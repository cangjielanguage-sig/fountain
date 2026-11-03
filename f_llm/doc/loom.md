# loom：文本 → 流程编排

设计见 `f_llm-memory-design.md` §9；本文只记**当前实现状态**与使用方式。

## 链路

```
自然语言描述
  → Planner（LLM 产出 JSON 计划，或返回澄清问题）
  → CodeGen（计划 → 步骤源码 + 流程源码，不编译）
  → LoomRegistry / LoomStore（存源码与状态，llm_loom_flow）
  → LoomCompiler（编译步骤闭包）
  → LoomRunner（拓扑序执行，结果事件）
```

## 状态机

`clarifying → pending → compiled`，编译失败标 `failed`（单条失败不影响其它流程）。

| 状态 | 含义 |
|---|---|
| `clarifying` | Planner 判定描述有歧义，已存问题，未生成源码 |
| `pending` | 已生成源码，未编译（`loomExecute(confirm=false)` 的结果） |
| `compiled` | 步骤闭包编译成功，可执行 |
| `failed` | 启动重编译失败，需人工修 |

## 工具

| 工具 | 关键参数 | 行为 |
|---|---|---|
| `loomExecute` | `name, description, tools?, mcps?, persona?, confirm?, execute?, parallel?` | `confirm=false` 返回计划与闭包原文；`confirm=true` 编译标 compiled；`execute=true` 顺带跑一次 |
| `loomDelete` | `name` | 从注册表与库中移除 |
| `memoryCall` | `op`(search/add/remove) + `payload` JSON | 读写长期记忆，与 `loomStore("memory", …)` 同一条网关 |
| `knowledgeIngest` | `docId, title, content` | 写入知识库，可用 `knowledge.search` 检索 |
| `listTools` | `offset, limit` | 列出已注册工具（名称 + 描述） |
| `searchTools` | `query, topK` | 关键词检索工具：名称命中 3 分、描述命中 1 分 |
| `skillImport` | `path` | 导入技能包目录（`skill.json` + `details.md`），同名 title 幂等 |
| `scheduleCreate` | `name, cron, payload?` | 注册（或替换同名）定时任务，到点执行同名 loom 流程 |
| `scheduleDelete` | `name` | 取消定时任务 |

工具元数据直接取自 `FunctionMediator.definition(name)`，不另建索引——「注册了什么」与「能检索到什么」永远一致。

## 能力清单（编排提示词自动附带）

模型不知道宿主有什么，就会虚构工具名，或把本该自动查的事写成澄清问题。因此 `Planner` 在拼 system prompt 时**无条件追加** `PromptCapabilities.render()`：

```
可用能力（运行期按需调用，禁止虚构不存在的工具名）：
- loomCallTool(name, argsJson)：调用已注册的 tool_call 或 MCP 工具
- loomCallLlm(model, system, input)：调用大模型
- loomStore(kind, op, payload)：kind = memory | knowledge | skill；op = search | add | upsert | remove | docIds | count
已注册工具：[memoryCall, listTools, …]
步骤需要事实时，优先排一个调用上述能力的步骤去查，不要先问用户。
```

| 规则 | 说明 |
|---|---|
| 自定义提示词也追加 | 开发者传的 system 原样保留，清单接在末尾 |
| 默认全量 | 取 `FunctionMediator.names()`（含 MCP 注册进来的工具） |
| 可收窄 | 任务描述给 `tools` 白名单时只列这些 |
| 动态 | 运行时新注册的工具，下一次规划即可见 |

## 定时任务

`f_ticktock` 的 cron 是**七段式**：`秒 分 时 天 月 星期 年`，通配符只支持 `*`。

```cangjie
// 方式一：到点执行一整条流程（payload 写进 StartEvent.data）
ScheduleCreateFunction().call(createParam(
    '{"name":"daily","cron":"0 0 9 * * * *","payload":"{\\"range\\":\\"today\\"}"}'))
// 到点 → LoomService.executeNow(name, host, StartEvent(..., data: payload))

// 方式二：只跑某一步（JIT 闭包包成 () -> Unit）
JitTicktockTask.create('sync-job', '0 0 9 * * * *', step, scheduler, payload: 'hello')
```

