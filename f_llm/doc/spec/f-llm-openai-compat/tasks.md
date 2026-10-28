# Tasks

> 每个任务按 TDD 推进：先写失败用例（Red，确认失败原因是功能缺失）→ 最小实现（Green）→ 重构；跑绿才勾选。各平台真实联调整体排在最后，实现阶段**优先适配 DeepSeek**。
>
> **状态（2026-10-28）**：**59/64 完成，5 项 deferred（9.2–9.6）**。9.2–9.6 是其他平台的真实联调，这些平台**没有免费额度**，保持现有实现现状、不做付费验证；9.6 的 DeepSeek 部分已实调通过。少数任务在实现中换了做法或类型名，均以「注：」标在原条目后；提案里没写、但为了可用性补做的工作见文末「计划外完成项」。

## 1. 前置验证与骨架

- [x] 1.1 `LLMConf` 改为评审给定字段（含 `HashMap` 形式的 `conf`、`temperature = -1.0`），`@DataAssist` + `@QueryMappersGenerator` 能编译通过；先写一个"字段可读写 + toData 含全部键"的用例
- [x] 1.2 `LLMConfCodec`：`toColumn` / `fromColumn` 往返用例（空表、中文、含引号、超长值、非法 JSON 回退空表）
- [x] 1.3 用真实数据库跑一条 `读 → 改 conf → 写 → 再读`，确认列内容是合法 JSON 文本；不通过则改为 `confJson: String` + 懒解析访问器，并记录结论

## 2. `f_httpclient` SSE 客户端

- [x] 2.1 `SseEvent` 与 `SseReader.next()` 骨架：喂 `data: a` + 空行，断言得到一条事件、字段正确（Red 先行）
- [x] 2.2 行尾兼容：`\r\n` 与 `\n` 解析结果一致
- [x] 2.3 注释/心跳行（`: ping`）被丢弃且不产生事件
- [x] 2.4 多行 `data` 以换行拼接；字段值去掉一个前导空格；未知字段忽略
- [x] 2.5 边界：单行超上限抛 `SseLineTooLongException`；空闲超时抛 `SseTimeoutException`；半行结束不抛解析错误
- [x] 2.6 `HttpResponse.sseReader()` 便利入口 + `SseReader` 实现 `Resource`，`close()` 后底层流关闭、再次 `next()` 返回空
- [x] 2.7 增量性验证：用可分段写入的假流，断言第一条事件在第二条写入前就返回

## 3. 配置装载、刷新与调度

- [x] 3.1 `LLMFinder.listConfs()` 改为无参全量；`LLMDAO` 查询条件改为 `enabled = true AND weight > 0`，用例覆盖 `weight = 0/-1` 被过滤（注：`LLMFinder` 后续整体删除，统一由 `LLMConfs.holder()` 提供候选）
- [x] 3.2 `LLMConfsSnapshot`：构建时按 `llmName` 分组、丢弃残缺行并记 `warn`；用例断言残缺行不进快照
- [x] 3.3 `ensureFresh()`：周期内 10 次调用只查库 1 次（计数桩）
- [x] 3.4 刷新成功：新增平台在下一周期参与调度；刷新失败：旧快照仍可用且记 `error`
- [x] 3.5 权重调度：权重 3:1 的分布近似 3:1；轮询算法严格交替
- [x] 3.6 熔断：连续 5 次可重试失败后跳过该 conf；冷却到期恢复；成功一次清零；400 不计入
- [x] 3.7 刷新后清理已删除 `conf.id` 的熔断状态
- [x] 3.8 `peekNext` / `isCircuitOpen` / `refreshNow` 的用例（`getTokenThreshold` / `saturated` 依赖 `TokenCounter`，归入 7.4 一并做）
- [x] 3.9 `LLMConfSource` 抽象 + 内置四个来源（数据库 / 环境变量 / 文件 / 静态）：文件源与数据库源产出同一份候选列表；来源名未知时启动失败
- [x] 3.10 `llm_confSource` 选择与装载失败回退：文件不存在/JSON 非法时保留上次成功配置；首次失败则调用报错

## 4. 协议层（非流式，先 DeepSeek）

