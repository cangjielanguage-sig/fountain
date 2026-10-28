# Design: 新建 f_zip 模块

## Context

**当前状态**：仓库里没有 `f_zip` 目录，ZIP 能力为零。`f_zip/doc/f_zip模块设计.md` v0.7 已冻结：21 项决策全部拍板、无阻塞项、并给出 P0–P6 的实施顺序与验收口径。可复用的地基均已就绪并实读确认：

- `f_util.crc32(data: Array<Byte>): UInt32`（`f_util/src/crc32.cj:114`，等价 `Crc32.isoHdlc`，即 zlib/PKZIP 口径）；**它的吞吐原本只有 ~4.2 MB/s，是本变更必须一并修掉的瓶颈（D16，已修到 51~58 MB/s）**
- `f_io.ByteBuffer`（`f_io/src/ByteBuffer.cj:22`）：`seekReading` / `seekWriting` / `readByte(): ?Byte` / `read(buf): Int64` / `writeByte` / `write(buf)` / `bytes()` / `reserve()`
- `stdx.compress.zlib` 的 `CompressInputStream` / `CompressOutputStream` + `WrapType.DeflateFormat` / `CompressLevel`（仓库内已有使用：`f_log/src/output/RotatableFile.cj:25`）
- `charset4cj 1.0.5` 已在根 `cjpm.toml` 声明，GBK 解码可用（仓库内用法见 `f_http/src/MediaType.cj:27`）
- `f_log` 的 `Log.debug(message: String)`（`f_log/src/base/Logger.cj:491`）
- `std.sync.AtomicBool`（`f_io/src/ByteBuffer.cj:19` 已使用）

动机见 `proposal.md - Why`；行为契约与验收场景见 `specs/*/spec.md`；本文件只回答「怎么做」。

**塑造本设计的硬约束**：

1. **容器层永久自主实现**（v0.7 `§1`）：local header / 中央目录 / EOCD / ZIP64 / CRC 编排全部自己写，不引入第三方 ZIP 库、不引 FFI、不做 native 链接。deflate 数据流复用 `stdx.compress.zlib`。
2. **以 PKWARE APPNOTE 为准**，不照抄其他语言的实现；与规范不一致的真实文件只登记进「已知兼容性例外」，不改代码迁就。
3. **`@When` 只能修饰声明、不能修饰语句**（v0.7 `§3.4.2.1`），互补分支在同一编译目标上只生成一份，因此平台分叉必须"整份声明各写一遍"。
4. **ZIP 全部字段小端**，且不依赖任何"默认端序"的 API（v0.7 `§1.2`、`§6.4`）。
5. **`struct` 的字段不可变**（公开值类型一律 `let`），解析过程中的可变状态留在内部类里。
6. **严格 TDD**：每一最小步先写失败用例，再写最小实现，全绿才勾掉任务。

## Goals / Non-Goals

**Goals：**

- 交付一个**格式正确、可被外部工具认可**的 ZIP 实现：写出的包必须通过 `7z t` 与 Python `zipfile.testzip()` 校验；`unzip -t` 为**环境具备时的补跑项**（当前融合开发环境未安装 `unzip`，不作为门禁）。
- **读取不吃内存**：`ZipReader(path)` 只用尾部窗口（≤ 64 KB）+ 中央目录 + 单条输出，1 GB 包的 RSS 不随文件线性增长。
- **写入不吃内存**：`addFileStream` 的内存峰值与条目大小无关；`add()` 超阈值的条目自动落临时文件，峰值从 `2 ×` 降到 `1 ×`。
- **ZIP64 双向完整**：读取能识别 EOCD64 / 定位器 / extra `0x0001`；写入在越界时自动升级、不越界时不写。
- **安全默认开**：Zip Slip、符号链接、ZIP 炸弹、加密 ZIP 四类风险在默认配置下即被挡住，上限可覆盖。
- **行为可观测**：`position` 与 `spilling` 让调用方能区分"在写"与"在准备"，不需要把 UI 回调塞进 writer。
- **CRC 不再是瓶颈**：`f_util` 的 CRC32 引擎经 D16 优化后 **51~58 MB/s**（判据 ≥ 30 MB/s 达标；最初设想的 ≥ 60 MB/s 差一点，见 D16 的 ④），4.4 GB 单条目的 `9.7b` 往返实测 200 s，落进 10 分钟。
- **零曲线**：所有取舍都在文档里有落点，实现与文档出现偏差时同提交改文档。

**Non-Goals：**

- 不实现 Stored / Deflate 之外的压缩方法，不做加密 ZIP，不做分卷 ZIP。
- 不做推模式写入（`openEntry` 返回 `OutputStream`）。
- 不做内存探测（含 cgroup）；阈值只按 `os` 分档。
- 不给 `f_io.ByteBuffer` 加小端 / 多字符集能力。
- 不追求 `f_zip` 自身的压缩率与吞吐调优；`CompressLevel` 保持库默认。**唯一例外**是 `f_util` 的 CRC32 引擎吞吐（D16）——它不改 `f_zip` 的任何参数，只把已被复用的底层函数变快，且不改变任何计算结果。

## Decisions

