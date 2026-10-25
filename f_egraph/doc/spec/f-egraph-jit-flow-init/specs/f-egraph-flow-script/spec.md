# Spec Delta — f-egraph-flow-script

## ADDED Requirements

### Requirement: FlowLoader 契约

`FlowLoader.load()` SHALL 返回 `ArrayList<String>`；每个元素 SHALL 是一段 f_jit 源码语句序列，
表示**一个流程**的完整注册脚本。`FlowInitializer` SHALL 按返回顺序逐个执行，每个脚本执行一次。

#### Scenario: 每个元素注册一个流程

- **WHEN** `FlowLoader` 返回 `[scriptA, scriptB]`，两者分别注册 `order/v1` 与 `pay/v1`
- **THEN** `initialize()` 返回后两个流程的 dispatcher 均可按 `category`/`tag` 启动

#### Scenario: 空列表是合法输入

- **WHEN** `FlowLoader.load()` 返回空列表
- **THEN** `initialize()` 正常返回，不注册任何流程

### Requirement: 脚本包装与空脚本处理

执行前 SHALL 把脚本包裹为 `{ => <script> }`，**不追加哨兵表达式**（f_jit 不支持空括号 `()`）。
脚本末条语句 SHALL 是 `Unit` 值表达式（约定为 `flow.removeExceptCurrentTag()`）；末条不是
`Unit` 时 `compile` 仍可成功，但 `call<Unit>([])` SHALL 在**调用期**抛 `JitException`
（返回类型不符），初始化仍然失败。去空白后为空的脚本 SHALL 抛 `GraphException`，
且不继续执行后续脚本。

#### Scenario: 脚本末尾无返回值

- **WHEN** 脚本最后一条语句是 `flow.removeExceptCurrentTag()`（返回 `Unit`）
- **THEN** 包装后的单元可被 `call<Unit>([])` 正常执行

#### Scenario: 末句不是 Unit 被拒绝

- **WHEN** 脚本最后一条语句返回非 `Unit`（例如 `compile("t", ["a"], ["b"], "e")`）
- **THEN** `call<Unit>([])` 在调用期抛 `JitException`（返回类型不符），初始化失败

#### Scenario: 空脚本快速失败

- **WHEN** `FlowLoader` 返回 `"   \n  "`
- **THEN** 抛 `GraphException`，其消息说明流程脚本不得为空

### Requirement: 编排语句与注册顺序

脚本 SHALL 通过以下语句完成编排：

- `let flow = ImmediateFlow("<category>", "<tag>")` 或 `AsyncFlow(...)`；
- `flow.registerStart("<event>")`；
- `flow.registerEnd()`、`flow.registerError()`；
- `let t = compile("<name>", [<accept>...], [<produce>...], "<exec>")`；
- `flow.registerTask(t)`；
- 末行 `flow.removeExceptCurrentTag()`。

注册顺序 SHALL 与语句顺序一致。`registerStart` 必须早于第一个 `registerTask`；第一个任务必须
接受开始事件，否则 `registerTask` 抛 `GraphException`。

#### Scenario: 开始事件先于任务

- **WHEN** 脚本先 `registerTask` 后 `registerStart`
- **THEN** `registerTask` 抛 `GraphException`（现有 `ImmediateFlow`/`AsyncFlow` 校验）

#### Scenario: 首任务必需接受开始事件

- **WHEN** 开始事件为 `created`，首任务 `acceptableEvents` 为 `["other"]`
- **THEN** `registerTask` 抛 `GraphException`

#### Scenario: 重复执行器被拒绝

- **WHEN** 两个 `ClosureTask` 都以同一事件注册
- **THEN** 第二次 `registerTask` 抛 `GraphException`

### Requirement: 流程构造可用

`ImmediateFlow(category:tag:)` 与 `AsyncFlow(category:tag:)` SHALL 在构造期完成 Multi 事件任务的
内部注册，且该注册 SHALL NOT 经过业务任务的顺序校验（`startName` 非空、首任务等于开始事件）：

1. 构造 SHALL NOT 抛 `GraphException`；`AsyncFlow` 仅在宿主已调用 `initDispatcher` 后可构造
   （未初始化时仍上抛，语义不变）；
