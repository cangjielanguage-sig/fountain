# Tasks

> 实施遵循 TDD：先写失败用例，再实现。每个任务完成即独立提交（遵循仓库「有单元测试后再提交」约定）。
> **分支**：沿用现有 `feature/f_egraph`，**不新建** `feature/f-egraph-jit-flow-init`；开工前 `git pull` 同步远程。
> **合并**：本变更**不自动合并**，也不自动删除分支。全部验收通过后由用户确认，再按仓库流程
> `git merge --no-ff` 合回 `sts/1.3.x`。
> **边界**：`f_jit` 仅允许新增 `@IgnoreJitBinding` 宏及 `@JitBind` 的忽略名单收集（设计 D10）；
> 不做命名形参 / `operator func` / 函数类型形参的宏修正，也不新增其它注册 API。

## 0. 前置验证与骨架

- [x] 0.1 确认当前 worktree 分支为 `feature/f_egraph`（`git branch --show-current`），记录基线：
  `f_jit` 与 `f_egraph` 的 `cjpm build` / `cjpm test` 均通过。**不做 `git checkout -b`**。
  > 基线实测：`f_egraph` build 通过、test 全绿（0 用例）；`f_jit` build 通过，test 1136/1137，
  > 唯一失败为既有性能用例 `PerfOverride_test.overrideBeatsReflectionEndToEnd`（与本次变更无关）。
- [x] 0.2 在 `f_egraph/cjpm.toml` 增加 `"fountain::f_jit" = {path = "../f_jit"}`；在
  `f_egraph/src/base/imports.cj` 增加 JIT 门面 / 注册协议 / `HostFieldTable` / `macros.*` 导入；
  根包（`egraph.cj`、`FlowScriptRunner.cj`）按需自行导入；`cjpm build` 通过。
  > 实测：`macros.*` 只能用普通 `import`，`internal import` 会报「不允许在包中再导出宏包」。
- [x] 0.3 **手工注册可行性 spike**（替代原 D0/R1/R9 的宏修正）：
  - 建 `JitHostRegistry` 骨架，只注册 `Event`：4 条 `HostFieldTable.register` + 一个
    `ClassDescriptor`（4 个字段 + `toString`）；
  - 编译 `{ e: Event => e.name }` 并 `call<String>([EndEvent("c","t","ok")])`，确认返回 `"End"`；
  - 注册 `ImmediateFlow` 的 `PublicCtor([4,4])` 与 `registerStart`，确认脚本能构造并调用；
  - 把实际结论写回 `design.md` §12 待验证项（成功就改为已确认）。
  > **结论（阻塞，两轮）**：第一轮 spike 在「脚本构造 `ImmediateFlow`」失败——构造器调用
  > `registerMultiEventTask()`，默认实现走业务入口 `registerTask(eventName:task:)`，构造期必中
  > 「`startName` 为空」校验并抛 `GraphException`。0.6 第一轮修掉该校验后，第二轮又在「Multi
  > 事件扇出」阻塞：业务入口把执行器登记为 `EventType.Task` 键，`MultiEvent` 永远命中不到；
  > 同时发现 `AsyncFlow` 的 `flows` 判重集合从不写入。三者均为既有缺陷（旧 DSL 路径同样受
  > 影响），根因与方案见 `design.md` D9；本项在 0.6 修复后继续完成。
  > **实测（0.6 修复后复验，通过）**：`JitHostRegistry_test.scriptReadsEventName` 断言
  > `{ e: Event => e.name }` 对 `EndEvent` 返回 `"End"`；
  > `scriptConstructsImmediateFlowAndRegistersStart` 断言脚本构造 `ImmediateFlow` 并
  > `registerStart("created")` 后宿主 `start("go")` 能拿到结束事件。结论已回填 `design.md` §12。
- [x] 0.4 **宏可用面验证**：给 `Task` 加 `@JitBind` 并 `registerInterface<Task>()`，
  给 `ClosureTask`/`FlowEventFactory` 加 `@JitBind` 并 `registerType`；
  `cjpm build` 在 `f_egraph` 与 `f_jit` 都无新增 WARNING。若出现 WARNING，记录到
  `design.md` §7.4 而不是修宏。
  同时验证 `ClosureTask` 公有构造器的函数类型形参：若 `as (Event) -> Event` 编译失败，
  按 `design.md` §7.1 回退方案改构造器可见性（函数类型构造器降为包内 + 公有
  `JitFunction` 版本），并把结论回填到 §7.1/§10 R12/§12。
  > **进度**：`Task` 部分已完成——`@JitBind` + `registerInterface<Task>()` 编译通过、
  > `cjpm test` 8/8 全绿、无新增 WARNING；宏导入需逐文件（已回填 `design.md` §12.1）。
  > `ClosureTask`/`FlowEventFactory` 尚不存在，其宏展开与 R12（构造器函数类型形参）
  > 在 2.2/2.4 实现时一并验证，届时再勾选本项。
