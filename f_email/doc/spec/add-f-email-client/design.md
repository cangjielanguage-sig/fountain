# 设计：add-f-email-client

## 1. 决策摘要

| 决策点 | 结论 | 理由 |
|---|---|---|
| 传输底座 | `std.net.TcpSocket` + `stdx.net.tls.TlsSocket` | `f_net` 是长度前缀帧 + 心跳 + 连接池，塞行协议等于在帧里再解析一遍，且无法表达"服务器随时推送 untagged 响应" |
| 协议抽象 | 一个 `MailConnection` + 一个 `LineChannel` | 三种协议的差异在命令层，不在字节层；把 socket/TLS 收敛到一处，协议层才能被 `ScriptedTransport` 完整替换 |
| 行语义 | 字节行（`Array<Byte>`），不是 `String` 行 | POP3 `RETR` 正文是任意 8 位字节，IMAP literal 长度是字节数；先 `String` 化就是先猜编码 |
| 注入防线 | 只在 `LineChannel.writeLine` + `EmailAddress` 构造器 | 分散在各协议里做 `replace("\r","")` 必然漏；一处拒绝，全链路覆盖 |
| MIME 实现 | 自研，不复用 `f_http` | `f_http` 的参数解析是 RFC 6266（HTTP），邮件要 RFC 2231 + RFC 2047 + RFC 2045；相似但规则不同，复用会把 HTTP 的兼容补丁带进来 |
| 解析模型 | 双模式：`parse` 建树 / `walk` 分块回调 | 普通邮件需要树；超大邮件只关心部分附件时，建树会浪费内存与时间 |
| 正文落点 | `PartBody.Text` 只放 ≤ `inlineTextLimit` 的小文本，其余进 `BodySource` | 100 MB 的 `text/plain` 放进 `String` 就失去流式意义 |
| 临时文件 | `Spool` 随机文件名 + 0600 + `close()` 删除 | 附件 `filename` 是不可信输入，绝不能参与路径 |
| 字符集 | 别名表 + 四级回退链，永不因字符集失败而丢邮件 | 声明 `gb2312` 实际 GBK、声明 `utf-8` 实际 GBK 在中文邮件里是常态 |
| SMTP 重试 | 客户端不自动重试，只给 `isRetryable` 分类 | `250` 可能已在断网前到达服务器，库内重试 = 重复投递；去重键属于业务 |
| SMTP 建连时机 | `build()` 内完成连接 + EHLO + STARTTLS + AUTH | 配置错误在启动期暴露，而不是在业务请求里；`send()` 只做事务 |
| Bcc | `SmtpClient` 剥离，`MimeWriter` 保留 | writer 是通用序列化器（保存草稿要用），发送路径才需要剥离 |
| 并发 | 每连接一线程，客户端不声明线程安全 | 邮件协议状态机是串行的；共享连接加锁只会把状态错位变成随机失败 |

## 2. 分层与依赖方向

```
应用
 │
 ▼
smtp/  pop3/  imap/        ← 协议层：状态机、命令编码、响应解析、能力协商
 │        │       │
 └────────┴───┬───┘
              ▼
        mime/              ← 编解码：parser / writer / 编码器
              │
              ▼
         消息模型           ← MailMessage / MimePart / HeaderMap / 地址 / 日期
              │
              ▼
        transport/          ← MailConnection / LineChannel / DotStuff / TLS
              │
              ▼
   std.net / stdx.net.tls / charset4cj
```

三条纪律，实现时按这个顺序做 code review 检查：

1. **协议层不解析 MIME**。POP3 `RETR`、IMAP `FETCH BODY[]` 只交出字节流；
   要不要交给 `MimeParser` 是调用方的选择（`retrMessage`/`fetchMessage` 只是便利方法）。
2. **消息层不碰 socket**。`MimeWriter` 只写 `OutputStream`，`MimeParser` 只读 `InputStream`，
   因此可以单测、可以落文件、可以走内存管道。
3. **传输层不理解邮件语义**。它只知道"一行""一段字节""literal 长度"。

`f_email` 是叶子模块：不依赖 `f_net`/`f_http`/`f_mvc`，也不被它们依赖。

## 3. 包与文件布局

