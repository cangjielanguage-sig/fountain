# Bug 分析报告：frpcdemo 错误日志成因（最终版 v2）

- 日期：2026-09-27
- 复现：`cd frpcdemo && ./boot.sh build && ./boot.sh runServer 1203 127.0.0.1:1203`
  （注意：`runServer 1203 127.0.0.1` 缺端口会启动即崩 —— `IPSocketAddress.tryParse('127.0.0.1')` → `NoneValueException`）

---

## 状态总览（2026-10-03 更新）

图例：✅ 已解决　🟡 部分解决（附遗留）　⬜ 未解决

| # | 问题 | 状态 | 说明 / 依据 |
| --- | --- | --- | --- |
| 缺陷 A | `EncodedMessage.copy` 写失败不归还池项 | ✅ | 早前会话已修（try/finally + 幂等 `release`）；本轮又修「归还不清空」（`Pool.init` 漏传 `clear`，见 6.8.1）——修后解码错误归零 |
| 缺陷 B | 一条消息拆多次 `write`，失败留半条 | 🟡 | 发送侧：≤4096B 已合并成**一次 write**（见 6.9 第 4 条），大消息仍流式 ⇒ 仍可能写出半条。**接收侧：已能在“装配中”判定半条并抛 + 断链（见 6.10）** ⇒ 剩下的只是“减少发送侧窗口”（见 7.1） |
| 缺陷 C | 解码异常后继续解析错位流 | ✅ | 两侧均改为 `close() + break`；`Message.decode` 中途 EOF 抛 `InputClosedException` |
| P0-2 | 池项所有权 / 借出必还 | ✅ | `BytesListOutputStream.release()`（幂等）+ `DefaultCodec.release()` + `EncodedMessage` finally 释放 |
| P1 | 取池项不无限静默阻塞 | ✅ | `KeyPool.get(Duration.Max)` 让出 CPU + 30s 上限 WARN 放弃；`lastBuffer()` 5s 有限超时（见 6.9 第 2 条） |
| P2 | 心跳与连接生命周期 | 🟡 | ✅ `pingTimeout` 10ms→1s、连续失败 3 次再拆链、`bufferQueueSize` 1e6→1024；⬜ 其余小项见 7.5 |
| 6.6-1 | f_pool 连线记账（根因） | ✅ | `Pool.init` 漏传 `clear`（确定性根因，见 6.8.1）+ `check()` 不再留 `checking` + 不变量 `s ≡ 节点数 + out` 同临界区 + 脱钩自愈 + 低频自检 |
| 6.6-2 | 不忙等 / 有限等待 | ✅ | 见 P1 |
| 6.6-3 | 借出即校验 | ✅ | `DefaultCodec.getBuf()` 借到非空缓冲即抛（编码期失败，绝不会写出半条脏消息） |
| 6.6-4 | 写路径原子性 | 🟡 | 同缺陷 B |
| 6.6-5 | 心跳策略 | ✅ | 同 P2 |
| 7.1 前半 | 半条消息被接收侧**静默吞掉**（零填充 / 当成“无 data”） | ✅ | 2026-10-03 修复（见 6.10）：`decodeData` 的 EOF 不再等价 `DataNone`；载荷短读不再被放行（原判据写错成 `size < s`）；流式分支改为“剩余待读”；`Message.decode` 的 `l == 0` → `l <= 0` |
| 7.1 后半 | 帧格式：无总长 / 无校验 | ✅ | 2026-10-03 改为 `[cmd][len][payload][crc32]`（见 6.11）：发送侧头里带 len、尾带 CRC；接收侧限长流（读不出帧外）+ 增量 CRC + `maxFramePayload` 上限；截断/损坏/长度不符一律抛 |
| — | (7.5 起) §四 P2 小项与池相关遗留 | ⬜ | 见 §7.2~7.6，未动 |
| — | 池记账脱钩的**触发源** | ⬜ | 未定位到具体一行；已加自愈 + `DEQUE-SELFCHECK`/`WEDGE-HEAL` 告警（见 6.8.5、7.2） |
| — | 重复归还的强约束 | ⬜ | 泛型 `SyncDeque<T>` 无法按值去重，目前只能检出 + 告警（见 6.9、7.3） |

**复验（2026-10-02，WSL Ubuntu-24.04）**：`f_pool` 全量 `cjpm test` = `TOTAL: 22, PASSED: 22, FAILED: 0`；
frpcdemo 端到端（默认配置约 45s）CPU **0%~2%**、应用日志事件 **0**、解码错误 **0**，无 `DEQUE-SELFCHECK` / `WEDGE-HEAL` 告警。

**复验（2026-10-03，分支 `fix/half-message-detect`）**：`f_protocol` **45/45**、`f_codec` **15/15**（修复前基线为 43/45）；frpcdemo 端到端日志事件 0、`decode errors` 0、`reader errors` 0、CPU **2.0%**。

> 下面 §一~§六 是历次分析原文（保留证据链），**其结论的当前状态以本节与 §七 为准**。

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

> **状态：✅ 已解决**（早前会话：`copy` 的 try/finally 归还 + 幂等 `release()`；本轮补「归还清空」见 6.8.1。）

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

> **状态：🟡 部分解决**（本轮：payload ≤ 4096B 合并成一次 write，见 6.9 第 4 条；大消息仍流式、协议无长度头 ⇒ 见 7.1。）

```cj
to.write([command])      // ① 命令字节：一次 write
bytes.copy(to: to, ...)  // ② 载荷：一次或多次 write（InputStream/File 走分块流式）
```

若 ① 成功、② 失败，socket 上留下**半条消息**。对端按协议继续解析 ⇒ 字节流从此错位 ⇒ `CodecException` ⇒ 垃圾 Data ⇒ `f_data` SIGSEGV。

### 缺陷 C：解码异常后继续解析错位流

