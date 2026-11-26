# Design

## Context

R7 的 6 条一般项集中在三个文件：`EmailChannel.cj`（transport 与附件）、`ChannelMediator.cj`（实例表）、`ChannelBootstrap.cj`（配置解析）。

## Decisions

### D1. `receive` 的失败语义按「是否已取到邮件」二分

```cangjie
var taken = 0
try {
    for (mail in transport.receive(limit)) { ...; taken++ }
} catch (e: Exception) {
    if (taken == 0) { throw ChannelException('email receive failed: ${e.message}') }
}
```

**替代**：一律抛。否决——已读到的邮件丢掉更糟。**替代**：一律吞。否决——正是要修的 bug。

### D2. 附件失败在附件粒度隔离

`item.read()` 包 try/catch，失败产出 `InboundAttachment(..., error)`；与既有「落盘失败」用同一个字段。

### D3. `register` 覆盖即释放，空账号重复即报错

```cangjie
synchronized(mutex){
    if(account.trimAscii().isEmpty() && instances.contains(key)){
        throw ChannelException('channel account must be specified when registering a second instance for ${platform}')
    }
    match(instances.get(key)){ case Some(old) => old.close(); case None => () }
    instances[key] = channel
}
```

`close()` 放在锁内会拉长临界区，但只有替换时发生（低频），换取「不会漏关」。

**替代**：把旧实例收集起来锁外关闭。否决——旧实例可能被并发 `channel()` 取走，锁外关闭会让调用方拿到已关闭实例。

### D4. 严格解析用「跳过 + 记错」，不复用宽松解析

`strOf` 对 `JsonNull` 返回空串（而不是 `toString()` 的 `"null"`）；`portOf` 越界抛错；email 必填校验抛错；`tls` 白名单校验抛错。逐条 try/catch 已在 `install` 里，抛错自然变成 skipped + error。

### D5. `tls` 明确不支持 `starttls`

`FEmailTransport` 目前用 `Email.builder()` 的默认 SSL 直连，没有 starttls 入口。与其留着假开关，不如解析时拒绝。

**替代**：删掉 `tls` 字段。否决——`ChannelAccountConf` 是对外契约，删字段要动装配与测试的调用点，留字段 + 明确拒绝成本更低，等真做 starttls 时再启用。

### D6. `installFromConfig` 用 try 包住配置读取

配置源（db/env/file）读取异常时返回 `report.errors`，与「单条非法只跳过」保持同一种失败表达。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 存量配置里 `tls:"starttls"` 的条目会从「能装」变「跳过」 | 错误信息明确写「暂只支持默认 SSL」，按提示删掉该字段即可 |
| `close()` 在锁内可能阻塞（IMAP 断连） | 只在替换/`closeAll` 时发生，属低频运维路径 |
| `receive` 首封前失败改为抛异常 | 工具层已有 catch → `ok:false`，流程侧行为一致 |

## Migration Plan

无需迁移；存量非法条目会被跳过并在装配报告里列出。
