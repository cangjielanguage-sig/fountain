# Proposal: f_excel 图片写入（M1.5）

## Why

M1 只做单元格与日期，图片列在 Out of Scope。实际导出报表需要把 logo / 截图锚定进表，
因此补一个**只做写侧**的最小能力；读侧导入图片涉及 DrawingML 反向解析，留到后续。

## What Changes

- `Worksheet.addImage(path, from, to)` / `addImage(data, format, from, to)` / `imageCount()`。
- 支持 png / jpeg；`twoCellAnchor editAs="oneCell"` 锚定到两个单元格。
- 生成 `xl/media/imageN.<ext>`、`xl/drawings/drawingN.xml`（含 rels）、
  `xl/worksheets/_rels/sheetN.xml.rels`，worksheet 写 `<drawing r:id="rId1"/>`，
  `[Content_Types].xml` 增加图片 Default 与 drawing Override。
- 读侧不导入图片；`ExcelWriter`（流式写）不支持图片。

## Impact

- 新增 `Image.cj`；改 `Worksheet` / `PackageWriter` / `SheetXmlWriter`。
- 4 条结构用例 + openpyxl 回读；README / 设计文档升 v0.11。
