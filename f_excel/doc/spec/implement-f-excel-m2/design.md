# Design: f_excel M2

> 依据 `f_excel模块设计.md` v0.11 第 6 / 7 章与 5.5。M2-e / M2-f 已在 M1 批次交付，
> 本文只覆盖 **M2-a / M2-b / M2-c / M2-d**。

## 1. 样式子系统（M2-a）

### 1.1 数据结构

```cangjie
public struct CellStyle {
    public let numberFormat: NumberFormat
    public let font: Font
    public let fill: Fill
    public let border: Border
    public let alignment: Alignment
    public let protection: Protection
    public let namedStyle: ?String
    // withFont / withFill / withNumberFormat / withAlignment ...
}
public struct Font { name: ?String, size: Float64, bold: Bool, italic: Bool,
                     underline: Underline, strike: Bool, color: ?Color,
                     family: Int64, charset: Int64, scheme: ?String }
public struct Fill { patternType: PatternType, fgColor: ?Color, bgColor: ?Color, gradient: ?Gradient }
public struct Border { left/right/top/bottom/diagonal: BorderSide }
public struct BorderSide { style: BorderStyle, color: ?Color }
public struct Alignment { horizontal: Horizontal, vertical: Vertical, wrapText: Bool, textRotation: Int64, indent: Int64, shrinkToFit: Bool }
public struct Protection { locked: Bool, hidden: Bool }
public enum Color { Rgb(String) | Theme(theme: Int64, tint: Float64) | Indexed(Int64) }
```

全部 `struct` + `let`：样式池按**值**深比较去重（设计 6.4 的硬要求）。

### 1.2 读取

`StylesLite` → `Styles`（M2）：

```
styles.xml DOM
  numFmts   → HashMap<Int64, String>
  fonts[i]  → Font
  fills[i]  → Fill
  borders[i]→ Border
  cellXfs[i]→ (numFmtId, fontId, fillId, borderId, alignment, protection, xfId)
  cellStyles→ named styles
```

`WorksheetParser` 的 `s` 索引改为查 `Styles.cellStyleAt(s)`，返回完整 `CellStyle`。
`CellValue` 不再携带样式；样式挂在 `Cell` / `Worksheet` 的样式索引上。

### 1.3 写入

```
Cell.style (CellStyle)
   → StylePool.getOrAdd(style)  // 深比较，返回 cellXfs 索引
   → <c r="A1" s="N">
styles.xml 在 worksheet 之后写（与 M1 顺序一致）
```

`StylePool` 内部四张子表（fonts/fills/borders/numFmts）各自去重，`cellXfs` 引用子表索引；
超 `maxCellStyles` 按设计 6.8 抛异常（Linux 64000，其他 8192）。

### 1.4 兼容

`Cell` 保留 `numberFormat!: ?NumberFormat` 形参；内部转成 `CellStyle(numberFormat: ...)`；
`numberFormat` 与 `style` 同时给时以 `style` 为准（文档写明）。

## 2. 公式引擎（M2-b / M2-c）

### 2.1 分层

```
FormulaLexer → FormulaParser → Ast
        ↓
Evaluator（借助 SheetResolver 取单元格值）
        ↓
FunctionRegistry（按名注册，分组文件：math/text/logic/date/lookup/stat/financial）
        ↓
DependencyGraph（单元格 → 依赖集合；跨 sheet 用 (sheet, ref) 键）
        ↓
CalcEngine.recalculate / evaluate
```

### 2.2 值模型

`CalcValue` 独立于 `CellValue`：`Number` / `Text` / `Boolean` / `Error` / `Blank` / `Array`（M3 用）。
`CellValue` ↔ `CalcValue` 双向转换；`Date` 按序列号参与运算，结果再按样式判回日期。

### 2.3 求值策略

- 默认**不自动重算**：读文件拿缓存值；`recalculate()` 显式触发。
- `recalculate`：建图 → 拓扑排序 → 逐格求值；循环引用 → 环上单元格 `#CIRC!` + `CalcIssue`。
- `evaluate(sheet, ref)`：单格递归求值，带 memo，不建全图。
- `NOW` / `TODAY` / `RAND` / `RANDBETWEEN`：一次 `recalculate` 内共享一个 `CalcContext`。

