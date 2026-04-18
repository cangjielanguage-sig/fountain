# fountain::f_io API 参考

> 所有声明仅在 Linux 下可用时标注 `@When[os == "Linux"]`

## 顶级函数

### pipe

```cj
public func pipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

将 `input` 的所有数据通过缓冲区传输到 `output`。

### asyncPipe

```cj
public func asyncPipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

在新线程中执行 `pipe`。

### copyToCType

```cj
public func copyToCType<T>(input: InputStream): T where T <: CType
```

从 `InputStream` 读取 `sizeOf<T>()` 字节并解释为 CType 值。字节数不足时抛出 `IllegalSizeException`。

---

## BytePointerStream

```cj
public class BytePointerStream <: IOStream & Resource
```

基于原生内存指针的字节流，支持读写 CPointer<Byte> 和 Array<Byte>。

### 构造函数

| 签名 | 说明 |
|------|------|
| `init(pointer: CPointer<Byte>, size: Int64, readable!: Bool = true, writable!: Bool = true)` | 基于已有指针 |
| `init(size: Int64, readable!: Bool = true, writable!: Bool = true)` | 分配新内存（LibC.malloc） |

### 属性

| 名称 | 类型 | 说明 |
|------|------|------|
| `readable` | `Bool` | 是否可读 |
| `writable` | `Bool` | 是否可写 |
| `readOffset` | `Int64` | 读偏移量 |
| `writeOffset` | `Int64` | 写偏移量 |
| `length` | `Int64` | 总映射大小 |

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | 读入 CPointer |
| read | `func read(buffer: Array<Byte>): Int64` | 读入 Array |
| write | `func write(p: CPointer<Byte>, size: Int64): Unit` | 从 CPointer 写入，空间不足抛异常 |
| write | `func write(buffer: Array<Byte>): Unit` | 从 Array 写入，空间不足抛异常 |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | 释放内存（如 freeable） |

---

## DummyInputStream

```cj
public class DummyInputStream <: InputStream & Resource
```

空输入流，用于测试或占位。

### 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | read 时抛异常 |
| `SILENCE` | read 时返回 0 |

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |

---

## DummyOutputStream

```cj
public class DummyOutputStream <: OutputStream & Resource
```

空输出流，用于测试或占位。

### 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | write/flush 时抛异常 |
| `SILENCE` | 静默忽略 |

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| write | `func write(buffer: Array<Byte>): Unit` | 取决于 throwing 标志 |
| flush | `func flush(): Unit` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |

---

## ExtendByteBuffer

```cj
public interface ExtendByteBuffer
```

ByteBuffer 的类型化读写接口，支持大端/小端字节序。

### 方法

| 分类 | 方法 | 返回类型 |
|------|------|---------|
| 读 | `readBool/readUInt8/readUInt16/readUInt32/readUInt64/readInt8/readInt16/readInt32/readInt64/readFloat16/readFloat32/readFloat64` | `?T` |
| 写 | `writeBool/writeUInt8/writeUInt16/writeUInt32/writeUInt64/writeInt8/writeInt16/writeInt32/writeInt64/writeFloat16/writeFloat32/writeFloat64` | `Unit` |

所有方法均有 `endian!: Endian` 参数（默认 `Endian.Platform`）。

### 扩展

```cj
extend ByteBuffer <: ExtendByteBuffer
```

`std.io.ByteBuffer` 实现了 `ExtendByteBuffer`。

---

