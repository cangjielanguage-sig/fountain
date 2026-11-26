# fountain实现思想与应用第十五弹

##### ——监控探针与告警

项目链接：https://gitcode.com/Cangjie-TPC/fountain

监控系统最容易被低估的部分不是采集，而是「**采集失败之后发生什么**」：

> 一个探针超时，整轮数据是否全废？
> 节点失联三次，运维看到的是一条告警还是三十条？

fprobe 把这两个问题当成设计起点。它分成两个可执行角色：被采节点上的 **agent**，和运维台/常驻服务上的 **supervisor**。两者之间只走一条很窄的 RPC 契约，其余全部是「快照」与「告警」的取舍。

| 角色 | 形态 | 职责 |
| --- | --- | --- |
| `fprobe agent` | 被监控节点上的进程 | 周期采集 → 内存快照 → 暴露 `ProbeRPC` |
| `fprobe supervisor` | 运维台 TUI 或 `resident` 常驻 | 拉取各节点快照 → 节点状态/历史 → 告警/报告/智能体 |

```
   agent（每节点一个）                    supervisor（一个）
 ┌──────────────────────┐            ┌───────────────────────────┐
 │ ProbeRunner.tick()   │            │ PollLoop.tick()           │
 │  ├─ cpu/memory/disk  │            │  ├─ 每节点 NodeRpcTransport│
 │  ├─ system/network   │  f_rpc TCP │  ├─ collect()             │
 │  ├─ hardware         │ ◀───────── │  ├─ NodeStateStore        │
 │  ├─ mvc/rpc-health   │  12323     │  ├─ AlarmEngine.evaluate  │
 │  └─ service/topology │            │  ├─ ReportJob（CRON）     │
 │ SnapshotStore（只读）│            │  └─ ProbeAdvisor（可选）  │
 └──────────────────────┘            └───────────────────────────┘
```

---

## 一、采集：一个接口，十种探针

采集侧的契约只有一个：

```cj
public interface ProbeAgent {
    prop kind: String
    prop host: String { get() { "" } }
    prop data: JsonObject
}
```

`kind` 是监控项名字（`cpu`、`memory`、`disk`…），`data` 是该项这一轮的完整 JSON。`host` 默认空串，由 `ProbeRunner` 在打包快照时用节点级 host 兜底——这样单个探针不必关心自己跑在哪台机器上。

`ProbeFactory` 负责把探针装起来。它**恒定注册**七个 kind：`cpu`、`memory`、`disk`、`system`、`network`、`hardware`、`topology`；`mvc-health`、`rpc-health`、`service` 只在对应配置非空时才注册。注册使用 `registerIfAbsent` 语义：**扩展不能覆盖内置探针**，重名直接跳过。

| kind | 采集什么 | 手段 |
| --- | --- | --- |
| `cpu` | `usagePercent`、`iowaitPercent`、`load1/5/15`、`cores` | `/proc/stat` 时间片差分、`/proc/loadavg` |
| `memory` | 总量/已用/可用/缓存/buffers/swap | `/proc/meminfo`，`used = MemTotal - MemAvailable` |
| `disk` | 挂载点容量/inode、设备读写字节/IOPS/await/util | 外部命令 `df -Pk` / `df -Pi` + `/proc/mounts` + `/proc/diskstats` 差分 |
| `system` | uptime、进程数、TCP 连接数 | `/proc/uptime`、`/proc` 目录项、`/proc/net/tcp{,6}` 计数 |
| `network` | 每网卡收发字节/速率、带宽占比、丢包/错误/重传率 | `/proc/net/dev`、`/proc/net/snmp`、`/sys/class/net/<if>/speed` |
| `hardware` | IPMI 传感器、SNMP 传感器、SMART 属性 | `ipmitool sdr`、`snmpbulkwalk`、`smartctl -A -j` |
| `mvc-health` | 目标 HTTP 服务的 `HealthData` + 延迟/状态码 | `f_httpclient` GET `probe_mvcHealthUrl` |
| `rpc-health` | 目标 RPC 服务的 `HealthRPC.health()` + 延迟 | 每目标临时建 `Client<RPCMessage>`，`Message.consume` |
| `service` | 目标可达性/延迟/状态码 | `name@http(s)://…` 或 `name@tcp://host:port` |
| `topology` | 交换机端口与 LLDP 邻居链路 | 每设备两次 `snmpbulkwalk`（IF-MIB + LLDP-MIB） |

