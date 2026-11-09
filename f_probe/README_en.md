# `fountain::f_probe`

The extension contract module for fprobe: it defines probe agents (`ProbeAgent`), alarm
message channels (`AlarmMessageChannel`), thread-safe registries and stable error codes.
A third-party extension depends only on this module to build a dynamic library, without
pulling in RPC, mail or TUI dependencies.

## Contracts

```cj
public interface ProbeAgent {
    prop kind: String          // metric kind, e.g. cpu / k8s
    prop host: String { get() { '' } }
    prop data: JsonObject      // data collected in this round
}

public interface AlarmMessageChannel {
    func send(message: String, receiver: Array<String>): Unit
    func receive(): String
    func replyConf(): String
    // default method: carries HTML and attachments; text-only channels degrade to send()
    func sendRich(message: String, html: String, attachments: Array<String>,
        receiver: Array<String>): Unit
}
```

## Registration

| API | Description |
| --- | --- |
| `ProbeRegistry.registerAgent(kind, factory)` | register a probe factory; `kind` is unique |
| `ProbeRegistry.agents()` | snapshot of all registered kinds |
| `ProbeRegistry.agent(kind)` | factory for a kind |
| `AlarmChannelRegistry.register(name, factory)` | register an alarm channel; `name` is unique |

Registration happens while a dynamic library is loaded, so factories are stored instead of
instances. Duplicate names raise `ProbeException(DUPLICATE)`; built-ins register first, so
extensions cannot override them.

## Error codes

`ProbeErrorCode`: `CONFIG`, `COLLECT`, `LOAD`, `DUPLICATE`, `UNSUPPORTED`.
A `ProbeException` from an extension is recorded as that metric's `error` and never
interrupts other metrics.

## Documentation

- Contract reference: [`doc/contract.md`](doc/contract.md)
- Extension guide: [`doc/extension-guide.md`](doc/extension-guide.md)
