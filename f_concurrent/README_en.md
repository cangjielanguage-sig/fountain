## STDX dependency
Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## Concurrency-safe dictionary

`ConcDict<K, V>` is a concurrent dictionary interface (`<: Collection<(K, V)>`): **it does not require `K` to implement `Hashable & Equatable<K>` or `Comparable<K>`** ——
hashing and equality are supplied by the implementation at construction time (`hasher: (K) -> Int64` / `equals: (K, K) -> Bool`), so keys may be arbitrary custom types.
`ConcHashDict` is its hash implementation, and `ConcurrentHashSet` provides a concurrent Set on top of it.

```cj
public interface ConcDict<K, V> <: Collection<(K, V)> {
    /* Must be implemented by the implementation itself */
    func get(key: K): Option<V>
    func add(key: K, value: V): Option<V>            // Returns the overwritten old value (if any)
    func add(all!: Collection<(K, V)>): Unit
    func addIfAbsent(key: K, value: V): ?V           // Puts only if absent, returns the original value (if any)
    func replace(key: K, value: V): ?V               // Replaces only if present, returns the old value
    func remove(key: K): Option<V>
    func remove(all!: Collection<K>): Unit
    func removeIf(predicate: (K, V) -> Bool): Unit
    func contains(key: K): Bool
    func contains(all!: Collection<K>): Bool
    func clear(): Unit
    func keys(): Collection<K>
    func values(): Collection<V>
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V    // Atomic "read-modify-write"; the convenience methods below are all built on it
    prop size: Int64
    func isEmpty(): Bool
    func iterator(): Iterator<(K, V)>
    operator func [](key: K): V                      // Throws when the key does not exist
    operator func [](key: K, value!: V): Unit

    /* Default implementations are already given in the interface (all based on entryView) */
    func addIfAbsent(key: K, fn: () -> V): V         // Creates the value with fn and puts it if absent, returns the final value
    func addIfPreset(key: K, fn: () -> V): ?V        // Generates a new value with fn and replaces the existing one
    func removeIf(key: K, predicate: (V) -> Bool): ?V
}
```

Two things that are easy to overlook:

- `addIfAbsent` has **two overloads** —— `(key, value)` returns the old value and must be implemented by the implementation; `(key, fn: () -> V)` has a default implementation and returns the final value;
- `removeIf` also has two different signatures —— `(predicate: (K, V) -> Bool): Unit` and `(key, predicate: (V) -> Bool): ?V`.

```cj
public class ConcHashDict<K, V> <: ConcDict<K, V> {
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /** The argument of initElement ranges over 0 to size and returns the initial key-value pair at that position */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool)
}
```

(`toArray()` and the like come from the `Collection` parent interface.)

## `public class ConcurrentHashSet<T> <: Set<T> where T <: Hashable & Equatable<T>`
A concurrency-safe Set: 4 `init`s (capacity / initial collection etc.), `retainAll`, `clone`, and the extensions `==` / `toString` /
`intersection` / `union` / `difference` (see `src/ConcurrentHashSet.cj`).

## Load balancing

```cj
/** Round robin: every next() returns current, then current += step; when current > max it goes back to min */
public struct RoundRobin<W> <: LoadBalanceAlgo<W> where W <: Addable<W> & Comparable<W> {
    public RoundRobin(private let step: W, private let min: W, private let max: W)
}
/** Random weight: Int64Weight draws from [min, max], Float64Weight from [min, max) (floating point cannot use the closed +1 semantics) */
public abstract class RandomWeight<W> <: LoadBalanceAlgo<W> where W <: StdNumber<W> & Addable<W> & Comparable<W>
public class Int64Weight <: RandomWeight<Int64>
public class Float64Weight <: RandomWeight<Float64>

public class LoadBalance<W, D, R> where W <: Addable<W> & Comparable<W> {
    /** min is the **starting point of the accumulated weight keys**, not the "minimum weight"; algo is required */
    public LoadBalance(min: W, algo: LoadBalanceAlgo<W>)
    public func add(weight: W, fn: (D) -> R): Unit
    public func add(all!: Iterable<(W, (D) -> R)>): Unit
    /** Pick a node by the algorithm and execute it */
    public func call(data: D): R
    /** On failure, move to the next node in order and retry up to maxRetrying times */
    public func call(data: D, maxRetrying: Int64): (?R, ?LoadBalanceException)
    /** Iterate starting from the position chosen by the algorithm and wrap around at the end (the first element is the chosen node, the rest are retry nodes) */
    public func iterator(): Iterator<(D) -> R>
}
```

