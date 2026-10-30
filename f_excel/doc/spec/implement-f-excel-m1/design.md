# Design: 实现 f_excel M1（读写核心 + 流式读 + 流式写）

> 依据 `f_excel/doc/f_excel模块设计.md` v0.8（下称「设计文档」）与 `baseline.md` 的依赖实测。
> 本文只处理 **M1 + M2-e + M2-f** 的落地细节，并对设计文档里无法字面实现、或与仓库现状冲突的
> 地方给出结论（§8）。
>
> **唯一入库副本**：`f_excel/doc/spec/implement-f-excel-m1/`。`openspec/` 已被根 `.gitignore`
> 忽略，`openspec/changes/implement-f-excel-m1/` 是本地工作副本，由 `rsync -a --delete` 同步，
> `diff -ru` 必须无输出（tasks 12.7）。

## 1. 目标与非目标

### 目标

1. `f_excel` 能读真实 xlsx：sheet 清单、单元格七种值、sharedStrings、合并区域、日期识别。
2. `f_excel` 能写 Excel 认可的最小 xlsx：多 sheet、七种值、合并区域、日期正确显示。
3. **两端常量内存**：`ExcelSheetStream` 逐行读、`ExcelWriter` 逐行写，内存与行数无关；
   读出的 `RowData` 能直接喂给写侧（"大表复制"闭环）。
4. 三条等价性可验证：模型往返、通道等价（流式 ↔ 整文档）、结构合法（外部工具可读）。

### 非目标

- 样式完整模型（`CellStyle`/`Font`/`Fill`/`Border`/`Color`/theme/tint）与样式池：M2-a。
- 公式求值、依赖图、函数库：M2-b/c。
- `TimeSpan`、富文本：M2-d。
- 按需解析（`eager`）、`sharedStrings` 磁盘索引、紧凑单元格结构：M3。
- 条件格式语义、`docProps`、图表/图片/透视表/批注/数据验证：M2~M4 或永不。
- 性能门禁：只记录，不设阈值（设计 §9 的预估不做对照验收）。

## 2. 范围边界

| 能力 | 本变更 | M2 | M3 |
|---|---|---|---|
| `CellRef` / 列号 / 七种 `CellValue` | ✅ | | |
| 整文档读（workbook/rels/sharedStrings/worksheet/合并/日期） | ✅ | | |
| 最小可用包生成（`inlineStr`、多 sheet、合并、日期绑样式） | ✅ | | |
| 流式读 `ExcelSheetStream` / `RowReader` | ✅ | | |
| 流式写 `ExcelWriter` | ✅ | | |
| 往返 / 通道等价 / 结构断言 | ✅ | | |
| 样式完整读写、样式池 | | ✅ | |
| 公式引擎 | | ✅ | |
| `TimeSpan`、`RichText`、`SharedStrings` 写出模式 | | ✅ | |
| 按需解析、`sharedStrings` 磁盘索引、紧凑单元格 | | | ✅ |

**为什么把 M2-e / M2-f 提前到本变更**：设计 §2.7.2 要求读侧 `RowData` 与写侧 `Cell` 同构，
两者共用一套取值逻辑（`t` 类型表 + sharedStrings + 日期识别）。先做整文档、再回头做流式，
等于把取值逻辑写两遍；而先做流式、后补整文档，则整文档只是"把行累加进 `Worksheet`"。
所以三条通道**一次做完**，用同一份 `WorksheetParser`（§6.6）。

六份 spec 分册各覆盖一层；范围摘要统一收在本文，spec 文件只保留 Requirement：

| spec | 覆盖内容 | 对应本文 |
|---|---|---|
| `f-excel-cell-model` | `CellRef` / 列号、`CellValue`、`RowData`/`Cell`、异常与告警 | §6.2–§6.4、§6.11 |
| `f-excel-reader` | 整文档解析：包结构、sharedStrings、类型表、稀疏性、合并、日期、选项 | §6.1、§6.3–§6.6 |
| `f-excel-writer` | 最小可用包、`inlineStr`、数字最短往返、日期绑样式、转义、上限 | §6.7、§6.8、§7 |
| `f-excel-stream-read` | `ExcelSheetStream` / `RowReader`、spool、行语义、生命周期 | §6.9 |
| `f-excel-stream-write` | `ExcelWriter`、行号校验、失败状态机、flush、与读侧直连 | §6.10 |
| `f-excel-roundtrip` | 模型往返、通道等价、结构合法性、夹具策略、人工验收 | §9 |

## 3. 依赖与复用查证

