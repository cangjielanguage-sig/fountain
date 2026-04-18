# ExtendByteBuffer

```cj
public interface ExtendByteBuffer
```

ByteBuffer 的类型化读写接口，支持大端/小端字节序。

## 方法

| 分类 | 方法 | 返回类型 |
|------|------|---------|
| 读 | `readBool/readUInt8/readUInt16/readUInt32/readUInt64/readInt8/readInt16/readInt32/readInt64/readFloat16/readFloat32/readFloat64` | `?T` |
| 写 | `writeBool/writeUInt8/writeUInt16/writeUInt32/writeUInt64/writeInt8/writeInt16/writeInt32/writeInt64/writeFloat16/writeFloat32/writeFloat64` | `Unit` |

所有方法均有 `endian!: Endian` 参数（默认 `Endian.Platform`）。

## 扩展

```cj
extend ByteBuffer <: ExtendByteBuffer
```

`std.io.ByteBuffer` 实现了 `ExtendByteBuffer`。
