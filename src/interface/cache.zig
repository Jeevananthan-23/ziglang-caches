/// Cache is the interface for a cache.
pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        // pickFn: fn (*Interface) i32,

        /// Set sets the value for the given key on cache.
        set: fn (self: *Self, K, V) ?void,

        /// Get gets the value for the given key from cache.
        get: fn (Self, K) ?V,

        /// Remove removes the provided key from the cache.
        remove: fn (K) bool,

        /// Contains check if a key exists in cache without updating the recent-ness
        constains: fn (K) bool,

        /// Peek returns key's value without updating the recent-ness.
        peek: fn (K) ?V,

        /// SetOnEvicted sets the callback function that will be called when an entry is evicted from the cache.
        // set_on_eviceted: fn SetOnEvicted(callback OnEvictCallback[K, V]),

        /// Len returns the number of entries in the cache.
        len: fn (*Self) u32,

        /// Purge clears all cache entries
        purge: fn (*Self) void,

        /// Close closes the cache and releases any resources associated with it.
        close: fn (*Self) void,
    };
}
