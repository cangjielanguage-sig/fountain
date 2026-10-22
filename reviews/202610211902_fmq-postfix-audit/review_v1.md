# R1: 复审 f_mq 全模块（base / client / exception / 门面 + 协议、客户端规格与详细设计）

审查时间：2026-10-21

### 审查范围

代码（HEAD `22c13ec4`，只读）：

- `f_mq/src/base/**`：`MQConstants.cj`、`MQFilter.cj`、`MQGroup.cj`、`MQHost.cj`、`MQMessageRecord.cj`、`MQProtocol.cj`、`MQTags.cj`、`MQTopic.cj`
- `f_mq/src/base/model/**`：`MQMessage.cj`、`MQMessageContent.cj`、`MQSubscribeGroupMeta.cj`、`MQTopicMeta.cj`
- `f_mq/src/base/payload/**`：`MQBlob.cj`、`MQConsumeResult.cj`、`MQDeregisterPayload.cj`、`MQInternalMessage.cj`、`MQMetaSnapshot.cj`、`MQMetaTombstone.cj`、`MQTopicAssignment.cj`、`MQResult.cj` 等 14 个载荷类
- `f_mq/src/client/**`：`MQClient.cj`、`MQClientConfig.cj`、`MQNodePool.cj`、`MQOwnershipCache.cj`、`MQSubscription.cj`
- `f_mq/src/exception/MQException.cj`、`f_mq/src/f_mq.cj`
- 测试：`f_mq/src/base/*_test.cj`（6 个文件）、`f_mq/src/client/MQClientConfig_test.cj`、`MQOwnershipCache_test.cj`、`f_mq/src/client/test/{MQClient_test,MQNodePool_test,LogCapture_test,MQStubServer}.cj`、`f_mq/src/exception/MQException_test.cj`、`f_mq/src/test/Facade_test.cj`（共 128 个 `@TestCase`）

文档/规格：

- `f_mq/README.md`、`f_mq/README_en.md`、`f_mq/doc/详细设计.md`、`f_mq/doc/开发计划.md`
- `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/specs/f-mq/{protocol,client}/spec.md`（本轮权威规格）、同变更 `tasks.md`、`verify-report.md`
- 历史规格：`f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/{protocol,client}/spec.md`、`f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md`、`f_mq/doc/spec/fix-fmq-verify-followups/specs/f-mq/protocol/spec.md`

说明：`openspec/specs/` 下当前只有 `docs/spec.md`，不存在 `openspec/specs/f-mq/**`（f-mq 规格尚未落到主 specs 目录，仅存在于归档变更中）。本轮以归档变更的 delta 规格为验收依据。

---

## 一、文档/规格承诺 vs 代码（逐项核对结果）

### 1.1 字段与默认值

| 文档承诺 | 代码实际 | 结论 |
|---|---|---|
| `MQTopicMeta(topic, queueNum, delayingMs=0)`（详细设计 §5.1:258-262） | `MQTopicMeta.cj:23-31`，默认 0，具名参数 `delayingMs!` | 一致 |
| `MQSubscribeGroupMeta(topic, subscribeGroup)`（§5.2:270-275、§3.3:129） | `MQSubscribeGroupMeta.cj:26-31`，另有 `revision`/`origin` | **漂移**（见 G4） |
| `MQMessage` 六字段 + `get<T>`（§5.3:282-294） | `MQMessage.cj:21-32`，一致；`body` 的 `None` 语义见 G-建议 9 | 基本一致 |
| `MQMetaSnapshot(topics, groups, nextStartNode)`（§5.10:419-425） | 另有 `tombstones`/`revision`/`tombstoneFloor`（`MQMetaSnapshot.cj:23-36`），§4.1:223 又列全了 | **漂移 + 文档自相矛盾**（见 G3） |
| `MQTopicAssignment` 七字段 + `owner()`（§5.9:404-413） | `MQTopicAssignment.cj:18-54` | 一致 |
| `MQSubscription.cursor: Int64`（§5.14:535） | `AtomicInt64`（`MQSubscription.cj:38`） | **漂移**（见 G-建议 2） |
| 门面 = `base.*` + `exception.*` + `client.*`（§4.4:249） | 另有 `base.model.*`、`base.payload.*`（`f_mq.cj:23-27`） | **漂移**（见 G-建议 1） |
| 错误码 0–11 数值（README:70-83、§3.5） | `MQConstants.cj:24-35` | 一致（`MQErrorCode_test.constantsAreStable` 覆盖） |
| `MQConfigKey.CLIENT_HOSTS="mqClient_hosts"` | `MQConstants.cj:71` | 一致 |
| `MQInternalKind` = `metaSync`/`backup`/`stats` | `MQConstants.cj:76-78` | 一致 |

### 1.2 签名

| 文档承诺 | 代码实际 | 结论 |
|---|---|---|
| `MQClient` 七个公开方法及默认值（README:28-43、§5.13:501-512） | `MQClient.cj:52-60,70,124,215,302,368,397,414` | 一致 |
| `MQProtocol` 构造/解析清单（§5.11:431-461） | `MQProtocol.cj:34-197`，含 `publish(record, id!)`、5 个 `metaSync`、`stats` | 一致 |
| `MQMessageRecord` 六个静态方法（§5.5:322-336） | `MQMessageRecord.cj:39-138`；`publishTime` 只在 §5.11a:476 描述，未进 §5.5 签名块 | 基本一致（建议补） |
| `MQBytes.fromData(data): ?Array<Byte>`（§5.5:346） | `MQMessageRecord.cj:192` | 一致 |
| `MQNodePool.init(hosts, build!, nowMs!)`、`aliveNodes` 返回全部下标（§5.15:544-548） | `MQNodePool.cj:49-69,160-165` | 一致（但 `开发计划.md:227-230` 仍写「过滤」/「缓存同一实例」） |
| `MQOwnershipCache` 三方法（§5.16:558-562） | 另有 `clear()`（`MQOwnershipCache.cj:58`） | 漂移（见 G-建议 2） |
| 规格示例 `MQTopicMeta("/t", 2, 61000)`、`MQTopicAssignment("/t", 2, 0, [0, 1], 61000)`（add-fmq-metrics-and-delay spec:20-28） | 第三/第五参数是 `delayingMs!` 具名参数（`MQTopicMeta.cj:26`、`MQTopicAssignment.cj:33`） | **漂移**（照抄无法编译，见 G9） |

### 1.3 行为

