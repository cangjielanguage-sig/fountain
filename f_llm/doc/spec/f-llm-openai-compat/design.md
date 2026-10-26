# Design

> 本设计以 `f_llm/doc/f_llm.md`（v0.4，已评审）为准，本文只抽取实施所需的决定与边界；两者冲突时以评审文档为准并回到评审。

## 1. 边界与依赖

### 1.1 模块职责

| 模块 | 职责 | 不做什么 |
|---|---|---|
| `f_httpclient` | 通用 HTTP 客户端；本次新增**SSE 客户端**（`SseEvent` / `SseReader` / `HttpResponse.sseReader()`） | 不解释 `[DONE]`、不解析 JSON、不自动重连 |
| `f_llm` | 平台配置与调度、协议映射、工具、MCP 工具来源、搜索/抓取、余额接口 | 不提供 HTTP 服务端（不注册路由、不产出 SSE） |

### 1.2 依赖方向

```
f_llm ──▶ f_httpclient（HttpClient + sseReader）
      ──▶ f_mcp（仅客户端）
      ──▶ f_concurrent（LoadBalance）
      ──▶ f_data / f_log / f_orm / f_config / f_bean / f_time / f_util（既有）
```

`f_mcp` 依赖 `f_mvc`（服务端能力），会把 `f_mvc` 带进 `f_llm` 的编译闭包；`f_llm` 自身不得 `import fountain::f_mvc.*`，也不得出现任何路由注解（硬性验收）。

### 1.3 包结构

```
f_httpclient/src/sse/{SseEvent,SseReader,SseException}.cj     新增
f_httpclient/src/ExtendHttpResponse.cj                         扩展 sseReader()

f_llm/src/llm/       LLM.cj、LLMRequest/LLMResponse/LLMDelta、Snapshot、CircuitBreaker
        llm/openai/  OpenAIContext、ProviderDialect、DialectRegistry
        llm/protocol/ ChatCompletionsMapper、ResponsesMapper
        llm/stream/  StreamAccumulator（归并，不含 SSE 解析）
        llm/ModelCapabilities.cj
f_llm/src/tool/      CurrentTimeFunction、WebSearchFunction、WebFetchFunction
f_llm/src/search/    SearchProvider、SearchProviderRegistry、Zhipu/DeepSeek 实现
f_llm/src/mcp/       ServerConf、McpToolSource、McpToolSchema
f_llm/src/balance/   Snapshot、Querier、Mediator（平台实现后置）
f_llm/src/model/     po/LLMConf、LLMConfCodec
f_llm/src/config/    LLMConfig 增加配置键
f_llm/src/util/      http.cj（新增流式构造）、Redactor、TokenCounter
```

## 2. 数据模型

### 2.1 `LLMConf`

字段（评审给定）：`id / provider / llmName / actualLlmName / url / auth / temperature / alwaysThinking / conf / enabled / weight`。

两个编译层约束：

- `conf` 声明为 `HashMap<String,String>`（`Map` 是接口，`f_data` 的 `DataFields` 扩展只落在 `HashMap`）；
- 字段名用 `temperature`（评审草稿写作 `tempreture`），默认 `-1.0f64` 表示"用平台默认、报文不传"。

`conf` 是开放键表（`thinking` / `tokenThreshold` / `chatPath` / `timeoutMs` / `searchUrl` / `fetchUrl` / `balanceUrl` / `accessKeyId` 等），语义见评审文档 3.5。

### 2.2 表结构与装载

`llm_conf` 按新结构重建（破坏性变更，不写数据迁移脚本）。

```sql
SELECT id, provider, llm_name, actual_llm_name, llm_url, auth,
       temperature, always_thinking, conf, enabled, weight
FROM llm_conf
WHERE enabled = true AND weight > 0
ORDER BY llm_name, id;
```

`weight <= 0` 与停用等价，**在 SQL 层过滤**；装载后只丢弃 `provider / actualLlmName / url` 为空的残缺行并记 `warn`。

### 2.3 `conf` 的读写

- 写：`LLMConfCodec.toColumn(conf)` → `toJson(conf)`，作为 SQL 字符串参数；
- 读：`@ORMField['conf']` 配 `QueryMapperJsonConverter`（内部 `fromJson<HashMap<String,String>>`），或用 codec 统一处理空串。

## 3. 配置装载、刷新与调度

### 3.1 不可变快照

`LLMConfsSnapshot { version, loadedAt, confs: HashMap<Int64, LLMConf>, byName, balancers }`，刷新时新建并整体替换；读路径无锁。context 缓存键是 `conf.id`（不能是 `llmName`）。

### 3.2 懒式刷新（不持有线程）

`ensureFresh()` 在每次访问入口检查 `now - loadedAt >= 刷新周期`；`Mutex` + `refreshing` 标志实现单飞，其余线程直接用旧快照；刷新失败保留旧快照并记 `error`。周期由 `llm_confRefreshSeconds`（默认 60s）配置。另提供 `refreshNow()`。

### 3.3 权重调度

每个 `llmName` 一个 `LoadBalance<Int64, LLMCall, LLMResp>`：

```cangjie
var total = 0
for(c in candidates){ total += c.weight }
let algo: LoadBalanceAlgo<Int64> = match(LLMConfig.getLoadBalanceAlgo()){
    case 'roundRobin' => RoundRobin<Int64>(1, 0, total - 1)
    case _ => Int64Weight(0, total)
}
let balancer = LoadBalance<Int64, LLMCall, LLMResp>(0, algo)
for(c in candidates){ balancer.add(c.weight){call => doAccess(c, call)} }
```

**不用** `call(data, maxRetrying)`（它对任何异常都继续试）；用 `iterator()` 自行遍历，只对可重试错误前进。

### 3.4 熔断（仅内存）

`ConcurrentHashMap<Int64, BreakerState>`，键为 `conf.id`；可重试失败累加，达 `llm_failureThreshold`（5）置 `openUntil = now + llm_cooldownSeconds`（60s）；成功清零；4xx 不计入；选择时跳过 `openUntil > now` 的节点，到期清零复活；刷新后清理已不存在的 `conf.id`。

## 4. 协议层

### 4.1 单一平台实现 + 方言表

`OpenAIContext` 是唯一平台实现；`ProviderDialect{endpoint, authHeaders, decorate, parseUsage}` 负责端点、鉴权头、报文补丁与 usage 补齐，`DialectRegistry` 按 `provider` 注册（重名失败，未知回退标准实现）。

### 4.2 请求构造

手拼 `JsonObject`（因为要按值排除 `temperature < 0`），字段名保持蛇形。`model` 填 `actualLlmName`；`stream` 由调用形态决定；工具定义沿用 `FunctionCalling.definition`。

### 4.3 流式归并

`SseReader` 只给 `SseEvent`；`StreamAccumulator` 负责：

- Chat：`delta.content` 追加、`reasoning_content|reasoning` 追加、`tool_calls` 按 `index` 归并且 `arguments` 先拼后解析、`finish_reason` 记录、`usage` 取末块（缺失则启发式估算并标 estimated）；`data == "[DONE]"` 结束。
- Responses：按事件类型分派，最终以 `response.completed` 的完整响应为准。

### 4.4 模型思考能力

`ThinkingCapability{None, Always, Toggle}` + `ModelCapabilities.thinking(conf)`，解析顺序 `conf['thinking']` → 内置模型表（前缀匹配）→ `Toggle`。`Always` 丢弃 `temperature`；`None` + `alwaysThinking` 记 `warn` 且不写思考字段；方言只决定字段形态（`thinking:{type}` / `enable_thinking` / `reasoning.effort`）。

## 5. 对外 API

```cangjie
LLM.chat(req: LLMRequest): LLMResponse
LLM.chatStream(req: LLMRequest, onDelta: (LLMDelta) -> Unit): LLMResponse
LLM.respond(req: LLMRequest): LLMResponse
LLM.respondStream(req: LLMRequest, onEvent: (ResponsesEvent) -> Unit): LLMResponse
```

