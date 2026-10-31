# 变更提案：JsonRpc 宏收敛与端到端 demo

## 背景

`@jsonrpc` 宏经过一轮实现后留下了三个问题：

1. 宏名与注解名不统一：类宏叫 `jsonrpc`，注解叫 `JsonRpcMeta`，还额外造了一个没有语义的 `@jsonrpcmeta` 语法糖。
2. 宏在展开期扫描 `ClassDecl.toTokens()` 提取注解，绕过了 `JsonRpcRegistry.getMeta`，导致同一个注解有两套读取路径。
3. 没有可运行的应用工程验证 `fboot run`、`/rpc` 的真实 HTTP 行为、`/mcp` 与 `/mcp/sse` 的端到端行为。

## 变更内容

- 类宏只保留 `@JsonRpc`；删除 `@jsonrpcmeta` 与 `@jsonrpc` 小写别名。
- `JsonRpcMeta` 增加 `timeoutDuration: Duration`，由 `f_data` 的 `Duration.parse` 扩展解析。
- `JsonRpcRegistry.getMeta<T>(funcName: String, argTypes: Array<TypeInfo>): JsonRpcMeta` 成为唯一读取入口；删除 `paramCount` / `JsonRpcRegisteredMeta` / `parseTimeout`。
- 宏展开简化为：`@Bean` + 每个 public 实例方法一段 `private let _`，方法体用 `lookup<T>().method(...)`，描述与超时在运行期从 `getMeta` 读取。
- 删除宏文件里的 `func str` 与编译期注解扫描。
- 修复 `JsonRpcClient` 在 keep-alive 连接上第二次请求报 `Socket is already closed`：读完 body 后不再调用 `HttpResponse.close()`，只在异常时关闭。
- `/mcp/sse` 显式设置 `Transfer-Encoding: chunked`，修复 stdx http server 的 `Unknown body size for Content-Length header`。
- 新增 `fjsonrpcdemo` 与 `fmcpdemo` 两个 workspace：
  - `fjsonrpcdemo`：server + client，`fboot run` 启动，客户端走 `/rpc`。
  - `fmcpdemo`：server + client，覆盖 `/mcp`、`/mcp/sse`，并用两个共享 `RateLimitBackend` 的 `McpServer` 验证分布式限流。
- 两个 demo 的 `boot.sh e2e` 内置 HTTP 断言：`/rpc` 的 200/415/406/通知/解析错误/topic；`/mcp` 的 discover、缺 `_meta`、SSE 头。

## 非目标

- 不改变 JSON-RPC / MCP 的错误码与 HTTP 状态策略。
- 不引入外部 Redis；分布式限流仍以 SPI + 共享 backend 示例表达。
