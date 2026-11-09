# `fountain::f_probe`

fprobe 的扩展契约模块：定义监控项（`ProbeAgent`）、告警渠道（`AlarmMessageChannel`）、
线程安全注册表与稳定错误码。第三方扩展只需依赖本模块即可编译动态库，无需引入 RPC、
邮件或 TUI 依赖。

## 契约

```cj
public interface ProbeAgent {
    prop kind: String          // 监控项类型，如 cpu / k8s
    prop host: String { get() { '' } }
    prop data: JsonObject      // 本次采集的数据
}

public interface AlarmMessageChannel {
    func send(message: String, receiver: Array<String>): Unit
    func receive(): String
    func replyConf(): String
    // 默认方法：承载 HTML 与附件，纯文本渠道自动退化为 send()
    func sendRich(message: String, html: String, attachments: Array<String>,
        receiver: Array<String>): Unit
}
```

## 注册

| API | 说明 |
| --- | --- |
| `ProbeRegistry.registerAgent(kind, factory)` | 注册监控项工厂；`kind` 全局唯一 |
| `ProbeRegistry.agents()` | 当前全部 `kind` 的快照 |
| `ProbeRegistry.agent(kind)` | 按 `kind` 取工厂 |
| `AlarmChannelRegistry.register(name, factory)` | 注册告警渠道；`name` 全局唯一 |

注册通常发生在动态库加载期，因此登记的是工厂而不是实例；重名一律抛
`ProbeException(DUPLICATE)`，内置项先注册，扩展无法覆盖。

## 错误码

`ProbeErrorCode`：`CONFIG`、`COLLECT`、`LOAD`、`DUPLICATE`、`UNSUPPORTED`。
扩展抛出的 `ProbeException` 会被 agent/supervisor 记录为对应监控项的 `error`，
不会中断其它监控项。

## 文档

- 契约说明：[`doc/contract.md`](doc/contract.md)
- 扩展开发指南：[`doc/extension-guide.md`](doc/extension-guide.md)
