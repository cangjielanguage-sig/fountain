# fountain实现思想与应用第十六弹

##### ——大模型接入与工具闭环

项目链接：https://gitcode.com/Cangjie-TPC/fountain

调用大模型的代码通常长这样：拼一个 HTTP 请求，把 `messages` 和 `model` 塞进去，拿回 `choices[0].message.content`。这段代码能跑通 demo，但上线前会撞上四类问题：

> 同一逻辑模型有多个平台，挂了怎么切？
> 流式返回的 `usage` 缺失，账单怎么算？
> 让模型调工具，谁来执行、谁来防它调内网？
> 对话历史、人格、技能、记忆存在哪？

f_llm 的规模就是被这四个问题撑起来的。它不是一个 HTTP 客户端，而是「**模型访问 + 工具闭环 + 存储接线 + 可编排流程**」四层：

```
┌──────────────────────────────────────────────────────┐
│ loom 编排：Planner → CodeGen → LoomCompiler → Runner │
├──────────────────────────────────────────────────────┤
│ tool：FunctionCalling / FunctionMediator / ToolLoop  │
│       内置工具 + MCP 适配 + SsrfGuard / 沙箱          │
├──────────────────────────────────────────────────────┤
│ llm：LLM 门面 / 候选与熔断 / 方言 / 报文映射 / 流式    │
├──────────────────────────────────────────────────────┤
│ store：ContentStore / MetaStore / Memory / Knowledge │
└──────────────────────────────────────────────────────┘
```

---

## 一、门面：全静态，候选列表，失败转移

`LLM` 是一个全静态类，没有实例——这让调用方不必管理生命周期，也让「配置快照」可以整体替换：

```cj
public class LLM {
    public static func chat(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp
    public static func chatByName(llmName: String, params: LLMParams): LLMResp
    public static func chatStream(candidates: ArrayList<LLMConf>, params: LLMParams,
                                  onDelta: (LLMDelta) -> Unit): LLMResp
    public static func setTransport / setStreamTransport   // 测试注入点
}
```

`chatByName` 的选号流程值得单独说：

1. `LLMConfs.holder().candidates(llmName)` 取出该逻辑名下的全部候选；
2. 按权重挑一个起点（`peekNext`），把**未熔断**的候选追加进列表；
3. 列表为空直接抛 `LLMException('no available llm conf for: …, available: …')`；
4. 调用成功 `recordSuccess(id)`，可重试失败 `recordRetryableFailure(id)`。

也就是说，「同一逻辑模型的多平台」不是配置层面的概念，而是调用层面的候选列表。`weight` 只影响起点，不影响可用性；`weight <= 0` 等同于停用。

### 错误分类：4xx 立即死，5xx 才换人

```cj
public static func isRetryable(status: Int64): Bool {
    match (status) {
        case 408 | 409 | 425 | 429 => true
        case _ => status >= 500
    }
}
```

门面的处理是：传输异常 → 记可重试失败并 `continue`；`status >= 400` 且可重试 → 换候选；**其余 4xx 立即抛出**。

这条规则的注释写得很直白：换平台也一样错，只会让第一个错误被第二个盖住。参数错了就是参数错了，重试只是把排查线索弄丢。

熔断器（`CircuitBreaker`）与这条规则配套：只统计可重试失败，连续失败达到 `llm_failureThreshold`（默认 5）后进入冷却，`llm_cooldownSeconds`（默认 60）到期自动复位。**状态只在内存**，重启清零；配置刷新时会按存活 id 清理已删除的条目。

还有一个容易误读的配置：`llm_accessTryingCount` / `llm_accessTryingElapsed` 默认都是 `Int64.Max`，看起来像门面的重试次数，实际只在 `agents/AgentTask.cj` 里使用，退避方式是斐波那契（`a, b = b, a+b`）。门面自身不做次数重试，只做候选转移。

### 流式：能读，但不能取消

`chatStream` 底层是 SSE：`DefaultStreamTransport` 按行读，`onData` 回调把增量交给 `ChatStreamAccumulator`。累加器负责三件事：

