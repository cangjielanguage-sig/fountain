# f_llm 模块审查报告（第 13/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个 `.cj` + 0 个 `.md`；模块整体 368 个 `.cj` + 112 个 `.md`）
- **本部分范围**：`src/llm/` 客户端契约层（`LLMTransport`、`ModelCapabilities`/`ThinkingPolicy`、`ResponsesMapper`、`ResponsesStreamAccumulator`、`TokenCounter`、`TokenizerParams`、`advanced_params`、`imports`）、`src/llm/openai/`（方言接口、注册表、5 个内建方言）、`src/loom/`（A2A 桥 + `a2aCall` 工具），以及这些文件对应的 5 个测试文件
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status` 仅有两个审查输出目录未跟踪）→ 本部分全部问题来源均为**存量**
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（本文件只是分报告，模块报告由主 Agent 合并生成）
- **与其他部分的分工**：`LLM.cj`、`ChatCompletionsMapper.cj`、`ChatStreamAccumulator.cj`、`LLMStreamTransport.cj` 不在本部分文件清单（由其它子轮覆盖）。本部分只在需要判定契约与对照实现时引用其行号，不展开审查、不计入统计；确属那些文件的独立缺陷只写进「范围外提示」

## 发现

### [严重][存量] LLM 传输层显式关闭 TLS 证书校验，Bearer Key 与完整应答都暴露在中间人信道

- **位置**：`f_llm/src/llm/LLMTransport.cj:46-48`（`DefaultHttpTransport.post` 里 `tls.verifyMode = CertificateVerifyMode.TrustAll`）；同一根因另两处：`f_llm/src/llm/LLMStreamTransport.cj:48-50`（流式传输）、`f_llm/src/util/http.cj:25-27`（`RemoteTokenCounter` 等使用的 `http()` 助手）
- **来源**：存量（`git blame -L 46,50 -- f_llm/src/llm/LLMTransport.cj` → `d3ebac7923 2026-10-27`；另外两处同作者同期）
- **判据**：review-checklist §10（安全性：敏感数据 / 硬编码降级）+ §11（契约与实现不符：调用方以为在走标准 HTTPS）
- **证据**：静态确定 —— 三处都在构造 `HttpClient` 后无条件把 `TlsClientConfig().verifyMode` 置成 `CertificateVerifyMode.TrustAll`，没有任何配置项能切回默认校验（全仓 `CertificateVerifyMode.TrustAll` 共 8 处：`f_llm` 内 7 处——本文件的 `LLMTransport`、`LLMStreamTransport`、`util/http`，加 `balance/BalanceQueriers.cj:42`、`embedding/BgeM3Transport.cj:91`、`search/DeepSeekSearchProvider.cj:44`、`store/hydra/HttpTransport.cj:203`；以及 `f_app/src/PublishCommand.cj:298`。没有一处按配置判断；反例是 `f_mvc/src/MVCConfig.cj:92` 已经把 `trustall` 做成可配置项，说明仓内已有正确形态可参照）
- **描述**：`DefaultHttpTransport.post` 是所有非流式 LLM 调用的唯一生产通道（`LLM.cj:38` 把 `transport` 初始化成它）。它把证书校验关成 TrustAll，而请求头里带的是 `Authorization: Bearer ${conf.auth}`（`ProviderDialect.cj:71`、`ProviderDialects.cj:150`）——即明文 API Key，响应体是模型输出与 usage。任何能劫持 DNS / 中间设备 / 企业代理的对手都可完整拿到密钥并篡改响应（例如把工具调用参数改掉）。这不是"自签证书兼容"的局部例外，而是对所有 provider 一律生效；`doc/known-limitations.md` 与 README 都没有把它记为已知限制。`RemoteTokenCounter` 走 `util/http.cj` 的同一助手，同样把 Key 发到 `conf['tokenizerUrl']`
- **建议**：①改为默认校验，只在 `conf` 显式给出 `tlsInsecure=true`（或给某个自建内网 endpoint）时降级，并在日志里 warn 一次；②给 `LLMConf` 增加 `caFile` / `tlsInsecure` 两个选项，把 `TlsClientConfig` 的构造收敛到一个工厂（见轻微第 4 条，三处重复的正是这段）；③流式与非流式共用同一个工厂，避免只修一处

### [一般][存量] Responses 路径静默丢弃 `max_tokens` 与 `response_format`，同一份 `LLMParams` 在两条协议下语义不同

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:36-91`（`build` 只写 `model` / `instructions` / `input` / `temperature` / `stream` / `tools`）
- **来源**：存量（`git blame` → `2026-10-27` 同批提交，快照模式无 diff）
- **判据**：review-checklist §11（契约与实现不符）+ §14.1（只做了一半的映射）
- **证据**：静态确定 —— `LLMParams` 的字段是 `model / messages / thinking / response_format / temperature / max_tokens`（`f_llm/src/llm/LLMParams.cj:22-31`）；Chat 路径用 `JsonValue.from(params.toData())` 整体序列化后再按值剔除（`ChatCompletionsMapper.cj:37-64`），所以 `max_tokens`、`response_format` 都会进报文；Responses 路径是"手拼白名单"，这两个字段在 `build` 里没有任何对应写入，且全文件搜 `max_tokens` / `max_output_tokens` / `response_format` 零命中
- **描述**：`LLM.respond` / `respondByName` 与 `LLM.chat` 接受同一个 `LLMParams`，但走 Responses 时：①`max_tokens`（默认 65536）不生效 → 不能限制单次输出长度，长回答成本与延迟不可控；②`response_format=json_object` 不生效 → 需要结构化输出的调用方（工具参数、评测）拿到自由文本，下游 `JsonValue.fromStr` 直接失败。两条都是"不报错、结果不对"，比抛异常更难查。Responses 协议的对应字段是 `max_output_tokens` 与 `text.format`，不是简单改名，确实需要单独映射——但现在的实现是"整段缺失"
- **建议**：在 `build` 里补两段映射（`max_tokens` → `max_output_tokens`，`response_format.type == json_object` → `text: {format: {type: 'json_object'}}`），并加一条 `ChatCompletionsMapper` / `ResponsesMapper` 的字段覆盖对照用例：同一个 `LLMParams` 两边都断言"该带的字段都带了"，防止以后再漏

### [一般][存量] `ResponsesMapper.parse` 把 `status=failed / incomplete` 当成功返回，错误原因被丢弃

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:93-128`（`:95` 只把 `status` 写进 `finishReason`，随后无条件返回 `LLMResp`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（失败路径当成功）+ §3（`Result` 失败被丢弃）
- **证据**：静态确定 —— `parse` 的入参是 HTTP 200 的响应体；当 `status` 为 `failed`/`incomplete` 时，`output` 通常为空或缺项，循环不产生消息，函数仍返回一个 `messages` 为空的 `LLMResp`；`resp.get('error')` / `incomplete_details` 全文件零引用
- **描述**：上游以 200 + `status: failed` 表达业务失败（Responses 的常见形态）时，`LLM.call` 认为成功，`hooks.onSuccess(conf.id)` 清掉熔断计数，返回空消息列表。后果按调用方：`respond` 的外部使用者拿到空 `messages[0]`（越界或空回答）；若上层拿它继续工具循环，会和"模型没话说"混淆。同时 `error.message` 不进任何日志/异常，线上只能看到 `finish: failed`
- **建议**：`status` 不属于 `completed`/`in_progress` 时抛 `LLMException`（消息带 `error.code/message` 与 `incomplete_details.reason`），或至少把错误文本塞进 `finishReason` 之外的独立字段；配一条 fixture：`{"status":"failed","error":{"code":"server_error","message":"boom"}}` 断言抛异常

### [一般][存量] Responses 流在缺 `response.completed` 时返回"成功"的部分结果，截断对调用方不可见

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:79-93`（`result()`：只有 `failure` 与 `completed` 两个分支，其余一律走 86-92 行拼装 `partial`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（错误处理缺失）+ §3（`case None` 兜底把错误吃掉）
- **证据**：静态确定 —— 类内没有"是否收到终态事件"的标志：`done` 只由 `[DONE]` / `response.completed` / `failed` / `error` 置位，而 `result()` 完全不读 `done`；走到 86 行时既可能是"SSE 正常结束但上游没发 completed"，也可能是"连接中断被上层吞掉"，两者都返回 `usageEstimated=true` 的正常 `LLMResp`，`finishReason` 为空串
- **描述**：调用方无法区分"模型正常答完"与"答到一半断了"。`LLM.stream`（`LLM.cj:267`）在 `transport.stream` 返回后直接 `result()`，若流被对端提前关闭（CDN/网关超时、上游 5xx 后断开），拿到的是半截正文 + `finish:'undefined'`，会被当成最终答案落库/回应用户。Chat 路径有同样的隐患，但 Responses 侧本来就有 `response.completed` 这个明确终态可用却没使用
- **建议**：`result()` 里 `completed.isNone() && !done` 时抛 `LLMException('responses stream ended without response.completed')`，或返回带 `finishReason='truncated'` 的结果并让 `LLM.stream` 按可重试失败处理（注意此时已经向 `onDelta` 推过增量，需要上层决定是否丢弃）

