# fountain实现思想与应用第十六弹

##### ——大模型接入、工具闭环与记忆存储

项目链接：https://gitcode.com/Cangjie-TPC/fountain

调用大模型的代码通常长这样：拼一个 HTTP 请求，把 `messages` 和 `model` 塞进去，拿回 `choices[0].message.content`。这段代码能跑通 demo，但上线前会撞上六类问题：

> 同一逻辑模型有多个平台，挂了怎么切？
> 流式返回的 `usage` 缺失，账单怎么算？
> 让模型调工具，参数 schema 从哪来、谁执行、谁防它调内网？
> 对话越来越长，超上下文之前怎么裁？
> 记忆、知识、向量存在哪，换数据库要改多少代码？
> 怎么把能力开放给别的智能体，或者调用别人的智能体？

f_llm 的规模就是被这六个问题撑起来的。它不是一个 HTTP 客户端，而是「**模型访问 + 工具闭环 + 上下文治理 + 持久化存储 + MCP/A2A + 可编排流程**」六层：

```
┌──────────────────────────────────────────────────────────────┐
│ loom：Planner → CodeGen → LoomCompiler → Runner → A2A 出口   │
├──────────────────────────────────────────────────────────────┤
│ tool：FunctionCalling / FunctionMediator / ToolLoop          │
│       内置工具 + MCP 适配 + SsrfGuard / 沙箱                  │
│ llm ：门面 / 候选与熔断 / 方言 / 报文 / 流式 / 上下文裁剪      │
├──────────────────────────────────────────────────────────────┤
│ store：f_store / postgres / mysql / f_hydra / fhydra          │
│        memory + knowledge + 三路向量（dense/sparse/colbert）  │
└──────────────────────────────────────────────────────────────┘
```

---

## 一、门面：全静态，候选列表，失败转移

`LLM` 是一个全静态类，没有实例——调用方不必管理生命周期，配置快照也可以整体替换：

```cj
public class LLM {
    public static func chat(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp
    public static func chatByName(llmName: String, params: LLMParams): LLMResp
    public static func chatStream(candidates: ArrayList<LLMConf>, params: LLMParams,
                                  onDelta: (LLMDelta) -> Unit): LLMResp
    public static func setTransport / setStreamTransport   // 测试注入点
}
```

`chatByName` 的选号流程：取该逻辑名下的全部候选 → 按权重挑起点（`peekNext`）→ 追加**未熔断**候选 → 空列表抛 `no available llm conf for: …, available: …` → 成功 `recordSuccess(id)`，可重试失败 `recordRetryableFailure(id)`。

「同一逻辑模型的多平台」不是配置层面的概念，而是调用层面的候选列表。`weight` 只影响起点，不影响可用性；`weight <= 0` 等同于停用。

### 错误分类：4xx 立即死，5xx 才换人

```cj
public static func isRetryable(status: Int64): Bool {
    match (status) {
        case 408 | 409 | 425 | 429 => true
        case _ => status >= 500
    }
}
```

门面的处理是：传输异常 → 记可重试失败并 `continue`；`status >= 400` 且可重试 → 换候选；**其余 4xx 立即抛出**。理由很直白：换平台也一样错，只会让第一个错误被第二个盖住。

熔断器（`CircuitBreaker`）只统计可重试失败：连续失败达到 `llm_failureThreshold`（默认 5）进入冷却，`llm_cooldownSeconds`（默认 60）到期自动复位；**状态只在内存**，重启清零。

`llm_accessTryingCount` / `llm_accessTryingElapsed` 默认都是 `Int64.Max`，但只在 `agents/AgentTask.cj` 里使用（斐波那契退避），门面自身不做次数重试。

### 流式：能读，但不能取消

`chatStream` 底层是 SSE：按行读，`onData` 把增量交给 `ChatStreamAccumulator`。累加器负责识别 `[DONE]`、按 `index` 归并正文/思考/`tool_calls`，以及在上游不给 `usage` 时按 `字符数 / 3` 估算并置 `usageEstimated = true`。

流式没有取消原语。`src/llm` 里没有 `cancel`/`abort`，只能靠 `llm_streamIdleTimeout`（默认 120 秒）自然超时。

两个默认传输都设了 `tls.verifyMode = TrustAll`——证书校验被关闭，接公网端点前需要自己权衡。

---

## 二、方言与报文：把平台差异关进两个文件

所有内置方言都走 OpenAI 兼容路线，差别集中在端点路径、思考字段、是否支持 Responses API：

| 方言 | 思考字段处理 | `/responses` |
| --- | --- | --- |
| `StandardDialect`（`openai`，未知 provider 的兜底） | 不处理 | 支持 |
| `DeepSeekDialect` | 删 `thinking` 与 `enable_thinking` | 支持 |
| `ZhipuDialect` / `VolcengineDialect` | `thinking: {type: enabled/disabled}` | 抛 `IllegalArgumentException` |
| `AliyunDialect` | 剥 `thinking`，用布尔 `enable_thinking` | 抛错 |
| `SiliconFlowDialect` | 两个字段都剥 | 抛错 |

