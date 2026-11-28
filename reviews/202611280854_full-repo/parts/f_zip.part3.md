# f_zip 模块审查报告（第 3/4 部分）

> **模块第 3/4 部分**。本报告只覆盖 `files/f_zip.part3.txt` 的 20 个文件（全部 `.cj`，无 `.md`）：`ReadBufferReuse_test.cj` → `ZipTime.cj`。`Eocd` / `CentralHeader` / `LocalHeader` / `EntryNameTable` / `EntrySource` / `BoundedStream` / `LeBytes` / `ZipWriter*` 属于第 1、2、4 部分，本报告只把它们当调用链证据引用，不计入本部分统计；本部分已由第 2 部分报过的同一根因（`ZipEntryInputStream` 无关闭途径、`LocalHeader.dataOffset` 死写）不重复计数，只在对应条目里注明。

- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（本部分 20 个源文件，0 个 `.md`）
- **基线**：工作区快照（`git status` 只有未跟踪的 `docs/review/` 与 `reviews/`，源码无改动）⇒ 全部问题记「存量」
- **审查重点**：压缩包解析与安全（zip slip / 炸弹）、流式与内存、资源释放、死代码、重复逻辑
- **报告版本**：v1（第 3/4 部分，合并后由主 Agent 另存 `f_zip_v2.md`）

## 发现

### [一般][存量] 解压失败时删掉被覆盖的既有文件——"CRC 错"变成"目标文件消失"

- **位置**：`f_zip/src/Unzip.cj:142-167`（`writeEntryToFile`；`File(target, OpenMode.Write)` 在 `:145` 截断，失败清理 `removeIfExists(target)` 在 `:163`），对外语义见 `Unzip.cj:32`（"同名文件覆盖"）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「资源不对称 / 错误路径」、§10「错误处理」；严重度按「数据丢失」定
- **证据**：静态确定 —— `OpenMode.Write` 先截断目标文件，`ok` 只在 `file.flush()`（`:154`）之后才置真；`finally` 里 `if (!ok) removeIfExists(target)`。CRC / 大小校验发生在 `ZipEntryInputStream.read` 读到最后一块时抛异常（`ZipReader.cj:313-322`），异常沿 `stream.read` → `writeEntryToFile` 传出，`ok` 仍为 `false`。
- **描述**：调用方把 `a.txt` 解压到已有 `a.txt` 的目录，若该条目 CRC 不符 / 被截断 / 超 `maxEntrySize`，结果是：旧 `a.txt` 被截断清零后又被删除。也就是"解压失败"把目标目录里原有的正确文件一起销毁，与"失败不改变现状"的直觉相反。批量解压里一条坏条目就会抹掉上一版产物。
- **建议**：写临时文件（同目录 `.tmp` 后缀）→ 校验通过后 `rename` 覆盖；或至少记录写入前 `exists(target)`，失败清理只在"本次新建"时执行。补用例：目标目录预置 `a.txt`（内容 `old`），用 `RawEntrySpec` 造 CRC 错误的同名条目，断言抛错且 `a.txt` 内容仍为 `old`。

### [一般][存量] `Unzip` 文档的两条原子性承诺与实现不符（部分落盘 / 目标目录先建）

- **位置**：`f_zip/src/Unzip.cj:29-30`（"加密 ZIP 直接报错，**不产生**『解出来一半是对的』的部分结果"）、`Unzip.cj:111`（"校验**先于**任何落盘动作"）；实现 `Unzip.cj:61-79`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」、§13「文档承诺与实现相反」
- **证据**：静态确定 —— `unzipInto` 先 `ensureDirectory(dir)`（`:62`）再逐条 `resolveSafeTarget`（`:69`）/`writeEntryToFile`（`:75`）；`openEntry` 里的加密检查（`ZipReader.cj:203-205`）是**逐条**在循环中做的，之前的条目已经落盘。本模块自己的用例把这一点写成了断言：`Unzip_security_test.cj:78-98`（`validationHappensBeforeWriting`）断言 `good1.txt` / `good2.txt` 在 `../evil.txt` 报错**之后**仍然存在。
- **描述**：两个后果。(1) 一个"普通条目 + 加密条目"的包，解压会先写出普通条目再抛"不支持加密 ZIP"，调用方若按文档理解为"什么都没写"，重试 / 清理逻辑会漏掉这些残留文件；(2) 路径全非法的包，`unzip` 仍会在目标位置留下一个空目录（`unzipInto:62` 早于任何校验），与"校验先于任何落盘动作"字面相反。现有用例 `encryptedEntryNotWritten`（`Unzip_security_test.cj:167-182`）把加密条目放在第一条，恰好绕过了这个场景。
- **建议**：二选一——要么改文档（"逐条目校验；失败时已完成的条目会保留"），要么真做成两阶段（先全量 `resolveSafeTarget` + `checkEntryReadable` 预检，再落盘；`ensureDirectory(dir)` 移到预检之后）。同时补一条"普通条目在前、加密条目在后"的用例锁行为。

### [一般][存量] `ensureDirectory` 的 `exists` → `create` 非原子，并发解压同一目录会抛 `FSException`

