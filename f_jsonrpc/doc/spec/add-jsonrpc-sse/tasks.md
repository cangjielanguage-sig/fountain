# Tasks

> 全程 TDD：先写失败用例（Red）→ 最小实现（Green）→ 重构。每条都要能说出「哪行代码让它变红」。

## 1. 服务端核心（不依赖 HTTP）

- [x] 1.1 `SseStream`：写入后 `read` 能读到；`close` 后 `read` 返回 -1；空闲返回心跳行。验证：3 条用例。
- [x] 1.2 `SseHub.publish/subscribe`：id 单调递增、`topic` 隔离、`taskId` 过滤。验证：3 条用例。
- [x] 1.3 缓冲溢出：发布 300 条 → 订阅者后续能读、`dropped` 置位、只 warn 一次。验证：1 条用例。
- [x] 1.4 补发：`lastEventId=2` → 只补发 id>2；早于最旧 → 从最旧开始。验证：2 条用例。

## 2. HTTP 端点

- [x] 2.1 `@SseMapping` 注解（`RequestMapping` 子类，固定 GET + text/event-stream）。
- [x] 2.2 `SseController`：`GET /rpc/stream` 解析 `topic/taskId/cursor`，返回 `SseStream` 并设置响应头。
- [x] 2.3 冒烟：起 `MvcStarter` → 连 `/rpc/stream` → 发布一条 → 客户端在 2s 内收到（验证 `InputStream` 真流式）。

## 3. 客户端

- [x] 3.1 `JsonRpcSseClient`：连上、逐帧解析、`next()` 产出 `JsonValue`；流结束返回 `None`。验证：2 条用例。
- [x] 3.2 重连：断开后用 `Last-Event-ID` 重连，只产出新事件；3 次失败后抛错。验证：2 条用例。

## 4. 集成与回归

- [x] 4.1 `f_jsonrpc` 全量 `cjpm test` 全绿（既有用例不退化）。
- [x] 4.2 `f_a2a` 的 `message/stream` / `resubscribe` 改用它（在 `add-f-a2a` 里落地）。
- [x] 4.3 `known-limitations.md` 记「进程内广播、多实例需外部总线」。

## Workflow follow-up

- `openspec validate add-jsonrpc-sse --strict` → 归档 → 覆盖 `f_jsonrpc/doc/spec/add-jsonrpc-sse/`。
