# 设计：`readCapped` 的 8 KiB 读缓冲按线程复用

## 1. 目标与约束

**目标**：消除 `HttpJsonRpcTransport.readCapped` 每次响应新建 8192 B 缓冲的重复分配，
同时保证并发调用（`callAsync` 的 `spawn`）不共享可变缓冲、返回字节与现状完全一致。

**硬约束**：

| 约束 | 判定方式 |
| --- | --- |
| 返回字节与「每次新建缓冲」逐字节一致 | 分块读取用例 + 既有 `HttpJsonRpcTransport_test` 一字不改 |
| 并发调用互不污染 | 8 线程 × 5 次 `callAsync`，服务端返回带唯一序号的大响应 |
| 线程隔离 | 两线程各填 8 KiB 标记，`Barrier` 后各自读回 |
| 残余字节不泄漏 | 缓冲预热 `0xFF` 后读小响应，结果长度与内容精确 |
| 公开 API 不变 | `git diff` 中无 `public` 符号变化 |
| 不引入耗时门禁 | 基准只打印耗时，断言只用分配量 |

## 2. 现状与成本

`f_jsonrpc/src/client/JsonRpcClient.cj:308-332`：

```cangjie
private func readCapped(response: HttpResponse, cap: Int64): Array<Byte> {
    var initial: Int64 = 8192
    match (declaredLength(response)) {
        case Some(declared) =>
            if (declared > 0 && declared <= cap) {
                initial = declared
            }
        case _ => ()
    }
    let bytes = ArrayList<Byte>(initial)
    let buffer = Array<Byte>(8192, repeat: 0)     // ← 每个响应一次
    var total: Int64 = 0
    while (true) {
        let size = response.body.read(buffer)
        if (size <= 0) {
            break
        }
        total += size
        if (total > cap) {
            throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR, 'response body exceeds ${cap} bytes')
        }
        bytes.add(all: buffer[0..size])
    }
    bytes.unsafeData()
}
```

调用链：`call` / `callAsync` / `batch` / `notify` → `sendWithRetry`（`159`）→
`transport.send`（`250`）→ `readCapped`（`279`）。也就是说**每个 RPC 请求**都会分配这块缓冲。

一次小响应（设响应体 `L` 字节）的堆分配：

| 项 | 无 `Content-Length` | 有 `Content-Length = L` |
| --- | --- | --- |
| 读缓冲 | 8192 B | 8192 B |
| `ArrayList` 原始数组 | 8192 B（`initial` 默认） | `L` B |
| `unsafeData()` 的最终复制 | `L` B | `L` B |
| 合计 | `16384 + L` | `8192 + 2L` |

`L = 100` 时，读缓冲分别占 50% 和 97%。大响应下它占比很小，但小响应是 JSON-RPC 的常态；
且这块内存不参与结果、不跨调用复用，是纯粹的分配 churn。

## 3. 方案对比

| 方案 | 并发安全 | 每调用缓冲分配 | 结论 |
| --- | --- | --- | --- |
| **A 现状**：每次 `Array<Byte>(8192)` | 是 | 8192 B | 否 |
| **B 实例字段** `private var buffer` | **否**：`callAsync` 的并发调用共享同一数组，互相覆盖 | 0 | 否（会串读） |
| **C `@ local!`**（`docs/LocalMode.md:316` 的次选） | 是 | 8192 B（local region） | 否（仍每次分配） |
| **D `static ThreadLocal<Array<Byte>>`** | 是（线程隔离） | 0（同线程复用） | **采纳** |
| **E 全局对象池** | 是（需锁） | 0 | 否（8 KiB 固定大小，锁争用与生命周期管理不划算） |

选 D 的理由：

- B 是 `docs/LocalMode.md:316` 的「优先字段复用」，但该建议没有考虑 `callAsync` 的 `spawn`；
  在本模块的并发模型下必须升级为线程本地。