这些探针共享几条很朴素的实现原则：

- **只读**。`/proc`、`/sys`、`df`、`ipmitool` 都只读取状态，不修改系统。
- **首帧不可信**。所有差分型指标（CPU 使用率、磁盘 IOPS、网络速率）都需要两个采样点。`ProbeRunner.warmup()` 先让每个探针读一次（结果丢弃），再等 200ms 建立基线，之后才开始发布快照。否则第一帧会出现「CPU 使用率 100%」之类的假值。
- **工具缺失不是事故**。`ipmitool` 需要 root 或 `ipmi` 组、`smartctl` 通常需要 root，缺权限时对应条目以 `available=false` + `error` 上报，采集继续。
- **采样裁剪是显式的**。磁盘只保留 `df` 列出的挂载点，并按 `probe_diskExcludeFs` 排除 `tmpfs`/`overlay` 等伪文件系统；网卡白名单（`probe_networkInterfaces`）之外的接口只更新差分基线、不进输出；CPU 只读 `/proc/stat` 前 9 个时间片。

命令执行有一条硬规则：**参数以数组直传，从不经 shell**。任何参数含空白直接抛 `COLLECT`。SNMP 的 host/community、`/dev/` 设备路径、网卡名还会再过一遍字符白名单——这些值最终会进命令行，不校验就等于把注入面交给配置。

---

## 二、快照：为什么跨 RPC 只传字符串

采集结果先落到 `SnapshotStore`，再由 RPC 暴露。快照的结构是这样的：

```cj
public class ProbeAgentData {
    private var kind: String = ""
    private var host: String = ""
    private var dataJson: String = "{}"
    private var collectedAt: Int64 = 0
    private var error: String = ""
}

public class ProbeSnapshot {
    public let node: String
    public let host: String
    public let timestamp: Int64
    // Array<ProbeAgentData> 序列化后的 JSON 文本
    private var agentsJson: String
    public prop agents: Array<ProbeAgentData> { /* 每次读取重新解析 */ }
}
```

`dataJson` 是字符串可以理解（每个探针的 data 本来就是自由结构的 JSON）。但 `agentsJson` 也是字符串，就值得解释一下：**f_rpc 的二进制编解码对嵌套 DTO 数组会创建默认元素却丢失字段**。与其在协议层修一个通用问题，fprobe 选择把数组压成一段 JSON 文本传输，接收侧再解析。

这是一个「**在边界上退一步**」的取舍：牺牲一点可读性，换跨进程传输的确定性。同样的取舍还体现在两个 API 行为上：

- `collect()` **只读** `SnapshotStore`，绝不触发新采集。supervisor 的拉取节奏和 agent 的采集节奏因此完全解耦：多个 supervisor 同时拉、或者 supervisor 卡住，都不会把 agent 拖慢。
- `SnapshotStore` 只对引用赋值加锁，发布后约定快照不再被修改，读者可以在锁外遍历。写者唯一，读者任意。

---

## 三、上报：定向拉取，而不是注册中心

`ProbeRPC` 的契约窄到只有两个方法：

```cj
@RPCStub
public interface ProbeRPC {
    func collect(): ProbeSnapshot
    func kinds(): ProbeKinds
}
```

agent 侧由 `ProbeRPCImpl`（`@RPCSkeleton`）实现，通过静态 `installedStore` 绑定进程内的快照仓库；监听端口来自 `probe_port`（默认 12323），在 `AgentSettings.apply()` 里被写成 `rpcServer_port`，由 `f_app` 的初始化链启动真正的 RPC 服务。

supervisor 侧没有用全局 `RPCClient`，而是每个节点一条 `NodeRpcTransport`：

