# `fountain::fprobe`

`fprobe` 是 fountain 的服务器监控可执行模块，由两个角色组成：

- **agent**：部署在每个受监控节点，周期采集主机、服务与硬件指标，并通过 `f_rpc`
  一次性暴露给监督端；
- **supervisor**：汇聚多节点数据，负责告警、图表、周期报告和可选的 LLM 分析，
  提供控制台（TUI）与常驻（resident）两种运行模式。

扩展契约 `ProbeAgent` / `AlarmMessageChannel` 声明在
[`fountain::f_probe`](../f_probe/README.md)，本模块只提供默认实现、注册表与进程装配。

## 特性

- **10 类内置监控项**：CPU、内存、磁盘、系统、网络、硬件、MVC 健康、RPC 健康、
  服务可达性、网络拓扑。覆盖计算/IO 瓶颈、inode 耗尽、TCP 重传、硬件传感器等场景。
- **一次 RPC 拉全量**：supervisor 每个 tick 对每个节点只调用一次 `collect()`，
  拿回该节点全部监控项，不为每个指标单独建连。
- **失败隔离**：单个探针失败只让该项带 `error` 上报，其余监控项照常采集；
  外部工具（`ipmitool`、`smartctl`、`snmpbulkwalk`）缺失时自动降级，不影响启动。
- **两种运行模式**：默认 TUI 实时展示节点、指标、图表与告警；`resident` 不初始化终端，
  日志是唯一输出，适合 systemd。
- **告警状态机**：支持持续时长、冷却去重、恢复通知、规则静音，以及节点不可达、
  监控项缺失、探针自身报错三类自动告警。
- **多渠道告警**：默认邮件渠道，告警与恢复邮件使用醒目 HTML 横幅并附带纯文本兜底；
  可通过扩展增加企业微信、飞书、钉钉等渠道。
- **图表与周期报告**：TUI 使用 `f_chart.tui` 画多行折线/柱状图；周期报告通过
  `f_ticktock` CRON 触发，发送内联 SVG 图表与拓扑图的 HTML 摘要。
- **可选 LLM 智能体**：分析采集数据与告警，给出问题定位与处置建议；收到的回复只允许
  触发白名单动作（`ack` / `mute` / `report` / `none`）。
- **动态扩展**：`custom/` 下的动态库在启动时由 `std.reflect.PackageInfo.load` 自动加载，
  可注册新的监控项与告警渠道；重名注册会被拒绝。
- **自带终端后端**：`fountain::f_tui` 直接对接 POSIX `termios`/`ioctl`，不依赖
  `crossterm`、`ratatui_backend` 或 `ratatui_widgets`。
- **配置 fail-fast**：启动期一次性读取并校验全部配置，非法值以退出码 `2` 终止，
  并一次打印所有问题。

## 工作原理

```text
┌──────────────── 被监控节点（fprobe agent）────────────────┐
│  ProbeRunner ──► SnapshotStore ──► ProbeRPC.collect()     │
│    cpu / memory / disk / system / network / hardware ...  │
└───────────────────────────┬───────────────────────────────┘
                            │ f_rpc（TCP，默认 12323）
┌───────────────────────────▼───────────────────────────────┐
│  supervisor：PollLoop ──► NodeStateStore ──► ViewModel/TUI │
│                    │            │                          │
│                    │            ├─► AlarmEngine ─► 渠道     │
│                    │            ├─► NodeHistoryStore        │
│                    │            └─► ReportJob（CRON）       │
│                    └─► 节点不可达 / 缺数据 / 探针报错告警     │
└────────────────────────────────────────────────────────────┘
```

agent 侧每轮采集产出 `ProbeSnapshot`，其中每个监控项是
`ProbeAgentData { kind, host, dataJson, collectedAt, error }`。`collect()` 只读快照，
不会在 RPC 调用里临时触发采集。

## 快速开始

### 构建

```bash
cd fprobe
cjpm build --release
./target/release/bin/main --help
```

