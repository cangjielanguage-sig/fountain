# Proposal

## Why

`f_mvc` 的 `RequestMeta` 里有一条「返回 `InputStream` 即流式响应」的分支：

```cangjie
case x: InputStream => respond(x, ctx)
...
private func respond(response: InputStream, ctx: HttpContext): Unit {
    respond(ctx.request.method) {
        populateResponseContentType(ctx)
        ctx.responseBuilder.body(response)      // ← 这里
    }
}
```

实测**这条分支从来没走通过**：任何返回 `InputStream` 的 controller 都得到
`HTTP/1.1 500 Internal Server Error`（21 字节通用错误页），异常在响应发送阶段抛出，
`respond` 内部捕获不到。

根因：`populateResponseContentType` 只设置了 `Content-Type`，**没有声明 `Transfer-Encoding`**。
HTTP 层拿到「没有 `Content-Length` 也没有分块声明」的响应体，直接判定非法 → 500。

这道门一破，SSE（`f_jsonrpc` 的 `/rpc/stream`）与任何「边算边发」的接口都做不了——
`f_a2a` 的 `message/stream`、`tasks/resubscribe` 全被它挡住。

## What Changes

`respond(response: InputStream, ctx)` 在设置 body 之前显式声明 `Transfer-Encoding: chunked`：

```cangjie
let _ = ctx.responseBuilder.header('Transfer-Encoding', 'chunked')
ctx.responseBuilder.body(response)
```

**不改任何公开 API、不改既有返回类型的行为**：只有「返回 `InputStream`」这一条路从 500 变成正常流式。

## Capabilities

### New Capabilities
- `mvc-response`：`InputStream` 响应体必须是分块流式写出，而不是 500。

## Impact

- 代码：`f_mvc/src/RequestMeta.cj`（3 行）。
- 影响面：所有模块共用，但只有返回 `InputStream` 的 controller 会走到该分支（此前全部 500，无人可用）。
- 测试：`f_mvc` 全量 32/32；`f_jsonrpc` 全量 106/106（新增的 SSE 冒烟用例断言
  `content-type: text/event-stream`、`transfer-encoding: chunked`，并验证事件在流结束前到达）。
