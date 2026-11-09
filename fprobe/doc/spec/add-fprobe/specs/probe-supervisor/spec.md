# Spec Delta

## Purpose

把多个 agent 节点的监控数据汇聚到一个进程：持续拉取、保留短期历史、按规则产生告警、通过可插拔渠道通知，并以 TUI 或常驻模式运行。任何单个节点、单条规则或单个渠道的失败都不能中断整体监督。

## ADDED Requirements

### Requirement: 节点配置与默认值

系统 SHALL 从 `probe_nodes` 读取节点列表，格式为 `name@host:port`，多个节点用逗号分隔；配置为空时 MUST 默认使用 `localhost@127.0.0.1:12323`。

#### Scenario: 默认节点

- **WHEN** 未配置 `probe_nodes` 且本机 `12323` 有 agent
- **THEN** supervisor 以 `localhost` 为节点名拉取数据

#### Scenario: 非法节点项

- **WHEN** 某项缺少 `@` 或端口非数字
- **THEN** 启动失败并指出非法项，不静默跳过

### Requirement: 拉取循环

系统 SHALL 以 `probe_pollIntervalMs`（默认 5000）为周期，对每个节点发起一次 `PROBE` 快照拉取，使用 `f_protocol` CONSUME 命令与 `f_rpc.base.RPCMessage`，一次调用取回该节点全部监控数据。

每次拉取 MUST 有超时（`probe_nodeTimeoutMs`，默认 3000）；节点失败 MUST NOT 影响其它节点；拉取 MUST NOT 因单帧渲染或单条告警发送失败而停止。

#### Scenario: 一次调用取全量

- **WHEN** 某个 tick 到达
- **THEN** 每个节点只收到一次 `collect()` 调用，快照包含该节点全部 `kind`

#### Scenario: 节点超时

- **WHEN** 某节点在超时时间内没有响应
- **THEN** 该节点本次拉取记为失败，其它节点照常更新，tick 不被无限阻塞

#### Scenario: 渲染异常隔离

- **WHEN** TUI 渲染某一帧抛出异常
- **THEN** 渲染错误被记录并重新绘制，拉取线程与告警评估继续运行

### Requirement: 历史窗口

系统 SHALL 为每个节点、每个指标保存最近 `probe_historyPoints`（默认 60）个数值点。历史 MUST 按时间顺序追加，超过容量时丢弃最旧点；历史供 TUI 图表、告警持续时长判断与周期报告使用。

#### Scenario: 环形窗口

- **WHEN** 已保存 60 个点后又追加 1 个点
- **THEN** 历史仍有 60 个点，最旧点被丢弃，最新点位于末尾

#### Scenario: 无数据

- **WHEN** 节点首次拉取失败
- **THEN** 该节点历史为空，不产生伪造的 0 值

### Requirement: 告警规则

系统 SHALL 从 `probe_alarmRules`（JSON 数组）读取规则，每条包含 `name`、`kind`、`path`、`op`、`threshold`、`forSeconds`、`level`。`path` MUST 用 `f_data.path.DataPath` 在该监控项的 `dataJson` 上取值；`op` MUST 支持 `gt`、`gte`、`lt`、`lte`、`eq`、`ne`。

#### Scenario: 阈值命中

- **WHEN** 规则 `cpu.usagePercent > 85` 且当前值为 90，`forSeconds=0`
- **THEN** 产生一条 `critical` 级告警事件，包含节点、规则名、当前值与阈值

#### Scenario: 持续时长

- **WHEN** 规则 `forSeconds=60`，条件只满足了 30 秒
- **THEN** 不产生告警；连续满足达到 60 秒后才产生

#### Scenario: 计数类规则

- **WHEN** `path` 指向数组且聚合出最大值仍超过阈值
- **THEN** 告警按聚合值判定，并在事件中保留实际取值

#### Scenario: 非法规则

- **WHEN** `probe_alarmRules` 不是合法 JSON 数组，或某条 `op` 不受支持
- **THEN** 启动失败并指出第几条规则；不进入「静默忽略所有规则」的状态

### Requirement: 告警去重与恢复

系统 SHALL 在 `probe_alarmCooldownSeconds`（默认 300）内对同一节点、同一规则只发送一次告警；条件恢复时，若 `probe_alarmRecoverNotify` 为真（默认），MUST 发送恢复通知；冷却窗口内恢复后再次命中，MUST 视为新告警。

#### Scenario: 冷却窗口

- **WHEN** 同一规则在同一节点连续两个 tick 都命中
- **THEN** 第二个 tick 不重复发送

#### Scenario: 恢复通知

- **WHEN** 已告警的条件恢复正常且恢复通知开启
- **THEN** 发送一条恢复消息，内容包含节点、规则与恢复时间

### Requirement: 数据缺失告警

系统 SHALL 在以下情况产生「数据不可达」告警：节点连续失败次数达到 `probe_missingThreshold`（默认 2）；某监控项 `error` 非空；`probe_expectKinds` 中列出的 `kind` 未出现在快照中。节点恢复后 MUST 发送恢复通知（受 `probe_alarmRecoverNotify` 控制）。

#### Scenario: 连续失败

- **WHEN** 某节点第一次拉取失败
- **THEN** 只记录失败次数，不告警

#### Scenario: 达到阈值

- **WHEN** 同一节点连续第二次拉取失败
- **THEN** 发送「节点不可达」告警，并在恢复后发送恢复通知

#### Scenario: 缺少期望监控项

