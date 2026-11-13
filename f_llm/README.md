# f_llm

仓颉（Cangjie）大模型工程库，属于 [fountain](../) 仓库。提供六块能力：

| 能力 | 入口 |
|---|---|
| 大模型访问（多平台、多候选、熔断、流式） | `fountain::f_llm.llm.LLM` |
| 存储（内容族 / 元数据族 / 演进族） | `fountain::f_llm.store.Stores` |
| 记忆、知识、技能、人格、提示词 | `MemoryStore` / `KnowledgeStore` / `MetaStore` |
| loom 编排（文本 → 流程 → 执行） | `fountain::f_llm.loom.LoomWiring` |
| 流程路由（一段描述 → 选中并执行流程） | `fountain::f_llm.loom.Supervisor` |
| 第三方平台通道（邮件收发，可扩展 IM） | `fountain::f_llm.channel.ChannelMediator` |
| 技能演进（经验 → 技能，带 A/B 门禁） | `fountain::f_llm.loom.SkillEvolutionJob` |
| 检索质量评测 | `fountain::f_llm.loom.RetrievalEvalRunner` |

- 版本：`1.3.1019`，`output-type = "dynamic"`
- 依赖：`f_base` / `f_bean` / `f_config` / `f_data` / `f_egraph` / `f_jit` / `f_orm` / `f_store` / `f_hydra` / `f_mcp` / `f_ticktock` / `f_util` 等，全部是同仓模块

---

## 目录结构

```
src/
├── llm/            模型访问：LLM 门面、LLMConf 装载、方言、裁剪器、流式、Token 计数
├── llm/openai/     OpenAI 兼容的请求/响应映射
├── embedding/      BGE-M3 向量化：Embedding 门面、HTTP 传输、三路编码
├── store/          存储契约与实现（f_store / f_hydra / fhydra / postgres / mysql / inMemory）
├── dao/            SQL 语句（postgres / mysql）
├── loom/           流程编排、Supervisor 路由、存储网关、技能演进、检索评测
├── memory/         记忆摘要与提炼（FaithfulMemory / ExperienceExtractor / IndividualityExtractor）
├── search/         联网搜索（DeepSeek 等 Provider）
├── tool/           工具：函数调用框架与内置工具（读文件、写文件、命令行、联网、todo…）
├── finder/         各类查询门面（技能、知识、记忆、组织、事件、Token 用量）
├── model/          数据模型（LLMConf、Skill、Knowledge、Agent、MemorySummary、TokenUsage…）
├── agents/         智能体事件与事件数据
├── balance/        平台余额查询与签名
├── service/        LLM 配置来源（静态 / 文件 / 环境变量 / 数据库 / 元数据存储）
├── config/         环境变量键与默认值
├── constant/       常量（模型名、角色、裁剪器名、Todo 状态、知识种类…）
├── wiring/         启动接线（StoreWiring）
├── exception/      异常类型
├── util/           Redactor（敏感信息脱敏）
├── mcp/            MCP 客户端
└── macros/         注解宏入口
```

---

## 快速开始

### 1. 配置（环境变量，启动时读一次）

```bash
export llm_memoryStore=f_hydra                      # 内容族（默认）
export llm_metaStore=f_store                        # 元数据族（默认）
export llm_metaStorePath=./data/f_llm-meta          # f_store 落盘目录
export llm_embeddingUrl=http://127.0.0.1:8000/v1/embeddings
```

**配置只在启动时读取一次**，不支持运行期修改（见 `doc/known-limitations.md`）。

### 2. 存储接线

```cangjie
import fountain::f_llm.wiring.StoreWiring

main(): Int64 {
    // 注册各实现、校验配置、建表、补种预定义记忆种类
    StoreWiring.wire()
    0
}
```

### 3. 调模型

```cangjie
import std.collection.ArrayList

import fountain::f_llm.llm.*

main(): Int64 {
    let messages = ArrayList<ChatMessage>()
    messages.add(UserMessage(content: '用一句话解释什么是熔断'))
    let resp = LLM.chatByName('deepseek-flash',
                              LLMParams(model: 'deepseek-flash', messages: messages))
    println(resp.messages[0].content)
    0
}
```

`LLM` 的入口：

| 方法 | 说明 |
|---|---|
| `chat(candidates, params, hooks?)` | 按候选列表调用，失败转移 + 熔断 |
| `chatByName(llmName, params)` | 按名字从配置快照取候选 |
| `respond` / `respondByName` | Responses 风格接口 |
| `chatStream` / `respondStream` | 流式，逐段回调 |
| `setTransport` / `setStreamTransport` | 替换底层传输（测试注入） |

### 4. 编排

```cangjie
import fountain::f_llm.loom.*

let service = LoomWiring.wire(plannerModel: 'deepseek-flash')
let preview = service.execute(LoomRequest(
    name: 'daily-report',
    description: '每天汇总昨日提交与 issue，写成日报发给团队'))
```

详见下文「loom 编排」。

---

## API 速查

按「要做什么」找入口，细节点进对应章节。

| 要做什么 | 入口 | 章节 |
|---|---|---|
| 调一次模型 | `LLM.chatByName(llmName, LLMParams(model:, messages:))` | 大模型访问 |
| 流式输出 | `LLM.chatStream(candidates, params, onDelta)` | 大模型访问 |
| 按候选容错 / 换平台 | `LLM.chat(candidates, params)` + `LLMConfs` | 大模型访问 |
| 文本向量化 | `Embedding.embed(llmName, EmbeddingParam(agentId: 0, session: '', input: '…'))` | 存储 · 向量化 |
| 写/查记忆 | `Stores.content().memory` → `add` / `get` / `list` / `search` | 存储 · 契约 |
| 写/查知识 | `Stores.content().knowledge` → `upsert` / `get` / `search` / `docIds` | 存储 · 契约 |
| 技能 / 提示词 / 人格 | `Stores.meta().skills` / `.prompts` / `.characters` | 存储 · 契约 |
| 加一个工具 | `@Bean` + `FunctionCalling<T>`，`FunctionMediator` 自动装载 | 大模型访问 · 工具调用 |
| 一句话生成流程并执行 | `LoomWiring.wire(...)` → `service.execute` → `confirmFlow` → `executeNow` | loom 编排 |
| 直接跑手写 DAG | `LoomRunner().run(plan, host, start)` | loom 编排 · 手工定义流程 |
| 一段描述交给最合适的流程 | `Supervisor.current().getOrThrow().dispatch(text)` | loom 编排 · 流程路由 |
| 给邮件 / IM 发消息 | `ChannelMediator.send(platform, account, msg)` 或 `channelSend` 工具 | loom 编排 · 第三方平台通道 |
| 评测检索质量 | `RetrievalEvalRunner.run(...)` | 检索评测 |
| 排障：技能检索是否在跑向量 | `SkillCatalog.embedFailureDetail()` | loom 编排 · 技能注入 |
| 排障：启动是否恢复了流程 | `LoomBootstrap.startup(registry).restoreFailed` | loom 编排 · 流程路由 |

三段最短可用代码（完整示例见各自章节）：

```cangjie
// 1) 调模型
let resp = LLM.chatByName('deepseek-flash',
    LLMParams(model: 'deepseek-flash', messages: messages))

// 2) 向量化（端点默认 http://127.0.0.1:8000/v1/embeddings）
let vectors = Embedding.embed('bge-m3', EmbeddingParam(agentId: 0, session: '', input: '要向量化的文本'))

// 3) 一段描述交给流程：选路 + 执行一步到位
let outcome = Supervisor.current().getOrThrow().dispatch('把今天的提交汇总一下')
```

---

## 大模型访问

### 配置装载

| 组件 | 作用 |
|---|---|
| `LLMConf` | 单个平台配置：provider、url、auth、实际模型名、能力位 |
| `LLMConfs` | 候选集合，按权重挑起点、失败转移、记熔断 |
| `LLMConfService` | 配置服务：刷新、下发、持久化 |
| `LLMConfSource` | 来源：`StaticConfSource` / `FileConfSource` / `EnvConfSource` / `DatabaseConfSource` / `StoreMetaConfSource` |
| `LLMCandidateProvider` | 候选提供者（按模型名或权重） |
| `CircuitBreaker` | 失败计数 + 冷却窗口 |

配置来源由 `llm_confSource` 选择；`llm_confs` 可直接内联一组配置（静态部署）。

### 方言（Provider Dialect）

`ProviderDialect` 负责把统一的请求体翻译成各家格式：

| 方言 | 适用 |
|---|---|
| `StandardDialect` | OpenAI 兼容（含大多数聚合平台） |
| `DeepSeekDialect` | DeepSeek 原生字段差异 |
| `ZhipuDialect` / `VolcengineDialect` / `AliyunDialect` / `SiliconFlowDialect` | 各家参数与报文差异 |

`DialectRegistry` 按 provider 选方言；模型名归一由 `ModelNames.normalize` 负责（只用于能力判断与日志，报文里的 `model` 永远是配置的原文）。

### 上下文裁剪

`ContextPrunerMediator` 按名字选裁剪器，`llm_prunerLlmName` 指定依赖模型的裁剪器所用模型：

| 名字 | 实现 | 行为 |
|---|---|---|
| `Retain` | `RetainContextPruner` | 全部保留 |
| `LastN` | `LastNContextPruner` | 保留最近 N 条 |
| `RetainLastUser` | `RetainLastUserPruner` | 保留最后一条用户消息 |
| `RetainLastRound` | `RetainLastNRoundPruner` | 保留最近 N 轮 |
| `TokenBudget` | `TokenBudgetContextPruner` | 按 token 预算裁剪 |
| `Saturation` | `SaturationContextPruner` | 饱和度裁剪 |
| `DRC` | `DRCContextPruner` | 动态相关度裁剪 |
| `Summary` / `Keywords` | 依赖模型 | 摘要 / 关键词压缩 |

裁剪策略通过 `ContextPrunerMediator.prune(...)` 调用；各策略都以「保留首条 system 消息」为约定（人格与技能的注入位置见 `doc/f_llm-memory-design.md` §6.5）。

### 工具调用

| 组件 | 作用 |
|---|---|
| `FunctionDefinition` | 函数签名（名、描述、参数 schema） |
| `FunctionCalling<T>` / `CommonFunctionCalling` | 单函数封装 |
| `WrappedFunctionCalling<T>` | 包装已有函数 |
| `FunctionMediator` | 注册表 + 调用入口（`FunctionMediator.call(name, args)`） |
| `LLMToolLoop` | 多轮「模型要工具 → 执行 → 回填」循环 |

