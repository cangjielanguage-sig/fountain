# R5: 全局测试质量、死代码与需求追踪复审

审查时间：2026-10-21
审查对象：HEAD `22c13ec4`（已以 `789f1349` 合入 `sts/1.3.x`），只读审查，未修改任何文件
审查性质：全树复审（非 diff）

### 审查范围

测试（45 个 `*_test.cj`，共 432 个 `@TestCase`）：

- `f_mq/src/base/*_test.cj`（11 个）、`f_mq/src/client/*_test.cj`（2 个）、
  `f_mq/src/client/test/{LogCapture_test,MQClient_test,MQNodePool_test}.cj`、
  `f_mq/src/exception/MQException_test.cj`、`f_mq/src/test/Facade_test.cj`
- `fmq/src/{MQUsage_test,Main_test}.cj`、`fmq/src/cluster/*_test.cj`（5 个）、
  `fmq/src/config/MQConfig_test.cj`、`fmq/src/manager/*_test.cj`（2 个）、
  `fmq/src/meta/*_test.cj`（4 个）、`fmq/src/queue/*_test.cj`（7 个）、
  `fmq/src/server/*_test.cj`（6 个）

生产代码（全部非测试 `.cj`，共 70 个文件）：

- `f_mq/src/**`、`fmq/src/**`（含 `f_mq/src/client/test/MQStubServer.cj`、`fmq/src/test/TestDirs.cj`——
  这两个**不是** `*_test.cj`，按生产源码处理）

规格与文档：

- `openspec/specs/f-mq/{protocol,client}/spec.md`
- `openspec/specs/fmq/{metadata-cluster,queue-storage,consume-semantics,server-runtime,manager-cli,metrics}/spec.md`
- `openspec/specs/docs/spec.md`
- `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/{specs/**,tasks.md,verify-report.md,design.md}`
- `f_mq/README*.md`、`f_mq/doc/**`、`fmq/README*.md`、`fmq/doc/**`

审查方法：

1. 用脚本解析 432 个 `@TestCase` 的函数体，逐条统计 `@Assert`/`print`/空体/禁用标记；
2. 对 1413 个生产符号做全树标识符引用统计（区分生产文件、测试文件、声明处），再人工复核候选；
3. 对显式 `import` 做最后一段符号的使用检查；对 `@Deprecated`、注释代码块、不可达分支做模式扫描；
4. 抽取 9 份规格的 97 条 Requirement / 379 条 Scenario，逐条映射实现与用例。

说明：`fix-fmq-full-audit` 的规格以 delta 形式归档，`openspec/specs/**` 已是合并后的权威全集；
两者差异仅为「MODIFIED/ADDED Requirements」包装头，不重复计分。

---

## 一、测试资产总览

### 1.1 规模

| 模块 | 测试文件 | `@TestCase` | `@Assert` | 平均断言/用例 |
|---|---:|---:|---:|---:|
| `f_mq` | 18 | 128 | 472 | 3.7 |
| `fmq` | 27 | 304 | 1132 | 3.7 |
| **合计** | **45** | **432** | **1604** | **3.7** |

与台账对照：`V38` 记录 `f_mq 128/128`、`fmq 304/304`，与实际一致。

### 1.2 空测试/空实现扫描结果（逐文件、逐用例）

| 检查项 | 命中 | 说明 |
|---|---:|---|
| 空 `@TestCase`（函数体为空/只有 `}`） | 0 | — |
| 无 `@Assert` 的用例 | 0 | 432/432 至少一条断言 |
| 仅 `@Assert(true)` 的用例 | 0 | 全树 5 处 `@Assert(true)` 均为 `match` 分支，且同 `match` 内有 `case _ => @Assert(false)`（见下表） |
| 只打印不断言的用例 | 0 | — |
| `@Ignore` / `@Disable` / `@Skip` | 0 | — |
| 注释掉的 `@TestCase` | 0 | — |
| 空函数体 | 1 | `f_mq/src/client/test/LogCapture_test.cj:48` `flush(): Unit {}`，是 `OutputStream` 替身的合法空实现 |
| 仅 `return` 的函数 | 0 | — |
| `throw NotImplemented` | 0 | — |
| `TODO` / `FIXME` | 0 | — |
| 无 `@TestCase` 的测试文件 | 2 | `LogCapture_test.cj`、`FakeTransport_test.cj`，均为测试替身文件 |

5 处 `@Assert(true)`（均为合法 match 分支，不计缺陷）：

- `f_mq/src/base/MQMessageRecord_test.cj:189`
- `f_mq/src/base/MQProtocol_test.cj:47`、`:105`
- `f_mq/src/client/test/MQClient_test.cj:132`
- `fmq/src/server/MQCommandExecutor_test.cj:189`

**结论：在「空测试 / 无断言 / 禁用用例 / 占位桩」这一维度，f_mq 与 fmq 是干净的**，
没有发现任何「勾选但用例为空」或「空实现冒充完成」的情况。本轮测试质量的问题不在“有没有测试”，
而在“测试是否验证了它名字声称的东西”，见第二节。

---

## 二、测试质量问题

#### [一般] 管理端 11/12 个用例只断言退出码，直接违反规格自身的验收条款

- **位置**：`fmq/src/server/MQManager_test.cj:104`、`:125`、`:145`、`:160`、`:182`、`:192`、
  `:203`、`:216`、`:224`、`:238`、`:249`；`fmq/src/server/MQServer_test.cj:315`
- **现象**：上述 12 个用例的全部 `@Assert` 都是 `manager.run() == N` 一种形式（脚本核对：
  `MQManager_test` 12 个用例中 11 个如此，`MQServer_test` 1 个如此）。典型：
  - `serverErrorIsNotReportedAsConnectionFailure:104-121` 与 `nonSnapshotResponseIsProtocolError:125-142`
    只断言 `run() == 1`，而「服务端 ERROR」「非快照 RESP」「真的连不上」三条路径退出码都为 1；
  - `sixSubcommandsSucceedAndMutateState:160-179` 名字声称验证状态变更，实际只断言 10 次退出码；
  - `emptyListsReturnZero:192-200`、`registerTopicWithDelayingAndStats:224-235` 同样不检查输出内容。
- **影响**：`server-runtime/spec.md:387-391` 明确要求
  「用例 SHALL NOT 仅断言退出码而不检查输出或状态」；`manager-cli/spec.md:232-237` 要求输出可断言。
  现有写法使 A65（错误分类）的回归完全不可见：把 `printError` 改回 `connectionFailed`
  或把 `stats` 渲染清空，这些用例仍然全绿。另 `sixSubcommandsSucceedAndMutateState` 的名实不符
  会误导后续维护者认为状态已被验证。
- **建议**：给 `MQManager` 注入输出 sink（或在 `run()` 返回 `(code, text)`），让用例直接断言文案与表格内容；
  对状态变更类用例，在命令后通过 `MetaStore`/`topicOf` 或 `listTopics` 的渲染结果断言实际状态。
  此项与 R4 的严重项（`:104-142` 两条 A65 用例）同源，R4 已单独计分，本轮按“全局普遍性”记一般。

#### [一般] 「帮助文本完整」用例漏测 2 个配置项，且不校验默认值

- **位置**：`fmq/src/MQUsage_test.cj:31-44`；实现 `fmq/src/config/MQConfig.cj:348-363`
- **现象**：`serverHelp()` 实际输出 12 个配置项（含 `mqServer_tombstoneTTL`、`mqServer_antiEntropyInterval`），
  用例只断言了 10 个键名，漏掉上述两项；同时只断言键名、不校验规格要求的「默认值」。
- **影响**：`server-runtime/spec.md:41-44` 的 Scenario 要求「输出含全部配置项名与默认值」。
  当前若有人删掉 `tombstoneTTL`/`antiEntropyInterval` 两行，或用例外的默认值被改错，测试不会失败。
- **建议**：补 `@Assert(text.contains("mqServer_tombstoneTTL"))`、`antiEntropyInterval` 与对应默认值
  （`7d`、`30s`、`2350`、`10s` 等），最好按 `MQConfig.helpText()` 的 12 行逐行断言。

#### [一般] 测试替身被编入生产源码树

- **位置**：`f_mq/src/client/test/MQStubServer.cj:16,32`（`public class MQStubServer`）、
  `fmq/src/test/TestDirs.cj:16,32`（`public class TestDirs`）
- **现象**：两者都不以 `_test.cj` 结尾，按 `cjpm` 规则属于生产源文件（`cjpm.toml` 的 `include = ["src", ...]`），
  会随 `f_mq` 动态库 / `fmq` 可执行文件一起编译；`MQStubServer` 还是 `public`，可通过
  `import fountain::f_mq.client.test.*` 被外部使用。生产代码对二者零引用。
- **影响**：测试基础设施（真实 socket 监听、`atExit` 清理、随机端口分配）进入生产产物，
  增加二进制体积与启动期依赖面；`TestDirs` 的 `atExit` 若被误用会在生产进程注册清理钩子。
  这与「合法测试替身」不同——替身本身没问题，问题是它们不该出现在生产源码目录。
