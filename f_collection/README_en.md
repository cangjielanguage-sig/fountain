# f_collection


## BitSet

Bit set
```cj
//Instantiate a 64-bit bit set
public init()
//Instantiate a bit set of 64 * capacity bits
public init(capacity: Int64)
//Copy the argument into a new bit set
public init(set: BitSet)
//The current number of bits
public prop size: Int64
//The returned iterator iterates over every bit; a bit that is 1 yields Some(true), otherwise Some(false)
public func iterator(): Iterator<Bool>
//Whether the hash of the argument is present in the current bit set
public func contains<T>(value: T): Bool where T <: Hashable
//Store the hash of the argument in the current bit set
public func set<T>(value: T): Bool where T <: Hashable
//Remove the hash of the argument from the current bit set
public func remove<T>(value: T): Bool where T <: Hashable
//Return whether the current bit set holds index
public operator func [](index: UInt32): Bool
public operator func [](index: Int32): Bool
public operator func [](index: UInt64): Bool
public operator func [](index: Int64): Bool
//Set the value at the given index to value
public operator func [](index: UInt32, value!: Bool): Unit
public operator func [](index: Int32, value!: Bool): Unit
public operator func [](index: UInt64, value!: Bool): Unit
public operator func [](index: Int64, value!: Bool): Unit
//Bitwise-OR the bit at the given index with 1, and set the value to the result
public operator func |(index: UInt32): Bool
public operator func |(index: Int32): Bool
public operator func |(index: UInt64): Bool
public operator func |(index: Int64): Bool
//Bitwise-AND the bit at the given index with 1, and set the value to the result
public operator func &(index: UInt32): Bool
public operator func &(index: Int32): Bool
public operator func &(index: UInt64): Bool
public operator func &(index: Int64): Bool
//Bitwise-XOR the bit at the given index with 1, and set the value to the result
public operator func ^(index: UInt32): Bool
public operator func ^(index: Int32): Bool
public operator func ^(index: UInt64): Bool
public operator func ^(index: Int64): Bool
```

## `Dict<K, V>`

An interface that implements key-value storage even when the key implements neither `Hashable & Equatable<K>` nor `Comparable<K>`
```cj
import std.collection.MapEntryView

public interface Dict<K, V> <: Collection<(K, V)> {
    
    /**
     * Get the value mapped by key in the Map
     * Parameter key - pass the key and get the value
     * Return value Option<V> - the value corresponding to the key is wrapped in Option
     */
    func get(key: K): Option<V> 

    /**
     * Check whether the mapping of the given key is contained
     * Parameter key - pass the key to check
     * Return value Bool - true if it exists, false otherwise
     */
    func contains(key: K): Bool 

    /**
     * Check whether the mappings of the given keys are contained
     * Parameter keys - pass the keys to check
     * Return value Bool - true if they exist, false otherwise
     */
    func contains(all!: Collection<K>): Bool 

    /**
     * Associate the given value with the given key in this map
           120
     * If the map previously contained a mapping for the key, the old value is replaced
     * Parameter key - the key to put
     * Parameter value - the value to assign
     * Return value Option<V> - if the key existed before the assignment, the old value is wrapped in Option;
     * otherwise Option<V>.None is returned
     */
    func add(key: K, value: V): Option<V> 

    /**
     * Pass the given elements for traversal and assign them in order
     * If the map previously contained a mapping for the key, the old value is replaced
     * Parameter element - the elements passed for traversal and assignment
     */
    func add(all!: Collection<(K, V)>): Unit 
    func addIfAbsent(key: K, value: V): ?V 
    func replace(key: K, value: V): ?V 

    /**
     * Remove the mapping of the given key from this map (if present)
     * Parameter key - the key to remove
     * Return value Option<V> - the V of the removed mapping is wrapped in Option
     */
    func remove(key: K): Option<V> 

    /**
     * Remove the mappings of the given collection from this map (if present)
     * Parameter all - the collection to remove
     */
    func remove(all!: Collection<K>): Unit 
    /**
     * Pass a lambda expression; when the condition is satisfied, delete the corresponding key-value entry
     * Parameter predicate - a lambda expression used for the check
     */
    func removeIf(predicate: (K, V) -> Bool): Unit 
    /**
     * Clear all key-value pairs
     */
    func clear(): Unit 

    /**
     * Operator overload collection; if the key exists, return the value corresponding to the key, otherwise throw
     * Parameter key - pass the value to check
     * Return value V - the value corresponding to the key
     */
    operator func [](key: K): V 

    /**
     * Operator overload collection; if the key exists, the new value overwrites the old one, and if the key does not
     * exist, this key-value pair is added
     * Parameter key - pass the value to check
     * Parameter value - pass the value to set
     */
    operator func [](key: K, value!: V): Unit 

    /**
     * Return all keys in the Map, stored in a Keys container
     * Return value Keys<K> - holds all the returned keys
     */
    func keys(): Collection<K> 

    /**
     * Return all values in the Map, stored in a Values container
     * Return value Values<V> - holds all the returned values
     */
    func values(): Collection<V> 

    /**
     * Return the number of all elements in the Map
     * Return value Int64 - the number of elements
     */
    prop size: Int64 

    /**
     * Check whether the Map is empty
     * Return value Bool - true if so, false otherwise
     */
    func isEmpty(): Bool 

    /**
     * Return the iterator of the Map
     * Return value Iterator<(K,V)> - the iterator of the Map
     */
    func iterator(): Iterator<(K, V)> 
    func entryView(k: K): MapEntryView<K, V> 
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        let entry = this.entryView(key)
        let value = fn(entry.key, entry.value)
        entry.value = value
        value
    }
    func addIfAbsent(key: K, fn: () -> V): V {
        let view = entryView(key)
        if (let Some(v) <- view.value) {
            v
        } else {
            let v = fn()
            view.value = v
            v
        }
    }
    func addIfPreset(key: K, fn: () -> V): ?V {
        let view = entryView(key)
        if (let Some(_) <- view.value) {
            let v = fn()
            view.value = v
            v
        } else {
            None<V>
        }
    }
    func removeIf(key: K, predicate: (V) -> Bool): ?V {
        let view = entryView(key)
        if (let Some(v) <- view.value && predicate(v)) {
            view.value = None<V>
            v
        } else {
            None<V>
        }
    }
}
```

## `HashDict<K, V> <: Dict<K, V>

```cj
//Hash dictionary
public class HashDict<K, V> <: Dict<K, V> {
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * elements is used to initialize and fill the HashDict
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * The initial capacity is size
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * The initial capacity is size,
     * initElement returns the key-value pairs for initialization; the argument ranges over 0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool) 
}
```

## LinkedHashDict

```cj
/**A dictionary iterated in most-recently-accessed order*/
public class LinkedHashDict<K, V> <: Dict<K, V> {
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * elements is used to initialize and fill the HashDict
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * The initial capacity is size
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher computes the hash of K, equals compares whether two K are equal
     * The initial capacity is size,
     * initElement returns the key-value pairs for initialization; the argument ranges over 0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool) 
}
```

## TreeDict

```cj
/**A sorted tree dictionary compared with the given comparison function*/
public class LinkedHashDict<K, V> <: Dict<K, V> {
    /**
     * Instantiate the dictionary with the given comparison function
     */
    public TreeDict(private let cmp: (K, K) -> Ordering)
    /**
     * Instantiate the dictionary with elements as the initial elements and the given comparison function
     */
    public init(elements: Array<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * Instantiate the dictionary with elements as the initial elements and the given comparison function
     */
    public init(elements: Collection<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * Instantiate the dictionary with the given comparison function; the initial capacity is size and initElement returns the
     * key-value pairs for initialization, with the argument ranging over 0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), cmp: (K, K) -> Ordering)
}
```

## LinkedHashMap

```cj
/**
 * A HashMap iterated in most-recently-accessed order
 */
public class LinkedHashMap<K, V> <: Map<K, V> where K <: Hashable & Equatable<K> {
    /**
     * No maximum capacity is set
     */
    public init()
    /**
     * size is the initial capacity; if max is true, size is also the maximum capacity
     */
    public init(size: Int64, max: Bool)
    /**
     * Add the elements of c to a new LinkedHashMap
     */
    public init(c: Collection<(K, V)>)
    /**
     * Add the elements of c to a new LinkedHashMap
     * size is the initial capacity; if max is true, size is also the maximum capacity
     */
    public init(c: Collection<(K, V)>, size: Int64, max: Bool)
    /**
     * size is the initial capacity; if max is true, size is also the maximum capacity
     * Fill the new LinkedHashMap with the return values of initElement; the argument ranges over 0..size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V))
}
```

## `ValueEqualMap<K, V>` and `ValueContainsMap<K, V>`

These are two interfaces; every Map implementation and ConcurrentHashMap can be extended with them
```cj
public interface Values<V> {
    func values(): Collection<V>
}
public interface ValueContainsMap<K, V> <: Values<V> where K <: Equatable<K> {
    /**
     * Check whether the current Map contains a value for which predicate returns true
     */
    func containsValue(predicate: (V) -> Bool): Bool
}
public interface ValueEqualMap<K, V> <: Values<V> where K <: Equatable<K>, V <: Equal<V> {
    /**
     * Check whether the current Map contains a value equal to value
     */
    func containsValue(value: V): Bool
}
```


## LinkedHashSet

```cj
/**
 * A HashSet iterated in most-recently-accessed order
 */
public class LinkedHashSet<T> <: Set<T> where T <: Hashable & Equatable<T> {
    /**
     * An empty set initialized by default
     */
    public init() 
    /**
     * Fill a new LinkedHashSet with elements
     */
    public init(elements: Collection<T>) 
    /**
     * Fill a new LinkedHashSet with elements
     */
    public init(elements: Array<T>) 
    /**
     * The initial capacity of the new LinkedHashSet is size,
     * and the return values of initElement are used to fill it, with the argument ranging over 0..size
     */
    public init(size: Int64, initElement: (Int64) -> T) 
}
```