### D1 单一包 + 内部 `internal` 声明，不切子包

`fountain::f_zip` 是唯一包；所有公开 API 与内部实现都在 `src/` 平铺，跨文件共享的实现细节用 `internal` 顶层声明，仅供单文件使用的用 `private`。不建 `src/internal/` 子包。

- **备选 ①** 切 `fountain::f_zip.internal` 子包：子包里的类型对包外不可见需要 `protected`（module 级），等于把实现类型提升到"整个 fountain 模块可见"，可见性反而更松；且多层 `import` 让 header 编解码的调用链变长。
- **备选 ②** 每个结构一个类文件 + 一个 `internal` 门面：fountain 既有模块（如 `f_codec`）确实这么做，但 ZIP 的耦合点是"共享同一个游标"，拆包只会增加跨包传 `ByteBuffer` 的成本。
- **选择理由**：ZIP 容器是一个内聚的有限状态过程，单包能把"游标不位移""字节数校验"这类不变量约束在最小可见范围内；对外只有 `ZipReader` / `ZipWriter` / `ZipEntry` / `ZipLimits` / `ZipWriterOptions` / `CompressionMethod` / `ZipException` / `unzip` / `zip` 九个名字。

### D2 读取侧的随机访问抽象成内部 `EntrySource`

`EntrySource` 是内部接口，两个实现：`BufferSource`（持有 `f_io.ByteBuffer`）与 `FileSource`（持有 `std.fs.File` + 长度）。`ZipReader` 的全部解析逻辑只面向 `EntrySource`，两种构造的差别被压到"怎么读到字节"这一层。

```
EntrySource
├── size: Int64
├── readAt(offset: Int64, dst: Array<Byte>): Int64     // 不定长读，返回实际字节数
├── openRange(offset: Int64, length: Int64): InputStream  // 独立句柄，限长流
└── close(): Unit
```

- **备选 ①** 两个 reader 各写一套解析：解析逻辑（EOCD 扫描、ZIP64、CD 逐条）会重复两份，正是"自己读自己写互相容忍同一个错误"的温床。
- **备选 ②** 统一全量缓冲：`ZipReader(path)` 的存在意义就是不吃内存，直接排除。
- **选择理由**：v0.7 `§4` 明确"两种模式的差别只在怎么读到字节，解析逻辑完全一致"。`openRange` 由 `FileSource` 另开 `File` 句柄（避免并发 `open` 互相打乱光标），`BufferSource` 用 `ByteBuffer.clone()` 起点 + 限长包装。

### D3 写入侧两条路径共用一个 `CentralEntry` 累加器

不论 `add()` 还是 `addFileStream()`，写完一条都把结果灌进同一个内部 `CentralEntry`（名字字节、flag、method、DOS 时间、crc、压缩后/原始大小、local header 偏移、external attributes）。`close()` 只消费这一张表。

- **备选 ①** 内存路径直接拼好中央目录片段缓存：流式条目的真实值要等写完才知道，两条路径的记录形态会分叉。
- **选择理由**：v0.7 `§3.2` 要求"两条路径共用同一套 header 写入与中央目录记录逻辑，只有 local header 怎么填 + 要不要 descriptor 不同"。把差异收敛在 `writeLocalHeader(kind)` 的一个参数上。

### D4 流式条目一律写 24 字节 ZIP64 data descriptor

`addFileStream` 的 local header：`crc = 0`、`compSize = 0`、`uncompSize = 0`、`bit 3 = 1`、`version needed = 45`、extra 含 `0x0001` 且两个 8 字节值写 0；数据后写 `0x08074b50 + crc32(4) + compSize(8) + uncompSize(8)`。

- **备选 ①** 先写 4 字节 descriptor，超 4 GB 再回退改：要求输出流可 seek，与"写任意 `OutputStream`"直接冲突。
- **备选 ②** 缓存整条数据到临时文件再决定宽度：等于把流式路径退化成内存/磁盘路径，失去流式意义。
- **选择理由**：descriptor 宽度必须在写 local header 时确定，而那时大小未知；只有"一律按 ZIP64"能做到头部一次写定、无需回退（v0.7 `§5.2`）。代价是每流式条目多 28 字节，对本来就是大文件的场景可忽略。
- **风险处置**：若某解压器不认 ZIP64 形式的 descriptor，只登记进 `f_zip/doc/兼容性例外.md`，**不因此改回 4 字节**。

### D5 ZIP64 只在越界时写，且 extra 只放越界项

写入时逐字段判断：单条目 `uncompressedSize` / `compressedSize` / `localHeaderOffset` 任一 ≥ `0xFFFFFFFF` → 该 header 走 ZIP64（字段写哨兵 + extra 按 `originalSize → compressedSize → localHeaderOffset → diskStart` 的**固定顺序只放越界项** + `version needed = 45`）；`close()` 时条目数 > `0xFFFF` 或 CD 大小 / 偏移 ≥ `0xFFFFFFFF` → 写 EOCD64 + 定位器，普通 EOCD 对应字段写哨兵。

