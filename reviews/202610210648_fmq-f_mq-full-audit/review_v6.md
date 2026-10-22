# R6: 全局测试质量与文档-实现追踪

审查时间：2026-10-21
审查对象：`f_mq`（动态库）与 `fmq`（可执行文件）
审查方式：只读审查（未修改任何文件）

---

## 审查范围

| 维度 | 范围 | 规模 |
| --- | --- | --- |
| 测试代码 | `f_mq/**` + `fmq/**` 下全部 `*_test.cj` | 39 个文件、260 个 `@TestCase`、6442 行 |
| 规格 | `f_mq/doc/spec/**` + `fmq/doc/spec/**` 全部 `spec.md`（3 个变更目录 × 9 个 capability） | 17 个文件、74 条 Requirement |
| 用户文档 | `f_mq/README.md`、`f_mq/README_en.md`、`fmq/README.md`、`fmq/README_en.md` | 4 个文件 |
| 详细设计 | `f_mq/doc/详细设计.md`（666 行）、`fmq/doc/详细设计.md` | 2 个文件 |
| 追踪产物 | `f_mq/doc/spec/*/tasks.md`、`*/verify-report.md`、`fmq/doc/backlog.md` | 5 个文件 |
| 实现对照 | `f_mq/src/**`、`fmq/src/**` 全部非测试源码（61 个文件） | 全量抽查关键路径 |

扫描口径（机器统计，均在本轮复现）：

```
@TestCase 计数            260
@Assert 总数              约 700（逐文件核对见下表）
@Ignore/@Disable/@Skip    0
被注释掉的 @TestCase      0
@Assert(true)             5（全部位于 match 分支）
用例内 println            0
TODO/FIXME/NotImplemented 0
空函数体（{}）            0
仅 return 的函数          0
```

---

## 一、测试质量全局扫描结论

### 1.1 空测试 / 禁用测试 / 占位实现：均为 0

| 检查项 | 结论 | 证据 |
| --- | --- | --- |
| 函数体为空的用例 | 0 | 逐用例解析函数体，260 个用例全部含 `@Assert` |
| 无 `@Assert` 的用例 | 0 | 同上（脚本按缩进提取每个 `@TestCase` 函数体后统计） |
| 仅 `@Assert(true)` 的用例 | 0 | 5 处恒真断言均与分支判定配对，见 1.3 |
| 只打印的用例 | 0 | 全仓测试内 `println(` 命中 0 |
| `@Ignore` / `@Disable` / `@Skip` | 0 | 全仓命中 0 |
| 注释掉的用例 | 0 | 无被注释的 `@TestCase` |
| 空函数体 / 仅 `return` / `throw NotImplemented` | 0 | 61 个非测试源文件中命中 0 |
| TODO / FIXME | 0 | 非测试源文件中命中 0（仅 `MQManagerOutput.cj:24` 有「空结果占位」注释，是渲染逻辑说明，非待办） |

结论：**不存在以空实现或禁用用例冒充完成度的情形**。

### 1.2 测试替身与桩函数（非遗留缺陷）

| 位置 | 形态 | 判定 |
| --- | --- | --- |
| `fmq/src/cluster/FakeTransport_test.cj:23` | 纯测试替身类，**0 个 `@TestCase`** | 合法：被 `MetaSyncer_test`、`BackupReplicator_test` 复用；仅文件名后缀使其进入测试目标 |
| `fmq/src/queue/GroupCursor_test.cj:125-127` | `isClosed() { false }` | 合法：`CursorFixture` 的资源包装，表示「永不关闭」 |
| `fmq/src/server/ConsumeService_test.cj:95-97` | 同上 | 合法 |
| `fmq/src/server/MQCommandExecutor_test.cj:99-101` | 同上 | 合法 |

这 3 处不是生产代码的占位桩，而是测试夹具对 `Resource` 接口的最小实现，不计为问题（命名建议见 S5）。

### 1.3 五处 `@Assert(true)` 逐条判定

| # | 位置 | 上下文 | 判定 |
| --- | --- | --- | --- |
| 1 | `f_mq/src/base/MQMessageRecord_test.cj:178` | `match (content.body.data) { case _: DataNone => @Assert(true); case _ => @Assert(false) }` | 有效：断言「运行时类型确为 `DataNone`」 |
| 2 | `f_mq/src/base/MQProtocol_test.cj:47` | `case CONSUME(_) => @Assert(true)` + `case _ => @Assert(false)` | 有效：命令分派断言 |
| 3 | `f_mq/src/base/MQProtocol_test.cj:105` | `case RESP(_) => @Assert(true)` + `case _ => @Assert(false)` | 有效 |
| 4 | `f_mq/src/client/test/MQClient_test.cj:79` | `case PUBLISH(_) => @Assert(true)` + 兜底 false | 有效 |
| 5 | `fmq/src/server/MQCommandExecutor_test.cj:132` | `case RESP(_) => @Assert(true)` + 兜底 false | 有效 |

结论：**无无意义恒真断言**。5 处均依赖「不匹配即 false」的兜底分支，语义完整。写法可读性建议见 S6。

### 1.4 用例规模分布（按文件）

