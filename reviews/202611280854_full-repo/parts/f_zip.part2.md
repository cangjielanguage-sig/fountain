# f_zip 模块审查报告（第 2/4 部分）

> **模块第 2/4 部分**。本报告只覆盖 `files/f_zip.part2.txt` 的 20 个文件：`doc/spec/add-f-zip-module/specs/f-zip-security/spec.md`、`.../f-zip-writer/spec.md`、`.../tasks.md`、`doc/兼容性例外.md`，以及 `src/BoundedStream.cj` → `src/RawZipBuilder_test.cj` 的 16 个 `.cj`。`ZipReader` / `ZipWriter` / `Unzip` / `Zip` / `ZipLayout` / `ZipTime` / `ZipLimits` 由第 1、3、4 部分产出；本报告引用它们只作调用链与文档承诺的证据，不计入本部分统计。

- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（本部分 16 个 `.cj` + 4 个 `.md`，共 20 个文件）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题记「存量」
- **审查重点**：压缩包解析与安全（zip slip / 炸弹）、流式与内存、资源释放、死代码、重复逻辑
- **报告版本**：v1（第 2/4 部分，合并后由主 Agent 另存 `f_zip_v2.md`）

## 发现

### [严重][存量] #1 EOCD 的 `cdSize` 不与文件长度交叉校验，`readFullyAt` 先按该长度预分配 —— 22 字节文件可触发约 4 GiB 分配

- **位置**：`f_zip/src/Eocd.cj:109`（`cdSize` 直接取自 EOCD）、`f_zip/src/Eocd.cj:165-169`（`checkCdOffset` 只校验 `cdOffset`）、`f_zip/src/Eocd.cj:47`（`Array<Byte>(want, repeat: 0)`）
- **来源**：存量（`git log --oneline -- f_zip/src/Eocd.cj` 为 `bc44964e4`、`66d934e7f`）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— `cdSize` 是 EOCD 的 32 位字段（≤ `0xFFFFFFFF`），`checkCdOffset` 只判断 `cdOffset < 0 || cdOffset > size`，从不与 `cdSize`、`eocdOffset` 做关系校验；`readFullyAt` 在**读之前**就 `Array<Byte>(want, repeat: 0)`，长度完全等于 `want`。调用链：`ZipReader(path|input)` → `loadDirectory()`（`f_zip/src/ZipReader.cj:184-198`）→ `readFullyAt(source, info.cdOffset, info.cdSize)`（`ZipReader.cj:192`）。
- **描述**：构造 22 字节的「EOCD-only」文件：`entryCount = 1`（低于 `maxEntries` 默认 65535，能过 `ZipReader.cj:186` 的检查）、`cdSize = 0xFFFFFFF0`、`cdOffset = 0`。`ZipReader` 构造函数里立刻申请 4 292 967 280 字节，然后才发现「读不满 → 抛 `ZipException`」。也就是说：任何接收不可信 ZIP 的入口都能用 22 字节输入换一次 4 GiB 分配，并发解压时是稳定的 OOM / GC 抖动放大面。同一根因还让 `cdOffset + cdSize > eocdOffset`（中央目录延伸到 EOCD 之后）这类结构上不可能的包一路进入解析。
- **建议**：`checkCdOffset` 改成完整关系校验——`cdSize >= 0 && cdOffset >= 0 && cdOffset + cdSize <= eocdOffset`（ZIP64 分支同，且用减法形式避开溢出，见 #6）；`readFullyAt` 分配前用 `source.size` 兜底：`offset < 0 || offset > source.size || want > source.size - offset` 直接抛 `ZipException`。用例：把 `buildRawZip` 的 EOCD `cdSize` 改成 `0xFFFFFFF0`，断言抛 `ZipException` 且 `getAllocatedHeapSize()` 前后差 < 1 MB。

### [严重][存量] #2 `FileSource.readAt` 共用同一个 `File` 游标（seek + 读循环非原子），与 `ZipReader` 注释承诺的「`read()` 可并发调用」冲突

- **位置**：`f_zip/src/EntrySource.cj:89-110`（`99` 行 `file.seek(Begin(offset))`，`101-108` 行读循环）；被违背的承诺在 `f_zip/src/ZipReader.cj:34-35`、`f_zip/README.md:110`、`f_zip/doc/api.md:31`
- **来源**：存量（`af3ca77d8` 改写了读循环，`66d934e7f` 引入）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§11「契约与实现不符」
- **证据**：静态确定 —— `FileSource` 只有一个 `private var file: File`（`:73`），`readAt` 的「seek 到 offset → 循环 read」没有任何锁 / 原子 / 线程封闭；`openRange` 每次另开句柄（`:112-114`），说明"另开句柄"只解决了 `open` 路径，没覆盖 `readAt`。并发路径明确：`ZipReader.read(name)` → `decodeEntry` → `locateData` → `readFullyAt` → `source.readAt`（`ZipReader.cj:192`、`:224`、`:233`）。`BufferSource`（`ZipReader(input)`）无状态、每流独立游标，不受影响。
- **描述**：两线程对同一 `ZipReader(path)` 调 `read("a")` / `read("b")`：T1 `seek(100)` 后、`read` 前被 T2 的 `seek(200)` 顶掉，T1 读到 200 处内容 → local header 签名不符或 `nameLen/extraLen` 荒谬 → 随机抛 `ZipException`；极端时序下长度恰好合法，则数据起点算错、内容错位（多数被 CRC 兜住，但报错指向完全无关的原因）。服务端共享一个 `ZipReader(path)` 是最自然的用法，这条把注释里的承诺变成了随机失败。
- **建议**：按代价从低到高：① `FileSource` 加 `Mutex`，只包住 `seek + 读循环`；② `readAt` 每次 `openRange` 式另开句柄；③ 让 `locateData` 也走 `openRange` + 读满关流。改了实现就同步 `ZipReader.cj:34-35`、`README.md:110`、`doc/api.md:31` 的措辞；若选 ①，补一条双线程交叉 `read` 的压力用例。