### [一般][存量] 非流式 HTTP 传输没有显式超时，完全依赖 stdx 默认值，而 f_llm 从未为 LLM 路径设置全局超时

- **位置**：`f_llm/src/llm/LLMTransport.cj:40-53`（`post` 只 `new HttpClient(url)` + header + tlsConfig，无 `readTimeout`/`writeTimeout`）
- **来源**：存量（`git blame` → `d3ebac7923 2026-10-27`）
- **判据**：review-checklist §11（资源与超时）+ §12.1（无界阻塞）
- **证据**：待确认 —— ①`HttpClient` 构造只把**进程级静态**超时应用上去（`f_httpclient/src/httpclient.cj:41-48` 读 `readTimeout_`/`writeTimeout_`，二者只由 `globalReadTimeout`/`globalWriteTimeout` 写入，`:29-36`）；②全仓 `globalReadTimeout` 只有 `f_llm/src/embedding/BgeM3Transport.cj:63-64` 与一个测试调用，LLM 路径从不设置；③因此 `DefaultHttpTransport` 的读超时等于 `ClientBuilder` 的默认值，该默认值不在仓内、本次环境也没有 stdx 源码/文档可核（SDK 目录只有二进制）。缺的数据：stdx `ClientBuilder.readTimeout` 的默认值，以及一次 >120s 的长回答实测（若默认较短，长推理请求会被误判成传输失败并触发换平台；若默认无限，则对端不响应时线程会一直挂着）
- **描述**：两条后果方向相反、都不可接受：默认超时偏短 → 长回答被截断后走 failover，重复计费；无默认超时 → 单个卡住的 provider 占住一个请求线程，直到 TCP keepalive 才释放。流式路径有 `llm_streamIdleTimeout`（默认 120s，`LLMConfig.cj:176-178`）兜底，非流式路径没有任何同类配置项
- **建议**：给 `LLMConf` 或 `LLMConfig` 增加 `llm_readTimeoutMs` / `llm_connectTimeoutMs`（默认值应大于最长生成时间，例如 300s），在 `DefaultHttpTransport` 里显式 `client.readTimeout(...)`/`writeTimeout(...)`，不要再依赖进程级 `globalReadTimeout`（它会被 embedding 的 3s 默认值顺带改掉，见下条）

### [一般][存量] A2A 代理卡片硬编码名称/描述与 80 端口 URL，与规格"由 LLMConfig 拼出"冲突，默认部署下卡片地址不可用

- **位置**：`f_llm/src/loom/A2aBridge.cj:129-132`（`defaultCard()`：`name: 'loom-supervisor'`、中文 `description`、`url: 'http://127.0.0.1/rpc/a2a'`）
- **来源**：存量（快照模式无基线；文件头年份 2026，与 A2A 特性同批）
- **判据**：review-checklist §14.1（承诺了但没实现 / 接线缺失）+ §13（规格与实现漂移）
- **证据**：静态确定 —— ①承诺源：`f_llm/doc/spec/add-loom-a2a/proposal.md:22`「卡片由 `LLMConfig` 里的名称/描述拼出，`url` 指向 `/rpc/a2a`」，`tasks.md:14` 同款验收口径；②缺失证据：`LLMConfig.cj` 里 A2A 只有 `llm_a2aEnabled`（`:62-68`），没有任何 name/description/host/port 配置项；`defaultCard()` 三个字段全是字面量；③端口：仓内所有 A2A 示例都是 `http://127.0.0.1:8080/rpc/a2a`（`f_a2a/README.md:54,98`、`f_a2a/doc/a2a-protocol.md:188`），这里是 80 —— 除非进程恰好监听 80，外部客户端按卡片地址调用必然连接失败
- **描述**：开启 `llm_a2aEnabled=true` 后，`a2a.agent.card` 返回的 URL 指向本机 80 端口，而 fountain 应用默认监听 8080（`LoomA2a` 的日志也只打 `chosenCard.url`）。对接方拿到卡片 → 直接 POST 到 80 → 连接被拒，且没有任何日志提示"卡片地址是猜的"。名称/描述硬编码还导致多实例部署时对外全是同一个 `loom-supervisor`，没法区分
- **建议**：新增 `llm_a2aName` / `llm_a2aDescription` / `llm_a2aUrl`（缺省时用 `f_config` 里的服务端口拼 `http://127.0.0.1:<port>/rpc/a2a`），`defaultCard()` 只做兜底并在兜底时 `warn`；补一条断言"配置了 `llm_a2aUrl` 时卡片取配置值"的用例

### [一般][存量] `DoSample` 的默认 `mut prop` setter 是空实现：写 `do_sample = false` 静默无效

- **位置**：`f_llm/src/llm/advanced_params.cj:32-39`（`get(){ true }` + `set(value){}`）
- **来源**：存量（`git blame -L 32,39` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（空实现：公开契约承诺有行为）
- **证据**：静态确定 —— setter 参数 `value` 未使用、函数体为空；getter 恒返回 `true`，所以该属性的取值与赋值完全脱钩。全仓搜 `DoSample` 只有定义处（README 索引 `f_llm/README.md:864` 登记了这个公开接口），没有任何类实现或使用
- **描述**：这是"接口给默认实现"的典型空实现：任何类 `class X <: DoSample` 都会继承这个 setter，`x.do_sample = false` 能编译、能运行、什么也不改，采样参数永远按 true 下发。当前仓内零使用，所以现在没有实际损失；但它是对外 public 接口，一旦被下游采纳就是静默错配（同文件 `FrequencyPenalty` / `ThinkingBudget` 只有只读默认值，没有这个问题）
- **建议**：二选一——(a) 删除这三个未使用的接口（对外 API 收窄需用户确认）；(b) 若要保留，把 `do_sample` 改成 `private var` + 由实现类覆盖，或在 setter 里真的存值（`mut prop` 的默认实现必须能被覆盖时才有意义）。同类问题合并检查：`FrequencyPenalty.frequency_penalty` / `ThinkingBudget.thinking_budget` 的默认值 0.5 / 1024 也没有任何配置来源

### [一般][存量] `ResponsesMapper.parse` 的 reasoning 跨 `output` 项不清零：后续 message 重复挂同一段思考内容，提前出现的 reasoning 则整段丢失

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:96`（`var reasoning = ''`）、`:101`（`reasoning += textOfReasoning(obj)`）、`:104-106`（挂到 `assistant.reasoningContent` 后不重置）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`，与 `parse` 同批）
- **判据**：review-checklist §11（逻辑错误：状态变量跨迭代复用）＋ §2（与 `ChatCompletionsMapper.appendMessage` 的「一条响应一份 reasoning」语义漂移）
- **证据**：静态确定 —— `reasoning` 声明在 `for(item in rawOutput...)` 之外；`case 'reasoning'` 只累加，`case 'message'` 只读取，`parse` 全程没有 `reasoning = ''`
- **描述**：`output = [reasoning, message, message]` 时两条 `AssistantMessage` 都带同一份 `reasoningContent`，回灌下一轮上下文会重复计费，并让模型看到两份互相矛盾的「上一次思考」；`output` 里 reasoning 排在 message 之后（ReAct 风格的分段输出）时，先出现的 message 完全拿不到 reasoning。仓内测试只覆盖单 message（`LLMStream_test.cj:136-144`），没覆盖多 message。
- **建议**：`case 'message'` 挂载后立即 `reasoning = ''`，把 reasoning 归属「紧随其后的第一条 message」；补一条 `output` 含两组 `reasoning + message` 的用例，断言两条消息各带各的 reasoning。

