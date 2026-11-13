## Why

`f_chart` 已覆盖模型评价与解释类图表（PDP、增益、校准、学习曲线），但缺少面向单样本特征贡献的 SHAP 解释图。SHAP 以水平条形展示各特征的正负贡献，是模型可解释性的常用视图。

## What Changes

- 新增 `ShapChart`（`type` 为 `shap`），实现 `Chart` 接口。
- `features: string[]` 声明特征顺序；`series[0].data` 为 `{feature, value}`，按 `|value|` 降序绘制。
- 以 0 为基线水平条：正值红色、负值蓝色，条端标注 SHAP 数值，左侧显示特征名。
- 缺失 `features` 时回退为数据出现顺序；数据为空、字段类型错误或特征重复时报错。

## Capabilities

### New Capabilities

- `chart-rendering`：新增 SHAP 单样本解释图的 JSON 契约与渲染行为。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/ShapChart.cj` 与 `f_chart/src/ShapChart_test.cj`。
- 复用 `ChartConfig`、`ChartFrame`、`BandScale`、`LinearScale`、`ChartSvgKit`。