| 文件 | 用例 | 断言 |
| --- | --- | --- |
| `f_mq/src/base/MQMessageRecord_test.cj` | 15 | 48 |
| `f_mq/src/base/MQPayload_test.cj` | 10 | 63 |
| `f_mq/src/base/MQProtocol_test.cj` | 11 | 50 |
| `f_mq/src/base/MQFilter_test.cj` | 6 | 21 |
| `f_mq/src/base/MQModel_test.cj` | 5 | 27 |
| `f_mq/src/base/MQErrorCode_test.cj` / `MQHost_test.cj` / `MQTopic_test.cj` | 3 / 2 / 2 | 19 / 11 / 13 |
| `f_mq/src/client/test/MQClient_test.cj` | 19 | 60 |
| `f_mq/src/client/test/MQNodePool_test.cj` | 3 | 7 |
| `f_mq/src/client/MQClientConfig_test.cj` | 2 | 2 |
| `f_mq/src/client/MQOwnershipCache_test.cj` | 3 | 6 |
| `f_mq/src/exception/MQException_test.cj` | 3 | 13 |
| `f_mq/src/test/Facade_test.cj` | 2 | 11 |
| `fmq/src/queue/GroupCursor_test.cj` | 22 | 79 |
| `fmq/src/queue/QueueLog_test.cj` | 10 | 30 |
| `fmq/src/queue/CursorStore_test.cj` | 6 | 17 |
| `fmq/src/queue/DeadLetterQueue_test.cj` | 5 | 19 |
| `fmq/src/queue/QueueManager_test.cj` | 5 | 16 |
| `fmq/src/queue/MQMatcher_test.cj` | 6 | 17 |
| `fmq/src/server/ConsumeService_test.cj` | 15 | 54 |
| `fmq/src/server/MQCommandExecutor_test.cj` | 19 | 52 |
| `fmq/src/server/MQServer_test.cj` | 5 | 24 |
| `fmq/src/server/MQManager_test.cj` | 8 | 25 |
| `fmq/src/server/BackupStore_test.cj` | 3 | 12 |
| `fmq/src/server/SubscriberRegistry_test.cj` | 6 | 24 |
| `fmq/src/cluster/MetaSyncer_test.cj` | 11 | 46 |
| `fmq/src/cluster/BackupReplicator_test.cj` | 7 | 15 |
| `fmq/src/cluster/NodeRegistry_test.cj` | 7 | 21 |
| `fmq/src/cluster/LogCleaner_test.cj` | 4 | 10 |
| `fmq/src/meta/MetaStore_test.cj` | 7 | 29 |
| `fmq/src/meta/MQAssignment_test.cj` | 6 | 15 |
| `fmq/src/meta/MQFileNames_test.cj` | 4 | 11 |
| `fmq/src/manager/MQManagerArgs_test.cj` | 5 | 27 |
| `fmq/src/manager/MQManagerOutput_test.cj` | 4 | 9 |
| `fmq/src/Main_test.cj` | 5 | 11 |
| `fmq/src/MQUsage_test.cj` | 3 | 15 |
| `fmq/src/config/MQConfig_test.cj` | 1 | 30 |

---

## 二、Requirement → 实现 → 用例 覆盖矩阵

判定口径：
- **完整**：Requirement 的全部 Scenario 均有直接断言用例；
- **部分**：Requirement 有实现且有用例，但至少一个 Scenario 无直接断言；
- **缺失**：Requirement 有实现但零用例；
- **无实现**：Requirement 无对应实现。

### 2.1 `f_mq` / protocol（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 复用既有协议命令 | `MQProtocol.cj` | `MQProtocol_test.factoriesUseExpectedCommands`、`MQCommandExecutor_test` 全矩阵 | 完整 |
| 2 | 发布记录的四段字节布局 | `MQMessageRecord.cj:encode/decode` | `MQMessageRecord_test`（15 例，含四段逐段解码 `perSegmentDecodersAgree`） | 完整 |
| 3 | 记录字节在帧内的承载与还原 | `MQProtocol.asRecord`、`MQBytes.fromData` | `MQProtocol_test.recordTravelsByteForByte`、`largeRecordSurvivesFrameRoundtrip`（16 KiB，覆盖临时文件形态） | 完整 |
| 4 | 载荷按运行时类型分派 | `MQProtocol.kindOf` | `payloadKindsAreClassified`、`typeMismatchReturnsNone`、`MQCommandExecutor_test.garbagePayloadReturnsInternalError` | 完整 |
| 5 | 响应与错误的构造 | `MQProtocol.resp/fail` | `responsesEchoRequestId`、`failUsesErrorCommandAndPayload` | 完整 |
| 6 | ACK 必须携带队列身份 | `MQAckPayload.queueIndex`、`ConsumeService.ack` | `MQProtocol_test.ackPayloadCarriesQueueIdentity`、`MQClient_test.ackPayloadKeepsQueueIdentity`、`ConsumeService_test.ackTargetsExactQueueAndRejectsUnknownQueue` | 完整 |
| 7 | 稳定的错误码表 | `MQErrorCode.cj` | `MQErrorCode_test`（3 例） | 完整 |
| 8 | 主题路径校验 | `MQTopic.cj` | `MQTopic_test`（2 例）、`MQClient_test.invalidTopicFailsLocally` | 完整 |
| 9 | 订阅过滤器求值 | `MQFilter.cj` | `MQFilter_test`（6 例，含 `DataNone`/缺失路径/容器） | 完整 |
| 10 | 载荷类的编解码自洽 | `payload/*.cj`、`model/*.cj` | `MQPayload_test`（10 例）、`MQModel_test`（5 例） | 完整 |

### 2.2 `f_mq` / client（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 客户端配置与节点表 | `MQClientConfig.cj` | `MQClientConfig_test`（2 例） | 完整 |
| 2 | 发布路由与失败重试 | `MQClient.publish:68-96` | `publishSendsRecordAndAlignsMessageId`、`publishFallsBackFromNotOwnerAndCachesOwner`、`publishTopicNotExistThrowsServiceException`、`allNodesUnreachableThrowsConnectionException` | 完整 |
| 3 | 订阅向所有节点广播并汇总 owner | `MQClient.subscribe:105-145` | `subscribeBroadcastsSamePayload`、`subscribeRollsBackOnGroupNotExist`、`subscribeDefaultGroupAndInvalidFilter` | 完整 |
| 4 | 阻塞式消费 | `MQClient.consume:161-200` | `consumeDecodesMessageAndFillsPosition`、`consumeEmptyMovesToNextOwner`、`consumeWaitsUntilMessageArrives`、`consumeThrowsWhenSubscriptionGone` | 完整 |
| 5 | 确认路由 | `MQClient.ack:208-220` | `ackGoesBackToDeliveryNode`、`unknownPositionAckBroadcastsAndIgnoresErrors`、`autoAckDoesNotRecordDeliveryAndStillAcks` | 完整 |
| 6 | 退订与生命周期 | `unsubscribe:229-240`、`close:243-258` | `unsubscribeIsIdempotentOnServerAndRejectsUnknownId`、`closeIsIdempotentAndBlocksApis` | 完整 |
| 7 | 并发安全 | `MQSubscription`/`MQOwnershipCache`/`ConcurrentHashMap` | `concurrentConsumersGetUniquePositions`（场景 1）；场景 2「关闭与调用并发」无用例 | **部分** |

