# f_zip —— 仓颉 ZIP 模块设计

> 版本 **v0.7** ｜ 2026-10-24 ｜ 状态：已实现（2026-10-28，实现偏差见文末「实现落位说明」）
>
> 定位：fountain 模块，提供 ZIP 格式的压缩与解压。
> deflate 部分复用 `stdx.compress.zlib`，容器层（头、中央目录、CRC）自己实现。
>
> v0.6 → v0.7（三项确认）：
> - `spilling` 用 **`AtomicBool`**，跨线程读安全
> - `@When` 是**通用语义**（适用于各种声明），但**只能用于声明**
> - `spilling` 与 `position` **不保证原子一致**，不能拿它们做逻辑判断
>
> v0.5 → v0.6（三项决策落定）：
> - 确认 `@When[os != "Linux"]` 与 `@When[os == "Linux"]` **不可能同时存在**，只保留匹配的那个
> - 不加 `forContainer(memoryLimit)`：容器内进程读到的是容器的 cgroup limit，不是宿主机内存
> - 新增 **`ZipWriter.spilling: Bool`**，让 UI 在落盘阶段显示"准备中"而不是"0%"
>
> v0.4 → v0.5（三项决策落定）：
> - `@When` 就两个分支（`== "Linux"` / `!= "Linux"`），后者兜底全部其他平台
> - `forServer()` / `forLowMemory()` 是**静态工厂**，返回的实例**可自由修改**
> - `add()` 进入临时文件分支时打一条 **debug 日志**（3.4.3）
>
> v0.3 → v0.4（三项决策落定）：
>
> - **`memoryEntryThreshold` 按平台分档**：Linux 64 MB，OHOS 及其他 16 MB（3.4.2）
> - 同名改名后缀从 **`_2`** 起（"第二个"），确认不改
> - `addFileStream` / `addFile` / `addDirectory` **都返回实际写入的名字**，确认接受这个 API 变更
>
> v0.2 → v0.3（五项决策落定）：
>
> - `ZipWriter` 暴露 `position: Int64`（进度上报）
> - **同名条目在写入侧消解**：目录合并；文件自动改名 `_2` `_3`…（3.3）
> - 符号链接**无条件跳过**（读取与 `zip()` 打包都跳过）
> - `maxEntries` 语义彻底拆开：读取侧是安全上限，写入侧**自动升级 ZIP64**，不再有格式上限
> - `add()` 超过阈值（平台相关）自动转临时文件走流式路径（内存峰值减半）
>
> v0.1 → v0.2（五项决策落定）：
>
> - `ZipReader(path)` 走文件 `seek`，不再全量缓冲
> - 流式写（`addFileStream` + data descriptor）纳入首版
> - **ZIP64 写入**纳入首版（原先只有读取）
> - 解压上限保留默认值，改为 `ZipLimits` 可覆盖
> - 「不引入第三方 ZIP 实现」升级为**长期约束**

---

## 实现落位说明（2026-10-28）

本文是 v0.7 设计稿在 `f_zip/doc/` 的落位版本。实现与设计稿共有两处偏差，均已回写到对应章节：

1. **§1 依赖表增加 `f_log`**：§3.4.3 要求落盘分支打 debug 日志，必须有日志出口。`f_log` 是仓库内模块，
   不属于"第三方 ZIP 实现"，长期约束（无外部 ZIP 库 / 无 FFI / 无 native 链接）不受影响。
2. **§3.2 `ZipWriter` 构造增加 `options!` 参数**：落盘阈值、临时目录、压缩方法需要一个入口，
   默认 `ZipWriterOptions()` 与原签名 `ZipWriter(out)` 等价。
3. **§3.4.2 的 `@When` 条件补上 `env`**：只写 `os == "Linux"` 会让 **OHOS 也命中服务器档**
   （鸿蒙目标的 `os` 同样是 `"Linux"`，差异在 `env == "ohos"`），与"OHOS 用 16 MB"的意图相反。
   实际实现为 `@When[os == "Linux" && env == "gnu"]` / `@When[os != "Linux" || env != "gnu"]`，
   与 `f_base/src/OS.cj` 的既有写法一致。

另外两处实现细节的选择（不改变契约）：

- `EntrySource.openRange` 的 `BufferSource` 用**共享字节数组 + 独立游标**实现，不复制整块缓冲——
  语义与"clone 起点"一致，但并发 `open` 不必为每个流复制整个 ZIP。
- `ZipReader` 读 EOCD64 记录时复用 `skipBytes` / `readU64LE` 原语，保证 D12 的函数集全部在正式路径上被使用。

---

## 0. 范围与结论


| 项           | 结论                                                                                     |
| ------------ | ---------------------------------------------------------------------------------------- |
| 压缩算法     | **仅 Stored(0) 与 Deflate(8)**，其余明确报错                                             |
| deflate 实现 | `stdx.compress.zlib`（`WrapType.DeflateFormat`）                                         |
| CRC32        | `f_util.crc32`（已有，无需自己写表）                                                     |
| ZIP64        | **读取与写入都支持**（EOCD64、extra `0x0001`、8 字节 data descriptor）                   |
| 加密 ZIP     | 不支持，明确报错                                                                         |
| 文件名编码   | bit 11 判定 + 回退链（见 6.3）                                                           |
| 依赖         | **仅 `stdx.compress.zlib` + `f_util` + `f_io`**，不引入任何第三方 ZIP 库（**长期约束**） |
| 读取方式     | `init(InputStream)` 全量缓冲；**`init(path)` 走 `File.seek`**，只读窗口与单条数据        |
| 写入方式     | `add(name, data)` 内存路径（先算后写）；**`addFileStream` 流式路径**（data descriptor）  |
| 条目大小阈值 | `add()` 的 `data` 超阈值自动落临时文件走流式路径；**Linux 64 MB / 其他 16 MB**（3.4）    |
| 同名条目     | 写入侧消解：目录合并、文件改名`_2` `_3`…；读取侧 `read()` 取最后一个（3.3）             |
| 符号链接     | **无条件跳过**（读取与 `zip()` 打包均跳过），不做跟随                                    |
| 条目数上限   | 读取侧`ZipLimits.maxEntries = 65535`（安全）；**写入侧无格式上限，越界自动写 ZIP64**     |
| 解压上限     | 默认单条 512 MB / 总计 2 GB / 1000 倍压缩比，**`ZipLimits` 可覆盖**                      |
| 进度         | `ZipWriter.position: Int64`，已写入 output 的字节数（3.2）                               |

### 依赖策略：只依赖 stdx.compress，自主实现

**明确决定：f_zip 的容器层完全自己实现，不引入第三方 ZIP 库。**

理由四条：

1. **依赖面最小化**。f_zip 是底层模块，上面还压着 f_excel。多一层第三方依赖，编译环境、版本、平台兼容都会变成传导风险；而 ZIP 容器的逻辑规模可控（估计 500~800 行），没有必要为此扩大依赖面。
2. **职责边界本来就清晰**。`stdx.compress.zlib` 只负责 deflate 数据流，不碰 ZIP 结构（local header、中央目录、EOCD、CRC）。两者是正交的，不存在"用一半很别扭"的问题。
3. **格式极其稳定，一次写对长期不用改**。ZIP 从 1989 年至今容器结构基本未变，PKWARE 的 APPNOTE 是唯一权威。它不像 HTML 解析需要持续对抗真实世界的畸形输入——这是"值得自己写"的少数格式之一。
4. **边角行为需要自己拍板**。中文文件名编码判定、ZIP64 支持范围、data descriptor 用不用、目录条目怎么标——这些取舍没有标准答案，只有自己实现才能按项目需要决定；用别人的库只能接受它的选择。

**实现依据：以 PKWARE APPNOTE.TXT 为准**，不要照着其他语言的实现抄。那些实现往往带着多年积累的兼容性补丁和特例处理，直接照搬会把别人的历史包袱一起继承过来。遇到与 APPNOTE 不一致的真实文件，再单独记录为"已知兼容性例外"。

**自行实现的代价，必须提前认下**：


| 代价           | 说明                                                                                                                     |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 边角格式容易漏 | ZIP64 的多组哨兵值、data descriptor 的有无、extra field 的各种 ID、目录条目的属性位——只能靠对照规范 + 真实样本逐个覆盖 |
| 没有社区兜底   | 遇到畸形文件只能自己啃，没有"升级一个版本就好了"这种选项                                                                 |
| 测试成本前置   | 第 9 章的"外部工具交叉验证"不是可选项，而是主要质量保证手段——自己写自己读可能互相容忍同一个错误                        |

换来的是：零第三方依赖、零 FFI、行为完全可控。

#### 长期约束（已定，不可随意推翻）

**f_zip 永久不引入第三方 ZIP 实现。** 这不是"当前阶段的选择"，是模块的长期约束，写入本节即生效。


