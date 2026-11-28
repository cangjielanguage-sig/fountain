# f_llm 模块审查报告

> **模块第 16/25 部分**（本报告只覆盖 `files/f_llm.part16.txt` 列出的 20 个文件：`src/loom/` 下 `LoomStoreGateway_test` → `ScheduleFunctions_test`，全部为 `.cj`。其余部分与 `README.md` / `README_en.md` / `doc/**` 由其他子轮产出；本部分编号独立，合并时以主 Agent 为准。`doc/f_llm.md`、`doc/loom.md`、`doc/retrieval-eval.md`、`README.md` 只作取证判据被引用，不计入本部分文件覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`HEAD f309f0b55`，`git status` 只有审查产物目录，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全。本部分不含 LLM 传输层与流式解析（在模块其它部分），可对照的等价面是**编排侧**：模型产出解析（`Planner` / `Plan`）、提示词与能力清单（`Prompts` / `PromptCapabilities`）、装配与网关惰性初始化（`LoomWiring`）、超时包装（`LoomTimeout`）、定时任务工具（`ScheduleFunctions`）、检索评测（`RetrievalEval` / `RetrievalEvalRunner`）
- **报告版本**：v1（第 16/25 部分）

## 发现

### [严重][存量] #1 `Planner.parse` 剥完围栏仍解析原始串：带 ` ```json ` 围栏的模型输出必然解析失败，且抛出 `JsonException` 而非 `LoomException`

