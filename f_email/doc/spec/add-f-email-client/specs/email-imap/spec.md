## Purpose

提供 IMAP4rev1 客户端能力：tagged/untagged/continuation 分发、literal 收发、邮箱选择与列表、FETCH、SEARCH、STORE/EXPUNGE、COPY/APPEND，并扩展 IDLE 事件会话、MOVE、SPECIAL-USE、NAMESPACE、UTF8=ACCEPT、CONDSTORE/QRESYNC 与 SORT/THREAD。

## ADDED Requirements

### Requirement: 会话与响应分发

客户端 SHALL 按 tag 匹配命令的 tagged 回复，untagged 响应 MUST 进入分发器：
既可能属于当前命令（`FETCH`、`SEARCH`），也可能是状态更新（`EXISTS`、`RECENT`、`EXPUNGE`、`FLAGS`）。
continuation `+` MUST 只用于 literal、`AUTHENTICATE` 挑战与 `IDLE`。收到 `* BYE` 时 MUST 记录原因、
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
邮箱名 MUST 先按 modified UTF-7 编码成 ASCII，**除非** `UTF8=ACCEPT` 已通过 `ENABLE` 生效
（见「UTF8=ACCEPT」），此时 MUST 直接发送 UTF-8。除 `INBOX` 外邮箱名 MUST 大小写敏感。

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
字符串参数 MUST 按 quoted string 或 literal 编码。
`UTF8=ACCEPT` 已生效时 MUST 省略 `CHARSET` 并直接发送 UTF-8；未生效时非 ASCII MUST 声明
`CHARSET UTF-8`（服务器支持时），否则 MUST 抛 `MailProtocolException`。
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

### Requirement: ENABLE 与扩展能力协商

客户端 SHALL 区分两件事：`CAPABILITY` 广告的能力（`capabilities.supportsXxx`）与
`ENABLE` 后由 `* ENABLED` 回显的能力（`isEnabled(cap)`）。扩展 API 的放行条件 MUST 是后者。
`ENABLE` MUST 只在已认证状态发送；未认证时调用 MUST 在本地抛 `MailProtocolException` 且不写任何字节。
`ENABLE` 返回 `NO`/`BAD` 或回显列表缺少某项时，MUST 视为该项未启用而**不**使连接不可用。
`ENABLE` MUST 在任何受其影响的命令之前发送：`UTF8=ACCEPT` 早于 `SELECT`/`SEARCH`/`APPEND`，
`QRESYNC` 早于带 `QRESYNC` 参数的 `SELECT`。
调用未广告或未启用的扩展 MUST 抛 `MailProtocolException(capability=…)`，MUST NOT 静默退化成近似行为。

#### Scenario: 回显才置位

- **WHEN** 发送 `ENABLE UTF8=ACCEPT QRESYNC`，服务器只回 `* ENABLED UTF8=ACCEPT`
- **THEN** `isEnabled(utf8Accept)` 为真，`isEnabled(qresync)` 为假，随后调用 QRESYNC 相关 API 抛 `MailProtocolException`

#### Scenario: 未认证时启用

- **WHEN** 在 `login()` 之前调用 `enable([ImapCapability.Utf8Accept])`
- **THEN** 抛 `MailProtocolException`，socket 上不出现 `ENABLE`

#### Scenario: 扩展不可用

- **WHEN** 服务器 `CAPABILITY` 未广告 `MOVE` 而调用 `move(...)`
- **THEN** 抛 `MailProtocolException`，其中带 `capability=MOVE`，socket 上不出现 `MOVE`/`COPY`

### Requirement: IDLE 事件会话

`idle()` SHALL 返回 `IdleSession`，`nextEvent(timeout)` 消费事件，`close()` 结束会话。
前置条件 MUST 为已认证且已 `SELECT`/`EXAMINE`，否则抛 `MailProtocolException` 且不发命令。
`IDLE` 期间 MUST NOT 发送其它命令，调用 MUST 立即抛 `MailProtocolException("connection is idle")`。
untagged 响应 MUST 转成 `ImapEvent` 入队，未知响应归入 `Other`；用户回调 MUST NOT 在读线程执行。
`nextEvent` 超时 MUST 返回 `None` 且不关闭连接。连续 IDLE 超过 25 分钟 MUST 发 `DONE`、
等 tagged `OK` 后重新 `IDLE`，`DONE` MUST 不带 tag。`* BYE` MUST 先投递 `Bye` 再结束会话；
`close()` MUST 先发 `DONE` 再停读线程，且 MUST 幂等。

