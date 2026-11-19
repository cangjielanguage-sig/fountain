# 提案：修复 f_jsonrpc / f_mcp 全量评审的严重与一般问题

## Why

`reviews/202610251557_jsonrpc_mcp_full_review/` 对 `f_jsonrpc` 与 `f_mcp` 做了 6 轮全量评审（基线 `4f249d5e`，`feature/jsonrpc_mcp` 与 `sts/1.3.x` 无差异），共确认 **7 条严重、48 条一般**问题。这些问题不是风格偏好，而是已经在默认配置下产生错误行为：

1. **默认配置即可触发错误**：无注解的 `@JsonRpc` 方法默认 500ms 超时，所有 handler 被丢进 `spawn` 线程执行，`CurrentHttpContext`（ThreadLocal）失效；任何调用 `CurrentHttpContext.instance` / `ResponseDownload` / `RequestMeta.setResponseStatus` 的 handler 都会变成 `-32603 Internal error`，且错误文案与真实原因无关。
2. **协议能力承诺未兑现**：`input_required` 多轮在自带服务端断裂（`inputResponses` 被静默丢弃），`callToolAuto` 不回传 `requestState`，对接真实服务端必然在 `maxRounds` 处失败；`capabilities.resources.subscribe = true` 却没有 `resources/subscribe` 方法。
3. **内存与资源上限形同虚设**：客户端 `maxResponseBytes` 要等整包读完才判断；`LimiterPool` 按调用方 key 只增不删，每个 key 常驻一个 Timer 与队列；`ToolResultStore.sweep()` 是死代码，过期条目永久占用配额，最终所有大结果被静默截断。
4. **热路径重复工作**：`tools/list` 每请求重建 JSON、`tools/call` 为量字节完整序列化 1~3 次、`paramsSchema` 每请求重走校验并运行时编译正则、`resolve` 每请求全表扫描并重复切片方法名、SSE 每连接 10 次/秒空转。
5. **文档与实现大面积偏差**：README 与设计文档声明的选项、类型、错误码、方法、行为大量不存在或语义相反，按文档写代码无法编译 / 无法调节任何选项。

这些问题覆盖「文档一致性、死代码、空函数、低性能」四个审查维度，必须一次性收敛，否则后续任何演示、接入与压测都建立在错误契约上。

## What Changes

按主题分十条工作流（编号与 `todo.md` 一一对应，详见 `design.md` 第 3 节映射表）：

### A. 客户端传输正确性与内存上限（严重 ×2）

- `HttpJsonRpcTransport` 先用 `Content-Length` 预判，再流式读取并累计字节数，超过 `maxResponseBytes` 立即停止读取并关闭响应，绝不为超大响应分配整包内存。
- 传输层区分「建连/发送阶段失败」与「读响应阶段失败」：只有前者进入 `retryOnConnectFailure` 重试；读响应失败（服务端可能已执行）永不重试。该边界写进 README 与测试。
- `batch` 遇到服务端返回单对象错误（`-32003` 批量超限、`-32600` 空批量）时抛出携带原 `code` / `data` 的 `JsonRpcException`，不再合成 N 条 `-32603`。
- `error.code` 非数字、响应体非法 JSON 等一律映射为 `JsonRpcException`，杜绝 `f_data` 的 `JsonException` 穿透。
- 补 `ClientOptions` 全字段文档，并把传输 SPI 变为公开可替换接口，客户端测试覆盖重试、上限、keep-alive、`callAsync`、批量错误路径。

### B. 超时与执行模型（严重 ×1）

- 无 `@JsonRpcMeta` 的方法默认**不设超时**，handler 在请求线程内联执行，f_mvc 请求级 ThreadLocal 完整可用。
- 显式配置超时才启用「`spawn` + `future.get(t)`」，并在子线程内建立/清理 `CurrentHttpContext`；`''` 明确定义为「不设超时」，不再依赖非法 `Duration` 解析。
- 文档写清：超时只停止等待，不终止 handler。

### C. 服务端热路径与死代码

- `resolve` 改为 O(1)：注册期维护 topic 索引、`JsonRpcMethodMeta` 预计算 `namespace`。
- `paramsSchema` 在注册期编译为 `CompiledSchema`（schema 文档结构校验 + 正则预编译），请求路径不再编译正则。
- 删除 `JsonRpcContext.meta` 与两个 controller 的逐请求头拷贝，删除 `JsonRpcMethodMeta.inputSchema/outputSchema`。
- 请求体上限改为按请求解析配置，修复 `JsonRpcRegistry` 在配置加载前静态初始化导致的永久 2MB 快照。
- `@JsonRpc` 同名重载在宏展开期报编译错误，替代模块加载期抛异常导致的启动失败；宏生成体不再产生 `unused variable` 警告。
- JSON-RPC 响应改由框架按 `application/json` 输出，不再把请求 `Accept`（缺省 `*/*`）写成 `Content-Type`。