没有 Gemini、Anthropic、Ollama 的专用实现；要接只能当 OpenAI 兼容端点走 `StandardDialect`。

`ThinkingPolicy.apply` 在 `dialect.decorate` **之后**执行：`always` 删 `temperature`，`none` 删思考字段并对 `alwaysThinking=true` 记 warn。模型名归一（`ModelNames`）只用于能力判断与日志，**报文里的 `model` 永远是 `conf.actualLlmName`**。

`ChatCompletionsMapper.build` 的规则不多，但每条都有原因：

| 规则 | 原因 |
| --- | --- |
| `model = conf.actualLlmName` | 逻辑名不进报文 |
| `conf.temperature >= 0` 优先，负值用 `params.temperature`，仍为负则删字段 | 「不传」与「传 0」是两种语义 |
| 非流式删 `stream` | 有的平台对 `stream: false` 也会走 SSE |
| `response_format.type != 'json_object'` 直接删 | 只支持 JSON 模式，不发半吊子的格式声明 |
| `tools` 为空不写 | 空数组会被某些平台判定为「要工具但没定义」 |
| 多模态 `parts` → `content` 数组 | 纯文本保持字符串，减少兼容面 |

解析侧只取 `choices[0]`，上游多给的字段一概忽略——**不做「尽力解析」**，因为静默接受未知结构等于把协议漂移藏起来。

---

## 三、tool-call：请求、回填与 JSON Schema

### 3.1 请求侧：没有 `tool_choice`

工具定义来自 `LLMToolParams.functions`（`HashSet<FunctionCall>`），每个元素形如：

```json
{"type": "function",
 "function": {"name": "...", "description": "...", "parameters": { /* JSON Schema */ }}}
```

`ChatCompletionsMapper` 只在集合非空时写 `tools` 字段；**全仓没有 `tool_choice`**，也没有对应参数。这不是遗漏，而是当前实现只支持「让模型自己决定是否调用」。

### 3.2 响应侧：一个 `ToolCallMessage` 装下所有调用

模型返回的 `tool_calls` 被原样映射：

```cj
toolMessage.addFunctionCall(
    id: stringOf(call, 'id'),
    toolType: stringOf(call, 'type', 'function'),
    name: stringOf(function, 'name'),
    arguments: stringOf(function, 'arguments'))   // 保留原始 JSON 字符串，不解析
```

三个细节：

- 同一个响应里的多个 `tool_calls` **全部进同一个 `ToolCallMessage`**，顺序即数组顺序；
- `arguments` 是未解析字符串，非法 JSON 直到执行时才暴露；
- 有 `tool_calls` 就构造 `ToolCallMessage`，否则才是 `AssistantMessage`，两者互斥。

流式由 `ChatStreamAccumulator` 按 `index` 归并 fragment，最后合成同样的结构。

### 3.3 回填：两条路径，一条循环一条单轮

`LLMToolLoop` 默认**关闭**：

```cj
public static func run(candidates, params: LLMToolParams,
                       enabled!: Bool = false, maxRounds!: Int64 = 8): LLMResp {
    if (!enabled || maxRounds <= 0) { return LLM.chat(candidates, params) }
    // 每轮：LLM.chat → 收集 tool_calls → assistant 原样回显 → 每个 call 追加一条 ToolMessage
    last.finishReason = 'rounds_exceeded'
}
```

- 硬上限 8 轮；用尽不是异常，保留最后一轮内容并把 `finishReason` 置为 `rounds_exceeded`；
- 工具**串行**执行；`arguments` 解析失败退化成空 `JsonObject`；工具抛异常只写成 `[工具调用失败] <name>: <e>`；
- `ToolMessage` 没有 `name` 字段，只有 `tool_call_id` 与 `content`。

生产路径 `AgentTask` 是**单轮**：拿到 `ToolCallMessage` 后回显，逐 call 执行并把结果写回；它还会往参数里注入 `session`/`event` 等上下文。`resultType` 决定回执文案：`Skill` → `[技能已加载]`、`SkillReference` → `[技能参考已加载]`、`MemorySummary` → `[记忆已加载]`。

### 3.4 函数注册：注解、宏、反射三条路

```cj
public class FunctionCalling<T> where T <: ObjectData<T> {   // 必须是 class + @Bean
    prop definition: JsonObject { get() {
        // {type:"function", function:{name, description, parameters: JsonObject.toJsonSchema<T>()}}
    }}
    func call(params: T): FunctionResult        // 默认抛 "default implementation"
    func call(json: JsonObject): FunctionResult // populate(json.toData()) 后调上面的重载
}
```

- `@FunctionDefinition[name, description]`：标在成员函数上，`FunctionDefinition.register<C,P>` 反射取注解，再注册 `WrappedFunctionCalling<P>`；
- `@ToolCall` 宏：遍历类的 **public 非静态函数**，要求**恰好一个参数**，为每个函数生成 `FunctionDefinition.register`，并给类补 `@Bean`；`@WeavedToolCall` = `@ToolCall + @Pointcut`。