> **状态：✅ 已解决**（服务端/客户端解码异常均 `close() + break`；`Message.decode` 中途 EOF 抛 `InputClosedException`。）

```cj
// 服务端 f_net/src/server/server.cj:147-150
} catch (e: Exception) { log.warn('error occurred on reading or executing', e); continue }   // ← continue！

// 客户端 f_net/src/client/client.cj:71-78
} catch (e: Exception) { log.error(e){...}; if(buffer.isClosed()){ break } }                // ← 未关闭时继续循环
```

对端一旦收到半条消息就会错位；此处 `continue`/不 break 让错位**被持续放大**，且（服务端）把垃圾 Data 送进 `RPCServer.execute → errorLog → JsonValue.from` → `f_data` SIGSEGV。

### 最初的引信

> **状态：✅ 已解决**（`pingTimeout` 10ms → 1s，见 6.5；并允许连续失败 3 次再拆链。）

客户端 `Client.checkTimer` 的 `pingTimeout` 默认仅 **10ms**（`f_net/src/client/client.cj:266`，`ClientBuilder.pingTimeout_`）。
一次 PING 往返要跨 4 次线程唤醒 + 2 次 encode + 2 次 decode，一旦超过 10ms 就 `close()+new()`；
向**已被自己关掉的 socket** 写就会抛 → 同时触发 A/B/C。这也解释了“服务端 `checkTimer` 关掉后日志全空”（少了这条写失败来源）。

---

## 四、修复建议（含落点与代码草案）

> 原则：**B/C 决定“错误会不会扩散”，A 的归还保证决定“会不会卡死”。** 三者必须一起修。

### P0-1 修 B：让消息写入具备原子性（不缓冲，适用于任意消息）

> **状态：✅ 已实现**（写失败即断链）；其中「合并」按文中建议只对**有界小消息**做（≤4096B，见 6.9 第 4 条）。

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

> **状态：✅ 已实现**（`BytesListOutputStream.release()` 幂等 + `DefaultCodec.release()` + `EncodedMessage.copy` finally 释放，并修了归还清空）。

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

> **状态：✅ 已实现**。

- 服务端 `server.cj:147-150`：`catch (e: Exception)` 里遇到解码类异常（`CodecException` / `IllegalArgumentException` / 任何非业务异常）应 `buffer.close(); break`，**不要 `continue`**。
- 客户端 `client.cj:71-78`：解码异常应 `buffer.close(); break`（而不是仅在 `isClosed()` 时 break）。
- `Message.decode` 在**消息中途读到 EOF** 时也应抛 `InputClosedException`（而不是让 `getOrThrow` 抛 `IllegalArgumentException`），便于上游统一识别。

### P1：取池项不要无限静默阻塞

> **状态：✅ 已实现**（见 6.9 第 2 条：让出 CPU + 30s 上限告警放弃 + `lastBuffer()` 5s 有限超时）。

- 结论：**“借出必还”是根治，但“无限阻塞”仍应改为有限超时 + 抛出/计数**（否则任何新漏还路径都会变成**无日志的永久挂起**，本次即是）。
- `DefaultCodec.lastBuffer()`：有限超时，取不到即抛出/计数。
- `f_pool/src/KeyPool.cj:342`：池满无空闲时快速失败（抛 `PoolException`）；`close()` 要唤醒所有等待者。

### P2：心跳与连接生命周期

> **状态：🟡 部分实现**（`pingTimeout`、连续失败容忍、`bufferQueueSize` 已做；其余小项见 7.5）。

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

---

## 六、本轮新增证据（v3）：根因落在 `f_pool` 的池项记账

> 本轮在 WSL Ubuntu-24.04 上做了“线上抓包 + 纯原子计数 + 隔离实验”，把 v2 的推断补成了可复现的因果链。
> 结论先说：**风暴的引擎是 `f_pool` 借出/归还的连线记账出错**——同一块池项会被两个借用者同时持有（double-lend）。
> 它同时解释了三件事：(1) 编码结果里混进别的消息的字节（→ 对端解码错位 → 拆链风暴）；
> (2) `size == totalSize` 但队列里取不到空闲项（→ `KeyPool.get(Duration.Max)` 死循环忙等 → 单核 100% 且永久挂住写线程）。

### 6.1 抓包铁证：同一条连接上，后续消息丢了命令字节，且载荷在累加

方法：把“注册消息里广告的服务端口”临时改成代理端口（`RPCServer.cj` 的 `registerMessage`，仅诊断用），
让客户端的**业务连接**也经过代理，再用 python 代理按连接名 dump 原始字节。

同一次运行里每条“风暴连接”的客户端→服务端字节数：`96, 134, 172, 210, 248, 286, 324, 362, 400, 438`（每条约 +38 = 2 条消息），
并且每条连接的开头都是**同一条 ping**（同一个 MessageID `18daa4ace9699c6e`）。conn=2 的完整原文：

```
c1 a018daa4ace9699c6e 3320042a 320127 3100 00      ← 完整消息：cmd + time + pid + tid + hostId + data
a0 18daa4ace9688a72 3320042a 320126 3100 00        ← 缺命令字节！(应是 c1 a0 ...)
a0 18daa4ace9699c6e 3320042a 320127 3100 00        ← 缺命令字节
a0 18daa4ace9699c6e 3320042a 320127 3100 00        ← 缺命令字节
a0 18daa4ad25646a5e 3320042a 32012e 3100 00        ← 缺命令字节
```

- 正常一条 19~20 字节；这里除第一条外都只有 **19 字节且没有 cmd**。
- `EncodedMessage.copy()` 明确先写 `to.write([command])`（`f_protocol/src/default/Message.cj:175-193`），
  所以“没写 cmd”只能是**一次 copy 里 payload 列表包含了多条消息的载荷**——即
  `EncodedMessage.bytes`(`ChainedBytesCopyTo(codec.inputs)`) 所引用的池项被**别的 codec 同时写入了**。