### [轻微][存量] 6 个方言各写一遍 `endpoint` / `headers`，已经出现 `Accept-Encoding` 漂移

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:58-64`（`StandardDialect.endpoint`）、`:66-74`（`headers`）；`f_llm/src/llm/openai/DeepSeekDialect.cj:39-46`、`:48-56`；`f_llm/src/llm/openai/ProviderDialects.cj:38-45`、`:64-71`、`:90-97`、`:126-133`（4 份 `endpoint`）、`:145-154`（`bearerHeaders`）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28` 方言表重构）
- **判据**：review-checklist §2（换控制流 / 跨文件复制，且差异不是业务要求）
- **证据**：静态确定 —— 6 份 `endpoint` 的 Chat 分支逐行相同（`trimTrailingSlash(conf.url) + conf.option('chatPath', '/chat/completions')`），Responses 分支 4 份只改错误文案；`headers` 有 3 份（`StandardDialect`、`DeepSeekDialect`、`bearerHeaders`），前两份**没有** `Accept-Encoding: identity`，`bearerHeaders` 有，测试也只对 zhipu 断言了这一项（`ProviderDialects_test.cj:139`）。差异点清单：`Accept-Encoding`（有/无）、`Accept`（都有）、`Authorization`（都有，条件相同）
- **描述**：方言表的设计意图是"只描述差异"，但复制粘贴让"通用头"也进了每个方言。真正的风险不是行数，而是漂移：`LLMStreamTransport.cj:47` 与 `LLMTransport.cj:45` 各自补了 identity，所以流式/非流式暂时都对；但 `StandardDialect`/`DeepSeekDialect` 的 `headers()` 返回值本身不完整，任何未来直接用 `dialect.headers(conf)` 发请求的新代码（例如余额查询、`/models` 探测）都会漏掉 `Accept-Encoding`，在 gzip 响应上踩"把压缩字节当 UTF-8"的老坑（`util/http.cj:23` 的注释正是这个坑）
- **建议**：把 `endpoint` 的通用实现提到 `ProviderDialect` 的默认方法（差异用 `conf.option` 的 path 覆盖已经能表达），`headers` 统一走 `bearerHeaders`，各平台只保留 `decorate` 与"不支持的 kind 抛错"；若要保留手写，至少把 `Accept-Encoding` 补进 `StandardDialect`/`DeepSeekDialect` 并加断言

### [轻微][存量] `ResponsesMapper.build` 与 `ChatCompletionsMapper.build` 的 temperature / stream / tools 三段逐行重复，且 Responses 侧悄悄少字段

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:57-66`（temperature）、`:68-72`（stream）、`:74-89`（tools 空集合分支） ↔ `f_llm/src/llm/ChatCompletionsMapper.cj:40-49`、`:51-55`、`:66-76`
- **来源**：存量（`git blame` → `2026-10-27`，两文件同批）
- **判据**：review-checklist §2（近似重复：一块少了边界/字段）
- **证据**：静态确定 —— temperature 段（`conf.temperature >= 0 ? conf : params` 再按 `< 0` 剔除）逐 token 相同；stream 段相同；tools 段只有"元素形状"不同（Chat 是 `function.toData()` 的嵌套 `function` 对象，Responses 是扁平 `{type,name,description,parameters}`），外层"`size > 0` 就 add 否则 remove"完全相同。差异点：Responses 侧没有 `response_format` 处理，也没有 `max_tokens`（见一般第 1 条）
- **描述**：三段重复本身不难看，但它们承担的是"两条协议必须保持一致的语义"（温度优先级、stream 标志、工具空集合不发）。现在语义已经漂了（一般第 1 条）。下次再有人往 Chat 侧加一个"参数优先级"规则，Responses 侧不会跟着变
- **建议**：把"有效温度计算"抽成 `internal func effectiveTemperature(conf, params): Float64`，stream/tools 的"有则写、无则删"抽成一个 3 行的 helper；两条 `build` 只保留各自的报文骨架（Chat 用 `toData`、Responses 用白名单），并在 `build` 上方用注释列出"本协议缺失的字段"清单

### [轻微][存量] `textOfReasoning` 与 `textOfMessage` 只有字面量不同，是一份实现的两份拷贝

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:131-142`（匹配 `'reasoning_text'`）与 `:144-155`（匹配 `'output_text'`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §2（只改字面量 / 类型名的重复）
- **证据**：静态确定 —— 两个函数体逐行对齐：遍历 `content` 数组 → `asObject()` → `stringOf(item,'type') == <字面量>` → `text.append(stringOf(item,'text'))`，唯一差异是 `'reasoning_text'` vs `'output_text'`
- **描述**：两份实现意味着"content part 的解析规则"有两个真相。加一种 part 类型（例如 `output_refusal`）、或给拼接加分隔符、或改成跳过空串，都得改两处，很容易只改一处
- **建议**：合成 `private static func textOfParts(obj: JsonObject, partType: String): String`，两处分别传字面量；`'reasoning_text'` / `'output_text'` 提成模块内常量（与 `PART_TYPE_IMAGE` 同级）

### [轻微][存量] `DefaultHttpTransport.post` 与 `f_llm.util.http()` 是同一段"建客户端 + identity + TrustAll"的第二份实现

- **位置**：`f_llm/src/llm/LLMTransport.cj:40-53` ↔ `f_llm/src/util/http.cj:18-29`
- **来源**：存量（`git blame` → `d3ebac7923 2026-10-27` / 同期）
- **判据**：review-checklist §2（跨文件复制，且差异没有业务理由）
- **证据**：静态确定 —— 两者都做：`HttpClient(url)` → 逐条 `header` → `client.header('Accept-Encoding','identity')` → `TlsClientConfig()` + `TrustAll` + `tlsConfig` → `resource(client){…}`。差异只有 `http()` 把 `Authorization` / `Content-Type` / `Accept` 固化在助手里，而 transport 走 `dialect.headers(conf)` 传入的 Map
- **描述**：安全策略（TrustAll）与压缩策略（identity）现在有三份拷贝（另见 `LLMStreamTransport.cj:47-50`），严重第 1 条要求"改成可配置"时必须三处同改，漏一处就等于没修。这也是"看起来只改了一行、线上仍然降级"的典型来源
- **建议**：抽一个 `internal func newClient(url: String, headers: HashMap<String,String>): HttpClient`（统一 identity + TLS 策略），`http()`、`DefaultHttpTransport`、`DefaultStreamTransport` 全部改用它；TLS 策略从该工厂一处读配置

### [轻微][存量] `imports.cj` 里的 `UUID` 导入在整包零引用；`A2aCallFunction.cj` 的 `f_log` 导入同样未使用

- **位置**：`f_llm/src/llm/imports.cj:28`（`internal import fountain::f_util.UUID`）、`f_llm/src/loom/A2aCallFunction.cj:25`（`import fountain::f_log.*`）
- **来源**：存量（`git blame` → 2026-10 各批提交）
- **判据**：review-checklist §1（无使用的 import）
- **证据**：静态确定 —— `grep -rn "UUID" f_llm/src/llm` 只命中 `imports.cj:28` 本身；`A2aCallFunction.cj` 内 `LoggerFactory` / `log` 零出现（该文件只用 `FunctionCalling`、`FunctionResult`、`JsonStringSchema`、`@DataAssist`）
- **描述**：`imports.cj` 是包级共享导入文件，一条无用导入会长期留着（没人会去删"公共文件"）。`A2aCallFunction` 的 `f_log` 是复制 `MemoryCallFunction` 时带过来的
- **建议**：删掉这两条。`imports.cj` 里 `fountain::f_bean.*` / `fountain::f_base.*` 是否真被使用无法静态排除（前者可能为 `@Bean` 宏、后者含大量扩展方法），本次只报能确证的 `UUID`

