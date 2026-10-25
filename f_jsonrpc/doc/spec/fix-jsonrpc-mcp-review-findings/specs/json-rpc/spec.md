# Spec Delta

## Purpose

收敛 `f_jsonrpc` 在传输层、服务端分发、超时执行模型、注册期校验与错误码契约上的缺陷，使实现与对外承诺一致，并把 7 条严重 / 48 条一般中的 `f_jsonrpc` 部分（R1、R2 共 18 条）落到可验收的需求上。

## MODIFIED Requirements

### Requirement: 方法表与元数据

服务端 MUST 提供运行期方法表：按名字注册、重复注册 MUST 抛错、方法元数据 MUST 携带 `description` / `timeout` / `paramsSchema` 并可通过 `methods()` 读取；`invoke` MUST 绕过 HTTP 直接调用 handler。

方法元数据 MUST NOT 再声明无生产读取者的 `inputSchema` / `outputSchema`；MCP 的工具描述由 `f_mcp` 自己的 `McpTool` 维护。

`JsonRpcMethodMeta` MUST 在构造期预计算 `namespace`（第一个 `.` 之前的前缀，不含 `.` 时为空串），请求路径 MUST NOT 重复切片方法名。

同一 `@JsonRpc` 类内若两个 public 实例方法生成相同方法名，宏 MUST 在编译期报错并指出冲突方法名；MUST NOT 把冲突推迟到模块加载期抛异常。

#### Scenario: 重复注册

- **WHEN** 同一个方法名被注册两次
- **THEN** 注册阶段抛 `JsonRpcException`，且不覆盖已有方法

#### Scenario: 元数据可读

- **WHEN** 注册了带 `description` 与 `timeout` 的方法
- **THEN** `methods()` 返回的元数据中包含这两项，顺序按方法名稳定排序

#### Scenario: 本地直调

- **WHEN** 调用 `invoke("ping", params: ...)` 且未涉及 HTTP
- **THEN** 直接返回 handler 结果，不需要构造 `HttpContext`

#### Scenario: 同名重载

- **WHEN** 一个 `@JsonRpc` 类里有两个同名、参数类型不同的 public 方法
- **THEN** 编译期报错，消息包含冲突的完整方法名；模块加载期不再因 `duplicate json-rpc method` 失败

#### Scenario: 无 inputSchema 字段

- **WHEN** 读取 `JsonRpcMethodMeta` 的公开成员
- **THEN** 不存在 `inputSchema` / `outputSchema`，编译期即可发现误用

### Requirement: topic 命名空间过滤

`/rpc/{topic}` 端点 MUST 把 `topic` 作为方法名的命名空间过滤：请求体中的 `method` 仍是完整名，`topic` 为空时不过滤；`topic` 非空但没有任何方法属于该命名空间时 MUST 返回 `-32004`。

判定 MUST 为 O(1)：注册期维护 topic 索引，请求期 MUST NOT 遍历整张方法表，也 MUST NOT 为判定再构造方法名前缀字符串。

#### Scenario: 命名空间内命中

- **WHEN** 端点为 `/rpc/kb`，请求 `method` 为 `kb.search`
- **THEN** 命中并执行 `kb.search`

#### Scenario: 跨命名空间

- **WHEN** 端点为 `/rpc/kb`，请求 `method` 为 `crm.list`
- **THEN** 返回 `-32601`，不执行任何 handler

#### Scenario: 未知 topic

- **WHEN** 端点为 `/rpc/none`，且没有任何方法以 `none.` 开头
- **THEN** 返回 `-32004`

#### Scenario: 方法名不含点

- **WHEN** 请求 `method` 为 `ping`（无命名空间）
- **THEN** 只能从 `/rpc` 调用；从任何 `/rpc/{topic}` 调用都返回 `-32601`

#### Scenario: 注册期索引与运行期一致

- **WHEN** 运行期通过 `addMethod` 新增 `ns.late`
- **THEN** 立即可以从 `/rpc/ns` 调用 `ns.late`，无需重建 server

### Requirement: 错误码与错误对象

服务端 MUST 使用 JSON-RPC 2.0 的错误对象形态（`code` / `message` / 可选 `data`），并遵循码段划分：`-32001 ~ -32004` 为框架保留，`-32020 ~ -32099` 为业务可用。除请求体超限（HTTP 413）、限流拒绝（HTTP 429）与框架级异常（5xx）外，协议错误 MUST 返回 HTTP 200。

框架实际产生的保留码 MUST 只有：`-32002` 超时、`-32003` 批量条数超限、`-32004` 未知 topic。`-32001` MUST 标记为「保留、当前实现不产生」，`messageOf` 保留其文案；MUST NOT 在 README / 设计文档中把通用异常映射到 `-32001`。

