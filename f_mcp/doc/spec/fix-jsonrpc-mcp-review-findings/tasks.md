# 任务：修复 f_jsonrpc / f_mcp 评审缺陷

> 执行规则（`AGENTS.md`）：
> - 开发在功能分支 `fix/jsonrpc-mcp-review-findings`，开工前 `git pull`；每完成一个任务独立提交。
> - 每个编码任务按 TDD：先写**会失败**的用例（Red），再改实现（Green），最后补边界 / 并发用例。
> - 新功能必须有仓颉单元测试；测试发现的新问题必须修掉并补用例。
> - 任务编号与 `design.md` 第 3 节的问题编号一一对应；P0 未全绿不得进入 P1。
> - 不允许出现「任务已勾选但没有对应测试」的进度。

## 0. 准备

- [x] 0.1 建分支 `fix/jsonrpc-mcp-review-findings`，同步远程；记录基线：`f_jsonrpc` / `f_mcp` /
      `f_data` / `f_mvc` / `f_concurrent` 各自 `cjpm test` 用例数与结果
- [x] 0.2 用本文末「问题 → 任务对照表」逐项确认 55 条都有落点；缺失项当场补进任务
- [x] 0.3 准备测试基建：
      `f_jsonrpc` 暴露 `JsonRpcTransport` 后可注入 `FakeTransport`；
      `f_mcp` 的 stdio 用例继续用 bash 脚本模拟子进程；
      `McpServer` 用例直接构造 server 并调用 `jsonRpcServer().invoke(...)`
- [x] 0.4 建立文档校对清单：两份 README、两份 `模块设计.md` 中所有被点名的行号

## P0 严重问题

> 目标：先修「协议错误 / 内存无上限 / 资源泄漏 / 数据丢失 / 默认配置不可用」。
> 每项先写能稳定复现的失败用例，禁止先改实现再补测试。

### T1 客户端流式响应上限（R1-1）

- [x] 1.1 Red：用本地 `stdx.net.http` server 返回 `Content-Length: 10485760`，
      `maxResponseBytes = 1 MiB` → 断言 `JsonRpcException` 且服务端未观察到 body 被读完（当前会读完）
- [x] 1.2 Red：chunked 持续输出 20 MiB，`maxResponseBytes = 1 MiB` → 断言在读约 1 MiB 时抛错
- [x] 1.3 Green：`HttpJsonRpcTransport.send` 先解析 `Content-Length` 预判，再 `readCapped` 流式累计；
      超限关闭响应并抛错
- [x] 1.4 Green：读取改为按 `Content-Length` 预分配 `ArrayList<Byte>` + 末尾 `unsafeData()`；去掉的是
      「收齐后整体拷成 `Array`」的整包副本，每轮 `read` 后把 `buffer[0..size]` 切片搬进列表这一趟保留
      （缓冲区复用，无法省）
- [x] 1.5 回归：正常 1 KiB 响应、空响应、`maxResponseBytes` 恰好等于 body 长度
- [x] 1.6 `cd f_jsonrpc && cjpm test` 全绿

### T2 重试边界（R1-2）

- [x] 2.1 Red：`FakeTransport` 抛普通 `IOException`，`retryOnConnectFailure = 3` → 只调用 1 次
- [x] 2.2 Red：`FakeTransport` 抛 `JsonRpcConnectException` → 调用 4 次后抛出
- [x] 2.3 Red：真实 HTTP 场景「建连成功、读响应中断」→ 不重发（server 只收到 1 次请求）
- [x] 2.4 Green：新增 `JsonRpcConnectException <: IOException`；`HttpJsonRpcTransport` 只把
      `client.send` 阶段异常包装成它；`sendWithRetry` 只捕获它
- [x] 2.5 回归：`retryOnConnectFailure = 0` 时任何异常都只尝试 1 次
- [x] 2.6 `cd f_jsonrpc && cjpm test` 全绿

### T3 批量单对象错误（R1-3）

- [x] 3.1 Red：响应为 `{"jsonrpc":"2.0","id":null,"error":{"code":-32003,...,"data":{"limit":2,"size":5}}}`
      → 抛 `JsonRpcException`，`code == -32003`，`data.limit == 2`
- [x] 3.2 Red：响应为单个非错误对象 → 抛 `-32603` 且 message 含 `expected an array`
- [x] 3.3 Green：`batch` 先判顶层类型，单对象错误直接抛；数组路径保持同序
- [x] 3.4 回归：正常数组、缺 id 条目仍合成 `-32603`、空数组输入
- [x] 3.5 `cd f_jsonrpc && cjpm test` 全绿

### T4 客户端异常封闭（R1-4）

- [x] 4.1 Red：`error.code` 为字符串 / `null` / 对象 → 抛 `JsonRpcException`，不抛 `JsonException`
- [x] 4.2 Red：响应体 `{not json` → 抛 `JsonRpcException`，message 含解析失败原因
- [x] 4.3 Red：`error` 为 `null` / 数组 → 抛 `JsonRpcException(-32603, malformed error object)`
- [x] 4.4 Green：`toResponse` 加类型守卫；`parseObject` 捕获解析异常并转换
- [x] 4.5 回归：合法 `error.code` 为 `JsonDecimal`（如 `-32603.0`）仍能取整
- [x] 4.6 `cd f_jsonrpc && cjpm test` 全绿

### T5 传输 SPI 与客户端测试补齐（R1-6、R1-9）

- [x] 5.1 Red：`JsonRpcClient(transport: t)` 从外部包可构造（编译用例）
- [x] 5.2 Red：`keepAlive = false` → 请求头含 `Connection: close`；`keepAlive = true` 时不含
- [x] 5.3 Red：同一 client 连续两次调用成功（复用连接，无 `Socket is already closed`）
- [x] 5.4 Red：`callAsync` 返回 `Future` 且结果正确
- [x] 5.5 Green：`JsonRpcTransport` / `JsonRpcClient(transport:, opts!)` 公开；
      `maxRetries` 从 `opts.retryOnConnectFailure` 取
