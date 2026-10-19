# Proposal: add-fmq-message-queue

## Why

仓库已具备消息队列所需的全部底层能力（`f_protocol` 帧与命令、`f_net` 连接与心跳、`f_codec`
自描述编解码、`f_io.SegmentedLog` 分段日志），需求也已在 `.autocode/mq.md` 定稿，并产出了两份
详细设计（`f_mq/doc/详细设计.md`、`fmq/doc/详细设计.md`）与两份 TDD 开发计划。但当前代码里：

- `f_mq` 只有一个占位文件（`f_mq/src/f_mq.cj`），没有任何类型或 API；
- `fmq` 的 `main` 直接打印 `not implemented yet` 并返回 1（`fmq/src/main.cj:24-27`）。

也就是说，业务侧无法发布/订阅消息，运维侧无法注册主题、管理消费组，多节点元数据复制与
持久化队列语义完全没有落地。本次变更把这个能力补齐。

另有一项**必须先做的前置事实**：`fmq/doc/开发计划.md` 的 D0 声称
「`LogPosition.seq`/`offset` 已改为 `public let`」，但本 worktree 的实际代码是
`f_io/src/SegmentedLog.cj:38-46`：

```cangjie
public struct LogPosition {
    let seq: Int64
    let offset: Int64
    public init(seq: Int64, offset: Int64) { ... }
}
```

两个字段是包内可见，`fmq` 侧读 `position.seq` 会直接编译失败（`can not access field 'seq'`）。
MQ 的整条读取链路（`append` 返回位置 → 落盘游标 → `openEntryStream(pos.seq, pos.offset)` 续读）
都依赖这两个字段，因此**本次变更必须把该可见性放宽纳入范围**，并作为第一个任务交付。

## What Changes

本次变更新增两个模块（均为新建，非改造），并修改一个既有模块的可见性：

1. **`f_io`（修改）**：`LogPosition.seq`/`offset` 放宽为 `public let`，仅可见性变化，不改变任何行为。
2. **`f_mq`（新建，动态库 `fountain::f_mq`）**：客户端与客户端/服务端共用 API。
   - `base`：数据模型、四段记录编解码、协议载荷类、命令工厂与解析、过滤器、错误码、主题校验。
   - `client`：`MQClient`（publish / subscribe / unsubscribe / consume / ack / close）、节点连接池、所有权缓存。
   - `exception`：`MQException` / `MQConnectionException` / `MQServiceException`。
   - 门面包 `fountain::f_mq` 重导出常用声明，业务侧只需 `import fountain::f_mq.*`。
3. **`fmq`（新建，可执行文件）**：
   - `fmq server`：多节点消息服务，负责队列存储、消费组游标、重投与死信、元数据全量复制、备份副本。
   - `fmq manager`：六个管理子命令（registerTopic / deleteTopic / registerSubscriber /
     deleteSubscribeGroup / listTopics / listSubscribeGroups）与帮助文本。
   - 配置项 `mqServer_*` 全部落地，启动期校验（`backup < 0` 等）按规格退出。

能力拆分（每项对应一份 delta spec）：

| 能力 | 变更内容 |
| --- | --- |
| `f-io/log-position-visibility` | 位置字段跨模块可读；行为与既有回归不变 |
| `f-mq/protocol` | 记录格式、命令映射、载荷分派、错误码、过滤器、主题校验 |
| `f-mq/client` | 客户端路由、订阅广播、阻塞消费、ack 归属、生命周期与并发 |
| `fmq/queue-storage` | 队列目录布局、分段日志读写、游标落盘、死信存储、TTL 清理 |
| `fmq/consume-semantics` | 组内不重复、at-least-once、乱序 ack、超时重投、死信、autoAck |
| `fmq/metadata-cluster` | 轮转分配、metas 持久化、节点间复制、节点表、备份复制 |
| `fmq/server-runtime` | 配置、启动装配、命令分发、断链清理、重启恢复 |
| `fmq/manager-cli` | 参数解析、六个子命令、输出渲染、连接失败语义 |

**不新增协议命令**：`f_protocol.Command` 的 16 个编号已全部占用，MQ 只复用
`REGISTER` / `DEREGISTER` / `PUBLISH` / `SUBSCRIBE` / `UNSUBSCRIBE` / `CONSUME` / `ACK` / `ERROR` / `RESP`，
同一命令的不同用途用**载荷运行时类型**区分（`MQTopicMeta` / `MQSubscribeGroupMeta` /
`MQInternalMessage` / 记录字节块）。

### verify 修复（2026-10-18）

`opsx:verify` 发现 3 个 critical 与 3 个 warning，用户确认全部修复：

- **C1 队列身份**：`MQConsumeResult` / `MQAckPayload` / `MQMessage` 增加 `queueIndex`；
  客户端投递映射与服务端 ACK 都按 `(queueIndex, segmentedIndex, segmentedOffset)` 精确定位，
  消除多队列同位置 ACK 串台。
