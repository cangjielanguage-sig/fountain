# f_llm 模块审查报告

> **模块第 15/25 部分**。本报告只覆盖 `files/f_llm.part15.txt` 列出的 20 个文件：`f_llm/src/loom/` 下的 10 个实现文件 + 10 个 `_test.cj`（`LoomContextMemory_test.cj` → `LoomStoreGateway.cj`）。模块其余部分、`README.md` / `README_en.md` / `doc/**` 由其它子轮产出；本部分引用的范围外文件（`LoomContextLog.cj`、`Plan.cj`、`Planner.cj`、`Supervisor.cj`、`ScheduleFunctions.cj`、`f_egraph` 等）只作为取证判据，不计入本部分覆盖与统计。

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`，本部分 `src/loom`（20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`HEAD f309f0b55`，`git diff` 为空）⇒ 全部问题记「存量（快照模式无基线）」
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全。本部分不含 LLM 传输层，等价面是 loom 执行链：宿主绑定（`LoomHostApi`）、模板渲染、步骤派发与等待（`LoomRunner`）、流程注册表（`LoomRegistry`）、存储/技能网关（`LoomStoreGateway`）、记忆提炼（`LoomMemoryPolicy`）。
- **报告版本**：v1（第 15/25 部分）

## 发现

### [严重][存量] #1 一次执行的全部上下文都是进程级静态量，`bind`/`unbind` 不校验归属，两个流程并发即互相清空步骤输出、串人格/技能、串记忆归属

- **位置**：
  - `f_llm/src/loom/LoomHostApi.cj:46-49`（`mutex` / `current` / `values` 均为 `private static`）、`:54-59`（`bind` 重建 `values`）、`:61-66`（`unbind` 清空）、`:147-152`（`callTool` 无锁读 `current`）、`:181-209`（`callLlm` 无锁读 `current`，并读 `personaText` / `skillText`）、`:212`、`:235`（`personaText` / `skillText` 静态）、`:262-267`（`taskEvent` 以步骤名写 `values`，不带 flow/tag）
  - `f_llm/src/loom/LoomRunner.cj:216-219`（`LoomContextLog.begin()` 与 `LoomHostApi.bind(host)`）、`:231-237`（`finally` 里 `snapshot` / `clear` / `unbind` / `clearPersona` / `clearSkills`）
  - `f_llm/src/loom/LoomContextLog.cj:51-53`（`turns` / `active` 静态，范围外文件，取证用）
- **来源**：存量（`git blame`：`LoomHostApi.cj:54-58` 为 `182d8196d2 2026-11-02`，`:55` 的 `synchronized` 为 `449f47ac1a 2026-11-07`；`LoomRunner.cj:216-237` 为 `3f87c56345 2026-11-02`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 发布逸出 / 可见性」；§11「并发正确性」
- **证据**：静态确定 —— ① `current` / `values` / `personaText` / `skillText` / `turns` 都是 `private static var`，而 `runCompiled` 每次执行都会 `bind`（重建 `values`）→ 执行 → `unbind` + `clear`，作用域是**进程**而非一次执行，全程没有任何"整轮执行"的锁（`mutex` 只保护单次读写）；② `callTool`（`:148`）与 `callLlm`（`:200`）读 `current` **完全不加锁**，与 `bind`/`unbind` 的锁内写构成 data race——同文件里 `callStore`（`:170-178`）、`currentPersonaText`（`:226-232`）反而都规规矩矩用 `synchronized` 拷贝，说明这两处是遗漏而非设计；③ 入口不唯一：`LoomFunctions.cj:126`（工具调用）、`LoomService.cj:140`（`executeNow` → `LoomRunner.run`）、范围外的 `ScheduleFunctions.cj:86`（定时任务）、`Supervisor.cj:194/227`（路由派发）、`LoomAgent.cj:130`（`runCompiled`）都直达同一条执行链，仓内不存在串行化它们的锁。
- **描述**：`bind` 把 `values` 换成新表、`unbind` 清 `current`、`clearPersona` / `clearSkills` 抹掉人格与技能、`LoomContextLog.begin/clear` 重置临时上下文。A、B 两个流程并发时：B 的 `bind` 清空 A 已产出的步骤输出，A 后续 `{step.output}` 按"未命中保留原样"（`LoomHostApi.cj:71` 的注释语义）把字面量 `{fetch.output}` 送进模型；B 的 `unbind` 让 A 的 `callTool` / `callLlm` 抛 `loom host is not bound`；`personaText` / `skillText` 被对方覆盖 ⇒ A 的 system 里混进 B 的人格与技能正文（跨租户提示词泄漏）；`LoomContextLog` 的快照被先结束的一方整体取走 ⇒ `LoomMemoryExtractor` 把别人的对话写进自己的记忆/知识（`docId` 前缀只带 `userId/namespace`，写错不可自愈）。`LoomHostApi.cj:22-30` 写着"约束：单线程使用"，但该注释贴在 `class TextBox`（`:32`）上方，`LoomHostApi` 类本身没有注释，这条"约束"既不可发现、也没有任何运行期校验。
- **建议**：把"一次执行的上下文"从静态量改成执行期对象（`host` / `values` / `persona` / `skills` / `turns` / `tag`），由 `runCompiled` 创建并沿闭包传参（`LoomJitBridge` 的 `PredefinedFunction` 闭包已可直接捕获，不必改 JIT 源码签名）；静态入口只作兜底，并加一把"进程内只允许一个流程在跑"的锁（`tryLock` 失败直接抛可读异常），把单流程串行从注释变成强制约束。最低限度：`values` 的键带上 `LoomRunner.cj:137` 的 `tag`；`unbind` 前校验 `current` 仍是自己 `bind` 的 host（ABA 保护）；`callTool` / `callLlm` 取 `current` 走锁内拷贝。补并发用例：两个 `runCompiled` 并行、步骤内 `sleep`，断言两边 `{step.output}` 都命中且 system 不串。

### [严重][存量] #2 `parallel=true` 时步骤抛异常：`waiter.get()` 无超时永久阻塞，异常无痕、流程资源不释放

- **位置**：`f_llm/src/loom/LoomRunner.cj:301-311`（`302-305` `flow.start(...)`、`307` `waiter.get()`、`308-310` `finally { release(flow) }`）；语义判据在 `f_egraph/src/base/AsyncDispatcher.cj:75-86`（`get()` 里 `endCondition.wait()` 无超时）、`:116-121`（`asyncExecute` 在 `spawn` 里直接 `executor.accept`，异常不回收）、`:108-115`（End 只由 `notifyEnd` 通知）、`:138-148`（`DummyEvent` 直接 `continue`）
- **来源**：存量（`git blame`：`LoomRunner.cj:300-311` 为 `3f87c56345 2026-11-02`，`try` 包装为 `8633ab3a6e 2026-11-06`）
- **判据**：review-checklist §12.1「异步语义：Future 异常被吞、超时但任务继续跑」；§11「资源不对称 / 错误处理静默」
- **证据**：静态确定 —— `AsyncEndExecutorGetter.get()` 的唯一实现是 `AsyncDispatcher.get()`，等待条件变量且**没有超时参数**（只有 `tryGet(timeout:)` 才有）；End 事件只由 sink 步骤返回的 `EventType.End` 触发 `notifyEnd`。步骤闭包在 `asyncExecute` 的 `spawn` 里执行，抛异常时既不会产生 End 事件，也没有 `registerError` / 错误通道，`waiter.get()` 就没有唤醒源。
- **描述**：`parallel=true` 是 `plan.parallel` 或调用参数显式开启的正常模式（`LoomService.cj:140`）。任意步骤（工具超时、`loomCallLlm` 报错、JIT 片段抛错）抛出后，执行线程永久停在 `waiter.get()`：调用方（LLM 工具请求线程、定时任务线程）被永久占用，`finally` 也永远不会执行（`release(flow)`、`unbind`、`clearPersona`、记忆提炼全部跳过）；同进程后续流程还会命中 #1 的静态量污染。异常本身没有日志，现场只剩线程栈。
- **建议**：改用 `waiter.tryGet(timeout: <执行上限>)`（`AsyncEndExecutorGetter` 已提供），超时抛 `LoomException('loom flow timed out: ${plan.name}')`；步骤侧（`LoomRunner.cj:334-365` 的 `bodyOf`）把 `compiled(e)` 包一层 `try/catch`，转成 error 日志 + 主动 emit `End` 收尾，保证 End 必定触发；`release` / 解绑逻辑保持在 `finally`（现在因为永远到不了 `finally` 而形同虚设，超时路径要确保走到）。补用例：并行计划里让一个步骤抛异常，断言在超时内返回错误而不是挂住。

### [严重][存量] #3 多根 / 不可达步骤的计划：只把 `order[0]` 注册为 start，其余根永不触发；若它们是汇聚点的前驱，并行模式永远等不齐（挂起），同步模式静默少跑步骤

- **位置**：`f_llm/src/loom/LoomRunner.cj:264`（`flow.registerStart(order[0])`）、`:296`（异步同）、`:121-125`（`run` 只校验非空步骤）、`:526-563`（`topologicalOrder` 对多根无提示）；根数/可达性校验缺失处：`f_llm/src/loom/Plan.cj:94-141`（`validate` 只查 id 重复、边端点、自环、kind）
- **来源**：存量（`git blame`：`registerStart(order[0])` 与异步同段为 `3f87c56345 2026-11-02`；快照模式无基线）
- **判据**：review-checklist §11「边界 / 契约与实现不符」；§12.1「条件等待：等待超时后状态未处理」
- **证据**：静态确定 —— `validate()` 不检查"入度为 0 的步骤数"，`topologicalOrder` 会把所有根都放进 `order`，但 `registerStart` 只登记 `order[0]` 一个事件名；`JoinBarrier.release`（`:76-94`）对 `need > 1` 的节点必须凑满 `expected` 次才放行，未到达的分支不会被补偿；`AsyncDispatcher` 对 `DummyEvent` 直接 `continue`（`AsyncDispatcher.cj:142`），因此凑不满的汇聚点不会产出 End。
- **描述**：`Planner` 产出的计划只有"步骤 + 边"，没有任何"必须单根"的约束或提示。计划形如 `a`、`b` 两个根且 `a→d`、`b→d`（`d` 入度 2）时：同步模式 `start(a)` 跑完 a、把事件交给 d、屏障计数 1/2 → 吞掉，b 从未执行，`runSync` 正常返回、`record` 里是 a 的输出（调用方看到"成功"，实际只跑了半个流程）；并行模式 End 永不触发 ⇒ 命中 #2 的永久阻塞。语义上 `FlowPlan.validate` 已经拒绝了 `http` 这类未实现的 kind，说明"拒绝跑不了的形状"是该项目既有的处理原则，多根属于同类漏检。
- **建议**：二选一——(a) `validate()` 增加"恰好一个入度为 0 的步骤，且所有步骤从它可达"的检查，不满足直接抛 `LoomException`（配合 Planner 提示词约束）；(b) 支持多根：把所有根都 `registerStart`，并在 `start` 时对每个根各投一次起始事件（`AsyncFlow` / `ImmediateFlow` 都支持多 start 名，`registerTask` 的"首个任务必须同名"校验可逐根满足）。无论哪种，都要为 `JoinBarrier` 加超时兜底，避免"少一个前驱"变成永久等待。

### [一般][存量] #4 `LoomExecuteParam.dryRun` 承诺"只预览不编译"，但从未接线：模型传 `dryRun=false` 仍然只预览

- **位置**：`f_llm/src/loom/LoomFunctions.cj:71-72`（`@JsonStringSchema[description:'"true" 时只预览不编译（默认）；预览返回计划与闭包原文'] private var dryRun`）、`:110-121`（`confirm=false` 分支构造 `LoomRequest` 时未传 `dryRun`）；`LoomRequest.dryRun` 在 `f_llm/src/loom/Planner.cj:35/46/60` 只被赋值，`Planner.plan` 无读取点
- **来源**：存量（`git blame`：`LoomFunctions.cj:118-120` 为 `716e648239 2026-11-01`）
- **判据**：review-checklist §1「读了不用（配置项 / 字段赋给局部变量后再无使用）」；§14.1「配置项被读取却从未使用」
- **证据**：静态确定 —— 全仓 `grep dryRun` 只有 4 处：本例字段声明、`Planner.cj` 的 `LoomRequest.dryRun` 声明/赋值、`Supervisor.cj:212` 显式传 `dryRun: false`；`LoomExecuteFunction.call` 里没有任何地方读 `params.dryRun`（`@DataAssist[props fields]` 生成的 prop 也无人读）。
- **描述**：`LoomExecuteParam` 是给模型看的 JSON schema，`dryRun` 的描述明确写了"true 时只预览不编译（默认）"，暗示 `false` 会编译。实际 `call()` 只按 `confirm` 分支，`dryRun` 被静默丢弃：模型按 schema 传 `dryRun=false` 期望编译，得到的是"pending + 源码预览"，而工具返回里没有"该参数被忽略"的提示，模型会误判流程已就绪。
- **建议**：要么把 `dryRun` 接入（`confirm=false && dryRun=false` → 直接 `confirmFlow`，或把它传进 `LoomRequest` 并让 `Planner` / `CodeGen` 消费），要么从 schema 删除该字段并把 description 改为只讲 `confirm`；`LoomRequest.dryRun` 若确实无人消费，也一并处理（它在范围外的 `Planner.cj`，本报告只提示）。

### [一般][存量] #5 `memory.list` 多 kind 分页：每个 kind 各取 `offset+limit` 再拼接，单页可返回 2×limit，分页契约被破坏

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:147-174`（`149` `kindsOf`、`150-151` `offset` / `limit`、`157-161` 每个 kind 各调一次 `listByKind(userId, ns, kind, offset, limit)`、`162` `merged`）；`kindsOf` 的默认双 kind 见 `:384-400`（`experience` → `experience` + `experience_failed`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；§6.4「同一输入重复取数」
- **证据**：静态确定 —— `wanted` 有 2 个元素时循环执行两次 `listByKind(..., offset, limit)`，`merged` 最多 `2 × limit` 条；`offset` 分别作用在每个 kind 上，而不是作用在合并结果上。KDoc（`:34`）承诺的是 `memory.list {"userId","namespace","offset","limit"}` → 记录数组，未说明"每 kind 各自分页"。
- **描述**：`experience` 走默认双 kind 时，`limit=50` 的"一页"实际最多返回 100 条；调用方按 `offset += limit` 翻页时，页边界不再对应合并序（每个 kind 各自从自己的 offset 起算），合并结果按 kind 分组（先全部 `experience` 再全部 `experience_failed`）也不是时间序。流程里若把 `{list.output}` 拼进上下文，会把两倍的记录塞进模型输入。
- **建议**：分页口径二选一并写进 KDoc：① 单 kind 单页（`kind` 必填，缺省报错），② 合并后在网关内排序再按 `offset/limit` 切（需要 Store 提供 `listByKinds`，或先取全量——只在上限可控时可行）。当前实现至少要把 `listByKind` 的 `limit` 改成 `offset + limit` 后合并切片，并补一条"2 个 kind、limit=10、翻三页无重复无遗漏"的用例。

