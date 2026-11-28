# f_llm 模块审查报告（第 11/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（**本报告为模块第 11/25 部分**，只覆盖 `files/f_llm.part11.txt` 的 20 个 `.cj` + 0 个 `.md`：`src/exception/*`（3 个）、`src/finder/*`（10 个，含 `imports.cj`）、`src/llm.cj`、`src/llm/{CallLogger, ChatCompletionsMapper, ChatCompletionsMapper_test, ChatCompletionsResponse_test, ChatMessage}.cj`；其余 24 个子轮的结论不在本报告统计内）
- **基线**：工作区快照（`sts/1.3.x` 工作区，`git status` 仅剩未跟踪的 `docs/review/`、`reviews/`，无 diff 可比 ⇒ 所有问题来源一律记「存量」；`git blame` 只作提交依据）
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 11/25 部分）

## 发现

本部分主体是「请求报文构造 / 响应解析 / 调用日志」三件事，外加 `finder` 的 10 个 SPI 接口与 3 个异常类。请求构造是**纯函数、无阻塞 I/O、无锁**（`ChatCompletionsMapper.build` 只操作局部 `JsonObject`，`build` 的输入 `LLMParams` 不被改写），并发面干净；`finder` 接口由工具层统一 `lookup<XxxFinder>()` 注入实现（`AgentTask.cj:108/120/298`、`Memory.cj:42-45`、`SkillLoadingFunction.cj:32`、`TodoFunction.cj:78/87/103`），分层正确，没有「业务代码里散落 if/else 选实现」。

问题集中在**契约完整性**：①`parse` 在 `choices` 缺失/为空时静默返回空响应，`LLM.call` 记成功，下游 `messages[0]` 直接越界；②非流式路径不标 `usageEstimated`，上游不给 usage 时把 0 当真值落库；③`parse` 对 `null`/异类型字段直接 `asObject()`，畸形 200 响应抛 `JsonException` 且绕过候选切换；④流式请求从不带 `stream_options.include_usage`，用量只能估算；⑤多模态消息的 `content` 文本在 `parts` 非空时被整段丢弃；⑥`CallLog`（文档承诺的「每次调用一行汇总日志」）**全仓没有任何生产调用点**。另有 8 条轻微：`temperature` 合并语义与配置注释相反、`intOf` 的 `toString+tryParse` 静默归零、两处 `private init(){}` 死代码（编译器已报 `unused`）、`finder` 包一条用不到的 import、三组重复逻辑、响应解析用例错放在 `ChatCompletionsResponse_test.cj`。

### [严重][存量] #1 `parse` 在 `choices` 缺失/为空时静默返回空响应，整条链路把异常响应当成功

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:149-158`（`if(let Some(rawChoices) <- resp.get('choices')){ ... if(choices.size > 0){ ... } }`，**两个 `if` 都没有 `else`**）；成功判定在 `f_llm/src/llm/LLM.cj:169-171`
- **来源**：存量（`git blame -L 147,157`：`9a1dd2412a` 2026-10-27，当时路径为 `f_llm/src/llm/protocol/ChatCompletionsMapper.cj`）
- **判据**：review-checklist §11「失败路径当成功 / 错误处理缺失」、§3「`Option` 只判 `Some`、坏值被当成合法」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `parse` 的两条空路径都直接落到 `out`（`LLMResp()`：零消息、`finishReason = ''`、usage 全 0、`usageEstimated = false`），既不抛也不记日志；`LLM.call` 拿到结果后只补 `result.usage.llmId = conf.id`（`LLM.cj:169`）就 `hooks.onSuccess(conf.id)` + `return result`（`:170-171`），**没有校验 `messages` 是否为空**。两条真实的下游消费点都是盲取第一个元素：`f_llm/src/memory/Memory.cj:70` 的 `.messages[0].content`、`f_llm/src/llm/ContextPruner.cj:74` 的 `msgs[msgs.size - 1]`（空列表时下标 = -1）。
- **描述**：触发条件是「HTTP 200 + 无有效 choices」：网关把限流/审核拦截包成 `{"error":{...}}` 返回 200、上游返回 `{"choices":[]}`（部分平台在内容过滤时如此）、或代理层返回 `{}`。此时：①`LLM.call` 把这次调用当成功并 `recordSuccess`（熔断器的失败计数被清掉，故障平台不会降级）；②业务层拿到 0 条消息的 `LLMResp`，在 `Memory.cj:70` / `ContextPruner.cj:74` 直接 `IndexOutOfBoundsException`——一个「调用方按 `LLMException` 写的 catch 全都接不住」的越界异常；③即使调用方读了 `messages.size` 做兜底，也会把「上游失败」当成「模型返回空内容」。这是本部分唯一会**静默产出错误结果 + 崩溃下游**的路径。
- **建议**：`parse` 在 `choices` 缺失或为空时抛 `LLMException('empty choices, body: ${…}')`（错误体截断，沿用 `LLM.cj:155` 的 `previewOf`），让 `LLM.call` 走既有失败分支（可重试则 `continue` 换候选）；若要保持 `parse` 不抛，则必须在 `LLM.cj:169` 前判 `result.messages.isEmpty()` 并转成 `LLMException`。补用例：`{}`、`{"choices":[]}`、`{"error":{"message":"x"}}` 三种 200 响应各一条，断言抛 `LLMException` 且 `hooks.onRetryableFailure` 被调用。

### [一般][存量] #2 非流式响应缺 `usage` 时 `usageEstimated` 不置位，0 用量被当成真值落库

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:159-161`（usage 分支）、`:194-201`（`fillUsage`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「契约与实现不符 / 失败路径当成功」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 契约写在 `f_llm/src/llm/LLMResp.cj:27-29`：「*usage 是否为启发式估算（上游没给 usage 时置 true）*」。流式侧遵守（`ChatStreamAccumulator.cj:163-170`：`hasUsage == false` 时估算 completion 并 `usageEstimated = true`），非流式侧没有：`parse` 只在 `resp.get('usage')` 命中时填 `TokenUsage`，缺省路径直接返回，`usageEstimated` 保持 `false`。全仓 `usageEstimated` 的写入点只有 `ChatStreamAccumulator.cj:169`、`ResponsesStreamAccumulator.cj:91` 两处，非流式零写入点（`grep -rn usageEstimated f_llm/src`）。
- **描述**：部分 OpenAI 兼容网关在非流式响应里省略 `usage`（或给 `null`，后者见 #3）。此时 `LLMResp` 是 `prompt=0, completion=0, total=0, estimated=false`，`ContextPruner.cj:71` 的 `lookupOption<TokenUsageSaver>()?.saveTokenUsage(resp.usage)` 会把这些 0 写进 `llm_token_usage`——行上看不出「没数据」还是「真 0」；`CallLog.summary` 的 `estimated:` 字段（`CallLogger.cj:37`）也恒为 `false`，观测面同样失去区分能力。同一契约在流式/非流式两种行为。
- **建议**：`parse` 的 usage 分支补 `else { out.usageEstimated = true }`，并复用 `ChatStreamAccumulator.cj:185-189` 的 `estimateTokens` 至少估算 completion（让两条路径口径一致）；或在 `LLM.call` 收口处统一判定「`usage.total == 0 ⇒ estimated = true`」。补用例：`{"choices":[...]}` 无 `usage` 的响应断言 `usageEstimated == true`（现有 `ChatCompletionsResponse_test.cj:118-123` 只断言了 0）。

