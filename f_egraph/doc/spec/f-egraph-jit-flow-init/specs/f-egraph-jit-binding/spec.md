# Spec Delta — f-egraph-jit-binding

## ADDED Requirements

### Requirement: f_jit 改动边界

本变更 SHALL NOT 修改 `@JitBind` 的既有展开语义、命名形参处理、`operator func` 与函数类型
形参映射；SHALL NOT 新增除 `@IgnoreJitBinding` 之外的注册 API。唯一允许的 `f_jit` 改动是
新增 `@IgnoreJitBinding` 成员宏，以及 `@JitBind` 遍历成员前收集忽略名单。

#### Scenario: 除忽略宏外无宏语义改动

- **WHEN** 对比变更前后的 `f_jit/src/macros`
- **THEN** 仅新增 `IgnoreJitBinding.cj` 与 `JitBind.cj` 中的忽略名单收集
- **AND** 其余宏的展开结果与变更前一致，`f_jit` 原有测试全绿

### Requirement: IgnoreJitBinding 成员宏

`@IgnoreJitBinding` SHALL 只能修饰 `@JitBind` 声明内部的公共成员；展开时 SHALL 用
`assertParentContext('JitBind')` 校验位置，并通过 `setItem` 向父宏投递成员名；
`@JitBind` SHALL 用 `getChildMessages('IgnoreJitBinding')` 收集名单并写入
`JitBindings.ignored`。**宏展开与 `ReflectRegistrar` 反射注册两层 SHALL 都跳过**名单内成员，
使其不进入注册表。被忽略的成员 SHALL 仍能在仓颉侧按原语义调用。

#### Scenario: 排除宿主专用静态成员

- **WHEN** `ClosureTask.initCompiler` 标注 `@IgnoreJitBinding`
- **THEN** `ClosureTask` 的宏登记静态面不含 `initCompiler`，`compile` 仍在
- **AND** 脚本中调用 `initCompiler` 在编译期失败（反射层也未登记）

#### Scenario: 实例成员同样不登记

- **WHEN** `@JitBind` 类的某个公共实例方法标注 `@IgnoreJitBinding`
- **THEN** 宏登记面与 `registerType<T>()` 的反射自动包装都不含该方法

#### Scenario: 非法位置

- **WHEN** `@IgnoreJitBinding` 用在未被 `@JitBind` 修饰的类的成员上
- **THEN** 编译失败，错误信息包含父上下文 `JitBind`

#### Scenario: 忽略不误伤

- **WHEN** 同一 `@JitBind` 类中另有未标注 `@IgnoreJitBinding` 的公共静态成员
- **THEN** 该成员仍出现在登记静态面

### Requirement: f_jit 依赖与宏可见性

`f_egraph` SHALL 在 `f_egraph/cjpm.toml` 的 `[dependencies]` 中声明
`"fountain::f_jit" = {path = "../f_jit"}`，并在 `f_egraph/src/base/imports.cj` 导入
JIT 门面、注册协议（`ClassDescriptor`/`PublicMethod`/`PublicCtor`/`PublicField`/
`PredefinedFunction`/`LocalType`）与 `HostFieldTable`。`fountain::f_jit.macros.*` SHALL 在
**需要注解的三个文件**（`Task.cj`、`ClosureTask.cj`、`FlowEventFactory.cj`）中逐文件导入——
宏导入是文件级的，`imports.cj` 的导入对同包其它文件不可见。
模块的 `output-type = "dynamic"` 与 `--dy-std` 编译选项 SHALL 保持不变。

#### Scenario: 依赖可解析

- **WHEN** 在 `f_egraph` 目录执行 `cjpm build`
- **THEN** `../f_jit` 被解析为同一 workspace 的模块，编译通过且无循环依赖

#### Scenario: 宏只在三个类型上可见

- **WHEN** 检查 `Task.cj`、`ClosureTask.cj`、`FlowEventFactory.cj`
- **THEN** `@JitBind` 可解析；`Event.cj`、`Emitter.cj`、`Flow.cj`、`ImmediateFlow.cj`、
  `AsyncFlow.cj` 中**没有**任何 `@JitBind`

### Requirement: 事件模型手工注册

`Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent`、`MultiEvent`、
`DummyEvent` SHALL NOT 标注 `@JitBind`；SHALL 由 `JitHostRegistry` 用
`Compiler.registerClass(ClassDescriptor)` 逐个注册，并满足：