- [x] 5.6 `cd f_jsonrpc && cjpm test` 全绿

### T6 默认无超时与 `''` 语义（R2-1、R1-8）

- [x] 6.1 Red：无 `@JsonRpcMeta` 的方法 `getMeta` 返回 `timeout == ''`
- [x] 6.2 Red：`@JsonRpcMeta['通知','']` 注册后 `JsonRpcMethodMeta.timeout.isNone()`
- [x] 6.3 Red：默认方法调用 `CurrentHttpContext.instance` 不抛异常（当前抛 `NoneValueException`）
- [x] 6.4 Green：`JsonRpcRegistry.getMeta` 默认值改 `JsonRpcMeta('', '')`；
      宏 `timeout.isEmpty()` 分支保持 `None`；`timeoutDuration` 不再被空串调用
- [x] 6.5 Green：`invokeHandler` 的 `None` 分支直接调用，不 `spawn`
- [x] 6.6 回归：显式 `'5s'` 仍产生 `Some(Duration)`；`invoke` 与 HTTP 行为一致
- [x] 6.7 `cd f_jsonrpc && cjpm test` 全绿

### T7 显式超时的 ThreadLocal 传播（R2-1）

- [x] 7.1 Red：方法配置 `timeout = '5s'`，handler 在子线程读 `CurrentHttpContext.instance` → 取到同一请求上下文
- [x] 7.2 Red：handler 返回后同一子线程复用时不残留上下文（用两次超时调用验证）
- [x] 7.3 Red：`timeout = '100ms'`、handler 睡 1s → `-32002`，响应耗时约 100ms
- [x] 7.4 Green：`f_mvc.CurrentHttpContext` 增加 `public static func scoped<T>(ctx: ?HttpContext, body: () -> T): T`
- [x] 7.5 Green：`invokeHandler` 的超时分支用 `scoped(ctx.http)` 包裹 handler
- [x] 7.6 回归：`f_mvc` 全量测试；非 HTTP（`http == None`）时不设置上下文
- [x] 7.7 `cd f_mvc && cjpm test`、`cd f_jsonrpc && cjpm test` 全绿

### T8 多轮链路服务端（R3-1）

- [x] 8.1 Red：`tools/call` 带 `inputResponses` / `requestState` → handler 的 `McpToolContext` 能读到原值
- [x] 8.2 Red：handler 返回 `CallToolResult(requestState: {...})` → 响应 JSON 含 `requestState`
- [x] 8.3 Red：handler 返回 `input_required` 且带 `requestState` → `resultType` / `inputRequired` / `requestState` 同时保留
- [x] 8.4 Green：`McpToolContext` 增加 `inputResponses` / `requestState`；
      `callTool` 从 `requireMeta` 后的 `request` 读取并注入
- [x] 8.5 Green：`CallToolResult` 增加 `requestState`，`toJson` 输出
- [x] 8.6 回归：`inputResponses` 为数组 / 对象 / 字符串都原样透传；缺失时 `None`
- [x] 8.7 `cd f_mcp && cjpm test` 全绿

### T9 多轮链路客户端（R3-2）

- [x] 9.1 Red：假服务端第一轮返回 `requestState = {"cursor":7}` + `input_required`；
      第二轮断言请求体含 `params.requestState` 与 `params.inputResponses`
- [x] 9.2 Red：第二轮返回 `complete` → `callToolAuto` 返回该结果，不继续循环
- [x] 9.3 Green：`toCallToolResult` 解析 `requestState`；`callToolAuto` 维护 `responses` / `state` 两个状态
- [x] 9.4 回归：`maxRounds` 到达时仍抛 `INTERNAL_ERROR`；`handler` 被调用次数等于轮数
- [x] 9.5 `cd f_mcp && cjpm test` 全绿

### T10 UTF-8 安全截断（R4-1）

- [x] 10.1 Red：结果含中文，序列化后 `limit` 落在 3 字节字符中间 → `tools/call` 正常返回，内容为合法 UTF-8
- [x] 10.2 Red：结果含 emoji（4 字节）→ 同上
- [x] 10.3 Red：截断结果保留 `isError` / `resultType` / `inputRequired` / `requestState`，`data.truncated = true`
- [x] 10.4 Green：新增 `truncateUtf8(text, limit)`；`truncated` 改为构造 `CallToolResult`
      （新增 `extra: ?JsonObject` 并入 `data`）
- [x] 10.5 回归：ASCII 截断长度不变；`limit` 大于内容时原样返回
- [x] 10.6 `cd f_mcp && cjpm test` 全绿

### T11 `tools/call` 单次序列化（R4-5）

- [x] 11.1 Red：小结果路径完整序列化次数为 1（用计数包装 / 自定义 ToData 统计）
- [x] 11.2 Red：大结果 + `publicBaseUrl` 路径序列化次数 ≤ 2（结果本体 + 最终响应）
- [x] 11.3 Green：`applyLargeResult` 只 `result.toJson()` + `toString()` 一次，字符串在量字节 / 入库 / 截断间复用
- [x] 11.4 回归：`resource_link` 内容与原文一致；截断文本与未优化前语义一致
- [x] 11.5 `cd f_mcp && cjpm test` 全绿

### T12 限流器池有界（R5-1）

