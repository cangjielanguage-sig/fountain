# verify 报告：fix-fmq-full-audit（第四轮）

结论：**不可归档**。任务台账 236/237，唯一未完成项仍是 31.4（合并回 `master`）。
上一轮 F1–F10 / W1–W15 已逐项复核，V1–V33 的修复全部落地；四模块全量用例本轮实跑全绿。
本轮新发现 1 个 E2E 稳定性问题（关闭时 accept 线程抛未捕获异常，SIGTERM 退出码偶发非 0）、
3 处规格未落实（设计文档段格式、管理端输出断言、客户端异常文案），以及 7 条遗留建议。

## 证据（本轮实跑，非引用上一轮）

| 验证面 | 结果 |
|---|---|
| `f_io` | 20/20 |
| `f_protocol` | 70/70 |
| `f_mq` | 128/128 |
| `fmq` | 299/299 |
| `scripts/mq_e2e.sh` | 7 次实跑：6 次 `E2E_OK`，1 次 `[FAIL] 节点3 退出码 = 0` |
| tasks | 236/237 |
| 分支 | `fix/fmq-full-audit`，领先 `master` 266 个提交，工作区干净（仅 `reviews/` 未跟踪） |

上一轮 W1–W15 复核（逐条对照源码，确认已落地）：

- W1 `f_mq/src/client/MQClient.cj:110,203,256,264,276,316,319,346,385,441,445`（节点下标/地址日志），
  用例 `MQClient_test.clientFailsWithPerNodeLogs`、`decodeFailureLogsPosition`。
- W2/W3 `MQServer.cj:205,285-301`（`subscribers.close` 步骤与包内可注入巡检）、
  `ConsumeService.cj:70-80`（`members` 过滤断链），用例见 `MQServer_test` 三条 + `ConsumeServiceTest`。
- W4 规格已改为「工厂原样透传、一致性由调用方保证」，`MQProtocol.cj:33-38` 与规格一致。
- W5 `MQBlob.cj:80`（`DataNone → None`）、`:116-123`（清理失败 WARN）。
- W6/W23 `QueueLog.cj:82-111`（`openFrom`/`openRecordsFrom` 共用 `startPositionOf`），
  `QueueLog_test.unknownSegmentResumesAtNextSegment`。
- W7/W24 `ConsumeService.cj:184-189`（无段抛 INTERNAL + WARN）、`MQCommandExecutor.cj:90-95`（服务码日志）。
- W8/W25 `MQServer_test.removeByBufferReleasesRecordToGroup`。
- W9/W26 `MetaStore.cj:294-316`（主题墓碑 + 级联组墓碑），用例 `deleteTopicCascadesGroups`。
- W10/W27 `MetaStore.cj:685-706`（`loadTopics` 结构校验），用例 `loadTopicsSkipsInvalidAssignment`。
- W11/W28 `MetaSyncer.cj:210-262`（未知→存活→死亡三趟），用例 `antiEntropyPrefersUnknownThenAliveThenDead`。
- W12/W29 `MQCommandExecutor.cj:249-256`（校验 `states` 数量），用例 `backupCursorRebuildsConsumerCursor`。
- W13/W30 `AtomicFile.cj:62-97`（区分不支持与真实失败）。
- W14/W31 `MQManagerArgs.cj:48-55`（跳过 `-*` 配置 token），用例 `configTokensAroundSubcommandAreSkipped`。
- W15/V32 文档六处与台账三条已改（`fmq/doc/详细设计.md:435,745,769,599,884` 等）。

## 评分

| 维度 | 状态 |
|---|---|
| Completeness | 236/237 tasks；9 份 delta 规格 60 条 ADDED/MODIFIED 需求全部有实现落点 |
| Correctness | 60 条需求中 56 条与实现一致；4 条存在偏差（W2–W5）；266 个场景中 262 个可静态定位到用例，4 个未覆盖/与实现相反 |
| Coherence | 设计决策（MQBlob、revision/墓碑、单趟扫描、关闭步骤表、可注入装配）均已落地；`design.md` §3.7 与实现相反（W2） |

> 场景覆盖按「规格正文逐条读 + 用例名/断言静态核对」得出；未逐条执行，属静态下界。

## CRITICAL

### C1 任务 31.4 未完成：分组提交并合并回 `master`
- 证据：`tasks.md:303` 未勾选；`openspec instructions apply` 报 `progress = 236/237`；
  `git rev-list --count master..HEAD` = 266。
