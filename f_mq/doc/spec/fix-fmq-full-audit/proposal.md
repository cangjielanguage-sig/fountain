# Proposal: fix-fmq-full-audit

## Why

`reviews/202610210648_fmq-f_mq-full-audit/todo.md`（来源 R1–R6）记录了 `f_mq` 与 `fmq` 的 75 项问题：
11 项严重、64 项一般。它们不是风格问题，而是可观测的正确性缺陷：

- **静默数据丢失**：超过 4096 字节的记录经对象载荷传输时字段被降级为空字节，服务端据此回
  「本次没有消息」，消费端永久空转；备份/死信/内部信封同样失效。
- **静默消息复活**：元数据复制没有墓碑与版本，删除只删本地文件；离线节点重启后会把已删除主题
  重新当作有效主题对外服务。
- **静默重放**：备份副本的状态是硬编码的「未投递、未确认」，接收端也不落状态，按备份恢复会把
  已确认消息整段重放。
- **静默删除**：段 TTL 只看内存游标，离线组在磁盘上的位点被忽略，慢组积压会被直接删掉。
- **静默停摆**：不可评估 BODY 让整组游标永久停在同一位置；客户端所有 owner 不可达时 `consume`
  永不返回也不抛异常；节点连接关闭后永不重建。
- **进程级风险**：损坏段的 4 字节长度头没有上界，读端可一次性申请 4 GiB；备份批次在发布线程内
  同步发送，最坏把一次 publish 拖住数秒；生产入口没有退出钩子，`MQServer.close()` 不可达。

同时，现有规格、设计文档与任务台账本身存在与实现冲突之处（`consume-semantics`「组内无匹配」
正文与场景相反；详细设计缺 `queueIndex`/`delayingMs`；`tasks.md` 把已完成项留空），使后续审查
无法据文档判定对错。本变更把这些缺陷收敛为可验收的规格、设计与任务，实现阶段严格按 TDD 推进。

## What Changes

按 capability 拆分，每项变更都能对应到一条 Requirement 与一组任务：

1. **f-mq/protocol**：字节字段改用可解码大载荷的 `MQBlob`；记录时间戳统一 UTC；载荷解码改为严格
   模式（不再产生「字段全默认」的对象）；`MQMessage.get<T>` 的空/异类 BODY 返回 `None`；补订阅组名
   校验与 `INVALID_GROUP` 产生路径；注销载荷 `kind` 必须精确匹配；补内部信封四类子载荷与
   `publish(record, id!)` 的一致性要求。
2. **f-mq/client**：节点连接可自愈且建连不占全局锁；区分「服务错误 / 空响应 / 连接失败」；
   `ack` / `unsubscribe` / `subscribe` 回滚的失败可见且可重试；新增客户端日志与投递位置唯一认领；
   本地补齐 tags 与组名校验；`close()` 与在途调用并发安全。
3. **fmq/metadata-cluster**：元数据引入 `revision + origin` 与墓碑，快照与广播都能传播删除；
   `applyTopic/applyGroup` 下沉到 `MetaStore` 一次临界区内完成「检查 + 写盘 + 推进指针」；远端
   分配做结构校验；恢复期同步后打开新主题队列；补反熵；备份携带真实消费状态、发送移出发布
   线程、失败可重入队、接收端落盘位点；节点连接自愈与存活语义修正。
4. **fmq/queue-storage**：读取端对长度头设上界并按剩余字节校验；段保留纳入**持久化游标**与
   备份游标；`scanAfter` / 不可读记录 / 读流恢复的行为统一且可观测；元数据与游标写入 fsync；
   `openTopic` 并发原子；死信完整性。
5. **fmq/consume-semantics**：`ack` 只接受已投递的位置；不可评估 BODY 有「跳过 + 一次性报错」
   的有界出口；消除「组内无匹配」正文与场景的矛盾（定为越过并留痕）；断链释放及时。
6. **fmq/server-runtime**：生产入口接入 `ExitCallbacks`，`close()` 异常隔离且可重试；断链清理
   可注入、可测且无「重订阅被误删」竞态；配置全量校验并复用 `MQHost.parseHost`；`dispatch` 可注入
   装配点；备份存储纳入生命周期与清理；子命令支持配置参数前置。
7. **fmq/manager-cli**：服务端 `ERROR` 不再被报成「无法连接」；输出层可直接断言；帮助文本与
   实际 7 个子命令一致。
8. **fmq/metrics**：`acked` 覆盖 autoAck 投递；删除主题/组时清理计数器；`stats` 读失败不得回
   `backlog=0`；单趟扫描替代 `O(G×N)`。
