# `fountain::f_probe`

fprobe 的扩展契约模块：定义监控项（`ProbeAgent`）、告警渠道（`AlarmMessageChannel`）、
线程安全注册表与稳定错误码。第三方扩展只需依赖本模块即可编译动态库，无需引入 RPC、
邮件或 TUI 依赖。

- 契约说明：[`doc/contract.md`](doc/contract.md)
- 扩展开发指南：[`doc/extension-guide.md`](doc/extension-guide.md)

> 本模块目前处于实现中，接口以 `src/` 下的公开声明为准。