`FunctionMediator` 负责注册表：`register` 先 `ToolName.validate` 再查重，重名抛 `FunctionCallingException`；`ensureLoaded()` 扫 `@Bean`，成功项先落临时表、扫描结束后合并，单个 bean 失败只 warn。`loaded` 一旦置 true 不再重扫——运行期新增的 `@Bean` 工具只能靠显式 `register` 进来。

工具名规则：最长 64，只允许 `A-Z a-z 0-9 _ -`；**超长/非法直接失败，不截断**（截断 + hash 会让日志里的名字与真实工具名对不上）。MCP 工具名是 `mcp__{alias}__{tool}`。

### 3.5 JSON Schema 的实现原理

`FunctionCalling.definition` 里的 `parameters` 来自 `f_data` 的 `JsonObject.toJsonSchema<T>()`（`f_data/src/json/JsonSchema.cj`）。它不是「根据类型猜 schema」，而是**反射字段表 + 注解补语义**：

1. 取 `TypeInfo`，先调用静态 `dataFields()`（`@DataAssist[fields]` 生成）；取不到再调 `mutableFields()`（`@Bean` 生成）；两者都没有就得到空 `properties`。
2. 每个字段递归 `toJsonSchema(fieldTypeInfo, annotation)`，注解是字段上的 `@JsonXxxSchema`。
3. 顶层 `required` **只来自** `@JsonObjectSchema[required: '["a","b"]']`；框架不会把「非 Option 字段」自动标成必填。
4. `description` **只来自注解**（`@JsonStringSchema[description: …]` 等），不读文档注释。
5. `Option<T>` 生成内层 schema 加 `"nullable": true`，不会自动从 `required` 里移除字段。

类型映射：

| Cangjie 类型 | schema |
| --- | --- |
| `Bool` | `boolean` |
| `Int8/16/32/64`、`UInt*` | `integer` |
| `Float16/32/64` | `number` |
| `String` | `string`（可带 `minLength`/`maxLength`/`pattern`/`format`） |
| `Option<T>` | 内层 schema + `nullable: true` |
| `Array`/`ArrayList`/`List`/`Set`/`HashSet`/`TreeSet<…>` | `array` |
| 其它（嵌套 class、枚举、`HashMap`、`Unit`） | 一律当 `object` |

限制必须写在明面上：

- **没有 `$ref`、没有递归检测、没有缓存**，自引用类会一直递归到栈溢出；
- Cangjie `enum` 不会反射成 `enum` 值，只能靠 `@JsonStringSchema[enumeration: '["a","b"]']` 手写；
- `items` 只由 `@JsonArraySchema` 触发：注解给了 `items` 就按泛型实参递归，没给但字段类型是 class 就用字段类型本身；没有这个注解的数组字段完全没有 `items`；
- 泛型靠字符串切 `<…>`，多类型参数（如 `HashMap<String, Int64>`）不可靠；
- 失败方式基本是**静默降级**（字段发现不到 → 空 properties，未知类型 → object），只有泛型名缺 `<` 时会抛异常。

MCP 工具还要多一步 `sanitizeSchema`：剥掉所有 `$` 开头的键（`$schema`/`$ref`/`$defs`），`type` 是联合类型数组时取第一个非 `null` 的值，`additionalProperties` 保留。原因是模型供应商对这些字段支持参差，留着只会换来 400。

### 3.6 内置工具与安全边界

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

安全边界三件套，各有各的边界：

- **`SsrfGuard`** 只做字面量校验：协议必须是 http(s)；拒绝 `localhost`、`::1`、`fc*`/`fd*`/`fe80*`、纯数字主机名、`10.`/`127.`/`172.16-31`/`192.168.`/`169.254.`/`100.64-127`。代码自己承认没覆盖 DNS rebinding。
- **文件沙箱**只做路径拼接：拒绝 `../` 前缀，Windows 下拒绝绝对路径，非 Windows 下把绝对路径去掉首个 `/` 后 join 沙箱根。能防手滑，防不了符号链接。
- **`Redactor`** 用「前 4 + `****` + 后 4」掩码，默认敏感键是 `auth/authorization/apiKey/api_key/token/secret/password`；实际只在 `CallLogger` 里对 `conf.auth` 用过一次——**没有全链路脱敏**。

---

## 四、上下文压缩与裁剪

### 4.1 接口与注册表：默认只有一个可用

```cj
public interface ContextPruner {
    prop name: String
    func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}
```

`ContextPrunerMediator` 在首次使用时扫描 `@Bean`，`agent.pruner` 是选择键（来自 `agents` 表的 `pruner` 列）。**未知名字直接抛 `IllegalArgumentException`，空串也一样**——没有默认回退到 `Retain`。

而全仓**只有 `RetainContextPruner` 带 `@Bean`**；`LastN_2`、`Summary_BY_*` 这些名字默认不在注册表里，必须宿主显式 `register`。这是阅读文档时最容易误解的一点：策略类存在 ≠ 策略可用。

### 4.2 九个实现的真实语义

