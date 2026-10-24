# Proposal: f_egraph 接入 f_jit 并重写流程初始化

## Why

`f_egraph` 现在的流程编排依赖自研 `FlowDSLCompiler`（`f_egraph/src/base/FlowDSLCompiler.cj:37`）：
用 `std.ast` 做词法 + 递归下降，只支持把 IoC 中**已存在的 `Task` bean 按名字**串成图。
这带来三个问题：

1. **任务体无法随编排一起交付**。DSL 只能引用 `lookupList<Task>()` 里已有的任务，流程定义与任务实现分离，无法在配置/运行期下发完整流程。
2. **维护成本高**。DSL 的词法、括号闭合、事件校验、重载解析全部手写（`FlowDSLCompiler.cj:41-178`），且与 `f_jit` 已具备的编译能力重复。
3. **宿主互操作仍是反射路径**。`Task`/`Event` 等宿主类型被 JIT 调用时仍走 `InstanceFunctionInfo.apply` 等 MCC 路径；改为显式绑定后，调用期只剩我们自己写的类型判断 + 直接方法调用。

`f_jit` 已提供 `Compiler.registerClass(ClassDescriptor)` / `registerType<T>()` /
`registerInterface<I>()` / `compile(source)` / `JitFunction.call<T>()`
（`f_jit/src/Compiler.cj:103-162`）与 `@JitBind` 宏（`f_jit/src/macros/JitBind.cj:47`）。
本变更把流程初始化整体切到 `f_jit`。

**关键约束（评审结论）**：本变更原则上**不修改 `f_jit` 的既有行为**。`@JitBind` 当前无法展开
`f_egraph` 大多数宿主类型（大量命名形参、`operator func ==`、函数类型形参），原方案里
「先修宏」的 D0 与 R1/R9 修正**全部撤销**。凡是宏不可用的类型，改为在 `f_egraph` 侧用
`Compiler.registerClass(ClassDescriptor)` 手工注册，统一收敛在 `JitHostRegistry`。

**唯一例外（评审新增）**：`f_jit` 新增 `@IgnoreJitBinding` 成员宏——它只能出现在 `@JitBind`
修饰的声明内部（`assertParentContext('JitBind')`），通过子宏消息通知 `@JitBind` 跳过指定
公共成员。`@JitBind` 仅在成员遍历时多读一份「忽略名单」，既有绑定语义不变。

## What Changes

0. **路线：`f_jit` 仅新增 `@IgnoreJitBinding`，需求 2–6 退化为手工注册**。撤销原 D0（宏支持命名实参）与
   R1/R9（宏跳过 operator / 函数类型形参）：不实现这两类宏修正。
   宏不可用的类型——`Event` 及全部子类、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow`
   ——用 `Compiler.registerClass(ClassDescriptor)` 手工注册：手写 `PublicMethod`（方法绑定）、
   `PublicCtor`（构造器）、`PublicField`（字段），接口用 `isInterface = true` 的
   `ClassDescriptor` 表达。字段的**运行期读取**另需 `HostFieldTable.register(...)`（手工注册
   不会生成反射访问器）。全部收敛在 `JitHostRegistry`，见 `design.md` §4 D0/D1 与 §5。
1. **依赖**：`f_egraph/cjpm.toml` 增加 `"fountain::f_jit" = {path = "../f_jit"}`；
   注解文件导入 `fountain::f_jit.macros.*`（仅 `Task`/`ClosureTask`/`FlowEventFactory` 需要）。
2. **事件模型（手工注册）**：`Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、
   `ErrorEvent`、`MultiEvent`、`DummyEvent` 不标注 `@JitBind`；由 `JitHostRegistry` 逐个
   `registerClass`，事件字段 `category`/`tag`/`name`/`session` 作为 `PublicField` 注册并配套
   `HostFieldTable` 访问器；`data: Any` 不注册（见需求 11）。
3. **任务接口（宏可用，保留 `@JitBind`）**：`Task` 标注 `@JitBind`，用
   `registerInterface<Task>()` 注册。非泛型实现 `ClosureTask` 一并标注。
   `BarrierTask<G>` 是泛型类，宏会生成 `enrollOf<BarrierTask>`（缺类型实参）无法编译，
   **明确排除**并在设计文档记录原因。
