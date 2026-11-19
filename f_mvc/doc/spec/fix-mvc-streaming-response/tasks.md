# Tasks

## 1. 定位与修复

- [x] 1.1 复现：`f_jsonrpc` 的 `GET /rpc/stream`（返回 `InputStream`）实测 500；
  对照 `@GetMapping` 返回 `String` 的探针是 200，排除路由与控制器实例化。
- [x] 1.2 定位：`respond(InputStream)` 未声明 `Transfer-Encoding`，HTTP 层拒绝未知长度响应体。
- [x] 1.3 修复：`body(response)` 前加 `Transfer-Encoding: chunked`。

## 2. 验证

- [x] 2.1 `f_jsonrpc`：`testStreamPushesIncrementally` 由红转绿（断言 `text/event-stream`、
  `transfer-encoding: chunked`、事件在流结束前到达，用例耗时 0.2s 而非 5s 超时）。
- [x] 2.2 `f_mvc` 全量回归 32/32。
- [x] 2.3 `f_jsonrpc` 全量回归 106/106。

## 3. 文档

- [x] 3.1 `add-jsonrpc-sse` 的 design 记录「为什么必须显式 chunked」。