| 文档承诺 | 代码实际 | 结论 |
|---|---|---|
| publish：本地校验 → 编码 → 选 owner → `NOT_OWNER` 换节点；全不可达抛 `MQConnectionException`（README:47-48、§6.2） | `MQClient.cj:70-115`，另有明文规定「全部 NOT_OWNER → `MQServiceException(8)`」 | 一致 |
| subscribe：UUID、广播全部节点、只记接受者、错误回滚并抛（§6.3） | `MQClient.cj:124-206` | 一致 |
| consume：轮转、空轮询 200ms、全 owner 不可达抛错、解码失败抛 INTERNAL（§6.4、client spec 115-158） | `MQClient.cj:215-294`，文案含 `(tried nodes [..])` | 一致 |
| ack：命中投递节点、成功后删映射、未命中广播、忽略 `ACK_UNKNOWN`（§6.5） | `MQClient.cj:302-359` | 一致 |
| unsubscribe：全部成功才删本地订阅；失败保留（§6.6） | `MQClient.cj:368-394` | 一致 |
| close 幂等、关闭后业务 API 抛 `MQConnectionException`（§5.13、§6.6） | `MQClient.cj:397-416,428-432` | 一致 |
| 线程安全：`deliveries.addIfAbsent` 原子认领（§6.7） | `MQClient.cj:243-250` | 一致 |
| `asPayload<T>` 用**严格转换**（`DEFAULT_DATA_FLAG`），且 `T` 为标量/字符串时按对应 `Data` 子类型匹配（§5.11:467-468、protocol spec:78-80） | `MQProtocol.cj:154-169`：非 `SimpleDataObject` 一律 `None`，转换用 `SILENCE` | **相反/缺失**（严重，见 S1） |
| 节点连接自愈：关闭后 `clientOf` 抛错、不建新连接（client spec:282-285） | `MQNodePool.cj:86-88,168-171` 顺序场景成立，并发场景不成立 | **部分相反**（见 G1） |
| 订阅组名/tags 校验规则（protocol spec:148-169） | `MQGroup.cj`、`MQTags.cj` 存在且被 `MQClient` 与 `fmq` 调用 | 一致，但**模块文档完全未记录**（见 G5）与字符集判定不全（见 G12） |
| `publishTime` 按 UTC 解析、非标准 ID 返回 None、未来时间戳交给服务端兜底（§5.11a:476-478） | `MQMessageRecord.cj:105-130` | 一致（用例弱，见 G16） |

---

## 二、Requirement / Scenario → 用例矩阵

判定：✅ 直接或等价用例；⚠ 弱断言/仅部分覆盖；❌ 无用例；➖ 本模块外（他轮次）或冗余场景。

### 2.1 `f-mq/protocol`（fix-fmq-full-audit 版，32 个 Scenario）

| # | Scenario | 用例 | 判定 |
|---|---|---|---|
| 1 | 常规记录原样往返 | `recordTravelsByteForByte`、`consumeResultRoundtripsAtThresholds`(0/4096) | ✅ |
| 2 | 大记录走临时文件仍可还原（4096/16K/1M） | `consumeResultRoundtripsAtThresholds`、`decodingLargeRecordLeavesNoTempFiles` | ✅ |
| 3 | 大记录出现在消费响应中（帧编解码） | `consumeResultRoundtripsAtThresholds`（走 `DefaultCodec`，未走 `Message` 帧） | ✅（等价） |
| 4 | 大记录出现在内部信封中（>4KB backup） | `backupAndDeadLetterRoundtripLargeRecords` | ✅ |
| 5 | 非字节载荷不伪装成空消息 | `mqBytesReadsByteBlock`、`dataNoneIsNotAnEmptyBlob`、`nonFileStreamIsNotTreatedAsEmpty` | ✅ |
| 6 | 解码失败不被解释为无消息 | `asConsumeResultSeparatesFailureFromEmpty`、`consumeFailsOnUndecodableRecord` | ✅ |
| 7 | 标准 ID → `2026-10-18T18:30:00.123456789Z` | `publishTimeParsesStandardMessageId`（只做 format 往返，恒真） | ⚠ |
| 8 | 本地时区进程生成的 ID 仍是 UTC（Asia/Shanghai） | 无（f_protocol 侧有 `messageIdFormatsTimestampInUtc`，f_mq 侧无） | ❌ |
| 9 | 非标准 ID | `publishTimeRejectsNonStandardMessageId` | ✅ |
| 10 | 未来时间戳（+8h）→ WARN、lagMs=0 | 不在 f_mq；`GroupCursor_test`/`ConsumeService_test` 覆盖 | ➖ |
| 11 | 六类载荷分类正确 | `payloadKindsAreClassified` | ✅ |
| 12 | 内部消息的两种 kind | 被 #13 覆盖 | ➖（冗余场景） |
| 13 | 内部消息的三种 kind | `internalEnvelopeCarriesSubPayload`、`statsRequestUsesRegisterAndInternalKind` | ✅ |
| 14 | 标量载荷不变成默认对象 | `decodePayloadRejectsScalarForObjectPayload` | ✅ |
| 15 | 类型不匹配时不产出半成品 | `typeMismatchReturnsNone` | ✅ |
| 16 | 错误码文案完整 | `messagesAreNonEmptyAndUnique` | ✅ |
| 17 | 常量数值稳定 | `constantsAreStable` | ✅ |
| 18 | 每个码可达（非测试构造路径） | 无用例（本次静态核对：12 个码均有生产构造点，见 §四.3） | ❌ |
| 19 | 合法组名 | `ordinaryNamesAreValid` | ✅ |
| 20 | 非法组名 + 服务端 `INVALID_GROUP` + 无落盘 | `whitespaceAndSeparatorsAreRejected`（仅本地校验） | ⚠ |
| 21 | 默认组不受影响 | `defaultGroupIsValid`、`subscribeDefaultGroupAndInvalidFilter` | ✅ |
| 22 | 注销载荷精确匹配 | f_mq 层无（`MQDeregisterPayload.kindOf` 未测 Topic/Group 分支） | ❌ |
| 23 | 空 kind 不删组 | 服务端用例（`MQCommandExecutor_test`） | ➖ |
| 24 | 大小写与拼写错误 | 服务端用例 | ➖ |
| 25 | 空 BODY → `None` | `messageGetRejectsEmptyAndMismatchedBody` | ✅ |
| 26 | 异类对象 BODY → `None` | 同 | ✅ |
| 27 | 匹配类型 → `Some` | `messageGetSupportsScalarsAndObjects` | ✅ |
| 28 | 标量 BODY | 同 | ✅ |
| 29 | 指定 id 的发布 | `publishWithExplicitIdKeepsFrameAndRecordIds` | ✅ |
| 30 | 记录 id 与帧 id 不一致 | 同（`record-mid` vs 新 `MessageID`） | ✅ |
| 31 | 删除同步走 DEREGISTER | **无用例**：5 个 `metaSync` 重载只测 4 个 | ❌ |
| 32 | 三类 REGISTER 子载荷可区分 | `allMetaSyncOverloadsRoundtrip` | ✅ |

