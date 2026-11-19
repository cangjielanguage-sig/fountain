# Design: f_excel M4

> 依据 `f_excel模块设计.md` 第 6.6（dxfs）与 M4 里程碑。前置：M2 公式引擎。

## 1. 模型

```cangjie
public class ConditionalFormat {
    public let range: String                 // sqref（可多段，空格分隔）
    public let rules: ArrayList<CfRule>
}
public struct CfRule {
    public let type: CfRuleType              // cellIs / expression / colorScale / dataBar / iconSet / top10 / ...
    public let priority: Int64
    public let stopIfTrue: Bool
    public let operator: ?CfOperator
    public let formulas: ArrayList<String>
    public let dxfId: ?Int64
    public let colorScale: ?CfColorScale
    public let dataBar: ?CfDataBar
    public let iconSet: ?CfIconSet
}
```

`CfRuleType` 覆盖 ECMA-376 的 13 种；未知类型保留原文（`CfRuleType.Unknown(raw)`）以便写回。

## 2. 解析与写回

- `WorksheetParser` 在 `</sheetData>` 后解析 `<conditionalFormatting>`，按 `sqref` 展开到
  `Worksheet` 的 `conditionalFormats`；不展开到每个单元格（避免百万格模型）。
- 写回：`SheetXmlWriter.end` 在 `mergeCells` 之后写 `<conditionalFormatting>`，顺序与 priority 一致。
- `dxfs`：`StylePool` 增加差分样式表，`dxfId` 指向它。

## 3. 求值

```
matchedRules(sheet, ref):
  for cf in conditionalFormats:
      if ref in cf.range:
          for rule in cf.rules (按 priority 升序):
              if evaluate(rule, sheet, ref): 记录；if stopIfTrue: break
```

- `cellIs`：把 `formula` 平移到目标格（相对引用），与单元格值比较。
- `expression`：平移公式后交给 `CalcEngine.evaluateFormula`，真值即命中。
- `containsText` / `timePeriod` / `top10` / `duplicateValues`：按 Excel 语义实现。
- `colorScale`：`min/mid/max` 的 `Cfvo`（num/percent/percentile/formula）→ 线性插值 RGB。
- `dataBar`：长度按 `minLength/maxLength` 比例；`iconSet`：按阈值分档。

## 4. `CfFormat`

```cangjie
public struct CfFormat {
    public let fill: ?Color
    public let fontColor: ?Color
    public let bold: Bool
    public let dataBarLength: ?Float64
    public let icon: ?String
}
```

`evaluateCf` 返回 `?CfFormat`；`null` 表示不命中。多个规则命中时由 `matchedRules` 组合（后者覆盖前者）。

## 5. 文件与测试

| 文件 | 职责 |
|---|---|
| `ConditionalFormat.cj` | 模型与 `sqref` 解析 |
| `CfRule.cj` | 13 种规则、`Cfvo`、colorScale/dataBar/iconSet |
| `CfEval.cj` | 求值与 `CfFormat` 组合 |
| `Dxfs.cj` | 差分样式读写 |

测试：13 种规则解析/写回、公式平移、三色刻度插值、dataBar 长度、iconSet 分档、priority/stopIfTrue、
条件格式与合并区域/空值/文本的边界。

## 6. 风险

| 风险 | 应对 |
|---|---|
| Excel 的 `dxf` 继承规则不直观 | 只实现显式字段，未设置字段保持 `None`；不猜默认值 |
| `colorScale` 的 `Cfvo` 公式求值 | 复用 `CalcEngine.evaluateFormula`，失败则退回数值边界 |
| 写回顺序影响 Excel 显示 | 按 priority 升序写，并保留原始 `sqref` 多段顺序 |