| 项         | 说明                                                                                                                                                                  |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 约束对象   | **ZIP 容器的实现**（local header / 中央目录 / EOCD / ZIP64 / CRC 编排）。**不包括** `stdx.compress.zlib`——deflate 数据流复用它是有意为之，不是例外                  |
| 允许的变化 | 容器层可以重写、优化、拆文件，但**不能换成外部库**                                                                                                                    |
| 复审条件   | 三条**同时**成立才允许提出：① 生态出现无 FFI、无 native 链接的实现；② 该实现能覆盖本文档第 2、9 章的格式要求与测试集；③ 有量化收益评估（代码量、维护成本、缺陷率） |
| 变更程序   | 推翻它必须在本文档新增一节「约束变更评估」，记录上述三条的证据与结论，由评审决定。**不接受"某某库很流行/很活跃"作为理由**                                             |

把这条写死的现实理由：模块的边界一旦靠"用别人的库"来兜，边角行为（中文名编码、ZIP64 范围、
descriptor 有无、目录属性位）就由不得自己——而这些恰恰是本项目最需要控制的部分。

---

## 1. 依赖

```
f_zip
├── stdx.compress.zlib   CompressInputStream / CompressOutputStream
├── f_util               crc32(data: Array<Byte>): UInt32
├── f_io                 ByteBuffer（流模式的随机访问缓冲）
├── f_log                LoggerFactory（落盘分支的 debug 日志，§3.4.3）
├── charset4cj           GBK 解码（文件名回退链，§6.2）
└── std.fs               File / Seekable（文件模式的窗口读，标准库，不算依赖项）
```

**没有第三方 ZIP 实现。** 无第三方 ZIP 库、无 FFI、无 native 链接——整条链路只到仓颉标准库、stdx、
仓库内模块（`f_util` / `f_io` / `f_log`）与 TPC 的 `charset4cj`（只用来解 GBK 文件名，不参与容器编解码）。

**zlib 关键 API**（已核实）：

```cangjie
// 解压（注意：解压用的是 DecompressInputStream，不是 CompressInputStream）
DecompressInputStream(
    inputStream: InputStream,
    wrap!: WrapType = DeflateFormat,          // ZIP 用 DeflateFormat（裸 deflate，无 zlib/gzip 头）
    bufLen!: Int64 = 512
)

// 压缩
CompressOutputStream(
    outputStream: OutputStream,
    wrap!: WrapType = DeflateFormat,
    compressLevel!: CompressLevel = DefaultCompression,
    bufLen!: Int64 = 512
)
```

`WrapType` 有 `DeflateFormat` / `GzipFormat`。**ZIP 必须用 `DeflateFormat`** —— ZIP 里存的是裸 deflate 流，带 zlib 头会解压失败。

`CompressLevel` 有 `BestSpeed` / `BestCompression` / `DefaultCompression`。

### 1.1 f_io.ByteBuffer

ZIP 需要随机访问（先读尾部的 EOCD，再跳回中央目录），所以用一个可 seek 的缓冲区做底座。

`fountain::f_io.ByteBuffer`（实读其源码确认）：

```cangjie
public class ByteBuffer <: IOStream {
    public prop writeOffset: Int64
    public prop readOffset: Int64
    public prop capacity: Int64

    public func bytes(): Array<Byte>
    public func clear(): Unit
    public func clone(): ByteBuffer
    public func reserve(addition: Int64): Unit

    public func seekReading(pos: SeekPosition): Unit
    public func seekWriting(pos: SeekPosition): Unit

    public func readByte(): ?Byte
    public func read(buf: Array<Byte>): Int64
    public func writeByte(b: Byte): Unit
    public func write(buf: Array<Byte>): Unit
    public func flush(): Unit
}
```

正好覆盖 ZIP 的需求：`seekReading` 跳位置、`read` 取字节、`bytes()` 拿原始数组。

### 1.2 小端读写：f_zip 内部实现（原前置任务已取消）

ZIP 需要两类能力：

1. **类型化小端读写**（解析 / 写出定长头字段）
2. **按字符集解码字符串**（文件名 UTF-8 / GBK 回退）

原本计划把这两项做成 `f_io.ByteBuffer` 的增强。**2026-10-24 决定：`f_io.ByteBuffer` 保持现状，
该增强不实施。** 所以这两项改由用到它的模块各自解决：


| 能力                                       | 谁提供                                | 说明                                                              |
| ------------------------------------------ | ------------------------------------- | ----------------------------------------------------------------- |
| `readU16LE` / `readU32LE` / `readU64LE`    | **f_zip 内部私有函数**                | 约 10 个，每个 3~5 行，基于现有`readByte()` / `read(Array<Byte>)` |
| `writeU16LE` / `writeU32LE` / `writeU64LE` | 同上                                  | 基于`writeByte()` / `write(Array<Byte>)`                          |
| `decodeStrict(bytes, charset)`             | **f_zip 内部**（内部调 `charset4cj`） | 只服务文件名回退链，不值得为此抽通用层                            |

**为什么仍用 `f_io.ByteBuffer`**：它已是依赖，且 `seekReading` / `bytes()` 的语义正合需要。
`std.io.ByteBuffer` 也能用，但要自己分清读写两个位置（它的 `position` 是读游标，写永远追加，
实测见 f_io 设计 3.11）。

> 顺带澄清一个之前没想清的点：**ZIP 其实不需要"回填"**。
> 内存路径是"先算 CRC 与压缩后大小，再写 header"；流式路径是"header 写 0 + data descriptor"。
> 两条路都不需要把写游标移回去改一个旧字段。真正需要回填的是长度前缀（区间记录格式），
> ZIP 用不到。

四条实现约定：

1. **读越界返回 `None` 且回滚读游标**——解析到一半失败时游标不能位移
2. **必须校验实际读到的字节数**，否则补零会产生"看起来合法的错误值"
3. 小端一律显式，**不写依赖默认端序的代码**
4. 这些函数是 `private`，不进公开 API——它们只服务 ZIP

---

## 2. ZIP 格式要点

### 2.1 三个核心结构

ZIP 文件 = `[local header + data]* + [central directory] + [EOCD]`

**Local File Header（固定 30 字节）**


| 偏移 | 长度 | 字段                 | 说明                                                             |
| ---- | ---- | -------------------- | ---------------------------------------------------------------- |
| 0    | 4    | signature            | `0x04034b50`                                                     |
| 4    | 2    | version needed       | 解压所需最低版本：普通条目 20；**流式条目 45**（带 ZIP64 extra） |
| 6    | 2    | general purpose flag | 见 2.2                                                           |
| 8    | 2    | compression method   | 0=Stored, 8=Deflate                                              |
| 10   | 2    | last mod time        | DOS 格式                                                         |
| 12   | 2    | last mod date        | DOS 格式                                                         |
| 14   | 4    | crc-32               | 未压缩数据的 CRC                                                 |
| 18   | 4    | compressed size      |                                                                  |
| 22   | 4    | uncompressed size    |                                                                  |
| 26   | 2    | file name length     |                                                                  |
| 28   | 2    | extra field length   |                                                                  |
| 30   | n    | file name            |                                                                  |
| —   | m    | extra field          | ZIP64 时含 0x0001 扩展                                           |

**Central Directory Header（固定 46 字节）**


| 偏移 | 长度 | 字段                  |
| ---- | ---- | --------------------- |
| 0    | 4    | signature`0x02014b50` |
| 4    | 2    | version made by       |
| 6    | 2    | version needed        |
| 8    | 2    | general purpose flag  |
| 10   | 2    | compression method    |
| 12   | 2    | last mod time         |
| 14   | 2    | last mod date         |
| 16   | 4    | crc-32                |
| 20   | 4    | compressed size       |
| 24   | 4    | uncompressed size     |
| 28   | 2    | file name length      |
| 30   | 2    | extra field length    |
| 32   | 2    | file comment length   |
| 34   | 2    | disk number start     |
| 36   | 2    | internal attributes   |
| 38   | 4    | external attributes   |
| 42   | 4    | **local header 偏移** |
| 46   | n    | file name             |
| —   | m    | extra field           |
| —   | k    | file comment          |

**EOCD（固定 22 字节）**


| 偏移 | 长度 | 字段                  |
| ---- | ---- | --------------------- |
| 0    | 4    | signature`0x06054b50` |
| 4    | 2    | 当前磁盘号            |
| 6    | 2    | 中央目录起始磁盘号    |
| 8    | 2    | 本盘条目数            |
| 10   | 2    | 总条目数              |
| 12   | 4    | 中央目录大小          |
| 16   | 4    | 中央目录偏移          |
| 20   | 2    | 注释长度              |
| 22   | n    | 注释                  |

### 2.2 General Purpose Bit Flag