2. Multi 任务 SHALL 以 acceptable 事件 `eventType = EventType.Multi`、事件名
   `EventType.Multi.toString()` 登记到该 `(category, tag)` 的 dispatcher，且 SHALL 经内部
   专用入口 `Dispatcher.registerMultiTask` 登记、SHALL NOT 经业务入口 `registerTask`
   （后者把事件类型硬编码为 `EventType.Task`，而 `Event.==`/`hashCode` 计入 `eventType`，
   永远匹配不到 `MultiEvent`）；收到 `data` 为 `Iterable<Event>` 的 `MultiEvent` 时，SHALL
   把每个子事件扇出为一次 `emit` 并返回 `DummyEvent`。`MultiEvent` 的 `name` SHALL 为
   `EventType.Multi.toString()`，否则不会被本流程接收；
3. 业务首任务约束 SHALL 保持不变：构造期 SHALL NOT 置位 `hasFirstTask`，首个业务任务的
   事件名仍必须等于 `registerStart` 的事件名；
4. 同一 `(category, tag)` 重复构造 SHALL NOT 重复登记 Multi 任务：`ImmediateFlow` 以
   dispatcher 表判重，`AsyncFlow` 以构造期 flow 集合判重（构造成功后加入、移除时同步删除）。

#### Scenario: 新流程可构造

- **WHEN** 用全新的 `category`/`tag` 构造 `ImmediateFlow("c", "t")`
- **THEN** 构造成功，不抛 `GraphException`

#### Scenario: 异步流程在 dispatcher 初始化后可构造

- **WHEN** 宿主先调用 `AsyncFlow.initDispatcher()`，再构造 `AsyncFlow("c", "t")`
- **THEN** 构造成功，不抛 `GraphException`

#### Scenario: Multi 事件扇出

- **WHEN** 流程对子事件 `a`/`b` 注册了执行器，宿主投入一个 `data` 为
  `[TaskEvent(a), TaskEvent(b)]`、`name` 为 `EventType.Multi.toString()` 的 `MultiEvent`
- **THEN** `a` 与 `b` 各被派发一次，Multi 任务返回 `DummyEvent`
- **AND** 该 Multi 任务的 acceptable 事件 `eventType` 为 `Multi`、事件名为
  `EventType.Multi.toString()`，证明它经 `Dispatcher.registerMultiTask` 登记，而不是经业务
  入口 `registerTask`（后者登记为 `Task`，收不到 `MultiEvent`）

#### Scenario: 首任务校验未被绕过

- **WHEN** 构造 `ImmediateFlow("c", "t")`、`registerStart("created")`，随后注册一个
  `acceptableEvents = ["other"]` 的业务任务
- **THEN** 仍抛 `GraphException`，消息指向首任务必须与开始事件一致

#### Scenario: 重复构造不重复注册

- **WHEN** 同一 `("c", "t")` 分别用 `ImmediateFlow` 与 `AsyncFlow` 各构造两次，再投入一个
  含单个子事件的 `MultiEvent`
- **THEN** 两条路径下该子事件都只被派发一次（Multi 任务未重复登记）
- **AND** `AsyncFlow` 的去重依赖构造期 flow 集合已加入自身（`ImmediateFlow` 以 dispatcher
  表判重）

### Requirement: 任务注册只使用 Task 重载

脚本 SHALL 使用 `flow.registerTask(task: Task)`。`flow.registerTask(eventName: String, task: (Event) -> Event)`
不属于脚本契约：宿主描述符**只登记 `Task` 重载**，闭包重载不在注册表中，调用即编译期报错。

#### Scenario: ClosureTask 注册

- **WHEN** 脚本执行 `flow.registerTask(compile(...))`
- **THEN** 注册成功，任务按 `acceptableEvents` 绑定到 dispatcher

#### Scenario: 闭包重载不可用

- **WHEN** 脚本执行 `flow.registerTask("evt", t)`
- **THEN** 编译期报「未注册方法」（描述符中没有该重载）

### Requirement: 脚本类型面的限制

脚本 SHALL NOT：

1. 对事件/流程类型使用 `is` / `as`（手工注册不合成 `$as$` 转型判定函数）；
2. 调用 `emit` / `start` / `initDispatcher`（未进入描述符或名空间）。

#### Scenario: 非法类型操作在编译期失败

- **WHEN** 脚本写 `e as TaskEvent`
- **THEN** 初始化期编译失败，错误指向缺失的转型判定函数，而不是运行期静默错误

#### Scenario: 事件分支用字段判别

