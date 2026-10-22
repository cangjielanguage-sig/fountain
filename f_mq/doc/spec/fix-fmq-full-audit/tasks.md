# 任务：fmq / f_mq 全量审查修复

> 执行规则（AGENTS.md）：
> - 开发在功能分支 `fix/fmq-full-audit`，开工前 `git pull`；每完成一个任务独立提交。
> - 每个编码任务按 TDD：先写**会失败**的用例（Red），再改实现（Green），最后补边界/并发用例。
> - 新功能必须有仓颉单元测试；测试发现的新问题必须修掉并补用例。
> - 本清单的任务编号与 `proposal.md` 的问题映射表一一对应。

## 0. 准备

- [x] 0.1 建分支 `fix/fmq-full-audit`，同步远程；记录三模块基线测试数（`f_mq` / `fmq` / `f_io`）与 `mq_e2e.sh` 结果
- [x] 0.2 把 `reviews/202610210648_fmq-f_mq-full-audit/todo.md` 的 75 项按本文任务编号建跟踪表，确认无遗漏
- [x] 0.3 统一测试临时目录：新增 `fmq/src/test/TestDirs.cj`（UUID 子目录 + `atExit` 清理），替换固定 `/tmp/fmq_test_*`
- [x] 0.4 建立时间与网络替身约定：`now: () -> DateTime`、`ClientBuilder`、`MQNodeTransport` 假实现；后续用例不再依赖真实 sleep/端口

## P0 数据安全

> 目标：先堵住「静默丢数据 / 静默删数据 / 静默重放 / 进程级崩溃」。P0 未全绿不得进入 P1。

### T1 大载荷字节字段（A01、A07）

- [x] 1.1 先写失败用例：`MQConsumeResult` 的 `record` 取 4097 字节与 16KB，经 `DefaultCodec` 往返后 `size > 0` 且逐字节相等（当前必失败）
- [x] 1.2 再写失败用例：`MQInternalMessage{kind="backup"}` 的子载荷 > 4KB，`asInternal` → `decodePayload<MQBackupPayload>` 成功；`MQDeadLetterMessage.record` > 4KB 往返成功
- [x] 1.3 再写失败用例：解码后 `/tmp/tmpFile*` 不残留该次文件与目录；`DataInputStream(非 File)` 不得被当成空字节
- [x] 1.4 实现 `f_mq/src/base/MQBlob.cj`（`DataFields<MQBlob>`）：读 `DataCollection`/`DataInputStream(File)`、清理临时文件、`toData()` 与 `Array<Byte>` 字节一致
- [x] 1.5 写 golden 用例：同一逻辑值分别用 `Array<Byte>` 与 `MQBlob` 编码，字节完全相等；新旧类型交叉解码成功
- [x] 1.6 替换 `MQConsumeResult.record`、`MQInternalMessage.payload`、`MQBackupPayload.records`、`MQDeadLetterMessage.record` 的字段类型，保留 `Array<Byte>` 构造重载，更新全部调用点
- [x] 1.7 `MQProtocol.asConsumeResult`：解码失败返回 `None`；仅「类型正确 + 空 blob」表示无消息；补对应用例
- [x] 1.8 `cd f_mq && cjpm test` 全绿；`cd fmq && cjpm test --no-progress` 不全绿前不提交（大载荷会影响备份/死信用例）

### T2 段 TTL 与持久化游标（A44）

- [x] 2.1 先写失败用例：注册组 G 并只写盘位点（模拟重启后未消费），`LogCleaner.cleanOnce` 不得删除 `segmentIndex >= G.committed.seq` 的段
- [x] 2.2 失败用例：组从未消费（无位点文件）时段 1 保留；组删除后 floor 抬升，旧段可按 TTL 删除
- [x] 2.3 实现 `CursorCatalog`：启动加载、`save` 更新、删除失效、`floorOf(topic, queue)`；位点损坏按缺失处理并记 ERROR
- [x] 2.4 `ConsumeService.references` 改为查询 `floorOf`；`LogCleaner` 的删除条件改为 `segment.index < floor` + TTL
- [x] 2.5 用例：真实 `ConsumeService` + `LogCleaner` 装配（非假回调），覆盖「内存游标」与「仅磁盘位点」两种引用
- [x] 2.6 用例：备份队列位点缺失时保留全部段（为 T25 预留接口）
- [x] 2.7 `cd fmq && cjpm test --no-progress` 全绿

### T3 读取端记录长度上界（A45）

- [x] 3.1 先写失败用例（构造段字节）：长度头为 `0`、`0xFFFFFFFF`、`> 剩余有效字节`、`== 剩余有效字节`、`4 字节头不完整`
- [x] 3.2 用例断言：非法长度不分配大缓冲（进程不 OOM）、不读入下一段、返回 `None` 且日志含段号/偏移/声明长度/剩余
- [x] 3.3 实现：`QueueLog.MAX_RECORD_SIZE` 作为唯一常量；`QueueRecordReader.next` 在分配前做 1..MAX 与 remaining 校验；修正零长度继续解析的控制流
- [x] 3.4 新增 `QueueCorruptionException`，`QueueLog.scanAfter` 遇损坏抛出而不是吞成 `(0, None)`
- [x] 3.5 `GroupCursor.next` 捕获损坏：记 ERROR、返回 `Corrupt`、不崩溃（为 T18 铺路）
- [x] 3.6 `cd fmq && cjpm test --no-progress` 全绿

### T4 元数据版本、墓碑与删除收敛（A25、A31）

