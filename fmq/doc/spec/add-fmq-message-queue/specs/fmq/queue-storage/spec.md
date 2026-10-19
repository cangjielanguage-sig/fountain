# fmq 队列存储（delta）

## ADDED Requirements

### Requirement: 队列目录布局与本机队列归属

服务端 SHALL 按主题与队列编号组织消息文件：`<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log`，
并 SHALL 只为「owner 是本机」的队列创建与打开日志。MQ 自身不得创建第二份索引文件。

#### Scenario: 只建本机队列

- **WHEN** 主题 `/t` 的 `owners = [0,1,2,0]`，本机下标为 0
- **THEN** 只创建 `<logRoot>/%2Ft/0/` 与 `<logRoot>/%2Ft/3/` 两个队列目录

#### Scenario: 无本机队列

- **WHEN** 主题的 owners 不包含本机下标
- **THEN** `pickQueue` 返回 `None`，服务端回 `NOT_OWNER`

### Requirement: 追加返回位置且单调

`QueueLog.append(record)` SHALL 返回该记录的 `LogPosition`；同一段内 `offset` 严格递增，
跨段后 `offset` 归零且段号加一。每条 append SHALL 在 `syncInterval = 1` 下完成落盘同步。

#### Scenario: 段内与跨段位置

- **WHEN** 连续追加记录直到发生轮转
- **THEN** 段内 offset 严格递增；轮转后新记录 offset 为 0、段号加一

#### Scenario: 每条记录可立即读回

- **WHEN** 每条 append 后立即用返回位置 `readAt`
- **THEN** 读到的字节与写入逐字节相等（含进程重启后重开）

### Requirement: 重启永不续写旧段

重开队列日志 SHALL 新建一个段，编号为目录内最大编号加一；旧段内容 SHALL 保持字节级不变，
且仍然可读。

#### Scenario: 重启后开新段

- **WHEN** 写入若干条、关闭、重新打开同一目录，再追加一条
- **THEN** 新记录落在编号更大的新段，旧段文件内容与关闭前完全一致

#### Scenario: 重启后有效长度不变

- **WHEN** 关闭前后比较各段有效长度之和
- **THEN** 两者相等

### Requirement: 按位置顺序读取与有界快照

`openFrom(position)` SHALL 从指定位置开始按写入顺序读出后续记录，跳过段内的预分配空洞；
返回的流 SHALL 是创建时刻的段与长度快照，之后新 append 的数据不出现在该流中，必须用最新位置重开。

#### Scenario: 从中间位置读

- **WHEN** 写入 5 条后从第 3 条的位置开流
- **THEN** 依次读出第 3、4、5 条

#### Scenario: 不读预分配区

- **WHEN** 段文件按 `maxFileSize` 预分配，读取到该段最后一条记录
- **THEN** 流结束，不会解出零填充的伪记录

#### Scenario: 快照语义

- **WHEN** 打开流并读尽后再 append 一条
- **THEN** 旧流读不到新记录；用新位置重开后能读到

#### Scenario: 位置已失效

- **WHEN** 起始位置所在的段已被 TTL 清理删除
- **THEN** 开流抛出 `IllegalArgumentException`，调用方按「跳到现存最老段」处理

### Requirement: 有效长度以段元数据为准

队列与死信的「有效字节数」SHALL 取各段 `logMetas().size` 之和，不得用文件长度推断。

#### Scenario: 有效长度不含空洞

- **WHEN** 队列只写入少量数据但段文件已预分配
- **THEN** `size` 等于实际写入字节数之和，远小于文件长度

### Requirement: 本机队列轮转选择

发布消息时，服务端 SHALL 在本机持有的该主题队列之间轮转选择，保证各队列写入量均衡。

#### Scenario: 三轮均分

- **WHEN** 本机有 3 个队列，连续调用 6 次 `pickQueue`
- **THEN** 3 个队列各被选中 2 次

### Requirement: 消费位点持久化

游标位点 SHALL 以 `codec(segmentedIndex) ‖ codec(segmentedOffset)` 写入
`metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor`，采用「临时文件 + rename」原子覆盖；
重启后 SHALL 能读回最后一次写入的值。

#### Scenario: 往返

- **WHEN** 保存 `(seq = 7, offset = 128)` 后重新加载
- **THEN** 得到相同的两个值

#### Scenario: 覆盖写无残留

- **WHEN** 对同一位置连续保存 1000 次
- **THEN** 最终读到最后一次的值，目录中没有 `.tmp` 残留文件

#### Scenario: 默认组

- **WHEN** 订阅组名为空串
- **THEN** 位点文件名为 `%00.cursor`，可正常保存与读取

### Requirement: 主题删除清理

`deleteTopic` SHALL 删除本机该主题的全部队列文件、订阅组元数据与该主题的全部游标位点；
`deleteSubscribeGroup` SHALL 删除该组元数据与该组的全部游标位点。

#### Scenario: 删除主题后目录消失

- **WHEN** 对已有消息的主题执行删除
- **THEN** 本机对应队列目录不再存在，游标位点被清理

#### Scenario: 删除组后位点消失

- **WHEN** 删除某订阅组
- **THEN** 该组在各队列上的位点文件被删除，其他组不受影响

### Requirement: 死信独立存储

死信 SHALL 写入独立的 `SegmentedLog`（`<deadMsgDir>/log_<seq>.log`），每条为自描述的
`codec(MQDeadLetterMessage)`，包含原始记录与来源上下文；SHALL 支持从指定位置顺序读取，
并在重启后保持完整。

#### Scenario: 写入后顺序读取

- **WHEN** 写入 3 条死信并从第 1 条位置开始迭代
- **THEN** 按顺序得到 3 条，record 原文与来源上下文逐项一致

#### Scenario: 从中间位置读取

- **WHEN** 从第 2 条的位置开始迭代
- **THEN** 只得到后两条

#### Scenario: 重启保持

- **WHEN** 关闭并重开死信队列
- **THEN** 迭代结果与关闭前一致

### Requirement: 段 TTL 清理

清理器 SHALL 删除「`updateTime + ttl < now` 且没有任何游标引用该段」的封口段，
且 MUST NOT 删除当前写入段。死信段 SHALL 使用独立的 `deadMsgTTL` 判定。

#### Scenario: 超期且无引用则删除

- **WHEN** 某封口段的更新时间早于 `now - ttl`，且没有游标引用
- **THEN** 该段被删除，返回删除段数

#### Scenario: 被游标引用则保留

- **WHEN** 某段已超期，但存在游标的 `references(index) == true`
- **THEN** 该段保留

#### Scenario: 当前段永不删除

- **WHEN** 当前写入段已超过 TTL
- **THEN** 该段不会被删除

#### Scenario: 死信用自己的 TTL

- **WHEN** 死信段超过 `deadMsgTTL` 但未超过 `segmentedLogTTL`
- **THEN** 死信段被清理，普通队列段不受影响
