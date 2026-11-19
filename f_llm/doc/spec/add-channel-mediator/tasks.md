# Tasks

> 每个任务按 Red-Green-Refactor：先写用例并确认因「功能未实现」失败，再写最小实现，`cjpm test` 跑绿才勾选。

## 1. 契约与中介者

- [x] 1.1 新增 `channel/ChannelContract.cj`：`Channel` 接口（`platform/account/send/receive/close`）、`OutboundMessage` / `InboundMessage` / `SendReceipt`、`ChannelPlatforms` 常量；验证：用例构造消息并断言字段默认值与 `ChannelPlatforms` 常量值（先失败）。
- [x] 1.2 新增 `ChannelMediator`：`register/channel/platforms/accounts/send/receive/reset`，`(platform, account)` 归一化、空账号取默认、未知抛异常；验证：4 条用例（多账号并存、默认账号、未知平台、重复注册幂等）。

## 2. provider 静态注册

- [x] 2.1 新增 `ChannelProviders`：`register(platform, factory)` + `platforms()` + `create(platform, conf)`，重复注册幂等；验证：用例断言重复注册后仍只有一项、未知平台 `create` 抛异常。
- [x] 2.2 在 `EmailChannel.cj` 顶层用 `let _emailProviderRegistered = ChannelProviders.register('email', …)` 自动注册；验证：用例（不手工注册）断言 `ChannelProviders.platforms()` 含 `email`。

## 3. 邮箱通道（含附件）

- [x] 3.1 `EmailTransport` 接口 + `EmailChannel.send`：映射收件人/标题/正文/附件路径并透传成功或失败；验证：注入假 transport，断言送达内容含附件清单与返回 receipt。
- [x] 3.2 `send` 的附件路径不存在时返回失败并指明文件，不发出邮件；验证：用例断言 `ok=false` 且 error 含文件名，假 transport 未被调用。
- [x] 3.3 `receive` 映射最近 N 封邮件的 id/发件人/标题/正文/时间/未读/附件元数据（文件名+大小）；验证：假 transport 返回 2 条（其中 1 条带 2 个附件），断言条数与字段。
- [x] 3.4 `receive(downloadDir)` 非空时落盘附件并回填路径；同名冲突顺延 `-2`，不覆盖已有文件；目录不可写时标记未下载并携带原因；验证：临时目录 3 条用例（正常落盘 / 冲突顺延 / 不可写）。
- [x] 3.5 `FEmailTransport`：用 `f_email` 的 `Email.builder()` 组装配 SMTP+IMAP，`send` 走 `attach(name, FileBodySource)`、`inbox` 走 `body(...).attachments` + `saveTo`；验证：用例只断言「配置到 builder 的映射结果」（缺字段报错信息），不连网。

## 4. 配置装配

- [x] 4.1 `ChannelBootstrap.install(json)`：解析 `llm_channels` 数组，逐条 `ChannelProviders.create` + `ChannelMediator.register`；验证：一条合法配置后 `accounts("email")` 含该账号。
- [x] 4.2 非法输入容错：非数组、缺字段、未知平台只跳过该条，不抛错；验证：3 条用例断言跳过数量与中介者状态。
- [x] 4.3 `LLMConfig` 增加 `llm_channels` 键与读取函数；验证：默认空串 → 装配后无实例。

## 5. loom 工具

- [x] 5.1 `channelSend`（`@Bean`）：入参 `platform/account/to/subject/text/html/attachments`（附件为 `[{filename,path}]`），返回 JSON；验证：用例断言成功返回 `{"ok":true,...}`、附件随调用透传、未知平台返回 `ok:false` 且不含异常。
- [x] 5.2 `channelInbox`（`@Bean`）：入参 `platform/account/limit/downloadDir`，返回消息数组 JSON（含附件元数据与落盘路径）；验证：用例断言条数、附件字段与 `downloadDir` 透传。
- [x] 5.3 工具在 JIT 步骤里可用：`loomCallTool("channelSend", …)`；验证：用例用内存宿主执行一步 JIT 调 `loomCallTool`，断言消息经中介者投递。

## 6. 文档与依赖

- [x] 6.1 `f_llm/cjpm.toml` 增加 `fountain::f_email` path 依赖；验证：`cjpm build` 通过。
- [x] 6.2 `doc/loom.md` 补「第三方平台通道」小节（接口、中介者、配置、工具），`README.md` / `README_en.md` 补能力表一行 + 配置项；验证：与代码逐项对照一致。

## 7. 集成验证

- [x] 7.1 全量回归 `cd f_llm && cjpm test` 全绿（含真库用例），无新增告警；验证：命令输出贴入交付说明。
- [x] 7.2 端到端冒烟：假 transport 走「装配配置 → 流程内 `channelSend`（带附件）→ 假邮箱收到 → `channelInbox`（指定 downloadDir）读回并落盘」；验证：单条用例通过，断言附件在临时目录里存在且正文一致。

## Workflow follow-up

- `openspec verify` → `openspec archive add-channel-mediator`，归档后用最终版覆盖 `f_llm/doc/spec/add-channel-mediator/`。
- 提交（不含 tag），提交信息写清「新增 channel 契约与中介者 + 邮件实现 + 两个工具 + 配置项」。
