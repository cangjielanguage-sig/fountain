# Spec Delta

## Purpose

修复 `/mcp/sse` 在 stdx http server 上的流式响应。

## ADDED Requirements

### Requirement: SSE 流式响应

`/mcp/sse` MUST 返回 `text/event-stream`，并 MUST 在长度未知时声明 `Transfer-Encoding: chunked`，避免 stdx http server 返回 500。`subscriptions/listen` MUST 返回 `subscriptionId` 与 `sseUrl`；`/mcp/sse?subscriptionId=N` MUST 绑定到同一个订阅者。

#### Scenario: 建立订阅

- **WHEN** 客户端先 `subscriptions/listen`，再 `GET` 返回的 `sseUrl`
- **THEN** 响应状态 200、`Content-Type: text/event-stream`、`Transfer-Encoding: chunked`，并绑定到该订阅者

#### Scenario: 推送通知

- **WHEN** 另一个连接调用工具并发布 `tools/list_changed`
- **THEN** 已建立的 SSE 流收到 `event: message` 与 `notifications/tools/list_changed`
