# fmq 元数据与集群（delta）

## ADDED Requirements

### Requirement: 删除与接受的统一判定

主题分配与订阅组的「接受」判定 SHALL 把同 key 的墓碑当成一次带版本的变更参与比较，
MUST NOT 只看内存索引是否存在：

- 存在同 key 墓碑 `T` 时，到来的条目 `E` 只有在 `isNewer(E.revision, E.origin, T.revision, T.origin)`
  为真时才 SHALL 被接受（`revision` 大者胜；相同则 `origin` 大者胜）；
- 否则 SHALL 返回 `Tombstoned`（新增的 `MetaApplyResult` 分支），MUST NOT 写盘、MUST NOT 加入
  内存索引、MUST NOT 触发 `notifyTopicApplied`/队列打开；日志为 WARN（可限流，含 topic/group、
  条目 revision、墓碑 revision）；
- 接受更高版本的条目后，SHALL 删除同 key 的墓碑（内存与磁盘），即「墓碑被更高 revision 覆盖」；
  删除失败 SHALL 记 ERROR 并保留墓碑，下一次加载/同步继续收敛。

`registerTopic` 与 `registerGroup` SHALL 在同一个临界区内为新条目分配**严格大于**同 key 墓碑
revision 的 revision，并在写入成功后删除该墓碑。重新注册成功后 `topicTombstone(topic)` SHALL
返回 `None`，快照 MUST NOT 再携带该墓碑。

该判定 SHALL 同时作用于：本地注册、`applyTopic`/`applyGroup`（广播）、`mergeSnapshot`
（全量快照）、`load()`（重启加载 / 崩溃收敛）。

#### Scenario: 迟到的低版本主题不复活

- **WHEN** `/t` 的墓碑 `revision = 7`，随后收到 `revision = 2` 的 `/t` 分配（广播或快照）
- **THEN** 返回 `Tombstoned`，`topicOf("/t")` 仍为空，磁盘 `topics/` 不出现该文件，队列不打开

#### Scenario: 迟到的低版本组不复活

- **WHEN** 组 `(topic, g)` 的墓碑 `revision = 7`，随后收到 `revision = 2` 的组注册
- **THEN** 返回 `Tombstoned`，`groupExists` 仍为假，不写盘

#### Scenario: 同 revision 不同 origin

- **WHEN** 墓碑 `(rev 5, origin 2)`，到来条目 `(rev 5, origin 3)`
- **THEN** 条目被接受（origin 更大），墓碑被移除

#### Scenario: 同 revision 同 origin

- **WHEN** 墓碑与条目 `revision`、`origin` 都相同
- **THEN** 返回 `Tombstoned`（删除优先，避免同事件自我复活），状态不变

#### Scenario: 重新注册覆盖墓碑

- **WHEN** `/t` 被删除（墓碑 rev 7）后通过 `registerTopic` 重新注册
- **THEN** 新分配 revision > 7，墓碑从内存与磁盘移除，`topicTombstone("/t")` 为 `None`，
  后续快照不含该墓碑

#### Scenario: 快照不再复活已删条目

- **WHEN** 本地墓碑 `rev 9`，对端快照仍含 `/t` 的 `rev 3` 条目
- **THEN** 合并后 `topicOf("/t")` 仍为空，且不触发 `openTopic`

### Requirement: 墓碑竞争的原子性

`applyTombstone` SHALL 只在墓碑赢下版本比较时改变本地状态：
「赢」定义为 `isNewer(tombstone.revision, tombstone.origin, local.revision, local.origin)`。
墓碑输掉比较时 SHALL 只返回 `Duplicated`，MUST NOT 写墓碑、MUST NOT 删除本地条目、
MUST NOT 触发删除回调（队列目录、游标、订阅、指标均不得清理）。
墓碑与本地条目 `revision` 相同但 `origin` 更小时属于「输掉」，MUST NOT 因
`local.revision <= tombstone.revision` 这类只看 revision 的条件删除条目。