```cj
let meta = ServiceMeta("*", "", "fountain::fprobe.rpc.ProbeRPC", method, [],
                       0.0, exactlyVersion: true)
Message.consume<RPCMessage>(once: true, qos: QoS.AtMostOnce, data: RPCMessage(meta, []))
```

原因很直接：**全局客户端会按权重在服务列表里挑一个节点**，而 supervisor 要的是「这台机器，就是这台机器」。定向传输自己维护 `Client`，`checkDuration` 1 秒、用 `Message.ping()` 保活；一旦异常或超时就 `dropClient()`，下次调用重建。

失败语义也只有三种，互不混淆：

| 情况 | 结果 |
| --- | --- |
| `transfer` 抛异常 | `COLLECT` 错误 |
| 返回 `None` | 超时错误 |
| 命令是 `ERROR` | 按错误响应处理 |

**没有重试，没有本地磁盘缓存**。supervisor 的下一个 `pollIntervalMs`（默认 5 秒）就是天然的重试；agent 的快照只在内存里，进程退出即消失。这不是省事，而是避免「一个已经死掉的节点的旧数据被当成新数据」——监控系统里，过期的正确数据比没有数据更危险。

---

## 四、supervisor：把「一次失败」变成「一个状态」

`PollLoop.tick()` 每轮对每个节点 `spawn collectOne`，然后逐个 `future.get()`。失败时保留上一份快照，只累加 `consecutiveFailures`；连续失败达到 `probe_missingThreshold`（默认 2）才把节点判为 `OFFLINE`，并在**恰好跨过阈值的那一次**发一个 `NodeEvent`，恢复时同理。

注意这里的 `NodeEvent` **只写日志**，不直接发告警。真正对外的「节点不可达」告警由 `AlarmEngine.evaluateMissing` 统一产生——否则节点不可达会同时触发「节点状态事件」「缺数据告警」「规则求值失败告警」三条消息，运维一天之内就会把告警静音。

三份状态各自负责一件事：

| 组件 | 保存什么 | 生命周期 |
| --- | --- | --- |
| `NodeStateStore` | 每节点最新快照 + 状态 + 连续失败次数 | 每次 tick 整体替换 `NodeState` |
| `HistoryRing` | 每指标最近 `probe_historyPoints` 个点（默认 60） | 内存环，供 TUI/报告画图 |
| `AlarmEngine.RuleState` | 每条规则每节点的 `since`/`firing`/`lastSentAt` | 进程内存，重启清零 |

---

## 五、告警：没有 pending，只有三个时间戳

`AlarmRule` 的字段少得刻意：`name`、`kind`、`path`、`op`、`threshold`、`forSeconds`、`level`。

```json
{
  "name": "cpu-high",
  "kind": "cpu",
  "path": "$.usagePercent",
  "op": "gt",
  "threshold": 90,
  "forSeconds": 300,
  "level": "warning"
}
```

`path` 是在该监控项 `dataJson` 上求值的 `DataPath`（JSONPath 子集）：`$` 根、`.member`、`[n]`、`[?(...)]` 过滤。列表命中多个数值时**取最大值**——「任一核超过 90%」和「平均超过 90%」是两种完全不同的告警，fprobe 选择前者，因为最大值才是能烧掉 CPU 的那个。非数值（布尔、字符串）直接忽略，不做隐式转换。

状态机没有 `pending` / `resolved` 枚举，只有三个字段：

```cj
private class RuleState {
    var since: ?Int64 = None       // 条件首次满足
    var firing: Bool = false       // 已发送
    var lastSentAt: ?Int64 = None  // 冷却起点
}
```

- **触发**：条件满足时记 `since`；`!firing` 且 `now - since >= forSeconds` 就发 `FIRING`。
- **冷却**：`now - lastSentAt >= probe_alarmCooldownSeconds`（默认 300s）才允许再发；被冷却挡住时 `firing` 保持 `false`，后续 tick 继续尝试。
- **恢复**：条件不再满足时清空 `firing`、`since`，**同时清空 `lastSentAt`**。这一点很关键——恢复后再次命中应当视为一条新告警，而不是被上一次的冷却时间压住。
- **静音**：`mute(rule, untilMs)` 只抑制发送，不改变状态机推进。恢复后状态机仍然是干净的。

