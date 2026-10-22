# fmq 消费语义（delta）

## ADDED Requirements

### Requirement: 跳过与不可读事件的统计暴露

游标在消费过程中累加的 `unreadableSkipped`、`noMatchSkipped`、`unsupportedSkipped` SHALL
通过生产可观测面暴露，MUST NOT 只存在于测试断言：

- `stats` 的 TSV 每行 SHALL 追加三列（顺序固定：不可读、无匹配、不支持），表头同步；
- `MQMetrics` SHALL 按 `(topic, group)` 维护对应计数器，并在删除主题/组时一并清理；
- 日志 SHALL 保留首次/汇总级别的 WARN/DEBUG，但日志不是唯一出口；
- 三个计数 SHALL 单调递增，进程重启后从 0 开始（不要求持久化），文档需说明这一点。

#### Scenario: stats 可见

- **WHEN** A 组越过了 1 条不可读记录与 2 条无匹配记录
- **THEN** `stats` 中 A 组行的三个新增列分别为 `1`、`2`、`0`

#### Scenario: 指标可见

- **WHEN** 同一组发生上述跳过
- **THEN** `MQMetrics` 对应计数器累加，`stats` 输出与指标一致

#### Scenario: 删除后清理

- **WHEN** 删除主题或组
- **THEN** 三个计数器被移除，再次查询不残留旧值

### Requirement: 关键场景的用例覆盖

以下场景 SHALL 各有一条**直接**用例，不得只用「等价路径」代替：

1. `GroupCursor` 层「段仍在但记录损坏」：不推进 `committed`、不标记已决、日志含段号/偏移；
2. 死信组间隔离：A 组进死信后，B 组仍能消费同一条消息；
3. 后加入的匹配订阅：已被越过的消息不可见，后续消息正常；
4. 已越过位置的 ACK：committed 之前、已进死信两种情形均不改变游标；
5. 中途失败回滚：`openTopic` 失败后磁盘上无残留主题目录/分配；
6. 并发投递：断言 `committed` 单调不减（不能只断言「比起始位置大」）；
7. 死信条目内容：原始字节、topic、queueIndex、组名、原位置、`deliverCount`、入死信时间全部断言；
8. 死信清理：断言具体被删段号与剩余段数（不能只断言 `removed >= 1`）；
9. 跨段写入：记录刚好放不下时整条写入新段，旧段有效长度不增加。

#### Scenario: 死信组间隔离

- **WHEN** 同一条消息在 A 组达到死信阈值
- **THEN** B 组仍可投递并确认该消息

#### Scenario: 并发单调

- **WHEN** 多线程并发投递与确认
- **THEN** 采样到的 `committed` 序列单调不减

#### Scenario: 已越过位置 ACK

- **WHEN** 对 `committed` 之前的位置发 ACK
- **THEN** 返回 `ACK_UNKNOWN`，游标不变

## MODIFIED Requirements

### Requirement: 离线组位点保留

订阅组离线（无在线消费者）或服务重启后，其持久化位点 SHALL 继续作为段保留的依据；
消费恢复时 SHALL 从该位点继续，MUST NOT 因为内存游标缺失而把位点前移到最老段。
若位点所在段确实已被删除，恢复语义 SHALL 与 `fmq/queue-storage` 完全一致：
**从编号更大的最近现存段起点继续，记 WARN（含原位置与实际起点），并把前移后的位点落盘**；
MUST NOT 回退到更老的段（那会重投已确认消息），MUST NOT 静默跳过而不留痕。
在游标尚未被消费路径修复前，`stats` 对该组 SHALL 返回错误（`INTERNAL`），
MUST NOT 用缺失后的起点计算出一个偏小的 `backlog` 并当作正常结果。
游标修复后，`stats` SHALL 恢复正常，并在新增的跳过计数列中保留「不可读」计数。

「跳到最老段」的表述 SHALL 从规格、README 与详细设计中删除，全仓只保留一套说法。

#### Scenario: 离线超过 TTL

- **WHEN** 组 G 的位点指向段 3，G 离线超过 TTL，清理器运行
- **THEN** 段 3 不被删除；G 重新上线后从段 3 继续消费