#### Scenario: 事件投递

- **WHEN** `idle()` 收到 `+ idling` 后服务器推送 `* 173 EXISTS`
- **THEN** `nextEvent` 返回 `Exists(173)`

#### Scenario: 25 分钟重建

- **WHEN** 会话已 IDLE 满 25 分钟且期间无任何事件
- **THEN** 客户端写出 `DONE`，收 tagged `OK` 后重新发送 `IDLE`，期间不关闭连接

#### Scenario: IDLE 中的命令

- **WHEN** `IdleSession` 仍处于 IDLE 时调用 `fetch(...)`
- **THEN** 立即抛 `MailProtocolException`，socket 上不出现该 `FETCH`

#### Scenario: 未选中邮箱

- **WHEN** 未 `SELECT` 时调用 `idle()`
- **THEN** 抛 `MailProtocolException`，socket 上不出现 `IDLE`

#### Scenario: 服务器断连

- **WHEN** IDLE 期间服务器直接关闭 TCP
- **THEN** 阻塞中的 `nextEvent` 抛 `MailIoException`，`isClosed()` 为真，无异常逃逸到其它线程

### Requirement: MOVE

`move`/`uidMove` SHALL 在服务器广告 `MOVE` 时用 `MOVE` 命令完成搬家，并解析
`[COPYUID uidvalidity srcuids dstuids]` 为 `MoveResult`，同时消费 `* VANISHED`（QRESYNC 生效时）
或 `* EXPUNGE`。服务器未广告 `MOVE` 时默认 MUST 抛 `MailProtocolException`。
只有调用方显式 `allowNonAtomicMove(true)` 时 MAY 回退为
`UID COPY` → `UID STORE +FLAGS.SILENT (\Deleted)` → `UID EXPUNGE`；
无 `UIDPLUS` 时第三次回退为 `EXPUNGE` 并 MUST 记告警。回退结果 MUST 标 `atomic=false`。

#### Scenario: 支持 MOVE

- **WHEN** 服务器广告 `MOVE`，调用 `uidMove(set, "Archive")`
- **THEN** 客户端发送 `UID MOVE <set> "Archive"`，返回的 `MoveResult` 含 `copyUid` 与被删 UID

#### Scenario: 不支持且未开启回退

- **WHEN** 服务器未广告 `MOVE`，`allowNonAtomicMove` 未开启而调用 `move(...)`
- **THEN** 抛 `MailProtocolException`，socket 上不出现 `COPY` 与 `STORE`

#### Scenario: 显式回退

- **WHEN** 未广告 `MOVE` 但开启了非原子回退且服务器支持 `UIDPLUS`
- **THEN** 依次写出 `UID COPY`、`UID STORE +FLAGS.SILENT (\Deleted)`、`UID EXPUNGE`，结果 `atomic=false`

### Requirement: SPECIAL-USE

`list`/`lsub` 的 attributes MUST 解析 special-use 属性 `\All`/`\Archive`/`\Drafts`/`\Flagged`/
`\Junk`/`\Sent`/`\Trash` 到 `MailboxInfo.specialUse`；未识别的 `\Xxx` MUST 保留在 attributes 中
且 MUST NOT 报错。`listSpecialUse()` SHALL 发送 `LIST (SPECIAL-USE) "" "*"`；
服务器未广告 `SPECIAL-USE` 时 MUST 抛 `MailProtocolException`，MUST NOT 退化为全量 `LIST` 后按名字猜。

#### Scenario: 系统文件夹

- **WHEN** `LIST "" "*"` 返回 `(\HasNoChildren \Sent) "/" "Sent"`
- **THEN** `MailboxInfo.specialUse` 为 `Sent`，`delimiter` 为 `/`

#### Scenario: 自定义属性

- **WHEN** attributes 中只有 `\NoInferiors \Foo`
- **THEN** `specialUse` 为 `None`，`attributes` 仍含 `\Foo`，不抛异常

#### Scenario: 无能力时列表

- **WHEN** 服务器未广告 `SPECIAL-USE` 而调用 `listSpecialUse()`
- **THEN** 抛 `MailProtocolException`，socket 上不出现 `LIST (SPECIAL-USE)`

### Requirement: NAMESPACE

