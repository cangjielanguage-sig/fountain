# Proposal

## Why

`f_a2a` 要支持 `message/stream`、`tasks/resubscribe`、push notification、非文本 `Part` 与扩展卡片，
其中**流式与重订阅**必须有服务端推送通道；而 `f_jsonrpc` 目前只有「POST 一问一答」，没有推送能力。

`f_mvc` 不动：它已经能把 `InputStream` 直接当响应体（`RequestMeta` 的 `case x: InputStream => respond(x, ctx)`），
SSE 需要的「一个不结束的输入流」是既有能力。所以扩展落在 `f_jsonrpc` 内部，影响面限定在本模块。

## What Changes

- 新增 `fountain::f_jsonrpc.server.SseHub`：进程级发布/订阅，按 `topic`（+ 可选 `taskId`）过滤，
  每订阅者环形缓冲 256 条，满了丢最旧并 warn 一次。
- 新增 `fountain::f_jsonrpc.server.SseStream <: InputStream`：阻塞读，订阅者关闭即结束；
  空闲 15s 由读取侧补一行 `: ping`。
- 新增 `@SseMapping` + `SseController`：`GET /rpc/stream`（`?topic=&taskId=&cursor=`），
  设置 `Content-Type: text/event-stream`、`Cache-Control: no-cache`、`X-Accel-Buffering: no`，返回 `SseStream`。
- 新增 `fountain::f_jsonrpc.client.JsonRpcSseClient`：流式读取、按 SSE 帧切分、`next(): ?JsonValue`；
  支持 `Last-Event-ID` 重连（最多 3 次）。
- 事件体仍是 **JSON-RPC 2.0 通知**（`{"jsonrpc":"2.0","method":"…","params":{…}}`），复用既有消息模型与 JSON 工具。

## Capabilities

### New Capabilities
- `jsonrpc-sse`：服务端推送通道（发布/订阅、SSE 帧编码、断线补发）与客户端流式消费。

## Impact

- 代码：`f_jsonrpc/src/server/{SseHub.cj, SseStream.cj, SseController.cj, SseMapping.cj}`、
  `f_jsonrpc/src/client/JsonRpcSseClient.cj`、门面导出。
- **不改 `f_mvc`**，不改 `JsonRpcClient` 的既有签名（新客户端是并列类）。
- 依赖：服务端 `f_mvc` 的 `InputStream` 响应能力；客户端 `std.net`（或 `f_httpclient` 的流式读，实现时择一）。
- 测试：新增用例覆盖发布/订阅、过滤、缓冲溢出、补发、帧解析、重连。
