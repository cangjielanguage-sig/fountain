# Design: f_egraph 接入 f_jit 与脚本化流程初始化

## 1. 背景与现状

`f_egraph` 是一个事件驱动的流程执行器，核心模型为：

- **事件**：`Event`（`f_egraph/src/base/Event.cj:18`）及 `DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent`、`MultiEvent`、`DummyEvent`。
- **任务**：`Task`（`f_egraph/src/base/Task.cj:18`），声明 `name`、`acceptableEvents`、`producingEvents` 与 `exec(Event): Event`。
- **流程**：`BaseFlow`（`f_egraph/src/base/Flow.cj:18`）与泛型 `Flow<G>`（`Flow.cj:43`），实现为 `ImmediateFlow`（同步）与 `AsyncFlow`（异步）。
- **调度**：`ImmediateDispatcher` / `AsyncDispatcher` 按事件路由到 `Executor`，`EndExecutor` 收集结束事件。
- **初始化**：`FlowInitializer.initialize()`（`f_egraph/src/egraph.cj:35`）遍历 `lookup<FlowLoader>().load()`，对每个字符串调用 `FlowDSLCompiler.compile`。

旧 DSL 由 `FlowDSLCompiler` 用 `std.ast` 现场解析，语法形如：

```
immediate(order, v1): 'created' => {
    validate |> {
        'validated' => { pay |> {END} }
        'rejected'  => { notify |> {END} }
    }
}
```

它的语义是「按名字查 `lookupList<Task>()`，把已有任务接到事件图上」，任务体本身不在字符串里。

## 2. 目标与非目标

### 目标

1. `f_egraph` 通过路径依赖接入 `f_jit`。
2. 事件、任务、流程、发射器全部暴露给 JIT 方言：**宏可用的类型用 `@JitBind`，其余用
   `Compiler.registerClass(ClassDescriptor)` 手工注册**，两者统一收敛在 `JitHostRegistry`。
3. `FlowLoader` 返回的字符串改为可直接执行的 **f_jit 编排脚本**，脚本内实例化 `ImmediateFlow`/`AsyncFlow` 与 `ClosureTask`，完成任务注册。
4. 删除 `FlowDSLCompiler` 及其专属类型。
5. 为 `f_egraph` 全部公开 API 补齐单元测试。

### 非目标

- 不保留旧 DSL 的解析器，也不做自动迁移。
- 不改变 `Event`/`Flow`/`Dispatcher` 的既有宿主语义。
- **不修改 `f_jit` 的既有语义**：不实现 `@JitBind` 的命名实参支持、不处理 `operator func`、
  不改函数类型形参的类型码。原「先修宏再注解」的 D0 与 R1/R9 全部作废；宏展开不了的类型由
  `f_egraph` 手工注册承担。唯一例外：新增 `@IgnoreJitBinding` 宏与 `@JitBind` 的忽略名单
  收集（见 D10），`@JitBind` 既有语义不变。
- 不把 `BarrierTask<G>` 泛型化改造为非泛型。

## 3. 依赖与模块边界

- `f_egraph/cjpm.toml` 的 `[dependencies]` 增加：
  ```toml
  "fountain::f_jit" = {path = "../f_jit"}
  ```
- `f_egraph/src/base/imports.cj` 增加 JIT 门面、注册协议与宏导入：
  ```cangjie
  internal import fountain::f_jit.{Compiler, CompileOptions, JitFunction}
  internal import fountain::f_jit.base.{ClassDescriptor, PublicCtor, PublicField, PublicMethod}
  internal import fountain::f_jit.base.{PredefinedFunction, JitBindings, LocalType, DummyDiagnosticsSink}
  internal import fountain::f_jit.runtime.HostFieldTable
  internal import fountain::f_jit.JitBindSupport
  internal import fountain::f_jit.macros.*
  ```
  该文件是 `base` 包集中导入点，与现有 `f_base`/`f_util` 等导入方式一致。
  `fountain::f_jit.macros.*` 只服务 `Task`、`ClosureTask`、`FlowEventFactory` 三个仍标注
  `@JitBind` 的类型；`JitBindSupport` 只用于测试断言（`enrolledOf`），生产代码不引用。
- 根包（`f_egraph/src/egraph.cj` 与新增的 `src/FlowScriptRunner.cj`）不在 `base` 包内，
  SHALL 自行导入 `Compiler`/`CompileOptions`/`DummyDiagnosticsSink` 与
  `fountain::f_egraph.exception.GraphException` 等所需类型（沿用 `egraph.cj` 现有的逐文件导入方式）。
- 依赖方向：`f_egraph` → `f_jit` → `f_macros`/`f_regex`/`f_util`/`f_base`/`f_data`，无环。

## 4. 设计决策

### D0 · 路线：不改 `f_jit`，需求 2–6 退化为手工注册

**原方案作废**：先前设计打算先修 `@JitBind`（D0 命名实参、R1 跳过 `operator func`、
R9 函数类型形参），再给宿主类型加注解。评审结论是**不动 `f_jit` 任何代码**，因此这三项修正
撤销，对应的风险项也随之改写（见 §10）。

#### 为什么这些类型不能加 `@JitBind`

| 阻塞点 | 位置 | 宏的现状 | 直接后果 |
|---|---|---|---|
| 命名形参（形参名后带 `!`） | `Event.cj:57-88`、`Emitter.cj:19`、`ImmediateFlow.cj:110`、`AsyncFlow.cj:121`、两个流程类的主构造器 | 三个调用点都用**位置实参**生成（`JitBind.cj:237`、`:379`、`:468`） | 展开即编译失败 |
| `operator func ==` | `Event.cj:29`、`ImmediateFlow.cj:61`、`AsyncFlow.cj:70` | 生成 `__self.==(other)`（`JitBind.cj:224-242`），该调用形式未在本仓库验证过 | 展开可能编译失败 |
| 函数类型形参 | `BaseFlow.registerTask(eventName:task:)` | `codeOf` 无函数类型分支 → 落 `14`，并生成 `as (Event) -> Event`（`JitBind.cj:194-209`） | 展开可能编译失败 |
| `Any` 形参 | `Emitter.emit`、`ImmediateFlow.start`/`emit`、`AsyncFlow.start`/`emit` | 未知类型统一落 `14`（`JitBind.cj:392-413`），而脚本侧 `data: Any` 无对应类型码 | 即使展开也**不可从脚本调用** |

这四类问题分别命中 `f_egraph` 的 8 个事件类、`Emitter`、`BaseFlow`、`ImmediateFlow`、
`AsyncFlow`——即需求 2、4、5、6 的全部类型。

#### 决策：手工注册

宏不可用的类型改为在 `f_egraph` 侧构造 `ClassDescriptor` 并交给
`Compiler.registerClass(desc)`（`Compiler.cj:103`）：

- **类**：`ClassDescriptor(name, fields, methods, ctors, parents, isInterface = false)`，
  手写 `PublicField` / `PublicMethod` / `PublicCtor`；
- **接口**：同一个 API，`isInterface = true`、字段与构造器为空。**不使用**
  `registerInterface<I>()`：它要求方法绑定非空，而 `Emitter` 的唯一成员带 `Any` 形参（不可登记），
  且它合成的 `$as$<I>` 依赖宏登记的 `o is I` 谓词（`JitBindSupport.acceptsInterface`，
  只有 `enrollInterfaceOf` 会填）——手工路径下该谓词恒为 `false`，是「静默给错答案」。
  用 `isInterface = true` 的描述符则没有 `$as$` 槽，脚本写 `as I` 会在**编译期**报错。
- **静态成员**：`ClassDescriptor` 没有 statics 槽位；本变更脚本可见的静态入口只有
  `ClosureTask.compile` 与 `FlowEventFactory.flow*`（共 6 个名字），都来自仍走宏的类，
  由 `registerType` 自动并入，不需要手工注册静态函数。
- **字段运行期访问**：手工注册不会生成反射访问器，`HOST_GET_FIELD` 只查
  `HostFieldTable`（`runtime/HostField.cj:68`），因此字段必须配一条
  `HostFieldTable.register(index, type, mutable, accepts, getter, setter)`；漏登记会在脚本读字段时
  运行期报 99。

#### 代价（必须记录，验收时逐条核对）

1. **代码量**：`JitHostRegistry` 从「几十行注册调用」膨胀到数百行成员描述 + 适配器闭包；
   每个 `PredefinedFunction.impl` 都要手写解包与类型判断。
2. **成员遗漏风险**：宏遍历类体、遗漏由编译器兜底；手工注册靠人列清单，**漏一个成员不会报错**，
   只在脚本用到时报「未注册方法/字段」。缓解见 §9.3 的登记面金线测试。
3. **没有宏 WARNING**：`@JitBind` 对泛型方法、`static var`、`static mut prop` 发 WARNING
   （`JitBind.cj:76-131`）；手工注册没有这层提示，必须靠测试断言「该有的都有、不该有的都没有」。

正向副作用（设计主动利用）：

- 脚本 API 面**精确可控**：只登记契约用到的成员，`Any` 形参、闭包重载、`static` 成员
  一律不进名空间；`emit`/`start`/`initDispatcher`/`DummyEvent.instance` 不再出现在脚本面，
  原「`Any` 槽映射」与「静态名冲突」两类约束大幅收缩；
- 同名重载不再被注册表按名字折叠（原 R10 的脆弱点消失）：`registerTask` 只登记 `Task` 重载，
  这是**显式**决定，不再依赖类体声明顺序。

### D1 · 注册方式清单（宏 vs 手工）

| 类型 | 注册方式 | 说明 |
|---|---|---|
| `Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent`、`MultiEvent`、`DummyEvent` | **手工** `registerClass` | 阻塞点：命名形参 + `operator func ==`；字段靠 `HostFieldTable` |
| `Emitter` | **手工** `registerClass(isInterface = true)` | 唯一成员带 `Any` 形参；方法面为空 |
| `BaseFlow` | **手工** `registerClass(isInterface = true)` | 阻塞点：函数类型形参 + 命名形参；只登记脚本契约成员 |
| `Flow<G>` | **不注册** | 泛型接口，见 D2 |
| `ImmediateFlow`、`AsyncFlow` | **手工** `registerClass` | 阻塞点：命名形参（构造器、`emit`）+ `operator func ==` |
| `Task` | `@JitBind` + `registerInterface<Task>()` | 接口成员均为普通类型，宏可用 |
| `ClosureTask` | `@JitBind` + `registerType<ClosureTask>()` | 新增类；静态 `compile` 进入预定义函数面 |
| `FlowEventFactory` | `@JitBind` + `registerType<FlowEventFactory>()` | 新增脚本事件工厂（见 D4） |
| `BarrierTask<G>` | **不注册** | 泛型类，宏会生成 `enrollOf<BarrierTask>`（缺类型实参）；保持纯宿主用法 |

