# f_email

Email client module: SMTP / POP3 / IMAP4rev1 + MIME parsing and generation.

- Package: `fountain::f_email`
- Dependencies: `f_base`, `f_io`, `f_log`, `f_random`, `charset4cj`, `stdx` (tls / base64 / digest / x509)
- Design document: [`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## Status

Module skeleton only. APIs are implemented incrementally following the design milestones (M0 → M1 → M2 → M3 → M4).

## STDX dependency

Set `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`.