- **备选 ①** 总是写 ZIP64：v0.7 `§2.4` 明确反对——小文件凭空多几十字节，且让老工具多一层解析。
- **备选 ②** extra 全放：让"这段 extra 有几个值"依赖读端宽容度；只放必要的，读端按哨兵值个数就能判定。
- **读取对称规则**：必须"先看 extra 总长度，再按哪些字段是哨兵值决定读几个 8 字节"，**不能按字段位置硬读**；长度不足时抛 `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}`。

### D6 写入侧消解同名，读取侧取最后一个

- `EntryNameTable` 持 `HashSet<String>` + `HashMap<String, Int64>`；`allocate(name)` 先试原名，占用则从 `_2` 起递增；`insertSuffix` 把后缀插在**最后一个非目录段的 `.` 之前**（`a.txt → a_2.txt`、`a → a_2`、`dir.d/file → dir.d/file_2`、`.gitignore → .gitignore_2`、`a. → a_2.`）。
- 目录（以 `/` 结尾）第二次遇到直接跳过（合并），不写第二条。
- 读取侧 `read(name)` 取**最后一个**匹配，`readAll(name)` 返回全部，`entries()` 原样列出不合并。

- **选择理由**：ZIP 允许多条同名，但解压行为依实现而异（有的取第一个、有的取最后一个、有的报错），这种不确定性不该留给下游；写入侧还能改名，读取侧文件已落盘只能选一种（取最后一个与 Info-ZIP / 7-Zip 一致）。读写不对称是刻意的。
- **备选 ①** 写入侧遇到同名直接覆盖前一条：`OutputStream` 不可回退，做不到。
- **备选 ②** 写入侧报错：把消解责任推给调用方，`zip(output, dir)` 这种批量场景会很别扭。

### D7 符号链接无条件跳过，`addFile` 是唯一例外

`unzip()` 与 `zip(output, dir)` 遇到 Unix mode `(attr >> 16) & 0xF000 == 0xA000` 的条目/路径一律跳过并记 warning；目录符号链接跳过整棵子树。`ZipReader.read(name)` / `open(name)` 把它当普通条目读出（链接目标字符串的字节），不做策略。`ZipWriter.addFile(path)` 传入符号链接路径时**跟随**。

- **选择理由**：跟随 `link -> /etc/passwd` 会让压缩包变成任意文件读取器，而 Zip Slip 的路径规则挡不住"先落地再看指向"的两步攻击；重建链接在 OHOS 沙箱 / FAT32 / Windows 无权限时并不可行；打包/解压的用途是搬数据，丢链接不丢字节。
- **为什么 `addFile` 例外**：调用方指名道姓要一个文件，它知道自己在干什么；`zip()` 处理整棵树，策略必须保守。
- **判别只在读取侧做**：写入侧通常没有 mode 信息，除非调用方显式给 external attributes。

### D8 `memoryEntryThreshold` 用 `@When` 做编译期分档

```cangjie
@When[os == "Linux" && env == "gnu"]
private func defaultMemoryEntryThreshold(): Int64 { 64 * 1024 * 1024 }
@When[os != "Linux" || env != "gnu"]
private func defaultMemoryEntryThreshold(): Int64 { 16 * 1024 * 1024 }
```

> **实现修正（2026-10-28）**：v0.7 原文只写 `os == "Linux"`，但鸿蒙目标（`aarch64-linux-ohos`）
> 在 `@When` 里的 `os` 同样是 `"Linux"`，区别在 `env`（`gnu` / `ohos`）。只按 `os` 分档会让 OHOS
> 拿到服务器档 64 MB，与设计意图相反。故条件改为 `os == "Linux" && env == "gnu"`，与
> `f_base/src/OS.cj` 既有写法一致；`f_zip/doc/f_zip模块设计.md` §3.4.2 已同步。

- **备选 ①** 运行期探测可用内存（`/proc/meminfo`、cgroup）：没有可靠跨平台 API；更关键的是**行为随环境变化会让问题不可复现**——开发机与现场走不同路径，bug 只在一边出现。
- **备选 ②** 统一一个值：16 MB 会让 Linux 服务器上 32 MB 的配置包无谓落盘；64 MB 在手机上直接 OOM 风险。
- **选择理由**：按 `os` 分档是编译期确定的、代码路径可预测，覆盖 99% 场景；剩余场景由调用方显式指定。
- **`@When` 的边界**：只能修饰声明，所以平台分叉必须"整份声明各写一遍"，两份都加 `// 与另一份保持同步` 注释。本模块只有 `defaultMemoryEntryThreshold()` 这一处需要分叉。

### D9 `position` 与 `spilling` 只做展示，不做逻辑

`position` 由包在最外层的 `CountingOutputStream` 累加，单调递增；`close()` 前不含中央目录。`spilling` 是 `std.sync.AtomicBool`：进入 `add()` 的临时文件分支前置 `true`，`addFileStream()` 开始前置 `false`。