### [轻微][存量] `ResponsesMapper.build` 有 3 处对刚创建的对象做 `remove`，是恒空的无效语句

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:62-63`（`body.remove('temperature')`）、`:71`（`body.remove('stream')`）、`:87`（`body.remove('tools')`）
- **来源**：存量（`git blame` → `2026-10-27`）
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `body` 在 `:37` 新建，到 `:62` 只 `add` 过 `model` / `instructions` / `input`，从未写入 `temperature` / `stream` / `tools`；`JsonObject.remove` 对不存在的键是 no-op，所以三个 else 分支永远不起作用
- **描述**：这三处是"从 Chat 侧照搬结构"留下的残骸（Chat 侧的 `body` 来自 `params.toData()`，确实可能有这些键，所以 remove 有意义）。读代码的人会误以为"Responses 报文里可能已经有 temperature/stream/tools 需要清"
- **建议**：直接删掉三个 else 分支（`if(stream){ body.add('stream', true) }` 即可），或加注释说明"本对象是白名单构造，不需要清理"

### [轻微][存量] `DialectRegistry.providers()` 不触发内建注册，首次调用可能返回空列表

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:151-159`（`providers()` 直接遍历 `dialects`，未调 `ensureBuiltins()`）↔ `:110-117`（`resolve()` 会调）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28`）
- **判据**：review-checklist §1（注册了但取不到 / 半成品接线）+ §11（契约与实现不符）
- **证据**：静态确定 —— 内建方言只在 `ensureBuiltins()`（`:125-147`）里写入 `dialects`，`providers()` 没有调用它；因此"进程启动后第一次调用的是 `providers()`"时返回空列表，而 `resolve('deepseek')` 之后同一调用返回 6 个
- **描述**：`providers()` 是公开 API（README `f_llm/README.md:900` 登记），语义应当是"当前可用的 provider 全集"。它对调用顺序敏感，会做出"没有任何 provider"的错误判断（例如管理页下拉框为空、启动自检误报）
- **建议**：`providers()` 首行加 `ensureBuiltins()`；补一条用例：新进程里先调 `providers()` 断言包含 `deepseek`/`zhipu`/`volcengine`/`aliyun`/`siliconflow`/`openai`

### [轻微][存量] `LoomA2a` 先置 `started` 再注册：注册失败或 `reset()` 后重入会留下"已启动但不可达"的状态

- **位置**：`f_llm/src/loom/A2aBridge.cj:91-109`（`:91-96` 置 `started=true` 并释放锁，`:105-106` 在锁外 `server.register()`，`:107-109` 才写 `lastServer`）、`:122-127`（`reset()` 只复位标志、不注销方法）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入跨锁、发布逸出）+ §11（资源/状态不对称）
- **证据**：静态确定（并发时序部分为待确认）—— ①置位与注册分属两个临界区，中间的失败（`A2aServer` 构造抛异常）不会被回滚，之后 `startIfEnabled()` 永远命中 `:92-94` 返回 `true`，但 `server()` 是 `None`；②`A2aServer.register()` 内部用 `safeRegister` 吞掉 `JsonRpcException`（`f_a2a/src/server/A2aServer.cj:184-190`），所以 `reset()` 后再 `startIfEnabled()` 会建出第二个 `A2aServer` 并把它的 9 个方法静默注册失败——`started` / `lastServer` 指向新实例，实际处理请求的是旧实例的 handler（任务存在旧实例里，`server()` 却给出新实例）
- **描述**：`reset()` 的注释已声明"不注销已注册的方法"，所以这条是"已知限制"而非意外；但公开 API 的组合（`reset` + `startIfEnabled`）会产生**看着成功、实际不生效**的状态，且只在测试里被用到。真正需要关注的是第一个窗口：如果 `A2aServer` 构造或 `register()` 抛异常，启动流程会得到一个永久"已启用"的假象
- **建议**：把 `started = true` 移到 `register()` 成功之后（失败则复位并重新抛出）；`reset()` 若要保留，改名 `resetForTest()` 并在内部断言仅有测试调用，或干脆去掉 `started` 标志改为"`lastServer.isSome()` 即已启动"

### [轻微][存量] Responses 流式不转发推理增量，与 Chat 流式的 `LLMDeltaKind.Reasoning` 不对称

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:50-75`（只处理 `response.output_text.delta` / `completed` / `failed` / `error`）↔ `f_llm/src/llm/ChatStreamAccumulator.cj:90-97`（`reasoning_content` / `reasoning` 都会产出 `LLMDeltaKind.Reasoning`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名/同族实现不符）
- **证据**：静态确定 —— `feed` 的 match 里没有 `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` 之类分支，`LLMDeltaKind.Reasoning` 在整个文件零出现；最终结果不受影响（`response.completed` 里带 reasoning，`ResponsesMapper.parse` 会挂到 `AssistantMessage.reasoningContent`）
- **描述**：同一个 `respondStream` 回调在 Chat 下能收到思考过程（前端可展示"正在思考"），在 Responses 下全程静默到结束才一次性出现。用户感知是"换了 platform 就没有思考过程"，而这是协议实现差异，不是模型能力差异。顺带：README 的成员清单只登记了 `feed` / `finished` / `isDone`（`f_llm/README.md:1018`），`public func result()` 未登记，一并补
- **建议**：补 `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` 分支，返回 `LLMDelta(LLMDeltaKind.Reasoning, delta)`；若上游事件名不确定，至少在类注释里写明"Responses 流式不转发 reasoning，原因：…"；README 成员清单补 `result`

### [轻微][存量] Responses 解析不填 `usage.cached`，同一份 `TokenUsage` 在两条协议下含义不同

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:121-126`（只取 `input_tokens` / `output_tokens` / `total_tokens`）↔ `f_llm/src/llm/ChatCompletionsMapper.cj:194-201`（额外取 `prompt_tokens_details.cached_tokens`）
- **来源**：存量（`git blame` → 2026-10-27 两文件同批）
- **判据**：review-checklist §2（近似重复：一块少了字段）
- **证据**：静态确定 —— `TokenUsage` 有 `cached` 字段（`ChatCompletionsMapper.cj:199`、`ChatStreamAccumulator.cj:161` 都在写），Responses 的非流式与流式（`ResponsesStreamAccumulator.cj:86-92`）都不写，恒为 0；Responses 协议里的对应字段是 `usage.input_tokens_details.cached_tokens`
- **描述**：按 `usage.cached` 统计"缓存命中省了多少钱"的报表会在 Responses 路径上恒为 0，看起来像"完全没命中缓存"，进而误导 prompt 结构优化。金额口径问题不会报错，只会长期偏差
- **建议**：`ResponsesMapper` 里补 `input_tokens_details.cached_tokens` 的读取；把 `fillUsage` 从 `ChatCompletionsMapper` 提成共享函数，两个协议各自传字段名映射，避免第三次漂移

### [轻微][存量] 测试直接改全局传输/方言注册表且不复位，用例之间会互相污染

- **位置**：`f_llm/src/llm/LLMStream_test.cj:163`、`:186`（`LLM.setStreamTransport(transport)`）、`f_llm/src/llm/LLM_test.cj:78,91,102,117,132`（`LLM.setTransport(...)`）、`f_llm/src/llm/openai/ProviderDialect_test.cj:95,102`（`DialectRegistry.register(...)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源不对称 / 隐式全局依赖）
- **证据**：静态确定 —— `LLM.transport` / `streamTransport` 是 `static var`（`LLM.cj:38-39`），测试只写不还原；`DialectRegistry.dialects` 同理（`ProviderDialect.cj:90`）。`ProviderDialect_test.cj:102` 还注册了 `fake-dup`，同一进程内重复执行该用例会变成"第一次 register 就抛"
- **描述**：这些用例单独跑都过，但组合/重跑时会命中别的用例留下的假传输或已注册方言（尤其 `testDuplicateRegisterThrows` 与 `testRegisterAndResolve` 共享 `dialects`）。缺 `@AfterEach` 还原，失败现象会随执行顺序变化
- **建议**：给 `LLM` 加 `internal func resetTransportForTest()`、给 `DialectRegistry` 加 `internal func clearForTest()`，在 `@AfterEach` 里复位；或把 `setTransport` 收窄为接受 `LLMTransport` 的调用级参数