`BarrierTask<G>` 不参与 JIT 的理由不变：宏只取 `klass.identifier`，不会补类型实参
（`f_jit/src/macros/JitBind.cj:141-169`），对泛型类直接编译失败；需要 JIT 任务时用 `ClosureTask`。

`Task` 是唯一仍走宏的接口。它没有泛型方法、没有 `Any` 形参、没有 `operator func`，
`@JitBind` 能正常展开；`registerInterface<Task>()` 还会登记 `o is Task` 谓词与 `$as$Task`
槽，供 14 实参校验使用。脚本契约仍不使用 `as`：反射拿不到接口实现关系，
`ClosureTask` 的 `parents` 只有父类链，静态收窄不可靠。

### D2 · `Flow<G>` 不注册，脚本只面向具体流程类

`Flow<G>` 的类型参数与默认方法（`registerMultiEventTask`、`registerTaskByFlow`、`registerTaskByImmediateFlow`、`registerTaskByAsyncFlow`，`Flow.cj:44-85`）不是脚本必需的：

- `registerMultiEventTask` 在 `ImmediateFlow`/`AsyncFlow` 的构造器内部调用（`ImmediateFlow.cj:24-26`、`AsyncFlow.cj:62-64`），
  脚本无需再次注册；该调用按 D9 直接走 dispatcher，不经过业务任务校验；
- 子流程注册（`registerTaskBy*Flow`）需要泛型类型实参，脚本方言不支持；
- 脚本通过具体类型 `ImmediateFlow`/`AsyncFlow` 的 `registerStart`/`registerEnd`/`registerError`/`registerTask` 完成编排即可。

因此 `Flow<G>` 既不标注也不注册；注册表只有 `BaseFlow` 与两个具体流程类。

### D3 · 脚本执行模型：每个字符串是一个「无参脚本」

`FlowLoader` 的契约保持 `ArrayList<String>`（`f_egraph/src/loader/FlowLoader.cj:20`），但每个元素的含义变为：

> **一段 f_jit 源码语句序列，包裹为 `{ => ... }` 后执行一次，执行过程完成一个流程的注册。**

`FlowInitializer` 统一做包装与调用：

```cangjie
let source = "{ =>\n" + script + "\n}"
let fn = compiler.compile(source)
fn.call<Unit>([])
```

- **不追加哨兵表达式**：f_jit 的空括号 `()` 不被解析（`Parser.cj:1182` 的 `LParen` 分支无条件
  `parseExpr()`，空括号报 `SyntaxError`）。闭包返回类型取块内最后一条表达式的类型，因此脚本
  **末条语句必须是 `Unit` 表达式**（约定为 `flow.removeExceptCurrentTag()`）；末条语句不是
  `Unit` 时 `call<Unit>` 在编译期报类型不符，这是刻意的严格化；
- 脚本必须是**语句序列**，不是完整 lambda（避免 `{ e => ... }` 与空参混淆）；
- 一个脚本只注册一个流程（`removeExceptCurrentTag` 依赖这一约定）。

**空脚本**（去空白后为空）视为配置错误，抛 `GraphException`，不静默跳过。

### D4 · 事件载荷桥：`FlowEventFactory`

这是本设计中最容易被忽略的硬约束：

1. `Event` 家族的事件构造器把 `data` 声明为 `Any`（`Event.cj:48`、`Event.cj:57-88`）。
2. `PredefinedFunction` / `PublicCtor` 的形参合法集是 `0–8`、`10–11`、`13`、`14`
   （`base/PredefinedFunction.cj:59-69`、`base/ClassRegistration.cj:135-146`），**不含 15（ANY）**
   ——手工注册根本无法表达 `Any` 形参。
3. 即使把 `data` 强行登记为 `14`，构造器重载匹配也按**静态类型码精确相等**
   （`f_jit/src/compiler/Lowerer.cj:2462-2487`）：脚本里的字符串是 `4`，匹配不上。
4. 宏也帮不上忙：`@JitBind` 的编译期映射对未知类型一律落 `14`（`JitBind.cj:392-413`），
   而 `Any` 在运行期映射里明确返回 `None`（`f_jit/src/ReflectRegistrar.cj:750-751`）。

结论：**事件构造器不作为脚本 API**，事件类型的手工描述符里也不登记任何构造器。
若强行暴露，脚本只能构造无载荷事件或直接编译失败。

因此新增 `public class FlowEventFactory`（仅静态函数，无实例状态），把脚本需要的事件出口收敛为 `String` 载荷：

```cangjie
@JitBind
public class FlowEventFactory {
    public static func flowTaskEvent(category: String, tag: String, name: String, data: String): Event
    public static func flowEndEvent(category: String, tag: String, data: String): Event
    public static func flowErrorEvent(category: String, tag: String, message: String): Event
    public static func flowDummyEvent(): Event
    /** data 为 String 时返回其值，否则返回空串；非 DataEvent 返回空串。 */
    public static func flowDataOf(event: Event): String
}
```

- 参数/返回全部是 `String`（4）或宿主类（14），在方言里可调用；
- 内部仍构造合法的事件对象，宿主侧 `data` 仍是 `Any`，不改变现有模型；
- 脚本面的载荷类型收敛为 `String`，这是本变更接受的表达能力边界，记录在 §11。

### D5 · 编译器共享与生命周期

`ClosureTask.compile` 的签名由需求固定，没有 `Compiler` 形参。因此采用**静态共享编译器**：

```cangjie
public class ClosureTask <: Task {
    private static let compilerMtx = Mutex()
    private static var sharedCompiler: ?Compiler = None

    @IgnoreJitBinding
    public static func initCompiler(compiler: Compiler): Unit
    private static func ensureCompiler(): Compiler
}
```

- `FlowInitializer.initialize` 先构造 `Compiler`、调用 `JitHostRegistry.configure(compiler)` 注册宿主类型，再 `ClosureTask.initCompiler(compiler)`。
- `compile` 在未显式注入时惰性创建并配置一个编译器（便于单测直接使用 `ClosureTask.compile`）。
- `static var sharedCompiler` 是私有静态变量，宏对私有成员静默忽略（`JitBind.cj:95-105` 只处理 public
  `static var`，且那一支也只发 WARNING），不会被绑定。
- 所有脚本共用同一 `Compiler`，`CompileCache` 对相同 `exec` 源码命中缓存。

### D6 · `ClosureTask.compile` 的 `exec` 契约

`exec` 是**任务体语句序列**，不是完整 lambda：

```cangjie
let source = "{ e: Event =>\n" + exec + "\n}"
let fn = compiler.compile(source)
```

- 参数名固定为 `e`，脚本作者可直接使用；
- 返回值必须是 `Event`（14）；
- `ClosureTask` 持有 `JitFunction`，`exec(e)` 调用 `fn.call<Event>([e])`；
- 不采用「编译返回闭包 + `callForFn`」的路径，避免闭包逃逸、提升组与 `close()` 生命周期问题；
- 编译错误（`SourceCompileException`）与运行期错误（`JitException`）**原样上抛**，不包装成 `GraphException`，保留 f_jit 的站点与错误码。

### D7 · 删除 DSL 与迁移

删除：

- `f_egraph/src/base/FlowDSLCompiler.cj`（含 `FlowDSLCompiler`、`TaskDef`、`ProducingDef`）；
- `egraph.cj` 中的 `FlowDSLCompiler.compile(flow)` 调用；
- README/README_en 中 DSL 章节与「其他公开 API」清单里的 `ProducingDef`/`TaskDef`。

旧 DSL 与新脚本**不是文本兼容关系**，是两种语言。迁移方必须按 §6.4 的映射重写 `FlowLoader`。

### D8 · 静态名空间（手工注册后收缩）

`@JitBind` 把类的 `public static func` / `public static let` 注册为**不带类名的全局预定义函数**（`JitBind.cj:424-494`）。手工注册的 `ClassDescriptor` 没有 statics 槽位，因此**只有仍走宏的三个类**会往全局名空间加东西：

| 来源 | 脚本名 | 用途 |
|---|---|---|
| `ClosureTask.compile` | `compile` | 编译任务体 |
| `FlowEventFactory.*` | `flowTaskEvent` / `flowEndEvent` / `flowErrorEvent` / `flowDummyEvent` / `flowDataOf` | 事件构造与读取 |

`ClosureTask.initCompiler` 虽然也是 `public static`，但标注了 `@IgnoreJitBinding`（D10），
因此**不进**静态名空间，只供宿主调用。

相对原方案，脚本名空间少了两个名字：

- `AsyncFlow.initDispatcher` —— `AsyncFlow` 改为手工注册，静态成员不再自动进入名空间。
  这符合「dispatcher 由宿主显式初始化」的既有语义（`AsyncFlow.cj:20`），也避免脚本用
  `Duration` 形参（脚本面没有合适的时长字面量表达）。
- `DummyEvent.instance` —— `DummyEvent` 改为手工注册；脚本统一用 `flowDummyEvent()`。
  原 R3 里「`instance` 名字过于泛化」的担忧随之消失。

注册顺序不影响解析。

**`registeredNames()` 不能作为静态名门禁**：它只返回 `registerClass` 写入的 `fns`
（`Compiler.cj:149-157`），`registerType`/`registerInterface` 由反射生成的 `autoFunctions`
只在 `snapshot()` 时才并入（`Compiler.cj:170-185`）。门禁改为**端到端**：用同一 `Compiler`
编译并执行调用 `compile(...)` 与 5 个 `flow*` 的脚本各一次，全部成功；反向用
`initDispatcher(...)` / `DummyEvent.instance` 的脚本调用断言编译期失败。`registeredNames()`
仍可用于手工注册面的局部断言，但不得用它证明宏静态名存在。

