# fmq 服务端运行时（delta）

## MODIFIED Requirements

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
| `mqServer_tombstoneTTL` | 7d |
| `mqServer_antiEntropyInterval` | 30s |
| `mqClient_hosts` | 无默认，必填 |

配置 SHALL 在首次使用时读取，以支持测试与启动顺序；`segmentedLogMaxSize` SHALL 接受
`1G` / `2M` 等字节量写法。`fmq server --help` SHALL 列出全部配置项名、意义与默认值。
显式设置但无法解析的值 SHALL 被视为配置错误，MUST NOT 静默回落默认值。

#### Scenario: 默认值

- **WHEN** 清空全部相关环境变量后读取各配置
- **THEN** 得到上表默认值，且 `segmentedLogMaxSize == 1073741824`

#### Scenario: 环境变量覆盖

- **WHEN** 逐项设置环境变量（含 `2M`、`500ms`）
- **THEN** 读取到新值

#### Scenario: 帮助文本完整

- **WHEN** 执行 `fmq server --help`
- **THEN** 输出含全部配置项名与默认值，退出码 0

#### Scenario: 非法值不回落

- **WHEN** 设置 `mqServer_segmentedLogMaxSize=not-a-size` 或 `mqServer_port=abc`
- **THEN** 启动失败、退出码 2，提示具体配置项与原始值

### Requirement: 启动期校验

服务端 SHALL 在下列任一条件成立时拒绝启动，打印明确原因并返回非 0 退出码：

- `backup < 0` 或 `backup > 节点数 - 1`；
- `mqClient_hosts` 为空，或任一项无法由 `MQHost.parseHost` 解析（含端口 0/越界、空主机）；
- 本机端口不在节点表，或节点表中任意两个节点端口重复；
- `deadMsgThreshold < 1`；
- `ackTimeout <= 0`、`deadMsgTTL <= 0`、`segmentedLogTTL <= 0`、`tombstoneTTL <= 0`；
- `segmentedLogMaxSize <= 0`；
- `antiEntropyInterval <= 0`。

`selfIndex`/端口比较 SHALL 复用 `MQHost.parseHost`，MUST NOT 自实现 `host:port` 切分。
校验结论 SHALL 与 `NodeRegistry` 的构造前置条件一致。

#### Scenario: 负数备份

- **WHEN** `mqServer_backup = -1`
- **THEN** 启动失败，退出码非 0，提示不得为负

#### Scenario: 备份超过节点数

- **WHEN** 3 节点、`mqServer_backup = 3`
- **THEN** 启动失败并提示上限

#### Scenario: 缺少节点表

- **WHEN** `mqClient_hosts` 未配置
- **THEN** 启动失败并提示该配置必填

#### Scenario: 自身端口缺失

- **WHEN** `mqServer_port` 不在节点表
- **THEN** 启动失败并提示端口未出现在节点表中

#### Scenario: 非本机端口重复

- **WHEN** `mqClient_hosts = "h1:2350,h2:2351,h3:2351"` 且 `mqServer_port = 2350`
- **THEN** 启动失败并提示节点表端口重复（不能只校验本机端口）

#### Scenario: 阈值为 0

- **WHEN** `mqServer_deadMsgThreshold = 0`
- **THEN** 启动失败

#### Scenario: 零超时

- **WHEN** `mqServer_ackTimeout = 0s`
- **THEN** 启动失败并提示必须为正

#### Scenario: 端口 0 的节点项

- **WHEN** `mqClient_hosts = "h:0"`
- **THEN** 启动失败（`MQHost.parseHost` 返回 `None`），不得在 `NodeRegistry` 构造时才抛错

### Requirement: 启动装配与关闭

服务端 SHALL 按「配置校验 → 目录准备 → 元数据加载 → 节点注册 → 启动同步 → 打开本机队列 →
启动清理/备份定时器 → 启动监听」的顺序装配，并在关闭时按相反顺序释放：
停止监听、停止定时器、同步并关闭队列、落盘游标、关闭节点连接。
生产入口 SHALL 注册退出钩子：收到 `SIGTERM`/`SIGINT` 时执行完整 `close()` 后以 0 退出。
`close()` SHALL 幂等；任一释放步骤失败 SHALL 记 ERROR、继续执行其余步骤，并在返回后允许再次
调用 `close()` 重试未完成的步骤。`run()` SHALL 在 `close()` 后返回。

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

#### Scenario: 收到 SIGTERM 完整关闭

- **WHEN** 以 `server` 子命令运行并发送 `SIGTERM`
- **THEN** `close()` 全链路执行（备份最后 flush、游标落盘、队列 sync/close），进程以 0 退出

#### Scenario: 关闭中途失败

- **WHEN** `consume.close()` 抛异常
- **THEN** 其余资源仍被释放；日志有 ERROR；再次 `close()` 会重试未完成步骤且不重复关闭已完成项

#### Scenario: run 可返回

- **WHEN** 另一线程调用 `close()`
- **THEN** `run()` 在 1s 内返回，返回值为 0

### Requirement: 断链清理

服务端 SHALL 定期巡检订阅所绑定连接的关闭状态，清理已断开连接名下的全部订阅，
并释放其已分配未确认的记录。清理 SHALL 以「订阅 id + 连接代次」判定归属：若在巡检快照与注销之间
同一 `subscribedId` 已在新连接上重新订阅，MUST NOT 移除新订阅或释放其名下记录。
巡检 SHALL 可由测试直接触发，不依赖真实网络与 2s 定时器。

