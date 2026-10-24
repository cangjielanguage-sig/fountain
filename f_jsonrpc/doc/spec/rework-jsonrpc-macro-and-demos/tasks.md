# 任务

## 1. 宏与注解

- [x] 1.1 删除 `@jsonrpc` / `@jsonrpcmeta`，类宏改名为 `@JsonRpc`
- [x] 1.2 `JsonRpcMeta` 增加 `timeoutDuration: Duration`
- [x] 1.3 `JsonRpcRegistry.getMeta<T>(funcName, argTypes)` 返回 `JsonRpcMeta`
- [x] 1.4 删除 `parseTimeout` / `JsonRpcRegisteredMeta` / `paramCount`
- [x] 1.5 宏展开改用 `lookup<T>()` 与运行期 `getMeta`；删除 `func str` 与编译期注解扫描

## 2. 客户端与服务端修复

- [x] 2.1 `JsonRpcClient` 读完 body 不再 `close()`，修复 keep-alive 二次请求
- [x] 2.2 `/mcp/sse` 设置 `Transfer-Encoding: chunked`

## 3. demo

- [x] 3.1 新增 `fjsonrpcdemo`（server/client/boot.sh）
- [x] 3.2 新增 `fmcpdemo`（server/client/boot.sh）
- [x] 3.3 两个 demo 的 `boot.sh e2e` 加入 HTTP 断言
- [x] 3.4 `fmcpdemo` 用两个共享 backend 的 server 验证 `-32050`
- [x] 3.5 `.modules` 登记两个 demo

## 4. 验证

- [x] 4.1 `f_jsonrpc` 全量测试
- [x] 4.2 `f_mcp` / `f_data` 回归
- [x] 4.3 `fboot run` 实测 `/rpc`：200 / 415 / 406 / 通知 / 解析错误 / topic / batch
- [x] 4.4 `fboot run` 实测 `/mcp`：discover / 缺 `_meta` / 版本错误 / SSE 头
- [x] 4.5 两个 demo 的客户端端到端通过