### [轻微][存量] `trimTrailingSlash` 后 base 可能变成空串/相对路径，`conf.url` 缺失时不会在拼端点阶段报错

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:79-85`（`trimTrailingSlash`）、`:58-64`（`endpoint` 直接 `base + path`）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28`）
- **判据**：review-checklist §11（边界 / 空值未处理）
- **证据**：静态确定 —— `LLMConf.url` 默认是 `''`（`model/po/LLMConf.cj:50` 附近），`trimTrailingSlash('')` 返回 `''`，`endpoint` 于是给出 `'/chat/completions'`；`conf.url = '/'` 同样收敛成 `''`。这个字符串会一路传进 `HttpClient(url)`，抛的是 URL 解析层的异常，在 `LLM.call` 里被当成"可重试传输失败"→ 换下一个候选，最终报"no llm candidate available"，掩盖真正原因（配置缺 url）
- **描述**：配置错误与网络错误被归为同一类，运维只能靠翻 provider 名字猜。同类问题还有一条更明确的：`ZhipuDialect/VolcengineDialect/AliyunDialect/SiliconFlowDialect.endpoint` 对 `LLMApiKind.Responses` 抛 `IllegalArgumentException`（`ProviderDialects.cj:43/69/95/131`），而 `endpoint` 的调用点在 `LLM.call` 的 `try` 内（`LLM.cj:145-146`）、`LLM.stream` 的 `try` 内（`LLM.cj:231-233`），异常会被 `catch(e: Exception)` 包成"llm transport failed"并调用 `hooks.onRetryableFailure(conf.id)`——一次「provider 不支持该 API」的配置错误会推高该平台的熔断计数、并浪费一次对其他平台的真实请求，最终异常文案也丢掉了「不支持 responses api」这条唯一有用的信息。`trimTrailingSlash` 本身是 `while + 逐字符切片`，`https://x///` 这种输入会做 O(n²) 的字符串拷贝，但只在启动路径上出现，不构成性能问题
- **建议**：在 `endpoint` 开头校验 `conf.url` 非空且含 `://`，否则抛 `IllegalArgumentException('llm url is empty, provider=…, llm=…')`（不可重试，直接暴露配置错误）；同时把 `dialect.endpoint(...)` / `headers(...)` 移到 `LLM.call`/`LLM.stream` 的 `try` 之外（或在 `catch` 里 `if(e is IllegalArgumentException){ throw }`），让配置错误不计入熔断；`trimTrailingSlash` 改成 `url.trimEnd(c: '/')` 之类的单趟实现

### [轻微][存量] 启发式 token 计数只看 `content`，工具调用参数与多模态 parts 完全不计数

- **位置**：`f_llm/src/llm/TokenCounter.cj:44-50`（`HeuristicTokenCounter.count` 只累加 `message.content`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（估算口径与实际报文不符）
- **证据**：静态确定 —— `ChatMessage` 家族的体积不只 `content`：`ToolCallMessage.tool_calls[].function.arguments`（单次可达数十 KB，工具结果上限就配到 64KB，`LLMConfig.cj:196-199`）、`ToolMessage` 的 `content`、`ContentPart.imageUrl`（base64 data URL 可达 MB 级）都不进计数
- **描述**：`HeuristicTokenCounter` 被 `LLMConfsHolder.saturated`（`LLMConfsHolder.cj:139-146`）与 `ContextPrunerMediator`（`ContextPruner.cj:186`）用来判断"上下文是否已到阈值"。工具密集或多图会话里真实 prompt 远大于估算值 → 判定"没饱和"→ 不裁剪 → 上游 400（context_length_exceeded），而熔断计数把它当致命错误直接抛出
- **建议**：计数时把 `tool_calls[].function.{name,arguments}`、`parts[].text`、`parts[].imageUrl` 的长度一并算进去（图片按固定 token 估值或按 base64 长度/4 粗估）；在 `count` 的注释里明确"这是下界估计"，并让 `saturated` 用 `> threshold * 0.9` 之类的安全裕度

### [轻微][存量] 流式归并对非 JSON 的 `data` 没有守卫，空事件会让整条流失败并触发换平台

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:49`（`JsonValue.fromStr(data).asObject()`）；同一模式：`f_llm/src/llm/ChatStreamAccumulator.cj:63`（范围外，仅作对照）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（异常路径未处理）+ §3（兜底把协议噪声变成致命错误）
- **证据**：静态确定（触发条件为待确认）—— `JsonValue.fromStr('')` / 非法 JSON 会抛 `JsonException`（`f_data/src/json/JsonValue.cj:27-80` 的 `asObject` 只在类型不符时抛，`fromStr` 对空串抛解析异常）；而 `SseReader.next()` 只要块里出现过任一字段（包括只有 `event:` / `id:` 的块）就会返回事件，`joinData` 对无 data 的块返回 `''`（`f_httpclient/src/sse/SseReader.cj:90-135`）。`data=''` → `fromStr` 抛 → 异常穿透 `DefaultStreamTransport` 的 `while` → 被 `LLM.stream` 的 `catch(e: Exception)` 当成传输失败 → 换下一个平台（已推送的增量重复）
- **描述**：OpenAI 兼容端点通常只发 `data:`，但 `event:` 前缀块、厂商心跳、代理注入的注释外文本都会命中。一旦命中，本可忽略的一行会变成"整条回答重来一遍"（并且用户已经看到半截输出）。当前所有测试都只喂合法 JSON（`LLMStream_test.cj:27-32`），覆盖不到
- **建议**：`feed` 里先判 `data.trimAscii().isEmpty()` 直接返回 `None`，再用 `try { JsonValue.fromStr } catch { return None }` 跳过非法行（可选记一次 debug 日志计数）；补一条用例：喂 `''`、`'event: ping'`、`'{bad'` 三个事件，断言流继续且 `result()` 正常

### [轻微][存量] `response.failed` 读的是顶层 `message`，而该事件的错误在 `response.error.message`

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:62-67`
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（字段路径与协议不符，导致错误信息丢失）
- **证据**：待确认 —— 代码只在顶层取 `stringOf(json,'message')`，取不到就退化成常量 `'response.failed'`；同文件 `case 'error'`（`:68-73`）才是顶层带 `message` 的事件形态。缺的信息：Responses 流式 `response.failed` 事件的真实报文（本地无规范文档，本次也无法联网核对），以及 DeepSeek `/responses` 实测样例
- **描述**：如果 `response.failed` 确实把错误放在 `response.error.{code,message}`，那当前实现永远拿不到上游原文，抛出的异常只剩 `responses stream failed: response.failed` —— 排查"为什么这次没答完"时没有任何线索（对比非流式路径会把 400 的 body 截断 400 字节带进异常，`LLM.cj:155`）
- **建议**：`case 'response.failed'` 时优先读 `json.get('response').asObject().get('error').asObject()` 的 `code`/`message`，取不到再退回顶层 `message`；把成功/失败两种形态都写成 fixture 用例

### [轻微][存量] 模型名「归一」对大小写变体不成立，能力表把 `DeepSeek-Flash` / `Embedding-3` 判成可开关