1. 每个描述符的 `fields` SHALL 包含 `category`/`tag`/`name`/`session` 四项，
   类型码 `4`（`STRING`）、`mutable = false`，索引分别为 `0/1/2/3`；
2. `parents` SHALL 按真实父链填写（直接父类在前）；
3. `HostFieldTable` SHALL 为这 4 个索引各注册一条访问器，`accepts` 为 `{ o => o is Event }`；
4. `DataEvent.data`（`Any`）与 `eventType` SHALL NOT 出现在描述符中；
5. 方法面 SHALL 只包含 `Event.toString`（`[14] -> 4`）；其余事件类不注册方法；
6. 构造器 SHALL NOT 登记（`data: Any` 的形参类型码不在 `PublicCtor` 合法集内），
   事件只能由 `FlowEventFactory` 构造。

#### Scenario: 事件类型可注册

- **WHEN** 对全新 `Compiler` 调用 `JitHostRegistry.configure`
- **THEN** `hasClass` 对 `Event`/`DataEvent`/`StartEvent`/`EndEvent`/`TaskEvent`/
  `ErrorEvent`/`MultiEvent`/`DummyEvent` 全部返回 `true`

#### Scenario: 脚本可读取事件字段

- **WHEN** 编译并执行 `{ e: Event => e.name }`，传入 `EndEvent("c", "t", "ok")`
- **THEN** 返回 `"End"`
- **AND** 传入 `TaskEvent("c", "t", "step", "x")` 时返回 `"step"`

#### Scenario: 未登记的成员不可访问

- **WHEN** 编译 `{ e: Event => e.data }` 或 `{ e: Event => e.eventType }`
- **THEN** 编译期报「未注册字段」，不产生运行期调用

#### Scenario: 事件不再有宏登记

- **WHEN** 读取 `JitBindSupport.enrolledOf` 中 `Event`、`DataEvent`、`DummyEvent` 的条目
- **THEN** 为空（这三个类型没有 `@JitBind`）

### Requirement: 任务接口注册（宏）

`Task` SHALL 标注 `@JitBind`，并通过 `Compiler.registerInterface<Task>()` 注册。
其方法绑定由宏生成，不手工维护。

#### Scenario: 接口注册成功

- **WHEN** 调用 `registerInterface<Task>()`
- **THEN** 不抛 `RegistrationException`，`hasClass("Task")` 为 `true`，
  且 `JitBindSupport.enrolledOf` 中存在 `name`/`exec` 的方法绑定

### Requirement: 发射器与流程接口手工注册

`Emitter` 与 `BaseFlow` SHALL NOT 标注 `@JitBind`；SHALL 用
`ClassDescriptor(isInterface = true)` 注册：

- `Emitter` 的方法面为空（唯一成员 `emit` 含 `Any` 形参，不在 `PredefinedFunction` 合法集内）；
- `BaseFlow` 只登记 `canBeRemoved`、`remove`、`removeExceptCurrentTag`、`registerStart`、
  `registerEnd`、`registerError`、`registerTask(Task)` 七个方法；
  `registerTask(eventName, closure)`（函数类型形参）、`emit`/`start`（`Any` 形参）、
  `dependencied`（容器属性）、`registerMultiEventTask`/`registerTaskBy*Flow`（泛型）
  SHALL NOT 登记。

#### Scenario: 接口描述符可注册

- **WHEN** 调用 `registerClass(emitterDescriptor)` 与 `registerClass(baseFlowDescriptor)`
- **THEN** 不抛 `RegistrationException`，`hasClass("Emitter")`/`hasClass("BaseFlow")` 为 `true`

#### Scenario: 流程编排方法可调用

- **WHEN** 脚本以 `let flow = ImmediateFlow("c", "t")` 声明并调用
  `registerStart`/`registerEnd`/`registerError`/`registerTask`
- **THEN** 四个调用均按宿主语义生效（dispatcher 中对应执行器已注册）
- **AND** `BaseFlow` 自身的同一组方法由金线测试断言，另有一条「`let f: BaseFlow = ImmediateFlow(...)`」
  的编译用例证明接口类型可用

#### Scenario: 闭包重载与 emit 不可用

- **WHEN** 脚本调用 `flow.registerTask("evt", { e: Event => e })` 或
  `flow.emit(0, "n", "d")`
- **THEN** 编译期报「未注册方法」，因为这两个成员不在描述符中

#### Scenario: 泛型接口不参与注册

