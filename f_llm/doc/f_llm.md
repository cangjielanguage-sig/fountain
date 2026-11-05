# f_llm 设计文档

> 本文只描述**当前实现**。历史改造方案、迁移记录、已删除的 API 不在本文范围。
> 使用示例见 `README.md`；记忆与人格的提示词细节见 `doc/f_llm-memory-design.md`；
> 编排的使用与边界见 `doc/loom.md`；检索评测见 `doc/retrieval-eval.md`。

## 0. 定位与分层

`f_llm` 是进程内的库（`output-type = "dynamic"`），不提供自己的服务进程，也不做运行期配置变更。

| 层 | 包 | 职责 |
|---|---|---|
| 门面 | `fountain::f_llm.llm` | `LLM`：候选调度、协议、流式、裁剪、Token 计数 |
| 协议 | `llm.openai` / `llm.ProviderDialect` | OpenAI 兼容报文与各家方言差异 |
| 向量 | `fountain::f_llm.embedding` | `Embedding`：BGE-M3 三路编码 |
| 存储 | `fountain::f_llm.store` | 契约 + 5 种内容族 / 3 种元数据族实现 + 演进族 |
| 数据访问 | `fountain::f_llm.dao.{postgres,mysql}` | 仅放 SQL |
| 编排 | `fountain::f_llm.loom` | 流程生成、编译、执行、存储网关、技能演进 |
| 辅助 | `memory` / `search` / `tool` / `finder` / `balance` / `mcp` | 记忆摘要、联网、工具、查询门面、余额、MCP |

三条硬约束（贯穿全库）：

1. **配置只读**：环境变量在启动时读一次，切换存储或端点必须重启；
2. **不自建线程**：定时能力交给 `f_ticktock`，库内只用调用方线程；
3. **降级要留观测点**：任何「静默退回」都必须有可查询的计数或标记（如 `SkillCatalog.embedFailureDetail()`、`MemoryHit.degraded`）。

## 1. 模块结构

```
src/
├── llm.cj                  统一导入入口（public import fountain::f_bean.*）
├── config/                 环境变量键与默认值（LLMConfig）
├── constant/               常量：模型名、角色、裁剪器名、Todo 状态、知识种类、工具类型
├── model/                  数据模型
│   ├── po/                 持久化对象：LLMConf、Skill、Knowledge、Agent、MemorySummary、TokenUsage…
│   └── entity/             检索实体：KnowledgeEntity
├── llm/                    门面与协议
│   ├── LLM.cj  LLMConfs.cj  LLMConfsHolder.cj  LLMCandidateProvider.cj
│   ├── CircuitBreaker.cj  LLMErrorClassifier.cj  TokenCounter.cj
│   ├── ChatMessage.cj  LLMParams.cj  LLMResp.cj  LLMDelta.cj
│   ├── ContextPruner.cj  ContextPrunerMediator.cj
│   ├── ProviderDialect.cj  ProviderDialects.cj  DeepSeekDialect.cj
│   └── openai/             ChatCompletionsMapper / ResponsesMapper / 流式累加器
├── embedding/              Embedding 门面、HttpEmbedder、BgeM3Transport/Codec、DefaultEmbedder
├── store/                  契约与实现
│   ├── StoreContracts.cj  StoreModels.cj  Stores.cj  StoreSettings.cj
│   ├── FStoreMetaStore.cj  InMemoryStores.cj  MemoryRepositories.cj
│   ├── EvolutionStore.cj  EvolutionStateStore.cj  EvolutionLease.cj
│   ├── KnowledgeChunker.cj  KnowledgeSearch.cj  KnowledgeIndexRebuilder.cj
│   ├── hydra/              f_hydra 与 fhydra 的内容族实现
│   ├── postgres/ mysql/    内容族、元数据族、演进族实现
│   └── it/                 真库集成用例
├── dao/{postgres,mysql}/    SQL
├── loom/                   编排（见 §6、§7）
├── memory/                 FaithfulMemory、ExperienceExtractor、IndividualityExtractor
├── search/                 SearchProvider 与 DeepSeek 实现
├── tool/                   函数调用框架与内置工具
├── finder/                 查询门面
├── agents/                 AgentEvent、AgentEventData
├── balance/                余额查询与签名
├── service/                LLMConfService 与配置来源
├── wiring/                 StoreWiring
├── exception/ util/ mcp/ macros/
```

