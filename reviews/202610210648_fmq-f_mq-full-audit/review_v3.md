# R3: fmq 元数据与集群层（持久化 / 复制 / 节点表 / 备份副本）

审查时间：2026-10-21 07:10
审查基线：HEAD `5a133474`（全树审计，非 diff）

### 审查范围

代码（`fmq/src/meta/**`、`fmq/src/cluster/**`）：

- `fmq/src/meta/MetaStore.cj`、`MQAssignment.cj`、`MQFileNames.cj`
- `fmq/src/meta/MetaStore_test.cj`、`MQAssignment_test.cj`、`MQFileNames_test.cj`
- `fmq/src/cluster/MetaSyncer.cj`、`NodeRegistry.cj`、`BackupReplicator.cj`、`LogCleaner.cj`、`MQNodeTransport.cj`
- `fmq/src/cluster/MetaSyncer_test.cj`、`NodeRegistry_test.cj`、`BackupReplicator_test.cj`、`LogCleaner_test.cj`、`FakeTransport_test.cj`

上下文参照（仅用于判定语义，问题归属其它轮次时已注明）：

- 装配与调用点：`fmq/src/server/MQServer.cj:63-97,130-150`、`MQCommandExecutor.cj:97-185`、`MQConfig.cj:192-254`
- 被依赖类型：`f_mq/src/base/payload/MQTopicAssignment.cj`、`MQMetaSnapshot.cj`、`MQDeregisterPayload.cj`、`MQProtocol.cj:75-97`
- 队列侧语义：`fmq/src/queue/QueueManager.cj:64-98`、`f_mq/src/client/MQClient.cj:62-96,289-307`
- `f_net` 客户端语义：`f_net/src/client/client.cj:262-295`

文档：

- `fmq/doc/spec/add-fmq-message-queue/specs/fmq/metadata-cluster/spec.md`
- `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/metadata-cluster/spec.md`
- `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metadata-cluster/spec.md`
- `fmq/doc/详细设计.md` §5.4–5.6、§5.15–5.16、§6.1–6.3、§6.8、§6.9、§8
- `fmq/doc/开发计划.md` 阶段 G（319–436 行）、`fmq/doc/backlog.md`、`fmq/README.md:36-38,98-112`

### 发现

