# f_llm 模块审查报告（第 14/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个源文件，全部位于 `src/loom/`）
- **基线**：工作区快照（分支 `sts/1.3.x`，`f_llm/src/loom` 无未提交改动，无 diff 可比 → 来源统一记「存量」）
- **审查重点**：本部分实际覆盖 代码生成 / JIT 编译 / 宿主桥 / 存储实现 / 启动恢复 / 后台任务 / 执行期上下文；重点为契约与配置分发、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块分报告，第 14 部分，供主 Agent 合并；本部分不含 `.md`，文档一致性按「承诺源在 `doc/`、`README` 」取证）

## 发现

### [严重][存量] `LoomContextLog` 是进程级单例，嵌套与并发执行互相清空、串台，跨流程/跨用户的对话会写进同一条记忆

- **位置**：`f_llm/src/loom/LoomContextLog.cj:52`（`private static var turns`）、`:66-71`（`begin` 无条件重置）、`:92-105`（`snapshot` / `clear`）
- **来源**：存量（`git blame`：`LoomContextLog.cj:66-71` 为 `b597073227` 2026-11-03，`:67` 加锁为 `a45fc16d14` 2026-11-07；`LoomRunner.cj:217/233-234` 同期）
- **判据**：review-checklist §12.1（共享可变状态无隔离 / 可见性与生命周期错配）、§11（契约与实现不符：「生命周期严格绑在一次流程执行上」）
- **证据**：静态确定 —— 状态是 `static`，唯一隔离手段是一把 `Mutex`（只保证单次操作原子，不区分执行实例）；`LoomRunner.runCompiled` 的 `begin()`（`LoomRunner.cj:217`）与 `finally` 里的 `snapshot()+clear()`（`LoomRunner.cj:233-234`）都作用在这份全局状态上，没有任何 per-execution 标识
- **描述**：`begin()` 无条件 `turns = ArrayList()` + `active = true`，`clear()` 无条件 `turns = ArrayList()` + `active = false`。只要有两条执行重叠，就会出现：
  1. B 的 `begin()` 把 A 已累积的轮次清空 → A 结束时的记忆提炼拿到残缺上下文；
  2. B 结束时的 `clear()` 把 `active` 置 `false` → A 其后所有 `LoomHostApi.callLlm`（`LoomHostApi.cj:205` 调 `record`）被静默丢弃，A 的 `snapshot()` 缺尾；
  3. 反向：A 的 `snapshot()` 可能取到 B 写入的 `LlmTurn`，`LoomMemoryExtractor.extract` 以 A 的 `plan.name` 与记忆策略的 `userId` 落库 → **B 的 prompt 与输出被当成 A 的上下文写进 A 的记忆**（内容串台；若 A/B 属于不同用户，就是把他人对话落到本用户名下）。
  4. `LoomRunner.cj:216` 只在 `policy.enabled` 时才 `begin()`，但 `finally` 里的 `snapshot()/clear()` 无条件执行 → 关闭记忆策略的执行会清掉另一条开启策略的执行的状态（第 2 条只是其中一种）。
  并发路径是真实存在的：`LoomService.executeNow`（`LoomService.cj:122-141`）无任何串行化，既被 `LoomExecuteFunction`（`LoomFunctions.cj:126`，工具调用线程）调用，也被 `ScheduleCreateFunction.runFlow`（`ScheduleFunctions.cj:86`，ticktock 线程）调用；`parallel=true` 时 `AsyncFlow` 还会在分叉分支上并发跑步骤。更确定的嵌套路径：`loomExecute` 本身是注册给模型的工具，流程里的 tool 步骤可以调用它 → 内层 `executeNow` 与外层同线程嵌套，`begin()/clear()` 必然互踩，**不需要并发就能触发**。
- **建议**：把 `turns` / `active` 从 `static` 改成「每次执行一个实例」：`LoomRunner.runCompiled` 里 `let ctx = LoomContextLog()`，通过参数或 `ThreadLocal` 传给 `LoomHostApi`（`callLlm` 增加 `ctx` 形参或从当前执行上下文取），删除 `static` 状态；若短期不能改，至少在 `begin()` 里检测 `active` 已为 `true` 就拒绝或退化为「不重置、只标记嵌套层数」，并在 `clear()` 里做引用计数，避免外层被内层关闭。

### [严重][存量] `JitTicktockTask` 的定时单步任务没有宿主可绑，tool/llm 步骤到点必然静默失效

- **位置**：`f_llm/src/loom/JitTicktockTask.cj:37-53`（任务体 `41-52`、吞异常 `48-51`）；依赖点 `f_llm/src/loom/LoomHostApi.cj:147-151`、`f_llm/src/loom/LoomRunner.cj:219/235`；承诺源 `f_llm/README.md:533`
- **来源**：存量（`git blame`：`JitTicktockTask.cj:37-53` 与 `BackgroundTasks.cj` 同批引入于 2026-11-03；`LoomHostApi.bind` 仅 `LoomRunner.cj:219` 一处于 `a45fc16d14` 2026-11-07 补齐）
- **判据**：review-checklist §3（承诺有行为、实际走进空分支）/ §14.1（承诺了但没接线）/ §0「静默失效 = 严重」
- **证据**：静态确定 —— 全仓 `grep -rn "LoomHostApi.bind" f_llm/src` 只命中 `LoomRunner.cj:219`；`LoomHostApi.callTool`/`callLlm` 在 `current == None` 时直接抛 `LoomException('loom host is not bound…')`（`:147-151`、`:200-208`）；`JitTicktockTask.create` 的任务体只构造事件并调用步骤闭包，从不 `bind`，异常被 `catch (error: Exception){ () }` 吞掉
- **描述**：`README.md:533` 写「JIT 步骤在任务里执行时由 `JitTicktockTask` 承接」，`doc/loom.md:186` 又把它列为「方式二：只跑某一步」并给出 `tool` 步骤示例。实际上定时触发时刻没有宿主：凡编译产物里出现 `loomCallTool`/`loomCallLlm`/`loomStore`（tool、mcp、llm 步骤，以及 jit 片段里调用这些桥的写法）都会抛错并被吞，任务表现为「按 cron 跑了但什么都没做」，且日志无痕。若触发时恰有另一条流程在执行，则会借用那条流程的 host（工具/模型的归属与配额记到别人头上）。当前生产链路走 `ScheduleCreateFunction.runFlow` → `executeNow`（跑整条流程，`ScheduleFunctions.cj:66-93`），本类仅测试引用，因此是「按 README 用就会踩空」的缺陷
- **建议**：`create` 接受 `LoomHost`（或任务体内 `LoomServices.currentHost()`）并在 `try` 里 `LoomHostApi.bind(host)` / `finally unbind()`；`catch` 里补 `warn`（`LoomRunner.cj:243-251` 有现成写法）。若确定不做单步调度，删掉本类并把 `README.md:533` 改成「定时任务执行完整流程（`executeNow`）」

