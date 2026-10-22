# verify 报告：fix-fmq-postfix-audit（第四轮）

结论：**无 CRITICAL**。代码与测试全部通过（`f_io` 21 例、`f_mq` 149 例、`fmq` 376 例、
`scripts/mq_e2e.sh` 输出 `E2E_OK`）；第三轮的两条 CRITICAL（C1 幽灵 API、C2 §5.8 签名块）与
三条 WARNING（W1 漂移表、W2 开发计划路径、W3 六个/七个）已逐项复核并确认修复。
本轮剩 3 条 WARNING（均为文档与规格/实现的表述不一致，不影响运行行为）与 4 条 SUGGESTION。

> 历史轮次：第一轮 5 条、第二轮 4 条（C1/C2 + W1–W4）、第三轮 2 CRITICAL + 3 WARNING + 1 SUGGESTION。
> 对应收尾任务 V39–V68 已在 `tasks.md` 勾选，本轮不再重复。

## 验证方式

- `openspec` CLI 在本机挂载路径 `/mnt/linux_share/storage/Users/currentUser/.local/bin/openspec`（1.14.3）。
- `openspec status --change fix-fmq-postfix-audit --json`：schema `spec-driven`，proposal/specs/design/tasks 齐备。
- `openspec instructions apply --json`：`progress = 218/218`，`remaining = 0`，无 `unavailableTrackingFiles`。
- `openspec validate fix-fmq-postfix-audit --strict`：通过（仅 7 条「Requirement 正文 > 500 字符」样式提示）。
- 逐份读取 9 份 delta spec 与 `design.md`、`proposal.md`、`tasks.md`，对照 `openspec/specs/**` 主规格。
- 实际执行测试：`f_io` 21/21、`f_mq` 149/149、`fmq` 376/376；`bash scripts/mq_e2e.sh` → `E2E_OK`
  （含 `MQStubServer`/`TestDirs` 打包断言）。
- 源码核对：`readPayload`、`scalarTypeMatches`、`Tombstoned`、`acceptOverTombstoneLocked`、
  `convergeTombstonesLocked`、`startPositionOf`、`resolveStart`、`LogReadResult`、`effectiveMaxRecord`、
  `LogRecordTooLargeException`、`MQRetiredSubscriptions`(4096 FIFO)、`clientOf` 锁内复核、
  `Failure` 四分类、`sink`、`closeSteps`(13)、`cleanupSubscribers`、`remainingTargets`、
  `backupStates/backupCursors/ackedByAll`、`warnDropped`、`entryView` 自增等。

## 汇总

| 维度 | 结果 |
|---|---|
| Completeness | 218/218 任务勾选；59 条 ADDED/MODIFIED 需求（23 ADDED + 36 MODIFIED）+ 1 条 REMOVED；282 个 Scenario |
| Correctness | 59/59 需求有实现证据；REMOVED「六个管理子命令」已确认由「七个」替代、维护面无残留「六个」 |
| Coherence | 0 CRITICAL + 3 WARNING + 4 SUGGESTION |

## CRITICAL

无。

## WARNING

### W1 `fmq/doc/详细设计.md` 缺「超前 5 分钟」容差（task 19.4 勾选与事实不符）

`specs/fmq/consume-semantics/spec.md:131-133` 规定：`publishTime` 超前 5 分钟以上的容差
「SHALL 写入本规格与详细设计，MUST NOT 只存在于代码注释中」。

- 实现与用例都在位：`fmq/src/queue/GroupCursor.cj:560-575`（`published > current + 5m` → 立即投递 + WARN）、
  `GroupCursor_test.cj:472`（`farFuturePublishTimeDeliversImmediately`）与 `:489`
  （`slightlyFuturePublishTimeStillWaitsForDelay`）。
- 但 `fmq/doc/详细设计.md:942-957`（§6.11 延迟投递）只写「未到期不投递」，全文检索
  `5 分钟`/`超前`/`容差` 仅命中 §6.4 的 TTL（`:813`），没有这条例外。
- `tasks.md:220` 的 19.4 标注「规格/详细设计同步（T28）」，实际未同步。

> 建议：在 §6.11「延迟投递」段补一句：`publishTime` 超前当前时刻 > 5 分钟视为已到期并记 WARN
> （兼容旧版本按本地时区写入的 messageId），超前 ≤ 5 分钟仍按正常延迟等待。

### W2 `design.md` 仍把两个可达分支写成「不可达、删除」

`design.md:366-367` 的处置表写：`main.cj --help` 分支「不可达 → 删除（帮助由 `dispatch` 统一处理）」、
`MQManager` 的 `case _`「不可达 → 删除，穷尽 match」。

- 两者都真实可达：`fmq/src/main.cj:70`（`--help`/`-h` 直接返回 0）、`fmq/src/manager/MQManager.cj:98`
  （未知子命令打印帮助并返回 2）。
- 同一变更的 delta 规格 `specs/fmq/server-runtime/spec.md:46-47` 明确要求保留；`tasks.md:295-296`
  （27.4）也记录「语法/实际可达，保留」。

> 建议：把 `design.md` 这两行改为「可达，保留」，与规格、tasks 及源码一致。