### D. MCP 多轮与能力声明

- `inputResponses` / `requestState` 贯通服务端 `tools/call` → `McpToolContext` → `CallToolResult` → 客户端 `callToolAuto`，多轮可真正收敛。
- `capabilities` 只声明已实现能力：`resources.subscribe = false`，`prompts` 保留（已实现），并新增能力一致性测试。
- `MCP-Protocol-Version` 请求头按设计逐请求校验并与 body `_meta` 比对，不一致拒绝。
- MCP 业务错误码退出 f_jsonrpc 保留段：`RESOURCE_NOT_FOUND` 从 `-32002` 迁到 `-32040`。

### E. 分页与订阅生命周期

- `decodeCursor` 返回 `?Int64`：非字符串、解码失败、负偏移一律 `-32602`，不再静默退化为首页或抛越界。
- 订阅者与通知队列有上限、有 TTL：未连接 SSE 的订阅者按 detached TTL 回收，队列满丢弃最旧并计数，`close()` 清空 hub。
- `subscriptionId` 支持断线后在 grace 内重连；30 分钟到点改为 detach 而非永久删除。
- SSE 查询串做百分号解码与 trim；`topics=`（显式空）返回 400，不再反转成「订阅全部」。

### F. stdio 与客户端模型

- stdio 传输改为 `JsonRpcTransport` 实现，复用 `JsonRpcClient` 的请求构造、单调 id、响应 id 匹配、错误映射；跳过 `notifications/*`，非响应行告警跳过，读超时可控。
- `McpClientOptions` 补齐 `headers` / `maxResponseBytes` / `keepAlive` / `retryOnConnectFailure`，HTTP 鉴权可配置。
- `protocolVersion` 协商加锁、变更记日志，并发命中 `-32022` 不再各自改写版本。
- 客户端结果模型与 base 统一：新增 `DiscoverResult` / `ToolPage` / `ResourcePage` / `PromptPage` / `ReadResourceResult` / `GetPromptResult` 与各 `fromJson`，`callTool` 返回 base `CallToolResult`。
- 宏按注解**末段名**匹配（支持全限定名），参数转换走 `JsonValue → Data → T`，返回值只序列化一次。

### G. 限流与并发（严重 ×2）

- `LimiterPool` 有界 + TTL 淘汰，淘汰时调用限流器 `close()` 真正取消 Timer；`f_concurrent` 的 `RateLimiter` 增加可覆盖 `close()`。
- `ConcurrencyGate` 改为「计数 + 上限 + 最近使用时间」条目，release 只减计数、不删 key，空闲 TTL 回收，消除删除竞态与负计数。
- 三层限流逐字段合并：配置 → Builder → 工具，未写的字段继承而非清零；注解 `-1` = 继承、`0` = 不限制、`>0` = 限额，三条路径统一。
- 检查顺序改为「全局并发 → 工具并发 → 调用方并发 → perCallerRpm → perCallerToolRpm → perToolRpm」，被并发拒绝的请求不消耗令牌；并发用 lease 释放，`0` 不再误减他人计数。
- 限流拒绝在 HTTP 层补 `429` + `Retry-After`；caller 派生支持 `X-Forwarded-For`（默认关闭）、`remoteAddr` 去端口、Authorization 取摘要前 16 字节。
- 移除 `any-moment` 后端（SPI 无 release，选择它等于静默关闭限流），配置引用时启动报错。

### H. 大结果与结果存储（严重 ×1）

- 截断按 UTF-8 字符边界切分，中文 / emoji 不再抛异常；截断结果保留 `isError` / `resultType` / `inputRequired` / `requestState`，并继续带 `data.truncated`。
- `tools/call` 只序列化一次用于量字节，大结果路径不再重复 2~3 次序列化。
- `ToolResultStore.put` 在条数 / 字节压力下先 `sweep()` 再判定；重复 token 覆盖时释放旧字节、不重复计数；`evaluate` 快路径无锁、日志移出锁。

### I. 缓存与热路径

- `tools/list` / `resources/list` / `prompts/list` 的条目 JSON 在**首次请求时惰性生成并固化**（每次启动只构造一次，之后只读复用），请求只做切片。
- prompt 参数在注册期算好 `required`，`prompts/get` 不再反射查注解；注册路径合并为一次函数查找。
- SSE 改为事件驱动的阻塞等待（信号量 + 超时），空闲连接不再 10 次/秒空转；拼接用 `StringBuilder`，字节用批量拷贝。

