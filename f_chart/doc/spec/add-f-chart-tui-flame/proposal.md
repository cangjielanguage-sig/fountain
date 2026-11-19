## Why

`f_chart` 已有 M52–M56 的 SVG 火焰图族，但 TUI 子包目前只覆盖 M1–M7。终端/SSH 场景需要把调用栈火焰图直接显示为字符画，并用 ANSI 24 位真彩色区分不同函数与层级。

## What Changes

- 新增 `TuiFlameChart`（`fountain::f_chart.tui`），实现 `fountain::f_chart.Chart`，处理 `type = "flame"`。
- 复用现有 `flame` JSON 契约：`nodes`（`id` / `name` / `parent` / `value`）、`orientation`、`colorBy`、`frameHeight`。
- 每个节点渲染为按值比例的彩色字符块；`colorBy = "name"` 使用主题调色板稳定散列，`colorBy = "value"` 使用热力色阶。
- 支持 `bottom-up`（根在底部）与 `top-down`（根在顶部）；标签在块宽足够时显示，颜色按背景亮度选择黑/白以保证对比度。
- 输出 ANSI 24 位真彩色字符串，并新增 `charts/M052-flame.tui.txt` 样例。
- 不新增第三方依赖，不修改 SVG 火焰图行为。

## Capabilities

### New Capabilities

- `chart-tui-flame`：TUI 火焰图的 JSON 校验、布局、真彩配色与标签规则。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/tui/TuiFlameChart.cj` 与 `TuiFlameChart_test.cj`。
- `f_chart/src/tui/TuiColor.cj` 增加对比色助手；`TuiGallery_test.cj` 增加 M52 样例。
- 更新 `f_chart/README.md`、`f_chart/README_en.md` 与 `f_chart/doc/f_chart模块设计.md`。