产物是 `target/release/bin/main`。`cjpm test` 运行模块测试，`cjpm test src/tui`
只跑某个子包。

### 启动脚本

模块根目录提供 `fprobe.sh`，三个子命令分别预置了对应模式的完整默认配置：

```bash
./fprobe.sh agent          # fprobe agent
./fprobe.sh supervisor     # fprobe supervisor（TUI）
./fprobe.sh resident       # fprobe supervisor resident
```

- 非空默认值写成实际参数；默认未配置或默认关闭的项（可选探针、邮件、报告、LLM）
  保持注释，取消注释即可启用；
- 脚本名之后的参数追加在默认值之后，优先级更高，可覆盖任意默认值：

  ```bash
  ./fprobe.sh agent --probe_port=12324
  ./fprobe.sh resident --probe_nodes='n1@10.0.0.11:12323,n2@10.0.0.12:12323'
  ```

- 可执行文件解析顺序：`$FPROBE_BIN` → `./target/release/bin/main` → `PATH` 中的 `fprobe`。

### 单机试用

supervisor 未指定任何节点时默认访问 `localhost:12323`，因此本机只需要两个终端：

```bash
# 终端 1：节点代理
./fprobe.sh agent

# 终端 2：控制台
./fprobe.sh supervisor
```

### 多节点常驻

```bash
./fprobe.sh resident \
  --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323' \
  --probe_channel_email_smtpHost=smtp.example.com \
  --probe_channel_email_from=fprobe@example.com \
  --probe_channel_email_receivers=ops@example.com \
  --probe_alarmRules='[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
```

## 命令与退出码

| 命令 | 说明 |
| --- | --- |
| `fprobe agent` | 节点代理，默认监听 TCP `12323` |
| `fprobe supervisor` | 控制台模式，要求标准输出是 TTY |
| `fprobe supervisor resident` | 常驻模式，不初始化终端，日志写 stderr |
| `fprobe --help` | 顶层帮助；`fprobe agent --help`、`fprobe supervisor --help` 查看子命令要点 |

| 退出码 | 含义 |
| --- | --- |
| `0` | 正常结束：打印帮助，或 TUI 中 `q` / `Ctrl+C` 退出 |
| `1` | 启动期运行错误，如 RPC 监听失败、邮件渠道初始化异常 |
| `2` | 用法错误、配置校验失败，或控制台模式检测到标准输出不是 TTY |

配置错误会一次列出全部问题，例如端口越界、节点格式错误、规则 JSON 非法、CRON 非法等，
不会只报第一条。

## 监控项

| kind | 关键字段 | 采集来源 / 开关 |
| --- | --- | --- |
| `cpu` | `usagePercent`、`iowaitPercent`、`load1`、`load5`、`load15`、`cores` | `/proc/stat`、`/proc/loadavg` |
| `memory` | `totalBytes`、`usedBytes`、`availableBytes`、`freeBytes`、`cachedBytes`、`buffersBytes`、`swapTotalBytes`、`swapUsedBytes`、`swapFreeBytes` | `/proc/meminfo`；`used = MemTotal - MemAvailable` |
| `disk` | `mounts[]`：`path`、`fs`、`totalBytes`、`usedBytes`、`availableBytes`、`usedPercent`、`inodesTotal`、`inodesUsed`、`inodesUsedPercent`；`devices[]`：`device`、`readBytes`、`writeBytes`、`readIops`、`writeIops`、`awaitMs`、`utilPercent` | `df`、`/proc/diskstats` 差分；`probe_diskExcludeFs` 排除伪文件系统 |
| `system` | `uptimeSeconds`、`processCount`、`tcpConnections` | `/proc/uptime`、`/proc`、`/proc/net/tcp` |
| `network` | `interfaces[]`：`name`、`rxBytes`、`txBytes`、`rxBytesPerSec`、`txBytesPerSec`、`bandwidthPercent`、`dropPercent`、`errorPercent`、`tcpRetransPercent` | `/proc/net/dev`、`/proc/net/snmp` 差分 |
| `hardware` | `ipmi[]`、`snmp[]`、`smart[]`，每项含 `available` 与 `error` | `ipmitool sdr`、SNMP 传感器、`smartctl` |
| `mvc-health` | 健康字段 + `latencyMs`、`statusCode`、`error` | `probe_mvcHealthUrl` 非空时注册 |
| `rpc-health` | 对端 `HealthRPC` 字段 + `latencyMs`、`error` | `probe_rpcHealthTargets` 非空时注册 |
| `service` | `targets[]`：`name`、`url`、`reachable`、`latencyMs`、`statusCode`、`error` | `probe_serviceTargets` 非空时注册 |
| `topology` | `devices[]`、`links[]`、`error` | 始终注册；`probe_snmpDevices` 为空时 `error` 说明已跳过 |