- **建议**：改名为 `*_test.cj`（如 `MQStubServer_test.cj`、`TestDirs_test.cj`），
  或移到独立的 `test/` 源集并在 `cjpm.toml` 中排除；同时确认 `f_mq` 的分发包不导出 `client.test` 包。
  注意：改名后 `MQStubServer` 被 `MQClient_test` 等同包测试引用，需保持包名不变。

#### [建议] `MQConfig_test` 把 253 行语义压进 1 个用例，且不还原全局配置

- **位置**：`fmq/src/config/MQConfig_test.cj:29-252`（唯一用例 `allConfigSemantics`）
- **现象**：12 个配置项的默认值、覆盖、9 类非法值、边界值、帮助文本全部在一个 `@TestCase` 内顺序断言；
  任一断言失败，后续 20 余条断言不再执行，无法定位；用例结束时把进程级 `Config` 留在
  `PORT=2350 / hosts=h1:2350,h2:2351,h3:2352 / backup=2` 的状态，未还原。
- **影响**：失败诊断粒度差；与 `MQManagerArgs_test`、`Main_test` 共享进程级 `Config` 时存在并行串扰
  （R4 已单独报告隔离问题）。注释「这里放在同一个用例里逐段验证」只解决了本类内部串行，未解决跨类污染。
- **建议**：拆成「默认值 / 覆盖 / 每类非法值 / 帮助文本」多个用例，并用 `beforeEach`/`afterEach`
  快照还原 `Config`；若必须单用例，至少在末尾恢复初始快照。

#### [建议] 弱断言与名实不符 4 处

- **位置与现象**：
  1. `fmq/src/cluster/MetaSyncer_test.cj:625-640`：用例名 `knownDeadPeerIsSkippedAndCompensatedByAntiEntropy`，
     注释与断言却是「已知死亡**不跳过**，仍然尝试发送」（`attemptCount() == 2`）。名字与断言相反，
     会让读者误判 A40 的取舍（R2 已指出）。
  2. `fmq/src/queue/QueueLog_test.cj:396-407` `zeroLengthHeaderEndsTheStream`：只断言 `readAt`/`scanAfter`
     返回空，没有断言 `isCorrupted()` 或 ERROR 日志；而规格 `queue-storage/spec.md:244-247` 的标题是
     「零长度视为损坏」。用例实际把「损坏」固化成「干净结束」（R3 M1 的行为面）。
  3. `fmq/src/cluster/BackupReplicator_test.cj:150-165` `slowReplicasDoNotBlockPublish`：
     规格 `metadata-cluster/spec.md:279-282` 要求「后继阻塞 5s、连续发布 200 条、每次 publish < 50ms」，
     用例只记录 200 条并断言总耗时 `< 1000ms`。虽然 200×300ms 的阻塞实现会失败，但阈值比规格宽 20 倍，
     且未逐次测量，无法区分「完全异步」与「少量同步开销」。
  4. `fmq/src/server/MQManager_test.cj:160` `sixSubcommandsSucceedAndMutateState`：
     名字声称验证状态变更，实际只断言退出码（见上一条 [一般]）。
- **影响**：这些用例在实现退化到「语义近似」时仍会通过，弱化了回归保护。
- **建议**：改名或补断言：`knownDeadPeer...` 改为 `knownDeadPeerIsStillTriedAndCompensated...`；
  `zeroLengthHeader...` 增加 `reader.isCorrupted()` 与日志断言，或按实现裁决后同步修订规格标题；
  `slowReplicas...` 改为逐条计时（每条 < 50ms）或断言工作线程未在 `record()` 内执行。

#### [一般] 退订幂等：规格承诺“两次都不抛”，实现与用例都抛

- **位置**：`f_mq/src/client/MQClient.cj:368-395`；用例 `f_mq/src/client/test/MQClient_test.cj:752-775`；
  规格 `openspec/specs/f-mq/client/spec.md:210-213`
- **现象**：规格 Scenario 要求「对同一 id 连续退订两次，第二次服务端回 `SUBSCRIBE_NOT_EXIST` →
  两次调用都不抛异常」。实现第一次成功后即从 `subscriptions` 删除；第二次调用 `subscriptionOf`
  返回 `None`，直接抛 `MQServiceException(SUBSCRIBE_NOT_EXIST)`，根本没有发出第二次请求。
  用例 `unsubscribeIsIdempotentOnServerAndRejectsUnknownId` 断言的正是这个抛异常行为
  （`:768-775`），与规格相反。
- **影响**：按规格编写的调用方（超时重试退订）会收到异常并误判失败；同时“未知 id”与
  “已成功退订的 id”在客户端不可区分，违背幂等承诺。当前用例把错误行为固化，修复时必须同步改用例。
- **建议**：`unsubscribe` 对「本地已不存在」直接返回成功（真正幂等），并保留“从未订阅过的 id”
  与“已退订 id”的区分（可保留一个短期已退订集合，或按规格允许统一成功）；
  用例改为断言第二次不抛且零请求。

#### [一般] 段恢复语义：README/详细设计/consume 规格说“最老段”，实现/queue 规格/用例说“更大段”

- **位置**：`fmq/README.md:128`、`fmq/README_en.md:152`、`fmq/doc/详细设计.md:790`；
  规格 `fmq/consume-semantics/spec.md:294`；实现 `fmq/src/queue/GroupCursor.cj:503-533`；
  规格 `fmq/queue-storage/spec.md:80-83`；用例 `fmq/src/queue/GroupCursor_test.cj:502-527`
- **现象**：三份文档写“位点所在段被删后跳到现存最老段”，而实现与 `queue-storage` 规格、用例
  `startingSegmentHoleResumesAtNextSegment` 都是“跳到最接近的更大段”。两种语义的数据后果相反：
  跳最老段会重复投递（at-least-once），跳更大段会跳过中间消息（丢消息）。
- **影响**：运维按 README 判断“只会重复不会丢”，实际可能丢消息；新维护者按任一文档修改都会
  与另一份冲突。R3 已按一般记录（M3），本轮从“用例与文档相反”角度再次确认，且三份文档均未修。
- **建议**：以 `queue-storage/spec.md:80-83` 为准统一三处文档，明确“跳过不可读区间，可能丢消息，
  需要人工从备份恢复”；同步修订 `consume-semantics/spec.md:294` 的 Scenario 文案。

#### [一般] 协议规格仍保留已废弃的「内部消息的两种 kind」场景

- **位置**：`openspec/specs/f-mq/protocol/spec.md:114-118`（两种 kind）与 `:120-125`（三种 kind）
- **现象**：同一 Requirement 下同时存在「内部消息的两种 kind」和「内部消息的三种 kind」两个 Scenario，
  前者不含 `stats`，与后者及 `MQInternalKind` 的三值（`MQConstants.cj:76-78`）矛盾。
  `tasks.md:334`（V9）明确声称「删除过时『两种 kind』场景、补墓碑子载荷」，但主规格仍保留该场景。
- **影响**：规格自相矛盾，验收时无法判断以哪条为准；台账“已删除”的勾选不实，属于文档任务未闭环。
- **建议**：删除 `:114-118` 的过时场景（保留三种 kind），并在 `tasks.md` V9 注明只修改了 delta、
  归档合并后需复核主规格。

#### [一般] 协议规格的延迟构造示例使用位置参数，照抄无法编译

- **位置**：`openspec/specs/f-mq/protocol/spec.md:319`、`:324`；实现
  `f_mq/src/base/model/MQTopicMeta.cj:33`、`f_mq/src/base/payload/MQTopicAssignment.cj:43`
- **现象**：规格示例写 `MQTopicMeta("/t", 2, 61000)` 与
  `MQTopicAssignment("/t", 2, 0, [0, 1], 61000)`；两个构造函数都把延迟声明为具名参数
  `delayingMs!: Int64 = 0`，第三个/第五个位置参数不存在，按示例编码会编译失败。
- **影响**：`docs/spec.md:23-26` 要求“签名可对照、参数个数/顺序/类型一致”；示例是最直接的对照物，
  当前示例本身不可用，读者会误以为可以位置传参。
- **建议**：示例改为 `MQTopicMeta("/t", 2, delayingMs: 61000)`、
  `MQTopicAssignment("/t", 2, 0, [0, 1], delayingMs: 61000)`；并在 `docs/spec.md` 的验收项中
  加入“示例可编译”。

#### [一般] `f_mq/doc/开发计划.md` 引用 4 个不存在的测试文件

- **位置**：`f_mq/doc/开发计划.md:256`、`:274`、`:294`、`:315`
- **现象**：分别引用 `src/client/MQClientPublish_test.cj`、`MQClientSubscribe_test.cj`、
  `MQClientConsume_test.cj`、`MQClientLifecycle_test.cj`，四个文件在仓库中均不存在；
  实际用例集中在 `f_mq/src/client/test/MQClient_test.cj`。
- **影响**：`docs/spec.md:80-83` 的「无幽灵文件」要求（虽然字面只约束 `tasks.md`）在此文档被违反；
  按计划文档找用例的维护者会扑空，也说明台账类文档没有纳入验收。
- **建议**：改为指向 `client/test/MQClient_test.cj` 的具体用例名，或标注“历史计划，用例已合并”；
  把 `开发计划.md` 纳入 `docs/spec.md` 的验收范围。