| bit | 含义                | 我们的处理                                                 |
| --- | ------------------- | ---------------------------------------------------------- |
| 0   | 加密                | **置位则报错**（不支持加密）                               |
| 1-2 | 压缩选项            | 忽略                                                       |
| 3   | **data descriptor** | 读取时识别；**流式写入必写**（24 字节 ZIP64 形式，见 5.2） |
| 6   | 强加密              | 报错                                                       |
| 11  | **文件名是 UTF-8**  | 编码判定依据（见 6.3）                                     |
| 13  | 掩盖 local header   | 报错                                                       |

### 2.3 DOS 时间格式

```
time:  bit15-11 时(0-23) | bit10-5 分(0-59) | bit4-0 秒/2(0-29)
date:  bit15-9 年-1980   | bit8-5 月(1-12)  | bit4-0 日(1-31)
```

注意秒只有 2 秒精度，这是格式限制不是 bug。

### 2.4 ZIP64

当任一字段越界（> 4 GB、条目数 > 65535、偏移 > 4 GB）时启用。**读取与写入都支持。**

**读取**

- 先找 EOCD；若条目数 / CD 大小 / CD 偏移为哨兵值（`0xFFFF` / `0xFFFFFFFF`），
  先读 EOCD64 定位器（`0x07064b50`，固定 20 字节，位于 EOCD 之前），再读 EOCD64（`0x06064b50`）
- local / central header 的 extra 里 ID `0x0001` 的扩展块，按**固定顺序**只包含越界的那几项：
  `originalSize(8)` → `compressedSize(8)` → `localHeaderOffset(8)` → `diskStart(4)`
- **不能按字段位置硬读**：必须先看 extra 总长度，再按"哪些字段是哨兵值"决定读几个 8 字节

**写入**


| 场景                                              | 做法                                                                                      |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 单条目大小或偏移 ≥`0xFFFFFFFF`                   | header 里对应字段写`0xFFFFFFFF`，extra 放 `0x0001` 的真实 8 字节值；`version needed` = 45 |
| 条目数 >`0xFFFF`，或 CD 大小/偏移 ≥ `0xFFFFFFFF` | 追加 EOCD64 + 定位器；EOCD 对应字段写哨兵                                                 |
| 都不越界                                          | **不写 ZIP64**。不要"总是写"——那会让小文件凭空多出几十字节，也让老工具多一层解析        |

**extra 里只放越界的字段。** 全放虽然多数解压器也能接受，但会让"这段 extra 到底有几个值"
依赖读取方的宽容度；只放必要的，读端按哨兵值个数就能判定。

**与 data descriptor 的交互**（最容易错的一条）：见 5.2——流式条目**一律用 ZIP64 形式**，
因为 descriptor 的宽度必须在写 local header 时就确定，而那时大小还是未知的。

---

## 3. API 设计

### 3.1 读取

```cangjie
package fountain::f_zip

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

public class ZipReader {
    /// 从流读取：内部把整个流缓冲到内存（ZIP 需要随机访问中央目录）
    public init(input: InputStream, limits!: ZipLimits = ZipLimits())   // ZipLimits 见 7.2

    /// 从文件读取：走 File.seek，**不缓冲整个文件**
    public init(path: String, limits!: ZipLimits = ZipLimits())         // ZipLimits 见 7.2

    /// 条目列表（按中央目录顺序）
    public func entries(): ArrayList<ZipEntry>

    /// 按名字取解压后的数据
    public func read(name: String): ?Array<Byte>

    /// 按条目取解压流（大条目推荐，避免一次性进内存）
    public func open(name: String): ?InputStream

    public func contains(name: String): Bool

    public func close(): Unit
}
```

**两种构造的分工**


| 构造          | 随机访问手段           | 适用                                       | 内存                                   |
| ------------- | ---------------------- | ------------------------------------------ | -------------------------------------- |
| `init(input)` | 全量读进`ByteBuffer`   | 网络流、内存中的 zip、xlsx（通常 < 10 MB） | 文件大小 × 1                          |
| `init(path)`  | `std.fs.File` + `seek` | 大 ZIP、要`open(name)` 流式解压            | 尾部窗口 ≤ 64 KB + CD 区域 + 单条输出 |

`init(path)` 的做法：

1. 只读打开 `File`，用 `length` 拿文件大小
2. `seek(SeekPosition.End(-(22 + 65535)))` → 读尾部窗口找 EOCD；
   窗口大小取 `min(fileLength, 22 + 65535)`
3. 有 ZIP64 → 再往前读 20 字节定位器 + 56 字节 EOCD64
4. `seek` 到 CD 偏移，一次读入 CD 区域
5. `read(name)` / `open(name)` 时**另开一个 File 句柄**，`seek` 到数据起点，用限长流读出

第 5 步为什么要另开句柄：`File` 的光标是共享状态，同一个句柄上并发 `open` 两个条目会互相打乱位置。
每次 `open` 独立开句柄，代价是一次 `open(2)`，换来的是"不用加锁、可以并行解压"。

> **不要用 `f_io.MMapFile` 做这件事**：它标了 `@When[os == "Linux"]`，在 OHOS 上根本不存在。
> `File.seek` 跨平台，且对这个访问模式（少量窗口 + 顺序读）已经足够。
> 将来若真要在 Linux 上再快一点，可以加平台条件下的内部优化，**但不进公开 API**。

### 3.2 写入

```cangjie
public class ZipWriter {
    public init(output: OutputStream, options!: ZipWriterOptions = ZipWriterOptions())

    /// 已写入 output 的字节数（local header + 压缩数据 + descriptor）。
    /// 不含尚未写出的中央目录。见下方"进度语义"
    public prop position: Int64

    /// 当前 `add()` 是否在"落临时文件"阶段（此时 position 不增长）。
    /// 内部用 `AtomicBool`，跨线程读安全
    public prop spilling: Bool

    /// 内存路径：先算 CRC 与压缩后大小，再写 header（真实值，无 descriptor）。
    /// 返回**实际写入的条目名**——同名冲突时会被改名，见 3.3。
    /// data 超过 memoryEntryThreshold 时自动走临时文件，见 3.4。
    public func add(name: String, data: Array<Byte>): String

    /// 流式路径：边压边写，用 data descriptor 回填。适合大文件、长度未知。
    /// 返回实际写入的条目名。
    public func addFileStream(name: String, input: InputStream): String

    /// 便捷：流式加入一个文件
    public func addFile(name: String, path: Path): String

    /// 目录条目（名字以 / 结尾，无数据）。同名目录会被合并，返回规范化后的名字。
    public func addDirectory(name: String): String

    /// 写中央目录并结束。必须调用，否则文件不完整
    public func close(): Unit
}
```

**两条写入路径，按"数据是否已在内存"分流**


|                 | `add(name, data)`                              | `addFileStream(name, input)`                     |
| --------------- | ---------------------------------------------- | ------------------------------------------------ |
| CRC / 大小      | 写 header**之前**已知                          | 写完才知道                                       |
| local header    | 真实值，bit 3 = 0                              | 全 0 + bit 3 = 1 + version 45 + ZIP64 extra 占位 |
| data descriptor | 不写                                           | 写，24 字节 ZIP64 形式                           |
| 压缩数据暂存    | 需要（整条进内存）                             | **不需要**，直接流出                             |
| 内存峰值        | 单条压缩后大小（超阈值时降为固定缓冲，见 3.4） | 固定缓冲，与条目大小无关                         |
| 适用            | 配置、xml、小图片                              | 视频、日志、数据库导出                           |

**为什么保留两条，而不是统一成一条**

- 统一用 descriptor：所有小条目都带上"三个未知"，产出的文件对老工具更挑，且没必要
- 统一进内存：直接放弃大文件

两条路径共用同一套 header 写入与中央目录记录逻辑，只有"local header 怎么填 + 要不要 descriptor"不同。

**`addFileStream` 的调用方约定**

- `input` 在调用期间归 writer 使用，返回时已读完（或已抛出）
- **不要依赖 `input` 的长度**：流可能没有长度信息，一切以实际读到的字节为准
- 中途抛异常 → writer 进入"脏"状态，之后的 `close()` 抛异常；**不要试图续写**，
  半截的 local header 无法修补（descriptor 还没写）

#### 3.2.1 `position` 的进度语义

```cangjie
let w = ZipWriter(out)
for (f in files) {
    w.addFileStream(f.name, File.open(f.path))
    println("${w.position} / ${estimatedTotal} (${w.position * 100 / estimatedTotal}%)")
}
w.close()
```

三条约定：

1. **`position` 是"已写出的字节数"**，单调递增，不因条目切换而回退
2. **`close()` 之前它不含中央目录**。CD 大小约 `条目数 × 70 字节`，通常可忽略；需要精确总大小时用 `close()` 后的 `finalSize`（若将来需要，再加）
3. **`position` 不是"已完成进度"**——`addFileStream` 内部是边压边写的，调用期间 `position` 会持续增长。想报"第几个条目"的进度，得自己计条目数

#### 3.2.2 `spilling`：区分"卡住"与"准备中"

