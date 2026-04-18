# DummyInputStream

```cj
public class DummyInputStream <: InputStream & Resource
```

空输入流，用于测试或占位。

## 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | read 时抛异常 |
| `SILENCE` | read 时返回 0 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |
