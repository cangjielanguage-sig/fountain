# f_pool 模块审查报告

> **模块第 2/2 部分**（本报告只覆盖 `files/f_pool.part2.txt` 列出的 17 个文件：`base/`、`diagnostics/`、`exception/`、`pool.cj`、`UnitKeyPool.cj`、`imports.cj` 与五个 `*_test.cj`；`README.md` / `README_en.md` 与 `ArrayPool` / `KeyPool` 等 14 个文件由第 1 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_pool`（本部分 17 个源文件，均为 `.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比）
- **审查重点**：对象池/线程池生命周期、泄漏与 OOM、大粒度锁与并发串行、栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 2/2 部分）

## 发现

### [一般][存量] `KeyPool<Unit, V>.remove(())` 之后 `get` 变成「建了立刻销毁」的空转，直到 `maxWaiting`（默认 30s）超时

- **位置**：`f_pool/src/UnitKeyPool.cj:53-55`（`remove` 直接 `pool.close{...}`）→ `f_pool/src/KeyPool.cj:544-565`（创建循环）→ `f_pool/src/KeyPool.cj:766-780`（`get` 的等待循环）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「错误处理缺失」；§12.1「有界性」；§6.3「并发串行（单消费者空转）」
- **证据**：静态确定 —— `UnitKeyPool.remove` 与 `close` 同体，只把底层 `BasePool` 置为 `closed`；`KeyPool.running` 仍为 `true`、`pool.size == 0`。于是 `get` 的 `if (pool.size < totalSize && pool.keyedSize(key) < maxSize)` 恒成立 → `tryAddTask` → `creationLoop` 调 `creator(k)` 建对象 → `pool.add` 返回 `false`（池已 closed）→ `keyedDestroy` 立刻销毁 → `break` → `wakeWaiters()` → `get` 醒来再走一遍，直到 `remain <= 0`
- **描述**：`KeyPool` 是 `public` 类型，`remove(key)` 也是 `public`；`K = Unit` 时用户写 `remove(())` 是自然用法（`UnitKeyPool` 的注释也只说「`get` 一直返回 `None`」）。实际后果比「返回 None」重得多：每次 `get` 都会**以 creator 的速度持续创建并销毁资源**（典型 creator 是建连/开文件/分配缓冲），默认持续 30 秒，然后打一条 `key pool exhausted` 的 WARN 并返回 `None`；下一次 `get` 再来 30 秒。对数据库/网络连接池就是一次连接风暴 + 满核 CPU，且没有任何「池已废」的快速失败路径
- **建议**：让 `UnitKeyPool` 也维护一个 `closed` 标志（或在 `IKeyPool` 增加 `isDead()`），`KeyPool.get` 在 `tryAddTask` 之前先判「底层池已关」立即返回 `None`；`KeyPool.remove` 对 `Unit` 键应同时把 `running` 置 `false`（语义上单键池的 remove 就是关闭），并在文档/README 里写清这一点