#### [R3-1] [严重] 重同步只做「补缺」，删除不可传播：被删主题/组会在离线节点上复活

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:145-159`（`mergeSnapshot` 仅 `topicOf(...).isNone()` 时 `applyTopic`）、`fmq/src/cluster/MetaSyncer.cj:105-121`（`syncFromPeers` 直接用该合并逻辑）、`fmq/src/meta/MetaStore.cj:178-192`（删除只删本地文件，不留任何删除标记/版本）
- **现象**：整套复制协议是「全量快照 + 只增合并」，元数据没有墓碑（tombstone）、没有版本号/纪元（全树 `grep tombstone|version|epoch` 为空）。节点 X 在 `deleteTopic /t` 期间离线，`broadcastDelete` 落空；X 重启后 `MQServer.cj:74` 拉取 peer 快照，`mergeSnapshot` 只补 peer 有、本地无的条目，对「本地有、peer 无」的 `/t` 不做任何处理，X 于是继续把 `/t` 当作已注册主题；`MQServer.cj:77-79` 还会为该主题打开本地队列目录并对外提供写入。
- **影响**：与 spec「每个节点 SHALL 保存全部主题与订阅组元数据」「由死转活时 SHALL 触发一次重同步」以及 `详细设计.md:617` 的承诺直接矛盾——一次普通重启即可让已删除主题在集群中长期存活。派生后果有三类：(1) 客户端仍可向幽灵主题发布，消息落入无人消费的日志持续堆积；(2) 同名主题后续重新注册时，幽灵节点 `applyRemote` 返回 `Conflict` 并保留旧 owners，与注册节点产生**分配分歧**（两节点对同一主题的队列归属不同）；(3) 组元数据同理，幽灵组会让重建后的主题 `registerGroup` 永远返回 `GROUP_ALREADY_EXIST`，只能手工删目录。这也是「反熵」在实现中完全缺失的根因：`MetaSyncer.cj:29` 注释声称「peer 恢复后由启动期全量同步补齐」，实际只能补缺、不能修正删除与漂移。
- **建议**：引入带单调版本（或 `updatedAt` + 节点 id 的 Lamport 计数）的元数据条目，并在删除时写墓碑（保留 TTL 后回收）；`mergeSnapshot` 改为「按版本比较、双向收敛」：peer 有本地无 → 补，本地有 peer 无且本地版本更旧 → 删，版本相同但内容不同 → WARN 并按确定性规则（如 topic 字符串哈希）收敛。补用例：删除主题 → 另一节点离线 → 该节点重启同步 → 断言主题不存在且队列目录未被打开。

#### [R3-2] [严重] 备份副本的「消息状态」是伪造值，接收端也完全忽略

- **文件:行号**：`fmq/src/cluster/BackupReplicator.cj:114-116`（`MQBackupState(seq, offset, 0, false)` 硬编码 `deliverCount=0`、`acked=false`）、`fmq/src/server/MQCommandExecutor.cj:194-196`（接收端只 `backupStore.append(...)`，`payload.states` 未被读取）
- **现象**：`详细设计.md:738` 与 spec「通过 `MQBackupPayload.records/states`（`MQBackupState{index, offset, deliverCount, acked}`）推送记录与其状态」要求在副本里保留投递次数与确认位；实现里 `record()` 的入参根本不含状态（`BackupReplicator.cj:65`），落盘状态恒为「未投递、未确认」；接收端连这个假状态也不存。
- **影响**：备份目录与主队列在「消费进度」维度完全等价于「全部未消费」。README:105 承诺「备份副本只保证落盘」，但 spec 与详细设计承诺的是「记录与其状态」；一旦按设计 §6.8「人工指定数据目录」做恢复，所有已 ack 的消息会被重新投递，at-least-once 退化为「重放历史全量」，与备份的可用性目标冲突。已知遗留项：`fmq/doc/backlog.md:8-11` 已登记为 P0，本轮仍未修复。
- **建议**：`BackupReplicator.record` 增加状态入参（由 `ConsumeService`/`GroupCursor` 提供当前 `deliverCount` 与 `acked` 快照），接收端按 `states[i]` 维护副本侧的旁路状态文件（或至少落一份 `states` 侧车），恢复流程再据此裁剪。

#### [R3-3] [严重] 备份批次达到 64 条时在发布线程内同步发送，直接阻塞发布

- **文件:行号**：`fmq/src/cluster/BackupReplicator.cj:69-80`（`shouldFlush` → 直接 `flush()`）、`fmq/src/cluster/BackupReplicator.cj:107-124`（`flush` 内对每个目标逐个 `transport.send`）、`fmq/src/cluster/NodeRegistry.cj:130`（`transfer(message, pingTimeout * 5)`，默认 1s×5=5s/目标）
- **现象**：`record()` 在临界区外调用 `flush()`，而 `flush()` 是同步 RPC：分组后对 `targets` 中每个节点串行 `send`，每个都能阻塞到 5s 超时。注释与 README:37「发布路径不阻塞」、spec「队列有界，溢出时 SHALL 丢弃并记 WARN，不得阻塞发布」均与此矛盾。最坏情况一次 publish 被拖住 `backup × 5s`（`backup=2` 即 10s），且同一批 64 条会被多个 queue/主题分组放大成多次 RPC。
- **影响**：`mqServer_backup > 0` 是常规集群配置，只要有一个后继节点网络抖动，每第 64 条消息的发布延迟就从毫秒级跳到秒级，客户端 `PUBLISH_TIMEOUT` 也仅 1s 级（`f_mq/src/client/MQClient.cj:77`）→ 大量误判超时，触发客户端换节点重试，进一步放大负载；这与「备份是可选增强、不得影响主链路」的设计意图相反。现有用例 `BackupReplicator_test.cj:61-73` 只用 `FakeTransport`（无耗时），无法暴露。
- **建议**：`record()` 只入队并由 `Timer` 线程 flush；需要按条数触发时改为「置标志 + 由定时器/独立发送线程执行」，或在 `flush` 内把发送投递到独立执行器。同时把每目标超时改为短超时（如 200ms）并统计失败；补一条「发送阻塞时 `record()` 立即返回」的用例（桩 transport 内 sleep 后断言 `record` 耗时）。

#### [R3-4] [严重] `registerTopic`/`registerGroup` 丢弃 `MetaApplyResult`，「检查-执行」非原子

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:54-67`（`store.topicOf` 预检查 → 读 `nextStartNode` → `applyTopic`，返回值被丢弃 → 无条件 `broadcastTopic` → 返回本地算出的 `assignment`）、`fmq/src/cluster/MetaSyncer.cj:74-80`（`groupExists` 预检查 + `applyGroup` 结果丢弃）
- **现象**：两段逻辑都是典型的 TOCTOU：`MQCommandExecutor` 用 200 线程的 executor 处理请求（`MQServer.cj:93-94`），两个并发 `registerTopic` 可以同时通过 `topicOf().isNone()`；随后 `applyTopic` 中只有一方 `Applied`，另一方得到 `Duplicated`/`Conflict`，但代码不看返回值，仍然把**自己算出的分配**广播出去并作为成功响应返回。`start = store.nextStartNode % nodeCount`（第 61 行）也读在锁外，两个并发注册可能拿到同一个起点。
- **影响**：响应与本地状态不一致——manager 拿到 assignment A，本节点落盘的却是 B。对端收到 A 后 `applyRemote` 若先到则落 A（→ 全集群 A，注册节点 B，自身队列按 B 打开）；若后到则被 `Conflict` 丢弃（→ 注册节点 B、对端 A）。两种结果都会让某些队列的 owner 与实际持有日志的节点不匹配，发布方持续收到 `NOT_OWNER` 并在节点之间打转（`f_mq/src/client/MQClient.cj:87-95`）。设计 §8 Q2 用「运维约定同一时刻只对一个节点做变更」减轻了跨节点并发，但**同一节点内的并发注册**并未被约束，而这条路径正是最容易发生的（同一 manager 并发脚本、双 manager 实例）。
- **建议**：把「校验 + 读指针 + 分配 + 落盘 + 推进指针」收敛到 `MetaStore` 的一个原子方法（在 `Mutex` 内完成，返回 `(MetaApplyResult, MQTopicAssignment)`），`MetaSyncer` 只在结果为 `Applied` 时广播并返回分配；`Duplicated` 映射为 `TOPIC_ALREADY_EXIST`/`GROUP_ALREADY_EXIST`，`Conflict` 返回 `MQServiceException` 并 WARN。补并发用例：8 线程并发注册同一主题/不同主题，断言最终 store 内容与各返回值一致。