### [一般][存量] `CodeGen.stepSource` 与 `LoomCompiler.{jit,tool,llm}SourceOf` 是三份同形源码生成逻辑，预览与真实编译靠注释约束同步

- **位置**：`f_llm/src/loom/CodeGen.cj:70-89`（`stepSource`）与 `f_llm/src/loom/LoomCompiler.cj:77-103`（`jitSourceOf` / `toolSourceOf` / `llmSourceOf`）
- **来源**：存量（`git blame`：`CodeGen.cj:74-75` 为 `0e6df9a3d0` 2026-11-02，`LoomCompiler.cj:91-103` 同期）
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 字面量复制）、§13（落库原文与实际执行的一致性）
- **证据**：静态确定 —— 三段生成串逐字对齐，只有缩进与注释差异：`'{ args: String =>\n  let ${id}_out = loomCallTool(${jsonQuote(tool)}, args)\n  ${id}_out\n}'` 两处各一份；`loomCallLlm` 同理；`jit` 两处都是 `{ e: Event => … ${id}_result }`。`CodeGen.cj:71` 的注释「与 `LoomCompiler` 实际编译的源码保持同形」正是靠人工约定。更进一步：`flowSource` 的流程组装部分与 f_egraph 现签名也不符——生成的 `flow.registerStart(category:…, tag:…, eventName:…)`（`CodeGen.cj:107-109`）、`flow.registerEnd(category:…, tag:…)`（`:127`）、`flow.get()`（`:129`）三处，而 `Flow.registerStart(eventName: String)` / `registerEnd()` 都不收 `category`/`tag`（`f_egraph/src/base/Flow.cj:23-24`、`AsyncFlow.cj:107/111`），`Flow` 上也没有 `get()`（`get()` 在 `EndExecutorGetter` 上，要用 `start()` 的返回值调），即这段落库源码**不可编译**
- **描述**：`flowSource` / `stepSources` 会落库并作为「可读源码」给开发者审计（`doc/loom.md:507` "流程级没有走 JIT：`CodeGen.flowSource` 只作预览/落库原文"），而真正执行的是 `LoomCompiler` 编译的串。两处任一侧改了字面量（函数名、参数顺序、变量命名），预览与执行就会静默分叉，审计看到的源码不再等于跑的代码——这是排查 loom 问题最难定位的一类偏差。全仓没有任何入口去编译 `flowSource`（只落库/预览/测试字符串断言），所以签名对不上也不会被编译器发现；叠加 `hasAsync` 的派发差异（见下一条），审计者拿到的「源码」在三个维度上都与真实执行不符
- **建议**：删掉 `CodeGen.stepSource` 里的三份模板，改为委托：`jit` → `LoomCompiler.jitSourceOf(step)`、`tool`/`mcp` → `LoomCompiler.toolSourceOf(step)`、`llm` → `LoomCompiler.llmSourceOf(step)`（这三个已是 `public static`，`LoomCompiler` 与 `CodeGen` 同包，无新增依赖）；顺带删掉 `CodeGen.jsonQuote`（`:164-166`）这个纯转发。

### [一般][存量] `StepPlan.async` 只有预览消费者，执行实际按 `plan.parallel` 派发，落库源码里的 `AsyncFlow`/`ImmediateFlow` 与真实执行不一致

- **位置**：`f_llm/src/loom/CodeGen.cj:135-145`（`hasAsync`）、`:96-98`（选 `AsyncFlow`/`ImmediateFlow`）；对照 `f_llm/src/loom/LoomService.cj:140`、`f_llm/src/loom/LoomRunner.cj:222`
- **来源**：存量（`git blame`：`CodeGen.cj:135-145` 为 `f6e7ba515d` 2026-11-01，`LoomService.cj:140` 为 `75f386d77e` 2026-11-07）
- **判据**：review-checklist §1（读了不用的字段 / 死配置字段）、§11（契约与实现不符）
- **证据**：静态确定 —— 全仓 `\.async` 读取点只有 `CodeGen.cj:137/140`；`StepPlan.async`（`Plan.cj:42`）由 `Planner.cj:203-206` 解析、`Plan.cj:241` 序列化进 `planJson`，但执行侧只看 `parallel`（`LoomService.cj:140` 传 `plan.parallel || parallel`，`LoomRunner.cj:222` 据此选 `AsyncFlow`）
- **描述**：默认计划里 `StepPlan.async` 是 `'auto'`，`hasAsync` 对非 `jit` 步骤一律返回 `true` → 预览源码写 `AsyncFlow(...)`；而 `FlowPlan.parallel` 默认 `false` → 实际执行是 `ImmediateFlow`。反之 `parallel=true` 且所有步骤 `async='false'` 时，预览写 `ImmediateFlow` 而实际并发。开发者按落库源码审计「这一步是并发还是串行」会得到错误结论；`async` 这个 schema 字段对执行完全无效。
- **建议**：二选一——(a) 让执行侧也消费 `async`（`LoomRunner` 按 `hasAsync(plan) || plan.parallel` 决定派发），(b) 承认 `async` 只是展示位，把 `hasAsync` 改为读 `plan.parallel`，并在 `planJson` schema 里标注 `async` 为保留字段。任一做法都要同步 `doc/loom.md:494-503` 的三级并发开关描述。

### [一般][存量] `FStoreLoomStore.save` 用 7 次独立写且**先写状态头**，崩溃或并发读会得到「新状态 + 旧源码」，重启后按旧计划执行却标 `compiled`

