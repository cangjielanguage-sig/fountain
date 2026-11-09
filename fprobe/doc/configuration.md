# fprobe 配置参考

所有配置项都通过 `f_config` 读取，可用命令行 `--key=value`、`-key value` 或同名环境变量提供。
布尔值接受 `true` / `false`，数组项用逗号分隔。

配置在启动期一次性读取并校验；非法值会让进程以退出码 `2` 结束，并一次打印全部问题。

## agent

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_port` | `12323` | RPC 监听端口，映射到 `rpcServer_port` |
| `probe_hostId` | `1` | 集群内唯一节点编号，映射到 `protocol_hostId`（必须非 0，多节点部署时各不相同） |
| `probe_host` | 主机名 | 节点标识与上报的 host |
| `probe_intervalMs` | `5000` | 采集间隔（毫秒） |
| `probe_customDir` | `./custom` | 扩展动态库目录 |
| `probe_customFailFast` | `true` | 单个扩展加载失败是否终止启动 |
| `probe_diskExcludeFs` | `tmpfs,devtmpfs,overlay,squashfs` | 磁盘统计排除的文件系统 |
| `probe_serviceTargets` | 空 | 服务可达性目标，`name@url` 或 `name@tcp://host:port` |
| `probe_mvcHealthUrl` | 空 | f_mvc `/health` 地址 |
| `probe_rpcHealthTargets` | 空 | f_rpc 健康目标，`name@host:port` |
| `probe_snmpDevices` | 空 | SNMP 设备，`name@host@community` |
| `probe_ipmiEnabled` | `false` | 是否调用 `ipmitool sdr` |
| `probe_smartDevices` | 空 | SMART 磁盘路径，如 `/dev/sda` |
| `probe_networkInterfaces` | 空（全部） | 只统计指定网卡 |
| `probe_httpTimeoutMs` | `2000` | HTTP 探测超时 |
| `probe_commandTimeoutMs` | `3000` | 外部命令超时 |

内置监控项固定为 `cpu`、`memory`、`disk`、`system`、`network`、`hardware`；
`mvc-health`、`rpc-health`、`service`、`topology` 只在对应配置非空时注册。

## supervisor

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_nodes` | `localhost@127.0.0.1:12323` | 节点列表，`name@host:port` |
| `probe_hostId` | `1` | supervisor 自身的协议节点编号，映射到 `protocol_hostId` |
| `probe_pollIntervalMs` | `5000` | 拉取间隔 |
| `probe_nodeTimeoutMs` | `3000` | 单节点单次拉取超时 |
| `probe_missingThreshold` | `2` | 连续失败多少次后发不可达告警 |
| `probe_historyPoints` | `60` | Sparkline 历史点数 |
| `probe_alarmRules` | 空 | 规则 JSON 数组，见 [alarm-rules.md](alarm-rules.md) |
| `probe_alarmCooldownSeconds` | `300` | 同一规则重复告警的去重窗口 |
| `probe_alarmRecoverNotify` | `true` | 恢复时是否发送恢复消息 |
| `probe_alarmChannels` | `email` | 启用的告警渠道名；未注册的名字会让启动失败 |
| `probe_expectKinds` | 空 | 期望每个节点都有的监控项；缺失时告警 |

## 告警渠道

渠道配置统一使用 `probe_channel_<name>_` 前缀；内置渠道为 `email`。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_channel_email_smtpHost` | — | SMTP 主机；为空时不构建邮件渠道 |
| `probe_channel_email_smtpPort` | `465` | SMTP 端口 |
| `probe_channel_email_smtpUser` | 空 | 用户名 |
| `probe_channel_email_smtpPassword` | 空 | 密码 |
| `probe_channel_email_smtpTls` | `true` | 是否使用隐式 TLS |
| `probe_channel_email_from` | 空 | 发件人 |
| `probe_channel_email_receivers` | 空 | 默认收件人 |
| `probe_channel_email_replyAccount` | 空 | 有权指挥智能体的账号 |
| `probe_channel_email_subjectPrefix` | `[fprobe]` | 主题前缀 |
| `probe_channel_email_imapHost` | 空 | IMAP 主机，用于接收回复 |
| `probe_channel_email_imapPort` | `993` | IMAP 端口 |
| `probe_channel_email_receiveLimit` | `20` | 每次收信条数（由 `EmailAlarmChannel` 读取） |

## 图表与报告

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_chart_<metric>` | 见下表 | 每个监控项使用的图表类型 |
| `probe_reportCron` | 空 | 报告 CRON；为空表示关闭 |
| `probe_reportReceivers` | 空 | 报告收件人 |
| `probe_reportChannels` | `email` | 报告渠道 |
| `probe_reportTmpDir` | `./data/fprobe-report` | 图表附件临时目录 |

`probe_chart_*` 的默认值：`cpu`、`memory`、`network` 为 `line`，`disk` 为 `bar`，
`topology` 为 `topology`，未配置的监控项回退到 `line`。

## LLM 智能体

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_llmAgent` | `false` | 是否启用智能体 |
| `probe_llmName` | `deepseek-flash` | 模型名 |
| `probe_llmTrigger` | `alarm` | `alarm` / `interval` / `both` |
| `probe_llmReplyPollMs` | `30000` | 回复轮询间隔 |
| `probe_llmIntervalMs` | `300000` | 周期分析间隔 |
| `probe_llmMaxTokens` | 空 | 生成上限 |
| `probe_llmMuteSeconds` | `600` | `mute` 动作的静音时长 |
| `probe_replyStateFile` | `./data/reply-state.json` | 已处理回复的去重文件 |

## 敏感配置

`probe_channel_email_smtpPassword` 等敏感项由 `f_config` 的 SM4 机制处理；未指定
`sm4Key` 等参数时，密文在编译期嵌入产物，运行期不落盘。