删除条目与写墓碑 SHALL 在同一临界区内完成；任一步失败 SHALL 保持「条目与墓碑至少一个可解释」
的状态，并在下一次加载时收敛（见「加载期墓碑收敛」）。

#### Scenario: 输掉的墓碑不删条目

- **WHEN** 本地组 `(rev 5, origin 9)`，收到组墓碑 `(rev 5, origin 2)`
- **THEN** 返回 `Duplicated`，组仍在，无删除回调，无队列/游标清理

#### Scenario: 赢下的墓碑删除条目

- **WHEN** 本地组 `(rev 4, origin 9)`，收到组墓碑 `(rev 5, origin 2)`
- **THEN** 返回 `Applied`，组被删除，回调清理队列与游标

#### Scenario: 并发注册与删除同 revision

- **WHEN** 节点 A 以 `(rev 6, origin 1)` 注册，节点 B 以 `(rev 6, origin 2)` 删除
- **THEN** 两个节点最终都是删除态（origin 大者胜），不会出现「A 活着、B 已删且无墓碑」

#### Scenario: 墓碑重复到达

- **WHEN** 同一墓碑第二次到达
- **THEN** 返回 `Duplicated`，不重复删除、不重复写盘

### Requirement: 快照字段与合并逻辑对齐

`MQMetaSnapshot` 的每个字段 SHALL 至少被一个生产逻辑读取（合并、清理、保留判定或对外输出）。
`tombstoneFloor` 若在合并、GC 与保留判定中都没有消费者，SHALL 从载荷类删除，
并同步删除其计算、序列化与测试断言；`MQMetaSnapshot` 仍 SHALL 携带 `tombstones` 与 `revision`。
`MQSubscribeGroupMeta` SHALL 携带 `revision` 与 `origin`，组变更广播 MUST NOT 丢失这两个字段。

#### Scenario: 快照字段都有消费者

- **WHEN** 检索快照字段的读取点
- **THEN** `topics`/`groups`/`tombstones`/`revision` 均有生产读取方，`tombstoneFloor` 已不存在

#### Scenario: 组元数据版本字段

- **WHEN** 组注册后经快照合并到对端
- **THEN** 对端组的 `revision`/`origin` 与本端一致，后续墓碑比较使用同一对值

### Requirement: 集群侧的受支持面

集群代码 SHALL 只保留有生产路径或明确观测用途的符号：

- `pendingPeers` 只累加/清空、从不参与选点、指标或日志，SHALL 删除；反熵 SHALL 直接尝试全部
  可达 peer（已由 `NodeRegistry` 提供存活判定）。
- `MetaApplyResult.Conflict` 对组不可达（`applyGroup` 只返回 `Applied/Duplicated/TopicMissing/
  Invalid/Tombstoned`），该 match 分支 SHALL 删除；若需要组冲突语义，SHALL 先补规格与用例。
- `BackupReplicator.flush()` 与 `flushOnce()` 重复，SHALL 只保留一个生产入口。
- `MQAssignment.ownersOf`、`NodeRegistry.nodeAt`/`indexOf` 若无生产调用方，SHALL 下沉到测试
  工具（`fmq/src/test/`）或删除；MUST NOT 继续在详细设计中列为生产 API。
- `LogCleaner.start(now!)` 的 `now` 注入参数若无调用方传值，SHALL 删除或改为可注入时钟的构造参数
  （后者需有生产装配点）。

#### Scenario: 不可达分支消失

- **WHEN** 对 `MetaApplyResult` 做穷尽 match
- **THEN** 不存在永不执行的组 `Conflict` 分支

#### Scenario: 观测 API 有消费者

- **WHEN** 检查 `pendingCount`/`pendingPeerCount` 这类观测方法
- **THEN** 或被生产日志/指标使用，或已删除；保留时必须有用例与文档说明

## MODIFIED Requirements