`-32003` 的含义 MUST 只描述「批量条数超限」，MUST NOT 声称包含并发限流（并发限流由 `f_mcp` 的 `-32050` 负责）。

#### Scenario: 协议错误仍是 HTTP 200

- **WHEN** 请求触发 `-32601` / `-32602` / `-32603`
- **THEN** HTTP 状态码为 200，错误放在响应体的 `error` 对象里

#### Scenario: 业务错误码

- **WHEN** handler 抛出 `JsonRpcException(-32020, "not found", data: ...)`
- **THEN** 响应 `error.code = -32020`，`message` 与 `data` 原样返回

#### Scenario: 未捕获异常

- **WHEN** handler 抛出普通异常
- **THEN** 响应 `error.code = -32603`，`message` 为固定文案，异常细节只进日志

#### Scenario: 保留码不误标

- **WHEN** 阅读 README 的错误码表
- **THEN** `-32001` 标注为「保留、当前不产生」，`-32003` 只对应批量条数超限

### Requirement: 编码与大小限制

服务端 MUST 只接受 UTF-8；请求体不是合法 UTF-8 或 JSON 解析失败 MUST 返回 `-32700`。请求体超过 `maxBodyBytes` MUST 返回 `-32600` 并由接入层映射为 HTTP 413。

`maxBodyBytes` MUST 在每次请求时解析：显式 `maxBodyBytes(n)` 优先；未显式配置时 MUST 读取当时的 `MVCConfig.maxRequestBodySize`，仍缺省才用 2 MiB。MUST NOT 在类静态初始化时把配置快照成常量。

`maxBatchSize`（默认 100）与 `maxBodyBytes` 的默认值、判定点与错误 `data` 字段 MUST 写入 README。

#### Scenario: 非法 JSON

- **WHEN** 请求体为 `{not json`
- **THEN** 返回 `-32700`

#### Scenario: 非法 UTF-8

- **WHEN** 请求体包含无法按 UTF-8 解码的字节
- **THEN** 返回 `-32700`，不尝试其他字符集

#### Scenario: 超限

- **WHEN** 请求体字节数超过 `maxBodyBytes`
- **THEN** 返回 `-32600`，`data.limit` 标明上限，接入层给出 HTTP 413

#### Scenario: 配置在模块加载后生效

- **WHEN** `@JsonRpc` 注册代码先于 `MVCStarter` 触发了 `JsonRpcRegistry.defaultServer`，随后配置加载 `mvc_maxRequestBodySize = 8388608`
- **THEN** 一个 4 MiB 请求被接受，而不是按 2 MiB 拒绝

#### Scenario: 批量超限可识别

- **WHEN** 一次批量含 101 条请求且 `maxBatchSize = 100`
- **THEN** 返回单对象 `-32003`，`data.limit = 100`、`data.size = 101`

### Requirement: 参数校验接线

方法元数据 MUST 支持携带 `paramsSchema`（`JsonObject`），并 MUST 在注册期编译为预编译校验器；请求进入 handler 前 MUST 用该预编译校验器校验 `params`，失败 MUST 返回 `-32602` 且 `error.data` 为 `ValidationResult.toJson()`。

编译 MUST 在注册期完成：

1. 校验 schema 文档结构合法（关键字取值类型正确），非法 schema MUST 在注册期抛错；
2. 预编译所有 `pattern` 正则，请求路径 MUST NOT 再调用 `regex(...)`；
3. 请求路径 MUST NOT 重新解析 schema 文档中的关键字取值。

`CompiledSchema` MUST 与 `JsonSchemaValidator.validate(schema, value)` 保持完全相同的校验语义（同一份遍历逻辑，仅复用编译结果）。

#### Scenario: 参数不合法

- **WHEN** 方法声明 `minLength: 2` 的 `query` 字段，请求传 `{"query":"a"}`
- **THEN** 返回 `-32602`，`error.data` 包含 `path` 与 `keyword`，且 handler 未被调用

#### Scenario: 未声明 schema

- **WHEN** 方法没有 `paramsSchema`
- **THEN** 跳过校验，handler 直接收到原始 `params`

#### Scenario: 非法 schema 注册失败

- **WHEN** `paramsSchema` 的 `pattern` 不是字符串
- **THEN** `addMethod` / 构造 `JsonRpcMethodMeta` 抛错，服务启动阶段即可发现

#### Scenario: 正则只编译一次

- **WHEN** 同一方法被连续调用 100 次，schema 含 `pattern`
- **THEN** 正则编译次数为 1（注册期），请求路径命中缓存

