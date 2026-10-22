# 任务：fmq postfix 复审修复

> 执行规则（`AGENTS.md`）：
> - 开发在功能分支 `fix/fmq-postfix-audit`，开工前 `git pull`；每完成一个任务独立提交。
> - 每个编码任务按 TDD：先写**会失败**的用例（Red），再改实现（Green），最后补边界/并发用例。
> - 新功能必须有仓颉单元测试；测试发现的新问题必须修掉并补用例。
> - 任务编号与 `proposal.md` 的「问题映射」一一对应；P0 未全绿不得进入 P1。

## 0. 准备

- [x] 0.1 建分支 `fix/fmq-postfix-audit`，同步远程；记录基线：`f_mq` 128 例、`fmq` 304 例、
      45 个测试文件、1604 条断言
- [x] 0.2 把 `reviews/202610211902_fmq-postfix-audit/todo.md` 的 77 项按本文任务编号建跟踪表，
      逐项确认落点（可用 `proposal.md` 表格直接对照）
- [x] 0.3 复核两处基线状态：`f_mq`/`fmq` 全绿；`mq_e2e.sh`（若存在）结果记录到提交说明
- [x] 0.4 建立验证约定：新增用例命名以 `postfix` 语义命名，不依赖执行顺序；需要时钟/网络的用例
      走既有 `now: () -> DateTime`、`MQNodeTransport` 替身
- [x] 0.5 冻结本次不动的二进制格式：段记录头、`.meta`、`.cursor` 字段布局不变（`MQMetaSnapshot`
      删字段除外，见 T27）

## P0 严重问题

> 目标：先修「错答 / 复活删除 / 数据被墓碑清掉 / 队列停摆 / 越界写 / 回归不可见」。
> 每项先写能稳定复现的失败用例，禁止先改实现再补测试。

### T1 协议载荷读取的类型闸门（R1-S1）

- [x] 1.1 Red：`asPayload<String>(Message(data: DataString("x")))` 返回 `Some("x")`；
      `Int64`/`Bool` 各一条（当前必失败）
- [x] 1.2 Red：标量读对象、对象读标量均 `None`；`asPayload` 与 `decodePayload` 对同一字节结论一致
- [x] 1.3 Red：构造少字段/改名字段的旧对象 → `None`（当前 `SILENCE` 会返回默认对象）
- [x] 1.4 Green：新增 `MQProtocol.readPayload<T>`，`asPayload`/`decodePayload` 统一调用；
      删除 `convert(..., SILENCE)` 路径
- [x] 1.5 回归：`asInternal`/`asResult`/`asConsumeResult` 行为不变；`MQPayload_test` 全绿
- [x] 1.6 `cd f_mq && cjpm test` 全绿

### T2 墓碑参与接受判定（R2-S1）

- [x] 2.1 Red：墓碑 `rev 7` + 迟到主题分配 `rev 2`（广播路径）→ 不落盘、`topicOf` 为空、
      不触发 `openTopic`
- [x] 2.2 Red：同一场景经 `mergeSnapshot`（旧 peer 快照）→ 不复活、不打开队列
- [x] 2.3 Red：迟到组 `rev 2` + 组墓碑 `rev 7` → `groupExists` 仍为假
- [x] 2.4 Green：`MetaApplyResult` 增加 `Tombstoned`；`applyTopic`/`applyGroup` 入口做
      `acceptOverTombstoneLocked`（`isNewer` 语义，同 rev 比 origin）
- [x] 2.5 Green：`mergeSnapshot` 维护 `verifiedTopics`/`skippedTopics`/`tombstoneKeys`，
      三者都从缺失扫描中排除；`Tombstoned` 记 WARN
- [x] 2.6 回归：`applyRemote`/`flushPendingGroups` 对新结果分支编译通过；元数据 102 例全绿
- [x] 2.7 `cd fmq && cjpm test --no-progress` 全绿

### T3 墓碑删除判定（R2-S2）

- [x] 3.1 Red：本地组 `(rev 5, origin 9)` + 墓碑 `(rev 5, origin 2)` → 组仍在、无删除回调、
      无队列/游标清理
- [x] 3.2 Red：本地组 `(rev 4, origin 9)` + 墓碑 `(rev 5, origin 2)` → 删除并触发回调
- [x] 3.3 Green：`applyTombstone` 只在 `isNewer(tombstone, local)` 时写墓碑 + 删条目；
      输掉时不落盘、不回调，返回 `Duplicated`
