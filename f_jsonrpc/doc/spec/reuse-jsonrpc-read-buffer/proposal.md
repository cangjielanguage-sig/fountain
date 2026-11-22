# 提案：`HttpJsonRpcTransport.readCapped` 8 KiB 读缓冲按线程复用

> **唯一入库副本**：`f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/`。`openspec/changes/reuse-jsonrpc-read-buffer/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份逐文件字节一致。
> 同步：以 `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/` 为准 `cp -a` 到
> `openspec/changes/reuse-jsonrpc-read-buffer/`（本机无 rsync）。
> 校验：`diff -ru f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer openspec/changes/reuse-jsonrpc-read-buffer` 无输出。

## Why

1. **每一次 RPC 响应都新建一块 8 KiB 缓冲，纯属一次性 churn**。
   `f_jsonrpc/src/client/JsonRpcClient.cj:318`：

   ```cangjie
   let buffer = Array<Byte>(8192, repeat: 0)
   ```

   `call` / `callAsync` / `batch` / `notify` 最终都会走
   `sendWithRetry` → `transport.send` → `readCapped`（`308-332`），于是**每个请求**都额外分配
   8192 B。对 100 B 的小响应（带 `Content-Length`）来说，这条路径的总分配约为
   `8192 + 2 × 100` B，读缓冲占了 **97%**；不带 `Content-Length` 时 `ArrayList` 的初始容量
   也是 8192，读缓冲仍占一半。大响应下这 8 KiB 可以忽略，但小响应是 JSON-RPC 的常态。

2. **`callAsync` 会 `spawn` 并发调用，所以不能用实例字段共享**。
   `JsonRpcClient.cj:94-98` 的 `callAsync` 直接 `spawn { call(...) }`，多个并发调用会同时进入
   同一个 `HttpJsonRpcTransport.send`。若把缓冲改成 `private var buffer`（`docs/LocalMode.md:316`
   的「优先字段复用」），两个线程会写入同一块数组：彼此覆盖、
   `bytes.add(all: buffer[0..size])` 复制到对方的字节，结果是响应体交错、JSON 解析失败，
   甚至解析出一个「格式合法但内容错误」的结果。**共享粒度必须是线程，不是 transport 实例。**

3. **结构性复用优于 local mode，且此处没有 local 的收益空间**。
   `docs/LocalMode.md:316` 对这条路径的结论是「优先字段复用；每次新建则 `@ local!`」；
   `docs/LocalMode.md:435` 进一步写明「`readCapped` 的 8 KB 读缓冲可直接复用，不需要 local」。
   字段复用被上一条否掉；`@ local!` 仍要每次分配，只是换到 local region 并且不参与跨调用回收，
   收益仅限分配器自身的成本。缓冲不逃逸、大小固定、生命周期可以长于单次调用，
   正好适合线程本地复用。

4. **复用不改变任何可观察语义**。读循环、缓冲大小（8192）、`total > cap` 的判定位置都不动；
   返回结果仍是从缓冲 `[0..size)` **复制**出来的独立数组（仓颉 `Array` 切片产生新数组，
   见 `f_util/doc/spec/accelerate-f-util-crc/design.md:181`）。唯一差别是缓冲不再每次清零；
   由于只读已写入的前缀，上一轮的残余字节不会进入结果。

5. **契约不能动**：`JsonRpcClient` / `ClientOptions` / `JsonRpcTransport` 的公开签名、
   `maxResponseBytes` 语义、分块读取与超限行为都必须保持。

6. **收益边界要诚实**。`ThreadLocal` 在长生命周期线程上稳定（连接池工作线程、服务端 worker、
   同线程顺序调用、测试线程），每次响应省 8192 B；如果调用方为每个请求 `spawn` 新线程，
   每线程首次使用仍要分配一块（与现状等价，不会更差也不会错）。这与
   `f_protocol/doc/spec/frame-encode-attrib/design.md:142` 的结论一致。

## What Changes

### A. 线程本地读缓冲（`HttpJsonRpcTransport` 内部）

- 新增固定常量 `READ_BUFFER_BYTES = 8192`（与现状同值，不改分块口径）。
- 新增 `private static let threadReadBuffer = ThreadLocal<Array<Byte>>()`：
  每个线程首次使用时懒创建一块 8192 B 缓冲，之后复用。
- 新增**包内可见**（非 `public`）的 `static func readBuffer(): Array<Byte>`：
  `get()` 命中直接返回，未命中则 `Array<Byte>(8192, repeat: 0)` 并 `set`。
  这个函数只服务读路径与同包测试，不属于公开 API。

### B. `readCapped` 只换缓冲来源

```cangjie
- let buffer = Array<Byte>(8192, repeat: 0)
+ let buffer = readBuffer()
```

循环、`total` 累计、`total > cap` 抛错、`bytes.add(all: buffer[0..size])`、
`bytes.unsafeData()` 全部逐字不动。`declaredLength` 预判与 `initial` 容量逻辑不动。

### C. 测试：新增 `f_jsonrpc/src/client/ReadBufferReuse_test.cj`

- **同线程复用**：`readBuffer()` 连续两次返回同一实例（哨兵字节保留）。
- **读路径确实用了线程缓冲**：先把 `readBuffer()[0]` 置 0，发一次请求后它变成响应体的首字节 `{`。
- **残余字节不泄漏**：把整块缓冲预热成 `0xFF`，再读一个小响应，结果必须逐字节等于响应体。
- **跨线程隔离**：两个线程各自填满 8 KiB 标记，`Barrier` 同步后各自读回，互不污染。
- **并发多响应隔离**：8 线程 × 5 次 `callAsync`，服务端每次返回约 9 KiB、带唯一序号的响应；
  每个结果都必须完整、序号与填充一致。
- **分块读取**：响应体取 `8191 / 8192 / 8193 / 24583` 四种长度，结果长度与内容逐字节精确。
- **小响应回归**：64 B 响应照常返回。

既有 `HttpJsonRpcTransport_test.cj` 的 9 条用例**一条不改**，作为行为不变的硬约束。

### D. 分配基准（`F_JSONRPC_BENCH=1` 门控）

- `case=reuse`：同线程连续取缓冲 5000 次，断言摊销分配 `<= 64 B/次`；
- `case=fresh`：同窗口内每次新建 8192 B 作为对照，只打印；
- `case=send_small`（64 B 响应）与 `case=send_multichunk`（3 × 8192 + 7 B）各 500 次串行调用，
  打印 `allocPerCall` / `nsPerCall`；
- `case=send_concurrent`：8 线程 × 250 次，打印总分配与墙钟吞吐；
- 未设门控时打印 `SKIP:` 并返回，常规 `cjpm test` 不受影响。

### E. 契约

- 无新增 / 修改 `public` 符号；`ClientOptions`、`JsonRpcClient`、`JsonRpcTransport`、
  `HttpJsonRpcTransport` 的公开构造与 `send` / `close` 签名全部不变。
- 不新增配置项；8192 是内部常量，不暴露。

## Impact

- **修改代码**：`f_jsonrpc/src/client/JsonRpcClient.cj`（新增 1 个常量、1 个私有持有者类、
  1 个 `static let`、1 个包内 `static func`；`readCapped` 改 1 行）。持有者类是落地时的必要性修正：
  `ThreadLocal` 直接存 `Array<Byte>` 每次 `get()` 要装箱 55 B（见 `design.md` §10.3）。
- **新增代码**：`f_jsonrpc/src/client/ReadBufferReuse_test.cj`（隔离 / 分块 / 分配基准）。
- **公开 API**：0 处变更。
- **依赖 / 配置 / 路由**：不改。
- **行为**：对任意响应，返回字节与现状逐字节相同；`maxResponseBytes` 的预判、流式超限、
  连接关闭时机均不变。
- **内存**：每次响应的读缓冲分配从 8192 B 降到 0（同线程复用时）；代价是每个执行过读的
  存活线程常驻 8192 B，随线程退出回收，上界为 `8192 × 线程数`，与调用次数无关。
- **风险**：`ThreadLocal` 对「每请求一个新线程」的场景没有分配收益（正确性不受影响）；
  线程缓冲的可重入性依赖「`readCapped` 在单次调用内不执行用户代码」这一结构事实。

## Out of Scope

- **不改 `ArrayList<Byte>` 的初始容量与最终拷贝**：`initial` 取 `Content-Length`（无则 8192）、
  `unsafeData()` 的 `[0..size]` 复制仍是每次调用的大头，但都跟响应体长度同阶，
  与「固定 8 KiB 的重复分配」不是同一类问题。
- **不改 `maxResponseBytes` 语义**：8 KiB 缓冲可能让超限检测越过 `cap` 最多 8191 B，
  这是现状行为，本变更不调整。
- **不做 `@ local!`**：缓冲不逃逸，local 只降低单次分配成本，无法消除分配；结构性复用已覆盖。
- **不引入全局缓冲池**：8 KiB 固定大小，池的锁争用与生命周期管理成本高于 ThreadLocal 的收益。
- **不把缓冲大小做成可配置项**：公开 API 不变，避免引入未经验证的配置面。
