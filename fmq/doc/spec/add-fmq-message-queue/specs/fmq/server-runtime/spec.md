# fmq 服务运行时（delta）

## ADDED Requirements

### Requirement: 服务端配置项与默认值

服务端 SHALL 支持以下配置项，未设置时取默认值：

| 配置项 | 默认值 |
| --- | --- |
| `mqServer_port` | 2350 |
| `mqServer_ackTimeout` | 10s |
| `mqServer_deadMsgThreshold` | 3 |
| `mqServer_deadMsgTTL` | 72h |
| `mqServer_segmentedLogDir` | `/var/log/fmq/segmentedLogs` |
| `mqServer_deadMsgDir` | `/var/log/fmq/deadMsgs` |
| `mqServer_segmentedLogMaxSize` | 1G（1073741824） |
| `mqServer_segmentedLogTTL` | 72h |
| `mqServer_backup` | 0 |
| `mqClient_hosts` | 无默认，必填 |

配置 SHALL 在首次使用时读取，以支持测试与启动顺序；`segmentedLogMaxSize` SHALL 接受
`1G` / `2M` 等字节量写法。`fmq server --help` SHALL 列出全部配置项名、意义与默认值。

#### Scenario: 默认值

- **WHEN** 清空全部相关环境变量后读取各配置
- **THEN** 得到上表默认值，且 `segmentedLogMaxSize == 1073741824`

#### Scenario: 环境变量覆盖

- **WHEN** 逐项设置环境变量（含 `2M`、`500ms`）
- **THEN** 读取到新值

#### Scenario: 帮助文本完整

- **WHEN** 执行 `fmq server --help`
- **THEN** 输出含全部配置项名与默认值，退出码 0

### Requirement: 启动期校验

服务端 SHALL 在 `backup < 0`、`mqClient_hosts` 为空、本机端口不在节点表、`deadMsgThreshold < 1`
时拒绝启动，打印明确原因并返回非 0 退出码。

#### Scenario: 负数备份

- **WHEN** `mqServer_backup = -1`
- **THEN** 启动失败，退出码非 0，提示不得为负

#### Scenario: 缺少节点表

- **WHEN** `mqClient_hosts` 未配置
- **THEN** 启动失败并提示该配置必填

#### Scenario: 自身端口缺失

- **WHEN** `mqServer_port` 不在节点表
- **THEN** 启动失败并提示端口未出现在节点表中

#### Scenario: 阈值为 0

- **WHEN** `mqServer_deadMsgThreshold = 0`
- **THEN** 启动失败

### Requirement: 子命令分发

可执行文件 SHALL 只接受 `server` 与 `manager` 两个子命令；`--help` / `-h` / 无参数 SHALL 打印用法
（其中无参数与未知子命令返回 2，显式帮助返回 0）。

#### Scenario: 顶层帮助

- **WHEN** 执行 `fmq --help` 或 `fmq`
- **THEN** 前者返回 0 且输出含 `server` / `manager`；后者返回 2

#### Scenario: 管理端帮助

- **WHEN** 执行 `fmq manager --help`
- **THEN** 输出含六个子命令与 `--server` 说明，返回 0

#### Scenario: 未知子命令

- **WHEN** 执行 `fmq bogus`
- **THEN** 打印用法并返回 2

### Requirement: 命令处理矩阵

服务端 SHALL 按下表处理请求，未知命令或无法解析的载荷 SHALL 回 `ERROR(INTERNAL)` 并记 WARN，
且不得关闭连接。

| 命令 | 载荷 | 行为 |
| --- | --- | --- |
| `REGISTER` | `MQTopicMeta` | 校验主题与队列数、分配、落盘、广播、建本地队列；回 `MQTopicAssignment` |
| `REGISTER` | `MQSubscribeGroupMeta` | 校验主题存在、组不存在；落盘、广播；回 `MQResult` |
| `REGISTER` | `MQInternalMessage(metaSync)` | 请求 → 回 `MQMetaSnapshot`；变更 → 应用并回 `MQResult` |
| `DEREGISTER` | `MQDeregisterPayload` | 按 kind 删除主题/组、清理订阅与游标、广播；回 `MQResult` |
| `PUBLISH` | 记录字节块 | 主题不存在 → `TOPIC_NOT_EXIST`；本机无队列 → `NOT_OWNER`；否则落盘 + 备份；回成功 |
| `PUBLISH` | `MQInternalMessage(backup)` | 副本落盘；回成功 |
| `SUBSCRIBE` | `MQSubscribePayload` | 校验主题与组 → 登记订阅并绑定连接；回 `MQResult` |
| `UNSUBSCRIBE` | `MQUnsubscribePayload` | 注销 + 释放已分配记录；回 `MQResult` |
| `CONSUME` | `MQConsumePayload` | 取一条；无消息时 `record = []`，不返回错误 |
| `ACK` | `MQAckPayload` | 确认；失败回 `ACK_UNKNOWN` |

