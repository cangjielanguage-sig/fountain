# R5: fmq 服务端、CLI 与指标（生命周期 / 命令分发 / 订阅清理 / 管理端 / 统计口径）

审查时间：2026-10-21 08:05
审查基线：HEAD `5a133474`（全树审计，非 diff）
审查角色：只读，未修改任何被审文件，未运行会改变仓库状态的命令

### 审查范围

代码（`fmq/src`，14 个非测试源文件 + 11 个 `*_test.cj`，共 74 条用例）：

- `fmq/src/main.cj`、`Main_test.cj`
- `fmq/src/MQUsage.cj`、`MQUsage_test.cj`
- `fmq/src/config/MQConfig.cj`、`MQConfig_test.cj`
- `fmq/src/metrics/MQMetrics.cj`（无独立用例，由 `ConsumeService_test`/`GroupCursor_test` 间接覆盖）
- `fmq/src/server/MQServer.cj`、`MQServerOptions.cj`、`MQServer_test.cj`
- `fmq/src/server/MQCommandExecutor.cj`、`MQCommandExecutor_test.cj`
- `fmq/src/server/ConsumeService.cj`、`ConsumeService_test.cj`
- `fmq/src/server/SubscriberRegistry.cj`、`SubscriberRegistry_test.cj`
- `fmq/src/server/MQSubscriptionInfo.cj`（无用例）
- `fmq/src/server/BackupStore.cj`、`BackupStore_test.cj`
- `fmq/src/server/MQManager_test.cj`
- `fmq/src/manager/MQManagerArgs.cj`、`MQManagerArgs_test.cj`、`MQManagerOutput.cj`、`MQManagerOutput_test.cj`、`MQManager.cj`

依赖参照（只确认语义，不计入被审对象）：

- `f_net/src/server/Server.cj`（`bindAt` 绑定时机、`executor` 返回 `None` 的兜底、`close()` 行为）
- `f_base/src/signal.cj`（`ExitCallbacks.toExitGracefully` / `atExit`）、`f_bean/src/BeanFactory.cj:47`、`f_cache/src/HeapCache.cj:65`（仓库既有注册范式）
- `f_config/src/Config.cj`（环境变量 + 命令行参数覆盖）
- `f_mq/src/base/MQProtocol.cj`（`fail` / `asResult` / `asPayload` / `kindOf`）、`f_mq/src/base/MQConstants.cj`（错误码）
- `fmq/src/queue/{GroupCursor,QueueLog,QueueManager,CursorStore,DeadLetterQueue}.cj`、`fmq/src/cluster/{MetaSyncer,NodeRegistry,BackupReplicator,LogCleaner}.cj`

文档：

- `fmq/doc/spec/add-fmq-message-queue/specs/fmq/server-runtime/spec.md`
- `fmq/doc/spec/add-fmq-message-queue/specs/fmq/manager-cli/spec.md`
- `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/metrics/spec.md`
- `fmq/doc/spec/add-fmq-metrics-and-delay/specs/fmq/manager-cli/spec.md`
- `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/{server-runtime,manager-cli}/spec.md`
- `fmq/README.md`、`fmq/doc/详细设计.md`（§3、§5.17–5.22、§6.1、§6.7–6.11、§7、§9）、`fmq/doc/开发计划.md`（H1–H3、I1–I3）、`fmq/doc/backlog.md`
- `scripts/mq_e2e.sh`（仅作为覆盖证据）

### 发现

#### [S1] [严重] 生产路径没有任何退出钩子，`MQServer.close()` 不可达：备份末批丢弃、关闭顺序形同虚设

