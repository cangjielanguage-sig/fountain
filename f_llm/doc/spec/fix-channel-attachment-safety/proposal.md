# Proposal

## Why

代码审查（`reviews/202611061157_f_llm_module_review`，R7）发现通道模块的附件路径有三处安全缺口，都属于「一旦被提示注入利用就能读写任意文件」的级别：

- 接收侧直接拿远端邮件的 `filename` 拼路径，`../` 可写出下载目录，`File.create` 又是截断写；
- 发送侧只 `exists()` 判断，模型可通过 `channelSend` 把宿主任意可读文件（`~/.ssh/id_rsa`、渠道配置）外发；
- `freeName` 的「先探测再创建」非原子，并发收信时后写者静默覆盖前者，与「不覆盖已有文件」的承诺相反。

## What Changes

- **接收侧净化文件名**：只取最后一段（`/`、`\` 均视作分隔符），拒绝空名、`.`、`..`、控制字符；落盘后断言最终路径仍在下载目录内。
- **发送侧增加允许根目录**：新配置 `llm_channelSendRoots`（逗号分隔绝对路径）；未配置时回落到 `llm_fileSandboxPath`，都没有则**禁用附件**并明确报错。附件必须是普通文件、不是符号链接。
- **落盘串行化**：`AttachmentSink` 内加 `Mutex`，把「探测可用名 + 创建」合成一个临界区，消除进程内并发覆盖；跨进程竞态作为残留限制写入 `known-limitations.md`。
- 补 6 条用例（穿越名、绝对路径、符号链接、白名单外发送、并发落盘、目录外路径）。

## Capabilities

### Modified Capabilities
- `platform-channel`：附件发送与接收的安全约束从「隐含」变为「显式需求」。

## Impact

- 代码：`src/channel/EmailChannel.cj`（`AttachmentSink`、`EmailChannel.send`）、`src/config/LLMConfig.cj`（1 个新键）。
- 配置：新增 `llm_channelSendRoots`；未配置时的行为变化（附件默认禁用）需在 README 写明。
- 测试：`src/channel/EmailChannel_test.cj` 增 6 条。
- 文档：`README.md` / `README_en.md` 配置表、`doc/loom.md` 通道小节、`doc/known-limitations.md` 补一条。
