# Design

## 1. 排序

`paretoOrder` 对下标按值降序排序（稳定）；柱与标签同步重排。

## 2. 累计

`paretoCumulative` 返回每项累计和占总和的百分比；总和必须大于 0。

## 3. 绘制

- 左轴为计数，柱 class `pareto-bar`。
- 右轴 0–100%，累计折线 class `pareto-line`，顶点圆 class `pareto-point`。
- x 轴复用 `drawXAxis`，类别标签按排序后顺序显示。
