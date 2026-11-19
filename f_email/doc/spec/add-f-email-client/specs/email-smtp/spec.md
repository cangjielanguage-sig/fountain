## Purpose

提供基于 SMTP 的发信能力：EHLO 能力协商与回退、STARTTLS 升级、四种 AUTH 机制、MAIL/RCPT/DATA 投递事务、PIPELINING 顺序、Bcc 剥离与逐收件人的投递结果报告，并对错误做不自动重试的分类。

## ADDED Requirements

### Requirement: 建连时机与 builder 校验

`SmtpClient.build()` SHALL 在同一次调用内完成 TCP 连接、读 greeting、`EHLO`、
按配置 `STARTTLS`、按配置 `AUTH`，返回后 `capabilities` 即可用；连接失败与认证失败
MUST 在 `build()` 抛出。`send()` MUST 只做事务，不重新握手。
builder 的配置校验 MUST 在 `build()` 阶段完成：`requireEncryption=true`（默认）且
`tls=None` 时抛 `IllegalArgumentException`；配置了凭据但既无 TLS 又未显式
`allowPlaintextAuth(true)` 时同样抛 `IllegalArgumentException`。

#### Scenario: 明文配置被拒

- **WHEN** 调用 `SmtpClient.builder(host).build()`（默认 `requireEncryption=true`，未设 TLS）
- **THEN** 在建立连接之前抛 `IllegalArgumentException`

#### Scenario: 能力立即可用

- **WHEN** `build()` 成功返回
- **THEN** 不发送任何额外命令即可读到 `capabilities.size`、`supportsStartTls` 等属性

### Requirement: EHLO 与能力表

客户端 SHALL 发送 `EHLO <helloName>` 并解析多行响应（`250-` 续行，最后一行 `250 `）。
`EHLO` 返回 `500`/`502`/`504` 时 MUST 回退到 `HELO`；`HELO` 成功后能力表为空，
`STARTTLS`/`AUTH`/`SIZE`/`PIPELINING` 全部视为不可用。若配置要求 TLS 或认证，
回退后 MUST 直接失败。`helloName` 为空时 MUST 使用本机 hostname，取不到用 `localhost`。

#### Scenario: 多行 EHLO

- **WHEN** 服务器返回 `250-smtp.example.com`、`250-SIZE 35882577`、`250 AUTH PLAIN LOGIN`
- **THEN** `capabilities.size` 为 35882577，`authMechanisms` 为 `["PLAIN", "LOGIN"]`

#### Scenario: 不支持 EHLO 且要求 TLS

- **WHEN** `EHLO` 返回 502，`HELO` 成功，但客户端配置了 `StartTls`
- **THEN** 抛 `MailProtocolException`，不发送任何凭据

### Requirement: STARTTLS 与重新 EHLO

配置 `StartTls` 时，客户端 SHALL 在 `EHLO` 广告 `STARTTLS` 后发送 `STARTTLS`，
收到 `220` 后升级 TLS，并 MUST 重新发送 `EHLO` 使其能力表生效。
服务器未广告 `STARTTLS` 时 MUST 抛错而不是继续明文。
升级前 MUST NOT 发送任何凭据（除非显式 `allowPlaintextAuth(true)`）。

#### Scenario: TLS 前后能力不同

- **WHEN** 升级前的 EHLO 不含 `AUTH`，升级后的 EHLO 含 `AUTH PLAIN`
- **THEN** 客户端使用升级后的能力表决定可用认证机制

#### Scenario: 未广告 STARTTLS

- **WHEN** 配置 `StartTls` 但 EHLO 回复中没有 `STARTTLS`
- **THEN** 抛 `MailProtocolException`，socket 上不出现 `AUTH` 与 `MAIL FROM`

### Requirement: AUTH 机制

