# fmq 元数据与集群（delta）

## ADDED Requirements

### Requirement: 延迟元数据的持久化与复制

主题分配结果中的 `delayingMs` SHALL 随 `MQTopicAssignment` 一起原子落盘；重建 `MetaStore`
后 SHALL 保持原值。注册主题的广播、启动期全量快照与远端应用 SHALL 携带同一 `delayingMs`，
不得在复制链路中丢失或归零。

#### Scenario: 重启保持

- **WHEN** 注册 `delaying=1m1s` 的主题后重建 `MetaStore`
- **THEN** 读回的 `delayingMs == 61000`

#### Scenario: 快照携带

- **WHEN** 另一节点拉取全量快照
- **THEN** 快照中该主题的 `delayingMs` 与注册节点一致

#### Scenario: 远端应用

- **WHEN** 节点收到带 `delayingMs` 的主题广播
- **THEN** 落盘与内存索引中的值一致，后续消费按该延迟执行