### Requirement: 单方法超时

方法元数据 MUST 支持可选 `timeout`；**默认无超时**。没有 `timeout` 时 handler MUST 在请求线程内联执行，MUST NOT 额外 `spawn`，以保证 f_mvc 请求级 ThreadLocal（`CurrentHttpContext`）可用。

显式配置超时时：

- 超时后 MUST 返回 `-32002`，且 MUST NOT 声称已终止 handler；
- handler 在子线程执行时，框架 MUST 在子线程内设置与请求一致的 `CurrentHttpContext`，并在结束时清理；
- `@JsonRpcMeta[description, '']` MUST 表示「不设超时」，MUST NOT 再解析成 `Duration`。

`JsonRpcContext` MUST 暴露 deadline 供 handler 自查。

#### Scenario: 未配超时

- **WHEN** 方法没有 `@JsonRpcMeta`，或注解的 timeout 为空串
- **THEN** `getMeta` 返回空 timeout，handler 在请求线程执行，不产生 `-32002`

#### Scenario: 默认路径 ThreadLocal 可用

- **WHEN** 无注解方法的 handler 调用 `CurrentHttpContext.instance`
- **THEN** 取到当前请求的 `HttpContext`，不抛 `NoneValueException`

#### Scenario: 空串表示不设超时

- **WHEN** 方法标注 `@JsonRpcMeta['通知', '']`
- **THEN** `timeout` 为 `None`，handler 内联执行，不触发 `Duration.parse`

#### Scenario: 超时返回

- **WHEN** handler 阻塞时间超过其显式 `timeout`
- **THEN** 调用方收到 `-32002`，响应耗时接近该超时值

#### Scenario: 显式超时下 ThreadLocal 仍可用

- **WHEN** 方法配置了超时，handler 在子线程调用 `CurrentHttpContext.instance`
- **THEN** 取到当前请求的 `HttpContext`；handler 结束后该线程的 ThreadLocal 被清理

### Requirement: HTTP 接入注解

`@JsonRpcMapping` MUST 是 `f_mvc.RequestMapping` 的子类，`method` / `consumes` / `produces` 固定为 `POST` / `application/json` / `application/json`，只暴露 `path` / `params` / `headers` / `ignoreAuth` / `ignorePrivilege`；`@Controller` 宏 MUST 能识别它并注册 `RequestMeta`。

JSON-RPC 响应的 `Content-Type` MUST 为 `application/json`（可带 `charset=utf-8`）。MUST NOT 把请求的 `Accept`（缺省 `*/*`）原样写成响应 `Content-Type`。

#### Scenario: 注解被识别

- **WHEN** 一个 `@Controller` 类的方法标注 `@JsonRpcMapping[path:'/rpc']`
- **THEN** `MVCStarter.generateAndRegister` 返回一条 `RequestMeta`，其 `method` 为 POST、`consumes` 与 `produces` 均含 `application/json`

#### Scenario: 默认端点

- **WHEN** 模块被加载
- **THEN** 内置 controller 注册 `/rpc` 与 `/rpc/{topic}` 两条路由，且 controller 方法接收原始字节、返回 `Any`

#### Scenario: 第三方客户端不带 Accept

- **WHEN** 请求不带 `Accept` 头
- **THEN** 响应 `Content-Type` 为 `application/json`，不是 `*/*`

### Requirement: 客户端调用

`JsonRpcClient` MUST 提供 `call` / `callAsync` / `notify` / `batch` / `close`；HTTP 传输 MUST 使用 POST + `application/json; charset=utf-8`，默认复用连接池、默认不重试；服务端返回的 `error` MUST 抛 `JsonRpcException`（携带 `code` / `message` / `data`），只有传输失败才抛 `IOException`。

客户端 MUST 保证：

1. **响应上限**：先用 `Content-Length` 预判，再流式累计字节数；超过 `maxResponseBytes` 时 MUST 停止读取、关闭响应并抛错，MUST NOT 先读完整个 body。
2. **重试边界**：`retryOnConnectFailure` 只对建连/发送阶段失败生效；读响应阶段的任何失败 MUST NOT 重试。
3. **批量错误**：服务端返回单对象错误时 MUST 抛 `JsonRpcException`，保留原 `code` / `message` / `data`；MUST NOT 合成 N 条 `-32603`。
4. **异常封闭**：`error.code` 非数字、`error` 非对象、响应体非法 JSON MUST 都转成 `JsonRpcException`，MUST NOT 泄漏 `JsonException` / `DataException`。

#### Scenario: 同步调用

- **WHEN** 调用已存在的 `ping`
- **THEN** 返回 `result`，不抛异常

