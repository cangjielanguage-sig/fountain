# Bug 分析报告：frpcdemo 错误日志成因（最终版 v2）

- 日期：2026-09-27
- 复现：`cd frpcdemo && ./boot.sh build && ./boot.sh runServer 1203 127.0.0.1:1203`
  （注意：`runServer 1203 127.0.0.1` 缺端口会启动即崩 —— `IPSocketAddress.tryParse('127.0.0.1')` → `NoneValueException`）

---

## 状态总览（2026-10-03 更新）

图例：✅ 已解决　🟡 部分解决（附遗留）　⬜ 未解决　⚠️ 曾误判（结论已更正，见对应小节）

| # | 问题 | 状态 | 说明 / 依据 |
| --- | --- | --- | --- |
| 缺陷 A | `EncodedMessage.copy` 写失败不归还池项 | ✅ | 早前会话已修（try/finally + 幂等 `release`）；本轮又修「归还不清空」（`Pool.init` 漏传 `clear`，见 6.8.1）——修后解码错误归零 |
| 缺陷 B | 一条消息拆多次 `write`，失败留半条 | ✅ | 发送侧：≤4096B 合并成**一次 write**（6.9 第 4 条）；大消息仍流式，但 `SocketBuffer.close()` 现在**先等在写的那一帧退场**（上限 2s）再关 socket ⇒ 正常关闭时序下对端看到「完整帧 + EOF」，不再是半帧（见 7.1）。接收侧本就能确定性判定半条并抛 + 断链（6.10） |
| 缺陷 C | 解码异常后继续解析错位流 | ✅ | 两侧均改为 `close() + break`；`Message.decode` 中途 EOF 抛 `InputClosedException` |
| P0-2 | 池项所有权 / 借出必还 | ✅ | `BytesListOutputStream.release()`（幂等）+ `DefaultCodec.release()` + `EncodedMessage` finally 释放 |
| P1 | 取池项不无限静默阻塞 | ✅ | `KeyPool.get(Duration.Max)` 让出 CPU + 30s 上限 WARN 放弃；`lastBuffer()` 5s 有限超时（见 6.9 第 2 条） |
| P2 | 心跳与连接生命周期 | ✅ | `pingTimeout` 10ms→1s、连续失败 3 次再拆链、`bufferQueueSize` 1e6→1024；其余小项见 7.5，**7.5 各行已全部关闭** |
| 6.6-1 | f_pool 连线记账（根因） | ✅ | `Pool.init` 漏传 `clear`（确定性根因，见 6.8.1）+ `check()` 不再留 `checking` + 不变量 `s ≡ 节点数 + out` 同临界区 + 脱钩自愈 + 低频自检 |
| 6.6-2 | 不忙等 / 有限等待 | ✅ | 见 P1 |
| 6.6-3 | 借出即校验 | ✅ | `DefaultCodec.getBuf()` 借到非空缓冲即抛（编码期失败，绝不会写出半条脏消息） |
| 6.6-4 | 写路径原子性 | ✅ | 同缺陷 B：整帧写与 `close()` 互斥（`SocketBuffer` 的 `frameLock`），close 侧上限 2s |
| 6.6-5 | 心跳策略 | ✅ | 同 P2 |
| 7.1 前半 | 半条消息被接收侧**静默吞掉**（零填充 / 当成“无 data”） | ✅ | 2026-10-03 修复（见 6.10）：`decodeData` 的 EOF 不再等价 `DataNone`；载荷短读不再被放行（原判据写错成 `size < s`）；流式分支改为“剩余待读”；`Message.decode` 的 `l == 0` → `l <= 0` |
| 7.1 后半 | 帧格式：无总长 / 无校验 | ✅ | 2026-10-03 改为 `[cmd][len][payload][crc32]`（见 6.11）：发送侧头里带 len、尾带 CRC；接收侧限长流（读不出帧外）+ 增量 CRC + `maxFramePayload` 上限；截断/损坏/长度不符一律抛 |
| 7.1 值级长度 | 帧内**值级**声明长度可触发超大分配 | ✅ | 2026-10-04：`SizeBoundedInput` + `DefaultCodec.checkedBuffer()` 分配前校验「声明 ≤ 帧剩余」，超了抛 `CodecException`；f_protocol **60/60**（含 1TB 声明用例，见 7.1） |
| 7.7 | frpcdemo 客户端无法启动（**既有问题**） | ✅ | 2026-10-03 定位并修好启动链路（缺 `rpcClient_serverAddress` ⇒ ERROR+`exit(1)`；RPC 调用移出 Init Image；另修 4 处段错误）：实测 0 Init Image fail、0 段错误。**业务级 E2E 已跑通**（见 7.10） |
| 7.10 | 业务级 E2E 的 10 层断链 | ✅ | 2026-10-03 逐层定位并修复：消息 id 时区/相等、`ExecutorFuture.get` 丢结果、客户端 reader 中性解码、骨架注册前缀过滤、`ServiceMeta` 含 weight、发现连接复用、重试判断、demo 侧接口/载荷、对象类型未注册。实测客户端打印 JSON、服务端 `CONSUME` 正常（见 7.10） |
| — | (7.5 起) §四 P2 小项与池相关遗留 | ✅ | **7.5 已收口、7.6 已实现、7.4 已修（2026-10-04）**：f_net 三条已修 + 服务端 `tcp closed` 已分级（WARN 140 → 1）+ `unavailableChecked` 评估后关闭；`KeyPool.get` 的 30s 改成池初始化参数 `maxWaiting`（全项目接上，ORM/RPC 各有配置项）；`SyncDeque.check()` 的「摘节点 / `s` 递减」已并入同一临界区；7.2 已增强诊断、7.3 已决定不改（见各自小节） |
| — | **f_protocol→f_util 依赖**：应用加载期 `undefined symbol: crc32Update` | ✅⚠️ | **已修**（`boot.sh` 自建库优先）。曾误判为"加载顺序/需要预打开 .so"，实际是 `installed/libs/fboot` 的**旧副本抢先**（库无 SONAME），见 7.8 |
| — | 池记账脱钩的**触发源** | ✅ | 2026-10-04 定位到具体一行：`ValueNode.nextForGet()` 摘掉节点后**没把值返回**（队首非 idle 时"扫到却拿不到"）⇒ 池项凭空消失、`s` 多记 ⇒ 攒满后永久卡死；已修 + `check` 异常安全 + 自愈泛化 + `destroy` 计数同步 + 弱引用池同类修复，`f_pool` **29/29**；见 7.2 |
| — | 重复归还的强约束 | ⬜ | **决定：暂不改（2026-10-04）** —— 容量护栏（方案 A）不解决问题；方案 B（给 `V` 加 `Hashable & Equatable` 约束或改句柄 API）与"支持任意类型对象"的目标冲突 ⇒ 保持现状（低频自检 + `Release` 幂等），见 7.3 |
| 7.12 | `f_pool` 全量用例**偶发** SIGSEGV | 🟡 | 2026-10-03 仅观察到一次（栈顶 `UnitKeyPool.size` 的运行时泛型 MTable 空指针）；2026-10-04 七轮对照仍未复现 ⇒ **加入自愈与取证组合**：回调异常不破账目、巡检期主动审计自愈、维护线程看护重开、构造完成栅栏、SIGSEGV 前打印池统计；`f_pool` **36/36**。根因仍未证；见 7.12 |
| 7.13 | `f_store` 的 6 个 WAL 用例 ERROR（**既有**） | ✅ | 2026-10-04 定位并修复：`SegmentLog` 预分配 64MB 的文件被用例按"文件长度"整读（并发时撑爆堆）⇒ 测试侧改为"有界前缀读 + 就地改 1 字节"，`f_store` **204/204**；见 7.13 |
| 7.14 | `f_store` 全量用例在 `/tmp` 留 ~4GB 残留 | ✅ | 2026-10-04 修复：新增测试专用 `TestTmpDirs_test.cj`，包初始化与进程退出各清一次 `/tmp/f_store*`；验证 `f_store` 204/204 且运行后无残留（修前每次 +3.9~4.1GB）；见 7.14 |
| 7.9 | `f_net` 用例长期编译不过（读写路径无回归覆盖） | ✅ | 2026-10-04 迁移到 `Server<T>`/`Client<T>`：`cjpm test` = **14/14**（含 PING→ACK、executor 请求/响应 + 载荷逐字节往返）；见 7.9 |
| 7.11 | 对象类型的注册应由框架自动完成（含**嵌套**） | ✅ | 2026-10-04 两条路径：`@RPCStub`/`@RPCSkeleton` 登记顶层参数/返回类型；`@DataAssist[fields]` 在包初始化时自登记（覆盖嵌套，f_codec 解码未命中时拉取）。删掉 demo 手工 `registerType<EchoPO>()` 后 E2E 仍跑通，且嵌套 `EchoPO.inner` 出现在 JSON 里；见 7.11 |