- [x] 0.5 **重载登记口径确认**：`ImmediateFlow`/`AsyncFlow` 描述符只登记一条 `registerTask`
  （`[14,14]`），确认 `registerClass` 后方法表里该名字只有一条。
  > 实测：`JitHostRegistry_test.flowDescriptorsRegisterSingleRegisterTask` 对两个描述符
  > 断言「名为 `registerTask` 的方法恰好 1 个、绑定名 `<类型>.registerTask`、形参 `[14,14]`」。
- [x] 0.6 **修复构造期 Multi 注册与 Multi 分发缺陷（D9，TDD）**：
  - **Red**：新建 `f_egraph/src/base/Flow_test.cj`，先写 5 条失败用例：
    - 新 `category`/`tag` 构造 `ImmediateFlow` 不抛异常；
    - `AsyncFlow.initDispatcher()` 后构造 `AsyncFlow` 不抛异常；
    - `MultiEvent` 把两个子事件扇出到各自执行器（各派发一次，返回 `DummyEvent`）；
    - `registerStart("created")` 后注册 `acceptableEvents = ["other"]` 的任务仍抛 `GraphException`；
    - 同一 `(category, tag)` 二次构造后，单个子事件只派发一次——`ImmediateFlow` 与 `AsyncFlow`
      各断言一次（`AsyncFlow` 依赖构造期 `flows.add(this)`）。
  - **Green**（5 个文件）：
    1. `Dispatcher.cj`：新增
       `internal func registerMultiTask(category!: String, tag!: String, task!: (Event) -> Event): Unit`；
    2. `ImmediateDispatcher.cj`：以
       `Event(eventType: EventType.Multi, category, tag, name: EventType.Multi.toString())`
       构造 `TaskExecutor`，经私有 `doRegister(executor:)` 追加；
    3. `AsyncDispatcher.cj`：`synchronized(mutex)` 内转调 `dispatcher.registerMultiTask(...)`；
    4. `ImmediateFlow.cj`：覆写 `registerMultiEventTask()`，调用
       `getDispatcher().registerMultiTask(..., multiEventTaskBody(this))`；
    5. `AsyncFlow.cj`：同上，并保留构造成功后的 `flows.add(this)`。
  - `Flow.cj` 的 `multiEventTaskBody` 第一轮已抽出，直接复用，本轮不改；不改 `f_jit`、
    不改公开签名（`registerMultiTask` 为 `internal`）。
  - 若仓颉不允许公开抽象类声明 `internal` 抽象成员，按 `design.md` D9 的兜底写法
    （`protected abstract doRegisterMulti` + `Dispatcher` 内具体转发）实施，并把实际写法回填 D9。
  - `cjpm test` 跑绿后勾选本项。不改 `f_jit`，不改 `PublicCtor`/方法签名。
  > **实测（A′）**：`internal` 抽象成员不被仓颉允许（`visibility of an 'abstract' function
  > must be 'public' or 'protected'`），按兜底写法落地并回填 `design.md` D9——
  > `Dispatcher` 为 `internal registerMultiTask`（转调）+ `protected abstract doRegisterMulti`，
  > 两个 dispatcher 实现 `doRegisterMulti`；`ImmediateDispatcher` 里的私有方法签名是位置形参
  > `doRegister(executor)`。5 条用例全绿；其中两条 Multi 扇出用例补齐了末态 `EndEvent`——
  > `ImmediateDispatcher.dispatch` 的 `eventQueue.remove()` 是阻塞出队，只有遇到 `EndExecutor`
  > 才返回，原用例全部返回 `DummyEvent` 会在队列排空后阻塞。