- **位置**：`f_llm/src/loom/Planner.cj:148`（`let trimmed = stripFence(raw)`）、`:149`（只拿 `trimmed` 做首尾字符判定）、`:152`（`JsonValue.fromStr(raw)` —— 用的是 `raw`）；实现本体 `f_llm/src/loom/Planner.cj:226-244`
- **来源**：存量（`git blame`：`:148` 为 `eb47a0f5c5 2026-11-02`，`:152` 为 `75f386d77e 2026-11-07`；快照无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§10 正确性
- **证据**：静态确定 —— ① 方法体内 `trimmed` 只有 2 处引用（`:149` 的两个判定），之后 `let dto = match (DataObject<PlanDto>.populate(JsonValue.fromStr(raw).toData()))` 仍用 `raw`；② `f_data` 的 `JsonValue.fromStr` → `fromBytes` → `fromInput` → `fromJson` 是严格 token 解析，遇到非 JSON 词法直接 `throw JsonException`（`f_data/src/json/JsonValue.cj:156-212`，含 `case _ => throw JsonException(...)` / `Unexpected token Name` 等分支），不会返回 `None`，所以 `:154` 的 `case None => throw LoomException(...)` 也接不住围栏场景。
- **描述**：注释（`:147`）写明「模型偶尔用 ```json 包裹，或加解释性文字：先剥围栏再确认外层是 JSON 对象」，实现只做了后半句。后果：任何带围栏的输出在 `:152` 抛 `JsonException`（消息是 JSON 词法错误，不含 `planner returned` 上下文），一路冒到 `LoomService.execute`（`LoomService.cj:75` 无 try/catch）→ 调用方拿到的是一次裸解析异常，`PlannerResult`「要么 planned 要么 need_clarification」的契约被绕过。`stripFence` 本身没问题（`Supervisor.cj:264`、`SkillNamer.cj:71`、`LoomMemoryPolicy.cj:129` 三处都在正确使用），是 `parse` 单点接线错误；`Planner_test.cj` 的 8 条 `parse`/`plan` 用例（`:62-199`）没有一条带围栏，所以一直没暴露。
- **建议**：`JsonValue.fromStr(trimmed)`，并把解析包进 `try { … } catch (e: Exception) { throw LoomException('planner returned invalid JSON: ${e.message}') }`，让异常类型回到契约内。若要容忍「围栏 + 前后说明」，取首个 `{` 到末个 `}` 的子串再解析，并在注释里写清只支持「单个 JSON 对象」。补两条用例：` ```json\n{…}\n``` `（应成功）、围栏后跟一段说明（应成功或给可读 `LoomException`）。

### [严重][存量] #2 `LoomTimeout` 用无同步的可变盒子跨线程传结果：数据竞争，可能把空串当成功结果、或对已完成调用误报超时

- **位置**：`f_llm/src/loom/LoomTimeout.cj:21-25`（`class TimeoutBox`，`done` / `value` / `error` 三个 `public var`）、`:39-47`（`spawn` 内写 `value` / `error` / `done`）、`:48-59`（调用线程轮询读 `done` / `error` / `value`）
- **来源**：存量（`git blame`：整段为 `75396dc966 2026-11-03`；快照无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性：用普通字段当跨线程信号，而不走原子 / 锁 / 通道」、§11「并发正确性」
- **证据**：静态确定 —— 全文件无 `synchronized` / `Mutex` / `Atomic*`（逐行核对 `:1-61`，只有 `sleep` 与 `spawn`）；`done` 是普通 `Bool` 字段，写在 `spawn` 线程、读在调用线程，两线程之间没有任何 happens-before 边（该函数**故意不** `Future.get()`，所以连 `spawn` 返回值的完成同步也放弃了）。写入顺序（先 `value` 再 `done`）只约束写者自身的顺序，不构成对读线程的可见性保证。语言文档：本机 `~/.autocode/cj/doc` 为空（`ls` 无输出），无法引具体章节，故判据只取 checklist §12.1。
- **描述**：三种可观察错误：① `box.done` 写入对轮询线程不可见 ⇒ 一直读到 `false`，`action` 早已返回却仍返回 `timeout after ${timeoutMs}ms`（步骤被记为失败）；② 观察到 `done=true` 但读到旧值 `''` ⇒ **把空串当成 LLM / 工具的成功结果**返回，调用方无法区分「模型返回空」与「竞争读到空」；③ 只 `catch (error: Exception)`，`Error` 子类逃出后 `box.done` 永不置位，表现为必然等满超时（`BackgroundTasks.cj:44` 的 `recordWithTimeout` 是唯一生产调用点，超时即丢记录）。另外轮询用 `waited += 10` 常量累加而非读时钟，真实超时只会晚于 `timeoutMs`，且每次空转都 `sleep(10ms)`，「注释语义正确、传结果通道不成立」是本条的核心。
- **建议**：优先用语言自带的超时等待替代手写轮询（`Future.get` 的 `Duration` 重载 / `TimeoutException`，签名与 `timeout <= 0` 的边界需按 std 文档核对，标 `待确认`）；若保留轮询，把 `done` 换成 `AtomicBool`、`value`/`error` 改由同一把 `Mutex` 保护或改成单字段 `AtomicReference<TimeoutResult>`，读方先拿一次同步再读负载。补并发用例：`action` 内 `sleep(5ms)` 后返回固定串，循环 1000 次断言既不出现空串也不出现早退超时。

### [严重][存量] #3 评测入口有破坏性全局副作用：`loadCorpus` 无条件清空整个技能库，`run` 覆盖进程级 `SkillCatalog` 且异常路径不还原

- **位置**：`f_llm/src/loom/RetrievalEvalRunner.cj:49-53`（`for(skill in meta.skills.list()){ meta.skills.remove(skill.id) }`）、`:87-90`（`SkillCatalog.reset()` + `install(… embedder)`）、`:123-129`（只在正常返回前 `reset()`，不在 `finally`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「资源不对称 / 数据丢失」、§12.1「共享可变状态无保护」、§5「长期持有与全局集合」
- **证据**：静态确定 —— ① `loadCorpus(meta, docs)` 的入参类型是任意 `MetaStore`，删除循环没有任何过滤（不是「只删本次语料的同名技能」，尽管注释 `:50` 的理由是叠版本）；`SkillStore.remove(id)` 在契约里就是真删（`store/StoreContracts.cj:97-98` 的注释即「删除」）；② `SkillCatalog` 是进程级单例（`SkillCatalog.cj:60-66` 的 `install` 持锁覆盖 `storeFactory` / `embedder` 并清空 `vectors`），`run` 覆盖它、结束时 `reset()`，但 `:118-121` 的 `evaluate`、`:123` 的 `embedFailureDetail` 任一处抛异常都会跳过 `:129` 的 `reset()`。
- **描述**：`doc/retrieval-eval.md:102` 的示例传 `InMemoryMetaStore()`，正常用法安全；但 API 接受任意 store，误传 `FStoreMetaStore` / mysql / postgres 即等于**清空生产技能库**（标题索引与正文一起删），且不可回滚。`run` 中途抛异常则整个进程的技能检索从此指向评测语料（`RetrievalEvalRunner` 是 README 对外宣传的能力，见 `README.md:14`、`:143`）。这是「危险默认 + 无守卫」。
- **建议**：① `loadCorpus` 只删本次语料标题命中的 id（先算 `titleToId` 的键集），或加显式 `resetAll!: Bool = false`；② `SkillCatalog` 的安装 / 还原包进 `try { … } finally { SkillCatalog.reset() }`（还原到原 `storeFactory` 更好）；③ 文档补一句「传入生产 `MetaStore` 会清空技能库」。用例侧建议补「`loadCorpus` 不删除语料外技能」的断言。

### [一般][存量] #4 `LoomRequest.onUnresolved` 只有赋值、没有读取点：文档承诺的「澄清轮次用尽按 ask/default/abort 收尾」不存在

- **位置**：`f_llm/src/loom/Planner.cj:33-34`（字段与注释「澄清轮次用尽时的策略：ask | default | abort」）、`:45`（构造参数）、`:59`（赋值）；承诺源 `f_llm/doc/f_llm.md:375-376`
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用（死配置字段）」；硬原则一：字段对外可达，**不判死代码**，只判「承诺未接线」
- **证据**：静态确定 —— 全仓 `grep -rn onUnresolved`（排除 `.worktrees`）只命中 `Planner.cj` 的 3 处（声明 / 参数 / 赋值）+ `doc/f_llm.md:375-376`、`README.md:969` 的说明；`LoomService` / `LoomAgent` / `CodeGen` / `LoomRunner` 零读取。`round` 也只有两处写入（`LoomService.cj:79`、`:94`），没有「轮次 +1 / 上限判定」的代码。
- **描述**：传 `onUnresolved: 'abort'` 或 `'default'` 不会有任何行为差异——既不会 abort，也不会用 `ClarifyQuestion.defaultValue` 收尾（`defaultValue` 因此只是透传字段）。这是「公开契约写了一个分支，实现里没有该分支」。同源 `dryRun`（`LoomRequest.dryRun` / `LoomExecuteParam.dryRun` 全链路无读取）已由 `parts/f_llm.part15.md` 的 #4 记录，**本部分不重复计数**。
- **建议**：要么在 `LoomService.execute` 的澄清分支真正消费（`round >= maxRound` 时按 `onUnresolved` 三分支：`abort` 抛 `LoomException`、`default` 用 `defaultValue` 填 `answers` 后重新 plan、`ask` 保持现状），`maxRound` 作为可选配置；要么删字段并同步改 `doc/f_llm.md:375-376`。测试落点：`Planner_test` / `LoomService_test` 各补一条「round 用尽 + abort」。

### [一般][存量] #5 提示词与 `StepPlan` 注释都声明 `kind=http` 合法，`validate` 却一律拒绝：按提示词输出的模型会让整份计划被否

- **位置**：`f_llm/src/loom/Prompts.cj:36`（规则 6：「步骤 kind 只能是 tool / llm / mcp / jit / http」）、`f_llm/src/loom/Plan.cj:30`（`kind` 取值注释同样列出 `http`）、`f_llm/src/loom/Plan.cj:125-126`（`case 'http' => throw LoomException('loom step kind http is not implemented yet: …')`）
- **来源**：存量（`git blame`：`Plan.cj:126` 与 `Prompts.cj:36` 均为 `d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「承诺了但没实现」、§11「契约与实现不符」
- **证据**：静态确定 —— 提示词把 `http` 列为可选 kind，`validate` 又把 `http` 单独判死；`Plan_test.cj:146-157` 还写了用例锁定「拒绝 http」，两者不可能同时为真。
- **描述**：`http` 是模型输入契约里的合法选项，模型照规则第 6 条排一个 `http` 步骤完全合理；但 `Planner.planOf` → `validate()` 抛错后**整份计划被否决**（连同其中合法步骤一起丢掉），一次成功的模型调用作废，用户只看到「不支持」。提示词是模型唯一的规格来源，这里两个规格源各说一套。
- **建议**：二选一并保持单一事实源：①（推荐）从 `Prompts.cj:36` 与 `Plan.cj:30` 删掉 `http`，改为「需要 HTTP 请用已注册工具」；② 实现 http 步骤后再放开（属功能开发，另开条）。若保留 `http` 作实验，提示词必须显式写「暂不支持，请勿使用」。

### [一般][存量] #6 网关惰性初始化是裸 check-then-write：并发首次调用会构造两个 `LoomStoreGateway`（两套存储连接），注释承诺的「只建一次」不成立