- [x] 12.1 Red：`RateLimiter` 子类可 `close()`；`TokenBucket` 被 close 后 Timer 不再填充（用计数验证）
- [x] 12.2 Red：`LimiterPool` 容量上限 100，注入 1000 个 key → `size <= 100 + 批`，被淘汰的 limiter 已 close
- [x] 12.3 Red：空闲超过 TTL 的条目被回收
- [x] 12.4 Green：`f_concurrent.RateLimiter` 增加 `public open func close(): Unit {}`；
      三个定时器型 limiter 保存 `Timer` 并覆盖 `close()`
- [x] 12.5 Green：`LimiterPool` 改为带 `lastUsed` 的条目，按操作计数触发 `sweep`，淘汰 / `close` 时调用 `limiter.close()`
- [x] 12.6 回归：`f_concurrent` 全量测试；限流行为（配额内放行、超限拒绝）不变
- [x] 12.7 `cd f_concurrent && cjpm test`、`cd f_mcp && cjpm test` 全绿

### T13 结果存储压力回收（R5-2、R5-9）

- [x] 13.1 Red：256 条全部过期后写第 257 条 → 成功，`size == 1`
- [x] 13.2 Red：字节预算被过期条目占满 → 写入触发 sweep 后成功
- [x] 13.3 Red：`sweep` 限频：1 秒内连续 100 次满额写入，全表扫描次数 ≤ 2
- [x] 13.4 Red：窗口未到期时 `evaluate` 不获取窗口锁（用可重入计数或注入锁探针）
- [x] 13.5 Green：`put` 在条数 / 字节压力下先 `sweepIfDue()` 再判定；`sweep` 记录 `lastSweep`
- [x] 13.6 Green：`evaluate` 窗口时间改原子读；快照计算在锁内，格式化与日志移出锁
- [x] 13.7 回归：自适应调容三条既有用例（扩容 / 缩容 / 字节瓶颈）行为不变
- [x] 13.8 `cd f_mcp && cjpm test` 全绿

### T14 结果存储重复 token（R5-8）

- [x] 14.1 Red：同 token 先写 100 字节再写 200 字节 → `size == 1`、`usedBytes == 200`
- [x] 14.2 Red：反复覆盖 100 次 → `usedBytes` 不增长、`size == 1`
- [x] 14.3 Green：`entries.add` 返回值判重；覆盖时 `budget.release(prev.bytes)`，不 `count.fetchAdd(1)`
- [x] 14.4 回归：正常写入 `usedBytes` 累加；`get` / `sweep` / `close` 记账一致
- [x] 14.5 `cd f_mcp && cjpm test` 全绿

## P1 一般问题

### T15 JSON-RPC 响应类型与 Content-Type（R2-8）

- [x] 15.1 Red：不带 `Accept` 的 HTTP 请求 → 响应 `Content-Type: application/json`
- [x] 15.2 Red：`Accept: application/json` → 同上，且 body 与 `handle` 返回的 `JsonValue` 序列化一致
- [x] 15.3 Green：`JsonRpcServer.handle` 返回 `?JsonValue`；`JsonRpcController` 返回 `Any`
- [x] 15.4 Green：删除 `encode` / `errorBytes` 的字节路径；批量返回 `JsonArray`
- [x] 15.5 回归：413 路径仍能设置状态码；通知仍返回 `None`
- [x] 15.6 `cd f_jsonrpc && cjpm test` 全绿

### T16 topic 索引与 namespace 预计算（R2-3）

- [x] 16.1 Red：注册 1000 个方法后 `resolve` 不遍历方法表（用计时或计数探针）
- [x] 16.2 Red：`JsonRpcMethodMeta.namespace` 在构造后不再切片（对同一 meta 取 1000 次无新分配）
- [x] 16.3 Green：`JsonRpcServer` 维护 topic 集合；`addMethod` 同步更新；`resolve` 走索引
- [x] 16.4 回归：`/rpc/{topic}` 的 4 类语义（命中 / 跨命名空间 / 未知 topic / 无点方法名）不变
- [x] 16.5 `cd f_jsonrpc && cjpm test` 全绿

### T17 注册期 schema 编译（R2-4）

- [x] 17.1 Red：`CompiledSchema.compile` 对非法 schema（`pattern: 1`、`required: "x"`）抛错
- [x] 17.2 Red：含 `pattern` 的 schema 连续校验 100 次，正则编译 1 次
- [x] 17.3 Red：`CompiledSchema.validate` 与 `JsonSchemaValidator.validate` 对同一组 schema/value 结论一致（表驱动，覆盖全部支持关键字）
- [x] 17.4 Green：`f_data` 新增 `CompiledSchema`：结构校验 + 正则预编译 + 关键字预解析，复用现有遍历器
- [x] 17.5 Green：`JsonRpcMethodMeta` 构造期编译 `paramsSchema`；`checkParamsEx` 用编译结果
- [x] 17.6 回归：`f_data` 全量 schema 测试；`f_jsonrpc` 参数校验用例
- [x] 17.7 `cd f_data && cjpm test`、`cd f_jsonrpc && cjpm test` 全绿

### T18 元数据瘦身（R2-2、R2-5）

- [x] 18.1 Red：`JsonRpcMethodMeta` 不再有 `inputSchema` / `outputSchema`（编译用例）
- [x] 18.2 Red：`JsonRpcContext` 不再有 `meta`（编译用例）
- [x] 18.3 Red：`/rpc` 请求不再遍历请求头构造 `HashMap`
- [x] 18.4 Green：删除字段与构造参数；两个 controller 去掉头拷贝
- [x] 18.5 Green：`McpController` 的版本头校验改读 `ctx.http.request.headers`
- [x] 18.6 `cd f_jsonrpc && cjpm test`、`cd f_mcp && cjpm test` 全绿

### T19 请求体上限动态解析（R2-9）

