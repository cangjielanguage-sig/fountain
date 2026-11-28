# f_io 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_io`（全模块 18 个 `.cj` + 8 个 `.md`；**本报告为模块第 2/2 部分**，覆盖 `f_io.part2.txt` 的 6 个 `.cj`：`SegmentedLog_test.cj`、`exception/BytePointerException.cj`、`exception/MMapException.cj`、`exception/SeekException.cj`、`f_io.cj`、`mmap_native.cj`；其余 12 个 `.cj` + 8 个 `.md` 属第 1 部分，本报告的「文件覆盖」「覆盖自检」「模块统计」只统计本部分的 6 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：文件 / 流句柄生命周期、缓冲与刷盘、错误处理、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 2/2 部分）

## 发现

本部分**没有严重级问题**：6 个文件里没有会造成数据损坏、崩溃或同步缺失的生产代码路径。风险集中在「测试给了假信心」与「顶层工具函数的语义缺口」两类，共 7 条一般 + 10 条轻微。

### [一般][存量] `concurrentAppendNoDataLoss` 的两条断言恒真，并发写入完整性实际零覆盖

- **位置**：`f_io/src/SegmentedLog_test.cj:319`（`totalOps` 断言）、`:322-327`（读文件断言）；写线程 `:304-313`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（错误处理缺失 / 失败路径当成功）；§3（契约承诺但检验为空）
- **证据**：静态确定 ——
  1. `totalOps` 是每个线程自己 `count += 1` 的累加（`:309`），与 `log.append` 的返回值、写入位置都无关，`== 400` 只能说明「400 次调用没抛异常」。
  2. 读回断言不成立：`initFileMapping`（`f_io/src/SegmentedLog.cj:731-737`）用 `ftruncate(fd, maxFileSize)` 把段文件预分配到 64 KiB，用例随后 `File(filePath, OpenMode.Read).read(Array<Byte>(6400))` 在任何写入量下都返回 6400。把 `log.append(data)` 整行删掉、或让它永远写到偏移 0，用例仍然通过。
- **描述**：这个用例是仓内唯一覆盖「多线程 append 不丢数据 / 不互相覆盖」的回归网。它既没校验 `LogPosition` 的唯一性（并发下两个线程拿到同一 offset 是核心风险），也没校验文件内容，因此 `appendLock` 双检、`currentSize.fetchAdd` 的正确性一旦回归，CI 依然全绿。结合第 1 部分「刷盘全部是空操作」的结论，这套测试的「绿色」并不能支撑任何持久化承诺。
- **建议**：每线程写不同标记（如 `Array<Byte>(16) { i => UInt8(tid) }`）并按 16 字节边界切分读回，断言每种标记恰好出现 `opsPerThread` 次；同时断言 `append` 返回的 `pos.offset` 集合等于 `{0, 16, …, (totalOps-1)*16}`（排序后逐个比对），并用 `log.logMetas()[0].size == totalOps * data.size` 校验已提交长度。

### [一般][存量] `copyToCType` 把一次 `read` 当作读满：短读即抛假失败，且已消费字节无法重试

- **位置**：`f_io/src/f_io.cj:50-56`
- **来源**：存量
- **判据**：review-checklist §11（错误处理 / 契约与实现不符）；§13（README.md:27-35 承诺「读取 `sizeOf<T>()` 字节」）
- **证据**：静态确定 —— `let len = input.read(buf)` 之后只判断 `len < size` 就 `throw IllegalSizeException`，函数体内没有循环、没有重试。标准库只承诺 `read` 返回「读取的数据的字节数」（`cangjie_runtime/stdlib/doc/libs/std/io/io_package_api/io_package_interfaces.md:13-27`），不保证填满缓冲区；socket、管道、`NonblockingQueueStream`、`SyncByteBuffer` 的短读都是合法行为（第 1 部分已在 `RotatableBuffer` 上确认同一误判）。
- **描述**：从任何可能短读的流上解析定长结构体（报文头、索引项）时，只要底层一次没给满就抛 `IllegalSizeException`，而此时 `input` 的读位置已经被推进了 `len` 字节——调用方既拿不到值，也无法「重试剩下的部分」，只能丢弃整个流。README 写的「读取 `sizeOf<T>()` 字节」与实现不一致。
- **建议**：`var got = 0; while (got < size) { let n = input.read(buf[got..]); if (n <= 0) { throw IllegalSizeException(...) } got += n }`；异常消息里区分「已读到 got / 需要 size / 流已结束」。

