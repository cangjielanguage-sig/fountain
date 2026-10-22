# fmq 元数据与集群（delta）

## MODIFIED Requirements

### Requirement: 元数据目录与原子写

元数据 SHALL 存放在 `<fmq 可执行目录>/metas/`，布局为：

```
metas/assign.meta
metas/topics/<topicEsc>.meta
metas/groups/<topicEsc>/<groupEsc>.meta
metas/tombstones/t_<topicEsc>.meta            # 主题墓碑
metas/tombstones/g_<topicEsc>_<groupEsc>.meta # 组墓碑
metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
```

文件名 SHALL 使用可逆、无碰撞的百分号编码（仅保留 `[A-Za-z0-9._-]`，空串编码为 `%00`）。
写入 SHALL 先写 `<file>.tmp`，对文件执行 `flush` 与 `fsync` 后再 rename 覆盖；rename 后 SHALL 对
父目录执行 `fsync`。任一 fsync 失败 SHALL 记 ERROR 并向上抛错，MUST NOT 以「已 rename」视为成功。

#### Scenario: 路径布局

- **WHEN** 为 `/order` 的默认组生成路径
- **THEN** 组文件为 `groups/%2Forder/%00.meta`，主题文件为 `topics/%2Forder.meta`

#### Scenario: 编码无碰撞

- **WHEN** 分别编码 `/a_b` 与 `/a/b`
- **THEN** 两者结果不同，且都能解码回原名

#### Scenario: 原子写

- **WHEN** 写入前目录里已有同名的 `.tmp` 残留
- **THEN** 正式元数据文件仍完整可读，不被半截内容污染

#### Scenario: 掉电后不为空文件

- **WHEN** 在写入完成后模拟掉电（flushed + fsynced + renamed）
- **THEN** 重新加载得到的元数据内容完整，不存在「文件存在但长度为 0」的状态

### Requirement: 元数据持久化与内存索引

`MetaStore` SHALL 在启动时加载全部主题、订阅组、墓碑与轮转指针；对外提供按主题查询分配、
按主题列出组、判断组是否存在、读取下一个起始下标与生成全量快照。
注册主题与注册组 SHALL 由 `MetaStore` 在**同一临界区**内完成「存在性检查 → 分配计算 → 落盘 →
推进指针」，并向调用方返回实际落盘的结果；调用方 MUST NOT 在锁外自行预检查后再写入。
重复注册 SHALL 返回「已存在」且不改变已有内容。
加载时 SHALL 校验主题分配的结构（见「远端元数据结构校验」），并 SHALL 丢弃没有对应主题的孤儿组
（记 ERROR），MUST NOT 将其纳入索引或快照。

#### Scenario: 重建后一致

- **WHEN** 注册主题与组后关闭并重开 `MetaStore`
- **THEN** `topicOf` / `groupsOf` / `nextStartNode` 与关闭前一致

#### Scenario: 重复注册

- **WHEN** 对同一主题再次 apply
- **THEN** 返回 duplicated，已有 owners 与 queueNum 不变

#### Scenario: 并发注册同一主题

- **WHEN** 8 个线程同时对 `/t` 调用注册
- **THEN** 恰好一个返回 applied，其余返回 duplicated；落盘分配与唯一成功者返回值一致

#### Scenario: 并发注册不同主题

- **WHEN** 两个线程同时注册 `/a` 与 `/b`
- **THEN** 两次分配的 `startNodeIndex` 不重复，`nextStartNode` 等于两次推进后的值

#### Scenario: 默认组存在性

- **WHEN** 已注册默认组 `""`
- **THEN** `groupExists(topic, "")` 为真

#### Scenario: 删除主题级联

- **WHEN** 删除某主题
- **THEN** 该主题下的所有订阅组元数据一并消失

#### Scenario: 孤儿组不进入索引

- **WHEN** `groups/` 下存在 `topic="/gone"` 的组文件，但 `topics/` 下没有 `/gone`
- **THEN** `load()` 记 ERROR 并忽略该组，`groupsOf("/gone")` 为空，快照不含它

#### Scenario: 快照内容完整

- **WHEN** 调用 `snapshot()`
- **THEN** 返回全部主题分配、全部订阅组、墓碑与当前轮转指针

#### Scenario: 损坏文件跳过

- **WHEN** metas 目录里存在无法解码的文件
- **THEN** `load()` 不抛异常，跳过该条并记 ERROR，其余元数据可用

### Requirement: 元数据全量复制

