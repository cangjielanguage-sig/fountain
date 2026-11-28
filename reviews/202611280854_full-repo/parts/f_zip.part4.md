# f_zip 模块审查报告（模块第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（本部分 6 个源文件：`ZipWriter.cj`、`ZipWriterOptions.cj` 与 4 个测试文件；全模块 .cj/.md 由 part1–part4 覆盖）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源统一记为「存量」
- **审查重点**：压缩包解析与安全（zip slip / 炸弹）、流式与内存、资源释放、死代码、重复逻辑；本部分实际落在**写入侧（ZipWriter）+ 写入侧测试**
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `<module>_v2.md`）

## 发现

### [一般][存量] `close()` 失败后重试会在文件里留下残缺/重复的中央目录区

- **位置**：`f_zip/src/ZipWriter.cj:381-449`（`close()`；关键状态缺失在 `391-400`，置位在 `444-448`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（错误处理缺失 / 语义与注释不符）；§6.2 无关，属写入状态机缺陷
- **证据**：静态确定 —— `close()` 只用局部变量 `cdStart` 记录中央目录起点，没有任何字段记住「CD 已经开始写」。`closed` 仅在 `out.flush()` 之后置位（`448`），失败路径不复位 `cdStart`、也不置 `dirty`
- **描述**：`close()` 的注释（`377-380`）承诺「写失败时不算已关闭，再次调用会重试（而不是静默返回、留下半截文件）」。实际重试路径有二：
  1. 中央目录写到一半失败（磁盘满 / 传输中断）→ 第二次 `close()` 以 `position`（已含前一次的残缺字节）为新 `cdStart` 再写一整份 CD，EOCD 指向第二份。文件可被 `EOCD → cdOffset` 型读取器（本项目 `ZipReader`、Python `zipfile`、Info-ZIP）正常读出，但条目数据区与中央目录之间多出一段不可达字节，`zip -T` 一类严格校验会报「extra bytes」类告警。
  2. `flush` 失败（EOCD 已写出）→ 重试再写一份 CD + EOCD，尾部出现两个 EOCD。
  另外失败后 `closed == false && dirty == false`，`ensureUsable()`（`453-463`）放行，调用方还能继续 `add()`，把新条目插到残缺 CD 之后，进一步放大上述夹层字节。
- **建议**：新增 `private var cdWritten = false` 或在进入 CD 循环前置 `dirty = true`（配合专门的 `closingError` 消息），使「CD 已开始写」成为不可回退状态；若确实要支持重试，则必须记录 `cdStart` 并在重试时断言 `position == cdStart`，否则抛「上次 close 已写入部分中央目录，无法安全重试」。

### [一般][存量] 条目名未做任何校验：`/` 结尾的「文件」在 unzip 侧静默丢数据、超长名抛裸异常

- **位置**：`f_zip/src/ZipWriter.cj:86`（`add`）、`:142`（`addFileStream`）、`:216`（`openEntry`）、`:312`（`addFile`）、`:331`（`addDirectory`）；长度截断点在 `f_zip/src/LocalHeader.cj:239`
- **来源**：存量
- **判据**：review-checklist §11（边界/契约与实现不符）、§10 安全性（外部可控字符串直接进归档结构）
- **证据**：静态确定 —— 五条写入入口都只做 `names.allocate` + `encodeName`（`NameCodec.cj:41`，仅判 ASCII/UTF-8），没有任何空串 / 尾斜杠 / 长度检查；`writeLocalHeader` 直接 `writeU16LE(out, UInt16(h.nameBytes.size))`（`LocalHeader.cj:239`）
- **描述**：三种边界都缺校验，其中第一种会静默丢数据：
  1. `add("dir/", data)` 写出的是一个「名字以 `/` 结尾但带数据」的条目。`unzip` 按名字判目录（`Unzip.cj:70-73`：`if (e.isDirectory) { ensureDirectory; continue }`），于是数据被丢弃且不计入返回值——包里的内容永远取不回来，而 writer 侧毫无提示。
  2. 名字长度 > 65535 字节（`String` 参数可由调用方任意构造，如用户上传文件名）时，`UInt16(size)` 触发默认溢出策略抛异常（语言文档 `basic_data_type/integer.md:137`：「若溢出可提前被编译器检测出来，则编译器会直接给出报错，否则根据默认的溢出策略将抛出异常」）。异常发生在 local header 已写出前 26 字节之后，被 `add*` 的 `catch` 转成脏状态，调用方拿到的是 `ArithmeticException` 而不是 `ZipException`。
  3. 空名字直接写出 0 长度 name 的条目，读取侧 `decodeName` 得到 `""`，`unzip` 侧由 `resolveSafeTarget` 判非法（`Unzip.cj:114-116`）——自己写的包自己解不开。