详见 `baseline.md`。结论四条：

1. `f_zip` 的 `ZipReader(path: String)` / `open(name): ?InputStream` / `ZipWriter.addFileStream`
   完全够用，**不改** `f_zip`。
2. `f_xml` 的 `XmlPullParser`（事件流）与 DOM（`XmlElement`/`XmlDocument`）够用；
   **`XmlWriter` 只有整元素/整文档写，没有增量接口**——这是 worksheet 必须自写发射器的原因
   （差异 5）。`Escaper` 是包内私有，无法复用（`Escaper.cj:26`）。
3. `f_base.BaseException` 与 `StringGenerator` 直接复用。
4. `f_zip` **没有** `openEntry(): OutputStream`，所以推模式（`appendRow`）确实做不了，
   设计 §2.6.1 的结论保持。

## 4. 包结构

**单包 `fountain::f_excel`，扁平 `src/*.cj`。** 理由同 `f_xml`（`implement-f-xml-m1/design.md`
§4）：仓颉 `internal` 对父包不可见，分子包会逼着把内部类型提成 `public`。

| 文件 | 职责 |
|---|---|
| `f_excel.cj` | 包文档、`F_EXCEL_VERSION` |
| `ExcelException.cj` | `ExcelException`、`ExcelWarning`、`ExcelWarningKind` |
| `CellRef.cj` | `CellRef`、`columnIndex`、`columnLetters` |
| `CellValue.cj` | `CellValue`、`NumberFormat`、值 → 文本/序列号的取值函数 |
| `RowData.cj` | `RowData`、`Cell` |
| `ExcelOptions.cj` | `ExcelReadOptions`、`ExcelStreamReadOptions`、`ExcelWriteOptions`、`SheetWriteOptions` |
| `ExcelDocument.cj` | `ExcelDocument`（构造、sheet 管理、`write`） |
| `Worksheet.cj` | `Worksheet`（单元格、合并、范围统计） |
| `PackageReader.cj` | `[Content_Types].xml` / `workbook.xml` / rels 的读取 |
| `PackageWriter.cj` | 四个小部件 + `styles.xml` 的 DOM 生成与写出 |
| `SharedStringTable.cj` | `sharedStrings.xml` 事件流装载 |
| `StylesLite.cj` | `styles.xml` 的**最小读取**（`cellXfs[i].numFmtId` → 是否日期/是否时长） |
| `DateFormat.cj` | `numFmtId` 集合、`formatCode` 净化与判定、`[h]` 判定 |
| `DateSerial.cj` | serial ↔ `DateTime`（1900 闰年 bug、1904 基准） |
| `WorksheetParser.cj` | worksheet 事件流 → `RowSink`（三条通道共用） |
| `SheetRowSink.cj` | 行级回调接口、`RowBuilder`、`CellBuilder` |
| `WorksheetXmlWriter.cj` | 流式 worksheet XML 发射器（8 KB 缓冲、转义、数字格式、上限） |
| `ExcelSheetStream.cj` | `ExcelSheetStream`、`RowReader` |
| `ExcelWriter.cj` | `ExcelWriter` |
| `fixtures.cj` | **测试支持**（`internal`）：用 `f_zip.ZipWriter` 拼最小 xlsx 的夹具工厂 |

## 5. 公开 API

