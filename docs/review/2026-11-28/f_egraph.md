# f_egraph 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_egraph`（58 个文件：50 个 .cj + 8 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_egraph.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] README 手抄的 API 声明块已与源码漂移：签名不全、类型写错、修饰符写错

- **位置**：
  - `f_egraph/README.md:159-165`（`Event` 构造器）、`:181-188`（`DataEvent` 构造器）——均缺 `priority` / `birth` / `cancelPrev`
  - `f_egraph/README.md:388`（`TaskExecutor`）、`:423`（`AsyncTaskExecutor`）——`task` 形参写成 `(Event) -> Unit`
  - `f_egraph/README.md:635`、`:639`——`BaseFlow.remove()` / `removeExceptCurrentTag()` 写成 `static func`
  - 英文同构：`f_egraph/README_en.md:162-168`、`:186-193`、`:397`、`:432`、`:651`、`:655`
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §13（API / 默认值与源码不符；示例代码不能用）
- **证据**：静态确定 ——
  1. `f_egraph/src/base/Event.cj:27-36` 的 `public Event(...)` 含 `priority!: Int64 = 2`、`birth!: DateTime = DateTime.now()`、`cancelPrev!: Int64 = 0`，且构造器对 `priority < 0` / `cancelPrev < 0` 抛 `GraphException`（`:37-42`）；`DataEvent` 在 `:60-70` 有同名三个形参并逐个转发。README 两个构造器块都只到 `session` 为止。
  2. `f_egraph/src/base/TaskExecutor.cj:26` 与 `f_egraph/src/base/AsyncTaskExecutor.cj:26` 的形参是 `task!: (Event) -> Event`。README 写成 `(Event) -> Unit` 后，同一段代码块里的 `accepter.accept(task(event))`（`README.md:415`）自相矛盾——`Unit` 不是 `Event`；`AsyncTaskExecutor` 的 `init` 又把这个 `task` 原样转给 `TaskExecutor`（`README.md:424`），类型错误会一路传到真实构造器。
  3. `f_egraph/src/base/Flow.cj:20-21` 是实例方法 `func remove(): Unit` / `func removeExceptCurrentTag(): Unit`；同一份 README 的 `ImmediateFlow`（`:712-713`）与 `AsyncFlow`（`:745-746`）块也写作实例方法，只有 `BaseFlow` 块加了 `static`。
- **描述**：`f_egraph` 是给下游项目用的库，README 就是对外契约。按当前 README：实现自定义执行器会因函数类型不匹配而编译失败；`BaseFlow.remove()` 这种静态调用不存在；`Event` / `DataEvent` 的新字段（优先级、撤销、出生时间，是 `QueuedClosureTask` 全部语义的输入）在构造器文档里完全看不到，也没有任何"这三个参数非法会抛异常"的说明。
- **建议**：以 `src` 为准重写这三处（补 3 个形参与默认值、`task` 改 `(Event) -> Event`、去掉 `static`），中英同步。根治办法是把 README 的逐字声明块改成「签名要点 + `src/` 链接」：本次漂移本身就是"手抄副本没跟上源码"的证据（同文件 `:913` 已列出 `priority/birth/cancelPrev`，与 `:159-165` 的构造器块互相矛盾）。

### [一般][存量] `StartExecutor` / `EndExecutor` 的行为描述与实现相反

- **位置**：`f_egraph/README.md:322-324`（`accepter.accept(Task)`）、`:332`（"返回事件包含的数据"）；`f_egraph/README_en.md:329-331`、`:339`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（文档承诺与实现相反；示例跑不通）
- **证据**：静态确定 ——
  1. `f_egraph/src/base/StartExecutor.cj:23-31`：收到 `DataEvent` 时**把它重建成同名、同数据的 `TaskEvent`** 再投递给第一个任务执行器；非 `DataEvent` 抛 `GraphException`。README 的 `accepter.accept(Task)` 里 `Task` 是接口（`src/base/Task.cj:22`），`Accepter.accept` 只接受 `Event`（`src/base/Accepter.cj:19`），该行既不能编译，也没有表达"Start → Task 的类型改写"。
  2. `f_egraph/src/base/EndExecutor.cj:23-31`：`get(): Event` / `tryGet(): ?Event` 返回的是**收到的 `Event` 本身**，不是"事件包含的数据"。
- **描述**：`StartEvent` → `TaskEvent` 的类型改写是流程能跑起来的关键：dispatcher 以整个 `Event` 为键查执行器（`src/base/ImmediateDispatcher.cj:109-111`、`:59-63`），而 `Event.==` / `hashCode` 计入 `eventType`（`src/base/Event.cj:44-49`），开始执行器登记的是 `Start` 键、第一个任务登记的是 `Task` 键。README 隐去这层改写，读者会以为任务执行器直接收到 `StartEvent`，从而错误地实现任务体或自行转换。
- **建议**：两段代码块换成真实签名，并各加一句行为说明：「`StartExecutor` 把 `StartEvent` 改写为 `TaskEvent`（同名同 data）」「`EndExecutor` 保存并返回收到的 `Event`，取数据请自行 `tryGet<T>()`」。

### [一般][存量] `AsyncFlow` 的 dispatcher 被写成实例成员，实际是进程级静态单例；`get()` 的阻塞语义与清理线程生命周期未文档化

- **位置**：`f_egraph/README.md:739-741`（"AsyncDispatcher 是本类型的实例成员变量……一个 AsyncFlow 实例会维持多个流程"）、`:472`（"得到结束执行器，如果没有就抛出异常"）、`:528-531`；`f_egraph/README_en.md:759-761`、`:482`、`:542-546`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（契约与实现不符）+ §12.1（并发契约必须明确）
- **证据**：静态确定 ——
  1. `f_egraph/src/base/AsyncFlow.cj:19-22`：`private static var dispatcher = None<AsyncDispatcher>`，`initDispatcher` 每次都 `AsyncDispatcher(...)` **覆盖全局**；所有 `AsyncFlow` 实例共用它（`:96-98`、`:142-155`）。文档说的"实例成员变量"与"一个实例维持多个流程"都不成立。
  2. `f_egraph/src/base/AsyncDispatcher.cj:88-99`：`get()` 在 `endCondition.wait()` 上**无超时阻塞**，只有另一线程 `notifyEnd`（`:136-141`）后才可能返回，取不到再 `getOrThrow`；文档只写"如果没有就抛出异常"，读者会以为是无结果立即失败。
  3. `f_egraph/src/base/AsyncDispatcher.cj:32-39`：构造器里 `spawn` 一个 `while(true) { end.removeIf(...); sleep(clearTimerDuration) }` 的常驻线程；文档只写"增加一个清除线程，定时清除"，没写它随实例创建、永不退出，重复 `initDispatcher` 会再起一个。
- **描述**：按 README 使用会踩三个坑：(1) 两个模块各自 `initDispatcher` 时后者的 dispatcher 覆盖前者，先前 `register*` 的流程再也收不到事件（`AsyncFlow` 的 `register*` 每次都读全局，但已登记的 executor 留在旧 dispatcher 里），表现为运行期 `No executor found for event`，与配置错误无关；(2) 没有结束事件时 `get()` 不是"抛异常"而是无限阻塞，`tryGet(timeout!)` 的存在意义因此也没被写出来；(3) 每次 `initDispatcher` 泄漏一个永不退出的线程（源码侧影响归第 3 部分）。
- **建议**：README 明写「dispatcher 是进程级单例，最后一次 `initDispatcher` 生效，只能在启动期调用一次」「`get()` 阻塞到有结果，无内置超时，需要超时用 `tryGet(timeout!)`」「每个 `AsyncDispatcher` 实例带一个常驻清理线程」。若认为全局单例语义本身有风险，属设计变更，需用户拍板。

### [一般][存量] README 未声明 `MultiEvent.name` 必须是 `"Multi"`，照文档构造的 Multi 事件会被调度器拒绝

- **位置**：`f_egraph/README.md:128-131`（`EventType.Multi` 注释）、`:243-248`（`MultiEvent` 构造器）；`f_egraph/README_en.md:130-133`、`:250-255`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13 + §14.2（关键约束缺失，按文档用会失败）
- **证据**：静态确定 ——
  1. 流程构造期登记的 Multi 任务，acceptable 事件是 `(eventType = Multi, category, tag, name = "Multi")`（`src/base/ImmediateDispatcher.cj:64-68`，`name: EventType.Multi.toString()`）。
  2. 分发按整个 `Event` 查表（`src/base/ImmediateDispatcher.cj:77-86`、`:109-111`），`Event.==` / `hashCode` 计入 `name`（`src/base/Event.cj:44-49`），所以 `name != "Multi"` 的 `MultiEvent` 永远匹配不到，落 `GraphException("No executor found for event: ...")`（`:85`）。
  3. `MultiEvent` 构造器接受任意 `name`（`src/base/Event.cj:104-109`），不做校验。
  4. 同一变更的规格自己写了这条约束：`doc/spec/f-egraph-jit-flow-init/specs/f-egraph-flow-script/spec.md:84-85`「`MultiEvent` 的 name SHALL 为 `EventType.Multi.toString()`，否则不会被本流程接收」，README（对外文档）却没有。
- **描述**：README 的 `EventType.Multi` 注释说"多个事件会合并成一个Multi事件，Multi事件会发送给下一个任务执行器"，暗示合并是自动的；实际是**任务体自己构造 `MultiEvent`，且 name 必须固定为 `"Multi"`**（`QueuedClosureTask` 自己造的批处理 `MultiEvent` 用的是批次事件名，它是给任务体消费、不进 dispatcher，不构成反例）。宿主按 README 写 `MultiEvent(category, tag, "batch", events)` 会让整个流程在分发处中止。
- **建议**：`MultiEvent` 段与「流程脚本契约 / 约束」各加一条 name 约束；示例给 `name: EventType.Multi.toString()`；`README_en.md` 同步。同时改写 `EventType.Multi` 的中英文注释，说明"合并"的实际发生位置。

### [一般][存量] 公开 API 与新增的优先级队列能力在 README 只有名字、没有语义

- **位置**：`f_egraph/README.md:903-914`（"其他公开 API"）；`f_egraph/README_en.md:922-933`；缺失面：`Flow.registerTask(task: BarrierTask<G>)`、`ConcurrentEndExecutor` 全部方法、`BarrierKey` 三个字段、`EmptyEvent`、`Event.priority/birth/cancelPrev`、`QueuedClosureTask`、`getDispatcher`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 缺关键段落）+ §13
- **证据**：静态确定 ——
  - `src/base/Flow.cj:62-66` 的 `func registerTask(task: BarrierTask<G>): Unit`（接口默认方法，对外可达）在两版 README 全文没有这个重载：`grep -n "BarrierTask" README.md` 只命中 `94`（"不支持 JIT"）、`581/586/594`（类本身）、`847`（同前）。
  - `ConcurrentEndExecutor` 只在 `README.md:907` 的类型清单出现一次；`execute` / `get()` / `get(timeout!)` / `tryGet()`（`src/base/ConcurrentEndExecutor.cj:26-56`）零文档。
  - `BarrierKey` 只写了 `let eventName`（`README.md:908`），实际 `category` / `tag` / `eventName` / `session` 四个 `public let`（`src/base/BarrierTask.cj:20-25`），且它是 `BarrierTask` 的聚合键。
  - `EmptyEvent` 只列类名（`README.md:910`），构造参数与"取消指令"语义未写（`src/base/Event.cj:112-128`：`cancelPrev > 0` 删除队列中前面 N 条同名同优先级事件、自身不执行）。
  - `Event.priority` / `birth` / `cancelPrev` 只在 `README.md:913` 列名字；`priority = 0` 抢占并合并、`1` 等当前结束再合并、`>= 2` 逐条执行（`src/base/QueuedClosureTask.cj:24-38`）只存在于源码注释。
  - `QueuedClosureTask` 的 7 个成员（`README.md:914`）只列签名；`exec` 会自动"入队 + 消费队列 + 结果回灌 dispatcher"（`src/base/QueuedClosureTask.cj:64-74`）、`runNext`/`drain` 的驱动模型均无说明。
  - `ImmediateFlow.getDispatcher()` / `AsyncFlow.getDispatcher()`（`src/base/ImmediateFlow.cj:76-80`、`src/base/AsyncFlow.cj:96-98`）只列名字，未写返回类型与"自驱动任务回灌"的用途。
  - 脚本面拿不到这些能力，README 的约束清单也没写：`src/base/JitHostRegistry.cj:114-125` 只注册 8 个事件类（不含 `EmptyEvent`），`flowMethods`（`:199-218`）没有 `priority` / `cancelPrev` 入口。
- **描述**：README 开头自称"下面所有的顶级声明都是重导出"，等于承诺它是完整契约；但一个 `public` 类（`QueuedClosureTask`）与一组决定队列行为的字段（`priority` / `cancelPrev` / `EmptyEvent`）只有源码头注释。使用者按 README 无法知道 `priority = 0` 会抢占、`cancelPrev` 撤销的是哪几条、`QueuedClosureTask` 由谁调 `runNext`，也不知道脚本面故意没暴露这些能力。
- **建议**：新增一节「优先级队列与取消」，把 `QueuedClosureTask`、`Event.priority/birth/cancelPrev`、`EmptyEvent` 一起写清（三段 priority 语义、两条取消规则、`runNext`/`drain` 的驱动方、`generation`/`cancelledCount` 的观测用途）；`ConcurrentEndExecutor`（带超时的等待结束器）、`BarrierKey`、`getDispatcher`、`BarrierTask` 重载各补一句语义；「约束」补"队列能力仅宿主侧可用，脚本面未暴露"。属文档补充，不改代码。

### [一般][存量] README 没有并发 / 线程安全段落，而模块的核心状态是进程级共享的

- **位置**：`f_egraph/README.md` 全文（`grep -n "线程安全\|并发\|thread\|concurrent" README.md` 零命中，仅代码块内的 `ConcurrentHashMap` 类型名出现）；`f_egraph/README_en.md` 同
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（关键段落缺失）+ §14.2（缺"限制与注意事项"）+ §12.1（并发契约必须明确）
- **证据**：静态确定 —— 实现侧的共享状态与同步手段是分散的：`ImmediateFlow` / `AsyncFlow` 用静态 `ConcurrentHashMap` / `ConcurrentHashSet`（`src/base/ImmediateFlow.cj:19-20`、`src/base/AsyncFlow.cj:19-23`、`:73`）；`AsyncFlow.dispatcher` 是裸 `static var`（`src/base/AsyncFlow.cj:19`，`:21` 直接赋值，无同步）；`AsyncDispatcher` 用 `Mutex` + `Condition` + 后台线程（`src/base/AsyncDispatcher.cj:19-39`）；`QueuedClosureTask` 用 `Mutex` 保护队列与执行态（`src/base/QueuedClosureTask.cj:40-48`）；而 `ImmediateFlow.startName` / `hasFirstTask` 是普通实例字段（`src/base/ImmediateFlow.cj:81-82`），`registerTask` 读改写没有同步（`:93-102`）。
- **描述**：使用者无法从文档判断「`registerStart` 能否与 `start` 并发」「`AsyncFlow.initDispatcher` 能否在运行期调用」「`ImmediateFlow` 能否跨线程共享」「`EndExecutor.tryGet` 的可见性由谁保证」。这类缺失直接导致宿主在启动并发下写出竞态（典型如并发 `initDispatcher` 与 `getDispatcher().getOrThrow()` 交错）。对本模块尤其重要：`f_egraph` 的定位是流程执行器，而流程注册发生在启动期、事件投递发生在运行期，两个阶段能不能重叠，文档必须表态。
- **建议**：加一节「并发与生命周期」，逐项声明：注册类方法（`register*` / `remove*` / `initDispatcher`）只允许启动期单线程调用；`start` / `accept` 可多线程但同一流程的事件顺序不保证；`AsyncDispatcher.get()` 阻塞且无超时；`ImmediateFlow` 不可跨线程并发注册。源码侧实际竞态由第 3 部分判，本节只要求文档如实声明契约。

### [轻微][存量] 事件字段与 Dummy 语义的描述与实现不符

- **位置**：`f_egraph/README.md:156`（"只有任务事件拥有名字"）、`:133-135`（Dummy"调度器会忽略这类事件"）、`:456`（"一个流程可以有大于等于一个开始事件执行器"）；`f_egraph/README_en.md:159`、`:135-137`、`:466`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（语义与实现不符）
- **证据**：静态确定 ——
  1. `src/base/Event.cj:76-81` 的 `StartEvent` 的 `name` 就是开始事件名（README 自己在 `:197` 要求它等于首个任务的事件名）；`src/base/Event.cj:104-109` 的 `MultiEvent` 的 `name` 由调用方给出并参与路由（见上一条发现）。"只有任务事件拥有名字"不成立。
  2. `src/base/Event.cj:123-128` 的 `EmptyEvent` 也是 `EventType.Dummy`，但 `src/base/ImmediateDispatcher.cj:75` 只跳过 `event is DummyEvent`；`EmptyEvent` 投进 dispatcher 会走"无执行器"分支抛 `GraphException`（`:85`）。"调度器会忽略这类事件"只对 `DummyEvent` 实例成立。
  3. `README.md:456` 注释写的是"注册任务事件执行器，一个流程可以有大于等于一个开始事件执行器"，被注释的函数是 `registerTask`，应为"任务事件执行器"。
- **描述**：三处都属措辞层面，但都会把排查带偏：`StartEvent`/`MultiEvent` 的 `name` 是路由键的一部分；`EmptyEvent` 虽是 Dummy 类型却不是被忽略的哑事件。
- **建议**：逐句改写；Dummy 那句改成"`DummyEvent` 实例会被调度器跳过；`EmptyEvent` 也是 `Dummy` 类型，但它是队列取消指令，不跳过"。

### [轻微][存量] `design.md` 与 `spec.md` 对「末句不是 `Unit`」的失败时机自相矛盾

- **位置**：`f_egraph/doc/spec/f-egraph-jit-flow-init/design.md:176-177`（"末条语句不是 `Unit` 时 `call<Unit>` 在**编译期**报类型不符"）vs `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-flow-script/spec.md:22-26`（"`compile` 仍可成功，但 `call<Unit>([])` SHALL 在**调用期**抛 `JitException`"）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（规格与实现漂移；同一变更的两份规格自相矛盾）
- **证据**：静态确定 —— `f_jit/src/JitFunction.cj:568-577`：`T` 与 `retType` 的一致性在 `callLocked` 里校验，不一致走 `contractFail`（抛 `JitException`，`ErrCode.CALL_CONTRACT`），即**调用期**；编译期只确定块内最后一条表达式的类型。`spec.md` 与实现一致，`design.md` 的"编译期"是错的。
- **描述**：实现者按 `design.md` 写测试会去断言一个不存在的编译期错误；`spec.md` 的措辞才是可实现、可验证的口径。这也影响 `FlowScriptRunner` 的错误分类（初始化期失败来自 `JitException` 而非编译异常）。
- **建议**：`design.md:176-177` 改为"`call<Unit>([])` 在调用期因返回类型不符抛 `JitException`"，与 spec 和实现一致。

### [轻微][存量] `design.md` 的实施回填称 `ImmediateFlow.getDispatcher` 为 `private`，实现与 README 都是 `public`

- **位置**：`f_egraph/doc/spec/f-egraph-jit-flow-init/design.md:531-533`（"`ImmediateFlow.getDispatcher()` 由隐式 `Unit` 改为返回 `ImmediateDispatcher`（`private`，不影响公开签名）"）；对照 `f_egraph/src/base/ImmediateFlow.cj:76`（`public func getDispatcher()`）、`f_egraph/README.md:912`（列为公开 API）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— 实现是 `public`，`AsyncFlow.getDispatcher()`（`src/base/AsyncFlow.cj:96`）同样是 `public`；README 的"其他公开 API"两项都收录了。
- **描述**：回填文本与实际相反，而且"不影响公开签名"的结论也随之不成立——把它做成 `public` 确实扩大了公开面（多了一个可直接取 dispatcher 的入口）。这属于"文档记录与落地形态不一致"，会让后续维护者以为它还是包内实现细节。
- **建议**：修正 `design.md` 的回填文字；若设计意图确实是包内可见，则改成 `internal` / `private` 并从 README"其他公开 API"移除——这是可见性变更，需用户确认没有下游在用。

### [轻微][存量] `ClosureTask` 的事件列表校验口径与 README 承诺不一致，空串元素可以静默通过

- **位置**：`f_egraph/README.md:798-800`、`f_egraph/README_en.md:819-821`（"`name`、两个事件列表、`exec` 去空白后为空 → `GraphException`"）；对照 `f_egraph/src/base/ClosureTask.cj:91-118`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（文档承诺的校验与实现不符）
- **证据**：静态确定 —— `compile` 只对 `name`（`:93`）与 `exec`（`:98`）做 `trimAscii().isEmpty()` 判断；`stringEvents`（`:107-118`）只判 `values.size == 0` 与元素 `is String`，**不对元素 trim**，所以 `[""]`、`["  "]` 都能通过。
- **描述**：`compile("t", [""], ["b"], "flowDummyEvent()")` 会被接受。若这是首个任务，`registerTask` 会抛"First TaskExecutor name must be same as StartExecutor name"（`src/base/ImmediateFlow.cj:94-100`），错误信息指向顺序问题而非空事件名，排查成本高；若不是首个任务，则会静默登记一个 `name=""` 的永不触发执行器（`src/base/ImmediateDispatcher.cj:59-63` 按名查表），属于"写了但不生效"。
- **建议**：二选一——在 `stringEvents` 里对每个元素 trim 后判空并抛 `GraphException`（与文档一致，推荐），或把 README 改成"列表为空即抛"并同时说明元素不做空白校验。