每个节点 SHALL 保存全部主题与订阅组元数据。注册/注销 SHALL 先本地落盘（含版本与墓碑），再广播给
其它所有节点，最后回响应；广播使用 `MQInternalMessage{kind: "metaSync"}` 承载，不新增协议命令。
接收方 SHALL 按 `(revision, origin)` 比较新旧：更高版本覆盖（包括删除），相同版本且内容不同时保留
先到者并记 WARN，更低版本直接忽略。删除 MUST 以墓碑传播，MUST NOT 依赖「本地有、对端无」的推断。
广播失败的节点 SHALL 进入待补偿集合并记 WARN；节点恢复或反熵周期到达时 SHALL 用快照让对端收敛。

#### Scenario: 注册后各节点一致

- **WHEN** 节点 X 收到主题注册
- **THEN** X 本地落盘后，每个可达 peer 都收到同一份 `MQTopicAssignment`，内容与 X 完全一致

#### Scenario: 重复应用幂等且不转发

- **WHEN** 同一份变更被应用两次
- **THEN** 第二次返回 duplicated，且不会再次广播（防止广播环）

#### Scenario: 冲突保留先到者

- **WHEN** 两个节点对同一主题给出相同 revision 但不同 owners
- **THEN** 保留先到者，返回 conflict 并记 WARN，不覆盖已有分配

#### Scenario: 注销复制

- **WHEN** 节点收到主题/组注销
- **THEN** 本地写入同一 revision 的墓碑、删除对应元数据与相关订阅/游标，并向 peer 广播墓碑

#### Scenario: 离线节点重启后删除仍生效

- **WHEN** 节点 X 离线期间 `/t` 被删除；X 重启并拉取快照
- **THEN** X 应用墓碑并删除 `/t`，MUST NOT 继续为该主题打开队列或接受发布

#### Scenario: 乱序广播

- **WHEN** X 先收到 `/b`（revision 5）再收到 `/a`（revision 3）
- **THEN** X 分别按各自 revision 应用；`nextStartNode` 取两者推进结果的最大值，不回退

### Requirement: 启动期与恢复期同步

节点启动时 SHALL 向可达 peer 请求全量快照并合并（新增、更新、删除一并应用）；
当全部 peer 不可达时 SHALL 保留本地元数据继续启动并记 WARN，不得因此拒绝启动。
由死转活时 SHALL 触发一次重同步；重同步与远端应用每落地一个本地缺失的主题，SHALL 打开该主题的
本机队列。系统 SHALL 周期性（默认 30s，可配置）向随机 peer 做一次反熵同步，使广播失败与删除
最终收敛，不得只依赖「下一次成功发送」。

#### Scenario: 补齐缺失

- **WHEN** 本地为空，peer 快照含 2 个主题与 1 个组
- **THEN** 全部补齐，`nextStartNode` 取较大值

#### Scenario: 全部不可达

- **WHEN** 所有 peer 都连不上
- **THEN** 服务仍启动，使用本地元数据，日志有 WARN

#### Scenario: 复活后打开新主题队列

- **WHEN** 节点 X 离线期间 `/new` 被注册且 X 是部分队列 owner；X 复活同步到 `/new`
- **THEN** `QueueManager` 打开 X 名下的 `/new` 队列，随后对该主题的发布/订阅不再回 `NOT_OWNER`

#### Scenario: 反熵补删除

- **WHEN** 一次删除广播失败，随后反熵周期到达
- **THEN** 对端在下一次同步后删除该主题/组，并记 INFO

#### Scenario: 告警文案准确

- **WHEN** peer 可达但返回错误或快照无法解码
- **THEN** 日志区分「不可达」与「响应不可用（错误码/解码失败）」，不得统一记为 no peer reachable

### Requirement: 备份副本复制

当 `mqServer_backup > 0` 时，发布成功后 SHALL 把记录与其**真实状态**异步推送给环形后续的
`backup` 个节点；接收方 SHALL 落盘副本与对应消费位点，不投递、不再次备份。
批量 SHALL 在「累积 64 条」或「距上次 100ms」时触发；发送 MUST 在独立工作线程执行，`record()`
只做入队并立即返回。队列有界，溢出时 SHALL 丢弃并记 WARN，不得阻塞发布。
发送失败 SHALL 把批次重新入队并按上限重试；超过重试次数或队列已满时 SHALL 丢弃并记 ERROR。
关闭时 SHALL 停止定时器、停止工作线程并做最后一次 flush，把已入队未发送的记录全部发出。
关闭阶段或 `backup <= 0` 时到达的写入 SHALL 被丢弃并记 WARN（限流，避免刷屏）。
备份段 SHALL 纳入 TTL 清理，保留边界由备份位点决定。

