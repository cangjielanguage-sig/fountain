# f_excel

Excel（xlsx / OOXML）读写模块：**流式解析、流式生成**、日期识别、合并单元格。

- 包名：`fountain::f_excel`
- 依赖：`f_base`、`f_log`、`f_util`、`f_xml`（XML 解析 / 增量生成）、`f_zip`（OOXML 容器）
- 设计文档：[`doc/f_excel模块设计.md`](doc/f_excel模块设计.md)
- 规格与任务：[`doc/spec/implement-f-excel-m1/`](doc/spec/implement-f-excel-m1/)

## 能力（M1）

| 能力 | 说明 |
|---|---|
| 整文档读 | `ExcelDocument(input)` / `ExcelDocument(path)`：sheet 清单、七种值、sharedStrings、合并区域、日期识别 |
| 整文档写 | `ExcelDocument.write(output)` / `write(path)`：`inlineStr`、多 sheet、合并、日期/时长绑样式、图片、完整样式 |
| **流式读** | `ExcelSheetStream.open(path/input)` → `RowReader`：逐行拉取，**内存与行数无关** |
| **流式写** | `ExcelWriter`：行迭代器 → `f_xml.XmlWriter` 增量事件 → `f_zip.openEntry` 推模式压缩 |
| 值类型 | `Empty` / `Number` / `Text` / `Boolean` / `Error` / `Date` / `Formula`（只保留原文 + 缓存，不求值） |
| 日期 | 内置 14–22 / 45–47 与自定义格式启发式；1900 / 1904 两种基准；serial 60 保留为数字并告警 |
| 图片（写） | `Worksheet.addImage(path/bytes, from, to)`：png / jpeg，锚定到单元格区域；读侧暂不导入图片 |
| 样式 | `CellStyle` / `Font` / `Fill` / `Border` / `Alignment` / `Protection` / `Color` 全量读写；`styles.xml` 的 numFmts/fonts/fills/borders/cellXfs/cellStyles；样式池按值去重 |
| 公式 | 解析 + 求值 + 依赖图：`CalcEngine.evaluate` / `recalculate`；350 个函数；共享公式平移；循环引用 `#CIRC!` |
| 时长 / 富文本 | `[h]:mm:ss` 读取为 `CellValue.TimeSpan`；`Worksheet.richText` 暴露 sharedStrings 的分段字体 |
| 条件格式 | `<conditionalFormatting>` / 13 种 `CfRuleType` / `dxfs` 解析与写回；`matchedRules` 求值（cellIs/expression/文本/colorScale/dataBar/iconSet） |

全量 `cjpm test`：**181 通过 / 0 失败**。

## 用法

### 读整份文档

```cangjie
import fountain::f_excel.*
import std.fs.Path

let doc = ExcelDocument(Path("/data/a.xlsx"))
let sheet = doc.sheet("Sheet1").getOrThrow()
let value = sheet.cell("A1")                       // ?CellValue
println(sheet.mergedValue(2, 1))                   // 合并区域左上角的值
```

### 写整份文档

```cangjie
let doc = ExcelDocument()
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.setCell("A1", CellValue.Text("名称"))
sheet.setCell("B1", CellValue.Number(0.1))
sheet.merge("A1:B1")
doc.write(Path("/data/out.xlsx"))
```

### 按需解析 / 字符串索引

```cangjie
let options = ExcelReadOptions()
options.eager = false                  // 首次访问 sheet 才解析
let doc = ExcelDocument(Path("big.xlsx"), options: options)

let streamOptions = ExcelStreamReadOptions()
streamOptions.sharedStringsIndex = true // 字符串表落临时文件，按需读取
let stream = ExcelSheetStream.open(Path("big.xlsx"), options: streamOptions)
```

### 公式求值

```cangjie
let engine = CalcEngine(doc)
let value = engine.evaluate("Sheet1", "B2")     // 单格，带依赖递归
engine.recalculate(writeBack: true)              // 全表重算并写回缓存值
```

### 样式

```cangjie
sheet.setCell("A1", CellValue.Number(1234.5))
sheet.setStyle(1, 1, CellStyle(
    numberFormat: NumberFormat.Builtin(4),
    font: Font(bold: true, color: Color.Rgb("FFFF0000")),
    fill: Fill.solid(Color.Rgb("FFFFFF00")),
    alignment: Alignment(horizontal: Horizontal.Center, wrapText: true)
))
```

### 插入图片

```cangjie
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.addImage(Path("/data/logo.png"), "A4", "E12")   // 锚定 A4:E12
```

### 流式写（大表，内存恒定）

```cangjie
let writer = ExcelWriter(out, ["明细"])
writer.writeSheet("明细", rows.iterator())         // rows: Iterator<RowData>
writer.finish()                                    // 写中央目录 + EOCD，之后才能读
```

### 流式读（边读边解析）

```cangjie
let stream = ExcelSheetStream.open(Path("/data/big.xlsx"))
try {
    let reader = stream.rows("明细").getOrThrow()
    while (let Some(row) <- reader.next()) {
        for (cell in row.cells) {
            // cell.col / cell.value
        }
    }
    println(reader.mergedRanges())                 // 流结束后才有值
} finally {
    stream.close()
}
```

### 大表复制（两端常量内存）

```cangjie
let src = ExcelSheetStream.open(Path("/data/big.xlsx"))
let out = File("/data/copy.xlsx", OpenMode.Write)
let writer = ExcelWriter(out, ["明细"])
writer.writeSheet("明细", src.rows("明细").getOrThrow())
writer.finish()
src.close()
out.close()
```

## 已知缺口（M1 范围）

- **样式**：`theme1.xml` 只按 tint 线性插值，主题色板未完整解析。
- **公式**：动态数组只做到函数返回数组，`#SPILL!` 溢出未实现；`OFFSET` / `INDIRECT` 为动态依赖，不参与静态依赖图。
- **富文本**：只读不写，写侧平坦化为普通文本（样式丢失）。
- **时长 / 富文本**：`[h]:mm:ss` 按 `Date` 返回并告警；富文本平坦化为 `Text`。
- **图片**：只支持写入（png / jpeg、两单元格锚定）；读取时不导入图片，含图片的文件往返后图片会丢失。
- **条件格式**：`timePeriod` / `aboveAverage` 只保留不求值；图标集不生成图片。
- **共享字符串写出**：只写 `inlineStr`，不生成 `xl/sharedStrings.xml`。
- **流式读的合并区域**：流中拿不到（`<mergeCells>` 在 `<sheetData>` 之后），流结束后 `mergedRanges()` 才可用。
- **流式读的常驻内存**：只有 `sharedStrings` 随文件增长；`loadSharedStrings = false` 可关。
- 不支持图表 / 数据透视表 / 批注 / 数据验证 / ods。

## 测试与夹具

- `cjpm test` 全绿（181 条）。
- 夹具用 `f_zip.ZipWriter` 现场拼最小 xlsx（`fixtures.cj`），不依赖外部样本文件。
- 「真实 Excel 打开不报修复」属人工验收项，记录见 `doc/spec/implement-f-excel-m1/verification.md`。