### 2.4 共享公式与数组公式

- `t="shared"`：主单元格保存原文与 `ref`；其余格按 `si` 找主公式，按 `shiftRef` 平移相对引用；
  `$` 修饰不动，越界 → `#REF!`。
- `t="array"`：M2 只求左上角，其余保留原文 + `NotSupported`（数组广播在 M3）。

### 2.5 函数清单（M2 共 140）

| 组 | M2-b（40） | M2-c（+100） |
|---|---|---|
| 数学 | SUM / AVERAGE / MIN / MAX / ROUND / ABS / INT / MOD / POWER / SQRT | ROUNDUP / ROUNDDOWN / CEILING / FLOOR / TRUNC / SIGN / EXP / LN / LOG / LOG10 / PI / PRODUCT |
| 文本 | CONCATENATE / LEFT / RIGHT / MID / LEN / LOWER / UPPER / TRIM | FIND / SEARCH / SUBSTITUTE / REPLACE / TEXT / VALUE / EXACT / REPT / CHAR / CODE |
| 逻辑 | IF / AND / OR / NOT / IFERROR | TRUE / FALSE / ISBLANK / ISNUMBER / ISTEXT / ISERROR / NA |
| 日期 | TODAY / NOW / DATE / YEAR / MONTH / DAY | HOUR / MINUTE / SECOND / DATEVALUE / TIME / WEEKDAY / EOMONTH / EDATE |
| 查找 | VLOOKUP / INDEX / MATCH | HLOOKUP / CHOOSE / OFFSET / INDIRECT / ROW / COLUMN / ROWS / COLUMNS |
| 统计 | COUNT / COUNTA / COUNTIF / SUMIF | COUNTIFS / SUMIFS / AVERAGEIF / MEDIAN / STDEV / VAR / LARGE / SMALL / RANK |
| 财务/信息 | — | PMT / FV / PV / RATE / NPER / ISEVEN / ISODD / TYPE / CELL |

具体清单与签名在 `FunctionRegistry` 的注册表中固定，测试按 Excel 预期值逐一对照。

## 3. 时长与富文本（M2-d）

- `CellValue.TimeSpan(Duration)`：`numFmtId` 46/47 或自定义格式含 `[h]/[m]/[s]` 时返回；
  读侧走 `DateSerial` 的"天数 + 秒"拆解，不做 1900 闰年偏移。
- `RichText`：`ArrayList<TextRun>`；`TextRun { text: String, font: ?RunFont }`；
  `sharedStrings` 解析 `<r><rPr>`（只取 b/i/u/sz/color/rFont）；无 `rPr` 的分段仍拼成 `Text`。
- 写侧 M2 仍写 `inlineStr`（平坦化），富文本写出与 `sharedStrings` 模式留 M3。

## 4. 文件与测试

| 文件 | 职责 |
|---|---|
| `Style.cj` | `CellStyle` 家族与 `with*` |
| `StylePool.cj` | 深比较去重、上限 |
| `Styles.cj` | styles.xml 全量读写 |
| `FormulaLexer.cj` / `FormulaParser.cj` / `Ast.cj` | 词法、语法、AST |
| `CalcValue.cj` / `Evaluator.cj` | 值模型与求值 |
| `FunctionRegistry.cj` + `functions/*.cj` | 140 个函数 |
| `DependencyGraph.cj` / `CalcEngine.cj` | 依赖图、重算 |
| `RichText.cj` | 富文本模型与 sharedStrings 解析 |

测试：样式 20 种往返、函数逐一对 Excel 值、共享公式平移、循环引用、时长/富文本；新增 200+ 用例。

## 5. 待实测（实现前）

| 项 | 问题 | 方案 |
|---|---|---|
| R5 | `theme1.xml` 的 tint 变换公式 | 按 OOXML 规范实现 `tint` 线性插值，用 Excel 样本对照 8 个色值 |
| R6 | 函数预期值来源 | 用 openpyxl 无法求值；以 Excel 手工样本 + LibreOffice 批量生成对照表 |
| R7 | `Duration` 的纳秒精度与 `[h]` 超过 24h | 用 `Duration` 总秒数，验证 100h/1000h |
| R8 | 样式池深比较性能 | 64000 条随机样式插入基准，目标 < 200 ms |
