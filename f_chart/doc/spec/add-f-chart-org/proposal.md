# Proposal

## Why

组织图用父子层级和正交连线表达汇报关系、目录结构，是组织结构与树状信息的常用展示形式。

## What Changes

- 新增 `OrgChart`，`type` 为 `org-chart`。
- `nodes` 的元素为 `{id, name, parent}`；根节点 `parent` 为 null 或省略。
- `layout` 取 `vertical`（默认）或 `horizontal`；`nodeWidth` 默认 140、`nodeHeight` 默认 48、`levelGap` 默认 80。
- 节点 class `org-node`，连线 class `org-link`，标签 class `org-label`。
- 新增内部 `orgLayout`，按叶子槽位为节点分配坐标，父节点居中于子节点。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增组织图需求。

## Impact

- 新增 `src/OrgChart.cj`、`src/OrgChart_test.cj`。
- 追加内部 `orgLayout` 便于单测布局不变式。