### [一般][存量] `pipe` 结束时不 `flush`，缓冲型 `OutputStream` 会丢尾部数据

- **位置**：`f_io/src/f_io.cj:36-41`（`pipe`）；同源缺口在 `:43-48`（`asyncPipe`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）；§13（README.md:12-16「将 `input` 的所有数据通过缓冲区传输到 `output`」）
- **证据**：静态确定 —— 循环退出后直接返回，全函数没有 `output.flush()`，也没有关闭 `output`；`OutputStream.flush()` 的默认实现为空（`io_package_interfaces.md:53-59`），因此任何自带缓冲的实现都必须由写端显式 flush。仓内唯一调用方 `f_process/src/process.cj:141`（`pipe(input: this.stdOutPipe, output: next.stdInPipe)`）正是「EOF 后既不 flush 也不关闭目标流」的形态。
- **描述**：对无缓冲的 `File` 无影响，但对缓冲型输出（或未来加的包装流）会留下未落地的尾段；对子进程 stdin 这类管道，子进程既收不到最后一段也等不到 EOF（`f_process` 的同类问题已在 `docs/review/2026-11-28/f_process.md` 记录，根因一半在本文件）。README 没有说明「不负责关闭目标流」，使用者容易按「pipe 会收尾」理解。
- **建议**：正常退出前 `output.flush()`；异常路径也应在 `finally` 里 flush 已写部分。README 明确写「不关闭 `output`」或增加 `closeOutput!: Bool = false` 参数；若加参数，默认值要与现有调用方兼容。

### [一般][存量] `asyncPipe` 丢弃 `Future`：搬运异常不可观测，且每次调用无界起线程

- **位置**：`f_io/src/f_io.cj:45-48`
- **来源**：存量
- **判据**：review-checklist §12.1（异步语义：`Future` 异常被吞）；§5（有界性：每次调用一个线程）。文档依据：`cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/use_thread.md:3-25`（`spawn` 创建新线程；异常只在 `get()` / `tryGet()` 时抛给调用方），`create_thread.md:3`
- **证据**：静态确定 —— `spawn { pipe<I, O>(...) }` 的返回值既没保存也没 `get()`；`pipe` 内的 `read` / `write` 异常只终止那个线程，调用方拿到的是正常的 `Unit` 返回。
- **描述**：磁盘满、对端关闭、缓冲区被回收等失败全部静默；上层（如 `f_process.piped`）会按「数据已送达」继续。另一方面，`asyncPipe` 每次调用起一个仓颉线程且没有并发上限，在循环里对 N 个管道调用就会起 N 个线程（`f_concurrent` 已有受管线程池，这里没用）。
- **建议**：返回 `Future<Unit>`（或 `Future<Int64>` 已搬字节数），由调用方 `get()` 收异常；若要保留 `Unit` 签名，至少在 spawn 体内 `try { … } catch (e) { 记录到 f_log }`，并在 README 写清「错误不可观测」。

### [一般][存量] `removeCreatedBeforeAndAfter` 把 Linux 的 `st_ctime` 当创建时间，非 Linux 上必然失败

- **位置**：`f_io/src/SegmentedLog_test.cj:566-592`（边界取值 `:575`，两次删除 `:579`、`:586`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）；§10 正确性（平台相关断言）
- **证据**：静态确定 —— `FileInfo.creationTime` 在 Unix 走 `CJ_FS_GetCreationTime` → `stat().st_ctime`（`cangjie_runtime/stdlib/libs/std/fs/native/file_system_unix.c:133-140`），在 Windows 走真创建时间 `CREATION`（`file_system_win.c:182-187`）。用例里段 3 是在 `boundary` **之前**创建、在 `boundary` 之后被 `setLength` 截断封口的，`removeCreatedAfter(boundary)` 之所以能删掉它，靠的是截断刷新了 ctime；用例没有 `@When[os == "Linux"]` 守卫。
- **描述**：两层问题。①测试把 ctime 当「创建时间」并把它写成断言（`:577` 的注释直接写「段 3 封口（时间晚于 boundary）」，把封口时刻当成了创建时刻），真按「创建时间」理解的读者会被误导；②同一断言在 Windows 上（真创建时间）不会删除段 3，`metas.size == 3` 直接失败，而非 Linux 构建是支持的（`SegmentedLog` 有 `@When[os != "Linux"]` 的 `file.write` 回退）。根因在 `SegmentedLog.scanSegments` 使用 `FileInfo.creationTime`（第 1 部分文件），本报告只记测试侧缺陷。
- **建议**：该用例改按 `updateTime`（mtime，语义确定）验证；若要保留创建时间的用例，加 `@When[os == "Linux"]` 并在注释里写明「Linux 上 `creationTime` 即 `st_ctime`」；同时把 `removeCreatedBefore/After` 的公开文档改成「inode 变更时间」，或改用 `statx` 的 btime。

