## Why

`f_chart` 已有 M1–M7 的 SVG 实现，但终端/SSH/日志场景需要不依赖图形环境的字符画输出。`ratatui-cj` 及其子包在当前工具链下 `cjpm update` 直接崩溃（`ratatui_text`、`ratatui_buffer`、`ratatui_backend`、`ratatui_widgets`、`ratatui_terminal` 均复现 SIGTRAP），无法作为稳定依赖引入；因此采用零依赖的字符画布 + ANSI 真彩色自绘方案。

## What Changes

- 新增子包 `fountain::f_chart.tui`（目录 `f_chart/src/tui/`），不引入任何第三方依赖。
- 新增 7 个 TUI 图表类，均实现 `fountain::f_chart.Chart`：
  - `TuiBarChart`（`bar`）
  - `TuiGroupedBarChart`（`grouped-bar`）
  - `TuiStackedBarChart`（`stacked-bar`）
  - `TuiPercentStackedBarChart`（`percent-stacked-bar`）
  - `TuiLineChart`（`line`）
  - `TuiScatterChart`（`scatter`）
  - `TuiComboChart`（`combo`，支持柱/折线/散点/分组柱/堆叠柱/百分比堆叠柱任意两两或三三组合）
- 新增内部字符画布 `TuiCanvas`、布局器 `TuiFrame`、柱族渲染器 `TuiBarRenderer` 与通用解析/颜色工具。
- `ChartConfig.parse` 增加可选参数 `defaultWidth` / `defaultHeight`（内部 API，既有调用不变），供 TUI 使用 80×24 的字符画布默认值。
- 输出为 ANSI 24 位真彩色字符串：`draw` 返回按行拼接的字符画，每行以换行符结束，可直接 `print`。
- 复用现有 JSON 契约与 `ChartJson` / `ChartConfig` / `ChartScale` / `ChartTime`，不新增 JSON 字段。

## Capabilities

### New Capabilities

- `chart-tui`：TUI 字符画的尺寸、布局、颜色、CJK 宽度与 7 种图的渲染规则。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/tui/` 下的实现与测试文件。
- 修改 `f_chart/src/ChartConfig.cj`：`parse` 增加带默认值的可选参数。
- 更新 `f_chart/README.md`、`f_chart/README_en.md` 与 `f_chart/doc/f_chart模块设计.md`。
- `f_chart/cjpm.toml` 不新增依赖；SVG 输出路径不受影响。
