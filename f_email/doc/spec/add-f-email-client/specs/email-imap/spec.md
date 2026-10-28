## ADDED Requirements

### Requirement: 会话与响应分发

客户端 SHALL 按 tag 匹配命令的 tagged 回复，untagged 响应 MUST 进入分发器：
既可能属于当前命令（`FETCH`、`SEARCH`），也可能是状态更新（`EXISTS`、`RECENT`、`EXPUNGE`、`FLAGS`）。
continuation `+` MUST 只用于 literal 与 `AUTHENTICATE` 挑战。收到 `* BYE` 时 MUST 记录原因、
让当前命令失败并标记连接不可用。
tag MUST 为 `A` + 四位十六进制递增，超过 `AFFFF` 后进位为 `B0001`，MUST NOT 回绕。

#### Scenario: untagged 在 tagged 之前到达

- **WHEN** 发送 `A0002 SELECT INBOX`，服务器先回 5 条 untagged 再回 `A0002 OK`
- **THEN** `select()` 返回的结果包含 `EXISTS`/`RECENT`/`UIDVALIDITY`/`FLAGS`，且命令被正确判定成功

#### Scenario: 命令期间收到 BYE

- **WHEN** 执行 `FETCH` 期间服务器发送 `* BYE Server shutting down`
- **THEN** 当前命令抛 `MailProtocolException`，`isClosed()` 为真

### Requirement: literal 的收发

发送侧遇到 literal 时 MUST 在同步模式下等待 `+` 后才写数据，仅在 `LITERAL+` 可用时
使用 `{n+}` 直接写。接收侧遇到 `{n}` MUST 用 `readExact(n)` 精确读取，
大 literal MUST 直接写入 `BodySource` 或 `FetchSink`，MUST NOT 经过 `String` 或整体数组。
单个 literal 超过 `maxLiteralBytes`（默认 64 MB）时 MUST 抛 `MailLimitException` 并关闭连接。

#### Scenario: 同步 literal

- **WHEN** 发送 `APPEND` 且 `LITERAL+` 不可用
- **THEN** 客户端写出 `{n}` 后停止，收到 `+` 才写正文

#### Scenario: 大 literal 流式

- **WHEN** `FETCH BODY[]` 返回 `{10485760}`
- **THEN** 数据被流式写入目标，解析完成后 `FetchResult.sections` 中的值为 `BodySource`

### Requirement: 命令参数编码

