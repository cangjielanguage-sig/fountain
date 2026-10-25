# Proposal

## Why

fountain 已有完整的 MVC/HTTP 框架（`f_mvc`）与 JSON 数据层（`f_data`），但缺少 JSON-RPC 2.0 协议能力。JSON-RPC 是「一个端点、按请求体内的 `method` 分发」的模型，与 MVC 的「一个方法一条路由」正交：把每个 RPC 方法映射成一条路由会破坏批量请求、错误模型与运行期方法增删。

同时，MCP（Model Context Protocol）的消息层就是 JSON-RPC 2.0，且要求服务端支持 `server/discover`、`tools/list`、`tools/call` 等运行期方法表。没有 JSON-RPC 层，MCP 只能重复实现一遍消息模型与错误码。

因此本次先补齐 `f_jsonrpc`（协议层），它是后续 `f_mcp` 的唯一消息层依赖。

## What Changes

- **新增模块 `f_jsonrpc`**（仓颉动态链接库，`output-type = "dynamic"`，路径依赖 `../f_mvc`、`../f_data`、`../f_log`）：
  - `@JsonRpcMapping`：`f_mvc.RequestMapping` 的第六个子类，`method` / `consumes` / `produces` 硬编码为 `POST` + `application/json`，只暴露 `path` / `params` / `headers` / `ignoreAuth` / `ignorePrivilege`
  - `JsonRpcServer` + `Builder`：运行期方法表、单请求 / 批量 / 通知处理、错误映射、批量上限、请求体上限、单方法超时
  - `JsonRpcContext` / `JsonRpcMethodMeta` / `JsonRpcHandler` / `JsonRpcException`
  - `JsonRpcClient`：同步 / 异步 / 通知 / 批量，复用 `stdx.net.http.Client`
  - `JsonRpcRegistry` + 内置 `JsonRpcController`：默认端点 `/rpc` 与 `/rpc/{topic}`，`topic` 作为方法命名空间过滤
- **扩展 `f_data.json`**：新增 `JsonSchema.validate`（实例版 + 文档版两个重载）、`ValidationError` / `ValidationResult` / `ValidationOptions` / `UnknownKeyword`，供 `f_jsonrpc` 做 `-32602` 参数校验（f_jsonrpc 设计 P-1.5）
- **文档与登记**：设计文档迁入 `f_jsonrpc/doc/`；`.modules` 的 `[include]` 登记 `f_jsonrpc` 与 `f_mcp`（后者本次仅建骨架）；README 中英成对
- **硬约束（不改变）**：`f_mvc` 零改动——不新增公开 API、不修改现有行为、不依赖未公开成员

## Capabilities

### New Capabilities

- `json-rpc`: JSON-RPC 2.0 消息模型、方法表、错误码与错误对象、批量与通知、HTTP 接入（注解 + controller）、客户端调用与传输细节
- `json-schema-validation`: `f_data` 的 JSON Schema 运行时校验——实例版与文档版两个入口、关键字支持矩阵、fail-closed 策略、错误路径与 `maxErrors`

### Modified Capabilities

无（`f_mvc` 行为与公开 API 均不变）

## Impact

- **新增代码**：`f_jsonrpc/src/**`（消息模型、服务端、客户端、注解、controller）、`f_jsonrpc/src/*_test.cj`
- **修改代码**：`f_data/src/json/JsonSchema.cj`（新增校验类型与两个 `validate`）、`f_data/src/json/*_test.cj`
- **依赖方向**：`f_jsonrpc` → `f_mvc` / `f_data` / `f_log`；`f_mvc` 不感知 `f_jsonrpc`。路径依赖保持仓库内相对路径，不引入中心仓版本
- **运行期**：模块为动态库，由 `fboot run` 加载；`@Controller` 在 `static init` 注册路由，要求加载发生在 `MVCStarter.initialize()` 之前（沿用 `f_mvc` 现有约束）
- **兼容性**：不修改任何既有公开签名；`f_data` 只做新增（schema 校验），既有 `toJsonSchema` 行为不变
- **发布**：`.modules` 的 `[include]` 增加两个新模块；不修改聚合根 `src/` shim（已冻结）
- **无新增第三方依赖**：仅用 `std` / `stdx` 与仓库内模块