- [x] 3.4 Green：墓碑输给活条目时不写入墓碑（避免挡住后续中间 revision 的条目）
- [x] 3.5 主题墓碑胜出时级联删除该主题下组；对更高 revision 的组记 WARN
- [x] 3.6 回归：`tombstoneRemovesLocalEntryOnlyWhenOlder` 扩到同 rev 不同 origin；`fmq` 全绿

### T4 段末尾位点归一化（R3-C1）

- [x] 4.1 Red：`QueueLog(maxFileSize = 64)` 追加 2 条 28B → 全部 ack（`committed = (1,64)`）→
      再追加 1 条触发轮转 → `next()` 返回第 3 条（当前报 `corrupt`）
- [x] 4.2 Red：同一状态下 `stats` 返回正确 backlog，不抛 `INTERNAL`
- [x] 4.3 Red：段 1 读满且无段 2 时 `next()` 返回 `None`，不记 ERROR
- [x] 4.4 Green：`startPositionOf` 在 `offset >= meta.size` 时归一化到「大于 seq 的最小现存段:0」；
      尾段读完返回 `None`；`offset > size` 才 WARN
- [x] 4.5 Green：`QueueRecordReader.next` 对 `remaining < 0` 给出明确不变量错误（防御）
- [x] 4.6 回归：`openReaderAt` 把 `committed` 前移并落盘；重启后从新段继续
- [x] 4.7 `cd fmq && cjpm test --no-progress` 全绿

### T5 记录与段上限联动（R3-C2、R3-M6）

- [x] 5.1 Red：`maxFileSize = 1 MiB`，追加 `2 MiB` 记录 → 抛 `IllegalArgumentException`，
      段文件长度不变（当前越界写）
- [x] 5.2 Red：`append([])` 抛异常，不写 4 字节零头；`maxFileSize = 4` 构造失败
- [x] 5.3 Red：直接 `SegmentedLog.append` 超过 `maxFileSize` → `LogRecordTooLargeException`
- [x] 5.4 Green：`QueueLog.effectiveMaxRecord = min(64 MiB, maxFileSize - 4)`，
      写入前拒绝空/超限；构造校验 `maxFileSize > 4`
