# Design

## Context

- 本变更在 fountain 仓库内（工作树 `feature/jsonrpc_mcp`，基线 `sts/1.3.x`）。
- `f_mvc` 已提供：`@Controller` 宏（编译期展开为 `MVCStarter.generateAndRegister`）、`RequestMapping` 抽象基类、`RequestMeta`（`consumes` 是路由表键、`produces` 是内容协商依据，均为 `private let`，只能由注解填充）、`CurrentHttpContext`、`MVCConfig.maxRequestBodySize`。
- 约束一（来自设计文档）：**`f_mvc` 零改动**。程序化构造 `RequestMeta` 无法写 `consumes` / `produces`，且 `setHandle` 依赖 `f_bean` 注册，因此接入方式只能是「`RequestMapping` 子类 + `@Controller`」。
- 约束二：`f_data.json.JsonSchema` 目前只是 schema 构造器，没有 `validate`；`JsonObjectSchema` 不携带 `properties`（成员 schema 只存在于 `toJsonSchema<T>()` 生成的文档里），所以校验必须有两个入口。
- 环境：`fboot` 未安装，`HttpContext` 由 stdx 构造且测试中不可实例化。协议逻辑的验证以「进程内直调 + 路由元数据」为主，HTTP 级冒烟留待有 fboot 的环境。

## Goals / Non-Goals

**Goals:**

- 按 `f_jsonrpc/doc/f_jsonrpc模块设计.md` 交付可用的 JSON-RPC 2.0 服务端与客户端：消息模型、方法表、错误模型、批量/通知、topic 命名空间、超时、参数校验接线。
- 为 `f_data` 增加通用 `JsonSchema.validate`（实例版 + 文档版），错误结构化，fail-closed。
- 全部行为以仓颉单元测试钉住；`f_mvc` 零改动。

**Non-Goals:**

- SSE / WebSocket 传输、JSON-RPC over 其他传输。
- `$ref` / 组合关键字（`allOf` / `anyOf` / `oneOf` / `not`）的解析（fail-closed 拒绝）。
- 分布式限流、方法级权限体系（复用 `f_mvc` 路由级鉴权）。
- 本变更不实现 `f_mcp`（仅建模块骨架与文档，实现在后续变更）。

## Decisions

### D1. 接入方式：`@JsonRpcMapping` + `@Controller`

`JsonRpcMapping <: RequestMapping`，`method = POST`、`consumes = produces = 'application/json'` 硬编码，只暴露 `path` / `params` / `headers` / `ignoreAuth` / `ignorePrivilege`。
`f_mvc` 的 `RequestMeta.generate` 按基类匹配注解（`if (let a: RequestMapping <- annotation)`），跨包继承合法，因此 **f_mvc 零改动**。

- 备选（已否决）：程序化构造 `RequestMeta`——`consumes` / `produces` 是 `private let`，空 `consumes` 直接 415，空 `produces` 直接 406。
- 备选（已否决）：新增 `JsonRPCMeta` / `@JsonRPC` 宏——`@Controller` 只看 public 实例方法，按基类识别，再包一层没有信息增量。

### D2. 一个端点 = 一个 `RequestMeta`，`method` 在体内分发

`/rpc` 与 `/rpc/{topic}` 各一个 public 方法（`/rpc` 上取不到 `{topic}`，不能用一个方法挂两条路径）。批量、方法增删都发生在方法表内，不动路由。

### D3. 包与文件布局（`package fountain::f_jsonrpc`，单包扁平，与 `f_mvc` 一致）

| 文件 | 内容 |
|---|---|
| `JsonRpcProtocol.cj` | 常量：版本、默认路径、错误码、默认上限 |
| `JsonRpcException.cj` | `JsonRpcException`、`JsonRpcError`（错误对象构造） |
| `JsonRpcContext.cj` | `JsonRpcContext`（`http` / `id` / `endpoint` / `topic` / `meta` / `deadline` / `setResponseHeader`） |
| `JsonRpcMethodMeta.cj` | `JsonRpcHandler`、`JsonRpcMethodMeta`（含 `paramsSchema` / `compiled` / `timeout`） |
| `JsonRpcServer.cj` | `JsonRpcServer` + `Builder` + `handle` / `invoke` / `methods` / `addMethod` |
| `JsonRpcMapping.cj` | `@JsonRpcMapping` 注解 |
| `JsonRpcController.cj` | 内置 `@Controller`，`/rpc` 与 `/rpc/{topic}` |
| `JsonRpcRegistry.cj` | 进程内默认 server 单例 + 方法注册入口 |
| `JsonRpcClient.cj` | `JsonRpcClient` / `ClientOptions` / 内部传输接缝 |