```cangjie
package fountain::f_excel

public struct CellRef <: Equatable<CellRef> & ToString {
    public let row: Int64
    public let col: Int64
    public let rowAbs: Bool
    public let colAbs: Bool
    public init(row: Int64, col: Int64, rowAbs!: Bool = false, colAbs!: Bool = false)
    public static func parse(s: String): ?CellRef
    public static func parseRange(s: String): ?(CellRef, CellRef)
    public func toString(): String
    public func toA1(): String
}

public func columnIndex(letters: String): ?Int64
public func columnLetters(col: Int64): String

public enum NumberFormat <: Equatable<NumberFormat> & ToString {
    | General
    | Builtin(Int64)
    | Custom(String)
}

public enum CellValue <: ToString {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)
    | Date(DateTime)
    | Formula(String, Option<CellValue>)
}

public struct Cell {
    public let col: Int64
    public let value: CellValue
    public let numberFormat: ?NumberFormat
    public init(col: Int64, value: CellValue, numberFormat!: ?NumberFormat = None)
}

public struct RowData {
    public let index: Int64
    public let cells: Array<Cell>
    public let height: ?Float64
    public init(index: Int64, cells: Array<Cell>, height!: ?Float64 = None)
}

public class ExcelDocument {
    public init()
    public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())
    public init(path: Path, options!: ExcelReadOptions = ExcelReadOptions())

    public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions())
    public func write(path: Path, options!: ExcelWriteOptions = ExcelWriteOptions())

    public func sheets(): ArrayList<Worksheet>
    public func sheet(name: String): ?Worksheet
    public func sheetAt(index: Int64): ?Worksheet
    public func sheetCount(): Int64
    public func addSheet(name: String): Worksheet
    public func removeSheet(name: String): Bool
    public func renameSheet(oldName: String, newName: String): Bool

    public prop date1904: Bool
    public func warnings(): ArrayList<ExcelWarning>
}

public class Worksheet {
    public prop name: String

    public func rowCount(): Int64
    public func colCount(): Int64
    public func dimension(): ?String

    public func cell(row: Int64, col: Int64): ?CellValue
    public func cell(ref: String): ?CellValue
    public func cell(ref: CellRef): ?CellValue
    public func setCell(row: Int64, col: Int64, value: CellValue): Unit
    public func setCell(ref: String, value: CellValue): Unit
    public func setCell(ref: CellRef, value: CellValue): Unit
    public func clearCell(row: Int64, col: Int64): Unit
    public func clearCell(ref: String): Unit

    public func range(from: String, to: String): Array<Array<CellValue>>
    public func rowValues(row: Int64): Array<(Int64, CellValue)>

    public func mergedRanges(): ArrayList<String>
    public func mergedRangeAt(row: Int64, col: Int64): ?String
    public func mergedValue(row: Int64, col: Int64): ?CellValue
    public func merge(range: String): Unit
    public func merge(from: String, to: String): Unit
    public func unmerge(range: String): Bool
}

public class ExcelSheetStream {
    public static func open(path: Path, options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public static func open(input: InputStream, options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public func sheetNames(): Array<String>
    public func rows(sheet: String): ?RowReader
    public func rowsAt(index: Int64): ?RowReader
    public func lastMergedRanges(sheet: String): ArrayList<String>
    public func warnings(): ArrayList<ExcelWarning>
    public func close(): Unit
}

public class RowReader <: Iterator<RowData> {
    public func next(): Option<RowData>
    public func close(): Unit
    public func mergedRanges(): ArrayList<String>
}

public class ExcelWriter {
    public init(output: OutputStream, sheetNames: Array<String>,
                options!: ExcelWriteOptions = ExcelWriteOptions())
    public func writeSheet(name: String, rows: Iterator<RowData>,
                           options!: SheetWriteOptions = SheetWriteOptions()): Unit
    public func finish(): Unit
    public prop rowsWritten: Int64
}

public class ExcelWriteOptions {
    /** `None` = 跟随文档（`ExcelDocument.date1904`）；流式写取 `false`（1900 基准）。 */
    public var date1904: ?Bool = None
}

public class SheetWriteOptions {
    public var dimension: ?String = None
}

public class ExcelReadOptions {
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0
    public var skipSheets: Array<String> = []
}

public class ExcelStreamReadOptions {
    public var spool: Bool = true
    public var spoolDir: ?Path = None
    public var loadRowHeight: Bool = true
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0
}

public class ExcelWarning { /* kind / message / sheet / ref */ }
public enum ExcelWarningKind <: Equatable<ExcelWarningKind> { /* 见 cell-model spec */ }
public class ExcelException <: BaseException { /* init(message) / init(message, caused) */ }
```

选项类按仓库惯例写成**可变类**（`f_zip.ZipWriterOptions` 同法），因为 `options.xxx = y` 是
调用方最常见的用法；`CellRef`/`Cell`/`RowData` 写成 **`struct` + 全 `let`**（值语义，
可放进 `Array`/作为键，与设计 2.6.4.2 对 `CellStyle` 的要求一致）。

## 6. 关键实现路线

### 6.1 读通路：三条通道，一个内核

```
PackageReader.read()                      // workbook + rels + ContentTypes
        │  sheet 名 → 部件路径
        ▼
StylesLite.load()   /  SharedStringTable.load()      // 一次性，KB~MB
        │ numFmtId→日期查表          │ 索引→字符串
        ▼                            ▼
WorksheetParser(sheetInputStream, sink)  // 唯一内核，事件流
        │  <row> / <c> / <v> / <is> / <f>
        ├── WorksheetSink   → 累加进 Worksheet（整文档）
        └── StreamRowSink   → 一行一个 RowData 交给调用方（流式）
        │
        └── 之后：<mergeCells> → 整文档并入 Worksheet；流式交给 RowReader
```

