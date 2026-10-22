# fmq postfix 审计待办（严重 / 一般）

来源：`review_v1.md` – `review_v5.md`（HEAD `22c13ec4`，审查日 2026-10-21）
范围：仅「严重」「一般」问题；已忽略各条建议。

## R1

### [严重] S1 `MQProtocol.asPayload<T>` 对标量/字符串恒返回 `None`，与规格 SHALL 相反；转换标志也与设计相反

- **位置**：`f_mq/src/base/MQProtocol.cj:154-169`（关键分支 `:157-163` 与 `:165`）
- **描述**：`asPayload` 只接受 `SimpleDataObject`，其余（`DataString`/`DataInt`/`DataBool`…）直接 `return None<T>`。规格要求「`T` 为标量或字符串时，只有对应 `Data` 子类型才算匹配」（protocol spec:79-80），即 `asPayload<String>(DataString("x"))` 应返回 `Some("x")`，实际恒为 `None`；而 `String`/`Int64` 确实实现了 `DataFields<T>`（`f_data/src/base/DataString.cj:43`、`NumberData.cj:240`），该路径本可成立。类型闸门通过后使用 `convert<T>(message.data, flag: SILENCE)`，而详细设计 §5.11:467-468 明确要求严格转换（`DEFAULT_DATA_FLAG`）；`decodePayload`（`:228-258`）使用 `DEFAULT_DATA_FLAG`，两个 API 语义不对称。影响：公开 API 对合法输入静默返回错误结果，调用方无法与「载荷不存在」区分；`SILENCE` 使字段级结构漂移（同 `typeInfo`、字段改名/缺失）仍产出「字段全默认」的对象。

### [一般] G1 `MQNodePool` 关闭与建连存在竞态：`close()` 之后仍可能新建连接并泄漏

- **位置**：`f_mq/src/client/MQNodePool.cj:86-88`（`closed` 检查在锁外）、`:89`（加锁）、`:110-115`（锁内直接 `build(...)`，无二次检查）、`:168-171`（`close` 先置 `closed` 再逐节点取锁）
- **描述**：线程 A 通过 `:86` 的 `closed` 检查后被调度挂起；线程 B 执行 `close()`：置 `closed=true`，取锁关掉空槽后释放；线程 A 继续取锁并 `build` 出一条新连接写入 `slots`。`close()` 已返回，但池里留有一条永不关闭的连接。违反 client spec:282-285「`close()` 之后调用 `clientOf` 抛异常、不建立新连接」；长连接句柄泄漏；`closeIsSafeUnderConcurrentCalls` 只并发调用 `publish`，覆盖不到该路径。

### [一般] G2 `MQSubscription` 五个字段从未被读取，`MQFilter` 预编译结果被丢弃

- **位置**：`f_mq/src/client/MQSubscription.cj:30-35`；写入点 `f_mq/src/client/MQClient.cj:137,176-177`
- **描述**：`subscribedId`/`topic`/`subscribeGroup`/`tags`/`filter` 只赋值不读取；`MQClient.subscribe` 编译出的 `MQFilter` 进入对象后再无使用。死状态增加内存与维护成本；client spec:289-291 要求日志含 topic/订阅 id，而这些现成字段未被使用；`MQFilter` 只在本地校验时有副作用，读者会误以为客户端会再次过滤。

### [一般] G3 详细设计 §5.10 `MQMetaSnapshot` 缺三个字段，且与 §4.1 表自相矛盾

- **位置**：`f_mq/doc/详细设计.md:419-425`（三字段）与 `:223`（六字段）；代码 `f_mq/src/base/payload/MQMetaSnapshot.cj:23-36`
- **描述**：§5.10 只列 `topics`/`groups`/`nextStartNode`，漏 `tombstones`/`revision`/`tombstoneFloor`；§4.1 的声明表却已列全。按 §5.10 构造/解码快照会漏掉墓碑与版本，正是「删除静默复活」根因描述所依赖的字段；文档内部互相矛盾。

### [一般] G4 详细设计 §5.2 `MQSubscribeGroupMeta` 缺 `revision`/`origin`

- **位置**：`f_mq/doc/详细设计.md:270-275`（及 §3.3:129）；代码 `f_mq/src/base/model/MQSubscribeGroupMeta.cj:23-31`
- **描述**：文档只写 `topic`/`subscribeGroup`，代码还有版本与产生节点两字段（元数据冲突消解依赖它们）。读者按文档实现组变更广播会丢失 revision，破坏 metadata-cluster 的 Lamport 比较。

### [一般] G5 `MQGroup` / `MQTags` 的校验规则未进入任何模块文档

- **位置**：`f_mq/src/base/MQGroup.cj:27-51`、`f_mq/src/base/MQTags.cj:25-44`；文档侧 `f_mq/README.md:110-119`、`f_mq/doc/详细设计.md:194-227`、`f_mq/doc/开发计划.md`
- **描述**：规格 ADDED 了「订阅组名校验」（protocol spec:148-169），代码也实现了（255 字节、禁 `/ \ : %`、不以 `.` 开头结尾、禁空白/控制；tags 64 个 × 128 字节），但 README 只写「tags 子集匹配」，详细设计完全没有 `MQGroup`/`MQTags` 条目，`MAX_LENGTH`/`MAX_COUNT` 也无出处。客户端会因这些规则抛 `MQException`（`MQClient.cj:75,130,133`），用户却查不到任何限制说明。

### [一般] G6 `f_mq/doc/开发计划.md` 大段与现状不符，且引用不存在的用例文件

- **位置**：`f_mq/doc/开发计划.md:19`、`:136`、`:227,230`、`:249`、`:256,274,294,315`
- **描述**：`:19` 写 `@Expect`，实际全部 `@Assert`；`:136` 写「10 万次」，实际 `MQMessageRecord_test.cj:282` 为 500 次；`:227,230` 的 `clientOfSameIndexIsCached`、`aliveNodesFiltersClosed` 无用例且与详细设计 §5.15「不预判死活」矛盾；`:249` 写 `HashMap + Mutex`，实际 `ConcurrentHashMap`；`:256,274,294,315` 引用的 `MQClientPublish_test.cj`/`MQClientSubscribe_test.cj`/`MQClientConsume_test.cj`/`MQClientLifecycle_test.cj` 均不存在（实际集中在 `client/test/MQClient_test.cj`）。该文件是 TDD 步骤形态的历史产物，未随实现收敛，无法作为验收依据。

### [一般] G7 规格「退订幂等」场景与需求正文/实现自相矛盾，且无对应用例

- **位置**：规格 `.../f-mq/client/spec.md:200-215`；实现 `f_mq/src/client/MQClient.cj:368-394` + `:420-426`
- **描述**：需求正文 `:202` 写「对本地不存在的 id SHALL 抛 `MQServiceException`」，场景 `:207-210` 写「连续退订两次……两次调用都不抛异常」。实现第一次成功退订会 `subscriptions.remove`，第二次在 `subscriptionOf` 处抛 `MQServiceException(7)`，不发请求；用例 `unsubscribeIsIdempotentOnServerAndRejectsUnknownId`（`MQClient_test.cj:752-780`）实际断言「第二次抛 7」，与场景文字相反。按场景书写的用例必然红，规格无法作为验收基准。

### [一般] G8 规格残留冗余场景「内部消息的两种 kind」，与「三种 kind」并存

- **位置**：`.../f-mq/protocol/spec.md:87-91`（两种）与 `:93-98`（三种）；`tasks.md:334`
- **描述**：V9 声称「删除过时『两种 kind』场景」但未真正落地，旧场景仍在权威 spec 中；历史 spec `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md:89-93` 也有同样场景。两个场景描述同一能力且粒度不同，验收时无法判断以哪条为准。

### [一般] G9 规格中的 `delayingMs` 调用示例是位置参数，实现要求具名参数

- **位置**：`f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md:20-28`；实现 `MQTopicMeta.cj:26-31`、`MQTopicAssignment.cj:33-40`
- **描述**：示例写 `MQTopicMeta("/t", 2, 61000)`、`MQTopicAssignment("/t", 2, 0, [0, 1], 61000)`，而实现第三/第五参数是具名参数 `delayingMs!`。照规格写用例直接编译失败；实际用例写作 `MQTopicMeta("/t", 2, delayingMs: 61000)`（`MQPayload_test.cj:180`）。

### [一般] G10 README 依赖列表不完整

- **位置**：`f_mq/README.md:4`、`f_mq/README_en.md:4`；`f_mq/cjpm.toml:2-11`、详细设计 §1:26-37
- **描述**：README 只列 `f_codec`、`f_data`、`f_protocol`、`f_net`、`f_util`，漏 `f_base`、`f_config`、`f_io`、`f_log`、`f_time`（实际与详细设计均为 10 个依赖）。用户评估耦合与打包依赖时会漏项，尤其 `f_config` 决定 `MQClient()` 可用性。

