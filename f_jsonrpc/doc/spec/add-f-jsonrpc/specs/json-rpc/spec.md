# Spec Delta

## Purpose

定义 `f_jsonrpc` 的对外行为：把 JSON-RPC 2.0 的请求/响应映射到 `f_mvc` 的一个 HTTP 端点，维护运行期方法表，并给出符合规范的错误模型、批量/通知语义、客户端调用与参数校验接线。

## ADDED Requirements

### Requirement: 单请求处理

服务端 MUST 接受单个 JSON-RPC 2.0 请求对象，按请求体中的 `method` 在方法表内分发，并把 handler 的返回值作为 `result` 写回响应对象。响应 MUST 包含 `jsonrpc: "2.0"`、与请求相同的 `id`，以及 `result` 或 `error` 之一。

#### Scenario: 成功调用

- **WHEN** 请求体为 `{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}` 且 `ping` 已注册
- **THEN** 响应为单个对象，`jsonrpc` 为 `"2.0"`、`id` 为 `1`、`result` 为 handler 的返回值，且不含 `error`

#### Scenario: 方法不存在

- **WHEN** 请求的 `method` 未注册
- **THEN** 响应为 `error.code = -32601`，且 `error.message` 不包含服务端已注册方法清单

#### Scenario: 请求体的 `method` 不作为路由

- **WHEN** 同一个端点先后收到 `method` 为 `a` 与 `b` 的两个请求
- **THEN** 两者都命中同一条 HTTP 路由，由方法表分发，不需要重启或重新注册路由

### Requirement: 批量与通知

服务端 MUST 支持批量（JSON 数组）与通知（无 `id`）。批量响应 MUST 只包含有 `id` 的条目；全为通知的批量 MUST 不产生响应体；空数组 MUST 返回单个 `-32600` 错误对象；超过 `maxBatchSize` MUST 整批拒绝并返回单个 `-32003`。

#### Scenario: 批量混合通知

- **WHEN** 批量包含 2 条有 `id` 与 1 条无 `id` 的请求
- **THEN** 响应数组只含 2 个元素，且元素顺序与请求中带 `id` 的顺序一致

#### Scenario: 全部是通知

- **WHEN** 批量中每条请求都没有 `id`
- **THEN** 服务端执行全部 handler，且 `handle` 返回 `None`（不写响应体）

#### Scenario: 空批量

- **WHEN** 请求体是空数组 `[]`
- **THEN** 返回单个错误对象（不是数组），`error.code = -32600`

#### Scenario: 批量超限

- **WHEN** 批量长度超过 `maxBatchSize`
- **THEN** 返回单个 `error.code = -32003`，且不执行其中任何一条

#### Scenario: 单条通知

- **WHEN** 单个请求没有 `id`
- **THEN** handler 被执行且 `handle` 返回 `None`；handler 抛异常时不产生响应，但必须记录日志

### Requirement: id 保真

响应中的 `id` MUST 与请求中的 `id` 完全一致，包括类型与数值精度（数字 id 不得变成字符串，大整数不得溢出或被改写）。

#### Scenario: 大整数 id

- **WHEN** 请求 `id` 为超出 `Int64` 范围的整数
- **THEN** 响应 `id` 与请求逐字节等价（按 JSON 值比较相等）

#### Scenario: 字符串 id

- **WHEN** 请求 `id` 为 `"abc"`
- **THEN** 响应 `id` 仍为字符串 `"abc"`

#### Scenario: 显式 null id

- **WHEN** 请求包含 `"id": null`
- **THEN** 该请求按有 id 处理并回填 `null`，不视为通知

### Requirement: 方法表与元数据

服务端 MUST 提供运行期方法表：按名字注册、重复注册 MUST 抛错、方法元数据 MUST 携带 `description` / `inputSchema` / `outputSchema` / `timeout` 并可通过 `methods()` 读取；`invoke` MUST 绕过 HTTP 直接调用 handler。

#### Scenario: 重复注册

- **WHEN** 同一个方法名被注册两次
- **THEN** 注册阶段抛异常，且不覆盖已有方法

#### Scenario: 元数据可读

- **WHEN** 注册了带 `description` 与 `inputSchema` 的方法
- **THEN** `methods()` 返回的元数据中包含这两项，顺序按方法名稳定排序

#### Scenario: 本地直调

- **WHEN** 调用 `invoke("ping", params: ...)` 且未涉及 HTTP
- **THEN** 直接返回 handler 结果，不需要构造 `HttpContext`

### Requirement: topic 命名空间过滤

`/rpc/{topic}` 端点 MUST 把 `topic` 作为方法名的命名空间过滤：请求体中的 `method` 仍是完整名，`topic` 为空时不过滤；`topic` 非空但没有任何方法属于该命名空间时 MUST 返回 `-32004`。

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

### Requirement: 错误码与错误对象

服务端 MUST 使用 JSON-RPC 2.0 的错误对象形态（`code` / `message` / 可选 `data`），并遵循码段划分：`-32001 ~ -32004` 为框架保留，`-32020 ~ -32099` 为业务可用。除请求体超限（HTTP 413）与框架级异常（5xx）外，协议错误 MUST 返回 HTTP 200。

#### Scenario: 协议错误仍是 HTTP 200

- **WHEN** 请求触发 `-32601` / `-32602` / `-32603`
- **THEN** HTTP 状态码为 200，错误放在响应体的 `error` 对象里

#### Scenario: 业务错误码