内置工具（`ToolName` 里有常量）：

| 工具 | 说明 |
|---|---|
| `FileReadingFunction` / `FileWritingFunction` / `FileReplacngFunction` | 文件读写与替换，受 `llm_fileSandboxPath` 限制 |
| `CommandFunction` | 执行命令行 |
| `ConsoleFunction` | 控制台读写 |
| `WebSearchFunction` / `WebFetchFunction` | 联网搜索与抓取（带 `SsrfGuard` 防内网探测） |
| `SkillLoadingFunction` / `SkillReferenceLoadingFunction` | 技能与技能引用加载 |
| `MemoriesLoadingFunction` | 经验、教训、用户个性等记忆加载 |
| `TodoFunction` | todo 增删改查 |
| `CurrentTimeFunction` | 当前时间 |
| `AnswerFunction` | 结构化回答 |

---

## 存储

### 三族与配置键

| 族 | 存什么 | 实现 | 配置键 |
|---|---|---|---|
| 内容族 | 记忆、经验、知识、文档 | `f_hydra`（默认）/ `fhydra` / `postgres` / `mysql` / `inMemory` | `llm_memoryStore` |
| 元数据族 | 人格、技能、提示词、模型配置 | `postgres` / `mysql` / `f_store`（默认） | `llm_metaStore` |
| 演进族 | 演进报告、演进状态、已消费知识、每日租约 | 报告/状态跟随元数据族；租约跟随内容族 | 同上 |

- 未知配置值**启动失败**并打印可选列表，不静默回退；
- 自定义实现用 `Stores.registerContent(name, factory)` / `Stores.registerMeta(name, factory)` 注册；
- `Stores.content()` / `Stores.meta()` 按配置取当前实现。

### 契约

| 契约 | 说明 |
|---|---|
| `ContentStore` | 内容族容器：`prop memory: MemoryStore` + `prop knowledge: KnowledgeStore` |
| `MetaStore` | 元数据族容器：`characters` / `skills` / `prompts` / `confs` |
| `MemoryStore` | 记忆与经验：`add / get / remove / list / search / listByKind` |
| `KnowledgeStore` | 知识与切块：`upsert / get / remove / search / docIds` |
| `CharacterStore` | 每用户一条人格：`get / set / reset` |
| `SkillStore` | 技能：`upsert / get / list / remove` |
| `PromptStore` | 提示词：`put / get(name,version) / latest / remove` |
| `LLMConfStore` | 模型配置：`names / candidates / put` |

数据模型（`store/StoreModels.cj`）：

| 类型 | 关键字段 |
|---|---|
| `MemoryRecord` | `id / userId / namespace / title / content / kind / saveTime` |
| `MemoryHit` | `record / score`（`search` 返回，带正文） |
| `KnowledgeDoc` | `docId / title / content` |
| `Character` | `userId / characterKey / prompts` |
| `Skill` | `id / title / details / functions / version` |
| `PromptEntry` | `name / version / content` |
| `EvolutionEntry` | `id / skillTitle / action / detail / at` |

### 落盘布局

**f_store**（无数据库部署）：

```
f_llm:meta:character:{userId}                        → 人格（key 与 prompts 两段）
f_llm:meta:skill:{id}                                → 技能
f_llm:meta:prompt:{name}:{version}                   → 提示词
f_llm:evolution:data:{id}                            → 演进报告
f_llm:evolution:idx:{标题长度}:{标题}:{补零at}:{补零id}  → 报告索引（bySkill）
f_llm:evolution:time:{补零at}:{补零id}                → 报告索引（list）
f_llm:evo-state:run                                 → 演进水位线
f_llm:evo-state:skill:{title}                       → 每技能冷却与门禁结果
f_llm:evo-state:kn:{docId}                          → 已消费的知识
```

**SQL**：建表语句在模块根目录的 `tables-pg.sql` / `tables-mysql.sql`；`StoreWiring.wire()` 在启动时幂等建表并建索引（PG 的演进报告索引为 `(skill_title, at_time DESC)`）。

### 向量化（BGE-M3）

| 组件 | 作用 |
|---|---|
| `Embedding` | 门面：`embed(llmName, EmbeddingParam)`，走配置快照 + 熔断 |
| `HttpEmbedder` | OpenAI 兼容的 `/v1/embeddings` 客户端 |
| `BgeM3Transport` / `BgeM3Codec` | BGE-M3 三路编码（dense / sparse / colbert） |
| `DefaultEmbedder` | 生产用 `Embedder` 实现，读 `llm_embeddingUrl` |

端点默认 `http://127.0.0.1:8000/v1/embeddings`，可用 `deploy_bge_m3.sh` 在本机拉起。

### 知识检索

- `KnowledgeChunker`：按长度与重叠切块；
- `KnowledgeSearch`：向量召回（块级），返回 `KnowledgeHit`；
- `KnowledgeIndexRebuilder` / `MemoryIndexRebuilder`：启动时按 `llm_rebuildIndexOnStart` 重建索引。

---

## loom 编排

把一句自然语言变成可执行的流程：

```
自然语言描述
→ Planner（LLM 产出 JSON 计划，或返回澄清问题）
→ CodeGen（计划 → 步骤源码 + 流程源码，不编译）
→ LoomRegistry / LoomStore（存源码与状态）
→ LoomCompiler（编译步骤闭包）
→ LoomRunner（拓扑序执行，结果事件）
```

状态机：`clarifying → pending → compiled`，编译失败标 `failed`（单条失败不影响其它流程）。

### 5 分钟上手

```cangjie
import fountain::f_egraph.base.*
import fountain::f_llm.loom.*

// 1) 装配：存储网关、宿主、记忆策略、技能目录、演进表/状态/租约 一次性就位
let chat = { model: String, system: String, input: String => yourLlmCall(model, system, input) }
let service = LoomWiring.wire(chat, plannerModel: 'deepseek-flash')

// 2) 预览：Planner + CodeGen，落库 pending，不编译
let preview = service.execute(LoomRequest(
    name: 'daily-report',
    description: '每天汇总昨日提交与 issue，写成日报发给团队'))
println(preview.status)          // pending | clarifying
println(preview.flowSource)      // 生成的流程源码（可读、可改）
println(preview.stepSources)     // 每个步骤的源码

// 3) 确认：编译步骤闭包，成功后状态变 compiled
let _ = service.confirmFlow('daily-report')

// 4) 执行：需要一个宿主（模型通道 + 工具通道）
let host = DefaultLoomHost(chat)
let _ = service.executeNow('daily-report', host,
    StartEvent(category: 'loom', tag: 'daily-report', name: 'start', data: '{}'))

// 5) 其它入口
service.status('daily-report')   // 当前状态
service.delete('daily-report')   // 删除
```

| 阶段 | 做了什么 | 失败时 |
|---|---|---|
| `execute(confirm=false)` | Planner 产出计划 → CodeGen 产出源码 → 落 `pending` | 描述有歧义 → 落 `clarifying`，返回 `questions` |
| `confirmFlow(name)` | 编译步骤闭包 | 保持 `pending` 并抛错（源码仍可读、可改） |
| `executeNow(name, …)` | 要求状态为 `compiled` | 未编译直接抛错 |

不传 `chat` 时用 `LoomWiring.wire(plannerModel: '…')`，内部走 `LoomDefaults.chat`（需要配置好 `LLMConf`）。

### 手工定义流程

```cangjie
let plan = FlowPlan('weekly-report')
let fetch = StepPlan('fetch', 'tool')
fetch.tool = 'webSearch'
fetch.args = '{"query":"仓颉 本周发布"}'
let sum = StepPlan('sum', 'llm')
sum.model = 'deepseek-flash'
sum.system = '你是技术编辑'
sum.input = '本周动态：{fetch.output}'      // 引用上游步骤的输出
plan.steps.add(fetch)
plan.steps.add(sum)
plan.edges.add(EdgePlan('fetch', 'sum'))

let _ = LoomRunner().run(plan, host,
    StartEvent(category: 'loom', tag: 'weekly-report', name: 'start', data: ''))
```

| kind | 用途 | 关键字段 |
|---|---|---|
| `tool` | 调已注册工具 | `tool`、`args` |
| `mcp` | 调 MCP 工具 | `tool`、`args` |
| `llm` | 调模型 | `model`、`system`、`input` |
| `jit` | 任意 Cangjie 片段，可调 `loomStore` | `input` 是源码，需产出 `let <id>_result = …` |

`http` 是保留 kind，`plan.validate()` 会明确拒绝（不会被当成 `llm` 静默执行）。

| 规则 | 说明 |
|---|---|
| 执行顺序 | 按 `edges` 拓扑序；没有入边的步骤先跑 |
| 取值 | 模板 `{stepId.output}` 替换成该步骤的输出，`{start.output}` 是进入本步骤的事件数据 |
| JIT 变量不跨步骤 | 每个 JIT 步骤独立编译，只能通过 `{id.output}` 传值 |
| 并发 | 默认同步；`StepPlan.async` 或 `run(parallel: true)`（计划里 `parallel` 同理）才真并发 |
| 校验 | `plan.validate()`：重复 id、悬空边、缺 kind 都会抛错 |

### 工具（注册给模型）

| 工具 | 关键参数 | 行为 |
|---|---|---|
| `loomExecute` | `name, description, tools?, mcps?, persona?, confirm?, execute?, parallel?` | `confirm=false` 只返回计划；`confirm=true` 编译；`execute=true` 顺带跑一次 |
| `loomDelete` | `name` | 从注册表与库中移除 |
| `memoryCall` | `op`(search/add/remove) + `payload` | 与 `loomStore("memory", …)` 同一网关 |
| `knowledgeIngest` | `docId, title, content` | 写入知识库 |
| `loomStoreCall` | `kind, op, payload` | 通用读写入口，与 `loomStore` 同源（读知识/经验、加载技能） |
| `listTools` / `searchTools` | `offset, limit` / `query, topK` | 列工具、按关键词检索工具 |
| `skillImport` | `path` | 导入技能包目录，同名 title 幂等 |
| `scheduleCreate` / `scheduleDelete` | `name, cron, payload?` / `name` | 注册/取消定时任务 |

