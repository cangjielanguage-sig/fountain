# f_protocol 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_protocol`（全模块 15 个 `.cj` + 9 个 `.md`；**本报告为模块第 2/2 部分**，只覆盖 `files/f_protocol.part2.txt` 的 4 个 `.cj`：`truncated_message_test.cj` 与 `exception/` 下三个文件；其余 11 个 `.cj` + 9 个 `.md` 见第 1 部分报告）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff 可比，所有问题来源一律记「存量」，blame 只用于给提交依据）
- **审查重点**：帧编解码边界与安全、长度字段、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1（第 2/2 部分）

## 发现

本部分只有两类文件：**帧截断/长度边界的回归测试**（`truncated_message_test.cj`，20 个 `@TestCase`）与**两个异常类型 + 一个 import 汇总文件**。异常类型本身没有任何逻辑（4 个构造器全部直转 `f_base.BaseException`，与 `f_exception` 模块公开的模板逐字一致），未发现缺陷；问题全部落在测试文件上：**最核心的一条是「只断言抛了异常」无法区分协议错误与干净关闭**，其余三条是测试基建的隐式上限、池项未归还与不可达分支。

### [一般][存量] 截断/版本用例只断言「抛了任意异常」，无法区分 `CodecException` 与 `InputClosedException`，文件头承诺的「中途 EOF 不是干净关闭」没有被任何用例锁定

- **位置**：`f_protocol/src/default/truncated_message_test.cj:83-93`（`decodeThrows`，`catch (_: Exception) { true }` 在 `:90`）；被 `:170`、`:195`、`:203-204`、`:213`、`:220`、`:227`、`:234`、`:243`、`:257`、`:265`、`:273`、`:281`、`:304` 使用
- **来源**：存量（blame：文件由 `fb69eede1` 2026-10-03「半条消息必须在接收侧被识别为"不完整"」新增，`decodeThrows` 自引入起未改；快照无基线）
- **判据**：review-checklist §11（契约与实现不符 / 边界校验缺失）、§14（用例覆盖不足）；承诺源为同文件 `:26-30` 与 `:194`
- **证据**：静态确定 —— `Message.decode` 用**两种不同异常**表达两种语义：首字节读不到 → `InputClosedException`（`Message.cj:287-289`），帧中途 EOF / CRC 缺失 / 长度不符 → `CodecException`（`Message.cj:78`、`:123`、`:308`、`:312`、`:317`）。文件头 `:28-30` 明确要求「帧中途 EOF、`len` 与实际不符、CRC 不符 ⇒ 必须抛，绝不返回半条」，`:194` 的注释还专门写了「且不能是"干净关闭"」。但 `decodeThrows` 把 `Exception` 全吞了，只返回 `true`/`false`，不区分类型、也不看 `message`。
- **描述**：11 个「必须抛」用例（`:195`、`:203-204`、`:213`、`:220`、`:227`、`:234`、`:243`、`:257`、`:265`、`:273`、`:281`）没有一条会因为异常类型变了而失败。`Message.decode` 的「零字节输入」异常类型本身就变过一次（`c51cf61bc` 把 `IllegalArgumentException` 改成 `InputClosedException`，`Message.cj:288`）——这两种类型都能通过 `decodeThrows` 的判定；同理，若把 `readFully` 的「读了一半再 EOF」也归成干净关闭，`truncatedHeaderMustThrow`/`partiallyReceivedHeaderMustThrow` 会抛 `InputClosedException` 而不是 `CodecException`，用例照样通过。`unknownFrameVersionMustThrow` 的注释写明「不能是'干净关闭'」，但断言对此毫无约束。而 `f_net` 对这两类异常的处理是**分开的**：`InputClosedException` 记 DEBUG、当作正常收尾并 `break`（`f_net/src/server/server.cj:143-151`，注释即「对端干净关闭」），其余异常才 `log.warn('error occurred on decoding', e)` 并断链（`:152-158`）。所以分类一旦漂移，协议错误会被静默降级成「对端正常关闭」——没有 WARN、没有错误计数。反向同理：任意无关异常（如 `IllegalArgumentException`、池耗尽）也会让这些「必须抛」的用例变绿，把真正的失败原因藏起来。同模块的 `Protocol_test.cj:486-496`（`messageDecodeEmptyStreamThrows`）已经示范了正确写法：只捕获 `InputClosedException`，其他异常直接冒出去让用例失败。
- **建议**：把 helper 改成断言异常类型并保留原始失败：`private func decodeThrowsCodec(all, keep): Bool` 内 `catch (e: CodecException) { true } catch (_: Exception) { false }`；「版本不符」再单独断言 `e.message` 含 `unsupported frame version`；`completeMessageStillDecodes`/`frameSurvivesDribbledReads` 保持「不抛」的断言。若想保留「任意异常都算截断」的宽口径，至少另加一条用例锁定「半头/半体 ⇒ 必须是 `CodecException`，不是 `InputClosedException`」。

