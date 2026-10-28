# Proposal

> **状态（2026-10-28）**：本提案写于动手之前，文中的部分类型名与最终实现不同（`OpenAIContext`、`ThinkingCapability`、`ModelCapabilities`、`LLMRequest`/`LLMResponse` 均未进代码）。逐条差异见文末「实现偏差（apply 之后回填）」。任务进度 **58/63**，剩余 9.2–9.6 为其他平台联调（需外部 Key）。

## Why

现在的 `f_llm` 只能对接智谱 GLM、只有一次性非流式调用：`LLMContextMediator` 的注册表里只有 `GLMContext`，`LLMConf` 只有 6 列、把鉴权 KEY 塞在 `conf` 列里当 Bearer Token 用，全模块 4 处 HTTP 调用都是 `post(...).readJson()`，没有流式。这使 fountain 上的智能体无法使用 DeepSeek、火山方舟、百炼等 OpenAI 兼容平台，也无法在会话里增量输出。

同时 `f_httpclient` 没有 SSE 客户端（对外只有 `reader(): StringReader<InputStream>`），`text/event-stream` 在仓库里只以**服务端**形态出现在 `f_mcp`。把 SSE 解析写在 `f_llm` 里会让每个用流式的业务模块各写一份行解析。

本次改造按已评审的设计文档 `f_llm/doc/f_llm.md`（v0.4）落地：协议层 OpenAI 兼容、`LLMConf` 多平台化、按权重调度 + 熔断、tool_call 与 MCP、余额查询接口，SSE 解析下沉到 `f_httpclient`。各平台真实方言**联调放到最后**，实现优先适配 DeepSeek。

## What Changes

- **BREAKING**：`LLMConf` 改为 `provider / llmName / actualLlmName / url / auth / temperature / alwaysThinking / conf / enabled / weight`；删除 `llmType` / `threshold` / `priority`（分别迁到 `conf` 键与 `weight`）；`llm_conf` 表按新结构重建，不做数据迁移。
- **BREAKING**：删除 `GLMContext`、`LLMRouter` 计划、旧 `access(agentId, session, llmType, params)` 系列签名、`AbstractSearcher` / `SearchMediator.register`；`LLMFinder.listConfs(llmTypes)` 改为无参 `listConfs()`。
  - **注（实际实现）**：`LLMFinder` 最终被整体删除（连同 `LLMContextMediator`、`SearchMediartor`），配置统一由 `LLMConfs.holder()` 提供。
- **BREAKING**：删除 `fcoder` 模块（`description = "nothing here"` 的遗留脚手架，全仓无引用、不在 `.modules`、不在根 package），不再做签名适配。
- **配置来源可插拔**：数据库只是可选来源之一。新增 `LLMConfSource` 抽象，内置数据库源，另支持环境变量/配置文件/静态注册；由 `llm_confSource` 选择。
- **上下文裁剪允许重写**：除"语义不变"这一约束外可重新实现，也可以新增算法；同时提供可插拔的 token 计数。
- 新增 `OpenAIContext`（唯一平台实现）+ `ProviderDialect` 表驱动方言 + `LLMApiKind`（Chat Completions / Responses API），四种调用形态：非流式 Chat、流式 Chat、非流式 Responses、流式 Responses。
  - **注（实际实现）**：没有 `OpenAIContext`。门面 `LLM` 直接按 `ProviderDialect` 取端点与请求头，内建 `deepseek` / `zhipu` / `volcengine` / `aliyun` / `siliconflow` 五个方言，未注册 provider 回退 `StandardDialect`；四种形态均已落地（含 Responses 多模态）。
- 新增 `ThinkingCapability`（`None` / `Always` / `Toggle`）与 `ModelCapabilities`：**思考由模型决定，平台只决定字段形态**。
  - **注（实际实现）**：这两个类型**未实现**。当前只有 `conf.alwaysThinking` 与「调用方是否要求过 `thinking`」两条规则，由各方言分别翻译成对象开关或布尔字段。
- 新增配置快照 + 懒式周期刷新（`llm_confRefreshSeconds`）、`f_concurrent.LoadBalance` 权重调度、连续可重试失败熔断（`llm_failureThreshold` / `llm_cooldownSeconds`，仅内存）。
- 新增对外门面 `LLM.chat / chatStream / respond / respondStream`，以及 `LLMDelta` / `LLMResponse` 稳定契约。
  - **注（实际实现）**：契约是 `LLMParams` → `LLMResp`（复用既有类型，补了 `finishReason` / `usageEstimated`），未新建 `LLMRequest` / `LLMResponse`；另加 `chatByName` / `respondByName` 与 `LLMHooks`。
- 工具：保留 `FunctionCalling` / `FunctionMediator`；新增内置 `currentTime`、`webSearch`、`webFetch`（抓取带 SSRF 防护）；新增 MCP 工具来源（`f_mcp` 客户端）。
- 搜索/抓取能力改为可注册的 `SearchProvider`（内置智谱与 DeepSeek），凭据从任意启用的 `LLMConf` 取；无可用配置时抛异常。
  - **注（实际实现）**：只做了 `DeepSeekSearchProvider`（`/v1/tools/search` 与 `/v1/tools/fetch`，2026-10-27 实调）；智谱搜索未做。
