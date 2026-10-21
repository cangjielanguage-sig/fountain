# fmq 管理端（delta）

## MODIFIED Requirements

### Requirement: 参数解析

管理端 SHALL 解析 `[--server=host:port] <subcommand> [operands...]`，`--server` 可出现在子命令前后；
未提供时 SHALL 读取 `mqServer_port` 并组装为 `127.0.0.1:<port>`。
每个子命令 SHALL 校验位置参数个数；非法子命令、参数不足或多余、`--help` 时 SHALL 不执行命令并打印帮助。
配置项形式的参数（`--mqServer_port=2400` 等）SHALL 允许出现在子命令之前或之后，解析器 SHALL 跳过
这些参数定位子命令；把配置参数放在子命令之前 MUST NOT 被判定为未知子命令。

#### Scenario: 前置与后置

- **WHEN** `fmq manager --server=h:1 registerTopic /t 2` 与 `fmq manager registerTopic /t 2 --server=h:1`
- **THEN** 两种写法解析出相同的 server 与操作数

#### Scenario: 默认服务端

- **WHEN** 不提供 `--server` 且 `mqServer_port = 2350`
- **THEN** 服务端地址为 `127.0.0.1:2350`

#### Scenario: 参数校验

- **WHEN** `registerTopic` 少给队列数，或 `listTopics` 多给参数
- **THEN** 解析失败，打印帮助，不发出请求

#### Scenario: 配置参数前置

- **WHEN** `fmq --mqServer_port=2400 server` 与 `fmq server --mqServer_port=2400`
- **THEN** 两者都识别 `server` 子命令并使用端口 2400

#### Scenario: 帮助

- **WHEN** `fmq manager --help`
- **THEN** 输出含全部 7 个子命令（含 `stats`）、各自参数与 `--server` 说明，返回 0

### Requirement: 连接失败语义

当配置缺失或服务端不可达时，管理端 SHALL 打印「无法连接消息队列服务」并返回退出码 1；
不得抛出未捕获异常或挂起。服务端可达但返回 `ERROR` 时 MUST NOT 使用该文案，
SHALL 打印服务端错误码对应文案或服务端消息。

#### Scenario: 端口不可达

- **WHEN** `--server=127.0.0.1:<无监听端口>` 执行任一子命令
- **THEN** 输出该提示，返回 1

#### Scenario: 配置缺失

- **WHEN** 未提供 `--server` 且读不到 `mqServer_port`
- **THEN** 同样输出该提示并返回 1

#### Scenario: 服务端内部错误

- **WHEN** 服务端对 `metaSync` 请求回 `ERROR(INTERNAL)`
- **THEN** 输出 `INTERNAL` 对应文案或服务端消息，返回 1，MUST NOT 输出「无法连接」

#### Scenario: 载荷类型不符

- **WHEN** 服务端回 `RESP` 但载荷不是 `MQMetaSnapshot`
- **THEN** 视为协议错误并打印可诊断信息，返回 1，MUST NOT 报连接失败

### Requirement: 与服务端语义一致

管理端 SHALL 把服务端的 `MQResult.code != 0` 视为失败：打印错误码对应文案并返回非 0，
不得把失败伪装成成功。对该错误码为 `INVALID_GROUP` 的路径 SHALL 同样生效。

#### Scenario: 重复注册

- **WHEN** 重复注册同一主题
- **THEN** 打印「已存在」类错误，返回非 0

#### Scenario: 非绝对路径主题

- **WHEN** 注册 `order`
- **THEN** 打印主题非法，返回非 0

#### Scenario: 非法组名

- **WHEN** `registerSubscriber /t "g 1"`
- **THEN** 打印组名非法（`INVALID_GROUP`），返回非 0，且不发出注册请求

## ADDED Requirements

### Requirement: 输出可断言

管理端每个子命令的输出 SHALL 由独立的渲染层生成，并 SHALL 有单元用例直接断言内容（表格列、
行数、关键值），MUST NOT 只依赖端到端脚本或仅断言退出码。`listTopics` 的列 SHALL 包含
topic、queueNum、delaying 与分配；`stats` 的列 SHALL 与 metrics 规格一致；空结果 SHALL 输出
「（空）」。

#### Scenario: 注册主题输出

- **WHEN** `registerTopic /order 4` 成功
- **THEN** 输出的文本含 `/order`、`4` 与每个队列的 owner 节点

#### Scenario: 列表输出

- **WHEN** 已注册 `/order` 且 `delaying = 1m1s`
- **THEN** `listTopics` 的对应行包含 `/order`、队列数、`1m1s` 与分配

#### Scenario: 统计输出

- **WHEN** 服务端返回 2 行 `R` 记录
- **THEN** 渲染出表头与 2 行数据，列数与规格一致

#### Scenario: 空列表

- **WHEN** 服务端没有任何主题
- **THEN** 输出「（空）」，返回 0