小计：✅ 21、⚠ 3、❌ 4、➖ 3、冗余 1。

### 2.2 `f-mq/client`（45 个 Scenario）

| # | Scenario | 用例 | 判定 |
|---|---|---|---|
| 1 | 从配置读取并保持顺序 | `configKeepsOrderAndTrimsSpaces` | ✅ |
| 2 | 配置缺失（含键名） | `emptyConfigThrowsWithKeyName`（空串近似「不存在」） | ✅ |
| 3 | 非法地址（缺端口/0/越界/空主机/非法字符） | `invalidEntryIsRejected`、`MQHostTest.rejectsInvalidEntry`；**「含非法字符」未实现也未测** | ⚠ |
| 4 | 用例隔离（结束还原配置） | `configIsRestoredAfterTest`（顺序依赖，单独运行会失败） | ⚠ |
| 5 | 发往 owner 并保持字段（10 个 tags、顺序不变） | `publishSendsRecordAndAlignsMessageId`（只 2 个 tag） | ⚠ |
| 6 | 主题不存在 | `publishTopicNotExistThrowsServiceException` | ✅ |
| 7 | 非 owner 自动换节点 | `publishFallsBackFromNotOwnerAndCachesOwner` | ✅ |
| 8 | 全部非 owner | `publishAllNotOwnerRaisesServiceException` | ✅ |
| 9 | 非法主题本地失败 | `invalidTopicFailsLocally` | ✅ |
| 10 | 非法 tags 本地失败 | `invalidTagsAndGroupFailBeforeAnyRequest` | ✅ |
| 11 | 全部节点不可达 | `allNodesUnreachableThrowsConnectionException` | ✅ |
| 12 | 返回 UUID | `subscribeBroadcastsSamePayload` | ✅ |
| 13 | 各节点同 id 同参数 | 同 | ✅ |
| 14 | 只把接受者记为 owner（节点1 `NOT_OWNER`） | **缺**（现有用例的 owner 集合均为全集或全空） | ❌ |
| 15 | 未注册订阅组回滚 | `subscribeRollsBackOnGroupNotExist` | ✅ |
| 16 | 回滚失败可观测 | **缺**（只测回滚成功） | ❌ |
| 17 | 默认组可用 | `subscribeDefaultGroupAndInvalidFilter` | ✅ |
| 18 | 解码并填位置 | `consumeDecodesMessageAndFillsPosition` | ✅ |
| 19 | 空后换 owner | `consumeEmptyMovesToNextOwner` | ✅ |
| 20 | 持续空则持续等待 | `consumeWaitsUntilMessageArrives` | ✅ |
| 21 | 订阅已失效 | `consumeThrowsWhenSubscriptionGone` | ✅ |
| 22 | 全部 owner 不可达（文案含节点） | `consumeThrowsWhenAllOwnersUnreachable` | ✅ |
| 23 | 负载不可评估 | `consumeMapsServiceErrorCode` | ✅ |
| 24 | 记录解码失败 | `consumeFailsOnUndecodableRecord`、`decodeFailureLogsPosition` | ✅ |
| 25 | 回到投递节点 | `ackGoesBackToDeliveryNode` | ✅ |
| 26 | 两队列同位置不串台 | `ackPayloadKeepsQueueIdentity` | ✅ |
| 27 | 未知位置广播 | `unknownPositionAckBroadcastsAndIgnoresErrors` | ✅ |
| 28 | 发送失败可重试（映射保留） | **缺** | ❌ |
| 29 | 服务端错误 | `ackSurfacesFailuresExceptUnknown` | ✅ |
| 30 | autoAck 订阅 | `autoAckDoesNotRecordDeliveryAndStillAcks`（「映射不增长」未断言） | ✅ |
| 31 | 退订幂等（连续两次不抛） | `unsubscribeIsIdempotentOnServerAndRejectsUnknownId`（第二次实际抛异常） | ⚠ |
| 32 | 未知 id | 同 | ✅ |
| 33 | 发送失败保留订阅 | `unsubscribePartialFailureKeepsSubscription` | ✅ |
| 34 | 关闭后可重入 | `closeIsIdempotentAndBlocksApis` | ✅ |
| 35 | 关闭后调用 | 同 | ✅ |
| 36 | 关闭与调用并发 | `closeIsSafeUnderConcurrentCalls` | ✅ |
| 37 | 多线程消费不重复 | `concurrentConsumersGetUniquePositions` | ✅ |
| 38 | 关闭与调用并发（并发章） | 同 #36 | ✅ |
| 39 | 服务端重复投递同一位置 | `sameDeliveryPositionIsClaimedOnce` | ✅ |
| 40 | 节点重启后恢复 | `closedConnectionIsRebuilt` | ✅ |
| 41 | 慢节点不阻塞其它节点 | `slowNodeDoesNotBlockOtherNodes` | ✅ |
| 42 | 并发首次建连只一条 | `concurrentFirstUseBuildsOnce` | ✅ |
| 43 | 关闭后不重建 | `lazilyBuildsAndCaches`（仅顺序，并发竞态未覆盖，见 G1） | ⚠ |
| 44 | 连接失败有日志 | `clientFailsWithPerNodeLogs` | ✅ |
| 45 | 解码失败有日志 | `decodeFailureLogsPosition` | ✅ |

小计：✅ 39、⚠ 4、❌ 3。

### 2.3 汇总

| 项 | 数量 |
|---|---|
| Scenario 总数（protocol 32 + client 45） | 77 |
| 有直接/等价用例 | 60 |
| 弱断言或仅部分覆盖 | 7 |
| 完全无用例 | 7 |
| 模块外（他轮次） | 3 |

另：**「日志 MUST NOT 输出 BODY」**（client spec:290）与 **`MQClient` 用例中的「consume 对象 BODY」**（`f_mq/doc/spec/add-fmq-message-queue/tasks.md:2.6` 已勾选）两处承诺也无对应用例，见 G17/G18。

---

## 三、空测试 / 空函数 / 占位扫描