`WorksheetParser` 是**同一个类**，只是 `RowSink` 实现不同——这是"通道等价"的机制保证：
两条通道不可能因为解析差异而不一致。`ExcelSheetStream` 每条 `rows(sheet)` 新建一个
`WorksheetParser`（ZIP 条目可重复解压，`ZipReader.open` 每次独立游标）。

### 6.2 `CellRef` 与列号

```
columnIndex("AB")：col = 0; for ch: col = col*26 + (upper(ch) - 'A' + 1)
columnLetters(27)："AA"；循环 col -= 1; prepend('A' + col % 26); col /= 26
```

`parse` 的状态机刻意写成**一次线性扫描**而非正则：

```
i = 0
while i < n && s[i] == '$' → 置 colAbs 后跳过（只允许一个 $
读字母段（A-Z/a-z，至少 1 个）→ 转列号，超 16384 → None
若下一个是 '$' → rowAbs，跳过
读数字段（至少 1 个，纯 0-9，允许前导零）→ 转行号，超 1048576 或 == 0 → None
i 必须到末尾，否则 None
```

这三条（前导零、`$` 位置、越界）是设计 §11.6 点名要单测的；`A01` 必须得到 `row=1`，
`A0` 必须 `None`（行号 0 在 Excel 里不存在）。

### 6.3 `t` 类型取值

按 `f-excel-reader` 的类型表实现，内部统一走一个函数：

```
valueOf(t: ?String, rawText: String, inlineText: ?String, styles, sst, ctx) -> CellValue
```

四个边界：

1. `t` 缺省且 `s` 指向日期格式 → `Date`（§6.4），否则 `Number`。
2. `t="s"` 且 `rawText` 不是合法整数 → `Empty` + `SharedStringIndexOutOfRange`
   （索引能解析但越界同理）。
3. `t="d"` 走 `DateTime.parse`；失败降级 `Text` + `NumberParseFailed`。
4. `<f>` 存在时，先记公式原文；缓存值是 `<v>` 按**无 `t`**（或 `t="str"`/`b`/`e`）解析的结果。
   `t="str"` 的缓存值是文本结果，必须按 `Text` 而不是 `Number`。

### 6.4 日期识别与 serial 换算

**判定顺序**（做反了会误判）：

```
1. numFmtId ∈ 内置日期集合 {14..22, 45..47}        → 日期；其中 46/47 另记 UnsupportedTimeFormat
2. 自定义 formatCode：
   a. 先在**原文**上扫方括号，方括号内容全为 h/m/s（大小写不敏感）→ hasElapsed = true
      （`[h]` `[hh]` `[mm]` `[ss]` 都算；`[Red]` `[$-409]` `[>=100]` `[Color10]` `[h:ss]` 都不算）
   b. 再净化：去 `[...]`、`"..."`、`\x`、`_x`、`*x`，转小写
   c. 净化后含 {y,m,d,h,s} 之一，且（含 `-` `/` `:` 或只由这些字符与分隔符组成）→ 日期
   d. hasElapsed → 记 UnsupportedTimeFormat（M1 仍返回 Date）
```

**`m` 的歧义**用"同段连续格式字符内是否紧邻 h 或 s"判定（`yyyy-mm-dd` 的 `m` 是月，
`h:mm` / `mm:ss` 的 `m` 是分钟）。这条只影响"是否日期"的边缘样本，两种判定都返回 `Date`，
所以 M1 不引入额外风险；M2 需要区分"日期 vs 时间 vs 时长"时才精确到分钟/月。

**serial → `DateTime`**：

```
1900 基准：
  serial ∈ [1, 59]  → base = 1899-12-31
  serial == 60      → 不是日期，返回 Number(60) + DateSerial60
  serial >= 61      → base = 1899-12-30
1904 基准：
  base = 1904-01-01（无闰年 bug），serial 0 = 该日

时间部分 = serial - floor(serial)；秒 = round(时间部分 * 86400)，跨 86400 时进位到次日
```

**`DateTime` → serial**：先算目标日与 base 的**日差**（用 `DateTime` 的日期字段归一化后算，
不依赖本地时区，见 §10 R2），再除以 86400 累加时间部分。M1 只处理「精确到秒」的日期，
毫秒 SHALL 被截断（Excel 的显示精度本来就到秒）。

### 6.5 `sharedStrings`

事件流，用一个深度游标识别上下文：