### [一般][存量] #3 ZIP64 形式的 disk number（`0xFFFF`）解析出 extra 里的盘号后从未校验 —— 分卷条目被当单卷接受

- **位置**：`f_zip/src/CentralHeader.cj:154-156`（放行 `0xFFFF`）、`:162`（`wantDiskStart = diskStart == 0xFFFF`）、`:165-179`（只用 size / offset，`zip64.diskStart` 无人消费）；字段定义在 `f_zip/src/LocalHeader.cj:34`
- **来源**：存量（`66d934e7f` 引入；`bc44964e4` 只补了 EOCD 层的分卷校验）
- **判据**：review-checklist §11「契约与实现不符」、§1「读了不用」
- **证据**：静态确定 —— 全仓 `grep "diskStart"` 只命中 `CentralHeader.cj:146/154/155/162`、`LocalHeader.cj:34/40/45/64/78`（编码侧）与 `Zip64ExtraValues` 的构造；`parseZip64Extra` 的返回值里 `diskStart` 从未被读。EOCD 层（`Eocd.cj:99-106`、`:145-152`）对分卷是「读到就报」，条目层却开了口子。
- **描述**：`if (diskStart != 0 && diskStart != 0xFFFF) throw` 的意图是「非 0 就是分卷」，但 ZIP64 条目恰恰把真实盘号放在 extra 里：`diskStart = 0xFFFF` + extra 中 disk = 1 的条目一路无阻，最终用「别的盘上的偏移」在本文件里取数据 —— 通常以 `local header 截断` 或 CRC 失败收场，错误信息与真实原因（分卷）完全无关。
- **建议**：`parseZip64Extra` 返回后补 `if (let Some(d) <- zip64.diskStart) { if (d != 0) throw ZipException("不支持分卷 ZIP（条目 ${e.name} 的 disk number start = ${d}）") }`；补一条用例（CD 的 `diskStart = 0xFFFF` + extra 中 disk = 1 → 断言抛「分卷」）。

### [一般][存量] #4 条目名 / extra / comment 长度按 `UInt16` 静默截断，写入侧没有任何上限校验

- **位置**：`f_zip/src/CentralHeader.cj:111`（`writeU16LE(out, UInt16(e.nameBytes.size))`，另见 `:112` extra、`:113` comment）、`f_zip/src/LocalHeader.cj:239`（local header 的 name length，另见 `:240` extra）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §11「静默数据错误 / 缺少边界校验」
- **证据**：静态确定 —— 写入侧只有这三处 `UInt16(...)` 强转，`grep "65535"` 在 `src/` 只命中 `ZipLayout.ZIP64_MAX_U16`，没有任何 `> 0xFFFF` 的判断；`ZipWriter.add*(name)` 是公开入口，`name` 长度不受约束。
- **描述**：传入 ≥ 64 KiB 的条目名（或 comment）时，头里的长度字段写成截断值（70000 → 4464），而 `out.write(e.nameBytes)` 仍写 70000 字节 → 之后所有字段与偏移整体错位。写侧不报错、`close()` 正常返回，产物是结构损坏的 ZIP，问题被推到下游（自家 reader / `7za t` 报「签名不符」）才发现。
- **建议**：`ZipWriter.add*` 入口（分配名字之前）校验 `name.toArray().size <= 0xFFFF`，超限抛 `ZipException("条目名过长：${len} 字节（上限 65535）")`；`writeCentralHeader` / `writeLocalHeader` 里把 `UInt16(...)` 换成带校验的辅助函数，避免二次回归。

### [一般][存量] #5 `decodeName` 在 bit 11 置位时直接 `String.fromUtf8`，非法字节抛 `IllegalArgumentException`，违反「不抛异常」的注释与「失败一律 `ZipException`」的契约

- **位置**：`f_zip/src/NameCodec.cj:53-56`（`if (utf8Flag) { return String.fromUtf8(bytes) }`）；被违背的注释在 `:50-52`（「任何输入都能得到一个字符串，不抛异常」）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「错误处理 / 异常类型不符契约」
- **证据**：静态确定 —— `std/core/core_package_api/core_package_structs.md:6386`（`static func fromUtf8` 的「异常」小节）：「`IllegalArgumentException` - 入参不符合 utf-8 序列规则……抛出异常」；同文件 `fromUtf8Unchecked`（`:6411`）才是"不校验"的版本。本模块 `strictUtf8` 手写校验的理由正是"解码器会替换成 U+FFFD 而不报错"（`NameCodec.cj:88-93`），与 bit 11 分支的行为不一致。
- **描述**：伪造一个 bit 11 置位、名字字节为 `0xC3` 的条目：`entries()` / `read()` / `contains()` 触发 `CentralEntry.name`（`CentralHeader.cj:41-45`）→ `decodeName(bytes, true)` → `IllegalArgumentException` 逃出本模块的错误契约（调用方按 `doc/api.md` 只 catch `ZipException` 时会当未知异常冒到上层）。同时 bit 11 条目完全不走 `UTF-8 → GBK → Latin-1` 回退链，与「任何输入都能得到字符串」的目标相反；GBK 分支同类风险已被 `decodeGbk` 的 `catch` 挡住，只有这条裸奔。
- **建议**：bit 11 分支先走 `strictUtf8`，失败后回退 `decodeGbk → latin1`；若坚持「bit 11 即 UTF-8」，至少 `try { String.fromUtf8(bytes) } catch (_: IllegalArgumentException) { latin1(bytes) }`，并把注释改成与实现一致。补一条「bit 11 + 非法字节」用例。