### [一般][存量] checker / taskPusher 抛异常时只结清 deque 自己的 `s`，上层 `BaseKeyPool` 的全局 `s` 不减 ⇒ `pool.size` 虚高、后续 `get` 可能连续 30s 取不到

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:171-183`（`checkedBeforeReturn` 的 catch）、`216-220`（`remove` 的 catch）、`330-336`（`check` 里 `n.check` 抛异常时 `rm` 不返回）↔ `f_pool/src/BaseKeyPool.cj:70-79`（`keyedChecker` 只在 `false` 分支 `s.fetchSub`）、`97-98`（`p.check(...) |> s.fetchSub` 只在正常返回时执行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」、§12.1「可见性 / 计数一致性」；违反 README「内部实现」段自己写的不变量 `s ≡ Σ 各队列 size`
- **证据**：静态确定 —— 三条异常路径都只调 `discardItem`（结清 deque 的 `s`/`out`），而上层的 `s` 依赖 `keyedChecker` 返回 `false` 或 `p.check` 正常返回。异常越过这两点时，全局 `s` 比实际多 1（每次一个池项），随后 `pool.size < totalSize` 可能恒假 → 不再派发创建任务 → `get` 等满 `maxWaiting` 返回 `None`
- **描述**：受影响的是 `K ≠ Unit` 的多键池（`UnitKeyPool` 的 `size` 直接读 deque，不会漂移）。触发条件是应用提供的 `checker` 抛异常（连接已断时校验里做 I/O 很常见）；`BaseKeyPool.audit()` 下一轮巡检会把 `s.store(total)` 校正回来，所以在巡检开启时是「最长一个巡检周期的性能/可用性塌陷 + 一次 `checkSize` 不一致」；`checkInterval <= 0`/`Duration.Max`（明确支持的「不巡检」配置）时会一直漂到进程重启
- **建议**：把「结清」放进 `discardItem` 的上层钩子（例如让 `SyncDeque` 的 checker 包装器用 `try/finally` 记一次「本项已判失效」，由 `BaseKeyPool` 在异常路径统一 `s.fetchSub(1)`），或让 `BaseKeyPool.check/get/giveBack` 统一 `catch` → `s.fetchSub(1)` → `rethrow`；补一条用例：checker 抛异常后断言 `pool.size == 实际可取数`

### [一般][存量] `SyncDeque.check` 的 `checkers.fetchAdd(1)` 在 `try` 之外：`prevForChecking()` 一旦抛异常，`checkers` 永久 +1，自愈从此完全失效

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:319-321`（`checkers.fetchAdd(1)` + `head.tail.prevForChecking()`）↔ `339-348`（`finally` 里 `checkers.fetchSub(1)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称（异常跳过释放）」、§12.1「失败后状态不可恢复」；`reconcileIfWedge` 的前置条件见 `SyncDeque.cj:256-258`
- **证据**：静态确定（结构）—— `checkers.fetchAdd(1)`（320）与 `fetchSub(1)`（347）不在同一个 `try` 里，`prevForChecking()`（321）在 `try` 之前；`LinkedNode.cj:32-34/109/142/200` 的 `UnreachableException` 是该调用链上唯一的抛出点
- **描述**：`reconcileIfWedge()` 的判据是「`checkers != 0` ⇒ 认定非 idle 节点是合法中间态，不动手」（`256-258`）。`checkers` 被永久抬高 1 之后，这条自愈路径**再也不会执行**：巡检 `audit()` 也走同一函数（`300-302`），于是「记着有项却一个也取不出来」一旦发生就永久保持——正是 7.2 里花了很大力气兜住的那个症状。触发需要链表结构异常（`prev`/`next` 类型不匹配），概率低，但代价是彻底失去兜底
- **建议**：把 `checkers.fetchAdd(1)` 之后的第一句移进 `try`（`checkers.fetchAdd(1); try { var pending = ...; ... } finally { ... }`），或改成一个 `CheckScope` 式的 `try/finally` 包裹；顺带在 `finally` 里对 `checkers` 做一次 `max(0)` 保护（`if (checkers.load() > 0)` 再减）以便计数被外部写坏时能自愈

### [一般][存量] `PoolDiagnostics` 默认在首次建池时接管进程级 SIGSEGV/SIGABRT，并在处理器里做分配/IO/`exit(134)`；`CRASH_DUMP_ON_FATAL` 是 `const`，注释说的「置 false」用户做不到

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:60-65`（`public static const CRASH_DUMP_ON_FATAL = true`）、`236-250`（处理器：`snapshot()` 字符串拼接 + `writeDiagnostic` 的 `writeln`/`flush` + `exit(134)`）、`KeyPool.cj:291-294`（每次建池都尝试安装）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「全局副作用」；§12.1「跨线程/进程级共享状态」；POSIX 的 async-signal-safety 约束（信号处理器里不得分配、不得用带锁的 stdio）
- **证据**：静态确定（调用与副作用）+ 待确认（运行时是否真的不触发，见下）—— 处理器体里调用了 `snapshot()`（12 次原子读 + `String` 插值分配）、`writeln`/`flush`（stdio 锁）、`exit()`；`60-62` 的注释让用户「把 `CRASH_DUMP_ON_FATAL` 置 false」，但它是 `const`，只能改库源码重编
- **描述**：任何 `Pool` 的构造都会走到 `installCrashHandler()`，把**宿主进程**已注册的 SIGSEGV/SIGABRT 处理器换成本模块的（`registerSignalHandler` 覆盖语义，`f_base/src/signal.cj:78-89`），随后 `exit(134)` 直接终结进程——崩溃上报、core dump、运行时的 fatal 处理都会被截断。而同一文件 `226-235` 又自述「Cangjie 运行时先接管，本处理器**不会被调用**（2026-10-04 实测）」，即：真出问题时它不会跑，代价（覆盖宿主处理器、信号上下文里跑非异步信号安全代码）却一直存在
- **建议**：默认值改 `false`（或改成 `var` + 配置读取），把这个安装动作降级为显式 API；处理器体只保留 `write(2)` 一段**预分配好的静态字节**（不拼接、不走 `String`/stdio），或在只有运行时接管的前提下删掉该分支，改由 `reportIfChanged` / `installShutdownReport` 承担取证（`233` 已经这么写了）

### [轻微][存量] `BasePool.close` 的「关闭即清空」在 check 在飞 / get 交错时不闭合（当前只靠上层 checker 把项判失效兜底）

- **位置**：`f_pool/src/base/BasePool.cj:96-102`（`close` 只走 `q.check({=> true}, ...)`）、`84-89`（`get` 的 `closed` 检查与 `q.remove` 不同步）↔ `f_pool/src/base/collection/LinkedNode.cj:129-144`（`prevForChecking` 只挑 idle 节点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「资源不对称」；§12.1「检查-然后-写入」
- **证据**：静态确定（机制）+ 待确认（仓内是否可达）—— `SyncDeque.check` 跳过 `CHECKING` 节点，`close` 也不会回头再扫一次；`FifoPool.get` 在 `closed.load()` 为 false 之后才 `q.remove`，close 的 `closed.store(true)` 与清空之间没有互斥
- **描述**：两种情况：(a) 巡检线程正持着某个节点做 `checker`（状态 CHECKING），此时 `close` 清空会**跳过**它；巡检线程稍后 `setIdle()` 把项放回一个已关闭的队列，`destroier` 永远不会被调用；(b) `get` 与 `close` 交错时可以从已关闭的池里借出一项（该项在归还时才被销毁）。仓内路径不漏，是因为 `KeyPool` 传给 `check` 的 checker 自己带 `running.load()` 判断、失效时主动 `take()` + `doDestroy`（`KeyPool.cj:434-448`），属于「上层替底座兜底」。任何直接使用 `BasePool` 或 checker 不感知 `running` 的调用方都会漏掉那一项的销毁
- **建议**：`close` 末尾再排空一次（`while (size > 0) { q.check(...) }`，或增加 `drainAll()`：先 `reviveNonIdle()` 再扫），并把「关闭后 `get` 必须返回 None」做成 `SyncDeque` 级别的关闭标志，而不是只靠上层