- **WHEN** 任务体需要按事件名分支
- **THEN** 使用 `if (e.name == "validated") { ... } else { ... }`，两个分支都返回 `Event`

### Requirement: 事件构造面

脚本 SHALL 通过 `FlowEventFactory` 的静态函数构造与读取事件：
`flowTaskEvent`、`flowEndEvent`、`flowErrorEvent`、`flowDummyEvent`、`flowDataOf`。
脚本 SHALL NOT 直接调用 `Event` 家族构造器（`data: Any` 槽无法从方言表达）。

#### Scenario: 结束事件由工厂构造

- **WHEN** 任务体为 `flowEndEvent("order", "v1", "ok")`
- **THEN** 流程结束事件为 `EndEvent`，`category`/`tag` 与流程一致

#### Scenario: 直接构造事件失败

- **WHEN** 任务体为 `EndEvent("order", "v1", "ok")`
- **THEN** 初始化期编译失败：事件类描述符里**没有登记任何构造器**（`data: Any` 的形参类型码
  不在合法集内），构造器解析无候选

### Requirement: 旧标签清理

脚本末行 SHALL 调用 `flow.removeExceptCurrentTag()`，以承接旧 `FlowDSLCompiler` 在编译结束时
删除同 `category`、不同 `tag` 流程的行为。

#### Scenario: 旧标签被清理

- **WHEN** 先注册 `order/v1`，再执行注册 `order/v2` 的脚本（末行调用清理）
- **THEN** `order/v1` 的 dispatcher 被移除，`order/v2` 可用

#### Scenario: 未调用清理

- **WHEN** 脚本遗漏 `removeExceptCurrentTag()`
- **THEN** 旧标签继续存在；该行为作为契约违例由测试与评审发现（运行期不额外报错）

### Requirement: 错误语义

脚本编译失败、运行期异常、注册校验失败 SHALL 立即终止 `initialize()` 并上抛原始异常；
已完成注册 SHALL 不回滚。`FlowInitializer` SHALL NOT 吞掉 `SourceCompileException` 或 `JitException`。

#### Scenario: 编译错误中止初始化

- **WHEN** 第一个脚本语法非法，第二个脚本合法
- **THEN** `initialize()` 抛 f_jit 编译异常，第二个脚本未执行

#### Scenario: 运行期错误中止初始化

- **WHEN** 脚本执行 `flow.registerTask` 时触发 `GraphException`
- **THEN** 该异常原样上抛

### Requirement: 异步流程前置条件

`FlowInitializer` SHALL NOT 隐式调用 `AsyncFlow.initDispatcher`。脚本构造 `AsyncFlow` 前，
宿主 SHALL 已调用 `AsyncFlow.initDispatcher(...)`。

#### Scenario: 已初始化时可注册

- **WHEN** 测试先调用 `AsyncFlow.initDispatcher()`，再执行异步脚本
- **THEN** `registerStart`/`registerTask` 成功

#### Scenario: 未初始化时失败

- **WHEN** 未调用 `AsyncFlow.initDispatcher` 就执行构造 `AsyncFlow` 的脚本
- **THEN** 初始化失败并上抛（现有 `getDispatcher().getOrThrow()` 行为）

### Requirement: 旧 DSL 不兼容

旧 DSL 字符串 SHALL NOT 被新初始化路径解析。`FlowLoader` 的实现方 SHALL 按设计文档 §6.4 的
映射表重写脚本；本变更 SHALL NOT 提供自动转换器。

#### Scenario: 旧 DSL 字符串被拒绝

- **WHEN** `FlowLoader` 仍返回 `immediate(order, v1): 'created' => { ... }`
- **THEN** 初始化期 f_jit 编译失败（不是旧的 DSL 语义错误）

### Requirement: 异步调度不持锁阻塞

`AsyncDispatcher` SHALL NOT 在 `mutex` 内阻塞取事件队列（队列自身线程安全）；
`AsyncFlow.doRemove` SHALL 在 `removeIf` 完成后统一删除 `flows` 条目，避免下一事件重建流程时
重登记 Multi 造成自锁。

#### Scenario: 异步启动后立即清理不自锁

- **WHEN** 异步流程 `start` 返回后立即调用 `remove()` 或 `removeExceptCurrentTag()`
- **THEN** 调用在有限时间内返回，随后的 `start` 仍能完成（有超时断言）
