# Proposal: 实现 f_excel M4（条件格式语义）

## Why

M1 明确不保留 `<conditionalFormatting>`（写回即丢失）；M2 有公式引擎后才有条件求值的基础。
条件格式是业务表格（预警、标色、进度）的核心表达，M4 把它补成"读得出、写得出、算得对"。

依赖：M2-b/c 的公式引擎与相对引用平移；M2-a 的 `dxfs` 差分样式。

## What Changes

- **M4-a 解析与保留**：`<conditionalFormatting sqref>` / `<cfRule>` 13 种 `CfRuleType` 全量解析，
  `Worksheet.conditionalFormats()` 暴露模型；写回时结构与顺序保持不变（M1 的"整块保留"升级为模型）。
- **M4-b 规则求值**：`cellIs` / `expression` / `containsText` / `timePeriod` / `top10` / `duplicateValues`
  等基于公式/比较的类型；相对引用平移到目标单元格后求值。
- **M4-c 视觉规则求值**：`colorScale` / `dataBar` / `iconSet` 的插值，返回 `CfFormat`（颜色/图标/数据条）。
- **M4-d 优先级与命中**：`priority` 排序、`stopIfTrue`、`matchedRules(sheet, ref)` 返回命中规则列表。
- 公开 API：

```cangjie
public class Worksheet {
    public func conditionalFormats(): ArrayList<ConditionalFormat>
    public func matchedRules(row: Int64, col: Int64): ArrayList<CfMatch>
    public func addConditionalFormat(range: String, rule: CfRule): Unit
}
public func evaluateCf(rule: CfRule, sheet: String, ref: CellRef): ?CfFormat
```

## Impact

- 新增 `ConditionalFormat.cj` / `CfRule.cj` / `CfEval.cj`；改 `Worksheet` / `WorksheetParser` /
  `SheetXmlWriter` / `PackageWriter`（`dxfs`）。
- 读侧从"丢弃"变为"保留 + 可求值"；写侧新增 `<conditionalFormatting>` 与 `dxfs` 输出。
- 测试：13 种规则解析/写回、公式平移、colorScale/dataBar/iconSet 插值、priority/stopIfTrue；
  预计新增 80+ 用例。

## Out of Scope

- 图表/图片条件（Excel 本身不支持）。
- 条件格式的 UI 交互（只提供模型与求值）。
- 跨 sheet 引用在条件格式中的边缘规则（按 Excel 限制处理并文档化）。
