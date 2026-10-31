## Purpose

把 TCP 与 TLS 连接、行协议的字节通道、dot-stuffing、literal 传输、超时与连接生命周期收敛成一层可注入的传输抽象，供 SMTP、POP3、IMAP 复用，并把 CRLF 注入防线与脱敏跟踪集中在一处实现。

## ADDED Requirements

### Requirement: TLS 模式与默认验证

传输层 SHALL 支持三种 TLS 模式：`None`（明文）、`StartTls`（先明文后命令升级）、
`Implicit`（连上即 TLS）。默认 TLS 配置 MUST 为 `serverName` 等于连接用的 host、
`verifyMode` 为系统 CA（`CertificateVerifyMode.Default`）。系统 MUST NOT 提供"默认信任所有证书"
的开关；`TrustAll` 只能由调用方显式设置。

#### Scenario: 默认配置拒绝自签证书

- **WHEN** 调用方以 `TlsMode.Implicit` 连接一个使用自签证书的服务器，且未显式传入 `tlsConfig`
- **THEN** 握手失败并抛出 `MailTlsException`，不建立任何明文通道

#### Scenario: 显式注入配置后才接受自签证书

- **WHEN** 同一连接显式传入含自签 CA 的 `TlsClientConfig`
- **THEN** 握手成功，`isTls` 为真

### Requirement: STARTTLS 升级的四条约束

配置为 `StartTls` 时，传输层 SHALL 遵守：服务器未广告 `STARTTLS` 则失败且不发明文；
升级后能力表必须重新协商；升级前不得发送任何凭据；升级前不得预读 socket。

#### Scenario: 服务器不广告 STARTTLS

- **WHEN** SMTP 服务器 EHLO 回复中没有 `STARTTLS`，而客户端配置为 `TlsMode.StartTls`
- **THEN** 抛 `MailProtocolException`，客户端不发送 `AUTH`、不发送 `MAIL FROM`

#### Scenario: 升级前的单字节读

- **WHEN** 连接以 `TlsMode.StartTls` 建立，正在读取 `220` / `+OK` 升级确认行
- **THEN** 该行读取使用非缓冲模式逐字节读取，读取完成后缓冲区中不残留任何 TLS 握手字节

### Requirement: 行通道的字节语义

`LineChannel` SHALL 按字节而非字符读写。`readLine()` MUST 返回不含行结束符的字节数组，
`\r\n` 与裸 `\n` 都要接受（裸 `\n` 记一次协议告警）；`writeLine()` MUST 自动补 `\r\n`，
且 MUST 在写入前拒绝任何包含 `\r` 或 `\n` 的参数。串行读取超过 `maxLine` 时
MUST 抛 `MailLimitException(kind=Line)`。

#### Scenario: 裸 LF 被接受

- **WHEN** 服务器用 `250 OK\n` 回复
- **THEN** `readLine()` 返回 `250 OK` 的字节，并记录一次协议告警，连接继续可用

#### Scenario: 注入被拒绝

- **WHEN** 调用方调用 `writeLine("AUTH PLAIN xxx\r\nRCPT TO:<evil@example.com>")`
- **THEN** 抛 `MailProtocolException`，socket 上不写出任何字节

#### Scenario: 超长行

- **WHEN** 回复行长度超过 `maxLine`
- **THEN** 抛 `MailLimitException(kind=Line)`，连接被关闭

### Requirement: dot-stuffing 的对称性

`DotStuffWriter` SHALL 把所有行首的 `.` 加倍并以 CRLF 结束每行，`finish()` MUST 补
`\r\n.\r\n`（空正文时只写 `.\r\n`）；`DotUnstuffReader` SHALL 逐字节还原并遇到单独一行
`.` 时结束。两侧 MUST 在任意分块边界上正确工作，且正文行长度不受行上限约束。

#### Scenario: 跨块边界的行首点

- **WHEN** 一次 `write` 以 `.` 结束、下一次 `write` 以换行和 `.abc` 开始
- **THEN** 输出的第二个 `.` 被加倍为 `..abc`，反解后与原文逐字节一致

#### Scenario: 空正文

- **WHEN** 调用方在 `354` 之后立即 `finish()`，未写任何正文
- **THEN** socket 上只收到 `.\r\n`

#### Scenario: 反解不提前结束

