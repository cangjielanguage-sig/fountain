# Spec Delta

## Purpose

让任意 OpenAI 兼容平台以同一套请求模型被调用：覆盖 Chat Completions 与 Responses API 的流式与非流式形态，把平台报文差异收敛到可注册的方言，并把「模型是否支持思考」从平台属性里剥离出来。

## ADDED Requirements

### Requirement: 统一模型名寻址

调用方 SHALL 只使用统一模型名 `llmName` 发起请求；系统 SHALL 用匹配到的配置里的 `actualLlmName` 填充报文 `model` 字段，调用方无需知道平台侧模型名。

#### Scenario: 同一统一模型名映射到不同平台模型名
- **WHEN** 两条配置的 `llmName` 都是 `chat-pro`，`actualLlmName` 分别为 `deepseek-chat` 与 `ep-2026xxxx`
- **THEN** 两次请求的报文 `model` 分别是对应的 `actualLlmName`，且调用方代码不改

#### Scenario: 未知统一模型名
- **WHEN** 请求的 `llmName` 没有任何启用配置
- **THEN** 调用立即失败，异常消息包含该 `llmName` 与当前可用模型名列表

### Requirement: 温度参数透传与缺省

`temperature` 小于 0 时系统 SHALL NOT 在报文中携带该字段，表示使用平台默认值；大于等于 0 时 SHALL 以该值覆盖调用方传值。

#### Scenario: 未配置温度
- **WHEN** 配置 `temperature = -1` 且请求未显式指定温度
- **THEN** 请求 JSON 中不存在 `temperature` 键

#### Scenario: 配置覆盖请求
- **WHEN** 配置 `temperature = 0.3`、请求传 `1.0`
- **THEN** 请求 JSON 的 `temperature` 为 `0.3`

### Requirement: 非流式 Chat Completions

系统 SHALL 支持非流式 Chat Completions 调用，返回助手消息列表、`finish_reason` 与 `TokenUsage`。

#### Scenario: 普通对话
- **WHEN** 以 `stream=false` 调用一个可用模型
- **THEN** 返回至少一条助手消息，其文本非空，且 `usage.total` 大于 0

#### Scenario: 返回工具调用
- **WHEN** 模型返回 `finish_reason = tool_calls`
- **THEN** 返回的助手消息包含 `tool_calls`，每项的 `id`、`function.name` 与 `function.arguments` 均非空，且 `arguments` 可被解析为 JSON 对象

### Requirement: 流式 Chat Completions

系统 SHALL 支持流式 Chat Completions：逐块回调增量，遇 `data: [DONE]` 结束，并返回与非流式一致的聚合结果。

#### Scenario: 文本增量拼接
- **WHEN** 上游依次返回 `delta.content` 为 `你`、`好`
- **THEN** 回调收到两次文本增量，聚合结果的助手文本为 `你好`

#### Scenario: 工具参数分片
- **WHEN** 上游把同一个 `tool_calls[0].function.arguments` 拆成 `{"pa` 与 `th":"x"}` 两块
- **THEN** 聚合后得到一个完整工具调用，`arguments` 为 `{"path":"x"}` 且可解析为 JSON

#### Scenario: 用量只在末块
- **WHEN** 只有最后一块携带 `usage`
- **THEN** 聚合结果的 `TokenUsage` 与末块一致，且不会把中途缺失的块计为 0

### Requirement: Responses API

系统 SHALL 支持 Responses API 的流式与非流式调用：请求侧把内部消息映射为 `input` 输入项（系统消息优先映射到 `instructions`），响应侧按 `type` 分派异构 `output` 项；流式最终结果 SHALL 以 `response.completed` 事件中的完整响应为准。

#### Scenario: 非流式工具输出项
- **WHEN** 响应 `output` 中同时含 `message` 与 `function_call` 两种项
- **THEN** 系统分别产出助手文本与工具调用，不把 `function_call` 当作文本

#### Scenario: 流式以 completed 为准
- **WHEN** 增量事件累计的文本为 `abc`，而 `response.completed` 中的文本为 `abcd`
- **THEN** 返回的最终文本是 `abcd`

#### Scenario: 流式失败事件
- **WHEN** 收到 `response.failed` 或 `error` 事件
- **THEN** 调用失败，异常中包含上游错误码

### Requirement: 平台方言可注册

平台差异（端点路径、鉴权头、报文补丁、usage 字段补齐）SHALL 由可注册的方言决定；未注册的 `provider` SHALL 回退到标准 OpenAI 行为，而不是报错。

#### Scenario: 未知平台按标准 OpenAI 处理
- **WHEN** 配置的 `provider` 没有任何方言注册
- **THEN** 请求发往 `{url}/chat/completions`，鉴权头为 `Authorization: Bearer {auth}`

#### Scenario: 同 provider 重复注册
- **WHEN** 两个方言声明同一个 `provider`
- **THEN** 注册阶段立即失败，且不进入服务状态

### Requirement: 思考能力由模型决定

系统 SHALL 按「配置覆盖 → 模型能力表 → 默认可开关」三级解析模型的思考能力（`None` / `Always` / `Toggle`）；平台方言只决定字段形态，不决定是否思考。

#### Scenario: 恒思考模型
- **WHEN** 模型能力为 `Always` 且请求带 `temperature = 0.3`
- **THEN** 报文不含 `temperature`，且思考字段开启

#### Scenario: 不支持思考的模型被强制开启
- **WHEN** 模型能力为 `None` 且配置 `alwaysThinking = true`
- **THEN** 报文不含任何思考字段，记录一条告警，请求照常发出

#### Scenario: 可开关模型关闭思考
- **WHEN** 模型能力为 `Toggle` 且请求显式关闭思考
- **THEN** 报文中的思考字段为关闭状态

### Requirement: 失败分类与跨平台转移

系统 SHALL 只对可重试错误（连接失败、超时、429、5xx、流中断）转移到下一个平台；其余 4xx SHALL 立即失败，不重试、不转移。

#### Scenario: 参数错误不转移
- **WHEN** 第一个平台返回 400
- **THEN** 调用立即失败，异常包含状态码 400，且没有向第二个平台发请求

#### Scenario: 限流后转移
- **WHEN** 第一个平台返回 429、第二个平台返回 200
- **THEN** 调用成功，返回结果来自第二个平台
