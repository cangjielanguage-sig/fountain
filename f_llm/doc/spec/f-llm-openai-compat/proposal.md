# Proposal

## Why

现在的 `f_llm` 只能对接智谱 GLM、只有一次性非流式调用：`LLMContextMediator` 的注册表里只有 `GLMContext`，`LLMConf` 只有 6 列、把鉴权 KEY 塞在 `conf` 列里当 Bearer Token 用，全模块 4 处 HTTP 调用都是 `post(...).readJson()`，没有流式。这使 fountain 上的智能体无法使用 DeepSeek、火山方舟、百炼等 OpenAI 兼容平台，也无法在会话里增量输出。

同时 `f_httpclient` 没有 SSE 客户端（对外只有 `reader(): StringReader<InputStream>`），`text/event-stream` 在仓库里只以**服务端**形态出现在 `f_mcp`。把 SSE 解析写在 `f_llm` 里会让每个用流式的业务模块各写一份行解析。

本次改造按已评审的设计文档 `f_llm/doc/f_llm.md`（v0.4）落地：协议层 OpenAI 兼容、`LLMConf` 多平台化、按权重调度 + 熔断、tool_call 与 MCP、余额查询接口，SSE 解析下沉到 `f_httpclient`。各平台真实方言**联调放到最后**，实现优先适配 DeepSeek。

## What Changes

- **BREAKING**：`LLMConf` 改为 `provider / llmName / actualLlmName / url / auth / temperature / alwaysThinking / conf / enabled / weight`；删除 `llmType` / `threshold` / `priority`（分别迁到 `conf` 键与 `weight`）；`llm_conf` 表按新结构重建，不做数据迁移。
- **BREAKING**：删除 `GLMContext`、`LLMRouter` 计划、旧 `access(agentId, session, llmType, params)` 系列签名、`AbstractSearcher` / `SearchMediator.register`；`LLMFinder.listConfs(llmTypes)` 改为无参 `listConfs()`。
- 新增 `OpenAIContext`（唯一平台实现）+ `ProviderDialect` 表驱动方言 + `LLMApiKind`（Chat Completions / Responses API），四种调用形态：非流式 Chat、流式 Chat、非流式 Responses、流式 Responses。
- 新增 `ThinkingCapability`（`None` / `Always` / `Toggle`）与 `ModelCapabilities`：**思考由模型决定，平台只决定字段形态**。
- 新增配置快照 + 懒式周期刷新（`llm_confRefreshSeconds`）、`f_concurrent.LoadBalance` 权重调度、连续可重试失败熔断（`llm_failureThreshold` / `llm_cooldownSeconds`，仅内存）。
- 新增对外门面 `LLM.chat / chatStream / respond / respondStream`，以及 `LLMDelta` / `LLMResponse` 稳定契约。
- 工具：保留 `FunctionCalling` / `FunctionMediator`；新增内置 `currentTime`、`webSearch`、`webFetch`（抓取带 SSRF 防护）；新增 MCP 工具来源（`f_mcp` 客户端）。
- 搜索/抓取能力改为可注册的 `SearchProvider`（内置智谱与 DeepSeek），凭据从任意启用的 `LLMConf` 取；无可用配置时抛异常。
- 保留 8 个上下文裁剪策略，仅 `SaturationContextPruner` 改为按 conf 取阈值；`tokenize` 改为可插拔 `TokenCounter`。
- `f_httpclient` 新增 SSE 客户端：`SseEvent` / `SseReader` / `HttpResponse.sseReader()`。
- 余额查询只落 `BalanceQuerier` 接口 + `BalanceMediator`，平台实现后置；CodeBuddy / Qoder 明确不做。

## Capabilities

### New Capabilities

- `llm-protocol-compat`: OpenAI Chat Completions 与 Responses API 的流式/非流式兼容，以及平台方言与模型思考能力解析。
- `llm-conf-routing`: `LLMConf` 模型、配置装载与周期刷新、按权重调度、连续失败熔断、饱和 token 阈值。
- `llm-tool-calling`: tool_call 保留与扩展、三个内置函数、MCP 工具来源、工具命名与冲突规则。
- `llm-balance-query`: 余额查询统一接口与中介者（平台实现后置）。
- `http-sse-client`: `f_httpclient` 提供通用 SSE 客户端，供 `f_llm` 等模块消费。

### Modified Capabilities

（无。`openspec/specs/` 当前为空，本次全部为新增能力。）

## Impact

- **代码**：`f_llm/src/**`（llm / tool / search / mcp / balance / config / model / util）、`f_httpclient/src/**`（新增 `sse/`，扩展 `ExtendHttpResponse`）。
- **依赖**：`f_llm/cjpm.toml` 新增 `fountain::f_mcp`、`fountain::f_concurrent`（均已确认无反向依赖，无环）。
- **数据库**：`llm_conf` 表重建；`llm_token_usage` 增列 `reasoning_tokens`（TokenUsage 只进日志，不再默认落库）。
- **调用方**：`fcoder` 的 `LLMService` / `LLMServiceImpl` / `LLMDAO` / `KnowledgeServiceImpl` 需同步改签名；`ContextPruner` 与 `AgentTask` 内部调用点同步。
- **文档**：`f_llm/README.md` + `README_en.md` 需按新公开 API 更新；`f_httpclient/README` 增补 SSE 客户端一节；设计文档已在 `f_llm/doc/f_llm.md`。
- **不做**：HTTP 服务端（不注册路由）、余额平台实现、CodeBuddy/Qoder 余额、Anthropic 协议。
