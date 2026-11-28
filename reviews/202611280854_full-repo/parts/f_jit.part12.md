# f_jit 模块审查报告（模块第 12/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（模块共 305 个 `.cj` + 290 个 `.md`；本部分 20 个文件，全部为 `doc/spec/**` 下的变更文档）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线，本轮所有问题来源记为「存量」）
- **审查重点**：本部分为规格/验证文档，按「文档承诺 ↔ 实现」逐条对拍，重点覆盖动态调用/桥接口径（helper 表与 hid 分支、`**` 运算与数值字面量）、句柄/资源生命周期（窗口收尾、失败缓存的有界化与失效）、并发安全（注册表临界区、编译缓存锁序、失败缓存失效顺序）、死代码与重复逻辑在这批文档口径中的落实情况
- **报告版本**：v1
- **与同模块其他部分的关系**：本部分只含 `doc/spec/feat-f-jit-pow-and-sci-notation`（4 个，无 `verify.md`）、`doc/spec/feat-f-jit-parallel-call`（`test-plan.md` / `verify.md` 2 个；同目录 `design.md` / `proposal.md` / `specs/**` / `tasks.md` 在 part11）、`doc/spec/fix-await-timeout-semantics`（3 个）、`doc/spec/fix-compile-failure-cache-sticky`（3 个）、`doc/spec/fix-compilecache-lock-order`（3 个）、`doc/spec/fix-compiler-register-lock`（3 个）、`doc/spec/fix-da-diagnostic-classification`（`proposal.md` / `tasks.md` 2 个；`verify.md` 不在本部分清单）。这五份 `fix-*` 与 `feat-f-jit-parallel-call` 均已归档，按 review-checklist §13 误报边界「`doc/spec/<已归档变更>/` 按当时结论是否自洽核对」，本报告只记两类：**① 同一变更内文档互相矛盾、或文档把当前实现状态写死却与代码不符；② 文档承诺的护栏/证据在仓内不存在**。变更前行号、历史设计取舍不计入问题，仅在文件覆盖表说明。

## 发现

### [一般][存量] 幂运算优先级的验收值与实现相反：规格写 `-2 ** 2` = -4，实现与测试给 4

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/specs/f-jit-runtime/spec.md:16`（`` `-2 ** 2` = `-(2 ** 2)` = -4 ``）、`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:60`（语法层用例「`-2 ** 2` = -4」）；实现 `f_jit/src/compiler/Parser.cj:972-980`（`parsePower` 左操作数取 `parseUnary`）、`f_jit/src/Pow_test.cj:53-57`（断言 4）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」「示例代码不能用」；§11「与规格 / README 冲突」；语言侧仓颉文档 `cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/operator.md`「操作符优先级表」——`-`（一元）为 **3**、`**` 为 **4**，且该表明写「优先级一栏数值越小，对应操作符的优先级越高」
- **证据**：静态确定 —— 一元负号比 `**` 更紧 ⇒ `-2 ** 2` = `(-2) ** 2` = 4；`Parser.cj:973` 的 `let left = this.parseUnary()` 正是这个结合方式，`Pow_test.cj:57` 断言的也是 4，`README.md:481` 同样写 4。仓颉文档给出的顺序与实现一致，只有 spec/design 两处写成 Python 语义的 -4；`design.md:8` 自己的「优先级 4（> `*`，< 一元 `-`）」也与同行结论自相矛盾
- **描述**：按 spec 的 Scenario 写验收用例（`{ => -2 ** 2 }` 期望 -4）必然红；反过来，读 spec 的人会认为方言与仓颉在负号结合上不一致。这条是规格给出的**可执行验收值**，不是措辞问题
- **建议**：`spec.md:16` 与 `design.md:60` 改为 `` `-2 ** 2` = `(-2) ** 2` = 4（一元 `-` 优先级 3 高于 `**` 的 4） ``，与 `README.md:481` / `Pow_test.cj:57` 对齐；若要保留「与仓颉一致」的论证，把 `operator.md` 的两行优先级一并引到 spec 里

### [一般][存量] 负指数字面量：proposal/design 承诺「编译期拒绝」，spec 与实现是「运行期 14」

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/proposal.md:21`（「字面量负指数**编译期拒绝**」）、`design.md:9`（「字面量负值 → 编译期拒绝；运行期负值 → 14」）、`design.md:23`（Lowerer「字面量负指数 → 编译期拒绝」）；对照 `specs/f-jit-runtime/spec.md:17-18`（两条都写「指数为负（**含字面量**）⇒ 运行期 `ERR_ARG_MISMATCH(14)`」）；实现 `f_jit/src/compiler/Lowerer.cj:1393-1401`（`case StarStar` 只判两侧类型 + `setSite` + `callHelper(H84)`，无字面量负值特判）、`f_jit/src/Pow_test.cj:76-88`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— `Lowerer` 的 `case StarStar` 分支 9 行内没有任何「右操作数是负 `Lit`」的判断，负指数一律落到 helper；`spec.md:18` 还把 `:17` 的同一件事重写了一遍（`含字面量` 与 `运行期指数为负` 两条 Requirement 内容重叠）
- **描述**：同一变更的两份文档对同一输入给出两种时机（编译期异常 vs 运行期 `JitException(14)`）。两者都「能拦住」，但错误面不同：写 `2 ** -1` 的宿主若按 proposal 处理 `SourceCompileException`，实际拿到的是运行期 `JitException`；反之按 spec 写测试则与 design 的落点表不符
- **建议**：二选一并三处同步——推荐保留实现的「统一运行期 14」（少一条特判、与「常量折叠不特判 `2 ** 63`」口径一致，见 `design.md:10`），把 `proposal.md:21`、`design.md:9,23` 改为「负指数（含字面量）运行期 14」；若坚持编译期拒绝，则 `Lowerer` 需在 `:1396` 前加 `Lit(Int64, v) && v < 0` 分支并补编译期用例

