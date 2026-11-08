# Proposal

## Why

ROC 曲线用假阳性率与真阳性率的取舍关系评价二分类模型，对角线提供随机猜测基准，AUC 则把整条曲线概括为单个可比指标，是模型评估的通用工具。

## What Changes

- 新增 `RocChart`，`type` 为 `roc`。
- `series[0].data` 的元素为 `{x: FPR, y: TPR}`，按 x 升序绘制。
- `diagonal` 默认 true，绘制 (0,0)–(1,1) 虚线基准。
- `auc` 可选，提供时在绘图区左上角标注 `AUC = ...`。
- 曲线 class `roc-line`，点 `roc-point`，对角线 `roc-diagonal`，AUC 标注 `roc-auc`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 ROC 曲线需求。

## Impact

- 新增 `src/RocChart.cj`、`src/RocChart_test.cj`。
- 复用 `LinearScale` / `ChartFrame`。