### [一般] G11 `MQClientConfigTest` 的配置还原不精确，用例断言依赖执行顺序

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:33-36`、`:87-92`
- **描述**：原值为「键不存在」时被还原成「键存在且为空串」（`Config.getString` 返回 `Some("")`，见 `f_config/src/Config.cj:164-176`）。`configIsRestoredAfterTest` 单独运行（`before == None`）时断言必然失败；当前能通过与类内前序用例已把键写成 `""` 有关。违反 client spec:26-29「用例结束后配置恢复为修改前的值」，`--filter` 单跑或并行执行会红。

### [一般] G12 组名/tags 的「控制字符」只判到 `0x20`，`0x7F` 与 Unicode 空白可通过

- **位置**：`f_mq/src/base/MQGroup.cj:40-49`、`f_mq/src/base/MQTags.cj:37-41`（`MQTopic.cj:30-34` 同法）
- **描述**：`for (c in s)` 按字节迭代，只拒绝 `<= 0x20`；`0x7F`（DEL）、`U+00A0`、`U+3000` 等空白/控制字符均通过。规格要求「不含空白与控制字符」（protocol spec:151）。组名/标签可写入不可见字符，日志与文件名排障困难；`MQGroup_test.cj:43-47` 只测 ASCII 空白。

### [一般] G13 缺用例：`metaSync(MQDeregisterPayload)` 重载（删除同步）

- **位置**：规格 `.../f-mq/protocol/spec.md:235-238`；实现 `f_mq/src/base/MQProtocol.cj:94-97`；用例 `f_mq/src/base/MQProtocol_test.cj:191-218`、`:54`
- **描述**：5 个 `metaSync` 重载只测了 4 个（request/assignment/group/tombstone），`factoriesUseExpectedCommands` 也只测 request 重载。该重载若把命令从 `DEREGISTER` 改坏、或子载荷类型写错，测试不会红；服务端 `MQCommandExecutor.onDeregister`（`fmq/src/server/MQCommandExecutor.cj:186-206`）依赖它与墓碑路径的区分。

### [一般] G14 缺用例：订阅回滚失败的可观测性

- **位置**：规格 client spec:105-108；实现 `f_mq/src/client/MQClient.cj:182-206`（异常文案拼「回滚失败的节点」、`:202-204` ERROR 日志）；用例 `MQClient_test.cj:254-274`
- **描述**：`subscribeRollsBackOnGroupNotExist` 只覆盖回滚成功，异常文案与 ERROR 日志没有任何用例保护，回滚失败的节点信息可能在重构中丢失。

### [一般] G15 缺用例：ack 发送失败后投递映射保留、可重试

- **位置**：规格 client spec:183-186；实现 `f_mq/src/client/MQClient.cj:307-325`（仅成功路径删映射，失败保留）；无用例
- **描述**：`deliveries` 的「失败不删」语义是 A13 的修复点，但只有服务端错误路径被覆盖（`ackSurfacesFailuresExceptUnknown`），连接失败路径无守护。

### [一般] G16 弱断言：`publishTime` 的「标准 ID」用例恒真，「跨时区」用例未切换时区

- **位置**：`f_mq/src/base/MQMessageRecord_test.cj:143-148` 与 `:150-159`
- **描述**：第一条断言 `time.format("yyyyMMddHHmmssSSS") == 原串`，无论是否做 UTC 补偿、格式化回同一时区都会得到原串，属恒真断言，无法验证规格要求的绝对时刻 `2026-10-18T18:30:00.123456789Z`（protocol spec:54-57）；第二条没有改变进程时区，「Asia/Shanghai」场景（spec:59-62）实际未覆盖，在 UTC 主机上「不补偿」也能通过。`MQMessageRecord.cj:124-126` 的时区补偿逻辑（跨时区差 8 小时）没有有效用例，而服务端延迟投递依赖它。

### [一般] G17 覆盖不足：publish 的「10 个 tags 顺序保持」与 subscribe 的「只记接受者」场景

- **位置**：规格 client spec:39-43、:95-98；用例 `MQClient_test.cj:123-146`（2 个 tag）、`:220-251`（两节点都成功）
- **描述**：前者只测 2 个 tag；后者没有「节点 1 回 `NOT_OWNER`、owner 集合应为 `[0]`」的用例（现有用例的 owner 集合要么是两个、要么为空）。任务台账 2.4 写「tags 顺序无关（2 个 tag）」，与规格的 10 个不一致。tags 顺序/数量边界与 owner 汇总逻辑（多节点订阅的关键路径）缺直接守护。

### [一般] G18 `consume` 的对象 BODY 路径无用例（任务已勾选）

- **位置**：任务 `f_mq/doc/spec/add-fmq-message-queue/tasks.md:2.6`；用例 `MQClient_test.cj:303-323`；模型层用例 `MQModel_test.cj:81-100`
- **描述**：任务已勾选「对象 BODY」，但客户端用例只发布 `String`，对象 BODY 只有模型层用例。`MQMessageRecord.decode` → `MQMessageContent.toMessage` → `MQMessage.get<T>` 的整链在对象类型上没有端到端用例；`get<T>` 的类型闸门在客户端路径未被真实解码数据验证过。

## R2

### [严重] 墓碑不参与接受判断，已删除的主题/组可被迟到的低版本变更复活

- **位置**：`fmq/src/meta/MetaStore.cj:224-248`（`applyTopic`）、`:250-286`（`applyGroup`）、`fmq/src/cluster/MetaSyncer.cj:382-413`（`mergeSnapshot` 先应用墓碑、再应用条目）
- **描述**：`applyTopic` 在 `topicIndex` 无该主题时直接 `writeAtomically` + `topicIndex.add`，全程不查 `tombstones`；`applyGroup` 同理。`mergeSnapshot` 即便刚从快照/本地应用了 revision 更高的墓碑，随后也会把快照里残留的旧条目写回。已删除组被迟到广播（如 rev 2 < 墓碑 rev 7）命中时会重新落盘；已删除主题被旧 peer 快照（快照含该主题、本地墓碑 rev 9 更高）命中时会重新落盘并触发 `notifyTopicApplied` → `QueueManager.openTopic` 与 `MQCommandExecutor` 的 `queues.openTopic`，随后该主题重新接受发布。仓库内唯一防复活判断在 `MetaSyncer.applyRemoteGroup:285`，且只在 `TopicMissing` 分支查 `topicTombstone`，对「主题已复活」与「主题条目迟到」都不生效。影响：违反 metadata-cluster 规格「删除 MUST 以墓碑传播」「旧节点删除不复活」「MUST NOT 继续为该主题打开队列」；墓碑机制对乱序广播与旧 peer 快照两条主路径失效，会产生删不掉的主题、已删主题重新积压消息、节点间长期不一致。现有 102 个用例无一覆盖「墓碑之后到达低版本条目」。

### [严重] `applyTombstone` 版本比较失败时仍删除本地条目，导致数据被「输掉的墓碑」清掉

- **位置**：`fmq/src/meta/MetaStore.cj:340-368`
- **描述**：`applied` 由 `isNewer(tombstone.revision, tombstone.origin, existing.revision, existing.origin)` 决定，但随后删除条件只比较 revision：`if (local.revision <= tombstone.revision) { dropTopicLocked(...) }`。当墓碑与本地条目 revision 相同、origin 更小（版本比较判负、`applied=false`、墓碑不落盘）时，`local.revision <= tombstone.revision` 成立，条目仍被删除；组墓碑同理（`:359-366`）。经 `MetaSyncer.applyRemoteTombstone:362-368` → `notifyDeletedIfGone` → `cleanupAfterDelete`，还会连带删除队列目录、游标、订阅与指标。影响：并发「注册」与「删除」在同一 revision 竞争时，持有较新 origin 的节点会把活着的主题/组删掉，且本地不保留任何墓碑记录（无法自愈），属数据丢失与一致性破坏；规格与代码注释（`:331-335`「按 revision 只进不退」）都要求墓碑输掉比较时不做任何变更。`tombstoneRemovesLocalEntryOnlyWhenOlder` 只覆盖 3 vs 4、3 vs 9，未覆盖同 revision 不同 origin。

### [一般] 快照合并把「畸形条目」当成「对端已删除」，误删本地元数据并清理队列

- **位置**：`fmq/src/cluster/MetaSyncer.cj:383-386`、`:399-402`、`:420-439`
- **描述**：畸形主题/组在校验失败时 `continue`，没有加入 `topicNames` / `groupKeys`；随后的缺失扫描以 `!topicNames.contains(...) && revision <= snapshot.revision` 判定为「对端已删除」，调用 `dropTopicLocally`/`dropGroupLocally` 并 `notifyDeleted`。一个发送畸形载荷（或版本较旧、数据残缺）的 peer 就能让本节点删除合法主题，并触发 `cleanupAfterDelete` 删除队列段目录与游标——「拒绝畸形数据」的保护变成「畸形数据触发删除」。`malformedSnapshotEntriesAreSkipped` 未构造「本地已有同 key 条目」的前置状态，该路径无用例。

### [一般] `MetaStore.load()` 不按已落盘墓碑收敛，崩溃窗口后已删条目会复活

- **位置**：`fmq/src/meta/MetaStore.cj:91-105`（加载顺序）、`:647-660`（`loadTombstones` 只填 map）
- **描述**：`removeTopic`/`applyTombstone` 的顺序是「先写墓碑 → 再删文件」。若在两步之间崩溃（或删除抛错，如 `dropTopicLocked:546-557` 中 `remove` 失败），重启后 `loadTopics` 会把条目重新载入，`loadTombstones` 只把墓碑放进 map，二者不做收敛。墓碑持久化原本用于「重启后删除仍生效」，此窗口下删除丢失：主题重新可发布，墓碑却仍在快照里，节点间出现「条目与墓碑共存」的非法状态（直到下一次同步）。规格 Scenario「墓碑往返」只覆盖无崩溃的正常路径。

### [一般] `LogCleaner` 的失败日志级别与粒度不符合规格（WARN 汇总、无逐对象 ERROR）

- **位置**：`fmq/src/cluster/LogCleaner.cj:114-119`
- **描述**：规格要求「单个失败 SHALL 记 ERROR（含主题/队列/段）」「一轮结束 SHALL 汇总删除数 / 失败数」（spec `:430-432`、Scenario `:434-437`）；实现把全部失败合并成一条 WARN，删除数与失败数分别打印（`log.info("removed N expired segments")` / `log.warn`），没有 ERROR，也没有段级定位（仅 `topic/queue#index(message)` 拼在 WARN 文本里）。`fmq/doc/详细设计.md:490-500` 未提 ERROR 要求，§5.14 与规格本身也不一致；`tasks.md:26.3` 的「逐对象 try/catch + 汇总日志」承诺未完全落地。

