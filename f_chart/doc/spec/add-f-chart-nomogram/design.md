# Design

## 1. 结构

- 行数 = `variables.size + 2`，按「变量、总分、风险」自上而下排列。
- 行高为绘图区高度除以行数；名称右对齐画在绘图区左侧。

## 2. 变量行

- 水平线横贯绘图区，class `nomogram-variable`。
- 左端标注 `range[0]`，右端标注 `range[1]`，class `nomogram-tick`。
- `points` 保留在解析结果中，用于后续扩展；当前不额外绘制刻度。

## 3. 总分与风险行

- 总分线 class `nomogram-total`，两端标注 `totalPoints` 的上下限。
- 风险刻度位置：`nomogramPosition(points, totalPoints[0], totalPoints[1])`。
- 每个风险点画短竖线与概率标签，class `nomogram-risk-tick`。

## 4. 归一化

`nomogramPosition(value, min, max)` 返回 `(value - min) / (max - min)`，结果夹到 0–1。