- **位置**：`f_llm/src/llm/ModelCapabilities.cj:42-48`（`ModelNames.normalize` 的结果直接与常量比较）；根因：`f_llm/src/constant/ModelNames.cj:35-45`（默认分支 `case _ => trimmed` 返回**未小写**的原串，属范围外文件）
- **来源**：存量
- **判据**：review-checklist §11（注释承诺「模型名先归一到框架常量」，在变体上不成立）
- **证据**：静态确定 —— `normalize` 用 `match(trimmed.toAsciiLower())` 匹配，但兜底返回 `trimmed`；`ModelCapabilities.resolve` 用 `== MODEL_NAME_DEEPSEEK_FLASH`（`'deepseek-flash'`，大小写敏感）。故 `'DeepSeek-Flash'` / `'Embedding-3'` 落不进能力表，走 `ThinkingMode.Toggle`
- **描述**：手填配置或聚合平台返回的大小写变体会让「恒思考模型不带 `temperature`」失效 → 报文继续带 `temperature`（被忽略或 400），`embedding-3` 的 `None` 也失效 → 仍可能被塞思考字段。现有用例全用小写或带平台前缀（`ModelCapabilities_test.cj:43-50`、`ModelNames_test.cj:28`），掩盖了裸名变体。
- **建议**：`normalize` 兜底返回 `trimmed.toAsciiLower()`（注释里写清「不改 `conf.actualLlmName` 发出的原值」），或 `resolve` 侧统一小写后再比；补 `'DeepSeek-Flash'` / `'Embedding-3'` 两条断言。

## 优化可行性方案

### [CPU] 复用 HTTP 客户端（连接池）替代"每请求一次 TCP+TLS 握手"

- **现状**：`DefaultHttpTransport.post`（`f_llm/src/llm/LLMTransport.cj:41`）与 `DefaultStreamTransport.stream`（`LLMStreamTransport.cj:43`）每次调用都 `new HttpClient(url)`，且 `HttpClient.send` 内部每次都 `builder.build()`（`f_httpclient/src/httpclient.cj:133-137`），`close()` 后不可再用 —— 结构上无法复用连接。对 https 端点即"每次 LLM 调用 = 一次 TCP 三次握手 + 一次 TLS 握手"；`LLM.call` 在候选间 failover 时还会再来一次
- **方案**：以 `baseUrl + 鉴权头` 为 key 缓存 `Client`（stdx `Client` 自带连接池），或用 `ClientBuilder.poolSize` 建长驻实例；`LLMHttpResponse` 只保留状态码+body，客户端生命周期上移到 `LLM` 或 transport 的单例
- **预期**：未实测。按"每次省一次 RTT+TLS 握手"估算，单次 chat 调用的固定开销可下降一个握手量级；对短请求（余额查询、`/models`）收益占比更大
- **代价**：需要处理连接失效重试、dns 变更、`close()` 生命周期；`TlsClientConfig` 变成共享对象后不能再按请求改（与严重第 1 条的可配置化要一起设计）
- **验证**：`cjprof record`（看 TLS/socket 相关栈占比）+ 分段计时（connect 完成 / 首字节 / 结束）在 1/10/50 并发下前后对照，`-O2`，中位数与 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `RemoteTokenCounter` 为一次计数把整段会话拼成两份全量字符串