客户端 SHALL 支持 `PLAIN`、`LOGIN`、`CRAM-MD5`、`XOAUTH2` 四种机制，默认只在 TLS 之后使用。
调用方未指定机制时 MUST 按 `XOAUTH2 > CRAM-MD5 > PLAIN > LOGIN` 选择服务器广告且配置可用的第一个。
机制失败 MUST NOT 自动降级到其它机制。
`XOAUTH2` 收到 `334` 挑战时 MUST 先发送一个空行结束挑战再读最终回复，MUST NOT 视为成功。

#### Scenario: PLAIN 逐字节

- **WHEN** 用户为 `user`、密码为 `pass`，使用 `PLAIN`
- **THEN** 客户端写出 `AUTH PLAIN ` 加 `base64("\0user\0pass")`

#### Scenario: CRAM-MD5 摘要

- **WHEN** 服务器返回 `334 <base64 challenge>`
- **THEN** 客户端写出 `base64(user + " " + hex(HMAC-MD5(pass, challenge)))`，十六进制为小写

#### Scenario: XOAUTH2 失败

- **WHEN** 服务器对 `AUTH XOAUTH2` 返回 `334 <base64 JSON>` 然后等待
- **THEN** 客户端发送空行，再读到 `535` 并抛 `MailAuthException`

### Requirement: 投递事务与逐收件人结果

`send()` SHALL 依次执行 `MAIL FROM`、逐收件人 `RCPT TO`、按 `SendPolicy` 决定是否 `DATA`。
`BestEffort` MUST 在至少一个收件人返回 2xx 时进入 `DATA`；`AllOrNothing` MUST 要求全部 2xx，
否则 `RSET` 中止。逐收件人的 2xx 进 `accepted`、4xx/5xx 进 `rejected` 并保留 code/enhanced/text。
只要拿到整封邮件的最终回复，MUST 返回 `SendReport` 而不是抛异常（包括全部收件人被拒）。

#### Scenario: 部分拒收（BestEffort）

- **WHEN** 两个收件人中一个返回 250、一个返回 550
- **THEN** 客户端进入 `DATA` 并投递，`accepted` 含前者，`rejected` 含后者，`isCompleteSuccess()` 为 false

#### Scenario: 部分拒收（AllOrNothing）

- **WHEN** 同样场景但策略为 `AllOrNothing`
- **THEN** 客户端不进入 `DATA`，发送 `RSET`，`aborted` 为 true，`accepted` 为空

#### Scenario: 全部拒收不抛异常

- **WHEN** 所有收件人都返回 550
- **THEN** `send()` 正常返回，`rejected` 含全部收件人，`reply` 为最后一条 550

### Requirement: Bcc 剥离

`SmtpClient` 在序列化 MUST 跳过 `Bcc` 头，且 MUST NOT 修改调用方传入的 `MailMessage`。
这是发送路径的硬规则，MUST NOT 提供保留 `Bcc` 的选项。

#### Scenario: 报文无 Bcc

- **WHEN** 发送一封含 `Bcc: hidden@example.com` 的邮件
- **THEN** 传输的报文中不含 `Bcc` 头，但 `hidden@example.com` 出现在 `RCPT TO` 中

### Requirement: PIPELINING

当服务器广告 `PIPELINING` 时，`BestEffort` 策略 SHALL 一次写出 `MAIL FROM`、全部 `RCPT TO`
与 `DATA` 后统一按序读取回复。若 `DATA` 回复不是 `354` MUST `RSET`；
若没有任何 2xx 收件人但服务器仍返回 `354`，客户端 MUST 以 `.\r\n` 结束空事务再 `RSET`，
MUST NOT 在 DATA 状态下发送 `RSET`。`AllOrNothing` 策略 MUST NOT 将 `DATA` 纳入流水线。

#### Scenario: 回复按序消费

- **WHEN** 流水线写出 1 条 MAIL、2 条 RCPT、1 条 DATA 并依次收到 250、250、550、354
- **THEN** 第一个收件人 accepted、第二个 rejected，正文照常投递

#### Scenario: 无有效收件人但收到 354