#### [一般] 主题墓碑在更高 revision 重新注册后既不删除也不标记复活

- **位置**：`fmq/src/meta/MetaStore.cj:173-191`（`registerTopic` 不触碰 `tombstones`）、
  `:388-393`（`topicTombstone`）、`:406-430`（GC 的 `resurrected` 分支永久保留）；
  规格 `fmq/metadata-cluster/spec.md:354-357`
- **现象**：规格 Scenario「新注册覆盖墓碑」允许「墓碑被移除或标记为已复活」；实现两者都没做。
  重新注册成功后，`topicTombstone(topic)` 仍返回旧墓碑，墓碑继续随快照扩散，`tombstoneFloor`
  被压低，GC 因 `local.revision > tombstone.revision` 永不回收。
- **影响**：删了又建的主题会永久携带墓碑，快照体积与同步成本随“删除-重建”次数增长；
  `applyRemoteGroup` 的 `topicTombstone` 检查仍会把该主题判为“已删除”，可能拒绝迟到的组。
  规格 Scenario 目前只有组维度等价用例（`deletedGroupCanBeRecreatedWithHigherRevision`），主题维度无实现无用例。
- **建议**：`registerTopic` 在分配 revision 高于同 key 主题墓碑时删除墓碑（含文件与 map）；
  补用例「删除主题 → 更高 revision 重新注册 → `allTombstones`/`snapshot().tombstones` 不含它；
  远端组同步不再被旧墓碑拒绝」。

#### [建议] 死代码清理（6 完全死 + 11 仅测试 + 7 只写/无消费者 + 4 不可达分支）

- **位置**：见 3.1–3.4 的完整表格
- **现象**：6 个生产与测试均零引用的符号（`isGroup`、`SegmentMissingException`、`openFrom`、
  `isConnected`、`TestDirs.unique/cleanNamespace`）；11 个仅测试使用的符号
  （`hasMessage`、`isOk`、`respondEmpty`、`scanAfter`、`countAll`、`iterate`、`removeByBuffer`、
  `nodeAt`、`pendingPeerCount` 等）；7 个只写字段/无消费者状态（`MQSubscription` 五字段、
  `tombstoneFloor`、`pendingPeers`、`hasLocalQueues`、`MQMatcher.topicOf`、`ownersOf`、`indexOf`）；
  4 个不可达分支（`QueueLog.cj:305`、`main.cj:70-73`、`MQManager.cj:85-88`、`MetaSyncer.cj:408-410`）。
- **影响**：`openFrom` 与 `ownersOf` 仍被详细设计当作生产 API 描述，读者会按错误契约编码；
  `MQSubscription.filter` 预编译结果被丢弃，每次订阅白做一次编译；`pendingPeers`/`tombstoneFloor`
  增加序列化与同步成本却不产生行为；不可达分支掩盖了“组没有 Conflict 语义”的真实设计缺口。
- **建议**：按 3.1–3.4 逐项删除或接入消费者；删除前先改文档签名；`setCloseStepsOverride` 等
  合法测试钩子保留并加注释；把 `MQStubServer.cj`/`TestDirs.cj` 改名移出生产源集。

#### [建议] 只写字段与无消费者状态应内化或删除

- **位置**：`f_mq/src/client/MQSubscription.cj:30-34`、`f_mq/src/base/payload/MQMetaSnapshot.cj:34`、
  `fmq/src/cluster/MetaSyncer.cj:46,474-484`、`fmq/src/queue/QueueManager.cj:208-210`、
  `fmq/src/queue/MQMatcher.cj:76-78`、`fmq/src/meta/MQAssignment.cj:99`、`fmq/src/cluster/NodeRegistry.cj:177`
- **现象**：字段只在构造/赋值处出现，无读取点。`MQSubscription.filter` 的 `MQFilter.compile`
  结果从未使用；`tombstoneFloor` 只序列化；`pendingPeers` 只计数。
- **影响**：这些状态会误导读者认为“已有补偿/过滤/复活机制”，并为序列化与内存付出成本。
- **建议**：删除 `MQSubscription` 的五个只读字段（保留 `owners/autoAck/deliveries`）；
  `tombstoneFloor` 要么用于快照缺失兜底，要么从协议移除；`pendingPeers` 接入反熵选点或删除。

#### [建议] 不可达分支应删除或改为显式断言

- **位置**：`fmq/src/queue/QueueLog.cj:305`（`length < 0`）、`fmq/src/main.cj:70-73`（`--help`）、
  `fmq/src/manager/MQManager.cj:85-88`（`case _`）、`fmq/src/cluster/MetaSyncer.cj:408-410`（组 `Conflict`）
- **现象与影响**：四处分支在当前类型/控制流下永不执行；保留会降低覆盖率统计有效性，并让
  `MetaApplyResult.Conflict` 看似“已处理组冲突”，实际 `applyGroup` 从不返回它。
- **建议**：`QueueLog` 去掉负值判断；`main` 删除 `--help` 分支（已由 `wantsHelp` 处理）；
  `MQManager` 的 `case _` 改为 `throw`/`unreachable` 断言；`MetaSyncer` 的组 `Conflict`
  要么在 `applyGroup` 同 revision 不同内容时真正返回，要么删除分支并同步枚举。

#### [建议] 两处未使用 import

- **位置**：`f_mq/src/base/MQMessageRecord.cj:20`（`std.io.SeekPosition`）、
  `fmq/src/manager/MQManager.cj:20`（`fountain::f_data.*`）
- **现象**：`SeekPosition` 全文件未出现；`f_data.*` 与 `:21` 的 `DataAny` 重复且无其它使用。
- **影响**：轻微，增加编译期依赖面与阅读噪音。
- **建议**：删除两行；`MQManager` 保留 `import fountain::f_data.DataAny` 即可。

#### [建议] “六个/七个管理子命令”在文档与源码注释中并存

- **位置**：`fmq/doc/详细设计.md:149`（七个）、`:946`（六个）、`:10`（两个，指 server/manager）、
  `fmq/doc/开发计划.md:127,443,500,520`（六个）、`fmq/src/manager/MQManager.cj:29`（六个）；
  规格 `fmq/manager-cli/spec.md:41`（标题“六个”）与 `:39`（Scenario“7 个”）
- **现象**：实现与 `MQUsage.managerHelp()` 为 7 个（含 `stats`），规格与文档多处仍写六个，
  且“两个子命令”与“七个子命令”混在同一份详细设计里。
- **影响**：读者无法确定 `stats` 是否属于管理子命令；与 `docs/spec.md:54-57`“README 与 --help 均为 7 个”
  的验收口径冲突。
- **建议**：统一为“7 个管理子命令（含 stats）”；详细设计 §1 的“两个子命令”改为“两个顶层子命令
  （server/manager），其中 manager 有 7 个子命令”；同步 `开发计划.md`。

---

## 三、全局死代码

判定口径：**完全死代码** = 生产与测试均零引用；**仅测试使用** = 无生产入口，只有用例调用；
**合法测试替身** = 为测试而生的类型/方法，且位于测试文件或测试专用包，不计缺陷。

### 3.1 完全死代码（生产、测试均零引用）

| 位置 | 符号 | 说明 |
|---|---|---|
| `f_mq/src/base/payload/MQDeregisterPayload.cj:71` | `isGroup()` | 全仓零调用；服务端统一走 `kindOf()`（同文件 `:67` 的 `isTopic()` 也仅测试使用） |
| `fmq/src/queue/QueueExceptions.cj:41-53` | `SegmentMissingException` | 全仓 0 处 `throw`/`catch`；任务 18.4 声称新增，实际恢复路径改用 `SegmentRecovery`/`startSegmentAtOrAfter` |
| `fmq/src/queue/QueueLog.cj:82-89` | `openFrom(position)` | 全仓 0 调用；游标实际用 `openRecordsFrom`（`GroupCursor.cj:477`）。文档 `详细设计.md:337,760` 仍把它写成游标读流 API |
| `fmq/src/server/MQSubscriptionInfo.cj:65-70` | `isConnected()` | 全仓零调用；断链判断走 `isDisconnected()`/`buffer.isClosed()` |
| `fmq/src/test/TestDirs.cj:50-52` | `unique(namespace)` | 含测试在内零调用（所有用例都用 `of(namespace, name)`） |
| `fmq/src/test/TestDirs.cj:69-71` | `cleanNamespace(namespace)` | 含测试在内零调用 |

### 3.2 仅测试使用（无生产入口）