- **位置**：`f_llm/src/loom/LoomWiring.cj:38-54`（`class LoomGatewayHolder`：`:39` `private var value: ?LoomStoreGateway`，`:46-52` 先查后写、无锁）、`:104-106`（`LoomHostApi.installStore({ … gatewayHolder.get(gateway).call(…) })`）
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §12.1「检查-然后-写入 / 惰性初始化」、§6.3「并发串行（重复初始化）」
- **证据**：静态确定（模式）+ 调用路径可证 —— `match (value) { Some => return }` 与 `value = Some(LoomStoreGateway())` 之间无任何同步手段；并发读者至少有两条：① `LoomHostApi.callStore` 只在锁内拷 `storeGateway`，回调在**锁外**执行（`LoomHostApi.cj:170-179`），任意流程步骤的 `loomStore(…)` 都会走到这里；② 技能演进 cron 在调度器线程执行 `SkillEvolutionJob.load(holder.get(injected), …)`（`LoomWiring.cj:213-216`）。无参构造 `LoomStoreGateway()` 会 `Stores.content()` + `Stores.meta()` + `EvolutionStores.current()`（`LoomStoreGateway.cj:68-74`），可能各开一套连接 / 句柄。
- **描述**：两线程同时首次进入 ⇒ 都看到 `None` ⇒ 各建一个网关，后者覆盖前者，先建的那个被本线程用完即弃——连接池 / 文件句柄泄漏，同进程出现两份网关；`buildCount` 也会 >1，即 `LoomWiringGateway_test` 想守的「只建一次」自检在并发下失效（该测试只覆盖「注入网关时不新建」，`LoomWiringGateway_test.cj:47-65`）。
- **建议**：给 holder 加 `Mutex` 做锁内二次检查，或在 `wire` 里用原子引用 CAS；若坚持不锁，就改成装配期建一次并删掉「懒建」注释（`:101-102` 与实现二选一）。补并发用例：10 线程同时 `callStore('skill','count','{}')`，断言 `LoomStoreGateway.buildCount == 1`。

### [一般][存量] #7 定时流程执行失败被 `catch (error: Exception) { () }` 吞掉：无日志、无计数，cron 任务静默失效

- **位置**：`f_llm/src/loom/ScheduleFunctions.cj:82-93`（`:85-90` 的 `try { service.executeNow(…) } catch (error: Exception) { () }`）
- **来源**：存量（`git blame`：`36c19d2ed2 2026-11-03`；快照无基线可比）
- **判据**：review-checklist §3「`catch` 静默吞掉异常」、§11「错误处理缺失或静默」、`fountain-baseline.md` §6（日志走 `f_log`）
- **证据**：静态确定 —— `catch` 体是空 tuple `()`，无 `LoggerFactory`、无计数器、无回写；同文件其它分支（`:56-60`、`:73-77`）都会把可读结果返回给调用方，只有这一支什么都不留。
- **描述**：`scheduleCreate` 注册的 body 在调度线程按 cron 执行同名流程（`:66-71`），`runFlow` 里的任何异常（流程不存在、未编译、JIT 失败、LLM 超时抛错）都被吞。表现是「到点了，但什么都没发生」，且没有任何日志能证明它跑过。注释（`:81`）只解释了「宿主缺失时静默跳过」，实现把「宿主缺失」与「执行失败」合并成了同一种静默。
- **建议**：`case None` 保持静默（可 `debug`），`catch` 分支至少 `LoggerFactory.getLogger<ScheduleCreateFunction>().error('loom scheduled flow failed: ${name}: ${error.message}')`；担心日志放大就 `warn` + 去重，但不要什么都不打。

### [一般][存量] #8 评测用「标题」反查语料 id，既不校验标题唯一、又用 `case None => ()` 静默丢命中

- **位置**：`f_llm/src/loom/RetrievalEvalRunner.cj:65-71`（`titleToId`：`map[doc.title] = doc.id`，后写覆盖先写）、`:91-100`（search 闭包里 `match (idOf.get(hit.title)) { case Some(id) => ids.add(id); case None => () }`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §3「`case None => ()` 把错误吃掉」、§11「静默失效」、§13（数据约束未写入文档）
- **证据**：静态确定 —— 语料 `id` 唯一有断言（`RetrievalEval_test.cj:134-139`），**标题唯一没有任何断言**；`SkillCatalog.search` 只回标题（`:93` 的 `hit.title`），标题重复时两条语料折叠到同一 id，另一条永远命不中，`recall` 被系统性拉低；`case None` 让「标题对不上」这种数据错误直接表现为「没命中」。
- **描述**：受影响的正「改了语料忘改标题 / id」的场景——正是评测脚本最该报警的输入错误，却被计成一个安静的指标下降（`doc/retrieval-eval.md:122-133` 记录过一次「指标莫名偏低」的踩坑，说明这类失真发生过）。
- **建议**：`titleToId` 检测冲突并抛 `LoomException('duplicate corpus title: …')`；`case None` 分支累加 `unmappedHits` 并在报告头 `WARN`（与 `embedFailures` 同款处理）。`testShippedDatasetIsWellFormed` 补「标题唯一」断言。

### [一般][存量] #9 `status` 未识别与空 `steps` 都落到 `planned`：模型输出 `{}` 或拼错 status 会静默产出一个空流程，被落库并可编译

- **位置**：`f_llm/src/loom/Planner.cj:156-161`（只有 `if (dto.status == 'need_clarification')`，其余一律 `planOf` + `PlannerResult('planned', …)`）；`f_llm/src/loom/Plan.cj:94-141`（`validate` 没有 `steps` 非空校验）；`f_llm/src/loom/CodeGen.cj:148-162`（`firstStep` 在空 `steps` 时返回 `''`，`flowSource` 因此跳过 `registerStart`）
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 空集合未处理」、§14.1「只做了一半的分支」、§3「开关打开后走进空分支」
- **证据**：静态确定 —— `PlanDto.status` 默认 `'planned'`（`Planner.cj:364`），`parse` 是二值判定；`{}`、`{"status":"clarify"}`、`{"status":"PLANNED"}` 都进 `planned` 分支，`planOf` 产出 0 步骤的 `FlowPlan`，`validate` 三个循环都不执行直接通过，`CodeGen.firstStep` 返回 `''`、`flowSource` 不写 `registerStart`。`Planner_test.cj:124-131` 的用例名叫 `testPlanWithoutStepsIsRejectedByCodeGen`，但断言只有 `plan.steps.size == 0`——**没有任何拒绝**，用例名与断言相反。
- **描述**：模型把 status 写错或返回空对象时，用户得到一份「成功但空」的流程：`pending` → `confirm` → `compiled`，执行时无任务可跑、无报错。错误被推迟到「跑完什么都没发生」，与「模型没排步骤」无法区分；而无步骤在 schema 里本应是非法计划。
- **建议**：`match (dto.status) { case 'planned' => …; case 'need_clarification' => …; case other => throw LoomException('planner returned unknown status: ${other}') }`；`validate` 增加 `if (steps.isEmpty()) { throw LoomException('loom plan must have at least one step') }`；把那条用例改名或改成真正的拒绝断言。

### [一般][存量] #10 `wire(store:)` 只接管流程注册表；演进族存储 / 技能目录仍走全局 `llm_metaStore`，注入 store 的调用方仍会连生产库（测试里真的写 `./data/f_llm-meta`）