4. **流程接口（手工注册）**：`BaseFlow` 用 `ClassDescriptor(isInterface = true)` 注册；
   只登记脚本契约用到的成员（`registerStart`/`registerEnd`/`registerError`/
   `registerTask(Task)`/`remove`/`removeExceptCurrentTag`/`canBeRemoved`）。
   `emit(..., data: Any)` 的 `Any` 形参在 `PredefinedFunction` 合法集之外，不注册。
   `Flow<G>` 是泛型接口，不注册。
5. **流程实现（手工注册）**：`ImmediateFlow`、`AsyncFlow` 用 `registerClass` 手工登记
   构造器 `(String, String)` 与上述方法；`AsyncFlow.initDispatcher` **不**进脚本名空间
   （`Duration` 形参与宿主配置语义都不适合脚本），仍由宿主调用。
6. **发射器接口（手工注册）**：`Emitter` 用 `ClassDescriptor(isInterface = true)` 注册，
   方法面为空（唯一成员 `emit` 含 `Any` 形参，不进脚本面）。
7. **新增 `ClosureTask`**：`public class ClosureTask <: Task`，持有 `(Event) -> Event` 执行体；
   提供 `static func compile(name: String, acceptableEvents: ArrayList<Any>,
   producingEvents: ArrayList<Any>, exec: String)`，用 `f_jit.Compiler` 把 `exec` 源码
   编译成任务执行体。事件列表用 `ArrayList<Any>`：f_jit 的 LIST 运行时形态恒为
   `ArrayList<Any>`（`IterTable.cj:256`），泛型不协变，`ArrayList<String>` 形参从脚本调用
   必然 `typeMismatch`；`compile` 内部逐元素校验 `is String`，否则抛 `GraphException`。
   构造器的函数类型形参若无法被宏展开，按 `design.md` §7.1 回退为「包内函数类型构造器 +
   公有 `JitFunction` 构造器」。
8. **删除 `FlowDSLCompiler`**：同时删除只服务于它的 `TaskDef`、`ProducingDef`；移除
   `FlowInitializer` 中的调用。
9. **重写 `FlowInitializer.initialize`**：创建并配置 `Compiler`，由 `JitHostRegistry`
   完成「手工注册 + 宏注册」两类宿主类型，逐个执行 `FlowLoader` 返回的编排脚本；
   脚本内实例化 `ImmediateFlow`/`AsyncFlow` 与 `ClosureTask`，调用
   `registerStart`/`registerEnd`/`registerError`/`registerTask` 完成编排。
10. **补齐单元测试**：覆盖 `f_egraph` 现有全部公开 API，以及本变更新增的 `ClosureTask`、
    `FlowEventFactory`、脚本初始化路径、**手工注册的成员面**（防止漏登记成员）。
11. **保留脚本事件工厂 `FlowEventFactory`**（设计决策 D4，本次评审确认保留）：
    `f_jit` 的 `Any` 成员槽不可映射，事件构造器的 `data: Any` 无法从脚本直接调用；
    提供 5 个静态函数（3 个 `String` 载荷构造器 + `Dummy` 构造器 + `flowDataOf` 读取）。
    `FlowEventFactory` 是宏可用的普通类，继续标注 `@JitBind`。