- [x] 4.1 先写失败用例：节点 X 离线 → 其它节点删除 `/t` → X 重启拉快照后 `topicOf("/t")` 为空，且不再为 `/t` 打开队列
- [x] 4.2 失败用例：删除组后重启/同步，`groupExists` 为假；重新注册同主题成功（墓碑被更高 revision 覆盖）
- [x] 4.3 失败用例：墓碑未过期不回收；过期且无活跃条目时回收
- [x] 4.4 协议层新增 `revision/origin`（主题、组）、`MQMetaTombstone`、`MQMetaSnapshot{tombstones, revision, tombstoneFloor}`，带默认值；补往返用例
- [x] 4.5 `MetaStore`：`revision.meta` Lamport 计数、墓碑目录与原子写、比较函数、`applyTopic/applyGroup/remove*` 全面接入
- [x] 4.6 `MetaSyncer.mergeSnapshot` 改为「应用主题/组/墓碑 + 对本地更旧且快照缺失的条目视为删除」；`nextStart` 取 max
- [x] 4.7 删除路径：写墓碑 → 删除元数据 → 广播墓碑；广播失败进入待补偿集合并记 WARN
- [x] 4.8 用例：乱序 revision（5 后到 3）、同 revision 不同内容（保留先到者 + WARN）、旧数据无 revision 的加载
- [x] 4.9 `cd fmq && cjpm test --no-progress` 全绿

### T5 备份异步、真实状态与重试（A26、A27、A30、A38）

- [x] 5.1 先写失败用例：后继发送阻塞 5s 时，连续 200 次 `publish` 每次 < 50ms 返回（当前必失败）
- [x] 5.2 失败用例：组已确认前 3 条后 flush，载荷 `states` 中前 3 条 `acked == true`，且携带位点；接收端位点文件可读回
- [x] 5.3 失败用例：首次发送失败后批次重新入队，恢复后成功；超过重试上限丢弃并记 ERROR
- [x] 5.4 失败用例：`record()` 在关闭后/`backup==0` 时丢弃并记 WARN（限流）
- [x] 5.5 协议：`MQBackupPayload` 增加 `cursors: Array<MQBackupCursor>`；`MQBackupState` 语义修正；补往返用例
- [x] 5.6 实现生产端：`record()` 只入队；独立工作线程（64 条或 100ms 触发）；失败批次重入队；关闭时 drain
- [x] 5.7 实现接收端：先落记录，再按 `(group, seq, offset)` 只进不退地落位点；数量不一致时只落记录并 WARN
- [x] 5.8 `BackupStore` 增加 `allLogs()` 与位点读写接口（供 T25）
- [x] 5.9 用例：单节点（无 target）不产生批次丢失；重复批次幂等；关闭与发送并发
- [x] 5.10 `cd fmq && cjpm test --no-progress` 全绿

### T6 元数据与游标的持久化（A37、A51）

- [x] 6.1 先写失败用例：用可注入的 `AtomicFile` 替身断言顺序为「write → flush → fsync(file) → rename → fsync(parent)」
- [x] 6.2 失败用例：fsync 抛错时 `save` 向上抛，内存状态不更新（或回滚）
- [x] 6.3 实现 `AtomicFile.write(path, bytes)`，替换 `MetaStore.writeAtomically` 与 `CursorStore.save`
- [x] 6.4 用例：连续保存 1000 次无 `.tmp` 残留；掉电替身下不会得到 0 字节正式文件
- [x] 6.5 `cd fmq && cjpm test --no-progress` 全绿

### T7 注册的检查-执行原子化（A28）

- [x] 7.1 先写失败用例：8 线程并发 `registerTopic("/t", 4)`，断言恰好 1 个成功、7 个 `TOPIC_ALREADY_EXIST`
- [x] 7.2 失败用例：并发注册 `/a` 与 `/b`，两者 `startNodeIndex` 不同，`nextStartNode` 等于两次推进结果
- [x] 7.3 失败用例：响应中的 `MQTopicAssignment` 与 `MetaStore.topicOf` 落盘值逐字段相等（当前可能不一致）
- [x] 7.4 实现 `MetaStore.registerTopic(meta, nodeCount) -> (result, assignment)` 与 `registerGroup(meta) -> result`，检查/分配/写盘/推进全在锁内
- [x] 7.5 `MetaSyncer` 只在 `Applied` 时广播，返回落盘对象；`Duplicated` 抛对应错误；补广播次数断言（假 transport）
- [x] 7.6 `cd fmq && cjpm test --no-progress` 全绿

### T8 删除顺序与组依赖（A35、A36）

- [x] 8.1 先写失败用例：在「删组」与「删主题文件」之间中断并重启，加载后不出现孤儿组，快照不含孤儿组
- [x] 8.2 失败用例：组先于主题到达（网络乱序）→ 进入待应用队列；主题落地后自动应用；主题已删除时组被拒绝
- [x] 8.3 实现 `removeTopic` 顺序（墓碑 → 组 → 主题 → 队列/游标）与重启后可重试
- [x] 8.4 实现 `MetaSyncer.pendingGroups`（有界 + TTL + 重试）与 `applyGroup` 的主题存在校验
- [x] 8.5 `MetaStore.loadGroups` 丢弃孤儿组并记 ERROR；`snapshot()` 不返回孤儿组
- [x] 8.6 `cd fmq && cjpm test --no-progress` 全绿

### T9 退出钩子与关闭容错（A58、A59）

