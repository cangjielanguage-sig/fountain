# Spec Delta — f-excel-images

## ADDED Requirements

### Requirement: 图片写入 API

`Worksheet` SHALL 提供 `addImage(path: Path, from: String, to: String)`、
`addImage(data: Array<Byte>, format: ImageFormat, from: String, to: String)` 与 `imageCount()`。
`from` / `to` SHALL 按 A1 引用解析；区域倒置、空数据、非 png/jpeg 扩展名 SHALL 抛 `ExcelException`。

#### Scenario: 锚定到区域

- **WHEN** `addImage(png, ImageFormat.Png, "A1", "B2")`
- **THEN** `imageCount() == 1`，写出的 drawing 中 from 为 (col 0,row 0)、to 为 (col 1,row 1)

#### Scenario: 倒置拒绝

- **WHEN** `addImage(png, Png, "B2", "A1")`
- **THEN** 抛 `ExcelException`

### Requirement: 图片部件与关系

`ExcelDocument.write` SHALL 为每张图片写 `xl/media/imageN.<ext>`，为每个含图 sheet 写
`xl/drawings/drawingN.xml`、`xl/drawings/_rels/drawingN.xml.rels`、
`xl/worksheets/_rels/sheetN.xml.rels`；worksheet SHALL 在 `mergeCells` 之后写
`<drawing r:id="rId1"/>`；`[Content_Types].xml` SHALL 含图片扩展名的 `Default` 与 drawing 的 `Override`。

#### Scenario: 结构可读

- **WHEN** 生成含 1 张 png 的工作簿
- **THEN** 四个部件都存在，worksheet 含 `<drawing r:id="rId1"/>`，drawing 含 `r:embed="rId1"`

#### Scenario: 多图编号

- **WHEN** 同一 sheet 加 2 张图
- **THEN** 媒体为 `image1.png` / `image2.png`，drawing 中第二个 `r:embed="rId2"`

### Requirement: 读侧不导入图片

`ExcelDocument` 读取含图片的文件 SHALL 正常返回单元格值；`Worksheet.imageCount()` SHALL 为 0。

#### Scenario: 往返丢图但值不丢

- **WHEN** 读取一个含图片与文本的工作簿
- **THEN** 文本值正确，`imageCount() == 0`

### Requirement: 外部工具可读

生成物 SHALL 能被 openpyxl 打开并读到图片数量与锚点。

#### Scenario: openpyxl 回读

- **WHEN** 用 openpyxl 打开生成物
- **THEN** `len(ws._images) == 1`，anchor 的 from/to 与入参一致