- **位置**：`f_llm/src/loom/LoomWiring.cj:85-92`（`store!` 只用于 `LoomRegistry`）、`:128`（`SkillCatalog.install({=> Stores.meta().skills})`）、`:130-134`（`EvolutionStores.bootstrap()` / `EvolutionStateStores.bootstrap()` / `EvolutionLeases.bootstrap()`）；对照 `EvolutionStores.cj:41-43`（`current()` → `byName(StoreSettings.load().metaStore)`）、`StoreSettings.cj:40-41`（默认 `f_store` / `./data/f_llm-meta`）
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §14.1「接线缺失 / 只做了一半」、§10 设计合理性（注入点覆盖面与声明不符）、§11「契约与实现不符」
- **证据**：静态确定 —— `wire` 的 `store` 参数在 `:87-91` 之后不再出现；四个 bootstrap / install 全部走 `Stores.*` / `StoreSettings`，与入参无关。可观察后果就在本部分：`LoomWiring_test.cj:37-89` 的四条用例只传 `store: MemoryLoomStore()`、**没有**设 `llm_metaStore`，因此每次 `wire` 都会 `EvolutionLeases.bootstrap()` 对默认 `./data/f_llm-meta` 建表并写一条租约；同目录的 `LoomWiringSupervisor_test.cj:57-58` 专门设了 `llm_metaStore=memory` 并在注释里写明「装配会碰演进族存储：指到内存，避免写默认元数据目录污染别的用例」——两条测试的写法差异正好证明这条链没被 `store` 覆盖。
- **描述**：① 调用方以为「传了 store 就完全隔离」，实际技能目录、演进报告表、演进状态、租约仍打到全局配置的库；② `cjpm test` 会写仓库目录下的 `./data/f_llm-meta`，并使测试之间通过全局存储产生隐式耦合（`Config` 是进程级单例，测试类并行执行时互相污染）。
- **建议**：让 `wire` 把选定的 store 一并传给 `SkillCatalog.install` 与三个 bootstrap（或新增 `evolutionStore! / metaStore!` 参数并在注释里写明「只影响 X」）；`LoomWiring_test` 与 `LoomWiringChannel_test` 补齐 `Config.set<String>([('llm_metaStore','memory')])` + `finally` 清理（照抄 `LoomWiringSupervisor_test.cj:56-77` 的写法）。

### [轻微][存量] #11 `FlowPlan.validate` 不查任何长度的环：`a→b→a` 能通过校验并被标成 compiled，直到执行期才由拓扑排序拒绝

- **位置**：`f_llm/src/loom/Plan.cj:93`（注释「校验：步骤 id 唯一、边两端存在、无自环、kind 合法」）、`:133-140`（只判 `edge.from == edge.to`）；兜底 `f_llm/src/loom/LoomRunner.cj:525-561`（Kahn 拓扑排序，`:558-560` 抛 `loom plan contains a cycle, cannot execute`）
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §11「边界缺失」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `validate` 的边循环只有「端点存在 + 非自环」两项，无入度 / 可达性检查；环不会被无限执行（`LoomRunner.topologicalOrder` 会抛错），所以**不是挂死**，而是「编译成功、执行必失败」。
- **描述**：同一类非法输入（模型排错边）在编译期放行、在执行期才报错，`confirmFlow` 之后 `LoomStatus.COMPILED` 是个假状态；排错信息到了执行期才出现，且 `LoomService.confirmFlow` 的成功返回会让人误以为流程可用。
- **建议**：在 `validate` 末尾加一次 Kahn（O(V+E)，用现成 `HashMap` 入度表），走不完即抛 `LoomException('loom plan contains a cycle: <剩余 id>')`；顺带把「根节点唯一 / 全部可达」也放这里（与 `parts/f_llm.part15.md` #3 的修法合并到同一处）。补用例：`a→b→a` 必须在 `validate` 就被拒。

### [轻微][存量] #12 jit 占位符拒绝逻辑写了两遍，且只扫「已见」步骤 id：同文案重复 + 前向引用漏检

- **位置**：`f_llm/src/loom/Plan.cj:109-124`（`:111-118` 遍历 `seen.keys()` 抛一次，`:119-124` 又为 `start` 抛一次，两段文案除 token 名外逐字相同）；`seen[item.id] = true` 在 `:106`，即扫描集合只含当前及之前步骤
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §2「字面量复制：同一文案两处」、§11「边界缺失」（校验覆盖不全）
- **证据**：静态确定 —— 两段 `throw LoomException('jit step does not support {…} template placeholders …')` 只差括号里的 id 与提示语；`:111` 的 `for (token in seen.keys())` 在 `:106` 之后执行，因此**后续步骤的 id 不在集合里**，`{later.output}` 形式的占位符不会被拒绝。
- **描述**：jit 源码在编译期固化，占位符不会被替换——这正是该校验存在的理由；引用后面步骤的 jit 步骤会带着字面量 `{x.output}` 编译通过，运行时产出的是这段字面文本（静默错误结果）。重复的两段在修改提示语时也容易只改一处。
- **建议**：改成先收集 token 列表（`seen.keys()` + `'start'`，或直接扫全部 `steps` 的 id），再对 `['{${t}.output}', '{${t}}']` 两个模式循环抛一次；若要保留「仅前序」的语义，注释必须写明并说明后继引用为何安全。

### [轻微][存量] #13 `TopicStat` 与 `EvalReport` 的四个指标函数逐行相同（重复逻辑）

- **位置**：`f_llm/src/loom/RetrievalEval.cj:79-105`（`TopicStat` 的 `ndcg` / `recallAt1` / `recallAtK` / `mrr`）对 `:142-168`（`EvalReport` 的同名四个函数）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §2「只改类型名：两个函数体逐行对齐」
- **证据**：静态确定 —— 四对函数体逐字相同（同样的 `if(total <= 0){ return 0.0f64 }` + 同样的分子/分母），唯一差异是 `EvalReport` 多一个 `negativeRate`；两边的 `total` 都是「正样本数」，语义一致。`render`（`:186-187`、`:212-213`）同时调用两种类型的方法。
- **描述**：当前无行为漂移，但「改分母规则」要改两处（例如以后把负样本计入分母），很容易只改一边。
- **建议**：抽 `internal func metricRatio(numerator: Float64, total: Int64): Float64`（或让 `EvalReport` 内嵌一个「全局 `TopicStat`」），四对方法改成一行委托；两个类型对外签名不变。

### [轻微][存量] #14 语料目录解析在两处逐字重复（同一环境变量、同一缺省值），且都不 trim 而同类 env 读取又 trim，口径不统一

