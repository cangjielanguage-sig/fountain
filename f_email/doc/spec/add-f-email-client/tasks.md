# 实施任务：add-f-email-client

按里程碑推进。每个阶段结束时模块必须能独立编译、单元测试全绿、可单独提交。
所有测试为仓颉单元测试，放在被测文件同目录的 `<文件名>_test.cj`。

## 1. P-0 依赖验证（硬门槛）

- [x] 1.1 在目标机（含 OHOS）用 `TlsSocket.client` 连一个真实 465 端口并校验证书，确认 `stdx.net.tls` 可用
- [x] 1.2 用真实中文邮件样本验证 `charset4cj` 对 GBK / GB18030 / BIG5 的解码结果
- [x] 1.3 验证 `stdx.encoding.base64` 对缺 padding、含空白、含非法字符的容错行为，记录需要自建兜底的范围
- [x] 1.4 验证 `stdx.crypto.digest` 的 `MD5`/`HMAC` 与 `toHexString` 输出大小写，供 CRAM-MD5 与 APOP 使用
- [x] 1.5 把三条结论写进 `f_email/README.md` 的"环境要求"小节；任一条不通则停药评审

验收：三个最小用例可跑；对不可用项给出明确退路（调用方注入 `TlsClientConfig` + 自签 CA，不默认 `TrustAll`）。

## 2. M0 传输骨架

- [x] 2.1 `MailException.cj`：`MailException` / `MailIoException` / `MailProtocolException` / `MailAuthException` / `MailLimitException` / `MimeException` / `MailTlsException`，含 `IoStage`、`LimitKind`
- [x] 2.2 `Secret.cj`：`of` / `use` / `toString` 返回 `<redacted>`；单测断言无法取回原文
- [x] 2.3 `transport/TlsMode.cj` + `MailTimeouts`
- [x] 2.4 `transport/MailConnection.cj`：open / startTls / channel / close / isClosed；默认 TLS 配置（`serverName=host`、`verifyMode=Default`）
- [x] 2.5 `transport/LineChannel.cj`：`readLine`（CRLF 与裸 LF、`maxLine`）、`readExact`（含缓冲残留）、`writeLine`（CRLF 注入拒绝）、`read`/`write`/`flush`
- [x] 2.6 `LineChannel` 的 `buffered` 开关，供 STARTTLS 升级前单字节读使用
- [x] 2.7 STARTTLS 后旧 `LineChannel` 失效：`readLine` 抛 `channel replaced by STARTTLS`
- [x] 2.8 `transport/DotStuff.cj`：`DotStuffWriter` / `DotUnstuffReader` 逐字节状态机，跨块正确，`finish()` 语义（空正文只写 `.\r\n`）
- [x] 2.9 `transport/MailTrace.cj`：`onLine`/`onBytes`，`AUTH`/`PASS`/`LOGIN` 参数脱敏，正文默认不进 `onLine`
- [x] 2.10 `transport/TransportFactory.cj`：`SocketTransportFactory` + 测试用 `ScriptedTransport`（预置服务器字节、记录客户端字节）
- [x] 2.11 超时：`Deadline` 折算剩余时长，`MailIoException(stage=Timeout)` 后关闭连接
- [x] 2.12 `idle` 类超时与跨线程 `close()`：IDLE 期间长时间静默 MUST NOT 因 `command` 超时断开；`close()` 可从其它线程打断阻塞读，被打断的读以 `MailIoException` 结束且不向调用方线程抛异常
- [x] 2.13 单测：1 字节慢速流下 `readLine`/`readExact`/dot-stuffing 全部正确；跨块 dot-stuffing；超长行；提前 EOF；重复 `close()`；跨线程 `close()` 打断阻塞读

验收：能连本机 `TcpServerSocket` 假服务器完成一次行往返；1 字节读写测试全过。

## 3. M1-a 消息模型

