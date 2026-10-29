## Purpose

定义"一封信是什么"的最小模型：头字段容器、地址与日期的解析生成、消息与正文来源、信封推导、凭据包装与异常层次。它不碰 socket，也不做 MIME 编解码，为协议层与 MIME 层提供共享的数据结构。

## ADDED Requirements

### Requirement: 头字段容器

`HeaderMap` SHALL 保留原始的字段顺序与大小写，查找 MUST 不区分大小写，并允许同名重复字段。
`set()` MUST 覆盖第一个同名项并删除其余同名项，`add()` MUST 追加。解析时 MUST 把
`CRLF + WSP` 折行展开为单个空格；生成时按 78 octets 重新折行。
任何值含 `\r` 或 `\n` MUST 抛 `MailProtocolException`；字段名 MUST 只允许可见 ASCII 中除
`:` 以外的字符。998 octets 是**物理行**上限，由 `MimeWriter` 生成时折行保证；`HeaderMap` 只校验 CR/LF，解析后的展开值可以超过 998。
字段值 MUST 按字节保留原样：允许出现非 ASCII 的 UTF-8 字节（RFC 6532，`UTF8=ACCEPT` 与
`SMTPUTF8` 场景下合法），解析层 MUST NOT 因值不是 ASCII 而拒绝、替换或丢弃字符。

#### Scenario: Received 链保序

- **WHEN** 解析含三条 `Received` 头的邮件
- **THEN** `entries()` 按原文顺序返回三条，`get("received")` 返回第一条

#### Scenario: 头部注入

- **WHEN** 调用方执行 `headers.set("Subject", "x\r\nBcc: victim@example.com")`
- **THEN** 抛 `MailProtocolException`，不产生任何头字段

#### Scenario: 折行展开

- **WHEN** 解析 `Subject: hello\r\n world`
- **THEN** `get("Subject")` 返回 `hello world`

#### Scenario: 裸 UTF-8 头部值

- **WHEN** 解析一封头部含裸 UTF-8 的 `Subject: 中文主题`（RFC 6532）
- **THEN** `get("Subject")` 返回 `中文主题`，无替换字符，`entries()` 保序不变

### Requirement: 地址解析与生成

`EmailAddress` 与 `AddressList` SHALL 支持 `addr-spec`、`name-addr`、引号显示名、
注释、组语法、域字面量、引号本地部分；废弃路由语法 MUST 在解析时接受、在生成时拒绝。
生成时，非 ASCII 显示名 MUST 用 RFC 2047 编码，纯 ASCII 且无特殊字符时 MUST 原样输出。
`address` 中包含 `\r`、`\n`、`<`、`>` MUST 抛异常。地址本身含非 ASCII 时，
只有服务器支持 `SMTPUTF8` 才允许发送，否则 MUST 抛 `MailProtocolException`（不隐式 punycode）。

#### Scenario: 组语法

- **WHEN** 解析 `Team: a@x.com, b@y.com;`
- **THEN** 得到两个地址 `a@x.com` 与 `b@y.com`

#### Scenario: 引号显示名往返

- **WHEN** 解析 `"Doe, John" <j@example.com>` 后再 `toString()`
- **THEN** 显示名 `Doe, John` 被重新加引号，解析回来仍是同一地址

#### Scenario: 地址注入

- **WHEN** 构造 `EmailAddress("a@b>\r\nRCPT TO:<c@d")`
- **THEN** 抛异常，不生成任何可发送的地址

### Requirement: 日期解析与生成

`MailDate` SHALL 解析 RFC 5322 日期：星期可省略、月份大小写不敏感、两位年份按
`00–49→2000–2049` / `50–99→1950–1999`、支持数字偏移与 `UT`/`GMT` 及常见美区缩写。
缺失时区 MUST 视为 `+0000` 并记告警，MUST NOT 按本地时区猜测。
非法日期在默认（宽松）模式下 MUST 回退到 `1970-01-01` 并记告警，严格模式下抛 `MimeException`。

#### Scenario: 两位年份

- **WHEN** 解析 `Date: Wed, 28 Oct 99 21:58:52 +0800`
- **THEN** 年份为 1999

#### Scenario: 缺失时区