`disk` 的 IO 字段、`network` 的速率与比例来自相邻两次采集的差分，因此 agent 启动后会先
做一次预热，首帧不产生无意义的 0 值。

所有监控项都受 `probe_httpTimeoutMs` / `probe_commandTimeoutMs` 约束；超时不会中断整轮采集。

## 配置

配置只来自两个地方，**命令行优先于环境变量**：

1. 同名环境变量，例如 `probe_port=12324`；
2. 命令行 `--key=value`，或 `-key value`；不带值的 `--probe_ipmiEnabled` 等价于 `true`。

数组用逗号分隔。布尔值接受 `true` / `false`。全部键、默认值与取值范围见
[`doc/configuration.md`](doc/configuration.md)。

### agent 常用配置

```bash
./fprobe.sh agent \
  --probe_port=12323 \
  --probe_hostId=1 \
  --probe_intervalMs=5000 \
  --probe_customDir=./custom \
  --probe_diskExcludeFs=tmpfs,devtmpfs,overlay,squashfs \
  --probe_serviceTargets='web@http://127.0.0.1:8080,db@tcp://127.0.0.1:3306' \
  --probe_mvcHealthUrl=http://127.0.0.1:8080/health \
  --probe_rpcHealthTargets=svc@127.0.0.1:12321 \
  --probe_networkInterfaces=eth0
```

`probe_hostId` 是集群内唯一的协议节点编号，`0` 会被 `f_protocol` 拒绝；多节点部署时
每个 agent 与 supervisor 都应有不同的值。

### supervisor 常用配置

```bash
./fprobe.sh resident \
  --probe_nodes='n1@10.0.0.11:12323,n2@10.0.0.12:12323' \
  --probe_pollIntervalMs=5000 \
  --probe_nodeTimeoutMs=3000 \
  --probe_missingThreshold=2 \
  --probe_historyPoints=60 \
  --probe_alarmCooldownSeconds=300 \
  --probe_alarmRecoverNotify=true \
  --probe_alarmChannels=email \
  --probe_expectKinds=cpu,memory,disk,system,network,hardware,topology
```

`probe_nodes` 格式为 `name@host:port`，名字用于告警去重和 TUI 选择，必须唯一。

## 告警

规则从 `probe_alarmRules` 读取，是一个 JSON 数组：

```json
[
  {
    "name": "cpu-high",
    "kind": "cpu",
    "path": "$.usagePercent",
    "op": "gt",
    "threshold": 85,
    "forSeconds": 60,
    "level": "warning"
  },
  {
    "name": "root-full",
    "kind": "disk",
    "path": "$.mounts[?(@.path == '/')].usedPercent",
    "op": "gte",
    "threshold": 85,
    "forSeconds": 0,
    "level": "critical"
  },
  {
    "name": "root-inode",
    "kind": "disk",
    "path": "$.mounts[?(@.path == '/')].inodesUsedPercent",
    "op": "gte",
    "threshold": 90,
    "forSeconds": 300,
    "level": "warning"
  },
  {
    "name": "web-unhealthy",
    "kind": "service",
    "path": "$.targets[?(@.name == 'web')].statusCode",
    "op": "ne",
    "threshold": 200,
    "forSeconds": 30,
    "level": "critical"
  }
]
```