- **建议**：在 `ZipWriter` 内加一个 `private func checkEntryName(name: String, isDirectory: Bool)`：拒绝空串、拒绝非目录语义下以 `/` 结尾、拒绝 `nameBytes.size > 0xFFFF`（用 `encodeName` 之后的字节数判），统一抛 `ZipException`；`addDirectory` 允许尾斜杠但同样限制长度。

### [一般][存量] 压缩失败路径不关闭 `CompressOutputStream`，原生 deflate 资源泄漏

- **位置**：`f_zip/src/ZipWriter.cj:170-192`（`addFileStream`：`compressor` 只在 `pump` 正常返回后 `close()`）、`:496-507`（`compressData`：`compressor.write/close` 都不在 `try` 内）；同根因另见 `f_zip/src/ZipEntryOutputStream.cj:127-134`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称）、§3（错误路径静默跳过释放）
- **证据**：静态确定 —— `stdx.compress.zlib.CompressOutputStream.close()`（`cangjie_stdx/src/stdx/compress/zlib/zlib_stream.cj:242-253`）是唯一调用 `deflater.deflateEnd()` 的地方；`ZipWriter` 的异常分支只做 `markDirty` + `throw`，从不 `close()` 压缩器
- **描述**：`pump(crcStream, compressor)` 抛异常（源流中断、磁盘写失败都是真实场景，测试 `ZipWriter_test.cj:421-430` 就是模拟它）时，`deflater` 持有的 zlib `z_stream` 与其内部缓冲不会 `deflateEnd()`，只能等 GC（`Deflate` 无显式终结器）。`compressData` 的 `compressor.write(data)` 同理。`ZipEntryOutputStream` 更彻底：`failed == true` 时 `close()` 在 `132-134` 直接 `return`，连正常收尾的机会都没有。
- **建议**：`try { pump(...) } catch (e) { try { compressor.close() } catch (_) {}; throw e }`，或把 `compressor` 放进 `try ... finally { if (!closed) compressor.close() }`；`ZipEntryOutputStream.close()` 在 `failed` 分支里也应 `try { c.close() } catch (_) {}`。

### [一般][存量] 清理路径吞掉所有异常，临时文件可能静默残留

- **位置**：`f_zip/src/ZipWriter.cj:486-493`（`addSpilled` 的 `finally`：`file.close()` 与 `removeIfExists(tmpPath)` 各一个空 `catch`）、`:320-324`（`addFile` 的 `finally`）
- **来源**：存量
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）
- **证据**：静态确定 —— 三处 `catch (_: Exception) {}` 内没有任何日志 / 计数，`TempSpill` 的 logger（`TempSpill.cj:36`）只用于创建成功的 debug 日志
- **描述**：`add()` 走落盘路径时，`removeIfExists(tmpPath)` 失败（Windows 上文件仍被占用、目录被外部清理、权限变化）会被完全吞掉。调用方看到的是成功的 `add()`，但磁盘上留下一个与条目同大的临时文件；反复触发就是持续磁盘增长，且没有任何观测点。`file.close()` 的静默失败同理（读句柄，影响较小）。
- **建议**：至少 `logger.warn("zip: 删除临时文件失败 ${tmpPath}: ${e.message}")`；`removeIfExists` 的失败要不要升级为异常应在注释里明确（推荐 warn，不破坏已成功写入的归档）。