| `name` | 行为 |
| --- | --- |
| `Retain` | 原样返回 |
| `LastN_{n}` | 保留最近 **n 轮 = 2n 条**；`n=0` 返回空列表 |
| `Summary_BY_{llmType}_{model}` | 把整段上下文交给模型总结，**只留下 1 条 user 消息** |
| `Keywords_BY_{llmType}_{model}` | 同上，但提示词是「提取关键词，逗号分隔」 |
| `DRC_{system.name}_{others.name}` | 按 `role == system` 分两堆，分别交给两个子裁剪器后拼接 |
| `Saturation_{inner.name}` | 只有 `conf.tokenThreshold > 0` 且启发式计数达到阈值才调用内层，否则原样返回 |
| `TokenBudget_{budget}` | 从尾部往前累加 `estimateTokens(content)+4`，超预算即停，但至少保留最后一条；默认 4000 |
| `RetainLastUser_{inner.name}` | 先裁剪，再把「原列表最后一条 user」补回（可能造成连续两条 user） |
| `RetainLastRound_{inner.name}` | 取尾部 `size - 2n` 起的所有消息；`n` 不在名字里，不同 `n` 会撞名，列表短于 `2n` 还会越界 |

`Summary`/`Keywords` 不是「压缩成摘要消息 + 保留最近若干条」，而是**用一条 user 消息替换全部历史**；`DRC` 也不是「动态相关度」，只是 system/others 分流。这两处 README 的说法与代码不一致。

### 4.3 触发时机与 token 计数

裁剪发生在 `AgentTask` 组装完 messages + tools 之后、发 LLM 之前，**每个事件一次**：

```cj
params.messages = ContextPrunerMediator.instance.prune(
    agent.pruner, agentId: agent.id, session: e.session, messages: params.messages)
```

`LLM.chat*` 自身不做任何裁剪；没有「每轮自动判断阈值」的逻辑，除非把策略包成 `Saturation_*`。

token 计数有两个实现，但生产只用启发式：

- `HeuristicTokenCounter`：`Σ (content 字节数 / 3 + 4)`，中文约 3 字节/token；不算 role、工具定义、图片、reasoning。
- `RemoteTokenCounter`：读 `conf['tokenizerUrl']` POST 文本，未配置返回 `-1`；**生产路径无调用点**。

裁剪调用本身的 token 消耗会通过 `TokenUsageSaver` 记一笔，但没有填 `agentId`/`session`——账单里只能靠 `llm_id` 区分「裁剪开销」与「会话开销」。

---

## 五、MCP 与 A2A：一个对内接工具，一个对外暴露入口

### 5.1 MCP：完整 SDK 在 f_mcp，接入在 f_llm

`f_mcp` 同时实现客户端与服务端，协议版本 `2026-07-28`：

| 项 | 事实 |
| --- | --- |
| 端点 | HTTP `POST /mcp`；SSE `GET /mcp/sse` |
| 方法 | `server/discover`、`tools/list`、`tools/call`、`resources/list`、`resources/read`、`prompts/list`、`prompts/get`、`subscriptions/listen` |
| 无握手 | `initialize` / `notifications/initialized` 被显式注册为「拒绝」，返回 `-32601` 并附 `supportedVersion` |
| 版本 | 每个请求在 `params._meta` 带协议版本与 clientInfo；`MCP-Protocol-Version` 头不一致返回 `-32022`/`-32602` |
| 传输 | stdio 一行一个 JSON-RPC；HTTP 复用 `f_jsonrpc`，默认 `timeout=30s`、`maxRounds=8`（`input_required` 自动多轮上限）、`maxResponseBytes=8 MiB`、`keepAlive=true` |
| 分页 | `base64("offset:N")`，页大小 100；`listAllTools` 上限 100 页 / 1000 个工具 |
| 大结果 | 超 `tool.maxResultBytes`（默认 1 MiB）：配了 `mcp_publicBaseUrl` 就外链到 `/mcp/tool-results/…`，否则 UTF-8 安全截断并标 `truncated` |

服务端有两种装配方式：`McpServer.builder().tool(...).build()`，或 `@Mcp['kb-server']` + `@McpToolMeta/@McpResourceMeta/@McpPromptMeta`（宏在模块加载期注册）。HTTP 落地靠宿主应用加载 `McpController`，**f_mcp 自己不 listen 端口**。

f_llm 侧只有一层适配（`src/mcp/McpToolSource.cj`）：

```cj
let n = McpToolSource('fs', McpClientAdapter(client)).load()   // 注册 mcp__fs__read_file…
```

- 命名 `mcp__{alias}__{tool}`，非法字符先替换 `_`，再整体校验（超 64 直接失败）；
- schema 走 `sanitizeSchema`；
- 调用结果：`isError` → `[MCP 错误] <text>`，`event` 固定 `mcp_result`；非 text 块（image/resource）会被丢弃。

