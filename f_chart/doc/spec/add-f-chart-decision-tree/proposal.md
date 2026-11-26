# Proposal

## Why

决策树图用节点与分支条件呈现分类规则，叶节点给出预测结果，是解释树模型与规则流程的直观形式。

## What Changes

- 新增 `DecisionTreeChart`，`type` 为 `decision-tree`。
- 顶层 `nodes` 元素为 `{id, label, parent?, condition?, leaf?}`；`edges` 元素为 `{source, target, label?}`。
- 树结构优先由 `edges` 推断，`edges` 缺失时回退到 `parent` 字段。
- 输出 `class="decision-node"` 节点矩形（叶子附加 `decision-leaf`）、`decision-node-label` 文本、`decision-edge` 折线与 `decision-edge-label` 分支标签。
- 新增内部 `decisionTreeLayout`，按叶子槽位分配坐标、父节点居中。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增决策树图需求。

## Impact

- 新增 `src/DecisionTreeChart.cj`、`src/DecisionTreeChart_test.cj`。