- **位置**：`fmq/src/server/MQServer.cj:121-127`（`run()` 只有 `while (!closed.load()) sleep(500ms)`）、`fmq/src/server/MQServer.cj:130-133`（`closed` 仅由 `close()` 置位）、`fmq/src/server/MQServer.cj:152-154`（`isClosed()` 无任何外部调用方）、`fmq/src/main.cj:71-83`（`runServer()` 直接 `server.run()`）
- **现象**：`fmq server` 的退出路径只有「进程被信号杀死」。`detailed design` 明确要求 `close()` 由退出回调触发（`详细设计.md:490-491`：「`close()` 由退出回调触发：先 `f_base.ExitCallbacks.toExitGracefully()` 安装信号处理，再 `atExit(priority, 回调)` 注册」；`详细设计.md:606`：「spawn { server.start(executor.execute) } 并阻塞等待关闭信号」），但全仓 `fmq/src/**` **没有任何** `ExitCallbacks`/`atExit`/信号处理调用（grep 为空；仓库既有范式见 `f_bean/src/BeanFactory.cj:47`、`f_cache/src/HeapCache.cj:65`）。因此 `MQServer.close()`（`MQServer.cj:130-150`）只可能被单元测试调用。
- **影响**：
  1. SIGTERM/SIGINT 走默认处理直接终止进程，`close()` 中「`server.close()` → 停定时器 → `backup.close()` → `cleaner.close()` → `consume.close()`（各 `GroupCursor.close()` 落盘 `committed`）→ `backupStore.close()` → `queues.sync()/close()` → `deadLetter.close()` → `meta.close()` → `registry.close()`」整条链**一次都不会执行**，与 server-runtime 规格「启动装配与关闭 … 关闭时按相反顺序释放」直接矛盾。
  2. `BackupReplicator.close()`（`fmq/src/cluster/BackupReplicator.cj:138-152`）是唯一的「关闭前最后一次 flush」；不可达意味着 `backup > 0` 时，最后一个 100ms 窗口内的在途批次（最多 64 条/批、队列上限 8192）必然丢失，而 `README.md:111-112` 承诺「关闭前已成功返回的写入会落盘」，恢复副本时会出现空洞。
  3. `run()` 也不可能返回，退出码永远拿不到 0；`MQServer.run()` 与整条关闭链在生产形态下零覆盖，S1 这类缺陷无法被现有用例发现。
  4. `scripts/mq_e2e.sh:29-37,175` 的 cleanup 与「停节点」都用 `kill`（SIGTERM），E2E 每次跑的都是「异常退出」路径，反而把崩溃式退出固化成了默认行为。
- **建议**：在 `MQServer.run()` 开始处（或 `main` 的 `runServer()`）调用 `ExitCallbacks.toExitGracefully()` 并 `ExitCallbacks.atExit(<priority>, {=> server.close()})`，与 `f_bean`/`f_cache` 保持同一范式；`run()` 改为「等待 `closed` 或退出回调触发」并在返回前确保 `close()` 已执行（例如回调内 close + `run()` 轮询 `isClosed()`）；补一条「SIGTERM 后 `BackupStore`/队列可读回、端口可再绑定」的回归锚点。

#### [G1] [一般] `close()` 无异常保护，任一环节抛错会中断后续释放且无法重试

- **位置**：`fmq/src/server/MQServer.cj:130-150`
- **现象**：`closed.compareAndSwap(false, true)` 置位后，`server.close()`、`timer.cancel()`、`backup.close()`、`cleaner.close()`、`consume.close()`、`queues.sync()`、`queues.close()`、`deadLetter.close()`、`meta.close()`、`registry.close()` 顺序裸调用，没有 `try/finally` 或逐项容错；`consume.close()` 内部会对每个 `GroupCursor` 调 `store.save`（`fmq/src/queue/GroupCursor.cj:357-369`），文件系统异常即可中断整条链。
- **影响**：一旦中途抛错，`closed` 已为 true → 再次 `close()` 直接返回（CAS 失败），剩余资源（队列日志句柄、死信日志、元数据、peer 连接）永远不会释放；在 S1 修复后这会成为退出阶段的真实风险（退出码/落盘都可能不完整）。
- **建议**：逐项 `try { ... } catch (e) { log.warn(...) }` 保证「后续步骤必定执行」，或改为 `try { 全链 } finally { 关键收尾 }`；`close()` 结束时汇总并记录失败项。

#### [G2] [一般] 「断链清理」规格场景零用例；清理依赖 2s 轮询，且与重订阅存在竞态

- **位置**：`fmq/src/server/MQServer.cj:157-169`（`cleanupSubscribers`）、`fmq/src/server/MQServer.cj:117`（`Timer.repeat(2s, 2s)`）、`fmq/src/server/SubscriberRegistry.cj:174-182`（`infos()` 快照）
- **现象**：`grep isDisconnected|cleanupSubscribers|断链` 在全部 `*_test.cj` 中无命中，server-runtime 规格 `:179-188` 的「连接关闭后订阅消失 … 同组其它订阅者能取到被释放的消息」没有任何用例覆盖（`MQServer_test.cj` 五个用例都不验证订阅表清理）。另外清理逻辑是「先取全量快照 → 逐个 `releaseSubscription` + `unregister`」，若在快照与 `unregister` 之间同一 `subscribedId` 已在新连接上重新 `SUBSCRIBE`（`MQCommandExecutor.cj:262-264` 用同一个 id 直接覆盖登记），会误删新订阅并释放其名下在途记录。
- **影响**：断链后该订阅名下的未确认记录只能等组内其他成员下一次 `consume` 时的 `sweep` 才释放（`ConsumeService.cj:74-75`），组内无其他在线成员时 `backlog` 与「组内无人在线则暂停」的语义无法区分；清理竞态会把正常重连的客户端打成「订阅不存在 / 消息丢失」。这类缺陷当前没有任何用例能发现。
- **建议**：补一条集成用例（客户端订阅 → 关闭连接 → 断言 `subscribers` 中该 id 消失、同组另一订阅能取到被退回的消息）；`unregister` 改为「按 `(subscribedId, connectionKey)` 条件删除」（`MQSubscriptionInfo.connectionKey` 已具备，见建议 1），避免误删重连订阅。

