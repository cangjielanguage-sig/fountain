# Design

## Context

`respond(InputStream)` 的实现只有三行，问题不在代码逻辑，而在**缺一个 HTTP 头**：
`Content-Type` 有、`Content-Length` 不能有（长度未知）、`Transfer-Encoding` 没人写。

## Decisions

### D1. 在 `respond(InputStream)` 里显式写 `Transfer-Encoding: chunked`

```cangjie
let _ = ctx.responseBuilder.header('Transfer-Encoding', 'chunked')
ctx.responseBuilder.body(response)
```

**替代**：让 HTTP 层「没长度就自动 chunked」。否决——那是框架行为，不在本模块可控范围内；
显式声明也让响应头可被测试断言（`transfer-encoding: chunked` 就是「流式」的判据）。

### D2. 不改 `respond(JsonValue)` / `respond(Array<Byte>)` 等分支

那几条都有确定长度，加 chunked 反而破坏既有语义（客户端拿不到 `Content-Length` 就没法显示进度）。

### D3. 不引入超时/心跳等策略

框架只负责「把流写出去」；心跳（`: ping`）是上层（`SseStream`）的事，混进来会让框架承担业务语义。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 客户端不读导致服务端线程被占 | 由业务层（`SseStream` 的有界队列 + 心跳）负责；框架不做背压 |
| 响应头里出现 `connection: transfer-encoding,keep-alive` | 这是 std HTTP 层把自定义头并进 `Connection` 的既有行为；SSE 客户端不读 `Connection`，已记入 `known-limitations` |
| 旧代码若有依赖「返回 InputStream 得到 500」的奇怪逻辑 | 不成立——此前无人能用（全部 500） |

## 迁移

无。