- 识别 `[DONE]`；
- 正文、`reasoning_content`/`reasoning`、`tool_calls` 按 `index` 累加；
- 上游不给 `usage` 时，按 `字符数 / 3` 估算并置 `usageEstimated = true`。

「估算要标注」是这一层唯一不能省的诚实：token 计数无法精确时 `TokenCounter` 直接返回 `-1`，不猜数；流式估算出来的值会带标记，账单侧能区分「上报的」与「猜的」。

流式没有取消原语。`src/llm` 里没有 `cancel`/`abort`，只能靠 `llm_streamIdleTimeout`（默认 120 秒）自然超时。这是当前实现的硬边界，不是使用姿势问题。

另有一个安全取舍需要写在明面上：两个默认传输都设了 `tls.verifyMode = TrustAll`。代码没有解释原因，但后果是**证书校验被关闭**；对公网端点，这需要调用方自己权衡。

---

## 二、方言：五个内置 + 一个兜底

所有内置方言都走 OpenAI 兼容路线，差别集中在三处：端点路径、思考字段、是否支持 Responses API。

| 方言 | 思考字段处理 | `/responses` |
| --- | --- | --- |
| `StandardDialect`（`openai`，未知 provider 的兜底） | 不处理 | 支持 |
| `DeepSeekDialect` | 删 `thinking` 与 `enable_thinking` | 支持 |
| `ZhipuDialect` | `thinking: {type: enabled/disabled}` | 抛 `IllegalArgumentException` |
| `VolcengineDialect` | 同上 | 抛错 |
| `AliyunDialect` | 剥 `thinking`，用布尔 `enable_thinking` | 抛错 |
| `SiliconFlowDialect` | 两个字段都剥 | 抛错 |

没有 Gemini、Anthropic、Ollama 的专用实现——全仓搜不到这些名字。要接只能当 OpenAI 兼容端点走 `StandardDialect`。

方言之上还有一层「模型能力」：

```cj
public static func resolve(conf: LLMConf): ThinkingMode   // none | always | toggle
public static func blocksTemperature(conf): Bool          // always -> true
```

`ThinkingPolicy.apply` 在 `dialect.decorate` **之后**执行：`always` 删掉 `temperature`（带思考的模型通常不接受自定义温度），`none` 删思考字段并对 `alwaysThinking=true` 记一条 warn。

模型名归一（`ModelNames`）只用于能力判断与日志；**报文里的 `model` 永远是 `conf.actualLlmName`**。这条约束避免了「归一化悄悄改了用户想调的模型」这类事故。

---

## 三、报文映射：把差异关在一个文件里

`ChatCompletionsMapper.build` 的规则不多，但每条都有明确原因：

| 规则 | 原因 |
| --- | --- |
| `model = conf.actualLlmName` | 逻辑名不进报文 |
| `conf.temperature >= 0` 优先，负值用 `params.temperature`，仍为负则删字段 | 「不传」与「传 0」是两种语义 |
| 非流式删 `stream` | 有的平台对 `stream: false` 也会走 SSE |
| `response_format.type != 'json_object'` 直接删 | 只支持 JSON 模式，不发送半吊子的格式声明 |
| `tools` 为空不写 | 空数组会被某些平台判定为「要工具但没定义」 |
| 多模态 `parts` → `content` 数组 | 纯文本保持字符串，减少兼容面 |

解析侧只取 `choices[0]`，把 `finish_reason`、`tool_calls`、`reasoning_content`、`usage.prompt_tokens/completion_tokens/total_tokens/prompt_tokens_details.cached_tokens` 映射回 `LLMResp`。上游多给的字段一概忽略——**不做「尽力解析」**，因为静默接受未知结构，等于把协议漂移藏起来。

---

## 四、工具闭环：默认不循环

工具调用的核心不是 `FunctionCalling` 接口，而是「谁来跑这个循环」。`LLMToolLoop` 的选择是：**默认关闭**。

```cj
public static func run(candidates: ArrayList<LLMConf>, params: LLMToolParams,
                       enabled!: Bool = false, maxRounds!: Int64 = 8): LLMResp {
    if (!enabled || maxRounds <= 0) { return LLM.chat(candidates, params) }
    // 每轮：LLM.chat -> 取 tool_calls -> 串行执行 -> 结果回填 -> 再调
    last.finishReason = 'rounds_exceeded'
}
```

