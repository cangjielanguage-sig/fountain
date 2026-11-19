# Proposal: 实现 f_excel M2（样式、公式引擎、时长/富文本）

## Why

M1 只做"能读能写的最小闭环"：样式只到日期 `numFmtId`，公式只保留原文 + 缓存值，
`[h]:mm:ss` 硬塞成 `Date`，富文本平坦化成 `Text`。真实报表场景需要：

1. **样式**：字体/填充/边框/对齐/保护/颜色是 Excel 的表达主体，缺了只能算"数据容器"；
2. **公式**：不只求值，还要能把公式与缓存一起写出；用户打开文件时希望看到计算结果；
3. **时长与富文本**：`[h]:mm:ss` 是工时/时长表的常见格式；富文本是注释与导出的必需。

M1 的验收已完成（90 用例、openpyxl 回读、OpenSpec 归档），M2-e / M2-f 已提前落地，
本变更只做 **M2-a / M2-b / M2-c / M2-d**。

## What Changes

### M2-a 样式完整读写

- 新增 `CellStyle`（struct + 全 `let`）及 `Font` / `Fill` / `Border` / `BorderSide` /
  `Alignment` / `Protection` / `Color` / `Gradient`；`Underline` / `PatternType` / `BorderStyle` 枚举。
- `styles.xml` 全量读写：`numFmts` / `fonts` / `fills` / `borders` / `cellStyleXfs` /
  `cellXfs` / `cellStyles` / `dxfs`；颜色三种编码（`rgb` / `theme+tint` / `indexed`）。
- `Worksheet.styleOf` / `setStyle`；`ExcelDocument.setStyle(sheet, ref, style)` 便捷入口。
- 写侧样式池：`StylePool.getOrAdd` 深比较去重，`maxCellStyles` 按平台分档（Linux 64000 / 其他 8192），
  超限按设计 6.8 抛带指引的 `ExcelException`。
- `Cell` 的 `numberFormat` 升级为 `style: ?CellStyle`，保留 `numberFormat` 便捷形参（兼容 M1 调用方）。

### M2-b 公式引擎核心

- `FormulaParser`：词法 + 递归下降 → AST（设计 7.2 / 7.3 的优先级表）。
- `Evaluator` + `FunctionRegistry`：首批 **40 个函数**（数学/文本/逻辑/日期/查找核心）。
- `DependencyGraph` + `CalcEngine`：跨单元格/跨表依赖、拓扑排序、循环引用检测。
- `recalculate()` / `recalculate(sheet)` / `evaluate(sheet, ref)`；默认不自动重算。
- 共享公式相对引用平移（`t="shared"`，`$` 不动）；数组公式只求左上角 + 告警（M2 口径）。
- 日期函数复用 M1 的 `DateSerial`（1900 闰年 bug 已处理）。

### M2-c 公式引擎扩展

- 再补 **100 个函数**（统计/财务/工程/信息类），函数总数 ≥ 140。
- 易失函数（`NOW` / `TODAY` / `RAND` / `RANDBETWEEN`）：同一次 `recalculate()` 共享一次系统时间/随机源。
- 函数注册表可按名查询；未知函数 → `#NAME?` + `CalcIssue`。

### M2-d `TimeSpan` 与富文本

- `CellValue` 增加 `TimeSpan(Duration)`；`[h]:mm:ss` / `[m]:ss` 等经过时间按 `TimeSpan` 返回。
- `RichText` 模型（`TextRun` + `RunFont`）与 `Worksheet.richText(row, col)`；
  `sharedStrings` 的 `<r><rPr>` 读取；写侧先平坦化为 `inlineStr`（富文本写出留 M3）。
- 读侧兼容：无 `<rPr>` 的分段仍合并为 `Text`。

## Impact

- 新增 `src/Style*.cj`、`src/Formula*.cj`（约 12 个文件）；改 `CellValue` / `Cell` / `Worksheet` /
  `PackageReader` / `PackageWriter` / `SheetXmlWriter` / `StylesLite`。
- 公开 API 增量：`CellStyle` 家族、`CalcEngine` 三个方法、`CellValue.TimeSpan`、`RichText`。
- **不破坏 M1 调用方**：`Cell.numberFormat` 保留；`CellStyle` 是新增类型。
- 测试：样式往返（20 种）、40+100 函数对照、共享公式平移、时长/富文本往返；预计新增 200+ 用例。
- 文档：README 中英、设计文档、`doc/spec/implement-f-excel-m2`。

## Out of Scope

- 350+ 函数、数组/动态数组求值（M3）。
- 条件格式（M4）。
- 富文本**写出**（M3）；M2 只读。
- 样式主题文件的完整解析（`theme1.xml` 只取 tint 所需的最小字段）。
