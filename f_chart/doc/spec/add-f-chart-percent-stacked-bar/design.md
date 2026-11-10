# Design

## 1. 归一化

`total = Σ abs(value)`；段比例 `abs(value) / total * 100`。`total <= 0` 时跳过该类目。

## 2. 布局

- 与 M3 相同：所有段共享 `stackedBarX` 的 x 与同一柱宽。
- 段从 0 向上累计：`from = scale(cum)`，`to = scale(cum + portion)`。
- 段颜色取系列色，class 固定 `bar`（构成图不区分正负方向）。

## 3. 轴

`resolvePercentRange` 返回 `[0, 100]`，除非显式 `min` / `max`；仍校验 `min < max`。