### [一般][存量] H84 未升 `verMinor`，但「取舍记入 verify.md 与 README 已知限制」两处落空；旧加载器仍会接受含 H84 的单元

- **位置**：文档 `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/tasks.md:32-33`（`verMinor` **不升级**，「取舍记入 `verify.md` 与 README「已知限制」」）；对照 `design.md:27`、`proposal.md:31`（仍写「`verMinor` **14 → 15**，旧加载器不该接受含 H77 的单元」）；代码 `f_jit/src/base/Version.cj:74`（写出 `verMinor = 14`）、`f_jit/src/runtime/Helpers.cj:139-146`（`case 84 => ipow`；`case _` 且 `hid < USER_BASE` ⇒ `failWith(ErrCode.NOT_IMPL)`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期」；§14.1「版本与依赖漂移」；`fountain-baseline.md` §1（模块版本与产物版本要对齐）
- **证据**：静态确定 —— `ls f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/` 只有 `design.md` / `proposal.md` / `specs/` / `tasks.md`，**没有 `verify.md`**（同批 5 个 `fix-*` 变更都写了 verify，只有这个没有）；`README.md` §8「已知限制」（:603-612）逐条核对无 `verMinor` / H84 相关条目；`specs/f-jit-runtime/spec.md` 与 `tasks.md` 都没有把「不升级」写进规格
- **描述**：设计阶段识别出的风险是「版本门保护」：旧版运行期只认到 H83，遇到 H84 会走 `case _` → `NOT_IMPL`，而不是版本拒绝。`tasks.md` 决定不升级版本（理由是 6 个 Golden 指纹 + 2 个常量表断言要改），这个决定本身可以接受——**但它把「记录」这件事标了 `[x]`，而两个记录点都不存在**。后果：跨版本交换 `.fbc`（README §1 明说 `.fbc` 是纯数据、可移植）时，含 `**` 的单元会被旧运行期当成格式合法单元接下，再以 `NOT_IMPL` 失败，排障时看不出是版本问题
- **建议**：二选一——① 补写 `feat-f-jit-pow-and-sci-notation/verify.md`（记「不升级的理由 + 影响面 + 6 个 Golden 指纹清单」）并在 `README.md` §8 加一条「含 `**` 的单元要求同版本运行期（H84 不在旧版白名单，旧版会以 `NOT_IMPL` 失败）」；② 或改为在 `FbcHeader` 侧给「使用 H84」加一条能力位，让加载期直接 `rejectFormat('该单元需要 H84')`。同时把 `design.md:27` / `proposal.md:31` 标注为「已被 tasks 4.2 取代」

### [一般][存量] 注册失效与在飞编译交错时，失败缓存仍会在 `invalidateFailures()` 之后被重新固化（H2 的「注册后同源可重试」在并发下不成立）

- **位置**：`f_jit/src/CompileCache.cj:98-105`（`fail()` 无条件写 `failures[key]`）、`:114-118`（`invalidateFailures()` 只做 `clear()`）、`:60-70`（`claim()` 在 `failures.contains(key)` 时拒绝认领）、`:128-160`（`awaitReady` 立即返回 `None`）；注册侧 `f_jit/src/Compiler.cj:82`、`:96`、`:129`、`:141`、`:156`；管线侧 `f_jit/src/CompilePipeline.cj:70-89`（`claim` → `c.snapshot()` → 失败 → `catch` → `CompileCache.fail`）
- **来源**：存量（`fix-compile-failure-cache-sticky` 引入的失效机制本身；此处是其并发边界未被覆盖）
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性 / 发布顺序」；§11「并发正确性」
- **证据**：静态确定（窗口存在，命中概率需实测）——`runSource` 不持 `Compiler.mtx` 跑管线，快照在 `claim` 之后单独取（`CompilePipeline.cj:72`）；注册线程只清 `failures`，不阻断已在飞的编译。时序：T1 `claim(key)` + 旧快照 → T2 `registerClass`（`Compiler.mtx` → `invalidateFailures()`，此时表为空）→ T1 编译失败 → `fail(key)` 写入「未注册的类名」→ 之后同一源码 `claim` 恒 `false`、`awaitReady` 恒 `None`、`missingResult` 复述旧文本，与 `proposal.md:19-22` 描述的原缺陷完全一致，只是窗口从「永久」缩到「一次注册与一次在飞失败之间」
- **描述**：`fix-compile-failure-cache-sticky` 修的是「失败结论被永久固化」，实现手段是「注册时清表」。但清表与写表之间没有先后约束：谁的锁后到谁生效。宿主的典型用法正是「编译失败 → 补注册 → 重试」，若补注册与首次编译并发（多线程宿主、或多请求各自编译），补注册可能先清表、首次编译后写表，重试依旧拿到注册前的错误文本
- **建议**：给注册表加**代际**（epoch）而不是用 `clear()` 表达失效：`Compiler` 侧维护 `registryEpoch`（注册/注销 +1，读值与 `snapshot()` 同一临界区取），`fail()` 写入 `(epoch, msg)`；`claim()` / `failureOf()` 只认 `epoch == 当前值` 的条目，过期条目视为不存在（顺带让 `failures` 的上限清理可以从「整表清空」变成「按代际淘汰」）。回归护栏：4 线程交替 `compile` 与 `registerClass`，循环若干轮后断言「注册后的同源编译成功」