Semantics (**the easiest place to trip**): internally a `TreeMap` is used whose keys are the **accumulated weights** `K_i = min + w₁ + … + w_i`,
and picking a node = the first key ≥ the value produced by the algorithm ⇒ node i covers `(K_{i-1}, K_i]`. The value produced by the algorithm must therefore land
**inside a bucket**: if the value aligns with a bucket boundary (for example if the starting point of the values equals `min`), **the same node is always hit**.
For weighted scenarios the recommendation is `min = 0`, a value starting point of `step / 2` and an upper bound of `Σw` (that is how `ClientConfig` of `f_rpc` is wired,
see part 2 of `.autocode/bugs/bug-archived-20261004-2.md`). For runnable examples see `src/LoadBalance_test.cj` (equal weights, 2:1, 4:1, and the expected values of both random modes are all in there).


## Rate limiting algorithms
```cj
abstract sealed class RateLimiter<T> {
    /**Blocking timeout*/
    public RateLimiter(protected let timeout: Duration)
    /**Execute a function*/
    public func exec(task: () -> ?T): ?T
    /**If task returns None this function returns default*/
    public func exec(default: ?T, task: () -> ?T): ?T
}
```
### No rate limiting
```cj
public class UnlimitedRateLimiter<T> <: RateLimiter<T>
```
### Leaky bucket algorithm
```cj
public class LeakingBucketRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param timeout Time a task may wait
     * @param maxWaitings Maximum number of tasks allowed to wait
     * @param leakingPerDuration Number of tasks leaked per leaky bucket period
     * @param leakingDuration Leaky bucket period
     */
    public init(
        timeout!: Duration,
        maxWaitings!: Int64,
        leakingPerDuration!: Int64,
        leakingDuration!: Duration
    )
}
```

### Sliding window algorithm
```cj
public class SlidingWindowRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param window Time window (must be > 0)
     * @param timeout Blocking timeout
     * @param limit Maximum number of tasks within the time window (must be > 0)
     */
    public init(window!: Duration, timeout!: Duration, limit!: Int64)
}
```

### Token bucket algorithm
```cj
public class TokenBucketRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param tokens Total number of tokens
     * @param timeout Blocking duration
     * @param populationPeriod Period for refilling tokens
     */
    public init(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration)
}
```

### Maximum-at-any-moment limiter
```cj
public class AnyMomentRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param maxTokens At most this many tasks may run concurrently at any moment
     * @param timeout Time a task may wait
     */
    public init(maxTokens!: Int64, timeout!: Duration)
}
```


## Compute only once
```cj
public struct Constants {
    /**
     * Get a constant; if no value exists for key, call fn to compute and return it
     */
    public static func get<T>(key: String, fn: () -> T): T
    /**
     * Get a constant; if it does not exist, call fn to compute and return it
     */
    public static func get<T>(fn: () -> T): T
}
```


## ConcurrentSkipListMap

A concurrency-safe dictionary implemented on a skip list, supporting ordered key operations.

```cj
public class ConcurrentSkipListMap<K, V> <: ConcurrentMap<K, V> & Collection<(K, V)> where K <: Comparable<K>
```

Besides the methods of its own listed below, `put` / `putIfAbsent` / `add(all!)` / `contains(all!)` / `toArray()` and so on come from the
`ConcurrentMap` / `Collection` parent interfaces (see `src/ConcurrentSkipListMap.cj`).

### Constructor

```cj
public init()
```

### Core methods

#### Lookup
```cj
// Get the value by key
public func get(key: K): Option<V>

// Check whether the given key is contained
public func contains(key: K): Bool

// Get the number of elements
prop size: Int64

// Check whether it is empty
public func isEmpty(): Bool
```

#### Insert/update
```cj
// Insert or update a key-value pair, returning the old value (if any)
public func add(key: K, value: V): Option<V>

// Insert only when the key does not exist
public func addIfAbsent(key: K, value: V): Option<V>

// Update only when the key exists
public func addIfPresent(key: K, value: V): Option<V>

// Unconditional replace
public func replace(key: K, value: V): Option<V>

// Replace with a function
public func replace(key: K, eval: (V) -> V): ?V

// Replace with a condition check
public func replace(key: K, predicate: (V) -> Bool, eval: (V) -> V): ?V
```

#### Delete
```cj
// Remove the mapping of the given key
public func remove(key: K): Option<V>

// Delete with a condition
public func remove(key: K, predicate: (V) -> Bool): Option<V>

// Delete all key-value pairs satisfying the condition
public func removeIf(predicate: (K, V) -> Bool): Unit

// Delete several keys
public func remove(all!: Collection<K>): Unit

// Clear all key-value pairs
public func clear(): Unit
```