### [一般][存量] #6 `skill.upsert` 主键分配是 check-then-write：并发 upsert 撞同一个 id，后者静默覆盖前者

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:249-272`（`251-260` 全量 `meta.skills.list()` 求 `maxId` 后 `targetId = maxId + 1`、`:262-271` `upsert`）；并发入口：`f_llm/src/loom/StoreFunctions.cj:85-92`（工具层直接 `gateway.call`）、`LoomJitBridge.cj:50-54`（JIT 步骤的 `loomStore`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「检查-然后-写入」（容器线程安全不代表组合操作原子）；§11「并发正确性」
- **证据**：静态确定 —— `list()` 与 `upsert()` 之间没有任何锁或版本校验，"读 max → +1 → 写"是典型的非原子组合操作；`SkillCatalog` / `SkillEvolutionJob`（范围外）与流程内的 `loomStore('skill','upsert',…)` 是同一条链路。
- **描述**：两个请求同时新建技能（`id<=0`）时拿到同一个 `maxId+1`，第二个 `upsert` 覆盖第一个：技能正文、`functions`、`version` 一起丢失，且没有任何报错。技能演进是后台任务（会写 `upsert`），与前台工具调用天然并发。
- **建议**：把 id 分配下沉到 Store（`skills.nextId()` / 自增列 / `upsert` 返回分配结果并在存储侧保证唯一），或在网关内用一把 `Mutex` 包住"读 max + 写"（技能写入频率低，粗锁可接受，但要在注释里写明原因）。同时把 `count`（`:218-220` 的 `list().size`）换成 Store 的计数接口。

### [一般][存量] #7 `intOf` 把"缺字段 / 非法值"一律折成 0：`userId=0` 的记忆写进共享桶、`remove(id=0)` 静默失败、`evolution.list` 不传 limit 返回空

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:420-434`（`424` `value.toString()`、`425-430` Int64→Float64→`0`、`:432` 缺键 `0`）；使用点 `:134`（`userId`）、`:142/210`（`id`）、`:150-151`（`offset/limit`）、`:182`（`topK`）、`:346`（`evolution.list` 的 `limit`）；对照 `:402-410`（`pageOf` 对 `knowledge`/`memory` 做了默认值兜底，`evolution` 没有）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「空集合 / 空串 / `None` 未处理」「错误处理缺失或静默」
- **证据**：静态确定 —— `intOf` 的失败路径直接返回 `0`，调用方没有任何 `isNone` 判别；`memory.add` 用 `userId` 直接构造 `MemoryWrite`（`:137-139`），网关不校验 `userId > 0`；`evolution` 分支（`:345-355`）没有走 `pageOf`。
- **描述**：模型漏写 `userId` 时，记忆被写进 `userId=0` 的公共命名空间（多租户串数据，且后续按真实 userId 检索不到）；`memory.remove` 漏 `id` 时删的是 0 号记录并返回 `false`，调用方无法区分"不存在"和"参数错"；`evolution.list` 不传 `limit` 时 `limit=0` → 返回 `[]`，与"缺字段按默认 50"（`pageOf` 的注释）不一致。
- **建议**：`intOf` 换成 `?Int64`，必填键（`userId`、`id`、`docId`）缺失即抛 `LoomException('loom store gateway: <kind>.<op> requires <key>')`；可选键统一走 `pageOf` 风格的默认值；`evolution.list` 复用 `pageOf`。补用例：缺 `userId` 的 `memory.add` 必须报错而不是写 0 号桶。

