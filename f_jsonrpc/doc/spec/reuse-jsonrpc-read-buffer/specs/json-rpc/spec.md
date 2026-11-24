# json-rpc

## Purpose

定义 `f_jsonrpc` 客户端读响应的结构性约束：HTTP 传输在同一线程内复用一块固定 8 KiB 读缓冲，
不同线程（含 `callAsync` 的 `spawn`）各自持有独立缓冲；复用不得改变响应字节、超限判定或公开 API。

## ADDED Requirements

### Requirement: 读缓冲线程私有且跨调用复用

`HttpJsonRpcTransport.readCapped` MUST 在同一线程的多次响应读取之间复用同一块固定 8192 B 的线程私有缓冲；缓冲 MUST NOT 逃逸，公开签名 MUST 保持不变。

缓冲大小 MUST 固定为 8192 B，MUST NOT 随 `cap` / `Content-Length` / 响应体长度变化。并发读取（包括 `callAsync` 的 `spawn`）MUST 各自使用独立缓冲，MUST NOT 通过实例字段或普通静态字段共享可变缓冲。

#### Scenario: 同线程复用

- **WHEN** 同一线程连续两次发起读取
- **THEN** 两次使用同一块缓冲实例（第二次读取不会新建 8192 B 数组）

#### Scenario: 跨线程隔离

- **WHEN** 两个线程同时读取各自的响应
- **THEN** 两个线程的缓冲互不重叠，任一方的写入不会出现在另一方的结果中

#### Scenario: 并发 `callAsync`

- **WHEN** 同一个 `JsonRpcClient` 上 8 个 `callAsync` 并发执行，服务端为每次请求返回约 9 KiB 的响应
- **THEN** 每个调用都得到完整、互不交错的响应体，没有 JSON 解析错误或内容串读

### Requirement: 复用不改变可观察结果

读缓冲的复用 MUST 对调用方完全透明。

1. 对同一响应流，返回字节 MUST 与「每次调用新建并清零缓冲」的实现逐字节相同；
2. 循环 MUST 只消费本次 `read` 实际写入的前缀 `buffer[0..size)`，
   MUST NOT 把上一轮遗留的尾部字节追加进结果；
3. `Content-Length` 预判、`total > cap` 的流式超限判定、异常类型与抛错时机 MUST 保持不变；
4. 空响应、恰好等于 `cap` 的响应、跨多次读取的长响应 MUST 保持现有行为；
5. `send` 返回的 `Array<Byte>` MUST 不与线程缓冲共享底层存储，后续写入线程缓冲 MUST NOT 改变已返回结果。

#### Scenario: 残余字节不泄漏

- **WHEN** 线程缓冲已被上一次读取填满 `0xFF`，随后读取一个 64 B 的小响应
- **THEN** 结果只包含这 64 B，长度精确，不含任何 `0xFF`

#### Scenario: 分块读取

- **WHEN** 响应体长度为 8191 / 8192 / 8193 / 24583 B，需要一次或多次 `read` 才能读完
- **THEN** 返回的字节数等于响应体长度，内容逐字节一致

#### Scenario: 超限行为不变

- **WHEN** 声明或实际的响应体超过 `maxResponseBytes`
- **THEN** 客户端仍按现有规则停止读取、关闭响应并抛 `JsonRpcException`

### Requirement: 读缓冲的验证与分配基准

本变更 MUST 提供可重复执行的验证：

1. 单元测试 MUST 覆盖同线程复用、跨线程隔离、并发多响应、残余字节不泄漏、分块读取与
   小响应回归；
2. 既有 `HttpJsonRpcTransport_test` 的用例 MUST 保持不变并通过；
3. MUST 提供 `F_JSONRPC_BENCH=1` 门控的分配基准，至少包含：
   - 同线程取缓冲的摊销分配（MUST `<= 64 B/次`，对照每次新建的 8192 B）；
   - 小响应与多分块响应的端到端 `allocPerCall`（只打印，不做耗时断言）；
   - 多线程并发发送的总分配与吞吐（只打印）；
4. 未设置门控环境变量时，基准 MUST 打印 `SKIP:` 并立即返回，不影响常规测试。

#### Scenario: 分配基准门控

- **WHEN** 未设置 `F_JSONRPC_BENCH=1` 运行 `cjpm test`
- **THEN** 基准用例输出 `SKIP:`，测试套件不因基准耗时受影响

#### Scenario: 复用分配上界

- **WHEN** 设置 `F_JSONRPC_BENCH=1`，同线程连续取缓冲 5000 次
- **THEN** 摊销分配 `<= 64 B/次`，且与「每次新建 8192 B」的对照组相差一个数量级以上
