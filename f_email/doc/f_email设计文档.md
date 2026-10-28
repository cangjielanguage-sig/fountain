# f_email —— 仓颉邮件协议模块设计（SMTP / POP3 / IMAP + MIME）

> 版本 **v0.1** ｜ 2026-10-28 ｜ 状态：待评审
>
> 定位：fountain 的**邮件客户端模块**。三套协议客户端（SMTP / POP3 / IMAP4rev1）+ 一套完整的
> MIME 消息模型、流式解析与生成。
>
> 三条底线：
> 1. **发送严格、接收宽容**——写出的报文必须合法；读入尽量读懂，读不懂要有明确的降级与告警。
> 2. **字节优先、流式优先**——不在未知字符集上先解码；附件不进内存。
> 3. **默认安全**——证书校验、凭据脱敏、CRLF 注入防线默认开启，放宽必须显式。
>
> **范围**：客户端优先。SMTP 接收服务端、IMAP/POP3 服务端不在本期（边界见 1.3），
> 未来若要做，复用本文的 MIME 与协议编解码，不推翻现有 API。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 模块定位 | 邮件**客户端**：发信、收信、MIME 解析/生成 |
| 协议版本 | SMTP（RFC 5321 + 4954/2920/3461/6152/6531）、POP3（RFC 1939 + 2449/2595/5034）、IMAP4rev1（RFC 3501 + 2177/4315/4551/6851） |
| 传输 | `std.net.TcpSocket` + `stdx.net.tls.TlsSocket`；**不复用 `f_net`**（理由见 1.2） |
| 行协议 | 统一 `LineChannel`：CRLF、行上限、dot-stuffing、literal 透传；字节而非 `String` |
| 消息模型 | `MailMessage` / `MimePart` / `HeaderMap` / `EmailAddress` / `ContentType` |
| MIME | 自研解析器 + 生成器；multipart 递归、RFC 2047、RFC 2231、base64、quoted-printable |
| 流式 | 叶子正文超过阈值落临时文件；IMAP literal / POP3 RETR 直接进解析器，不整体驻留 |
| 字符集 | `charset4cj`；自带常见邮件字符集别名表与回退链 |
| 认证 | SMTP：PLAIN / LOGIN / CRAM-MD5 / XOAUTH2；POP3：USER-PASS / APOP / AUTH；IMAP：LOGIN / AUTHENTICATE |
| TLS | 隐式 TLS 与 STARTTLS；默认校验证书；STARTTLS 失败**不降级** |
| 失败语义 | SMTP 逐收件人状态；4xx 可重试、5xx 永久；**客户端不自动重试**（避免重复投递） |
| 安全 | CRLF 注入防线、凭据脱敏、日志清洗、临时文件 0600、默认拒绝明文 AUTH |
| 依赖 | `f_base`、`f_io`、`f_log`、`f_random`、`charset4cj`、`stdx`（tls/base64/digest/x509） |
| 不做 | 服务端、MTA 队列、S/MIME/PGP、DKIM/SPF/DMARC、HTML 渲染、代理 |
| 里程碑 | **M0** 传输骨架 → **M1** MIME + SMTP → **M2** POP3 → **M3** IMAP 核心 → **M4** IMAP 扩展与加固 |

### 0.1 三行用法

```cangjie
// 发信
let client = SmtpClient.builder("smtp.example.com", port: 587)
    .tls(TlsMode.StartTls)
    .auth(SmtpAuthMechanism.Plain, "bot@example.com", Secret.of(token))
    .build()
let report = client.send(MailMessage.builder()
    .from("bot@example.com")
    .to("ops@example.com")
    .subject("构建失败")
    .text("第 42 号流水线失败，详见附件")
    .attach("build.log", FileBodySource(Path("build.log")))
    .build())
client.close()
```

```cangjie
// 收信（IMAP）
let imap = ImapClient.builder("imap.example.com", port: 993).tls(TlsMode.Implicit).build()
imap.login("bot@example.com", Secret.of(password))
let box = imap.select("INBOX")
let hits = imap.search(SearchCriteria.unseen().and(SearchCriteria.from("alerts@example.com")))
for (seq in hits) {
    let message = imap.fetchMessage(seq)          // 小邮件直接建模
    println(message.subject())
}
imap.logout()
```

```cangjie
// 收信（POP3，逐封流式解析，附件不驻留）
let pop = Pop3Client.builder("pop.example.com", port: 995).tls(TlsMode.Implicit).build()
pop.login("bot@example.com", Secret.of(password))
for (info <- pop.uidl()) {
    let message = pop.retrMessage(info.message)
    process(message)
    pop.dele(info.message)                        // 只有 quit() 才真正删除
}
pop.quit()
```

---

## 1. 定位与边界

### 1.1 在模块链里的位置

```
                 应用 / f_mvc / 业务代码
                          │
                          ▼
   ┌──────────────────────────────────────────────┐
   │                  f_email                     │
   │  smtp/  pop3/  imap/  mime/  transport/      │
   └───────┬──────────────┬──────────────┬────────┘
           │              │              │
           ▼              ▼              ▼
   std.net.TcpSocket  stdx.net.tls   charset4cj
           │              │              │
           └──────────────┴──────────────┘
                          │
                f_base / f_io / f_log / f_random
```

**f_email 不依赖 `f_net`、`f_http`、`f_mvc`**，也不被它们反向依赖。它是叶子模块，只向上提供服务。

### 1.2 为什么不复用 f_net / f_http

| 候选 | 为什么不用 |
|---|---|
| `f_net` | 它是 **`Message` 长度前缀帧**传输层，带心跳、连接池、RPC 请求表。SMTP 是 CRLF 行协议、POP3 是多行响应、IMAP 是带 literal 的标签协议；套进帧层等于在帧里再解析一遍，且无法表达「服务器随时推送 untagged 响应」 |
| `f_protocol` | 同 `f_net`，是 RPC 消息模型，不是邮件报文 |
| `f_httpclient` | 只承载 HTTP；SMTP/POP3/IMAP 不是 HTTP 的变体 |
| `f_http.ContentDisposition` | 它是 **RFC 6266（HTTP）** 的参数解析，邮件需要 **RFC 2231 + RFC 2047 + RFC 2045 参数**；两者相似但规则不同，复用会把 HTTP 的兼容补丁带进邮件 |
| `f_io.ByteBuffer` | 可用，但不是必须。传输层只需要 `InputStream` / `OutputStream`，不绑定具体缓冲区 |

结论：**传输层直接用 `std.net` + `stdx.net.tls`**，把差异收敛在 `MailConnection` 一个类里。

### 1.3 明确不做

| 不做 | 说明 |
|---|---|
| SMTP 接收服务端 | 需要 MTA 队列、退信、反垃圾、SPF/DKIM 校验，是另一个量级的产品 |
| IMAP / POP3 服务端 | 需要存储引擎、并发会话、配额、索引；不在客户端模块里 |
| MTA 队列与持久化重试 | 客户端只报告「这一次投递的结果」，重试由调用方决定（见 6.6） |
| S/MIME、PGP | `multipart/signed`、`application/pkcs7-mime` 按普通 MIME 解析，**不验签、不解密** |
| DKIM / SPF / DMARC | 属于发送域与接收端策略，不是客户端职责 |
| HTML 渲染与清洗 | 只提供原始 HTML 文本；渲染与 XSS 清洗由调用方负责 |
| 通讯录 / 日历 | vCard / iCalendar 作为 MIME 附件原样处理 |
| 代理 | M1 不做；`TransportFactory` 预留（见 3.8） |
| OAuth2 取 token / 刷新 | 只接受调用方给的 access token；刷新逻辑属于应用 |

### 1.4 依赖与版本

```toml
[dependencies]
  "fountain::f_base" = {path = "../f_base"}
  "fountain::f_io" = {path = "../f_io"}
  "fountain::f_log" = {path = "../f_log"}
  "fountain::f_random" = {path = "../f_random"}
  "cangjie_tpc::charset4cj" = "1.0.5"
```

| 依赖 | 用途 | 备注 |
|---|---|---|
| `f_base` | `StringGenerator`、`BaseException`、`Peekable` | 文本累积用 `StringGenerator`，不用 `String +` |
| `f_io` | `ByteBuffer`、文件流辅助 | 只在内部使用，不暴露到公开 API |
| `f_log` | 协议跟踪、告警 | 默认不记录正文与凭据 |
| `f_random` | Message-ID、boundary、临时文件名 | 不要求密码学强度 |
| `charset4cj` | 字符集解码/编码 | `Charsets.forName` 的标签有限，需别名表（5.7） |
| `stdx.net.tls` | TLS 客户端 | `TlsSocket.client(...)` + `handshake()` |
| `stdx.encoding.base64` | base64 编解码 | `toBase64String` / `fromBase64String` |
| `stdx.crypto.digest` | CRAM-MD5、APOP | `MD5`、`HMAC` |
| `stdx.crypto.common` / `x509` | 证书类型与校验模式 | `TlsClientConfig.verifyMode` |

工具链：`cjc-version = "1.2.0"`，stdx 1.3.0。OHOS 目标上 `stdx.net.tls` 是否可用需在 M0 实跑确认（见 13 章 P-0）。

### 1.5 包结构

```
f_email/
├── cjpm.toml
└── src/
    ├── email.cj                     # public import 汇总
    ├── MailException.cj             # 异常层次
    ├── Secret.cj                    # 凭据包装与脱敏
    ├── MailAddress.cj               # EmailAddress / AddressList / 解析器
    ├── MailDate.cj                  # RFC 5322 日期
    ├── HeaderMap.cj                 # 头字段容器
    ├── MailMessage.cj               # 消息模型 + builder
    ├── MimePart.cj                  # MIME 树
    ├── BodySource.cj                # 可重复/一次性正文来源
    ├── Spool.cj                     # 临时文件暂存
    ├── mime/
    │   ├── ContentType.cj
    │   ├── ContentDisposition.cj
    │   ├── TransferEncoding.cj      # base64 / QP / 7bit / 8bit / binary
    │   ├── EncodedWord.cj           # RFC 2047
    │   ├── MimeParameter.cj         # RFC 2231
    │   ├── MimeParser.cj
    │   ├── MimeWriter.cj
    │   └── Boundary.cj
    ├── transport/
    │   ├── MailConnection.cj
    │   ├── LineChannel.cj
    │   ├── DotStuff.cj
    │   ├── TlsMode.cj
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
    │   └── Pop3Multiline.cj
    └── imap/
        ├── ImapClient.cj
        ├── ImapResponse.cj
        ├── ImapParser.cj
        ├── ImapValue.cj
        ├── ImapFetch.cj
        ├── ImapSearch.cj
        ├── ImapIdle.cj
        └── ImapUtf7.cj
```

公开包名：

| 包 | 内容 |
|---|---|
| `fountain::f_email` | 消息模型、地址、日期、头、MIME 类型、异常 |
| `fountain::f_email.mime` | 解析器、生成器、编码器 |
| `fountain::f_email.smtp` | SMTP 客户端 |
| `fountain::f_email.pop3` | POP3 客户端 |
| `fountain::f_email.imap` | IMAP 客户端 |

---

## 2. 总体架构

### 2.1 分层

```
┌─────────────────────────────────────────────────────┐
│ 应用 API  SmtpClient / Pop3Client / ImapClient       │
├─────────────────────────────────────────────────────┤
│ 协议层    状态机、命令编码、响应解析、能力协商        │
├─────────────────────────────────────────────────────┤
│ 消息层    MailMessage / MimePart / MIME 编解码        │
├─────────────────────────────────────────────────────┤
│ 传输层    MailConnection / LineChannel / TLS / 超时   │
├─────────────────────────────────────────────────────┤
│ 系统层    std.net / stdx.net.tls / charset4cj         │
└─────────────────────────────────────────────────────┘
```

**分层纪律**：

- 协议层**不解析 MIME**。POP3 `RETR`、IMAP `FETCH BODY[]` 只交出字节流；要不要交给 `MimeParser` 是调用方的选择。
- 消息层**不碰 socket**。`MimeWriter` 只写 `OutputStream`，`MimeParser` 只读 `InputStream`，因此可以单测、可以落文件、可以走内存管道。
- 传输层**不理解邮件语义**。它只知道「一行」「一段字节」「literal 长度」。

### 2.2 两条数据流

**发信**：

```
MailMessage
   │
   ▼
MimeWriter（流式，边写边计数）
   │  原始 RFC 5322 字节
   ▼
DotStuffWriter（行首 '.' 加倍）
   │
   ▼
SMTP DATA ──▶ server
```

**收信**：

```
POP3 RETR / IMAP FETCH BODY[]
   │  原始 RFC 5322 字节（已去掉 dot-stuffing / literal 边界）
   ▼
MimeParser（流式）
   │
   ├── 小文本 → String
   ├── 大正文 → BodySource（内存或临时文件）
   └── multipart → 递归 MimePart
```

### 2.3 线程模型

| 场景 | 线程 |
|---|---|
| SMTP 发信 | 调用方线程；一个 `SmtpClient` 同时只跑一个事务 |
| POP3 | 调用方线程；协议本身不允许并发 |
| IMAP 普通命令 | 调用方线程；同一连接串行 |
| IMAP IDLE | 内部一个读线程，事件进队列；`IdleSession.nextEvent()` 消费 |

**约定**：

- 所有客户端**不是线程安全的**。一个连接由一个线程驱动；`close()` 幂等，允许从其他线程调用来中止阻塞读。
- 不使用 `async/await`；需要并发时由调用方用 `spawn` + 每线程一个客户端。
- **不做自动重连**。连接断了就是断了，重连由调用方决定（IMAP 重连会丢 `SELECT` 状态，自动重连只会掩盖问题）。

### 2.4 三条全局约定

**① 字节优先，不在未知字符集上解码**

POP3/IMAP 取回的是字节；`Content-Type` 里的 `charset` 可能缺失、写错、是别名。**先把字节存下来，等确定字符集再解码**。反过来（先按 UTF-8 解码、失败再重编码）会把 `GBK` 邮件变成永久乱码。

**② 流式优先，附件不进内存**

一封信 20 MB 附件很常见。解析器的默认行为是把叶子正文写进 `BodySource`：小于 `spoolThreshold` 放内存，超过落临时文件。IMAP `FETCH BODY[]` 的 literal 直接边读边写，不在 `String` 里过一遍。

**③ 凭据与正文默认不进日志**

`Secret` 的 `toString()` 永远输出 `<redacted>`；AUTH 命令行、POP3 `PASS`、IMAP `LOGIN` 在 trace 里按规则打码；正文只在显式 `traceBody=true` 时记录。

```cangjie
public class Secret {
    public static func of(value: String): Secret
    /// 唯一取值入口；回调结束后不保留引用
    public func use<T>(f: (String) -> T): T
    public func toString(): String        // "<redacted>"
}
```

---

