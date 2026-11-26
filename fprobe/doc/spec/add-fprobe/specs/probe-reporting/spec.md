# Spec Delta

## Purpose

把历史监控数据转成可读的图表与周期性报告：图表类型可由配置逐指标选择，报告按 CRON 生成 HTML 摘要并以附件形式带上 SVG 图表与拓扑图，通过告警渠道发送给指定收件人。

## ADDED Requirements

### Requirement: 图表类型选择

系统 SHALL 通过 `probe_chart_<metric>` 配置为每个指标选择 `f_chart` 的图表类型（`line` / `area` / `bar` 等）。未配置时 MUST 使用默认：`cpu.usagePercent` → `line`、`memory.usedPercent` → `area`、`disk.usedPercent` → `bar`、`network.rxBps` → `line`、`service.latencyMs` → `line`，其它指标 → `line`。配置了 `f_chart` 不支持的类型时 MUST 记录 WARN 并回退到 `line`，不得中断报告。

#### Scenario: 默认类型

- **WHEN** 未配置 `probe_chart_*`
- **THEN** CPU 用折线、内存用面积、磁盘用柱状、网络与服务用折线

#### Scenario: 自定义类型

- **WHEN** `probe_chart_cpu_usagePercent=bar`
- **THEN** CPU 使用率图以柱状图生成

#### Scenario: 未知类型

- **WHEN** `probe_chart_cpu_usagePercent=sankey`
- **THEN** 记录 WARN，CPU 图仍以折线生成，报告继续

### Requirement: SVG 图表生成

系统 SHALL 用 `f_chart.Chart.draw` 把历史数据生成 SVG。输入 JSON MUST 包含 `type`、`title`、`xAxis.labels` 与 `series[].data`；输出 MUST 是完整 SVG 文档，且包含实际数据点。历史为空时 MUST 跳过该图并记录 INFO，不生成空白图。

#### Scenario: 生成成功

- **WHEN** 某指标有 10 个历史点
- **THEN** 生成的 SVG 非空、可被 `f_svg` 解析，且 `series[0].data` 的点数与历史点数一致

#### Scenario: 无数据

- **WHEN** 节点从未成功拉取
- **THEN** 报告中不含该节点的图表附件，摘要注明「无数据」

### Requirement: 周期报告

系统 SHALL 在 `probe_reportCron` 非空时通过 `f_ticktock.Ticktock.instance.addOrReplaceTask` 注册周期报告任务；`probe_reportCron` 为空时 MUST 不注册任务。报告收件人取 `probe_reportReceivers`，发送渠道取 `probe_reportChannels`（默认 `email`）。

#### Scenario: 关闭报告

- **WHEN** `probe_reportCron` 为空
- **THEN** 不注册报告任务，运行期不产生报告

#### Scenario: CRON 非法

- **WHEN** `probe_reportCron` 不是合法 CRON 表达式
- **THEN** 启动失败并给出非法表达式，不静默关闭报告

#### Scenario: 周期触发

- **WHEN** 报告任务被定时器触发
- **THEN** 生成一次报告并通过配置的渠道发送给全部收件人

### Requirement: 报告内容与附件

报告 MUST 包含 HTML 摘要（节点在线状态、告警统计、关键指标当前值）与每个节点/指标的 SVG 图表附件；附件文件名 MUST 形如 `<node>-<metric>.svg`，并 MUST 在发送后清理临时文件。收件人为空或渠道发送失败时 MUST 记录 ERROR，不影响下一次报告。

#### Scenario: 附件命名

- **WHEN** 节点 `web1` 的 CPU 图被加入报告
- **THEN** 附件名为 `web1-cpu_usagePercent.svg`

#### Scenario: 发送失败

- **WHEN** 邮件服务器拒绝
- **THEN** 日志记录失败原因与报告批次，临时文件仍被清理，下一周期继续尝试

### Requirement: 拓扑图

系统 SHALL 用 `f_svg.SvgBuilder` 把 `topology` 监控项的 `devices` 与 `links` 生成拓扑 SVG，作为报告附件；节点位置 MUST 采用确定性布局（同一输入产生相同坐标），无拓扑数据时 MUST 跳过该附件并注明原因。

#### Scenario: 确定性布局

- **WHEN** 对同一份拓扑数据生成两次 SVG
- **THEN** 两次输出完全一致

#### Scenario: 拓扑缺失

- **WHEN** 所有节点都没有拓扑数据
- **THEN** 报告不含拓扑附件，摘要注明「拓扑不可用」

### Requirement: 报告渠道能力

系统 SHALL 通过 `AlarmMessageChannel.sendRich` 发送报告，使邮件渠道能够同时携带 HTML 正文与多个 SVG 附件；只实现基础方法的渠道 MUST 仍能收到纯文本摘要（附件被忽略），不得因不支持附件而使报告任务失败。

#### Scenario: 富消息

- **WHEN** 使用 `email` 渠道发送报告
- **THEN** 邮件正文为 HTML 摘要，SVG 以 `image/svg+xml` 附件投递

#### Scenario: 基础渠道

- **WHEN** 使用只实现 `send` 的渠道发送报告
- **THEN** 渠道收到纯文本摘要，报告任务正常结束