- **位置**：`f_llm/src/loom/RetrievalEval.cj:249-255` 对 `f_llm/src/loom/RetrievalEvalManual_test.cj:55-60`
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §2「字面量复制：同一个环境变量 / 同一个缺省值散落多处」
- **证据**：静态确定 —— 两处都是 `match(getVariable('fllm_evalDir')){ case Some(value) => value; case None => './eval' }`，逐字相同（都不 `trimAscii`）；而同一测试文件的 `modelName()`（`:48-53`）对 `fllm_evalModel` 做了 `trimAscii` 并处理空串，`minScore`（`:69-72`）也做了 trim，只有目录这一路不 trim，同一文件内口径已不一致。
- **描述**：`fllm_evalDir` 带尾随空格 / 换行时，目录路径会带进脏字符（`./eval ` 打不开），错误表现为「文件不存在」而不是「变量写错了」；`RetrievalEval_test.evalDir`（`:314-322`）又是第三份「先试再用 `../eval` 回落」的逻辑，三处需要人肉对齐。
- **建议**：`RetrievalEvalManual_test.evalDir()` 直接调 `RetrievalEval.defaultDir()`，并把 `trimAscii` 收进 `defaultDir`；`RetrievalEval_test.evalDir` 的回落逻辑若要保留，注释写明「仅在 cjpm test 工作目录不一致时需要」。

### [轻微][存量] #15 `RetrievalEval.linesOf` 全量 `readToEnd` 且 `file.close()` 不在 `finally`：读异常即泄漏句柄

- **位置**：`f_llm/src/loom/RetrievalEval.cj:416-429`（`:418` `File(path, OpenMode.Read)`、`:419` `StringReader(file).readToEnd()`、`:420` `file.close()`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§5「一次性物化」（`mem §5.1` 流式优先）
- **证据**：静态确定 —— `close()` 与 `readToEnd()` 之间没有 `try/finally`；`readToEnd` 在路径是目录 / 编码非法 / 文件被截断时抛异常，此时 `file` 已打开且不会关闭。
- **描述**：评测是手动 / nightly 入口，进程退出会回收，但「循环跑多个目录」就会累积；`readToEnd` 生成整串后再 `split('\n')` + `ArrayList`，是对同一份数据的第二次全量副本。50 条语料无压力，`fllm_evalDir` 指向大文件时就是典型的按输入长度物化。
- **建议**：`try { … } finally { file.close() }`，或改成 `std.io` 逐行读（边读边 `add`），顺带消掉二次副本。

### [轻微][存量] #16 `LoomWiring.cj` 的 KDoc 挂错对象：`LoomWiring` 类注释落在 `LoomGatewayHolder` 上，`installSupervisor` 的注释落在 `reload` 上

- **位置**：`f_llm/src/loom/LoomWiring.cj:25-36`（「loom 的启动装配…需要宿主在 `StoreWiring.wire()` 之后调一次」）紧接 `:37` 的 `/** 懒建一次的网关持有者… */` 与 `:38` 的 `class LoomGatewayHolder`；`:143-148`（「装配 Supervisor…」）紧接 `:149` 的 `/** 最近一次装配的恢复结果… */` 与 `:150` 的 `private static var reload`；`:60-64`（`@param chat … @return 已安装的 LoomService`）紧接 `:65` 的 `/** 零配置… */` 与 `:66` 的 `wire(plannerModel!)`
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06` / `d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §10「可读性 / 必要注释」、§11「语义与注释不符」
- **证据**：静态确定 —— 连续两段 KDoc 时只有最后一段属于被修饰声明：`public class LoomWiring`（`:56`）因此**没有类文档**，`LoomGatewayHolder` 拿到的是「启动装配」的说明；`installSupervisor`（`:176`）与 `lastReload`（`:152`）同理互换/缺失；`wire(chat, …)`（`:75`）的 20 个命名参数失去了 `:60-64` 的 `@param` 说明（该段落在 `wire(plannerModel!)` 前面）。
- **描述**：doc 生成与 IDE 悬浮会读错：查 `reload` 看到「装配 Supervisor」，查 `installSupervisor` 什么都没有，查 `LoomWiring` 类没有任何说明。`LoomWiring.wire` 是 README 列的对外入口，参数文档丢失影响最大。
- **建议**：`:25-36` 移到 `:56` 前（`LoomGatewayHolder` 只留 `:37`）；`:143-148` 移到 `:176` 前；`:60-64` 移到 `:75` 前，`wire(plannerModel!)` 保留 `:65` 一句。

### [轻微][存量] #17 未使用的 import：`LoomTimeout.cj` 的 `std.sync.*` / `std.time.*`，`LoomWiringGateway_test.cj` 的 `fountain::f_data.JsonString`

- **位置**：`f_llm/src/loom/LoomTimeout.cj:18`、`:19`；`f_llm/src/loom/LoomWiringGateway_test.cj:22`
- **来源**：存量（`git blame`：`75396dc966 2026-11-03` / `8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §1「未使用的 import」（机械动作第 7 条）
- **证据**：静态确定 —— `LoomTimeout.cj` 只用 `TimeoutBox` / `String` / `Bool` / `sleep` / `Duration` / `spawn`，`std.sync` 的 `Mutex`/`Atomic`/`synchronized` 与 `std.time` 的 `DateTime` 一个都没出现（`grep` 该文件无这些符号）；`LoomWiringGateway_test.cj` 的 `JsonString` 只在 `:22` 出现，文件内 `match(out as DataEvent)` 之类都不涉及（`as JsonString` 的用法在 `ScheduleFunctions_test.cj:57`，不在本文件）。
- **描述**：无害，但 `std.sync.*` 的通配 import 会让人误以为 `LoomTimeout` 用了同步原语——而 #2 的问题恰恰是**没有**同步。删掉后读者不会误判。
- **建议**：删除三处 import；若按 #2 改用 `Future.get` 的超时重载，只需 `std.core` 的异常类型（无需新增 import）。

### [轻微][存量] #18 测试注释与数据集实际规模不符（「语料只有 20 条」，实际 50 条）

- **位置**：`f_llm/src/loom/RetrievalEval_test.cj:263`（`// 选择排序取前 topK（语料只有 20 条）`），对照同文件 `:132`（`@Expect(docs.size, 50)`）与 `eval/retrieval_corpus.tsv`（实测 50 条有效行）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §10 可读性 / §13「文档与代码一致性（注释过期）」
- **证据**：静态确定 —— 注释写 20、断言写 50；同文件类注释 `:122` 写的是「50 条语料 + 612 条正样本」，说明 `:263` 是扩语料时漏改的残留（另核对数据集：50 条语料 / 622 条 query = 612 正样本 + 10 负样本 / 12 个主题，与 `:162-174` 断言一致）。
- **描述**：不影响执行；但这条注释是「为什么可以对语料用 O(n²) 选择排序」的唯一理由，数字错了会让人误判复杂度前提。
- **建议**：改成「语料 50 条」或去掉具体数字。

### [轻微][存量] #19 报表格式化不严谨：`percent` 截断且小数位随值变化，`padRight` 按字节对齐（中文主题列不齐）

