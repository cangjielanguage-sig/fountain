# 告警规则

规则从 `probe_alarmRules` 读取，是一个 JSON 数组；每条形如：

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
    "name": "disk-full",
    "kind": "disk",
    "path": "$.mounts[?(@.path == '/')].usedPercent",
    "op": "gte",
    "threshold": 85,
    "forSeconds": 0,
    "level": "critical"
  },
  {
    "name": "mem-available-low",
    "kind": "memory",
    "path": "$.availablePercent",
    "op": "lt",
    "threshold": 10,
    "forSeconds": 120,
    "level": "warning"
  }
]
```

## 字段

| 字段 | 说明 |
| --- | --- |
| `name` | 规则唯一名，用于去重、静音与恢复 |
| `kind` | 监控项 `kind`，如 `cpu`、`memory`、`disk`、`network`、`service` |
| `path` | 在该监控项 `dataJson` 上求值的 `DataPath`（JSONPath 子集） |
| `op` | `gt` / `gte` / `lt` / `lte` / `eq` / `ne` |
| `threshold` | 比较阈值 |
| `forSeconds` | 条件需持续多少秒才触发；`0` 表示立即触发 |
| `level` | 告警级别，会写进消息与邮件标题 |

`path` 与 `f_data.path.DataPath` 完全一致：`$` 表示根，`.name` 取成员，`[n]` 取下标，
`[?(...)]` 过滤。规则在启动时一次性校验；`op` 未知、字段缺失或 JSON 非法都会以
退出码 `2` 终止，不会静默跳过。

## 状态机

- **触发**：条件首次满足时记录时间；持续 `forSeconds` 后进入 firing 并发送一次告警。
- **冷却**：同一规则在 `probe_alarmCooldownSeconds` 内不重复发送，但状态机继续推进。
- **恢复**：条件不再满足时退出 firing；`probe_alarmRecoverNotify=true` 时发送恢复消息。
- **缺数据**：某监控项连续缺失达到 `probe_missingThreshold`，即使没有显式规则也会告警。
- **静音**：智能体的 `mute` 动作会调用 `AlarmEngine.mute(rule, untilMs)`，静音只影响发送，
  不影响状态机。

## 图表类型

`probe_chart_<kind>` 决定报告与 TUI 使用的图表：

| 监控项 | 默认 |
| --- | --- |
| `cpu` | `line` |
| `memory` | `line` |
| `disk` | `bar` |
| `network` | `line` |
| `topology` | `topology` |
| 其它 | `line` |

## 邮件样式

默认 `email` 渠道把告警渲染成带红色横幅的 HTML，恢复消息使用绿色横幅；正文始终附带
纯文本兜底，便于不支持 HTML 的客户端阅读。多个渠道可以同时启用，单个渠道发送失败
只记录错误，不影响其它渠道。