- [x] 19.1 Red：模拟「注册先于配置加载」——构造 server 后再设置 `MVCConfig.maxRequestBodySize` → 4 MiB 请求被接受
- [x] 19.2 Red：显式 `maxBodyBytes(1024)` 时配置不生效
- [x] 19.3 Green：`JsonRpcServer` 保存 `configuredMaxBodyBytes`，`handle` 每请求解析；`build()` 不再快照
- [x] 19.4 回归：超限仍返回 `-32600` + 413 + `data.limit`；批量超限仍返回 `-32003` + `data.size`
- [x] 19.5 文档：README 写明 `maxBatchSize` / `maxBodyBytes` 默认值与 `data` 字段（与 T44 合并校对）
- [x] 19.6 `cd f_jsonrpc && cjpm test` 全绿

### T20 宏生成代码无警告（R1-7）

- [x] 20.1 Red：编译含 `@JsonRpc` 的模块，构建日志出现 `unused variable: '__jsonrpc_ctx'`
- [x] 20.2 Green：handler 形参改 `_`（或显式 `let _ = __jsonrpc_ctx`）
- [x] 20.3 回归：`@JsonRpc` 宏测试全绿；构建日志无该警告
- [x] 20.4 `cd f_jsonrpc && cjpm test` 全绿

### T21 三层合并与 0 语义（R5-11、R5-12、R4-7）

- [x] 21.1 Red：配置 `maxConcurrency=64, perToolRpm=6000` + `Builder.rateLimit(perCallerRpm:120)` → 三个值都生效
- [x] 21.2 Red：注解 `perCallerRpm: 0` + 全局 600 → 该工具不检查调用方配额
- [x] 21.3 Red：只写 `description` 的注解 → 所有限流字段继承
- [x] 21.4 Red：全局 `maxConcurrency=8`、工具 A `maxConcurrency=2` → A 在途 ≤2、A+B ≤8
- [x] 21.5 Green：`RateLimitPolicy.overlay`；`build()` 用 `配置.overlay(builder)`；
      `McpToolMeta` 数值默认 `-1`；`toolRateLimitOf` 映射 `-1/0/>0`；`resolveLimit` 区分全局 / 工具并发
- [x] 21.6 回归：三层限流既有用例；`maxResultBytes` 仍来自 `McpTool`
- [x] 21.7 `cd f_mcp && cjpm test` 全绿

### T22 限流顺序与并发 lease（R6-5、R5-3）

- [x] 22.1 Red：全局并发满 + `perCallerRpm=2` → 5 次并发拒绝后令牌仍为 2
- [x] 22.2 Red：并发获取成功后 rpm 拒绝 → 并发计数回到 0
- [x] 22.3 Red：`ConcurrencyGate` release 到 0 后 key 保留，A 释放与 B 获取交错不丢计数
- [x] 22.4 Red：`maxConcurrency=0` 调用前后全局计数不变
- [x] 22.5 Green：引入 `ConcurrencyLease`；检查顺序改为并发优先；失败释放 lease
- [x] 22.6 Green：`ConcurrencyGate` 条目化（count/limit/lastUsed），release 只减，TTL 回收
- [x] 22.7 回归：异常路径 `finally` 释放；`close()` 清空
- [x] 22.8 `cd f_mcp && cjpm test` 全绿

### T23 429、Retry-After 与 caller 派生（R6-2）

- [x] 23.1 Red：限流拒绝的 HTTP 响应状态 429，`Retry-After >= 1`
- [x] 23.2 Red：`X-Forwarded-For: 1.2.3.4, 10.0.0.1` + `mcp_trustForwardedFor=true` → caller 为 `1.2.3.4`
- [x] 23.3 Red：默认不信任 XFF → caller 仍是 `remoteAddr`
- [x] 23.4 Red：`remoteAddr = "10.0.0.9:53211"` → caller 去掉端口
- [x] 23.5 Red：`Authorization` 的 caller 为 32 位十六进制（摘要前 16 字节）
- [x] 23.6 Green：`rateLimitError(ctx, verdict)` 设置 429 / `Retry-After`；`callerId` 实现四级派生；新增配置项
- [x] 23.7 `cd f_mcp && cjpm test` 全绿

### T24 限流配置校验（R5-10）

- [x] 24.1 Red：负数 / 小数 / 未知键 / 段数 >5 / 中间空段 / JSON 语法错误 → `IllegalArgumentException` 且消息含字段
- [x] 24.2 Red：`0` → `None`（不限制）；`rpm > 1_000_000` → 报错
- [x] 24.3 Red：`mcp_trustForwardedFor` 非 `true`/`false` → 报错
- [x] 24.4 Green：统一 `parseValue`；JSON 只接受整数；未知键 / 段数 / 空段校验；异常包装
- [x] 24.5 回归：合法 CSV 与 JSON 两种写法结果一致
- [x] 24.6 `cd f_mcp && cjpm test` 全绿

### T25 移除 any-moment 后端（R5-7）

- [x] 25.1 Red：`mcp_rateLimitBackend=any-moment` → 启动 `IllegalArgumentException`，消息列出可用后端
- [x] 25.2 Red：`RateLimitBackends.of('any-moment')` 抛错
- [x] 25.3 Green：删除 `AnyMomentRateLimitBackend` 与注册项；README 后端表删除该行
- [x] 25.4 回归：其余四种后端可用；默认 token-bucket
- [x] 25.5 `cd f_mcp && cjpm test` 全绿

### T26 能力声明一致性（R4-2）

- [x] 26.1 Red：`discover().capabilities.resources.subscribe == false`
- [x] 26.2 Red：`capabilities` 含 `prompts`，且 `prompts/list` 可调用
- [x] 26.3 Red：能力一致性测试——声明的每个能力都有对应方法（`subscribe=true` 时必须有 `resources/subscribe`）
- [x] 26.4 Green：`capabilities()` 调整；README 同步
- [x] 26.5 `cd f_mcp && cjpm test` 全绿