### [一般][存量] #6 ZIP64 定位器偏移用 u64 直转 `Int64` 后做 `+ 56` 比较，越界触发溢出异常而非 `ZipException`

- **位置**：`f_zip/src/Eocd.cj:134-137`（`let eocd64Offset = Int64(u64At(locator, 8))`；`eocd64Offset + ZipLayout.EOCD64_SIZE > size`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §11「错误处理 / 异常类型」、§10 边界
- **证据**：静态确定 —— 整数运算默认溢出策略为 `throwing`（`cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/compile_options.md:235-237`：「默认为 `throwing`……整数运算溢出时会抛出异常」）。把 locator 的 offset 填成 `0x7FFF_FFFF_FFFF_FFFF`：`Int64(...)` 得到 `Int64.Max`，`+56` 立即溢出抛 `OverflowException`，绕过「所有失败都是 `ZipException`」的统一约定；大于 `Int64.Max` 的值在转换一步就可能抛同类异常（转换语义未逐个核对，结论对这两条路径都成立）。
- **描述**：调用方按文档只 catch `ZipException` 时表现为「未知异常」，`unzip` 的安全层（限额 / 半截文件清理）也接不住。同一文件的 `checkCdOffset` 用的是简单比较（没有 `+`，安全），但 `readZip64Eocd:135` 这处是 attacker-controlled 路径。
- **建议**：改成减法形式：`if (eocd64Offset < 0 || eocd64Offset > size - ZipLayout.EOCD64_SIZE)`（先判 `size >= EOCD64_SIZE`）；补一条用例：locator offset = `0x7FFFFFFFFFFFFFFF` → 断言抛「ZIP64 EOCD 偏移……超出文件长度」。

### [一般][存量] #7 `open()` 返回的条目流没有关闭途径（`InputStream` 只有 `read`，两处包装都未实现 `Resource`），提前放弃读取会一直占着文件句柄

- **位置**：`f_zip/src/BoundedStream.cj:103-150`（`FileRangeInputStream` 在 `:109` 打开 `File`，只有 `closeQuietly`，且仅被自身 `read` 的三个分支调用）、`f_zip/src/ZipReader.cj:291-330`（`ZipEntryInputStream` 只实现 `read`）
- **来源**：存量（`af3ca77d8`、`66d934e7f`）
- **判据**：review-checklist §11「资源不对称：打开未关、异常跳过释放」、mem §6（句柄生命周期）
- **证据**：静态确定 —— `std/io/io_package_api/io_package_interfaces.md:6-8`：`public interface InputStream { func read(buffer: Array<Byte>): Int64 }`，**没有 `close`**；关闭能力来自另一个接口 `Resource`（`f_io/src/DummyInputStream.cj:18` 的 `InputStream & Resource`、`f_io/src/BytePointerStream.cj:24` 的 `IOStream & Resource` 是仓内现成用法）。本模块两个包装类都没有实现 `Resource`，`ZipReader.openEntry`（`ZipReader.cj:143-150`）对外只暴露 `InputStream`。
- **描述**：`open(name)` 的典型用法就是"读一部分"（内容嗅探、只取前 4 KiB、按行读到第一行）。两种情况句柄不会及时归还：① 调用方提前 `return`；② 中途抛错（`owner.account` 触发限额、解压失败）。句柄只在"读到窗口末尾"时才由 `read` 内部关闭，于是批量处理 N 个条目时 FD 峰值不可控；Windows 上残留句柄还会让 ZIP 无法删除 / 改名。仓库内已有真实触发路径：`f_zip/src/Unzip.cj:147-171` 的 `writeEntryToFile` 在 `stream.read` 抛异常时，`finally` 只关 `target`、删半截文件，**不关 `stream`**；反复解压被限额打断的恶意包会持续累积 fd。`Resource*` 系列用例都是"读到底"，测不出这条。
- **建议**：让 `FileRangeInputStream` 与 `ZipEntryInputStream` 实现 `Resource`（`public func close(): Unit`），`ZipEntryInputStream.close()` 转发给 `inner`；并把未关闭的 range 流登记到 `ZipReader`，`ZipReader.close()` 统一收尾。`Unzip.writeEntryToFile` 把 `stream` 纳入 `finally`。用例：开 1000 个条目各读 1 字节后丢弃，`/proc/self/fd` 计数不线性增长。

### [轻微][存量] #8 重复逻辑：`LeBytes` 里 8 个端序原语两两同体（只差输入/出口）

- **位置**：`f_zip/src/LeBytes.cj:62-85`（`readU16LE/readU32LE/readU64LE`）↔ `:160-175`（`u16At/u32At/u64At`）；`:87-109`（`writeU16LE/writeU32LE/writeU64LE`）↔ `:112-134`（`u16LEBytes/u32LEBytes/u64LEBytes`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §2「只改类型名 / 换控制流」
- **证据**：静态确定 —— 逐字节展开的移位与掩码在两处完全一致（`b[0] = UInt8(v & 0xFF); b[1] = UInt8((v >> 8) & 0xFF)`），差异只有「写进流」还是「返回数组」、「读缓冲」还是「按偏移取值」。
- **描述**：8 个函数、4 组语义，任何一处位移写错都要改两遍（`readU32LE` 与 `u32At` 的换行风格也已不一致）。合并成本为零：`writeU16LE` 改成 `out.write(u16LEBytes(v))` 不会多一次分配。
- **建议**：`write*LE` 改为 `out.write(u*LEBytes(v))`；`read*LE` 内部改成 `readBytes(buf, n)` + `u*At(b, 0)`（保持「越界不动游标」语义）。合并后配合 `LeBytes_test` 的往返/越界用例守住。