- **WHEN** 检查 `Flow<G>` 的源码与注册路径
- **THEN** `Flow<G>` 上没有 `@JitBind`，也不在注册表中

### Requirement: 流程实现手工注册

`ImmediateFlow` 与 `AsyncFlow` SHALL NOT 标注 `@JitBind`；SHALL 用 `registerClass`
手工注册，且：

1. 构造器 SHALL 为 `params = [4, 4]`（`category`、`tag`）；
2. 方法 SHALL 包含 `canBeRemoved`、`remove`、`removeExceptCurrentTag`、`registerStart`、
   `registerEnd`、`registerError`、`registerTask(Task)`，签名与 `BaseFlow` 一致；
3. `start`、`emit`（`Any` 形参）与闭包重载 SHALL NOT 登记；
4. `parents` SHALL 包含 `BaseFlow`。

#### Scenario: 同步流程可实例化并注册

- **WHEN** 脚本执行 `let flow = ImmediateFlow("c", "t")` 后调用
  `registerStart("created")`/`registerEnd()`/`registerError()`
- **THEN** 构造与三次注册均成功，`flow.start(...)` 由宿主触发的流程可正常结束

#### Scenario: 异步流程可实例化并注册

- **WHEN** 宿主先 `AsyncFlow.initDispatcher()`，脚本再 `AsyncFlow("c", "t")` 并注册
- **THEN** 构造与注册成功；脚本名空间中**不存在** `initDispatcher`

#### Scenario: 只登记 Task 重载

- **WHEN** 检查 `ImmediateFlow`/`AsyncFlow` 描述符的 `registerTask` 条目
- **THEN** 只有一条，`paramTypes = [14, 14]`；脚本 `flow.registerTask(t)` 编译并执行成功

### Requirement: ClosureTask

SHALL 新增 `public class ClosureTask <: Task`，持有 `(Event) -> Event` 执行体，并标注 `@JitBind`。
其 `static func compile(name: String, acceptableEvents: ArrayList<Any>,
producingEvents: ArrayList<Any>, exec: String)` SHALL：

1. 事件列表形参固定为 `ArrayList<Any>`（f_jit 的 LIST 运行时形态恒为 `ArrayList<Any>`，
   泛型不协变使 `ArrayList<String>` 形参从脚本调用必然 `typeMismatch`）；
2. 逐元素校验列表项 `is String`，否则抛 `GraphException`；
3. 校验 `name`、两个事件列表、`exec` 均非空，否则抛 `GraphException`；
4. 把 `exec` 包裹为 `{ e: Event => <exec> }` 后用共享 `Compiler` 编译；
5. 返回一个 `ClosureTask`，其 `exec(e)` 调用编译产物并返回 `Event`；
6. 编译与运行期异常原样上抛。

`ClosureTask` SHALL 提供 `public static func initCompiler(compiler: Compiler)`；未注入时 SHALL
惰性创建并配置一个编译器。

`ClosureTask` 的构造器 SHALL 保证 `@JitBind` 可展开：若函数类型形参 `(Event) -> Event`
的展开不合法，SHALL 将带函数类型的构造器改为包内可见，并另提供以 `JitFunction` 为形参的
公有构造器（见设计 §7.1 回退方案）。`compile` 的签名与行为 SHALL 不受该调整影响。

#### Scenario: 构造器可被宏展开

- **WHEN** 在 `f_egraph` 目录执行 `cjpm build`
- **THEN** `ClosureTask` 的 `@JitBind` 展开编译通过；若走回退方案，公有构造器的形参列表
  不含函数类型

#### Scenario: 编译并执行任务体

- **WHEN** 以 `exec = "flowEndEvent(\"c\", \"t\", \"ok\")"` 调用 `ClosureTask.compile` 并执行 `exec(EndEvent(...))`
- **THEN** 返回的 `Event` 是 `EndEvent`，且 `FlowEventFactory.flowDataOf` 对其返回 `"ok"`

#### Scenario: 列表字面量匹配

- **WHEN** 脚本执行 `compile("t", ["a"], ["b"], "flowDummyEvent()")`
- **THEN** 编译通过（列表字面量运行时为 `ArrayList<Any>`），返回可注册任务

#### Scenario: 非字符串列表项被拒绝

- **WHEN** 宿主传入含非 `String` 元素的 `ArrayList<Any>`
- **THEN** `compile` 抛 `GraphException`

#### Scenario: 空任务名被拒绝

- **WHEN** `name` 为空白字符串
- **THEN** `compile` 抛 `GraphException`

