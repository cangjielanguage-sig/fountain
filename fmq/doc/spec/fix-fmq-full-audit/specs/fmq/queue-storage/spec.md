# fmq 队列存储（delta）

## MODIFIED Requirements

### Requirement: 按位置顺序读取与有界快照

`openFrom(position)` SHALL 从指定位置开始按写入顺序读出后续记录，跳过段内的预分配空洞；
返回的流 SHALL 是创建时刻的段与长度快照，之后新 append 的数据不出现在该流中，必须用最新位置重开。
起始位置所在段已被删除时：若存在编号更大的段，SHALL 从最接近的更大段起点继续；若不存在，SHALL
返回空流并记 WARN。调用方 MUST NOT 把「段缺失」解释为「积压为 0」而不留痕。

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
- **THEN** 不抛 `IllegalArgumentException`：从最接近的更大段继续；若不存在则返回空流并记 WARN

#### Scenario: 起始段落在空洞

- **WHEN** 起点段号为 5，现存段为 1、7、8
- **THEN** 从段 7 起点继续，并记 WARN（含原位置与实际起点）

#### Scenario: 全部段被删除

- **WHEN** 起点段与所有更晚的段都不存在
- **THEN** 返回空流，记 WARN；统计层不得输出 `backlog = 0` 而不报错

### Requirement: 消费位点持久化

游标位点 SHALL 以 `codec(segmentedIndex) ‖ codec(segmentedOffset)` 写入
`metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor`，采用「临时文件 + rename」原子覆盖；
写入 SHALL 在 rename 前对文件 `flush` + `fsync`，rename 后对父目录 `fsync`。
重启后 SHALL 能读回最后一次写入的值；掉电后 MUST NOT 得到 0 字节或被截断的文件。
同一位置的重复保存 SHALL 幂等，不得产生 `.tmp` 残留。

#### Scenario: 往返

- **WHEN** 保存 `(seq = 7, offset = 128)` 后重新加载
- **THEN** 得到相同的两个值

#### Scenario: 覆盖写无残留

- **WHEN** 对同一位置连续保存 1000 次
- **THEN** 最终读到最后一次的值，目录中没有 `.tmp` 残留文件

#### Scenario: 默认组

- **WHEN** 订阅组名为空串
- **THEN** 位点文件名为 `%00.cursor`，可正常保存与读取

#### Scenario: 落盘后可持久

- **WHEN** `save` 返回成功
- **THEN** 文件内容已 fsync；模拟掉电后仍能解析出同一位置（不得为半条记录）

### Requirement: 主题删除清理

`deleteTopic` SHALL 删除本机该主题的全部队列文件、订阅组元数据与该主题的全部游标位点；
`deleteSubscribeGroup` SHALL 删除该组元数据与该组的全部游标位点。
删除 SHALL 先写墓碑（见 metadata-cluster），再按「组 → 主题文件 → 目录」顺序清理；
中途失败后重试 SHALL 收敛到同一终态，MUST NOT 留下「主题文件已删、组仍存在」的孤儿组。

#### Scenario: 删除主题后目录消失

- **WHEN** 对已有消息的主题执行删除
- **THEN** 本机对应队列目录不再存在，游标位点被清理

#### Scenario: 删除组后位点消失

- **WHEN** 删除某订阅组
- **THEN** 该组在各队列上的位点文件被删除，其他组不受影响

#### Scenario: 删除中途崩溃

- **WHEN** 删除主题时在「删组」与「删主题文件」之间中断，随后重启
- **THEN** 加载阶段不产生孤儿组；重试删除或反熵后主题完全消失

### Requirement: 段 TTL 清理

清理器 SHALL 删除「`updateTime + ttl < now` 且没有任何游标引用该段」的封口段，
且 MUST NOT 删除当前写入段。死信段 SHALL 使用独立的 `deadMsgTTL` 判定。
「游标」SHALL 同时包括内存中的 `GroupCursor` 与磁盘上的持久化位点：
对每个已注册订阅组，若其位点文件缺失，SHALL 视为位于 `(1, 0)`（即引用全部段）；
若存在，则 `segmentIndex >= committed.seq` 视为引用。备份段 SHALL 使用同一规则，
以其备份位点为保留边界。

#### Scenario: 超期且无引用则删除

- **WHEN** 某封口段的更新时间早于 `now - ttl`，且没有游标引用
- **THEN** 该段被删除，返回删除段数

#### Scenario: 被游标引用则保留

- **WHEN** 某段已超期，但存在游标的 `references(index) == true`
- **THEN** 该段保留

#### Scenario: 离线组的持久化位点仍保留段

- **WHEN** 组 G 的游标只存在于磁盘（重启后未消费），位点指向段 3，段 3 已超期
- **THEN** 段 3 保留，MUST NOT 被删除

#### Scenario: 从未消费的组

- **WHEN** 组已注册但从未产生位点文件，段 1 已超期
- **THEN** 段 1 保留（视为引用全部段）

#### Scenario: 当前段永不删除

- **WHEN** 当前写入段已超过 TTL
- **THEN** 该段不会被删除

#### Scenario: 死信用自己的 TTL

- **WHEN** 死信段超过 `deadMsgTTL` 但未超过 `segmentedLogTTL`
- **THEN** 死信段被清理，普通队列段不受影响

