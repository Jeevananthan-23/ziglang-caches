//! A In-memory cache implementation with S3FIFO [S3-FIFO](https://s3fifo.com/) as the eviction policy.
//!
//! S3FIFO improves cache hit ratio noticeably compared to LRU.
//!
//! S3FIFO is using RWLock. It is very fast in the systems with a lot concurrent reads and/or writes

const std = @import("std");
const AtomicU8 = std.atomic.Value(u8);
const Allocator = std.mem.Allocator;
const TailQueue = std.DoublyLinkedList;
const Mutex = std.Thread.RwLock;
const testing = std.testing;
const assert = std.debug.assert;

/// Maximum frequency limit for an entry in the cache.
const maxfreq: u8 = 3;

const TracerStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
};

pub const Kind = enum {
    locking,
    non_locking,
};

/// Simple implementation of "S3-FIFO" from [FIFO Queues are ALL You Need for Cache Eviction](https://jasony.me/publication/sosp23-s3fifo.pdf)
pub fn S3fifo(comptime kind: Kind, comptime K: type, comptime V: type) type {
    return struct {
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

        tracer_stats: *TracerStats,

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

        /// Initialize cache with given capacity.
        pub fn init(allocator: Allocator, max_cache_size: usize) !Self {
            const max_small_size = max_cache_size / 10;
            const max_main_size = max_cache_size - max_small_size;
            const hashmap = if (K == []const u8) std.StringArrayHashMap(*Node).init(allocator) else std.AutoArrayHashMap(K, *Node).init(allocator);
            // errdefer hashmap.deinit();

            // Explicitly allocated so that get / get_index can be `*const Self`.
            const tracer_stats = try allocator.create(TracerStats);
            errdefer allocator.destroy(tracer_stats);

            return Self{
                .mux = if (kind == .locking) Mutex{} else undefined,
                .allocator = allocator,
                .small = TailQueue(Entry){},
                .main = TailQueue(Entry){},
                .ghost = TailQueue(K){},
                .entries = hashmap,
                .max_cache_size = max_cache_size,
                .main_size = max_main_size,
                .len = 0,
                .tracer_stats = tracer_stats,
            };
        }

        /// Deinitialize cache.
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
            self.allocator.destroy(self.tracer_stats);
        }

        /// Return the capacity of the cache.
        pub inline fn capacity(self: *Self) usize {
            self.max_cache_size;
        }

        /// Check if cache is empty.
        pub inline fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        /// Whether or not contains key.
        /// NOTE: doesn't affect cache ordering.
        pub fn contains(self: *Self, key: K) bool {
            if (kind == .locking) self.mux.lock();
            defer if (kind == .locking) self.mux.unlock();

            return self.entries.contains(key);
        }

        pub fn get_trace(self: *const Self) void {
            std.debug.print("Tracer_stats \n hits: {}\n misses: {}", .{ self.tracer_stats.*.hits, self.tracer_stats.*.misses });
        }

        /// Returns a reference to the value of the given key if it exists in the cache.
        pub fn get(self: *Self, key: K) ?V {
            if (kind == .locking) {
                self.mux.lockShared();
                defer self.mux.unlockShared();
            }
            if (self.entries.get(key)) |node| {
                self.tracer_stats.hits += 1;
                const freq = @min(node.data.feq.load(.SeqCst) + 1, maxfreq);
                node.data.feq.store(freq, .SeqCst);
                return node.data.value;
            } else {
                self.tracer_stats.misses += 1;
                return null;
            }
        }

        /// Inserts a new entry with the given key and value into the cache.
        pub fn set(self: *Self, key: K, value: V) error{OutOfMemory}!void {
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

        /// WIP
        pub fn remove(self: *Self, key: K) error{OutOfMemory}!bool {
            if (self.entries.getPtr(key)) |val| {
                const node = try self.initNode(key, val);
                try self.removeEntry(&node);
                _ = self.entries.swapRemove(key);
                self.len -= 1;
                return true;
            }
            return false;
        }

        // WIP
        fn removeEntry(self: *Self, node: *Node) error{OutOfMemory}!void {
            const gnode = try self.allocator.create(gNode);
            defer self.allocator.free(gnode);
            gnode.* = .{ .data = node.data.key };
            self.ghost.remove(gnode);
            self.main.remove(&node);
            self.small.remove(&node);
            self.deinitNode(node);
        }

        fn insert_m(self: *Self, tail: *Node) void {
            self.len += 1;
            self.main.prepend(tail);
        }

        fn insert_g(self: *Self, tail: *Node) !void {
            if (self.ghost.len >= self.main_size) {
                const key = self.ghost.popFirst().?;
                defer self.allocator.destroy(key);
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
    defer std.debug.print("\n GPA result: {}\n", .{gpa.deinit()});
    var logging_alloc = std.heap.loggingAllocator(gpa.allocator());
    const allocator = logging_alloc.allocator();

    var cache = try S3fifo(.non_locking, u64, []const u8).init(allocator, 3);
    defer cache.deinit();

    try cache.set(1, "one");
    try cache.set(2, "two");
    const val = cache.get(1);
    try testing.expectEqual(val.?, "one");
    try cache.set(3, "three");
    try cache.set(4, "four");
    try cache.set(5, "five");
    try cache.set(4, "four");
    try testing.expect(cache.contains(1));
    cache.get_trace();
}

test "s3fifotest: push and read" {
    var cache = try S3fifo(.locking, []const u8, []const u8).init(testing.allocator, 2);
    defer cache.deinit();

    try cache.set("apple", "red");
    try cache.set("banana", "yellow");
    const red = cache.get("apple");
    const yellow = cache.get("banana");
    try testing.expectEqual(red.?, "red");
    try testing.expectEqual(yellow.?, "yellow");
}

pub const BenchmarkS3fifo = struct {
    pub const min_iterations = 1;
    pub const max_iterations = 10;
    pub var hits: u64 = 0;
    pub var misses: u64 = 0;
    pub const args = [_]usize{
        1_00,
        5_00,
        10_00,
    };

    pub const arg_names = [_][]const u8{
        "1k_iters",
        "5k_iters",
        "10k_iters",
    };

    pub fn benchmarkS3fifoGetandSet(num_iterations: usize) !void {
        var cache = S3fifo(.non_locking, u32, usize).init(std.heap.page_allocator, 200);
        defer cache.deinit();
        var rand_impl = std.rand.DefaultPrng.init(num_iterations);
        for (0..num_iterations) |_| {
            const num = rand_impl.random().uintLessThan(u32, @as(u32, @intCast(num_iterations)) + 1);
            const val = cache.get(num);
            if (val != null) {
                hits += 1;
            } else {
                misses += 1;
                _ = try cache.set(num, num);
            }
        }
        cache.get_trace();
    }
};
