# 任务：`readCapped` 读缓冲按线程复用

> TDD：先写用例（Red），再改实现（Green），最后跑门控基准并记录数字。
> 每个任务完成后独立提交；分支 `feature/reuse-jsonrpc-read-buffer`（AGENTS.md §5）。
> 本变更只改 `f_jsonrpc`，不新增依赖、不改配置与路由。

## T1 前置确认（不改代码）

- [x] 1.1 确认 `ThreadLocal` API：`ThreadLocal<T>()`、`get(): ?T`、`set(T)`、`set(None<T>)`；
      在 core 包默认可见、无需 import。先例：`f_base/src/FutureTask.cj:56`（声明）、
      `:77`（`get`）、`:253-257`（`set` / `set(None<...>)`）
- [x] 1.2 确认仓颉 `Array` 切片产生新数组（`f_util/doc/spec/accelerate-f-util-crc/design.md:181`），
      因此 `bytes.add(all: buffer[0..size])` 不会让线程缓冲逃逸
- [x] 1.3 确认并发模型：`JsonRpcClient.callAsync`（`JsonRpcClient.cj:94-98`）用 `spawn` 起新线程，
      `readCapped`（`308-332`）是每次响应的唯一缓冲创建点；`call/callAsync/batch/notify` 都会经过它
- [x] 1.4 记录基线分配：同线程 5000 次 `Array<Byte>(8192)` 的摊销分配，以及 64 B / 24583 B
      响应各 500 次 `send` 的 `allocPerCall`（临时探针，不入库）

## T2 新增测试（Red）

新增 `f_jsonrpc/src/client/ReadBufferReuse_test.cj`（包 `fountain::f_jsonrpc.client`）。
复用同包 `RawHttpServer` / `writeText` / `writeBytes`（`HttpJsonRpcTransport_test.cj:31,123-142`）；
`responseOf` 是 `private`，在本文件内自行拼响应头。

- [x] 2.1 Red：`testReadBufferIsReusedOnSameThread` —— `readBuffer()` 连续两次返回同一实例
      （写哨兵 `0x5A` 后第二次仍能读到），且 `size == 8192`
- [x] 2.2 Red：`testReadCappedUsesThreadBuffer` —— 先 `readBuffer()[0] = 0`，`send` 一次后
      `readBuffer()[0] == UInt8(123)`（`{`），证明读路径确实使用线程缓冲
- [x] 2.3 Red：`testStaleTailDoesNotLeak` —— 把整块缓冲预热为 `0xFF`，再读 64 B 响应，
      结果长度 64、内容逐字节正确
- [x] 2.4 Red：`testReadBufferIsolatedAcrossThreads` —— `Barrier(3)`；两个 `spawn` 各填满
      `0xA1` / `0xB2`，同步后各自校验整块；主线程断言两个 `Future<Bool>` 都为 `true`
- [x] 2.5 Red：`testConcurrentCallsGetIntactResponses` —— 8 线程 × 5 次 `callAsync`；
      服务端每次 `sleep(10ms)` 后返回约 9 KiB、带唯一 seq 的响应；每个结果以 `<seq>|` 开头、
      填充字节与 seq 对应；共 40 次
- [x] 2.6 Red：`testMultiChunkResponseIsExact` —— 响应体长度取 `8191 / 8192 / 8193 / 24583`，
      分 4 次写；断言返回长度精确、内容逐字节一致
- [x] 2.7 Red：`testSmallResponseUnaffected` —— 64 B 响应长度与内容正确
- [x] 2.8 Red：`testReturnedBytesAreIndependentOfBuffer` —— 拿到返回数组后把 `readBuffer()`
      全填 `0xFF`，断言返回数组不变
- [x] 2.9 运行：`cd f_jsonrpc && cjpm test --filter ReadBufferReuse`，
      2.1 因 `readBuffer` 未定义而编译失败（Red）

## T3 实现（Green）

- [x] 3.1 在 `JsonRpcClient.cj` 增加 `private const READ_BUFFER_BYTES: Int64 = 8192`
- [x] 3.2 `HttpJsonRpcTransport` 增加 `private static let threadReadBuffer = ThreadLocal<ReadBufferHolder>()`，
      缓冲由私有引用类型 `ReadBufferHolder` 持有（直接存 `Array<Byte>` 每次 `get()` 装箱 55 B，
      见 `design.md` §10.3 的归因测量）
- [x] 3.3 增加包内可见 `static func readBuffer(): Array<Byte>`：`get()` 命中返回，未命中创建并 `set`；
      注释写明「包内可见，不属于公开 API」
- [x] 3.4 `readCapped` 的 `let buffer = Array<Byte>(8192, repeat: 0)` 替换为 `let buffer = readBuffer()`，
      其余逐字不动（循环、`total > cap`、`bytes.add(all: buffer[0..size])`、`bytes.unsafeData()`）
- [x] 3.5 在 `readCapped` 文档注释中固定「同线程不可重入」的前提（单次调用内不执行用户代码）
- [x] 3.6 检查无新增 `public` 符号：`ClientOptions` / `JsonRpcClient` / `JsonRpcTransport` /
      `HttpJsonRpcTransport` 的公开签名逐字不变
- [x] 3.7 运行：`cd f_jsonrpc && cjpm test --filter ReadBufferReuse` 全绿

## T4 分配基准（`F_JSONRPC_BENCH=1`）

- [x] 4.1 `benchEnabled()` 门控 + `settleGc()`（`gc(heavy: true)` 后等 `getGCCount()` 连续 3 次不变）
- [x] 4.2 分配量 = `(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)`，5 样本中位数
- [x] 4.3 `case=reuse`：5000 次 `readBuffer()`，断言 `allocPerOp <= 64`，且 `reuse * 16 < fresh`
- [x] 4.4 `case=fresh`：5000 次 `Array<Byte>(8192, repeat: 0)` 并触碰首字节，只打印
- [x] 4.5 `case=send_small`（64 B × 500）与 `case=send_multichunk`（24583 B × 500）串行 `send`，
      打印 `allocPerCall` / `nsPerCall`
- [x] 4.6 `case=send_concurrent`（8 线程 × 250 次）打印总分配与墙钟吞吐
- [x] 4.7 未设 `F_JSONRPC_BENCH=1` 时打印 `SKIP:` 并返回，默认 `cjpm test` 不受影响
- [x] 4.8 跑一次，把输出写入 `design.md` §10「实测记录」

## T5 回归

- [x] 5.1 `f_jsonrpc/src/client/HttpJsonRpcTransport_test.cj` 的 9 条既有用例**一字不改**、通过
- [x] 5.2 `cd f_jsonrpc && cjpm test` 全绿
- [x] 5.3 `cd f_jsonrpc && cjpm build` 不新增 WARNING
- [x] 5.4 检查 `git diff f_jsonrpc/src/client/JsonRpcClient.cj`：只涉及新增常量 / `static let` /
      包内 `static func` 与 `readCapped` 的一行替换

## T6 产物与提交

- [x] 6.1 确认 `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/` 与
      `openspec/changes/reuse-jsonrpc-read-buffer/` 逐文件一致（`diff -ru` 无输出）
- [x] 6.2 分支 `feature/reuse-jsonrpc-read-buffer`，按「测试 + 实现」与「基准 + 实测记录」
      分成两次提交（均在有单元测试之后）