### [轻微][存量] 告警钩子是静态 `var`，`redirectWarningsTo` 与 `warn/error` 之间无同步；`installDefaultHooks` 与它竞争时可能覆盖应用钩子

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:139-141`（`protected static var warnHook/errorHook`）、`154-158`（先赋值后 `hooksInstalled.store(true)`）、`161-167`（CAS 成功后再赋值）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「可见性：用普通字段当跨线程信号」
- **证据**：静态确定 —— 函数值字段是普通 `var`，写入方（`redirectWarningsTo`，`public`，运行期任意线程可调；`installDefaultHooks`，每次建池调用）与读取方（`warn`/`error`，任意线程）之间没有锁或原子；`hooksInstalled` 的 CAS 只保护「谁先装」，保护不了「赋值顺序」
- **描述**：最坏序列：应用调 `redirectWarningsTo`（赋值完成、尚未 `store(true)`）→ 另一线程建池，`installDefaultHooks` 的 CAS 成功 → 用 f_log 钩子覆盖应用的采集钩子。反过来也可能读到旧的闭包。注释把用法限定在「启动早期」（`145-147`），但 `SyncDeque_test.cj:256-288/297-336` 就在运行期改它，说明运行期改是预期用法之一
- **建议**：`warnHook`/`errorHook` 收进一个不可变 `struct Hooks`，用 `AtomicReference`/原子替换整块发布；`redirectWarningsTo` 先 `store` 再登记「已被接管」，`installDefaultHooks` 用同一个原子做 CAS 后再校验

### [轻微][存量] `reportIfChanged` 首轮必打一条「健康」统计（与「健康时静默」相反），且 check-then-store 会让多个池重复打

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:182`（`lastReportedSignature = AtomicInt64(-1)`）、`190-198`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」（`187/200` 两处注释都写「健康时静默」）、§12.1「检查-然后-写入」
- **证据**：静态确定 —— `anomalySignature()` 初始为 `0`，与 `-1` 不等 ⇒ 第一次 `reportIfChanged`（`KeyPool.cj:464`，第一轮巡检后）必然 `warn("[FOUNTAIN_POOL.diag] pool audit: …")`；`load` 与 `store` 不是原子的，两个池的巡检线程可能同时通过判断
- **描述**：进程启动约一个 `checkInterval`（默认 1 分钟）后必有一条 WARN 级诊断行，容易被值班当成告警；多池部署时同一份统计会被打印多次。同类可观测性小问题：`SyncDeque.cj:85`/`285` 的告警前缀写成 `DEQUE-SELFCHECK]` / `WEDGE-HEAL]`，缺起始 `[`，按 `[...]` 检索会漏
- **建议**：初值改 `0`（或第一次只记录不输出）；用 `compareAndSwap` 代替 `load`+`store`，失败即返回 `false`；补上缺失的 `[`