### W3 备份丢弃日志的限流口径在三处不一致

| 位置 | 表述 |
|---|---|
| delta `specs/fmq/server-runtime/spec.md:288` | 同一**毫秒**内限流一条 |
| `fmq/src/server/BackupStore.cj:234-243` | `now - lastDropWarnMs < 1000`（1 秒） |
| `fmq/README.md:140-141`、`design.md:331` | 同一**秒**限流一条（1s） |

规格同段还要求「README 与本规格 SHALL 使用同一表述」，归档后主规格会带一条与实现相悖的「毫秒」。

> 建议：把 delta 的「同一毫秒内限流一条」改为「同一秒内限流一条（1s）」。

## SUGGESTION

1. `fmq/doc/详细设计.md:508` 的「语义与写入时机见 §5.12 与 §6.10（清理）」指向错误：§6.10 是
   `fmq server --help`，清理在 §5.14 `LogCleaner` 与 §6.4 TTL。建议改为「§5.14 / §6.4」。
2. `design.md:120-126` 的 `MetaApplyResult` 片段只列 `Applied/Duplicated/TopicMissing/Invalid/Tombstoned`，
   但源码（`fmq/src/meta/MetaStore.cj:29-37`）对主题路径仍保留 `Conflict`（`:226`、`:294`）。
   建议在片段里补 `Conflict`，并注明「组路径不使用」。
3. `design.md:341` 的「投入生产」示例仍写 `scanAfter`，与本文件 `:356` 的决定（标注为测试观测 API）
   相矛盾。建议把示例换成 `BackupReplicator.pendingCount`。
4. `tasks.md:352` 的验收清单写「`fmq` 375 例」，实际为 376 例（同文件 `:394` 的 V68 记的是 376）。
   建议统一为 376。

## 已确认通过的要点（抽样）

- **上一轮 C1/C2 已闭环**：`fmq/doc/详细设计.md` 全文 0 命中 `pendingPeers`（仅 `:308` 的历史说明
  「不再维护」）、`MQAssignment.ownersOf`、`QueueLog.openFrom`、`NodeRegistry.nodeAt/indexOf`、
  `countAll`/`generations`；§5.8 已按源码重写（`readAt → LogReadResult` 三态、`openRecordsFrom`、
  `resolveStart(strict)`、`segmentsOrEmpty`、`removeById`、`scanAfter`、`effectiveMaxRecord`）；
  `MetaApplyResult` 补 `Tombstoned`（§4.3 与源码一致）；新增 §5.12a `CursorCatalog` 小节。
- **上一轮 W1–W3 已闭环**：`specs/docs/spec.md:84/96` 漂移表已改「`countAll` 已下沉测试，文档不列」
  与「`count`/`generations` 已删」；`fmq/doc/开发计划.md` 的 4 处路径与 3 个用例名已改真实值
  （`src/queue/MQMatcher_test.cj`、`openFromMiddleRecordReturnsRemaining` 等，文件均存在）；
  `manager-cli/spec.md:164` 的「子命令错误路径的稳定契约」已改为七个。
- **R1-S1**：`readPayload` 是唯一闸门，`asPayload`/`decodePayload` 共用；对象目标用字面量 `0`、
  标量用 `DEFAULT_DATA_FLAG`，并额外做 `scalarTypeMatches` 跨类拦截（`MQProtocol.cj:158-212,279`）。
- **R2-S1/S2**：`Tombstoned`、`acceptOverTombstoneLocked`、`isNewer`、`convergeTombstonesLocked`、
  注册清墓碑均在位（`MetaStore.cj:238,270,281,320,608,629,642`）；组路径无 `Conflict` 分支，
  主题路径保留（正确）。
- **R3-C1/C2/M1/M2**：`startPositionOf` 归一化 + `resolveStart(strict)`、`effectiveMaxRecord`、
  `LogRecordTooLargeException`、`LogReadResult` 三态在位；`length == 0` 判损坏。
- **R4-S1**：`MQManager` 的 sink（`init(args, sink)` 重载在位）、`Failure` 四分类
  （`Unreachable/Server/Protocol/Local`），协议错误不再归为「无法连接」。
- **启动/关闭**：`Server` 绑定推迟到 `MQServer.start()`（`MQServer.cj:166-190`）；`closeSteps` 13 步
  与规格顺序逐项一致，含 `subscribers` 与 `queues.sync`（`MQServer.cj:206-232`）。
- **打包边界**：`MQStubServer_test.cj` 已改名；`TestDirs` 为 `protected`、无 `atExit`；
  生产源集无引用；E2E 三条符号/字符串断言通过。
- **规格自洽**：维护面（`openspec/specs/**`、两份详细设计、四份 README）检索「最老段」为 0；
  「两种 kind」仅存在于 `f_mq/doc/spec/**` 历史快照（规格已声明排除）；`delayingMs` 示例与
  `MQTopicMeta(topic, queueNum, delayingMs!)` / `MQTopicAssignment(..., delayingMs!)` 构造一致。
- **测试/端到端**：21 + 149 + 376 全绿；`mq_e2e.sh` → `E2E_OK`。
