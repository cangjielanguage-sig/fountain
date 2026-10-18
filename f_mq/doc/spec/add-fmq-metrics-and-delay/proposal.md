# Proposal: add-fmq-metrics-and-delay

## Why

`fmq` 目前没有任何运行指标：运维只能看日志和目录大小，无法回答「积压多少、消费延迟多大、重投了多少、死信多少」。
同时，业务侧需要「发布后延迟一段时间才可被消费」的能力（例如订单超时提醒、重试退避），
当前只能由消费者自己 sleep 或另建定时任务，既浪费连接也无法保证「到点才投递」。

本次变更补齐这两项：`fmq manager stats` 查询节点级指标；主题新增 `delaying` 定义项，
消息在延迟到期前不投递、不推进游标。

## What Changes

1. **指标采集与查询**
   - 服务端维护进程内计数器：`delivered` / `acked` / `redelivered` / `deadLettered`（按 topic + group）。
   - `backlog` 与 `lagMs` 在查询时按游标位置扫描计算：`backlog` = committed 之后的记录数；
     `lagMs` = 当前时间 − backlog 中最早一条记录的发布时间（取自 messageId 时间戳）。
   - 新增内部消息 `MQInternalKind.STATS`，请求/响应使用 TSV 文本（复用 `REGISTER`），
     不新增对象载荷类。
   - `fmq manager stats [topic]` 输出节点级表格；省略 topic 时输出全部本地主题。

2. **主题延迟定义**
   - `MQTopicMeta` / `MQTopicAssignment` 新增 `delayingMs`；注册主题时由
     `fmq manager registerTopic <topic> <queueNum> [delaying=1m1s]` 指定，默认 `0s`。
   - `delaying` 随元数据落盘、广播与快照复制；`listTopics` 增加 delaying 列。
   - 投递判定：记录发布时间 + `delaying` ≤ 当前时间才可投递；未到期时停在队首，
     **不投递、不标记已决、不推进 committed**，到期后自然继续。
   - 发布时间取 messageId 末尾的 23 位 UTC 时间戳；无法解析时按「已到期」处理并记 WARN。
   - 延迟跨重启有效（时间戳在记录内，不依赖内存）。

3. **遗留项归档**：P0/P1 清单写入 `fmq/doc/backlog.md`，本轮不实现。

## Capabilities

**New Capabilities**

- `fmq/metrics`：指标口径、采集点、`stats` 查询响应与节点级语义。

**Modified Capabilities**

- `fmq/manager-cli`：新增 `stats` 子命令；`registerTopic` 增加可选 `delaying=`；`listTopics` 增加延迟列。
- `fmq/consume-semantics`：新增延迟投递的到期判定与队首阻塞语义。
- `f-mq/protocol`：主题元数据/分配增加 `delayingMs`；新增统计请求与快照载荷、内部 kind。
- `fmq/metadata-cluster`：分配结果携带延迟并随落盘/广播/快照复制。

## Impact

| 范围 | 影响 |
|---|---|
| `f_mq/src/base/model/MQTopicMeta.cj` | 新增 `delayingMs` 字段 |
| `f_mq/src/base/payload/MQTopicAssignment.cj` | 新增 `delayingMs` 字段（**元数据格式变更**） |
| `f_mq/src/base/MQProtocol.cj` | 新增 `stats(topic)` 与 `STATS` kind |
| `f_mq/src/base/MQConstants.cj` / `MQProtocol.cj` | 新增 `STATS` kind 与工厂 |
| `f_mq/src/base/MQMessageRecord.cj` | 新增 `publishTime()` 解析 messageId 时间戳 |
| `fmq/src/queue/GroupCursor.cj` | 延迟到期判定；投递/确认/重投/死信计数 |
| `fmq/src/queue/QueueLog.cj` | 新增 `scanAfter()`（记录数与最早发布时间） |
| `fmq/src/queue/QueueManager.cj` | 保存/查询主题延迟与本地主题列表 |
| `fmq/src/metrics/MQMetrics.cj` | 新增指标计数器 |
| `fmq/src/server/ConsumeService.cj` | 组装 `MQStatsSnapshot`；向游标注入延迟与指标 |
| `fmq/src/server/MQCommandExecutor.cj` | 分派 `STATS` 内部消息 |
| `fmq/src/manager/MQManager*.cj` | `stats` 子命令、`registerTopic` 可选参数、列表列 |
| `fmq/doc/backlog.md` | P0/P1 归档 |

兼容性：`MQTopicMeta` / `MQTopicAssignment` 增加字段属于**源码与元数据格式变更**；旧元数据文件缺少
`delayingMs`，升级后需重新注册主题（当前为未发布功能分支，按 BREAKING 记录）。协议命令号不变。