- C 只改变分配位置，不消除分配；`readCapped` 的缓冲不逃逸、大小固定，没有必须走 local 的理由。
- E 对固定 8 KiB 的对象是过度设计：`ThreadLocal` 的查找成本约百纳秒级
  （`f_base/src/FutureTask.cj:53` 的实测口径），远低于一次锁竞争。

不用 `InheritedTaskLocal`：它的语义是「子任务继承父任务的值」，会让父子任务看到**同一块可变数组**，
正是本变更要避免的共享。

## 4. 详细设计

### 4.1 代码形态

文件顶部常量（与现状同值）：

```cangjie
private const READ_BUFFER_BYTES: Int64 = 8192
```

`HttpJsonRpcTransport` 内新增：

```cangjie
// 每线程一块读缓冲：callAsync 的 spawn 调用各自持有独立缓冲，
// 长生命周期线程（连接池 worker / 顺序调用）复用同一块。
private static let threadReadBuffer = ThreadLocal<ReadBufferHolder>()

/** 取当前线程的读缓冲；首次使用时按固定大小创建。包内可见：仅读路径与同包测试使用，不属于公开 API。 */
static func readBuffer(): Array<Byte> {
    match (threadReadBuffer.get()) {
        case Some(holder) => holder.data
        case None =>
            let holder = ReadBufferHolder(Array<Byte>(READ_BUFFER_BYTES, repeat: 0))
            threadReadBuffer.set(holder)
            holder.data
    }
}
```

**落地修正（由 §10.1 的归因测量驱动）**：`ThreadLocal` 直接存 `Array<Byte>` 时，`get()` 每次都要把
这个值类型装箱，实测 **55 B/次**（`-O0`），使 `case=reuse` 的 `allocPerOp=88` 冲破 §6.3 的 64 B 门限；
改存引用类型 `ReadBufferHolder` 后该路径回到循环基线（`case=reuse` 降到 32 B/次）。架构不变——
仍是线程私有、缓冲不逃逸、大小固定；变的只是 `ThreadLocal` 的存储类型。

```cangjie
/** 线程本地读缓冲的持有者。直接存 Array<Byte> 会触发每次 get() 的装箱分配。 */
private class ReadBufferHolder {
    ReadBufferHolder(let data: Array<Byte>) {}
}
```

`readCapped` 仅换一行：

```cangjie
- let buffer = Array<Byte>(8192, repeat: 0)
+ let buffer = readBuffer()
```

`ThreadLocal` 在 core 包默认可见，无需 import（仓内先例：
`f_base/src/FutureTask.cj:56` 声明、`:77` `get()`、`:253-257` `set(...)` / `set(None<...>)`）。

### 4.2 不变量

| 编号 | 不变量 | 保证方式 |
| --- | --- | --- |
| I1 | 缓冲线程私有 | `ThreadLocal`；不放进实例字段或普通静态字段 |
| I2 | 缓冲不逃逸 | 结果只经由 `buffer[0..size]` 切片复制；仓颉 `Array` 切片产生新数组 |
| I3 | 只消费已写前缀 | 循环体只用 `size`（`read` 的返回值），从不读 `buffer[size..]` |
| I4 | 同线程内不可重入 | `readCapped` 在单次调用内不执行用户代码，缓冲也不被保存到任何字段；调用返回即释放 |
| I5 | 大小固定 | `READ_BUFFER_BYTES` 不随 `cap` / `Content-Length` 变化 |

I4 是正确性的关键：若未来有人在 `response.body.read` 的调用链里插入回调并再次发请求，
同一线程会拿到同一块缓冲并被覆写。当前 stdx HTTP 客户端没有这种回调；本设计用注释固定这一前提，
并在 `readCapped` 的文档注释中写明「不得在读取回调中重入」。

### 4.3 生命周期与内存

- 首次使用时分配 8192 B 并挂到当前线程；线程退出时随 `ThreadLocal` 一起回收。
- 每个执行过响应的存活线程常驻 8192 B，与调用次数无关。
- 静态 `ThreadLocal` 被所有 `HttpJsonRpcTransport` 实例共享：同一线程上的多个 client 复用同一块，
  这是安全的（I1–I4），也把常驻量收敛到「每线程一块」而不是「每 client 每线程一块」。