#### Scenario: 服务端业务错误

- **WHEN** 服务端返回 `error.code = -32020`
- **THEN** 客户端抛 `JsonRpcException`，其 `code` 为 `-32020`

#### Scenario: 通知不等待

- **WHEN** 调用 `notify`
- **THEN** 只发送请求，不解析 `result`，服务端错误不抛给调用方

#### Scenario: 批量同序

- **WHEN** `batch` 传入 N 条调用
- **THEN** 返回 N 条响应，顺序与输入一致，每条含自己的结果或错误

#### Scenario: 批量被服务端拒绝

- **WHEN** `batch` 传 200 条、服务端返回单个 `-32003` 对象
- **THEN** 客户端抛 `JsonRpcException(-32003, ...)`，`data.limit` 与 `data.size` 可读

#### Scenario: 非数字错误码

- **WHEN** 响应为 `{"error":{"code":"oops","message":"x"}}`
- **THEN** 抛 `JsonRpcException`（code 为 `-32603`，message 保留服务端文案），不抛 `JsonException`

#### Scenario: 声明 Content-Length 超限

- **WHEN** 响应头 `Content-Length = 10485760`，`maxResponseBytes = 8388608`
- **THEN** 客户端不读取 body，立即抛错并关闭响应

#### Scenario: 无 Content-Length 时流式截断

- **WHEN** 服务端用 chunked 持续输出 20 MiB，`maxResponseBytes = 1 MiB`
- **THEN** 客户端在读到约 1 MiB 时停止并抛错，峰值内存不超过上限量级

#### Scenario: 读响应失败不重试

- **WHEN** `retryOnConnectFailure = 3`，建连成功、请求已发送、读响应时连接中断
- **THEN** 客户端只抛 `IOException`，不重新发送请求

#### Scenario: 建连失败重试

- **WHEN** `retryOnConnectFailure = 2`，前两次建连失败、第三次成功
- **THEN** 调用成功，底层共尝试 3 次

## ADDED Requirements

### Requirement: 可替换的客户端传输 SPI

`JsonRpcTransport` 与 `JsonRpcClient(transport:)` MUST 公开，允许上层（如 `f_mcp` 的 stdio）复用请求构造、单调自增 id、响应 id 匹配与错误映射，而无需自建 JSON-RPC 消息层。

传输实现 MUST 通过抛出专用异常（`JsonRpcConnectException <: IOException`）标记「可重试的连接阶段失败」，其余 `IOException` 一律视为不可重试。

#### Scenario: 自定义传输

- **WHEN** 上层实现 `JsonRpcTransport` 并构造 `JsonRpcClient(transport: t)`
- **THEN** `call` / `batch` / `notify` 行为与 HTTP 传输一致，id 从 1 单调递增

#### Scenario: 只有专用异常触发重试

- **WHEN** 传输抛普通 `IOException`
- **THEN** `sendWithRetry` 不重试，直接抛出

### Requirement: 宏生成代码无编译警告

`@JsonRpc` 生成的 handler MUST 引用或显式忽略 `JsonRpcContext` 参数，MUST NOT 因未使用局部变量产生 `unused variable` 警告；使用方的构建输出 MUST NOT 出现来源于宏展开的警告。

#### Scenario: 构建日志

- **WHEN** 编译一个含多个 `@JsonRpc` public 方法的模块
- **THEN** `cjpm build` 输出中没有 `note: unused variable: '__jsonrpc_ctx'`

### Requirement: 客户端选项与传输测试

`ClientOptions` MUST 在 README 中逐字段说明 `timeout`（默认 30s，仅作用于读 / 写超时，不含建连与整体 deadline）、`headers`、`maxResponseBytes`（默认 8 MiB）、`keepAlive`、`retryOnConnectFailure`（默认 0）。

`f_jsonrpc` 的客户端测试 MUST 覆盖：建连失败重试与读响应失败不重试、`Content-Length` 超限与流式超限、`keepAlive=false` 的 `Connection: close`、连续两次调用复用连接、`callAsync`、批量单对象错误、非数字错误码。

#### Scenario: 选项可见

- **WHEN** 阅读 README 客户端章节
- **THEN** 五个 `ClientOptions` 字段都有默认值与影响说明，且写明 `timeout` 不覆盖建连阶段

#### Scenario: 连续两次调用

- **WHEN** 同一个 `JsonRpcClient` 对同一 endpoint 连续调用两次
- **THEN** 第二次调用成功，不出现 `Socket is already closed`

#### Scenario: 关闭 keep-alive

- **WHEN** `keepAlive = false`
- **THEN** 请求头包含 `Connection: close`