### [一般][存量] #3 `parse` 对 `null` / 异类型字段直接 `asObject()` / `asArray()`，畸形 200 响应抛 `JsonException` 且绕过候选切换

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:159-160`（`rawUsage.asObject()`）、`:150`（`rawChoices.asArray()`）、`:140`（`other.asString()`）、`:174-178`（`call.get('function')` 之外的 `rawCalls.asArray()`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「错误处理缺失 / 与契约不符」、§3「`Option` 只判 `Some` 不判内容」
- **证据**：静态确定 —— `JsonValue.asObject()` / `asArray()` / `asString()` 在类型不符时 `throw JsonException`（`f_data/src/json/JsonValue.cj:55-76`，三个 `as*` 都是 `if(let x: T <- this)… else throw JsonException`）。`parse` 的守卫只判断「键存在」：`"usage": null` 时 `get` 返回 `Some(JsonNull)`，`asObject()` 直接抛；`"choices": null`、`content` 为数字/对象/布尔时同理。抛点位于 `LLM.cj:164`（`JsonValue.fromStr(...).asObject()` 之后的 `parse`），**在只包住 `post` 的 `try`（`LLM.cj:145-151`）之外**，因此既不走 `hooks.onRetryableFailure` + `continue` 的候选转移，抛出的也是 `JsonException` 而非契约上的 `LLMException`。
- **描述**：触发条件是「200 但字段形状不同」，与 #1 同一类上游异常的不同表现。后果：多候选配置下不会切到下一个平台、熔断计数不记，表现为「偶发失败、换平台就好、日志里只有 Json 异常」。`ChatStreamAccumulator.cj:64-67` 有相同形态的守卫（范围外，同模式）。
- **建议**：`parse` 入口做形状校验（`JsonValue.kind` / `isObject` / `isArray`，`f_data/src/json/JsonValue.cj:77-91`、`:578-587`），不符时跳过字段并计一次 warn + `estimated`；`content` 的兜底改用同文件的 `textOf`（`:205-210`，已处理 `JsonNull`）。更彻底的做法是在 `LLM.call` 里把「反序列化 + parse」整体包进 `try`，统一转 `LLMException` 并进入候选转移。

### [一般][存量] #4 流式请求从不带 `stream_options.include_usage`，上游不回 usage ⇒ 用量全部估算（prompt 记 0）

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:51-55`（`stream` 分支只写 `stream: true`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「契约与实现不符 / 数据错误」、§14.1「能力未接完：有估算兜底却没有取真值的手段」
- **证据**：静态确定（请求侧）+ 待确认（各家平台默认行为）—— `grep -rn "stream_options\|include_usage" f_llm` 零命中，请求体永远只有 `stream: true`；响应侧 `ChatStreamAccumulator.result()`（`:158-170`）在 `hasUsage == false` 时走估算分支且 `response.usage.prompt = 0`（`:166`）——prompt 侧连估算都没有，`total` 只等于 completion 的粗估。`f_llm/doc/f_llm.md:102` 列的请求体字段也没有 usage 开关。
- **描述**：OpenAI Chat Completions 在未显式要求时不会在流里给 `usage`（要求方式是 `stream_options: {"include_usage": true}`，末块带 usage、其余块为 `null`），DeepSeek 等兼容实现同样默认不发。于是 `LLM.stream` 每次调用都以「prompt=0、completion=字节数/3」进入 `llm_token_usage` 与日志，prompt 侧恒 0 会让「缓存命中率 / 上下文成本」类分析全部失真。注意加上该字段后，`null` 块会触发 #3 的 `asObject()` 缺陷，两处必须一起改。
- **建议**：`stream == true` 时补 `body.add('stream_options', ...)`，并在 `ChatStreamAccumulator.cj:64` 把 `Some(JsonNull)` 当作「本块无 usage」跳过；若个别平台拒绝该字段，走 `ProviderDialect.decorate`（`LLM.cj:140`）做平台开关而不是全局关闭。补用例：末块缺 usage → `usageEstimated == true`；末块带 usage → `false` 且 `prompt > 0`。

### [一般][存量] #5 `CallLog` 从未接线：文档承诺的「每次调用一行汇总 / 失败观测点」在生产路径不存在

- **位置**：`f_llm/src/llm/CallLogger.cj:40-43`（`info`，零生产调用方）；契约在 `:23-29` 类注释
- **来源**：存量（`git blame`：整文件出自 `e928da3176` 2026-10-27「…Redactor、调用日志（任务 7.1-7.6）」）
- **判据**：review-checklist §14.1「接线缺失 / 承诺了但没实现」、§13「文档与实现不一致」
- **证据**：静态确定 —— `grep -rn "CallLog\." f_llm/src` 只有 `ContextPruner_test.cj:211`（测试调 `summary`），`CallLog.info` 全仓零调用；`elapsedMs` / `ttftMs` 除 `CallLogger.cj:35-41` 自身外**没有任何计算点**（`grep -rn "elapsedMs\|ttft" f_llm/src/llm` 只命中该文件），即连计时都没埋。承诺源三处：`CallLogger.cj:23-29`「只记**一行**：平台、模型、耗时、TTFT、用量、结束原因、是否估算」；`f_llm/doc/f_llm.md:157`「`LLMHooks` 提供调用前后的切面（日志、审计、埋点），`CallLogger` / `CallLog` 是内置实现」；`f_llm/doc/f_llm.md:581`「单个平台失败 → 换下一个候选｜观测点：熔断计数、`CallLog`」。而 `LLMHooks`（`LLMHooks.cj:24-34`）只有 `onSuccess` / `onRetryableFailure` 两个 `(Int64) -> Unit` 回调，`LLM.call`（`LLM.cj:144-171`）与流式路径都没有调 `CallLog`。
- **描述**：三处后果。①**可观测性缺口**：出问题时没有「一次调用一行」的汇总（provider / model / 耗时 / TTFT / 用量 / finish），排查「慢在哪个模型、TTFT 多少、是否估算」无据。②**文档失真**：`doc/f_llm.md:157/581` 描述的是不存在的实现；`doc/f_llm.md:157` 还把类型写成 `CallLogger`，而代码里只有 `CallLog`（`CallLogger` 只是文件名）。③**成本**：`CallLog.summary` 的 `estimated:` 是当前唯一能暴露「用量是估算」的通道（见 #2），它不产出，估算值就被静默当真值。
- **建议**：在 `LLM.call` 成功分支（`LLM.cj:169-171` 之前，起点用 `MonoTime.now()`——同包已此用法，见 `CircuitBreaker.cj:58`）与流式首块/末块（TTFT = 首块时间 − 起点）各调一次 `CallLog.info(conf, result, elapsedMs, ttftMs: ttft)`；失败分支在 `lastError` 落盘处补一条 warn（带 provider/model/status）。短期不接就把 `doc/f_llm.md:157/581` 改成「预留」，不要写成已具备。