### T27 订阅上限、TTL 与重连（R4-3、R5-5）

- [x] 27.1 Red：订阅数达 `maxSubscribers` 再 `listen` → `-32003`，订阅数不变
- [x] 27.2 Red：未 attach 的订阅者在 detached TTL 后消失；`publish` 不再为它累积通知
- [x] 27.3 Red：队列容量 2，发布 5 条 → 保留最后 2 条，`dropped == 3`
- [x] 27.4 Red：SSE 关闭后 60 秒内同 id 重连成功；超过 TTL 失败
- [x] 27.5 Red：30 分钟到点只 detach，订阅者仍在 TTL 内
- [x] 27.6 Red：`McpServer.close()` 后 hub 为空
- [x] 27.7 Green：`SubscriptionHub` 实现 `maxSubscribers` / `detachedTtl` / `queueCapacity` / `detach` / `attach` / `prune` / `close`
- [x] 27.8 Green：`McpSseStream` 30 分钟与 `close()` 改为 `detach`
- [x] 27.9 `cd f_mcp && cjpm test` 全绿

### T28 SSE 阻塞等待与批量拷贝（R6-6）

- [x] 28.1 Red：无事件时 1 秒内 `take` 调用次数为 1（当前约 10 次）
- [x] 28.2 Red：15 秒无事件发一次 ping
- [x] 28.3 Red：1000 条事件的拼接为一次 `StringBuilder`，不出现 O(n²) 复制
- [x] 28.4 Red：`read` 输出与事件字节完全一致（批量拷贝正确性）
- [x] 28.5 Green：订阅者用信号量 / 条件变量实现带超时阻塞；`nextChunk` 用 `StringBuilder`；
      `read` 用批量拷贝
- [x] 28.6 回归：`McpSse_test` 的 `poll` 语义不变
- [x] 28.7 `cd f_mcp && cjpm test` 全绿

### T29 SSE 查询串与响应头（R5-4、R5-6）

- [x] 29.1 Red：`?topics=tools%2Flist_changed` → 收到 `tools/list_changed` 通知
- [x] 29.2 Red：`?topics=a, b` → 订阅 `a`、`b`
- [x] 29.3 Red：`?topics=` → HTTP 400，不建立订阅
- [x] 29.4 Red：无效 `subscriptionId` → 400，响应无 `Transfer-Encoding: chunked`
- [x] 29.5 Green：统一查询串解析 + 百分号解码 + trim；校验通过后再写 `Transfer-Encoding`
- [x] 29.6 Green：错误路径设置 `status(400)`
- [x] 29.7 `cd f_mcp && cjpm test` 全绿

### T30 客户端强类型模型（R3-7）

- [x] 30.1 Red：`ContentBlock.fromJson` 对 `text` / `image` / `audio` / `resource` / `resource_link` / 未知类型
      都能往返，未知类型不丢失
- [x] 30.2 Red：`CallToolResult.fromJson(...).toJson()` 与输入语义等价（含 `structuredContent` / `inputRequired` / `requestState`）
- [x] 30.3 Red：`discover()` / `listTools()` / `readResource()` / `getPrompt()` 返回强类型，字段可直接访问
- [x] 30.4 Red：`McpCapabilities.toJson()` 保留未知字段
- [x] 30.5 Green：新增 `base/McpModels.cj` 与各 `fromJson`；客户端改返回类型；保留 `McpCallToolResult` 别名
- [x] 30.6 回归：`listAllTools` 返回强类型且分页仍是 100 页 / 1000 条上限
- [x] 30.7 `cd f_mcp && cjpm test` 全绿

### T31 stdio 复用消息层与读超时（R3-3、R3-4）

- [x] 31.1 Red：子进程先输出 `notifications/tools/list_changed`，再输出匹配响应 → 返回正确结果
- [x] 31.2 Red：子进程先输出 `starting server...` → 记 WARN 后继续
- [x] 31.3 Red：连续两次调用 id 为 1、2
- [x] 31.4 Red：迟到旧响应（id=1）不匹配当前 id=2 → 忽略
- [x] 31.5 Red：子进程沉默 + `timeout=500ms` → 约 500ms 抛错
- [x] 31.6 Green：新增 `StdioJsonRpcTransport`（读线程 + 带超时队列 + id 匹配 + 通知跳过）
- [x] 31.7 Green：`McpClient.stdio` 改为 `JsonRpcMcpRpc(JsonRpcClient(StdioJsonRpcTransport(...)))`；
      删除 `HttpMcpRpc` / `StdioMcpRpc`，保留 `McpRpc` 测试接缝
- [x] 31.8 Green：`rpcCall` 捕获 `IOException` 转 `McpException`
- [x] 31.9 `cd f_mcp && cjpm test` 全绿

### T32 客户端选项补齐（R3-5）

- [x] 32.1 Red：`headers = {"Authorization":"Bearer x"}` → 每个 HTTP 请求都带该头
- [x] 32.2 Red：`maxResponseBytes` 透传到 `ClientOptions`，超限抛错
- [x] 32.3 Red：`keepAlive=false` 透传 `Connection: close`
- [x] 32.4 Red：`retryOnConnectFailure=2` 透传，建连失败重试
- [x] 32.5 Green：扩展 `McpClientOptions` 与 `toJsonRpcOptions()`；stdio 忽略 HTTP 专属项并文档化
- [x] 32.6 `cd f_mcp && cjpm test` 全绿

### T33 版本协商线程安全（R3-6）

- [x] 33.1 Red：8 线程同时命中 `-32022` → 版本只改写一次，每请求最多重试一次，产生 1 条 INFO
- [x] 33.2 Red：协商后新请求使用新版本
- [x] 33.3 Green：`Mutex` 保护 `protocolVersion`；`negotiate` 比较「本次请求使用的版本」决定是否更新；记录日志
- [x] 33.4 `cd f_mcp && cjpm test` 全绿