## 3. 传输层

### 3.1 连接与抽象

```cangjie
package fountain::f_email.transport

public enum TlsMode {
    | None          // 明文
    | StartTls      // 先明文，命令升级
    | Implicit      // 连上即 TLS（SMTPS 465 / POP3S 995 / IMAPS 993）
}

public struct MailTimeouts {
    public let connect!: Duration = Duration.second * 15
    public let greeting!: Duration = Duration.second * 30
    public let command!: Duration = Duration.second * 60
    public let data!: Duration = Duration.second * 300
    public let idle!: Duration = Duration.second * 60
}

public class MailConnection <: Resource {
    public static func open(host: String, port: UInt16,
                            tls!: TlsMode = TlsMode.None,
                            timeouts!: MailTimeouts = MailTimeouts(),
                            tlsConfig!: ?TlsClientConfig = None): MailConnection

    /// STARTTLS：在已建立的明文连接上升级；升级后内部 LineChannel 被替换
    public func startTls(config!: ?TlsClientConfig = None): Unit

    public func channel(): LineChannel
    public prop remoteAddress: String
    public prop isTls: Bool
    public func close(): Unit
    public func isClosed(): Bool
}
```

`MailConnection` 是**唯一**知道 `TcpSocket` / `TlsSocket` 的地方。协议客户端只拿 `LineChannel`，因此可以在测试里换成内存管道。

**`channel()` 在 STARTTLS 之后必须重新取**：`startTls()` 会替换底层流并重建 `LineChannel`；调用方（SMTP/POP3 状态机）升级完成后必须用新的 `connection.channel()`，不能继续持有旧引用。旧 `LineChannel` 的 `readLine()` 会抛 `MailProtocolException("channel replaced by STARTTLS")`，避免静默读到已废弃的明文流。

**TLS 配置默认值**：

| 项 | 默认 | 说明 |
|---|---|---|
| `serverName` | 连接用的 host | SNI 与证书主机名校验；IP 字面量时设为 IP |
| `verifyMode` | `CertificateVerifyMode.Default` | 系统 CA；**不是 `TrustAll`** |
| `supportedVersions` | 空（由 stdx 决定） | 最低 TLS 1.2 由 stdx 默认保证；如需强制再显式设置 |
| `clientCertificate` | `None` | 双向 TLS 时由调用方提供 |
| 握手超时 | `timeouts.connect` | `TlsSocket.handshake(timeout: ...)` |

> **OHOS / 嵌入式注意**：`stdx.net.tls` 依赖 OpenSSL 与系统 CA 路径。M0 必须在目标机上跑一次「连 465 端口 + 校验证书」的用例；不通就退回「让调用方注入 `TlsClientConfig` + 自签 CA」，不要默认 `TrustAll`。

### 3.2 STARTTLS 的四条规则

1. **服务器不广告 `STARTTLS` 就失败**，不静默继续明文——这是 STARTTLS 剥离攻击的入口。
2. **升级后必须重新 `EHLO` / `CAPA`**：服务器的能力表在 TLS 前后可能不同（很多服务器只在 TLS 后广告 `AUTH`）。
3. **升级前不发送任何凭据**。`AUTH` 必须在 TLS 之后；唯一例外是调用方显式 `allowPlaintextAuth(true)`。
4. **升级前绝不预读**。`STARTTLS` 的回复行之后紧跟的就是 TLS `ClientHello`；如果行读取器用了 `BufferedInputStream` 预读，会把握手字节吞进缓冲区，导致 TLS 握手读到明文残渣而失败。
   实现方式：`LineChannel` 有 `buffered` 开关，`TlsMode.StartTls` 的连接在升级前按**单字节**从 socket 读，直到收到 `220` 回复；升级成功后重新创建 `buffered=true` 的 `LineChannel`。POP3 的 `STLS` 同理。
   代价是 EHLO/CAPA 阶段多几百次 `read` 系统调用，相对于一次 TLS 握手可以忽略。

### 3.3 LineChannel：字节行，不是 String 行

```cangjie
public class LineChannel <: InputStream & Resource {
    public init(input: InputStream, output: OutputStream,
                maxLine!: Int64 = 4096,
                buffered!: Bool = true,
                trace!: ?MailTrace = None)

    /// 读一行，返回不含 CRLF 的字节；EOF 返回 None
    public func readLine(): ?Array<Byte>
    /// 读恰好 count 字节（IMAP literal 用）
    public func readExact(count: Int64): Array<Byte>
    /// 把剩余字节当普通输入流读（DotUnstuffReader 用），包含当前行缓冲里的残留
    public func read(buffer: Array<Byte>): Int64
    /// 写一行，自动补 CRLF；内容含 CR/LF 直接抛异常
    public func writeLine(line: String): Unit
    public func writeLine(line: Array<Byte>): Unit
    public func write(bytes: Array<Byte>): Unit
    public func flush(): Unit
    public func close(): Unit
}
```

**为什么返回 `Array<Byte>` 而不是 `String`**：

- POP3 的 `RETR` 正文可以是任意 8 位字节，`String` 化会按某种编码猜，猜错就损坏；
- IMAP 的 literal 长度是字节数，不是字符数；
- 协议命令与回复确实是 ASCII，但解析层在拿到字节后再做 ASCII 解码，边界清晰。

**行读取规则**：

| 输入 | 行为 |
|---|---|
| `...\r\n` | 正常，去掉 CRLF |
| `...\n`（裸 LF） | **接受**，记一次 `protocolWarning`；写出一律 CRLF |
| 超过 `maxLine` | 抛 `MailLimitException(kind=Line)`；SMTP/POP3 传 4 KB（规范 512，给现实留余量），IMAP 传 8 KB；构造函数默认 4 KB |
| EOF 中途 | 返回 `None` 或抛 `MailIoException`（由调用点决定语义） |

`writeLine` 在写之前做**统一注入防线**：任何 `\r` / `\n` 出现在参数里都抛 `MailProtocolException`。这条防线覆盖 SMTP 命令、IMAP 标签/命令、POP3 用户名等所有拼接点。

### 3.4 dot-stuffing

只在两处使用：SMTP `DATA` 与 POP3 多行响应。

```cangjie
/// 写：行首 '.' 加倍，所有行以 CRLF 结束
public class DotStuffWriter <: OutputStream {
    public init(output: OutputStream)
    /// 写完最后一行后调用：补 CRLF + ".\r\n"（空正文时直接 ".\r\n"）
    public func finish(): Unit
}

/// 读：去掉行首多余的一个 '.'，遇到单独一行 "." 结束
public class DotUnstuffReader <: InputStream {
    public init(input: InputStream)
}
```

实现要点：

- **跨缓冲区边界**也要正确：维护 `atLineStart` 标志，不假设一次 `write` 覆盖整行。
- 空正文：写完 `DATA` 的 354 后直接写 `.\r\n`，不额外制造空行。
- 正文最后一行没有 CRLF 时由 `finish()` 补齐。
- **读取侧不按行缓冲**：`DotUnstuffReader` 是逐字节状态机（只记 `atLineStart` 与「本行已读字符数」），因此正文行可以任意长；行上限只作用于协议控制行（`LineChannel.readLine`）。

### 3.5 literal（IMAP 专用）

IMAP 的 `{n}` 不是普通行内容：它是「接下来 n 个字节是数据」的声明。

```cangjie
public struct ImapLiteral {
    public let size: Int64
    public let nonSynchronizing: Bool   // {n+}，LITERAL+ 扩展
}
```

- **发送**：`{n}` 后必须等服务器 `+` 继续；`{n+}` 可直接写。是否使用 `{n+}` 取决于 `CAPABILITY` 里的 `LITERAL+`。
- **接收**：`readLine()` 返回以 `{n}` 结尾的行后，调用 `readExact(n)`；**大 literal 不经过 `String`**，直接写 `BodySource` 或调用方的 `OutputStream`。
- **上限**：`ImapClientBuilder.maxLiteralBytes` 默认 64 MB；超过直接抛 `MailLimitException` 并断开连接（流已经错位，不能继续读）。

### 3.6 超时

| 超时 | 覆盖 | 默认 |
|---|---|---|
| `connect` | TCP 连接 + TLS 握手 | 15 s |
| `greeting` | 连上后等待服务器欢迎行 | 30 s |
| `command` | 单条命令从发出到 tagged/最终回复 | 60 s |
| `data` | `DATA` 正文、`RETR`、`FETCH BODY[]` 的单次读 | 300 s |
| `idle` | IDLE 两次保活之间 | 60 s（实际重发间隔 25 min，见 8.8） |

实现方式：`TcpSocket.readTimeout` / `writeTimeout` 是**单次系统调用**超时，不是命令总超时。命令总超时由 `Deadline` 在每次读写前折算成剩余时间设置；超时统一映射成 `MailIoException(stage=Timeout)`，并**关闭连接**（超时后流不可信）。

### 3.7 连接生命周期

```
open → greeting → [STARTTLS] → AUTH → 事务... → QUIT → close
                                         │
                                         └─ 异常 → close（不尝试复用）
```

- `close()` 幂等；已关闭时再调不抛。
- 任何协议错误、超时、EOF 都**关闭连接**，不尝试「跳过一行继续」——邮件协议的状态机一旦错位，继续读只会把错误放大。
- `SmtpClient` 可以在同一个连接上连续发多封；`Pop3Client` / `ImapClient` 不支持跨连接复用状态。

### 3.8 自定义传输（为测试与代理预留）

```cangjie
public interface TransportFactory {
    func connect(host: String, port: UInt16, tls: TlsMode): MailConnection
}
```

M1 只提供 `SocketTransportFactory`。测试用 `ScriptedTransport` 注入字节脚本；未来 SOCKS/HTTP CONNECT 代理实现同一接口，不改协议层。

**协议跟踪**（默认关闭）：

```cangjie
public interface MailTrace {
    /// direction: 'C' / 'S'；line 已去掉 CRLF，且已按 9 章规则脱敏
    func onLine(direction: Rune, line: String): Unit
    func onBytes(direction: Rune, count: Int64): Unit
}
```

`MailTrace` 只拿得到脱敏后的行：`AUTH ...`、`PASS ...`、`LOGIN ...` 的参数一律替换为 `<redacted>`；正文默认不回调 `onLine`，只在 `onBytes` 里报字节数。

---

## 4. 消息模型（RFC 5322）

### 4.1 HeaderMap

```cangjie
public class HeaderMap {
    public init()
    public func get(name: String): ?String
    public func getAll(name: String): Array<String>
    public func set(name: String, value: String): Unit       // 覆盖第一个，删除其余
    public func add(name: String, value: String): Unit
    public func remove(name: String): Array<String>
    public func contains(name: String): Bool
    public func entries(): Array<(String, String)>           // 保留原始顺序
    public func names(): Array<String>
}
```

| 规则 | 说明 |
|---|---|
| 大小写 | 查找不区分大小写；**保留原始大小写与顺序**（`Received` 链的顺序有意义） |
| 重复字段 | 允许（`Received`、`Comments`、`X-*`）；`set` 会清掉同名其余项 |
| 折行 | 解析时展开 `CRLF + WSP` 为单个空格；生成时按 78 octets 重新折行 |
| 注入 | `set` / `add` 的值里含 `\r` 或 `\n` 直接抛 `MailProtocolException` |
| 长度 | 单行硬上限 998 octets（RFC 5322 §2.1.1）；超长抛 `MailLimitException` |
| 字段名 | 只允许 `!`–`~` 中除 `:` 的可见 ASCII；不合法抛异常 |

结构化取值不放进 `HeaderMap`，由 `MailMessage` 的便捷方法完成：

```cangjie
public class MailMessage {
    public prop headers: HeaderMap
    public func from(): ?EmailAddress
    public func to(): AddressList
    public func cc(): AddressList
    public func bcc(): AddressList
    public func subject(): ?String
    public func date(): ?MailDate
    public func messageId(): ?String
    public func contentType(): ContentType
}
```

### 4.2 地址

```cangjie
public class EmailAddress {
    public init(address: String, name!: ?String = None)
    public static func parse(text: String): EmailAddress
    public prop address: String        // 不含显示名与尖括号
    public prop name: ?String          // 已解码的显示名
    public func toString(): String     // 需要时做 RFC 2047 编码
}

public class AddressList <: Iterable<EmailAddress> {
    public init(addresses!: Array<EmailAddress> = [])
    public static func parse(text: String): AddressList   // 支持逗号分隔与 group 语法
    public func add(address: EmailAddress): Unit
    public func add(text: String): Unit
    public func iterator(): Iterator<EmailAddress>
    public func toString(): String
}
```

解析范围（RFC 5322 §3.4）：

| 语法 | 支持 | 例 |
|---|---|---|
| `addr-spec` | ✅ | `user@example.com` |
| `name-addr` | ✅ | `张三 <user@example.com>` |
| 引号显示名 | ✅ | `"Doe, John" <j@example.com>` |
| 注释 | ✅ | `user@example.com (work)` |
| 组 | ✅ | `Team: a@x, b@y;` |
| 域字面量 | ✅ | `user@[192.0.2.1]` |
| 引号本地部分 | ✅ | `"john doe"@example.com` |
| 废弃路由 | 解析接受，**生成拒绝** | `<@a,@b:user@host>` |
| UTF-8 地址 | 解析接受；发送要求 `SMTPUTF8` | `用户@例子.中国` |

**生成规则**：

- 显示名是纯 ASCII 且不含特殊字符 → 原样；否则 RFC 2047 编码（5.3）。
- 地址本身含非 ASCII → 只在 `SMTPUTF8` 可用时发送，否则抛 `MailProtocolException`；不做隐式 punycode（本地部分无法安全转换）。
- 任何 `\r` / `\n` / `>` / `<` 出现在 `address` 里 → 抛异常。这是 SMTP 命令注入的主入口。

### 4.3 日期

```cangjie
public class MailDate {
    public init(dateTime: DateTime, offsetMinutes!: Int32 = 0)
    public static func now(): MailDate
    public static func parse(text: String): MailDate
    public prop dateTime: DateTime
    public prop offsetMinutes: Int32
    public func toString(): String       // "Wed, 28 Oct 2026 21:58:52 +0800"
    public func toUtc(): DateTime
}
```

| 解析项 | 规则 |
|---|---|
| 星期 | 可省略（obsolete）；存在时不校验是否与日期一致 |
| 月份 | 英文三字母，大小写不敏感 |
| 两位年份 | `00`–`49` → 2000–2049；`50`–`99` → 1950–1999（RFC 5322 §4.3） |
| 时区 | `+0800` / `-0500`；`UT` / `GMT`；常见美区缩写 `EST` / `EDT` / `CST` / `CDT` / `MST` / `MDT` / `PST` / `PDT` |
| 缺失时区 | 视为 `+0000`，记 warning；不按本地时区猜 |
| 非法日期 | 抛 `MimeException`（严格）或回退到 `1970-01-01` + warning（宽松，默认） |

