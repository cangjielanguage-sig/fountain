# f_pool

## Pool modes
```cj
package fountain::f_pool
public enum Mode{
  | Fifo     // First in first out, the default
  | Lifo     // Last in first out
  | WeakFifo // Weak-reference FIFO; pooled objects are held as weak references with the DEFERRED policy (**currently has no caller**)
  | WeakLifo // Weak-reference LIFO; pooled objects are held as weak references with the DEFERRED policy (**currently has no caller**)
}
```


## `Pool<T>`

```cj
//Pooled object manager
public interface ObjectManager<V> {
    func create(): V // Create an object
    func check(value: V): Bool // Check an object
    func destroy(value: V): Unit // Destroy an object
    func clear(value: V): Unit {} // Clear an object
}
public class PoolBuilder<V> {
    init(){}
    // Set the pooled object storage mode
    public func setMode(mode: Mode): This 
    // Set the initial pool size
    public func setInitSize(initSize: Int64): This 
    // Set the minimum pool size
    public func setMinSize(minSize: Int64): This 
    // Set the maximum pool size
    public func setMaxSize(maxSize: Int64): This 
    // Set the idle time of pooled objects
    public func setIdleTimeout(idleTimeout: Duration): This 
    // Set whether to check on creation
    public func setCheckOnCreation(checkOnCreation: Bool): This 
    // Set whether to check on borrowing
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This 
    // Set whether to check when a pooled object is given back
    public func setCheckOnReturning(checkOnReturning: Bool): This 
    // Set whether to clear when a pooled object is given back (the pool item is really emptied only when clear is non-empty)
    public func setClearOnReturning(clearOnReturning: Bool): This 
    // Set the pooled object check interval
    public func setCheckInterval(checkInterval: Duration): This 
    // Set the object creation function
    public func setCreator(creator: () -> V): This 
    // Set the object check function
    public func setChecker(checker: (V) -> Bool): This 
    // The object destruction function
    public func setDestroier(destroier: (V) -> Unit): This 
    // The object clearing function
    public func setClear(clear: (V) -> Unit): This 
    // The pooled object manager
    public func setManager(manager: ObjectManager<V>): This 
    // Create the pooled object manager
    public func build(): Pool<V>
}
public struct Pool<V> <: Resource {
    public init(
        mode!: Mode = Mode.Fifo, // Pooled object storage mode
        initSize!: Int64, // Initial pool size
        minSize!: Int64 = 0, // Minimum pool size
        maxSize!: Int64 = 10, // Maximum pool size
        idleTimeout!: Duration = Duration.hour, // Idle time of pooled objects
        checkOnCreation!: Bool = false, // Check on creation
        checkOnBorrowing!: Bool = true, // Check on borrowing
        checkOnReturning!: Bool = true, // Check on returning
        clearOnReturning!: Bool = false, // Clear on returning
        checkInterval!: Duration = Duration.minute, // Pooled object check interval
        creator!: () -> V, // Object creation function
        checker!: (V) -> Bool, // Check function
        destroier!: (V) -> Unit, // Destruction function
        clear!: (V) -> Unit = {_ =>} // Clearing function
    )
    public init(
        mode!: Mode = Mode.Fifo,
        initSize!: Int64,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        clearOnReturning!: Bool = false,
        checkInterval!: Duration = Duration.minute,
        manager!: ObjectManager<V>// Take creaator, checker, destroier and clear from the manager instance
    )
    // Create a pool builder
    public static func builder(): PoolBuilder<V>
    // Get an object; timeout is the timeout for getting an object, and a timeout <= Duration.Zero returns immediately without waiting
    public func get(timeout!: Duration = Duration.Max): ?V
    // Give an object back
    public func giveBack(value: V): Unit
}
```

> Three more things are not fully listed in the signatures above: `maxWaiting!: Duration = Duration.second * 30` (the waiting limit when
> `get()` uses the default `Duration.Max`; on timeout it logs a WARN and returns `None`; the builder counterpart is
> `setMaxWaiting(maxWaiting)`), `isClosed()` / `close()` (the `Resource` lifecycle), and `PoolException` (thrown when the builder
> has no `creator` / `checker` / `destroier`).

