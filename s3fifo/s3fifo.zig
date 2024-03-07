//! A In-memory cache implementation with S3FIFO [S3-FIFO](https://s3fifo.com/) as the eviction policy.
//!
//! S3FIFO improves cache hit ratio noticeably compared to LRU.
//!
//! S3FIFO is using RWLock. It is very fast in the systems with a lot concurrent reads and/or writes

const std = @import("std");
const AtomicU8 = std.atomic.Value(u8);
const Allocator = std.mem.Allocator;
const TailQueue = std.TailQueue;
const Mutex = std.Thread.RwLock;
const testing = std.testing;
const assert = std.debug.assert;

/// Maximum frequency limit for an entry in the cache.
const maxfreq: u8 = 3;

pub const Kind = enum {
    locking,
    non_locking,
};

/// Simple implementation of "S3-FIFO" from "FIFO Queues are ALL You Need for Cache Eviction" by
/// Juncheng Yang, et al: https://jasony.me/publication/sosp23-s3fifo.pdf
pub fn S3fifo(comptime kind: Kind, K: type, comptime V: type) type {
    return struct {
        mux: if (kind == .locking) Mutex else void,
        allocator: Allocator,
        /// Small queue for entries with low frequency.
        small: TailQueue(Entry),
        /// Main queue for entries with high frequency.
        main: TailQueue(Entry),
        /// Ghost queue for evicted entries.
        ghost: TailQueue(K),
        /// Map of all entries for quick access.
        entries: if (K == []const u8) std.StringArrayHashMap(*Node) else std.AutoArrayHashMap(K, *Node),
        max_cache_size: usize,
        main_size: usize,
        len: usize,

        const Self = @This();

        /// Represents an entry in the cache.
        pub const Entry = struct {
            key: K,
            value: V,
            /// Frequency of access of this entry.
            feq: AtomicU8,

            const Self = @This();

            /// Creates a new entry with the given key and value.
            pub fn init(key: K, val: V) Entry {
                return Entry{
                    .key = key,
                    .value = val,
                    .feq = AtomicU8.init(0),
                };
            }
        };

        const Node = TailQueue(Entry).Node;

        const gNode = TailQueue(K).Node;

        fn initNode(self: *Self, key: K, val: V) error{OutOfMemory}!*Node {
            self.len += 1;

            const node = try self.allocator.create(Node);
            node.* = .{ .data = Entry.init(key, val) };
            return node;
        }

        fn deinitNode(self: *Self, node: *Node) void {
            self.len -= 1;
            self.allocator.destroy(node);
        }

        /// Creates a new cache with the given maximum size.
        pub fn init(allocator: Allocator, max_cache_size: usize) Self {
            const max_small_size = max_cache_size / 10;
            const max_main_size = max_cache_size - max_small_size;
            const hashmap = if (K == []const u8) std.StringArrayHashMap(*Node).init(allocator) else std.AutoArrayHashMap(K, *Node).init(allocator);
            return Self{ .mux = if (kind == .locking) Mutex{} else undefined, .allocator = allocator, .small = TailQueue(Entry){}, .main = TailQueue(Entry){}, .ghost = TailQueue(K){}, .entries = hashmap, .max_cache_size = max_cache_size, .main_size = max_main_size, .len = 0 };
        }

        pub fn deinit(self: *Self) void {
            while (self.small.pop()) |node| {
                self.deinitNode(node);
            }

            while (self.ghost.pop()) |node| : (self.len -= 1) {
                self.allocator.destroy(node);
            }

            while (self.main.pop()) |node| {
                self.deinitNode(node);
            }
            std.debug.assert(self.len == 0); // no leaks
            self.entries.deinit();
        }

        /// Whether or not contains key.
        /// NOTE: doesn't affect cache ordering.
        pub fn contains(self: *Self, key: K) bool {
            if (kind == .locking) {
                self.mux.lockShared();
                defer self.mux.unlockShared();
            }
            return self.entries.contains(key);
        }

        /// Returns a reference to the value of the given key if it exists in the cache.
        pub fn get(self: *Self, key: K) ?V {
            if (kind == .locking) {
                self.mux.lockShared();
                defer self.mux.unlockShared();
            }
            if (self.entries.get(key)) |node| {
                const freq = @min(node.data.feq.load(.SeqCst) + 1, maxfreq);
                node.data.feq.store(freq, .SeqCst);
                return node.data.value;
            } else {
                return null;
            }
        }

        /// Inserts a new entry with the given key and value into the cache.
        pub fn insert(self: *Self, key: K, value: V) error{OutOfMemory}!void {
            if (kind == .locking) {
                self.mux.lock();
                defer self.mux.unlock();
            }

            try self.evict();

            if (self.entries.contains(key)) {
                const node = try self.initNode(key, value);
                self.main.append(node);
            } else {
                const node = try self.initNode(key, value);
                try self.entries.put(key, node);
                self.small.append(node);
            }
        }

        fn insert_m(self: *Self, tail: *Node) void {
            self.len += 1;
            self.main.prepend(tail);
        }

        fn insert_g(self: *Self, tail: *Node) !void {
            if (self.ghost.len >= self.main_size) {
                const key = self.ghost.popFirst().?;
                self.allocator.destroy(key);
                _ = self.entries.swapRemove(key.data);
                self.len -= 1;
            }
            const node = try self.allocator.create(gNode);
            node.* = .{ .data = tail.data.key };
            self.ghost.append(node);
            self.len += 1;
        }

        fn evict(self: *Self) !void {
            if (self.small.len + self.main.len >= self.max_cache_size) {
                if (self.main.len >= self.main_size or self.small.len == 0) {
                    self.evict_m();
                } else {
                    try self.evict_s();
                }
            }
        }

        fn evict_m(self: *Self) void {
            while (self.main.popFirst()) |tail| {
                const freq = tail.data.feq.load(.SeqCst);
                if (freq > 0) {
                    tail.data.feq.store(freq - 1, .SeqCst);
                    self.main.append(tail);
                } else {
                    _ = self.entries.swapRemove(tail.data.key);
                    self.deinitNode(tail);
                    break;
                }
            }
        }

        fn evict_s(self: *Self) !void {
            while (self.small.popFirst()) |tail| {
                if (tail.data.feq.load(.SeqCst) > 1) {
                    self.insert_m(tail);
                } else {
                    try self.insert_g(tail);
                    self.deinitNode(tail);
                    break;
                }
            }
        }
    };
}

test "s3fifotest: base" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.print("GPA result: {}\n", .{gpa.deinit()});
    var logging_alloc = std.heap.loggingAllocator(gpa.allocator());
    const allocator = logging_alloc.allocator();

    var cache = S3fifo(.non_locking, u64, []const u8).init(allocator, 2);
    defer cache.deinit();

    try cache.insert(1, "one");
    try cache.insert(2, "two");
    const val = cache.get(1);
    try testing.expectEqual(val.?, "one");
    try cache.insert(3, "three");
    try cache.insert(4, "four");
    try cache.insert(5, "five");
    try cache.insert(4, "four");
    try testing.expect(cache.contains(1));
}

// test "s3fifotest: push and read" {
//     var cache = S3fifo(.locking, []const u8, []const u8).init(testing.allocator, 2);
//     defer cache.deinit();

//     try cache.insert("apple", "red");
//     try cache.insert("banana", "yellow");
//     const red = cache.get("apple");
//     const yellow = cache.get("banana");
//     try testing.expectEqual(red.?, "red");
//     try testing.expectEqual(yellow.?, "yellow");
// }