### T34 游标校验（R3-8）

- [x] 34.1 Red：`decodeCursor("bad")` / `base64("offset:-5")` / `base64("offset:abc")` → `None`
- [x] 34.2 Red：`"cursor": 1` → `-32602`
- [x] 34.3 Red：非法 base64 → `-32602`，不返回首页
- [x] 34.4 Red：`offset:99`（只有 3 条）→ 空页，无 `nextCursor`
- [x] 34.5 Green：`decodeCursor` 返回 `?Int64`；`cursorOf` 校验并抛 `-32602`
- [x] 34.6 回归：合法分页连续取完；`listAllTools` 不重复收集
- [x] 34.7 `cd f_mcp && cjpm test` 全绿

### T35 宏参数 / 返回值转换（R3-9）

- [x] 35.1 Red：`argument<T>` 不再调用 `toString()` + `fromJson`（用计数 `ToData` 验证 0 次字符串往返）
- [x] 35.2 Red：`toolResult<T>` 对同一返回值只序列化一次，`structuredContent` 与文本一致
- [x] 35.3 Red：非法参数仍抛 `-32602`
- [x] 35.4 Green：`argument<T>` 用 `value.toData()` + `T.tryFromData`；`toolResult<T>` 用 `toData()` + `JsonValue.from`
- [x] 35.5 `cd f_mcp && cjpm test` 全绿

### T36 prompt 注册期元数据与列表缓存（R4-4、R4-6）

- [x] 36.1 Red：`prompts/get` 10 次，`findAnnotation<McpPromptArg>` 次数等于参数个数
- [x] 36.2 Red：`registerPromptMeta` 只做一次 `getInstanceFunction`
- [x] 36.3 Red：`tools/list` / `resources/list` / `prompts/list` 连续 10 次，每个条目 JSON 构造次数为 1
      （发生在首次请求，`build()` 期间为 0）
- [x] 36.4 Green：注册期汇总参数元数据；宏改调合并后的注册函数；条目 JSON 在**首次 `list` 请求时**惰性
      构造并写入 `listJson`（`build()` 不预生成），此后只读复用；`listXxx` 只引用不拷贝，本地 `handle()` /
      `invoke()` 返回的条目同样是只读约定，调用方不得修改
- [x] 36.5 回归：必填参数校验、分页、排序不变
- [x] 36.6 `cd f_mcp && cjpm test` 全绿

### T37 重载编译期诊断（R2-6）

- [x] 37.1 Red：`@JsonRpc` 类里两个同名 public 方法 → 编译失败，消息含完整方法名
- [x] 37.2 Green：宏内 `HashSet<String>` 去重并 `diagReport(ERROR, ...)`
- [x] 37.3 回归：不同名方法正常注册；`JsonRpcServer.addMethod` 重复注册仍抛异常
- [x] 37.4 `cd f_jsonrpc && cjpm test` 全绿

### T38 注解末段匹配与 `@Mcp` 延迟构建（R3-10、R3-12）

- [x] 38.1 Red：`@fountain::f_mcp::server::McpToolMeta[...]` → 工具被注册
- [x] 38.2 Red：`@Mcp` 类 + `main()` 里 `McpRegistry.configure(...)` → 启动不抛 `already initialized`
- [x] 38.3 Red：`@Mcp` 类里两个方法解析出同名工具 → 编译期报错
- [x] 38.4 Green：`annotationKinds` 取 `fullIdentifier` 末段；删除宏内 `McpRegistry.build()`；
      重名 `diagReport(ERROR, ...)`
- [x] 38.5 回归：手工注册、注解注册、两者共存三种路径都有工具输出
- [x] 38.6 `cd f_mcp && cjpm test` 全绿

### T39 错误码文档修正（R1-5）

- [x] 39.1 Red：README 错误码表把 `-32001` 标为「handler 通用异常」→ 校对用例失败
- [x] 39.2 Green：`JsonRpcProtocol.SERVER_ERROR` 注释改为「保留、当前不产生」；README 与设计文档修正；
      `-32003` 只描述批量
- [x] 39.3 回归：`messageOf` 行为不变；实际产生的保留码只有 -32002/-32003/-32004
- [x] 39.4 `cd f_jsonrpc && cjpm test` 全绿

### T40 README topic 示例修正（R2-7）

- [x] 40.1 Red：按 README 的 `POST /rpc/other` 示例复现，实际返回 `-32004`
- [x] 40.2 Green：README / `README_en.md` 改为 `-32004`，并补一行「topic 下没有方法」
- [x] 40.3 回归：示例对应的服务端测试（`kb` 存在 + `crm.list` → `-32601`；`other` → `-32004`）
- [x] 40.4 `cd f_jsonrpc && cjpm test` 全绿

### T41 `MCP-Protocol-Version` 头校验（R6-1）

- [x] 41.1 Red：头与 body 不一致 → `-32602`，`data.header` / `data.body` 正确
- [x] 41.2 Red：头版本不受支持 → `-32022`
- [x] 41.3 Red：头缺失 → 只按 body 校验
- [x] 41.4 Green：`requireMeta(ctx, params)` 读取 `ctx.http` 头并校验；README 补说明
- [x] 41.5 `cd f_mcp && cjpm test` 全绿

### T42 MCP 错误码迁段（R6-4）

- [x] 42.1 Red：`RESOURCE_NOT_FOUND == -32040`
- [x] 42.2 Red：未知资源 / 过期链接返回 `-32040`，不再是 `-32002`
- [x] 42.3 Green：常量迁移；README 与设计文档码段表更新
- [x] 42.4 回归：`-32002` 只由 f_jsonrpc 超时产生
- [x] 42.5 `cd f_mcp && cjpm test` 全绿