**复验（2026-10-02，WSL Ubuntu-24.04）**：`f_pool` 全量 `cjpm test` = `TOTAL: 22, PASSED: 22, FAILED: 0`；
frpcdemo 端到端（默认配置约 45s）CPU **0%~2%**、应用日志事件 **0**、解码错误 **0**，无 `DEQUE-SELFCHECK` / `WEDGE-HEAL` 告警。

**复验（2026-10-03，分支 `fix/half-message-detect`）**：`f_util` **28/28**、`f_protocol` **55/55**（修复前基线 43/45）、`f_codec` **15/15**。

**复验（2026-10-04，worktree `fix-half-message`）**：`f_data` **104/104**、`f_pool` **23/23**（含 §7.6 的 `maxWaiting` 用例）、`f_codec` **15/15**、
`f_protocol` **60/60**（含 §7.1 值级长度的 1TB 声明用例）、`f_net` **14/14**（迁移后的读写路径用例，见 7.9）；
全仓 `cjpm build` **success**（验证 `@DataAssist` 宏改动在 f_orm/f_mvc/f_bean 等全部使用者上的影响面）。
frpcdemo 业务级 E2E 跑通：客户端打印 JSON —— **含嵌套** `"inner":{"tag":"inner-default","count":7}`、
服务端 `CONSUME(8)`（param/result 里同样有 `inner`）、两侧 `Init Image fail` 0、`not registered` 0、
客户端 `[ERROR]` **138 → 0**、`ping_failures=0`。
（§7.5 已收口：客户端 `[ERROR]`/`[WARN]` 均 **0**，服务端 `[WARN]` **140 → 1**——剩的那条是收尾时真实的 `SocketBuffer write error`。）
demo 已删除手工的 `DefaultCodec.registerType<EchoPO>()`，登记改由 §7.11 的两条自动路径完成（含嵌套类型）。

**复验（2026-10-04 第二轮，worktree `fix-half-message`）**：§7.1a（帧写/close 互斥）+ §7.1b（帧版本位）+ §7.2（诊断带 `lastOp`）
+ §7.4（`s` 递减并入临界区）落地后：`f_pool` **23/23**、`f_protocol` **62/62**（原 60/60 + 2 个版本位用例）、
`f_net` **14/14**、`f_codec` **15/15**，全仓 `cjpm build` **success**。

**复验（2026-10-04 第三轮）**：§7.9 的 CRC 多变体重构（`CrcEngine` + `Crc16`/`Crc32`/`Crc64`，顶层按最常用变体
MODBUS/ISO-HDLC/REDIS）后：`f_util` **31/31**（41 个变体逐个对上 RevEng 目录检查值 + 增量等价 + 顶层包装一致性）；
另修 `fdemo/boot.sh` 的库搜索顺序（见 7.8）—— 该问题表现为 `libboot.error@fountain.so` 加载期
`undefined symbol: fountain/f_data.base:DataTypeRegistry.ti`。

**加载现状**：帧 CRC 改用 f_util 后曾出现 `undefined symbol: crc32Update`（frpcdemo 起不来），
**已定因并修复**（`boot.sh` 自建库优先，提交 `7cdc025a`，见 7.8）；修复后服务端正常加载并监听 1203、
0 加载失败、0 帧错误。`f_protocol → f_util` 的依赖予以保留。

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

> **状态：✅ 已解决（2026-10-04）**，本节保留当时的分析原文：payload ≤ 4096B 合并成一次 write（6.9 第 4 条）；
> 大消息仍流式，但整帧写与 `close()` 已互斥（`SocketBuffer`，见 7.1），协议也补了总长 + CRC + 版本位（6.11、7.1）。

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

> **状态：✅ 已解决（2026-10-04）**，本节保留当时的分析原文：`pingTimeout`、连续失败容忍、`bufferQueueSize` 已做；
> 其余小项（7.5 表）各行已全部关闭。

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
>
> **2026-10-04 收口**：触发源已定位到 `ValueNode.nextForGet()` 丢值（见 §7.2）并已修复；本节的自愈机制保留并泛化。

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
>
> **2026-10-04 收口**：已定位到具体一行 —— `ValueNode.nextForGet()` 摘掉节点后把值丢了（见 §7.2）；
> 本节的探针思路（把校验放进临界区、只看权威状态）正是最终抓到这个 bug 的方法。

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
| CRC 类型 | **CRC-32**（IEEE 802.3 / zlib：反射多项式 `0xEDB88320`、初值 `0xFFFFFFFF`、末尾异或 `0xFFFFFFFF`），线上 4 字节大端，覆盖 `cmd+len+payload`。标准检查值 `CRC-32("123456789") == 0xCBF43926` 有专门用例（`frameCrcIsStandardCrc32`） |
| CRC 实现 | 帧 CRC 用 `fountain::f_util` 的**增量接口**（`crc32Init` / `crc32Update` / `crc32Finish`，2026-10-03 调整）；原来的自包含实现（`FRAME_CRC_TABLE` + `frameCrc*`）已删除 |
| 加载顺序 ⚠️ | **本条结论已更正**：最初判断为"f_protocol 必须先于 f_util 加载"，是**误判** —— `readelf -d` 显示 `NEEDED` 正常记录、库也会被正常拉起；真正原因是 `LD_LIBRARY_PATH` 命中了 `installed/libs/fboot` 里的**旧副本**（该 .so 无 SONAME，按文件名先命中）。详见 7.8 |

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
- ✅ 已修（2026-10-04）：发送侧窗口已收窄。`f_net` 的 `SocketBuffer` 里**整帧写出**（含大帧的流式载荷 —— `transfer`
  队列的单线程 writer 全程）与 `close()` 互斥：`close()` 先等这一帧退场（条件变量 `frameDone`，上限
  `FRAME_CLOSE_WAIT = 2s`），超时才记 WARN 后照关 —— 既不让对端看到半帧，也不把「截断」换成「挂起」；
  `isClosed()` 的懒关闭路径同样遵守该纪律。剩余的理论窗口只有「写卡住超过 2s」一种（有 WARN；写本身受
  socket 写超时约束，`socketWriteTimeout` 默认未设置）。用例：`f_net` 14/14（读写路径）。
- ✅ 已修（2026-10-04）：帧内**值级**长度不再按声明值直接分配。新增 `f_codec.SizeBoundedInput`（能报「本帧还剩多少字节」，
  由 `f_protocol` 的帧体流实现），`DefaultCodec.checkedBuffer()` 在**分配缓冲之前**校验「声明长度 ≤ 本帧剩余」，
  超了立刻抛 `CodecException`（三处：STRING、INPUTSTREAM 内联载荷、FILE 文件名×2）；输入不支持报剩余量时退化为原行为。
  用例（`truncated_message_test.cj`）：`splicedDataFieldStillDecodes`（拼接自检）+ `oversizedValueLengthIsRejectedBeforeAllocating`
  （载荷内声明 **1TB** ⇒ 只得到「超出帧剩余」的 `CodecException`，而不是 OOM/分配失败）。`f_protocol` **60/60**、`f_codec` **15/15**。
- ✅ 已修（2026-10-04）：帧头加 1 字节版本位 —— 帧格式变为
  `[version(1B)][cmd(1B)][len(4B 大端)][payload][crc32(4B，覆盖 version+cmd+len+payload)]`；
  `FRAME_VERSION = 1`（`f_protocol` 内部常量），接收侧遇到不认识的版本直接抛
  `CodecException('unsupported frame version …')`，不按当前布局硬解。用例：`frameLayoutIsVersionCmdLenPayloadCrc`、
  `unknownFrameVersionMustThrow`（0/2/0xff ⇒ 抛）、`partiallyReceivedHeaderMustThrow`（1/5 字节半头 ⇒ 抛）；
  `f_protocol` **62/62**（原 60/60 + 2）。

### 7.2 池记账脱钩的**触发源**：✅ 已定位并修复（2026-10-04）