#### Scenario: 目标为环形后继

- **WHEN** self = 0、节点数 3、backup = 2
- **THEN** 只向节点 1、2 发送

#### Scenario: backup 为 0

- **WHEN** `mqServer_backup = 0`
- **THEN** 不发送任何备份消息

#### Scenario: 按条数或时间 flush

- **WHEN** 累积到 64 条，或注入时钟前进 100ms
- **THEN** 各触发一次发送，载荷记录条数正确

#### Scenario: 定时器到期刷写

- **WHEN** 只记录 1 条，未达到 64 条，等待超过 100ms
- **THEN** 定时器触发发送，该条记录出现在载荷中

#### Scenario: 慢后继不阻塞发布

- **WHEN** 后继节点的发送阻塞 5s，持续发布 200 条
- **THEN** 每次 `publish` 在 50ms 内返回，备份在后台排队/发送

#### Scenario: 发送失败重试

- **WHEN** 首次发送到节点 1 失败
- **THEN** 该批次重新入队，恢复后再次发送成功，记录不丢

#### Scenario: 关闭排空

- **WHEN** 队列中仍有未发送记录时调用关闭
- **THEN** 关闭前做最后一次 flush，记录全部发出，定时器与工作线程停止

#### Scenario: 队列满不阻塞

- **WHEN** 备份队列达到上限
- **THEN** 新记录被丢弃并记 WARN，发布调用立即返回

#### Scenario: 副本不参与消费

- **WHEN** 接收方收到备份消息
- **THEN** 只写入备份目录与备份位点，本队列与订阅表均无变化

#### Scenario: 单节点故障不影响其它

- **WHEN** 后继节点 1 不可达、节点 2 可达
- **THEN** 节点 2 仍收到副本

#### Scenario: 关闭后写入有痕迹

- **WHEN** `record()` 在关闭后或 `backup <= 0` 时被调用
- **THEN** 不抛异常，丢弃并记 WARN（限流），文案包含原因

### Requirement: 节点表与身份

服务端 SHALL 从 `mqClient_hosts` 读取节点表（顺序即下标），并 SHALL 用 `mqServer_port`
与表中某项的端口匹配来确定本机下标。端口在表中不存在或出现重复端口时 SHALL 拒绝启动。
节点间 SHALL 复用 `f_net` 客户端内建心跳完成探活与重连；连接被对端关闭后 SHALL 重建，
MUST NOT 永久保留已关闭的 `Client`。
存活标记初值 SHALL 为「未知/不存活」，只有成功交互一次后才置为存活；`isAlive` SHALL 参与
广播跳过、反熵选点或指标中的至少一处决策。

#### Scenario: 按端口定位自身

- **WHEN** 节点表为 `h1:2350,h2:2351`，`port = 2351`
- **THEN** `selfIndex == 1`

#### Scenario: 自身不在表中

- **WHEN** 端口不在节点表
- **THEN** 启动失败并打印原因

#### Scenario: 端口重复

- **WHEN** 节点表中有两项端口相同
- **THEN** 启动失败并打印原因

#### Scenario: 环形后继

- **WHEN** 节点数 3、self = 2、backup = 2
- **THEN** 后继为 `[0,1]`

#### Scenario: 不与自身建连

- **WHEN** 请求本机下标的客户端
- **THEN** 返回 `None`

#### Scenario: 对端重启后重连

- **WHEN** 某 peer 的 `Client` 因心跳失败自行关闭，随后 peer 恢复
- **THEN** 下一次发送重建连接并成功，`isAlive` 从 false 转为 true 并触发一次重同步

#### Scenario: 从未连上的 peer

- **WHEN** 启动后尚未与某 peer 成功交互
- **THEN** `isAlive` 为 false；第一次成功时不重复触发多余的「由死转活」同步

## ADDED Requirements

### Requirement: 元数据版本与墓碑

主题分配、订阅组与墓碑 SHALL 携带 `revision: Int64` 与 `origin: Int64`（产生变更的节点下标）。
本地变更的 `revision` SHALL 大于本节点已见过的最大 revision；比较规则为
「revision 大者胜，revision 相同则 origin 大者胜，二者相同且内容不同则保留先到者并记 WARN」。
删除主题 SHALL 写入主题墓碑并级联写入其全部组墓碑；删除组 SHALL 写入组墓碑。
墓碑 SHALL 持久化、参与快照、参与广播，并在 `mqServer_tombstoneTTL`（默认 7d）后由清理器回收。
回收 MUST NOT 发生在墓碑年龄小于 TTL 时；运维文档 SHALL 说明「离线超过 TTL 的节点需要全量重建」。

