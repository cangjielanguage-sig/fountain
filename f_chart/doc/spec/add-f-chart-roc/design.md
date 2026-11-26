# Design

## 1. 数据

- 每个元素解析为 `RocPoint(x, y)`，校验 `0 <= x, y <= 1`。
- 用稳定插入排序按 x 升序排列，保证曲线单调向右。

## 2. 坐标

- x / y 默认范围均为 0–1；显式 `xAxis.min` / `max`、`yAxis.min` / `max` 优先。
- 刻度用 `chartNiceTicks`，坐标用 `LinearScale`。

## 3. 绘制

- 对角线 (0,0)–(1,1)，虚线，class `roc-diagonal`。
- 曲线折线 class `roc-line`，顶点圆 class `roc-point`。
- `auc` 提供时在绘图区左上角写 `AUC = 0.86`，class `roc-auc`。