| 字段 | 说明 |
| --- | --- |
| `name` | 规则唯一名，用于冷却、静音与恢复配对 |
| `kind` | 监控项 `kind` |
| `path` | 在该监控项 `dataJson` 上求值的 `DataPath`（JSONPath 子集） |
| `op` | `gt` / `gte` / `lt` / `lte` / `eq` / `ne` |
| `threshold` | 比较阈值 |
| `forSeconds` | 条件持续多少秒才触发；`0` 表示立即 |
| `level` | 告警级别，写入消息与邮件标题 |

`path` 必须解析为数值；布尔与字符串字段不参与比较。`$` 是根，`.name` 取成员，
`[n]` 取下标，`[?(...)]` 过滤；过滤命中多个值时取最大值。

状态机行为：

- **触发**：条件首次满足时计时，持续 `forSeconds` 后进入 firing 并发送一次；
- **冷却**：同一规则在 `probe_alarmCooldownSeconds` 内不重复发送，状态机继续推进；
- **恢复**：条件不再满足时退出 firing；`probe_alarmRecoverNotify=true` 时发送恢复消息，
  并清除冷却起点，之后再次命中视为新告警；
- **节点不可达**：连续拉取失败达到 `probe_missingThreshold` 即告警；
- **监控项缺失**：`probe_expectKinds` 中列出的 kind 未上报时告警；
- **探针报错**：任何监控项带非空 `error` 时告警（硬件工具缺失也会走这条）；
- **静音**：智能体的 `mute` 动作只抑制发送，不改变状态机。

规则在启动时整体校验，字段缺失、`op` 未知或 JSON 非法都会以退出码 `2` 终止。

更多细节见 [`doc/alarm-rules.md`](doc/alarm-rules.md)。

## 控制台模式

`fprobe supervisor` 要求标准输出是 TTY；重定向或 CI 环境会以退出码 `2` 失败，
并提示改用 `fprobe supervisor resident`。

```text
┌ fprobe ─ 节点/页 ─────────────────────────────────────────────┐
│ 节点列表                 │ 当前监控项与关键指标                 │
│ > node-a                 │ cpu  usage 12.4%  iowait 0.3%       │
│   node-b                 │ mem  available 6.1 GiB              │
├──────────────────────────┴────────────────────────────────────┤
│ 图表 / sparkline / 告警摘要                                     │
└────────────────────────────────────────────────────────────────┘
```

| 按键 | 动作 |
| --- | --- |
| `q` | 退出并恢复终端 |
| `r` | 立即刷新一帧 |
| `Tab` | 下一页（CPU → 内存 → 磁盘 → 网络 → 服务 → 健康 → 拓扑 → 告警） |
| `Shift+Tab` | 上一页 |
| `↑` / `↓` | 上一个 / 下一个节点 |
| `a` | 直接跳到告警页 |

图表区高度 ≥8 行时使用 `fountain::f_chart.tui` 画多行图，不足 8 行回退到单行
sparkline。CPU/内存/网络/服务/健康为折线，磁盘为柱状，拓扑与告警页不画图；
拓扑页改为展示设备与链路文本行。

退出时按顺序停止拉取、关闭连接、恢复 raw mode 与光标；`q`、`Ctrl+C`、`SIGTERM`
走同一套钩子。

`resident` 模式不初始化 TUI，日志不含 ANSI 序列，可直接交给 systemd/journald。
布局与终端实现见 [`doc/tui.md`](doc/tui.md)。

## 图表与周期报告

- **TUI 图表**：按页固定类型，见上一节；只画当前页第一条序列，避免不同单位混轴。
- **周期报告**：`probe_reportCron` 非空时通过 `f_ticktock` 注册任务。CRON 为 6 段：
  `秒 分 时 日 月 周`，例如 `0 0/5 * * * *` 表示每 5 分钟。