### D9 · 修复 Flow 构造期 Multi 注册与分发的三个既有缺陷

**结论来源**：`tasks.md` 0.3 的可行性 spike 在「脚本构造 `ImmediateFlow`」一步阻塞——
`let flow = ImmediateFlow("c", "t")` 直接抛 `GraphException`。这不是脚本化引入的新问题，
而是 `f_egraph` 的既有缺陷：旧 DSL 路径（`FlowDSLCompiler.cj:50-55`）走同一个构造入口，
同样受影响。0.6 第一轮修掉构造校验后，spike 又在「Multi 事件扇出」处阻塞，暴露出另外两个
同源缺陷：分发键错位、`AsyncFlow` 判重集合从不写入。三个缺陷都在宿主侧，与 `f_jit` 无关，
本变更一并修复。

#### 缺陷 1：构造期 Multi 注册撞业务校验

1. `ImmediateFlow` 构造器（`ImmediateFlow.cj:22-27`）与 `AsyncFlow` 构造器
   （`AsyncFlow.cj:60-66`）在静态表中尚无当前 `(category, tag)` 时调用
   `registerMultiEventTask()`；
2. 两个类都没有覆写该方法，落到 `Flow<G>` 的默认实现（`Flow.cj:67-69`）。默认实现调用的是
   **业务任务入口** `registerTask(eventName: String, task: (Event) -> Event)`；
3. 该重载在 `ImmediateFlow.cj:92-101`（`AsyncFlow.cj:101-110` 同构）有两条前置校验：
   - `startName.size == 0` → 抛「There must be with StartExecutor before registering
     first TaskExecutor」；
   - `!hasFirstTask` 时事件名必须等于 `startName` → 抛「First TaskExecutor name must be
     same as StartExecutor name」。

   构造期 `startName` 必然为空，第一条立即命中，因此**任何流程都无法构造**。

**「延后到 `registerStart` 再注册」也逃不掉**：延后只满足第一条；Multi 任务的事件名是
`EventType.Multi.toString()`，不可能等于业务开始事件，第二条必然命中。除非放宽业务校验，
否则该路径走不通。

#### 缺陷 2：`MultiEvent` 永远无法分发

按缺陷 1 的修法把 Multi 任务改为直接调 `Dispatcher.registerTask` 后，构造不再失败，但 Multi
事件仍然收不到：

1. `ImmediateDispatcher.registerTask`（`ImmediateDispatcher.cj:46-50`）把 `TaskExecutor` 的
   acceptable 事件**硬编码**为 `Event(eventType: EventType.Task, category, tag, name: eventName)`；
2. `MultiEvent` 的 `eventType` 是 `EventType.Multi`（`Event.cj:84-89`）；
3. `Event` 的 `hash` 与 `==` 都计入 `eventType`（`Event.cj:27`、`29-32`），而 `executors` 是
   `HashMap<Event, ArrayList<Executor>>`（`ImmediateDispatcher.cj:19`），查表用整个事件对象
   （`:91-93`）；
4. 因此无论 `eventName` 传什么，经 `registerTask` 登记的执行器键都是 `Task` 类型，永远不等于
   投递进来的 `MultiEvent`；`dispatch` 未命中即抛 `GraphException("No executor found for event: ...")`
   （`:59-68`）。

`AsyncDispatcher` 是 `ImmediateDispatcher` 的加锁包装（`AsyncDispatcher.cj:26`、`:52-56`、
`:139-143`），同步路径与异步路径等价，都收不到 Multi 事件。

#### 缺陷 3：`AsyncFlow` 重复构造去重失效

`AsyncFlow` 构造器（`AsyncFlow.cj:60-66`）用 `!flows.contains(this)` 判重，但 `flows`
（`:58`）在构造期从未写入：

- 每次构造都判定「未注册」，重复调用 `registerMultiEventTask()`；
- `doRemove`（`:46-57`）在 `removeIf` 谓词里重建 `AsyncFlow(category:tag:)`，该重建同样不在
  `flows` 中，会**反向再登记**一次；
- `ImmediateDispatcher` 的私有 `doRegister(executor:)`（`:41-45`）只追加、无重复校验，重复
  登记后同一子事件被扇出两次。

`ImmediateFlow` 以 `dispatchers` 表本身判重（`ImmediateFlow.cj:24-26`，`getDispatcher()` 的
`computeIfAbsent` 会写入该表），不存在这个问题；`AsyncFlow` 的 dispatcher 是全局单例，必须
额外维护 `flows` 集合。修复：构造成功后 `flows.add(this)`（`AsyncFlow.cj:64`，第一轮已落），
`doRemove` 时同步删除（`:51`）。

#### 方案 A′（采用）：dispatcher 增内部专用入口

- `Dispatcher` 增加
  `internal func registerMultiTask(category!: String, tag!: String, task!: (Event) -> Event): Unit`；
- `ImmediateDispatcher` 实现：构造
  `TaskExecutor(acceptingEvent: Event(eventType: EventType.Multi, category: category, tag: tag, name: EventType.Multi.toString()), accepter: this, task: task)`，
  经私有 `doRegister(executor:)` 追加（与业务 `registerTask` 同一条追加路径，重复登记仍由
  流程层的判重挡住）；
- `AsyncDispatcher` 实现：`synchronized(mutex) { dispatcher.registerMultiTask(category: category, tag: tag, task: task) }`；
- `ImmediateFlow` / `AsyncFlow` 覆写 `registerMultiEventTask()`，改调
  `getDispatcher().registerMultiTask(category: category, tag: tag, task: multiEventTaskBody(this))`，
  不再经过业务入口；
- `Flow.cj` 的 `internal func multiEventTaskBody`（`:48-60`）第一轮已抽出，两个流程类继续复用，
  本轮不再改 `Flow.cj`。

依据：

- `registerMultiTask` 只做「构造 `TaskExecutor` + 按事件名挂载」，**没有**注册顺序前置校验，
  也没有 `hasFirstTask` 概念；两条校验全部在 `Flow` 实现层，绕过它们不改变 dispatcher 语义。
- **业务首任务约束原样保留**：`hasFirstTask` 仍只由业务 `registerTask(eventName, closure)`
  推进，构造期不置位；脚本第一个业务任务仍必须与 `registerStart` 的事件名一致
  （「首任务必需接受开始事件」场景不变）。
- **公开 API 不变**：`registerMultiTask` 是 `internal`，包外不可见；`BaseFlow`/`Flow<G>`/
  `Dispatcher` 的公开签名不变；`Dispatcher` 不在 JIT 注册表（§5）里，脚本面同样不受影响。
- **失败语义保持**：`AsyncFlow.getDispatcher()` 仍是 `dispatcher.getOrThrow()`，
  未 `initDispatcher` 时构造照样抛异常（异常来源由「`startName` 为空」变为 dispatcher 未初始化）。
- 默认实现保留给第三方 `Flow` 实现；它们若同样在构造器里调用，需要按同一模式覆写（或自行
  调用 `registerMultiTask`）。本变更只修自带实现，不为此新增公开 API。

**兜底写法**：若仓颉不允许在公开抽象类上声明 `internal` 抽象成员，则改为
`protected func doRegisterMulti(category!: String, tag!: String, task!: (Event) -> Event): Unit`
抽象成员 + `Dispatcher` 内具体的 `internal func registerMultiTask(...)` 转发到它，两个
dispatcher 改为实现 `doRegisterMulti`。两种形态下调用点（两个流程类）与语义都不变，实施时
在此回填实际采用的写法。

> **实施回填（0.6）**：直接声明 `internal func registerMultiTask(...): Unit`（无实现）时，
> 编译器报 `error: the visibility of an 'abstract' function must be 'public' or 'protected'`，
> 因此实际采用上述**兜底写法**：
> - `Dispatcher` 内为 `internal func registerMultiTask(...)`（有实现，转调 `doRegisterMulti`）
>   + `protected func doRegisterMulti(...)`（抽象成员）；
> - `ImmediateDispatcher.doRegisterMulti` 构造 `TaskExecutor` 后经私有 `doRegister(executor)`
>   追加（该方法为**位置形参**，不是 `doRegister(executor:)`）；
> - `AsyncDispatcher.doRegisterMulti` 在 `synchronized(mutex)` 内转调
>   `dispatcher.registerMultiTask(...)`（内部再落到 `ImmediateDispatcher.doRegisterMulti`）。
>
> 调用点仍是 `getDispatcher().registerMultiTask(...)`，`BaseFlow`/`Dispatcher` 的公开签名不变。

**Multi 事件名契约**：Multi 任务的 acceptable 事件名固定为 `EventType.Multi.toString()`，
`MultiEvent` 的 `name` 必须是同名（`MultiEvent` 构造器允许任意 `name`，不是该值时不会被本流程
接收）。该约束写入 `specs/f-egraph-flow-script` 与测试。

#### 明确不选

| 备选 | 不选的理由 |
|---|---|
| B. 构造器增加 `startEvent` 参数，构造时直接注册 | 破坏 `ImmediateFlow(category:tag:)` 公开签名，同时要改 §5.2 的 `PublicCtor([4,4])` 与脚本契约；所有宿主调用方受影响。 |
| C. 只把注册延后到 `registerStart` | 仍命中第二条校验（Multi ≠ 开始事件）；且 Multi 在 `registerStart` 之前不可用，顺序语义变复杂。 |
| D. 在 `registerTask` 里对 `Multi` 事件名开特例 | 既把宿主内部细节塞进业务校验，也修不了缺陷 2：`registerTask` 的事件类型仍是 `Task`，`MultiEvent` 依旧匹配不上。 |

#### 影响面

- 改 5 个文件：`Dispatcher.cj`、`ImmediateDispatcher.cj`、`AsyncDispatcher.cj`、
  `ImmediateFlow.cj`、`AsyncFlow.cj`；`Flow.cj` 的 `multiEventTaskBody` 复用，本轮不改；
  `f_jit` 仅新增 `@IgnoreJitBinding` 宏（见 D10），不改公开签名。