`add()` 遇到大于 `memoryEntryThreshold` 的条目时，会先把它写进临时文件（3.4）。
这段时间 `position` **完全不增长**——因为还没有字节压进 output。

```cangjie
let w = ZipWriter(out)
w.addFileStream("a.bin", aStream)
w.add("huge.bin", hugeBytes)      // 100 MB，进入落盘阶段
// 期间的轮询：
// w.position  → 不变
// w.spilling  → true
```

**只靠 `position` 会误判成"卡死"**；加上 `spilling` 就能显示"准备中"：

```cangjie
if (w.spilling) {
    ui.show("正在准备大文件…")
} else {
    ui.show("${w.position * 100 / total}%")
}
```

三条约定：

| 项 | 说明 |
|---|---|
| 语义 | **仅表示"当前 `add()` 正处于落盘阶段"**，不含 `addFileStream`（那个本来就是流式，不需要落盘） |
| 生命周期 | `add()` 进入临时文件分支前置 `true`，`addFileStream` 开始前置回 `false` |
| 代价 | 一个 `AtomicBool` + 两次原子写。读它无锁 |
| 线程安全 | **跨线程读安全**。底层是 `std.sync.AtomicBool`，不是普通 `Bool` 字段——普通字段在"写线程置位、UI 线程读"时可能读到旧值 |
| 与 `position` 的一致性 | **不保证原子一致**。可能读到 `spilling = false` 而 `position` 刚好停住（一帧的显示问题）。**不要拿两者做逻辑判断**，只用于展示 |

**为什么不做成回调**：回调会把 writer 的主循环与 UI 更新耦合（重入、异常传播、线程切换）。
一个只读布尔 + 调用方自己的轮询节奏，能解决同一个问题且没有这些负担。

**为什么不做 `progress` 回调**：回调会把 writer 的主循环与调用方的 UI 更新耦合在一起（重入、异常传播、UI 线程切换），而 `position` 只是一个 `Int64` 读，调用方想在哪儿读就在哪儿读。需要细粒度进度的场景，可以在 `addFileStream` 外面包一层计数流（`CountingInputStream`），这是调用方的事，不是 writer 的 API。

### 3.3 同名条目：写入侧消解

ZIP 格式允许多条同名条目，但解压行为依实现而异：有的取第一个、有的取最后一个、有的报错。**这种不确定性不该留给下游。**

**策略：在写入时就把同名消解掉，产出的文件里绝不会出现同名条目。**


| 情况                            | 处理                                             |
| ------------------------------- | ------------------------------------------------ |
| 同名**目录**（名字以 `/` 结尾） | **合并**：第二次遇到时直接跳过，不写第二个条目   |
| 同名**文件**                    | 第一个保留原名，后续自动加`_<N>` 后缀，N 从 2 起 |
| 改名后又撞上已有名字            | 继续递增，直到无冲突                             |

```
加入 a.txt        → a.txt
加入 a.txt        → a_2.txt
加入 a.txt        → a_3.txt
加入 a_2.txt      → a_2_2.txt   （先按规则得到 a_2.txt，发现已占用，再递增）
加入 a_2_2.txt    → a_2_2_2.txt
```

**后缀增长在"原名的 stem 上"，不在末尾追加。** 即 `a.txt` → `a_2.txt`（保留扩展名），而不是 `a.txt_2`。保留扩展名很重要：解压后双击能正常打开。

实现：

```cangjie
class EntryNameTable {
    private let used = HashSet<String>()
    private let counter = HashMap<String, Int64>()

    /// 返回实际可用的名字
    func allocate(name: String): String {
        if (used.add(name)) { return name }               // HashSet.add 返回是否新增
        var n = counter.get(name) ?? 2
        while (true) {
            let candidate = insertSuffix(name, n)
            if (used.add(candidate)) {
                counter[name] = n + 1
                return candidate
            }
            n += 1
        }
    }

    /// "dir/a.txt" -> "dir/a_2.txt"
    func insertSuffix(name: String, n: Int64): String {
        let dot = name.lastIndexOf('.')
        let slash = name.lastIndexOf('/')
        if (dot <= slash) { return "${name}_${n}" }        // 无扩展名，或点在目录名里
        return "${name[0..dot]}_${n}${name[dot..]}"
    }
}
```

边界：


| 名字         | N | 结果                                         |
| ------------ | - | -------------------------------------------- |
| `a.txt`      | 2 | `a_2.txt`                                    |
| `a`          | 2 | `a_2`                                        |
| `dir.d/file` | 2 | `dir.d/file_2`（点在目录段里，不当作扩展名） |
| `.gitignore` | 2 | `.gitignore_2`（点在开头，视为无扩展名）     |
| `a.`         | 2 | `a_2.`（末尾点仍算扩展名分隔）               |

**`add()` 返回实际名字**，调用方需要知道最终名字时用它；不关心时忽略返回值即可。

**读取侧遇到外部产生的同名 ZIP**：`read(name)` 返回**最后一个**（等价于"后写覆盖"，与 Info-ZIP / 7-Zip 的解压行为一致）。`readAll(name): Array<Array<Byte>>` 返回全部，供需要审计的场景使用。`entries()` 不合并，原样列出所有条目。

> 读写两侧的不对称是刻意的：写入侧能改名（还没落盘），读取侧不能（文件已经存在）。读取侧只能在"取第一个 / 取最后一个 / 报错"里选一个，取最后一个与主流解压器一致。

### 3.4 大条目：`add()` 的平台相关阈值

内存路径的峰值是 `data.size + compressed.size`。对**不可压缩**的数据（已是 JPEG/MP4/ZIP），`compressed ≈ data`，峰值就是 **2 × 条目大小**。100 MB 的条目会吃掉 200 MB 内存。

**阈值：`data.size` 超过 `memoryEntryThreshold` 时，自动落临时文件改走流式路径。**
该阈值**按平台分档**（Linux 64 MB，OHOS 及其他 16 MB），理由见 3.4.2。

```
add(name, data):
  if (data.size <= memoryEntryThreshold):
      内存路径（原逻辑）
  else:
      tmp = 创建临时文件
      写 data 进 tmp
      addFileStream(name, File.open(tmp))      // f_zip 从 tmp 读，边压边写
      删除 tmp
```

效果：内存峰值从 `data + compressed` 降到 `data + 固定缓冲`。**`data` 本身省不掉**（它是调用方传进来的），省掉的是"压缩结果"那一份。对不可压缩数据，峰值直接减半。

#### 3.4.1 临时目录：OHOS 上没有 `/tmp`

**这是必须写清的一条。** 鸿蒙的应用沙箱里没有 `/tmp`，硬编码这个路径会直接失败。

解析顺序：

```
1. ZipWriterOptions.tempDir（显式指定）
2. 环境变量 TMPDIR
3. 系统临时目录（std.fs 提供）
4. 当前工作目录下的 .fountain_tmp/（兜底，自动创建）
```

四个都失败 → 抛 `ZipException("无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}")`。

**不做"落盘失败就退回内存"的降级**：那等于把"OOM 风险"重新引回来，而且调用方完全无感。宁可当场报错。

#### 3.4.2 阈值按平台分档：Linux 64 MB，其他 16 MB

```cangjie
public class ZipWriterOptions {
    /// add() 走内存路径的条目大小上限，超过则落临时文件。
    /// 默认按平台：Linux 64 MB，OHOS 及其他 16 MB
    public var memoryEntryThreshold: Int64 = defaultMemoryEntryThreshold()
    /// 临时目录。None = 按 3.4.1 的顺序解析
    public var tempDir: ?Path = None
    /// 压缩方法，默认 Deflate；Stored 用于已压缩数据
    public var method: CompressionMethod = CompressionMethod.Deflate
}

@When[os == "Linux" && env == "gnu"]
private func defaultMemoryEntryThreshold(): Int64 { 64 * 1024 * 1024 }

@When[os != "Linux" || env != "gnu"]
private func defaultMemoryEntryThreshold(): Int64 { 16 * 1024 * 1024 }
```

> **实现修正（2026-10-28，v0.7 原文只写了 `os`）**：鸿蒙的编译目标 `aarch64-linux-ohos`
> 在 `@When` 里 **`os` 也是 `"Linux"`**，区别在 `env`（`gnu` / `ohos`）。
> 只按 `os` 分档会让 OHOS 拿到服务器档的 64 MB，与本节的意图相反（参考 `f_base/src/OS.cj`
> 的既有写法：`@When[os == "Linux" && env == "gnu"]` 与 `@When[os == "Linux" && env == 'ohos']`）。
> 因此条件必须是 `os == "Linux" && env == "gnu"`，另一半取反 `os != "Linux" || env != "gnu"`。

**为什么分两档**：