- 逐条 +38B 的增长也一致：池项在那儿持续被追加，每次 copy 都把“累积的全部载荷”发出去。

### 6.2 对端解码报错可以逐字节对上

`head=18 value=-2692390523438772173 bytes=[218,162,181,21,117,205,208,51]`（两次运行、1305 次**完全相同**）。
按缺 cmd 的错位推演：读端把上一字段多吃 1 字节后，本应读“命令字节”的位置读到的是 DATETIME 头 `a0`，
于是把 `a0` 当命令、把时间值首字节 `18` 当 STRING 头（`s=8`），接着读 8 字节“长度”= 时间值后 7 字节 + pid 头 `33`：

```
18            ← 被当作 STRING 头（s=8）
da a2 b5 15 75 cd d0 33   ← 时间值后 7 字节 + 下一字段头 0x33  → 对应的负数正是 -2692390523438772173
```
这与 `parseInt64` 的符号校验异常完全吻合（`DefaultCodec.cj:662`）。

### 6.3 `KeyPool.get(Duration.Max)` 的死循环忙等（CPU 2300%）

在 `KeyPool.get` 的 `Duration.Max` 分支临时插计数（纯 AtomicInt64 + 定期打印）：

```
KEYCNT] loop=58634000 poolNone=58633966 refNone=0
```
- `poolNone` = `pool.get(...)` 返回 None（队列取不到空闲项）；
- 同一时刻 `POOLCNT borrow=40 miss=0 back=14 held=26`，且 `pool.size == totalSize(1024)`；
- 即：**`size` 说有 1024 项，队列却是空的**，于是 `while(running.load())` 既取不到、又不能再创建，只能原地死转。

实测对照（同一份代码，只改这一个分支）：

| 版本 | 服务端 CPU（`/proc/<pid>/stat` 差分） |
| --- | --- |
| 原样（无限忙等） | **2200% ~ 2300%**（22 核全满，26 线程） |
| 该分支加 `sleep(1ms)` + 有限等待 | **1% ~ 4%** |

注意：这是**两件事**：忙等本身是 CPU 杀手；而“size 与队列不一致”才是 `f_pool` 的记账 bug 现场。

### 6.4 风暴的稳态（1 连接/秒）与它的自持条件

抓包侧同一次运行：`conn=1`（注册连接）ping/ack 全部配对成功；`conn=2..11`（业务连接）**客户端只发不收回**（S>C 为空或仅 1 字节 `e0`）。
日志侧稳态（每秒各一次）：服务端 `error occurred on decoding` / `TcpSocket.check` / `tcp closed`，客户端 `Client reader error`。
即：对端因错位断链 → 本端写线程撞上“Socket is already closed” → 双方各自 close+重连 → 每秒一轮，永不恢复。

另有两个**放大器**（不是根因，但会让现象更凶）：
- 服务端写线程卡在 `message.encode()`（池项取不到）→ 服务端**发不出 ACK** → 客户端 1s 心跳必然超时 → 拆链（这正是 `TcpSocket.check`/无 ack 的来源）。
- 日志量大且 `logger_appender_FRPCDemoFile_path` 指向 `/mnt/d`（drvfs）：几百条/分钟的多行栈日志会进一步吃 CPU。

### 6.5 本轮已落地的改动（保留）

| 文件 | 改动 | 依据 |
| --- | --- | --- |
| `f_rpc/src/server/ServerConfig.cj:59` | `bufferQueueSize` 默认 `1000000` → `1024` | 实测：1e6 会在 accept 循环里构造 1M 槽队列，第 9 个连接起 `SocketBuffer(...)` 卡住（`accParams=9 accBuf=8`），LISTEN 队列积压到一百多 → 新连接永远得不到服务；改 1024 后 accept 分步计数始终相等，不再积压 |
| `f_net/src/client/client.cj:272` | `ClientBuilder.pingTimeout` 默认 `10ms` → `1s` | 实测：一次 PING 往返在系统繁忙时可达数百 ms ~ 1.4s，10ms 必然超时；每次超时都 close+new，是风暴的引信 |

> `f_pool/src/KeyPool.cj` 的“有限等待”改动**已按要求回退**（当前工作区无该改动）。

### 6.6 建议的下一步修复方向（f_pool 为主）

1. ~~**修 `f_pool` 的连线记账（根因；必要但不充分 —— 为什么不能替代 2~5，见本节末「结论」）**~~ ✅ **已修（2026-10-02，见 6.8）**：
   归结点在 `f_pool/src/base/collection/LinkedNode.cj`（`HeadNode.nextForGet` / `TailNode.prevForChecking` /
   `ValueNode.check` / `doRemove`）与 `SyncDeque.cj`（`s` 与链表内容的同步）。必须成立的不变量：
   - **同一底层值在任意时刻最多被一个借用者持有**；队列里同一值最多存在一个节点（重复 `append/prepend` 必须去重）；
   - 只有 `idle` 节点可被 `nextForGet` 取走，且取走时**同时从链表摘除**（`doRemove`），归还时再重新插入；
   - `s` 恒等于「在队节点数 + 已借出数」：任何 `destroier` / 移除路径都必须 `fetchSub`；一旦 `s` 与实际节点数脱钩
     （表现为 `size >= totalSize` 却取不到空闲项），池要能自愈，否则只能靠第 2 条兜底；
   - `nextForGet` / `prevForChecking` 的链路遍历不得依赖跨锁非原子字段的读写；出现重复/丢节点时，
     优先看 `TailNode.insertPrev` 与并发 `remove`（`doRemove`）的交错。
   - 验收：并发压力下断言「同时借出的两个池项，其底层 `ArrayList` 不是同一个实例」；长跑后断言 `size` 与「实际可借数」一致
     （本轮的抓包/计数脚本可直接复用，见 6.7）。