### 2.3 `f_mq` / protocol（change: add-fmq-metrics-and-delay）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 主题延迟字段 | `MQTopicMeta.delayingMs:29` | `MQPayload_test.topicMetaAndAssignmentCarryDelaying`、`MQAssignment_test.allocateKeepsDelaying`、`MetaSyncer_test.registerTopicKeepsDelayingInAssignmentAndBroadcast` | 完整 |
| 2 | messageId 发布时间解析 | `MQMessageRecord.publishTime:104-129` | `publishTimeParsesStandardMessageId`、`publishTimeRejectsNonStandardMessageId`（UTC 语义未锁定） | **部分** |
| 3 | 统计请求载荷 | `MQProtocol.stats` | `MQProtocol_test.statsRequestUsesRegisterAndInternalKind` | 完整 |

### 2.4 `f_mq` / protocol（change: fix-fmq-verify-followups）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | BODY 容器类型的编解码与过滤 | `MQMessageRecord`、`MQFilter` | `MQMessageRecord_test.containerBodiesRoundtrip`、`emptyContainerBodiesRoundtrip`、`MQFilter_test.containerBodiesSupportPathEvaluation` | 完整 |

### 2.5 `fmq` / queue-storage（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 队列目录布局与本机队列归属 | `QueueManager.cj` | `QueueManager_test.onlyLocalQueuesAreCreated` | 完整 |
| 2 | 追加返回位置且单调 | `QueueLog.append` | `appendThenReadAtReturnsSameBytes`、`everyAppendIsImmediatelyReadable`、`rotationResetsOffsetAndIncrementsSequence` | 完整 |
| 3 | 重启永不续写旧段 | `QueueLog` 打开流程 | `restartOpensNewSegmentAndKeepsOldBytes` | 完整 |
| 4 | 按位置顺序读取与有界快照 | `QueueLog.stream` | `streamIsSnapshotOfCreationTime`、`readerSkipsPreallocationAndStopsAtEnd` | 完整 |
| 5 | 有效长度以段元数据为准 | `QueueLog.size` | `sizeUsesSegmentMetadata` | 完整 |
| 6 | 本机队列轮转选择 | `QueueManager.pickQueue` | `pickQueueRotatesEvenly`、`topicWithoutLocalQueueHasNoPick` | 完整 |
| 7 | 消费位点持久化 | `CursorStore.cj` | `CursorStore_test`（6 例） | 完整 |
| 8 | 主题删除清理 | `QueueManager.closeTopic`、`ConsumeService.removeTopic` | `closeTopicKeepsOrDeletesFiles`、`removeAllOfDeletesWholeTopic`、`MQCommandExecutor_test.deregisterTopicDeletesFilesAndMetadata` | 完整 |
| 9 | 死信独立存储 | `DeadLetterQueue.cj` | `DeadLetterQueue_test`（5 例） | 完整 |
| 10 | 段 TTL 清理 | `LogCleaner.cj` | `LogCleaner_test`（4 例） | 完整 |

### 2.6 `fmq` / consume-semantics（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 订阅匹配规则 | `MQMatcher.cj` | `MQMatcher_test`（6 例）、`ConsumeService_test.filterRestrictsDelivery` | 完整 |
| 2 | 组内不重复消费 | `GroupCursor.next` | `ConsumeService_test.sameGroupDoesNotDuplicate`、`GroupCursor_test.recordAssignedToOtherSubscriber` | 完整 |
| 3 | 连续确认前缀推进 | `GroupCursor.advance` | `sequentialDeliveryAdvancesCommitted`、`outOfOrderAckKeepsHole` | 完整 |
| 4 | 超时重投 | `GroupCursor.sweep/next` | `timeoutAllowsRedelivery`、`sweepReleasesInactiveOwner` | 完整 |
| 5 | 死信判定与按组隔离 | `GroupCursor.writeDeadLetter` | `deliveryOverThresholdGoesToDeadLetter`（超阈值、条目字段）；「组间隔离」场景无用例 | **部分** |
| 6 | 自动确认 | `GroupCursor` autoAck 分支 | `autoAckAdvancesWithoutExplicitAck`、`ConsumeService_test.autoAckSubscriptionNeedsNoAck` | 完整 |
| 7 | 确认归属校验 | `GroupCursor.ack` | `ackChecksOwnership`、`ConsumeService_test.ackChecksSubscriptionOwnership` | 完整 |
| 8 | 无匹配订阅者时暂停 | `GroupCursor.next` unmatched 标记 | `unmatchedRecordIsSkippedAndCommitted`、`ConsumeService_test.unregisterStopsDeliveryForSubscription` | 完整 |
| 9 | 订阅注销释放已分配记录 | `GroupCursor.release`、`MQServer.cleanupSubscribers` | `releaseReturnsRecordToGroup`、`ConsumeService_test.releaseReturnsDeliveryToGroup`；「连接断开清理」场景无用例 | **部分** |
| 10 | 至少一次投递与重启恢复 | `CursorStore` + `GroupCursor` | `GroupCursor_test.restartRedeliversOnlyUnacked`、`MQServer_test.restartRedeliversOnlyUnacked` | 完整 |
| 11 | 并发安全 | `GroupCursor` 锁 | `concurrentNextAndAckProduceUniquePositions` | 完整 |