- **位置**：`f_llm/src/loom/RetrievalEval.cj:225-227`（`percent`）、`:229-235`（`padRight`，用 `Int64(padded.size) < width`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§10 可读性
- **证据**：静态确定（`percent`）/ 待确认（`padRight`）—— `percent(0.6309)` → `6309/100=63`、`6309%100=9` → `63.9%`（第三位直接截断、不四舍五入）；`percent(0.05)` → `5.0%`；`percent(1.0)` → `100.0%`，小数位随值变化，人工比对主题时列对不齐。`padRight` 的宽度若按 UTF-8 字节算（`String.size` 的字节语义需按 std 文档核对，本机无文档副本，标 `待确认`），`padRight('代码评审', 10)` 会提前「填满」，中文主题名整体左移。
- **描述**：只影响人工阅读的报表（`doc/retrieval-eval.md:109-120` 的样例输出），不影响指标数值；但主题名多为中文，而「最差主题排最前」正是报表的主要目的（`:178-182` 的注释）。
- **建议**：`percent` 改定点两位（乘法后加 50 再除，实现四舍五入）；`padRight` 按 `Rune` 数或显示宽度补齐。

## 优化可行性方案

> 不是缺陷，是「还能更好」。无基线数据，收益只能作为待验证假设。

### [CPU] `FlowPlan.jsonQuote` 每次转义做两次全量字节拷贝