| 检查项 | 结果 |
|---|---|
| 空 `@TestCase`（无语句） | 0（脚本遍历 128 个用例体，全部非空） |
| 无断言的用例 | 0（128/128 至少一条 `@Assert`） |
| 仅 `@Assert(true)` 的用例 | 0；有 4 处 `@Assert(true)`，均为 `match` 的合法分支且同块存在 `@Assert(false)` 反例（`MQMessageRecord_test.cj:189`、`MQProtocol_test.cj:47,105`、`MQClient_test.cj:132`） |
| `@Ignore` / 注释掉的用例 / `@Disabled` | 0 |
| `throw NotImplemented` / TODO / FIXME / XXX | 0 |
| 生产代码空函数体 | 0（`MQBlob.isEmpty`、`MQResult.isOk` 等均有实现） |
| 「仅 return」占位 | 0 |
| 被注释掉的代码块 | 0（脚本未匹配到 `// let|var|if|for|while|return|func|class|import|@`） |
| 用例总数与台账一致性 | 128，与 `tasks.md:394,410` 的 `f_mq 128/128` 一致 |

唯一「不可达代码」例外：`MQClient.cj:292-293` 在 `while (true)` 之后保留 `throw MQConnectionException("unreachable")`（注释说明为满足编译器返回类型），归入 G-建议 5。

---

## 四、死代码

### 4.1 无调用方的函数/方法（非测试代码中零引用）

| 位置 | 符号 | 说明 |
|---|---|---|
| `f_mq/src/base/payload/MQDeregisterPayload.cj:71` | `isGroup()` | 全仓零调用（服务端统一走 `kindOf()`）；`isTopic()`（`:67`）也只在 `MQPayload_test.cj:94` 被调用 |
| `f_mq/src/base/payload/MQResult.cj:35` | `isOk()` | 仅测试使用 |
| `f_mq/src/base/payload/MQConsumeResult.cj:50` | `hasMessage()` | 仅测试使用（`MQClient` 用 `record.isEmpty()`） |
| `f_mq/src/client/MQNodePool.cj:188` | `isClosed()` | 仅 `MQNodePool_test.cj:48` 使用 |
| `f_mq/src/base/MQConstants.cj:102` | `MQPayloadKind.toString()` | 生产无调用 |
| `f_mq/src/base/MQMessageRecord.cj:145,157` | `valueAt`/`decodeValues` | 私有但在同文件被调用，非死代码 |

### 4.2 无读取的字段

`f_mq/src/client/MQSubscription.cj:30-35`：`subscribedId`、`topic`、`subscribeGroup`、`tags`、`filter` 五个字段只在构造函数写入，全仓无读取点（`grep 'sub.topic' / 'sub.filter'` 均为空）。其中 `filter` 的预编译结果（`MQClient.cj:137`）因此完全失去意义——真实过滤发生在服务端（`fmq/src/server/MQCommandExecutor.cj:331` 重新 `MQFilter.compile`）。

### 4.3 仅测试使用的测试辅助

| 位置 | 符号 | 证据 |
|---|---|---|
| `f_mq/src/client/test/LogCapture_test.cj:90` | `CapturingAppender.clear()` | 编译器已告警 `warning: unused function:'clear'`（`f_mq/target/release/.test-logs/f_mq/f_mq.client.test@fountain.errlog`） |
| `f_mq/src/client/test/MQStubServer.cj:116` | `isClosed()` | 全仓无调用 |

### 4.4 未使用 import / 不可达分支 / 注释代码

- `f_mq/src/base/MQMessageRecord.cj:19`（`import std.fs.*`）、`:20`（`import std.io.SeekPosition`）：文件内无任何文件系统或 seek 调用（`MQBlob` 才需要）。
- `f_mq/src/client/MQClient.cj:292-293`：`while (true)` 之后的 `throw`。
- 注释掉的代码块：无。
- `@Deprecated` API：无。

### 4.5 错误码可达性（规格「每个码可达」的静态核对）

0–11 全部存在非测试构造点：`TOPIC_NOT_EXIST`/`GROUP_NOT_EXIST`/`INVALID_TOPIC`/`INVALID_GROUP`/`INTERNAL`/`FILTER_UNSUPPORTED_BODY`（`MQCommandExecutor.cj`）、`TOPIC_ALREADY_EXIST`/`GROUP_ALREADY_EXIST`（`MetaSyncer.cj:144,156`）、`SUBSCRIBE_NOT_EXIST`/`NOT_OWNER`/`ACK_UNKNOWN`（客户端与服务端双端）、`OK` 为成功路径。无不可达码，但**没有用例**守护该约束（见 G-建议 16）。

---

## 五、发现

### [严重]

#### S1 `MQProtocol.asPayload<T>` 对标量/字符串恒返回 `None`，与规格 SHALL 相反；转换标志也与设计相反

- **位置**：`f_mq/src/base/MQProtocol.cj:154-169`（关键分支 `:157-163` 与 `:165`）
- **现象**：
  1. `asPayload` 只接受 `SimpleDataObject`，其余（`DataString`/`DataInt`/`DataBool`…）直接 `return None<T>`。而规格要求「`T` 为标量或字符串时，只有对应 `Data` 子类型才算匹配」（protocol spec:79-80），即 `asPayload<String>(DataString("x"))` 应返回 `Some("x")`，实际恒为 `None`。`String`/`Int64` 确实实现了 `DataFields<T>`（`f_data/src/base/DataString.cj:43`、`NumberData.cj:240`），所以这条路径本可成立。
  2. 类型闸门通过后使用 `convert<T>(message.data, flag: SILENCE)`，而详细设计 §5.11:467-468 明确写「用严格转换（`DEFAULT_DATA_FLAG`）……不再用 `SILENCE` 把异类载荷折成默认对象」。`decodePayload`（`:228-258`）用的是 `DEFAULT_DATA_FLAG`，两个 API 语义不对称。
- **影响**：公开 API 对合法输入静默返回错误结果（`None`），调用方无法与「载荷不存在」区分；`SILENCE` 使字段级结构漂移（同 `typeInfo`、字段改名/缺失）仍然产出「字段全默认」的对象，正是 A03 要消除的形态。此前 verify 报告把它列为 S5 建议，本轮按「规格 SHALL 未实现 + 静默错误结果」升级为严重。
- **建议**：把非对象分支改为「运行时 `Data` 子类型与 `T` 对应的标量类型匹配则转换，否则 `None`」，或直接复用 `decodePayload` 的实现；转换标志统一为 `DEFAULT_DATA_FLAG`，并补 `asPayload<String>`/`asPayload<Int64>` 的正反用例。若决定不实现标量路径，则必须把规格该句收窄为「`asPayload` 仅用于对象载荷」。