#### Iteration
```cj
// Return an iterator
public func iterator(): Iterator<(K, V)>

// Get all keys
public func keys(): EquatableCollection<K>

// Get all values
public func values(): Collection<V>
// Iterate starting from the smallest KEY up to max; including decides whether max is included
public func header(max: K, including!: Bool = false): Iterator<(K, V)>
/**
 * @param min: the first key of the iterator is not less than min
 * @param including: whether the first key of the iterator includes min, true to include, false not to include
 */
public func tailer(min: K, including!: Bool = true): Iterator<(K, V)> 
// Return an iterator over the given range, starting at min and ending at max; includingMax decides whether max is included and includingMin whether min is included
public func sub(min: K, max: K, includingMin!: Bool = true, includingMax!: Bool = true): Iterator<(K, V)>
```

#### Atomic operations
```cj
// If the key does not exist, call fn to compute the value and store it
public func addIfAbsent(key: K, fn: () -> V): V

// If the key exists, call fn with the current value and store the result
public func addIfPresent(key: K, fn: () -> V): ?V

// Simplified overload of the Entry View operation
public func entryView(key: K, fn: (K, ?V) -> ?V): ?V

// Atomic update with a condition check
public func entryView(key: K, fn: (MapEntryView<K, V>) -> Unit): ?V
```

### Operator overloads
```cj
// Get the value by key (throws when the key does not exist)
operator func [](key: K): V

// Set the value by key
operator func [](key: K, value!: V): Unit
```

### Implementation details

- **Data structure**: implemented as a skip list, supporting O(log n) lookup, insertion and deletion
- **Concurrency safety**: lock-free concurrency based on CAS operations
- **Weak consistency**: the size property may deviate slightly
- **Deferred cleanup**: logical deletion plus physical cleanup
- **Dynamic levels**: the maximum level is adjusted dynamically according to size (8/12/16)


## DelayQueue
### Delayed
```cj
public interface Delayed<T> <: Comparable<T> where T <: Delayed<T> {
    //Once a Delayed instance is determined, the value of delayedAt must be determined and can no longer change
    prop delayedAt: DateTime

    func compare(other: T): Ordering {
        delayedAt.compare(other.delayedAt)
    }
}
```

### `DelayQueue<T> where T <: Delayed<T>`
```cj
public class DelayQueue<T> <: Queue<T> where T <: Delayed<T> {
    public init()
    //Synchronous function; notifies all threads waiting for data before returning
    public func add(element: T): Unit
    //Non-synchronous function; returns the data at the head of the queue without removing the head
    public func peek(): ?T
    //Synchronous function; waits until the queue is non-empty if it is empty, otherwise waits for the delay of the head element and then returns
    public func remove(): ?T
    //Synchronous function; if the queue is empty it waits until it is non-empty or the timeout expires, otherwise it waits for the delay of the head element and then returns
    public func remove(timeout: Duration): ?T
    //Non-synchronous function; get the queue size
    public prop size: Int64
    //Non-synchronous function; check whether the queue is empty
    public func isEmpty(): Bool
    //Non-synchronous function; get an iterator whose next function is synchronous
    public func iterator(): Iterator<T>
}
```

## Supplement: public surface not expanded in this README (the source code is authoritative)

- **`Executors` / `Executor` / `ExecutorFuture`** (`Executor.cj`): thread pool + Future ——
  created with `Executors(n)`, submitted with `call(task)` / `tryCall(task)` / `call(limiter, task)`, results taken with `get(...)`.
- **Event bus** (`eventbus/`): `EventBus` (`init(workers, maxWaitingJobPerWorker, fullJobQueueStrategy,
  toThrowIfNotMatch, abilities)`, methods `arrange` / `arrangeAndGet` / `register` / `retireAll`),
  `Event` (abstract event base class: `name` / `getData` / `setData` / `deliverResult` / `workerId`),
  `EndEvent` (return it to end the task), `Worker` / `JobQueue`; the exception `EventBusException` (queue full / timeout).
- **`SyncPriorityQueue<T>`** (`SyncPriorityQueue.cj`): concurrent priority queue ——
  `init(comparator, capacity, overSizePolicy)`, `create` / `createReverse`, `peek` / `remove` / `add`.
- **Other concurrent containers and utilities**: `ConcDict` (dictionary interface with default implementations for some methods), `ConcHashDict` (`toArray()` etc.),
  `ConcurrentHashSet`, `AtomicInteger` and `ExtendAtomic{Int8..UInt64}` (`fetchIncr` / `incrFetch` / `addFetch` …),
  `Constants.get<T>` (the key is `TypeInfo.of<T>() + key`; a type mismatch throws `TypeNotMatchException`).
- **Exceptions** (`exception/`): `ConcurrentException`, `LoadBalanceException`, `RateLimiterException`,
  `ReadWriteSyncerException`, `TimeoutException`; `RateLimiter` throws `RateLimiterException` when `timeout <= 0`, and
  `UnlimitedRateLimiter` uses `Duration.Max` internally.
- **Load balancing test cases**: `src/LoadBalance_test.cj` (equal weights 50/50, 2:1 → 67/33, 4:1 → 80/20, and two random modes).
