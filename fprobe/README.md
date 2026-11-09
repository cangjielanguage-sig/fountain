# `fountain::fprobe`

服务器监控可执行模块：`fprobe agent` 部署到每个节点，周期采集主机指标并通过 RPC
暴露给监督端；`fprobe supervisor` 汇聚多节点数据，提供告警、图表、周期报告与扩展
渠道。扩展契约见 [`fountain::f_probe`](../f_probe/README.md)。

## 命令

```text
fprobe agent                   # 节点代理，默认监听 12323
fprobe supervisor              # 控制台模式（TUI）
fprobe supervisor resident     # 常驻模式，不初始化终端
fprobe --help                  # 用法
```

## 监控项

| kind | 内容 |
| --- | --- |
| `cpu` | 总使用率、`iowait`、1/5/15 分钟负载、核数 |
| `memory` | `available`、`used`、`swap`、缓存与 buffers |
| `disk` | 各挂载点空间与 inode 使用率；`await` / `util` / IOPS 差分 |
| `system` | 运行时长、进程数、TCP 连接数 |
| `network` | 网卡吞吐、带宽占比、丢包率、错包率、TCP 重传率 |
| `hardware` | IPMI 传感器、SNMP 传感器、磁盘 SMART |
| `mvc-health` | 指定 f_mvc `/health`（配置 `probe_mvcHealthUrl`） |
| `rpc-health` | f_rpc `HealthRPC`（配置 `probe_rpcHealthTargets`） |
| `service` | HTTP/TCP 可达性（配置 `probe_serviceTargets`） |
| `topology` | SNMP IF-MIB / LLDP-MIB 拓扑（配置 `probe_snmpDevices`） |

扩展可以通过 `f_probe.ProbeRegistry.registerAgent` 增加新的 `kind`；重名注册会被拒绝。

## 最小部署

```bash
# 节点
fprobe agent --probe_port=12323

# 监督端（常驻）
fprobe supervisor resident --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323'
```

systemd 单元、权限要求与扩展目录见 [`doc/deployment.md`](doc/deployment.md)。

## 告警与报告

- 规则：`probe_alarmRules`（JSON 数组），见 [`doc/alarm-rules.md`](doc/alarm-rules.md)
- 渠道：默认 `email`，告警邮件带醒目 HTML 横幅与纯文本兜底
- 报告：`probe_reportCron` 非空时按 CRON 周期发送 HTML 摘要与 SVG 图表
- 智能体：`probe_llmAgent=true` 时分析数据并给出建议，只执行白名单动作
  （`ack` / `mute` / `report` / `none`），可指挥账号由渠道的 `replyConf()` 决定

## 配置

全部键、默认值与取值范围见 [`doc/configuration.md`](doc/configuration.md)。配置可用
命令行 `--key=value`、`-key value` 或同名环境变量提供。

## 文档

| 文档 | 内容 |
| --- | --- |
| [`doc/configuration.md`](doc/configuration.md) | 全部配置项 |
| [`doc/alarm-rules.md`](doc/alarm-rules.md) | 告警规则与状态机 |
| [`doc/tui.md`](doc/tui.md) | 控制台布局、按键、终端后端 |
| [`doc/deployment.md`](doc/deployment.md) | systemd、权限、扩展目录 |
| [`doc/rpc.md`](doc/rpc.md) | RPC 契约与最小客户端 |
| [`doc/spec/add-fprobe/`](doc/spec/add-fprobe/) | OpenSpec 提案、设计、规格与任务 |

## 目录

```text
fprobe/src/
  main.cj            子命令分发
  config/            agent / supervisor 配置与校验
  collect/           采集器（proc、health、hw、net、topology）
  snapshot/          快照与只读仓库
  rpc/               ProbeRPC 服务端与节点定向传输
  supervisor/        拉取循环、节点状态、历史
  alarm/             规则、状态机、缺数据
  channel/           渠道分发与邮件实现
  report/            图表、报告、拓扑渲染、CRON
  llm/               提示词、建议解析、回复监听、动作白名单
  tui/               视图模型、渲染计划、Painter、SupervisorApp
  runtime/           agent / supervisor 进程装配
  custom/            扩展动态库加载
```