#### Scenario: 注册返回分配

- **WHEN** 发送合法 `MQTopicMeta`
- **THEN** 回 `RESP`，载荷解码为 `MQTopicAssignment`，与本地落盘一致

#### Scenario: 非法主题

- **WHEN** 注册 `order`（非绝对路径）
- **THEN** 回 `ERROR(INVALID_TOPIC)`

#### Scenario: 发布原样落盘

- **WHEN** 发布一条 16KB 记录
- **THEN** 队列中读出的字节与请求载荷逐字节相等（不因临时文件形态退化为空）

#### Scenario: 未注册组

- **WHEN** 用未注册的组订阅
- **THEN** 回 `ERROR(GROUP_NOT_EXIST)`

#### Scenario: 空消费不是错误

- **WHEN** 队列没有可投递消息时 `CONSUME`
- **THEN** 回成功响应且 `MQConsumeResult.record` 为空数组

#### Scenario: 内部同步与备份分派

- **WHEN** 收到 `MQInternalMessage{kind:"metaSync"}` 或 `{kind:"backup"}`
- **THEN** 前者回快照/应用变更，后者只落副本且不进入本队列

#### Scenario: 垃圾载荷

- **WHEN** 载荷无法解析为任何已知类型
- **THEN** 回 `ERROR(INTERNAL)`，记 WARN，连接保持可用

### Requirement: 启动装配与关闭

服务端 SHALL 按「配置校验 → 目录准备 → 元数据加载 → 节点注册 → 启动同步 → 打开本机队列 →
启动清理/备份定时器 → 启动监听」的顺序装配，并在关闭时按相反顺序释放：
停止监听、停止定时器、同步并关闭队列、落盘游标、关闭节点连接。

#### Scenario: 只打开本机队列

- **WHEN** 元数据中有 2 个主题，本机只拥有其中部分队列
- **THEN** 只创建这些队列的目录与日志

#### Scenario: 关闭后可重新绑定

- **WHEN** 调用 `close()`
- **THEN** 端口可再次绑定，队列已 `sync`，订阅表清空

#### Scenario: 无法连接任何 peer 仍可启动

- **WHEN** 全部 peer 不可达
- **THEN** 服务启动成功（WARN），可接受本地请求

#### Scenario: 重启恢复消费

- **WHEN** 消费 3 条、确认 2 条后重启
- **THEN** 重启后从第 3 条继续（第 2 条已确认不再投递，第 3 条被重投）

### Requirement: 断链清理

服务端 SHALL 定期巡检订阅所绑定连接的关闭状态，清理已断开连接名下的全部订阅，
并释放其已分配未确认的记录。

#### Scenario: 连接关闭后订阅消失

- **WHEN** 客户端连接被关闭
- **THEN** 该连接上的订阅全部被移除，同组其它订阅者能取到被释放的消息

### Requirement: 端到端可用性

在 3 节点部署下，系统 SHALL 支持管理端注册主题与订阅组、多个客户端订阅与消费、
发布不重不漏、超时重投与死信、自动确认，以及在单节点停机时继续工作。

#### Scenario: 100 条不重不漏

- **WHEN** 3 节点、同组两个消费者、发布 100 条并全部确认
- **THEN** 消费集合恰好 100 条且无重复位置

#### Scenario: 单节点停机

- **WHEN** 停掉一个非全部 owner 所在节点
- **THEN** 客户端通过 `NOT_OWNER` 重试仍能发布与消费

#### Scenario: 重投与死信

- **WHEN** 一条消息始终不确认
- **THEN** `ackTimeout` 后被重投，超过阈值后出现在死信目录中

#### Scenario: 自动确认组

- **WHEN** 第二个组以 `autoAck = true` 订阅
- **THEN** 不调用 ack 也能持续消费，游标正常前进