### J. 文档与契约收敛

- `f_jsonrpc/README.md`、`README_en.md`、`f_mcp/README.md`、`README_en.md` 改正错误码、topic 示例、Content-Type、批量 / 请求体上限、`ClientOptions` / `McpClientOptions`、限流派生规则、`subscribe` 声明。
- 两份模块设计文档加「以实现为准」标注，逐条修正被点名的过期 API / 配置 / 错误码 / 能力声明。

### K. verify 复审收口（不改变 A2 / A3 的 spec 语义）

- 订阅中心：`/mcp/sse` 直连创建的订阅者立即 attach；未连接状态以**创建时刻**起算，TTL 到点必回收；`detach` 幂等，30 分钟到点只 detach。
- 版本头：校验顺序改为「头受支持性 → 头与 body 一致性 → body 受支持性」，使「头与 body 不一致 → `-32602`」可达。
- 限流配置：CSV **中间空段**报错（空段后仍有非空段），尾部空段仍视为省略。
- 测试证据：补齐 T41 / T11 / T32 / T33 / T29 / T36 / T38 / T27 / T1.1 缺失用例。
- 文档：设计文档清除 MCP 侧 `-32002`、`AdaptivePolicy`、`subscribe`、`any-moment` 残留；`McpConfig` / `Mcp` 宏注释同步。
- 规划卫生：补齐 7 个 MODIFIED 块缺失的既有场景，使 `openspec validate` 归零。
- 规划产物布局：`f_mcp/doc/spec/<change>/` 只放 MCP 侧（`specs/mcp`、`specs/mcp-guardrails`）与 proposal / design / tasks；`specs/json-rpc` 与 `.openspec.yaml` 不进该副本，`json-rpc` spec 的唯一副本在 `f_jsonrpc/doc/spec/<change>/`。

> 「头与 body 不一致 → `-32602`」与「CSV 中间空段报错」两条 spec 场景保持原文，本阶段只改实现与测试。

## Impact

### 受影响模块

| 模块 | 变更性质 |
| --- | --- |
| `f_jsonrpc` | 客户端传输层、服务端分发 / 校验 / 超时、宏、`README` 与设计文档 |
| `f_mcp` | 协议常量、服务端能力 / 分页 / 订阅 / 结果 / 限流、客户端传输与模型、宏、`README` 与设计文档 |
| `f_data` | 新增 `JsonSchemaValidator.compile` / `CompiledSchema`（供 f_jsonrpc 注册期使用） |
| `f_mvc` | `CurrentHttpContext` 增加公开的作用域执行入口；无行为变更 |
| `f_concurrent` | `RateLimiter` 增加可覆盖的 `close()`，定时器型限流器实现取消 |

### 破坏性变更（需在 README「迁移」小节列出）

- `JsonRpcContext.meta` 字段删除。
- `JsonRpcMethodMeta.inputSchema` / `outputSchema` 构造参数删除。
- `JsonRpcServer.handle` 返回 `?JsonValue`（不再返回字节）。
- `McpProtocol.RESOURCE_NOT_FOUND` 由 `-32002` 改为 `-32040`。
- `McpProtocol.decodeCursor` 返回 `?Int64`。
- `McpCallToolResult` 改为 `CallToolResult`（保留类型别名）；`McpClient.listTools` 等返回强类型模型。
- `mcp_rateLimitBackend=any-moment` 不再可用。
- `ToolRateLimit.maxConcurrency` 语义改为「该工具的并发上限」，全局并发只取服务级 `maxConcurrency`。
- `@McpToolMeta` 的数值默认值由 `0` 改为 `-1`（继承），`0` 明确为「不限制」。

### 不受影响

- JSON-RPC 2.0 线协议（方法名、id 保真、错误对象形态）不变。
- MCP `2026-07-28` 的请求 / 响应结构（除新增可选 `requestState` 与错误码迁移）不变。
- HTTP 路由、注解名、包名不变。
- A2 / A3 的 spec 场景文本不变：`MCP-Protocol-Version` 头与 body 不一致仍返回 `-32602`；`mcp_rateLimit` CSV 中间空段仍须报错。

## 非目标

- 不做异步 Servlet / 事件循环改造（SSE 仍占用一个 f_mvc 工作线程，只消除空转 CPU）。
- 不实现 `resources/subscribe` / `unsubscribe` 与逐资源通知（因此声明 `subscribe=false`）。
- 不重写 JSON Schema 校验语义（保留文档遍历器作为唯一语义来源，只做注册期校验与正则预编译）。
- 不修复本次报告未列出的「建议」项与报告范围外的模块。
- 不新增 MCP 方法或 JSON-RPC 扩展方法。