#### Scenario: 空事件列表被拒绝

- **WHEN** `acceptableEvents` 或 `producingEvents` 为空
- **THEN** `compile` 抛 `GraphException`

#### Scenario: 编译错误保留 f_jit 语义

- **WHEN** `exec` 是非法 f_jit 源码
- **THEN** `compile` 抛出 f_jit 的编译异常（含站点信息），不被包装成 `GraphException`

### Requirement: FlowEventFactory

SHALL 新增 `public class FlowEventFactory` 并标注 `@JitBind`，提供以下静态函数：

- `flowTaskEvent(category, tag, name, data: String): Event`
- `flowEndEvent(category, tag, data: String): Event`
- `flowErrorEvent(category, tag, message: String): Event`
- `flowDummyEvent(): Event`
- `flowDataOf(event: Event): String`

#### Scenario: 构造任务事件

- **WHEN** 调用 `flowTaskEvent("c", "t", "n", "payload")`
- **THEN** 返回 `TaskEvent`，其 `category`/`tag`/`name` 与实参一致，`flowDataOf` 返回 `"payload"`

#### Scenario: 构造结束与错误事件

- **WHEN** 调用 `flowEndEvent` 与 `flowErrorEvent`
- **THEN** 分别返回 `EndEvent` 与 `ErrorEvent`，`ErrorEvent` 的消息为传入的 `message`

#### Scenario: 非字符串载荷读取

- **WHEN** `flowDataOf` 接收一个 `data` 不是 `String` 的 `DataEvent`，或接收非 `DataEvent`
- **THEN** 返回空串，不抛异常

### Requirement: 宿主类型注册与编译器共享

`FlowInitializer.initialize()` SHALL 在执行任何脚本前通过 `JitHostRegistry.configure(compiler)`
完成以下注册（`JitHostRegistry` 为公开类，允许宿主复用来配置自己的 `Compiler`）：

1. 8 个事件类型：`registerClass` + 4 条 `HostFieldTable` 访问器；
2. `Emitter`、`BaseFlow`：`registerClass(isInterface = true)`；
3. `ImmediateFlow`、`AsyncFlow`：`registerClass`（含 `(String, String)` 构造器）；
4. `Task`：`registerInterface<Task>()`；
5. `ClosureTask`、`FlowEventFactory`：`registerType<T>()`。

注册完成后 SHALL 通过 `ClosureTask.initCompiler` 注入同一个 `Compiler` 实例。

#### Scenario: 注册面完整

- **WHEN** 初始化完成后检查 `compiler.hasClass(...)`，并用同一个 `Compiler` 编译执行分别调用
  `compile(...)` 与 5 个 `flow*` 的脚本
- **THEN** 上述类型全部存在；6 个静态入口的脚本调用全部成功
- **AND** 脚本调用 `initDispatcher(...)` 或 `DummyEvent.instance` 时编译期失败
- **NOTE** `registeredNames()` 只含 `registerClass` 写入的方法绑定；`registerType` 的
  `autoFunctions` 仅在 `snapshot()` 时并入（`Compiler.cj:149-185`），不能用它断言宏静态名

#### Scenario: 共享编译器生效

- **WHEN** 脚本内调用 `compile(...)`
- **THEN** 使用 `FlowInitializer` 注入的同一 `Compiler`（可通过编译缓存命中验证）

### Requirement: 移除 FlowDSLCompiler

`FlowDSLCompiler`、`TaskDef`、`ProducingDef` SHALL 从 `f_egraph/src` 删除且不再被任何代码引用。
README 中 SHALL 只在「从旧 DSL 迁移」章节以「已删除」的说明形式提及这三个名字，用于指导迁移；
其余章节 SHALL NOT 出现。

#### Scenario: 源码无残留

- **WHEN** 在 `f_egraph/src` 搜索 `FlowDSLCompiler`、`TaskDef`、`ProducingDef`
- **THEN** 无匹配；`cjpm build` 通过

#### Scenario: README 只保留迁移说明

- **WHEN** 检查 `README.md` 与 `README_en.md`
- **THEN** 三个名字只出现在「从旧 DSL 迁移」章节，且语义是「已删除」

#### Scenario: 初始化不再走 DSL

- **WHEN** 阅读 `FlowInitializer.initialize` 实现
- **THEN** 只存在 `Compiler` + `FlowScriptRunner` 路径，不存在 `FlowDSLCompiler.compile`