- [x] 5.5 Green：`SegmentedLog.append` 在 rotate 前后都检查容量；新增异常类型
- [x] 5.6 Green：`MQConfig.validate` 在段上限 ≤ 64 MiB+4 时 WARN（含真实记录上限）
- [x] 5.7 正例：`1 MiB - 4` 记录成功、独占段、可完整读回
- [x] 5.8 `cd f_io && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

### T6 管理端输出可断言与错误分类（R4-S1）

- [x] 6.1 Red：`serverErrorIsNotReportedAsConnectionFailure` 捕获输出，断言含
      `boom from server` 且不含「无法连接」（当前必失败）
- [x] 6.2 Red：`nonSnapshotResponseIsProtocolError` 断言含「响应不是 MQMetaSnapshot」
- [x] 6.3 Red：`stats` 返回非数字 `delaying` → 文案为「服务端响应格式不正确」，不是「无法连接」
- [x] 6.4 Green：`MQManager` 增加可注入 sink（默认 `println`），全部输出走 sink
- [x] 6.5 Green：`Failure` 四分类（Unreachable/Server/Protocol/Local）+ 统一 `report`；
      `MQManagerOutput.stats` 解析失败抛 `MQServiceFailure`
- [x] 6.6 回归：`MQManager_test` 12 个用例改为「退出码 + 输出」双断言；`fmq` 全绿

## P1 一般问题

### T7 客户端连接池与退订幂等（R1-G1、R1-G7、R5-4）

- [x] 7.1 Red：并发用例——A 通过外层 `closed` 检查后被挂起，B `close()`，A 继续 `clientOf`
      → 不得建立新连接；`close()` 返回后无活连接
- [x] 7.2 Green：`clientOf` 在节点锁内二次检查 `closed`
- [x] 7.3 Red：对同一 id 连续退订两次 → 两次都成功，第二次不发请求
- [x] 7.4 Red：从未订阅的 id → `MQServiceException`，零请求
- [x] 7.5 Green：`retired` 有界集合（4096 FIFO）区分「已退订」与「未知」
- [x] 7.6 回归：`unsubscribeIsIdempotentOnServerAndRejectsUnknownId` 改为断言新语义；
      发送失败仍保留订阅
- [x] 7.7 `cd f_mq && cjpm test` 全绿

### T8 客户端会话状态与日志（R1-G2）

- [x] 8.1 Red：断言连接/解码/退订失败日志含订阅 id 与 topic（当前无）
- [x] 8.2 Green：`subscribedId`/`topic`/`subscribeGroup` 接入日志与错误文案
- [x] 8.3 Green：`tags` 校验后不再保存；`filter` 字段删除（仅本地校验用）
- [x] 8.4 回归：订阅/消费/退订/owner 汇总用例全绿
- [x] 8.5 `cd f_mq && cjpm test` 全绿

### T9 组名/标签/主题字符集（R1-G12）

- [x] 9.1 Red：`"g\u{7F}"`、`"g\u{00A0}"`、`"g\u{3000}"` 判非法（当前通过）
- [x] 9.2 Red：tags 第 65 个、单条 129 字节、含 `U+2028` 判非法
- [x] 9.3 Green：`MQGroup`/`MQTags`/`MQTopic` 改为按 `Rune` 判定控制/空白；
      保留原长度与保留符号规则
- [x] 9.4 正例：`订单组`、64×128 边界判合法
- [x] 9.5 `cd f_mq && cjpm test` 全绿

### T10 协议规格一致性与用例（R1-G8、G9、G13、G16、R5-6、R5-7）

- [x] 10.1 Red：`metaSync(MQDeregisterPayload)` 重载行为用例（命令、子载荷、kind）
- [x] 10.2 Red：`publishTime` 标准 ID 断言绝对时刻 `2026-10-18T18:30:00.123456789Z`；
      跨时区用例真正切换 `TZ=Asia/Shanghai` 或在构造时指定时区
- [x] 10.3 Green：删除「两种 kind」场景与描述；`MQInternalKind` 只保留三值
- [x] 10.4 Green：`delayingMs` 示例改具名参数，复制到用例可编译
- [x] 10.5 回归：五个 `metaSync` 重载各自有用例；`factoriesUseExpectedCommands` 保留但不再唯一
- [x] 10.6 `cd f_mq && cjpm test` 全绿

### T11 客户端用例补强（R1-G11、G14、G15、G17、G18）

- [x] 11.1 配置还原：修改前键不存在 → 结束后删除；单独运行 `configIsRestoredAfterTest` 通过
- [x] 11.2 回滚失败：异常文案含失败节点，ERROR 日志含 topic/id
- [x] 11.3 ack 发送失败：映射保留、重试成功、成功后删除
- [x] 11.4 发布 10 个 tags 顺序保持；订阅 owner 汇总只含接受者（`[0]`）
- [x] 11.5 对象 BODY 端到端：publish → consume → `get<T>()` 字段相等，`get<String>()` 为 `None`
- [x] 11.6 `cd f_mq && cjpm test` 全绿（含 `--filter` 单跑关键用例）

### T12 快照合并与加载收敛（R2-G1、R2-G2）

- [x] 12.1 Red：本地有合法 `/t`，对端快照含畸形 `/t` → 本地保留、无删除回调
- [x] 12.2 Red：墓碑已落盘、条目文件残留 → 重启后条目被删除（当前复活）
- [x] 12.3 Red：条目 rev 8 + 墓碑 rev 5 同时存在 → 重启后墓碑被删除、条目保留
- [x] 12.4 Green：`mergeSnapshot` 的 `skippedKeys` 不参与缺失扫描
- [x] 12.5 Green：`load()` 末尾执行 `convergeTombstonesLocked()`（幂等、逐条容错）
- [x] 12.6 `cd fmq && cjpm test --no-progress` 全绿

### T13 清理器日志与异常隔离（R2-G3、R2-G4）

- [x] 13.1 Red：注入「某段 `removeById` 抛异常」→ 同队列其它段仍被删，日志含该段 ERROR
- [x] 13.2 Red：注入 `deadLetter.cleanExpired` 抛异常/普通队列失败 → 死信仍清理
- [x] 13.3 Green：段级 try/catch 记 ERROR（topic/queue/segment）；轮末汇总
      「removed N / failed M」
- [x] 13.4 回归：`oneQueueFailureDoesNotStopOthers` 保留并补段级版本
- [x] 13.5 `cd fmq && cjpm test --no-progress` 全绿

### T14 备份链路（R2-G5、G6、G8、G9）

- [x] 14.1 Red：`states` 数量与记录数不一致 → WARN，记录落盘，位点不更新（读回断言）
- [x] 14.2 Red：真实 `ConsumeService.backupStates`：前 3 条 `acked=true`、边界位置不算确认、
      多组取最小 committed、无组全 false
- [x] 14.3 Red：target A 成功、B 失败 → 只重试 B，A 不重复收到
- [x] 14.4 Red：工作线程发送中 `close()` → 等当前批次 + drain，`pendingCount == 0`
- [x] 14.5 Green：`BackupItem.remainingTargets` 按 target 重试；`close()` 等待上限覆盖发送超时，
      残留条数记 ERROR
- [x] 14.6 回归：`BackupReplicator_test`、`MQCommandExecutor_test` 全绿

### T15 重新注册墓碑与校验 WARN（R2-G7、G10、R5-9）

- [x] 15.1 Red：删除 `/t`（墓碑 rev 7）后 `registerTopic` → 新 rev > 7、墓碑移除、
      `topicTombstone` 为 `None`、快照不含墓碑
- [x] 15.2 Red：组维度同场景（`registerGroup` 清组墓碑）
- [x] 15.3 Red：非法组名载荷 → `Invalid` 且 WARN 含 `subscribeGroup` 与失败原因
- [x] 15.4 Green：注册路径分配 revision 时把墓碑计入 `maxRevision`；成功后删墓碑
- [x] 15.5 Green：`applyRemoteGroup`/`applyGroup` 的 `Invalid` 分支补 WARN（含失败字段）
- [x] 15.6 `cd fmq && cjpm test --no-progress` 全绿

### T16 零长度与损坏语义（R3-M1、M2）

- [x] 16.1 Red：零长度头 → `corrupted = true`、ERROR、停止读取（当前当干净结束）
- [x] 16.2 Red：段仍在但记录损坏 → 游标不标记已决、不推进 `committed`
- [x] 16.3 Green：`QueueLog.readAt` 返回判别结果（Ok/Corrupt/SegmentGone）；
      `GroupCursor` 对 Corrupt 记 ERROR 且不前进
- [x] 16.4 Green：`zeroLengthHeaderEndsTheStream` 改名并改断言；用「真实删段」模拟段缺失
- [x] 16.5 `cd fmq && cjpm test --no-progress` 全绿

### T17 段缺失语义统一与 WARN 限流（R3-M3、M9、R5-5）

- [x] 17.1 统一实现与规格文本：唯一语义「跳到更大段 + WARN，游标前移落盘」
- [x] 17.2 Red：同一位置连续 100 轮不可读，WARN 条数受秒级限流
- [x] 17.3 Green：`startPositionOf` 的 WARN 走限流器（按 `(topic, queue, position)` 记忆）
- [x] 17.4 回归：`startingSegmentHoleResumesAtNextSegment` 保留；补「不回退到老段」断言
- [x] 17.5 同步删除 `consume-semantics`/README/详细设计中的「最老段」表述（T28 落地）

### T18 `stats` 严格模式与跳过计数（R3-M4、M8）

- [x] 18.1 Red：`committed` 段缺失且未修复 → `stats` 返回 `INTERNAL`（当前返回偏小 backlog）
- [x] 18.2 Red：游标已修复 → `stats` 正常，三个跳过计数出现在 TSV 尾部
- [x] 18.3 Green：`QueueLog.resolveStart(position, strict)` 供 `stats` 使用；
      `scanAfter` 标注为测试观测 API（`ConsumeService.stats` 用单趟扫描，不复用）
- [x] 18.4 Green：`MQMetrics` 增加三个计数器，`stats` 列扩展
- [x] 18.5 回归：`ConsumeService_test`/`MQManagerOutput_test` 列数断言同步
- [x] 18.6 `cd fmq && cjpm test --no-progress` 全绿

### T19 死信阈值与延迟规则（R3-M5、M12）

- [x] 19.1 Red：`deadMsgThreshold = 3` → 消费者收到 4 次投递，第 5 次扫描入死信，
      `deliverCount = 4`（当前只投 3 次）
- [x] 19.2 Green：死信检查移到自增之前（`deliverCount > threshold` 才入死信）
- [x] 19.3 Red：`publishTime` 超前 10 分钟 → 立即投递 + WARN；超前 1 分钟 + `delaying=5m`
      → 不投递
- [x] 19.4 Green：`isDue` 的 5 分钟容差写注释并接入用例；规格/详细设计同步（T28）
- [x] 19.5 `cd fmq && cjpm test --no-progress` 全绿

### T20 队列/消费测试缺口与弱断言（R3-M10、M11）

- [x] 20.1 1 MiB / 多字节长度头往返；`MAX_RECORD_SIZE` 边界
- [x] 20.2 「落盘后可持久」：`sync` 后模拟重开段可读
- [x] 20.3 「删除中途崩溃」：删除失败后重启状态可解释
- [x] 20.4 死信组间隔离、后加入的匹配订阅、已越过位置 ACK 两种
- [x] 20.5 回滚磁盘断言、跨段不拼接断言、死信清理段号断言
- [x] 20.6 并发用例改为断言 `committed` 单调不减；死信条目 7 个字段全断言
- [x] 20.7 `cd fmq && cjpm test --no-progress` 全绿

### T21 启动顺序与关闭 sync（R4-G2、R4-G18）

- [x] 21.1 Red：用注入点断言「定时器启动」早于「端口可连接」；监听前连接被拒绝
- [x] 21.2 Red：装配期抛错（如清理器初始化失败）→ 端口未绑定，进程非 0 退出
- [x] 21.3 Green：`Server` 构造/绑定延迟到 `start()` 的监听步骤
- [x] 21.4 Red：`close()` 断言 `queues.sync()` 被调用（注入观测点）
- [x] 21.5 Green：`closeSteps` 顺序与 13 步列表一致；失败步骤可重试
- [x] 21.6 `cd fmq && cjpm test --no-progress` 全绿

### T22 `BackupStore` 关闭留痕（R4-G3）

- [x] 22.1 Red：`close()` 后 `append` → 有 DEBUG/WARN（1s 限流），含 topic/位置
- [x] 22.2 Red：`append` 内 `LogClosedException` 不再静默
- [x] 22.3 Green：两条路径共用 `warnRateLimited`；README 同步（T28）
- [x] 22.4 `cd fmq && cjpm test --no-progress` 全绿

### T23 指标原子性（R4-G4）

- [x] 23.1 Red：删除主题与投递自增并发 → 不抛异常，`next()` 不返回 `INTERNAL`
- [x] 23.2 Green：`bump` 用一次 `compute` 完成「取或建 + 自增」
- [x] 23.3 Red：并发 `stats` 读取 + 删除 → 不抛遍历异常
- [x] 23.4 回归：删除后计数清零（含三个跳过计数）
- [x] 23.5 `cd fmq && cjpm test --no-progress` 全绿

### T24 管理端错误分类与测试（R4-G1、G12、G15、G16、G17、R5-1）

- [x] 24.1 Red：`stats` 三个 CLI 场景断言输出行（全部/按主题/未知）
- [x] 24.2 Red：非法组名指向不可达地址 → 含 `INVALID_GROUP`、不含「无法连接」
- [x] 24.3 Red：`mqServer_port` 缺失 → 「无法连接」，退出码 1，不崩溃
- [x] 24.4 Red：非绝对路径主题 → 含 `INVALID_TOPIC`，退出码非 0
- [x] 24.5 Green：本地前置校验在发请求前返回；配置缺失走 `Local` 分类
- [x] 24.6 回归：12 个管理端用例全部双断言；`fmq` 全绿

### T25 服务端配置与测试补强（R4-G11、G13、G14、G19、G20、G21、R5-2）

- [x] 25.1 Red：「默认值」用例不写任何键，断言 `None → 默认值` 分支（端口 2350、10s、1G 等）
- [x] 25.2 Red：`serverHelp` 断言 12 个键名与默认值（含 `tombstoneTTL`、`antiEntropyInterval`）
- [x] 25.3 Red：`backup >= 1` 发布一条 → 注入的备份替身收到一次入队
- [x] 25.4 Red：`runServer()` 调用 `toExitGracefully()` 可观测；manager 注册计数为 0
- [x] 25.5 Red：命令矩阵 6 条错误分支（非法 tags、NOT_OWNER、REGISTER 意外载荷、
      未知 internal kind、非 backup 信封、未知 metaSync 子载荷）
- [x] 25.6 Red：`mqServer_port = 0` → 校验失败，错误含键名
- [x] 25.7 Green：`ConfigSandbox`（记录存在性与值）接入 `MQConfig_test`/`Main_test`/
      `MQManagerArgs_test`，用例结束原样恢复
- [x] 25.8 `cd fmq && cjpm test --no-progress` 全绿

### T26 子命令数量统一（R4-G9）

- [x] 26.1 Red：`fmq manager --help` 断言 7 个子命令含 `stats`
- [x] 26.2 Green：`MQManager` 注释、`MQUsage.managerHelp`、帮助文本统一为 7
- [x] 26.3 回归：README/详细设计同步（T28）；检索「六个」仅历史归档命中

## P2 死代码与文档

### T27 死代码清理与打包边界（R2-G11、R5-3）

- [x] 27.1 按 `design.md` §4.2 逐项处置，先删完全死代码（`isGroup`、
      `SegmentMissingException`、`openFrom`、`isConnected`、`TestDirs.unique/cleanNamespace`）
- [x] 27.2 下沉测试：`hasMessage`/`isOk`/`respondEmpty`/`countAll`/`removeByBuffer`/
      `nodeAt`/`indexOf`/`ownersOf`
- [x] 27.3 处置仅测试符号：`scanAfter` 标注测试观测 API；`BackupReplicator.pendingCount` 投入生产（运维观测）
      （close 日志）；删除 `flush()` 与 `pendingPeers`/`pendingPeerCount`
- [x] 27.4 删除不可达分支（组 `Conflict`、`length < 0`、`main --help`、`MQManager case _`）
      与 3 处未使用 import（`main --help` 与 `MQManager case _` 为语法/实际可达，保留）
- [x] 27.5 删除 `MQMetaSnapshot.tombstoneFloor` 字段、计算、序列化与断言；快照往返用例修正
- [x] 27.6 打包：`MQStubServer.cj`→`MQStubServer_test.cj` 并改包内可见；`TestDirs.cj` 保留原名（跨包共用），
      改 `protected` 且移除 `atExit`
- [x] 27.7 验收：生产构建不带测试符号；`nm`/字符串检索无 `MQStubServer`、`TestDirs`
- [x] 27.8 标注保留：`DeadLetterQueue.iterate`、`setCloseStepsOverride` 注释与文档说明
- [x] 27.9 `cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