#### Scenario: 墓碑往返

- **WHEN** 写入主题墓碑后重建 `MetaStore`
- **THEN** 墓碑仍存在，`topicOf` 为空，快照包含该墓碑

#### Scenario: 旧节点删除不复活

- **WHEN** 节点 A 删除 `/t`，节点 B 的本地仍有 `/t` 且 revision 更低
- **THEN** B 应用墓碑后删除 `/t`

#### Scenario: 新注册覆盖墓碑

- **WHEN** `/t` 被删除后以更高 revision 重新注册
- **THEN** 墓碑被移除或标记为已复活，`topicOf("/t")` 返回新分配

#### Scenario: 墓碑未过期不回收

- **WHEN** 清理器运行且墓碑年龄小于 TTL
- **THEN** 墓碑保留

#### Scenario: 墓碑过期回收

- **WHEN** 墓碑年龄超过 TTL 且无同主题活跃元数据
- **THEN** 墓碑被删除并记 INFO

### Requirement: 远端元数据结构校验

任何来自网络或磁盘的 `MQTopicAssignment` SHALL 在应用前校验：`topic` 合法、`queueNum >= 1`、
`owners.size == queueNum`、每个 owner 在 `[0, nodeCount)`、`startNodeIndex` 在 `[0, nodeCount)`、
`delayingMs >= 0`、`revision >= 0`、`origin` 在 `[0, nodeCount)`。
校验失败 SHALL 返回 `Invalid`，记 WARN（含主题与失败字段），MUST NOT 写入 `topics/` 或内存索引。
`MQSubscribeGroupMeta` SHALL 校验主题存在、组名合法；主题不存在时 SHALL 进入待应用队列，
在主题到达后重试，MUST NOT 直接落盘为孤儿组。

#### Scenario: owners 与 queueNum 不一致

- **WHEN** 收到 `queueNum = 4`、`owners = [0,1]` 的分配
- **THEN** 返回 `Invalid`，本地状态不变，日志有 WARN

#### Scenario: owner 越界

- **WHEN** `owners` 含 `nodeCount` 或负数
- **THEN** 返回 `Invalid`

#### Scenario: 组先于主题到达

- **WHEN** 节点先收到 `/new` 的组注册，后收到 `/new` 的主题分配
- **THEN** 组进入待应用队列；主题落地后自动应用，最终 `groupExists("/new", g)` 为真

#### Scenario: 主题已删除后组到达

- **WHEN** 收到一个已被墓碑删除主题的组注册
- **THEN** 组被拒绝（记 WARN），不产生孤儿组

### Requirement: 备份副本的消费位点

`MQBackupPayload` SHALL 携带每个 `(topic, queueIndex)` 的订阅组位点
`{group, segmentedIndex, segmentedOffset}`，以及每条记录的 `deliverCount` 与 `acked`。
生产端 SHALL 在 flush 时从游标服务读取当前 `committed` 生成位点；`acked` SHALL 由
「记录位置早于该组 committed」推导，不得硬编码为 false。接收端 SHALL 把位点写入备份目录下的
`cursors/<groupEsc>.cursor`，并 SHALL 校验每条记录的投递状态数量（`states`）与记录数量一致
（位点按订阅组计，与记录条数不成比例，因此只校验状态）。
同一位点重复到达 SHALL 幂等；位点回退 MUST NOT 覆盖更大的已存位点。

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
- **THEN** 接收端记 WARN，仍落盘记录，但不更新位点

### Requirement: 清理器异常隔离

`LogCleaner.cleanOnce` SHALL 对每个主题、队列、段的删除操作做独立异常隔离：单个失败 SHALL 记
ERROR（含主题/队列/段）并继续处理其余对象。一轮结束 SHALL 汇总「删除数 / 失败数」；
定时器回调 SHALL 捕获异常，MUST NOT 因单次失败终止后续轮次。

#### Scenario: 单段删除失败

- **WHEN** 某段的删除抛异常，其它段可删除
- **THEN** 其它段被删除，返回删除数，日志有该段的 ERROR

#### Scenario: 死信清理继续

- **WHEN** 普通队列某段删除失败
- **THEN** 死信清理仍执行

#### Scenario: 定时器不中断

- **WHEN** 一轮 `cleanOnce` 抛出未预期异常
- **THEN** 定时器记录 ERROR，下一轮仍会执行
