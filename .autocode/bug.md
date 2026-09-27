# Bug 分析报告：frpcdemo 错误日志成因（最终版 v2）

- 日期：2026-09-27
- 复现：`cd frpcdemo && ./boot.sh build && ./boot.sh runServer 1203 127.0.0.1:1203`
  （注意：`runServer 1203 127.0.0.1` 缺端口会启动即崩 —— `IPSocketAddress.tryParse('127.0.0.1')` → `NoneValueException`）

---

## 一、结论速览

日志里刷的三类异常（`Client reader error` / `tcp closed` / `TcpSocket.check`）**不是传输/编解码失败**，
而是「心跳判失败 → 拆链重连」的产物。成因为两个**耦合**缺陷：

- **缺陷 A（池项泄漏）**：`EncodedMessage.copy` 写失败时不归还编码用的池化缓冲 → 池在 ~2s 内从 1024 抽干 →
  之后所有 `message.encode()` 永久阻塞 → PING 发不出去 → 客户端 `pingTimeout=10ms` 超时 → 拆链重连 → 循环。
- **缺陷 B（流错位）**：一条消息被拆成多次 `socket.write`（先命令字节、再载荷）；**写中途失败会在 socket 上留下半条消息** →
  对端字节流解析错位 → `CodecException` → 垃圾 Data → `f_data` SIGSEGV。
- **缺陷 C（错位被继续传播）**：两侧 reader 遇到解码异常后**继续在已错位的流上解析**（服务端 `continue`、客户端不 break），
  使错位不会被及时断链，最终把垃圾 Data 送进 `JsonValue.from` 触发崩溃。

**三者关系**：A 的“写线程卡死”客观上**掩盖**了 B/C；**只修 A 会把“卡死”变成“崩溃”**（判定实验实证，见 §二）。

---

## 二、关键证据链

| 结论 | 证据 |
|---|---|
| 写线程卡在 `message.encode()` 取编码缓冲 | 零 I/O 分步计数：`sbExec=36` 而 `sbEnc=10`（26 个闭包没出来）；`sbCopy`/`sbDone` 跟随 `sbEnc` ⇒ `copy`/`flush` 不阻塞 |
| 卡住时**池是空的**（不是池的 bug） | 运行中非阻塞采样 `avail` 从 1024 → 0 且不再恢复；隔离 `@TestCase` 全通过（容量 4 借还 8 轮；容量 1024 + 32 并发 × 20 轮 = 640 次借还） |
| 泄漏发生在**写失败路径** | 给 `EncodedMessage.copy` 加 try/finally 归还池项后：`acq == acqOk` 全程成立、崩溃前心跳异常为零 |
| 写失败会留下半条消息 → 流错位 | 判定实验后进程以 `CodecException: current data head is 18, but sign mark is opposite to actual value, bytes: [217,35,56,141,...]` → `f_data` SIGSEGV 崩溃 |

判定实验中 `EncodedMessage.copy` 的写法（`if(!copied){ bytes.copy(to: DiscardSink(), ...) }`）**已还原**，仅作证据留存。

---

## 三、缺陷详述

### 缺陷 A：`EncodedMessage.copy` 失败路径不归还池项

```cj
// f_protocol/src/default/Message.cj
public func copy(to!: OutputStream, closeToOnEnd!: Bool = false): Unit {
    to.write([command])                                             // ① 抛（socket 已关闭）→ 池项从此无归还路径
    bytes.copy(to: to, closeToOnEnd: false, closeFromOnEnd: false)  // ② 关键：唯一归还入口
    to.flush()
}
```

`finish()` 返回 `ChainedBytesCopyTo(codec.inputs)`，所以 `bytes` 里持有 **`DefaultCodec.inputs` 的所有缓冲**。这些池项分属**两个池**：

| 池项 | 借自 | 归还点 |
|---|---|---|
| `BytesListOutputStream`（命令/普通字段） | `byteListOutputBuilder`（`ArrayListPool`，容量 1024） | `BytesListOutputStream.copy` 的 `finally{ pool.giveBack(list) }`（`f_pool/src/BytesListOutputStream.cj:32`） |
| `PooledBufferBytesCopyTo`（InputStream/File 载荷） | `bytesPool`（`ArrayPool<Byte>`，4096 字节缓冲） | `PooledBufferBytesCopyTo.copy` 的 `finally{ pool.giveBack(buf) }`（`f_pool/src/BytesCopier.cj:47-52`） |