### T28 文档对齐（R1-G3、G4、G5、G6、G10；R3-M7；R4-G5、G6、G7、G8、G10；R5-5/6/7/8；专项）

- [x] 28.1 `f_mq/doc/详细设计.md`：§5.10 快照四字段、§5.2 组版本字段、门面 import 五条、
      `cursor: AtomicInt64`、`removeTopic` 返回 `Array`、`NodeRegistry` 公开面
- [x] 28.2 `fmq/doc/详细设计.md` §5.8/§5.11/§5.12/§5.6/§4：补方法签名、`owner` 赋值、
      `stats` 扫描来源、`metaRoot`、`CursorCatalog` 小节、`unsupportedSkipped`
- [x] 28.3 `fmq/doc/详细设计.md` §6.7/§3：断链清理改 `cleanupSubscribers()`（2s 独立定时器）、
      配置读取改严格解析、依赖表与 `cjpm.toml` 一致
- [x] 28.4 `fmq/doc/详细设计.md` §5/§7：`main`/`dispatch`/`installExitHooks`、`onPublish`、
      `SubscriberRegistry`、`MQManagerOutput` 签名；`registerTopic` 参数 `delaying=` 与输出格式
- [x] 28.5 关闭顺序 13 步（含 `subscribers`、`queues.sync`）写入两份 README 与详细设计
- [x] 28.6 `f_mq/README(.md/_en.md)`：补 10 个依赖、组名/tags/主题限制与错误码、记录上限
- [x] 28.7 `fmq/README(.md/_en.md)`：段恢复语义改「更大段」、`BackupStore` 留痕丢弃、
      `retired` 有界、7 个子命令与 `delaying=` 写法
