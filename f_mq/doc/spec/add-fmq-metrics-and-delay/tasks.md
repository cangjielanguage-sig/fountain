# 任务：fmq 指标统计与延迟消息

> 编码任务按 TDD：先写失败用例（Red），再实现（Green），必要时重构。
> 纯文档任务不适用红绿。

## 0. 准备与归档

- [x] 0.1 新增 `fmq/doc/backlog.md`，归档 P0/P1 遗留项（不实现）
- [x] 0.2 记录基线：`f_io 20`、`f_mq 82`、`fmq 154`、`E2E_OK`

## 1. 协议载荷与发布时间（f_mq）

- [x] 1.1 先写用例：`MQInternalKind.STATS == "stats"`；`MQProtocol.stats("/order")` 命令为 `REGISTER`，子载荷解码为字符串
- [x] 1.2 先写用例：`MQMessageRecord.publishTime` 标准 23 位 ID → UTC 时间；`mid-1` / 位数不足 → `None`
- [x] 1.3 实现 `MQInternalKind.STATS`、`MQProtocol.stats(topic)`、`publishTime`
- [x] 1.5 `cd f_mq && cjpm test --no-progress` 全绿

## 2. 主题延迟元数据（f_mq + fmq）

- [x] 2.1 先写用例：`MQTopicMeta` / `MQTopicAssignment` 带 `delayingMs` 往返；负值在注册入口被拒绝
- [x] 2.2 实现字段与构造参数；`MQAssignment.allocate` 传递 `delayingMs`
- [x] 2.3 先写用例：`MetaStore` 持久化后重建保留 `delayingMs`；快照与远端应用保留
- [x] 2.4 实现 `MetaSyncer` / `MetaStore` 链路
- [x] 2.5 `cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 相关用例全绿

## 3. 延迟投递（fmq）

- [x] 3.1 先写用例：`delaying=61s`，发布后立即消费返回空、`committed` 不变；时钟推进 62s 后投递
- [x] 3.2 先写用例：`delaying=0` 与无延迟行为一致；队首未到期时第二条不被越过
- [x] 3.3 先写用例：重启后仍按发布时间延迟；非标准 messageId 立即投递并 WARN
- [x] 3.4 实现：`GroupCursor` 注入 `delaying`，扫描新记录时判定到期；未到期停在队首
- [x] 3.5 `cd fmq && cjpm test --no-progress` 全绿

## 4. 指标计数器（fmq）

- [x] 4.1 先写用例：投递两次再确认 → `delivered=2`、`redelivered>=1`、`acked>=1`；死信 → `deadLettered=1`
- [x] 4.2 实现 `MQMetrics`（ConcurrentHashMap + AtomicInt64）并注入 `GroupCursor`
- [x] 4.3 在 `next` / `ack` / `writeDeadLetter` 埋点
- [x] 4.4 `cd fmq && cjpm test --no-progress` 全绿

## 5. 统计服务与协议分派（fmq）

- [x] 5.1 先写用例：发布 3 条、确认 1 条 → 组 `backlog=2`、`lagMs>0`；全部确认后 `backlog=0`
- [x] 5.2 先写用例：`stats` 按主题过滤、未知主题返回空、查询不改变 `committed`
- [x] 5.3 实现 `QueueLog.scanAfter(position)` 与 `countAll()`；`QueueManager.localTopics/delayingOf`
- [x] 5.4 实现 `ConsumeService.stats(topic)` 组装 TSV 文本
- [x] 5.5 实现 `MQCommandExecutor.onInternal` 的 `STATS` 分派
- [x] 5.6 `cd fmq && cjpm test --no-progress` 全绿

## 6. 管理端（fmq）

- [x] 6.1 先写用例：`stats` 全部主题 / 按主题 / 未知主题 / 连接失败
- [x] 6.2 先写用例：`registerTopic` 的 `delaying=1m1s`、默认 `0s`、`delaying=abc` / `-1s` 返回 2
- [x] 6.3 先写用例：`listTopics` 输出含 delaying 列
- [x] 6.4 实现 `MQManagerArgs`（`stats`、可选第三操作数）、`MQManager.stats`、`registerTopic` 新签名、列表列
- [x] 6.5 更新 `MQUsage` / 帮助文本
- [x] 6.6 `cd fmq && cjpm test --no-progress` 全绿

## 7. 文档

- [x] 7.1 `fmq/README.md` / `README_en.md`：`stats` 用法、指标口径、`delaying` 定义与时钟前提
- [x] 7.2 `fmq/doc/详细设计.md`：统计与延迟章节；`f_mq/doc/详细设计.md`：新增载荷与 `publishTime`
- [x] 7.3 `fmq/src/MQUsage.cj` 的配置/子命令说明与测试同步
- [x] 7.4 `fmq/doc/backlog.md` 复核：已实现的指标项从 P1 移除

## 8. 回归与交付

- [x] 8.1 `f_io` 20 项通过（20/20）
- [x] 8.2 `f_mq` 全绿（85/85）
- [x] 8.3 `fmq` 全绿（168/168）
- [x] 8.4 `scripts/mq_e2e.sh` 输出 `E2E_OK`（发布 7637ms、消费 12694ms、重投 3、死信 1）
- [x] 8.5 新增 E2E：注册 `delaying=3s` 主题，消费实际耗时 ≥2.5s 后取到消息
- [ ] 8.6 按代码/文档分组提交，工作区干净

## 验收清单

- [x] `fmq manager stats` 可查询积压、延迟、投递/确认/重投/死信计数
- [x] 指标口径与 `fmq/metrics` 规格一致，查询无副作用
- [x] `registerTopic ... delaying=1m1s` 生效；未到期不投递、不推进 committed
- [x] 延迟跨重启有效；`delaying=0` 行为不变
- [x] `listTopics` 显示 delaying；帮助文本同步
- [x] P0/P1 已归档到 `fmq/doc/backlog.md`
- [x] 三模块全量 + E2E 全绿