## Extension interfaces and node types

| Type | Description |
|---|---|
| `ExtendCollection` / `ExtendList` / `ExtendMap` / `ExtendNonConcurrentMap` | Common contracts of collection extensions (`src/ExtendCollection.cj`) |
| `Values` | Value collection interface (`src/ValueEqualMap.cj`) |
| `Growable` | Growable contract (`src/Growable.cj`) |
| `LinkedNode` family: `LinkedNodeIterator`, `Node`, `NoneNode`, `HeadNode`, `TailNode`, `ValueNode` | Linked list nodes and iterators (`src/LinkedNode.cj`) |

## PriorityQueue

Priority queue that grows automatically when it is full
```cj
public class PriorityQueue<T> <: Queue<T> & Iterable<T> & Collection<T> & Growable {
    /**
     * comparator Element comparator
     * capacity Initial capacity
     * overSizePolicy Overflow rejection policy, fountain::f_base.OverSizePolicy
     */
    public PriorityQueue(
        private let comparator: (T, T) -> Ordering,
        private var capacity!: Int64 = DEFAULT_CAPACITY,
        private let overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public init(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public static func create<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func createReverse<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func create(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T>
    /**
     * current size
     */
    public prop size: Int64
    public func isEmpty(): Bool
    /**
     * add an element
     */
    public func add(x: T): Unit
    /**
     * Grow
     */
    public func grow(): Unit
    /**
     * offer all elements in values to current queue
     */
    public func add(all!: Collection<T>): Unit
    /**
     * is current heap full? if capacity is not greater than 0, heap is infinity
     */
    private func isFull(): Bool
    /**
     * get element on top
     */
    public func peek(): Option<T>
    /**
     * get and remove element on top
     */
    public func remove(): Option<T>
    public func iterator(): Iterator<T>
    public func removeIf(predicate: (T) -> Bool): Unit
    public func toArray(): Array<T>
}
```


## `SetOp<T>`

Every Set implementation is extended with this interface
```cj
public interface SetOp<T> {
    /**
     * Return an intersection view of two Sets
     */
    func intersection<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * Return a union view of two Sets
     */
    func union<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * Return a difference view of two Sets
     */
    func difference<C>(collection: C): Set<T> where C <: Collection<T>
}
```


## `DifferenceSetView<T> <: Set<T>`

Read-only difference view

## `IntersectionSetView<T> <: Set<T>`

Read-only intersection view

## `UnionSetView<T> <: Set<T>`

Read-only union view

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `BitSet` (class), `ComparableKey` (struct), `ConcurrentHashMapValues` (class), `GrowSizePolicy` (class), `HashKey` (struct), `public class HashKeyMapEntryView<K, V> <: MapEntryView<K, V>`, `public class LinkedHashKeyMapEntryView<K, V> <: MapEntryView<K, V>`, `LinkedHashMapEntryView` (class), `public func retain(set: Set<T>): Unit`
- `ComparableKey`: `func compare(that: K): Ordering`
- `DifferenceSetView`: `clone` (func), `retain` (func), `subsetOf` (func)
- `GrowSizePolicy`: `func reject(o: C, fn: () -> Unit): Unit`
- `HashKey`: `func hashCode(): Int64`
- `HeadNode`: `func insertNext(value: T): ValueNode<T>`, `func removeNext(): Option<T>`, `func reset(tail: TailNode<T>): Unit`
- `IntersectionSetView`: `clone` (func), `retain` (func), `subsetOf` (func)
- `LinkedHashMap`: `clone` (func), `func firstEntry(): Option<(K, V)>`, `func lastEntry(): Option<(K, V)>`, `func pollFirstEntry(): Option<(K, V)>`, `func pollLastEntry(): Option<(K, V)>`
- `LinkedHashSet`: `func clone(): Set<T>`, `prop first: ?T`, `prop last: ?T`, `func removeFirst(): ?T`, `func removeLast(): ?T`, `func retain(all!: Set<T>): Unit`, `func retainAll(elements: Set<T>): Unit`, `func subsetOf(other: ReadOnlySet<T>): Bool`
- `LinkedNodeIterator`: `next` (func)
- `TailNode`: `func insertPrev(value: T): ValueNode<T>`, `func removePrev(): Option<T>`
- `TreeDict`: `prop first: ?(K, V)`, `func forward(mark: K, inclusive!: Bool = true): Iterator<(K, V)>`, `prop last: ?(K, V)`, `func removeFirst(): ?(K, V)`, `func removeLast(): ?(K, V)`
- `UnionSetView`: `clone` (func), `retain` (func), `subsetOf` (func)
- `ValueNode`: `func removeNext(): Option<T>`, `func removePrev(): Option<T>`, `func turnTo(node: HeadNode<T>): Unit`
