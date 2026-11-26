# Proposal

## Why

f_llm 现在能把「事情做完」，却不能把**结果送出去**：loom 流程跑完只能写库、返回事件，想让结果落到邮件或 IM 里，调用方得自己在流程外重写一遍发送逻辑，平台差异、账号管理、凭据全部暴露给业务。

同时，仓库里没有任何「第三方平台接入」的统一抽象——`f_email` 只是邮件客户端，没有平台无关的消息接口。再放任下去，微信 / 企业微信 / 钉钉 / 飞书 / 邮件会各自长出一套调用方式。

## What Changes

- 新增 `fountain::f_llm.channel` 包：平台无关的发送/接收接口 + 中介者。
- **中介者按平台名寻址，支持同一平台多账号**：`(platform, account)` 二维键，`account` 为空时落到该平台默认账号。
- **每个对接实现在静态块自动注册自己的 provider 到中介者**（沿用 `Stores.registerContent` 的同款顶层 `let` 写法），启动时按配置为每个账号建实例。
- 先落**电子邮件**：基于 `f_email`（SMTP 发、IMAP/POP3 收），f_llm 新增 `fountain::f_email` 依赖。
- loom 流程内可访问：新增 `channelSend` / `channelInbox` 两个工具，流程里用 `loomCallTool` 调用，也供模型工具循环使用。
- 微信 / 企业微信 / 钉钉 / 飞书**本期不实现**：只登记平台名常量与扩展位，不写空壳实现（避免假实现被当成可用）。

## Capabilities

### New Capabilities
- `platform-channel`: 第三方平台接入的接口与中介者（平台/账号寻址、静态注册、配置装配、邮件收发、loom 内访问）。

### Modified Capabilities
<!-- 无：不改既有能力的需求（loom-flow / loom-supervisor 等行为不变，仅新增工具）。 -->

## Impact

- 代码：`f_llm/src/channel/`（新增：契约、中介者、provider 注册表、邮箱实现、两个工具）；`f_llm/cjpm.toml` 新增 `fountain::f_email` path 依赖；`ToolName` / `PromptCapabilities` 可选补充工具名。
- 配置：新增 `llm_channels`（JSON 数组，每条一个账号）；关闭/缺省时中介者只有 provider、没有实例，`send` 明确报错。
- 测试：新增 `channel/ChannelMediator_test.cj`、`channel/EmailChannel_test.cj`、`channel/ChannelFunctions_test.cj`；全部离线（注入假 transport，不连 SMTP/IMAP）。
- 依赖：`f_email` 是同仓模块（其自身依赖 `cangjie_tpc::charset4cj` 中心仓包，属传递依赖）。