| 平台                      | 默认  | 理由                                                                         |
| ------------------------- | ----- | ---------------------------------------------------------------------------- |
| Linux（服务器 / 桌面）    | 64 MB | 可用堆通常几 GB；64 MB 条目走内存路径峰值 128 MB，占比很小                   |
| OHOS（手机 / 平板）/ 其他 | 16 MB | 可用堆常在 512 MB~2 GB；16 MB 条目峰值 32 MB 已占手机的 3~6%。再大就该走流式 |

**为什么按 `os` 而不是探测可用内存**：

1. **没有可靠的跨平台 API。** 读 `/proc/meminfo` 是 Linux 专属；OHOS 沙箱里未必可读；
   而且"可用堆"与"物理内存"是两回事（进程堆上限、GC 策略都影响）。
2. **行为随环境变化会让问题不可复现。** 同一份代码在开发机（32 GB）和客户现场（4 GB）
   走不同路径，bug 只在一边出现，排查成本极高。
   按 `os` 分档是**编译期确定的**，代码路径可预测。
3. **平台分档已经能覆盖 99% 的场景。** 剩下的 1%（Linux 小内存设备、容器 memory limit）
   本来就该由调用方显式指定。

> **关于容器**：容器内进程读到的是**容器的 cgroup limit**，不是宿主机物理内存。
> 所以"容器里读到的内存不准"这个担心**不成立**——真要探测，读 cgroup 是准的。
> 不做探测的理由只有一条：**阈值随环境变化会让问题不可复现**，而不是"读不到"。

#### 3.4.2.1 `@When` 的语义边界

**`@When` 是通用语义，适用于各种声明**（`func`、`class`、`let`、`struct`…），
不是本模块的特例。两个互补的 `@When` 在任一编译目标上**只会生成其中一个**，
所以不会出现重复定义。

**但它只能用于声明，不能用于语句。** 这意味着：

```cangjie
// ✅ 可以：同一签名两份声明，各带一个 @When
@When[os == "Linux" && env == "gnu"]
private func threshold(): Int64 { 64 * 1024 * 1024 }
@When[os != "Linux" || env != "gnu"]
private func threshold(): Int64 { 16 * 1024 * 1024 }

// ❌ 不可以：条件写在函数体里
private func threshold(): Int64 {
    @When[os == "Linux"]        // 编译不过，@When 不能修饰语句
    return 64 * 1024 * 1024
}
```

**所以平台分叉必须"整份声明各写一遍"**，不能"一个函数体里分支"。
好处是编译器保证只有一份存在、零运行期判断；代价是代码有重复，
要靠注释说明"这两份必须同步修改"。

**本模块只有两处用到**：`defaultMemoryEntryThreshold()`（3.4.2）
和它的对立面。加起来四份声明、每份一行，重复成本可忽略。

**覆盖方式（两种预设 + 显式值）**：

```cangjie
public static func forServer(): ZipWriterOptions {
    ZipWriterOptions(memoryEntryThreshold: 64 * 1024 * 1024)
}
public static func forLowMemory(): ZipWriterOptions {
    ZipWriterOptions(memoryEntryThreshold: 8 * 1024 * 1024)
}

// 容器里 memory limit = 256 MB
let opts = ZipWriterOptions(memoryEntryThreshold: 4 * 1024 * 1024)
```

**两个预设是普通静态工厂，不是 `const`。** 返回的实例**可自由修改**：

```cangjie
let opts = ZipWriterOptions.forServer()
opts.memoryEntryThreshold = 32 * 1024 * 1024     // 合法，改就是了
opts.method = CompressionMethod.Stored
```

也就是说预设只是"一次性设好一组默认值的便捷构造"，不是不可变模板。这样调用方
"拿服务器档当基线再微调一项"很自然，不需要先查默认值再手写全字段。

**副作用**：每次调用都返回**新对象**，可以放心改，不影响后续调用拿到的实例。

**`addFileStream` / `addFile` 不受这个阈值影响**——它们本来就是流式的，无论多大都不进内存。

```
add(name, data):
  if (data.size <= memoryEntryThreshold):
      内存路径（原逻辑）
  else:
      tmp = 创建临时文件
      写 data 进 tmp
      addFileStream(name, File.open(tmp))      // f_zip 从 tmp 读，边压边写
      删除 tmp
```

效果：内存峰值从 `data + compressed` 降到 `data + 固定缓冲`。**`data` 本身省不掉**
（它是调用方传进来的），省掉的是"压缩结果"那一份。对不可压缩数据，峰值直接减半。

#### 3.4.3 进入临时文件分支时打 debug 日志

```cangjie
if (data.size > memoryEntryThreshold) {
    Log.debug(
        "zip: entry '${name}' is ${data.size} bytes (> ${memoryEntryThreshold}), " +
        "spilling to temp file: ${tmpPath}"
    )
    // 写 tmp、addFileStream、删 tmp
}
```

**为什么需要这条日志**：`add()` 走临时文件分支时，`position` 会在"落盘"阶段停止增长
（真正的压缩要等 `addFileStream` 开始才启动）。调用方如果按 `position` 报进度，
会看到一段莫名的"卡住"——尤其当条目有几百 MB、落盘要好几秒时。

有了这条日志，排查时能立刻对上："卡住的那几秒是在落盘，不是死锁"。

**同时 `spilling` 会在这一段置 `true`**（3.2.2），UI 可以据此显示"准备中"。
日志与 `spilling` 是同一件事的两个出口：日志给人排查，`spilling` 给程序判断。

**日志级别用 debug 而不是 info**：正常路径不该刷屏；只有排查进度问题时才开。
`tmpPath` 也打出来，方便确认临时目录是否落在预期位置（3.4.1 的四级解析）。

### 3.5 便捷函数

```cangjie
/// 把 ZIP 全部解压到目录
public func unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64

/// 从文件解压（走 seek，不缓冲整包）
public func unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64

/// 把目录打包成 ZIP（每个文件走 addFileStream，不整体进内存）
public func zip(output: OutputStream, dir: Path): Int64
```

`zip(output, dir)` 内部对每个文件用 `addFileStream`——这是流式路径最直接的收益：
打包一个 2 GB 的目录不需要 2 GB 内存。

---

## 4. 读取流程

```
1. 打开随机访问源
   · init(input) → 全量读进 f_io.ByteBuffer
   · init(path)  → 打开 std.fs.File，后续 seek + 定长 read
2. 定位 EOCD：读尾部窗口（min(fileLength, 22 + 65535)），从后往前扫 0x06054b50
   · 对每个候选校验「22 + 注释长度 == 到文件尾的距离」，取第一个自洽的
3. 若条目数 / CD 大小 / CD 偏移是哨兵 → 读 EOCD64 定位器（前 20 字节）→ 读 EOCD64
4. seek 到 CD 偏移，逐条解析 central directory → ZipEntry 列表
5. read(name) / open(name)：
   a. 用 entry.localHeaderOffset 定位 local header
   b. 跳过 name + extra，得到数据起点
   c. 按 method 解压：Stored(0) 直接切片；Deflate(8) 走 CompressInputStream(DeflateFormat)
   d. 校验 CRC32 与 uncompressedSize
```

**关键点：以中央目录为准，不信 local header。**

bit 3（data descriptor）置位时，local header 里的 crc 和 size 可能是 0，真实值在数据之后。
中央目录里的一定是对的。所以大小、CRC、方法一律从中央目录取。

**两种模式的差别只在"怎么读到字节"，解析逻辑完全一致。**


| 模式 | 实现                                                       |
| ---- | ---------------------------------------------------------- |
| 流   | 全量入`ByteBuffer`，之后都是内存切片                       |
| 文件 | `File.seek` + 定长 `read`；CD 区域一次读入，条目数据按需读 |

**`init(path)` 的三个实现要点**

1. **尾部窗口扫不到就失败，不要退化成全文件扫描。** 22 + 65535 是规范给的上界
   （EOCD 最大 22 字节 + 注释最大 65535 字节）。扫不到说明不是 ZIP 或被截断；
   继续往前扫只会把"文件损坏"拖成"读完 2 GB 才报错"。
2. **CD 区域一次读完。** 它是整个访问模式里唯一值得整块读的部分；条目数据才是按需读。
3. **`open(name)` 另开 File 句柄。** 复用 reader 自己的句柄会在并发解压时互相打乱光标。

**EOCD 定位的陷阱**：`0x06054b50` 可能出现在注释或压缩数据里。从尾部往前扫，对每个候选校验
"22 + 注释长度 == 到文件尾的距离"，取第一个匹配的。

---

## 5. 写入流程

### 5.1 整体顺序