- **WHEN** `probe_expectKinds=cpu,disk` 但快照中没有 `disk`
- **THEN** 产生缺项告警，说明缺少的 `kind`

### Requirement: 多渠道分发

系统 SHALL 按 `probe_alarmChannels`（逗号分隔，默认 `email`）把告警事件分发给已注册渠道；每个渠道 MUST 独立执行，单个渠道抛错 MUST 只记录 ERROR 并继续分发其它渠道。告警消息 MUST 同时写入日志（WARN/ERROR）。

#### Scenario: 单渠道失败

- **WHEN** `email` 渠道发送失败，`webhook` 渠道正常
- **THEN** `webhook` 仍收到告警，日志记录 `email` 的失败原因

#### Scenario: 未知渠道

- **WHEN** 配置了未注册的渠道名
- **THEN** 启动校验失败并指出未知渠道

### Requirement: 邮件告警

系统 SHALL 提供注册名为 `email` 的默认渠道，基于 `f_email` 发送告警邮件。告警邮件 HTML MUST 包含醒目的红色/橙色横幅、节点、指标、当前值、阈值与时间表格；恢复邮件 MUST 使用绿色横幅；MUST 同时提供纯文本正文兜底。

#### Scenario: 告警邮件内容

- **WHEN** 发送一条 `critical` 告警
- **THEN** HTML 正文包含红色或橙色横幅、节点名、规则名、当前值、阈值与时间，纯文本正文包含同样的关键信息

#### Scenario: 恢复邮件

- **WHEN** 发送恢复通知
- **THEN** HTML 横幅为绿色，标题明确标注「已恢复」

### Requirement: 控制台模式

系统 SHALL 默认以控制台模式运行：启动时检查标准输出是否为 TTY，非 TTY MUST 报错并提示使用 `supervisor resident`；TTY 下 MUST 使用 raw mode 与 alternate screen，退出时 MUST 恢复终端状态。

终端能力（TTY 检测、raw mode、alternate screen、终端尺寸、按键读取、`Buffer → ANSI` 渲染）MUST 由 `f_tui` 提供；系统 MUST NOT 依赖 `crossterm`，也 MUST NOT 依赖 `ratatui_backend`、`ratatui_terminal` 或 `ratatui_widgets`。终端初始化或绘制失败 MUST NOT 中断拉取、告警与周期报告。

界面 MUST 包含：顶部状态栏（节点数、告警数、最后刷新时间）、左侧节点列表与状态（在线/离线/告警）、右侧按 `kind` 分页的指标区（CPU/内存/磁盘/网络/服务/健康/拓扑）、底部最近告警滚动区。指标区 MUST 以 sparkline 展示 `probe_historyPoints` 窗口，并用表格展示当前值；panel、table、sparkline MUST 由 `FprobePainter` 基于 ratatui 基础类型自绘为 `Buffer`，不依赖 `ratatui_widgets`。

按键 MUST 支持：`q` 退出、`Tab`/`Shift+Tab` 切换页、`↑`/`↓` 选择节点、`r` 立即刷新、`a` 打开告警页。

#### Scenario: 非 TTY

- **WHEN** 在重定向输出或 CI 中执行 `fprobe supervisor`
- **THEN** 进程报错退出，提示改用 `fprobe supervisor resident`

#### Scenario: 切换节点与页

- **WHEN** 用户按 `↓` 再按 `Tab`
- **THEN** 选中节点下移一项，右侧页面切到下一个 `kind`，界面在两帧内反映变化

#### Scenario: 自绘组件

- **WHEN** 渲染右侧指标区
- **THEN** 生成的 `Buffer` 包含边框、表格行列与 sparkline 采样字符，且依赖清单中没有 `ratatui_widgets`

#### Scenario: 退出恢复

- **WHEN** 用户按 `q`
- **THEN** 终端退出 raw mode 与 alternate screen，光标与回显恢复正常

#### Scenario: 终端后端不可用

- **WHEN** `f_tui` 初始化 raw mode 或备用屏失败
- **THEN** 已完成的初始化步骤按逆序回滚，进程报错退出，拉取线程不会在未恢复的终端上继续写输出

### Requirement: 常驻模式

系统 SHALL 提供 `fprobe supervisor resident`：不初始化 TUI，只运行拉取、告警、周期报告与可选智能体；日志是唯一输出；收到 SIGINT/SIGTERM MUST 优雅退出。

#### Scenario: 常驻启动

- **WHEN** 执行 `fprobe supervisor resident`
- **THEN** 进程不申请终端控制，按周期拉取并记录日志，Ctrl+C 后退出码为 0 或约定值且无终端残留

### Requirement: 线程职责分离

系统 SHALL 把拉取与渲染分离：拉取线程负责网络与数据更新，渲染线程只读共享状态并绘制；两者通过共享状态或通道传递快照。渲染 MUST NOT 阻塞拉取超过一个刷新周期。

#### Scenario: 慢渲染

- **WHEN** 终端渲染耗时超过一个拉取周期
- **THEN** 拉取仍按周期进行，最新快照在下一次成功渲染时显示

### Requirement: 拓扑展示

系统 SHALL 在 TUI 的拓扑页展示节点与设备邻接摘要（设备名、端口、对端），数据来自 `topology` 监控项；拓扑数据缺失时 MUST 显示「不可用」与原因，而不是空白崩溃。

#### Scenario: 拓扑不可用

- **WHEN** 节点没有 SNMP 凭据
- **THEN** 拓扑页显示不可用原因，其它页面不受影响