依赖方向：`loom` → `store` / `llm` / `embedding` / `tool`；`store` 不依赖 `loom`；`tool` 依赖 `llm`（工具循环需要模型响应），`llm` 不依赖 `tool`。

## 2. 大模型访问

### 2.1 `LLMConf`

单个平台的配置对象（`model/po/LLMConf.cj`）。除了固定字段（provider、url、auth、实际模型名、权重、能力位），还带一张**扩展 option 表**：

| 方法 | 用途 |
|---|---|
| `setConf(HashMap<String,String>)` | 批量写入扩展键值 |
| `option(key)` / `option(key, default)` | 读扩展值 |
| `optionInt` / `optionBool` | 带类型与默认值的读取 |

部署差异（超时、额外请求头、特殊开关）都走 option，不新增固定字段。

### 2.2 装载与快照

| 组件 | 行为 |
|---|---|
| `LLMConfSource` | 配置来源：`StaticConfSource` / `FileConfSource` / `EnvConfSource` / `DatabaseConfSource` / `StoreMetaConfSource` |
| `LLMConfService` | 装配来源、按 `llm_confRefreshSeconds` 懒式刷新 |
| `LLMConfsHolder` / `LLMConfsSnapshot` | 持有不可变快照，替换整体而非逐字段改 |
| `LLMCandidateProvider` | 按 `llmName` 或权重给出候选列表 |

刷新是**懒式**的：调用方取快照时检查 TTL，过期则重新装载并整体替换；没有后台线程。

### 2.3 候选调度与熔断

一次调用按候选列表顺序尝试：命中即返回；抛错则记录并换下一个（`llm_accessTryingCount` / `llm_accessTryingElapsed` 控制重试预算）。
连续失败达 `llm_failureThreshold` 后该候选进入 `llm_cooldownSeconds` 冷却（`CircuitBreaker`），冷却期内跳过。

### 2.4 协议层

| 形态 | 映射器 | 说明 |
|---|---|---|
| Chat Completions 非流式 | `ChatCompletionsMapper` | 请求体 `{model, messages, tools, temperature, max_tokens, response_format, thinking}` |
| Chat Completions 流式 | `ChatStreamAccumulator` | 逐块累加为 `LLMDelta`，空闲超时 `llm_streamIdleTimeout`、单行上限 `llm_streamMaxLineBytes` |
| Responses API | `ResponsesMapper` / `ResponsesStreamAccumulator` | `respond` / `respondStream` |

传输可替换：`LLM.setTransport` / `setStreamTransport`（测试注入桩，默认 `DefaultHttpTransport` / `DefaultStreamTransport`）。

### 2.5 方言

`ProviderDialect` 负责把统一请求翻译成各家格式；`DialectRegistry` 按 provider 选：

| 方言 | 覆盖 |
|---|---|
| `StandardDialect` | OpenAI 兼容端点（含聚合平台） |
| `DeepSeekDialect` | DeepSeek 的字段差异 |
| `ZhipuDialect` / `VolcengineDialect` / `AliyunDialect` / `SiliconFlowDialect` | 各家参数与报文差异 |

模型名归一（`ModelNames.normalize`）只用于能力判断与日志；报文里的 `model` 永远是配置原文。

### 2.6 模型能力

`ModelCapabilities` + `ThinkingPolicy` 决定是否下发思考开关；`ThinkingMode`（`constant/ThinkingSwitch.cj`）表达开启/关闭/自动。
能力表按模型名匹配，新增模型只改常量表。

### 2.7 上下文裁剪

`ContextPrunerMediator` 通过 `ContextPrunerName` 常量选策略：

| 名字 | 实现 | 行为 |
|---|---|---|
| `Retain` | `RetainContextPruner` | 全保留 |
| `LastN` | `LastNContextPruner` | 保留最近 N 条 |
| `RetainLastUser` | `RetainLastUserPruner` | 保留最后一条用户消息 |
| `RetainLastRound` | `RetainLastNRoundPruner` | 保留最近 N 轮 |
| `TokenBudget` | `TokenBudgetContextPruner` | 按 token 预算裁剪 |
| `Saturation` | `SaturationContextPruner` | 饱和度裁剪 |
| `DRC` | `DRCContextPruner` | 动态相关度裁剪 |
| `Summary` / `Keywords` | 依赖模型（`llm_prunerLlmName`） | 摘要 / 关键词压缩 |

约定：裁剪**不丢首条 system 消息**；裁剪是单次调用的动作，不改变持久化的会话内容。

### 2.8 错误与重试

