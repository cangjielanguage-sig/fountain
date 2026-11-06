# Tasks

> 每个任务按 Red-Green-Refactor：先写用例并确认因「功能未实现 / 行为不符合预期」失败，再改实现，`cjpm test` 跑绿才勾选。

## 1. 文件名净化

- [x] 1.1 `AttachmentSink.bareName`：`../../etc/passwd` → `passwd`、`a\\b\\c.txt` → `c.txt`、空/`.`/`..` → `attachment.bin`；验证：4 条断言（先失败）。
- [x] 1.2 `save` 落盘后断言目标仍在目录内：构造穿越名，断言写入的是 `<dir>/passwd` 而不是目录外文件。

## 2. 落盘并发安全

- [x] 2.1 `AttachmentSink` 加 `Mutex`，把「选名 + 创建」放进临界区；验证：并发用例——两线程同时存 `a.txt`，断言两个路径不同且都存在。
- [x] 2.2 回归：既有冲突顺延用例（`a-2.txt`）仍通过。

## 3. 发送侧白名单

- [x] 3.1 `LLMConfig` 增加 `LLM_CHANNEL_SEND_ROOTS` 与读取函数（逗号分隔 → `ArrayList<Path>`，回落 `llm_fileSandboxPath`）；验证：3 条（显式配置 / 回落 / 都空）。
- [x] 3.2 `EmailChannel.send` 校验每个附件：canonical 前缀、`isRegular`、非符号链接；验证：4 条（根内成功、根外拒绝、符号链接拒绝、未配置拒绝）。
- [x] 3.3 拒绝时的错误文案含文件名与「allowed roots」，且 `transport.send` 未被调用（断言 `sent.size == 0`）。

## 4. 文档

- [x] 4.1 `README.md` / `README_en.md` 配置表加 `llm_channelSendRoots`，通道小节写明「未配置则禁用附件」。
- [x] 4.2 `doc/loom.md` 通道小节补「附件约束」三行；`doc/known-limitations.md` 加「跨进程落盘竞态」一条。

## 5. 集成验证

- [x] 5.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 578）。
- [x] 5.2 端到端冒烟：带附件的 `channelSend` 走允许根目录成功、目录外被拒；`channelInbox` 收带 `../` 名字的附件落到目录内。

## Workflow follow-up

- `openspec validate --strict` → `openspec verify`（不可用时回退：strict + 三对齐）→ `openspec archive fix-channel-attachment-safety`。
- 归档后用最终版覆盖 `f_llm/doc/spec/fix-channel-attachment-safety/`；提交信息写清「附件名净化 + 发送白名单 + 落盘串行化」。
