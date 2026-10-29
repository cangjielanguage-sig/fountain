# fmq

消息队列服务端（可执行文件）：`fmq server` 与 `fmq manager`。
依赖 `f_mq`（共用 API）、`f_io`（分段日志）、`f_net` / `f_protocol`（节点间通讯）等。

## 构建与启动

```bash
cjpm build          # 产物：target/release/bin/main
cjpm install        # 安装为 $HOME/.cjpm/bin/fmq

export mqClient_hosts="127.0.0.1:2350,127.0.0.1:2351,127.0.0.1:2352"
export mqServer_port=2350
fmq server
```

### 启停脚本（推荐）

仓库内的 `fmq.sh` 把启停与全部配置项收在一处：

```bash
bash fmq.sh start     # 后台启动；pid 写 fmq.pid、输出追加到 fmq.log
bash fmq.sh stop      # SIGTERM，走 f_base 的退出钩子做优雅关闭
bash fmq.sh restart   # 先 stop 再 start
```

脚本里已 `export` 全部配置项：`mqClient_hosts` 必填（保持 export），有默认值的项一律注释掉，
取消注释即覆盖默认值；每项上方都有一行说明。可执行文件按 `$FMQ_BIN` → `PATH` 里的 `fmq` →
本仓库 `target/release/bin/main` 的顺序查找，`metas/` 仍由可执行文件所在目录决定。
默认的 `mqServer_segmentedLogDir` / `mqServer_deadMsgDir` 在 `/var/log/fmq` 下，普通用户请先改成可写目录。

`mqClient_hosts` 既是客户端节点表，也是服务端的集群节点表。服务端按 `mqServer_port` 在表中
匹配本机下标；端口不在表中或重复出现会在启动时报错退出。

`protocol_hostId`（f_protocol 的配置，脚本里已默认导出 `1`）**必填且每台机器唯一**：
`MessageID` 的相等/哈希包含它，配 0 或漏配会在构造 `MessageID` 时抛 `IllegalArgumentException`
（`(pid, tid, 时间戳)` 跨机器会重复，集群维度只能靠它区分）。

配置项（均可用环境变量或命令行参数覆盖）：

| 配置项 | 默认值 |
| --- | --- |
| `mqServer_port` | 2350 |
| `mqServer_ackTimeout` | 10s |
| `mqServer_deadMsgThreshold` | 3 |
| `mqServer_deadMsgTTL` | 72h |
| `mqServer_segmentedLogDir` | `/var/log/fmq/segmentedLogs` |
| `mqServer_deadMsgDir` | `/var/log/fmq/deadMsgs` |
| `mqServer_segmentedLogMaxSize` | 1G |
| `mqServer_segmentedLogTTL` | 72h |
| `mqServer_backup` | 0（不复制） |
| `mqServer_tombstoneTTL` | 7d（删除墓碑保留时长） |
| `mqServer_antiEntropyInterval` | 30s（反熵同步间隔） |
| `mqClient_hosts` | 必填，节点表 |

`mqServer_backup = N` 时每条消息异步推送给环形后续的 N 个节点（不含自身，最多 `节点数-1`）；
副本只落盘，不参与投递。发布路径只入队，独立工作线程按 64 条或 100ms 批量发送，失败批次重入队、
最多重试 3 次后丢弃并记 ERROR；备份队列满或关闭阶段到达的写入会被丢弃并记 WARN，发布路径不阻塞。
备份载荷携带每组真实位点（`cursors`），恢复时据此不回放已确认消息；备份段按位点与 `segmentedLogTTL`
一起参与清理，磁盘不会无界增长。`fmq server --help` 打印全部配置项。

`SIGTERM`/`SIGINT` 会触发优雅关闭：退出钩子调用 `MQServer.close()`，按固定顺序释放
server → 定时器 → 反熵 → 备份 → 清理器 → 消费 → 订阅表 → 备份存储 → `queues.sync` → 队列 →
死信 → 元数据 → 节点连接；单步失败不影响其它步骤，再次调用 `close()` 只重试失败步骤。

