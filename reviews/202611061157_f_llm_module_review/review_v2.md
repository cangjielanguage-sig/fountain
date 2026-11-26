已完成全部定位与阅读。以下是审查报告内容（**注意：本 Agent 仅有只读工具，无法写文件，报告内容如下，需由调用方落盘**）。

---

```markdown
# R2: loom 内「读」记忆/知识/经验/技能 是否完全支持

审查时间：2026-11-06 12:05（worktree `f_llm`，HEAD `d5385cec`，只读锚定）

### 审查范围

- `src/loom/LoomStoreGateway.cj`、`src/loom/StoreFunctions.cj`
- `src/loom/LoomHostApi.cj`、`src/loom/LoomJitBridge.cj`、`src/loom/LoomCompiler.cj`、`src/loom/CodeGen.cj`
- `src/loom/LoomRunner.cj`、`src/loom/LoomService.cj`、`src/loom/LoomWiring.cj`、`src/loom/Plan.cj`
- `src/loom/SkillCatalog.cj`、`src/loom/LoomMemoryPolicy.cj`、`src/loom/JitTicktockTask.cj`
- 测试：`LoomStoreGateway_test.cj`、`StoreFunctions_test.cj`、`LoomPersona_test.cj`、`LoomMemoryE2E_test.cj`、`DefaultLoomHost_test.cj`
- 契约参照：`src/store/StoreContracts.cj`、`src/store/StoreModels.cj`
- 文档参照：`doc/loom.md:125-150`、`doc/loom.md:425-457`、`doc/loom.md:525-553`

### 结论速览

**总体：四个目标中 2 个达标、2 个部分达标。kind×op 矩阵基本齐全且返回都带正文，但 `experience.list` 有确定性语义错误，工具侧读能力弱于网关，`run(skills:)` 在生产入口不可达。**

| 目标 | 结论 |
|---|---|
| 1) kind×op 矩阵 / 参数校验 / 返回正文 | **部分支持**：op 全部存在；`experience.list` 丢过滤（严重）；校验仅有 1 处；正文齐全（`knowledge.search` 缺 title） |
| 2) JIT 注入点与 `{step.output}` | **部分支持**：三个函数注入点正确且作用域覆盖 LoomCompiler/CodeGen 两条路径；模板替换覆盖跨步骤，但 **jit 步骤不替换** |
| 3) `memoryCall`/`knowledgeIngest` 与网关同路径 | **部分支持**：生产存储同一（都落 `Stores`），但注入点不同、`memoryCall` 读 op 少 3 个、`knowledgeIngest` 比网关校验更严 |
| 4) `SkillCatalog` 自动注入 + `run(skills:)` | **部分支持**：自动挑选链路完整并有测试；`run(skills:)` 只对代码直调 `LoomRunner` 生效，`loomExecute`/Supervisor/定时任务一律拿不到 |

#### kind×op 逐条核对

| kind | op | 代码位置 | 存在 | 结论 |
|---|---|---|---|---|
| memory | get | `LoomStoreGateway.cj:123-128` | ✔ | 已支持（返回含 content） |
| memory | list | `:129-149` | ✔ | 已支持（`kind` 存在时走 `listByKind`） |
| memory | listByKind | `:136` | ✔ | 已支持（同一 `list` 的分支，非独立 op） |
| memory | search | `:150-181` | ✔ | 已支持（返回 id/title/content/kind/score） |
| memory | remove | `:182-184` | ✔ | 已支持 |
| experience | 别名 + kind 强制 | `:72-73`、`:73/118/157` | ⊘ | **部分支持**：`add`/`search` 用 `kindOf(defaultKind)`；**`list` 未用 `defaultKind`** |
| knowledge | get | `:76-84` | ✔ | 已支持（docId/title/content） |
| knowledge | docIds | `:85-88` | ✔ | 部分支持（缺省 limit=0 → `[]`） |
| knowledge | search | `:97-112` | ✔ | 已支持（缺 title，见 M1） |
| knowledge | upsert | `:92-96` | ✔ | 已支持（不校验 docId） |
| knowledge | remove | `:89-91` | ✔ | 已支持（无测试） |
| skill | load | `:212-221` | ✔ | 已支持（按 title 精确匹配，线性扫全表） |
| skill | get | `:194-199` | ✔ | 已支持 |
| skill | list | `:200-211` | ✔ | 已支持 |
| skill | count | `:191-193` | ✔ | 已支持（全量 list 取 size） |
| skill | remove | `:188-190` | ✔ | 已支持（无测试） |
| skill | **search** | 无 | ✘ | **未支持**：流程内无法用 `SkillCatalog` 检索技能 |

### 发现

#### [严重] `experience.list` 丢失 kind 强制，静默返回全部 kind 的记忆

- **位置**：`src/loom/LoomStoreGateway.cj:129-138`（对照 `:150-160`）
- **描述**：`experience` 别名的 kind 强制只做了一半。`search` 分支通过 `kindOf(args, defaultKind)`（`:157`）把缺省 kind 补成 `experience`；`add` 分支同样（`:118`）。但 `list` 分支取的是 `let kindFilter = strOf(args, 'kind')`（`:130`），**完全没有引用 `defaultKind`**，于是 `loomStore("experience","list","{...}")` 在未显式给 `kind` 时走 `content.memory.list(...)`（`:132`），返回**所有 kind** 的记录。
- **证据**：`defaultKind` 在 `:73` 定义，全文件只在 `:118`、`:157` 被使用，`list` 分支未出现。`doc/loom.md:545` 明确写着「`experience`｜同 `memory`｜同上，`kind` 缺省 `experience`」，与代码矛盾。测试侧只有 `LoomStoreGateway_test.cj:127-135` 的 `testExperienceAliasesMemoryWithKind`，只断言 `add` + `search`，没有 `experience.list` 用例，所以该缺陷一直未被发现。
- **影响**：流程按 `experience.list` 取「可复用经验」时会拿到普通 `note` 记录，模型无法区分事实与经验，属于静默错答（不是崩溃，比崩溃更难发现）。
- **建议**：`let kindFilter = kindOf(args, defaultKind)`，让 `list` 与 `search` 走同一套补全；补一条 `testExperienceListFiltersKind`（写入 `kind=note` + `kind=experience` 各一条，断言 `list` 只返回后者）。

#### [严重] 执行期状态是进程级静态单例，并发流程互相清空 system 注入并解除 host 绑定

- **位置**：`src/loom/LoomHostApi.cj:29-31`、`:42-45`、`:97`、`:145`、`:168`；`src/loom/LoomRunner.cj:207`、`:223-225`；`src/loom/LoomContextLog.cj:51-53`
- **描述**：`current`（host）、`values`、`storeGateway`、`personaText`、`skillText` 全部是 `LoomHostApi` 的 `private static`，`LoomContextLog.turns/active` 同样是静态单例。`LoomRunner.runCompiled` 在 `:207` `bind(host)`，在 `finally` 的 `:223-225` 依次 `unbind()` / `clearPersona()` / `clearSkills()`。只要两个流程在执行期重叠，后结束的一方会把另一方的 persona/skill 注入和 host 绑定一起清掉：另一方的后续 `loomCallLlm` 会拿不到技能块，`loomCallTool` 直接抛 `loom host is not bound`；`LoomContextLog` 的记录还会串到别的流程的 `LoomMemoryExtractor.extract`（`:228`）里。
- **证据**：`LoomHostApi.cj:29-31` 自带注释「约束：**单线程使用**。执行前 `bind`，执行完 `unbind`；并发流程需各自持有独立进程或改为显式传参（当前 loom 的执行模型是单流程串行）」。但代码里已有三条会重叠的入口：`LoomRunner.cj:210-214` 的 `parallel=true` 走 `AsyncFlow` 并发分支；`ScheduleFunctions.cj:82-92` 的 cron 线程直接 `executeNow`；`Supervisor.cj:183` 的派发线程。约束只写在注释里，没有任何运行时防线（如"已绑定则拒绝"，或 runId 作用域）。
- **建议**：至少把 `persona/skill/host` 收进一个「执行上下文」对象，由 `runCompiled` 创建并通过参数传给步骤闭包（`LoomHostApi` 只保留只读兼容层）；或在 `bind` 时检测已绑定并抛 `LoomException`（把注释里的"单线程"变成一个可失败的断言），同时把 `LoomContextLog` 改为按上下文实例化。

#### [一般] `experience.search` 默认读不到 `experience_failed`

- **位置**：`src/loom/LoomStoreGateway.cj:156-160`；`src/loom/LoomMemoryPolicy.cj:120-122`
- **描述**：`experience.search` 缺省只把 `'experience'` 放进 `kinds`。而失败流程写的是 `kind='experience_failed'`（`LoomMemoryPolicy.cj:121`），恰恰是最值得复用的教训，默认检索路径完全读不到。模型要么知道这个 kind 名并发两次调用，要么就永远只看到成功经验。
- **证据**：`kinds` 是 `Array<String>`（`StoreModels.cj:64`、`:139` 里是 OR 语义），但网关只 `kinds.add(kindValue)` 一个元素（`:158-160`）。
- **建议**：`experience` 缺省时把 `['experience','experience_failed']` 一起放进 `kinds`；或新增 `includeFailed`（缺省 `true`）。补一条断言两个 kind 都能命中的用例。

#### [一般] `memoryCall` 的读能力弱于网关，且绕过 `installStore` 注入点

- **位置**：`src/loom/StoreFunctions.cj:62-66`、`:74-79`；对照 `src/loom/LoomWiring.cj:72-74`
- **描述**：两点不对称：
  1. **op 少**：`memoryCall` 只放行 `search|add|remove`（`:63`），网关支持 `get`/`list`/`get+listByKind`（`LoomStoreGateway.cj:123-149`）。模型若只靠工具入口（`kind=tool` 的步骤），无法按 id 取单条、无法按 namespace/kind 列举，"按 id 精确回读"这种最常用的读法没有入口。
  2. **注入点不同**：`loomStore` 走 `LoomHostApi.storeGateway`（`LoomHostApi.cj:99-121`，由 `LoomWiring.cj:72-74` 装配）；`memoryCall` 走 `target()` 里 `LoomStoreGateway()` **每次调用新建**（`StoreFunctions.cj:74-79`），只认构造参数 `gateway!`，完全不看 `installStore`。生产环境两者最终都落到 `Stores.content()/meta()`（`LoomStoreGateway.cj:60-65`），所以数据一致；但**装配期一旦替换了网关（测试、灰度、mock），两条入口就会读到不同的库**。
- **证据**：`LoomStoreGateway_test.cj:221`、`LoomMemoryE2E_test.cj:131` 都用 `LoomHostApi.installStore(...)`；而 `StoreFunctions_test.cj:57` 必须显式 `MemoryCallFunction(gateway: gateway)`——说明注入点确实是两套。
- **建议**：`memoryCall` 的 `target()` 优先复用 `LoomHostApi` 已安装的网关（加一个 `LoomHostApi.currentStoreGateway()`），并在 op 白名单里补 `get`/`list`（与网关行为严格同源）。

#### [一般] `kind=tool` 的步骤没有任何「读知识 / 读技能 / 读经验」的工具

- **位置**：`src/loom/StoreFunctions.cj:41-136`（全仓仅 `memoryCall`、`knowledgeIngest` 两个 store 相关工具）
- **描述**：`knowledgeIngest` 只做写入（`knowledge.upsert`），没有对应的 `knowledgeSearch`/`knowledgeGet`；技能、经验在工具侧完全没有入口。 consecuencia：一旦模型产出的计划用 `kind=tool`（而不是 `kind=jit`）来取事实，它能读的只有记忆，读不到知识库、技能正文、经验。而 `doc/loom.md:125-126` 的能力清单给模型看到的正是这两个工具名，容易让它误以为"工具入口已覆盖读写"。
- **证据**：`memoryCall`（`:51`）与 `knowledgeIngest`（`:105`）是 `src/loom` 下唯一两个 `FunctionCalling` 存储入口；`grep 'memoryCall|knowledgeIngest'` 无第三个。
- **建议**：要么补 `knowledgeSearch`/`skillLoad` 两个工具（与网关同源），要么在 `doc/loom.md:125-126` 明确标注「工具入口只覆盖记忆；知识/技能/经验必须用 `kind=jit` + `loomStore`」。

#### [一般] `kind=jit` 的步骤不做 `{step.output}` 模板替换

- **位置**：`src/loom/LoomCompiler.cj:82-88`（对比 `:105-112`、`:114-121`）；`src/loom/CodeGen.cj:111-126`
- **描述**：`compileTool`（`:108`）与 `compileLlm`（`:117`）都先 `LoomHostApi.render(...)`；`compileJit` 直接把 `step.input` 原样当源码编译，`CodeGen.flowSource` 对 jit 分支（`:121-124`）也一样不 render。于是 `render` 的跨步骤替换（`LoomHostApi.cj:69-87`）对 jit 完全不生效——而 jit 是唯一能调 `loomStore` 的步骤类型，也就是说「把上一步输出拼进 `memory.search` 的 payload」这件事只能靠 JIT 代码里手工写 `e`（上一条事件 data），跨两步以上或汇聚场景取不到值。
- **证据**：`values` 表由 `taskEvent` 写入（`LoomHostApi.cj:195-200`），三个 `compileXxx` 都会调；但读取只发生在 `:108`/`:117`。`LoomMemoryE2E_test.cj:168-176` 的用例是 `ms`/`ks`（jit）→ `ask`（llm）用 `{ms.output}`，即"jit 产出、llm 消费"能通，"llm 产出、jit 消费"没有用例覆盖，也没有实现支撑。
- **建议**：在 `compileJit` 里对 `step.input` 也做一次 `render`——但 JIT 源码里的 `{`/`}` 会与代码冲突，更稳的做法是提供一个 JIT 内可调的函数（如 `loomValue("s1")`，转发 `LoomHostApi.valueOf`），让 jit 步骤能显式取任意历史步骤输出。

#### [一般] 缺省 `limit` 为 0 导致 `docIds` / `memory.list` 静默返回空数组

- **位置**：`src/loom/LoomStoreGateway.cj:85-88`、`:129-138`、`:341-356`
- **描述**：`intOf` 缺字段一律返回 0（`:354`），`docIds` 与 `list` 又直接把 0 透传给存储。`list`/`docIds` 的实现是 `index < offset + limit`（`InMemoryStores.cj:160`），`limit=0` 时结果恒为空。于是 `loomStore("knowledge","docIds","{}")` 或 `loomStore("memory","list","{\"userId\":1}")` 返回 `[]` 而不是报错——这正是 :44 注释所说的"静默返回空被流程当成真实结果"的场景，却在同一文件里存在。同文件 `search` 分支（`:100`、`:164`）已经有 `if(limit>0){limit}else{5}` 的保护，两套规则不一致。
- **证据**：`LoomStoreGateway_test.cj:49` 把 `limit:0 → []` 固化成了期望值（`testKnowledgeUpsertThenDocIds`），说明这是"被测试保护住的行为"，改之前需要先改测试。
- **建议**：`docIds`/`list` 也采用与 `search` 一致的缺省值（如 `limit<=0 → 50`），并在测试里断言"缺省 limit 能取到已写入的记录"；若确实要保留 0 即空的语义，至少在 `docIds` 缺 `limit` 时抛 `LoomException`。

#### [一般] 参数校验缺失且两套入口不一致

- **位置**：`src/loom/LoomStoreGateway.cj:76-96`、`:116-137`、`:188-199`；对照 `:256-259`、`src/loom/StoreFunctions.cj:116-118`
- **描述**：全文件只有 `prompt.put` 校验了 `name`（`:256-259`）。其余读/写 op 一律靠 `strOf`→`''`、`intOf`→`0` 静默兜底：`knowledge.upsert` 可以写入 `docId=''` 的文档；`knowledge.get/remove` 缺 `docId` 时返回 `''`/`false`；`memory.add` 缺 `userId` 时写入 `userId=0` 的孤儿记录（`MemoryPolicy` 用非 0 userId 的调用方永远读不到）；`skill.load` 缺 `title` 时可能与某个 title 为空的技能匹配上。而工具入口 `knowledgeIngest` 明确校验了 `docId`（`StoreFunctions.cj:116-118`）——**同一个 upsert 能力，工具比网关严**。
- **建议**：对"按 id/docId 取或删"的 op 在 `id<=0`/`docId=='0'` 时抛 `LoomException`（与 `:311` 的 unsupported 一致，让错误可见）；给 `knowledge.upsert` 补 `docId` 非空校验（与工具对齐）；`memory.add` 校验 `userId>0`。

#### [一般] `run(skills:)` 在生产入口不可达，流程无法声明技能

- **位置**：`src/loom/LoomRunner.cj:121-131`、`:134-137`；`src/loom/LoomService.cj:122-134`；`src/loom/LoomFunctions.cj:57-79`；`src/loom/Plan.cj:67-76`
- **描述**：`skills!` 是 `run`/`runCompiled` 的命名参数，但唯一的执行入口 `LoomService.executeNow` 在 `:133` 调 `LoomRunner(...).run(plan, host, input, parallel: ...)` 时**不传 skills**；`loomExecute` 的参数表（`LoomFunctions.cj:57-79`）没有 `skills`；`FlowPlan`（`Plan.cj:67-76`）也没有 skills 字段，`Planner` 不解析。所以 `run(skills:)` 只对"代码里直接 new LoomRunner"的调用方有效。对由 `loomExecute` 生成、Supervisor 派发、cron 触发的流程，技能只能靠 `policy.autoSkills` 自动挑选（`LoomRunner.cj:194-199`）。
- **证据**：`skills: [` 的全部调用点都在测试里（`LoomPersona_test.cj:106`、`LoomMemoryE2E_test.cj:135`、`:394`），生产代码零调用。
- **建议**：把 `skills` 纳入 `FlowPlan`（并让 `Planner` 解析、`FlowPlan.toJson` 输出），`executeNow` 从 `plan.skills` 透传；`loomExecute` 也加一个 `skills` 参数。否则 scope 里"`run(skills:)` 显式注入"这条只有代码层可用，流程层不可用。

#### [一般] `skill` 缺 `search` op，`SkillCatalog` 的检索能力对流程不可达

- **位置**：`src/loom/LoomStoreGateway.cj:187-240`；`src/loom/SkillCatalog.cj:141-186`
- **描述**：网关的 `skill` 只提供 `get/list/count/load/upsert/remove`，`load` 是**标题精确相等**的线性扫描（`:215-219`）。`SkillCatalog.search` 既支持向量余弦也支持关键词/字符命中率，但唯一调用点在 `LoomRunner.cj:195`（自动挑选系统侧），JIT 步骤无法用它。「按任务描述找技能」这一步在流程内只能靠模型猜标题。
- **建议**：加 `skill` 的 `search` op（payload `{"text","topK","minScore"}`，返回 `[{title,details,score}]`），复用 `SkillCatalog.search`。

#### [一般] 读取路径的测试覆盖缺口

- **位置**：见下表
- **描述**：核心读路径大多有 E2E 覆盖，但下列分支没有任何用例，其中两项恰好是本轮发现缺陷的地方。

| kind.op | 覆盖情况 |
|---|---|
| knowledge.remove | 无用例 |
| **experience.list** | **无用例（即 S1 缺陷所在）** |
| experience.get / remove | 无用例 |
| **experience_failed 检索** | **无用例（即 G1 缺陷所在）** |
| skill.remove | 无用例 |
| `{llm步骤.output}` 被 jit 消费 | 无用例（即 G4 的缺口） |
| `run(skills:)` 经 `executeNow` 生效 | 无用例（即 G7 的缺口） |
| **已有覆盖（断言点）** | `testFlowSearchReachesModel`（`LoomMemoryE2E_test.cj:156`，断言 `cangjie 关键字记忆`/`cangjie 关键字知识` 进入 input）；`testExperienceSearchReachesModel`（`:198`）；`testSkillListAndGetReachModel`（`:230`，断言 `"title":"日报助手"`/`三段式…`/`"version":1`）；`testFlowRetrievalReachesModel`（`:128`，断言记忆/知识/经验都进 input、人格+技能进 system）；`testSkillsInjectedIntoSystem`（`LoomPersona_test.cj:98`）；`testAutoSelectsSkillByTaskText`（`:233`）；`testSkillLoadByTitle`（`:259`）；`testJitStepCallsStoreGateway`/`testJitStepQueriesEvolutionReport`（`LoomStoreGateway_test.cj:244`/`:215`）；`LoomHostApi.render` 跨步骤（`DefaultLoomHost_test.cj:40-43`，断言 `sum: A`）与未命中保留占位符（`:53`） |

#### [轻微] `knowledge.search` 不返回 title，`skillJson` 不返回 functions

- **位置**：`src/loom/LoomStoreGateway.cj:108-109`、`:367-371`
- **描述**：`knowledge.search` 只给 `docId/seq/score/content`，模型拿不到文档标题（`knowledge.get` 是给的），多文档场景难辨来源；`skillJson` 只给 `id/title/details/version`，丢掉了 `functions`（技能绑定的工具），流程无法据技能声明去 `loomTool` 白名单。
- **建议**：`knowledge.search` 补 `title`（若 `KnowledgeHit` 不带 title，可按 `docId` 回查一次，或扩展 hit 模型）；`skillJson` 补 `functions`。

#### [轻微] `skill.count` / `skill.load` 每次都全量 `list()`

- **位置**：`src/loom/LoomStoreGateway.cj:191-193`、`:212-221`、`:227-231`
- **描述**：`count` 用 `meta.skills.list().size`，`load` 线性遍历，`upsert` 分配 id 时又遍历一遍取 `maxId`。内存/几十条技能无感，但 SQL 后端每次都是整表读 + 逐行构造 `Skill` 对象（`src/store/postgres/MetaStore.cj:94-100`）。JIT 步骤若在一个流程里 load 多个技能，就是 N 次全表扫描。
- **建议**：`SkillStore` 补 `count()`/`getByTitle(title)`；或网关内部对 `list()` 做一次短 TTL 缓存（`SkillCatalog` 已有按 `标题#版本` 缓存向量的先例）。

#### [轻微] 网关抛异常、工具返回错误文本，两套错误语义并存

- **位置**：`src/loom/LoomStoreGateway.cj:311`；`src/loom/StoreFunctions.cj:64-71`、`:117`、`:125-127`
- **描述**：`memoryCall` 把非法 op 变成 `FunctionResult` 文本（流程继续），`loomStore` 直接抛 `LoomException`，异常穿过 JIT 闭包 → 步骤 → `flow.start`，整个流程失败（只留下一条 `experience_failed`）。而 `doc/loom.md:145` 把 op 压成一个跨 kind 的并集（`search | get | list | load | add | upsert | remove | docIds | count | latest | put | set | reset | by_skill`）交给模型，模型很容易写出 `memory.docIds` 这种"文档上合法、实现上不存在"的组合，代价是整条流程崩掉。
- **建议**：文档改成按 kind 分列合法 op（网关头部注释 `:26-42` 已经是这个形态，直接搬进 doc），或在 JIT 侧提供一个"错误也返回文本"的变体 `loomStoreSafe`。

#### [轻微] `resolveSkills` 把多行技能正文压成单行、未命中静默

- **位置**：`src/loom/LoomRunner.cj:449-471`
- **描述**：注入块用 `'- ${title}：${details}\n'` 拼（`:462`），`details` 里的换行原样保留但整体只占一行前缀，多技能时结构上是"一行一条"；标题未命中时 `continue`（`:456`），既不报错也不在 `LoomContextLog` 留痕（`doc/loom.md:455` 注明这是设计）。可接受，但排查"为什么技能没生效"时没有观测点——`SkillCatalog.embedFailures()` 有计数，这里没有类似计数。
- **建议**：加一个 `resolveMisses` 计数（与 `SkillCatalog.embedFailureDetail` 同风格），或在提取阶段的经验正文里带上"本次加载技能：X/Y"。

#### [轻微] `JitTicktockTask` 调度的步骤没有 host 绑定，`loomCallLlm/loomCallTool` 不可用

- **位置**：`src/loom/JitTicktockTask.cj:37-52`
- **描述**：任务体只 `fn(StartEvent(...))`，没有 `LoomHostApi.bind`，也没有 persona/skills 注入。因此被调度的 jit 步骤里 `loomStore` 可用（它只依赖 `installStore`），但 `loomCallLlm`/`loomCallTool` 会抛 `loom host is not bound`，且拿不到技能块。测试 `JitTicktockTask_test.cj:106` 手动 `LoomHostApi.bind(host)` 恰好掩盖了这一点。当前该类只有测试在用，暂列轻微。
- **建议**：任务体内 `bind/unbind` 一次（复用 `LoomServices.currentHost()`），或在类注释里写明"被调度步骤只能做纯计算 + loomStore"。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 5 |

### 总评

kind×op 矩阵的**覆盖面**是这次审查里表现最好的一块：scope 列出的 memory(get/list/search/listByKind/remove)、knowledge(get/docIds/search/upsert/remove)、skill(load/get/list/count/remove) 全部真实存在，`experience` 别名也确实复用了同一条记忆链路而不是另造存储，没有发现"文档说支持、代码没实现"的空壳 op。返回值在"能否直接喂模型"这一点上基本达标——`memory.get/list/search`、`knowledge.get/search`、`skill.load/get/list` 都带正文，`recordJson`/`skillJson` 是集中收敛的，不存在某条路径只给 id。

问题集中在三处**语义偏离**，而不是缺功能：

1. `experience.list` 忘了走 `kindOf`，与同文件 `add`/`search` 以及 `doc/loom.md:545` 三处不一致——这是本轮唯一的确定性逻辑错误，改动量一行，但因为没有 `experience.list` 的测试而一直存在。
2. 读能力在"两套入口"上不对称：网关 6 个 memory op，`memoryCall` 只有 3 个；工具侧完全没有知识/技能/经验的读入口。生产存储是同一条（都落 `Stores`），但注入点分叉（`installStore` vs 每次 `new LoomStoreGateway()`），意味着"换网关"这类装配动作无法同时作用于两条入口。
3. `run(skills:)` 作为 scope 里点名的显式注入手段，生产上不可达——`executeNow`/`loomExecute`/`FlowPlan` 三层都没有 skills 的传递路径，流程层只能吃自动挑选。

`LoomHostApi.render` 的跨步骤替换本身实现正确（`values` 随 `bind` 重置、未命中保留占位符，且 `DefaultLoomHost_test.cj:40-43`/`:53` 双向断言覆盖），缺的只是 jit 步骤这一路；`SkillCatalog` 自动挑选 + `skill.load` 注入 system 的链路是完整且经过 E2E 验证的（`LoomMemoryE2E_test.cj:128`、`LoomPersona_test.cj:98/233/259`），这段代码质量较好。

最后，`LoomHostApi.cj:29-31` 那句"约束：单线程使用"是整块设计里最需要正视的地方——它是一句注释，而 `AsyncFlow` 并行、cron 调度、Supervisor 派发三条并发路径已经都在代码里了，`finally` 里的 `clearSkills/clearPersona/unbind` 会在重叠执行时互相踩。这条建议优先于其它所有条目处理。
```

---

需要说明：我的工具集只有 `search_file` / `search_content` / `read_file` / `lsp`，**没有写文件能力**，因此上面的报告没有落盘到 `review_v2.md`，需要调用方（或具备写权限的 Agent）将上述 markdown 内容写入该路径。

REVIEW_WRITTEN:D:\docs\work\cangjie\projects\fountain\.worktrees\f_llm\reviews\202611061157_f_llm_module_review\review_v2.md