- **备选 ①** 用普通 `Bool` 字段：写线程置位、UI 线程读取时可能读到旧值。
- **备选 ②** 给两者加锁保证原子一致：把 IO 路径变成临界区，得不偿失。
- **备选 ③** 回调（`progress` / `onSpill`）：把 writer 主循环与 UI 更新耦合（重入、异常传播、线程切换）。
- **选择理由**：调用方自己决定轮询节奏，读一个 `Int64` + 一个 `AtomicBool` 就够；**明确不保证两者原子一致**，可能出现"`spilling = false` 而 `position` 刚好停住"的一帧，这只影响显示。
- **为什么还需要 `spilling`**：`add()` 落盘阶段 `position` 完全不增长，只有 `position` 会被误判成"卡死"。

### D10 `ZipLimits.maxEntries` 只服务读取，写入侧无上限

读取侧在**解析中央目录时**就拒绝超限（不先建完列表再判）；写入侧不设任何条目数参数，`close()` 时按实际条目数自动决定是否写 EOCD64。

- **选择理由**：两件事的触发条件、处置方式、责任方都不同。"安全上限"防的是恶意/畸形文件的中央目录声明（如声明 40 亿条目把我们撑爆）；"格式上限"只是非 ZIP64 EOCD 的 2 字节字段。写入是调用方自己的行为，不存在恶意输入，加人为上限会让"导出 100 万个文件"这种合法需求莫名失败。
- **陷阱**：读普通 EOCD 时条目数字段是 2 字节、ZIP64 的是 8 字节——**必须先读普通 EOCD，发现字段是 `0xFFFF` / `0xFFFFFFFF` 才去找 EOCD64**，不能无条件按 8 字节读。

### D11 依赖面：`f_base` + `f_util` + `f_io` + `f_log` + `charset4cj` + `stdx.compress.zlib`

与 v0.7 `§0` 依赖表有两处差异：① `f_log`——`§3.4.3` 要求落盘分支打 debug 日志，必须有日志出口；② `f_base`——`ZipException` 继承 `f_base.BaseException`（与仓库其它模块一致），只取异常基类这一个类型，不引入其它能力。

- **备选 ①** 不依赖 `f_log`，让调用方注入日志回调：为一个 debug 日志引入一个构造参数，API 变化比依赖变化更贵。
- **备选 ②** 直接 `println`：污染标准输出，且线上无法按级别关闭。
- **选择理由**：`f_log` 与 `f_base` 都是仓库内模块（不是第三方 ZIP 实现），长期约束只禁止"外部 ZIP 库 / FFI / native 链接"，两者都不在其中；`f_base` 只提供异常基类，没有运行期成本。此差异回写 `f_zip/doc/f_zip模块设计.md` 的依赖表。

### D12 小端读写在本模块内部实现，不扩展 `f_io`

约 10 个私有/内部函数，全部基于 `ByteBuffer.readByte(): ?Byte` / `read(buf): Int64` 与 `writeByte` / `write(buf)`：

| 函数 | 语义 |
| --- | --- |
| `readU16LE(buf): ?UInt16` / `readU32LE` / `readU64LE` | 读越界返回 `None` **且回滚读游标**；必须校验实际读到的字节数 |
| `writeU16LE(buf, v)` / `writeU32LE` / `writeU64LE` | 逐字节写出，显式小端 |
| `readBytes(buf, n): ?Array<Byte>` | 定长读；不足 `n` 时返回 `None` 并回滚 |
| `skip(buf, n): Bool` | 跳过 + 越界判定 |
| `decodeNameStrict(bytes, charset): ?String` | 严格解码，失败返回 `None`（供回退链使用） |

- **备选 ①** 用 `buf.readUInt32(endian: Endian.Little)`：`f_io.ByteBuffer` 没有这些方法；`std.io.ByteBuffer` 的 `position` 语义是读游标、写永远追加，同时维护两套游标更易错。
- **备选 ②** 另写一个 `ZipByteBuffer` 包装类：多一层间接，收益只是少几个自由函数。
- **选择理由**：v0.7 `§1.2` 已把增强 `f_io` 的方案取消；这些函数只服务 ZIP，不进公开 API。
- **四条硬约定**：① 越界返回 `None` 且游标不位移；② 校验实际读到的字节数（否则补零会产生"看起来合法的错误值"）；③ 小端一律显式；④ 不进公开 API。

### D13 文件名编码：写入只判 ASCII，读取走固定回退链

- **写**：全 ASCII → 不置 bit 11、按 ASCII 字节写；否则置 bit 11、UTF-8 编码写。
- **读**：bit 11 置位 → UTF-8 解码；否则 UTF-8 严格解码 → 失败试 GBK → 仍失败按 Latin-1 逐字节映射（保证不抛异常）。
- **备选 ①** 引入编码检测库：ZIP 文件名通常只有几到几十字节，小样本上检测准确率低，误判（把 GBK 判成 UTF-8）就是全乱码。
- **选择理由**：这条链覆盖"现代工具置 bit 11"与"中文 Windows 打 GBK 且不置 bit 11"两类绝大多数情况；回退链固定写死，不引入运行时依赖。

### D14 错误模型：单一 `ZipException`，消息必须可定位

`public class ZipException <: Exception`，只在 `ZipException(message)` 一个构造器。消息统一带"期望 / 实际 / 条目名"三要素（见 `specs/f-zip-container/spec.md` 的错误消息表）：