#### [G3] [一般] `acked` 指标不含 autoAck 投递；删除主题/组后计数器残留

- **位置**：`fmq/src/queue/GroupCursor.cj:176-178`（`autoAck` 投递后直接 `entry.decided = true`，不经过 `ack()`）、`fmq/src/queue/GroupCursor.cj:301-305`（`incAcked` 只在 `ack()` 内）、`fmq/src/server/ConsumeService.cj:184-192`（`stats` 读 `ackedOf`）、`fmq/src/metrics/MQMetrics.cj:27-28`（`counters` 无清理入口）、`fmq/src/server/MQCommandExecutor.cj:174-185`（删除时不触碰 metrics）
- **现象**：`autoAck = true` 的组每投递一条都会推进 `committed`（`backlog` 归零），但 `acked` 恒为 0；`delivered` 正常累加。另一方面 `MQMetrics` 的键是 `topic\0group`，主题/订阅组被 `deleteTopic`/`deleteSubscribeGroup` 删除后计数仍在，同名重建会直接继承旧值（metrics 规格 `:9-10` 的「按 `(topic, subscribeGroup)` 累计」没有说明「删除后归零」，但巡检会看到「刚建的组已 acked 1e6」）。
- **影响**：`stats` 是本模块唯一的运行期可观测面；`acked` 与 `backlog` 对 autoAck 组自相矛盾（`backlog=0` 而 `acked=0`），运维若用 `acked/delivered` 判断消费进度会误判；删除重建后的残留值会掩盖重建后的真实流量。
- **建议**：autoAck 投递处同步 `incAcked`（或在文档/规格里显式声明 autoAck 不计 acked，并让 `stats` 输出 `autoAck` 标识）；`MQMetrics` 增加 `clearTopic`/`clearGroup`，由 `cleanupAfterDelete` 调用。

#### [G4] [一般] `stats` 在扫描异常时静默给出 `backlog=0/lagMs=0`，且按「组 × 队列」重复全量扫描

- **位置**：`fmq/src/server/ConsumeService.cj:161-166`（`store.load` + `log.scanAfter(committed)`）、`fmq/src/queue/QueueLog.cj:125-126`（`catch (_: Exception) { return (0, None<DateTime>) }`）、`fmq/src/server/ConsumeService.cj:157-179`（组内逐队列扫描）
- **现象**：段被并发清理、目录不可读、记录损坏等任何异常都被 `scanAfter` 吞成 `(0, None)`，`stats` 据此输出「无积压、无延迟」，且不记日志。metrics 规格 `:15-16` 明确「指标必须与查询时刻的持久化状态一致，不得使用可能失真的估算值」——「读失败 = 0」正是失真值。另外 backlog/lag 的计算对每个 `(topic, group)` 的所有本地队列各做一次全量扫描，组数 G、记录数 N 时是 O(G×N) 重复 IO（README `:79-80` 只提示了「有一定耗时」）。
- **影响**：故障（段损坏/权限/并发删除）被伪装成「消费跟上了」，是本模块最容易被误信的假绿；大主题 + 多组时 `manager stats` 会长时间占满执行线程（无采样、无缓存）。
- **建议**：`scanAfter` 区分「无记录」与「读失败」（后者返回错误或 `?`），`stats` 对失败行输出显式标记（如 `-1`）并 `WARN`；同一次查询内每队列只扫一遍，把结果按组复用。

#### [G5] [一般] 配置校验不足，非法值静默回落默认值

