# Spec Delta

## Purpose

为 `fountain::f_zip` 提供写入侧能力：内存路径与流式路径的双轨写入、data descriptor、ZIP64 自动升级、同名条目消解、目录条目、`position` / `spilling` 进度语义、平台分档的落盘阈值，以及 `zip` 便捷打包。目标是"小条目写得干净、大条目不吃内存、产出的包能被外部工具认可"。

## ADDED Requirements

### Requirement: 构造与选项

`ZipWriter` SHALL 以 `init(output: OutputStream, options!: ZipWriterOptions = ZipWriterOptions())` 构造。`ZipWriterOptions` SHALL 是可变类，含 `memoryEntryThreshold: Int64`（默认按平台分档）、`tempDir: ?Path`（默认 `None`）、`method: CompressionMethod`（默认 `Deflate`）。`ZipWriterOptions` SHALL 提供静态工厂 `forServer()`（64 MB）与 `forLowMemory()`（8 MB），二者每次调用返回**新实例**且返回后**可自由修改字段**。

#### Scenario: 默认选项

- **WHEN** 用 `ZipWriter(out)` 构造
- **THEN** `method` 为 `Deflate`，`tempDir` 为 `None`，`memoryEntryThreshold` 等于当前平台的默认值

#### Scenario: 预设可微调

- **WHEN** 取 `ZipWriterOptions.forServer()` 后把 `memoryEntryThreshold` 改为 `32 MB`、`method` 改为 `Stored`
- **THEN** 修改生效，且下一次 `forServer()` 返回的实例仍是 64 MB

#### Scenario: 预设互不影响

- **WHEN** 连续取两个 `forLowMemory()` 并修改第一个
- **THEN** 第二个不受影响

### Requirement: 内存路径不写 data descriptor

`ZipWriter.add(name: String, data: Array<Byte>): String` SHALL 在写 local header 之前算出 CRC32 与压缩后大小，写出**真实值**的 local header（bit 3 = 0），随后写压缩数据，SHALL NOT 写 data descriptor。返回值 SHALL 是实际写入的条目名（可能因同名消解而改变）。

#### Scenario: 内存路径的 header 字段

- **WHEN** 以 `add("a.txt", bytes)` 写入
- **THEN** 该条目 local header 的 crc / compressedSize / uncompressedSize 都是真实值
- **AND** general purpose flag 的 bit 3 为 0
- **AND** 数据之后紧跟下一条目的 local header，没有 `0x08074b50` 签名

#### Scenario: 空数据条目

- **WHEN** `add("empty.txt", Array<Byte>())`
- **THEN** 该条目大小为 0、CRC 为 0，仍被中央目录收录

#### Scenario: Stored 方法

- **WHEN** 选项为 `Stored` 时调用 `add`
- **THEN** method 字段为 0，存储的是原始字节，CRC 与大小正确

### Requirement: 流式路径必写 ZIP64 data descriptor

`ZipWriter.addFileStream(name: String, input: InputStream): String` SHALL 在写 local header 时填 `crc = 0` / `compressedSize = 0` / `uncompressedSize = 0`、置位 bit 3、`version needed = 45`、并在 extra 中包含 `0x0001` 且两个 8 字节值为 0；数据写完后 SHALL 写 **24 字节** 的 descriptor：`0x08074b50 + crc32(4) + compressedSize(8) + uncompressedSize(8)`。返回值 SHALL 是实际写入的条目名。

#### Scenario: header 的流式标记

- **WHEN** 用 `addFileStream("big.bin", input)` 写入
- **THEN** local header 的 bit 3 为 1、`version needed` 为 45、extra 含 `0x0001`
- **AND** extra 中原始与压缩大小两个 8 字节值均为 0

#### Scenario: descriptor 长度固定 24 字节

- **WHEN** 该条目写完
- **THEN** 紧随压缩数据的是 4 字节签名 `0x08074b50` + 4 字节 CRC + 8 字节压缩后大小 + 8 字节原始大小
- **AND** 不存在 16 字节形式的 descriptor

#### Scenario: 小内容也用 ZIP64 形式

- **WHEN** 用 `addFileStream` 写入只有 10 字节的内容
- **THEN** descriptor 仍是 24 字节，不得"优化"成 16 字节