```
<si>            → 新条目，depthSi++
  <t>           → 文本目标（若在 <rPh> 内则忽略）
  <rPh>         → inPhonetic = true（整个跳过）
</si>           → 提交条目
```

三个易错点单测覆盖：

1. 多段 `<r><t>` 必须**拼接**（不是取第一段）；
2. `<t xml:space="preserve">` 保留首尾空白；**没有该属性时也保留**（不 trim，
   否则 `" "` 会变成 `""`，与 Excel 显示不符）；
3. `<rPh>` 里的 `<t>` 不是正文。

### 6.6 worksheet 事件处理器

```cangjie
internal interface RowSink {
    func row(row: RowData): Unit          // 流式：直接交出去；整文档：累加进 Worksheet
    func merged(ranges: ArrayList<String>): Unit
}
```

`WorksheetParser` 的 `match` 只按 `name.local`，不拼前缀：

| local | 动作 |
|---|---|
| `row` | 开新 `RowBuilder`（读 `r` / `ht`） |
| `c` | 开新 `CellBuilder`（读 `r` / `t` / `s`） |
| `v` | 后续文本进 `valueText` |
| `f` | 后续文本进 `formulaText`（读 `t` 属性判断 shared/array） |
| `is` / `t` | 后续文本进 `inlineText`（`is` 下的 `t`，不是 `<si>` 的） |
| `mergeCell` | 读 `ref` 收集 |
| `row`（End） | 组装 `RowData` → `sink.row(...)`，**立刻丢弃** |

**必须按 `r` 定位**，不能按出现顺序（设计 §3.3：这是最常见的解析错误，没有之一）。
`<c>` 缺 `r` 才按"前一列 + 1"推断并记 warning。

`<row>` 的 `r` 缺失按"上一行 + 1"推断——注意流式通道里"上一行"是**产出过的最后一行**，
不是"解析到的最后一行"。

### 6.7 写通路与最小包

`ExcelDocument.write` 与 `ExcelWriter` 共用 `PackageWriter`（四个小部件）与
`WorksheetXmlWriter`（worksheet 正文），差别只在 worksheet 的数据来源：

```
ExcelDocument.write：模型 → WorksheetXmlWriter（一次一行，行来自 Worksheet 的稀疏映射）
ExcelWriter        ：Iterator<RowData> → WorksheetXmlWriter → addFileStream
```

条目顺序（两个入口一致）：

```
1. [Content_Types].xml      ← 必须第一
2. _rels/.rels
3. xl/workbook.xml
4. xl/_rels/workbook.xml.rels
5. xl/worksheets/sheetN.xml （addFileStream）
6. xl/styles.xml
```

`PackageWriter` 用 `f_xml` 的 DOM + `XmlWriter`（小部件几十 KB，DOM 足够）。
**`r:id` 属性必须手工构造 `XmlAttribute(QName(local:"id", prefix!: Some("r"), uri!: Some(R_NS)), …)`
并 `push` 进 `element.attributes`**——`XmlElement.setAttr` 只生成无前缀 `QName`
（`XmlNode.cj:169`），写出来的 `r:id` 会变成字面名，Excel 直接报错（`baseline.md` §3）。

`[Content_Types].xml` 的生成 SHALL 由 sheet 清单**一次性**拼好（sheet 数量在 `write()` 开始
或 `ExcelWriter` 构造时就已确定）。

### 6.8 `WorksheetXmlWriter`

```
writeRow(RowData) → buf
  满 8 KB 或行结束 → output.write(buf.bytes())   // 这里的 output 是喂给 addFileStream 的流
```

结构：

```cangjie
internal class WorksheetXmlWriter {
    init(output: OutputStream)
    func begin(dimension: ?String)              // <worksheet> + [<dimension>] + <sheetData>
    func row(r: RowData)                        // <row r ht> + <c>* + </row>
    func end(merged: ArrayList<String>)         // </sheetData> + [<mergeCells>] + </worksheet>
}
```

它实现一个**惰性 `InputStream`** 供 `ZipWriter.addFileStream` 拉取（`addFileStream` 只吃
`InputStream`）：`begin` 之后的行写入先落在 8 KB 缓冲，缓冲满时把字节推进一个内部队列，
`read(buffer)` 从队列取；队列空且未结束时，再回头问调用方的 `Iterator<RowData>` 要下一行。
这就是设计 §2.6.7 的"三段拉模式"，**不额外起线程**。

> 实现细节：`read()` 内部循环"队列空 → 生成下一行 → 再取"，直到队列非空或数据结束。
> 这是把"生产者"内联进 `read()`，语义上仍是拉模式。