- [x] 28.8 `f_mq/doc/开发计划.md`：`@Expect`→`@Assert`、500 次、`ConcurrentHashMap`、
      删除 4 个幽灵用例文件与 2 个不存在用例名
- [x] 28.9 历史台账：V9、26.1、W12/W29 取消不实勾选并注明原因
      （核实结论：`fix-fmq-full-audit/tasks.md` 的 V9（5 个 `metaSync` 重载）、26.1
      （`oneSegmentFailureDoesNotStopOthersAndLogsError`）、V29/W12（备份 `states` 数量校验 WARN）
      本次实现后均属实，保留勾选；全仓检索无 `W29`，无需处置。台账位于
      `f_mq/doc/spec/fix-fmq-full-audit/` 等归档变更目录，按 T29「归档保留原文」原则未改动）
- [x] 28.10 验收：`docs/spec.md` 的「文档漂移清单」逐行 grep 通过

### T29 规格矛盾收敛与归档（docs R5）

- [x] 29.1 全仓检索「最老段」，统一为「更大段/后继段」；同步 `consume-semantics`、
      `queue-storage`、两份 README、详细设计与用例断言
- [x] 29.2 退订幂等：正文、场景、用例三处一致（T7 的语义）
- [x] 29.3 删除「两种 kind」场景；历史 change 归档目录可保留原文，但主规格只能有一套
- [x] 29.4 所有 `delayingMs` 示例改具名参数并实际编译验证
- [x] 29.5 归档前跑 `openspec validate`（若 CLI 可用）或人工按 delta 结构核对
      ADDED/MODIFIED/REMOVED 三节完整、无重复 Requirement