### [一般][存量] 测试共用固定目录且每个用例重复注册 `atExit`，并发 / 重入运行会互删文件

- **位置**：`f_io/src/SegmentedLog_test.cj:29-42`（`testDir()` / `cleanDir()`）；30 个用例开头的 `atExit { cleanDir() }`（如 `:48`、`:81`、`:126`、`:164`，全文共 23 处 `atExit`）；另一套清理 `:745-750`（`durableDir`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态 / 有界性）；§11（资源清理不对称）
- **证据**：静态确定 —— 30 个用例全部硬编码同一个 `/tmp/f_io_test/segmented_log`，每个用例开头 `cleanDir()` 递归删掉该目录下所有文件；23 处 `atExit` 钩子注册后从不注销，进程退出时按注册顺序全部执行（每次都重新 `Directory.walk` 一遍）。
- **描述**：默认串行执行（`@Parallel` 只在 `--parallel` 下生效，`unittest_testmacro_package_macros.md:602-604`）时不会互相踩；但两个 `cjpm test` 进程（并行 CI 分片、同机多任务、开发者本地同时跑两次）会互相删段文件，表现为随机的「文件不存在 / 元数据条数不对」假失败。`durableDir` 另起一套清理逻辑，进一步分散了隔离策略。
- **建议**：目录名带唯一后缀（进程 id 或时间戳 + 随机数），每个用例一个子目录；清理统一到一个 `@BeforeAll` / `@AfterAll`（或 `@BeforeEach`）里做，不要在用例体内注册 `atExit`。

### [一般][存量] `MMapProt.&` 缺 `public`，README 却把它列为公开操作符

- **位置**：`f_io/src/mmap_native.cj:96-98`；对照同 enum 的 `public operator func |`（`:99`、`:102`）与 `public prop value`（`:86`）；文档 `f_io/README.md:311`
- **来源**：存量
- **判据**：review-checklist §13（API 与文档不符）；§10（API 一致性）
- **证据**：静态确定（附一条编译复核建议）—— `&` 没写 `public`，同 enum 的其他成员都显式写了；仓颉成员的缺省可见性是 `internal`（`class.md:370`、`define_struct.md:199`；`enum` 成员缺省可见性语言文档未单列，建议用外部模块一条 `MMapProt.Read & 1` 的编译用例复核）。README 的「操作符」表把它和两个 `public` 的 `|` 并列写成公开 API。
- **描述**：下游按 README 写 `MMapProt.Read & protBits` 会编译失败（`MMapFile.cj:52-53` 是同包调用，所以仓内看不出来）。同时说明这层 API 面本身没被任何外部使用验证过。
- **建议**：补 `public`；若确实只想内部用，就把 README 表格里的 `&` 删掉或标注 internal。

### [轻微][存量] `basicAppendAndRotate` 为读 `.info` 打开了一个不关闭的 `File`

- **位置**：`f_io/src/SegmentedLog_test.cj:108`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称：打开未关）
- **证据**：静态确定 —— `File(filePath, OpenMode.Read).info` 之后没有 `close()`；同文件其余 4 处 `File(...)`（`:112`、`:151`、`:323`、`:916`）都显式关闭，`:460` 则直接用 `FileInfo(path)`。
- **描述**：每个用例泄漏一个文件描述符；`cjpm test` 里影响很小，但这是「同一件事两种写法」的示范，容易被后续用例复制。
- **建议**：改成 `FileInfo(filePath).size`，与 `:460` 保持一致。