三个事实必须记住：

1. **不传 `enabled: true` 就不会循环**。理由是「框架不应偷偷多跑几轮打乱计费与日志」。
2. **硬上限 8 轮**；用尽不是异常，保留最后一轮内容并把 `finishReason` 置为 `rounds_exceeded`。
3. **工具串行执行**。`for (call in calls)` 一个一个调，没有并行；单个工具抛异常只把结果写成 `[工具调用失败] <name>: <e>`，不中断循环。

函数注册在 `FunctionMediator`：`register` 先校验名字再查重，重名抛 `FunctionCallingException`；`ensureLoaded()` 扫 `BeanFactory` 里的 `@Bean`，成功项先落临时表、扫描结束后再合并进正式表（避免中途失败留下「半张表」），单个 bean 构造失败只 warn 跳过——**一个工具坏掉，不能让整张工具表不可用**。但名字冲突是硬错误，会直接抛 `FunctionCallingException`。

### 内置工具

模型看到的是工具名，不是类名：

| 工具名 | 功能 | 关键约束 |
| --- | --- | --- |
| `readFile` / `writeFile` / `replaceFile` | 文件读写替换 | 路径必须落在 `llm_fileSandboxPath` 内 |
| `command` | 执行命令 | 只把 cwd 设为沙箱；**不校验命令内容、无超时** |
| `console` | 控制台读写 | 用于交互式宿主 |
| `webSearch` | 借任一可用 `LLMConf` 凭据调搜索 provider | 显式 provider 不跨平台回退；结果按 `llm_toolResultMaxBytes` 截断 |
| `webFetch` | 抓取网页正文 | 先过 `SsrfGuard`，再按 `llm_fetchMaxBytes` 截断 |
| `loadSkills` / `loadSkillReferences` | 按标题取技能正文/引用 | 返回 `ResultType.Skill` / `SkillReference` |
| `loadMemories` | 查经验/教训/个性摘要 | 返回 `ResultType.MemorySummary` |
| `answer` | 结构化回答 | 供编排层识别终止 |
| `currentTime` | 当前时间 | 避免模型猜日期 |
| `addTodo` / `todoList` / `updateTodoStatus` | 待办增/查/改 | **没有删除接口** |

### 安全边界：三件套，各有各的边界

**`SsrfGuard`** 只做字面量校验：

```cj
if (!lower.startsWith('http://') && !lower.startsWith('https://')) throw …
if (host.isEmpty()) throw …
if (blocked(host)) throw 'url points to a private or local address'
// blocked: localhost / ::1 / fc* / fd* / fe80* / 纯数字主机名
// IPv4: 0. / 10. / 127. / 172.16-31 / 192.168. / 169.254. / 100.64-127
```

代码自己承认没有覆盖 DNS rebinding：建连前应该用解析后的 IP 再校验一次。这不是「已经安全」，而是「挡住了最常见的误用」。

**文件沙箱**只做路径拼接：拒绝 `../` 前缀，Windows 下拒绝绝对路径，非 Windows 下把绝对路径去掉首个 `/` 后 join 沙箱根。它能防手滑，防不了符号链接。

**`Redactor`** 用「前 4 + `****` + 后 4」掩码，长度 ≤ 8 整体替换；默认敏感键是 `auth/authorization/apiKey/api_key/token/secret/password`。实际使用点只有 `CallLogger` 里的 `Redactor.mask(conf.auth)`——**没有全链路脱敏**，日志里其它位置出现密钥不会被自动处理。

---

## 五、MCP：适配层在这里，传输在 f_mcp

f_llm 的 `mcp` 包只有一层适配：

```cj
public interface McpToolClient {
    func listAllTools(): Array<McpToolDescriptor>
    func callTool(name: String, arguments: JsonObject): CallToolResult
}
// McpClientAdapter 包装 f_mcp 的 McpClient（package fountain::f_mcp.client）
// McpToolSource.load(): listAllTools -> FunctionMediator.register
```

三条规则：