#### Scenario: 备份段按其位点保留

- **WHEN** 备份队列的位点指向段 2，段 1 超期
- **THEN** 段 1 被删除，段 2 保留

### Requirement: 记录边界格式与文档化

每条队列记录在段内 SHALL 以 `[4 字节大端无符号长度][记录字节]` 存放；长度只表示后续记录字节数，
不包含 4 字节头。读取端 SHALL 以该长度确定单条边界，记录 SHALL NOT 跨段。
读取端 SHALL 在分配缓冲前校验：`1 <= length <= MAX_RECORD_SIZE（64 MiB）` 且
`length <= 当前段剩余有效字节`；任一不满足 SHALL 视为损坏，停止读取并记 ERROR（含段号、偏移、
声明长度、剩余字节），MUST NOT 按声明长度分配缓冲。
长度为 0 SHALL 立即停止读取，不得继续解析后续字节。
该格式与上界 SHALL 写入 `design.md` 与模块设计文档，并注明：升级时不得改变前缀宽度或字节序，
否则旧段无法按边界读取。

#### Scenario: 格式写入设计文档

- **WHEN** 查阅 `openspec/changes/fix-fmq-full-audit/design.md` 与 `fmq/doc/详细设计.md`
- **THEN** 能找到「4 字节大端长度 + 记录字节」、64 MiB 上界与兼容约束

#### Scenario: 长度不含头部

- **WHEN** 写入一条 10 字节记录
- **THEN** 段内占用 14 字节，前 4 字节解码为 10

#### Scenario: 零长度视为损坏

- **WHEN** 段中出现长度为 0 的前缀
- **THEN** 读取立即停止，不返回空记录、不越界、不继续解析

#### Scenario: 超大声明长度

- **WHEN** 段头声明的长度为 `0xFFFFFFFF`
- **THEN** 读取停止，记 ERROR，进程内存不增长（不分配 4 GiB）

#### Scenario: 超过段剩余

- **WHEN** 声明长度小于 64 MiB 但大于本段剩余有效字节
- **THEN** 读取停止并记 ERROR，不跨段拼接、不读入下一段

#### Scenario: 跨段不拼接

- **WHEN** 当前段剩余空间不足以容纳「4 字节头 + 记录」
- **THEN** 先轮转，再在新段完整写入

## ADDED Requirements

### Requirement: 队列打开的原子性

`QueueManager.openTopic` SHALL 对同一主题的并发调用最多创建一组 `QueueLog`。实现 SHALL 用
「占位 + 发布」或等价机制保证：竞争失败的调用 MUST 关闭已创建的日志并清理本次新建的空段目录，
MUST NOT 泄漏文件描述符、mmap 或空段。打开过程中任一队列创建失败 SHALL 关闭本次已创建的队列，
保持 `QueueManager` 状态不变。

#### Scenario: 并发打开同一主题

- **WHEN** 8 个线程同时对同一主题调用 `openTopic`
- **THEN** 只存在一组 `QueueLog`，`allLogs()` 中该主题的队列数等于 owner 中本机队列数，
  目录中没有多余的空段

#### Scenario: 重复调用是空操作

- **WHEN** 已打开的主题再次 `openTopic`
- **THEN** 不新建段、不改变已有队列，返回成功

#### Scenario: 中途失败回滚

- **WHEN** 打开第 2 个队列时抛异常
- **THEN** 第 1 个队列被关闭，`topics` 中不留半成品；磁盘上不保留本次新建的段文件

### Requirement: 损坏记录与不可读记录的可观测性

读取链路遇到损坏段或不可读记录时 SHALL 留下可定位的痕迹：日志含主题、队列、段号、偏移与原因；
游标 SHALL 把「记录不可读」与「正常已决」区分开（独立计数器或日志标记），
MUST NOT 仅以 `decided = true` 静默跳过。同一位置的重复不可读 SHALL 限流记录，避免刷屏。

#### Scenario: 段被清理导致不可读

- **WHEN** 重投时 `readAt` 返回 `None`
- **THEN** 记 WARN（含位置），`decided = true`，并累加不可读计数

#### Scenario: 损坏段停止读取

- **WHEN** 读取中遇到非法长度头
- **THEN** 记 ERROR，本轮返回空，后续消费不崩溃；统计查询返回错误而不是 0

### Requirement: 读流恢复语义一致

「起始段缺失」在开流与读中两个阶段 SHALL 采用同一判定：所有段都不存在时视为空队列并返回
`None`（记 WARN）；仍存在其它段时跳到最近的后继段继续；段存在但读取抛错时 SHALL 继续抛出。
同一状态下 MUST NOT 出现「首次打开返回空、读到一半抛异常」的分歧。

#### Scenario: 开流时全段缺失

- **WHEN** `openRecordsFrom` 抛「段不存在」且当前无任何段
- **THEN** 返回 `None`，记 WARN

#### Scenario: 读中全段缺失

- **WHEN** 读到一半段被删除，且当前无任何段
- **THEN** 结束本轮并返回 `None`，不向调用方抛原始异常

#### Scenario: 段仍在但记录损坏

- **WHEN** 段文件存在，记录长度头非法
- **THEN** 抛出可识别的损坏异常（或按损坏停止），不得伪装成「段被删除」
