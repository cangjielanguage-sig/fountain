# 变更提案：add-f-email-client

## Why

fountain 目前没有任何邮件能力。服务端业务（构建失败告警、验证码、工单通知、报表投递）要发信，
只能起外部进程调 `sendmail`；要收信，只能把其它语言的 IMAP 客户端拉进链路。代价是编码不可控、
错误不可分类、附件必须整体进内存，而且这些代码都绕过了 fountain 的异常与日志约定。

`f_email` 的模块骨架（`f_email/cjpm.toml` + `f_email/src/email.cj`）已在仓库里，
但只有一个版本常量。本变更按 `f_email/doc/f_email设计文档.md` 把它填成一个可用的邮件**客户端**库：
SMTP 发信、POP3 简单收信、IMAP4rev1 完整邮箱操作，外加一套独立的 MIME 解析/生成实现。

三条贯穿全案的底线，后面每一条需求都从它们推导：

1. **发送严格、接收宽容** —— 写出的报文必须合法；读入尽量读懂，读不懂要有明确降级与告警。
2. **字节优先、流式优先** —— 不在未知字符集上先解码；附件不进内存。
3. **默认安全** —— 证书校验、凭据脱敏、CRLF 注入防线默认开启，放宽必须显式。

**客户端优先**是本次的范围定义：只做客户端。SMTP 接收服务端、IMAP/POP3 服务端不在本期，
未来若做，复用本变更的 MIME 与协议编解码，不推翻现有 API。

## What Changes

按能力切成六个新 capability，彼此单向依赖（transport ← message ← mime ← 三个协议客户端）：

- **`email-transport`** —— `MailConnection` / `LineChannel` / `DotStuff` / `TlsMode` / `MailTrace`。
  把 `std.net.TcpSocket` 与 `stdx.net.tls.TlsSocket` 的差异收敛到一个类里；行协议统一走字节通道，
  CRLF 注入防线只在这一处实现；超时折算成 deadline；`ScriptedTransport` 让协议测试不依赖网络。
- **`email-message`** —— `HeaderMap` / `EmailAddress` / `AddressList` / `MailDate` /
  `MailMessage` / `MimePart` / `BodySource` / `Envelope` / `Secret` / 异常层次。
  只描述"一封信是什么"，不碰 socket，也不做 MIME 编解码。
- **`email-mime`** —— `ContentType` / `ContentDisposition` / `TransferEncoding` /
  `EncodedWord` / `MimeParameter` / `MimeParser` / `MimeWriter` / `CharsetResolver`。
  multipart 递归、RFC 2047、RFC 2231、base64、quoted-printable、字符集回退链，
  以及 `parse`（建树）与 `walk`（不建树、分块回调）两种模式。
- **`email-smtp`** —— `SmtpClient` 与 builder：EHLO 能力协商、STARTTLS、四种 AUTH 机制、
  MAIL/RCPT/DATA 事务、PIPELINING、逐收件人 `SendReport`、Bcc 剥离。
- **`email-pop3`** —— `Pop3Client`：USER/PASS、APOP、AUTH、CAPA/STLS、
  LIST/UIDL、流式 `RETR`、`TOP`、`DELE`/`QUIT` 的删除提交语义。
- **`email-imap`** —— `ImapClient`：tagged/untagged/continuation 分发、literal 流式、
  SELECT/EXAMINE/LIST/STATUS、FETCH/FETCH BODYSTRUCTURE、SEARCH/STORE/COPY/EXPUNGE、
  APPEND、`ID`（163/126 登录前必需）、UIDPLUS、UNSELECT、modified UTF-7。

同时改动的工程文件：

- `f_email/cjpm.toml`：补 `stdx` 的 `bin-dependencies` 路径说明与依赖注释（依赖项本身已在）。
- `f_email/README.md`：里程碑进度从"骨架"更新为实际已实现范围。

## 不在本次范围（显式排除）

| 项 | 原因 |
|---|---|
| SMTP 接收服务端、IMAP/POP3 服务端 | 需要 MTA 队列、存储引擎、并发会话、配额，是另一个量级的产品 |
| MTA 队列与持久化重试 | 客户端只报告"这一次投递的结果"；`250` 可能已在断网前到达服务器，库内自动重试会造成重复投递 |
| IMAP `IDLE` / `MOVE` / `SPECIAL-USE` / `NAMESPACE` / `UTF8=ACCEPT` / `CONDSTORE` | 设计文档 M4，另立变更；本期只保证能力协商能正确解析并暴露 `supportsXxx` |
| S/MIME、PGP、DKIM/SPF/DMARC | `multipart/signed`、`application/pkcs7-mime` 按普通 MIME 解析，不验签不解密 |
| HTML 渲染与 XSS 清洗 | `html()` 返回不可信原文，清洗是调用方职责 |
| 代理（SOCKS5 / HTTP CONNECT）、连接池 | `TransportFactory` 预留接口，本期只提供 `SocketTransportFactory` |
| OAuth2 token 获取与刷新 | 只接受调用方给的 access token |
| IDN / punycode | 非 ASCII 地址要求服务器支持 `SMTPUTF8`，否则明确报错，不做隐式转换 |

## Impact

**受影响规格**（全部为新增）：

- `specs/email-transport/spec.md`
- `specs/email-message/spec.md`
- `specs/email-mime/spec.md`
- `specs/email-smtp/spec.md`
- `specs/email-pop3/spec.md`
- `specs/email-imap/spec.md`

**受影响代码**：`f_email/src/**`（新增约 30 个源文件与同等数量的 `_test.cj`），
`f_email/cjpm.toml`、`f_email/README.md`。根 `cjpm.toml` 已声明 `fountain::f_email`，无需改动。

**新增外部依赖**：`stdx.net.tls`、`stdx.encoding.base64`、`stdx.crypto.digest`、
`stdx.crypto.common`/`x509`。这些是仓颉标准扩展库，不改 `cjpm.toml` 的 `[dependencies]`，
但要求构建环境设置 `CANGJIE_STDX_DYNAMIC_PATH`。

**风险**：

| 风险 | 影响 | 缓解 |
|---|---|---|
| `stdx.net.tls` 在 OHOS 目标机不可用 | 隐式 TLS / STARTTLS 全部失效 | P-0 阶段先在目标机跑"连 465 + 校验证书"用例；不通则退回"调用方注入 `TlsClientConfig` + 自签 CA"，**不默认 `TrustAll`** |
| `charset4cj` 的 GBK/GB18030 解码有偏差 | 中文邮件乱码 | P-0 用真实中文样本验证；不足处由 `CharsetResolver` 的别名表与回退链兜底 |
| 真实服务商行为差异（QQ/163/Gmail） | 互操作失败 | 163/126 的 `ID` 命令已列入本期（登录前必需）；互操作按 G6 手工验证 |
| 单个变更体量偏大 | 评审与回滚粒度粗 | 任务按 M0→M3 分阶段，每个阶段独立可编译、可测试、可单独提交 |