- [x] 29.6 全量回归：`f_mq`、`fmq`、`f_io` 测试全绿；端到端脚本通过

## 验收清单

- [x] 6 个严重项各有「先红后绿」的提交记录，且 Red 用例保留在仓库
      （R1-S1 `41e54f16`、R2-S1 `149b65a8`、R2-S2 `b009abe7`、R3-C1 `a6607c9f`、
      R3-C2 `b5852467`、R4-S1 `16438b8e`，Red 用例随实现提交保留）
- [x] 77 项均有落点：Requirement、文档任务或测试任务（对照 `proposal.md` 表格逐项勾销）
- [x] 死代码 30 项全部处置完毕，无「保留但无人用」
      （另有 verify 未列出的 3 处编译告警一并清理：`MQSubscriptionInfo.hasBuffer`、
      `SubscriberRegistry.count`、`SubscriberRegistry` 的未使用 import）
- [x] 生产产物不含测试替身（`scripts/mq_e2e.sh` 构建断言：主程序无 `TestDirs`、
      `f_mq` 动态库无 `MQStubServer`）
- [x] 规格/README/详细设计/台账无互相矛盾的表述
      （关闭顺序 13 步、段恢复「后继段」、备份「留痕丢弃」、退订集合有界、台账路径全部收敛）