- 旧 DSL 路径与脚本路径同时恢复可用（两者共用构造器与 dispatcher）。
- 回归用例见 `tasks.md` 0.6、`tasks.md` 5.2/5.3、`specs/f-egraph-flow-script/spec.md` 的
  「流程构造可用」与 `specs/f-egraph-test-coverage/spec.md` 的「构造期 Multi 注册与扇出」。

### D10 · `@IgnoreJitBinding`：把宿主专用成员排除出 `@JitBind`

**动机**：`ClosureTask` 需要保留 `public static initCompiler(compiler: Compiler)` 作为宿主注入面
（自定义 `Compiler`），但 `@JitBind` 会把所有 `public static` 展开进脚本静态名空间。
需要一个显式的「成员级退出」标记，而不是把 API 降级为 `internal`。

**机制**（与 `f_bean` 的 `@Constructor` / `@BeanParam` 同一套子宏消息协议）：

1. 新增 `f_jit/src/macros/IgnoreJitBinding.cj`：

```cangjie
public macro IgnoreJitBinding(input: Tokens): Tokens {
    assertParentContext('JitBind')            // 只能出现在 @JitBind 声明内部
    let name = declaredName(input)             // FuncDecl / VarDecl / PropDecl 的标识符
    setItem('member', name)                    // 向父宏发消息
    input                                      // 声明本身保留，交给 @JitBind 处理
}
```

2. `JitBind.cj` 在遍历 `CompositeDecl` 成员前收集忽略名单，并写入 `JitBindings`：

```cangjie
let ignored = HashSet<String>()
for (msg in getChildMessages('IgnoreJitBinding')) {
    ignored.add(msg.getString('member'))
}
```

`JitBindings` 增加 `ignored: Array<String> = Array<String>()`（构造参数，默认空，向后兼容）。

3. **反射注册侧同样跳过**（`ReflectRegistrar`）：`registerType<T>()` 会遍历反射成员并为
   每个 `staticFunctions` / `staticVariables` 生成 `PredefinedFunction`，即使宏没给绑定也会
   退回反射包装。因此 `ReflectRegistrar.registerType` 在收集**实例方法与字段、静态函数、
   静态只读字段/属性、`static var`/`static mut prop`** 时，凡名字在 `bindings.ignored` 中
   一律跳过（不再生成任何绑定）。这样「忽略」是**真不登记**，而不是「不用类型化绑定」。

成员遍历的每个分支增加「成员名不在 `ignored` 中」的守卫（方法/字段/属性/静态成员）。
`init` 不是属性宏的合法落点，构造器不参与忽略。

**语义边界**：

- 按**成员名**忽略，同名重载全部跳过（`initCompiler` 无重载，当前无歧义）；
- 只对 `@JitBind` 直接修饰的类/接口体内的成员生效；子宏先展开并投递消息，父宏再读取；
- 用在 `@JitBind` 之外时由 `assertParentContext` 产生编译错误，这是刻意行为；
- 被忽略的成员仍可按原语义在仓颉侧调用，只是不进注册表；
- 不改 `@JitBind` 对未标注成员的展开结果，也不改变其它公开 API。

**测试**（`f_jit/src/JitBind_test.cj`）：

1. 合法：`@JitBind` 类中给一个 `public static func` 标 `@IgnoreJitBinding`，
   `enrollOf` 的 `statics` 不含它、其余静态成员仍在；
2. 合法：实例方法与字段同理；
3. 合法：`registerType<T>()` 后，被忽略的静态/实例成员**也不出现在反射自动包装里**
   （脚本调用编译失败）；
4. 非法：`@IgnoreJitBinding` 用在未被 `@JitBind` 修饰的类里，编译失败且错误信息含父上下文；
5. 反向：不标注的同类成员仍被登记（防止忽略名单误伤）。

**代价**：`f_jit` 改动 4 个文件——新增 `macros/IgnoreJitBinding.cj`，修改 `macros/JitBind.cj`、
`base/JitBindings.cj`（`ignored` 字段）、`ReflectRegistrar.cj`（反射侧跳过），另加宏与反射
两层测试；`f_jit` 的 `cjpm test` 需全绿。

> **实施回填（0.7）**：
> 1. `JitBindings.ignored` 在 `withOverrides` 里与显式覆盖的名单**取并集**（去重、保序）：
>    `registerType<T>(bindings:)` 若也声明了忽略项，反射侧同样生效。
> 2. `JitBind` 在两处 `JitBindings(...)`（类 / 接口）都下发 `ignored: [...]`；宏侧成员跳过
>    依赖子宏消息，与 `unwrapMemberMacro` 的穿透配合——`@IgnoreJitBinding` 返回原声明时，
>    成员可能已不在 `MacroExpandDecl` 形态，两种形态都要能取到名字。
> 3. `ReflectRegistrar` 的跳过点共 6 处：实例字段、实例属性、实例方法、静态字段、静态属性、
>    静态函数；属性按源面名与归一后的 `propName` 各判一次（SDK 对 mut prop 报首字母大写）。
>    **父类并入口径同样跳过**（`mergeAncestorFields` / `mergeAncestorMethods` 用父类
>    `enrollOf` 的 `ignored`），否则子类注册会把父类被忽略的成员按反射重新加回来。
> 4. 负向用例（`@IgnoreJitBinding` 用在 `@JitBind` 之外）不能放进 `cjpm test`：`f_jit` 的
>    `include = ["src"]`，故意失败的文件会一起编进包。实测改用独立 cjpm 工程
>    `cjpm build`，错误信息为
>    `The macro call 'IgnoreJitBinding' should with the surround code contains a call 'JitBind'`，
>    与 `assertParentContext('JitBind')` 的预期一致。
> 5. 红→绿的关键一条：宏侧不登记后，反射侧仍会为 `public static func` 生成回退包装，
>    脚本 `{ => hostOnly() }` 照样编译成功——**只改宏不够**，`ReflectRegistrar` 的跳过是必需项。

### D11 · 开始事件名的共享读取（`start` 路径修复）

**问题**：`ImmediateFlow`/`AsyncFlow` 的 `startName` 是**实例字段**（`ImmediateFlow.cj:80`、
`AsyncFlow.cj:92`）。脚本调用 `registerStart("created")` 时写的是脚本内 `new` 的实例；宿主在
`initialize()` 之后通常只能再 `ImmediateFlow(category: c, tag: "v1")` 构造一个新实例来启动，
其 `startName == ""`，`start()` 于是发出 `StartEvent(name: "")`，dispatcher 按
`(category, tag, name)` 精确匹配必然落空（`No executor found for event`）。旧 DSL 路径同样
无法启动——这是既有缺陷，只是此前没有消费者。

**决策**：把开始事件名落到 **dispatcher 共享侧**，`start()` 在本地 `startName` 为空时回退读取。

1. `Dispatcher` 增 `internal func startEventName(category!: String, tag!: String): ?String`；
2. `ImmediateDispatcher.registerStart` 在登记后记录 `(category, tag) -> eventName`；
   方法实现按该表查询；
3. `AsyncDispatcher` 在 `synchronized(mutex)` 内转调；
4. `ImmediateFlow.start` / `AsyncFlow.start`：`name = if (startName.size > 0) { startName }
   else { getDispatcher().startEventName(category: category, tag: tag) ?? "" }`。

**边界**：公开签名不变；显式在本地实例上调用过 `registerStart` 的路径行为不变；只影响原本
必然失败的「宿主新实例启动已注册流程」路径。`removeExceptCurrentTag`/`remove` 的语义不变。

**测试**：`FlowInitializer_test` 的 5 条启动用例（同步/异步、按 category/tag 启动、旧 tag 清理、
共享编译器）转绿；`Flow_test` 增「本地 registerStart 后 start 仍用本地名」回归用例。

> **实施回填（3.5）**：
> 1. 与 D9 同因，仓颉不允许 `internal` 抽象成员，实际为
>    `internal func startEventName(...)`（转发）+ `protected func doStartEventName(...)`（抽象）。
> 2. `ImmediateDispatcher` 的记录表用嵌套 `HashMap<String, HashMap<String, String>>`
>    （`category -> tag -> 名称`），在 `registerStart` 的 `doRegister` 之后写入；
>    查询未命中返回 `None`，`start` 回退为 `?? ""`。
> 3. `ImmediateFlow.getDispatcher()` 由隐式 `Unit` 改为返回 `ImmediateDispatcher`
>    （`private`，不影响公开签名），供 `start` 读取共享名；`start` 的 dispatcher 调用仍是
>    原来的 `dispatchers[this]`，不额外创建实例。
> 4. **顺带修复两处既有异步缺陷**（不修则异步流程 `start` 之后任何登记/清理都会自锁，
>    3.5 的异步用例无法收尾）：
>    - `AsyncDispatcher.getEvent()` 原先在 `synchronized(mutex)` 内调用阻塞的
>      `LinkedBlockingQueue.remove()`：dispatch 线程取空队列后长期持锁阻塞，后续
>      `register*`/`removeIf` 永久等锁。改为不加锁直接取队列（队列自身线程安全，
>      `getExecutors` 仍在锁内读 map）。
>    - `AsyncFlow.doRemove` 原先在 `removeIf` 谓词内 `flows.remove(flow)`：下一个事件的
>      重建 `AsyncFlow` 发现不在 `flows` 中，于是重新登记 Multi，经
>      `AsyncDispatcher.mutex` 自锁。改为在 `removeIf` 结束后统一删除。
>    两条都是宿主内部实现修正，公开签名与 D9 的语义不变。

### D12 · 重复任务登记显式拒绝

`ImmediateDispatcher.registerTask` 原先走私有 `doRegister(executor)`（纯追加、无重复校验），
同一 `(category, tag, eventName)` 重复登记会静默追加第二个执行器，导致同一事件被执行两次；
而 `registerStart`/`registerEnd`/`registerError` 走 `doRegister(name, executor)`，重复时抛
`GraphException`。这与 §6.2 第 3 条「同一事件只能注册一个执行器」不一致。

**决策**：`registerTask` 改用带校验的 `doRegister('TaskExecutor', executor)`，重复登记抛
`GraphException`。`registerMultiTask` 保持追加（Multi 由构造期幂等守卫保证只登记一次，
且它不是业务任务）；公开签名不变。

**测试**：`ImmediateDispatcher_test.duplicateTaskIsRejected` 与
`AsyncDispatcher_test.duplicateTaskIsRejected` 断言重复登记抛异常。