2. **P1 兜底**：`KeyPool.get(Duration.Max)` 不得无限忙等（有限等待 + 抛出/计数）；`DefaultCodec.lastBuffer()` 用有限超时取池项。
   —— 这条即使根因修好也应做：任何“漏还/挂起”都会退化成**无日志的永久挂起**。
3. **防御性校验（便宜且立刻降害）**：`DefaultCodec.getBuf()` 借到池项后断言/清空该 `ArrayList`（借出的缓冲必须是空的），
   可让“被别的 codec 追加过”的池项不再把脏载荷发到线上。
4. **写路径原子性（缺陷 B）**：`EncodedMessage.copy` 现在是“先写 cmd 再写 payload”，中途失败即半条消息上线路；
   建议“同一把锁内完成一条消息的写出”，或对小消息（≤`fileThreshold`）合并成一次 `write`，大消息仍流式。
5. **心跳策略（P2）**：`pingTimeout` 放大（本轮已改默认值）+ 允许 N 次失败再拆链（与服务端 `unavailableChecked` 对齐）。

**结论（2026-10-02 追加）：修好第 1 条之后，2~5 是否就不用做了？——不是。**

第 1 条修的是**一个具体的记账 bug**；2~5 各自对应**独立的失效路径或放大机制**，第 1 条只能让它们「暂时不可达」：

- **第 2 条（不忙等）**：自旋与「池记账是否正确」无关。`size == totalSize` 本来就是**正常状态**（借出的项仍计数），
  1024 项全被合法借出时 `pool.get` 必然失败 —— 现在的实现是 `while(running.load())` **无 sleep 死转**，
  每个等待者烧满一个核、且**不打任何日志**。另外 `r.get()` 返回 None（`Ref` 被终结器置空）时只重试不退出，属同一类。
  最小版本可以**不改 `Duration.Max` 的等待语义**，只把自旋改成让出 CPU。
- **第 3 条（借出即校验）**：`ArrayListPool` 是 `clearOnReturning: true`，池项借出时非空 = 铁证违反不变量；
  O(1) 校验就能把「线上数据污染」变成「借出点本地报错」。形式可选：抛异常（fail fast）或 `clear + WARN`。
- **第 4 条（写原子性）**：**与第 1 条完全正交**。只要消息是「先写 cmd 再分片写 payload」，任何中断
  （本地 `close()` 竞态、对端 RST、socket 报错）都会留半条消息在流上；而协议**没有长度头/校验**，
  对端无法判定「这是半条」，只能靠解析到垃圾才发现（最早的 f_data SIGSEGV 就是垃圾 Data 被当合法数据）。
  修第 1 条只降低触发频率，不会消除它。
- **第 5 条（心跳策略）**：属策略层，与池无关。单次丢 ACK 就 close+new，会把任何 GC/调度抖动放大成重连；
  实测 PING 往返在繁忙时可达 1.4s。

| 条目 | 与第 1 条的关系 | 建议 |
| --- | --- | --- |
| 1 f_pool 记账根因 | 根因 | 必做，但不是唯一要做的 |
| 2 不忙等 / 有限等待 | 独立失效模式（自旋烧核 + 静默挂起） | 保留；`sleep` 部分无争议，超时策略另行决定 |
| 3 借出即校验 | 冗余安全网 | 建议保留（O(1)，收益是故障可见性） |
| 4 写原子性 / 截断可判定 | 完全正交 | 独立任务，建议排期 |
| 5 心跳 N 次失败再拆链 | 策略层 | 保留（便宜，防抖动放大） |

一句话：第 1 条让风暴**不再发生**，2/3 让**下次出问题时立刻可见（而不是静默挂住/污染线上）**，
4 让**发送失败不变成对端的数据事故**，5 让**抖动不升级为拆链**。四件事的价值不因第 1 条修好而消失，只是紧急度下降。


### 6.7 复现与诊断工具（都在 `.autocode/tmp/`）

- 构建：`bash .autocode/tmp/build.sh`（内部 `source /mnt/d/docs/work/cangjie/cangjie.sh`，无需手动设环境）。
- 起服务端：`server.sh`（默认 1203，自注册）；`server3.sh` 覆盖 `rpcServer_bufferQueueSize`。
- 抓包：`proxy.py`(1203→1204) / `proxy2.py`(1204→1203)；分析：`anawire3.py`（每连接 ping/ack 配对）、`dumpconn.py`（dump 指定连接原始字节）。
- 观测：`monitor2.sh`（瞬时 CPU% + 关键计数）、`cputop2.sh`（按线程 CPU）、`loggrep.sh`/`sumlog.py`/`errmix.py`/`decerr.py`（日志构成）。
- 隔离实验：`qtest.cj`（`ArrayBlockingQueue.remove(timeout)` 行为）、`closerace.cj`（close 与阻塞写并发，验证“close 会让写抛错而不是挂住”）。

> 注意：本轮用于**插桩计数 / 伪造广告端口**的一次性脚本（`instr3~8.py`、`diagdec.py`、`diagport.py`、`fixes.py` 等）已删除，
> 对应的源码插桩改动也已全部 `git checkout` 回退；若要复现请先 `git status`（应只剩 6.5 里的两处真实改动）。

---

### 6.8 第 1 条已修：根因、修复与验证（2026-10-02）

#### 6.8.1 根因一（确定性 bug）：`Pool.init` 漏传 `clear`，池项归还时不清空

- `f_pool/src/pool.cj:146-161`：`Pool.init` 构造 `KeyPool` 时**没有把 `clear` 回调传下去**，`KeyPool` 的 `clear` 落到默认空实现 `{_, _ =>}`（`KeyPool.cj:178`）。
  于是 `clearOnReturning: true` 形同虚设——**归还的池项保留旧内容**。
- 对照：`KeyPoolBuilder.build()` 是传了的（`KeyPool.cj:155`），所以“builder 建的池”正常；**只有经 `Pool` 建的池坏**，
  而 `DefaultCodec` 的字节缓冲池正是 `BytesListOutputStream.builder → ArrayListPool → Pool` 这条路。