### 流程内的 JIT 入口

```cangjie
loomCallTool(name, argsJson)          // 调已注册的 tool / MCP
loomCallLlm(model, system, input)     // 调大模型
loomStore(kind, op, payload)          // 读写六类存储
```

| kind | op | 说明 |
|---|---|---|
| `memory` | `add` / `get` / `list` / `search` / `remove` | `search` 返回 `{id,title,content,kind,score}`，可直接喂模型；`list` 支持 `kind` 过滤 |
| `experience` | 同 `memory` | 入口别名，强制 `kind=experience` |
| `knowledge` | `get` / `docIds` / `search` / `upsert` / `remove` | `search` 返回命中块与正文 |
| `skill` | `load` / `get` / `list` / `upsert` / `count` / `remove` | `load` 按标题取正文 |
| `prompt` | `latest` / `get` / `put` / `remove` | `put` 的 `version<=0` 表示接在最新版本之后 |
| `character` | `get` / `set` / `reset` | `characterKey` 必须是预定义值（或 `custom`） |
| `evolution` | `list` / `by_skill` | **只读**：报告由后台演进任务写 |

payload 都是 JSON 字符串：

```cangjie
let mem  = loomStore("memory", "list",
    "{\"userId\":7,\"namespace\":\"work\",\"kind\":\"note\",\"offset\":0,\"limit\":20}")
let hits = loomStore("memory", "search",
    "{\"userId\":7,\"namespace\":\"work\",\"text\":\"发布流程\",\"topK\":5}")
let one  = loomStore("memory", "get", "{\"userId\":7,\"id\":42}")
let id   = loomStore("memory", "add",
    "{\"userId\":7,\"namespace\":\"work\",\"title\":\"发布结论\",\"content\":\"先灰度 5%\",\"kind\":\"note\"}")

let exp  = loomStore("experience", "search",
    "{\"userId\":7,\"namespace\":\"work\",\"text\":\"灰度\",\"topK\":5}")

loomStore("knowledge", "upsert", "{\"docId\":\"k1\",\"title\":\"发布规范\",\"content\":\"先灰度 5%\"}")
let doc  = loomStore("knowledge", "get", "{\"docId\":\"k1\"}")
let docs = loomStore("knowledge", "search", "{\"text\":\"灰度\",\"limit\":5}")

let skill = loomStore("skill", "load", "{\"title\":\"日报助手\"}")
let all   = loomStore("skill", "list", "{}")
let prm   = loomStore("prompt", "get", "{\"name\":\"reviewer\",\"version\":1}")
let ch    = loomStore("character", "get", "{\"userId\":7}")

let history = loomStore("evolution", "by_skill", "{\"skill\":\"日报助手\",\"limit\":5}")
```

在下一个 LLM 步骤里用模板引用：

```cangjie
let ask = StepPlan('ask', 'llm')
ask.model = 'deepseek-flash'
ask.system = 'BASE'
ask.input = '参考资料：{mem.output}\n问题：{start.output}'   // 多路引用
```

### 人格与角色

`FlowPlan.persona` 与 `character` 最终都汇成 system 前缀，解析是**三级回落**：

```
1. prompt 库：prompt.latest(name) 命中 → 用它的 content
2. 内置角色正文：PredefinedCharacters.bodyOf(name)（13 个预定义人格，正文固化在代码）
3. 字面文本：以上都没有 → 把入参本身当正文
```

```cangjie
// 1) 提示词库条目（最高优先级）
loomStore("prompt", "put", "{\"name\":\"reviewer\",\"content\":\"你是严格评审员\"}")
plan.persona = 'reviewer'

// 2) 预定义人格 key
plan.persona = 'rigorous'        // default/rigorous/friendly/blunt/…

// 3) 字面文本
plan.persona = '只挑错，不夸奖'

// 4) 留空：回落到该用户的 character 记录
loomStore("character", "set",
    "{\"userId\":7,\"characterKey\":\"rigorous\",\"prompts\":\"回答不超过 300 字，用中文\"}")
plan.persona = ''
```

`custom` 是特例：正文只来自 `character.prompts`，不会把 `custom` 这个词当人格；两者都空就等于不设置。
`character.prompts` 作为**用户级附加要求**（语言、篇幅等）追加在人格正文之后。
角色记录按 `LoomMemoryPolicy.userId` 取（`userId<=0` 时跳过）。

### 技能注入

| 方式 | 用法 | 说明 |
|---|---|---|
| 显式 | `LoomRunner().run(plan, host, start, skills: ['日报助手'])` 或计划 JSON 的 `"skills"` | 按标题加载，顺序固定；`executeNow(skills:)` 可临时覆盖 |
| 自动 | 不传 `skills` 且 `autoSkills=true`（默认） | 用「计划备注 + 起始输入」检索，取 `skillTopK`（默认 3）条 |

`SkillCatalog` 两种模式：装了编码器走向量余弦（向量按 `标题#版本` 缓存），否则/失败退关键词
（词面包含、字符命中比例、标题覆盖比例）。**编码失败会静默降级**，排障读
`SkillCatalog.embedFailureDetail()`——返回 `(query 侧失败数, 技能侧失败数)`。

### 流程结束的提炼

`LoomRunner` 在 `finally` 里（成功失败都走）：

| 产出 | kind | 条件 |
|---|---|---|
| 上下文摘要 | `note` | `policy.enabled`（默认 true）且本次至少调过一次模型 |
| 执行经验 | `experience`（失败为 `experience_failed`） | 同上 |
| 知识文档 | `loom:<流程>:<序号>` | 额外开 `writeKnowledge` |

`summarize=true` 时改由模型返回 `{"memory":"…","experience":"…"}`，JSON 非法回落规则提炼。

开关都在 `LoomMemoryPolicy`：

| 参数 | 默认 | 作用 |
|---|---|---|
| `enabled` | `true` | 关掉后连临时上下文都不记 |
| `userId` / `namespace` | `0` / `'loom'` | 写到哪；也决定读哪个 character |
| `maxTurns` | `20` | 摘要最多取最近多少轮 |
| `summarize` / `model` | `false` / `''` | 模型提炼 |
| `writeKnowledge` | `false` | 额外写知识文档 |
| `autoSkills` / `skillTopK` / `skillMinScore` | `true` / `3` / `0.2` | 自动技能挑选 |

### 定时任务

`scheduleCreate` 注册的流程任务由 `LoomScheduler`（`TicktockScheduler`，基于 `f_ticktock`）驱动；
JIT 步骤在任务里执行时由 `JitTicktockTask` 承接。`LoomSchedules` 未安装时注册与触发都跳过。

### 第三方平台通道（邮件）

流程要把结果送出去时，走 `channel` 而不是直接调 `f_email`：

```bash
export llm_channels='[{"platform":"email","account":"work","from":"bot@example.com",
  "user":"bot@example.com","password":"***","smtpHost":"smtp.example.com","smtpPort":465,
  "imapHost":"imap.example.com","imapPort":993}]'
```

```cangjie
// 流程步骤里（JIT / 工具循环均可）
loomCallTool("channelSend",
    '{"platform":"email","account":"work","to":"a@b.c","subject":"日报","text":"正文",' +
    '"attachments":[{"filename":"report.pdf","path":"/tmp/report.pdf"}]}')
loomCallTool("channelInbox", '{"platform":"email","account":"work","downloadDir":"/tmp/inbox"}')
```

| 能力 | 说明 |
|---|---|
| 平台 / 账号 | 中介者按 `(platform, account)` 寻址；同平台可多账号；账号留空仅当该平台只有一个实例才回落 |
| 扩展新平台 | 实现 `Channel` + 一行顶层 `let _ = ChannelMediator.registerProvider('xxx', …)` 自动注册 |
| 已实现 | `email`（SMTP 发 / IMAP 收，含附件）；`wechat` / `wecom` / `dingtalk` / `feishu` 仅预留常量 |
| 附件 | 发送按路径给出，且必须在允许根目录内（否则整封失败）；接收给 `downloadDir` 才落盘，文件名只取最后一段，同名顺延 `-2`，不覆盖 |

### 流程路由（Supervisor）

流程多了以后，调用方不必再记「该找哪个流程」：打开 `llm_supervisor`，流程编译成功即自动登记成路由目标，
一段描述交给模型判定落在哪条流程上，再把描述作为事件投递进去。

```bash
export llm_supervisor=true        # 打开路由；每个流程对应唯一事件 sv/<流程名>
export llm_loomOnNoUsable=true    # 可选：没有可用流程时自动编排一条并执行（默认关）
```

```cangjie
// LoomWiring.wire 按开关自动装配：路由表用已编译流程播种，重启后从流程库重建
let service = LoomWiring.wire(chat, plannerModel: 'deepseek-flash')

// 派发：描述 → 选路 → 执行；描述就是起始事件的 data，经 {start.output} 进入首步
let supervisor = Supervisor.current().getOrThrow()
let outcome = supervisor.dispatch('把今天的提交汇总一下')
println(outcome.kind)     // dispatched | created | noUsableFlow | clarifying
println(outcome.flow)     // 命中的流程名（created 时是新建的 auto-<秒级时间戳>）
println(outcome.event)    // 实际使用的 Supervisor 事件名 sv/<流程名>
println(outcome.message)  // 无可用流程时的固定文案
```

| `outcome.kind` | 含义 | `result` |
|---|---|---|
| `dispatched` | 命中已有流程并执行完 | `Some(Event)` |
| `created` | 自动新建流程、登记并执行完 | `Some(Event)` |
| `clarifying` | 自动新建时编排要求补充信息 | `None`（问题已落流程库） |
| `noUsableFlow` | 没有可用流程（含选路输出不可用） | `None` |

路由表运行期可随时增删：

```cangjie
supervisor.routes()          // 全部路由：名称 / 描述 / 事件名 / 状态
supervisor.routable()        // 只有 compiled，可被选路命中
supervisor.eventOf('daily')  // Some("sv/daily")

let _ = supervisor.register('adhoc', '临时流程', status: LoomStatus.COMPILED)  // 手动加一条
let _ = supervisor.unregister('adhoc')                                        // 手动摘掉
```

