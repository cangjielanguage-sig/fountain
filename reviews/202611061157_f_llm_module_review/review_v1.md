## 说明（重要）

本 Agent 只挂载了只读检索工具（`read_file` / `search_content` / `search_file` / `lsp`），**没有写文件能力**，因此下面的完整报告内容尚未落盘到 `review_v1.md`。请主 Agent 将“报告正文”整段写入目标路径（内容已按 `reviewer.md` 的格式定稿，可直接保存）。

---

# R1: 死代码与功能重复

审查时间：2026-11-06

### 审查范围

被审代码（feature/f_llm 工作树）：`f_llm/src/**`，重点：
`loom/LoomStoreGateway.cj`、`loom/StoreFunctions.cj`、`loom/LoomMemoryPolicy.cj`、`loom/BackgroundTasks.cj`、`loom/LoomJitBridge.cj`、`loom/LoomHostApi.cj`、`loom/CodeGen.cj`、`loom/Plan.cj`、`loom/Planner.cj`、`loom/SqlLoomStore.cj`、`loom/LoomRegistry.cj`、`loom/RetrievalEval.cj`、`loom/Supervisor.cj`、`loom/LoomBootstrap.cj`；
`store/StoreContracts.cj`、`store/Stores.cj`、`store/StoreSettings.cj`、`store/MemoryKinds.cj`、`store/MemoryStoreAdapter.cj`、`store/MemoryRepositories.cj`、`store/PostgresMemoryStore.cj`、`store/MemoryIndexRebuilder.cj`、`store/KnowledgeIndexRebuilder.cj`、`store/postgres|mysql/KnowledgeStore.cj`、`store/InMemoryStores.cj`；
`memory/Memory.cj`、`memory/FaithfulMemory.cj`、`memory/MemoryExtractor.cj`、`tool/MemoriesLoadingFunction.cj`、`channel/ChannelBootstrap.cj`、`agents/AgentTask.cj`。

文档参照：`f_llm/README.md`、`f_llm/doc/loom.md`、`f_llm/doc/known-limitations.md`。
检索根：`D:\docs\work\cangjie\projects\fountain\.worktrees\f_llm`（该工作树含全部模块，可作为“全仓”口径；跨模块消费方只有 `fcoder` 4 个文件，`f_llm` 的 loom/store 新 API 在仓外零引用）。

### 发现

#### [一般] 记忆写入有 5 条现行入口 + 2 条旧入口，其中一条绕过网关

- **位置**：`src/store/StoreContracts.cj:42`、`src/loom/LoomStoreGateway.cj:117-122`、`src/loom/StoreFunctions.cj:61-72`、`src/loom/LoomMemoryPolicy.cj:153-170`、`src/loom/BackgroundTasks.cj:31-38`、`src/memory/Memory.cj:119-130`
- **描述**：同一次“写记忆”有互不相同的 5 个上层入口，且 payload 由各自手拼 JSON；`memory/Memory.cj:124` 直接用 `MemoryStoreAdapter().add(...)`，**不经过** `LoomHostApi.callStore` / `LoomStoreGateway`，与 `LoomStoreGateway.cj:119-120` 的 JSON 字段约定（`userId/namespace/title/content/kind`）形成第二套协议；`Memory.cj:125` 写死 `namespace='global'`、`kind='session'`，而 `LoomMemoryPolicy.cj:52` 默认 `namespace='loom'`，loom 内 `loomStore("memory","search",{namespace:"loom"})` 永远召回不到这些摘要记忆。
- **证据**：
  - `search_content 'callStore\(|LoomStoreGateway\(\)|\.call\('memory'` → 生产写点：`LoomMemoryPolicy.cj:164`（`callStore('memory','add')`）、`BackgroundTasks.cj:37`（`gateway.call('memory','add')`）、`StoreFunctions.cj:68`（memoryCall→`call('memory',op)`）、`LoomStoreGateway.cj:121`（唯一 `content.memory.add`）。
  - `search_content 'MemoryStoreAdapter'` → 2 命中：`store/MemoryStoreAdapter.cj:28`（声明）、`memory/Memory.cj:124`（唯一调用方）。
  - `search_content 'Memory\.add|Memory\.remember'` → 旧链路：`memory/Memory.cj:27`、`agents/AgentTask.cj:510`（`Memory.add(e.session, all: messages)` 仍走 `FaithfulMemory`）。
- **建议**：收敛为“原语（`MemoryStore.add`）+ 一个上层写入口（网关）”；`Memory.remember` 改为 `LoomHostApi.callStore('memory','add', …)` 并复用 `LoomMemoryPolicy.namespace`/`LoomMemoryPolicy.userId`；把 payload 组装集中到一个 `MemoryPayload.of(...)`，禁止各处手拼。