### [一般][存量] #8 注册表内存态与持久化非原子：`put` 先改内存再 `save`、`remove` 先删内存再删库，任一步抛错就分叉

- **位置**：`f_llm/src/loom/LoomRegistry.cj:175-183`（`put`：`176-178` 写 `flows`、`179-182` `store.save`）、`:193-208`（`remove`：`195-200` 删内存、`201-206` `store.remove`，返回值被丢弃）、`:241-266`（`restore` 只做合并、不清理旧值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称 / 错误处理缺失」；§12.1「有界性与一致性」
- **证据**：静态确定 —— `put` 的两步不在同一个事务/补偿逻辑里，`store.save` 抛异常时内存已更新；`remove` 同理，且 `target.remove(name)` 的 `Bool` 被忽略（存储侧没删掉也算成功）。
- **描述**：`store.save` 失败（DB 断连、约束冲突）时，`LoomService.execute` 抛出异常并告诉模型"失败"，但注册表里已经有了这条 `pending` 流程——本进程内可见、重启后消失，行为随进程重启而变。`remove` 失败时更危险：内存删了、`Supervisor.untap` 摘了路由（`LoomService.cj:143-148`），但库里还留着 `compiled` 记录，重启 `restore()` 后流程复活且没有路由。
- **建议**：先落库再改内存（`save` 成功才 `flows[name] = flow`），失败直接抛出，保证"内存是库的缓存"；`remove` 先删库、成功后删内存；`restore` 改为"清空后重建"并在 KDoc 注明"仅启动期调用一次"，避免运行期调用把旧流程混进来。

### [一般][存量] #9 `LoomRegistry.get` / `compiledFlows` 把内部可变 `LoomFlow` 直接交出去：调用方在锁外读改写，`status` 无同步

- **位置**：`f_llm/src/loom/LoomRegistry.cj:185-191`（`get` 锁内取引用、锁外原样返回）、`:219-238`（`compiledFlows` 把同一批引用装进结果）、`:102-114`（`MemoryLoomStore.get` 同样返回内部引用）；使用点 `f_llm/src/loom/LoomService.cj:107-118`（`flow.mark(COMPILED)` + `registry.put(flow)`）、`:124-140`、`:150-154`（`status()` 读 `flow.status`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「发布逸出 / 迭代与修改并发」；§11「并发正确性」
- **证据**：静态确定 —— `LoomFlow` 的 `status` / `stepSources` / `planJson` 都是 `public var`，注册表的锁只保护 `HashMap` 本身；`confirmFlow` 的"取 → 编译 → `mark` → `put`"整段在锁外，`status()` 在另一线程读同一个 `String` 字段。两个并发 `confirmFlow` 会对同一实例各编译一遍、各自 `mark` + `put`，`status()` 可能读到编译前后的中间态。
- **描述**：这是"锁保护了容器却保护不住容器里的对象"的典型形态。除并发外还有语义问题：任何持有 `get()` 结果的调用方（工具层、`Supervisor`、测试）都能改 `status` / `description` 而绕过 `mark()` 的合法性校验（`LoomFlow.mark` 才是唯一校验点）。
- **建议**：`LoomFlow` 改成不可变 + 显式状态迁移（`withStatus(next)` 返回新实例，注册表在锁内替换），或 `get()` 返回快照（拷贝 `stepSources` 等可变容器）；`confirmFlow` 的整段状态迁移放进注册表提供的 `update(name) { flow => ... }` 原子操作里。至少要把 `LoomFlow` 的字段收窄为 `public let` + 受控 `mark`。

