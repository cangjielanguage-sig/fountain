# DummyOutputStream

```cj
public class DummyOutputStream <: OutputStream & Resource
```

空输出流，用于测试或占位。

## 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | write/flush 时抛异常 |
| `SILENCE` | 静默忽略 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| write | `func write(buffer: Array<Byte>): Unit` | 取决于 throwing 标志 |
| flush | `func flush(): Unit` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |
