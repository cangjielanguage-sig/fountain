# Strong-reference heap cache
1. Strong references
2. A lifetime can be specified for cached entries
3. A maximum number of cached objects can be specified
```cj
public class HeapCache<V> where V <: Object {
    /**
     * concurrencyLevel concurrency level, 128 by default
     * maxLife maximum lifetime of a cached object
     * maxSize maximum number of cached objects
     * checkDuration inspection period of the cache
     * evictionCallback callback invoked when a cached object becomes invalid
     */
    public HeapCache(
        private let concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL,
        private let maxLife!: Duration = DEFAULT_HEAP_CACHE_MAX_LIFE,
        private let maxSize!: Int64 = DEFAULT_HEAP_CACHE_MAX_SIZE,
        private let checkDuration!: Duration = DEFAULT_HEAP_CHECK_CHECK_DURATION,
        private let evictionCallback!: (String, V) -> Unit = {_, _ => ()}
    )
    /**Cache builder*/
    public static func builder(): HeapCacheBuilder<V>
    /**Get the value corresponding to the cache KEY*/
    public func get(key: String): Option<V>
    /**Check whether the cache KEY exists*/
    public func contains(key: String): Bool
    /**
     * Returns true when the cache KEY exists and the cached object is one-shot.
     * A one-shot object means that reading the object does not restart its expiry timer; otherwise every read restarts the expiry timer
     */
    public func once(key: String): Bool
    /**
     * Modify the expiry time of the object and whether it is one-shot.
     * A one-shot object means that reading the object does not restart its expiry timer; otherwise every read restarts the expiry timer
     */
    public func prolong(key: String, life: Duration, once!: Bool = false): Bool
    /**
     * Modify the expiry time of the object and make it one-shot
     * A one-shot object means that reading the object does not restart its expiry timer; otherwise every read restarts the expiry timer
     */
    public func prolong(key: String, deathTime: DateTime): Bool
    /**
     * Add or overwrite a cached object, specifying its expiry time and whether it is one-shot
     * A one-shot object means that reading the object does not restart its expiry timer; otherwise every read restarts the expiry timer
     */
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V
    /**
     * Add or overwrite a cached object, making the object one-shot
     * A one-shot object means that reading the object does not restart its expiry timer; otherwise every read restarts the expiry timer
     */
    public func set(key: String, value: V, dieAt: DateTime): ?V
    /**
     * Get the cached object, or return default if it does not exist
     */
    public func getOrDefault(key: String, default: V): V
    /**
     * Get the cached object, or cache value and return it if it does not exist
     */
    public func getOrStore(key: String, value: V): V
    /**
     * Get the cached object, or cache the return value of callable and use it as the return value if it does not exist
     */
    public func getOrCompute(key: String, callable: () -> V): V
    /**
     * Get the cached object, or cache the return value of callable and set its expiry time to the returned time if it
     * does not exist, and use the returned object as the return value of this function
     */
    public func getOrCompute(key: String, callable: () -> (V, DateTime)): V
    /**
     * Get the cached object, or cache the return value of callable if it does not exist, setting its expiry time to the
     * returned Duration and its one-shot flag to the returned Bool, and use the V returned by callable as the return
     * value of this function
     */
    public func getOrCompute(key: String, callable: () -> (V, Duration, Bool)): V
    /**
     * Remove the cached entry with the given key
     */
    public func remove(key: String): Option<V>
    /**
     * Remove the cached entries for which predicate returns true; the key-value pair of a cached entry is the argument of predicate
     */
    public func removeIf(predicate: (String, V) -> Bool): Unit
    /**Returns the number of cached objects*/
    public prop size: Int64
    /**Clear the cache*/
    public func clear(): Unit
    /**Close the cache: stop the internal thread, cancel the timer and empty the cache (Resource interface, may be called repeatedly)*/
    public func close(): Unit
    /**Whether the cache is already closed (Resource interface)*/
    public func isClosed(): Bool
}
```
```cj
public open class HeapCacheBuilder<V> where V <: Object {
    public func setMaxLife(maxLife: Duration): HeapCacheBuilder<V> 
    public func setConcurrencyLevel(concurrencyLevel: Int64): HeapCacheBuilder<V> 
    public func setMaxSize(maxSize: Int64): HeapCacheBuilder<V> 
    public func setEvictionCallback(callback: (String, V) -> Unit): HeapCacheBuilder<V> 
    public func setCheckDuration(checkDuration: Duration): HeapCacheBuilder<V> 
    public open func build(): HeapCache<V> 
}
```

# Weak-reference heap cache
The keys and values kept internally are wrapped in weak references; the cache is walked periodically and the weak references cleared by the runtime are removed
```cj
public class WeakHeapCache<T> where T <: Object {
    public init()
    /**Add a cache key-value object*/
    public func set(key: String, value: T): ?T
    /**
     * Get the cached object; if there is no cache entry and fn returns Some, cache that value, return it, and return None<T> otherwise
     */
    public func getOrCompute(key: String, fn: () -> ?T): ?T
    /**
     * Return the cached object, or None<T> if there is no cached KEY
     */
    public func get(key: String): ?T
    /**
     * Return the cached object, or default if there is no cache entry
     */
    public func getOrDefault(key: String, default: T): T
    /**
     * Return the cached object, or cache value and return it if there is no cache entry
     */
    public func getOrStore(key: String, value: T): T
    /**
     * Remove the cache KEY
     */
    public func remove(key: String): ?T
    /**
     * Remove the cached entries for which predicate returns true
     */
    public func removeIf(predicate: (String, T) -> Bool): Unit
    /**
     * Size of the cache
     */
    public prop size: Int64
    /**Clear the cache*/
    public func clear(): Unit
}
```

# Concurrency and conventions (added 2026-10-05)

Internally the cache is divided into segments according to `concurrencyLevel`, each with a reentrant read-write lock, and segments do not block one another:

- **The callable of `getOrCompute` runs outside the segment lock**: the same key may be computed concurrently several times, only the first written result takes effect and the other results are discarded. The callable should be a pure computation or idempotent; when it has side effects, or must "be computed only once", deduplicate in the caller.
- **`removeIf` deletes in two phases**: first take a snapshot under the read lock, then run the predicate outside the lock, and finally delete by key under the write lock. The predicate does not block reads and writes of the same segment; the price is that "decide—delete" is not atomic —— an entry written between the two phases may also be deleted because the old value in the snapshot satisfied the predicate.
- **The gap between `size` and `get`/`contains`**: `get`/`contains` first check the lifetime, while `size` counts the entries in the map ⇒ an entry that has expired but not yet been swept by the timer (at most one `checkDuration`) is still counted in `size`; the `maxSize` eviction also goes by `size`.
- **`WeakHeapCache` is a weak-reference cache with strong keys and weak values**: once a value is no longer strongly referenced from outside it may be collected by the GC and the entry becomes invalid with it (removed by the sweeping thread after at most 1 s) ⇒ `size` includes entries "whose value is already invalid but which have not been swept yet", and the gap with `get`/`contains` is at most 1 s; `close()` actively empties the cache and waits for the sweeping thread to finish.
- **Iteration consistency**: the iterators of `ConcHashMap`/`SyncLinkedHashMap` are **weakly consistent** (created outside the lock, taking locks segment by segment / entry by entry, with no cross-segment snapshot) ⇒ writes that happen during iteration are not guaranteed to be seen by that iteration, nor is their order guaranteed; the same holds when the timed eviction of `HeapCache` runs concurrently with business reads.
- **Eviction order when `maxSize` is exceeded**: the two candidates are first compared by "time since last use" —— if the gap exceeds one `checkDuration`, the older one is evicted directly; if the gap is within one period, the comparison goes level by level: **the one used more often in the current inspection period and the one used more recently is kept first** ("protect the newborn"). (Below that there are two more tie-break levels, "larger total number of historical accesses" and "born later", which are hardly ever reached in practice.)
- The public methods `set` / `get` / `remove` / `once` / `prolong` / `clear` and so on may all be called concurrently (segment locks + atomic counters).
- **`HeapCache` and `WeakHeapCache` implement `Resource`**: each of them holds one resident internal thread (`HeapCache` = a consumer thread for eviction callbacks + 1 timer; `WeakHeapCache` = a weak reference sweeping thread). Call `close()` when done (it may be called repeatedly): it sends a cancellation request to the internal thread, cancels the timer (`HeapCache`) and empties the cache; the internal thread checks `Thread.currentThread.hasPendingCancellation` on every loop, and the consumer thread of `HeapCache` drains the already queued eviction callbacks before exiting once it receives the cancellation. (The old `destroy()` of `HeapCache` has been removed; use `close()` uniformly. At process exit the `ExitCallbacks` of `f_base` call `close()` automatically; that registration holds a **weak reference**, so the instance can be collected by the GC after `close()`.)
- **Closing latency**: the consumer thread of `HeapCache` polls every 100 ms and the sweeping period of `WeakHeapCache` is 1 s, so `close()` may block for that long at most (it waits for the internal thread to end before returning); `isClosed()` becomes true immediately.
- **After closing**: `close()` **actively empties all entries** and returns only after the internal thread has ended; afterwards any operation (`get`/`set`/`contains`/`once`/`prolong`/`getOrCompute`/`remove`/`removeIf`/`size`/`clear`/…) throws `IllegalStateException` —— the only exceptions are `isClosed()` and `close()` (which may be called repeatedly).
- **`once` / `prolong` use the same rules as `get` / `contains`**: an expired entry (even if not yet swept by the timer) counts as absent —— `once`/`prolong` return `false` and **do not "revive" an expired entry**; use `set` to renew or rebuild it.