## 5. 宿主类型注册表

`JitHostRegistry.configure(compiler)` 在**执行任何脚本之前**完成下表注册。手工与宏两条路径混用，
但每个类型只走一条：

| # | 类型 | 注册 API | 目的 |
|---|---|---|---|
| 1 | `Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent`、`MultiEvent`、`DummyEvent` | `registerClass(ClassDescriptor)` + `HostFieldTable.register` | 事件类型与字段读取；供脚本形参、`FlowEventFactory` 返回值使用 |
| 2 | `Task` | `registerInterface<Task>()`（宏） | 接口方法绑定与 `o is Task` 谓词 |
| 3 | `Emitter`、`BaseFlow` | `registerClass(ClassDescriptor(isInterface = true))` | 接口名解析与脚本可调用的编排方法 |
| 4 | `ImmediateFlow`、`AsyncFlow` | `registerClass(ClassDescriptor)` | 脚本实例化与 `register*` 调用 |
| 5 | `ClosureTask` | `registerType<ClosureTask>()`（宏） | 静态 `compile` 与实例成员绑定 |
| 6 | `FlowEventFactory` | `registerType<FlowEventFactory>()`（宏） | 脚本构造/读取事件载荷 |

顺序要求：先手工类、后宏注册。原因只是可读性；`registerClass` 与 `registerType` 互不依赖，
但宏观上保持「基础类型 → 接口 → 实现 → 工具类」的阅读顺序。

### 5.1 命名口径

所有类型（手工与宏）在注册表里都用**短名**：`Event`、`BaseFlow`、`ImmediateFlow`、
`ClosureTask`……

- 手工描述符由我们直接给 `name`，写短名即可；
- `registerType<T>()` / `registerInterface<I>()` 用 `TypeInfo.of<T>().name`，同样是短名
  ——仓库既有用例就是靠这一口径工作的：`registerType<ReflectUser>()` 之后脚本里写
  `{ u: ReflectUser => ... }` 能解析（`f_jit/src/CompilerRegistration_test.cj:158-163`），
  `JitBind_test.cj:272` 同理。

短名是硬要求：脚本里的类型注解（`{ e: Event => ... }`、`let flow: BaseFlow = ...`）按源码
文本查表，`ClassRegistryView.classOf` 是**精确匹配**（`compiler/ClassRegistryView.cj:57-64`）；
运行期 14 实参校验也用 `ClassTypeInfo.of(o).name`（短名）比对（`CallMarshal.cj:93-113`）；
宏生成的 `retName` 同样取源码里的首 token（`JitBind.cj:416-422`）。因此
`ClosureTask.compile` 的 `retName`（`ClosureTask`）与 `registerType` 的注册名一致，
脚本对返回值做成员访问也不会踩名字错位。

### 5.2 手工注册的成员面（金线）

下表是 `JitHostRegistry` 必须逐条构造的成员，也是测试断言的**金线**（§9.3）。

**字段（事件谱系，索引全局一致）**

| index | 字段 | 类型码 | mutable | `accepts` |
|---|---|---|---|---|
| 0 | `category` | 4 (`STRING`) | false | `{ o => o is Event }` |
| 1 | `tag` | 4 (`STRING`) | false | 同上 |
| 2 | `name` | 4 (`STRING`) | false | 同上 |
| 3 | `session` | 4 (`STRING`) | false | 同上 |

- 8 个事件描述符的 `fields` **都**包含这 4 项（前端不做继承上溯，`ClassRegistryView.cj:44-49`），
  索引相同；`HostFieldTable` 只注册一次，`accepts` 用基类判定，子类实例天然命中。
- `DataEvent.data` 是 `Any`，不进描述符：`PublicField` 的类型码合法集只到 `14`
  （`isRegistrationLocalType`，`base/ClassRegistration.cj:27-30`），`Any`（15）直接非法；
  脚本面用 `flowDataOf` 读取。
- `eventType` 不登记：脚本不需要，且枚举值的类型码语义对脚本无价值。
- 父链（`parents`）：`Event` 为空；`DataEvent → ["Event"]`；`StartEvent`/`EndEvent`/
  `TaskEvent`/`ErrorEvent`/`MultiEvent → ["DataEvent", "Event"]`；`DummyEvent → ["Event"]`
  （它直接继承 `Event`）。
  不把未注册的 `Object` 写进父链（`isSameOrSubclass` 只做名字比较，写进去只会让
  `as Object` 走到「缺少 `$as$Object`」的编译错误）。

**方法**

| 类型 | 脚本名 | `paramTypes` | `retType` | 备注 |
|---|---|---|---|---|
| `Event` | `toString` | `[14]` | 4 | 诊断用；其余事件类不登记方法 |
| `Task`（宏） | `name` / `acceptableEvents` / `producingEvents` / `exec` | `[14]` / `[14]` / `[14]` / `[14,14]` | 4 / 14 / 14 / 14 | 由 `@JitBind` 生成；两个事件列表属性返回 14，不进脚本契约 |
| `BaseFlow` | `canBeRemoved` | `[14]` | 3 | |
| `BaseFlow` | `remove` | `[14]` | 3 | |
| `BaseFlow` | `removeExceptCurrentTag` | `[14]` | 3 | 脚本末行 |
| `BaseFlow` | `registerStart` | `[14,4]` | 3 | |
| `BaseFlow` | `registerEnd` | `[14]` | 3 | |
| `BaseFlow` | `registerError` | `[14]` | 3 | |
| `BaseFlow` | `registerTask` | `[14,14]` | 3 | **只登记 `Task` 重载** |
| `ImmediateFlow` | 同上 7 个 | 同上 | 同上 | 绑定名用 `ImmediateFlow.<name>` |
| `AsyncFlow` | 同上 7 个 | 同上 | 同上 | 绑定名用 `AsyncFlow.<name>` |

不登记：`emit`（`Any` 形参）、`start`（`Any` 形参）、`registerTask(eventName, closure)`
（函数类型形参，脚本契约不需要）、`dependencied`（容器属性）、`registerMultiEventTask` /
`registerTaskBy*Flow`（泛型）、`initDispatcher`（`Duration` 形参 + 宿主职责）。

**构造器**

| 类型 | `params` | 适配器 |
|---|---|---|
| `ImmediateFlow` | `[4, 4]` | `ImmediateFlow(category: a0 as String, tag: a1 as String)` |
| `AsyncFlow` | `[4, 4]` | `AsyncFlow(category: a0 as String, tag: a1 as String)` |

`PublicCtor.adapter` 收 `Array<Any>` 并把结果作为 `Any` 返回（`base/ClassRegistration.cj:122-147`）。
上表的 `a0 as String` 是示意：`Any` 上的 `as` 返回 `?String`，实现里用
`match (args[0] as String) { case Some(v) => v; case None => throw GraphException(...) }`
或 `??` 兜底，不要直接强转。

**绑定名唯一性**

`PublicMethod.bind.name` 是预定义函数表的键，必须全表唯一。手工路径用
`"<类型短名>.<方法名>"`；因为每个类型只登记一份 `registerTask`，不会出现同名绑定。

### 5.3 使用约束

- `Event.data` 是 `Any`，脚本不可读；改用 `flowDataOf(e)`。
- 手工注册不合成 `$as$<C>`：脚本对事件/流程类型**不要写 `is` / `as`**
  （会得到「缺少转型判定函数」的编译错误）。事件分支用 `e.name` 判别。
- 手工类之间没有运行期 `is C` 语义。`parents` 只参与静态子类型判定；即便判为相容，
  `as` 仍会因注册期没有合成 `$as$<C>` 而在编译期失败（本契约不使用 `as`）。父链仍按真实关系填写，
  便于后续扩展与诊断。
- `AsyncFlow` 的全局 dispatcher 仍由宿主显式 `AsyncFlow.initDispatcher(...)` 初始化；
  `FlowInitializer` **不**隐式调用，避免覆盖宿主配置。

## 6. FlowLoader 脚本契约

### 6.1 可用语言子集

脚本使用 f_jit 方言（`f_jit/doc/design-m1.md` 附 A、`design-m2.md` 附 A）：

**可用**：`let`/`var`、赋值、`if`/`else`（语句与表达式）、`while`、`for-in`、闭包、字符串字面量与插值、整数/布尔字面量、列表字面量、构造器调用 `C(a, b)`、成员调用 `x.m(a)`、静态函数裸名调用、`return`。

**不可用**：类/接口/枚举声明、`import`、命名实参（`category: ...`）、`null`、`try/catch`、数组 `Array<T>` 值、`Any` 形参/字段、宏、`Event` 家族构造器直接调用。

### 6.2 脚本骨架

```cangjie
let flow = ImmediateFlow("order", "v1")   // 或 AsyncFlow("order", "v1")
flow.registerStart("created")
flow.registerEnd()
flow.registerError()

let t = compile("validate", ["created"], ["validated"], "<任务体源码>")
flow.registerTask(t)

flow.removeExceptCurrentTag()             // 对应旧编译器的最后一步
```

约束：

1. `registerStart` 必须在第一个 `registerTask` 之前；
2. 第一个注册的任务的 `acceptableEvents` 必须包含开始事件名，否则 `ImmediateFlow`/`AsyncFlow` 的 `registerTask` 抛 `GraphException`（`ImmediateFlow.cj:92-101`）；
3. 同一事件只能注册一个执行器；重复注册抛 `GraphException`；
4. 脚本只使用 `registerTask(task: Task)` 重载。手工注册**只登记这一个重载**，闭包重载
   （`registerTask(eventName: String, task: (Event) -> Event)`）因函数类型形参不进入描述符，
   脚本调用它会在编译期报「未注册方法」；
5. 脚本末行必须是 `flow.removeExceptCurrentTag()`，承接旧 DSL 自动清理同 `category` 旧 `tag` 的行为；
6. 异步脚本的前提是宿主已调用 `AsyncFlow.initDispatcher(...)`（该静态不进脚本名空间）；
7. 脚本不得对事件/流程类型使用 `is` / `as`（手工注册不合成 `$as$`，见 §5.3）。

### 6.3 执行与错误语义