12. **修复三个既有缺陷（设计决策 D9，由 0.3/0.6 spike 发现）**：
    a) **构造期 Multi 注册撞业务校验**：`ImmediateFlow`/`AsyncFlow` 构造器调用
    `registerMultiEventTask()`，`Flow<G>` 的默认实现走业务任务入口
    `registerTask(eventName:task:)`，命中「`startName` 为空 / 首任务必须等于开始事件」两条
    校验，流程**无法构造**；
    b) **`MultiEvent` 永远无法分发**：改走 `Dispatcher.registerTask` 后，该入口仍把执行器的
    acceptable 事件硬编码为 `EventType.Task`，而 `MultiEvent` 的 `eventType` 是 `Multi`、
    `Event.==`/`hashCode` 计入 `eventType`，因此 Multi 任务**永远收不到** `MultiEvent`；
    c) **`AsyncFlow` 重复构造去重失效**：`flows` 判重集合只查询/删除、从不写入，每次构造都
    重复登记，`doRemove` 内的重建还会反向再登记。
    d) **宿主新实例无法启动已注册流程**：`startName` 是实例字段，脚本注册写在脚本实例上，
    宿主再构造同 `(category, tag)` 的新实例时 `startName` 为空，`StartEvent` 的 name 匹配不到
    执行器（旧 DSL 路径同样受影响）。
    修复按方案 A′：`Dispatcher` 增加 `internal registerMultiTask`，`ImmediateDispatcher`
    以 `eventType = Multi` 的 acceptable 事件实现、`AsyncDispatcher` 加锁转调，
    `ImmediateFlow`/`AsyncFlow` 覆写 `registerMultiEventTask()` 调用该入口，`AsyncFlow`
    构造成功后把自身加入 `flows`。共改 5 个文件，公开 API 不变、不放宽业务首任务规则。
13. **新增 `f_jit` 成员宏 `@IgnoreJitBinding`（本次评审唯一允许的 `f_jit` 改动）**：
    它只能修饰 `@JitBind` 声明内部的公共成员，用 `assertParentContext('JitBind')` 约束位置；
    展开时通过 `setItem` 向父宏发送成员名，`@JitBind` 用
    `getChildMessages('IgnoreJitBinding')` 收集忽略名单并写入 `JitBindings.ignored`；宏展开与
    `ReflectRegistrar` 的反射注册**两层**都跳过名单内成员，从而把
    `ClosureTask.initCompiler` 这类仅宿主可用的成员真正排除出脚本名空间。`@JitBind`
    的既有绑定语义与其它公开 API 不变；配套 `f_jit` 宏测试与反射侧忽略测试（合法/非法位置、
    重载按名忽略、脚本调用编译失败）。

## 需求 2–6 的退化与代价

需求 2–6 原本以「给宿主类型加 `@JitBind`」实现。撤销宏修正后，它们退化为
**全手工注册**，这是本变更最主要的成本：

| 需求 | 原方案 | 现方案（退化后） | 代价 |
|---|---|---|---|
| 2 事件模型 | 8 个类型各加 1 行注解 | 8 个 `ClassDescriptor` + 4 条 `HostFieldTable` 访问器 + 父链声明 | 约 200–300 行，逐成员手写 |
| 3 任务接口 | `Task` + `ClosureTask` 注解 | 不变（宏可用） | 无 |
| 4 流程接口 | `BaseFlow` 注解 | `ClassDescriptor(isInterface=true)` + 7 个 `PublicMethod` | 约 120 行 |
| 5 流程实现 | 2 个注解 | 2 个 `ClassDescriptor`（含 `(String,String)` 构造器与各 7 个方法） | 约 200 行 |
| 6 发射器接口 | `Emitter` 注解 | `ClassDescriptor(isInterface=true)`（方法面为空） | 约 20 行 |

三项具体代价：

1. **代码量**：`JitHostRegistry` 从「约 30 行注册调用」膨胀到「数百行的成员描述 + 适配器闭包」，
   且每个 `PredefinedFunction` 都要手写 `match (args[0] as C)` 解包与类型校验。
2. **成员遗漏风险**：宏遍历类体，漏掉的成员会由编译器（类型不存在）或测试兜住；手工注册靠人列清单，
   漏一个成员**不会报错**——只会在脚本用到时报「未注册方法/字段」。
3. **没有宏 WARNING**：`@JitBind` 对泛型方法、`static var`、`static mut prop` 会发 WARNING，
   提示「哪些成员没有绑定」；手工注册没有这层信号，必须用「登记面金线测试」自建门禁
   （见 `design.md` §9.3 与 `tasks.md` 1.x）。

反过来，手工注册也带来两个正向效果，设计与测试应利用：

- 脚本 API 面**精确可控**：只登记契约里用到的成员，`Any` 形参、闭包重载、`static` 成员
  一律不进名空间，不再依赖宏的映射规则；原「`Any` 槽映射」「静态名冲突」「重载被按名折叠」
  三类约束大部分随之消失；
- 同名重载不再被注册表按名字折叠，`registerTask(Task)` 是**显式**唯一登记项。

## Impact