- 历史症状：`s` 记着 1024（池上限）已满、队列里 0 个节点、也没有借出项 ⇒ `KeyPool.get` 再也取不到项；
  旧实现在那里是 `while(running.load())` 无 sleep 忙等（CPU 2200%+、且无日志）。
- **触发源（已定位到具体一行）**：`ValueNode.nextForGet()`（`LinkedNode.cj`，**队首节点不是 idle** 时向后续扫描的路径）
  在 `synchronized(globalLock){ … x.value }` 里摘掉节点后**没有把值 return 出去**，块的值又被紧随的
  `sleep(Duration.Zero)` 丢掉 ⇒ **池项被摘掉却没人拿到**：值凭空消失、`s` 不减（还继续记着它）。
  - 触发条件很常见：空闲巡检（`KeyPool.startCheckingSchedule` → `pool.check`）会把节点标记成 CHECKING，
    只要被标记的正好是**队首**节点，此刻并发上来的 `get` 就走这条扫描路径 ⇒ 每发生一次丢一个池项、`s` 多记一个。
    累积到 `s == totalSize` 而实际池项为 0 时，`KeyPool.get` 认为「池已满且没有空闲项」⇒ 既不新建也取不到
    ⇒ 永久卡死。这与历史症状（含「队列里 0 个节点」）完全吻合，也解释了当时为什么抓不到日志——这条路径不抛异常。
  - 修法：摘到的值放进局部 `taken` 再 `return`；内层复检失败则前移继续扫描（`LinkedNode.cj`）。
- **同时修掉的两处同类隐患**（都会造成「池项还在/记着，却取不到」）：
  1. `check` 循环的异常安全：`ValueNode.check` 在 `checker` 抛异常时先 `setIdle()` 再往外抛；
     `SyncDeque.check` 改用 `try/finally` 保证「已标记 CHECKING、还没被处理」的节点一定还原
     —— 原来除 `!running()` 以外的任何异常退出（checker/taskPusher 抛异常）都会把它永久留在 CHECKING：
     既取不到、也不会再被 `prevForChecking` 挑中清理。
  2. `BaseKeyPool.destroy()` 不同步全局计数 `s`（改为 `BasePool.destroy` 返回清掉的数量，`s.fetchSub(...)`）
     ⇒ 原来 destroy 之后 `size` 仍报旧值，会让后续 `get` 以为池已满。
  3. `WeakSyncDeque.remove()` 只匹配 `WeakRef<Box<T>>`：引用类型（对象本身）会「节点已摘掉却返回 None」
     ⇒ 与 1 同类的池项凭空丢失（`Mode.WeakFifo/WeakLifo` 这条路径当前仓库里没人用，属潜伏问题）。
- **自愈泛化**（`reconcileIfWedge`，仍在「`remove()` 一个都取不到」时触发）：**队列是权威**，两种形态都校正 ——
  ①「滞留项」：队列上还有非 idle 节点且**没有 check 在飞**（`checkers == 0`）⇒ 全部还原为 idle
  （该判据不依赖计数，`out > 0` 时也照样能救）；②「计数脱钩」：**没有借出项**时 `s != 节点数` ⇒ `s` 拉回节点数。
  告警带 `stranded/bookkeeping` 明细、`out`、`lastOp`；`DEQUE-SELFCHECK` 另加「无可取项」形态
  （打印 `idle/checking/在飞 check 数`）。
- 验证：`f_pool` **29/29**（原 23/23 + 6 个新用例）——
  `testScanForwardMustReturnTakenElement`（队首非 idle 时借用必须真的返回所摘项：修前返回 None 且项被摘走）、
  `testCheckerThrowingMustNotLoseElement`、`testTaskPusherThrowingMustNotLoseElement`、
  `testWeakDequeRemoveMustReturnElement`（弱引用池同类丢值）、
  `testStrandedCheckingMustBeHealed`（人为制造滞留 ⇒ 下一次取不到时自愈救回）、`BaseKeyPoolTest.destroyMustSyncSize`；
  依赖模块回归：`fdemo` 全量构建 **BUILD_EXIT=0**、`f_rpc` 用例 **2/2**。

### 7.3 重复归还（同一对象 `giveBack` 两次）仍会插入重复节点（🟡 只能检出）

- 现状：泛型 `SyncDeque<T>` 无法按值比较/去重，重复归还会让队列出现同一对象的两个节点 ⇒ 该对象可能被两个借用者同时持有。
  当前策略：低频自检发现并告警（`DEQUE-SELFCHECK`）+ 依赖 `Releasable.release()` 幂等与调用方纪律。
- **原待办方案经查不成立（2026-10-04）**：「用 `Ref<V>` 身份维护借出集合」需要借出方与归还方看到**同一个 `Ref`**，
  但现状是 `KeyPool.giveBack` 每次都 `ref(key, object)` **新建** `Ref<V>`（`KeyPool.cj`），且 `KeyPool.get` 返回的是解包后的
  `V`（借出方根本看不到 `Ref`）⇒ 拿 `Ref` 当身份判不出"同一个对象被还两次"。
- **决定（2026-10-04）**：**暂不改**。—— A（容量护栏）不解决问题；B 需要给 `V` 加 `Hashable & Equatable` 约束或改成句柄式 API，
  而"支持各种类型的对象"才是本池的目标（用户明确）⇒ 维持"低频自检 + 告警 + `Releasable.release()` 幂等 + 调用方纪律"。
  下面两条路作为记录保留（日后若改变取舍可直接照做）：
- 两条可落地的路（二者代价不同）：
  1. **容量护栏（便宜、部分）**：归还时若该 key 的**空闲项数**已达 `maxSize`（注意不能用 `keyedSize`，它含借出项，
     会把合法归还误拒），就丢弃这次归还并 WARN。能拦住"重复归还把池撑到上限以上"（历史症状正是 `s` 记满 1024），
     但拦不住"池没满时的重复归还"；需要给 `SyncDeque`/`BasePool`/`IKeyPool` 加一个 `idleSize` 视图。
  2. **精确拒绝（彻底、破坏 API）**：`KeyPool` 的 `V` 加 `Hashable & Equatable` 约束并用借出集合去重，
     或把 `get` 改成返回句柄（`Ref<V>`）。能精确判重，但改动公开 API 与所有调用点。

### 7.4 `SyncDeque.check()` / destroy 路径残留的窄窗口：✅ 已修（2026-10-04）

- 原状：`ValueNode.check` 摘节点（自己进一次临界区）与调用方 `s.fetchSub(1)` 分属两个临界区，
  会留下「节点已摘、`s` 未减」的中间态，被并发的不变量校验误判成记账脱钩；该路径只在「空闲超时巡检 / destroy」触发。
- 修法：`ValueNode.check(fn, onRemoved!)` 新增回调，**在摘节点的同一临界区内**执行 —— `SyncDeque.check` 传
  `{=> s.fetchSub(1)}`；`taskPusher()` 仍在锁外（可能阻塞，不能带进临界区）。
- 验证：`f_pool` **23/23**（含并发用例）。

### 7.5 §四 P2 中尚未落地的几个小项：✅ 全部关闭（2026-10-04）

| 位置 | 现状 | 建议 |
| --- | --- | --- |
| `f_net/src/server/server.cj:57` | ✅ 已修（2026-10-04）：取 `remoteAddress` 前加 `!buffer.isClosed()` 守卫 | — |
| `f_net/src/server/server.cj:53` | ✅ 已修（2026-10-04）：`buffers.remove()` → `tryRemove()`。**这不是纯噪音**：`std.collection.concurrent` 的 `remove(): E` 是阻塞出队，而 `size` 只是快照 —— 队列被并发消费（其它 tick 回调 / `close()` 时 `doClose` 抽干）时会把定时器线程**永久卡住**（巡检停摆 + 每 tick 泄漏一个阻塞线程） | — |
| `f_net/src/client/client.cj:77` | ✅ 已修（2026-10-04）：`buffer.isClosed()` 为真（连接是自己关的）时降级 `log.debug{'Client reader closed …'}`，其余仍 `log.error` 带栈。实测一次 70s E2E：`[ERROR]` **138 → 0**，同一批消息以 `Client reader closed`（DEBUG）出现 138 条；`ping_failures=0`（心跳与发现正常） | — |
| `f_net/src/server/server.cj:131/159` | ✅ 已修（2026-10-04）：两处 `InputClosedException`（对端干净关闭 = 读到 EOF）由 `log.warn('tcp closed', e)` 改为 `log.debug{'tcp closed'}`、不带栈。实测一次 70s E2E 服务端 `[WARN]` **140 → 1**（剩的那条是收尾时真实的 `SocketBuffer write error`）；真正的解码/执行失败仍是 WARN + 栈 | — |
| 服务端 `unavailableChecked` | 默认仍为 3（P2 建议放宽并与 PING 发送对齐） | ✅ **本行关闭（2026-10-04 评估）**：该项已可用 `rpcServer_unavailableChecked` 配置；多轮 E2E 无"误判拆链"证据（`ping_failures=0`）⇒ 保持默认 3，不为无证据的假设放宽 |
| `KeyPool.get` 放弃阈值 | ✅ 已修（2026-10-04，随 §7.6）：30s 不再是写死常量，改成池初始化参数 `maxWaiting`（默认 30s，可传 `Duration.Max` 表示真无限等待）；全项目的建池点都已接上 | — |