- **C2 filter 三态**：`MQMatcher` 区分 `Match / NoMatch / Unsupported`；未注册对象 BODY + 非空 filter
  时，发布路径返回 `FILTER_UNSUPPORTED_BODY` 且不落盘；消费路径不把 `Unsupported` 标记为已决。
- **C3 段失效恢复**：游标指向已删除段时跳到现存最老段并落盘，全部删除时返回空，不再永久 `INTERNAL`。
- **W1**：节点由死转活触发一次 `syncFromPeers`。
- **W2**：节点表任意重复端口都拒绝启动。
- **W3**：`BackupStore` 的 get-or-create 加锁，避免并发创建两个同目录 `QueueLog`。

## Impact

### 受影响规格

全部为新增能力（仓库当前没有任何 `openspec/specs/`）：上表 8 个 capability 的 `ADDED Requirements`。

### 受影响代码

| 路径 | 变更 |
| --- | --- |
| `f_io/src/SegmentedLog.cj` | 两个字段加 `public`（前置） |
| `f_mq/cjpm.toml` / `f_mq/src/**` | 新增约 20 个源文件与对应 `*_test.cj`；verify 修复给 `MQConsumeResult`/`MQAckPayload`/`MQMessage` 加 `queueIndex`，客户端 `deliveries` 键与 ack 路由同步调整 |
| `fmq/cjpm.toml` / `fmq/src/**` | 新增约 20 个源文件与对应 `*_test.cj`；verify 修复 `ConsumeService.ack` 精确定位、`MQMatcher` 三态、`GroupCursor` 段恢复、`NodeRegistry` 重同步回调、`MQConfig` 端口唯一性、`BackupStore` 并发锁 |
| `README.md` / `README_en.md` / `CHANGELOG` / `.modules` | 模块登记与文档 |
| `docs/模块依赖图/**` | 依赖图重新生成（脚本产出） |

### 行为与兼容性

- `f_io` 的改动是纯可见性放宽：不新增/删除/重命名任何声明，既有调用方零影响；
  回归以 `f_io` 全量单测（当前 19 项）为准。
- `f_mq`、`fmq` 为全新模块，不影响现有模块的编译与运行。
- 协议层不新增命令号，不改变 `f_protocol` 的帧格式，因此与既有 `f_rpc` / `f_net` 部署兼容。
- verify 修复给 MQ 自己的 `MQConsumeResult` / `MQAckPayload` / `MQMessage` 增加 `queueIndex` 字段；
  这是 MQ 载荷的字段新增，服务端与客户端需同版本部署（本期无旧客户端兼容要求）。
- 投递语义为 **at-least-once**：未确认消息在重启或超时后会重复投递；`committed` 之前的消息不再投递。
  这是有意的取舍（重复优于丢失），写入文档与用例。

### 不在本次范围

- `fmq manager` 与普通客户端的强隔离（同一 TCP 协议下服务端无法区分；本期靠「客户端 API 不提供
  register/deregister 入口 + 文档约定」）。
- 备份副本的自动故障转移与恢复流程（本期只保证副本落盘）。
- 死信队列的「专门消费者」产品形态（本期提供 `DeadLetterQueue.iterate` 机制）。
- BODY 为任意自定义 `@DataAssist` 类型时的服务端 filter 求值仍不支持（需 `f_codec` 支持未知对象兜底解码）；
  本期对这类记录明确回 `FILTER_UNSUPPORTED_BODY`，不落盘、不误投、不静默丢。
- 客户端元数据查询 API、`consume` 带超时重载、`tryConsume`（规格未要求）。

## 成功判据

1. `cd f_io && cjpm test` 全绿；`cd f_mq && cjpm test` 全绿；`cd fmq && cjpm test` 全绿（或按
   `fmq` 计划备注的测试模块方案等价通过）。
2. 三节点端到端脚本 `scripts/mq_e2e.sh` 输出 `E2E_OK`，覆盖：
   - 100 条消息同组不重复、不丢失；
   - 不 ack 的消息在 `ackTimeout` 后重投，超过阈值进死信；
   - `autoAck=true` 的订阅无需 ack；
   - 停掉一个节点后客户端仍能发布与消费（`NOT_OWNER` 重试路径）。
3. 管理端六个子命令在真实服务上可用，`--help` 文本完整，连接失败返回 1 且提示
   「无法连接消息队列服务」。
4. verify 修复的回归：两队列同位置 ACK 不串台；未注册对象 BODY + 非空 filter 发布返回
   `FILTER_UNSUPPORTED_BODY`；删除 `committed` 所在段后消费恢复；死转活触发重同步；
   任意节点端口重复拒绝启动；备份并发只创建一个 `QueueLog`。