```
【内存路径 add(name, data)】
  记录 offset = 当前写入位置
  crc = crc32(data)
  compressed = deflate(data)                 // 整条进内存
  写 local header（真实 crc / compSize / uncompSize，bit 3 = 0）
  写 compressed

【流式路径 addFileStream(name, input)】
  记录 offset = 当前写入位置
  写 local header（crc=0、compSize=0、uncompSize=0、bit 3 = 1、version = 45、ZIP64 extra 占位）
  input ──▶ Crc32InputStream ──▶ CompressOutputStream ──▶ CountingOutputStream ──▶ output
            （算 CRC + 数原始字节）   （deflate）            （数压缩后字节）
  写 data descriptor（24 字节）

【收尾 close()】
  cdStart = 当前写入位置
  逐条写 central directory header（流式条目的真实 crc / 大小在这里）
  if 条目数 > 0xFFFF 或 cdStart / cdSize 越界 → 写 EOCD64 + 定位器
  写 EOCD（必要时填哨兵）
```

**三个包装流的顺序不能换。**

- CRC 算在**未压缩**字节上 → `Crc32InputStream` 必须紧贴 `input`
- 压缩后大小要数**压缩后**字节 → `CountingOutputStream` 必须在 `CompressOutputStream` **之后**
- `uncompressedSize` 就是 `Crc32InputStream` 读过的字节数，不需要第二个计数器

写反的后果很隐蔽：CRC 对了但大小差一截，或者大小对了但 CRC 是压缩流的。
外部工具会报 "CRC mismatch"，而我们自己的 reader 因为是同一套错误逻辑，反而读得通。
这正是第 9 章强调"必须用外部工具验证"的原因。

### 5.2 data descriptor：只在流式路径用

descriptor 的作用是"local header 先写 0，真实值放到数据之后"。它只解决一件事：
**写 header 时还不知道 CRC 和压缩后大小。**

所以判据不是"哪个更先进"，而是"信息够不够"：


| 情况                          | 用哪个                                |
| ----------------------------- | ------------------------------------- |
| 数据已在内存（`Array<Byte>`） | 直接算，写真实值，**不用 descriptor** |
| 从流读、长度未知              | 必须用 descriptor                     |

descriptor 的字节布局（**必须带签名**，否则与后续数据无法区分）：


| 形式                            | 长度   | 内容                                                  |
| ------------------------------- | ------ | ----------------------------------------------------- |
| 标准                            | 16     | `0x08074b50` + crc32(4) + compSize(4) + uncompSize(4) |
| **ZIP64（流式条目一律用这个）** | **24** | `0x08074b50` + crc32(4) + compSize(8) + uncompSize(8) |

#### 为什么流式条目一律用 ZIP64 形式

descriptor 有两种宽度，而**读端要靠 local header 里的 ZIP64 extra 判断用哪种**。
可 local header 是在数据之前写的——那时大小未知，无法判断"会不会超 4 GB"。于是只有两条路：


| 方案                                                                  | 可行性                                                   |
| --------------------------------------------------------------------- | -------------------------------------------------------- |
| 先按 4 字节写，超了再回退改                                           | 要求输出流可 seek 回退，与"写任意`OutputStream`"直接冲突 |
| **一律按 ZIP64 写**（extra 占位 0/0、version 45、descriptor 24 字节） | ✅ 头部一次写定，无需回退                                |

代价是每个流式条目多 20 字节 extra + 8 字节 descriptor 长度。用流式写的本来就是大文件，可以忽略。

> 校验：`unzip -t`、Python `zipfile.testzip()`、7-Zip 各跑一遍流式样本。
> 若有解压器不接受 ZIP64 形式的 descriptor，记入第 8 章的「已知兼容性例外」，**不因此改回 4 字节**——
> 改回去意味着要么放弃大文件，要么引入可回退的输出流。

### 5.3 空目录条目

目录条目名字以 `/` 结尾，`compressedSize = uncompressedSize = 0`，`method = 0`，CRC = 0，
external attributes 置目录位（Unix 下 `0x41ED0000` 之类）。很多解压器靠名字尾部 `/` 判断目录，
所以这一步不能省。

---

## 6. 关键实现细节

### 6.1 CRC32

直接复用 `f_util.crc32(data: Array<Byte>): UInt32`。

**注意**：CRC 是对**原始未压缩数据**算的，不是压缩后。写入时顺序必须是"先算 CRC，再压缩"，别搞反。

### 6.2 文件名编码 —— 这是中文用户的头号问题

ZIP 规范原本用 CP437，但中文 Windows 打包的 ZIP 常用 GBK，且很多工具不置 bit 11。于是"解压出来是乱码"成了经典问题。

**读取时的判定链**：

```
if (bit 11 置位) → 按 UTF-8 解码
else:
    1. 尝试 UTF-8 严格解码（非法序列即失败）
    2. 失败 → 尝试 GBK
    3. 仍失败 → 按 Latin-1 逐字节映射（保证不抛异常，至少能显示）
```

**写入时**：

```
if (文件名全是 ASCII) → 不置 bit 11，直接写
else → 置 bit 11，UTF-8 编码写入
```

这条能覆盖绝大多数现代解压器（Windows 资源管理器、macOS 归档工具、7-Zip、unzip 都认 bit 11）。

**回退链固定写死，不引入编码检测库**。理由：ZIP 文件名通常很短（几个到几十字节），编码检测在小样本上准确率低、误判代价高（把 GBK 判成 UTF-8 就是全乱码）；而"UTF-8 严格失败 → GBK → Latin-1"这条链对两类常见情况已经够用。若将来需要，可在 f_io 层面加检测能力，f_zip 通过参数注入，而不是硬依赖。

### 6.3 压缩方法白名单


| method | 名称      | 处理                   |
| ------ | --------- | ---------------------- |
| 0      | Stored    | ✅ 直接拷贝            |
| 8      | Deflated  | ✅ zlib DeflateFormat  |
| 9      | Deflate64 | ❌ 报错（zlib 不支持） |
| 12     | BZIP2     | ❌                     |
| 14     | LZMA      | ❌                     |
| 93     | Zstandard | ❌                     |
| 95     | XZ        | ❌                     |
| 98     | PPMd      | ❌                     |

遇到不支持的 method 要报**具体的方法名**，不要只说"解压失败"——用户需要知道是"这个 ZIP 用了 zip 不支持的算法"，而不是"文件坏了"。

### 6.4 小端读写

ZIP **全部字段是小端**。默认的 `writeUInt32(value)` 若不带 `endian` 参数，行为取决于底层实现，很容易整份文件都写错。

规避方式：**所有整数字段读写都显式传 `Endian.Little`**，不要依赖默认值。

```cangjie
// 读
let sig  = buf.readUInt32(endian: Endian.Little)
let flag = buf.readUInt16(endian: Endian.Little)

// 写
buf.writeUInt32(0x04034b50, endian: Endian.Little)
buf.writeUInt16(20, endian: Endian.Little)
```

**建议再包一层语义化函数**，让代码读起来是"写 local header"而不是一堆数字：

```cangjie
func writeLocalHeader(buf: ByteBuffer, e: ZipEntry): Unit
func readCentralEntry(buf: ByteBuffer): CentralEntry
```

否则后续维护时，很难确认第 7 个 `writeUInt16` 对应的是哪个字段。

---

## 7. 安全

### 7.1 Zip Slip（路径穿越）

条目名可能是 `../../etc/passwd` 或 `/abs/path`。解压时不校验就会写出目标目录。

**规则**：

```
1. 拒绝绝对路径（以 / 或盘符开头）
2. 拒绝包含 .. 段的路径
3. 规范化后必须仍以目标目录为前缀，否则拒绝
4. 符号链接条目（external attributes 的 Unix mode 含 S_IFLNK）跳过
```

#### 7.1.1 符号链接：无条件跳过

**决定：一律跳过，不跟随、不重建、不报错。**

三条理由：

1. **跟随会突破目标目录。** `link -> /etc/passwd` 是合法的 ZIP 条目，跟随它打包/解压等于让压缩包变成任意文件读取器。Zip Slip 的第 1-3 条规则能挡住 `../` 路径，但挡不住符号链接——它是"先落地再看指向"的两步攻击。
2. **重建链接在目标平台上未必可行。** OHOS 沙箱、FAT32、Windows 无权限时都创建不了符号链接；带权限位的 ZIP 在解压到这些文件系统时，行为依实现而异。
3. **知识库场景不需要它。** 打包/解压的用途是"搬数据"，不是"还原目录结构"。丢了符号链接，数据一个字节都不少。

具体行为：


| 场景                                       | 行为                                                     |
| ------------------------------------------ | -------------------------------------------------------- |
| `unzip()` 遇到 S_IFLNK                     | 跳过，记一条 warning（含条目名与链接目标）               |
| `zip(output, dir)` 遇到符号链接            | 跳过，记一条 warning                                     |
| `zip(output, dir)` 遇到**目录符号链接**    | 跳过整个子树，不递归（否则会无限递归进`/`）              |
| `ZipReader.read(name)` 直接读符号链接条目  | 返回链接目标字符串的字节（它是普通条目，读取层不做策略） |
| `ZipWriter.addFile(path)` 传入符号链接路径 | 跟随（这是调用方显式指定单个文件，它想要的就是目标内容） |