### [一般][存量] #6 多模态消息的 `content` 文本在 `parts` 非空时被整段丢弃，且两条报文路径都如此、无任何文档提示

- **位置**：`f_llm/src/llm/ChatMessage.cj:24-25`（`parts` 注释）、`:35-44`（`addText` / `addImage`）；丢弃点在 `f_llm/src/llm/ChatCompletionsMapper.cj:92-101`（`message.remove('parts')` + `message.add('content', parts 数组)`），Responses 侧同构于 `ResponsesMapper.cj:161-181`
- **来源**：存量（`git blame -L 46,51`：`ce152e5f22` 2026-10-28；`ChatCompletionsMapper.cj:88-105` 出自 `9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「语义与注释不符 / 数据丢失」、§2（两条报文路径同构复制，见 #12）
- **证据**：静态确定 —— `ChatMessage` 的 `content` 是独立字段（`:28`），`addText` / `addImage` 只往 `parts` 追加（`:36`、`:42`），**不回写 `content`**；`rewriteMultimodal` 对每条消息先 `remove('parts')`，再在 `parts` 非空时 `message.add('content', JsonArray(...))`——`add` 覆盖同名键，于是构造时写进 `content` 的文本从报文里消失。仓内唯一的使用形态正好踩中：`ChatCompletionsMapper_test.cj:120-121`（`UserMessage('看图')` + `addImage(...)`）断言 `content` 数组只有 1 项且是 `image_url`，即测试把「'看图' 被丢弃」固化成了期望；`ChatCompletionsResponse_test.cj:128-139` 的 Responses 版同样只有 1 个 `input_image`。注释只说「非空时 `content` 只是文本摘要」，没有说「摘要不会发给模型」。
- **描述**：`UserMessage('描述这张图').addImage(url)` 是最自然的写法，实际发给模型的是「只有图片、没有问题」——模型不会报错，只会答非所问；排查时看 `params` 里 `content` 明明在，报文里却没有，很容易误判为上游丢字段。附带一处命名漂移：`multimodal`（`:47-51`）返回 `!parts.isEmpty()`，因此**只 addText 的纯文本消息也算 multimodal**（`ResponsesMapper.cj:162` 用它决定 content 走数组还是字符串），与注释「是否含多模态片段」不符，调用方若用它判断「有没有图片」会得到假阳性。
- **建议**：二选一并写进 README 与类型注释：①首次 `addText` / `addImage` 时若 `content` 非空且尚无 text 片段，先把 `content` 作为首个 text 片段种进 `parts`（这样 `UserMessage('看图').addImage(...)` 会得到 2 个片段；需同步改 `testBuildsContentParts` 的断言）；②保持「parts 权威」，但让 `addImage` / `addText` 在 `content` 非空时显式清空 `content` 或在报文里追加一条 warn，避免静默丢文本。`multimodal` 建议改名 `hasParts`，或改成「存在非 text 片段」。

### [轻微][存量] #7 `temperature` 合并语义与配置注释 / 类注释相反：conf 设 -1 仍然会发出 `temperature: 1.0`

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:40-49`（合并逻辑），注释在 `:28-31`（规则 2）
- **来源**：存量（`git blame`：`:40-49` 出自 `9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「语义与注释不符」、§13「配置默认值与文档不符」
- **证据**：静态确定 —— 合并是「conf 优先、否则用 params」，而 `LLMParams.temperature` 的默认值是 **`1.0`**（`f_llm/src/llm/LLMParams.cj:30`）。因此 `conf.temperature = -1`（`LLMConf.cj:56-58`：「温度：< 0 表示用平台默认值（报文不带该参数）」）只有在调用方**同时**把 `params.temperature` 也设成负数时才走 `body.remove('temperature')`；默认参数下报文带 `temperature: 1.0`。类注释 `:30`「`temperature` 有效值为负 ⇒ 报文里不出现该字段」读起来像「conf 负即可」。
- **描述**：运维在 `llm_conf.temperature` 填 -1 期望「不干预、用平台默认」，实际发出 1.0；对 temperature 默认值不是 1.0 的平台可感知，且排查时从配置上看不出来。`ThinkingPolicy` 只对恒思考模型删该字段（`ModelCapabilities.cj:73-85`），覆盖不到这类模型。
- **建议**：语义收敛成一处并写清：要么 `conf.temperature < 0` ⇒ 直接 `remove`（params 不参与，与 `LLMConf` 注释一致），要么把 `LLMParams.temperature` 默认改成 `-1.0` 让「未显式设置」与「用平台默认」同义。补用例：`conf(-1)` + 默认 `params` → 断言 `body.get('temperature').isNone()`（现有 `testTemperatureFallsBackToParams` 断言的是相反行为）。

### [轻微][存量] #8 `intOf` 用 `toString() + tryParse` 取整，字符串 / 小数形式的 token 数静默变 0

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:228-234`
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「错误处理静默 / 边界」、§10「标准库利用」（有 `asInt` 不用）
- **证据**：静态确定 —— `Int64.tryParse(value.toString()) ?? 0`；`JsonValue.toString()` 是 **JSON 序列化**（`f_data/src/json/JsonValue.cj:153-155` → `toJsonString(false)`，字符串值经 `JsonWriter` 带引号写出），`JsonString("19")` 的文本是 `"19"`，`tryParse` 必然失败 ⇒ 0；`JsonDecimal(19.0)` 的文本 `19.0` 同样失败。`JsonValue.asInt()`（`JsonValue.cj:30-39`）已处理 `JsonInt` 与 `JsonDecimal`（后者走 `toBigInt()`）。
- **描述**：触发条件是上游把 usage 写成字符串（部分国产网关 / 代理层如此）或写成 `19.0`。此时 prompt/completion/total 全变 0，与 #2「缺 usage」表现相同却无法区分，进一步污染计费数据；附带每次取值一次小字符串分配 + 解析（一次响应 3-4 次，μs 级，本身不是热点）。
- **建议**：改成 `if(value.kind == JsonKind.JsonInt || value.kind == JsonKind.JsonDecimal){ value.asInt().value… } else { 0 }`（或先 `isInt` / `isDecimal` 判断），并对「有值但解析不出」记一条 warn（带 key 与原文），让「格式不认识」不再与「字段缺失」同义。