规则只在 `NodeStatus.ONLINE` 的节点上求值，评估频率由 `PollLoop` 驱动（默认 5 秒一次），`AlarmEngine` 自己没有定时器。

### 三类「没有规则也会响」的告警

规则是给人配的，但有些问题不需要规则：

| 事件 | 触发条件 | 级别 |
| --- | --- | --- |
| `NODE_UNREACHABLE` | 节点 `OFFLINE` 且连续失败 ≥ 阈值 | `critical` |
| `KIND_MISSING` | `probe_expectKinds` 中的 kind 没上报；或规则引用的 kind 不在快照里 | `warning`（后者沿用规则级别） |
| `PROBE_ERROR` | 任何监控项 `error` 非空 | `warning` |

去重由 `MissingDataTracker` 负责，键分别是 `node|node`、`node|kind|K`、`node|error|K`：**同一件事只告警一次**，条件消失时发一条「已恢复」（`probe_alarmRecoverNotify`，默认 true）。

### 渠道：先校验，再发送，最后才允许失败

`ChannelDispatcher` 在构造期就检查 `probe_alarmChannels` 里的每个名字是否已注册，未知名字直接抛 `CONFIG`——**启动时失败，而不是告警来了才发现渠道没配**。

发送时所有告警先写一条日志（stderr/stdout），再逐个渠道发送；单个渠道异常只记 `logError`，不影响其它渠道。邮件渠道（`email`）的配置项很多，但核心只有三层：

- SMTP：`smtpHost` 必填（为空则整个渠道不构建），`smtpPort` 默认 465，`smtpTls` 默认 true；关闭 TLS 时会显式允许明文认证并关闭「必须加密」。
- IMAP：`imapHost` 非空才构建，用于接收回复，`imapPort` 默认 993。只发告警不需要 IMAP。
- 展示：主题 `"<prefix> <node> <首行>"`，HTML 用红色横幅；标题以「已恢复」开头时换绿色。

HTML 与纯文本共用同一份 `AlarmEvent.format()` 输出，邮件正文按这些行渲染表格——不为了好看造两套模板。

---

## 六、报告与 TUI：同一份历史，两种出口

TUI 是 supervisor 的默认形态，要求标准输出是 TTY；重定向或 CI 环境会以**退出码 2** 拒绝启动，并提示改用 `fprobe supervisor resident`。这是刻意的：往文件里写 ANSI 序列没有任何意义。

| 按键 | 动作 |
| --- | --- |
| `q` | 退出并恢复终端 |
| `r` | 立即刷新一帧 |
| `Tab` / `Shift+Tab` | 下一页 / 上一页（CPU → 内存 → 磁盘 → 网络 → 服务 → 健康 → 拓扑 → 告警） |
| `↑` / `↓` | 上一个 / 下一个节点 |
| `a` | 跳到告警页 |

图表区高度 ≥ 8 行时用 `fountain::f_chart.tui` 画多行图，不足则回退到单行 sparkline。**每页只画第一条序列**：同一页里的指标单位不同，混轴画出来的图看着丰富，实际无法读数。磁盘用柱状，拓扑与告警页不画图。

周期报告走另一条路：`probe_reportCron` 非空时通过 `f_ticktock` 注册任务。CRON 是 6 段 `秒 分 时 日 月 周`（年省略即为 `*`），例如 `0 0/5 * * * *` 表示每 5 分钟。

报告内容是节点在线状态、告警列表、关键指标图与拓扑图；SVG 直接内联在 HTML 正文里，**邮件不带附件**，同一份内容同时生成 HTML 与纯文本。单张图渲染失败时该位置退化为一行「指标: 当前值」，拓扑缺失显示「拓扑不可用」——报告整体不能因为一张图失败而消失。

---

## 七、可选的 LLM 智能体：只给建议，只执行白名单