| 约定 | 原因 |
|---|---|
| 定时任务执行**完整流程**，不是单步 | `Ticktock` 任务体是 `() -> Unit`，无事件进出；单步调度要么假事件、要么套迷你 Flow，等于一步流程 |
| `JitTicktockTask` 丢弃返回值 | 成果由**副作用**（写库、发消息、落产物）体现，没人消费返回值 |
| 异常全吞 | 抛到调度线程会中断后续 tick |
| `{start.output}` | 取**进入当前步骤的事件**的 `data`；第一步即 payload，后续步骤等价于上一步输出 |

## 后台任务与超时

| 能力 | 入口 | 说明 |
|---|---|---|
| 记忆记录 | `MemoryRecorderTask.record(gateway, userId, ns, title, text)` | 写一条记忆，返回 id；`recordWithTimeout` 加超时保护 |
| 技能演进 | `SkillEvolutionTask.evolve(chat, store, title, usage)` | 现有正文 + 近期使用 → 模型合并 → 版本 +1 |
| 超时包装 | `LoomTimeout.call({ => … }, 3000)` | 正常返回结果、超时返回 `timeout after Nms`、异常返回 `error: …` |

`LoomTimeout` 的语义是「**调用方按时返回**」：Cangjie 无法强杀线程，被调用方会在后台自行结束；对流程来说足够——这一步记为失败，不会挂死整条流程。

## 装配

宿主在 `StoreWiring.wire()` 之后调用一次：

```cangjie
LoomWiring.wire({ model, system, user => /* 调 LLM；model 为空串时用默认模型 */ },
                plannerModel: 'chat-pro')
```

- 存储按 `llm_metaStore` 选（与 `MetaStore` 共用）：`f_store`（默认）/ `memory` / `postgres` / `mysql`，未知取值直接抛错；
- `LoomWiring.wire` 内部会 `restore()` 并重编译 `compiled` 流程，并安装 `DefaultLoomHost` 与存储网关；
- 测试可传 `store:` 注入内存实现，避免占用默认数据目录；
- 工具调用通过 `LoomServices.current()` 取服务实例。

## 临时上下文与记忆提炼

流程执行期每次通过 `loomCallLlm` 与大模型交互，都会往 `LoomContextLog` 记一条：

```cangjie
LlmTurn(model, system, input, output)
```

记录的生命周期严格绑在一次执行上：

```
LoomRunner.runCompiled
  ├─ begin()                 清空并激活
  ├─ … 步骤执行，每次 callLlm 追加一条 …
  └─ finally
       ├─ snapshot()         取快照
       ├─ clear()            关闭记录（提炼阶段的模型请求不会被记进来）
       ├─ unbind()
       └─ LoomMemoryExtractor.extract(plan.name, turns, host, policy)
```

提炼结果写两条记忆，都走 `memory.add`：

| 标题 | kind | 内容 |
|---|---|---|
| `流程 <name> 记忆` | `note` | 各轮 system/input/output 的摘要（默认取最近 `maxTurns` 轮） |
| `流程 <name> 经验` | `experience` | 交互次数 + 最后一次输出摘要 |

策略由 `LoomMemoryPolicy` 控制：

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 关闭后连临时上下文都不记 |
| `userId` / `namespace` | `0` / `loom` | 记忆归属 |
| `maxTurns` | `20` | 摘要只取最近 N 轮，防止长流程把记忆撑爆 |
| `summarize` | `false` | `true` 时让模型读摘要并返回 `{"memory":"…","experience":"…"}` |
| `model` | `''` | `summarize=true` 时必填，走 `host.callLlm` |

装配：

```cangjie
LoomWiring.wire(chat, plannerModel: 'chat-pro',
                memoryPolicy: LoomMemoryPolicy(userId: 7, namespace: 'work',
                                               summarize: true, model: 'deepseek-flash'))
```

两条兜底：**模型返回的 JSON 解析失败**时回落到规则提炼；**存储未装配或写失败**时不影响流程结果（提炼失败被吞掉，流程照常返回）。

## 执行语义

`LoomRunner` 用 `ImmediateFlow` 组装：每个步骤是一个 `QueuedClosureTask`，结果按计划的边改写事件名并回灌派发器。