- **报告内容**：节点在线状态、告警列表、关键指标图表与拓扑图；SVG 直接内联在 HTML
  正文中，邮件不携带附件；同一份内容同时生成 HTML 与纯文本。
- **收件人**：`probe_reportReceivers` 指定收件人；`probe_reportTmpDir` 已废弃，
  保留以兼容旧配置，报告不再落盘。
- **发送渠道**：复用已启用的告警渠道；单个渠道失败只记录错误，不影响其他渠道。
- **渲染降级**：单张图生成失败时该图位置退化为一行「指标: 当前值」文本，不影响其他图表
  与正文；拓扑缺失或渲染异常显示「拓扑不可用」；指标无历史只记录 INFO 日志，不产生空图。

报告规则：`probe_reportCron` 为空即关闭；CRON 非法会让进程启动失败，而不是静默不注册。
图表类型可用 `probe_chart_<metric>` 覆盖；未配置时由 `ChartSelector` 选择默认类型
（多数指标为 `line`）。

## LLM 智能体

默认关闭，设置 `probe_llmAgent=true` 启用。

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `probe_llmAgent` | `false` | 总开关 |
| `probe_llmName` | `deepseek-flash` | 逻辑模型名 |
| `probe_llmTrigger` | `alarm` | `alarm` / `interval` / `both` |
| `probe_llmIntervalMs` | `300000` | 周期分析间隔 |
| `probe_llmReplyPollMs` | `30000` | 回复轮询间隔 |
| `probe_llmMuteSeconds` | `600` | `mute` 动作的默认静音时长 |
| `probe_replyStateFile` | `./data/reply-state.json` | 已处理回复去重文件 |

### 模型端点与鉴权 KEY

fprobe 没有端点与 KEY 的独立配置项：`probe_llmName` 只是**逻辑模型名**，
平台、地址与密钥来自 `f_llm` 的 `LLMConf`（`LLM.chatByName(probe_llmName, ...)`）。
因此 `probe_llmName` 必须等于某条 `LLMConf` 的 `llmName`。

| `LLMConf` 字段 | 作用 |
| --- | --- |
| `provider` | 平台方言：`deepseek` / `zhipu` / `volcengine` / `aliyun` / `siliconflow`，其它值回退标准 OpenAI |
| `llmName` | 逻辑名，与 `probe_llmName` 对应 |
| `actualLlmName` | 写进报文的 `model`；`probe_llmName` 不参与报文 |
| `url` | base URL，只到版本根；默认追加 `/chat/completions`，可用 `conf.chatPath` 覆盖 |
| `auth` | 原样作为 `Authorization: Bearer <auth>`；只认明文 KEY，不解析 `secretRef:` |
| `weight` / `enabled` | `weight > 0` 且 `enabled = true` 才进候选；同 `llmName` 多条按权重分流 |

内联 JSON（容器或临时验证）：

```bash
./fprobe.sh resident \
  --probe_llmAgent=true \
  --probe_llmName=deepseek-flash \
  --probe_llmTrigger=interval \
  --llm_metaStore=legacy \
  --llm_confSource=env \
  --llm_confs='[{"provider":"deepseek","llmName":"deepseek-flash","actualLlmName":"deepseek-flash","url":"https://api.deepseek.com","auth":"sk-xxx"}]'
```

本地 JSON 文件（推荐，KEY 不出现在 `ps` 里）：

```bash
./fprobe.sh resident --probe_llmAgent=true --llm_metaStore=legacy \
  --llm_confSource=file:/etc/fprobe/llm.json
```

文件内容是对象数组，字段名与 `LLMConf` 成员同名，`conf` 是字符串键值对象：

```json
[
  {
    "provider": "deepseek",
    "llmName": "deepseek-flash",
    "actualLlmName": "deepseek-flash",
    "url": "https://api.deepseek.com",
    "auth": "sk-xxx",
    "temperature": -1,
    "enabled": true,
    "weight": 1
  }
]
```