- [x] 3.1 `HeaderMap.cj`：保序 + 大小写不敏感查找、`set`/`add`/`remove`/`entries`/`names`、折行展开、998 octets 上限、字段名与值校验；值按字节保留、允许裸 UTF-8（RFC 6532），只拒绝 `\r`/`\n`
- [x] 3.2 `MailAddress.cj`：`EmailAddress` 与 `AddressList` 的解析（addr-spec / name-addr / 引号名 / 注释 / 组 / 域字面量 / 引号本地部分）与生成（RFC 2047、拒绝废弃路由、拒绝 `\r\n<>`）
- [x] 3.3 `MailDate.cj`：RFC 5322 解析（两位年份、月份大小写、时区缩写、缺失时区告警）与生成
- [x] 3.4 `BodySource.cj`：`BodySource` 接口 + `MemoryBodySource` / `FileBodySource` / `StreamBodySource`（一次性来源二次 `open` 抛异常）
- [x] 3.5 `Spool.cj`：临时目录四级解析、随机文件名、0600、`close()` 删除、全部失败抛 `MimeException`
- [x] 3.6 `MimePart.cj`：`MimePart` / `PartBody` / `Multipart`，`text()`/`source()`/`children()`/`isMultipart()`/`isAttachment()`
- [x] 3.7 `MailMessage.cj`：`MailMessage` 与 `MailMessageBuilder`（`text`+`html` 自动 `alternative`，有附件外层 `mixed`）、`text()`/`html()`/`attachments()` 选取语义
- [x] 3.8 `Envelope.cj`：`fromMessage` 的 `Resent-*` 优先与缺失校验
- [x] 3.9 单测：地址往返、组语法、注入拒绝、日期两位年份与缺失时区、`text`/`html` 选取、临时文件权限

验收：RFC 5322 语料解析正确；地址 parse → toString → parse 幂等；注入用例全部被拒。

## 4. M1-b MIME 编解码

- [x] 4.1 `mime/MimeParameter.cj`：RFC 2231 单段 `name*=`、续行 `name*0*`、优先级、percent-decode、生成侧策略
- [x] 4.2 `mime/ContentType.cj`：引号参数、转义、注释跳过、默认值、大小写归一、`charset()`/`boundary()`
- [x] 4.3 `mime/ContentDisposition.cj`：`filename` 的 RFC 2231 / RFC 2047 兼容解码
- [x] 4.4 `mime/TransferEncoding.cj` + `QuotedPrintable.cj`：流式状态机，跨块残留、行尾空格、软换行不落在 `=XX` 中间、非法序列宽容/严格两态
- [x] 4.5 `mime/Base64Codec.cj`：76 列 + CRLF 编码、忽略空白解码、缺 padding 容错、非法字符两态
- [x] 4.6 `mime/EncodedWord.cj`：B/Q 解码、相邻 word 空白丢弃、混排保留空白、编码侧不切断多字节字符且每个 word ≤ 75 字符
- [x] 4.7 `mime/CharsetResolver.cj`：别名表 + 四级回退链，`charsetUsed`/`charsetLossy`
- [x] 4.8 单测：QP/base64/RFC 2047/RFC 2231 往返幂等（G1 要求 100%）、跨块边界、异常样本

验收：编解码往返 100% 一致；`gb2312` 实为 GBK 的样本能正确解码。

## 5. M1-c multipart 解析

- [x] 5.1 `mime/Boundary.cj`：`BoundaryScanner` 滚动窗口，只认行首 `CRLF + "--" + boundary`，支持空 preamble 与 `--boundary--`
- [x] 5.2 `mime/MimeParser.cj`：`MimeParseOptions`、头/正文分离、叶子正文按 `inlineTextLimit` 与 `spoolThreshold` 分流
- [x] 5.3 嵌套解析：`multipart/*` 递归、`message/rfc822` 为 `Embedded`、`multipart/digest` 子 part 默认为 `message/rfc822`
- [x] 5.4 缺失结束 boundary 的宽松/严格两态；preamble/epilogue 保留
- [x] 5.5 限制：`maxHeaderBytes`、`maxHeaderLine`、`maxParts`、`maxDepth`、`maxBodyBytes`，超限抛 `MailLimitException`
- [x] 5.6 `MimeParser.walk` + `MimeVisitor` + `MimeAction`：`SkipPart` 仍回调 `onPartEnd`，`Stop` 终止
- [x] 5.7 单测：真实语料（Gmail alternative+related、Outlook winmail.dat、转发、中文 GBK、缺失 boundary）、10 层嵌套、1 字节流下 parse 与 walk 结果一致、大附件落盘

验收：嵌套样本解析正确；2 MB 附件落临时文件且权限 0600；深度/数量炸弹被拒。