```
f_email/src/
├── email.cj                     # public 汇总与版本常量（已存在，扩充 re-export）
├── MailException.cj
├── Secret.cj
├── MailAddress.cj               # EmailAddress / AddressList
├── MailDate.cj
├── HeaderMap.cj
├── MailMessage.cj               # MailMessage + MailMessageBuilder
├── MimePart.cj                  # MimePart / PartBody / Multipart
├── BodySource.cj                # BodySource / Memory / File / Stream
├── Spool.cj                     # 临时文件解析顺序、0600、删除
├── mime/
│   ├── ContentType.cj
│   ├── ContentDisposition.cj
│   ├── TransferEncoding.cj
│   ├── QuotedPrintable.cj       # 编解码器（流式）
│   ├── Base64Codec.cj           # 包一层 stdx.encoding.base64，处理流式分块
│   ├── EncodedWord.cj
│   ├── MimeParameter.cj         # RFC 2231
│   ├── Boundary.cj              # BoundaryScanner（滚动窗口）
│   ├── MimeParser.cj
│   ├── MimeWriter.cj
│   └── CharsetResolver.cj
├── transport/
│   ├── MailConnection.cj
│   ├── LineChannel.cj
│   ├── DotStuff.cj
│   ├── TlsMode.cj
│   ├── TransportFactory.cj      # 含 SocketTransportFactory / ScriptedTransport
│   └── MailTrace.cj
├── smtp/
│   ├── SmtpClient.cj
│   ├── SmtpReply.cj
│   ├── SmtpCapabilities.cj
│   ├── SmtpAuth.cj
│   └── SendReport.cj
├── pop3/
│   ├── Pop3Client.cj
│   ├── Pop3Reply.cj
│   └── Pop3Capabilities.cj
└── imap/
    ├── ImapClient.cj
    ├── ImapResponse.cj
    ├── ImapParser.cj            # token / ImapValue
    ├── ImapFetch.cj             # FetchItem / FetchResult / BodyStructure
    ├── ImapSearch.cj            # SearchCriteria / SequenceSet
    ├── ImapAppend.cj
    └── ImapUtf7.cj
```

公开包名：`fountain::f_email`、`fountain::f_email.mime`、`fountain::f_email.smtp`、
`fountain::f_email.pop3`、`fountain::f_email.imap`。单元测试与被测文件同目录，命名 `<文件>_test.cj`，
沿用仓库既有 `f_base`/`f_io` 的做法。

## 4. 传输层

### 4.1 唯一知道 socket 的类

`MailConnection` 持有 `TcpSocket` 或 `TlsSocket`，对外只给 `LineChannel`。
`startTls()` 替换底层流并**重建** `LineChannel`；旧引用必须失效——旧 `LineChannel.readLine()`
抛 `MailProtocolException("channel replaced by STARTTLS")`，否则会静默读到已废弃的明文流。

### 4.2 STARTTLS 的"不预读"

`STARTTLS` 回复行之后紧跟的就是 TLS `ClientHello`。若读取该行时用了带缓冲的流，
握手字节会被吞进缓冲区，TLS 握手读到明文残渣而失败。
实现：`LineChannel` 带 `buffered` 开关，`TlsMode.StartTls` 的连接在升级前用**单字节**读，
读完 `220` 后重建 `buffered=true` 的通道。EHLO 阶段多几百次 `read` 相对一次握手的成本可忽略。

### 4.3 超时

`TcpSocket.readTimeout`/`writeTimeout` 是**单次系统调用**超时，不是命令总超时。
命令总超时由 `Deadline` 在每次读写前折算成剩余时间设置；
超时统一映射 `MailIoException(stage=Timeout)` 并关闭连接（超时后流不可信）。

### 4.4 行读取的一个易错点

`readLine()` 返回的字节要**去掉 CRLF**，但遇到裸 `\n` 也要接受并记告警。
`readExact(n)` 必须包含当前行缓冲的残留——IMAP literal 紧跟在 `{n}` 所在行的 CRLF 之后，
行读取器已经预读的字节不能丢。

### 4.5 测试替身

`ScriptedTransport` 预置"服务器要说的字节"并记录"客户端说了什么"，
断言粒度到字节。每类协议测试都必须覆盖：正常流程、多行回复、错误码、超长行/截断/提前 EOF、
以及**每次 `read` 只返回 1 字节**的慢速流。后者是暴露"依赖一次读满一行"这类 bug 的唯一手段。

## 5. 消息层

`HeaderMap` 用 `ArrayList<(String, String)>` 保序 + 一个大小写不敏感的索引，
不用 `HashMap`——`Received` 链的顺序是语义的一部分。

`MailMessage.headers` 与 `root.headers` 是同一个对象；`contentType()`/`disposition()`
是解析时建立的缓存视图。**解析完成后不允许改 headers**，要改就用 builder 重建，
否则缓存与原文会不一致。这条要写进 API 注释。

