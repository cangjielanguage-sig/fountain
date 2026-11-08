# Proposal

## Why

fountain 已经具备 RPC（`f_rpc`）、进程健康数据（`f_health`）、图表（`f_chart`）、邮件（`f_email`）、定时器（`f_ticktock`）与大模型（`f_llm`），但这些能力彼此孤立：仓库里没有一个可以部署到服务器节点、把主机级指标采集起来并通过 RPC 暴露的常驻进程，也没有一个能把多节点指标汇聚成告警、图表和报告的控制端。运维现在只能靠外部脚本 + 人盯屏幕，节点掉线、磁盘写满、网卡丢包这类问题没有统一的发现路径。

同时，仓库没有任何「监控扩展契约」：若每个接入方各自定义探针与告警渠道，k8s、硬件、IM 通知会各长出一套调用方式，且无法在不重新编译主程序的前提下增加监控项。

本变更交付两个模块：`f_probe` 固定扩展契约与注册表，`fprobe` 提供可执行节点代理（agent）与多节点监督端（supervisor）。目标是把「采集 → 传输 → 告警/展示/报告」变成一条可部署、可扩展、可离线测试的链路，而不是一组散落的库调用。

## What Changes

- 新增库模块 `f_probe`（动态库，仅依赖 `f_base`、`f_data`）：
  - `ProbeAgent`：统一监控项契约（`kind` / `host` / `data`）。
  - `AlarmMessageChannel`：告警消息渠道契约（`send` / `receive` / `replyConf`），并增加带默认实现的富消息发送入口，供报告携带 HTML 与附件。
  - `ProbeRegistry` / `AlarmChannelRegistry`：线程安全、拒绝重名的工厂注册表。
  - `ProbeException` 与稳定错误码（`DUPLICATE` / `CONFIG` / `LOAD` / `COLLECT`）。
- 新增可执行模块 `fprobe`（`output-type = "executable"`，`src/main.cj` 分发 `agent` / `supervisor` / `--help`）：
  - `fprobe agent`：默认端口 `12323`，按 `probe_intervalMs` 周期采集 CPU、内存、磁盘、系统、网络、服务可达性、MVC/RPC 健康、IPMI/SNMP/SMART 硬件健康、网络拓扑，用 `f_rpc` 暴露 `collect()`（一次拉回本节点全部探针数据）与 `kinds()`。
  - `fprobe supervisor`：默认控制台 TUI（crossterm + ratatui-cj），`resident` 子命令为无 TUI 常驻模式；按节点用 `f_protocol` CONSUME 拉取快照，维护历史窗口，执行告警规则，经 `AlarmMessageChannel` 发送邮件告警，按 CRON 生成带 SVG 图表的周期报告，可选启用 LLM 智能体分析与「同意/拒绝」回复闭环。
  - `custom/` 动态库扩展：启动时扫描 `.so/.dll/.dylib`，排序后 `PackageInfo.load`，由扩展在加载期向注册表登记探针或渠道；重名拒绝、加载失败默认快速失败。
- 文档与登记：`f_probe/README.md` + `README_en.md`、`fprobe/README.md` + `README_en.md`、两个模块的 `doc/`、`.modules` 的 `[include]`、根 README 模块清单。
- 不修改任何既有模块的公开 API；不新增 fountain 公共 API（采集、拓扑、TUI、告警引擎全部在 `fprobe` 内部实现）。

## Capabilities

### New Capabilities

- `probe-contract`: 扩展契约与注册表（`ProbeAgent`、`AlarmMessageChannel`、两个注册表、异常与错误码、扩展自注册规则）。
- `probe-agent`: 节点代理（启动与配置、周期采集、内置探针数据契约、RPC 服务、自定义动态库加载、非 Linux 明确不支持）。
- `probe-supervisor`: 多节点监督端（CONSUME 拉取、历史窗口、告警规则与去重/恢复、多渠道分发、邮件告警、TUI 与 resident 两种模式）。
- `probe-reporting`: 图表与周期报告（图表类型选择、SVG 生成、CRON 报告、附件、拓扑图）。
- `probe-advisor`: 可选 LLM 智能体（触发、结构化建议、授权回复、白名单动作、去重持久化）。

### Modified Capabilities

<!-- 无：既有模块行为不变，仅新增两个模块并登记。 -->

## Impact

- 代码：新增 `f_probe/src/`（契约、注册表、异常）与 `fprobe/src/`（config、collect、rpc、custom、supervisor、alarm、channel、report、llm、tui）；不触碰既有模块源码。
- 依赖：`fprobe` 直接依赖 `f_base`、`f_config`、`f_data`、`f_log`、`f_ticktock`、`f_httpclient`、`f_process`、`f_net`、`f_protocol`、`f_time`、`f_io`、`f_util`、`f_svg`、`f_concurrent`、`f_health`、`f_rpc`、`f_chart`、`f_email`、`f_llm`、`f_probe`，以及 `crossterm` 与 `ratatui_*` 中心仓包；Linux target 需要 `-ldl`。
- 配置：新增 `probe_*` 命名空间（agent 采集、supervisor 拉取、告警规则、渠道、图表、报告、LLM）。全部为新增键，默认值保证「不配置也能启动 agent；supervisor 默认探测 `localhost:12323`」。
- 测试：`f_probe` 与 `fprobe` 各自 `cjpm test`；所有用例离线（fixture 文件、假传输、临时目录、假终端），不依赖真实 SMTP/IMAP/LLM/IPMI/SNMP/外网。
- 运维：agent 以 systemd 常驻；supervisor 可交互观察或 resident 后台运行。非 Linux 只保证编译与明确的 unsupported 错误。
- 风险：`ratatui-cj` 系列包需在实现期从中心仓实际拉取验证；`f_llm` 在根 `.modules` 中处于 `[detention]`，作为 `fprobe` 直依赖后需要确认可构建；IPMI/SNMP/SMART 依赖外部工具，工具缺失时探针必须降级为「不可用」而不是拖垮整体采集。

## Non-Goals

- 不做 Web UI；TUI + 邮件报告即交付范围。
- 不做告警规则热更新文件监听；规则来自配置项，重启生效。
- 不执行 LLM 生成的自由文本命令；只执行白名单动作（`ack` / `mute` / `report` / `none`）。
- 不实现微信/企业微信/钉钉/飞书渠道；只保留契约与邮件默认实现。
- 不保证非 Linux 平台的指标采集；只保证编译通过并返回明确错误。