**判别方法**：`externalAttributes >> 16` 得到 Unix mode，`(mode & 0xF000) == 0xA000` 即为符号链接。这一步只在读取时做——写入侧通常没有 mode 信息（除非调用方显式给）。

**为什么 `zip()` 和 `unzip()` 一致跳过、而 `addFile()` 跟随**：`zip()`/`unzip()` 处理的是"整棵目录树"，策略必须保守；`addFile()` 是调用方指名道姓要一个文件，它已经知道自己在干什么。

### 7.2 ZIP 炸弹

高压缩比文件（如 42.zip）解压后可达 PB 级。上限做成**可配置**，默认值按"常见文档包"给：

```cangjie
public struct ZipLimits {
    /// 单条目解压上限
    public let maxEntrySize!: Int64 = 512 * 1024 * 1024          // 512 MB
    /// 单次读取的总解压上限
    public let maxTotalSize!: Int64 = 2 * 1024 * 1024 * 1024     // 2 GB
    /// 中央目录里可接受的条目数上限（**仅用于读取**）
    public let maxEntries!: Int64 = 65535
    /// 压缩比告警阈值（只告警，不拦截）
    public let ratioWarnThreshold!: Int64 = 1000
}
```

四个默认值就是上面这些，**可按实例覆盖**：`ZipReader(path, limits: ZipLimits(maxEntrySize: 8 * 1024 * 1024 * 1024))`。

四条规则：

1. 单条目超 `maxEntrySize` → 中断并报错，**不返回部分数据**
2. 累计超 `maxTotalSize` → 中断；计数按**实际解压出的字节**累加
3. 条目数超 `maxEntries` → **在解析中央目录时就拒绝**，不要先建完列表再判
4. 压缩比 > `ratioWarnThreshold` → 记告警日志，继续（压缩比高不等于恶意，有的是重复数据）

#### 7.2.1 `maxEntries` 只服务读取，写入侧自动升级 ZIP64

**原设计的问题**：`maxEntries` 同时被当成"安全上限"和"非 ZIP64 的格式上限"，两个语义混在一个参数里。

- 作为**安全上限**：读一个恶意 ZIP 时，防止中央目录里声明 40 亿条目把我们撑爆
- 作为**格式上限**：非 ZIP64 的 EOCD 里条目数字段只有 2 字节，最大 65535；超过就必须写 ZIP64

这两件事的触发条件、处置方式、责任方都不同。**现在彻底分开：**


|          | 读取侧                         | 写入侧                             |
| -------- | ------------------------------ | ---------------------------------- |
| 参数     | `ZipLimits.maxEntries = 65535` | **无参数**                         |
| 语义     | 安全上限：防恶意/畸形文件      | 无上限                             |
| 超限行为 | 拒绝，抛`ZipException`         | **自动升级 ZIP64**，不报错、不告警 |
| 依据     | 中央目录里的条目数             | 实际已写入的条目数                 |

写入侧的自动升级规则：

```
写 close() 时：
  if (entryCount <= 0xFFFF && cdOffset <= 0xFFFFFFFF && cdSize <= 0xFFFFFFFF && 无条目需要 ZIP64):
      写普通 EOCD
  else:
      写 EOCD64 + EOCD64 定位器 + 普通 EOCD（其中的字段填哨兵值 0xFFFF / 0xFFFFFFFF）
```

**为什么写入侧不设上限**：写入是调用方自己的行为，不存在"恶意输入"；条目数多到把中央目录撑爆（`条目数 × 70 字节`）时，先耗尽的是内存，不是格式。加一个人为上限只会让"导出 100 万个文件"这种合法需求莫名失败。

**读取侧的默认值 65535 是否合适**：合适。真实 ZIP 极少超过这个数（Linux 内核源码包约 8 万文件，已经需要 ZIP64，但那类包本来就是 ZIP64）。安全上限宁紧勿松，需要时可调大：

```cangjie
ZipReader(path, limits: ZipLimits(maxEntries: 1_000_000))
```

**一个易错点**：非 ZIP64 的 EOCD 里条目数字段是 2 字节，ZIP64 的是 8 字节。读取时要**先看普通 EOCD，发现字段是 0xFFFF / 0xFFFFFFFF 才去找 EOCD64**，不能无条件按 8 字节读。

**不能只看 header 里的 `uncompressedSize`**——它可以伪造。必须边解压边计数。

**`maxTotalSize` 的语义是"每个 `ZipReader` 实例的累计"，不是全局。** 要限制一次批量导入的总量，
调用方得自己持有剩余配额并逐次传进 `limits`。这一点要写进 API 文档，
否则容易误以为它是一道全局闸门。

### 7.3 加密 ZIP

bit 0 或 bit 6 置位 → 直接报错"不支持加密 ZIP"。不做部分支持，避免出现"解出来一半是对的"的情况。

bit 0 或 bit 6 置位 → 直接报错"不支持加密 ZIP"。不做部分支持，避免出现"解出来一半是对的"的情况。

---

## 8. 错误处理

```cangjie
public class ZipException <: Exception {
    public init(message: String)
}
```


| 情况                 | 异常信息要点                                                 |
| -------------------- | ------------------------------------------------------------ |
| 找不到 EOCD          | `不是有效的 ZIP 文件（未找到中央目录）`                      |
| CD 偏移越界          | `中央目录偏移 ${off} 超出文件长度 ${len}`                    |
| 不支持的 method      | `不支持压缩方法 ${method}（${name}）`                        |
| 加密                 | `不支持加密 ZIP（${name}）`                                  |
| CRC 不匹配           | `CRC 校验失败：期望 ${exp}，实际 ${act}（${name}）`          |
| 解压超限             | `解压体积超过上限 ${limit}（${name}）`                       |
| 条目数超限           | `条目数 ${n} 超过上限 ${limit}`                              |
| ZIP64 结构损坏       | `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）` |
| data descriptor 缺失 | `缺少 data descriptor（bit 3 置位但数据后无签名）`           |
| 流式写入中途失败     | `条目 ${name} 写入中断，ZIP 结构不完整`                      |
| 路径非法             | `条目路径非法：${name}`                                      |

### 8.1 已知兼容性例外

按 1 节的"以 APPNOTE 为准"原则，遇到与规范不一致的真实文件时**记录在这里，而不是改代码去迁就**。
每条要写清：样本来源、现象、规范原文位置、我们的处理（拒绝 / 容忍 / 特判）。


| #      | 现象 | APPNOTE 依据 | 处理 |
| ------ | ---- | ------------ | ---- |
| （空） | —   | —           | —   |

> 这张表一开始是空的。它的作用是**防止"悄悄加个 if 让它能读"**——所有偏离都要留痕，
> 否则半年后没人说得清某个分支到底在修什么问题。

---

## 9. 测试要点

**构造性测试**（自己写、自己读）

- 空 ZIP（0 条目）
- 单文件 Stored / Deflate
- 多文件 + 目录条目
- 空文件（0 字节）条目
- 中文文件名
- 嵌套路径 `a/b/c.txt`

**流式与 ZIP64 专项**（本轮新增能力，必须单独覆盖）


| 用例                       | 验证点                                                                     |
| -------------------------- | -------------------------------------------------------------------------- |
| `addFileStream` 单条目     | local header bit 3 = 1、version = 45、extra 含`0x0001`、descriptor 24 字节 |
| 内存路径 + 流式路径混合    | 同一文件里两种条目并存，中央目录里 sizes 都对                              |
| 单条目 > 4 GB              | 稀疏文件或重复数据构造；外部工具能列出并校验                               |
| 条目数 > 65535             | EOCD64 + 定位器被写出；`unzip -l` 计数正确                                 |
| 流式条目但内容很小         | 仍然按 ZIP64 形式写，不能"优化"成 4 字节 descriptor                        |
| `init(path)` 解压 1 GB 包  | 进程 RSS 不随文件大小线性增长                                              |
| `open(name)` 并发 4 个条目 | 各自独立句柄，数据不串                                                     |

**兼容性测试**（外部工具造、我们读）


| 来源               | 验证点                       |
| ------------------ | ---------------------------- |
| Linux`zip`         | 标准 deflate、UTF-8 名       |
| Windows 资源管理器 | 可能 GBK 名、bit 11 未置位   |
| 7-Zip              | 可能含 ZIP64                 |
| macOS 归档工具     | 含`__MACOSX/` 与 `._` 资源叉 |
| Python`zipfile`    | 各种边界                     |

**反向测试**（我们写、外部工具读）

写出的 ZIP 必须能被 `unzip -t`、`7z t`、Python `zipfile.testzip()` 校验通过。**这是最容易发现问题的一环**——自己读自己写可能互相容忍同一个错误。


| 工具                      | 重点看什么                                               |
| ------------------------- | -------------------------------------------------------- |
| `unzip -t` / `unzip -l`   | 流式条目的 descriptor 是否被正确跳过；ZIP64 条目名与大小 |
| Python`zipfile.testzip()` | `bit 3` + ZIP64 extra 组合的读取路径（它的实现较严格）   |
| `7z t`                    | 对 ZIP64 的宽容度最高，用作"能不能读"的兜底              |

