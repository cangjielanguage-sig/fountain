# f_egraph 模块审查报告（第 1/4 部分：文档与设计规格）

- **审查日期**：2026-11-28
- **模块路径**：`f_egraph`（全模块 50 个 `.cj` + 8 个 `.md`；**本报告为模块第 1/4 部分**，覆盖 5 个 `.md`；第 2 部分（3 个 `.md` + 17 个 `.cj`）、第 3 部分（20 个 `.cj`）、第 4 部分（13 个 `.cj`）不在本报告统计）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：`README` / `README_en` / `doc/spec/**` 与实现的一致性、公开 API 覆盖、脚本与 JIT 契约；本部分无 `.cj`，图算法、递归、OOM、并发、死代码等专项以「文档承诺是否与源码相符」为审查对象，源码侧缺陷归第 2–4 部分
- **报告版本**：v1（第 1/4 部分，供主 Agent 合并为 `docs/review/2026-11-28/f_egraph.md`）

## 发现

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

## 优化可行性方案

本部分为空。5 个文件全是 `.md`，没有循环、容器、锁、序列化或字符串拼接，不存在可度量的 CPU / 堆内存优化对象；与性能相关的两条线索（`proposal.md` 的手工适配器收益宣称、`docs/LocalMode.md` 对 `takeBatchLocked` 的结论）都没有改前基线，只能进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 宿主成员从反射 MCC 路径切到手工适配器后调用更快（`proposal.md` 称"性能：宿主成员从反射 MCC 路径切到手工适配器（直接方法调用）"） | `f_egraph/doc/spec/f-egraph-jit-flow-init/proposal.md:160-161` | 无任何绝对值、调用次数、自耗时占比；无法判断 JIT→宿主调用的占比是否高于噪声 | `cjpm bench -O2` 同机对照：同一 `ClosureTask` 任务体分别在宏绑定 / 手工适配器两条注册路径下跑 10 万次事件，取中位数与 P95；或 `cjprof record` 看 JIT 调用栈里宿主适配器帧的 self time |
| 2 | `QueuedClosureTask.takeBatchLocked` 的"整队列 `toArray()` 快照"是 f_egraph 的分配峰值热点 | `f_egraph/src/base/QueuedClosureTask.cj:218-248`（属第 4 部分）；口径来自 `docs/LocalMode.md:421-423`、`docs/LocalMode-O2-Plan.md:112` | 上游资料是静态分析结论（"逃逸，不改"），没有分配量 / RSS / 队列深度对照 | 队列深度 1k 与 10k 两档，`getAllocatedHeapSize()` + RSS + `cjprof heap` 对照；同时统计 batch.size>1（走 `MultiEvent`，`:182-187`）的比例，确认快照副本是否真的成为峰值主因 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_egraph/README.md` | .md | ✅ | 914 行；发现 1/2a/2b/2c/3/4/5/9；JIT 注册面（`JitHostRegistry.configure` 顺序、`@IgnoreJitBinding`、`BarrierTask` 不可绑定）与 `src/base/JitHostRegistry.cj:37-49`、`src/base/Task.cj:21`、`src/base/ClosureTask.cj:56-61` 逐条核对一致 |
| 2 | `f_egraph/README_en.md` | .md | ✅ | 933 行；与中文版逐节对应（无整节缺失，BOM + 首次"Other public API"条目顺序不同），缺陷同构，行号已在各条给出 |
| 3 | `f_egraph/doc/spec/f-egraph-jit-flow-init/design.md` | .md | ✅ | 1188 行；发现 6/7；§5.2 "手工注册金线"与 `src/base/JitHostRegistry.cj:93-228`（4 个字段索引、2 个接口的 7 个方法、2 个构造器 `[String,String]`、8 个事件类的父链）逐项一致；D9/D11/D12 的缺陷描述与 `src` 现状吻合，仅 D11 回填的可见性口径不符（发现 7） |
| 4 | `f_egraph/doc/spec/f-egraph-jit-flow-init/proposal.md` | .md | ✅ | 171 行；变更提案，与 `design.md`/`README` 的迁移表一致；性能宣称进待验证假设 #1；文中 `FlowDSLCompiler.cj` 属"变更前现状"，`src/base/` 已无该文件（`ls` 确认），按变更记录对待，不计文档过期 |
| 5 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-flow-script/spec.md` | .md | ✅ | 237 行；11 条 Requirement 的场景逐条对照实现，除发现 3（name 约束未进 README）与发现 6（Unit 时机与 design 冲突）外均与 `src` 一致；`registerMultiTask`、`AsyncDispatcher` 取队列不持锁两条与 `src/base/Dispatcher.cj:36-45`、`src/base/AsyncDispatcher.cj:143-146` 一致 |