生成时使用 `MailDate.now()` 的本地偏移；`Date` 头缺失时由 `SmtpClient.send` 自动补。

### 4.4 正文与 MIME 树

```cangjie
public class MimePart {
    public prop headers: HeaderMap
    public prop contentType: ContentType
    public prop disposition: ?ContentDisposition
    public prop body: PartBody

    public func text(): ?String                  // text/* 时返回解码后的文本；Data 会按需物化
    public func source(): ?BodySource            // 叶子正文
    public func children(): Array<MimePart>      // Parts 时返回子 part，否则空数组
    public func isMultipart(): Bool
    public func isAttachment(): Bool
}

public enum PartBody {
    | Text(String)                    // 小文本，已按 charset 解码
    | Data(BodySource)                // 大文本或二进制，CTE 已解码
    | Parts(Multipart)                // multipart/*
    | Embedded(MailMessage)           // message/rfc822
    | Empty
}
```

`MailMessage` 是根 `MimePart` 的薄包装：

```cangjie
public class MailMessage {
    public prop headers: HeaderMap
    public prop root: MimePart
    public static func builder(): MailMessageBuilder
    public static func parse(input: InputStream,
                             options!: MimeParseOptions = MimeParseOptions()): MailMessage
    public func text(): ?String
    public func html(): ?String
    public func attachments(): Array<MimePart>
}
```

三个便捷方法的语义（都不做渲染、不做 HTML 转文本）：

| 方法 | 行为 |
|---|---|
| `text()` | 单 part `text/plain` 直接返回；`multipart/alternative` 取第一个 `text/plain`；`multipart/mixed` 在非附件 part 里递归找；找不到返回 `None` |
| `html()` | 同上，但找 `text/html`；找不到返回 `None`，**不会**拿 `text()` 顶替 |
| `attachments()` | `Content-Disposition: attachment` 的 part，或带 `filename` 参数的非文本 part；`inline` 图片不算附件，但可通过 `children()` 遍历 |

`MailMessage.headers` 与 `root.headers` 是**同一个对象**；`contentType` / `disposition` 是解析时从 headers 得到的缓存视图。解析完成后不要直接改 headers——要改就用 builder 重新构造，避免缓存与原文不一致。

对 `StreamBodySource`，`text()` / `source().open()` 只能成功一次；需要多次读取就先落盘成 `FileBodySource`。

**为什么 `Text` 只存小文本**：`PartBody.Text` 是 `String`，一旦把 100 MB 的 `text/plain` 放进去就失去流式意义。规则是：解码后 ≤ `inlineTextLimit`（默认 256 KB）且 `text/*` → `Text`；否则 → `Data(BodySource)`，由 `text()` 按需解码（可能物化，调用方自己承担）。

#### 4.4.1 BodySource 与构造器

```cangjie
public interface BodySource <: Resource {
    /// 每次 open() 返回一个新的读流；一次性来源第二次调用抛异常
    func open(): InputStream
    prop size: Int64          // -1 = 未知
    prop reusable: Bool
}

public class MemoryBodySource <: BodySource {
    public init(bytes: Array<Byte>)
}

public class FileBodySource <: BodySource {
    public init(path: Path)
}

public class StreamBodySource <: BodySource {
    public init(input: InputStream, size!: Int64 = -1)   // 一次性
}
```

`MailMessageBuilder`（示例里用的链式 API）：

```cangjie
public class MailMessageBuilder {
    public func from(address: String): This
    public func to(address: String): This
    public func cc(address: String): This
    public func bcc(address: String): This
    public func subject(text: String): This
    public func date(date: MailDate): This
    public func header(name: String, value: String): This
    public func text(content: String, charset!: Charset = Charsets.UTF8): This
    public func html(content: String, charset!: Charset = Charsets.UTF8): This
    public func attach(filename: String, source: BodySource,
                       mediaType!: String = "application/octet-stream"): This
    public func build(): MailMessage
}
```

`text` + `html` 同时存在时自动生成 `multipart/alternative`；有附件时外层再包 `multipart/mixed`。`attach` 的 `filename` 只用于 `Content-Disposition`，不用于临时文件路径。

**临时目录解析顺序**（OHOS 上没有 `/tmp`，必须写死）：

```
1. MimeParseOptions.spoolDir（显式指定）
2. 环境变量 TMPDIR
3. 系统临时目录（std.fs 提供）
4. 当前工作目录下的 .fountain_tmp/（兜底，自动创建）
```

四个都失败 → 抛 `MimeException("无法创建附件临时文件，请显式指定 spoolDir")`。临时文件名由内部随机生成（不使用附件名），创建时 0600，`BodySource.close()` 删除。

### 4.5 信封

```cangjie
public class Envelope {
    public init(from: String, recipients: Array<String>)
    public prop from: String              // 反路径，退信时可为空串（<>）
    public prop recipients: Array<String>
    public static func fromMessage(message: MailMessage): Envelope
}
```

`Envelope.fromMessage` 的规则：

1. 若存在任意 `Resent-*` 字段 → 用 `Resent-From` / `Resent-To` / `Resent-Cc` / `Resent-Bcc`
2. 否则用 `From` / `To` / `Cc` / `Bcc`
3. `From` 缺失 → 抛 `MailProtocolException`；`To` + `Cc` + `Bcc` 全空 → 抛异常
4. 地址只取 `addr-spec`，不取显示名

### 4.6 自动补齐的头

`SmtpClient.send` 在序列化前检查：

| 头 | 缺失时 |
|---|---|
| `Date` | 补 `MailDate.now()` |
| `Message-ID` | 补 `<{时间戳}.{随机}.{domain}>`，domain 取 `From` 的域，取不到用 `localhost` |
| `MIME-Version` | 补 `1.0`（有 MIME 结构时） |
| `From` | **不补，直接报错** |
| `To` | 允许空（Bcc-only 场景） |
| `Bcc` | **发送时从报文里删除**（见 6.5） |

---

## 5. MIME

### 5.1 Content-Type / Content-Disposition

```cangjie
public class ContentType {
    public init(mediaType: String, parameters!: HashMap<String, String> = HashMap())
    public static func parse(value: String): ContentType
    public prop type: String          // 小写
    public prop subtype: String       // 小写
    public prop parameters: HashMap<String, String>
    public func charset(): ?Charset
    public func boundary(): ?String
    public func toString(): String
}

public class ContentDisposition {
    public init(disposition: String, parameters!: HashMap<String, String> = HashMap())
    public static func parse(value: String): ContentDisposition
    public prop disposition: String   // "inline" / "attachment"
    public prop filename: ?String     // 已按 RFC 2231/2047 解码
    public func toString(): String
}
```

解析规则：

| 场景 | 行为 |
|---|---|
| 缺失 `Content-Type` | 默认 `text/plain; charset=us-ascii`（RFC 2045） |
| 缺失 `Content-Transfer-Encoding` | 默认 `7bit` |
| 类型/子类型大小写 | 统一小写后比较；参数名小写，参数值保留 |
| 引号参数 | 支持 `"..."`，`\"` 转义；分号在引号内不切分 |
| 注释 | 参数间的 `(...)` 注释跳过 |
| 未知类型 | 保留原样，按 `application/octet-stream` 处理正文 |
| 非法参数 | 宽松模式跳过该参数并 warning；严格模式抛 `MimeException` |

#### 5.1.1 RFC 2231 参数

邮件附件名常见三种写法，解析优先级从高到低：

```
filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf          // 单段扩展值
filename*0*=UTF-8''%E4%B8%AD; filename*1*=%E6%96%87.pdf   // 续行
filename="=?UTF-8?B?...?="                        // 旧客户端（RFC 2047，非标准）
```

| 规则 | 行为 |
|---|---|
| `name*=charset'lang'value` | `value` 按 percent-encoding 解字节，再按 `charset` 解码 |
| `name*0*` / `name*1*` … | 按数字顺序拼接**编码后的字符串**，再 percent-decode；缺号则停止并 warning |
| 同时有 `name` 和 `name*` | 优先 `name*`；`name` 作为回退 |
| charset 缺失/未知 | 按 5.7 回退链；`lossy=true` |
| 非法 percent 序列 | 宽松模式原样保留 + warning；严格模式抛 |
| 生成 | 非 ASCII 一律用 `name*=UTF-8''...`；纯 ASCII 用 `name="..."` |

**不要用 RFC 2047 生成参数**：它在参数位置不是标准做法，只有解析侧为兼容旧客户端才接受。

### 5.2 传输编码

```cangjie
public enum TransferEncoding {
    | SevenBit
    | EightBit
    | Binary
    | QuotedPrintable
    | Base64
}
```

| 编码 | 解码 | 编码 |
|---|---|---|
| `7bit` | 原样；出现 >0x7F 记 warning | 仅在纯 ASCII 且行 ≤ 998 时使用 |
| `8bit` | 原样 | 仅在服务器支持 `8BITMIME` 且正文是文本时使用 |
| `binary` | 原样 | 仅用于 `message/global` 等；M1 不主动生成 |
| `quoted-printable` | `=XX`、`=\r\n`（兼容裸 `=\n`）软换行；非法序列按字面保留（宽松）或抛（严格） | 见下 |
| `base64` | 忽略空白；缺 padding 容错 | 76 列 + CRLF |

**QP 编码规则**（RFC 2045 §6.7）：

- 可打印 ASCII（`33`–`60`、`62`–`126`）原样；`=` 必须编码为 `=3D`。
- 行尾的空格/制表符编码为 `=20` / `=09`，否则会在传输中被剥掉。
- 其他字节 `=XX`，十六进制**大写**。
- 每行 ≤ 76 字符，超出用 `=\r\n` 软换行；软换行不能落在 `=XX` 中间。
- 解码时 `=XX` 大小写都接受；`=` 后不是两位十六进制 → 宽松模式原样保留并 warning；`=\n`（裸 LF）按软换行处理。

**base64 规则**：

- 编码：每 76 字符插入 `\r\n`；末尾补 `=`。
- 解码：忽略 `\r`、`\n`、空格、制表符；遇到非字母表字符（除 padding）→ 宽松模式跳过，严格模式抛。
- 空正文 → 空输出，不产生单独空行。

### 5.3 RFC 2047 encoded-word

```cangjie
public class EncodedWord {
    public static func decode(text: String, options!: DecodeOptions = DecodeOptions()): String
    public static func encode(text: String, charset!: Charset = Charsets.UTF8,
                              maxWordLength!: Int64 = 75): String
}
```

**解码**：

| 规则 | 行为 |
|---|---|
| 语法 | `=?charset?B?encoded-text?=` 或 `=?charset?Q?encoded-text?=`，`?` 之间不允许空白 |
| B 编码 | base64，忽略空白 |
| Q 编码 | `_` → 空格；`=XX` → 字节；其余原样；编码时 `?`、`_`、`=` 必须写成 `=XX` |
| 相邻 encoded-word | 中间的空白**丢弃**再拼接（`=?utf-8?B?..?= =?utf-8?B?..?=` 是一个词被折断） |
| 普通文本与 encoded-word 混排 | 普通文本的空白保留 |
| charset 未知 | 回退链（5.7）；仍失败 → 原样保留整段并 warning |
| 非法 encoded-word | 宽松模式原样保留；严格模式抛 |

**编码**：

- 只在**确实需要**时编码：显示名/主题中出现非 ASCII，或出现控制字符。
- 优先 `Q`（可读性好）当非 ASCII 字节少于 1/3，否则 `B`。
- 每个 encoded-word ≤ 75 字符；多个词之间用 `CRLF + 空格` 折行。
- **不切断多字节字符**：按字符边界切，切完再编码。
- 不编码纯 ASCII 文本——`=?utf-8?Q?hello?=` 是合法的，但没必要，且会降低可读性。

### 5.4 multipart

```cangjie
public class Multipart {
    public let boundary: String
    public let parts: Array<MimePart>
    public let preamble: ?String      // 第一个 boundary 之前的内容，保留但不解释
    public let epilogue: ?String
}
```

解析状态机：

```
BODY
 ├─ 逐字节扫描 "\n--boundary"
 │    ├─ 后面是 "--" → CLOSE
 │    └─ 后面是 CRLF/空白 → 新 part
 ├─ 新 part：读头部（到空行）→ 读正文（到下一个 boundary）
 └─ CLOSE：剩余字节是 epilogue
```

**关键实现点**：

1. **不能用「按行读」扫 boundary**。附件正文可能有超长行，也可能是二进制；必须用字节级 `BoundaryScanner`，维护一个 `boundary.len + 4` 的滚动窗口，匹配只发生在行首（`\n--boundary`），并额外接受「正文偏移 0 就是 `--boundary`」的情况（空 preamble）。
2. **boundary 只在行首有效**。正文里出现 `--boundary` 子串不算，必须是 `CRLF + "--" + boundary`。
3. **结束 boundary** 是 `--boundary--`，后面可以有空白再 CRLF。
4. **preamble / epilogue** 保留但不解析；解析结果里可选暴露。
5. **嵌套**：每个 part 按自己的 `Content-Type` 递归；`message/rfc822` 的正文是一个完整的 `MailMessage`。
6. **缺失结束 boundary**：宽松模式把剩余字节作为最后一个 part，记 warning；严格模式抛 `MimeException`。
7. **`multipart/digest`**：子 part 默认 `message/rfc822`（RFC 2046）。
8. **`multipart/alternative`**：提供 `bestAlternative(preferred: Array<String>)`，按调用方偏好选 `text/plain` / `text/html`；不自动猜。
9. **`multipart/related`**：暴露 `start` 参数与 `Content-ID`，`cid:` 解析由调用方做（不自动读本地文件，防 SSRF/路径穿越）。

### 5.5 流式解析

```cangjie
public struct MimeParseOptions {
    public let maxHeaderBytes!: Int64 = 256 * 1024
    public let maxHeaderLine!: Int64 = 64 * 1024
    public let maxParts!: Int64 = 1000
    public let maxDepth!: Int64 = 32
    public let maxBodyBytes!: Int64 = 0              // 0 = 不限
    public let inlineTextLimit!: Int64 = 256 * 1024
    public let spoolThreshold!: Int64 = 1024 * 1024
    public let spoolDir!: ?Path = None
    public let strict!: Bool = false
    public let defaultCharset!: Charset = Charsets.UTF8
}

public class MimeParser {
    public static func parse(input: InputStream,
                             options!: MimeParseOptions = MimeParseOptions()): MailMessage
    public static func walk(input: InputStream, visitor: MimeVisitor,
                            options!: MimeParseOptions = MimeParseOptions()): Unit
}

public interface MimeVisitor {
    /// path 形如 "1.2"、"3"；根 part 为空串
    func onPartStart(path: String, headers: HeaderMap): MimeAction
    func onBodyData(path: String, data: Array<Byte>): MimeAction
    func onPartEnd(path: String): MimeAction
}

public enum MimeAction {
    | Continue
    | SkipPart
    | Stop
}
```

