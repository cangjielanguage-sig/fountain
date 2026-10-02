# BytePointerStream

```cj
public class BytePointerStream <: IOStream & Resource
```

基于原生内存指针的字节流，支持读写 CPointer<Byte> 和 Array<Byte>。

## 构造函数

| 签名 | 说明 |
|------|------|
| `init(pointer: CPointer<Byte>, size: Int64, readable!: Bool = true, writable!: Bool = true)` | 基于已有指针 |
| `init(size: Int64, readable!: Bool = true, writable!: Bool = true)` | 分配新内存（LibC.malloc） |

## 属性

| 名称 | 类型 | 说明 |
|------|------|------|
| `readable` | `Bool` | 是否可读 |
| `writable` | `Bool` | 是否可写 |
| `readOffset` | `Int64` | 读偏移量 |
| `writeOffset` | `Int64` | 写偏移量 |
| `length` | `Int64` | 总映射大小 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | 读入 CPointer |
| read | `func read(buffer: Array<Byte>): Int64` | 读入 Array |
| write | `func write(p: CPointer<Byte>, size: Int64): Unit` | 从 CPointer 写入，空间不足抛异常 |
| write | `func write(buffer: Array<Byte>): Unit` | 从 Array 写入，空间不足抛异常 |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | 释放内存（如 freeable） |