## 6. M1-d MimeWriter

- [x] 6.1 `mime/MimeWriter.cj` 骨架 + `MimeWriteOptions`（含 `utf8Headers`）+ `bytesWritten()`
- [x] 6.2 传输编码选择（7bit / QP / base64 / 8bit 规则）与 `forceEncoding` 硬约束
- [x] 6.3 头部折行：78 octets、不在引号内与 encoded-word 内断行、续行单空格开头
- [x] 6.4 boundary 生成（`=_fountain_{32hex}`）与 `ContentType.toString()` 的引号规则
- [x] 6.5 换行归一（CRLF / 裸 LF / 裸 CR → CRLF）
- [x] 6.6 `Bcc` 原样写出（删除由 `SmtpClient` 负责）
- [x] 6.7 单测：生成的报文可被 `MimeParser` 读回且内容一致；`forceEncoding` 冲突抛 `MimeException`；折行后每行 ≤ 78 octets
- [x] 6.8 头部编码两态：`utf8Headers=false`（默认）非 ASCII 头走 RFC 2047；`true` 时直写裸 UTF-8 且不混 encoded-word；单测断言两种输出都能被 `MimeParser` 读回成同一文本

验收：中文主题 + HTML + 二进制附件的邮件 write → parse 往返一致。

## 7. M1-e SMTP 客户端

- [x] 7.1 `smtp/SmtpReply.cj`：多行 `250-` 解析、`code` 取最后一行、`enhanced` 提取
- [x] 7.2 `smtp/SmtpCapabilities.cj`：`SIZE`/`8BITMIME`/`SMTPUTF8`/`PIPELINING`/`STARTTLS`/`AUTH`/`ENHANCEDSTATUSCODES`/`DSN`
- [x] 7.3 `smtp/SmtpClient.cj` builder：`tls`/`tlsConfig`/`auth`/`oauth2`/`helloName`/`timeouts`/`requireEncryption`/`allowPlaintextAuth`/`sendPolicy`/`maxMessageBytes`/`precomputeSize`/`dsn`
- [x] 7.4 builder 校验：默认加密要求、明文认证拒绝、`helloName` 缺省
- [x] 7.5 `build()` 建连流程：greeting → EHLO（失败回退 HELO）→ STARTTLS → 重新 EHLO → AUTH
- [x] 7.6 `smtp/SmtpAuth.cj`：PLAIN / LOGIN / CRAM-MD5 / XOAUTH2 编码与挑战处理；XOAUTH2 失败发空行再读最终码；不自动降级
- [x] 7.7 投递事务：MAIL FROM（`SIZE=`/`BODY=8BITMIME`/`SMTPUTF8`/`RET=`）、逐收件人 RCPT（`NOTIFY=`/`ORCPT=`）、DATA
- [x] 7.8 `SendPolicy`：BestEffort 与 AllOrNothing 的进入 DATA 判定与 `aborted` 语义
- [x] 7.9 PIPELINING：BestEffort 批量写出按序消费；无有效收件人但收到 354 时写 `.\r\n` 再 RSET；AllOrNothing 不 pipeline DATA
- [x] 7.10 `smtp/SendReport.cj`：`accepted`/`rejected`/`reply`/`aborted`/`isCompleteSuccess`/`isRetryable`
- [x] 7.11 自动补齐 `Date`/`Message-ID`/`MIME-Version`；`From` 缺失报错；发送时剥离 `Bcc` 且不改原 message
- [x] 7.12 SIZE：默认不发；`precomputeSize` 或 `maxMessageBytes>0` 时先计数，超限在 MAIL FROM 前失败
- [x] 7.13 8BITMIME / SMTPUTF8 分支与错误
- [x] 7.14 `isRetryable(error)` 分类表
- [x] 7.15 脚本测试：EHLO 多行、STARTTLS 后重新 EHLO、未广告 STARTTLS、四种 AUTH 逐字节、部分/全部 RCPT 被拒、PIPELINING 顺序、dot-stuffing、SIZE 超限、无 8BITMIME、非 ASCII 地址、Bcc 剥离、421 中途断开

验收：M1 全绿；用真实服务器发出一封含附件的中文邮件（G6 手工）。

## 8. M2 POP3 客户端