| 场景 | 行为 |
|---|---|
| 单后继 | 结果事件名改写为后继步骤 id |
| 分叉（出度 > 1） | 返回 `MultiEvent`（name 必须是 `EventType.Multi.toString()`），由 `registerMultiEventTask` 注册的 Multi 执行器逐条 emit |
| 汇聚（入度 > 1） | `JoinBarrier` 计数，所有前驱事件到齐才执行一次；未到齐的事件返回 `DummyEvent` 被派发循环跳过 |
| 汇合数据 | 取**最后到达**的那条事件的数据（不做多路合并） |
| 收尾 | 出度为 0 的步骤返回 `End` 事件（name = `EventType.End.toString()`） |

**并发开关（三级可控）**

| 层级 | 入口 | 说明 |
|---|---|---|
| 开发者（代码） | `LoomRunner.run(..., parallel: true)` | 直接指定本轮执行是否并发 |
| 开发者（装配） | `LoomService.executeNow(..., parallel: true)` | 单次执行覆盖计划里的值 |
| 模型（计划） | 计划 JSON 的 `"parallel": true`，或 `loomExecute` 的 `parallel:"true"` | 请求级开关会并入计划，模型也可自行决定 |
| 重启恢复 | `LoomBootstrap.startup` + `LoomService.executeNow` | 重编译后按计划里的 `parallel` 值执行，不需要再传参 |

生效规则：`计划.parallel || 调用方 parallel`。并发走 `AsyncFlow`（分叉分支并行），同步走 `ImmediateFlow`。

其它约定：

- 流程级没有走 JIT：`CodeGen.flowSource` 只作预览/落库原文；
- 所有步骤都由 f_jit 编译：`jit` 编译整段语句，`tool`/`mcp` 编译成 `loomCallTool(...)`，`llm` 编译成 `loomCallLlm(...)`；模板替换（`{step.output}`）与事件包装留在原生侧；
- `http` 步骤**尚未实现**，`validate()` 会直接拒绝，不会被当成 `llm` 静默执行；
- 模板 `{stepId.output}` 由 `LoomHostApi` 的跨步骤输出表替换，未命中的占位符原样保留；
- 每次执行用 `loom/{name}#{seq}` 作为流程 tag，执行完 `flow.remove()` 释放派发器——否则重复执行同一计划会撞上 `StartExecutor has already been registered`。

## 存储

流程定义存**源码与状态**，不存编译产物（`JitFunction` 不可序列化），启动时重新编译。

### 四种实现，与 MetaStore 共用 `llm_metaStore`

| 取值 | 实现 | 位置 |
|---|---|---|
| `f_store`（默认，不指定也是它） | `FStoreLoomStore` | `llm_metaStorePath`（相对部署目录） |
| `memory` / `inMemory` | `MemoryLoomStore` | 进程内，重启即失 |
| `postgres` | `PostgresLoomStore` | `llm_loom_flow` 表 |
| `mysql` | `MySqlLoomStore` | `llm_loom_flow` 表 |

选哪个由 `LoomBootstrap.storeFor(llm_metaStore)` 决定；未知取值直接抛错并列出可用值，不静默兜底。

### 内存层 + 持久化层

`LoomRegistry` 内存里有一份 `HashMap<String, LoomFlow>`（`Mutex` 保护），`put`/`remove` **双写** store；`restore()` 启动时按 100 条分页把库里的流程拉回内存。

### SQL 版（`llm_loom_flow`）

| 列 | 说明 |
|---|---|
| `name` PK | 流程标识 |
| `plan_json` / `flow_source` / `step_sources` | 计划与源码 |
| `status` / `round` / `questions_json` | 状态机与澄清 |
| `tools` / `mcps` | 白名单（逗号分隔） |
| `created_time` / `update_time` | upsert 时刷新 |

- 写：PG `ON CONFLICT (name) DO UPDATE`，MySQL `ON DUPLICATE KEY UPDATE`；
- 读：`WHERE name = ?`；`list` 按 `name` 排序分页（PG `LIMIT ? OFFSET ?`，MySQL `LIMIT ?, ?`）；
- 删：先查存在再 `DELETE`，返回真实 `Bool`。

`step_sources` **不用 JSON**：`id\u0001source` 以 `\u0002` 分隔。源码里全是引号与换行，用 JSON 要完整转义/反转义（历史上被转义 bug 咬过），控制字符在仓颉源码里不会出现，比 JSON 更省事且无损。

### `loomStore` 网关（`LoomStoreGateway`）

`loomStore(kind, op, payload)` 是 JIT 步骤访问记忆/知识/技能的入口，装配时由 `LoomWiring` 自动安装。