`probe_llmAgent=true` 时 supervisor 会多一个线程，把「节点状态 + 告警 + 历史点」组装成提示词交给模型，再把模型的结论通过告警渠道发出去。

触发方式有三种（`probe_llmTrigger`）：`alarm`（有新告警时）、`interval`（每 `probe_llmIntervalMs`，默认 5 分钟）、`both`。

这条链路的边界比功能更重要：

- **模型不直接操作系统**。它返回的是一段建议文本，外加一个动作字段。
- **动作只有四种**：`ack`、`mute`、`report`、`none`。`ActionWhitelist` 对未知动作返回 `UNSUPPORTED`，不执行任何命令。
- **回复必须来自可指挥账号**。渠道的 `replyConf()` 给出配置键（邮件渠道是 `probe_channel_email_replyAccount`），`ReplyMonitor` 轮询渠道取回回复；无权限账号收到固定回复「本账号没有权限指挥智能体」。
- **失败只记日志**。LLM 调用失败不影响采集、告警与报告。

还有个容易踩的接线问题：`probe_llmName` 只是**逻辑模型名**，平台地址与密钥来自 f_llm 的 `LLMConf`。而 `LLMConfs.holder()` 会优先从 `llm_metaStore` 读配置——fprobe 是独立进程，不初始化 bean 与 ORM，`database` 源不可用；`f_store` 默认能建目录，于是 `llm_confSource=env/file` 会被**静默忽略**，现象是每次分析只记一行 `no available llm conf for: …, available: []`。要让 `env`/`file` 生效，得把 `llm_metaStore` 设成这三个取值之外的占位值（例如 `legacy`）。

---

## 八、扩展：动态库 + 注册表

扩展契约在 `fountain::f_probe`：

- `ProbeAgent`：新增监控项，实现 `kind`、`host`、`data`；
- `AlarmMessageChannel`：新增告警渠道，实现 `send`、`receive`、`replyConf`，可选覆盖 `sendRich` 承载 HTML 与附件。

编译成动态库放进 `probe_customDir`（默认 `./custom`），启动时按完整路径排序后逐个 `PackageInfo.load`，再通过 `ProbeRegistry.registerAgent` / `AlarmChannelRegistry.registerChannel` 注册。**重名注册被拒绝**——这是「内置优先」的保证，也意味着扩展之间不能互相覆盖。`probe_customFailFast` 默认 true，任一扩展加载失败即终止启动；设为 false 则只记警告。

---

## 九、配置：全部可选，但有几处只读不生效

配置只来自两个地方：环境变量与命令行参数（`--key=value`），`f_config` 合并两者且命令行优先，**没有配置文件源**。

### agent

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_port` | 12323 | 监听端口，经 `rpcServer_port` 生效 |
| `probe_host` | 主机名，空则 `localhost` | 同时作为快照的 `node` 与 `host` |
| `probe_hostId` | 1 | 写入 `protocol_hostId` |
| `probe_intervalMs` | 5000 | 采集周期 |
| `probe_customDir` | `./custom` | 扩展目录 |
| `probe_customFailFast` | true | 扩展加载失败是否终止 |
| `probe_diskExcludeFs` | `tmpfs,devtmpfs,overlay,squashfs` | 排除的伪文件系统 |
| `probe_serviceTargets` | `[]` | `name@http(s)://…` 或 `name@tcp://…` |
| `probe_mvcHealthUrl` | 空 | 必须 http(s) |
| `probe_rpcHealthTargets` | `[]` | `name@host:port`，名字不可重复 |
| `probe_snmpDevices` | `[]` | `name@host@community` |
| `probe_smartDevices` | `[]` | 必须以 `/dev/` 开头 |
| `probe_networkInterfaces` | `[]`（空=全部） | 网卡白名单 |
| `probe_ipmiEnabled` | **false** | 关闭时 `ipmitool` 那一路直接返回空 |
| `probe_httpTimeoutMs` | 2000 | health / service 用 |
| `probe_commandTimeoutMs` | 3000 | ipmitool / snmp / smartctl / topology 用 |