| 位置 | 符号 | 生产侧替代/说明 |
|---|---|---|
| `f_mq/src/base/payload/MQConsumeResult.cj:50` | `hasMessage()` | 生产用 `record.isEmpty()` / `size`，仅 2 个测试文件引用 |
| `f_mq/src/base/payload/MQResult.cj:35` | `isOk()` | 生产全部写 `code == 0`，仅 `MQPayload_test` 引用 |
| `f_mq/src/base/MQProtocol.cj:117` | `respondEmpty()` | 仅 `MQProtocol_test.cj:110` 使用；服务端空响应走 `respond<MQResult>`/`Message.resp`。文档 `f_mq/doc/详细设计.md:452` 把它列为公开 API |
| `fmq/src/queue/QueueLog.cj:148-192` | `scanAfter()` | 仅测试调用；`ConsumeService.stats` 自行单趟扫描（R3 M7） |
| `fmq/src/queue/QueueLog.cj:194-201` | `countAll()` | 仅测试调用 |
| `fmq/src/queue/DeadLetterQueue.cj:43-46` | `iterate()` | 仅测试调用；生产没有死信读取入口（R3 S6） |
| `fmq/src/server/SubscriberRegistry.cj:137-152` | `removeByBuffer()` | 仅 `MQServer_test` 调用；生产断链清理走 `unregister`。其依赖的 `MQSubscriptionInfo.hasBuffer`/`connectionKey` 同属该测试专用链路（R4） |
| `fmq/src/cluster/NodeRegistry.cj:104` | `nodeAt()` | 仅 `NodeRegistry_test` 调用 |
| `fmq/src/cluster/MetaSyncer.cj:101` | `pendingPeerCount()` | 仅 `MetaSyncer_test` 调用（与下列 `pendingPeers` 一起构成无消费者的状态） |
| `fmq/src/server/MQServer.cj:254` | `setCloseStepsOverride()` | 仅 `MQServer_test` 注入失败步骤用；属于**合法测试钩子**，建议保留但加注释 |
| `f_mq/src/client/test/MQStubServer.cj:98,104` | `received()`/`receivedCount()` | 测试替身自身 API，合法 |

### 3.3 只写字段 / 无消费者状态 / 协议字段

| 位置 | 符号 | 现象 |
|---|---|---|
| `f_mq/src/client/MQSubscription.cj:30-34` | `subscribedId`、`topic`、`subscribeGroup`、`tags`、`filter` | 五个字段只在构造函数写入，生产与测试均无读取；`MQClient.cj:137` 预编译的 `MQFilter` 因此完全失去意义（真实过滤在服务端重新编译） |
| `f_mq/src/base/payload/MQMetaSnapshot.cj:34` | `tombstoneFloor` | 由 `MetaStore.snapshot`（`:462-471`）计算并序列化，但 `mergeSnapshot`/GC/同步均不读取；仅 f_mq 往返用例断言 |
| `fmq/src/cluster/MetaSyncer.cj:46,474-484` | `pendingPeers` 集合 | 只 `add`/`clear`/`size`，从不参与选点、快照或日志；唯一读数是测试用的 `pendingPeerCount()`。规格 `metadata-cluster/spec.md:139` 承诺「广播失败节点进入待补偿集合，恢复时用快照收敛」，实际反熵只是随机选点 |
| `fmq/src/queue/QueueManager.cj:208-210` | `hasLocalQueues` | 零引用（R3 已报） |
| `fmq/src/queue/MQMatcher.cj:76-78` | `topicOf(record)` | 零引用（R3 已报） |
| `fmq/src/meta/MQAssignment.cj:99` | `ownersOf(assignment)` | 仅 `MQAssignment_test` 调用；文档 §5.4 仍把它列为签名（R2 已报） |
| `fmq/src/cluster/NodeRegistry.cj:177` | `indexOf(address)` | 零引用（R2 已报） |

### 3.4 不可达分支

| 位置 | 分支 | 原因 |
|---|---|---|
| `fmq/src/queue/QueueLog.cj:305` | `if (length < 0 \|\| length > MAX)` 中的 `length < 0` | `getInt32BE`（`:242-245`）由 4 个字节拼出，范围 `0..0xFFFFFFFF`，永不为负；只需判上界 |
| `fmq/src/main.cj:70-73` | `if (command == "--help" \|\| command == "-h")` | `command` 取自「第一个不以 `-` 开头的参数」（`:53-59`），不可能以 `-` 开头；`--help` 已由 `:60-68` 的 `wantsHelp` 处理（R4） |
| `fmq/src/manager/MQManager.cj:85-88` | `case _ =>` | `MQManagerArgs.parse` 已拒绝未知子命令（`MQManagerArgs.cj:70-82`），经公开路径不可达；仅当绕过 `parse` 直接构造 `MQManagerArgs` 时可达（防御性，可删或改为断言） |
| `fmq/src/cluster/MetaSyncer.cj:408-410` | `case MetaApplyResult.Conflict`（组） | `MetaStore.applyGroup`（`:250-286`）只会返回 `Applied/Duplicated/TopicMissing/Invalid`，从不返回 `Conflict`（R2） |

### 3.5 未使用 import / 注释代码 / `@Deprecated`

| 类别 | 位置 | 说明 |
|---|---|---|
| 未使用 import | `f_mq/src/base/MQMessageRecord.cj:20` | `import std.io.SeekPosition`，全文件未使用（`std.fs.*` 提供 `File`，`std.time.*` 提供 `DateTime`） |
| 未使用 import | `fmq/src/manager/MQManager.cj:20` | `import fountain::f_data.*` 与 `:21` 的 `f_data.DataAny` 重复，通配符未提供实际使用（R4） |
| 注释代码块 | — | 全树未发现连续 2 行以上的注释代码 |
| `@Deprecated` | — | 全树无 `@Deprecated`，不存在“废弃但无迁移路径”的 API |

### 3.6 合法测试替身（不计死代码）

- `f_mq/src/client/test/MQStubServer.cj`：进程内桩服务端，仅测试包使用；
- `f_mq/src/client/test/LogCapture_test.cj`：日志捕获流/Appender，`flush() {}` 是 `OutputStream` 接口的合法空实现；
- `fmq/src/cluster/FakeTransport_test.cj`：`MQNodeTransport` 假实现；
- `fmq/src/test/TestDirs.cj` 的 `of/clean/token/registerCleanup`：临时目录工厂，被 15 个测试文件使用。

这些替身本身**不是**死代码；`MQStubServer`/`TestDirs` 的问题是打包位置（见第二节），
不是“死代码被当作生产入口”。

### 3.7 汇总

| 类别 | 数量 |
|---|---:|
| 完全死代码符号 | 6 |
| 仅测试使用（含 1 个合法钩子） | 11 |
| 只写字段/无消费者状态/协议字段 | 7 |
| 不可达分支 | 4 |
| 未使用 import | 2 |
| 注释代码块 / `@Deprecated` | 0 |

前四轮已报告、本轮复核仍存在的同类项：`MQNodePool.isClosed`（R1）、`MQPayloadKind.toString`（R1）、
`MQDeregisterPayload.isTopic`（R1）、`hasLocalQueues`/`MQMatcher.topicOf`（R3）、`ownersOf`/`nodeAt`/`indexOf`/
`pendingPeers`/`tombstoneFloor`（R2）、`removeByBuffer` 链路（R4）。这些不重复计入本轮，
但说明**死代码清理是跨轮次未闭环项**，建议在 `todo.md` 中合并为一次“符号清理”任务。

---

## 四、Requirement → 实现 → 用例矩阵

### 4.1 记号与判定口径

- `P` = `openspec/specs/f-mq/protocol/spec.md`，`C` = `openspec/specs/f-mq/client/spec.md`
- `M` = `fmq/metadata-cluster`，`Q` = `fmq/queue-storage`，`S` = `fmq/consume-semantics`
- `SR` = `fmq/server-runtime`，`MC` = `fmq/manager-cli`，`ME` = `fmq/metrics`，`D` = `docs`
- `✔` 直接或等价用例；`⚠` 仅弱断言/仅部分覆盖；`✘` 完全无用例。
- 「覆盖」列的分母是该 Requirement 的 Scenario 数；缺口场景在 4.12 逐条列出。