- **位置**：`fmq/src/config/MQConfig.cj:225-254`（`validate` 仅校验 `backup < 0`、`nodes` 为空、端口重复/缺失、`deadMsgThreshold < 1`）、`fmq/src/config/MQConfig.cj:98-108`（`segmentedLogMaxSize` 解析失败直接返回 `1G`）、`fmq/src/config/MQConfig.cj:62-66`（`port` 取值失败直接返回 2350）
- **现象**：
  1. `mqServer_segmentedLogMaxSize=-1G` 或 `0`、`mqServer_ackTimeout=0s`、`mqServer_deadMsgTTL=-1h`、`mqServer_segmentedLogTTL=0s` 全部能通过 `validate()`；负/零 `maxFileSize` 会一路传到 `QueueLog`/`SegmentedLog`（`MQServer.cj:76,81,83`），把「启动期报错」推迟成「首次发布/首次轮转时行为异常」。
  2. `mqServer_segmentedLogMaxSize=not-a-size`、`mqServer_port=abc` 静默回落默认值：服务端按 2350 监听、按 1G 切段，与运维意图不符且无任何 WARN（`MQConfig_test.cj:82-85` 甚至把这个行为固化成期望）。
- **影响**：配置错误无法在启动期暴露（规格 `:40-43` 只枚举了 5 项，但 `详细设计.md:597` 承诺「配置读取与校验 → 失败退出码 2」）；最坏情况是「以为改了大段上限，实际没生效」。
- **建议**：`validate()` 增加 `segmentedLogMaxSize > 0`、`ackTimeout > 0`、两个 TTL `>= 0`、目录可创建/可写；解析失败时 `WARN` 或直接按「非法配置」退出（比静默回落更可诊断）。

#### [G6] [一般] `MQConfig.parsePort` 自实现 host:port 解析，违反「统一复用 `MQHost`」的增量规格且与装配期语义不一致

- **位置**：`fmq/src/config/MQConfig.cj:216-222`（`parsePort` 自切 `:` + `UInt16.tryParse`）、对照 `fmq/src/cluster/NodeRegistry.cj:49-52`（`MQHost.parseHost`）；规格 `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/server-runtime/spec.md:7-19`
- **现象**：增量规格要求「`host:port` 解析 SHALL 位于 `f_mq.base`（`MQHost.parseHost`），`f_mq.client` 与 `fmq` 均复用它 … 端口为 0 或越界时返回 `None`」。`NodeRegistry` 已复用，但 `MQConfig.selfIndex`/`validate` 仍用自实现的 `parsePort`：它接受 `h:0`（规格要求 `None`）、接受任意非空主机名（含非法字符），且只按「端口字符串相等」比较。于是 `mqClient_hosts="h:0,127.0.0.1:2350"` 时配置校验通过、`selfIndex` 定位成功，随后 `NodeRegistry` 构造抛 `IllegalArgumentException("invalid node 'h:0'…")`，错误信息来自装配期而非配置校验，且同一份配置在两处判定不一致。
- **影响**：配置校验结论不可信（G5 的延伸）；`fix-…/server-runtime` 的 Scenario「解析语义不变」在 `MQConfig` 侧不成立，后续再改 `MQHost` 语义会分裂成两套。
- **建议**：`MQConfig` 直接调用 `MQHost.parseHost`（取 `port` 用于比对），删除 `parsePort`；`validate()` 中把「节点表存在非法 entry」也作为启动期错误项。

#### [G7] [一般] `listTopics` / `listSubscribeGroups` 把服务端 `ERROR` 响应报成「无法连接消息队列服务」

- **位置**：`fmq/src/manager/MQManager.cj:263-269`（`requestSnapshot` 只用 `asPayload<MQMetaSnapshot>`，不判 `Command.ERROR`）、`fmq/src/manager/MQManager.cj:137-156`、`fmq/src/manager/MQManager.cj:158-179`（`case None => connectionFailed()`）
- **现象**：服务端对 `metaSync` 请求返回 `ERROR(MQResult(INTERNAL))`（如 `onInternal` 的 `unrecognized metaSync payload`，`MQCommandExecutor.cj:154`）或返回了非 `MQMetaSnapshot` 载荷时，`asPayload` 返回 `None`，manager 打印「错误：无法连接消息队列服务」并返回 1。连接其实成功、错误原因被替换。
- **影响**：与 manager-cli 规格 `:98-101`「SHALL 把服务端的 `MQResult.code != 0` 视为失败：打印错误码对应文案」不一致——文案属于另一种失败语义，排障时会被误导去查网络/端口（`connectionFailed` 是本模块唯一的 1 号退出提示）。
- **建议**：`requestSnapshot` 返回区分「连接失败 / 服务端 ERROR / 载荷不符」的三态（或直接返回 `?Message` 由调用方判 `Command.ERROR` 走 `printError`）。

#### [G8] [一般] 备份副本段没有任何清理路径，长期运行磁盘无界增长