- `不是有效的 ZIP 文件（未找到中央目录）`
- `中央目录偏移 ${off} 超出文件长度 ${len}`
- `不支持压缩方法 ${method}（${name}）` —— 必须给出方法数值，让用户区分"算法不支持"与"文件损坏"
- `不支持加密 ZIP（${name}）`
- `CRC 校验失败：期望 ${exp}，实际 ${act}（${name}）`
- `解压体积超过上限 ${limit}（${name}）`
- `条目数 ${n} 超过上限 ${limit}`
- `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）`
- `缺少 data descriptor（bit 3 置位但数据后无签名）`
- `条目 ${name} 写入中断，ZIP 结构不完整`
- `条目路径非法：${name}`

`ZipException` 继承 `f_base.BaseException`（与仓库其它模块一致），不新增子类——调用方按 message 区分的场景很少，按 `catch (e: ZipException)` 统一兜底更多。

### D15 写入中途失败的处置：脏状态，不试图续写

`addFileStream` 抛异常后 writer 置 `dirty = true`；此后任何 `add*` / `close()` 直接抛 `条目 ... 写入中断，ZIP 结构不完整`。保护范围 SHALL 覆盖写入一条的三段：**local header 写入 → 压缩数据泵送 → data descriptor 写入**，三段同等对待（只在数据泵送段加 `try` 会让 header / descriptor 写失败留下"结构看似完好、实际半截"的包）。

- **备选 ①** 捕获异常后补写一个"空 descriptor"占位：半截压缩流无法修补，补出来的包结构合法但内容错，比报错更糟。
- **备选 ②** 允许继续 `add` 下一个条目：中央目录里会出现一条尺寸错误的记录，整包作废。
- **选择理由**：ZIP 的 local header 一旦写了 bit 3，descriptor 就是结构的一部分；中断即整包不可信，宁可让调用方重新打包。

### D16 CRC32 吞吐优化（`f_util`，范围扩展）

**现状**：`CrcEngine.update`（`f_util/src/CrcEngine.cj:99`）用 `for (b in data)` 逐字节查表，融合侧实测约 **4.2~7.1 MB/s**（同机 C 版表驱动 175 MB/s、`-O0` 下 92 MB/s）。`f_zip` 每条目至少算一次 CRC：1 GB 条目 > 4 分钟；4.4 GB 单条目往返要算两遍 ≈ 35 分钟，`9.7b` 因此在 10 分钟的单命令时限内跑不完。设计 `§10` 的性能预估以"CRC 不是瓶颈"为前提，这个前提**已经不成立**（100 MB 条目写一次光 CRC 就 ~25 s，两个资源用例 509 s / 551 s 几乎全耗在这里）。

**方案**：保持**同一个多项式与同一套参数口径**，只换内层循环，分四步、每步可独立回退（下表「实测」是 2026-10-28 在融合引擎上跑 `F_UTIL_PERF=1` 的结果，1 MiB 单遍）：

| 步 | 改法 | 预期 | 实测 |
| --- | --- | --- | --- |
| ① | 内层 `for (b in data)` → `for (i in 0..data.size)` + `data[i]` | 去掉迭代器开销；3.3x | **21 MB/s**（3.0x），仍 < 30 |
| ② | 「反射 + 位宽 32」的变体启用 slicing-by-4 | ≥ 60 MB/s | **21 MB/s，无收益** |
| ③ | 不足 4 字节的尾巴走 ① 的索引路径 | 任意长度都正确 | 正确 |
| ④ | 热循环改用 `std.core.acquireArrayRawData` 取的裸指针（只读、成对 release） | — | **51~58 MB/s** |

- **为什么 ② 没收益**：`cjpm test` 默认构建未开优化，**一次带边界检查的下标访问约 25 ns**（实测 `for (i) { s += data[i] }` 处理 1 MiB 要 26 ms）。逐字节表驱动每字节 2 次下标、slicing-by-4 每 4 字节 8 次下标——都是每字节约 2 次，所以换表不改变总次数。**只做 ①②③ 到不了 30 MB/s**，这是本决策最初的预估偏差，已在 ④ 修正。
- **④ 的口径**：`acquireArrayRawData` 是 `std.core` 的数组裸指针接口，**不是 FFI、不是硬件指令**；同一段循环从 `data[i]` / `table[k]` 换成 `pointer.read(i)` 后 1 MiB 从 ~48 ms 降到 ~17 ms。约束是只读、不跨线程、每个出口都 `releaseArrayRawData`（实现里用 `try/finally` 包住）。
- **仍差于目标值**：目标 ≥ 60 MB/s 只摸到 51~58（口径是"1 MiB 单遍"，机器有 ±10% 抖动）。剩余成本是 `CPointer.read()` 这个方法调用本身（未优化构建里每个约 8 ns，每字节 2 次），不是算法问题。需求下限（≥ 30 MB/s）达标，且 `9.7b` 端到端已从"跑不完"变成 200 s（见 18.6）。
- **切片表**：`t0` 就是现有 `reflectedTable`；`t1[k] = (t0[k] >> 8) ^ t0[t0[k] & 0xFF]`，`t2` / `t3` 同法逐级递推。
- **一次消费 4 字节**（`c` 是**未收尾**的寄存器，与 `update` 现有语义一致）：把 4 字节按小端组装成 `UInt32` 后 `c ^= w`，再
  `c = t3[c & 0xFF] ^ t2[(c >> 8) & 0xFF] ^ t1[(c >> 16) & 0xFF] ^ t0[(c >> 24) & 0xFF]`。