**两种模式的分工**：

| 模式 | 适用 | 行为 |
|---|---|---|
| `parse` | 普通邮件、几 MB 以内 | 建 `MailMessage` 树；叶子正文按阈值进内存或临时文件 |
| `walk` | 超大邮件、只关心附件/正文 | 不建树；正文分块回调，调用方自己决定写哪 |

`walk` 的 `onBodyData` 收到的字节**已经过 CTE 解码**，但**未做字符集解码**——字符集信息在 `headers` 里，由调用方决定。

`MimeAction.SkipPart` 跳过当前 part 的正文与子树，但仍然回调 `onPartEnd`（这样调用方的栈不会失衡）；`MimeAction.Stop` 终止整个解析并返回。

### 5.6 生成

```cangjie
public struct MimeWriteOptions {
    public let allow8Bit!: Bool = false           // 服务器支持 8BITMIME 时才能 true
    public let maxLineLength!: Int64 = 78          // 头部折行
    public let bodyLineLength!: Int64 = 76         // base64 / QP
    public let maxBytes!: Int64 = 0                // 0 = 不限；>0 时超限抛
    public let forceEncoding!: ?TransferEncoding = None
    public let boundaryPrefix!: String = "=_fountain_"
}

public class MimeWriter {
    public init(output: OutputStream, options!: MimeWriteOptions = MimeWriteOptions())
    public func write(message: MailMessage): Unit
    public func bytesWritten(): Int64
    public func flush(): Unit
}
```

**编码选择**（`forceEncoding = None` 时）：

```
正文是 7bit 安全（全部 ≤0x7F 且行 ≤998）→ 7bit
正文是文本且非 ASCII 字节 < 20%      → quoted-printable
其他                                 → base64
服务器支持 8BITMIME 且 allow8Bit     → 8bit（仅文本；二进制仍 base64）
```

`forceEncoding` 是硬约束：指定 `SevenBit` 但正文含 8 位字节或行超 998，直接抛 `MimeException`，不静默换编码。

**头部折行**：

- 在空白、逗号、分号处断行，续行以单个空格开头。
- **不在引号字符串内部、不在 encoded-word 内部断行**。
- `Content-Type` 的 `boundary` 参数可能很长，允许单独占一行。
- 折行后每行 ≤ 78 octets；硬上限 998，超了抛 `MailLimitException`。

**换行归一**：写入前把正文里的 `\r\n`、裸 `\n`、裸 `\r` 统一成 CRLF（7bit/8bit 文本）；base64/QP 的输出本来就按 CRLF 生成。不要依赖调用方传入的换行风格——SMTP 的 DATA 与头部都要求 CRLF。

**boundary 生成**：

- 格式 `=_fountain_{32 位十六进制}`，长度远小于 70。
- 参数值里含 `=`、`;`、`"`、空白等 tspecial 时，`ContentType.toString()` 必须加引号；生成的 boundary 含 `=`，所以默认写成 `boundary="=_fountain_..."`。
- **不做全文碰撞扫描**（流式无法预读）；32 位随机 + 前缀的碰撞概率可以忽略。文档明确写这条取舍，避免实现者以为漏了检查。

**Bcc 处理**：`MimeWriter` **原样写出** `Bcc`（它是通用序列化器）；是否删除由 `SmtpClient` 决定。这样「保存草稿」和「发送」可以复用同一个 writer。

### 5.7 字符集与回退链

```cangjie
public class CharsetResolver {
    public static func resolve(name: ?String, options!: CharsetOptions = CharsetOptions()): Charset
}

public struct CharsetOptions {
    public let fallback!: Array<Charset> = [Charsets.UTF8, Charsets.GB18030, Charsets.WINDOWS_1252]
    public let strict!: Bool = false
}
```

**别名表**（`charset4cj` 的标签覆盖不全，必须自己补）：

| 邮件里常见写法 | 映射 |
|---|---|
| `us-ascii` / `ascii` / `ansi_x3.4-1968` | `Charsets.UTF8`（ASCII 是 UTF-8 子集，解码安全） |
| `utf8` / `utf-8` | `Charsets.UTF8` |
| `gb2312` / `gbk` / `cp936` / `x-gbk` | `Charsets.GBK` |
| `gb18030` | `Charsets.GB18030` |
| `big5` / `cp950` | `Charsets.BIG5` |
| `iso-8859-1` / `latin1` | `Charsets.WINDOWS_1252`（CP1252 是 Latin-1 的超集；charset4cj 没有 ISO-8859-1） |
| `shift_jis` / `sjis` / `cp932` | `Charsets.SHIFT_JIS` |
| `euc-kr` / `ks_c_5601-1987` | `Charsets.EUCKR` |
| `iso-2022-jp` | `Charsets.ISO_2022_JP` |

**回退链**：

1. 声明了 charset 且能 `forName` → 用它；解码失败按 `strict` 决定抛或回退。
2. 声明缺失 → `defaultCharset`（默认 UTF-8；RFC 的 `us-ascii` 在实现上等价于 UTF-8 的 ASCII 子集）。
3. 声明未知 → 依次尝试 `UTF8` → `GB18030` → `WINDOWS_1252`；记录 `decodedWith`，供调用方判断。
4. 全部失败 → `WINDOWS_1252` 逐字节映射（永不失败），并置 `lossy=true`。

`MimePart` 暴露：

```cangjie
public prop charsetUsed: ?Charset     // 实际解码用的字符集
public prop charsetLossy: Bool        // 是否发生过替换
```

> **为什么不直接报错**：中文邮件里 `charset=gb2312` 但内容是 GBK 扩展字符、或者声明 `utf-8` 实际是 GBK 的情况非常常见。直接报错会让大量正常邮件读不出来；回退链 + 标记是更实用的选择。严格模式留给需要确定性的场景。

### 5.8 MIME 限制

| 限制 | 默认 | 超限行为 |
|---|---|---|
| 头部总字节 | 256 KB | `MailLimitException(Header)` |
| 单头部行 | 64 KB | 同上 |
| part 数量 | 1000 | `MailLimitException(Parts)` |
| 嵌套深度 | 32 | `MailLimitException(Depth)` |
| 单 literal / 单正文 | 0（不限，IMAP 另有 64 MB 上限） | 按来源配置 |
| boundary 长度 | 1–70 | 非法 boundary 视为普通文本，记 warning |
| 解码后正文 | `maxBodyBytes` | `MailLimitException(Body)` |

---

## 6. SMTP 客户端

### 6.1 状态机

```
CONNECT
  │  220 greeting
  ▼
GREETING ── EHLO ──▶ READY ────────────────┐
  │                   │                    │
  │                   ├─ STARTTLS ─▶ TLS ──┤（重新 EHLO）
  │                   ├─ AUTH ─────────────┤
  │                   ▼                    │
  │                 MAIL FROM               │
  │                   ▼                    │
  │                 RCPT TO*                │
  │                   ▼                    │
  │                 DATA ── 354 ── 正文 ── 250
  │                   │                    │
  │                   └──── 失败 ── RSET ───┘
  ▼
QUIT ── 221 ── CLOSED
```

### 6.2 API

```cangjie
public class SmtpClient <: Resource {
    public static func builder(host: String, port!: UInt16 = 587): SmtpClientBuilder
    public func send(message: MailMessage): SendReport
    public func send(envelope: Envelope, message: MailMessage): SendReport
    public func noop(): SmtpReply
    public func reset(): Unit
    public func close(): Unit          // 先尝试 QUIT，再关 socket
    public func isClosed(): Bool
    public prop capabilities: SmtpCapabilities
}

public class SmtpClientBuilder {
    public func tls(mode: TlsMode): This
    public func tlsConfig(config: TlsClientConfig): This
    public func auth(mechanism: SmtpAuthMechanism, user: String, secret: Secret): This
    public func oauth2(user: String, token: Secret): This
    public func helloName(name: String): This
    public func timeouts(timeouts: MailTimeouts): This
    public func requireEncryption(required: Bool): This      // 默认 true
    public func allowPlaintextAuth(allow: Bool): This        // 默认 false
    public func sendPolicy(policy: SendPolicy): This         // 默认 BestEffort
    public func maxMessageBytes(limit: Int64): This          // 默认 0 = 不限
    public func precomputeSize(enabled: Bool): This          // 默认 false；见 6.5
    public func dsn(ret!: DsnReturn, notify!: Array<DsnNotify>): This
    public func build(): SmtpClient
}
```

**`build()` 的校验**（POP3/IMAP 的 builder 相同）：

| 条件 | 行为 |
|---|---|
| `requireEncryption=true` 且 `tls=None` | 抛 `IllegalArgumentException`，不建立连接 |
| 配置了 `auth` / `oauth2` 且 `tls=None` 且 `allowPlaintextAuth=false` | 抛 `IllegalArgumentException` |
| `tls=StartTls` 但 `tlsConfig` 为空 | 使用默认配置（`serverName=host`、`verifyMode=Default`） |
| `helloName` 为空 | 用本机 hostname；取不到用 `localhost` |
| `maxMessageBytes > capabilities.size` | 不在 `build()` 判断（能力要连上才知道）；在 `send` 预检时失败 |

这些校验放在 `build()` 而不是第一次 `send`，是为了让配置错误在启动期暴露，而不是在业务请求里才炸。

**`SmtpClient.build()` 的建连时机**：`build()` 就完成 TCP 连接、读 greeting、`EHLO`、按配置 `STARTTLS`、`AUTH`。因此 `capabilities` 在 `build()` 返回后即可用；连接失败、认证失败都在 `build()` 抛出。`send()` 只做事务，不再重新握手。

```cangjie
public enum SendPolicy {
    | BestEffort      // 至少一个收件人成功就发送（默认）
    | AllOrNothing    // 任一收件人被拒 → 整封不发
}

public struct SendReport {
    public let messageId: String
    public let accepted: Array<RecipientStatus>
    public let rejected: Array<RecipientStatus>
    public let reply: SmtpReply
    public let aborted: Bool              // AllOrNothing 因部分拒收而整封未发
    public func isCompleteSuccess(): Bool
    public func isRetryable(): Bool
}

public struct RecipientStatus {
    public let address: String
    public let code: Int64
    public let enhanced: ?String
    public let text: String
    public let accepted: Bool
}

public struct SmtpReply {
    public let code: Int64
    public let lines: Array<String>       // 多行回复按顺序保留，已去掉 code 前缀
    public let enhanced: ?String          // 第一行里的 2.x.x / 4.x.x / 5.x.x
}

public enum DsnReturn {
    | Full
    | Headers
}

public enum DsnNotify {
    | Success
    | Failure
    | Delay
    | Never
}
```

`SmtpReply.lines` 保留服务器原文（已去掉 `250-` / `250 ` 前缀），用于日志与错误消息；`code` 取最后一行的三位码。

**EHLO 回退**：`EHLO` 返回 `500` / `502` / `504` 时，发 `HELO` 重试；`HELO` 成功则能力表为空，`STARTTLS` / `AUTH` / `SIZE` / `PIPELINING` 全部不可用。如果配置要求 TLS 或认证，直接失败——不支持 `EHLO` 的服务器基本也不可能支持这些扩展。

### 6.3 EHLO 扩展矩阵

| 扩展 | 用途 | M1 |
|---|---|---|
| `SIZE n` | 声明最大邮件大小；`MAIL FROM` 带 `SIZE=` | ✅ |
| `8BITMIME` | `BODY=8BITMIME` | ✅ |
| `SMTPUTF8` | UTF-8 地址与头 | ✅ |
| `PIPELINING` | 批量命令 | ✅ |
| `STARTTLS` | 升级 TLS | ✅ |
| `AUTH mech...` | 认证 | ✅ |
| `ENHANCEDSTATUSCODES` | 增强状态码 | ✅ 解析，不依赖 |
| `DSN` | 投递状态通知 | ✅ |
| `CHUNKING` / `BDAT` | 分块传输 | ❌ M4（M1 用 DATA） |
| `BINARYMIME` | 二进制正文 | ❌ 依赖 CHUNKING |
| `REQUIRETLS` | 强制 TLS 投递 | ❌ 只记录 |
| `DELIVERBY` | 投递时限 | ❌ |
| `ETRN` | 队列拉取 | ❌ |

`SmtpCapabilities`：

```cangjie
public class SmtpCapabilities {
    public func has(name: String): Bool
    public func value(name: String): ?String
    public prop size: ?Int64
    public prop authMechanisms: Array<String>
    public prop supports8BitMime: Bool
    public prop supportsSmtpUtf8: Bool
    public prop supportsPipelining: Bool
    public prop supportsStartTls: Bool
    public prop supportsDsn: Bool
}
```

### 6.4 AUTH

```cangjie
public enum SmtpAuthMechanism {
    | Plain
    | Login
    | CramMd5
    | XOAuth2
}
```

| 机制 | 流程 | 默认允许 |
|---|---|---|
| `PLAIN` | `AUTH PLAIN <base64(\0user\0pass)>`；服务器 334 时再发一次 | 仅 TLS |
| `LOGIN` | `AUTH LOGIN` → 334 user → 334 pass | 仅 TLS |
| `CRAM-MD5` | `AUTH CRAM-MD5` → 334 challenge → `base64(user + " " + hex(HMAC-MD5(pass, challenge)))` | 仅 TLS（默认策略统一） |
| `XOAUTH2` | `AUTH XOAUTH2 <base64("user=...\x01auth=Bearer ...\x01\x01")>` | 仅 TLS |

**机制选择**：调用方指定；不自动降级（`PLAIN` 失败不会偷偷换 `LOGIN`，因为失败原因通常不是机制）。未指定时按 `XOAUTH2 > CRAM-MD5 > PLAIN > LOGIN` 里服务器广告且配置可用的第一个。

**CRAM-MD5 实现**：

```cangjie
secret.use { password =>
    let md5 = HMAC(password.unsafeBytes(), HashType.MD5)
    md5.write(challenge)
    let digest = toHexString(md5.finish())      // 小写十六进制
    toBase64String((user + " " + digest).unsafeBytes())
}
```

**XOAUTH2 失败**：服务器可能返回 `334 <base64 JSON>`，客户端必须发一个空行结束挑战，再读最终的 `535`；不要把它当成成功。

### 6.5 发送流程

```
1. 连接、读 220 greeting
2. EHLO helloName
3. STARTTLS（若配置）→ TLS 握手 → 重新 EHLO
4. AUTH（若配置）→ 235
5. envelope = Envelope.fromMessage(message)
6. 预检：
   - From 非空
   - 地址无 CR/LF；非 ASCII 地址要求 SMTPUTF8
   - message 大小已知且 > capabilities.size → 失败
7. MAIL FROM:<from> [SIZE=n] [BODY=8BITMIME] [SMTPUTF8] [RET=...]
8. RCPT TO:<rcpt> [NOTIFY=...] [ORCPT=...]（逐收件人）
9. 根据 SendPolicy：
   - BestEffort：至少一个 2xx → DATA
   - AllOrNothing：全部 2xx → DATA，否则 RSET 并返回
10. DATA → 354 → MimeWriter 流式写 → DotStuff → "." → 250
11. 返回 SendReport
```