`LLMErrorClassifier` 把上游错误分成可重试（超时、限流、5xx）与不可重试（鉴权、参数非法）。
可重试错误消耗重试预算，不可重试错误立即换候选；两者都记入熔断状态。

### 2.9 门面

| 方法 | 说明 |
|---|---|
| `chat(candidates, params, hooks?)` | 按候选列表调用 |
| `chatByName(llmName, params)` | 从快照取候选 |
| `respond` / `respondByName` | Responses 形态 |
| `chatStream` / `respondStream` | 流式，逐段回调 |
| `getTransport` / `getStreamTransport` | 读当前传输（排障用） |

`LLMHooks` 提供调用前后的切面（日志、审计、埋点），`CallLogger` / `CallLog` 是内置实现。

## 3. 工具调用

### 3.1 定义与注册

| 组件 | 作用 |
|---|---|
| `FunctionDefinition` | 函数签名：名、描述、参数 schema |
| `FunctionCalling<T>` / `CommonFunctionCalling` | 单函数封装（`T` 是参数类型） |
| `WrappedFunctionCalling<T>` | 包装已有函数 |
| `FunctionMeta` / `FunctionMediator` | 注册表与调用入口 `call(name, args)` |
| `ToolName` | 工具名常量，避免散落字符串 |

注册是**进程内静态表**：同名重复注册抛 `FunctionCallingException`，不覆盖。

### 3.2 内置工具

| 工具 | 要点 |
|---|---|
| `FileReadingFunction` / `FileWritingFunction` / `FileReplacngFunction` | 受 `llm_fileSandboxPath` 限制，越界直接拒绝 |
| `CommandFunction` | 执行命令行，输出截断到 `llm_toolResultMaxBytes` |
| `ConsoleFunction` | 控制台读写 |
| `WebSearchFunction` / `WebFetchFunction` | 抓取大小受 `llm_fetchMaxBytes` 限制，`SsrfGuard` 拦内网地址 |
| `SkillLoadingFunction` / `SkillReferenceLoadingFunction` | 按标题加载技能与技能引用 |
| `MemoriesLoadingFunction` | 加载经验、教训、用户个性 |
| `TodoFunction` | todo 增删改查（`TodoStatus`） |
| `CurrentTimeFunction` | 当前时间 |
| `AnswerFunction` | 结构化回答 |

### 3.3 工具循环

`LLMToolLoop.run(...)`：模型返回 `tool_calls` → `FunctionMediator.call` 执行 → 结果作为 `ToolMessage` 回填 → 再请求，最多 `DEFAULT_MAX_ROUNDS = 8` 轮。
工具抛错不会中断循环，而是作为「工具调用失败」文本回填，让模型自行决定下一步。

### 3.4 MCP

`mcp` 包适配 `f_mcp` 客户端：把 MCP 工具定义转成 `FunctionDefinition`，调用结果转成文本。
流程计划里用 `tools` / `mcps` 声明可用集合，`ToolScope.check(kind, requested, available)` 做白名单校验：
**只能收窄，不能凭空引入**——声明了未注册的名字直接抛 `LoomException`。

### 3.5 安全

| 组件 | 作用 |
|---|---|
| `SsrfGuard` | 拒绝内网/回环地址的抓取请求 |
| `Redactor` | 日志与错误信息中的敏感字段脱敏 |
| `llm_fileSandboxPath` | 文件工具的沙箱根 |
| `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` | 结果与抓取上限，防止把上下文撑爆 |

## 4. 存储

### 4.1 三族与选型

| 族 | 存什么 | 实现 | 配置键 |
|---|---|---|---|
| 内容族 | 记忆、经验、知识、文档 | `f_hydra`（默认）/ `fhydra` / `postgres` / `mysql` / `inMemory` | `llm_memoryStore` |
| 元数据族 | 人格、技能、提示词、模型配置 | `postgres` / `mysql` / `f_store`（默认） | `llm_metaStore` |
| 演进族 | 演进报告、状态、已消费知识、每日租约 | 报告/状态跟随元数据族，租约跟随内容族 | 派生 |

`StoreSettings.load()` 在启动时读一次；未知值**直接失败**并打印可选列表，不静默回退。
旧键 `llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` / `llm_contentStore` 只识别不生效，逐条 `warn`。

### 4.2 契约

