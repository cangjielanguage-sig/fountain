# fmcpdemo

`f_mcp` 的端到端示例：server / client 两个动态模块，由 `fboot run` 加载。

```bash
./boot.sh e2e 18082
```

预期输出：

```
MCP_HTTP_CHECKS_OK discover/missing-meta/sse
MCP_HTTP_DEMO_OK discover tools/call resources/read prompts/get sse
MCP_LIMIT_DEMO_OK shared_by_two_servers fourth_code=-32050
```

- `/mcp`：`server/discover`、`tools/list`、`tools/call`、`resources/read`、`prompts/get`
- `/mcp/sse`：客户端先订阅 `tools/list_changed`，再调用 `notify` 工具触发通知并读取事件
- 服务端：`@Mcp['fmcpdemo']` 的 `McpDemoService`，tool / resource / prompt 全部由注解注册；`limited` 通过 `@McpToolMeta[perCallerToolRpm: 3]` 配置限流
- 分布式限流：服务端启动时构建两个共享同一个 `RateLimitBackend` 的 `McpServer`，第 4 次调用 `limited` 工具返回 `-32050`

单独运行：

```bash
./boot.sh build
./boot.sh runServer 18082   # 终端 1
./boot.sh runClient 18082   # 终端 2
```
