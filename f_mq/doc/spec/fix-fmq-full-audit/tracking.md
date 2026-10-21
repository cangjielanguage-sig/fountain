# 审查问题跟踪表（75 项）

> 由 `proposal.md` 的映射表生成，逐项对应 `reviews/202610210648_fmq-f_mq-full-audit/todo.md`。
> 「任务」列指向 `tasks.md` 的任务编号；「状态」列随实现勾选更新。

| ID | 轮次 | 级别 | 问题摘要 | 任务 | 状态 |
|---|---|---|---|---|---|
| A01 | R1 | 严重 | >4KB 记录经对象载荷被降级为空数组 | T1, T3 | 已关闭 |
| A02 | R1 | 严重 | `publishTime` 与本地时间 ID 不一致，跨时区偏移 | T10 | 已关闭 |
| A03 | R1 | 一般 | `decodePayload` 对标量/异类载荷返回默认对象 | T11 | 已关闭 |
| A04 | R1 | 一般 | `MQMessage.get<T>` 对空/异类 BODY 返回默认对象 | T11 | 已关闭 |
| A05 | R1 | 一般 | `INVALID_GROUP` 无产生路径，组名校验缺失 | T12 | 已关闭 |
| A06 | R1 | 一般 | `metaSync` 四重载与子载荷分支无用例 | T28 | 已关闭 |
| A07 | R1 | 一般 | 16KB 用例未验临时文件形态与清理 | T1, T28 | 已关闭 |
| A08 | R1 | 一般 | `publish(record, id!)` 无用例，帧/记录 id 无守护 | T28 | 已关闭 |
| A09 | R1 | 一般 | `f_mq/doc/详细设计.md` 与实现多处不一致 | T29 | 已关闭 |
| A10 | R1 | 一般 | `isTopic()` 不校验 `kind`，拼错即删组 | T12 | 已关闭 |
| A11 | R2 | 严重 | 节点连接一次性使用，故障后永不重建 | T13 | 已关闭 |
| A12 | R2 | 一般 | 全部 owner 不可达时 `consume` 永久空转 | T14 | 已关闭 |
| A13 | R2 | 一般 | `ack` 静默忽略全部失败与错误码 | T14 | 已关闭 |
| A14 | R2 | 一般 | `unsubscribe` 忽略发送结果，服务端残留 | T14 | 已关闭 |
| A15 | R2 | 一般 | `subscribe` 回滚忽略失败 | T14 | 已关闭 |
| A16 | R2 | 一般 | 客户端零日志，解码失败静默丢消息 | T14 | 已关闭 |
| A17 | R2 | 一般 | 建连在全局锁内，慢节点阻塞全部 | T13 | 已关闭 |
| A18 | R2 | 一般 | 全 `NOT_OWNER` 被分类为连接异常 | T14 | 已关闭 |
| A19 | R2 | 一般 | `publish` 未校验 tags，与规格矛盾 | T12 | 已关闭 |
| A20 | R2 | 一般 | `consume` 无客户端认领，并发用例虚假 | T15 | 已关闭 |
| A21 | R2 | 一般 | 客户端 8 条关键失败路径零覆盖 | T28 | 已关闭 |
| A22 | R2 | 一般 | 任务清单虚报用例文件与内容 | T30 | 已关闭 |
| A23 | R2 | 一般 | 详细设计客户端签名/行为漂移 | T29 | 已关闭 |
| A24 | R2 | 一般 | `MQClientConfig_test` 泄漏全局配置且缺场景 | T28 | 已关闭 |
| A25 | R3 | 严重 | 删除不可传播，离线节点复活已删主题/组 | T16, T4 | 已关闭 |
| A26 | R3 | 严重 | 备份消息状态是伪造值，接收端忽略 | T5 | 已关闭 |
| A27 | R3 | 严重 | 备份 64 条在发布线程同步发送 | T5 | 已关闭 |
| A28 | R3 | 严重 | `registerTopic/Group` 丢弃结果，检查-执行非原子 | T7 | 已关闭 |
| A29 | R3 | 一般 | 死转活重同步不打开新主题队列 | T16 | 已关闭 |
| A30 | R3 | 一般 | 备份批次失败整批丢弃，无重试 | T5 | 已关闭 |
| A31 | R3 | 一般 | 广播失败只 WARN，无补偿 | T16, T4 | 已关闭 |
| A32 | R3 | 一般 | `mergeSnapshot` 不检测冲突、不告警 | T16 | 已关闭 |
| A33 | R3 | 一般 | `applyRemote` 乱序使轮转指针回退 | T16 | 已关闭 |
| A34 | R3 | 一般 | 远端元数据缺结构校验 | T16 | 已关闭 |
| A35 | R3 | 一般 | `removeTopic` 崩溃窗口产生孤儿组 | T8 | 已关闭 |
| A36 | R3 | 一般 | `applyGroup` 不校验主题存在 | T8 | 已关闭 |
| A37 | R3 | 一般 | 元数据写入无 fsync，掉电得空文件 | T6 | 已关闭 |
| A38 | R3 | 一般 | `record()` 关闭后静默丢弃 | T5 | 已关闭 |
| A39 | R3 | 一般 | `NodeRegistry.clientOf` 命中关闭连接不重建 | T13 | 已关闭 |
| A40 | R3 | 一般 | 存活标记初值全真，`isAlive` 死代码 | T13 | 已关闭 |
| A41 | R3 | 一般 | `LogCleaner.cleanOnce` 无异常隔离 | T26 | 已关闭 |
| A42 | R3 | 一般 | 元数据/备份/清理测试缺口 | T28 | 已关闭 |
| A43 | R3 | 一般 | `syncFromPeers` 失败分支与参数问题 | T16 | 已关闭 |
| A44 | R4 | 严重 | TTL 只认内存游标，删掉慢组积压 | T2 | 已关闭 |
| A45 | R4 | 严重 | 长度头无上界，损坏段触发 GB 分配 | T3 | 已关闭 |
| A46 | R4 | 严重 | `Unsupported` BODY 让组永久停摆 | T17 | 已关闭 |
| A47 | R4 | 一般 | 位点段被删时 `scanAfter` 报 0 | T18 | 已关闭 |
| A48 | R4 | 一般 | 记录不可读时静默标记已决 | T18 | 已关闭 |
| A49 | R4 | 一般 | `next` 开流/读中分支语义相反 | T18 | 已关闭 |
| A50 | R4 | 一般 | `ack` 不校验是否真的投递过 | T19 | 已关闭 |
| A51 | R4 | 一般 | 游标落盘无 fsync | T6 | 已关闭 |
| A52 | R4 | 一般 | `openTopic` 先查后插，并发泄漏 | T20 | 已关闭 |
| A53 | R4 | 一般 | 详细设计队列章与实现不符 | T29 | 已关闭 |
| A54 | R4 | 一般 | `ackTimeout` 无正数校验 | T21 | 已关闭 |
| A55 | R4 | 一般 | `sweep` 收到已断链订阅 | T22 | 已关闭 |
| A56 | R4 | 一般 | 队列 12 类场景零覆盖 | T28 | 已关闭 |
| A57 | R4 | 一般 | 「组内无匹配」正文与场景矛盾 | T17 | 已关闭 |
| A58 | R5 | 严重 | 无退出钩子，`MQServer.close()` 不可达 | T9 | 已关闭 |
| A59 | R5 | 一般 | `close()` 无异常保护，不可重试 | T9 | 已关闭 |
| A60 | R5 | 一般 | 断链清理零用例且与重订阅竞态 | T22 | 已关闭 |
| A61 | R5 | 一般 | `acked` 不含 autoAck，删除后计数残留 | T23 | 已关闭 |
| A62 | R5 | 一般 | `stats` 异常伪造 0 且 O(G×N) | T23 | 已关闭 |
| A63 | R5 | 一般 | 配置校验不足，非法值静默回落 | T21 | 已关闭 |
| A64 | R5 | 一般 | `MQConfig.parsePort` 自实现，违反规格 | T21 | 已关闭 |
| A65 | R5 | 一般 | `listTopics` 把服务端错误报成连接失败 | T24 | 已关闭 |
| A66 | R5 | 一般 | 备份段无清理，磁盘无界增长 | T25 | 已关闭 |
| A67 | R5 | 一般 | 服务端/管理器关键分支缺用例 | T28 | 已关闭 |
| A68 | R5 | 一般 | 启动路径不可测，`dispatch` 无注入点 | T27 | 已关闭 |
| A69 | R5 | 一般 | README/详细设计与实现不一致（含命令行限制） | T24, T29 | 已关闭 |
| A70 | R6 | 一般 | 断链清理整条 Requirement 零用例 | T22, T28 | 已关闭 |
| A71 | R6 | 一般 | 客户端关闭与调用并发零用例 | T28 | 已关闭 |
| A72 | R6 | 一般 | 死信组间隔离与字节完整性未断言 | T28 | 已关闭 |
| A73 | R6 | 一般 | 详细设计消费结果/ACK/`MQMessage` 缺 `queueIndex` | T29 | 已关闭 |
| A74 | R6 | 一般 | 详细设计 §5.1 `MQTopicMeta` 缺 `delayingMs` | T29 | 已关闭 |
| A75 | R6 | 一般 | `tasks.md` 六项已完成但未勾选 | T30 | 已关闭 |