### [轻微][存量] #9 重复逻辑 + 行为漂移：三份「限长读」实现，空缓冲处理三者不一致（`FileRange` 空读会直接关句柄）

- **位置**：`f_zip/src/BoundedStream.cj:42-63`、`:83-97`、`:116-140`；空缓冲判断在 `:43-45`、`:84-86`、`:117-120`
- **来源**：存量（`af3ca77d8` 把三处都改成「读进目标切片」）
- **判据**：review-checklist §2「换控制流 / 近似重复」、§11「边界」
- **证据**：静态确定 —— 三者骨架相同（判剩余 → 取 `min(buffer.size, left)` → 读/拷贝 → 递减），差异是数据源与"到 EOF 是否 close"；`FileRangeInputStream` 自己又实现了一遍 `BoundedInputStream` 的限长逻辑。空缓冲分支三者都归到 `-1`，其中 `FileRange` 还先 `closeQuietly()`（`:118`）。
- **描述**：调用方做一次 `stream.read(Array<Byte>())` 探测（或用 `buffer[0..0]`）时：`Bounded` / `ArrayRange` 返回 -1（被外层 `while (n > 0)` 当成流结束，条目被判「数据不完整」）；`FileRange` 更重——直接关句柄，此后该条目任何读取都返回 -1。三份实现漂移是 `af3ca77d8` 一次同改三处的直接产物，后续新增流类型很容易再踩。
- **建议**：`FileRangeInputStream` 只保留「独立句柄 + 可关闭」职责，限长交给组合（底层实现一个内部 `Closeable`，由 `BoundedInputStream` 在耗尽时回调）；空缓冲统一 `return 0` 且不改状态（不关句柄、不动 `remaining`）。改完补一条「空读后仍能正常读到数据」与「到 EOF 仍关句柄」的用例。

### [轻微][存量] #10 重复逻辑：ZIP64 哨兵判定与分卷盘号校验各写了两份

- **位置**：`f_zip/src/LocalHeader.cj:209-227` ↔ `f_zip/src/CentralHeader.cj:69-87`（哨兵判定 + `buildZip64Extra`）；`f_zip/src/Eocd.cj:99-106` ↔ `:145-152`（分卷盘号 + 同一条错误消息）
- **来源**：存量（`66d934e7f`；`Eocd.cj` 的 ZIP64 那份在 `bc44964e4`）
- **判据**：review-checklist §2「字面量复制 / 换算复制」
- **证据**：静态确定 —— 两处哨兵判定都是 `origOver/compOver(±offsetOver) → version = 45 → 哨兵字段 → buildZip64Extra`，差异仅「central 多 offset、local 多 version 赋值」；两处分卷校验都是 `let disk = if (x != 0) {x} else {y}` + `throw ZipException("不支持分卷 ZIP（disk ${disk}）")`（一处 u16、一处 u32）。
- **描述**：「两处各判一次 ZIP64」已经出过一次真实漂移（`tasks.md:17.2`：写侧 `>` 与读侧哨兵口径不一致，导致 65535 条目的包自读不回来）；分卷错误消息重复，改文案要改两处。
- **建议**：抽 `zip64Sentinel(orig, comp, offset) -> (Bool, Bool, Bool)` 供读写两侧共用，差异用参数表达；抽 `rejectSpannedDisk(diskA, diskB)` 统一分卷报错。合并时保留 `>=` 语义与「extra 只放越界项」的顺序，并补等价性用例。

### [轻微][存量] #11 重复逻辑：`ExternalCompat_test` 三个反向校验用例同构，外加 6 份 tempdir/finally 样板

- **位置**：`f_zip/src/ExternalCompat_test.cj:76-98`、`:135-156`、`:158-179`（三个 `*AcceptsOurArchives`）；`:78-97`、`:103-132`、`:138-155`、`:161-178`、`:184-210`、`:216-242`、`:248-280`（`Directory.createTemp` + `finally { removeIfExists }`）
- **来源**：存量（`66d934e7f`、`bc44964e4`）
- **判据**：review-checklist §2「同文件重复」
- **证据**：静态确定 —— 三个反向用例体只差「可执行文件名 + 参数 + 断言文案」，其余逐行对齐（`samples(work)` 循环 → `executeWithOutput` → `skipMissingTool` → `@Fail`）；`samples()` 被三个用例各调一次，在同一 temp 目录里重复写 12 个文件。
- **描述**：新增一个外部工具校验要复制 20 行；更实际的问题是「工具缺失即 skip」的口径（`tasks.md` 19.2）分散在多处，容易再次漂移。
- **建议**：抽 `withTempDir { dir => ... }` 与 `expectToolAccepts(tool, args, scenario)`；`samples()` 结果按目录缓存一次。（本文件 `:89-91` 还有一处不可达分支，见 #12。）

### [轻微][存量] #12 死代码 / 不可达：5 处无引用或只写不读，另有 3 处可见性可收窄

