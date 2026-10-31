# f_zip

ZIP 容器读写模块：**容器层（local header / 中央目录 / EOCD / ZIP64 / CRC 编排）完全自主实现**，
deflate 数据流复用 `stdx.compress.zlib`（`WrapType.DeflateFormat`）。
不引入任何第三方 ZIP 库、不引 FFI、不做 native 链接。

## STDX 依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 依赖

```
f_zip
├── stdx.compress.zlib   DecompressInputStream / CompressOutputStream
├── f_util               crc32(data: Array<Byte>): UInt32
├── f_base               BaseException（ZipException 的基类）
├── f_io                 ByteBuffer（流模式的随机访问缓冲）
├── f_log                LoggerFactory（落盘 debug 日志 / 压缩比告警 / 符号链接跳过）
├── charset4cj           GBK 解码（文件名回退链）
└── std.fs / std.io / std.time / std.sync
```

## 能力清单

- **读取**：`ZipReader(input)` 全量缓冲、`ZipReader(path)` 走 `File.seek` 窗口读（1 GB 的包 RSS 不随文件线性增长）；
  条目枚举、按名读取（同名取最后一个）、`readAll`、`open` 流式解压（每次独立游标，可并发）。
- **写入**：`add`（内存路径，header 写真实值、无 descriptor）、`addFileStream`（流式路径，
  24 字节 ZIP64 data descriptor）、`openEntry`（**推模式**流式条目：把 `OutputStream` 交给调用方，
  边生成边压缩，不需要先造输入流）、`addFile`、`addDirectory`。
- **ZIP64 双向**：读取识别 EOCD64 / 定位器 / extra `0x0001`；写入仅在越界时升级，小文件不产生任何 ZIP64 字节。
- **安全默认开**：Zip Slip 拦截、符号链接跳过、ZIP 炸弹上限、加密 ZIP 拒绝。
- **大文件不吃内存**：`add()` 超阈值自动落临时文件后走流式；`zip` / `unzip` 全程流式。

## 快速开始

```cangjie
import fountain::f_zip.*

// 打包目录（每个文件走流式路径）
let out = File("export.zip", OpenMode.Write)
let count = zip(out, Path("/data/reports"))
out.close()
println("${count} 个文件")

// 解压（默认上限：单条 512 MB / 累计 2 GB / 65535 条）
let files = unzip("/data/export.zip", Path("/tmp/unpacked"))
println("${files} 个文件")

// 按名取一条
let reader = ZipReader("/data/export.zip")
if (let Some(bytes) <- reader.read("a.txt")) {
    println(String.fromUtf8(bytes))
}
reader.close()

// 流式写入（长度未知也安全）
let buffer = ByteBuffer()
let writer = ZipWriter(buffer)
writer.add("config.json", "{ }".toArray())
writer.addFileStream("huge.log", File("/var/log/app.log", OpenMode.Read))
writer.close()

// 推模式：数据本来就在"生成中"（逐行 XML / CSV / 日志）
let sink = ByteBuffer()
let w2 = ZipWriter(sink)
let entry = w2.openEntry("sheet1.xml")
entry.write("<?xml version=\"1.0\"?><sheetData>".toArray())
entry.write("<row r=\"1\"/></sheetData>".toArray())
entry.close()          // 写 data descriptor 并登记中央目录
w2.close()             // 写中央目录 + EOCD，此时才能读
```

## API 参考

### 顶层函数

```cangjie
public func zip(output: OutputStream, dir: Path,
    options!: ZipWriterOptions = ZipWriterOptions()): Int64
public func unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
public func unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
```

| 函数 | 行为 |
| --- | --- |
| `zip` | 递归打包目录，每个文件走 `addFileStream`（流式）；目录也写目录条目；返回写入的**文件数**（不含目录条目）。符号链接跳过，目录链接跳过整棵子树。 |
| `unzip` | 解压全部条目；目标目录自动创建；同名覆盖；返回解压出的**文件数**（不含目录条目）。Zip Slip、符号链接、加密 ZIP、ZIP 炸弹策略在此生效。 |

`unzip` 不是事务性的：遇到加密条目或中途错误时，已经解出的文件会留在磁盘上（当前条目的半截文件会被删除）。需要全有或全无时先解压到临时目录，成功后再整体替换。

### `ZipReader`

```cangjie
public class ZipReader {
    public init(input: InputStream, limits!: ZipLimits = ZipLimits())
    public init(path: String, limits!: ZipLimits = ZipLimits())

    public func entries(): ArrayList<ZipEntry>
    public func contains(name: String): Bool
    public func read(name: String): ?Array<Byte>
    public func readAll(name: String): Array<Array<Byte>>
    public func open(name: String): ?InputStream
    public func openEntry(entry: ZipEntry): ?InputStream
    public func close(): Unit
}
```

- `ZipReader(input)` 先把整个流读进内存；`ZipReader(path)` 用 `File.seek` 窗口读，不缓冲整包。
- 解析完成后 `entries` / `contains` / `read` / `open` 只读，可并发调用；每次 `open` 另开独立游标。
- `read` / `open` 对同名条目取**最后一个**（后写覆盖）；`readAll` 返回全部同名非目录条目，按中央目录顺序。
- `open` 读到 EOF 才校验 CRC 与解压大小；不完整或 CRC 不符抛 `ZipException`。
- `read` / `open` **不做路径安全校验**；路径校验只在 `unzip` 中执行。
- `close()` 幂等；关闭后 `entries` / `read` / `open` 抛 `ZipException`。

### `ZipEntry`

```cangjie
public struct ZipEntry {
    public let name: String
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let crc32: UInt32
    public let method: UInt16
    public let isDirectory: Bool
    public let modifiedAt: Option<DateTime>
    public let localHeaderOffset: Int64
}
```