**PIPELINING**（`capabilities.supportsPipelining`）：

```
BestEffort:
  write: MAIL FROM, RCPT..., DATA     （一次 flush）
  read:  按顺序读所有回复
  if DATA 回复不是 354 → RSET
  if 有 2xx 收件人 → 写正文 + "."
  else → 写 ".\r\n" 结束空 DATA（仅服务器不合规地给了 354 时），再 RSET

AllOrNothing:
  不 pipeline DATA；先 MAIL + RCPT，全部 2xx 才发 DATA
```

最后一条 `else` 是防御性分支：RFC 2920 要求服务器在无有效收件人时对 `DATA` 回 `554`/`503`，但现实中有服务器仍回 `354`。此时客户端已进入 DATA 状态，**不能发 RSET**，只能用 `.<CRLF>` 结束一个空事务；没有收件人，所以不会产生投递。

**为什么 `AllOrNothing` 不 pipeline DATA**：一旦服务器回了 354，客户端就进入 DATA 状态；此时若发现某个 RCPT 被拒，只能发一个空正文的 `.`，会把空邮件投给已接受的收件人。关掉这一小段流水线是唯一正确的做法。

**逐收件人状态**：

- `RCPT` 的 250/251 → accepted；4xx/5xx → rejected，记录 code/enhanced/text。
- `MAIL` 失败 → 所有收件人都标记为同一失败，`SendReport.reply` 是 MAIL 的回复。
- `DATA` 失败（552/554）→ 全部收件人失败。
- 发送成功后 `250` 的 enhanced code 通常是 `2.0.0`。
- **`AllOrNothing` 中止时**：`accepted` 为空；`rejected` 包含全部收件人（原本通过的那些 `code=0`、`text="aborted by AllOrNothing"`）；`aborted=true`。这样调用方不会误以为「部分已发」。

**Bcc**：`SmtpClient` 在序列化时**跳过** `Bcc`，且**不修改调用方的 `MailMessage`**。这是发送路径的**硬规则**，不提供「保留 Bcc」选项——保留了就是把密送名单泄露给所有收件人。

**SIZE**：

- **默认不发送 `SIZE=`**。流式写 `DATA`，不为算大小多写一遍；服务器在 `DATA` 阶段用 `552` 拒绝超限邮件。
- `precomputeSize(true)` 或 `maxMessageBytes > 0` 时，先序列化到 `BodySource`（≤ `spoolThreshold` 内存，超过落临时文件）得到精确字节数 `n`；所有 `BodySource` 可重复且 `size` 已知时，也可以只写计数 sink（不落盘）算 `n`。
- 只有拿到 `n` 才发 `SIZE=n`；`n > capabilities.size` 或 `n > maxMessageBytes` → 在 `MAIL FROM` 之前失败。
- `SIZE=` 的值是**序列化后的报文字节数**，不含 dot-stuffing 额外加的点，也不含结束的 `.<CRLF>`（RFC 1870 §5）。

**8BITMIME / SMTPUTF8**：

| 情况 | 行为 |
|---|---|
| 正文含 8 位字节，服务器支持 `8BITMIME` | `BODY=8BITMIME`，正文可以 8bit |
| 正文含 8 位字节，服务器不支持 | `MimeWriter` 强制 QP/base64，绝不发裸 8 位 |
| 信封地址含非 ASCII，服务器支持 `SMTPUTF8` | `MAIL FROM ... SMTPUTF8`，头部保持 UTF-8 |
| 信封地址含非 ASCII，服务器不支持 | 抛 `MailProtocolException`（不 punycode、不替换） |
| 只有显示名/主题含非 ASCII | RFC 2047 编码，不要求 `SMTPUTF8` |

**DSN**：`MAIL FROM` 带 `RET=HDRS|FULL`，`RCPT TO` 带 `NOTIFY=SUCCESS,FAILURE,DELAY` 与 `ORCPT=rfc822;addr`。只在服务器广告 `DSN` 时发送；否则忽略并记 warning。

### 6.6 错误与重试

**客户端不自动重试。** 理由：

1. SMTP 的 `250` 可能在网络中断前已经到达服务器，客户端没收到就重试 → **重复投递**。
2. 重试需要持久化队列、退避、去重键，这是 MTA 的职责，不是库的职责。
3. 应用层通常有更好的幂等键（业务单号），库不该替它决定。

只提供分类：

```cangjie
public func isRetryable(report: SendReport): Bool
public func isRetryable(error: MailException): Bool
```

| 情况 | 可重试 |
|---|---|
| 连接失败、超时、TLS 失败 | ✅ |
| `421` / `450` / `451` / `452` | ✅ |
| `4xx` 增强码 `4.x.x` | ✅ |
| `5xx` / 增强码 `5.x.x` | ❌ |
| `535` 认证失败 | ❌（重试只会再失败） |
| `552` 超出大小 | ❌（除非调整内容） |
| 全部收件人 `5xx` | ❌ |
| 部分收件人 `4xx` | ✅（只重试被拒的那部分） |
| 全部收件人 `4xx` | ✅（整封重试；调用方需自行去重） |

### 6.7 连接复用

- 一个 `SmtpClient` 持有一条连接，可在同一连接上连续 `send`。
- 两封之间服务器可能因空闲断开；下一次 `send` 前若 `isClosed()` 或 `NOOP` 失败 → 抛 `MailIoException`，由调用方重建客户端。
- **不在 `send` 内部自动重连**：重连后重发同一封邮件同样有重复投递风险。
- 需要并发发信 → 每个线程一个 `SmtpClient`；连接池是 M4 的可选项，不是 M1。

---

## 7. POP3 客户端

### 7.1 状态机

```
CONNECT ── +OK ──▶ AUTHORIZATION
                      │ USER/PASS | APOP | AUTH
                      ▼
                  TRANSACTION ── STAT/LIST/UIDL/RETR/TOP/DELE/RSET/NOOP
                      │ QUIT
                      ▼
                   UPDATE（提交删除）── +OK ── CLOSED
```

- `close()` 不走 `QUIT` → **不进入 UPDATE**，已 `DELE` 的邮件保留。
- 连接异常断开 → 同样不进入 UPDATE，删除不生效。

### 7.2 API

```cangjie
public class Pop3Client <: Resource {
    public static func builder(host: String, port!: UInt16 = 110): Pop3ClientBuilder
    public func login(user: String, password: Secret): Unit
    public func apop(user: String, password: Secret): Unit
    public func authenticate(mechanism: Pop3AuthMechanism, user: String, secret: Secret): Unit

    public func stat(): Pop3Stat
    public func list(): Array<Pop3MessageInfo>
    public func list(message: Int64): Pop3MessageInfo
    public func uidl(): Array<Pop3Uidl>
    public func uidl(message: Int64): String

    public func retr(message: Int64, sink: OutputStream): Int64
    public func retrMessage(message: Int64,
                            options!: MimeParseOptions = MimeParseOptions()): MailMessage
    public func top(message: Int64, lines: Int64, sink: OutputStream): Int64
    public func topMessage(message: Int64, lines: Int64,
                           options!: MimeParseOptions = MimeParseOptions()): MailMessage

    public func dele(message: Int64): Unit
    public func rset(): Unit
    public func noop(): Unit
    public func quit(): Unit
    public func close(): Unit
    public func isClosed(): Bool
    public prop capabilities: Pop3Capabilities
}

public struct Pop3Stat {
    public let count: Int64
    public let size: Int64
}

public struct Pop3MessageInfo {
    public let message: Int64
    public let size: Int64
}

public struct Pop3Uidl {
    public let message: Int64
    public let uid: String
}

public class Pop3Capabilities {
    public func has(name: String): Bool
    public func value(name: String): ?String
    public prop supportsTop: Bool
    public prop supportsUidl: Bool
    public prop supportsStls: Bool
    public prop supportsPipelining: Bool
    public prop authMechanisms: Array<String>
}

public enum Pop3AuthMechanism {
    | Plain
    | Login
}

public class Pop3ClientBuilder {
    public func tls(mode: TlsMode): This
    public func tlsConfig(config: TlsClientConfig): This
    public func timeouts(timeouts: MailTimeouts): This
    public func requireEncryption(required: Bool): This
    public func allowPlaintextAuth(allow: Bool): This
    public func build(): Pop3Client
}
```

**`Pop3Client.build()`**：完成 TCP 连接、读 greeting、`CAPA`（可选）、按配置 `STLS`；**不登录**。`login()` / `apop()` / `authenticate()` 才进入 TRANSACTION 状态。这样调用方可以先看 `capabilities` 再决定认证方式。

### 7.3 命令矩阵

| 命令 | 状态 | 回复 | 说明 |
|---|---|---|---|
| `CAPA` | AUTHORIZATION / TRANSACTION | 多行 | 能力：`TOP`、`UIDL`、`PIPELINING`、`RESP-CODES`、`AUTH`、`STLS`、`IMPLEMENTATION`（M2 只利用 `TOP` / `UIDL` / `AUTH` / `STLS`） |
| `USER` / `PASS` | AUTHORIZATION | `+OK` / `-ERR` | 明文密码；必须 TLS |
| `APOP` | AUTHORIZATION | `+OK` / `-ERR` | 需要 greeting 里的 `<timestamp>` |
| `AUTH` | AUTHORIZATION | `+` 挑战 | RFC 5034；PLAIN / LOGIN |
| `STLS` | AUTHORIZATION | `+OK` | 升级 TLS 后重新 `CAPA` |
| `STAT` | TRANSACTION | `+OK n size` | 邮件数与总字节 |
| `LIST` | TRANSACTION | `+OK` + 多行 / `+OK n size` | 不改变状态 |
| `UIDL` | TRANSACTION | `+OK` + 多行 / `+OK uid` | 持久唯一标识 |
| `RETR n` | TRANSACTION | `+OK size` + 多行 | 整封下载 |
| `TOP n lines` | TRANSACTION | `+OK` + 多行 | 头部 + 前 n 行正文 |
| `DELE n` | TRANSACTION | `+OK` | 只标记，不立即删除 |
| `RSET` | TRANSACTION | `+OK` | 取消所有 DELE 标记 |
| `NOOP` | TRANSACTION | `+OK` | 保活 |
| `QUIT` | TRANSACTION | `+OK` | 进入 UPDATE，提交删除 |

### 7.4 多行响应与流式 RETR

POP3 多行响应的规则：

- 第一行 `+OK ...`，随后若干行，最后一行是单独的 `.`。
- 正文里以 `.` 开头的行，服务器会写成 `..`；客户端要还原。
- 行结束符 CRLF；规范行上限 512，但真实邮件正文可能更长。

**`RETR` 必须流式**：

```cangjie
public func retr(message: Int64, sink: OutputStream): Int64 {
    let channel = connection.channel()
    let reply = channel.readLine()       // +OK n octets
    parseOk(reply)
    let reader = DotUnstuffReader(channel)
    var total = 0
    let buf = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = reader.read(buf)
        if (n <= 0) { break }
        sink.write(buf[0..n])
        total += n
    }
    total
}
```

- `retrMessage` 把 `DotUnstuffReader` 直接接到 `MimeParser.parse`，**不产生中间整封文件**（附件仍按 `spoolThreshold` 落盘）。
- `topMessage` 同理，但只读前 n 行正文；`TOP` 不支持时（`CAPA` 无 `TOP`）抛 `MailProtocolException`。
- 多行响应的行上限只作用于 `LIST` / `UIDL` 这类控制行；`RETR` 正文按字节流处理，不做行长限制。

### 7.5 删除语义

| 操作 | 效果 |
|---|---|
| `DELE n` | 标记；本次会话内 `LIST` 可能仍列出（标记为删除），以服务器实现为准 |
| `RSET` | 取消所有标记 |
| `QUIT` | 服务器进入 UPDATE，真正删除；成功才返回 `+OK` |
| `close()` / 连接断开 | 不进入 UPDATE，删除不生效 |
| 同一封重复 `DELE` | `-ERR`，抛 `MailProtocolException` |

**POP3 没有「已读」概念**：下载即代表客户端处理；要保留在服务器上就不能 `DELE`。需要「已读/未读/搜索」的场景必须用 IMAP，这是协议边界，不是实现缺失。

### 7.6 认证

| 方式 | 安全性 | 说明 |
|---|---|---|
| `USER`/`PASS` | 低 | 明文；默认只允许 TLS |
| `APOP` | 中 | MD5(timestamp + password)；服务器 greeting 必须带 `<...>`；MD5 已不适合作为唯一防线 |
| `AUTH PLAIN` / `LOGIN` | 低 | RFC 5034；base64 不是加密，必须 TLS |

`Pop3ClientBuilder` 的默认策略与 SMTP 一致：`requireEncryption=true`，`allowPlaintextAuth=false`。`STLS` 后必须重新 `CAPA`，因为 `TOP`/`UIDL` 可能在 TLS 后才广告。

`CAPA` 本身返回 `-ERR` 时（老服务器不支持），能力表置空，**不直接失败**：`UIDL` / `TOP` 仍然尝试，服务器不支持时按 `-ERR` 映射成 `MailProtocolException`。但 `STLS` 必须依赖 `CAPA` 广告或直接尝试 `STLS`——后者只允许在 `allowPlaintextAuth=true` 的兼容模式下使用。

### 7.7 与 MIME 的衔接

```cangjie
let info = pop.list(1)
let message = pop.retrMessage(1)          // 内部：DotUnstuff → MimeParser
let text = message.text()
let attachments = message.attachments()
```

- `retrMessage` 的 `MimeParseOptions` 直接透传；附件落临时文件的目录由 `spoolDir` 控制。
- 如果调用方只想要头部（例如预览），用 `topMessage(1, 0)`：只解析头部，正文为空。
- POP3 的 `UIDL` 是跨会话的去重键；调用方若要做「只处理新邮件」，自己保存 UID 集合。

---

## 8. IMAP 客户端

### 8.1 会话模型

IMAP 与 SMTP/POP3 最大的不同：**服务器可以在任何时候推送 untagged 响应**，不限于当前命令的回复。

```
C: A0001 LOGIN user pass
S: A0001 OK LOGIN completed
C: A0002 SELECT INBOX
S: * 172 EXISTS
S: * 1 RECENT
S: * OK [UNSEEN 12] Message 12 is first unseen
S: * OK [UIDVALIDITY 3857529045] UIDs valid
S: * OK [UIDNEXT 4392] Predicted next UID
S: * FLAGS (\Answered \Flagged \Deleted \Seen \Draft)
S: * OK [PERMANENTFLAGS (\Deleted \Seen \*)] Limited
S: A0002 OK [READ-WRITE] SELECT completed
```