### Requirement: 元数据持久化与内存索引

`MetaStore` SHALL 在启动时加载全部主题、订阅组、墓碑与轮转指针；对外提供按主题查询分配、
按主题列出组、判断组是否存在、读取下一个起始下标与生成全量快照。
注册主题与注册组 SHALL 由 `MetaStore` 在**同一临界区**内完成「存在性检查 → 墓碑比较 →
分配计算 → 落盘 → 推进指针 → 移除被覆盖的墓碑」，并向调用方返回实际落盘的结果；
调用方 MUST NOT 在锁外自行预检查后再写入。
重复注册 SHALL 返回「已存在」且不改变已有内容。
加载时 SHALL 校验主题分配的结构（见「远端元数据结构校验」），并 SHALL 丢弃没有对应主题的孤儿组
（记 ERROR），MUST NOT 将其纳入索引或快照。

加载完成后 SHALL 执行一次**墓碑收敛**：对每个已落盘墓碑，若本地存在同 key 条目且墓碑赢下
`isNewer` 比较，SHALL 删除该条目（内存 + 磁盘）并记 WARN；若条目更新，SHALL 删除该墓碑
（视为已复活）。收敛 SHALL 幂等，MUST NOT 因某一条目的删除失败而中断其余条目。
这保证「先写墓碑、后删文件」之间崩溃或删除失败时，重启不会把已删条目重新载入。

#### Scenario: 重建后一致

- **WHEN** 注册主题与组后关闭并重开 `MetaStore`
- **THEN** `topicOf` / `groupsOf` / `nextStartNode` 与关闭前一致

#### Scenario: 重复注册

- **WHEN** 对同一主题再次 apply
- **THEN** 返回 duplicated，已有 owners 与 queueNum 不变

#### Scenario: 并发注册同一主题

- **WHEN** 多线程同时注册同一主题
- **THEN** 只有一个成功，其余返回 duplicated，只产生一份分配

#### Scenario: 并发注册不同主题

- **WHEN** 多线程注册不同主题
- **THEN** 每个主题都落盘，`nextStart` 单调推进

#### Scenario: 默认组存在性

- **WHEN** 主题注册后查询默认组
- **THEN** 默认组按规格存在/不存在

#### Scenario: 删除主题级联

- **WHEN** 删除带组与队列的主题
- **THEN** 主题、组、队列目录与游标被清理

#### Scenario: 孤儿组不进入索引

- **WHEN** 磁盘上存在无主题的组文件
- **THEN** 加载时丢弃并记 ERROR

#### Scenario: 快照内容完整

- **WHEN** 生成快照
- **THEN** 含 topics、groups、tombstones、revision，且不含 `tombstoneFloor`

#### Scenario: 损坏文件跳过

- **WHEN** 某个 `.meta` 文件损坏
- **THEN** 跳过该条目并记 ERROR，其余条目正常加载

#### Scenario: 崩溃窗口后不复活

- **WHEN** 墓碑已落盘、条目文件尚未删除时进程退出，重启加载
- **THEN** 收敛阶段删除该条目，`topicOf` 为空，且墓碑仍在

#### Scenario: 复活后清除墓碑

- **WHEN** 磁盘上条目 `rev 8` 与墓碑 `rev 5` 同时存在，重启加载
- **THEN** 墓碑被删除，条目保留

### Requirement: 元数据全量复制

`MetaSyncer` SHALL 支持全量快照合并：先应用墓碑，再应用主题与组，最后对「本地更旧且快照缺失」
的条目做删除兜底。合并 SHALL 满足：

1. 畸形条目（结构校验失败）SHALL 只记 WARN 并跳过，MUST NOT 进入「已验证 key 集合」，
   也 MUST NOT 被后续缺失扫描当作「对端已删除」；本地同 key 条目 SHALL 保持不变。