### 7.6 `KeyPool.get(Duration.Max)` 的等待语义：✅ 已拍板并实现（2026-10-04）

- **决定**：等待上限 `maxWaiting` 改成**池初始化参数**（默认 **30s**）—— f_pool **不读配置**（不加 f_config 依赖）；
  `timeout == Duration.Max` 仍走"让出 CPU 的等待"分支，超过 `maxWaiting` 记 WARN 并返回 `None`；
  把 `maxWaiting` 传成 `Duration.Max` 就是**真无限等待**（实现仍每轮 `sleep(1ms)` + 分片等待，**不是**当初那个忙等）。
- 实现（全项目池使用点已接上；f_orm/f_rpc 的配置项风格分别是 `orm_*` / `rpc_codec*`）：

| 位置 | 改动 |
| --- | --- |
| `f_pool` | `KeyPool`（两个构造 + `KeyPoolBuilder` + `setMaxWaiting`）、`Pool`（同）、`ArrayPool`、`ArrayListPool`、`BytesListOutputStream.builder` 全部新增 `maxWaiting!: Duration = Duration.second * 30` 并逐层透传；`KeyPool.get` 用它替代写死的常量，并加 `waitChunk()` 防 `MonoTime + Duration.Max` 溢出。内部 `UnitKeyPool`/`BaseKeyPool`/`base/*` 只是存储实现（不做等待），不需要该参数 |
| `f_codec` | 新增 `DefaultCodec.setBufferPool(initSize!, minSize!, maxSize!, maxWaiting!)`（不暴露 f_pool 类型）、`setBytesPool(..., maxWaiting!)`；两个静态池显式按参数初始化 |
| `f_orm` | `DatabasePool` 三个构造新增 `maxWaiting!` 并传给 `Pool<PooledConnection>`；配置驱动的构造读 `ORMConfig.getPoolMaxWaiting` = **`orm_databasePoolMaxWaiting`**（**Duration 格式**，如 `30s`/`1m`，默认 30s，≤0 如 `0s` = 真无限等待） |
| `f_rpc` | 新增 `f_rpc/src/base/PoolConfig.cj`（module 级 `protected`，因为 `f_rpc.client`/`f_rpc.server` 是**兄弟包**）：`rpc_codecBufferPoolInitSize/MinSize/MaxSize`、`rpc_codecBytesPoolInitSize/MinSize/MaxSize/ArraySize`、`rpc_codecPoolMaxWaiting`（**Duration 格式**，如 `30s`，默认 30s，≤0 = 无限）；`initCodecPools()` 在 `RPCServer.start()` / `RPCClient.start()` 首次调用，用配置项初始化 codec 的两个池 |
| `f_protocol` | 生产代码**不建池**（只用 `BytesCopyTo`/`Releasable` 两个接口），无需参数；其用例通过 `DefaultCodec.setBytesPool` 注入的是 f_codec 的池 |

- 验证：
  1. 新用例 `f_pool/src/KeyPool_test.cj::maxWaitingBoundsInfiniteWait`：`maxWaiting = 200ms` 的池取空后
     `get(timeout: Duration.Max)` 实测 **200.7ms** 返回 `None`（既不是 0.2ms 也不是默认 30s）⇒ 参数确实生效；
  2. 全仓 `cjpm build` **success**（含 f_orm/f_rpc）；`f_pool` **23/23**、`f_codec` **15/15**、`f_protocol` **60/60**、`f_net` **14/14**；
  3. demo E2E 跑通，两侧启动日志出现 `[FOUNTAIN_RPC.pool] codec pools initialized: … maxWaiting=30s`；
     再用自定义配置启动服务端（`rpc_codecPoolMaxWaiting=5s rpc_codecBytesPoolArraySize=2048 rpc_codecBufferPoolMaxSize=256`）
    ⇒ 日志变为 `bufferPool(… max=256), bytesPool(… arraySize=2048), maxWaiting=5s` ⇒ **确实按配置项初始化**。
- **2026-10-04 补充（配置项改为 Duration 语义）**：`orm_databasePoolMaxWaiting` / `rpc_codecPoolMaxWaiting` 的值
  按 `Duration.toString()` 书写（`30s`、`1m`），由 `Config.getData<Duration>`（f_config，走 `DataParsable`）解析，ORM 侧仍支持驱动级 key
  （`postgres_orm_databasePoolMaxWaiting`）；非法值退回默认 30s；
  用例 `f_orm/src/wrap/ORMConfig_test.cj::testPoolMaxWaiting` 覆盖 `45s` / `1m` / `0s`(⇒`Duration.Max`) / 非法值(⇒默认 30s)。
- 附带修掉一个静默隐患：`DefaultCodec` 文件载荷解码时 `bytesPool.get()` 取不到会**静默跳过写文件**（把内容缺失的 `File` 交给上层），
  现改为抛可见的 `CodecException`。
- 精确边界：`maxWaiting` 只在 `timeout == Duration.Max` 分支生效；编码借缓冲走 `lastBuffer()` 的**有限 5s** 超时，不受它影响。

### 7.7 frpcdemo 客户端无法启动（**既有问题**）⚠️ 启动链路已于 2026-10-03 修好，原症状与根因见本节末尾

- 症状：`cd frpcdemo && ./boot.sh runClient` → `Init Image fail! exception ...: std.core:NoneValueException`
  （加载 `.../target/release/rpcclient@fountain/librpcclient@fountain` 失败）→ 随后 `MessageID.toString`
  解引用空值 SIGSEGV，进程 exit 139。
- **与本轮帧改造无关**：在不含本轮任何改动的主工作区（HEAD `e8d71105`）用同样命令复现，输出一致。
- 线索：崩点前最后两条是 `BeanFactory.getFirst: requiredType-fountain::rpcdef.EchoRPC` →
  `beanType-fountain::rpcdef.EchoRPC_Stub__`，即挂在 `f_bean`/`f_rpc` 宏生成的 stub 创建路径上；
  服务端不受影响（能正常加载、监听端口）。
- 影响：无法用 demo 做 client↔server 的**业务级**端到端回归；帧的端到端行为暂由 socket 级别
  短读/短写用例 + 服务端启动验证覆盖。

**根因（三段式，2026-10-03 定位）**：
1. `frpcdemo/rpcclient/src/client.cj` 把一次**真实 RPC** 写在包级初始化器里 ⇒ 它在 `Init Image`（包初始化）阶段执行；
2. `frpcdemo/boot.sh` 的 `runClient` 从没给过客户端服务端地址（脚本只导出服务端语义的 `rpcServer_baseAddresses`，
   客户端要的 `rpcClient_serverAddress` 始终未设置）⇒ 地址表为空；
3. 空地址表一路下传 ⇒ 包初始化阶段抛 `NoneValueException` ⇒ 包加载失败 ⇒ 进程带着未初始化完的静态状态继续跑
   ⇒ `f_log` 异步线程格式化**零值 `MessageID`**（`time` 未初始化）⇒ SIGSEGV / exit 139。
   （`MessageID` 自身默认值是对的（`time = DateTime.now()`）；段错误是次生现象，别往 `MessageID` 报 bug。）

**探针证据**：不设地址 ⇒ `NoneValueException` + exit 139；设 `rpcClient_serverAddress=1.0,127.0.0.1:1203`
⇒ 异常变成可诊断的 `fountain/f_net.client:ClientException`、exit 1（不再段错误）。

**本轮修复（9 个文件）**：