- **WHEN** handler 抛出 `JsonRpcException(-32020, "not found", data: ...)`
- **THEN** 响应 `error.code = -32020`，`message` 与 `data` 原样返回

#### Scenario: 未捕获异常

- **WHEN** handler 抛出普通异常
- **THEN** 响应 `error.code = -32603`，`message` 为固定文案，异常细节只进日志

### Requirement: 请求形态校验

服务端 MUST 校验 `jsonrpc == "2.0"`、`method` 为非空字符串、`id` 为字符串/数字/null；不合法 MUST 返回 `-32600`，批量为逐条判定（只影响该条）。

#### Scenario: 缺少 jsonrpc 字段

- **WHEN** 请求对象缺少 `jsonrpc` 或值不是 `"2.0"`
- **THEN** 返回 `-32600`

#### Scenario: 批量中部分非法

- **WHEN** 批量里第 1 条合法、第 2 条 `method` 为数字
- **THEN** 响应数组含两条：第 1 条正常结果，第 2 条 `-32600`

### Requirement: 编码与大小限制

服务端 MUST 只接受 UTF-8；请求体不是合法 UTF-8 或 JSON 解析失败 MUST 返回 `-32700`。请求体超过 `maxBodyBytes` MUST 返回 `-32600` 并由接入层映射为 HTTP 413。

#### Scenario: 非法 JSON

- **WHEN** 请求体为 `{not json`
- **THEN** 返回 `-32700`

#### Scenario: 非法 UTF-8

- **WHEN** 请求体包含无法按 UTF-8 解码的字节
- **THEN** 返回 `-32700`，不尝试其他字符集

#### Scenario: 超限

- **WHEN** 请求体字节数超过 `maxBodyBytes`
- **THEN** 返回 `-32600`，`data` 标明超限，接入层给出 HTTP 413

### Requirement: 参数校验接线

方法元数据 MUST 支持携带 `paramsSchema`（`JsonObject`）与预编译的校验器；请求进入 handler 前 MUST 用 `f_data.json.JsonSchema.validate` 校验 `params`，失败 MUST 返回 `-32602` 且 `error.data` 为 `ValidationResult.toJson()`。

#### Scenario: 参数不合法

- **WHEN** 方法声明 `minLength: 2` 的 `query` 字段，请求传 `{"query":"a"}`
- **THEN** 返回 `-32602`，`error.data` 包含 `path` 与 `keyword`，且 handler 未被调用

#### Scenario: 未声明 schema

- **WHEN** 方法没有 `paramsSchema`
- **THEN** 跳过校验，handler 直接收到原始 `params`

### Requirement: 单方法超时

方法元数据 MUST 支持 `timeout`；超时后 MUST 返回 `-32002`，且 MUST NOT 声称已终止 handler（仓颉无抢占式取消）。`JsonRpcContext` MUST 暴露 deadline 供 handler 自查。

#### Scenario: 超时返回

- **WHEN** handler 阻塞时间超过其 `timeout`
- **THEN** 调用方收到 `-32002`，响应耗时接近 `timeout` 而不是 handler 的实际结束时间

#### Scenario: 未配超时

- **WHEN** 方法没有 `timeout`
- **THEN** 同步等待 handler 返回，不产生 `-32002`

### Requirement: 响应头写回

`JsonRpcContext` MUST 提供 `setResponseHeader`，仅在 handler 执行期间有效；`http` 为 `None`（stdio / 本地直调）时 MUST 静默忽略，不抛异常。

#### Scenario: HTTP 场景

- **WHEN** handler 在 HTTP 请求内调用 `setResponseHeader("X-Test","1")`
- **THEN** 该头出现在响应上

#### Scenario: 非 HTTP 场景

- **WHEN** 在 `invoke` 中调用 `setResponseHeader`
- **THEN** 不抛异常，无副作用

### Requirement: HTTP 接入注解

`@JsonRpcMapping` MUST 是 `f_mvc.RequestMapping` 的子类，`method` / `consumes` / `produces` 固定为 `POST` / `application/json` / `application/json`，只暴露 `path` / `params` / `headers` / `ignoreAuth` / `ignorePrivilege`；`@Controller` 宏 MUST 能识别它并注册 `RequestMeta`（`f_mvc` 零改动）。

#### Scenario: 注解被识别

- **WHEN** 一个 `@Controller` 类的方法标注 `@JsonRpcMapping[path:'/rpc']`
- **THEN** `MVCStarter.generateAndRegister` 返回一条 `RequestMeta`，其 `method` 为 POST、`consumes` 与 `produces` 均含 `application/json`

#### Scenario: 默认端点

- **WHEN** 模块被加载
- **THEN** 内置 controller 注册 `/rpc` 与 `/rpc/{topic}` 两条路由，且 controller 方法接收原始字节、返回 `Any`

### Requirement: 客户端调用

`JsonRpcClient` MUST 提供 `call` / `callAsync` / `notify` / `batch` / `close`；HTTP 传输 MUST 使用 POST + `application/json; charset=utf-8`，默认复用连接池、默认不重试；服务端返回的 `error` MUST 抛 `JsonRpcException`（携带 `code` / `message` / `data`），只有传输失败才抛 `IOException`。

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

### Requirement: 只支持 UTF-8 的请求与紧凑序列化

服务端与客户端 MUST 使用紧凑序列化（`toString()`）传输，不得使用美化输出；不得提供 charset 参数或编码探测。

#### Scenario: 紧凑响应

- **WHEN** handler 返回对象结果
- **THEN** 响应体不含换行与缩进空白