- **位置**：`fmq/src/server/BackupStore.cj:38-42`（`root = <segmentedLogDir>/backup`，只创建、只 append）、`fmq/src/server/MQServer.cj:83`、`fmq/src/cluster/LogCleaner.cj:51-66`（只遍历 `queues.allLogs()` + `deadLetter`）
- **现象**：`LogCleaner.cleanOnce` 的清理对象只有「本地队列段」与「死信段」，备份目录（`<segmentedLogDir>/backup/<owner>/<topicEsc>/<queueIndex>/log_*.log`，README `:87-98` 已列出该布局）不在任何 TTL 策略内；`BackupStore` 除了 `close()` 没有任何段管理入口，`segmentedLogTTL`/`segmentedLogMaxSize` 对备份段只影响单段大小。
- **影响**：`mqServer_backup > 0` 的部署（`scripts/mq_e2e.sh:79-90` 就是 `backup=1`）每条消息额外落一份副本且永不删除，长时间运行必然写满 `segmentedLogDir` 所在分区，进而影响主队列写入。
- **建议**：给 `BackupStore` 提供 `segments()` + TTL 清理（可复用 `deadMsgTTL` 或新增 `mqServer_backupTTL`），并在 `LogCleaner` 中纳入同一轮；至少在 README「已知限制」中写明「备份副本需人工清理」。

#### [G9] [一般] 关键分支与开发计划要求的用例缺失（含「只断言退出码」的弱断言）

- **位置/现象**（逐项）：
  1. **内部 metaSync 变更分支无用例**：`MQCommandExecutor.cj:138-153`（`applyRemote` → `queues.openTopic`、`applyRemoteGroup`、`applyRemoteDelete` + `cleanupAfterDelete`）在 `MQCommandExecutor_test.cj` 中无对应用例；测试只覆盖「请求 → 快照」（`metaSyncRequestReturnsSnapshot`，`:331-343`）。复制落地的三条路径（建队列/建组/删组清理）靠 `MetaSyncer_test` 单测，跨不到「信封解码 + 分派 + 开队列」这一层。
  2. **未知命令分支无用例**：`MQCommandExecutor.cj:85-88`（`case _ => INTERNAL + WARN`）无命中；`garbagePayloadReturnsInternalError`（`:360-373`）覆盖的是「PUBLISH + 无法解析载荷」，不是「不支持的命令」。
  3. **`publishWithBackupEnqueues` 缺失**：`开发计划.md:465` 明确列了「`backup>0` 时 `BackupReplicator.record` 被调用」，但 `ExecutorFixture` 固定 `BackupReplicator(registry, 0)`（`MQCommandExecutor_test.cj:60`）且无 `BackupReplicator` 替身，发布→备份入队这条链路零断言。
  4. **`closeReleasesResources` 只做了一半**：`开发计划.md:488` 要求「`close()` 后端口可再绑定；队列 `sync` 已调用；订阅表清空」，`MQServer_test.cj:122-129` 只验证了端口重绑；`close()` 幂等（`MQServer.cj` 注释「幂等」）无二次调用用例；`订阅表清空` 既未实现也未断言。
  5. **`stats` 计数列覆盖不全**：`ConsumeService_test.cj:294-328` 只断言 `backlog/lagMs/delivered/acked`，metrics 规格 `:28-31` 的「投递两次 + 一条死信 → `redelivered>=1`、`deadLettered>=1`」没有在 `stats` 输出层验证（仅 `GroupCursor_test.cj:584-606` 在游标层断言）；多队列分组聚合也无用例。
  6. **manager 输出内容零断言**：`MQManager_test.cj:95-114`、`:158-170` 全部只断言退出码（`listTopics`/`listSubscribeGroups`/`stats` 的输出结构、`（空）` 占位、「（无）」组名都未校验），`开发计划.md:514-516` 要求的 `registerTopicPrintsAssignment`、`listTopicsShowsQueueNum` 实际不存在。
  7. **E2E 无 stats、无备份校验**：`scripts/mq_e2e.sh` 全程未调用 `manager stats`（只在 `:211-213` 打印自测耗时），也未校验 `backup=1` 下 `<dir>/logs/backup/...` 是否真的落盘；`deleteTopic`/`deleteSubscribeGroup` 在 E2E 中亦未出现。
- **影响**：R5 的「命令矩阵」「指标口径」「关闭清理」三块规格中，恰好是复制落地、备份、断连与关闭这几条最容易坏的路径没有用例兜底；弱断言（只比退出码）无法发现「渲染错列/错行」。
- **建议**：按上表逐条补锚点；`MQManager` 的渲染改为「返回字符串 + `main` 打印」（或注入输出回调），使输出内容可断言；E2E 增加 `manager stats` 字段断言与备份目录存在性检查。