2. 缺失扫描 SHALL 只考虑「快照中有效出现的 key 的补集」，且必须排除：带有本地墓碑的 key、
   被墓碑挡下的 key、畸形跳过的 key。
3. 删除兜底 SHALL 仍受 `revision <= snapshot.revision` 约束；快照 `revision <= 0` 时 MUST NOT 删除。
4. 应用条目后被墓碑挡下（`Tombstoned`）SHALL 记 WARN，MUST NOT 触发主题打开或删除回调。

#### Scenario: 注册后各节点一致

- **WHEN** 节点 A 注册主题并广播
- **THEN** 其它节点最终一致

#### Scenario: 重复应用幂等且不转发

- **WHEN** 同一变更应用两次
- **THEN** 第二次返回 duplicated，不重复广播

#### Scenario: 冲突保留先到者

- **WHEN** 同 revision 同 origin 但内容不同
- **THEN** 保留先到者并记 WARN

#### Scenario: 注销复制

- **WHEN** 节点删除主题
- **THEN** 其它节点收到墓碑并删除

#### Scenario: 离线节点重启后删除仍生效

- **WHEN** 离线节点重启后拉取快照
- **THEN** 已删主题不会复活

#### Scenario: 乱序广播

- **WHEN** 先收 rev 5 再收 rev 3
- **THEN** rev 3 被忽略

#### Scenario: 畸形条目不清空本地

- **WHEN** 本地有合法 `/t`，对端快照含一个畸形 `/t` 条目（`owners` 越界）
- **THEN** 本地 `/t` 保留，无删除回调，日志有 WARN

#### Scenario: 畸形组不影响主题

- **WHEN** 快照含非法组名
- **THEN** 只跳过该组，同快照的合法主题与组照常应用

#### Scenario: 墓碑挡下的条目不算缺失

- **WHEN** 快照含 `/t` 的 rev 3，本地墓碑 rev 9
- **THEN** 条目被拒绝，缺失扫描不清除任何东西，也不重新打开队列

### Requirement: 远端元数据结构校验

任何来自网络或磁盘的 `MQTopicAssignment` SHALL 在应用前校验：`topic` 合法、`queueNum >= 1`、
`owners.size == queueNum`、每个 owner 在 `[0, nodeCount)`、`startNodeIndex` 在 `[0, nodeCount)`、
`delayingMs >= 0`、`revision >= 0`、`origin` 在 `[0, nodeCount)`。
校验失败 SHALL 返回 `Invalid`，记 WARN（含主题与**失败字段名/实际值/允许范围**），
MUST NOT 写入 `topics/` 或内存索引。
`MQSubscribeGroupMeta` SHALL 校验主题存在、组名合法；校验失败 SHALL 返回 `Invalid` 并记 WARN
（含主题、组名与失败字段），MUST NOT 静默返回；主题不存在时 SHALL 进入待应用队列，
在主题到达后重试，MUST NOT 直接落盘为孤儿组。

#### Scenario: owners 与 queueNum 不一致

- **WHEN** 收到 `queueNum = 4`、`owners = [0,1]` 的分配
- **THEN** 返回 `Invalid`，本地状态不变，WARN 含 `owners`

#### Scenario: owner 越界

- **WHEN** `owners` 含 `nodeCount` 或负数
- **THEN** 返回 `Invalid`，WARN 含越界值与 `nodeCount`

#### Scenario: 非法组名有 WARN

- **WHEN** 收到组名含 `%` 或超过 255 字节的组注册
- **THEN** 返回 `Invalid`，WARN 含 `subscribeGroup` 与失败原因，不写盘

#### Scenario: 组先于主题到达

- **WHEN** 节点先收到 `/new` 的组注册，后收到 `/new` 的主题分配
- **THEN** 组进入待应用队列；主题落地后自动应用，最终 `groupExists("/new", g)` 为真

#### Scenario: 主题已删除后组到达

- **WHEN** 收到一个已被墓碑删除主题的组注册
- **THEN** 组被拒绝（记 WARN），不产生孤儿组

