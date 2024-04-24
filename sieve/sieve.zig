//! A In-memory cache implementation with SIEVE [SIEVE](https://cachemon.github.io/SIEVE-website/) as the eviction policy.
//!
//! An Eviction Algorithm Simpler than LRU for Web Caches.
//!
//! SIEVE is using RWLock. It is very fast in the systems with a lot concurrent reads and/or writes

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.RwLock;

pub const Kind = enum {
    locking,
    non_locking,
};

/// Simple implementation of "SIEVE" from
/// [SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction Algorithm for Web Caches (NSDI'24)](https://junchengyang.com/publication/nsdi24-SIEVE.pdf)
pub fn Sieve(comptime kind: Kind, comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const HashMapUnmanaged = if (K == []const u8) std.StringHashMapUnmanaged(*Node) else std.AutoHashMapUnmanaged(K, *Node);

        /// Intrusive cache's node.
        pub const Node = struct {
            is_visited: bool = false,
            prev: ?*Node = null,
            next: ?*Node = null,
            value: V,
            key: K,

            /// Creates a new entry with the given key and value.
            pub fn init(key: K, val: V) Node {
                return Node{
                    .key = key,
                    .value = val,
                };
            }
        };

        mux: if (kind == .locking) Mutex else void,
        allocator: Allocator,

        map: HashMapUnmanaged = HashMapUnmanaged{},
        hand: ?*Node = null,
        head: ?*Node = null,
        tail: ?*Node = null,

        capacity: usize,
        len: usize,

        fn initNode(self: *Self, key: K, val: V) error{OutOfMemory}!*Node {
            self.len += 1;

            const node = try self.allocator.create(Node);
            node.* = .{ .key = key, .value = val };
            return node;
        }

        fn deinitNode(self: *Self, node: *Node) void {
            self.len -= 1;
            self.allocator.destroy(node);
        }

        /// Initialize cache with given capacity.
        pub fn init(allocator: std.mem.Allocator, max_size: u32) error{OutOfMemory}!Self {
            if (max_size == 0) @panic("Capacity must be greter than 0");
            var self = Self{
                .allocator = allocator,
                .mux = if (kind == .locking) Mutex{} else undefined,
                .capacity = max_size,
                .len = 0,
            };

            // pre allocate enough capacity for max items since we will use
            // assumed capacity and non-clobber methods
            try self.map.ensureTotalCapacity(allocator, max_size);

            return self;
        }

        /// Deinitialize cache.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
            self.* = undefined;
        }

        pub fn reset(self: *Self) void {
            @memset(self.len, 0);
            @memset(self.capacity, 0);
        }

        /// Return the capacity of the cache.
        pub inline fn capacity(self: *Self) usize {
            self.capacity;
        }

        /// Return the number of cached values.
        pub inline fn len(self: *Self) usize {
            self.len;
        }

        /// Check if cache is empty.
        pub inline fn isEmpty(self: *Self) bool {
            return self.capacity() == 0;
        }

        /// Check if cache contains given key.
        pub fn contains(self: *Self, key: K) bool {
            return self.map.contains(key);
        }

        /// Get value associated with given key, otherwise return `null`.
        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                node.is_visited = true;
                return node.value;
            }
            return null;
        }

        /// Put node pointer and return `true` if associated key is not already present.
        /// Otherwise, set node pointer, evicting old entry, and return `false`.
        pub fn set(self: *Self, key: K, value: V) error{OutOfMemory}!bool {
            var node = try self.initNode(key, value);
            if (self.map.getPtr(key)) |old_node| {
                old_node.* = node;
                return false;
            } else {
                if (self.len >= self.capacity) {
                    self.evict();
                }

                node.next = self.head;
                if (self.head) |head| {
                    head.prev = node;
                }

                self.head = node;
                if (self.tail == null) {
                    self.tail = self.head;
                }

                self.map.putAssumeCapacityNoClobber(node.key, node);
                std.debug.assert(self.len < self.capacity);
                self.len += 1;
                return true;
            }
        }

        /// Remove key and return associated node pointer, otherwise return `null`.
        pub fn fetchRemove(self: *Self, key: K) ?*Node {
            const node = self.map.get(key) orelse return null;
            _ = self.map.remove(key);
            self.removeNode(node);
            std.debug.assert(self.len > 0);
            self.len -= 1;
            return node;
        }

        fn removeNode(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            self.deinitNode(node);
        }

        fn evict(self: *Self) void {
            var node_opt = self.hand orelse self.tail;
            while (node_opt) |node| : (node_opt = node.prev orelse self.tail) {
                if (!node.is_visited) {
                    break;
                }
                node.is_visited = false;
            }
            if (node_opt) |node| {
                self.hand = node.prev;
                _ = self.map.remove(node.key);
                self.removeNode(node);
                std.debug.assert(self.len > 0);
                self.len -= 1;
            }
        }
    };
}

test Sieve {
    const StringCache = Sieve(.non_locking, []const u8, []const u8);

    var cache = try StringCache.init(std.testing.allocator, 4);
    defer cache.deinit(std.testing.allocator);

    const foobar_node = StringCache.Node{ .key = "foo", .value = "bar" };
    const zigzag_node = StringCache.Node{ .key = "zig", .value = "zag" };
    const flipflop_node = StringCache.Node{ .key = "flip", .value = "flop" };
    const ticktock_node = StringCache.Node{ .key = "tick", .value = "tock" };

    try std.testing.expect(try cache.set(foobar_node.key, foobar_node.value));
    try std.testing.expect(try cache.set(zigzag_node.key, zigzag_node.value));
    try std.testing.expectEqual(2, cache.len);
    try std.testing.expect(try cache.set(flipflop_node.key, flipflop_node.value));
    try std.testing.expect(try cache.set(ticktock_node.key, ticktock_node.value));
    try std.testing.expectEqual(4, cache.capacity);

    try std.testing.expectEqualStrings("bar", cache.fetchRemove("foo").?.value);
    try std.testing.expectEqual(cache.get("foo"), null);

    try std.testing.expectEqualStrings("zag", cache.get("zig").?);
    try std.testing.expectEqualStrings("flop", cache.get("flip").?);
    try std.testing.expectEqualStrings("tock", cache.get("tick").?);
}