### 4.2 `f-mq/protocol`（18 Requirement / 64 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| P1 | 复用既有协议命令（`:8`） | `MQProtocol.cj:34-112` | `MQProtocol_test.factoriesUseExpectedCommands:41` | 1/2 ✘S2 |
| P2 | 四段字节布局（`:27`） | `MQMessageRecord.cj:39-142` | `fullRoundtripKeepsAllSegments:49`、`perSegmentDecodersAgree:176` | 5/5 |
| P3 | 记录字节承载与还原（`:60`） | `MQBlob.cj:66-115`、`MQProtocol.cj:195-225` | `consumeResultRoundtripsAtThresholds:83`、`largeRecordSurvivesFrameRoundtrip:73`、`nonFileStreamIsNotTreatedAsEmpty:125` | 6/6 |
| P4 | 载荷按运行时类型分派（`:101`） | `MQProtocol.cj:128-201` | `payloadKindsAreClassified:82`、`internalEnvelopeCarriesSubPayload:150`、`typeMismatchReturnsNone:92` | 5/5（S2 为过时冗余） |
| P5 | 响应与错误的构造（`:138`） | `MQProtocol.cj:113-126` | `responsesEchoRequestId:100`、`failUsesErrorCommandAndPayload:116`、`consumeResultParsing:127` | 4/4 |
| P6 | ACK 必须携带队列身份（`:163`） | `MQAckPayload.cj`、`ConsumeService.cj:110-121` | `ackPayloadCarriesQueueIdentity:139`、`ackTargetsExactQueueAndRejectsUnknownQueue:263` | 2/2 |
| P7 | 稳定错误码表（`:179`） | `MQConstants.cj:24-62` | `constantsAreStable:25`、`messagesAreNonEmptyAndUnique:41` | 2/3 ✘S3 |
| P8 | 主题路径校验（`:214`） | `MQTopic.cj:25-37` | `MQTopic_test.validTopics:24` / `invalidTopics:32` | 2/2 |
| P9 | 订阅过滤器求值（`:228`） | `MQFilter.cj:42-75` | `MQFilter_test` 5 条（`:44-109`） | 5/5 |
| P10 | 载荷类编解码自洽（`:259`） | `payload/*.cj` | `metaSnapshotNestedRoundtrip:126`、`topicAssignmentOwnerBounds:59`、`deadLetterRoundtrip:163` | 4/4 |
| P11 | BODY 容器编解码与过滤（`:285`） | `MQMessageRecord.cj:106-129`、`MQFilter.cj:83` | `containerBodiesRoundtrip:106`、`emptyContainerBodiesRoundtrip:129`、`containerBodiesSupportPathEvaluation:83` | 4/4 |
| P12 | 主题延迟字段（`:311`） | `MQTopicMeta.cj:33`、`MQTopicAssignment.cj:43` | `topicMetaAndAssignmentCarryDelaying:179` | 2/2 |
| P13 | messageId 发布时间解析（`:327`） | `MQMessageRecord.cj:105-131` | `publishTimeParsesStandardMessageId:144`、`publishTimeRoundTripsAcrossTimeZones:152`、`nonStandardMessageIdDeliversImmediately:663` | 4/4（S2 弱，见 R1 G17） |
| P14 | 统计请求载荷（`:355`） | `MQProtocol.cj:106`、`MQConstants.cj:76-78` | `statsRequestUsesRegisterAndInternalKind:169`、`configKeyAndInternalKinds:54` | 2/2 |
| P15 | 订阅组名校验（`:370`） | `MQGroup.cj:30-51`、`MQCommandExecutor.cj:104-137` | `MQGroup_test` 4 条、`registerGroupRejectsInvalidName:139` | 3/3 |
| P16 | 注销载荷 kind 判别（`:393`） | `MQDeregisterPayload.cj:57-73` | `deregisterWithUnknownKindDeletesNothing:166`、`deregisterTopicAndGroup:136` | 3/3 |
| P17 | 消息 BODY 类型契约（`:414`） | `MQMessage.cj:62-88` | `messageGetSupportsScalarsAndObjects:81`、`messageGetRejectsEmptyAndMismatchedBody:104` | 4/4 |
| P18 | 工厂重载与帧 id 一致性（`:440`） | `MQProtocol.cj:34,76-100` | `publishWithExplicitIdKeepsFrameAndRecordIds:222`、`allMetaSyncOverloadsRoundtrip:192` | 4/4 |

小计：**62/64**。

### 4.3 `f-mq/client`（9 Requirement / 45 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| C1 | 客户端配置与节点表（`:8`） | `MQClientConfig.cj`、`MQClient.cj:52-68` | 4 条 `MQClientConfig_test`（`:41-87`） | 4/4 |
| C2 | 发布路由与失败重试（`:34`） | `MQClient.cj:70-115` | `publishFallsBackFromNotOwnerAndCachesOwner:149`、`publishAllNotOwnerRaisesServiceException:377` 等 7 条 | 7/7 |
| C3 | 订阅广播与汇总 owner（`:78`） | `MQClient.cj:124-180` | `subscribeBroadcastsSamePayload:220`、`subscribeRollsBackOnGroupNotExist:254`、`subscribeDefaultGroupAndInvalidFilter:277` | 4/6 ✘S3,S5 |
| C4 | 阻塞式消费（`:118`） | `MQClient.cj:215-300` | `consumeDecodesMessageAndFillsPosition:303`、`consumeEmptyMovesToNextOwner:326`、`consumeWaitsUntilMessageArrives:587` | 7/7 |
| C5 | 确认路由（`:163`） | `MQClient.cj:302-366` | `ackGoesBackToDeliveryNode:637`、`ackPayloadKeepsQueueIdentity:665`、`ackSurfacesFailuresExceptUnknown:448` | 5/6 ✘S4 |
| C6 | 退订与生命周期（`:201`） | `MQClient.cj:368-414` | `unsubscribeIsIdempotentOnServerAndRejectsUnknownId:752`、`closeIsIdempotentAndBlocksApis:783`、`closeIsSafeUnderConcurrentCalls:912` | 6/6（S1 与规格相反） |
| C7 | 并发安全（`:240`） | `MQSubscription.cj:37`、`MQClient.cj:215-300` | `concurrentConsumersGetUniquePositions:819`、`sameDeliveryPositionIsClaimedOnce:527` | 3/3 |
| C8 | 节点连接自愈（`:261`） | `MQNodePool.cj:82-165` | `closedConnectionIsRebuilt:77`、`slowNodeDoesNotBlockOtherNodes:95`、`concurrentFirstUseBuildsOnce:133` | 3/4 ✘S4 |
| C9 | 客户端可观测性（`:288`） | `MQClient.cj:439-498` | `clientFailsWithPerNodeLogs:948`、`decodeFailureLogsPosition:970` | 2/2 |

小计：**41/45**。

### 4.4 `fmq/metadata-cluster`（12 Requirement / 66 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| M1 | 队列轮转分配（`:8`） | `MQAssignment.cj:28-50`、`MetaSyncer.cj:198` | `specExampleIsReproduced:24`、`remoteApplyAdvancesRoundRobinPointer:198` | 5/5 |
| M2 | 元数据目录与原子写（`:41`） | `MQFileNames.cj`、`AtomicFile.cj:38-103` | `pathLayoutMatchesSpec:44`、`writesInFsyncOrder:53`、`atomicWriteSurvivesStaleTmp:202` | 3/4 ✘S4 |
| M3 | 持久化与内存索引（`:78`） | `MetaStore.cj:91-480` | `persistenceReloadsEverything:42`、`concurrentRegisterTopicOnlyOneWins:417` 等 9 条 | 9/9 |
| M4 | 元数据全量复制（`:133`） | `MetaSyncer.cj:122-178,264-473` | `registerTopicAllocatesAndBroadcasts:60`、`remoteApplyIsIdempotentAndKeepsFirst:181`、`snapshotConflictKeepsLocal:574` | 6/6 |
| M5 | 启动期与恢复期同步（`:171`） | `MetaSyncer.cj:84-111,210-263` | `startupSyncMergesSnapshot:213`、`startupSyncWithAllPeersDownKeepsLocal:236`、`appliedTopicFromSnapshotOpensLocalQueue:498` | 4/5 ✘S4 |
| M6 | 节点表与身份（`:204`） | `NodeRegistry.cj`、`MQConfig.cj:275-345` | `nodeTableAndIdentity:50`、`successorsWrapAround:70`、`knownDeadOnlyAfterFailedCall:147` | 7/7 |
| M7 | 备份副本复制（`:248`） | `BackupReplicator.cj` | `sendsToRingSuccessors:55`、`timerFlushesBeforeBatchIsFull:126`、`onePeerFailureDoesNotBlockOthers:105` 等 11 条 | 11/11 |
| M8 | 延迟元数据持久化与复制（`:314`） | `MetaStore.cj:173-191`、`MQAssignment.cj:28-50` | `registerTopicKeepsDelayingInAssignmentAndBroadcast:164`、`allocateKeepsDelaying:68` | 3/3 |
| M9 | 元数据版本与墓碑（`:335`） | `MetaStore.cj:294-430` | `deleteWritesTombstoneThatSurvivesReload:344`、`tombstoneRemovesLocalEntryOnlyWhenOlder:393`、`tombstoneGcRespectsTtl:370` | 4/5 ✘S3 |
| M10 | 远端元数据结构校验（`:369`） | `MQAssignment.cj:52-105`、`MetaSyncer.cj:264-349` | `malformedRemoteAssignmentIsRejected:530`、`groupArrivingBeforeTopicIsAppliedLater:445`、`groupIsRejectedWhenTopicIsDeleted:470` | 4/4 |
| M11 | 备份副本消费位点（`:398`） | `BackupStore.cj:104-180`、`ConsumeService.cj:269-330` | `payloadCarriesRealStatesAndCursors:169`、`backupCursorRebuildsConsumerCursor:295`、`cursorsOnlyMoveForward:260` | 3/4 ✘S4 |
| M12 | 清理器异常隔离（`:428`） | `LogCleaner.cj:64-121` | `oneQueueFailureDoesNotStopOthers:255`、`timerKeepsRunningAfterFailure:296` | 2/3 ✘S2 |

小计：**61/66**。

