# f_email

邮件客户端模块：SMTP / POP3 / IMAP4rev1 + MIME 解析与生成。

- 包名：`fountain::f_email`（另有 `f_email.transport` / `f_email.mime` / `f_email.smtp` / `f_email.pop3` / `f_email.imap`）
- 依赖：`f_base`、`f_io`、`f_log`、`f_random`、`charset4cj`、`stdx`（tls / base64 / digest / x509）
- 设计文档：[`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## 当前状态

按里程碑推进（M0 → M1 → M2 → M3 → M4）。

- **M0 传输骨架**：`MailConnection` / `LineChannel` / `DotStuff` / `MailTrace` /
  `TransportFactory`（含脚本化测试传输）。
- **M1 消息模型与 MIME**：`HeaderMap`、地址/日期、`CharsetResolver`、base64/QP、
  RFC 2047/2231、`MimePart`/`MailMessage`、流式 `MimeParser` 与 `MimeWriter`。
- **M1-e SMTP**：`SmtpClient` 建连/EHLO/STARTTLS/AUTH 与投递事务、PIPELINING、
  逐收件人 `SendReport`、Bcc 剥离、SIZE 预检。

POP3、IMAP 与 M4 扩展尚未实现，进度见 `openspec/changes/add-f-email-client/tasks.md`。

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
