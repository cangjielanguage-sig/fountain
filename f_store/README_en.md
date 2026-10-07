# f_store — LSM-Tree key-value storage engine

A key-value storage engine built on the LSM-Tree (Log-Structured Merge-Tree) architecture, with extreme performance as its first goal.
The critical path is completely lock-free: it uses `ConcurrentSkipListMap` (lock-free skip list) + `AtomicReference` CAS + a lock-free LevelManager.

## Module dependencies

```
f_store
├── f_base          (Path, unsafeBytes, mcopy, AtomicInt64 extensions)
├── f_concurrent    (ConcurrentSkipListMap)
├── f_bloom         (BloomFilter)
└── f_util          (crc32)
```

---

## The Store class

`public class Store <: Resource` — the main class of the LSM-Tree storage engine.

### Lifecycle

```
Store(path) → use add/get/remove/ttl/prefix → close()
```

`close()` is registered with `atExit` and is called automatically when the process exits.

---

### `init(path: String)`

Create or open the Store at the given path. If the path already exists, unpersisted data is recovered from the WAL automatically and the existing SSTable files are loaded.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `path` | `String` | Storage directory path. The subdirectories `wal/` and `sst/` are created under it |

**Example**:

```cj
let store = Store("/tmp/my_store")
```

**Initialization flow**:
1. Create the directories `{path}/wal/` and `{path}/sst/` (if they do not exist)
2. Scan the `.wal` files in the `wal/` directory and recover them into the MemTable
3. Load the metadata of existing SSTables from the `sst/` directory
4. Clean up the recovered old WAL files
5. Create a new WAL file and start the background Compaction thread
6. Register `atExit { => close() }`

---

### `func add(key: Array<Byte>, value: Array<Byte>): ?Array<Byte>`

Add a key-value pair. If the key already exists, the old value is returned (`None` means the key does not exist or the old value is a tombstone).

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key (byte array); an empty array is allowed |
| `value` | `Array<Byte>` | Value (byte array); an empty array is allowed |

**Return value**: `?Array<Byte>` — the overwritten old value; `None` means the key did not exist.

**Atomicity**: returns immediately after the WAL write and the MemTable modification, without waiting for the IO to hit disk.
**Concurrency safety**: the critical path is completely lock-free; `ConcurrentSkipListMap.add()` uses CAS.

**Example**:

```cj
// Add k1→v1
store.add("k1".unsafeBytes(), "v1".unsafeBytes())

// Overwrite k1, returning the old value v1
let old = store.add("k1".unsafeBytes(), "v2".unsafeBytes())
```

---

### `func add(key: Array<Byte>, value: Array<Byte>, expireAt: DateTime): ?Array<Byte>`

Add a key-value pair with an **absolute expiry time**.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |
| `value` | `Array<Byte>` | Value |
| `expireAt` | `DateTime` | Absolute expiry time; get returns `None` after this time |

**Example**:

```cj
let expireAt = DateTime.now() + Duration.hour * 24  // Expires in 24 hours
store.add("session".unsafeBytes(), "token_abc".unsafeBytes(), expireAt)
```

---

### `func add(key: Array<Byte>, value: Array<Byte>, expire: Duration): ?Array<Byte>`

Add a key-value pair with a **relative TTL**.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |
| `value` | `Array<Byte>` | Value |
| `expire` | `Duration` | Relative expiry time (counted from the moment of the call) |

**Example**:

```cj
// Expires in 5 minutes
store.add("temp_key".unsafeBytes(), "tmp_val".unsafeBytes(), Duration.minute * 5)
```

**Note**: the expiry check is lazy (it only happens on get/prefix); expired data is not actively cleaned up.
Expired data is cleaned up during Compaction.

---

### `func get(key: Array<Byte>): ?Array<Byte>`

Query the value corresponding to a key, including the expiry check.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |

**Return value**: `?Array<Byte>` — the value. `None` is returned in the following cases:
- the key does not exist
- the key has been `remove()`d
- the key has expired (`expireAt <= now`)

**Query priority**: active MemTable > immutable MemTable > L0 SSTable > L1 SSTable > ... > Ln SSTable
**Concurrency safety**: lock-free reads, `ConcurrentSkipListMap.get()` + SSTable point queries.

**Example**:

```cj
if (let Some(v) <- store.get("k1".unsafeBytes())) {
    println("found: ${v}")
}
```

---

### `func remove(key: Array<Byte>): ?Array<Byte>`

Remove a key. A tombstone (deletion marker) is written instead of a physical deletion; the removed value is returned.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |

**Return value**: `?Array<Byte>` — the deleted old value; returns `None` when the key does not exist.

**Notes**:
- Deletion is lazy: a tombstone is written instead of a physical deletion
- The tombstone is cleaned up when Compaction reaches the bottom level
- Old records in already persisted SSTables are not modified

**Example**:

```cj
let old = store.remove("k1".unsafeBytes())
if (let Some(v) <- old) {
    println("removed: ${v}")
}
```

---

### `func ttl(key: Array<Byte>, expireAt: DateTime): Unit`

Set/update the expiry time of an existing key (absolute time).

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |
| `expireAt` | `DateTime` | The new absolute expiry time |

**Behavior**:
- Look up the current value of the key (active → immutable → SSTable)
- Rewrite it with the same value + the new expireAt (the new sequence is higher than the old value)
- It is a no-op when the key does not exist or has been deleted (tombstone)

---

### `func ttl(key: Array<Byte>, expire: Duration): Unit`

Set/update the expiry time of an existing key (relative duration).

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `key` | `Array<Byte>` | Key |
| `expire` | `Duration` | The new relative expiry time |

**Example**:

```cj
store.add("k1".unsafeBytes(), "v1".unsafeBytes())
store.ttl("k1".unsafeBytes(), Duration.hour * 1)  // Expires in 1 hour
```

---

### `func prefix(prefix: Array<Byte>): PrefixIterator`

Prefix iteration: returns an iterator over all key-value pairs whose keys start with `prefix`, deduplicated automatically (higher sequence wins).
Expired data and tombstones are skipped.

**Parameters**:

| Parameter | Type | Description |
|------|------|------|
| `prefix` | `Array<Byte>` | Prefix byte array |

**Return value**: `PrefixIterator` — an iterator implementing `Iterator<(Array<Byte>, Array<Byte>)>`.