客户端 SHALL 按规则编码命令参数：纯 ASCII 且不含引号/反斜杠/CRLF 用 quoted string；
含 `"` 或 `\` 时转义；含非 ASCII、CRLF 或超长时改用 literal。
邮箱名 MUST 先按 modified UTF-7 编码为非 ASCII 的 UTF-8 literal 形式，除非服务器声明
`UTF8=ACCEPT`。除 `INBOX` 外邮箱名 MUST 大小写敏感。

#### Scenario: 中文邮箱名

- **WHEN** 调用 `select("已发送")` 且服务器不支持 `UTF8=ACCEPT`
- **THEN** 命令中的邮箱名以 modified UTF-7 形式出现，而不是原始 UTF-8

#### Scenario: 含引号的参数

- **WHEN** 命令参数为 `He said "hi"`
- **THEN** 参数以 quoted string 形式写出，内部引号被转义

### Requirement: 响应解析器

`ImapParser` SHALL 递归下降解析 atom、quoted、number、`NIL`、括号列表与 literal 标记，
递归深度超过 64 MUST 抛 `MailLimitException(kind=Depth)`，行上限 8 KB。
literal MUST 只在 token 中记录长度，由调用方在 `readExact` 时消费。
未知项 MUST 保留为原始 `ImapValue` 而不是丢弃。

#### Scenario: 嵌套结构

- **WHEN** 解析 `* 1 FETCH (UID 100 FLAGS (\Seen) BODYSTRUCTURE (("TEXT" "PLAIN" ...)))`
- **THEN** 得到嵌套的 `ImapValue.List`，`FLAGS` 为含 `\Seen` 的列表

#### Scenario: 深度限制

- **WHEN** 响应中出现 100 层嵌套括号
- **THEN** 抛 `MailLimitException(kind=Depth)`

### Requirement: 邮箱选择与列表

客户端 SHALL 提供 `select`/`examine` 返回 `MailboxStatus`（含 `EXISTS`、`RECENT`、
`UIDVALIDITY`、`UIDNEXT`、`UNSEEN`、`FLAGS`、`PERMANENTFLAGS`、`readOnly`），
`list`/`lsub` 返回已从 modified UTF-7 解码的 `MailboxInfo`（含 delimiter 与 attributes），
`status` 按请求项返回对应字段。`selected` 属性 MUST 反映当前已选邮箱。

#### Scenario: SELECT 结果

- **WHEN** `SELECT INBOX` 返回 `* 172 EXISTS`、`* 1 RECENT`、`* OK [UIDVALIDITY 3857529045]`
- **THEN** 返回的 `MailboxStatus.exists` 为 172，`uidValidity` 为 3857529045，`readOnly` 为 false

#### Scenario: 中文文件夹

- **WHEN** `LIST "" "*"` 返回含 modified UTF-7 编码的邮箱名
- **THEN** `MailboxInfo.name` 为解码后的中文名

### Requirement: FETCH

客户端 SHALL 支持 `FETCH`/`UID FETCH` 的元数据项（`UID`、`FLAGS`、`INTERNALDATE`、
`RFC822.SIZE`、`ENVELOPE`、`BODYSTRUCTURE`）与正文项（`BODY[section]`、
`BODY.PEEK[section]`、部分获取 `<origin.length>`）。`ENVELOPE` MUST 解析为 `ImapEnvelope`
且 subject 按 RFC 2047 解码、date 保留原文。`INTERNALDATE` MUST 按 IMAP 日期格式解析，
MUST NOT 复用 RFC 5322 解析器。
`fetchMessage`/`uidFetchMessage` MUST 使用 `BODY.PEEK[]` 且 MUST NOT 设置 `\Seen`。

#### Scenario: 部分获取

- **WHEN** 请求 `BODY.PEEK[]<0.1024>` 并收到键 `BODY[]<0>`
- **THEN** `sections` 中含一个 1024 字节的 `BodySource`，键信息保留 `<0>`

#### Scenario: 不设已读

- **WHEN** 调用 `fetchMessage(3)`
- **THEN** 命令使用 `BODY.PEEK[]`，服务器不会因本次读取设置 `\Seen`

#### Scenario: 大正文走 sink

- **WHEN** 使用带 `FetchSink` 的重载执行 `FETCH`
- **THEN** 元数据走 `onMessage`，大正文走 `onBody` 的 `InputStream`，不整体驻留内存

### Requirement: SEARCH

`SearchCriteria` SHALL 支持 `ALL`/`UNSEEN`/`SEEN`/`FROM`/`TO`/`SUBJECT`/`BODY`/`TEXT`/
`SINCE`/`BEFORE`/`HEADER`/`UID` 及 `and`/`or`/`not` 组合。
字符串参数 MUST 按 quoted string 或 literal 编码；非 ASCII MUST 声明 `CHARSET UTF-8`
（服务器支持时），否则 MUST 抛 `MailProtocolException`。
`SEARCH` 结果 MUST 解析 `* SEARCH n n n`；`uidSearch` MUST 返回 UID。

#### Scenario: 组合条件

- **WHEN** 执行 `SearchCriteria.unseen().and(SearchCriteria.from("a@b.com"))`
- **THEN** 命令中条件按 `UNSEEN FROM "a@b.com"` 的顺序写出，结果序号正确解析

### Requirement: STORE 与 EXPUNGE

`store` SHALL 支持 `Replace`/`Add`/`Remove` 三种动作，默认 MUST NOT 附加 `.SILENT`
以便拿到服务器确认的新 flags。`expunge` MUST 返回被删除序号列表；
`uidExpunge` 在 `UIDPLUS` 可用时 MUST 只删指定 UID。
系统 MUST 在文档与返回结果中明示：`EXPUNGE` 后序号会移动，需要稳定标识时用 UID。

#### Scenario: 标记已读

- **WHEN** `store(SequenceSet.single(3), StoreAction.Add, ["\\Seen"])`
- **THEN** 返回的 flags 含 `\Seen`，且命令未带 `.SILENT`

#### Scenario: UID 删除

- **WHEN** 服务器支持 `UIDPLUS` 且调用 `uidExpunge`
- **THEN** 客户端发送 `UID EXPUNGE <set>`，返回被删除的 UID 列表

### Requirement: COPY 与 APPEND

`copy` SHALL 在 `UIDPLUS` 可用时解析 `[COPYUID uidvalidity srcuids dstuids]` 并返回
`CopyResult`，否则返回不含 UID 映射的结果。
`append` MUST 先序列化到 `BodySource` 得到精确字节数再写 `{n}`；`LITERAL+` 可用时用 `{n+}`；
`UIDPLUS` 可用时 MUST 解析 `[APPENDUID uidvalidity uid]` 返回 `AppendResult`。
`date` 参数 MUST 使用 IMAP 日期格式，MUST NOT 使用 RFC 5322 格式。

#### Scenario: APPEND 精确长度

- **WHEN** 调用 `append("INBOX", message, flags: ["\\Seen"])`
- **THEN** 命令中的 `{n}` 等于随后写出的报文字节数，`APPENDUID` 被解析为 `AppendResult`

### Requirement: ID 命令

客户端 SHALL 支持在 `CAPABILITY` 之后、`LOGIN` 之前发送 `ID`（RFC 2971），
参数由 `ImapClientBuilder.id(...)` 提供。该能力 MUST 适用于要求登录前发 `ID` 的服务商
（163/126 否则返回 `Unsafe Login`）。

#### Scenario: 登录前发送 ID

- **WHEN** builder 配置了 `id({"name": "fountain", "version": "1.0"})` 并且 `build()` 成功
- **THEN** 在 `LOGIN` 之前，socket 上出现一条 `ID (...)` 命令并获得 tagged `OK`

### Requirement: modified UTF-7

`ImapUtf7.encode`/`decode` SHALL 实现 RFC 3501 §5.1.3：`&` 编码为 `&-`，
非 ASCII 连续段编码为 `&` + UTF-16BE 的 base64（`/` 替换为 `,`、去掉 `=` 填充）+ `-`。
解码失败时宽松模式 MUST 原样返回并记告警，严格模式抛 `MimeException`。

#### Scenario: 往返幂等

- **WHEN** 对 `已发送` 执行 `decode(encode(name))`
- **THEN** 结果与原始字符串相等

#### Scenario: 转义 &

- **WHEN** 编码邮箱名 `A&B`
- **THEN** 结果为 `A&-B`

### Requirement: 认证与 TLS 顺序

`build()` SHALL 只完成 TCP 连接、读 greeting、`CAPABILITY`、按配置 `STARTTLS`，MUST NOT 登录。
`STARTTLS` MUST 只在未认证状态发送，升级后 MUST 重新 `CAPABILITY` 再认证。
`AUTHENTICATE` 支持 `PLAIN`/`LOGIN`/`CRAM-MD5`/`XOAuth2`，有 `SASL-IR` 时可带初始响应；
认证失败返回 tagged `NO` 时 MUST 抛 `MailAuthException`。

#### Scenario: 升级后重新协商

- **WHEN** 明文 `CAPABILITY` 不含 `AUTH=PLAIN`，`STARTTLS` 后含该项
- **THEN** 客户端使用升级后的能力表决定认证方式

#### Scenario: 认证失败

- **WHEN** `LOGIN` 返回 `NO [AUTHENTICATIONFAILED]`
- **THEN** 抛 `MailAuthException`，`isRetryable` 为 false

### Requirement: 登出与关闭

`logout()` SHALL 发送 `LOGOUT`，读取 `* BYE` 与 tagged `OK` 后关闭连接；
`close()` MUST 直接关闭 socket，MUST NOT 发送 `LOGOUT`。两者 MUST 幂等。

#### Scenario: 礼貌登出

- **WHEN** 调用 `logout()`
- **THEN** 客户端发送 `LOGOUT`，读到 `* BYE` 与 tagged `OK` 之后连接关闭