- [x] 4.1 `ProviderDialect` + `DialectRegistry`：未知 provider 回退标准实现；同 provider 重复注册抛异常
- [x] 4.2 `ChatCompletionsMapper` 请求构造：`model = actualLlmName`、`temperature < 0` 不出现在报文、工具定义形态正确
- [x] 4.3 非流式响应解析：助手文本、`tool_calls`、`usage`、`finish_reason`
- [x] 4.4 `DeepSeekDialect`：端点与鉴权头；用录制响应回放验证普通对话与工具调用
- [x] 4.5 `ResponsesMapper` 非流式：`input`、`instructions` 映射；`output` 按 `type` 分派（message / function_call）
- [x] 4.6 错误分类：400 立即失败不转移；429/5xx 触发转移并最终成功
- [x] 4.7 门面 `LLM.chat` / `LLM.respond` 接入（注：直接复用现有 `LLMResp`，未新建 `LLMResponse`；后补 `chatByName` / `respondByName` 与 `LLMHooks`）

## 5. 流式

- [x] 5.1 `StreamAccumulator`（Chat）：`content` 拼接、`reasoning_content|reasoning` 兼容、`[DONE]` 结束（注：落地为 `ChatStreamAccumulator` + `ResponsesStreamAccumulator` 两个类）
- [x] 5.2 `tool_calls` 分片归并：`arguments` 拆成两块后仍能解析为 JSON
- [x] 5.3 `usage` 只在末块：聚合结果与末块一致；缺失时按启发式估算并标 `estimated`
- [x] 5.4 `LLM.chatStream`：回调按增量触发，返回聚合结果与非流式字段一致（同输入比对）
- [x] 5.5 `LLM.respondStream`：`response.completed` 为准（delta 累计与 completed 不一致时取后者）；`response.failed` 抛异常
- [x] 5.6 流中断与空闲超时：包装为 LLM 异常并带 `requestId` 与阶段信息

## 6. 工具与 MCP

- [x] 6.1 `FunctionMediator.register`：内置函数可注册且出现在工具定义里；未注册名调用失败
- [x] 6.2 `currentTime`：默认 ISO + epoch；非法时区返回错误文本不抛
- [x] 6.3 `SearchProvider` 注册表：注册假 provider 后 `webSearch` 可用；同名重复注册抛异常
- [x] 6.4 `webSearch` 借凭据：有可用配置时成功；无可用配置抛 `SearchUnavailableException`；指定 provider 无配置时不跨平台回退
- [x] 6.5 `webSearch` 结果归一与长度截断（含 `[已截断]` 标注）
- [x] 6.6 `webFetch` 正常路径：公网地址返回标题与正文，超 256 KiB 截断
- [x] 6.7 `webFetch` SSRF：内网地址族、`file:` 协议、跳转到内网 三类用例全部拒绝
- [x] 6.8 MCP 工具加载：`listAllTools` → 定义清洗（`$schema`/`$ref`/联合类型/`additionalProperties`）→ 调用转发；`isError` 作为文本回给模型
- [x] 6.9 工具命名冲突：跨来源重名、别名重复、超 64 字符 三种情形均在建表时失败
- [x] 6.10 自动工具循环：默认关闭；开启后 8 轮上限生效并标记轮数超限

## 7. 裁剪、日志与余额接口

- [x] 7.1 裁剪语义回归基线：为 8 个既有策略各写一条"输出语义"用例（不依赖内部实现），作为重写前后的对照
- [x] 7.2 裁剪实现整理：允许重写内部实现（如统一成组合器），8 条语义用例全绿；`SaturationContextPruner` 改为按 conf 阈值（注：没有用 `peekNext`，而是注入 `confSelector: () -> ?LLMConf`，便于单测不连库）
- [x] 7.3 新增算法：注册 `TokenBudget_4000`（按 token 预算裁剪）验证可扩展；同名注册失败；未知策略名显式失败并列出可用名
- [x] 7.4 `TokenCounter`：远端（tokenizerUrl）与启发式两种实现；不可精确计数时返回 -1 且不抛
- [x] 7.5 `Redactor`：前 4 + `****` + 后 4；长度 ≤ 8 全掩码（注：原计划写的是 < 12，实现取更保守的「短于等于前后可见位数就不露」）；对 JSON 与 conf 选项表递归生效
- [x] 7.6 调用日志：默认 `info` 一条汇总，含 provider / actualLlmName / 耗时 / TTFT / TokenUsage / finish_reason；日志中无明文 KEY（正则断言）
- [x] 7.7 `BalanceQuerier` + `BalanceMediator`：未实现平台抛 `BalanceUnsupportedException`；重复注册失败；`@Bean` 自动发现可用
- [x] 7.8 DeepSeek 余额实现：`GET /user/balance`，多币种各出一条快照，金额按定点解析；`is_available = false` 标记不可用并告警
- [x] 7.9 其余平台可编译占位：各家一个实现类，调用即抛「不支持」并标注待实现；不得返回 0 或伪造数据（注：腾讯云 `DescribeAccountBalance`（TC3 签名）、火山引擎 `QueryBalanceAcct`（V4 签名）已按官方文档实现；智谱/硅基流动/阿里云仍为占位）
- [x] 7.10 低余额：快照标记 + 一条告警日志，不产生任何外部通知