### [轻微][存量] README 同一段流程脚本示例重复两处，已出现注释口径分叉

- **位置**：`f_egraph/README.md:45-62` 与 `:816-833`；`f_egraph/README_en.md:45-62` 与 `:840-855`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（重复逻辑，文档形态；判据是「语义相同、维护两份」）
- **证据**：静态确定 —— `grep -n "^let flow = ImmediateFlow" README.md` → `48`、`820`；两段均为 18 行，仅第二段首行多一句行尾注释（`// 或 AsyncFlow("order", "v1")`），其余逐字相同；中文版与英文版各自重复一对。
- **描述**：示例是"契约的可执行表述"，重复两份意味着改一次注册顺序或事件名要同步四个位置（中英 × 2）。发现 1 已经证明这类手抄副本会漂移（`Event` 构造器块与"其他公开 API"清单已经互相矛盾）。
- **建议**：「JIT 支持」节的最小示例改为一行指引（"完整脚本见下文「流程脚本契约」"），只保留 `:816-833` 那份；英文同步。

<!-- 第 2 部分 -->

### [严重][存量] #1 `AsyncDispatcher.dispatch()` 每次 `start()` 派生一个**永不退出**的消费线程，线程数随流程启动次数线性增长

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:138-148`（`140` `spawn{`、`141` `while(let event <- getEvent())`），调用方 `f_egraph/src/base/AsyncFlow.cj:148`（`start` 每次都 `getDispatcher().start(...)` → `AsyncDispatcher.start` `70-74` → `dispatch()`）；同源另一处 `AsyncDispatcher.cj:30-36`（构造器里的清理线程 `while(true){ removeIf; sleep }`）
- **来源**：存量（`git blame -L 138,148` 全为 `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §5「无界容器 / 长期持有」、§12.1「有界性」、§11「契约与实现不符」
- **证据**：静态确定 —— 三层文档核对后结论唯一：
  1. `spawn` 就是新建一个仓颉线程（语言文档 `cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/create_thread.md:3`「要创建一个新的仓颉线程，可以使用关键字 `spawn`」）；
  2. `getEvent()` 转调 `ImmediateDispatcher.getEvent()` → `eventQueue.remove()`，而 `LinkedBlockingQueue.remove(): E` 的语义是「如果队列为空，则阻塞等待」（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:561-567`）；
  3. `getEvent()` 的返回类型是非 `Option` 的 `Event`（`AsyncDispatcher.cj:162`、`ImmediateDispatcher.cj:106`），所以 `while(let event <- getEvent())` 的绑定永远成立 ⇒ 该线程只会在空队列上永久阻塞，**没有任何退出路径**（构造器里的 `while(true)` 同理）。
- **描述**：`AsyncDispatcher.start()` 是 `accept(event); dispatch()`，于是**每一次流程启动**都新增一个常驻消费线程。这些线程共享同一个 `eventQueue`，谁被唤醒谁处理事件（见 #2、#4 的连带后果）。服务端每次异步流程启动 = 一个永久线程（默认栈保留 + 调度实体），启动 1 万次就是 1 万个线程 ⇒ 线程创建失败 / RSS 失控。另外构造器里的「定时清理线程」在正常路径上几乎清不掉任何条目：`end` 里存的是 `WeakRef<EndExecutor>`（`111`），而 `EndExecutor` 同时被 `ImmediateDispatcher.executors` 强引用（`ImmediateDispatcher.cj:52` 的 `doRegister('EndExecutor', ...)`），弱引用不会失效，只有 `removeIf` 注销执行器后才会命中——付出一个常驻线程换到几乎为零的清理量。
- **建议**：消费循环移出 `dispatch()`，改成「`AsyncDispatcher` 构造时启动 1 个消费者」或用有界线程池（`spawn` 数 = 核数/固定窗口）驱动 `getEvent()`；`dispatch()` 只做「确保消费者已启动」的幂等操作（`AtomicBool` / 一次性初始化）。清理线程改为跟随生命周期（提供 `close()` 或用 `WeakRef` + 退出标志），并说明为什么不能只靠 `get()` 时顺带清理。

### [严重][存量] #2 结束事件按「消费线程的**创建者**线程 id」单槽登记 ⇒ 并发启动会取错结果，跨线程 `get()` 永久阻塞

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:108-115`（`111` `this.end[tid] = WeakRef(end, DEFERRED)`）、`116-128`（`tid` 由 `dispatch()` 在 `139` 捕获后逐层透传）、`87-89`（`tryGet` 用 `Thread.currentThread.id` 取键）、`70-74` + `AsyncFlow.cj:148`
- **来源**：存量（`git blame -L 75,115` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入」、§11「语义与命名/契约不符」
- **证据**：静态确定 —— 键的产生与消费明显不是同一个东西：
  - 写：`dispatch()` 在**调用 `start()` 的线程**上取 `tid`（`139`），该 `tid` 被闭包捕获，之后这个消费线程处理**任意**流程的事件时，都仍用这个 `tid` 登记结束执行器（`118` → `111`）；
  - 读：`tryGet()` 用的是**调用 `get()` 的线程**的 id（`88`）。
  于是有两个互相独立的错配：
  1. **队列是全局的、消费者是每启动一个**：线程 A 启动的流程，其 `StartEvent` 可能被线程 B 那次 `dispatch()` 派生的消费者取走，于是结束执行器被登记在 `end[B]` 下。结果 A 的 `get()` 等不到自己的结果（永久阻塞），B 的 `get()` 可能拿到 A 的结束事件（数据错投）。
  2. **同一线程上的两个在途流程共用一个槽**：`end` 的键只有线程 id，第二次 `start()` 的 `notifyEnd` 直接覆盖第一次的条目；第一次 `get()` 拿到的是第二个流程的 `EndExecutor`，第二个 `get()` 永久阻塞。`AsyncDispatcher_test.cj:24` 的注释「用例都从同一线程发起并等待，`AsyncDispatcher` 用线程 id 关联结束事件」等于把这一限制写成了使用前提，但 `AsyncEndExecutorGetter`（`AsyncEndExecutorGetter.cj:18-20`）与 `Dispatcher.get()` 都没有任何注释声明「必须同线程、且同线程只能有一个在途流程」，`AsyncFlow.start()` 返回的又是**共享的 dispatcher 本身**（`AsyncFlow.cj:148-151`），调用方完全无从得知。
- **建议**：把「一次启动」的关联标识显式化——`start()` 返回一个 per-start 的句柄（内含 `EndExecutor` 或 `Future`），`AsyncDispatcher` 内部用自增序号/`Event.session` 做键，而不是线程 id；至少在 `AsyncEndExecutorGetter` 与 `AsyncFlow.start` 的注释/README 里写清线程约束，并让「同线程并发启动」直接抛异常而不是静默覆盖。

### [严重][存量] #3 条件等待不循环、醒后直接 `getOrThrow()` ⇒ 被无关的 `notifyAll` 唤醒即抛 `NoneValueException`；同一线程第二次 `get()` 永久阻塞

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:75-86`（`83` `endCondition.wait()`、`84` `tryGet().getOrThrow()`）；同一模板的另一份拷贝 `f_egraph/src/base/ConcurrentEndExecutor.cj:33-44`（`41-42`）
- **来源**：存量（`git blame -L 75,86`、`-L 33,44` 均为 `4be871f2fd`）
- **判据**：review-checklist §12.1「条件等待：条件变量虚假唤醒未在循环里重查条件」、§11「边界/空值未处理」
- **证据**：静态确定 —— `notifyAll()` 在 `112` 是被**任意线程的任意一次结束事件**触发的（`end` 是全局 map），而 `get()` 只 `wait()` 一次，醒来后不校验「我要的 `tid` 是否真的有值」，直接 `tryGet().getOrThrow()`。两个线程各自等自己的流程时，先完成的那一方会把另一方从 `wait()` 唤醒，被唤醒者 `tryGet()` 返回 `None` → `getOrThrow()` 抛 `NoneValueException`（异常类型与语义都对调用方完全不可预期，且不是 `GraphException`）。
  另外 `tryGet()`（`87-89`）是**破坏性**的（`end.remove(...)`）：同一线程对这个 getter 调两次 `get()`，第二次先 `remove` 到 `None`，然后进锁 `wait()`，此后再没有 `notifyAll` 会针对它发生 ⇒ 永久阻塞。行为上「取一次就失效」没有任何文档说明。
- **建议**：改成标准的「循环 + 谓词」写法：`while (true) { if (let Some(v) <- tryGet()) { return v }; if (!endCondition.wait(timeout: remain)) { return None } }`，把 `tryGet` 拆成「非破坏性 peek」+「成功后 remove」；`wait()` 的返回布尔值不要丢弃（`wait(timeout)` 返回 `Bool`，见 `sync_package_interfaces.md:77-79`）。

### [严重][存量] #4 管线异常只抛在被 `spawn` 的线程里，等待方没有任何通知 ⇒ `get()` 永久阻塞且异常被静默吞掉

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:116-121`（`asyncExecute` 的 `spawn` 内直接 `executor.accept(event)`，无 try/catch）、`129-137`（`133` `throw GraphException(...)`）、`122-128`（`asyncDispatch` 再套一层 `spawn`）
- **来源**：存量（`git blame -L 116,137` 为 `4be871f2fd`）
- **判据**：review-checklist §3「静默吞异常 / 开关打开后走进空分支」、§11「错误处理缺失或静默」、§12.1「异步语义：Future 异常被吞」
- **证据**：静态确定 —— 任务体抛异常（`TaskExecutor.execute` → `task(event)`，`TaskExecutor.cj:39-41`；`BarrierTask.exec` 的 `GraphException`，`BarrierTask.cj:89`；`ErrorExecutor` 必然抛异常）发生在 `spawn` 出来的线程里，异常终止该线程；`notifyEnd`（`118`）只在「执行器是 `EndExecutor`」时才触发（`109`），失败路径既不发 `end`、也不 `notifyAll`、也不记录错误 → 调用方 `get()` 永久阻塞（无超时版本连兜底都没有），异常信息只留在被杀掉的线程里。`AsyncDispatcher_test.cj:118` 的注释「`toThrowIfNoExecutor = true` 时异常在 dispatch 线程内抛出，用例侧只断言『拿不到结束事件』」已经把这一行为当成既定事实。
- **建议**：`asyncExecute` 外层 `try { ... } catch (e: Exception) { 记录 error 到 slot; notifyAll }`，把异常挂到 per-start 句柄上，让 `get()` 抛 `GraphException(cause: e)`；`doDispatch` 的「无执行器」也不要只 `throw` 在消费线程，应回填到该 `tid` 的结果槽。`get()` 增加可选的超时重载，避免无界等待。

### [严重][存量] #5 结束执行器「先登记、后赋值」，且 `EndExecutor.end` 被无同步读取 ⇒ `start().get().get()` 的第二次 `get()` 可能读到 `None` 或永久看不到写入

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:116-121`（`118` 先 `notifyEnd` 登记并唤醒，`119` 才 `executor.accept(event)`）、`f_egraph/src/base/EndExecutor.cj:22-31`（`22` `private var end = None<Event>`，`23-25` `execute` 赋值，`26-31` `tryGet`/`get` 直接读，无锁无原子）
- **来源**：存量（`git blame` 对应区间均为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性 / 发布逸出」、§11「并发正确性」、§3「`case None => ()` 当兜底把错误吃掉」（`getOrThrow` 版本）
- **证据**：静态确定 —— 写读之间存在真实的先后与可见性缺口：
  1. 顺序：`notifyEnd` 在 `110-113` 里先 `end[tid] = ...` 再 `notifyAll()`，**然后**才在 `119` 调 `executor.accept(event)`；`EndExecutor.accept` → `execute`（`EndExecutor.cj:23-25`）才是给 `end` 赋值的地方。等待方被唤醒后 `AsyncDispatcher.get()` 立刻返回这个 `EndExecutor`，紧接着调用 `.get()`（`EndExecutor.cj:29-31`）读 `end`——此时写者可能还没执行到赋值语句，直接 `None.getOrThrow()`。
  2. 可见性：`EndExecutor.end` 是普通 `var`（`22`），`notifyAll` 时持锁释放的是 `endMutex`，而写 `end` 发生在**解锁之后**，读者拿同一把锁也建立不了与这次写之间的 happens-before；`tryGet`/`get` 本身又完全不加锁。按语言并发模型（`cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/sync.md` 第 1 节：共享可变状态必须用原子/锁/通道保护），这是一处数据竞争，读者可能长期读到 `None`。
  也就是说 `AsyncFlow.start(...).get().get()` 的正确性只依赖「写者比读者先跑完」，而不是任何同步手段；`AsyncDispatcher_test.blockingGetReturnsEnd`（`AsyncDispatcher_test.cj:50-60`）这类用例存在偶发 `NoneValueException` 的理论可能。
- **建议**：把「赋值」移到「登记」之前（先 `executor.accept(event)`，再 `notifyEnd`）；`EndExecutor.end` 改用 `AtomicReference`/`AtomicOption`（或整个 `EndExecutor` 读写都走同一把 `Mutex`），`get()` 用条件变量等到非空，而不是 `getOrThrow`。

### [严重][存量] #6 `BarrierTask.exec` 的并发累积无任何同步：非线程安全 `ArrayList` 并发 `add` + 「检查数量-然后-发射-删除」 ⇒ 丢数据/重复发射

- **位置**：`f_egraph/src/base/BarrierTask.cj:82-96`（`85` `datas.computeIfAbsent(key){ArrayList<Any>()}`、`86` `list.add(de.data)`、`91` `list.size >= count`、`92-93` `emit` + `datas.remove(key)`）
- **来源**：存量（`git blame -L 82,96` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 用并发容器就当复合操作原子」、§11「并发正确性」
- **证据**：静态确定 —— `datas` 是 `ConcurrentHashMap`（`42`），但**值**是普通 `ArrayList<Any>`，而同一 `BarrierKey`（同一 `category/tag/eventName/session`）的多个事件会被 `AsyncDispatcher` 的 `asyncExecute` 派到**不同线程**并发执行（`AsyncDispatcher.cj:116-121`），于是：
  1. `list.add` 并发写同一个 `ArrayList` → 元素丢失/内部数组损坏（`ConcurrentHashMap` 只保证 map 结构安全，不保护 value）；
  2. `list.size >= count` 与 `datas.remove(key)` 之间没有原子性 → 两个线程可同时通过判断，各 `emit` 一次（下游流程被重复触发），随后一个线程 `remove` 后另一个把新事件加进已被摘下的 list（彻底丢失）。
  这是把「并发容器」当成「复合操作原子」的典型误用。
- **建议**：改成 `ConcurrentHashMap<BarrierKey, Mutex>` + 在锁内做「add → 判数量 → 取出并清空 → 锁外 emit」，或直接 `datas.compute(key) { ... }` 的原子重映射（在映射函数内只做累积与计数，返回 `null` 表示触发，再把要发射的 list 带出来，emit 放锁外）。

### [严重][存量] #7 `AsyncFlow` 构造期的 `flows` 判重是 check-then-act ⇒ 并发构造同一 `(category, tag)` 会重复登记 Multi 执行器，`MultiEvent` 被重复扇出

- **位置**：`f_egraph/src/base/AsyncFlow.cj:75-81`（`77` `if(!flows.contains(this))`、`78` `registerMultiEventTask()`、`79` `flows.add(this)`），`135-137`（注册走 `Dispatcher.registerMultiTask` → `ImmediateDispatcher.doRegister(executor)`，后者只 `add` 不查重：`ImmediateDispatcher.cj:54-58`）
- **来源**：存量（`blame`：`77-78` 为 `4be871f2fd`，`79` 为 `8f86940889`（2026-10-24，即 `tasks.md 0.6` 的补丁））
- **判据**：review-checklist §12.1「检查-然后-写入：容器线程安全不代表组合操作原子」、§11「并发正确性」
- **证据**：静态确定 —— `flows` 是 `ConcurrentHashSet`（`73`），但 `contains` 与 `add` 之间有窗口。两个线程同时 `AsyncFlow(c, t)`（这是公开构造器，也是 `registerTaskByAsyncFlow`（`Flow.cj:91-93`）与「宿主用新实例启动」的既定用法，见 `FlowInitializer_test.cj:228`）→ 两边都看到 `contains == false` → 两边都 `registerMultiEventTask()` → `ImmediateDispatcher.executors` 里同一 `Event(Multi, c, t, "Multi")` 键下出现 2 个 `TaskExecutor`（`doRegister` 无查重）→ `dispatch` 遍历该 list（`ImmediateDispatcher.cj:78-83`）把 `MultiEvent` 扇出两次 → 每个子事件被执行两次（重复的业务副作用）。`AsyncFlow.start()` 同一时刻也被多个线程调用是服务端的常态，窗口很容易命中。
- **建议**：`if (flows.addIfAbsent(this)) { registerMultiEventTask() }`（先原子占位再注册），或在 `AsyncDispatcher` 的 `mutex` 内完成「判重 + 注册」；`ImmediateDispatcher.doRegister(executor)` 对 Multi 也应查重，避免任何路径产生重复执行器。

### [一般][存量] #8 `BarrierTask` 未达阈值的聚合数据永不回收：以 `session` 为键的无界增长

- **位置**：`f_egraph/src/base/BarrierTask.cj:42`（`datas` 定义）、`85-94`（只在达到阈值时 `datas.remove(key)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §5「无界容器：全局 HashMap 随请求增长，GC 后条目仍在」、§7「有界化」
- **证据**：静态确定 —— `BarrierKey` 含 `session`（`18-27`），而 `session` 默认是每个事件新生成的 UUID（`Event.cj:32`）。任何「事件数没凑够 `count`」的会话（上游失败、客户端断开、部分事件被 `removeIf` 清掉）都会在 `datas` 里永久留下「key + 该会话已收到的 `Any` 引用」。量级：`Σ(未完成会话数) × 平均已收条目数 × 8B 引用`，无上限、无 TTL、无淘汰，且 `BarrierTask` 是长生命周期对象（注册在 dispatcher 里）。同样，`ArrayList` 在 `remove(key)` 后即被丢弃，没有复用/收缩。
- **建议**：给 `datas` 加容量/TTL（例如「会话首次写入时间 + 超时清理」，或复用 dispatcher 已有的 `clearTimerDuration` 循环做定期清空），并在 `count` 长期不满足时打点/告警；`sessions` 维度按 `category/tag` 分片便于整体清理。

### [一般][存量] #9 `Condition.wait` 的超时余量可能 ≤ 0，抛 `IllegalArgumentException` 而不是返回 `None`

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:99`（`endCondition.wait(timeout: timeout - (MonoTime.now() - start))`）、`f_egraph/src/base/ConcurrentEndExecutor.cj:53`（`condition.wait(timeout: timeout)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「边界差一 / 契约与实现不符」；标准库文档 `sync_package_interfaces.md:83`「如果 `timeout` 小于等于 `Duration.Zero`，抛出 `IllegalArgumentException`」
- **证据**：静态确定 —— `tryGet(timeout:)` 的契约是「超时返回 `None`」（`AsyncEndExecutorGetter.cj:19` 与 `AsyncDispatcher_test.cj:128` 的负向用例都这么用），但先做了一次快速 `tryGet()`，若这一步耗时 ≥ `timeout`（极短超时、GC 停顿、被抢占），`timeout - elapsed` 为负 ⇒ `wait` 抛 `IllegalArgumentException`，调用方拿到的不是 `None` 而是异常。`timeout = Duration.Zero` 时同样直接抛。`ConcurrentEndExecutor.get(timeout:)` 把用户传入值原样透传，问题相同。对照：`LinkedBlockingQueue.remove(timeout)` 对负值「立即执行并返回结果」（`collection_concurrent_class.md:595-601`），两处 API 的负值语义并不一致，更容易写错。
- **建议**：`if (remain <= Duration.Zero) { return None }` 后再 `wait`；或统一用 `waitUntil(predicate, timeout)`（`sync_package_interfaces.md:107-133`）把「条件 + 超时」交给标准库处理。

### [一般][存量] #10 `AsyncFlow` 的全局可变状态无同步；`initDispatcher` 可重复覆盖，旧 dispatcher 的执行器与线程被静默遗弃

- **位置**：`f_egraph/src/base/AsyncFlow.cj:19-26`（`private static var dispatcher`，`20-22` 无条件覆盖、`24-26` 测试用清空）、`27`（`dependencied_`）、`73`（`flows`）、`96-98`（`getDispatcher` 直接 `getOrThrow`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」、§14.1「接线缺失：开关只在一处判断」
- **证据**：静态确定 ——
  1. `dispatcher` 是普通 `static var`，`initDispatcher` 写入、每个 `AsyncFlow` 构造/启动读，无锁、无原子 ⇒ 按语言并发模型属数据竞争（`sync.md` 第 1 节）；典型调用点是启动期单线程，但 `initDispatcher` 是 `public`，测试里就被反复调用（`AsyncFlow_test.cj:38,46`、`BarrierTask_test.cj:58`、`FlowInitializer_test.cj:222`）。
  2. 覆盖后果不止「旧实例没人引用」：旧的 `AsyncDispatcher` 及其常驻线程（#1）继续存活，而 `flows`（`73`）里仍记着旧 dispatcher 上注册过的流程 —— 再次 `AsyncFlow(c, t)` 时 `flows.contains` 为真 ⇒ **跳过** `registerMultiEventTask()`，但新 dispatcher 里根本没有这些执行器。也就是「重新初始化」之后流程会静默失去 Multi 扇出，随后 `start` 抛「No executor found」，且无法自愈。
  3. `dependencied_` / `flows` 只在 `remove()` 路径清理，未 `remove()` 的流程永久驻留（有界于 `(category, tag)` 数量，属轻度泄漏）。
- **建议**：`dispatcher` 改为 `AtomicReference` 或用 `Mutex` 保护的「只允许初始化一次 + 显式 `reset()`」；`initDispatcher` 被二次调用时要么抛异常要么先清理旧实例（停线程、清 `flows`/`dependencied_`）；`flows` 与 dispatcher 的生命周期绑定到同一个对象上，避免两套全局状态不同步。

### [一般][存量] #11 `removeIf` 谓词里构造 `AsyncFlow` 带注册副作用：在 `HashMap.removeIf` 迭代中可能修改同一个 map

- **位置**：`f_egraph/src/base/AsyncFlow.cj:57-72`（`59-68` 是传给 `dispatcher.removeIf` 的谓词，`61` `let flow = AsyncFlow(category: category, tag: e.tag)`，`62` `flow.canBeRemoved()`，`69-71` 循环后删 `flows`）；谓词在被 `AsyncDispatcher.removeIf`（`103-107`）持有 `mutex` 时执行，最终落到 `ImmediateDispatcher.executors.removeIf`（`ImmediateDispatcher.cj:103-105`）
- **来源**：存量（`blame`：`57-72` 中 11 行为 `4be871f2fd`、5 行为 `8f86940889`）
- **判据**：review-checklist §12.1「迭代与修改并发」、§3「开关打开后走进空分支」、§11「语义与注释不符」
- **证据**：静态确定（机制）/ 待确认（可达状态）——
  - 谓词里 `AsyncFlow(...)` 不只是读：构造器在 `flows` 里查不到时会**注册执行器**（`77-79`）。若 `executors.removeIf` 正在遍历 `executors` 而谓词往同一个 `HashMap` 里 `computeIfAbsent(...).add(...)`，属「迭代中修改容器」，结果取决于 `HashMap.removeIf` 的实现（抛并发修改异常、漏删或结构损坏）。
  - 可达状态需要「dispatcher 里存在某 tag 的执行器，但该 tag 不在 `flows`」：直接调 `AsyncDispatcher.registerStart/registerTask`（公开 API）注册、`canBeRemoved()` 在 `62` 抛异常导致 `69-71` 的 `flows.remove` 未执行（执行器已删、`flows` 残留的相反情况）、或 #10 的 dispatcher 覆盖都会造出这种状态。
  - 代码注释（`50-56`）把重排的理由写成「`AsyncDispatcher` 的 `mutex` 不可重入 —— 同一次 `removeIf` 里删集合会在下一个事件上自锁」。这条理由与标准库文档相反：`std.sync.Mutex` 是**可重入**的（`sync_package_classes.md:8927-8930`「可重入是指线程获取该锁后可再次获得该锁」；`sync.md:350` 同义）。真正的风险是上面的「迭代中改 map」以及「重复登记 Multi」，不是自锁（另见 #15）。
- **建议**：谓词里只做纯判断（按 `category/tag` 过滤），把「构造实例 / 判依赖 / 删 `flows`」全部移到 `removeIf` 返回之后（对自己收集的 `(category, tag)` 列表做）；`AsyncFlow` 构造器也不要带注册副作用，把「注册 Multi」显式成 `ensureRegistered()`。

### [一般][存量] #12 D11 的「开始事件名回退」只做在 `start`，`registerTask` 仍只看本地 `startName` ⇒ 宿主新实例无法给已注册流程补任务，且错误消息误导

- **位置**：`f_egraph/src/base/AsyncFlow.cj:142-152`（`start` 在本地为空时回退到 `getDispatcher().startEventName(...)`）vs `117-126`（`registerTask` 仍在 `118` 用本地 `startName.size == 0` 判定并抛 `GraphException`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §14.1「只做了一半的分支」、§11「语义与命名/注释不符」
- **证据**：静态确定 —— 回退的动机在 `Dispatcher.cj:34-39` 写得很清楚：「流程的 `startName` 是实例字段，宿主在初始化后新建的实例读不到脚本里登记的名字」。这个理由对 `registerTask` 同样成立：宿主 `AsyncFlow(c, t)` 新建实例后想追加一个任务，`registerTask` 会走 `118` 抛「There must be with StartExecutor before registering first TaskExecutor」——而 dispatcher 里**确实**已经注册了 StartExecutor（`startEventName` 能查到），错误消息与事实相反。要么这是有意的「任务只能由脚本注册」，那就应在接口注释里写明；要么是 D11 漏改一处。
- **建议**：`registerTask` 的 `startName` 取值改成与 `start` 相同的回退逻辑（抽 `private func effectiveStartName(): String`），或在注释里明确「宿主实例只允许 `start`/`emit`，任务必须在脚本里注册」。

### [一般][存量] #13 测试的全局状态与真实时钟等待，与 `f-egraph-test-coverage` 的「用例隔离 / 不依赖真实时钟」条款不符

- **位置**：`f_egraph/src/FlowInitializer_test.cj:219-233`（`asyncScriptRequiresInitDispatcher` 调 `AsyncFlow.initDispatcher()` 覆盖全局 dispatcher，且**未** `remove()`）、`276-296`（`readmeExampleScriptRuns` 同样只 `start` 不 `remove`）、`f_egraph/src/base/AsyncDispatcher_test.cj:128,137`（`tryGet(timeout: Duration.millisecond * 200)` 的负向用例要真的等 200ms）
- **来源**：存量（`blame` 为 `4be871f2fd`）
- **判据**：review-checklist §13「规格与实现漂移」；承诺源 `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-test-coverage/spec.md:13`（「不依赖外部服务、网络或真实时钟等待」）、`:18`（「流程用例使用的 `category` 唯一并在结束时清理」）、`tasks.md:295`（5.5 全局状态隔离，勾选为已完成）
- **证据**：静态确定 —— 上述两个用例既没有在结束处 `flow.remove()`（对比同文件 `syncScriptRegistersRunnableFlow:115`、`twoScriptsRegisterTwoFlows:133-134` 都有），又用 `initDispatcher()` 把全局 dispatcher 换掉：先于它们注册的 `AsyncFlow` 会留在旧 dispatcher 上（#10 的第 2 点），后于它们构造的同 tag 流程会因为 `flows` 判重跳过 Multi 注册。`AsyncDispatcher_test` 的负向断言用 200ms 真实等待，属于 spec 明令避免的「真实时钟等待」，在慢 CI 上可能抖动（`removeIfDropsExecutors` 期望 200ms 内取不到结果，慢机器上若派发晚于 200ms 反而会变红）。
- **建议**：两个用例补 `flow.remove()`（或 `finally` 里清理）；把「重置 + 初始化 dispatcher」收敛成测试夹具的 `@BeforeAll` 一次性动作，并提供 `AsyncFlow.resetDispatcherForTest()`（已有，`AsyncFlow.cj:24-26`）在 `@AfterEach` 里清空；负向用例改成「注入一个永不完成的执行器 + 立即断言 `isNone()`」，或用可控时钟/注入的 `Condition` 替身避免真实等待。

### [轻微][存量] #14 重复逻辑：`ClosureTask.exec` 与 `evaluate` 函数体逐字相同；`AsyncDispatcher` 与 `ConcurrentEndExecutor` 是同一份「双重检查 → wait → getOrThrow」模板

- **位置**：`f_egraph/src/base/ClosureTask.cj:141-143` vs `146-148`；`f_egraph/src/base/AsyncDispatcher.cj:75-102` vs `f_egraph/src/base/ConcurrentEndExecutor.cj:33-57`
- **来源**：存量（`ClosureTask.cj:141-148` 为 `afb9821e26`/`8f86940889`；其余 `4be871f2fd`）
- **判据**：review-checklist §2「只改类型名 / 换控制流，语义相同」
- **证据**：静态确定 ——
  1. `ClosureTask.exec` 与 `protected evaluate` 都只有一行 `body_(e)`。`evaluate` 的注释说「不经过 `exec` 的入队逻辑」，但 `ClosureTask` 本身没有任何入队逻辑（入队逻辑在子类 `QueuedClosureTask.exec` 里，`QueuedClosureTask.cj:76-83`），所以这句注释和这份重复都不成立：`exec` 直接写 `evaluate(e)` 即可，子类仍能覆盖 `exec`。
  2. `AsyncDispatcher.get()` / `tryGet(timeout:)` 与 `ConcurrentEndExecutor.get()` / `get(timeout:)` 是同一个「锁外快速判定 → 加锁 → 再判定 → `wait` → `getOrThrow`」模板的两份拷贝（差异只有返回类型与等待的目标），并且两份**带着同样的缺陷**（#3、#9）。这正是「近似重复里少一处边界判断」的典型：修一处必须记得修另一处。
- **建议**：`ClosureTask.exec` 改为 `evaluate(e)`；抽出 `private func awaitValue<T>(mutex, cond, probe: () -> ?T): T`（带 timeout 重载）供两个类共用，把 #3/#9 的修法只写一遍。注意 `AsyncDispatcher` 的 5 个 `register*` 包装（`37-56`）虽形状相同但目标方法不同，**不**算重复逻辑，保持现状即可。

### [轻微][存量] #15 代码注释与变更记录声称「`AsyncDispatcher` 的 `mutex` 不可重入」，与标准库文档相反

- **位置**：`f_egraph/src/base/AsyncFlow.cj:53-56`（「`AsyncDispatcher` 的 `mutex` 不可重入 …… 会在下一个事件上自锁」）；同一论断在 `doc/spec/f-egraph-jit-flow-init/tasks.md:223-225`（「原在 `removeIf` 谓词内删 `flows` …… 而自锁」）
- **来源**：存量（`4be871f2fd`；`tasks.md` 同批次）
- **判据**：review-checklist §10「可读性/可维护性：必要注释（尤其是『为什么这样写』）」、§13「文档与实现一致性」；反证文档 `sync_package_classes.md:8927-8930`、`sync.md:350`（「`Mutex` 在设计上是一个可重入锁……再次尝试获取同一个 `Mutex` 锁，永远可以立即获得」）
- **证据**：静态确定 —— `synchronized(x)` 的锁对象是 `Lock`，这里就是 `std.sync.Mutex`，文档明确可重入；`ImmediateDispatcher` 内部也没有第二把锁。因此「同一次 `removeIf` 里删集合会自锁」这个因果链不成立（真实风险是 #11 的迭代中改 map、以及重复登记 Multi）。留着的危害是：它把一个错误的约束写进了代码与变更记录，后续维护者会据此继续做不必要的重排，或反过来误判真实死锁风险。
- **建议**：改写注释，说明真正的约束（谓词内不要产生注册副作用 / 不要在 `removeIf` 遍历中改 map），并在 `design.md` D9/D11（第 1 部分范围内）同步更正。

<!-- 第 3 部分 -->

### [严重][存量] #1 `dispatch()` 只在遇到 `EndExecutor` 时返回，队列耗尽后永久阻塞在 `LinkedBlockingQueue.remove()` ⇒ 未注册 End 的流程 `start()` 挂死

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:70-88`（`71` 空队列抛异常的守卫、`74` `while(let event <- getEvent())`、`81` `return this.end = end`）、`106-108`（`getEvent()` → `eventQueue.remove()`）、`20`（队列构造）；调用方 `f_egraph/src/base/ImmediateFlow.cj:118-125` → `ImmediateDispatcher.start` `92-96`
- **来源**：存量（`git blame -L 70,90 -- f_egraph/src/base/ImmediateDispatcher.cj` 全为 `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §11「错误处理缺失 / 契约与实现不符」、§12.1「异步语义、有界性」
- **证据**：静态确定 —— 三条独立事实叠加：
  1. `getEvent()` 的返回类型是**非 `Option`** 的 `Event`（`ImmediateDispatcher.cj:106`），`while(let event <- getEvent())` 的绑定模式不可失败 ⇒ 循环条件恒真，唯一出口是 `81` 的 `return` 和 `85` 的 `throw`（语言文档 `cangjie_docs/docs/dev-guide/source_zh_cn/class_and_interface/typecast.md:92-133` 的 while-let 示例说明 `let pattern <- expr` 是「匹配成功即进入循环体」的条件糖）。
  2. `LinkedBlockingQueue.remove(): E` 是**阻塞**出队：「阻塞的出队操作，获得队首元素并删除」（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:561-567` 与 `3320-3326`）——队列为空时不会抛异常、不会返回，而是等待。
  3. 同一模式的异步版本把这条行为写成了注释：「`LinkedBlockingQueue.remove()` 在队列为空时会一直阻塞，而 dispatch 线程取空队列后正是长期停在这里」（`AsyncDispatcher.cj:154-164`）；`Flow_test.cj:126` 同样自认「`ImmediateDispatcher.dispatch` 只在遇到 `EndExecutor` 时返回」。
- **描述**：一个流程若不调用 `registerEnd()`（`BaseFlow.registerEnd()` 是可选的，`Flow.cj:24`），或末态任务返回 `DummyEvent`（`74-76` 的 `continue` 之后队列就空了），或末态任务返回的事件恰好没有对应执行器之外的任何出口，`dispatch()` 就会在 `remove()` 上永久阻塞。对 `ImmediateFlow.start()` 而言这意味着**调用线程挂死**（不是超时、不是异常），且该线程持有的业务锁 / 请求上下文一并冻结；`get()` 永远拿不到结果。触发条件全部由公开 API 的合法用法构成（不注册 End、任务返回 `DummyEvent`），不需要任何错误用法。另附两点：`71` 的 `eventQueue.size == 0` 守卫与 `74` 的阻塞出队之间存在 TOCTOU（`size()` 文档明确「不保证并发场景下的原子性」，`collection_concurrent_class.md:2752-2756`）；`85` 的 `throw` 退出后队列里剩余的事件既不清空也不上报，下一次 `start` 会把它们当作本次事件消费（见 #2）。
- **建议**：把消费循环改成有界、可退出的形式——`tryRemove()`（`collection_concurrent_class.md:778-790`，非阻塞、空队列返回 `None`）驱动循环，或 `remove(timeout:)` + 「连续空转 N 次且无在途任务」退出；「没有 End」应显式失败：`start()` 返回一个 `tryGet()` 为 `None` 的 getter 或抛 `GraphException('flow ${category}-${tag} has no EndExecutor registered')`。若确认「必须 registerEnd」是契约，则把它写进 `BaseFlow.registerEnd` 的注释与 README，并让 `start` 前置校验（`dispatch` 里已在 `92-96` 拿到 dispatcher，可直接查 `executors` 是否有 End 键）。

### [严重][存量] #2 「一次 start」的会话状态（`eventQueue` / `end` / `executors`）全部落在共享 dispatcher 实例上，既无会话隔离也无同步

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:19-22`（`executors` 普通 `HashMap<Event, ArrayList<Executor>>`、`eventQueue`、`startEventNames` 普通嵌套 `HashMap`）、`69`（`private var end = None<EndExecutor>`）、`74-88`、`89-91`（`accept` 只 `add`）、`97-102`（`get`/`tryGet` 直读 `end`）、`103-105`（`removeIf` 直接改 `executors`）；`f_egraph/src/base/ImmediateFlow.cj:19`（`private static let dispatchers`，同一 `(category, tag)` 全进程共用一个 dispatcher）、`118-125`（`start` 把 dispatcher 自己当 `EndExecutorGetter` 返回）、`126-128`（`emit` 直接 `accept`）
- **来源**：存量（`git blame -L 19,111` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 迭代与修改并发 / 可见性 / 发布逸出」、§11「并发正确性」、§10「正确性」
- **证据**：静态确定 —— 共享路径可逐段点出：
  1. **结果是单槽**：`ImmediateDispatcher.start()` 返回 `this`（`92-96`），`end` 是该实例上的**唯一字段**（`69`），`81` 写入、`98` 读取。因此「上一次 start 拿到的 getter」和「这一次 start 拿到的 getter」是同一个对象：顺序调用 `let g1 = flow.start(a); flow.start(b); g1.get()` 得到的是 b 的 `EndExecutor`；并发调用时两个线程都往 `end` 写，谁后跑完谁覆盖，两个调用方都可能拿到对方的结束事件。
  2. **队列是单槽**：`eventQueue` 是全流程共享的 FIFO（`20`、`90`），`dispatch` 无锁地 `remove()` 并就地执行。两个线程各自 `start` 时，双方的 `dispatch` 循环会**抢同一个队列**——A 的消费者可能取走 B 的 `StartEvent` 并用 B 的数据跑 A 的逻辑（执行器按 `(eventType, category, tag, name)` 路由，与 session 无关），结束后把 B 的 End 写进同一个 `end`。
  3. **End 提前返回会留残留**：`81` 一遇到 `EndExecutor` 就 `return`，队列里剩下的事件不清理。`Flow_test.cj:231-241`（`emitEnqueuesEvent`）就是这种用法：先 `emit` 一条 End、再 `start`，队列为 `[End, Start]`，`dispatch` 处理完 End 即返回，`StartEvent` 留在队列里；下一次 `start` 会先消费这条**上一次会话**的 Start 并可能提前返回它的 End。
  4. **容器与字段无同步**：`executors` 是普通 `HashMap<K, ArrayList<E>>`，`removeIf`（`103-105`）与 `doRegister`（`54-58` 的 `add`）会结构性修改它，而 `dispatch` 在 `77-83` 无锁遍历同一个 `ArrayList`；`end` 是普通 `var`，`startEventNames` 是普通嵌套 `HashMap` 且被 `41-47`（读）与 `34-40`（写）跨线程访问。按语言并发模型（`cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/sync.md` 第 1 节：共享可变状态必须用原子 / 锁 / 通道保护），这些都是数据竞争。`ImmediateDispatcher` 没有任何 `Mutex`，也没有「仅单线程」的文档约束（`README.md:483-499` 只列签名）。
  与第 2 部分已报的 `AsyncDispatcher`「结束事件按线程 id 单槽、消费者不退出」（`parts/f_egraph.part2.md` #1/#2）是**同一设计缺陷的同步侧版本**：那边靠 `spawn` 把并发掩盖成「线程各干各的」，这边直接把并发暴露在调用线程上。
- **描述**：`ImmediateFlow` 是服务端每请求启动一次的对象，`(category, tag)` 相同的请求天然并发命中同一个 dispatcher。后果有三类：事件跨请求串流（A 的数据进 B 的流程）、结果错投（拿到别人的 End）、以及 `removeIf` 与 `dispatch` 并发时 `ArrayList` / `HashMap` 的迭代-修改竞态（漏删、`ConcurrentModification` 类异常、结构损坏）。这些都不是「可能慢」，而是结果错误。
- **建议**：把「一次启动」显式建模成一个对象——`start()` 返回 per-start 句柄（含自己的 `eventQueue` 或 session 过滤、自己的 `end` 槽、`Future`/`Condition`），dispatcher 只持有不可变的「执行器表」；或最小改动：`start` 全程 `Mutex` 串行化 + `end` 改为 per-`Event.session` 的 `ConcurrentHashMap`、消费循环按 `event.session` 过滤掉非本次会话的事件（`Event.session` 已存在且默认每事件一个 UUID，`Event.cj:32`）。无论哪种，`executors` 至少要换成并发容器，并把 `removeIf` 与 `dispatch` 的关系写清楚（现注释只在 `AsyncDispatcher` 侧说明 `mutex` 保护）。

### [一般][存量] #3 `Event` 文档承诺的 `priority` / `cancelPrev` / `EmptyEvent` 取消语义只在 `QueuedClosureTask` 内成立，`ImmediateDispatcher` 完全忽略

- **位置**：承诺源 `f_egraph/src/base/Event.cj:23-26`（「`priority`：0 抢占并合并执行；1 等当前结束后合并执行；>=2（默认）逐条执行」「`cancelPrev > 0`：撤销前面 N 条同优先级事件」）、`117-122`（「空事件：执行时什么也不做，只作为『取消指令』」）；实现缺口 `f_egraph/src/base/ImmediateDispatcher.cj:89-91`（只 `add`，不看 `priority` / `cancelPrev`）、`74-86`（只跳过 `is DummyEvent`，`EmptyEvent` 不是 `DummyEvent` 子类，直接落 `85` 的 `No executor found`）；唯一实现 `f_egraph/src/base/QueuedClosureTask.cj:68-100`、`263-295`
- **来源**：存量（`git blame -L 74,91`、`-L 23,26` 均为 `4be871f2fd`）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `Event` 构造函数接受并校验 `priority` / `cancelPrev`（`37-42`），把语义写进了公开 API 的注释；但 `ImmediateDispatcher` 的队列是 `LinkedBlockingQueue`（FIFO，无优先级概念），`accept` 只入队、`dispatch` 只按到达序执行。真正兑现这段注释的只有 `QueuedClosureTask.submit`（`76-100`：`cancelPrev` 删同优先级尾部、`EmptyEvent` 删同名同优先级尾部、`priority == 0` 立即执行）。而 `priority` / `cancelPrev` 是 `Event` 层面的字段，任何 `Task` 实现（`TaskExecutor` 直接 `accepter.accept(task(event))`，`TaskExecutor.cj:39-41`）返回的事件都会带着它们进入 dispatcher，此时语义静默失效。
- **描述**：两种可观察后果：① 用 `ImmediateFlow` + 普通 `ClosureTask`（非 `Queued`）组成的流程里，`priority = 0` 的「抢占」不发生，事件仍按 FIFO 逐条跑——调用方按注释设计出的「最新配置覆盖旧配置」会变成「旧配置先执行完、新配置后执行」，业务结果取决于时序；② 任务返回 `EmptyEvent(cancelPrev: 1)` 想撤销前一条事件时，dispatcher 既不撤也不忽略，而是抛 `GraphException("No executor found for event: Event(eventType: Dummy, category: , tag: , name: ...)")`，把一次「取消」升级成流程失败。与第 1 部分 `parts/f_egraph.part1.md` §「事件字段与 Dummy 语义的描述与实现不符」重叠（那条讲文档描述，本条讲实现面缺失与错误路径），合并时取一条即可。
- **建议**：二选一并落到注释：要么让 `ImmediateDispatcher` 也按 `priority` 排序（队列换 `SyncPriorityQueue`，`QueuedClosureTask` 已在用）并在 `74` 之前先处理 `EmptyEvent` 的撤销；要么把 `Event.cj:23-26`、`117-122` 的注释改成「优先级与撤销仅对 `QueuedClosureTask` 生效，其它 `Task` 实现忽略」，同时让 `EmptyEvent` 在任何 dispatcher 下都被静默跳过（`74` 的判定从 `is DummyEvent` 改为 `event.eventType == EventType.Dummy`）。

### [一般][存量] #4 `JitHostRegistry.configure` 每次调用都往进程级 `HostFieldTable` 追加 4 个等价访问器，无去重 ⇒ 全局表只增不减，且字段查找退化为线性扫描

- **位置**：`f_egraph/src/base/JitHostRegistry.cj:37-49`（`38` 无条件 `registerEventFields()`）、`54-91`（4 次 `HostFieldTable.register`）、`24-25`（注释「重复 `configure` 只会追加等价访问器」）；被调方 `f_jit/src/runtime/HostField.cj:91-114`（`register` 每次 `list.add(acc)`，无查重）、`121-133`（`find` 在桶内逐个 `accepts` 线性扫描）
- **来源**：存量（`git blame -L 37,91` 为 `4be871f2fd`；`HostField.cj` 为 f_jit 范围，仅作被调方证据）
- **判据**：review-checklist §5「长期持有 / 全局集合只增不减」、§6.4「热点里对 `Array` 反复线性查找」、§11「注释与实现不符」
- **证据**：静态确定 —— `HostFieldTable.register` 的写入路径没有任何键判重：`synchronized` 内取出旧桶、`ArrayList` 复制、`list.add(acc)`、整表原子替换（`HostField.cj:96-113`）。因此每次 `configure` 净增 4 个 `HostFieldAccessor`（每个含 2 个闭包 + `type`/`mutable`），永不释放；同一 index 的桶长度随 `configure` 次数线性增长，`find` 每次字段读都要按注册序逐个 `accepts(obj)`（`121-133`）。调用点：`f_egraph/src/egraph.cj:39`（模块初始化 1 次）、`f_egraph/src/base/ClosureTask.cj:76`（惰性编译器 1 次）、`f_llm/src/loom/LoomCompiler.cj:40`（**每个 `LoomCompiler` 实例 1 次**，范围外提示）。
- **描述**：注释把「追加等价访问器」当成了无害事实，实际是两个后果：进程 RSS 随 `configure` 次数单调上升（每次 4 个访问器 + 2 个闭包捕获），脚本字段读的耗时随桶长度线性上升（命中越晚越慢，而 `Event` 的 4 个字段都在同一个对象上反复读）。若 `LoomCompiler` 按会话 / 按脚本创建，这就是一条无上限的慢性泄漏，且没有清理 API（`resetForTest` 仅测试用）。
- **建议**：`registerEventFields` 做成幂等——按「index + 目标类型」在 `HostFieldTable` 内部查重（`register` 增加 `if (list.any{it.accepts(sample)}) return` 之类）或把访问器表改成 `static let` 只注册一次、`configure` 只做 `registerClass`；同时把 `JitHostRegistry.cj:24-25` 的注释改成与实现一致（「等价访问器会被重复追加，故需幂等」）。

### [一般][存量] #5 `ImmediateFlow` 与 `AsyncFlow` 是两份逐行同形的实现，且已经出现行为漂移

- **位置**：`f_egraph/src/base/ImmediateFlow.cj:28-43`（`canBeRemoved`）↔ `AsyncFlow.cj:28-43`；`93-107`（`registerTask` 校验 + `registerTask(Task)`）↔ `AsyncFlow.cj:117-131`；`111-113`（`registerMultiEventTask`）↔ `AsyncFlow.cj:135-137`；`118-128`（`start` / `emit`）↔ `AsyncFlow.cj:142-155`；`58-69`（`hashCode` / 两个 `==` / `toString`）↔ `AsyncFlow.cj:83-94`；`70-74`（`dependencied`）↔ `AsyncFlow.cj:99-103`
- **来源**：存量（`git blame -L 28,128 -- f_egraph/src/base/ImmediateFlow.cj` 为 `4be871f2fd`；`AsyncFlow.cj` 属第 2 部分，此处只作对照）
- **判据**：review-checklist §2「只改类型名 / 换控制流，语义相同」+「近似重复里少一处边界判断往往同时是缺陷」
- **证据**：静态确定 —— 两段代码压成「输入 → 输出 → 副作用」后逐条相同：`canBeRemoved`（拼依赖串 → 抛 `GraphException`，文案一字不差）、`registerTask`（三态校验 + 同样两句错误消息）、`hashCode`（`HashBuilder().append(category).append(tag)`）、`toString`（`'${category}-${tag}'`）、`start`（本地 `startName` 为空则回退 `startEventName`）、`emit`（`dispatcher.accept(DataEvent(...))`）。差异只应在「dispatcher 类型」，实际已经扩散到行为：
  1. **判重机制不同**：`AsyncFlow` 用独立的 `flows: ConcurrentHashSet` 判重（`AsyncFlow.cj:73-80`），`ImmediateFlow` 用「`dispatchers` 里有没有这个键」判重（`ImmediateFlow.cj:24-26`）；
  2. **remove 路径不同**：`ImmediateFlow.removeExceptCurrentTag` 在 `removeIf` 谓词里构造实例并判依赖（`48-56`），`AsyncFlow` 改成「谓词只标记、循环后删集合」（`57-72`）；
  3. **start 校验不同**：`AsyncFlow.start` 用 `match` 校验返回值并抛 `GraphException`（`148-151`），`ImmediateFlow.start` 直接 `dispatchers[this].start(...)`（`124`），移除后抛的是 map 索引异常（见 #8）。
- **描述**：约 60 行同形代码，改一处必须记得改另一处；已经出现的三处漂移说明维护同步失败，同一份业务脚本在同步 / 异步流程上会表现不一致（这正是 #2/#8 与第 2 部分 #7/#10 的温床）。注意 `AsyncFlow` 的 5 个 `register*` 包装那种「形状相同但目标不同」不算重复（第 2 部分已判），本条的判据是函数体语义等价。
- **建议**：抽 `abstract class FlowBase<D> <: Flow<...>` 承载 `canBeRemoved` / `registerTask` 校验 / `start` 回退 / `emit` / `hashCode` / `==` / `toString`，两个子类只提供 `dispatcher()`、`ensureRegistered()`、`doRemove(except:)`；落点放在 `f_egraph/src/base`（同模块内，不新建共享包）。抽之前先把 #8 的错误语义定下来，否则会把错误语义一起复制。

### [一般][存量] #6 `ImmediateDispatcher.eventQueue` 无容量上限、只有 `dispatch` 消费，`emit` 只入队不派发 ⇒ 无背压的堆积

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:20`（`LinkedBlockingQueue<Event>()` 无参构造）、`89-91`（`accept` 只 `add`）、`70-88`（唯一消费者）；生产者入口 `f_egraph/src/base/ImmediateFlow.cj:126-128`（`emit` 只 `accept`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §5「无界容器 / 没有拒绝路径」、§12.1「有界性」
- **证据**：静态确定（容量默认值有文档）——`LinkedBlockingQueue()` 无参构造的容量是 `Int64.Max`（`collection_concurrent_class.md:2789`「构造一个具有默认初始容量（`Int64.Max`）的 `LinkedBlockingQueue`」），`add` 永不失败；而 `emit` 不触发 `dispatch`，队列只在下一次 `start()` 里被消费（`Flow_test.cj:229-241` 的 `emitEnqueuesEvent` 就是靠这个语义）。`Event` 的载荷是 `Any`（`Event.cj:67`），下游可放任意大对象。
- **描述**：两条堆积路径：① 外部线程周期性 `emit`、但流程长时间不 `start`（或 `start` 在 End 处提前返回，见 #2-③），队列只增；② 单个任务里 `emit` N 条而下游处理慢，`dispatch` 在跑完之前队列已按 N 增长。最坏规模 = `emit` 速率 × 单事件载荷大小，无上限、无拒绝、无打点，只能到 OOM 才发现。第 2 部分已把该容器作为 `AsyncDispatcher` #1 的「背压缺失」附带提及，本部分给出容器本身的容量与消费语义证据。
- **建议**：构造时给显式容量（配置项，默认值可查询 `f_config`），满时对生产者施加背压（阻塞或抛带上下文的 `GraphException`）；`dispatch` 正常退出（End）与异常退出时都要处理残留：要么清空并打点计数，要么按 `session` 留在队列里但保证不会被下一次 `start` 误消费（依赖 #2 的会话隔离）。

### [一般][存量] #7 `registerTaskByFlow` 的子流程嵌套同步派发没有环检测 ⇒ 自引用 / 互引用流程无限递归（栈溢出）

- **位置**：`f_egraph/src/base/Flow.cj:74-77`（默认实现：`registerTask(eventName) {e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}`）、`83-93`（两个便捷入口）；每层递归的落点 `f_egraph/src/base/ImmediateFlow.cj:118-125`；等价路径 `TaskExecutor.cj:30-31`（`newByFlow`，同模块其它部分）
- **来源**：存量（`git blame -L 74,93 -- f_egraph/src/base/Flow.cj` 为 `4be871f2fd`）
- **判据**：review-checklist §4「间接递归 / 自引用结构」、§11「边界」
- **证据**：静态确定（递归存在、无深度上限、无环检测）——`registerTaskByFlow` 让「任务体」变成「同步启动另一个流程并等它结束」，子流程的 `start` 又调 `dispatch`（`ImmediateDispatcher.cj:92-96`），于是调用栈深度 = 子流程嵌套层数；`dependencied`（`Flow.cj:76`）只用来阻止删除（`ImmediateFlow.cj:28-43`），**不参与任何环检测**。`flow.registerTaskByFlow(eventName: "x", flow: flow)`（把流程挂到自己的事件上）在语法与类型上都合法（`F <: Flow<G>`，`G` 可等于自身的 `G`），一旦该事件被触发就是无限递归：每层都新增一个 `dispatch` 栈帧、一个 `StartEvent`、一条队列。可达性：该 API 未暴露给脚本（`JitHostRegistry.flowMethods` `199-218` 只注册 7 个方法），只有宿主代码能写出环 → 证据等级「静态确定（机制）/ 待确认（真实调用图是否成环）」。
- **描述**：崩溃形态是 `StackOverflow`（不可捕获、整进程退出），而不是可处理的 `GraphException`；同时每层递归都在分配事件对象，先爆栈再爆堆。深度上界不是输入规模，而是**流程定义的图深度**——由宿主（或生成脚本的代码）决定，没有常量上限。
- **建议**：注册时做一次可达性检查（把 `dependencied` 升级成有向图，`registerTaskByFlow` 时 DFS 判环，命中直接抛 `GraphException` 并打印环路径）；运行期再加一道保险：`ImmediateFlow` 维护 `start` 的线程内深度计数（`ThreadLocal<Int64>`），超过常量上限（例如 64）抛明确异常。修好 #2 的会话隔离后，这一步可以顺带用 per-start 句柄上的 `depth` 字段实现。

### [轻微][存量] #8 `ImmediateFlow.start` / `emit` 在流程未登记或被移除后抛非契约异常；本地 `startName` 缺失时静默回退到空串

- **位置**：`f_egraph/src/base/ImmediateFlow.cj:124`（`dispatchers[this].start(...)`）、`127`（`dispatchers.get(this).getOrThrow()`）、`119-123`（`startEventName(...) ?? ""`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「空集合 / `None` 未处理」「契约与实现不符」
- **证据**：静态确定（行为）/ 待确认（具体异常类型）——`ConcurrentHashMap` 的索引运算符文档：「如果键存在，返回键对应的值；如果不存在，抛出异常」（`collection_concurrent_class.md:1835-1846`），因此 `remove()`（`44-47`）之后再 `start()` 抛的是容器异常而不是本模块统一的 `GraphException`；`emit` 同理（`getOrThrow()` 抛 `NoneValueException`）。另一处是 `119-123`：本地 `startName` 为空且 dispatcher 侧也没记录时，`?? ""` 生成 `name = ""` 的 `StartEvent`，最终在 `ImmediateDispatcher.cj:85` 表现为 `No executor found for event: Event(eventType: Start, ..., name: )`——错误信息里看不出「忘了 `registerStart`」。
- **描述**：调用方按 `GraphException` 统一处理流程错误（模块内其它所有失败路径都用它）时，这两条路径会漏网；空名回退把「配置缺失」伪装成「执行器缺失」，排查成本高。
- **建议**：`dispatchers.get(this) ?? throw GraphException('flow ${category}-${tag} is not registered or already removed')`；`startName` 与 dispatcher 记录都为空时抛 `GraphException('start event name is not registered for ${category}-${tag}')`，不要用空串兜底。

### [轻微][存量] #9 `registerEventFields` 四段只差索引与取值字段，属字面量复制

- **位置**：`f_egraph/src/base/JitHostRegistry.cj:54-91`（4 × 10 行，仅 `index:` 与 `e.category`/`e.tag`/`e.name`/`e.session` 不同）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §2「只改字段名 / 字面量复制」
- **证据**：静态确定 —— 四段的 `type` / `mutable` / `accepts` / `setter` 完全相同，`getter` 的 `match` 与默认值完全相同；`eventFields()`（`93-104`）已经是「数组 + 逐项字段」的写法，两处结构不一致。
- **描述**：加第 5 个字段时要改两处（`eventFields` 与 `registerEventFields`），漏一处会出现「描述符里有、运行期访问器没有」的半接线状态（`HostFieldTable.find` 返回 `None` → 运行期 99 号错误）。
- **建议**：改成 `[(0u16, {e: Event => e.category}), (1u16, {e: Event => e.tag}), ...]` 的数组驱动，`eventFields()` 与 `registerEventFields()` 共用同一张表（字段名 + index + getter），从源头保证两边一致。

### [轻微][存量] #10 `Flow.emit` 与 `BaseFlow.emit` 同签名重复声明

- **位置**：`f_egraph/src/base/Flow.cj:41`（`BaseFlow` 内）与 `f_egraph/src/base/Flow.cj:95`（`Flow` 内，签名逐字相同）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §2「重复声明」、§10「可读性」
- **证据**：静态确定 —— `Flow <: BaseFlow`（`61`），`emit(eventType:name:data:)` 在 `41` 已声明，`95` 再声明一次完全相同的签名，没有新增默认实现或收窄类型。
- **描述**：读者会以为子接口有额外约束；实现类（`ImmediateFlow.cj:126-128`、`AsyncFlow.cj:153-155`）只需实现一次。属可读性噪音，无行为影响。
- **建议**：删掉 `Flow.cj:95`。

### [轻微][存量] #11 `testPriorityZeroRunsBeforeQueuedBacklog` 名不副实：没有制造 backlog，断言恒真

- **位置**：`f_egraph/src/base/FlowQueueIntegration_test.cj:53-70`（`67` 注释「先塞一条 p2 到队列，再让流程触发」、`69` `@Expect(counter.executed >= 1, true)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「语义与注释不符」、§10「可测试性」
- **证据**：静态确定 —— 用例体只有 `flow.registerStart` / `registerTask` / `registerEnd` / `flow.start('go')`，注释里说的「p2 事件」**从未提交**（没有 `submit`、没有 `priority: 0` 的事件构造）；`counter.executed >= 1` 在流程跑通时恒为真，无法区分「p0 抢在 p2 之前」与「只是跑了一次」。本模块唯一实现抢占语义的地方（`QueuedClosureTask.submitImmediate`，`QueuedClosureTask.cj:108-142`）因此没有端到端顺序断言。
- **描述**：给维护者「已被覆盖」的错觉；`QueuedClosureTask` 的 p0 顶替、`cancelPrev` 撤销、同名合并这三条语义目前只有 `QueuedClosureTask_test`（同模块第 4 部分）的单元层覆盖，缺一条「提交 backlog → 触发 p0 → 断言执行顺序」的集成用例。
- **建议**：真的先 `task.submit(p2Event)` 造出 backlog，再让流程触发 p0，用有序 `ArrayList<String>` 记录执行序列并断言 `["p0", "p2-merged"]`；或把用例改名为 `flowRunsQueuedTaskOnce` 并把断言收紧到 `== 1`。

<!-- 第 4 部分 -->

### [严重][存量] #1 `runNext` 只在取批时持锁、任务体在锁外执行，且取消令牌只有单槽 ⇒ 多线程投递时同一任务体并发执行、`>=2` 号事件乱序、「顶替」只对最后一个执行生效

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:169-204`（`172-181` 持锁取批、`188` 锁外 `evaluate`、`189-201` 单槽清理、`202` 锁外 `dispatcher.accept`）、`45-46`（`currentName` / `currentToken` 各一个槽）、`180`（新批直接覆盖 `currentToken`）、`68-74`（`exec` = 提交后自排空）；并发路径：`f_egraph/src/base/AsyncDispatcher.cj:116-128`（`asyncExecute` / `asyncDispatch` 逐事件、逐执行器 `spawn`）→ `TaskExecutor.cj:39-41`（`task(event)`）→ `AsyncFlow.cj:127-131`（`registerTask(e, task.exec)` 把同一实例的 `exec` 登记到每个 acceptable 名字）
- **来源**：存量（`git blame -L 100,145 -- f_egraph/src/base/QueuedClosureTask.cj` 全为 2026-11-01 的 `c6cd191aa5`/`da88f4bc4a`/`afb9821e26`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 数据竞争」、§11「契约与实现不符」（类注释 `:31` 承诺「`>=2` 按 `(priority, birth, 入队序号)` 顺序逐条执行」）
- **证据**：静态确定 —— 三条事实叠加：
  1. **任务体会被多线程并发调用**：`AsyncDispatcher.asyncDispatch` 对每个事件 `spawn`（`122-128`），`asyncExecute` 再 `spawn`（`116-121`），最终走到 `TaskExecutor.execute` → `task(event)`，即 `QueuedClosureTask.exec`。同一 `QueuedClosureTask` 实例被 `AsyncFlow.registerTask(task: Task)` 按 `acceptableEvents` 逐个登记（`AsyncFlow.cj:127-131`），所以每次入站事件都在**独立线程**上进入 `exec`；同步侧（`ImmediateFlow` 被两个线程各自 `start`）同理。
  2. **锁不覆盖执行段**：`runNext` 在 `172-181` 取批后立即释放 `mutex`，`188` 在锁外 `evaluate`。两个线程可以各自取一批（`takeBatchLocked` 返回不同批）并**同时**执行任务体；`202` 的 `dispatcher.accept` 谁先到谁先发，与 `birth`/`sequence` 顺序无关。
  3. **取消令牌只有一个槽**：`currentName`/`currentToken` 是单字段（`45-46`）。两个批同时在跑时，后取批的线程在 `180` 覆盖令牌，`submitImmediate` 的顶替判定（`114-123`）只能标记**最后一个**令牌；先跑的那批即使同名、本应被顶替，其 `token.cancelled` 仍为 `false`，结果照常 `accept`（`129-131` 只判自己的 token）。
- **描述**：类注释把「0 号抢占、1 号合并、`>=2` 逐条按 `birth` 顺序」写成契约，实现只保证**单线程驱动**下成立（`:37` 的注释自认「执行由 `runNext()`/`drain()` 驱动（便于单线程确定性）」，但 `exec` 是公开入口且被派发器从多线程调用）。并发下的三个后果都不是「慢」：① 同一任务体并发执行 ⇒ 任务体读写共享状态即数据竞争（`f_llm/src/loom/LoomRunner.cj:295-298` 用 `AsyncFlow` + `QueuedClosureTask` 注册每个步骤，属范围外但证明该组合在仓内真实使用）；② 结果投递顺序与 `birth` 无关，流程后续节点看到的顺序与契约相反；③ 抢占漏判 ⇒ 本应被丢弃的旧结果被 `accept` 进流程（数据陈旧）。三者都依赖「并发投递同一任务」这一条件，但对 `AsyncFlow` 而言这是常态而非异常用法。
- **建议**：三选一，并同步类注释：(a) 增加私有 `execMutex`，`evaluate + accept` 整段串行（最简单，代价是任务体不再并行）；(b) 改「单消费者」——`exec` 只入队，由固定 driver（`spawn` 一次）`drain`，`submit` 不再自排空；(c) 若要保留多批并行，把 `currentToken` 换成 `Map<Int64, CancelToken>`（或按 `name` 分桶）并声明任务体必须线程安全。无论哪种，补一条并发用例：>1 线程 `submit` + 并发 `drain`，断言 `accept` 顺序 = `birth` 顺序、`cancelledCount` = 预期数。

### [一般][存量] #2 任务体抛异常时 `currentToken` / `currentName` 不清理（无 `try`/`finally`）⇒ 槽位永久残留、后续同名 0 号事件被误判为「正在执行」

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:127-141`（`127` `evaluate`，`128-140` 的清理是其后顺序语句）、`188`（同构，`189-201` 为其后的清理）
- **来源**：存量（`git blame -L 100,145`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「错误处理缺失 / 资源不对称」、§3「异常被静默」
- **证据**：静态确定 —— `evaluate` 调用与令牌清理之间无 `try`/`catch`/`finally`，任务体抛出（`f_jit` 脚本错误、宿主闭包抛错，`ClosureTask.cj:145-148` 明确「错误原样上抛」）时 `128-140` / `189-201` 整体跳过：
  1. 槽位残留：`currentName` 仍是该事件名、`currentToken` 仍指向已结束的令牌，且**没有任何路径会再清空它**（清理条件是 `active.id == token.id`，`134`/`192`）。
  2. 误判顶替：下一次同名 0 号事件在 `114-123` 看到 `currentToken.isSome()` 且未 `cancelled` ⇒ 置 `cancelled = true`、`cancelled++`，`cancelledCount`（`151-157`）虚增，且这次的 `cancelled` 永远等不到对应执行结束。
  3. 静默丢失：`takeBatchLocked`（`218-248`）已把批从队列删除，异常向上穿过 `exec` → `TaskExecutor.execute` → `AsyncDispatcher` 的 `spawn` 线程（无人捕获），dispatcher 侧既收不到结果也收不到 `ErrorEvent`——批事件就这样消失。
- **描述**：错误路径与成功路径的清理不对称。触发条件是任意一次任务体异常（脚本编译通过但运行期报错很常见），后果是「取消计数不可信 + 槽位脏死 + 该批事件无声丢失」。第 3 点会让排障变成不可能：日志里看不到该批的去向。
- **建议**：`let result = try { evaluate(payload) } catch (e: Exception) { 在 finally 里按 id 清理令牌槽；再把 e 包成 ErrorEvent 交 dispatcher.accept（或至少 f_log 记录 batch 名字与异常）; rethrow }`；清理逻辑抽成 `clearTokenIfCurrent(token)`，`submitImmediate` 与 `runNext` 共用。

### [一般][存量] #3 批量执行把 `MultiEvent` 的 `session` 换成新 UUID，与单条路径及批内子事件都不一致

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:182-187`（`MultiEvent(category: batch[0].category, tag: batch[0].tag, name: batch[0].name, events: batch)`，未传 `session`）；默认值 `f_egraph/src/base/Event.cj:104-108`（`session! = UUID.random().toHexString()`）
- **来源**：存量（`git blame -L 180,190`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「语义与注释不符 / 契约与实现不符」（同一入口两条路径的 session 语义不同）
- **证据**：静态确定（不一致本身）——`batch.size == 1` 时 `payload` 就是原事件（`182-184`），`session` 原样保留；`batch.size > 1` 时新建 `MultiEvent` 走默认值，得到一条与所有子事件无关的随机 session。`session` 是对外可见的语义字段：`JitHostRegistry.cj:82-92` 把它登记给脚本读取，`BarrierTask.cj:83` 用它作会话聚合键（`BarrierKey(category, tag, name, session)`）。下游影响面为**待确认**（本部分无法确认有多少消费者读 `MultiEvent.session`）。
- **描述**：同一个任务、同一个事件名的结果，单条时 session 属于调用方，批量时属于一个凭空生成的值。若消费者按 session 关联请求（Barrier 聚合、脚本里读 `e.session` 打点），批量路径会关联到不存在的会话；而批内各子事件各自带着不同的原 session（`MultiEvent.data` 是 `Iterable<Event>`），"以谁为准"也没有约定。
- **建议**：传 `session: batch[0].session` 并在注释写明「批内 session 以首条为准（同批通常同会话）」；若确认批内可跨会话，则改为 `session` 保留首条 + 文档标注「批内可能跨会话，勿用 MultiEvent.session 做聚合」。

### [一般][存量] #4 `Flow` 公共入口无法产生 `priority != 2` 的事件 ⇒ `QueuedClosureTask` 的 0/1 号分支在生产路径不可达，只在测试与直接 `submit` 下触发

- **位置**：承诺方 `f_egraph/src/base/QueuedClosureTask.cj:27-31`（「Flow 收到事件后立即调用 `exec(e)`：`priority = 0` 立即执行…`priority = 1` 合并成一批…」）；缺失方 `f_egraph/src/base/Emitter.cj:19`、`Flow.cj:41,95`、`ImmediateFlow.cj:126-127`、`AsyncFlow.cj:153-154`、`FlowEventFactory.cj:31-46`（全部只有 `eventType` / `name` / `data`，构造 `DataEvent` 时不传 `priority` / `cancelPrev`）
- **来源**：存量（`git blame`：`QueuedClosureTask.cj:24-38` 为 `c6cd191aa5`；`emit` 三处为 2026-10/11 提交）
- **判据**：review-checklist §14.1「接线缺失 / 只有一半的分支」、§13「文档承诺与实现不一致」
- **证据**：静态确定 —— 逐个签名核对：`Emitter.emit(eventType:name:data:)`、`BaseFlow.emit` 同签名、`ImmediateFlow.emit` / `AsyncFlow.emit` 直接 `DataEvent(eventType:category:tag:name:data:)`，`priority` 取默认 `2`（`Event.cj:33`），`cancelPrev` 取默认 `0`；`FlowEventFactory` 的 4 个工厂函数也没有这两个参数；脚本面同样不可达——`README.md:85` 明确「脚本**不可用**：事件构造器…」，`JitManualBinding_test.cj:233-238` 另证 `Event.data` 字段都不在注册面。仓内 `priority != 2` 的构造只出现在测试里（`QueuedClosureTask_test.cj:45`、`:72`、`:89-91`、`:129`，均经 `ev(...)` 助手传 `priority`），生产代码无一处。
- **描述**：合并（1 号）、抢占（0 号）、撤销（`cancelPrev`）三条能力写在类注释里并作为「Flow 收到事件后」的行为描述，但 Flow 侧没有任何入口能表达它们：生产流量里所有事件都是 2 号，`takeBatchLocked` 的 `if(priority <= 1)` 分支（`224-238`）与 `submitImmediate`（`108-142`）只被测试覆盖。这既让能力"看起来有、实际用不上"，也让 #1、#2 这两条只影响 0/1 号路径的缺陷长期无人发现（无生产触发）。
- **建议**：二选一并写进 README：给 `emit` 增加 `priority!: Int64 = 2, cancelPrev!: Int64 = 0` 具名参数（`DataEvent` 已支持，改动落在 `Emitter`/`BaseFlow`/`Flow` 三处声明、`ImmediateFlow`/`AsyncFlow` 两个实现与 `FlowEventFactory` 的工厂函数）；或在类注释里明确「优先级仅供宿主直接调用 `submit`，Flow 派发恒为 2 号事件」，并说明为什么不做入口。
- **与第 3 部分的边界**：第 3 部分 #3 讲的是「`ImmediateDispatcher` 路由完全忽略 `priority`/`cancelPrev`」，本条讲「Flow 的 `emit` 无法表达这两个字段 ⇒ `QueuedClosureTask` 的 0/1 分支不可达」，判据文件不同（`Emitter`/`Flow`/`emit` vs `ImmediateDispatcher`），合并时可归到同一根因「优先级只在单点实现」。

### [一般][存量] #5 事件队列无容量上限、无背压、无拒绝路径；`overSizePolicy` 因 `capacity = 0` 永远不生效

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:41`（字段声明）、`54`（`SyncPriorityQueue<QueueEntry>(QueuedClosureTask.compareEntries)`，未传 `capacity`）、`94`（`queue.add`）；容量语义 `f_concurrent/src/SyncPriorityQueue.cj:21-27`（`capacity!: Int64 = 0`）、`f_collection/src/PriorityQueue.cj:103-113`（`capacity > 0` 才走 `overSizePolicy`）、`159-164`（`capacity <= 0` 即「heap is infinity」）
- **来源**：存量（`git blame -L 39,56`：`afb9821e26`/`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §5「无界容器 / 无拒绝路径」、§12.1「有界性」
- **证据**：静态确定（无上限）；增长速度与峰值 **需实测**（见「待验证假设」#2）——`capacity = 0` 在 `PriorityQueue` 里表示无限（`isFull` 只比较内部数组），`DiscardOverSizePolicy` 只在 `capacity > 0` 分支被调用（`104-109`），所以这里的"超限丢弃"策略从未生效。每条 `QueueEntry`（`324-332`）持有一个 `Event`，`DataEvent.data` 是 `Any`（`Event.cj:67`），可以是整包载荷；生产侧是 `AsyncDispatcher` 每事件一条 `spawn`（`AsyncDispatcher.cj:116-128`），消费侧是调用 `exec` 的线程。任务体慢于事件到达时（LLM 步骤、外部 IO），`queue` 单调增长、GC 无法回收，进程内没有任何阈值、TTL、丢弃或拒绝。
- **描述**：按 `backlog × (QueueEntry ≈ 40B + Event ≈ 100–200B + 载荷)` 线性占堆，没有上界也没有观测点（`pending` 只是 `queue.size` 的读取器，没有告警、没有采样）。对长跑服务意味着「压力上来只会表现为 OOM」，而不是明确的拒服务。
- **建议**：构造时给 `capacity`（配 `DiscardOverSizePolicy` 或自定义 `reject` 抛 `GraphException`），或把上限做成配置并在 `submit` 满时快速失败；至少给 `pending` 加周期性打点与阈值告警，让"堆积"可见。

### [一般][存量] #6 0 号事件在提交线程同步 `evaluate`，任务体自提交即无界递归（无深度上限、无环检测）

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:68-74`（`exec` → `submit`）、`90-99`（`immediate` 分支出锁后调 `submitImmediate`）、`108-127`（`submitImmediate` 内 `evaluate` 直接在当前栈执行）
- **来源**：存量（`git blame -L 108,127`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §4「无界递归 / 间接递归」
- **证据**：静态确定（无 `depth` 计数、无队列兜底、无"同一线程已在执行"的标记）；触发需任务体自提交 0 号事件 —— `QueuedClosureTask_test.cj:194-228` 正是这种写法（`slow` 的任务体里 `target.submit(DataEvent(..., name: 'slow', priority: 0))`），说明该模式被当作正常用法并有测试保护。
- **描述**：`exec → submit → submitImmediate → evaluate → (任务体) submit → …` 的递归深度 = 提交链长度，完全由任务体决定。一个"每次运行都重排自己一次"的任务体（常见的自我续跑写法）会一直递归到栈耗尽（崩溃，不是变慢）；同期 `epoch`/`tokenCounter` 正常递增，看不出异常。尾调用不保证优化（清单 §4），不能靠"看起来是尾递归"兜底。
- **建议**：在实例上记录"当前线程正在执行 0 号事件"的标记（或用 `ThreadLocal`）：已在执行时把新 0 号事件**入队**并在当前 `exec` 的 `while(runNext())` 里执行，把递归改成迭代；或保留递归但加 `depth` 上限（如 32）超限抛 `GraphException`，让栈溢出变成可诊断错误。

### [一般][存量] #7 `generation` 对**所有** 0 号事件递增，但注释把它当「被顶替」信号 ⇒ 按注释实现的任务体会误判并交出不完整结果

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:113`（`epoch++` 在 `currentName == e.name` 判定（`114`）之前）、`160-166`（`prop generation`）、`28-29`（注释「其返回结果被丢弃（协作式：Cangjie 无法强杀闭包，任务体可轮询 `generation` 提前退出）」）
- **来源**：存量（`git blame -L 108,125`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「注释承诺 A，实现做 B」
- **证据**：静态确定 —— `epoch` 只在一处递增（`113`），无条件；是否真的取消由 `114-123` 决定。两类 0 号事件对 `generation` 的效果相同，对结果的影响相反：同名 ⇒ `token.cancelled = true`，结果被丢弃（`129-131`/`198-200`）；不同名 ⇒ 不取消，结果照常 `accept`（`QueuedClosureTask_test.cj:231-258` 用 `cancelledCount == 0` 且 `events.size == 2` 固定了这条语义）。
- **描述**：任务体按注释"轮询 `generation` 提前退出"时无法区分这两种情况（它不知道"自己"的 epoch 值，只能比较快照）：别的名字提交一条 0 号事件就会让它提前返回，而它的结果**仍会被投递**（未被取消）——流程拿到一个被截断的结果且没有任何错误标记。这是"按文档写就会错"的语义陷阱。
- **建议**：把"是否被顶替"暴露成可查询对象：`prop cancelled: Bool`（读 `currentToken` 对应令牌，且只在该执行期间有效），或让 `evaluate` 拿到 `CancelToken`；`generation` 明确为"存在新 0 号提交"的观测指标，注释改掉"用它提前退出"的建议。

### [轻微][存量] #8 四处同语义实现（取消批处理 / 序列排序 / 令牌临界区 / 排空循环），且已出现行为漂移

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:264-278`（`dropTailByNameAndPriority`）vs `281-295`（`dropTailSamePriority`，只差 `name` 谓词）；`297-307`（`sortBySequenceDesc`）vs `310-320`（`sortBySequenceAsc`，只差比较方向）；`110-126` vs `172-181` 与 `128-140` vs `189-201`（令牌安装/清理临界区逐行同形）；`68-74`（`exec` 的 `while(runNext())`）vs `207-213`（`drain`）
- **来源**：存量（`git blame`：全部 `c6cd191aa5`/`afb9821e26`，2026-11-01）
- **判据**：review-checklist §2「表现形式不同的重复逻辑」
- **证据**：静态确定 —— 差异点已逐项列出：`dropTail*` 只差一个 `item.event.name == name` 条件；排序两版只差 `<` / `>`；令牌两版本应完全同构，但已经漂移出两处不一致：`runNext` 在**锁外** `accept`（`202`）而 `submitImmediate` 在**锁内**（`128-131`）；`runNext` 用 `if(token.cancelled){ return true }` 早退（`198-200`）而 `submitImmediate` 用 `if(!token.cancelled)` 包裹（`129`）。
- **描述**：复制本身是维护成本，但这里的代价已经具体化：`submitImmediate` 的 `accept` 位置（→ #9）与取消判断的写法不同，说明两份临界区在演进中分叉；`dropTail*` 的 `matched → toArray → 插入排序 → 逐个 removeIf` 四步也是两份手抄（`265-277` / `282-294`）。
- **建议**：合并为 `dropTail(priority: Int64, name: ?String, n: Int64)`（`None` 表示不限名）、`sortBySequence(entries: Array<QueueEntry>, ascending: Bool)`（或直接用 `std.sort` 的 `sort(comparator:)`）；把令牌安装/清理抽成 `installToken(name)` / `clearTokenIfCurrent(token)`，`exec` 直接调 `drain()`。

### [轻微][存量] #9 `submitImmediate` 在持有 `mutex` 时调用 `dispatcher.accept`（外部虚函数），与 `runNext` 的锁外投递不一致

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:128-131`（`synchronized(mutex){ if(!token.cancelled){ dispatcher.accept(result) } … }`）；对照 `202`（`runNext` 在锁外投递）；`dispatcher` 是 `public abstract class Dispatcher`（`Dispatcher.cj:18,47-51`），`accept` 由下游实现
- **来源**：存量（`git blame -L 128,131`：`da88f4bc4a`，2026-11-01）
- **判据**：review-checklist §12.2「临界区只保护不变量；I/O、解析、日志、外部回调一律移到锁外」、§6.2「锁内调用外部回调」
- **证据**：静态确定（调用位置在锁内）；实际影响 **待确认** —— 仓内两个实现的 `accept` 都只是入队（`ImmediateDispatcher.cj:89-91` → `LinkedBlockingQueue.add`；`AsyncDispatcher.cj:67-69` 转发），开销 O(1) 且不阻塞；但 `Dispatcher` 是公开可继承的抽象类，第三方实现的 `accept` 可以做任意事（派发、等待、再入 `submit`）。同线程再入不会死锁（仓颉 `Mutex` 可重入，见「可重入是指线程获取该锁后可再次获得该锁」`stdlib/doc/libs/std/sync/sync_package_api/sync_package_classes.md:8919-8930`），但跨线程若 `accept` 在等一个正在 `submit` 的线程，就会互相等待。
- **描述**：临界区里放了不保护任何不变量的外部调用，且两处入口做法不一致（`runNext` 已经在锁外投递）。修正成本极低，收益是把"锁内未知时长"彻底消掉。
- **建议**：锁内只算 `let dropped = token.cancelled` 并清槽，出锁后 `if(!dropped){ dispatcher.accept(result) }`；与 `runNext` 的形态对齐。

### [轻微][存量] #10 `imports.cj` 有两项全模块零引用的 `internal import`

- **位置**：`f_egraph/src/base/imports.cj:30`（`JitFunction`）、`22`（`Condition`）
- **来源**：存量（`git blame -L 18,35`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §1「无调用者 → 未使用的 import」
- **证据**：静态确定 —— 对 `f_egraph/src` 全量 grep（排除 `imports.cj` 自身）：`JitFunction` 0 处、`Condition` 0 处。`AsyncDispatcher.cj:23-25` 用的是 `endMutex.condition()` 方法而非 `Condition` 类型名，类型由推断得出，不需要该 import。其余 19 项均有引用（`Compiler`/`CompileOptions` 6+、`JitBindSupport` 4、`ClassDescriptor` 15、`PublicCtor` 5、`PublicField`/`PublicMethod` 各 9、`PredefinedFunction`/`JitBindings` 各 2、`LocalType` 28、`DummyDiagnosticsSink` 6、`HostFieldTable` 13、`WeakRef` 2、`MonoTime` 2、`TypeInfo` 6、`LinkedBlockingQueue` 2、`ConcurrentHashMap` 5、`StringGenerator` 2、`ConcurrentHashSet` 8）。
- **描述**：`internal import` 是包级可见（同包各文件无需再写 import，这是本模块 `AsyncDispatcher.cj` 等文件零 import 仍能编译的原因），因此无用项不会被"本文件未使用"的常规 lint 抓到，只会长期留在公共 import 面里误导读者以为这些类型被用到。
- **建议**：删除 `JitFunction` 与 `Condition` 两项；若 `JitFunction` 是为将来扩展预留，加注释说明并接受 lint 提示。

### [轻微][存量] #11 `PriorityQueueBench_test` 把基准塞进单元测试：无断言、毫秒分辨率、对照组不同量纲、固定写 `/tmp`

- **位置**：`f_egraph/src/base/PriorityQueueBench_test.cj:42-51`（`millis()` 用 `DateTime.now().toUnixTimeStamp().toMilliseconds()`、`dump()` 写 `/tmp/pq-bench-*.txt`）、`54-111`（三个 `@TestCase`，`N = 20000`）、`78-80`（对照组用 `remove(at: 0)`）
- **来源**：存量（`git blame -L 34,112`：2026-11 提交）
- **判据**：review-checklist §6.1（证据要求）反向适用：既然没有可复核的对照数据，就不应以"测试"形式产出伪基准
- **证据**：静态确定 —— 三个用例只断言队列被清空（`82`/`96`/`110`），耗时仅落盘不参与判定；1 ms 分辨率下 20k 次 `add`+`remove` 可能整段落入 0–1 ms 区间，落盘值无法区分实现；`testSortedArrayList` 的计时把 `list.remove(at: 0)`（每次 O(n)，共 O(n²)）计入，与堆的 `remove()`（O(log n)）不同量纲，三者不可比；用例在 `src/` 下，`cjpm test` 每次都会跑 3×20000。固定 `/tmp` 路径在非 WSL 环境会失败（项目约定测试在 WSL 跑，可接受，但也说明它不是可移植的基准）。
- **描述**：这份文件唯一能成立的信息是"哪种结构被选中"，真正的结论（谁快、快多少）无法从落盘的一个整数得出；同时它拖慢常规测试。仓内也没有对应的 bench 套件在用它。
- **建议**：改成 `@Bench` 基准或独立 `bench/` 目录（`cjpm bench -O2`、多轮取中位数、输出到 stdout）；对照组只保留语义等价的 `add` + `remove`（去掉 `remove(at: 0)` 或用双端队列替代），并把 `N` 做成参数。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分为空。5 个文件全是 `.md`，没有循环、容器、锁、序列化或字符串拼接，不存在可度量的 CPU / 堆内存优化对象；与性能相关的两条线索（`proposal.md` 的手工适配器收益宣称、`docs/LocalMode.md` 对 `takeBatchLocked` 的结论）都没有改前基线，只能进「待验证假设」。

<!-- 第 2 部分 -->

> 以下都不是缺陷（缺陷见上），是「还能更好」；**全部没有改前基线**，故只作待验证方向，不进 `todo.md` / `tasks.md`。

### [CPU] 把「事件 → 两层 spawn」换成有界执行器

- **现状**：每个事件至少 2 次线程创建：`asyncDispatch`（`AsyncDispatcher.cj:123`）→ 每个执行器一次 `asyncExecute`（`117`）；`AsyncTaskExecutor.execute` 还会再 `spawn` 一次（`AsyncTaskExecutor.cj:36-40`）。线程创建 + 调度 + 栈分配的单次开销远大于事件本身的路由成本，且 `spawn` 无上限、无复用（`spawn` 语义见 `create_thread.md:3`）。
- **方案**：`AsyncDispatcher` 持有固定大小的 `ThreadPool`/`Executor`（复用 `f_concurrent` 或 `f_pool` 里的能力，若已有；否则用固定 worker 数 + 有界队列），`doDispatch` 只提交任务；`AsyncTaskExecutor` 直接复用同一执行器而不是自己 `spawn`。
- **预期**：线程数与并发度解耦（常数 vs ∝在途事件数）；线程创建开销从「每事件 2 次」降到「每 worker 一次」。端到端收益取决于事件处理体本身的耗时占比（未测）。
- **代价**：并发模型从「无界并行」变为「有界并行」，长任务可能互相排队，需要评估单任务耗时；`spawn` 的「线程即隔离」语义（异常不传染）会变成「线程池内异常」——必须配合 #4 的异常回填，否则会把单个坏任务升级成 worker 丢失。
- **验证**：同机同 SDK `-O2`，固定输入（例如 10k 个事件、4 阶段流程、并发 8），对比 `cjprof record` 中线程创建/调度占比与 P50/P99 端到端延迟、峰值线程数（`/proc/<pid>/status` 或运行时统计）。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 缩小 `removeIf` 的临界区，别在 `mutex` 内跑用户谓词

- **现状**：`AsyncDispatcher.removeIf`（`103-107`）与 `getExecutors`（`149-153`）都在 `mutex` 内调用 `dispatcher` 的方法，前者还把**调用方传入的谓词**（公开 API `predicate: (Event) -> Bool`）整个包在临界区里；`AsyncFlow.doRemove` 的谓词会构造对象、算 hash、查 `flows` 集合、可能拼异常消息（`AsyncFlow.cj:59-68`）。
- **方案**：`removeIf` 改为「锁内只做快照/标记 + 锁外执行谓词 + 再次加锁确认删除」，或让 `ImmediateDispatcher` 维护「category → tag → 事件」的索引，把 `O(全部执行器)` 的遍历降为按 `category` 定位。
- **预期**：锁持有时间从 `O(全部注册事件) + 谓词耗时` 降到 `O(该 category)`，注册/启动路径的偶发长尾减少（未测）。
- **代价**：快照 + 二次确认会引入 ABA/竞态，需要明确「谓词执行期间新注册的执行器是否也要删」的语义；实现复杂度上升。
- **验证**：`cjprof` 看 `removeIf`/`registerStart` 的阻塞时长，或加埋点记录 `mutex` 等待时间（P99），在「每秒启动 N 个流程 + 周期性 remove」的压测下对照。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `BarrierTask.datas` 与 `eventQueue` 的有界化

- **现状**：`BarrierTask.datas`（`BarrierTask.cj:42`）按 `session` 累积 `ArrayList<Any>`，只有凑满阈值才删（见 #8）；`ImmediateDispatcher.eventQueue` 用 `LinkedBlockingQueue<Event>()` 无参构造 → 容量 `Int64.Max`（`collection_concurrent_class.md:2789`），生产者（`emit`，任何线程）快于消费者时无条件堆积。
- **方案**：`datas` 加「会话 TTL + 总条目上限」，超限按最旧会话淘汰并打点；`eventQueue` 改为显式容量（例如按 `--queue-capacity` 之类的配置），满时对生产者施加背压（阻塞或拒绝 + 明确异常）而不是无限追加。
- **预期**：等待中的会话不再无界累积；队列峰值内存可估算（容量 × 单事件大小），从「到 OOM 才知道」变成「有明确上限与拒绝路径」。
- **代价**：背压会把压力传导回 `emit`/`start` 调用方，需要确认框架侧是否接受阻塞；TTL 淘汰会让「慢会话」丢失聚合数据（需业务确认可接受）。
- **验证**：多轮压测下 `getAllocatedHeapSize()` + RSS 是否达到有界稳态（`mem §1.2`），并统计「被淘汰会话数 / 队列拒绝次数」。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 3 部分 -->

> 以下不是缺陷，是「还能更好」；两条都**没有改前基线**，只作待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] 事件 `session` 默认值（每事件一次 UUID + 36 字符）在同步流程里完全用不到

- **现状**：`Event` 及其 7 个子类的构造器都把 `session` 默认成 `UUID.random().toHexString()`（`Event.cj:32,63,78,84,90,96,101,106,125`），即每个事件固定付一次 UUID 生成 + 两次 36 字符 `String` 分配；而唯一消费 `session` 的是 `BarrierTask` 的会话聚合（`BarrierTask.cj:18-27`，同模块其它部分）。`ImmediateDispatcher` 的路由键只看 `(eventType, category, tag, name)`（`Event.cj:43-48`），完全不读 `session`。
- **方案**：把 `session` 改成惰性 / 可选：默认空串，由需要会话维度的调用方（`BarrierTask` 路径）显式传入；或提供 `Event.withNewSession()` 在需要时补。改动点集中在 `Event.cj` 的默认参数，语义上「session 为空」= 不参与聚合。
- **预期**：每次事件构造少一次 UUID + 2 个 36 字符串；按 `perf` 层面的收益取决于事件吞吐（未测）。峰值内存下降量 ≈ 事件峰值数 × 约 100 B。
- **代价**：`session` 为空时 `BarrierTask` 的 key 需要明确处理（拒绝或退化为按 category/tag 聚合），属语义变化，需要业务确认；事件相等性不受影响（`==` 不含 session）。
- **验证**：同机同 SDK `-O2`，固定 10k 事件 × 4 阶段流程，对比 `getAllocatedHeapSize()` 增量与 `cjprof record` 中 `UUID`/`String` 分配占比、P50/P99 端到端耗时。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `EventType.hashCode` 每次调用都插值一个包名限定串

- **现状**：`EventType.hashCode()` 实现为 `'fountain::f_egraph.base.EventType.${this}'.hashCode()`（`EventType.cj:36-38`），每次调用一次 `StringBuilder` + `toString` + 字符串哈希；而每个 `Event` 构造都会经 `HashBuilder().append(eventType)`（`Event.cj:43`）触发它一次，`Event` 又是流程每一步的必建对象。
- **方案**：6 个枚举值的哈希是常量，改成 `static let` 预计算表（或 `match(this)` 返回 6 个字面量常量），`hashCode()` 只做一次数组 / 分支查找；包名限定串只在确需稳定跨版本哈希时保留，并在注释里写明理由。
- **预期**：每次事件构造少一次字符串分配与哈希；端到端收益取决于事件吞吐与 GC 压力（未测）。
- **代价**：哈希值变成代码内常量，若历史上已有持久化依赖这些哈希值（本模块未见），需要迁移说明；改动面仅 `EventType.cj`。
- **验证**：`cjpm bench -O2` 对「构造 N 个 `Event` + 插入 `HashMap<Event, _>`」做前后对照（N = 1e6，重复 5 轮取中位数），并用 `cjprof` 看 `EventType.hashCode` 的自耗时占比是否可测。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 4 部分 -->

> 以下不是缺陷，是「还能更好」；两条都**没有改前基线**，只作待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] `takeBatchLocked` 每批都 `queue.toArray()` 全量复制一次

- **现状**：`takeBatchLocked`（`QueuedClosureTask.cj:218-248`）每取一批就 `queue.toArray()`（`227`）拿到**整个队列长度**的临时数组，再筛出匹配项、`matched.toArray()`（`232`）再复制一次；批内每个元素还要 `queue.removeIf`（`236`）一次，而 `removeIf` 内部对整个堆数组做一次 O(n) 压实（`f_collection/src/PriorityQueue.cj:239-258`）。等价于每批 O(n) 临时内存 + O(k·n) 堆操作。
- **方案**：给队列加"按 `(priority, name)` 分桶"的二级索引（`HashMap<(Int64,String), ArrayDeque<QueueEntry>>` + 一个按 `(priority, birth, seq)` 取最小桶的堆），批处理直接取整桶、O(k) 出队；或退一步：先 `toArray` 取出全部条目，一次 `removeIf` 删掉本批（`removeIf` 内部只做一次压实），把 k 次 `removeIf` 降为 1 次。
- **预期**：单批临时数组从 O(n) 降到 O(k)；`drain` 一批的开销从 O(k·n) 降到 O(n)（或 O(k)）。峰值内存下降量 ≈ `backlog × 16B`（`Array<QueueEntry>` 引用）级别，量级取决于 backlog。
- **代价**：一次 `removeIf` 需要把整批 `sequence` 放进 `HashSet`（或改用范围谓词），谓词里不能再依赖"逐条删除"；分桶方案则要维护索引与主队列的一致性，复杂度更高。
- **验证**：同机同 SDK `-O2`，固定 `n = 10k`（priority 1，同名与 `n` 个不同名两种分布）× 5 轮取中位数，对比 `getAllocatedHeapSize()` 增量、P50/P99 `drain` 耗时、`cjprof` 中 `PriorityQueue.removeIf`/`toArray` 的自耗时占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 批量取批路径的复杂度与排序都还有余量

- **现状**：`priority <= 1` 的批路径实际复杂度是 O(n)（`toArray`）+ O(k·n)（k 次 `removeIf`）+ O(k²)（`sortBySequenceAsc` 插入排序，`310-320`）；`priority >= 2` 的路径只有一次 `queue.remove()`（O(log n)），两条路径差一个量级。`dropTail*`（`264-295`）是同样的 O(n) + O(limit·n)。
- **方案**：① 用一次遍历 + 重建堆替代 k 次 `removeIf`（见上条）；② 批内排序换 `std.sort` 的比较排序（O(k log k)），或利用 `sequence` 单调性用计数/桶排；③ `dropTail*` 合并为一趟收集 + 一趟重建。
- **预期**：批处理与取消两条路径从 O(n²) 降到 O(n log n)；k 较大（同名高频事件合并）时收益最大。
- **代价**：批量删除要靠 `removeIf` 一次谓词完成（`PriorityQueue.removeIf` 已是 O(n) 单趟压实，`f_collection/src/PriorityQueue.cj:239-258`），谓词需支持"整批序号集合"判断；`std.sort` 需要 `Comparator`，会引入一次函数调用开销。
- **验证**：`cjpm bench -O2` 对 `submit`+`drain` 做前后对照（n = 1k/10k/100k，同名比例 0%/50%/100%），报绝对值、中位数、离散程度；`cjprof record` 确认 `removeIf` 是否真的是自耗时大头（否则不做）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 宿主成员从反射 MCC 路径切到手工适配器后调用更快（`proposal.md` 称"性能：宿主成员从反射 MCC 路径切到手工适配器（直接方法调用）"） | `f_egraph/doc/spec/f-egraph-jit-flow-init/proposal.md:160-161` | 无任何绝对值、调用次数、自耗时占比；无法判断 JIT→宿主调用的占比是否高于噪声 | `cjpm bench -O2` 同机对照：同一 `ClosureTask` 任务体分别在宏绑定 / 手工适配器两条注册路径下跑 10 万次事件，取中位数与 P95；或 `cjprof record` 看 JIT 调用栈里宿主适配器帧的 self time |
| 2 | `QueuedClosureTask.takeBatchLocked` 的"整队列 `toArray()` 快照"是 f_egraph 的分配峰值热点 | `f_egraph/src/base/QueuedClosureTask.cj:218-248`（属第 4 部分）；口径来自 `docs/LocalMode.md:421-423`、`docs/LocalMode-O2-Plan.md:112` | 上游资料是静态分析结论（"逃逸，不改"），没有分配量 / RSS / 队列深度对照 | 队列深度 1k 与 10k 两档，`getAllocatedHeapSize()` + RSS + `cjprof heap` 对照；同时统计 batch.size>1（走 `MultiEvent`，`:182-187`）的比例，确认快照副本是否真的成为峰值主因 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 线程-per-事件（两层 `spawn`）的创建/调度开销占端到端耗时的主要部分 | `AsyncDispatcher.cj:117,123`、`AsyncTaskExecutor.cj:37` | 线程创建 + 调度自耗时占比、10k 事件下的线程峰值 | `cjprof record` 跑 4 阶段流程 × 10k 事件、并发 8；同时采 `Thread.getAllThreads()`/`/proc/<pid>/status` 的线程数曲线 |
| 2 | 每次 `start()` 一个常驻消费线程会把 RSS 推到不可接受（默认栈保留 × 启动次数） | `AsyncDispatcher.cj:138-148` | 单线程栈实际占用、连续 1 万次启动后的 RSS/线程数 | 循环 `AsyncFlow.start` 1 万次（不 `get`）后采 RSS 与线程数；对照改为单消费者版本 |
| 3 | `BarrierTask` 的未完成会话在真实业务里占比很低，因此 #8 的内存增长是慢性的而非突发 | `BarrierTask.cj:42,85-94` | `datas.size` 随时间/请求量的曲线、未完成会话比例 | 给 `datas` 加 `size` 打点，跑 30 分钟稳态 + 20% 失败注入 |
| 4 | `removeIf` 在 `mutex` 内的持有时长已成为注册路径的长尾 | `AsyncDispatcher.cj:103-107`、`AsyncFlow.cj:59-68` | `mutex` 等待时间 P99、执行器总数 | 埋点记录 `synchronized` 前后时间差，压测「频繁 start + 周期性 removeExceptCurrentTag」 |
| 5 | 并发构造同一 `(category, tag)`（#7）在真实调用图上是否可达 | `AsyncFlow.cj:75-81` | 运行期 `AsyncFlow(...)` 构造的并发度、重复构造次数 | 在构造器加计数器（同 tag 并发进入次数），跑真实网关流量或 100 并发 `start` |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 事件路由（`HashBuilder` 构造 + `HashMap<Event>` 查找 + `Event.==` 的 4 次字符串比较）占单步流程耗时的主要部分 | `Event.cj:43-48`、`ImmediateDispatcher.cj:109-111` | 该路径自耗时占比、每步平均耗时 | `cjprof record` 跑 4 阶段流程 × 10k 事件、并发 1/8，看 `hashCode`/`equals`/`HashMap.get` 占比 |
| 2 | 每事件一次 UUID `session` 的分配占 GC 时间的主要部分 | `Event.cj:32` 等 9 处 | 分配量占比、GC 次数 | `cjprof heap` 对比「保留默认 session」与「session 传空串」两种构建的分配量与 GC 停顿 |
| 3 | 重复 `configure` 后 `HostFieldTable.find` 的桶内线性扫描已成为脚本字段读的瓶颈 | `JitHostRegistry.cj:54-91`、`HostField.cj:121-133` | 桶长度、`find` 自耗时 | 在 `f_llm` 侧统计 `configure` 调用次数与桶长度，`cjprof` 看 `find` 占比（输入：1 个 Loom 编译 1k 个任务的脚本） |
| 4 | 长跑服务里 `ImmediateFlow.dispatchers` 随 `(category, tag)` 数量单调增长（脚本动态生成 tag 时无回收） | `ImmediateFlow.cj:19`、`44-56` | 运行 24h 后的 key 数、`remove` 调用次数 | 给 `dispatchers.size` 加周期性打点，跑 24h 真实流量（含滚动发布换 tag） |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 批量取批的 O(n²)（`toArray` + 逐条 `removeIf` + 插入排序）在 backlog 上千后成为 `drain` 的主要耗时 | `QueuedClosureTask.cj:218-248,310-320` | 各函数自耗时占比、n 多大时劣于 `>=2` 路径 | `cjprof record` 跑「10k 条 priority=1 同名事件 → `drain`」，并发 1/8，看 `removeIf`/`toArray`/`sortBySequenceAsc` 占比 |
| 2 | 事件到达快于任务体执行时 `queue` 无界增长（无背压） | `QueuedClosureTask.cj:41,54,94` | 稳态 backlog 曲线、RSS 增长速率 | 埋点周期性记录 `pending`/`getUsedHeapSize()`/RSS，跑 30 分钟 >消费速率的压测（任务体固定 sleep 50ms，提交 200/s） |
| 3 | `takeBatchLocked` 持锁做 O(n) 工作会拉长 `submit` 的等锁时间（尤其并发提交时） | `QueuedClosureTask.cj:172-181` + `227-244` | 锁等待时长、P99 `submit` 延迟 | 线程状态采样（BLOCKED/WAITING 时长）+ 分段计时，8 线程 submit、backlog 10k |
| 4 | 任务体并发执行在 `AsyncFlow` 场景下的实际触发频率（是否存在同一 task 同名事件并发到达） | `QueuedClosureTask.cj:169-204`；`AsyncDispatcher.cj:116-128` | 生产/压测中同名事件并发度 | 在 `exec` 入口加线程 id + 并发计数埋点，跑 `f_llm` Loom parallel 场景与 `f_rule` 异步流程，统计重入次数 |

## 文件覆盖

> 与 `files/f_egraph.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_egraph/README.md` | .md | ✅ | — |
| 2 | `f_egraph/README_en.md` | .md | ✅ | — |
| 3 | `f_egraph/doc/spec/f-egraph-jit-flow-init/design.md` | .md | ✅ | — |
| 4 | `f_egraph/doc/spec/f-egraph-jit-flow-init/proposal.md` | .md | ✅ | — |
| 5 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-flow-script/spec.md` | .md | ✅ | — |
| 6 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-jit-binding/spec.md` | .md | ✅ | — |
| 7 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-test-coverage/spec.md` | .md | ✅ | — |
| 8 | `f_egraph/doc/spec/f-egraph-jit-flow-init/tasks.md` | .md | ✅ | — |
| 9 | `f_egraph/src/FlowInitializer_test.cj` | .cj | ✅ | — |
| 10 | `f_egraph/src/FlowScriptRunner.cj` | .cj | ✅ | — |
| 11 | `f_egraph/src/base/Accepter.cj` | .cj | ✅ | — |
| 12 | `f_egraph/src/base/AsyncDispatcher.cj` | .cj | ✅ | — |
| 13 | `f_egraph/src/base/AsyncDispatcher_test.cj` | .cj | ✅ | — |
| 14 | `f_egraph/src/base/AsyncEndExecutorGetter.cj` | .cj | ✅ | — |
| 15 | `f_egraph/src/base/AsyncFlow.cj` | .cj | ✅ | — |
| 16 | `f_egraph/src/base/AsyncFlow_test.cj` | .cj | ✅ | — |
| 17 | `f_egraph/src/base/AsyncTaskExecutor.cj` | .cj | ✅ | — |
| 18 | `f_egraph/src/base/BarrierTask.cj` | .cj | ✅ | — |
| 19 | `f_egraph/src/base/BarrierTask_test.cj` | .cj | ✅ | — |
| 20 | `f_egraph/src/base/ClosureTask.cj` | .cj | ✅ | — |
| 21 | `f_egraph/src/base/ClosureTask_test.cj` | .cj | ✅ | — |
| 22 | `f_egraph/src/base/ConcurrentEndExecutor.cj` | .cj | ✅ | — |
| 23 | `f_egraph/src/base/Dispatcher.cj` | .cj | ✅ | — |
| 24 | `f_egraph/src/base/Emitter.cj` | .cj | ✅ | — |
| 25 | `f_egraph/src/base/EndExecutor.cj` | .cj | ✅ | — |
| 26 | `f_egraph/src/base/EndExecutorGetter.cj` | .cj | ✅ | — |
| 27 | `f_egraph/src/base/ErrorExecutor.cj` | .cj | ✅ | — |
| 28 | `f_egraph/src/base/Event.cj` | .cj | ✅ | — |
| 29 | `f_egraph/src/base/EventType.cj` | .cj | ✅ | — |
| 30 | `f_egraph/src/base/EventType_test.cj` | .cj | ✅ | — |
| 31 | `f_egraph/src/base/Event_test.cj` | .cj | ✅ | — |
| 32 | `f_egraph/src/base/Executor.cj` | .cj | ✅ | — |
| 33 | `f_egraph/src/base/Executor_test.cj` | .cj | ✅ | — |
| 34 | `f_egraph/src/base/Flow.cj` | .cj | ✅ | — |
| 35 | `f_egraph/src/base/FlowEventFactory.cj` | .cj | ✅ | — |
| 36 | `f_egraph/src/base/FlowEventFactory_test.cj` | .cj | ✅ | — |
| 37 | `f_egraph/src/base/FlowQueueIntegration_test.cj` | .cj | ✅ | — |
| 38 | `f_egraph/src/base/Flow_test.cj` | .cj | ✅ | — |
| 39 | `f_egraph/src/base/ImmediateDispatcher.cj` | .cj | ✅ | — |
| 40 | `f_egraph/src/base/ImmediateDispatcher_test.cj` | .cj | ✅ | — |
| 41 | `f_egraph/src/base/ImmediateExecutor.cj` | .cj | ✅ | — |
| 42 | `f_egraph/src/base/ImmediateFlow.cj` | .cj | ✅ | — |
| 43 | `f_egraph/src/base/JitBinding_test.cj` | .cj | ✅ | — |
| 44 | `f_egraph/src/base/JitHostRegistry.cj` | .cj | ✅ | — |
| 45 | `f_egraph/src/base/JitHostRegistry_test.cj` | .cj | ✅ | — |
| 46 | `f_egraph/src/base/JitManualBinding_test.cj` | .cj | ✅ | — |
| 47 | `f_egraph/src/base/PriorityQueueBench_test.cj` | .cj | ✅ | — |
| 48 | `f_egraph/src/base/QueueCapacityRegression_test.cj` | .cj | ✅ | — |
| 49 | `f_egraph/src/base/QueuedClosureTask.cj` | .cj | ✅ | — |
| 50 | `f_egraph/src/base/QueuedClosureTask_test.cj` | .cj | ✅ | — |
| 51 | `f_egraph/src/base/StartExecutor.cj` | .cj | ✅ | — |
| 52 | `f_egraph/src/base/Task.cj` | .cj | ✅ | — |
| 53 | `f_egraph/src/base/TaskExecutor.cj` | .cj | ✅ | — |
| 54 | `f_egraph/src/base/imports.cj` | .cj | ✅ | — |
| 55 | `f_egraph/src/egraph.cj` | .cj | ✅ | — |
| 56 | `f_egraph/src/exception/GraphException.cj` | .cj | ✅ | — |
| 57 | `f_egraph/src/exception/GraphException_test.cj` | .cj | ✅ | — |
| 58 | `f_egraph/src/loader/FlowLoader.cj` | .cj | ✅ | — |

合计：`.cj` 50 个 / `.md` 8 个 / 共 58 个，全部读完。

## 覆盖自检

### 第 1 部分

> 本部分没有 `.cj`，因此各专项的检查对象是"这 5 个文件里的每一条声明、示例、契约"。源码只作为取证依据被引用，不代替第 2–4 部分。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分是文档，代码级正确性结论不在此产生；发现的 9 处与实现不符全部归入 §13 行（不重复计数）。安全性方面：README 无凭据、无外部输入拼接、无敏感数据示例；可读性方面结构与术语统一（唯一术语错在发现 2c 已记） |
| §1 死代码 | 0 | 本部分无 `.cj`，无 `private` / `internal` / `protected` 符号可判。对文档做了同构的双向核对：① README/design 里点名的每个类型与成员是否在 `src` 存在（`Event`/`DataEvent`/`MultiEvent`/`EmptyEvent`/`ConcurrentEndExecutor`/`JitHostRegistry`/`registerMultiTask`/`startEventName`/`BarrierKey`/`QueuedClosureTask` 等逐个 grep 命中，0 个"文档写了代码没有"）；② `src` 的 `public` 顶级声明是否都在 README 出现（缺失项见 §14 行，不在本节重复） |
| §2 重复逻辑 | 1 | README 的流程脚本示例在 `README.md:45-62` 与 `:816-833` 逐字重复（发现 9）；其余重复（`README` 声明块 vs `src` 源码）属于本模块既有的"逐字抄写"体例，按 §2 误报边界（可读性刻意展开）不判为重复缺陷，但其漂移后果已在发现 1 单列 |
| §3 空实现 | 0 | 逐个核对文档承诺的入口均有实现：`FlowInitializer.initialize` 4 步（`src/egraph.cj:37-44`）、`JitHostRegistry.configure` 的全部注册动作（4 条字段访问器 + 8 个事件类 + `Emitter`/`BaseFlow` + `ImmediateFlow`/`AsyncFlow` + `Task`/`ClosureTask`/`FlowEventFactory`，`src/base/JitHostRegistry.cj:37-49`）、`FlowEventFactory` 5 个工厂（`src/base/FlowEventFactory.cj:31-58`）、`ClosureTask.compile`/`initCompiler`（`src/base/ClosureTask.cj:56-101`）；`grep -rn "TODO\|FIXME" src` 零命中；本部分无 `catch` 块可判静默吞异常 |
| §4 栈溢出 | 0 | 文档未描述任何递归；唯一"嵌套"是 `Flow.registerTaskByFlow` 的子流程同步启动 `flow.start(...).get().get()`（`src/base/Flow.cj:75`），深度由静态编排（`registerTaskByFlow` 的调用层数）决定，不存在输入可控的递归或自引用结构。附带信息：文档没有给"子流程嵌套层数"建议上限，属可选补充，未单列 |
| §5 OOM | 0 | 本部分无代码；文档没有承诺任何容量 / 上限 / 背压，因此不产生"承诺有界而实现无界"的文档缺陷。`BarrierTask.datas` 无界累积（`src/base/BarrierTask.cj:42`、`:82-96`）属第 4 部分；`AsyncDispatcher` 清理线程（`src/base/AsyncDispatcher.cj:32-39`）属第 3 部分，均只作范围外提示 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；`proposal.md` 的收益宣称与 `LocalMode.md` 的 `takeBatchLocked` 结论都缺改前基线，已进「待验证假设」1/2，不作发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁代码。文档侧相关缺口是"没有并发章节、未说明 `AsyncDispatcher` 的互斥范围"，已在发现 2b / 5 计入 §13、§12 行 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 Future、无线程池。文档提到"增加一个清除线程"但未描述其并发影响，并入发现 2b |
| §6.4 低效算法 | 0 | 本部分无循环 / 查找 / 字符串拼接；`takeBatchLocked` 的整队列扫描属第 4 部分 |
| §7 降堆内存方案 | 0 | 无代码即无对象生命周期可改；本部分不产出方案（无基线，按规则也不能写成方案） |
| §8 降 CPU 方案 | 0 | 同上；唯一 CPU 相关线索是 JIT→宿主调用开销，已进待验证假设 #1 |
| §9 local mode 可行性 | 0 | 本部分无函数体；`docs/LocalMode.md:330`、`:421-423` 对 `f_egraph` 的结论已复核（`takeBatchLocked` 整队列快照、batch 进 `MultiEvent` 逃逸），按"无前后峰值数据只能是待验证假设"处理，记入待验证假设 #2，不作方案 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码可判。对文档引用到的 12 个实现点（`StartExecutor` 改写、`EndExecutor` 返回值、`AsyncDispatcher.get` 阻塞、`AsyncFlow` 静态 dispatcher、`Multi` 路由键、`ClosureTask` 校验、`JitHostRegistry` 注册面、`EmptyEvent` 类型、`registerTask` 顺序校验等）逐个比对，发现的不符**全部是文档侧错误**，已计入 §13 行；源码自身的逻辑缺陷由第 2–4 部分判，不在本节重复 |
| §12 并发安全与锁粒度 | 2 | 命中 2 条，均为"并发契约未文档化"：发现 2b（`AsyncFlow` 全局 dispatcher 与 `AsyncDispatcher.get` 阻塞语义）与发现 5（缺并发章节）。本部分无代码，锁粒度 / 竞态本身不在此判 |
| §13 文档与代码一致性（.md） | 9 | 发现 1、2a、2b、2c、3、5、6、7、8；已逐文件对照 `src` 取证（每条给文档行号 + 代码行号）。同一发现可同时命中多个小节（如 3、5 也命中 §14），统计按小节计 |
| §14 功能完备性与 README 覆盖 | 3 | 发现 3（`MultiEvent.name` 约束缺失）、4（6 个公开 API / 能力的语义缺失）、5（缺"并发与限制"关键段落）。反方向核对：README 承诺的 JIT 能力（`compile` + 5 个 `flow*` 入口、`registerMultiTask` 内部入口、`BarrierTask` 不可绑定）全部有实现，无"承诺但没做" |
| 文件覆盖（§13 等） | 5/5 | 与 `files/f_egraph.part1.txt` 五条一一对应，无缺文件；第 2 部分的 3 个 `.md`（`f-egraph-jit-binding/spec.md`、`f-egraph-test-coverage/spec.md`、`tasks.md`）与 50 个 `.cj` 不在本部分清单内 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性见 #1-#13；设计见 #2（把「一次启动」的关联退化在线程 id 上）、#12；语言特性见 #5（普通 `var` 跨线程读写）、#9（`Condition.wait` 的负超时语义）；可读性见 #14、#15；安全性 0 条——本部分不处理外部输入、无 SQL/命令/路径拼接、无凭据 |
| §1 死代码 | 0 | 已逐符号执行机械检查：`private`/文件内私有的 `log`/`mutex`/`endMutex`/`end`/`endCondition`/`dispatcher`/`notifyEnd`/`asyncExecute`/`asyncDispatch`/`doDispatch`/`getExecutors`/`getEvent`（AsyncDispatcher）、`dependencied_`/`flows`/`h`/`startName`/`hasFirstTask`/`doRemove`（AsyncFlow）、`name_`/`events_`/`datas`/`acceptable`/`producing`/`flow`（BarrierTask）、`compilerMtx`/`sharedCompiler`/`name_`/`acceptable_`/`producing_`/`body_`/`ensureCompiler`/`stringEvents`（ClosureTask）、`end`（EndExecutor）、`run`（FlowScriptRunner）全部有引用；`internal` 的 `Dispatcher.registerMultiTask`/`startEventName` 被 `AsyncFlow` 使用，`FlowScriptRunner` 被 `egraph.cj:42` 使用；`AsyncFlow.resetDispatcherForTest`/`ClosureTask.resetCompilerForTest` 只被 `*_test.cj` 引用，按 §1「仅测试使用」只算可见性建议、不算死代码；`protected` 的 `Dispatcher.dispatch`/`doRegisterMulti`/`doStartEventName` 有实现与调用，`ClosureTask.evaluate` 属 `public open class` 的成员且被 `QueuedClosureTask` 调用；`public` 声明经 `egraph.cj:23` 的 `public import` 对外可达，按硬原则一不判（`AsyncTaskExecutor`/`ConcurrentEndExecutor` 仓内只有测试引用，记「对外 API，仓内无引用」）；逐个检查 `return`/`throw`/`continue` 之后无同层语句，无 `if(false)`，无未使用的 `import`（`internal import` 集中在 `imports.cj`，被同包文件共用） |
| §2 重复逻辑 | 2 | 已把本部分 17 个 `.cj` 里可执行函数体压成「输入→输出→副作用」逐一比对：命中 #14 的 (a) `ClosureTask.exec`/`evaluate`（同体）、(b) `AsyncDispatcher`/`ConcurrentEndExecutor` 的等待模板；`AsyncDispatcher` 的 5 个 `register*` 包装虽形状相同但目标方法不同，判为不重复；`AsyncDispatcher.tryGet()` 与 `tryGet(timeout:)` 是同一包装的两种形态（保留）；测试里的 `scriptsOf`/`list`（`FlowInitializer_test.cj:54-60` vs `ClosureTask_test.cj:33-39`）属「测试准备代码」误报边界，不报 |
| §3 空实现 | 2 | `BarrierTask.exec` 在 `flow` 未注入时 `flow?.emit` 静默不发射、却照样 `datas.remove(key)`（`92-93`），聚合数据静默丢失；`AsyncFlow.doRemove` 在 `dispatcher == None` 时 `dispatcher?.removeIf` 静默不做事（`59`）。两处都无注释说明「为什么可以空」。其余无空函数体、无 `TODO`、无 `catch {}` |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`multiEventTaskBody`（`Flow.cj:48-60`）是迭代；`AsyncTaskExecutor`/`AsyncDispatcher` 的嵌套是「新线程」而非调用栈，不加深栈帧。跨层同步嵌套（`registerTaskByFlow` 在同一线程里启动子流程）在 `Flow.cj:74-77`，属第 1 部分范围，本轮不展开 |
| §5 OOM | 3 | #1（线程数随启动次数无界）、#8（`BarrierTask.datas` 无界）、以及 `eventQueue` 容量 `Int64.Max`（`ImmediateDispatcher.cj:20`，本部分只作为 #1 的背压缺失一并说明，容器本身归第 3 部分）。另核对过 `AsyncDispatcher.end`：`EndExecutor` 同时被 `executors` 表强引用，条目数有界于线程 id 数量，**不构成泄漏**（排除一个候选） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 只给了 `docs/LocalMode*.md`，与本部分无关），热点未成立；线程创建开销与 `removeIf` 锁持有时间已列入「待验证假设」#1、#4 |
| §6.2 大粒度锁 | 0 | `mutex` 的临界区内容已核对（转调 `ImmediateDispatcher` 的 map 操作、`removeIf` 谓词），未测持有时长与竞争线程数，按规则只进「待验证假设」#4 与优化方案「缩小 `removeIf` 临界区」；`endMutex` 只保护条件等待，`get()` 期间不持 `mutex`，无锁顺序嵌套（`mutex`→`endMutex` 不存在），未发现死锁组合 |
| §6.3 并发串行 | 1 | #1 的反面问题：不是并发度=1，而是**并发度无界**（每次 `start` 一个消费者，每个事件两层 `spawn`）。没有 `spawn` 后立刻 `get()` 的形态（`get()` 在调用方线程），`Batch=1` 形态不存在 |
| §6.4 低效算法 | 0 | `doRemove` 的 `removeIf` 是 `O(全部执行器)` 遍历，但只在流程移除时触发、无频次数据，不成立为发现（已进待验证假设 #4）；`canBeRemoved` 的字符串拼接只在异常路径 |
| §7 降堆内存方案 | 1 | 「`BarrierTask.datas` 与 `eventQueue` 有界化」，证据状态：无基线（待验证） |
| §8 降 CPU 方案 | 2 | 「有界执行器替代两层 spawn」「缩小 `removeIf` 临界区」，均为无基线（待验证） |
| §9 local mode 可行性 | 0 | 本部分的临时对象（`BarrierKey`、`ArrayList<Any>`、`StartEvent`）几乎全部**逃逸**到队列/执行器/跨线程（`accept`→`eventQueue`、`emit`→下游流程），不满足 local region 的逃逸约束；且需 `--experimental --enable-local-mode`、`String`/`Array` 需 mode 重载版本，收益只能靠峰值内存对照证明——本模块无任何峰值基线，故判「不可行/无证据」，不进方案 |
| §11 现有代码的 BUG（存量） | 13 | 本部分 17 个 `.cj` 的函数边界与空值已逐个核对（含 `BarrierTask` 阈值/空事件列表、`ClosureTask.compile` 的 4 类校验、`AsyncFlow.start` 的空 `startName`、`EndExecutor.get` 的未设置态、`AsyncDispatcher` 的超时余量）；命中的 13 条存量缺陷见 #1-#13，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 6 | 共享路径逐条列出：`AsyncDispatcher.end`（`ConcurrentHashMap`+`WeakRef`，按 tid 单槽，见 #2/#5）、`AsyncDispatcher.endCondition`（#3）、`AsyncDispatcher.dispatcher`/`mutex`（转调无竞态，`accept` 只碰线程安全队列）、`AsyncFlow.dispatcher/flows/dependencied_`（#7、#10）、`BarrierTask.datas`+`ArrayList`（#6）、`EndExecutor.end`（#5）；`ClosureTask.compilerMtx` 已正确加锁（惰性初始化在锁内完成，无双重检查漏洞）。锁粒度结论见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 1 | #12（D11 只做一半）。README 覆盖归第 1 部分（`README.md`/`README_en.md` 不在本部分文件清单），本部分只核对接口注释：`AsyncEndExecutorGetter` 无注释、`EndExecutor.get()` 的「未设置即抛」无说明，已并入 #2/#5 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`files/f_egraph.part2.txt` 的 20 行全部在「文件覆盖」表中出现且已读 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性见 #1-#3、#6-#8；设计见 #2（把 per-start 状态放到共享实例）、#5（两个流程类分叉）、#7（用 `dependencied` 只做删除保护）；语言特性见 #3（`while-let` 在非 `Option` 上恒真，`typecast.md:92-133`）、#8（`ConcurrentHashMap` 索引运算符抛异常，`collection_concurrent_class.md:1835-1846`）、#1（`LinkedBlockingQueue.remove` 阻塞，`collection_concurrent_class.md:561-567`）；可读性见 #9、#10、#11；安全性 0 条——本部分不处理外部输入、无 SQL/命令/路径拼接、无凭据与敏感数据 |
| §1 死代码 | 0 | 已逐符号机械检查：`private` 的 `ImmediateDispatcher.doRegister(name:executor:)`（4 处调用）、`doRegister(executor:)`（2 处）、`end`、`executors`、`eventQueue`、`startEventNames`、`ImmediateFlow.h`/`startName`/`hasFirstTask`、`JitHostRegistry.EVENT/EMITTER/BASE_FLOW/IMMEDIATE_FLOW/ASYNC_FLOW`/`eventDescriptor`/`eventToStringMethod`/`flowMethods`/`flowMethod`/`flowArg`/`stringArg`/`taskArg`、`FlowEventFactory.init` 全部有引用；`internal` 的 `multiEventTaskBody`（`Flow.cj:68`、`ImmediateFlow.cj:112`、`AsyncFlow.cj:136`）、`JitHostRegistry.registerEventFields`/`eventFields`/`eventDescriptors`/`emitterDescriptor`/`baseFlowDescriptor`/`immediateFlowDescriptor`/`asyncFlowDescriptor`（`configure` + `JitHostRegistry_test`）、`ImmediateDispatcher.getEvent`/`getExecutors`（`AsyncDispatcher.cj:149-164`）均有引用；`protected` 的 `doStartEventName`/`doRegisterMulti` 是 `Dispatcher` 抽象成员的实现（调用方是 `Dispatcher` 的 `internal` 转发），非死代码；`public` 声明经 `egraph.cj:23` 的 `public import` 对外可达，按硬原则一不判（`EndExecutorGetter`、`Executor.accept` 默认实现属接口契约），`EmptyEvent` 仓内只在 `QueuedClosureTask` 的 `is` 判断与测试中出现，记「对外 API，仓内无构造点」不作死代码；逐个检查 `return`/`throw`/`continue` 之后无同层语句（`dispatch` 的 `continue` 与 `return` 均为分支末句），无 `if(false)`，`import` 全部用到（`ImmediateDispatcher` 无 import，`Event.cj` 的 `std.time.DateTime` 用于 `birth`，`FlowQueueIntegration_test` 的 `std.unittest.*` 用于 `@Test`） |
| §2 重复逻辑 | 3 | 已把本部分 15 个非测试 `.cj` 的函数体压成「输入→输出→副作用」两两比对：命中 #5（`ImmediateFlow` ↔ `AsyncFlow` 六组同形函数，附三处已发生的漂移）、#9（`registerEventFields` 四段）、#10（`emit` 重复声明）；判为**不**重复的：`ImmediateDispatcher.doRegister` 两版（一版查重一版追加）、`ErrorEvent` 两个构造器（载荷类型不同）、8 个事件子类构造器（各自固定 `eventType`/`name`，差异是业务要求）、`JitHostRegistry.flowMethods` 7 项（目标方法不同，已用 `flowMethod` 共因子消除）、测试里的 `TestCounter`/`RecordingAccepter`/`StepCounter`（测试准备代码，误报边界） |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}`：`ImmediateExecutor.execute` 是抽象成员（`26`），`ErrorExecutor.execute` 必抛异常，`JitHostRegistry` 描述符里的 `setter: { _, _ => () }`（`63,72,81,90`）是只读字段的 Null-Object 写法且与 `mutable: false`（`55` 等）及 `HostFieldTable` 的 `mutable` 校验呼应，属有意为空的正确用法；`FlowEventFactory.flowDataOf` 的「非 `String` 返回空串」有注释（`48`）说明 |
| §4 栈溢出 | 1 | #7：`registerTaskByFlow` 的子流程同步嵌套无环检测、无深度上限，深度上界 = 流程图深度（宿主可控），自引用/互引用即 `StackOverflow`。其余无递归：`multiEventTaskBody`（`Flow.cj:48-60`）是迭代，`dispatch` 的循环是迭代，`ImmediateFlow.canBeRemoved` 只遍历 `String` 集合 |
| §5 OOM | 2 | #6（`eventQueue` 容量 `Int64.Max`、`emit` 只入队、End 提前返回留残留）、#4（进程级 `HostFieldTable` 每次 `configure` 净增 4 个访问器，永不回收）；另核对过 `ImmediateFlow.dispatchers` / `dependencied_` / `startEventNames`：键都是 `(category, tag)`，有界于流程注册数，且 `remove()` 会清 `dispatchers`（`44-47`），**不构成无界泄漏**，只列待验证假设 #4 观察是否随滚动发布换 tag 增长 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的「已有性能资料」只给了 `docs/LocalMode*.md`，与本部分无关），任何「热点」结论都不成立；事件路由、UUID session、`HostFieldTable.find` 的自耗时已列入「待验证假设」#1-#3，不进发现 |
| §6.2 大粒度锁 | 0 | 本部分**没有锁**：`ImmediateDispatcher` 无 `Mutex`（问题在「完全没有同步」而非「锁太大」，已作 #2 报严重）；`ImmediateFlow` 只用 `ConcurrentHashMap`/`ConcurrentHashSet`，无临界区、无锁内 I/O。`removeIf` 谓词里构造对象（`ImmediateFlow.cj:52`）不持锁，不构成大粒度锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get()`、无批大小配置，不存在「形式并发实际串行」形态。相关的反向问题（无界并发 / 无会话隔离）已在 #2 按正确性报 |
| §6.4 低效算法 | 1 | #4 的 `HostFieldTable.find` 桶内线性扫描（随 `configure` 次数增长）+ #4 的 `register` 整表复制（每次 `configure` 复制全部桶，O(表大小)）；`ImmediateFlow.canBeRemoved` 的字符串拼接只在异常路径（排除）；`dispatch` 的 `HashMap<Event>` 查找是 O(1)，不报 |
| §7 降堆内存方案 | 1 | 「事件 `session` 默认 UUID」（证据状态：无基线，待验证） |
| §8 降 CPU 方案 | 1 | 「`EventType.hashCode` 预计算」（证据状态：无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分的临时对象全部逃逸：`Event`（含 `DataEvent.data`）被放进 `eventQueue`、交给执行器、作为 `dispatch` 返回值传出；`MultiEvent` 的 `Iterable<Event>` 被下游流程持有；`HostFieldAccessor` 的闭包进进程级静态表。没有「函数内创建、函数内销毁且不逃逸」的大对象，故判不可行；另需 `--experimental --enable-local-mode`、`String`/`Array` 需 mode 重载版本，且收益只能靠峰值内存对照证明（本模块无任何峰值基线） |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 15 个非测试文件、5 个测试文件的边界与空值已逐个核对（`Event` 的 4 字段相等性、`priority`/`cancelPrev` 负数、`doRegister` 重复注册、`dispatch` 的空队列守卫、`ImmediateFlow.startName` 空串、`remove` 后 start/emit、`JitHostRegistry` 的描述符索引、`FlowEventFactory.flowDataOf` 的 3 个分支）；命中的 11 条即 #1-#11，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 1 | 逐条列出共享点与同步手段：`ImmediateFlow.dispatchers`（`ConcurrentHashMap`，安全）→ 其 value `ImmediateDispatcher`（**内部全部无同步**：`executors` 普通 `HashMap`+`ArrayList`、`end` 普通 `var`、`startEventNames` 普通嵌套 `HashMap`）→ 这是 #2 的共享路径；`ImmediateFlow.dependencied_`/`AsyncFlow` 侧属第 2 部分；`ImmediateExecutor.acceptingEvent` 不可变（安全）；`DummyEvent.instance` 静态单例只读（安全）。锁粒度结论：不是「锁太大」，而是「该有的同步完全没有」，修法见 #2 |
| §14 功能完备性与 README 覆盖 | 2 | #3（`Event` 承诺的优先级/撤销语义只在 `QueuedClosureTask` 实现，`ImmediateDispatcher` 忽略）、#7（子流程环检测缺失，属「能力接了一半」）；README 覆盖归第 1 部分（本部分无 `.md`），本部分只核对接口注释，另记一句范围外提示：`README.md:441-472` 手抄的 `Dispatcher` 声明用 `name:`，实现是 `eventName:`，该漂移已由第 1 部分首条覆盖，此处不重复计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`files/f_egraph.part3.txt` 的 20 行全部在「文件覆盖」表中出现且已读。本部分无 `.md`，§13 文档一致性不适用（模块文档由第 1/2 部分覆盖） |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1（并发下顺序与独占不成立）、#2（异常路径状态残留）、#3（session 不一致）、#5（无界无背压）、#6（自提交递归）、#7（`generation` 语义陷阱）；设计 #4（能力只在单点实现）；可读性 #8（四处同形实现）；语言特性：`synchronized` 内早退（`176-178`、`198-200`）与 `Mutex` 可重入语义已按 `sync_package_classes.md:8919-8930` 核对，未据此报缺陷；安全性 0 条——本部分不接外部输入、无 SQL/命令/路径拼接、无凭据与敏感数据 |
| §1 死代码 | 1 | 已逐符号机械检查：本部分 `private` 符号 `submitImmediate`(`98`)、`takeBatchLocked`(`175`)、`compareEntries`(`54`)、`dropTailByNameAndPriority`(`82`)、`dropTailSamePriority`(`85`)、`sortBySequenceAsc`(`233`)、`sortBySequenceDesc`(`272,289`)、测试里的 `ev`/`newTask`/`names`/`configuredCompiler`/`category`/`compileError` 全部有调用者；`internal` 顶层类 `QueueEntry`(`324`)、`CancelToken`(`335`) 只在本文件用（同包内），有引用；`protected` 无新增声明；`public` 成员（`owner`/`pending`/`cancelledCount`/`generation`/`runNext`/`drain`/`submit`/`exec`、`TaskExecutor.newBy*`、`StartExecutor.execute`、`GraphException` 四个构造器）均属对外可达（`egraph.cj:23-24` 的 `public import`），按硬原则一不判——其中 `owner`/`cancelledCount`/`generation`/`runNext`/`drain` 仓内仅测试引用，记为「对外 API，仓内无生产引用」的可见性信息，不作死代码；`return`/`throw`/`continue` 之后无同层语句（`runNext` 的 `return false`/`return true` 均为分支末句）；`import` 命中 #10 两项 |
| §2 重复逻辑 | 1 | 已把 6 个非测试文件的函数体压成「输入→输出→副作用」两两比对：命中 #8（四组同形实现，且令牌临界区已漂移）；判为**不**重复的：`submit` 与 `submitImmediate`（前者做取消+入队，后者做顶替+立即执行，副作用不同）、`compareEntries` 与 `sortBySequence*`（一个是 `Ordering` 三级比较器，一个是原地插入排序）、`RecordingDispatcher` 的空实现（测试替身）、`GraphException` 四构造器（转发目标不同）、`TaskExecutor` 三个工厂（泛型参数与 flow 类型不同） |
| §3 空实现 | 0 | 本部分无 `TODO`/`FIXME`、无 `catch {}`、无 `throw UnsupportedException`：`FlowLoader.load` 是抽象成员（契约由宿主实现，`FlowInitializer_test.cj:40` 有实现）；`RecordingDispatcher` 的 `dispatch`/`doRegisterMulti`/`removeIf`/`register*` 空体有注释「只实现管道所需的接口」（`267`），属测试替身；`FlowInitializer.initialize` 有完整实现（`egraph.cj:37-44`）；`JitManualBinding_test.BindingTestTask.exec` 转发 `body_`，非空实现 |
| §4 栈溢出 | 1 | #6：0 号事件在提交线程同步 `evaluate`，任务体自提交即 `exec→submit→submitImmediate→evaluate→…` 无界递归，深度 = 提交链长度（由任务体决定），无 `depth` 上限、无环检测。其余无递归：`takeBatchLocked`/`dropTail*`/`sortBySequence*` 全为迭代，`drain`/`exec` 是 while 循环 |
| §5 OOM | 1 | #5：`queue` 容量 0 = 无限（`PriorityQueue.cj:159-164`）、`overSizePolicy` 永不生效、无背压/无拒绝；已按「backlog × 单条 ≈ 140–240B + 载荷」给出线性估算与缺失的拒绝路径。其余容器：`sequence`/`epoch`/`tokenCounter` 是标量；`QueuedClosureTask_test.Holder` 是测试对象，无长期持有 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的「已有性能资料」只给 `docs/LocalMode*.md`，与本部分无关），`PriorityQueueBench_test` 落盘的毫秒数没有对照意义（#11），故不成立任何热点结论；`takeBatchLocked` 的 O(n²)、锁内 `toArray`、队列堆积三项已进「待验证假设」#1-#3 |
| §6.2 大粒度锁 | 1 | #9：`submitImmediate` 持 `mutex` 调外部虚函数 `dispatcher.accept`；当前两个实现都是 O(1) 入队，故只定轻微。`takeBatchLocked` 持锁做 O(n) 工作属"临界区偏大"，与 #9 同源（同一把 `mutex`），未单列，性能面见「待验证假设」#3 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get()`、无批大小配置；相反的问题是"并发没有被串行化"（#1），按正确性报 |
| §6.4 低效算法 | 1 | `takeBatchLocked` 批量路径 O(n)+O(k·n)+O(k²)（`227`/`234-238`/`233`），与 `>=2` 路径 O(log n) 差一个量级；未定为缺陷（无耗时数据），落在「优化可行性方案 [CPU]」+「待验证假设」#1 |
| §7 降堆内存方案 | 1 | 「`takeBatchLocked` 每批 `toArray` 全量复制」（证据状态：无基线，待验证） |
| §8 降 CPU 方案 | 1 | 「批量取批复杂度与批内排序」（证据状态：无基线，待验证） |
| §9 local mode 可行性 | 0 | 不可行：`batch`/`matched`/`entries` 三个临时容器都不在函数内销毁——`batch` 被塞进 `MultiEvent.events`（`185-186`）并随返回值交给 dispatcher，`payload`/`result` 直接逃逸到 `dispatcher.accept`（`130`/`202`），不符合「不逃逸」前提；且需 `--experimental --enable-local-mode`、`ArrayList`/`Array` 需 mode 重载版本，收益只能用峰值内存对照证明（本模块无任何峰值基线） |
| §11 现有代码的 BUG（存量） | 8 | 本轮逐个核对了 13 个文件的边界与空值：`submit` 的 `EmptyEvent`/`cancelPrev` 四分支（`79-89`）、`dropTail*` 的 `n > size` 截断（`273`/`290`）、`sortBySequence*` 的 `position >= 0` 循环（`301`/`314`）、`takeBatchLocked` 的空队列（`245-246`）、`runNext` 的空批早退（`176-178`）、`compareEntries` 的三级比较、`StartExecutor` 的非 `DataEvent` 分支、`GraphException` 四构造器、`FlowInitializer` 的 `lookup` 缺失路径；命中的 8 条为 #1、#2、#3、#5、#6、#7、#9、#11，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 2 | 共享点与同步手段已逐条列出：`mutex`（`40`）保护 `sequence`/`epoch`/`cancelled`/`currentName`/`currentToken`/`tokenCounter`，`queue` 由 `SyncPriorityQueue` 自身 `Mutex` 保护，锁序恒为「task.mutex → queue.mutex」（`pending` 只取 queue.mutex，无反向路径，不构成死锁）；`cancelled` 的读写都在 `mutex` 内（`118` 写、`129`/`198` 读），可见性成立。**不成立的是"执行段互斥"**：`evaluate`（`188`，及 `127`）在锁外且 `exec` 可被多线程进入（#1），`currentToken` 单槽无法表达多个在途执行（#1），`dispatcher.accept` 在锁内（#9）。锁粒度结论：不是"锁太大"，而是"该串行的段没有串行"；改法见 #1 建议 |
| §14 功能完备性与 README 覆盖 | 1 | #4：`QueuedClosureTask` 注释承诺的 0/1 号语义没有 Flow 入口，`emit` 恒为 2 号（`Emitter.cj:19`、`Flow.cj:41`、`ImmediateFlow.cj:126`、`AsyncFlow.cj:153`、`FlowEventFactory.cj:31-46`），属"能力只接了单点"。README 覆盖归第 1 部分（本部分无 `.md`），本部分只核对了源码注释与实现的一致性；另记一句范围外提示：`README.md:913` 只列出 `QueuedClosureTask` 的 API 名，没有任何一段说明 0/1/`cancelPrev` 的使用条件（该缺口由第 1 部分的 README 覆盖条统一处理，此处不重复计数） |
| 文件覆盖（§13 等） | 13/13 | 无缺失文件；`files/f_egraph.part4.txt` 的 13 行全部在「文件覆盖」表中出现且已读。本部分无 `.md`，§13 文档一致性不适用（模块文档由第 1/2 部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 10 |
| 一般 | 23 |
| 轻微 | 15 |
| 其中存量 | 48 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分是 f_egraph 的对外文档与变更记录，内容密度很高：JIT 注册面、脚本契约、旧 DSL 迁移表、手工注册"金线"（`design.md` §5.2 与 `JitHostRegistry.cj` 逐项吻合）都写得具体且可验证，`design.md` 的 D9/D11/D12 三个既有缺陷的成因分析（构造期 Multi 注册撞业务校验、`Multi` 事件永远分发不到、`AsyncFlow` 判重集合从不写入）与本轮读到的源码完全对得上。设计文档质量明显高于常见水平。

风险集中在两份面向使用者的 README：

1. **手抄副本已经漂移**（发现 1/2a/2b/2c）：`Event`/`DataEvent` 构造器缺三个新参数、`TaskExecutor.task` 类型写错、`BaseFlow.remove*` 写成静态、`StartExecutor` 的行为被描述成另一回事、`AsyncFlow` 的进程级静态 dispatcher 被写成实例字段。这些都是"照文档写会编译失败或行为不符"，对下游是直接的误导，其中 `StartEvent → TaskEvent` 的改写与 `AsyncFlow` 全局单例两点最容易被误解放大。
2. **新增能力只有名字没有语义**（发现 3/4/5）：`MultiEvent.name` 必须等于 `"Multi"` 这条硬约束只写在 spec 里；`priority` / `cancelPrev` / `EmptyEvent` / `QueuedClosureTask` 的全部行为只存在于源码头注释；并发与生命周期完全空白。使用者按 README 无法安全使用优先级队列，也无法判断启动期与运行期的并发边界。

阻塞项：无（本轮均为文档问题，不影响编译与运行）。但建议把「README 重写」排在 f_egraph 后续工作的前面——尤其发现 2b（并发/生命周期）与发现 5，它们决定宿主能否正确初始化异步流程，属于"文档缺一句话、线上多一类事故"的类型。`design.md` / `spec.md` 的两处内部矛盾（发现 6/7）与校验口径（发现 8）随手修正即可。

**第 2 部分**：本部分的风险不在「图算法复杂度」（流程路由就是 map 查表，`Event` 的 `hash` 预计算、`BarrierKey` 四字段哈希都没问题），而在**异步调度层的并发契约**：`AsyncDispatcher` 用「线程 id 当一次启动的标识」「每次 `start` 派生一个常驻消费者」「先登记结束执行器、后填值」「失败路径不通知等待方」四件事叠在一起，使得任何「同线程两个在途流程」「多线程并发启动」「任务抛异常」都会退化成永久阻塞或取到别人的结束事件。这 7 条严重问题里有 6 条集中在 `AsyncDispatcher.cj` 一个文件（约 160 行），根因是同一个设计决定（把 per-start 的结果槽放在全局 map 的线程 id 上，且结果槽的发布没有同步），修法也集中在同一个方向：per-start 句柄 + 有界执行器 + 条件等待循环 + 异常回填。

阻塞项：#1（线程无界增长）、#2（结果错投/永久阻塞）、#3（`NoneValueException`）、#4（异常吞掉后 `get()` 永挂）、#5（发布早于赋值的数据竞争）—— 这 5 条都会在真实服务端流量下出现，且表现为「调用方永久挂起」这类最难排查的故障，建议一并修复后再对上层流程能力做信任性评估。#6（`BarrierTask` 并发累积）取决于是否存在同一 session 的并发事件，属条件触发但后果是数据错乱，同样应优先。一般级 6 条（`BarrierTask` 无界累积、`Condition.wait` 负超时、`AsyncFlow` 全局状态、`removeIf` 谓词副作用、D11 半实现、测试隔离）可以排期；两条轻微问题（重复的等待模板、错误的「Mutex 不可重入」注释）修起来很便宜，但 #15 的错误论断会误导后续对死锁的判断，建议顺手改掉。

代码质量的正面之处：`ClosureTask` 的校验与惰性编译器（`compilerMtx` 全程持锁，无双重检查漏洞）写得很干净；`FlowScriptRunner` 的契约（空脚本抛异常、末句必须 `Unit`）与注释、测试三方一致；`Dispatcher` 用 `internal` 转发 + `protected` 抽象承接「抽象成员不能是 `internal`」的语言限制，处理得体并有注释说明。测试覆盖度本身不差（`ClosureTask_test` 10 条、`AsyncDispatcher_test` 7 条、`FlowInitializer_test` 10 条覆盖了主路径与失败路径），缺的是**并发路径**的用例：#2/#3/#6/#7 目前一条测试都没有，`BarrierTask_test.barrierTaskEmitsWhenThresholdReached` 只跑了单线程，这也是这些问题能长期存活的直接原因。

存量缺陷共 15 条（严重 7 / 一般 6 / 轻微 2），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。

**第 3 部分**：本部分是「事件原语 + 同步派发器 + JIT 手工注册面」，代码量不大（15 个非测试文件约 900 行），图算法本身没有复杂度问题（路由就是一次 `HashMap<Event>` 查表，`Event` 的哈希在构造期预计算），真正的风险集中在**同步派发器的生命周期契约**：

- `ImmediateDispatcher` 把「一次 `start` 的上下文」实现成了实例上的三个字段（`eventQueue` / `end` / `executors`），而实例又被 `ImmediateFlow` 的静态表按 `(category, tag)` 全局共享。于是同一个流程的并发启动必然互相串流，`start()` 返回的 getter 也不是 per-start 句柄。这是 #2，也是本部分最该先修的一条。
- `dispatch()` 的终止条件只有 `EndExecutor`，而队列耗尽时 `remove()` 是阻塞调用，于是「合法地不注册 End」直接变成调用线程挂死（#1）。#1 与 #2 是同一条循环的两个方向：出口太窄、状态太共享。
- 事件层的 `priority` / `cancelPrev` / `EmptyEvent` 承诺（`Event.cj` 自己的公开注释）只有 `QueuedClosureTask` 兑现，普通 `Task` 路径下静默失效甚至抛异常（#3）；这是「注释比实现跑得快」的典型，和本模块第 1/2 部分报出的文档漂移是同一个根。

阻塞项：#1（`start` 挂死）与 #2（会话串流 / 数据竞争）——两者都会在真实服务端流量下表现为「请求永不返回」或「拿到别人的结果」，建议一并修复后再评估同步流程的可用性。#3、#6 属契约与容量问题，应和 #1/#2 同批处理（`eventQueue` 的背压与残留清理依赖会话隔离的设计）。#4、#5、#7 可以排期：#5 的重复实现是维护成本（且已经漂移出三处差异），#7 是宿主写错流程图的兜底，#4 的收益取决于 `f_llm` 侧 `configure` 的调用频次（范围外）。4 条轻微问题修起来很便宜，其中 #11 的无效断言会掩盖 `QueuedClosureTask` 抢占语义的覆盖缺口。

正面之处：`Event`/`EventType` 的值语义与相等性实现得很干净（哈希预计算、`==` 与 `hashCode` 字段集一致、`DataEvent.tryGet` 用 `as` 返回 `Option` 而不是抛异常）；`ErrorExecutor` 的三分支 + `Executor_test` 的空值用例覆盖到位；`JitHostRegistry` 用「描述符工厂 + 统一 `match` 解包 + 绑定名全局唯一」把手工注册面组织得很好，并有 `JitHostRegistry_test` 的金线断言（父链、字段索引、方法集合、`registeredNames`）兜住回归。测试的主要缺口是**并发与终止条件**：`ImmediateDispatcher_test` 7 个用例里没有一条并发启动、也没有一条「队列耗尽」的用例，`FlowQueueIntegration_test` 的优先级用例断言恒真——这正是 #1/#2 能长期存活的原因。

存量缺陷共 11 条（严重 2 / 一般 5 / 轻微 4），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。

**第 4 部分**：本部分是「队列化任务 + 手工 JIT 绑定测试 + 模块初始化 + 异常/加载器契约」的组合，代码量最小（13 个文件约 1360 行，其中 5 个是测试），但**唯一的核心类 `QueuedClosureTask` 承担了本模块最重的并发契约**，严重与一般问题几乎都集中在这里：

- 这个类的设计是「一把锁保护队列与取消令牌，任务体在锁外执行」——单线程驱动下自洽（测试全是单线程 `drain`），可它被 `AsyncFlow` 以「每事件一条 `spawn` 线程」的方式调用（`AsyncDispatcher.cj:116-128` + `AsyncFlow.cj:127-131`），于是①执行段没有任何互斥、②`currentToken` 单槽装不下多个在途执行、③投递顺序与 `birth` 脱钩。这是 #1，本部分唯一的严重项，也是唯一必须优先修的：它把"顺序执行"的契约在最常见的异步用法下变成不成立。
- 与之配套的三条"状态机卫生"问题同样值得同批处理：#2 异常路径不清令牌槽（导致取消计数不可信、批事件无声丢失）、#7 `generation` 被当成"被顶替"信号（按注释写就会误判并交出不完整结果）、#3 批量的 `session` 凭空重置（会话关联错位）。
- #4 与 #5 是能力面问题：优先级/抢占/撤销只写在注释里，Flow 入口表达不了（#4），队列又没有容量上限与拒绝路径（#5）。两者叠加的现状是——"高级能力"只在测试里跑，"容量风险"在生产里没有护栏。
- 轻微项都是低成本可清的：#8 的四处同形实现（且令牌临界区已经漂移，正是 #9 的来源）、#9 锁内调外部回调、#10 两个无用 `internal import`、#11 把伪基准放进单测。

阻塞项：#1（并发下契约不成立 + 任务体数据竞争）。建议同批修 #2（异常清理）与 #7（取消信号）——它们都在同一段临界区里，改一次比改三次便宜。#3、#4、#5 可排期，但 #4 需要产品/API 决策（要不要把 `priority` 放进 `emit`）。#8-#11 是清理项，其中 #8 应先做，因为 #9 的正确修法就是"把两份临界区合成一份"。

正面之处：`takeBatchLocked` 的批语义（同优先级同名、跨非相邻位置合并）与 `compareEntries` 的三级稳定比较（`priority → birth → sequence`）实现清晰，`sequence` 的唯一性保证了堆序确定；`submit` 对 `EmptyEvent`/`cancelPrev` 的四个分支与 `dropTail*` 的 `n > size` 截断都做了边界处理；`GraphException` 与 `FlowLoader` 的契约薄而明确，`FlowInitializer` 的初始化链（compiler → host registry → `initCompiler` → loader → runner）责任划分干净，且"由宿主注册 `FlowInitializer`"的约定在 README 与仓内范例（`BeanInitializer`）里对得上。测试的主要缺口**不是覆盖数量**（`QueuedClosureTask_test` 有 14 条），而是**并发与错误路径**：没有任何多线程用例，也没有"任务体抛异常后状态如何"的用例——这正是 #1/#2 能长期存活的原因；`PriorityQueueBench_test` 则把"看起来在测性能"变成了误导。

存量缺陷共 11 条（严重 1 / 一般 6 / 轻微 4），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。

## 范围外提示（不计入统计）

- `AsyncDispatcher` 构造器内的 `while(true)` 清理线程永不退出、`end` 表以 `Thread.currentThread().id` 为键并用 `WeakRef`（`f_egraph/src/base/AsyncDispatcher.cj:32-39`、`:136-141`）：线程与表的有界性、`initDispatcher` 重复调用的泄漏，归第 3 部分判定。
- `BarrierTask.datas` 按 `(category, tag, eventName, session)` 无上限累积，只有凑满计数才 `remove`（`f_egraph/src/base/BarrierTask.cj:42`、`:82-96`）：OOM 面归第 4 部分。
- `QueuedClosureTask.takeBatchLocked` 的整队列 `toArray()` 快照（`f_egraph/src/base/QueuedClosureTask.cj:218-248`）与 `docs/LocalMode.md` 的"逃逸，不改"结论，归第 4 部分，本报告只在待验证假设 #2 记录取证方式。
- `EmptyEvent` 未进 JIT 注册表（`f_egraph/src/base/JitHostRegistry.cj:114-125` 只注册 8 个事件类）：脚本面因此无法构造取消事件。这是缺陷还是有意边界 `待确认`（需要一次设计决策），本报告只作信息，不并入发现 4 的计数。
- `ImmediateFlow.registerTask` 的 `startName` / `hasFirstTask` 读改写无同步（`f_egraph/src/base/ImmediateFlow.cj:93-102`）：并发注册的实际竞态归第 3 部分。