### 4.4 为什么大小仍是 8192

- 改变块大小会改变 `read` 的调用次数与 `total > cap` 的越限量级，属于可观察行为变化，不在本变更内。
- 按 `cap` 或 `Content-Length` 定制缓冲会破坏复用（每个响应一个尺寸），也与「固定缓冲」矛盾。
- 8 KiB 与 `ArrayList` 的默认初始容量一致，沿用现状最易证明等价。

## 5. 等价性论证

对同一响应流，记第 `i` 次 `read` 写入 `n_i` 字节（`n_i > 0`），流结束返回 `<= 0`。

1. **结果构成**：新旧实现都按 `buffer[0..n_1] + buffer[0..n_2] + ...` 追加，且都使用 8192 B 的同一块
   缓冲大小，因此 `read` 可返回的上界相同；拼接结果都是流的完整内容。
2. **残余内容**：新实现进入循环前缓冲可能含上一轮数据，但循环只追加 `[0..n_i)`；
   `read` 返回 `n_i` 即表示前 `n_i` 字节已被本次写入覆盖。因此旧数据不可能进入结果。
3. **不逃逸**：`bytes.add(all: buffer[0..size])` 的实参是切片产生的新数组；
   `bytes.unsafeData()` 再复制 `[0..size]`。返回结果与线程缓冲没有共享存储，
   后续读取覆写缓冲不会改变已返回的数组。
4. **异常路径**：`total > cap` 时在追加前抛错，缓冲内容留在原地，下一次调用照常覆写；
   与旧实现（缓冲被丢弃）的可观察行为一致。
5. **并发**：不同线程的 `ThreadLocal` 值互不可见；同一线程内 `readCapped` 不可重入（I4）。
   因此任意并发调用序列下，每个调用的输入流与输出都不受影响。

唯一需要测试兜底的是第 2 条（残余前缀误用）与第 3 条（逃逸），见 §6 的
`testStaleTailDoesNotLeak` 与返回值后续可变性检查。

## 6. 测试设计

新增 `f_jsonrpc/src/client/ReadBufferReuse_test.cj`，包 `fountain::f_jsonrpc.client`。
复用同包的 `RawHttpServer`、`writeText`、`writeBytes`（`HttpJsonRpcTransport_test.cj:31,123-142`）；
`responseOf` 是 `private`，本文件内自行拼响应头。

### 6.1 用例清单

| 用例 | 步骤与断言 |
| --- | --- |
| `testReadBufferIsReusedOnSameThread` | `let a = readBuffer(); a[0] = 0x5A; let b = readBuffer()`；断言 `b[0] == 0x5A` 且 `b.size == 8192` |
| `testReadCappedUsesThreadBuffer` | `readBuffer()[0] = 0`；`transport.send` 一次（响应体以 `{` 开头）；断言 `readBuffer()[0] == UInt8(123)` |
| `testStaleTailDoesNotLeak` | 先把 `readBuffer()` 全填 `0xFF`；读 64 B 响应；断言结果长度 64、内容逐字节正确 |
| `testReadBufferIsolatedAcrossThreads` | `Barrier(3)`；两个 `spawn` 各自取缓冲并填满 `0xA1` / `0xB2`，同步后各自校验整块；主线程 `get()` 两个 `Future<Bool>` 并断言都为 `true` |
| `testConcurrentCallsGetIntactResponses` | 8 线程 × 5 次 `callAsync`；服务端每次 `sleep(10ms)` 后返回约 9 KiB 的 `{"jsonrpc":"2.0","id":1,"result":"<seq>\|<filler>"}`；每个结果以 `<seq>\|` 开头且填充字节全部等于该 seq 对应的字符；共 40 次 |
| `testMultiChunkResponseIsExact` | 响应体长度取 `8191 / 8192 / 8193 / 24583`，内容为 `'a' + 序号`；断言 `send` 返回长度精确、内容逐字节一致 |
| `testSmallResponseUnaffected` | 64 B 响应；断言长度与内容 |
| `testReturnedBytesAreIndependentOfBuffer` | 取到返回数组后，把 `readBuffer()` 全填 `0xFF`；断言返回数组不变 |

