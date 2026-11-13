# Spec Delta

## ADDED Requirements

### Requirement: InputStream 响应体必须流式写出

controller 返回 `InputStream` 时，框架 MUST 以 `Transfer-Encoding: chunked` 输出响应体，
MUST 在流未结束时就能把已产生的字节发给客户端；MUST NOT 返回 500。

#### Scenario: 有限长度的流

- **WHEN** 一个 `@Controller` 方法返回只含 `hello` 的 `InputStream`，客户端发起 GET
- **THEN** 响应为 `200 OK`，头含 `Transfer-Encoding: chunked`，body 为 `hello`

#### Scenario: 未知长度、持续输出

- **WHEN** 返回的流在 1 秒后才产出第一块数据，客户端立刻读取
- **THEN** 客户端能在数据产生后立即收到该块，无需等流结束

#### Scenario: 客户端断开

- **WHEN** 客户端在流结束前关闭连接
- **THEN** 服务端不崩溃，下一次请求正常