### [轻微][存量] 退出统计走告警钩子，与本文件「崩溃/退出路径不能碰日志框架」的自述冲突

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:201-209`（`atExit { reportIfChanged('shutdown') }`）↔ `132-136`/`217-224`（`dump()` 为此固定直写 stderr）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「设计与注释冲突」、§3「静默失效」
- **证据**：静态确定（调用链）—— `reportIfChanged` → `warn` → `warnHook`；`KeyPool` 首次建池就把钩子接到 `LoggerFactory`（`KeyPool.cj:286-288`），而 `f_base/src/signal.cj:45-69` 的 `onExit()` 是在 SIGTERM/SIGINT 处理器里执行 `atExit` 回调
- **描述**：应用没接管钩子时，退出统计会被写进 f_log（队列 + 独立写线程）——正是在信号处理器上下文里；模块自己在 `31-38` 明说此时「日志框架可能死锁或丢行，不能碰」，并因此让 `dump()` 绕过钩子。结果是「最后一次已知状态」在最需要它的退出路径上最可能丢（或卡住退出）
- **建议**：`installShutdownReport` 使用 `dump()`（固定 stderr + flush）而不是 `reportIfChanged`；若还想进 f_log，改成 `try { warn(...) } catch { dump(...) }` 的双通道，并注明退出期只保证 stderr

### [轻微][存量] `UnitKeyPool.keyCount()` 恒为 1（含 `close()` 之后），与 `IKeyPool.keyCount` 的「close 之后必须为 0」契约相反

- **位置**：`f_pool/src/UnitKeyPool.cj:74-77` ↔ `f_pool/src/IKeyPool.cj:38-39`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」；§14.2「文档承诺与实现不一致」
- **证据**：静态确定 —— 接口注释「键表里当前的键数（诊断 / 测试用：`POOL-11` 的观测点，**`close()` 之后必须为 0**）」；实现直接 `return 1`，且自带注释「单键池：键数恒为 1（哪怕是已关闭的池）」
- **描述**：同一份不变量，两种口径。`BaseKeyPool_test` 里大量 `@Assert(pool.keyCount(), 0)` 正是按接口口径写的；若对 `Unit` 池套用同一断言就会失败。`KeyPool.keyCount()` 是 `POOL-11`（键表不许从 close 之后长回来）的观测点，口径分叉会让该观测对 `Pool<V>` 完全失真
- **建议**：`UnitKeyPool` 记录自身是否已 `close`/`remove`，关闭后返回 0；或把接口注释改成「多键池返回键数、单键池恒为 1」，并同步 README

### [轻微][存量] `FifoPool.add` 缺「入队后再查一次 closed」的第二道检查（`giveBack` 有），关停交错时新项会留在死队列里永不销毁

- **位置**：`f_pool/src/base/BasePool.cj:64-70`（`add`：检查 → 入队 → 返回 true）↔ `71-83`（`giveBack`：入队后再查一次并排空）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「检查-然后-写入」「资源不对称」；§12.1
- **证据**：静态确定（窗口存在）+ 待确认（仓内可达性）—— 仓内唯一的 `add` 调用点在 `KeyPool.cj:557-559` 的 `synchronized(admission)` 内，而 `close()` 的 `running` CAS 也在这把锁里（`601`），因此窗口被外部锁堵住；`BaseKeyPool.add` 自身没有这道锁（`BaseKeyPool_test` 直接调用它）
- **描述**：`add` 在 `closed.load()` 为 false 之后、`q.insertTail` 之前被 close 抢到，项就被插进一个已经清空过的队列：`get` 不会再取（`closed` 为 true），`close` 也不会再扫，`destroier` 永不执行。四个 `*Pool` 实现都是这个形状，`giveBack` 的「第二道检查 + 排空」正是对同一窗口的补丁，`add` 漏了
- **建议**：`add` 照抄 `giveBack` 的第二段（入队后 `if (closed.load()) { while (let Some(_) <- q.remove({_=>false}, destroier)) {} }`，并把「没进去」如实返回 `false`）；或把 closed 判定与入队都放进 deque 的同一临界区（`SyncDeque.addIfOpen(value): Bool`）

### [轻微][存量] 死代码与「用 `open` + `throw` 代替 `abstract`」的静默失效风险（`LinkedNode`）

- **位置**：`f_pool/src/base/collection/LinkedNode.cj:24`（`VALUE_NODE_INVALIDATED`）、`273-277`（`prop busy`）、`278-282`（`prop invalidated`）、`289-291`（`setInvalidated`）、`26-53`（`Node` 的 6 个 `protected open` 成员，全部 `throw UnreachableException()`）、`225`（不可达的 `sleep(Duration.Zero)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「无调用者」「不可达语句」「恒真恒假分支」；§3「接口默认空实现，实现类忘记覆盖」
- **证据**：静态确定 —— `grep -rn "invalidated\|setInvalidated\|VALUE_NODE_INVALIDATED" f_pool/src` 只命中定义处；`grep -rn "\.busy" f_pool/src` 为 0（`setBusy` 有调用，getter 没有）；`Node<T>` 的 6 个成员没有任何**多态**调用点（`head.insertNext`、`tail.insertPrev`、`x.nextForGet`、`x.prevForChecking`、`ValueNode.prev/next` 全部是具体类型上的静态分派），因此基类实现永不执行；`208-228` 的 `synchronized` 块两条分支分别是 `continue` 与 `return`，块后的 `sleep(Duration.Zero)`（225）不可达
- **描述**：`Node` 本应是抽象层，却用「`open` + 抛 `UnreachableException`」当默认实现：将来新增一个 `Node` 子类若忘了覆盖 `insertPrev`/`insertNext`，编译期不报错，运行时才在链表操作里抛 `UnreachableException`（而 `check` 路径上的 `UnreachableException` 还会顺带触发发现 #3 的 `checkers` 泄漏）。`invalidated`/`busy` 三件套是重构残留，读代码的人会以为存在「作废状态」这一状态机分支
- **建议**：`Node` 的成员改成 `abstract`（或直接删掉 `Node` 这层，`?Node<T>` 换成 `?ValueNode<T>`）；删掉 `invalidated`/`busy` 与 `VALUE_NODE_INVALIDATED`；删掉 225 行的 `sleep`

### [轻微][存量] 重复逻辑：四个 `BasePool` 实现逐行对应（180 行），`SyncDeque` 内两两重复，`UnitKeyPool.remove` 与 `close` 同体

- **位置**：`f_pool/src/base/BasePool.cj:60-251`（`FifoPool` / `LifoPool` / `WeakFifoPool` / `WeakLifoPool`）、`f_pool/src/base/collection/SyncDeque.cj:123-166`（`insertHead`/`insertTail`、`prepend`/`append`）、`f_pool/src/UnitKeyPool.cj:53-59`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」「换控制流」「字面量复制」
- **证据**：静态确定 —— 四个结构体的 `add`/`giveBack`/`get`/`check`/`audit`/`close`/`size` 逐行一致，差异只有两处：deque 类型（`SyncDeque` / `WeakSyncDeque`）与入队/出队方法（`insertTail`+`append` / `insertHead`+`prepend`）；`SyncDeque.insertHead` 与 `insertTail` 只差 `head.insertNext` / `head.tail.insertPrev`，`prepend` 与 `append` 同理；`UnitKeyPool.remove` 与 `close` 函数体完全相同
- **描述**：这不是「为可读性展开」——四份实现里每一份都包含 `closed` 标志、二次检查排空、异常吞掉的销毁记账这些容易改漏的逻辑。发现 #10（`add` 缺二次检查）就是必须同步改四处的典型：现状是四处一致地漏
- **建议**：`BasePool` 抽成一个 `struct PoolCore<T, D>`（语义参数只有「deque 类型」与「头插/尾插」两个），四个别名只保留构造差异；`UnitKeyPool.remove` 直接委托 `close`（`remove(_, fn) { close(fn) }`）以消掉同体复制