#### [一般] 记忆读取存在新旧两条互不相通的链路

- **位置**：`src/tool/MemoriesLoadingFunction.cj:31-57`（旧）、`src/loom/StoreFunctions.cj:41-80`（新）
- **描述**：旧链路 `loadMemories` 工具 → `MemorySummaryFinder.query`（`memory_summary` 表，由 `Memory.summarise` 写入）；新链路 `memoryCall`/`loomStore("memory","search")` → `MemoryStore.search`。两套写入互不可见，两套读取也不互相覆盖，同一能力存在两份实现。
- **证据**：`search_content 'loadMemories|MemoriesLoadingFunction|MemoryLoading'` → 4 命中，全部落在 `src/tool/MemoriesLoadingFunction.cj` 本身（类名/`name` 属性/参数类），另有 1 处出现在 `README.md`、1 处 `doc/f_llm.md`；**全仓无任何代码引用该工具，也无单测**。
- **建议**：明确保留一套。若新链路为准，删除 `MemoriesLoadingFunction` + `MemorySummaryFinder` + `memory/Memory.cj` 的 summarise 分支（并同步 README:31、doc/f_llm.md）；若需兼容，至少在 README 标注 deprecated。

#### [一般] 检索融合逻辑在 memory / knowledge × 4 个后端各写一遍，权重常量散落 5 处

- **位置**：`src/store/PostgresMemoryStore.cj:90-169`（dense+sparse+colbert 融合）、`src/store/postgres/KnowledgeStore.cj:98+`、`src/store/mysql/KnowledgeStore.cj:98+`、`src/store/InMemoryStores.cj:248`
- **描述**：`MemoryStore.search` 与 `KnowledgeStore.search` 是两条平行链路，各自实现“向量召回 + 词面召回 + 归一化 + 排序”；`MemoryStore` 侧权重 `0.7/0.3`、rerank `0.4/0.6` 只在 `PostgresMemoryStore.cj:117,128-129` 内联，`KnowledgeStore` 侧 `LEXICAL_WEIGHT = 0.1` 在 `postgres/KnowledgeStore.cj:34` 与 `mysql/KnowledgeStore.cj:34` 重复定义，`InMemoryStores.cj:248` 又硬编码 `0.1f64`。
- **证据**：`search_content '0\.7f64|0\.3f64|0\.4f64|0\.6f64|0\.1f64'`（path=src/store）→ `PostgresMemoryStore.cj:117,128,129`；`postgres/KnowledgeStore.cj:34`；`mysql/KnowledgeStore.cj:34`；`InMemoryStores.cj:248`。另 `src/store/VectorMath.cj` 与 `f_hydra/src/VectorMath.cj` 是同一份向量数学的跨模块两份实现（`search_content 'ColbertCodec|VectorMath'` → `f_hydra/src/{VectorMath,VectorCodec,IvfIndex,FStoreVectorStore}.cj` 与 `f_llm/src/store/VectorMath.cj` 并存）。
- **建议**：抽出 `store/Fusion.cj`（`fuse(dense, sparse, weights)` + `rerank`），memory/knowledge 共用；权重常量集中到一个 `SearchWeights` 并支持配置（`known-limitations.md:118` 也把“词面权重不可配”列为已知限制）。

#### [一般] 工具与网关 op 重叠：`memoryCall` ⊂ `loomStore("memory")`，`knowledgeIngest` ≡ `knowledge.upsert`

- **位置**：`src/loom/StoreFunctions.cj:63`（`if(op != 'search' && op != 'add' && op != 'remove')`）、`src/loom/StoreFunctions.cj:119-124`（knowledgeIngest → `call('knowledge','upsert')`）、`src/loom/LoomStoreGateway.cj:115-185`（memory: add/get/list/search/remove）、`src/loom/LoomStoreGateway.cj:92-96`（knowledge.upsert）
- **描述**：`memoryCall` 的 op 白名单是网关 `memory` 分支的子集（缺 `get`/`list`），`knowledgeIngest` 是 `knowledge.upsert` 的一对一薄封装，二者都只是“参数改名 + 转发网关”。工具集里保留它们等于给同一能力两套模型可见的 schema，模型可能用错（例如 `memoryCall` 无 `list`，模型只能回退到 JIT 片段里的 `loomStore`）。
- **证据**：`search_content 'MemoryCallFunction|KnowledgeIngestFunction'` → 仅 `src/loom/StoreFunctions.cj`（2 命中，声明）与 `src/loom/StoreFunctions_test.cj`（4 命中）；生产代码中没有其它调用方，说明它们是“模型入口”而非“代码入口”，重复的是协议而不是代码。
- **建议**：二选一。保留工具则把 op 白名单对齐网关（补 `get`/`list`）并在描述里声明等价关系；或者删掉 `knowledgeIngest`，只留 `loomStore` 说明。