`Secret` 只暴露 `use((String) -> T)`。实现上不保留明文字段，`use` 接受引用后立即丢弃；
`toString()` 返回 `<redacted>`。异常构造时对 `command` 做白名单脱敏。

## 6. MIME

### 6.1 boundary 扫描

不能用"按行读"扫 boundary——附件正文可能有超长行，也可能是二进制。
用 `BoundaryScanner` 维护 `boundary.len + 4` 的滚动窗口，只在 `CRLF + "--" + boundary`
处匹配，并额外接受"正文偏移 0 就是 `--boundary`"（空 preamble）。
复杂度 O(n)，不回溯、不用正则。

### 6.2 嵌套与递归

每个 part 按自己的 `Content-Type` 递归；`message/rfc822` 的正文是一个完整 `MailMessage`；
`multipart/digest` 的子 part 默认按 `message/rfc822`。深度与 part 数量在**进入递归前**检查，
不能等栈溢出。

### 6.3 编解码器都是状态机

QP 与 base64 都必须支持跨块边界：QP 在块尾留下 1–2 字节残留（可能是 `=` 或 `=4`），
base64 留下未满 4 字符的尾组。写成"整块解码"在 8 KB 缓冲下必然出错，且 1 字节读测试会立刻暴露。

### 6.4 生成侧的顺序

`MimeWriter.write(message)`：

1. 决定每个 part 的传输编码（`forceEncoding` 优先，否则按 7bit/QP/base64 规则）；
2. 写头部（自动折行、encoded-word 编码、RFC 2231 参数）；
3. 写正文（边写边计数，`bytesWritten()` 供 SMTP 的 `SIZE` 使用）。

换行归一发生在写正文之前：`\r\n`、裸 `\n`、裸 `\r` 统一成 CRLF。
base64/QP 的输出本来按 CRLF 生成，不重复归一。

### 6.5 boundary 生成

`=_fountain_{32 位十六进制}`，含 `=` 因此在 `Content-Type` 里必须加引号。
**不做全文碰撞扫描**——流式写出无法预读全文；32 位随机 + 固定前缀的碰撞概率可以忽略。
这个取舍要写成注释，避免后来者以为是漏了检查。

### 6.6 字符集

`CharsetResolver` 是唯一调用 `charset4cj` 的地方。别名表覆盖
`gb2312/gbk/cp936`、`big5/cp950`、`iso-8859-1/latin1→windows-1252`、
`shift_jis/sjis/cp932`、`euc-kr/ks_c_5601-1987`、`iso-2022-jp`。
回退链的最后一档 `WINDOWS_1252` 逐字节映射永不失败，保证"任何字节都能出文本"，
同时把 `charsetLossy` 置 true 让调用方有据可查。

## 7. 三个协议客户端

### 7.1 SMTP

状态推进由 `send()` 单线程驱动，关键在于三个分支：

- **BestEffort + PIPELINING**：一次 flush 写出 MAIL/RCPT…/DATA，再按序读回复。
  若所有 RCPT 被拒但服务器仍回 `354`，此时已在 DATA 状态，只能写 `.\r\n` 结束空事务再 `RSET`。
  这是防御性分支，RFC 2920 要求服务器回 `554`/`503`，但现实中不总是。
- **AllOrNothing**：不 pipeline DATA。先等 MAIL/RCPT 全部回复，若任一 RCPT 被拒就直接 `RSET`，
  根本不进入 DATA 状态。如果连 DATA 一起 pipeline，服务器可能已经回了 `354`，此时再发现拒收
  就只能投一封空邮件给已接受的收件人——所以这一段流水线必须关掉。
- **EHLO 回退 HELO**：能力表清空。若配置要求 TLS 或认证，直接失败而不是退化。

### 7.2 POP3

`RETR` 用 `DotUnstuffReader` 逐字节状态机读，直接接 `sink` 或 `MimeParser`。
删除只在 `QUIT` 的 `+OK` 之后生效；`close()` 与异常断开都不进入 UPDATE。

### 7.3 IMAP

分层：`ImapParser` 只产出 `ImapToken`/`ImapValue`（literal 只记长度），
`ImapClient` 负责消费 literal 并路由到内存 / 临时文件 / `FetchSink`。
把"解析"和"IO 决策"分开，才能在测试里只测解析、在生产里保证流式。

`EXPUNGE` 的序号移动是调用方最容易踩的坑：文档与返回结果都要提示，`UIDPLUS` 可用时优先
`UID EXPUNGE`。

## 8. 错误映射