## 管理命令

```bash
fmq manager --server=127.0.0.1:2350 registerTopic /order 4
fmq manager --server=127.0.0.1:2350 registerTopic /reminder 2 delaying=1m1s
fmq manager --server=127.0.0.1:2350 registerSubscriber /order grp1
fmq manager --server=127.0.0.1:2350 listTopics
fmq manager --server=127.0.0.1:2350 listSubscribeGroups /order
fmq manager --server=127.0.0.1:2350 deleteSubscribeGroup /order grp1
fmq manager --server=127.0.0.1:2350 deleteTopic /order
fmq manager --server=127.0.0.1:2350 stats /order
fmq manager --server=127.0.0.1:2350 stats
```

`--server` 可放在子命令前后；缺省读取 `mqServer_port` 并连接 `127.0.0.1:<port>`。
连接失败打印「无法连接消息队列服务」并返回 1。`listTopics` 输出 topic、queueNum、delaying
与队列到节点的分配；`listSubscribeGroups` 输出订阅组（空名显示为默认组）。

## 消费语义

- 一个主题有 `queueNum` 个队列，注册时按节点轮转分配；每个队列是一份独立的段日志。
- 订阅组按 `(topic, group)` 注册；每个 `(topic, queueIndex, group)` 维护一个组游标，
  组内订阅共享该游标（未确认记录归属到具体订阅），服务端保证 **at-least-once**。
- `ack` 推进对应队列的 `committed`；超过 `mqServer_ackTimeout` 未确认的消息会重投。
- 投递次数超过 `mqServer_deadMsgThreshold` 的消息进入死信，不再投递；死信段按
  `mqServer_deadMsgTTL` 保留。
- `autoAck` 订阅在投递时自动推进游标，客户端无需 `ack`。
- 延迟消息未到期时不投递、不推进游标，并阻塞该队列的后续消息（保持 FIFO）。
- 组内无匹配订阅时该位置被标记为「不适用」并越过（DEBUG 日志）；组内无人在线时保留未决、不推进。
- BODY 无法评估（未注册对象类型 + 非空 filter）时，该位置被越过并向触发扫描的消费者返回一次
  `FILTER_UNSUPPORTED_BODY`，同一位置不重复报错，组不会停摆。

## 指标与延迟投递

`stats [topic]` 返回**当前节点**的指标，输出列为
`topic / group / queueNum / delaying / backlog / lagMs / delivered / acked / redelivered / deadLettered /
skippedUnreadable / skippedNoMatch / skippedUnsupported`：

- `backlog`：订阅组在该主题本地队列中 `committed` 之后的记录数（含已投递未确认与未到期延迟消息）。
- `lagMs`：backlog 中最早一条消息的发布时长（毫秒）；无积压时为 `0`。
- `delivered` / `acked` / `redelivered` / `deadLettered`：进程启动以来的累计值，重启归零；
  `autoAck` 订阅的投递同样计入 `acked`，删除主题/组时对应计数器清零。
- 扫描失败（段损坏）时返回 `ERROR(INTERNAL)`，不会伪造 `backlog=0`；`lagMs` 负值钳到 0。
- 主题没有订阅组时输出一行 `group` 为空的零值行；`stats` 不带 topic 时汇总本节点持有的主题。

多节点部署时需分别查询各节点；manager 不自动聚合。`backlog` / `lagMs` 在查询时扫描，
超大积压会有一定耗时。

主题注册时可用 `delaying=<DurationString>`（如 `1m1s`、`500ms`，默认 `0s`）设置延迟投递。
消息在「发布时间 + delaying」之前不会投递，也不会推进游标；未到期消息会阻塞该队列的后续消息
（保持 FIFO）。发布时间取自 messageId 末尾的 UTC 时间戳，因此跨重启有效；依赖生产者与
服务端时钟基本同步（NTP）。非标准 messageId 无法解析时间戳时按已到期处理并记 WARN。

## 存储布局