#### Scenario: 中央目录记录真实值

- **WHEN** 流式条目写完并 `close()`
- **THEN** 中央目录里该条目的 crc / 两个大小都是真实值，与 descriptor 一致

### Requirement: 包装流顺序固定

流式写入 SHALL 按 `input → Crc32InputStream（算 CRC + 数原始字节）→ CompressOutputStream(DeflateFormat) → CountingOutputStream（数压缩后字节）→ output` 的顺序包装，SHALL NOT 调换。`uncompressedSize` SHALL 取 `Crc32InputStream` 读过的字节数，SHALL NOT 引入第二个计数器。

#### Scenario: CRC 作用于原始字节

- **WHEN** 用 `addFileStream` 写入一段可压缩文本
- **THEN** descriptor 与中央目录中的 crc 等于 `f_util.crc32(原始字节)`
- **AND** 不等于对压缩字节计算的 crc

#### Scenario: 压缩后大小计数位置正确

- **WHEN** 写入同一段文本
- **THEN** descriptor 中的 compressedSize 小于 uncompressedSize，且两者与解压后校验一致

#### Scenario: 不可压缩数据

- **WHEN** 用 `addFileStream` 写入一段随机字节
- **THEN** compressedSize 可略大于 uncompressedSize，但解压后逐字节一致、CRC 通过

### Requirement: 两条路径可混用

同一个 `ZipWriter` SHALL 允许 `add` 与 `addFileStream` 任意混用，中央目录 SHALL 正确记录两种条目的差异字段。

#### Scenario: 混合样本被自身读回

- **WHEN** 依次 `add("a.txt", …)`、`addFileStream("b.bin", …)`、`add("c.txt", …)` 后 `close()`，再用 `ZipReader` 读回
- **THEN** 三条数据逐字节正确，`a.txt` / `c.txt` 的 bit 3 为 0，`b.bin` 的 bit 3 为 1

#### Scenario: 混合样本被外部工具认可

- **WHEN** 把该混合样本交给 `unzip -t` 与 Python `zipfile.testzip()`
- **THEN** 两者都报告无错误

### Requirement: 同名条目写入侧消解

`ZipWriter` SHALL 保证产出的 ZIP 中不存在同名条目：

- 同名目录（名字以 `/` 结尾）→ **合并**，第二次遇到直接跳过，不写第二个条目
- 同名文件 → 第一个保留原名，后续自动加 `_<N>` 后缀，`N` 从 **2** 起
- 改名后仍冲突 → 继续递增直到无冲突
- 后缀插在**最后一个非目录段的 `.` 之前**，保留扩展名

所有 `add*` 方法 SHALL 返回实际写入的名字。

#### Scenario: 连续三次同名

- **WHEN** 依次三次 `add("a.txt", …)`
- **THEN** 返回值依次为 `a.txt`、`a_2.txt`、`a_3.txt`

#### Scenario: 改名后再撞名

- **WHEN** 依次 `add("a.txt")`、`add("a.txt")`、`add("a_2.txt")`
- **THEN** 第三个返回 `a_2_2.txt`

#### Scenario: 无扩展名

- **WHEN** 连续两次 `add("a", …)`
- **THEN** 第二个为 `a_2`

#### Scenario: 点在目录段里不算扩展名

- **WHEN** 连续两次 `add("dir.d/file", …)`
- **THEN** 第二个为 `dir.d/file_2`

#### Scenario: 点开头的隐藏文件

- **WHEN** 连续两次 `add(".gitignore", …)`
- **THEN** 第二个为 `.gitignore_2`

#### Scenario: 末尾点仍算扩展名分隔

- **WHEN** 连续两次 `add("a.", …)`
- **THEN** 第二个为 `a_2.`

#### Scenario: 同名目录合并

- **WHEN** 连续两次 `addDirectory("d")`
- **THEN** 两次都返回 `d/`，且 ZIP 中只有一条 `d/` 条目

#### Scenario: 目录与文件不同名不算冲突

- **WHEN** `addDirectory("a")` 后 `add("a", …)`
- **THEN** 文件名为 `a`（不带斜杠），两条并存

### Requirement: 目录条目

