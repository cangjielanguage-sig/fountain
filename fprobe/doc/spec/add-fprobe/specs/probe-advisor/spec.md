# Spec Delta

## Purpose

在告警之外增加可选的智能分析：把快照、告警与趋势交给 LLM，产出结构化的问题与建议，经告警渠道发给运维；运维可在邮件里回复同意或拒绝，系统只在白名单动作内执行后续操作。默认关闭，且绝不让模型执行任意命令。

## ADDED Requirements

### Requirement: 开关与触发

系统 SHALL 仅当 `probe_llmAgent=true` 时启用智能体，默认关闭。触发方式由 `probe_llmTrigger` 决定：`alarm`（告警事件触发，默认）、`interval`（按 `probe_llmIntervalMs` 周期触发）、`both`（两者都触发）。模型名由 `probe_llmName` 指定（默认 `deepseek-flash`），调用 `fountain::f_llm.LLM.chatByName`。

#### Scenario: 默认关闭

- **WHEN** 未配置 `probe_llmAgent`
- **THEN** 不构造提示词、不调用 LLM、不轮询回复

#### Scenario: 告警触发

- **WHEN** `probe_llmTrigger=alarm` 且产生一条告警
- **THEN** 对该告警涉及的节点与指标执行一次分析

#### Scenario: 周期触发

- **WHEN** `probe_llmTrigger=interval`
- **THEN** 按 `probe_llmIntervalMs` 对当前全部节点执行一次分析，不与告警事件重复触发

### Requirement: 分析输入

系统 SHALL 把以下内容组织为提示词：受影响节点的快照摘要（在线状态、关键指标当前值）、相关告警事件（规则、级别、当前值、阈值）、最近 N 个历史点（N 取 `probe_historyPoints` 的子集，默认 20）。提示词 MUST 要求模型输出固定 JSON 结构，而不是自由文本。

#### Scenario: 输入完整

- **WHEN** 某个节点有 CPU 告警与 20 个历史点
- **THEN** 提示词包含该节点名、CPU 当前值、阈值、告警级别与历史点序列

### Requirement: 结构化建议

系统 SHALL 把模型输出解析为 `LlmAdvice`，包含 `summary`、`problems[]`、`solutions[]`；每条 `solution` 包含 `title`、`action`、`risk`。解析失败（不是 JSON、字段缺失、类型不符）时 MUST 把整段文本作为 `summary`，**不**丢弃分析结果。

#### Scenario: 正常解析

- **WHEN** 模型返回合法 JSON
- **THEN** `summary`、`problems`、`solutions` 按字段填充

#### Scenario: 解析失败兜底

- **WHEN** 模型返回带 Markdown 代码围栏的 JSON 或纯文本
- **THEN** 剥离围栏后尝试解析；仍失败时 `summary` 为原文，`problems` 与 `solutions` 为空

### Requirement: 建议发送

系统 SHALL 通过已配置的告警渠道发送建议消息，消息 MUST 包含摘要、问题列表、建议列表，以及「回复同意/拒绝」的操作说明和授权账号提示。发送失败 MUST 记录 ERROR，不中断后续分析周期。

#### Scenario: 建议邮件

- **WHEN** 生成了一条包含两个建议的分析
- **THEN** 渠道收到包含摘要、问题、两个建议与回复说明的消息

### Requirement: 回复轮询

系统 SHALL 按 `probe_llmReplyPollMs`（默认 30000）逐渠道调用 `receive()`。收到非空消息时 MUST 解析为 `{"id","from","subject","body"}`；格式非法 MUST 记录 WARN 并跳过。

#### Scenario: 无消息

- **WHEN** 所有渠道 `receive()` 返回空字符串
- **THEN** 本轮不执行任何动作，等待下一轮

#### Scenario: 非法消息

- **WHEN** 渠道返回非 JSON 文本
- **THEN** 记录 WARN，包含渠道名与截断后的原文，不尝试执行

### Requirement: 回复授权

系统 SHALL 通过渠道的 `replyConf()` 取得配置项名，并读取该配置项的账号列表（逗号分隔）。消息 `from` 不在列表内时 MUST 通过同一渠道回复固定文案 `本账号没有权限指挥智能体`，且 MUST NOT 执行任何动作。

#### Scenario: 未授权

- **WHEN** 发件人不在 `probe_channel_email_replyAccount` 中
- **THEN** 回复「本账号没有权限指挥智能体」，不改变告警状态

#### Scenario: 授权

- **WHEN** 发件人在授权列表中
- **THEN** 按消息内容进入同意/拒绝处理

### Requirement: 白名单动作

系统 SHALL 只执行以下动作：`ack`（确认当前告警）、`mute`（临时静音指定规则，时长 `probe_llmMuteSeconds`，默认 600）、`report`（立即生成一次报告）、`none`（仅记录）。模型生成的自由文本、shell 命令或任何未列入白名单的动作 MUST NOT 被执行；非白名单建议仅作为展示内容。

#### Scenario: 同意可执行建议

- **WHEN** 授权用户回复「同意」，且该建议的 `action` 为 `mute`
- **THEN** 对应规则在配置时长内不再发送告警

#### Scenario: 拒绝

- **WHEN** 授权用户回复「拒绝」
- **THEN** 不做任何状态改变，仅记录该决定

#### Scenario: 非白名单动作

- **WHEN** 建议的 `action` 为 `restart-service`
- **THEN** 不执行任何系统操作，回复说明该动作需要人工处理

### Requirement: 回复去重

系统 SHALL 把已处理消息的 `id` 持久化到 `probe_replyStateFile`（默认 `./data/reply-state.json`），重启后 MUST 不再重复处理同一消息；状态文件损坏时 MUST 记录 WARN 并以空集合开始，不阻止启动。状态文件 MUST 限制条目数量（保留最近 1000 条）。

#### Scenario: 重启不重复

- **WHEN** 一条消息已处理并落盘，随后进程重启并再次 `receive()` 到同一 `id`
- **THEN** 不重复回复或执行

#### Scenario: 文件损坏

- **WHEN** 状态文件不是合法 JSON
- **THEN** 记录 WARN，按空集合启动，后续正常写入

### Requirement: LLM 故障隔离

LLM 调用失败、超时或返回空内容时 MUST 记录 ERROR，且 MUST NOT 影响拉取、告警与报告；下一次触发仍正常尝试。

#### Scenario: 模型不可用

- **WHEN** `LLM.chatByName` 抛出异常
- **THEN** 本次分析结束，告警照常发送，周期任务继续
