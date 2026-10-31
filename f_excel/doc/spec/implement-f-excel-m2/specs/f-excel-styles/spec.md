# Spec Delta — f-excel-styles

## ADDED Requirements

### Requirement: `CellStyle` 是值类型

`CellStyle` 与 `Font` / `Fill` / `Border` / `BorderSide` / `Alignment` / `Protection` SHALL 为 `struct` 且字段全 `let`；
SHALL 提供 `withFont` / `withFill` / `withNumberFormat` / `withAlignment` 等返回新值的便捷方法。
`Color` SHALL 支持 `Rgb` / `Theme(theme, tint)` / `Indexed` 三种编码。

#### Scenario: 值语义

- **WHEN** `let a = CellStyle(); let b = a.withFont(Font(bold: true))`
- **THEN** `a.font.bold == false`、`b.font.bold == true`

#### Scenario: 颜色编码

- **WHEN** 读取 `rgb="FFFF0000"` / `theme="4" tint="0.4"` / `indexed="10"`
- **THEN** 分别得到 `Rgb` / `Theme` / `Indexed`，写回后属性一致

### Requirement: 样式完整读写

`styles.xml` SHALL 读写 `numFmts` / `fonts` / `fills` / `borders` / `cellStyleXfs` / `cellXfs` /
`cellStyles` / `dxfs`；`Worksheet.styleOf` / `setStyle` SHALL 以 `s` 索引为桥梁。
`ExcelDocument.setStyle(sheet, ref, style)` SHALL 等价于 `sheet(ref).setStyle(...)`。

#### Scenario: 20 种样式往返

- **WHEN** 写入 20 种覆盖字体/填充/边框/对齐/保护的样式并读回
- **THEN** 每个字段逐项相等

#### Scenario: 命名样式

- **WHEN** 单元格引用 `cellStyles` 的 `Normal`
- **THEN** `CellStyle.namedStyle == Some("Normal")`

### Requirement: 样式池去重与上限

写侧 SHALL 按**值**深比较去重；相同样式只占一个 `cellXfs` 索引。
超过 `SheetWriteOptions.maxCellStyles`（Linux 64000 / 其他 8192）SHALL 抛 `ExcelException`，
消息含当前数量、上限与两种出路。

#### Scenario: 去重

- **WHEN** 1000 个单元格都设置 `Font(bold: true)`
- **THEN** `cellXfs` 只增加 1 条

#### Scenario: 超限

- **WHEN** `maxCellStyles = 2` 且写入第 3 种样式
- **THEN** 抛 `ExcelException`，消息含上限与 `maxCellStyles` 调整建议

### Requirement: 与 M1 调用兼容

`Cell` SHALL 保留 `numberFormat!: ?NumberFormat` 形参；同时给 `style` 与 `numberFormat` 时以 `style` 为准，
并记一条 `NumberFormatNotSupportedInM1` 之外的明确 warning（`StyleOverridesNumberFormat`）。

#### Scenario: 旧写法仍编译

- **WHEN** `Cell(1, CellValue.Number(1.0), numberFormat: Some(Builtin(14)))`
- **THEN** 行为与 M1 一致（日期样式生效）