### [轻微][存量] `HelperId` 名称表与 `isFixed` 未登记 H84，hid 值域用例仍以 83 为上限

- **位置**：`f_jit/src/runtime/HelperId.cj:121`（`IPOW = 84u16`）与 `:130-221`（`name()` 的 case 表止于 `83u16`，`case _` ⇒ `'unknown(${hid})'`）；`f_jit/src/runtime/Helpers_test.cj:110-131`（`expected` 列表止于 83，断言 `size == 80`）；`f_jit/src/compiler/Ops.cj:210`（注释仍写「`1–62`、`69–83` 为固定 helper」）；文档侧 `design.md:25`（「`IPOW = 77` + 名称表」）、`tasks.md:16`
- **来源**：存量
- **判据**：review-checklist §13「文档与代码一致性」；§14.1「接线缺失」（新增线上码未接入名称表与值域守卫）；§2「重复逻辑」（`Ops.HelperCodec` 与 `runtime.HelperId` 两份 hid 常量的唯一守卫失效）
- **证据**：静态确定 —— `HelperId.name(84u16)` 落入 `case _` ⇒ `unknown(84)`，`isFixed(84u16)` ⇒ `false`；全仓 `HelperId.IPOW` 引用数为 0（`Helpers.cj:139` 用字面量 `case 84` 分派），因此没有任何代码或用例会把 84 补进名称表
- **描述**：`Ops.cj:214-218` 明写「hid 两侧各持一份常量…由「hid 合法值域」用例（`HelperId.isFixed`）在差分层守住一致性」，这条不变量对 H84 已经失效：若 `Ops.IPOW` 与 `Helpers.cj` 的 `case 84` 将来漂移，没有任何用例会红。当前可见影响只到诊断面（`name(84)` 打印 `unknown(84)`；`isFixed` 无生产调用点，仅测试与注释引用）
- **建议**：`HelperId.name` 补 `case 84u16 => 'ipow'`，`Helpers_test.helperIdsCoverSpecRange` 的 `expected` 追加 84 并把 `size` 改 81，`Ops.cj:210` 注释改 `1–62`、`69–84`；顺带在 `Helpers.cj:139` 用 `HelperId.IPOW` 替掉字面量 `84`

### [轻微][存量] H6 的三态判定分两次取锁，`failureOf` 与 `isCompiling` 之间状态可变，会给出错误 kind

- **位置**：`f_jit/src/CompilePipeline.cj:129-141`（`missingResult` 先 `failureOf` 再 `isCompiling`，两把锁分别进出）
- **来源**：存量
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性」；§11「契约与实现不符」
- **证据**：静态确定 —— 两个读各自 `synchronized(mtx)`，中间没有持锁；`CompileCache.cj:132-137`（`awaitReady` 的 `done` 与 `ready.get` 也分两次取锁，同一模式）
- **描述**：本变更的卖点是「调用方能区分『源码有问题』与『等太久』」。在 `awaitReady` 返回 `None` 到 `missingResult` 判定的间隙，另一线程可能刚 `claim` 同一 key（`compiling` 由假变真）⇒ 报 `CompileTimeout`「等待超时（30 s）」；或刚 `fail` 写入文本 ⇒ 本该复述原文却回落到 fallback。都是诊断文本层面的误判，不影响是否抛异常
- **建议**：把三态判定收进一次临界区（`CompileCache.classify(key): (kind, msg)` 内部读 `failures` / `compiling` / `ready`），或让 `awaitReady` 直接返回 `(state, ?JitFunction)` 三元结果，把「为什么是 None」在锁内定型