| 场景 | 异常 | 可重试 |
|---|---|---|
| DNS/连接失败 | `MailIoException(stage=Connect)` | ✅ |
| TLS 握手/证书 | `MailTlsException` | ✅ |
| 读超时 | `MailIoException(stage=Timeout)` | ✅ |
| 回复格式错误 | `MailProtocolException` | ❌ |
| SMTP `535` / POP3 `-ERR [AUTH]` / IMAP `NO [AUTHENTICATIONFAILED]` | `MailAuthException` | ❌ |
| 单个收件人 `550` | 不抛，进 `SendReport.rejected` | — |
| 全部收件人失败 | 不抛，返回 `SendReport` | 视码分类 |
| 头部/正文/literal 超限 | `MailLimitException(kind=…)` | ❌ |
| MIME 结构损坏（严格模式） | `MimeException` | ❌ |
| 已关闭连接上操作 | `MailProtocolException("client is closed")` | ❌ |

`send()` 的分界：拿到整封邮件的最终回复就返回 `SendReport`（含部分失败）；
只有连接/协议/认证层面的失败才抛异常。这样调用方一个 `try` 管网络问题、一个 `report` 管业务拒收。

## 9. 测试策略

| 层 | 手段 | 覆盖 |
|---|---|---|
| 单元 | 纯函数 | base64/QP/RFC 2047/RFC 2231/地址/日期/头折行/boundary 扫描 |
| 协议 | `ScriptedTransport` | 逐字节断言命令、多行回复、literal、dot-stuffing、错误码、1 字节读 |
| 集成 | 本机 `TcpServerSocket` 假服务器 | 真实 socket、超时、断连、TLS 握手 |
| TLS | 自签证书 + `TlsSocket.server`（工具链支持时） | 证书校验成功/失败、STARTTLS、主机名不匹配 |
| 互操作 | 手工（Postfix / Dovecot / 163） | 真实服务商差异 |

必须入库的语料：Gmail 的 `alternative + related`、Outlook 的 `winmail.dat`、中文
`charset=gb2312` 实为 GBK、跨多个 encoded-word 的主题、`filename*0*` 续行、
旧客户端在参数里用 RFC 2047、`message/rfc822` 转发、缺失结束 boundary、base64 含空白缺 padding、
QP 软换行与行尾空格、10 层嵌套、单行 10 KB 头部。

恶意样本单列一组测试：头注入、地址注入、100 层嵌套、10 万 part、100 MB literal、
base64 炸弹、递归 `message/rfc822`、POP3 正文含 `.\r\n`、SMTP 正文含裸 LF。

## 10. 里程碑与验收

| 里程碑 | 范围 | 出口 |
|---|---|---|
| M0 | transport + 异常 + Secret + ScriptedTransport | 连本机假服务器；1 字节读写通过；OHOS TLS 有结论 |
| M1 | 消息模型 + MIME + SMTP | 能发纯文本/HTML/附件；语料全过；注入测试全过 |
| M2 | POP3 | 登录、列表、UIDL、流式 RETR、TOP、DELE/QUIT；大邮件内存恒定 |
| M3 | IMAP 核心（含 `ID`、`UIDPLUS`、`UNSELECT`） | 读 INBOX、条件搜索、取整封、标记已读、追加已发送 |

验收门槛沿用设计文档 G1–G6：单元全过、三协议脚本全过、1 字节压力全过、
10 MB 附件 RSS 增量 < 10 MB、注入与炸弹样本全被拒、至少两个真实服务器互操作通过。

## 11. P-0：动工前的三个硬验证

这三条不通会推翻上层设计，必须在写第一个业务类之前跑完：

1. `stdx.net.tls` 在目标机（尤其 OHOS）能连 465 端口并校验证书；
2. `charset4cj` 对 GBK/GB18030 解码正确（用真实中文邮件样本）；
3. `stdx.encoding.base64` 的容错行为（缺 padding、含空白）符合预期，否则要在
   `Base64Codec` 里自行兜底。

不通过时的退路：调用方注入 `TlsClientConfig` + 自签 CA；**不默认 `TrustAll`**。

## 12. 本设计明确不做

S/MIME/PGP 验签解密、HTML 渲染与清洗、代理与连接池、OAuth2 token 刷新、
IDN/punycode、IMAP IDLE/MOVE/SPECIAL-USE/UTF8=ACCEPT（M4 另立变更）。
这些不是"以后再说"，而是**接口上已经留好位置**：`TransportFactory` 可换代理实现，
`MimeAction` 可扩展，`ImapCapabilities.supportsXxx` 已能读到能力位。