- **位置与清单**：
  1. `f_zip/src/EntryNameTable.cj:48` —— `while (true) { ... }`（`:40`）之后的 `throw ZipException("名字分配失败：${name}")` 永不可达（两个出口都是 `return`）。
  2. `f_zip/src/EntryNameTable.cj:67-69` —— `size()` 全仓零调用（`grep "size()" f_zip/src` 只有定义处；测试里的 `names.size` 是别的列表）。
  3. `f_zip/src/Eocd.cj:25-26` —— `EocdInfo.eocdOffset` 与 `eocd64Offset` 只写不读（`ZipReader` 只用 `entryCount` / `cdSize` / `cdOffset`；全仓无 `info.eocdOffset` 形式的读取）。
  4. `f_zip/src/LocalHeader.cj:190` —— `dataOffset` 只在 `f_zip/src/ZipReader.cj:236` 被赋值（`header.dataOffset = total`），无任何读取。
  5. `f_zip/src/BoundedStream.cj:36-40` —— `left` 属性全仓零引用。
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §1（不可达语句 / 非 public 符号无引用 / 读了不用）；`EocdInfo`、`LocalHeader`、`EntryNameTable` 都是 `internal` 顶层类型，其 `public` 成员按硬原则二判
- **证据**：静态确定 —— 逐符号全仓 `grep`，上述符号只有定义处或只有赋值处命中。另核对了其余符号：`leRemaining` / `skipBytes` / `needValue` / `concatBytes` / `u*At` / `safeRead` / `decodeGbk` / `latin1` / `strictUtf8` / `buildZip64Extra` / `parseZip64Extra` / `readFullyAt` / `locateEocd` / `readZip64Eocd` / `checkCdOffset` / `allocateDirectory` / `toZipEntry` / `deflateBytes` / `buildRawZip` 均有生产或测试调用。
- **描述**：`EocdInfo` 的两个字段是「设计稿预留、落位后没用上」的残留，构造方还要替它们算值；`LocalHeader.dataOffset` 让 `locateData` 多了一行无意义赋值，还配了一条「读取侧：数据起点」的注释，容易让维护者以为数据起点由 local header 解析得出（实际是 `e.localHeaderOffset + total` 现算）。可见性建议（不计死代码）：`EntryNameTable.contains` 仅 `EntryNameTable_test.cj:83-84` 使用，`insertSuffix` 仅同类内部使用，`BoundedInputStream` 整个类只被 `EntrySource_test.cj:93` 与 `ReadBufferReuse_test.cj:66` 引用。
- **建议**：删 `EntryNameTable.size()`、`BoundedInputStream.left`、`EocdInfo.eocdOffset/eocd64Offset`（连带简化 `readZip64Eocd` 的传参）、`LocalHeader.dataOffset` 与 `ZipReader.cj:236` 的赋值，以及 `EntryNameTable.allocate` 尾部的不可达 `throw`；`contains` / `insertSuffix` 收成 `internal` / `private`；`BoundedInputStream` 若确认没有下游用途就删除，或加注释说明"仅测试使用"。

### [轻微][存量] #13 文档与实现漂移（代码注释 / `tasks.md` 两处）

- **位置**：
  - `f_zip/src/BoundedStream.cj:25`（「传入的 `buffer` 比剩余长度大时用临时数组截断」）↔ 同文件 `:55-56`（「直接读入目标前缀，避免按剩余长度新建临时数组再拷贝」，实现是后者，`af3ca77d8` 改的）。
  - `f_zip/doc/spec/add-f-zip-module/tasks.md:30`（「`readBytes` / `skip`」）↔ 实现 `f_zip/src/LeBytes.cj:54`（`skipBytes`）。
  - `f_zip/doc/spec/add-f-zip-module/tasks.md:64`（`BoundedStream_test.cj`）↔ 实际位置 `f_zip/src/EntrySource_test.cj:87-118`。
- **来源**：存量（`af3ca77d8` / `66d934e7f`）
- **判据**：review-checklist §13「文档过期 / 描述的功能与实现不符」
- **证据**：静态确定 —— 直接对照行号；`grep "func skip" f_zip/src` 只有 `skipBytes`；`EntrySource_test.cj` 内含 `BoundedStream_test` 类。
- **描述**：类注释描述的分支已不存在，读者会照着去找；`tasks.md` 的用例落位偏差同类问题已被返修过一次（3.5 / 5.1 都补了注），这两处漏了。
- **建议**：类注释改成「超出剩余长度时只读入目标前缀」；`tasks.md:30` 的 `skip` 改 `skipBytes`、`:64` 补一句「用例寄居在 `EntrySource_test.cj` 的 `BoundedStream_test` 类」。

### [轻微][存量] #14 安全 spec 要求上限类错误消息包含「上限值与实际值」，实现只给上限值与条目名

- **位置**：`f_zip/doc/spec/add-f-zip-module/specs/f-zip-security/spec.md:136`（「涉及上限时 MUST 包含上限值与实际值」）↔ `f_zip/src/ZipReader.cj:272`、`:276`（`解压体积超过上限 ${limit}（${name}）`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 消息模板只有上限与条目名；对应 Scenario（`spec.md:143-146`）只要求「上限值与条目名」，所以单测不会报错，只有 Requirement 正文这条不成立。
- **描述**：定位问题时看不到「超了多少」，对 512 MB / 2 GB 两档上限尤其难排查。属文档承诺与实现不一致，不是行为缺陷。
- **建议**：二选一——消息改成 `...超过上限 ${limit}（实际 ${actual}，${name}）`（`account` 里两个数都现成），或把 spec 正文收窄成「上限值与条目名」并同步 `doc/api.md`。

> **范围外提示**（不占本部分统计）：`ZipWriter` 四个 `add*` 各自重复同一段 `LocalHeader` 字段装配（`ZipWriter.cj:85-100`、`:148-160`、`:220-235`、`:341-350`）；`ZipReader.findLast` 每次 `read`/`contains` 做 O(n) 线性扫描并为每条目解码名字（`ZipReader.cj:174-182`）。两者属其他部分。

## 优化可行性方案

> 不是缺陷，是「还能更好」。三条都无改前基线，`证据状态` 均为 `无基线（待验证，不进 tasks）`。

### [堆内存] 中央目录双份驻留：`readFullyAt` 的整块 + `ByteBuffer(array)` 的内部拷贝