- **位置**：`f_zip/src/Unzip.cj:82-86`（`ensureDirectory`），调用点 `:62`、`:71`、`:74`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」；§11「并发正确性」
- **证据**：静态确定 + 文档核对 —— `std.fs.Directory.create` 明确"目录已存在…则抛出异常"（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_classes.md:38`，`recursive: true` 也一样），所以这里必须先 `exists` 再创建；两步之间没有锁也没有 catch。
- **描述**：`unzip` 是自由函数、目标目录由调用方给出，两个线程（或两个进程各自的线程）解压到同一目录时，`!exists(p)` 同时为真 → 第二个 `Directory.create` 抛 `FSException`，整个解压中断（且抛出的不是 `ZipException`，与"唯一异常类型"的承诺再偏一层，后者第 1 部分已报）。同一条竞态也出现在 `target.parent` 的创建（`:74`）与目录条目（`:71`）。
- **建议**：`try { Directory.create(path, recursive: true) } catch (e: FSException) { if (!exists(path)) { throw ZipException(...) } }`，即"建失败后再确认一次是否已存在"，把竞态收敛为幂等。用例：两线程各解压同一包含嵌套目录的包到同一目标，断言两边都成功。

### [一般][存量] `unzip(InputStream, dir)` 全量物化且对归档大小没有任何上限

- **位置**：`f_zip/src/Unzip.cj:34-43`、`f_zip/src/ZipReader.cj:52-56`、`ZipReader.cj:333-342`（`readAllBytes`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §5「一次性物化 / 全量读入」+「有没有拒绝路径」
- **证据**：静态确定 —— `readAllBytes` 用 `ByteBuffer(initialCapacity: 8192)` 循环 `write` 直到 EOF，长度完全由输入决定；`ByteBuffer` 扩容按倍增，峰值可到归档大小的 ~2 倍（旧缓冲 + 新缓冲同时存活）。`ZipLimits` 的四个上限全部作用在**解压后**的字节与条目数上，没有任何一项约束**归档本身**的大小。`unzip(path, dir)` 走 `FileSource`，不受影响。
- **描述**：量化：一个 4 GiB 的网络流交给 `unzip(input, dir)`，最坏峰值 ≈ 8 GiB 堆（倍增期间），且没有任何"太大就拒绝"的入口——只有 OOM 才知道。已知文档在 `ZipReader.cj:49-51` 说明了"先把整个流读进内存"，但 `unzip` 的公开注释（`Unzip.cj:22-33`）没有这条提示，使用者很容易把它当流式接口用。
- **建议**：给 stream 重载加 `maxArchiveSize!`（复用 `ZipLimits` 或独立参数），超限在 `readAllBytes` 里抛 `ZipException`；`ByteBuffer` 侧按已知 `Content-Length` 预分配可省一次翻倍（见"优化可行性方案"）。文档两条重载分别注明"缓冲整包 / 走 seek 不缓冲"。

### [一般][存量] `ZipReader.closed` 是普通字段：`close()` 与并发读之间既无同步也无契约

- **位置**：`f_zip/src/ZipReader.cj:47`（`private var closed = false`）、`:159-164`（`close`）、`:168-172`（`ensureOpen`）；并发承诺在 `:34-35`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」；§11「契约与实现不符」
- **证据**：静态确定 —— 同类里的 `consumed` 用了 `AtomicInt64`（`:46`），`closed` 却是裸 `var`；`close()` 置位后直接 `source.close()`，而 `FileSource.close`（`EntrySource.cj:116-123`）关掉的是**同一个** `File` 对象，`readAt`（`EntrySource.cj:89-110`）正拿它在读。注释只承诺"解析完成后 `entries()` / `read()` / `contains()` 只读，可并发调用"，没有定义 `close` 能否与读并发。
- **描述**：典型用法是"多线程读同一个 reader，收尾时任一线程 `close()`"。此时：(1) `closed` 的写对其他线程不可见（无原子/无同步），`ensureOpen` 可能放行已关闭的 reader；(2) 已放行的线程继续 `source.readAt` / `openRange`，与 `file.close()` 并发，读到已关闭句柄的未定义行为或原生异常。这与第 2 部分 #2（`FileSource.readAt` 共用游标）是同一族问题的**另一个窗口**，不重复计数但需一起修。
- **建议**：`closed` 换 `AtomicBool`（或 `AtomicInt64`），`close()` 用 CAS 保证只有一个线程执行收尾；更彻底的是记录活跃读计数（读入口 +1 / `finally` -1），`close()` 置位后等待归零再关句柄。无论选哪种，都在类注释里写清"`close` 与其它方法并发"的语义。

### [轻微][存量] `zip(output, dir)` 失败时不 `close()` writer，半成品输出无中央目录

- **位置**：`f_zip/src/Zip.cj:35-40`（`let count = addTree(...)` 后直接 `writer.close()`，无 `try/finally`）、`Zip.cj:42-63`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「资源不对称 / 错误路径」；对照 `unzip`（`Unzip.cj:37-41`）的 `try/finally`
- **证据**：静态确定 —— `addTree` 递归展开目录，任一 `Directory.readFrom` / `addFile` 抛错都会跳过 `:38` 的 `writer.close()`；`ZipWriter.close` 是唯一写中央目录 + EOCD 的地方（`ZipWriter.cj:440-449` 附近）。
- **描述**：写盘到一半出错时，`output` 里留下若干 local header + 数据，但没有中央目录，产物完全不可读。`ZipWriter.close()` 对"有条目未关""已 dirty"两种情况会拒绝收尾（`ZipWriter.cj:381-392`），但目录遍历阶段（`Directory.readFrom` 抛错，或 `addFile` 在打开文件前失败）既不置 `entryOpen` 也不置 `dirty`，于是之后任何一次 `close()` 都会写出一份"结构完整但少了若干文件"的包——失败变成静默的成功。`unzip` 侧有 `finally`（`Unzip.cj:37-41`），两个便捷函数不对称。
- **建议**：`try { count = addTree(...) } finally { try { writer.close() } catch (_: Exception) {} }`；只加 `finally` 还不够（上面第二种情况仍会写出半成品），需要让 `zip()` 在遍历失败分支调用包内的 `writer.entryFailed("<tree>")`（`ZipWriter.cj:298` 已是 `internal`）把 writer 置 dirty，使后续 `close()` 抛"ZIP 结构不完整"。用例：目录里放一个不可读文件，断言抛错且再 `close()` 也抛 `ZipException`。

### [轻微][存量] 目录条目在 `read` / `readAll` / `open` 三个 API 上语义不一致

- **位置**：`f_zip/src/ZipReader.cj:89-95`（`read` 不排除目录）、`:98-107`（`readAll` 显式 `!e.isDirectory`）、`:113-122`（`open` 对目录返回 `None`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「语义与命名 / 注释不符」
- **证据**：静态确定 —— 目录条目 `compressedSize == 0`、`crc == 0`，`read` 会走完 `decodeEntry` 得到空数组并 `verifyEntry(0, 0, 0, 0)` 通过，返回 `Some(Array<Byte>())`；`readAll` 直接跳过；`open` 返回 `None`。
- **描述**：同一个名字（如 `"d/"`），`read` 说"存在且内容为空"，`open` 说"没有这条"，`readAll` 说"没有匹配"。调用方用 `read` 判断"目录条目是否可解压"会得到错误结论。
- **建议**：三处统一——建议 `read` 也跳过目录条目（返回 `None`），并在文档里写明"目录条目只有 `entries()` 能看到"。

### [轻微][存量] 条目流校验失败后置 `done`，之后 `read` 静默返回 `-1`

- **位置**：`f_zip/src/ZipReader.cj:309-329`（`done = true` 在 `:315`，两个 `throw` 在 `:317` / `:321`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「错误被吞」、§11「错误处理」
- **证据**：静态确定 —— 首次读到 EOF 时先置 `done = true` 再校验，校验失败抛 `ZipException`；调用方若 `catch` 后继续循环（"记录错误、继续读下一个"的常见写法），下一次 `read` 在 `:310-312` 命中 `done` 直接返回 `-1`，等于把"数据损坏"降级成"正常 EOF"。
- **描述**：与 `decodeEntry`（一次性抛错、无后续状态）行为不同；流式 API 的失败不可重放也不应"变成功"。
- **建议**：失败时记 `failed` 而不是 `done`，`read` 在 `failed` 时重新抛同一个 `ZipException`（或至少返回 `-1` 前不再声称校验通过）。`flush`/`write` 侧已有 `failed` 字段（`ZipEntryOutputStream.cj:45`）可参照。

### [轻微][存量] `ZipEntryOutputStream.write` 在 `failed` 后静默返回，与类注释"此后任何操作都抛异常"不符

- **位置**：`f_zip/src/ZipEntryOutputStream.cj:88-97`（`if (failed) { return }` 在 `:92-94`），注释在 `:28-29`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「静默吞掉」、§11「契约与实现不符」
- **证据**：静态确定 —— 第一次写失败时 `catch` 里置 `failed` 并 rethrow（`:105-109`）；后续 `write` 直接 `return`，既不抛也不计数，`count`/`crc` 也不再更新。
- **描述**：调用方若在 `catch` 之后继续 `write`（例如循环里 catch 后继续下一块），数据被静默丢弃且不会二次报错，最终状态只能靠 `writer` 的 dirty 检查兜底；而类注释承诺"writer 的任何操作都抛异常"，读代码的人会以为 `write` 会抛。
- **建议**：`failed` 分支改为 `throw ZipException("条目 ${name} 上次写入失败，不能继续写入")`，或把注释改成"后续 `write` 静默丢弃"。

### [轻微][存量] `TempSpill.createIn` 四次 `catch { continue }` 丢掉底层失败原因

- **位置**：`f_zip/src/TempSpill.cj:69-89`（`catch (_: Exception) { continue }` 在 `:84`，最终抛错 `:88`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§11「错误处理缺失」
- **证据**：静态确定 —— 逐候选 `try/catch` 只 `continue`，异常对象既不打日志也不带入最终消息；最终 `ZipException` 只有 `size` / `threshold` 两个数，没有"每个候选为什么失败"。
- **描述**：落盘失败在生产上最常见的原因是磁盘满 / 权限 / 目录只读，这三者的处置完全不同；现在的报错无法区分，只能靠猜。`createIn` 的 `logger.debug` 也只在**成功**分支（`:80`）。
- **建议**：catch 里 `logger.warn("zip: 候选临时目录 ${candidate} 不可用：${e.message}")`，或把最后一次异常作为 `cause` 带进最终消息。

### [轻微][存量] 死代码：`wrapMethod` 的 `case _` 兜底不可达（与 `checkEntryReadable` 重复校验）

- **位置**：`f_zip/src/ZipReader.cj:240-246`（`case _ =>` 在 `:244`），守卫在 `:202-208`，两个调用点 `:145-148` 与 `:249-252`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达」、§2「同一校验写两遍」
- **证据**：静态确定 —— `wrapMethod` 是 `private`，全仓只有两个调用点，且两点都紧跟在 `checkEntryReadable(e)` 之后（`openEntry` 在 `:145`，`decodeEntry` 在 `:249`）；`checkEntryReadable` 已经用 `e.method != 0 && e.method != 8` 拒绝了其它方法并抛出**同一句** "不支持压缩方法 ${method}（${name}）"（`:206-208`）。
- **描述**：`:244` 的分支在当前调用链上永远到不了；一旦以后有人新增调用点绕过 `checkEntryReadable`，两条错误路径的文案还会漂移。属于"防御性但结构上死"的代码。
- **建议**：把方法白名单收敛到一处——`checkEntryReadable` 只做读前检查、`wrapMethod` 保留 `match` 而删掉 `checkEntryReadable` 里的方法判断；或反过来让 `wrapMethod` 接受 `UInt16` 时假定已校验（加注释）。`CompressionMethod.fromValue`（`ZipLayout.cj:37-43`）正是为这件事准备的，见下一条。

### [轻微][存量] 死代码：`ZipEntryStream_test.cj` 的 `std.io.OutputStream` import 未使用

- **位置**：`f_zip/src/ZipEntryStream_test.cj:18`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全文件 `OutputStream` 只出现在该 import 行与第 28 行注释里，没有任何类型标注或值使用（`build` 返回 `Array<Byte>`，`ByteBuffer` 来自 `fountain::f_io`）。
- **描述**：无行为影响，只是本轮 §1 机械检查的命中项。
- **建议**：删除该 import。

### [轻微][存量] 重复逻辑：`verifyEntry` 与 `ZipEntryInputStream.read` 各写一份长度 + CRC 校验（连文案都一样）

- **位置**：`f_zip/src/ZipReader.cj:280-287`（`verifyEntry`）与 `:316-322`（`ZipEntryInputStream.read` 的 EOF 分支）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同语义双份实现 + 字面量复制」
- **证据**：静态确定 —— 两处都是"先 `produced != expectedSize` 抛『条目 X 数据不完整：期望 N 字节，实际 M 字节』，再 `crc != expectedCrc` 抛『CRC 校验失败：期望 A，实际 B（X）』"，只有变量名与插值位置不同。
- **描述**：语义差异为零（错误类型、顺序、文案全同），改一处忘另一处就会出现"批量 `read` 与流式 `open` 报不同消息"的漂移。
- **建议**：抽 `private func checkEntryIntegrity(name, produced, actualCrc, expectedSize, expectedCrc): Unit`，`verifyEntry` 直接删掉改调它，`ZipEntryInputStream.read` 复用；错误文案只留一份。

### [轻微][存量] 重复逻辑：`buildZipBytes` / `buildZipWithResult` 同体；`TempSpill` 两处同一异常文案

- **位置**：`f_zip/src/ZipTestSupport_test.cj:92-98` 与 `:101-110`；`f_zip/src/TempSpill.cj:66` 与 `:88`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同文件两两比对 / 字面量复制」
- **证据**：静态确定 —— `buildZipBytes` 的四个动作（建 `ByteBuffer`、建 `ZipWriter`、执行 action、`close` + `bytes()`）是 `buildZipWithResult` 去掉返回值后的真子集；`:100` 的注释解释了"为什么要第二个"（闭包不能捕获可变变量），但没解释为什么不复用。`TempSpill` 的两处 `throw ZipException("无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}")` 逐字节相同，只是触发条件不同（空候选列表 / 全部候选都失败）。
- **描述**：前者的差异只是"有无返回值"，可以 `buildZipBytes(a) = buildZipWithResult(a).0`；后者应保留两处语义（一个是"没有候选"，一个是"都失败"），但文案相同会让人以为两者等价，且改阈值措辞要改两处。
- **建议**：`buildZipBytes` 改为 `buildZipWithResult(action, options: options)[0]`；`TempSpill` 抽一个 `private func noTempFile(size: Int64, threshold: Int64): ZipException`，空候选处改用不同措辞（"没有可用的临时目录"）。

### [轻微][存量] 0/8 白名单散落 4 处，`CompressionMethod.fromValue` 未接入读取路径

- **位置**：`f_zip/src/ZipLayout.cj:22-51`（`value` / `fromValue`）、`f_zip/src/ZipReader.cj:206-208`（`method != 0 && method != 8`）、`ZipReader.cj:241-245`（`case 0 / case 8`）、`f_zip/src/ZipWriter.cj:497`（`method.value == Stored.value`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同一张表散落多处」、§14.1「能力未接入」
- **证据**：静态确定 —— `CompressionMethod.fromValue` 全仓只有 `ZipLayout_test.cj:64-65` 使用；读取侧（`checkEntryReadable`、`wrapMethod`）用的是裸 `UInt16` 字面量 0/8，写入侧用 `options.method.value`。新增一个方法（例如 BZIP2=12）要同时改这 3 处 + 枚举 2 处。
- **描述**：枚举是对外公开 API（`ZipWriterOptions.method`），读取侧却绕过它，形成"写侧有类型、读侧靠字面量"的分裂；`fromValue` 目前是"只给测试用"的公开 API。
- **建议**：`checkEntryReadable` 改 `if (CompressionMethod.fromValue(e.method).isNone()) { throw ... }`，`wrapMethod` 改 `match (CompressionMethod.fromValue(method))`；若暂时不接入，至少把 `fromValue` 的文档改成"预留给读取侧"，避免被当成已有能力。

### [轻微][存量] 注释「ZIP 没有独立的目录标志位」与同模块用 external attributes 判符号链接自相矛盾

- **位置**：`f_zip/src/ZipEntry.cj:26`（"`isDirectory` 由名字是否以 `/` 结尾判断（ZIP 没有独立的目录标志位）"）、对照 `f_zip/src/Unzip.cj:88-91`（`((e.externalAttributes >> 16) & 0xF000) == 0xA000`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §13「文档过期 / 与实现相反」（代码内注释同样算契约）
- **证据**：静态确定 —— 同一模块靠 external attributes 的高 16 位（Unix mode）识别 `S_IFLNK`，`ZipLayout.cj:90-94` 还专门定义了 `VERSION_MADE_BY_UNIX` 与 `EXTERNAL_ATTRIBUTES_DIRECTORY`（`040755 << 16`），说明 mode 位是可用的。
- **描述**：注释把"本实现选择只看名字"说成"ZIP 格式没有这个信息"，会误导后续维护者（例如想做"目录条目不带斜杠也能识别"的兼容时，会以为不可能）。实际差异是"跨平台 mode 不可靠，故意不用"，不是"格式没有"。
- **建议**：改成"目录判定只看名字结尾 `/`，不采信 external attributes 的 Unix mode（Windows 造的包没有可信 mode）；符号链接例外，按 mode 判"。

### [轻微][存量] `openEntry(entry: ZipEntry)` 只按名字在本 reader 内重查，跨包传入会静默读到同名条目

- **位置**：`f_zip/src/ZipReader.cj:124-140`（`findLast(entry.name)` 在 `:133`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：待确认（缺下游用法）—— 静态可见：入参 `ZipEntry` 的 `localHeaderOffset` / `crc32` / `uncompressedSize` 全部被丢弃，只用 `name` 做一次 `findLast`。若调用方把 A 包的 `ZipEntry` 传给 B 包的 reader，得到的是 B 包里**最后一条同名条目**，且不会报错。
- **描述**：注释写"按已取到的 `[ZipEntry]` 打开解压流"，读者会以为用的是那条目的元数据；实际只是按名重查。同一 reader 内的正常用法没问题（`entries()` 出来的名字一定能在本包找到）。
- **建议**：要么在 `ZipEntry` 里加 `reader` 身份（弱引用/句柄）做校验，要么在文档里写明"`entry` 必须来自本 reader；同名条目取中央目录最后一条"。顺带把 `:130-136` 的两段 `isDirectory` 判断合并（入参判一次、查到后再判一次，第一次可省）。

### [轻微][存量] 日志 category 错配：`unzip` 的 warning 记在 `ZipReader` 名下，`zip` 的记在 `ZipWriter` 名下

- **位置**：`f_zip/src/Unzip.cj:57-59`（`UnzipLog.logger = LoggerFactory.getLogger<ZipReader>()`）、`f_zip/src/Zip.cj:22-24`（`getLogger<ZipWriter>()`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「语义与命名不符」；`LoggerFactory.getLogger<O>` 用 `TypeInfo.of<O>().qualifiedName` 作 category（`f_log/src/base/LoggerFactory.cj:44-52`）
- **证据**：静态确定 —— "zip: 跳过符号链接条目 ${e.name}"（`Unzip.cj:66`）与"zip: 跳过符号链接 ${name}"（`Zip.cj:51`）都会落在 `fountain::f_zip.ZipReader` / `.ZipWriter` 这两个与它们无关的 category 下。
- **描述**：按类调日志级别（把 `ZipWriter` 调到 ERROR 以压制写入噪音、保留解压告警）的做法会直接失效；排查"哪个包被跳过"时也会被归到错误的 category。
- **建议**：`getLogger<UnzipLog>` / `getLogger<ZipLog>`（或 `LoggerFactory.getLogger("fountain::f_zip.unzip")`），让 category 与代码单元一致。

### [轻微][存量] 测试稳健性三处：分配量阈值断言、非 Linux 下资源用例恒真、符号链接用例未门控

- **位置**：`f_zip/src/ReadBufferReuse_test.cj:43-51` 与 `:69-77`（`@Expect(alloc < size / 4)`）；`f_zip/src/Resource_test.cj:261-273`（`peakRssKb` 读 `/proc/self/status`，读不到返回 `-1`）+ `:73`、`:117`、`:164`、`:230`（`deltaMb` / `totalMb` 断言）；`f_zip/src/Unzip_security_test.cj:209-230`（`SymbolicLink.create` 在 `:215-216`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「边界 / 空值未处理」+ 测试可信度
- **证据**：静态确定 —— (1) `getAllocatedHeapSize()` / `getGCFreedSize()` 的差值受 GC 时机与运行时版本影响，`size/4` 是写死的经验阈值，`settle()` 只 `gc()` 三次；(2) `peakRssKb` 在非 Linux 返回 `-1`，`before` 与 `after` 都是 `-1` 时 `deltaMb == 0`，`@Assert(deltaMb < 256.0)` 恒真，用例"通过"但什么也没测；(3) `SymbolicLink.create` 在 Windows 需要特权（开发者模式/管理员），没有 `try/catch` 也没有 `skipGated`，非 Linux 环境下会直接失败。
- **描述**：三类问题都让"绿了的用例"骗人：前两类是假通过风险，第三类是跨平台假失败。资源用例另外依赖 `F_ZIP_RESOURCE` 门控（`:253-258`），门控正确但平台判定缺失。
- **建议**：分配量断言改成"同一进程内两种实现对照"（比值而非绝对阈值）或直接降级为打印；`peakRssKb` 返回 `?Int64`，`None` 时 `skipGated("VmHWM 不可用")`；符号链接用例在 `!OS.current.isLinux` 时走 `skipGated`。

### [轻微][存量] `zip` 对非普通文件（FIFO / socket / 设备）静默跳过，只有符号链接有 warning

- **位置**：`f_zip/src/Zip.cj:50-60`（`isSymbolicLink` 有 warning，`isDirectory` / `isRegular` 之外的类型无任何分支）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「静默跳过」、§11「语义与命名不符」（类注释只声明"符号链接一律跳过"）
- **证据**：静态确定 —— `addTree` 的 `if/else if` 链只覆盖符号链接、目录、普通文件；FIFO / socket / 设备文件落到链尾无操作，既不打日志也不计数。
- **描述**：打包一个含 FIFO 的目录（日志管道、`/dev` 镜像、某些构建产物目录）时，`zip` 返回的文件数与目录实际条目数不符，且没有任何提示；调用方无法区分"文件被跳过"和"目录本来就空"。符号链接跳过了反而有 warning（`:51`），两者标准不一致。
- **建议**：`else` 分支补 `ZipLog.logger.warn("zip: 跳过非普通文件 ${name}")`，或加 `options` 开关决定"报错 / 告警 / 静默"。用例：目录里放一个 FIFO（Linux），断言 `zip` 返回 0 且日志含跳过提示。

> 存量 20 条（一般 5 / 轻微 15），是否纳入修复待用户决定。其中 #7（条目流无关闭途径）与 #12 里的 `LocalHeader.dataOffset` 死写已由第 2 部分报告，本报告未重复计数。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分**没有**改前基线数据，全部为 `无基线（待验证）`，不得进 `tasks.md`。

### [堆内存] `ZipReader(input)` 的整包缓冲：去掉倍增峰值与二次拷贝

- **现状**：`readAllBytes`（`ZipReader.cj:333-342`）用 `ByteBuffer(initialCapacity: 8192)` 承接整个归档，扩容按倍增 ⇒ 峰值 ≈ 2 × 归档大小（旧缓冲 + 新缓冲同时存活）；读完再交给 `BufferSource(data)`，`BufferSource` 只持有引用，不再复制（这一点已经做对了）。
- **方案**：`unzip(input)` / `ZipReader(input)` 增加 `maxArchiveSize!` 上限（先解决"能拒绝"），再考虑按 `InputStream` 的已知长度（`File` / `Socket` 可给出）预分配；无法得知长度时按 8 MB 起步、1.5 倍增长（比 2 倍更省峰值）。
- **预期**：4 GiB 归档的峰值从 ~8 GiB 降到 ~4.2 GiB；上限生效后最坏情况是有界失败而非 OOM。
- **代价**：`ByteBuffer` 增长策略若改成 1.5 倍，拷贝次数上升（CPU 略增）；新增参数是对外 API 变更。
- **验证**：同一 1 GiB / 4 GiB 归档，`getAllocatedHeapSize()` 峰值 + `VmHWM`（`Resource_test.cj` 的采集方式）改前改后对照，各跑 5 轮取中位数；同时记录 `ZIP_READAT_BENCH` 之类已有点位的输出。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `entries()` 每次全量重建 `ZipEntry`，可按需缓存

- **现状**：`entries()`（`ZipReader.cj:68-75`）每次调用都按 `rawEntries.size` 新建 `ArrayList<ZipEntry>`，每条 `toZipEntry()` 还会构造 `String`/`DateTime`；65k 条目的包，单次调用就是 65k 个新对象，循环里反复调用（`for (e in reader.entries())` 每次重来）会持续制造垃圾。
- **方案**：首次调用时物化一次不可变快照（`let cached: ?ArrayList<ZipEntry>`），之后返回 `clone()` 或只读视图；语义仍是"返回独立列表"（`entriesReturnsIndependentList` 用例继续成立）。
- **预期**：稳态下每次 `entries()` 的分配从 O(条目数) 降到 O(条目数) 的浅拷贝（`ZipEntry` 是 struct，但 `String` 字段共享）；具体降幅需实测。
- **代价**：多一份 `ZipEntry` 常驻（65k × ~80 B ≈ 5 MB 量级），换来调用期零解码；对一次性使用者是净亏。
- **验证**：`getAllocatedHeapSize()` 差 + 10 万次 `entries()` 的耗时中位数，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `findLast` 线性扫描：`read(name)` / `contains(name)` 是 O(n)

- **现状**：`findLast`（`ZipReader.cj:174-182`）对 `rawEntries` 全表扫描取最后一条；`read` / `contains` / `open` 各调一次。模块内已有 `EntryNameTable`（写侧用的哈希索引），读侧没有接。
- **方案**：构造期建 `HashMap<String, Int64>`（name → 最后一条的下标），`findLast` 退化为一次查表；重复名字的语义不变（后写覆盖）。
- **预期**：单次查找 O(n) → O(1)；对"逐条 `read(name)` 遍历大包"的调用方式收益随条目数线性放大。
- **代价**：常驻一份 name → index 的 map（65k 条 ≈ 数 MB）；`internalEntries()` 若被外部修改会失配（当前只有包内调用，可加注释约束）。
- **验证**：构造 1 万 / 10 万条目的包，跑 1 万次 `read(随机名)`，`cjpm bench -O2` 或分段计时取中位数，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `locateData` 每条目读两次 local header

- **现状**：`locateData`（`ZipReader.cj:222-238`）先 `readAt` 30 字节拿 name/extra 长度（`:223-229`），再用 `readFullyAt` 把 30+name+extra 整段读一遍（`:233`），`readLocalHeader` 只做校验、结果被丢弃（`:235-236`）。每打开/解码一个条目就是 2 次随机读。
- **方案**：一次读满（先读 30 字节，若 `nameLen+extraLen` 超过缓冲再补读剩余部分），把 `readLocalHeader` 的解析结果复用起来做数据起点；或在 `ZipReader` 构造期把每个条目的 data offset 预算并缓存（中央目录已全量在手）。
- **预期**：随机读次数减半；小条目（header 占比高）场景收益最大。绝对值需实测。
- **代价**：预算缓存需要 65k × 8 B ≈ 0.5 MB 常驻；`readLocalHeader` 的 ZIP64 extra 自洽性校验不能丢。
- **验证**：1 万个小条目的包，`unzip` 端到端耗时 + `readAt` 调用次数（分段计时），改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `findLast` 线性扫描是批量 `read(name)` 的主要开销 | `f_zip/src/ZipReader.cj:174-182` | 单次查找自耗时占比 | `cjprof record` 跑 10 万条目的包 + 1 万次 `read(随机名)`，看 `findLast` self time |
| 2 | `locateData` 双读 local header 在"多小条目"场景是热点 | `ZipReader.cj:222-238` | 每条目平均随机读耗时 | 1 万 × 1 KB 条目的包，`unzip` 前后分段计时 + I/O 计数 |
| 3 | `entries()` 反复调用造成 GC 压力 | `ZipReader.cj:68-75` | 分配速率与 GC 次数 | 循环 1 万次 `entries()`，采 `getAllocatedHeapSize()` 与 GC 次数 |
| 4 | Windows 下 `".. "`（尾随空格）/ 尾随点可绕过 `resolveSafeTarget` 的前缀校验 | `f_zip/src/Unzip.cj:113-136` | Windows 上 `Path.normalize` 与 `File` 打开时是否裁掉尾随空格/点 | 在 Windows 上解压含 `".. /evil.txt"` 条目的包，检查 `<base>/../evil.txt` 是否被创建 |
| 5 | 目标目录里**预置**的符号链接可让 `resolveSafeTarget` 前缀校验失效（`normalize` 只做字符串解析，不解析链接） | `Unzip.cj:129-135`；`Path.normalize` 文档：`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1734`"仅做字符串解析，不会进行 io 操作" | 是否把"目标目录含符号链接"纳入威胁模型 | 预置 `dir/link -> /tmp/out`，解压 `link/x.txt`，检查是否写到了 `/tmp/out/x.txt` |
| 6 | `ensureDirectory` 的竞态在并发解压时真会触发（而非仅理论） | `Unzip.cj:82-86` | 双线程同目标目录解压的失败率 | 两线程 × 1000 轮解压同一包到同一目录，统计 `FSException` 次数 |
| 7 | `ReadBufferReuse_test` 的 `alloc < size/4` 在不同运行时/负载下是否稳定 | `ReadBufferReuse_test.cj:51`、`:77` | 多轮 CI 的实际 `alloc` 分布 | 连续 20 轮跑该用例，记录 `ZIP_READAT_BENCH` / `ZIP_BOUNDED_BENCH` 输出的离散程度 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_zip/src/ReadBufferReuse_test.cj` | .cj | ✅ | 见"测试稳健性"条目 |
| 2 | `f_zip/src/Resource_test.cj` | .cj | ✅ | 同上（`peakRssKb` 非 Linux 恒真） |
| 3 | `f_zip/src/TempSpill.cj` | .cj | ✅ | 见 #10、#14 |
| 4 | `f_zip/src/Unzip.cj` | .cj | ✅ | 见 #1、#2、#3、#16、#18 |
| 5 | `f_zip/src/Unzip_security_test.cj` | .cj | ✅ | 见 #2 的行为证据、#19 |
| 6 | `f_zip/src/Zip.cj` | .cj | ✅ | 见 #6、#18、#20 |
| 7 | `f_zip/src/Zip64BigEntry_test.cj` | .cj | ✅ | 慢用例门控（`F_ZIP_SLOW`）正确；流未 close 属第 2 部分 #7 同根因 |
| 8 | `f_zip/src/Zip64EntryCount_test.cj` | .cj | ✅ | 门控 + 外部工具缺失走 `skipMissingTool`，与其它用例一致 |
| 9 | `f_zip/src/ZipEntry.cj` | .cj | ✅ | 见 #16 |
| 10 | `f_zip/src/ZipEntryOutputStream.cj` | .cj | ✅ | 见 #9 |
| 11 | `f_zip/src/ZipEntryStream_test.cj` | .cj | ✅ | 见 #12（未使用 import） |
| 12 | `f_zip/src/ZipException.cj` | .cj | ✅ | 异常类型本身无问题；"唯一异常类型"承诺不成立已由第 1 部分报告 |
| 13 | `f_zip/src/ZipLayout.cj` | .cj | ✅ | 见 #15；27 个常量逐个 grep，均 ≥ 1 处非定义引用 |
| 14 | `f_zip/src/ZipLayout_test.cj` | .cj | ✅ | 常量/签名逐项有断言，无问题 |
| 15 | `f_zip/src/ZipLimits.cj` | .cj | ✅ | 仅数据载体，无逻辑；默认值文档与实现一致 |
| 16 | `f_zip/src/ZipReader.cj` | .cj | ✅ | 见 #1、#4、#5、#7、#8、#11、#13、#15、#17 |
| 17 | `f_zip/src/ZipReader_path_test.cj` | .cj | ✅ | 两构造对照 + 独立句柄并发，覆盖到 `FileSource` 正常路径 |
| 18 | `f_zip/src/ZipReader_test.cj` | .cj | ✅ | 覆盖限流/关闭/并发交错；`drain` 为包内共享 helper |
| 19 | `f_zip/src/ZipTestSupport_test.cj` | .cj | ✅ | 见 #14；其余 helper 逐个 grep，均有调用者 |
| 20 | `f_zip/src/ZipTime.cj` | .cj | ✅ | 编解码边界（年 <1980 截断、非法月日为 `None`）与注释一致 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | #1 数据丢失、#2 契约、#3 竞态、#7 语义分裂、#8 错误降级、#9 静默丢弃、#17 跨包误读、#18 日志错配、#19 测试可信度 |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` / 非可达 `public` 搜引用：`isSymbolicLinkEntry`、`resolveSafeTarget`、`readAllBytes`、`account`、`encodeDos*`、`decodeDosDateTime`、`TempSpill` 四个 `public static`、`peakRssKb`、`RepeatingBlockInputStream`、13 个测试 helper 均有调用者（`internal class TempSpill` 的成员按硬原则二全项目搜过，`createIn` 仅测试 + 自身、`candidates`/`fallbackDirectory` 内部使用，均非零引用）；20 个文件的 `import` 逐条核对，仅 `ZipEntryStream_test.cj:18` 未使用；`return`/`throw` 后同层语句逐处看过，另命中 `wrapMethod` 的不可达 `case _`。`ZipLayout` 27 个常量全部有引用。第 2 部分已报的 `LocalHeader.dataOffset` 死写不重复计 |
| §2 重复逻辑 | 3 | 同文件两两比对 20 个文件的函数体：命中 `verifyEntry` vs `ZipEntryInputStream.read`（同语义同文案）、`buildZipBytes` vs `buildZipWithResult`（真子集）、`TempSpill` 两处同文案；跨文件搜相同错误文案另查到 `条目路径非法`（`Unzip.cj:115/119/122/126/133`）5 处，属"为可读性刻意展开"的误报边界，未计 |
| §3 空实现 | 3 | 无空函数体、无 `TODO`/`FIXME`、无 `UnsupportedException`；命中三处静默：`TempSpill` 的 `catch { continue }`（#10）、`ZipEntryOutputStream.write` 的 `if (failed) return`（#9）、`addTree` 对非常规文件无分支（#20） |
| §4 栈溢出 | 0 | 唯一递归是 `Zip.addTree`（`Zip.cj:42-63`），深度 = 目录深度且 `info.isSymbolicLink()` 在递归前就跳过（`Zip.cj:50-53`），不存在环；深度上界受路径长度限制（Windows 260 / Linux 4096 字符量级），未构成可达的爆栈路径。`readLinkTarget`/`ensureDirectory` 均非递归 |
| §5 OOM | 1 | #4（`unzip(InputStream)` 全量物化 + 无归档上限）。`decodeEntry` 的 `ByteBuffer` 有 `maxEntrySize` 兜底（`account` 按实际字节记账），`readAll` 是"显式要求全部同名条目"的语义，均未计 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，`findLast`、`locateData` 双读、`entries()` 重建全部降级为"待验证假设" #1-#3，不进统计 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`ZipReader` 只用 `AtomicInt64` 记账（`ZipReader.cj:46`） |
| §6.3 并发串行 | 0 | 无 `spawn` / 无批处理 / 无线程池，不适用 |
| §6.4 低效算法 | 0 | `findLast` 的 O(n) 与 `locateData` 的二次读都是"没有测量数据"的线索，已入待验证假设，未计为缺陷 |
| §7 降堆内存方案 | 2 | "整包缓冲峰值"、"`entries()` 重建"两条，均标 `无基线` |
| §8 降 CPU 方案 | 2 | "`findLast` 哈希索引"、"`locateData` 单次读"两条，均标 `无基线` |
| §9 local mode 可行性 | 0 | 本部分的热点候选（`decodeEntry` 的 8 KB chunk、`writeEntryToFile` 的 8 KB 缓冲、`entries()` 的 `ZipEntry` 列表）都要么逃逸（作为返回值/成员），要么是 `Array` 无法直接标注；且无峰值内存前后对照，按铁律只能停在"待验证假设"，本轮不单列 |
| §11 现有代码的 BUG（存量） | 7 | #1、#3、#7、#8、#9、#17、#20；`ZipTime` 的 DOS 编解码边界（年 <1980 截断、非法月/日返回 `None`、秒 60-62 由 `DateTime.of` 抛错兜底）逐条核对，无缺陷 |
| §12 并发安全与锁粒度 | 2 | #3（`exists`→`create`）、#5（`closed` 裸 `var` + `close` 与读并发）；无锁粒度问题可谈（本部分没有锁） |
| §14 功能完备性与 README 覆盖 | 1 | #15（`CompressionMethod.fromValue` 未接入读取侧，属"能力未接线"）；README 不在本部分文件清单内，`.md` 覆盖由第 1 部分负责 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 文档一致性在其余部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 15 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分代码的整体质量偏好：`unzip` 的 zip-slip 校验（绝对路径 / 盘符 / `..` 段 / 规范化前缀四道）思路完整且有对照用例，炸弹防护按"实际解压字节"记账而不是信 header，`ZipEntryOutputStream` 的 dirty 状态与幂等 `close` 设计清楚，测试分层（慢用例 / 资源用例 / 外部工具）也有门控。

阻塞项不在"能不能解压"，而在**失败路径的副作用**：`writeEntryToFile` 在失败时删除目标文件（#1）是唯一会造成数据丢失的问题，应优先修；紧随其后的是 `ensureDirectory` 的 TOCTOU（#3）与 `ZipReader.closed` 的裸字段（#5）——两者都只在并发下暴露，但只要 f_zip 被放进服务端并发路径就会命中，属"先安全后粒度"里必须先处理的安全项。#2 是文档高估了原子性（含本模块自己的用例已经把"部分落盘"写成断言），改文档或改实现都行，但不能两者都不动。`unzip(InputStream)` 无归档上限（#4）是设计选择，补一个上限参数即可把它从"OOM 面"降级为"有界失败"。

轻微项以契约细节为主（目录条目三 API 语义、错误降级、静默丢弃、日志 category、注释与实现相反），可排期批量修；死代码与重复逻辑各 2-3 处，量很小。性能侧本轮没有 profile，`findLast` 的 O(n)、`locateData` 的双读都只作为待验证假设登记，等下一轮补 `cjprof` 数据再决定是否动结构。