- **WHEN** 所有 RCPT 都被拒，服务器仍返回 `354`
- **THEN** 客户端写 `.\r\n` 结束空事务，再发 `RSET`，不产生任何投递

### Requirement: 自动补齐的头与 SIZE 语义

`send()` 在序列化前 SHALL 补齐 `Date`（`MailDate.now()`）、`Message-ID`
（`<时间戳.随机.domain>`，domain 取自 `From`）、`MIME-Version`（有 MIME 结构时）。
`From` 缺失 MUST 直接报错。默认 MUST NOT 发送 `SIZE=`；`precomputeSize(true)` 或
`maxMessageBytes > 0` 时 MUST 先得到精确序列化字节数，超过 `capabilities.size` 或
`maxMessageBytes` 时 MUST 在 `MAIL FROM` 之前失败。`SIZE=` 的值 MUST 不含 dot-stuffing
与结束的 `.\r\n`。

#### Scenario: 缺 From

- **WHEN** 发送一封没有 `From` 的邮件
- **THEN** 抛 `MailProtocolException`，不发送 `MAIL FROM`

#### Scenario: 大小预检

- **WHEN** 开启 `maxMessageBytes(1024)` 并发送一封序列化后 2048 字节的邮件
- **THEN** 在 `MAIL FROM` 之前失败，不进入 `DATA`

### Requirement: 8BITMIME 与 SMTPUTF8

正文含 8 位字节且服务器支持 `8BITMIME` 时 SHALL 使用 `BODY=8BITMIME`；不支持时
MUST 由 `MimeWriter` 强制 QP/base64，MUST NOT 发送裸 8 位字节。
信封地址含非 ASCII 且服务器支持 `SMTPUTF8` 时 MUST 附加 `SMTPUTF8` 并保持头部 UTF-8
（序列化时以 `MimeWriteOptions.utf8Headers=true` 写出）；不支持时 MUST 抛 `MailProtocolException`。
仅显示名或主题含非 ASCII 时 MUST 走 RFC 2047，MUST NOT 要求 `SMTPUTF8`。

#### Scenario: 无 8BITMIME

- **WHEN** 服务器未广告 `8BITMIME`，邮件正文含中文
- **THEN** 正文以 quoted-printable 或 base64 编码发出，DATA 中不出现 8 位字节

#### Scenario: 非 ASCII 地址

- **WHEN** 信封发件人为 `用户@例子.中国` 且服务器不支持 `SMTPUTF8`
- **THEN** 抛 `MailProtocolException`，不做 punycode 转换

### Requirement: 错误分类与不自动重试

客户端 MUST NOT 自动重试任何投递。系统 SHALL 提供 `isRetryable(report)` 与
`isRetryable(error)` 分类：连接失败、超时、TLS 失败、`421`/`450`/`451`/`452` 与 4.x.x
增强码为可重试；`5xx`、`535`、`552`、全部收件人 5xx 为不可重试；
部分收件人 4xx 与全部收件人 4xx 为可重试（调用方自行去重）。

#### Scenario: 421 中途断开

- **WHEN** 服务器在事务中途返回 `421 Service not available` 并断开
- **THEN** 抛 `MailIoException`，连接被关闭，客户端不重建连接

#### Scenario: 认证失败不可重试

- **WHEN** `AUTH` 返回 `535`
- **THEN** `isRetryable` 对相应异常返回 false

### Requirement: 连接复用边界

一个 `SmtpClient` SHALL 持有一条连接并支持连续 `send`。下一次 `send` 前若 `isClosed()`
或 `NOOP` 失败 MUST 抛 `MailIoException`，MUST NOT 在 `send` 内部自动重连。
客户端 MUST NOT 声明线程安全；并发发信由调用方每线程一个实例完成。

#### Scenario: 空闲断连后发送

- **WHEN** 服务器在两封邮件之间关闭连接，调用方再次 `send()`
- **THEN** 抛 `MailIoException`，调用方可自行重建客户端