### [轻微][存量] #9 死代码：`CallLog` / `ChatCompletionsMapper` 上的 `private init(){}` 无调用者（编译器已报 `unused`）

- **位置**：`f_llm/src/llm/CallLogger.cj:33`、`f_llm/src/llm/ChatCompletionsMapper.cj:34`
- **来源**：存量（`git blame`：`e928da3176` / `9a1dd2412a`，2026-10-27）
- **判据**：review-checklist §1「无调用者」、§11「兼容残留」
- **证据**：静态确定 —— 构建日志直接给出证据：`f_llm/target/release/.build-logs/f_llm@fountain/f_llm.llm@….errlog:9-21` 有 `warning: unused function:'init'`，逐条指向 `CallLogger.cj:33`、`ChatCompletionsMapper.cj:34`（同 errlog 还有 `ResponsesMapper.cj:34`、`ModelCapabilities.cj:28`、`LLMErrorClassifier.cj:25`）。两个 struct 的成员全是 `static`（`CallLog.summary/info`、`ChatCompletionsMapper.build/parse`），构造函数从未被调用；`private init(){}` 的唯一作用是「禁止外部构造」，与「所有成员都是 static」叠加后冗余（static 成员本就无需实例）。
- **描述**：不影响行为，但每次构建刷 warning，长期淹没真正的 `unused` 告警（该 errlog 共 12 条 warning，其中 6 条是这类 `unused function:'init'`，本部分占 2 条）。是否算「死代码」有争议（它表达「不可实例化」的意图），但既然编译器按 `unused` 报，且意图可由注释表达，建议清理。
- **建议**：删除这两个 `private init(){}`（同款另见 #12 提到的 `ResponsesMapper.cj:34` 等，范围外）；若坚持保留「不可实例化」的显式约定，改成注释 + `-Woff unused` 的局部抑制，并在 `cjlintignore.cfg` 说明。

### [轻微][存量] #10 `finder/imports.cj` 里的 `fountain::f_orm.*` 在本包内没有任何使用

- **位置**：`f_llm/src/finder/imports.cj:21`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— `grep -rn "RootDAO\|ORM\.\|SqlExecutor" f_llm/src/finder/` 零命中；finder 包 10 个文件引用的类型只有 `Agent` / `Code` / `CodeParam` / `Knowledge` / `KnowledgeParam` / `KnowledgeKind` / `MemorySummary` / `Skill` / `SkillReference` / `SkillReferenceParam` / `Specification` / `SpecKind` / `Todo` / `TokenUsage` + `ArrayList` + `LoggerFactory`。同文件其余 import（`std.collection` / `f_log` / `f_llm.constant`（`KnowledgeKind`）/ `f_llm.model` / `f_llm.model.po`）均有命中。
- **描述**：本仓约定「每包一个 `imports.cj` 承载包级 `internal import`」（`internal import` 对同包所有文件可见，见 `cangjie-doc/md/doc/cj_syntax.md:71`），因此这类残留会随包长期存在；它不影响编译（编译器不报未使用 import），但会让读者以为 finder 直接依赖 ORM。DAO 实现确实用 ORM，但那些在 `src/store/**`，不在本包。
- **建议**：删掉该行；若 finder 后续要放 `@QueryMappersGenerator` 的查询映射再按需加回。

### [轻微][存量] #11 重复逻辑①：同包 JSON 取值助手「拷贝式演进」，已出现行为漂移

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:194-201`（`fillUsage`）↔ `f_llm/src/llm/ChatStreamAccumulator.cj:175-182`（`fillStreamUsage`）；`ChatCompletionsMapper.cj:139-141`（`contentTextOf` 标量分支）↔ `:205-210`（`textOf`）；`:212-218` / `:220-226`（`stringOf` 两版）
- **来源**：存量（`git blame`：`fillUsage`、`stringOf`、`textOf` 出自 `9a1dd2412a`；`fillStreamUsage` 出自 `ce62d320ef` 2026-10-27）
- **判据**：review-checklist §2「只改函数名 / 换控制流」
- **证据**：静态确定 —— `fillUsage` 与 `fillStreamUsage` **逐行同构**（`prompt/completion/total` 三个 `intOf` + `prompt_tokens_details.cached_tokens` 的 `if let`），唯一差别是函数名与 `private static` / 包级可见性。`contentTextOf` 的 `case other => other.asString().value`（`:140`）与 `textOf` 的 `case _ => value.asString().value`（`:208`）是同一逻辑两份；`stringOf(obj,key)` 与 `stringOf(obj,key,default)` 只差兜底 `''`。
- **描述**：风险不是重复本身，而是**漂移已经发生**：流式侧有 `estimateTokens` 兜底 + `usageEstimated = true`（`ChatStreamAccumulator.cj:163-170`），非流式侧什么都没有（#2）；`fillStreamUsage` / `fillUsage` 任一侧补字段（如 `completion_tokens_details.reasoning_tokens`）另一侧不会跟上。名称也在混淆：`ContentPart.textOf`（`ContentPart.cj:42`）是工厂方法，同包顶层 `textOf` 是取值函数。
- **建议**：`fillStreamUsage` 删掉，`ChatStreamAccumulator.cj:65` 改调 `fillUsage`（提升为包级并移到单独的 `WireSupport.cj`）；`contentTextOf` 标量分支直接 `textOf(raw)`；`stringOf(obj,key)` 改为 `stringOf(obj, key, '')` 单行转调。迁移后把流式/非流式的 usage 兜底策略一并收口到同一处。

### [轻微][存量] #12 重复逻辑②：`build` 的「温度 / stream / tools」三段在 Chat 与 Responses 两个映射器里各写一遍，且已漂移（Responses 丢 `response_format`）

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:40-49`、`:51-55`、`:66-76` ↔ `f_llm/src/llm/ResponsesMapper.cj:57-66`、`:68-72`、`:74-89`（对端文件范围外，同包）
- **来源**：存量（`git blame`：Chat 侧 `9a1dd2412a` 2026-10-27，Responses 侧 `d3ebac792` 2026-10-27）
- **判据**：review-checklist §2「跨文件复制 / 近似重复，其中一块少了边界判断」
- **证据**：静态确定 —— 三段逐句对齐：温度「conf ≥ 0 用 conf，否则用 params，仍 < 0 则 remove」、stream「true 则 add / 否则 remove」、tools「`if(let tool: LLMToolParams <- params)` 遍历 `tool.functions`，空集合 remove」。差异点只有 tools 条目形状（Chat 套 `{type, function}`，Responses 扁平 `{type,name,description,parameters}`）——这部分**应当**不同。但 `response_format` 的处理只在 Chat 侧存在（`:57-64`），`ResponsesMapper.build`（`:36-90`）完全没有该分支，也没有 Responses 等价的 `text.format`；`'json_object'` 字面量（`:61`）与 `ResponseFormat.json`（`LLMParams.cj:63`）也各写一份。
- **描述**：调用方 `params.response_format = ResponseFormat.json` 走 `respond()`（`LLM.cj:138`）时静默退化成纯文本请求——不报错、不告警，只是模型不返回 JSON。这是「近似重复里少一块」的典型后果。另外 `remove('stream')` / `remove('tools')` 在 Responses 的新建 `JsonObject` 上恒为 no-op，属防御性冗余。
- **建议**：三段抽成包内小函数（`applyTemperature(conf, params, body)`、`applyStream(body, stream)`、`collectTools(params)`），两个映射器只保留各自的结构差异；`response_format` 抽成返回 `?JsonValue` 的函数，Chat 用 `{type}`、Responses 用平台要求形态，缺失时显式 warn 或抛 `LLMException`，避免静默降级。