客户端必须：

1. **按 tag 匹配命令回复**：`A0002` 的 tagged 回复才是 `SELECT` 的结果。
2. **untagged 响应进分发器**：可能属于当前命令（`FETCH`、`SEARCH`），也可能是状态更新（`EXISTS`、`EXPUNGE`）。
3. **continuation `+`** 只用于 literal 或 `IDLE`。
4. **`BYE`** 表示服务器要关闭连接；记录原因并让当前命令失败。

### 8.2 API

```cangjie
public class ImapClient <: Resource {
    public static func builder(host: String, port!: UInt16 = 143): ImapClientBuilder
    public func capability(): ImapCapabilities
    public func login(user: String, password: Secret): Unit
    public func authenticate(mechanism: ImapAuthMechanism, user: String, secret: Secret): Unit

    public func select(mailbox: String): MailboxStatus
    public func examine(mailbox: String): MailboxStatus
    public func closeMailbox(): Unit                 // CLOSE，静默 expunge
    public func unselect(): Unit                     // UNSELECT 扩展

    public func list(reference!: String = "", pattern!: String = "*"): Array<MailboxInfo>
    public func lsub(reference!: String = "", pattern!: String = "*"): Array<MailboxInfo>
    public func status(mailbox: String, items!: Array<StatusItem>): MailboxStatus

    public func fetch(sequence: SequenceSet, items: Array<FetchItem>): Array<FetchResult>
    public func fetch(sequence: SequenceSet, items: Array<FetchItem>, sink: FetchSink): Unit
    public func uidFetch(uids: SequenceSet, items: Array<FetchItem>): Array<FetchResult>
    public func uidFetch(uids: SequenceSet, items: Array<FetchItem>, sink: FetchSink): Unit
    public func fetchMessage(sequence: Int64,
                             options!: MimeParseOptions = MimeParseOptions()): MailMessage
    public func uidFetchMessage(uid: Int64,
                                options!: MimeParseOptions = MimeParseOptions()): MailMessage

    public func search(criteria: SearchCriteria): Array<Int64>
    public func uidSearch(criteria: SearchCriteria): Array<Int64>
    public func store(sequence: SequenceSet, action: StoreAction, flags: Array<String>,
                      silent!: Bool = false): Array<FetchResult>
    public func copy(sequence: SequenceSet, mailbox: String): CopyResult
    public func expunge(): Array<Int64>
    public func uidExpunge(uids: SequenceSet): Array<Int64>   // UIDPLUS
    public func append(mailbox: String, message: MailMessage,
                       flags!: Array<String> = [], date!: ?MailDate = None): ?AppendResult

    public func idle(): IdleSession
    public func logout(): Unit
    public func close(): Unit
    public func isClosed(): Bool
    public prop capabilities: ImapCapabilities
    public prop selected: ?MailboxStatus
}
```

```cangjie
public class ImapClientBuilder {
    public func tls(mode: TlsMode): This
    public func tlsConfig(config: TlsClientConfig): This
    public func timeouts(timeouts: MailTimeouts): This
    public func requireEncryption(required: Bool): This
    public func allowPlaintextAuth(allow: Bool): This
    public func maxLiteralBytes(limit: Int64): This
    /// RFC 2971：在 CAPABILITY 之后、LOGIN 之前发送；163/126 必填
    public func id(parameters: HashMap<String, String>): This
    public func build(): ImapClient
}
```

163/126 的 `id` 典型值：

```cangjie
.id({"name": "fountain", "version": "1.0", "vendor": "example"})
```

`build()` 只连接 + `CAPABILITY` + `STARTTLS` + `ID`；不登录。

`close()` 直接关闭 socket；要礼貌结束会话用 `logout()`（发 `LOGOUT`，读 `* BYE` 与 tagged `OK`）。

```cangjie
public class SequenceSet {
    public static func of(spec: String): SequenceSet
    public static func single(n: Int64): SequenceSet
    public static func range(from: Int64, to: Int64): SequenceSet
    public func union(other: SequenceSet): SequenceSet
    public func toString(): String
}

public struct FetchItem {
    public static let uid: FetchItem
    public static let flags: FetchItem
    public static let internalDate: FetchItem
    public static let size: FetchItem
    public static let envelope: FetchItem
    public static let bodyStructure: FetchItem
    public static func body(section!: String = "", peek!: Bool = true,
                            partial!: ?(Int64, Int64) = None): FetchItem
}
```

`FetchResult` / `FetchMeta`：

```cangjie
public class FetchResult {
    public prop sequence: Int64
    public prop uid: ?Int64
    public prop flags: Array<String>
    public prop internalDate: ?MailDate
    public prop size: ?Int64
    public prop envelope: ?ImapEnvelope
    public prop bodyStructure: ?BodyStructure
    public prop sections: HashMap<String, BodySource>
}

public interface FetchSink {
    /// 一条 FETCH 的元数据（不含大正文）
    func onMessage(meta: FetchMeta): Unit
    /// 大正文字节流；input 只在本次调用期间有效
    func onBody(sequence: Int64, section: BodySection, input: InputStream): Unit
}
```

#### 8.2.1 返回类型

```cangjie
public struct MailboxStatus {
    public let exists: ?Int64             // SELECT 必有；STATUS 未请求时为 None
    public let recent: ?Int64
    public let uidValidity: ?Int64
    public let uidNext: ?Int64
    public let unseen: ?Int64
    public let flags: Array<String>
    public let permanentFlags: Array<String>
    public let readOnly: ?Bool            // SELECT/EXAMINE 必有；STATUS 为 None
}

public struct MailboxInfo {
    public let name: String              // 已从 modified UTF-7 解码
    public let delimiter: ?String
    public let attributes: Array<String> // \HasNoChildren / \Noselect / \Sent ...
}

public enum StatusItem {
    | Messages
    | Recent
    | UidNext
    | UidValidity
    | Unseen
}

public class ImapEnvelope {
    public let date: ?String
    public let subject: ?String
    public let from: AddressList
    public let sender: AddressList
    public let replyTo: AddressList
    public let to: AddressList
    public let cc: AddressList
    public let bcc: AddressList
    public let inReplyTo: ?String
    public let messageId: ?String
}

public abstract class BodyStructure {
    public let mediaType: String
    public let parameters: HashMap<String, String>
    public let contentId: ?String
    public let description: ?String
    public let encoding: ?String
    public let size: Int64
}

public class LeafBody <: BodyStructure {
    public let lines: ?Int64
}

public class MultiBody <: BodyStructure {
    public let children: Array<BodyStructure>
    public let subType: String           // mixed / alternative / related ...
}

public struct FetchMeta {
    public let sequence: Int64
    public let uid: ?Int64
    public let flags: Array<String>
    public let internalDate: ?MailDate
    public let size: ?Int64
    public let envelope: ?ImapEnvelope
    public let bodyStructure: ?BodyStructure
}

public struct BodySection {
    public let path: String               // "" / "1.2"
    public let specifier: String          // "" / "HEADER" / "TEXT" / "HEADER.FIELDS"
    public let fields: Array<String>      // HEADER.FIELDS 的字段名
    public let partial: ?(Int64, Int64)   // (origin, length)
}

public struct CopyResult {
    public let uidValidity: ?Int64
    public let sourceUids: Array<Int64>
    public let destinationUids: Array<Int64>
}

public struct AppendResult {
    public let uidValidity: Int64
    public let uid: Int64
}

public class ImapCapabilities {
    public func has(name: String): Bool
    public func value(name: String): ?String
    public prop supportsIdle: Bool
    public prop supportsUidPlus: Bool
    public prop supportsMove: Bool
    public prop supportsLiteralPlus: Bool
    public prop supportsUtf8Accept: Bool
}

public enum ImapAuthMechanism {
    | Plain
    | Login
    | CramMd5
    | XOAuth2
}
```

**`ImapClient.build()`**：完成 TCP 连接、读 greeting、`CAPABILITY`（greeting 里带能力时也再查一次）、按配置 `STARTTLS`；**不登录**。`login()` / `authenticate()` 才进入已认证状态。

### 8.3 命令与响应解析

**命令编码**：

```
tag SP command [SP arguments] CRLF
```

**认证与 TLS 的顺序**：`STARTTLS` 只能在未认证状态发送；升级后重新 `CAPABILITY`（能力可能变化），再 `LOGIN`/`AUTHENTICATE`。`AUTHENTICATE` 的流程与 SMTP 类似：服务器返回 `+` 挑战，客户端回 base64；有 `SASL-IR` 能力时可带初始响应。认证失败返回 tagged `NO`；客户端发 `*` 可以取消进行中的 `AUTHENTICATE`。