- **同步执行**：`initialize()` 顺序执行每个脚本，执行完一个再执行下一个；
- **失败快停**：任一脚本编译失败或运行期抛错，立即终止初始化，后续脚本不执行；已完成注册不回滚（启动期失败，进程不应继续提供服务）；
- **空脚本**：抛 `GraphException`；
- **重复初始化**：再次调用 `initialize()` 会重复注册并抛 `GraphException`（与现有 dispatcher 语义一致），本变更不引入幂等层。

### 6.4 原 DSL → 脚本映射

| 旧 DSL 结构 | 新脚本语句 | 说明 |
|---|---|---|
| `async(c, t)` | `let flow = AsyncFlow("c", "t")` | 位置参数；`c`/`t` 是字符串 |
| `immediate(c, t)` | `let flow = ImmediateFlow("c", "t")` | 同上 |
| `: 'Start' =>` | `flow.registerStart("Start")` | 旧语法强制开始事件 |
| 隐式 `registerEnd()` | `flow.registerEnd()` | 显式写出 |
| 隐式 `registerError()` | `flow.registerError()` | 显式写出 |
| `task |> { 'out' => { ... } }` | `let t = compile("task", ["<accept>"], ["out"], "<exec>"); flow.registerTask(t)` | `<accept>` 是该任务在此位置接受的事件 |
| 嵌套任务 | 按深度优先先序展开为连续语句 | 顺序 = 注册顺序 |
| `END` | 无对应语句 | `EndExecutor` 已由 `registerEnd()` 注册；任务返回 `flowEndEvent(...)` 即结束 |
| 旧编译器末尾 `flow.removeExceptCurrentTag()` | 脚本末行显式调用 | 清理同 category 旧 tag |
| 旧编译期的「可接受事件/产出事件」校验 | **不再自动校验** | 由脚本作者保证；错误在初始化期暴露 |

`compile` 的 `acceptableEvents` 对应旧 DSL 中任务节点入边的事件名，`producingEvents` 对应任务声明的产出事件（仅元数据，供 `Task` 契约与诊断使用）。

### 6.5 完整迁移示例

旧 DSL：

```
immediate(order, v1): 'created' => {
    validate |> {
        'validated' => { pay |> {END} }
    }
}
```

新脚本（`FlowLoader.load()` 的一个元素）：

```cangjie
let flow = ImmediateFlow("order", "v1")
flow.registerStart("created")
flow.registerEnd()
flow.registerError()

let validate = compile("validate", ["created"], ["validated"],
    "flowTaskEvent(\"order\", \"v1\", \"validated\", flowDataOf(e))")
flow.registerTask(validate)

let pay = compile("pay", ["validated"], ["End"], "flowEndEvent(\"order\", \"v1\", flowDataOf(e))")
flow.registerTask(pay)

flow.removeExceptCurrentTag()
```

注意：

- 字符串里的双引号需要按 f_jit 的字符串转义规则书写；也可用 `'''...'''` 降低转义噪音；
- `validate` 的 `producingEvents` 与实际返回的事件名应保持一致（元数据一致性由测试与评审保证）；
- 多分支任务可在 `exec` 里使用 f_jit 的 `if` 表达式（两分支类型必须同为 `Event`/`14`）；示例保持单分支以突出映射关系；
- 旧 DSL 的 `task` 名字不再用于 IoC 查找，只是 `ClosureTask.name`。

## 7. 组件设计

### 7.1 `ClosureTask`

文件：`f_egraph/src/base/ClosureTask.cj`

```cangjie
@JitBind
public class ClosureTask <: Task {
    private let name_: String
    private let acceptable_: Array<String>
    private let producing_: Array<String>
    private let body_: (Event) -> Event

    public init(name: String, acceptableEvents: Array<String>,
                producingEvents: Array<String>, body: (Event) -> Event)

    public static func initCompiler(compiler: Compiler): Unit
    public static func compile(name: String,
                               acceptableEvents: ArrayList<Any>,
                               producingEvents: ArrayList<Any>,
                               exec: String): ClosureTask

    public prop name: String
    public prop acceptableEvents: Array<String>
    public prop producingEvents: Array<String>
    public func exec(e: Event): Event
}
```

设计要点：

- `compile` 的列表形参用 `ArrayList<Any>`：f_jit 的 LIST 字面量类型码是 `10`，但**运行时形态
  恒为 `ArrayList<Any>`**（`IterTable.cj:256` `makeRuntimeList()`），且仓颉泛型不协变——
  `ArrayList<Any> as ArrayList<String>` 返回 `None`，宏生成的
  `match (args[i] as ArrayList<String>)` 必然落 `typeMismatch`（实测 `JitException(code=21)`）。
  因此形参声明为 `ArrayList<Any>`，`compile` 内部逐元素 `is String` 校验，非字符串抛
  `GraphException`；脚本仍可直接写 `["created"]` 字面量。
- `compile` 校验：`name` 去空白非空、两个事件列表非空、`exec` 去空白非空；不满足抛 `GraphException`。
- `compile` 失败时不吞异常；`SourceCompileException` 的 `site`/`message` 原样保留，便于定位脚本行。
- `exec` 每次调用 `fn.call<Event>([e])`；`JitFunction` 由 `ClosureTask` 长期持有，不提供 `close()`（任务与流程同生命周期）。
- 构造器的形参含函数类型 `(Event) -> Event`，而宏对函数类型一律落 `14` 并生成
  `as (Event) -> Event`（`JitBind.cj:392-413`、`:194-209`）。这是本设计唯一可能触发
  「宏展开不合法」的地方，处理规则：
  - **首选**：保留单个公有构造器；任务 0.4 验证 `cjpm build`。
  - **回退**：若该展开不合法，把带函数类型的构造器改为**包内可见**（去掉 `public`，供测试与
    同包宿主注入闭包），并新增跨包入口
    `public init(name: String, acceptableEvents: ArrayList<String>,
    producingEvents: ArrayList<String>, fn: JitFunction)`——`JitFunction` 是宏可用的宿主类（14），
    展开安全。两种形态下 `compile` 的签名与脚本契约都不变。
  - 该结论只影响构造器的可见性，**不影响** `ClosureTask` 继续标注 `@JitBind`
    （`compile` 与实例成员仍需宏绑定）。
- 构造器是公开的（或按上面的回退方案），宏会把它绑定为构造器项，但脚本不会使用（脚本只走 `compile`）。

### 7.2 `FlowEventFactory`

文件：`f_egraph/src/base/FlowEventFactory.cj`

```cangjie
@JitBind
public class FlowEventFactory {
    private init() {}

    public static func flowTaskEvent(category: String, tag: String, name: String, data: String): Event
    public static func flowEndEvent(category: String, tag: String, data: String): Event
    public static func flowErrorEvent(category: String, tag: String, message: String): Event
    public static func flowDummyEvent(): Event
    public static func flowDataOf(event: Event): String
}
```

- `flowTaskEvent` → `TaskEvent(category:..., tag:..., name:..., data: data)`；
- `flowEndEvent` → `EndEvent(...)`；
- `flowErrorEvent` → `ErrorEvent(category:..., tag:..., message:...)`；
- `flowDummyEvent` → `DummyEvent.instance`；
- `flowDataOf` → `event is DataEvent` 且 `data is String` 时返回该字符串，否则返回 `""`。

`FlowEventFactory` 不提供公共实例构造器（`private init`）；`@JitBind` 只为静态成员生成绑定。

### 7.3 `FlowInitializer` 与脚本执行器

`f_egraph/src/egraph.cj`：

```cangjie
public interface FlowInitializer <: Initializer {
    prop name: String { get() { "fountain::f_egraph" } }
    prop dependencies: Array<String> { get() { ["fountain::f_bean"] } }

    func initialize(): Unit {
        let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
        JitHostRegistry.configure(compiler)
        ClosureTask.initCompiler(compiler)
        for (script in lookup<FlowLoader>().load()) {
            FlowScriptRunner.run(compiler, script)
        }
    }
}
```

内部执行器（放在**根包** `f_egraph/src/FlowScriptRunner.cj`：`loader` 子包的 `internal` 对根包
不可见，根包内不写 `public` 即可包内可见）：

```cangjie
class FlowScriptRunner {
    static func run(compiler: Compiler, script: String): Unit {
        if (isBlank(script)) {
            throw GraphException("flow script must not be blank")
        }
        let source = "{ =>\n" + script + "\n}"
        compiler.compile(source).call<Unit>([])
    }
}
```

`JitHostRegistry` 是 `public class`（`f_egraph/src/base/JitHostRegistry.cj`），集中注册逻辑：

```cangjie
public class JitHostRegistry {
    private init() {}

    public static func configure(compiler: Compiler): Unit {
        JitHostRegistry.registerEventFields()     // HostFieldTable：4 条访问器（只注册一次）
        for (desc in JitHostRegistry.eventDescriptors()) {
            compiler.registerClass(desc)          // 8 个事件类
        }
        compiler.registerClass(JitHostRegistry.emitterDescriptor())
        compiler.registerClass(JitHostRegistry.baseFlowDescriptor())
        compiler.registerClass(JitHostRegistry.immediateFlowDescriptor())
        compiler.registerClass(JitHostRegistry.asyncFlowDescriptor())
        compiler.registerInterface<Task>()        // 宏注册
        compiler.registerType<ClosureTask>()      // 宏注册（静态 compile 入全局名空间）
        compiler.registerType<FlowEventFactory>() // 宏注册（5 个 flow* 入全局名空间）
    }

    // 以下均为 internal static（同包测试可直接断言），不进入公开 API
    internal static func eventDescriptors(): Array<ClassDescriptor>
    internal static func emitterDescriptor(): ClassDescriptor
    internal static func baseFlowDescriptor(): ClassDescriptor
    internal static func immediateFlowDescriptor(): ClassDescriptor
    internal static func asyncFlowDescriptor(): ClassDescriptor
    internal static func registerEventFields(): Unit
}
```

职责边界：

- **只描述、不缓存**：每次 `configure` 都新建描述符；`ClassDescriptor` 自带数组防御性拷贝
  （`base/ClassRegistration.cj:155-189`），可以安全地跨调用复用同一常量工厂。
