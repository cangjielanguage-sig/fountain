# Design

## 1. 复用方式

M67 与 M36 共用 `SankeyChart`：

- `type` 均为 `sankey`。
- 节点、链接与布局参数完全一致。
- 不引入注册表或工厂，调用方直接导入 `SankeyChart`。

## 2. 回归测试

用文档 M36/M67 示例数据调用 `SankeyChart`，断言返回 SVG 且包含 `sankey-link`。
