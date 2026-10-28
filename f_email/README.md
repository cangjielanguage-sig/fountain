# f_email

邮件客户端模块：SMTP / POP3 / IMAP4rev1 + MIME 解析与生成。

- 包名：`fountain::f_email`
- 依赖：`f_base`、`f_io`、`f_log`、`f_random`、`charset4cj`、`stdx`（tls / base64 / digest / x509）
- 设计文档：[`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## 当前状态

模块骨架已建立，具体 API 按设计文档的里程碑逐步实现（M0 → M1 → M2 → M3 → M4）。

## STDX 依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`