**f_llm 没有生产代码自动接线 MCP server**：`McpToolSource(...).load()` 只在测试与演示里被调用。宿主必须在启动时建客户端、装载一次，否则模型的工具列表里不会出现任何 MCP 工具；loom 计划里的 `mcps` 只是提示词字段，不做强制校验，`kind='mcp'` 的步骤最终也走 `FunctionMediator.call`——工具没注册就跑不通。

### 5.2 A2A：把 Supervisor 暴露成智能体

A2A 由独立模块 `f_a2a` 实现（model + server + client），f_llm 在 `loom` 里搭了一座桥：

```cj
// LoomWiring.wire(): 默认关闭，开启时幂等注册一次
let _ = LoomA2a.startIfEnabled()
```

`llm_a2aEnabled` 默认 false，注释的理由是「开启等于对外暴露一个可执行入口，不该在升级后悄悄生效」。

暴露的不是工具，而是 9 个 JSON-RPC 方法：`a2a.message.send`、`a2a.tasks.get`、`a2a.tasks.cancel`、`a2a.message.stream`、`a2a.tasks.resubscribe`、`a2a.agent.extendedCard`、`a2a.pushConfig.set/get/delete`。方法名带 `a2a.` 前缀，与规范里的 `message/send` 不同。

`A2aServer` 的要点：

- 任务状态：`submitted`/`working`/`completed`/`failed`/`canceled`/`input-required`；代码**直接置 `working`**，从不写 `submitted`；
- `send` 调 `A2aExecutor.execute(task, message)`（同步），结果映射：`completed`（带 artifact）/`input-required`/`failed`；
- `cancel` 只拒终态，`input-required` **可以**被取消；
- executor 抛异常 → 任务 `failed`，不是协议错误；
- `-32024`（TASK_REJECTED）与 `-32022`（UNSUPPORTED）在 f_a2a 内**从未抛出**，只是常量；
- 任务存储返回副本，避免「取消后再读」读到中间态；推送回调失败只 warn。

Agent Card 只提供序列化，**不自动挂 `/.well-known/agent.json`**，也**没有 `skills` 列表**——客户端无法从 Card 发现有哪些 loom 流程。

loom 桥把 `Supervisor.dispatch(prompt)` 包成 executor：

| Supervisor 结果 | A2A 结果 |
| --- | --- |
| `DISPATCHED` / `CREATED` | `completed` |
| `CLARIFYING` | `input-required` |
| 其它（含无可用流程） | `failed` |

「无可用流程」映射成 `failed` 而不是协议拒绝，是为了让客户端理解成「这次没办成」，换说法重试更自然。

**A2A 本身没有鉴权**，依赖宿主 `f_mvc` 拦截器；`register()` 也不设超时。反方向的调用有三层：协议层 `A2aClient`（`send/get/cancel/close`，不含 stream/resubscribe/pushConfig）、便捷层 `LoomA2aClient().ask(url, text)`、流程内工具 `a2aCall{url, text}`。`a2aCall` 与 `memoryCall` 一样依赖宿主 bean 装配，仓库里没有生产注册点。

---

## 六、存储：三族、五种内容后端

### 6.1 三族与合法取值

| 族 | 存什么 | 配置键 | 合法值 |
| --- | --- | --- | --- |
| 内容族 | 记忆、经验、知识、切块、向量 | `llm_memoryStore` | `inMemory` / `postgres` / `mysql` / `f_hydra`（默认）/ `fhydra` |
| 元数据族 | 人格、技能、提示词、模型配置 | `llm_metaStore` | `f_store`（默认）/ `postgres` / `mysql` |
| 演进族 | 演进报告、状态、已消费知识、每日租约 | 跟随上面两族 | 报告跟元数据族，租约跟内容族 |

注意 `f_store` **不是** `llm_memoryStore` 的合法值：它是 `f_hydra` 的底层存储引擎，同时是 `llm_metaStore` 的默认实现。

`f_hydra` 与 `fhydra` **不是别名**：

- `f_hydra` = 进程内向量库（依赖 `f_hydra` 动态库），数据目录 `llm_hydraPath`，默认 `./data/f_hydra`；
- `fhydra` = 远程服务，走 `llm_hydraUrl`（默认 `http://127.0.0.1:18081/rpc`）+ `llm_hydraSecret`。

两者的 `MemoryStore` 都是 `SqlMemoryStore` + `HydraMemoryRepository`，只把传输层换成 `InProcessTransport` 或 `HttpTransport`——不是两套检索代码。

未知值**启动失败并打印可选列表**，不静默回退；`StoreWiring.wire()` 只做一次，换实现必须重启。

### 6.2 f_store：是 LSM-Tree，不是简单 KV 文件

`f_store` 的目录里有 `wal/` 与 `sst/`：MemTable 是 `ConcurrentSkipListMap`，超过 8MB flush 成 SSTable；SSTable 由 Data Block + Index + **Bloom Filter（FPR 0.01）** + Footer 组成，点查先用 Bloom 否定再二分。

持久化上，`add` 先 `WAL.append` 再写 MemTable，但 **WAL 默认每 100 次 append 才 fsync 一次**；显式落盘只有 `syncWAL()`/`close()`。没有事务、没有 rename 原子写。

