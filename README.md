# ziglang-caches

This is a modern cache implementation, inspired by the following papers, provides high efficiency.

- SIEVE | [SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction Algorithm for Web Caches (NSDI'24)](https://junchengyang.com/publication/nsdi24-SIEVE.pdf)
- S3-FIFO | [FIFO queues are all you need for cache eviction (SOSP'23)](https://dl.acm.org/doi/10.1145/3600006.3613147)
- W-TinyLFU | [TinyLFU: A Highly Efficient Cache Admission Policy](https://arxiv.org/abs/1512.00727)

This offers state-of-the-art efficiency and scalability compared to other LRU-based cache algorithms.

## Basic usage
 > [!LRU_Cache]
 > Least recents used cache eviction policy for cache your data in-memory for fast access. 


```zig
const std = @import("std");
const lru = @import("lru");

const cache = lru.LruCache(.locking, u8, []const u8);

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
```

### :rocket: Usage

1. Add `ziglang-caches` as a dependency in your `build.zig.zon`.

    <details>

    <summary><code>build.zig.zon</code> example</summary>

    ```zig
    .{
        .name = "<name_of_your_package>",
        .version = "<version_of_your_package>",
        .dependencies = .{
            .caches = .{
                .url = "https://github.com/jeevananthan-23/ziglang-caches/archive/<git_tag_or_commit_hash>.tar.gz",
                .hash = "<package_hash>",
            },
        },
    }
    ```

    Set `<package_hash>` to `12200000000000000000000000000000000000000000000000000000000000000000`, and Zig will provide the correct found value in an error message.

    </details>

2. Add `lrucache` as a module in your `build.zig`.

    <details>

    <summary><code>build.zig</code> example</summary>

    ```zig
    const lrucache = b.dependency("caches", .{});
    exe.addModule("lrucache", lrucache.module("lrucache"));
    ```

    </details>