- 后果链与 6.1 的抓包逐字节对上：归还的 `ArrayList` 留着上一条消息的字节 → 下一个 codec 直接**追加** →
  一次 copy 写出 `[cmd][上一条载荷][本条载荷]…`（除首条外都没有命令字节）→ 对端把 `a0`(DATETIME 头) 当命令、`18` 当 STRING 头 →
  那条恒定 `CodecException(head=18, value=-2692390523438772173)` → 断链 → 每秒一轮风暴。
- 修复：`clear: {_, v => clear(v)}`（`pool.cj`）。

#### 6.8.2 根因转二（记账脱钩）：计数说满、队列为空 → `KeyPool.get` 死循环忙等

修完 6.8.1 后抓包不再错位（`error occurred on decoding` 归零），但仍有约每秒一次拆链 + CPU 2200%~2400%。加纯计数探针（池编号 + 持有量 + 队列真实节点数）后拿到现场：

```
PDIAG] pool#0 ctor minSize=1024 maxSize=1024 totalSize=1024          ← 字节缓冲池
PDIAG] SPIN  pool#0 spins=100400000 size=1024/1024 keyed=1024/1024 blHeld=56 …
PDIAG] DEQUE-MISS s=1024 nodes=0 idles=0
```

即：**`s` 记着 1024 个池项，队列里一个节点都没有、也没有借出项** —— 记账脱钩。此时
`KeyPool.get(Duration.Max)` 的 `while(running.load())` 既取不到、又因为 `size >= totalSize` 不能新建 → 死循环忙等（单核 100%）。

修复（§6.6 第 1 条要求的“自愈”）：
- `SyncDeque` 增加**借出计数 `out`**，维护不变量 `s ≡ 队列节点数 + out`（取出 `+1`、归还 `-1`）；
- 取不到项时调用 `reconcileIfWedge()`：若 `s - out > 0` 却 `队列节点数 == 0 && out == 0` ⇒ 判定记账丢失，
  把 `s` 拉回真实值（0）并打出 `WEDGE-HEAL` 告警，池随即能重新创建池项、调用者立即恢复；
- 同时修掉 `SyncDeque.check()` 提前退出时把节点永久留在 `checking` 的问题（同样会永久丢池项）。

> 说明：脱钩的**触发源**（节点为何在并发下被摘掉而 `s` 未减）仍未定位到具体一行；上述自愈按 §6.6 第 1 条
> “一旦脱钩池要能自愈”实现，并把现场以 `WEDGE-HEAL` 告警暴露出来，便于下次直接抓现场。

#### 6.8.3 本轮改动清单（最小 diff）

| 文件 | 改动 | 作用 |
| --- | --- | --- |
| `f_pool/src/pool.cj` | `+5/-1` 补 `clear: {_, v => clear(v)}` | **根因一**：归还清空池项 |
| `f_pool/src/base/collection/SyncDeque.cj` | `+57/-2`：`out` 借出计数 + `reconcileIfWedge()` 自愈 + `check()` 不留 `checking` | **根因二**：脱钩自愈；另修一处永久丢项 |
| `f_pool/src/base/collection/LinkedNode.cj` | `+15`：`nextForCount()` 只读后继访问器 | 自愈做现场核对用 |
| `f_pool/src/byteslist_clear_test.cj`（新增） | 借→写→还→再借，断言缓冲为空 | 回归用例（已绿） |
| `f_rpc/src/server/ServerConfig.cj` | `bufferQueueSize` 1000000 → 1024 | 见 6.5 |
| `f_net/src/client/client.cj` | `pingTimeout` 10ms → 1s | 见 6.5 |

#### 6.8.4 验证结果（WSL Ubuntu-24.04）

| 项目 | 修前 | 修后 |
| --- | --- | --- |
| 服务端 CPU（默认配置，运行约 45s） | 2200%~2400%，26 线程 | **0%~2%，9~10 线程** |
| 应用日志事件数（约 45s） | 95~139 条（`error occurred on decoding` / `Client reader error` / `TcpSocket.check`） | **0 条** |
| 解码错误 | 每秒 1 条恒定 `CodecException` | **0** |
| `f_pool` 回归用例 `*ClearOnReturn*` | （未加前无覆盖） | `PASSED: 1, FAILED: 0, cjpm test success` |

复现/验证脚本（都带硬超时）：`.autocode/tmp/e2e_check.sh`（后台跑，输出 `/tmp/e2e.log`）、
`server_to.sh`（服务端 150s 硬超时）、`test_fpool_filter.sh`（只跑回归用例）、`monitor2.sh`（瞬时 CPU）。

#### 6.8.5 追查“记账脱钩”触发源 + `KeyPoolTest.testConcurrency` 挂死（2026-10-02 晚）

**1）触发源追查：加了不变量探针，但未能定位到具体一行**

做法：在 `SyncDeque` 每次变更后校验 `s == 队列节点数 + out`，违约即抛异常（让 unittest 直接失败并带调用栈）；
另加一个临时压力用例（32 线程 × 3000 次借还 + “同一对象归还两次”）。

结果：
- 压力用例确实**逼出了违约**（`INV-VIOLATION[append] s=3 nodes=1 out=1`），但**判定不可靠**：探针在临界区外采集，
  而 `out` 的增减与节点摘挂原本不在同一临界区，并发下会看到“节点已摘、计数未加”的**中间态**，无法区分真丢项与瞬时态。
- 端到端（修完 6.8.1/6.8.2 后）连跑多轮再未出现 `s=1024 nodes=0` 那种**确定性的**脱钩；
  推测原先的高频脱钩与“未清空 → 对端解码错位 → 拆链 → 池并发暴涨”这条链耦合，`clear` 修好后触发条件大幅减少。

**2）加固（本轮已改）：让不变量在任何时刻都成立，自愈不会误伤**