- **`HostFieldTable` 是进程级全局表**（`runtime/HostField.cj:68-119`），重复 `configure`
  会向同一 index 追加等价访问器。因为 `accepts` 与 getter 语义一致，`find` 取第一条即可，
  功能不受影响；测试若在意表大小，可在用例前后调用 `resetForTest()`。
- **扩展点**：应用可以创建自己的 `Compiler`，先 `JitHostRegistry.configure`，再注册额外
  函数/类型，最后 `ClosureTask.initCompiler` 注入。公开它是因为 `base` 包与根包
  （`egraph.cj`）跨包调用，`internal` 不可见。
- **静态名门禁**：`configure` 结束时不主动校验，由测试断言（见 §9.3），避免生产路径为
  断言付出开销。

### 7.4 注解清单与预期 WARNING

只有三个类型仍标注 `@JitBind`：

| 文件 | 标注对象 | 预期 WARNING |
|---|---|---|
| `Task.cj` | `Task`（接口） | 无（无泛型方法、无 `static var`） |
| `ClosureTask.cj` | `ClosureTask` | 无（`private static let/var` 被静默忽略） |
| `FlowEventFactory.cj` | `FlowEventFactory` | 无（`private init` 静默忽略） |

`Event.cj`、`Emitter.cj`、`Flow.cj`、`ImmediateFlow.cj`、`AsyncFlow.cj` **不再有注解**，
因此不再有「泛型方法未生成绑定」这类 WARNING；原来的 `DataEvent.tryGet<T>` WARNING 随之消失。
代价是**没有编译期信号**提示成员遗漏，必须由 §9.3 的登记面金线测试承担。

**实测（3.x/4.4，已回填）**：`@JitBind` 会为每个登记生成包级
`let jitBindEnroll_<类名> = enrollOf<...>(...)`，`f_egraph` 构建共 **5 条 WARNING**，构成为：

| # | 来源 | 位置 |
|---|---|---|
| 1 | `jitBindEnroll_Task` 未使用 | `Task.cj` 的 `@JitBind` |
| 2 | `jitBindEnroll_ClosureTask` 未使用 | `ClosureTask.cj` 的 `@JitBind` |
| 3 | `jitBindEnroll_FlowEventFactory` 未使用 | `FlowEventFactory.cj` 的 `@JitBind` |
| 4 | 宏内 `args` 未使用 | `FlowEventFactory.cj` 的 `@JitBind` 展开 |
| 5 | `TypeInfo.of` 已废弃 | `StartExecutor.cj:27`（既有告警，与本次变更无关） |

其中第 4 条只出现一次（原预期为 2 条，实测 `Task` 接口那一支不产生 `args` 告警）。
删除 `FlowDSLCompiler.cj` 后 `imports.cj` 的 `HashSet`/`LinkedList` 变成未使用导入，已一并移除
（`JitHostRegistry_test` 自行 `import std.collection.HashSet`），因此构建日志里没有新增的
unused import 告警。它们由宏展开与既有代码产生，不影响语义；
**接受并记录，不加 `-Woff`**（避免把真实告警一起压掉）。`f_jit` 侧无新增 WARNING（0 条）。

实施时仍需在构建日志中核对 `f_egraph` 与 `f_jit` 的 WARNING 条数，并在 `tasks.md` 记录实际值
（预期：`f_egraph` 5 条、`f_jit` 0 条）。

## 8. 关键调用链

```
Initializer.initialize()
  └─ FlowInitializer.initialize()
       ├─ new Compiler(CompileOptions(DummyDiagnosticsSink()))
       ├─ JitHostRegistry.configure(c)
       │    ├─ HostFieldTable.register × 4                     // category/tag/name/session
       │    ├─ c.registerClass(eventDescriptor) × 8            // 手工
       │    ├─ c.registerClass(Emitter / BaseFlow)             // 手工，isInterface = true
       │    ├─ c.registerClass(ImmediateFlow / AsyncFlow)      // 手工，含 (String,String) 构造器
       │    ├─ c.registerInterface<Task>()                     // 宏
       │    └─ c.registerType<ClosureTask / FlowEventFactory>() // 宏
       ├─ ClosureTask.initCompiler(c)
       └─ for script in FlowLoader.load():
            ├─ FlowScriptRunner.run(c, script)
            │    ├─ wrap "{ => ... }"                  // 不追加哨兵；末句须为 Unit
            │    ├─ c.compile(source)                  // 命中 CompileCache（源码相同）
            │    └─ jitFn.call<Unit>([])               // 执行注册语句
            │         ├─ ImmediateFlow("c","t")         // 手工 PublicCtor → 宿主构造器
            │         ├─ flow.registerStart/End/Error()  // 手工 PublicMethod → 直接调用
            │         ├─ compile("task", [...], [...], execSrc)  // 宏静态绑定
            │         │    ├─ ClosureTask.ensureCompiler()
            │         │    └─ c.compile("{ e: Event => ... }")
            │         └─ flow.registerTask(task)        // 写入 dispatcher
            └─ 下一个脚本
```

任务运行期：

```
dispatcher.accept(event)
  └─ TaskExecutor.execute(event)
       └─ ClosureTask.exec(event)
            └─ jitFn.call<Event>([event])
                 └─ 任务体返回 TaskEvent/EndEvent/ErrorEvent/DummyEvent
```

## 9. 测试策略

### 9.1 分层

1. **纯模型测试**：事件、`EventType`、`GraphException`、`BarrierKey`、`BarrierTask`，不依赖 JIT。
2. **执行器/调度器测试**：`ImmediateExecutor` 家族、`ImmediateDispatcher`、`AsyncDispatcher`、`ConcurrentEndExecutor`。
3. **流程测试**：`ImmediateFlow`、`AsyncFlow`、`Flow` 默认方法、`Emitter`；其中包括
   **构造期 Multi 注册**（D9）：构造不抛、经 `registerMultiTask` 的 Multi 扇出、首任务约束
   不变、两个流程类各自的重复构造去重（`AsyncFlow` 依赖构造期 `flows.add`）。
4. **宏绑定测试**：断言 `Task`、`ClosureTask`、`FlowEventFactory` 的
   `JitBindSupport.enrolledOf(...)` 内容；断言 `Event`/`BaseFlow`/`ImmediateFlow`/`AsyncFlow`
   **不在**宏登记表里（防止有人回头加注解）。
5. **手工注册测试**：`JitHostRegistry` 在全新 `Compiler` 上跑完后，逐类断言描述符的
   字段/方法/构造器集合等于 §5.2 金线；再对每个成员做**端到端**调用
   （`registerStart`/`registerEnd`/`registerError`/`registerTask`/`removeExceptCurrentTag`、
   `ImmediateFlow("c","t")`、`e.name` 读取），证明「登记了也真的能调」。
6. **脚本初始化测试**：注入 `FlowLoader` 假实现，验证 `FlowInitializer.initialize()` 的注册结果、空脚本失败、编译失败传播、异步前置条件。
7. **任务测试**：`ClosureTask` 构造/属性/`exec`/`compile` 成功与失败分支；`FlowEventFactory` 全部分支。

### 9.2 全局状态隔离

`ImmediateFlow`/`AsyncFlow` 使用静态 `ConcurrentHashMap`/`ConcurrentHashSet`（`ImmediateFlow.cj:19-20`、`AsyncFlow.cj:19-23`）：

- 每个用例使用唯一 `category`（含测试名/随机后缀），结束调用 `flow.remove()`；
- `AsyncFlow.initDispatcher` 是进程级重置，所有异步用例共享一次初始化（测试入口统一调用），或在每个用例开头调用并接受旧 flow 失效；
- 断言顺序不依赖其它用例的残留状态。

### 9.3 覆盖口径

「覆盖全部公开 API」的判定：每个 `public` 声明（类/接口/枚举/结构体/构造器/方法/属性/静态成员）至少一个正向用例；每个可能抛异常的分支至少一个负向用例；`FlowDSLCompiler`/`TaskDef`/`ProducingDef` 已删除，不保留用例。

**登记面金线**（替代宏 WARNING 的门禁）：

1. 对每个手工注册类，断言描述符里的成员集合**等于** §5.2 表：
   - 方法名集合（不多不少）；
   - 字段名 + index + 类型码；
   - 构造器的 `params` 序列。
   实现方式：`JitHostRegistry` 的描述符工厂函数声明为 `internal`（不是 `public`，不扩大公开
   API），测试文件放在 `f_egraph/src/base/`（与被测包同包，仓库既有约定如
   `f_mq/src/base/*_test.cj`）；对外仍只暴露 `configure(compiler)`。
   `Compiler.snapshot()` / `classSnapshot()` 是 `protected`，`f_egraph` 读不到，不能作为断言入口。
2. 服务名门禁（端到端）：用注册后的 `Compiler` 编译并执行分别调用 `compile`、
   `flowTaskEvent`、`flowEndEvent`、`flowErrorEvent`、`flowDummyEvent`、`flowDataOf`
   的脚本，6 个调用全部成功；反向用 `initDispatcher` / `instance` 的脚本调用断言编译期失败。
   **不得**用 `registeredNames()` 判定宏静态名是否存在（它不含 `registerType` 的
   `autoFunctions`，见 D8）。
3. 端到端门禁：金线里每一个方法都要有一次真实脚本调用；只断言「描述符里有」不算通过
   （手工注册最容易出现的错误是签名写错，编译期不报、调用期才炸）。

细分清单见 `tasks.md` 的测试矩阵与 `specs/f-egraph-test-coverage/spec.md`。

## 10. 风险与缓解

> 原 R1（宏展开 `operator func ==`）、R9（宏展开函数类型形参）、R10（`registerTask` 重载被
> 按名字折叠）都已随「不改 `f_jit`」消失：前两者不再给这些类型加注解，后者改为手工只登记
> 一个重载。下表是手工注册路线的风险集合。

### R1 · 手工注册成员遗漏（高）

手工描述符是人写清单，漏一个成员**不会编译失败**，只会在脚本用到时报「未注册方法/字段」；
若漏的是构造器或字段，可能在初始化/首次读取时才暴露。

**缓解**：

1. §5.2 金线表是唯一事实来源，实现与测试都按它逐条对齐；
2. §9.3 的登记面测试断言「方法名集合、字段名+index+类型码、构造器 params」三项**完全相等**
   （不是包含关系），漏登记与多登记都会失败；