### 4.5 `fmq/queue-storage`（14 Requirement / 45 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| Q1 | 目录布局与本机归属（`:8`） | `QueueManager.cj:72-118` | `onlyLocalQueuesAreCreated:39`、`topicWithoutLocalQueueHasNoPick:132` | 2/2 |
| Q2 | 追加返回位置且单调（`:23`） | `QueueLog.cj:58-67` | `rotationResetsOffsetAndIncrementsSequence:66`、`everyAppendIsImmediatelyReadable:251` | 2/2 |
| Q3 | 重启永不续写旧段（`:38`） | `QueueLog.cj` 构造/打开 | `restartOpensNewSegmentAndKeepsOldBytes:201`、`sizeUsesSegmentMetadata:180` | 2/2 |
| Q4 | 按位置读取与有界快照（`:53`） | `QueueLog.cj:92-121` | `openFromMiddleRecordReturnsRemaining:486`、`unknownSegmentResumesAtNextSegment:117`、`startingSegmentHoleResumesAtNextSegment:502` | 6/6 |
| Q5 | 有效长度以段元数据为准（`:90`） | `QueueLog.cj:128-146` | `sizeUsesSegmentMetadata:180` | 1/1 |
| Q6 | 本机队列轮转选择（`:99`） | `QueueManager.cj:190-196` | `pickQueueRotatesEvenly:148` | 1/1 |
| Q7 | 消费位点持久化（`:108`） | `CursorStore.cj:75-141` | `saveAndLoadRoundtrip:53`、`overwriteHasNoTmpResidue:69`、`defaultGroupUsesEncodedName:87` | 4/4 |
| Q8 | 主题删除清理（`:136`） | `QueueManager.cj:125-159`、`CursorStore.cj:93-120` | `deregisterTopicDeletesFilesAndMetadata:547`、`removeAllOfDeletesWholeTopic:103` | 2/3 ✘S3 |
| Q9 | 死信独立存储（`:158`） | `DeadLetterQueue.cj:31-104` | `appendAndIterateFromFirst:57`、`iterateFromMiddlePosition:81`、`reopenKeepsAllEntries:100` | 3/3 |
| Q10 | 段 TTL 清理（`:179`） | `CursorCatalog.cj:98-122`、`LogCleaner.cj:64-121` | 7 条 `LogCleaner_test`（`:60-222`） | 7/7 |
| Q11 | 记录边界格式与文档化（`:223`） | `QueueLog.cj:275-351` | `zeroLengthHeaderEndsTheStream:396`、`hugeDeclaredLengthIsRejectedWithoutAllocation:323`、`declaredLengthBeyondRemainingIsRejected:343` | 6/6（S3 与规格标题不符） |
| Q12 | 队列打开原子性（`:264`） | `QueueManager.cj:72-118` | `concurrentOpenCreatesSingleSet:63`、`failedOpenRollsBackAndLeavesNoTopic:104` | 3/3 |
| Q13 | 损坏/不可读可观测性（`:287`） | `GroupCursor.cj:352-370`、`ConsumeService.cj:155-263` | `unreadableRecordIsCounted:742`、`statsFailsWhenSegmentsAreGone:512` | 2/2 |
| Q14 | 读流恢复语义一致（`:303`） | `GroupCursor.cj:503-533`、`QueueLog.cj:203-221` | `allSegmentsMissingReturnsNone:457`、`allSegmentsMissingMidStreamReturnsNone:474`、`corruptionDoesNotReadIntoNextSegment:410` | 3/3 |

小计：**44/45**。

### 4.6 `fmq/consume-semantics`（14 Requirement / 42 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| S1 | 订阅匹配规则（`:8`） | `MQMatcher.cj:92-120` | `topicMustMatchExactly:48`、`tagsAreSubsetAndOrderIndependent:55`、`filterDecidesDelivery:76` | 5/5 |
| S2 | 组内不重复消费（`:41`） | `GroupCursor.cj:118-350` | `sameGroupDoesNotDuplicate:157`、`differentGroupsConsumeIndependently:690` | 2/2 |
| S3 | 连续确认前缀推进（`:56`） | `GroupCursor.cj:457-472` | `sequentialDeliveryAdvancesCommitted:160`、`outOfOrderAckKeepsHole:187` | 3/3 |
| S4 | 超时重投（`:76`） | `GroupCursor.cj:422-438` | `timeoutAllowsRedelivery:231`（含未超时分支） | 2/2 |
| S5 | 死信判定与按组隔离（`:91`） | `GroupCursor.cj:559-566` | `deliveryOverThresholdGoesToDeadLetter:256`、`entriesFromDifferentGroupsStayIsolated:162`、`deadLetterRoundtrip:163` | 3/3 |
| S6 | 自动确认（`:111`） | `GroupCursor.cj:118-280` | `autoAckAdvancesWithoutExplicitAck:279` | 1/1 |
| S7 | 确认归属校验（`:120`） | `GroupCursor.cj:375-400` | `ackChecksOwnership:214`、`ackRequiresDeliveredPosition:777` | 4/4 |
| S8 | 无匹配订阅者时暂停（`:146`） | `GroupCursor.cj:246-310` | `unmatchedRecordIsSkippedAndCommitted:299`、`groupWithoutOnlineSubscriberKeepsPosition:714` | 2/3 ✘S3 |
| S9 | 注销释放已分配记录（`:169`） | `GroupCursor.cj:402-420`、`ConsumeService.cj:122` | `releaseReturnsRecordToGroup:339`、`sweepReleasesInactiveOwner:357`、`disconnectedSubscriptionDoesNotBlockGroup:353` | 3/3 |
| S10 | 至少一次与重启恢复（`:190`） | `CursorStore.cj`、`GroupCursor.cj:378` | `restartRedeliversOnlyUnacked:378`、`catalogFloorTracksCommittedSegments:403` | 2/2 |
| S11 | 并发安全（`:205`） | `GroupCursor.cj` Mutex | `concurrentNextAndAckProduceUniquePositions:549` | 1/1 |
| S12 | 延迟投递（`:215`） | `GroupCursor.cj:541-557` | `delayedRecordWaitsUntilDue:587`、`delayedTopicBlocksHeadOfLine:607`、`delayedRecordSurvivesCursorReopen:629` | 6/6 |
| S13 | 无法评估 BODY 的出口（`:256`） | `GroupCursor.cj:352-358`、`MQCommandExecutor.cj:291-302` | `unsupportedBodyIsReportedOnceAndSkipped:309`、`unsupportedBodySkipIsCounted:531`、`unsupportedBodyIsRejectedBeforeAppend:291` | 4/4 |
| S14 | 离线组位点保留（`:290`） | `CursorCatalog.cj:98-122`、`GroupCursor.cj:503-533` | `offlineGroupPositionKeepsSegments:155`、`removedCommittedSegmentRecoversToOldestSurvivor:428`、`statsFailsWhenSegmentsAreGone:512` | 3/3 |

小计：**41/42**。

### 4.7 `fmq/server-runtime`（15 Requirement / 54 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| SR1 | 配置项与默认值（`:8`） | `MQConfig.cj:147-363` | `allConfigSemantics:30`、`serverHelpListsEveryConfigItem:31` | 3/4 ✘S2 |
| SR2 | 启动期校验（`:51`） | `MQConfig.cj:275-345` | `allConfigSemantics:30`（覆盖负数/越界/重复/0 端口等） | 8/8 |
| SR3 | 备份副本并发安全（`:106`） | `BackupStore.cj:52-84` | `concurrentAppendsReuseSingleQueueLog:35` | 1/1 |
| SR4 | 子命令分发（`:116`） | `main.cj:37-90` | `topLevelHelpReturnsZero:28`、`dispatchWithInjectedFactories:35`、`noArgumentsOrUnknownCommandReturnsTwo:88` | 3/3 |
| SR5 | 命令处理矩阵（`:136`） | `MQCommandExecutor.cj:67-378` | `registerTopicReturnsAssignment:184`、`subscribeConsumeAckFlow:330`、`garbagePayloadReturnsInternalError:418` 等 7 条 | 7/7 |
| SR6 | 启动装配与关闭（`:189`） | `MQServer.cj:135-274` | `bindAcceptPublishSubscribeAck:94`、`onlyLocalQueuesAreOpened:144`、`closeMakesRunReturnZero:372` | 6/7 ✘S3 |
| SR7 | 断链清理（`:233`） | `SubscriberRegistry.cj`、`MQServer.cj:285-306` | `cleanupSubscribersRemovesAndReleases:407`、`cleanupSubscribersKeepsResubscribed:455` | 3/3 |
| SR8 | 端到端可用性（`:255`） | `scripts/mq_e2e.sh` + 服务端 | `sameGroupDoesNotDuplicate:157`、`restartRedeliversOnlyUnacked:378` + E2E | 4/4 |
| SR9 | host 解析归属（`:280`） | `MQHost.cj:26` | `MQHost_test` 2 条（`:24,35`） | 2/2 |
| SR10 | 备份存储关闭并发安全（`:296`） | `BackupStore.cj:235-250` | `closeKeepsAcknowledgedWrites:93`、`closeRacesWithConcurrentAppends:124` | 3/3 |
| SR11 | 退出钩子（`:316`） | `main.cj:102-118`、`MQServer.cj:332` | `installExitHooksClosesServer:386` | 1/2 ✘S2 |
| SR12 | 关闭异常隔离（`:333`） | `MQServer.cj:197-243` | `closeIsolatesFailingStep:323`、`closeRetriesOnlyFailedStepsUntilComplete:344` | 2/2 |
| SR13 | 备份存储生命周期（`:349`） | `BackupStore.cj:86-250` | `cleanerReclaimsBackupSegmentsByCursor:178`、`closeKeepsAcknowledgedWrites:93` | 3/3 |
| SR14 | 可注入的启动装配（`:371`） | `main.cj:46-90` | `dispatchWithInjectedFactories:35` | 2/2 |
| SR15 | 服务端测试资产（`:387`） | —（测试要求） | `internalMetaSyncAppliesTopicGroupAndTombstone:434`、`closeClearsSubscriptionTable:520` | 2/3 ✘S2 |