- [x] 8.1 `pop3/Pop3Reply.cj` + `Pop3Capabilities`（TOP / UIDL / PIPELINING / AUTH / STLS）
- [x] 8.2 `Pop3Client` builder：`tls`/`tlsConfig`/`timeouts`/`requireEncryption`/`allowPlaintextAuth`
- [x] 8.3 `build()`：greeting → CAPA（`-ERR` 时置空能力表不失败）→ STLS → 重新 CAPA；不登录
- [x] 8.4 认证：`login`（USER/PASS）、`apop`（MD5(timestamp+password)，无 timestamp 抛错）、`authenticate`（PLAIN/LOGIN）
- [x] 8.5 `stat` / `list`（单条与多行）/ `uidl`（单条与多行）解析为结构化结果
- [x] 8.6 `retr(message, sink)` 流式 + dot-unstuffing；`retrMessage` 直接接 `MimeParser`
- [x] 8.7 `top` / `topMessage`；无 `TOP` 能力时抛 `MailProtocolException`
- [x] 8.8 `dele` / `rset` / `noop` / `quit` / `close`：删除只在 `QUIT` 成功后提交
- [x] 8.9 `-ERR` 的 response code 解析与错误分类（`[AUTH]`/`[SYS/TEMP]`/`[SYS/PERM]`/`[IN-USE]`）
- [x] 8.10 脚本测试：APOP 摘要、LIST/UIDL 单条与多条、RETR 含 `..` 与 `.` 行、超长正文行、TOP 0、DELE+QUIT、DELE+close、`-ERR [AUTH]`

验收：大邮件 `RETR` 到 sink 时 RSS 增量不随大小线性增长；解析结果与样本逐字节一致。

## 9. M3 IMAP 客户端

- [x] 9.1 `imap/ImapUtf7.cj`：modified UTF-7 编解码，`&-`、`&` 结尾、非法序列的两态处理
- [x] 9.2 `imap/ImapParser.cj`：atom/quoted/number/NIL/列表/literal token 化，深度 64 与 8 KB 行上限
- [x] 9.3 `imap/ImapValue.cj` + `ImapResponse.cj`：tagged / untagged / continuation / `BYE` 分类
- [x] 9.4 `ImapClient` 命令框架：tag 生成（`A0001`… 进位到 `B0001` 不回绕）、参数编码（quoted / 转义 / literal）、邮箱名走 modified UTF-7
- [x] 9.5 `build()`：greeting → CAPABILITY → STARTTLS → 重新 CAPABILITY → `ID`（配置时）；不登录
- [x] 9.6 认证：`login`、`authenticate`（PLAIN/LOGIN/CRAM-MD5/XOAUTH2），`SASL-IR` 时带初始响应，`*` 取消
- [x] 9.7 `select` / `examine` / `closeMailbox` / `unselect` 与 `MailboxStatus`、`selected` 属性
- [x] 9.8 `list` / `lsub` / `status` 与 `MailboxInfo`（UTF-7 解码、delimiter、attributes）
- [x] 9.9 `FetchItem` / `SequenceSet` / `FetchResult` / `FetchMeta` / `BodySection` / `CopyResult` / `AppendResult`
- [x] 9.10 `fetch` / `uidFetch`（返回数组与 `FetchSink` 两个重载）；literal 路由到内存 / `Spool` / sink
- [x] 9.11 `BODYSTRUCTURE` 解析为 `BodyStructure` / `LeafBody` / `MultiBody`；`ENVELOPE` 解析为 `ImapEnvelope`（subject 走 RFC 2047，date 保留原文）
- [x] 9.12 `INTERNALDATE` 独立解析器（`dd-Mon-yyyy HH:mm:ss +zzzz`）
- [x] 9.13 部分获取 `BODY.PEEK[]<origin.length>` 与响应键 `<0>` 的保留
- [x] 9.14 `fetchMessage` / `uidFetchMessage` 用 `BODY.PEEK[]`，不置 `\Seen`
- [x] 9.15 `SearchCriteria`（含 and/or/not 组合）与 `search` / `uidSearch`；非 ASCII 需 `CHARSET UTF-8`，否则抛错
- [x] 9.16 `store`（Replace/Add/Remove，默认不加 `.SILENT`）、`copy`（`COPYUID` 解析）、`expunge`、`uidExpunge`
- [x] 9.17 `append`：先序列化到 `BodySource` 得精确大小，`LITERAL+` 用 `{n+}`，解析 `APPENDUID`
- [x] 9.18 `logout`（发 `LOGOUT`、读 `* BYE` 与 tagged `OK`）与 `close`（直接关 socket）
- [x] 9.19 脚本测试：tagged/untagged 交错、literal `{n}` 同步与 `{n+}`、大 literal 内存恒定、`BODY[HEADER.FIELDS (FROM TO)]` 键、BODYSTRUCTURE 嵌套、SEARCH 编码、STORE/EXPUNGE、APPEND、BYE、1 字节读、中文邮箱名往返

