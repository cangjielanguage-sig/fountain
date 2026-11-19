# Design

## Context

审查报告 R7 的三条严重问题（`reviews/202611061157_f_llm_module_review/review_v7.md`）都在 `src/channel/EmailChannel.cj`：

- `freeName` / `save` 直接 `${directory}/${filename}` 拼接，`filename` 来自远端邮件；
- `EmailChannel.send` 只做 `exists(Path(path))`；
- `freeName` 的 `exists` 探测与 `File.create` 之间非原子。

现有可复用的东西：`LLMConfig.FILE_SANDBOX_PATH`（`llm_fileSandboxPath`）已被文件工具使用；`std.fs` 的 `Path` / `File.create` / `exists`；`LoomContextLog` 等组件的 `Mutex` 用法。

## Goals / Non-Goals

**Goals**：堵住「任意读」（外发）与「任意写」（落盘）两个面；不改通道的公开签名；不引入新依赖。

**Non-Goals**：跨进程锁（需要文件锁，`std.fs` 无稳定 API）；附件内容扫描（病毒/MIME 校验）；`llm_channels` 的其它解析问题（R7 其它一般项另开变更）。

## Decisions

### D1. 文件名净化只认「最后一段」

```cangjie
static func bareName(filename: String): String
```

把 `/` 与 `\` 都当分隔符，取最后一个非空段；拒绝空、`.`、`..`、控制字符（`< 0x20`）；超长按 120 字符截断。做不到合法名字时返回 `attachment.bin`。

**替代**：只替换 `..`。否决——`/etc/passwd` 这种绝对路径同样能逃出目录，必须整体只取 basename。

### D2. 发送侧白名单：`llm_channelSendRoots`

新配置键（逗号分隔绝对路径）。解析顺序：

1. `llm_channelSendRoots` 非空 → 只用它；
2. 否则 `llm_fileSandboxPath` 非空 → 用它；
3. 都没有 → 附件能力**关闭**，带附件发送直接失败并说明原因。

校验：`canonicalize()` 后必须以某个根为前缀、`isRegular()` 为真、不能是符号链接（`Path` 的 canonical 与实际不同即视为链接）。

**替代**：只校验「是普通文件」。否决——防不住 `~/.ssh/id_rsa`，而这正是审查指出的外泄面。
**替代**：默认允许全部路径。否决——新功能没有兼容包袱，secure-by-default 更合适。

### D3. 落盘串行化用进程内 `Mutex`，跨进程风险入档

`AttachmentSink` 加 `private static let mutex: Mutex`，把「选名 + 创建」整个放进 `synchronized`。这样进程内两路并发一定得到不同名字。

**替代**：文件锁（`flock`）。否决——`std.fs` 无 API，引 `f_io` 只为这个不值得。
**替代**：随机后缀。否决——得到 `a-8f3c.txt` 这类不可读名字，且并发窗口仍在（先探测后创建依然非原子，只是概率低）。

跨进程竞态（两个进程写同一目录）写进 `known-limitations.md`，标注「未知规模下可忽略」。

### D4. 净化发生在 `receive` 调用 `save` 之前，而不是 `freeName` 内部

因为 `freeName` 是 `public`，调用方可能直接用它做展示；把净化放在 `save` 入口，保证「凡落盘必净化」，同时 `freeName` 对传入的已净化名字仍然只做冲突探测。

**替代**：两层都净化。采纳——`save` 与 `freeName` 都调 `bareName`，成本可忽略，避免绕过。

### D5. 失败语义保持「返回错误字符串」而不是抛异常

`AttachmentSink.save` 现在返回 `(path, error)`，`EmailChannel.send` 返回 `SendReceipt`。安全拒绝复用这条通道（`SendReceipt.failure('attachment outside allowed roots: …')`），不新增异常类型。

**替代**：抛 `ChannelException`。否决——调用方（工具层）依赖 `ok:false` 转 JSON，抛异常会变成 `ok:false` 加一段堆栈文案，反而更难解析。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 老部署没配 `llm_channelSendRoots` 时附件突然不可用 | 回落 `llm_fileSandboxPath`；README 配置表与「第三方平台通道」小节都写明 |
| `canonicalize()` 在文件不存在时抛异常 | 先 `exists` 再 canonicalize，两处都包在 try 里，失败按拒绝处理 |
| 进程内锁降低并发落盘吞吐 | 落盘本身是 IO，锁粒度只覆盖「起名 + 创建」，写入段在锁外 |
| 净化后名字可能重复（不同邮件的同名附件） | 冲突顺延本来就处理重复 |

## Migration Plan

纯安全加固，无数据结构变更，无需迁移；回退只需删配置或回滚代码。

## Open Questions

- 是否需要「附件大小上限」？本期不做，写入 `todo.md` 的扩展项。