### [一般] 规格「单段删除失败」「死信清理继续」两个 Scenario 无用例，`tasks.md:26.1` 属勾选但未落实

- **位置**：`fmq/src/cluster/LogCleaner_test.cj:254-292`（`oneQueueFailureDoesNotStopOthers`）
- **描述**：该用例注入的是 `floorOf` 抛异常（整队列被跳过），不是「某段 `removeById` 抛异常、同队列其它段仍被删」；也没有任何用例让 `deadLetter.cleanExpired` 抛异常来验证「普通队列失败时死信仍清理」（`deadLetterUsesItsOwnTtl` 不含失败注入）。`tasks.md:26.1` 声称「某段删除抛错时其它段与死信仍被清理，日志含失败段」，实际无对应用例，日志亦未被断言。`cleanOnce` 内层的段级 try/catch（`LogCleaner.cj:75-80`、`:97-102`）与死信 try/catch（`:109-113`）从未被失败的用例触发。

### [一般] 备份接收端「`states` 与记录数不一致」的分支完全无用例，且台账记录与事实不符

- **位置**：`fmq/src/server/MQCommandExecutor.cj:249-257`；测试 `fmq/src/server/MQCommandExecutor_test.cj:403-415`
- **描述**：规格新增 Scenario「记录与状态数量不一致 → 记 WARN，仍落盘记录，但不更新位点」（spec `:423-426`）。唯一相关用例 `backupPayloadOnlyWritesCopy` 的 records/states 数量相等；`verify-report.md` 的 W12/W29 把该场景归到 `backupCursorRebuildsConsumerCursor`，而该用例验证的是「备份位点重建游标」，与数量校验无关。该 ADDED Requirement 的核心防御（数量不一致时不得写位点）没有任何用例，实现退化为「始终写位点」时现有测试全绿。

### [一般] 「备份真实状态」只用桩验证，真实 `acked` 推导（`ConsumeService.backupStates`）无用例

- **位置**：`fmq/src/cluster/BackupReplicator_test.cj:168-185`（`StubStateSource`，`:347-358`）；实现 `fmq/src/server/ConsumeService.cj:269-308`
- **描述**：规格要求「`acked` SHALL 由『记录位置早于该组 committed』推导，不得硬编码为 false」，并由生产端在 flush 时读取真实游标。现有用例注入固定返回的桩，只证明「载荷透传」；`backupStates`/`backupCursors`/`ackedByAll`（含「无组时视为未确认」「多组取最小 committed」）没有任何直接用例。规格最核心的「备份不带假状态」缺少回归锚点；`ackedByAll` 在多组场景下的边界（`<=` 与 `<` 的选择）无法被验证。

### [一般] 组载荷校验失败不记 WARN，与「校验失败 SHALL 记 WARN（含主题与失败字段）」不符

- **位置**：`fmq/src/cluster/MetaSyncer.cj:281-292`（`applyRemoteGroup` 对 `Invalid` 无日志）、`:264-268`（主题 WARN 不含失败字段）
- **描述**：规格 `:373-375` 要求任何远端载荷校验失败「返回 `Invalid`，记 WARN（含主题与失败字段）」。实现中组名非法时 `store.applyGroup` 返回 `Invalid` 后直接返回，无任何日志；主题的 WARN 只有 `topic` 与 `origin`，没有指出哪个字段越界。线上出现畸形广播时无迹可查，与 `tasks.md:16.2` 的验收口径不一致。

### [一般] 备份部分目标失败不重试，副本在失败节点上永久缺失（且备份无反熵补偿）

- **位置**：`fmq/src/cluster/BackupReplicator.cj:169-180`
- **描述**：一批数据对多个 target 逐个 `send`，只要 `delivered > 0` 就不进入 `retry`；失败 target 的记录被丢弃。规格「发送失败 SHALL 把批次重新入队并按上限重试」、文档 §6.8:830「失败批次 attempts++ 后放回队首」都按「批次」描述，未说明这种部分成功语义。`backup=2` 且其中一个后继短暂不可达时，该节点永久缺失这批副本，而备份链路没有类似元数据的反熵补偿；恢复时若切到该节点会丢这段数据。

### [一般] 备份 `close()` 只等 500ms，慢后继时在途批次回队后无人 drain，与文档「等当前批次」不符

- **位置**：`fmq/src/cluster/BackupReplicator.cj:268-279`；文档 `fmq/doc/详细设计.md:534`
- **描述**：`close()` 轮询 `workerRunning`，最多 50×10ms；单次发送超时上限是 `pingTimeout*5`（`NodeRegistry.send:150`，默认 5s）。若工作线程仍在 `sendBatch`，`close()` 会继续执行 `flushOnce()`，随后在途批次失败被 `requeue` 到 `pending`，此时已无任何线程会再 flush。文档声明「停止定时器 → 唤醒工作线程 → 等当前批次 → 最后 drain 一次」，实现与「关闭前做最后一次 flush，记录全部发出」的承诺不符；最后一批可能静默留在内存（`pendingCount>0` 但无人检查）。

### [一般] 主题重新注册不清理墓碑：墓碑永久保留、持续随快照扩散；对应 Scenario 无用例

- **位置**：`fmq/src/meta/MetaStore.cj:173-191`（`registerTopic` 不触碰 `tombstones`）、`:406-427`（GC 的 `resurrected` 分支会永久保留被更高 revision 覆盖的墓碑）
- **描述**：规格 Scenario「新注册覆盖墓碑」允许「墓碑被移除或标记为已复活」，实现两者都没做：墓碑留在 map 与磁盘、进入每份快照、`tombstoneFloor` 被压低，且 GC 因 `local.revision > tombstone.revision` 永不回收；`applyRemoteGroup` 的 `topicTombstone` 检查也仍会命中该主题。墓碑数量随「删除-重建」次数单调增长，快照体积与同步成本上涨；`topicTombstone(topic)` 对已重建主题返回 `Some`，「主题已删」的判断不再可靠。该 Scenario 目前只有组维度等价用例（`deletedGroupCanBeRecreatedWithHigherRevision`），主题维度无用例。

### [一般] 死代码：不可达分支 + 7 处仅测试使用/无消费者的符号 + 1 个空转参数 + 1 个无消费者的协议字段

- **位置**：见下列各项
- **描述**：
  1. 不可达分支：`fmq/src/cluster/MetaSyncer.cj:408-410` 的 `case MetaApplyResult.Conflict`——`MetaStore.applyGroup`（`:250-286`）只会返回 `Applied/Duplicated/TopicMissing/Invalid`，该分支永不执行。
  2. 仅测试使用：`MQAssignment.ownersOf`（`fmq/src/meta/MQAssignment.cj:99`，生产无调用方）、`NodeRegistry.nodeAt`（`:104`）与 `indexOf`（`:177`）、`MetaSyncer.pendingPeerCount`（`:101`）、`BackupReplicator.pendingCount`（`:80`）与 `flush`（`:119-121`，生产仅经 `flushOnce`）。
  3. 无消费者状态：`MetaSyncer.pendingPeers`（`:46`、`:474-484`）只累加/清空，从未参与选点、指标或日志，唯一读数是 `pendingPeerCount` 的用例断言。
  4. 无调用方赋值：`LogCleaner.start(now!: () -> DateTime)`（`fmq/src/cluster/LogCleaner.cj:123`）的生产与测试调用都不传 `now`。
  5. 无消费者字段：`MQMetaSnapshot.tombstoneFloor`（`f_mq/src/base/payload/MQMetaSnapshot.cj:34`）由 `MetaStore.snapshot:471` 计算、序列化，但任何合并/清理逻辑都未读取（仅 `f_mq` 往返用例与本包一条断言）。

  影响：`ownersOf`、`nodeAt`、`indexOf` 会被误认为生产 API（文档 §5.4 还把 `ownersOf` 列进签名清单）；`pendingPeers` 与 `tombstoneFloor` 增加维护与序列化成本却不产生行为；不可达分支掩盖了「组冲突本该被处理」的设计缺口（组根本没有 `Conflict` 语义）。

## R3

### [严重] C1 位置恰为段末尾时，下一次读取把后继段的记录头当成本段剩余字节，判为损坏且游标永久停摆