`llm_confSource` 取 `database`（默认）/ `env` / `file:<path>`，未知值抛错。

### 配置来源：`llm_metaStore` 优先

`f_llm` 1.3 起，`LLMConfs.holder()` 先看 `llm_metaStore`：取值为 `f_store`（默认）/
`postgres` / `mysql` 时，配置一律从元数据存储读（默认 `<可执行文件目录>/data/f_llm-meta`），
`llm_confSource` / `llm_confs` 完全不参与；只有该分支构造失败才回退到 `llm_confSource`。

fprobe 是独立进程，不初始化 bean 容器与 ORM，`database` 源不可用；`f_store` 分支不依赖 bean，
默认能建目录，所以**直接配 `env` / `file` 会被静默忽略**，现象是每次分析只记一行
`no available llm conf for: deepseek-flash, available: []`。
要真正走 `env` / `file`，把 `llm_metaStore` 设为这三个取值之外的占位值（示例中的 `legacy`），
让元数据分支被跳过。

### 排查

| 现象 | 处理 |
| --- | --- |
| 智能体不回复 | 确认 `probe_llmAgent=true`、`probe_llmTrigger` 会触发、以及 `probe_llmName` 与 `LLMConf.llmName` 完全一致 |
| 日志 `llm conf refreshed, ... source: store` | 走的是元数据存储，`llm_confSource` 未生效，按上一节调整 `llm_metaStore` |
| 日志 `llm conf: N record(s) dropped` | 该条配置 `provider` / `actualLlmName` / `url` 有空值，被丢弃 |
| 想快速确认链路 | `--probe_llmTrigger=interval --probe_llmIntervalMs=60000`，失败只记日志、不影响采集与告警；回复闭环另需邮件渠道的 `probe_channel_email_replyAccount` |

`probe_llmMaxTokens` 目前只在 `doc/configuration.md` 与启动脚本注释中出现，当前版本未接线。

### 工作流程

1. 告警触发或周期到达时，把节点状态、告警事件与历史点组装成提示词；
2. 模型返回问题摘要、可能原因与处置建议，作为一条消息通过告警渠道发出；
3. 有权限的账号回复同意/拒绝，`ReplyMonitor` 轮询渠道取回回复；
4. `ActionWhitelist` 只执行 `ack`、`mute`、`report`、`none` 四类动作，
   未知动作返回 `UNSUPPORTED`，不会执行任意命令；
5. 无权限账号会收到固定回复「本账号没有权限指挥智能体」，且不触发任何动作。

可指挥账号由渠道的 `replyConf()` 决定；邮件渠道对应
`probe_channel_email_replyAccount`。LLM 调用失败只记录日志，不影响采集、告警与报告。

## 扩展机制

扩展契约在 `fountain::f_probe`：

- `ProbeAgent`：新增监控项，实现 `kind`、`host`、`data`；
- `AlarmMessageChannel`：新增告警渠道，实现 `send`、`receive`、`replyConf`，
  可选覆盖 `sendRich` 以承载 HTML 与附件。

编译成动态库后放入 `probe_customDir`（默认 `./custom`）。fprobe 启动时：

1. 扫描目录下的动态库；
2. 调用 `std.reflect.PackageInfo.load` 加载；
3. 通过 `ProbeRegistry.registerAgent` / `AlarmChannelRegistry.registerChannel` 注册；
4. 重名注册被拒绝；`probe_customFailFast=true`（默认）时任一扩展加载失败即终止启动，
   设为 `false` 则只记录警告并继续。

自定义渠道可以被 `probe_alarmChannels` 直接启用；自定义监控项会出现在快照里，
TUI 与告警规则按 `kind` 使用。完整示例与注册表 API 见
[`f_probe/README.md`](../f_probe/README.md) 与 [`f_probe/doc/contract.md`](../f_probe/doc/contract.md)。

