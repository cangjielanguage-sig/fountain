# f_llm

仓颉（Cangjie）大模型工程库，属于 [fountain](../) 仓库。提供六块能力：

| 能力 | 入口 |
|---|---|
| 大模型访问（多平台、多候选、熔断、流式） | `fountain::f_llm.llm.LLM` |
| 存储（内容族 / 元数据族 / 演进族） | `fountain::f_llm.store.Stores` |
| 记忆、知识、技能、人格、提示词 | `MemoryStore` / `KnowledgeStore` / `MetaStore` |
| loom 编排（文本 → 流程 → 执行） | `fountain::f_llm.loom.LoomWiring` |
| 流程路由（一段描述 → 选中并执行流程） | `fountain::f_llm.loom.Supervisor` |
| 技能演进（经验 → 技能，带 A/B 门禁） | `fountain::f_llm.loom.SkillEvolutionJob` |
| 检索质量评测 | `fountain::f_llm.loom.RetrievalEvalRunner` |

- 版本：`1.3.17`，`output-type = "dynamic"`
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
| 显式 | `LoomRunner().run(plan, host, start, skills: ['日报助手'])` | 按标题加载，顺序固定 |
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