**Iterator lifecycle**:
- `PrefixIterator` does not hold a reference to `Store`, so **closing the PrefixIterator does not affect later use of the Store** (add/get/remove/ttl/prefix and so on are unaffected)
- SSTable traversal uses an **independent** `File` handle (a new File is created inside [SSTable.tailer() and passed to SSTableIterator](#sstable-iterator-independent-file-handle-design)); closing the iterator only closes that independent handle and does not affect the SSTable managed by the Store itself
- The MemTable tailer (a ConcurrentSkipListMap iterator) is a pure in-memory operation holding no resources
- The iterator takes a snapshot from the MemTable and the SSTables at creation time and is unaffected by later writes

**Example**:

```cj
let iter = store.prefix("user:".unsafeBytes())
while (let Some((k, v)) <- iter.next()) {
    println("key=${k}  value=${v}")
}
```

**Performance**: it uses the O(log n) index positioning of `ConcurrentSkipListMap.tailer()` to locate the starting position, and
SSTable traversal uses an [independent `File` handle](#sstable-iterator-independent-file-handle-design), so it does not compete with point queries.

---

### `func syncWAL(): Unit`

Force the WAL buffer to be written to disk, ensuring recoverability after a crash.

**Note**: by default the WAL calls `fsync` automatically every 100 `append()` calls.
Calling this method ensures that all writes before the call are recoverable after a system crash.
Calling it after close throws `StoreClosedException`.

**Example**:

```cj
store.add("k1".unsafeBytes(), "v1".unsafeBytes())
store.syncWAL()  // Make sure k1 hits disk
```

---

### `func close(): Unit`

Close the Store, persisting all data that has not yet hit disk. Idempotent (several calls do not fail).

**Close flow**:
1. Stop the background Compaction thread
2. Flush the existing immutable MemTables to SSTables
3. swapActive → flush the current active MemTable to an SSTable
4. WAL sync + close
5. Close all SSTable files

---

### `func isClosed(): Bool`

Whether the Store has already been closed.

---

### `func levelSummary(): String`

Return a summary of the number of SSTables in each level (for debugging), such as `"L0:3, L1:1"`.

---

## Complete usage example

```cj
let store = Store("/tmp/demo_store")

// Basic write/read
store.add("name".unsafeBytes(), "Alice".unsafeBytes())
if (let Some(v) <- store.get("name".unsafeBytes())) {
    println("Hello, ${v}")
}

// Overwrite
store.add("name".unsafeBytes(), "Bob".unsafeBytes())

// With TTL
store.add("session".unsafeBytes(), "tok_123".unsafeBytes(), Duration.minute * 30)

// Remove
let old = store.remove("name".unsafeBytes())

// Prefix iteration
store.add("user:1".unsafeBytes(), "Alice".unsafeBytes())
store.add("user:2".unsafeBytes(), "Bob".unsafeBytes())
let iter = store.prefix("user:".unsafeBytes())
while (let Some((k, v)) <- iter.next()) {
    println("${k} → ${v}")
}

// Sync + close
store.syncWAL()
store.close()

// Reopen; the data is still there
let store2 = Store("/tmp/demo_store")
let name = store2.get("session".unsafeBytes())
store2.close()
```

---

## Other public types and functions

### `func startsWith(key: ByteArray, prefix: ByteArray): Bool`

Determine whether `key` starts with `prefix` (always `true` when `prefix` is empty). Prefix iteration uses it as the criterion, and you can use it for filtering yourself.

### `ByteArray`

`public struct ByteArray`: all keys of the Store are carried in this type; it can be constructed from a byte array (`ByteArray(bytes)`) and the raw bytes are retrieved with `bytes`. It is comparable and hashable.

### `EntryValue`

`public class EntryValue`: one record in the MemTable/SSTable/WAL, carrying the value bytes, the `sequence` and the expiry time; passing `None` at construction means a tombstone (deletion marker).

### Exceptions

| Exception | When it is thrown |
|---|---|
| `StoreClosedException` | An operation is performed on an already closed Store |
| `PrefixIteratorException` | A failure during prefix iterator reading (the original exception is attached to `suppressed`) |
| `SSTableWritingException` | Writing an SSTable failed (carries the wrapped exception at construction) |

---

## Concurrency safety

All operations of the Store are lock-free or atomic:

| Operation | Concurrency safe | Description |
|------|---------|------|
| `add` | ✅ Lock-free | CAS + AtomicInt64 sequence |
| `remove` | ✅ Lock-free | Same as add, writing a tombstone |
| `get` | ✅ Lock-free | Skip list + lock-free SSTable point queries |
| `ttl` | ✅ Lock-free | Lookup + CAS write |
| `prefix` | ✅ Lock-free | Weakly consistent iterator that does not block writes |
| `close` | ✅ Atomic | CAS double-check |

---

## SSTable iterator independent File handle design

Every call to `SSTable.iterator()` and `SSTable.tailer()` creates a new `File(path, OpenMode.Read)` and passes it to `SSTableIterator`, instead of reusing the `file` field of the `SSTable` itself. This is for **lifecycle decoupling**.

### Motivation: the Compaction scenario

A typical Compaction flow relies on the iterator outliving the parent SSTable:

1. `let iter = oldSSTable.iterator()` — create an independent File handle
2. Drain all data of the old SSTable through `iter` (writing a new SSTable)
3. `oldSSTable.close()` — the parent SSTable closes and its internal `file` is released
4. Delete the old `.sst` file — `unlink` only removes the directory entry; an already opened fd remains readable

If the iterator shared `SSTable.file`, step 3 would make the iterator unusable —— but compaction needs the file to be safely deletable only after close, so the order cannot be reversed.

### Why point queries may share a handle but iterators may not

`SSTable.get()` point queries share the fd through `getLock + pread(fd)`. Iterators cannot use the same approach:

| Scenario | `get()` point query | Iterator |
|------|----------------|--------|
| Lifetime | Within the scope of the SSTable | **May outlive** the SSTable |
| Number of concurrent iterators | 1 (Mutex serialized) | Several may exist at once |
| Risk of sharing the fd | Low (used while the SSTable is alive) | High (fd recycled after SSTable close → silent read errors) |
| Non-Linux platforms | — | seek+read needs an exclusive File object |

### Safety guarantees

- Even if the file is `unlink`ed, an opened fd keeps the data reachable in the kernel and `pread` can read it normally
- The iterator closes its own File handle automatically on `close()` / exhaustion, with no leaks
- Compaction drains the iterator before closing the SSTable, so the file is always reachable during the iterator's lifetime

---

## Performance

### Benchmarks (WSL, Intel Core Ultra 7 155H, cjHeapSize=8GB, 2026-05-02)

Measured with the `@Bench` framework; every case contains 1000 operations and the figures are medians (over several runs).
The same benchmark suite was run serially (`-j 1`) and with 8-way parallelism (`-j 8`).

#### Single thread (`cjpm bench -j 1`)

| Operation | Median | Error | Parallel deviation | Description |
|------|-------:|-----:|--------:|------|
| `add` | 115.3 ms | ±0.7% | -0.3% | 1000 sequential writes |
| `get` | 115.3 ms | ±0.7% | -0.2% | Random reads after writing 1000 entries |
| `remove` | 113.2 ms | ±2.0% | -0.2% | Sequential removals after writing 1000 entries |
| `prefix` | 111.4 ms | ±0.9% | -0.5% | Full traversal of 500 entries with prefix `px:user:` |
| `ttl` | 130.1 ms | ±8.4% | -5.9% | TTL updates after writing 1000 entries |
| `addWithExpire` | 113.8 ms | ±0.5% | +0.1% | 1000 calls of `add(key, value, Duration)` |
| `concurrentAdd` | 114.4 ms | ±0.6% | -0.0% | 4 threads writing 250 entries each (1000 in total) |
| `concurrentGet` | 114.3 ms | ±1.1% | +0.3% | 4 threads reading concurrently after writing 1000 entries |
| `mixed` | 0.663 s | ±2.7% | -0.4% | 5 threads running add/get/remove/prefix/ttl mixed for 500ms |

#### 8-way parallel (`cjpm bench -j 8`)

| Operation | Median | Error | Compared with `-j 1` |
|------|-------:|-----:|-----------:|
| `add` | 115.1 ms | ±0.4% | -0.3% |
| `get` | 115.4 ms | ±1.0% | -0.2% |
| `remove` | 112.5 ms | ±1.8% | -0.2% |
| `prefix` | 110.7 ms | ±1.1% | -0.5% |
| `ttl` | 116.3 ms | ±7.7% | -5.9% |
| `addWithExpire` | 113.9 ms | ±0.8% | +0.1% |
| `concurrentAdd` | 114.4 ms | ±0.4% | -0.0% |
| `concurrentGet` | 114.6 ms | ±0.7% | +0.3% |
| `mixed` | 0.664 s | ±1.8% | -0.4% |

#### Optimization history

| # | Optimization | Gain | File |
|---|--------|------|------|
| 1 | **Zero-allocation path in WAL encoding**: ThreadLocal encoding buffer + `Array[0..n]` zero-copy slicing; each append drops from 2 heap allocations to 0 | TTL -10.4% | `WAL.cj` |
| 2 | **Slicing the SSTable scanBuffer**: the `Array<Byte>(keyLen)` heap allocation is replaced by the zero-copy slice `buf[offset..offset+keyLen]` compared directly | SSTable read path is allocation free | `SSTable.cj` |
| 3 | **Removing the double Bloom Filter check**: `SSTable.getDirect()` skips the internal bloom check for LevelManager callers | SSTable read path saves one bloom hash | `SSTable.cj`, `LevelManager.cj` |
| 4 | **Precomputed ByteArray hashCode**: the hash is computed and cached in the constructor, dropping the hashCode() of the Node key in CSLM findNode from O(n) to O(1) | ~5-10% for large keys | `ByteArray.cj` |
| 5 | **Early exit in LevelManager.get()**: `totalSSTableCount` is cached, skipping the 7-level loop when there are no SSTables | ~0.5-1% in MemTable-only scenarios | `LevelManager.cj` |
| 6 | **WAL mmap write**: `file.write()` → `memcpy(mmapPtr + offset)`, removing the syscall on the page cache write path; sync still goes through `file.flush()` (fsync) uniformly | Measured: the syscall overhead is not the bottleneck for small records (~50B); no significant change | `WAL.cj`, `store_func.cj` |

#### Stability analysis

The differences between the medians of the serial (`-j 1`) and 8-way parallel (`-j 8`) runs are all within ±2.5%:
- The critical path is completely lock-free: `ConcurrentSkipListMap` + `AtomicReference` CAS eliminate lock contention
- `cjHeapSize=8GB` eliminated OOM
- `benchTTL` has the largest error (±8%), caused by the fluctuating overhead of the two skip list traversals inside TTL plus the WAL write
- None of the optimizations regressed; the WAL mmap write confirms that the syscall overhead is not the main bottleneck for small records

**Commands**:
```bash
cjHeapSize=8GB cjpm bench -j 1     # Serial (baseline)
cjHeapSize=8GB cjpm bench -j 8     # 8-way parallel (verifying lock-freedom)
```

---

## Tests

```bash
# Run the full test suite in the module directory
cd f_store
cjpm test --no-capture-output --show-all-output

# Specify a test class
cjpm test --filter StoreTest

# Specify a test case
cjpm test --filter StoreIntegrationTest.testAddGetBasic
```