### [一般][存量] 符号链接用例无平台门控，Windows 上必然失败

- **位置**：`f_zip/src/ZipWriter_test.cj:293-319`（`addFileFollowsSymlinkAndRejectsMissing`，`SymbolicLink.create` 在 `300`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理 / 环境假设）
- **证据**：需实测 —— 用例没有 `OS.current` 判断或跳过分支；Windows 创建符号链接需要开发者模式或管理员权限，`std.fs.SymbolicLink.create` 会抛 `UnauthorizedAccessException`，`finally` 里只会删临时目录，用例直接失败。同根因另见 `Unzip_security_test.cj:215-216`（范围外，不重复计数）
- **描述**：模块本身支持 Windows（`ZipWriterOptions.cj:42` 的 `@When[os != "Linux" || env != "gnu"]` 分支、`f_base.OS` 的 `Windows` 分支齐备），但这条用例把「跟随符号链接」的核心断言绑死在 POSIX 权限模型上；Windows 开发者跑 `cjpm test` 会在这一段红。
- **建议**：`if (!SymbolicLink.tryCreate(...)) { skipGated("当前环境不允许创建符号链接"); return }`，或按 `OS.current.isWindows` 走 `skipGated`（`ZipTestSupport_test.cj:42` 已有统一出口）。

### [轻微][存量] `close()` 与 `ensureUsable()` 重复实现两条前置检查，错误文案字面相同

- **位置**：`f_zip/src/ZipWriter.cj:385-390`（`close`）与 `:457-462`（`ensureUsable`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 字面量复制）
- **证据**：静态确定 —— 两处都是 `if (entryOpen) throw ZipException("条目 ${openEntryName} 仍在写入，先关闭条目流")` + `if (dirty) throw ZipException("条目 ${dirtyEntry} 写入中断，ZIP 结构不完整")`
- **描述**：`close()` 不能直接调 `ensureUsable()`（后者还要拒绝已关闭状态），于是把两条检查抄了一遍。文案改一处漏一处就会出现两种措辞。
- **建议**：抽 `private func checkWritable(allowClosed: Bool)`，`close()` 传 `true`、`add*` 传 `false`；`ensureUsable()` 变成一行转发。

### [轻微][存量] data descriptor 与 local header 的构造各重复 4 处

- **位置**：`f_zip/src/ZipWriter.cj:185-188` 与 `:271-280`（24 字节 descriptor 的 4 次 `writeU32LE/writeU64LE`）；`:98-110`、`:150-160`、`:224-234`、`:343-352`（`LocalHeader` 的 flags / dosTime / dosDate / nameBytes 赋值）
- **来源**：存量
- **判据**：review-checklist §2（同一串字面量 / 同一组字段名散落多处）
- **证据**：静态确定 —— 两段 descriptor 代码逐行一致；四段 header 构造除 `streaming`、`method`、`crc/size` 外完全相同
- **描述**：`finishEntry` 是推模式条目的收尾，`addFileStream` 是拉模式收尾，两者写出完全相同的 `SIGNATURE_DATA_DESCRIPTOR + crc + comp + uncomp`。descriptor 格式若改动（例如改成 12 字节非 ZIP64 形式）必须同时改两处，漏一处就产出两种格式混存的包。header 构造同理（新增 flag 要改 4 处）。
- **建议**：`private func writeDescriptor(out: OutputStream, crc: UInt32, comp: Int64, uncomp: Int64)`；`private func newHeader(nameBytes, utf8, method, now, streaming) -> LocalHeader`。

### [轻微][存量] `spilling` 用例忙等自旋、无慢用例门控、断言依赖时序窗口