```
<可执行文件目录>/metas/
├── assign.meta
├── revision.meta                       # Lamport 计数器
├── topics/<topicEsc>.meta
├── groups/<topicEsc>/<groupEsc>.meta
├── tombstones/t_<topicEsc>.meta         # 主题墓碑
├── tombstones/g_<topicEsc>_<groupEsc>.meta
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/cursors/<groupEsc>.cursor
<deadMsgDir>/log_<seq>.log
```

主题名使用百分号编码（仅保留 `[A-Za-z0-9._-]`，空串 → `%00`）；元数据与游标写入采用
`.tmp` + `fsync` + rename + 父目录 `fsync`，掉电不会留下空文件。

## 命名与长度限制

| 项目 | 规则 |
| --- | --- |
| 主题 | 非空、以 `/` 开头、不以 `/` 结尾、无空段（`//`）；不含控制字符与 Unicode 空白；否则客户端 `INVALID_TOPIC` |
| 订阅组 | 空串为默认组；≤ `MQGroup.MAX_LENGTH`（255）字节；不含控制字符/Unicode 空白与 `/` `\` `:` `%`；不以 `.` 开头或结尾（`INVALID_GROUP`） |
| tags | 最多 `MQTags.MAX_COUNT`（64）个，每个 1..`MQTags.MAX_LENGTH`（128）字节；不含控制字符/Unicode 空白（`INVALID_TAGS`） |
| 单条记录 | ≤ `min(QueueLog.MAX_RECORD_SIZE, segmentedLogMaxSize - 4)`（即 `QueueLog.effectiveMaxRecord`）；超限在写入前拒绝，不会越界写 |

## 已知限制

- at-least-once：未确认消息会被重复投递。
- 无自动故障转移：备份副本只保证落盘，不自动接管。
- manager 与普通客户端共用 TCP 协议，没有强身份隔离（客户端 API 不提供注册入口）。
- BODY 为未注册对象类型且存在非空 filter 的活跃订阅时，发布返回 `FILTER_UNSUPPORTED_BODY`
  且不落盘；空 filter 不需要服务端解码 BODY。
- ACK 按 `(topic, queueIndex, group)` 精确定位游标；队列身份缺失或不属于本机时返回 `ACK_UNKNOWN`。
- 游标指向的段被 TTL 清理后，自动跳到编号更大的最近现存段并落盘（记 WARN，同一位置按秒限流）；
  全部段不可读时返回空，不永久报错。
- 备份副本在关闭阶段允许丢弃：`BackupStore` 关闭后到达的写入会被丢弃并留痕
  （WARN，同一秒限流一条），不阻塞发布路径；关闭前已成功返回的写入会落盘。
- 段保留边界取「所有已注册组持久化位点的最小值」：从未消费过的组会把边界钉在编号最小的现存段，
  历史段不会回收。需要回收时删除该组，或接受语义变化后下调 `segmentedLogTTL`。
- 删除墓碑默认保留 7d：离线时间超过 `mqServer_tombstoneTTL` 的节点无法通过增量收敛，
  需全量重建元数据（清空该节点 `metas/` 后重启拉快照）。
- 大记录（>4096 字节）的完整支持要求集群内**所有节点**升级到本版本：旧节点收到大记录仍会降级为空，
  发布大消息前先完成服务端滚动升级。
- 客户端已退订 id 集合有界（默认 4096，FIFO 淘汰）：被淘汰的 id 再退订按「未知 id」处理并抛
  `MQServiceException`，不影响服务端状态。

## 测试与端到端

```bash
cd fmq && cjpm build && cjpm test
cd .. && ./scripts/mq_e2e.sh    # 三节点端到端，输出 E2E_OK
```

单机全流程的最小示例见 [`fmqdemo`](../fmqdemo)：发布端/消费端都是 fboot 加载的动态库，
`bash fmqdemo/run-demo.sh` 一条命令完成「起 fmq → 注册主题/订阅组 → 发布 → 消费 ack → 校验」。
