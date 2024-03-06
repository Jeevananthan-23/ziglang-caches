Window TinyLfu
W-TinyLfu uses a small admission LRU that evicts to a large Segmented LRU if accepted by the TinyLfu admission policy. TinyLfu relies on a frequency sketch to probabilistically estimate the historic usage of an entry. The window allows the policy to have a high hit rate when entries exhibit recency bursts which would otherwise be rejected. The size of the window vs main space is adaptively determined using a hill climbing optimization. This configuration enables the cache to estimate the frequency and recency of an entry with low overhead.

This implementation uses a 4-bit CountMinSketch, growing at 8 bytes per cache entry to be accurate. Unlike ARC and LIRS, this policy does not retain evicted keys.


 - [TinyLFU: A Highly Efficient Cache Admission Policy](https://arxiv.org/abs/1512.00727)