### 2.7 `fmq` / metadata-cluster（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 队列轮转分配 | `MQAssignment.cj` | `MQAssignment_test`（6 例，含 spec 示例逐字复现） | 完整 |
| 2 | 元数据目录与原子写 | `MetaStore.cj`、`MQFileNames.cj` | `atomicWriteSurvivesStaleTmp`、`MQFileNames_test`（4 例） | 完整 |
| 3 | 元数据持久化与内存索引 | `MetaStore.cj` | `persistenceReloadsEverything`、`duplicateAndConflictHandling`、`corruptedFilesAreSkipped` | 完整 |
| 4 | 元数据全量复制 | `MetaSyncer.broadcast/applyRemote` | `registerTopicAllocatesAndBroadcasts`、`registerGroupRequiresTopicAndBroadcasts`、`deregisterTopicAndGroup`、`remoteApplyIsIdempotentAndKeepsFirst` | 完整 |
| 5 | 启动期与恢复期同步 | `MetaSyncer.syncFromPeers`、`NodeRegistry` | `startupSyncMergesSnapshot`、`startupSyncWithAllPeersDownKeepsLocal`、`NodeRegistry_test.revivalTriggersResyncOnlyOnce` | 完整 |
| 6 | 节点表与身份 | `NodeRegistry.cj` | `NodeRegistry_test`（7 例） | 完整 |
| 7 | 备份副本复制 | `BackupReplicator.cj`、`MQCommandExecutor.onBackup` | `BackupReplicator_test`（7 例）、`backupPayloadOnlyWritesCopy` | 完整（定时器停止未断言，见 S8） |

### 2.8 `fmq` / server-runtime（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 服务端配置项与默认值 | `MQConfig.cj` | `MQConfig_test.allConfigSemantics`（30 个断言） | 完整 |
| 2 | 启动期校验 | `MQConfig.validate`、`NodeRegistry` | `Main_test.serverStartupValidationFailureReturnsTwo`、`NodeRegistry_test.invalidSelfIndexRejected` | 完整 |
| 3 | 备份副本并发安全 | `BackupStore.cj` | `BackupStore_test`（3 例，含并发 close 竞态） | 完整 |
| 4 | 子命令分发 | `main.cj:36-69` | `Main_test`（5 例） | 完整 |
| 5 | 命令处理矩阵 | `MQCommandExecutor.dispatch` | `MQCommandExecutor_test`（19 例） | 完整 |
| 6 | 启动装配与关闭 | `MQServer.cj` | `bindAcceptPublishSubscribeAck`、`restartRedeliversOnlyUnacked`（同端口重建，覆盖「关闭后可重新绑定」） | 完整 |
| 7 | 断链清理 | `MQServer.cleanupSubscribers:157-169` | **无**（全仓测试中 `isDisconnected`/`disconnect` 命中 0） | **缺失** |
| 8 | 端到端可用性 | `MQServer` + `f_net` | `MQServer_test`（5 例）、`scripts/mq_e2e.sh`（三节点 100 条不重不漏） | 完整 |

### 2.9 `fmq` / manager-cli（change: add-fmq-message-queue）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 参数解析 | `MQManagerArgs.cj` | `MQManagerArgs_test`（5 例） | 完整 |
| 2 | 六个管理子命令 | `MQManager.cj` | `MQManager_test.sixSubcommandsSucceedAndMutateState` 等 8 例 | 完整 |
| 3 | 输出渲染 | `MQManagerOutput.cj` | `MQManagerOutput_test`（4 例） | 完整 |
| 4 | 连接失败语义 | `MQManager.connectionFailed` | `connectionFailureReturnsOne`、`statsConnectionFailureReturnsOne`、`MQServer_test.managerConnectionFailureReturnsOne` | 完整 |
| 5 | 与服务端语义一致 | `MQManager` + `MQCommandExecutor` | `MQServer_test.managerCommandsAgainstRunningServer` | 完整 |

### 2.10 `fmq` / consume-semantics（change: add-fmq-metrics-and-delay）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 延迟投递 | `GroupCursor.isDue:421-431` | `delayedRecordWaitsUntilDue`、`delayedTopicBlocksHeadOfLine`、`delayedRecordSurvivesCursorReopen`、`nonStandardMessageIdDeliversImmediately`、`delayedRecordNotAssignedToOtherSubscriberEarly` | 完整 |

### 2.11 `fmq` / manager-cli（change: add-fmq-metrics-and-delay）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 统计查询子命令 | `MQManager.stats` | `MQManager_test.registerTopicWithDelayingAndStats` | 完整 |
| 2 | 主题延迟定义参数 | `MQManager.registerTopic` 的 `delaying=` 解析 | `invalidDelayingReturnsTwo`、`MetaSyncer_test.registerTopicRejectsNegativeDelaying` | 完整 |

### 2.12 `fmq` / metadata-cluster（change: add-fmq-metrics-and-delay）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 延迟元数据的持久化与复制 | `MetaStore`、`MQAssignment`、`MetaSyncer` | `MQPayload_test.topicMetaAndAssignmentCarryDelaying`、`MQAssignment_test.allocateKeepsDelaying`、`MetaSyncer_test.registerTopicKeepsDelayingInAssignmentAndBroadcast` | 完整 |

### 2.13 `fmq` / metrics（change: add-fmq-metrics-and-delay）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 指标口径 | `MQMetrics.cj`、`ConsumeService.stats` | `GroupCursor_test.metricsCountDeliveryAckAndRedelivery`、`metricsCountDeadLetter`、`ConsumeService_test.statsReportsBacklogLagAndCounters` | 完整 |
| 2 | 统计查询 | `ConsumeService.stats` | `statsUnknownTopicReturnsEmpty`、`statsWithoutTopicListsAllLocalTopics`、`statsAllTopicsAndFiltering`、`statsDoesNotCreateCursorOrChangeLog`、`statsEmitsEmptyGroupRow` | 完整 |