### [轻微][存量] 两处 `match` 的 `case _ => []` 不可达

- **位置**：`f_protocol/src/default/truncated_message_test.cj:139-143`（死分支在 `:142`）、`:156-160`（死分支在 `:159`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §1（`match` 里被前面 case 完全覆盖的 case）
- **证据**：静态确定 —— 待匹配值来自 `decoded.tryFromData<Array<String>>()`，静态类型是 `?Array<String>`（`Message.cj:151` 的返回类型 `?T`）。`Option` 只有 `Some`/`None` 两个构造器（仓颉文档 `enum_and_pattern_match/option_type.md` 开头定义），而前两个类型模式 `Array<String>` 与 `?Array<String>` 已覆盖全部取值：`Some` 由第一个或第二个接住，`None` 由第二个（`?Array<String>` 是 `Option<Array<String>>` 自身）接住，第三个分支没有值可落。
- **描述**：这是死分支，且会误导读者以为「转换失败会静默返回空数组」——实际上转换失败时 `x ?? []` 走的是第二分支，第三分支永不可达；`[]` 兜底一旦被误读成「容错」，后续新增断言会以为失败路径已被覆盖。
- **建议**：删除 `case _`；更直接的写法是 `let got = decoded.tryFromData<Array<String>>() ?? []`，或用 `match (opt) { case Some(x) => x; case None => [] }` 显式表达 `Option` 的两个构造器。

### [轻微][存量] `dataFieldSize` 编码后未 `release()`，每次调用永久丢一个 8 KB 池项（与第 1 部分一般 #1 同一类错误）

- **位置**：`f_protocol/src/default/truncated_message_test.cj:99-101`（`DefaultCodec().encode(data).finish().byteSize() ?? -1`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §11（资源释放不对称）、§10（契约与实现不符）
- **证据**：静态确定 —— `DefaultCodec.encode(data)` 在第一次编码时就经 `lastBuffer()` 从池借一个 8 KB 缓冲并加入 `inputs`（`f_codec/src/default/DefaultCodec.cj:124-149`，`:139` 的 `inputs.add(buf)`）；`finish()` 只是把 `inputs` 包成 `ChainedBytesCopyTo`（`:713-715`），**不归还**；唯一归还路径是 `release()`（`:720-726`），其 KDoc 写明「调用方若只做 decode，或不打算把编码结果写出，也必须调用本方法」。`f_pool/src/BytesListOutputStream.cj:211-219` 的 `release()` 是显式且幂等的，全文件没有析构函数兜底（`~init` 只在 `f_pool/src/Ref.cj:24` 出现）。`byteSize()` 只读长度，之后对象被丢弃，池项再也回不去。
- **描述**：本文件共 3 次调用（`eofAtDataFieldMustThrow` 1 次 + `frameWithDataField` 在 `splicedDataFieldStillDecodes`/`oversizedValueLengthIsRejectedBeforeAllocating` 中各 1 次），泄漏 3 × 8 KB，测试进程内可忽略；但这是「量一下编码长度」这种最自然的用法踩中的坑，与第 1 部分一般 #1（`Message.encode()` 异常路径不归还）同源，说明 `DefaultCodec` 的所有权契约缺少一个安全的便捷封装。
- **建议**：`let codec = DefaultCodec(); try { codec.encode(data).finish().byteSize() ?? -1 } finally { codec.release() }`；或抽一个 `private func encodedSize(data: Data): Int64` 并注释「内部必须 release，否则每次泄漏一个池项」。更彻底的做法（属 f_codec）是让 `finish()` 之后的对象在 GC/作用域结束时归还，或提供 `bytes.byteSize()` 后自动回收的 API。