#### [一般] `LoomStore` 的 PG / MySQL 实现逐行同构，另有两套实现同场

- **位置**：`src/loom/SqlLoomStore.cj:124-155`（`PostgresLoomStore`）与 `:158-189`（`MySqlLoomStore`）；`src/loom/FStoreLoomStore.cj:43`；`src/loom/LoomRegistry.cj:95`（`MemoryLoomStore`）
- **描述**：两个 SQL 实现的 `save/get/list/remove` 方法体除 `dao<…LoomDAO>('postgres'|'mysql')` 外完全一致（含 `get(name).isSome()` 的先查后删写法），是典型的复制粘贴；共有 4 个 `LoomStore` 实现（f_store / memory / pg / mysql），选路由 `LoomBootstrap.storeFor` 硬编码 if 链（`LoomBootstrap.cj:47-62`），而内容族/元数据族走的是 `Stores` 注册表——两套选型机制并存。
- **证据**：`search_content 'PostgresLoomStore|MySqlLoomStore|FStoreLoomStore'` → 9 文件命中，其中 `SqlLoomStore.cj`（2）、`LoomBootstrap.cj`（3：`storeFor` 里的分支）、`EvolutionStore.cj:174` 与 `EvolutionStateStore.cj:173`（仅注释“与 FStoreLoomStore 共用配置”）。
- **建议**：抽 `SqlLoomStore(dialect: String)` 一个实现两个 bean，或把方言作为参数；选型统一走 `Stores` 风格注册表（`registerLoomStore(name, factory)`），去掉 if 链。

#### [一般] “选实现”职责被三层适配器重复承担

- **位置**：`src/store/MemoryRepositories.cj:28-33`（`MemoryRepositoryAdapter`）、`src/store/MemoryStoreAdapter.cj:28-42`（`MemoryStoreAdapter`）、`src/store/Stores.cj:68-97`（`Stores.content()/meta()`）
- **描述**：`MemoryRepositoryAdapter` = `lookupOption<MemoryRepository>() ?? 抛错`；`MemoryStoreAdapter` = `lookupOption<MemoryStore>() ?? Stores.content().memory`；`Stores.content()` = 按配置查工厂。同一“bean 优先、配置兜底”的策略被写了三遍，且 `MemoryStoreAdapter` 只有 `memory/Memory.cj:124` 一个调用方（见上条证据）。
- **建议**：只保留 `Stores` 一处选型；`*Adapter` 若只为“容器未初始化时可用”，应下沉到 `Stores` 的一个 `lookupOrStores()` 私有方法，删除两个 Adapter 类。

#### [一般] `experience` / `experience_failed` 未纳入 `MemoryKinds`，kind 字面量四处散落

- **位置**：`src/store/MemoryKinds.cj:44-50`（7 个预定义常量，无 `experience*`）、`src/store/MemoryKinds.cj:176-190`（`weightOf` 未知 kind 落 `0.8`）、`src/loom/LoomMemoryPolicy.cj:117,121`、`src/loom/SkillEvolutionJob.cj:260-261`
- **描述**：loom 侧写入的两种 kind 不在预定义集合里，`MemoryKinds.validate()` 会返回 false、`weightOf()` 落默认权重；同时 `'note'`（`LoomMemoryPolicy.cj:117`）、`'session'`（`memory/Memory.cj:125`）、`'experience'`（`LoomStoreGateway.cj:73`、`LoomMemoryPolicy.cj:121`、`SkillEvolutionJob.cj:260-261`）都是字面量，没有引用 `MemoryKinds.NOTE/SESSION` 常量——常量形同虚设。
- **证据**：`search_content 'experience_failed|.experience.'`（path=src/loom）→ `LoomStoreGateway.cj:72-73`、`LoomMemoryPolicy.cj:121`、`SkillEvolutionJob.cj:260-261`、`LoomMemoryE2E_test.cj:94,208`；`MemoryKinds.cj:77-87` 的 `predefined()` 只列出 note/fact/preference/task/doc/knowledge/session。
- **建议**：在 `MemoryKinds` 增加 `EXPERIENCE`/`EXPERIENCE_FAILED` 并给出权重；所有写入点改用常量（可用 `MemoryKinds.validate` 在 `LoomStoreGateway` 的 memory.add 分支做一次校验，非法 kind 立即报错而不是静默落 0.8）。