### Requirement: 备份副本复制

备份副本 SHALL 由发布路径入队、独立工作线程批量发送；发布路径 MUST NOT 同步发送。
一批数据发往多个 target 时，发送结果 SHALL 按 target 记录：

- 任一 target 成功、另一个失败时，MUST NOT 丢弃失败 target 的记录；失败 target SHALL 在本批
  重试时被继续尝试，已成功的 target MUST NOT 重复投递同一批（避免无限重复）。
- 全部 target 成功后才从待发队列移除；重试次数上限仍为 3，超过 SHALL 记 ERROR 并丢弃。
- 备份队列满、关闭后到达的写入 SHALL 记 WARN（限流）并丢弃，不阻塞发布。

`close()` SHALL：停止定时器 → 置关闭标志 → 等待工作线程结束**当前批次**（等待时长 SHALL
覆盖一次发送超时上限，不得用固定 500ms 截断）→ 执行最后一次 `flushOnce()`。
关闭完成后若仍有未发送条目，SHALL 记 ERROR 并打印条数；MUST NOT 静默留在内存。
关闭期间失败而需要重新入队的批次 SHALL 被丢弃并记 ERROR，MUST NOT 入队等一个已不存在的工作线程。

#### Scenario: 目标为环形后继

- **WHEN** `backup = 2`、节点数 4
- **THEN** 副本发往两个环形后继

#### Scenario: backup 为 0

- **WHEN** `backup = 0`
- **THEN** 不发送，入队调用只记 WARN（限流）

#### Scenario: 按条数或时间 flush

- **WHEN** 累积 64 条或最早条目等待 100ms
- **THEN** 触发一次发送

#### Scenario: 定时器到期刷写

- **WHEN** 工作线程轮询到应刷写
- **THEN** 调用 `flushOnce`，异常不外溢

#### Scenario: 慢后继不阻塞发布

- **WHEN** 某个后继很慢
- **THEN** 发布调用在毫秒级返回，发送在工作线程内完成

#### Scenario: 发送失败重试

- **WHEN** 全部 target 发送失败
- **THEN** 整批回队，`attempts` 递增，最多 3 次

#### Scenario: 部分 target 失败

- **WHEN** target A 成功、target B 失败
- **THEN** 只把 B 作为剩余目标重试，A 不重复收到同一批；B 恢复后补齐副本

#### Scenario: 关闭排空

- **WHEN** 工作线程正在发送时调用 `close()`
- **THEN** `close()` 等到该批次结束，再 drain 一次；`pendingCount == 0`，无 ERROR

#### Scenario: 关闭超时留痕

- **WHEN** 发送耗时超过关闭等待上限
- **THEN** 记录 ERROR（含剩余条数），不静默丢弃

#### Scenario: 队列满不阻塞

- **WHEN** 待发队列达到容量
- **THEN** 新记录被丢弃并 WARN（限流），发布仍成功

#### Scenario: 副本不参与消费

- **WHEN** 收到 `PUBLISH(backup)`
- **THEN** 只落备份存储，不进入本机队列

#### Scenario: 单节点故障不影响其它

- **WHEN** 一个 target 不可达
- **THEN** 其它 target 仍收到副本

#### Scenario: 关闭后写入有痕迹

- **WHEN** `BackupReplicator` 关闭后调用 `record`
- **THEN** WARN（限流）含 topic/位置，不静默返回

### Requirement: 备份副本的消费位点