#### [R3-5] [一般] 死转活触发的重同步不会打开新主题的本地队列，节点长期处于「元数据有、队列无」状态

- **文件:行号**：`fmq/src/server/MQServer.cj:96`（`onRevived = {=> syncer.syncFromPeers()}`）、`fmq/src/cluster/MetaSyncer.cj:145-159`（`mergeSnapshot` 只写 `MetaStore`）；对照 `openTopic` 的全部生产调用点：`MQServer.cj:77-79`（仅启动期）、`MQCommandExecutor.cj:104`（本节点处理注册）、`MQCommandExecutor.cj:141`（收到主题广播）
- **现象**：节点 X 离线期间其它节点注册了 `/new`（X 是其中若干队列的 owner），X 复活后只拉到元数据，`QueueManager` 里没有 `/new`；而 `openTopic` 只在上面三个路径被调用，均不会再触发。`QueueManager.openTopic`（`fmq/src/queue/QueueManager.cj:65-77`）只为 `owners[i] == selfIndex` 的队列建日志，其它节点也不会代建。
- **影响**：X 对 `/new` 的所有 publish/subscribe 一律回 `NOT_OWNER`（`MQCommandExecutor.cj:215-216`），X 名下的队列在整个进程生命周期内不可用，分配器承诺的负载分散被永久破坏；若某主题只有 1 个队列且 owner 恰为 X，则该主题在 X 重启前完全不可发布（客户端遍历所有节点都拿不到可写队列，抛 `MQConnectionException`，见 `MQClient.cj:95`）。spec「由死转活时 SHALL 触发一次重同步」的语义因此只完成了一半。
- **建议**：重同步完成后，把 `meta.topics()` 与 `queues` 已打开集合做差集并 `openTopic`（`openTopic` 自身对同主题幂等，可直接重复调用）；删除方向则调用 `queues.closeTopic(deleteFiles: false)`（配合 R3-1 的墓碑）。补用例：`MetaSyncer` 合并新主题后调用装配层同步入口，断言 `queues.queueOf(...)` 非空。

#### [R3-6] [一般] 备份批次发送失败后整批丢弃，无重试

- **文件:行号**：`fmq/src/cluster/BackupReplicator.cj:88-92`（先把 `pending` 换成空表）、`fmq/src/cluster/BackupReplicator.cj:107-110`（`targets` 为空直接 return，`batch` 丢失）、`fmq/src/cluster/BackupReplicator.cj:119-123`（`send` 失败仅 WARN）
- **现象**：一批数据在发送前就脱离队列，任何失败都没有回到待发送集合的路径；`targets.size == 0`（单节点）时整批静默丢弃。
- **影响**：备份的可靠性承诺退化为「尽力而为」。节点重启窗口内的备份全部丢失且无补发，主节点随后故障时副本缺少一段连续区间，而备份的用途正是应对该场景。已知遗留项：`backlog.md:12-14` 已登记为 P0。
- **建议**：按目标节点维护发送确认；失败批次回到队首（或专用重试队列）并做退避重试，设置最大重试/老化阈值后再丢弃并 WARN；`targets` 为空时直接丢弃即可，但应显式区分（当前与失败共用同一出口）。

#### [R3-7] [一般] 运行期广播失败只记 WARN，注释与文档承诺的「补齐」并不存在

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:173-183`（失败仅 `log.warn`）、`fmq/src/cluster/MetaSyncer.cj:29`（类注释「peer 恢复后由启动期全量同步补齐」）、`fmq/src/cluster/NodeRegistry.cj:166-184`（复活回调只在**本节点**发往该 peer 成功后才触发，且执行的是只增合并）
- **现象**：注册/注消广播失败后没有任何补偿队列；后续补只有在「本节点再次成功给该 peer 发消息」时才触发一次 `syncFromPeers`，而该同步又只补缺（R3-1），因此**删除类变更永远补不回来**，新增类变更也只能在碰巧发送成功时补。
- **影响**：设计文档与代码注释给出的是「最终一致」的承诺，实际是「最终补新增、永不补删除」。运维视角表现为：某节点元数据比集群旧且没有任何告警可定位。
- **建议**：广播失败时把变更记入本地 outbox（含目标节点），由定时器/复活事件重放；或至少在 `isAlive` 由死转活时对所有 peer 触发一次**双向**同步（依赖 R3-1 的版本化合并）。同步修正类注释与文档，避免两者不一致。

#### [R3-8] [一般] `mergeSnapshot` 不检测冲突、不发 WARN，与设计的冲突处理不一致

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:145-159`
- **现象**：设计 §5.6（`详细设计.md:248`）明确「已存在但不同 → 记 WARN、保留先到者」，但 `mergeSnapshot` 对同名主题直接跳过（第 147 行），既不比较 `owners`/`queueNum`/`delayingMs`，也不打日志；快照中带 `delayingMs` 的差异同样被静默吞掉。
- **影响**：启动同步阶段发生的元数据分歧完全不可观测，排障时缺少唯一线索；`add-fmq-metrics-and-delay` spec 要求「快照携带 `delayingMs`」，实现只在「本地无该主题」时才落该值，本地已有主题的延迟漂移不会被纠正。
- **建议**：`mergeSnapshot` 对已存在主题调用 `store.applyTopic`（其 `Conflict` 分支已有 WARN），或在差异时显式 WARN 并列出 owners 差异；比较字段补上 `delayingMs`。