#### [一般] 零引用 / 仅自用的 public API（逐条证据）

| 符号 | 位置 | grep 命令 | 命中 | 判定 |
|---|---|---|---|---|
| `Stores.DEFAULT_CONTENT` / `DEFAULT_META` / `META_KEY` | `src/store/Stores.cj:30-32` | `Stores\.(CONTENT_KEY\|META_KEY\|DEFAULT_CONTENT\|DEFAULT_META)` | 全仓 2 命中，都是 `Stores.CONTENT_KEY`（`Stores_test.cj:80,83`） | **三个常量全仓零引用**；`CONTENT_KEY` 仅测试引用 |
| `MemoryIndexRebuilder`（含 `rebuildIfConfigured`） | `src/store/MemoryIndexRebuilder.cj:34,46-56` | `MemoryIndexRebuilder\|KnowledgeIndexRebuilder` | 9 文件，生产侧仅自身；`rebuildIfConfigured` 3 命中 = 自身 + 测试 + 文档 | **生产零调用入口** |
| `KnowledgeIndexRebuilder` | `src/store/KnowledgeIndexRebuilder.cj:28` | 同上 | 生产侧仅自身 | 生产零调用入口 |
| `TopicStat` | `src/loom/RetrievalEval.cj:60` | `TopicStat` | 2 文件：`RetrievalEval.cj`（6）、`RetrievalEval_test.cj`（2） | 仅本文件 + 测试，标 public 过宽 |
| `SupervisorRoute` / `SupervisorOutcome` | `src/loom/Supervisor.cj:26,41` | `SupervisorRoute\|SupervisorOutcome` | 仅 `Supervisor.cj`(23) + `Supervisor_test.cj`(14) | 仅本文件 + 测试 |
| `PlanDto` / `StepDto` / `OptionDto` / `QuestionDto` / `AssumptionDto` | `src/loom/Planner.cj:288-336` | `PlanDto\|StepDto\|OptionDto\|QuestionDto\|AssumptionDto` | 仅 `Planner.cj`(13) + `doc/f_llm.md`(1) | 仅本文件使用，应改 private/包内 |
| `MemoryRecorderTask.recordWithTimeout` | `src/loom/BackgroundTasks.cj:41-45` | `recordWithTimeout\|MemoryRecorderTask` | `BackgroundTasks.cj`(2=两个声明)、`BackgroundTasks_test.cj`(1)、`doc/loom.md`(1) | 无生产调用方（`LoomTimeout` 因此只有 `record` 一条真实用法） |
| `RetrievalEval` / `EvalDoc` / `EvalCase` / `EvalReport` | `src/loom/RetrievalEval.cj:25,43,109,245` | `EvalReport\|EvalCase\|EvalDoc` | 仅 `RetrievalEval.cj`(12)、`RetrievalEvalRunner.cj`(5)、`RetrievalEval_test.cj`(30)、`doc/retrieval-eval.md` | 生产零引用（仅评测脚本 `eval/run_eval.sh` 入口），应标注“评测专用” |

- **建议**：`Stores.DEFAULT_*`/`META_KEY` 删除；`*IndexRebuilder` 要么接进 `LoomWiring`/启动装配，要么移出 `src`（放到 `eval/` 或运维脚本）；其余降级为包内可见（仓颉默认包内可见 + `internal`）即可消除“public 但无消费者”。

#### [轻微] `Stores` 与 `StoreSettings` 重复定义配置键，且默认值互相矛盾

- **位置**：`src/store/Stores.cj:29-32` 与 `src/store/StoreSettings.cj:34-41`
- **描述**：同一个键 `'llm_memoryStore'` / `'llm_metaStore'` 各定义一次；默认值冲突：`Stores.DEFAULT_CONTENT='postgres'`、`Stores.DEFAULT_META='postgres'` vs `StoreSettings.DEFAULT_CONTENT='f_hydra'`、`DEFAULT_META='f_store'`。当前 `Stores.content()` 走 `StoreSettings.load()` 所以行为正确，但常量对外暴露后极易被误用。
- **建议**：删除 `Stores` 里的 4 个常量，全部改为引用 `StoreSettings.*`。

#### [轻微] 五个“跨 `synchronized` 传值盒子”类重复定义

- **位置**：`src/loom/LoomMemoryPolicy.cj:24`（`DocSeqBox`）、`src/loom/LoomAgent.cj:89`（`AgentSeqBox`）、`src/loom/LoomHostApi.cj:33,37`（`TextBox`、`GatewayBox`）、`src/loom/LoomRegistry.cj:86,90`（`BoolBox`、`CountBox`）
- **描述**：都是同一个模式（`synchronized` 块返回 Unit，用持有者带出结果），6 个近似类各写一遍，且都带 `public var`（类本身是包内可见）。
- **建议**：用一个泛型 `class Box<T> { public var value: T }`（或 `Cell<T>`）替换，`var` 保持包内可见。