⇒ ① 一抛，② 永不执行 ⇒ **两个池的项都可能不还**。池耗尽后 `DefaultCodec.lastBuffer()` 阻塞：

```cj
func getBuf(){
    let buf = byteListOutputBuilder.build().getOrThrow()   // ← ArrayListPool.get → KeyPool.get(timeout=Duration.Max) 永久忙等
}
```
（`f_pool/src/KeyPool.cj:342-350`：无空闲且已达 `totalSize` 时 `while(running.load())` 忙等，**不抛异常、不打日志**。）

### 缺陷 B：一条消息被拆成多次 `socket.write`，中途失败 → 流错位

```cj
to.write([command])      // ① 命令字节：一次 write
bytes.copy(to: to, ...)  // ② 载荷：一次或多次 write（InputStream/File 走分块流式）
```

若 ① 成功、② 失败，socket 上留下**半条消息**。对端按协议继续解析 ⇒ 字节流从此错位 ⇒ `CodecException` ⇒ 垃圾 Data ⇒ `f_data` SIGSEGV。

### 缺陷 C：解码异常后继续解析错位流

```cj
// 服务端 f_net/src/server/server.cj:147-150
} catch (e: Exception) { log.warn('error occurred on reading or executing', e); continue }   // ← continue！

// 客户端 f_net/src/client/client.cj:71-78
} catch (e: Exception) { log.error(e){...}; if(buffer.isClosed()){ break } }                // ← 未关闭时继续循环
```

对端一旦收到半条消息就会错位；此处 `continue`/不 break 让错位**被持续放大**，且（服务端）把垃圾 Data 送进 `RPCServer.execute → errorLog → JsonValue.from` → `f_data` SIGSEGV。

### 最初的引信

客户端 `Client.checkTimer` 的 `pingTimeout` 默认仅 **10ms**（`f_net/src/client/client.cj:266`，`ClientBuilder.pingTimeout_`）。
一次 PING 往返要跨 4 次线程唤醒 + 2 次 encode + 2 次 decode，一旦超过 10ms 就 `close()+new()`；
向**已被自己关掉的 socket** 写就会抛 → 同时触发 A/B/C。这也解释了“服务端 `checkTimer` 关掉后日志全空”（少了这条写失败来源）。

---

## 四、修复建议（含落点与代码草案）

> 原则：**B/C 决定“错误会不会扩散”，A 的归还保证决定“会不会卡死”。** 三者必须一起修。

### P0-1 修 B：让消息写入具备原子性（不缓冲，适用于任意消息）

`EncodedMessage.copy` / `SocketBuffer`：**任何一次写失败 → 立即关闭该连接**（宁可断链，也不留半条消息）。通用、零额外内存。

```cj
// f_protocol/src/default/Message.cj — EncodedMessage.copy
public func copy(to!: OutputStream, closeToOnEnd!: Bool = false): Unit {
    var ok = false
    try {
        to.write([command])
        bytes.copy(to: to, closeToOnEnd: false, closeFromOnEnd: false)
        to.flush()
        ok = true
    } finally {
        releaseBytes()                                        // 见 P0-2：无论如何都归还
        if (!ok && let r: Resource <- to && !r.isClosed()) {
            r.close()                                         // 写失败 → 断链，让对端见 EOF 而非半条消息
        }
    }
    if (closeToOnEnd && let r: Resource <- to && !r.isClosed()) { r.close() }
}
```

更彻底：把「一条消息一次 write、失败即 close」下沉到 `f_net.SocketBuffer`（帧级原子性），上层自动获益。

> ⚠️ **不要**把整条消息合并成一个字节数组再单次 write：`inputs` 可能含 `PooledBufferBytesCopyTo`（InputStream/File，`DefaultCodec.cj:494-501`），
> 其分块流式（4096 缓冲，`BytesCopier.cj:29-58`）就是为了**不把大载荷读进内存**。合并会让内存峰值 = 整条消息大小，**可能爆**。
> 合并只可作为**带 size 阈值的优化**（仅用于有界小消息，如 PING/ACK）。