## `KeyPool<K, V> where K <: Hashable & Equatable<K>`
Each key corresponds to a pool; only pooled objects need to be destroyed, keys do not
```cj
// Key pool object manager
public interface KeyedObjectManager<K, V> {
    // Create an object
    func create(key: K): V
    // Check an object
    func check(key: K, value: V): Bool
    // Destroy an object
    func destroy(key: K, value: V): Unit
    // Clear an object
    func clear(key: K, value: V): Unit {}
}

public class KeyPoolBuilder<K, V> where K <: Hashable & Equatable<K> {
    init(){}
    // Set the pooled object storage mode
    public func setMode(mode: Mode): This 
    // Set the initial objects of the pool; a pool is created for each returned key, and as many objects as the key is returned are created in its pool
    public func setInitKeys(initKeys: () -> ?K): This 
    // Set the initial objects to add
    public func setinitKeys(initKeys: Iterable<K>): This
    // Each K value returned from keys creates initSizePerKey pooled objects; if keys returns the same K value several times, the initial number of pooled objects for that K is the repetition count * initSizePerKey
    public func setInitKeys(keys: Iterable<K>, initSizePerKey!: Int64 = 1)
    // Set the minimum number of pooled objects per key
    public func setMinSize(minSize: Int64): This 
    // Set the maximum number of pooled objects per key
    public func setMaxSize(maxSize: Int64): This 
    // Set the total number of objects of the whole pool; total and maxSize jointly affect the number of pooled objects
    public func setTotalSize(totalSize: Int64): This 
    // Set the idle time of pooled objects
    public func setIdleTimeout(idleTimeout: Duration): This 
    // Set whether to check when an object is created
    public func setCheckOnCreation(checkOnCreation: Bool): This 
    // Set whether to check on borrowing
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This 
    // Set whether to check when a pooled object is given back
    public func setCheckOnReturning(checkOnReturning: Bool): This 
    // Set whether to clear when a pooled object is given back
    public func setClearOnReturning(clearOnReturning: Bool): This 
    // Set the pooled object check interval
    public func setCheckInterval(checkInterval: Duration): This 
    // Set the object creation function
    public func setCreator(creator: (K) -> V): This 
    // Set the pooled object check function
    public func setChecker(checker: (K, V) -> Bool): This 
    // Set the object destruction function
    public func setDestroier(destroier: (K, V) -> Unit): This 
    // Set the pooled object clearing function
    public func setClear(clear: (K, V) -> Unit): This 
    // Set the pooled object manager
    public func setManager(manager: KeyedObjectManager<K, V>): This 
    // Create the pool
    public func build(): KeyPool<K, V> 
}

public class KeyPool<K, V> <: Resource where K <: Hashable & Equatable<K> {
    public KeyPool(
        mode!: Mode = Mode.Fifo, // Pooled object storage mode
        initKeys!: () -> ?K, // Initial pool objects; a pool is created for each returned key, and as many objects as the key is returned are created in its pool
        private let minSize!: Int64 = 0, // Minimum number per key
        private let maxSize!: Int64 = 10, // Maximum number per key
        private let totalSize!: Int64 = maxSize, // Total number of pooled objects; total and maxSize jointly affect the number of pooled objects
        private let idleTimeout!: Duration = Duration.hour, // Idle time of pooled objects
        private let checkOnCreation!: Bool = false, // Check on creation
        private let checkOnBorrowing!: Bool = true, // Check on borrowing
        private let checkOnReturning!: Bool = true, // Check on returning
        private let clearOnReturning!: Bool = false, // Clear on returning
        private let checkInterval!: Duration = Duration.minute, // Pooled object check interval (<= Duration.Zero or Duration.Max = no inspection, see below)
        private let creator!: (K) -> V, // Object creation function
        private let checker!: (K, V) -> Bool, // Check function
        private let destroier!: (K, V) -> Unit, // Destruction function
        private let clear!: (K, V) -> Unit = {_, _ =>} // Clearing function
    )
    public init(
        mode!: Mode = Mode.Fifo, // Pooled object storage mode
        initKeys!: () -> ?K, // Initial pool objects; a pool is created for each returned key, and as many objects as the key is returned are created in its pool
        minSize!: Int64 = 0, // Minimum number per key
        maxSize!: Int64 = 10, // Maximum number per key
        totalSize!: Int64 = maxSize, // Total number of pooled objects; total and maxSize jointly affect the number of pooled objects
        idleTimeout!: Duration = Duration.hour, // Idle time of pooled objects
        checkOnCreation!: Bool = false, // Check on creation
        checkOnBorrowing!: Bool = true, // Check on borrowing
        checkOnReturning!: Bool = true, // Check on returning
        clearOnReturning!: Bool = false, // Clear on returning
        checkInterval!: Duration = Duration.minute, // Pooled object check interval
        manager!: KeyedObjectManager<K, V> // Take creaator, checker, destroier and clear from the manager instance
    )
    // Create a pool builder
    public static func builder(): KeyPoolBuilder<K, V>
    // Get an object; timeout is the timeout for attempting to get an object, and a timeout <= Duration.Zero returns immediately without waiting
    public func get(key: K, timeout!: Duration = Duration.Max): ?V
    // Give an object back
    public func giveBack(key: K, object: V): Unit
    // Take out the pool of a key: close it and destroy its pool items first, then delete the key from the key table (a nonexistent key is a no-op)
    public func remove(key: K): Unit
}
```

> `giveBack(key: K, object: V)` throws `UnknownKeyException` when "this key never had a pool" (a wrong key, or giving an object
> borrowed under key A back to key B) (`fountain::f_pool.exception`, a subclass of `f_base.BaseException` with a `key` field):
> the pool **neither gives it back nor destroys it**, ownership of the object is still with the caller and the application layer decides
> what to do. When giving back from a cleanup path such as `finally` / `release()`, attach the suppressed exception with
> `addSuppressed` (do not lose the evidence):
> `catch (e: UnknownKeyException) { if (let Some(p) <- inFlight) { e.addSuppressed(p) }; throw e }`.
> The pools used inside this repository are all `Pool<V>` (the key is `Unit`, and there is only ever one key), so this path is never
> taken. See `.autocode/bugs/bug-pool.md` §2.5 `POOL-10`.
>
> A special value of `checkInterval`: **`<= Duration.Zero` (including `Duration.Zero`) or `Duration.Max` means no inspection is
> enabled** —— no inspection thread is started, and the pool then performs no `minSize` replenishment, no idle reclamation
> (`idleTimeout`) and no `audit()` self-healing.
> `Duration.Max` is equivalent to "never inspect" (previously it merely started a thread that slept on `sleep(Duration.Max)`,
> never woke up, and could not even be woken by closing the pool).
> For "very slow but still inspecting" pass a very large **finite** value (such as `Duration.hour`); such pools are woken up
> immediately and exit on `close()` and do not park for a whole period. The default `Duration.Zero` of `ArrayPool` /
> `ArrayListPool` and the default `Duration.Max` of `BytesListOutputStream.builder` both fall into this category. See §3 `POOL-L2`.
>
> Same rule: **an exception from `giveBack` means the object was not given back**. When `clearOnReturning = true` and the `clear`
> callback throws, `giveBack` throws `ClearFailedException` (also a subclass of `f_base.BaseException` with a `key` field, with the
> original callback exception attached to `suppressed`) —— no destruction, no accounting settlement, no entering the pool; the state
> of the pool item is as before `giveBack` was called and ownership is still with the caller: after fixing the condition you can
> **retry** `giveBack` (a successful retry settles the quota as usual), or destroy it yourself. See §2.7 `POOL-12`.
>
> `remove(key)` is for **actively reclaiming keys**: when the key cardinality is controlled by the application (users / sessions /
> files …), failing to reclaim makes the key table, the empty pool entries and the O(#keys) traversal of every inspection round a
> permanent cost (§2.6 `POOL-11`). Removing a key destroys only the items **inside the pool**; objects currently borrowed are still
> in the hands of the application, and after removal `giveBack(key, …)` throws `UnknownKeyException` —— those objects must be
> destroyed by the application layer itself.
> `close()` is **idempotent** and destroys the pools of all keys and empties the key table before returning; after shutdown `get`
> returns `None`, `giveBack` destroys directly, and the key table does not grow back. This pool layer no longer has `destroy` (the
> only destruction entry point is `close`).

## ArrayListPool

`ArrayListPool<T>` is a pool "whose pooled item type is fixed to `ArrayList<T>`": `creator` is fixed to `{=> ArrayList<T>()}` and it
has **no** `arraySize` / `creator` arguments (earlier documentation mistakenly copied the signature of `ArrayPool`).
The other arguments are the same as `ArrayPool` (`initSize` / `minSize` / `maxSize` / `elementLife` / `checkInterval` /
`clearOnReturning` / `maxWaiting`), and `giveBack` returns `Unit` (see `src/ArrayListPool.cj` for the signature).

## ArrayPool

The pooled items are **fixed-length arrays**: `arraySize` is the length of each array, and **giving back an array whose size differs
from `arraySize` throws `IllegalSizeException`** (`fountain::f_exception`, a subclass of `f_base.BaseException`, with the message
carrying the expected/actual sizes).
Throwing means the array **was not given back this time**: the array is still in the hands of the caller (the pool has no right to
destroy it), and the quota of the pool that lent it out is not settled either —— the give-back path is usually written in
`finally` / `release()`, so if it suppresses an exception that is being propagated, attach it with `addSuppressed` before
rethrowing. A mismatched size is an application-layer BUG (giving back a foreign array, or an array of a pool with a different
`arraySize`); see `.autocode/bugs/bug-pool.md` §3 `POOL-L7`.

```cj
// Pooled items are fixed-length arrays
ArrayPool<T>(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.Max,
        checkInterval!: Duration = Duration.Zero,
        clearOnReturning!: Bool = false,
        arraySize!: Int64 = 128,
        maxWaiting!: Duration = Duration.second * 30,
        creator!: () -> T = {=> unsafeZeroValue<T>()})
public func get(timeout!: Duration = Duration.Max): ?T
// Give the array back; a size different from arraySize throws IllegalSizeException (not given back this time, see above)
public func giveBack(array: Array<T>): Unit
```

## `maxWaiting`: the waiting limit when the pool is exhausted

`maxWaiting` is an **initialization argument of the pool** (`Pool` / `KeyPool` / `ArrayListPool` / `ArrayPool` /
`BytesListOutputStream.builder` all have it, `Duration.second * 30` by default; builders set it with `setMaxWaiting(maxWaiting)`);
its meaning is "how long `get()` is willing to wait when the pool is exhausted":

| `timeout` passed by the caller | Behavior |
| --- | --- |
| `<= Duration.Zero` | Do not wait: return `None` immediately when no idle item can be obtained |
| `Duration.Max` (the default) | Wait in a loop (`sleep(1ms)` per round, **no busy waiting**). On reaching the `maxWaiting` limit it logs the WARN `key pool exhausted but no idle element: size=…/…, keyedSize=…/…, waited …, give up` and returns `None`; the caller decides whether to retry or fail |
| Any other finite value | Wait for that duration and return `None` if nothing becomes available (the implementation is the third branch of `KeyPool.get`) |

Passing `Duration.Max` as `maxWaiting` itself means **truly waiting forever**: the implementation waits in fixed slices (which avoids
the overflow of `MonoTime + Duration.Max` and still lets it see changes of `running` in time).

> Where this constraint comes from: the original implementation busy-waited with `while(running)` when "the pool is full but no idle
> item can be obtained", occupying a whole core and **hanging the caller forever without any log** (see section six / §7.6 of
> `.autocode/bugs/bug-archived-on-20261004.md`). The test case `KeyPool_test.maxWaitingBoundsInfiniteWait` directly verifies that
> "an infinite wait must also be bounded by `maxWaiting`".

## The semantics of `clear` / `clearOnReturning` (`ObjectManager.clear` is an empty body by default)

- The `clear` of `ObjectManager<V>` / `KeyedObjectManager<K, V>` is an **empty implementation by default** (`{_ =>}` / `{_, _ =>}`) ——
  "clear on returning" is optional behavior and does nothing by default; for it to take effect `clear` must be given explicitly
  (or `clearOnReturning = true` with a non-empty `clear`);
- `setManager(manager)` wires up the `create` / `check` / `destroy` / `clear` of `manager` at once;
  when `Pool<V>` forwards to `KeyPool<Unit, V>` internally it **must** also pass `clear` down —— omitting it makes given-back pool
  items keep their old content, which once made `f_codec` produce "bytes of the previous message mixed into the encoding result ⇒
  displaced decoding on the peer ⇒ disconnect storm" (see section six of `.autocode/bugs/bug-archived-on-20261004.md`).

## Internal implementation: `BasePool<T>` / `BaseKeyPool<K, V>` (internal, not public API)

These two layers are the foundation of `Pool` / `KeyPool` (`BasePool` is in `fountain::f_pool.base` and is `protected package`;
`BaseKeyPool` has no `public`); they are listed to make troubleshooting easier:

- **`BasePool<T>`**: `add(value): Bool` (returns whether it entered the pool; `false` when the pool is already closed) / `giveBack` / `get(checker, destroier)` /
  `check(running, checker, taskPusher)` / `audit(): Int64` (active audit and self-healing, returning the number of corrective actions) /
  `close(destroier): Int64` (**close and empty**: set the closed flag first, then destroy the pool items one by one and return the
  number destroyed, which the caller uses to synchronize the global count; `destroy` has been removed, see §2.6 `POOL-11` of
  `.autocode/bugs/bug-pool.md`) / `prop size`;
  the four implementations are `FifoPool` (`insertTail` + `append`),
  `LifoPool` (`insertHead` + `prepend`) and `WeakFifoPool` / `WeakLifoPool` (weak reference queues).
  **`maxWaiting` is not here**: it only decides "how long the upper layer waits when no pool item can be obtained", which is the
  responsibility of the `get` of `Pool` / `KeyPool`.
