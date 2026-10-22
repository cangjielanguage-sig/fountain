# docs（delta）

## ADDED Requirements

### Requirement: 模块限制说明可查

每一条会导致客户端/服务端抛异常的输入限制 SHALL 在模块文档中有唯一、可检索的说明，
至少包括：

- 主题：必须以 `/` 开头（绝对路径）、字符集限制；
- 订阅组名：≤ 255 字节、不含 `/ \ : %`、不以 `.` 开头/结尾、不含控制字符与 Unicode 空白、
  空串表示默认组；
- tags：数量 ≤ 64、单条 ≤ 128 字节、字符集限制、子集匹配语义；
- 记录：单条 ≤ `min(64 MiB, segmentedLogMaxSize - 4)`；
- messageId：23 位时间戳按 UTC 解释。

文档 SHALL 给出常量出处（源码文件与符号名），MUST NOT 只写「有校验」。
校验失败时的错误码/异常类型 SHALL 与实现一致（`INVALID_TOPIC`、`INVALID_GROUP`、
`INVALID_TAGS`、`MQException`）。

#### Scenario: 组名限制可查

- **WHEN** 在 `f_mq/README.md` 与详细设计检索「255」「MAX_LENGTH」
- **THEN** 能找到组名长度、禁用字符与「默认组为空串」的说明

#### Scenario: tags 限制可查

- **WHEN** 检索「64」「128」
- **THEN** 能找到 tags 数量/长度上限与 `MAX_COUNT`/`MAX_LENGTH` 的源码出处

#### Scenario: 错误码一致

- **WHEN** 对照文档中的限制与 `MQErrorCode`
- **THEN** 每条限制都能指出触发时的错误码或异常类型

### Requirement: 规格自身无矛盾

同一能力在 `openspec/specs/**` 中 MUST NOT 存在两套互斥表述。以下四项 SHALL 收敛为单一权威说法，
并在归档时同步到主规格：

1. **位点段被删**：唯一说法为「跳到编号更大的最近现存段起点 + WARN，游标前移并落盘；
   修复前 `stats` 返回错误」。`README`、两份详细设计、`consume-semantics`、`queue-storage`
   与用例断言 SHALL 全部一致；MUST NOT 再出现「跳到现存最老段」。
2. **退订幂等**：「已成功退订过的 id 再退订返回成功且不发请求；从未订阅的 id 抛
   `MQServiceException` 且不发请求」。正文与 Scenario SHALL 一致。
3. **内部消息 kind**：只有 `metaSync`/`backup`/`stats` 三种；「两种 kind」场景 SHALL 删除。
4. **延迟构造**：`delayingMs` 为具名参数，所有示例 SHALL 可直接编译。

#### Scenario: 段恢复只有一套说法

- **WHEN** 在**当前维护面**（`openspec/specs/**`、`f_mq/doc/详细设计.md`、`fmq/doc/详细设计.md`、
  两份 README）检索「最老段」与「更大段」
- **THEN** 只剩「更大段/后继段」一种语义描述；`doc/spec/**` 与 `openspec/changes/archive/**`
  属历史快照，不在检索范围

#### Scenario: 退订正文与场景一致

- **WHEN** 对照 client 规格正文与「退订幂等」场景
- **THEN** 两者都描述「两次均成功」，且用例断言一致

#### Scenario: kind 唯一

- **WHEN** 检索「两种 kind」
- **THEN** 结果为 0（历史 change 归档目录除外）

#### Scenario: 示例可编译

- **WHEN** 把任意规格中的 `delayingMs` 示例复制到用例
- **THEN** 编译通过

### Requirement: 文档漂移清单逐项闭环

`f_mq/doc/详细设计.md` 与 `fmq/doc/详细设计.md` SHALL 逐项修正下列已确认漂移，
每项 SHALL 有可 grep 的验收串：