- **启用条件只用 `refin && width == 32`**：`refout != refin` 由 `finish` 收尾时处理，与 `update` 无关；位宽 8/16/24/40/64 与**全部非反射**变体保持 ① 的路径（`crc16` / `crc64` 也因此只享受索引遍历）。
- `update` 的**分段语义**不变：每次调用独立处理自己的整块、尾巴当场吃掉，所以 `update(update(c, a), b) == update(c, a ++ b)` 仍成立（`f_protocol` 的帧校验正是靠这条边读边算）。④ 的 acquire/release 每次调用各做一遍，实测 128 次调用的开销 ≈ 14 µs（8 KiB 分块与整块的耗时相同），不影响分段语义与吞吐。

**正确性红线**（这是本决策唯一的风险点）：

1. `crc_check_test.cj` 的 11 个变体检查值与三条增量接口用例**一个都不许改**；
2. 新增等价性用例必须以**测试内的逐字节参考实现**为第二基准（不能拿优化后的实现和自己比），覆盖长度 `0/1/2/3/4/5/7/8/4095/4096`、随机数据、4 的整数倍与非整数倍切分；
3. 只改 `update` 的内层循环与切片表构造；`initRegister` / `finish` / `compute` 与表生成的多项式口径**一行不动**。

> 为什么第 2 条是硬要求：切片表口径写错（例如索引字节顺序反了）时，**短向量可能仍然全对，长数据却整体漂移**；只有"另一个实现 + 长随机数据"能抓住它。落到 `f_util/src/CrcEngine_test.cj`：
> `slicingMatchesByteWiseReferenceForAnyLength`（6 个反射 32 位变体 + `bzip2`，长度含 0/1/2/3/4/5/7/8/4095/4096/4097/65537）、
> `segmentedUpdatesMatchOneShot`（`1+3+5` / 4 的整数倍 / `4n+1` / 逐字节）、`slicingOnlyAppliesToReflected32Bit`（`bzip2` / `modbus` / `redis`）。

**收益与成本**：

- 实测 51~58 MB/s ⇒ 4.4 GB 单遍 76~86 s，`9.7b` 往返实测 **200 s**（写 94 s + 读回 105 s），从"跑不完"变成"可跑"。
- 成本：6 个反射 32 位变体（`isoHdlc` / `jamcrc` / `crc32c` / `koopman` / `base91D` / `autosar`）各多 3 张 256 项 `Array<UInt64>` 表；**+6 KB/引擎、合计 +36 KB**，一次性静态分配；构造期多 768 次查表。其余变体（`crc16` / `crc64` / 非反射 32 位）不建切片表，`slice1..3` 是空数组且不会被索引。
- **只做 ① 不够**（21 MB/s），**①+② 也不够**（下标访问成本主导），④ 才是决定性的一步。

**明确不做**：不改 `Crc32` / `crc32*` 的公开签名、不改变体列表、不改 `finish` / `initRegister` 的语义、不引 FFI 与硬件指令（CRC32C 的 SSE4.2 / ARMv8 `crc32` 另议）、不新增 `update(ptr, len)` 之类重载、不动 `f_zip` 的任何压缩参数。**唯一的 `unsafe` 是 ④ 的数组裸指针只读访问**（`acquireArrayRawData` / `releaseArrayRawData`），不涉及跨模块 ABI。

## 模块与文件布局

```
f_zip/
├── cjpm.toml
├── README.md / README_en.md
├── doc/
│   ├── f_zip模块设计.md        # v0.7 的设计稿落位（唯一权威，含 21 条决策表）
│   ├── api.md                 # 公开 API 速查（含 maxTotalSize 是"每实例累计"的说明）
│   └── 兼容性例外.md           # §8.1 的表格：样本来源 / 现象 / APPNOTE 位置 / 我们的处理
└── src/
    ├── f_zip.cj               # package 声明 + 公开类型再导出（如需要）
    ├── ZipException.cj
    ├── CompressionMethod.cj   # enum { Stored, Deflate }
    ├── ZipLimits.cj           # struct，四个 let + 命名默认参数
    ├── ZipEntry.cj            # struct（名字/大小/CRC/method/isDirectory/modifiedAt/localHeaderOffset）
    ├── ZipWriterOptions.cj    # class，可变字段 + forServer() / forLowMemory()
    ├── ZipReader.cj
    ├── ZipWriter.cj
    ├── Unzip.cj               # unzip(input) / unzip(path)
    ├── Zip.cj                 # zip(output, dir)
    ├── LeBytes.cj             # 小端读写原语（D12）
    ├── ZipLayout.cj           # 签名、固定长度、extra ID 常量
    ├── ZipTime.cj             # DOS 时间 ↔ DateTime
    ├── NameCodec.cj           # bit 11 判定 + 回退链（D13）
    ├── EntryNameTable.cj      # 同名消解（D6）
    ├── LocalHeader.cj         # 30 字节头编解码 + ZIP64 extra
    ├── CentralHeader.cj       # 46 字节头编解码 + ZIP64 extra
    ├── Eocd.cj                # EOCD 定位 + EOCD64 + 定位器
    ├── EntrySource.cj         # 随机访问抽象（D2）+ BufferSource / FileSource
    ├── BoundedStream.cj       # 限长 InputStream / CountingOutputStream / Crc32InputStream
    ├── TempSpill.cj           # 临时目录四级解析 + 落盘
    └── *_test.cj              # 单元测试（与被测文件同名）
```