### [轻微][存量] #13 重复逻辑③：六个异常类的四个构造函数完全同构，且 `RoleException` 在两个包里各定义了一份

- **位置**：`f_llm/src/exception/LLMException.cj:18-29`、`RoleException.cj:20-31`、`SkillNotFoundException.cj:18-29`（同包另有 `FunctionCallingException` / `FunctionNotFoundException` / `IllegalPathException`，形态相同）；**同名重复**：`f_llm/src/embedding/exception/RoleException.cj:20`（`fountain::f_llm.embedding.exception.RoleException`，与 `fountain::f_llm.exception.RoleException` 除包名外字节级同构）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02 前既有）
- **判据**：review-checklist §2「只改类型名」、§14.1「能力漂移」
- **证据**：静态确定 —— 三个文件除类名外同构：`<: BaseException` + `init()` / `init(message)` / `init(caused)` / `init(message, caused)` 四个纯转发构造。`grep -rn "RoleException" --include=*.cj` 命中两个定义处（`src/exception/RoleException.cj:20`、`src/embedding/exception/RoleException.cj:20`），**同名、同结构、不同包**，且全仓零构造/捕获点。附带一处 import 不一致：只有 `src/exception/RoleException.cj:18` 写了 `internal import fountain::f_base.BaseException`，同包其余五个文件引用同一基类却没有 import（依赖 `internal import` 的包级可见性）——删掉/移动 `RoleException.cj` 的那一行，另外五个文件立刻编译失败。
- **描述**：语义上区分异常类型是合理的（调用方按类型降级），问题在样板与重名：①6 个文件 × 12 行纯转发、新增类型要复制 4 个构造函数；②同名 `RoleException` 分属两个包，使用者 `import fountain::f_llm.exception.*` 与 `import fountain::f_llm.embedding.exception.*` 同时可见时会出现歧义或需要别名，`catch(RoleException)` 捕获的是哪一个取决于 import——这类错误在编译期不一定暴露；③全仓零引用的 `RoleException` / `SkillNotFoundException` 作为对外可达的 public 类型，按硬原则一**不判死代码**，这里只记信息并建议单列「可见性建议」。
- **建议**：删掉 `src/embedding/exception/RoleException.cj`（与 `src/exception/RoleException.cj` 完全重复，删前确认无下游 import）；两个异常包统一基类与 import 写法（或都交给各自包的 `imports.cj`）；4 个构造函数的样板可用宏或中间基类 `FountainException <: BaseException` 收敛。`RoleException` / `SkillNotFoundException` 是否保留请交用户决定，不默认删除。

### [轻微][存量] #14 `ChatCompletionsResponse_test.cj` 混装 `ResponsesMapper` 与 `LLMErrorClassifier` 的用例（按文件名找不到被测对象）

- **位置**：`f_llm/src/llm/ChatCompletionsResponse_test.cj:126-203`（5 个 `testResponses*` 用例）、`:205-215`（`testClassifyStatusCodes`）
- **来源**：存量（快照模式无基线；文件 216 行由 `9a1dd2412a` 起的多次追加累积）
- **判据**：review-checklist §10「可维护性」、§2 误报边界之外（这不是重复，而是归属错位）
- **证据**：静态确定 —— 文件名对应 `ChatCompletionsMapper.parse`，但 216 行 / 10 个用例里，5 个测 `ResponsesMapper.build/parse`、1 个测 `LLMErrorClassifier.isRetryable/isFatal`；`ChatCompletionsMapper` 的 `parse` 只被 `testParseText` / `testParseToolCalls` / `testParseReasoningContent` / `testUsageMissingDefaultsToZero` 覆盖。三类被测对象共用一个 fixture 段（`:25-74`）与同一 `@Test` 类 `ChatCompletionsResponseTest`。
- **描述**：后果是「改 `ResponsesMapper` 时在 `ChatCompletionsResponse_test.cj` 里找用例」「按文件名 grep 不到 Responses 的测试」，以及 `ChatCompletionsMapper.parse` 的空 `choices`（#1）、`usageEstimated`（#2）没有任何用例——用例被别的被测对象的测试挤占了位置。另 `:25-74` 的 `RESP` 常量是文件级 `let`，与本包其他测试的 `facadeConf` 分离，理解成本偏高。
- **建议**：拆成 `ResponsesMapper_test.cj`（5 个用例 + Responses fixture）与 `LLMErrorClassifier_test.cj`（1 个用例），`ChatCompletionsResponse_test.cj` 只留 4 个 Chat 解析用例，并补 #1 / #2 的空 `choices`、无 usage 用例。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下两条均**无改前基线**，只能作为下一轮补数据的候选，不进 `tasks.md`。

### [堆内存] 请求体三级物化：`toData()` → `JsonValue.from` → `toString()`

