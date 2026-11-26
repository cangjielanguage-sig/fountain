# Proposal

## Why

仓库里没有 Agent-to-Agent（A2A）协议的实现。A2A 的线上协议本质是「HTTP POST + JSON-RPC 2.0 方法调用」，
与已有的 `fountain::f_jsonrpc` 完全同构；缺的只是**数据模型 + 任务状态机 + 三个方法处理器 + 客户端薄封装**。

设计基线已落盘 `f_a2a/doc/a2a-protocol.md`：协议映射、数据模型、状态机、错误码、支持边界都在那里，
本变更按它逐条实现。

## What Changes

新建动态库模块 `f_a2a`（`package fountain::f_a2a`，`output-type = "dynamic"`，依赖 `f_jsonrpc` / `f_data` / `f_log` / `f_collection`）：

| 包 | 内容 |
|---|---|
| `fountain::f_a2a.model` | `A2aAgentCard` / `A2aSkill` / `A2aCapabilities` / `A2aTask` / `A2aTaskState` / `A2aMessage` / `A2aPart` / `A2aArtifact` / `A2aError`（错误码常量） |
| `fountain::f_a2a.server` | `A2aExecutor`（宿主实现）、`A2aExecutionResult`、`A2aTaskStore` + `InMemoryA2aTaskStore`、`A2aServer`（注册 `a2a.message.send` / `a2a.tasks.get` / `a2a.tasks.cancel`） |
| `fountain::f_a2a.client` | `A2aClient`（`send` / `get` / `cancel` / `close`），薄封装 `JsonRpcClient` |
| `fountain::f_a2a` | 门面包：`public import` 以上三个包 |

行为约定（详见设计文档）：

- `send` 同步执行：建任务 → `working` → 执行器返回 → 落终态（`completed` / `failed` / `input-required`）；
- `get` 未知 id → `JsonRpcException(-32020)`；`cancel` 终态任务 → `-32021`；非文本 `Part` → `-32023`；
- `register()` 幂等；任务存储默认内存实现（`Mutex` 保护）；
- **流式与扩展能力全部实现**：`message/stream`、`tasks/resubscribe`、push notification、非文本 `Part`（`file` / `data`）、
  `agent/getAuthenticatedExtendedCard`；流式依赖 `f_jsonrpc` 的 SSE 扩展（`add-jsonrpc-sse`，`GET /rpc/stream`），
  **`f_mvc` 不改**。

## Capabilities

### New Capabilities
- `a2a-protocol`：A2A 任务模型、状态机、服务端方法注册与客户端调用。

## Impact

- 新增目录 `f_a2a/`（`cjpm.toml` / `README.md` / `README_en.md` / `doc/` / `src/`），`.modules` 增加一行 `f_a2a`；
- 不改动任何既有模块的公开 API；
- 根 `cjpm.toml` 的聚合依赖与 `src/` shim **不动**（新模块不登记进聚合根，与 `f_jsonrpc` 现状一致）；
- 测试：新增用例覆盖设计文档 §8 的 12 条矩阵。