- **位置**：`fmq/src/queue/QueueLog.cj:106-121`、`:303-311`；`fmq/src/queue/GroupCursor.cj:402-418`、`:226-237`；`f_io/src/SegmentedLog.cj:666-671`
- **描述**：`startPositionOf` 对 `position.seq` 存在时原样返回，不归一化 `offset == meta.size`；`remaining = meta.size - offset - PREFIX_SIZE` 为负 → `corrupt`。消费到段末尾并全部确认后，`committed` 正常落在 `(seg, meta.size)`（排空到段尾的常态）；随后该段被封口（下一条不适合放入而轮转），或重启后新段已有数据时：`openRecordsFrom((seg, size))` → `startPositionOf` 认为段仍在 → `openEntryStream(seg, size)` → `ChainedSegmentStream` 跳过零可用字节的旧段、返回下一段字节 → `QueueRecordReader.seq` 仍是旧段号 → `remaining = size - size - 4 = -4` → `corrupt("declared length N exceeds remaining -4")`。`GroupCursor` 每轮都用同一位置重开，于是每轮 ERROR + `None`，该队列对该组永久不可消费；`stats` 以相同位置开流（`ConsumeService.cj:201-205`）同样抛 `INTERNAL`。复现路径：`maxFileSize = 2*(4+28)=64`，追加 2 条 28B 记录 → 确认 2 条（`committed=(1,64)`）→ 再追加 1 条触发轮转到段 2 → 下一次 `next()` 即命中。现有 83 个用例无一覆盖（`catalogFloorTracksCommittedSegments` 已构造出 `committed=(2,size2)`，只差再追加一条）。

### [严重] C2 `segmentedLogMaxSize` 与 `MAX_RECORD_SIZE` 无关联校验，记录大于段上限时越界写

- **位置**：`fmq/src/queue/QueueLog.cj:58-61`；`fmq/src/config/MQConfig.cj:306-308`；`f_io/src/SegmentedLog.cj:189-196`、`:579-585`
- **描述**：`QueueLog` 只校验 64 MiB 上界，不结合段上限；`MQConfig` 只校验 `segmentedLogMaxSize > 0`。运维把 `mqServer_segmentedLogMaxSize` 配成小于单条消息（如 1 MiB）时，`append` 先 `rotate()`，随后按 `currentSize=0` 把整条记录 `mcopy` 进按 `maxFileSize` 映射的区域（无剩余空间检查），越过映射长度。影响：越界写（进程崩溃或相邻映射被破坏），与规格「记录 SHALL NOT 跨段」（queue-storage/spec.md:226）和「先轮转，再在新段完整写入」（`:259-262`）相悖；没有任何用例覆盖「记录接近段上限」。

### [一般] M1 零长度头的语义与规格/设计文档相反

- **位置**：`fmq/src/queue/QueueLog.cj:290-294`；文档 `fmq/doc/详细设计.md:366`
- **描述**：实现把长度 0 当作「干净结束」（关闭流、`corrupted=false`、不记 ERROR）；规格场景标题为「零长度视为损坏」（queue-storage/spec.md:244-247），设计要求 `length <= 0` 视为损坏。损坏段（被清零的头部）会被静默当作「已读完」，`stats` 输出 `backlog=0` 而不报错；`GroupCursor` 的「不可读」路径也因此复用了错误语义（见 M11）。verify-report S7 已记录但未闭环。

### [一般] M2 损坏记录被当成「段被删除」越过，违反「不得伪装成段被删除」

- **位置**：`fmq/src/queue/QueueLog.cj:68-79`；`fmq/src/queue/GroupCursor.cj:152-158`
- **描述**：重投路径 `readAt` 返回 `None` 时统一 `entry.decided = true` + 计数 + WARN，随后 `advance()` 推进 `committed`；段仍在但记录头损坏的情况无法与段被清理区分，且 `isCorrupted()` 信息在此路径被丢弃。损坏记录被静默确认（消息丢失），与 queue-storage/spec.md:319-322「段存在但记录损坏 … 不得伪装成『段被删除』」相反；同一队列的 `stats` 会因损坏报 INTERNAL，而消费侧继续前进，两侧行为不一致。

### [一般] M3 「位点段被删」在三处有四种说法，实现与 `consume-semantics` 冲突

- **位置**：`openspec/specs/fmq/queue-storage/spec.md:57-58`、`:75-83`；`openspec/specs/fmq/consume-semantics/spec.md:290-310`；`fmq/doc/详细设计.md:789-791`；实现 `fmq/src/queue/QueueLog.cj:106-121`、`GroupCursor.cj:503-533`
- **描述**：queue-storage 要求「从最接近的更大段继续 + WARN」；consume-semantics 要求「记 ERROR 后从现存最老段恢复」；详细设计写「跳到现存最老的段继续」；实现是「从 `>= seq` 的最小段继续 + WARN」。用例 `startingSegmentHoleResumesAtNextSegment`（`GroupCursor_test.cj:502`）断言跳到段 7（前进），明确否定了 consume-semantics 的「最老段」。验收/排障时无法判定哪种行为正确；若按 consume-semantics 实现会重投已确认消息（回退），按实现则可能跳过未被确认的旧段（漏消费）。日志级别（WARN/ERROR）也不一致。

### [一般] M4 `stats` 在「部分段缺失」时静默少算 backlog，不报错

- **位置**：`fmq/src/server/ConsumeService.cj:183-205`、`:209-228`
- **描述**：只在 `segmentsOrEmpty().size == 0` 时抛 INTERNAL；若 `committed` 所在段被删但仍存在后继段，`openRecordsFrom` 内部跳段并只记 WARN，`starts` 仍用旧位点比较，最终返回一个偏小的 `backlog`。违反 consume-semantics/spec.md:309「stats 对该组返回错误而非伪造 backlog」与 queue-storage/spec.md:58「MUST NOT 把段缺失解释为积压为 0 而不留痕」的观测要求。

### [一般] M5 死信阈值 off-by-one：实际投递次数比规格少一次

- **位置**：`fmq/src/queue/GroupCursor.cj:172-180`
- **描述**：先 `deliverCount++`，再判 `deliverCount > deadMsgThreshold` 就直接入死信并 `continue`，本次不再返回给消费者。`threshold=3` 时实际只投递 3 次；规格场景写「被投递 4 次仍未确认 → 进死信」（consume-semantics/spec.md:96-99），且死信条目的 `deliverCount=4` 与「实际投递次数」不符。重试次数与规格/用户预期差 1；死信条目的计数失真；`metrics.delivered` 也不含最后一次。

### [一般] M6 `append` 接受 0 长度记录，会把同段后续记录变成不可见

- **位置**：`fmq/src/queue/QueueLog.cj:58-66`、`:290-294`
- **描述**：`append([])` 写入 4 字节零头；读取端在该位置直接结束，同段其后已写入的记录全部不可见。一旦内部调用方传入空记录，等价于段内数据截断（`stats` 少算、消费丢失），且无任何日志。详细设计 `:362` 要求取值 1..64MiB，写入侧只校验上界。

### [一般] M7 详细设计 §5.8/§5.11/§5.12/§6.4/§6.5/§6.11 与实现漂移

- **位置**：`fmq/doc/详细设计.md:337`、`:760`、`:329-344`、`:758`、`:864`、`:727-728`、`:448`、`:446-452`、`:120`、`:407-433`、`:790`
- **描述**：
  - `:337` 与 `:760` 把 `openFrom` 写成游标读流；实现用 `openRecordsFrom`（`GroupCursor.cj:477`），`openFrom` 零调用。§5.8 签名块（`:329-344`）缺 `openRecordsFrom`/`segmentsOrEmpty`/`removeById`/`scanAfter`/`countAll`。
  - `:758` 写「`owner = None`」，实现 `GroupCursor.cj:174` 写 `owner = Some(subscription.subscribedId)`。
  - `:864` 称 `backlog/lagMs` 由 `QueueLog.scanAfter(committed)` 计算，实际由 `ConsumeService.stats` 自写扫描；`scanAfter` 仅测试调用。
  - `:727-728` 称读取端「抛 `QueueCorruptionException`」，游标路径实际返回 `None` 并记 ERROR（仅 `scanAfter` 抛）。
  - `:448` `CursorStore.init(offsetRoot: String)` 与实现 `metaRoot` 参数名不符；`:446-452` 未列 `removeGroup`/`hasCursor`；`CursorCatalog`（`:120` 表内声明）没有 §5.x 详细小节。
  - `:407-433` 未列 `unsupportedSkipped`（实现 `GroupCursor.cj:343-349`）。
  - `:790` 「跳到现存最老的段」与实现/用例相反（M3）。

  影响：按文档写调用方会使用不存在的语义；符号清单无法作为「文档-实现一致」的验收基线（任务 29.4 声称逐节核对过）。

### [一般] M8 规格要求的「跳过计数」只存在于测试，生产不可见

- **位置**：`fmq/src/queue/GroupCursor.cj:325-349`；`consume-semantics/spec.md:146-152`、`:256-264`
- **描述**：`unreadableSkipped`/`noMatchSkipped`/`unsupportedSkipped` 只被 `GroupCursor_test` 断言，`stats` TSV、`MQMetrics`、日志汇总都不输出。线上「消息被越过」无法观测，规格的可观测意图未落地，只能靠 DEBUG/WARN 文本 grep。

### [一般] M9 段缺失 WARN 未限流，全段删除时每次 CONSUME 刷两条 WARN

- **位置**：`fmq/src/queue/QueueLog.cj:112-119`
- **描述**：`startPositionOf` 在段不存在时无条件 WARN；`GroupCursor` 每轮 `next()` 都重新开流，因此「位点段被删/目录被删」状态下每次消费产生 1–2 行 WARN。规格要求「同一位置的重复不可读 SHALL 限流记录，避免刷屏」（queue-storage/spec.md:287-291）；高频轮询会淹没日志、抬高 I/O。

### [一般] M10 关键场景缺口（Requirement 有、用例无）