### [轻微][存量] 弱引用池的值类型路径：`Box<T>` 只被 `WeakRef` 持有 ⇒ 池项可被任意一次 GC 回收，且销毁绕过 `destroier`

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:375-380`（`ref(value)`：`WeakRef<Object>(Box<T>(x), DEFERRED)`）→ `f_pool/src/base/BasePool.cj:158-204`（`WeakFifoPool`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称」；§12.1「弱引用/生命周期」；mem §4.3「`WeakRef` 不是淘汰策略」
- **证据**：静态确定 —— `Box<T>(x)` 是 `ref()` 里的临时对象，除了 `WeakRef` 之外没有任何强引用；`refDestroier` 只在「弱引用仍能解析」时调 `destroier`，被 GC 回收后 `check` 只会 `discardItem`（no-op 销毁）
- **描述**：值类型池项（`WeakFifoPool<Int64>` 之类）入池后随时可能消失，且消失时**不会**调用 `destroier`——对持有句柄的池项等于漏 close。仓库里 `Mode.WeakFifo/WeakLifo` 目前无调用方（README `9-10` 已注明），`.autocode/bugs/bug-pool-archived-20261006.md` 的 `POOL-L9` 也登记过；属潜伏问题，一旦有人按「弱引用池可以自动回收」去用就会踩到
- **建议**：值类型路径改为「`Box<T>` 由池侧强持有、只对引用类型用 `WeakRef`」，或在 `Mode` 文档/README 里明确「Weak 模式只支持引用类型池项，且不保证 `destroier` 被调用」

### [轻微][存量] 测试自身的问题：钩子用例把全局告警通道换成不 flush 的写法且无恢复 API，`pool_test` 的销毁回调直接 `println`

- **位置**：`f_pool/src/base/collection/SyncDeque_test.cj:256-288`、`297-336`（两次 `redirectWarningsTo` 收尾都用 `getStdErr().writeln` 但**不 flush**，与默认钩子 `PoolDiagnostics.cj:132-136` 的行为不同）、`244-254`（依赖全局计数变化的快照断言）、`f_pool/src/pool_test.cj:21-26`（`Test.destroy()` 里 `println('destroy …')`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可测试性 / 可维护性」；§3「标准输出占用」（模块自述「库不占应用的数据通道」）
- **证据**：静态确定 —— `SyncDeque_test` 的「收尾」只是换回一个**相似**的闭包，`hooksInstalled` 仍为 true，默认 flush 行为再也回不去；`297-336` 的用例在钩子里 `spawn` 另一线程并用 400ms 墙钟等锁，慢机上会把「钩子没占锁」误判成失败；`pool_test.Test.destroy` 无条件打印
- **描述**：这些不影响产品代码，但会让 `cjpm test` 的输出混入 `destroy …` 行、让后续用例的告警可能滞留在 stderr 缓冲里，以及让一个并发用例带墙钟依赖。`pool_test` 的类名 `Test` 与 `@Test` 宏同名，读起来也容易误判
- **建议**：给 `PoolDiagnostics` 增加 `resetDefaultHooks()`（或用 `installDefaultHooks` 暴露为 internal 测试入口），用例收尾改调它；`297-336` 改成用 `Condition`/`Future` 同步而不是 400ms 轮询；`pool_test` 的 `Test` 改名（如 `PoolTestItem`）并去掉 `println`

## 优化可行性方案

> 均无改前/改后对照数据，一律按「待验证假设」处理，不进 `todo.md` / `tasks.md`。

### [CPU] `Pool<V>` 每次 `get`/`giveBack` 都新建两个转接闭包（`UnitKeyPool.keyedChecker/keyedDestroier`）

- **现状**：`Pool<V>` 走 `KeyPool<Unit, V>` → `UnitKeyPool`，每次 `get`/`giveBack` 都在 `UnitKeyPool.cj:32-37` 现造 `{v => checker(eternity, v)}` / `{v => destroier(eternity, v)}` 两个闭包（捕获 `eternity` + 入参），`giveBack` 另外还有 `KeyPool.ref()` 的 `Ref` + 捕获 `key` 的闭包（`KeyPool.cj:580-582`）。模块自己已经为同类问题留过微基准：`KeyPool.cj:237-246` 注释「现场取方法值 39 ns + 45 B vs 复用 15 ns + 0 B」
- **方案**：让 `IKeyPool` 的 `get/giveBack` 接受「已适配的 `(V) -> Bool` / `(V) -> Unit`」（`KeyPool` 在构造期就知道键恒为 `()`，可以把 `eternity` 折进它缓存的那两个方法值，`checkOnBorrowFn` / `checkOnReturnFn`）；`UnitKeyPool` 侧按「入参函数值引用相等则复用上次的适配闭包」缓存一份即可，无需改接口
- **预期**：每次借还少 2 次闭包分配（约 90 B）。按 10 万 QPS 的编码路径推算约 9 MB/s 的分配量下降（**推算，未测**）
- **代价**：`UnitKeyPool` 增加两个缓存字段；若调用方每次传不同的 checker，缓存命中率为 0（此时退化为现状，无副作用）
- **验证**：`cjpm bench -O2` 跑 `KeyPool_test.cj:1050` 的 `KeyPoolBench`（单线程 get/giveBack）与 `Pool` 版本各 5 轮取中位数/P95；`cjprof record` 看 `UnitKeyPool.<init>`/闭包分配的采样占比
- **证据状态**：`无基线（待验证，仅有 KeyPool.cj:237-246 的 closureshape 微基准）`

### [CPU] `SyncDeque` 每次操作在锁外写两次原子（`lastOp.store` + `opCount.fetchAdd`），只为诊断

- **现状**：`insertHead/insertTail/prepend/append/remove/check` 六个入口各做一次 `lastOp.store(n)`（`SyncDeque.cj:124/134/144/156/199/318`）与一次 `opCount.fetchAdd(1)`（`72-75`，用于每 1e4 次触发 `selfCheck`）。这两次 RMW 都在临界区之外、且与随后必然要拿的 `head.globalLock` 保护的同一批状态无关；多核下它们落在同一个 cache line 上，是与 `s`/`out`/`nodes` 同类的争用点
- **方案**：把 `lastOp` 改成锁内普通字段（只在 `selfCheck`/`reconcileIfWedge` 的告警文案里用，允许粗粒度）；`opCount` 改成锁内普通 `Int64`（或仅在 `selfCheck` 采样开关打开时才原子自增）
- **预期**：每次借还少 2 次全局原子 RMW；高并发下减少一点 cache line 乒乓（**推算，未测**）
- **代价**：`selfCheck` 的采样计数在并发下可能少计（诊断精度换 CPU）；`selfCheck` 本身仍在锁内读 3 个原子，保持不变
- **验证**：32 线程 × 1024 池项的 get/giveBack 压测，`cjpm bench -O2` 改前/改后对照吞吐与 P99（各 5 轮）；`cjprof` 看 `Atomic*` 的自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SyncDeque.head.globalLock` 是 `Pool<V>` 借还的唯一串行点（单 deque），高并发下是吞吐上限 | `SyncDeque.cj:37`、`123-166`、`198-235` | 锁等待时长、BLOCKED 线程数、吞吐随线程数的曲线 | 8/32/128 线程压同一个 `Pool<Object>`（maxSize=1024），跑 10 分钟；`cjprof` 取线程状态，另加 `Mutex` 等待计时埋点 |
| 2 | 巡检每轮遍历全部池项、每节点一次 `sleep(Duration.Zero)`，大池单轮耗时被拉长 | `SyncDeque.cj:317-350` | 单轮 `pool.check` 耗时 vs 池项数 | 建 1k/1w/1e5 项的池，量两次 `audit` 之间的实际间隔与单轮耗时（`MonoTime` 埋点） |
| 3 | `ValueNode.prevForChecking` 在 `synchronized(globalLock)` 内 `sleep(Duration.Zero)`，会在锁内让出，形成锁持有尖刺 | `LinkedNode.cj:216-224` | 该分支命中率与锁持有时间分布 | 构造「队尾节点非 idle」的场景（`strandHeadForTest`）压测，量 `get` 的 P99 与锁等待 |
| 4 | `UnitKeyPool` 每次借还的两个闭包分配在 f_codec 编码热路径上占 GC 分配量一成以上 | `UnitKeyPool.cj:32-37`、`KeyPool.cj:580-582` | 分配采样占比、GC 次数 | `cjprof record` 跑编码 100 万条小消息，看闭包/`Ref` 分配占比（同第 1 部分假设 7，这里是 `Pool<V>` 路径的对应项） |
| 5 | `FifoPool.close` 在 1e5 项量级上的关闭耗时被「每节点一次 yield」主导 | `BasePool.cj:96-102`、`SyncDeque.cj:337` | 关闭耗时 vs 池项数 | 先灌满 1e5 个 8KB 缓冲再 `close()`，分段计时；对照去掉 `sleep` 的临时构建 |
| 6 | `selfCheck` 每 1e4 次操作在锁内读 3 个原子 + 一次 `%` 运算，在多核下可观测 | `SyncDeque.cj:72-91` | 自检触发的单次耗时与占比 | `cjprof` 看 `selfCheck` 自耗时；把采样间隔从 1e4 调到 1e6 做对照 |