**转义**：与 `f_xml.Escaper` 同表（`&`/`<`/`>`/`\r` 文本；加 `"` 属性）。差异只有非法字符：
`f_xml` 抛 `XmlException`（`Escaper.cj:31`），`f_excel` **剔除 + `ControlCharStripped`**——
因为设计 §10 明确"写入文本含控制字符 → 剔除并记 warning，不抛异常"，
知识库场景下"少一个不可见字符"远好于"整份导出失败"。两套实现的**合法字符输出逐字节一致**
由用例钉住（`f-excel-writer` 的「与 f_xml 转义一致」）。

**数字格式化**（设计 4.3）：见 §10 R1。策略固定为：

```
if (v 是 NaN 或 ±Inf) → 抛 ExcelException
if (v == trunc(v) 且 |v| < 1e15) → Int64(v).toString()
else → 最短往返串（若 std 的 toString 不满足，退化为 17 位有效数字再裁剪尾随 0）
```

**文本长度校验放在写之前**（32767 字符按 **rune** 计，不是字节——Excel 的上限是字符数）。

### 6.9 流式读的生命周期

```
open(path)  → ZipReader(path)                    // File.seek
open(input) → spool 到临时文件 → ZipReader(tmp)   // spool = true（默认）
            → ZipReader(input)                    // spool = false，全量缓冲 + SpoolDisabled

rows(sheet):
  确定部件路径 → ZipReader.open(path) → XmlPullParser(input)
  new WorksheetParser(parser, StreamRowSink()) → RowReader
RowReader.next():
  幂等：已 None → None；已 close → 抛
  推进 parser 直到产出下一条 RowData 或结束（结束时把合并区域交给 reader）
close(): 关闭条目流；ExcelSheetStream.close(): 关闭所有 reader + 删临时文件 + 关 ZipReader
```

**临时文件策略**：拷入用 64 KB 固定缓冲（`baseline.md` §5 的临时目录四级解析；
`f_zip` 的 `TempSpill` 是包内实现，不 import）。`close()` 删除；异常路径 `try-finally` 清理。

**并发**：`sharedStrings` 只读共享安全；每个 `RowReader` 有独立 `XmlPullParser` 与独立条目游标。
但同一个 `ExcelSheetStream` 上多线程同时 `next()` 会让"谁先拿到解析器"变得不可预期，
类注释 SHALL 写明"顺序交替可以，多线程同时 next 不可以"。

**合并区域的时序**：`RowReader.mergedRanges()` 在 `next()` 返回 `None` 之后才有值——
因为 `<mergeCells>` 在 `<sheetData>` 之后。读过程中调用返回空数组 + `MergedRangesUnavailable`
（返回空数组而不是 `None`，避免调用方误以为"没有合并"）。`lastMergedRanges(sheet)` 给
"读完但没有保留 reader"的场景。

### 6.10 流式写的状态机与校验

```
init: 校验 sheetNames → 写四个小部件 → Writing
writeSheet: 校验名字/顺序 → 写 <worksheet> 骨架 → 逐行消费迭代器 → 写 </worksheet> → Writing
finish: 写 styles.xml → ZipWriter.close()（中央目录 + EOCD）→ Finished
任一步抛异常 → Failed
```

**校验点**（全部抛 `ExcelException`，不静默修正）：

| 校验 | 时机 |
|---|---|
| `name` 与 `sheetNames[n]` 一致 | `writeSheet` 进入时 |
| `row.index` 严格递增 | 每行 |
| `row.index ∈ [1, 1048576]` | 每行 |
| `cell.col ∈ [1, 16384]` 且行内升序 | 每个 cell |
| 文本 ≤ 32767 字符、公式 ≤ 8192 字符 | 每个 cell |
| 状态必须是 `Writing` | 每个入口 |

**为什么失败不跳过坏行**：设计 §2.6.7——"一张缺行的表比一个明确的异常更难排查"。
`Failed` 之后所有入口直接抛，`rowsWritten` 冻结在失败时的值，供调用方判断产物残缺位置。

### 6.11 错误与告警

读取侧宽容（记 warning，继续）；写入侧严格（抛异常）。映射见 `f-excel-cell-model` 的
`ExcelWarningKind` 表与设计 §10 的对照。三条例外要单独说明：

1. **`SharedStringIndexOutOfRange`**：`t="s"` 越界只影响一格，按 `Empty` 处理。
2. **`StylesMissing`**：缺 `styles.xml` 时日期识别全部失效（退回 `Number`），
   记一条 summary 级 warning，不逐格刷屏。