| kind | op | payload | 返回 |
|---|---|---|---|
| `knowledge` | `docIds` | `{"offset":0,"limit":50}` | JSON 字符串数组 |
| `knowledge` | `upsert` | `{"docId":"d1","title":"t","content":"…"}` | `ok` |
| `knowledge` | `remove` | `{"docId":"d1"}` | `true/false` |
| `knowledge` | `search` | `{"text":"cangjie","limit":5}` | `[{docId,seq,score,content}]` |
| `memory` | `search` | `{"userId":1,"namespace":"n","text":"…","topK":5}` | `[{id,title,score}]` |
| `memory` | `add` | `{"userId":1,"namespace":"n","title":"t","content":"c","kind":"fact"}` | 记录 id |
| `memory` | `remove` | `{"userId":1,"id":2}` | `true/false` |
| `skill` | `count` | `{}` | 整数 |
| `skill` | `get` / `list` | `{"id":3}` / `{}` | 技能 JSON / 数组 |
| `skill` | `upsert` | `{"id"?, "title","details","functions","version"?}` | 技能 id |
| `skill` | `remove` | `{"id":3}` | `true/false` |
| `memory` | `get` / `list` | `{"userId","id"}` / `{"userId","namespace","offset","limit"}` | 记录 / 数组 |
| `experience` | 同 `memory` | 同上，`kind` 缺省 `experience` | 同上 |
| `prompt` | `latest` / `get` | `{"name"}` / `{"name","version"}` | `{name,version,content}`，未命中 `''` |
| `prompt` | `put` | `{"name","content","version"?}` | 版本号（缺省自动 +1） |
| `prompt` | `remove` | `{"name","version"}` | `true/false` |
| `character` | `get` | `{"userId":1}` | `{userId,characterKey,prompts}`，未命中 `''` |
| `character` | `set` / `reset` | `{"userId","characterKey","prompts"}` / `{"userId"}` | `ok` |

未列出的 op 一律抛错，不静默返回空值。

### f_store 版（键布局）

按字段拆键，进一步绕开拼接与转义：

```
f_llm:loom:index:{name}      → 空值，仅用于列举
f_llm:loom:data:{name}:h     → status \u0003 round \u0003 tools \u0003 mcps
f_llm:loom:data:{name}:d     → description
f_llm:loom:data:{name}:p     → planJson
f_llm:loom:data:{name}:f     → flowSource
f_llm:loom:data:{name}:q     → questionsJson
f_llm:loom:data:{name}:s     → stepSources（同上编码）
```

`remove` 扫描 `f_llm:loom:data:{name}:` 前缀清空全部字段，再删索引键。

### 状态与恢复

| 状态 | 含义 |
|---|---|
| `clarifying` | Planner 判定有歧义，存问题、无源码 |
| `pending` | 已生成源码，未编译 |
| `compiled` | 编译通过，可执行 |
| `failed` | 启动重编译失败，需人工修 |

`LoomBootstrap.startup` 只重编译 `compiled` 的流程；单条失败标 `failed`，不影响其它。

### 已知边界

| 项 | 说明 |
|---|---|
| 无并发控制 | 后写覆盖先写，没有版本号/乐观锁（loom 写入频率极低） |
| 无历史版本 | 只保留最新源码，改坏了靠重新规划 |
| `remove` 非原子 | 先查后删；库侧删除本身幂等 |
| 名称即主键 | 没有租户/命名空间，多租户需在 `name` 里加前缀 |
| DDL 注释有 `blocked` | 注释列 5 个状态，代码只用 4 个 |

## 已知边界

| 项 | 说明 |
|---|---|
| 并行执行 | 目前用 `ImmediateFlow` 同步派发（分叉按顺序 emit，不并行）；要真并行需换 `AsyncFlow` |
| 汇聚数据 | 汇合步骤只拿最后到达的那条数据，不做多路合并 |
| 汇聚计数 | `JoinBarrier` 计数在单次执行内有效；执行结束不复位（流程不重入） |
| `confirm` 后自动执行 | 需要显式调用 `LoomService.executeNow`，`loomExecute` 不自动执行 |
| 真实宿主 | `DefaultLoomHost` 的工具通道接 `FunctionMediator`，模型通道由装配方注入；没有内置 LLM 客户端 |
| `step_sources` 编码 | 存 `id\u0001source`、`\u0002` 分隔（不是 JSON）：避免源码引号/换行的转义问题 |