`MQBackupPayload` SHALL 携带每个 `(topic, queueIndex)` 的订阅组位点
`{group, segmentedIndex, segmentedOffset}`，以及每条记录的 `deliverCount` 与 `acked`。
生产端 SHALL 在 flush 时从游标服务读取当前 `committed` 生成位点；`acked` SHALL 由
「记录位置早于该组 committed」推导，不得硬编码为 false；无组时 `acked` 视为 false；
多组时取「所有组 committed 的最小值」作为判定边界。
接收端 SHALL 把位点写入备份目录下的 `cursors/<groupEsc>.cursor`，并 SHALL 校验每条记录的
投递状态数量（`states`）与记录数量一致（位点按订阅组计，与记录条数不成比例，因此只校验状态）。
数量不一致 SHALL 记 WARN（含期望/实际条数），仍落盘记录，但 MUST NOT 更新位点。
同一位点重复到达 SHALL 幂等；位点回退 MUST NOT 覆盖更大的已存位点。

验证该 Requirement 的用例 MUST NOT 只用「固定返回值的状态桩」证明载荷透传：
SHALL 至少有一条用例装配真实 `ConsumeService`（或等价真实游标源）验证 `backupStates`/
`backupCursors`/`ackedByAll` 的推导，覆盖「无组」「多组取最小 committed」「边界位置等于
committed 时不算已确认」。

#### Scenario: 状态随备份落地

- **WHEN** 组已确认前 3 条，随后 flush 备份 5 条
- **THEN** 载荷中前 3 条 `acked = true`，位点文件中 committed 指向第 4 条，接收端可读回

#### Scenario: 备份位点可用于重建游标

- **WHEN** 从备份目录读回该组的位点文件，并写入 `CursorStore`
- **THEN** `CursorCatalog.positionOf` 返回该位点（`committed` 等于备份位点），不依赖内存状态

#### Scenario: 位点不回退

- **WHEN** 旧批次（位点更小）晚于新批次到达
- **THEN** 已存位点保持不变，记录 WARN

#### Scenario: 记录与状态数量不一致

- **WHEN** `states` 数量与记录数不匹配
- **THEN** 接收端记 WARN（含期望/实际），仍落盘记录，但不更新位点；未更新可通过读回位点断言

#### Scenario: 真实状态来源

- **WHEN** 组 G 的 committed 指向第 4 条，flush 该队列前 5 条
- **THEN** `backupStates` 对前 3 条返回 `acked = true`、第 4、5 条为 false，`deliverCount` 与游标一致

#### Scenario: 多组取最小

- **WHEN** 同队列有 A、B 两组，A committed 在第 5 条、B 在第 2 条
- **THEN** 前 1 条对两组都已确认（`acked = true`），第 2 条及以后为 false

#### Scenario: 无组

- **WHEN** 队列没有任何订阅组位点
- **THEN** 所有 `acked = false`，`cursors` 为空数组

### Requirement: 清理器异常隔离

`LogCleaner.cleanOnce` SHALL 对每个主题、队列、段的删除操作做独立异常隔离：
单个段删除失败 SHALL 记 ERROR（含主题、队列、段号），并继续删除同队列的其它段与其它队列；
单个主题/队列级失败 SHALL 同样记 ERROR 并继续。
一轮结束 SHALL 汇总「删除数 / 失败数」，作为一条 INFO/WARN 日志输出；
定时器回调 SHALL 捕获异常，MUST NOT 因单次失败终止后续轮次。
死信清理 SHALL 独立于普通队列清理：普通队列失败时死信清理仍 SHALL 执行。

#### Scenario: 单段删除失败

- **WHEN** 某段的 `removeById` 抛异常，其它段可删除
- **THEN** 同队列其它段仍被删除，日志有该段 ERROR（含主题/队列/段号），失败数计入汇总

#### Scenario: 死信清理继续

- **WHEN** 普通队列某段删除失败
- **THEN** `deadLetter.cleanExpired` 仍被调用，死信段被清理

#### Scenario: 定时器不中断

- **WHEN** 一轮 `cleanOnce` 抛出未预期异常
- **THEN** 定时器记录 ERROR，下一轮仍会执行

#### Scenario: 失败可定位

- **WHEN** 检查一轮清理后的日志
- **THEN** 既有逐对象 ERROR，也有「removed N / failed M」汇总行