3. 每个登记项都有一次真实脚本调用（端到端门禁），签名写错同样会失败。

### R2 · 手工适配器的签名写错（高）

`PredefinedFunction.paramTypes` 与实际适配器解包顺序不一致时，编译期只看类型码，
调用期才炸（`CALL_CONTRACT` 或 `ClassCastException`）。这是手工路径最容易犯的错。

**缓解**：

1. 每个方法一个独立小工厂函数，参数序列与 §5.2 表**逐行对应**，避免复制粘贴；
2. 适配器统一用「先 `match (args[0] as C)`，再逐个 `match (args[i] as T)`」的形态，
   不做隐式转换；
3. 端到端用例用**非默认值**做断言（例如 `registerStart("created")` 后检查
   `startName` 生效），避免「参数顺序写反但值相同」漏检；
4. 重载/多方法共用适配器时，测试必须覆盖每个方法至少一次。

### R3 · `Any`/`Array` 类型映射（中）

- `Any` 不能作 `PredefinedFunction` 的形参（合法集只到 8/10–11/13/14），
  所以 `emit`/`start` 一律不进描述符；脚本用 `FlowEventFactory` 收事件载荷；
- `Array<String>` 无映射：`ClosureTask.compile` 用 `ArrayList<Any>`（LIST 运行时形态），
  内部逐元素校验 `is String`；
- `DataEvent.data` 是 `Any`，字段不登记，脚本用 `flowDataOf(e)` 读取。

**缓解**：契约写清「哪些成员不在脚本面」；测试为 `ArrayList`/`String` 提供正向用例，
并为「调用未登记成员」提供编译失败的负向断言。

### R4 · 手工描述符名必须与脚本类型注解一致（中）

脚本的类型注解按源码文本**精确匹配**注册名。手工描述符如果写成完整限定名或别名
（例如 `fountain::f_egraph.base.Event`），`{ e: Event => ... }` 会直接报「未注册的类名」。
`registerType`/`registerInterface` 走的 `TypeInfo.of<T>().name` 也是短名，两条路径必须同口径。

**缓解**：

1. 描述符名写成 `private static let` 字符串常量，便于集中检查；
2. 金线测试里真实编译 `{ e: Event => e.name }` 与 `{ => ImmediateFlow("c","t") }`，
   名字写错会在测试期立刻失败；
3. 不用 `TypeInfo.of<T>().name` 去拼手工描述符名（避免未来口径变化时静默漂移）。

### R5 · 静态名空间（低）

手工注册后脚本名空间只剩 `compile` + 5 个 `flow*`（见 D8），碰撞面比原方案小得多。
剩余风险是 `compile` 这个名字太通用，未来给其它类加 `@JitBind` 静态函数时可能撞名。

**缓解**：端到端脚本调用 `compile` + 5 个 `flow*` 各一次（不能依赖 `registeredNames()`，
见 D8）；新增静态入口统一用 `flow*` 前缀。

### R6 · 异步 dispatcher 前置条件（中）

脚本构造 `AsyncFlow` 时若宿主未调用 `initDispatcher`，构造期（D9 覆写后的
`registerMultiEventTask` 调 `getDispatcher().getOrThrow()`）即失败。这是既有语义，不是本变更引入。

**缓解**：在脚本契约与 README 明确前置条件；测试分为「已初始化」与「未初始化」两条。

### R7 · 嵌套编译的重入（中）

脚本执行本身是一次 JIT 调用，脚本内 `compile(...)` 又调用 `Compiler.compile`。`Compiler.compile` 是纯宿主侧编译、不进入执行器；`JitFunction.call` 使用全局互斥量（`JitFunction.cj:49`），同一线程重入由 f_jit 的调用上下文栈支持。

**缓解**：初始化保持单线程；测试覆盖「脚本内 compile」路径；若出现死锁，改为在 `ClosureTask.compile` 中只保存 `exec` 源码，延迟到第一次 `exec` 再编译，避开初始化期的嵌套编译（代价是首个事件多一次编译延迟）。

### R8 · 全局静态状态导致测试串扰（中）

见 §9.2。手工注册额外引入 `HostFieldTable` 这一进程级全局表（见 R11）。

### R9 · 校验能力下降（中）

旧 DSL 在编译期校验「任务是否产出某事件、是否接受某事件」；新脚本不再有该静态校验，错误推迟到初始化/运行期。

**缓解**：脚本契约明确由作者保证；`ClosureTask.compile` 校验事件列表非空；`registerTask` 保留开始事件与重复执行器校验；测试覆盖典型错误脚本的失败路径。后续如需恢复校验，可在 `ClosureTask` 注册时由宿主侧做图检查（不在本变更范围）。

### R10 · `JitFunction` 生命周期（低）

`ClosureTask` 不关闭 `JitFunction`，流程存活期间任务常驻。当前以进程生命周期为界，可接受；若未来支持热更新流程，需要引入 `close()` 与任务注销机制（不在本变更范围）。

### R11 · `HostFieldTable` 是进程级全局表（低）

手工注册的字段访问器写入 `HostFieldTable` 的静态桶（`runtime/HostField.cj:68-119`）。
多次 `JitHostRegistry.configure`（多 `Compiler`、重复初始化、测试用例）会向同一 index
追加等价访问器；`find` 取第一条 `accepts` 为真的项，功能等价但表会增长。

**缓解**：

1. `configure` 是一次性的启动期调用，正常路径只执行一次；
2. `accepts` 用基类判定 `{ o => o is Event }`，重复登记之间语义相同，不会出现「后注册覆盖前注册」；
3. 测试若需干净状态，用 `HostFieldTable.resetForTest()` 并在用例结束时复位；
4. 不在 `configure` 里做去重（会引入额外状态），保持注册逻辑纯函数化。

### R12 · `ClosureTask` 公有构造器的函数类型形参（中）

`ClosureTask` 仍是 `@JitBind` 类型，宏会为它的公有构造器生成
`match (args[3] as (Event) -> Event)`。`Any as <函数类型>` 是否被仓颉接受未在本仓库验证；
若不合法，是**编译期错误**（响亮失败，不是静默错绑）。

**缓解**：按 §7.1 的回退方案——把带函数类型的构造器降为包内可见，公有构造器改用
`JitFunction`（14 形参）。`compile` 签名与脚本契约不受影响；结论在任务 0.4 验证并回填本节。

## 11. 兼容性与边界

- **源码兼容**：`Event`/`Task`/`Flow`/`Dispatcher` 的公开签名不变；新增 `ClosureTask`、`FlowEventFactory` 为增量 API。宿主类型**不再加注解**，因此也不产生新的宏展开代码。
- **破坏性**：`FlowLoader` 语义变化；删除 `FlowDSLCompiler`/`TaskDef`/`ProducingDef`。
- **能力边界**：脚本面的任务载荷限定为 `String`；`Any` 数据、`Array<T>`、命名实参、`null`、异常捕获不可用；对事件/流程类型不能用 `is`/`as`（§5.3、§6.2）。
- **平台**：`f_jit` 的字节码与解释器跨平台；机器码仅 Linux x86_64/aarch64，其它平台自动退解释器（`f_jit` README §4），`f_egraph` 不感知差异。
- **初始化顺序**：`FlowInitializer.dependencies` 仍为 `["fountain::f_bean"]`；`f_jit` 是库依赖而非 `Initializer`，无需加入。

## 12. 假设与开放项

1. **假设**：`@JitBind` 与 `JitBindSupport` 可在 `base` 包的 `imports.cj` 中集中导入并对该包所有文件生效（与现有集中导入风格一致）。若仓颉要求逐文件导入，则在 `Task.cj`、`ClosureTask.cj`、`FlowEventFactory.cj` 三个文件重复导入，语义不变。
   > **实测（0.4）**：**宏导入是文件级的**——`imports.cj` 里的 `import fountain::f_jit.macros.*`
   > 对 `Task.cj` 不可见（报 `undeclared identifier 'JitBind'`），且该行本身被报 unused。
   > 因此改为在 `Task.cj`（以及后续 `ClosureTask.cj`、`FlowEventFactory.cj`）各自
   > `import fountain::f_jit.macros.*`，并删除 `imports.cj` 里的宏导入。其余
   > `internal import`（普通类型）仍是包级集中导入，语义不变。
2. **假设**：`FlowLoader` 的实现方能够提供每个任务的 `exec` 源码；若只能提供任务名，则无法使用 `ClosureTask`，需要额外的宿主 `Task` 注册通道（不在本变更范围）。
3. **待验证**（均在 `f_egraph` 侧，不涉及改 `f_jit`）：
   - ~~`registerClass` 描述符 + `HostFieldTable` 能否让脚本读到 `e.name`/`e.category`/`e.tag`~~
     → **已确认（0.3）**：`{ e: Event => e.name }` 对 `EndEvent` 返回 `"End"`
     （`JitHostRegistry_test.scriptReadsEventName`）。
   - ~~手工构造的 `PublicCtor` 能否让脚本 `ImmediateFlow("c","t")` 成功
     （0.3 被既有构造缺陷阻塞，按 D9 修复后复验）~~ → **已确认（0.3，D9 修复后复验）**：
     脚本构造 `ImmediateFlow` 并调用 `registerStart("created")` 后，宿主注册任务并
     `start("go")` 能拿到结束事件（`JitHostRegistry_test.scriptConstructsImmediateFlowAndRegistersStart`）。
   - `Task` 的 `@JitBind` + `registerInterface<Task>()` 是否如预期无 WARNING；
   - `ClosureTask.compile` 的 `ArrayList<Any>` 形参可由列表字面量直接匹配（实测：
     `ArrayList<String>` 会因泛型不协变落 `typeMismatch`，故固定为 `ArrayList<Any>` + 逐元素校验）；
   - `ClosureTask` 公有构造器的函数类型形参能否被宏展开成合法的 `as (Event) -> Event`
     （不合法则按 §7.1 的回退方案调整构造器可见性）。
   `ImmediateFlow.registerTask` 的重载收敛已不再是风险点（手工只登记 `Task` 重载）。
4. **待定**：`FlowEventFactory` 是否应扩展非 `String` 载荷（例如通过宿主注册的转换函数）。当前按最小面收敛为 `String`。