`SyncDeque` 里把「节点摘挂」与「借出计数 `out` / 总数 `s`」放进**同一临界区**（`head.globalLock`，仓颉 Mutex 可重入）：
- `remove`：取到节点与 `markBorrowed()` 同临界区；销毁分支的 `markReturned()` + `s.fetchSub(1)` 同临界区；
- `append`/`prepend`：插入（或销毁）与 `markReturned()`/`s.fetchSub(1)` 同临界区；
- `insertHead`/`insertTail`：插入与 `s.fetchAdd(1)` 同临界区；
- `reconcileIfWedge()` 在锁内核对，只在「`s > out` 且队列 0 节点且 `out == 0`」时自愈（`WEDGE-HEAL` 告警）。

残留窗口（已记录、风险极低）：`check()`（空闲超时巡检/`destroy` 路径）里 `ValueNode.check` 的摘节点与调用方的 `s.fetchSub(1)`
仍分属两个临界区；而这类巡检在本工程的池上 `checkInterval` 分别为 `Duration.Max`（字节缓冲池，不触发）与 `Duration.Minute`（byte 数组池，极少），
因此自愈误判只剩极窄窗口，后果仅是 `s` 可能偏小（软上限内多建一个池项），不会崩溃。

**3）`KeyPoolTest.testConcurrency` 挂死：已不再复现，全量用例转绿**

- 该用例：10 线程 × 1000 次 `pool.get('a', timeout: Duration.Max).getOrThrow()` + `giveBack`，而 key `'a'` 的 `maxSize = 3` ——
  **一旦池真丢项，`Duration.Max` 的等待就永远不会返回**，所以它天然是“脱钩”的探针（之前 2 分多钟不结束正是这个原因）。
- 现状：`cjpm test`（f_pool 全量）`TOTAL: 20, PASSED: 20, FAILED: 0`，整轮约 3 分钟内结束。
- 端到端复验（最终版）：默认配置跑约 45s，CPU **1%~2%**（9 线程）、应用日志事件 **0** 条、解码错误 **0**。

> 结论：第 1 条的“脱钩”已按“不变量成立 + 自愈兜底 + 现场告警”处理完毕；**触发源未定位到具体一行**，
> 若日后再现，可直接用 `WEDGE-HEAL` 告警 + 6.8.5 的探针思路（把校验放进临界区）继续收口。

---

### 6.9 §6.6 第 2/3/4/5 条与第 1 条剩余项：已落地（2026-10-02 晚）

| §6.6 条目 | 落地内容 | 落点 |
| --- | --- | --- |
| **2 不忙等** | `Duration.Max` 分支每轮 `sleep(1ms)` 让出 CPU；超过 **30s** 未取到即 `WARN` 放弃并返回 `None`（不再静默永久挂起）。`lastBuffer()` 改为 **5s 有限超时**取池项，取不到直接抛，由写线程记录可见失败 | `f_pool/src/KeyPool.cj`、`f_codec/src/default/DefaultCodec.cj` |
| **1 剩余** | ① 低频自检：每 10000 次变更核对一次 `s ≡ 队列节点数 + out`，违约打印 `DEQUE-SELFCHECK]`（重复归还等都在此暴露；泛型下无法按值去重，故策略为“检出 + 告警”，配合 `Releasable` 幂等与调用方纪律）② 两条验收用例落库：`sizeMatchesBorrowableCount`（借空后 size == 实际可借数，归还后仍成立）、`concurrentBorrowNeverSharesBuffer`（8 线程 × 2000 次，借到的缓冲必须为空 = 无共享底层 list） | `f_pool/src/base/collection/SyncDeque.cj`、`f_pool/src/pool_concurrency_test.cj`（新增） |
| **3 借出即校验** | `getBuf()` 借到池项后校验：非空即抛 `CodecException`（编码期失败 ⇒ 绝不会写出半条脏消息；调用方可见）。为此给 `BytesListOutputStream` 增加 `isEmpty` / `reset` | `f_codec/src/default/DefaultCodec.cj`、`f_pool/src/BytesListOutputStream.cj` |
| **5 后半** | 客户端心跳连续失败容忍 **3 次**再拆链（成功即清零），失败 1~2 次只 `WARN` 保留连接；异常路径同样容忍 | `f_net/src/client/client.cj` |
| **4 写路径原子性** | `BytesCopyTo` 增加 `byteSize()` / `asBytes()`（默认不支持；`BytesListOutputStream` 与 `ChainedBytesCopyTo` 实现）；`EncodedMessage.copy` 在 **payload ≤ 4096B** 时把 `[cmd][payload]` **合并成一次 `write`**，大消息仍流式（不做全量缓冲）。写失败时不再可能只写出前半条 | `f_protocol/src/default/Message.cj`、`f_pool/src/BytesCopier.cj`、`f_pool/src/BytesListOutputStream.cj` |

**验证**（WSL Ubuntu-24.04）：
- `f_pool` 全量 `cjpm test`：`TOTAL: 22, PASSED: 22, FAILED: 0`（含此前会挂死的 `KeyPoolTest.testConcurrency` 与新增两条验收用例）。
- frpcdemo 端到端（默认配置，约 45s）：CPU **0%~2%**（9 线程）、应用日志事件 **0**、解码错误 **0**，且无 `DEQUE-SELFCHECK` / `WEDGE-HEAL` 告警。

**遗留说明**：
- 条目 4 的“与 `close()` 互斥”未做：合并只覆盖小消息（≤4096B），大消息仍是流式，理论上仍可能出现“半条大消息”；彻底解决建议给消息加长度头/校验（见 6.6 第 4 条）。
  **（2026-10-03 补充）接收侧的“半条必被识别”已完成（见 6.10）；剩下的是“发送侧减少半条窗口”与“帧总长/校验”。**
