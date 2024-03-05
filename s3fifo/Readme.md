![S3FIFO diagram](https://s3fifo.com/assets/posts/2023-08-16-s3fifo/diagram_s3fifo.svg)

An illustration of S3-FIFO.


S3-FIFO uses three FIFO queues: a small FIFO queue (S), a main FIFO queue (M), and a ghost FIFO queue (G). We choose S to use 10% of the cache space based on experiments with 10 traces and find that 10% generalizes well. M then uses 90% of the cache space. The ghost queue G stores the same number of ghost entries (no data) as M.

Cache read: S3-FIFO uses two bits per object to track object access status similar to a capped counter with frequency up to 31. Cache hits in S3-FIFO increment the counter by one atomically. Note that most requests for popular objects require no update.

Cache write: New objects are inserted into S if not in G. Otherwise, it is inserted into M. When S is full, the object at the tail is either moved to M if it is accessed more than once or G if not. And its access bits are cleared during the move.
When G is full, it evicts objects in FIFO order. M uses an algorithm similar to FIFO-Reinsertion but tracks access information using two bits. Objects that have been accessed at least once are reinserted with one bit set to 0 (similar to decreasing frequency by 1).

Implementation¶
Although S3-FIFO has three FIFO queues, it can also be implemented with one or two FIFO queue(s). Because objects evicted from S may enter M, they can be implemented using one queue with a pointer pointed at the 10% mark. However, combining S and M reduces scalability because removing objects from the middle of the queue requires locking.

The ghost FIFO queue G can be implemented as part of the indexing structure. For example, we can store the fingerprint and eviction time of ghost entries in a bucket-based hash table. The fingerprint stores a hash of the object using 4 bytes, and the eviction time is a timestamp measured in the number of objects inserted into G. We can find out whether an object is still in the queue by calculating the difference between current time and insertion time since it is a FIFO queue. The ghost entries stay in the hash table until they are no longer in the ghost queue. When an entry is evicted from the ghost queue, it is not immediately removed from the hash table. Instead, the hash table entry is removed during hash collision --- when the slot is needed to store other entries.