- **现状**：`readFullyAt`（`f_zip/src/Eocd.cj:47-52`）返回长度为 `cdSize` 的新数组；`ZipReader.loadDirectory` 立刻交给 `ByteBuffer(cdBytes)`（`ZipReader.cj:192-193`），而 `f_io` 的这个构造是 `this(initialCapacity: array.size)` + `write(array)`（`f_io/src/ByteBuffer.cj:33-40`）——**新建数组并整块拷贝**。构造期间两份同时存活 ⇒ 峰值 ≈ 2 × `cdSize`；之后每条目的 name/extra/comment 再从缓冲拷出第三份（`CentralHeader.cj:150-152`）。
- **方案**：让 `readCentralHeader` 直接吃 `(Array<Byte>, offset)` 形式的游标（`LeBytes.cj:160-175` 已有 `u*At`），去掉 `ByteBuffer` 这一层；或给 `f_io.ByteBuffer` 增加零拷贝包装构造（需保证外部不再改写该数组）。
- **预期**：65535 条目 / CD ≈ 4 MB 时解析期峰值从 ~8 MB 降到 ~4 MB（数量级估算，未测）。
- **代价**：改 `readCentralHeader` 签名或新增 `f_io` 公开 API；零拷贝包装要明确所有权语义（`bytes()` 是引用视图，见 `std/core/core_package_api/core_package_structs.md:1187`）。
- **验证**：65537 条目样本解析前后 `getAllocatedHeapSize()` + RSS 差，5 轮取中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `CentralEntry.name` 每次访问都重新解码名字

- **现状**：`name` 是计算属性（`f_zip/src/CentralHeader.cj:41-45`），每次 get 都跑 `decodeName`：`strictUtf8` 全串扫描 + `String.fromUtf8` 再拷一份，非 UTF-8 时还要试探 GBK。触发点密集：`toZipEntry()`（每条目一次）、`entries()`、`findLast`（按名读取时对每个条目解码一次）、错误消息。
- **方案**：解析时解一次存字段（常驻多一份 `String`）；或让 `findLast` 把目标名 `encodeName` 成字节后与 `nameBytes` 逐字节比较（零常驻，但要注意 bit 11 与回退链的等价性）。
- **预期**：65535 条目下按名 `read()` 从「扫描 × 逐条解码」降到「扫描 × 字节比较」；具体降幅需实测。
- **代价**：字段缓存版增加常驻堆；字节比较版要保证同一显示名对应字节唯一（编码回退可能让不同字节得到同名）。
- **验证**：`cjprof record` 跑 65535 条目 × `read(name)` 1000 次；`cjpm bench -O2` 前后对照，取中位数与离散度。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 头部字段逐字段申请 2/4/8 字节小数组（读、写两侧都有）

