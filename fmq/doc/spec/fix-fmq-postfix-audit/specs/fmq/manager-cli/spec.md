# fmq 管理端 CLI（delta）

## REMOVED Requirements

### Requirement: 六个管理子命令

**Reason**：`stats` 加入后实际为 7 个子命令；保留「六个」的 Requirement 会让验收脚本与帮助文本
自相矛盾（`fmq/server-runtime` 的「管理端帮助」也要求六个）。

**Migration**：由「七个管理子命令」替代，内容为原 Requirement 的 5 个场景 + `stats`，
名称与 README、`MQUsage.managerHelp`、`MQManager` 分派表统一。

## ADDED Requirements

### Requirement: 七个管理子命令

`fmq manager` SHALL 提供 7 个子命令：`registerTopic`、`registerSubscriber`、`listTopics`、
`listSubscribeGroups`、`deleteSubscribeGroup`、`deleteTopic`、`stats`。
每个子命令成功时 SHALL 返回 0 并输出可断言文本；失败时 SHALL 返回非 0 并输出统一错误前缀。

#### Scenario: 注册主题并显示分配

- **WHEN** `registerTopic /order 4`
- **THEN** 退出码 0，输出含主题、`队列 0..3（共 4 个）`、延迟与 `0→A,1→B` 形式分配

#### Scenario: 注册后被列出

- **WHEN** 注册后 `listTopics`
- **THEN** 输出含该主题与分配

#### Scenario: 删除主题生效

- **WHEN** `deleteTopic /order`
- **THEN** 退出码 0，再次 `listTopics` 不含该主题

#### Scenario: 删除订阅组生效

- **WHEN** `deleteSubscribeGroup /order g1`
- **THEN** 退出码 0，再次列出不含该组

#### Scenario: 列表空结果

- **WHEN** 没有任何主题
- **THEN** 输出 `（空）`，退出码 0

#### Scenario: 统计子命令存在

- **WHEN** 运行 `fmq manager --help`
- **THEN** 7 个子命令全部出现，含 `stats`

### Requirement: 本地前置校验与配置缺失

管理端 SHALL 在发请求前完成可在本地判定的校验：

- 组名非法（含 `/`、空白、控制字符等）→ 打印 `INVALID_GROUP` 文案并返回非 0，
  MUST NOT 发出任何请求，MUST NOT 打印「无法连接」；
- 配置缺失（`mqServer_port` 不存在或节点表为空）→ 打印「无法连接消息队列服务」并返回 1，
  MUST NOT 抛未捕获异常；
- 主题非绝对路径 SHALL 由服务端拒绝，管理端 SHALL 原样渲染 `INVALID_TOPIC` 文案并返回非 0；
  若管理端增加本地校验，行为必须与「服务端拒绝」的文案一致。

#### Scenario: 非法组名不连服务器

- **WHEN** `--server` 指向不可达地址，组名为 `g/1`
- **THEN** 输出含 `INVALID_GROUP`，不含「无法连接」，退出码非 0

#### Scenario: 配置缺失

- **WHEN** `mqServer_port` 未配置
- **THEN** 输出「无法连接消息队列服务」，退出码 1，进程不崩溃

#### Scenario: 非绝对路径主题

- **WHEN** `registerTopic order 2`
- **THEN** 输出含 `INVALID_TOPIC`，退出码非 0

## MODIFIED Requirements

### Requirement: 连接失败语义

管理端 SHALL 把失败分成四类，且四类的**输出文案互斥**：

| 类别 | 触发 | 文案 |
|---|---|---|
| 连接失败 | 建连/传输失败 | 无法连接消息队列服务 |
| 服务端错误 | 收到 `ERROR` 命令 | 错误：<服务端 message 或错误码文案> |
| 响应格式不符 | 收到 RESP 但不是期望载荷，或渲染解析失败 | 错误：响应不是 <类型> / 服务端响应格式不正确 |
| 本地拒绝 | 参数/配置非法 | 错误：<具体原因> |

「服务端可达但返回错误」与「响应格式不符」MUST NOT 使用「无法连接」文案。
`body()` 内的解析异常（如 `stats` 的 `delaying` 不是数字）SHALL 归为「响应格式不符」，
MUST NOT 被兜底 `catch (_: Exception)` 归为连接失败。