9. **docs**（新增 capability）：`f_mq/doc/详细设计.md`、`fmq/doc/详细设计.md`、`fmq/README.md`
   与实现逐项对齐，并给出可 grep 的验收点；`tasks.md` 台账改为真实状态。

**非目标**：不做跨节点事务、不做自动故障转移、不做备份自动接管、不改段文件二进制格式、不新增
协议命令号、不替换 `f_io`/`f_codec` 的底层存储与编码实现。

## Capabilities

**Modified Capabilities**

- `f-mq/protocol`
- `f-mq/client`
- `fmq/metadata-cluster`
- `fmq/queue-storage`
- `fmq/consume-semantics`
- `fmq/server-runtime`
- `fmq/manager-cli`
- `fmq/metrics`

**Added Capabilities**

- `docs`：把「文档与实现一致」「任务台账真实」变成可验收的系统约束。

## Impact

| 范围 | 影响 |
|---|---|
| `f_mq/src/base/payload/*` | 字节字段改为 `MQBlob`；`MQConsumeResult`/`MQInternalMessage`/`MQBackupPayload`/`MQDeadLetterMessage` 构造签名保留 `Array<Byte>` 重载 |
| `f_mq/src/base/MQProtocol.cj` | 严格解码、`asConsumeResult` 失败语义、`publish(record, id!)` 校验 |
| `f_mq/src/base/MQMessageRecord.cj` | `MQBlob` 读取临时文件并清理；`publishTime` 增加未来时刻告警 |
| `f_protocol/src/default/MessageID.cj` | `toString()` 固定按 UTC 格式化（**行为变更**） |
| `f_mq/src/client/*` | 连接池重建、错误分类、日志、认领、tags 校验、并发关闭 |
| `fmq/src/meta/MetaStore.cj` | 原子注册接口、`revision/origin`、墓碑、结构校验、fsync |
| `fmq/src/cluster/MetaSyncer.cj` | 删除收敛、反熵、远端校验、恢复后打开队列 |
| `fmq/src/cluster/BackupReplicator.cj` | 独立发送线程、真实状态、重试、WARN 口径 |
| `fmq/src/server/BackupStore.cj` | 落盘游标、参与 TTL 清理、生命周期 |
| `fmq/src/queue/*` | 长度上界、持久化游标保留、`ack` 已投递校验、`openTopic` 原子、fsync |
| `fmq/src/server/MQServer.cj` / `fmq/src/main.cj` | 退出钩子、关闭容错、可注入启动、断链清理竞态 |
| `fmq/src/config/MQConfig.cj` | 全量校验、`MQHost` 复用、新增 `mqServer_tombstoneTTL` / `mqServer_antiEntropyInterval` |
| `fmq/src/metrics/*`、`fmq/src/manager/*` | 计数口径、统计错误传播、CLI 错误分类 |
| `f_mq/doc/*`、`fmq/doc/*`、`fmq/README*.md` | 与实现对齐，补全字段/签名/格式/限制 |

**兼容性**

- 传输格式：对象载荷的字段类型变化不进入对象类型特征（特征只取类全名），`MQBlob` 的 `toData()`
  与 `Array<Byte>` 完全一致，因此**不改变字节布局**；新增字段一律带默认值，旧节点可忽略。
- 存储格式：段文件、`.meta`、`.cursor`、`assign.meta` 的编码不变；新增墓碑目录与备份游标目录，
  旧数据可直接加载。旧版本进程读新数据时忽略墓碑，可能在滚动升级窗口内短暂「复活」删除项，
  升级完成后由反熵与墓碑收敛。
- 公开 API：`MQClient.ack` / `unsubscribe` / `consume` 由「静默忽略」改为「抛异常」；全部
  `NOT_OWNER` 由 `MQConnectionException` 改为 `MQServiceException(NOT_OWNER)`。按语义级
  **BREAKING** 记录，仓库内调用点与用例同步更新。
- 指标：`acked` 对 autoAck 组不再是 0；`stats` 在读失败时改为返回 `ERROR(INTERNAL)` 而不是
  `backlog=0`。列结构不变。
- 配置：非法显式值由「静默回落默认」改为启动失败（退出码 2）；`mqServer_tombstoneTTL` 新增，
  默认 7d。

## 审查问题映射（75 项）

> 每条问题至少映射一条 Requirement 或一个文档/测试任务；任务编号见 `tasks.md`。
> 级别取 `todo.md` 原文（严重/一般），轮次为 R1–R6。