### [一般][存量] #10 `LoomService.execute` 同名直接覆盖：已编译流程被一次预览静默替换，源码与状态一起丢

- **位置**：`f_llm/src/loom/LoomService.cj:71-103`（`77` / `90` 直接 `LoomFlow(request.name, …)`、`83` / `98` `registry.put(flow)`）；`f_llm/src/loom/LoomRegistry.cj:175-183`（`put` 是覆盖语义、无 `contains` 检查）；`f_llm/src/loom/LoomFunctions.cj:61`（`name` 仅由模型填写）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；fountain-baseline §4「同名注册：启动直接失败，不做隐式优先级」
- **证据**：静态确定 —— `put` 无条件赋值；`execute` 不查 `registry.get(name)`，也不比较 `round` / 描述。`name` 是 LLM 从自然语言里生成的字符串（`LoomExecuteParam.name` 的描述只有"流程标识，全局唯一"），重名成本极低。
- **描述**：模型重复调用 `loomExecute`（重试、同一任务换个说法）时，已 `compiled` 的流程被新 `pending` 覆盖：旧 `stepSources` 丢失、`Supervisor.tap` 把路由状态改回 `pending`，正在跑的实例不受影响但新派发会按 `pending` 处理（`Supervisor.cj:116-124` 只转 status，具体分支待确认）。表现为"昨天能跑的流程今天说没编译"。
- **建议**：`execute` 在 `name` 已存在且状态为 `compiled` 时拒绝覆盖（抛 `LoomException('loom flow already compiled: ${name}')`）或要求显式 `force` 参数；`pending` 覆盖时保留旧 `round` 并在返回里说明"已替换"。`LoomRegistry.put` 提供 `putIfAbsent` / `replace(name, expectedStatus: …)` 供调用方选择语义。