| 位置 | 改动 | 实测结果 |
| --- | --- | --- |
| `frpcdemo/boot.sh` | 透传地址：`runClient $2` ⇒ `export rpcClient_serverAddress="1.0,$地址"`；不给地址则不设置（交由客户端报错） | 两条路径都能演示 |
| `frpcdemo/rpcclient/src/client.cj` | 包级初始化器 ⇒ `ClientInitializer`（`Initializer.start()`，由 `f_app` 启动后另起线程调用）；失败只记 ERROR | **Init Image fail 0**、进程不再 139；演示调用失败不再阻止应用启动 |
| `f_rpc/src/client/ClientConfig.cj` | 新增 `requireServerAddresses()`：缺 `rpcClient_serverAddress` ⇒ `rpclog.error`（键名/格式/示例/后果）⇒ `exit(1)` | 满足"记录 ERROR 说明原因后结束进程"：实测 exit 1、ERROR 可读 |
| `f_rpc/src/client/ClientConfig.cj` | 新增 `rpcClient_discoveryTimeout`（默认 5s，可配，不写死常量） | 服务发现未完成时有上限 |
| `f_rpc/src/client/RPCClient.cj` | `services[message.meta]` 直接下标 ⇒ `availableClients()` 等待发现完成，超时抛明确 `RPCException`（服务名/方法/版本） | 第二层 `NoneValueException` 消失，失败可诊断 |
| `f_rpc/src/client/RPCClient.cj` | `hostMap[host]` ⇒ `hostMap.get(host) ?? 1.0` | 键不存在不再抛 |
| `f_rpc/src/client/RPCClient.cj` | `var consume = unsafeZeroValue<Message>()` ⇒ `Option<Message>`；`finally` 只在真发出过消息时记日志 | **段错误根因之一**：零值 `MessageID` 一格式化就崩 |
| `f_rpc/src/macros/RPCStub.cj` | `qualifiedName.indexOf('.').getOrThrow()` ⇒ `?? qualified.size` | 宏生成代码里的 `NoneValueException` 隐患 |
| `f_rpc/src/server/LogMessage.cj` | `ErrorMessage.new(param, e)` 不再写固定容量缓冲（曾把 875B 堆栈写进 80B 缓冲抛下标越界）；`EMPTY_DATA_ANY` 由 `unsafeZeroValue<DataAny>()` 改为 `DataAny(DataNone.INSTANCE)` | 服务端错误响应不再自崩 |
| `f_rpc/src/server/RPCServer.cj` | `error()` 的错误日志只记文本，不再对请求数据做 `JsonValue` 转换 | 错误路径不再遍历形状未知的 `Data`（曾段错误），真实异常得以打印 |

**复验（2026-10-03，worktree `fix-half-message-detect`）**：
- A) `./boot.sh runClient`（不给地址）⇒ `Init Image fail` **0**、`CLIENT_EXIT=1`、ERROR 日志含原因与格式示例；
- B) 服务端在跑 + `./boot.sh runClient 127.0.0.1:1203` ⇒ `Init Image fail` **0**、客户端**不再段错误**
  （跑到超时被杀，exit 124），失败信息为 `RPCException: no available client for ... after 5s`。

**后续**：A)「不给地址」与 B)「发现未完成」两条路径都已按预期可诊断；B 路径当时暴露的「服务端拒收 SUBSCRIBE ⇒ 服务发现为空」
已在 §7.10 逐层修复 —— **业务级 E2E 已跑通**（客户端打印 JSON、服务端 `CONSUME(8)`，见 7.10）。

### 7.8 `undefined symbol: crc32Update`：**已定因并修复**（2026-10-03）⚠️ 本条曾被误判

- 现象：`frpcdemo` 重建成功（`cjpm build success`），一启动就失败、端口未监听：
  ```
  f_protocol@fountain/libf_protocol.default@fountain.so: undefined symbol: _CN15fountain:f_util11crc32UpdateHjRNat5ArrayIhE
  LoadCJLibrary fail.
  ```
- **真因（与加载顺序无关，也与 `PackageInfo.load` 无关）**：`LD_LIBRARY_PATH` 里
  `/mnt/d/docs/work/cangjie/installed/libs/fboot` 排在**工程自建库目录之前**，而该目录下的
  `libf_util@fountain.so` 是 **2026-10-02 的旧副本（不含 `crc32Update`）** ⇒ 动态链接器先命中旧副本。
  对应事实（`readelf`/`nm` 实测）：

  | 事实 | 证据 |
  | --- | --- |
  | `libf_protocol.default.so` **确实**记录了依赖 | `readelf -d` → `NEEDED libf_util@fountain.so` |
  | 它对 `crc32Update` 是**未定义引用** | `nm -D -u` → `U _CN15fountain:f_util11crc32UpdateHjRNat5ArrayIhE` |
  | 自建库里**有**该符号 | `nm -D` → `T _CN15fountain:f_util11crc32UpdateHjRNat5ArrayIhE`（16:58 构建） |
  | `installed/libs/fboot` 的副本**没有**该符号 | 同一条 `nm` → `crc32Update=0`（10-02 构建） |
  | `libf_util@fountain.so` **没有 SONAME** | `readelf -d` → 无 `SONAME`（因此按文件名在 `LD_LIBRARY_PATH` 里先命中者胜） |
  | 库搜索顺序里旧目录在前 | `boot.sh` 生成 `LD_LIBRARY_PATH` 时把自建目录 **append 在后**：`$LD_LIBRARY_PATH:<target dirs>` |

- **修复**：`frpcdemo/boot.sh` 改为把自建库目录**前置**（`<target dirs>:$LD_LIBRARY_PATH`），
  已实测：服务端正常加载并监听 1203、0 加载失败。
  - 同一脚本在每个 app 里各有一份（fdemo/fleet 等），如需彻底根治，建议在部署脚本同步
    `installed/libs/fboot` 的内容，或统一改成“自建库优先”。
- **不再是阻塞项**：`f_protocol → f_util` 的依赖可以保留；此前的“加载顺序/预打开 .so”方案**不需要**了
  （那是我最初的误判：库其实会被 `DT_NEEDED` 正常拉起，问题出在命中了旧副本）。
- **同一坑第二次命中（2026-10-04，fdemo）+ 已修**：`./fdemo/boot.sh run` 启动期报
  ```
  libboot.error@fountain.so: undefined symbol: fountain/f_data.base:DataTypeRegistry.ti
  LoadCJLibrary fail. / ReflectException : Failed to load package from '.../libboot.error@fountain'
  ```
  取证：用户那次跑的是**嵌套产物** `fdemo/fdemo/release`（`cd fdemo && ./boot.sh run` ⇒ `target_path=./fdemo` 相对于该目录）；
  那份 `libboot.error@fountain.so` 引用了 §7.11 自动登记用的 `DataTypeRegistry`（`nm -D -u` 可见），
  它自己目录下的 `libf_data.base@fountain.so` **有**该符号（5 处），而 `installed/libs/fboot` 的副本 **0 处** ——
  但该目录排在 `LD_LIBRARY_PATH` **前面**（`cangjie.sh` 就把它放在前面），于是命中了旧副本。
  修法（与 frpcdemo 一致）：`fdemo/boot.sh` 的 `exports()` 让自建 release 目录**优先**（放在继承的
  `$LD_LIBRARY_PATH` 之前）。静态复验：第一命中变为自建库、`DataTypeRegistry` 符号数 5。
- **同一处的第二个缺口（2026-10-04，同一脚本）**：`postgres_driver` 的 `.so` 不在 `release/*` 的**一级**目录里，
  而在 `release/postgres_driver/` 下（产物都在 `$target_path/release` 内，只是一层深）。原来那种
  `find $target_path/release/* -type d` 只取一级子目录 ⇒ 驱动目录漏掉 ⇒ 运行期
  `libpostgres_driver.so: cannot open shared object file`。
  修法：改成**一条**递归 find —— `find $target_path/release -name 'lib*.so' -printf '%h\n'|sort -u`，
  直接收集「目录里有 .so」的那些目录（一层深、两层深都覆盖，也不会产生重复条目）。
  （此前 `undefined symbol: DataTypeRegistry.ti` 的另一半原因是：在 `fdemo/` 目录里执行时，旧的相对默认值
  `./fdemo` 会解析成 `fdemo/fdemo`，即跑到另一棵树上；现在统一在仓库根目录执行 `./fdemo/boot.sh …`，
  产物只在 `fdemo/release/` 一处，不再有嵌套。）