- **位置**：见下列各项
- **描述**：
  1. 1 MiB / 多字节长度头往返：无（`QueueLog_test.cj` 记录 ≤ 96B；`MAX_RECORD_SIZE` 边界仅测 64MiB+1 拒绝）。
  2. 「落盘后可持久」（queue-storage/spec.md:131-134）：无 fsync/掉电模拟用例。
  3. 「删除中途崩溃」（`:153-156`）：无。
  4. 死信「组间隔离」（consume-semantics/spec.md:101-104）：GroupCursor 无 A 组进死信、B 组仍消费的用例。
  5. 「后加入的匹配订阅」（`:164-167`）：无。
  6. 「已越过的位置 ACK」（`:136-139`）：无（committed 之前、已进死信两种）。
  7. 「段仍在但记录损坏」（queue-storage/spec.md:319-322）：无 GroupCursor 层用例。
  8. 「中途失败回滚」的磁盘断言（`:282-285`）：无。
  9. 「跨段不拼接」的正常路径（`:259-262`）：无「记录刚好放不下 → 整条写入新段」断言。

  影响：以上多为数据正确性/恢复路径，缺失意味着回归不可见。

### [一般] M11 弱断言清单

- **位置**：`GroupCursor_test.cj:267-271`、`:578-580`、`:742-773`；`QueueManager_test.cj:121-124`；`DeadLetterQueue_test.cj:133-137`；`QueueLog_test.cj:323-340`
- **描述**：
  - 死信条目只断言 3 个字段；规格要求「原始记录字节、topic、queueIndex、组名、原位置、投递次数、入死信时间」（consume-semantics/spec.md:106-109），仅 `DeadLetterQueue_test` 验证了字段往返，未验证真实入死信条目。
  - 并发用例只断言 `committed.seq > 1 || offset > 0`，规格要求「`committed` 单调不减」（`:213`）。
  - 用零长度头模拟「段被清理」，夹具与场景不符（M1）。
  - 回滚用例未断言磁盘（M10-8）。
  - 死信清理只断言 `removed >= 1`，未断言具体段号/剩余段数。
  - 超大声明长度用例无法证明「未分配 4 GiB」，只能证明不崩溃。

  影响：用例通过不等于规格满足，尤其死信内容与并发单调性。

### [一般] M12 延迟的「未来时间 > 5 分钟视为到期」未写入规格与设计

- **位置**：`fmq/src/queue/GroupCursor.cj:541-557`
- **描述**：`published > current + 5min` 时直接投递并 WARN。规格只说「无法解析发布时间 → 视为到期」（consume-semantics/spec.md:223），设计 §6.11（`详细设计.md:870-874`）也未提该容差。真实未来时间的消息（时钟漂移 > 5min）会提前投递，违反「发布时间 + delaying ≤ 当前时间才可投递」；行为不可预期且无文档依据。

## R4

### [严重] 管理端「服务端错误 / 载荷类型不符」两个场景的用例只断言退出码，A65 回归不可见

- **位置**：`fmq/src/server/MQManager_test.cj:104-121`、`:124-142`
- **描述**：两个用例唯一断言是 `manager.run() == 1`。但「服务端回 `ERROR(INTERNAL)`」「回 RESP 但非快照」「真的连不上」三条路径的退出码都是 1（`MQManager.cj:227-280`）；用例既不检查 stdout，也不能区分实际渲染的是 `boom from server` / `响应不是 MQMetaSnapshot` 还是 `无法连接消息队列服务`。`openspec/specs/fmq/manager-cli/spec.md:109-117` 的两条 Scenario 都写「MUST NOT 输出『无法连接』」，而用例在「把 `printError` 改回 `connectionFailed`」时仍然全绿，A65 的修复没有回归保护；同时违反 server-runtime/spec.md:388-391「用例 SHALL NOT 仅断言退出码而不检查输出」。

### [一般] 管理端把「响应格式异常」兜底成「无法连接」

- **位置**：`fmq/src/manager/MQManager.cj:214`；`fmq/src/manager/MQManagerOutput.cj:80`
- **描述**：`catch (_: Exception) { connectionFailed() }` 兜底；`stats` 的 TSV 解析在渲染层完成，若服务端给出非数字的 `delaying`（版本漂移、串包），`Int64.parse` 抛 `IllegalArgumentException`，被 `withClient` 的兜底 catch 归为连接失败，打印「无法连接消息队列服务」。任何 `body()` 内的非 `MQServiceFailure` 异常都会被误分类，与 manager-cli 规格「服务端可达但返回 ERROR 时 MUST NOT 使用该文案」的意图相反，运维会误判为网络问题；该路径无用例。

### [一般] 启动顺序与规格「先定时器、后监听」相反，且端口在装配期即绑定

- **位置**：`fmq/src/server/MQServer.cj:114-115`、`:170-180`
- **描述**：`f_net` 的 `Server.init` 内部 `newServerSocket(bindAt)`（`f_net/src/server/Server.cj:117`）在 `MQServer` 构造期就完成 bind/listen；`start()` 先起 accept 协程，再起备份/清理/反熵/巡检。server-runtime/spec.md:189-192 要求「打开本机队列 → 启动清理/备份定时器 → 启动监听」的 SHALL 顺序被违反；存在「已可接受请求、但备份/清理/反熵未运行」的窗口（单节点基本无害，但备份窗口内发布的消息不会被复制）；若构造后段（如 `LogCleaner`）抛错，端口已被占用到进程退出。

### [一般] `BackupStore` 关闭后写入完全静默，与规格「记 DEBUG/WARN（限流）」冲突

- **位置**：`fmq/src/server/BackupStore.cj:53-55`、`:106-108`、`:79-81`
- **描述**：`closed.load()` 为真时直接 `return`，无任何日志；`append` 内的 `LogClosedException` 也只是静默丢弃。server-runtime/spec.md:349-354 明确要求「关闭后到达的写入 SHALL 被安全丢弃并记 DEBUG/WARN（限流）」，实现不满足；而 `README.md:129-130` 写的是「静默丢弃」，规格与 README 互相矛盾。丢副本这件事在关闭期可能涉及数据可恢复性，静默会让排障失去线索。

### [一般] `MQMetrics.bump` 的「addIfAbsent + get」非原子，与删除并发时抛异常

- **位置**：`fmq/src/metrics/MQMetrics.cj:35-39`
- **描述**：`counters.addIfAbsent(key, AtomicInt64(0))` 与 `counters.get(key).getOrThrow().fetchAdd(1)` 两步之间若 `removeTopic` / `removeGroup`（`:49-74`）删掉该键，`get` 返回 `None`，`getOrThrow` 抛异常。调用点是 `GroupCursor.next` 的投递路径（`fmq/src/queue/GroupCursor.cj:182-193`），此时 `entry.owner/delivered` 已更新。删除主题/组与在途消费并发时，消费者会随机收到一次 `ERROR(INTERNAL)`；记录停留在「已分配给旧订阅」状态，要等 `ackTimeout` 后才会重投。metrics/spec.md:99-118 要求「清理 SHALL 与读取并发安全，不得因遍历删除抛异常」，且「并发读取」Scenario 没有用例。

### [一般] 断链清理：实现是「代次 + 释放」，文档写的是 `removeByBuffer` 与「与 LogCleaner 同一批定时器」

- **位置**：`fmq/doc/详细设计.md:819-820`；`fmq/src/server/MQServer.cj:177-180`、`:285-301`；`fmq/src/server/SubscriberRegistry.cj:137`
- **描述**：文档称「在 `MQServer` 的巡检（与 `LogCleaner` 同一批定时器）里对 `buffer.isClosed()` 的订阅做清理（`removeByBuffer`）」。实际是独立的 2s `Timer.repeat`（`CLEANUP_INTERVAL`）调用 `cleanupSubscribers()`，按「订阅 id + generation」摘除并 `consume.releaseSubscription`；`removeByBuffer` 在生产路径上没有调用方（仅 `MQServer_test.cj:497` 使用）。文档会误导维护者把 `removeByBuffer` 当成生产入口（它没有释放已分配记录，也没有代次保护，直接接回生产会退化为 A55/A60 的缺陷）；巡检周期（2s vs LogCleaner 5min）也与文档不符。

### [一般] 关闭顺序：README / 详细设计 的「完整列表」缺订阅表与 `queues.sync`

- **位置**：`fmq/README.md:44-46`、`fmq/README_en.md:48-51`、`fmq/doc/详细设计.md:682-684`；实现 `fmq/src/server/MQServer.cj:197-213`
- **描述**：实现 `closeSteps` 为 server → cleanupTimer → antiEntropy → backup → cleaner → consume → **subscribers.clear()** → backupStore → **queues.sync()** → queues → deadLetter → meta → registry。文档列表在 consume 之后直接跳到 backup store，漏掉订阅表，也没有体现 `queues.sync` 是独立步骤。`fix-fmq-full-audit` 的 docs 规格要求「含退出钩子注册点与『相反顺序释放』的**完整**列表」（`.../specs/docs/spec.md:35-38`），当前列表不完整；排查关闭问题时容易漏看订阅释放。

### [一般] 详细设计 §5 的签名与实现不符（main / onPublish / SubscriberRegistry / MQManagerOutput）

- **位置**：`fmq/doc/详细设计.md:159-168`、`:564`、`:581-590`、`:657-660`
- **描述**：
  - `main` 只写 `server → MQServer(MQConfig).run()`；实际是 `MQServer()` + `installExitHooks` + 注入式 `dispatch/dispatchWith`（`main.cj:37-118`），文档也未列出 `dispatch`/`dispatchWith`/`installExitHooks`。
  - `onPublish(buffer: SocketBuffer, request: Message): ?Message`；实际 `onPublish(request): Message`（`MQCommandExecutor.cj:237`）。
  - `register(subscription, buffer)`、`byGroup(topic, group)`；实际 `register(info)`、`byGroupOf`，且未列 `activeIds`/`infos`/`count`/`generations`（`SubscriberRegistry.cj:41,99,186,208`）。
  - `MQManagerOutput` 只列 `table`/`error`；实际另有 `registeredTopic`/`topicList`/`stats`/`assignments`/`width` 与 4 个公开常量（`MQManagerOutput.cj:25-110`）。

  影响：docs 规格要求「签名可对照」；按文档写调用会编译失败，测试/评审对照失真。