#### [G10] [一般] 服务端成功启动路径不可测：`dispatch` 没有可注入的装配点，`run()/close()` 生产路径零单测

- **位置**：`fmq/src/main.cj:71-83`（`runServer` 直接 `MQServer()`）、`fmq/src/main.cj:36-69`、`fmq/src/server/MQServer.cj:121-127`
- **现象**：`开发计划.md:444` 要求「`dispatch(["server"])` 走 `MQServer`（测试里用可注入的装配点，断言被调用而不真正 listen）」，实现没有该注入点；`Main_test.cj:54-66` 只能测「配置非法 → 返回 2」，`dispatch(["server"])` 的合法路径一旦进入就会永久阻塞。`MQServer.run()` 同样无法在用例中调用（只能 `start()` 后手动 `close()`），因此「`run()` 永不返回」「`close()` 不可达」这类问题在测试层完全隐形（与 S1 互为因果）。
- **影响**：`main` 与 `MQServer` 的生产入口是 R5 中唯一「零覆盖」的可执行路径；同时 `MQConfigException` → 退出码映射之外的所有分发行为（`server` 分支、`run()` 返回值）都只能靠 E2E 的进程级观察。
- **建议**：给 `runServer` 增加 `serverFactory !: () -> MQServer` 之类的注入参数（或把「构造 + run」拆成可替换的函数值），用例注入假实现断言「被调用、参数来自 args」；`run()` 支持外部 `close()` 或接受 `stopSignal`，使关闭链可在进程内驱动。

#### [G11] [一般] 文档与实现不一致（README 的命令行覆盖、详细设计的子命令数量 / 输出格式 / sweep 定时器）

- **位置/现象**：
  1. `fmq/README.md:21`「配置项（均可用环境变量或命令行参数覆盖）」：`Config`（`f_config/src/Config.cj` 静态初始化）确实会读 `--key=value`，但 `main.cj:36-45` 只认 `args[0]` 为子命令，`fmq --mqServer_port=2400 server` 会被判为未知子命令并返回 2（而 `Config` 已把端口改成 2400），`fmq server --mqServer_port=2400` 才生效；文档没写这个限制。
  2. `fmq/doc/详细设计.md:782-796`（§7 表格只有 6 个子命令，且 `registerTopic` 输出写作「队列 0..N-1，分配：0→A 1→B」）、`:846`（§9「manager 六个子命令」）：实现已含 `stats` 共 7 个子命令，输出为「…，延迟：0s，分配：0→A,1→B」（`MQManager.cj:104-110`）。增量规格 `add-fmq-metrics-and-delay/.../manager-cli/spec.md` 已加 `stats`，但主设计未同步。
  3. `fmq/doc/详细设计.md:683-685`、`:753`（线程模型表「`GroupCursor.sweep` Timer … 粒度 `min(ackTimeout,1s)`」）：`GroupCursor` 内不存在任何 `Timer`（`grep Timer fmq/src/queue/GroupCursor.cj` 为空），`sweep` 只由 `ConsumeService.consume`（`ConsumeService.cj:74-75`）驱动。功能上暂无害（清理另有 `cleanupSubscribers` + `releaseSubscription`），但设计文档描述的线程模型与实际线程数不符。
  4. `fmq/doc/详细设计.md:733`「清理 … 调用 `removeByBuffer`」：实现走的是 `infos()` + `isDisconnected()` + `unregister`（`MQServer.cj:158-167`），`removeByBuffer` 无调用方（见建议 1）。
- **影响**：README 的命令行承诺会让运维写出「看起来生效、实际返回 2」的命令；设计文档的 6 子命令/输出格式/线程表会误导后续维护者按错误基线改动。
- **建议**：README 明确「全局配置参数必须写在子命令之后（或改用环境变量）」；详细设计 §7/§9 同步为 7 个子命令与实际输出格式；删除或补上 `sweep` 定时器描述；同步断链清理的实际实现。

### 已核对无问题项（供 R6 汇总时排除）

