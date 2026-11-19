# Design: f_excel 图片写入

## API

```cangjie
public enum ImageFormat <: ToString { | Png | Jpeg }
extend Worksheet {
    public func addImage(path: Path, from: String, to: String): Unit
    public func addImage(data: Array<Byte>, format: ImageFormat, from: String, to: String): Unit
    public func imageCount(): Int64
}
```

`from`/`to` 走 `CellRef.parse`；倒置或空数据抛 `ExcelException`；扩展名决定格式。

## OOXML 部件

| 部件 | 内容 |
|---|---|
| `xl/media/imageN.png` | 原始字节（`ZipWriter.add`） |
| `xl/drawings/drawingN.xml` | `<xdr:wsDr>` + 每图一个 `twoCellAnchor`（`from`/`to` 0 基、`pic`/`blipFill`/`spPr`/`clientData`） |
| `xl/drawings/_rels/drawingN.xml.rels` | `rIdK → ../media/imageX.ext`，Type `…/image` |
| `xl/worksheets/_rels/sheetN.xml.rels` | `rId1 → ../drawings/drawingN.xml`，Type `…/drawing` |
| worksheet | `<drawing r:id="rId1"/>`（`mergeCells` 之后） |
| `[Content_Types].xml` | 图片扩展名 `Default`；每个 drawing `Override` |

命名空间：`xdr`（spreadsheetDrawing）、`a`（drawingml main）、`r`（relationships）；
drawing 根声明 `xmlns:r`，`a:blip` 用 `r:embed`。

## 读侧

`WorksheetParser` 忽略 `<drawing>`；含图片文件读回后 `imageCount() == 0`，文档已列为缺口。

## 验证

结构断言 4 条（部件、drawing 引用、锚点、多图编号）；openpyxl 3.1.5 回读
`len(ws._images) == 1` 且 anchor 的 from/to 与入参一致。
