# 控制台模式（TUI）

`fprobe supervisor` 默认进入控制台模式；`fprobe supervisor resident` 不初始化终端。
两种模式共用同一份拉取与告警逻辑，区别只在输出。

## 前置条件

标准输出必须是 TTY。重定向、管道或 CI 环境下启动会直接报错并提示改用：

```bash
fprobe supervisor resident
```

退出码为 `2`，stderr 含 `标准输出不是 TTY`。

## 布局

```
┌ fprobe ─ 节点/页 ─────────────────────────────────────────────┐
│ 节点列表                 │ 当前监控项与关键指标                 │
│ > node-a                 │ cpu  usage 12.4%  iowait 0.3%       │
│   node-b                 │ mem  available 6.1 GiB              │
├──────────────────────────┴────────────────────────────────────┤
│ Sparkline / 告警摘要                                            │
└────────────────────────────────────────────────────────────────┘
```

- 左侧节点列表，`↑`/`↓` 选择节点；
- 右侧上半是指标表，下半是图表区：高度 ≥8 行时用 `fountain::f_chart.tui` 画多行折线/柱状图，
  不足 8 行时回退到单行 sparkline（每页一条）；
- 底部显示当前页说明（如拓扑缺失原因）与告警摘要，两者同时存在时用 ` | ` 连接。

图表类型按页固定：

| 页 | 图表 |
| --- | --- |
| CPU / 内存 / 网络 / 服务 / 健康 | `TuiLineChart`（折线） |
| 磁盘 | `TuiBarChart`（柱状） |
| 拓扑 / 告警 | 不画图（拓扑仍以设备/链路文本行展示） |

横轴固定为类目轴，标签由图表实现自动生成 `1..N`；只画该页第一条序列，避免
`%` 与字节混在同一 Y 轴。图表区最小尺寸为 20 列 × 8 行。

## 按键

| 按键 | 动作 |
| --- | --- |
| `q` | 退出并恢复终端 |
| `r` | 立即刷新一帧 |
| `Tab` | 下一页 |
| `Shift+Tab` | 上一页 |
| `↑` / `↓` | 上一个 / 下一个节点 |
| `a` | 切到告警页 |

退出时按顺序停止拉取线程、关闭节点连接、恢复 raw mode 与光标；`q`、`Ctrl+C`、
`SIGTERM` 走同一套钩子。

## 终端后端

终端相关代码全部在 `fountain::f_tui`：

- `PosixFfi`：`termios` / `ioctl` / `read` / `write` / `isatty` 的唯一出口；
- `RawMode`：进入与恢复 raw mode；
- `AnsiRenderer` + `BufferRenderer`：把 `ratatui_buffer.Buffer` 输出为差分 ANSI；
- `KeyReader`：字节流 → `TerminalKey`。

`fprobe` 只用 ratatui 的 `core` / `style` / `text` / `layout` / `buffer` 五个基础包，
自绘 panel、table、sparkline，不依赖 `crossterm`、`ratatui_backend`、`ratatui_terminal`
或 `ratatui_widgets`。

## 日志

resident 模式下日志是唯一输出，不含 ANSI 控制序列，可直接交给 systemd/journald。
控制台模式下日志写 stderr，避免污染画面。