流式采用**同步回调**（调用方线程内触发），模块不 `spawn`、不建线程池。`LLMContextMediator` 保留并改为按 `llmName` 访问，新增 `candidates()/peekNext()/isCircuitOpen()/refreshNow()`，阈值与计数改为按 `conf`。

## 6. 错误语义

| 情形 | 行为 |
|---|---|
| 连接失败 / 超时 / 429 / 5xx / 流中断 | 可重试：指数退避 + 尝试下一个平台 |
| 其余 4xx | 立即失败，不转移 |
| 流空闲超时 | 包装为 LLM 异常，保留 `requestId` 与阶段（首包/中途） |
| 搜索/抓取无可用配置 | 抛 `SearchUnavailableException` |
| 抓取被安全策略拒绝 | 抛 `FetchRejectedException`，消息含拒绝原因 |
| MCP 工具返回错误 | 错误文本作为工具结果回给模型（不抛） |
| 余额平台不支持 | 抛 `BalanceUnsupportedException` |

## 7. 工具、搜索与抓取

- 工具三来源合并，重名构建期失败；MCP 工具名 `mcp__{alias}__{tool}`，**不截断**，超 64 字符或字符集非法直接失败。
- `webSearch` / `webFetch` 的凭据从任意启用配置借：按 `SearchProvider` 注册表筛平台 + 熔断过滤；`provider` 显式指定时不跨平台回退。
- `webFetch` 必须实现 SSRF 防护：仅 `http/https`、解析后 IP 必须在公网（拒绝 `127/8`、`10/8`、`172.16/12`、`192.168/16`、`169.254/16`、`::1`、`fc00::/7`、`fe80::/10`）、每跳重新校验、最多 3 跳、响应体上限 256 KiB。

## 8. 上下文裁剪

8 个策略保留；仅 `SaturationContextPruner` 改为 `peekNext(agent.llmName)` 取 conf 后按该 conf 的 `tokenThreshold` 判断（0 表示不限制）。`tokenize` 改为 `TokenCounter` 策略（远端/启发式），`LLM.chat*` 不做自动裁剪。

## 9. 日志与序列化

- 默认 `info`；每次调用一条汇总（provider / actualLlmName / 耗时 / TTFT / TokenUsage / finish_reason）。
- `Redactor`：前 4 + `****` + 后 4（长度 < 12 全掩码），覆盖 `auth`、`Authorization`、`*Key*/*Secret*/*Token*`。
- `f_data`：非流式用 `DataObject.populate`；流式手工 `JsonObject.get` 归并；`conf` 用 `toJson/fromJson`。

## 10. 兼容与发布影响

破坏性变更（无兼容期）：删除 `GLMContext`、旧 `access(llmType, ...)` 系列、`AbstractSearcher`/`SearchMediator.register`；`LLMFinder.listConfs` 改无参；`llm_conf` 重建；`fcoder` 的 `LLMService`/`LLMServiceImpl`/`LLMDAO`/`KnowledgeServiceImpl` 同步改。

## 11. 实施顺序

1. 前置验证（`LLMConf` 编译 + `conf` JSON 往返）；
2. `f_httpclient` SSE 客户端（独立可测，流式的前置）；
3. 配置装载/刷新/调度/熔断 + 非流式协议（**先接 DeepSeek**）；
4. 流式（Chat → Responses）；
5. 工具与 MCP；
6. 裁剪适配 + 日志脱敏；
7. 余额接口；
8. 各平台联调（智谱/DeepSeek/火山/百炼/硅基流动/OpenAI）**最后做**，按 §附录 B 的清单逐家打勾。

## 12. 待验证事项

- `conf: HashMap` 的 ORM 写方向（`QueryMapperConverter` 只有读方向）：用真实库跑一条 `读 → 改 → 写 → 再读`。
- 各家 `usage` / `thinking` / `tools` 真实字段：联调前按假设写 fixture，联调时以实测为准并回填文档。