`namespace()` SHALL 返回 `NamespaceInfo`，其 `personal`/`otherUsers`/`shared` 三段分别为
`(prefix, delimiter)` 列表，`NIL` MUST 映射为空（`None`）而不是空字符串。
三段全 `NIL` 时 MUST 返回三段皆空的 `NamespaceInfo`，MUST NOT 抛错。
服务器未广告 `NAMESPACE` 时 MUST 抛 `MailProtocolException`。
`joinPath()` SHALL 按 delimiter 拼接前缀与邮箱名，MUST NOT 产生重复分隔符；
delimiter 为 `None`（扁平命名空间）时 MUST 直接拼接。

#### Scenario: 个人命名空间

- **WHEN** 服务器回 `* NAMESPACE (("" "/")) NIL NIL`
- **THEN** `personal` 含一项 `(prefix="", delimiter="/")`，`otherUsers` 与 `shared` 为 `None`

#### Scenario: 全 NIL

- **WHEN** 服务器回 `* NAMESPACE NIL NIL NIL`
- **THEN** 返回三段皆空的 `NamespaceInfo`，不抛异常

#### Scenario: 拼接

- **WHEN** 段落为 `(prefix="INBOX.", delimiter=".")`，调用 `joinPath(ns, "Sent")`
- **THEN** 结果为 `INBOX.Sent`，不出现 `INBOX..Sent`

### Requirement: UTF8=ACCEPT

`UTF8=ACCEPT` 经 `ENABLE` 生效后，客户端 SHALL 切换三处行为：邮箱名直接以 UTF-8 发送与解析
（MUST NOT 再做 modified UTF-7）；`SEARCH` 的字符串直接以 UTF-8 发送且 MUST NOT 带
`CHARSET` 参数；`APPEND` 接受含 UTF-8 头部的报文。
`SORT`/`THREAD` 的 `charset` 参数 MUST 保持显式给出（见各自需求），不因该能力改变。
未生效时 MUST 完整走 modified UTF-7 路径（M3 行为），MUST NOT 采用"先试 UTF-8、失败再编码"的降级策略。
`UTF8=ONLY` 的服务器 MUST 视为 `UTF8=ACCEPT` 已生效且 MUST NOT 发送 modified UTF-7。

#### Scenario: 启用后直传

- **WHEN** 已 `ENABLE UTF8=ACCEPT`，调用 `select("已发送")`
- **THEN** 命令中的邮箱名是裸 UTF-8 字节，不含 `&` 开头的 modified UTF-7 编码段

#### Scenario: 未启用时仍走 UTF-7

- **WHEN** 未 `ENABLE UTF8=ACCEPT`，调用 `select("已发送")`
- **THEN** 命令中的邮箱名是 modified UTF-7 形式

#### Scenario: 启用后的列表解码

- **WHEN** 已启用且 `LIST` 返回 UTF-8 邮箱名
- **THEN** `MailboxInfo.name` 与原始中文名一致，不做 modified UTF-7 解码

### Requirement: CONDSTORE

`select`/`examine` SHALL 支持 `condstore: true`，发送 `SELECT <mailbox> (CONDSTORE)` 并解析
`* OK [HIGHESTMODSEQ n]` 到 `MailboxStatus.highestModSeq`。
`FetchItem` SHOULD 支持 `MODSEQ` 与 `(CHANGEDSINCE n)`，结果暴露 `FetchMeta.modSeq`。
`store` SHALL 支持 `unchangedSince`，发送 `STORE (UNCHANGEDSINCE n) …`，返回 `StoreResult`。
服务器回 `* OK [MODIFIED <set>]` 时这些序号 MUST 进 `StoreResult.modified`，MUST NOT 视为成功。
未广告 `CONDSTORE` 时使用上述参数 MUST 抛 `MailProtocolException(capability=CONDSTORE)`。

#### Scenario: 最高修改序号

- **WHEN** `SELECT INBOX (CONDSTORE)` 返回 `* OK [HIGHESTMODSEQ 12345]`
- **THEN** `MailboxStatus.highestModSeq` 为 12345

#### Scenario: 乐观并发失败

- **WHEN** `store(set, Add, ["\\Flagged"], unchangedSince: 100)` 且服务器回 `* OK [MODIFIED 4]`
- **THEN** `StoreResult.modified` 含 4，第 4 封的 flags 不被视为已更新

#### Scenario: 能力缺失

- **WHEN** 服务器未广告 `CONDSTORE` 而传入 `unchangedSince`
- **THEN** 抛 `MailProtocolException(capability=CONDSTORE)`，不发 `STORE`