- 重复归还目前在泛型 `SyncDeque<T>` 上只能“检出 + 告警”，无法按值去重；若后续要强约束，需要在 `KeyPool` 层用 `Ref<V>` 身份做借出集合（需要 `Ref` 满足 `Hashable & Equatable`）。

### 6.10 “半条消息被接收侧静默吞掉”：已修（2026-10-03）

- 分支/提交：`fix/half-message-detect`，提交 `fb69eede`（隔离工作区 `.worktrees/fix-half-message`）。
- 原则：**读到 0 字节 = 写端已关闭 = 数据不完整**；而“对象没装配完”在解码器里是已知的游标位置，可探测。
  因此 **EOF 只允许出现在“消息边界”**，一旦进入装配中就必须抛。

| 位置 | 修复前 | 修复后 |
| --- | --- | --- |
| `f_codec` `decodeData` | `size == 0 \|\| bytes[0] == 0` → 返回 `DataNone`（EOF 与“显式 `0x00`”混同） | `size <= 0` ⇒ 抛 `CodecException`；只有显式 `0x00` 才返回 `DataNone` |
| `f_codec` INPUTSTREAM 载荷 ≤ `fileThreshold` | 判据写成 `size < s`（`s` 是“长度的长度”1..8）⇒ 截断被放行 + 零填充 | 读到的字节数 `!=` 声明长度 ⇒ 抛 |
| `f_codec` 流式载荷分支 | 循环把“总长/本轮读到的长度”混用、无剩余计数 ⇒ EOF 时 `buffer[0..size]` 越界 | 改为“剩余待读”循环，读不满即抛；`file.write(buffer[0..take])` |
| `f_protocol` `Message.decode` | `l == 0` | `l <= 0`（防 SDK 在 EOF 返回 -1 时漏判） |

回归用例（按**协议层语义**放 `f_protocol/src/default/truncated_message_test.cj`）：

- `completeMessageStillDecodes`：完整消息仍能解（防止把修复做成“一律抛”）
- `truncatedInlinePayloadMustThrow`：1000B 载荷砍掉 300B ⇒ 必须抛（修复前：零填充放行）
- `truncatedStreamedPayloadMustThrow`：9000B 载荷（流式分支）截断 ⇒ 必须抛
- `eofAtDataFieldMustThrow`：EOF 恰好落在 `data` 字段起始处 ⇒ 必须抛（修复前：静默返回“无 data”的消息）

**验证**：修复前基线 f_protocol `43/45`（失败的两个正是本次新增用例）、f_codec `15/15`；修复后 f_protocol **45/45**、f_codec **15/15**；
frpcdemo 端到端（worktree 内构建，跑 40s）日志事件 0、`decode errors` 0、`reader errors` 0、新异常无误报、CPU 2.0%。

**仍未解决**：发送侧大消息仍是多段 `write`（可能写出半条），且协议没有帧总长/校验 —— 收不到“剩余字节数”“损坏检测”，见 7.1。

### 6.11 帧格式改造：`[cmd][len][payload][crc32]`（2026-10-03）

- 目标：把 6.10 的“**能判定不完整**”升级为“**有帧边界 + 有校验**”——接收侧能提前知道剩余字节数，也能发现损坏。
- 线上格式（payload = 原 `[time][pid][tid][hostId][data]`）：

```
[cmd(1B)][len(4B 大端, = payload 字节数)][payload(len B)][crc32(4B, 覆盖 cmd+len+payload)]
```

| 侧 | 实现 |
| --- | --- |
| 发送 `EncodedMessage.copy` | payload ≤ 4096B：整帧拼好**一次 write**；否则：先写头（含 len）→ 流式写载荷（**边写边算** CRC，零缓冲、零二次读）→ 写尾 CRC。写失败仍断链 ✓ |
| 接收 `Message.decode` | 读帧头（0 字节 = 干净关闭）→ 校验 `len ≤ maxFramePayload` → 用**限长流** `FrameBodyStream` 解码（物理上读不出帧外，载荷内部长度被写坏也不会越界）→ 校验“载荷是否被完整消费” → 读尾 CRC 比对 |
| 上限 | `protocol_maxFramePayload`（默认 1GB）——**首次使用时才读配置**：包初始化期读配置会在应用 `Init Image` 阶段抛 NoneValueException（已实测），故改为懒读 + 缓存 |
| CRC 实现 | 帧 CRC 自包含在 f_protocol（不在包初始化期依赖外部包）。**踩坑**：`f_protocol` 依赖 `f_util` 会导致应用加载期 `undefined symbol: crc32Update` —— 本仓库应用按目录顺序 dlopen 各包 .so，`f_protocol@fountain` 先于 `f_util@fountain` |

**配套改动**：`PooledBufferBytesCopyTo` 记住调用方声明的长度并实现 `byteSize()`（流式载荷也要能给出 len）；`DefaultCodec.encode(value: Array<Byte>)` 的 `this.size += size + sizeBuf.size` 把计数器算成两倍，改为 `value.size`。

**新增/更新用例**（`f_protocol/src/default/truncated_message_test.cj`，共 13 条）：
帧结构自洽（cmd/len/crc 与内容对应）、头截断、载荷截断（inline/流式）、尾 CRC 截断、
EOF 落在 data 字段起始、CRC 被污染、`len` 比实际长/短（CRC 已重算）、声称 1MB 快速失败、
**逐字节短读**、**大帧（9000B）自洽性** —— 最后这条当场抓出了“流式路径把帧头算了两遍 CRC”的真 bug。

**验证**：`f_protocol` **54/54**、`f_codec` **15/15**；demo 重建通过、服务端正常加载并监听（0 加载失败）。

**已知限制**：`frpcdemo` 客户端在本仓库当前 HEAD 上**本来就起不来**（`Init Image fail: NoneValueException` → SIGSEGV，主工作区未含本次改动时同样复现，见下），
因此本轮没能跑通“client 业务调用”级别的端到端；帧的端到端行为由 socket 级别的短读/短写用例 + 服务端启动验证覆盖。

