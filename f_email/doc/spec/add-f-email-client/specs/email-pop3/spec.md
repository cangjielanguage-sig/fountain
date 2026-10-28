## ADDED Requirements

### Requirement: 会话状态与删除提交

客户端 SHALL 实现 AUTHORIZATION → TRANSACTION → UPDATE 三态。`DELE` MUST 只做标记，
只有 `QUIT` 收到 `+OK` 才真正删除；`close()`、协议错误、连接中断 MUST NOT 进入 UPDATE，
已标记的删除 MUST 不生效。同一封邮件重复 `DELE` 收到 `-ERR` 时 MUST 抛 `MailProtocolException`。

#### Scenario: DELE 后 QUIT

- **WHEN** `DELE 2` 成功后再 `QUIT` 并收到 `+OK`
- **THEN** 服务器侧第 2 封被删除

#### Scenario: DELE 后 close

- **WHEN** `DELE 2` 成功后直接 `close()`
- **THEN** 不发送 `QUIT`，第 2 封保留在服务器上

### Requirement: 建连与能力协商

`Pop3Client.build()` SHALL 完成 TCP 连接、读 greeting、可选 `CAPA`、按配置 `STLS`，
但 MUST NOT 登录。`CAPA` 返回 `-ERR` 时 MUST 置空能力表并继续而不是失败。
`STLS` 升级后 MUST 重新 `CAPA`，因为 `TOP`/`UIDL`/`AUTH` 可能在 TLS 后才广告。
builder 的加密策略默认与 SMTP 一致：`requireEncryption=true`、`allowPlaintextAuth=false`。

#### Scenario: 老服务器无 CAPA

- **WHEN** `CAPA` 返回 `-ERR unknown command`
- **THEN** `build()` 仍然成功，`capabilities` 为空，后续 `UIDL` 尝试发送并按服务器回复处理

#### Scenario: STLS 后能力变化

- **WHEN** STLS 前的 `CAPA` 不含 `TOP`，STLS 后的 `CAPA` 含 `TOP`
- **THEN** 最终能力表包含 `TOP`

### Requirement: 认证

客户端 SHALL 支持 `USER`/`PASS`、`APOP` 与 `AUTH`（`PLAIN`/`LOGIN`）。
明文方式（`USER`/`PASS`、`AUTH`）MUST 默认只在 TLS 之后允许。
`APOP` MUST 使用 greeting 里的 `<timestamp>` 计算 `MD5(timestamp + password)`；
greeting 中不含 `<...>` 时 MUST 抛 `MailProtocolException`。

#### Scenario: APOP 摘要

- **WHEN** greeting 为 `+OK POP3 ready <1896.697170952@dbc.mtview.ca.us>`
- **THEN** 客户端发送 `APOP user ` 加 `hex(MD5("<1896.697170952@dbc.mtview.ca.us>" + password))`

#### Scenario: 无 timestamp 的 APOP

- **WHEN** greeting 中不含 `<...>` 而调用方调用 `apop()`
- **THEN** 抛 `MailProtocolException`，不发送 `APOP`

### Requirement: 多行响应

客户端 SHALL 按 POP3 多行规则读取：首行 `+OK ...`，随后若干行，最后一行单独的 `.`；
以 `..` 开头的行 MUST 还原为 `.`。多行读取 MUST 逐字节处理，MUST NOT 受控制行行上限约束。

#### Scenario: 正文中的点行

- **WHEN** `RETR` 正文中含一行 `..` 与一行 `.`（服务端编码后的形式）
- **THEN** 解析结果中分别是 `.` 与提前结束标记，不会把内容误当作终止符

### Requirement: 流式 RETR 与 TOP

`retr(message, sink)` SHALL 边读边写入调用方 sink 并返回总字节数，MUST NOT 构造整封中间副本。
`retrMessage` MUST 把去 dot-stuffing 的字节流直接交给 `MimeParser`，MUST NOT 产生中间整封文件。
`topMessage(message, lines)` MUST 只解析头部与前 n 行正文；能力表无 `TOP` 时 MUST 抛
`MailProtocolException`。

#### Scenario: 大邮件内存恒定

- **WHEN** `RETR` 一封含 20 MB 附件的邮件到 sink
- **THEN** 进程常驻内存增量不随邮件大小线性增长

#### Scenario: TOP 不可用

- **WHEN** `CAPA` 未广告 `TOP` 且调用方调用 `topMessage`
- **THEN** 抛 `MailProtocolException`

### Requirement: 列表与唯一标识

客户端 SHALL 支持 `STAT`、`LIST`（单条与多条）、`UIDL`（单条与多条）并解析为结构化结果。
`UIDL` MUST 作为跨会话去重键暴露，MUST NOT 由库内部保存状态。

#### Scenario: 多行 LIST

- **WHEN** 服务器返回 `+OK` 后跟 `1 120`、`2 340` 与 `.`
- **THEN** 得到两个 `Pop3MessageInfo`，序号与大小正确

### Requirement: 错误映射

`-ERR [AUTH]` MUST 映射为 `MailAuthException`；`-ERR [SYS/TEMP]`、`-ERR [IN-USE]`
MUST 分类为可重试；`-ERR [SYS/PERM]` 与无 response code 的一般 `-ERR` MUST 默认不可重试。
文本没有 `[...]` 时 MAY 按关键字匹配，最终必须落到确定的分类。

#### Scenario: 认证失败

- **WHEN** `PASS` 收到 `-ERR [AUTH] invalid credentials`
- **THEN** 抛 `MailAuthException`，`isRetryable` 为 false

#### Scenario: 系统临时失败

- **WHEN** `RETR` 收到 `-ERR [SYS/TEMP] try later`
- **THEN** 抛出的异常被分类为可重试
