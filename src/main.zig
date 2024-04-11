const std = @import("std");
const LRU = @import("lru").LruCache;
const zbench = @import("zbench");

const cache = LRU(.non_locking, u8, []const u8);

pub fn main() !void {

    // Create a cache backed by DRAM
    var lrucache = try cache.init(std.heap.page_allocator, 4);
    defer lrucache.deinit();

    // Add an object to the cache
    try lrucache.insert(1, "one");
    try lrucache.insert(2, "two");
    try lrucache.insert(3, "three");
    try lrucache.insert(4, "four");

    // Most recently used cache
    std.debug.print("mru: {s} \n", .{lrucache.mru().?.value});

    // least recently used cache
    std.debug.print("lru: {s} \n", .{lrucache.lru().?.value});

    // remove from cache
    _ = lrucache.remove(1);

    // Check if an object is in the cache O/P: false
    std.debug.print("key: 1 exists: {} \n", .{lrucache.contains(1)});
}

fn myBenchmark(alloc: std.mem.Allocator) void {
    var result: usize = 0;
    for (0..2_000) |i| {
        std.mem.doNotOptimizeAway(i);
        result += i * i;
        const buf = alloc.alloc(u8, 1024) catch unreachable;
        defer alloc.free(buf);
    }
}

test "bench test" {
    var bench = zbench.Benchmark.init(std.testing.allocator, .{});
    defer bench.deinit();
    try bench.add("My Benchmark", myBenchmark, .{});
    try bench.run(std.io.getStdOut().writer());
}