### [轻微][存量] `oversizedAppendIsRejected` 的「轮转后」分支从未轮转，与首段重复

- **位置**：`f_io/src/SegmentedLog_test.cj:63-72`（注释在 `:63`）
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）；§14（覆盖缺口）
- **证据**：静态确定 —— 64 字节写入恰好填满 64 字节段（`currentSize + size == maxFileSize`，不满足 `SegmentedLog.cj:286` 的 `>`），随后 65 字节在 `SegmentedLog.cj:281-283` 的 `data.size > maxFileSize` 处直接抛出，**在 `doRotate()` 之前**；真正的轮转只发生在 `:72` 的 1 字节 append 上。因此 `:66` 与 `:54` 命中同一条路径，注释声明的「rotate 不改变上限（R3-C2）」这条场景没有被测到。
- **建议**：在两次超大 append 之间显式 `log.rotate()`（或先写 1 字节触发轮转），再断言超限仍被拒绝，并断言 `logMetas()` 段数已增加。

### [轻微][存量] `readAll` 与 `join` 是同一段「逐字节摊平」逻辑的两次实现

- **位置**：`f_io/src/SegmentedLog_test.cj:405-420`（`readAll`）、`:423-431`（`join`）
- **来源**：存量
- **判据**：review-checklist §2（输入/输出/副作用相同，仅入参类型不同）
- **证据**：静态确定 —— 两者都是 `ArrayList<Byte>` 逐字节 `add` + `Array<Byte>(out.size) { i => out[i] }`，差异只在数据来源（流 vs 数组的数组）。逐字节 `add` 对每个字节装箱，属于同一份实现的两个副本。
- **建议**：抽 `flatten(parts: ArrayList<Array<Byte>>)`，`readAll` 先把块收集成 `ArrayList<Array<Byte>>` 再调它；或者用 `Array.copyTo` 按块搬运，同时消掉装箱。

### [轻微][存量] 模块级 doc 注释指向不存在的 `fountain::f_io.uring` 包

- **位置**：`f_io/src/f_io.cj:18-29`
- **来源**：存量
- **判据**：review-checklist §13 / §14（文档承诺不存在的包）
- **证据**：静态确定 —— `f_io/src` 下没有 `uring` 目录，全仓 `package fountain::f_io.uring` 零命中；io_uring 绑定在独立模块（`f_uring/src/base/uring.cj:16` 为 `package fountain::f_uring.base`）。注释里的 `import fountain::f_io.uring.*` 会直接编译失败。
- **建议**：改成指向 `fountain::f_uring.base` / `fountain::f_uring.lockfree`（若存在），或删除这段注释。

### [轻微][存量] `f_io.cj` 的 `import fountain::f_base.*` 在本文件没有引用

- **位置**：`f_io/src/f_io.cj:33`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 本文件用到的符号只有 `Array`、`sizeOf`、`TypeInfo`、`CPointer`、`acquireArrayRawData` / `releaseArrayRawData`（core）与 `IllegalSizeException`（`f_exception`）；`f_base` 的通配导入没有为任何标识符提供来源。
- **建议**：删除该 import。

### [轻微][存量] `mmap_native.cj` 残留注释掉的 `MAP_FIXED` 与重复的 C 宏注释块

- **位置**：`f_io/src/mmap_native.cj:21-42`（C 宏注释块）、`:55-56`、`:150`、`:158`
- **来源**：存量
- **判据**：review-checklist §1（兼容残留 / 条件编译死分支）
- **证据**：静态确定 —— 取值已在 `:44-64` 用仓颉常量重新定义，注释块是同一批取值的副本（两处维护，改一处不会同步）；`MAP_FIXED` 的整条链（常量 + `MMapFlag.Fixed` 构造器 + `value` 的 match 分支）都被注释掉，不可达。
- **建议**：删掉注释块与死分支；确需 `MAP_FIXED` 时按 `@When` + 真实用例恢复，并把 man page 摘要挪进 `/** */` 文档注释。

### [轻微][存量] README 漏掉 `MMapFlag.isAnonymous` 与 `SeekException` 的构造器

