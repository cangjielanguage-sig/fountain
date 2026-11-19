# Verify 报告 — rework-jsonrpc-macro-and-demos

> 校验方式：`openspec validate --strict` + 融合侧 `fusion_build.sh` 全量测试 + `fboot run` 实机端到端。

## Completeness

- 宏：只保留 `@JsonRpc`；`@JsonRpcMeta` 提供 `timeoutDuration`；`getMeta<T>(funcName, argTypes)` 返回注解对象。
- 删除：`@jsonrpc` / `@jsonrpcmeta` / `parseTimeout` / `JsonRpcRegisteredMeta` / `paramCount` / 宏内 `str`；`JsonRpcRegister` 类整体删除，成员迁入 `JsonRpcRegistry`。
- 修复：`JsonRpcClient` keep-alive 二次请求；`/mcp/sse` 的 chunked 响应。
- 新增：`fjsonrpcdemo`、`fmcpdemo`，均支持 `fboot run`。

## Correctness

- `f_jsonrpc`：58 passed / 0 failed / 0 error。
- `f_mcp`：38 passed / 0 failed / 0 error（新增订阅绑定、mcp_rateLimit、f_concurrent 限流用例）。
- `f_data`：156 passed / 0 failed / 0 error。
- `fjsonrpcdemo e2e`：`JSONRPC_HTTP_CHECKS_OK` + `JSONRPC_DEMO_OK`。
- `fmcpdemo e2e`：`MCP_HTTP_CHECKS_OK` + `MCP_HTTP_DEMO_OK`；服务端 `MCP_LIMIT_DEMO_OK ... fourth_code=-32050`。

## HTTP 实测矩阵

| 请求 | 结果 |
|---|---|
| `POST /rpc` 正常 | 200 + JSON-RPC result |
| 缺 `Content-Type` | 415 |
| `Accept: text/plain` | 406 |
| 通知（无 id） | 200 + 空 body |
| 非法 JSON | 200 + `-32700` |
| `POST /rpc/kb` | 200 + topic 路由 |
| batch | 200 + 按输入顺序 |
| `POST /mcp` discover | 200 + capabilities |
| 缺 `_meta` | 200 + `-32602` |
| 错误版本 | 200 + `-32022` + supported |
| `GET /mcp/sse` | 200 + `text/event-stream` + chunked |

## 结论

- CRITICAL 0；WARNING 0。
- 已知限制：分布式限流 demo 用进程内共享 backend 模拟外部存储；真实多实例需换成 Redis / f_store。