- **现状**：`jsonQuote`（`Plan.cj:186-214`）先 `text.toArray()` 把整串复制成一份 `Array<Byte>`，逐字节判断后用 `ArrayList<Byte>` 累积（多次扩容复制），最后 `out.toArray()` + `String.fromUtf8(...)` 再复制一份。调用密度高：`FlowPlan.toJson` / `StepPlan.toJson`（每步骤 5-8 个字段）以及仓内 30+ 处手工拼 JSON（`LoomStoreGateway.cj`、`LoomService.cj`、`LoomMemoryPolicy.cj`、`LoomRunner.cj` 等）。
- **方案**：改成按索引扫描（`for (index in 0..text.size) { let ch = text[index] }`，`LoomHostApi.cj:92-101` 的 `render` 已用同一手法做单遍字节扫描），`out` 预分配 `text.size + 2`，省掉 `toArray()`。
- **预期**：单次转义少一份 `size` 字节临时数组（典型字段 20-200 字节），一个 5 步计划约 40 次转义 ⇒ 少约 40 次小分配；具体降幅未测。
- **代价**：无 API 变化；需确认 `String[index]` 的越界语义与 `toArray` 长度一致（`待确认`）。
- **验证**：`cjpm bench -O2`，对 `FlowPlan.toJson()` 跑 10 万次，同机对照改前 / 改后中位数与 P95，并记 `getAllocatedHeapSize()` 差值。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LoomTimeout` 的 10ms 轮询带来可观线程唤醒与超时精度损失（每次调用最多 `timeoutMs/10` 次 `sleep` + 唤醒） | `LoomTimeout.cj:48-52` | 单次调用唤醒次数、CPU 占比、超时误差分布 | `cjprof record` 跑「1000 次 3s 超时的工具调用」，统计 `sleep` 相关采样与「墙钟 − 期望超时」的 P50/P99 |
| 2 | `jsonQuote` 的两次 `toArray()` 拷贝在计划落库路径上占比可测 | `Plan.cj:188-213` | self time 占比、分配量 | `cjpm bench -O2` 对 `toJson()` 做改前 / 改后对照 + `cjprof` 看 `String.fromUtf8` 与数组拷贝占比 |
| 3 | 评测路径（50 文档 × 622 query × `SkillCatalog.search`）的耗时大头在编码而非打分 | `RetrievalEvalRunner.cj:91-100`、`RetrievalEval.cj:319-365` | 编码 / 余弦 / 排序的分段耗时 | 在 search 闭包里加分段计时，跑一次 `fllm_runEval=1`，对比三段中位数 |
| 4 | `EvalReport.render` 的 O(12²) 选择排序与 `padRight` 字符串拼接在报告生成里可忽略 | `RetrievalEval.cj:193-235` | 单次 `render` 耗时 | 对 `render` 跑 1 万次取中位数（预期微秒级；若成立则不必优化） |

## 文件覆盖

> 与 `{workdir}/files/f_llm.part16.txt` 一一对应，20 行齐全。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/loom/LoomStoreGateway_test.cj` | .cj | ✅ | 覆盖 op 映射 / 错误分支 / JIT 可达性；`testBuildCountTracksConstruction`（`:117-124`）是 #6 的自检手段，但未覆盖并发 |
| 2 | `f_llm/src/loom/LoomTimeout.cj` | .cj | ✅ | 见 #2、#17；超时包装的唯一实现，`BackgroundTasks.cj:44` 是唯一生产调用点 |
| 3 | `f_llm/src/loom/LoomWiring.cj` | .cj | ✅ | 见 #6、#10、#16；装配入口，公开符号与 `README.md` 条目对照过 |
| 4 | `f_llm/src/loom/LoomWiringChannel_test.cj` | .cj | ✅ | 通道装配用例，`finally` 复位 `Config`/`ChannelMediator`/`LoomServices`；未隔离 `llm_metaStore`（同 #10） |
| 5 | `f_llm/src/loom/LoomWiringGateway_test.cj` | .cj | ✅ | 见 #6（并发首次调用未覆盖）、#17（未用 import）；`quiet()` 注释解释了测试类并行执行的全局状态问题 |
| 6 | `f_llm/src/loom/LoomWiringSupervisor_test.cj` | .cj | ✅ | `FailingLoomStore` 为有意桩（`list` 抛错），非空实现；`lastReload` / `evolutionOwner` / 宿主不被覆盖均有用例；`llm_metaStore=memory` 的隔离写法可作 #10 的修法模板 |
| 7 | `f_llm/src/loom/LoomWiring_test.cj` | .cj | ✅ | 装配 / 演进注册 / 默认 chat 三组用例；缺围栏 JSON 用例（#1 漏测点），未隔离 `llm_metaStore`（#10） |
| 8 | `f_llm/src/loom/Plan.cj` | .cj | ✅ | 见 #5、#9、#11、#12；`jsonQuote` 进 CPU 方案；已逐个确认 `hexOf` 被 `jsonQuote` 调用、`StepPlan.jsonQuote` 被 `extend StepPlan.toJson` 的无限定调用使用（非死代码） |
| 9 | `f_llm/src/loom/Plan_test.cj` | .cj | ✅ | 校验 / toJson 转义 / `ToolScope` 用例；`:146-157` 锁定 http 拒绝（#5 的另一半），缺「环」与「空步骤」用例（#9/#11 漏测点） |
| 10 | `f_llm/src/loom/Planner.cj` | .cj | ✅ | 见 #1、#4、#9；DTO 与 `DataAssist` 映射逐字段核对，`async` 的 `'true'/'false'` 回落与 `planOf` 的字符串比较一致 |
| 11 | `f_llm/src/loom/Planner_test.cj` | .cj | ✅ | 8 组用例；缺「围栏 JSON」与「未知 status」（#1/#9 漏测点）；`:124-131` 用例名与断言相左（#9 描述） |
| 12 | `f_llm/src/loom/PromptCapabilities.cj` | .cj | ✅ | 能力清单拼装；`allowed` 收窄走 `whitelist.contains` 过滤，与 `Planner.plan` 的传参一致，无问题 |
| 13 | `f_llm/src/loom/Prompts.cj` | .cj | ✅ | 见 #5（规则 6 的 `http`）；其余规则（id ≤16、边为二元数组、`async=false`/`external=true`）与 `validate` 一致 |
| 14 | `f_llm/src/loom/RetrievalEval.cj` | .cj | ✅ | 见 #13、#14、#15、#19；指标公式（nDCG / MRR / 负样本分母 / 空集保护）逐条核算通过 |
| 15 | `f_llm/src/loom/RetrievalEvalManual_test.cj` | .cj | ✅ | 见 #14；默认跳过（`fllm_runEval=1`），报告写 `/tmp` 依赖 WSL 环境；`file` 未用 `finally` 关（测试内，可接受） |
| 16 | `f_llm/src/loom/RetrievalEvalRunner.cj` | .cj | ✅ | 见 #3、#8；报告拼装与 `EvalOutcome` 契约一致，`embedFailures` 汇总口径正确 |
| 17 | `f_llm/src/loom/RetrievalEval_test.cj` | .cj | ✅ | 见 #18；指标用例（完美 / 第 2 名 / 多相关 / 未命中 / 空集 / 分层 / 数据集完整性）与实现及 `eval/*.tsv` 实测规模一致 |
| 18 | `f_llm/src/loom/RetrievalQuality_test.cj` | .cj | ✅ | 假编码器 + 固定语料，`finally` 复位 `SkillCatalog`；用例覆盖向量排序、关键词回落、归属分配，无问题 |
| 19 | `f_llm/src/loom/ScheduleFunctions.cj` | .cj | ✅ | 见 #7；`scheduleCreate` / `scheduleDelete` 的空 name / 空 cron / 无调度器分支均正确，`scheduler.schedule` 抛错时结果文本不会误报成功 |
| 20 | `f_llm/src/loom/ScheduleFunctions_test.cj` | .cj | ✅ | `FakeScheduler` 只记录不执行，`runFlow` 异常路径无用例（#7 漏测点）；`createParam` / `deleteParam` 仅类型名不同（属测试样板，已并入 #14 记录，不另计） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_llm.part16.txt` 的 20 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 #1/#3/#5/#9；设计 #10（注入点覆盖不全）；语言特性 #2（把其他线程写的普通字段当同步通道）；可读性 #16/#17/#18/#19；安全性 #3（误传生产 store 即清库，属破坏性操作，与正确性同一根因只计一次） |
| §1 死代码 | 1 | 已逐个核对本部分全部 `private` / `internal` / 非 public 顶层声明里的 `public` 成员：`FlowPlan.hexOf`（`Plan.cj:216`，被同文件 `jsonQuote` 调用）、`StepPlan.jsonQuote`（`Plan.cj:248`，被 `extend StepPlan.toJson` 的无限定 `jsonQuote(...)` 调用）、`Planner.stripFence`/`argsJson`/`planOf`/`questionsOf`/`assumptionsOf`/`userPrompt`、`RetrievalEval.percent`/`padRight`/`ndcgOf`/`discount`/`linesOf`、`ScheduleCreateFunction.runFlow`、`LoomGatewayHolder.get`、`LoomWiring.installSupervisor`/`registerEvolution`/`reload`、`TimeoutBox` 三个 `public var`（同文件读写）**均有调用者**；另查 `return`/`throw`/`break`/`continue` 后无同层语句、无恒真恒假分支、无只被测试引用的非 public 符号。命中仅 #17 的 3 处未使用 import。`LoomRequest.onUnresolved`/`dryRun` 是**对外可达 public 字段**，按硬原则一不判死代码，改按「读了不用」记 #4（`dryRun` 已在 part15 计数，本部分不重复） |
| §2 重复逻辑 | 2 | 同文件两两比对 20 个文件的函数体：`TopicStat` 与 `EvalReport` 的 4 对指标方法逐行相同（#13）；jit 占位符两段同文案 `throw`（并入 #12）。跨文件比对相同字面量 / 环境变量：`fllm_evalDir` 读取逻辑两处逐字相同（#14）；`ScheduleFunctions_test` 的 `createParam`/`deleteParam` 只改类型名（并入 #14 记录）。已排除的近似项：`CodeGen.jsonQuote` 只是委托 `FlowPlan.jsonQuote`；`RetrievalQuality_test` 假编码器与 `RetrievalEval_test` 字符重合检索器用途不同（一个测排序、一个测数据集）；`percent`/`padRight` 各仅一处 |
| §3 空实现 | 1 | #7 的 `catch (error: Exception) { () }`。其余逐个核对：`FailingLoomStore`（`LoomWiringSupervisor_test.cj:26-41`）是显式「存储不可用」桩、`CountingStore`（`LoomWiringGateway_test.cj:26-33`）是计数桩、`ChatRecorder`/`PromptRecorder`/`FakeScheduler` 是记录桩，均属测试替身不判；`LoomTimeout`/`PromptCapabilities`/`Prompts`/`RetrievalEval`/`RetrievalEvalRunner`/`LoomWiring` 的 `private init() {}` 是「静态工具类」惯用法（配 `public static func`），不是空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`Plan.validate`/`toJson`、`Planner.parse`/`stripFence`/`userPrompt`、`RetrievalEval.evaluate`/`ndcgOf`、`RetrievalEvalRunner.run` 全是单层循环（`ndcgOf` 内层上界是 `expected.size`，量级 ≤ topK）；无自引用结构的深度遍历。JSON 递归解析在 `f_data`（不属本部分） |
| §5 OOM | 0 | 唯一「全量物化」是 `RetrievalEval.linesOf` 的 `readToEnd()`（按 §11 资源问题记 #15；规模受本地语料约束：50 条 / 53 行）；`evaluate` 的 `statMap`/`reciprocalMap`/`ndcgMap` 键数=主题数、`misses` 上限=正样本数，均有界；评测与定时任务不接请求主路径，无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据（`RetrievalQuality_test`/`RetrievalEval_test` 是功能用例，且 `cjpm test` 默认 `-O0`）。4 条疑似热点全部进「待验证假设」，不以缺陷计 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `synchronized` / `Mutex`（`grep` 核实），不存在锁内 I/O、锁内回调或锁顺序问题；`LoomWiring` 只在装配期写全局对象 |
| §6.3 并发串行 | 1 | #6：惰性初始化的重复构造（并发首次调用各建一份）。`LoomTimeout` 的 `spawn` + 轮询不是「形式并发实际串行」（确实并发执行，问题在同步通道，记 #2） |
| §6.4 低效算法 | 0 | 静态可判的低效点规模都极小且无数据：`Plan.validate` 每条边一次线性 `step()`（O(E·S)，S ≤ 数十）、`EvalReport.render` 主题选择排序 O(12²)、`evaluate` 的 `expected` 内层扫描 O(topK·|expected|)。按 checklist 要求不足以成发现，已并入「待验证假设」#4 |
| §7 降堆内存方案 | 0 | 本部分对象都随调用结束释放：`TimeoutBox`（每调用一个）、`PlannerResult`/`FlowPlan`/`StepPlan`（随请求）、`EvalReport`/`TopicStat`（每轮评测）、`titleToId`/`statMap`（随 `run` 结束），无长期持有容器；`readToEnd` 的峰值问题并入 #15 的修法（改流式），不单列方案 |
| §8 降 CPU 方案 | 1 | `jsonQuote` 的两次全量字节拷贝（`无基线（待验证）`）。其余候选（nDCG 双重循环、选择排序、报表字符串拼接）规模太小，不进方案 |
| §9 local mode 可行性 | 0 | 不可行 / 无收益证据：本部分热点对象（`FlowPlan`/`StepPlan`/`PlannerResult`、拼接中的 JSON 串、`EvalReport`）全部**逃逸**（作为返回值、写入 `LoomRegistry`/`LoomResult`、进 `HashMap`），`@ local!` 约束下不成立；`jsonQuote` 的临时数组虽不逃逸，但收益是分配量而非峰值内存，且缺 `getAllocatedLocalObjectSize()` 前后对照，只能作假设 |
| §11 现有代码的 BUG（存量） | 10 | #1-#3、#5、#7-#11、#15 按 §11 记（#13/#14 归 §2，#16/#19 归可读性，#17 归 §1，#18 归注释一致性）。已核对的关键边界：`planOf` 的 `args`/`async`/`edges.size != 2` 三处回落、`stripFence` 的空体与无闭合围栏、`readCases` 的「既非负样本又无期望」跳过、`evaluate` 的 `rank`/`positiveTotal` 分母、`ndcgOf` 的 `ideal<=0` 保护、`percent` 的除零、`ScheduleFunctions` 的空 name / 空 cron、`evolutionOwner` 的三级回落、`RetrievalEval.defaultDir` 的 `None` 回落 |
| §12 并发安全与锁粒度 | 3 | #2（`TimeoutBox` 跨线程无同步，数据竞争）、#6（`LoomGatewayHolder` check-then-write）、#3（评测覆盖进程级 `SkillCatalog`，异常不还原）。已核对的「看似共享但安全」点：`LoomHostApi` 的存储注册有锁（`LoomHostApi.cj:157-179`，回调在锁外执行——这正是 #6 的可达路径）；`LoomSchedules`/`LoomServices`/`LoomWiring.reload` 只在装配期写、运行期读，按「装配期写」约定不单列（可见性无保证与 part15 同类，不重复报）；`RetrievalQuality_test` 的 `SkillCatalog.install/reset` 在 `finally` 成对出现 |
| §14 功能完备性与 README 覆盖 | 3 | #4（`onUnresolved` 承诺未接线）、#5（提示词放出 `http` 而校验器拒绝）、#9（空步骤 / 未知 status 当合法计划）。README 覆盖已对照：本部分对外符号 `StepPlan`/`FlowPlan`/`EdgePlan`/`LoomException`/`Planner`/`PlannerResult`/`LoomRequest`/`ClarifyQuestion`/`Prompts`/`PromptCapabilities`/`LoomTimeout`/`LoomWiring.lastReload`/`evolutionOwner`/`RetrievalEval*`/`EvalReport`/`TopicStat`/`EvalCase`/`EvalDoc`/`ScheduleCreateFunction`/`ScheduleDeleteFunction` 在 `f_llm/README.md` 均可检索到（`Prompts.PLANNER_SYSTEM` 作常量未单列，属可接受的信息层级） |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完；**无 `.md`**，故 §13 文档一致性命中 0 条——但已用 `doc/f_llm.md:375-376`、`doc/loom.md:105/204`、`doc/retrieval-eval.md:101-105/122-133`、`README.md:14/143/969/1020` 交叉核对承诺（漂移分别归 #4 / #5 / #3 / #8，KDoc 类问题归 #16） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量 19 条（严重 3 / 一般 7 / 轻微 9），是否纳入修复待用户决定；本部分未发现「本次改动」引入的问题（工作区快照无源码 diff，`git blame` 命中的提交均为 2026-11-01 ~ 11-07）。范围外提示一句：`LoomStoreGateway.buildCount`（`LoomStoreGateway.cj:47/61/69`）是普通 `static var` 自增，并发构造会丢计数——它是 #6 唯一可用的「只建一次」断言依据，做并发修复时应顺手改成原子计数。