- **WHEN** 解析 `Date: 28 Oct 2026 21:58:52`
- **THEN** `offsetMinutes` 为 0，并记录一次告警

### Requirement: 消息模型与正文来源

`MailMessage` SHALL 是根 `MimePart` 的薄包装，`headers` 与 `root.headers` MUST 是同一对象。
`PartBody` MUST 能表达 `Text`（小文本）、`Data`（大文本或二进制，已解 CTE）、`Parts`
（multipart）、`Embedded`（`message/rfc822`）与 `Empty`。解码后不超过 `inlineTextLimit`
（默认 256 KB）的 `text/*` 进 `Text`，其余进 `Data(BodySource)`。
`BodySource` MUST 提供 `open()`、`size`、`reusable`；一次性来源第二次 `open()` MUST 抛异常。

#### Scenario: 大正文不进 Text

- **WHEN** 解析一个解 CTE 后 1 MB 的 `text/plain` part
- **THEN** 该 part 的 body 为 `Data`，且其 `BodySource` 可被打开读取

#### Scenario: 一次性来源重复打开

- **WHEN** 对基于 `StreamBodySource` 的 part 连续调用两次 `text()`
- **THEN** 第二次抛异常，提示先落盘为 `FileBodySource`

### Requirement: 便捷取值语义

`MailMessage.text()` / `html()` / `attachments()` SHALL 按固定规则取值：`text()` 在
`multipart/alternative` 取第一个 `text/plain`，在 `multipart/mixed` 的非附件 part 中递归查找，
找不到返回 `None`；`html()` 只找 `text/html`，MUST NOT 用纯文本顶替；
`attachments()` 返回 `Content-Disposition: attachment` 的 part 或带 `filename` 的非文本 part，
`inline` 图片不算附件。三者 MUST NOT 做 HTML 渲染或 HTML 转纯文本。

#### Scenario: 只有 HTML 的邮件

- **WHEN** 邮件仅含 `text/html`
- **THEN** `text()` 返回 `None`，`html()` 返回 HTML 原文

#### Scenario: inline 图片不算附件

- **WHEN** 邮件含一张 `Content-Disposition: inline` 的 `image/png`
- **THEN** `attachments()` 不包含它，但 `children()` 能遍历到

### Requirement: 信封推导

`Envelope.fromMessage` SHALL 优先使用 `Resent-*` 字段，其次使用 `From`/`To`/`Cc`/`Bcc`，
只取 `addr-spec` 不取显示名。`From` 缺失，或 `To`+`Cc`+`Bcc` 全空时 MUST 抛
`MailProtocolException`。反路径允许为空串（`<>`）。

#### Scenario: Resent 优先

- **WHEN** 邮件同时含 `From: a@x` 与 `Resent-From: b@y`
- **THEN** 信封发件人是 `b@y`

#### Scenario: 无收件人

- **WHEN** 邮件只有 `From`，没有 `To`/`Cc`/`Bcc`，也没有 `Resent-*`
- **THEN** 抛 `MailProtocolException`

### Requirement: 凭据包装

`Secret` MUST 不提供直接取值方法，只提供 `use((String) -> T)` 让调用方在回调内使用；
`toString()` MUST 恒为 `<redacted>`；凭据 MUST NOT 出现在异常消息、日志或协议跟踪中。

#### Scenario: 凭据不外泄

- **WHEN** 把 `Secret` 拼进字符串或打印
- **THEN** 输出为 `<redacted>`，且无法从任何公开 API 取回原文

### Requirement: 异常层次

异常 SHALL 以 `MailException` 为根，并提供 `MailIoException(stage)`、
`MailProtocolException(command, reply)`、`MailAuthException(mechanism, code)`、
`MailLimitException(kind, limit, actual)`、`MimeException(partPath, offset)`、
`MailTlsException`。`MailProtocolException.command` 在 `AUTH`/`PASS`/`LOGIN` 场景下
MUST 被替换为 `<redacted>`。

#### Scenario: 认证失败异常不含挑战

- **WHEN** CRAM-MD5 认证被服务器以 `535` 拒绝
- **THEN** 抛 `MailAuthException`，其中只保留机制名与状态码，不含 challenge 与 response
