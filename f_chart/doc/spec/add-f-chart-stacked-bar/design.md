# Design

## 1. 范围

`resolveStackedRange` 对每个类目分别累加正值与负值，取所有类目的最大正值总和与最小负值总和，再套用 5% 余量与显式 min/max。

## 2. 布局

- 柱宽：`series[0].barWidth ?? bandWidth * 0.6`，所有段共用。
- x：`band.center(i) - barWidth / 2`。
- 正值：`from = scale(cumPos)`、`to = scale(cumPos + v)`，`y = min(from,to)`，`height = abs(to-from)`。
- 负值：`from = scale(cumNeg)`、`to = scale(cumNeg + v)`，`y = min(from,to)`，`height = abs(to-from)`。
- 每段颜色取系列色，class `bar` / `bar bar-negative`。

## 3. 兼容

`Simple` / `Grouped` 分支保持原样，M1/M2 全量回归。