## RPC 接口

agent 暴露 `fountain::fprobe.rpc.ProbeRPC`：

| 方法 | 返回 | 说明 |
| --- | --- | --- |
| `collect()` | `ProbeSnapshot` | 当前快照，包含全部监控项 |
| `kinds()` | `ProbeKinds` | 已注册的监控项名称 |

supervisor 每个 tick 对每个节点调用一次 `collect()`；`collect()` 只读取
`SnapshotStore`，不触发新采集。线协议、`ServiceMeta` 与最小客户端见
[`doc/rpc.md`](doc/rpc.md)。

## 部署与权限

- agent 监听 TCP `12323`（`probe_port` 可改），supervisor 主动连接各节点；
- `/proc` 指标普通用户即可读取；
- `ipmitool` 需要 root 或 `ipmi` 组，`smartctl` 通常需要 root，SNMP 只需能访问设备；
- 工具或权限缺失不会导致启动失败，对应监控项以 `available=false` / `error` 上报；
- systemd 单元、日志与扩展目录示例见 [`doc/deployment.md`](doc/deployment.md)。

## 目录

```text
fprobe/
  fprobe.sh          启动脚本（三种模式的默认配置）
  src/
    main.cj          子命令分发
    usage.cj         帮助文本
    config/          agent / supervisor 配置与校验
    collect/         采集器（proc、health、hw、net、topology）
    snapshot/        快照与只读仓库
    rpc/             ProbeRPC 服务端与节点定向传输
    supervisor/      拉取循环、节点状态、历史
    alarm/           规则、状态机、缺数据
    channel/         渠道分发与邮件实现
    report/          图表、报告、拓扑渲染、CRON
    llm/             提示词、建议解析、回复监听、动作白名单
    tui/             视图模型、渲染计划、Painter、SupervisorApp
    runtime/         agent / supervisor 进程装配
    custom/          扩展动态库加载
  doc/               配置、告警、TUI、部署、RPC 与 OpenSpec 产物
```

## 文档

| 文档 | 内容 |
| --- | --- |
| [`doc/configuration.md`](doc/configuration.md) | 全部配置项与默认值 |
| [`doc/alarm-rules.md`](doc/alarm-rules.md) | 告警规则与状态机 |
| [`doc/tui.md`](doc/tui.md) | 控制台布局、按键、终端后端 |
| [`doc/deployment.md`](doc/deployment.md) | systemd、权限、扩展目录 |
| [`doc/rpc.md`](doc/rpc.md) | RPC 契约与最小客户端 |
| [`doc/spec/add-fprobe/`](doc/spec/add-fprobe/) | OpenSpec 提案、设计、规格与任务 |
| [`doc/spec/add-fprobe-tui-charts/`](doc/spec/add-fprobe-tui-charts/) | TUI 图表改造的提案、设计与任务 |
| [`doc/spec/inline-report-charts/`](doc/spec/inline-report-charts/) | 报告图表内联的提案、设计与任务 |

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 启动即退出 `2`，stderr 列出多条配置问题 | 按提示修正端口、节点格式、规则 JSON 或 CRON |
| `标准输出不是 TTY` | 改用 `fprobe supervisor resident`，或在前台终端运行 |
| supervisor 一直显示节点离线 | 检查 agent 是否监听 `probe_port`、防火墙与 `probe_nodes` 地址 |
| `hardware` 项 `available=false` | 安装 `ipmitool` / `smartctl`，或补齐权限；不影响其他监控项 |
| 邮件没有发出 | 检查 `probe_channel_email_smtpHost` 与收件人；未配置 smtpHost 时该渠道不构建 |
| 报告没有生成 | `probe_reportCron` 为空表示关闭；非法 CRON 会让启动直接失败 |
| 智能体不回复 | 确认 `probe_llmAgent=true`、`probe_llmTrigger` 会触发；端点与 KEY 见[模型端点与鉴权 KEY](#模型端点与鉴权-key) |