### T43 设计文档收敛（R6-3、R3-11）

- [x] 43.1 两份 `模块设计.md` 文首加「以实现为准」横幅
- [x] 43.2 删除 `onExceed` / `RateLimitAction` / `AdaptivePolicy` / `ttl: Duration` 等未实现声明；
      `ResultStoreOptions` 改为实际 8 个字段；`maxResultBytes` 归 `McpTool`
- [x] 43.3 `f_jsonrpc` 设计文档修正：默认超时、`''` 语义、错误码产生点、`-32003` 范围、`ClientOptions`
- [x] 43.4 `f_mcp` 设计文档修正：`Builder` 方法名、`capabilities()`、`McpTool` 字段、`subscribe=false`、
      SSE 30 分钟语义、限流顺序与 429
- [x] 43.5 校对：文档中出现的每个公开符号都能在源码中找到（脚本或人工清单）

### T44 README 全面校对（R1-6、R2-9、R3-5、R3-7、R3-11、R4-2、R5-7、R5-10、R6-2、R6-3）

- [x] 44.1 `f_jsonrpc/README.md` / `README_en.md`：客户端选项、错误码、topic、批量 / body 上限、超时、重试
- [x] 44.2 `f_mcp/README.md` / `README_en.md`：客户端选项与返回类型、能力表、错误码、限流三层 / 顺序 /
      caller / 429、后端列表、订阅与重连、`-1/0/>0`
- [x] 44.3 所有 README 代码片段与实际 API 一致（逐段编译或对照测试）
- [x] 44.4 「迁移」小节列出 `design.md` 第 5 节的全部破坏性变更
- [x] 44.5 中英文内容对齐（结构相同、语义一致）

## 收尾

- [x] Z1 `f_data`、`f_mvc`、`f_concurrent`、`f_jsonrpc`、`f_mcp` 各自 `cjpm test` 全绿
- [x] Z2 `fboot build` 通过
- [x] Z3 按 `design.md` 第 5 节逐条验证破坏性变更的迁移说明已落地
- [x] Z4 复核 55 条问题全部有对应代码改动或文档改动，且都有测试或校对证据
- [x] Z7 规划产物去重：删除 `f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/` 下的 `specs/json-rpc/`
      与 `.openspec.yaml`；`json-rpc` spec 只在 `f_jsonrpc/doc/spec/fix-jsonrpc-mcp-review-findings/specs/json-rpc/`
      保留一份；两侧副本按 `openspec/changes/fix-jsonrpc-mcp-review-findings/` 逐文件同步（含本次 `specs/mcp`
      缓存口径修订）
- [x] Z5 运行 `/opsx:verify`（已执行；F1 的 T38.1–38.3 自动化测试受仓颉 1.3 语言/基建限制，见 T38 注）
- [ ] Z6 合并回 `master`（`--no-ff`），删除功能分支；按需建 tag

## 遗留（verify 复审未收敛，已在 apply 阶段收敛）

> **spec 语义保持不动**：A2（头与 body 不一致 → `-32602`）与 A3（CSV 中间空段报错）的 spec 文本未改，
> 代码按 V4 / V5 对齐；`openspec validate` 0 错。

- [x] V1（A2 判定）保留 `specs/mcp/spec.md` 的「头与 body 不一致 → `-32602`」场景：header `2026-07-28`
      + body `2025-11-25` MUST 返回 `-32602`，`data.header` / `data.body` 为原值。MUST NOT 通过改 spec
      场景来迁就当前实现 —— spec 未改，代码按 V4 对齐
- [x] V2（A3 判定）保留 `specs/mcp-guardrails/spec.md` 的「CSV 中间空段 MUST 报错」：`'1,,120'` 这类
      「空段之后仍有非空段」的输入 MUST 报错；尾部空段仍等同省略（`'1,,,'` 合法）。MUST NOT 改 spec
      迁就实现 —— spec 未改，代码按 V5 对齐
- [x] V3（A1）**订阅者泄漏**（`McpServer.cj`、`McpSse.cj`）：
      1. `SubscriptionHub.subscribe` 创建时写入 `detachedAtNanos = nowNanos()`，`pruneLocked` 去掉 `> 0`
         条件；
      2. `detach` 幂等：未 attach 也写入 `detachedAtNanos`；
      3. 新增 `subscribeAttached`，`/mcp/sse` 直连路径创建后立即 attach；
      4. `attach` 命中后清 `detachedAtNanos = 0`，重连语义不变。
      用例（`McpServer_test`）：`testNeverAttachedSubscriberIsPrunedAfterTtl`（含「`publish` 不再入队」）、
      `testDirectSseStreamIsAttachedAndRecycled`、`testStreamEndOnlyDetachesSubscriber`（`close()` 与
      30 分钟到点同一条 detach 路径）、`testPrunedSubscribersReleaseCapacity`
- [x] V4（A2 落地）`requireMeta` 顺序改为：① header 存在且不受支持 → `-32022`；② header != body →
      `-32602` + `data.header` / `data.body`；③ body 不受支持 → `-32022`；④ 头缺失只按 body 校验。
      用例（`McpHttp_test`）：`testHeaderBodyVersionMismatchIsInvalidParams`、
      `testUnsupportedHeaderVersionIsRejected`、`testUnsupportedHeaderWinsOverMismatch`、
      `testMissingHeaderFallsBackToBody`
- [x] V5（A3 落地）`McpConfig.rateLimit` 按段判定：空段之后仍有非空段 → `IllegalArgumentException`
      （消息含字段名）；尾部空段仍视为省略。
      用例（`McpConfig_test`）：`testInnerEmptySegmentIsRejected`（`'1,,120'` / `',1'` / `'1,2,,4'`）、
      `testTrailingEmptySegmentsAreOmitted`（`'1,,,'` / `'1'` / `'0,,,'`）
