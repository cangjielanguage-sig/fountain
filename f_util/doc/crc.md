## crc16
```cj
@Frozen
public func crc16(bytes: Array<Byte>): UInt16 
@Frozen
public func crc16(s: String): UInt16 
@Frozen
public func crc16<T>(s: T): UInt16 where T <: ToString 
```

## crc32
```cj
// 2.4 核心计算函数：计算字节数组的CRC32值
// 参数 data: 需要计算校验和的字节数组
// 返回值: 计算得到的32位CRC校验值（UInt32类型）
@Frozen
public func crc32(data: Array<Byte>): UInt32 
@Frozen
public func crc32(data: String): UInt32 
@Frozen
public func crc32<T>(s: T): UInt16 where T <: ToString 
```

## crc64
```cj

// --- 4. 核心计算函数 ---
// 功能：计算字节数组的 CRC64 值
// 参数 data：需要计算校验和的字节数组
// 返回值：计算得到的 64 位 CRC 校验值
@Frozen
public func crc64(data: Array<Byte>): UInt64 
@Frozen
public func crc64(data: String): UInt64 
@Frozen
public func crc64<T>(s: T): UInt16 where T <: ToString 
```