3. **`ControlCharStripped`**：一个单元格内多个非法字符只记一条（消息带首个码点与总数）。

## 7. 最小 `styles.xml` 的固定内容

M1 没有样式池，`cellXfs` 是一个**编译期常量表**：

| `s` | `numFmtId` | 用途 |
|---|---|---|
| 0 | 0 | General（默认） |
| 1 | 14 | 纯日期（当天 00:00:00） |
| 2 | 22 | 日期 + 时间 |
| 3 | 20 | 纯时间 |
| 4 | 0 + `applyNumberFormat="0"` | 预留（M2-a 接管前不使用） |

`fonts` / `fills` / `borders` / `cellStyleXfs` / `cellStyles` 按设计 6.1/6.4 的硬约定写：

```xml
<fonts count="1"><font><sz val="11"/></font></fonts>
<fills count="2">
  <fill><patternFill patternType="none"/></fill>
  <fill><patternFill patternType="gray125"/></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="4">…</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
```

`fills[1]` 是 `gray125` 不是白色——这是 ECMA-376 的硬约定，写反了 Excel 报"需要修复"
（设计 6.1 已强调，本设计再钉一次，因为它是最常见的"文件损坏"来源）。

M2-a 落地时这张表会被真正的 `StylePool` 取代（`s` 变为运行期分配），对调用方无影响。

## 8. 与设计文档的差异（9 项）

| # | 差异 | 理由 | 影响 |
|---|---|---|---|
| 1 | `ExcelDocument.init(path: Path)` 内部转 `String` 传给 `ZipReader` | `f_zip` 只有 `ZipReader(path: String)`（`ZipReader.cj:61`） | 公开 API 仍是 `Path`，内部一行转换 |
| 2 | `ExcelReadOptions` 不含 `eager` / `loadTheme` | `eager=false` 是 M3；`loadTheme` 依赖 M2 的 theme 解析 | 少两个"声明了但无声失效"的字段 |
| 3 | `Cell.numberFormat: ?NumberFormat` 而非 `style: ?CellStyle` | `CellStyle` 是 M2-a；M1 兑现不了字体/填充，提前暴露会静默丢样式 | M2-a 改为 `style: ?CellStyle` 并保留 `numberFormat` 便捷形参 |
| 4 | `styles.xml` 是固定常量表，不是"样式池 + 后写" | 样式池存在的理由是"第 100 万行才出现新样式"（设计 2.6.4）；M1 没有用户样式 | M2-a 引入池，条目顺序（styles 最后）不变 |
| 5 | worksheet / sharedStrings 由 f_excel 自带 `WorksheetXmlWriter` 输出 | `XmlWriter` 无增量接口，`Escaper` 包内私有（`baseline.md` §3）；设计 2.6.7 已定该组件 | 两套转义并存，用「与 f_xml 一致」用例钉住 |
| 6 | `SheetWriteOptions` 只有 `dimension` | `columns`/`freezePane` 属 M2（行高列宽/视图）；`maxCellStyles`/`styleBytesWarnThreshold` 依赖样式池 | 少四个暂无实现的字段 |
| 7 | 合并区域挂 `RowReader.mergedRanges()` + `ExcelSheetStream.lastMergedRanges(sheet)` | 设计 §2.7.2 的 API 列表漏了它、§2.7.6 又写了 `ExcelSheetStream.mergedRanges()`；合并区域属于"某张表"，挂在 reader 上语义更准 | 比设计多一个 `lastMergedRanges`，`RowReader` 多一个方法 |
| 8 | 不含 `DocumentProperties` / `docProps/core.xml` | 设计 §2.2 列了 `properties`，但 M1 里程碑与 §4.1 第 7 步都是"可选"；无实际字段可填时会变成死 API | M2 随样式/公式一起补，届时不破坏现有调用 |
| 9 | 不提供 `StringWriteMode` 枚举 | 设计 §2.6.6 的两个值里 `SharedStrings` 要全量去重表，与"两端常量内存"是两套取舍，M2-e 收尾才做；单值枚举是假选择 | `ExcelWriteOptions` 只有 `date1904` |

## 9. 测试策略

### 9.1 分层