> 具体文件粒度允许在实现时合并（例如 `LocalHeader` / `CentralHeader` 可以合进 `ZipLayout`），但**公开类型与九个公开名字不得增减**，内部划分以"一个正确性论证点一个文件"为准。

## 关键实现要点

### 读取流程（对应 v0.7 `§4`）

1. 打开 `EntrySource`（缓冲 / 文件）。
2. 尾部窗口 = `min(size, 22 + 65535)`；从后往前扫 `0x06054b50`，对每个候选校验 `22 + commentLen == size - candidateOffset`，取第一个自洽的。
3. 条目数 / CD 大小 / CD 偏移为哨兵 → 读 `0x07064b50` 定位器（20 字节，位于 EOCD 前）→ 读 `0x06064b50` EOCD64。
4. `seek` 到 CD 偏移，**一次读入整块 CD**，逐条解析成 `RawEntry`（含 externalAttributes、flag、extra 原片），再映射成 `ZipEntry`。
5. `read(name)` / `open(name)`：用 `localHeaderOffset` 定位，跳过 name + extra 得到数据起点，按 method 解压，**以中央目录为准不信 local header**（bit 3 置位时 local header 的 crc/size 可能是 0），解压后校验 CRC 与 `uncompressedSize`。

三条实现红线：① 尾部窗口扫不到就失败，**不退化成全文件扫描**（否则"文件损坏"会拖成"读完 2 GB 才报错"）；② CD 一次读完，条目数据按需读；③ `open(name)` 另开句柄。

### 写入流程（对应 v0.7 `§5.1`）

```
add(name, data):
  写前记录 offset
  if data.size > memoryEntryThreshold:  → 落盘路径（D8）
  crc = f_util.crc32(data)；compressed = deflate(data)
  写 local header（真实值，bit 3 = 0）→ 写 compressed → 记 CentralEntry

addFileStream(name, input):
  写前记录 offset
  写 local header（crc=0 / size=0 / bit3=1 / version=45 / ZIP64 extra 占位）
  input → Crc32InputStream → CompressOutputStream(DeflateFormat) → CountingOutputStream → output
  写 24 字节 descriptor → 记 CentralEntry

close():
  cdStart = position
  逐条写 central header
  if 任一越界：写 EOCD64 + 定位器
  写 EOCD
```

**三个包装流的顺序不能换**：CRC 算在未压缩字节上（紧贴 `input`）、压缩后大小要数压缩后字节（`CountingOutputStream` 在 `CompressOutputStream` 之后）、`uncompressedSize` 就是 `Crc32InputStream` 读过的字节数（不要第二个计数器）。写反的后果很隐蔽——自身读写能互通，外部工具却报 "CRC mismatch"，这正是必须用外部工具验证的原因。

### 并发模型

- `ZipReader` 的 `entries()` / `read()` / `contains()` 在解析完成后只读，可并发调用。
- `open(name)` 每次独立句柄，**不加锁即可并发解压多个条目**。
- `ZipWriter` 不是线程安全的（单条 `OutputStream` 顺序写），文档明确写"同一个 writer 不得并发调用"；`spilling` 仅保证跨线程读安全。

### 测试策略

三层，缺一不可：

1. **构造性单测**（模块内 `cjpm test`）：空 ZIP、单文件 Stored/Deflate、多文件 + 目录、0 字节条目、中文名、嵌套路径、`addFileStream` 专项（bit 3 / version 45 / extra `0x0001` / descriptor 24 字节）、内存 + 流式混合、名字消解全表（`a.txt`/`a_2.txt`/`a_2_2.txt`/`dir.d/file`/`.gitignore`/`a.`）、`position` 单调、`spilling` 状态跃迁、阈值触发落盘、`ZipLimits` 四种上限、Zip Slip 四种路径、截断包、注释内嵌 EOCD 签名。
2. **外部工具交叉验证**（脚本用例，非 `cjpm test`）：写出的包必须过 `7z t` 与 Python `zipfile.testzip()`，`unzip -t` 为环境具备时补跑（当前环境无 `unzip`，见 `tasks.md` §13）；流式样本单独跑一轮（`add` 造的样本覆盖不到 descriptor）。读入侧用 Linux `zip`、7-Zip、Python `zipfile` 各造样本；Windows 资源管理器（GBK 名）与 macOS 归档工具（`__MACOSX/`、`._` 资源叉）无环境，由 GBK 字节直造 + Python `zipfile` 造样本替代，未跑项登记进 `f_zip/doc/兼容性例外.md`。
3. **资源行为验证**（Linux，脚本 + `/proc/self/status`）：`ZipReader(path)` 解压 1 GB 包 RSS 不线性增长；`add()` 100 MB 条目在 Linux 峰值 < 110 MB；`open(name)` 并发 4 条目数据不串。