- **现状**：`TokenCounter.cj:66-75`：先把全部 `message.content` 追加进一个 `StringBuilder`，再 `prompt.toString()`（第 1 份完整副本），随后作为 `body.add('prompt', …)` 的值进入 `JsonObject` 序列化（第 2 份，`body.toString()`），最后 `response.readEntire()` 再物化响应体。生命周期只有一次 HTTP 往返，但峰值是"prompt × 2 + 响应"
- **方案**：①按 `llm_toolResultMaxBytes` 同口径给 remote 计数输入设上限（超限直接返回 -1，让调用方退回 heuristic）；②或改为"只对有阈值的头部/尾部消息计数"，不必拼全量
- **预期**：未实测。上限落地后单次峰值从 O(全部消息) 降到 O(上限常量)，具体字节量取决于真实会话长度
- **代价**：估算语义变化（截断后计数偏小），需要与 `saturated` 的 0.9 裕度一起调；`RemoteTokenCounter` 目前只有测试调用，收益仅在未来接入时体现
- **验证**：`getAllocatedHeapSize()` + RSS 在 100 条/400 条工具结果的会话下前后对照，同时断言 `count` 返回值不变（未超限时）
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求新建 `HttpClient` 导致 TLS 握手占单次 LLM 调用延迟的可观比例 | `f_llm/src/llm/LLMTransport.cj:41` | connect/TLS 阶段耗时与总耗时占比 | 分段计时（DNS/connect/TLS 完成/首字节/读完）跑 100 次 `chat`，与复用 `Client` 的实现对照 |
| 2 | `DialectRegistry.get` 的全局 `Mutex` 在并发调用下成为串行点 | `f_llm/src/llm/openai/ProviderDialect.cj:103-107` | 锁等待时长、BLOCKED 线程数 | `cjprof` 看不到锁，需线程状态采样 + 把 `resolve` 预热成不可变快照后对照吞吐 |
| 3 | `ResponsesMapper.build/parse` 的 `JsonObject` 图（每条消息 2-4 个对象）是短生命周期分配热点 | `f_llm/src/llm/ResponsesMapper.cj:36-128` | 单位调用分配字节数、GC 次数 | `cjprof heap` 对比 1k 条历史消息的 `respond` 调用，配合 `getAllocatedHeapSize()` |
| 4 | `HeuristicTokenCounter` 的 字节/3 估值与真实 `usage.prompt` 偏差导致裁剪阈值失效 | `f_llm/src/llm/TokenCounter.cj:44-50` | 估算值与上游 `prompt_tokens` 的比值分布（含工具/多图样本） | 在 `CallLogger` 里同时记录估算值与真实 usage，跑 1 周真实会话后看 P50/P95 比值 |
| 5 | Responses 流式缺 `response.completed` 的截断率 | `f_llm/src/llm/ResponsesStreamAccumulator.cj:79-93` | 线上 `finish` 为空/`response.completed` 缺失的请求占比 | 加计数埋点（`finishReason.isEmpty()` 且 `kind=Responses`），跑 24h |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/llm/LLMStream_test.cj` | .cj | ✅ | 流式归并/门面用例；全局 transport 不复位（轻微第 11 条），无非法 JSON 用例（轻微第 14 条） |
| 2 | `f_llm/src/llm/LLMTransport.cj` | .cj | ✅ | `TrustAll`（严重第 1 条）、无显式超时（一般第 4 条）、与 `util.http` 重复（轻微第 4 条） |
| 3 | `f_llm/src/llm/LLM_test.cj` | .cj | ✅ | 非流式门面用例；setTransport 不复位（轻微第 11 条）。`FakeTransport` 在 `statuses/bodies` 为空时取 `size-1` 会越界，但仅测试桩内部、不构造空列表，未计入 |
| 4 | `f_llm/src/llm/ModelCapabilities.cj` | .cj | ✅ | 三级解析顺序与方言分工正确；`blocksTemperature` 仓内只有测试引用（对外 public，按硬原则一不判死代码）；模型名大小写变体不归一（轻微第 16 条） |
| 5 | `f_llm/src/llm/ModelCapabilities_test.cj` | .cj | ✅ | 7 个用例覆盖配置覆盖/模型表/方言落字段，与实现一致；无问题 |
| 6 | `f_llm/src/llm/ResponsesMapper.cj` | .cj | ✅ | 丢 `max_tokens`/`response_format`（一般第 1 条）、`status=failed` 当成功（一般第 2 条）、reasoning 跨 `output` 项不清零（一般第 7 条）、重复段（轻微第 2、3 条）、no-op remove（轻微第 6 条）、`cached` 缺失（轻微第 10 条） |
| 7 | `f_llm/src/llm/ResponsesStreamAccumulator.cj` | .cj | ✅ | 截断当成功（一般第 3 条）、不转发 reasoning（轻微第 9 条）、JSON 无守卫（轻微第 14 条）、`response.failed` 字段路径（轻微第 15 条） |
| 8 | `f_llm/src/llm/TokenCounter.cj` | .cj | ✅ | `HeuristicTokenCounter` 口径缺陷（轻微第 13 条）、`RemoteTokenCounter` 全量拼接（优化方案 2）；`catch(_: Exception) → -1` 是注释声明的契约，不判空实现。信息项：全仓只有 `ContextPruner_test.cj:200` 用 `RemoteTokenCounter`，生产裁剪固定走 `HeuristicTokenCounter`（`ContextPruner.cj:186`、`LLMConfsHolder.cj:145`），故 `conf['tokenizerUrl']` 在框架内不生效——如需「配置即生效」需按 §14.1 另行接线（未计入本部分统计） |
| 9 | `f_llm/src/llm/TokenizerParams.cj` | .cj | ✅ | 纯数据载体，仓内零引用（对外 public + README 索引已登记，按硬原则一只记信息） |
| 10 | `f_llm/src/llm/advanced_params.cj` | .cj | ✅ | `DoSample` 空 setter（一般第 6 条）；`FrequencyPenalty`/`ThinkingBudget` 仓内零引用（对外 public，只记信息） |
| 11 | `f_llm/src/llm/imports.cj` | .cj | ✅ | `UUID` 未使用（轻微第 5 条）；其余导入有跨文件使用（`Mutex`/`ConcurrentHashMap`/`MonoTime`/`LoggerFactory`/`f_data` 均已逐符号核对） |
| 12 | `f_llm/src/llm/openai/DeepSeekDialect.cj` | .cj | ✅ | `endpoint`/`headers` 复制（轻微第 1 条）；`decorate` 只剥思考字段，与 `ThinkingPolicy` 分工一致 |
| 13 | `f_llm/src/llm/openai/DeepSeekDialect_test.cj` | .cj | ✅ | 4 个用例；复用 `ProviderDialect_test.cj` 的 `mkConf`（同包跨文件依赖，未单独计问题） |
| 14 | `f_llm/src/llm/openai/ProviderDialect.cj` | .cj | ✅ | 6 份 `endpoint` 模板（轻微第 1 条）、`providers()` 不触发内建注册（轻微第 7 条）、`trimTrailingSlash` 空 base（轻微第 12 条）；无 `protected` 声明；`ensureBuiltins` 双重检查读 `builtinsLoaded` 已在推理中排除误报（`dialects` 的读写全在锁内，快路径只会多拿一次锁） |
| 15 | `f_llm/src/llm/openai/ProviderDialect_test.cj` | .cj | ✅ | 注册/回退用例；注册表污染（轻微第 11 条） |
| 16 | `f_llm/src/llm/openai/ProviderDialects.cj` | .cj | ✅ | 4 个方言 + `bearerHeaders`（轻微第 1 条）；`applyThinkingObject` 三分支与 `ThinkingPolicy` 无重复 |
| 17 | `f_llm/src/llm/openai/ProviderDialects_test.cj` | .cj | ✅ | 8 个用例，覆盖 Responses 不支持与思考字段形态；只对 zhipu 断言 `Accept-Encoding`（正是漂移未被发现的原因） |
| 18 | `f_llm/src/loom/A2aBridge.cj` | .cj | ✅ | 卡片硬编码（一般第 5 条）、`started` 先置位（轻微第 8 条）；`map` 的四类 outcome 映射与注释一致 |
| 19 | `f_llm/src/loom/A2aBridge_test.cj` | .cj | ✅ | 11 个用例；`testStartIsIdempotent` 只断言 `registrationCount`，未覆盖 `reset` 后重注册的实际可达性（轻微第 8 条） |
| 20 | `f_llm/src/loom/A2aCallFunction.cj` | .cj | ✅ | `call` 的 url 校验/异常转文本符合注释契约；`f_log` 未使用（轻微第 5 条） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 安全性 1（严重第 1 条）、正确性 3（一般第 2、3、7 条）、契约/设计 2（一般第 1、5 条）、边界 1（轻微第 12 条）、语言特性 1（一般第 6 条 `mut prop` 默认实现语义）、归一/大小写 1（轻微第 16 条）。语言特性另核对：`return` 位于 `match` 分支内确实从函数返回（`ResponsesStreamAccumulator.feed:55`、`ChatStreamAccumulator.mergeDelta:88`），故两处 `feed` 的尾 `None` 不是死语句；`JsonValue.asObject/asArray` 类型不符会抛 `JsonException`（`f_data/src/json/JsonValue.cj:56-80`），故"缺守卫"类判断按抛异常而非静默处理 |
| §1 死代码 | 2 | 逐个符号核对：本部分只有 8 个包级/`private` 函数（`ResponsesMapper.textOfReasoning/textOfMessage/contentOf/messageToJson`、`ProviderDialect.trimTrailingSlash`、`ProviderDialects.bearerHeaders/applyThinkingObject/setThinkingType`），全部有调用者（含 `trimTrailingSlash` 被 5 个方言调用）；`DialectRegistry.ensureBuiltins` 被 `resolve` 调用；无 `internal`、无 `protected` 声明；`public` 顶层类型（`LLMHttpResponse`/`LLMTransport`/`DefaultHttpTransport`/`ModelCapabilities`/`ThinkingPolicy`/`ResponsesMapper`/`ResponsesStreamAccumulator`/`TokenizerParams`/`TokenCounter` 家族/`ProviderDialect` 家族/`LoomA2a` 家族/`A2aCallFunction`/`A2aCallParam`/`SupervisorAgent`）按硬原则一不判——`TokenizerParams`、`FrequencyPenalty`、`ThinkingBudget`、`DoSample`、`DialectRegistry.providers`、`ModelCapabilities.blocksTemperature`、`LoomA2a.server/reset` 仓内零引用（或仅测试引用），已在文件覆盖表记为信息、不计问题。命中 2 处：未使用 import（第 5 条）、`build` 里 3 个 no-op `remove`（第 6 条）。各文件 `return`/`throw` 后无同层语句 |
| §2 重复逻辑 | 5 | 同文件内两两比对（`ResponsesMapper` 6 个函数、`ProviderDialects` 5 个 `endpoint` + `bearerHeaders`/`applyThinkingObject`/`setThinkingType`、`TokenCounter` 2 个实现、`A2aBridge` 3 个类）：命中 `textOfReasoning`/`textOfMessage`（第 3 条）。跨文件按相同语句/字面量搜 `trimTrailingSlash(conf.url)`、`'Bearer ${conf.auth}'`、`'application/json'`、`Accept-Encoding`、`effective < 0.0f64`、`body.remove('thinking')`：命中方言 `endpoint`/`headers`（第 1 条）、两个 mapper 的 temperature/stream/tools（第 2 条）、`util.http` 与 `DefaultHttpTransport`（第 4 条）、`usage.cached` 缺失（第 10 条）。判定为非重复：`AliyunDialect.decorate` 与 `applyThinkingObject`（字段形态完全不同）、`Chat`/`Responses` 的工具定义（线上形状不同，属协议要求）、`DeepSeekDialect.decorate` 与 `SiliconFlowDialect.decorate`（函数体恰好相同，但分属两个独立演进的平台方言，合并会把"某平台多剥一个字段"变成改共享函数，按误报边界保留——它们的模板重复已由第 1 条覆盖） |
| §3 空实现 | 1 | `DoSample.set(value){}`（一般第 6 条）。`StandardDialect.decorate` 空函数体有注释声明"默认什么都不做"，属有意的 Null Object，不判；`RemoteTokenCounter` 的 `catch(_: Exception) → -1` 与类注释「没配、失败、无 usage 都返回 -1」一致，是显式契约不是吞异常；无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归（无函数自调用、无树/图遍历）；`trimTrailingSlash` 是单层 `while`，`ResponsesMapper` 的嵌套只有 `for output[] → for content[]` 两层，深度由单条报文固定 |
| §5 OOM | 0 | 没有按不可信长度预分配（`Array(n)` 只出现在 `SseReader`，范围外）；`LLMHttpResponse.body` 是单个响应体（上界由模型输出决定）；`RemoteTokenCounter` 的全量拼接是"两份会话副本"，量级受上下文窗口约束，未量化前只写进优化方案 2 与待验证假设，不作缺陷 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；"每请求 TLS 握手""全局锁"已列入待验证假设 1-2 与优化方案 1，不作缺陷、不计严重度 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `DialectRegistry.mutex`（`ProviderDialect.cj:89`），临界区内只有 `HashMap.contains/get/赋值` 与 5 次 `new Dialect()`（`ensureBuiltins` 内、一次性），无 I/O、无解析、无回调；不在 §6.2 的可报形态内，竞争比例见待验证假设 2 |
| §6.3 并发串行 | 0 | 无 `spawn`、无批处理、无单消费者队列；`LoomA2a` 是启动期一次性注册 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `remove(at: 0)`、无循环内字符串 `+`（`StringBuilder` 用得正确）；`trimTrailingSlash` 对多斜杠是 O(n²) 但输入是配置常量，不构成可报项 |
| §7 降堆内存方案 | 1 | `RemoteTokenCounter` 双份全量 prompt（无基线，待验证） |
| §8 降 CPU 方案 | 1 | HTTP 客户端复用（无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分"函数内创建的大对象"只有 `ResponsesMapper.build` 的 `JsonObject` 图与 `textOfMessage` 的 `StringBuilder`，两者都作为返回值/成员逃逸（`build` 返回 `JsonObject` 交给 `body.toString()`，`textOf*` 返回 `String` 存进消息），`@ local!` 无法生效；`estimateTokens` 只有 1 个 `String` 参数读取，无临时大对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 24 | 本轮 20 个文件逐函数核对边界/空值/错误处理/资源/契约，24 条全部为存量缺陷（严重 1 + 一般 7 + 轻微 16），其中 18 条以 §11 为主要判据、6 条以 §1/§2/§3/§12/§14 为主要判据但同时是存量问题。另核对了 4 处"疑似但非缺陷"：`ensureBuiltins` 快路径裸读 `builtinsLoaded`（`dialects` 的读写全在锁内，最坏只是多拿一次锁，不构成可见性缺陷）、`StandardDialect.decorate` 空实现（有注释的 Null Object）、`RemoteTokenCounter` 吞异常（注释声明的 -1 契约）、`ResponsesMapper.parse` 用 `status` 当 `finishReason`（下游只用于日志，`CallLogger.cj:37`，非契约破坏） |
| §12 并发安全与锁粒度 | 1 | 轻微第 8 条（`started` 与 `lastServer` 分处两个临界区、注册在锁外）。其余：`DialectRegistry` 的 `dialects` 所有读写都在 `mutex` 内（`register`/`get`/`ensureBuiltins`/`providers`），无共享可变状态逃逸；`LLMTransport`/`ResponsesMapper` 都是无状态 struct/新建对象，可并发调用；`LoomA2aClient.send` 是闭包里的局部对象，线程封闭 |
| §14 功能完备性与 README 覆盖 | 2 | 一般第 1 条（Responses 映射缺 `max_tokens`/`response_format`，属"承诺同一 `LLMParams` 契约但只做一半"）、一般第 5 条（A2A 卡片未按 spec 从配置拼出）。README 覆盖：本部分全部公开类型都已进 `f_llm/README.md:864` 的模块清单，`DialectRegistry`/`LoomA2a`/`ModelCapabilities`/`ResponsesMapper` 在 `:900/:956/:986/:1017` 有成员级清单；唯一遗漏是 `ResponsesStreamAccumulator` 的 `public func result()` 未登记（`:1018` 只有 `feed/finished/isDone`），已并入轻微第 9 条、不单列计数 |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part13.txt` 共 20 行、全部为 `.cj`，`.md` 为 0，故 §13「文档与代码一致性」在本部分没有独立 `.md` 取证对象；只按 `.cj` 注释核对（`ResponsesMapper` 顶部三条结构差异、`ProviderDialects` 各平台思考规则、`A2aCallFunction` 的"不抛异常"契约）均与实现一致。承诺源取自范围外的 `doc/spec/add-loom-a2a/proposal.md`、`f_llm/README.md`，仅作判据引用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 16 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