- **位置**：`f_zip/src/ZipWriter_test.cj:352-378`（`spillingObservedDuringSpill`）
- **来源**：存量
- **判据**：review-checklist §11（用例本身的健壮性）；模块约定见 `ZipTestSupport_test.cj:26-44`
- **证据**：需实测 —— `while (!done.load()) { if (writer.spilling) ... }`（`360-367`）没有 `sleep`/`yield`，在落盘期间占满一个核；断言 `seen == true` 取决于 poller 是否正好在 8 MB 临时文件写入窗口内被调度到（4 次机会）
- **描述**：该用例一次写 4×8 MB 到临时目录，却没有走模块统一的 `slowEnabled()` / `skipGated()` 门控（`Zip64BigEntry_test.cj:43`、`Zip64EntryCount_test.cj:36` 都走了），在 OHOS 真机或小 tmpfs 环境上既慢又可能因时序没抓到 `true` 而偶发失败。
- **建议**：断言改为「跨线程读到的值曾经为 true 或最终为 false」之外，再加一个确定性的观测点（例如让 `addSpilled` 支持注入回调 / 用 `AtomicBool` 记录 `maxSeen`）；至少补 `if (!slowEnabled()) { skipGated(...); return }`，并在轮询里加 `sleep(Duration.millisecond)`。

### [轻微][存量] `unzip` 返回值语义（条目数 vs 文件数）被测试固化，与文档不符

- **位置**：`f_zip/src/Zip_test.cj:87-95`（`duplicateEntriesOverwrite` 断言 `unzip(...) == 2`）；契约侧 `f_zip/src/Unzip.cj:23`（「返回解压出的**文件数**」）与 `:76`（`count += 1` 按条目累加）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）、§13（文档承诺与实现不一致）
- **证据**：静态确定 —— 两个同名条目 `x.txt` 依次写入，磁盘上只有 1 个文件，`unzipInto` 对每个非目录条目 `count += 1`，因此返回 2
- **描述**：用例把「返回值 = 写入的条目数」固化成契约。调用方按文档拿它做进度 / 完整性计数时，同名覆盖场景会得到大于实际文件数的值。
- **建议**：二选一——要么把 `Unzip.cj:23` 的注释改成「返回写入的条目数（同名覆盖会重复计数）」，要么按去重后的路径计数并同步改用例。属契约变更，需用户拍板。

### [轻微][存量] `TempSpill_test` 与 `Zip_test` 混在一个文件，且同一次失败调用连跑 3 遍

- **位置**：`f_zip/src/Zip_test.cj:122-181`（`TempSpill_test` 类在 `123`；`allCandidatesFailThrows` 的 `178-180` 三次相同调用）
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）、§10 可维护性
- **证据**：静态确定 —— 模块其余测试都是「一个类一个同名文件」（`ZipTime_test.cj` ↔ `ZipTime_test`、`ZipReader_test.cj` ↔ `ZipReader_test`），只有 `TempSpill_test` 没有独立文件；`178-180` 三次 `TempSpill.createIn(bogus, "x.bin", 1234, 1024)` 参数完全一致
- **描述**：文件命名与内容不对应，按类名找不到用例文件；三次重复调用只为断言同一条消息的三个片段，`captureZipError` 已经能一次拿到异常对象。
- **建议**：拆出 `TempSpill_test.cj`；`let e = captureZipError({=> ...}).getOrThrow()` 后连断言三次。

### [轻微][存量] 测试保真度与边界覆盖：模拟中断的输入流从不返回部分数据，若干边界无用例锚定

- **位置**：`f_zip/src/ZipWriter_test.cj:496-522`（`FailingInputStream`）；覆盖缺口见 `f_zip/src/ZipTime_test.cj:69-73`、`ZipWriter_test.cj` 全文
- **来源**：存量
- **判据**：review-checklist §11（用例与注释不符）、§14（关键分支无覆盖）
- **证据**：静态确定 —— `FailingInputStream.read`（`506-521`）只在**读开始时**判 `position >= failAfter`，从不截断一次读：`failAfter = 1` 且数据只有 3 字节时，第一次 `read` 直接返回 3，第二次才抛；注释「读到第 `failAfter` 个字节后抛异常（模拟传输中断）」描述的语义没有实现
- **描述**：三个缺口：(1) `FailingInputStream` 无法模拟「读了一半再断」，而 `pump` 的 `dst.write(chunk[0..n])` 只在完整读到数据后才写，真正的半截读路径没被覆盖；(2) `ZipTime` 的 1980/2107 钳位（`ZipTime.cj:36-42`）与非法日期分支（`:60-62`）无断言；(3) 上面 G2 的尾斜杠名、超长名无任何用例。
- **建议**：`FailingInputStream` 改为「最多返回 `min(remaining, buffer.size)` 字节，达到 `failAfter` 后下一次读抛」；补 `encodeDosDate(1979/2108)` 与 `decodeDosDateTime(0, 0x0021)` 用例；补 `add("dir/", data)` 的拒绝用例（修完 G2 后）。