`ZipWriter.addDirectory(name: String): String` SHALL 写一条名字以 `/` 结尾、`compressedSize = uncompressedSize = 0`、`method = 0`、`crc = 0` 的条目，并把 external attributes 置为目录位（Unix 下形如 `0x41ED0000`）。名字未以 `/` 结尾时 SHALL 自动补上。

#### Scenario: 自动补斜杠

- **WHEN** `addDirectory("sub")`
- **THEN** 返回 `sub/`，条目名以 `/` 结尾

#### Scenario: 目录条目的字段

- **WHEN** 检查该条目的中央目录记录
- **THEN** 两个大小为 0、method 为 0、crc 为 0、external attributes 高位是目录 mode

#### Scenario: 外部工具识别为目录

- **WHEN** 用 `unzip -l` 列出含目录条目的包
- **THEN** 该条目显示为目录

### Requirement: addFile 与 addDirectory 的返回值

`ZipWriter.addFile(name: String, path: Path): String` SHALL 以流式路径写入一个磁盘文件，SHALL 返回实际写入的名字。传入符号链接路径时 SHALL **跟随**链接读取目标内容。传入不存在的路径 SHALL 抛出 `ZipException`。

#### Scenario: 写入磁盘文件

- **WHEN** `addFile("data.bin", path)` 指向一个 1 MB 文件
- **THEN** 返回 `data.bin`，读回内容与源文件逐字节一致

#### Scenario: 符号链接被跟随

- **WHEN** `addFile("link.txt", path)` 的 `path` 是指向 `real.txt` 的符号链接
- **THEN** 写入的是 `real.txt` 的内容

#### Scenario: 路径不存在

- **WHEN** `addFile("x", 不存在的路径)`
- **THEN** 抛出 `ZipException`

### Requirement: position 进度语义

`ZipWriter.position: Int64` SHALL 表示已写入 output 的字节数（local header + 压缩数据 + descriptor），SHALL 单调递增，SHALL NOT 因条目切换而回退，`close()` 之前 SHALL NOT 包含中央目录。

#### Scenario: 单调递增

- **WHEN** 连续写入三个条目，每次写完后读取 `position`
- **THEN** 三次读数严格递增

#### Scenario: 不含中央目录

- **WHEN** 写完条目但未 `close()` 时读 `position`，再 `close()`
- **THEN** `position` 的值小于最终输出总字节数，差值约为条目数乘以中央目录单条记录大小

### Requirement: spilling 状态语义

`ZipWriter.spilling: Bool` SHALL 用 `std.sync.AtomicBool` 实现，跨线程读取 SHALL 安全。语义 SHALL 仅限于"当前 `add()` 正处于落临时文件阶段"：进入该分支前置 `true`，`addFileStream` 开始前（以及 `add` 退出该分支后）置 `false`。`spilling` 与 `position` SHALL NOT 保证原子一致，二者 SHALL NOT 用于逻辑判断，只用于展示。

#### Scenario: 落盘期间 spilling 为真

- **WHEN** 在另一个线程轮询，同时主线程 `add` 一个超过阈值的条目
- **THEN** 落盘阶段能读到 `spilling == true`
- **AND** 在此期间 `position` 不增长

#### Scenario: 流式写入不改 spilling

- **WHEN** 调用 `addFileStream`
- **THEN** `spilling` 为 `false`

#### Scenario: 落盘结束后复位

- **WHEN** 一个超阈值条目 `add` 完成
- **THEN** `spilling` 回到 `false`

### Requirement: 平台分档的内存阈值

`ZipWriterOptions.memoryEntryThreshold` 的默认值 SHALL 按 `os` 编译期分档：Linux 为 `64 * 1024 * 1024`，其他平台（含 OHOS）为 `16 * 1024 * 1024`。分档 SHALL 通过两份互补的 `@When` 声明实现（`@When[os == "Linux"]` 与 `@When[os != "Linux"]`），SHALL NOT 在函数体内做条件分支——`@When` 只能修饰声明。

#### Scenario: Linux 默认 64 MB

- **WHEN** 在 Linux 上取 `ZipWriterOptions().memoryEntryThreshold`
- **THEN** 等于 `67108864`

#### Scenario: 非 Linux 默认 16 MB

- **WHEN** 在 OHOS 或其他平台上取默认值
- **THEN** 等于 `16777216`

#### Scenario: 互补分支只存在一份

