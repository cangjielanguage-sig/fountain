# fmq 元数据与集群（delta）

## MODIFIED Requirements

### Requirement: 队列轮转分配

注册主题时 SHALL 按「队列 i → 节点 `(start + i) % nodeCount`」分配，并把下一主题的起始下标推进为
`(start + queueNum) % nodeCount`。分配结果 SHALL 自包含（含 `queueNum`、`startNodeIndex` 与
每个队列的 owner），不依赖各节点对节点表的一致理解。接收主题广播的远端节点 SHALL 用分配结果中的
`startNodeIndex` 与 `queueNum` 推进本地 `nextStartNode`，使任一节点后续承接注册时与注册节点使用
同一轮转位置。

#### Scenario: 规格示例逐字复现

- **WHEN** 3 节点、`/topic1` 4 队列、start = 0
- **THEN** `owners = [0,1,2,0]`、`nextStart = 1`；随后 `/topic2` 2 队列得到 `owners = [1,2]`

#### Scenario: 单节点

- **WHEN** 节点数为 1
- **THEN** 全部队列 owner 为 0，起始下标保持 0

#### Scenario: 单队列环绕

- **WHEN** start = 2、节点数 3、1 队列
- **THEN** owner 为 2，下一 start 为 0

#### Scenario: 非法队列数

- **WHEN** `queueNum <= 0`
- **THEN** 抛异常，注册请求回 `ERROR`

#### Scenario: 远端节点推进指针

- **WHEN** 节点 0 注册 4 队列得到 start = 0，节点 1 收到广播后再注册新主题
- **THEN** 节点 1 的起始下标与节点 0 一致（均为 1），不会重新从 0 开始

### Requirement: 备份副本复制

当 `mqServer_backup > 0` 时，发布成功后 SHALL 异步把记录与其状态推送给环形后续的 `backup` 个节点；
接收方 SHALL 只落盘副本，不投递、不再次备份。批量 SHALL 在「累积 64 条」或「距上次 100ms」时触发；
队列有界，溢出时 SHALL 丢弃并记 WARN，不得阻塞发布。关闭时 SHALL 停止定时器并做最后一次 flush，
把已入队未发送的记录全部发出。

#### Scenario: 目标为环形后继

- **WHEN** self = 0、节点数 3、backup = 2
- **THEN** 只向节点 1、2 发送

#### Scenario: backup 为 0

- **WHEN** `mqServer_backup = 0`
- **THEN** 不发送任何备份消息

#### Scenario: 按条数或时间 flush

- **WHEN** 累积到 64 条，或注入时钟前进 100ms
- **THEN** 各触发一次发送，载荷记录条数正确

#### Scenario: 定时器到期刷写

- **WHEN** 只记录 1 条，未达到 64 条，等待超过 100ms
- **THEN** 定时器触发发送，该条记录出现在载荷中

#### Scenario: 关闭排空

- **WHEN** 队列中仍有未发送记录时调用关闭
- **THEN** 关闭前做最后一次 flush，记录全部发出，定时器停止

#### Scenario: 队列满不阻塞

- **WHEN** 备份队列达到上限
- **THEN** 新记录被丢弃并记 WARN，发布调用立即返回

#### Scenario: 副本不参与消费

- **WHEN** 接收方收到备份消息
- **THEN** 只写入备份目录，本队列与订阅表均无变化

#### Scenario: 单节点故障不影响其它

- **WHEN** 后继节点 1 不可达、节点 2 可达
- **THEN** 节点 2 仍收到副本
