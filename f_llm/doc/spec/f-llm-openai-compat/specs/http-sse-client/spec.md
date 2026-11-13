# Spec Delta

## Purpose

为 `f_httpclient` 增加通用 SSE（`text/event-stream`）客户端能力，使任意需要消费服务端事件的模块不必各写一份行解析；解析器只负责语法，不解释业务语义。

## ADDED Requirements

### Requirement: 从响应体按事件读取

系统 SHALL 能从 HTTP 响应体按事件读取：一次返回一条事件，包含事件名、数据、标识与重试间隔；流正常结束时返回空，而不是抛异常。

#### Scenario: 读取两条事件
- **WHEN** 响应体为 `data: a` 空行 `data: b` 空行
- **THEN** 第一次读取得到数据 `a`，第二次得到 `b`，第三次返回空

#### Scenario: 事件名与标识
- **WHEN** 响应体含 `event: done` 与 `id: 42`
- **THEN** 返回事件的 `event` 为 `done`、`id` 为 `42`

### Requirement: 增量读取不缓冲整段

系统 SHALL 边读边产出事件，SHALL NOT 等待整个响应体结束再返回第一条事件。

#### Scenario: 首条事件先到
- **WHEN** 服务端先写一条事件、若干秒后才写第二条
- **THEN** 调用方在第二条到达前就拿到第一条事件

### Requirement: 行与字段解析规则

解析 SHALL 容忍 `\n` 与 `\r\n` 行尾；以 `:` 开头的行 SHALL 作为注释丢弃；`data` 多行 SHALL 以换行拼接；字段值 SHALL 去掉一个前导空格；未知字段 SHALL 忽略。

#### Scenario: 心跳注释
- **WHEN** 响应体含一行 `: ping`
- **THEN** 该行不产生事件，读取继续

#### Scenario: 多行 data
- **WHEN** 两条连续 `data:` 行属于同一事件
- **THEN** 事件数据为两行内容以换行拼接的结果

#### Scenario: CRLF
- **WHEN** 服务端使用 `\r\n` 行尾
- **THEN** 事件解析结果与使用 `\n` 时一致

### Requirement: 业务语义不进入解析器

解析器 SHALL NOT 解释 `[DONE]`、SHALL NOT 解析 JSON、SHALL NOT 自动重连；这些由调用方处理。

#### Scenario: 结束标记原样返回
- **WHEN** 响应体最后一行是 `data: [DONE]`
- **THEN** 解析器把它作为一条普通事件返回

### Requirement: 边界与资源释放

系统 SHALL 在单行超过上限时失败、在空闲超时后失败，并在关闭时释放底层流；实现 SHALL 可被资源管理语法自动关闭。

#### Scenario: 超长行
- **WHEN** 单行长度超过配置上限
- **THEN** 读取抛出「行过长」异常，且不继续读取

#### Scenario: 空闲超时
- **WHEN** 超过空闲超时没有任何字节到达
- **THEN** 读取抛出「超时」异常，异常类型区别于连接超时

#### Scenario: 半行结束
- **WHEN** 流在一条事件中间断开，最后一行没有换行符
- **THEN** 已完整的部分仍产出对应事件或安全结束，不抛解析错误

#### Scenario: 关闭释放
- **WHEN** 调用方关闭读取器
- **THEN** 底层流被关闭，再次读取返回空
