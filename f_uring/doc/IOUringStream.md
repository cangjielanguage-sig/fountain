# IOUringStream

> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class IOUringStream <: IOStream & Resource
```

包: `fountain::f_io`

基于 io_uring 的 IOStream 实现（双 ring 架构）。Write 异步提交后立即返回，Read 同线程 submit + waitCQE。可选注册缓冲区模式。

## 构造函数

| 签名 | 说明 |
|------|------|
| `init(fd: Int32, entries: UInt32, flags!: UInt32 = 0, fixedBufCount!: UInt32 = 0, fixedBufSize!: UInt32 = 4096)` | 完整参数，支持注册缓冲区 |
| `init(fd: Int32)` | 简化初始化（64 entries，无注册缓冲区） |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | 读取数据，无数据阻塞，有数据立即返回 |
| write | `func write(buffer: Array<Byte>): Unit` | 写入数据，立即返回 |
| flush | `func flush(): Unit` | 无操作（write 已立即返回） |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | 停止收割线程，注销缓冲区，关闭 ring |
