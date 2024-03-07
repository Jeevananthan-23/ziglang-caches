const std = @import("std");
const Time = std.time;
const List = std.DoublyLinkedList;

const numberOfBuckets = 100;

pub fn Sieve(comptime K: type, comptime V: type) type {
    return struct {
        size: usize,
        ll: List(Entry),
        items: std.AutoHashMap(K, Entry),

        const Self = @This();

        /// Represents an entry in the cache.
        pub const Entry = struct {
            key: K,
            value: V,
            visited: bool,
            element: List(K).Node,
            expiredAt: Time.Instant,
            bucketID: i8, // bucketID is an index which the entry is stored in the bucket

            const Self = @This();

            /// Creates a new entry with the given key and value.
            pub fn init(key: K, val: V) Entry {
                return Entry{
                    .key = key,
                    .value = val,
                };
            }
        };
    };
}