- [x] `cd f_mq && cjpm test` 与 `cd fmq && cjpm test --no-progress` 全绿
      （f_mq 149 例、fmq 376 例；`f_io` 21 例；`scripts/mq_e2e.sh` 输出 `E2E_OK`）

## V. verify 收尾（依据 verify-report.md）

- [x] V39 [C1] `TestDirs` 改为模块内共享 helper（`protected`，仓颉 `internal` 只覆盖当前包及子包）、
      移除 `atExit`；用例在 `@AfterAll` 调 `cleanNamespace` 回收 16 个 namespace；delta 已表述为
      「模块内可见、无进程钩子、生产代码不引用、主程序不链接」，并在 `scripts/mq_e2e.sh` 补构建断言
- [x] V40 [C2] 修正 `f_mq/doc/开发计划.md` 的 4 个幽灵用例文件路径（并修正 `MQNodePool`/`MQModel`/
      载荷三处目录漂移，`MQNodePool` 用例表对齐真实用例名）
- [x] V41 [C3] 核对并勾选 28.9，注明「V9/26.1/V29 属实，W29 不存在」
- [x] V42 [C4] 逐项核对验收清单，成立项勾选、不成立项修复后再勾
- [x] V43 [W1] 关闭顺序统一为 13 步（specs/docs 两处、tasks 两处）
- [x] V44 [W2] `fmq/doc/详细设计.md` 补 `effectiveMaxRecord` 与「不可跨段、零长度即损坏」
- [x] V45 [W3] `f_mq/README.md`/`README_en.md` 补退订集合有界与淘汰后按未知 id 处理
      （并补齐 `README_en.md` 的 10 个依赖、`fmq/README_en.md` 的段恢复与备份留痕表述）