## 优化可行性方案

### [堆内存] `add()` 内存路径可以不做整份压缩副本

- **现状**：`add()`（`ZipWriter.cj:86-134`）峰值持有三份数据：调用方的 `data`（N）、`compressData` 里 1.5× 增长的 `ByteBuffer`（容量 ≤1.5×C）、以及 `buf.bytes()`（`f_io/src/ByteBuffer.cj:56-58` 返回 `buffer[roffset..woffset]` 切片，即 C 的完整副本）。按 `memoryEntryThreshold` 默认 64 MB 算，单条目峰值约 N + 2.5C（不可压数据时 ≈ 3.5N ≈ 224 MB）
- **方案**：方案 A——内存路径改为复用流式写法的骨架：先写 `streaming = true` 的 local header（`writeLocalHeader` 已经支持 ZIP64 占位），header 里 CRC/大小留 0，数据直接 `out.write(data)`，末尾补 24 字节 descriptor，把 `compressData` 与 `payload` 整体删掉（压缩改由 `CompressOutputStream(out)` 直写）。方案 B（保留真实 header 语义）——`ByteBuffer(initialCapacity: data.size + 64)` 一次预留，避免 1.5× 增长轨迹，并把 `compressData` 改成返回 `(ByteBuffer, len)` 由调用方 `write(buf[0..len])`
- **预期**：方案 A 单条目峰值从 ≈3.5N 降到 ≈N（deflate 内部 8 KB 缓冲 + 32 KB 窗口除外），64 MB 条目省 ~160 MB；方案 B 省掉增长期的旧数组与末尾切片副本，约省 1.5C
- **代价**：方案 A 会让「内存路径」也带 descriptor（bit 3 置位、version 45），与 `ZipWriter.cj:32-37` 表格承诺的「内存路径不写 descriptor」冲突，老工具兼容性需回归；方案 B 无行为变化，收益较小
- **验证**：固定 64 MB 可压 / 不可压两种输入，`cjpm bench -O2` 对照 `getAllocatedHeapSize()` 峰值与 RSS，各跑 10 轮取中位数
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 每条目新建压缩器的固定开销

- **现状**：`add()` → `compressData`（`ZipWriter.cj:500-501`）、`addFileStream`（`:174`）、`openEntry` → `ZipEntryOutputStream`（`ZipEntryOutputStream.cj:60-61`）都为**每个条目**新建 `CompressOutputStream`（`deflateInit` + 8 KB `outBuf`）。打包 1 万个 1 KB 小文件时，deflate 初始化的固定成本与有效压缩工作量同数量级
- **方案**：writer 级持有一个 `ZipWriter` 内复用的压缩器（zlib 层面用 `deflateReset`），每条目只重置状态；或给 `ZipWriterOptions` 增加 `smallEntryThreshold`，低于阈值的条目强制 `Stored`（小文件压缩收益本就接近 0）
- **预期**：小条目占比高的场景减少每条目一次 native 初始化与 8 KB 分配；收益需实测（Amdahl：若 deflate 初始化占总耗时 <5%，不做）
- **代价**：复用压缩器会把「条目级独立」变成共享状态，必须保证异常后能安全重置，否则脏状态跨条目传播；阈值型方案会给归档体积带来可预期的小幅上升
- **验证**：`cjpm bench -O2`，输入 1 万 × 1 KB 与 100 × 1 MB 两组，对照总耗时中位数；`cjprof record` 确认 `deflateInit`/`Deflate.init` 自耗时占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `pump` 每 8 KB 一次切片分配