`Store` 只提供 `get/add/remove/prefix`，**没有二级索引**。f_llm 的元数据实现靠「把查询条件编码进 key」来模拟索引，因此 `list()` 类操作是 O(该前缀下键数)；「主体 + 索引」两阶段写崩溃会缺索引，靠启动 `repair()` 自愈。

`llm_metaStorePath` 相对**可执行文件目录**解析（在 `bin/` 下取上一级），不是 CWD。

### 6.3 PostgreSQL / MySQL：向量列与三路存储

| 通路 | PostgreSQL（pgvector ≥ 0.7） | MySQL（8.0+；VECTOR 需 9.2+） |
| --- | --- | --- |
| dense | `llm_memory_vector.title_dense/content_dense vector(1024)` + HNSW `vector_cosine_ops` | `llm_memory.title_vec/content_vec`，`MYVECTOR`/`myvector_construct` |
| sparse | `llm_memory_token(memory_id, user_id, namespace, field, token, weight)` | 同结构 |
| colbert | `title_colbert/content_colbert BYTEA`（`count + count×1024×f32`） | `LONGBLOB`，同格式 |

检索 SQL 的差异：

- PG dense 用 `1 - (title_dense <=> q::vector)` 打分、`ORDER BY <=>` 排序，`namespace` 用占位符过滤；
- PG sparse 用 `SUM(weight)` 分组排序；
- MySQL 的 ANN 是 `MYVECTOR_IS_ANN(路径, 主键, 向量, limit, 过滤子查询)`，组件不认占位符，**过滤条件必须内联并放在第 5 个参数**，否则隔离条件会失效；
- MySQL 知识切块用 `MYVECTOR(type=HNSW,dim=1024,dist=COSINE,…)`。

两个必须知道的现状：

1. **dense 检索只用标题向量**：PG 查 `v.title_dense`、MySQL 查 `title_vec`；`content_dense`/`content_vec` 会写入、也建了索引，但检索路径没用到。
2. **MySQL 的 DDL 与 DAO 存在偏差**：DAO 读写 `llm_memory.title_vec/content_vec`，而 `tables-mysql.sql` 的 `llm_memory` 没有这两列（向量列建在 `llm_memory_vector`）。接入 MySQL 前要按实际 DAO 核对表结构，不能直接照搬 DDL。

### 6.4 f_hydra：进程内向量库

`f_hydra` 依赖 `f_store`，把向量拆成多类键：

```
h:{c}:d:{id}          payload
v:d:{id}              dense
v:s                   sparse（文本）
v:c:{id}:{p}          colbert 分片（≤64KB）
i:t:{tok}:{id}        倒排
f:{field}:{value}:{id} 过滤索引
m:ivf / m:cent:{i} / i:c:{i}:{id} / i:r:{id}   IVF 索引
m:ttl                 TTL 元数据
r:{id}                ready 标记
```

写入顺序是 payload → dense → sparse → colbert → 倒排 → **ready**；读路径先校验 ready，未就绪的半成品对查询不可见，`recover()` 清半成品。这是没有事务时的「两阶段提交」。

检索是**暴力扫 + 可选 IVF**，明确不实现 HNSW：先用 IVF 候选，候选不足或未建索引就全量扫描（IVF 是优化，不牺牲召回）；colbert 只对一级候选做 max-sim。过滤白名单 `hydra_filterFields`（默认 `kind,save_day,tags`）变更会触发全量倒排重建。

### 6.5 fhydra：远程服务

`fhydra` 是自带 `main` 的可执行程序，`MVCStarter` 起 HTTP 服务，只有 `POST /rpc` 与 `/rpc/hydra` 两个 JSON-RPC 端点，**没有 REST 接口**。

方法表（namespace `hydra`）：`health`（免鉴权）、`upsert`、`upsertBatch`（≤100）、`get`、`remove`、`searchDense`、`searchSparse`、`count`、`ids`、`rerank`、`buildIndex`、`indexClusters`、`export`、`recover`、`setTtl`、`ttl`、`purgeExpired`。

- 鉴权：除 `health` 外的请求都要带 `X-Hydra-Key`，与 `hydra_secret` 严格相等；**未配置 secret 时这些请求全部被拒**；
- 数据目录 `hydra_dataPath`（默认 `./data/fhydra`）；
- 向量字段优先用 `denseB64`（f32 小端 Base64），`dense` 数组是兼容路径；
- 并发：多请求线程共享一个 `FStoreVectorStore`，自身无锁，依赖 f_store 的无锁读与 WAL 串行 append。

f_llm 的 `HttpTransport` 走 `HttpClient` 的默认超时，没有单独的配置项；`llm_hydraSecret` 为空时**任何调用直接抛** `IllegalStateException`。

### 6.6 记忆与知识的检索算法

记忆检索是两路融合：

```
dense  = 1 - cosine(标题向量)          // 只用标题
sparse = Σ 命中 token 权重
score  = 0.7 × minmax(dense) + 0.3 × minmax(sparse)
hit    = score × kindWeight(kind)      // fact/preference 1.0、note 0.9、doc 0.8、task 0.6、session 0.3
```