### [一般] 详细设计 §3 描述的配置读取方式与实现不符

- **位置**：`fmq/doc/详细设计.md:69-73`（及 `:24`）
- **描述**：文档写「`Config.getValue<UInt16>(...) ?? 2350u16`」「`port` 用 `MQHost.parseHost` 解析」。实现全部走 `Config.getString` + `strictPort()`（`UInt16.tryParse`）/`strictInt64`/`strictDuration`（`MQConfig.cj:147-178`），只有 `nodes` 项的校验才用 `MQHost.parseHost`（`MQConfig.cj:315-339`）。文档描述的正是 A63 修复前的旧实现（`?? default` 会静默回落），与「非法值不回落」的规格直接矛盾；按文档评审会误判 A63 未落地。包依赖表 `:24` 还列了实现并未使用的 `f_util`/`f_data`（`MQConfig.cj:180-185`）。

### [一般] 子命令数量「六 / 七」在文档与源码注释中并存

- **位置**：`fmq/doc/详细设计.md:946`、`fmq/src/manager/MQManager.cj:29`、`fmq/src/server/MQManager_test.cj:34`、`fmq/doc/开发计划.md:127,443,500,520`、`openspec/specs/fmq/server-runtime/spec.md:129`；对照 `详细设计.md:149,647`、`MQUsage.cj:48`、`manager-cli/spec.md:39`
- **描述**：`stats` 加入后总数是 7，但上述位置仍写「六」；`server-runtime` 的「管理端帮助」Scenario 还要求「输出含六个子命令」，与 manager-cli 的「7 个子命令」自相矛盾。docs 规格 `.../specs/docs/spec.md:51-54` 明确要求「README 与管理端 `--help` 均为 7 个子命令，名称一致」，现有表述会让验收脚本与人工核对结论打架。

### [一般] 详细设计 §7 的 `registerTopic` 参数与输出格式与实现不符

- **位置**：`fmq/doc/详细设计.md:880`；实现 `fmq/src/manager/MQManager.cj:56-72`、`MQManagerOutput.cj:43-47`
- **描述**：文档参数写 `[delayingMs]`，输出写「队列 0..N-1，延迟：<dur>，分配：0→A 1→B …」；实际第三个操作数是 `delaying=<DurationString>`（`delaying=1m1s`），输出为「队列 0..3（共 4 个），延迟：0s，分配：0→0,1→1」（逗号分隔 + 「共 N 个」）。与 `MQUsage.managerHelp`、README 示例、`MQManagerOutput_test` 均不一致；用户按设计文档写 `registerTopic /t 2 1m1s` 会得到「第三个参数必须是 delaying=<时长>」并返回 2。

### [一般] 「默认值」「帮助文本完整」两个 Scenario 属弱覆盖

- **位置**：`fmq/src/config/MQConfig_test.cj:31-55`、`:246-251`；规格 `server-runtime/spec.md:31-44`
- **描述**：名为「默认值」的段落先用 `Config.set` 把 11 个键全部显式写成默认值，再断言解析结果，`Config.getString` 的 `None` 分支（真正的「未设置 → 取默认值」）完全没有执行；`helpText` 只断言了 10 个键名，`mqServer_tombstoneTTL`、`mqServer_antiEntropyInterval` 未断言，也没有断言任何默认值文本（如 `2350`、`10s`、`1G`）。若把某个 `DEFAULT_*` 常量改错、或把 `?? fallback` 分支删掉，用例仍全绿；Scenario「帮助文本完整 … 含全部配置项名与默认值」实际未验证。

### [一般] 「配置缺失」路径无用例

- **位置**：`fmq/src/manager/MQManager.cj:42-45`；规格 `manager-cli/spec.md:104-107`；`MQManagerArgs.cj:83-87`
- **描述**：`args.server.isEmpty()` 分支（打印「无法连接消息队列服务」返回 1）没有任何用例覆盖；`MQManagerArgs.parse` 在 `mqServer_port` 缺失时返回 `Some` 且 `server == ""`，这条组合路径未被测试。该分支若被误改为抛异常/返回 0 或用例无法发现；与「端口不可达」混淆后覆盖矩阵看起来是满的。

### [一般] 「发布触发备份」场景无用例

- **位置**：规格 `server-runtime/spec.md:398-401`；实现 `MQCommandExecutor.cj:280`；测试 `MQCommandExecutor_test.cj:402-415`
- **描述**：现有用例只测「收到 `PUBLISH(backup)` 后副本落盘、不进本队列」（接收侧）；「`backup = 1` 时发布一条 → 备份复制器收到一次入队（用替身断言）」没有对应用例——fixture 里 `BackupReplicator(registry, 0)`，且没有可注入的 replicator 替身（`ExecutorFixture` 私有字段）。`onPublish` 里 `backup.record(...)` 若被删/被条件包住，发布仍返回成功，用例全绿，副本静默丢失。

### [一般] 退出钩子：「manager 不安装」无用例，`toExitGracefully()` 调用点无覆盖

- **位置**：`fmq/src/main.cj:115-116`；规格 `server-runtime/spec.md:316-331`
- **描述**：`installExitHooks` 做了注入测试（`MQServer_test.cj:386-401`），但 (a) `runServer()` 里 `ExitCallbacks.toExitGracefully()` 这半步没有被任何用例观察；(b) 「执行 `fmq manager listTopics` 不注册 MQ 退出钩子」没有用例（`runManager` 为 private，也没有钩子计数入口）。若把 `installExitHooks`/`toExitGracefully` 移到 `dispatch` 之前（对所有子命令生效），现有用例仍全绿；manager 短命令可能被异常的信号处理行为影响。

### [一般] 管理端「非绝对路径主题」无用例

- **位置**：规格 `manager-cli/spec.md:129-132`；对照 `MQCommandExecutor_test.cj:202-211`；`MQManager.cj:117-122`
- **描述**：`MQManager.registerTopic("order", ...)` 会走网络由服务端拒绝并打印 `INVALID_TOPIC` 文案，但 manager 包/CLI 层没有对应用例；`MQManager` 也没有像组名那样的本地前置校验（只校验 group）。该 Scenario 只能靠 executor 用例间接等价，「退出码非 0 + 打印主题非法」的渲染路径未验证。

### [一般] `stats` 三个 CLI 场景只断言退出码

- **位置**：`fmq/src/server/MQManager_test.cj:224-235`、`:248-252`；规格 `manager-cli/spec.md:184-197`
- **描述**：「查询全部主题 → 输出包含两个主题」「按主题 → 只输出该主题」「未知主题 → 输出（空）」在 CLI 层都只断言 `run() == 0`；输出断言只存在于渲染层的 `MQManagerOutput_test.cj:107-137` 和 `ConsumeService_test` 的 TSV 层，没有贯通「请求 → 渲染」。服务端返回空串、manager 渲染成空行、或 `stats("")` 误传给服务端 `/` 等组合缺陷不可见。

### [一般] 「非法组名不发请求」的断言无法区分行为

- **位置**：`fmq/src/server/MQManager_test.cj:144-157`
- **描述**：注释写「指向不存在的地址也应当先被本地校验挡下（否则会打印『无法连接』）」，但断言只有 `offline.run() == 1`——本地拒绝、连接失败、服务端拒绝三者都是 1；`deleteSubscribeGroup /t "g/1"` 同样只断言 1。若删掉 `MQManager.cj:119-122` / `130-133` 的本地校验，用例仍然通过（只是文案从 `INVALID_GROUP` 变成「无法连接」），A05 的「不发请求」承诺失去保护。

### [一般] 「关闭释放」未断言队列已 `sync`

- **位置**：`fmq/src/server/MQServer_test.cj:518-539`；规格 `server-runtime/spec.md:403-406`
- **描述**：用例断言了订阅表清空与端口可再绑定，但没有断言 `queues.sync()` 执行（无注入点/观测点）；`closeSteps` 里 `queues.sync` 与 `queues.close` 是两个独立步骤，前者失败会被记为失败步骤但不会体现在任何用例里。`queues.sync` 被误删时用例仍全绿，重启可能丢最后一段未 fsync 的数据（`syncInterval=1` 时风险较小，但语义上仍属「关闭完整释放」）。

### [一般] 测试共享进程级 `Config`，缺少隔离手段，存在并行串扰

- **位置**：`fmq/src/config/MQConfig_test.cj:25-30`、`fmq/src/Main_test.cj:110-122`、`fmq/src/manager/MQManagerArgs_test.cj:36-41`
- **描述**：`MQConfig` 全部静态读取进程级 `Config`；`MQConfig_test` 在注释里承认「用例必须串行读写」，但没有任何强制串行/恢复机制，且结束时把配置留在 `PORT=2350, hosts=h1:2350,h2:2351,h3:2352, BACKUP=2, THRESHOLD=1`；`Main_test`/`MQManagerArgs_test` 也各自 `Config.set`。一旦测试框架并行调度同进程用例（或新增用例按包并行），会出现「端口不在节点表」「阈值非法」之类的随机失败；`Main_test.serverStartupValidationFailureReturnsTwo` 只恢复 `mqServer_backup`，也会把残留配置带给后续用例。

