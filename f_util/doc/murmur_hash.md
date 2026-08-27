## murmur hash
```cj
@Frozen
@OverflowWrapping
public func murmurHash(data: Array<Byte>, seed!: UInt64 = 0): UInt128 

// 便捷函数：直接对字符串进行哈希（静态方法）
@Frozen
public func murmurHash(text: String, seed!: UInt64 = 0): UInt128 
@Frozen
public func murmurHash<T>(text: T, seed!: UInt64 = 0): UInt128 where T <: ToString 
// 64 位循环左移（私有静态辅助函数）
@Frozen
@OverflowWrapping
private func rotl64(x: UInt64, r: Int): UInt64 
```