- 属交付动作而非编码任务（`tasks.md:337-339` 已注明留给归档环节），但归档门禁不得跳过。
- 建议：确认目标分支与合并方式（AGENTS.md 要求 `git merge --no-ff`），完成合并并删除
  `fix/fmq-full-audit`；若要随归档执行，需在 `tasks.md` 显式改期。

## WARNING

### W1 SIGTERM 关闭时 accept 线程抛未捕获异常，退出码偶发非 0
- 证据（可复现，7/7 次）：每次关闭后 `n*/server.log` 都有
  `An exception has occurred: SocketException: Socket is already closed`，栈顶为
  `f_net/src/server/server.cj:123`，调用方 `fmq/src/server/MQServer.cj:170-172`：
  ```cangjie
  spawn {
      server.start(executor.execute)   // 关闭监听后 accept() 抛异常，无人捕获
  }
  ```
- 证据（偶发，1/7 次）：`scripts/mq_e2e.sh` 首跑输出
  `[FAIL] 节点3 退出码 = 0` → `E2E_FAILED`；随后 6 次（含保留日志的 3 次）均 `E2E_OK`，
  未能在单节点压测中复现（`SIGTERM` 后连续 8 次均为 0）。
- 影响：`server-runtime` 场景「收到 SIGTERM 完整关闭 → 进程以 0 退出」没有稳定保证；
  未捕获异常栈会污染 stderr，也让「关闭异常隔离」失去可观测性基线。
- 建议：在 `MQServer.start` 的 `spawn` 内包一层 `try`/`catch`（关闭后 `SocketException`
  记 DEBUG 或静默返回，其它异常记 ERROR）；或在 `f_net.Server.start` 的 accept 循环里区分
  「已关闭」与其他 `SocketException`。补一条用例：`close()` 后 1s 内无未捕获异常。

### W2 `design.md` §3.7 缺少段格式与兼容约束，且「不足 4 字节」的处理与实现相反
- 规格：`specs/fmq/queue-storage/spec.md:136-150`——该格式与上界 SHALL 写入 `design.md` 与模块文档，
  并注明「升级时不得改变前缀宽度或字节序」；场景 `格式写入设计文档` 要求两处都能检索到。
- 现状：`openspec/changes/fix-fmq-full-audit/design.md:255-265` 只写「读 4 字节头 / `getInt32BE`」，
  没有「4 字节大端长度 + 记录字节」的表述，也没有兼容约束；第 1 步写
  「不足 4 字节 → 正常结束」，而实现是判损坏（`QueueLog.cj:285-287`），
  用例 `QueueLog_test.incompleteHeaderIsCorruption` 也断言损坏。
  `fmq/doc/详细设计.md:355-368` 已满足要求，缺的是本变更的 `design.md`。
- 建议：`design.md` §3.7 补格式表与兼容约束，并把第 1 步改为「不足 4 字节 → 损坏」。

### W3 管理端「输出可断言」未落实：`stats` 渲染内联且无内容级用例
- 规格：`specs/fmq/manager-cli/spec.md:86-111`——每个子命令的输出 SHALL 由独立渲染层生成，
  并 SHALL 有单元用例直接断言内容（列、行数、关键值），MUST NOT 只断言退出码；
  场景 `统计输出` 要求 2 行 `R` 记录渲染出表头与 2 行数据。
- 现状：`registerTopic`/`listTopics`/`listSubscribeGroups` 走 `MQManagerOutput.table`，只有
  `MQManagerOutput_test` 对表头对齐/空表做通用断言；`stats` 的解析与渲染内联在
  `fmq/src/manager/MQManager.cj:192-228`，没有独立渲染函数；`MQManager_test` 的
  `sixSubcommandsSucceedAndMutateState`、`registerTopicWithDelayingAndStats` 只断言退出码，
  全仓没有任何用例断言这三种输出的内容。
- 影响：T24.6 勾选声称「补 `registerTopic`/`listTopics`/`stats` 的内容断言」并不成立；
  `stats` 的列错位、空值渲染等回归只能靠 E2E 的 `grep backlog` 兜住。
- 建议：把 `stats` 的 TSV→表格解析抽到 `MQManagerOutput`，为 `registerTopic`/`listTopics`/`stats`
  各补一条断言输出文本的用例（或用可注入输出流捕获）。