- [x] V46 [W4] 删除 `QueueManager.hasLocalQueues`
- [x] V47 [W5] 测试名/注释「六个子命令」统一为 7 个
- [x] V48 重跑 f_io/f_mq/fmq 与 E2E，全绿后提交

## V2. 第二轮 verify 收尾

- [x] V49 [C1] `f_mq/详细设计.md`：§5.2 补 `revision`/`origin`；§4.4 门面改五条 import；新增 §5.8a 名称字符集与长度上限
- [x] V50 [C2] `fmq/详细设计.md`：NodeRegistry/CursorStore/SubscriberRegistry/MQManagerOutput 公开面按源码重写；`owner = Some(...)`；补 `unsupportedSkipped`；§6.1 关闭顺序改 13 步；`MQManager(args, sink)` 重载
- [x] V51 [W1] 删除 `MetaSyncer` 组维度不可达的 `MetaApplyResult.Conflict` 分支
- [x] V52 [W2] 协议规格/design/详细设计改为「对象目标用严格标志 0，标量用 `DEFAULT_DATA_FLAG`」，注明其等于 `SILENCE`
- [x] V53 [W3] `f_mq/README_en.md`、`fmq/README.md`、`fmq/README_en.md` 补「命名与长度限制」表
- [x] V54 [W4] `LogCleaner.start()` 删除空转 `now!` 参数，定时回调直接用 `DateTime.now()`
- [x] V55 [S1–S4] docs 检索场景注明归档除外；`MQManagerOutput` 注释改 14 列/兼容 11 列；delta 去掉 `openFrom`；`case _`/`--help` 措辞改为可达
- [x] V56 重跑 `f_io`/`f_mq`/`fmq` 与 `mq_e2e.sh`，全绿后提交（149/375/21 + `E2E_OK`）

- [x] V57 [C1] `fmq/详细设计.md` 删除 `pendingPeerCount`/`pendingPeers`/`MQAssignment.ownersOf`/`QueueLog.openFrom` 的生产 API 表述，`§6.5` 改 `openRecordsFrom`
- [x] V58 [C2] `§5.8` 按源码重写（`readAt → LogReadResult`、`openRecordsFrom`/`resolveStart`/`segmentsOrEmpty`/`removeById`/`scanAfter`/`effectiveMaxRecord`）；`MetaApplyResult` 补 `Tombstoned`；新增 §5.12a `CursorCatalog`
- [x] V59 [W1/W3] delta 漂移表去掉 `countAll`/`count`/`generations`；补 MODIFIED「子命令错误路径的稳定契约」（六 → 七）
- [x] V60 [W2/S1/S2] `开发计划.md` 4 个路径与 3 个用例名改真实值；装配图改「start() 末尾绑定端口」；`§5.8` 标注 `warnNowMs` 为测试观测参数

- [x] V61 [C1] `fmq/详细设计.md` 5 处签名对齐源码（`MetaStore.init` 补 `nodeCount`、`LogCleaner.start()`、`NodeRegistry` 补 `clientBuilder`/`pingTimeout=1s`、`MQNodePool` 补 `beforeLock`、`unregister(generation: Int64 = -1)`）；另补 `LogCleaner` 的 `removeSegment`
- [x] V62 [C2] 墓碑胜负语义（`isNewer` + origin）、`append` 异常类型（`IllegalArgumentException`）、`scanAfter` 改标测试观测 API、`QueueCorruptionException` 来源补 `resolveStart`
- [x] V63 [W1] `design.md`/`tasks.md` 的「stats 复用 scanAfter」表述改为「stats 单趟扫描，`scanAfter` 为测试观测 API」
- [x] V64 [W2] 新增 `managerPathInstallsNoExitHooks` 用例（server 工厂 0 次、manager 工厂 1 次）
- [x] V65 [W3] `design.md` §4.3 改为「`TestDirs.cj` 保留原名、`protected`、无 `atExit`」，与 V39 一致
- [x] V66 [W4] `开发计划.md` 的 `@Expect` 改为 `@Assert`
- [x] V67 [S1–S4] `design.md` 去 `openFrom`；tasks 27.6 改最终结论；`GroupCursor.isDue` 合并重复注释；docs 漂移表 §6.5 → §6.11
- [x] V68 重跑 `fmq` 全量测试与 E2E，全绿后提交（376 例 + `E2E_OK`）