| 契约 | 成员 |
|---|---|
| `ContentStore` | `prop memory: MemoryStore`、`prop knowledge: KnowledgeStore` |
| `MetaStore` | `prop characters`、`prop skills`、`prop prompts`、`prop confs` |
| `MemoryStore` | `add / get / remove / list / search / listByKind` |
| `KnowledgeStore` | `upsert / get / remove / search / docIds` |
| `CharacterStore` | `get / set / reset` |
| `SkillStore` | `upsert / get / list / remove` |
| `PromptStore` | `put / get(name, version) / latest / remove` |
| `LLMConfStore` | `names / candidates / put` |

`listByKind` 的接口默认实现是「取一页再过滤」（近似）；内存实现与适配器覆盖成**先过滤再分页**，SQL 实现依赖仓储层的 kind 条件。

### 4.3 数据模型

| 类型 | 关键字段 |
|---|---|
| `MemoryRecord` | `id / userId / namespace / title / content / kind / saveTime(DateTime)` |
| `MemoryWrite` | 写入用的入参（用户、命名空间、标题、正文、kind） |
| `MemoryHit` | `record / score / degraded`（`degraded=true` 表示某一路向量缺失，分数只由剩余通路融合） |
| `KnowledgeDoc` | `docId / title / content` |
| `KnowledgeChunk` / `KnowledgeHit` | 块与命中（块级检索） |
| `Character` | `userId / characterKey / prompts` |
| `Skill` | `id / title / details / functions / version` |
| `PromptEntry` | `name / version / content` |
| `EvolutionEntry` | `id / skillTitle / action / detail / at` |

### 4.4 f_store 键布局

```
f_llm:meta:character:{userId}                          → 人格（第一行 characterKey，第二行 prompts）
f_llm:meta:skill:{id}                                  → 技能
f_llm:meta:prompt:{name}:{version}                     → 提示词
f_llm:meta:conf:{id}                                   → 模型配置主体（provider/llmName/actual/weight/enabled）
f_llm:meta:conf:byname:{llmName}:{id}                  → 按名索引
f_llm:evolution:data:{id}                              → 演进报告
f_llm:evolution:idx:{标题长度}:{标题}:{补零at}:{补零id}    → 报告索引（bySkill）
f_llm:evolution:time:{补零at}:{补零id}                  → 报告索引（list）
f_llm:evo-state:run                                   → 演进水位线
f_llm:evo-state:skill:{title}                         → 每技能冷却与门禁结果
f_llm:evo-state:kn:{docId}                            → 已消费的知识
```

索引键的值都是「数据键」，查询时先扫前缀拿数据键，再按数据键读正文——`f_store` 没有二级索引，这是自建索引的通用做法。

### 4.5 SQL 表

**基础表**在模块根目录的 `tables-pg.sql` / `tables-mysql.sql`，由部署脚本或 DBA 执行：

| 表 | 用途 |
|---|---|
| `llm_conf` | 模型配置 |
| `llm_memory` / `llm_memory_kind` / `llm_memory_vector` | 记忆、种类、向量 |
| `llm_character` | 人格 |
| `llm_prompt` | 提示词 |
| `llm_document` / `llm_document_chunk` | 知识与切块 |
| `llm_token_usage` | Token 用量落库 |
| `llm_loom_flow` | loom 流程（源码与状态） |

**演进族表**由代码在启动时幂等创建（`ensureSchema`），因为它们属于 f_llm 的可选能力，要求部署方也去改 DDL 不合适：

| 表 | 用途 |
|---|---|
| `llm_skill_evolution` | 演进报告 |
| `llm_skill_evolution_state` | 水位线（保留行 `__run__`）与每技能冷却 |
| `llm_skill_evolution_knowledge` | 已消费的知识 docId |
| `llm_evolution_lease` | 每日租约（单行表） |

### 4.6 启动接线

`StoreWiring.wire()` 幂等，做四件事：

1. `BeanFactory.instance.afterRegistered()`：让 `@Bean` 条件按配置生效；
2. `ensure(...)` 注册内容族 5 个实现、`ensureMeta(...)` 注册元数据族 3 个实现；
3. `Stores.bootstrap()`：校验配置值、初始化默认实现；
4. `seedKinds()`：`postgres` / `mysql` 部署下把 7 个预定义记忆种类补种到 `llm_memory_kind`，并 `MemoryKinds.attach()` 载入自定义种类（失败只告警）。

### 4.7 向量化