- 教训：这类问题**单测发现不了**
- 教训：这类问题**单测发现不了**（`cjpm test` 走工程内的链接，`f_util` 28/28、`f_protocol` 55/55、`f_codec` 15/15 全绿），
  必须做“启动应用 + 看加载日志”级别的验证；排查时先 `readelf -d` / `nm -D`，别急着改加载器。

### 7.9 零散遗留（低优先）

- ✅ **已重构为多变体实现（2026-10-04）**：新增通用引擎 `f_util/src/CrcEngine.cj`（width/poly/init/refin/refout/xorout，
  参数口径同 [RevEng CRC catalogue](https://reveng.sourceforge.io/crc-catalogue/)，表在构造时现算、内部 UInt64 寄存器 + mask 截宽），
  三个宽度各自包装成类：`Crc16`（24 个变体）/`Crc32`（11 个）/`Crc64`（6 个），每个变体都带目录检查值，
  由 `crc_check_test.cj` 遍历 `CrcXX.all` 逐个核对（`"123456789"`）。
  **顶层函数按最常用变体**（2026-10-04 拍板）：`crc16`=**CRC-16/MODBUS**、`crc32`（含 `crc32Init/Update/Finish`）=**CRC-32/ISO-HDLC**、
  `crc64`=**CRC-64/REDIS**；`crc32*` 的语义与重构前完全一致（f_protocol 帧校验、f_store WAL 校验不受影响）。
  两个坑已在实现里注明：① 反射表要按 LSB-first 直接生成（只反射多项式，不能漏索引反序）；② 反射变体的 `init`
  在 catalogue 里是"非反射表示"，要整体反射后再作为寄存器初值（非对称 init 如 `0x89EC` 会算错）。
  暂未收录（参数待核对，宁缺勿错）：`CRC-16/A`、`CRC-64/NVME`——加一个变体只需一行并带上检查值，用例会自动核对。
- `crc64`（`f_util`）：复制粘贴 bug 早已修（`02d57ee0`）；**保留**（公开库函数，删掉属破坏性变更），
  现在它是顶层 `crc64()` 的默认实现（CRC-64/REDIS），"无使用方"的状态随之解除。
- ✅ `f_net` 用例已修（2026-10-04）：`src/test/f_net_tcp_test.cj`、`socket_params_test.cj` 从旧泛型签名
  （`Server<Message, EncodedMessage, Message, String>` …）迁移到 `Server<T>` / `Client<T>`
  （`Server<T>.builder(...).reuseAddress(true).build()`、`spawn { server.start({ _, req => ... }) }`、
  `Client<T>.builder(...).noDelay(true).build()`、`client.transfer(msg, timeout)`），并按新的服务端行为改写断言：
  **PING 由服务端内置回 ACK（不进 executor）**，业务请求-响应另用 SUBSCRIBE→RESP 覆盖。
  实测 `cjpm test` = **14/14 通过**（含 `Array<Int64>` 载荷逐字节往返、accept 后 `SocketParams.populate` 不抛）⇒
  **f_net 的读取/发送路径重新有了可执行覆盖**（此前只能靠 demo 运行验证）。

### 7.10 业务级 E2E 的完整断链（2026-10-03 逐层定位，共 10 层，**已跑通**）

修完 7.7 后 `./boot.sh runClient 127.0.0.1:1203` 的失败点逐层后移，每层都是一个独立缺陷：

| # | 层 | 现象 | 根因 | 处置 |
| --- | --- | --- | --- | --- |
| 1 | demo | 服务端处理 SUBSCRIBE 时 `params[0]` 越界 | 主机列表订阅写成 `Message.subscribe(data: true)`（**裸 Bool**），而服务端要求载荷是 `RPCMessage`（再取 `params[0]`）；`Message.subscribe<T>(data!)` 是泛型直通、不包一层 | 改为 `Message.subscribe(data: RPCMessage.subscribe(true))`（同文件另一处本来就这么写） |
| 2 | 编解码 | 响应带回的消息 id 与请求不同（实测相差整 8 小时） | `DefaultCodec.encode(DateTime)` 用 `value - DateTime.UnixEpoch`（与时区相关），解码用 `UnixEpoch + duration` ⇒ 时刻偏移；`MessageID` 的 hash/相等又按带时区的 `DateTime` 比较 ⇒ `futures` 永远查不到 | 改用绝对时刻 `toUnixTimeStamp()` / `fromUnixTimeStamp()`；`MessageID` 的 hash/相等按绝对时刻；新增用例 `messageIdSurvivesFrameRoundTrip`（修前必失败） |
| 3 | f_concurrent | 服务端处理完了，但响应**从不回**客户端（reader 侧只收到 PING/ACK，0 个 RESP） | `ExecutorFuture.get(default)` 在任务 `finished` 后直接 `return default()`，**丢掉 result** | finished 后先返回 result，无结果才用 default |
| 4 | f_net 客户端 | 拿到响应后在 `String.tryFromData` → `DataObject.toString` 段错误 | reader 用 `Message.decode<T>`（T=RPCMessage）解码**所有**消息；`Array<String>`/`Array<ServiceMeta>` 响应被宽松转换成字段为空的 RPCMessage ⇒ 后续转换踩空对象 | reader 改中性解码 `Message.decode<DataAny>`；并补"响应无等待者"的 DEBUG 日志（此前完全静默） |
| 5 | f_rpc 服务端 | 服务列表订阅返回 `[]` | `ServiceHub.register` 的接口遍历把 `fountain::` 前缀一律当框架接口排除，而 demo 接口 `fountain::rpcdef.EchoRPC` 恰是这个前缀 ⇒ 永远遍历不到 ⇒ 骨架注册不进去（日志里只有 class 行、没有 interface 行） | 只排除 `std.`/算子接口（真正决定注册的是 `getInstanceFunction` 判定） |
| 6 | demo | 骨架注册后服务列表仍是 `[]` | `EchoPOImpl <: EchoPO` —— 继承的是**数据模型**，根本没实现 RPC 接口 `EchoRPC` | 改为 `<: EchoRPC` |
| 7 | f_rpc 客户端 | 发现循环第一轮之后每轮抛 `Client is closed` | 发现用的 `clients` 建在 `while(true)` 之外，第一轮末尾 `close()` 后第二轮起 `transfer` 直接抛 | 每轮重建（`createClient()` 移进循环） |
| 8 | f_rpc | 服务找到了却立刻 `retry count exceeded` | `if(tried >= retryCount)`，而 `retryCount` 默认 0、`tried` 从 0 起 ⇒ **首次尝试就被判超限** | 改为 `tried > retryCount`（放行首次尝试） |

**链路已推进到**：客户端能连上 → 能发现服务（`metas=2`）→ 能把 CONSUME 发到服务端；服务端骨架也已注册。

**第 10 层（最后一层，已修）**：服务端解码 CONSUME 载荷时曾抛（原始证据）：
```
NoneValueException: Value does not exist.
  at std.collection.concurrent.ConcurrentHashMap::[]
  at fountain::f_codec.default.DefaultCodec::decodeData (DefaultCodec.cj:850 ← 830 ← 858)
  at fountain::f_codec.default.DefaultCodec::decode (DefaultCodec.cj:949)
  at fountain::f_protocol.default.Message::decode (Message.cj:277)   ← 解码 data 字段
  at fountain::f_net.server.Server::start::lambda.0 (server.cj:125)
```
即 `DefaultCodec` 重建 `@DataAssist` 对象时，**"类型hash → creator"注册表里没有该类型**（服务端没见过客户端侧构造的某个类型）。
**第 10 层（最后一层）的根因与处置**：不是"hash 算法不一致"，而是**注册时机** —— 类型hash→creator 注册表
只在该进程**编码过该类型**时才登记（`encode` 的 `SimpleDataObject` 分支 `addIfAbsent`），而解码侧用下标直接取值 ⇒
只解码不编码的一侧（客户端第一次收响应、服务端第一次收请求）必然踩空。处置：

| 改动 | 内容 |
| --- | --- |
| `f_codec` | `decodeData` 的 OBJECT 分支改为显式 `CodecException`，报出缺失的哈希并指出补救办法（原来抛 `NoneValueException`，上层再一包装就成了难以定位的错误） |
| `rpcdef`（两端共享模块） | 加 `private let _ = DefaultCodec.registerType<EchoPO>()` —— `registerType<T>()` 早已存在却**从未被调用**，显式注册一次即可覆盖两侧 |
| `frpcdemo/cjpm.toml` | 增加 `fountain::f_codec` 依赖 |

**✅ 2026-10-03 业务级端到端跑通**（`./boot.sh runServer 1203 127.0.0.1:1203` + `./boot.sh runClient 127.0.0.1:1203`）：
- 客户端打印分隔线 ×2 与 JSON：`{"a":100,"b":"hello world","c":false,"d":2.71828...}`；
- 服务端：`[FOUNTAIN_RPC.Skeleton.CONSUME(8)] ...; {"param":{...echo...},"result":{...},"consumed":"582us246ns"}`；
- `Init Image fail` **0**、客户端不再崩溃（跑到超时被杀，exit 124）。

**影响**：`frpcdemo` 的业务级端到端**已可用** —— 这也是 7.7 的最终验收。

**补充（2026-10-03，`ServiceMeta` 改注解版）**：第 6 条的实现从"手写 `hashCode`/`==`"改为注解版 ——
`@DataAssist[fields props hash equal]` + 在 `weight` 上 `@DataExclude[equal hash]`。改用注解的过程中查出并修掉两个 `@DataAssist` 宏缺陷：

1. **集合字段按身份哈希**：`Array<T>`/`ArrayList<T>` 自身满足 `Hashable`，默认 `hashCode` 是**身份**哈希 ⇒
   `argTypeNames` 内容相同但实例不同时哈希不同。实测给 `HashBuilder` 加集合重载**没用**（抢不过
   `append<T>(arg: T) where T <: Hashable`），改为在生成的 `hashCode` 里对集合字段用 `字段.toString()` 参与哈希
   （碰撞只会多一次 equals 检查）。
2. **`@DataExclude[hash]`/`[equal]`/`[compare]`/`[tostring]` 对私有 var 静默失效**：`generateProps` 会把私有字段改名成
   `<name>_`，而这些生成器都在改名**之后**运行，排除集合里只有源码名 ⇒ 匹配不上（`ServiceMeta.weight` 因此仍参与比较：
   实测两个内容相同的 meta `hashCode` 不同、`==` 为 false ⇒ `services`/`hub` 查表落空）。修法：登记排除项时同时登记改名后的键。

回归用例 `ServiceMetaIdentityTest.equalMetaWithDistinctArgTypeArraysMustMatch`（f_rpc **2/2**）覆盖这一组合；
demo 端到端与之前一致：分隔线 ×2、客户端 JSON、服务端 `CONSUME(8)`、`Init Image fail` 0。
协议/消息层行为另有 `f_protocol` **58/58** 用例覆盖（含帧长自洽与消息 id 往返）。

### 7.11 对象类型的注册应由框架自动完成（✅ 2026-10-04 已实现）

- 原问题：跨网络传输的对象类型（`@DataAssist` 生成的类）必须在**每一侧**调用 `DefaultCodec.registerType<T>()`，
  否则第一次解码该类型就会失败（7.10 第 10 层）。原先靠 demo 在 `rpcdef` 里手工注册。
- **已实现**：`@RPCStub` / `@RPCSkeleton` 展开时自动为**参数与返回类型**生成登记调用
  （类型收集在 `f_rpc/src/macros/TypeRegistration.cj`；登记走新公开的 `f_rpc.base.registerRPCType<T>()`）。
  实现过程中试过并**排除**的两条路（均有实测结论）：
  1. 直接生成 `DefaultCodec.registerType<X>()` —— 它的约束是 `T <: Object & ObjectData<T> & DataFields<T>`，
     而宏是 token 级的、拿不到类型约束：参数/返回类型是 `Int64`/`String`/`Unit`/集合的接口会**编译失败**；
  2. 「同名泛型函数 + 带约束版 + 无约束兜底版」靠重载选择 —— 编译器明确报
     `generic constraints are not involved in the overloading`（约束不参与重载求解），此路不通。
  因此生成的是**无约束**的 `registerRPCType<X>()`：运行时用反射判断 X 是否有静态 `dataFields()`
  （`@DataAssist[fields]` 必生成），有则把「限定名 + 创建者」交给新增的
  `DefaultCodec.registerType(qualifiedName:creator:)`（键与 `registerType<T>()` 一致，两种方式可混用）；
  非对象类型直接跳过 —— 它们走各自的 dataType 分支，本来就不需要登记。
- **验证**：把 demo 里手工的 `DefaultCodec.registerType<EchoPO>()` 删掉后，
  `./boot.sh runServer 1203 127.0.0.1:1203` + `./boot.sh runClient 127.0.0.1:1203` 的业务级 E2E **仍然跑通**
  （客户端打印 JSON、服务端 `CONSUME(8)`、两侧 `not registered` 0 次）⇒ 自动登记确实生效。
- ✅ **嵌套类型也已覆盖（同日第二轮）**：`@DataAssist[fields]` 展开时在**包初始化**处生成
  `DataTypeRegistry.registerDataType<Klass>()`（纯内存操作，不做 I/O、不读配置），把「限定名 → 创建者」登记进
  **f_data 自己的注册表**（新增 `f_data/src/base/DataTypeRegistry.cj`，因此不构成 f_data → f_codec 的环）；
  `f_codec` 在解码 OBJECT 未命中时按名字补算 murmur（与编码侧同规则）并拉取该表后重试
  （`DefaultCodec.pullRegisteredTypes()`，用注册表条目数当「版本」避免每次未命中都遍历全表），仍缺才抛原来的 `CodecException`。
- 两条登记路径的分工（**都保留**，覆盖不同集合）：RPC 宏那条登记**顶层**参数/返回类型，连**手写**的
  `ObjectData` 实现也覆盖得到；`@DataAssist` 自登记覆盖**全部**宏生成类型（含嵌套），是嵌套字段的唯一依靠。
- 嵌套的验证（decisive）：demo 模型加了 `EchoPO.inner: InnerPO` —— `InnerPO` **不是**任何 RPC 方法的顶层参数/返回类型，
  RPC 宏够不着它。E2E 客户端打印的 JSON 为
  `{"a":100,"b":"hello world","c":false,"d":2.71828…,"inner":{"tag":"inner-default","count":7}}`，
  服务端 `CONSUME(8)` 的 `param`/`result` 里同样有 `inner`，两侧 `not registered` 0 ⇒ **嵌套解码确实由自登记兜住**。
- 已知不覆盖：**泛型** `@DataAssist` 类（文件级拿不到类型实参：`Foo` 不是类型、`Foo<…>` 才是），
  这类类型仍需在解码侧手工 `DefaultCodec.registerType<Foo<…>>()`。

### 7.12 `f_pool` 全量用例偶发 SIGSEGV（2026-10-03 观察到一次，未复现）

- 现象：`f_pool` 全量 `cjpm test` 的某一次运行中，`concurrentBorrowNeverSharesBuffer` 触发 **SIGSEGV**；
  栈顶落在 `fountain::f_pool` 的 `UnitKeyPool.size`，表现为**运行时泛型 MTable 空指针**（对象/虚表字段未初始化）。
  同一次会话内立刻重跑 ⇒ `TOTAL: 22, PASSED: 22, FAILED: 0`，其后多轮复验（含 2026-10-02 的 22/22）均通过。
- 证据强度：**只观察到一次，未保留完整栈与日志**，没有稳定复现路径 ⇒ 当前判定为**偶发**，不能排除环境/调度因素。
- 影响面：`f_pool` 是 f_codec / f_net 的缓冲池底座。若确有竞态，症状会是**随机崩溃**而不是可复现的用例失败，
  排查成本高；反之若只是环境抖动，则会白白背上一个"疑案"。
- 待办建议：
  1. 再现时**先留全量与完整栈**（`cjpm test 2>&1 | tee`），并记录当次是否并发跑过其它构建/用例；
  2. 重点确认 `UnitKeyPool.size` 读到的实例是否来自**未初始化完的静态/共享对象**（MTable 空指针 ⇒ 对象头未就绪）；
  3. 用 `-j1`（串行）与默认并行各跑 N 轮做对照，区分「用例间互相干扰」与「单用例自身竞态」。
- **复现尝试（2026-10-04）**：按待办第 3 条做了对照 —— 默认并行 **5 轮** + `cjpm test --parallel 1` **2 轮**，
  共 7 轮全部 `TOTAL: 23, PASSED: 23, FAILED: 0`、退出码 0，无 SIGSEGV、无崩溃进程 ⇒ **仍未复现**。
  结论：不能据此判定"已修复"（触发条件依旧未知）；后续再现时按上面第 1、2 条留现场。
- **自愈机制（2026-10-04 落地）**：根因仍不可复现，因此按"让池在单点故障下继续服务 + 让下一次崩溃可诊断"加固：
  1. **回调异常不再破坏账目**（`SyncDeque.remove/append/prepend` + `discardItem`）：`checker` / `destroier`
     抛异常时，该项按"校验不过"结清（销毁 + `out`/`s` 一起还原）后再抛出 —— 否则它会永久挂在 `out` 上：
     池项凭空消失、池越用越小。用例：`testBorrowCheckerThrowingMustNotLeakElement`、
     `testReturnCheckerThrowingMustNotLeakElement`、`testDestroyerThrowingMustNotBreakAccounting`。
  2. **主动审计自愈**（`audit()` 链路：`SyncDeque` → `BasePool` → `IKeyPool`）：巡检线程每轮调一次，
     不必等某个 `get` 取不到项才自愈；`BaseKeyPool.audit()` 还会把全局 `s` 与各 key 队列之和校正一致。
     用例：`testAuditHealsStrandedWithoutBorrowAttempt`、`auditRunsFromSchedule`。
  3. **后台维护线程不许静默退出**（`KeyPool` 的创建/巡检线程加看护循环：异常记 WARN、意外退出则重开并计数），
     否则空闲回收、minSize 补足、审计自愈会永久停摆。用例：`scheduleSurvivesCallbackErrors`。
  4. **构造完成栅栏**（`KeyPool.constructed` + `Condition`）：后台线程在构造函数返回前不许碰 `this`。
     7.12 的栈顶是"运行时泛型 MTable 空指针"、疑似对象未构造完就被别的线程使用，这条是针对性兜底。
  5. **崩溃取证**（新增子包 `fountain::f_pool.diagnostics.PoolDiagnostics`）：自愈动作与借还都记数
     （`snapshot()` / `dump()`）；首次建池时装一次 SIGSEGV / SIGABRT 处理器 —— 致命信号时先打印
     `[FOUNTAIN_POOL.crash] fatal signal=…, pools=…/… items=+… borrow=… callbackErr=… strandedRevived=… bookkeepingHealed=… scheduleRestarts=…`
     再 `exit(134)`，把"偶发崩溃零现场"变成"至少有一行统计"。可用 `PoolDiagnostics.uninstallCrashHandler()`
     交还信号处理，或把 `CRASH_DUMP_ON_FATAL` 置 false。用例：`testDiagnosticsSnapshotTracksActivity`。
     **输出通道**：除信号处理器里那一行，f_pool 的常规告警/统计都走 f_log
     （`PoolDiagnostics.warn/error` 转发、`dump()` 走 WARN）—— `SyncDeque` 在最底层，反向 import 父包的
     logger 会形成包环，所以统一经 `fountain::f_pool.diagnostics` 转发；只有崩溃取证那一行保留 `println`
     （f_log 是"队列 + 独立写线程"，崩溃时可能死锁或丢行）。查过 `f_pool`/`f_codec`/`f_net`/`f_protocol`/`f_rpc`
     的非测试代码：除这一处外已无 `println`/`print`/`Console.*`/`printStackTrace`。
- **验证**：`f_pool` **36/36**（原 29/29 + 7 个新用例）；`fdemo` 全量构建 `BUILD_EXIT=0`、`f_rpc` 用例 2/2。
- 未关闭的部分：**根因未证**（仍算"偶发"，不声称已修）。下次再现时按上面待办第 1、2 条留现场，
  并优先看 `[FOUNTAIN_POOL.crash]` 那行统计 —— 尤其 `bookkeepingHealed` / `strandedRevived` / `scheduleRestarts`
  是否为 0（为 0 说明池的账目与线程都正常，崩溃更可能出在泛型 MTable/类型信息侧；不为 0 则有池内线索）。

### 7.13 `f_store` 的 6 个 WAL 用例 ERROR（**既有问题**）：✅ 已修（2026-10-04）

- 现象：`f_store` 全量 `cjpm test` = `TOTAL: 204, PASSED: 198, ERROR: 6`（`FAILED: 0`），6 个 ERROR 全在 WAL：
  `walChecksumCorruptionSingleRecord` / `walChecksumCorruptionConsecutive` / `walRecoverEmptyAndCorruptedMixed`
  （`WALWALReaderTest`），`walAppendAndRecover` / `walAppendWithExpireAt` / `walTombstoneRecord`（`WALTest`）；
  同族的 `StoreIntegrationTest.testWALRecovery`、`WALRecordTest`、`WALTest.walSyncCloseRace` 都通过。
  **与本轮 CRC 重构无关**：`git stash push --include-untracked -- f_util`（回到 HEAD 的旧实现）后重跑，同样 6 个。
- 定位手段：Cangjie 的 unittest 只标 `[ ERROR ] CASE:`、**不打异常详情**（`--verbose` 也不打），
  于是加了个临时诊断用例（复刻这两条路径 + 分步 `println`），跑完整套件时它的输出才被打印出来：
  ```
  [diag] 4) exists(path)=true
  [diag] 5) size=67108864        ← 打印完这一步就死了
  ```
- **根因：把「预分配文件」按文件长度整读，撑爆堆**。`WAL` 建在 `f_io.SegmentedLog` 上，
  segment 会按 `maxFileSize`（默认 **64MB**）**fallocate 预分配 + mmap** ⇒ `file.info.size`/`file.length`
  永远是 64MB，而真实数据只有一百多字节。这些用例却按文件长度整读（`Array<Byte>(fileSize)` + `read`），
  损坏用例还整读整写 ⇒ 每次 64MB（`bytes[offset..]` 切片再复制一份）⇒ 与 `ConcurrencyTest`（66s 重载）并发时
  堆被吃穿 ⇒ 抛异常、表现为 ERROR。单独跑（内存宽裕）同一路径**通过**，所以容易误判为"偶发/并发问题"。
- 修法（**只在测试侧**，不动实现）：
  1. `WAL_test.cj::readRecords` 改成只读**有界前缀**（64KB）再解析，不按文件长度整读；
  2. `WALReader_test.cj` 的 3 个损坏用例改成 `seek(offset) + write([byte])` **就地改 1 字节**，不整读整写。
  原则：**预分配文件的实际数据长度不能从 `file.info.size` 推断** —— 需要真实长度时走 `SegmentedLog` 的游标/mmap 视图。
- 验证：`f_store` **204/204**（`FAILED: 0, ERROR: 0`, `EXIT=0`）。

### 7.14 `f_store` 全量用例在 `/tmp` 留约 4GB 残留：✅ 已修（2026-10-04）

- 现象：跑完一次 `cjpm test`，`/tmp/f_store_test` 约 **3.9~4.1GB**、`/tmp` 合计 4.5GB；里面是几十个
  `Concurrency_*` / `Integration_*` / `Store_*` / `PrefixIterator_*` / `SSTable_*` 目录，每个含 64MB
  预分配文件（`SegmentedLog` 按 `maxFileSize` fallocate + mmap）。
- 原因：这些用例的 `getTestDir()` 只在自己**开始时**清目录（start-clean），结束时（尤其中途失败）不管；
  WAL 用例的 `cleanWAL()` 同理 ⇒ 每跑一次就累积一批。
- 修法：新增测试专用文件 `f_store/src/TestTmpDirs_test.cj`（`_test.cj` 结尾 ⇒ 只在测试构建里编译，不进库产物）：
  `/tmp` 下以 `f_store` 开头的顶层目录都视为本模块用例的临时数据，在 **包初始化（用例开始前）** 与
  **进程退出** 各清一次（`Directory.walk('/tmp')` 是非递归的 ⇒ 只处理顶层项 + 前缀匹配）；
  需要保留现场排查时把 `KEEP_TEST_TMP_DIRS` 置 true。一处改动覆盖所有现有目录，新增用例沿用 `f_store` 前缀即可自动纳入。
- 验证：`f_store` **204/204**（`EXIT=0`）；运行前后 `/tmp` 都是 **150M**、运行后 `/tmp/f_store*` **为空**
  （修前每次运行 +3.9~4.1GB）。
- 注意：清理按前缀删 `/tmp/f_store*` ⇒ 不要在同一台机上并行跑两份 f_store 用例（先退出者会删掉另一份的目录）。
