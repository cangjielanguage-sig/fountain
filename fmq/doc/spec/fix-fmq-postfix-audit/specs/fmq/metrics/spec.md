# fmq/metrics（delta）

## ADDED Requirements

### Requirement: 跳过计数的指标口径

`MQMetrics` SHALL 为每个 `(topic, group)` 维护三个单调递增计数器：
`skippedUnreadable`、`skippedNoMatch`、`skippedUnsupported`，分别对应：
段缺失导致记录不可读、组内无匹配订阅而越过、BODY 不可评估而越过。
计数器 SHALL 在投递路径上累加，SHALL 由 `stats` 输出，SHALL 在删除主题/组时清理。
计数器 MUST NOT 包含「记录损坏」事件（损坏不推进游标，见 `fmq/consume-semantics`）。

#### Scenario: 累加

- **WHEN** 一次消费过程越过 2 条无匹配记录
- **THEN** `skippedNoMatch` 加 2，其余两个不变

#### Scenario: 输出

- **WHEN** 查询 `stats`
- **THEN** 三个计数作为 TSV 的尾部三列输出，与 `MQMetrics` 读取值一致

#### Scenario: 清理

- **WHEN** 删除该主题或组
- **THEN** 三个计数器被移除

## MODIFIED Requirements

### Requirement: 统计查询

服务端 SHALL 以 TSV 返回统计，表头固定为：

```
#\t<nodeIndex>\t<generatedAtMs>\n
#\ttopic\tgroup\tqueueNum\tdelaying\tbacklog\tlagMs\tdelivered\tacked\tredelivered\tdeadLettered\tskippedUnreadable\tskippedNoMatch\tskippedUnsupported\n
```

数据行 SHALL 以 `R` 开头，共 14 列（`R` + 13 个字段），列顺序与表头一致；
`group` 为空表示该队列没有组（输出空串）。
`backlog` 与 `lagMs` SHALL 基于游标当前 `committed` 计算；若 `committed` 所在段已缺失且尚未被
消费路径修复，SHALL 返回 `ERROR(INTERNAL)`，MUST NOT 输出偏小的 `backlog`。
查询 SHALL 无副作用：不得创建目录、不得推进游标、不得修改指标。

#### Scenario: 查询全部

- **WHEN** `stats` 不带主题
- **THEN** 返回所有主题的行，列数与表头一致

#### Scenario: 按主题过滤

- **WHEN** `stats /order`
- **THEN** 只返回该主题的行

#### Scenario: 未知主题

- **WHEN** `stats /nope`
- **THEN** 只返回表头，无数据行，不报错

#### Scenario: 查询无副作用

- **WHEN** 连续两次查询
- **THEN** 指标与游标不变，输出一致

#### Scenario: 扫描失败不伪造 0

- **WHEN** 位点段缺失且游标未修复
- **THEN** 返回 `ERROR(INTERNAL)`，错误文案含 topic/queue/group

#### Scenario: 跳过列存在

- **WHEN** 解析任一行
- **THEN** 第 12–14 个字段分别为三个跳过计数

### Requirement: 指标清理入口

`MQMetrics` SHALL 支持删除主题/组的计数器，并 SHALL 与读取并发安全：

- `bump`/`inc*` SHALL 用一次原子操作完成「取或建 + 自增」（如 `compute`），
  MUST NOT 先 `addIfAbsent` 再 `get().getOrThrow()`；
- 删除与自增并发时，自增 MUST NOT 抛异常；被删除键上的自增结果可以被丢弃，
  但不得影响消费路径（`next()` 不得因指标抛错而失败）；
- 并发读取 SHALL NOT 因遍历删除而抛 `ConcurrentModificationException` 类异常；
- 删除 SHALL 同时清理三个跳过计数。

#### Scenario: 删除主题

- **WHEN** 删除主题
- **THEN** 该主题所有计数器被移除

#### Scenario: 删除组

- **WHEN** 删除组
- **THEN** 该组所有计数器被移除

#### Scenario: 并发读取

- **WHEN** 一个线程持续 `stats` 读取，另一个线程删除主题/组
- **THEN** 读取不抛异常，删除后不再出现被删 key

#### Scenario: 并发自增与删除

- **WHEN** 消费投递路径自增与 `removeTopic`/`removeGroup` 并发
- **THEN** 投递不抛 `INTERNAL`，`delivered`/`acked` 不因键消失而中断