#### Scenario: 连接关闭后订阅消失

- **WHEN** 客户端连接被关闭
- **THEN** 该连接上的订阅全部被移除，同组其它订阅者能取到被释放的消息

#### Scenario: 重订阅不被误删

- **WHEN** 巡检取到旧快照后，同一 `subscribedId` 在新连接上完成 `SUBSCRIBE`
- **THEN** 新订阅保留，其记录不被释放

#### Scenario: 可注入触发

- **WHEN** 测试调用 `cleanupSubscribers()`（包内可见）
- **THEN** 不依赖定时器即可断言清理结果

## ADDED Requirements

### Requirement: 退出钩子

`fmq server` 的启动路径 SHALL 调用 `ExitCallbacks.toExitGracefully()` 并用
`ExitCallbacks.atExit(0, ...)` 注册 `MQServer.close()`；钩子 MUST 只在 `server` 子命令安装，
`manager` 与帮助路径 MUST NOT 安装。钩子执行完成后 SHALL 由运行时以 0 退出。
测试 SHALL 能通过可注入的启动器断言「钩子已安装 / 关闭被调用」，不真正发送信号。

#### Scenario: server 安装钩子

- **WHEN** 以 `server` 启动
- **THEN** `ExitCallbacks` 中存在一个调用 `close()` 的注册项，且已调用 `toExitGracefully()`

#### Scenario: manager 不安装

- **WHEN** 执行 `fmq manager listTopics`
- **THEN** 不注册 MQ 退出钩子

### Requirement: 关闭异常隔离

`MQServer.close()` SHALL 对每个释放步骤（监听、巡检定时器、备份、清理器、消费服务、备份存储、
队列、死信、元数据、节点连接）独立 `try/catch`。任一步骤失败 MUST NOT 阻止后续步骤；
失败 SHALL 汇总为 ERROR 日志（含步骤名与异常）。已成功的步骤 MUST NOT 因重试被重复关闭到报错。

#### Scenario: 单步失败仍完成其余

- **WHEN** 备份 `close()` 抛异常
- **THEN** 清理器、消费服务、队列、元数据仍被关闭，日志含备份步骤的 ERROR

#### Scenario: 重试收敛

- **WHEN** 第一次 `close()` 有失败步骤，修复后再次调用
- **THEN** 只重试未完成步骤，最终全部关闭

### Requirement: 备份存储生命周期

`BackupStore` SHALL 提供以下能力：按 `(ownerIndex, topic, queueIndex)` 落盘记录与备份位点；
枚举全部备份队列日志（供清理器使用）；关闭时停止接受新写入并关闭全部日志。
备份段 SHALL 参与 TTL 清理，保留边界为该队列的备份位点；没有位点时 SHALL 保留全部段。
关闭后到达的写入 SHALL 被安全丢弃并记 DEBUG/WARN（限流），MUST NOT 重建 `QueueLog`。

#### Scenario: 枚举备份队列

- **WHEN** 存在 3 个 `(owner, topic, queue)` 的备份日志
- **THEN** `allLogs()` 返回这 3 项，含 owner/topic/queueIndex

#### Scenario: 备份段被清理

- **WHEN** 备份队列位点指向段 2，段 1 超过 TTL
- **THEN** 段 1 被删除

#### Scenario: 关闭后写入

- **WHEN** `close()` 返回后调用 `append`
- **THEN** 不抛异常、不创建新 `QueueLog`，`instanceCount` 保持 0

### Requirement: 可注入的启动装配

`dispatch` SHALL 允许注入「启动服务端」与「构造管理端」的工厂，使 `fmq server` 的成功路径可在
单元测试中断言（被调用、参数正确、返回值透传），MUST NOT 在测试中真正 `listen` 或永久阻塞。
生产入口 SHALL 使用默认真实工厂。

#### Scenario: 分发到服务端

- **WHEN** 以注入工厂调用 `dispatch(["server"])`
- **THEN** 工厂被调用一次，返回其退出码，测试不阻塞

#### Scenario: 分发到管理端

- **WHEN** 以注入工厂调用 `dispatch(["manager", "listTopics"])`
- **THEN** 管理端被调用，退出码透传

### Requirement: 服务端测试资产

服务端 SHALL 为以下路径提供独立用例：内部 metaSync 变更应用（主题/组/删除）、未知命令、
发布触发备份入队、关闭释放全部资源、`stats` 的 `redelivered`/`deadLettered` 与多队列聚合、
管理端输出内容、断链清理。用例 SHALL NOT 仅断言退出码而不检查输出或状态。

#### Scenario: 内部变更落地

- **WHEN** 服务端收到内部主题分配/组注册/删除
- **THEN** 元数据、队列与订阅状态按预期变化，用例直接断言

#### Scenario: 发布触发备份

- **WHEN** `backup = 1` 时发布一条
- **THEN** 备份复制器收到一次入队（用替身断言）

#### Scenario: 关闭释放

- **WHEN** 调用 `close()`
- **THEN** 队列已 `sync`、订阅表为空、二次 `close()` 不抛异常