### supervisor

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_nodes` | 空 → `localhost@127.0.0.1:12323` | 节点清单 |
| `probe_pollIntervalMs` | 5000 | 拉取周期 |
| `probe_nodeTimeoutMs` | 3000 | 单节点超时 |
| `probe_missingThreshold` | 2 | 连续失败多少次判离线 |
| `probe_historyPoints` | 60 | 内存历史点数量 |
| `probe_alarmRules` | `[]` | JSON 数组 |
| `probe_alarmCooldownSeconds` | 300 | 负值按 0 |
| `probe_alarmRecoverNotify` | true | 是否发恢复消息 |
| `probe_alarmChannels` | `["email"]` | 已启用渠道 |
| `probe_expectKinds` | `[]` | 期望上报的 kind |
| `probe_reportCron` | 空=关闭 | 6 段 CRON |
| `probe_reportReceivers` | `[]` | 报告收件人 |
| `probe_chart_<metric>` | 见 `ChartSelector` | `line`/`area`/`bar` |
| `probe_channel_email_*` | 见上文 | SMTP/IMAP/主题/收件人/可指挥账号 |
| `probe_llmAgent` 等 | 见上文 | 智能体开关与节奏 |

三处「写了也不生效」需要记住：

1. `probe_reportTmpDir`、`probe_reportChannels` 已废弃，报告不再落盘，渠道复用已启用的告警渠道；
2. `probe_channel_email_receiveLimit` 未接线，`receiveLimit` 恒为 20；
3. `probe_llmMaxTokens` 目前只在文档与启动脚本注释里出现，代码未读取。

另外，`disk` 探针的 `df` 超时是**硬编码 3000ms**，不读 `probe_commandTimeoutMs`——这是当前实现与 README 不一致的地方之一，调参时不要误以为改一个键能管所有命令。

---

## 十、设计取舍与已知限制

1. **采集单线程串行**。一个慢探针会拖慢整轮采集。换来的是所有差分基线只有一个写者，不需要为每个探针设计并发保护。要提速，先拆探针，再谈并发。
2. **失败保留旧数据**。探针抛异常时保留上一次成功的数据与时间戳，只写 `error`。好处是图表不断线；代价是「数据看起来是新的，其实是旧的」——所以 `collectedAt` 与 `error` 必须一起看。
3. **无重试、无磁盘缓存**。supervisor 靠下一轮拉取重试；agent 重启后快照清零。监控数据的价值在于「当下」，不在「历史」。
4. **快照跨进程传字符串**。原因是 f_rpc 嵌套 DTO 数组的字段会丢；在协议层修通用问题不如在边界上退一步。
5. **告警状态在内存**。重启后 `firing` 与冷却全部清零，可能在新进程启动后重复发一次告警。对运维来说是「重复」，对系统来说是「不丢」——宁重勿漏。
6. **命令执行不做 shell，但 `command` 之外的参数校验是白名单**。snmp host/community、`/dev/` 路径、网卡名都有字符限制；新增外部命令时必须自己补校验，因为 `CommandRunner` 只保证「不经过 shell」。
7. **TUI 与 `resident` 是两条路径**。TUI 要求 TTY，`resident` 完全不碰终端；不要在 systemd 里跑 TUI 模式再抱怨没有输出。
8. **退出码有两种**。`settings.validate()` 失败返回 2；启动期 `AlarmRule`/CRON/渠道构造失败抛 `ProbeException(CONFIG)`，被 `main` 的 `catch (Exception)` 接住后返回 **1**。部署脚本若只判 `!=0` 没有影响，若要区分「参数错」与「配置错」，不要照搬「配置错=2」的说法。
9. **`-key value` 形式有坑**。子命令定位规则是「第一个不以 `-` 开头的参数」，所以 `fprobe -probe_port 12324 agent` 会把 `12324` 当成子命令并报未知命令。统一用 `--key=value`。
10. **`IntervalCounter` 是公开 API，但不在生产采集路径上**。各探针自己维护差分；把它当成「采集调度组件」会找错地方。