| 行为 | 说明 |
|---|---|
| 登记 | `execute` / `confirmFlow` 落库后自动登记；`delete` 自动摘除；`clarifying` 不登记（无源码不可执行） |
| 选路 | 只把 `compiled` 流程的名称/描述/事件名发给模型；非 JSON、空名、不在表内一律按无可用处理 |
| 事件名 | `sv/<流程名>`，与内部 tag `loom/<name>#<seq>` 区分 |
| 无可用 | `llm_loomOnNoUsable=false` → 返回「没有可完成此工作的流程」；`true` → 自动编排、登记并执行 |
| 存储不可用 | 启动不中断：`LoomBootstrap.startup(...)` 返回 `restoreFailed=true`，路由表为空但流程服务可用 |
| 关闭态 | 零开销：不注册、不选路、不产生额外模型调用 |

---

## 经验 → 技能演进

流程结束只写经验，**技能的一切改动都由 `SkillEvolutionJob` 执行**：

```
到点触发 → 读水位线后的新增素材（经验 + 知识）
  → SkillMatcher：归到已有技能 / 聚成新技能候选
  → 先演进已有技能：Policy 判定 → 模型改正文 → SkillGate A/B → 版本 +1
  → 再提炼新技能：簇够大 → SkillNamer 起名（必须带样例）→ version=1
  → SkillEvolutionLedger 落报告 → 推进水位线
```

| 组件 | 默认策略 |
|---|---|
| `SkillEvolutionPolicy` | 样本 ≥ 3、成功率 ≥ 0.8、冷却 1 天；**上次门禁失败则 2 天** |
| `SkillGate` | 用技能自带 `samples` 跑旧版/新版，新版 ≥ 旧版且达 `minScore` 才落库；无样例直接拒绝 |
| `SkillNamer` | 标题 ≤ 24 字、**至少一条样例**，否则不建（没样例的新技能无法自我演进） |
| 知识去重 | `processedAmong(docIds)` 成员判定，避免同一批知识每轮重复聚类 |

启动注册：

```cangjie
LoomWiring.wire(chat, plannerModel: 'chat-pro',
                evolutionCron: '0 0 3 * * * *',      // 空串 = 不启用
                evolutionUserId: 7,
                evolutionNamespace: 'work',
                evolutionNameCandidates: true,
                skillEmbedder: SkillCatalog.embeddingEncoder('bge-m3'))
```

### 多进程互斥：每日租约

任务一天只跑一次，用「时间型 UUID + 日期级乐观锁」保证只有一个进程执行：

| 向量存储（`llm_memoryStore`） | 租约存放 | 互斥 |
|---|---|---|
| `mysql` / `postgres` | 单行表 `llm_evolution_lease` | `UPDATE … WHERE lease_value = 旧值`，真正 CAS |
| `f_hydra` | 本地全 0 向量记录的 payload | 本地存储，单进程无需跨进程 |
| `fhydra` | 远程全 0 向量记录 | 先写后读校验 |
| 其它 | f_store / 内存 | 单进程 |

全 0 向量的原因：租约不该被任何语义检索命中（与任何查询的余弦都是 0）。

```
启动 → EvolutionLeases.bootstrap()：租约不存在就写一次 UUID
每天触发 → acquire(now)
  ├─ 日期 == 今天 → 空串 → 放弃
  └─ 日期 < 今天 → 新 UUID + CI 覆盖
       ├─ 成功 → 抢到
       └─ 失败（别人先改）→ 放弃
```

---

## 检索评测

单测只验证排序逻辑，语义质量要用真实模型测（详见 `doc/retrieval-eval.md`）：

| 位置 | 内容 |
|---|---|
| `eval/retrieval_corpus.tsv` | 50 条语料（10 主题 × 5） |
| `eval/retrieval_queries.tsv` | 612 条正样本（300 模板化 + 300 难样本 + 12 多相关）+ 10 条负样本 |
| `eval/run_eval.sh` | 一键跑真实 embedding 并输出报告 |

```bash
eval/run_eval.sh                          # 默认 bge-m3 + 127.0.0.1:8000
fllm_evalMinScore=0.5 eval/run_eval.sh    # 调阈值
```

指标：`recall@1` / `recall@5` / `MRR` / `nDCG@5`（位置敏感、多相关按理想排序归一）+ 负样本通过率。
实测（bge-m3，`minScore=0.5`）：模板化 ~100%、**难样本 recall@1 39.66% / nDCG@5 54.76%**、负样本 90%；
同一 `hard` 集合上字符重合只有 22%。

Cangjie 侧入口：

```cangjie
let outcome = RetrievalEvalRunner.run(InMemoryMetaStore(), './eval', 'bge-m3', minScore: 0.5f64)
println(outcome.report)
// outcome.embedFailures 必须为 0，否则测的是关键词而不是向量
```

---

## 配套脚本与建表

### `deploy_bge_m3.sh`：本机 BGE-M3 向量服务

把 BGE-M3 装成一个 OpenAI 兼容的 `/v1/embeddings` 端点（dense + sparse + colbert 三路），`llm_embeddingUrl` 的默认值就指向它。

```bash
sudo ./deploy_bge_m3.sh                    # 安装或更新（幂等，可重复执行）
sudo ./deploy_bge_m3.sh status             # 看服务 / 模型 / 端口状态
sudo ./deploy_bge_m3.sh smoke              # 打一发 embedding 自检
sudo ./deploy_bge_m3.sh restart            # 重启服务
sudo ./deploy_bge_m3.sh uninstall          # 停服务、删 unit（保留模型）
sudo ./deploy_bge_m3.sh uninstall --purge  # 连 /opt/bge-m3 一起删
```

脚本做的事：系统依赖与独立 venv（默认 `/opt/bge-m3/venv`）→ 装 torch(CPU)+transformers+fastapi+uvicorn →
从 ModelScope 下权重（含 `sparse_linear.pt` / `colbert_linear.pt` 两个投影）→ 起 `/v1/embeddings` →
注册 systemd 并做健康检查。

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `BGE_HOME` | `/opt/bge-m3` | 安装根目录（venv / model / server.py） |
| `BGE_PORT` | `8000` | 监听端口，对应 `llm_embeddingUrl` |
| `BGE_THREADS` | `8` | torch 线程数 |
| `BGE_PIP_INDEX` / `BGE_PIP_EXTRA` | 清华镜像 / 空 | pip 源与附加源 |
| `BGE_MODEL_BASE` | ModelScope `BAAI/bge-m3` | 权重源 |
| `BGE_FORCE_DOWNLOAD` | `0` | 置 `1` 强制重下权重 |

只跑 dense 也能用：把 `llm_embeddingUrl` 指向任意 OpenAI 兼容端点即可，但 sparse / colbert 缺失时检索结果会标
`degraded` 且重排失效（见 `doc/known-limitations.md` §2）。

### `tables-pg.sql` / `tables-mysql.sql`：建表

两个文件列定义一一对应，只允许类型、自增与索引语法不同，**必须同步改**。共 20 张表：

| 分组 | 表 |
|---|---|
| 模型配置 | `llm_conf` |
| 记忆与知识 | `llm_memory` / `llm_memory_kind` / `llm_memory_event` / `llm_memory_vector` / `llm_memory_token` / `llm_document` / `llm_document_chunk` |
| 元数据 | `llm_character` / `llm_character_binding` / `llm_channel_binding` / `llm_prompt` / `skills` / `skill_references` / `llm_skill_version` / `agents` / `memory_summaries` / `agent_todo` |
| 编排与用量 | `llm_loom_flow` / `llm_token_usage` |

```bash
# PostgreSQL（需要 pgvector >= 0.7，扩展名 vector）
psql "postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test" \
     -c 'CREATE EXTENSION IF NOT EXISTS vector'
psql "postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test" -f tables-pg.sql

# MySQL（普通表 8.0+；VECTOR 列与 HNSW 索引需 9.2+）
mysql -h127.0.0.1 -ufllm_test -p fllm_test < tables-mysql.sql
```

| 注意 | 说明 |
|---|---|
| 演进族 4 张表不在这里 | `llm_skill_evolution` / `llm_skill_evolution_state` / `llm_skill_evolution_knowledge` / `llm_evolution_lease` 由 `EvolutionStores` / `EvolutionStateStores` / `EvolutionLeases` 的 `bootstrap()` 在启动时幂等创建 |
| 已存在的表不补列 | `CREATE TABLE IF NOT EXISTS` 只建不改；加列必须自己 `ALTER TABLE`（并同步两个文件） |
| MySQL 旧版本 / MariaDB | 删掉文件末尾向量索引语句（MariaDB 连向量列一起删）即可，向量检索降级为「取候选 + 应用层计算」，结果不变只是慢 |
| 与代码同步 | 改列先改 `tables-pg.sql`，再同步 `tables-mysql.sql` 与 `src/model/po` 的字段 |

---

## 配置项

全部是环境变量，启动时读一次。

### 存储与向量化

| 键 | 默认 | 说明 |
|---|---|---|
| `llm_memoryStore` | `f_hydra` | 内容族 + 租约：`f_hydra`/`fhydra`/`postgres`/`mysql`/`inMemory` |
| `llm_metaStore` | `f_store` | 元数据族 + 演进报告/状态 |
| `llm_metaStorePath` | `./data/f_llm-meta` | f_store 路径 |
| `llm_contentStoreUrl` | 空 | 远程内容存储地址（fhydra） |
| `llm_hydraPath` / `llm_hydraUrl` / `llm_hydraSecret` | `./data/f_hydra` / `http://127.0.0.1:18081/rpc` / 空 | f_hydra 本地路径、远程地址、共享密钥 |
| `llm_embeddingUrl` | `http://127.0.0.1:8000/v1/embeddings` | BGE-M3 端点 |
| `llm_embeddingTimeoutMs` / `llm_embeddingRetries` | `3000` / `2` | 超时与重试 |
| `llm_rebuildIndexOnStart` / `llm_rebuildIndexUserId` / `llm_rebuildIndexNamespace` | 关 / 0 / 空 | 启动重建向量索引 |
| `llm_memoryUserId` | 0 | 记忆默认归属用户 |

### 模型访问

