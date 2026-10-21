# fmq 指标（delta）

## MODIFIED Requirements

### Requirement: 指标口径

服务端 SHALL 按节点维护以下指标：

- `delivered` / `acked` / `redelivered` / `deadLettered`：按 `(topic, subscribeGroup)` 累计，
  从进程启动开始计数（重启归零）。
- `backlog`：指定组在该主题本地队列中、`committed` 位置之后的记录数（含已投递未确认与未投递）。
- `lagMs`：`backlog` 中最早一条记录的发布时间到当前时间的毫秒数；`backlog = 0` 或发布时间
  不可解析时为 0；计算结果为负时 SHALL 取 0。

`acked` SHALL 覆盖自动确认投递：`autoAck = true` 的订阅每成功投递一条并推进 `committed` 时，
SHALL 同时累加 `acked`。`backlog` 与 `lagMs` 在查询时按游标位置扫描计算，必须与查询时刻的持久化
状态一致，不得使用可能失真的估算值。
主题或订阅组被删除时 SHALL 清理该键下的计数器；同名重建后 SHALL 从 0 开始。
发布时间 SHALL 取自 messageId 末尾的 23 位 UTC 时间戳。

#### Scenario: 积压与延迟

- **WHEN** 发布 3 条消息、组只确认 1 条后查询
- **THEN** `backlog = 2`；`lagMs` 约等于第 2 条消息的发布时长

#### Scenario: 无积压

- **WHEN** 组已确认全部消息
- **THEN** `backlog = 0`、`lagMs = 0`

#### Scenario: 计数器

- **WHEN** 一条消息被投递两次（超时重投）后确认，另一条进入死信
- **THEN** 该组 `delivered >= 2`、`redelivered >= 1`、`acked >= 1`、`deadLettered >= 1`

#### Scenario: 自动确认计数

- **WHEN** `autoAck = true` 的组消费 3 条
- **THEN** `backlog = 0` 且 `acked >= 3`

#### Scenario: 删除后计数清零

- **WHEN** 删除主题或组后以同名重建并查询
- **THEN** 四个计数器均为 0

#### Scenario: 未来发布时间

- **WHEN** 最早一条记录的发布时间晚于当前时刻
- **THEN** `lagMs = 0`，不出现负值

### Requirement: 统计查询

服务端 SHALL 接受 `REGISTER` + `MQInternalMessage{kind = "stats"}` 请求，子载荷为 topic 字符串；
空串表示全部本地主题。响应 SHALL 为 TSV 文本：

```
#\t<nodeIndex>\t<generatedAtMs>\n
R\t<topic>\t<group>\t<queueNum>\t<delayingMs>\t<backlog>\t<lagMs>\t
  <delivered>\t<acked>\t<redelivered>\t<deadLettered>\n
```

无订阅组的主题输出一行 group 为空的 `R` 记录。
统计 SHALL 只反映被查询节点的本地队列；不存在的主题不返回 `R` 记录，不报错。
查询 SHALL NOT 改变游标、消息或元数据。

统计期间任一队列扫描失败（段缺失、目录不可读、记录损坏）时，服务端 SHALL 返回
`ERROR(INTERNAL)` 并记 WARN，MUST NOT 以 `backlog = 0` / `lagMs = 0` 冒充正常结果。
同一 `(topic, group)` 的多队列统计 SHALL 合并为一次顺序扫描（按最小的 `committed` 起步，
一次遍历内按各组的 `committed` 分桶计数），MUST NOT 对每个队列重复全量扫描。

#### Scenario: 查询全部

- **WHEN** 节点上有两个主题时执行 stats 且 topic 为空
- **THEN** 返回两行 `R` 记录，首行 `#` 的节点下标为本节点

#### Scenario: 按主题过滤

- **WHEN** stats 请求 topic = `/order`
- **THEN** 只返回 `/order`，其它主题不出现

#### Scenario: 未知主题

- **WHEN** stats 请求一个未注册主题
- **THEN** 响应成功且不含 `R` 记录

#### Scenario: 查询无副作用

- **WHEN** 查询前后对比 `committed` 与记录数
- **THEN** 两者均不变

#### Scenario: 扫描失败不伪造 0

- **WHEN** 某队列的段目录不可读或段被并发删除导致扫描失败
- **THEN** 返回 `ERROR(INTERNAL)`，日志含 topic/queue/group，MUST NOT 返回 `backlog = 0`

## ADDED Requirements

### Requirement: 指标清理入口

`MQMetrics` SHALL 提供按主题、按 `(topic, group)` 清理计数器的入口；服务端在
「删除主题 / 删除订阅组 / 远端墓碑生效」时 SHALL 调用对应入口。清理 SHALL 与读取并发安全，
不得因遍历删除抛异常。

#### Scenario: 删除主题

- **WHEN** 删除 `/order`
- **THEN** `/order` 下所有组的计数器被移除，`stats` 不再返回这些键

#### Scenario: 删除组

- **WHEN** 删除 `/order` 的组 `g`
- **THEN** 只移除该组，其他组不受影响

#### Scenario: 并发读取

- **WHEN** 清理与 `stats` 并发
- **THEN** 不抛异常，读取到的值要么是清理前要么是 0