### 2.14 `fmq` / manager-cli（change: fix-fmq-verify-followups）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 子命令错误路径的稳定契约 | `MQManager.printError` | `invalidQueueNumFailsBeforeSending`、`invalidDelayingReturnsTwo`、`connectionFailureReturnsOne`、`MQManagerOutput_test.errorUsesStablePrefix` | 完整 |

### 2.15 `fmq` / metadata-cluster（change: fix-fmq-verify-followups，MODIFIED）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 队列轮转分配（含远端推进） | `MetaSyncer.applyRemote:123-131` | `remoteApplyAdvancesRoundRobinPointer`、`MQAssignment_test`（6 例） | 完整 |
| 2 | 备份副本复制（含定时 flush/关闭排空） | `BackupReplicator.cj` | `batchOfSixtyFourTriggersImmediately`、`timerFlushesBeforeBatchIsFull`、`closeFlushesPending`、`fullQueueDropsWithoutBlocking`、`onePeerFailureDoesNotBlockOthers` | 完整 |

### 2.16 `fmq` / queue-storage（change: fix-fmq-verify-followups）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 记录边界格式与文档化 | `QueueLog.cj` 的 `[4B 大端长度][记录]` | `truncatedEntryIsRejected`、`unknownSegmentThrows`、`readerSkipsPreallocationAndStopsAtEnd` | 完整 |

### 2.17 `fmq` / server-runtime（change: fix-fmq-verify-followups）

| # | Requirement | 实现 | 用例 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | host 解析归属 | `f_mq/base/MQHost.cj` | `MQHost_test`（2 例）；`fmq/src` 非测试源码无 `f_mq.client` 引用（已复核） | 完整 |
| 2 | 备份存储关闭并发安全 | `BackupStore.cj` | `BackupStore_test`（并发 append 单实例、关闭前写入可读回、关闭后写入静默丢弃） | 完整 |

### 2.18 矩阵汇总

| 分类 | 数量 | 明细 |
| --- | --- | --- |
| Requirement 总数 | 74（含 2 条 MODIFIED 增量） | 17 个 spec 文件 |
| 完整覆盖 | 69 | — |
| 部分覆盖 | 4 | client「并发安全」、consume「死信按组隔离」、consume「连接断开清理」、protocol「messageId 发布时间解析」 |
| **有实现无用例** | **1** | server-runtime「断链清理」（`MQServer.cj:157`） |
| **无用例且无实现** | **0** | — |
| **文档承诺但代码缺失** | **0** | 全部文档偏差均为「文档滞后于实现」，无相反方向 |

---

## 三、文档-实现不一致（逐条核对结果）

| # | 文档位置 | 文档表述 | 实现事实 | 结论 | 严重度 |
| --- | --- | --- | --- | --- | --- |
| 1 | `f_mq/doc/详细设计.md:138` | ack 载荷：`subscribedId, segmentedIndex, segmentedOffset` | `MQAckPayload.cj:29` 含 `queueIndex`，构造器四参（`:35`） | 文档缺 `queueIndex` | 一般 |
| 2 | `f_mq/doc/详细设计.md:137` | `MQConsumeResult`：`segmentedIndex, segmentedOffset, record` | `MQConsumeResult.cj:29` 含 `queueIndex` | 文档缺 `queueIndex` | 一般 |
| 3 | `f_mq/doc/详细设计.md:490` | `ack(subscribedId, segmentedIndex, segmentedOffset)` | `MQClient.cj:208` 为四参含 `queueIndex` | 文档与实现/README 不一致 | 一般 |
| 4 | `f_mq/doc/详细设计.md:253-256` | `MQTopicMeta`：`topic`、`queueNum` | `MQTopicMeta.cj:29` 另有 `delayingMs` | 文档缺延迟字段 | 一般 |
| 5 | `f_mq/doc/详细设计.md:276-281` | `MQMessage`：`topic/tags/body/segmentedIndex/segmentedOffset` | `MQMessage.cj:36` 另有 `queueIndex` | 文档缺 `queueIndex` | 一般 |
| 6 | `f_mq/doc/详细设计.md:314-326` | `MQMessageRecord` 成员表无 `publishTime` | 实现有（`MQMessageRecord.cj:104`），§5.11a:458 有补充说明 | 成员表滞后（补充章节已覆盖） | 建议 |
| 7 | `f_mq/doc/spec/add-fmq-message-queue/tasks.md:156-161` | 11.1–11.6 六项未勾选 | 六项均已落地（见下） | 追踪产物滞后 | 一般 |
| 8 | `fmq/README.md:37` | 备份写入在「队列满**或关闭阶段**」丢弃并记 WARN | 队列满记 WARN（`BackupReplicator.cj:72`）；关闭阶段静默返回（`BackupStore.cj:44-47`），同文件 L111-112 亦如此表述 | README 内部自相矛盾 | 建议 |
| 9 | `f_mq/README.md:127` | 端到端脚本位于「`fmq` 的 `scripts/mq_e2e.sh`」 | 脚本位于仓库根 `scripts/mq_e2e.sh`，`fmq/` 下无 `scripts/` | 路径表述不准（`README_en.md:144-145` 同） | 建议 |

`tasks.md` 六项完成情况的实测证据：

| 任务 | 声称未完成 | 实际证据 |
| --- | --- | --- |
| 11.1 补 `MQManager_test.cj` | 未勾选 | 文件存在，8 个用例覆盖六子命令正常/错误路径 |
| 11.2 补 BODY 容器矩阵 | 未勾选 | `MQMessageRecord_test.cj:106-141`、`MQFilter_test.cj:83-106` |
| 11.3 补备份定时 flush 与并发关闭 | 未勾选 | `BackupReplicator_test.cj:111-129`、`BackupStore_test.cj:117-165` |
| 11.4 消除 `fmq → f_mq.client` | 未勾选 | `fmq/src` 非测试源码 grep `f_mq.client` = 0 命中 |
| 11.5 文档化 4 字节前缀 | 未勾选 | `f_mq/doc/详细设计.md:102-104`、`fmq/doc/详细设计.md:314-317` |
| 11.6 修复远端分配不推进指针 | 未勾选 | `MetaSyncer.cj:123-131`、`MetaSyncer_test.cj:194-206` |