| 组件 | 说明 |
|---|---|
| `Embedding` | 门面：`embed(llmName, EmbeddingParam)`，复用候选与熔断 |
| `HttpEmbedder` | OpenAI 兼容 `/v1/embeddings` 客户端，`EmbeddingTransport` 可替换 |
| `BgeM3Transport` / `BgeM3Codec` | BGE-M3 三路（dense / sparse / colbert）的报文编解码 |
| `DefaultEmbedder` | 生产 `Embedder`，读 `llm_embeddingUrl` / 超时 / 重试 |
| `VectorMath` | 余弦、归一、融合 |

向量检索是**多路融合**：dense 与 sparse 各出一份分数再融合；某一路缺失时 `MemoryHit.degraded=true`，调用方可据此判断结果可信度。

### 4.8 知识切块与检索

- `KnowledgeChunker.split(content, maxChars: 400, overlap: 50)`：按字符滑窗，`overlap` 必须落在 `[0, maxChars)`；
- `KnowledgeSearch`：块级向量召回，返回 `KnowledgeHit`（带块与所属文档）；
- 写入路径：`knowledge.upsert` → 切块 → 逐块编码 → 落 `llm_document_chunk`。

### 4.9 索引重建

`MemoryIndexRebuilder` / `KnowledgeIndexRebuilder` 在 `llm_rebuildIndexOnStart` 开启时按
`llm_rebuildIndexUserId` / `llm_rebuildIndexNamespace` 重建向量索引；重建是全量扫描，建议低峰期执行。

## 5. 记忆与经验

### 5.1 种类

7 个预定义 kind：`note` / `fact` / `preference` / `task` / `doc` / `knowledge` / `session`（`MemoryKinds.predefined()`）。
自定义 kind 按用户注册（`register(userId, kind)`），落 `llm_memory_kind`（`predefined=false`），启动时 `attach` 载回；预定义 kind 不可删除。

### 5.2 写入路径

| 路径 | 触发 | 产出 |
|---|---|---|
| 流程结束提炼 | `LoomRunner` 的 `finally` | `note` + `experience`（失败为 `experience_failed`），可选知识文档 |
| 流程内显式写 | `loomStore("memory","add")` / `memoryCall` | 调用方指定的 kind 与内容 |
| 内容族 API | `MemoryStore.add(MemoryWrite)` | 直接落库，不经过提炼 |

### 5.3 检索

`MemoryStore.search(MemoryQuery)` 返回 `MemoryHit` 列表，按融合分数降序；`MemoryQuery` 带用户、命名空间、文本、`topK`。
`f_hydra` 部署下 `kind` 过滤**下推到服务端**：记录写入时把 `kind` 写进 `filters`，查询用 `idsFiltered` 走倒排。

## 6. loom 编排

### 6.1 状态机

```
clarifying ──(回答澄清)──> pending ──(confirm)──> compiled
                              ^                        │
                              └────(重编译失败)── failed
```

| 状态 | 含义 | 可执行 |
|---|---|---|
| `clarifying` | Planner 认为描述有歧义，存问题清单 | 否 |
| `pending` | 已生成源码，尚未编译 | 否 |
| `compiled` | 步骤闭包已编译 | 是 |
| `failed` | 编译失败（单条失败不影响其它流程） | 否 |

### 6.2 计划模型

| 类型 | 字段 |
|---|---|
| `FlowPlan` | `name / persona / steps / edges / notes / parallel / round` |
| `StepPlan` | `id / kind / tool / model / system / input / args / async / external` |
| `EdgePlan` | `from / to` |

`kind` 三种：`tool` / `llm` / `jit`。`async` 取 `auto` / `true` / `false`，与 `parallel` 一起决定并发；
`external=true` 表示该步骤由外部（MCP 或宿主）执行。
`plan.validate()` 检查重复 id、悬空边、缺 kind。

### 6.3 Planner 与澄清

`Planner.plan(LoomRequest)` 调模型返回 JSON，交由 `PlanDto` / `StepDto` 解析；解析失败或字段缺失即视为需要澄清，返回 `ClarifyQuestion` 列表。
`LoomRequest` 携带 `tools` / `mcps` / `persona` / `answers` / `onUnresolved` / `dryRun` / `model` / `parallel`；
澄清轮次用尽时按 `onUnresolved`（`ask` / `default` / `abort`）收尾。

### 6.4 CodeGen

`CodeGen.generate(plan)` 产出 `GeneratedFlow`：`planJson`、`stepSources`（每步源码）、`flowSource`（流程源码）。
**产物只生成不编译**，因此预览、落库、人工修改都不触发编译开销。

### 6.5 编译与 JIT