### [轻微][存量] `feat-f-jit-parallel-call/verify.md` 的「未完成 / 风险」与同文件「实施内容」自相矛盾（P1.5 计数器、P1.2d `freeSlots`、`unloadFn`）

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/verify.md:46`（「`NativeMem.malloc/freeCount` 改 `AtomicInt64`」）对 `:98`（「P1.5：`NativeMem.mallocCount/freeCount` 仍为普通静态计数」）；`:45`（「`freeSlots` 争用评估…保持全局短锁」）对 `:30`（P0 分块存储）与 `f_jit/src/runtime/HandleTable.cj:983`（`freeSlots` 只剩一条注释）；`:101-102`（「主规格 `f_jit-facade-bridge` 的 `unloadFn` 仍待单独立项」）对 `doc/spec/align-jitfunction-close-naming/verify.md:12`（主规格 `unloadFn` / `unload(` 已 0 处）
- **来源**：存量
- **判据**：review-checklist §13「文档过期」「规格与实现漂移」
- **证据**：静态确定 —— `f_jit/src/runtime/JitContext.cj:29-30` 是 `AtomicInt64(0)`，`:36-43` 走 `load()`；全仓 `freeSlots` 仅剩注释一处，槽位由段式 `alive/gens` 管理（`HandleTable.cj:174-178`），空闲索引已改为 `FreeStripes(64)` 分片（`HandleTable.cj:86-103`、`:202`，由 `doc/spec/optimize-call-path-phase2/verify.md:22` 记录）；`unloadFn` 对齐已由 `align-jitfunction-close-naming` 完成
- **描述**：「未完成 / 风险」这一节看起来是 P1 阶段写的快照，P5/P6 落地后没回填。读者据 :98 会认为并发计数存在丢更新，据 :96 会认为槽回收仍是全局 `ArrayList`，据 :101-102 会把已完成的命名对齐继续排期 —— 三条都与现状相反，也会让人误判 P0/P1.5 其实没做完
- **建议**：把 `:96-98` 两条改成「已完成」并指向落点（`JitContext.cj:29-30`、`HandleTable.cj:86-103`），`:101-102` 加「已由 `align-jitfunction-close-naming` 完成（见其 verify §一致性检查）」，只保留仍然成立的 `:99`（吞吐目标与专用机器复测，仍未完成）

### [轻微][存量] H5 计划里的护栏规模（4 线程 × 100 类、每类 2 方法）与 tasks / verify / 实际用例（4 × 20、每类 1 方法、80 次编译）不一致

- **位置**：`f_jit/doc/spec/fix-compiler-register-lock/proposal.md:43-45`；对照 `tasks.md:6`、`verify.md:36-38`、`f_jit/src/CompilerRegistrationConcurrency_test.cj:45`（`per = 20`）、`:60`（每类 1 个 `PublicMethod`）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 计划与落地不一致」
- **证据**：静态确定 —— 三处数字直接可读：proposal 100/2、tasks 20/1、代码 20/1
- **描述**：proposal 写的是「计划时的护栏」，落地缩了 5 倍（100 类 → 20 类）。缩规模本身可能是有意的（4×100 注册会显著拖慢全量），但 proposal 没有回填，读者会以为并发注册的覆盖面比实际大
- **建议**：`proposal.md:43-45` 改成与落地一致（4 线程 × 20 类 × 1 方法 + 80 次编译），并注明「规模化到 100 类会显著拖慢全量，故取 20」

### [轻微][存量] `test-plan.md` 的 8 条计划用例有 6 条在仓内不存在，门槛「单线程与 `9357e98f` 逐位一致」也没有对应证据

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/test-plan.md:7-14`（`concurrentWindowsDoNotInterfere` / `pinDedupeStaysInWindow` / `iterTablePerCallIsolation` / `sameUnitParallelCalls` / `wrapperCrossThread` / `unloadDuringParallelCalls` / `parallelThroughput` / `deadlineIsThreadLocal`）、`:15`（门槛「单线程路径与 `9357e98f` 逐位一致；无句柄/内存泄漏」）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」，§14.1「承诺了但没实现（验收门槛无证据）」
- **证据**：静态确定 —— 全仓搜这 8 个名字只有 `deadlineIsThreadLocal` 命中（`src/runtime/ThreadLocalEnv_test.cj`）；实际用例名见 `verify.md:71-75`（`concurrentWindowsKeepSeparateAccounting`、`iterTablesAreThreadPrivate`、`resetWindowDoesNotKillSlotReusedByAnotherThread`、`concurrentReleasesDropRefcountExactly` 等）。`verify.md` 全文无 `9357e98f`、无「逐位 / 逐字节对比单线程路径」的记录，只有全量用例数与 `liveCount` / `NativeMem.outstanding()` 回基线（`:47`）
- **描述**：计划与落地各用一套名字，追踪「哪条断言被哪个用例覆盖」时必须人工对照；`pinDedupeStaysInWindow`（窗口内去重）与 `sameUnitParallelCalls`（同单元 4×500）在落地用例里找不到同名对应物，无法判断这两条计划断言是否被放弃
- **建议**：`test-plan.md` 顶部加一行「已被 `verify.md` 取代，用例名以 verify 为准」，并把 8 条映射到实际用例名（缺的标 GAP）；门槛里的「与 `9357e98f` 逐位一致」若未执行，改为「同单元单线程结果与改造前用例集合一致（见 `ParallelCall_test`）」

### [轻微][存量] 设计文档写 `mulChecked` 用「显式边界判断」，实现是 try/catch 兜底

- **位置**：`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:43-44`（「`mulChecked(a, b)`：显式边界判断（`MinInt64 * -1`、符号组合的 `MIN/…`、`MAX/…` 阈值）」）；实现 `f_jit/src/runtime/PowHelper.cj:60-72`（只特判 `0` 与 `Min * -1`，其余走 `try { a * b } catch (_: Exception) { failWith(OVERFLOW_I64) }`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§3「静默吞异常」（`catch (_: Exception)` 会把非溢出异常也归一成 3）
- **证据**：静态确定 —— 函数体 13 行，显式阈值判断只有 `a == 0 || b == 0` 与 `Min * -1` 两处；`MAX/…` 分支不存在
- **描述**：两种写法在「溢出 → 3」这一契约上等价（默认溢出策略是抛异常），所以不算行为缺陷；但 `catch (_: Exception)` 的捕获面比「溢出」宽，未来若 `a * b` 因其它原因抛异常（例如调试断言），会被伪装成溢出码 3；另外异常控制流在 hot helper 里的开销也没有数据
- **建议**：要么按 design 改成显式阈值（`a > 0 == b > 0` 时比较 `a > MAX / b`，异号时比较 `a < MIN / b`），要么把 design 改成「以溢出异常为准，捕获后归一为 3」并把 `catch` 收窄到 `ArithmeticException`

### [轻微][存量] 幂变更承诺的词法错误面用例（`***` 切分、`1e`、`1e+`、`1.5f32`）一个都没有落地

- **位置**：`f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md:59`（词法层用例清单）、`:71`（风险表「`***`、`**=` 需覆盖」）、`proposal.md:35`、`specs/f-jit-runtime/spec.md:50,58-61`（非法形态 SHALL 词法错误）；实现 `f_jit/src/compiler/Lexer.cj:817-820`（`***` → `**`+`*`）、`:354-367`（指数缺数字 ⇒ `BAD_NUMBER`）、`:379-382`（数字紧邻标识符 ⇒ `BAD_NUMBER`）
- **来源**：存量
- **判据**：review-checklist §14.1「半成品 / 承诺的护栏缺失」；§13「规格与实现漂移」
- **证据**：静态确定 —— 全仓搜 `***`、`1.5f32`、`f32`、`'1e'` 在 `src/**/*.cj` 只有 `Lexer.cj:818` 的注释命中，无任何用例；`Lexer_test.cj:146` 只是 token 名映射表里的 `StarStar` 分支，不是切分用例。`Pow_test.cj` / `NumberLitSci_test` 6+5 条全是执行层用例
- **描述**：实现侧三条错误面**确实存在**（缺数字、紧邻标识符、`***` 贪心 2 字符），但 spec 把它们写成 SHALL，且 design 明确要求词法层用例，落地为零。一旦有人改 `scanOp` 的匹配顺序（`**` 与 `*`），无护栏会红
- **建议**：`Lexer_test` 补 4 条：`2**3` → `[Int, StarStar, Int]`、`2***3` → `[Int, StarStar, Star, Int]`、`1e`/`1e+` → `BAD_NUMBER`、`1.5f32` → `BAD_NUMBER`；`spec.md:58-61` 的 Scenario 引用这些用例名

### [轻微][存量] 锁序论证句「两条路径各自只持一把锁」与 `close` 实际持两把锁不符

- **位置**：`f_jit/doc/spec/fix-compilecache-lock-order/verify.md:29`（「改后 `finish` 不再在缓存锁内取单元锁，两条路径各自只持一把锁，ABBA 消失」，同结论见 `proposal.md:24-25`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档与代码一致性」；§12.1「判安全要指出具体同步手段与顺序」
- **证据**：静态确定 —— `f_jit/src/JitFunction.cj:256-263`：`close` 在 `synchronized(this.mtx)` 内调用 `CompileCache.remove(k)`，仍持「单元锁 → 缓存锁」两把锁。ABBA 结论本身成立（反向的「缓存锁 → 单元锁」已由 `CompileCache.cj:80-87`「先 bind 后进锁」消除），但「各自只持一把锁」这句不成立
- **描述**：结论对、论证句错。后续有人依据「close 只持一把锁」在 close 路径再嵌一层锁，就会重新造出相反顺序
- **建议**：改为「`finish` 只持缓存锁（bind 在锁外）；`close` 仍持单元锁再取缓存锁（单向）；两条路径不再出现相反顺序」

### [轻微][存量] 并行吞吐表的「加速比」口径未注明，按墙钟直算会得到相反符号

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/verify.md:84-92`（同表复制到 `doc/spec/feat-f-jit-parallel-call/design.md:115`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §6.1「性能结论必须可复核：输入规模 + 工具 + 对照 + 口径」；§13「数据口径」
- **证据**：静态确定（表内数字自算）—— 1 线程 734 ms、2 线程 1154 ms：按「单次调用延迟」读是 **0.64×（变慢）**，只有按「每线程各跑同一 2M 单元、加速比 = 线程数 × 734 / 墙钟」才得到 1.27×（2×734/1154）、2.40×（4×734/1220）、1.91×（8×734/3061）；文档未写这个定义
- **描述**：同一张表按最常见的「单线程耗时 / 并行耗时」读法，2 线程那一行（墙钟 734 → 1154 ms）与「1.27×」相反。数据自洽，缺的是口径，复核者无法直接重算
- **建议**：表头补「每线程各执行 1 个 2M 循环单元；加速比 = N × 734 ms / 墙钟（聚合吞吐）」，并注明 2 线程墙钟上升是共享 VM 干扰，不代表单调用变慢

## 优化可行性方案

> 本部分为文档，优化对象是文档所指的实现。两条均无改前/改后对照数据，只能作下一轮补数据的候选。

### [堆内存] 失败缓存每条文本内嵌「全量已注册名列表」，256 条上限下会放大成数 MB 常驻

- **现状**：`CompileCache.failures` 存 `源码指纹 → 失败文本`，上限 256 条（`CompileCache.cj:95,98-105`）。文本来源含 `PredefinedSnapshot.cj:161-163`（`'已注册：${this.snapshot.registeredList()}'`）与 `:178-180`，而 `registeredList()`（`PredefinedSnapshot.cj:101-112`）把注册表**全部**名字拼成一个字符串；注册量上限由 `Compiler.maxPredefined` 决定。粗估：1000 个注册名 × ~15 B ≈ 15 KB/条，256 条 ≈ 3.8 MB 常驻，且这些文本在注册失效前不会再被读取
- **方案**：失败文本只保留「诊断头部 + 注册表代际号」，把 `registeredList()` 从错误消息里摘出来，改为诊断出口按需拼接（`DiagnosticsSink` 渲染时读当前快照）；或把 `registeredList()` 截断到前 N 个并注明剩余数量
- **预期**：单条失败文本从 O(注册名总长) 降到 O(1)，256 条上限下的常驻从数 MB 降到数十 KB；具体比例待测
- **代价**：错误文本不再自包含「完整注册列表」，排障时要多一次查询；`Semantics_test` 中若断言了注册列表全文需同步
- **验证**：注册 1000 个函数 → 制造 256 条不同失败 → 对照 `getAllocatedHeapSize()` / RSS 与 `registeredList().size`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ipow` 的溢出检测走异常控制流，可改显式阈值判断

- **现状**：`PowHelper.cj:60-72` 每次乘法都在 `try { a * b } catch (_: Exception)` 里做溢出判定。快速幂每算一位最多一次乘法（≤ 63 次），溢出用例（`2 ** 63`）会**必然**走一次抛异常路径；正常用例是否为零成本取决于仓颉异常实现（表驱动 vs 栈展开），无数据
- **方案**：按 `design.md:43` 的写法做显式阈值比较，仅在越界时 `failWith(3)`，去掉 try/catch
- **预期**：溢出用例省一次异常构造/展开；正常用例是否受益未知（若 use-landing-pad 实现则收益接近 0）
- **代价**：阈值分支要覆盖同号/异号与 `MIN` 边界，逻辑比 catch 复杂，需配 6 条等价用例（`MIN * -1`、`MAX * 2`、`-2 * MIN/2`、`0 * MIN` 等）
- **验证**：`cjpm bench -O2` 跑 `2 ** 62`（成功路径）与 `2 ** 63`（溢出路径）各 100 万次，取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注册与在飞编译交错时，旧失败文本会在 `invalidateFailures()` 之后被重新写入（发现 #4 的可复现性） | `f_jit/src/CompilePipeline.cj:70-89`、`CompileCache.cj:98-105` | 实际命中率与窗口宽度 | 4 线程交替 `compile('{ u: LateCls => u.m(1) }')` 与 `registerClass(LateCls)`，每轮结束断言同源编译成功；跑 10 万轮统计失败次数 |
| 2 | 失败缓存 256 条的文本体积是常驻堆的一部分（优化方案 1） | `f_jit/src/CompileCache.cj:95`、`PredefinedSnapshot.cj:101-112` | 单条文本字节数、注册规模分布 | 注册 1000 函数后制造 256 条失败，读 `registeredList().size` 与 `getAllocatedHeapSize()` |
| 3 | `ipow` 的 try/catch 在溢出路径上有可观开销（优化方案 2） | `f_jit/src/runtime/PowHelper.cj:60-72` | 成功/溢出两条路径的单次耗时 | `cjpm bench -O2` 对照显式阈值实现，各 100 万次取中位数 |
| 4 | `HelperId.name(84)` 为 `unknown(84)` 在诊断转储/报告里可见 | `f_jit/src/runtime/HelperId.cj:130-221` | 是否有转储路径打印 hid 名 | 搜 `HelperId.name` 的生产调用点（当前只有测试），或对含 `**` 的单元跑一次诊断转储观察输出 |
| 5 | 三态判定在并发编译同一源码时会误报 `CompileTimeout`（发现 #6） | `f_jit/src/CompilePipeline.cj:129-141` | 误判出现频率 | 2 线程同时编译同一新源码 + 1 线程持续 `registerFunction`，统计 `CompileTimeout` 次数与真实超时次数之比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/feat-f-jit-parallel-call/test-plan.md` | .md | ✅ | 8 条计划用例 6 条无对应实现、门槛无证据（#9）；基线 1145 与 verify 的 1178 不同快照 |
| 2 | `f_jit/doc/spec/feat-f-jit-parallel-call/verify.md` | .md | ✅ | 实施表逐条对得上（1024 槽/段与 4096 段 `HandleTable.cj:174-178`、TLS、无锁读抽查 9 个函数 0 个 `synchronized`、`PromotionGroup` 全方法加锁、10 条新用例数目核实 3+3+1+2+1）；「未完成/风险」三处过期（#7，含 `:101-102` 的 `unloadFn` 实际已由 `align-jitfunction-close-naming` 完成）；吞吐表加速比口径未注明（#13） |
| 3 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/design.md` | .md | ✅ | H77/`verMinor` 15/显式溢出边界/`-2 ** 2` = -4 四处与实现不符（#1/#2/#3/#10） |
| 4 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/proposal.md` | .md | ✅ | 优先级引用（3 vs 4）正确；字面量负指数与 `verMinor` 两处与落地相反（#2/#3）；`:49` 提到的 `NumberLit_test.cj` 实为 `Pow_test.cj` 内的 `NumberLitSci_test` 类 |
| 5 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/specs/f-jit-runtime/spec.md` | .md | ✅ | Requirement 结构与 Scenario 完整；`:16` 验收值与实现相反（#1）；`:17-18` 两条重叠；非法形态无用例（#11） |
| 6 | `f_jit/doc/spec/feat-f-jit-pow-and-sci-notation/tasks.md` | .md | ✅ | 2.1 的 H84 与代码一致（`Ops.cj:259`、`Lowerer.cj:1401`）；4.2 的「记入 verify.md / README」断链（#3）；`:30` 的 1123/1123 是当时的全量数 |
| 7 | `f_jit/doc/spec/fix-await-timeout-semantics/proposal.md` | .md | ✅ | 与 `CompileCache.cj:43,46`、`CompilePipeline.cj:129-141` 一致 |
| 8 | `f_jit/doc/spec/fix-await-timeout-semantics/tasks.md` | .md | ✅ | T1.1–T1.4 均有落点 |
| 9 | `f_jit/doc/spec/fix-await-timeout-semantics/verify.md` | .md | ✅ | diff 与现状一致；三态判定的非原子性未记载（#6） |
| 10 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/proposal.md` | .md | ✅ | 上限 256、五个注册入口与实现一致；并发窗口未讨论（#4） |
| 11 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/tasks.md` | .md | ✅ | T1.1/T1.2 的「改前必红」与 verify 一致 |
| 12 | `f_jit/doc/spec/fix-compile-failure-cache-sticky/verify.md` | .md | ✅ | diff 与 `CompileCache.cj:95-118` 逐行一致；`:63` 的「整表清空」语义已实现 |
| 13 | `f_jit/doc/spec/fix-compilecache-lock-order/proposal.md` | .md | ✅ | 锁序结论与 `CompileCache.finish`（bind 在锁外）一致 |
| 14 | `f_jit/doc/spec/fix-compilecache-lock-order/tasks.md` | .md | ✅ | T1.1/T1.2 均落地（含注释） |
| 15 | `f_jit/doc/spec/fix-compilecache-lock-order/verify.md` | .md | ✅ | 锁序结论成立（`JitFunction.close` 仍为「单元锁 → 缓存锁」，无反向）；「两条路径各自只持一把锁」与 `close` 实际持两把锁不符（#12） |
| 16 | `f_jit/doc/spec/fix-compiler-register-lock/proposal.md` | .md | ✅ | 锁序 `Compiler.mtx → ClassRegistry.mtx / retainedMtx` 与实现一致；护栏规模与落地不同（#8） |
| 17 | `f_jit/doc/spec/fix-compiler-register-lock/tasks.md` | .md | ✅ | T1.1–T1.4 落地；T2.1 如实记「旧实现也通过」 |
| 18 | `f_jit/doc/spec/fix-compiler-register-lock/verify.md` | .md | ✅ | 用例规模与代码一致（4×20×1 + 80 编译），与 proposal 不同（#8） |
| 19 | `f_jit/doc/spec/fix-da-diagnostic-classification/proposal.md` | .md | ✅ | 两处落点与 `DefiniteAssignment.cj:204-219`、`:357-367` 一致；`walkCallee` 不需改动的判断成立；`NameResolver` 实为 `PredefinedSnapshot.cj` 内的类（提示，非问题） |
| 20 | `f_jit/doc/spec/fix-da-diagnostic-classification/tasks.md` | .md | ✅ | T2.1/T2.2 已在代码、T3.3 已在 `DaDiagnostic_test`（4 条）对上；本变更的 `verify.md` 不在本部分清单（由 part13 覆盖） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 #1（优先级验收值）、#2（负指数时机）；设计 #4（失效机制缺代际）。本部分为文档，无外部输入、无凭据面，语言特性除 `**` 优先级（已用 `operator.md` 核对）外无其它断言，安全性 0 条 |
| §1 死代码 | 0 | 本部分无源码，按「文档声称新增的符号是否真有引用」机械过：`CompileCache.awaitTimeoutNs`（`CompileCache.cj:43` + `CompilePipeline.cj:135`）、`isCompiling`（`CompilePipeline.cj:133`）、`invalidateFailures`（`Compiler.cj:82/96/129/141/156`）、`missingResult`（`CompilePipeline.cj:89/117`）、`HelperCodec.IPOW`（`Lowerer.cj:1401`）、`lastEscaped`（`JitFunction.cj:669` 写、`:539-549` 与 `JitFunctionClosure_test.cj:123` 读）均有非测试引用；`failureCount` / `CompileCache.reset` 仅测试引用，属「可见性建议」不算死代码；`HelperId.IPOW` 仓内 0 引用，但 `HelperId` 是 `public class`（对外可达 public，硬原则一不判），已计入信息与 #5；`awaitReady` 末尾 `while(true)` 后的 `return None`（`CompileCache.cj:149`）是可达性兜底，不判 |
| §2 重复逻辑 | 2 | `Ops.HelperCodec` 与 `runtime.HelperId` 的 hid 双份常量（设计上刻意，守卫用例未覆盖 84，见 #5）；`CompilePipeline` 两处 `None` 分支已抽成 `missingResult`（无重复）。幂实现只有 `PowHelper.ipow` 一份，`TextFormat.pow2/pow5` 是 10 的幂换算，语义不同不判 |
| §3 空实现 | 2 | `PowHelper.cj:69` 的 `catch (_: Exception)` 把非溢出异常也归一成 3（#10）；`CompileCache.fail` 达上限整表清空后无淘汰策略说明（记入 #4 的修法）。`fix-da-diagnostic` 的 `return`（放行）有注释说明为何可以放行，不判 |
| §4 栈溢出 | 0 | 本部分文档不引入递归；`ipow` 是 `while` 循环（`:47-55`），深度由指数位数（≤63）界定 |
| §5 OOM | 1 | 失败缓存有 256 上限（`CompileCache.cj:95-104`）已挡住无界增长；剩余放大面是「每条文本内嵌全量注册名列表」，进优化方案 1（无基线，不进 tasks） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；`ipow` 异常控制流、失败文本拼接都只进「待验证假设」2/3，不判缺陷 |
| §6.2 大粒度锁 | 0 | 文档所述的 `callMtx` / `envMtx` 已删；`Compiler.mtx` 在注册期包住反射（`Compiler.cj:134-146`）是冷路径且文档已明确代价（`proposal.md:37-38`），无持锁 I/O |
| §6.3 并发串行 | 0 | 本部分无 `spawn` 后立即 `get()` 的实现；`verify.md:82-92` 的 1/2/4/8 线程吞吐是已有基线（1.27×/2.40×/1.91×，共享 VM 超订），不重复计入 |
| §6.4 低效算法 | 0 | `registeredList()` 在每次失败时全量拼接（O(注册数)），但失败是冷路径且无耗时数据，归入优化方案 1 的内存面 |
| §7 降堆内存方案 | 1 | 失败文本内嵌注册名列表（优化方案 1） |
| §8 降 CPU 方案 | 1 | `ipow` 溢出检测改显式阈值（优化方案 2） |
| §9 local mode 可行性 | 0 | 本部分涉及的产物（失败文本、编译快照、`PredefinedSnapshot`）全部逃逸进 `CompileCache` / `Compiler` 成员，`@local` 不成立 |
| §11 现有代码的 BUG（存量） | 13 | #1–#13 全部按 §11 取证；其中 #1/#2/#3/#5/#10/#11/#12/#13 同时属 §13，#4 同时属 §12.1 |
| §12 并发安全与锁粒度 | 2 | #4（失效与写回的先后无序，缺代际）、#6（三态判定分两次取锁）；锁序方面核对了三条链：`Compiler.mtx → ClassRegistry.mtx / retainedMtx / CompileCache.mtx`（`Compiler.cj:113-157`）、`JitFunction.mtx → CompileCache.mtx`（`JitFunction.cj:263`）、`CompileCache` 只进不出（`finish` 的 bind 已移出锁，`CompileCache.cj:80-88`），无 ABBA；#12 只是锁序表述不准确，不改变安全结论 |
| §14 功能完备性与 README 覆盖 | 4 | #3（版本门与「记入 verify/README」未兑现）、#5（hid 名称表与值域守卫未接线）、#9（计划用例与验收门槛无对应物）、#11（承诺的词法错误面用例全缺）；本部分不含 README，README 覆盖检查在其它部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

这 20 份文档的**主体质量高于一般归档文档**：五份 `fix-*` 变更的「问题 → 改法 → 锁序论证 → 改前红/改后绿」链条完整，工程上最容易被糊弄的两处都如实写了——`fix-compiler-register-lock/verify.md:40-52` 明说「旧实现也通过，本条没有变异证据」，`fix-compilecache-lock-order/verify.md:29-33` 把「为什么把 bind 移出锁仍然安全」论证到调用图不变式层面。逐条对拍后，`missingResult` 三态、`FAILURES_MAX` 256 与五个注册入口、`finish` 的 bind/发布顺序、`DefiniteAssignment` 两处 `None` 放行、并行调用的分块存储/TLS/无锁读/PromotionGroup 加锁、10 条新用例数目，都能在代码里找到落点，没有「文档说做完了其实没做」的大面积漂移。

风险集中在两处。**第一处是 `**` 这个新特性的四份文档三套口径**：`-2 ** 2` 的验收值写反（#1）、负指数字面量的拒绝时机在 proposal/design 与 spec/实现之间相反（#2）、`verMinor` 该不该升在 design/proposal 与 tasks 之间相反且「记入 verify/README」两个落点都不存在（#3）、连带 `HelperId` 名称表与值域用例没跟上 H84（#5）。这些都不影响正常运行，但 `spec.md` 是可执行验收口径，按它写用例必红，属于必须排期修的一类。

**第二处是「注册使失败缓存失效」这个修法本身的并发边界**（#4）：时序上，注册线程清表与在飞编译写回失败之间没有先后约束，宿主「编译失败 → 补注册 → 重试」的多线程用法仍会复现原来的 sticky 行为。这条没有任何护栏覆盖（`CompileFailureCache_test` 是单线程），修法建议用代际号而非 `clear()`，成本不高。

本部分**无严重项**：没有发现栈溢出、OOM（失败表已 256 上限）、死锁（三条锁链无反向）、或对外契约承诺为空的形态。#6–#13 是归档文档的回填问题与护栏缺口，可随下一次文档整理批量处理。存量问题 13 条（一般 4 / 轻微 9），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计）：`README.md:249` 仍写 helper 白名单为「H01–H83」，而 `**` 已占用 H84（同文件 `:484` 又写 H84），属 README 部分的自相矛盾；`README_en.md` 的并发问答编为 Q7 而中文版为 Q8（`README.md:587`），中英编号不对称。
