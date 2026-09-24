# QueueInputStream / NonblockingQueueStream / BlockingQueueStream

## QueueInputStream

```cj
sealed abstract class QueueInputStream <: InputStream
```

队列式输入流，支持添加多个 InputStream 顺序读取。

### 构造函数

`init(size: Int64, closeOnEnd!: Bool = true)`

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| add | `func add(stream: InputStream): Unit` | 添加输入流 |
| add | `func add(bytes: Array<Byte>): Unit` | 添加字节（包装为 ByteBuffer） |

## NonblockingQueueStream

```cj
public class NonblockingQueueStream <: QueueInputStream
```

非阻塞读取，无数据时返回 0。

## BlockingQueueStream

```cj
public class BlockingQueueStream <: QueueInputStream
```

阻塞读取，等待数据可用。
