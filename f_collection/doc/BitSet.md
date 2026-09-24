## BitSet
位集
```cj
//实例化一个64比特的位集
public init()
//实例化一个64 * capacity的位集
public init(capacity: Int64)
//将参数复制到一个新的位集
public init(set: BitSet)
//当前的位数
public prop size: Int64
//返回的迭代器迭代每个bit，迭代到的比特是1则返回Some(true)，否则是Some(false)
public func iterator(): Iterator<Bool>
//参数的哈希是否存在于当前的位集
public func contains<T>(value: T): Bool where T <: Hashable
//将参数的哈希保存于当前的位集
public func set<T>(value: T): Bool where T <: Hashable
//将参数的哈希移除当前的位集
public func remove<T>(value: T): Bool where T <: Hashable
//返回当前位集是否存于index
public operator func [](index: UInt32): Bool
public operator func [](index: Int32): Bool
public operator func [](index: UInt64): Bool
public operator func [](index: Int64): Bool
//将指定索引的值改为value
public operator func [](index: UInt32, value!: Bool): Unit
public operator func [](index: Int32, value!: Bool): Unit
public operator func [](index: UInt64, value!: Bool): Unit
public operator func [](index: Int64, value!: Bool): Unit
//指定索引的比特与1位或，并将值改为位或后的值
public operator func |(index: UInt32): Bool
public operator func |(index: Int32): Bool
public operator func |(index: UInt64): Bool
public operator func |(index: Int64): Bool
//指定索引的比特位与1位与，并将值改为位与后的值
public operator func &(index: UInt32): Bool
public operator func &(index: Int32): Bool
public operator func &(index: UInt64): Bool
public operator func &(index: Int64): Bool
//指定索引的比特位与1位异或，并将值改为位异或后的值
public operator func ^(index: UInt32): Bool
public operator func ^(index: Int32): Bool
public operator func ^(index: UInt64): Bool
public operator func ^(index: Int64): Bool
```
