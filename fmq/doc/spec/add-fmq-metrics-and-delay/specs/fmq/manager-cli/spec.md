# fmq 管理端（delta）

## ADDED Requirements

### Requirement: 统计查询子命令

管理端 SHALL 新增 `stats [topic]` 子命令：向目标服务发送
`REGISTER` + `MQInternalMessage{kind = "stats"}`，解析 TSV 响应并渲染表格。
`topic` 省略时查询全部本地主题；`topic` 多余参数或无法连接时 SHALL 返回非 0。

表格列 SHALL 包含：`topic`、`group`、`queueNum`、`delaying`、`backlog`、`lagMs`、
`delivered`、`acked`、`redelivered`、`deadLettered`。没有订阅组的主题组列显示「（无）」。

#### Scenario: 查询全部主题

- **WHEN** 服务端存在 `/order` 与 `/pay` 时执行 `stats`
- **THEN** 返回 0，输出包含两个主题

#### Scenario: 按主题查询

- **WHEN** 执行 `stats /order`
- **THEN** 只输出 `/order` 的行

#### Scenario: 未知主题

- **WHEN** 执行 `stats /missing`
- **THEN** 返回 0，输出「（空）」

#### Scenario: 连接失败

- **WHEN** `--server` 指向未监听端口执行 `stats`
- **THEN** 返回 1

### Requirement: 主题延迟定义参数

`registerTopic` SHALL 接受可选的第三个操作数 `delaying=<DurationString>`，例如
`delaying=1m1s`；省略时为 `0s`。解析 SHALL 使用 `Duration.tryParse`，负数或非法格式 SHALL
在本地返回 2 且不发请求。

`listTopics` 的输出 SHALL 增加 `delaying` 列，展示该主题的延迟定义。

#### Scenario: 带延迟注册

- **WHEN** `registerTopic /order 4 delaying=1m1s`
- **THEN** 返回 0；`listTopics` 中 `/order` 的 delaying 为 `1m1s`

#### Scenario: 默认无延迟

- **WHEN** `registerTopic /order 4`
- **THEN** 返回 0；listTopics 中 delaying 为 `0s`

#### Scenario: 非法延迟

- **WHEN** `registerTopic /order 4 delaying=abc` 或 `delaying=-1s`
- **THEN** 返回 2，不发送注册请求

#### Scenario: 参数个数

- **WHEN** `registerTopic` 只给主题，或给出第四个操作数
- **THEN** 解析失败，打印帮助并返回 2