- **位置**：`f_io/src/mmap_native.cj:179-183`（`public prop isAnonymous`）；`f_io/src/exception/SeekException.cj:20-31`；文档 `f_io/README.md:811`、`:813-816`
- **来源**：存量
- **判据**：review-checklist §14（公开 API 未文档化 / 公开 API 文档不完整）
- **证据**：静态确定 —— README 的「其他公开 API」只列了 `MMapFlag` 的 `isPrivate` / `isShared` / `value`，`isAnonymous` 在整个 README 里只出现在 `MMapFile` 的属性表（`:188`）；`SeekException` 只在模块级清单里点名，没有像 `BytePointerException` / `MMapException`（`:352-380`）那样给构造器表。
- **建议**：补 `isAnonymous`；`SeekException` 的四个构造器与另两个异常类同构，复用同一张表即可。

### [轻微][存量] `pipe` 不校验 `bufferSize`：0 时静默不搬运，负数抛的是数组构造异常

- **位置**：`f_io/src/f_io.cj:36-37`
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）；§3（静默无操作）
- **证据**：静态确定 —— `Array<Byte>(bufferSize, repeat: 0)`：`bufferSize == 0` 得到空数组，`input.read(buf)` 返回 0，`while (len > 0)` 立即退出，函数「成功返回」但一个字节都没搬；负数由 `Array` 构造抛异常，类型不是本模块约定的 `IllegalSizeException`。
- **建议**：入口加 `if (bufferSize <= 0) { throw IllegalSizeException(...) }`（模块已 import 该异常），或在 README 写明「0 表示使用默认 4096」。

### [轻微][存量] 时间相关用例靠 1.3 s 睡眠对齐秒级时间戳，套件固定付出约 6.5 s

- **位置**：`f_io/src/SegmentedLog_test.cj:434-436`（`crossSecond`）；调用点 `:574`、`:576`、`:604`、`:606`、`:637`
- **来源**：存量
- **判据**：review-checklist §10（可维护性 / 可测试性）
- **证据**：静态确定 —— `sleep(Duration.second + Duration.millisecond * 300)` 共 5 次调用（`:574`、`:576`、`:604`、`:606`、`:637`），总计约 6.5 s；用例注释自己也写明「`FileInfo` 的时间戳只精确到秒」（`:433`）。这把 `cjpm test` 的时长钉死在 6 s 以上，且仍依赖底层文件系统时间戳精度（`DateTime.ofEpoch(second:...)` 只有秒）。
- **建议**：把这几个「按时间删除」的用例合并成一个，共用一次跨秒等待；或者给 `SegmentedLog` 注入时钟 / 直接构造 `SegmentedMeta` 来测谓词，不依赖真实 mtime/ctime。

### [轻微][存量] `rotationConcurrentNoLeak` 名字承诺泄漏检测，断言里没有任何泄漏指标

- **位置**：`f_io/src/SegmentedLog_test.cj:350-400`
- **来源**：存量
- **判据**：review-checklist §14（能力未接线 / 命名与实现不符）；§11（契约与实现不符）
- **证据**：静态确定 —— 用例只断言 `totalOps > 0`（`:391`）与 `takeOldFiles()` 返回的路径存在（`:395-397`），没有检查文件描述符数、mmap 区域数、`mapped` 标志或内存；轮转期间的 `unmapFile` / `file.close()` 少调一次不会被发现。
- **建议**：Linux 下统计 `/proc/self/fd` 条目数在用例前后的差值（允许常量抖动），或断言 `logMetas().size` 与目录里实际段文件数一致；至少把用例名改成 `rotationConcurrentKeepsOldFiles`，别暗示「无泄漏」。

## 优化可行性方案

> 不是缺陷，是「还能更好」。两条都没有改前基线，按规则只作待验证方案，不进 `tasks`。

### [堆内存] `copyToCType` 每次调用一个中间数组