## 总评

这 20 个文件的骨架是清楚的：`Plan`/`Planner` 把 LLM 产出的 JSON 收敛成受校验的 `FlowPlan`，`LoomWiring` 用一句 `wire` 把服务、宿主、网关、调度、演进接上，评测侧把「算指标」（`RetrievalEval`）与「接真实编码器」（`RetrievalEvalRunner`）拆成两层，测试覆盖了主路径与主要错误分支，`validate` 的报错文案都带步骤 id，可排错性不错。分层与命名没有明显问题。

**阻塞项三个**：#1 `Planner.parse` 剥了围栏却仍解析原始串——「模型输出被代码块包住」是最常见的真实情况，当前实现把它变成一次裸 `JsonException`，`stripFence` 在这个入口等于白写；#2 `LoomTimeout` 用无同步的普通字段跨线程传结果，数据竞争可能把空串当成功、也可能对已完成的调用误报超时；#3 评测入口会清空整库技能并覆盖进程级 `SkillCatalog`，误传生产 store 即不可回滚地丢数据。三者修法都很短（换 `trimmed` + `try/catch`；换 `Future.get(Duration)` 或原子发布；清库改成按标题命中删除 + `finally` 还原）。

其余按严重度排期即可：#4/#5/#9 是「契约写了、实现没跟上」（`onUnresolved` 无消费点、提示词放出 `http` 而校验器拒绝、空计划被当合法计划落库），#6/#10 是并发与全局状态（网关可能建两份、注入的 store 并不隔离演进族存储），#7/#8 是「失败被静默」（cron 异常无日志、标题映射丢命中），#11-#19 属校验完整度、重复逻辑与文档卫生，可以合并到同一次清理里做。

性能方面只有一条候选（`jsonQuote` 的两次字节拷贝）与四条待补数据的假设，本轮不产出性能结论、不进入修复清单。
