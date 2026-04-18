# RotatableBuffer

```cj
public class RotatableBuffer
```

可旋转缓冲区，支持按分隔符从 InputStream 中分段读取。

## 构造函数

`init(input: InputStream, boundaryBytes: Array<Byte>, halfBufferSize!: Int64 = 4096)`

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| indexOf | `func indexOf(bytes: Array<Byte>, from!: Int64): Int64` | 搜索字节模式，未找到返回 -1 |
| addOffset | `func addOffset(off: Int64): Unit` | 推进偏移量 |
| read | `func read(bytes: Array<Byte>): (length: Int64, remainder: Bool, partEnd: Bool)` | 读取到数组，返回（长度，是否有剩余，是否到达边界） |