- **位置**：`f_llm/src/loom/FStoreLoomStore.cj:59-68`（`save`，`:61` 先写 `:h`，`:63-66` 才写 `planJson`/`flowSource`/`stepSources`）
- **来源**：存量（`git blame`：整段为 `f170ea26b9` 2026-11-02）
- **判据**：review-checklist §11（资源/写入顺序与一致性）、§12.1（复合操作非原子）
- **证据**：静态确定 —— `save` 是 7 次 `store.add`（`put` → `FStoreLoomStore.cj:129-132`），无事务、无 batch、无版本号；`f_store` 的 `add` 是逐次 WAL append（`f_store/src/Store.cj:97-107`），单键原子、跨键不原子。`LoomService.confirmFlow`（`LoomService.cj:113-115`）先 `compileSteps` 再 `flow.mark(COMPILED)` 再 `registry.put` → 落库
- **描述**：`save` 的写序让「状态」先于「内容」可见。任一次写失败/进程崩溃/并发读卡在两次 `put` 之间，都会出现 `:h = compiled` 而 `:p`（`planJson`）仍是上一版的情况；`LoomBootstrap.startup` 只按 `status == compiled` 重编译（`LoomRegistry.cj:230`），于是**重启后用旧计划当新版本执行，且状态显示编译成功**。同一进程内 `get()` 也是 6 次独立读（`:70-91`），并发 `save` 时会读到混合快照。
- **建议**：把 `:h` 与 `:index` 的写放到最后（内容 → 状态 → 索引），使「可见即完整」；内容字段合并成一次 `StepSourceCodec` 风格的多字段编码一次写入，或在 `:h` 里存一个内容版本号/校验（写内容后回写 `:h`），`get()` 校验不一致就返回 `None` 并打日志。若改成本更低，至少在 `save` 前后 `store.syncWAL()` 并接受「半新半旧」由启动期校验兜底。

### [一般][存量] `DefaultLoomHost.callTool` 把非字符串的工具结果静默降级成空串，流程拿到 `''` 继续跑

- **位置**：`f_llm/src/loom/DefaultLoomHost.cj:42-49`（`match(result.result as JsonString){ case None => '' }`）
- **来源**：存量（`git blame`：`DefaultLoomHost.cj:42-49` 为 `f484d075d4` 2026-11-01）
- **判据**：review-checklist §11（错误处理缺失 / 成功路径静默吞掉非预期结果）
- **证据**：静态确定 —— `FunctionMediator.call` 返回 `FunctionResult`，其 `result` 是 `JsonValue`；`callTool` 只接受 `JsonString`，其余类型（`JsonObject` / `JsonArray` / `JsonInt`）一律返回 `''`，无日志、无异常、无标记
- **描述**：`loomCallTool` 是每条 tool/mcp 步骤的唯一出口（`LoomJitBridge` 把 `loomCallTool` 绑到 `LoomHostApi.callTool`，最终落到本方法）。工具返回结构化结果时，步骤的 `{id.output}` 变成空串，后续步骤与模型都看到「成功但没数据」，而 `LoomHostApi.taskEvent` 会照常把事件推进下去——失败被伪装成空结果。仓内现有工具基本都返回字符串，因此影响面取决于后续是否接入返回对象的工具，属潜在但无告警的失效路径。
- **建议**：`None` 分支改为序列化整个 `JsonValue`（`result.result.toString()`），或在非字符串时返回显式错误文本 `'[loomCallTool] non-string result: ${name}'` 并 warn；只在 `FunctionResult` 明确表示失败时才回空串，并让调用方（`LoomRunner.bodyOf`）把错误文本当步骤失败处理。

### [一般][存量] `LoomBootstrap.startup` 失败路径上的 `registry.put(flow)` 未做保护，写库失败会中断整个启动，违背「单条失败不影响其它」

- **位置**：`f_llm/src/loom/LoomBootstrap.cj:85-89`（`catch` 内 `flow.mark(FAILED)` + `registry.put(flow)`）
- **来源**：存量（`git blame`：`LoomBootstrap.cj:80-89` 为 `4badb23236` 2026-11-06）
- **判据**：review-checklist §11（错误处理缺失 / 异常路径上的二次失败）、§13（与 `doc/loom.md:643` 承诺相反）
- **证据**：静态确定 —— `registry.put` 在锁外直接 `target.save(flow)`（`LoomRegistry.cj:176-186`），`FStoreLoomStore.save` → `store.add` 会抛（`guardOpen()` / 写失败）；而 `LoomBootstrap.cj:85-89` 的 `catch` 块内部没有任何 `try`，因此 `put` 抛出的异常会穿出 `startup`，`LoomWiring.wire`（`LoomWiring.cj:92`）随之失败
- **描述**：设计承诺是「单条失败只把该条标 `failed`，不影响其它流程」（`doc/loom.md:643`、`LoomBootstrap.cj:38`）。实际上数据库不可写时，第一条坏流程就会让整个 `wire()` 抛错——恰好与「库可能比应用晚就绪，恢复失败不阻断启动」的设计目标相反。另外 `catch (e: Exception)` 的 `e` 未使用，失败原因完全不落地（见轻微项）。
- **建议**：`catch` 内用独立的 `try{ registry.put(flow) }catch(error: Exception){ /* 计数 + warn */ }` 包住，失败只累加 `result.failed` 并记录 `flow.name` 与 `error.message`；`ReloadResult` 增加 `failedNames: ArrayList<String>` 供装配日志输出。

### [一般][存量] 三个演进工厂对未知 `llm_metaStore` / `llm_memoryStore` 静默回落 `f_store`，与同仓 `LoomBootstrap.storeFor` 的「未知取值直接抛错」约定相反

- **位置**：`f_llm/src/loom/EvolutionLeases.cj:39-48`（`case _ => FStoreEvolutionLease()`）、`f_llm/src/loom/EvolutionStores.cj:32-38`、`f_llm/src/loom/EvolutionStateStores.cj:31-37`
- **来源**：存量（`git blame`：`EvolutionLeases.cj:39-48` 为 `ca253ca2a4` 2026-11-04，`EvolutionStores.cj:32-38` 为 `01571db6fd`、`EvolutionStateStores.cj:31-37` 为 `11f5d5f106`，均 2026-11-04）
- **判据**：review-checklist §14.1（接线/配置分发）、§11（配置错误静默降级）；`fountain-baseline.md` §4「多实现与注册冲突：启动时选一个实现，不要静默兜底」
- **证据**：静态确定 —— 三个 `byName` 都是 `match(name){ case 'postgres'… case 'mysql'… case 'memory'… case _ => FStoreXxx() }`，`_` 分支不校验、不抛错；同文件族里的 `LoomBootstrap.storeFor`（`LoomBootstrap.cj:48-63`）对未知值 `throw IllegalStateException('unknown loom store: …')`，`doc/loom.md:526` 也明确写着「未知取值直接抛错并列出可用值，不静默兜底」
- **描述**：把 `llm_metaStore` / `llm_memoryStore` 写成 `postgresql`、`my_sql` 之类时，流程存储会启动失败（`storeFor` 抛错），但演进报告表、演进状态、每日租约三族会**悄悄落到 `f_store` 本地文件**：多进程部署下每台机器各拿一份租约（跨进程互斥失效）、演进状态水位线分叉、演进报告写进本地而非库。这些偏差没有任何报错，只有审计时才发现数据不在库里。
- **建议**：三个 `byName` 统一改成与 `storeFor` 相同的白名单 + 未知值抛 `LoomException('unknown evolution store: …; expected f_store|memory|postgres|mysql')`；`fhydra`/`f_hydra` 这类额外取值在文档里列全。抽一个 `MetaStoreFactory.pick(name)` 返回枚举，避免三份 `match` 各写一遍（同时消掉重复逻辑）。

