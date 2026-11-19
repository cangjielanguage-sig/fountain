# Tasks

## 1. Red

- [x] 1.1 写 `src/BarChart_test.cj`：三根柱、默认/显式尺寸、标签、调色板、网格、标题、四类错误、负值、`null`、确定性、`SvgParser` 可解析、无名单系列隐藏图例
- [x] 1.2 运行 `cjpm test --no-run`，确认因 `BarChart` 不存在而失败

## 2. 公共基础设施

- [x] 2.1 `ChartJson`：带路径的 string/number/bool/array/object 读取，数字拒绝 NaN/Inf
- [x] 2.2 `ChartTheme` + `ChartPadding` + `ChartAxisConfig` + `ChartLegendConfig`
- [x] 2.3 `ChartConfig.parse`：通用信封与默认值
- [x] 2.4 `ChartScale`：LinearScale、BandScale、nice ticks、数值格式化
- [x] 2.5 `ChartSvgKit`：文本、矩形、线、路径助手与属性设置
- [x] 2.6 `ChartFrame`：标题、图例、绘图区、网格、轴、刻度

## 3. Green

- [x] 3.1 `BarChart.draw`：解析 → 布局 → 柱 → 轴/图例 → 输出
- [x] 3.2 运行测试，确认 13+ 用例全绿
- [x] 3.3 重构：去重坐标轴绘制、统一数值格式

## 4. 验证与交付

- [x] 4.1 `cjpm build` + `cjpm test` 全绿
- [x] 4.2 `openspec validate add-f-chart-bar --strict`
- [x] 4.3 同步四件套到 `f_chart/doc/spec/add-f-chart-bar/`
- [x] 4.4 `openspec archive add-f-chart-bar`
- [x] 4.5 分支内提交