- 两路各取 `topK × 2` 后做 min-max 归一化；sparse 为空时 `degraded=true`；
- `userId` 必须相等，`namespaces`/`kinds` 非空才过滤；
- `rerank=true` 时对融合分最高的前 `topK×4`（至少 20）个候选做 colbert max-sim，**只改顺序，不改 score**；
- `(user_id, namespace, title)` 唯一：同空间同标题是覆盖写并返回既有 id。

知识检索：切块默认 `400` 字符、重叠 `50`（按 rune 滑窗），`score = cosine + 0.1 × min(命中次数, 5)`，同分按 `docId/seq` 升序保证跨后端稳定；没有 `Embedder` 时退化为纯词面。

f_hydra 路径有两处语义差异：`namespaces` 为空时**返回空结果**（SQL 实现是「不过滤」）；知识分数是 `cosine + 0.1 × 原始 sparse 分`，没有 `min(…,5)` 封顶。

写入语义也分三级：dense 失败直接拒绝整条记录；sparse 失败抛异常；colbert 失败被吞掉——只损失重排能力，不影响写入。

---

## 七、BGE-M3：一次请求，三路输出

生产实现是 `DefaultEmbedder` → `HttpEmbedder` → `BgeM3Transport`：

```text
POST /v1/embeddings
{"input":["<text>"],"return_sparse":true,"return_colbert_vecs":true}
```

- **不带 `model`、不做批量**：永远单条、单元素数组；
- 响应解析：`data[0].embedding` → dense；`data[0].lexical_weights` → `HashMap<tokenId, weight>`；`data[0].colbert_vecs` → colbert；
- dense 维度硬校验 **1024**，不等直接抛 `embedding dimension mismatch`；
- 同一 `text` 缓存一次响应，避免 dense/sparse/colbert 发三次 HTTP；
- 重试 `llm_embeddingRetries`（默认 2）次，退避 `100ms × 尝试次数`；超时只覆盖读/写，**建连超时不可设**；
- TLS 同样是 `TrustAll`；
- dense 与 colbert 的归一化由服务端完成，客户端不再归一化。

`deploy_bge_m3.sh` 起的是一个 FastAPI 服务：venv + ModelScope 权重 + `uvicorn server:app --port 8000`，systemd 单元名 `bge-m3`；`MAX_LENGTH=8192`，colbert 最多 96 token，sparse/colbert 分别用官方 `sparse_linear.pt` 与 `colbert_linear.pt`。

另有一条**不同的**向量化路径：`Embedding` 门面走 `LLMConf` 的 `url` + `/embeddings`，只取 dense，带候选与熔断；`LlmEmbeddingTransport` 是它的适配器。用这条路径会 `degraded=true`，且 colbert rerank 失效。

索引重建：

- 记忆：`llm_rebuildIndexOnStart=true` 时按 `batchSize=100` 重算 sparse + colbert，**不动 dense**；
- 知识：`KnowledgeIndexRebuilder` 提供 `rebuild(docIds)`/`rebuildAll()`，**没有启动或定时任务**，需要手工运维；
- 换 embedding 模型必须先改列宽（`vector(1024)`/`MYVECTOR(dim=1024)`）再重建。

---

## 八、loom：把一句话变成可执行流程

```
自然语言描述
→ Planner（LLM 产出 JSON 计划，或返回澄清问题）
→ CodeGen（计划 → 步骤源码 + 流程源码，不编译）
→ LoomRegistry / LoomStore（存源码与状态）
→ LoomCompiler（编译步骤闭包）
→ LoomRunner（拓扑序执行）
```

状态机：`clarifying → pending → compiled`。编译失败保持 `pending`，源码仍可读、可改；单条流程失败不影响其它流程。

步骤类型四种：`tool`、`mcp`、`llm`、`jit`（需产出 `let <id>_result = …`）。`http` 是保留 kind，`plan.validate()` 明确拒绝，不会被当成 `llm` 静默执行。

流程内 JIT 入口：`loomCallTool`、`loomCallLlm`、`loomStore`；`loomStore` 覆盖 `memory`/`experience`/`knowledge`/`skill`/`prompt`/`character`/`evolution` 七类，`payload` 都是 JSON 字符串。

对模型暴露的工具：`loomExecute`、`loomDelete`、`memoryCall`、`knowledgeIngest`、`loomStoreCall`、`listTools`/`searchTools`、`skillImport`、`scheduleCreate`/`scheduleDelete`，以及可选开启的 `a2aCall`。

---

## 九、配置：默认值都在代码里