**流式条目要单独跑一轮**：只用 `add` 造的样本覆盖不到 descriptor，而 descriptor 恰恰是最容易写错的部分。

**恶意样本**

- Zip Slip 路径
- 高压缩比炸弹（小样本即可，如 10 MB 解压到 1 GB）
- 截断的 ZIP（模拟下载中断）
- 注释里嵌入 EOCD 签名（测试 EOCD 定位健壮性）

---

## 10. 性能预估


| 操作                                    | 估算                                                      |
| --------------------------------------- | --------------------------------------------------------- |
| 读取 1000 条目的中央目录                | < 10 ms                                                   |
| 解压 100 MB（deflate）                  | 1~3 s（取决于 CPU）                                       |
| 压缩 100 MB（默认级别）                 | 3~8 s                                                     |
| 内存占用（`ZipReader(input)` 全量缓冲） | 文件大小 × 1                                             |
| 内存占用（`ZipReader(path)`）           | 尾部窗口 ≤ 64 KB + CD 区域 + 单条输出                    |
| 内存峰值（`addFileStream`）             | 压缩器缓冲（`bufLen`）+ 计数包装，**与条目大小无关**      |
| 内存峰值（`add`，≤ 阈值）              | 原始 + 压缩后两份，约`2 × 条目大小`                      |
| 内存峰值（`add`，> 阈值）               | 原始 + 固定缓冲，约`1 × 条目大小`（自动落临时文件，3.4） |

**`add` 的内存是 `2 × 条目大小` 而不是 `1 ×`**：`data` 本身在内存，`deflate(data)` 又产出一份。
所以超过 `memoryEntryThreshold` 的条目自动落到临时文件走流式路径（3.4），峰值降回 `1 ×`。

**瓶颈在 deflate 本身，容器层开销可忽略。** 如果要优化，方向是 `BestSpeed` 级别 + 更大的 `bufLen`。

---

## 11. 实施顺序


| 阶段     | 内容                                                          | 验收                                                                                                                              |
| -------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **P0**   | CRC 封装 +**小端读写工具函数（f_zip 内部）**                  | CRC 与已知向量一致；`readUInt32LE` 越界返回 `None` 且游标不位移                                                                   |
| P1       | `ZipReader(input)`：EOCD → CD → 条目列表                    | 能列出外部 ZIP 的所有条目                                                                                                         |
| P2       | 解压（Stored + Deflate）+ CRC 校验                            | `unzip` 出来的文件逐字节一致                                                                                                      |
| **P2.5** | **`ZipReader(path)`：`File.seek` 窗口读**                     | 1 GB 样本能列出条目；`open(name)` 解压时 RSS 不随文件增长                                                                         |
| P3       | `ZipWriter.add` + 中央目录 + EOCD                             | 写出的 ZIP 能被`unzip -t` 通过                                                                                                    |
| P4       | 多条目 + 目录 + 中文名                                        | 中文名在 Windows/macOS 都正常                                                                                                     |
| **P4.5** | **`addFileStream` + data descriptor**                         | descriptor 被`unzip -t` / `zipfile.testzip()` / `7z t` 三家认可                                                                   |
| **P4.6** | **ZIP64 写入**（extra + EOCD64）。含"条目数 > 65535 自动升级" | > 4 GB 条目、> 65535 条目两个样本外部工具可读                                                                                     |
| P5       | 安全校验（Zip Slip、ZipLimits、炸弹样本、符号链接跳过）       | 恶意样本被拒绝；上限可覆盖；符号链接不落地                                                                                        |
| **P6**   | **同名消解 + `position` + `add` 大条目落盘 + 平台阈值**       | 连续`add("a.txt")` 三次得到 `a.txt`/`a_2.txt`/`a_3.txt`；`position` 单调；100 MB 条目在 Linux 上峰值 < 110 MB，在 OHOS 上 < 30 MB |

**P3 是关键里程碑**：能写出被外部工具认可的 ZIP，才算真正跑通格式理解。
小端读写已并入 P0，**不再有外部前置任务**——它只是十几个私有函数，没有跨模块协调成本。

**为什么 P4.5 / P4.6 排在 P3 之后而不是并进 P3**：它们各自引入一类"读端可能不认"的风险
（descriptor 宽度、ZIP64 哨兵）。先把最简单的 ZIP 写到三家工具都认，再加这两层，
出问题时能立刻判断是新加的那层引起的，而不是在一堆变量里猜。

**P2.5 可以提前到 P2 之后立刻做**：它只影响"怎么读到字节"，与解析逻辑正交，
早点做能让后续所有大文件测试都用上流式读取，省内存也省时间。

---

## 12. 已定事项与剩余问题

### 12.1 已定（不再讨论）

| # | 事项 | 结论 | 落点 |
|---|---|---|---|
| 1 | 文件读取 | **需要** `ZipReader(path)`：走 `File.seek`，不用 `MMapFile`（Linux-only） | 3.1 / 4 |
| 2 | 流式写大文件 | **需要** `addFileStream` + data descriptor，descriptor 一律 ZIP64 形式 | 3.2 / 5.2 |
| 3 | ZIP64 写入 | **需要**，与读取同等对待；不越界时不写 | 2.4 |
| 4 | 解压上限 | 默认 512 MB / 2 GB 不变，改为 `ZipLimits` 可覆盖 | 7.2 |
| 5 | 第三方实现 | **长期约束：不引入**；变更需走 1 节的复审约定 | 1 |
| 6 | 写入进度 | **暴露** `ZipWriter.position: Int64`（已写出字节数，不含 CD） | 3.2.1 |
| 7 | 落盘状态 | **暴露** `ZipWriter.spilling: Bool`，UI 据此显示"准备中"而非"0%" | 3.2.2 |
| 8 | 同名条目 | **写入侧消解**：目录合并；文件第一个用原名，后续 `_2` `_3`… | 3.3 |
| 9 | 符号链接 | **跳过**（`unzip` / `zip` 都跳过）；`addFile` 跟随 | 7.1.1 |
| 10 | `maxEntries` | **只服务读取**（安全上限 65535）；**写入侧无上限，越界自动写 ZIP64** | 7.2.1 |
| 11 | `add` 大条目 | **平台相关阈值**（Linux 64 MB / 其他 16 MB），超过自动落临时文件 | 3.4 |
| 12 | 阈值默认值 | **按 `os` + `env` 编译期分档**（`os == "Linux" && env == "gnu"` 为服务器档，其余 16 MB）；**就两个 `@When` 分支，任一时刻只有一个存在** | 3.4.2 |
| 13 | 不做内存探测 | 不按可用内存动态算阈值。**容器内进程读到的是容器 cgroup limit（不是宿主机内存）**，所以"容器里读错"这个担心不成立；不做是因为**行为不可复现**，不是读不到 | 3.4.2 |
| 14 | 预设形态 | `forServer()` / `forLowMemory()` 是**静态工厂**，返回实例**可自由修改**；每次返回新对象 | 3.4.2 |
| 15 | 改名后缀 | **从 `_2` 起**（"第二个"），不做 `_1` | 3.3 |
| 16 | 写入方法返回值 | **全部返回实际写入的名字** | 3.2 |
| 17 | 落盘日志 | 进入临时文件分支时打 **debug 日志**（条目名、大小、阈值、tmpPath） | 3.4.3 |
| 18 | `spilling` 的实现 | **`AtomicBool`**（不是普通 `Bool`），跨线程读安全 | 3.2.2 |
| 19 | `spilling` 与 `position` | **不保证原子一致**，只用于展示，不能做逻辑判断 | 3.2.2 |
| 20 | `@When` 语义 | **通用语义**，适用于各种声明；**只能用于声明**，不能修饰语句；互补分支只生成一个 | 3.4.2.1 |
| 21 | 容器内存 | 容器内读到的是 **cgroup limit**（不是宿主机内存）；不做探测的理由是"不可复现"，不是"读不到" | 3.4.2 |

### 12.2 仍需确认

**暂无阻塞项。** 二十一项决策已全部落地，可以进入实施。

实施前需要实测的一条：

1. **`forLowMemory()` 的 8 MB 是否合适？**
   这是拍的。对"内存 256 MB 的嵌入式设备"，8 MB 条目峰值 16 MB 尚可；
   对"512 MB 手机"，16 MB 更合适。先按 8 MB，真机测堆水位后修正。

实现时要留意的两条（不改设计）：

| 项 | 注意 |
|---|---|
| `@When` 的两份声明重复 | 共四份、每份一行，且必须同步修改。加注释 `// 与另一份保持同步` |
| `AtomicBool` 的读写 | 写入侧两次（进入/退出落盘），读取侧无锁；不要为了"更准"加锁，那会把 IO 路径变成临界区 |