### [一般] 命令处理矩阵存在成组的分支缺口

- **位置**：`fmq/src/server/MQCommandExecutor.cj:315-317`、`:326-329`、`:131-135`、`:150-152`、`:260`、`:168-180`
- **描述**：tags 非法、订阅时本机无队列 `NOT_OWNER`、`REGISTER` 意外载荷、未知 internal kind、`PUBLISH` 收到非 backup 的内部信封、未知 metaSync 子载荷，上述 6 条错误分支都没有用例；server-runtime/spec.md:136-152 的命令矩阵虽未逐条列举这些错误码，但「未知命令或无法解析的载荷 SHALL 回 ERROR(INTERNAL)」的兜底语义只覆盖了 `PUBLISH` 垃圾载荷与 `PING`。这些分支属于安全兜底——误改成 `throw`、返回 `None`（不回包导致客户端挂起）或落到错误的删除分支都不会被发现；其中 `SUBSCRIBE` 的 `NOT_OWNER` 与「客户端连到非 owner 节点」的运维场景直接相关。

### [一般] `mqServer_port = 0` 的校验分支无用例

- **位置**：`fmq/src/config/MQConfig.cj:288-290`；规格 `server-runtime/spec.md:51-63`；`MQConfig_test.cj:166-193`
- **描述**：`validate()` 对 `port == 0` 有专门报错，但「零值」用例集只覆盖 ack/maxSize/logTTL/deadTTL/tombstone/antiEntropy，没有 `PORT=0`。`UInt16.tryParse("0")` 合法，若删掉该判断，服务端会尝试绑定 0（随机端口）并「成功启动」，与节点表定位语义冲突，且用例不会报错。

## R5

### [一般] 管理端 11/12 个用例只断言退出码，直接违反规格自身的验收条款

- **位置**：`fmq/src/server/MQManager_test.cj:104`、`:125`、`:145`、`:160`、`:182`、`:192`、`:203`、`:216`、`:224`、`:238`、`:249`；`fmq/src/server/MQServer_test.cj:315`
- **描述**：上述 12 个用例的全部 `@Assert` 都是 `manager.run() == N` 一种形式（`MQManager_test` 12 个用例中 11 个如此，`MQServer_test` 1 个如此）。典型：`serverErrorIsNotReportedAsConnectionFailure:104-121` 与 `nonSnapshotResponseIsProtocolError:125-142` 只断言 `run() == 1`，而三条失败路径退出码都为 1；`sixSubcommandsSucceedAndMutateState:160-179` 名字声称验证状态变更，实际只断言 10 次退出码；`emptyListsReturnZero:192-200`、`registerTopicWithDelayingAndStats:224-235` 同样不检查输出内容。server-runtime/spec.md:387-391 明确要求「用例 SHALL NOT 仅断言退出码而不检查输出或状态」，manager-cli/spec.md:232-237 要求输出可断言。现有写法使 A65（错误分类）的回归完全不可见；`sixSubcommandsSucceedAndMutateState` 的名实不符会误导维护者认为状态已被验证。（与 R4 严重项同源，R4 已单独计分，本轮按全局普遍性记一般。）

### [一般] 「帮助文本完整」用例漏测 2 个配置项，且不校验默认值

- **位置**：`fmq/src/MQUsage_test.cj:31-44`；实现 `fmq/src/config/MQConfig.cj:348-363`
- **描述**：`serverHelp()` 实际输出 12 个配置项（含 `mqServer_tombstoneTTL`、`mqServer_antiEntropyInterval`），用例只断言了 10 个键名，漏掉上述两项；同时只断言键名、不校验规格要求的「默认值」。server-runtime/spec.md:41-44 的 Scenario 要求「输出含全部配置项名与默认值」；若有人删掉 `tombstoneTTL`/`antiEntropyInterval` 两行，或用例外的默认值被改错，测试不会失败。

### [一般] 测试替身被编入生产源码树

- **位置**：`f_mq/src/client/test/MQStubServer.cj:16,32`、`fmq/src/test/TestDirs.cj:16,32`
- **描述**：两者都不以 `_test.cj` 结尾，按 `cjpm` 规则属于生产源文件（`cjpm.toml` 的 `include = ["src", ...]`），会随 `f_mq` 动态库 / `fmq` 可执行文件一起编译；`MQStubServer` 还是 `public`，可通过 `import fountain::f_mq.client.test.*` 被外部使用。生产代码对二者零引用。测试基础设施（真实 socket 监听、`atExit` 清理、随机端口分配）进入生产产物，增加二进制体积与启动期依赖面；`TestDirs` 的 `atExit` 若被误用会在生产进程注册清理钩子。

### [一般] 退订幂等：规格承诺“两次都不抛”，实现与用例都抛

- **位置**：`f_mq/src/client/MQClient.cj:368-395`；用例 `f_mq/src/client/test/MQClient_test.cj:752-775`；规格 `openspec/specs/f-mq/client/spec.md:210-213`
- **描述**：规格 Scenario 要求「对同一 id 连续退订两次，第二次服务端回 `SUBSCRIBE_NOT_EXIST` → 两次调用都不抛异常」。实现第一次成功后即从 `subscriptions` 删除；第二次调用 `subscriptionOf` 返回 `None`，直接抛 `MQServiceException(SUBSCRIBE_NOT_EXIST)`，根本没有发出第二次请求。用例 `unsubscribeIsIdempotentOnServerAndRejectsUnknownId` 断言的正是这个抛异常行为（`:768-775`），与规格相反。按规格编写的调用方（超时重试退订）会收到异常并误判失败；「未知 id」与「已成功退订的 id」在客户端不可区分，违背幂等承诺。当前用例把错误行为固化。

### [一般] 段恢复语义：README/详细设计/consume 规格说“最老段”，实现/queue 规格/用例说“更大段”

- **位置**：`fmq/README.md:128`、`fmq/README_en.md:152`、`fmq/doc/详细设计.md:790`；`fmq/consume-semantics/spec.md:294`；实现 `fmq/src/queue/GroupCursor.cj:503-533`；`fmq/queue-storage/spec.md:80-83`；用例 `fmq/src/queue/GroupCursor_test.cj:502-527`
- **描述**：三份文档写「位点所在段被删后跳到现存最老段」，而实现与 queue-storage 规格、用例 `startingSegmentHoleResumesAtNextSegment` 都是「跳到最接近的更大段」。两种语义的数据后果相反：跳最老段会重复投递（at-least-once），跳更大段会跳过中间消息（丢消息）。运维按 README 判断「只会重复不会丢」，实际可能丢消息；新维护者按任一文档修改都会与另一份冲突。R3 已按一般记录（M3），本轮从「用例与文档相反」角度再次确认，三份文档均未修。

### [一般] 协议规格仍保留已废弃的「内部消息的两种 kind」场景

- **位置**：`openspec/specs/f-mq/protocol/spec.md:114-118`（两种）与 `:120-125`（三种）；`tasks.md:334`
- **描述**：同一 Requirement 下同时存在「内部消息的两种 kind」和「内部消息的三种 kind」两个 Scenario，前者不含 `stats`，与后者及 `MQInternalKind` 的三值（`MQConstants.cj:76-78`）矛盾。`tasks.md:334`（V9）声称「删除过时『两种 kind』场景、补墓碑子载荷」，但主规格仍保留该场景。规格自相矛盾，验收时无法判断以哪条为准；台账「已删除」的勾选不实，属于文档任务未闭环。

### [一般] 协议规格的延迟构造示例使用位置参数，照抄无法编译

- **位置**：`openspec/specs/f-mq/protocol/spec.md:319`、`:324`；实现 `f_mq/src/base/model/MQTopicMeta.cj:33`、`f_mq/src/base/payload/MQTopicAssignment.cj:43`
- **描述**：规格示例写 `MQTopicMeta("/t", 2, 61000)` 与 `MQTopicAssignment("/t", 2, 0, [0, 1], 61000)`；两个构造函数都把延迟声明为具名参数 `delayingMs!: Int64 = 0`，第三/第五个位置参数不存在，按示例编码会编译失败。`docs/spec.md:23-26` 要求「签名可对照、参数个数/顺序/类型一致」；示例是最直接的对照物，当前示例本身不可用。

### [一般] `f_mq/doc/开发计划.md` 引用 4 个不存在的测试文件

- **位置**：`f_mq/doc/开发计划.md:256`、`:274`、`:294`、`:315`
- **描述**：分别引用 `src/client/MQClientPublish_test.cj`、`MQClientSubscribe_test.cj`、`MQClientConsume_test.cj`、`MQClientLifecycle_test.cj`，四个文件在仓库中均不存在；实际用例集中在 `f_mq/src/client/test/MQClient_test.cj`。`docs/spec.md:80-83` 的「无幽灵文件」要求（字面只约束 `tasks.md`）在此文档被违反；按计划文档找用例的维护者会扑空，也说明台账类文档没有纳入验收。

### [一般] 主题墓碑在更高 revision 重新注册后既不删除也不标记复活