- [x] 9.1 先写失败用例：注入「备份 close 抛错」的步骤，断言其余资源仍被关闭、日志含步骤名
- [x] 9.2 失败用例：第一次 close 有失败步骤，修复后第二次只重试失败步骤并完成；已成功步骤不重复报错
- [x] 9.3 失败用例：`close()` 后 `run()` 在 1s 内返回 0
- [x] 9.4 实现 `MQServer.closeSteps()`（可覆写）+ 逐步 try/catch + `closeCompleted` 重试语义
- [x] 9.5 `main.runServer()` 接入 `ExitCallbacks.toExitGracefully()` + `atExit(0, close)`，只在 `server` 分支安装
- [x] 9.6 用例：以注入启动器断言钩子注册（不真正发信号）；`manager` 分支不注册
- [x] 9.7 `cd fmq && cjpm test --no-progress` 全绿

## P1 正确性

### T10 记录时间戳统一 UTC（A02）

- [x] 10.1 先写失败用例：`MessageID(time: 绝对时刻).toString()` 的 23 位等于 UTC 墙钟（在 `TZ=Asia/Shanghai` 下运行）
- [x] 10.2 失败用例：`publishTime` 往返一致；未来 8 小时的时间戳记 WARN、`isDue == true`、`lagMs == 0`
- [x] 10.3 修改 `MessageID.toString()` 用 `DateTime.fromUnixTimeStamp(time.toUnixTimeStamp())` 格式化
- [x] 10.4 `GroupCursor.isDue` 与 `ConsumeService.stats` 增加未来时间容错与负值钳制
- [x] 10.5 全仓检索依赖本地时间格式的用例并修正；`cd f_protocol && cjpm test`、`cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

### T11 严格解码与 BODY 契约（A03、A04）

- [x] 11.1 先写失败用例：`decodePayload<MQMetaSyncRequest>` 收到 `DataString`/`DataReal` 返回 `None`（当前返回默认对象）
- [x] 11.2 失败用例：`MQMessage.get<Order>()` 对空 BODY、异类对象 BODY、标量 BODY 均返回 `None`
- [x] 11.3 `asPayload`/`decodePayload` 改严格转换（`DEFAULT_DATA_FLAG`），保留类型前置检查
- [x] 11.4 `MQMessage.get<T>` 实现 §4.1 的判定；补匹配类型的正例
- [x] 11.5 `cd f_mq && cjpm test` 全绿

### T12 组名、kind 与 tags 校验（A05、A10、A19）

- [x] 12.1 先写失败用例：空 kind、`"Topic"`、`"subscriber"` 的注销请求返回 `ERROR` 且不删除任何东西
- [x] 12.2 失败用例：非法组名在 `registerGroup`/`subscribe`/`deregister`/manager 均被拒绝（`INVALID_GROUP`），`metas/groups` 无新文件
- [x] 12.3 失败用例：`publish`/`subscribe` 的非法 tags 本地失败且零请求
- [x] 12.4 实现 `MQGroup.isValid`、`MQTags.isValid`、`MQDeregisterPayload.kindOf`
- [x] 12.5 接入服务端入口（`MQCommandExecutor`）、客户端、管理端
- [x] 12.6 `cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

### T13 连接自愈与存活语义（A11、A17、A39、A40）

