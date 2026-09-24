## wyhash

```cj
@Frozen
public func wyrand(seed: Int64): UInt64 
@Frozen
@OverflowWrapping
public func wyrand(seed: UInt64): UInt64 
@Frozen
public func wyhash(s: String, start!: Int64 = 0, size!: Int64 = s.size, see!: UInt64 = 0): UInt64 
@Frozen
public func wyhash<T>(s: T, start!: Int64 = 0, see!: UInt64 = 0): UInt64 where T <: ToString 
@Frozen
@OverflowWrapping
public func wyhash(arr: Array<UInt8>, start!: Int64 = 0, size!: Int64 = arr.size, see!: UInt64 = 0): UInt64
```