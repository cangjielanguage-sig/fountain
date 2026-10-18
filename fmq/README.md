# fmq

消息队列服务端（可执行文件）：`fmq server` 与 `fmq manager`。
依赖 `f_mq`（共用 API）、`f_io`（分段日志）、`f_net` / `f_protocol`（节点间通讯）等。

## 启动

```bash
export mqClient_hosts="127.0.0.1:2350,127.0.0.1:2351,127.0.0.1:2352"
export mqServer_port=2350
fmq server
```

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
| `mqClient_hosts` | 必填，节点表 |

`mqServer_backup = N` 时每条消息异步推送给环形后续的 N 个节点；副本只落盘，不参与投递。
`fmq server --help` 打印全部配置项。

## 管理命令

```bash
fmq manager --server=127.0.0.1:2350 registerTopic /order 4
fmq manager --server=127.0.0.1:2350 registerSubscriber /order grp1
fmq manager --server=127.0.0.1:2350 listTopics
fmq manager --server=127.0.0.1:2350 listSubscribeGroups /order
fmq manager --server=127.0.0.1:2350 deleteSubscribeGroup /order grp1
fmq manager --server=127.0.0.1:2350 deleteTopic /order
```

`--server` 可放在子命令前后；缺省读取 `mqServer_port` 并连接 `127.0.0.1:<port>`。
连接失败打印「无法连接消息队列服务」并返回 1。

## 存储布局

```
<可执行文件目录>/metas/
├── assign.meta
├── topics/<topicEsc>.meta
├── groups/<topicEsc>/<groupEsc>.meta
└── offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
<segmentedLogDir>/<topicEsc>/<queueIndex>/log_<seq>.log
<segmentedLogDir>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/log_<seq>.log
<deadMsgDir>/log_<seq>.log
```

主题名使用百分号编码（仅保留 `[A-Za-z0-9._-]`，空串 → `%00`）；元数据写入采用 `.tmp` + rename。

## 已知限制

- at-least-once：未确认消息会被重复投递。
- 无自动故障转移：备份副本只保证落盘，不自动接管。
- manager 与普通客户端共用 TCP 协议，没有强身份隔离（客户端 API 不提供注册入口）。
- BODY 为未注册对象类型且存在非空 filter 的活跃订阅时，发布返回 `FILTER_UNSUPPORTED_BODY`
  且不落盘；空 filter 不需要服务端解码 BODY。
- ACK 按 `(topic, queueIndex, group)` 精确定位游标；队列身份缺失或不属于本机时返回 `ACK_UNKNOWN`。
- 游标指向的段被 TTL 清理后，自动跳到现存最老段并落盘；全部段不可读时返回空，不永久报错。
- 备份副本在关闭阶段允许丢弃：`BackupStore` 关闭后到达的写入静默丢弃，不阻塞发布路径；
  关闭前已成功返回的写入会落盘。

## 测试与端到端

```bash
cd fmq && cjpm build && cjpm test
cd .. && ./scripts/mq_e2e.sh    # 三节点端到端，输出 E2E_OK
```