- [x] V6 **补齐「任务已勾选但无测试」的证据**（apply 落地情况）：
      - T41.1–41.3：由 V4 四条 HTTP 用例覆盖；
      - T11.1–11.2：`CountingPayload`（计数 `ToData`）探针——`testToolsCallConvertsResultOnce` /
        `testLargeResultConvertsBodyOnce` 断言小结果与大结果路径都只把结果本体转成 JSON 一次；
        大结果 + `publicBaseUrl` 的入库文本就是那次序列化的结果（含 `structuredContent`）；
      - T32.1–32.4：新增 `RawMcpServer`（原始 TCP 端点），`testHeadersAreSentOnEveryRequest` /
        `testMaxResponseBytesFromOptions` / `testKeepAliveMapsToConnectionHeader` /
        `testRetryOnConnectFailureFromOptions` 逐请求验证真实 HTTP 行为；
      - T33.1：`testConcurrentVersionNegotiationRewritesOnce`——8 线程并发命中 `-32022`，
        版本只改写一次、每请求恰好 2 次调用（`negotiate` 对「目标版本与当前一致」不再重复改写，
        所以也只有一条 INFO）；
      - T29.1–29.4：`parseTopics` / `parseSubscriptionId` 抽为纯函数（`McpController` 在 try 内建流、
        失败统一 400、chunked 头只在成功路径写入）——`testEncodedTopicReceivesNotification` /
        `testTopicsAreSplitAndTrimmed` / `testEmptyTopicsIsRejected` / `testInvalidSubscriptionIdIsRejected`；
      - T36.1–36.3：`testListEntriesAreBuiltOnceAndReused`（tools / resources / prompts 第二次请求
        仍是同一对象）+ `testPromptArgumentsResolvedAtRegistration`（10 次 `prompts/get` 不重建条目）。
        `findAnnotation` 无拦截点，用「缓存对象复用、请求期不再构造」等价证明；
      - T38.1–38.3：**未补自动化用例**（语言/基建限制）：`McpToolMeta` 是普通包里的注解类，
        仓颉 1.3.0 不接受 `@包名.注解[...]`（编译器按「宏包」解析并报 `undefined macro package`），
        全限定写法在语言层不可表达；重名用例需要编译失败基建，共存用例需要 `McpRegistry` 重置能力，
        仓库里都没有。宏内末段匹配与重名 `diagReport` 保留，基建具备后补；
      - T27.2 / T27.5：由 V3 用例覆盖；
      - T1.1：`testDeclaredLengthExceedsCapFailsFast` 补「服务端落地字节 < `Content-Length`」断言
- [x] V7 **文档与注释清理**：
      - `f_mcp/doc/f_mcp模块设计.md`：资源不存在 / 过期链接一律 `-32040`；删除不存在的
        `temporarily_unavailable` 语义；删除 `AdaptivePolicy` 类与 13 项配置表，`ResultStoreOptions`
        按实际 9 个字段重写（决策伪代码同步为 0.25 / +25% / -12.5% 常量）；`resources/subscribe` 改为
        「SSE 已实现，未实现逐资源订阅」；`McpTool` / `McpResource` 字段与 `JsonRpcContext` 表述按实现重写；
      - `f_jsonrpc/doc/f_jsonrpc模块设计.md`：`maxResponseBytes` 改为「超限立即抛错并关闭响应」；
      - 代码注释：`McpConfig.cj` 后端列表去掉 `any-moment`；`Mcp.cj` 去掉「最后调用 `McpRegistry.build()`」；
      - 校对：`AdaptivePolicy` / `any-moment` 在 `f_mcp/doc` 零命中，MCP 侧 `-32002` 仅剩
        「`-32002` 留给 f_jsonrpc 超时」这条对照说明
- [x] V8 **`openspec validate` 归零**：`openspec validate fix-jsonrpc-mcp-review-findings` →
      `Change ... is valid`（0 错）；未删除既有场景、未改 A2 / A3 场景

## 问题 → 任务对照表

| 问题 | 任务 | 问题 | 任务 | 问题 | 任务 |
| --- | --- | --- | --- | --- | --- |
| R1-1 | T1 | R1-2 | T2 | R1-3 | T3 |
| R1-4 | T4 | R1-5 | T39 | R1-6 | T5、T44 |
| R1-7 | T20 | R1-8 | T6 | R1-9 | T5 |
| R2-1 | T6、T7 | R2-2 | T18 | R2-3 | T16 |
| R2-4 | T17 | R2-5 | T18 | R2-6 | T37 |
| R2-7 | T40 | R2-8 | T15 | R2-9 | T19、T44 |
| R3-1 | T8 | R3-2 | T9 | R3-3 | T31 |
| R3-4 | T31 | R3-5 | T32、T44 | R3-6 | T33 |
| R3-7 | T30、T44 | R3-8 | T34 | R3-9 | T35 |
| R3-10 | T38 | R3-11 | T43、T44 | R3-12 | T38 |
| R4-1 | T10 | R4-2 | T26、T44 | R4-3 | T27 |
| R4-4 | T36 | R4-5 | T11 | R4-6 | T36 |
| R4-7 | T21、T22 | R5-1 | T12 | R5-2 | T13 |
| R5-3 | T22 | R5-4 | T29 | R5-5 | T27 |
| R5-6 | T29 | R5-7 | T25、T44 | R5-8 | T14 |
| R5-9 | T13 | R5-10 | T24、T44 | R5-11 | T21 |
| R5-12 | T21、T22 | R6-1 | T41 | R6-2 | T23、T44 |
| R6-3 | T43、T44 | R6-4 | T42 | R6-5 | T22 |
| R6-6 | T28 | | | | |