### [一般][存量] #11 `LoomStoreGateway` 的 op 契约表与实现不符：表头写"未列出的 op 一律抛 `LoomException`"，实际支持 5 类未列出的能力

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:25-44`（KDoc 表 + `43` 的"未列出的 op 一律抛"）、实现 `:214-273`（`skill.load` / `skill.upsert`）、`:275-319`（`prompt.get/latest/put/remove`）、`:321-337`（`character.get/set/reset`）、`:339-356`（`evolution.list/by_skill`）；实际调用方 `f_llm/src/loom/LoomRunner.cj:389`（`prompt.latest`）、`:428`（`character.get`）、`:473`（`skill.load`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」；§14.2「公开 API 未文档化」
- **证据**：静态确定 —— 表里只有 `knowledge` / `memory` / `skill`（`get/list/count/remove`）/ `experience`；`prompt`、`character`、`evolution` 三类和 `skill.load/upsert` 在实现里都有，`LoomRunner` 自己也依赖 `prompt.latest` / `character.get` / `skill.load`。
- **描述**：网关是 `loomStore` 与 `StoreFunctions` 的唯一入口，KDoc 表是模型和开发者写 JIT 片段时的唯一参考。按表理解，"未列出的 op 一律抛"意味着 `prompt.latest` 不可用，而实际上这条路径是人格解析的主链路（`LoomRunner.resolvePersona`）。反过来，`character.set/reset`、`prompt.put/remove` 这些会改数据的 op 没有任何文档说明权限与副作用。
- **建议**：补齐 KDoc 表（含 `skill.load` 的 `title` 键、`skill.upsert` 的 id 分配规则、`prompt.put` 的版本递增、`character` / `evolution` 全量 op），并把"未列出的 op 抛错"改成"未列出的 op 抛错（当前实现见下表）"避免自相矛盾；`evolution` 只读这一点值得写进表里（`:344` 的注释已说明理由）。

### [一般][存量] #12 注册表 `flows` 只增不删：每次 `loomExecute` 落一条含 `planJson` + `stepSources` 的记录，无 TTL / 上限

- **位置**：`f_llm/src/loom/LoomRegistry.cj:167-168`（`flows` 普通 `HashMap`）、`:175-183`（只 `flows[flow.name] = flow`）、`:193-208`（只有显式 `remove` 才减）；写入驱动 `f_llm/src/loom/LoomService.cj:83/98/115`；删除入口只有 `LoomFunctions.cj:191` 的 `loomDelete`（需要模型主动调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器：全局 `HashMap` 随请求增长，GC 后条目仍在」
- **证据**：静态确定（增长无界）；量级需实测 —— 单条 `LoomFlow` 持有 `planJson`（每步 1 段 JSON）+ `stepSources`（每步一段源码）+ `description` / `tools` / `mcps`，按 5 步流程估 3~8 KB；10 万条即 300~800 MB，且没有淘汰路径（`clear()` 语义不适用）。增长速率取决于调用量与 `name` 的唯一性。
- **描述**：`clarifying` / `pending` 流程是"半成品"，正常业务里被 `compiled` 覆盖或删除，但失败、放弃、模型换名字重试都会留下死记录；`compiled` 流程也只在显式 `loomDelete` 时才释放。长跑进程（fboot 常驻）里这是一条线性增长的堆占用，且 `restore()` 每次重启还会把库里的全量读回内存。
- **建议**：给注册表加有界策略——按 `status` 分桶：`clarifying/pending` 设 TTL（例如 24h 未确认即清理），`compiled` 设条数上限（LRU 或按 `lastUsed`）并落库保留；`restore()` 只加载 `compiled`（`pending` 源码已无意义）。补一条 10 万条 `put` 后的 `usedHeap` 对照，作为"是否真的需要上限"的判据。

### [轻微][存量] #13 死代码：`release(Flow<EndExecutorGetter>)` 空重载无调用者、`LoomMemoryPolicy` 未使用的 `f_log` 导入、`buildCount` 仅测试可见

- **位置**：
  - `f_llm/src/loom/LoomRunner.cj:313-315`（`private static func release(flow: Flow<EndExecutorGetter>): Unit { () }`）
  - `f_llm/src/loom/LoomMemoryPolicy.cj:22`（`import fountain::f_log.*`，全文件无 `Logger` / `LoggerFactory` 使用）
  - `f_llm/src/loom/LoomStoreGateway.cj:46-51`（`static var buildCount` + `static func resetBuildCount`，`:61/69` 自增）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者 / 未使用的 import / 仅测试使用」
- **证据**：静态确定 —— `release(` 在 `LoomRunner.cj` 只有 `:275`（`ImmediateFlow`）与 `:309`（`AsyncFlow`）两个调用点，均精确匹配到同名具体重载，泛型重载零调用；`buildCount` / `resetBuildCount` 全仓只在 `LoomStoreGateway_test.cj:119-123`、`LoomWiringGateway_test.cj:43-61` 出现。
- **描述**：泛型 `release` 不仅没人调用，还是**空实现**——与另外两个真正 `flow.remove()` 的重载放在一起，读者会以为"泛型路径故意不释放"，实际只是重载解析不到的历史残留。`f_log` 导入让读者以为该文件会打日志（它的 `catch` 分支全是静默 `()`）。`buildCount` 是包内可见的测试计数，两个构造函数无条件自增，本身无锁（测试单线程时无碍）。
- **建议**：删除泛型 `release` 重载（或合并成一个接收 `BaseFlow` 的实现，因为 `remove()` 在 `BaseFlow` 上就有）；删 `f_log` 导入；`buildCount` 改名 `testBuildCount` 并在 KDoc 注明"仅测试"，或改为返回给测试的可选计数器。

### [轻微][存量] #14 重复逻辑：三份 `fieldOf/strOf`、三份 `Any→String`（语义已漂移）、两个逐行相同的 `release`、`execute` 两个分支的装配代码

- **位置**：
  - JSON 取字符串：`f_llm/src/loom/LoomMemoryPolicy.cj:241-249`、`f_llm/src/loom/LoomRunner.cj:492-500`、`f_llm/src/loom/LoomStoreGateway.cj:369-377`（后者名 `strOf`）
  - `Any→String`：`f_llm/src/loom/LoomHostApi.cj:278-286`（`String` + `Int64`）、`f_llm/src/loom/LoomRunner.cj:460-466`（只认 `String`）、`f_llm/src/loom/LoomJitBridge.cj:57-65`（只认 `String` + 下标保护）
  - 释放流程：`f_llm/src/loom/LoomRunner.cj:317-323` 与 `:325-331`（仅参数类型不同）
  - 流程装配：`f_llm/src/loom/LoomService.cj:77-86` 与 `:90-102`（`round` / `tools` / `mcps` / `put` / `Supervisor.tap` 各写一遍）
  - 手写 JSON 数组：`LoomStoreGateway.cj:119-129`、`:164-173`、`:192-207`、`:228-238`、`:451-466`、`:479-490`，`LoomService.cj:168-179`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名 / 字面量复制 / 跨层复制」
- **证据**：静态确定 —— 三份 `fieldOf` 逐行同构（`json.get(key)` → `as JsonString` → `text.value` 否则 `''`）；三份 `textOf` 的差异是**语义**差异（`LoomHostApi` 认 `Int64`，另外两处遇到数字返回空串），属于"实现漂移"而非纯复制；两个 `release` 除形参类型完全一致；两个 `execute` 分支的 5 个字段赋值与两次副作用调用一致。
- **描述**：`fieldOf` 三份意味着"JSON 字符串字段的缺失语义"有三个独立演进点；`textOf` 的差异已经造成不一致——`LoomHostApi.taskEvent` 会把 `Int64` 步骤输出记成十进制串，而 `LoomRunner.taskTextOf` 遇到同样的 `Int64` 起始数据得到空串（自动技能检索拿不到任务文本）。手写 JSON 数组的 7 处都依赖 `FlowPlan.jsonQuote` 做转义，目前正确，但只要有一处改用字符串插值就会产生非法 JSON。
- **建议**：在 `f_llm/src/loom` 内提一个包内工具 `LoomJson`（不新建共享包）：`str(json, key)`、`text(any)`（明确是否支持数字）、`array(items, render)`；`release` 合并成一个接收 `BaseFlow` 的函数；`execute` 的两个分支抽成 `storeFlow(flow, plan, status)`。合并前先把 `textOf` 的语义差异参数化（`allowNumber: Bool`），否则是"统一即回归"。

### [轻微][存量] #15 `LoomDefaults.chat` 在响应没有 `AssistantMessage` 时静默返回空串，多段时只留最后一段

- **位置**：`f_llm/src/loom/LoomDefaults.cj:45-52`（`var text = ''`；`for` 里 `match(item as AssistantMessage)` 覆盖赋值；无匹配则原样返回）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」；§3「`case None => ()` 当兜底把错误吃掉」
- **证据**：静态确定 —— 空串会一路传给 `Planner` / `CodeGen` 的调用方（`LoomWiring.cj:67` 的零配置装配），表现为"模型没返回任何内容"而不是"响应结构异常"。
- **描述**：这是"零配置能用"的门面（README 明确指向 `LoomDefaults.chat`）。上游返回工具调用消息、空 `messages`、或纯 `ToolMessage` 时 `text` 为空，规划阶段会得到空计划并以"模型没给 JSON"的形式失败，排查方向被误导到提示词而不是响应解析；多段 assistant 内容（分段流式/多候选）只保留最后一段，前面的内容静默丢弃。
- **建议**：无 `AssistantMessage` 时抛 `LoomException('loom default chat: no assistant message in response')`；多段时按顺序拼接（或取第一段并在 KDoc 说明理由）。

### [轻微][存量] #16 `LoomMemoryExtractor.extract` 的返回契约写"0~2"（实际可为 3），且知识写入失败被完全吞掉

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:107`（`@return 写入条数（0~2）`）、`:140-167`（`written` 在 note、experience、knowledge 三处 +1）、`:160-165`（`knowledge` 分支 `catch (error: Exception) { () }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「注释与实现不符」；§3「静默吞掉异常」
- **证据**：静态确定 —— `writeKnowledge=true` 时最多 3；`LoomRunner.cj:241-246` 只在 `written == 0` 时 warn，知识单条失败不影响 `written`，因此"配置了写知识但一条没写"没有任何日志。
- **描述**：`write()`（`:183-199`）失败时返回 `false`，注释解释了"存储未装配时不影响流程结果"，属于有意的降级；知识分支连返回值都没有，`catch` 里只有一个 `()`，与记忆分支的"失败→false→计数"不对称。运维视角下 `writeKnowledge` 打开后长期不生效无法发现。
- **建议**：KDoc 改成 `0~3` 并说明各条来源；知识分支 `catch` 里至少 `LoggerFactory.getLogger<LoomMemoryExtractor>().warn(...)`（该文件已导入 `f_log`，正好可用）；或把三处写入统一成 `(ok: Bool, kind: String)` 列表返回，让调用方决定日志级别。

### [轻微][存量] #17 状态用字符串字面量而非 `LoomStatus` 常量；`LoomHostApi` 的"单线程使用"约束注释贴错对象

- **位置**：`f_llm/src/loom/LoomService.cj:43`（`status == 'clarifying'`）、`:86` / `:101`（`LoomResult('clarifying' / 'pending')`）、`:118`（`'compiled'`）、`:150-154`；常量定义 `f_llm/src/loom/LoomRegistry.cj:26-33`（`LoomStatus.CLARIFYING/…`）；注释错位 `f_llm/src/loom/LoomHostApi.cj:22-34`（"约束：单线程使用"紧贴 `class TextBox`，`LoomHostApi` 无类注释）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「语言特性 / 可读性」；§13「文档与代码一致性」
- **证据**：静态确定 —— `LoomStatus` 提供常量与 `valid()`，`LoomFlow.mark` 用它校验，但 `LoomResult.status` / `needsClarification` / `status()` 全部用字面量；`LoomHostApi.cj` 的类文档被写在 `class TextBox` 前，`LoomHostApi` 自身只有成员级注释。
- **描述**：状态字符串是"编解码契约"（`llm_loom_flow.status` 落库、`Supervisor.register(status:)`、工具返回值），字面量散落意味着改名时编译器帮不上忙，也容易出现 `'clarify'` / `'clarifying'` 这类拼写漂移（当前 `needsClarification` 与 `CLARIFYING` 靠人工对齐）。注释错位使"单线程使用"这条最重要的运行约束在读 `LoomHostApi` 时看不到——直接放大了 #1。
- **建议**：`LoomService` / `LoomResult` 全部改用 `LoomStatus.*`；`LoomStatus` 增加 `prop isTerminal` 之类的判定集中语义；把单线程约束的注释移到 `LoomHostApi` 类声明前，并补一句"并发执行由 `LoomRunner` 串行化（见 …）"或改为运行期校验（见 #1）。

### [轻微][存量] #18 进程级单例 `LoomServices` / `LoomSchedules` 的 `install` / `reset` 无同步，与同模块其它单例的写法不一致

- **位置**：`f_llm/src/loom/LoomFunctions.cj:28-55`（`installed` / `host` 静态，`install` / `installHost` / `reset` 直接赋值，`current` 直接读）、`f_llm/src/loom/LoomScheduler.cj:53-70`（同形态）；对照 `LoomHostApi.cj:46` / `LoomMemoryPolicy.cj:74`（都有 `Mutex`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」
- **证据**：待确认 —— 现状静态确定（无锁读写 `?T` 静态字段），但 `install` 是否只发生在启动装配期、`current` 是否只读，需要看 `LoomWiring` 的调用时机；若严格"启动装一次、之后只读"，风险降为可见性理论问题。
- **描述**：`LoomServices.install` 在测试里被反复调用（`LoomFunctions_test.cj:50/61` 等），生产侧若出现"运行期重装"（例如 `LoomWiring` 被多次触发），读到 `None` 的窗口会让 `loomExecute` 静默降级成"service not installed"字符串返回（`LoomFunctions.cj:103-107`），而不是报错。
- **建议**：与 `LoomMemoryPolicy` 统一——`private static let mutex` + 锁内赋值/锁内拷贝；或者把这两个单例改成"只能装一次"的幂等语义（第二次抛错）。

### [轻微][存量] #19 测试卫生：`LoomServiceSkills_test` 用桩网关覆盖全局 store 而不复位、`bind` 后不 `unbind`；`LoomPromptDesign_test` 改进程级 Http 超时并依赖 `/tmp`；`LoomRenderPerf_test` 名为 Perf 实为功能用例

- **位置**：`f_llm/src/loom/LoomServiceSkills_test.cj:68`、`:96`（`finally` 里 `LoomHostApi.installStore({ kind, op, payload => '[]' })` 而不是 `resetStore()`）、`:63`、`:90`（`LoomHostApi.bind(host)` 后没有 `unbind`，靠 runner 的 `finally` 兜底）；`f_llm/src/loom/LoomPromptDesign_test.cj:81-85`（`HttpClient.globalReadTimeout/globalWriteTimeout` 改进程级配置，`static var timeoutsReady` 无同步）、`:65-71`、`:185-190`（读写 `/tmp`）；`f_llm/src/loom/LoomRenderPerf_test.cj:24-84`（类名与注释都指向性能，内容全是功能断言）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.1「没有测量数据不能当基线」；§12.1「共享可变状态」在测试进程内的同类问题
- **证据**：静态确定 —— `LoomHostApi.storeGateway` 是进程级静态量；桩函数永远返回 `'[]'`，后续用例若没重新 `installStore`，会拿到"任何检索都为空"的假数据而不是"未装配"的报错（`callStore` 的 `None` 分支才会抛 `loom store gateway is not installed`）。
- **描述**：按类/方法顺序跑测试时，`LoomServiceSkills_test` 之后执行的用例会拿到假网关；`bind` 未 `unbind` 的窗口里若用例失败（异常跳过 runner 的 `finally` 之前），后面的用例会看到过期宿主。`LoomPromptDesign_test` 把全局读超时改成 300s，影响同进程所有 HTTP 用例（含失败重试用例的时长预期）。`LoomRenderPerf_test` 的类名会让人误以为有渲染性能基线（本报告 §6.1 因此明确不引用它）。
- **建议**：`finally` 统一 `LoomHostApi.resetStore()` / `unbind()`；`LoomPromptDesign_test` 的全局超时改成构造期注入或 `finally` 恢复原值；`LoomRenderPerf_test` 改名（如 `LoomRender_test`）或补真正的 bench 用例。

## 优化可行性方案

> 都不是缺陷，是"还能更好"。全部缺改前基线，故一律 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] 复用 `confirmFlow` 编译出的步骤闭包，避免 `executeNow` 二次 parse + 二次 JIT

- **现状**：`confirmFlow`（`f_llm/src/loom/LoomService.cj:106-119`）调 `compiler.compileSteps(target)` 后**丢弃返回值**，只把状态标成 `compiled`；`executeNow`（`:122-141`）重新 `Planner.parse(flow.planJson)` + `LoomRunner.run`（`LoomRunner.cj:126` 再 `compileSteps`）。"确认 + 立即执行"这条主链路（`LoomFunctions.cj:123-133`）每次执行都要重新解析计划并重新编译全部步骤。
- **方案**：`LoomService` 持有 `HashMap<String, (planJsonHash, HashMap<String, (Event)->Event>)>` 缓存（键 = `flow.name` + `planJson` 的内容哈希），`confirmFlow` 填入、`executeNow` 命中则走 `runCompiled`（`LoomRunner.cj:131` 已支持），`delete` 时清除；缓存容量与 `LoomRegistry` 同步有界。
- **预期**：省掉每次执行的一次 JSON 解析 + N 次 JIT 编译；收益取决于编译耗时占端到端比例（未测，不给百分比）。
- **代价**：缓存与源码一致性风险（`LoomRegistry` 的 KDoc 明确说"不缓存编译产物——`JitFunction` 与源码可能不一致"，因此必须按内容校验而不是只按 name）；内存随流程数增长，必须与 #12 的上限一起做。
- **验证**：`cjprof record` 跑 5 步流程 × 100 次（host 用 `RunnerHost`，不调真实模型），对比 `run` 与 `runCompiled` 的 self time；`cjpm bench -O2` 给中位数与离散度。
- **证据状态**：`无基线（待验证）`

### [CPU] 拓扑排序与注册表列举的 O(n²) 结构

- **现状**：`LoomRunner.topologicalOrder`（`LoomRunner.cj:526-563`）用 `ready.remove(at: 0)` 当队列，每步 O(n) 搬移；`MemoryLoomStore.list`（`LoomRegistry.cj:116-134`）与 `LoomRegistry.compiledFlows`（`:219-238`）每次调用都先全量收集名字再插入排序（`sortNames`，`:147-157`，O(n²)）。
- **方案**：`ready` 换成索引游标（`var head = 0`，`while (head < ready.size)`）或双端队列；列举改为维护有序结构（若 std 提供 `TreeMap`）或只在 `restore` 时排序、运行期保持插入序。
- **预期**：排序从 O(n²) 降到 O(n log n)（或 O(n)）；只在流程/步骤规模大时有意义（10 步以下可忽略）。
- **代价**：`MemoryLoomStore` 是测试 / `llm_loomPersist=false` 用的内存实现，收益仅限该路径；换有序结构需确认当前 SDK 的 std 支持与迭代语义。
- **验证**：`cjpm bench -O2` 对 `topologicalOrder` 造 10 / 100 / 1000 步计划，取中位数；`list` 造 10 / 1000 / 10000 条。
- **证据状态**：`无基线（待验证）`

### [堆内存] 把 `values` 快照从"每次 render 全量拷贝"改成写时复制的不可变快照

- **现状**：`LoomHostApi.render`（`LoomHostApi.cj:73-145`）每次调用都在 `synchronized(mutex)` 里新建 `HashMap` 并逐条拷贝 `values`（步骤数 n 条），再在锁外替换。一个流程里 m 个模板步骤 ⇒ O(m×n) 次条目拷贝 + m 次 `HashMap` 分配。
- **方案**：`taskEvent` 写入时构造新的不可变快照（写入次数 = 步骤数），`render` 只做一次引用读取（整块原子替换），去掉锁内逐条拷贝；或用 `std.sync` 的原子引用（对引用类型的支持需按文档核对）。
- **预期**：`render` 的分配从 O(n) 降到 O(1)（引用），锁内只读一次引用；n 大时收益明显。
- **代价**：写入路径变成 O(n) 拷贝（步骤多时写放大），需要权衡读写比；快照生命周期仍受 #1 的静态量问题约束（必须先解决归属）。
- **验证**：`cjprof heap` 看 `render` 的分配量；50 步流程 × 100 轮对比 `getAllocatedHeapSize()` 与 RSS，同时测 `render` 的 P95。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `render` 每次全量拷贝 `values` 是模板步骤的主要开销（分配 + 锁等待） | `f_llm/src/loom/LoomHostApi.cj:80-88` | 单次 `render` 耗时、锁等待时长、`values` 平均条目数 | 50 步流程跑 100 轮，`cjprof record -O2` 看 `render` self time；锁前后打点统计持有时间 |
| 2 | `confirmFlow` 丢弃编译产物导致 `executeNow` 重复编译，占单次执行的可感比例 | `f_llm/src/loom/LoomService.cj:113/131-140`、`LoomRunner.cj:126` | 编译段耗时 / 执行总耗时 | 分段计时（编译段 vs 派发段），或 `cjprof` 看 `LoomCompiler.compile*` self time；5 步流程 × 100 次 |
| 3 | `memory.list` 多 kind 时每页两次 Store 查询，使翻页延迟翻倍 | `f_llm/src/loom/LoomStoreGateway.cj:147-163` | 每 kind 的 `listByKind` 延迟、页大小 | 造 2 种 kind 各 1 万条，`cjpm bench -O2` 对比单 kind 与双 kind 的 `limit=50` 单页耗时 |
| 4 | `skill.load` / `upsert` 的全表扫描在技能数百条后成为流程启动段热点 | `f_llm/src/loom/LoomStoreGateway.cj:239-248/249-260`、`LoomRunner.cj:469-490` | 技能表规模、每次流程的标题数、单次 `list()` 耗时 | 造 10 / 100 / 1000 条技能，bench `resolveSkills(['a','b','c'])`；生产侧加计数埋点看标题数分布 |
| 5 | `topologicalOrder` 的 `remove(at: 0)` 在 100+ 步计划上成为可观开销 | `f_llm/src/loom/LoomRunner.cj:545-546` | 不同 n 下的排序耗时 | bench 10 / 100 / 1000 步，取中位数；与索引游标实现对照 |
| 6 | `LoomRegistry.flows` 的实际增长速度与单条内存（决定 #12 的上限该设多少） | `f_llm/src/loom/LoomRegistry.cj:167-183` | 每日 `loomExecute` 次数、`pending`/`clarifying` 残留比例、单条 `LoomFlow` 字节数 | 生产埋点统计 `registry.size()` 与 `usedHeap`（每小时），跑一周；离线用 1 万条 `put` 测单条均值 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/loom/LoomContextMemory_test.cj` | .cj | ✅ | 提炼链路用例；#16 的断言依据；`:208` 有一行悬空 KDoc 注释（下一行是另一个用例的注释） |
| 2 | `src/loom/LoomDefaults.cj` | .cj | ✅ | 见 #15 |
| 3 | `src/loom/LoomFunctions.cj` | .cj | ✅ | 见 #4（`dryRun` 死参数）、#18（`LoomServices` 无锁） |
| 4 | `src/loom/LoomFunctions_test.cj` | .cj | ✅ | 覆盖 preview/confirm/execute/delete，无并发用例（#1 的缺口） |
| 5 | `src/loom/LoomHostApi.cj` | .cj | ✅ | 见 #1、#13、#14、#17；`render` 的字节边界已核对（`{`/`}` 为 ASCII，切片必落在字符边界） |
| 6 | `src/loom/LoomJitBridge.cj` | .cj | ✅ | 见 #14；三个 `PredefinedFunction` 注册均被 `LoomCompiler.cj:42` 使用 |
| 7 | `src/loom/LoomMemoryE2E_test.cj` | .cj | ✅ | 端到端验证 `{step.output}` / persona / skills 注入，与实现一致 |
| 8 | `src/loom/LoomMemoryPolicy.cj` | .cj | ✅ | 见 #13、#14、#16；`maxTurns` / `MAX_TURNS` 有界，不构成 OOM |
| 9 | `src/loom/LoomPersona_test.cj` | .cj | ✅ | 人格三级解析用例，与 `resolvePersona` 一致 |
| 10 | `src/loom/LoomPromptDesign_test.cj` | .cj | ✅ | 真实 DeepSeek 用例（无 `DS_KEY` 时跳过）；见 #19 的全局超时与 `/tmp` 依赖 |
| 11 | `src/loom/LoomRegistry.cj` | .cj | ✅ | 见 #8、#9、#12、#17；`sortNames` / 分页见「优化方案」 |
| 12 | `src/loom/LoomRegistry_test.cj` | .cj | ✅ | 覆盖存取删、分页稳定性、恢复、非法状态/空名 |
| 13 | `src/loom/LoomRenderPerf_test.cj` | .cj | ✅ | 见 #19；名字含 Perf 但无 bench，不能当性能基线 |
| 14 | `src/loom/LoomRunner.cj` | .cj | ✅ | 见 #1、#2、#3、#13、#14；`release(Flow<…>)` 空重载已全仓核对无调用者 |
| 15 | `src/loom/LoomRunner_test.cj` | .cj | ✅ | 同步/并行菱形、解绑后调用报错均有断言；缺"步骤抛异常"的并行用例（#2） |
| 16 | `src/loom/LoomScheduler.cj` | .cj | ✅ | 见 #18；`cancel` 被 `ScheduleFunctions.cj:128` 使用，非死代码 |
| 17 | `src/loom/LoomService.cj` | .cj | ✅ | 见 #10、#14、#17；`join` / `questionsJson` 为手写拼接 |
| 18 | `src/loom/LoomServiceSkills_test.cj` | .cj | ✅ | 见 #19 |
| 19 | `src/loom/LoomService_test.cj` | .cj | ✅ | 菱形分叉 + 汇聚、坏计划保持 pending 均有断言 |
| 20 | `src/loom/LoomStoreGateway.cj` | .cj | ✅ | 见 #5、#6、#7、#11、#13、#14；25 个 op 分支逐个核对到实现 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #2/#3/#5/#7/#8；设计 #9/#10（状态所有权与覆盖语义）；语言特性 #14（`Int64`/`String` 取值漂移）、#17（字符串当枚举）；可读性 #13/#17；安全性 #1（跨租户人格/记忆串写）、#7（`userId` 静默归零写公共桶） |
| §1 死代码 | 3 | 逐个核对 20 个文件的 `private` / `internal` / `protected` 符号：`release(Flow<EndExecutorGetter>)` 零调用（#13）、`LoomMemoryPolicy` 的 `f_log` 导入未使用（#13）、`LoomExecuteParam.dryRun` 写了不读（#4）。`buildCount`/`resetBuildCount` 与 `LoomHostApi.valueOf` 只被测试用，按「可见性建议」处理（#13），不判死代码；`public` 且对外可达的声明（`LoomHostApi` / `LoomRegistry` / `LoomService` / `LoomRunner` / `LoomScheduler` 等顶层 `public` 类成员、`LoomStore` 接口）按硬原则一不判 |
| §2 重复逻辑 | 1 | 已两两比对本部分 20 个文件里所有具名函数体摘要：3 份 `fieldOf/strOf`、3 份 `textOf`、2 份逐行相同的 `release`、`execute` 两分支装配、7 处手写 JSON 数组（#14）。其余同形函数（`LoomStoreGateway` 的 6 个 `xxxJson`、`LoomRegistry_test` 的 `flow()`）字段各不同，属业务差异，不合并 |
| §3 空实现 | 2 | `release(Flow<EndExecutorGetter>)` 空 body（#13）；`LoomDefaults.chat` 无助手消息返回空串（#15）。`LoomRegistry.put/remove` 的 `case None => ()`、`LoomRunner.resolvePersona` 的 `catch { () }` 都是有注释的"未装配即降级"分支，不算；`LoomMemoryExtractor` 知识分支的静默 `catch` 单列在 #16 |
| §4 栈溢出 | 0 | 本部分无递归：`topologicalOrder` 为迭代 Kahn，`LoomStoreGateway.call` 是扁平 `if` 链，`LoomRunner.bodyOf` 只有一层闭包。`JsonValue.fromStr` 的递归在 std 内部，不属本部分 |
| §5 OOM | 1 | `LoomRegistry.flows` 只增不删（#12，已给 3~8 KB/条 × 10 万条的估算，增速需实测）。其余容器有界：`LoomContextLog` 上限 200 轮（`MAX_TURNS`）、`values` 按步骤数、`digestOf` 按 `maxTurns`、`LoomMemoryE2E_test` 的 `inputs` 仅测试 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / bench 数据；`LoomRenderPerf_test` 只是功能用例（#19）。6 项疑似热点全部进「待验证假设」，不作结论 |
| §6.2 大粒度锁 | 0 | `LoomHostApi.render` 临界区只有一次 `values` 拷贝（注释与实现一致）；`LoomRegistry` / `MemoryLoomStore` / `LoomMemoryPolicy` 临界区内无 I/O、无日志、无回调；`callStore` 已做到"锁内取引用、锁外调网关"。持锁时长问题见假设 #1 |
| §6.3 并发串行 | 1 | #1 的本质是"进程级状态被迫串行"，并发流程只能互相踩踏；`runAsync` 的 `waiter.get()` 只等一次，`QueuedClosureTask` 的批内串行属 `f_egraph` 设计，不计入本部分缺陷 |
| §6.4 低效算法 | 2 | `skill.load/upsert/count` 全表扫描（#6 的复杂度面，收益进假设 #4）；`topologicalOrder` 的 `remove(at: 0)` 与列举时插入排序（进「优化方案」，无基线） |
| §7 降堆内存方案 | 1 | `render` 的快照拷贝（写时复制方案，`无基线`）。其余对象随流程结束释放，长期持有只有 `LoomRegistry.flows`（已按 #12 报缺陷） |
| §8 降 CPU 方案 | 2 | 复用编译产物、拓扑排序/列举结构，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 被约束卡住：热点对象（`LoomFlow`、步骤闭包、`HashMap` 快照、JSON 串）全部逃逸到注册表 / 全局 `values` / 返回值，`@ local!` 下不成立；且收益需峰值内存对照，而峰值由 #12 的注册表决定，不是 local region |
| §11 现有代码的 BUG（存量） | 9 | #2/#3/#5/#6/#7/#8/#9/#10/#11 按 §11 记（#4 归 §1/§14、#12 归 §5）；已核对 `runCompiled` 的 `try/catch/finally`（同步路径异常→`outcome=failed`→rethrow 正确）、`render` 的字节扫描边界、`topologicalOrder` 环检测、`LoomStoreGateway` 全部 25 个 op 分支、`restore` 的分页终止条件、`parse` 的字段回落 |
| §12 并发安全与锁粒度 | 4 | #1（共享静态量 + 无锁读）、#6（check-then-write 分配主键）、#9（内部可变实例逸出）、#18（单例 install/reset 无同步）。`LoomMemoryPolicy` / `LoomHostApi` 的锁本身用法正确（锁内拷贝、锁外回调）；`LoomRunner` 的 `tagSeq` / `docSeq` / `asyncReady` 均有锁，未发现问题 |
| §14 功能完备性与 README 覆盖 | 2 | #4（`dryRun` 承诺未接线）、#11（网关 op 表漏 5 类能力）。本部分无 `.md`，README 覆盖核对留给对应子轮；本部分只把 README / KDoc 当判据引用 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无 `.md`，故 §13「README/文档与实现」命中 0（KDoc 类问题按 §11/§14 记） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 9 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 19 条（严重 3 / 一般 9 / 轻微 7），是否纳入修复待用户决定；本部分未发现"本次改动"引入的问题（工作区快照 `f309f0b55`，`git diff` 为空）。

## 总评

这 20 个文件的局部质量不错：模板渲染是单遍扫描且保留"未命中不替换"的可排错语义（还有专门的边界用例）；记忆提炼对模型返回做了按字段回落、临时上下文有 200 轮上限；注册表与网关的锁基本遵循"锁内拷贝、锁外干活"的写法（`callStore`、`currentPersonaText`、`render` 都如此），并解释了为什么不用普通局部变量带返回值；测试覆盖面扎实（同步/并行菱形、失败流程写经验、人格三级解析、跨租户 `docId` 唯一性都有断言）。

真正的风险集中在**执行模型的全局性**：#1 把 host、步骤输出、人格、技能、临时上下文全部放在进程级静态量里，而 `LoomRunner` 每次执行都 `bind`/`unbind` 一遍，四条入口（工具调用、定时任务、Supervisor 派发、`LoomAgent`）都没有串行化——并发时不仅丢步骤输出，还会把 A 的人格/技能/记忆串到 B 上（跨租户）。#2 让并行模式下的任何步骤异常变成永久挂起，且异常无日志、`finally` 不执行。#3 是"计划形状不合规就静默跑半个流程或直接挂住"，与项目已有的"`http` kind 直接拒绝"原则不一致。这三条是阻塞项，修法方向清晰：执行上下文变成执行期对象 + 等待加超时/错误回传 + 校验计划根与可达性。

其余按严重度排期即可：#4/#5/#7 属于"模型产出或参数略不合规就静默错"（`dryRun` 无效、分页超量、`userId` 归零）；#6/#8/#9/#10 是注册表与网关的并发/一致性/覆盖语义；#11/#12 是契约文档与容量治理；#13-#19 是死代码、重复逻辑、注释与测试卫生。性能方面只有三条候选（复用编译产物、排序/列举结构、`render` 快照），全部缺基线，先按「待验证假设」采数据再决定，不进入本轮修复清单。