- [x] 0.7 **`@IgnoreJitBinding` 宏与反射侧忽略（D10，TDD，`f_jit`）**：
  - **先写失败测试** `f_jit/src/JitBindIgnore_test.cj`：`@JitBind` 类中给一个 `public static func`
    标 `@IgnoreJitBinding`，断言 `enrollOf` 的 `statics` 不含它、其余静态成员仍在；实例方法/
    字段同理；未标注的同类成员仍被登记；
  - **再写反射侧失败测试**：`registerType<T>()` 后，被忽略的静态/实例成员**不在**自动包装里，
    脚本 `{ => <ignored>() }` 编译失败；
  - 非法位置：`@IgnoreJitBinding` 用在未被 `@JitBind` 修饰的类里，断言编译失败且错误含
    `JitBind`（负向用例可放在 `f_jit/src/test/` 的编译失败夹具，按 f_jit 既有做法）；
  - 实现 `f_jit/src/macros/IgnoreJitBinding.cj`（`assertParentContext('JitBind')` +
    `setItem('member', name)` + 原样返回 `input`）；
  - `f_jit/src/base/JitBindings.cj` 增加 `ignored: Array<String>`（默认空，向后兼容）；
  - 修改 `f_jit/src/macros/JitBind.cj`：`getChildMessages('IgnoreJitBinding')` 收集名单写入
    `JitBindings`，成员遍历各分支按成员名跳过；
  - 修改 `f_jit/src/ReflectRegistrar.cj`：实例方法/字段、静态函数/静态只读字段与属性、
    `static var`/`static mut prop` 的收集循环对 `bindings.ignored` 内的名字跳过，不生成任何绑定；
  - 跑 `fusion_build.sh /…/f_jit` 全绿后勾选，并在 `design.md` §12 回填实测结论。
  > **实测**：`JitBindIgnore_test` 5 条用例全绿。红→绿路径为「宏侧 `enrollOf` 不看
  > `statics`/`methods`/`fields`（4 条已绿）→ 反射侧仍回退包装 `hostOnly`，脚本
  > `{ => hostOnly() }` 编译成功（`ignoredMembersAreInvisibleToScripts` 红）→
  > `JitBindings.ignored` + `JitBind` 下发名单 + `ReflectRegistrar` 六处收集循环跳过 → 转绿」。
  > 父类成员并入（`mergeAncestorFields`/`mergeAncestorMethods`）同样按父类 `ignored` 跳过，
  > 否则子类注册会把被忽略的父类成员重新按反射包装加回来。
  > 负向用例无法放进 `cjpm test`（`include = ["src"]` 会把编译失败夹具一起编进包），
  > 改用独立 cjpm 工程 `cjpm build` 验证：报
  > `error: The macro call 'IgnoreJitBinding' should with the surround code contains a call 'JitBind'`。
  > `fusion_build.sh f_jit`：TOTAL 1142，PASSED 1142，FAILED 0（先前偶发的
  > `PerfOverride_test` 本轮未复现）。

## 1. 手工注册宿主类型（需求 2、4、5、6）