- **命名**：`mcp__{alias}__{tool}`，总长上限 64 且不截断；非法字符或超长直接注册失败。
- **Schema 清洗**：剥除以 `$` 开头的键（`$schema`/`$ref`/`$defs`），`type` 为数组时取第一个非空且非 `null` 的字符串；`additionalProperties` 保留。
- **错误**：MCP 返回 `isError` 时，文本前缀 `[MCP 错误] `，`event` 固定为 `mcp_result`。

传输在隔壁 `f_mcp`：`McpClient.stdio(command, args, options)` 与 HTTP 两条路线都走 `f_jsonrpc.JsonRpcClient`；默认 `timeout = 30s`、`maxRounds = 8`、`maxResponseBytes = 8 MiB`、`keepAlive = true`。**f_llm 里没有生产代码自动接线 MCP server**：构造 `McpClient` 再 `load()` 是宿主的责任，loom 计划里的 `mcps` 只是白名单字段。

---

## 六、存储：三族，一次接线，永不热更新

存储不是「一个数据库」，而是按用途分三族：

| 族 | 存什么 | 实现（`llm_memoryStore` / `llm_metaStore`） |
| --- | --- | --- |
| 内容族 | 记忆、经验、知识、切块 | `inMemory` / `postgres` / `mysql` / `f_hydra`（默认） |
| 元数据族 | 人格、技能、提示词、模型配置 | `postgres` / `mysql` / `f_store`（默认） |
| 演进族 | 演进报告、状态、已消费知识、每日租约 | 报告跟随元数据族；租约跟随内容族 |

`StoreWiring.wire()` 在启动时做三件事：幂等注册实现 → `Stores.bootstrap()` 校验配置值 → 给 SQL 实现补种预定义记忆种类。未知配置值**启动失败并打印可选列表**，不静默回退。

这套接线有一个硬约束：**永不支持运行期改配置**。原因有三层——`@Bean` 的条件只评估一次、`wire()` 只执行一次、holder 的首次使用会定死实现。换存储或换实现必须重启。注意区分：`llm_confRefreshSeconds` 刷新的是**模型配置快照**（数据库/文件里的 `LLMConf` 行），不是环境变量。

模型配置的来源还有一条隐式优先级：`LLMConfs.createHolder()` 先看 `llm_metaStore` 是否属于 `f_store`/`postgres`/`mysql`，是则一律从元数据存储读，失败才回退 `llm_confSource`。这解释了一个常见现象：明明配了 `llm_confSource=env`，日志却显示 `source: store`。

向量化走 OpenAI 兼容的 `/v1/embeddings`（默认 `http://127.0.0.1:8000/v1/embeddings`），BGE-M3 三路编码在 `BgeM3Transport`/`BgeM3Codec`；知识检索按块召回，索引可在启动时用 `llm_rebuildIndexOnStart` 重建。

---

## 七、loom：把一句话变成可执行流程

loom 是 f_llm 里最「应用层」的部分，但它的阶段划分很清晰：

```
自然语言描述
→ Planner（产出 JSON 计划，或返回澄清问题）
→ CodeGen（计划 → 步骤源码 + 流程源码，不编译）
→ LoomRegistry / LoomStore（存源码与状态）
→ LoomCompiler（编译步骤闭包）
→ LoomRunner（按拓扑序执行）
```

状态机只有三个状态：`clarifying → pending → compiled`。编译失败保持 `pending`，源码仍可读、可改；单条流程失败不影响其它流程。

步骤类型有四种：`tool`（调已注册工具）、`mcp`（调 MCP 工具）、`llm`（调模型）、`jit`（任意仓颉片段，需产出 `let <id>_result = …`）。`http` 是保留 kind，`plan.validate()` 会明确拒绝，不会被当成 `llm` 静默执行。

流程内可用三个 JIT 入口：`loomCallTool(name, argsJson)`、`loomCallLlm(model, system, input)`、`loomStore(kind, op, payload)`。`kind` 覆盖 `memory`/`experience`/`knowledge`/`skill`/`prompt`/`character`/`evolution` 七类，`payload` 都是 JSON 字符串。