## MMapFile `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class MMapFile <: Resource & IOStream
```

内存映射文件。写映射区每次重定位为 mapLength 大小，读映射区按 mapLength 和剩余长度动态决定。文件以只写方式打开且长度不足时会自动延长。

### 构造函数

| 签名 | 说明 |
|------|------|
| `init(file: File, prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, offset!: Int64 = 0, mapLength!: Int64 = DEFAULT_MMAP_BYTES)` | 基于文件映射 |
| `static func anonymous(prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, mapLength!: Int64 = DEFAULT_MMAP_BYTES): MMapFile` | 匿名映射 |

### 属性

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

### 方法

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

---

## ToMMap `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public interface ToMMap
```

### 方法

| 方法 | 签名 |
|------|------|
| mmap | `func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag): MMapFile` |

### 扩展

```cj
@When[os == "Linux"]
extend File <: ToMMap
```

`std.fs.File` 扩展了 `ToMMap`，根据 `canRead()`/`canWrite()` 确定 prots。

---

## QueueInputStream

```cj
sealed abstract class QueueInputStream <: InputStream
```

队列式输入流，支持添加多个 InputStream 顺序读取。

### 构造函数

`init(size: Int64, closeOnEnd!: Bool = true)`

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| add | `func add(stream: InputStream): Unit` | 添加输入流 |
| add | `func add(bytes: Array<Byte>): Unit` | 添加字节（包装为 ByteBuffer） |

### 子类

#### NonblockingQueueStream

```cj
public class NonblockingQueueStream <: QueueInputStream
```

非阻塞读取，无数据时返回 0。

#### BlockingQueueStream

```cj
public class BlockingQueueStream <: QueueInputStream
```

阻塞读取，等待数据可用。

---

## RotatableBuffer

```cj
public class RotatableBuffer
```

可旋转缓冲区，支持按分隔符从 InputStream 中分段读取。

### 构造函数

`init(input: InputStream, boundaryBytes: Array<Byte>, halfBufferSize!: Int64 = 4096)`

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| indexOf | `func indexOf(bytes: Array<Byte>, from!: Int64): Int64` | 搜索字节模式，未找到返回 -1 |
| addOffset | `func addOffset(off: Int64): Unit` | 推进偏移量 |
| read | `func read(bytes: Array<Byte>): (length: Int64, remainder: Bool, partEnd: Bool)` | 读取到数组，返回（长度，是否有剩余，是否到达边界） |

---

## MMapProt `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public enum MMapProt
```

内存映射保护标志。

### 构造器

`Read` | `Write` | `Exec` | `None`

### 操作符

| 操作符 | 签名 | 说明 |
|--------|------|------|
| & | `operator func &(prot: IntNative): Bool` | 检查标志位 |
| \| | `operator func \|(other: MMapProt): Array<MMapProt>` | 组合两个标志 |
| \| | `operator func \|(others: Array<MMapProt>): Array<MMapProt>` | 组合数组 |

---

## MMapFlag `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public enum MMapFlag <: Equatable<MMapFlag> & Equatable<IntNative>
```

### 构造器

`Shared` | `Private` | `Anonymous`

---

## MSyncFlag `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public enum MSyncFlag
```

### 构造器

`Sync` | `Async` | `Invalidate`

---

## DEFAULT_MMAP_BYTES `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024  // 1 GiB
```

---

## IOUringStream `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class IOUringStream <: IOStream & Resource
```

基于 io_uring 的 IOStream 实现（双 ring 架构）。Write 异步提交后立即返回，Read 同线程 submit + waitCQE。可选注册缓冲区模式。

### 构造函数

| 签名 | 说明 |
|------|------|
| `init(fd: Int32, entries: UInt32, flags!: UInt32 = 0, fixedBufCount!: UInt32 = 0, fixedBufSize!: UInt32 = 4096)` | 完整参数，支持注册缓冲区 |
| `init(fd: Int32)` | 简化初始化（64 entries，无注册缓冲区） |

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | 读取数据，无数据阻塞，有数据立即返回 |
| write | `func write(buffer: Array<Byte>): Unit` | 写入数据，立即返回 |
| flush | `func flush(): Unit` | 无操作（write 已立即返回） |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | 停止收割线程，注销缓冲区，关闭 ring |

---

## BytePointerException

```cj
public class BytePointerException <: BaseException
```

包: `fountain::f_io.exception`

构造函数: `init()`, `init(message: String)`, `init(caused: Exception)`, `init(message: String, caused: Exception)`

---

## MMapException

```cj
public class MMapException <: BaseException
```

包: `fountain::f_io.exception`

构造函数: `init()`, `init(message: String)`, `init(caused: Exception)`, `init(message: String, caused: Exception)`