- **破坏性变更**：
  - `FlowLoader.load()` 返回值的语义由「旧 DSL 文本」变为「f_jit 编排脚本」，旧字符串**不可直接复用**，所有 `FlowLoader` 实现必须重写（迁移映射见 `design.md` §6）。
  - 删除公开声明 `FlowDSLCompiler`、`TaskDef`、`ProducingDef`。
  - 旧 DSL 在编译期做的「任务可接受事件/产出事件」校验**不再自动执行**；错误脚本在初始化期以 `GraphException`/`JitException` 失败。
- **新增依赖**：`f_egraph` 编译期与运行期依赖 `f_jit`（`f_jit` 自身依赖 `f_macros`、`f_regex`、`f_util` 等，均已在本 workspace）。
- **`f_jit` 的唯一改动**：新增 `@IgnoreJitBinding` 宏（配合 `@JitBind` 使用，用于把
  `ClosureTask.initCompiler` 这类宿主专用静态成员排除出脚本名空间）；`@JitBind` 增加
  `getChildMessages('IgnoreJitBinding')` 的忽略名单收集，既有展开语义与公开 API 不变。
  除此之外不加 API、不做命名形参 / operator / 函数类型形参的宏修正；这些限制仍由
  `f_egraph` 侧的手工注册承担。
- **行为保持**：`Event`/`Task`/`Flow`/`register*`/`start`/`emit` 的宿主侧语义不变；
  `ImmediateFlow`/`AsyncFlow` 的 `removeExceptCurrentTag` 语义由脚本末行显式调用承接（见 §6.4）。
- **既有缺陷修复**：`ImmediateFlow`/`AsyncFlow` 构造期调用 `registerMultiEventTask()`，默认实现
  却走业务入口 `registerTask(eventName:task:)`，构造时必然命中「开始事件未注册 / 首任务必须
  是开始事件」校验并抛 `GraphException`；即使绕过校验，`registerTask` 也把执行器登记为
  `EventType.Task` 键，`MultiEvent`（`eventType = Multi`）永远匹配不到；`AsyncFlow` 的
  `flows` 判重集合又从不写入，重复构造会重复登记。这三个缺陷在本变更**之前就已存在**：旧
  DSL 路径（`FlowDSLCompiler.cj:50-55`）走同一个构造入口与 dispatcher，同样不可用；脚本化
  路径只是把它们暴露出来。本变更按设计 D9 方案 A′ 修复（5 个文件，公开签名不变），使两条
  路径同时恢复。
- **回归测试**：新增「流程构造可用」用例（新 category 构造不抛、`AsyncFlow` 在
  `initDispatcher` 后可构造、经 `registerMultiTask` 的 Multi 扇出且执行器 acceptable 事件为
  `Multi`、首任务约束仍生效、`ImmediateFlow` 与 `AsyncFlow` 同 `(category, tag)` 二次构造
  不重复登记），见 `tasks.md` 0.6/5.2/5.3 与两份 spec。
- **测试影响**：删除旧 DSL 用例；新增全量公开 API 单测，并新增「手工注册面」金线测试
  （逐类断言登记的方法/字段/构造器集合，防止静默漏登记）。
- **性能**：宿主成员从反射 MCC 路径切到手工适配器（直接方法调用）；流程首次初始化多一次
  脚本编译（随后命中 `CompileCache`）。

## 非目标

- 不做旧 DSL 到新脚本的自动转换器；迁移由 `FlowLoader` 实现方按映射表手工完成。
- 不改变 `Flow` 的生命周期语义（`AsyncFlow` 的 dispatcher 仍由宿主显式 `initDispatcher`）。
- **不修改 `f_jit` 的既有语义**：不实现 `@JitBind` 的命名实参支持、不处理 `operator func`、
  不改函数类型形参的类型码。原 D0/R1/R9 的「修宏」方案作废；唯一例外是新增
  `@IgnoreJitBinding` 宏与 `@JitBind` 的忽略名单收集（见 What Changes 第 13 项）。
- 不把 `BarrierTask<G>` 改造成非泛型。
- 不为脚本面恢复 `Any` 载荷：`Event.data` 仍走 `FlowEventFactory` 的 `String` 通道。