| 层 | 内容 | 量级 |
|---|---|---|
| 小函数单测 | 列号互转（8 组边界）、`CellRef.parse` 全表（12 行）、`parseRange`、serial ↔ DateTime（59/60/61、1904）、`formatCode` 判定（5.3.2 的"非日期"表 + `[h]` 表） | ~60 |
| 组件单测 | `sharedStrings`（拼接/preserve/rPh）、`WorksheetParser`（前缀/稀疏/缺 `r`/乱序）、`WorksheetXmlWriter`（转义/数字/上限） | ~50 |
| 读端集成 | 现场构造的 6 类夹具：最小表、前缀表、稀疏+乱序、合并、日期两种基准、公式 | ~20 |
| 写端集成 | 七种值、多 sheet、合并、日期三档、上限、`Failed` 状态机、`finish` 前不是有效包 | ~30 |
| 往返 | 值往返、通道等价、结构断言 | ~15 |

### 9.2 夹具策略

现场构造（测试内用 `f_zip.ZipWriter` 拼字符串部件）为主——**代码即夹具**，改一处
不用同步二进制文件；真实生成器样本（Excel / LibreOffice / WPS / openpyxl 各 1，
单份 ≤ 20 KB）入库存 `f_excel/testdata/`，覆盖"别人的前缀与顺序"。

### 9.3 落位

测试文件与实现同目录（`src/Xxx_test.cj`），理由同 `f_xml`：包外访问不到 `internal`
（`WorksheetParser`、`WorksheetXmlWriter`、`DateSerial` 的内部行为要同包断言）。

### 9.4 不做的测试

- 真实 Excel 自动化（无法在 CI 里跑）：改为人工验收清单（`f-excel-roundtrip`）。
- 性能门禁：只记录一条"1 万行 × 10 列往返耗时"的观测值。

## 10. 待实测项

| # | 项 | 怎么验 | 期望 | 不达标的处置 |
|---|---|---|---|---|
| R1 | `Float64.toString()` 的最短往返与整数形态 | 打印 `1.0` / `0.1` / `1e20` / `1.0/3.0`，再 `Float64.parse` 回比 | 整数不带 `.0`，小数 17 位内最短 | 不满足则按 §6.8 的"17 位 + 裁剪尾 0"自实现 |
| R2 | `DateTime` 与"自 1899-12-30 起的天数"互转的可用 API | 查 `std.time` 有无 `toUnixTimeStamp` / `ofEpoch` 一类，并验证零时区偏移 | 有稳定 API，且不受本地时区影响 | 无可用时用"年/月/日归一到儒略日"自算（不碰时区） |
| R3 | `File.createTemp(directory)` 与系统临时目录 API 的实际签名 | 读 `std.fs`，写一个最小用例 | 与设计 2.7.4 的描述一致 | 改用 `File.create(dir.join(随机名))` |
| R4 | `cjpm test` 的工作目录 | 用例里打印 `env.getWorkingDirectory()` | 模块根（`f_xml` 已实测） | 若否，`testdata/` 路径加 `CJPM_MODULE_ROOT` 候选 |

R4 已有先例（`f_xml` 实测为模块根），本变更只需复核一次。

### 10.1 实测记录

（实施时回填，见 `tasks.md` 0.3–0.5。）

## 11. 里程碑与出口

| 阶段 | 内容 | 出口 |
|---|---|---|
| P0 | `CellRef` / 列号 / `CellValue` / `RowData` / 异常告警 | 设计 §11.6 的小函数单测全绿 |
| P1 | `PackageReader` + `Worksheet` + 最小 worksheet 解析 | 能列出 sheet 名、读出 A1 的值 |
| P2 | `SharedStringTable` + `t` 类型表 | 文本/数字/布尔/错误全通 |
| P3 | `PackageWriter` + `WorksheetXmlWriter` + `ExcelDocument.write` | **Excel 能打开不报修复**（本变更最关键的一步） |
| P4 | `DateFormat` + `DateSerial` + 日期绑样式 | 日期往返到秒一致；`autoDetectDate` 开关生效 |
| P5 | 合并单元格 + 多 sheet | `mergedValue` 正确，多 sheet 结构与顺序正确 |
| P6 | `ExcelSheetStream` / `RowReader` | 与整文档通道逐行等价；`close` 删临时文件 |
| P7 | `ExcelWriter` | 与 `ExcelDocument.write` 输出同字节；失败状态机正确 |
| P8 | 往返 + 结构断言 + README | 三条等价性全绿；Excel 人工验收 4 条通过 |

**出口条件**：`cjpm build` 无 ERROR；`cjpm test` 全绿；`f-excel-roundtrip` 的
「真实 Excel 人工验收」4 条有记录；`f_excel/doc/f_excel模块设计.md` 按 §8 回填到 v0.9。
