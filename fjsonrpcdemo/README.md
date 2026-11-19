# fjsonrpcdemo

`f_jsonrpc` 的端到端示例：一个进程跑服务端（`fboot run`），另一个进程跑客户端。

```bash
./boot.sh e2e 18080
```

预期输出：

```
JSONRPC_HTTP_CHECKS_OK 200/415/406/notification/parse-error/namespace
JSONRPC_DEMO_OK search=found:hello add=5 echo=hi!
```

- 服务端：`@JsonRpc[namespace: knowledge]` 的 `SearchRPC`，方法含单参数、多参数、`@DataAssist` 对象与 `Unit`
- 客户端：`JsonRpcClient` 走 HTTP 调用 `/rpc`，同一个连接连续调用（验证 keep-alive）
- `JSONRPC_HTTP_CHECKS_OK` 覆盖 415（缺 `Content-Type`）、406（`Accept: text/plain`）、通知空响应、解析错误与 `/rpc/{topic}`

单独运行：

```bash
./boot.sh build
./boot.sh runServer 18080   # 终端 1
./boot.sh runClient 18080   # 终端 2
```