### [一般][存量] `SkillEvolutionTask.evolve` 绕过 A/B 门禁与「无样例不落库」的演进不变量，直接把模型输出写成新版本

- **位置**：`f_llm/src/loom/BackgroundTasks.cj:57-82`（`:78-80` 构造新 `Skill` 并 `store.upsert`）
- **来源**：存量（`git blame`：`BackgroundTasks.cj:57-82` 为 `75396dc966` 2026-11-03）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（承诺了但实现不同）
- **证据**：静态确定 —— `evolve` 只做「标题非空 → 找到技能 → `chat(prompt)` → 非空就 `upsert(version+1)`」，全程没有 `SkillGate.evaluate`、没有 `skill.functions` 里的 `samples` 校验、没有 `SkillEvolutionLedger` 记录；生产链路的 `SkillEvolutionJob` 则是 `SkillGate` + 冷却期 + 报告留档（`SkillEvolutionJob.cj:426` 处才写版本 +1）
- **描述**：`doc/loom.md:299` 把「A/B 门禁」列为演进流程的必经阶段，`doc/loom.md:310` 明确「**没有样例时不落库**——无据可依的演进会污染技能库」；而 `doc/loom.md:203` / `README.md:1034` 又把 `SkillEvolutionTask.evolve` 当作「技能演进」的公开入口推荐。开发者按文档调用它就得到一个绕过全部质量闸门、且不写演进报告的路径：一次模型幻觉就会把技能正文改坏并 +1 版本，`SkillEvolutionJob` 的冷却期/水位线也不会知道这次变更。当前该 API 全仓仅测试引用（生产走 `SkillEvolutionJob`），所以是「文档诱导的误用面」而非在线故障。
- **建议**：要么把 `evolve` 改成内部实现细节（收窄为 `internal`，README/doc 删掉该入口），要么让它走与 `SkillEvolutionJob` 相同的 `SkillGate` + 样例校验 + 报告落库；同时把 `doc/loom.md:203` 的表述改为「底层工具，生产请用 `SkillEvolutionJob`」。

### [一般][存量] `llm_memoryStore=inMemory` 时演进租约选到 f_store，README 承诺的「租约跟随内容族」不成立

- **位置**：`f_llm/src/loom/EvolutionLeases.cj:39-48`（`case 'memory'` + `case _ => FStoreEvolutionLease()`）；对照 `f_llm/src/loom/LoomBootstrap.cj:59`、`f_llm/README.md:764`、`:239`、`f_llm/src/store/InMemoryStores.cj:84`
- **来源**：存量（`git blame`：`EvolutionLeases.cj:39-48` 为 `ca253ca2a4` 2026-11-04）
- **判据**：review-checklist §14.1（配置项未生效 / 接线缺失）、§13（与 README 承诺相反）
- **证据**：静态确定 —— `byName` 先 `trimAscii().toAsciiLower()`，文档值 `inMemory` 变成 `'inmemory'`，match 只列 `'memory'`，于是落到 `_ => FStoreEvolutionLease()`（文件存储）；而内容族的 Bean 条件认的正是 `StringCond.Exactly('inMemory')`（`InMemoryStores.cj:84`），`README.md:764` 写明「`llm_memoryStore` … 内容族 + **租约**：`f_hydra`/`fhydra`/`postgres`/`mysql`/`inMemory`」，`:239` 同。对照组 `LoomBootstrap.storeFor`（`LoomBootstrap.cj:59`）认 `'memory' || 'inmemory'`，三处别名处理不一致
- **描述**：按文档配 `inMemory`（本地演示/单测常见取值）时，记忆在内存、每日租约写在 `./data/f_llm-meta` 的文件里：重启后内存清空但租约还在，技能演进被「上次刚演进过」的冷却判断挡住；多副本部署时每台机器各持一份租约（与 G6 的后果相同，但触发值是文档明确列出的，不需要用户写错）
- **建议**：`EvolutionLeases.byName` 增加 `case 'inmemory'`（与 `storeFor` 共用同一套别名归一，可与 G6 的「统一工厂」一并进行）；补一条 `byName('inMemory') is InMemoryEvolutionLease` 的单测

## 优化可行性方案

### [CPU] `FStoreLoomStore.list` 每页重扫全量索引 + 逐条 6 次 `get`，`restore()` 因此是 O(页数 × N)