### 模型访问

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `llm_confSource` | `database` | 只认 `database` / `env` / `file:<path>` |
| `llm_confs` | 空 | `env` 源必填，JSON 数组 |
| `llm_confRefreshSeconds` | 60 | 配置快照刷新（懒式 TTL） |
| `llm_loadBalanceAlgo` | `randomWeight` | 或 `roundRobin` |
| `llm_failureThreshold` / `llm_cooldownSeconds` | 5 / 60 | 熔断 |
| `llm_accessTryingCount` / `llm_accessTryingElapsed` | `Int64.Max` | 仅 `AgentTask` 用 |
| `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` | 120s / 1 MiB | 流式 |
| `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` | 64 KiB / 256 KiB | 工具结果 / 网页正文 |
| `llm_prunerLlmName` / `llm_summarisingLlmName` | `chat-pro` | 裁剪 / 摘要 |
| `llm_supervisor` / `llm_loomOnNoUsable` / `llm_a2aEnabled` | false | 编排与对外入口 |

### 存储与向量

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `llm_memoryStore` | `f_hydra` | `inMemory`/`postgres`/`mysql`/`f_hydra`/`fhydra` |
| `llm_metaStore` | `f_store` | `f_store`/`postgres`/`mysql` |
| `llm_metaStorePath` | `./data/f_llm-meta` | 相对可执行文件目录 |
| `llm_hydraPath` | `./data/f_hydra` | 仅 `f_hydra` |
| `llm_hydraUrl` | `http://127.0.0.1:18081/rpc` | 仅 `fhydra` |
| `llm_hydraSecret` | 空 | 为空时远程调用直接抛 |
| `llm_embeddingUrl` | `http://127.0.0.1:8000/v1/embeddings` | BGE-M3 |
| `llm_embeddingTimeoutMs` / `llm_embeddingRetries` | 3000 / 2 | 向量化 |
| `llm_rebuildIndexOnStart` / `llm_rebuildIndexUserId` / `llm_rebuildIndexNamespace` | false / 0 / `global` | 记忆索引重建 |
| `llm_fileSandboxPath` | 工作目录 | 文件工具沙箱 |

服务端侧：`hydra_dataPath`（fhydra 数据目录）、`hydra_secret`（鉴权）、`hydra_filterFields`（过滤白名单）。

已废弃、只 warn 不生效的键：`llm_contentStore`、`llm_memoryBackend`、`llm_characterBackend`、`llm_memoryPath`。`llm_contentStoreUrl` 在 MySQL 实现里被当作**库名**解析，不是远程存储地址。

---

## 十、设计取舍与已知限制

1. **失败转移优先于重试**。4xx（除 408/409/425/429）立即抛；重试只对「换个平台可能好」的错误有意义。
2. **工具循环默认关闭**。开启后串行、最多 8 轮；并行工具执行是下一步，不是现状。
3. **没有 `tool_choice`**。只能让模型自己决定是否调用，无法强制调用某个工具。
4. **schema 是注解驱动的**。`required`/`description`/`enum` 都靠注解，不读注释；没有 `$ref`、没有递归保护，复杂嵌套类型会静默降级。
5. **`command` 工具不是沙箱**。只限制 cwd，命令内容不校验、无超时；给不可信模型开放等于开放 shell。
6. **`SsrfGuard` 不是 SSRF 的完整解**。字面量校验挡不住 DNS rebinding。
7. **TLS 校验关闭**。默认传输与 BGE-M3 客户端都是 `TrustAll`；接公网端点前必须替换或接受风险。
8. **裁剪策略大多没注册**。只有 `Retain` 带 `@Bean`；`agent.pruner` 写成未注册的名字（包括空串）会直接抛异常。生产要用 `LastN_*`/`Summary_*`，必须自己 `register`。
9. **`Summary`/`Keywords` 是「替换」不是「压缩」**。整段历史只剩一条 user 消息，system 提示也会丢。
10. **dense 检索只用标题向量**。`content_dense` 写入但不用；改这一点要同时改 SQL 与索引。
11. **MySQL 的 DDL 与 DAO 有偏差**。DAO 用 `llm_memory.title_vec/content_vec`，DDL 没有这两列；接入前按实际 DAO 核对表结构。
12. **f_store 不是事务数据库**。WAL 默认每 100 次 append 才 fsync；主体与索引两阶段写崩溃会缺索引，靠 `repair()` 自愈。
13. **f_hydra 没有 HNSW**。暴力扫 + 可选 IVF，明确用召回换实现简单；数据量大时靠 IVF，不靠图索引。
14. **fhydra 未配置 secret 时，除 `health` 外的请求全部被拒**，且没有 REST 接口——只能走 JSON-RPC。
15. **MCP 需要宿主手动接线**。`McpToolSource.load()` 没有生产调用点；loom 的 `mcps` 只是提示词，不是白名单强制。
16. **A2A 没有鉴权、没有超时**。`llm_a2aEnabled=true` 即对外可调，安全边界完全交给宿主的 `f_mvc` 拦截器。
17. **A2A 的 `submitted` 是死状态**，`-32024`/`-32022` 是死常量；`input-required` 可以被取消。
18. **两套默认值容易混**。`Stores.DEFAULT_CONTENT='postgres'`/`DEFAULT_META='postgres'` 是零引用的保留常量，真正生效的是 `StoreSettings` 的 `f_hydra`/`f_store`。