| 位置 | 现状 | 要求 |
|---|---|---|
| `f_mq/doc/详细设计.md` §5.10 | `MQMetaSnapshot` 只列 3 字段 | 列 `topics`/`groups`/`tombstones`/`revision`，与 §4.1 一致 |
| `f_mq/doc/详细设计.md` §5.2 | `MQSubscribeGroupMeta` 缺版本字段 | 列 `revision`/`origin` |
| `f_mq` 门面章节 | import 条数三条 | 与实现一致（五条） |
| `MQSubscription.cursor` | `Int64` | `AtomicInt64` |
| `removeTopic` 返回 | `?MQMetaTombstone` | `Array<MQMetaTombstone>` |
| `NodeRegistry` | 只有 `self` | `selfIndex`，并列出 `isKnownDead`/`onRevived` |
| `fmq` §5.8 | 签名块缺方法 | 补 `openRecordsFrom`/`segmentsOrEmpty`/`removeById`/`scanAfter`/`resolveStart`（`countAll` 已下沉测试，文档不列） |
| `fmq` §5.11 | `owner = None` | `owner = Some(subscription.subscribedId)` |
| `fmq` §5.12 | `backlog` 由 `scanAfter` 计算 | 由 `ConsumeService.stats` 扫描计算 |
| `fmq` §6.4 | 读端抛 `QueueCorruptionException` | 游标路径返回损坏结局并记 ERROR（仅 `scanAfter` 抛） |
| `fmq` §5.6 | `CursorStore.init(offsetRoot)` | `metaRoot`，并补 `removeGroup`/`hasCursor` |
| `fmq` §4 | `CursorCatalog` 无小节 | 新增 §5.x |
| `fmq` §6.11 | 未列 `unsupportedSkipped` | 列三个跳过计数（`unreadableSkipped`/`noMatchSkipped`/`unsupportedSkipped`） |
| `fmq` §6.7 | 断链清理用 `removeByBuffer`、与 `LogCleaner` 同一批定时器 | 改为 `cleanupSubscribers()`（2s 独立定时器，按 id + generation） |
| `fmq` §3 | `getValue(...) ?? 默认` | `Config.getString` + `strictPort`/`strictInt64`/`strictDuration` |
| `fmq` §3 依赖表 | 含未使用的 `f_util`/`f_data` | 与 `cjpm.toml` 一致 |
| `fmq` §5 `main` | `MQServer(MQConfig).run()` | 列出 `dispatch`/`dispatchWith`/`installExitHooks` |
| `fmq` §5 `onPublish` | `(buffer, request) -> ?Message` | `(request) -> Message` |
| `fmq` §5 `SubscriberRegistry` | `register(subscription, buffer)`/`byGroup` | `register(info)`/`byGroupOf`，并列 `activeIds`/`infos`（`count`/`generations` 已删，文档不列） |
| `fmq` §5 `MQManagerOutput` | 只列 `table`/`error` | 列 `registeredTopic`/`topicList`/`stats`/`assignments`/`width` 与 3 个常量（`ERROR_PREFIX`/`EMPTY`/`STATS_HEADER`） |
| `fmq` §7 | `[delayingMs]`、输出「0..N-1」 | `delaying=<DurationString>`、输出「队列 0..3（共 4 个），延迟：0s，分配：0→0,1→1」 |
| `fmq` §7 关闭顺序 | 缺 `subscribers` 与 `queues.sync` | 补全 13 步列表 |
| 子命令数量 | 文档/注释写「六」 | 全部改为 7 |

#### Scenario: 快照字段可对照

- **WHEN** 对照 §5.10 与 `MQMetaSnapshot.cj`
- **THEN** 字段集合完全一致

#### Scenario: 签名可 grep

- **WHEN** 检索 `byGroupOf`、`installExitHooks`、`cleanupSubscribers`、`openRecordsFrom`
- **THEN** 均出现在对应章节，且签名与源码一致

#### Scenario: 关闭顺序完整

- **WHEN** 数关闭步骤
- **THEN** 含 `subscribers` 与 `queues.sync`，共 13 步，顺序与 `closeSteps` 一致

## MODIFIED Requirements

### Requirement: 设计文档与实现一致

`f_mq/doc/详细设计.md` 与 `fmq/doc/详细设计.md` SHALL 与源码保持一致，至少覆盖：
协议字段与构造签名、命令分派表、`MQConsumeResult`/`MQAckPayload`/`MQMessage` 的 `queueIndex`、
`MQTopicMeta`/`MQTopicAssignment` 的 `delayingMs`（具名参数）、`MQInternalMessage` 的三种 kind 与
五个 `metaSync` 重载、`MQClient` 的公开签名（含 `ack` 的 `queueIndex`）、`MQNodePool` 构造参数、
`GroupCursor` 的 `entries` 结构/`next` 参数/`sweep` 触发方式、段记录格式（含
`effectiveMaxRecord` 的推导）、备份语义（真实状态、异步发送、按 target 重试、关闭排空、清理）、
退出钩子与完整关闭顺序、子命令数量与输出格式。

文档中的每个符号 SHALL 与源码同名、同参数个数/顺序/类型；MUST NOT 描述零调用方的「生产 API」。
文档与实现冲突时 SHALL 以「先改文档、再改实现」的顺序收敛，并在变更任务中留痕。
每项 SHALL 有可 grep 的唯一关键串，供验收脚本检查。

#### Scenario: 协议字段可检索

- **WHEN** 在 `f_mq/doc/详细设计.md` 检索 `queueIndex`、`delayingMs`、`ACK`、`stats`
- **THEN** 对应表项同时出现字段名与语义说明，且与 `f_mq/src/base/payload/*` 一致

#### Scenario: 签名可对照

- **WHEN** 对照文档中的 `MQClient.ack` 与源码
- **THEN** 参数个数、顺序与类型一致