---

## 四、发现

### [一般] G1 断链清理整条 Requirement 零用例（含「连接断开清理」场景）

- **位置**：`fmq/src/server/MQServer.cj:157-169`（`cleanupSubscribers`）、`fmq/src/server/MQServer.cj:117`（2s 定时器注册）
- **现象**：`cleanupSubscribers` 遍历 `subscribers.infos()`，对 `isDisconnected()` 的订阅执行 `consume.releaseSubscription` + `subscribers.unregister`。全仓 `*_test.cj` 对 `isDisconnected` / `disconnect` 的引用为 **0**，`cleanupSubscribers` 本身为 `private` 且无用例触达。
- **对应规格**：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/server-runtime/spec.md`「断链清理」（Scenario：连接关闭后订阅消失、同组其它订阅者取到被释放消息）；`.../consume-semantics/spec.md`「订阅注销释放已分配记录」的 Scenario「连接断开清理」。
- **影响**：这是 at-least-once 语义的关键兜底路径——若清理逻辑失效，断线订阅会永久占住记录，同组消费者永远取不到，形成静默的消息停滞；而现有全部用例都无法发现。且该路径涉及 `try/catch` 吞掉异常后仅记 WARN，错误会被完全隐藏。
- **建议**：为 `SubscriberRegistry`/`MQServer` 增加可注入的连接状态（或把 `cleanupSubscribers` 提升为 `internal` 以便测试），补用例：断开一条订阅后触发清理 → 订阅消失、未决记录回到组内、同组另一订阅者可取到该条。

### [一般] G2 客户端「关闭与调用并发」场景零用例

- **位置**：`f_mq/src/client/test/MQClient_test.cj:497-531`（`closeIsIdempotentAndBlocksApis`）
- **现象**：用例仅在 `close()` **返回之后**顺序调用 `publish/subscribe/consume/ack` 并断言 4 次 `MQConnectionException`；规格要求的是一线程 `close()`、其它线程持续调用公开 API 的并发场景。
- **对应规格**：`f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md:186-190`（Scenario：关闭与调用并发）。
- **影响**：`MQClient.close()` 先 `pool.close()` 再清空订阅表（`MQClient.cj:243-258`），与在途 `consume` 的 `subscriptionOf` / `deliveries.add` 存在真实竞态窗口；顺序用例无法暴露「关闭后仍向已释放连接写入」「订阅表遍历时被清空」这类崩溃或永久阻塞。
- **建议**：补一个 `spawn` 场景：1 线程 `close()`，4 线程循环调用 `publish/consume/ack`，断言进程不崩溃、线程全部退出（有超时上限），异常类型限定为 `MQConnectionException`/`MQServiceException`。

### [一般] G3 死信「组间隔离」与「条目字节完整」未断言

- **位置**：`fmq/src/queue/GroupCursor_test.cj:245-265`（`deliveryOverThresholdGoesToDeadLetter`）
- **现象**：用例只构造单组 `g`，断言条目数、`segmentedIndex`、`subscribeGroup`、`deliverCount`；未构造 A/B 两组对照验证「A 组进死信不影响 B 组消费」，也未校验死信条目保存的**原始记录字节**可完整读回。
- **对应规格**：`fmq/doc/spec/.../consume-semantics/spec.md:87-105`（Scenario「组间隔离」「死信条目内容完整」）。
- **影响**：`GroupCursor.writeDeadLetter` 把 `record` 原样写入 `DeadLetterQueue`，若记录被截断或组名写错，现有用例（只查 `subscribeGroup` 字段与条数）无法发现；而按组隔离是「一个组卡死不影响其它组」的核心保证。
- **建议**：在同一 `QueueLog` 上挂两个组的游标，令 A 组投递超阈值后断言 B 组仍可取到同一条；并断言死信条目的 `record` 与原始记录字节逐字节相等。

### [一般] G4 详细设计的消费结果、ACK 载荷与 `MQMessage` 缺 `queueIndex`，与规格明文冲突

- **位置**：`f_mq/doc/详细设计.md:137`（`MQConsumeResult` 行）、`:138`（`ack` 行）、`:490`（`MQClient.ack` 签名）、`:276-281`（`MQMessage` 成员）
- **现象**：前两处与 §5.13 均写作 `segmentedIndex, segmentedOffset`，无 `queueIndex`；§5.3 的 `MQMessage` 也只列 `topic/tags/body/segmentedIndex/segmentedOffset`。而规格 `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md:122` 明确 `MQConsumeResult{queueIndex, segmentedIndex, segmentedOffset, record}`，`:127` 明确「`MQAckPayload` SHALL 携带 `queueIndex`」；实现 `MQClient.cj:208`、`MQConsumeResult.cj:29`、`MQMessage.cj:36`、`MQAckPayload.cj:29` 与 README `f_mq/README.md:37-38` 均为四元组。
- **影响**：详细设计是协议实现的直接依据。按该文档实现客户端会漏传队列身份，导致多队列主题下 ACK 串台（`ConsumeService.ack` 按 `payload.queueIndex` 精确 `queueOf`，缺失时为 0，会误确认 0 号队列）。规格与实现正确，风险在文档误导后续维护/移植。
- **建议**：把三处统一为 `subscribedId, queueIndex, segmentedIndex, segmentedOffset`，并在 §3.3 表中补一行说明「队列身份必填，缺失视为队列 0」。

### [一般] G5 详细设计 §5.1 的 `MQTopicMeta` 缺 `delayingMs`

- **位置**：`f_mq/doc/详细设计.md:253-256`
- **现象**：成员仅 `topic`、`queueNum`；实现 `MQTopicMeta.cj:29` 已有 `delayingMs`，构造器默认 `delayingMs: Int64 = 0`（`:33`）。规格 `f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md:5-19`（主题延迟字段）要求该字段随注册载荷传递。
- **影响**：§5.1 是「规格给定」的类型清单，缺字段会让人误以为延迟只能走 manager 侧解析、不能随 `REGISTER` 传输；实际 `MQAssignment`/`MetaSyncer`/`MetaStore` 全链路都依赖它。
- **建议**：在 §5.1 代码块补 `private var delayingMs: Int64 = 0  // 延迟投递毫秒数，0 = 不延迟`，并注明「由 add-fmq-metrics-and-delay 变更追加」。

### [一般] G6 `tasks.md` 六项遗留任务全部已完成但未勾选

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/tasks.md:156-161`
- **现象**：11.1–11.6 六项均为 `- [ ]`，逐项核对后全部已落地（证据见第三节表格）。
- **影响**：`tasks.md` 是本项目唯一的实施进度台账；6/6 失真会让后续审查反复复查已完成项（本轮即为此消耗），也会掩盖真正的新增缺口（如 G1）。
- **建议**：勾选这六项并各补一行落地说明（文件 + 用例名），使台账可作为回归清单复用。

### [建议] S1 `publishTime` 用例无法发现 UTC 补偿被移除

- **位置**：`f_mq/src/base/MQMessageRecord_test.cj:144-148`
- **现象**：唯一断言是 `time.format("yyyyMMddHHmmssSSS") == "20261018183000123456789"`。`publishTime` 的 `format` 与 `parse` 都按本地时区，若删掉 `MQMessageRecord.cj:125` 的 `+ parsed.zoneOffset`，该断言仍然通过（本地→UTC→本地是恒等变换）。
- **影响**：`§5.11a` 与 README 都声明时间戳为 UTC；在非 UTC 机器上，补偿一旦丢失会让延迟投递整体偏移一个时区（东八区晚 8 小时），而测试全绿。
- **建议**：增补断言 `time.toUnixTimeStamp() == DateTime.parse("20261018183000123456789", "yyyyMMddHHmmssSSS").toUnixTimeStamp() - zoneOffset`，或直接断言与已知 UTC 秒值相等。

### [建议] S2 详细设计 §5.5 成员表未列 `publishTime`

- **位置**：`f_mq/doc/详细设计.md:314-326`
- **现象**：`MQMessageRecord` 的成员清单只列 `encode/decode/topic/tags/body/messageId`；`publishTime` 在 §5.11a:458 有说明，但不在成员表。
- **影响**：按成员表检索会漏掉该公开方法；延迟投递与 `lagMs` 计算都依赖它。
- **建议**：在 §5.5 代码块补签名并注明「见 §5.11a」。

### [建议] S3 `fmq/README.md` 关于关闭阶段是否记 WARN 自相矛盾

- **位置**：`fmq/README.md:37` 与 `:111-112`；`fmq/README_en.md:39`
- **现象**：L37 称「备份队列满**或关闭阶段**到达的写入会被丢弃并记 WARN」；L111-112 称「`BackupStore` 关闭后到达的写入**静默丢弃**」。实现为：队列满记 WARN（`BackupReplicator.cj:72`），关闭后静默返回（`BackupStore.cj:44-47`）。
- **影响**：文档内部矛盾；规格 `fix-fmq-verify-followups/server-runtime` 只要求「安全丢弃」，故实现无误，属文档措辞问题。运维按 L37 排查会找不到 WARN 日志。
- **建议**：L37 改为「队列满时丢弃并记 WARN；关闭阶段到达的写入静默丢弃（见「已知限制」）」。

### [建议] S4 `MQClientConfig_test` 两个用例共享进程级 `Config` 且不恢复现场

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:26-43`
- **现象**：两个用例各自 `Config.set(...)`，第二个用例把 `mqClient_hosts` 置为空串后不再恢复。同模块 `MQConfig_test.cj:25-28` 已明确注释「配置是进程级全局状态，用例必须串行读写」并把全部断言塞进单用例；此处未遵循同一约定。
- **影响**：当前无 `MQClient()` 无参用例，故未实际触发；一旦新增（或测试并行度调整），会出现用例间互相覆盖的偶发失败。
- **建议**：合并为单用例（与 `MQConfig_test` 一致），或在 `finally` 中恢复原值。

### [建议] S5 `FakeTransport_test.cj` 无任何 `@TestCase`

- **位置**：`fmq/src/cluster/FakeTransport_test.cj:23`
- **现象**：文件仅定义 `protected class FakeTransport <: MQNodeTransport` 测试替身，`@TestCase` 计数为 0。
- **影响**：会被「空测试文件」类扫描误报（本轮即命中）；作为测试支持代码放在 `*_test.cj` 中，语义不清晰。
- **建议**：改名为 `FakeTransportTestSupport.cj` / `TestTransport.cj`（仍可被 `_test.cj` 引用），或在其文件头注释注明「本文件为测试替身，不含用例」。

### [建议] S6 五处 `@Assert(true)` 建议改为等值断言

- **位置**：`MQMessageRecord_test.cj:178`、`MQProtocol_test.cj:47`、`MQProtocol_test.cj:105`、`MQClient_test.cj:79`、`MQCommandExecutor_test.cj:132`
- **现象**：`match` 分支命中后写 `@Assert(true)`，靠兜底 `case _ => @Assert(false)` 成立。语义正确，但对读者是「恒真断言」，容易在审查中被误判（本轮逐条核对才确认有效）。
- **影响**：纯可读性；不影响正确性。
- **建议**：改为 `@Assert(MQProtocol.kindOf(msg) == MQPayloadKind.Record)` 一类的等值断言，或在分支内断言关键字段，去掉兜底 false 分支。

### [建议] S7 测试固定使用 `/tmp/fmq_test_*` 与固定起始端口，同机并行会互相干扰