- **现状**：每次调用分配 `Array<Byte>(sizeOf<T>())`（典型 8–64 B）+ 一次 `acquireArrayRawData` 句柄；对象在函数返回即不可达，但按调用次数产生短命分配（按记录解析时是「每条一次」）。
- **方案**：加 `copyToCType<T>(input: InputStream, buffer: Array<Byte>)` 重载复用调用方缓冲；或直接读进 `ByteBuffer` / `BytePointerStream` 后按端序取值（注意第 1 部分已确认 `ExtendByteBuffer.read<T>` 目前恒返回 0，不能直接复用）。
- **预期**：每次调用少 1 个短命数组 + 1 次 raw-data 获取；峰值收益随调用频次线性，未测。
- **代价**：多一个重载、调用方需持有缓冲并保证 `buffer.size >= sizeOf<T>()`；不加校验会引入新的越界面。
- **验证**：`cjpm bench -O2` 连续解析 100 万条 32 B 记录，对照 `getAllocatedHeapSize()` 与 GC 次数中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `pipe` 的默认 4 KiB 块偏小

- **现状**：默认 `bufferSize = 4096`，每块一次 `read` + 一次 `write`；搬运 N 字节需要 `2 × (N / 4096)` 次流调用（跨 CFFI 的 `File` 实现还要加系统调用开销）。
- **方案**：默认值提到 64 KiB，或按流类型/已知剩余长度自适应；小报文管道保持 4 KiB。
- **预期**：流调用次数降为 1/16；吞吐提升幅度取决于流实现，未测。
- **代价**：单次缓冲占用从 4 KiB 变 64 KiB，对「大量小管道并发」不友好；需要实测确认拐点。
- **验证**：`cjpm bench -O2` 搬运 1 GiB，分别用「文件→文件」与「socket→socket」两种源，比较吞吐中位数与 P99，块大小取 4K/16K/64K/256K 四档。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | durable 模式每条 append 的 `msync + 边界发布`（当前边界发布链路上 `file.flush()` 还是空操作，修好刷盘后会变成真实 syscall）会成为写吞吐上限 | `f_io/src/SegmentedLog_test.cj:956-969`（已有 `SEGMENT_APPEND_COST` 埋点） | 多次采样的中位数与离散度、`-O2` 下的绝对值 | 该用例已打印 `durable=true/false` 的 32×64 B 耗时；连续跑 50 轮取中位数与 P95，再与 `cjprof` 的 self time 对照 |
| 2 | `pipe` 默认 4 KiB 块在大流量下因流调用次数过多成为瓶颈 | `f_io/src/f_io.cj:36-39` | 4K/16K/64K/256K 四档吞吐 | `cjpm bench -O2` 搬运 1 GiB（文件→文件、socket→socket），每档 10 轮取中位数 |
| 3 | `copyToCType` 的「每次调用一个 `sizeOf<T>` 数组」在按记录解析时带来可观 GC 压力 | `f_io/src/f_io.cj:50-56` | 每秒调用次数、分配量与 GC 次数 | 解析 100 万条 32 B 记录，采 `getAllocatedHeapSize()` 增量与 GC 次数；与复用缓冲版本对照 |

## 文件覆盖