- **现状**：读侧 `readU16LE/readU32LE/readU64LE`（`f_zip/src/LeBytes.cj:62-85`）每次 `Array<Byte>(2|4|8)` 再 `buf.read(dst)`，`readCentralHeader` 一条目约 19 次；写侧 `writeU16LE/...`（`:87-109`）每次同样新建数组再 `out.write`，`writeCentralHeader` 一条目约 13 次。65535 条目即百万级小分配。
- **方案**：读侧按固定头长（46 / 30 字节）一次读入，再用 `u*At` 按偏移取值，`readBytes` 只留给变长字段；写侧先拼一块定长头缓冲（或复用 writer 的成员缓冲），最后一次 `out.write`。
- **预期**：字段级分配次数降一个数量级；解析/写入耗时降幅需实测（-O2 下小对象分配可能只占个位数百分比）。
- **代价**：重写游标推进与字段偏移，必须原样保留 `needValue` 的截断错误文案；写侧偏移表需与 APPNOTE 对齐，ZIP64 / descriptor 分支要重算。
- **验证**：`cjprof heap` 分配采样 + `cjpm bench -O2`，同输入解析 / 写 65537 条目空条目。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `locateEocd` 每次构造都分配 64 KiB 尾窗，最坏逐字节倒扫 65535 次（每次 4 次带边界检查的数组读） | `f_zip/src/Eocd.cj:67-89` | 每次 `ZipReader(path)` 构造的分配量与耗时 | 造「0 注释」与「65535 字节注释」两个样本，构造 10k 次分段计时 |
| 2 | 中央目录双份驻留是解析期峰值主项 | `f_zip/src/Eocd.cj:47` + `ZipReader.cj:192-193` | 解析前后 heapUsed / RSS 峰值 | 65537 条目样本，`getAllocatedHeapSize()` + `/proc/self/status` 前后对照 |
| 3 | 按名读取的解码放大（`findLast` 每条目解码）在条目上万时成为 CPU 热点 | `f_zip/src/CentralHeader.cj:41-45` | 该段自耗时占比 | `cjprof record` 跑 65535 条目 × 1000 次 `read(name)`，看 `decodeName` 占比 |
| 4 | 头部字段的小数组分配是解析/写入期 GC 压力主要来源 | `f_zip/src/LeBytes.cj:62`、`:87` | 分配次数 / GC 次数 | `cjprof heap` 采样 65537 条目解析与写入，按调用点聚合分配量 |
| 5 | 未关闭的条目 range 流会让 FD 峰值随「丢弃的条目数」线性增长 | `f_zip/src/BoundedStream.cj:142-149` | FD 峰值与 GC 触发点 | 打开 1000 个条目各读 1 字节后丢弃，读 `/proc/self/fd` 计数，再手动 GC 观察是否回落 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-security/spec.md` | .md | ✅ | Zip Slip 四条校验、符号链接跳过、四道限额、加密拒绝、可诊断消息；与实现逐条对得上，唯一偏差见 #14 |
| 2 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-writer/spec.md` | .md | ✅ | 双轨写入 / 24 字节 descriptor / ZIP64 升级 / 同名消解 / 平台阈值；七类消解场景与 `EntryNameTable_test` 一一对应；名字长度上限未在 spec 里写（对应 #4） |
| 3 | `f_zip/doc/spec/add-f-zip-module/tasks.md` | .md | ✅ | 实施记录与实测值完整；见 #13（`skip` 与 `BoundedStream_test.cj` 落位两处未注） |
| 4 | `f_zip/doc/兼容性例外.md` | .md | ✅ | 表为空 + 六组交叉验证结论；与 `ExternalCompat_test` 的样本类与"缺 `unzip`"口径一致 |
| 5 | `f_zip/src/BoundedStream.cj` | .cj | ✅ | 见 #7（range 流无关闭途径）、#9（三份限长读 + 空缓冲）、#12（`left` 无引用）、#13（类注释）；`CountingOutputStream` / `Crc32InputStream` 无缺陷 |
| 6 | `f_zip/src/CentralHeader.cj` | .cj | ✅ | 见 #3（ZIP64 diskStart）、#4（长度截断）、#5（`name` 触发解码）；`writeCentralHeader` 的哨兵与 extra 顺序符合 APPNOTE |
| 7 | `f_zip/src/EntryNameTable.cj` | .cj | ✅ | 消解语义与 spec 七类场景一致；见 #12（不可达 `throw`、`size()` 无引用、`contains`/`insertSuffix` 可见性） |
| 8 | `f_zip/src/EntryNameTable_test.cj` | .cj | ✅ | 7 个用例覆盖 spec 全部消解场景；多字节同名的消解路径无用例（已按 `String` 字节下标语义核对实现正确，仅记覆盖缺口，不计缺陷） |
| 9 | `f_zip/src/EntrySource.cj` | .cj | ✅ | 见 #2（`readAt` 共享游标）；`BufferSource.close` 为内存源的有意 no-op（不计） |
| 10 | `f_zip/src/EntrySource_test.cj` | .cj | ✅ | 内含 `BoundedStream_test` 类（见 #13）；`fileSourceBasics` 两个 range 流不读到 EOF，正好演示 #7 |
| 11 | `f_zip/src/Eocd.cj` | .cj | ✅ | 见 #1（`cdSize` 预分配）、#6（u64 偏移溢出）、#10（分卷校验重复）、#12（`EocdInfo` 两个字段）；窗口扫描与 ZIP64 链的字段偏移手工核算正确 |
| 12 | `f_zip/src/Eocd_test.cj` | .cj | ✅ | 8 个用例覆盖空包 / 注释内嵌签名 / 窗口外 / 分卷 disk / 定位器损坏；`cdOffsetOutOfRange` 手工复制字节未复用 `cloneBytes`（测试内小重复，未单列） |
| 13 | `f_zip/src/ExternalCompat_test.cj` | .cj | ✅ | 四类样本 × 三个外部工具 + 三个正向读取；见 #11、#12（`:89-91` 不可达分支） |
| 14 | `f_zip/src/LeBytes.cj` | .cj | ✅ | 见 #8（8 个原语两两重复）、优化方案 3；「越界不动游标」的前提（`ByteBuffer.read` 短读会 `clear()`）经 `f_io/src/ByteBuffer.cj` 核实属实 |
| 15 | `f_zip/src/LeBytes_test.cj` | .cj | ✅ | 5 个用例守住四条硬约定（越界不位移、短读、端序、失败后可继续读），无缺陷 |
| 16 | `f_zip/src/LocalHeader.cj` | .cj | ✅ | 流式 / 内存两条 header 填法与 spec 一致；见 #4（name 长度）、#10（哨兵判定重复）、#12（`dataOffset` 只写不读） |
| 17 | `f_zip/src/LocalHeader_test.cj` | .cj | ✅ | 含 `LocalHeader_test` 与 `CentralHeader_test` 两个类（tasks 3.5 已注）；ZIP64 extra「只放越界项」的断言与实现一致 |
| 18 | `f_zip/src/NameCodec.cj` | .cj | ✅ | 见 #5（bit 11 直解抛 `IllegalArgumentException`）；回退链与 `strictUtf8` 的过长编码 / 代理区 / 上界校验手工核算正确 |
| 19 | `f_zip/src/NameCodec_test.cj` | .cj | ✅ | 7 个用例覆盖 ASCII / 中文 / GBK / Latin-1 / 严格校验；未覆盖 bit 11 + 非法字节（对应 #5 建议） |
| 20 | `f_zip/src/RawZipBuilder_test.cj` | .cj | ✅ | `buildRawZip` / `deflateBytes` 供多个测试造样本；`out.bytes()` 是引用切片（`core_package_structs.md:1187`）不产生 O(n²) 拷贝，无缺陷 |