### [一般]

#### G1 `MQNodePool` 关闭与建连存在竞态：`close()` 之后仍可能新建连接并泄漏

- **位置**：`f_mq/src/client/MQNodePool.cj:86-88`（`closed` 检查在锁外）、`:89`（加锁）、`:110-115`（锁内直接 `build(...)`，无二次检查）、`:168-171`（`close` 先置 `closed` 再逐节点取锁）
- **现象**：线程 A 通过 `:86` 的 `closed` 检查后被调度挂起；线程 B 执行 `close()`：置 `closed=true`，取锁关掉空槽后释放；线程 A 继续取锁并 `build` 出一条新连接写入 `slots`。`close()` 已返回，但池里留有一条永不关闭的连接。
- **影响**：违反 client spec:282-285「`close()` 之后调用 `clientOf` 抛异常、不建立新连接」；长连接句柄泄漏；`closeIsSafeUnderConcurrentCalls` 只并发调用 `publish`，覆盖不到该路径。
- **建议**：在锁内 `build` 之前再次检查 `closed`（并在失败时抛 `MQConnectionException`）；或改为「先逐节点加锁关闭，最后置 `closed`」。补一条「8 线程 `clientOf` 与 `close` 并发，结束后无存活连接」的用例。

#### G2 `MQSubscription` 五个字段从未被读取，`MQFilter` 预编译结果被丢弃

- **位置**：`f_mq/src/client/MQSubscription.cj:30-35`；写入点 `f_mq/src/client/MQClient.cj:137,176-177`
- **现象**：`subscribedId`/`topic`/`subscribeGroup`/`tags`/`filter` 只赋值不读取；`MQClient.subscribe` 编译出的 `MQFilter` 进入对象后再无使用。
- **影响**：死状态增加内存与维护成本；「客户端可观测性」要求日志含 topic/订阅 id（client spec:289-291），而这些现成字段未被使用，日志只能从参数取；`MQFilter` 只在本地校验时有副作用，读者会误以为客户端会再次过滤。
- **建议**：删除未用字段（保留 `subscribedId` 并用于日志），或在日志/重订阅逻辑中真正使用；`filter` 若只用于校验，改为显式 `MQFilter.compile(filter)` 丢弃并注释「仅本地校验」。

#### G3 详细设计 §5.10 `MQMetaSnapshot` 缺三个字段，且与 §4.1 表自相矛盾

- **位置**：`f_mq/doc/详细设计.md:419-425`（三字段）与 `:223`（六字段）；代码 `f_mq/src/base/payload/MQMetaSnapshot.cj:23-36`
- **现象**：§5.10 只列 `topics`/`groups`/`nextStartNode`，漏 `tombstones`/`revision`/`tombstoneFloor`；§4.1 的声明表却已列全。
- **影响**：按 §5.10 构造/解码快照会漏掉墓碑与版本，正是「删除静默复活」的根因描述所依赖的字段；文档内部互相矛盾。
- **建议**：以代码为准补齐 §5.10，并同步补默认值（`[]`/`0`）说明。

#### G4 详细设计 §5.2 `MQSubscribeGroupMeta` 缺 `revision`/`origin`

- **位置**：`f_mq/doc/详细设计.md:270-275`（及 §3.3:129）；代码 `f_mq/src/base/model/MQSubscribeGroupMeta.cj:23-31`
- **现象**：文档只写 `topic`/`subscribeGroup`，代码还有版本与产生节点两字段（元数据冲突消解依赖它们）。
- **影响**：读者按文档实现组变更广播会丢失 revision，破坏 metadata-cluster 的 Lamport 比较。
- **建议**：补齐两字段并说明默认值 0 的「旧数据」语义。

#### G5 `MQGroup` / `MQTags` 的校验规则未进入任何模块文档

- **位置**：`f_mq/src/base/MQGroup.cj:27-51`、`f_mq/src/base/MQTags.cj:25-44`；文档侧 `f_mq/README.md:110-119`、`f_mq/doc/详细设计.md:194-227`（§4.1 声明表无这两类）、`f_mq/doc/开发计划.md`
- **现象**：规格 ADDED 了「订阅组名校验」（protocol spec:148-169），代码也实现了（255 字节、禁 `/ \ : %`、不以 `.` 开头结尾、禁空白/控制；tags 64 个 × 128 字节），但 README 只写「tags 子集匹配」，详细设计完全没有 `MQGroup`/`MQTags` 条目，`MAX_LENGTH`/`MAX_COUNT` 也无出处。
- **影响**：客户端会因这些规则抛 `MQException`（`MQClient.cj:75,130,133`），用户却查不到任何限制说明；运维侧也无法判断合法组名。
- **建议**：在详细设计 §5 新增两小节，README「订阅与过滤」补上限与字符集；与规格阈值保持一致。

#### G6 `f_mq/doc/开发计划.md` 大段与现状不符，且引用不存在的用例文件

- **位置**：`f_mq/doc/开发计划.md:19`（`@Expect`，实际全部 `@Assert`）、`:136`（「10 万次」，实际 `MQMessageRecord_test.cj:282` 为 500 次）、`:227,230`（`clientOfSameIndexIsCached`、`aliveNodesFiltersClosed` 无用例且与详细设计 §5.15「不预判死活」矛盾）、`:249`（`HashMap + Mutex`，实际 `ConcurrentHashMap`）、`:256,274,294,315`（`MQClientPublish_test.cj`/`MQClientSubscribe_test.cj`/`MQClientConsume_test.cj`/`MQClientLifecycle_test.cj` 均不存在，实际集中在 `client/test/MQClient_test.cj`）
- **现象**：计划文件是「TDD 步骤」形态的历史产物，未随实现收敛；`tasks.md:30.2` 只修正了 `doc/spec/add-fmq-message-queue/tasks.md` 的同类问题。
- **影响**：按计划执行会找不到文件、写出与设计相反的 `aliveNodes` 用例；无法作为验收依据。
- **建议**：改写为「实际文件 + 实际用例名」，或明确标注为历史计划并移入 `doc/spec/`。

#### G7 规格「退订幂等」场景与需求正文/实现自相矛盾，且无对应用例

