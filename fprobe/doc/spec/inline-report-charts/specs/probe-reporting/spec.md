# Spec Delta

## Purpose

把历史监控数据转成可读的图表与周期性报告：图表类型可由配置逐指标选择，报告按 CRON 生成 HTML 摘要，并把 SVG 图表与拓扑图直接内联到 HTML 正文，通过告警渠道发送给指定收件人。

## MODIFIED Requirements

### Requirement: SVG 图表生成

系统 SHALL 用 `f_chart.Chart.draw` 把历史数据生成 SVG。输入 JSON MUST 包含 `type`、`title`、`xAxis.labels` 与 `series[].data`；输出 MUST 是完整 SVG 文档，且包含实际数据点。历史为空时 MUST 跳过该图并记录 INFO，不生成空白图。生成的 SVG MUST 原样进入报告 HTML，不转义、不 base64；若 SVG 以 `<?xml` 声明开头，嵌入前 MUST 去掉该声明。

#### Scenario: 生成成功

- **WHEN** 某指标有 10 个历史点
- **THEN** 生成的 SVG 非空、可被 `f_svg` 解析，且 `series[0].data` 的点数与历史点数一致
- **AND** 报告 HTML 中包含该 SVG 的 `<svg>` 标记，且不包含 `<?xml` 声明

#### Scenario: 无数据

- **WHEN** 节点从未成功拉取，或某指标没有历史点
- **THEN** 报告中不含该节点的图表，摘要注明「无数据」

#### Scenario: 图表生成失败

- **WHEN** `f_chart` 对某个指标抛出异常
- **THEN** 只记录 WARN，报告省略该图表，其余图表与报告发送不受影响

### Requirement: 拓扑图

系统 SHALL 用 `f_svg.SvgBuilder` 把 `topology` 监控项的 `devices` 与 `links` 生成拓扑 SVG，并作为 HTML 正文「拓扑」小节的一部分内联，MUST NOT 作为附件。拓扑图 MUST 包在 `<div class="fprobe-topology">` 中。节点位置 MUST 采用确定性布局（同一输入产生相同坐标）。无拓扑数据或渲染失败时 MUST NOT 输出拓扑 SVG，并注明「拓扑不可用」。

#### Scenario: 确定性布局

- **WHEN** 对同一份拓扑数据生成两次 SVG
- **THEN** 两次输出完全一致

#### Scenario: 拓扑内联

- **WHEN** 报告中存在可用拓扑数据
- **THEN** HTML 正文的「拓扑」小节包含 `<div class="fprobe-topology">` 与拓扑 `<svg>`
- **AND** 纯文本摘要包含拓扑状态，且不出现 `topology.svg` 等附件文件名

#### Scenario: 拓扑缺失

- **WHEN** 所有节点都没有拓扑数据
- **THEN** HTML 与纯文本摘要均注明「拓扑不可用」，且不输出拓扑 SVG

### Requirement: 报告渠道能力

系统 SHALL 通过 `AlarmMessageChannel.sendRich` 发送报告，使邮件渠道能够投递携带内联 SVG 的 HTML 正文。报告发送时 MUST 传入空附件数组。只实现基础方法的渠道 MUST 仍能收到纯文本摘要（HTML 与附件被忽略），不得因不支持富消息而使报告任务失败。

#### Scenario: 富消息

- **WHEN** 使用 `email` 渠道发送报告
- **THEN** 邮件正文为包含内联 SVG 的 HTML 摘要，且邮件没有附件

#### Scenario: 基础渠道

- **WHEN** 使用只实现 `send` 的渠道发送报告
- **THEN** 渠道收到纯文本摘要，报告任务正常结束

## REMOVED Requirements

### Requirement: 报告内容与附件

**Reason**: 报告改为把 SVG 图表与拓扑图内联到 HTML 正文，不再生成或发送任何附件。

**Migration**: 无需迁移；旧配置 `probe_reportTmpDir` 仍可传入但不再读取。

## ADDED Requirements

### Requirement: 报告内容与内联图表

报告 MUST 包含 HTML 摘要（节点在线状态、告警统计、关键指标当前值）与每个成功生成的 SVG 图表。图表 MUST 以 `<svg>` 标记内联在 HTML 正文中，MUST NOT 作为邮件附件。每个指标图表 MUST 包在独立的 `<div class="fprobe-chart">` 中，并以 `<h4>` 给出「节点 + 指标 + 当前值/单位」标题。发送时附件数组 MUST 为空，报告 MUST NOT 依赖临时目录或发送后清理文件。收件人为空或渠道发送失败时 MUST 记录 ERROR，不影响下一次报告。

#### Scenario: 内联图表

- **WHEN** 节点 `web1` 的 CPU 指标成功生成图表
- **THEN** HTML 正文包含 `<div class="fprobe-chart">` 与该图的 `<svg>`
- **AND** 该 div 的 `<h4>` 同时包含节点名、指标名与当前值/单位

#### Scenario: 无附件

- **WHEN** 报告通过任意渠道发送
- **THEN** 传给渠道的附件数组为空
- **AND** 报告正文包含全部成功生成的 `<svg>`，且不出现附件文件名

#### Scenario: 发送失败

- **WHEN** 邮件服务器拒绝
- **THEN** 日志记录失败原因与报告批次，下一周期继续尝试
- **AND** 不执行任何临时文件清理动作（因为不存在临时文件）