#### Scenario: 分派与 kind 完整

- **WHEN** 查阅内部消息章节
- **THEN** 列出 `metaSync`/`backup`/`stats` 三种 kind 及各自子载荷类型

#### Scenario: 存储格式与上界

- **WHEN** 查阅 `fmq/doc/详细设计.md` 存储章节
- **THEN** 含「4 字节大端长度 + 记录字节」、`effectiveMaxRecord`、不可跨段、零长度视为损坏

#### Scenario: 关闭顺序与钩子

- **WHEN** 查阅服务端生命周期章节
- **THEN** 含退出钩子注册点与「相反顺序释放」的完整列表

#### Scenario: 无幽灵 API

- **WHEN** 对文档中每个「生产 API」符号做全仓引用检索
- **THEN** 至少有一个非测试调用方，或已从文档删除

### Requirement: README 与实际行为一致

`f_mq/README.md`、`f_mq/README_en.md`、`fmq/README.md`、`fmq/README_en.md` SHALL 准确描述：

- 依赖列表：`f_mq` 为 10 个（`f_base`、`f_codec`、`f_config`、`f_data`、`f_io`、`f_log`、
  `f_net`、`f_protocol`、`f_time`、`f_util`），与 `cjpm.toml` 一致；
- 配置覆盖方式与参数位置限制；
- 7 个管理子命令与 `registerTopic` 的 `delaying=<DurationString>` 写法；
- 备份的丢弃/重试/关闭排空/清理语义，与 `BackupStore` 关闭后「留痕丢弃」一致；
- 段 TTL 与离线组保留；
- 统计错误的可见性（含三个跳过计数列）；
- 字符限制与记录上限。

文档 MUST NOT 声称实现未提供的能力，也 MUST NOT 与实际丢弃策略矛盾。

#### Scenario: 命令行写法

- **WHEN** 按 README 示例执行配置参数前置与后置两种写法
- **THEN** 两种都能启动或返回帮助，退出码符合描述

#### Scenario: 子命令数量

- **WHEN** 检索 README 与管理端 `--help`
- **THEN** 均为 7 个子命令（含 `stats`），名称一致

#### Scenario: 备份语义

- **WHEN** 查阅备份章节
- **THEN** 明确「发布不阻塞」「失败按 target 重试」「关闭排空」「队列满/关闭丢弃并 WARN」

#### Scenario: 依赖完整

- **WHEN** 对照 README 依赖列表与 `f_mq/cjpm.toml`
- **THEN** 10 个依赖全部出现，无多余项

#### Scenario: 已知限制

- **WHEN** 查阅已知限制
- **THEN** 含「离线超过墓碑 TTL 的节点需全量重建」「大记录依赖全部节点升级」
  「已退订 id 集合有界，淘汰后按未知 id 处理」三条

### Requirement: 任务台账真实

`f_mq/doc/spec/add-fmq-message-queue/tasks.md` 与 `f_mq/doc/开发计划.md` SHALL 反映真实完成状态：

- 已完成项 SHALL 勾选，未完成项 MUST NOT 勾选；
- 每条勾选项 SHALL 能指向实际存在的文件或用例，不得引用不存在的用例文件；
- `开发计划.md` 中 `MQClientPublish_test.cj`/`MQClientSubscribe_test.cj`/`MQClientConsume_test.cj`/
  `MQClientLifecycle_test.cj` 等幽灵文件 SHALL 改为真实路径（`src/client/test/MQClient_test.cj`）
  或删除该引用；
- `@Expect` 与实际 `@Assert`、性能规模（500 次 vs 10 万次）、数据结构（`ConcurrentHashMap` vs
  `HashMap + Mutex`）、用例名（`clientOfSameIndexIsCached`、`aliveNodesFiltersClosed`）SHALL 与现状一致；
- 历史 `tasks.md` 中 V9、26.1、W12/W29 的勾选状态 SHALL 与本次实现一致（未落实则取消勾选并在
  本变更 tasks 中重建条目）。

#### Scenario: 勾选项可验证

- **WHEN** 对每个 `[x]` 项检查其声称的文件或用例
- **THEN** 文件存在且用例可运行

#### Scenario: 无幽灵文件

- **WHEN** 检索台账中出现的 `*_test.cj`
- **THEN** 全部存在于仓库

#### Scenario: 六项遗留已勾选

- **WHEN** 查阅第 11 节
- **THEN** 11.1–11.6 的状态与实际一致（已落地则勾选）

#### Scenario: 历史勾选与事实一致

- **WHEN** 查阅第 11 节与 26.x
- **THEN** 状态与实际一致；不实勾选已取消并注明原因

#### Scenario: 开发计划可执行

- **WHEN** 按 `开发计划.md` 的步骤与用例名执行
- **THEN** 文件与用例都存在，术语（`@Assert`）与实现一致
