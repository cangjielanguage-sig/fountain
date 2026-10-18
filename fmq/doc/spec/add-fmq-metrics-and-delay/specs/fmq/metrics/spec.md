# fmq 指标（delta）

## ADDED Requirements

### Requirement: 指标口径

服务端 SHALL 按节点维护以下指标：

- `delivered` / `acked` / `redelivered` / `deadLettered`：按 `(topic, subscribeGroup)` 累计，
  从进程启动开始计数（重启归零）。
- `backlog`：指定组在该主题本地队列中、`committed` 位置之后的记录数（含已投递未确认与未投递）。
- `lagMs`：`backlog` 中最早一条记录的发布时间到当前时间的毫秒数；`backlog = 0` 或发布时间
  不可解析时为 0。

发布时间 SHALL 取自 messageId 末尾的 23 位 UTC 时间戳。`backlog` 与 `lagMs` 在查询时按游标位置
扫描计算，必须与查询时刻的持久化状态一致，不得使用可能失真的估算值。

#### Scenario: 积压与延迟

- **WHEN** 发布 3 条消息、组只确认 1 条后查询
- **THEN** `backlog = 2`；`lagMs` 约等于第 2 条消息的发布时长

#### Scenario: 无积压

- **WHEN** 组已确认全部消息
- **THEN** `backlog = 0`、`lagMs = 0`

#### Scenario: 计数器

- **WHEN** 一条消息被投递两次（超时重投）后确认，另一条进入死信
- **THEN** 该组 `delivered >= 2`、`redelivered >= 1`、`acked >= 1`、`deadLettered >= 1`

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
