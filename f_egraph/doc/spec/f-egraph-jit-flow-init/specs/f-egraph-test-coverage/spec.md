# Spec Delta — f-egraph-test-coverage

## ADDED Requirements

### Requirement: 测试组织与门禁

单元测试 SHALL 位于 `f_egraph/src` 下，按领域拆分为独立 `*_test.cj`，使用仓颉 `std.unittest`。
测试 SHALL 可通过 `cjpm test` 在 `f_egraph` 模块内运行；本变更合入前 SHALL 全绿。

#### Scenario: 模块内可运行

- **WHEN** 在 `f_egraph` 目录执行 `cjpm test`
- **THEN** 全部测试通过，且不依赖外部服务、网络或真实时钟等待

#### Scenario: 用例隔离

- **WHEN** 连续运行两次 `cjpm test`
- **THEN** 结果一致；流程用例使用的 `category` 唯一并在结束时清理

### Requirement: 事件模型测试

SHALL 覆盖 `EventType`、`Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、
`ErrorEvent`、`MultiEvent`、`DummyEvent` 与 `GraphException` 的全部公开成员。

#### Scenario: EventType 全值

- **WHEN** 遍历 `Start`/`Task`/`End`/`Error`/`Multi`/`Dummy`
- **THEN** `toString` 返回对应名称，`==` 仅对同值返回 `true`，`hashCode` 稳定且不同值可区分

#### Scenario: Event 相等性与哈希

- **WHEN** 构造 `eventType/category/tag/name` 相同但 `session` 不同的两个 `Event`
- **THEN** `==` 返回 `true`，`hashCode` 相等（现有语义忽略 `session`）

#### Scenario: Event 不等

- **WHEN** 任一 `eventType`/`category`/`tag`/`name` 不同
- **THEN** `==` 返回 `false`

#### Scenario: 事件子类构造器

- **WHEN** 分别构造 `StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent(message)`、
  `ErrorEvent(error)`、`MultiEvent`
- **THEN** `eventType` 分别为 `Start`/`End`/`Task`/`Error`/`Error`/`Multi`，
  `name` 与 `data` 符合各构造器约定

#### Scenario: DataEvent 取数

- **WHEN** `data` 为 `String`，调用 `tryGet<String>()`；再调用 `tryGet<Int64>()`
- **THEN** 前者返回 `Some`，后者返回 `None`

#### Scenario: DummyEvent 单例

- **WHEN** 两次读取 `DummyEvent.instance`
- **THEN** 为同一对象，`eventType == Dummy`，`session` 为空串

#### Scenario: GraphException 四种构造

- **WHEN** 分别使用无参、`message`、`cause`、`message + cause` 构造
- **THEN** `message` 与 `cause` 符合 `BaseException` 约定

### Requirement: 执行器与调度器测试

SHALL 覆盖 `Accepter`、`Executor`、`ImmediateExecutor`、`StartExecutor`、`EndExecutor`、
`ErrorExecutor`、`TaskExecutor`、`AsyncTaskExecutor`、`ConcurrentEndExecutor`、
`Dispatcher`、`ImmediateDispatcher`、`AsyncDispatcher` 的全部公开成员。

#### Scenario: 执行器接受/拒绝事件

- **WHEN** 用匹配事件调用 `accept`，再用不匹配事件调用 `accept`
- **THEN** 前者执行，后者抛 `GraphException`

#### Scenario: 开始/结束/错误执行器

- **WHEN** `StartExecutor` 收到 `DataEvent`；`EndExecutor` 收到事件；`ErrorExecutor` 收到字符串/异常/其它数据
- **THEN** `StartExecutor` 发出同内容的 `TaskEvent`；`EndExecutor.get()` 返回事件；
  `ErrorExecutor` 分别抛带消息/带原因/带类型名的 `GraphException`

#### Scenario: TaskExecutor 三种构造

- **WHEN** 分别用直接闭包、`newByImmediateFlow`、`newByAsyncFlow` 构造并执行
- **THEN** 闭包结果被交给 `Accepter`；子流程启动并返回其结束事件

#### Scenario: ConcurrentEndExecutor 等待

- **WHEN** 在另一线程延迟 `execute`，主线程 `get()` 或 `get(timeout:)`
- **THEN** 在事件到达后返回；超时返回 `None`

#### Scenario: ImmediateDispatcher 注册与路由

- **WHEN** 注册 start/end/error/task 并 `start(StartEvent)`
- **THEN** 事件按注册顺序路由，`get()` 返回 `EndExecutor`；重复注册/无执行器抛 `GraphException`

#### Scenario: ImmediateDispatcher 清理

- **WHEN** 调用 `removeIf` 匹配某事件的谓词
- **THEN** 该事件执行器被移除，后续派发按「无执行器」处理

#### Scenario: AsyncDispatcher 异步等待

- **WHEN** 初始化后注册并 `start`，随后 `get()` / `tryGet(timeout:)`
- **THEN** 结果在异步执行完成后可见；超时返回 `None`；`removeIf` 生效

### Requirement: 流程与 Barrier 测试

SHALL 覆盖 `BaseFlow`、`Flow<G>`、`ImmediateFlow`、`AsyncFlow`、`Emitter`、`BarrierKey`、
`BarrierTask<G>` 的全部公开成员。

#### Scenario: 同步流程端到端

- **WHEN** 构造 `ImmediateFlow`，`registerStart/End/Error`，注册一个返回 `EndEvent` 的任务并 `start`
- **THEN** `start` 返回的 `EndExecutorGetter.get()` 返回该结束事件

#### Scenario: 异步流程端到端

- **WHEN** 调用 `AsyncFlow.initDispatcher()` 后构造 `AsyncFlow`、注册任务并 `start`
- **THEN** `AsyncEndExecutorGetter.get()` / `tryGet(timeout:)` 返回结束事件

#### Scenario: 构造期 Multi 注册与扇出

- **WHEN** 构造 `ImmediateFlow`（以及 `initDispatcher` 后的 `AsyncFlow`），由构造期注册 Multi
  任务，再注册子事件执行器并投入 `MultiEvent`
- **THEN** 子事件各被派发一次，Multi 任务返回 `DummyEvent`
- **AND** 该 Multi 任务的 acceptable 事件 `eventType` 为 `Multi`、事件名为
  `EventType.Multi.toString()`；业务入口 `registerTask` 登记的是 `Task` 类型，收不到
  `MultiEvent`（负向对照）
- **AND** 同一 `(category, tag)` 在 `ImmediateFlow` 与 `AsyncFlow` 各二次构造后，含单个子事件
  的 `MultiEvent` 仍只派发一次（`AsyncFlow` 以构造期 flow 集合判重，`ImmediateFlow` 以
  dispatcher 表判重）

#### Scenario: 事件发射

- **WHEN** 在任务中调用 `flow.emit(eventType:name:data:)`
- **THEN** 事件按 `category`/`tag` 路由到已注册执行器

#### Scenario: 流程相等性与字符串

- **WHEN** 两个 `ImmediateFlow`/`AsyncFlow` 的 `category`/`tag` 相同或不同
- **THEN** `==`/`hashCode` 按 `category + tag` 判定；`toString` 为 `"category-tag"`

#### Scenario: 依赖与移除

- **WHEN** 通过 `registerTaskByFlow`/`registerTaskByImmediateFlow`/`registerTaskByAsyncFlow` 建立依赖后调用 `canBeRemoved`/`remove`
- **THEN** 有依赖时抛 `GraphException`；无依赖时可移除；`removeExceptCurrentTag` 删除同 category 旧 tag

#### Scenario: BarrierTask 累积

- **WHEN** 同一 `BarrierKey` 累积到阈值
- **THEN** `exec` 返回 `DummyEvent`，并让依赖流程发出配置的产出事件；不足阈值不发出；
  非 `DataEvent` 入参抛 `GraphException`

#### Scenario: BarrierKey 相等性

- **WHEN** `category`/`tag`/`eventName`/`session` 全同或任一不同
- **THEN** `==` 与 `hashCode` 按四个字段判定

### Requirement: JIT 绑定、手工注册与脚本任务测试

SHALL 覆盖 `ClosureTask`、`FlowEventFactory`、`JitHostRegistry`，并同时验证两条注册路径：

1. **宏路径**：`Task`、`ClosureTask`、`FlowEventFactory` 的 `JitBindSupport.enrolledOf` 条目；
2. **手工路径**：`Event` 家族、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow` 的
   `ClassDescriptor` 成员面（方法名集合、字段名 + 索引 + 类型码、构造器 `params`），
   且这些类型的宏登记表为空。