| ID | 轮次 | 级别 | 问题摘要 | 映射 |
|---|---|---|---|---|
| A01 | R1 | 严重 | >4KB 记录经对象载荷被降级为空数组 | protocol:大载荷（T1）；queue-storage:损坏可观测（T3） |
| A02 | R1 | 严重 | `publishTime` 与本地时间 ID 不一致，跨时区偏移 | protocol:UTC 时间戳（T10） |
| A03 | R1 | 一般 | `decodePayload` 对标量/异类载荷返回默认对象 | protocol:严格解码（T11） |
| A04 | R1 | 一般 | `MQMessage.get<T>` 对空/异类 BODY 返回默认对象 | protocol:BODY 契约（T11） |
| A05 | R1 | 一般 | `INVALID_GROUP` 无产生路径，组名校验缺失 | protocol:组名校验（T12） |
| A06 | R1 | 一般 | `metaSync` 四重载与子载荷分支无用例 | protocol:信封可判别（T28）；metadata:信封测试（T28） |
| A07 | R1 | 一般 | 16KB 用例未验临时文件形态与清理 | protocol:大载荷（T1.2/T28） |
| A08 | R1 | 一般 | `publish(record, id!)` 无用例，帧/记录 id 无守护 | protocol:帧 id 一致（T28） |
| A09 | R1 | 一般 | `f_mq/doc/详细设计.md` 与实现多处不一致 | docs:设计一致性（T29） |
| A10 | R1 | 一般 | `isTopic()` 不校验 `kind`，拼错即删组 | protocol:kind 判别（T12） |
| A11 | R2 | 严重 | 节点连接一次性使用，故障后永不重建 | client:连接自愈（T13）；metadata:自愈（T13） |
| A12 | R2 | 一般 | 全部 owner 不可达时 `consume` 永久空转 | client:故障区分（T14） |
| A13 | R2 | 一般 | `ack` 静默忽略全部失败与错误码 | client:失败可见（T14） |
| A14 | R2 | 一般 | `unsubscribe` 忽略发送结果，服务端残留 | client:失败可见（T14） |
| A15 | R2 | 一般 | `subscribe` 回滚忽略失败 | client:失败可见（T14） |
| A16 | R2 | 一般 | 客户端零日志，解码失败静默丢消息 | client:可观测性（T14） |
| A17 | R2 | 一般 | 建连在全局锁内，慢节点阻塞全部 | client:连接自愈（T13） |
| A18 | R2 | 一般 | 全 `NOT_OWNER` 被分类为连接异常 | client:故障区分（T14） |
| A19 | R2 | 一般 | `publish` 未校验 tags，与规格矛盾 | client:本地校验（T12） |
| A20 | R2 | 一般 | `consume` 无客户端认领，并发用例虚假 | client:唯一认领（T15） |
| A21 | R2 | 一般 | 客户端 8 条关键失败路径零覆盖 | client:测试资产（T28） |
| A22 | R2 | 一般 | 任务清单虚报用例文件与内容 | docs:台账真实（T30） |
| A23 | R2 | 一般 | 详细设计客户端签名/行为漂移 | docs:设计一致性（T29） |
| A24 | R2 | 一般 | `MQClientConfig_test` 泄漏全局配置且缺场景 | client:测试隔离（T28） |
| A25 | R3 | 严重 | 删除不可传播，离线节点复活已删主题/组 | metadata:墓碑与纪元（T4）；metadata:反熵（T16） |
| A26 | R3 | 严重 | 备份消息状态是伪造值，接收端忽略 | metadata:备份真实状态（T5） |
| A27 | R3 | 严重 | 备份 64 条在发布线程同步发送 | metadata:备份异步（T5） |
| A28 | R3 | 严重 | `registerTopic/Group` 丢弃结果，检查-执行非原子 | metadata:注册原子性（T7） |
| A29 | R3 | 一般 | 死转活重同步不打开新主题队列 | metadata:恢复装配（T16） |
| A30 | R3 | 一般 | 备份批次失败整批丢弃，无重试 | metadata:备份重试（T5） |
| A31 | R3 | 一般 | 广播失败只 WARN，无补偿 | metadata:墓碑与反熵（T4/T16） |
| A32 | R3 | 一般 | `mergeSnapshot` 不检测冲突、不告警 | metadata:快照冲突（T16） |
| A33 | R3 | 一般 | `applyRemote` 乱序使轮转指针回退 | metadata:指针单调（T16） |
| A34 | R3 | 一般 | 远端元数据缺结构校验 | metadata:结构校验（T16） |
| A35 | R3 | 一般 | `removeTopic` 崩溃窗口产生孤儿组 | metadata:删除顺序（T8） |
| A36 | R3 | 一般 | `applyGroup` 不校验主题存在 | metadata:组依赖（T8） |
| A37 | R3 | 一般 | 元数据写入无 fsync，掉电得空文件 | metadata:持久化（T6） |
| A38 | R3 | 一般 | `record()` 关闭后静默丢弃 | metadata:备份告警（T5） |
| A39 | R3 | 一般 | `NodeRegistry.clientOf` 命中关闭连接不重建 | metadata:连接自愈（T13） |
| A40 | R3 | 一般 | 存活标记初值全真，`isAlive` 死代码 | metadata:存活语义（T13） |
| A41 | R3 | 一般 | `LogCleaner.cleanOnce` 无异常隔离 | metadata:清理隔离（T26） |
| A42 | R3 | 一般 | 元数据/备份/清理测试缺口 | metadata:测试资产（T28） |
| A43 | R3 | 一般 | `syncFromPeers` 失败分支与参数问题 | metadata:反熵告警（T16） |
| A44 | R4 | 严重 | TTL 只认内存游标，删掉慢组积压 | queue-storage:持久化游标保留（T2） |
| A45 | R4 | 严重 | 长度头无上界，损坏段触发 GB 分配 | queue-storage:长度上界（T3） |
| A46 | R4 | 严重 | `Unsupported` BODY 让组永久停摆 | consume:不可评估出口（T17） |
| A47 | R4 | 一般 | 位点段被删时 `scanAfter` 报 0 | queue-storage:扫描可观测（T18） |
| A48 | R4 | 一般 | 记录不可读时静默标记已决 | queue-storage:不可读留痕（T18） |
| A49 | R4 | 一般 | `next` 开流/读中分支语义相反 | queue-storage:恢复一致（T18） |
| A50 | R4 | 一般 | `ack` 不校验是否真的投递过 | consume:已投递校验（T19） |
| A51 | R4 | 一般 | 游标落盘无 fsync | queue-storage:游标 fsync（T6） |
| A52 | R4 | 一般 | `openTopic` 先查后插，并发泄漏 | queue-storage:打开原子（T20） |
| A53 | R4 | 一般 | 详细设计队列章与实现不符 | docs:设计一致性（T29） |
| A54 | R4 | 一般 | `ackTimeout` 无正数校验 | server-runtime:配置校验（T21） |
| A55 | R4 | 一般 | `sweep` 收到已断链订阅 | consume:断链释放（T22） |
| A56 | R4 | 一般 | 队列 12 类场景零覆盖 | queue-storage:测试资产（T28） |
| A57 | R4 | 一般 | 「组内无匹配」正文与场景矛盾 | consume:越过语义（T17） |
| A58 | R5 | 严重 | 无退出钩子，`MQServer.close()` 不可达 | server-runtime:退出钩子（T9） |
| A59 | R5 | 一般 | `close()` 无异常保护，不可重试 | server-runtime:关闭容错（T9） |
| A60 | R5 | 一般 | 断链清理零用例且与重订阅竞态 | server-runtime:断链清理（T22） |
| A61 | R5 | 一般 | `acked` 不含 autoAck，删除后计数残留 | metrics:计数口径（T23） |
| A62 | R5 | 一般 | `stats` 异常伪造 0 且 O(G×N) | metrics:统计真实（T23） |
| A63 | R5 | 一般 | 配置校验不足，非法值静默回落 | server-runtime:配置校验（T21） |
| A64 | R5 | 一般 | `MQConfig.parsePort` 自实现，违反规格 | server-runtime:MQHost 复用（T21） |
| A65 | R5 | 一般 | `listTopics` 把服务端错误报成连接失败 | manager-cli:错误分类（T24） |
| A66 | R5 | 一般 | 备份段无清理，磁盘无界增长 | server-runtime:备份清理（T25） |
| A67 | R5 | 一般 | 服务端/管理器关键分支缺用例 | server-runtime:测试资产（T28） |
| A68 | R5 | 一般 | 启动路径不可测，`dispatch` 无注入点 | server-runtime:可注入装配（T27） |
| A69 | R5 | 一般 | README/详细设计与实现不一致（含命令行限制） | docs:README 一致（T29）；server-runtime:参数顺序（T24） |
| A70 | R6 | 一般 | 断链清理整条 Requirement 零用例 | server-runtime:断链清理（T22/T28） |
| A71 | R6 | 一般 | 客户端关闭与调用并发零用例 | client:生命周期（T28） |
| A72 | R6 | 一般 | 死信组间隔离与字节完整性未断言 | consume:死信测试（T28） |
| A73 | R6 | 一般 | 详细设计消费结果/ACK/`MQMessage` 缺 `queueIndex` | docs:设计一致性（T29） |
| A74 | R6 | 一般 | 详细设计 §5.1 `MQTopicMeta` 缺 `delayingMs` | docs:设计一致性（T29） |
| A75 | R6 | 一般 | `tasks.md` 六项已完成但未勾选 | docs:台账真实（T30） |