合计：`.cj` 0 个 / `.md` 5 个 / 共 5 个，全部读完（与 `files/f_egraph.part1.txt` 的 5 行一一对应）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 11 条（6 一般 + 5 轻微），是否纳入修复待用户决定。

## 总评

本部分是 f_egraph 的对外文档与变更记录，内容密度很高：JIT 注册面、脚本契约、旧 DSL 迁移表、手工注册"金线"（`design.md` §5.2 与 `JitHostRegistry.cj` 逐项吻合）都写得具体且可验证，`design.md` 的 D9/D11/D12 三个既有缺陷的成因分析（构造期 Multi 注册撞业务校验、`Multi` 事件永远分发不到、`AsyncFlow` 判重集合从不写入）与本轮读到的源码完全对得上。设计文档质量明显高于常见水平。

风险集中在两份面向使用者的 README：

1. **手抄副本已经漂移**（发现 1/2a/2b/2c）：`Event`/`DataEvent` 构造器缺三个新参数、`TaskExecutor.task` 类型写错、`BaseFlow.remove*` 写成静态、`StartExecutor` 的行为被描述成另一回事、`AsyncFlow` 的进程级静态 dispatcher 被写成实例字段。这些都是"照文档写会编译失败或行为不符"，对下游是直接的误导，其中 `StartEvent → TaskEvent` 的改写与 `AsyncFlow` 全局单例两点最容易被误解放大。
2. **新增能力只有名字没有语义**（发现 3/4/5）：`MultiEvent.name` 必须等于 `"Multi"` 这条硬约束只写在 spec 里；`priority` / `cancelPrev` / `EmptyEvent` / `QueuedClosureTask` 的全部行为只存在于源码头注释；并发与生命周期完全空白。使用者按 README 无法安全使用优先级队列，也无法判断启动期与运行期的并发边界。

阻塞项：无（本轮均为文档问题，不影响编译与运行）。但建议把「README 重写」排在 f_egraph 后续工作的前面——尤其发现 2b（并发/生命周期）与发现 5，它们决定宿主能否正确初始化异步流程，属于"文档缺一句话、线上多一类事故"的类型。`design.md` / `spec.md` 的两处内部矛盾（发现 6/7）与校验口径（发现 8）随手修正即可。

## 范围外提示（不计入统计）

- `AsyncDispatcher` 构造器内的 `while(true)` 清理线程永不退出、`end` 表以 `Thread.currentThread().id` 为键并用 `WeakRef`（`f_egraph/src/base/AsyncDispatcher.cj:32-39`、`:136-141`）：线程与表的有界性、`initDispatcher` 重复调用的泄漏，归第 3 部分判定。
- `BarrierTask.datas` 按 `(category, tag, eventName, session)` 无上限累积，只有凑满计数才 `remove`（`f_egraph/src/base/BarrierTask.cj:42`、`:82-96`）：OOM 面归第 4 部分。
- `QueuedClosureTask.takeBatchLocked` 的整队列 `toArray()` 快照（`f_egraph/src/base/QueuedClosureTask.cj:218-248`）与 `docs/LocalMode.md` 的"逃逸，不改"结论，归第 4 部分，本报告只在待验证假设 #2 记录取证方式。
- `EmptyEvent` 未进 JIT 注册表（`f_egraph/src/base/JitHostRegistry.cj:114-125` 只注册 8 个事件类）：脚本面因此无法构造取消事件。这是缺陷还是有意边界 `待确认`（需要一次设计决策），本报告只作信息，不并入发现 4 的计数。
- `ImmediateFlow.registerTask` 的 `startName` / `hasFirstTask` 读改写无同步（`f_egraph/src/base/ImmediateFlow.cj:93-102`）：并发注册的实际竞态归第 3 部分。