- **WHEN** 在任一目标平台编译
- **THEN** 同名函数只有一份定义，不存在重复定义错误

### Requirement: 超阈值条目自动落盘

当 `add(name, data)` 的 `data.size` 超过 `memoryEntryThreshold` 时，`ZipWriter` SHALL 把 `data` 写入临时文件，改用 `addFileStream` 从其读取，写完删除临时文件。临时目录 SHALL 按固定顺序解析：① `ZipWriterOptions.tempDir`；② 环境变量 `TMPDIR`；③ 系统临时目录；④ 当前工作目录下的 `.fountain_tmp/`（自动创建）。四级都失败时 SHALL 抛出 `ZipException`，消息形如 `无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}`。SHALL NOT 降级回内存路径。

#### Scenario: 超过阈值走流式

- **WHEN** 阈值设为 1 KB，`add` 一条 100 KB 的数据
- **THEN** 该条目按流式形式写入（bit 3 为 1、带 24 字节 descriptor），读回内容一致

#### Scenario: 未超阈值不进临时文件

- **WHEN** 阈值设为 1 MB，`add` 一条 100 KB 的数据
- **THEN** 全程不创建临时文件，条目按内存路径写入（bit 3 为 0）

#### Scenario: 临时目录按序解析

- **WHEN** 显式设置 `tempDir`
- **THEN** 临时文件落在该目录，不读 `TMPDIR` 与系统临时目录

#### Scenario: 全部失败即报错

- **WHEN** 四个候选目录都不可写且条目超阈值
- **THEN** 抛出 `ZipException`，不尝试退回内存路径

#### Scenario: 落盘分支打 debug 日志

- **WHEN** 条目进入临时文件分支
- **THEN** 产生一条 debug 级日志，内容包含条目名、大小、阈值与临时文件路径
- **AND** 该日志在默认级别下不输出

### Requirement: close 必须调用且幂等

`ZipWriter.close()` SHALL 写中央目录（必要时写 EOCD64 与定位器）与 EOCD。SHALL 幂等：第二次调用不重复写、不抛异常。未调用 `close()` 的产物 SHALL 被视为不完整。

#### Scenario: 正常收尾

- **WHEN** 写入若干条目后调用 `close()`
- **THEN** 输出以 EOCD 结尾，能被 `ZipReader` 与外部工具读取

#### Scenario: 重复 close

- **WHEN** 连续调用 `close()` 两次
- **THEN** 不抛异常，输出字节不变

#### Scenario: 空包

- **WHEN** 不写任何条目直接 `close()`
- **THEN** 产出 0 条目的合法 ZIP

### Requirement: 写入失败进入脏状态

`addFileStream` / `addFile` 过程中抛异常时，`ZipWriter` SHALL 进入脏状态；此后任何 `add*` 或 `close()` SHALL 抛出 `ZipException`，消息形如 `条目 ${name} 写入中断，ZIP 结构不完整`。SHALL NOT 尝试续写或修补。

#### Scenario: 输入流中途抛错

- **WHEN** 一个 `InputStream` 在读第 N 字节时抛异常
- **THEN** `addFileStream` 抛出异常，随后 `close()` 也抛 `ZipException`

#### Scenario: 脏状态下不能继续加条目

- **WHEN** 脏状态后调用 `add("x", bytes)`
- **THEN** 抛出 `ZipException`，不写入任何字节

### Requirement: zip 便捷打包

`f_zip` SHALL 提供 `zip(output: OutputStream, dir: Path, options!: ZipWriterOptions = ZipWriterOptions()): Int64`，递归遍历 `dir`，对每个文件用 `addFileStream` 写入，对每个目录写目录条目，返回写入的文件数（不含目录条目）。符号链接条目 SHALL 跳过（见 `f-zip-security`）。

#### Scenario: 目录打包后解压还原

- **WHEN** 对一个含两层子目录与 5 个文件的目录调用 `zip`
- **THEN** 返回 `5`，解压到新目录后文件树与内容完全一致

#### Scenario: 不整体进内存

- **WHEN** 打包一个总大小 2 GB 的目录
- **THEN** 进程 RSS 不随总大小线性增长

#### Scenario: 空目录

- **WHEN** 打包一个只含空子目录的目录
- **THEN** 返回 `0`，包内仍有对应的目录条目