- **现状**：`pump`（`ZipWriter.cj:509-516`）循环里 `dst.write(chunk[0..n])` 每次生成一个长度 n 的新数组；2 GB 条目 ≈ 26 万次切片 + 26 万次 8 KB 拷贝
- **方案**：`OutputStream.write` 只接受整数组，可改为固定 8 KB 缓冲 + 每次按 `n` 复用（`chunk[0..n]` 无法避免）→ 实际可行的是把 `bufLen` 提到 64 KB（切片次数降到 1/8），或让 `pump` 直接读满 `chunk` 再写（当前已是）
- **预期**：切片次数与单次拷贝开销按 bufLen 线性下降；吞吐提升幅度需实测（大文件场景受磁盘带宽限制，可能 <5%）
- **代价**：64 KB 缓冲 × 并发 writer 的内存占用；对小条目无收益
- **验证**：`cjpm bench -O2`，2 GB 文件写入对照墙钟与 `cjprof` 中 `Array.copyTo` 占比
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 小条目场景下 `deflateInit` 固定开销占比可观 | `f_zip/src/ZipWriter.cj:174`、`:500` | `Deflate.init` 自耗时占比、条目平均大小分布 | `cjprof record` 跑 1 万 × 1 KB 打包，读 self time 排序前 10 |
| 2 | `add()` 内存路径的 2.5× 压缩副本是 GC 压力主源 | `f_zip/src/ZipWriter.cj:496-507` | 每轮分配量、GC 次数、峰值 RSS | 64 MB 条目循环 100 次，采 `getAllocatedHeapSize()` 与 `cjprof heap` |
| 3 | `pump` 的 8 KB 切片复制在 2 GB 条目上可观测 | `f_zip/src/ZipWriter.cj:510-514` | `Array.copyTo` / 分配点占比 | `cjprof record` 写 2 GB 稀疏文件，按函数自耗时排序 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_zip/src/ZipTime_test.cj` | .cj | ✅ | 4 条 DOS 时间用例；边界（1980/2107 钳位、非法日期）未覆盖，见 M6 |
| 2 | `f_zip/src/ZipWriter.cj` | .cj | ✅ | 写入主体；G1–G4、M1、M2 位置 |
| 3 | `f_zip/src/ZipWriterOptions.cj` | .cj | ✅ | 编译期分档与预设；与 `f_base.OS.current` 分档一致，无问题 |
| 4 | `f_zip/src/ZipWriter_test.cj` | .cj | ✅ | 27 条用例；G5、M3、M6 位置 |
| 5 | `f_zip/src/Zip_test.cj` | .cj | ✅ | `zip`/`unzip` 端到端 + `TempSpill_test`；M4、M5 位置 |
| 6 | `f_zip/src/f_zip_test.cj` | .cj | ✅ | 测试骨架（`captureZipError`/`assertZipError`）；无问题 |

合计：`.cj` 6 个 / `.md` 0 个 / 共 6 个，全部读完。本部分无 `.md`，§13 文档一致性由 part1（README）覆盖；`ZipWriter`/`ZipWriterOptions` 的 doc comment 已逐条与实现核对（唯一出入并入 G1）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性与契约 5 条（G1–G5），可读性/重复 4 条（M1、M2、M5、M6），语义一致性 2 条（M4、G2 的 unzip 侧行为）；本部分无网络、无外部字节流解析（写入侧只收调用方给的字符串与数组） |
| §1 死代码 | 0 | 已逐个符号 grep：`ZipWriter` 7 个 private 方法 + 2 个 internal 方法全有调用者；`ZipWriterOptions` 两个 `@When` 版 `defaultMemoryEntryThreshold` 都被 `init` 默认参数使用；测试内 `text`、`FailingInputStream`、`CountingSink`、`FailingOutputStream`、`captureZipError`、`assertZipError` 均有引用；`forServer`/`forLowMemory` 属对外可达 public，只记录「仓内仅测试引用」，不判死代码；无 `return/throw/break/continue` 之后的同层语句；6 个文件的 import 全部用到 |
| §2 重复逻辑 | 3 | M1（前置检查两份）、M2（descriptor 2 处 + LocalHeader 构造 4 处）、M5（同参数失败调用 3 次） |
| §3 空实现 | 1 | G4 的 3 处 `catch (_: Exception) {}`；无空函数体、无 TODO/FIXME |
| §4 栈溢出 | 0 | 本部分唯一的递归在 `Zip.cj`（不在本部分）；`pump`/`compressData`/`names.allocate` 都是单层循环，`EntryNameTable.allocate` 的后缀递增保证终止 |
| §5 OOM | 0 | 内存路径有 `memoryEntryThreshold` 上限且四级临时目录全失败会抛错而非降级（`ZipWriter.cj:88`、`TempSpill.cj:88`）；有界但峰值偏高，归入优化方案 1；`entries`/`names` 与条目数同阶，`close()` 后随 writer 释放，无只增不减的全局容器 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点不成立；两条候选写入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`ZipWriter` 注释明确非线程安全（`ZipWriter.cj:39`） |
| §6.3 并发串行 | 0 | 无 `spawn` 提交任务、无线程池；`spillingObservedDuringSpill` 的 poller 只读一个 `AtomicBool` |
| §6.4 低效算法 | 0 | 无嵌套循环 / 热路径 `contains` / `remove(at: 0)`；`compressData` 的 1.5× 增长是摊还 O(n)；`EntryNameTable.allocate` 的 `while(true)` 由后缀递增收敛 |
| §7 降堆内存方案 | 1 | 优化方案 1（去掉 payload 副本） |
| §8 降 CPU 方案 | 2 | 优化方案 2（复用压缩器）、3（`pump` 切片） |
| §9 local mode 可行性 | 0 | `compressData` 的缓冲区作为返回值逃逸，不满足 local 约束；`pump` 内 8 KB 数组生命周期虽短但没有峰值内存前后对照，收益无法证明 |
| §11 现有代码的 BUG（存量） | 5 | G1–G5；均为工作区快照下的存量（`git diff` 为空，无本次改动） |
| §12 并发安全与锁粒度 | 0 | 类注释声明非线程安全，唯一跨线程可见状态是 `spillingFlag: AtomicBool`（`ZipWriter.cj:50`、`74-78`），测试只跨线程读它；`dirty`/`entryOpen`/`closed` 无线程共享证据；无锁粒度问题可谈 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；写入侧 public 入口（`add`/`addFile`/`addFileStream`/`addDirectory`/`openEntry`/`close`/`position`/`spilling`）均有接口注释与用例（`openEntry` 的用例在 `ZipEntryStream_test.cj`）；模块 README 覆盖由 part1 判定 |
| 文件覆盖（§13 等） | 6/6 | 清单 6 个文件全部读完，无 `.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

写入侧是这套代码里质量偏高的一块：两条写入路径的分工与注释表一致，脏状态把 header / 泵送 / descriptor 三个阶段都包住（且有专门用例），ZIP64 升级判据（`>= 0xFFFF` 的条目数、CD 起点与大小）逐条写清了理由。本部分**没有阻塞项**，5 条一般问题都集中在「边界与失败之后」：`close()` 重试的中间状态没有被记录、条目名没有规范化校验（尾斜杠会静默丢数据）、异常路径跳过压缩器释放和临时文件清理日志、以及一条绑死 POSIX 符号链接权限的用例。

性能侧没有 profile / bench 数据，三条候选（整份压缩副本、每条目压缩器初始化、`pump` 切片）全部落在「待验证假设 / 无基线优化方案」，不构成缺陷。

本部分存量缺陷 11 条（5 一般 + 6 轻微），默认只报不修，是否纳入修复待用户决定。

范围外提示：`EntryNameTable.cj:48` 的 `throw ZipException` 位于 `while (true)` 之后，是不可达语句（死代码）；同文件的 `contains` 仅被测试引用、`size()` 全仓无引用，属 part1–3 范围，未计入本部分统计。