> 与 `{workdir}/files/f_io.part2.txt` 一一对应，6 行全在。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_io/src/SegmentedLog_test.cj` | .cj | ✅ | 30 个 `@TestCase`；见一般 #1、#5、#6，轻微 #1、#2、#3、#9、#10；`durable*` 段与 `SegmentBoundary` / `SegmentedLog` 的提交顺序、证据文件、严格读语义逐条核对一致 |
| 2 | `f_io/src/exception/BytePointerException.cj` | .cj | ✅ | 4 个构造器委托 `BaseException`，与 README.md:352-367 的构造器表一致；被 `BytePointerStream.cj:78/83/150` 使用 |
| 3 | `f_io/src/exception/MMapException.cj` | .cj | ✅ | 同上，与 README.md:369-384 一致；被 `MMapFile.cj` 使用 |
| 4 | `f_io/src/exception/SeekException.cj` | .cj | ✅ | 同上；被 `ByteBuffer.cj:92` 使用；README 只有点名、无构造器表（轻微 #7） |
| 5 | `f_io/src/f_io.cj` | .cj | ✅ | `pipe` / `asyncPipe` / `copyToCType`；见一般 #2、#3、#4，轻微 #4、#5、#8 |
| 6 | `f_io/src/mmap_native.cj` | .cj | ✅ | 常量取值与 Linux 头文件逐项核对（PROT_/MAP_/MS_ 均正确）；见一般 #7，轻微 #6、#7 |

合计：`.cj` 6 个 / `.md` 0 个 / 共 6 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 3（一般 #1 测试恒真、#2 短读、#4 未观测异常）；契约/设计 3（一般 #3 `pipe` 收尾、#5 ctime 语义、#7 操作符可见性）；可读性 2（轻微 #2 注释与行为不符、#10 用例名与断言不符）。安全性 0：无外部输入拼串、无凭据、`unsafe` 只用于 `acquireArrayRawData` 且 `finally` 释放 |
| §1 死代码 | 2 | 已逐个 `private` / `internal` / `protected` 符号搜引用：`testDir/cleanDir/readAll/join/crossSecond/durableDir/durableConfig` 均有调用者；`PROT_*`/`MAP_*`/`MS_*` 常量全部被 enum 属性或 `MMapFile` 使用；`mmap/munmap/msync/ftruncate/fallocate` 均被同模块调用；`DEFAULT_MMAP_BYTES` 被 `MMapFile` 默认参数使用。命中：未使用的 `import fountain::f_base.*`（轻微 #5）、注释掉的 `MAP_FIXED` 链（轻微 #6）。信息项（不算问题）：`MMapFlag.isShared` / `isAnonymous`、`MMapProt.|` 两个操作符仓内零引用，但 `MMapFlag`/`MMapProt` 是顶层 `public enum`，按硬原则一对外可达不判死代码 |
| §2 重复逻辑 | 2 | 已把本部分 3 个生产函数（`pipe`/`asyncPipe`/`copyToCType`）+ 8 个测试 helper 压成「输入→输出→副作用」两两比对：`readAll` 与 `join` 同为逐字节摊平（轻微 #3）；`oversizedAppendIsRejected` 的两段超大 append 命中同一路径（轻微 #2）。三个异常类的四个构造器逐一比对后认定为仓颉所需的同构样板（每个类型必须自带构造器），不算重复 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`。`SegmentedLog.durableStep` 的默认空闭包是有意的测试注入点（第 1 部分已认定）；`pipe` 在 `bufferSize == 0` 时的「成功但什么都没做」归入轻微 #8，不单列 |
| §4 栈溢出 | 0 | 本部分无递归函数；`Directory.walk` / `exists` / `remove` 的递归在标准库内，深度由固定测试路径决定 |
| §5 OOM | 0 | `asyncPipe` 的无界起线程已在一般 #4 计（线程资源，不是堆）；测试里的最大分配是 `Array<Byte>(6400)`（6.25 KiB），`Array<Byte>(65)` 等都在 KB 级 |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` / `cjpm bench` 数据。`SEGMENT_APPEND_COST` 只是单次打印、无阈值、`cjpm test` 默认 `-O0`，不足以构成热点结论，已列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 生产代码本部分不含锁；测试里 `concurrentAppendNoDataLoss` / `rotationConcurrentNoLeak` 只是多线程**调用方**，临界区在 `SegmentedLog.appendLock`（第 1 部分已审） |
| §6.3 并发串行 | 0 | `:886-890` 的 `spawn` + 立即 `get()` 是为了让追加发生在另一个线程以验证读视图快照，不是并行加速；`concurrentAppendNoDataLoss` 是 4 个 `spawn` 全部提交后再逐个 `get()`，形态正确 |
| §6.4 低效算法 | 1 | 轻微 #3 的逐字节 `add` 装箱（测试量级 ≤ 200 B，实际影响可忽略，故只记轻微） |
| §7 降堆内存方案 | 1 | `copyToCType` 的每次调用中间数组（无基线，标「待验证」） |
| §8 降 CPU 方案 | 1 | `pipe` 的默认块大小（无基线，标「待验证」） |
| §9 local mode 可行性 | 0 | 候选只有 `copyToCType` 的 `sizeOf<T>` 小数组与测试 helper 的 `ArrayList<Byte>`：前者 ≤ 64 B 且要返回给调用方，后者规模在百字节级；没有峰值内存数据，收益无法证明，判「不划算」，不列方案 |
| §11 现有代码的 BUG（存量） | 17 | 一般 7 条 + 轻微 10 条全部为存量（快照模式无 diff）。本部分读到的 3 个生产函数、30 个用例、4 个 FFI 常量块的边界/空值/异常路径已逐条核对：`pipe` 的 EOF 判断（`len > 0`）正确；`SegmentBoundary` 相关断言（44 B、CRC 位、`bytes[24]` 是 length 首字节）与实现一致；`durable*` 用例的预期与 `SegmentedLog.durableDirectory` / `ChainedSegmentStream` 的严格读语义逐条对得上 |
| §12 并发安全与锁粒度 | 2 | 一般 #4（`asyncPipe` 的 `Future` 异常被吞 + 每次调用起线程，依据 `use_thread.md:3-25`）、一般 #6（测试共享固定目录的无同步清理）。测试内其余并发点（`AtomicBool` 运行标志、4 写线程）已核对：`AtomicBool(true)` 是 `init(val: Bool)`（`sync_package_classes.md:7-20`），语义正确 |
| §14 功能完备性与 README 覆盖 | 3 | 一般 #7（README 承诺的 `&` 操作符不可用）、轻微 #7（`MMapFlag.isAnonymous`、`SeekException` 构造器未进 README）、轻微 #5（模块 doc 指向不存在的 `f_io.uring` 包） |
| 文件覆盖（§13 等） | 6/6 | 无缺失文件；本部分无 `.md` 文件（README 的核对作为第 1 部分文件的一致性引用，不计入本部分文件覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

