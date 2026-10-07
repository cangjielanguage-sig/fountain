# f_bloom

`fountain::f_bloom` provides a Bloom Filter implementation

---

## BloomFilter

A Bloom filter is a space-efficient probabilistic data structure used to tell whether an element may exist in a set.

### Features

- **High space efficiency**: it stores data in a bit array, using far less memory than a traditional set
- **May produce false positives**: if the element does not exist, it always returns false; if it exists, it may return true (false positive)
- **Lock-free concurrency safety**: it uses `AtomicUInt64` for lock-free writes and is safe across threads
- **Automatic parameter optimization**: it automatically computes the optimal bit array size and number of hash functions from the expected number of elements and the false positive rate

### Core parameters

| Parameter | Description |
|------|------|
| `n` | Expected number of elements |
| `p` | Desired false positive rate (0 < p < 1) |
| `m` | Bit array size (computed automatically, `bitCount`) |
| `k` | Number of hash functions (computed automatically, the number of `seeds`) |

### Constructors

```cj
// Create with a random seed
let filter = BloomFilter.new(1000000, 0.01) // 1 million expected elements, 1% false positive rate

// Create with custom seeds (for persistence or distributed scenarios)
let seeds = Array<UInt64>(k){i => ... }
let filter = BloomFilter.new(1000000, 0.01, seeds)
```

### Main methods

```cj
// Add an element
filter.add("hello")          // Add a String
filter.add(someByteArray)    // Add an Array<Byte>
filter.add(someToString)     // Add an object implementing ToString
filter.add(someHashable)     // Add an object implementing Hashable

// Query an element
let exists = filter.mightContain("hello")  // Returns Bool

// Persistence: the seeds are serialized together with the data
let bytes = filter.serialize()
let restored = BloomFilter.deserialize(bytes)
```

Public members: `n`, `p` (recorded values), `bitCount` (bit array length), `seeds` (iterator over the hash seeds), `new(n, p)`, `new(n, p, seeds)`, the 4 overloads of `add`/`mightContain`, `serialize()`, `deserialize(bytes)`.

### Notes

- A Bloom filter does not support deletion
- The lower the false positive rate, the more memory is required
- When the number of elements exceeds the expectation, the false positive rate goes up
- **The seeds of `new(n, p)` are randomly generated**: when multiple instances must agree or the result must be consistent across processes, you must use `new(n, p, seeds)` or `deserialize` (`seeds` are carried back with the serialized data).
- **`deserialize` silently falls back on dirty data**: when the data is too short or the bit array is out of bounds it returns `BloomFilter.new(1, 0.01)` instead of throwing.
- **Different overloads use different hashing rules**: the `Hashable` overload only builds and looks up by the 8-byte `hashCode()`, and is not interchangeable with the `String`/`ToString`/`Array<Byte>` overloads; do not mix overloads for the same logical element.
- `f_store` uses it to suppress the read amplification of SSTable/L0.