---

## 七、尚未解决的问题（遗留清单）

> 截至 2026-10-03，§一~§六 描述的风暴及其直接缺陷**均已修复并复验**（含 6.10 的“半条必被识别”与 6.11 的帧格式）；见文首「状态总览」。以下是**仍未解决**的部分。

### 7.1 帧完整性：已完成（见 6.11），但发送侧仍有“多段写”窗口

- ✅ 已完成：`[cmd][len][payload][crc32]` 帧格式 + 限长流 + 增量 CRC + 上限校验（6.11）。
- ⬜ 未完成：大帧（> 4096B，尤其含 InputStream/File 流式载荷）发送侧仍是“头 + 多段载荷 + 尾 CRC”，
  写中途失败仍会在流上留下**半帧**；接收侧现在能**确定性判定**（len 未读满/CRC 缺失 ⇒ 抛 + 断链），
  但发送侧窗口本身没有消除。可选做法：把“写完一帧”与 `close()` 互斥（需配合写超时，否则把截断换成挂起）。
- ⬜ 未完成：帧内**值级**长度仍未设上限 —— 帧的 `len` 把可读字节数限住了，但 `DefaultCodec` 仍会按线上声明的长度
  直接分配（如 STRING 分支 `Array<Byte>(size, repeat: 0)`），恶意/损坏长度可造成超大分配。建议给值长度也加上限或与帧剩余量对齐。

### 7.2 池记账脱钩的**触发源**未定位（🟡 已有自愈兜底）

- 现状：历史上出现过「`s` 记着 1024 已满、队列里 0 个节点、也没有借出项」的脱钩，使 `KeyPool.get` 死循环忙等（当时 CPU 2200%+）。
  已实现 `reconcileIfWedge()` 自愈 + 低频 `DEQUE-SELFCHECK` 告警，但**触发源没有定位到具体一行**：
  追查探针在临界区外采集，无法区分「真丢项」与「并发中间态」（详见 6.8.5）。
- 若再现：直接以 `WEDGE-HEAL` / `DEQUE-SELFCHECK` 告警为线索，把不变量校验放进 `head.globalLock` 临界区内再采一次现场。

### 7.3 重复归还（同一对象 `giveBack` 两次）仍会插入重复节点（🟡 只能检出）

- 现状：泛型 `SyncDeque<T>` 无法按值比较/去重，重复归还会让队列出现同一对象的两个节点 ⇒ 该对象可能被两个借用者同时持有。
  当前策略：低频自检发现并告警（`DEQUE-SELFCHECK`）+ 依赖 `Releasable.release()` 幂等与调用方纪律。
- 待办建议：在 `KeyPool` 层用 `Ref<V>` 身份维护「借出集合」，归还时校验并拒绝重复归还
  （前提：`Ref` 满足 `Hashable & Equatable`）。

### 7.4 `SyncDeque.check()` / destroy 路径残留的窄窗口

- `ValueNode.check` 摘节点与调用方 `s.fetchSub(1)` 仍分属两个临界区。
- 该路径只在「空闲超时巡检 / destroy」触发，本工程的池配置为 `Duration.Max`（字节缓冲池，不触发）与 `Duration.Minute`（byte 数组池，极少），
  故仅剩极窄窗口；最坏后果是 `s` 偏小（软上限内多建一个池项），不会崩溃。
- 待办建议：把 `s` 递减并入同一临界区，彻底消除。

### 7.5 §四 P2 中尚未落地的几个小项（🟡 低优先，属健壮性改进）

| 位置 | 现状 | 建议 |
| --- | --- | --- |
| `f_net/src/server/server.cj:57` | 取 `buffer.remoteAddress` 前仍无 `isClosed()` 守卫（异常被外层 `try` 吞掉，只产生 WARN 噪音） | 加守卫或复用 `try` 内的地址 |
| `f_net/src/server/server.cj:53` | accept 循环仍是 `while (i < size && let buffer <- buffers.remove())`（`size` 快照 + 阻塞 `remove`） | 改 `tryRemove()` |
| `f_net/src/client/client.cj:77` | reader 异常统一 `log.error`，包括「被自身 checkTimer 正常关闭」的场景 | 该场景降级为 WARN/DEBUG |
| 服务端 `unavailableChecked` | 默认仍为 3（P2 建议放宽并与 PING 发送对齐） | 风暴已消失，建议先观察再定 |
| `KeyPool.get` 放弃阈值 | 30s 为写死常量 | 如需按池配置，可后续加参数 |

### 7.6 其他

- `KeyPool.get(Duration.Max)` 的「有限等待」是**策略变更**（原来是无限等待）：30s 后 `WARN` 并返回 `None`；
  若业务上确实需要无限等待，应改为可配置（当前为常量）。

### 7.7 frpcdemo 客户端当前无法启动（**既有问题**，2026-10-03 实测）

- 症状：`cd frpcdemo && ./boot.sh runClient` → `Init Image fail! exception ...: std.core:NoneValueException`
  （加载 `.../target/release/rpcclient@fountain/librpcclient@fountain` 失败）→ 随后 `MessageID.toString`
  解引用空值 SIGSEGV，进程 exit 139。
- **与本轮帧改造无关**：在不含本轮任何改动的主工作区（HEAD `e8d71105`）用同样命令复现，输出一致。
- 线索：崩点前最后两条是 `BeanFactory.getFirst: requiredType-fountain::rpcdef.EchoRPC` →
  `beanType-fountain::rpcdef.EchoRPC_Stub__`，即挂在 `f_bean`/`f_rpc` 宏生成的 stub 创建路径上；
  服务端不受影响（能正常加载、监听端口）。
- 影响：无法用 demo 做 client↔server 的**业务级**端到端回归；帧的端到端行为暂由 socket 级别
  短读/短写用例 + 服务端启动验证覆盖。