- **位置**：规格 `.../f-mq/client/spec.md:200-215`（需求「对本地不存在的 id SHALL 抛 `MQServiceException`」在 `:202`，场景「连续退订两次……两次调用都不抛异常」在 `:207-210`）；实现 `f_mq/src/client/MQClient.cj:368-394` + `:420-426`
- **现象**：第一次成功退订会 `subscriptions.remove`，第二次在 `subscriptionOf` 处抛 `MQServiceException(7)`，不发请求；用例 `unsubscribeIsIdempotentOnServerAndRejectsUnknownId`（`MQClient_test.cj:752-780`）实际断言「第二次抛 7」，与场景文字相反。上一轮 verify 报告的 S6 已指出，本轮仍未修正。
- **影响**：按场景书写的用例必然红；规格无法作为验收基准。
- **建议**：把场景改为「第二次退订（本地已无该 id）抛 `MQServiceException(7)` 且不发请求」，或实现真正的本地幂等并补用例。

#### G8 规格残留冗余场景「内部消息的两种 kind」，与「三种 kind」并存

- **位置**：`.../f-mq/protocol/spec.md:87-91`（两种）与 `:93-98`（三种）；`tasks.md:334`（V9 声称「删除过时『两种 kind』场景」）
- **现象**：V9 未真正落地，旧场景仍在权威 spec 中；历史 spec `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md:89-93` 也有同样场景。
- **影响**：两个场景描述同一能力且粒度不同，验收时无法判断以哪条为准。
- **建议**：删除 `:87-91` 场景，保留三种 kind 版本。

#### G9 规格中的 `delayingMs` 调用示例是位置参数，实现要求具名参数

- **位置**：`f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md:20-28`（`MQTopicMeta("/t", 2, 61000)`、`MQTopicAssignment("/t", 2, 0, [0, 1], 61000)`）；实现 `MQTopicMeta.cj:26-31`、`MQTopicAssignment.cj:33-40`（`delayingMs!`）
- **影响**：照规格写用例直接编译失败；用例实际写作 `MQTopicMeta("/t", 2, delayingMs: 61000)`（`MQPayload_test.cj:180`）。
- **建议**：规格示例改为具名参数，或把构造参数改为位置参数。

#### G10 README 依赖列表不完整

- **位置**：`f_mq/README.md:4`、`f_mq/README_en.md:4`（列 `f_codec`、`f_data`、`f_protocol`、`f_net`、`f_util`）；`f_mq/cjpm.toml:2-11` 与详细设计 §1:26-37 列出 10 个依赖
- **现象**：漏 `f_base`、`f_config`、`f_io`、`f_log`、`f_time`。
- **影响**：用户评估耦合与打包依赖时会漏项（尤其 `f_config` 决定 `MQClient()` 可用性）。
- **建议**：README 中英同步为完整列表，或改为「详见详细设计 §1」。