`LoomCompiler.compileSteps(plan)` 把每步源码编译成 `(Event) -> Event` 闭包：

| 步骤类型 | 编译方式 |
|---|---|
| `tool` | 生成调用 `LoomHost.callTool` 的闭包 |
| `llm` | 生成调用 `LoomHost.callLlm` 的闭包，输入先做模板替换 |
| `jit` | 走 `f_jit` 编译任意片段，片段内可用 `loomCallTool` / `loomCallLlm` / `loomStore` |

JIT 片段的约定：末行产出 `let <stepId>_result = …`，该值即步骤输出，供下游 `{stepId.output}` 引用。

### 6.6 执行器

`LoomRunner.runCompiled(...)`：

1. 拓扑序取执行顺序（无入边的步骤先跑）；
2. 每个步骤一个 `JoinBarrier` 计数，等所有前驱完成才执行；
3. 输出按步骤 id 存进共享表，模板替换时取；
4. `parallel=true` 时分叉用异步任务并发，否则顺序 emit；
5. 超时由 `LoomTimeout` 控制，超时步骤记为失败并向下传递；
6. 结果以事件形式返回（最后一个事件是流程输出）。

`LoomContextLog` 记录每次 `callLlm` 的 `LlmTurn`（model / system / input / output），流程结束据此提炼。

### 6.7 存储网关

`LoomStoreGateway.call(kind, op, payloadJson)` 是流程内唯一的数据入口（JIT 的 `loomStore` 与内置工具 `memoryCall` / `knowledgeIngest` 都走它）：

| kind | op |
|---|---|
| `memory` | `add` / `get` / `list` / `search` / `remove` |
| `experience` | 同 `memory`（入口别名，强制 `kind=experience`） |
| `knowledge` | `get` / `docIds` / `search` / `upsert` / `remove` |
| `skill` | `load` / `get` / `list` / `upsert` / `count` / `remove` |
| `prompt` | `latest` / `get` / `put` / `remove` |
| `character` | `get` / `set` / `reset` |
| `evolution` | `list` / `by_skill`（只读） |

约定：

- payload 是 JSON **字符串**，缺少必填字段抛 `LoomException`；
- `memory.search` 返回 `{id,title,content,kind,score}`，与 `knowledge.search` 保持一致，流程里可直接喂模型；
- `evolution` 只读——报告是审计记录，写入方只有后台演进任务。

### 6.8 人格解析

```
plan.persona 非空？
 ├─ 是 → 三级解析：prompt.latest(name) → PredefinedCharacters.bodyOf(name) → 字面文本
 └─ 否 → character.get(userId) 的 characterKey → 同一三级链
              ↓
      追加 character.prompts（非空时），再拼步骤自己的 system
```

`custom` 是特例：正文只来自 `character.prompts`，不会把 `custom` 当人格。角色记录按 `LoomMemoryPolicy.userId` 取，`userId<=0` 跳过。

### 6.9 技能检索与注入

| 模式 | 触发 | 数据来源 |
|---|---|---|
| 显式 | `run(..., skills: [...])` | `SkillStore.list()` 按标题匹配 |
| 自动 | `autoSkills=true` 且未显式传 | `SkillCatalog.search(query, topK, minScore)` |

`SkillCatalog` 装编码器走向量余弦（向量按 `标题#版本` 缓存），未装或编码失败走关键词（词面包含 / 字符命中比例 / 标题覆盖比例）。
编码失败计数通过 `embedFailureDetail()` 暴露——这是「装了编码器却在跑关键词」这类配置错误的唯一观测点。

### 6.10 提炼

`LoomMemoryExtractor.extract(name, turns, host, policy, outcome)`：

| 条件 | 结果 |
|---|---|
| `policy.enabled=false` | 不记录、不提炼 |
| `turns` 为空（一次模型都没调） | 不写任何记录 |
| 正常 | 写 `note`（上下文摘要）+ `experience` / `experience_failed` |
| `writeKnowledge=true` | 额外写 `loom:<流程>:<序号>` 知识文档 |
| `summarize=true` + `model` | 由模型返回 `{memory, experience}`；JSON 非法回落规则提炼 |

顺序上先 `snapshot()` → `clear()` → 解绑，再提炼：否则提炼自身那次模型调用会被记进下一次上下文。

### 6.11 定时任务

