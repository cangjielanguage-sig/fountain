## MODIFIED Requirements

### Requirement: 控制台模式

系统 SHALL 默认以控制台模式运行：启动时检查标准输出是否为 TTY，非 TTY MUST 报错并提示使用 `supervisor resident`；TTY 下 MUST 使用 raw mode 与 alternate screen，退出时 MUST 恢复终端状态。

终端能力（TTY 检测、raw mode、alternate screen、终端尺寸、按键读取、`Buffer → ANSI` 渲染）MUST 由 `f_tui` 提供；系统 MUST NOT 依赖 `crossterm`，也 MUST NOT 依赖 `ratatui_backend`、`ratatui_terminal` 或 `ratatui_widgets`。终端初始化或绘制失败 MUST NOT 中断拉取、告警与周期报告。

界面 MUST 包含：顶部状态栏（节点数、告警数、最后刷新时间）、左侧节点列表与状态（在线/离线/告警）、右侧按 `kind` 分页的指标区（CPU/内存/磁盘/网络/服务/健康/拓扑）、底部最近告警滚动区。指标区 MUST 先以表格展示当前值；随后在右侧内容区剩余高度不小于 8 行、宽度不小于 20 列时，MUST 以 `fountain::f_chart.tui` 的多行图表展示 `probe_historyPoints` 窗口，否则 MUST 回退为单行 sparkline。

图表类型 MUST 按页固定选择：CPU、内存、网络、服务、健康使用折线图（`line`），磁盘使用柱状图（`bar`），拓扑与告警页 MUST NOT 绘图。图表 MUST 只使用当前页的第一条指标序列（主指标），避免不同单位共用数值轴；其余指标 MUST 继续以表格当前值呈现。图表单元格 MUST 由 `f_chart.tui` 的逐单元格接口提供，`FprobePainter` 只负责写入 `Buffer`，MUST NOT 解析 ANSI，也 MUST NOT 自行计算 Unicode 显示宽度。

panel、table、sparkline MUST 由 `FprobePainter` 基于 ratatui 基础类型自绘为 `Buffer`，不依赖 `ratatui_widgets`。

按键 MUST 支持：`q` 退出、`Tab`/`Shift+Tab` 切换页、`↑`/`↓` 选择节点、`r` 立即刷新、`a` 打开告警页。

#### Scenario: 非 TTY

- **WHEN** 在重定向输出或 CI 中执行 `fprobe supervisor`
- **THEN** 进程报错退出，提示改用 `fprobe supervisor resident`

#### Scenario: 切换节点与页

- **WHEN** 用户按 `↓` 再按 `Tab`
- **THEN** 选中节点下移一项，右侧页面切到下一个 `kind`，界面在两帧内反映变化

#### Scenario: 多行折线图

- **WHEN** 终端高度使右侧内容区剩余不少于 8 行，当前页为 CPU
- **THEN** 指标表下方出现多行字符画，包含坐标轴字符 `│`、`─`、折线标记 `*` 或数据点 `o`
- **AND** 图表只包含 CPU 页第一条序列（使用率）

#### Scenario: 柱状图

- **WHEN** 当前页为磁盘，且高度满足图表条件
- **THEN** 指标表下方出现柱状字符画，包含柱体 `█`

#### Scenario: 不绘图的页面

- **WHEN** 当前页为拓扑或告警
- **THEN** 指标区不出现坐标轴与 `█`，保持原有文本行

#### Scenario: 高度不足回退

- **WHEN** 终端高度使右侧内容区剩余不足 8 行
- **THEN** 指标表下方使用单行 sparkline（`▁▂▃▄▅▆▇█`），不出现坐标轴
- **AND** 该页所有指标序列都可继续以 sparkline 展示

#### Scenario: 宽度不足回退

- **WHEN** 右侧内容区宽度不足 20 列
- **THEN** 不调用多行图表，回退为 sparkline，且不抛出异常

#### Scenario: 自绘组件

- **WHEN** 渲染右侧指标区
- **THEN** 生成的 `Buffer` 包含边框、表格行列与图表或 sparkline 采样字符，且依赖清单中没有 `ratatui_widgets`

#### Scenario: 退出恢复

- **WHEN** 用户按 `q`
- **THEN** 终端退出 raw mode 与 alternate screen，光标与回显恢复正常

#### Scenario: 终端后端不可用

- **WHEN** `f_tui` 初始化 raw mode 或备用屏失败
- **THEN** 已完成的初始化步骤按逆序回滚，进程报错退出，拉取线程不会在未恢复的终端上继续写输出

#### Scenario: 终端尺寸变化

- **WHEN** 运行期终端被放大或缩小，使图表区可用高度跨过 8 行阈值
- **THEN** 下一帧按新尺寸重新计算，图表与 sparkline 自动切换，不残留上一帧的越界字符