验收：M3 全绿；对 Dovecot 与 163 各跑一次真实会话（读 INBOX、搜索、取整封、标已读、追加到已发送）。

## 10. M4 IMAP 扩展

前提：M3 全绿。M4 的每个扩展都遵守同一条规则——**能力位可见 ≠ 已生效**，
`CAPABILITY` 决定"能做什么"，`ENABLE` 的 `* ENABLED` 回显决定"已经生效什么"。

- [x] 10.1 `imap/ImapCapabilities.cj`：解析 `IDLE`/`MOVE`/`SPECIAL-USE`/`NAMESPACE`/`UTF8=ACCEPT`/`ENABLE`/`CONDSTORE`/`QRESYNC`/`SORT`/`SORT=DISPLAY`/`THREAD=ORDEREDSUBJECT`/`THREAD=REFERENCES`，暴露 `supportsXxx`，未识别能力保留在原始表里
- [x] 10.2 `imap/ImapEnable.cj`：`ENABLE <cap>…` 命令与 `* ENABLED` 解析；只把回显的能力置为已启用；未认证状态调用 MUST 在本地拒绝、不发命令
- [x] 10.3 扩展调用前置校验：每类扩展在"未广告或未启用"时 MUST 抛 `MailProtocolException(capability=…)`，且异常文本不含凭据；统一走一处 `requireCapability` 而非各命令自己判断
- [x] 10.4 `imap/ImapIdle.cj` 的 `IdleSession`：`idle()` 前置校验（已认证 + 已 SELECT/EXAMINE）、发送 `IDLE`、处理 `+ idling`、`DONE` 不带 tag 单独写出、收 tagged `OK` 收尾
- [x] 10.5 IDLE 读线程：读行 → 分类 `ImapEvent` → 入有界队列；`nextEvent(timeout)` 阻塞消费，超时返回 `None` 且 MUST NOT 关连接；用户回调 MUST NOT 在读线程上执行
- [x] 10.6 IDLE 25 分钟重建：可注入时钟驱动，到点写 `DONE`、等 tagged `OK`、重新 `IDLE`；`close()` 在 IDLE 中先发 `DONE` 再停读线程，幂等
- [x] 10.7 IDLE 期间的命令互斥：同一连接上 IDLE 未结束时调用普通命令 MUST 立即抛 `MailProtocolException`，MUST NOT 排队；`* BYE` 先作为 `Bye` 事件投递再结束会话
- [x] 10.8 `imap/ImapMove.cj`：`move`/`uidMove`；解析 `[COPYUID]`、`* VANISHED` 与 `* EXPUNGE`；返回 `MoveResult(atomic, copyUid, vanished)`；服务器广告 `MOVE` 时 MUST 用 `MOVE`
- [x] 10.9 MOVE 非原子回退：`allowNonAtomicMove(true)` 时 `UID COPY` → `UID STORE +FLAGS.SILENT (\Deleted)` → `UID EXPUNGE`（无 `UIDPLUS` 时退回 `EXPUNGE` 并记告警），结果 `atomic=false`；未开启回退时 MUST 抛错且不发 `COPY`
- [x] 10.10 `imap/ImapSpecialUse.cj`：`\All`/`\Archive`/`\Drafts`/`\Flagged`/`\Junk`/`\Sent`/`\Trash` 映射到 `SpecialUse`；未知 `\Foo` 保留在 attributes 不报错；`listSpecialUse()` 发 `LIST (SPECIAL-USE) "" "*"`，无能力时 MUST 抛错而不是全量 LIST 后猜名字
- [x] 10.11 `imap/ImapNamespace.cj`：`NAMESPACE` 三段（personal / otherUsers / shared）的 `(prefix delimiter)` 列表与 `NIL` 解析为 `NamespaceInfo`；`joinPath()` 按 delimiter 拼接且不产生重复分隔符
- [x] 10.12 `imap/ImapCondStore.cj`：`SELECT … (CONDSTORE)`、`[HIGHESTMODSEQ n]`、`FETCH (MODSEQ)` 与 `(CHANGEDSINCE n)`、`STORE (UNCHANGEDSINCE n)` 与 `* OK [MODIFIED <set>]` → `StoreResult.modified`（失败项 MUST NOT 记为成功）
- [x] 10.13 QRESYNC：`ENABLE QRESYNC` 时 MUST NOT 再单独 `ENABLE CONDSTORE`；`SELECT … (QRESYNC (uidvalidity modseq [known-uids [(known-seqs known-uids)]]))`；区分 `* VANISHED (EARLIER)` 与普通 `* VANISHED`，两者都要在普通命令的响应分发里被消费
- [x] 10.14 `imap/ImapSort.cj`：`SORT`/`UID SORT` 的 `SortCriteria`（`ARRIVAL`/`CC`/`DATE`/`FROM`/`SIZE`/`SUBJECT`/`TO` + `REVERSE` 前缀）、`SORT=DISPLAY` 时的 `DISPLAY FROM`/`DISPLAY TO`、字符集只允许 `US-ASCII`/`UTF-8`；解析 `* SORT`
- [x] 10.15 `THREAD ORDEREDSUBJECT` / `THREAD REFERENCES`（含 `UID THREAD`）：解析 `* THREAD (…)` 嵌套为 `ThreadNode` 树，同级顺序与响应一致；只广告一种算法时请求另一种 MUST 抛错
- [x] 10.16 `UTF8=ACCEPT` 分支：启用后邮箱名直传 UTF-8、`SEARCH` 省略 `CHARSET`、`LIST`/`STATUS` 返回名按 UTF-8 解码、`APPEND` 接受 UTF-8 头部（序列化用 `utf8Headers=true`）；`SORT`/`THREAD` 的 `charset` 参数不变；未启用时上述各处 MUST 完整走 M3 的 modified UTF-7 路径，禁止"能发就发 UTF-8"的尝试式降级
- [x] 10.17 脚本测试：IDLE 的 `+`/推送/`DONE`/tagged 时序、25 分钟重建（假时钟）、IDLE 中插入 `* BYE`、`DONE` 之后才到的 untagged、IDLE 期间 untagged 与 `DONE` 进 `onLine`、跨线程 `close()` 打断阻塞读、MOVE 的 `COPYUID` 与 `VANISHED`、MOVE 回退三步顺序、`LIST (SPECIAL-USE)` 含自定义属性、`NAMESPACE` 三段全 `NIL`、`ENABLE` 回空列表、`MODIFIED` 只列半数序号、`VANISHED (EARLIER)` 与普通 `VANISHED` 混排、`SORT`/`THREAD` 结果含重复序号与 1000 兄弟节点、1 字节读
- [x] 10.18 互操作（G6 手工）：QQ 邮箱实测通过（IMAP 993 / SMTP 465、发信→收信→取整封→标已读、NAMESPACE、IDLE）；Dovecot 与仅 M3 服务器的扩展错误矩阵留后续

验收：M4 全绿；IDLE 在 25 分钟边界上自行重建且不丢事件；七组扩展在"不支持"时全部给出可断言的具体错误，不出现静默退化。

## 11. 收尾

- [x] 11.1 `email.cj` 汇总 re-export，确认五个公开包名与设计一致
- [x] 11.2 更新 `f_email/README.md`：已实现范围（含 M4 七组扩展）、里程碑进度、`CANGJIE_STDX_DYNAMIC_PATH` 要求、编码/解码与 IDLE 使用示例
- [x] 11.3 更新 `f_email/README_en.md` 与之一致
- [x] 11.4 跑 `cjpm build` 与 `cjpm test`，确保无 warning 级新增告警
- [x] 11.5 按 G1–G6 逐条自查并在变更里记录结果（含 10 MB 附件的 RSS 增量实测值）
- [x] 11.6 把 `f_email/doc/f_email设计文档.md` 中与实际实现有出入的 API 签名回写到文档