所有数值来自**中央目录**，不信任 local header。`isDirectory` 由名字是否以 `/` 结尾判断；DOS 时间为全 0 时 `modifiedAt = None`。

### `ZipWriter`

```cangjie
public class ZipWriter {
    public init(output: OutputStream, options!: ZipWriterOptions = ZipWriterOptions())
    public prop position: Int64
    public prop spilling: Bool

    public func add(name: String, data: Array<Byte>): String
    public func addFileStream(name: String, input: InputStream): String
    public func openEntry(name: String): ZipEntryOutputStream
    public func addFile(name: String, path: Path): String
    public func addDirectory(name: String): String
    public func close(): Unit
}
```

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `add` | 内存 | 数据已在内存；写真实 local header，无 data descriptor。超过 `memoryEntryThreshold` 自动落临时文件后走流式路径。 |
| `addFileStream` | 流式 | 长度未知；写 bit 3 + 24 字节 ZIP64 data descriptor。 |
| `openEntry` | 推模式 | 返回 `ZipEntryOutputStream`，调用方直接 `write` 数据，关闭条目时写 descriptor 并登记中央目录。 |
| `addFile` | 流式 | 从磁盘文件读；**跟随符号链接**（调用方显式指定单个文件）。 |
| `addDirectory` | — | 写目录条目，自动补 `/`；同名目录合并。 |

- 所有 `add*` 返回**实际写入的名字**；同名冲突会改名（`a.txt` → `a_2.txt`）。
- `close()` 写中央目录 + EOCD；必须调用，幂等。关闭后才能读取产物。
- `ZipWriter` 不是线程安全的；`spilling` 是原子读，但 `position` 与 `spilling` 不保证原子一致。
- 写入中途异常后 writer 进入脏状态，之后任何 `add*` / `close()` 都抛 `ZipException`。

### `ZipEntryOutputStream`

```cangjie
public class ZipEntryOutputStream <: OutputStream {
    public prop entryName: String
    public prop count: Int64
    public func write(buffer: Array<Byte>): Unit
    public func flush(): Unit
    public func close(): Unit
}
```

- `count` 是已写入的**未压缩**字节数。
- `close()` 结束条目并登记中央目录；幂等。关闭后不能再写。
- 写入失败会把所属 `ZipWriter` 置为脏状态。

### `ZipWriterOptions`

```cangjie
public class ZipWriterOptions {
    public var memoryEntryThreshold: Int64
    public var tempDir: ?Path
    public var method: CompressionMethod

    public init(memoryEntryThreshold!: Int64 = /* 平台默认 */, tempDir!: ?Path = None,
        method!: CompressionMethod = CompressionMethod.Deflate)
    public static func forServer(): ZipWriterOptions
    public static func forLowMemory(): ZipWriterOptions
}
```

| 字段 / 预设 | 默认 | 说明 |
| --- | --- | --- |
| `memoryEntryThreshold` | Linux/gnu 64 MB，其它 16 MB | `add()` 超过后落临时文件走流式 |
| `tempDir` | `None` | 首选临时目录；按选项 → `TMPDIR` → 系统临时目录 → `./.fountain_tmp/` 回退 |
| `method` | `Deflate` | `Stored` 适合已压缩数据（JPEG/MP4/ZIP） |
| `forServer()` | 64 MB | 服务器档 |
| `forLowMemory()` | 8 MB | 低内存档 |

临时目录四级都不可写时直接抛错，**不降级回内存**。

### `ZipLimits`

```cangjie
public struct ZipLimits {
    public let maxEntrySize: Int64        // 512 MB
    public let maxTotalSize: Int64        // 2 GB，每 reader 实例
    public let maxEntries: Int64          // 65535
    public let ratioWarnThreshold: Int64  // 1000，只告警
}
```

- `maxTotalSize` 是**每个 `ZipReader` 实例**的累计上限，不是进程级全局配额。
- 计数按实际解压字节累加，不采信 header 的 `uncompressedSize`。
- `maxEntrySize` 分两层：中央目录声明值超限时在打开条目前拒绝；声明值撒谎时在流式读取中按实际字节中断。
- `maxEntries` 在解析中央目录过程中拒绝；写入侧没有条目数上限，条目数 ≥ `0xFFFF` 自动升级 ZIP64。

### `CompressionMethod` / `ZipException`

```cangjie
public enum CompressionMethod {
    | Stored
    | Deflate
    public prop value: UInt16
    public static func fromValue(value: UInt16): ?CompressionMethod
}

public class ZipException <: BaseException {
    public init(message: String)
}
```

`f_zip` 对外只抛 `ZipException`；非法 ZIP、CRC 不符、加密条目、路径非法、限额超出都走它。

## 安全默认值

| 风险 | 默认行为 |
| --- | --- |
| Zip Slip | 绝对路径 / `..` 段 / 规范化后在目标目录外 → 拒绝，且不创建任何中间目录 |
| 符号链接 | `unzip` / `zip` 跳过并记 warning；`addFile` 跟随（调用方显式指定单个文件） |
| ZIP 炸弹 | `ZipLimits` 四道上限，按**实际解压字节**累计，超限中断且不留半截文件 |
| 加密 ZIP | bit 0 / bit 6 置位即报错，不做部分支持 |

## 文档

- `doc/f_zip模块设计.md` —— 设计稿（21 条决策表、字节布局、实施顺序）
- `doc/api.md` —— 九个公开名字的速查与约束（每实例限额、非线程安全、`spilling` 语义）
- `doc/兼容性例外.md` —— 与 APPNOTE 不一致的真实样本登记表（初始为空）
