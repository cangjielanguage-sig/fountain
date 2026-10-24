# Spec Delta

## Purpose

修复 `/mcp/sse` 在 stdx http server 上的流式响应。

## ADDED Requirements

### Requirement: SSE 流式响应

`/mcp/sse` MUST 返回 `text/event-stream`，并 MUST 在长度未知时声明 `Transfer-Encoding: chunked`，避免 stdx http server 返回 500。

#### Scenario: 建立订阅

- **WHEN** 客户端 `GET /mcp/sse?topics=tools/list_changed`
- **THEN** 响应状态 200、`Content-Type: text/event-stream`、`Transfer-Encoding: chunked`

#### Scenario: 推送通知

- **WHEN** 另一个连接调用工具并发布 `tools/list_changed`
- **THEN** 已建立的 SSE 流收到 `event: message` 与 `notifications/tools/list_changed`