## 8. 文档与回归

- [x] 8.1 `f_llm/README.md` 与 `README_en.md` 按新公开 API 更新（中英成对）
- [x] 8.2 `f_httpclient/README.md` 增补「SSE 客户端」一节（含 10 条实现要求）
- [x] 8.3 删除 `fcoder` 整个模块目录（`src` / `docs` / `README*` / `cjpm.toml`），并清理文档中相关引用
- [x] 8.4 全量回归：`f_httpclient`、`f_llm` 模块测试全绿；`f_llm` 源码无路由注解、无 `f_mvc` 导入

## 9. 平台联调（最后做）

- [x] 9.1 DeepSeek：非流式/流式/工具调用/usage/reasoning 五项打勾，结果回填 `f_llm/doc/f_llm.md` 附录 B（实测 `deepseek-chat` 已回显为 `deepseek-flash`；`deepseek-flash` 自带思考；同批还实测了余额、搜索/抓取、`/responses`）
- [ ] 9.2 智谱：同上五项；确认 `thinking` 开关对可开关模型生效（**deferred：无免费额度**，实现保留、不做付费联调）
- [ ] 9.3 火山方舟：端点与 `ep-` 模型名；确认是否支持 Responses API（**deferred：无免费额度**）
- [ ] 9.4 阿里百炼：`enable_thinking` 形态与 `compatible-mode` 路径（**deferred：无免费额度**）
- [ ] 9.5 硅基流动与 OpenAI：标准兼容性抽查（**deferred：无免费额度**）
- [x] 9.7 腾讯云 tokenhub：`/v1/chat/completions`，模型 ID `deepseek/deepseek-flash` 归一为 `MODEL_NAME_DEEPSEEK_FLASH`；最小请求实测通过（免费额度，省着用）
- [ ] 9.6 搜索/抓取：智谱 `web_search` 字段复核（**deferred：无免费额度**）；DeepSeek `tools/search` 与 `tools/fetch` 已实调通过（2026-10-27）

## 计划外完成项（提案未列，apply 期间补做）

| 项 | 说明 |
|---|---|
| Chat 多模态 | `ContentPart` + `ChatMessage.addText/addImage`；`ChatCompletionsMapper` 把内部 `parts` 改写成 `{type:'text'}/{type:'image_url',image_url:{url,detail}}` |
| Responses 多模态 | `input_text` / `input_image`（`image_url` 是字符串）；**DeepSeek `/responses` 实测可用**（原先误判为不支持，已修 `DeepSeekDialect`） |
| Responses `reasoning` 解析 | `output[].type=="reasoning"` → `AssistantMessage.reasoningContent` |
| 内建方言注册 | 此前 `DialectRegistry` 只有显式注册、内建方言从未生效；现 `resolve()` 自动注册 deepseek/zhipu/volcengine/aliyun/siliconflow |
| 按 llmName 调用 | `LLM.chatByName` / `respondByName` + `LLMHooks`，把权重选号、熔断、失败转移串起来 |
| embedding 迁移 | 新增 `Embedding.embed(llmName, param)`；删除 `EmbeddingContextMediator` / `AbstractEmbeddingContext` / `GLMEmbeddingContext` |
| 旧链路清理 | 删除 `LLMContextMediator` / `GLMContext` / `AbstractLLMContext` / `SearchMediartor` / `AbstractSearcher` / `GLMSearcher` / `LLMFinder` |
| 余额单位统一 | 一律元（腾讯云分→元）；可用 `conf['balanceUnit']` 覆盖 |
| `f_httpclient.readToEnd()` 修复 | 已知长度时只读一次会留 0 字节，症状是 JSON 解析报 `Unescaped control character`；改为循环读满 |
| 默认模型 | `MODEL_NAME_DEEPSEEK_FLASH = 'deepseek-flash'`，智谱常量改为 glm-5 系列 |

> 仍未做：`llm_token_usage` 增列 `reasoning_tokens`（TokenUsage 当前只进日志）；Responses 的服务端会话（`previous_response_id` / `store`）与 `function_call_output` 回填。