小计：**50/54**。

### 4.8 `fmq/manager-cli`（9 Requirement / 37 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| MC1 | 参数解析（`:8`） | `MQManagerArgs.cj:36-89` | `serverCanAppearBeforeOrAfterCommand:25`、`defaultServerUsesConfiguredPort:37`、`configTokensAroundSubcommandAreSkipped:256` | 5/5 |
| MC2 | 管理子命令（`:41`） | `MQManager.cj:91-196` | `sixSubcommandsSucceedAndMutateState:160`、`registeredTopicOutputHasTopicCountAndOwners:60` | 5/5 |
| MC3 | 输出渲染（`:79`） | `MQManagerOutput.cj:34-168` | `cjkWidthIsTwo:25`、`tableColumnsAreAligned:37`、`errorUsesStablePrefix:48` | 2/2 |
| MC4 | 连接失败语义（`:93`） | `MQManager.cj:246-280` | `connectionFailureReturnsOne:216`、`statsConnectionFailureReturnsOne:249`（均弱） | 3/4 ✘S2 |
| MC5 | 与服务端语义一致（`:119`） | `MQManager.cj:41-196` | `sixSubcommandsSucceedAndMutateState:160`、`invalidGroupIsRejectedLocally:145` | 2/3 ✘S2 |
| MC6 | 子命令错误路径契约（`:139`） | `MQManager.cj:41-196` | `sixSubcommands...:160`、`subscriberRequiresExistingTopic:182`、`emptyListsReturnZero:192` | 5/6 ✘S1 |
| MC7 | 统计查询子命令（`:175`） | `MQManager.cj:178-196`、`MQManagerOutput.cj:65-87` | `registerTopicWithDelayingAndStats:224`、`statsRendersHeaderAndTwoRows:107`、`statsIgnoresHeaderAndShortRows:135` | 4/4 |
| MC8 | 主题延迟定义参数（`:204`） | `MQManager.cj:54-73`、`MQManagerArgs.cj:71` | `registerTopicWithDelayingAndStats:224`、`invalidDelayingReturnsTwo:238`、`operandCountIsValidated:44` | 4/4 |
| MC9 | 输出可断言（`:232`） | `MQManagerOutput.cj` | `registeredTopicOutputHasTopicCountAndOwners:60`、`topicListRendersOneRowPerTopic:73`、`statsRendersHeaderAndTwoRows:107` | 4/4 |

小计：**34/37**。注：MC4/MC6 的「覆盖」按“存在对应用例”计，但其中 11 条只断言退出码（见第二节）。

### 4.9 `fmq/metrics`（3 Requirement / 14 Scenario）

| # | Requirement（spec:行） | 实现 | 主用例 | 覆盖 |
|---|---|---|---|---|
| ME1 | 指标口径（`:8`） | `MQMetrics.cj:28-114`、`ConsumeService.cj:155-263` | `statsReportsBacklogLagAndCounters:371`、`autoAckCountsAckedAndClearsBacklog:408`、`removingTopicAndGroupClearsCounters:428` | 6/6 |
| ME2 | 统计查询（`:54`） | `ConsumeService.cj:155-263` | `statsWithoutTopicListsAllLocalTopics:565`、`statsAllTopicsAndFiltering:580`、`statsFailsWhenSegmentsAreGone:512` | 5/5 |
| ME3 | 指标清理入口（`:99`） | `MQMetrics.cj:49-81` | `removingTopicAndGroupClearsCounters:428` | 2/3 ✘S3 |

小计：**13/14**。

### 4.10 `docs`（3 Requirement / 12 Scenario）

| # | Requirement（spec:行） | 实现 | 人工核对结果 | 自动化 |
|---|---|---|---|---|
| D1 | 设计文档与实现一致（`:8`） | `f_mq/doc/详细设计.md`、`fmq/doc/详细设计.md` | 4/5 场景可 grep 命中；但 §3/§5.1/§5.18 等仍有 R1–R4 报告的漂移（子命令数、`openFrom`、`removeTopic` 返回值） | 0/5 |
| D2 | README 与实际行为一致（`:43`） | `fmq/README.md`、`README_en.md` | 3/4；`README.md:128`、`README_en.md:152` 的“跳到最老段”与实现相反（见 F3） | 0/4 |
| D3 | 任务台账真实（`:69`） | `f_mq/doc/spec/add-fmq-message-queue/tasks.md` | 2/3；台账本身无幽灵文件，但 `f_mq/doc/开发计划.md:256,274,294,315` 引用 4 个不存在的测试文件 | 0/3 |

小计：**0/12 自动化**。

### 4.11 覆盖总表

| 规格 | Requirement | Scenario | 直接/等价覆盖 | 缺口 |
|---|---:|---:|---:|---:|
| `f-mq/protocol` | 18 | 64 | 62 | 2 |
| `f-mq/client` | 9 | 45 | 41 | 4 |
| `fmq/metadata-cluster` | 12 | 66 | 61 | 5 |
| `fmq/queue-storage` | 14 | 45 | 44 | 1 |
| `fmq/consume-semantics` | 14 | 42 | 41 | 1 |
| `fmq/server-runtime` | 15 | 54 | 50 | 4 |
| `fmq/manager-cli` | 9 | 37 | 34 | 3 |
| `fmq/metrics` | 3 | 14 | 13 | 1 |
| `docs` | 3 | 12 | 0（自动）/ 9（人工） | 12 |
| **合计** | **97** | **379** | **346（91.3%）** | **33** |

### 4.12 缺口明细（33 条）

| # | 规格:行 | 缺口场景 | 现状 | 判定 |
|---|---|---|---|---|
| 1 | `P:22` | 不引入新命令号 | 只能静态检索，无用例 | 无用例（静态约束） |
| 2 | `P:209` | 每个码可达 | 静态核对 12/12 有生产构造点（`INTERNAL` 31 处、`SUBSCRIBE_NOT_EXIST` 10 处…），无用例 | 无用例 |
| 3 | `C:98` | 只把接受者记为 owner | 无用例；现有订阅用例 owner 集合均为全集或全空 | 无用例 |
| 4 | `C:108` | 回滚失败可观测 | `MQClient.cj:183-206` 实现完整，无失败注入用例 | 有实现无用例 |
| 5 | `C:186` | ack 发送失败可重试 | 无“投递节点不可达后重试仍命中”的用例 | 有实现无用例 |
| 6 | `C:283` | 关闭后不重建 | `MQNodePool.cj:86-88` 有分支，无 `pool.close()` 后 `clientOf` 用例 | 有实现无用例 |
| 7 | `M:73` | 掉电后不为空文件 | 仅 `atomicWriteSurvivesStaleTmp`（残留 `.tmp`）与 fsync 顺序，无“rename 后加载”断言 | 弱覆盖 |
| 8 | `M:194` | 反熵补删除 | 无“删除广播失败 → 反熵后对端删除”的用例；`pendingPeers` 也未参与选点 | 有实现无用例 |
| 9 | `M:354` | 新注册覆盖墓碑 | 只有组维度 `deletedGroupCanBeRecreatedWithHigherRevision`；主题墓碑 `registerTopic` 不清理（`MetaStore.cj:173-191`） | **无实现 + 无用例** |
| 10 | `M:423` | 记录与状态数量不一致 | `MQCommandExecutor.cj:249-257` 有分支，无用例（R2 已报，`tasks.md` W12 误归） | 有实现无用例 |
| 11 | `M:439` | 死信清理继续 | 无“普通队列删除失败时死信仍清理”的失败注入 | 有实现无用例 |
| 12 | `Q:153` | 删除中途崩溃 | `removeTopicDeletesGroupsBeforeTopicFile` 只断言终态顺序，无中断重启 | 弱覆盖 |
| 13 | `S:164` | 后加入的匹配订阅 | 无“已越过位置对后加入订阅不可见”的用例 | 有实现无用例 |
| 14 | `SR:36` | 环境变量覆盖 | `MQConfig_test` 用 `Config.set` 代替环境变量，未走 `env.getVariables()` | 弱覆盖 |
| 15 | `SR:208` | 无法连接任何 peer 仍可启动 | 仅 `MetaSyncer.startupSyncWithAllPeersDownKeepsLocal`，无 `MQServer.start()` 装配级用例 | 弱覆盖 |
| 16 | `SR:328` | manager 不安装退出钩子 | `Main_test` 用注入工厂，但未断言 `ExitCallbacks` 注册表 | 有实现无用例 |
| 17 | `SR:398` | 发布触发备份 | `MQCommandExecutor_test` 的 fixture `BackupReplicator(registry, 0)`，无入队断言（R4） | 有实现无用例 |
| 18 | `MC:104` | 配置缺失 | 无“读不到 `mqServer_port`”用例（R4） | 有实现无用例 |
| 19 | `MC:129` | 非绝对路径主题 | 只有 `MQCommandExecutor.invalidTopicIsRejected`，无 manager 级用例 | 弱覆盖 |
| 20 | `MC:145` | 注册成功后 `listTopics` 可见 | `sixSubcommands` 只断言两次退出码，未断言列表内容 | 弱覆盖 |
| 21 | `ME:115` | 清理与 stats 并发 | `MQMetrics` 用 `ConcurrentHashMap`，但无并发用例 | 有实现无用例 |
| 22-26 | `D:18,23,28,33,38` | 设计文档 5 个场景 | 无自动验收；人工发现 R1–R4 的签名/字段漂移仍在 | 仅手工 |
| 27-30 | `D:49,54,59,64` | README 4 个场景 | 无自动验收；子命令数量、段恢复语义有漂移 | 仅手工 |
| 31-33 | `D:75,80,85` | 台账 3 个场景 | 无自动验收；台账本体合格，外围 `开发计划.md` 有幽灵文件 | 仅手工 |