`LoomScheduler` 是接口，`TicktockScheduler` 基于 `f_ticktock` 实现；`LoomSchedules` 保存全局实例，未安装时注册与触发都跳过。
`scheduleCreate` 注册的是「流程 + cron + payload」，触发时 payload 进入 `StartEvent.data`；`JitTicktockTask` 承接 JIT 步骤在定时线程中的执行。

### 6.12 装配

`LoomWiring.wire(chat, plannerModel, store, memoryPolicy, skillEmbedder, evolutionCron, evolutionUserId, evolutionNamespace, evolutionModel, evolutionNameCandidates, evolutionPolicy)`：

1. 安装存储网关与宿主；
2. 安装记忆策略（默认 `enabled=true`、`namespace='loom'`）；
3. 安装技能目录（含可选编码器）；
4. `EvolutionStores` / `EvolutionStateStores` / `EvolutionLeases` 各自 `bootstrap()`（SQL 部署建表，失败不阻断）；
5. 配了 `evolutionCron` 且装了调度器时注册 `loom-skill-evolution`，否则静默跳过。

## 7. 技能演进

### 7.1 流水线

```
触发 → 抢每日租约
  → load 素材（经验 + 知识，按水位线筛新增）
  → SkillMatcher.assign：归到已有技能 / 聚成新技能候选
  → 先演进：policy.decide → 改写正文 → SkillGate A/B → 版本 +1
  → 再新建：簇够大 → SkillNamer 起名（必须带样例）→ version=1
  → 落报告 + 推进水位线 + 标记已消费知识
```

「先演进再新建」是刻意的：同一主题的素材若既能并入旧技能又够格建新技能，先演进能让它被吸收，避免两份近似内容。

### 7.2 匹配与聚类

`SkillMatcher.assign(experiences, skills, embedder, threshold)`：向量（或关键词）最近邻归属；未达阈值的素材彼此聚类，簇大小达到门槛即成为新技能候选。
`ExperienceItem` 带 `source`（知识用 docId，经验为空），供去重使用。

### 7.3 策略

`SkillEvolutionPolicy.decide(state, stats)`：

| 条件 | 默认值 |
|---|---|
| 最小样本数 | 3 |
| 最小成功率 | 0.8 |
| 冷却期 | 86400 秒（1 天） |
| 门禁失败后的冷却期 | 172800 秒（2 天） |

冷却状态由调用方传入（`EvolutionSkillState`），Job 只负责判定与落库。

### 7.4 门禁

`SkillGate.evaluate(oldDetails, newDetails, samples, chat, minScore)`：用技能自带的 `samples` 分别跑旧版与新版，
新版分数 ≥ 旧版且达到 `minScore` 才放行。**没有样例直接拒绝**——无法验证的改动不落库。

### 7.5 命名与建档

`SkillNamer.propose(details, samples, chat)`：标题 ≤ 24 字、必须至少一条样例、名字不能与已有技能冲突；
任一条件不满足就返回空，本轮不建。没有样例的新技能无法参与后续 A/B，等于死技能。

### 7.6 报告与状态

`SkillEvolutionLedger` 把每轮的 evolved / rejected / skipped / created 与候选数落成一条 `EvolutionEntry`；
`EvolutionStateStore` 保存水位线（`lastRunAt` / `markRun`）与每技能的 `lastEvolvedAt` / `lastGatePassed`。

### 7.7 每日租约

| 内容族 | 租约存放 | 互斥机制 |
|---|---|---|
| `postgres` / `mysql` | 表 `llm_evolution_lease`（单行） | `UPDATE … WHERE lease_value = 旧值`，影响行数为 1 才算抢到 |
| `f_hydra` | 本地全 0 向量记录的 payload | 本地存储，单进程无需跨进程 |
| `fhydra` | 远程全 0 向量记录 | 写后读校验 |
| `memory` / 其它 | f_store / 内存 | 单进程 |

租约值是 `f_util.UUID` 的时间型 UUID（`UUID.unixTimeBased()`），日期从 UUID 时间戳解析。
全 0 向量保证租约不会被任何语义检索命中（余弦恒为 0）。

### 7.8 知识去重

`EvolutionStateStore.processedAmong(docIds)` 回答「这批候选里哪些已消费」，实现按后端：

| 后端 | 实现 | 复杂度 |
|---|---|---|
| `postgres` / `mysql` | `WHERE doc_id IN (...)` | O(候选数)，走主键 |
| `f_store` | `kn:{docId}` 点查 | O(候选数) |
| `memory` | 查集合 | O(候选数) |