- `tag`：`A` + 4 位十六进制递增（`A0001`…）；不回绕，超过 `AFFFF` 用 `B0001`。
- 参数里的字符串：
  - 纯 ASCII、无引号/反斜杠/CRLF → `"..."` 加引号；
  - 含 `"` / `\` → 转义；
  - 含非 ASCII / CRLF / 过长 → 用 literal `{n}`；
  - **邮箱名是例外**：非 ASCII 必须先按 modified UTF-7 编码（8.9），不能直接发 UTF-8 literal，除非服务器声明 `UTF8=ACCEPT`。
- **mailbox 名称**：除 `INBOX` 外大小写敏感；非 ASCII 用 modified UTF-7（8.9）。

**响应解析器**：

```cangjie
public enum ImapToken {
    | Atom(String)
    | Quoted(String)
    | Literal(Int64)          // 后面跟 n 字节
    | Number(Int64)
    | LParen
    | RParen
    | Nil
}
```

- 递归下降；`(` / `)` 建成 `ImapValue.List`。
- 原子：除 `(){%*"\\]` 和空白外的可见字符；`\Seen` 这类标志是原子。
- `NIL` → `ImapValue.Nil`。
- literal：**不在 token 里存字节**，只记长度；由调用方在 `readExact` 时消费。
- 嵌套深度上限 64；超过抛 `MailLimitException(Depth)`。
- 行上限 8 KB；literal 单独计数。

`ImapValue`：

```cangjie
public enum ImapValue {
    | Atom(String)
    | Str(String)
    | Number(Int64)
    | Nil
    | List(Array<ImapValue>)
    | Literal(BodySource)
}
```

### 8.4 literal 必须流式

`FETCH BODY[] {10485760}` 后面可能是 10 MB 附件。三种处理方式：

| 方式 | 结果 |
|---|---|
| 读进 `String` 再转字节 | 10 MB 变 20 MB，且可能按错误编码损坏 |
| 读进 `Array<Byte>` | 峰值 20 MB，无法处理 1 GB 邮件 |
| **边读边写 `BodySource` / 调用方 sink** | 内存恒定，正确 |

实现：

- `ImapParser` 遇到 `{n}` 时返回 `Literal(n)`，由 `ImapClient` 决定目标是内存、临时文件还是 `FetchSink`。
- 小 literal（< `inlineLiteralLimit`，默认 64 KB）可以进 `MemoryBodySource`；大的直接 `Spool`。
- 发送侧的 `APPEND`：`MailMessage` 先序列化到 `BodySource` 以获得精确大小，再写 `{n}`；`LITERAL+` 可用时用 `{n+}` 省一次往返。

### 8.5 FETCH

`FETCH` 的响应是一条 untagged `* n FETCH (...)`，括号里是键值对：

```
* 1 FETCH (UID 100 FLAGS (\Seen) INTERNALDATE "28-Oct-2026 21:58:52 +0800"
          RFC822.SIZE 1234 BODY[HEADER] {342}
...342 bytes...
)
```

解析要点：

| 项 | 处理 |
|---|---|
| `UID` | 数字 |
| `FLAGS` | 括号里的原子列表；`\Recent` 不可设置 |
| `INTERNALDATE` | IMAP 日期格式（`dd-Mon-yyyy HH:mm:ss +zzzz`），与 RFC 5322 不同 |
| `RFC822.SIZE` | 数字 |
| `ENVELOPE` | 10 字段列表：date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id；解析成 `ImapEnvelope`（与 4.5 的 SMTP `Envelope` 不是同一个东西）。`subject` 按 RFC 2047 解码；`date` 保留原文（IMAP 的日期格式与 RFC 5322 不同） |
| `BODYSTRUCTURE` | 嵌套列表；解析成 `BodyStructure` 树 |
| `BODY[section]` / `BODY.PEEK[section]` | 值通常是 literal；section 可能是 `HEADER`、`TEXT`、`1.2`、`HEADER.FIELDS (FROM TO)`；`<origin.length>` 是部分获取 |
| `BODY[]` | 整封邮件，走 `fetchMessage` |
| 未知项 | 保留原始 `ImapValue`，不丢 |

**部分获取**：`BODY.PEEK[]<0.1024>` 只取前 1 KB；响应的 section 键会带 `<0>`。用于预览，避免下载整个附件。

**`fetchMessage`**：内部发 `FETCH <seq> (BODY.PEEK[])`；`uidFetchMessage` 发 `UID FETCH <uid> (BODY.PEEK[])`。两者都把 literal 直接交给 `MimeParser`，不设置 `\Seen`（`PEEK`）。

### 8.6 SEARCH / STORE / COPY / EXPUNGE

**SEARCH**：

```cangjie
public class SearchCriteria {
    public static func all(): SearchCriteria
    public static func unseen(): SearchCriteria
    public static func seen(): SearchCriteria
    public static func from(address: String): SearchCriteria
    public static func to(address: String): SearchCriteria
    public static func subject(text: String): SearchCriteria
    public static func body(text: String): SearchCriteria
    public static func text(text: String): SearchCriteria
    public static func since(date: MailDate): SearchCriteria
    public static func before(date: MailDate): SearchCriteria
    public static func header(name: String, value: String): SearchCriteria
    public static func uid(set: SequenceSet): SearchCriteria
    public func and(other: SearchCriteria): SearchCriteria
    public func or(other: SearchCriteria): SearchCriteria
    public func not(): SearchCriteria
}
```

- 字符串参数用 quoted string 或 literal；非 ASCII 需要 `CHARSET UTF-8`（服务器支持 `UTF8=ACCEPT` 或 `SEARCH` 的 `CHARSET` 能力）。
- 结果：`* SEARCH 1 2 3`；`UID SEARCH` 返回 UID。
- 不提供「自动分页」；`SEARCH` 一次返回全部匹配，超大结果由调用方用日期/UID 分段。

**STORE**：

```cangjie
public enum StoreAction {
    | Replace      // FLAGS
    | Add          // +FLAGS
    | Remove       // -FLAGS
}
```

- 默认不加 `.SILENT`，这样能拿到服务器确认的新 flags；`silent=true` 时只读 tagged OK。
- 修改 `\Deleted` 后必须 `EXPUNGE`（或 `CLOSE`）才真正删除。

**COPY**：`COPY seq mailbox`；有 `UIDPLUS` 时返回 `[COPYUID uidvalidity srcuids dstuids]`，否则只返回 OK。

**EXPUNGE**：返回被删除的序号列表。**注意序号会移动**：删除 3 后，原来的 4 变成 3；客户端缓存的序号必须按返回顺序调整，或改用 UID。`UID EXPUNGE <set>`（UIDPLUS）只删指定 UID，不受序号移动影响，优先用它。

### 8.7 APPEND

```
C: A0005 APPEND "INBOX" (\Seen) "28-Oct-2026 21:58:52 +0800" {12345}
S: + Ready for literal data
C: ...12345 bytes...
S: A0005 OK [APPENDUID 3857529045 4392] APPEND completed
```

- 大小必须**预先知道**：`MimeWriter` 先写 `BodySource`（内存/临时文件）计数，再发命令。
- `LITERAL+` 可用时用 `{12345+}`，不等 `+` 直接写。
- `date` 可选；不传则由服务器决定。
- `UIDPLUS` 时返回 `AppendResult(uidValidity, uid)`。

### 8.8 IDLE

```cangjie
public class IdleSession <: Resource {
    public func nextEvent(timeout!: Duration): ?ImapEvent
    public func close(): Unit
}

public enum ImapEvent {
    | Exists(Int64)
    | Expunge(Int64)
    | Recent(Int64)
    | Fetch(FetchMeta)
    | Bye(String)
    | Other(kind: String, value: ImapValue)
}
```

流程：

```
C: A0010 IDLE
S: + idling
   ... 服务器推送 * 173 EXISTS / * 5 EXPUNGE ...
C: DONE
S: A0010 OK IDLE terminated
```

- **重发间隔 25 分钟**：RFC 2177 建议服务器至少保持 30 分钟；客户端在 25 分钟时主动 `DONE` 并重新 `IDLE`，避免被服务器静默断开。
- **前置条件**：`idle()` 只能在 `SELECT` / `EXAMINE` 之后调用；未选择邮箱时抛 `MailProtocolException`。
- `nextEvent(timeout)` 在内部队列上阻塞；`close()` 发送 `DONE`（如果还处于 IDLE）并结束读线程。
- **回调不在读线程里执行用户代码**：事件进队列，由调用方线程消费；避免用户回调阻塞导致服务器超时。
- IDLE 期间不能发其他命令；需要并发操作就用第二条连接。

### 8.9 modified UTF-7（邮箱名）

IMAP4rev1 的邮箱名不是 UTF-8，而是 **modified UTF-7**（RFC 3501 §5.1.3）：

```
& → &-
非 ASCII 连续段 → & + UTF-16BE 的 base64（'/' 换成 ','，去掉 '=' 填充）+ -
```

```cangjie
public class ImapUtf7 {
    public static func encode(name: String): String
    public static func decode(name: String): String
}
```

- 只处理邮箱名；`SEARCH` 的字符串、`APPEND` 的 flags 不用。
- `UTF8=ACCEPT` / `UTF8=ONLY` 可用时，可直接用 UTF-8；M4 支持，M3 默认走 modified UTF-7。
- 解码失败：宽松模式原样返回 + warning；严格模式抛 `MimeException`。

### 8.10 扩展矩阵

| 扩展 | RFC | 里程碑 |
|---|---|---|
| `LITERAL+` | 2088 | M3（发送侧可选） |
| `UIDPLUS` | 4315 | M3（`APPENDUID` / `COPYUID` / `UID EXPUNGE`） |
| `UNSELECT` | 3691 | M3 |
| `IDLE` | 2177 | M4 |
| `MOVE` | 6851 | M4 |
| `SPECIAL-USE` | 6154 | M4 |
| `ID` | 2971 | **M3**（163/126 要求登录前发 `ID`，否则报 `Unsafe Login`） |
| `NAMESPACE` | 2342 | M4 |
| `CONDSTORE` / `QRESYNC` | 7162 | M4（可选） |
| `SORT` / `THREAD` | 5256 / 5256 | M4（可选） |
| `UTF8=ACCEPT` | 6855 | M4 |
| `METADATA` / `QUOTA` | 5464 / 2087 | 不做（需要时再加） |

---

## 9. 安全

| 威胁 | 防线 |
|---|---|
| **STARTTLS 剥离** | 配置了 `StartTls` 而服务器不广告 → 直接失败；不静默明文 |
| **明文凭据泄露** | 默认 `requireEncryption=true`；`AUTH`/`PASS`/`LOGIN` 只在 TLS 后发送；`allowPlaintextAuth` 必须显式打开 |
| **证书伪造** | 默认 `CertificateVerifyMode.Default`；`TrustAll` 只能显式设置；文档不提供「为了方便默认信任」的开关 |
| **CRLF 注入** | `LineChannel.writeLine` 统一拒绝 `\r`/`\n`；地址、头字段、IMAP 标签/邮箱名在进入协议层前再校验一次 |
| **SMTP 命令注入** | 信封地址只允许 `addr-spec` 字符集；`<`/`>`/CR/LF 直接拒绝；显示名不进入命令 |
| **SMTP smuggling** | 客户端始终 CRLF、始终 dot-stuff；不接受调用方提供的裸 LF；`DATA` 结束严格 `.\r\n` |
| **日志注入** | 所有写入日志的协议行先转义控制字符；AUTH/PASS 行整体替换为 `AUTH <redacted>` |
| **凭据落盘** | `Secret` 不实现 `ToString` 的原文输出；不写入异常消息；不写入 trace |
| **附件路径穿越** | `Spool` 的文件名由内部随机生成，**不使用 `filename` 参数**；`filename` 只作为元数据 |
| **临时文件泄露** | 创建时 0600；`close()` 删除；进程退出时 `deleteOnExit` 兜底 |
| **IMAP literal 炸弹** | `maxLiteralBytes` 默认 64 MB；超限断开，不继续读 |
| **MIME 嵌套炸弹** | `maxDepth=32`、`maxParts=1000`、`maxHeaderBytes=256 KB` |
| **base64/QP 膨胀** | 解码边读边写，超过 `maxBodyBytes` 立即中断；不先解码成完整数组再检查 |
| **SSRF / 本地文件读取** | MIME 解析**不解析 `cid:`、不读本地路径、不访问 URL**；`multipart/related` 只暴露 ID |
| **HTML 注入** | 库不做渲染；文档明确「`html()` 返回的是不可信输入，渲染前必须清洗」 |
| **证书/主机名** | `serverName` 默认取 host；IP 连接时按 IP 校验；不提供跳过主机名校验的单独开关 |

**四条实现要求**：

1. **注入防线只有一处**：`LineChannel.writeLine` + `EmailAddress` 构造器。不要在协议层各处零散地 `replace("\r", "")`——那会漏。
2. **`Secret` 不可逆**：不提供 `value()`；只提供 `use((String) -> T)`，调用方用完即弃。异常里只出现 `<redacted>`。
3. **安全默认值不可被配置悄悄覆盖**：`TrustAll`、`allowPlaintextAuth`、`requireEncryption=false` 都要求显式调用 builder 方法，不从环境变量/配置文件隐式读取。
4. **异常也要脱敏**：`MailProtocolException.command` 在 `AUTH` / `PASS` / `LOGIN` 场景下替换为 `<redacted>`；`MailAuthException` 只保留机制名，不保留 challenge 或 response。

---

## 10. 错误处理

### 10.1 异常层次

```cangjie
public open class MailException <: Exception {
    public init(message: String)
    public init(message: String, caused: Exception)
}

public class MailIoException <: MailException {
    public let stage: IoStage          // Connect / Tls / Greeting / Read / Write / Timeout
}

public class MailProtocolException <: MailException {
    public let command: ?String
    public let reply: ?String
}

public class MailAuthException <: MailException {
    public let mechanism: String
    public let code: ?Int64
}

public class MailLimitException <: MailException {
    public let kind: LimitKind         // Header / Line / Parts / Depth / Body / Literal / Size
    public let limit: Int64
    public let actual: Int64
}

public class MimeException <: MailException {
    public let partPath: ?String
    public let offset: ?Int64
}

public class MailTlsException <: MailException

public enum IoStage {
    | Connect
    | Tls
    | Greeting
    | Read
    | Write
    | Timeout
}

public enum LimitKind {
    | Header
    | Line
    | Parts
    | Depth
    | Body
    | Literal
    | Size
}
```

### 10.2 场景映射

| 场景 | 异常 |
|---|---|
| DNS/连接失败 | `MailIoException(stage=Connect)` |
| TLS 握手/证书 | `MailTlsException` |
| 读超时 | `MailIoException(stage=Timeout)` |
| 服务器回复格式错误 | `MailProtocolException` |
| SMTP `535` / POP3 `-ERR [AUTH]` / IMAP `NO [AUTHENTICATIONFAILED]` | `MailAuthException` |
| 单个收件人 `550` | 不抛；进 `SendReport.rejected` |
| 全部收件人失败 | **不抛异常**，返回 `SendReport`（`rejected` 全满，`isCompleteSuccess()=false`） |
| 头部/正文超限 | `MailLimitException` |
| MIME 结构损坏（严格模式） | `MimeException` |
| 调用方在已关闭连接上操作 | `MailProtocolException("client is closed")` |

`send` 的约定：**只要拿到了服务器对整封邮件的最终回复就返回 `SendReport`**（包括部分失败）；只有「连接/协议/认证」层面的失败才抛异常。这样调用方可以用一个 `try` 包住网络问题，用 report 处理业务拒收。

### 10.3 回复码分类

| 协议 | 临时失败（可重试） | 永久失败 |
|---|---|---|
| SMTP | `421` `450` `451` `452` `4xx` | `5xx` |
| POP3 | `-ERR [SYS/TEMP]` `-ERR [IN-USE]` | `-ERR [AUTH]` `-ERR [SYS/PERM]` |
| IMAP | `NO [UNAVAILABLE]` `NO [SERVERBUG]` | `NO [AUTHENTICATIONFAILED]` `NO [TRYCREATE]` `BAD` |

POP3 的 `-ERR` 文本没有标准结构；优先解析 `[...]` response code（RFC 2449），没有就按文本关键字，最后默认「不可重试」。

---

## 11. 性能与内存

### 11.1 复杂度

| 操作 | 时间 | 内存 |
|---|---|---|
| SMTP 发信 | O(报文大小) | O(头部 + 缓冲区 + 流式正文块) |
| POP3 RETR | O(报文大小) | O(缓冲区) + 附件落盘 |
| IMAP FETCH 元数据 | O(响应行数) | O(单条 FETCH 的元数据) |
| IMAP FETCH BODY[] | O(literal) | O(缓冲区) + 落盘 |
| MIME 解析 | O(字节数)，boundary 扫描每字节常数次比较 | O(头部 + 深度 + 单块) |
| MIME 生成 | O(输出字节数) | O(头部 + 缓冲区) |

### 11.2 关键优化

| 点 | 做法 |
|---|---|
| 缓冲 | `BufferedInputStream` / `BufferedOutputStream` 8 KB；唯一例外是 STARTTLS 升级前的单字节读（3.2），升级后恢复缓冲 |
| 行解析 | 在字节缓冲上找 `\n`，不构造 `String` 再 `split` |
| 文本累积 | `f_base.StringGenerator`（`ArrayList<Byte>`，摊销 O(1)），不用 `String +` |
| base64 | 4 字符一组流式解码；不把整个编码串读进内存 |
| QP | 逐字节状态机；`=XX` 跨块时保留 1–2 字节残留 |
| boundary | 滚动窗口匹配，O(n)；不回溯、不正则 |
| 附件 | 超过 `spoolThreshold` 落临时文件；解析完直接 `FileBodySource` |
| IMAP | `BODY.PEEK[HEADER]` 预览；`BODY.PEEK[TEXT]<0.2048>` 取正文开头；避免 `FETCH BODY[]` 拉整个大附件 |
| POP3 | `TOP n 0` 取头部；`UIDL` 去重，避免重复下载 |
| 并发 | 每连接一线程；不共享可变状态，不需要锁 |

### 11.3 目标（待实测，不是承诺）

| 场景 | 目标 |
|---|---|
| 1 MB 纯文本邮件 MIME 解析 | < 30 ms（A53 级） |
| 1 MB 邮件 MIME 生成 | < 20 ms |
| 10 MB base64 附件解析 | < 150 ms，RSS 增量 < 5 MB |
| 1000 封头部（IMAP FETCH ENVELOPE） | < 2 s（取决于网络） |

> 这些是设计目标，M1/M3 结束时在目标机上实测；不达标就按 11.2 的项逐条查，而不是先加缓存。

---

## 12. 测试策略

### 12.1 分层

| 层 | 方式 | 覆盖 |
|---|---|---|
| 单元 | 纯函数 | base64 / QP / RFC 2047 / RFC 2231 / 地址 / 日期 / 头折行 / boundary 扫描 |
| 协议 | `ScriptedTransport`（内存字节脚本） | 逐字节断言命令与解析回复；多行、literal、dot-stuffing、错误码 |
| 集成 | 本机 `TcpServerSocket` 假服务器 | 真实 socket、超时、连接断开、TLS 握手 |
| TLS | 自签证书 + `TlsSocket.server` | 证书校验成功/失败、STARTTLS、主机名不匹配 |
| 互操作 | 手工/可选 | Postfix、Dovecot、Gmail、Outlook、QQ 邮箱、163 |

真实服务商差异（M3 互操作前先看这张表）：

| 服务商 | 端口 | 认证 | 注意 |
|---|---|---|---|
| Gmail | SMTP 587/465，IMAP 993 | OAuth2 或应用专用密码 | 基本认证已停用；`\All` / `\Sent` 等系统文件夹 |
| Microsoft 365 | SMTP 587，IMAP 993 | OAuth2 | 基本认证已停用；租户可能禁用 IMAP |
| QQ 邮箱 | SMTP 465/587，IMAP 993 | 授权码 | 不是登录密码；需在网页端开启 SMTP/IMAP 服务 |
| 163 / 126 | SMTP 465，IMAP 993 | 授权码 | **登录前必须发 `ID` 命令**，否则 `Unsafe Login`；`ID` 已列入 M3 |

**`ScriptedTransport` 是关键**：它让协议测试不依赖网络、不依赖外部服务器，且能精确断言「客户端到底写了什么字节」。每个协议至少覆盖：

- 正常流程；
- 多行回复（SMTP `250-`、POP3 `+OK` 多行、IMAP untagged 交错）；
- 错误码（4xx/5xx、`-ERR`、`NO`/`BAD`/`BYE`）；
- 超长行 / 截断 / 提前 EOF；
- 每次只读 1 字节的慢速流（暴露缓冲与状态机 bug）。

### 12.2 MIME 语料

必须包含的真实世界样本（可脱敏后入库）：

| 样本 | 验证点 |
|---|---|
| Gmail 的 `multipart/alternative` + `multipart/related` | 嵌套、CID、HTML/plain 选择 |
| Outlook 的 `multipart/mixed` + `winmail.dat` | `application/ms-tnef` 作为普通附件 |
| 中文邮件 `charset=gb2312` 实际 GBK | 别名与回退链 |
| 主题被拆成多个 encoded-word | 相邻 encoded-word 空白丢弃 |
| 附件名 `filename*=UTF-8''...` + 续行 | RFC 2231 |
| 旧客户端在参数里用 RFC 2047 | 兼容解码 |
| `message/rfc822` 转发 | 嵌套邮件 |
| 缺失结束 boundary | 宽松/严格两种模式 |
| base64 正文含空格/换行/缺 padding | 解码容错 |
| QP 正文含软换行、行尾空格、`=3D` | 编解码往返 |
| 8bit 正文 + 无 `8BITMIME` | 发送时强制 QP/base64 |
| 超长头（单行 10 KB） | 上限与错误 |
| 10 层嵌套 multipart | 深度限制 |

### 12.3 协议用例

**SMTP**：

| 用例 | 断言 |
|---|---|
| EHLO 多行 | 能力表完整，`SIZE`/`AUTH` 解析正确 |
| STARTTLS 后重新 EHLO | 第二次 EHLO 的能力生效；未重新 EHLO 的 AUTH 被拒绝 |
| 服务器不广告 STARTTLS | 配置 `StartTls` 时抛错，**不发明文** |
| AUTH PLAIN/LOGIN/CRAM-MD5/XOAUTH2 | 逐字节断言 base64；失败码映射 |
| 部分 RCPT 被拒（BestEffort） | 已接受的收到正文；report 正确 |
| 部分 RCPT 被拒（AllOrNothing） | 不进入 DATA；无邮件投递 |
| 全部 RCPT 被拒 | 不写正文；RSET |
| PIPELINING | 命令批量写出；回复按序消费；不串位 |
| dot-stuffing | 行首 `.` 变 `..`；空正文；跨块边界 |
| SIZE 超限 | 预检失败或 552 映射 |
| 8BITMIME 缺失 | 正文被 QP/base64 编码 |
| SMTPUTF8 缺失 + 非 ASCII 地址 | 抛错 |
| Bcc | 报文中无 `Bcc` 头 |
| 421 中途断开 | 异常 + 连接关闭 |

**POP3**：

| 用例 | 断言 |
|---|---|
| greeting 带 APOP timestamp | APOP 摘要正确 |
| `LIST` / `UIDL` 单条与多条 | 解析正确 |
| `RETR` 流式 | 字节与样本一致；dot-unstuffing 正确 |
| `TOP n` | 只取头部 + n 行 |
| `DELE` + `QUIT` | 删除提交 |
| `DELE` + `close()` | 删除不提交 |
| `-ERR [AUTH]` | `MailAuthException` |
| 超长正文行 | 不因行上限失败 |

**IMAP**：

| 用例 | 断言 |
|---|---|
| tagged / untagged / continuation 交错 | 命令结果不被 untagged 污染 |
| literal `{n}` 同步 | 发送 `+` 前不写数据 |
| literal `{n+}` | 直接写，不等待 |
| `FETCH BODY[]` 大 literal | 内存恒定；内容正确 |
| `FETCH BODY[HEADER.FIELDS (FROM TO)]` | section 键解析正确 |
| `BODYSTRUCTURE` | 嵌套结构解析正确 |
| `SEARCH` | 条件编码正确；结果解析 |
| `STORE` / `EXPUNGE` | flags 更新；序号移动处理 |
| `APPEND` | 大小精确；`APPENDUID` 解析 |
| `IDLE` | 25 分钟重发；`DONE` 正确；事件队列 |
| modified UTF-7 | 中文邮箱名往返 |
| `BYE` | 连接关闭；当前命令失败 |
| 1 字节读 | 所有解析器不依赖「一次读满一行」 |

### 12.4 恶意样本

| 样本 | 期望 |
|---|---|
| 头部注入 `Subject: x\r\nBcc: victim` | 构造/发送时抛异常 |
| 地址注入 `a@b>\r\nRCPT TO:<c@d>` | 抛异常 |
| 100 层 multipart | `MailLimitException(Depth)` |
| 10 万个 part | `MailLimitException(Parts)` |
| 100 MB literal | `MailLimitException(Literal)`，断开 |
| 单行 1 MB 头 | `MailLimitException(Header)` |
| base64 炸弹（编码后 10 MB，解码后 7.5 MB） | 按 `maxBodyBytes` 中断 |
| 递归 `message/rfc822` | 深度限制 |
| 伪造 `Content-Type: multipart/...; boundary=` 超长 | 拒绝/警告 |
| POP3 正文含 `.\r\n` 行 | 正确 unstuff，不提前结束 |
| SMTP 正文含 `\n.\n` 裸 LF | 客户端只写 CRLF，不受影响 |

### 12.5 验收门槛

| Gate | 标准 |
|---|---|
| G1 | 所有单元测试通过；QP/base64/RFC 2047 往返 100% |
| G2 | 三协议正常流程 + 错误流程脚本测试全过 |
| G3 | 1 字节读/写压力测试全过（无死锁、无越界） |
| G4 | 10 MB 附件解析 RSS 增量 < 10 MB |
| G5 | 头部注入、地址注入、literal 炸弹全部被拒绝 |
| G6 | 与至少两个真实服务器（Postfix/Dovecot）手工互操作通过 |

---

## 13. 实施顺序

### 13.1 里程碑

| 里程碑 | 范围 | 出口标准 |
|---|---|---|
| **M0** | 模块骨架、`MailConnection`、`LineChannel`、`DotStuff`、`ScriptedTransport`、异常层次、`Secret` | 能连本机假服务器；1 字节读写测试通过；OHOS 上 TLS 连通性有结论 |
| **M1** | 消息模型、地址/日期/头、MIME 解析/生成、SMTP 客户端 | 能发纯文本 + HTML + 附件；MIME 语料全过；注入测试全过 |
| **M2** | POP3 客户端 | 能登录、列表、UIDL、流式 RETR、TOP、DELE/QUIT；大邮件内存恒定 |
| **M3** | IMAP 核心：登录、SELECT、LIST、FETCH、SEARCH、STORE、COPY、EXPUNGE、APPEND、ID（163/126 必需）、UIDPLUS、UNSELECT | 能读 INBOX、按条件搜索、取整封邮件、标记已读、追加到已发送 |
| **M4** | IMAP 扩展：IDLE、MOVE、SPECIAL-USE、NAMESPACE、UTF8=ACCEPT、CONDSTORE/QRESYNC、SORT/THREAD；加固与性能 | IDLE 事件可用；扩展能力协商正确；性能目标达标 |

### 13.2 阶段拆解

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P-0** | 确认 `stdx.net.tls` 在目标机可用；确认 `charset4cj` 的 GBK/GB18030 解码正确；确认 `stdx.encoding.base64` 的容错行为 | 三个最小用例可跑；不通过就调整依赖策略 |
| **P0** | `LineChannel` + `DotStuff` + 假服务器 | SMTP/POP3 的行读写逐字节正确；跨块 dot-stuffing 正确 |
| **P1** | 头部、地址、日期、`ContentType` | RFC 5322 语料解析正确；地址往返 |
| **P2** | base64 / QP / RFC 2047 / RFC 2231 | 单元测试全过；往返幂等 |
| **P3** | multipart 解析 + `BodySource` / `Spool` | 嵌套样本、缺失 boundary、大附件内存恒定 |
| **P4** | `MimeWriter` | 生成的报文可被 `MimeParser` 读回；头部折行合法 |
| **P5** | SMTP：EHLO/STARTTLS/AUTH/MAIL/RCPT/DATA | 脚本测试 + 真实服务器发信 |
| **P6** | POP3 | 脚本测试 + 真实服务器收信 |
| **P7** | IMAP 核心（含 `ID`、`UIDPLUS`、`UNSELECT`） | 脚本测试 + Dovecot/163 互操作 |
| **P8** | IMAP 扩展（IDLE / MOVE / SPECIAL-USE / UTF8=ACCEPT）+ 性能 | IDLE 事件可用；扩展能力协商正确；性能目标达标 |

**为什么 SMTP 在 POP3/IMAP 之前**：发信是三件事里最有确定价值、协议状态机最简单、最容易用真实服务器验证的；先把 MIME + SMTP 打通，能尽早暴露「生成器写出的报文服务器不收」这类问题。POP3 次之，IMAP 最后——它的响应模型最复杂。

**P-0 是硬门槛**：TLS 与字符集是两条外部依赖，任何一条不通都会推翻上层设计；先花半天验证，比写到 M3 再发现好。

### 13.3 模块接入

- 在根 `cjpm.toml` 增加 `"fountain::f_email" = {path = "./f_email"}`；
- `f_email/cjpm.toml` 声明 1.4 的依赖与 `output-type = "dynamic"`；
- README / 模块依赖图在 M1 完成后更新（`docs/模块依赖图` 的脚本会自动抽取）。

---

## 14. 开放问题

| 问题 | 现状 | 建议 |
|---|---|---|
| 是否做 SMTP 接收服务端 | 不做 | 如果未来要做，另立 `f_email.server`，复用 MIME 与 `LineChannel` |
| SCRAM-SHA-256 | M4 之后 | 现代认证首选；需要 `stdx.crypto` 的 PBKDF2/HMAC，先确认可用 |
| 代理（SOCKS5 / HTTP CONNECT） | 不做 | `TransportFactory` 已预留；企业环境有需求 |
| IDN / punycode | 不做 | 非 ASCII 域名目前要求 `SMTPUTF8`；国际化域名可在应用层转 punycode |
| OAuth2 刷新 | 不做 | token 生命周期由调用方管理；库只负责用 token 认证 |
| S/MIME / PGP | 不做 | 需要证书链、签名验证、解密；是独立模块 |
| IMAP CONDSTORE/QRESYNC | M4 可选 | 大量邮箱同步时价值高，但复杂度也高 |
| 连接池 | M4 可选 | 高并发发信时需要；M1 用「每线程一个客户端」 |
| 邮件大小默认上限 | 0（不限） | 是否给一个 25 MB 的默认值？需要产品决策 |
| 严格模式的默认值 | `false` | 真实邮件太脏；严格模式给需要确定性的场景 |

---

## 附录 A：协议速查

| 项 | SMTP | POP3 | IMAP4rev1 |
|---|---|---|---|
| 明文端口 | 25 / 587 | 110 | 143 |
| 隐式 TLS 端口 | 465 | 995 | 993 |
| 行结束 | CRLF | CRLF | CRLF |
| 控制行上限 | 512（命令/回复） | 512 | 8 KB（实现上限） |
| 正文行上限 | 1000（含 CRLF） | 无硬限制（控制行 512） | literal 长度前缀 |
| 多行机制 | `250-` 续行 | `.` 终止 | literal / 括号列表 |
| 状态 | 无会话状态 | AUTHORIZATION / TRANSACTION / UPDATE | 未认证 / 已认证 / 已选择 |
| 删除语义 | 无 | `DELE` + `QUIT` | `\Deleted` + `EXPUNGE` |
| 搜索 | 无 | 无 | `SEARCH` |
| 推送 | 无 | 无 | `IDLE`（扩展） |
| 典型用途 | 发信 | 简单收信 | 完整邮箱操作 |

## 附录 B：关键边界用例清单

实现时逐条对照，缺一不可：

1. SMTP 回复 `250-` 多行，最后一行 `250 `；中间行没有空格。
2. SMTP `DATA` 正文第一行就是 `.`；最后一行没有 CRLF；空正文。
3. SMTP 部分收件人 550；全部 550；MAIL 550；DATA 552。
4. SMTP `AUTH LOGIN` 的 334 提示是 base64 的 `Username:` / `Password:`；有的服务器提示不同，不要按固定字符串判断。
5. SMTP `AUTH XOAUTH2` 失败后收到 334 JSON，必须发空行再读 535。
6. POP3 greeting 带 `<...>`；`APOP` 摘要；`STLS` 后 `CAPA` 变化。
7. POP3 `RETR` 正文含 `..` 行、`.` 行、超长行；`TOP 1 0` 只有头部。
8. POP3 `QUIT` 失败（服务器拒绝）时删除是否生效——以服务器回复为准。
9. IMAP 命令 tag 大小写；untagged 在 tagged 之前/之后到达。
10. IMAP literal `{0}`（空）、`{n+}`、跨缓冲区。
11. IMAP `BODY[HEADER.FIELDS (FROM TO)]` 的 section 键带空格与括号。
12. IMAP `BODY[]<0.1024>` 的部分获取与响应键 `<0>`。
13. IMAP `EXPUNGE` 后序号移动；`COPYUID` 的 UID 映射。
14. IMAP `APPEND` 的日期格式与 RFC 5322 不同。
15. IMAP modified UTF-7 的 `&-`、`&` 结尾、非法序列。
16. MIME `Content-Type` 参数含分号/引号/注释；boundary 含特殊字符。
17. MIME 头部折行跨 3 行；折行处是 encoded-word 中间（非法，但真实存在）。
18. RFC 2047 相邻 encoded-word；普通文本与 encoded-word 混排的空白。
19. RFC 2231 续行乱序、缺 `*`、charset 未知。
20. QP 软换行跨块；`=` 在块边界；行尾空格。
21. base64 缺 padding、含空白、含非法字符。
22. 字符集声明 `gb2312` 实际 GBK；声明 `utf-8` 实际 GBK；未知字符集。
23. 附件名含 `/`、`..`、NUL；只作为元数据，不用于路径。
24. 邮件正文是 `message/rfc822`，里面还有 `message/rfc822`（深度限制）。
25. 头部 `Bcc` 在发送时被删除，但 `MimeWriter` 单独使用时保留。

---

## 附录 C：与现有模块的对照

| 现有能力 | f_email 的处理 |
|---|---|
| `f_http.ContentDisposition` | 不复用；邮件参数规则是 RFC 2231/2047，不是 RFC 6266 |
| `f_http.MediaType` | 不复用；邮件 `Content-Type` 需要 boundary/charset 语义与 multipart 绑定 |
| `f_data.JsonValue` | 不用于 MIME；MIME 不是 JSON，且需要流式 |
| `f_io.ByteBuffer` | 内部可用；公开 API 用 `InputStream` / `OutputStream` |
| `f_net` 心跳/重连 | 不适用；邮件协议没有心跳，IMAP 有 IDLE |
| `f_log` | 使用；trace 默认脱敏 |
| `f_config` | 不直接依赖；配置读取由应用完成，避免库绑定配置键 |

---

*本文档为设计稿，API 签名在实现阶段可微调，但「客户端优先」的边界与开头的三条底线不变。*