### 4.13 四类问题清单

#### A. 有实现、无用例（高风险 9 项）

`C:108` 回滚失败、`C:186` ack 重试、`C:283` 关闭后不重建、`M:423` 备份 states 数量校验、
`M:439` 死信清理隔离、`SR:328` manager 钩子、`SR:398` 发布触发备份、`MC:104` 管理端配置缺失、
`ME:115` 指标并发清理。其余见 4.12。这些路径的代码分支真实存在，但删除或改坏后测试全绿。

#### B. 无用例且无实现（1 项）

- `M:354`「新注册覆盖墓碑」：规格允许「墓碑被移除或**标记为已复活**」，实现二者都没做——
  `MetaStore.registerTopic:173-191` 既不删除同 key 墓碑，也不写复活标记；`topicTombstone(topic)`
  对被重建的主题仍返回 `Some`，墓碑还会持续随快照扩散、压低 `tombstoneFloor`（R2 已详述）。
  主题维度无任何用例，只有组维度等价用例。

#### C. 文档承诺但代码缺失 / 不一致

| 规格/文档:行 | 承诺 | 代码实际 |
|---|---|---|
| `M:139` | 广播失败节点进入待补偿集合，恢复时用快照收敛 | `pendingPeers` 只累加/清空，不参与选点与定向快照；反熵随机选点 |
| `M:354-357` | 墓碑被移除或标记复活 | 均未实现（见 B） |
| `fmq/README.md:128`、`README_en.md:152`、`fmq/doc/详细设计.md:790` | 位点段被删后“跳到现存最老段” | `GroupCursor.recoverIfSegmentGone:503-533` 跳到「最接近的更大段」；与 `queue-storage/spec.md:80-83` 一致，但与上述三处文档相反 |
| `P:317-325` | 示例 `MQTopicMeta("/t", 2, 61000)`、`MQTopicAssignment("/t", 2, 0, [0,1], 61000)` | 第三/第五参数是 `delayingMs!` 具名参数（`MQTopicMeta.cj:33`、`MQTopicAssignment.cj:43`），照抄无法编译 |
| `fmq/doc/详细设计.md:149,946`、`开发计划.md:127,443,500,520` | 管理端“六个子命令” | 实现与 `MQUsage.managerHelp()` 为 7 个（含 `stats`）；`详细设计.md:10` 又写“两个子命令”（指 server/manager），同文件三处口径不一 |
| `f_mq/doc/开发计划.md:256,274,294,315` | 引用 `MQClientPublish/Subscribe/Consume/Lifecycle_test.cj` | 四个文件均不存在（`docs/spec.md:80-83`「无幽灵文件」的同类问题） |
| `docs/spec.md:16` | 每项有唯一关键串“供验收脚本检查” | `scripts/` 下只有 `mq_e2e.sh`，无文档验收脚本；D1–D3 的 12 个场景全部只能人工核对 |

#### D. 用例与文档相反 / 名实不符

| 用例:行 | 文档承诺 | 用例断言 |
|---|---|---|
| `f_mq/src/client/test/MQClient_test.cj:752-775` | `client/spec.md:210-213`：同一 id 连续退订两次，**两次都不抛异常** | 第二次本地已无订阅，断言抛 `MQServiceException(7)`；实现 `MQClient.unsubscribe:368-395` 也抛 |
| `fmq/src/queue/QueueLog_test.cj:396-407` | `queue-storage/spec.md:244-247`：零长度前缀「视为损坏」 | 用例名 `zeroLengthHeaderEndsTheStream`，只断言返回空，未断言 `corrupted`/ERROR |
| `fmq/src/queue/GroupCursor_test.cj:502-527` | `consume-semantics/spec.md:294`、`README.md:128`：从“最老段”恢复 | 断言从段 7（最近的更大段）继续；与 `queue-storage/spec.md:80-83` 一致 |
| `fmq/src/cluster/MetaSyncer_test.cj:625-640` | 用例名：已知死亡节点“被跳过” | 注释与断言：不跳过，`attemptCount() == 2`（R2） |
| `fmq/src/server/MQManager_test.cj:104,125,160` | 用例名：不误报连接失败 / 状态变更 | 只断言 `run() == 1` / 退出码（R4、F1） |

---

## 五、本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 0 |
| 一般 | 9 |
| 建议 | 7 |

一般项：F1 管理端退出码断言、F2 退订幂等相反、F3 段恢复文档矛盾、F4 帮助文本漏测、
F5 测试替身进入生产、F6 过时「两种 kind」场景、F7 规格示例不可编译、F8 幽灵测试文件、
F9 主题墓碑复活缺失。
建议项：F10 巨型配置用例、F11 弱断言 4 处、F12 死代码清理（19 符号）、F13 只写字段/无消费者状态、
F14 不可达分支 4 处、F15 未使用 import 2 处、F16 子命令数量 6/7 并存。

复现口径：432 个用例 / 1604 条断言 / 0 空用例 / 0 无断言；379 个场景 / 346 有直接或等价覆盖 / 33 缺口。

---

## 六、总评

本轮在“空测试与空实现”这一最容易被掩盖的维度上给出了明确结论：**432 个用例全部有断言，
没有空 `@TestCase`、没有 `@Ignore`/禁用、没有注释用例、没有 `throw NotImplemented`、没有 TODO 占位**。
唯一的空函数是日志替身的 `flush()`，属于合法实现。测试数量（128 + 304）与台账一致，
断言密度（3.7 条/用例）也说明作者不是“写个用例占位”。

但“有断言”不等于“有效断言”。全局最突出的问题是**测试与它声称验证的契约脱节**：

1. **管理端 12 个用例里 11 个只断言退出码**，而规格自己写着“用例 SHALL NOT 仅断言退出码”。
   这使得 A65 这类“错误分类”修复没有任何回归保护，也让 `sixSubcommandsSucceedAndMutateState`
   这样的名字失去意义。
2. **关键失败/恢复路径仍有 20 余个“有实现、无用例”的洞**：回滚失败、ack 重试、
   关闭后不重建、备份 states 数量校验、死信清理隔离、指标并发清理、发布触发备份、manager 钩子。
   这些正是最容易被后续重构悄悄改坏的分支。
3. **文档三方矛盾**：段恢复语义在 `queue-storage` 规格、`consume-semantics` 规格、README、详细设计之间
   存在“最老段 vs 更大段”的相反表述，而用例断言的是其中一方；退订幂等的规格与实现/用例相反；
   主题墓碑复活是规格承诺、代码二者皆无。
4. **文档规格（D1–D3，12 个场景）完全没有自动化验收**，只靠人工 grep，导致 R1–R4 指出的签名漂移
   （`removeTopic` 返回值、`openFrom`、子命令数量）在“文档任务已勾选”的状态下继续存在。

死代码方面，本轮未发现“整块死代码被当作生产入口”的情况；问题集中在局部：
6 个完全死符号、11 个仅测试使用符号、7 个只写字段/无消费者状态、4 个不可达分支、2 个未使用 import。
其中 `SegmentMissingException`、`openFrom`、`hasLocalQueues`、`MQMatcher.topicOf`、`MQSubscription`
的五个只写字段最值得优先清理；`MQStubServer.cj`/`TestDirs.cj` 被编入生产源码树是打包问题，
应在下一次构建调整中一并解决。

需求追踪的整体覆盖率是 **346/379（91.3%）**，主干功能（协议编解码、客户端路由、元数据墓碑、
队列段格式、消费语义、服务端生命周期、指标口径）覆盖扎实；缺口集中在“失败注入、并发、崩溃恢复、
文档验收”四类——也恰好是最难写、最容易退化的四类。

最后必须指出：R1–R4 的严重项（墓碑不参与接受判断、`applyTombstone` 输掉版本仍删除、段末尾消费停摆、
A65 用例无输出断言等）在 HEAD `22c13ec4` 上仍然成立，本轮不重复计分，但它们决定了本次全量审计
**尚不能判定为“质量达标”**。建议 `todo.md` 将“严重项闭环”与“20 个有实现无用例”列为下一轮前置条件，
再把死代码清理与文档矩阵自动化作为常规维护项。