## 严重问题（11 项）的用例锚点

> 每项都先写失败用例、再改实现；用例名即回归锚点（`cjpm test` 全量即可覆盖）。

| ID | 问题 | 用例锚点 |
|---|---|---|
| A01 | >4KB 记录降级为空 | `MQBlob_test`（4097/16KB/1MB）、`MQPayload_test` 三种载荷往返 |
| A02 | 时间戳跨时区偏移 | `Protocol_test.messageIdFormatsTimestampInUtc`、`GroupCursor_test.futurePublishTimeIsDeliveredImmediately` |
| A11 | 连接一次性使用 | `MQNodePool_test.closedConnectionIsRebuilt`、`slowNodeDoesNotBlockOtherNodes`、`failedBuildBacksOff` |
| A25 | 删除不可传播 | `MetaSyncer_test.snapshotMergeDropsTopicDeletedWhileOffline`、`deletedGroupCanBeRecreatedWithHigherRevision` |
| A26 | 备份状态伪造 | `BackupReplicator_test.payloadCarriesRealStatesAndCursors`、`BackupStore_test.cursorsOnlyMoveForward` |
| A27 | 备份阻塞发布 | `BackupReplicator_test.slowReplicasDoNotBlockPublish`、`recordOnlyEnqueuesAndFlushSendsOneBatch` |
| A28 | 注册非原子 | `MetaSyncer_test.concurrentRegisterThemeThrowsAlreadyExist`、`registeredAssignmentMatchesPersistedAndBroadcastsOnce` |
| A44 | TTL 忽略离线位点 | `LogCleaner_test.offlineGroupPositionKeepsSegments`、`neverConsumedGroupKeepsEverySegment` |
| A45 | 长度头无上界 | `QueueLog_test.hugeDeclaredLengthIsRejectedWithoutAllocation`、`declaredLengthBeyondRemainingIsRejected` |
| A46 | 不可评估 BODY 停摆 | `ConsumeService_test.unsupportedBodyIsReportedOnceAndSkipped` |
| A58 | 无退出钩子 | `MQServer_test.installExitHooksClosesServer`、`scripts/mq_e2e.sh` 的 `SIGTERM 优雅退出` 段 |