### Requirement: QRESYNC

`QRESYNC` 生效后 SHALL 提供快速重同步：`select` 支持 `qresync: QResyncParams(uidValidity, modSeq, …)`，
发送 `SELECT <mailbox> (QRESYNC (<uidvalidity> <modseq> [known-uids [(known-seqs known-uids)]]))`。
`* VANISHED (EARLIER) <uid-set>` MUST 解析为 `Vanished(earlier=true)` 并可通过 `MailboxStatus.vanished` 读取。
普通 `* VANISHED <uid-set>` MUST 与 `EXPUNGE` 一样在响应分发中被消费；未启用 QRESYNC 时收到
`VANISHED` MUST 仍解析为 vanished 并记告警，MUST NOT 视为协议错误。
启用 QRESYNC 时 MUST NOT 再单独发送 `ENABLE CONDSTORE`。

#### Scenario: 补齐离线期间删除

- **WHEN** `SELECT INBOX (QRESYNC (3857529045 12345))` 返回 `* VANISHED (EARLIER) 41:43`
- **THEN** `vanished` 含 UID 41、42、43，`earlier` 为 true

#### Scenario: 不重复 ENABLE

- **WHEN** 配置启用 QRESYNC
- **THEN** `ENABLE` 命令里只出现 `QRESYNC`，不出现 `CONDSTORE`

#### Scenario: 未启用时收到 VANISHED

- **WHEN** 普通 `FETCH` 期间收到 `* VANISHED 100:102`
- **THEN** 解析为 vanished 事件并记告警，命令正常结束

### Requirement: SORT

`sort`/`uidSort` SHALL 发送 `SORT (<keys>) <charset> <criteria>` 并解析 `* SORT n n n`。
`SortCriteria` MUST 支持 `ARRIVAL`/`CC`/`DATE`/`FROM`/`SIZE`/`SUBJECT`/`TO` 与 `REVERSE` 前缀；
`SORT=DISPLAY` 生效时 MUST 另外支持 `DISPLAY FROM`/`DISPLAY TO`。
`charset` 只允许 `US-ASCII` 与 `UTF-8`，其它值 MUST 在本地抛 `MailProtocolException`；
`charset` MUST 始终显式给出，不受 `UTF8=ACCEPT` 影响（`SORT` 没有可省略字符集的语法）。
服务器未广告 `SORT` 时 MUST 抛 `MailProtocolException(capability=SORT)`。
结果顺序 MUST 与服务器一致，MUST NOT 重排或去重。

#### Scenario: 按日期倒序

- **WHEN** `uidSort([SortKey.date.reversed()], Charset.Utf8, SearchCriteria.all())`
- **THEN** 命令为 `UID SORT (REVERSE DATE) UTF-8 ALL`

#### Scenario: 结果保序

- **WHEN** 服务器回 `* SORT 3 1 2`
- **THEN** 返回的序列为 `[3, 1, 2]`

#### Scenario: 未广告

- **WHEN** 服务器未广告 `SORT` 而调用 `sort(...)`
- **THEN** 抛 `MailProtocolException(capability=SORT)`，socket 上不出现 `SORT`

### Requirement: THREAD

`thread`/`uidThread` SHALL 发送 `THREAD <algorithm> <charset> <criteria>` 并把
`* THREAD (…)` 解析为 `ThreadNode` 树，同一层兄弟顺序 MUST 与服务器一致。
算法 MUST 为 `ORDEREDSUBJECT` 或 `REFERENCES`，放行条件分别是能力位
`THREAD=ORDEREDSUBJECT` / `THREAD=REFERENCES`；只广告一种时请求另一种 MUST 抛
`MailProtocolException(capability=…)`，MUST NOT 换成另一种算法。
`charset` 规则与 `SORT` 相同。

#### Scenario: 嵌套线程树

- **WHEN** 服务器回 `* THREAD (2)(3 6 (4 23)(44 7 96))`
- **THEN** 得到两个顶层线程：第一个只含 2；第二个含 3、6、4、23、44、7、96，
  其中 `(4 23)` 与 `(44 7 96)` 是嵌套子列表，层级与响应完全一致

#### Scenario: 算法不支持

- **WHEN** 服务器只广告 `THREAD=ORDEREDSUBJECT` 而请求 `REFERENCES`
- **THEN** 抛 `MailProtocolException(capability=THREAD=REFERENCES)`，不发命令