| 键 | 默认 | 说明 |
|---|---|---|
| `llm_confSource` | 空 | 配置来源：`static` / `file` / `env` / `database` / `store` |
| `llm_confs` | 空 | 内联配置（JSON 数组） |
| `llm_confRefreshSeconds` | 无 | 配置刷新周期 |
| `llm_loadBalanceAlgo` | 无 | 候选挑选算法 |
| `llm_failureThreshold` / `llm_cooldownSeconds` | 无 | 熔断阈值与冷却 |
| `llm_accessTryingCount` / `llm_accessTryingElapsed` | 无 | 重试次数 / 总重试时长 |
| `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` | 无 | 流式空闲超时与单行上限 |
| `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` | 无 | 工具结果 / 抓取内容上限 |
| `llm_prunerLlmName` / `llm_summarisingLlmName` | 无 | 依赖模型的裁剪器 / 提炼所用模型 |
| `llm_balanceLowThreshold` | 无 | 余额告警阈值 |
| `llm_supervisor` | `false` | 打开流程路由（Supervisor）：已编译流程自动登记、可按描述派发 |
| `llm_loomOnNoUsable` | `false` | Supervisor 判定无可用流程时自动编排新流程；仅 `llm_supervisor=true` 时生效 |
| `llm_channels` | 空 | 第三方平台账号（JSON 数组，一条一个账号；单条非法只跳过并 warn） |
| `llm_channelSendRoots` | 空 | 允许作为邮件附件的根目录（逗号分隔）；未配置时回落 `llm_fileSandboxPath`，都没有则禁用附件 |

### 其它

| 键 | 默认 | 说明 |
|---|---|---|
| `llm_fileSandboxPath` | 无 | 文件工具只能访问该目录 |
| `llm_faithfulMemoryPath` | 无 | 忠实记忆落盘路径 |
| `llm_makingMemory` | 无 | 是否保存记忆（保存才有经验） |
| `llm_summarisingModel` / `llm_summarisingActionKind` | `glm-4.7-flash` / 无 | 经验总结模型与动作类型 |
| `llm_db` | 无 | 数据库连接（SQL 部署） |
| `hydra_filterFields` | `kind,save_day,tags` | fhydra 服务端倒排白名单（改后重启自动重建） |
| `fllm_runEval` / `fllm_evalModel` / `fllm_evalMinScore` / `fllm_evalDir` | 未设 / `bge-m3` / `0.2` / `./eval` | 检索评测 |

旧键 `llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` / `llm_contentStore` 只识别、不生效，启动时逐条 `warn`。

---

## 测试

```bash
cjpm test                 # 单元测试，不依赖外部服务
cjpm test                 # 真库用例连得上就跑，连不上打印 SKIP 自行跳过
```

真库用例探测连接（`postgresReady()` / `mySqlReady()`）：连不上打印 `SKIP …` 后跳过，不算失败；连上了断言失败照常报错。准备 PostgreSQL / MySQL 见 `doc/dev-env.md`。

---

## 文档

| 文件 | 内容 |
|---|---|
| `doc/f_llm.md` | 设计文档：分层、契约、数据布局、关键流程、失败降级、测试策略 |
| `doc/f_llm-memory-design.md` | 记忆 / 知识 / 技能 / 人格的设计与提示词 |
| `doc/loom.md` | loom 编排、存储网关、人格、技能演进、报告表 |
| `doc/retrieval-eval.md` | 检索评测：数据格式、指标、真实基线、门槛 |
| `doc/content-store.md` | 内容族存储契约 |
| `doc/known-limitations.md` | 已知限制（配置只读、并发、成本等） |
| `doc/dev-env.md` | 开发环境与依赖 |
| `doc/todo.md` | 未实现项 |
| `doc/spec/add-loom-supervisor/` | 流程路由的规格副本（proposal / spec / design / tasks） |

---

## 已知限制（摘要）

| 项 | 说明 |
|---|---|
| 配置只读 | 只在启动时读取一次，切换存储或端点必须重启 |
| 编码器失败静默降级 | `SkillCatalog` 退回关键词；用 `embedFailureDetail()` 判断实际走向 |
| 演进重建是全量扫描 | 白名单变更时重建倒排，O(记录数)，建议低峰期操作 |
| `processedKnowledge` 有上限 | 只用于运维查看；去重走 `processedAmong`，无上限 |
| 单进程定时任务 | `SkillEvolutionJob.schedule` 注册在服务内，跨进程依靠每日租约 |

## A2A（Agent-to-Agent）

默认关闭。设 `llm_a2aEnabled=true` 后，装配时把 `loom.Supervisor` 暴露成 A2A 智能体：

| 方向 | 用法 |
|---|---|
| 外部 → loom | A2A 客户端调 `a2a.message.send`，正文交给 `Supervisor.dispatch`，结果作为任务终态返回 |
| loom → 外部 | `LoomA2aClient().ask(url, text)`；流程内可用工具 `a2aCall{url, text}` |