#### [R3-9] [一般] `applyRemote` 在乱序到达时会让本机轮转指针回退

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:123-131`
- **现象**：远端应用时无条件用 `assignment.startNodeIndex` 重算 `nextStart` 并交给 `applyTopic`；`MetaStore.applyTopic`（`MetaStore.cj:148-151`）在 `Applied` 时直接覆盖 `assign.meta`，不做「只增」比较。广播是逐节点串行的实时 RPC，但 peer 之间、以及「广播」与「快照」之间没有顺序保证：先收到 `/b`(start=1, 1 队列 → next=2)、后收到 `/a`(start=0, 1 队列 → next=1) 时，指针从 2 回退到 1。
- **影响**：注册节点指向 2、该节点指向 1，若后续注册（manager 故障转移）落到该节点，就会选出一个与注册节点预期不同的起始节点。assignment 自包含所以不会直接丢消息，但分配语义在节点间不一致，且每次重启/乱序都可能重现。另外 `startNodeIndex` 与 `owners[0]` 之间没有任何一致性校验，一个畸形载荷就能把指针推到任意值。
- **建议**：`nextStart` 只允许前进（比较后再写，或统一改为「版本化 + 单调推进」）；`applyRemote` 校验 `owners.size == queueNum`、`0 <= startNodeIndex < nodeCount`、`owners[i]` 在 `[0, nodeCount)` 内，不合法直接拒绝并 WARN。

#### [R3-10] [一般] 远端元数据缺少结构校验，畸形分配会污染本地状态

- **文件:行号**：`fmq/src/meta/MetaStore.cj:135-154`（`applyTopic` 只比较 `queueNum` 与 `owners`，从不校验二者关系）、`fmq/src/cluster/MetaSyncer.cj:123-135`、`fmq/src/server/MQCommandExecutor.cj:138-144`
- **现象**：`applyTopic` 接受任意可解码的 `MQTopicAssignment`。`owners.size != queueNum` 时，`QueueManager.openTopic` 按 `owners.size` 建队列（`QueueManager.cj:70-75`），而 `TopicQueueSet.queueNum` 取的是 `assignment.queueNum`（`QueueManager.cj:76`），二者不一致；`owner(i)` 越界返回 `None` 但调用方多按 `owners` 直接用。远程节点（版本不一致、载荷损坏但能解码）可以把这种结构写进 `topics/` 并持久化。
- **影响**：一旦落盘就跨越重启持续存在；统计（`queueNum`）与实际队列数背离，消费/发布路径对同一主题给出不同视图，且 `MetaStore` 的 `Conflict` 判定也会被这种脏数据固化。
- **建议**：在 `MetaStore.applyTopic` 入口做结构与范围校验（`queueNum >= 1`、`owners.size == queueNum`、每个 owner 在 `[0, nodeCount)` 内、`startNodeIndex` 合法），非法直接拒绝（返回新的 `Invalid` 结果或抛 `MQServiceException`），并补用例。

#### [R3-11] [一般] `removeTopic` 的删除顺序留下崩溃窗口：重启后出现「无主题的孤儿组」

- **文件:行号**：`fmq/src/meta/MetaStore.cj:178-192`（顺序：清内存 → 删 `topics/*.meta`（183-185）→ 递归删 `groups/<topicEsc>`（186-189））
- **现象**：两次删除之间进程崩溃/掉电，磁盘上就只剩组文件而主题文件已消失。`loadGroups`（`MetaStore.cj:302-322`）不校验主题是否存在，直接按 `meta.topic` 建索引，于是 `groupsOf("/t")`、`groupExists("/t", g)` 在重启后仍为真，而 `topicOf("/t")` 为 `None`。
- **影响**：同名主题重新注册后，原组的 `GROUP_ALREADY_EXIST` 会阻止再次注册（`MetaSyncer.cj:74-77`），且这些组没有任何主题承载；`snapshot()` 也会把孤儿组复制给所有 peer（第 232-237 行遍历 `groups` 全表），把局部脏数据扩散到集群。
- **建议**：删除顺序改为「先删组目录 → 再删主题文件」（崩溃时最多留下「有主题无组」，可被重新注册覆盖）；`loadGroups` 载入时丢弃 `topicIndex` 中不存在的主题对应的组并记 WARN；`snapshot()` 同理过滤。

#### [R3-12] [一般] `applyGroup` 不校验主题存在，组广播可与主题广播乱序

- **文件:行号**：`fmq/src/meta/MetaStore.cj:156-175`（无 `topicIndex` 检查）、`fmq/src/cluster/MetaSyncer.cj:133-135`（`applyRemoteGroup` 直接落盘）
- **现象**：`MetaSyncer.registerGroup` 有「主题必须存在」的检查（第 71 行），但远端应用路径没有。注册主题与注册组是两条独立的广播消息，网络/线程调度可让组先到；或主题已被删除（`removeTopic` 已执行）而组的广播仍在途。
- **影响**：对端产生孤儿组并持久化，后果与 R3-11 相同（阻塞后续组注册、被快照扩散）；对「乱序」这一重点场景，当前实现没有顺序或依赖保证。
- **建议**：`applyRemoteGroup` 校验主题存在，不存在则丢弃并 WARN（或缓存待重放）；更彻底的是给元数据变更加单调序列号，对端按序应用/缓冲。

#### [R3-13] [一般] 元数据写入没有 `flush`/`fsync`，掉电可能得到空 `.meta`

- **文件:行号**：`fmq/src/meta/MetaStore.cj:328-346`（`File.create(tmp)` → `write` → `close` → `rename(overwrite: true)`，全程无 `file.flush()`）
- **现象**：设计 §5.5 只承诺「`.tmp` + rename 避免半写文件」，但 rename 与数据块落盘的顺序在多数文件系统上不保证；掉电后可能得到「已改名但长度为 0」的正式文件。
- **影响**：`loadTopics`/`loadGroups` 会把它当坏文件跳过（`MetaStore.cj:294-297,309-318`），即**主题/组在重启后静默消失**，而消息日志仍然存在（`SegmentedLog` 默认 `syncInterval=1`，每条 append 都 fsync，见 `f_io/src/SegmentedLog.cj:58,592-594`）。消息比元数据更耐久，语义上是反的。该路径没有被任何用例覆盖（见 R3-18）。
- **建议**：写入后、rename 前调用 `file.flush()`（`f_io` 已用同一 API 做 fsync）；对 `metas/` 目录也可考虑目录 fsync。补一条「写后立即重开仍可读」的用例，并在文档中明确元数据的持久性等级。

#### [R3-14] [一般] `record()` 在关闭后静默丢弃，与 README 的「记 WARN」不符

- **文件:行号**：`fmq/src/cluster/BackupReplicator.cj:66-68`
- **现象**：`backup <= 0 || closed.load()` 直接 `return`，无任何日志；README:37 写的是「备份队列满或关闭阶段到达的写入会被丢弃并记 WARN」（README:111 的「静默丢弃」是另一处，两处自相矛盾）。
- **影响**：关闭阶段丢备份是允许的，但完全没有痕迹；线上排查「为什么副本比主队列少一截」时缺少依据。
- **建议**：区分两种原因分别记日志（`backup=0` 可静默，`closed` 与队列满记 WARN），并统一 README 两处表述。

#### [R3-15] [一般] `NodeRegistry.clientOf` 命中已关闭连接直接抛，不重建

- **文件:行号**：`fmq/src/cluster/NodeRegistry.cj:102-108`
- **现象**：`case Some(client) => if (client.isClosed()) { throw Exception(...) }`，且 `clients[index]` 不会被清空；`send` 捕获异常后只 `markFailed`，下一次调用依旧命中同一个已关闭对象。
- **影响**：与 R2-F1（`MQNodePool.clientOf`）完全同型：`f_net` 的 `Client` 会在连续心跳失败后自我 `close()`（`f_net/src/client/client.cj:171-181`），此后本节点对该 peer 的元数据广播与备份永久失败，直到整个进程重启——而「节点间复用 `f_net` 心跳重连」正是 spec「节点表与身份」的要求。`backlog.md:18-21` 已登记。
- **建议**：`isClosed()` 时把槽位置 `None` 并重建客户端（失败则返回 `None` 走失败分支）；`send` 不再把所有异常都视为「对端不可达」，至少区分「本端连接已坏」（应重建）与「网络超时」。

#### [R3-16] [一般] 存活标记初值为「全部存活」，且 `isAlive` 是死代码

- **文件:行号**：`fmq/src/cluster/NodeRegistry.cj:58`（`alive = Array<AtomicBool>(nodes.size) {_ => AtomicBool(true)}`）、`NodeRegistry.cj:192-198`；对照 `fmq/doc/开发计划.md:373`（用例 `isAliveFalseBeforeSeen`「未成功交互 → false」）
- **现象**：所有节点（含从未连上的 peer）一开始就被视为存活，只有一次失败后才转 false；`isAlive` 在生产代码中无任何调用点（仅 `NodeRegistry_test.cj:64` 使用），`markFailed` 只被 `send` 的 catch 调用。
- **影响**：开发计划承诺的存活语义没有实现，`详细设计.md:461`「MQ 侧只记录 `markSeen`/`isAlive`」中的 `isAlive` 实际未参与任何决策；「由死转活」判定完全依赖「先失败一次再成功一次」，因此一个**从未成功连过的 peer** 在第一次成功时会触发一次多余的 `syncFromPeers`，而「曾经存活、后来静默死亡（没有再发消息）」的 peer 会一直保持 alive 标记。当前可见后果有限（因为没有消费方），但一旦按设计文档接入路由/告警就会误判。
- **建议**：初值改为「self 为 true、其它为 false」并让 `isAlive` 参与 `successors`/广播裁剪（或删除该 API 并同步修改文档）；补 `clientOfLazyAndCached`、`isAliveFalseBeforeSeen`（计划里已有、实际缺失）用例。

#### [R3-17] [一般] `LogCleaner.cleanOnce` 无异常隔离，单点失败中断整轮清理

- **文件:行号**：`fmq/src/cluster/LogCleaner.cj:51-69`（`queue.removeById(meta.index)` 在双重循环内，无 try）
- **现象**：任一段删除抛异常（文件被占用、f_io 拒绝删除、目录权限）都会让 `cleanOnce` 抛出；对 `Timer.repeat` 回调（第 72 行）而言，异常会终止本轮并且可能让后续轮次不再执行（取决于 `Timer` 实现），且已删除部分与未删除部分没有汇总日志。
- **影响**：一个坏主题目录可让整个节点的 TTL 清理长期停摆，磁盘持续增长且无告警；死信清理（第 64 行）也一并被跳过。
- **建议**：对每个队列 `try/catch` 并累计失败数，末尾输出一条汇总 WARN；`deadLetter.cleanExpired` 单独包裹。

#### [R3-18] [一般] 测试覆盖缺口：关键失败/乱序/持久化路径无用例

- **文件:行号**：`fmq/src/cluster/MetaSyncer_test.cj:176-275`（仅覆盖 happy path 与两条拒绝路径）、`fmq/src/meta/MetaStore_test.cj:26-204`、`fmq/src/cluster/BackupReplicator_test.cj:25-130`、`fmq/src/cluster/NodeRegistry_test.cj:23-104`、`fmq/src/cluster/LogCleaner_test.cj:69-71`
- **现象与影响**（逐条给出缺失的断言点，均会掩盖上文缺陷）：
  - `MetaSyncer`：无 `applyRemoteDelete` 用例（删除复制完全无测试）；无「广播失败（`available[i]=false`）仍返回成功且只 WARN」用例（可掩盖 R3-7）；无乱序/重复到货用例（可掩盖 R3-9）；无 `mergeSnapshot` 冲突用例（可掩盖 R3-8）；无「重同步后队列已打开」的装配级用例（可掩盖 R3-5）。`MetaSyncer_test.cj:231-243` 只断言「不抛 + 本地仍空」，未断言 WARN。
  - `MetaStore`：`removeGroup` 零用例（`grep removeGroup MetaStore_test.cj` = 0），删除是否持久化、空列表残留均无覆盖；无「坏 `assign.meta` → `nextStart=0`」用例；无「`applyGroup` 缺主题」用例（可掩盖 R3-12）；无「`removeTopic` 不存在的主题返回 false」。`MetaStore_test.cj:151-173`（`atomicWriteSurvivesStaleTmp`）只覆盖「目标文件不存在 + 残留 tmp」，未覆盖 spec 场景的原意「已有有效 `.meta` + 残留 `.tmp` 时正式文件不被污染」；`MetaStore_test.cj:130-148`（坏文件）只断言 `/ok` 可写，未断言坏条目**未进入索引**。
  - `BackupReplicator`：`BackupReplicator_test.cj:56-57` 只断言 `states[i].offset`，对 `deliverCount`/`acked`（R3-2 的错误值）零断言；无多主题/多队列分批用例（分组逻辑 `BackupReplicator.cj:96-106` 未覆盖）；`closeFlushesPending`（第 101-108 行）未断言定时器已停止；无「`record` 不被慢发送阻塞」用例（R3-3）。
  - `NodeRegistry`：无 `clientOf` 惰性建连/缓存复用用例（计划 `clientOfLazyAndCached` 缺失）；`failedSendMarksNodeDead`（第 61-74 行）依赖真实网络连 `127.0.0.1:1`，属环境相关用例；对「已关闭连接不重建」（R3-15）无用例。
  - `LogCleaner`：`LogCleaner_test.cj:69-71` 的 `@Assert(meta.last || after.size == 1)` 在只剩 1 段时恒真，属弱断言。
  - 目录固定为 `/tmp/fmq_test_*`（`MetaStore_test.cj:27-29`、`MetaSyncer_test.cj:30-32`、`LogCleaner_test.cj:28-30`），并行执行同一测试二进制（`cjpm test` 默认并行）时不同用例目录不冲突，但同一用例如被重复执行/多进程并行会互相清理。
- **建议**：按上面清单逐条补齐（优先 R3-1/R3-3/R3-4/R3-9 相关路径）；`FakeTransport` 增加「注入延迟/失败次数」能力以便测非阻塞与重试；弱断言改为「按 index 断言具体段存在/不存在」。

#### [R3-19] [一般] `syncFromPeers` 的失败分支与告警文案不准确，`snapshotFor` 参数未使用

- **文件:行号**：`fmq/src/cluster/MetaSyncer.cj:110-121`（循环末尾无条件 `log.warn("no peer reachable ...")`）、`MetaSyncer.cj:100-102`（`requesterIndex` 未使用）
- **现象**：只要没有一个 peer 返回**可解码的快照**就会打「no peer reachable」，包括「peer 可达但响应是 `MQResult` 错误」「载荷解码失败」两种情况；`snapshotFor(requesterIndex)` 完全忽略入参，也就无法按请求方做任何差异/权限处理。
- **影响**：告警把「协议/版本不一致」误报成「网络不可达」，正好掩盖升级期最常见的故障；`requesterIndex` 的无用参数在接口上暗示了并不存在的按节点裁剪能力。
- **建议**：区分「发送失败」「响应非快照」「解码失败」三种情况分别计数并输出对应日志；`snapshotFor` 去掉参数或在文档中说明该参数保留用途（若将来做增量同步）。

#### [R3-20] [建议] `MetaStore.close()` 只置标志，且没有任何方法检查该标志

- **文件:行号**：`fmq/src/meta/MetaStore.cj:242-252`
- **现象**：`isClosed`/`close` 是 `Resource` 的形式实现，`close()` 后 `applyTopic`/`removeTopic` 仍会写盘。
- **影响**：`MQServer.close()`（`MQServer.cj:141-149`）先 `meta.close()` 后 `registry.close()`，但 `NodeRegistry.onRevived` 回调可能在关闭窗口内触发 `syncFromPeers` 并把元数据写回磁盘，属于「关闭后仍在落盘」的竞态。
- **建议**：`applyTopic`/`applyGroup`/`remove*` 在 `closed` 时拒绝（返回明确结果或抛异常）；`MQServer.close()` 先解绑 `onRevived` 再关 meta。

#### [R3-21] [建议] `applyTopic` 的重复比较忽略 `delayingMs`

- **文件:行号**：`fmq/src/meta/MetaStore.cj:137-144`
- **现象**：`queueNum` + `owners` 相同即判 `Duplicated`，`delayingMs`、`startNodeIndex` 不同也不报 `Conflict`、不更新。
- **影响**：延迟值在复制链路上出现漂移时（例如对端用不同 `delaying` 重新注册同名主题）会被静默吞掉，各节点按不同延迟消费，且没有任何日志可追。
- **建议**：比较字段补上 `delayingMs`；若产品上不允许修改延迟，则至少记一条 WARN 说明「已存在且延迟不同，保留先到者」。

#### [R3-22] [建议] 文件名编码无长度上限，超长主题会得到 `INTERNAL` 而非 `INVALID_TOPIC`

- **文件:行号**：`fmq/src/meta/MQFileNames.cj:52-67`、`fmq/src/meta/MetaStore.cj:146`；主题校验 `f_mq/src/base/MQTopic.cj:25-37` 无长度约束
- **现象**：非 ASCII 字节每个都膨胀为 3 字符（`%XX`），中文主题约 85 个字符即触及常见 `NAME_MAX=255`；`writeAtomically` 创建文件失败会抛底层 IO 异常，最终由 `MQCommandExecutor.cj:91-94` 映射为 `INTERNAL`。
- **影响**：注册失败的错误码误导（配置问题被报成内部错误），且失败发生在分配之后、指针落盘之前，重试仍会失败。
- **建议**：`MQTopic.isValid` 增加长度上限（按编码后长度校验），或在 `registerTopic` 里先做 `MQFileNames.escape(topic).size` 检查并返回 `INVALID_TOPIC`。

#### [R3-23] [建议] `MQAssignment.nextStart` 不校验 `queueNum`

- **文件:行号**：`fmq/src/meta/MQAssignment.cj:40-45`
- **现象**：`allocate` 严格校验 `queueNum >= 1`（第 29-31 行），`nextStart` 却接受任意值（含负数），负值经 `normalize` 后静默回绕成一个看似正常的指针。
- **影响**：当前调用方都先校验过，属防御性缺口；一旦被新调用方复用会得到难以发现的错误分配。
- **建议**：与 `allocate` 对齐校验，或把两者合并为一次调用（`allocate` 同时返回 next，避免调用方各算一次）。

#### [R3-24] [建议] `start()` 无幂等保护

- **文件:行号**：`fmq/src/cluster/BackupReplicator.cj:127-132`、`fmq/src/cluster/LogCleaner.cj:71-73`
- **现象**：重复调用会创建第二个 `Timer` 且覆盖 `timer` 字段，旧定时器失去引用无法 `cancel`。
- **影响**：重复 `start()`（装配重复、测试重入）会泄漏线程并按双倍频率执行 flush/清理。
- **建议**：用 `AtomicBool` 或 `if (timer.isNone())` 保护，与 `close()` 的 CAS 风格一致。

#### [R3-25] [建议] `isTopic()` 对未知 `kind` 一律按「删组」处理

- **文件:行号**：`f_mq/src/base/payload/MQDeregisterPayload.cj:40-42`、`fmq/src/cluster/MetaSyncer.cj:83-97,137-143`
- **现象**：只有 `kind == "topic"` 返回 true，其它任意字符串都会走组删除分支，且 `subscribeGroup` 缺省为空串就会删掉默认组。
- **影响**：内部通道上的畸形载荷（或未来新增 kind）会误删默认组元数据；虽然当前只有 manager 会发该载荷，但删除路径缺乏「未知即拒绝」的保护。
- **建议**：改为显式 `kindOf(): ?Kind`，`None` 时拒绝并 WARN。

#### [R3-26] [建议] 文档与代码位置/顺序不一致

- **文件:行号**：`fmq/doc/开发计划.md:58-60`（MetaSyncer 记为 `src/meta/MetaSyncer.cj`、LogCleaner 记为 `src/queue/LogCleaner.cj`）与实际 `fmq/src/cluster/MetaSyncer.cj`、`fmq/src/cluster/LogCleaner.cj`；`fmq/doc/详细设计.md:632`（deleteTopic 顺序「删队列 → 删组 → 删游标 → 广播 → 再删元数据」）与 `fmq/src/server/MQCommandExecutor.cj:161-163`（先 `deregister`（含删元数据+广播）后 `cleanupAfterDelete`）相反
- **现象**：开发计划与详细设计中仍有已迁移/已变更的描述；`详细设计.md:738` 的备份内容（含 `states`）与实现也不一致（R3-2）。
- **影响**：按文档排障会找错文件、按文档推断删除时序会误判「先广播后清本地」的风险；文档-实现追踪矩阵失真。
- **建议**：更新开发计划 G4/G6 路径、把「可见性/删除顺序」章节改为实际顺序（或调整实现顺序以匹配文档），并在 §6.8 标注备份状态为未实现（引用 backlog）。

#### [R3-27] [建议] `NodeRegistry` 的若干细节

- **文件:行号**：`fmq/src/cluster/NodeRegistry.cj:157-164`（`indexOf` 生产代码未使用，且按原始字符串比较，节点表含空格/大小写差异时匹配不到）、`NodeRegistry.cj:59,62`（`checkDuration_` 在使用之后才声明）、`NodeRegistry.cj:102-121`（在建连临界区内构建 `Client`，慢连接会阻塞其它节点的 `clientOf`/`close`）
- **影响**：可读性与潜在阻塞；`indexOf` 的语义（精确匹配配置串而非 host:port）与 `selfIndex` 的「按端口匹配」不一致，未来复用时易踩坑。
- **建议**：删除未用的 `indexOf` 或改为按解析后的 `host:port` 比较；把 `checkDuration_` 声明移到字段区；`Client` 构建移出锁（先置占位，构建成功后写回，或用 per-index 锁）。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 4 |
| 一般 | 15 |
| 建议 | 8 |

### 总评

`MetaStore`/`MQAssignment`/`MQFileNames` 三个纯逻辑件质量较好：轮转分配逐字复现规格示例、百分号编码可逆且路径与 spec 布局一致、写入走 `.tmp`+rename、载入坏文件跳过不阻断启动、并发 apply 有 `Mutex` 保护且用例覆盖到 80 并发写入。`LogCleaner` 的「当前段不删 + 游标引用不删」双重保护也实现得干净。

但**集群一致性层面存在结构性缺口**，且都不是边角问题：元数据复制是「全量快照 + 只增合并」，没有墓碑/版本，删除无法随重同步传播（R3-1），所以 spec 与详细设计反复承诺的「所有节点保存全量元数据」「死转活重同步」「反熵」在删除方向上不成立；复活后的同步又只写元数据不建队列（R3-5），使复活节点长期无法承载体现在其名下的队列；`registerTopic` 丢弃 `MetaApplyResult` 并采用 TOCTOU 检查（R3-4），把「冲突保留先到者」的设计退化成了「响应可能不是落盘内容」。备份链路则同时失真（状态恒 0/false，R3-2）且违背「不阻塞发布」的硬承诺（R3-3）。以上四项中 R3-2/R3-6/R3-7 已在 `backlog.md` 登记为已知遗留，但 R3-1、R3-3、R3-4、R3-5 及 R3-9~R3-12 的乱序/删除一致性问题未被记录，且现有用例全部是 happy path，无法发现它们（R3-18）。

测试层面不存在空测试、空函数或 `@Assert(true)` 占位：本层 5 个测试文件的每条用例都有实质断言，`FakeTransport` 也是真实可用的内存桩。主要问题是**盲区而非敷衍**——删除复制、广播失败、乱序到货、合并冲突、断电容错、备份状态语义这六类路径完全没有用例，恰好覆盖了本层最脆弱的部分。

建议优先级：R3-1（版本化/墓碑 + 双向合并）→ R3-4（原子注册）→ R3-5（重同步后打开队列）→ R3-3（备份异步化）→ R3-2（备份状态）→ R3-9/R3-11/R3-12（乱序与删除顺序）→ 其余为健壮性与文档修正。文档侧至少应把 §5.6、§6.8 中未实现的承诺标注为「未实现（见 backlog）」，避免继续以「已承诺」的口径描述当前能力。
