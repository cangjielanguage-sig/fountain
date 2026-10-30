# Spec Delta — f-excel-rich-values

## ADDED Requirements

### Requirement: `TimeSpan` 值

`CellValue` SHALL 增加 `TimeSpan(Duration)`；`numFmtId` 为 46/47 或自定义格式含 `[h]`/`[m]`/`[s]` 时，
读侧 SHALL 返回 `TimeSpan`（不再返回 `Date` + 告警）。`TimeSpan` SHALL 支持超过 24 小时（100h / 1000h）。

#### Scenario: 超过 24 小时

- **WHEN** 单元格值 `4.5`、格式 `[h]:mm`
- **THEN** 返回 `TimeSpan(108 小时)`

#### Scenario: 写回

- **WHEN** `CellValue.TimeSpan(90 分钟)` 写入并读回
- **THEN** 数值为 `0.0625`、格式仍为 `[h]:mm`

### Requirement: 富文本读取

`Worksheet.richText(row, col)` SHALL 返回 `RichText`（`ArrayList<TextRun>`）；
`sharedStrings` 的 `<r><rPr>` SHALL 解析粗体/斜体/下划线/字号/颜色/字体名；
无 `<rPr>` 的分段 SHALL 合并为单个 `TextRun`。`CellValue` 仍为平坦化 `Text`（`text()` 可用）。

#### Scenario: 分段与样式

- **WHEN** `<si><r><rPr><b/></rPr><t>粗</t></r><r><t>细</t></r></si>`
- **THEN** `richText` 有 2 段，第一段 `font.bold == true`，`text()` 为 `"粗细"`

### Requirement: 富文本写出（M2 口径）

M2 写侧 SHALL 继续写 `inlineStr`（平坦化文本）；富文本样式 SHALL NOT 丢失数据（只丢样式），
并记一条 `RichTextFlattened` warning。

#### Scenario: 平坦化

- **WHEN** 写入含粗体分段的文本
- **THEN** 读回 `text()` 完整，`richText` 为单段（样式丢失）