#### [轻微] 手工拼 JSON 形成多套“同一实体两种 schema”

- **位置**：`src/loom/LoomStoreGateway.cj:79-111`（knowledge）、`:174-178`（memory.search 带 content/kind）、`:358-365`（`recordJson` 带 namespace/saveTime）、`:367-399`（skill/prompt/character/evolution）；`src/loom/BackgroundTasks.cj:33-36`、`src/loom/LoomMemoryPolicy.cj:127-129,158-162`、`src/loom/StoreFunctions.cj:119-121`
- **描述**：唯一转义工具是 `FlowPlan.jsonQuote`（`Plan.cj:158`），但字段名/字段子集由各处硬编码：同一 `MemoryRecord` 在 `list` 返回 `recordJson`（含 `userId/namespace/saveTime`），在 `search` 返回另一种（含 `content/kind/score`，无 `userId/saveTime`）；`knowledge` 的 `get` 与 `search` 字段名也不同（`docId/seq/content` vs `docId/title/content`）。消费方（模型/JIT 步骤）必须记住两套 schema。
- **建议**：把每个实体的 JSON 序列化收敛到 `LoomStoreGateway` 内的 `recordJson/searchHitJson` 一组函数，并让 `recordJson` 带可选 `score`；`BackgroundTasks`/`LoomMemoryPolicy`/`StoreFunctions` 改为调用统一构造器（如 `MemoryWrite.toJson()`）。

#### [轻微] `LoomStoreGateway` 类注释的 kind/op 表与实现不一致

- **位置**：`src/loom/LoomStoreGateway.cj:26-42`（表只列 knowledge/memory/skill/experience）
- **描述**：实现还支持 `skill.load`（:212）、`skill.upsert`（:222）、`prompt.*`（:242-274）、`character.*`（:276-293）、`evolution.*`（:295-309），文档表全部缺失；而 `README.md:408-444` 与 `doc/loom.md:525-569` 反而列了这些 kind，形成“代码注释比外部文档更不全”的反常。
- **建议**：以 README 的表为准回填类注释，或把表抽到 `doc/loom.md` 单一来源并删除类内表。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 0 |
| 一般 | 8 |
| 轻微 | 4 |

### 总评

本轮针对“死代码与功能重复”的结论是：**没有真正意义上的“零引用类型”遗留成灾**，但存在三类结构性问题。

1. **写入/读取入口发散**：记忆写入有 5 条现行入口 + 1 条旧链路（`Memory`/`FaithfulMemory`），`memory/Memory.cj:124` 绕过网关直连适配器并写死 `namespace='global'`，与 loom 默认 `'loom'` 不一致——这是本轮最需要处理的一条（不只是重复，还会造成“写了但检索不到”）。
2. **同一能力多份实现**：memory/knowledge 两条检索链路各自实现融合打分（权重常量 5 处）、`LoomStore` 的 4 个实现（其中 PG/MySQL 逐行同构）、三层“选实现”适配器、6 个传值盒子类。这类重复目前未导致错误，但已经出现常量口径分裂（`LEXICAL_WEIGHT` 0.1 三份、`0.7/0.3` 内联）。
3. **公开面偏宽**：`PlanDto`/`StepDto`/`OptionDto`/`QuestionDto`/`AssumptionDto`、`TopicStat`、`SupervisorRoute`/`SupervisorOutcome` 只在自身文件使用，`Stores.DEFAULT_CONTENT/DEFAULT_META/META_KEY` 全仓零引用（且与 `StoreSettings` 默认值冲突），`MemoryIndexRebuilder.rebuildIfConfigured` 生产零调用但 `doc/known-limitations.md:73-82` 写成“配置驱动、启动后调用一次”，而同一文档 `:121` 又说“重建需手工触发”——文档自相矛盾。

代码整体结构清晰、注释质量高，没有发现会导致崩溃的重复逻辑；上述问题均属“可维护性/一致性”范畴，建议按“收敛写入口 → 统一检索常量 → 收缩 public 面 → 修正文档”的顺序处理。

REVIEW_WRITTEN:D:\docs\work\cangjie\projects\fountain\.worktrees\f_llm\reviews\202611061157_f_llm_module_review\review_v1.md

（再次提示：本 Agent 无写文件工具，上述路径下的文件尚未创建，请主 Agent 将“报告正文”保存到该路径。）