## 文件覆盖

> 与 `files/f_pool.part2.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_pool/src/UnitKeyPool.cj` | .cj | ✅ | 见发现 #1（`remove` 与 `close` 同体导致 get 空转）、#9（`keyCount` 契约）、#12（remove/close 同体） |
| 2 | `f_pool/src/base/BasePool.cj` | .cj | ✅ | 见发现 #4（close 契约不闭合）、#10（`add` 缺二次检查）、#12（四份实现重复）、#13（弱引用池） |
| 3 | `f_pool/src/base/collection/LinkedNode.cj` | .cj | ✅ | 见发现 #11（`invalidated`/`busy` 死代码、`open`+throw、不可达 `sleep`）；`check` 的异常安全路径与注释一致 |
| 4 | `f_pool/src/base/collection/SyncDeque.cj` | .cj | ✅ | 见发现 #2（异常路径计数）、#3（`checkers` 泄漏）、#4（CHECKING 节点逃过 close）、#7（告警前缀）、#12/#13；记账不变量 `s ≡ nodes + out` 逐路径核对通过（插入/取走/归还/丢弃/巡检摘除） |
| 5 | `f_pool/src/base/collection/SyncDeque_test.cj` | .cj | ✅ | 22 个用例，覆盖 checker/destroier/taskPusher 抛异常、滞留自救、钩子不在锁内、`nodes` 不漂移；见发现 #14（钩子恢复与墙钟依赖） |
| 6 | `f_pool/src/base/logger.cj` | .cj | ✅ | 单例 `LoggerFactory.getLogger('fountain::f_pool')`，与基线 §6 一致（无 println） |
| 7 | `f_pool/src/byteslist_clear_test.cj` | .cj | ✅ | 1 个用例，断言 `clearOnReturning` 生效；与 `BytesListOutputStream` 的契约一致，无问题 |
| 8 | `f_pool/src/diagnostics/PoolDiagnostics.cj` | .cj | ✅ | 见发现 #4（致命信号处理器）、#6（钩子数据竞争）、#7（首轮误报）、#8（退出统计走钩子）；计数钩子逐个搜过引用，全部有调用方 |
| 9 | `f_pool/src/exception/ClearFailedException.cj` | .cj | ✅ | `key: Any` 公开字段 + suppressed 语义与 `KeyPool.giveBack` 一致，无问题 |
| 10 | `f_pool/src/exception/PoolException.cj` | .cj | ✅ | 仅 `message` 构造，无问题 |
| 11 | `f_pool/src/exception/UnknownKeyException.cj` | .cj | ✅ | 与 `BaseKeyPool.giveBack` 的抛出口径一致；文档示例中的 `addSuppressed` 用法可编译（`f_base.BaseException` 已提供） |
| 12 | `f_pool/src/imports.cj` | .cj | ✅ | `internal import fountain::f_pool.base.*`，被 `KeyPool`/`Mode`/`UnitKeyPool` 使用，无问题 |
| 13 | `f_pool/src/local_buffer_cache_test.cj` | .cj | ✅ | 3 个用例（同线程命中、`maxLocal=0` 不命中、跨线程归还后仍命中）；`LocalBufferCache` 用 `Mutex` 保护本地栈，无关并发问题 |
| 14 | `f_pool/src/pool.cj` | .cj | ✅ | `Pool`/`PoolBuilder`/`ObjectManager`/`InitKeyIterator`；`clear` 透传注释与实现一致；见发现 #14（`pool_test`，本文件本身无缺陷） |
| 15 | `f_pool/src/pool_concurrency_test.cj` | .cj | ✅ | 2 个用例：借空后 `size` 一致、8 线程 × 2000 次借还断言缓冲为空；`sleep(2s)` 等异步建池属测试脆弱性，未单列 |
| 16 | `f_pool/src/pool_test.cj` | .cj | ✅ | 1 个用例（3 段：非阻塞 get、容量上限、空闲回收后重建）；见发现 #14（`Test.destroy` 的 println） |
| 17 | `f_pool/src/releasable_test.cj` | .cj | ✅ | 5 个用例（release 幂等、级联释放、copy 失败仍归还、release 后读写抛 `IllegalStateException`）；与 `BytesListOutputStream` 契约一致 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1/#2/#3/#10，设计 #4（进程级副作用）/#5（契约不闭合）；语言特性上核对了 `struct` 持有引用字段的复制语义（`FifoPool`/`SyncDeque` 全字段为引用或原子，复制不产生状态分叉）、`??` 的短路求值（`PoolBuilder.build` 不会误抛）、`AtomicBool.compareAndSwap` 参数顺序；无外部输入拼接、无凭据、无注入面 |
| §1 死代码 | 2 | `VALUE_NODE_INVALIDATED` / `prop invalidated` / `setInvalidated` / `prop busy` 全仓零引用；`LinkedNode.cj:225` 的 `sleep` 不可达（#11）。逐个核过：`DEQUE_OP_NAMES`、`opCount`、`lastOp`、`refChecker`/`refDestroier`、`strandHeadForTest`、`PoolDiagnostics` 的 12 个计数钩子均有调用方；`Node` 的 6 个基类成员无多态调用点（合并进 #11）；`UnitKeyPool`/`SyncDeque`/`WeakSyncDeque` 的 `public` 成员均为接口实现或包内被调用，不判死代码 |
| §2 重复逻辑 | 1 | 同文件内把 30 余个函数体压成「输入 → 输出 → 副作用」两两比对：`BasePool` 四份实现逐行对应、`SyncDeque` 两对入队/归还方法、`UnitKeyPool.remove`/`close` 同体（#12）；`PoolDiagnostics.onItemAdded` 等在 `insertHead`/`insertTail` 各出现一次属必要（两个入口） |
| §3 空实现 | 1 | `Node` 用 `open` + `throw UnreachableException` 充当抽象默认实现（#11）；`ObjectManager.clear` 默认空体有 README 说明（Null Object，不算问题）；Windows 版 `installCrashHandler`/`uninstallCrashHandler` 空体有 `@When` + 注释说明；`close`/`check` 传空 `taskPusher` 是关停语义，非空实现 |
| §4 栈溢出 | 0 | 逐个追过：`HeadNode.nextForGet` → `ValueNode.nextForGet`（循环）、`TailNode.prevForChecking` → `ValueNode.prevForChecking`（循环），递归深度恒为 1；`Node` 无自引用遍历；`doRemove`/`reviveNonIdle`/`countNodes` 均为迭代；`InitKeyIterator` 是计数器 |
| §5 OOM | 0 | 无「按不可信长度预分配」：`ArrayBlockingQueue` 容量已夹在 `[1, 1024]`（`KeyPool.cj:32-43`）；`SyncDeque` 节点数受 `maxSize`/`totalSize` 限；`BaseKeyPool.close` 的键快照与 `map` 同阶（不是新增无界容器）；键表的无界性由文档明确交给应用 `remove(key)` 管理，本轮不计为缺陷 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；锁竞争、巡检遍历、闭包分配、原子写全部降级为「待验证假设」1-6 |
| §6.2 大粒度锁 | 0 | 逐处核对临界区：`head.globalLock` 内只有链表指针改写 + `s/out/nodes` 原子、`countNodes` 遍历与 `doRemove`；`checker` / `destroier` / 告警钩子全部在锁外（`SyncDeque_test.cj:297-336` 有用例证明），不存在「锁内 I/O / 回调」；`prevForChecking` 里有一次锁内 `sleep` 已单列为假设 3 |
| §6.3 并发串行 | 0 | 线索两条：`Pool<V>` 只有一个 deque（借还串行化）、每个 `KeyPool` 只有 1 个创建线程。无并行度/串行段占比数据，按铁律只进「待验证假设」1 |
| §6.4 低效算法 | 0 | 无 `remove(at: 0)` 当队列（`LocalBufferCache` 是尾部删除 O(1)）、无嵌套循环匹配、无循环内字符串拼接；`reconcileIfWedge` 的 O(n) 实走只在「取不到项」/每分钟一次，`selfCheck` 已降为 O(1)；巡检每节点一次 yield 已单列为假设 2 |
| §7 降堆内存方案 | 0 | 本部分没有可量化的常驻/峰值削减项：节点数受 `maxSize` 限、`ValueNode` 的 3 个原子容器相对 8KB 池项可忽略、`BaseKeyPool.close` 的键快照是瞬时的；唯一候选（`entries()` 每次分配 1 元素数组）量级太小，不列方案 |
| §8 降 CPU 方案 | 2 | 方案 1（`UnitKeyPool` 每次借还两个闭包）、方案 2（`SyncDeque` 锁外两次原子写）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选都不满足「函数内创建、函数内释放」：`countNodes` 的元组是返回值、`reconcileIfWedge` 的 `healed` 字符串进告警、`UnitKeyPool.entries()` 的数组逃逸为返回值、`snapshot()` 的字符串作为返回值；且这些都不在热点分配路径，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | #1（remove 后空转）、#2（异常路径计数漂移）、#3（`checkers` 泄漏）、#4（close 契约）、#5（close/check 交错）、#9（keyCount 契约）、#10（add 竞态窗口）、#13（弱引用值类型）；另核对了 `SyncDeque` 的 `s ≡ nodes + out` 六条路径、`markReturned` 的钳位（全部调用点都在同一把锁内，无竞态）、`ValueNode.check` 的异常还原、`Pool` 侧 `FifoPool.size` 含借出项的语义，均无缺陷 |
| §12 并发安全与锁粒度 | 4 | 已证明安全：`closed`/`s`/`out`/`nodes`/`opCount`/`lastOp`/`checkers` 全为原子且复合更新都在 `head.globalLock` 内；`reconcileIfWedge` 的「无 check 在飞」判据与 `check` 的 `checkers` 协议自洽（除 #3）。命中：#2（计数一致性）、#3（自愈被永久关闭）、#6（钩子可见性）、#7（报告去重竞态）；锁粒度见 §6.2 结论 |
| §14 功能完备性与 README 覆盖 | 1 | `PoolDiagnostics` 的公开面（`snapshot`/`dump`/`redirectWarningsTo`/`installCrashHandler`/`uninstallCrashHandler`/`CRASH_DUMP_ON_FATAL`）README `345-350` 已列；但 README 未提示「首次建池即**默认安装**进程级致命信号处理器、会覆盖宿主处理器」这一副作用，也没有「`CRASH_DUMP_ON_FATAL` 是 const、无法配置」的说明（#4）。README 本体属第 1 部分文件，其余文档一致性问题以第 1 部分为准 |
| 文件覆盖（§13 等） | 17/17 | 本部分无 `.md`（README 两版在第 1 部分）；17 个 `.cj` 全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