#### Scenario: 端口不可达

- **WHEN** 连接被拒绝
- **THEN** 输出「无法连接消息队列服务」，退出码 1

#### Scenario: 配置缺失

- **WHEN** 未配置服务端地址
- **THEN** 输出「无法连接消息队列服务」，退出码 1

#### Scenario: 服务端内部错误

- **WHEN** 服务端回 `ERROR(INTERNAL, "boom from server")`
- **THEN** 输出含 `boom from server`，不含「无法连接」

#### Scenario: 载荷类型不符

- **WHEN** 服务端回 RESP 但载荷不是 `MQMetaSnapshot`
- **THEN** 输出含「响应不是 MQMetaSnapshot」，不含「无法连接」

#### Scenario: 统计响应格式异常

- **WHEN** `stats` 返回的 TSV 中 `delaying` 为非数字
- **THEN** 输出「服务端响应格式不正确」，不含「无法连接」

### Requirement: 输出可断言

管理端 SHALL 把输出写入可注入的 sink（默认 `println`），使测试能捕获并断言全部文本；
用例 MUST NOT 只断言退出码。每个子命令至少 SHALL 有一条用例同时断言：

- 退出码；
- 输出中的关键字段（主题名、队列数、分配、错误码/错误文案）；
- 反例文案不出现（如「无法连接」）。

`stats` 的三个 CLI 场景（全部主题、按主题、未知主题）SHALL 在 CLI 层断言输出行内容，
不得只依赖渲染层用例。

#### Scenario: 注册主题输出

- **WHEN** 捕获 `registerTopic` 的输出
- **THEN** 含 `已注册`、主题名、队列数与 `0→` 分配

#### Scenario: 列表输出

- **WHEN** 捕获 `listTopics` 的输出
- **THEN** 每个主题一行，含队列数与延迟

#### Scenario: 统计输出

- **WHEN** 捕获 `stats /order` 的输出
- **THEN** 含表头与至少一行数据，列数与 `STATS_HEADER` 一致

#### Scenario: 空列表

- **WHEN** 捕获空列表输出
- **THEN** 含 `（空）`

#### Scenario: 服务端错误不伪装成连接失败

- **WHEN** 断言输出文本
- **THEN** `serverErrorIsNotReportedAsConnectionFailure` 与
  `nonSnapshotResponseIsProtocolError` 都检查了输出，删掉错误分类时用例失败

#### Scenario: 统计三场景贯通

- **WHEN** 分别在 CLI 层执行 `stats`、`stats /order`、`stats /nope`
- **THEN** 输出分别为两行数据、一行数据、空表；退出码均为 0

### Requirement: 子命令错误路径的稳定契约

七个管理子命令 SHALL 在成功时返回 0 并打印可读结果；服务端返回错误时 SHALL 返回 1 并打印
`MQErrorCode` 对应文案或服务端消息；客户端无法连接时 SHALL 返回 1 并打印
「无法连接消息队列服务」。这些路径 SHALL 有独立用例覆盖，不依赖端到端脚本间接断言。

#### Scenario: 注册主题成功

- **WHEN** `registerTopic /t 2` 命中健康服务端
- **THEN** 退出码为 0，随后 `listTopics` 能看到该主题

#### Scenario: 主题重复

- **WHEN** 对已存在主题再次 `registerTopic`
- **THEN** 退出码为 1

#### Scenario: 删除不存在的主题或订阅组

- **WHEN** `deleteTopic /missing` 或 `deleteSubscribeGroup /missing g`
- **THEN** 退出码为 1

#### Scenario: 订阅组依赖主题

- **WHEN** 对未注册主题执行 `registerSubscriber`
- **THEN** 退出码为 1

#### Scenario: 空列表

- **WHEN** 服务端没有任何主题或订阅组时执行 `listTopics` / `listSubscribeGroups`
- **THEN** 退出码为 0

#### Scenario: 连接失败

- **WHEN** `--server` 指向未监听端口
- **THEN** 退出码为 1

#### Scenario: 统计子命令错误路径

- **WHEN** `stats` 命中服务端错误或返回非 TSV 文本
- **THEN** 退出码为 1，且打印服务端错误/协议错误文案（不是「无法连接」）