- **WHEN** POP3 正文中包含一行 `..` 与一行单独的 `.`（原始内容）
- **THEN** `..` 被还原为 `.`，而传输层的 `..`（原始为 `.`）不会终止读取

### Requirement: literal 传输

IMAP 的 `{n}` literal SHALL 由 `LineChannel.readExact(n)` 按字节精确读取，且 MUST NOT
经过 `String`。接收侧遇到 `{n}` 时，小 literal MAY 进内存，大 literal MUST 写入
`BodySource` 或调用方提供的 `OutputStream`。同一连接上声明的 literal 总长度超过
`maxLiteralBytes` 时 MUST 抛 `MailLimitException(kind=Literal)` 并关闭连接。

#### Scenario: 大 literal 不驻留内存

- **WHEN** 服务器返回 `{10485760}` 并紧随 10 MB 数据
- **THEN** 数据边读边写入目标 sink，进程内存增量不随 literal 大小线性增长

#### Scenario: literal 超限

- **WHEN** 声明的 literal 长度超过 `maxLiteralBytes`（默认 64 MB）
- **THEN** 抛 `MailLimitException(kind=Literal)`，连接被关闭而不是继续读

### Requirement: 超时与连接生命周期

传输层 SHALL 提供 `connect` / `greeting` / `command` / `data` / `idle` 五类超时；
命令总超时 MUST 由 deadline 折算成每次读写的剩余时长，而不是依赖单次系统调用超时。
`idle` 超时 MUST 只用于 IDLE 期间的读等待与事件轮询判断，MUST NOT 在 IDLE 期间因为
长时间没有数据而关闭连接（健康的长连接本来就长时间静默）。
超时 MUST 映射为 `MailIoException(stage=Timeout)` 并关闭连接。任何协议错误、超时、
EOF 都必须关闭连接，MUST NOT 尝试"跳过一行继续"。`close()` MUST 幂等，
且 MUST 允许从其它线程调用以打断阻塞中的读——被打断的读 MUST 以 `MailIoException` 结束，
MUST NOT 返回伪数据，也不得把异常抛到调用 `close()` 的线程上。

#### Scenario: 命令总超时

- **WHEN** 服务器每 50 ms 返回一个字节，持续超过 `command` 超时
- **THEN** 抛 `MailIoException(stage=Timeout)`，且 `isClosed()` 为真

#### Scenario: IDLE 静默不算超时

- **WHEN** 连接处于 IDLE，连续 20 分钟没有任何服务器数据
- **THEN** 连接不被关闭，`command` 超时不生效，仅有 `idle` 超时按配置让 `nextEvent` 返回 `None`

#### Scenario: 跨线程 close

- **WHEN** 一个线程阻塞在读上，另一个线程对该连接调用 `close()`
- **THEN** 阻塞的读在有限时间内以 `MailIoException` 结束，连接状态为已关闭，调用 `close()` 的线程不收到异常

#### Scenario: 重复 close

- **WHEN** 对已关闭的连接再次调用 `close()`
- **THEN** 不抛异常

### Requirement: 可注入的传输与脱敏跟踪

传输层 SHALL 暴露 `TransportFactory`，使测试可以注入字节脚本（`ScriptedTransport`）
而不依赖真实网络。`MailTrace` SHALL 只能拿到已脱敏的行：`AUTH`、`PASS`、`LOGIN`
的参数一律替换为 `<redacted>`；正文默认不回调 `onLine`，只在 `onBytes` 报告字节数。
IDLE 期间的 untagged 行（`* 173 EXISTS` 等）与 `DONE` MUST 走 `onLine`——它们不含凭据，
且是排查"事件为什么没来"的唯一线索。

#### Scenario: 凭据不进跟踪

- **WHEN** 客户端发送 `AUTH PLAIN AHVzZXIAcGFzcw==` 且启用了 `MailTrace`
- **THEN** `onLine` 收到的内容是 `AUTH PLAIN <redacted>`

#### Scenario: 脚本化传输

- **WHEN** 测试用 `ScriptedTransport` 预置 `220 ready\r\n` 后构建 SMTP 客户端
- **THEN** 客户端成功完成握手，且测试能逐字节断言客户端后续写出的内容

#### Scenario: IDLE 行进跟踪

- **WHEN** 连接处于 IDLE 且收到 `* 173 EXISTS`，随后客户端写出 `DONE`
- **THEN** `onLine` 依次收到该 untagged 行与 `DONE`，两者都未被脱敏或丢弃