- **位置**：`fmq/src/meta/MetaStore.cj:173-191`、`:388-393`、`:406-430`；规格 `fmq/metadata-cluster/spec.md:354-357`
- **描述**：规格 Scenario「新注册覆盖墓碑」允许「墓碑被移除或标记为已复活」；实现两者都没做。重新注册成功后，`topicTombstone(topic)` 仍返回旧墓碑，墓碑继续随快照扩散，`tombstoneFloor` 被压低，GC 因 `local.revision > tombstone.revision` 永不回收。删了又建的主题会永久携带墓碑，快照体积与同步成本随「删除-重建」次数增长；`applyRemoteGroup` 的 `topicTombstone` 检查仍会把该主题判为「已删除」，可能拒绝迟到的组。该 Scenario 目前只有组维度等价用例（`deletedGroupCanBeRecreatedWithHigherRevision`），主题维度无实现无用例。

## 统计

| 轮次 | 严重 | 一般 | 合计 |
|---|---:|---:|---:|
| R1 | 1 | 18 | 19 |
| R2 | 2 | 11 | 13 |
| R3 | 2 | 12 | 14 |
| R4 | 1 | 21 | 22 |
| R5 | 0 | 9 | 9 |
| **合计** | **6** | **71** | **77** |

## 专项结论

### 空测试 / 空函数

结论：干净，未发现空用例或占位实现。

- 432 个 `@TestCase`（`f_mq` 128 + `fmq` 304），1604 条 `@Assert`，平均 3.7 条/用例，与台账 `V38`（`f_mq 128/128`、`fmq 304/304`）一致。
- 空 `@TestCase` 0 个、无断言用例 0 个、只打印不断言 0 个、`@Ignore`/`@Disable`/`@Skip` 0 个、注释掉的用例 0 个、`throw NotImplemented` 0 个、`TODO`/`FIXME` 0 个、仅 `return` 的函数 0 个、被注释的代码块 0 个、`@Deprecated` 0 个。
- 仅 `@Assert(true)` 的用例 0 个：全树 5 处 `@Assert(true)` 都在 `match` 分支内（`MQMessageRecord_test.cj:189`、`MQProtocol_test.cj:47,105`、`MQClient_test.cj:132`、`MQCommandExecutor_test.cj:189`），且同 `match` 内有 `@Assert(false)` 反例。
- 空函数体 1 处：`f_mq/src/client/test/LogCapture_test.cj:48` 的 `flush(): Unit {}`，是 `OutputStream` 替身的合法空实现；`MQMatcher_test.cj:29` 的无参构造、`QueueManager.cj:106/:113` 的回滚空 `catch` 同属正常。
- 无 `@TestCase` 的测试文件 2 个：`LogCapture_test.cj`、`FakeTransport_test.cj`，均为测试替身文件。
- 真正的风险不在「空」，而在「名实不符」：`MQManager_test` 12 个用例中 11 个只断言退出码；`QueueLog_test.zeroLengthHeaderEndsTheStream` 把「损坏」固化成「干净结束」；`GroupCursor_test.unreadableRecordIsCounted` 用零长度头模拟段缺失。

### 死代码

结论：未发现整块死代码被当作生产入口，但符号级死代码是跨轮次未闭环项，共 4 类 30 项。

- R5 全局统计：完全死代码符号 6 个、仅测试使用 11 个（含 1 个合法钩子 `setCloseStepsOverride`）、只写字段/无消费者状态/协议字段 7 个、不可达分支 4 个、未使用 import 2 处；注释代码块与 `@Deprecated` 均为 0。
- 完全死代码：`MQDeregisterPayload.isGroup`、`SegmentMissingException`、`QueueLog.openFrom`、`MQSubscriptionInfo.isConnected`、`TestDirs.unique`、`TestDirs.cleanNamespace`。
- 仅测试使用：`hasMessage`、`isOk`、`respondEmpty`、`scanAfter`、`countAll`、`DeadLetterQueue.iterate`、`removeByBuffer`、`nodeAt`、`pendingPeerCount`、`pendingCount`/`flush` 等；其中 `openFrom`、`ownersOf` 仍被详细设计当作生产 API 描述。
- 只写字段/无消费者状态：`MQSubscription` 五个字段（`subscribedId`/`topic`/`subscribeGroup`/`tags`/`filter`，`filter` 的预编译结果被丢弃）、`MQMetaSnapshot.tombstoneFloor`、`MetaSyncer.pendingPeers`、`QueueManager.hasLocalQueues`、`MQMatcher.topicOf`、`MQAssignment.ownersOf`、`NodeRegistry.indexOf`。
- 不可达分支 4 处：`QueueLog.cj:305`（`length < 0`）、`main.cj:70-73`（`--help`）、`MQManager.cj:85-88`（`case _`）、`MetaSyncer.cj:408-410`（组 `Conflict`）。
- 未使用 import 2 处：`MQMessageRecord.cj:20`（`std.io.SeekPosition`）、`MQManager.cj:20`（`fountain::f_data.*`）；R1 另报 `MQMessageRecord.cj:19` 的 `std.fs.*`。
- 另有打包问题（非死代码）：`MQStubServer.cj`、`TestDirs.cj` 不以 `_test.cj` 结尾，被编入生产源集，`MQStubServer` 还是 `public`。

### 文档-实现一致性

结论：主干一致、局部漂移集中，且规格与文档之间存在多处互相矛盾；docs 类场景无自动化验收。

- 需求追踪规模：9 份规格 97 条 Requirement / 379 条 Scenario，346 条有直接或等价用例（91.3%），缺口 33 条；`docs` 规格 3 Requirement / 12 Scenario 自动化覆盖 0/12，只能人工核对。
- 主题与组元数据侧：`MQMetaSnapshot` 缺 3 字段且与 §4.1 自相矛盾、`MQSubscribeGroupMeta` 缺 `revision`/`origin`、门面 import 条数（三条 vs 五条）、`MQSubscription.cursor` 类型（`Int64` vs `AtomicInt64`）、`removeTopic` 返回类型（`?MQMetaTombstone` vs `Array`）、`NodeRegistry` 公开面（`self` vs `selfIndex`，缺 `isKnownDead`/`onRevived`）等 4 处签名漂移。
- 队列与消费侧：§5.8/§5.11/§5.12/§6.4/§6.5/§6.11 共 7 处漂移（`openFrom`、`owner = None`、`scanAfter`、抛损坏异常、`offsetRoot`/`metaRoot`、`CursorCatalog` 无小节、`unsupportedSkipped` 未列）。
- 服务端侧：§3 仍描述 A63 修复前的 `?? default` 读取方式、§5 四组签名（main/onPublish/SubscriberRegistry/MQManagerOutput）不符、§6.7 断链机制写 `removeByBuffer`、§7 `registerTopic` 参数与输出格式不符、关闭顺序列表缺 `subscribers`/`queues.sync`、「六/七子命令」并存。
- 规格自身矛盾 4 组：「位点段被删」四种说法（queue-storage 更大段 / consume-semantics 最老段 / 详细设计最老段 / 实现更大段）；退订幂等场景与需求正文相反；「两种 kind」与「三种 kind」并存；`delayingMs` 示例为位置参数、实现要求具名参数（照抄无法编译）。
- 台账与计划文件：`f_mq/doc/开发计划.md` 大段与现状不符，引用 4 个不存在的用例文件（`MQClientPublish/Subscribe/Consume/Lifecycle_test.cj`）；`tasks.md` 多处「已勾选」未落实（V9、26.1、W12/W29）。
- 实现缺失（规格已承诺）：主题墓碑在更高 revision 重新注册后既不删除也不标记复活；`pendingPeers` 不参与反熵选点/定向快照；`BackupStore` 关闭后写入不记 DEBUG/WARN。

### 测试覆盖

结论：数量与失败路径覆盖较好，但关键失败/恢复路径与「输出可断言」缺口集中，覆盖率 91.3% 属「正常路径扎实、退化路径薄弱」。

- 规模：432 个用例 / 1604 条断言 / 3.7 条每例；45 个测试文件；`f_mq` 128、`fmq` 304。
- 场景覆盖：346/379（91.3%）；缺口 33 条，其中「有实现、无用例」的高风险项 9 条（回滚失败、ack 重试、关闭后不重建、备份 states 数量校验、死信清理隔离、manager 退订钩子、发布触发备份、管理端配置缺失、指标并发清理）。
- 完全无用例的 Scenario：R1 记 7 个（protocol 4 + client 3），R2 记 6 个（含反熵补删除、主题维度墓碑复活、记录/状态数量不一致、单段删除失败、死信清理继续、owner 为负）；R3 记 9 个缺口场景（1 MiB 往返、落盘持久、删除中途崩溃、死信组间隔离、后加入订阅、已越过位置 ACK、段仍在但记录损坏、回滚磁盘断言、跨段不拼接）；R4 另记命令矩阵 6 条错误分支、`port=0`、配置缺失、发布触发备份、manager 钩子等。
- 弱断言集中区：管理端 12 个用例中 11 个只断言退出码；`publishTime` 标准 ID 用例恒真、跨时区用例未切时区；`slowReplicasDoNotBlockPublish` 阈值宽 4–20 倍；`zeroLengthHeaderEndsTheStream` 未断言 `corrupted`/ERROR；并发用例只断言「大于起点」而非「单调不减」；`failedOpenRollsBackAndLeavesNoTopic` 未断言磁盘。
- 关键正确性路径零覆盖：段末尾位点（C1）在 83 个队列用例中无一命中；记录大于段上限（C2）无用例；墓碑之后到达低版本条目、同 revision 不同 origin 的墓碑竞争（R2 两个严重项）在 102 个用例中无一覆盖。
- 跨轮次共性：R5 指出 R1–R4 的严重项在 HEAD `22c13ec4` 上仍成立，且「20 余个有实现、无用例」的洞多集中在失败注入、并发、崩溃恢复三类。