不要用 `processedKnowledge()`（全量）做去重：它受实现内部上限约束，记录累积后会截断，把老记录误判成「没消费过」。

## 8. 检索评测

| 组件 | 作用 |
|---|---|
| `RetrievalEval` | 读 TSV、算指标（recall@1 / recall@k / MRR / nDCG@k / 负样本通过率）、分层统计 |
| `RetrievalEvalRunner` | 灌语料 → 装编码器 → 分组评测 → 返回报告与编码失败数 |

nDCG@k 用二值相关：`DCG = Σ gain_i / log2(i+1)`，`IDCG` 是期望文档全排最前时的值，因此单相关样本等价于 `1/log2(rank+1)`。

`EvalOutcome.embedFailures` 必须为 0，否则本次测的是关键词而非向量；该断言写在 `RetrievalEvalManual_test` 里。

数据规模与基线见 `doc/retrieval-eval.md`。

## 9. 配置

全部环境变量，启动时读一次。按用途分四组：

| 组 | 键 |
|---|---|
| 存储 | `llm_memoryStore` / `llm_metaStore` / `llm_metaStorePath` / `llm_contentStoreUrl` / `llm_hydraPath` / `llm_hydraUrl` / `llm_hydraSecret` |
| 向量 | `llm_embeddingUrl` / `llm_embeddingTimeoutMs` / `llm_embeddingRetries` / `llm_rebuildIndexOnStart` / `llm_rebuildIndexUserId` / `llm_rebuildIndexNamespace` |
| 模型 | `llm_confSource` / `llm_confs` / `llm_confRefreshSeconds` / `llm_loadBalanceAlgo` / `llm_failureThreshold` / `llm_cooldownSeconds` / `llm_accessTryingCount` / `llm_accessTryingElapsed` / `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` / `llm_prunerLlmName` / `llm_summarisingLlmName` |
| 运行 | `llm_fileSandboxPath` / `llm_makingMemory` / `llm_summarisingModel` / `llm_summarisingActionKind` / `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` / `llm_balanceLowThreshold` / `llm_db` / `hydra_filterFields` |

## 10. 失败与降级

| 故障 | 行为 | 观测点 |
|---|---|---|
| 单个平台失败 | 换下一个候选 | 熔断计数、`CallLog` |
| 全部候选失败 | 抛 `LLMException` | 异常信息含最后一次错误 |
| 编码器失败 | `SkillCatalog` 退回关键词 | `embedFailureDetail()` |
| 某一路向量缺失 | 用剩余通路融合 | `MemoryHit.degraded` |
| 元数据写失败 | 业务继续（如 kind 落库） | `warn` 日志 |
| 演进任务抛错 | 吞掉，不中断调度 | 调度器日志 |
| 租约被他人抢占 | 本轮直接放弃 | 无报告落库 |
| 流程编译失败 | 该流程标 `failed` | `LoomService.status` |

原则：**能用就降级、降级要留痕**。所有降级都有对应计数或标记，不依赖日志排查。

## 11. 测试策略

| 层 | 方式 | 覆盖 |
|---|---|---|
| 单元 | `cjpm test`，无外部依赖 | 契约、解析、状态机、指标计算、策略判定 |
| 集成 | `FLLM_DB_TEST=1` 时连真实 PG / MySQL | 建表幂等、读写、索引、租约、去重 |
| 端到端 | 假宿主 + 内存存储 | 流程内读写六类存储并进入模型 system/input |
| 评测 | `eval/run_eval.sh`（手动） | 真实 embedding 的检索质量 |

集成用例用「随机后缀 + 只断言包含」的方式兼容累积数据；本地目录用 UUID 或时间戳生成，避免并行与重跑冲突。

## 12. 已知限制

| 项 | 说明 | 影响 |
|---|---|---|
| 配置只读 | 启动读一次 | 切换存储/端点必须重启 |
| 无分布式锁（除租约） | 编排与提炼走各进程本地 | 多副本下流程执行不互斥；演进靠每日租约互斥 |
| 索引重建全量 | `rebuildFilterEntries` / `rebuildIndex` 都是 O(记录数) | 大库上改配置需低峰期 |
| `listByKind` 的 SQL 实现 | 依赖仓储层 kind 条件，未下推时按近似实现 | 大结果集需放大 `limit` |
| nDCG 是二值相关 | 无分级相关性 | 无法区分「很相关」与「沾边」 |
| 评测集为模板 + 手写 | 非真实用户分布 | 只看量级与回归，不追求绝对值 |