## 总评

本部分是全模块的「底座」：`SyncDeque` 的记账不变量（`s ≡ 节点数 + 借出数`）、异常安全（checker/destroier/taskPusher 三条抛出路径都要么还原状态要么结清）、以及「告警钩子绝不在锁内调用」这三件事做得比一般池库细，注释里带着失败案例编号，`SyncDeque_test` 有 22 个用例专门盯这些历史症状。主要问题集中在**底座与上层之间的计数/关闭协议**，不在链表本身：

- 值得排期的三条 一般：#1（`KeyPool<Unit,V>.remove(())` 之后 `get` 以 creator 速度空转 30s，公开 API 可达）、#2（checker 抛异常时上层 `s` 只靠巡检自愈）、#3（`checkers` 一次异常泄漏就永久关掉自愈）。#1 是唯一会让业务侧直接看到「连接风暴 + 30s 超时」的路径，#2/#3 属于「异常之后的可用性塌陷」，都不是崩溃级，但会让池在最需要兜底的时候失去兜底。
- #4（默认接管 SIGSEGV/SIGABRT 且在信号上下文里分配/IO/`exit`）更像一个「收益自述为零、副作用一直在」的开关：既然文件自己写了实测不会触发，默认值应改为 false。
- 轻微项里 #10（`add` 缺二次检查）与 #4（`close` 跳过 CHECKING 节点）是同一个主题：`BasePool` 的关闭语义只在「上层 checker 恰好把项判失效」时才完整。它们现在不可达，但只要有人直接使用 `BasePool`（它是 `protected package` 里的公共实现层，`BaseKeyPool_test` 就在直接调 `add`）就会漏 `destroier`。
- 死代码与重复逻辑都有明确结论：#11 是 `LinkedNode` 的状态机残留 + 一层没有多态调用点的抽象；#12 是四份 `BasePool` 实现（180 行）与两对 `SyncDeque` 方法，改一处必须同步改四处。这两项不改也不出错，但会放大后续任何修复的成本。
- 性能与内存：本部分没有任何 profile / bench 数据，两条 CPU 方案与六条假设全部标 `无基线（待验证）`，不进修复清单。最值得下一轮补数据的是「单 deque 的锁竞争」（假设 1）与「大池巡检/关闭的逐节点 yield」（假设 2、5）。
- 已确认**没有**的问题：栈溢出（§4）、锁内回调与死锁（§6.2）、OOM（§5）、local mode（§9，候选对象全部逃逸）、`s ≡ nodes + out` 的记账路径。

存量缺陷共 14 条（严重 0 / 一般 4 / 轻微 10），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