`> 4 GB 单条目` 与 `> 65535 条目` 两个样本用稀疏文件 / 重复数据构造，标注为**慢用例**（`@Tag[slow]` 或独立脚本），不阻塞日常全量跑。

`f_util` 的 CRC 优化（D16）自带一套**等价性 + 吞吐**用例，与 `f_zip` 的验收解耦：先让 `f_util` 全绿（含 `crc_check_test`），再跑 `9.7b`。吞吐用例 1 MiB 断言 ≥ 30 MB/s，用 `F_UTIL_PERF=1` 门控（默认 SKIP，避免机器差异把 CI 弄成 flaky），跑通后把实测值回填 D16 与设计稿 `§10`。

## Risks / Trade-offs

| 风险 | 影响 | 处置 |
| --- | --- | --- |
| ZIP64 形式 descriptor 被部分解压器拒绝 | 流式包在个别老工具上打不开 | 先用三家工具实测；若失败只登记兼容性例外，**不改回 4 字节**（改回去等于放弃大文件或要求可回退输出流） |
| `@When` 两份声明重复、易漏改 | 平台阈值只在一侧生效 | 两份都带 `// 与另一份保持同步`；单测在 Linux 断言 64 MB，CI 在 OHOS 断言 16 MB |
| `charset4cj` 的 GBK 严格解码行为未在本模块验证 | 中文名回退链可能吞掉非法序列 | P0 先写一个 `decodeNameStrict` 的探针用例：合法 UTF-8 → 命中、非法 UTF-8 + 合法 GBK → 命中、两串都非法 → `None`，再往下写 |
| 自己读自己写会互相容忍同一个错误 | 逻辑错误逃过单测 | 外部工具校验为**独立验收步骤**（任务 8.x），不合并进"单测全绿" |
| 临时目录在 OHOS 上无 `/tmp` | 大条目落盘失败 | 四级解析 + 自动建 `.fountain_tmp/`；四级全失败抛明确错误，不降级回内存 |
| `maxTotalSize` 被误当作全局闸门 | 批量导入内存失控 | `api.md` 与 KDoc 都写明"每个 `ZipReader` 实例的累计"；需要总量控制时调用方自己持配额 |
| `> 65535` 条目 / `> 4 GB` 条目样本构建慢 | CI 时间变长 | 标注慢用例，默认套件跳过；发布前全量跑一次 |
| `f_log` 依赖让底层模块的依赖图变宽 | 编译期耦合 | 只在 `TempSpill` 一处使用 `Log.debug`；若将来要摘掉，把这一个调用点改成可注入回调即可，不影响公开 API |
| `CrcEngine` 热循环改动波及 `f_protocol` / `f_store` | 帧校验 / WAL 校验算错，且只在长数据上暴露 | 结果必须逐位不变：`crc_check_test` 全变体 + 测试内逐字节参考实现双基准；切片只对反射 32 位启用；`f_protocol` / `f_store` 各跑一遍 CRC 相关用例（任务 18.7） |
| 切片表口径与字节表不一致 | 短向量全对、长数据整体漂移 | 等价性用例必须含长度 ≥ 4 的随机数据与不整除 4 的尾巴；只生成一次表、生成公式写进 D16 |

## Migration / Rollout

- 纯新增模块：无数据迁移、无 API 破坏、无灰度需求。
- 唯一的既有模块改动是 D16：**纯性能、结果逐位不变**，但它是全仓库共用的底层函数，发布说明里要点明"`f_util` CRC32 提速，行为不变"，并在合入前跑完 `f_util` 全量 + `f_protocol` / `f_store` 的 CRC 用例。
- 顺序上必须"先能写出被外部工具认可的普通 ZIP（P3），再加 descriptor（P4.5）、ZIP64（P4.6）"——一次只引入一类"读端可能不认"的风险，出问题时能立刻定位到新加的那层。D16 必须在跑 `9.7b` **之前**完成，否则那个用例永远是"跑了但跑不完"。
- 发布时同步更新根 `README.md` 的模块清单与依赖矩阵图（若仓库有自动生成则按流程重新生成）。

## Open Questions

1. **`forLowMemory()` 的 8 MB 是否合适？** 目前是拍的。对 256 MB 嵌入式设备，8 MB 条目峰值 16 MB 尚可；对 512 MB 手机，16 MB 更合适。按"先 8 MB，真机测堆水位后修正"执行，不阻塞本次。
2. **`entries()` 是否要缓存 `ArrayList` 快照？** 默认每次返回新 `ArrayList`（防调用方改内部状态）；条目数上万时会有一次拷贝开销，实测后若显著再改为内部不可变列表 + 复制接口。
3. **`ZipEntry.modifiedAt` 的 `Option<DateTime>` 在 DOS 时间全 0 时返回 `None` 还是 1980-01-01？** 倾向 `None`（"没有时间信息"比"1980 年"更诚实），实现时按此处理并写进 `api.md`。