并发用例的服务端延迟用于制造真实重叠；断言只看内容完整性，不断言线程调度。

### 6.2 分块读取的构造

`RawHttpServer` 的 handler 先写响应头，再把 body 分 4 次写（每次约 `size / 4` 字节）。
客户端返回长度必须精确等于 body 长度——若实现错误地把整块 8192 B 追加进去，长度会变成 8192 的倍数。

### 6.3 分配基准（`F_JSONRPC_BENCH=1`）

沿用 `f_mcp` / `f_protocol` 的门控与测量写法：

- `benchEnabled()` 读 `F_JSONRPC_BENCH`，非 `1` 时打印 `SKIP:` 并返回；
- `settleGc()`：`gc(heavy: true)` + 等 `getGCCount()` 连续 3 次不变；
- 分配量 = 窗口内 `(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)`，取 5 个样本中位数
  （大对象分配会诱发 GC，只读存活堆会低估）；
- 输出一行：
  `JSONRPC_READBUF_BENCH case=... ops=... allocPerOp=... nsPerOp=... samples=...`

| 用例 | 参数 | 断言 |
| --- | --- | --- |
| `case=reuse` | 5000 次 `readBuffer()`，`sink ^= buf[0]` | `allocPerOp <= 64` |
| `case=fresh` | 5000 次 `Array<Byte>(8192, repeat: 0)` 并触碰首字节 | 只打印；用于证明对照组约 8192 |
| `case=send_small` | 500 次串行 `send`，响应体 64 B | 只打印 `allocPerCall` / `nsPerCall` |
| `case=send_multichunk` | 500 次串行 `send`，响应体 24583 B | 只打印；`allocPerCall` 不应随分块数线性增长 |
| `case=send_concurrent` | 8 线程 × 250 次 | 只打印总分配与墙钟吞吐 |

`reuse` 与 `fresh` 是唯一带断言的分配对照：`reuse * 16 < fresh` 且 `reuse <= 64`。
端到端用例包含请求构造、连接池、`ArrayList` 与最终复制，无法把 8 KiB 单独归因，
因此只记录数字，判定以 `reuse`/`fresh` 为准。

## 7. 验收

| 项 | 标准 |
| --- | --- |
| 等价性 | 新增 8 条用例全部通过；`HttpJsonRpcTransport_test` 9 条既有用例一字不改、通过 |
| 并发 | `testConcurrentCallsGetIntactResponses` 40 次调用全部成功且内容完整 |
| 分配 | 门控基准下 `reuse allocPerOp <= 64 B`，且 `reuse * 16 < fresh` |
| 回归 | `cd f_jsonrpc && cjpm test` 全绿；`cjpm build` 不新增 WARNING |
| 契约 | `git diff` 中 `JsonRpcClient.cj` 只新增常量 / 私有持有者类 / `static let` / 包内 `static func`，并把 `readCapped` 的一行替换为 `readBuffer()`；无 `public` 符号变化 |

## 8. 风险与回退

| 风险 | 处理 |
| --- | --- |
| 每请求 `spawn` 新线程时无分配收益 | 每线程首次仍分配一块，与现状等价；正确性不受影响（与 `f_protocol` §9 同一结论） |
| 线程常驻 8 KiB | 上界 `8192 × 执行过读的存活线程数`，随线程退出回收；对长生命周期线程是净收益 |
| 同线程重入会覆写缓冲 | 当前 `readCapped` 内无用户代码，结构上不可重入；在函数注释中固定该前提 |
| 静态 `ThreadLocal` 跨 client 共享 | 缓冲不逃逸、线程内非重入，安全；同时把常驻量收敛为每线程一块 |
| 基准受 `-O0` 与机器负载影响 | 耗时只打印；断言只用确定性的分配量 |
| `ThreadLocal` 的预热开销 | 首调用一次 8192 B 分配 + 一次 `set`；包含在 `send_small` 的 `allocPerCall` 中，可观测 |