- **空测试/占位断言**：R5 范围 74 条用例全部有实质断言，无空函数体、无 `@Assert(true)`、无被注释/跳过的 `@TestCase`。
- **空函数/TODO**：`fmq/src/{server,manager,metrics,config}`、`main.cj`、`MQUsage.cj` 中 grep `TODO|FIXME|XXX|NotImplemented|未实现` 无命中；无空实现或仅 `return`/`throw` 的函数。
- **命令矩阵**：`REGISTER`(topic/group)、`DEREGISTER`、`PUBLISH`(record/backup)、`SUBSCRIBE`、`UNSUBSCRIBE`、`CONSUME`、`ACK` 的成功与主要错误分支均有对应用例；空消费、`TOPIC_NOT_EXIST`、`NOT_OWNER`、`GROUP_NOT_EXIST`、`SUBSCRIBE_NOT_EXIST`、`ACK_UNKNOWN`、垃圾载荷 → `INTERNAL` 均已覆盖。
- **`stats` 口径主体**：`backlog` 取 `committed` 之后的记录数、`lagMs` 取最早一条 `publishTime`、无组时输出空组行、未知主题不返回 `R`、查询无副作用（`statsDoesNotCreateCursorOrChangeLog`）——与 metrics 规格 `:5-67` 一致。
- **指标失败路径**：`stats` 之外，`MQMetrics` 的 `delivered/redelivered/deadLettered` 在 `GroupCursor_test.cj:584-606` 已有游标层断言。
- **无 `f_mq.client` 依赖**：`fmq/src/**` 非测试源码未 import `fountain::f_mq.client`（`fix-…/server-runtime` 规格 `:11-14` 满足）。
- **归档项不重复计数**：`backlog.md` P0 #1「备份 `states` 未被接收端使用」（`MQCommandExecutor.cj:194-196` 只 `append` 记录、忽略 `payload.states`）、#2「备份发送失败即丢」、P2「服务端关闭 drain」已在归档文档中记录为「本轮不实现」，本报告不再单独计为问题（但 S1 与「drain」不是同一件事：S1 是关闭流程根本不被触发）。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 11 |
| 建议（轻微） | 11 |

建议级明细（不改变结论，仅列位置与要点）：

