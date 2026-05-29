# MMapFile

> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class MMapFile <: Resource & IOStream
```

内存映射文件。写映射区每次重定位为 mapLength 大小，读映射区按 mapLength 和剩余长度动态决定。文件以只写方式打开且长度不足时会自动延长。

## 构造函数

| 签名 | 说明 |
|------|------|
| `init(file: File, prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, offset!: Int64 = 0, mapLength!: Int64 = DEFAULT_MMAP_BYTES)` | 基于文件映射 |
| `static func anonymous(prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, mapLength!: Int64 = DEFAULT_MMAP_BYTES): MMapFile` | 匿名映射 |

## 属性

| 名称 | 类型 | 说明 |
|------|------|------|
| `info` | `FileInfo` | 文件信息 |
| `isReadable` | `Bool` | 是否可读 |
| `isWritable` | `Bool` | 是否可写 |
| `isSyncable` | `Bool` | 是否可同步（非 Private 且非 Anonymous） |
| `isAnonymous` | `Bool` | 是否匿名映射 |
| `readOffset` | `Int64` | 读偏移量 |
| `writeOffset` | `Int64` | 写偏移量 |
| `length` | `Int64` | 映射内存大小 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| syncAndUnmap | `func syncAndUnmap(): Unit` | 同步并取消映射 |
| sync | `func sync(flag: MSyncFlag): Unit` | 按标志同步 |
| remap | `func remap(offset: Int64, mapLength!: Int64, flag!: MMapFlag): MMapFile` | 重新映射 |
| setLength | `func setLength(length!: Int64): Unit` | 设置文件长度 |
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | |
| read | `func read(buffer: Array<Byte>): Int64` | |
| write | `func write(p: CPointer<Byte>, s: Int64): Unit` | |
| write | `func write(buffer: Array<Byte>): Unit` | |
| flush | `func flush(): Unit` | 等同于 sync(MSyncFlag.Sync) |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | sync + unmap + close file |

## 相关类型

- [ToMMap](ToMMap.md) — 接口，File 扩展此接口
- [MMapProt](MMapProt_MMapFlag_MSyncFlag.md) — 保护标志枚举
- [MMapFlag](MMapProt_MMapFlag_MSyncFlag.md) — 映射标志枚举
- [MSyncFlag](MMapProt_MMapFlag_MSyncFlag.md) — 同步标志枚举
