# fmq 管理端（delta）

## ADDED Requirements

### Requirement: 参数解析

管理端 SHALL 解析 `[--server=host:port] <subcommand> [operands...]`，`--server` 可出现在子命令前后；
未提供时 SHALL 读取 `mqServer_port` 并组装为 `127.0.0.1:<port>`。
每个子命令 SHALL 校验位置参数个数；非法子命令、参数不足或多余、`--help` 时 SHALL 不执行命令并打印帮助。

#### Scenario: 前置与后置

- **WHEN** `fmq manager --server=h:1 registerTopic /t 2` 与 `fmq manager registerTopic /t 2 --server=h:1`
- **THEN** 两种写法解析出相同的 server 与操作数

#### Scenario: 默认服务端

- **WHEN** 不提供 `--server` 且 `mqServer_port = 2350`
- **THEN** 服务端地址为 `127.0.0.1:2350`

#### Scenario: 参数校验

- **WHEN** `registerTopic` 少给队列数，或 `listTopics` 多给参数
- **THEN** 解析失败，打印帮助，不发出请求

#### Scenario: 帮助

- **WHEN** `fmq manager --help`
- **THEN** 输出含六个子命令、各自参数与 `--server` 说明，返回 0

### Requirement: 六个管理子命令

管理端 SHALL 实现以下子命令，并通过单次请求/响应完成：

| 子命令 | 参数 | 协议调用 | 输出要点 |
| --- | --- | --- | --- |
| `registerTopic` | `<topic> <queueNum>` | `REGISTER` + `MQTopicMeta` | topic、队列范围、每个队列的 owner |
| `deleteTopic` | `<topic>` | `DEREGISTER` + `kind="topic"` | 删除成功提示 |
| `registerSubscriber` | `<topic> <group>` | `REGISTER` + `MQSubscribeGroupMeta` | 组注册成功提示 |
| `deleteSubscribeGroup` | `<topic> <group>` | `DEREGISTER` + `kind="group"` | 组删除成功提示 |
| `listTopics` | — | `metaSync` 请求 → `MQMetaSnapshot` | 表格：topic / queueNum / 分配 |
| `listSubscribeGroups` | `<topic>` | 同上并过滤 | 表格：订阅组 |

#### Scenario: 注册主题并显示分配

- **WHEN** 注册 `/order` 4 个队列
- **THEN** 输出含 `/order`、队列数 4 与每个队列的 owner 节点

#### Scenario: 注册后被列出

- **WHEN** 注册组后执行 `listSubscribeGroups /order`
- **THEN** 输出表格包含该组

#### Scenario: 删除主题生效

- **WHEN** 删除主题后客户端发布该主题
- **THEN** 服务端回 `TOPIC_NOT_EXIST`，管理端命令本身返回 0

#### Scenario: 删除订阅组生效

- **WHEN** 删除组后客户端用该组订阅
- **THEN** 服务端回 `GROUP_NOT_EXIST`

#### Scenario: 列表空结果

- **WHEN** 没有任何主题
- **THEN** 输出「（空）」而不是空行或异常

### Requirement: 输出渲染

表格输出 SHALL 按列对齐（CJK 字符按显示宽度 2 计算），错误输出 SHALL 使用统一前缀。

#### Scenario: 中英文混排对齐

- **WHEN** 表头与单元格同时包含中文与 ASCII
- **THEN** 各行列宽一致，竖线对齐

#### Scenario: 错误前缀

- **WHEN** 渲染错误
- **THEN** 输出以统一前缀开头，便于脚本匹配

### Requirement: 连接失败语义

当配置缺失或服务端不可达时，管理端 SHALL 打印「无法连接消息队列服务」并返回退出码 1；
不得抛出未捕获异常或挂起。

#### Scenario: 端口不可达

- **WHEN** `--server=127.0.0.1:<无监听端口>` 执行任一子命令
- **THEN** 输出该提示，返回 1

#### Scenario: 配置缺失

- **WHEN** 未提供 `--server` 且读不到 `mqServer_port`
- **THEN** 同样输出该提示并返回 1

### Requirement: 与服务端语义一致

管理端 SHALL 把服务端的 `MQResult.code != 0` 视为失败：打印错误码对应文案并返回非 0，
不得把失败伪装成成功。

#### Scenario: 重复注册

- **WHEN** 重复注册同一主题
- **THEN** 打印「已存在」类错误，返回非 0

#### Scenario: 非绝对路径主题

- **WHEN** 注册 `order`
- **THEN** 打印主题非法，返回非 0