- **`BaseKeyPool<K, V>`**: `map: ConcurrentHashMap<K, BasePool<V>>` + the global count `s`.
  `s` contains **both idle and borrowed items** (borrowing does not subtract from the queue count), so `s` and "the sum of the
  `size` of the queues of all keys" **should be equal at all times**; if they differ they are genuinely out of sync:
  - `add` / `giveBack` / `get(key, checker, destroier)` / `keyedSize(key)` / `entries()` / `size` / `keyCount()`;
  - `check(running, checker, taskPusher)`: inspect key by key (condition `p.size < max && checker(...)`);
  - `audit()`: let the queue of every key heal itself first, then correct `s` to the sum of the queues (the correction log is
    emitted uniformly as a WARN by the `KeyPool` inspection, so that the same correction is not printed twice);
  - `remove(key, fn)`: take out the pool of one key (`map.remove` first, then close and destroy the pool items), with
    `s.fetchSub(...)` over **all** items under that pool; a nonexistent key is a no-op (`POOL-11`);
  - `close(fn)`: `remove` key by key, and finally clear `s` to zero —— that is the only way to really empty the key table
    (`ConcurrentHashMap` has no `clear`, and after `running=false` neither `add` / `get` / `keyedSize` create pools on demand);
  - Accounting: `s` and "the sum of the `size` of the queues of all keys" should be equal at all times; if they are not
    synchronized, `size` reports a stale value and later `get` calls believe the pool is already full and stop creating pool
    items (see 7.2 of the archived report).
- The mapping from `Mode` to implementations: `Fifo` → `FifoPool`, `Lifo` → `LifoPool`, `WeakFifo` / `WeakLifo` → the corresponding
  weak reference implementations (currently no caller); when `K` is `Unit` `KeyPool` switches to the specialized `UnitKeyPool`
  (see the constructor of `KeyPool.cj`), and `IKeyPool<K, V>` is their common interface.

## Supplement: public surface not expanded in this README (the source code is authoritative)

- **`Releasable`** (`BytesCopier.cj`): `release()` must be **idempotent**, and is used to give borrowed pool items back;
- **Byte pools (the foundation of `f_codec` encoding buffers)**:
  - `BytesCopier <: BytesCopyTo & BytesCopyFrom` (`byteSize(): ?Int64`, `asBytes(): ?Array<Byte>`);
  - `PooledBufferBytesCopyTo` / `PooledBufferedBytesCopyFrom` (borrowing `ArrayPool<Byte>` for streaming copies);
  - `ChainedBytesCopyTo <: Releasable` (`release` cascades to its children);
  - `BytesListOutputStream` (`OutputStream & BytesCopyTo & Releasable`, `release()` idempotent, `isEmpty` / `reset`) and
    `BytesListOutputStream.builder(...)` / `BytesListOutputStreamBuilder.build(timeout!)`
    —— the counterparts of `setBytesPool(...)` of `f_codec` and the `rpc_codec*` configuration of `f_rpc`;
- **`PoolDiagnostics`** (`diagnostics/PoolDiagnostics.cj`): `snapshot()` / `dump()` / `redirectWarningsTo(...)` /
  `installCrashHandler(...)` / `uninstallCrashHandler()` / `CRASH_DUMP_ON_FATAL`, used together with `[FOUNTAIN_POOL.diag]`
  logging to collect evidence of pool anomalies;
- **Other implementations**: `BasePool` / `BaseKeyPool` / `UnitKeyPool` / `IKeyPool` —— see the "Internal implementation" section above;
- **Internal mechanisms (for troubleshooting)**: the accounting invariant of `SyncDeque` `size ≡ number of queue nodes + number of
  borrowed items`, the `DEQUE-SELFCHECK` check every 10000 operations, the `WEDGE-HEAL` self-healing when no pool item can be
  obtained (including restoring items stuck in CHECKING), the exception safety of `LinkedNode.check` and the value-taking path of
  `nextForGet` —— see the source code and `.autocode/bugs/bug-archived-on-20261004.md` (§7.2 / §7.3 / §7.4) for details.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `public func next(): ?Unit`
- `BytesListOutputStream`: `func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit`, `func write(bytes: Array<Byte>): Unit`
- `ChainedBytesCopyTo`: `func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit`
- `PooledBufferBytesCopyTo`: `func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit`
- `PooledBufferedBytesCopyFrom`: `func copy(from!: InputStream, closeFromOnEnd!: Bool = false, closeToOnEnd!: Bool = true): Unit`