- **现状**：`ChatCompletionsMapper.build:37` 用 `JsonValue.from(params.toData())` 先把整份会话物化成 `DataObject` 树，再整棵转成 `JsonObject`；`LLM.cj:146` / `LLM.cj:235` 又 `body.toString()` 产出字符串。同一份会话在内存里同时存在 **3 份表示**（Data 树 / Json 树 / 字符串），大小与会话长度及内联 base64 图片（`addImage` 的 `data:` URI，单张常见 1-4 MB）线性相关。
- **方案**：照 `ResponsesMapper.messageToJson`（`ResponsesMapper.cj:183-205`）的做法逐条消息直接构造 `JsonObject`，跳过 `DataObject` 中间层；`tools` 同样直接产出 `JsonObject`（`ChatCompletionsMapper.cj:67-70` 现在是 `JsonValue.from(function.toData())`）。`rewriteMultimodal` 随之退化为「构造时直接产出 content parts」，不再需要「先序列化再改字段」——这也顺带解决 #6 的 content/parts 二选一（在构造点就能决定）。
- **预期**：峰值表示从 3 份降到 2 份（Json 树 + 字符串），base64 图片场景最明显；若 5 张 4 MB 图，粗略量级可从 ~60 MB 降到 ~40 MB（估算，非实测）。
- **代价**：`build` 要手工覆盖 `LLMParams` 的全部字段（`model` / `messages` / `temperature` / `max_tokens` / `response_format` / `thinking`），漏字段会静默丢参数；必须配「报文字段快照」用例（现有 8 个 build 用例只断言了部分字段）。`DataAssist` 的 `@FieldAlias`（如 `finish_reason`）也要手工对齐。
- **验证**：会话 200 条 + 2 张 2 MB `data:` 图，`getAllocatedHeapSize()` 与进程 RSS 峰值前后对照；`-O2`，10 轮取中位数与离散程度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `build` 在候选循环内重复序列化同一份会话