测试与被测代码同包，文件 `*_test.cj`，与仓库既有布局一致。

### D4. 错误模型：协议错误一律 HTTP 200

`-32700` / `-32600` / `-32601` / `-32602` / `-32603` 与 `-32001 ~ -32004` 进响应体的 `error` 对象；只有请求体超限映射 413、框架级异常映射 5xx。`-32603` 的 `message` 固定文案，细节写日志（`f_log`）。

### D5. 通知用 `Unit` 表达「不写响应体」

`handle` 返回 `?Array<Byte>`：`None` 表示通知；controller 方法返回 `Any`，`Some(bytes)` 返回字节、`None` 返回 `()`。`f_mvc` 的 `setHandle` 对 `Unit` 分支不触碰响应构建器。
**未验证项**：该分支最终状态码是 200 还是 204。无 fboot 环境下无法做 HTTP 冒烟，记为遗留验证项（两份设计共同关注）。

### D6. 方法表线程安全、可运行期增删

`ConcurrentHashMap<String, JsonRpcMethodMeta>`；`addMethod` 在重复名时抛 `JsonRpcException(-32603)`；`methods()` 按名字排序（供 `f_mcp` 的 `tools/list` 稳定序）。
超时用 `spawn` + `Future.get(timeout)`：超时返回 `-32002`，**不终止 handler**；`JsonRpcContext.deadline` 供 handler 自查。

### D7. topic 过滤

`topic` 非空时：方法名第一个 `.` 之前的部分必须等于 `topic`，否则 `-32601`；若方法表中没有任何方法属于该 `topic`，返回 `-32004`。无点方法只属默认命名空间。

### D8. `f_data.JsonSchema.validate`

- 在 `JsonSchema` 上加实例方法 `validate(value, options!)` 与静态重载 `validate(schema, value, options!)`；若编译器无法区分重载，退化为 `JsonSchemaValidator.validate(schema, value, options)` 并同步修订规格。
- 实现放新文件 `f_data/src/json/JsonSchemaValidator.cj`（`extend JsonSchema` + 内部校验器），避免把 288 行的构造器文件继续撑大。
- 关键字矩阵与 fail-closed 策略严格按设计 4.7.3 / 4.7.5；正则走 `f_regex`（`f_data` 已有依赖）：`format` 的固定模式 `solid: true`，schema 文档里的 `pattern` `solid: false`。
- `maxErrors` 达到即提前返回；`uniqueItems` 在元素数 > 1000 时跳过并记入 `skipped`。

### D9. 客户端

`JsonRpcClient` 持有 `stdx.net.http.Client`（复用连接池）；默认不重试；`call` 同步、`callAsync` 用 `spawn` 包装、`notify` 不解析响应、`batch` 按输入顺序返回。
为可测性，内部定义包内 `JsonRpcTransport` 接缝（`send(body: Array<Byte>): Array<Byte>`），HTTP 实现为默认；单测用假传输验证请求构造与响应解析，另加一条本机 loopback 集成用例（可用时）。

### D10. `.modules` 与聚合根

两个新模块登记到 `.modules` 的 `[include]`（新模块要能发布到中心仓）；**不改**仓库根 `src/` 的聚合 shim 与根 `cjpm.toml`（已冻结，新模块不登记）。

## Risks / Trade-offs

| 风险 | 处置 |
|---|---|
| `Unit` 分支的 HTTP 状态码（200/204）未知 | 记为遗留验证项；通知本就不该有响应体，两种状态码对客户端都可接受 |
| 测试无法构造 `HttpContext` | `JsonRpcContext.http = None` 的路径覆盖全部协议逻辑；`setResponseHeader` 的 HTTP 分支只做编译级验证，留待 fboot 冒烟 |
| `spawn` 超时后 handler 仍在跑 | 文档与 README 明示「超时只提前返回，不终止」；`deadline` 供 handler 自查 |
| 静态/实例 `validate` 重载歧义 | 设计已给退化路径（`JsonSchemaValidator.validate`），实现时以编译器为准并同步规格 |
| `f_mvc` 未来改成枚举具体注解类型 | 兜底退回 `@PostMapping[path:'/rpc', consumes:'application/json', produces:'application/json']`，行为等价、仍零改动 |
| 无 fboot，无法做端到端 HTTP 冒烟 | 交付说明中明确未覆盖项；verify 以单测 + 路由元数据为准 |