### [轻微][存量] `wireOf` 用固定 1 MiB 缓冲单次读取，超过 1 MiB 的帧会被静默截断

- **位置**：`f_protocol/src/default/truncated_message_test.cj:74-81`（`Array<Byte>(1 << 20, repeat: 0)` 在 `:78`，`buf.read(all)` 在 `:79`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §11（边界未校验 / 隐式上限）、§14（测试基建可维护性）
- **证据**：静态确定 —— `ByteBuffer.read(buffer)` 单次读取最多填满 `buffer`（与 `Message.readFully` 的 `let n = input.read(tmp)`、`tmp.size = 剩余` 用法一致，`Message.cj:72-73`），因此 `n <= 1 MiB`；`all[0..n]` 静默丢弃第 1 MiB 之后的字节，没有任何断言或注释提示这个上限。当前用例最大 9000 B（`:226`、`:298`），未触发。
- **描述**：模块自身允许最大 1 GB 的帧（`Message.cj:29`、`ProtocolConfig` 默认 `1 << 30`），而测试 helper 有一个未声明的 1 MiB 上限。一旦有人新增 2 MB 帧的用例，`wireOf` 返回的是**被截断的真帧**：在「必须抛」的用例里会因为截断而通过（假绿），在往返用例里则报一个与真实原因无关的 `len` 断言失败，排查成本很高。
- **建议**：按 `EncodedMessage` 的 `byteSize()` 精确分配（或循环 `read` 直到返回 0）；若刻意限制测试帧大小，就写成 `private const TEST_FRAME_LIMIT = 1 << 20`，超过时 `@Assert`/抛错而不是静默切片。

> **合并提示（不计入本部分缺陷数）**：README 的「其他公开 API」清单（`f_protocol/README.md:216` / `README_en.md:220`）还漏了 `InputClosedException`（`f_protocol/src/exception/InputClosedException.cj:18`；下游必须写 `import fountain::f_protocol.exception.InputClosedException`，见 `f_net/src/server/server.cj:27`），且 `CommandException`/`InputClosedException` 两个类都没有任何 KDoc 说明抛出条件。这与第 1 部分「一般 #8：README 公开 API 清单失真」同根因，合并时并入该条，不另计。

## 优化可行性方案

本部分只有测试代码与两个空壳异常类型，没有可量化的堆内存 / CPU 改造对象：