**回退**：改动是单个文件内的局部替换与新增私有/包内符号，`git revert` 该提交即可恢复；
无数据、配置、协议影响。

## 9. 落地顺序

1. 确认 `ThreadLocal` API 与可见性（core 包默认可见；`f_base/src/FutureTask.cj` 先例）；
2. 确认 `Array` 切片复制语义（`f_util/doc/spec/accelerate-f-util-crc/design.md:181`）；
3. 写新增测试（Red：`readBuffer` 不存在，编译失败）；
4. 实现常量、`static let`、`readBuffer()`，替换 `readCapped` 的一行（Green）；
5. 跑门控基准，把输出写入 §10；
6. `cd f_jsonrpc && cjpm test` 全绿后独立提交。

## 10. 实测记录

环境：`aarch64-unknown-linux-gnu`、`Cangjie Compiler 1.3.0-alpha.20261118001016`、7 核、
`cjpm test` 默认 `-O0` 测试构建。口径均取 5 样本中位数，分配量按
`(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)` 计。

执行命令：

```bash
cd f_jsonrpc && F_JSONRPC_BENCH=1 cjpm test --filter '*ReadBufferReuse*' --show-all-output
```

### 10.1 改造前基线（临时探针，未入库）

同线程 5000 次 `Array<Byte>(8192)`；64 B / 24583 B 响应各 500 次串行 `send`：

| case | allocTotal | allocPerCall |
| --- | --- | --- |
| `fresh5000` | 46,810,320 | 9,362 |
| `send_small` | 10,330,584 | 20,661 |
| `send_multichunk` | 40,952,576 | 81,905 |

`fresh5000` 的 9,362 B/次 中约 8192 B 是数组本体，其余是测试循环自身的开销（见下表归因）。

### 10.2 改造后基准（`F_JSONRPC_BENCH=1`）

| case | ops | allocTotal | allocPerOp / allocPerCall | nsPerOp / nsPerCall | 样本 |
| --- | --- | --- | --- | --- | --- |
| `reuse` | 5000 | 160,000 | **32** | 465 | 5 |
| `fresh` | 5000 | 46,937,848 | 9,387 | 88,492 | 5 |
| `send_small` | 500 | 5,739,488 | 11,478 | 487,313 | 5 |
| `send_multichunk` | 500 | 33,121,272 | 66,242 | 558,454 | 5 |
| `send_concurrent` | 2000（8×250） | 23,950,920 | 11,975 | 38,716 | 1 次墙钟 |

- `reuse` 32 B/次 ≤ 64 B 门限，且 `32 × 16 = 512 < 9,387`（差一个数量级以上）✔
- `send_small` 从 20,661 降到 11,478（−9,183 ≈ 8192 B 读缓冲 + 噪声）✔
- `send_multichunk` 从 81,905 降到 66,242 ✔；剩余量随响应体长度走，不随分块数线性增长
- 耗时只作参考：`-O0` 测试构建，不代表生产数值

### 10.3 归因测量（决定了 §4.1 的落地修正）

同一 5000 次循环、同一 `AtomicInt64` sink，逐项剥离：

| 变体 | allocPerOp |
| --- | --- |
| 空循环（只 `sink.fetchAdd(1)`） | 0 |
| 循环 + 恒定数组下标（循环基线） | 17 |
| `ThreadLocal<Array<Byte>>` + `get()` + `match` | 72（基线外 **+55**） |
| `ThreadLocal<ReadBufferHolder>` + `get()` + `match` | 16（与基线持平，**0 额外**） |
| `readBuffer()` 取值后读 `[0]` | 88 |

结论：`ThreadLocal` 存值类型时每次 `get()` 都装箱；改存引用类型后读缓冲取用本身零分配，
`case=reuse` 的残余 32 B/次 是测试循环与下标访问的成本，不是读缓冲。