这套编排能力最终以工具形式暴露给模型：`loomExecute`（生成/编译/执行）、`loomDelete`、`memoryCall`、`knowledgeIngest`、`loomStoreCall`、`listTools`/`searchTools`、`skillImport`、`scheduleCreate`/`scheduleDelete`。

---

## 八、配置：默认值都在代码里

### 模型访问

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `llm_confSource` | `database` | 只认 `database` / `env` / `file:<path>` |
| `llm_confs` | 空 | `env` 源必填，JSON 数组 |
| `llm_confRefreshSeconds` | 60 | 配置快照刷新（懒式 TTL） |
| `llm_loadBalanceAlgo` | `randomWeight` | 或 `roundRobin` |
| `llm_failureThreshold` | 5 | 熔断阈值 |
| `llm_cooldownSeconds` | 60 | 熔断冷却 |
| `llm_accessTryingCount` | `Int64.Max` | 仅 `AgentTask` 用 |
| `llm_accessTryingElapsed` | `Int64.Max` | 仅 `AgentTask` 用 |
| `llm_streamIdleTimeout` | 120s | 流式空闲超时 |
| `llm_streamMaxLineBytes` | 1 MiB | SSE 单行上限 |
| `llm_toolResultMaxBytes` | 64 KiB | 工具结果截断 |
| `llm_fetchMaxBytes` | 256 KiB | 网页正文截断 |
| `llm_prunerLlmName` | `chat-pro` | 上下文裁剪用模型 |
| `llm_summarisingLlmName` | `chat-pro` | 摘要用模型 |
| `llm_balanceLowThreshold` | 100 | 余额告警线 |
| `llm_supervisor` / `llm_loomOnNoUsable` | false | 编排相关开关 |
| `llm_a2aEnabled` | false | 对外暴露可执行入口，慎重 |

### 存储与向量

| 键 | 默认 |
| --- | --- |
| `llm_memoryStore` | `f_hydra` |
| `llm_metaStore` | `f_store` |
| `llm_metaStorePath` | `./data/f_llm-meta` |
| `llm_hydraPath` | `./data/f_hydra` |
| `llm_hydraUrl` | `http://127.0.0.1:18081/rpc` |
| `llm_hydraSecret` | 空（未配置时抛 `IllegalStateException`） |
| `llm_embeddingUrl` | `http://127.0.0.1:8000/v1/embeddings` |
| `llm_embeddingTimeoutMs` / `llm_embeddingRetries` | 3000 / 2 |
| `llm_rebuildIndexOnStart` | false |
| `llm_fileSandboxPath` | 未设则工作目录 |

已废弃、只 warn 不生效的键：`llm_contentStore`、`llm_memoryBackend`、`llm_characterBackend`、`llm_memoryPath`。

---

## 九、设计取舍与已知限制

1. **失败转移优先于重试**。4xx（除 408/409/425/429）立即抛，5xx 换候选。重试只对「换个平台可能好」的错误有意义。
2. **熔断不持久化**。重启清零，刷新时按存活 id 清理。监控系统要的是「当下可用」，不是「历史故障率」。
3. **工具循环默认关闭**。开启后串行、最多 8 轮、轮次用尽不算异常。并行工具执行是下一步，不是现状。
4. **`command` 工具不是沙箱**。它只限制 cwd，命令内容不校验、无超时。给不可信模型开放这个工具，等于开放 shell。
5. **`SsrfGuard` 不是 SSRF 的完整解**。字面量校验挡不住 DNS rebinding，建连前需要二次校验。
6. **文件沙箱防手滑不防链接**。路径前缀拼接对符号链接无效。
7. **TLS 校验关闭**。两个默认传输都是 `TrustAll`；接入公网端点前必须替换 transport 或接受风险。
8. **无取消原语**。流式只能等空闲超时；长回答占住连接时没有「停止」按钮。
9. **存储接线只做一次**。换实现必须重启，`@Bean` 条件不会重新评估。
10. **两套默认值容易混**。`store/Stores.cj` 里还留着 `DEFAULT_CONTENT='postgres'`/`DEFAULT_META='postgres'`，但真正生效的是 `StoreSettings` 的 `f_hydra`/`f_store`——不要照抄前者的常量。