- 上下文裁剪：8 个策略的**对外语义保持不变**，实现可重写，并允许新增算法；`tokenize` 改为可插拔 `TokenCounter`；`SaturationContextPruner` 改为按 conf 取阈值。
- `f_httpclient` 新增 SSE 客户端：`SseEvent` / `SseReader` / `HttpResponse.sseReader()`。
- 余额查询：`BalanceQuerier` 接口 + `BalanceMediator` 中介者；**先实现 DeepSeek**（`GET /user/balance`），其余平台先落可编译占位（调用即抛「不支持」），后续按 JAVA 参考逐个补齐；CodeBuddy / Qoder 不做。
  - **注（实际实现）**：DeepSeek 之外，腾讯云 `DescribeAccountBalance`（TC3 签名，金额单位是分）与火山引擎 `QueryBalanceAcct`（V4 签名）已按官方文档实现；智谱 / 硅基流动 / 阿里云仍为占位。金额一律归一为元。

## Capabilities

### New Capabilities

- `llm-protocol-compat`: OpenAI Chat Completions 与 Responses API 的流式/非流式兼容，以及平台方言与模型思考能力解析。
- `llm-conf-routing`: `LLMConf` 模型、可插拔配置来源、装载与周期刷新、按权重调度、连续失败熔断、饱和 token 阈值。
- `llm-context-pruning`: 上下文压缩/裁剪的对外语义契约（8 个既有策略的行为不变）与新增算法的扩展方式。
- `llm-tool-calling`: tool_call 保留与扩展、三个内置函数、MCP 工具来源、工具命名与冲突规则。
- `llm-balance-query`: 余额查询统一接口与中介者，先实现 DeepSeek，其余平台可编译占位。
- `http-sse-client`: `f_httpclient` 提供通用 SSE 客户端，供 `f_llm` 等模块消费。

### Modified Capabilities

（无。`openspec/specs/` 当前为空，本次全部为新增能力。）

## Impact

- **代码**：`f_llm/src/**`（llm / tool / search / mcp / balance / config / model / util）、`f_httpclient/src/**`（新增 `sse/`，扩展 `ExtendHttpResponse`）；删除 `fcoder/`（含 `src` / `docs` / `README*` / `cjpm.toml`）。
- **依赖**：`f_llm/cjpm.toml` 新增 `fountain::f_mcp`、`fountain::f_concurrent`（均已确认无反向依赖，无环）；删除 `fcoder` 后无模块依赖它。
- **数据库**：数据库只是配置来源之一（`llm_conf` 表按新结构重建）；`llm_token_usage` 增列 `reasoning_tokens`（TokenUsage 只进日志，不再默认落库）。
  - **注（实际实现）**：`reasoning_tokens` 列**没有加**，`doc/sql/*.sql` 里只有 `llm_conf`；TokenUsage 目前只出现在日志与 `CallLogger` 汇总里。
- **调用方**：`ContextPruner` 与 `AgentTask` 的内部调用点同步；`fcoder` 整体删除，不做适配。
- **文档**：`f_llm/README.md` + `README_en.md` 需按新公开 API 更新；`f_httpclient/README` 增补 SSE 客户端一节；设计文档已在 `f_llm/doc/f_llm.md`。
- **不做**：HTTP 服务端（不注册路由）、CodeBuddy/Qoder 余额、Anthropic 协议；除 DeepSeek 外的平台余额与方言联调排到最后。

## 实现偏差（apply 之后回填，2026-10-28）

| 提案写的 | 实际落地 | 原因 |
|---|---|---|
| `OpenAIContext` 唯一平台实现 | `LLM` 门面 + `ProviderDialect`（5 个内建方言 + `StandardDialect` 回退） | 平台差异只在端点/请求头/思考字段，一个 Context 类会把所有分支塞进同一个类 |
| `ThinkingCapability` / `ModelCapabilities` | 未实现；`conf.alwaysThinking` + 方言翻译 | 需要真实模型清单才能推断，宁可少一层抽象 |
| `LLMRequest` / `LLMResponse` 契约 | `LLMParams` / `LLMResp`（+ `LLMHooks`） | 复用既有类型，避免平行模型 |
| `LLMFinder.listConfs()` 无参 | `LLMFinder` 整体删除，统一 `LLMConfs.holder()` | 两套配置视图容易不一致 |
| 内置智谱 + DeepSeek 搜索 | 仅 DeepSeek（已实调） | 智谱搜索字段未复核，先不做 |
| 余额：DeepSeek + 其余占位 | DeepSeek + 腾讯云（TC3）+ 火山（V4）；其余占位 | 按官方文档实现，签名待真实 AK/SK 联调验证 |
| Responses 未提多模态 | 已实现 `input_image`，且实测 DeepSeek `/responses` 可用 | 提案假设 DeepSeek 无 Responses，实测推翻 |
| 未提 Chat 多模态 | `ChatMessage.addImage/addText` + `ContentPart` | 与 Responses 多模态对齐 |
| 未提 embedding | `Embedding.embed(llmName, param)`，旧链路删除 | 旧 mediator 已无人引用 |
| `llm_token_usage.reasoning_tokens` | 未加列 | 本期 TokenUsage 只进日志 |