- **现状**：`LLM.cj:133-140` 与 `LLM.cj:217-223` 都是「每个候选调一次 `build`」。报文里与候选相关的只有 `model`（`ChatCompletionsMapper.cj:38`）和 `temperature`（`:40-49`），`messages` 占报文体积的绝大部分；N 个候选全失败时同一份会话被序列化 N 次，每次都带 `toString()`。成功命中首个候选时无额外开销。
- **方案**：把「与会话相关、与候选无关」的部分（`messages` + `tools` + `thinking` + `response_format`）先序列化成不可变模板，循环内只浅拷贝顶层 `JsonObject` 再覆写 `model` / `temperature`；或先 `build` 一次，循环内改 `model` 字段。
- **预期**：多候选失败转移路径上序列化次数从 N 降到 1；只影响失败转移，属长尾改善。
- **代价**：`dialect.decorate`（`LLM.cj:140`）与 `ThinkingPolicy.apply`（`:142`）会**就地改写** `body`，共享同一 `JsonObject` 会被前一候选的方言字段污染 ⇒ 必须保证每次拿到独立副本；浅拷贝不成立时收益会被拷贝成本抵消，需实测判断。
- **验证**：3 个候选全返 500 的场景，在 `build` 前后与 `toString` 前后分段计时，10 轮中位数；`cjprof record` 看 `build` / `toData` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `build` + `toData` + `toString` 在失败转移路径上占端到端耗时的可观比例 | `ChatCompletionsMapper.cj:36-79`、`LLM.cj:133-146` | 自耗时占比、单次耗时绝对值 | `cjprof record` 跑「3 候选全 500、会话 200 条」场景，看 `toData` / `JsonValue.from` / `toString` 的 self time |
| 2 | `tools` 数组顺序（`HashSet<FunctionCall>` 迭代序，`LLMParams.cj:42` + `ChatCompletionsMapper.cj:66-76`）稳定，不影响上游 prompt cache 命中 | `ChatCompletionsMapper.cj:66-76` | 同进程/跨进程顺序一致性、上游 cache 命中率 | 用同一 `params` 连续 `build` 1000 次比对 `tools` 序列化文本；再压 10 分钟稳态看 cache 命中率波动 |
| 3 | `CallLog.summary` 在 INFO 关闭时仍拼完整字符串（1 次/调用，量级可忽略） | `CallLogger.cj:35-43` | logger 级别过滤行为、单次构建耗时 | 关 INFO 后循环 1e4 次 `CallLog.info` 分段计时；确认 `log.info{}` 的 lambda 是否延迟求值 |
| 4 | `build` 内的 `JsonObject` / `JsonArray` 中间件（不逃逸出 `build` 之外的子树）适合 local region，可降峰值内存 | `ChatCompletionsMapper.cj:88-123` | 峰值内存对照（`getUsedHeapSize()` / RSS） | `f_llm/cjpm.toml:9` 已开 `--enable-local-mode`；对 `rewriteMultimodal` / `toWirePart` 加 local 标注后跑同输入，对照峰值与 `getAllocatedLocalObjectSize()` |
| 5 | 流式用量估算与实际账单偏差幅度（prompt 侧恒 0） | `ChatStreamAccumulator.cj:163-170`（估算）/ `ChatCompletionsMapper.cj:51-55`（未请求 usage） | 同一 prompt 的估算值 vs 上游真实 usage | 同一 prompt 分别走 `chatStream` 与 `chat`（非流式），比对 usage；样本覆盖中文/英文/代码各 10 条 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/exception/LLMException.cj` | .cj | ✅ | 4 个转发构造函数；§2 重复逻辑③；内容无缺陷，`init(message, caused)` 有生产调用（`LLM.cj:149`） |
| 2 | `f_llm/src/exception/RoleException.cj` | .cj | ✅ | 同上；唯一写了 `BaseException` import 的文件（同包其余文件隐式依赖它）；全仓零引用（public，不判死代码）；与 `embedding/exception/RoleException.cj` 同名重复 → #13 |
| 3 | `f_llm/src/exception/SkillNotFoundException.cj` | .cj | ✅ | 同上；全仓零引用（public，不判死代码） |
| 4 | `f_llm/src/finder/AgentsFinder.cj` | .cj | ✅ | 纯接口；仓内无 `lookup` 消费点（对外 SPI，不判死代码） |
| 5 | `f_llm/src/finder/CodeFinder.cj` | .cj | ✅ | 纯接口；仓内无消费点（对外 SPI） |
| 6 | `f_llm/src/finder/EventFinder.cj` | .cj | ✅ | 消费点 `AgentTask.cj:298` |
| 7 | `f_llm/src/finder/KnowledgeFinder.cj` | .cj | ✅ | 纯接口；`findKnowledge` 返回 `?String` 与 `queryAgent: Agent` 的可空性风格不一致（轻微，未单列）；仓内无消费点 |
| 8 | `f_llm/src/finder/MemorySummaryFinder.cj` | .cj | ✅ | 三个接口；消费点 `Memory.cj:42-45`、`MemoriesLoadingFunction.cj:32`。`overwrite(kind: String)` 用裸字符串而 `KnowledgeFinder` / `SpecificationFinder` 用 `KnowledgeKind` / `SpecKind` 类型（轻微，未单列） |
| 9 | `f_llm/src/finder/OrganizationFinder.cj` | .cj | ✅ | 消费点 `AgentTask.cj:114-120` |
| 10 | `f_llm/src/finder/SkillsFinder.cj` | .cj | ✅ | 消费点 `SkillLoadingFunction.cj:32`、`SkillReferenceLoadingFunction.cj:33`、`AgentTask.cj:103-108` |
| 11 | `f_llm/src/finder/SpecificationFinder.cj` | .cj | ✅ | 纯接口；仓内无消费点（对外 SPI） |
| 12 | `f_llm/src/finder/TodoFinder.cj` | .cj | ✅ | 消费点 `TodoFunction.cj:78/87/103`；`updateStatus` 返回 `Int64` 而 `save` 返回 `Unit`，影响行数为 0 时调用方无法区分「没这条」与「状态相同」（轻微，未单列） |
| 13 | `f_llm/src/finder/TokenUsageSaver.cj` | .cj | ✅ | `DummyTokenUsageSaver` 作 `lookupOption` 回退（`AgentTask.cj:126/133`），属有意的日志兜底，§3 不判；日志只含 token 计数，无报文正文 |
| 14 | `f_llm/src/finder/imports.cj` | .cj | ✅ | `f_orm` 未被本包使用 → #10 |
| 15 | `f_llm/src/llm.cj` | .cj | ✅ | 仅 `public import fountain::f_bean.*`，无逻辑；效果是对外再导出 `f_bean` 的 `@Bean` / `lookup` 等符号（信息，不判缺陷；副作用是扩大 `f_llm` 的导出面，可能与下游同名符号冲突，未验证） |
| 16 | `f_llm/src/llm/CallLogger.cj` | .cj | ✅ | #5（未接线）、#9（`private init`）；`Redactor.mask(conf.auth)` 已做脱敏，日志无报文正文 |
| 17 | `f_llm/src/llm/ChatCompletionsMapper.cj` | .cj | ✅ | #1（空 choices）、#2（usageEstimated）、#3（畸形字段）、#4（include_usage）、#6（content 丢弃）、#7（temperature）、#8（intOf）、#11/#12（重复逻辑） |
| 18 | `f_llm/src/llm/ChatCompletionsMapper_test.cj` | .cj | ✅ | 11 个用例（8 个 build 用例 + 3 个多模态/解析用例）；`:120-133` 把「content 被丢弃」固化为期望（见 #6）；未覆盖空 `choices` / 无 usage / tools 顺序；`itemsOf`（`:159-164`）为仅测试使用的包级 helper（可见性建议，不判死代码） |
| 19 | `f_llm/src/llm/ChatCompletionsResponse_test.cj` | .cj | ✅ | 10 个用例：4 个 Chat 解析 + 5 个 Responses + 1 个状态码（归属错位 → #14）；`testUsageMissingDefaultsToZero`（`:118-123`）只断言 0，未断言 `usageEstimated`（#2） |
| 20 | `f_llm/src/llm/ChatMessage.cj` | .cj | ✅ | 消息模型族；`parts` / `content` 双表示 → #6；`multimodal` 语义漂移并入 #6；`ToolCallMessage.tool_calls`、`ToolMessage.tool_call_id` 均有生产读写（`AgentTask.cj:466-467`、`LLMToolLoop.cj:86-88`、`ResponsesMapper.cj:201`） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单无 `.md`；`README.md` / `doc/f_llm.md` 仅作 §13/§14 的承诺源交叉核对，不计入覆盖数）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 5（#1 空 choices、#2 usageEstimated、#3 畸形字段、#6 content 丢弃、#7 temperature 语义）；设计 2（#13 重名异常类型、#14 用例归属）；语言特性 1（#8 有 `asInt` 不用）。安全性 0：`CallLog.summary` 的 `auth` 走 `Redactor.mask`（`util/Redactor.cj:31-36`，≤8 字符整段掩码），日志无报文正文；本部分无 SQL / 路径拼接 / 外部输入直接进缓冲区 |
| §1 死代码 | 2 | 逐个非 public 符号搜引用：`rewriteMultimodal` / `toWirePart` / `contentTextOf` / `appendMessage` / `fillUsage`（均在 `ChatCompletionsMapper` 内被调）、`CallLog.log`、`DummyTokenUsageSaver.log` / `instance` / `init`（`AgentTask.cj:126/133`）、`textOf` / `stringOf`×2 / `intOf`（包内跨文件使用，`ChatStreamAccumulator` / `ResponsesMapper`）均有调用者。命中：两个 `private init(){}`（#9，编译器 `unused` warning 佐证）、`finder/imports.cj:21` 的 `f_orm` import（#10）。`public` 按硬原则一不判：`RoleException` / `SkillNotFoundException` / `AgentsFinder` / `CodeFinder` / `KnowledgeFinder` / `SpecificationFinder` 仓内零引用只记信息（并见 #13 的可见性建议） |
| §2 重复逻辑 | 3 | 把本部分 8 个函数体压成「输入→输出→副作用」两两比对：`fillUsage` / `fillStreamUsage` / `contentTextOf` / `textOf` / 两版 `stringOf` 判 #11；`build` 三段与 `ResponsesMapper.build` 判 #12（差异点已列：tool 条目形状属业务要求，`response_format` 属缺失）；6 个异常类 + 两包同名 `RoleException` 判 #13。`SystemMessage` / `UserMessage` / `AssistantMessage` 仅 role 常量不同，属业务语义要求不合并；测试脚手架（`mapperConf` / `mapperParams` vs `facadeConf`）按误报边界不判 |
| §3 空实现 | 0 | `ExperienceFinder` / `IndividualityFinder` 是继承 `MemorySummaryFinder` 的标记接口，非默认空实现；`DummyTokenUsageSaver.saveTokenUsage` 是 `lookupOption` 失败时的日志兜底（`AgentTask.cj:126/133`），命名与调用点已表明语义；无 `TODO` / `UnsupportedException`，本部分无 `catch {}`（`parse` 的 `else` 缺失按「只做了一半的分支」记 #1 / #2，不重复计 §3） |
| §4 栈溢出 | 0 | 全部函数为单层循环或嵌套 `match`（`contentTextOf` 的 match 深度 2），无自递归、无 A→B→A；`build` / `rewriteMultimodal` 的遍历深度由消息条数决定但为迭代而非递归 |
| §5 OOM | 0 | 无全局集合、无按报文长度预分配、无「一次提交全量任务」。`build` 的整份会话物化是有界内存（上限 = 会话大小），已作为优化方案（堆内存）而非缺陷；最坏量级见该方案「现状」 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据（`docs/` 下只有 `LocalMode*.md`，不含本部分函数），不满足「函数级自耗时占比 + 输入规模 + 对照」三项，热点结论不成立，已列入待验证假设 #1 / #2 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无临界区；`CallLogger` / `DummyTokenUsageSaver` 的 `static let log` 是日志门面，不在锁内做 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无线程池与批处理（`finder` 的 `lookup` 是启动期注入，不在循环里） |
| §6.4 低效算法 | 0 | 已核 `rewriteMultimodal`（O(消息数×片段数)，单遍）、`toWirePart`（O(1)）、`parse`（只取 `choices[0]`）。`intOf` 的 `toString+tryParse` 是常数级放大，按轻微缺陷处理（#8），不构成算法级问题 |
| §7 降堆内存方案 | 1 | 见优化方案「请求体三级物化」（`无基线`） |
| §8 降 CPU 方案 | 1 | 见优化方案「候选循环内重复序列化」（`无基线`） |
| §9 local mode 可行性 | 0 | `f_llm/cjpm.toml:9` 已开 `--enable-local-mode`；`build` 的返回值 `JsonObject` 逃逸（返回给 `LLM.call` 并 `toString`），可 local 化的只有 `rewriteMultimodal` / `toWirePart` 内部临时件，收益只能用峰值内存证明，当前无对照数据 → 待验证假设 #4 |
| §11 现有代码的 BUG（存量） | 6 | 已核对 `parse`（`choices` / `message` / `usage` / `content` / `tool_calls` 五个可选字段的空值与类型）、`fillUsage`、`contentTextOf`、`intOf`、`build` 的温度 / stream / response_format / tools 四分支、`rewriteMultimodal`（parts 空 / content 共存两种边界）→ 命中 #1 / #2 / #3 / #6 / #7 / #8；其余边界（`detail` 缺省、`tool_calls` 无 `function` 时回退 `JsonObject()`）已确认有兜底 |
| §12 并发安全与锁粒度 | 0 | 本部分唯一被多线程共享的是 `DummyTokenUsageSaver.instance`（不可变 struct，只持有 `static let` logger）与 `ChatMessage` / `LLMResp` 这类**按请求构造**的模型对象；未发现全局 `var` / 单例可变字段 / 惰性初始化 / 发布逸出。`ChatMessage` 可变异（`addText` / `addImage` / `addToolCall`）但生命周期限于单次请求组装；范围外提示：若上层把同一 `LLMParams` 跨线程复用并并发追加消息，本部分不提供任何保护，也未声明线程安全 |
| §14 功能完备性与 README 覆盖 | 2 | #5（`CallLog` 未接线，双证：`doc/f_llm.md:157/581` + `README.md:875` 为承诺源，`grep` 零生产调用为缺失证据）、#13（同名 `RoleException` 两处定义）。README 的 API 索引已覆盖本部分全部 public 符号（`:864` / `:875` / `:881-882` / `:901`），无「public API 未文档化」；但多模态 `content` 丢弃语义（#6）在 README 中完全没有说明，只能从类型注释与测试反推 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无未读项；本部分清单不含 `.md`，§13 的「文档一致性」只做跨文件交叉核对（命中 `doc/f_llm.md:157/581` 一处，已并入 #5） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

请求构造层的骨架是对的：`ChatCompletionsMapper.build` 是纯函数、无共享状态，`testTemperature*` / `testStreamFlag` / `testResponseFormat*` / 多模态三例把主要分支钉住；`finder` 的 10 个接口职责单一、工具层统一走 `lookup`，分层没有违规；消息模型用 `DataAssist` 保证 `ToolCallMessage.tool_calls` 能进报文（`ResponsesMapper.cj:187-200` 另有手工构造）。并发面与资源面干净：无锁、无阻塞 I/O、无 `spawn`，不存在死锁、线程饥饿或资源泄漏风险；本部分也没有栈溢出候选与无界容器。

主要风险是**响应侧的「失败被当成功」**，这一族共 5 条（1 严重 + 4 一般）：`parse` 对空 `choices` 静默返回空响应（#1，唯一严重项：`LLM.call` 记成功 + 下游 `messages[0]` 越界）、非流式不标 `usageEstimated`（#2，计费落 0 且看不出没数据）、畸形字段抛 `JsonException` 绕过候选切换（#3）、流式不索要 usage（#4，prompt 恒 0）、`CallLog` 完全没接线（#5，文档承诺的调用汇总与失败观测点不存在）。五条叠起来的后果是「计费与可观测性同时失真」，而 #1 还会把上游故障伪装成模型空回复。建议修复顺序 #1 → #2 → #3 → #5 → #4：#1 是几行防御 + 一个 `LLMException`，#2 / #3 集中在 `parse` 入口，#5 若短期不接就改文档措辞（`doc/f_llm.md:157/581`），#4 需要配合 `ChatStreamAccumulator` 的 `null` 块处理一起改。

第二条线是**多模态的 `content` / `parts` 双表示**（#6）：`UserMessage('描述这张图').addImage(url)` 会把问题本身丢掉，而仓内唯一的使用形态（两个测试）已经把这种行为写成期望，说明这不是「偶发漏写」而是语义没定清。修法要连测试一起改，建议与本轮文档补齐放在一起。

8 条轻微里，`temperature` 语义与 `LLMConf` 注释相反（#7）是用户最容易踩的（配置填 -1 实际发 1.0）；`intOf` 静默归零（#8）会放大 #2 的症状；两处 `private init` 死代码（#9，编译器 warning 佐证）与一条未使用 import（#10）属清理项；三组重复逻辑里 #12（Chat / Responses 的 `build` 三段，且 Responses 漏了 `response_format`）已经造成实际行为漂移，值得排一次小重构，#13 的同名 `RoleException` 建议直接删掉 `embedding/exception` 那份（需确认无下游 import）。#14 是用例归属问题，修 #1 / #2 时顺手拆分最省事。

两条优化方案与五条待验证假设都需要先有 profile / 峰值内存数据才能立项，本轮不作为结论、不进 `tasks.md`。

存量缺陷共 14 条（严重 1 / 一般 5 / 轻微 8），是否纳入修复待用户决定；本部分无「本次改动」问题（工作区快照无 diff 可比）。本报告只读代码，未运行构建、未修改任何源码。