合计：`.cj` 16 个 / `.md` 4 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | #1~#7。已核对而非缺陷的项：`dst[got..want]` / `buffer[0..remaining]` 依赖"切片是引用"语义（`std/core/core_package_api/core_package_structs.md:1187`、`:2616`），写入落到原数组、不丢数据；`ByteBuffer.read` 短读会 `clear()`，所以 `readBytes` 必须先算剩余（`leRemaining`）；ZIP64 extra 字段顺序、哨兵判定、EOCD64 字段偏移手工核算正确；`insertSuffix` 的字节下标与 `String` 切片语义一致（`core_package_structs.md:9383`） |
| §1 死代码 | 5 | #12 的五处：不可达 `throw`、`EntryNameTable.size()`、`EocdInfo.eocdOffset/eocd64Offset`、`LocalHeader.dataOffset`、`BoundedInputStream.left`。其余符号逐个全仓 grep 均有引用；对外不可达的 `public` 成员按硬原则二判；仅测试引用的 `BoundedInputStream` / `contains` 记为可见性建议，不判死代码 |
| §2 重复逻辑 | 4 | #8（8 个端序原语）、#9（三份限长读）、#10（ZIP64 哨兵 + 分卷校验）、#11（测试同构 + tempdir 样板）。同文件函数体两两比对了 20 个：`buildZip64Extra`/`parseZip64Extra` 与 `buildZip64Sample`/`buildRawZip` 职责不同，不并；`readLocalHeader`/`readCentralHeader` 字段布局不同，不并 |
| §3 空实现 | 0 | `BufferSource.close`（`EntrySource.cj:67`）是内存源的有意 no-op；`catch (_: Exception) {}` 只包「关闭 / 删除临时文件」这类无业务后果的清理（`EntrySource.cj:119-122`、`BoundedStream.cj:145-148`、`Unzip.cj:157-170`）；无 `TODO` / 未接线分支 |
| §4 栈溢出 | 0 | 本部分无递归：`decodeName` 的回退链是三条独立函数；`locateEocd` / `parseZip64Extra` / `readCentralHeader` 全是深度由常量决定的循环 |
| §5 OOM | 1 | #1（按不可信 `cdSize` 预分配）。其余分配均有上界：尾窗 ≤ 22+65535、local header `total ≤ 30+65535+65535`、`readBytes` 的 n ≤ 65535、`latin1` 的 Rune 数组 ≤ nameLen |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点结论不成立；三个候选已进「待验证假设」与优化方案（均无基线） |
| §6.2 大粒度锁 | 0 | 本部分没有任何锁；`#2` 是「该加锁而没加」，不是锁太大 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 0 | 结构上可指出 `findLast` 的 O(n) 扫描 + 每条目解码（`ZipReader.cj:174-182`），无实测支撑，只作范围外提示与假设 3 |
| §7 降堆内存方案 | 1 | 「中央目录双份驻留」，`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 「`CentralEntry.name` 重复解码」「头部字段逐字段小数组（读+写）」，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 热点候选产出的是逃逸对象（`CentralEntry` 进 `rawEntries`、`cdBytes` 交给 `ByteBuffer`），不满足 local region 的「不离开函数」前提；剩余临时对象（2/4/8 字节数组）峰值太小，无法用峰值内存证明收益 |
| §11 现有代码的 BUG（存量） | 7 | #1~#7 全部存量。另核对了 6 处边界未成立：`readBytes(n==0)`、`skipBytes` 负数、`u32At` 在 `i = window-22` 时的上界、`parseZip64Extra` 的 `pos+4` 上界、`ArrayRangeInputStream` 的 `offset+length` 截到 `data.size`、`buildZip64Extra` 空 payload 早退 |
| §12 并发安全与锁粒度 | 1 | #2。`BufferSource` 无状态、`ArrayRangeInputStream` 每流独立游标、`CountingOutputStream` / `Crc32InputStream` 每实例独占——逐类核对过线程封闭性；`ZipReader.consumed` 的原子记账不在本部分文件 |
| §13 文档一致性（.md 与代码注释） | 3 | #14（spec 正文 vs 错误消息）、#13（类注释 + `tasks.md` 两处）、#5 的注释侧（「不抛异常」vs `String.fromUtf8`）。两个 spec 的验收口径与实现逐条对得上（含 `unzip` 可选证据口径、`>= 0xFFFF` 升级、临时目录首选+逐级回退） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分文件不新增对外符号（`EntrySource` / 各流 / `EntryNameTable` / `CentralEntry` / `LocalHeader` 均 `internal`），README 覆盖由公开 API 所在部分负责；spec / tasks 承诺的能力（ZIP64 extra、分卷拒绝、GBK 回退、同名消解、24 字节 descriptor）在本部分均有实现与用例 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无缺项 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

待验证假设 5 条，不计入上表，也不进 `todo.md` / `tasks.md`。存量 14 条（严重 2 / 一般 5 / 轻微 7），是否纳入修复待用户决定。

## 总评

本部分是 f_zip 的地基：端序原语、四种 header 读写、EOCD/ZIP64 链、名字编码与同名消解。硬约定（越界不动游标、extra 只放越界项、按长度决定读几个 8 字节、`>=` 哨兵）都有注释与用例兜住，读写两侧的字段往返测试相当齐，是本模块质量最高的一段。

阻塞项两条，都在「打开归档」这一侧：#1 的 `cdSize` 预分配是真正能打崩进程的那条（22 字节换约 4 GiB，发生在 `ZipReader` 构造函数里，任何网关都会先撞上），修法很小（两处减法比较 + `readFullyAt` 的长度兜底），应优先；#2 的并发共享游标与 `ZipReader.cj:34-35` 的承诺直接矛盾，加一把只包住 seek+read 的 `Mutex` 即可，不必改架构。这两条建议同批修，并各补一条负例（`cdSize` 伪造、双线程交叉 `read`）。

其余五条一般问题（ZIP64 条目分卷口子、名字长度截断、bit 11 非法 UTF-8 抛错类型、u64 偏移溢出、条目流无关闭途径）单条触发条件都不算常见，但都是「静默或错误类型不符」型：#3 / #6 与 #1 同属「EOCD 链校验不足」，建议一起改、一起补负例；#4 / #5 是写入侧与解码侧各一处缺校验，改动小；#7 需要在 `BoundedStream` / `ZipReader` 之间引入 `Resource` 契约，顺带修掉 `Unzip` 的 fd 泄漏，值得排进同一次迭代。

轻微项（端序原语与限长流重复、ZIP64 判定两处、测试同构、5 处死代码、两处文档漂移、一处 spec 措辞）纯属可维护性，可随下次触碰该文件顺手处理；#9 / #10 有耦合，建议同一次改完，否则「三份实现漂移」「两处哨兵判定漂移」还会复现。三条优化方案与五条待验证假设都缺改前基线，只用于下一轮补数据，不进修复清单。

本报告只报不修，未改动任何源码、未跑构建。
