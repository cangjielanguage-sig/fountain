# Spec Delta

## ADDED Requirements

### Requirement: 桑基图别名

M67 MUST 复用 `SankeyChart`，不新增实现文件；输入 `type` 为 `sankey` 的文档示例 MUST 生成完整 SVG，并包含桑基流量带。

#### Scenario: 别名绘制

- **WHEN** 调用方使用 M67 文档示例作为 `SankeyChart.draw` 的输入
- **THEN** 返回以 `<svg` 开头的字符串，且包含 `class="sankey-link"`

#### Scenario: 类型一致

- **WHEN** 输入 `type` 为 `sankey`
- **THEN** 不抛出 `UnsupportedChart`
