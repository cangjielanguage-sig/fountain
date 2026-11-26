# Design

## 1. 数据

- 每个元素解析为 `PrPoint(x, y)`，校验 `0 <= x, y <= 1`。
- 稳定插入排序按 x 升序，保证召回率单调向右。

## 2. 坐标

- x / y 默认范围均为 0–1；显式轴范围优先。
- 基线 y 值为 `baseline`，横贯绘图区。

## 3. 绘制

- 曲线折线 class `pr-line`，顶点圆 class `pr-point`。
- 基线 class `pr-baseline`，虚线。
- `ap` 提供时在绘图区左上角写 `AP = 0.72`，class `pr-ap`。
