# f_email

邮件客户端模块：SMTP / POP3 / IMAP4rev1 + MIME 解析与生成。

- 包名：`fountain::f_email`（另有 `f_email.transport` / `f_email.mime` / `f_email.smtp` / `f_email.pop3` / `f_email.imap`）
- 依赖：`f_base`、`f_io`、`f_log`、`f_random`、`charset4cj`、`stdx`（tls / base64 / digest / x509）
- 设计文档：[`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## 当前状态

按里程碑推进（M0 → M4），代码与单元测试同步落地。

- **M0 传输骨架**：`MailConnection` / `LineChannel` / `DotStuff` / `MailTrace` /
  `TransportFactory`（含脚本化测试传输）。
- **M1 消息模型与 MIME**：`HeaderMap`、地址/日期、`CharsetResolver`、base64/QP、
  RFC 2047/2231、`MimePart`/`MailMessage`、流式 `MimeParser` 与 `MimeWriter`。
- **M1-e SMTP**：`SmtpClient` 建连/EHLO/STARTTLS/AUTH（PLAIN / LOGIN / CRAM-MD5 / XOAUTH2）、
  投递事务、PIPELINING、逐收件人 `SendReport`、Bcc 剥离、SIZE 预检、8BITMIME / SMTPUTF8。
- **M2 POP3**：`Pop3Client`（`CAPA` / `STLS`、`USER`+`PASS` / `APOP` / `AUTH PLAIN`+`LOGIN`、
  `STAT`/`LIST`/`UIDL`、流式 `RETR`/`TOP`、`DELE`/`RSET`/`QUIT`），`-ERR` 响应码分类。
- **M3 IMAP 核心**：tag 驱动的命令框架、modified UTF-7、token 解析、`SELECT`/`EXAMINE`/
  `STATUS`/`LIST`/`LSUB`、`FETCH`（含 literal 的流式与内存两路）、`BODYSTRUCTURE`、
  `ENVELOPE`、`INTERNALDATE`、`SEARCH`、`STORE`/`COPY`/`EXPUNGE`、`APPEND`、`LOGOUT`。
- **M4 IMAP 扩展七组**：`ENABLE` 协商、`IDLE`（读线程 + 有界队列 + 25 分钟重建）、
  `MOVE`（含非原子回退）、`SPECIAL-USE`、`NAMESPACE`、`UTF8=ACCEPT`、
  `CONDSTORE`/`QRESYNC`、`SORT`/`THREAD`。

进度与逐条验收见 `openspec/changes/add-f-email-client/tasks.md`。

## 用法

### 发信（SMTP）

```cangjie
let client = SmtpClient.builder("smtp.example.com", port: 465)
    .tls(TlsMode.Implicit)
    .auth(SmtpAuthMechanism.Plain, "user@example.com", Secret.of("password"))
    .build()

let message = MailMessage.builder()
    .from("user@example.com")
    .to("friend@example.com")
    .subject("你好")
    .text("正文")
    .attach("report.pdf", FileBodySource(Path("report.pdf")))
    .build()

let report = client.send(message)   // 部分拒收不抛异常，看 report.rejected
client.close()
```

### 收信（POP3）

```cangjie
let client = Pop3Client.builder("pop.example.com", port: 995).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
let list = client.list()                 // 每封的序号与大小
let message = client.retrMessage(1)      // RETR 直接交给 MimeParser
let text = message.text()
client.quit()                            // 删除标记只在 QUIT 的 +OK 后提交
```

### 读信（IMAP）

```cangjie
let client = ImapClient.builder("imap.example.com", port: 993).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
client.select("INBOX")

// 只要头部：不置 \Seen
let heads = client.fetch(
    SequenceSet.range(1, 10),
    [FetchItem.uid(), FetchItem.envelope(), FetchItem.flags()]
)

// 只要未读里来自某个人的
let ids = client.uidSearch(
    SearchCriteria.unseen().andWith(SearchCriteria.from("boss@example.com"))
)
```

### IDLE（服务器推送）

```cangjie
let enabled = ImapEnable(client).enableUtf8Accept()
let session = ImapIdle(client).start()      // 默认 25 分钟自动 DONE 后重建
while (true) {
    match (session.nextEvent(timeout: Duration.second * 30)) {
        case Some(event) => println("${event.kind} ${event.sequence}")
        case None => ()                     // 超时不是错误，连接仍然有效
    }
}
session.close()                             // 发 DONE 后收尾
```

### MIME 编解码

```cangjie
// 解析：解码后 ≤ 256 KB 的文本进内存，其余落临时文件（权限 0600）
let message = MimeParser.parse(input, options: MimeParseOptions(strict: false))
let attachments = message.attachments()

// 生成：target 支持 8BITMIME 时 allow8Bit=true
MimeWriter(target, options: MimeWriteOptions(allow8Bit: true)).write(message)
```

## 环境要求

构建前必须设置 `CANGJIE_STDX_DYNAMIC_PATH` 指向 stdx 动态库目录：

```shell
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

### P-0 依赖验证结论（2026-10-28，Linux aarch64）

| 项 | 结论 |
|---|---|
| `stdx.net.tls` | `TlsSocket.client` 连接 `smtp.163.com:465` 成功，协商到 TLS 1.3 + `TLS_AES_256_GCM_SHA384`，系统 CA 校验链路（3 张证书）通过，默认 `CertificateVerifyMode.Default` 可用。**OHOS 目标机未验证**（无设备），按设计保留"调用方注入 `TlsClientConfig` + 自签 CA"的退路，不默认 `TrustAll` |
| `charset4cj` 1.0.5 | GBK / GB18030 / BIG5 / WINDOWS_1252 解码中文样本均正确（`中文测试`、`中文測試`、`éÿ`） |
| `stdx.encoding.base64` | **不容错**：缺 padding（`SGVsbG8`）与含空白（`SGVs bG8=\n`）都返回 `None`，非法字符同样 `None`。因此 `mime/Base64Codec` 必须自行去空白、补 padding、按宽松/严格两态处理非法字符 |
| `stdx.crypto.digest` | `MD5` / `HMAC(key, HashType.MD5)` + `toHexString` 输出**小写**十六进制，可直接用于 CRAM-MD5 与 APOP 摘要 |

验证方式：一次性探针测试（已从仓库移除），逐项断言/打印上表结果。

## 已知未验证项

- OHOS 目标机上的 TLS 与 `Spool` 目录（无设备）。
- Dovecot / 163 的扩展错误矩阵（QQ 邮箱的 IMAP/SMTP 往返已验证通过）。
- TLS 自签证书的自动化用例（当前由 G6 与 P-0 的手工验证覆盖）。
