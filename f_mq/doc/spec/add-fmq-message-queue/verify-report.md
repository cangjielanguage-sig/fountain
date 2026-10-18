# verify 报告与修复范围（2026-10-18）

> 来源：`/opsx:verify add-fmq-message-queue` 的校验结果。
> 用户裁决：**修复 3 个 critical + W1–W3**；W4/W5/S1–S4 记录为后续项，不纳入本轮。

## 必须修复（critical）

### C1 多队列 ACK 无法区分队列

- 现状：`MQConsumeResult`/`MQAckPayload` 只有 `segmentedIndex`/`segmentedOffset`；客户端 `deliveries` 只用 `index:offset` 作键；服务端 `ConsumeService.ack` 遍历本机队列，命中第一个即返回。
- 风险：每个队列是独立 `SegmentedLog`，都从 `1:0` 开始；同一位置在多个队列同时存在时，ACK 可能落到错误队列，造成误确认/丢消息。
- 修复方向：给 `MQConsumeResult`、`MQAckPayload`、`MQMessage` 增加 `queueIndex`；客户端 `deliveries` 键改为 `(queueIndex, seq, offset)`；服务端按 `(topic, queueIndex, group)` 精确定位游标；`consume` 返回时带 queueIndex，`ack` 必须携带。
- 测试：两队列同一 `(seq, offset)`、并发消费/确认、错队列 ACK 返回 `ACK_UNKNOWN`。

### C2 `FILTER_UNSUPPORTED_BODY` 从未产生

- 现状：`MQMatcher.matches` 对 BODY 解码失败只返回 `false`；`GroupCursor` 把「组内无人匹配」直接标记为已决并推进；发布路径始终回成功。
- 风险：BODY 是服务端未注册对象且订阅 filter 非空时，消息被静默跳过，发布者收到成功，违反「不得静默丢消息」。
- 修复方向：匹配结果改为三态 `Match / NoMatch / Unsupported`；`Unsupported` 不得标记为已决；发布路径在落盘前检测该主题下所有活跃订阅的非空 filter 是否可评估，不可评估则返回 `FILTER_UNSUPPORTED_BODY`，不落盘；消费路径遇到 `Unsupported` 不得推进 `committed`。
- 测试：未注册对象 BODY + 非空 filter → 发布返回 `FILTER_UNSUPPORTED_BODY`；空 filter → 正常发布；消费不越过该位置。

### C3 游标指向已删除段时消费永久失败

- 现状：`GroupCursor` 打开读取流/`readAt` 未捕获 `openEntryStream` 的 `IllegalArgumentException`，异常被 executor 转成 `ERROR(INTERNAL)`，客户端每 200ms 重试永不恢复。
- 风险：TTL 清理删掉 `committed` 所在段（或消费滞后）后，该组永久消费失败。
- 修复方向：`GroupCursor` 捕获段失效异常，读取 `QueueLog.segments()` 找最老现存段，重置 `committed_`/`scanPosition` 并落盘，记 WARN；无现存段时返回空而不是报错；重投路径的 `readAt` 同样处理。
- 测试：删除 `committed` 所在段后继续消费；全部段被删时返回空；`committed` 落盘为新段起点。

## 本轮一并修复（warning）

### W1 节点由死转活未触发重同步

- `NodeRegistry.markSeen` 只记日志；`MQServer` 只在启动时 `syncFromPeers`。
- 修复：`markSeen` 检测 `wasAlive == false → true` 时触发一次回调（`MetaSyncer.syncFromPeers`）；补恢复同步测试。

### W2 重复端口校验不完整

- `MQConfig.selfIndex` 只在重复端口等于本机端口时抛错；`h1:2350,h2:2351,h3:2351` 且本机 2350 会启动成功。
- 修复：`validate()` 先对所有节点端口做唯一性检查；补「非本机端口重复」用例。

### W3 BackupStore 先查后建竞态

- `logs.get` 与 `logs.add` 不在同一把锁内；同一 `(owner, topic, queue)` 并发备份可能创建两个 `QueueLog`。
- 修复：`Mutex` 保护 get/create（或原子 computeIfAbsent）；补并发用例。

## 不纳入本轮（记录为后续）

- W4 部分任务缺测试证据（2.7 并发关闭、5.2 段删除恢复、6.5 按时间 flush、8.3 `MQManager_test`）。C3 会补段删除恢复；其余在后续变更补齐或在 tasks 中明确由集成测试覆盖。
- W5 远端 `MQTopicAssignment` 不推进轮转指针；建议后续在 `applyRemote` 推进 `nextStart`，或明确「变更只发同一节点」的运维约束。
- S1 BODY 类型矩阵补 `TreeSet`/`HashMap` 与更多基本类型。
- S2 `MQMessage.body` 的 `None` 语义与文档对齐。
- S3 `fmq` 依赖 `f_mq.client`（`MQClientConfig`）与设计分层不一致；把 `parseHost` 下沉到 `base`。
- S4 QueueLog 的 4 字节长度前缀未写入设计/规格；补文档说明。

## 更新产物要求

- `proposal.md`：What Changes/Impact 增加「队列身份进入 ACK 链路」「filter 三态」「段失效恢复」。
- `specs/f-mq/protocol/spec.md`：`MQConsumeResult`/`MQAckPayload` 增加 `queueIndex`；新增 ACK 精确定位场景。
- `specs/f-mq/client/spec.md`：`deliveries` 键与 ack 路由带 queueIndex。
- `specs/fmq/consume-semantics/spec.md`：filter 三态、`FILTER_UNSUPPORTED_BODY` 发布路径、段失效恢复。
- `specs/fmq/queue-storage/spec.md`：段失效恢复与「全部段删除返回空」。
- `specs/fmq/metadata-cluster/spec.md`：死转活重同步、远端分配轮转指针说明（W5 可只记录）。
- `specs/fmq/server-runtime/spec.md`：重复端口校验（W2）、BackupStore 并发（W3）。
- `design.md`：C1–C3、W1–W3 的实现方案与决策；更新 `MQConsumeResult`/`MQAckPayload` 字段与 ack 流程。
- `tasks.md`：新增阶段 10（TDD 小步），并保持已完成任务不再改动。