- [x] 13.1 先写失败用例：客户端缓存的 `Client` 已关闭后再次请求会重建并成功（用注入的假 ClientBuilder）
- [x] 13.2 失败用例：节点 0 建连阻塞 2s 时，节点 1 的请求在 100ms 内完成
- [x] 13.3 失败用例：8 线程首次请求同一节点只建一条连接；关闭后不重建
- [x] 13.4 失败用例：`NodeRegistry` 对已关闭连接重建；`isAlive` 初值 false，成功一次后 true，复活只触发一次同步
- [x] 13.5 实现 `MQNodePool` 每节点锁/槽位/退避；`aliveNodes` 语义调整
- [x] 13.6 实现 `NodeRegistry` 同型重建与 `isAlive` 参与决策（广播跳过或反熵选点）
- [x] 13.7 `cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

### T14 客户端错误可见性与日志（A12、A13、A14、A15、A16、A18）

- [x] 14.1 先写失败用例：全部 owner 连接失败时 `consume` 抛 `MQConnectionException`（当前永久空转）
- [x] 14.2 失败用例：全部 `NOT_OWNER` 时 `publish` 抛 `MQServiceException(8)`（当前连接异常）
- [x] 14.3 失败用例：`ack` 发送失败抛错且映射保留，重试仍命中；非 `ACK_UNKNOWN` 错误抛 `MQServiceException`
- [x] 14.4 失败用例：`unsubscribe` 部分失败抛错且本地订阅保留；回滚失败文案含节点
- [x] 14.5 失败用例：非空记录解码失败记 ERROR 并抛 `MQServiceException(INTERNAL)`；`FILTER_UNSUPPORTED_BODY` 抛 code 10
- [x] 14.6 实现 `TransferOutcome` 与上述分支；新增 `LoggerFactory` 日志
- [x] 14.7 `cd f_mq && cjpm test` 全绿

### T15 客户端投递唯一认领（A20）

- [x] 15.1 先写失败用例：桩对两个线程返回同一 `(queueIndex, seq, offset)`，只允许一个线程返回该消息
- [x] 15.2 失败用例：ack 后同一位置再次投递可被重新认领
- [x] 15.3 实现 `deliveries.putIfAbsent` 原子占位；未抢到则继续下一 owner
- [x] 15.4 `cd f_mq && cjpm test` 全绿

### T16 反熵、远端校验与恢复装配（A29、A32、A33、A34、A43）

- [x] 16.1 先写失败用例：复活后同步到 `/new`，`QueueManager` 已打开本机队列，发布不再 `NOT_OWNER`
- [x] 16.2 失败用例：畸形分配（owners 数量不符、越界、负 delaying、start 越界）返回 `Invalid` 且不落盘
- [x] 16.3 失败用例：乱序远端分配使 `nextStart` 回退（当前必失败）；修复后取 max
- [x] 16.4 失败用例：快照与本地同名不同内容记 WARN（含差异字段）；`syncFromPeers` 区分不可达/错误/解码失败
- [x] 16.5 实现 `validateAssignment`、`nextStart` 单调、`mergeSnapshot` 冲突日志
- [x] 16.6 实现 `onTopicApplied` 回调并接入 `MQServer`；实现 `pendingPeers` 与反熵定时器
- [x] 16.7 `snapshotFor` 去掉误导性入参（或全部改为 `_` 并在文档说明）
- [x] 16.8 `cd fmq && cjpm test --no-progress` 全绿

### T17 不可评估 BODY 的出口（A46、A57）

- [x] 17.1 先写失败用例：先发布未注册对象 BODY（无 filter 订阅），再加非空 filter 订阅；第一次消费返回 `FILTER_UNSUPPORTED_BODY`（含位置），第二次消费返回后续消息
- [x] 17.2 失败用例：同一位置不重复报错；A 组跳过不影响 B 组
- [x] 17.3 失败用例：组内无匹配消息时越过并记 DEBUG，不进入死信；组内无人在线时 `committed` 不前进
- [x] 17.4 实现 `CursorOutcome` 与 `GroupCursor.next` 的 `Unsupported` 分支（写已决项 + advance + WARN）
- [x] 17.5 `ConsumeService`/`MQCommandExecutor` 返回 `ERROR(FILTER_UNSUPPORTED_BODY)`；客户端映射 code 10
- [x] 17.6 更新 `consume-semantics` 正文与场景的一致性（文档任务 T29 复核）
- [x] 17.7 `cd fmq && cjpm test --no-progress` 全绿

### T18 扫描、恢复与不可读记录的可观测性（A47、A48、A49）

- [x] 18.1 先写失败用例：位点段号落在「比最老段大但已被删除」区间，`scanAfter` 不再返回 `(0, None)`
- [x] 18.2 失败用例：开流与读中在「全段缺失」时行为一致（均返回空 + WARN）；段存在但损坏仍抛损坏异常
- [x] 18.3 失败用例：`readAt` 返回 `None` 时记 WARN + 计数，而非静默 `decided`
- [x] 18.4 实现 `SegmentMissingException`/`QueueCorruptionException` 与统一恢复分支
- [x] 18.5 `ConsumeService.stats` 对扫描异常返回错误（与 T23 联调）
- [x] 18.6 `cd fmq && cjpm test --no-progress` 全绿

### T19 ACK 必须对应已投递（A50）

- [x] 19.1 先写失败用例：位置已分配给 S2 但 `delivered = false` 时 S2 直接 ACK 返回 `ACK_UNKNOWN`，游标不动
- [x] 19.2 实现 `ack` 的 `delivered` 判定；补重复确认、越界、他人位置回归
- [x] 19.3 `cd fmq && cjpm test --no-progress` 全绿

### T20 队列打开原子性（A52）

- [x] 20.1 先写失败用例：8 线程同时 `openTopic`，只创建一组 `QueueLog`，无多余空段与 fd 泄漏
- [x] 20.2 失败用例：打开第 2 个队列抛错时第 1 个被关闭，`QueueManager` 无半成品
- [x] 20.3 实现 per-topic 锁 + `putIfAbsent` + 失败回滚（关闭并删本次空段）
- [x] 20.4 `cd fmq && cjpm test --no-progress` 全绿

### T21 配置校验与 MQHost 复用（A54、A63、A64）

- [x] 21.1 先写失败用例：`ackTimeout=0`、`segmentedLogMaxSize=0`、`segmentedLogTTL=0`、`deadMsgTTL=-1h`、`backup=3`（3 节点）、`h:0` 均启动失败退出 2
- [x] 21.2 失败用例：`segmentedLogMaxSize=not-a-size`、`port=abc` 不再静默回落默认值
- [x] 21.3 实现 `MQConfig.validate` 全量校验与解析失败报错；删除 `parsePort`，改用 `MQHost.parseHost`
- [x] 21.4 用例：合法边界（`1M`、`1ms`、`backup=2`）通过
- [x] 21.5 `cd fmq && cjpm test --no-progress` 全绿

### T22 断链清理与重订阅竞态（A55、A60、A70）

- [x] 22.1 先写失败用例：`cleanupSubscribers` 清理断链订阅并释放记录（当前零覆盖）
- [x] 22.2 失败用例：巡检快照后同一 `subscribedId` 在新连接重订阅，清理不得删除新订阅
- [x] 22.3 失败用例：断链订阅不在 `activeIds` 中，同组其它订阅下一次消费即可取到其记录
- [x] 22.4 `SubscriberRegistry` 增加 `generation`；`unregister(id, generation)`；`activeIds` 过滤断链
- [x] 22.5 `MQServer.cleanupSubscribers` 包内可见并可注入触发
- [x] 22.6 `cd fmq && cjpm test --no-progress` 全绿

### T23 指标口径与统计真实性（A61、A62）

- [x] 23.1 先写失败用例：`autoAck=true` 消费 3 条后 `acked == 3` 且 `backlog == 0`
- [x] 23.2 失败用例：删除主题/组后同名重建，四个计数器为 0
- [x] 23.3 失败用例：扫描失败时 `stats` 返回 `ERROR(INTERNAL)`，不返回 `backlog=0`（当前必失败）
- [x] 23.4 失败用例：多队列 `backlog` 与逐队列求和一致；`lagMs` 不为负
- [x] 23.5 实现 `MQMetrics.removeTopic/removeGroup`、autoAck `incAcked`、`stats` 错误传播
- [x] 23.6 实现单趟扫描（按最小 committed 起步，按组 committed 分桶计数），补大组数性能用例（不按时间断言，断言扫描次数）
- [x] 23.7 `cd fmq && cjpm test --no-progress` 全绿

### T24 管理端错误分类与参数顺序（A65、A69 命令行部分）

- [x] 24.1 先写失败用例：服务端回 `ERROR(INTERNAL)` / 非快照 `RESP` 时，输出服务端错误而非「无法连接」
- [x] 24.2 失败用例：`fmq --mqServer_port=2400 server` 正确识别 `server`（当前返回 2）
- [x] 24.3 失败用例：帮助文本含 7 个子命令（含 `stats`）
- [x] 24.4 实现 `requestSnapshot` 的 `Command.ERROR` 分支与协议错误文案
- [x] 24.5 实现 `dispatch` 跳过配置参数定位子命令；管理与服务端两种顺序都覆盖
- [x] 24.6 把输出渲染抽成纯函数，补 `registerTopic`/`listTopics`/`stats` 的内容断言
- [x] 24.7 `cd fmq && cjpm test --no-progress` 全绿

### T25 备份段清理（A66）

- [x] 25.1 先写失败用例：备份队列位点指向段 2，段 1 超 TTL 后被删除；无位点时保留全部
- [x] 25.2 `LogCleaner` 接入 `BackupStore.allLogs()` 与备份位点；`MQServer` 构造注入
- [x] 25.3 用例：清理失败按 T26 的隔离规则继续
- [x] 25.4 `cd fmq && cjpm test --no-progress` 全绿

### T26 清理器异常隔离（A41）

- [x] 26.1 先写失败用例：某段删除抛错时其它段与死信仍被清理，日志含失败段
- [x] 26.2 失败用例：`cleanOnce` 抛出未预期异常时定时器下一轮仍执行
- [x] 26.3 实现逐对象 try/catch + 汇总日志；定时器回调包裹
- [x] 26.4 `cd fmq && cjpm test --no-progress` 全绿

### T27 可注入启动装配（A68）

- [x] 27.1 先写失败用例：`dispatch(["server"])` 用注入工厂断言被调用一次、返回码透传、不阻塞
- [x] 27.2 失败用例：`dispatch(["manager", ...])` 用注入工厂断言参数与返回码
- [x] 27.3 实现 `dispatchWith(serverFactory, managerFactory, args)`，生产 `dispatch` 委托它
- [x] 27.4 `cd fmq && cjpm test --no-progress` 全绿

## P2 测试与文档

### T28 测试缺口补齐（A06、A07、A08、A21、A24、A42、A56、A67、A71、A72）

- [x] 28.1 协议：`metaSync` 四个重载的命令与子载荷往返；`publish(record, id!)` 的帧 id/记录 id 一致（A06、A08）
- [x] 28.2 客户端：8 条场景（节点 0 成功/节点 1 非 owner、订阅全非 owner/不可达、关闭与调用并发、publish 超时、consume 非 `SUBSCRIBE_NOT_EXIST` 错误、记录解码失败、节点恢复、非法 `host:port`）（A21、A71）
- [x] 28.3 客户端配置用例结束后还原 `Config`；补「配置缺失」「非法项」场景（A24）
- [x] 28.4 元数据：`applyRemoteDelete`、广播失败仍成功、乱序/重复到货、`mergeSnapshot` 冲突、重同步后队列已打开（A42）
- [x] 28.5 `MetaStore`：`removeGroup`、坏 `assign.meta`、`applyGroup` 缺主题、删除不存在主题、`atomicWriteSurvivesStaleTmp` 的规格原意、坏文件不进索引（A42）
- [x] 28.6 `BackupReplicator`：`deliverCount`/`acked` 断言、多主题/多队列分批、`closeFlushesPending` 同时断言定时器停止、慢发送不阻塞（A42）
- [x] 28.7 `NodeRegistry`：惰性建连/缓存复用/关闭后重建；`failedSendMarksNodeDead` 改为替身（A42）
- [x] 28.8 队列：真实游标保留段、长度头损坏、`Unsupported` 行为、跨组消费、组内无人在线、从中间记录开流、`scanAfter`/`countAll`/`segmentsOrEmpty`、`MAX_RECORD_SIZE`、死信损坏尾与 `== ttl` 边界、`openTopic` 关闭重开保留消息、topic/tags 解码失败 → `NoMatch`、并发 `committed` 单调（A56）
- [x] 28.9 死信：A/B 两组隔离；条目原始字节完整读回（A72）
- [x] 28.10 服务端：内部 metaSync 三个变更分支、未知命令、`publishWithBackupEnqueues`、`closeReleasesResources`（含 `sync`/订阅清空/幂等）、`stats` 输出字段、manager 输出断言（A67）
- [x] 28.11 `LogCleaner` 弱断言改为「剩余段数 + 段号集合」精确断言（A42）
- [x] 28.12 三模块全量测试通过

### T29 文档与实现对齐（A09、A23、A53、A69、A73、A74）

- [x] 29.1 以源码为准重写 `f_mq/doc/详细设计.md`：register/consume/ack 字段、三种 kind、四个 `metaSync`、`MQHost`、`MQTopicMeta.delayingMs`、`MQMessage.queueIndex`、`toMessage` 签名、签名清单（`stats`/`publish(record,id!)`/`publishTime`）、`MQBytes` 描述
- [x] 29.2 重写 `fmq/doc/详细设计.md`：`MQConsumeResult`/`MQAckPayload` 的 `queueIndex`、`MQClient.ack` 签名、`deliveries` 类型、`MQNodePool.init`、publish 路由、`entries` 结构、`next` 参数、`sweep` 触发方式、删除 `GroupCursor.sweep` 定时器、段格式与 64 MiB 上界、备份语义、退出钩子与关闭顺序、7 个子命令与输出格式
- [x] 29.3 更新 `fmq/README.md` 与 `README_en.md`：参数位置、7 个子命令、备份丢弃/重试/清理、TTL 与离线组保留、统计错误、已知限制（跨 TTL 节点重建、大记录需全节点升级）
- [x] 29.4 验收：逐节按实际符号/签名核对（`MQConfig.tombstoneTTL`/`antiEntropyInterval`、`MetaApplyResult` 五个值、`removeTopic: ?MQMetaTombstone`、`snapshotFor()`、`GroupCursor` 成员与 `entries` 类型），不能只查关键字命中
- [x] 29.5 `scripts/mq_e2e.sh` 的注释/输出与新行为一致

### T30 任务台账（A22、A75）

- [x] 30.1 勾选 `f_mq/doc/spec/add-fmq-message-queue/tasks.md` 第 11 节 11.1–11.6（逐项核对已落地）
- [x] 30.2 修正 39/42/44/45 行：删除不存在的 `MQClientPublish_test.cj`/`MQClientLifecycle_test.cj` 引用；「多 tags」改为实际的 10 个；补齐非法项解析/对象 BODY/关闭与调用并发
- [x] 30.3 新增本次变更章节，逐项与 `tasks.md` 对应
- [x] 30.4 验收：台账中每个 `*_test.cj` 都存在；每个 `[x]` 可运行

### T31 E2E 与回归

- [x] 31.1 `scripts/mq_e2e.sh` 增加：1MB 消息发布/消费；`stats` 校验；备份目录落盘与清理；`deleteTopic`/`deleteSubscribeGroup`
- [x] 31.2 停机改为 `kill -TERM`，断言进程退出码 0 且备份最后一批落盘、游标已落盘
- [x] 31.3 回归：`f_io`、`f_protocol`、`f_mq`、`fmq` 全量测试；E2E 输出 `E2E_OK`
- [x] 31.4 按类型分组提交；按用户确认合回 `sts/1.3.x`（`--no-ff`，合并不进 `master`），提交 `789f1349`

## 验收清单

- [x] 75 项问题全部有对应任务且已关闭（对照 `proposal.md` 映射表）
- [x] 11 项严重问题均有「修复前失败、修复后通过」的用例记录
- [x] 大记录（1MB）经消费、备份、死信全链路可读；无临时文件残留
- [x] 非 UTC 时区下延迟与 `lagMs` 正确
- [x] 节点重启、断链、全 owner 不可达后客户端能恢复或明确报错
- [x] 离线节点重启后不会复活已删除主题；组不会成为孤儿
- [x] 备份恢复不重放已确认消息；备份发送不阻塞发布；备份段可回收
- [x] 损坏段不会触发大分配；`stats` 不伪造 0
- [x] 不可评估 BODY 不再让组停摆
- [x] `SIGTERM` 触发完整关闭；`close()` 单步失败可重试
- [x] 文档、README、`tasks.md` 与实现一致
- [x] 三模块全量 + E2E 全绿


## V. verify 修复（依据 verify-report.md）

- [x] V1 [F1] 墓碑 Applied 后对 peer 执行队列/游标/订阅/计数器清理，并补装配级用例（peer 收到墓碑后四类状态均清空）
  - `MetaSyncer.onDeleted` 回调 + `MQCommandExecutor.cleanupAfterDelete`（改为 `protected`）；广播墓碑、快照墓碑、快照缺失兜底三条路径均触发
  - `MQServer` 注入回调，并在装配末尾 `reconcileDeletions` 收敛启动前（同步先于装配）已删主题/组的残留
  - 用例：`MQCommandExecutorTest.topicTombstoneFromPeerClearsLocalState` / `groupTombstoneFromPeerClearsGroupStateOnly` / `MQServerTest.restartCleansStateOfTopicDeletedWhileOffline`
- [x] V2 [F2] 重写 `fmq/doc/详细设计.md` §3/§4.3/§5.5/§5.6/§5.11（另同步 §4.4–§4.7、§5.14、§6.3），使配置签名、`MetaApplyResult`、删除返回值、`snapshotFor`、`GroupCursor` 接口与实现一致
- [x] V3 [F3] 统一反熵默认周期为 30s（改规格 `server-runtime`/`metadata-cluster`，与实现、README、`--help` 一致）
- [x] V4 [F4] 组内无匹配补 DEBUG 日志与 `noMatchSkipped` 计数，并补断言（`GroupCursorTest.unmatchedRecordIsSkippedAndCommitted`）
- [x] V5 [F5] `BackupReplicator.record()` 在 `backup<=0` 时记限流 WARN（文案含原因与位置）
- [x] V6 [F6] `BackupStore.saveCursor` 位点回退记 WARN（含路径与旧/新位点）
- [x] V7 [F7] 主题已被墓碑删除时组到达记 WARN 且不入 `pendingGroups`（迟到的主题重建也不复活，`MetaSyncerTest.groupIsRejectedWhenTopicIsDeleted` 加断言）
- [x] V8 [F8] 修订 `metadata-cluster` 规格中的墓碑路径为 `t_<topicEsc>.meta` / `g_<topicEsc>_<groupEsc>.meta`
- [x] V9 [F9] 规格改为 5 个 metaSync 重载；删除过时「两种 kind」场景、补墓碑子载荷、修断行；`f_mq/doc/详细设计.md` 与 `docs` 规格同步为五个重载
- [x] V10 [F10] 补 stats 单趟扫描次数断言（`ConsumeService.statsScans` + `statsScansEachQueueOnceRegardlessOfGroupCount`）
- [x] V11 重跑 `f_io`/`f_protocol`/`f_mq`/`fmq` 与 `scripts/mq_e2e.sh`，全绿后提交
  - `f_io` 20/20、`f_protocol` 70/70、`f_mq` 126/126、`fmq` 285/285、`scripts/mq_e2e.sh` = `E2E_OK`
  - 提交：`8acb2d2a`（fix/fmq 代码与用例）、`6a09243b`（docs）
  - 仍未做：31.4 合并回 `master`（需先定目标分支与合并方式，留给归档环节）

- [x] V12 [W1] `GroupCursor` 读流中途「全段缺失」改为与开流一致：返回 `None` + WARN，并补用例
  - `recoverIfSegmentGone` 改为 `SegmentRecovery{StillPresent, Moved, NoFuture}`；读中途分支不再 `throw e`，`NoFuture` 一律 WARN + 返回 `None`
  - 用例：`GroupCursorTest.allSegmentsMissingMidStreamReturnsNone`（读流已打开后删整目录，断言不抛异常且返回空）
- [x] V13 [W2] 起点段空洞时从「最接近的更大段」继续（不回退最老段），`scanAfter` 空洞记 WARN，并补用例
  - 新增 `QueueLog.startSegmentAtOrAfter`，`GroupCursor.recoverIfSegmentGone` 与 `QueueLog.scanAfter`/`countAll` 共用；无后继段时按空队列处理并 WARN
  - 用例：`GroupCursorTest.startingSegmentHoleResumesAtNextSegment`（1/7/8 洞，位点 5 → 段 7 起点继续）、`QueueLogTest.scanAfterSkipsGapToNextSegment`
- [x] V14 [W3] 补「不可评估 BODY 跳过」计数 `unsupportedSkipped` 并断言
  - 用例：`GroupCursorTest.unsupportedBodySkipIsCounted`（截断 BODY + 非空 filter ⇒ 计数 1、`takeUnsupported` 只报一次）
- [x] V15 [W4] 修正 `f_mq/doc/spec/add-fmq-message-queue/tasks.md` 中 `MQManager_test.cj` 的路径
- [x] V16 [W5] `f_mq/doc/详细设计.md` 的 metaSync 子载荷数量改为 5，与重载清单一致
- [x] V17 重跑四模块测试与 E2E，全绿后提交
  - `f_io` 20/20、`f_protocol` 70/70、`f_mq` 126/126、`fmq` 289/289（新增 4 个用例）、`scripts/mq_e2e.sh` = `E2E_OK`

- [x] V18 [W1] 客户端失败出口补节点下标/地址日志，`MQNodePool` 清理 catch 补 DEBUG，并补两条日志用例
  - `MQClient.transferOf` 统一记超时/连接失败 WARN（节点下标 + 地址），publish/consume/ack 失败出口补 ERROR；`MQNodePool` 两处清理 catch 记 DEBUG
  - 用例：`MQClientTest.clientFailsWithPerNodeLogs`（每个节点一条含下标与地址的日志）、`decodeFailureLogsPosition`（订阅 id + 队列:段:偏移 + 字节数）；日志捕捉器 `f_mq/src/client/test/LogCapture_test.cj`（内存输出流，不引入 `stdx.log` 依赖）
- [x] V19 [W2] `cleanupSubscribers` 补装配级用例（移除+释放、重订阅不误删）；`closeSteps` 清空订阅表并断言
  - `SubscriberRegistry.clear()` + `closeSteps` 新增 `subscribers` 步骤；`MQServer.subscriptionRegistry` 供用例检查
  - 用例：`cleanupSubscribersRemovesAndReleases` / `cleanupSubscribersKeepsResubscribed` / `closeClearsSubscriptionTable`
- [x] V20 [W3] `ConsumeService` 传给游标的成员视图过滤断链订阅，并补「S2 断链、S1 下一次可取」用例
  - `ConsumeService.consume` 用 `isDisconnected()` 过滤 `members`，与 `activeIds` 口径一致；用例见 `cleanupSubscribersRemovesAndReleases`
- [x] V21 [W4] 规格改为「调用方保证记录内 MESSAGE_ID 与帧 id 一致，工厂不改写记录字节」，同步场景
  - `specs/f-mq/protocol/spec.md` 需求与两个场景改写；`MQProtocol_test.publishWithExplicitIdKeepsFrameAndRecordIds` 断言已与规格一致
- [x] V22 [W5] `MQBlob` 对 `DataNone` 返回 `None`，清理失败记 WARN；更新用例
  - `MQBlob.cj`：`DataNone` → `None<MQBlob>`；临时文件/目录清理失败记 WARN；用例改为 `dataNoneIsNotAnEmptyBlob`
- [x] V23 [W6] `QueueLog.openFrom/openRecordsFrom` 下沉「后继段选择 + WARN」，`unknownSegmentThrows` 改为从段 7 继续
  - `QueueLog.startPositionOf` 统一恢复语义（无后继段返回空流）；`GroupCursor.openReaderAt` 把跳转同步到 `committed` 并落盘
  - 用例：`QueueLogTest.unknownSegmentResumesAtNextSegment`；`GroupCursorTest` 的两条恢复用例保持通过
- [x] V24 [W7] `stats` 无段/损坏不再静默 0，记 WARN 并返回 INTERNAL；`catch MQServiceException` 补日志
  - `ConsumeService.stats` 无段分支记 WARN + `INTERNAL`；`MQCommandExecutor` 对 `INTERNAL` 记 WARN、其余服务码记 DEBUG
  - 用例：`ConsumeServiceTest.statsFailsWhenSegmentsAreGone`
- [x] V25 [W8] 补 `removeByBuffer` → 组内另一订阅下次 consume 取到记录的装配用例
  - 用例：`MQServerTest.removeByBufferReleasesRecordToGroup`（真实连接 + 按 buffer 摘除 + 同组新订阅取到记录）
- [x] V26 [W9] `removeTopic` 级联写组墓碑并随广播下发（或明确规格由主题墓碑涵盖）
  - `MetaStore.removeTopic` 返回「主题墓碑 + 各组墓碑」；`MetaSyncer.deregister` 逐条广播；用例 `MetaStoreTest.deleteTopicCascadesGroups` 断言 3 条墓碑与快照
- [x] V27 [W10] `loadTopics` 调用 `MQAssignment.validate`，失败记 ERROR 并跳过；补用例
  - `MetaStore` 新增 `nodeCount`（未知时用 `MQAssignment.validateStructure`）；`MQServer` 传入节点数
  - 用例：`MetaStoreTest.loadTopicsSkipsInvalidAssignment`（owners 数量不符、owner 越界均不进索引）
- [x] V28 [W11] 反熵选点参考 `isAlive`（未知优先、死亡最后），或修订规格
  - `MQNodeTransport.isAlive` 进入接口，`NodeRegistry.isAlive` 转 public；`MetaSyncer.syncFromPeers` 三趟：未知 → 存活 → 已知死亡
  - 用例：`MetaSyncerTest.antiEntropyPrefersUnknownThenAliveThenDead`
- [x] V29 [W12] 备份位点校验与恢复场景对齐（校验 states 数量；补 loadCursor→save 用例或改规格）
  - 规格改为校验 `states` 数量，恢复场景改写为「备份位点可用于重建游标」
  - 用例：`BackupStoreTest.backupCursorRebuildsConsumerCursor`（loadCursor → `CursorStore.save` → `CursorCatalog.positionOf`）
- [x] V30 [W13] `AtomicFile` 的 fsync 失败记 ERROR 并区分不支持/真实失败
  - 文件 fsync 失败记 ERROR 并重抛；目录 fsync 按 `isUnsupportedFsync` 分 DEBUG（跳过）与 ERROR + 重抛
  - 用例：`AtomicFileTest.unsupportedDirectoryFsyncIsClassified`
- [x] V31 [W14] `MQManagerArgs` 跳过子命令前后的配置参数，并补 manager 级前置用例
  - `parse` 跳过 `-*` 形式的配置项（单横线连同其值）；用例 `MQManagerTest.configTokensAroundSubcommandAreSkipped`
- [x] V32 [W15] 修正详细设计 6 处漂移与台账 7.2/7.3/11.1 的过度声称
  - `fmq/doc/详细设计.md`：`entries` 类型、`sweep` 触发（两处）、`MQMatcher.matches` 签名与 `MQMatchResult`、`registerTopic` 输出含延迟、`listTopics` 四列
  - `f_mq/doc/spec/add-fmq-message-queue/tasks.md`：7.2/7.3 归属修正、11.1 断言范围收窄到退出码（内容断言归 `MQManagerOutput_test.cj`）
- [x] V33 重跑四模块与 E2E，全绿后提交
  - `f_io` 20/20、`f_protocol` 70/70、`f_mq` 128/128、`fmq` 299/299、`scripts/mq_e2e.sh` = `E2E_OK`

- [x] V34 [W1] 修复 SIGTERM 时 accept 抛未捕获 `SocketException`，保证退出码稳定为 0；E2E 连续 3 次验证
  - `f_net` `Server.start` 的 accept 循环吞掉「已关闭」的 `SocketException`（DEBUG）并正常返回，其余记 ERROR；
    用例 `f_net_tcp_test.testStartReturnsAfterClose`（修复前以 `SocketException: Socket is already closed` 失败，修复后通过）
  - E2E 连续 4 次 `E2E_OK`；保留日志的一轮中 `n*/server.log` 只剩 `Handle signal: 15`，无未捕获异常栈
- [x] V35 [W2] `design.md` §3.7 补 4 字节大端长度与跨版本兼容约束，修正「不足 4 字节」语义
  - §3.7 新增段内记录格式表（4 字节大端长度 + 记录字节、不跨段）、64 MiB 上界与「升级不得改前缀宽度/字节序」约束；
    第 1 步由「不足 4 字节 → 正常结束」改为「损坏」
- [x] V36 [W3] 管理端 `registerTopic`/`listTopics`/`stats` 输出内容可断言，并补用例
  - 渲染下沉到 `MQManagerOutput.registeredTopic`/`topicList`/`stats`（`assignments` 共用），`MQManager` 只负责取数后打印
  - 用例：`registeredTopicOutputHasTopicCountAndOwners`、`topicListRendersOneRowPerTopic`、`emptyTopicListShowsPlaceholder`、
    `statsRendersHeaderAndTwoRows`、`statsIgnoresHeaderAndShortRows`
- [x] V37 [W4] 「全部 owner 不可达」异常文案包含尝试过的节点
  - `MQClient.consume` 文案追加 `(tried nodes [..])`，与 ERROR 日志同源；用例 `consumeThrowsWhenAllOwnersUnreachable` 断言含 `[0]`
- [x] V38 四模块 + E2E 连续 3 次全绿后提交
  - `f_io` 20/20、`f_protocol` 70/70、`f_mq` 128/128、`fmq` 304/304（新增 5 条管理端渲染用例）、`scripts/mq_e2e.sh` 连续 4 次 `E2E_OK`