结果映射：`dispatched` / `created` → `completed`，`clarifying` → `input-required`，其余 → `failed`。
`dispatch` 是同步的，长流程会让 A2A 请求等待；需要边跑边推时用 `f_a2a` 的 `a2a.message.stream`（SSE）。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`public class A2aCallFunction <: FunctionCalling<A2aCallParam>`、`public class A2aCallParam`、`AbstractFileFunction`（class）、`public class Agent`、`AgentEvent`（class）、`AgentEventData`（class）、`AgentTask`（class）、`AgentsFinder`（interface）、`public class AliyunBalanceQuerier <: BalanceQuerier`、`public class Answer`、`public open class AssistantMessage <: ChatMessage`、`public class AssumptionDto`、`AttachmentSink`（class）、`BalanceMediator`（class）、`BalancePoster`（type）、`BalanceQuerier`（interface）、`public class BalanceSnapshot`、`BalanceUnits`（struct）、`BalanceUnsupportedException`（class）、`CallLog`（struct）、`ChannelAccountConf`（class）、`public class ChannelAttachmentParam`、`ChannelBootstrap`（class）、`ChannelException`（class）、`public class ChannelInboxFunction <: FunctionCalling<ChannelInboxParam>`、`public class ChannelInboxParam`、`ChannelInstallReport`（class）、`ChannelPlatforms`（struct）、`public class ChannelSendFunction <: FunctionCalling<ChannelSendParam>`、`public class ChannelSendParam`、`ChatCompletionsMapper`（struct）、`public open class ChatMessage`、`ChatStreamAccumulator`（class）、`ClarifyQuestion`（class）、`Code`（class）、`CodeFinder`（interface）、`CodeParam`（class）、`ColbertCodec`（class）、`ColbertVectors`（class）、`public class Command`、`public class ConsoleOutput`、`public class ContentPart`、`public abstract class ContextLLMPruner <: ContextPruner`、`ContextPruner`（interface）、`ContextPrunerName`（type）、`public open class ContextSummaryPruner <: ContextLLMPruner`、`public class CurrentTimeParams`、`public class DeepSeekBalanceQuerier <: BalanceQuerier`、`public class DeepSeekSearchProvider <: SearchProvider`、`DefaultHttpTransport`（class）、`DefaultStreamTransport`（class）、`DeployPaths`（class）、`public interface DoSample`、`public struct DummyTokenUsageSaver <: TokenUsageSaver`、`EmailChannel`（class）、`EmailTransport`（interface）、`EmbeddingException`（class）、`public class EmbeddingResp`、`EmbeddingResponse`（class）、`EmbeddingTransport`（interface）、`EvalCase`（class）、`EvalDoc`（class）、`EvalOutcome`（class）、`EvalReport`（class）、`EventFinder`（interface）、`EvolutionDecision`（class）、`EvolutionInput`（class）、`EvolutionLease`（interface）、`EvolutionSkillState`（class）、`EvolutionStateStore`（interface）、`EvolutionStore`（interface）、`public class ExperienceExtractor <: MemoryExtractor`、`public interface ExperienceFinder <: MemorySummaryFinder`、`ExperienceItem`（class）、`FEmailTransport`（class）、`FStoreEvolutionLease`（class）、`FStoreEvolutionStateStore`（class）、`FStoreEvolutionStore`（class）、`FStoreLoomStore`（class）、`FStoreMetaStore`（class）、`FaithfulMemory`（interface）、`FetchRejectedException`（class）、`public class FetchedPage`、`FhydraContentStore`（class）、`public class FileReadingParams`、`public class FileReplacingParams`、`public class FileWritingParams`、`FrequencyPenalty`（interface）、`public class Function`、`public class FunctionCall <: Hashable & Equatable<FunctionCall>`、`FunctionCallingException`（class）、`FunctionMeta`（struct）、`FunctionNotFoundException`（class）、`FunctionResult`（struct）、`GeneratedFlow`（class）、`HeuristicTokenCounter`（class）、`HydraContentStore`（class）、`HydraEvolutionLease`（class）、`HydraMemoryRepository`（class）、`IllegalPathException`（class）、`InMemoryContentStore`（class）、`InMemoryEvolutionLease`（class）、`InMemoryEvolutionStateStore`（class）、`InMemoryEvolutionStore`（class）、`InMemoryKnowledgeStore`（class）、`public class InMemoryMemoryStore <: MemoryStore`、`InboundAttachment`（class）、`InboundMessage`（class）、`public class IndividualityExtractor <: MemoryExtractor`、`public interface IndividualityFinder <: MemorySummaryFinder`、`KindPersistence`（interface）、`Knowledge`（class）、`KnowledgeChunk`（class）、`KnowledgeEntity`（class）、`KnowledgeFinder`（interface）、`public class KnowledgeIngestFunction <: FunctionCalling<KnowledgeIngestParam>`、`public class KnowledgeIngestParam`、`KnowledgeKind`（type）、`KnowledgeParam`（class）、`KnowledgeQuery`（class）、`LLMApiKind`（enum）、`LLMConfCodec`（struct）、`public interface LLMConfDAO <: RootDAO`、`public class LLMConfServiceImpl <: LLMConfService`、`LLMConfView`（class）、`LLMConfig`（struct）、`LLMConfsHolder`（class）、`LLMConfsSnapshot`（class）、`LLMDelta`（class）、`LLMDeltaKind`（enum）、`LLMErrorClassifier`（struct）、`LLMException`（class）、`LLMHooks`（class）、`LLMHttpResponse`（class）、`public class LLMResp`、`LLMStreamTransport`（interface）、`public open class LLMToolParams <: LLMParams`、`LLMTransport`（interface）、`LLMType`（type）、`public class ListToolsFunction <: FunctionCalling<ListToolsParam>`、`public class ListToolsParam`、`LlmEmbeddingTransport`（class）、`LlmTurn`（class）、`LoomA2a`（class）、`LoomAgent`（class）、`LoomCharacterScope`（class）、`LoomContextLog`（class）、`public class LoomDeleteFunction <: FunctionCalling<LoomDeleteParam>`、`public class LoomDeleteParam`、`LoomException`（class）、`public class LoomExecuteFunction <: FunctionCalling<LoomExecuteParam>`、`public class LoomExecuteParam`、`LoomFlow`（class）、`LoomHost`（interface）、`LoomHostApi`（class）、`LoomJitBridge`（class）、`LoomMemoryExtractor`（class）、`LoomProgram`（class）、`LoomRegistry`（class）、`LoomResult`（class）、`LoomService`（class）、`LoomServices`（class）、`LoomStatus`（struct）、`LoomStoreGateway`（class）、`LoomTimeout`（class）、`McpClientAdapter`（class）、`McpFunctionCalling`（class）、`McpToolClient`（interface）、`McpToolSource`（class）、`Memory`（struct）、`public class MemoryCallFunction <: FunctionCalling<MemoryCallParam>`、`public class MemoryCallParam`、`MemoryExtractor`（class）、`MemoryKinds`（class）、`public class MemoryLoading`、`MemoryLoomStore`（class）、`MemoryQuery`（class）、`MemoryRecorderTask`（class）、`MemoryRepository`（interface）、`MemoryRepositoryAdapter`（class）、`MemoryStoreAdapter`（class）、`public class MemorySummary`、`MemorySummaryFinder`（interface）、`MemoryWrite`（class）、`MetaStoreAdapter`（class）、`ModelCapabilities`（struct）、`ModelName`（type）、`MySqlContentStore`（class）、`public interface MySqlEvolutionDAO <: RootDAO`、`MySqlEvolutionLease`（class）、`public interface MySqlEvolutionLeaseDAO <: RootDAO`、`public interface MySqlEvolutionStateDAO <: RootDAO`、`MySqlEvolutionStateStore`（class）、`MySqlEvolutionStore`（class）、`public interface MySqlKindDAO <: RootDAO`、`MySqlKindPersistence`（class）、`public interface MySqlKnowledgeDAO <: RootDAO`、`MySqlKnowledgeStore`（class）、`public interface MySqlLoomDAO <: RootDAO`、`MySqlLoomStore`（class）、`public interface MySqlMemoryDAO <: RootDAO`、`public class MySqlMemoryRepository <: MemoryRepository & RootService`、`public interface MySqlMetaDAO <: RootDAO`、`public class MySqlMetaStore <: MetaStore & RootService`、`public interface MySqlTokenUsageDAO <: RootDAO`、`public class MySqlTokenUsageSaver <: TokenUsageSaver & RootService`、`public class OptionDto`、`OrganizationFinder`（interface）、`OutboundAttachment`（class）、`OutboundMessage`（class）、`public class Parameters`、`public class PlanDto`、`PlannerResult`（class）、`PostgresContentStore`（class）、`public interface PostgresEvolutionDAO <: RootDAO`、`PostgresEvolutionLease`（class）、`public interface PostgresEvolutionLeaseDAO <: RootDAO`、`public interface PostgresEvolutionStateDAO <: RootDAO`、`PostgresEvolutionStateStore`（class）、`PostgresEvolutionStore`（class）、`public interface PostgresKindDAO <: RootDAO`、`PostgresKindPersistence`（class）、`public interface PostgresKnowledgeDAO <: RootDAO`、`PostgresKnowledgeStore`（class）、`public interface PostgresLoomDAO <: RootDAO`、`PostgresLoomStore`（class）、`public interface PostgresMemoryDAO <: RootDAO`、`public class PostgresMemoryRepository <: MemoryRepository & RootService`、`public interface PostgresMetaDAO <: RootDAO`、`public class PostgresMetaStore <: MetaStore & RootService`、`public interface PostgresTokenUsageDAO <: RootDAO`、`public class PostgresTokenUsageSaver <: TokenUsageSaver & RootService`、`PredefinedCharacters`（class）、`PromptCapabilities`（class）、`Prompts`（struct）、`public class Property`、`public class QuestionDto`、`ReceivedAttachment`（class）、`ReceivedMail`（class）、`ReloadResult`（class）、`RemoteTokenCounter`（class）、`public class ResponseFormat`、`ResponsesMapper`（struct）、`ResponsesStreamAccumulator`（class）、`ResultType`（enum）、`RetrievalEval`（class）、`RetrievalScoring`（class）、`Role`（type）、`RoleException`（class）、`public class ScheduleCreateFunction <: FunctionCalling<ScheduleCreateParam>`、`public class ScheduleCreateParam`、`public class ScheduleDeleteFunction <: FunctionCalling<ScheduleDeleteParam>`、`public class ScheduleDeleteParam`、`SearchHttpException`（class）、`SearchPoster`（type）、`SearchProvider`（interface）、`SearchProviderRegistry`（class）、`public class SearchResult`、`public class SearchResultItem`、`public class SearchToolsFunction <: FunctionCalling<SearchToolsParam>`、`public class SearchToolsParam`、`SearchUnavailableException`（class）、`SendReceipt`（class）、`SignUtil`（struct）、`public class SiliconFlowBalanceQuerier <: BalanceQuerier`、`SkillAssignment`（class）、`SkillCandidate`（class）、`SkillDraft`（class）、`SkillEntry`（class）、`SkillEvolutionLedger`（class）、`SkillEvolutionReport`（class）、`SkillEvolutionTask`（class）、`SkillGateResult`（class）、`public class SkillImportFunction <: FunctionCalling<SkillImportParam>`、`public class SkillImportParam`、`SkillImporter`（class）、`public class SkillLoading`、`SkillMatchResult`（class）、`SkillNotFoundException`（class）、`SkillPackage`（class）、`public class SkillReference`、`public class SkillReferenceLoading`、`public class SkillReferenceParam`、`SkillSample`（class）、`SkillSamples`（class）、`SkillType`（type）、`SkillsFinder`（interface）、`SpecKind`（type）、`SpecialAgentId`（type）、`Specification`（class）、`SpecificationFinder`（interface）、`public class SqlMemoryStore <: MemoryStore`、`public class StepDto`、`public class StoreCallFunction <: FunctionCalling<StoreCallParam>`、`public class StoreCallParam`、`StoreSettings`（class）、`SummaryActionKind`（type）、`SupervisorAgent`（class）、`SupervisorOutcome`（class）、`SupervisorRoute`（class）、`public class SystemMessage <: ChatMessage`、`public class TencentCloudBalanceQuerier <: BalanceQuerier`、`TencentSigner`（struct）、`TextClip`（class）、`public class Thinking`、`public interface ThinkingBudget`、`ThinkingMode`（enum）、`ThinkingPolicy`（struct）、`ThinkingSwitch`（type）、`TimeUuid`（class）、`public class Todo`、`TodoFinder`（interface）、`public class TodoListParam`、`public class TodoSaving`、`public class TodoSavingParam`、`TodoStatus`（type）、`public class TodoStatusParam`、`TokenCounter`（interface）、`public class TokenUsage`、`TokenUsageSaver`（interface）、`public class TokenizerParams`、`public class ToolCall`、`public class ToolCallFunction`、`public class ToolCallMessage <: AssistantMessage`、`ToolCatalog`（class）、`ToolEntry`（class）、`public class ToolMessage <: ChatMessage`、`ToolScope`（class）、`ToolType`（type）、`TopicStat`（class）、`VectorMath`（class）、`VolcSigner`（struct）、`public class VolcengineBalanceQuerier <: BalanceQuerier`、`public macro WeavedToolCall(input: Tokens): Tokens`、`public class WebFetchParams`、`public class WebSearchParams`、`public class ZhipuBalanceQuerier <: BalanceQuerier`、`createConfSource`（func）、`emptySkills`（func）、`parseConfJson`（func）、`parseDeepSeekBalance`（func）、`parseDeepSeekFetch`（func）、`parseDeepSeekSearch`（func）、`parseTencentBalance`（func）、`parseVolcengineBalance`（func）、`renderPage`（func）、`sanitizeSchema`（func）
- `Agent`：`acceptableEvents`（prop）、`prop producingEvents: Array<String>`
- `AgentEventData`：`addFunctions`（func）、`let memorySummaries!: ArrayList<MemorySummary> = ArrayList<MemorySummary>()`、`let skillDetails!: ArrayList<(String, String)> = ArrayList<(String, String)>()`
- `AgentTask`：`prop acceptableEvents: Array<String>`、`open func exec(e: Event): Event`、`prop producingEvents: Array<String>`
- `AliyunBalanceQuerier`：`prop provider: String`
- `AliyunDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
- `AssumptionDto`：`var field: String =`、`var reason: String =`、`var value: String =`
- `AttachmentSink`：`bareName`（func）、`freeName`（func）、`save`（func）
- `BalanceMediator`：`static let instance = BalanceMediator()`、`queryAll`（func）
- `BalanceUnits`：`format`（func）、`parse`（func）、`toYuan`（func）、`unitOf`（func）
- `BgeM3Codec`：`static func parse(body: String): EmbeddingResponse`
- `CallLog`：`info`（func）、`summary`（func）
- `ChannelAccountConf`：`let extra: HashMap<String, String>`、`let from: String`、`let imapHost: String`、`let imapPort: UInt16`、`let password: String`、`let smtpHost: String`、`let smtpPort: UInt16`、`let tls: String`、`let user: String`
- `ChannelBootstrap`：`install`（func）、`installFromConfig`（func）
- `ChannelInstallReport`：`var errors: ArrayList<String> = ArrayList<String>()`、`var installed: Int64 = 0`、`var skipped: Int64 = 0`、`summary`（func）
- `ChannelMediator`：`accounts`（func）、`closeAll`（func）、`create`（func）、`platforms`（func）、`providerPlatforms`（func）、`receive`（func）、`resetAll`（func）
- `ChannelPlatforms`：`isReserved`（func）
- `ChatCompletionsMapper`：`build`（func）、`parse`（func）
- `ChatMessage`：`addImage`（func）、`addText`（func）、`multimodal`（prop）
- `ChatStreamAccumulator`：`feed`（func）、`finished`（prop）、`isDone`（func）
- `CircuitBreaker`：`cleanup`（func）、`isOpen`（func）、`recordRetryableFailure`（func）、`recordSuccess`（func）、`size`（func）
- `ClarifyQuestion`：`let blocking: Bool`、`let defaultValue: String`、`let options: ArrayList<String>`、`let question: String`、`let why: String`
- `Code`：`let code!: String`、`let codeLang!: String`、`let filePath!: String`、`let moduleName!: String`、`let packageName!: String`、`let projectId!: Int64`
- `CodeGen`：`generate`（func）、`hasAsync`（func）、`stepSource`（func）
- `CodeParam`：`let code!: String =`、`let confidence!: Float64 = 0.0`、`let moduleName!: String =`、`let packageName!: String =`、`let projectId!: Int64 = 0`、`let weight!: Float64 = 0.0`
- `ColbertCodec`：`decode`（func）、`encode`（func）
- `ContentPart`：`imageOf`（func）、`textOf`（func）
- `ContextPrunerMediator`：`static let instance = ContextPrunerMediator()`
- `ContextSummaryPruner`：`open class ContextKeywordsPruner <: ContextLLMPruner`
- `DeepSeekBalanceQuerier`：`provider`（prop）
- `DeepSeekDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
- `DeepSeekSearchProvider`：`fetchEndpoint`（prop）、`provider`（prop）、`searchEndpoint`（prop）
- `DefaultEmbedder`：`embedColbert`（func）、`tokenize`（func）
- `DefaultHttpTransport`：`func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse`
- `DefaultLoomHost`：`callLlm`（func）、`callTool`（func）、`render`（func）
- `DeployPaths`：`resolve`（func）、`root`（func）
- `DialectRegistry`：`providers`（func）、`resolve`（func）
- `DummyTokenUsageSaver`：`static let instance = DummyTokenUsageSaver()`、`func saveTokenUsage(usage: TokenUsage): Unit`
- `EdgePlan`：`let from: String`、`let to: String`
- `EmailChannel`：`close`（func）、`receive`（func）
- `Embedding`：`getTransport`（func）、`parse`（func）
- `EmbeddingParam`：`let dimension!: Int64 = 1024`
- `EmbeddingResponse`：`let colbert: Array<Array<Float64>>`、`let dense: Array<Float64>`、`let sparse: HashMap<Int64, Float64>`
- `EvalCase`：`let expected: ArrayList<String>`、`isNegative`（func）、`let topic: String`
- `EvalReport`：`let hitAt1: Int64`、`let hitAtK: Int64`、`let misses: ArrayList<String>`、`mrr`（func）、`ndcg`（func）、`let ndcgSum: Float64`、`let negativePassed: Int64`、`negativeRate`（func）、`let negativeTotal: Int64`、`recallAt1`（func）、`recallAtK`（func）、`let reciprocalSum: Float64`、`render`（func）、`let topics: ArrayList<TopicStat>`、`let total: Int64`
- `EvolutionDecision`：`let reason: String`、`let shouldEvolve: Bool`
- `EvolutionInput`：`let successes: ArrayList<ExperienceItem>`
- `EvolutionLeases`：`byName`（func）
- `EvolutionSkillState`：`lastEvolvedAt`（let）、`lastGatePassed`（let）
- `EvolutionStateStores`：`byName`（func）
- `EvolutionStores`：`byName`（func）
- `ExperienceExtractor`：`func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit): Unit`、`prop systemPrompts: String`、`prop userPrompts: String`
- `FEmailTransport`：`close`（func）、`receive`（func）
- `FStoreEvolutionLease`：`ensure`（func）
- `FStoreEvolutionStateStore`：`lastRunAt`（func）、`markKnowledge`（func）、`markRun`（func）、`save`（func）
- `FStoreEvolutionStore`：`bySkill`（func）、`save`（func）
- `FStoreLoomStore`：`save`（func）
- `FlowPlan`：`var notes: String =`、`round`（var）、`toJson`（func）
- `FunctionCall`：`let function: Function = Function()`、`hashCode`（func）
- `FunctionMediator`：`definition`（func）、`getDefinitions`（func）
- `FunctionMeta`：`let callee: (JsonObject) -> FunctionResult`、`let definition: JsonObject`
- `FunctionResult`：`let eventType!: EventType = EventType.Task`、`let resultType!: ResultType = ResultType.Text`
- `GeneratedFlow`：`let planJson: String`
- `HttpEmbedder`：`embedColbert`（func）、`tokenize`（func）
- `HydraEvolutionLease`：`ensure`（func）、`remote`（func）
- `HydraMemoryRepository`：`colbert`（func）、`searchDense`（func）、`searchSparse`（func）、`upsertColbert`（func）、`upsertSparse`（func）
- `InMemoryEvolutionLease`：`ensure`（func）
- `InMemoryEvolutionStateStore`：`lastRunAt`（func）、`markKnowledge`（func）、`markRun`（func）、`save`（func）
- `InMemoryEvolutionStore`：`bySkill`（func）、`save`（func）
- `InboundAttachment`：`let error: String`、`let filename: String`、`let saved: Bool`、`let size: Int64`
- `InboundMessage`：`let attachments: ArrayList<InboundAttachment>`、`let from: String`、`let receivedAt: String`、`let subject: String`、`let unread: Bool`
- `IndividualityExtractor`：`func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit)`、`prop systemPrompts: String`、`prop userPrompts: String`
- `JitTicktockTask`：`create`（func）
- `Knowledge`：`let codeLang!: String =`、`let embedding!: Array<Float64>`、`let entire!: Bool = false`、`let md5!: String =`
- `KnowledgeChunker`：`split`（func）
- `KnowledgeEntity`：`queryConf`（func）、`func save(knowledgeSaver!: (Knowledge) -> Unit): ArrayList<String>`
- `KnowledgeIndexRebuilder`：`rebuild`（func）、`rebuildAll`（func）
- `KnowledgeParam`：`let embeddingWeight!: Float64 = 0.7`、`let keywords!: String`、`let maxResults!: Int64 = 10`、`let minConfidence!: Float64 = 0.8`
- `KnowledgeSearch`：`occurrences`（func）、`rank`（func）、`terms`（func）
- `LLM`：`getStreamTransport`（func）、`getTransport`（func）
- `LLMCandidateProvider`：`setSupplier`（func）
- `LLMConf`：`prop conf: HashMap<String, String>`、`prop isPlaceholder: Bool`、`option`（func）、`optionBool`（func）、`optionInt`（func）、`setConf`（func）、`prop streamable: Bool`、`prop tokenThreshold: Int64`
- `LLMConfCodec`：`fromColumn`（func）、`toColumn`（func）
- `LLMConfServiceImpl`：`clear`（func）、`findById`（func）、`func listEnabled(): ArrayList<LLMConf>`、`save`（func）
- `LLMConfView`：`let actualLlmName: String`、`let alwaysThinking: Bool`、`let auth: String`、`llmUrl`（let）、`let provider: String`、`let temperature: Float64`、`let weight: Int64`
- `LLMConfig`：`a2aEnabled`（func）、`channelSendRoots`（func）、`channelsJson`（func）、`getBalanceLowThreshold`（func）、`getConfRefreshInterval`（func）、`getConfSource`（func）、`getCooldownDuration`（func）、`getEmbeddingRetries`（func）、`getEmbeddingTimeoutMs`（func）、`getEmbeddingUrl`（func）、`getFailureThreshold`（func）、`static func getFaithfulMemoryPath(): Path`、`getFetchMaxBytes`（func）、`static func getFileSandboxPath(): Path`、`getIndexRebuildNamespace`（func）、`getIndexRebuildUserId`（func）、`static func getLLMAccessTryingCount(): Int64`、`static func getLLMAccessTryingElapsed(): Duration`、`getLoadBalanceAlgo`（func）、`static func getMakingMemory(): Bool`、`getMemoryUserId`（func）、`getPrunerLlmName`（func）、`getStreamIdleTimeout`（func）、`getStreamMaxLineBytes`（func）、`static func getSummarisingActionKind(): String`、`getSummarisingLlmName`（func）、`static func getSummarisingModel(): String`、`getToolResultMaxBytes`（func）、`isAuto`（func）、`isDatabaseEnabled`（func）、`isIndexRebuildEnabled`（func）、`loomOnNoUsable`（func）、`supervisorEnabled`（func）
- `LLMConfs`：`holder`（func）、`isConfigured`（func）、`setHolder`（func）
- `LLMConfsHolder`：`ensureFresh`（func）、`getTokenThreshold`（func）、`isCircuitOpen`（func）、`peekNext`（func）、`recordRetryableFailure`（func）、`recordSuccess`（func）、`refreshNow`（func）、`saturated`（func）
- `LLMConfsSnapshot`：`let byId: HashMap<Int64, LLMConf>`、`let byName: HashMap<String, ArrayList<LLMConf>>`、`let loadedAt: MonoTime`
- `LLMErrorClassifier`：`isFatal`（func）、`isRetryable`（func）
- `LLMHooks`：`let onRetryableFailure: (Int64) -> Unit`、`let onSuccess: (Int64) -> Unit`
- `LLMToolParams`：`func addFunction(function: FunctionCall): Unit`、`addFunctions`（func）
- `LoomA2a`：`defaultCard`（func）、`server`（func）、`startIfEnabled`（func）
- `LoomAgent`：`compile`（func）
- `LoomBootstrap`：`storeFor`（func）
- `LoomCharacterScope`：`install`（func）
- `LoomCompiler`：`compileStep`（func）、`compileSteps`（func）、`jitSourceOf`（func）、`llmSourceOf`（func）、`toolSourceOf`（func）
- `LoomContextLog`：`MAX_TURNS`（let）、`begin`（func）、`clear`（func）、`isActive`（func）、`snapshot`（func）
- `LoomFlow`：`mark`（func）、`var planJson: String =`、`var questionsJson: String =`、`var round: Int64 = 0`
- `LoomHostApi`：`bind`（func）、`callLlm`（func）、`callStore`（func）、`callTool`（func）、`clearPersona`（func）、`clearSkills`（func）、`currentPersonaText`（func）、`currentSkillsText`（func）、`installStore`（func）、`render`（func）、`resetStore`（func）、`setPersona`（func）、`setSkills`（func）、`taskEvent`（func）、`unbind`（func）、`valueOf`（func）
- `LoomJitBridge`：`install`（func）
- `LoomMemoryExtractor`：`extract`（func）
- `LoomMemoryPolicy`：`effective`（func）、`install`（func）
- `LoomProgram`：`stepCount`（prop）
- `LoomRegistry`：`compiledFlows`（func）、`restore`（func）、`size`（func）
- `LoomRequest`：`answers`（let）、`let dryRun: Bool`、`onUnresolved`（let）
- `LoomResult`：`needsClarification`（prop）、`let planJson: String`
- `LoomRunner`：`runCompiled`（func）、`topologicalOrder`（func）
- `LoomSchedules`：`install`（func）
- `LoomServices`：`currentHost`（func）、`install`（func）、`installHost`（func）
- `LoomStatus`：`valid`（func）
- `LoomWiring`：`evolutionOwner`（func）、`lastReload`（func）
- `McpClientAdapter`：`callTool`（func）、`listAllTools`（func）
- `McpFunctionCalling`：`definition`（prop）
- `Memory`：`remember`（func）
- `MemoryExtractor`：`func extract(json: JsonObject, overwriter: (String, String) -> Unit): Unit`、`prop systemPrompts: String`、`prop userPrompts: String`
- `MemoryIndexRebuilder`：`rebuild`（func）、`rebuildIfConfigured`（func）
- `MemoryKinds`：`static let DOC =`、`EXPERIENCE`（let）、`EXPERIENCE_FAILED`（let）、`static let FACT =`、`static let KNOWLEDGE =`、`static let NOTE =`、`static let PREFERENCE =`、`static let SESSION =`、`static let TASK =`、`attach`（func）、`predefined`（func）、`resetForTest`（func）、`seed`（func）、`weightOf`（func）
- `MemoryLoomStore`：`save`（func）
- `MemoryQuery`：`let kinds: Array<String>`、`let namespaces: Array<String>`、`rerank`（let）
- `MemoryRecorderTask`：`recordWithTimeout`（func）
- `MemoryRepositoryAdapter`：`colbert`（func）、`searchDense`（func）、`searchSparse`（func）、`upsertColbert`（func）、`upsertSparse`（func）
- `ModelCapabilities`：`blocksTemperature`（func）、`resolve`（func）
- `ModelNames`：`isFlash`（func）
- `MySqlEvolutionLease`：`ensure`（func）、`ensureSchema`（func）
- `MySqlEvolutionStateStore`：`ensureSchema`（func）、`lastRunAt`（func）、`markKnowledge`（func）、`markRun`（func）、`save`（func）
- `MySqlEvolutionStore`：`bySkill`（func）、`ensureSchema`（func）、`save`（func）
- `MySqlKindPersistence`：`allCustom`（func）、`deleteCustom`（func）、`has`（func）、`insert`（func）、`insertCustom`（func）
- `MySqlLoomStore`：`save`（func）
- `MySqlMemoryRepository`：`colbert`（func）、`searchDense`（func）、`searchSparse`（func）、`upsertColbert`（func）、`upsertSparse`（func）
- `MySqlTokenUsageSaver`：`saveTokenUsage`（func）
- `OptionDto`：`var label: String =`、`var value: String =`
- `OutboundAttachment`：`let filename: String`
- `OutboundMessage`：`let attachments: ArrayList<OutboundAttachment>`、`let html: String`、`let subject: String`、`let to: String`
- `Parameters`：`func addProperty(name!: String, `type`!: String, description!: String): Unit`、`addRequired`（func）
- `PlanDto`：`var assumptions: ArrayList<AssumptionDto> = ArrayList<AssumptionDto>()`、`var notes: String =`、`var round: Int64 = 0`
- `Planner`：`parse`（func）
- `PlannerResult`：`let assumptions: ArrayList<String>`、`isPlanned`（prop）、`let round: Int64`
- `PostgresEvolutionLease`：`ensure`（func）、`ensureSchema`（func）
- `PostgresEvolutionStateStore`：`ensureSchema`（func）、`lastRunAt`（func）、`markKnowledge`（func）、`markRun`（func）、`save`（func）
- `PostgresEvolutionStore`：`bySkill`（func）、`ensureSchema`（func）、`save`（func）
- `PostgresKindPersistence`：`allCustom`（func）、`deleteCustom`（func）、`has`（func）、`insert`（func）、`insertCustom`（func）
- `PostgresLoomStore`：`save`（func）
- `PostgresMemoryRepository`：`colbert`（func）、`searchDense`（func）、`searchSparse`（func）、`upsertColbert`（func）、`upsertSparse`（func）
- `PostgresTokenUsageSaver`：`saveTokenUsage`（func）
- `PredefinedCharacters`：`isKnown`（func）、`static func keys(): ArrayList<String>`
- `PromptCapabilities`：`render`（func）
- `QuestionDto`：`var blocking: Bool = true`、`var defaultValue: String =`、`var options: ArrayList<OptionDto> = ArrayList<OptionDto>()`、`var question: String =`、`var why: String =`
- `ReceivedAttachment`：`let filename: String`、`let read: () -> Array<Byte>`、`let size: Int64`
- `ReceivedMail`：`let attachments: ArrayList<ReceivedAttachment>`、`let from: String`、`let receivedAt: String`、`let subject: String`、`let unread: Bool`
- `Redactor`：`defaultKeys`（func）、`mask`（func）、`redactJson`（func）
- `ReloadResult`：`var restored: Int64 = 0`、`toString`（func）
- `ResponseFormat`：`static let json: ResponseFormat = ResponseFormat(             )`
- `ResponsesMapper`：`build`（func）、`parse`（func）
- `ResponsesStreamAccumulator`：`feed`（func）、`finished`（prop）、`isDone`（func）
- `RetrievalEval`：`defaultDir`（func）、`evaluate`（func）、`readCases`（func）、`readCorpus`（func）
- `RetrievalEvalRunner`：`loadCorpus`（func）、`titleToId`（func）
- `RetrievalScoring`：`LEXICAL_CAP`（let）、`LEXICAL_WEIGHT`（let）、`MEMORY_DENSE_WEIGHT`（let）、`MEMORY_SPARSE_WEIGHT`（let）、`RERANK_CONTENT_WEIGHT`（let）、`RERANK_TITLE_WEIGHT`（let）、`fuseKnowledge`（func）、`fuseMemory`（func）、`rerank`（func）
- `SendReceipt`：`let error: String`、`let messageId: String`、`let ok: Bool`、`success`（func）
- `SignUtil`：`hmacSha256`（func）、`hmacSha256Hex`（func）、`sha256Hex`（func）、`utcDate`（func）、`utcDateTime`（func）
- `SiliconFlowBalanceQuerier`：`prop provider: String`
- `SiliconFlowDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
- `Skill`：`prop functionNames: Iterator<String>`
- `SkillAssignment`：`let experiences: ArrayList<ExperienceItem>`
- `SkillCandidate`：`let experiences: ArrayList<ExperienceItem>`
- `SkillCatalog`：`install`（func）、`isVectorized`（func）
- `SkillEvolutionJob`：`installSink`（func）、`ownedBy`（func）、`resetSink`（func）
- `SkillEvolutionLedger`：`write`（func）
- `SkillEvolutionPolicy`：`let cooldownSeconds: Int64`、`decide`（func）、`let failedCooldownSeconds: Int64`、`let minSamples: Int64`、`let minSuccessRate: Float64`
- `SkillEvolutionReport`：`let candidateClusters: Int64`、`let evolved: ArrayList<String>`、`materials`（let）、`let rejected: ArrayList<String>`、`let skipped: ArrayList<String>`
- `SkillEvolutionTask`：`evolve`（func）
- `SkillGate`：`evaluate`（func）
- `SkillGateResult`：`let newScore: Float64`、`let oldScore: Float64`、`let passed: Bool`、`let reason: String`
- `SkillImporter`：`importInto`（func）、`parse`（func）
- `SkillMatchResult`：`assignedCount`（prop）、`let assignments: ArrayList<SkillAssignment>`
- `SkillMatcher`：`assign`（func）
- `SkillNamer`：`propose`（func）
- `SkillReferenceParam`：`var reference: ArrayList<String> = ArrayList<String>()`
- `SkillSample`：`let expect: String`
- `SkillSamples`：`of`（func）
- `Specification`：`let codeLang!: String =`、`let projectId!: Int64`
- `SsrfGuard`：`blocked`（func）、`check`（func）、`hostOf`（func）
- `StandardDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
- `StepDto`：`var external: Bool = false`
- `StepPlan`：`var external: Bool = false`、`func toJson(): String`
- `StoreSettings`：`let contentStoreUrl: String`、`deprecated`（let）、`memoryStore`（let）、`let metaStore: String`、`let metaStorePath: String`
- `Stores`：`containsContent`（func）、`containsMeta`（func）、`resetForTest`（func）
- `Supervisor`：`eventName`（func）、`install`（func）、`tap`（func）、`untap`（func）
- `SupervisorAgent`：`map`（func）
- `TencentCloudBalanceQuerier`：`provider`（prop）
- `TencentSigner`：`headers`（func）
- `TextClip`：`clip`（func）
- `ThinkingPolicy`：`apply`（func）
- `TicktockScheduler`：`cancel`（func）
- `TimeUuid`：`create`（func）、`dayOf`（func）、`timestampOf`（func）
- `Todo`：`predecessor`（func）
- `TodoFunction`：`func addTodo(param: TodoSavingParam): FunctionResult`、`func todoList(param: TodoListParam): FunctionResult`、`func updateStatus(param: TodoStatusParam): FunctionResult`
- `ToolCallMessage`：`func addFunctionCall(id!: String, toolType!: ToolType, name!: String, arguments!: String)`、`addToolCall`（func）
- `ToolCatalog`：`entries`（func）
- `ToolScope`：`check`（func）、`verifyPlan`（func）
- `TopicStat`：`let hitAt1: Int64`、`let hitAtK: Int64`、`mrr`（func）、`ndcg`（func）、`let ndcgSum: Float64`、`recallAt1`（func）、`recallAtK`（func）、`let reciprocalSum: Float64`、`let topic: String`、`let total: Int64`
- `VectorMath`：`cosine`（func）
- `VolcSigner`：`headers`（func）
- `VolcengineBalanceQuerier`：`provider`（prop）
- `VolcengineDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
- `ZhipuBalanceQuerier`：`prop provider: String`
- `ZhipuDialect`：`decorate`（func）、`endpoint`（func）、`headers`（func）、`prop provider: String`