- [x] 1.1 **先写测试** `f_egraph/src/base/JitHostRegistry_test.cj`（金线）：
  - 8 个事件类、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow` 均可 `hasClass`；
  - 事件类字段集合 = `{category, tag, name, session}`，索引 0–3、类型码 4、`mutable=false`；
  - `Event` 方法集合 = `{toString}`；`BaseFlow`/`ImmediateFlow`/`AsyncFlow` 方法集合 =
    `{canBeRemoved, remove, removeExceptCurrentTag, registerStart, registerEnd, registerError, registerTask}`；
  - `Emitter` 方法集合为空；两个流程类构造器 `params` 均为 `[4,4]`；
  - 每个 `PublicMethod.bind.name` 在整个注册表中唯一。
- [x] 1.2 实现 `f_egraph/src/base/JitHostRegistry.cj`：`registerEventFields()`（4 条
  `HostFieldTable.register`，`accepts = { o => o is Event }`）+ 8 个事件 `ClassDescriptor`
  （父链、字段、`toString`）。
- [x] 1.3 实现 `Emitter` 与 `BaseFlow` 描述符（`isInterface = true`）；`BaseFlow` 7 个方法，
  适配器按设计 §5.2 手写；**不登记** `emit`/`start`/闭包重载/`dependencied`/泛型方法。
- [x] 1.4 实现 `ImmediateFlow`/`AsyncFlow` 描述符：`PublicCtor([4,4])` + 同一组 7 个方法，
  `parents = ["BaseFlow"]`。
- [x] 1.5 **先写测试** `f_egraph/src/base/JitManualBinding_test.cj`（端到端）：
  - 脚本 `{ e: Event => e.name }` / `e.category` / `e.tag` 返回正确值；
  - 脚本 `{ => ImmediateFlow("c", "t") }` 能拿到实例（通过 `call<ImmediateFlow>` 断言）；
  - 逐个方法真实调用：`registerStart`/`registerEnd`/`registerError`/`registerTask(Task)`/
    `removeExceptCurrentTag`/`canBeRemoved`/`remove`；
  - 负向：`flow.emit(...)`、`flow.registerTask("e", t)`、`e.data`、`e as TaskEvent`
    均在编译期失败（断言异常类型与消息关键词）。
- [x] 1.6 确认 `Event.cj`、`Emitter.cj`、`Flow.cj`、`ImmediateFlow.cj`、`AsyncFlow.cj`
  内**没有任何** `@JitBind`；测试断言 `JitBindSupport.enrolledOf` 对这些类型返回空。
- [x] 1.7 静态名空间初检：此时 `registeredNames()` 只应包含手工方法绑定名
  （`Event.toString`、`BaseFlow.*`、`ImmediateFlow.*`、`AsyncFlow.*`），
  且**不含** `initDispatcher` / `instance`。此断言只覆盖手工路径；宏静态名由 2.5 的
  端到端脚本用例负责（`registeredNames()` 不含 `registerType` 的 `autoFunctions`）。

## 2. `ClosureTask` 与 `FlowEventFactory`（需求 7、11）

- [x] 2.1 **先写测试** `f_egraph/src/base/ClosureTask_test.cj`：
  - 构造器与四个属性；
  - `exec` 返回注入执行体的结果；
  - `compile` 成功（同步/异步流程可用）；
  - 空白 `name`、空事件列表、空白 `exec` → `GraphException`；
  - 非法源码 → f_jit 编译异常且站点保留；
  - 未注入编译器时的惰性创建路径；
  - `compile` 的列表形参类型为 `ArrayList<Any>`（LIST 运行时形态；用 `ArrayList<Any>`
    实参调用；非字符串元素 → `GraphException`）；
- [x] 2.2 实现 `f_egraph/src/base/ClosureTask.cj`：
  - `@JitBind`；
  - 私有静态 `compilerMtx` + `sharedCompiler`（`static var` 被宏忽略）；
  - `initCompiler` 与 `ensureCompiler`；
  - `compile` 按设计 §7.1 包裹 `{ e: Event => ... }`，`exec` 走 `JitFunction.call<Event>`；
  - 构造器按 0.4 的结论实现（首选单公有构造器；不合法则回退为包内函数类型构造器 +
    公有 `JitFunction` 构造器）；
  - `name`/`acceptableEvents`/`producingEvents`/`exec` 实现 `Task`。
  > **实测**：单公有构造器（含 `(Event) -> Event` 形参）的宏展开合法，未走 `JitFunction`
  > 回退方案（R12 关闭）。`compile` 形参为 `ArrayList<Any>`，内部 `stringEvents` 逐元素
  > `is String` 校验（空列表消息含字段名，非字符串消息含 `String`），列表转 `Array<String>`
  > 后交给构造器。
- [x] 2.3 **先写测试** `f_egraph/src/base/FlowEventFactory_test.cj`：
  - `flowTaskEvent`/`flowEndEvent`/`flowErrorEvent`/`flowDummyEvent` 的类型与字段；
  - `flowDataOf` 的 String、非 String、非 DataEvent 三个分支。
- [x] 2.4 实现 `f_egraph/src/base/FlowEventFactory.cj`（`@JitBind`，仅静态函数，设计 §7.2）。
- [x] 2.5 在 `JitHostRegistry.configure` 补上宏注册三项：`registerInterface<Task>()`、
  `registerType<ClosureTask>()`、`registerType<FlowEventFactory>()`；随后断言宏登记面
  （`JitBindSupport.enrolledOf` 中 `Task`/`ClosureTask`/`FlowEventFactory` 的方法集合）。
  **`ClosureTask.initCompiler` 必须因 `@IgnoreJitBinding` 不在 `statics` 中**，`compile` 仍在。
  宏静态名改用**端到端**断言：用同一 `Compiler` 编译并执行分别调用 `compile(...)` 与
  5 个 `flow*` 的脚本，全部成功；反向用 `initCompiler(...)`/`initDispatcher(...)`/
  `DummyEvent.instance` 的脚本断言编译期失败。**不要**用 `registeredNames()` 断言宏静态名——
  它只含 `registerClass` 写入的方法绑定，`registerType` 的 `autoFunctions` 只在 `snapshot()`
  时并入（`Compiler.cj:149-185`）。
  > **实测**：`ClosureTask.initCompiler` 标 `@IgnoreJitBinding` 后，宏 `statics` 仅剩
  > `compile`（`b.ignored == ["initCompiler"]`），反射侧也未回退包装——脚本
  > `{ => initCompiler(1) }` 编译失败，错误文本为
  > `NotAssigned ... 局部变量「initCompiler」在读取路径上未必已被赋值`（含名字，不含
  > 「未定义/未注册」字样），故负向断言只校验「失败且消息含成员名」。`scriptCallsCompile`
  > 与 5 个 `flow*` 的端到端调用全绿；`JitBinding_test` 7/7、`f_egraph` 48/48。

## 3. 脚本初始化（需求 9）

- [x] 3.1 **先写测试** `f_egraph/src/FlowInitializer_test.cj`：
  - 假 `FlowLoader`（返回同步脚本）→ `initialize()` 后流程可启动并结束；
  - 两个脚本各自注册一个流程；
  - 空列表正常返回；
  - 空脚本 → `GraphException` 且后续脚本未执行；
  - 非法源码 → f_jit 编译异常；
  - 异步脚本：已 `initDispatcher` 成功、未初始化的失败路径；
  - 脚本末尾 `removeExceptCurrentTag` 清理旧 tag；
  - 共享编译器（两个脚本的 `compile` 均可执行）。
  > **实测（3.5 落地后转绿）**：10 条用例全绿。5 条启动用例（同步、双流程、异步、旧 tag 清理、
  > 共享编译器）都改为「`initialize()` 之后宿主**新实例**启动」，即 D11 的回退路径；异步用例改
  > `tryGet(timeout: Duration.second)`，避免 dispatcher 异常时无限阻塞。「未初始化」失败路径仍在
  > `AsyncFlow_test.uninitializedDispatcherFailsConstruction`（需要 base 包内的 `resetDispatcherForTest`）。
- [x] 3.2 新增 `f_egraph/src/loader/FlowScriptRunner.cj`（`internal`）：
  空脚本校验、`{ => <script> }` 包装（不追加 `()`，末句须为 Unit）、`call<Unit>([])`；
  非 Unit 结尾的负向用例。
  > **实施结论（与 design D3 一致）**：文件最终放**根包** `f_egraph/src/FlowScriptRunner.cj`
  > （`class` 不加 `public`，包内可见），原因有二：f_jit 的 `Parser.parsePrimary` 在 `(` 之后
  > 无条件 `parseExpr()`，**不支持空元组 `()`**；且 `internal` 对子包可见、对父包不可见，
  > `loader` 包内的类无法被根包 `egraph.cj` 调用。design D3 已改为「不追加哨兵表达式」，
  > 与本实现一致；非 Unit 末句的负向用例为 `nonUnitLastStatementIsRejected`。
- [x] 3.3 重写 `f_egraph/src/egraph.cj` 的 `FlowInitializer.initialize`：
  创建 `Compiler(CompileOptions(DummyDiagnosticsSink()))` → `JitHostRegistry.configure` →
  `ClosureTask.initCompiler` → 遍历 `lookup<FlowLoader>().load()` 调用 `FlowScriptRunner.run`。
- [x] 3.4 更新 `FlowLoader` 的文档注释：说明每个元素是「一个流程的 f_jit 脚本」，
  并引用 `design.md` §6 的契约、§6.2 的 7 条约束与 §6.4 的映射表。
- [x] 3.5 **开始事件名共享读取（D11，TDD）**：先补失败用例——`initialize()` 后宿主用新的
  `ImmediateFlow(category: c, tag: t)` / `AsyncFlow(...)` 启动能拿到结束事件；再实现
  `Dispatcher.startEventName` + `ImmediateDispatcher` 记录、`AsyncDispatcher` 加锁转调、
  两个 `Flow.start` 本地 `startName` 为空时回退；最后回归「本地 registerStart 后仍用本地名」。
  > **实测**：红 → `GraphException: No executor found for event: Event(... name: )`
  > （`FlowInitializer_test.syncScriptRegistersRunnableFlow`）→ 实现后 10/10 绿。
  > 实际写法：`Dispatcher` 的 `internal startEventName` 转发 + `protected doStartEventName` 抽象
  > （抽象成员不能是 `internal`，与 D9 同因）；`ImmediateDispatcher` 用
  > `category -> tag -> 名称` 的嵌套 `HashMap`；`AsyncDispatcher` 在 `synchronized(mutex)` 内转调。
  > 回归用例：`Flow_test.localRegisterStartStillDrivesStart` /
  > `localRegisterStartStillDrivesAsyncStart`。
  > **附带修复（测试暴露的既有缺陷）**：`AsyncDispatcher.getEvent` 原在 `mutex` 内阻塞取队列，
  > 使异步流程 `start` 之后任何登记/清理永久等锁；`AsyncFlow.doRemove` 原在 `removeIf` 谓词内
  > 删 `flows`，下一事件重建流程时重新登记 Multi 而自锁。两者改为「取队列不加锁」「循环后统一删
  > `flows`」，公开签名不变，已回填 design D11。

## 4. 删除 DSL 与文档（需求 8）

- [x] 4.1 删除 `f_egraph/src/base/FlowDSLCompiler.cj`（含 `FlowDSLCompiler`/`TaskDef`/`ProducingDef`）。
- [x] 4.2 全仓清理引用：`FlowDSLCompiler`、`TaskDef`、`ProducingDef`、旧 DSL 示例。
  > **实测**：`grep -rn "FlowDSLCompiler\|TaskDef\|ProducingDef"` 在 `f_egraph/src` 与两份 README 中
  > 只剩「迁移」章节的说明文字（用于告诉使用者这些类型已删除），没有代码或示例引用。
  > 删除后 `imports.cj` 的 `HashSet`/`LinkedList` 变成未使用导入，已移除
  > （`JitHostRegistry_test` 自行导入 `HashSet`）。
- [x] 4.3 更新 `f_egraph/README.md` 与 `README_en.md`：
  - 删除 DSL 编译器章节与「其他公开 API」中的 `ProducingDef`/`TaskDef`；
  - 增加 `ClosureTask`、`FlowEventFactory`、脚本契约与迁移示例；
  - 明确 `BarrierTask<G>` 不支持 JIT 绑定；`AsyncFlow.initDispatcher` 由宿主调用；
  - 明确脚本面边界：不能用 `is`/`as`；`emit`/`start`/`initDispatcher` 不在脚本面。
  > **实测**：两份 README 的 DSL 章节替换为 `ClosureTask` / `FlowEventFactory` / 流程脚本契约
  > （7 条约束）/ 迁移映射表；`FlowLoader` 段落同步为「每个元素是一个流程的脚本」；
  > 「其他公开 API」移除 `ProducingDef`/`TaskDef`，补 `JitHostRegistry.configure`。
  > 迁移示例由 `FlowInitializer_test.readmeExampleScriptRuns` 逐行复刻执行（7.5）。
- [x] 4.4 `cjpm build` 后检查构建日志：`f_egraph` 无新增 WARNING（`f_jit` 也无），
  实际条数记录到 `design.md` §7.4。
  > **实测**：`f_egraph` **5 条**（3 条 `jitBindEnroll_*` 未使用 + 1 条宏内 `args` 未使用
  > + 1 条既有的 `TypeInfo.of` deprecated），已按实际构成回填 `design.md` §7.4；
  > `f_jit` 7 条与改动前的干净副本逐条一致（无新增，均为既有告警）。

## 5. 公开 API 测试补齐（需求 10）

按下列矩阵逐项补齐。测试文件 SHALL 放在**被测包目录**下（`src/base/`、`src/loader/`、
`src/exception/`、根 `src/`），与 `f_mq/src/base/*_test.cj` 的既有约定一致——
包外文件访问不到 `internal` 成员（手工描述符工厂需要同包才能断言）。

| 领域 | 测试文件 | 覆盖的公开 API |
|---|---|---|
| 事件枚举 | `src/base/EventType_test.cj` | `EventType` 六个值、`toString`/`hashCode`/`==` |
| 事件 | `src/base/Event_test.cj` | `Event`、`DataEvent`、`StartEvent`、`EndEvent`、`TaskEvent`、`ErrorEvent`、`MultiEvent`、`DummyEvent` |
| 异常 | `src/exception/GraphException_test.cj` | 4 个构造器、`message`/`cause` |
| 执行器 | `src/base/Executor_test.cj` | `Accepter`、`Executor`、`ImmediateExecutor`、`StartExecutor`、`EndExecutor`、`ErrorExecutor`、`TaskExecutor`、`AsyncTaskExecutor`、`ConcurrentEndExecutor` |
| 同步调度 | `src/base/ImmediateDispatcher_test.cj` | `Dispatcher`、`ImmediateDispatcher` |
| 异步调度 | `src/base/AsyncDispatcher_test.cj` | `AsyncDispatcher` |
| 流程 | `src/base/Flow_test.cj` | `BaseFlow`、`Flow<G>`、`Emitter`、`ImmediateFlow`、`AsyncFlow`（含 `registerTaskBy*`、`remove*`、`dependencied`、`start`、`emit`） |
| 屏障 | `src/base/BarrierTask_test.cj` | `BarrierKey`、`BarrierTask<G>` |
| 手工注册 | `src/base/JitHostRegistry_test.cj`、`src/base/JitManualBinding_test.cj` | 描述符金线 + 每个登记成员的端到端调用 |
| 宏注册 | `src/base/JitBinding_test.cj` | `Task`/`ClosureTask`/`FlowEventFactory` 的 `enrolledOf`，以及其余类型为空 |
| JIT 任务 | `src/base/ClosureTask_test.cj`、`src/base/FlowEventFactory_test.cj` | 本变更新增 API |
| 初始化 | `src/FlowInitializer_test.cj` | `FlowLoader`、`FlowInitializer` |

- [x] 5.1 事件与异常（3 个文件）。
  > **实测**：`EventType_test` 3 条、`Event_test` 8 条、`GraphException_test` 4 条。
- [x] 5.2 执行器与同步/异步调度（3 个文件）；`ImmediateDispatcher_test.cj` 与
  `AsyncDispatcher_test.cj` 增补 `registerMultiTask` 用例：acceptable 事件
  `eventType = Multi`、名称为 `EventType.Multi.toString()`，投递 `MultiEvent` 能命中；并与
  业务 `registerTask`（登记为 `Task`）收不到 `MultiEvent` 作负向对照。
  > **实测**：`Executor_test` 10 条（含 `TaskExecutor` 三种构造、`AsyncTaskExecutor` 后台执行、
  > `ConcurrentEndExecutor` 的延时唤醒与超时）、`ImmediateDispatcher_test` 7 条、
  > `AsyncDispatcher_test` 7 条；两个 dispatcher 都覆盖 `registerMultiTask` 命中与
  > `startEventName`（D11）。
  > **已裁决并实现（D12）**：业务 `registerTask` 改用带校验的
  > `doRegister('TaskExecutor', executor)`，同一 `(category, tag, eventName)` 重复登记抛
  > `GraphException`；`ImmediateDispatcher_test` 与 `AsyncDispatcher_test` 各补
  > `duplicateTaskIsRejected` 用例。
- [x] 5.3 流程与屏障（2 个文件）；`Flow_test.cj` 在 0.6 的基础上增补经 `registerMultiTask`
  的 Multi 扇出、`ImmediateFlow` 与 `AsyncFlow` 各自的二次构造去重、以及
  `registerTaskBy*Flow` 依赖用例。
  > **实测**：`Flow_test` 18 条（构造/扇出/首任务约束/两种二次构造去重/D11 本地名回归/
  > `emit`（宿主与任务内各一条）/相等性与 `toString`/`registerTaskByImmediateFlow` 与
  > `registerTaskByAsyncFlow` 的依赖与 `canBeRemoved`/`AsyncFlow.removeExceptCurrentTag`）、
  > `BarrierTask_test` 5 条（阈值触发聚合、未达阈值、非 `DataEvent`、`BarrierKey` 四字段）。
- [x] 5.4 手工/宏注册、JIT 任务与初始化（6 个文件，部分已在 1.1/1.5/2.1/2.3/2.5/3.1 建立）。
  > **实测**：`JitHostRegistry_test` 补 `hostFieldTableExposesOnlyFourIndexes`（索引 0–3 的
  > 类型码/不可写/取值，`data` 不在表中）；其余文件保持全绿。
- [x] 5.5 全局状态隔离：每个流程用例唯一 `category`，结束 `remove()`；异步 dispatcher 统一初始化；
  `HostFieldTable` 用例前后 `resetForTest()`。
- [x] 5.6 覆盖率自查：逐条对照本矩阵，确认每个 `public` 声明至少一个用例。
  > **自查结果**：矩阵内全部公开类型都有正向用例；可能抛异常的分支
  > （空脚本、非法源码、首任务约束、未初始化 dispatcher、类型不匹配、未知事件）均有负向用例。
  > 可能抛异常的分支（空脚本、非法源码、首任务约束、未初始化 dispatcher、类型不匹配、
  > 未知事件、重复任务登记）均有负向用例。

## 6. 风险验证（对应 `design.md` §10）

| 风险 | 验证动作 | 通过标准 |
|---|---|---|
| R1 成员遗漏 | 1.1 的金线断言用**集合相等**，不是包含 | 漏登记、多登记都会失败 |
| R2 适配器签名写错 | 1.5 端到端用非默认值调用每个方法；多方法共用适配器时逐个覆盖 | 无 `CALL_CONTRACT` / `ClassCastException` |
| R4 描述符名与注解口径 | 1.1/1.5 中真实编译 `{ e: Event => e.name }` 与 `{ => ImmediateFlow("c","t") }` | 名字写错（如写成完整限定名）在测试期即失败 |
| R5 静态名空间 | 2.5 + 1.7 的名字断言 | 6 个名字各一次，无 `initDispatcher`/`instance` |
| R6 异步前置条件 | 3.1 的「未 initDispatcher」用例 | 上抛原始异常，不回滚已注册流程 |
| R7 嵌套编译 | 3.1 的「脚本内 compile」用例 | 无死锁，两个脚本都能编译执行 |
| R11 HostFieldTable 全局表 | 5.5 的 reset 约定 + 连续两次 `cjpm test` | 两次结果一致 |

- [x] 6.1 逐条执行上表并勾选。
  > **实测**：R1/R2/R4/R5 由 `JitHostRegistry_test` 与 `JitManualBinding_test` 的集合相等断言 +
  > 真实脚本调用覆盖；R6 由 `AsyncFlow_test.uninitializedDispatcherFailsConstruction`
  > （异常来自 dispatcher 未初始化，符合 D9 的失败语义）；R7 由
  > `FlowInitializer_test.scriptsShareInjectedCompiler`（两个脚本各用一次 `compile`）；
  > R11 见 7.2 的连续两次运行。
  > 附带发现并修复的两处既有缺陷（`AsyncDispatcher.getEvent` 持锁阻塞、`AsyncFlow.doRemove`
  > 谓词内删 `flows`）已在 D11 回填，回归用例覆盖在 `AsyncFlow_test` 与 `Flow_test`。
- [x] 6.2 若某条不通过，先修 `f_egraph` 侧实现；**不允许**通过修改 `f_jit` 解决。
  > 本轮未出现需要在 `f_jit` 侧修的问题；`f_jit` 的改动仍只有 D10 的四个文件。

## 7. 验收

- [x] 7.1 `cjpm build`：无错误；WARNING 仅限 `design.md` §7.4 登记项（预期 `f_egraph` 5 条
  宏展开产生的 unused variable、`f_jit` 0 条）。
  > **实测**：`f_egraph` 5 条（3 条 `jitBindEnroll_*` + 1 条宏内 `args` + 1 条既有
  > `TypeInfo.of` deprecated，构成已回填 §7.4）；`f_jit` 与改动前副本逐条一致（无新增）。
- [x] 7.2 `cjpm test`：全绿；连续运行两次结果一致。
  > **实测（D12 补齐后）**：`f_egraph` **121/121**（base 106 + exception 4 + 根包 11）。
  > 连续两次运行结果一致；`f_jit` **1141–1142/1142**——唯一不稳定项是既有性能用例
  > `PerfOverride_test.overrideBeatsReflectionEndToEnd`（净成本在阈值附近波动，与本次变更无关，
  > 0.1 基线已记录；verify 那次为 1142/1142 全绿）。
- [x] 7.3 手工冒烟：用假 `FlowLoader` 注册一个「开始 → 校验 → 结束」同步流程，
  验证任务体由 `ClosureTask.compile` 生成、结束事件由 `flowEndEvent` 构造。
  > **实测**：`FlowInitializer_test.syncScriptRegistersRunnableFlow` 与
  > `readmeExampleScriptRuns` 走完整的「脚本 → `compile` → `flowEndEvent` → 宿主新实例 `start`」路径。
- [x] 7.4 异步冒烟：宿主先 `AsyncFlow.initDispatcher()`，执行异步脚本并 `tryGet(timeout:)` 拿到结束事件。
  > **实测**：`FlowInitializer_test.asyncScriptRequiresInitDispatcher` 用
  > `tryGet(timeout: Duration.second)` 断言拿到 `End`。
- [x] 7.5 文档核对：README 示例可编译（至少在测试中复刻一遍）。
  > **实测**：`readmeExampleScriptRuns` 复刻 `README.md` / `README_en.md` 的迁移示例
  > （两段 `compile` + `flowTaskEvent` + `flowEndEvent`），执行成功并返回 payload `"go"`。
- [x] 7.6 全仓 `FlowDSLCompiler` 零引用；`f_jit` 的 `git diff` 仅限
  `macros/IgnoreJitBinding.cj`、`macros/JitBind.cj`、`base/JitBindings.cj`、
  `ReflectRegistrar.cj` 与相应测试；`f_jit` 的 `cjpm test` 全绿；
  `f_egraph/doc/spec/f-egraph-jit-flow-init` 的验收场景逐条勾对。
  > **实测**：`f_egraph/src` 与两份 README 无 `FlowDSLCompiler`/`TaskDef`/`ProducingDef` 代码引用
  > （仅迁移章节的说明文字）。**注意**：本仓库的 `git` 元数据（`.git` 文件指向
  > `/storage/.../.git/worktrees/f_egraph`）在当前环境不可解析（`git` 报
  > `not a git repository`），无法产出 `git diff`；改用与 `f_jit` 干净副本的逐目录比对：
  > 变更仅落在 `macros/IgnoreJitBinding.cj`（新增）、`macros/JitBind.cj`、
  > `base/JitBindings.cj`、`ReflectRegistrar.cj` 与 `src/JitBindIgnore_test.cj`。
  > `f_jit` 的 `cjpm test` 见 7.2。`f_egraph/doc/spec/f-egraph-jit-flow-init` 已与本变更目录同步。
- [x] 7.7 **合并需用户确认**（已确认：`1bd64039` 已 `--no-ff` 合入 `sts/1.3.x`）：验收全绿后向用户汇报，得到确认再执行
  `git merge --no-ff feature/f_egraph` 到 `sts/1.3.x`；合并后是否删除功能分支同样由用户确认。
  本变更的执行过程**不得**自动 merge、不得自动 push。


## 8. 遗留（verify 记录，行为已实现，不在本变更补）

- **W3 场景级用例缺口**：① 开始事件先于任务；② 初始化路径的重复执行器拒绝（已在 dispatcher
  层由 `duplicateTaskIsRejected` 覆盖）；③ 直接构造事件失败（已由描述符 `ctors.size == 0` 结构性覆盖）；
  ④ 旧 DSL 字符串被拒绝；⑤ `let f: BaseFlow = ImmediateFlow(...)` 的接口赋值编译用例；
  ⑥ 初始化级重复注册。后续按需补。
- **W4 非法位置的仓内夹具**：`@IgnoreJitBinding` 用在 `@JitBind` 之外时，`f_jit` 目前只有
  一次性外部工程验证（报 `should with the surround code contains a call 'JitBind'`），
  未固化为仓内编译失败夹具。
- **S2 既有文档问题**：`README.md` 提到 `AsyncFlow.remove(category:tag:)` 静态方法，代码中
  不存在（本变更 diff 未触及，另行修正）。