### P0-2 修 A：显式定义池项所有权，保证必还（幂等）

1. `BytesListOutputStream` 加显式释放（幂等）：

```cj
// f_pool/src/BytesListOutputStream.cj
private var released = false            // 需与既有字段一起置于 struct/class 内
public func release(): Unit {
    if (released) { return }
    released = true
    list.clear()
    pool.giveBack(list)
}
public func copy(to!: OutputStream, ...): Unit {
    try { for(bytes in list){ to.write(bytes) } }
    finally { release() }               // 原 giveBack 收敛到这里
}
```

2. `DefaultCodec` 提供 `release()`：归还 `inputs` 中所有 `BytesListOutputStream` 与 `PooledBufferBytesCopyTo`（各自 `release()`/`copy(DiscardSink)`）。
3. **`EncodedMessage` 持有可释放句柄**（codec 或 `inputs` 列表），在 `finally` 调 `release()`。注意 `EncodedMessage` 是 `struct`，赋值会复制引用 ⇒ **`release()` 必须幂等**（防 double `giveBack`）。
4. 层间关系（务必记住）：`Message.encode()` = `DefaultCodec().encode(...).finish()`；`EncodedMessage.bytes` = `ChainedBytesCopyTo(codec.inputs)` ⇒ **池项持有者是 `EncodedMessage`**，生命周期横跨 `f_protocol` → `f_codec` → `f_pool`。

### P0-3 修 C：解码异常即断链

- 服务端 `server.cj:147-150`：`catch (e: Exception)` 里遇到解码类异常（`CodecException` / `IllegalArgumentException` / 任何非业务异常）应 `buffer.close(); break`，**不要 `continue`**。
- 客户端 `client.cj:71-78`：解码异常应 `buffer.close(); break`（而不是仅在 `isClosed()` 时 break）。
- `Message.decode` 在**消息中途读到 EOF** 时也应抛 `InputClosedException`（而不是让 `getOrThrow` 抛 `IllegalArgumentException`），便于上游统一识别。

### P1：取池项不要无限静默阻塞

- 结论：**“借出必还”是根治，但“无限阻塞”仍应改为有限超时 + 抛出/计数**（否则任何新漏还路径都会变成**无日志的永久挂起**，本次即是）。
- `DefaultCodec.lastBuffer()`：有限超时，取不到即抛出/计数。
- `f_pool/src/KeyPool.cj:342`：池满无空闲时快速失败（抛 `PoolException`）；`close()` 要唤醒所有等待者。

### P2：心跳与连接生命周期

- 客户端 `pingTimeout` 默认 **10ms** 过紧：放大并允许 N 次失败 + 指数退避再拆链。
- 服务端 `unavailableChecked` 默认 **3**：放宽，`count` 累加/清零语义与 PING 发送对齐。
- `server.cj:57`：取 `buffer.remoteAddress` 前加 `isClosed()` 守卫。
- `client.cj:71-77`：被自身 checkTimer 正常关闭时应降级为 DEBUG/WARN。
- `server.cj:53`：`while (i < size && let buffer <- buffers.remove())`（`size` 快照 + 阻塞 `remove()`）→ 改 `tryRemove()`。
- `f_rpc/src/server/ServerConfig.cj`：`bufferQueueSize` 默认 **1000000**（每连接约 8MB 实分配）建议调小。

---

## 五、方法论备注

- 本问题对**加日志极敏感**：带锁/文件 I/O 的埋点会改变现象（“第 1 秒失败” ↔ “前 10 个 ping 才失败”）。只允许**纯 `AtomicInt64` 计数 + 独立线程定期输出**。
- 隔离实验里把「借→归还」写进 `while(let Some(x) <- build(...))` **会变成死循环**（归还后立刻又能借到），会误判为“池挂死”；**判容量必须「先只借不还到底、再统一归还」**。
- 排查此类“心跳/连接抖动”：先看**写线程是否卡在 `encode()`**、**池可用数**，再怀疑传输层；修“卡死”前务必先确认“写失败会不会留下半条消息”，否则会把卡死变成崩溃。