#### G11 `MQClientConfigTest` 的配置还原不精确，用例断言依赖执行顺序

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:33-36`（`case None => Config.set(..., "")`）、`:87-92`（`@Assert(Config.getString(...) == before)`）
- **现象**：原值为「键不存在」时被还原成「键存在且为空串」（`Config.getString` 返回 `Some("")`，见 `f_config/src/Config.cj:164-176`）。因此 `configIsRestoredAfterTest` 单独运行（`before == None`）时断言必然失败；当前能通过与类内前序用例已把键写成 `""` 有关。
- **影响**：违反 client spec:26-29「用例结束后配置恢复为修改前的值」；用例顺序敏感，`--filter` 单跑或并行执行会红。
- **建议**：提供可删除键的还原手段（或用快照/恢复 API）；断言改为比较 `MQClientConfig.hosts` 的行为（空/缺失都抛），而非比较 `Option<String>` 的形态。

#### G12 组名/tags 的「控制字符」只判到 `0x20`，`0x7F` 与 Unicode 空白可通过

- **位置**：`f_mq/src/base/MQGroup.cj:40-49`、`f_mq/src/base/MQTags.cj:37-41`（`MQTopic.cj:30-34` 同法）
- **现象**：`for (c in s)` 按字节迭代，只拒绝 `<= 0x20`；`0x7F`（DEL）、`U+00A0`、`U+3000` 等空白/控制字符均通过。规格要求「不含空白与控制字符」（protocol spec:151）。
- **影响**：组名/标签可写入不可见字符，日志与文件名排障困难；与规格文字不符，且无用例守护（`MQGroup_test.cj:43-47` 只测 ASCII 空白）。
- **建议**：改为 `toRuneArray()` 后按 `isWhiteSpace`/`isControl` 判定，或至少补 `c == 0x7F`；补全角空格用例。

#### G13 缺用例：`metaSync(MQDeregisterPayload)` 重载（删除同步）

- **位置**：规格 `.../f-mq/protocol/spec.md:235-238`；实现 `f_mq/src/base/MQProtocol.cj:94-97`；用例 `f_mq/src/base/MQProtocol_test.cj:191-218` 只覆盖 request/assignment/group/tombstone 四个重载，`factoriesUseExpectedCommands:54` 也只测 request 重载
- **影响**：该重载若把命令从 `DEREGISTER` 改坏、或子载荷类型写错，测试不会红；服务端 `MQCommandExecutor.onDeregister`（`fmq/src/server/MQCommandExecutor.cj:186-206`）依赖它与墓碑路径的区分。
- **建议**：补一条 `roundtripFrame(MQProtocol.metaSync(MQDeregisterPayload("/t","g","group")))`，断言 `command == DEREGISTER` 且子载荷可还原。

#### G14 缺用例：订阅回滚失败的可观测性

- **位置**：规格 client spec:105-108；实现 `f_mq/src/client/MQClient.cj:182-206`（异常文案拼「回滚失败的节点」、`:202-204` ERROR 日志）；用例 `subscribeRollsBackOnGroupNotExist`（`MQClient_test.cj:254-274`）只覆盖回滚成功
- **影响**：异常文案与 ERROR 日志没有任何用例保护，回滚失败的节点信息可能在重构中丢失（上一轮 W4 类问题的同族）。
- **建议**：让接受节点在 `UNSUBSCRIBE` 时超时或回 `INTERNAL`，断言抛出的 `MQServiceException` 文案含该节点下标，并用 `CapturingAppender` 断言 ERROR 日志。

#### G15 缺用例：ack 发送失败后投递映射保留、可重试

- **位置**：规格 client spec:183-186；实现 `f_mq/src/client/MQClient.cj:307-325`（仅成功路径删映射，失败保留）；无用例
- **影响**：`deliveries` 的「失败不删」语义是 A13 的修复点，但只有服务端错误路径被覆盖（`ackSurfacesFailuresExceptUnknown`），连接失败路径无守护。
- **建议**：让投递节点在 `ACK` 时不可达，断言首次抛 `MQConnectionException`；恢复后再次 `ack` 同一位置，断言仍只发往该节点（`countOf(stub, "ACK") == 2` 而非广播）。

#### G16 弱断言：`publishTime` 的「标准 ID」用例恒真，「跨时区」用例未切换时区

- **位置**：`f_mq/src/base/MQMessageRecord_test.cj:143-148`（断言 `time.format("yyyyMMddHHmmssSSS") == 原串`）与 `:150-159`（`publishTimeRoundTripsAcrossTimeZones`）
- **现象**：第一条无论是否做 UTC 补偿，格式化回同一时区都会得到原串，属恒真断言，无法验证规格要求的绝对时刻 `2026-10-18T18:30:00.123456789Z`（protocol spec:54-57）；第二条没有改变进程时区，「Asia/Shanghai」场景（spec:59-62）实际未覆盖——在 UTC 主机上「不补偿」也能通过。
- **影响**：`MQMessageRecord.cj:124-126` 的时区补偿逻辑（跨时区差 8 小时的正确性）没有有效用例；服务端延迟投递依赖它。
- **建议**：用 `DateTime.ofUTC(...)` 构造期望值并断言 `time.toUnixTimeStamp()`；时区用例用 `TimeZone` 显式构造，或在子进程中设 `TZ` 后运行（参照 `f_protocol/src/default/Protocol_test.cj:130-140` 的写法）。

#### G17 覆盖不足：publish 的「10 个 tags 顺序保持」与 subscribe 的「只记接受者」场景

- **位置**：规格 client spec:39-43、:95-98；用例 `MQClient_test.cj:123-146`（2 个 tag）、`:220-251`（两节点都成功）
- **现象**：前者只测 2 个 tag；后者没有「节点 1 回 `NOT_OWNER`、owner 集合应为 `[0]`」的用例（现有用例的 owner 集合要么是两个、要么为空）。任务台账 2.4 写「tags 顺序无关（2 个 tag）」，与规格的 10 个不一致。
- **影响**：tags 顺序/数量边界与 owner 汇总逻辑（多节点订阅的关键路径）缺直接守护。
- **建议**：补一条 10 tags（含重复与边界长度）的 publish 用例；补一条 `NOT_OWNER` + 成功的用例并断言后续 `CONSUME` 只打节点 0。

#### G18 `consume` 的对象 BODY 路径无用例（任务已勾选）

- **位置**：任务 `f_mq/doc/spec/add-fmq-message-queue/tasks.md:2.6`（勾选「对象 BODY」）；用例 `MQClient_test.cj:303-323` 只发布 `String`，对象 BODY 只有模型层用例（`MQModel_test.cj:81-100`）
- **影响**：`MQMessageRecord.decode` → `MQMessageContent.toMessage` → `MQMessage.get<T>` 的整链在对象类型上没有端到端用例；`get<T>` 的类型闸门在客户端路径未被真实解码数据验证过。
- **建议**：用桩服务端返回带 `@DataAssist` 对象的记录，断言 `consume` 后 `get<Order>()` 字段正确、`get<Other>()` 为 `None`。

### [建议]

#### G-建议 1 门面 import 清单与文档不一致

- **位置**：`f_mq/doc/详细设计.md:249`、`f_mq/doc/开发计划.md:192`（「三条 `public import`」）；`f_mq/src/f_mq.cj:23-27`（五条，含 `base.model.*`、`base.payload.*`）
- **建议**：文档改为实际的五条，并说明为何 `model`/`payload` 也要重导出（业务侧需要 `MQTopicMeta`/`MQMessage`）。

#### G-建议 2 `MQSubscription.cursor` 类型与 `MQOwnershipCache.clear` 未入文档

- **位置**：`f_mq/doc/详细设计.md:535`（`var cursor: Int64`）vs `MQSubscription.cj:38`（`AtomicInt64`）；`MQOwnershipCache.cj:58` 的 `clear()` 未出现在 §5.16:558-562
- **建议**：文档同步为 `AtomicInt64`（并说明并发行），补 `clear()` 的用途（`MQClient.close` 调用）。

#### G-建议 3 仅测试使用的公共 API

- `MQResult.isOk()`（`MQResult.cj:35`）、`MQConsumeResult.hasMessage()`（`MQConsumeResult.cj:50`）、`MQDeregisterPayload.isGroup()`（`MQDeregisterPayload.cj:71`，测试也未用）、`MQNodePool.isClosed()`（`MQNodePool.cj:188`）、`MQPayloadKind.toString()`（`MQConstants.cj:102`）
- **建议**：要么在服务端/管理端消费端真正使用（`isOk` 很适合替换 `code == 0` 的字面比较），要么删除；`isGroup` 建议直接删（服务端统一走 `kindOf()`）。

#### G-建议 4 未使用的 import

- **位置**：`f_mq/src/base/MQMessageRecord.cj:19-20`
- **建议**：删除 `import std.fs.*` 与 `import std.io.SeekPosition`（编译期未告警是因为动态库构建未开启 unused 检查）。

#### G-建议 5 `consume` 中不可达的 `throw`

- **位置**：`f_mq/src/client/MQClient.cj:292-293`
- **现象**：`while (true)` 之后保留 `throw MQConnectionException("unreachable")`，注释写明只为满足编译器。
- **建议**：保留但改为 `unreachable` 明确的私有异常（或 `throw Exception("unreachable")` 以外的方式），避免调用方把这条文案当成真实故障；若语言版本支持 `while (true)` 的流分析，可删除。

#### G-建议 6 `closeLock` 冗余

- **位置**：`f_mq/src/client/MQClient.cj:49`、`:397-411`
- **现象**：`compareAndSwap(false, true)` 已保证只有一个线程进入临界区，`synchronized(closeLock)` 不提供额外保护。
- **建议**：删除 `closeLock`，或注释说明它防的是「未来并发路径」。

#### G-建议 7 测试辅助死代码

- `f_mq/src/client/test/LogCapture_test.cj:90`（`CapturingAppender.clear`，编译器已告警）
- `f_mq/src/client/test/MQStubServer.cj:116`（`isClosed`）
- **建议**：删除，或在实际用例中使用（例如每例前 `clear()` 防止日志串例）。

#### G-建议 8 publish 成功后所有权缓存被写成单节点

- **位置**：`f_mq/src/client/MQClient.cj:90`（`ownership.put(topic, [node])`）；文档 §5.16:564-565 说缓存是「主题 → 所有者节点下标」，§6.2:592 说「目标节点 = ownersOf(topic) 的第一个可用节点」
- **现象**：一次成功发布后缓存变为「最近一次成功的节点」，不再表示 owner 集合；与 subscribe 写入的集合语义不同。
- **影响**：当前无功能错误（`candidateNodes` 会把其余节点追加为兜底，`fmq` 的 `pickQueue` 只要有一队列即可写入），但缓存语义漂移会让后续读者误判。
- **建议**：成功时改为 `ownership.put(topic, 并集(existing, node))`，或另立「最近成功节点」字段并补文档。

#### G-建议 9 `MQMessage.body` 的 `None` 形态实际不可达

- **位置**：`f_mq/src/base/model/MQMessageContent.cj:34-36`（`toMessage` 恒 `Some(body)`）；文档 `f_mq/doc/详细设计.md:303`、`MQMessage.cj:25`（「`None` 表示 BODY 为 `DataNone`」）
- **现象**：`consume` 路径永远不会产出 `body == None`，`DataNone` BODY 会变成 `Some(DataAny(DataNone))`。
- **建议**：`toMessage` 对 `DataNone` 传 `None`（与文档一致），或改文档为「`None` 仅由调用方构造」。

#### G-建议 10 `deliveries` 无上限，长期不 ack 时无界增长

- **位置**：`f_mq/src/client/MQClient.cj:243-250`（仅 `ack` 成功时删除，`:318`）
- **现象**：非 autoAck 订阅若业务永不 `ack`（例如处理失败后丢弃），每个投递位置都留在 `ConcurrentHashMap` 中，且该位置后续无法被再次认领。
- **建议**：文档明确「不 ack 的位置不会再次投递、映射常驻」；或设置上限/过期清理并在设计 §7 记录取舍。

#### G-建议 11 `decodePayload` 不校验尾部残留

- **位置**：`f_mq/src/base/MQProtocol.cj:228-258`（只解一个值，剩余字节忽略）
- **现象**：与 `MQMessageRecord.decode`（要求恰好用尽，`MQMessageRecord.cj:168-170`）的严格性不一致。
- **建议**：内部子载荷也校验「解完即用尽」，或注释说明允许前向兼容的附加字段。

#### G-建议 12 客户端用例依赖 `sleep`，违反模块任务约定

- **位置**：模块约定 `f_mq/doc/spec/add-fmq-message-queue/tasks.md:3-5`（「时间相关逻辑必须注入时钟，不使用 `sleep`」）；实际 `MQClient_test.cj:555`（600ms）、`:931-937`、`MQNodePool_test.cj:102`（1200ms）等
- **影响**：用例整体变慢，机器负载高时易抖（`sameDeliveryPositionIsClaimedOnce` 依赖 600ms 窗口）；与 `MQOwnershipCache`/`QueueLog` 的注入式做法不一致。
- **建议**：为 `MQClient` 注入 `sleeper`/轮询间隔，或至少把等待改为「条件轮询 + 明确失败信息」。

#### G-建议 13 `asResult` 对未知 RESP 载荷返回 `INTERNAL` 而非可区分的失败态

- **位置**：`f_mq/src/base/MQProtocol.cj:184-193`
- **现象**：响应载荷不是 `MQResult` 时返回 `MQResult(11, "unrecognized result payload")`，与「服务端主动返回 INTERNAL」不可区分，调用方会把协议错误当成业务错误重试。
- **建议**：改为 `?MQResult`，或使用独立文案并在客户端分别处理。

#### G-建议 14 `MQOwnershipCache.ownersOf` 返回内部数组引用

- **位置**：`f_mq/src/client/MQOwnershipCache.cj:45`
- **现象**：`Some(entry[0])` 直接暴露缓存内的 `Array<Int64>`；调用方若修改会污染缓存。
- **建议**：返回 `clone()`（当前调用方 `candidateNodes` 只读，风险低）。

#### G-建议 15 缺用例：日志不输出 BODY / autoAck 映射不增长

- **位置**：client spec:290、:196
- **建议**：用 `CapturingAppender` 断言 publish/consume 日志行不含 BODY 文本；`autoAck` 用例无法直接观测 `deliveries`，可增加 internal 只读视图或在测试包内断言。

#### G-建议 16 缺用例：错误码可达性（规格横切约束）

- **位置**：protocol spec:141-144
- **现象**：本次静态核对通过（12 个码均有非测试构造点），但无用例；一旦某个码的构造路径被删，只有人工审查能发现。
- **建议**：至少加一条「服务器/管理端源码中出现的错误码集合覆盖 0–11（0 除外）」的静态断言脚本，或在 R5 全局扫描中固化。

---

## 六、本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 18 |
| 轻微（建议） | 16 |

## 七、总评

**整体质量较好，可以继续作为 f_mq 的基线，但需先处理 1 条严重项。**

- **文档一致性**：字段/签名层面的主体是准确的（`MQClient`、`MQProtocol`、`MQMessageRecord`、错误码表、载荷表基本逐字对应），漂移集中在「后继变更未回写」的三处（`MQMetaSnapshot`、`MQSubscribeGroupMeta`、门面 import）和「规格未回写实现」的三处（`asPayload` 转换语义、`delayingMs` 参数形态、两种 kind 冗余场景）。`开发计划.md` 仍是 TDD 期的历史文本，已不能作为验收依据。
- **测试覆盖**：128 个用例、0 空测试、0 无断言、0 `@Ignore`，失败路径覆盖明显优于一般模块（空记录 vs 解码失败、`ACK_UNKNOWN`、回滚、关闭并发、退订部分失败、重复投递认领都有专门用例）。真正的缺口集中在三处错误路径（回滚失败、ack 重试、订阅 owner 汇总）和两处弱断言（`publishTime` 恒真断言、非法 filter 泛捕获），都属于「补一条用例即可闭合」的量级。
- **空函数/占位**：无。生产代码没有空体、`return` 占位或 `NotImplemented`；唯一的不可达 `throw` 有注释说明。
- **死代码**：局部且无害——`MQSubscription` 五个只写不读的字段（其中 `filter` 的预编译结果被丢弃）是最值得清理的一处；其余是 4 个测试专用公共方法与 2 行未使用 import。没有整块死代码被当作生产入口，也没有 `@Deprecated` 无迁移路径的 API。
- **建议优先级**：S1（`asPayload`）→ G1（连接池关闭竞态）→ G7（退订幂等规格矛盾）→ G11（配置还原/顺序依赖）→ 其余文档回写（G3–G6、G9、G10）。G2 的字段清理可与「日志带 topic」的可观测性改进合并做。
