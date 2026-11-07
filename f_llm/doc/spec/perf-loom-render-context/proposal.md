# Proposal

## Why

R6 的两条热点都在 loom 执行器内部，且**不涉及存储层**、可以就地量化：

- `LoomHostApi.render` 每次替换是「对每个已产出步骤做一次全串 `replace`」，复杂度 `O(步数 × 模板长度)`；
  而且整段替换在**全局锁内**执行——渲染是纯字符串工作，却把 `bind/unbind/取快照` 都堵在后面；
- `LoomContextLog.turns` 单次执行内**没有条数上限**：长流程（几十步 × 每步多轮）会让快照一直涨到执行结束，
  提炼提示词也跟着变长。

## What Changes

- `render`：锁内只拷贝 `values` 快照，替换移到锁外；替换算法改成**单遍扫描**（`{...}` 就地识别并查表），
  复杂度降到 `O(模板长度)`，未命中的占位符仍原样保留（语义不变）。
- `LoomContextLog`：新增 `MAX_TURNS = 200`，超过后丢最旧的（保留最近 200 轮）。
- 补 4 条用例：多步替换 + 未知占位符保留、`{start.output}` 空数据保留、JSON 里嵌模板不被外层花括号误导、快照上限。

## Capabilities

### Modified Capabilities
- `loom-flow`：模板替换与执行期快照的复杂度与上限显式化。

## Impact

- 代码：`src/loom/LoomHostApi.cj`、`src/loom/LoomContextLog.cj`。
- 行为：`render` 的**输出完全不变**（含嵌套花括号与未知占位符）；`turns` 在 200 轮后只保留最近部分。
- 测试：新增 4 条；全量基线 650。