#### Scenario: 宏登记面

- **WHEN** 读取 `JitBindSupport.enrolledOf` 中 `Task`、`ClosureTask`、`FlowEventFactory` 的条目
- **THEN** 期望的公共成员存在；`Event`/`DataEvent`/`BaseFlow`/`ImmediateFlow`/`AsyncFlow`
  的条目为空

#### Scenario: 手工登记面（金线）

- **WHEN** 对一个全新 `Compiler` 调用 `JitHostRegistry.configure`
- **THEN** 每个手工类的成员集合与设计 §5.2 金线**完全相等**（不多不少）：
  事件类 4 个字段（索引 0–3、类型码 4、不可写）；`Event` 只有 `toString` 方法；
  `BaseFlow`/`ImmediateFlow`/`AsyncFlow` 各有 7 个方法、`registerTask` 只有一条；
  两个流程类各有 `params = [4,4]` 的构造器；`Emitter` 方法面为空

#### Scenario: 手工注册的端到端可用性

- **WHEN** 用脚本逐项调用金线里的每个方法，并读取 `e.name`/`e.category`/`e.tag`
- **THEN** 全部按宿主语义生效；不存在「描述符里有、调用即失败」的条目

#### Scenario: 字段访问器已登记

- **WHEN** 查询 `HostFieldTable` 的索引 0–3 对 `TaskEvent` 实例的访问器
- **THEN** 分别返回 `category`/`tag`/`name`/`session` 的值；未登记的 `data` 不在表中