- 堆内存：测试期的 1 MiB `wireOf` 缓冲与 8 KB 池项泄漏都属于测试进程内的一次性开销，不构成可写进 `tasks` 的优化方案（池项泄漏已作为缺陷单列）。
- CPU：没有 profile / bench 数据，异常构造是否成为断链路径热点只能进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次正常断链都 `new InputClosedException`，而 `BaseException` 给每个实例分配一个 `ArrayList<Exception>`（`f_base/src/BaseException.cj:45`）；高连接 churn 的服务端（`f_net/src/server/server.cj:143` 每条连接关闭走一次）里，异常构造 + 栈回溯可能占关闭路径的可观比例 | `f_protocol/src/exception/InputClosedException.cj:18`、`Message.cj:288`、`f_net/src/server/server.cj:143` | 每次断链的分配字节数、`InputClosedException` 构造的自耗时占比 | `cjprof` 跑 10k 次 connect/close（同机、`-O2`、固定并发），对照「复用单例异常（不可变、不加 suppressed）」与现实现的 ns/次、alloc/次；注意单例异常会丢栈信息，需同时评估可诊断性 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_protocol/src/default/truncated_message_test.cj` | .cj | ✅ | 20 个 `@TestCase`；见一般 #1、轻微 #1~#3；`:144` 的 `println` 与仓内既有测试风格一致（`Protocol_test.cj:339-341` 也打印），不单列问题 |
| 2 | `f_protocol/src/exception/CommandException.cj` | .cj | ✅ | 4 个公开构造器全部直转 `BaseException`；仓内被 `constants.cj:70`（`QoS.parse` 非法位）与 `:221`（`Command.parse` 兜底，后者不可达见第 1 部分）使用；README 覆盖见「合并提示」 |
| 3 | `f_protocol/src/exception/InputClosedException.cj` | .cj | ✅ | 同上；由 `Message.cj:288` 抛出、`f_net` 捕获；README 清单遗漏见「合并提示」 |
| 4 | `f_protocol/src/exception/imports.cj` | .cj | ✅ | 仅 `internal import fountain::f_base.BaseException`，被同包两个异常类使用（包级 import 生效），非死 import |

合计：`.cj` 4 个 / `.md` 0 个 / 共 4 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性 1（一般 #1：用例断言弱于文档契约）；设计 0（异常类型与 `f_exception` 模板一致，不引入新抽象）；语言特性 0（`?T`/`match` 用法本身正确，问题在分支覆盖）；可读性 0（命名 `DribbleInputStream`/`CollectOutputStream` 与用途相符）；安全性 0（测试不开外部端口、不读真实凭据、不落盘） |
| §1 死代码 | 1 | 逐一核过：`DribbleInputStream`（data/pos/step/read）、`CollectOutputStream`（list/write/bytes）与 9 个私有 helper（`wireOf`/`decodeThrows`/`payload`/`dataFieldSize`/`lenOf`/`crcOf`/`reframe`/`stringField`/`frameWithDataField`）全部有调用者；4 条 import 均被使用；`CommandException`/`InputClosedException` 是 public 顶层类（对外可达，按硬原则一不判），其 `init()`/`init(caused:)` 仓内零引用只作信息；`internal import BaseException` 被两个类使用。命中 1：两处 `case _ => []` 不可达（轻微 #1） |
| §2 重复逻辑 | 0 | 逐行比对了两个异常类：4 个构造器完全相同，但差异是**类型身份本身**（`f_net` 按 `InputClosedException` 捕获），合并成基类不会减少代码且会改变公开继承链；且该 4 构造器模板是 `f_exception/README.md:5-14` 明示的全项目约定，不判重复。测试侧把 `reframe`/`stringField`/`frameWithDataField` 压成「输入→输出」比对：三者共享的只是 4~8 行大端写字节，用途分别是「改帧」「拼字段」「拼整帧」，边界与输入不同，抽 helper 收益低于误用风险，不判重复；`wireOf` 相比 `Protocol_test.cj` 里 15 处内联样板是收敛而非复制 |
| §3 空实现 | 0 | 全部函数体有实现；`public init() {}` 是异常类的空体构造器（隐式 `super()`），无契约承诺，不属空实现；无 `TODO`/`FIXME`/`throw UnsupportedException`；无 `catch {}` 静默吞异常（`decodeThrows` 的 catch 有返回语义，已作为一般 #1 单列） |
| §4 栈溢出 | 0 | 本部分无递归（`Message.decode` 的集合递归在 f_codec，第 1 部分已作范围外提示）；`DribbleInputStream`/`CollectOutputStream` 都是线性循环，循环次数由数组长度界定 |
| §5 OOM | 0 | 测试侧缓冲有界（`wireOf` 1 MiB、`payload` ≤ 9000 B、`stringField` 9+B）；没有按不可信长度分配；`oversizedValueLengthIsRejectedBeforeAllocating` 正是验证「1 TB 声明在分配前被拒」，不构成 OOM 面。生产侧 1 GB 上限问题属第 1 部分一般 #3 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；唯一候选（每条断链构造异常）因缺自耗时占比，按铁律进「待验证假设 #1」，未计入发现 |
| §6.2 大粒度锁 | 0 | 本部分没有锁、没有 `synchronized` |
| §6.3 并发串行 | 0 | 没有 `spawn`/`Future`/线程池；测试类由 unittest 框架单线程驱动 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`、无循环字符串拼接；`CollectOutputStream.write` 逐字节 `add` 是 O(n) 且 n ≤ 9000（测试专用），不构成低效算法 |
| §7 降堆内存方案 | 0 | 只有测试期临时对象与两个异常实例，无长期持有；池项泄漏是缺陷不是优化项，已单列 |
| §8 降 CPU 方案 | 0 | 无基线数据，候选进「待验证假设 #1」 |
| §9 local mode 可行性 | 0 | 本部分没有生产函数内的临时大对象；测试里的字节数组会作为帧返回给断言，不满足不逃逸前提，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 4 | 4 条发现全部标存量：一般 #1（异常类型未被断言）、轻微 #1（不可达 case）、轻微 #2（池项泄漏）、轻微 #3（1 MiB 隐式上限）。已逐条核对两个异常类的构造器转发、`DribbleInputStream` 在 EOF 返回 0 与 `Message.readFully` 的 `n <= 0` 判定一致、`reframe`/`stringField` 的大端位运算与 `putInt32BE`/`getInt32BE` 一致、`crc32(空数组) == 0` 与 `crc32Init/crc32Finish` 语义一致（标准检查值 0xCBF43926），均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 两个异常类型无自有可变状态（`BaseException.suppressed_` 是每实例的，异常对象按抛出线程封闭）；测试类与方法由 unittest 框架串行调用，无共享路径；不存在「每次新建锁对象」「检查-然后-写入」等形态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分新增 0 条：`CommandException` 已在 README:216 列出；`InputClosedException` 只在解码异常表（README:58）出现、未进公开 API 清单，与第 1 部分一般 #8 同根因，已写在「合并提示」并入该条，不重复计数 |
| 文件覆盖（§13 等） | 4/4 | 与 `files/f_protocol.part2.txt` 一一对应，无缺失；本部分无 `.md`，§13 的文档一致性只涉及 README 对这两个异常类的描述（见合并提示） |