### W4 「全部 owner 不可达」的异常文案不含尝试过的节点
- 规格：`specs/f-mq/client/spec.md:145-148`——一轮内所有 owner 都因连接失败返回空时抛
  `MQConnectionException`，**文案包含尝试过的节点**。
- 现状：`f_mq/src/client/MQClient.cj:278-284` 的异常文案只有
  `all owner nodes of subscription '<id>' are unreachable`；节点列表只出现在同处 ERROR 日志里。
- 影响：调用方把异常直接上抛或落业务日志时，仍然看不到是哪些节点失败，A12/A16 的排障目标只完成了一半。
- 建议：文案拼上 `nodeList(sub.owners)`（与日志同源），用例断言异常消息含节点下标。

## SUGGESTION

### S1 组与墓碑的「同版本不同内容」冲突不记 WARN
- 规格：`metadata-cluster/spec.md:282-284`（相同 revision+origin 且内容不同 → 保留先到者并记 WARN）。
- 现状：主题路径有 WARN 与 `Conflict`（`MetaStore.cj:228-237`），组路径（`:272-274`）与墓碑路径
  （`:340-345`）直接返回 `Duplicated`，无 WARN、无 `Conflict`。
- 建议：抽出共用的 `resolveIncoming()`，三处统一返回 `Conflict` + WARN。

### S2 反熵选点不是「随机 peer」
- 规格：`metadata-cluster/spec.md:140`「向随机 peer 做一次反熵同步」。
- 现状：`MetaSyncer.cj:210-262` 从 `(selfIndex + 1) % nodeCount` 顺序尝试（分层后仍是固定轮转）。
  V3 只统一了周期，未改选点方式。
- 建议：在每层候选内随机取起点，或把规格改为「按层轮转起点」。

### S3 清理器汇总日志与规格口径不同
- 规格：`metadata-cluster/spec.md:373-377`——一轮结束 SHALL 汇总「删除数 / 失败数」。
- 现状：`LogCleaner.cj:115-118` 失败与删除分两条日志，`cleanOnce` 只返回 `removed`，失败数不外传。
- 建议：合并为一条 `removed=N failed=M` 日志，并返回 `(removed, failed)`。

### S4 `BackupStore` 关闭后写入无日志
- 规格：`server-runtime/spec.md:204-209`——关闭后到达的写入 SHALL 安全丢弃并记 DEBUG/WARN（限流）。
- 现状：`fmq/src/server/BackupStore.cj:52-55`（以及 `:59-60`）静默 `return`。
- 建议：补限流 WARN（含 owner/topic/queue），与 `BackupReplicator.warnRateLimited` 对齐。

### S5 `asPayload<T>` 对标量/字符串一律返回 `None`
- 规格：`f-mq/protocol/spec.md:78-80`——`T` 为标量或字符串时，只有对应 `Data` 子类型才算匹配。
- 现状：`MQProtocol.cj:156-170` 对非 `SimpleDataObject` 一律 `None`，`asPayload<String>(DataString)`
  取不到值（`decodePayload` 在 `:245-266` 是放行的，两者不对称）。生产未使用该形态。
- 建议：补 `DataString`/标量分支，或把规格收窄为「`asPayload` 仅用于对象载荷」。

### S6 退订规格自相矛盾（第二轮遗留）
- `f-mq/client/spec.md:202` 要求「本地不存在的 id SHALL 抛 `MQServiceException`」，
  `:207-210` 场景却要求「连续退订两次都不抛」；实现按需求与「未知 id」场景（`MQClient.cj:364-366`
  + `subscriptionOf` 抛 code 7），用例 `MQClient_test` 也如此断言。
- 建议：把「退订幂等」场景改成「第二次退订（本地已无该 id）抛 `MQServiceException(7)`」。

### S7 零长度头的措辞与实现不一致
- 规格场景标题为「零长度视为损坏」（`queue-storage/spec.md:157`），正文只要求「立即停止、不继续解析」。
- 现状：`QueueLog.cj:281-286` 按干净结束处理（不置 `corrupted`、不记 ERROR），
  用例名为 `zeroLengthHeaderEndsTheStream`。
- 建议：统一措辞（要么改场景标题，要么补 ERROR 日志与损坏标记）。

## 最终评估

1 critical issue found（C1：任务 31.4 未完成）。另有 4 warning、7 suggestion 需要处理。
所有检查项均已执行，无跳过项；四个模块全量用例全绿，E2E 存在一次未能稳定复现的退出码失败（W1）。
**Fix before archiving.**