#### Scenario: ClosureTask 契约

- **WHEN** 构造 `ClosureTask` 并读取 `name`/`acceptableEvents`/`producingEvents`；调用 `exec`
- **THEN** 返回构造时注入的执行体结果

#### Scenario: ClosureTask.compile 成功

- **WHEN** 用合法 `exec` 与 `ArrayList<Any>` 事件列表编译并执行
- **THEN** 返回 `Task`，其执行结果与 `FlowEventFactory` 构造的事件一致

#### Scenario: ClosureTask.compile 失败

- **WHEN** 传入空白名称、空事件列表、空白 `exec`、非法源码
- **THEN** 前三者抛 `GraphException`，非法源码抛 f_jit 编译异常

#### Scenario: FlowEventFactory 全函数

- **WHEN** 逐个调用五个静态函数
- **THEN** 事件类型、字段、`flowDataOf` 返回值与边界分支符合设计 §7.2

#### Scenario: 静态名空间门禁（端到端）

- **WHEN** 用注册后的 `Compiler` 编译并执行分别调用 `compile`、`flowTaskEvent`、
  `flowEndEvent`、`flowErrorEvent`、`flowDummyEvent`、`flowDataOf` 的脚本
- **THEN** 6 个调用全部成功，证明宏静态入口确实进入了预定义函数面
- **AND** 调用 `initDispatcher` 或 `DummyEvent.instance` 的脚本编译期失败
- **AND** 不以 `registeredNames()` 作为宏静态名是否存在的判据：它只含 `registerClass`
  的方法绑定，`registerType` 的 `autoFunctions` 只在 `snapshot()` 时并入

### Requirement: 初始化与加载器测试

SHALL 覆盖 `FlowLoader` 与 `FlowInitializer` 的公开成员，以及脚本初始化的成功/失败路径。

#### Scenario: 名称与依赖

- **WHEN** 读取 `FlowInitializer.name` 与 `dependencies`
- **THEN** 分别为 `"fountain::f_egraph"` 与 `["fountain::f_bean"]`

#### Scenario: 脚本初始化成功

- **WHEN** 通过假 `FlowLoader` 提供同步流程脚本并调用 `initialize()`
- **THEN** 流程注册成功，任务按事件路由，`removeExceptCurrentTag` 生效

#### Scenario: 脚本初始化失败

- **WHEN** 提供空脚本、非法源码、重复注册或缺少 `initDispatcher` 的异步脚本
- **THEN** 分别抛 `GraphException` / f_jit 编译异常 / `GraphException` / 运行时异常，
  且不继续执行后续脚本

#### Scenario: 编译器共享

- **WHEN** 两个脚本都调用 `compile(...)`
- **THEN** 二者使用 `FlowInitializer` 注入的同一 `Compiler`，静态名无重复注册错误