## 模块统计

> 仅统计本部分（4 `.cj` + 0 `.md`）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

**本部分是「防线上的防线」：一段专门锁定帧截断语义的回归测试，加上两个没有任何逻辑的异常类型。** 20 个用例把「半头 / 半体 / 半尾 / 长度不一致 / CRC 不符 / 版本不符 / 逐字节短读 / 帧内值级超长声明」逐条覆盖，构造手法（`reframe` 重写 len 后重算 CRC、`stringField` 手工拼 8 字节长度头、`frameWithDataField` 借合法帧前缀）是扎实的，且 `splicedDataFieldStillDecodes` 先自检拼接方式再测超长声明，避免了「用例本身构造错」的假阳性。异常类型与 `f_exception` 的模板一致，没有自有状态，线程安全按「每实例每线程」成立。

**唯一的实质问题是「断言口径」而不是「用例数量」**（一般 #1）：`decodeThrows` 把 `Exception` 全吞，导致这 20 个用例只证明「解码器没有静默返回消息」，没有证明「解码器把截断归类为协议错误」。而模块的对外契约恰恰是两分法（干净关闭 vs 协议错误），`f_net` 也按这两类做不同处理（一个 DEBUG 断链、一个记错误）。一旦有人为了「兼容短读」把截断改回 `InputClosedException`，测试全绿、线上把协议错误当正常下线——这是本部分唯一值得排期修的点，改动量只有几行。

**三条轻微问题都在测试基建**：`dataFieldSize` 借池不还（与第 1 部分一般 #1 同类，说明 `DefaultCodec` 的所有权契约容易被自然用法踩中）、`wireOf` 的 1 MiB 隐式上限（未来大帧用例的假绿陷阱）、两处不可达 `case _`（`Option` 的两个构造器已被前两支覆盖）。都不影响当前行为，可随下一次改测试文件时顺手清掉。

**文档**：两个异常类没有 KDoc，README 的公开 API 清单漏了 `InputClosedException`；与第 1 部分的清单问题同根因，合并处理即可。

本部分共 4 条存量问题（严重 0 / 一般 1 / 轻微 3），是否纳入修复由用户决定；只读代码，未改任何源码、未跑构建。

（范围外提示：`f_protocol/cjpm.toml:26` 声明了 `fountain::f_exception` 依赖，但 `f_protocol/src/**` 全仓 grep 不到任何 `f_exception` 引用，该依赖疑似为历史残留，属依赖卫生问题，不在本轮文件清单内故不计。）