- **位置**：`fmq/src/meta/MetaStore_test.cj:28`、`fmq/src/queue/QueueLog_test.cj:26`、`QueueManager_test.cj:27`、`CursorStore_test.cj:28`、`DeadLetterQueue_test.cj:29`、`GroupCursor_test.cj:50`、`ConsumeService_test.cj:53`、`MQCommandExecutor_test.cj:45`、`MQServer_test.cj:87/137/159/213`；端口分配器见 `MQServer_test.cj:26-42`（`AtomicInt64(27000)`）
- **现象**：目录为固定绝对路径（夹具构造时 `remove` 重建），端口从固定基数递增；`freePort()` 仅用 `TcpSocket` 探测后立即 `close()`，未真正 bind/listen 保留。
- **影响**：同一台机器并行跑两套测试（或与旧进程残留）会互相删除目录、抢占端口；`freePort` 存在「探测通过→服务绑定前被抢占」的 TOCTOU 窗口，表现为偶发 `bind failed`。
- **建议**：目录名拼接进程号/随机后缀；`freePort` 改为「创建并保持监听直到交给 `MQServer`」或允许由环境变量指定端口段。

### [建议] S8 备份复制未断言「关闭后定时器停止」

- **位置**：`fmq/src/cluster/BackupReplicator_test.cj:101-108`（`closeFlushesPending`）、`:110-129`（`timerFlushesBeforeBatchIsFull`）
- **现象**：规格 `fix-fmq-verify-followups/metadata-cluster`「备份副本复制」要求「关闭时 SHALL 停止定时器并做最后一次 flush」。现有用例断言了 flush 发出的记录数，但 `closeFlushesPending` 未先 `start()`（无定时器可停），`timerFlushesBeforeBatchIsFull` 只在 `finally` 中 `close()` 而未断言关闭后不再发送。
- **影响**：若 `close()` 忘记取消定时器，关闭后仍会有一次空 flush（或对已关存储写入），现有用例无法发现。
- **建议**：在 `timerFlushesBeforeBatchIsFull` 的 `finally` 中 `close()` 后记录 `sentCount`，再等待 >100ms 断言计数不再增长。

### [建议] S9 `f_mq/README` 的端到端脚本路径表述不准

- **位置**：`f_mq/README.md:127`、`f_mq/README_en.md:144-145`
- **现象**：写作「见 `fmq` 的 `scripts/mq_e2e.sh`」，链接指向 `../fmq`；实际脚本位于仓库根 `scripts/mq_e2e.sh`，`fmq/` 下不存在 `scripts/` 目录（`fmq/README.md:118` 的 `cd .. && ./scripts/mq_e2e.sh` 才是正确用法）。
- **影响**：读者按链接进入 `fmq/` 后找不到脚本。
- **建议**：改为「见仓库根 `scripts/mq_e2e.sh`」，链接指向 `../scripts/mq_e2e.sh`。

---

## 五、本轮统计

| 项目 | 数值 |
| --- | --- |
| 审查测试文件 | 39 |
| 审查 `@TestCase` | 260 |
| 审查规格 Requirement | 74（17 个 spec.md，含 2 条 MODIFIED） |
| 审查文档 | 4 个 README + 2 份详细设计 + tasks.md/verify-report/backlog |
| 空测试 / 禁用用例 / 空实现 / TODO | 0 / 0 / 0 / 0 |
| 恒真断言（有语义） | 5（全部合法） |
| 完整覆盖 Requirement | 69 |
| 部分覆盖 Requirement | 4 |
| 有实现无用例 | 1 |
| 无用例且无实现 | 0 |
| 文档-实现不一致 | 9 处（均为文档滞后，无代码缺失） |
| **[严重]** | **0** |
| **[一般]** | **6**（G1–G6） |
| **[建议]** | **9**（S1–S9） |
| 合计 | 15 |

---

## 六、总评

测试工程质量整体良好，与「规格驱动 + 逐条验收」的工程纪律一致：

1. **无造假型测试**。260 个用例全部含实质断言，无 `@Ignore`、无注释掉的用例、无空函数、无 `NotImplemented`，5 处 `@Assert(true)` 均是有兜底分支的 match 断言。这一点在前几轮已归档的 C/W 系列修复之后依然保持，说明测试纪律未被破坏。
2. **覆盖密度高且有针对性**。核心风险点均有专门用例：段失效恢复（`removedCommittedSegmentRecoversToOldestSurvivor`）、大记录临时文件形态（16 KiB 帧往返）、备份并发关闭（4 线程 + 主线程 close）、远端轮转指针推进（11.6 修复的回归用例）、游标并发（`concurrentNextAndAckProduceUniquePositions`）。`MQServer_test` 用真实 TCP 覆盖了 bind/publish/subscribe/ack 与重启重投，`scripts/mq_e2e.sh` 再做三节点端到端，层次合理。
3. **规格-实现-用例三段可追踪**，74 条 Requirement 中 69 条有直接断言，仅 1 条（断链清理）零用例。这条缺口值得优先补：它是「断线后不丢消息」的最后一道兜底，且异常被 `try/catch` 吞成 WARN，属于「坏了也看不出来」的类型。
4. **文档滞后是本轮的主要问题面**。9 处不一致全部是「实现正确、文档没跟上」（`queueIndex` 四处、`delayingMs`、`publishTime`、`tasks.md` 六项、README 措辞），没有一处是「文档承诺、代码没做」。其中 G4 最值得修：详细设计缺 `queueIndex` 与规格明文冲突，而队列身份正是多队列 ACK 不串台的前提。
5. **测试基建有两个可改进点**：固定 `/tmp` 路径与固定端口段限制并行；`freePort` 的探测不保留存在 TOCTOU 窗口。当前串行执行下不构成问题，但会在 CI 并行化时集中暴露。

结论：R6 无严重问题，建议在归档前处理 G1（补断链清理用例）与 G4/G5（详细设计补齐 `queueIndex`、`delayingMs`），其余可作为后续清理项。