- **现状**：`list(offset, limit)`（`FStoreLoomStore.cj:93-113`）每次调用都 `store.prefix(INDEX)` 遍历**全部**流程名 → `sortNames`（插入排序，O(N²) 最坏）→ 再对页内每条 `get()`（`get` 内部 6 次 `store.get`：header + description + planJson + flowSource + questionsJson + stepSources）。`LoomRegistry.restore()`（`LoomRegistry.cj:241-266`）以 100 条一页循环调用，N 条流程共 N/100 页，每页一次全量前缀扫描 → 启动期约 N²/100 次键比较 + N 次 6 键读
- **方案**：`list` 改为接受迭代器续读（把 `store.prefix` 的迭代状态提到调用方），或在 `restore` 里一次性 `prefix` 遍历并流式 `get`，去掉 `offset` 重复扫描；`sortNames` 换 `ArrayList.sort`（若 std 提供稳定排序）或改为按索引键的字典序天然有序（f_store 前缀迭代是否有序需先验证）
- **预期**：启动恢复从 O(N²) 降到 O(N) 次键比较 + O(N) 次 `get`；N=1000 时只省启动期，稳态无影响
- **代价**：`LoomStore` 接口变更（`list` 语义）会波及 `MemoryLoomStore` / `SqlLoomStore` / `PostgresLoomStore` / `MySqlLoomStore` 四个实现；SQL 侧本来有 `LIMIT/OFFSET`，需要保留分页形态
- **验证**：`cjpm bench -O2`，构造 N=100/1000/5000 条 loom 流程的 f_store 目录，测 `LoomBootstrap.startup` 端到端耗时（中位数 + P95，各 10 轮）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CodeGen.flowSource` 在循环里对整串 `+=`，源码生成是 O(步数²) 的字节拷贝

- **现状**：`CodeGen.cj:100-131` 与 `:102-104`、`:111-126` 两组循环都用 `text += '…'` 累积；每步约 200~400 字节源码，第 i 步要复制前 i 步的全部内容。步数 n 时累计拷贝 ≈ n²·len/2。`plan.validate()`（`Plan.cj:94-141`）没有任何步数上限，n 只受模型输出长度约束
- **方案**：改 `StringBuilder`（同仓 `LoomHostApi.render` 已是这个写法，`:89-141`）一次性 `toString()`；或在 `generate` 里预分配 `StringBuilder(capacity: steps.size * 256)`
- **预期**：生成期从 O(n²) 降到 O(n) 字节拷贝；n=200 时拷贝量降两个数量级（按上式估算，未实测）
- **代价**：无（输出字符串完全一致，可用现有 `CodeGen_test` 做等价性回归）
- **验证**：`cjpm bench -O2` 构造 n=20/100/500 步的计划，测 `CodeGen.generate` 耗时；同时断言 `flowSource` 字节级不变
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LoomBootstrap.startup` 串行重编译是启动耗时主项（每条流程一次 `Planner.parse` + `compileSteps`） | `f_llm/src/loom/LoomBootstrap.cj:80-90` | 单条编译耗时、流程数、占启动总时长比例 | 装配期分段计时（`wire` 前后 + 每条 `compileSteps` 前后），N=10/100/1000 条流程各跑 5 次取中位数 |
| 2 | `LoomContextLog` 保留 200 轮完整 `input/output` 是单次执行峰值内存的主要来源之一 | `f_llm/src/loom/LoomContextLog.cj:61,74-90` | 单轮平均字节数、峰值 heapUsed 占比 | 长流程（≥200 轮、单轮输出 ~10KB）跑 `cjprof heap`，对比 `begin()` 前后与 `clear()` 后的 `getUsedHeapSize()` |
| 3 | `CodeGen.flowSource` 的 O(n²) 拼接在真实计划规模（n≤30）下可忽略 | `f_llm/src/loom/CodeGen.cj:100-131` | n=20/100 的实测耗时曲线 | `cjpm bench -O2`，与 `StringBuilder` 版本对照 |
| 4 | f_store 的 `prefix` 迭代顺序是否天然按 key 有序（决定 `list` 能否省掉 `sortNames`） | `f_llm/src/loom/FStoreLoomStore.cj:95-101` | `PrefixIterator` 的顺序保证 | 读 `f_store/src/Store.cj:199` 实现并写用例：乱序写入 1000 个 `f_llm:loom:index:*` 后断言迭代顺序 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/loom/BackgroundTasks.cj` | .cj | ✅ | 见发现 G7（evolve 绕过门禁）、§2 与 `SkillEvolutionJob.cj:426` 同源的版本递增写法、轻微项 M8（未使用 import） |
| 2 | `f_llm/src/loom/BackgroundTasks_test.cj` | .cj | ✅ | 6 条用例；未覆盖 evolve 的空 usage、重复标题、样例缺失三条路径 |
| 3 | `f_llm/src/loom/CodeGen.cj` | .cj | ✅ | 见发现 G1（与 `LoomCompiler` 三份同形模板 + `flowSource` 与 f_egraph 签名不符）、G2（`hasAsync` 只看预览）、轻微项 M7（http 分支不可达）、优化方案 2 |
| 4 | `f_llm/src/loom/CodeGen_test.cj` | .cj | ✅ | 覆盖三类步骤源码与 `AsyncFlow` 选择；未覆盖「预览 vs 执行派发不一致」 |
| 5 | `f_llm/src/loom/DefaultLoomHost.cj` | .cj | ✅ | 见发现 G4（非字符串工具结果静默降级为 `''`）、轻微项 M2（`render` 契约不符） |
| 6 | `f_llm/src/loom/DefaultLoomHost_test.cj` | .cj | ✅ | 用例依赖 `LoomHostApi` 全局绑定，`finally` 里 `unbind`，与其他测试共享全局状态 |
| 7 | `f_llm/src/loom/EvolutionLeases.cj` | .cj | ✅ | 见发现 G6（静默回落）、G8（`inMemory` 别名未识别）、轻微项 M1/M3（无日志、返回值无人消费） |
| 8 | `f_llm/src/loom/EvolutionStateStores.cj` | .cj | ✅ | 见发现 G6、轻微项 M1 |
| 9 | `f_llm/src/loom/EvolutionStores.cj` | .cj | ✅ | 见发现 G6、轻微项 M1 |
| 10 | `f_llm/src/loom/FStoreLoomStore.cj` | .cj | ✅ | 见发现 G3（写序）、轻微项 M4（status/offset 未校验）、优化方案 1 |
| 11 | `f_llm/src/loom/FStoreLoomStore_test.cj` | .cj | ✅ | 往返/覆盖/分页三例；未覆盖崩溃半写、负 offset、非法 status |
| 12 | `f_llm/src/loom/JitTicktockTask.cj` | .cj | ✅ | 见发现 S2（缺宿主绑定 → 定时单步静默失效）、轻微项 M1（异常全吞无日志） |
| 13 | `f_llm/src/loom/JitTicktockTask_test.cj` | .cj | ✅ | 用 `ManualScheduler` 手动触发；测试自己 `LoomHostApi.bind` 后才 fire，掩盖了 S2 的缺绑定问题；未断言异常被记录 |
| 14 | `f_llm/src/loom/LoomAgent.cj` | .cj | ✅ | `nextSeq` 加锁正确；`LoomProgram` 持有 `flowSource`+`stepSources`+`plan` 三份副本（设计如此）；仓内仅 `LoomPromptDesign_test` 引用 |
| 15 | `f_llm/src/loom/LoomBootstrap.cj` | .cj | ✅ | 见发现 G5（失败路径 `put` 未保护） |
| 16 | `f_llm/src/loom/LoomBootstrap_test.cj` | .cj | ✅ | 覆盖恢复/失败标记/未编译拒绝/并发恢复；未覆盖「存储写失败」 |
| 17 | `f_llm/src/loom/LoomCharacterScope.cj` | .cj | ✅ | `install/current/reset` 均在锁内；`current()` 返回值用 `ScopeBox` 带出，无共享路径问题 |
| 18 | `f_llm/src/loom/LoomCompiler.cj` | .cj | ✅ | 见发现 G1（模板源在此）；`compileStep` 的三类分派与 `Plan.validate` 一致（`http` 在 `Plan.cj:126` 已被拒绝，本文件无缺口；`CodeGen` 侧遗留的 http 分支见 M7） |
| 19 | `f_llm/src/loom/LoomCompiler_test.cj` | .cj | ✅ | 5 例覆盖 jit/tool/host-llm/模板拒绝；`FakeHost` 与 `JitTicktockTask_test.CountingHost` 重复 |
| 20 | `f_llm/src/loom/LoomContextLog.cj` | .cj | ✅ | 见发现 S1（单例串台）、轻微项 M6（`BoolValue` 与 `BoolBox` 同构） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分文件清单不含 `.md`；`doc/loom.md`、`README.md` 仅作承诺源取证，不计入本部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 7（S1、S2、G2、G3、G4、G7、G8）、设计 1（G6 配置分发缺统一工厂）、安全性 1（S1，与正确性同一根因，跨用户对话串台）、可读性 2（M1、M6）；语言特性 0：本部分只用了 `synchronized` + Box 带值这一惯用法，已逐个核对（`LeaseTextBox`/`ScopeBox`/`AgentSeqBox`/`TurnsBox`/`BoolValue` 都是同一原因的产物，无捕获可变局部变量问题） |
| §1 死代码 | 3 | 已逐个检查 20 个文件的 `private` / `internal` / `protected` 符号与 `import`：`private` 全部有引用（`CodeGen.firstStep/jsonQuote`、`FStoreLoomStore.put/text/INDEX/DATA/SEP`、`LoomAgent.nextSeq/seq/seqMutex`、`LoomContextLog` 私有三项均被本文件使用）；`internal` 的 `LoomBootstrap.requestOf` 被 `LoomService.cj:111,131` 使用，`StepSourceCodec`（在 `SqlLoomStore.cj`）被本文件使用。命中 3 条：M3（`EvolutionLeases.bootstrap` 返回值被唯一调用点 `let _ =` 丢弃）、M7（`CodeGen` 的 http 分支经 `validate` 后恒不可达）、M8（`BackgroundTasks.cj:18` 未使用 import）。对外可达的 `public`（`MemoryRecorderTask`/`SkillEvolutionTask`/`JitTicktockTask`/`LoomAgent`/`CodeGen`/`FStoreLoomStore` 等）按硬原则一不判死代码，只记「仓内引用面」；`LoomHost.render` 是接口方法且存在实现，属接口契约不判死代码（其「零生产调用」记在 M2 的可见性建议里） |
| §2 重复逻辑 | 2 | 已把 20 个文件里的函数体压成「输入→输出→副作用」摘要两两比对：命中 G1（三份源码模板）与 M6（`BoolValue` vs 同包 `BoolBox`，以及 5 个同构 Box）。已核对差异后**不报**的两组：三个 `EvolutionXxx.byName` 结构相同但返回类型不同（已并入 G6 的「抽统一工厂」建议，不重复计数）；`SkillEvolutionTask.evolve` 与 `SkillEvolutionJob.cj:426` 只共享一句 `Skill(... version+1)` 构造，其余是完整的策略/门禁/留档差异，属业务差异不判重复（漂移风险已在 G7 说明） |
| §3 空实现 | 2 | 无 `TODO`/`FIXME`/`UnsupportedException`/空函数体（`grep` 全 20 文件 0 命中）。命中：4 处 `catch → ()` 静默吞异常（M1，其中 `JitTicktockTask` 有注释与 `doc/loom.md:195` 说明「异常全吞」，故 M1 不按严重计）；S2 的失效机制正是「异常被吞 + 宿主未绑定」，单独按承诺落空记为严重 |
| §4 栈溢出 | 0 | 20 个文件无递归、无自引用结构、无深度遍历；`CodeGen`/`LoomBootstrap`/`FStoreLoomStore` 全为单层或双层 `for`/`while`，深度与输入规模无关 |
| §5 OOM | 0 | 逐个核对无界容器：`LoomContextLog` 有 `MAX_TURNS=200` 上限（`:79-87`）；`FStoreLoomStore.list` 一次只物化页内结果，但 `names` 全量持有全部流程名（与流程数同阶，非请求可控）；`LoomAgent`/`LoomProgram` 持有计划与源码，生命周期与编译产物一致。未发现按不可信长度预分配或全局集合只增不减 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据（`doc/perf-baseline.md` 属模块其他部分，本部分未取到针对这些文件的测量），不构成热点结论；相关线索已写入「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 本部分唯一锁是 `LoomContextLog.mutex`、`LoomCharacterScope.mutex`、`LoomAgent.seqMutex`：临界区内只有内存赋值/克隆，无 I/O、无日志、无序列化、无回调；`LoomHostApi`（范围外）已把渲染移到锁外 |
| §6.3 并发串行 | 0 | `LoomBootstrap.startup` 串行编译、`FStoreLoomStore.list` 逐条 `get` 都是串行段，但没有并发度/耗时数据，不足以判「并发上不去」；已拆到优化方案 1 与待验证假设 1 |
| §6.4 低效算法 | 0 | 结构性 O(n²) 位置有两处（`CodeGen.flowSource` 循环 `+=`、`FStoreLoomStore.list` 每页重扫 + 插入排序），已按「无基线不得写成结论」放进优化方案，不计入发现 |
| §7 降堆内存方案 | 0 | 本部分没有「无界持有多份副本」的形态：7 字段拆键写入是为了避转义（`FStoreLoomStore.cj:40-41` 有说明），`LoomProgram` 的三份源码是审计必需。可降的只有 `LoomContextLog` 的单轮字符串体积，缺峰值数据（待验证假设 2） |
| §8 降 CPU 方案 | 2 | 优化方案 1（`list`/`restore` 分页重扫）、方案 2（`flowSource` 拼接）；均 `无基线`，不进 tasks |
| §9 local mode 可行性 | 0 | 本部分函数内的临时对象都会逃逸（`CodeGen.generate` 返回 `GeneratedFlow`、`FStoreLoomStore.get` 返回 `LoomFlow`、`snapshot()` 返回 `ArrayList`），加 local 标注需先 `exclave`，且收益只能用峰值内存证明——无数据，不成立 |
| §11 现有代码的 BUG（存量） | 11 | S1（生命周期错配）、S2（宿主未绑定 + 吞异常导致承诺落空）、G2（`async` 与派发不符）、G3（写序导致状态/内容不一致）、G4（工具结果静默降级）、G5（失败路径二次抛错）、G6（配置静默降级）、G7（演进绕过门禁）、G8（文档值 `inMemory` 选错租约实现）、M4（status/offset 未校验）、M5（README 机制描述与接线不符）；每条都给了位置与判据，边界/空值/资源/并发四类均已覆盖（S1 另计入 §12、G6/G8 另计入 §14，故本行 11 项 > 报告 10 条存量缺陷） |
| §12 并发安全与锁粒度 | 1 | 已列出全部共享点：`LoomContextLog.turns/active`（S1，缺执行级隔离）、`LoomCharacterScope.installed`（锁内读写，安全）、`LoomAgent.seq`（锁内自增，安全）、`LoomHostApi.*`（范围外，`LoomHostApi.cj:28` 已声明「单线程使用」但无运行时约束——见范围外提示）；`FStoreLoomStore` 无自身可变状态，跨键一致性属 §11（G3）；无锁内 I/O、无锁顺序问题、无 `spawn().get()` |
| §13 文档一致性 | 3 | 本部分无 `.md`；按承诺源交叉核对了 `doc/loom.md` 与 `README.md` 中涉及本部分符号的段落，命中 M5（定时任务机制描述）、G6（「未知取值直接抛错」只对 `storeFor` 成立）、G8（`README.md:764` 的租约取值清单与 `byName` 实现不符）、M7（`doc/loom.md:509` 声明 http 被拒绝，`CodeGen` 注释仍写 http 内联）；`doc/loom.md:231-244` 的 `LoomContextLog` 生命周期描述与实现「单例」不符，已并入 S1 的 §11 判据 |
| §14 功能完备性与 README 覆盖 | 3 | 本部分 public 符号在 `README.md:920-1034` 的 API 清单里均能检索到（`FStoreLoomStore`/`LoomAgent`/`LoomContextLog`/`MemoryRecorderTask`/`SkillEvolutionTask` 等），无「公开 API 未进 README」；命中：S2（`README.md:533` 承诺单步任务由 `JitTicktockTask` 承接，但它没有宿主可绑）、G8（`README.md:764` 承诺租约跟随 `inMemory`，实现落到 f_store）、G7（`SkillEvolutionTask` 与生产演进链路双入口且行为不同）。`recordWithTimeout` 仓内零调用但有文档（`doc/loom.md:202`、`README.md:984`），记为「对外 API，仓内无引用」信息项 |
| 文件覆盖（§13 等） | 20/20 | 本部分文件清单 20 行（全 `.cj`）逐行读完，无跳过；`.md` 清单项为 0 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2（S1 `LoomContextLog` 单例串台；S2 `JitTicktockTask` 缺宿主绑定导致定时单步静默失效） |
| 一般 | 8（G1 三份源码模板 + 落库源码不可编译、G2 `async` 只影响预览、G3 写序、G4 非字符串工具结果降级、G5 失败路径二次抛错、G6 演进工厂静默回落、G7 演进绕过门禁、G8 `inMemory` 租约选错实现） |
| 轻微 | 8（M1 静默吞异常无日志、M2 `LoomHost.render` 契约不符、M3 `EvolutionLeases.bootstrap` 返回值无人消费、M4 `FStoreLoomStore` 反序列化/分页缺校验、M5 定时任务机制描述与接线不符、M6 Box 类型同构重复、M7 `CodeGen` http 分支不可达、M8 未使用 import） |
| 优化方案（堆内存 / CPU） | 0 / 2 |

存量缺陷 10 条（严重 2 / 一般 8）+ 轻微 8 条，均来自工作区快照、无 diff 基线；是否纳入修复由用户在门禁决定，本报告不代拍板。

### 轻微项明细（八条）

- **M1 静默吞异常、失败不可观测**：`EvolutionStores.cj:51-57`、`EvolutionStateStores.cj:45-51`、`EvolutionLeases.cj:65-67`、`JitTicktockTask.cj:48-51` 四处 `catch → ()`，绑定变量一律未用；对照 `LoomBootstrap.cj:73-74` 至少落了 `restoreFailed` 并被 `LoomWiring.cj:94-97` 打成 warn。后果：建表失败、租约获取失败、定时步骤失败在日志里完全无痕。建议统一走 `LoggerFactory.getLogger<…>().warn(...)` 并带 `error.message`（`LoomRunner.cj:243-251` 已有可照抄的写法）。
- **M2 `LoomHost.render` 契约不符**：接口注释（`CodeGen.cj:29`）承诺「把 `{step.output}` 替换成上一步结果」，`DefaultLoomHost.cj:37-40` 原样返回（注释说明真实替换在 `LoomHostApi`）；全仓生产代码没有一处 `host.render(...)` 调用，实际走 `LoomHostApi.render`（`LoomCompiler.cj:109,119`）。建议删除该接口方法（外部实现需同步）或让它委托 `LoomHostApi.render`，避免下游按契约实现却得不到替换。
- **M3 `EvolutionLeases.bootstrap` 返回值无人消费**：`EvolutionLeases.cj:59-69` 用 `LeaseTextBox`（`:72-74`）把租约值带出 `try` 块，唯一调用点 `LoomWiring.cj:134` 写的是 `let _ = EvolutionLeases.bootstrap()`。要么让 `bootstrap` 返回 `Unit` 并删掉 `LeaseTextBox`（省一个类型 + 一次分配），要么在装配日志里打出该值用于确认租约初始值。
- **M4 `FStoreLoomStore` 反序列化/分页缺校验**：`:76` 直接把 `parts[0]` 当 `status` 赋给 `flow.status`，不走 `LoomFlow.mark` 的 `LoomStatus.valid` 校验（`LoomRegistry.cj:61-66`），头部被写坏时会带出 `''`/未知状态并再次落库；`:105-111` 的 `names[index]` 直接用调用方给的 `offset`，负值即下标越界。仓内 `list` 唯一调用方是 `LoomRegistry.restore`（offset 从 0 递增），所以当前不可达，属潜在契约缺口：建议 `offset < 0` 归零、`limit <= 0` 走默认页，`status` 非法时按 `PENDING` 处理并 warn。
- **M5 定时任务机制描述与接线不符**：`README.md:533` 写「JIT 步骤在任务里执行时由 `JitTicktockTask` 承接」，但 `ScheduleCreateFunction`（`ScheduleFunctions.cj:66-93`）注册的任务体是 `service.executeNow(...)`——跑整条流程，`JitTicktockTask.create` 全仓只有 `JitTicktockTask_test.cj` 调用。`doc/loom.md:186` 把它定位成「方式二：只跑某一步」的手动 API 是准确的，README 这句应改成同一口径。
- **M6 Box 类型同构重复**：`LoomContextLog.cj:40-42` 的 `BoolValue` 与同包 `LoomRegistry.cj:86-88` 的 `BoolBox` 完全同构；本部分另有 `LeaseTextBox`（String）、`ScopeBox`（`?Int64`）、`AgentSeqBox`（Int64）、`TurnsBox`（`ArrayList<LlmTurn>`）四处。建议同包内保留一个 `class ValueBox<T> { public var value: T }`（或直接复用 `BoolBox`/`FlowBox` 命名族），减少读者对「这个 Box 有什么特殊语义」的误判。
- **M7 `CodeGen` 的 http 分支恒不可达且注释误导**：`CodeGen.cj:84-88` 注释写「jit / http：素材由计划里的 input 语句片段给出，原样内联」，但 `Plan.validate` 对 `case 'http'` 直接抛「loom step kind http is not implemented yet」（`Plan.cj:126`），`doc/loom.md:509` 也写明「`http` 步骤**尚未实现**，`validate()` 会直接拒绝，不会被当成 `llm` 静默执行」，而 `generate`（`CodeGen.cj:61`）与 `flowSource` 入口都会先 `validate`，所以这段只可能是 `jit`。后果是将来放开 http 时会静默按 jit 语义内联。建议改成 `if (step.kind == 'jit')` 并删掉注释里的 `http`。
- **M8 未使用的 import**：`BackgroundTasks.cj:18` 的 `import std.collection.*` 在文件内无任何集合类型名引用（`store.list()` 的返回值只用于 `for` 迭代），属机械检查命中的未使用 import，删掉即可（同时避免读者误以为这里有集合操作）。

## 总评

本部分代码整体结构清晰：职责切分（`CodeGen` 只产源码、`LoomCompiler` 只编译、`LoomRunner` 原生组装流程、`FStoreLoomStore` 只做键布局）与 `doc/loom.md` 的设计叙述基本一致，出错路径大多有兜底与注释说明，没有 TODO 残留、没有递归、没有无界容器。

阻塞项有两条。第一条是 **`LoomContextLog` 的进程级单例**：它把「一次执行的临时上下文」做成了全局状态，而执行入口（工具调用线程、ticktock 线程、`loomExecute` 嵌套）都没有串行化，后果是记忆提炼丢轮次与跨流程/跨用户内容串台——后者是数据正确性与隐私问题，建议在合并模块报告时列为该模块最高优先级。同一根因在 `LoomHostApi`（范围外）还有一份「单线程使用」的口头约束没有运行时保障，两者应一起改成执行级上下文对象。

另一条是 **`JitTicktockTask` 没有宿主可绑**：`README.md:533` 承诺「JIT 步骤在任务里执行时由 `JitTicktockTask` 承接」，但定时触发时刻 `LoomHostApi` 一定未绑定（只有 `LoomRunner.runCompiled` 会绑），凡是 tool/mcp/llm 步骤或 jit 片段里调用 `loomCallTool`/`loomStore` 的写法都会抛错并被 `catch → ()` 吞掉；更糟的是若有别的流程正在跑，它会借用那条流程的 host。当前生产调度走 `executeNow`（跑整条流程），本类只被测试引用，所以是「照 README 用就会静默空跑」的缺陷，建议要么补绑定+日志，要么删掉入口并改 README。

其次是四条「落库/文档与执行不一致」的问题：`CodeGen` 与 `LoomCompiler` 三份同形模板且 `flowSource` 与 f_egraph 签名不符、`StepPlan.async` 只影响预览（G2）、`FStoreLoomStore.save` 先写状态（G3）、`llm_memoryStore=inMemory` 时租约选错实现（G8）。它们的共同风险是**审计与预览失真**——排查线上 loom 问题时，看到的源码/状态不等于真正跑的东西，这类偏差比崩溃更难定位，建议排期修复。

其余为一致性收敛项（G4、G5-G7、M1-M8），可随演进链路的下一轮重构一起处理；两条 CPU 优化方案没有基线数据，只作为下一轮补测量的入口，不进修复清单。

### 范围外提示（不计入本部分统计）

- `LoomHostApi.cj:28` 用注释声明「约束：单线程使用……（当前 loom 的执行模型是单流程串行）」，但 `LoomService.executeNow` 无任何串行化，`loomExecute` 工具与 ticktock 任务都能并发进入；该文件属同模块其他部分，请与 S1 合并看。
- `LoomRunner.cj:313-315` 有一个空实现的 `release(flow: Flow<EndExecutorGetter>)` 重载，两处调用点（`:275`、`:309`）的静态类型分别是 `ImmediateFlow` / `AsyncFlow`，不会选中这个重载——疑似死代码 + 空实现，建议由覆盖 `LoomRunner.cj` 的部分确认。
- `LoomJitBridge.cj:38` 注释写「幂等：重复安装会覆盖同名函数」，但 `f_jit` 的 `Compiler.registerFunction` 对同名是抛 `DuplicateRegistration`（`f_jit/src/Compiler.cj:70-73`）；当前每次 `LoomCompiler()` 都新建 `Compiler` 实例所以不触发，注释与实际语义不符。
- `Plan.cj:133-140` 只拒绝自环，不拒绝环；配合 `CodeGen.firstStep`（`CodeGen.cj:148-162`）在「所有步骤都有入边」时回落到 `steps[0]`，环计划会让 `registerStart` 指到一个有入边的步骤、`JoinBarrier` 永远等不齐。属 `Plan.cj` / `LoomRunner.cj` 的覆盖范围。
- `LoomTimeout.cj:38-59` 用普通字段 `done/value/error` 做跨线程信号（`spawn` 写、调用方轮询读），无原子/锁；`MemoryRecorderTask.recordWithTimeout`（本部分 `BackgroundTasks.cj:41-45`）是它在本部分唯一相关调用点。可见性问题建议由覆盖 `LoomTimeout.cj` 的部分定级。