#### Scenario: 重启后恢复

- **WHEN** 服务重启，G 未重新订阅，清理器运行
- **THEN** 磁盘位点仍参与保留判定

#### Scenario: 位点段被删

- **WHEN** 运维手工删除了位点所在段，现存段为 7、8
- **THEN** 消费从段 7 起点继续并落盘，WARN 含原位置 `(旧段, offset)` 与 `(7, 0)`

#### Scenario: 修复前 stats 报错

- **WHEN** `committed` 指向已删段，且尚未发生下一次消费
- **THEN** `stats` 对该组返回 `INTERNAL`，不返回 `backlog = 0` 或偏小值

#### Scenario: 修复后 stats 恢复

- **WHEN** 消费路径已把 `committed` 前移到现存段
- **THEN** `stats` 返回该段之后的真实 backlog，不可读计数保留

### Requirement: 死信判定与按组隔离

`deadMsgThreshold` SHALL 表示**重试次数上限**：一条记录最多被投递 `deadMsgThreshold + 1` 次
（1 次首发 + `deadMsgThreshold` 次重投）。当记录已有 `deliverCount > deadMsgThreshold` 时，
下一次扫描 SHALL 把它写入死信队列并把该位置标记为已决，MUST NOT 再投递给消费者。
死信条目的 `deliverCount` SHALL 等于实际投递次数（`deadMsgThreshold + 1`）。
死信 SHALL 按组独立：A 组进死信不影响 B 组。

#### Scenario: 超过阈值进死信

- **WHEN** `deadMsgThreshold = 3`，同一位置被投递 4 次仍未确认
- **THEN** 第 5 次扫描把它写入死信，死信条目 `deliverCount = 4`，游标可继续推进

#### Scenario: 实际投递次数

- **WHEN** `deadMsgThreshold = 3`
- **THEN** 消费者共收到 4 次投递，`metrics.delivered` 计 4 次，第 5 次不再投递

#### Scenario: 组间隔离

- **WHEN** 同一条消息在 A 组已进死信
- **THEN** B 组仍可正常消费该条消息

#### Scenario: 死信条目内容完整

- **WHEN** 读取死信条目
- **THEN** 含原始记录字节、topic、queueIndex、组名、原位置、投递次数与入死信时间

### Requirement: 延迟投递

消息 SHALL 在 `publishTime + delaying <= now` 时才可投递；`delaying = 0` 时立即投递。
`publishTime` 无法解析时 SHALL 视为已到期并记 WARN。
`publishTime` 超前当前时刻 **5 分钟以上**时 SHALL 视为已到期并记 WARN：这是为兼容旧版本按本地
时区写入的 messageId（整体偏移一个时区）；该容差 SHALL 写入本规格与详细设计，
MUST NOT 只存在于代码注释中。超前不足 5 分钟的记录仍按正常延迟处理。

#### Scenario: 未到期不投递

- **WHEN** 记录发布时间为 10 秒前，`delaying = 1m`
- **THEN** 本轮不投递，`committed` 不前进

#### Scenario: 到期后投递

- **WHEN** 时钟前进至 `publishTime + delaying`
- **THEN** 记录可被投递

#### Scenario: 零延迟

- **WHEN** 主题 `delayingMs = 0`
- **THEN** 记录立即可投递

#### Scenario: 队首阻塞

- **WHEN** 队首记录未到期
- **THEN** 同队列后续记录不得越过队首投递

#### Scenario: 重启后仍延迟

- **WHEN** 未到期时重启
- **THEN** 重启后仍按原 `publishTime` 判断

#### Scenario: 非标准 messageId

- **WHEN** 记录的 messageId 不含 23 位时间戳
- **THEN** 视为已到期并投递，同时记录 WARN

#### Scenario: 未来时间容差

- **WHEN** `publishTime` 比当前时刻晚 10 分钟（旧版本本地时区 ID）
- **THEN** 视为已到期并投递，WARN 含「超前超过 5 分钟」

#### Scenario: 略超前不触发容差

- **WHEN** `publishTime` 比当前时刻晚 1 分钟，`delaying = 5m`
- **THEN** 不投递，等待到期