1. `fmq/src/server/SubscriberRegistry.cj:110-125`（`removeByBuffer`）、`fmq/src/server/MQSubscriptionInfo.cj:60-65`（`isConnected`）、`fmq/src/server/SubscriberRegistry.cj:184-188`（`count`，仅测试用）、`fmq/src/server/MQSubscriptionInfo.cj:34-51,75-77`（`connectionKey`/`hasBuffer`）：生产路径均无调用方，是死代码；且 `hasBuffer` 在 buffer 已关闭时调 `remoteAddress.toString()` 会抛 `SocketException`。若按 G2 建议改为「按连接键条件删除」，正好把这些成员用起来，否则应删除。
2. `fmq/src/metrics/MQMetrics.cj:34-38`：`bump` 每次计数都 `counters.addIfAbsent(key, AtomicInt64(0))`，即每次投递/确认都新分配一个 `AtomicInt64`；建议先 `get` 命中则直接 `fetchAdd`，未命中再 `addIfAbsent`（或改用 `entryView`）。
3. `fmq/src/server/MQCommandExecutor.cj:230-241`（`bodyIsEvaluable`）+ `fmq/src/server/SubscriberRegistry.cj:97-107`（`byTopicOf` 线性遍历全部订阅）：每次 `PUBLISH` 都 O(#订阅) 扫描并对每个非空 filter 订阅解一次 BODY，订阅数多时把发布延迟绑定到「订阅数量 × BODY 解码成本」；建议按 topic 维护二级索引，并把「有非空 filter 的订阅集合」单独缓存。
4. `fmq/src/MQUsage.cj:49-68` 与 `fmq/src/manager/MQManagerArgs.cj:84-103`：两份 7 子命令帮助文本逐字重复，改一处必忘另一处（`main.cj:55` 用前者、`:61` 用后者）；建议 `MQUsage.managerHelp()` 直接返回 `MQManagerArgs.helpText()`。
5. `fmq/src/manager/MQManagerOutput.cj:32-42`：`width` 把一切非 ASCII 计 2 宽，`→`（U+2192，East Asian Ambiguous）实际多按 1 宽，`listTopics`/`registerTopic` 的「分配」列会右移 1 格；`MQManagerOutput_test.cj:36-44` 用同一个 `width` 自证，无法发现这类偏差。建议按 East-Asian-Width 属性表判定（至少把 `→`、`←`、`·` 归 1）。
6. `fmq/src/manager/MQManager.cj:29`「六个子命令」、`fmq/src/server/MQManager_test.cj:95`（`sixSubcommandsSucceedAndMutateState`）、`fmq/src/manager/MQManagerArgs_test.cj:57`（`sixSubcommandsParse`）：注释与用例名已过时（实际 7 个，含 `stats`）。
7. `fmq/src/manager/MQManager.cj:43,235,277,282`（`println`）vs `fmq/src/main.cj:76,79`（`eprintln`）：manager 的错误提示走 stdout，服务端错误走 stderr，与「便于脚本匹配」的初衷（`MQManagerOutput.ERROR_PREFIX`）不一致；建议错误统一 `eprintln`。
8. `fmq/src/manager/MQManager.cj:194-210`：`Int64.parse(fields[4])` 对畸形字段直接抛异常（被 `withClient` 兜成「无法连接」），`fields.size < 11` 静默 `continue`；建议用 `tryParse` 并在跳过行时 `WARN`，避免服务端格式演进后静默丢行。
9. `fmq/src/server/MQCommandExecutor.cj:247-265`：`SUBSCRIBE` 不拒绝「同一 `subscribedId` 被另一个连接占用」（`SubscriberRegistry.register` 静默覆盖 `buffer`/`connectionKey`），两客户端撞 id 时一方的消息会被另一连接收走；`MQErrorCode.INVALID_GROUP`（`f_mq/src/base/MQConstants.cj:30`）全仓从未产生，组名合法性（空串以外的 NUL、超长等）无校验。建议 `register` 返回「占用冲突」错误（可复用 `SUBSCRIBE_NOT_EXIST`/新增码），并在 `onSubscribe` 校验组名。
10. `fmq/src/server/MQServer.cj:63-97`：构造期末尾才 `Server<DataAny>(bindAt: …)` 绑定端口（`f_net/src/server/server.cj:315-326`），此时 `MetaStore`/`QueueLog`/`DeadLetterQueue`/`NodeRegistry` 都已打开；端口被占用而抛错时不关闭这些资源（进程退出掩盖了泄漏，进程内重试/测试会累积句柄）。建议构造体用 `try/catch` 兜底 `close()` 后再抛。
11. 测试基础设施：`fmq/src/server/MQServer_test.cj:29-42`、`fmq/src/server/MQManager_test.cj:36-49` 的 `freePort()` 是「bind → close → 稍后再 bind」的 TOCTOU，遇到并行测试/系统占用会偶发失败；用例目录固定为 `/tmp/fmq_test_*/<name>`，同一名称的用例并行时会互删。建议改用「构造时即持有监听端口」或在 `setUp` 里随机化目录名。

### 总评

R5 的代码形态是清楚的：`MQCommandExecutor` 严格「解析 → 校验 → 调服务 → 组装响应」，任何异常都收敛成 `ERROR(MQResult)` 而不关连接；`ConsumeService` 的游标懒建、按 `queueIndex` 精确定位 ack、`stats` 的 TSV 口径与 metrics 规格对得上；`MQManager` 的「一次请求一次响应 + 必关连接」与退出码约定（0/1/2）也基本按规格落地；`BackupStore` 的并发 get-or-create 与关闭竞态有专门的 4 线程用例（这是 R5 里质量最高的一块）。74 条用例**没有空用例、没有占位断言、没有空函数体**，命令矩阵的 happy path 与主要错误码覆盖到位。

问题集中在**「进程生命周期」与「可观测面的诚实性」**：

- 唯一的严重问题 S1 不是实现细节写错，而是**设计要求的那一步根本不存在**——没有 `ExitCallbacks.toExitGracefully()`/`atExit`，`close()` 只能由测试调用，于是「关闭顺序」「队列 sync」「备份最后一次 flush」全部降级为文档承诺；而 E2E 恰恰用 `kill` 验证，等于把异常退出当成了正常退出。
- G1/G2 是同一主题的延伸：S1 修复后 `close()` 才会真正成为生产路径，它目前没有异常保护，断链清理也没有任何用例兜底。
- G3/G4/G7 是「指标与错误提示不许撒谎」：autoAck 组的 `acked`、扫描失败时的 `backlog=0`、列表命令把 `ERROR` 说成「连不上」，都会把故障伪装成健康——对本模块这种「靠 `stats` 判断消费是否跟得上」的系统，这类偏差比崩溃更难发现。
- G5/G6/G8 是配置与存储的边界：非法配置不报、host 解析两套语义、备份目录永不清理，都是「上线后才暴露、且暴露时已经写了很多数据」的问题。
- G9/G10 解释了为什么上述问题能长期存在：复制落地、备份入队、关闭幂等、`stats` 计数列、manager 渲染内容都没有用例，服务端生产入口连可注入的装配点都没有。

修复顺序建议：S1（补退出钩子 + 关闭链回归锚点）→ G1/G2（关闭容错、断链用例）→ G4/G7/G3（指标与错误提示的诚实性）→ G5/G6（配置校验统一到 `MQHost`）→ G8（备份清理）→ G9/G10（补用例与可测性）→ G11/建议级。完成 S1、G1、G2、G4、G9 中第 1–4 项后，本层可认为「生命周期与可观测性与规格一致」。