> 存量缺陷 24 条（严重 1 + 一般 7 + 轻微 16），是否纳入修复待用户决定；本部分未做任何源码修改。

## 总评

本部分是"LLM 客户端契约层"：传输抽象、思考能力/策略、两套协议的报文与流式归并、token 计数、平台方言表、A2A 桥。整体结构是清楚的——`LLMTransport` / `LLMStreamTransport` 把网络隔离出来（测试确实能脱离网络跑），方言表把"报文长什么样"和"模型支不支持思考"分开了（`ThinkingPolicy` 在 `decorate` 之后执行，顺序正确），Responses 的两处协议差异（`instructions`、扁平工具、`output[].type` 分派）也都在 mapper 里消化掉了，没有散到调用方。

真正需要先处理的是**安全问题而不是性能问题**：唯一阻塞项是严重第 1 条——传输层把 TLS 证书校验无条件关成 `TrustAll`，而报文头就是明文 API Key + 完整模型应答，且这段代码有三份拷贝、没有任何配置开关。它不是"内网自签证书的兼容手段"（没有 host 判断），也不是文档化的已知限制；建议与"超时显式化"（一般第 4 条）一起做，因为两者都要改同一个客户端构造点，顺手就能把三处重复（轻微第 4 条）收敛掉。

第二类是 **Responses 路径的契约漂移**：一般第 1、2、3、7 条加上轻微第 9、10、15 条，全部集中在"Chat 有、Responses 没有或者读错位置或错挂"。`respond`/`respondByName` 目前在仓内没有生产调用方（只有测试），所以这些不会立刻炸线上；但一旦下游按 README 的"Responses 风格接口"接入，表现会是"不报错、结果不对"：参数不生效、失败当成功、半截图当完整答案、token 账单口径不一致、reasoning 串到下一条消息。这类问题建议一次性补齐，并加一组"同一 `LLMParams` 双协议字段对照"的用例，而不是逐条修。

第三类是复制粘贴带来的维护成本（轻微第 1-4、6、10 条）：6 份 `endpoint`、3 份 `headers`、两个 mapper 的三段同构逻辑、两处 HTTP 客户端构造。它们现在只有 `Accept-Encoding` 一处真实漂移，但正是这些拷贝让"改一处安全策略"变成"改三处、漏一处"。按收益排序，先收敛 HTTP 客户端构造（同时修严重第 1 条），再收敛方言 `endpoint`/`headers`。

其余轻微项（`providers()` 顺序敏感、A2A 卡片硬编码、`DoSample` 空 setter、模型名归一漏大小写、token 估算盲区、流式 JSON 守卫、测试全局状态）都是"小改动、低风险、可排期"的清理项，不影响主链路正确性。两条优化方案（HTTP 客户端复用、remote 计数去全量拼接）都没有基线数据，按要求只作为下一轮补测清单，不进修复任务。

**结论**：严重第 1 条必须修（凭据暴露面）；一般第 1/2/3 条建议同批修（Responses 契约与静默失败）；一般第 4 条需先补 stdx 默认超时的确认再定改法；其余可排期。

## 范围外提示

- `f_llm/src/llm/LLM.cj:248-254`：流式 failover 在已经向 `onDelta` 推送过部分增量后直接换下一个候选，用户会看到"A 的前半段 + B 的完整回答"拼接；且 `ResponsesStreamAccumulator.result()` 抛出的 `LLMException`（`LLM.cj:267`）不在 try 内，会直接冒泡而不换平台。属 `LLM.cj`（其它子轮）。
- `f_llm/doc/spec/f-llm-openai-compat/design.md:197-203` 仍写着 `LLM.chat(req: LLMRequest)` / `ThinkingCapability` / `OpenAIContext` 等已不存在的 API 与类型，与当前 `call(candidates, params, hooks)` 实现不一致；同一文件 `:178` 的"手拼 JsonObject"只对 Responses 成立（Chat 已改 `toData`）。
- `f_llm/README.md:784` 把 `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` 的默认值写成"无"，代码默认是 120s / 1MB（`LLMConfig.cj:176-187`）。
- `f_llm/src/util/http.cj:18-29` 的 `http()` 助手与 `LLMTransport` 同根因（TrustAll），本报告已并入严重第 1 条的位置列表，不重复计数。