第 2 部分没有阻塞项，但它决定了第 1 部分那些严重问题**为什么一直没被发现**。

**测试层的「绿色」是假象，这是本部分最值得处理的地方。** `SegmentedLog_test.cj` 有 30 个用例、近千行，覆盖了轮转、编号单调、按序号/时间删除、定位读、durable 提交顺序与失败注入——测试设计本身是认真的。问题出在三条关键断言上：`concurrentAppendNoDataLoss` 读的是被 `ftruncate` 预分配过的文件，`n == 6400` 恒成立（一般 #1）；`removeCreatedBeforeAndAfter` 实际断言的是 Linux 的 `st_ctime`，换个平台就挂（一般 #5）；`rotationConcurrentNoLeak` 从不检查任何泄漏指标（轻微 #10）。也就是说，并发写、按创建时间清理、轮转不泄漏这三块目前都没有真正的回归网。结合第 1 部分「`file.flush()` 是空函数、`msync` 从不被调用」的结论，`durable*` 全套用例验证的只是「边界文件写了什么」，不是「数据到没到盘」——这一点必须在修完刷盘之后补一条「强杀进程再重启仍能读到」的用例才算闭环。

**`f_io.cj` 的三个顶层工具函数是「能用但有语义缺口」。** `copyToCType` 把一次 `read` 当读满，短读即抛假失败并吞掉已消费字节（一般 #2）；`pipe` 收尾不 `flush` 也不说明不关闭目标流，缓冲型输出会丢尾段（一般 #3）；`asyncPipe` 把 `Future` 扔掉，失败不可观测且每次调用起一个线程（一般 #4）。三条都有仓内真实调用方（`f_process`），所以不是纸面问题，而是「按 README 用就会踩」的形态。

**`mmap_native.cj` 的 FFI 常量与文档基本可靠。** PROT_/MAP_/MS_ 的取值与 Linux 头文件逐项一致，`@When[os == "Linux"]` 覆盖到位，没有发现错误的位值或签名。要收拾的是 API 面：`MMapProt.&` 漏了 `public` 而 README 把它写成公开操作符（一般 #7）、`DEFAULT_MMAP_BYTES` 1 GiB 作为默认映射长度（作为设计取舍记在这里，未升级为发现）、以及注释掉的 `MAP_FIXED` 链。三个异常类只是同构样板，与 README 的构造器表一致，无需改动。

存量缺陷共 17 条（一般 7 / 轻微 10），是否纳入修复由用户决定；本轮只给结论与修法，未改任何源码。性能类结论均无测试数据，全部停留在「优化可行性方案」与「待验证假设」，未写成收益结论。

（范围外提示：`MMapFile.cj:44` 的构造器没有 `public`，而 `f_io/README.md:176-177` 把它列为公开构造器——该文件属第 1 部分，未计入本部分统计；`f_process/src/process.cj:40/141` 是 `asyncPipe` / `pipe` 的唯一调用方，一般 #3、#4 的实际影响会经它放大。）
