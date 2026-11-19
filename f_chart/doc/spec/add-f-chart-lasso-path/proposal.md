# Proposal

## Why

LASSO 路径图展示各变量系数随正则化强度 `log(lambda)` 的收缩轨迹，可看出变量进入模型的顺序与最终被压缩为零的路径。

## What Changes

- 新增 `LassoPathChart`，`type` 为 `lasso-path`。
- `variables` 为变量名数组；`series[i].data` 元素为 `{x: log(lambda), y: 系数}`。
- 每个系列输出一条 `class="lasso-line"` 路径与 `class="lasso-point"` 数据点。
- 横轴、纵轴范围覆盖全部数据；图例显示变量名。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 LASSO 路径图需求。

## Impact

- 新增 `src/LassoPathChart.cj`、`src/LassoPathChart_test.cj`。
