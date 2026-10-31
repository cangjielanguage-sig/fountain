# f_excel —— 仓颉 Excel（OOXML）解析器 / 生成器设计

> 版本 **v0.14** ｜ 2026-10-31 ｜ 状态：M1 + M2 + M4 已实施，M3 部分
>
> 定位：fountain 模块。单个 `ExcelDocument` 类同时承担解析与生成。
> 依赖 `fountain::f_zip`（读写 OOXML 包）与 `fountain::f_xml`（XML 解析/生成）。
>
> **v0.14 变更**
> - 第 17 章：M3 磁盘索引、`eager=false`、数组广播的实施记录与剩余缺口
>
> **v0.13 变更**
> - 第 16 章：M4 条件格式（解析/求值/dxfs 写回）的实施记录
> - M3 状态：数组广播与动态数组、ods 评估已落地；磁盘索引/按需解析/350 函数/紧凑存储未做
>
> **v0.12 变更**
> - 第 15 章：M2-a 样式、M2-b/c 公式引擎（143 函数）、M2-d 时长与富文本的实施记录与差异
>
> **v0.11 变更**
> - 新增 14.5：`Worksheet.addImage` 最小图片写入（png/jpeg、两单元格锚定）；读侧不导入
>
> **v0.10 变更**
> - M1 落地后的差异、R1–R4 实测与新增前置能力记入第 14 章
>
> **v0.9 变更**
> - 前置能力落地：`f_zip.ZipWriter.openEntry(name): OutputStream`（推模式条目流）与
>   `f_xml.XmlWriter` 增量接口（`startElement` / `text` / `endElement` / `emptyElement`，
>   f_xml v1.2）
> - **流式写改推模式**：逐行事件直接写条目流，不再需要把行迭代器包成惰性 `InputStream`（2.6 / 2.6.7）
> - **worksheet 生成交给 `f_xml.XmlWriter`**：f_excel 不再自写 XML 发射器与转义表，
>   只保留控制字符剔除与 Excel 上限校验（2.6.7 / 8.1）
>
> **v0.8 变更**
> - 新增 **2.7 流式解析（边读边解析）**：`ExcelSheetStream` / `RowReader` 拉模式逐行产出，
>   内存与行数无关；`Path` 输入真流式，`InputStream` 输入落临时文件后同样真流式
> - 新增 **2.6.7 流式输出的字节路径与失败语义**：行迭代器 → `f_xml.XmlWriter` 增量写 →
>   `f_zip.openEntry` 推模式 → deflate → output 的通路、背压、flush 粒度、失败即残缺的约定
> - 明确流式读的**语义缺口**：`mergeCells` 在 `sheetData` 之后，逐行流式期间拿不到合并区域
> - 里程碑调整：流式读提到 **M2-f**（与流式写对称），M3-a 改为流式读增强（大 `sharedStrings` 磁盘索引）
>
> **v0.7 变更**
> - `Duration` 溢出行为确认：**`*` 与 `toSeconds()` 都会抛**，反向转换改用 try-catch 兜住（5.5.4）
> - `Duration → serial` 不再假设 `toSeconds()` 的边界，一律捕获 `ArithmeticException`
> - 样式池超限的**错误文案分两版**（触到平台默认 vs 触到 Excel 硬限）（2.6.4.5）
> - `fonts[0]` 必须写一条，最少写 `<sz val="11"/>`（6.4）
>
> **v0.6 变更**
> - `maxCellStyles` **按 `os` 分档**：Linux 64000，其他 8192（2.6.4.1）
> - **`Font.name` 改为 `?String`**：`None` 表示不写 `<name>`，用 Excel 自己的默认（6.4）
> - 修正 `TimeSpan` 与 `Duration` 的范围说明：**约 292 年**，不是 106 天（13.2）
>
> **v0.5 变更**
> - **样式池上限改回条目数 64000**，对齐 Excel 硬限与 excelize 的 `MaxCellStyles`（2.6.4.1）；
>   字节预算降级为"只告警"的 `styleBytesWarnThreshold`
> - **`CellStyle` 及其嵌套类型全部改为 `struct` + `let`**，消除"调用方必须复用实例"的坑（2.6.4.2）
> - 新增**三层查找**去重（引用→结构哈希→逐字段），并说明为什么不能"出错后再深比较"（2.6.4.3 / 2.6.4.4）
> - TimeSpan 判定（`[Red][h]:mm` 这类混合方括号）补单测项（11.6）
>
> **v0.4 变更**
> - **`CellValue.TimeSpan(Duration)` 确认加入**（M2）：`[h]:mm:ss` 不再硬塞成 `Date`
> - **`dxfs` 语义解析确认要做**，排 **M4**（因为依赖公式引擎求值条件表达式）；新增 M4 里程碑
> - **样式池上限改为字节预算** `maxStyleBytes = 1 MB`，不再是条目数 4096（2.6.4 详细解释）
>   —— **该决定在 v0.5 已被推翻**，见上方 v0.5 变更
>
> **v0.3 变更**
> - 2.1 重写：澄清 `init()` 不是"新建 `std.fs.File`"，也不是"从空缓冲区解析"（后者是失败路径）
> - **去掉对 `f_io.ByteBuffer` 的依赖**（`f_io` 已决定保持现状、不增强，f_excel 也就不需要它做后端）
> - 2.4 新增：`CellRef` 值类型，`(row, col)` 与 `"A1"` 双套访问 API
> - 2.5 新增：`ExcelReadOptions`，日期自动识别默认开
> - 2.6 新增：流式写入（迭代器拉模式，`f_zip` 零改动）
> - 第 6 章新增：完整样式读写（**M2**）
> - 第 7 章新增：公式求值引擎（**M2**）
> - 里程碑体系改为 M1 / M2 / M3，与 f_xml 对齐
>
> v0.2 变更：v0.1 名为 `f_xlsx`，现统一改名为 **`f_excel`**（模块名与文件格式 xlsx 解耦，将来支持 ods 时不用再改名）。

---

## 0. 范围与结论

| 项 | 结论 | 里程碑 |
|---|---|---|
| 读取 | worksheet 单元格、共享字符串、数字/布尔/错误、日期识别、合并单元格、富文本 | M1 |
| 写入 | 多 sheet、文本/数字/布尔/日期、合并单元格、最小可用包 | M1 |
| 样式 | **完整读写**（字体/填充/边框/数字格式/对齐/保护/theme 颜色）；`CellStyle` 为不可变 struct | **M2** |
| 公式 | **读取保留原文 + 缓存值**；**求值引擎在 M2 实现**（默认不自动重算，须显式调用） | **M2** |
| 时长 | **`CellValue.TimeSpan`**：`[h]:mm:ss` 等经过时间 | **M2** |
| 条件格式 | `dxfs` 只存取（M2）；**语义解析与求值** | **M4** |
| 单元格访问 | `(row, col)` 与 `"A1"` **两套都提供**，共用 `CellRef` | M1 |
| 日期识别 | **默认开**，可由 `ExcelReadOptions.autoDetectDate` 关闭 | M1 |
| 流式写入 | **提供**，行迭代器驱动，边生成 XML 事件边压缩写出，内存与行数无关 | M2 |
| 流式读取 | **提供**，行迭代器拉模式（`ExcelSheetStream`），**边读边解析**，内存与行数无关 | M2 |
| 图表 / 图片 / 数据透视表 | 不支持（读取时跳过，写入时不生成） | — |
| 依赖 | `f_zip`、`f_xml`。**不依赖 `f_io`** | — |

**关键前提：XML 解析交给 `f_xml` 模块。** 早先设想的"自写标签扫描器"已废弃——命名空间前缀（`<row>` vs `<x:row>`）用字符串扫描处理不干净，必须靠正规的 QName 解析（见 8.1 与 `f_xml模块设计.md`）。

---

## 1. 依赖与调用关系

```
f_excel
├── f_zip            读写 OOXML 包（xlsx 本质是 ZIP）
│   ├── f_util       crc32
│   └── stdx.compress.zlib
└── f_xml            XML 事件解析 / DOM 生成
```

**f_excel 不直接依赖 `f_io`。** 读走 `ZipReader(input)` 或 `ZipReader(path)`，写走 `ZipWriter(output)`，中间不经过任何 `ByteBuffer`。理由见 2.1。

xlsx 文件结构：

```
[Content_Types].xml
_rels/.rels
xl/workbook.xml
xl/_rels/workbook.xml.rels
xl/worksheets/sheet1.xml
xl/worksheets/sheet2.xml
xl/sharedStrings.xml
xl/styles.xml
xl/theme/theme1.xml        （有 theme 颜色时必须）
docProps/core.xml          （可选）
docProps/app.xml           （可选）
```

---

## 2. API 设计

### 2.1 `init()` 的语义：三个概念的区分

用户给定的骨架：

```cangjie
package fountain::f_excel

public class ExcelDocument {
    /// 从流解析
    public init(input: InputStream)
    /// 新建空文档
    public init()
    /// 序列化输出
    public func write(output: OutputStream)
}
```

**问题：`init()` 是不是"新建一个空的 `std.fs.File`"？**

**不是。** 而且"新建空文档"和"从空 ByteBuffer 解析"这两条路径**结果并不相同**——后者根本得不到文档，它是失败路径。

#### 2.1.1 为什么 `init()` 不可能创建 `std.fs.File`

四条理由，从强到弱：

**（1）语言层面不成立。** `std.fs.File` 没有任何无参构造形式，全部需要路径：

```cangjie
File.create(path: String, ...)      // 需要在磁盘上创建
File.open(path: String, ...)        // 需要已存在的文件
File.createTemp(directory: String)  // 需要目录
```

`init()` 拿不到路径，就无从创建 `File`。

**（2）职责层面冲突。** 如果 `ExcelDocument` 内部已经绑定了一个 `File`，那 `write(output: OutputStream)` 这个签名就没有意义了——数据该写进内部 `File`，何必再传一个 `output`。有 `write(output)` 就说明**文档不持有输出目标**。

**（3）资源层面不干净。** `File` 是 OS 句柄，有打开/关闭生命周期。让一个纯数据对象持有句柄，会带来三个麻烦：构造后必须保证关闭（异常路径呢？）、对象不能被随意复制、并发访问同一路径时行为依赖 OS。

**（4）完全没必要。** 新建的文档在 `write(output)` 之前，全部状态就是内存里的 workbook 模型。没有任何环节需要文件、ZIP 或 XML。

#### 2.1.2 "从空 ByteBuffer 解析"为什么是失败路径

假设真的走这条路：

```
空 ByteBuffer
  → ZipReader(input)
  → 找 EOCD（文件末尾 22 字节起，签名 PK\x05\x06）
  → 找不到
  → 抛 ZipException("不是有效的 ZIP 文件")
```

空缓冲区连 ZIP 的 EOCD 都没有，**解析在第 0 步就抛异常**。它不会"得到一个空文档"，它是明确的错误。

所以原文档里"两者结果相同，只是路径不同"这个前提，需要纠正：

| 做法 | 实际发生什么 | 得到什么 |
|---|---|---|
| **新建空文档**（`init()`） | 在内存里构造 workbook 模型 | 1 个空 sheet + 默认样式表 + 空字符串表 |
| 用空缓冲区作**输出后端** | 只是"将来写到哪"的容器，不做任何解析 | 模型仍是空的，但这不是解析 |
| 从空缓冲区**解析** | `ZipReader` 找不到 EOCD | **抛 `ZipException`**，拿不到文档 |

第二行才是需求里"`this(ByteBuffer)`"想表达的意思：**不是解析，而是给输出准备一个内存后端**。

#### 2.1.3 结论与实现

`init()` = **纯内存模型初始化**，不发任何 I/O：

```cangjie
public init() {
    this.workbookPr = WorkbookPr()                 // 默认 1900 日期系统
    this.sheets = ArrayList<Worksheet>()
    this.sheets.add(Worksheet("Sheet1"))           // Excel 新建工作簿的默认行为
    this.stylePool = StylePool.withDefaults()      // 至少含 Normal 样式（cellXfs[0]）
    this.sharedStrings = SharedStringTable()
    this.theme = Theme.default()                   // 无 theme1.xml 时的默认调色板
}

public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions()) {
    // 到这里才第一次构造 ZIP
}
```

第一个 sheet 命名为 `Sheet1` 是刻意的——Excel、LibreOffice、WPS 新建工作簿都是这个名字。叫 `"Sheet"` 或者空字符串会让打开后的体验很怪。

#### 2.1.4 顺带：去掉 ByteBuffer 依赖

v0.2 曾论证"用 `f_io.ByteBuffer` 做序列化后端"，理由是它比标准库多 `seekReading`/`seekWriting`。**这个理由现在不成立了**：`f_io` 已决定保持现状不增强，而这些能力在 f_excel 的场景里本来就不需要——

| 原以为需要的能力 | 实际是否需要 |
|---|---|
| `seekReading` / `seekWriting`（回填长度） | **不需要**。回填发生在 ZIP 层，由 `f_zip` 的 data descriptor 解决（见 `f_zip/doc/f_zip模块设计.md` 3.2） |
| `bytes(): Array<Byte>` 零拷贝给 ZipWriter | **不需要**。`ZipWriter.openEntry(name)` 直接给条目输出流，`XmlWriter` 写进去即可 |
| `<: IOStream` 双向 | **不需要**。读写是两个独立入口，不共享同一个对象 |
| `reserve` / `clone` | **不需要** |

于是依赖链简化成：

```cangjie
public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())
    → ZipReader(input)            // f_zip 内部全量缓冲
public init(path: Path, options!: ExcelReadOptions = ExcelReadOptions())
    → ZipReader(path)             // f_zip 走 File.seek，省内存
public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions())
    → ZipWriter(output) + openEntry(...) + XmlWriter 增量写
```

传 `f_io.ByteBuffer` 进来也照常工作——它实现了 `InputStream`/`OutputStream`。**但 f_excel 不 import 它**，和 f_xml 的 1.4 节保持同一条原则。

---

### 2.2 完整接口

```cangjie
public class ExcelDocument {
    // —— 构造 ——
    public init()                                                      // 新建空文档，见 2.1
    public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())
    public init(path: Path, options!: ExcelReadOptions = ExcelReadOptions())

    // —— 输出 ——
    public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions())
    public func write(path: Path, options!: ExcelWriteOptions = ExcelWriteOptions())

    // —— sheet 访问 ——
    public func sheets(): ArrayList<Worksheet>
    public func sheet(name: String): ?Worksheet
    public func sheetAt(index: Int64): ?Worksheet
    public func sheetCount(): Int64
    public func addSheet(name: String): Worksheet
    public func removeSheet(name: String): Bool
    public func renameSheet(oldName: String, newName: String): Bool

    // —— 文档属性 ——
    public prop date1904: Bool                                         // 由 workbookPr 决定，可改
    public var properties: DocumentProperties

    // —— 公式（M2）——
    public func recalculate(options!: CalcOptions = CalcOptions()): CalcReport
    public func recalculate(sheet: String, options!: CalcOptions = CalcOptions()): CalcReport
    public func evaluate(sheet: String, ref: CellRef): ?CellValue

    // —— 样式池（M2）——
    public func styleOf(sheet: String, ref: CellRef): ?CellStyle
    public func setStyle(sheet: String, ref: CellRef, style: CellStyle): Unit
    public func theme(): Theme

    // —— 诊断 ——
    public func warnings(): ArrayList<ExcelWarning>
}

public class Worksheet {
    public prop name: String

    // 范围
    public func rowCount(): Int64                                      // 最大已用行号，0 表示空
    public func colCount(): Int64
    public func dimension(): ?String                                   // "A1:C100"

    // —— 单元格访问：(row, col) 与 "A1" 双套，见 2.4 ——
    public func cell(row: Int64, col: Int64): ?CellValue
    public func cell(ref: String): ?CellValue
    public func cell(ref: CellRef): ?CellValue

    public func setCell(row: Int64, col: Int64, value: CellValue): Unit
    public func setCell(ref: String, value: CellValue): Unit
    public func setCell(ref: CellRef, value: CellValue): Unit

    public func clearCell(row: Int64, col: Int64): Unit
    public func clearCell(ref: String): Unit

    // 批量
    public func range(from: String, to: String): Array<Array<CellValue>>
    public func rowValues(row: Int64): Array<(Int64, CellValue)>        // 稀疏行，返回 (col, value)

    // 合并单元格
    public func mergedRanges(): ArrayList<String>                       // ["A1:B1", "C3:E3"]
    public func mergedRangeAt(row: Int64, col: Int64): ?String
    public func mergedValue(row: Int64, col: Int64): ?CellValue         // 取所属区域左上角的值
    public func merge(from: String, to: String): Unit
    public func merge(range: String): Unit                              // "A1:B1"
    public func unmerge(range: String): Bool

    // 富文本（M2）
    public func richText(row: Int64, col: Int64): ?RichText

    // 行高列宽（M2）
    public func columnWidth(col: Int64): ?Float64
    public func setColumnWidth(col: Int64, width: Float64): Unit

    public func rowHeight(row: Int64): ?Float64
    public func setRowHeight(row: Int64, height: Float64): Unit
}
```

`Worksheet` 的 `cell`/`setCell` 三组重载不会产生歧义：`cell(1, 1)` 匹配 `Int64` 版本，`cell("A1")` 匹配 `String` 版本，`cell(CellRef.parse("A1")!)` 匹配 `CellRef` 版本。参数类型互不重叠。

---

### 2.3 单元格值模型

```cangjie
public enum CellValue {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)                       // "#DIV/0!" 之类
    | Date(DateTime)                      // 由样式识别出的日期
    | Formula(String, Option<CellValue>)  // 公式原文 + 缓存值
}
```

**`Formula` 保留原文而不自动求值**：M1 只解析，M2 提供显式求值（第 7 章）。读取时永远不去碰公式——打开一个 10 万行带公式的表，全量重算可能几秒到几十秒，而知识库场景只要文本，根本不需要重算。

**`Text(String)` 是平坦化后的结果。** 富文本（`<is><r>` 分段）的样式信息不进 `CellValue`，而是另走 `richText()` 接口。理由：让 99% 的调用方（只要文本）不必面对一个联合体，而需要样式的少数调用方多写一行。

```cangjie
public class RichText {
    public let runs: Array<TextRun>
    public func text(): String                     // 所有 run 拼接
}
public class TextRun {
    public let text: String
    public let font: ?Font                          // 缺省表示继承单元格样式
}
```

---

### 2.4 单元格引用：`CellRef` 与双套 API

需求：`(row, col)` 与 `"A1"` 都提供。

**不建议在 `Worksheet` 里散着写两套解析代码**，而是引入一个值类型，把解析、格式化、绝对/相对标志全部收进去：

```cangjie
public struct CellRef {
    public let row: Int64        // 1 起
    public let col: Int64        // 1 起
    public let rowAbs: Bool      // $ 前缀
    public let colAbs: Bool

    /// 解析 "A1" / "$A$1" / "a1" / "A01"。非法返回 None
    public static func parse(s: String): ?CellRef
    /// 解析 "A1:B2" 形式的区域
    public static func parseRange(s: String): ?(CellRef, CellRef)

    /// 格式化，不带 $
    public func toString(): String
    /// 格式化，保留 $ 前缀（公式原文里用）
    public func toA1(): String

    public operator func ==(other: CellRef): Bool
    public operator func <(other: CellRef): Bool      // 先行后列
}
```

`CellRef` 用 `struct` 而非 `class`：它是纯值，没有身份，拷贝廉价，可以被放进 `Array`/`HashMap` 的键。

#### 2.4.1 列字母 ↔ 列号的转换

```
字母 → 列号：
  col = 0
  for ch in letters:
      col = col * 26 + (ch - 'A' + 1)      // 'A'=1 ... 'Z'=26

列号 → 字母：
  while col > 0:
      col -= 1
      buf.prepend('A' + col % 26)
      col /= 26
```

**这是最容易写错的小函数，务必单测**：`A→1, Z→26, AA→27, AZ→52, BA→53, ZZ→702, AAA→703, XFD→16384`。

#### 2.4.2 解析规则

| 输入 | 结果 | 说明 |
|---|---|---|
| `"A1"` | row=1, col=1 | |
| `"a1"` | row=1, col=1 | 小写接受 |
| `"$A$1"` | row=1, col=1, abs 均 true | `$` 只对复制粘贴有意义，单纯访问时忽略 |
| `"A01"` | row=1, col=1 | 前导零接受 |
| `"A"` | `None` | 缺行号 |
| `"1"` | `None` | 缺列号 |
| `"A1B"` | `None` | 尾随垃圾 |
| `"XFE1"` | `None` | 超列上限（16384） |
| `"A1048577"` | `None` | 超行上限（1048576） |
| `""` | `None` | |

超出 Excel 上限的引用一律 `None` 而不是"尽力返回"——因为写入这种引用会产生 Excel 打不开的文件。

#### 2.4.3 越界 / 空单元格的约定

`cell()` 返回 `?CellValue`，三种情况都返回 `None`：

1. 坐标越界（< 1 或超上限）
2. 单元格从未出现过（稀疏表里没有这一项）
3. 单元格被显式清空

**`Empty` 与 `None` 的区别**：
- `None` = "这里没有记录"
- `Some(Empty)` = "这里有记录，但值是空的"（例如 `<c r="A1"/>` 这种只有样式没有值的单元格）

调用方通常只需判断 `None`。需要区分"有样式但无值"的场景（例如导出一张保留格式的空表），才去分辨两者。

---

### 2.5 读取选项：日期识别默认开

```cangjie
public class ExcelReadOptions {
    /// 日期自动识别。默认 true。
    /// 关闭后所有日期单元格都按 Number 返回（原始序列号）
    public var autoDetectDate: Bool = true

    /// 强制日期基准。None = 按 workbookPr 的 date1904 自动判定
    public var date1904: ?Bool = None

    /// 是否解析 styles.xml。关闭可省内存，但 autoDetectDate 会失效
    public var loadStyles: Bool = true

    /// 是否解析 sharedStrings.xml。关闭则 t="s" 的单元格变成 Empty
    public var loadSharedStrings: Bool = true

    /// 是否解析 theme1.xml。关闭则 theme 颜色退化为默认调色板
    public var loadTheme: Bool = true

    /// 单 sheet 最大行数，0 = 不限
    public var maxRows: Int64 = 0

    /// 单 sheet 最大列数，0 = 不限
    public var maxCols: Int64 = 0

    /// 跳过这些名字的 sheet（大小写敏感）
    public var skipSheets: Array<String> = []

    /// 是否把所有 sheet 一次性全解析。false = 按需解析（M3）
    public var eager: Bool = true
}

public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())
```

**选项冲突的消解：**

| 组合 | 行为 |
|---|---|
| `autoDetectDate = true` 且 `loadStyles = false` | **不报错**。自动把 `autoDetectDate` 降级为 `false`，并记一条 `ExcelWarning`。宽容优于打断 |
| `date1904 = Some(x)` 且 workbook 里写了相反的值 | 以选项为准，记一条 warning |
| `maxRows` 截断 | 截断后记 warning，不抛异常 |

**为什么日期识别默认开**：知识库场景下，一张日期列如果原样返回 `45231`，下游要么不知道怎么处理，要么得自己再实现一遍序列号转换。默认开是对的，误判是个别现象，有开关可关。

---

### 2.6 流式写入（M2）

需求："需要流式写入 API（应对超大表）"。

`f_zip` 提供两条流式写路径：拉模式 `addFileStream(name, input)` 与**推模式** `openEntry(name): OutputStream`。
f_excel 的对外接口仍是行迭代器（调用方最自然的形态），内部走**推模式**：逐行取 `RowData` →
转成 XML 片段 → 写进 `openEntry` 返回的条目流，由 f_zip 边压边写。不再需要"把迭代器包成
惰性 `InputStream`"的适配层。

```cangjie
public class ExcelWriter {
    /// sheetNames 必须在这里一次给全，理由见 2.6.2
    public init(output: OutputStream,
                sheetNames: Array<String>,
                options!: ExcelWriteOptions = ExcelWriteOptions())

    /// 逐个 sheet 写入。调用顺序必须与构造时的 sheetNames 一致
    public func writeSheet(name: String, rows: Iterator<RowData>,
                           options!: SheetWriteOptions = SheetWriteOptions()): Unit

    /// 写共享字符串表（仅 StringMode.SharedStrings 时有效，必须在所有 sheet 之后）
    public func finish(): Unit
}

/// 一行。cells 必须按 col 升序
public struct RowData {
    public let index: Int64                       // 1 起，必须严格递增
    public let cells: Array<Cell>
    public let height: ?Float64
    public init(index: Int64, cells: Array<Cell>, height!: ?Float64 = None)
}

public struct Cell {
    public let col: Int64
    public let value: CellValue
    public let style: ?CellStyle                  // None = 用默认样式（cellXfs[0]）
    public init(col: Int64, value: CellValue, style!: ?CellStyle = None)
}

public class SheetWriteOptions {
    /// use range。None = 省略 <dimension>（推荐），见 2.6.3
    public var dimension: ?String = None
    /// 列宽，必须在 sheetData 之前写出（schema 顺序强制）
    public var columns: Array<ColumnSpec> = []
    /// 冻结窗格。如 "A2" 表示冻结首行
    public var freezePane: ?String = None
    /// 样式种类数上限。按平台：Linux 64000，其他 8192。见 2.6.4.1
    public var maxCellStyles: Int64 = defaultMaxCellStyles()
    /// 样式池内存告警阈值（估算字节数）。只告警，不阻断。按平台分档
    public var styleBytesWarnThreshold: Int64 = defaultStyleWarnBytes()
}
```

典型用法：

```cangjie
let out = File.create("/tmp/big.xlsx")
let writer = ExcelWriter(out, ["明细"])
writer.writeSheet("明细", rows.iterator())     // rows 可以是数据库游标、CSV、另一个表
writer.finish()
```

`rows` 来自哪里都行——`ArrayList.iterator()`、数据库游标包装的迭代器、另一个文件流的解析器。**内存峰值 = 单行 + 压缩缓冲，与总行数无关。**

#### 2.6.1 为什么接口是迭代器而不是 `appendRow()`

推模式已经有了（`f_zip.ZipWriter.openEntry`），那为什么 f_excel 不直接暴露 `appendRow(RowData)`？

| 方案 | 评价 |
|---|---|
| `writeSheet(name, rows: Iterator<RowData>)` | **采纳**：调用方可以传数组迭代器、数据库游标、另一个文件的 `RowReader`；写入过程由 f_excel 驱动，异常与关闭时序集中在一处 |
| `appendRow()` 逐行推给 writer | 调用方要自己管"第几张 sheet、行号是否递增、何时 finish"，把状态机摊到业务代码里；对"把 A 表复制成 B 表"这类场景反而更啰嗦 |

迭代器覆盖了所有超大表场景——不管数据来自数据库游标、CSV、还是另一个 Excel，都能包成
`Iterator`。`appendRow` 只是写法上顺一点，不值得把状态机暴露出去。

#### 2.6.2 为什么 `sheetNames` 必须一次给全

xlsx 的 `[Content_Types].xml` 里，每个 worksheet 都有一个 `<Override PartName="/xl/worksheets/sheetN.xml" ContentType="..."/>` 项。这个文件必须在 ZIP 里**第一个**写出（OPC 读取器的惯例，虽然规范不强制顺序）。

流式写入时，第一个条目写出去就改不了了。所以 sheet 的数量和名字必须在写 `[Content_Types].xml` 之前确定，也就是在 `ExcelWriter` 构造时。

**这不是为了省事，而是 ZIP 顺序写的硬约束。** 替代方案是"先写占位、最后 seek 回填"，但那样要求 `output` 可 seek 且整个包不能被 deflate 流式输出——直接放弃流式。

写出的条目顺序：

```
1. [Content_Types].xml          ← 必须第一个
2. _rels/.rels
3. xl/workbook.xml
4. xl/_rels/workbook.xml.rels
5. xl/worksheets/sheet1.xml     ← 流式，大
6. xl/worksheets/sheet2.xml     ← 流式，大
...
7. xl/styles.xml                ← 后写，理由见 2.6.4
8. xl/sharedStrings.xml         ← 后写（若启用）
9. docProps/core.xml            ← 可选
   —— 中央目录 + EOCD ——
```

ZIP 条目顺序本身不强制与逻辑结构一致，`[Content_Types].xml` 之外的部件都可以任意排序。

#### 2.6.3 `<dimension>` 的取舍

worksheet 的 schema 是 `sequence`（有序），`<dimension>` 在 `<sheetData>` **之前**：

```
sheetPr?, dimension?, sheetViews?, sheetFormatPr?, cols*, sheetData, ...
```

流式写入时，写 `<sheetData>` 之前根本不知道数据有多大。三个选择：

| 方案 | 评价 |
|---|---|
| **省略 `<dimension>`**（默认） | ECMA-376 中 `minOccurs=0`，可省。Excel 打开时自己算 used range。代价是超大表首次打开的重绘可能慢一点。**采纳** |
| 调用方显式声明 | `SheetWriteOptions.dimension = "A1:C1000000"`。适合调用方已知范围的情况 |
| 占位后 seek 回填 | 要求 output 可 seek 且不能边压边写。**否决** |

同理 `<cols>` 也必须在 `<sheetData>` 之前，所以列宽信息通过 `SheetWriteOptions.columns` 预先给出——列宽本来就是"整列"属性，不是逐行推出来的，这个约束自然。

#### 2.6.4 样式池后写：解决"写到第一百万行才出现新样式"

流式写入的经典难题：前 10 万行都用一个样式，第 100001 行突然出现一个新字体。如果 `styles.xml` 必须写在最前面，就得预先知道所有样式——不可能。

**解法：把 `styles.xml` 放在所有 sheet 之后写。** ZIP 条目的顺序不要求与 OPC 逻辑一致。

具体做法：

1. 写单元格时，`style` 进 `StylePool.getOrAdd(style)` 得到一个索引 `s`
2. 单元格写 `s="7"`
3. 全部 sheet 写完后，`StylePool` 已收敛，按索引顺序输出 `xl/styles.xml`
4. `s="7"` 指向 `cellXfs` 的第 7 项，对得上

所以样式池是**流式场景下唯一随输入增长的内存结构**。

#### 2.6.4.1 上限怎么定：先看 excelize 与 Apache POI 怎么做

这个问题有成熟答案，不该自己拍。先看两个主流实现：

| | **excelize**（Go） | **Apache POI**（Java） |
|---|---|---|
| 上限形式 | **条目数**：`const MaxCellStyles = 64000` | **条目数**：受 Excel 自身限制，约 64000 |
| 去重方式 | 遍历已有序号表，**逐字段深比较**（`reflect.DeepEqual` 风格） | `XSSFCellStyle.equals()` 逐字段比较；`StylesTable` 线性查找 |
| 字节预算 | 无 | 无 |
| 超限行为 | 返回 `ErrCellStyles` | 写入成功但 Excel 打开时报"单元格格式太多" |

**两条关键事实：**

1. **64000 不是拍出来的，是 Excel 的真实上限。** 超过之后 Excel 打开会直接报
   "此工作簿中单元格格式太多"（Too many different cell formats）——**文件产出成功但用户打不开**，
   这是最糟的失败形态。所以上限应该对齐这个数，而不是对齐某个内存估算值。
2. **两个成熟实现都不用"字节预算"。** 因为它们约束的是"产出物能不能被 Excel 打开"，
   不是"进程占多少内存"。字节预算是过程指标，且估算有误差，用在 API 契约上不可解释。

**所以改回条目数：**

```cangjie
public class SheetWriteOptions {
    /// 样式种类数上限。按平台：Linux 64000，其他 8192
    public var maxCellStyles: Int64 = defaultMaxCellStyles()
    /// 样式池内存告警阈值（估算字节数）。只告警，不阻断。按平台分档
    public var styleBytesWarnThreshold: Int64 = defaultStyleWarnBytes()
}

@When[os == "Linux"]
private func defaultMaxCellStyles(): Int64 { 64000 }

@When[os != "Linux"]
private func defaultMaxCellStyles(): Int64 { 8192 }

@When[os == "Linux"]
private func defaultStyleWarnBytes(): Int64 { 16 * 1024 * 1024 }

@When[os != "Linux"]
private func defaultStyleWarnBytes(): Int64 { 2 * 1024 * 1024 }
```

告警阈值也分档的理由：OHOS 上 8192 种样式约 4 MB，若阈值还是 16 MB，**永远不会触发**，
等于没有告警。2 MB 是"约 4096 种样式"，用它作为手机上的预警线。

**为什么按平台分档**：

| 平台 | 默认 | 理由 |
|---|---|---|
| Linux（服务器 / 桌面） | 64000 | 对齐 Excel 硬限与 excelize。32 MB 样式池在服务器上可接受 |
| OHOS（手机 / 平板）/ 其他 | 8192 | 8192 × ~500 B ≈ 4 MB，手机可接受；且 8192 种样式在任何真实表格里都远超需求 |

**这是"内存保护"而不是"格式语义"**：8192 不是 Excel 的限制，是我们给低内存设备设的上限。
所以它可以在调用方明确知道自己在干什么时提高：

```cangjie
SheetWriteOptions(maxCellStyles: 64000)      // 手机上生成超大样式表，自己承担内存
```

**`os` 只是近似**：Linux 桌面也算 Linux，但它不是服务器。这个近似对本项目（OHOS + Linux 服务器）
够用；如果将来要跑 Linux 嵌入式，用 `SheetWriteOptions.lowMemory()` 显式覆盖。

两个参数职责完全不同，不要混：

| 参数 | 性质 | 超限行为 | 依据 |
|---|---|---|---|
| `maxCellStyles` | **格式语义** | 抛 `ExcelException` | Excel 打不开的硬边界 |
| `styleBytesWarnThreshold` | 内存诊断 | 记 warning | 64000 × ~500 B ≈ 32 MB，超过 16 MB 就该警惕 |

**为什么不是"1 MB 字节预算"**：1 MB ≈ 2000 种样式。这个数字会让一张
"按行应用不同日期格式"的报表（5000 行 × 各不相同的 `formatCode`）直接失败，
但那种文件 Excel 是能正常打开的——**我们凭什么拒绝一个 Excel 认可的文件**。

**OHOS 上的内存考虑**：64000 种样式约占 32 MB，手机上确实偏大。但这是"上限"，不是"预分配"——
实际用多少算多少。真要在低内存设备上收紧，用预设：

```cangjie
public static func lowMemory(): SheetWriteOptions {
    SheetWriteOptions(maxCellStyles: 8192, styleBytesWarnThreshold: 4 * 1024 * 1024)
}
```

#### 2.6.4.2 去重：三层查找，不是"靠调用方复用实例"

**先把 `CellStyle` 改成 `struct`。**

上一版用 `class` + "让调用方复用实例"来做快速去重，这是把库的设计缺陷转嫁给调用方：

```cangjie
// 反例：调用方没复用实例，每个单元格都新建
for (row in rows) {
    ws.setCell(...)
    ws.setStyle(row, col, CellStyle(font: Font(bold: true)))   // 每次都是新对象
}
```

`HashSet<CellStyle>` 按引用比会全部落空，64000 的池瞬间被撑满——而这本来只是**一种**样式。

**改成 `struct` + 全 `let` 字段**，问题从根上消失：

```cangjie
public struct CellStyle {
    public let numberFormat: NumberFormat
    public let font: Font
    public let fill: Fill
    public let border: Border
    public let alignment: Alignment
    public let protection: Protection
    public let namedStyle: ?String

    public init(numberFormat!: NumberFormat = NumberFormat.General,
                font!: Font = Font(),
                ...)
    /// 局部修改，返回新值（不可变风格的 builder）
    public func withFont(f: Font): CellStyle
}
```

`Font` / `Fill` / `Border` / `BorderSide` / `Alignment` / `Protection` 同样都是 `struct` + `let`。

好处有三条：

1. **值语义**，`setStyle(ref, style)` 传的是副本，调用方之后改自己的变量不影响文档
2. **不可变**，哈希稳定——不会出现"加入池后被外部修改导致 `styles.xml` 错乱"
3. **去重按值比较是自然语义**，不需要文档教调用方"要复用实例"

代价是一次 struct 拷贝（约 150 字节，纳秒级），和 100 万次 `setStyle` 相比可忽略。

#### 2.6.4.3 三层查找：深比较几乎不发生

```cangjie
class StylePool {
    /// 结构哈希 → 池内索引列表（哈希冲突时列表长度 > 1）
    private let byHash = HashMap<UInt64, ArrayList<Int64>>()
    private let styles = ArrayList<CellStyle>()
    private var estimatedBytes: Int64 = 0

    func getOrAdd(style: CellStyle): Int64 {
        let h = structuralHash(style)                 // ① 逐字段算 64 位哈希
        if (let Some(list) <- byHash.get(h)) {
            for (idx in list) {
                if (styles[idx] == style) { return idx }   // ② 逐字段比较（几乎不执行）
            }
        }
        // ③ 未命中，新增
        styles.add(style)
        byHash.getOrPut(h) { ArrayList<Int64>() }.add(styles.size - 1)
        estimatedBytes += style.estimatedBytes()
        if (estimatedBytes > threshold) { warn(...) }
        if (styles.size > maxCellStyles) { throw ExcelException(...) }
        return styles.size - 1
    }
}
```

三层成本：

| 层 | 条件 | 成本 |
|---|---|---|
| ① 算结构哈希 | 每次 `setStyle` | ~100 ns（7 个字段，含 2~3 个字符串的 FNV） |
| ② 逐字段比较 | 哈希命中时 | 字符串相等通常"长度不同即返回"，实际 ~50 ns |
| ③ 新增 | 确实是新样式 | 一次 `ArrayList.add` |

**100 万个单元格全部调用 `setStyle`，第 ① 层总成本约 0.1 秒。** 第 ② 层只在哈希命中时执行，
而哈希命中意味着"大概率是同一种样式"，比较通常在第一个字段就返回 false 或很快 true。

**注意 ② 不能省。** 64 位哈希的碰撞概率虽然极低（10 万个样式约 2.7e-10），
但一旦碰撞就是"两个不同样式被当成一个"，产出的文件里样式会静默错乱——这类 bug 极难查。
逐字段比较是兜底，成本几乎为零。

#### 2.6.4.4 为什么不能"等出错后再做深比较"

问题原话是："可否在失败或出错时再做这个深比较？"

**不能。** 三个理由：

**① 流式写入时没有"出错后再补救"的机会。**

```
writeSheet(rows):
  第 1 行   → 写 <c r="A1" s="7">   ← s=7 已经进了 deflate 流
  第 100 万行 → 发现样式池爆了
```

ZIP 是顺序写的，`sheet1.xml` 的字节已经压进输出流。想改第 1 行的 `s` 值，必须重写整个 sheet——
那就是放弃流式，回到"全量在内存"。

**② 非流式也一样，因为 `styles.xml` 在 sheet 之后写。**

`styles.xml` 最后写是为了解决"写到第一百万行才出现新样式"（2.6.4）。但每个单元格的 `s`
索引在写 sheet 时就固定了。池满了才发现，只能整个重来。

**③ "失败"的定义本身不成立。**

什么时候算失败？池满？那已经写了百万行。哈希碰撞？那不会"失败"，只会静默错乱。
既然没有明确的失败点，就没有"失败后补救"这个时机。

**真正的解法是让深比较不构成成本**，也就是 2.6.4.3 的三层查找——不是把它推迟到某个时机。

#### 2.6.4.5 超限时的错误信息：必须分两版

**同一个"超过上限"，原因可能完全不同，文案必须说清是哪一种**——否则用户会以为
"Excel 只支持 8192 种样式"。

判断依据很简单：**触发时 `maxCellStyles` 是多少**。

```cangjie
if (styles.size > maxCellStyles) {
    if (maxCellStyles >= 64000) {
        // 版本 A：真的是 Excel 打不开
        throw ExcelException(
            "样式种类超过 ${maxCellStyles}（当前 ${n} 种），已超出 Excel 的单元格格式上限，" +
            "生成的文件将无法打开。" +
            "常见原因是每行用了不同的自定义数字格式。" +
            "建议：把 formatCode 归并到少数几种（例如统一用 yyyy-mm-dd，而不是逐行拼不同字面量）。"
        )
    } else {
        // 版本 B：是我们给低内存设备设的保护，Excel 本身没问题
        throw ExcelException(
            "样式种类超过 ${maxCellStyles}（当前 ${n} 种），超过本平台的默认上限。" +
            "注意：这不是 Excel 的限制（Excel 支持 64000 种），" +
            "是本模块为低内存设备设的保护，约占用 ${mb} MB。" +
            "如果确实需要更多样式，显式传入更大的值：" +
            "SheetWriteOptions(maxCellStyles: 64000)。"
        )
    }
}
```

**两版文案的差别**：

| | 版本 A（`maxCellStyles >= 64000`） | 版本 B（`maxCellStyles < 64000`） |
|---|---|---|
| 根因 | Excel 打不开 | 我们主动拦的 |
| 能否解决 | **不能**，只能归并格式 | **能**，调大参数即可 |
| 文案要点 | "文件将无法打开" | "这不是 Excel 的限制"+"怎么调大" |

**版本 B 里"这不是 Excel 的限制"这句不能省。** 少了它，用户的第一反应是
"Excel 这么弱？"或者"这个库有 bug"，而实际是我们为了保护他的手机内存。

`styleBytesWarnThreshold` 触发时只记 warning（不阻断）：

```
"样式池估算占用 ${mb} MB（${n} 种样式），超过告警阈值 ${threshold}。文件仍可正常生成。"
```

#### 2.6.5 行号必须严格递增

ECMA-376 要求 `<sheetData>` 内的 `<row>` 按 `r` 属性升序。乱序的行 Excel 可能报"需要修复"，LibreOffice 会静默重排。这条在流式场景下必须校验：

```cangjie
if (row.index <= this.lastRowIndex) {
    throw ExcelException("行号必须严格递增：上一次 ${lastRowIndex}，本次 ${row.index}")
}
```

**不要静默排序**——静默排序要求把整表缓存起来，正好废掉流式。

#### 2.6.6 文本写入方式

```cangjie
public enum StringWriteMode {
    | InlineStr        // <c t="inlineStr"><is><t>...</t></is></c>
    | SharedStrings    // <c t="s"><v>索引</v></c> + 全量 sst
}
```

| | `InlineStr` | `SharedStrings` |
|---|---|---|
| 内存 | 恒定 | 需全量去重表（与唯一字符串数成正比） |
| 文件体积 | 大（重复字符串各写一遍） | 小 |
| 流式友好 | ✅ | ❌（表要全部写完后才能输出） |
| 默认 | **流式时 `InlineStr`** | 非流式时可配 |

`ExcelWriter` 默认 `InlineStr`；`ExcelDocument.write()` 默认也是 `InlineStr`（首版简单），可切到 `SharedStrings` 换体积。

#### 2.6.7 流式输出的字节路径、背压与失败语义

2.6 给的是"接口形状"，这里定"字节怎么流"。

**通路（四段，推模式）：**

```
调用方的 Iterator<RowData>
        │  next()（writeSheet 驱动）
        ▼
SheetXmlEmitter            f_xml.XmlWriter 增量接口（startElement / text / endElement）
        │  write(buf)（XmlWriter 内部 16 KB 缓冲满才写）
        ▼
ZipWriter.openEntry(name)  返回条目 OutputStream（24 字节 data descriptor，长度未知也安全）
        │  推入
        ▼
stdx.compress.zlib deflate
        ▼
OutputStream（File / Socket / 内存）
```

每一段都是"上一段产出、下一段消费"，**没有任何一段预读整表**，这就是"边产生 Excel 格式的数据边写出"的实现口径。

**XML 生成交给 `f_xml`**：`XmlWriter` 的增量接口（`startElement` / `text` / `endElement` /
`emptyElement`）从 v1.2 起提供，命名空间声明、转义、缩进、缓冲、非 UTF-8 编码都在 f_xml 内完成。
f_excel 只负责"把一行映射成若干 XML 事件"，不再自己维护 XML 发射器与转义表。

**三个必须明确的约定：**

| 约定 | 内容 | 理由 |
|---|---|---|
| **迭代器驱动** | `writeSheet` 返回前会把迭代器消费完；迭代器 `next()` 返回 `None` 即该 sheet 结束 | f_excel 主动取行、主动写条目流，不额外起线程（2.6.1） |
| **失败即残缺** | 写出中途抛异常（行号乱序、超上限、迭代器自身报错）时，**已经写出的字节无法回滚** | ZIP 顺序写 + deflate 流不可回退（2.6.4.4） |
| **`finish()` 才算完成** | `finish()` 之前 output 不是有效 xlsx（缺中央目录 + EOCD） | 调用方不得提前把 output 交给别人 |

失败后的状态机：

```
Writing ──(任一异常)──▶ Failed ──(finish/close)──▶ 抛 ExcelException("流式写入已失败：<原因>")
Writing ──(finish 成功)──▶ Finished
```

- `Failed` 状态下 `writeSheet` / `finish` 一律立即抛，不再写任何字节；
- 调用方负责丢弃产物：`Path` 场景删掉半成品文件，`OutputStream` 场景关闭并丢弃；
- **不要**试图"跳过坏行继续写"——一张缺行的表比一个明确的异常更难排查。

**flush 粒度：**

| 层 | 何时 flush | 说明 |
|---|---|---|
| XmlWriter 缓冲（16 KB） | 满时自动 | 行结束**不**强制 flush，避免把 XML 切得过碎 |
| 条目流（f_zip） | 条目 `close()` | 结束时写 data descriptor 并登记中央目录 |
| deflate | 由 `stdx` 决定（内部块） | f_excel 不干预 |
| `OutputStream` | `finish()` / `close()` | 每行 `output.flush()` 会把 deflate 打碎，反而变慢 |

**进度与取消：**

- 进度：`ExcelWriter.rowsWritten`（本 sheet 已写行数）+ `f_zip` 的 `position` / `spilling`（2.6.4 / f_zip 3.2.2）；
- 取消：调用方让迭代器提前返回 `None` 即可（写出的是"到此为止"的完整表）；**不提供 `cancel()`**——
  中途取消与失败同义，产物都应丢弃。

**大字符串与超限：** 单格文本 > 32767 字符、行号 > 1048576、列号 > 16384 一律抛 `ExcelException`（9.4），
不做静默截断——截断会让产出的数据与调用方以为写进去的不一致。

---

## 2.7 流式解析（边读取边解析）

### 2.7.1 为什么需要它，以及它不是 `eager = false`

`ExcelReadOptions.eager = false`（2.5 / M3）只是把"解析哪个 sheet"推迟，**解析一个 sheet 仍然把整张表装进 `Worksheet`**。
100 万行的 sheet 依旧要 30~50 MB 模型 + 几十 MB XML。

知识库、导入、统计这类场景要的是：**一行进来、处理完、丢掉**。所以新增一条独立通道：

| 通道 | 产物 | 内存 | 适用 |
|---|---|---|---|
| `ExcelDocument(input/path)` | 完整模型（`Worksheet` / `CellValue`） | 与表大小成正比 | 随机访问、改样式、公式重算、写回 |
| **`ExcelSheetStream(path/input)`** | 逐行 `RowData` | **与行数无关** | 导入、抽取、统计、转 CSV、转另一个 xlsx |

两者不互相替代：流式通道**不构建 `Worksheet`**，因此没有 `cell("A1")` 随机访问、没有合并区域（见 2.7.6）、没有公式求值。

### 2.7.2 API

```cangjie
public class ExcelSheetStream {
    /// 文件输入：ZIP 走 seek，真流式（推荐）
    public static func open(path: Path,
                            options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream

    /// 流输入：默认落临时文件后走 Path 通道（真流式）；spool = false 时退化为全量缓冲
    public static func open(input: InputStream,
                            options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream

    /// sheet 清单（从 workbook.xml + rels 读出，几 KB）
    public func sheetNames(): Array<String>
    /// 名称不存在返回 None
    public func rows(sheet: String): ?RowReader
    public func rowsAt(index: Int64): ?RowReader

    public func warnings(): ArrayList<ExcelWarning>
    /// 释放临时文件、条目流与 ZipReader；幂等
    public func close(): Unit
}

/// 拉模式：next() 时才解析下一行
public class RowReader <: Iterator<RowData> {
    public func next(): Option<RowData>
    /// 提前结束本 sheet（不关闭 ExcelSheetStream）
    public func close(): Unit
}

public class ExcelStreamReadOptions {
    /// 是否把不可定位的输入落临时文件（默认 true）。false = 全量缓冲进内存并记 warning
    public var spool: Bool = true
    /// 临时文件目录。None = 系统临时目录
    public var spoolDir: ?Path = None
    /// 行数据里是否附带行高（<row ht>）
    public var loadRowHeight: Bool = true
    /// 日期识别，语义同 ExcelReadOptions.autoDetectDate
    public var autoDetectDate: Bool = true
    /// 日期基准覆盖，语义同 ExcelReadOptions.date1904
    public var date1904: ?Bool = None
    /// 是否加载 styles.xml（关掉则日期识别失效）
    public var loadStyles: Bool = true
    /// 是否加载 sharedStrings.xml（关掉则 t="s" 的单元格变 Empty）
    public var loadSharedStrings: Bool = true
    /// 单 sheet 最大行数，0 = 不限（超出截断 + warning）
    public var maxRows: Int64 = 0
    /// 单 sheet 最大列数，0 = 不限
    public var maxCols: Int64 = 0
}
```

`RowData` / `Cell` **直接复用 2.6 的写侧定义**（`index` / `cells` / `height`）：

- 读出来的行可以直接喂给 `ExcelWriter.writeSheet(name, reader)`，**读写同构，不需要中间转换**；
- `cells` 按 `col` 升序，只含实际出现过的单元格（稀疏行天然表达）。

### 2.7.3 数据通路

```
Path ──▶ ZipReader(path)                       // seek 定位中央目录，只读条目窗口
             │ open("xl/worksheets/sheet1.xml")
             ▼
         InputStream（增量解压，独立游标）
             │
             ▼
         XmlPullParser(input).nextEvent()       // f_xml 拉模式，不建树
             │ StartElement(row) / Text / EndElement(c)
             ▼
         SheetRowHandler                         // 按 QName.local 匹配，约 100 行（8.1）
             │ 一行结束
             ▼
         RowData  ──▶ next() 返回给调用方，随即丢弃
```

开流前先做三件事（都是 KB~MB 级，一次性）：

1. `xl/workbook.xml` + `xl/_rels/workbook.xml.rels` → sheet 名与条目路径（DOM）
2. `xl/styles.xml` → `cellXfs` 索引与"是否日期"查表（DOM，`loadStyles = false` 时跳过）
3. `xl/sharedStrings.xml` → 字符串表（事件流；`loadSharedStrings = false` 时跳过）

第 3 步是流式读的**唯一潜在大内存项**（见 2.7.4）。

### 2.7.4 真流式的三个前提，与 `InputStream` 输入的处置

| 前提 | 谁提供 | `Path` 输入 | `InputStream` 输入 |
|---|---|---|---|
| ZIP 可随机定位（中央目录在尾部） | `f_zip` | ✅ `ZipReader(path)` 走 `File.seek` | ❌ `ZipReader(input)` 全量缓冲 |
| 条目内容增量解压 | `f_zip` | ✅ `open(name)` 返回独立游标流 | ✅ 同左 |
| XML 增量解析 | `f_xml` | ✅ `XmlPullParser(InputStream)` | ✅ 同左 |

第三条满足不代表真流式——ZIP 那条不满足时，整包已经在内存里了。所以：

```cangjie
// open(input) 的默认路径：先落盘，再走 Path 通道
let tmp = File.createTemp(options.spoolDir ?? 系统临时目录)
copy(input, tmp)                    // 固定 64 KB 缓冲，内存与包大小无关
tmp.close()
this.reader = ZipReader(tmpPath)
```

| 选择 | 内存 | 磁盘 | 何时用 |
|---|---|---|---|
| `spool = true`（默认） | 恒定 | 包大小 × 1（临时） | 网络响应、HTTP 上传、压缩包内嵌 |
| `spool = false` | 包大小 × 1 | 0 | 包本来就在内存里、或磁盘不可写 |

`spool = false` 且输入不可定位时**记一条 warning 说明"已退化为全量缓冲"**——不报错，但要让调用方知道内存模型变了。

**临时文件必须清理**：`close()` 删除；异常路径用 `try-finally` 保证。进程被 kill 时残留属 OS 临时目录的正常代价（与 `f_zip` 的 `TempSpill` 同一策略）。

**`sharedStrings` 是唯一随文件增长的结构：**

| 数据 | 规模 | 说明 |
|---|---|---|
| sheet 当前行 | 几 KB | 逐行丢弃 |
| `styles` / `workbook` / `rels` | KB ~ 几 MB | 一次性 |
| `sharedStrings` | 唯一字符串数 × 平均长度 | 100 万行 × 每行 20 字符不重复 ≈ 40 MB |
| f_xml / 解压缓冲 | 固定几十 KB | |

选项 `loadSharedStrings = false` 可把它降为 0，代价是 `t="s"` 的单元格变 `Empty`（与 `ExcelReadOptions` 一致）。
用 `inlineStr` 生成的文件不受影响。**大表 + 大量共享字符串**的组合留给 M3-a 的磁盘索引（11.6 有验收项）。

### 2.7.5 行产出语义

| 情况 | 行为 |
|---|---|
| `<row r="5">` | `RowData.index = 5`，`cells` 按 `col` 升序 |
| `<row>` 无 `r` | 按"上一行 + 1"推断，记 warning（与 3.3 一致） |
| `<row r="5"/>`（只有行属性） | 产出 `cells` 为空的行；`height` 有则带上 |
| 中间缺行（3 之后直接 7） | **不补空行**，调用方按 `index` 自行对齐 |
| `<c>` 无 `r` | 按"前一列 + 1"推断，记 warning |
| 单元格值 | 走 3.1 的类型表；日期识别同 5.3；`TimeSpan` 同 5.5 |
| 公式 | 只给原文 + 缓存值，不求值（与 2.3 一致） |
| 超出 `maxRows` / `maxCols` | 截断并记 warning，流正常结束 |
| 行号乱序 | **照原样产出**（读侧宽容），记 warning；不重排、不抛 |

**为什么读侧不因乱序抛异常**：写侧严格（2.6.5）是因为要产出 Excel 能打开的文件；读侧面对的是既成文件，
抛异常等于"这份文件进不去"，与 10 章"读取要宽容"的原则冲突。

### 2.7.6 语义缺口：合并单元格拿不到

`<mergeCells>` 在 worksheet 的 schema 里位于 `<sheetData>` **之后**：

```
sheetPr?, dimension?, sheetViews?, sheetFormatPr?, cols*, sheetData, sheetCalcPr?, sheetProtection?,
protectedRanges?, scenarios?, autoFilter?, sortState?, dataConsolidate?, customSheetViews?,
mergeCells?, phoneticPr?, conditionalFormatting*, ...
```

逐行拉取时还没读到 `mergeCells`，所以：

| 需求 | 流式通道 | 正确做法 |
|---|---|---|
| 只要每行的原始值 | ✅ | `ExcelSheetStream` |
| 要 `mergedValue()` / `mergedRanges()` | ❌ 流式期间没有 | `ExcelDocument` |
| 流结束想知道有哪些合并区域 | ✅ | `ExcelSheetStream.mergedRanges()`（读完 sheetData 后填充） |

`mergedRanges()` 在 `RowReader` 返回 `None` **之后**才有值；提前调用返回空数组（不是 `None`，避免调用方误以为"没有合并"）。
这条限制必须写进 README 与 API 注释——它是"边读边解析"的固有代价，不是实现偷懒。

### 2.7.7 生命周期、并发与异常

```
ExcelSheetStream.open(...)
   └── rows(sheet) ──▶ RowReader 1 ──(next 到 None / close)──▶ 可再 rows(sheet) 重新读
                     └── RowReader 2（顺序交替可以，多线程同时 next 不可以）
close() ──▶ 关闭所有 RowReader、删除临时文件、关闭 ZipReader
```

| 事项 | 约定 |
|---|---|
| 可重复读 | `rows(sheet)` 每次重新 `open` 条目，得到新游标（ZIP 条目可重复解压） |
| 单 reader 回退 | **不支持**；`Iterator` 语义就是单向 |
| 并发 | 同一 `ExcelSheetStream` 上**不要多线程同时 `next()`**；`sharedStrings` 只读共享安全，条目游标各自独立，但顺序不可预期 |
| `close()` | 幂等；关闭后再 `next()` 抛 `ExcelException("流已关闭")` |
| 解析中途出错 | 关闭当前条目流并记 warning，`next()` 抛 `ExcelException`；`ExcelSheetStream` 本身可继续读下一个 sheet |
| 临时文件 | `close()` 删除；`spool` 文件在异常路径由 `try-finally` 清理 |

### 2.7.8 错误处理

| 情况 | 处理 |
|---|---|
| 不是有效 ZIP | `ExcelException("不是有效的 xlsx 文件")`（包装 `ZipException`） |
| 缺 `xl/workbook.xml` | `ExcelException("缺少 workbook.xml，可能不是 xlsx 文件")` |
| `rows(name)` 名称不存在 | 返回 `None`（不抛） |
| `rowsAt(index)` 越界 | 返回 `None` |
| sheet 条目缺失 / rels 指向不存在 | `rows()` 返回 `None` + warning |
| XML 格式错误 | `next()` 抛 `ExcelException`，带 sheet 名与行号 |
| 单元格 `t="s"` 索引越界 | 该格 `Empty` + warning |
| 数字解析失败 | 该格 `Text` 原文 + warning |
| `spool` 目录不可写 | `open` 抛 `ExcelException`，提示用 `spoolDir` 或 `spool = false` |

### 2.7.9 典型用法

```cangjie
import fountain::f_excel.*

// 1) 大表 → 逐行统计，内存恒定
let stream = ExcelSheetStream.open(Path("/data/big.xlsx"))
try {
    let Some(rows) = stream.rows("明细") else { throw ExcelException("没有 明细 sheet") }
    var total = 0.0
    while (let Some(row) <- rows.next()) {
        for (cell in row.cells) {
            if (let Number(v) <- cell.value) { total += v }
        }
    }
    println("合计 ${total}")
} finally {
    stream.close()
}

// 2) 大表 → 另一个大表（读流直接喂写流，全程恒定内存）
let src = ExcelSheetStream.open(Path("/data/big.xlsx"))
let out = File.create("/data/big-copy.xlsx")
let writer = ExcelWriter(out, ["明细"])
if (let Some(rows) = src.rows("明细")) {
    writer.writeSheet("明细", rows)          // RowReader 就是 Iterator<RowData>
}
writer.finish()
src.close()
out.close()
```

示例 2 是"边读边解析 + 边产生边写出"的组合形态：**两端都是常量内存**，中转不落地。

---

## 3. 读取流程

本章描述**整文档解析**（`ExcelDocument`）。逐行流式通道（`ExcelSheetStream`）走同一套步骤 1~6，
只是第 7 步改为"每解析完一行立即交出去"，且第 8 步在流结束后才执行——见 2.7。

```
1. ZipReader(input) 或 ZipReader(path)
2. 读 xl/workbook.xml（DOM，几 KB）
   · <sheets><sheet name r:id>
   · <workbookPr date1904="1">  → 决定日期基准
3. 读 xl/_rels/workbook.xml.rels（DOM）
   · r:id → 目标路径（如 worksheets/sheet1.xml）
4. 读 xl/theme/theme1.xml（DOM，若存在）→ 调色板
5. 读 xl/styles.xml（DOM）
   · numFmts / fonts / fills / borders / cellStyleXfs / cellXfs / dxfs
   · 建立 cellXfs 索引 → 完整 CellStyle
   · 建立"是否日期"查表
6. 读 xl/sharedStrings.xml（事件流）
   · 按 <si> 顺序构建字符串表；<si> 内可能有多个 <r><t>
7. 逐 sheet 读 xl/worksheets/sheetN.xml（事件流）
   · 扫描 <row> / <c>
   · 按 c 的 r 属性定位行列（不能靠顺序，单元格是稀疏的）
   · 按 t 属性决定取值方式
   · 整文档模式：整表进 Worksheet；流式模式：一行一个 RowData 交出去（2.7）
8. 读 <mergeCells> 记录合并区域
   · 整文档模式：并入 Worksheet.mergedRanges
   · 流式模式：流结束后才可用（2.7.6）
```

### 3.1 单元格类型（`t` 属性）

| `t` 值 | 含义 | `<v>` / 其他 | 转换 |
|---|---|---|---|
| 缺省 / `n` | 数字 | `<v>` 十进制字符串 | `Float64.parse` |
| `s` | 共享字符串 | `<v>` 是**索引** | 查 sharedStrings 表 |
| `inlineStr` | 内联字符串 | 无 `<v>`，用 `<is><t>` | 直接取文本 |
| `str` | 公式的字符串结果 | `<v>` 文本 | 直接取文本 |
| `b` | 布尔 | `<v>` `0`/`1` | `!= 0` |
| `e` | 错误 | `<v>` 错误码 | 包装为 `Error` |
| `d` | ISO 8601 日期 | `<v>` ISO 字符串 | `DateTime.parse` |

`t="d"` 在老文件中极少见（Excel 2010 之后才支持），但一旦出现必须按 ISO 8601 解析，不能当数字。

### 3.2 只有 `s` 属性、没有 `t`：日期识别入口

```xml
<c r="B2" s="3"><v>45231</v></c>
```

`t` 缺省 = 数字，但 `s="3"` 指向 `cellXfs[3]`。若 `cellXfs[3].numFmtId` 是日期格式，则 `45231` 应转成 `Date` 而不是 `Number`。判定逻辑见第 5 章。

### 3.3 稀疏性

单元格只在实际有值时出现。`<row r="100"><c r="Z100">` 意味着第 100 行只有 Z 列有值。

**绝对不能按遍历顺序推断行列**，必须解析 `r` 属性。这是最常见的解析错误，没有之一。

`<c>` 的 `r` 属性在 ECMA-376 中是**可选**的（可省略，此时按顺序推断），但实际所有生成器都会写。策略：`r` 缺失时按"前一个 +1"推断，并记一条 warning。

---

## 4. 写入流程

### 4.1 非流式（`ExcelDocument.write`）

```
1. 收集所有 sheet 的名字 → 构造 [Content_Types].xml
2. 构造 _rels/.rels（指向 xl/workbook.xml）
3. 构造 xl/workbook.xml（sheet 列表 + workbookPr）
4. 构造 xl/_rels/workbook.xml.rels（r:id → worksheet 路径）
5. 对每个 sheet 构造 xl/worksheets/sheetN.xml
6. 构造 xl/styles.xml（完整，M2）
7. 可选：xl/sharedStrings.xml、xl/theme/theme1.xml、docProps
8. 全部通过 ZipWriter 写入 output
```

第 1 步决定了必须先把 sheet 清单拿到手——这点和非流式一样，不是流式特有的约束。

### 4.2 最小可用的 xlsx 必需部件

| 部件 | 必需 | 作用 |
|---|---|---|
| `[Content_Types].xml` | ✅ | 声明每个 part 的 MIME 类型 |
| `_rels/.rels` | ✅ | 指向主文档（workbook） |
| `xl/workbook.xml` | ✅ | sheet 清单 |
| `xl/_rels/workbook.xml.rels` | ✅ | r:id → worksheet 路径 |
| `xl/worksheets/sheetN.xml` | ✅ | 实际数据 |
| `xl/styles.xml` | 建议 | 没有它时，日期无法表达，部分 Excel 版本会报"需要修复" |
| `xl/sharedStrings.xml` | 可选 | 用 `inlineStr` 时不需要 |

### 4.3 数值格式：最短往返

数字必须写成**足够精度**的十进制字符串，否则读回来会掉精度。

```
Float64 → 最短往返表示（取能唯一还原该 Float64 的最短十进制串）
```

**不要用 `"${v}"` 直接拼**——仓颉默认的浮点转字符串可能截断精度。需要显式控制有效位数（17 位内取最短）。

整数要特判：`Float64(1.0)` 应写成 `"1"` 而不是 `"1.0"`，否则某些工具会把它当文本或显示成 `1.0`。

### 4.4 XML 转义

| 字符 | 转义 |
|---|---|
| `&` | `&amp;` |
| `<` | `&lt;` |
| `>` | `&gt;`（非必需但推荐） |
| `"` | `&quot;`（属性值内必需） |
| `'` | `&apos;`（属性值内可选） |

**控制字符（0x00-0x1F，除 `\t` `\n` `\r`）在 XML 1.0 里非法**，必须剔除或替换，否则生成的 xlsx 打不开。这是生成器最常见的"文件损坏"来源。

XML 1.0 允许但需注意的字符：
- `0x7F` (DEL) — 合法，但某些 Excel 版本处理异常，建议剔除
- `0xFFFE` / `0xFFFF` — 非法，必须剔除
- 孤立代理项 `0xD800-0xDFFF` — 非法（UTF-8 里本就无法出现）

`f_xml` 的 `InvalidCharMode.Replace` 会把非法字符换成 `'?'`（0x3F），见 `f_xml模块设计.md` 2.7。

---

## 5. 日期处理

Excel 的日期是一个数字 + 一个日期格式样式。数字是"从基准日算起的天数"，小数部分表示时间。

### 5.1 两种基准

| 系统 | 基准 | 判定方式 |
|---|---|---|
| 1900（默认） | serial 1 = 1900-01-01 | `workbookPr` 无 `date1904` 或 `date1904="0"` |
| 1904 | serial 0 = 1904-01-01 | `workbookPr date1904="1"` |

### 5.2 1900 系统的闰年 bug

Excel 为兼容 Lotus 1-2-3，认为 1900 年是闰年，于是存在一个不存在的 `1900-02-29`（serial 60）。

```
serial 1..59    → 1899-12-31 + serial 天
serial == 60    → 无效（Excel 的假日期），返回 Error("#VALUE!") 或按 Number 保留
serial >= 61    → 1899-12-30 + serial 天
```

验证：

| serial | 日期 |
|---|---|
| 1 | 1900-01-01 |
| 59 | 1900-02-28 |
| 60 | （不存在）|
| 61 | 1900-03-01 |

反算（`DateTime` → serial）：`datetime >= 1900-03-01` 用 1899-12-30 基准，否则用 1899-12-31。

**serial 60 的处理需要拍板**：返回 `Error("#VALUE!")` 会让一张正常的表出现莫名其妙的错误；按 `Number(60)` 保留则调用方可能误当日期。**选择按 `Number` 保留**，并记 warning——因为这种文件本身就是历史遗留，不该让整个解析失败。

### 5.3 如何判断是日期

不能只看数字范围，必须看样式：

1. `styles.xml` 里 `<cellXfs>` 每个 `<xf numFmtId="N">`
2. `<numFmts>` 里自定义格式 `numFmtId → formatCode`
3. **内置的日期 numFmtId**：`14`-`22`、`45`-`47`
4. 自定义格式的 code 需要"净化"后判断

#### 5.3.1 内置日期格式一览

| id | 格式 | 类型 |
|---|---|---|
| 14 | `mm-dd-yy` | 日期 |
| 15 | `d-mmm-yy` | 日期 |
| 16 | `d-mmm` | 日期 |
| 17 | `mmm-yy` | 日期 |
| 18 | `h:mm AM/PM` | 时间 |
| 19 | `h:mm:ss AM/PM` | 时间 |
| 20 | `h:mm` | 时间 |
| 21 | `h:mm:ss` | 时间 |
| 22 | `m/d/yy h:mm` | 日期时间 |
| 45 | `mm:ss` | 时间 |
| 46 | `[h]:mm:ss` | 时长 |
| 47 | `mmss.0` | 时间 |

注意 46 是 `[h]` 经过时间，47 也是时长性质——M1 一律当 `Date` 会丢信息，但至少不会显示成裸数字。**M2 引入 `CellValue.TimeSpan` 区分**（见 5.5）。

#### 5.3.2 自定义格式的启发式判定

原始 formatCode 里混着大量非语义内容，必须先净化：

```
净化步骤（按顺序）：
1. 去掉 [...] 整体        —— [Red]、[h]、[$-409]、[>=100] 都是这类
2. 去掉 "..." 整体        —— 字面量
3. 去掉 \x                —— 单个转义字符
4. 去掉 _x 和 *x          —— 占位与填充
5. 转小写
```

净化后：

```
是日期 ⟺ 含 {y, m, d, h, s} 中至少一个，且
         （含 '-' 或 '/' 或 ':'）或者 只由这些字符与分隔符组成
```

**`m` 的歧义**（月 vs 分钟）是最麻烦的一处：

```
若 m 紧邻 h 或 s（同一段连续的格式字符内），则是分钟，否则是月
例：
  "h:mm"      → m 是分钟（紧跟 h）
  "mm:ss"     → m 是分钟（紧跟 s）
  "yyyy-mm-dd" → m 是月（不邻 h/s）
```

这个规则覆盖了绝大多数真实格式。误判的极端例子（如 `"m h"`）可以接受——用户可以关掉 `autoDetectDate`。

#### 5.3.3 不会被误判的常见"非日期"

| 格式 | 判定 | 原因 |
|---|---|---|
| `0.00` | 数字 | 无 y/m/d/h/s |
| `#,##0` | 数字 | 无 |
| `0.00%` | 数字 | 无 |
| `0.00E+00` | 数字 | 无 |
| `@` | 文本 | 无 |
| `"日期："0.00` | 数字 | `日期：` 在引号内，已剔除 |
| `[Red]0.00` | 数字 | `[Red]` 已剔除 |
| `# ?/?` | 分数 | 无 ymdhs |
| `0 "m"` | 数字 | `m` 在引号内，已剔除 |

### 5.4 写入时必须绑样式

如果写入了 `Date` 值却不给样式，Excel 会把它显示成一个 5 位数字（序列号），用户会以为数据错了。

```cangjie
// 写 Date 时自动绑一个日期样式
let serial = toSerial(dt, date1904)
cell.style = cell.style ?? CellStyle(numberFormat: .Builtin(14))
```

若调用方显式指定了样式，以调用方为准（但若样式不是日期格式，记 warning）。

### 5.5 `[h]` 经过时间：`TimeSpan` 加入 `CellValue`（已定，M2）

**决定：`TimeSpan(Duration)` 进 `CellValue` 枚举，M2 实施。**

```cangjie
public enum CellValue {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)
    | Date(DateTime)                      // 时间点
    | TimeSpan(Duration)                  // 时长（M2 新增）
    | Formula(String, Option<CellValue>)
}
```

`[h]:mm:ss` 表示"累积小时数"，可以超过 24（如 `37:30:00`），无法用 `DateTime` 表达——
**它不是一个时间点，而是一段时长**。用 `Date` 表示会丢失语义：`37:30:00` 会被迫映射到
某个具体日期，而 Excel 里它只是一个数（1.5625 天）。

M1 按 `Date` 或 `Number` 处理并记 warning，M2 修正为 `TimeSpan`。

#### 5.5.1 为什么接受"加一项枚举"的代价

替代方案是"`[h]:mm:ss` 继续返回 `Date`，另提供 `isTimeSpan()` 查询"。**否决**，三条理由：

1. **`Date` 装不下超过 24 小时的值。** `Duration` 可以表达任意长度，`DateTime` 不行。
   这是硬伤，不是风格问题。
2. **`isTimeSpan()` 是个补丁，不是设计。** 它要求每个调用方都记得"拿到 `Date` 之后还要再查一次"，
   漏查就会把 `37:30:00` 当成某个日期。这种"正确性依赖调用方记性"的 API 迟早出事。
3. **枚举多一项的成本是编译期的一次性成本。** `match` 少了分支，编译器会直接报错并指出位置，
   照着补就行。如果以后再加 `RichText` 之类，成本一样——早加早暴露。

#### 5.5.2 判定与转换

**判定**：`numFmtId ∈ {46, 47}`（内置），或自定义格式净化后含 `[h]` / `[m]` / `[s]` / `[hh]` / `[mm]` / `[ss]`。

```
46  → [h]:mm:ss
47  → mmss.0      （实际是 mm:ss.0，老版本 Excel 的笔误，按时间处理）
```

**注意**：`[h]` 表示"累计小时"，`h` 表示"一天内的小时"（0~23）。这个区别是判定的关键——
净化步骤（5.3.2）里"去掉 `[...]`"这一步会**丢掉**这个信号，所以判定必须**在净化之前**扫一遍原文。

#### 5.5.3 方括号里既有颜色又有 `[h]` 怎么办

同一个格式串里，方括号可以装四种完全不同的东西：

| 内容 | 含义 | 例 |
|---|---|---|
| 全 `h`/`m`/`s` 字符（1~2 个） | **经过时间**（TimeSpan 的唯一信号） | `[h]` `[mm]` `[ss]` `[hh]` |
| 颜色名 | 颜色 | `[Red]` `[Blue]` `[Color10]` |
| `$` 开头的语言/货币代码 | locale | `[$-409]` `[$€-407]` |
| 比较条件 | 条件格式（在 numFmt 里用于分段） | `[>=100]` `[<0]` |

**判别规则只有一条：整个方括号的内容必须由 `h`/`m`/`s`（大小写不敏感）组成。**

```cangjie
/// 返回 (是否有经过时间标记, 是否是日期/时间格式)
func classifyBrackets(code: String): (Bool, Bool) {
    var hasElapsed = false
    for (seg in allBracketSegments(code)) {          // 逐个 [...] 的内容，不含方括号本身
        if (seg.isEmpty) { continue }
        if (seg.all { |c| c == 'h' || c == 'H' || c == 'm' || c == 'M' || c == 's' || c == 'S' }) {
            hasElapsed = true                        // [h] [mm] [ss] [hh] 都算
        }
        // 其余一律不参与 TimeSpan 判定：[Red] [$-409] [>=100] [Color10]
    }
    return (hasElapsed, ...)
}
```

**必须写成"全 h/m/s 才算"而不是"包含 h/m/s 就算"**，否则 `[h:ss]`、`[Red]` 里的字母 `R`/`e`/`d`
不会误判，但像 `[sRed]` 这种脏数据会被误判成时长——虽然罕见，规则本身要严。

判定表：

| formatCode | TimeSpan？ | 理由 |
|---|---|---|
| `[h]:mm:ss` | ✅ | `[h]` 全是 h |
| `[hh]:mm` | ✅ | `[hh]` 全是 h |
| `[Red][h]:mm` | ✅ | 两个方括号，第二个是 `[h]` |
| `[Blue][mm]:ss` | ✅ | 第二个是 `[mm]` |
| `[Red]0.00` | ❌ | `[Red]` 不是全 h/m/s；且无其他时间标记 |
| `[$-409]h:mm` | ❌ | 是普通时间（`h` 不在方括号里），不是累计时长 |
| `[$-409][h]:mm` | ✅ | `[$-409]` 跳过，`[h]` 命中 |
| `[>=100]0.00` | ❌ | 条件不是时长 |
| `[h:ss]` | ❌ | 混合内容，不是纯 h/m/s |
| `[Color10]` | ❌ | 颜色名 |

**注意最后三行**：`[$-409]h:mm` 是**时间**（`CellValue.Date`），不是**时长**（`TimeSpan`）。
这两者都"看起来像时间"，区别只在 `h` 是否被方括号包住。这条必须单测覆盖（11.6）。

**实现顺序**：先扫方括号定 `hasElapsed`，再按 5.3.2 净化判日期/时间。两步都要做，
不能用净化后的串反推 `hasElapsed`——净化已经把方括号删了。

**转换**：

```
serial = 单元格的数值（单位：天）
nanos  = serial × 86400 × 1e9          // Float64 计算
if (nanos > Duration.Max.toNanoseconds()) → 报 ExcelException，不静默回绕
duration = Duration.nanoseconds(Int64(nanos.round()))
```

Excel 的序列号是"天"，小数部分是"天的小数"。`37:30:00` 的 serial = `1.5625`。

**反向**（`TimeSpan` → 单元格写法）：

```
serial = Float64(duration.toNanoseconds()) / 86400e9
cell.value = Number(serial)
cell.style = CellStyle(numberFormat: .Builtin(46))
```

#### 5.5.4 `Duration` 的范围：两个上限要分清

**实测结论（由用户提供）：`Duration.Max.toNanoseconds()` 会抛异常，不是返回一个数。**

```
[running@localhost docs]$ cat maxDuration.cj
main(){
  println(Duration.Max.toNanoseconds())
}
[running@localhost docs]$ cj -c maxDuration.cj
An exception has occurred:
ArithmeticException: Duration in nanoseconds exceeds 'Int64' range.
```

**这条实测推翻了两版推断，必须记下来：**

| 版本 | 说法 | 状态 |
|---|---|---|
| v0.4 | "`serial × 86400 × 1e9` 约 106 天就溢出" | ❌ 算错 1000 倍 |
| v0.5 | "`Duration` 是 Int64 纳秒，上限约 292 年" | ❌ 内部不是纯纳秒 |
| v0.6（本版） | **`Duration` 的表示上限远大于 Int64 纳秒；`toNanoseconds()` 对小值安全、对大值抛异常** | ✅ 实测 |

所以**存在两个不同的上限，绝不能混用**：

| 上限 | 值 | 由什么决定 |
|---|---|---|
| `Duration` 能表示的**最大时长** | 约 **2920 亿年**（`Int64.Max` 秒） | 内部秒字段是 `Int64` |
| 能安全调用 **`toNanoseconds()`** 的最大时长 | 约 **292 年** | 纳秒总数不能超 `Int64.Max` |

```
Int64.Max ÷ 1e9 ÷ 86400 ÷ 365.25     ≈ 292 年        ← toNanoseconds() 的安全边界
Int64.Max ÷ 86400 ÷ 365.25           ≈ 2920 亿年     ← Duration 本身的上限
```

**这直接决定实现方式：不能拿 `Duration.Max.toNanoseconds()` 当上界比较——它自己就会抛。**

##### 正确写法：用秒构造，避开纳秒转换

```cangjie
/// serial（Float64 天）→ Duration
func toDuration(serial: Float64): Duration {
    let totalSeconds = serial * 86400.0
    // 上界用 1e18 秒（约 317 亿年），远大于任何 Excel 值，又留足余量不碰 Int64 边界
    if (!totalSeconds.isFinite() || totalSeconds < 0.0 || totalSeconds > 1.0e18) {
        throw ExcelException("时长超出可表示范围：serial=${serial}（约 ${serial / 365.25} 年）")
    }
    let wholeSec = Int64(totalSeconds)                                   // 截断
    let fracNanos = Int64(((totalSeconds - Float64(wholeSec)) * 1e9).round())
    return Duration.second * wholeSec + Duration.nanosecond * fracNanos
}
```

**关键点**：

1. **用 `Duration.second * wholeSec`，不用 `Duration.nanoseconds(totalNanos)`**。后者在
   `totalNanos > Int64.Max` 时抛 `ArithmeticException`。
2. **上界检查放在秒上（1e18），不放纳秒上**。1e18 秒 ≈ 317 亿年，
   是"远大于需求但离 Int64 边界还有 9 倍余量"的位置。
3. **小数部分单独取**：`(totalSeconds - wholeSec) × 1e9` 一定 < 1e9，转 `Duration.nanosecond` 安全。

##### 反向：`Duration` → serial 也不能直接 `toNanoseconds()`

```cangjie
/// Duration → serial（Float64 天）
func toSerial(d: Duration): Float64 {
    // toSeconds() 对超大 Duration 也可能抛（已实测），用 try-catch 兜住，
    // 不依赖它的精确边界
    let wholeSec = try {
        d.toSeconds()
    } catch (e: ArithmeticException) {
        throw ExcelException("Duration 超出 Excel 可表示范围")
    }
    let frac = d - Duration.second * wholeSec         // 余数，一定 < 1 秒
    let fracNanos = frac.toNanoseconds()              // < 1e9，安全
    return (Float64(wholeSec) + Float64(fracNanos) / 1e9) / 86400.0
}
```

**先用 `toSeconds()` 拆出整数秒，再对余数调 `toNanoseconds()`。** 余数永远小于 1 秒，
它的纳秒数最多 1e9，绝不会溢出。

**为什么要 try-catch 而不是 `if` 判断**：`toSeconds()` 的确切边界没有实测数据
（用户确认"对超长 Duration 也会抛"，但没给边界值）。与其猜一个阈值，
不如直接捕获异常——**语义正确，且不依赖具体实现细节**。

同样的原则适用于正向：`Duration.second * wholeSec` 溢出**会抛**
（用户确认），所以 5.5.4 的 `1e18` 上界只是"提前给出可读错误"的第一道防线，
真正兜底的是 `*` 自己的溢出检查。两道防线都要有：

| 防线 | 作用 |
|---|---|
| `totalSeconds > 1e18` 的显式检查 | 给出**带上下文的错误信息**（"serial=xxx，约 xxx 年"） |
| `Duration.second * n` 的溢出抛 | 兜住任何我们没想到的路径 |

一条通用规则（写进代码注释）：

> **永远不要对可能很大的 `Duration` 直接调 `toNanoseconds()`。**
> 需要大范围时用 `toSeconds()` + 对余数取纳秒。

##### 现实中的值域

| 量 | 值 |
|---|---|
| Excel `[h]` 的典型值 | 几小时 ~ 几百小时 |
| Excel `[h]` 的极端值 | 几万小时（约 1~5 年） |
| `.xlsx` 里 serial 的实际最大值 | 受 `Float64` 精度限制，实用上 < 1e7 天 |
| 我们接受的上界 | **1e18 秒 ≈ 317 亿年**（远超任何真实值） |

**`Float64` 的精度不是问题**：在 1e5 天量级，`Float64` 的分辨率约 1e-11 天 ≈ 1 μs，
远小于 `Duration` 的纳秒粒度。所以"`serial` → 纳秒"的转换误差可以忽略。

---|---|
| `Duration` 上限 | 约 **292 年**（106,751 天） |
| 对应小时数 | 约 **2,562,024 小时** |
| 现实中的 `[h]` 值 | 通常几小时到几百小时，极端几万小时 |

**106,751 天这个上限远大于任何真实的 `[h]` 值**，所以不需要"限制用户只能填 106 天"。
要做的是**超出时报错而不是静默回绕**：

```cangjie
let maxNanos = Duration.Max.toNanoseconds()
let nanos = serial * 86400.0 * 1e9
if (nanos > Float64(maxNanos) || nanos < 0.0) {
    throw ExcelException("时长超出可表示范围：serial=${serial}（约 ${serial/365.25} 年）")
}
```

**实施时要实测确认**：`Duration.Max.toNanoseconds()` 的实际值决定上限。
若 `Duration` 内部是 `(sec: Int64, nanos: Int32)` 而非纯纳秒，
上限会远大于 292 年——那这段检查依然正确（只是永远不会触发）。

**`Float64` 的精度不是问题**：在 1e5 天量级，`Float64` 的分辨率约 1e-11 天 ≈ 1 μs，
远小于 `Duration` 的纳秒粒度。所以"`serial` → 纳秒"的转换误差可以忽略。

---

## 6. 样式子系统（M2）

M1 只做"日期识别所必需的最小样式"（读 `numFmtId`）。**M2 做完整读写。**

### 6.1 styles.xml 的结构

```xml
<styleSheet>
  <numFmts count="1">
    <numFmt numFmtId="164" formatCode="yyyy&quot;年&quot;mm&quot;月&quot;dd&quot;日&quot;"/>
  </numFmts>
  <fonts count="2">
    <font><sz val="11"/><name val="等线"/><family val="2"/><charset val="134"/></font>
    <font><b/><sz val="14"/><color theme="4"/><name val="等线"/></font>
  </fonts>
  <fills count="2">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1">
    <border><left/><right/><top/><bottom/><diagonal/></border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="2">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="164" fontId="1" fillId="1" borderId="0" xfId="0"
        applyNumberFormat="1" applyFont="1" applyFill="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
  </cellXfs>
  <cellStyles count="1">
    <cellStyle name="常规" xfId="0" builtinId="0"/>
  </cellStyles>
  <dxfs count="0"/>
  <tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
</styleSheet>
```

七个集合，**彼此用索引互相引用**：

| 集合 | 被谁引用 | 说明 |
|---|---|---|
| `numFmts` | `xf.numFmtId`（≥164 的自定义） | 内置 0-163 不在此表，直接用 |
| `fonts` | `xf.fontId` | |
| `fills` | `xf.fillId` | **下标 0 必须是 `none`，下标 1 必须是 `gray125`** — 否则 Excel 报修复 |
| `borders` | `xf.borderId` | |
| `cellStyleXfs` | `xf.xfId` | 命名样式的基准 |
| `cellXfs` | 单元格的 `s` 属性 | 实际生效的 |
| `cellStyles` | 无（按名字查） | 必须至少有一个 `builtinId="0"` 的"常规" |

**`fills` 的前两项是硬约定**，这是生成 xlsx 时最常见的"需要修复"原因之一。空文档也必须写这两项。

### 6.2 索引化与去重

`cellXfs[i].fontId` 是**指向 `fonts` 的索引**，不是内联的字体定义。这意味着：

1. 读的时候，必须先把 `fonts`/`fills`/`borders` 全部读成数组，再按索引组装 `CellStyle`
2. 写的时候，必须对相同内容去重——否则 N 个单元格若各自写一份字体，`fonts` 会有 N 项

**去重的实现**：给 `Font`/`Fill`/`Border`/`NumberFormat` 各算一个结构化哈希（不用 `hashCode()` 默认实现，因为需要按字段值比较），用 `HashMap<T, Int64>` 映射到索引。

实践中 openpyxl 生成的文件经常有几百个重复 `font`，就是因为没做去重。去重后典型文件 `fonts` 只有 3-10 项。

### 6.3 继承链：`cellXfs[i].xfId` → `cellStyleXfs`

这是样式系统里**最容易搞错的地方**。

规范语义：

```
cellXfs[i] 只定义"覆盖项"
  applyFont="1"   → 用 cellXfs[i].fontId
  applyFont="0"   → 继承 cellStyleXfs[cellXfs[i].xfId].fontId
```

`applyNumberFormat` / `applyFont` / `applyFill` / `applyBorder` / `applyAlignment` / `applyProtection` 六个开关。

**但现实是：绝大多数写入器不写 `applyXxx`。** 此时 `applyFont` 的默认值是 `false`——严格按规范，`cellXfs[i].fontId` 就不该生效，这显然荒谬，因为文件本身想表达的就是"用这个字体"。

**采用宽容模式（openpyxl / Apache POI 的通行做法）：**

| `applyXxx` | `cellXfs[i].xxxId` | 取哪个 |
|---|---|---|
| `="1"` | 任意 | `cellXfs[i].xxxId` |
| `="0"` | 任意 | 继承 `cellStyleXfs[xfId]` |
| 缺省 | 存在且 > 0 | `cellXfs[i].xxxId`（宽容） |
| 缺省 | 不存在或 = 0 | 继承 `cellStyleXfs[xfId]` |

写入时**总是显式写 `applyXxx="1"`**（当该属性被设置时），避免读回来时落到宽容分支。

### 6.4 数据模型

```cangjie
public struct CellStyle {
    public let numberFormat: NumberFormat
    public let font: Font
    public let fill: Fill
    public let border: Border
    public let alignment: Alignment
    public let protection: Protection
    /// 命名样式（cellStyles 的 name），None = 普通单元格
    public let namedStyle: ?String

    public init(numberFormat!: NumberFormat = NumberFormat.General,
                font!: Font = Font.default(),
                fill!: Fill = Fill.none(),
                border!: Border = Border.none(),
                alignment!: Alignment = Alignment.default(),
                protection!: Protection = Protection.default(),
                namedStyle!: ?String = None)

    // 不可变风格的局部修改
    public func withFont(f: Font): CellStyle
    public func withFill(f: Fill): CellStyle
    public func withNumberFormat(n: NumberFormat): CellStyle
    // ...
}

public enum NumberFormat {
    | General
    | Builtin(Int64)                  // 0..163
    | Custom(String)                 // "yyyy-mm-dd" 这类
}

public struct Font {
    /// 字体名。**None = 不写 `<name>`**，由 Excel 用自己的默认（通常随 locale 变）
    /// 显式指定就写死，往返后可能与你给的名字一致但与目标机器的默认不同
    public let name: ?String = None
    public let size: Float64 = 11.0
    public let bold: Bool = false
    public let italic: Bool = false
    public let underline: Underline = Underline.None
    public let strike: Bool = false
    public let color: ?Color = None
    public let family: Int64 = 2          // 1=Roman 2=Swiss 3=Modern 4=Script 5=Decorative
    public let charset: Int64 = 0
    public let scheme: ?String = None     // "major" / "minor"
}
```

**`fonts[0]` 必须写一条，最少写 `<font><sz val="11"/></font>`。**

原因：`cellXfs[0].fontId` 必须指向一个有效索引，所以 `fonts` 至少有一项。
即使所有单元格都用默认字体，这条也不能省。

**为什么最少保留 `<sz>`**：`<font/>`（完全空元素）在 schema 上是合法的（所有子元素
`minOccurs=0`），但"Excel 是否接受一个没有任何属性的 `<font/>`"没有实测依据。
`<sz val="11"/>` 是 Excel 的默认字号，写上它不改变任何显示效果，又能避免空元素的风险。

```xml
<fonts count="1">
  <font><sz val="11"/></font>          <!-- 不写 <name>，用 Excel 自己的默认字体 -->
</fonts>
```

**读取侧对称**：`<font>` 里没有 `<name>` 时，`Font.name` 保持 `None`，
**不要填 `"Calibri"` 之类的默认值**——否则写回去就多了一个 `<name>`，
往返一次字体名就"固定"了，第二次打开时和目标机器的默认字体不一致。

public enum Underline { | None | Single | Double | SingleAccounting | DoubleAccounting }

public struct Fill {
    public let patternType: PatternType = PatternType.None
    public let fgColor: ?Color = None
    public let bgColor: ?Color = None
    public let gradient: ?Gradient = None
}

public struct Border {
    public let left: BorderSide = BorderSide.none()
    public let right: BorderSide = BorderSide.none()
    public let top: BorderSide = BorderSide.none()
    public let bottom: BorderSide = BorderSide.none()
    public let diagonal: BorderSide = BorderSide.none()
    public let diagonalUp: Bool = false
    public let diagonalDown: Bool = false
}

public struct BorderSide {
    public let style: BorderStyle = BorderStyle.None   // Thin/Medium/Thick/Dashed/Dotted/Double/...
    public let color: ?Color = None
}

public struct Alignment {
    public let horizontal: ?HorizontalAlign = None     // Left/Center/Right/Fill/Justify/CenterAcross
    public let vertical: ?VerticalAlign = None         // Top/Center/Bottom/Justify
    public let wrapText: Bool = false
    public let textRotation: Int64 = 0                 // -90..90 或 255（竖排）
    public let indent: Int64 = 0
    public let shrinkToFit: Bool = false
    public let readingOrder: Int64 = 0                 // 0=context 1=LTR 2=RTL
}

public struct Protection {
    public let locked: Bool = true
    public let hidden: Bool = false
}
```

### 6.5 颜色的三种编码

```xml
<color rgb="FFFF0000"/>                 <!-- ARGB，8 位 -->
<color theme="4" tint="0.3999755851924192"/>
<color indexed="10"/>
```

**同时存在时的优先级：`rgb` > `theme` > `indexed`。** 这是 ECMA-376 的约定。

```cangjie
public enum Color {
    | Rgb(UInt32)                      // ARGB
    | Theme(Int64, Float64)            // theme 索引 + tint
    | Indexed(Int64)                   // 0..65
}
```

#### 6.5.1 theme 颜色必须读 theme1.xml

`theme="4"` 只给了一个槽位索引，真实的 RGB 在 `xl/theme/theme1.xml` 的 `<a:clrScheme>` 里：

| 索引 | 槽名 | 典型值 |
|---|---|---|
| 0 | `dk1` | 黑色（`sysClr` + `lastClr="000000"`） |
| 1 | `lt1` | 白色 |
| 2 | `dk2` | 深蓝 |
| 3 | `lt2` | 浅蓝 |
| 4 | `accent1` | 蓝 |
| 5 | `accent2` | 橙/红 |
| 6 | `accent3` | 灰 |
| 7 | `accent4` | 金 |
| 8 | `accent5` | 蓝 |
| 9 | `accent6` | 绿 |
| 10 | `hlink` | 超链接蓝 |
| 11 | `folHlink` | 已访问链接紫 |

每个槽有两种写法：

```xml
<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
<a:accent1><a:srgbClr val="4472C4"/></a:accent1>
```

`sysClr` 的 `val` 是系统色名（`windowText`/`window` 等），真实值在 `lastClr`——**必须用 `lastClr`**，因为我们不知道渲染环境。

**很多实现只存 `theme` 索引就完事了，导致导出的图片/PDF 颜色全错。** 本模块必须在 `Styles` 解析完成后立即把 theme 索引解析成 RGB，对外只暴露 `Rgb`。

若 `theme1.xml` 缺失（非标准生成器），退回内建的默认调色板（Office 2013+ 的默认主题），并记 warning。

#### 6.5.2 tint 的算法

`tint` 是在 HLS 空间里对亮度做插值，不是简单的 RGB 混合。MS-OI29500 §2.1.7.6：

```
HLSMAX = 255

if tint < 0:
    Lum' = Lum * (1.0 + tint)
if tint > 0:
    Lum' = Lum * (1.0 - tint) + (HLSMAX - HLSMAX * (1.0 - tint))
```

注意 `tint = -1` 得到纯黑，`tint = +1` 得到纯白，`tint = 0` 不变。

实现步骤：

```
1. RGB → HLS（H 0..360, L 0..1, S 0..1，注意用 Float64 而非整数 255 刻度）
2. L' = 上述公式（先把 tint 按同样比例映射）
3. HLS → RGB
```

**这个算法必须单测**。用 `tint=0`（恒等）、`tint=-1`（纯黑）、`tint=+1`（纯白）、`theme=4 tint=0.4` 对照 Excel 实际显示色。

#### 6.5.3 indexed 调色板

`indexed="0"`..`"63"` 是内建的 64 色调色板（Excel 97 时代遗留），`64` 是系统前景，`65` 是系统背景。

`<colors><indexedColors>` 可以覆盖默认调色板。若存在，必须用文件里的；否则用内建的。

内建调色板的前 8 项（也是出现频率最高的）：

| index | RGB |
|---|---|
| 0 | 000000 |
| 1 | FFFFFF |
| 2 | FF0000 |
| 3 | 00FF00 |
| 4 | 0000FF |
| 5 | FFFF00 |
| 6 | FF00FF |
| 7 | 00FFFF |

完整 64 项需要内建到代码里（约 64 行常量）。**不要靠猜**——网上流传的调色板有多个版本，以 ECMA-376 Part 1 §18.8.27 为准。

### 6.6 `dxfs`（差分格式）

条件格式用的差分样式。

```cangjie
public class DifferentialStyle {
    public var font: ?Font = None         // 只含被覆盖的属性
    public var fill: ?Fill = None
    public var border: ?Border = None
    public var numberFormat: ?NumberFormat = None
}
```

读出后原样保留，写入时原样写回。**不参与 `cellXfs` 的索引体系**——`dxfs` 是独立的索引空间。

#### 6.6.1 语义解析排 M4（已定）

**决定：`dxfs` 本身在 M2 存取；但"哪条规则命中、该单元格当前该显示成什么样"这套语义解析，排 M4。**

原因不是工作量，而是**依赖**：条件格式的规则里通常带公式。

```xml
<conditionalFormatting sqref="A1:A10">
  <cfRule type="expression" dxfId="0" priority="1">
    <formula>$B1&gt;100</formula>
  </cfRule>
</conditionalFormatting>
```

要判断"`A5` 是否命中这条规则"，必须**求值 `$B1>100` 并把相对引用从 `A1` 平移到 `A5`**。
这正好是公式引擎（第 7 章）的能力，而公式引擎在 M2。所以语义解析最早也只能排在公式引擎之后。

M3 又被流式写入和按需解析占满，因此排 **M4**。

#### 6.6.2 M4 的设计草案（先定形状）

```cangjie
public class ConditionalFormatting {
    /// sqref 展开后的区域列表
    public let ranges: Array<String>              // ["A1:A10", "C1:C10"]
    public let rules: Array<CfRule>
}

public class CfRule {
    public let type: CfRuleType
    public let priority: Int64                    // 数字越小优先级越高
    public let stopIfTrue: Bool
    public let dxfId: ?Int64                      // 指向 dxfs 的索引
    public let formula: ?String                   // 原始表达式
    public let operator: ?CfOperator              // cellIs 用
    // 专用结构（colorScale / dataBar / iconSet 各自不同）
    public let colorScale: ?CfColorScale
    public let dataBar: ?CfDataBar
    public let iconSet: ?CfIconSet
}

public enum CfRuleType {
    | CellIs | Expression | Top10 | AboveAverage | DuplicateValues | UniqueValues
    | ContainsText | NotContainsText | BeginsWith | EndsWith
    | ColorScale | DataBar | IconSet
    | TimePeriod | Blanks | NoBlanks | Errors | NoErrors
}

/// 求值：该单元格当前该用哪个差分样式
public func conditionalStyle(sheet: String, ref: CellRef): ?CellStyle
/// 所有命中的规则（按 priority 排序）
public func matchedRules(sheet: String, ref: CellRef): Array<CfRule>
```

四条设计约束：

1. **`priority` 决定求值顺序，不是数组顺序。** 文件里的 `<cfRule>` 顺序与优先级无关，
   必须按 `priority` 升序求值。
2. **`stopIfTrue = true` 时命中即停**，后续规则不再求值。
3. **`colorScale` / `dataBar` / `iconSet` 不是"样式覆盖"**，它们是按值插值出的颜色/图形，
   无法用 `CellStyle` 表达。`conditionalStyle()` 对这三类返回 `None`，
   要拿到具体颜色必须走 `CfColorScale.evaluate(value)`。
4. **规则里的相对引用需要平移**：`sqref="A1:A10"` 配 `formula="$B1>100"`，
   对 `A5` 求值时表达式是 `$B5>100`（列锁定、行相对）。这依赖 7.8 的共享公式平移逻辑。

**M4 之前的处理**：
- 读取时把 `<conditionalFormatting>` 整块**保留在 `Worksheet` 上**（`conditionalFormattings()` 返回原始结构）
- 不参与 `cell()` 的值计算，不影响任何现有 API
- 写入时原样写回

这样即使 M4 还没做，数据也不会丢。

### 6.7 命名样式（`cellStyles`）

必须至少写一项：`<cellStyle name="Normal" xfId="0" builtinId="0"/>`。

`builtinId="0"` 对应英文的 "Normal"，中文 Excel 显示"常规"。**名字随语言变，但 `builtinId` 不变**——所以写入时用 `name="Normal"`，Excel 会按 locale 显示。

没有这一项，Excel 打开时会报"需要修复"，提示"命名样式缺失"。

### 6.8 样式池的对外接口

```cangjie
public func styleOf(sheet: String, ref: CellRef): ?CellStyle
public func setStyle(sheet: String, ref: CellRef, style: CellStyle): Unit

/// 样式池当前占用的估算字节数与样式种类数（诊断用）
public func stylePoolBytes(): Int64
public func stylePoolCount(): Int64
```

`styleOf` 返回的是**解析后的完整样式**（已展开 theme 颜色、已应用继承链），不是原始索引。调用方不需要知道 `cellXfs` 的存在。

`setStyle` 内部走 `StylePool.getOrAdd(style)`，返回索引存到单元格上。

`stylePoolBytes()` / `stylePoolCount()` 用于诊断"为什么样式池报警或超限"：

| 现象 | 诊断 |
|---|---|
| `count` 很小但 `bytes` 很大 | 有超长的自定义 `formatCode`，属正常，不用管 |
| `count` 接近 64000 | 真的在用大量不同格式，Excel 也会打不开。必须归并 |
| `count` 跳跃增长（如每加一行加 1） | 有代码在逐行拼不同格式，几乎肯定是 bug |

> 由于 `CellStyle` 已是不可变 struct + 结构哈希去重（2.6.4.2），
> **不会再出现"每格新建实例导致去重失效"的情况**——所以上表没有这一行。

---

## 7. 公式子系统（M2）

需求："是否需要公式求值？m2 实现。"

M1 只保留 `<f>` 原文 + `<v>` 缓存值。**M2 实现完整的求值引擎。**

### 7.1 分层结构

```
FormulaParser        词法 + 递归下降 → AST
      ↓
Evaluator            AST 求值 → CalcValue
      ↓
FunctionRegistry     函数库（分批实现）
      ↓
DependencyGraph      跨单元格/跨表依赖，拓扑排序
      ↓
CalcEngine           整表重算 / 单格求值 / 循环引用处理
```

### 7.2 词法

公式原文形如：

```
=IF(SUM(A1:A10)>100, VLOOKUP(B1,'明细表'!$A:$C, 2, FALSE), "不足")
```

Token 类型：

| Token | 例 |
|---|---|
| `Number` | `123`、`1.5`、`1E-3` |
| `String` | `"abc"`（内部 `""` 转义一个 `"`） |
| `Bool` | `TRUE` / `FALSE` |
| `Error` | `#DIV/0!` 等 |
| `Ref` | `A1`、`$A$1`、`A1:B2`、`$A$1:$B$2` |
| `SheetRef` | `Sheet2!A1`、`'My Sheet'!A1`、`Sheet2!A1:C3` |
| `Func` | `SUM` `IF`（后跟 `(`） |
| `Op` | `+ - * / ^ & % = <> < > <= >=` |
| `Paren` | `( )` |
| `Sep` | `,`（参数分隔） `;`（某些 locale，罕见） |
| `Whitespace` | 引用交集运算符（`A1:A10 B1:B10`） |
| `Colon` | 区域运算符（已在 `Ref` 里处理） |
| `Bang` | sheet 分隔符 |

**注意：Excel 公式里的函数名和引用都不区分大小写。** 归一化到小写再查表。

**外部工作簿引用 `[1]Sheet1!A1` 直接拒绝**，返回 `#REF!` 并在 `CalcReport` 里记一条。

### 7.3 语法与优先级

Excel 的运算符优先级与常见语言**有几处显著不同**：

| 优先级 | 运算符 | 结合性 | 备注 |
|---|---|---|---|
| 1（最高） | `:` 区域、` ` 交集、`,` 联合 | 左 | 在引用解析阶段处理 |
| 2 | 一元 `-` / `+` | 右 | **比 `^` 高** |
| 3 | `%`（后缀） | 左 | |
| 4 | `^` | **左** | **不同于数学惯例** |
| 5 | `*` `/` | 左 | |
| 6 | `+` `-` | 左 | |
| 7 | `&` | 左 | 文本连接 |
| 8（最低） | `=` `<>` `<` `>` `<=` `>=` | 左 | 返回 Bool |

三个著名坑：

```
-2^2   Excel = 4      （一元负优先）
2^3^2  Excel = 64     （左结合，不是 512）
50%    Excel = 0.5
```

**必须按 Excel 的规则实现，不能按数学/其他语言的规则。** 否则用户对不上账。

AST 节点：

```cangjie
enum Expr {
    | Literal(CalcValue)
    | Ref(SheetName, CellRef)                    // 可能是区域，见下
    | Range(SheetName, CellRef, CellRef)
    | Union(Expr, Expr)                          // (A1:A3,B1:B3)
    | Intersect(Expr, Expr)                      // A1:A10 B1:B10
    | Unary(UnaryOp, Expr)
    | Binary(BinOp, Expr, Expr)
    | FuncCall(String, Array<Expr>)
    | ArrayLiteral(Array<Array<Expr>>)           // {1,2;3,4}
}
```

### 7.4 值模型

```cangjie
public enum CalcValue {
    | Empty                    // 空单元格
    | Number(Float64)
    | Text(String)
    | Bool(Bool)
    | Error(CalcError)
    | Array(Array<Array<CalcValue>>)     // 区域求值结果、数组常量
}

public enum CalcError {
    | Null            // #NULL!   交集为空
    | DivZero         // #DIV/0!
    | Value           // #VALUE!  类型错误
    | Ref             // #REF!    无效引用
    | Name            // #NAME?   未知函数/名字
    | Num             // #NUM!    数值域错误
    | NotAvailable    // #N/A     查找失败
    | GettingData     // #GETTING_DATA
}
```

#### 7.4.1 类型转换规则（隐式）

| 运算 | Excel 行为 |
|---|---|
| `Empty` + 数字 | `Empty` 当 `0` |
| `Empty` & 文本 | `Empty` 当 `""` |
| `Bool` + 数字 | `TRUE`=1, `FALSE`=0 |
| 数字文本 `"123"` + 数字 | 自动转数字（`"123"+1 = 124`） |
| 非数字文本 `"abc"` + 数字 | `#VALUE!` |
| 文本比较 | **不区分大小写**（`"ABC"="abc"` 为 TRUE） |
| 文本排序比较 | 按 locale 排序，不是 ASCII |
| `=`` 比较数字与文本 | 数字 < 文本（类型序：Number < Text < Bool） |

**文本比较不区分大小写**这一条最容易漏。Excel 的 `="A"="a"` 返回 `TRUE`，和几乎所有编程语言相反。

#### 7.4.2 错误传播

任何操作数是 `Error`，结果就是**该错误**。多参数函数按**参数顺序**取第一个错误，不是"最后一个"。

```
=1 + #DIV/0! + #VALUE!     →  #DIV/0!   （取第一个）
```

例外：`IFERROR` / `IFNA` / `ISERROR` / `ISERR` / `ISNA` 会拦截错误，不传播。

### 7.5 函数库

按批次实现，M2 内分两个子阶段：

#### 7.5.1 M2-a：核心 40 个

| 类别 | 函数 |
|---|---|
| 数学 | `SUM` `SUMIF` `SUMIFS` `PRODUCT` `ABS` `ROUND` `ROUNDUP` `ROUNDDOWN` `INT` `MOD` `POWER` `SQRT` `SIGN` `TRUNC` |
| 统计 | `AVERAGE` `AVERAGEIF` `COUNT` `COUNTA` `COUNTBLANK` `COUNTIF` `COUNTIFS` `MIN` `MAX` `MEDIAN` |
| 逻辑 | `IF` `IFS` `AND` `OR` `NOT` `XOR` `IFERROR` `IFNA` `SWITCH` |
| 文本 | `CONCATENATE` `CONCAT` `LEN` `LEFT` `RIGHT` `MID` `TRIM` `UPPER` `LOWER` `TEXT` `VALUE` |
| 日期 | `DATE` `YEAR` `MONTH` `DAY` `HOUR` `MINUTE` `SECOND` `TODAY` `NOW` |
| 查找 | `VLOOKUP` `INDEX` `MATCH` |
| 信息 | `ISBLANK` `ISERROR` `ISNUMBER` `ISTEXT` `ISLOGICAL` `ISNA` |

#### 7.5.2 M2-b：扩展 100 个

| 类别 | 代表函数 |
|---|---|
| 统计 | `STDEV.P` `STDEV.S` `VAR.P` `VAR.S` `LARGE` `SMALL` `RANK` `PERCENTILE` `QUARTILE` `MODE` `CORREL` `SLOPE` `INTERCEPT` `FORECAST` |
| 查找 | `HLOOKUP` `LOOKUP` `XLOOKUP` `CHOOSE` `OFFSET` `INDIRECT` `ROW` `COLUMN` `ROWS` `COLUMNS` `TRANSPOSE` `UNIQUE` `SORT` `FILTER` |
| 文本 | `SUBSTITUTE` `REPLACE` `FIND` `SEARCH` `REPT` `TEXTJOIN` `EXACT` `PROPER` `CLEAN` `CHAR` `CODE` `UNICHAR` `UNICODE` `T` |
| 数学 | `SUMPRODUCT` `CEILING` `FLOOR` `MROUND` `RAND` `RANDBETWEEN` `LOG` `LOG10` `LN` `EXP` `PI` `SIN` `COS` `TAN` `DEGREES` `RADIANS` `GCD` `LCM` `FACT` |
| 日期 | `DATEVALUE` `TIMEVALUE` `EDATE` `EOMONTH` `WEEKDAY` `WEEKNUM` `DATEDIF` `DAYS` `DAYS360` `NETWORKDAYS` `WORKDAY` |
| 财务 | `PMT` `IPMT` `PPMT` `FV` `PV` `NPV` `IRR` `RATE` `NPER` `SLN` `DB` `DDB` |
| 信息 | `ISBLANK` `ISERR` `NA` `TYPE` `CELL` `INFO` `ERROR.TYPE` |

#### 7.5.3 M3：完整库 + 自定义

- 剩余约 200 个函数（工程、数据库、统计高级）
- 数组公式（`{=SUM(A1:A10*B1:B10)}`，Ctrl+Shift+Enter）
- 动态数组（`#SPILL!` 语义）
- 自定义函数注册：`FunctionRegistry.register(name, arity, fn)`

**`OFFSET` / `INDIRECT` 是易失函数**，且会破坏依赖图的静态分析（`INDIRECT("A"&B1)` 的依赖在运行期才知道）。M2-b 里实现它们时，**必须把它们标记为"动态依赖"**，即每次重算都重新求值，不缓存。

### 7.6 依赖图与求值策略

#### 7.6.1 惰性求值（默认）

```cangjie
public func evaluate(sheet: String, ref: CellRef): ?CellValue
```

按需递归：求 `A1` 时，先求它依赖的 `B1`、`C1`，带 memo（本次求值内缓存结果）。**不修改文档状态**，纯粹是查询。

适合："我只想知道 A1 现在是多少"。

#### 7.6.2 整表重算

```cangjie
public func recalculate(options!: CalcOptions = CalcOptions()): CalcReport
```

1. 扫描所有 sheet，收集所有含 `Formula` 的单元格
2. 解析每个公式的 AST（若上次已解析且原文没变，复用缓存）
3. 构建依赖图：`依赖方 → 被依赖方` 的有向边
4. 拓扑排序
5. 按序求值，结果写回 `Formula.cached`
6. 返回 `CalcReport`

```cangjie
public class CalcOptions {
    /// 循环引用迭代次数。0 = 不迭代，直接报 #REF!
    public var maxIterations: Int64 = 0
    /// 迭代收敛阈值（相邻两次迭代的最大差值）
    public var convergence: Float64 = 1e-9
    /// 易失函数随机种子（确定性测试用）。None = 用系统时间
    public var volatileSeed: ?Int64 = None
    /// 是否把结果写回单元格缓存
    public var writeBack: Bool = true
    /// 单次重算的时间上限（毫秒），0 = 不限
    public var timeLimitMs: Int64 = 0
}

public class CalcReport {
    public let evaluated: Int64
    public let cached: Int64                       // 命中缓存跳过求值的数量
    public let elapsedMs: Int64
    public let issues: Array<CalcIssue>
}

public class CalcIssue {
    public let sheet: String
    public let ref: CellRef
    public let kind: CalcIssueKind                 // Circular / UnknownFunction / InvalidRef / ...
    public let message: String
}
```

#### 7.6.3 循环引用

默认 `maxIterations = 0`：检测到环就报 `#REF!`（Excel 的行为是弹警告并显示 0，但那是 UI 层，这里用错误值更明确），并记一条 `CalcIssue(kind: Circular)`。

`maxIterations > 0` 时走不动点迭代：

```
1. 环上所有单元格初始化为 0（Excel 的行为）
2. 重复 N 次：
   a. 按序求值环上所有单元格
   b. 若 max |新值 - 旧值| < convergence，提前收敛
3. 未收敛则记 warning，保留最后一次结果
```

**迭代求值必须按固定顺序**，不能用 HashMap 的遍历顺序——否则结果不可复现。

#### 7.6.4 易失函数

`NOW` `TODAY` `RAND` `RANDBETWEEN` `OFFSET` `INDIRECT` `CELL` `INFO` 每次调用结果可能不同。

处理：

- 标记为 `volatile`，重算时强制重新求值，不走 memo
- `NOW`/`TODAY` 在同一次 `recalculate()` 内**只取一次系统时间**（Excel 的行为），所有调用共享
- `RAND` 用可注入的种子，`volatileSeed` 给了就用它，保证测试可复现

#### 7.6.5 三个必须说清的边界

**（1）解析时不自动重算。** 打开文件 → 拿到的是缓存值。要最新值必须显式 `recalculate()`。理由见 2.3。

**（2）重算不写回文件，除非显式 `write()`。** `recalculate(writeBack: true)` 只改内存模型。

**（3）重算不影响 `CellValue.Formula` 的原文。** 只更新第二个字段（缓存值）。

### 7.7 日期函数的 1900 陷阱

`DATE(1900, 2, 29)` 在 Excel 里返回 `#NUM!`（因为 1900-02-29 不存在），但 `DATE(1900, 3, 1)` 返回 serial 61。

`DATE` 的实现不能直接用 `DateTime` 构造：

```
DATE(y, m, d):
  1. 月份归一化：m 超出 1..12 时向年份进位/借位
  2. d 超出当月天数时向月份进位（Excel 允许 DATE(2024,1,32) = 2024-02-01）
  3. 若结果为 1900-02-29，返回 #NUM!
  4. 若结果 < 1900-01-01，返回 #NUM!
  5. DateTime → serial（走 5.2 的规则）
```

**`DATE` 的溢出行为是 Excel 的特性**：`DATE(2024,13,1)` = `2025-01-01`，`DATE(2024,1,0)` = `2023-12-31`。这不是 bug，必须实现。

### 7.8 与读取流程的接口

```cangjie
// 读取时
<f>SUM(A1:A10)</f>   →  Formula.src = "SUM(A1:A10)"
<v>55</v>            →  Formula.cached = Some(Number(55))
// <f> 存在但 <v> 缺失  →  Formula.cached = None
```

`<f>` 的 `t="shared"` / `t="array"` 两种特殊形式：

```xml
<!-- 共享公式：只在主单元格写完整公式，其余引用 si -->
<c r="B2"><f t="shared" ref="B2:B100" si="0">A2*2</f><v>20</v></c>
<c r="B3"><f t="shared" si="0"/><v>30</v></c>

<!-- 数组公式 -->
<c r="C1"><f t="array" ref="C1:C10">{=A1:A10*B1:B10}</f><v>100</v></c>
```

处理策略：

| 形式 | M1 | M2 |
|---|---|---|
| 普通 `<f>` | 原文保留 | 求值 |
| `t="shared"` | 原文保留（从主单元格复制） + 记 warning | **实现相对引用平移**（见下） |
| `t="array"` | 原文保留 + 记 warning | 只求值左上角，其余记 `NotSupported` |

**共享公式的相对引用平移**：`B2:B100` 共享 `A2*2`，则 `B3` 的等效公式是 `A3*2`。平移规则：相对引用按行/列偏移量调整，`$` 修饰的部分不动。

```
shiftRef(ref, dRow, dCol):
    row' = ref.rowAbs ? ref.row : ref.row + dRow
    col' = ref.colAbs ? ref.col : ref.col + dCol
    若 row' < 1 或 col' < 1 → #REF!
```

这个规则同样用于实现"复制粘贴"，所以是必须的基础设施。

### 7.9 明确不支持

| 特性 | 行为 |
|---|---|
| 外部工作簿 `[1]Sheet1!A1` | `#REF!` + `CalcIssue` |
| VBA 自定义函数 `Module1.MyFunc()` | `#NAME?` + `CalcIssue` |
| `GETPIVOTDATA` | `#REF!` + `CalcIssue` |
| `WEBSERVICE` / `RTD` / `FILTERXML` | `#VALUE!` + `CalcIssue` |
| `STOCKHISTORY` / 动态数组函数 | M3 |
| 迭代计算（默认） | `#REF!`，除非 `maxIterations > 0` |

---

## 8. 关键技术难点

### 8.1 XML 处理：交给 f_xml

**原设计里的"自写标签扫描器"方案已废弃**，改用 `f_xml` 模块（见 `f_xml模块设计.md`）。

原因是命名空间：xlsx 的 `<row>` 和 `<x:row>` 是同一个元素，纯字符串扫描遇到带前缀的生成器（LibreOffice 导出常见）会全线失配。`f_xml` 在解析时就完成前缀解析，产出 `QName{prefix, local, uri}`，按 local name 匹配即可。

按文件大小选模式：

| 部件 | 模式 | 理由 |
|---|---|---|
| `[Content_Types].xml`、`xl/workbook.xml`、`_rels/*.rels` | **DOM** | 几 KB，`child()` 取值最省事 |
| `xl/styles.xml`、`xl/theme/theme1.xml` | **DOM** | 几十 KB，且需要按索引互查，DOM 方便 |
| `xl/worksheets/sheetN.xml` | **事件流** | 10 万行的 sheet 解压后几十 MB，建树会打爆内存 |
| `xl/sharedStrings.xml` | **事件流** | 可能几万个 `<si>`，逐个产出后丢弃 |

事件模式下 `onEndElement(row)` 里立刻把这一行交给上层入库，然后丢弃——内存与行数无关。

`f_excel` 侧只需实现一个 `SheetRowHandler <: XmlEventHandler`（约 100 行），不关心词法、命名空间、实体解码：

```cangjie
class SheetRowHandler <: XmlEventHandler {
    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        if (name.local == "row") { currentRow = RowBuilder(attrs) }
        else if (name.local == "c") { currentCell = CellBuilder(attrs) }
        else if (name.local == "v") { inValue = true }
        else if (name.local == "is") { inInlineString = true }
        else if (name.local == "f") { inFormula = true }
        XmlAction.Continue
    }
    public func onText(text: String): XmlAction {
        if (inValue) { currentCell.appendValue(text) }
        else if (inInlineString) { currentCell.appendText(text) }
        else if (inFormula) { currentCell.appendFormula(text) }
        XmlAction.Continue
    }
    public func onEndElement(name: QName): XmlAction {
        if (name.local == "c") { currentRow.add(currentCell) }
        else if (name.local == "row") { sink.write(currentRow); currentRow = null }   // 立刻交出去
        XmlAction.Continue
    }
}
```

> `XmlEventHandler` 的回调返回 `XmlAction`（`Continue` / `SkipSubtree` / `Stop`），
> 这是 f_xml v0.4 起的约定，详见其设计文档 3.1 / 3.3。

所有匹配都用 `name.local`，不拼前缀——这是 f_xml 的 `QName` 设计带来的直接好处。

**写侧同样交给 f_xml**：`XmlWriter` 从 v1.2 起提供增量接口（`startElement` / `text` /
`endElement` / `emptyElement` / `writeDeclaration`），f_excel 逐行把 `<row>` / `<c>` 事件写进去，
命名空间声明、转义、缩进、缓冲与编码都由 f_xml 负责：

```cangjie
let xml = XmlWriter(entryStream)                  // entryStream = ZipWriter.openEntry("xl/worksheets/sheet1.xml")
xml.writeDeclaration(encoding: "UTF-8")
xml.startElement(QName("worksheet", uri: Some(NS_SPREADSHEET)))
xml.startElement(QName("sheetData"))
// 每行：xml.startElement(row) → 每格 startElement(c) + text(v) + endElement(c) → endElement(row)
xml.endElement(QName("sheetData"))
xml.endElement(QName("worksheet"))
xml.flush()
```

f_excel 只保留**语义层**的两件事：非法控制字符剔除（`ControlCharStripped`，写进 `text()` 之前）
与 Excel 上限校验（行/列/文本长度）；XML 语法与转义不再由 f_excel 实现。

### 8.2 共享字符串

```xml
<sst count="2" uniqueCount="2">
  <si><t>Hello</t></si>
  <si><r><t>Rich</t></r><r><t> text</t></r></si>
</sst>
```

- `<si>` 内可能有**多个 `<r><t>`**（富文本分段），必须全部拼接
- `<t xml:space="preserve">` 表示保留首尾空格，否则应 trim
- `<si>` 内还可能有 `<rPh>`（注音，日文），要**跳过**——`<rPh>` 里的 `<t>` 不是正文

**`xml:space="preserve"` 的判定依赖 `f_xml` 正确解析 `xml:` 前缀**（它绑定到 `http://www.w3.org/XML/1998/namespace`，不需要声明）。

### 8.3 合并单元格

```xml
<mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells>
```

只有左上角单元格有值，其余为空。**必须把合并区域暴露给调用方**，否则读出来的表格结构是残缺的——比如一个跨 5 列的表头，读出来只有 1 个有值的格子。

`mergedValue(row, col)` 返回所属区域左上角的值，这是知识库场景最常用的语义。

### 8.4 富文本与共享字符串的交叉

`<si>` 里的富文本分段可以有自己的 `<rPr>`（run properties），结构与 `styles.xml` 的 `<font>` 类似但不完全相同（多 `outline`/`shadow`/`vertAlign`）。

M1 忽略 `rPr`，只取文本。M2 解析为 `TextRun.font`，**但不进 `CellStyle` 体系**——它是独立的一套字体描述。

### 8.5 数值精度的双向陷阱

**读**：`Float64.parse("0.1")` 得到最接近 0.1 的二进制浮点。Excel 内部也是这样，所以往返一致。

**写**：必须输出最短往返串。若输出 `"0.10000000000000001"`，Excel 会显示成 `0.1` 但底层值略有不同，某些比较会出问题。

**整数特判**：`Float64` 的整数值应输出不带小数点的形式。

```
1.0     → "1"          不是 "1.0"
1.5     → "1.5"
1e20    → "1E+20"      科学计数法（Excel 接受）
0.0001  → "0.0001"     不是 "1E-04"（虽然也能读，但难看）
```

**Excel 的有效数字上限是 15 位**。超过 15 位的数字，Excel 会截断显示。这是 Excel 的固有行为，不是我们的 bug——但往返测试时要注意，`Float64` 有 17 位精度，写 17 位再读回来 Excel 可能显示不同的值。

### 8.6 空 sheet 与零行 sheet

`<sheetData/>` 是合法的空 sheet。必须能处理，且 `rowCount()` 返回 0。

写入空 sheet 时，`<sheetData/>` 不能省略（虽然 schema 里 `sheetData` 是必需的 `minOccurs=1`）。

---

## 9. 内存与性能

### 9.1 内存模型

**非流式读（一次全解析）：**

| 数据 | 估算 |
|---|---|
| 10 万行 × 10 列 = 100 万单元格 | 每个 `CellValue` 约 32~48 字节 → **32~48 MB** |
| 原始 XML（解压后） | 50~100 MB |
| ZIP 缓冲 | 文件大小 × 1 |

**峰值可能达到文件的 3~5 倍。** 对 10 MB 的 xlsx 约 50 MB 峰值，可接受；对 100 MB 的大表就要用流式写 + 按需读。

**流式写：**

| 数据 | 估算 |
|---|---|
| 当前行 | 几 KB |
| 样式池 | 种类数 × ~200 字节（典型 < 100 KB） |
| 压缩缓冲（f_zip 内部） | 固定几十 KB |
| XML 生成缓冲 | 固定 8 KB |

**与总行数无关。** 这是流式写入的核心价值。

**流式读（`ExcelSheetStream`，2.7）：**

| 数据 | 估算 | 与行数有关？ |
|---|---|---|
| 当前行（`RowData`） | 几 KB | ❌ |
| `styles` / `workbook` / `rels`（DOM） | KB ~ 几 MB | ❌ |
| `sharedStrings` | 唯一字符串数 × 平均长度 | ✅ **唯一增长项** |
| 解压缓冲（`ZipReader.open`） | 固定几十 KB | ❌ |
| f_xml 事件缓冲 | 固定几十 KB | ❌ |
| `spool` 临时文件（`InputStream` 输入） | 0 内存 / 磁盘 = 包大小 | ❌（在盘上） |

**除 `sharedStrings` 外全部恒定**；`loadSharedStrings = false` 可把它也降为 0（代价是 `t="s"` 变 `Empty`）。

### 9.2 优化清单

| 优化 | 阶段 | 说明 |
|---|---|---|
| 解析完立即丢弃 XML 缓冲区 | M1 | 不要同时持有压缩包、XML、模型三份 |
| `ZipReader(path)` 走 seek | M1 | 小文件无所谓，大文件避免全量缓冲 |
| sheet 走事件流 | M1 | 内存与行数无关 |
| 样式池去重 | M2 | 顺带减小输出体积 |
| 公式 AST 缓存 | M2 | 原文没变就复用 AST |
| 行级流式读（`ExcelSheetStream`） | M2 | 边读边解析，逐行丢弃 |
| `InputStream` 输入落临时文件 | M2 | 换取"包大小不进内存" |
| 按需解析 sheet（`eager = false`） | M3 | 只解析被访问的 sheet（保留模型场景） |
| `sharedStrings` 磁盘索引 | M3 | 大表共享字符串不再常驻内存 |
| 单元格用紧凑结构 | M3 | `Array<Float64>` + 类型位图，而不是每格一个对象 |

### 9.3 性能预估

| 操作 | 1 万行 × 10 列 | 10 万行 × 10 列 |
|---|---|---|
| 解析（不含公式） | 100~300 ms | 1~3 s |
| 解析（流式逐行） | 100~300 ms | 1~3 s（内存恒定） |
| 生成（非流式） | 100~300 ms | 1~3 s |
| 生成（流式） | 100~300 ms | 1~3 s（内存恒定） |
| ZIP 解压/压缩（占大头） | 50~150 ms | 0.5~1.5 s |
| 公式重算（每格一个 SUM） | 10~50 ms | 100~500 ms |

**瓶颈通常在 ZIP 的 deflate 和 XML 的字符串处理**，不在数值转换。公式重算在依赖图建好之后很快，慢在建图（要遍历所有单元格）。
流式读写的绝对耗时与整文档模式接近——省的是**内存**，不是 CPU。

### 9.4 规模上限

Excel 本身的限制：

| 项 | 上限 |
|---|---|
| 行 | 1,048,576 |
| 列 | 16,384（XFD） |
| 单元格文本长度 | 32,767 字符 |
| 公式长度 | 8,192 字符 |
| 单文件 sheet 数 | 受内存限制，实践上几百 |

超出时：读取截断并记 warning；写入抛 `ExcelException`。

---

## 10. 错误处理

```cangjie
public class ExcelException <: Exception {
    public init(message: String)
}

public class ExcelWarning {
    public let kind: ExcelWarningKind
    public let message: String
    public let sheet: ?String
    public let ref: ?CellRef
}
```

| 情况 | 处理 |
|---|---|
| 不是有效 ZIP | 包装 `ZipException` → `ExcelException("不是有效的 xlsx 文件")` |
| 缺 `xl/workbook.xml` | `ExcelException("缺少 workbook.xml，可能不是 xlsx 文件")` |
| sheet 的 rels 指向不存在 | 跳过该 sheet，记 warning，不整体失败 |
| 单元格 `r` 属性非法 | 按顺序推断，记 warning |
| `t="s"` 但索引越界 | 视为 `Empty`，记 warning |
| 数字解析失败 | 视为 `Text` 原文保留，不丢数据 |
| 写入文本含控制字符 | 剔除并记 warning，不抛异常 |
| 写入超 Excel 上限 | 抛 `ExcelException` |
| 流式写入行号乱序 | 抛 `ExcelException` |
| 流式写入中途失败 | 进入 `Failed` 状态，产物残缺由调用方丢弃（2.6.7） |
| 流式读 XML 格式错误 | `next()` 抛 `ExcelException`，带 sheet 名与行号（2.7.8） |
| 流式读 `spool` 目录不可写 | `open` 抛 `ExcelException`，提示 `spoolDir` / `spool = false` |
| 循环引用（`maxIterations=0`） | 结果 `#REF!`，记 `CalcIssue` |
| 未知函数 | 结果 `#NAME?`，记 `CalcIssue` |

**原则：读取要宽容，写入要严格。** 读取时单个坏单元格不该让整个文件失败——知识库场景下"少一格"远好于"整份文档进不去"。写入时若产出非法文件，宁可当场报错。

---

## 11. 测试要点

### 11.1 解析（外部造、我们读）

| 样本 | 验证点 |
|---|---|
| Excel 手工保存的 xlsx | 基本功能 |
| LibreOffice 保存的 xlsx | 命名空间前缀差异 |
| Google Sheets 导出 | sharedStrings 结构差异 |
| WPS 保存的 xlsx | 国内常见，主题/字体差异 |
| Python openpyxl 生成 | 边界格式、样式去重 |
| 含中文 / emoji / 控制字符 | 转义与编码 |
| 含合并单元格 | 区域识别、`mergedValue` |
| 含日期（1900 / 1904 两种） | 基准判断 |
| 含 `[h]:mm:ss` | `TimeSpan` 识别（M2） |
| 含公式（普通/共享/数组） | 原文 + 缓存值；共享公式平移 |
| 含 theme 颜色 | theme1.xml 解析 + tint 计算 |
| 含 `indexed` 颜色 | 64 色板 |
| 空 sheet / 只有 1 格 | 边界 |
| 超大 sheet（10 万行） | 内存与耗时 |
| 超大 sheet + 流式读 | 峰值内存与行数无关（9.1）；行内容与整文档模式逐行一致 |
| 流式读 + 稀疏行 / 缺 `<row>` | 行号推断、不补空行（2.7.5） |
| 流式读 + 合并单元格 | 流结束后 `mergedRanges()` 有值，流中为空（2.7.6） |
| 流式读 + `loadSharedStrings = false` | `t="s"` 变 `Empty` |
| 流式读 + `spool = false` | 退化为全量缓冲并记 warning |

### 11.2 生成（我们写、Excel 读）

**必须用真实 Excel 打开验证**，因为 Excel 对最小 xlsx 的要求比解析器严格得多：

- 能打开不报"需要修复"
- 中文不乱码
- 数字精度不丢
- 日期显示为日期而不是 5 位数字
- 合并单元格正确
- 样式（背景色、字体、边框）正确显示
- 流式生成的大文件也能打开

再用 openpyxl 读回来做结构比对（可自动化）。

### 11.3 往返一致性

```
xlsx → 解析 → 模型 → 生成 → xlsx → 解析 → 模型
```

两个模型逐单元格比对。**注意值语义 vs 格式语义**：往返后可能丢失不支持的特性，但值、类型、样式必须一致。

**流式与整文档必须等价**：同一文件分别用 `ExcelDocument` 与 `ExcelSheetStream` 读，
逐行比对 `index` / `cells`（含类型），必须完全一致；差异只允许出现在"流式通道拿不到的语义"（合并区域，2.7.6）。

### 11.4 公式求值的验收

**不能只测自己造的样例**——公式语义的坑太多。

| 来源 | 用途 |
|---|---|
| LibreOffice `sc/qa/unit/data/functions/` | 各函数的期望值，公开且覆盖广 |
| 微软官方函数文档的示例 | 逐函数比对 |
| 自建 fixture：手写 xlsx + 用 Excel 算好结果 | 端到端 |

**逐函数验收标准**：给定相同输入，结果与 Excel 的差异在 1e-9 相对误差内（浮点），或完全一致（文本/布尔/错误）。

### 11.5 样式往返的验收

```
造一个有 20 种样式的表 → 我们读 → 我们写 → Excel 打开
→ 逐格比对背景色/字体/边框/数字格式
```

theme 颜色的验证必须对照 Excel 实际显示，不能只看 XML 里的 tint 值——tint 算法错了在 XML 层面看不出来。

### 11.6 必须单测的小函数

| 函数 | 测试点 |
|---|---|
| 列号 ↔ 字母 | `A→1, Z→26, AA→27, AZ→52, BA→53, ZZ→702, AAA→703, XFD→16384` |
| `CellRef.parse` | 2.4.2 全表 |
| serial ↔ DateTime | 1900/1904 两种基准，serial 59/60/61 |
| tint 计算 | 0 / -1 / +1 / 0.4 |
| `DATE` 溢出 | `DATE(2024,13,1)`、`DATE(2024,1,0)`、`DATE(1900,2,29)` |
| 运算符优先级 | `-2^2=4`、`2^3^2=64`、`50%=0.5` |
| 文本比较 | `"A"="a"` 为 TRUE |
| **`[h]` 判定 vs 颜色方括号** | `[Red][h]:mm` → TimeSpan；`[Red]0.00` → Number；`[Blue][m]:ss` → TimeSpan；`[$-409]h:mm` → Time 但非 TimeSpan；`[>=100]0.00` → Number |
| `[h]` / `[m]` / `[s]` 与 `[hh]` / `[mm]` / `[ss]` | 全部识别为 TimeSpan |
| 方括号内混合内容 | `[h:ss]` → 不是时长标记（不是全 h/m/s）；`[Red]` / `[Color10]` / `[$-409]` → 不是时长 |
| 结构哈希 | 两个字段全同的 `CellStyle` 哈希相等；任一字段不同则哈希不同（抽样 1 万对） |
| 哈希碰撞兜底 | 构造哈希相同但字段不同的两个样式，断言池里是两项而不是一项 |
| 行号推断 | `<row>` 无 `r` 时按上一行 +1；首行无 `r` 时为 1 |
| 列号推断 | `<c>` 无 `r` 时按前一列 +1；行首无 `r` 时为 1 |
| 稀疏行产出 | `<row r="5"><c r="C5">` 只产出一个 cell（col=3），不补 A/B |
| 流式行序 | 乱序 `<row r="9">` 后接 `<row r="3">` 照原样产出并记 warning（不抛、不重排） |
| 空行产出 | `<row r="5"/>` 产出 `cells` 为空的行 |
| `mergedRanges` 时序 | 流中为空数组，`next()` 返回 `None` 后才有值 |
| `next()` 幂等性 | `None` 之后继续 `next()` 仍返回 `None`；`close()` 后 `next()` 抛异常 |
| 流式 ↔ 整文档等价 | 同一 fixture 两条通道逐行比对完全一致 |

---

## 12. 里程碑与实施顺序

### M1：读取 + 最小可用生成

| 步骤 | 内容 | 验收 |
|---|---|---|
| **P-1** | 完成前置模块 `f_xml`（事件解析 + DOM + 序列化）与 `f_zip`（`ZipReader`/`ZipWriter`） | 能解包并解析带命名空间前缀的 xlsx 片段 |
| P0 | `CellRef` + 行列转换 + `f_xml` 接入封装 | 单测 2.4.2 全表通过 |
| P1 | 读 workbook + rels + 最小 sheet | 能列出 sheet 名、读出 A1 的值 |
| P2 | sharedStrings + 各 `t` 类型 | 文本/数字/布尔/错误全通 |
| P3 | 生成最小 xlsx（`inlineStr`） | **Excel 能打开不报修复** |
| P4 | 日期识别（内置 14-22/45-47 + 自定义启发式）+ 写入绑样式 | 日期往返一致；`autoDetectDate` 开关生效 |
| P5 | 合并单元格 + 多 sheet | 结构完整，`mergedValue` 正确 |
| P6 | 双套单元格 API 收尾 + `ExcelReadOptions` 全项生效 | `(row,col)` 与 `"A1"` 结果一致 |

**P3 是最关键的里程碑**：能生成一个 Excel 认可的文件，说明对 OOXML 必需部件的理解是完整的。这一步之前所有工作都只是"自己读自己"。

### M2：完整语义

| 步骤 | 内容 | 验收 |
|---|---|---|
| M2-a | 样式子系统：完整读写（字体/填充/边框/对齐/保护/theme/indexed） | 20 种样式的表往返后 Excel 显示一致 |
| M2-b | 公式引擎核心：词法 + AST + 40 个函数 + 依赖图 + 循环检测 | 40 个函数逐一对照 Excel |
| M2-c | 公式引擎扩展：+100 个函数、共享公式平移、易失函数 | LibreOffice 函数测试集通过率 > 90% |
| M2-d | `TimeSpan`（`[h]:mm:ss`）、富文本 `RichText` | 往返一致 |
| M2-e | 流式写入 `ExcelWriter` | 100 万行生成，内存峰值 < 20 MB |
| M2-f | 流式读取 `ExcelSheetStream`（2.7） | 100 万行逐行读，内存峰值 < 20 MB；与整文档通道逐行等价 |

**M2-a 必须先于 M2-b/c**：公式的日期函数依赖序列号转换，而序列号转换依赖样式判定。

**M2-e / M2-f 合起来是"边读边解析 + 边产生边写出"的闭环**：`src.rows(sheet)` 直接喂
`writer.writeSheet(sheet, rows)`，两端常量内存（2.7.9 示例 2）。实现顺序上 M2-f 不依赖 M2-a~d，
但依赖 M1 的取值逻辑（`t` 类型表、sharedStrings）。

### M3：规模化与完整度

| 步骤 | 内容 | 验收 |
|---|---|---|
| M3-a | 流式读增强：`sharedStrings` 磁盘索引、`spool` 零拷贝优化 | 100 MB / 百万唯一字符串，RSS < 50 MB |
| M3-a2 | 按需解析 sheet（`eager = false`） | 打开 100 MB 文件 < 100 MB RSS |
| M3-b | 数组公式、动态数组 | `#SPILL!` 语义正确 |
| M3-c | 剩余函数库 | 覆盖 350+ 函数 |
| M3-d | 紧凑单元格结构 | 100 万单元格 < 20 MB |
| M3-e | ods 支持评估（模块名已解耦） | 可行性报告 |

### M4：条件格式语义

| 步骤 | 内容 | 验收 |
|---|---|---|
| M4-a | `<conditionalFormatting>` / `<cfRule>` 解析 + `sqref` 展开 | 13 种 `CfRuleType` 都能读出来并原样写回 |
| M4-b | 规则求值：`cellIs` / `expression` / `containsText` 等**基于公式**的类型 | 相对引用平移到目标单元格后结果正确 |
| M4-c | `colorScale` / `dataBar` / `iconSet` 的插值求值 | 与 Excel 显示的颜色/图形一致 |
| M4-d | `priority` 排序 + `stopIfTrue` + `matchedRules()` | 多规则命中的用例结果正确 |

**为什么 M4 不能提前**：M4-b 依赖公式引擎（M2）与相对引用平移（M2-c 的共享公式逻辑）。
M4-c 的插值不依赖公式，可以提前到 M3，但单独做意义不大——条件格式的主要用途是"基于值的判断"。

**M4 之前的兼容策略**（6.6.2）：`<conditionalFormatting>` 整块原样保留在 `Worksheet` 上，
读得到、写得出，只是不参与求值。这样数据不丢，后续补 M4 时不需要重新解析历史文件。

---

## 13. 已定事项与剩余问题

### 13.1 已定

| 原问题 | 决定 | 落点 |
|---|---|---|
| `init()` 语义 | 纯内存模型初始化，不碰 `File`、不做解析 | 2.1 |
| 公式求值 | **M2 实现**，默认不自动重算 | 第 7 章 |
| 样式读写 | **M2 完整实现** | 第 6 章 |
| 单元格访问 | `(row, col)` 与 `"A1"` **两套都提供**，共用 `CellRef` | 2.4 |
| 流式写入 | **提供**，迭代器驱动 + `f_zip.openEntry` 推模式直写条目流 | 2.6 |
| worksheet XML 生成 | **交给 `f_xml.XmlWriter` 增量接口**，f_excel 不自写发射器与转义表 | 2.6.7 / 8.1 |
| 日期自动识别 | **默认开**，`ExcelReadOptions.autoDetectDate` 可关 | 2.5 |
| `TimeSpan` | **进 `CellValue`**，M2 实施；不做 `isTimeSpan()` 补丁 | 5.5 |
| `dxfs` 语义 | **做**，排 **M4**（因依赖公式引擎）；M2~M3 只存取 | 6.6 |
| 样式池上限 | **条目数**：Linux 64000（对齐 Excel / excelize），**其他 8192** | 2.6.4.1 |
| 告警阈值 | **不动态算**：Linux 16 MB，其他 2 MB（固定值，可解释） | 2.6.4.1 |
| `CellStyle` 语义 | **`struct` + 全 `let`**，不可变值语义；去重靠结构哈希 + 逐字段兜底 | 2.6.4.2 |
| 深比较时机 | **不能"出错后再做"**（流式无法回退）；靠三层查找让成本可忽略 | 2.6.4.3 / 2.6.4.4 |
| `[Red][h]:mm` | 方括号内容**全为 h/m/s** 才判为时长；判表见 5.5.3，已入单测 | 5.5.3 / 11.6 |
| `Font.name` | **`?String`，默认 `None` = 不写 `<name>`**，用 Excel 自己的默认 | 6.4 |
| `Duration` 表示上限 | **约 2920 亿年**（`Int64.Max` 秒）；构造用 `Duration.second * n` | 5.5.4 |
| `toNanoseconds()` 边界 | **约 292 年**（`Int64.Max` 纳秒），超出抛 `ArithmeticException`。**不要拿它当上界** | 5.5.4 |
| `Duration` ↔ serial | 正向拆秒+纳秒构造；反向先用 `toSeconds()` 再对余数取纳秒 | 5.5.4 |
| `Duration` 溢出行为 | **`Duration.second * n` 溢出会抛 `ArithmeticException`**（已实测），与显式阈值构成双保险 | 5.5.4 |
| `toSeconds()` 边界 | **对超长 `Duration` 也会抛**（已实测）；反向转换用 try-catch 兜住，不猜边界 | 5.5.4 |
| 超限文案 | **分两版**：`maxCellStyles >= 64000` 说"Excel 打不开"，否则说"这是本平台保护，可调大" | 2.6.4.5 |
| `fonts[0]` | **必须写一条**，最少 `<font><sz val="11"/></font>`；读侧无 `<name>` 时保持 `None` 不补默认 | 6.4 |
| `Font.name` 语义 | `None` = 不写 `<name>`，只有 `<sz>` 的 `<font>` Excel 能正确解读（已确认） | 6.4 |
| OHOS 8192 上限 | 接受：极少触及，且是"内存保护"不是"格式语义"；需要时显式传 64000 | 2.6.4.1 |
| 阈值比例 | 2 MB / 16 MB 与 8192 / 64000 都是"到一半告警"，比例一致 | 2.6.4.1 |
| 流式读的形态 | **行迭代器拉模式**（`ExcelSheetStream` / `RowReader`），不构建 `Worksheet` | 2.7 |
| 流式读的输入 | `Path` 真流式；`InputStream` **默认落临时文件**（`spool = true`），`false` 时退化并记 warning | 2.7.4 |
| 流式读的常驻内存 | **只有 `sharedStrings` 随文件增长**；`loadSharedStrings = false` 可降为 0 | 2.7.4 |
| 流式读的行语义 | 稀疏行不补空行、乱序行照原样产出 + warning、缺 `r` 按推断 | 2.7.5 |
| 流式读 + 合并单元格 | **流中拿不到**（`<mergeCells>` 在 `<sheetData>` 之后）；流结束后 `mergedRanges()` 可用 | 2.7.6 |
| 读写同构 | 读出的 `RowData` **直接**喂 `ExcelWriter.writeSheet`，不设中间类型 | 2.7.2 / 2.7.9 |
| 流式写的失败语义 | **失败即残缺**：不回滚、不跳过坏行；`Failed` 状态后续调用一律抛，产物由调用方丢弃 | 2.6.7 |
| 流式写的 flush | 文本缓冲满/行结束 flush；**不每行 flush OutputStream** | 2.6.7 |
| 流式写的完成判据 | `finish()` 之前 output 不是有效 xlsx（缺中央目录 + EOCD） | 2.6.7 |

### 13.2 仍需确认

**暂无。** 所有决策已落地，可以进入实施。

实施中如遇与本文档不符的实测结果，直接回填到对应章节，并在此处留一条记录
（写清"哪一版怎么错的、实测是什么、改成了什么"——`Duration` 那两轮已经证明这种记录有用）。

---

## 14. 实施记录（M1 落地，v0.10）

### 14.1 与本文档的差异（9 项）

实施时按仓库现状与依赖实测调整了 9 处，逐条见
`doc/spec/implement-f-excel-m1/design.md` §8；摘要：

| # | 差异 | 原因 |
|---|---|---|
| 1 | `ZipReader` 只接受 `String` 路径，对外仍收 `Path` | `f_zip` 现状 |
| 2 | M1 不提供 `eager` / `loadTheme` 选项 | 避免"声明了但无声失效" |
| 3 | `Cell` 用 `numberFormat` 而非 `CellStyle` | M1 兑现不了字体/填充，提前暴露会静默丢样式 |
| 4 | `styles.xml` 是固定最小表（日期格式按需追加） | 无用户样式，样式池留 M2-a |
| 5 | worksheet 由 `f_xml.XmlWriter` **增量接口**生成 | f_xml v1.2 已补齐；f_excel 不自带转义表 |
| 6 | `SheetWriteOptions` M1 只有 `dimension` | 列宽/冻结属 M2 |
| 7 | `mergedRanges()` 挂 `RowReader`，另有 `ExcelSheetStream.lastMergedRanges` | 消歧 2.7.6 |
| 8 | M1 不含 `DocumentProperties` | `docProps` 是可选的，M2 补 |
| 9 | 只写 `inlineStr`，无 `StringWriteMode` | 共享字符串写出与"两端常量内存"是两套取舍，留 M2-e |

### 14.2 实测结论（R1–R4）

| 项 | 实测 | 采用方案 |
|---|---|---|
| R1 `Float64.toString()` | 固定 6 位小数（`1.0 → "1.000000"`），不是最短往返 | `formatNumber`：整数值走 `Int64`；其余按 `g` 精度 1..17 逐个试，取能解析回原值的最短串 |
| R2 `DateTime` | `DateTime.ofUTC(of year:month:dayOfMonth:hour:minute:second:nanosecond:)`、`toUnixTimeStamp().toNanoseconds()` 可用；`monthValue` 已废弃，用 `month.toInteger()` | 日期差按 UTC 日序号算，与本地时区无关 |
| R3 临时文件 | `File.createTemp(Path)` 返回 `File`（不是目录） | `ExcelSheetStream.open(input)` 直接用它做 spool，`file.info.path` 交给 `ZipReader` |
| R4 `cjpm test` 工作目录 | 包根（`f_excel/`） | 夹具现场拼包（`fixtures.cj`），不依赖 `testdata/` |

### 14.3 实施中新增的前置能力

| 模块 | 新增 | 提交 |
|---|---|---|
| `f_zip` | `ZipWriter.openEntry` 推模式条目流、`ZipReader.openEntry(ZipEntry)` | `00ca5ed9` |
| `f_xml` | `XmlWriter` 增量接口；保留前缀 `xml`/`xmlns` 不再输出 `xmlns:xml` | `9066e1cd` / `47751ec0` |

### 14.4 遗留

- 真实 Excel / WPS / LibreOffice 打开验证与 openpyxl 回读属人工/外部验收，见 `doc/spec/implement-f-excel-m1/verification.md`。
- M2-a（样式）、M2-b/c（公式）、M2-d（`TimeSpan` / 富文本）、M3（按需解析 / 磁盘索引）、M4（条件格式）未开始。

### 14.5 M1.5 图片写入（v0.11）

M1 把图片列为"不做"；实际使用中需要把 logo/截图锚定进表，因此补一个**只看写侧**的最小能力：

| 项 | 约定 |
|---|---|
| API | `Worksheet.addImage(path: Path, from: String, to: String)`、`addImage(data, format, from, to)`、`imageCount()` |
| 格式 | png / jpeg（按扩展名判定，jpeg 统一写 `.jpeg` 扩展与 `image/jpeg`） |
| 锚定 | `xdr:twoCellAnchor editAs="oneCell"`，`from`/`to` 为 0 基行列；区间倒置抛 `ExcelException` |
| 部件 | `xl/media/imageN.<ext>`、`xl/drawings/drawingN.xml`、`xl/drawings/_rels/drawingN.xml.rels`、`xl/worksheets/_rels/sheetN.xml.rels` |
| worksheet | `<drawing r:id="rId1"/>` 位于 `mergeCells` 之后、`</worksheet>` 之前；根元素声明 `xmlns:r` |
| ContentTypes | 用到的图片扩展名加 `Default`，每个 drawing 加 `Override` |
| 读侧 | M1.5 **不导入图片**；含图片文件往返后图片丢失（README 已列为已知缺口） |
| 流式写 | `ExcelWriter` 不支持图片（无模型），只支持 `ExcelDocument.write` |

验证：结构用例 4 条 + openpyxl 3.1.5 回读（`len(ws._images) == 1`，anchor 与 `from`/`to` 一致）。

---

## 15. M2 实施记录（v0.12）

### 15.1 已落地

| 子项 | 内容 | 用例 |
|---|---|---|
| M2-a 样式 | `CellStyle` / `Font` / `Fill` / `Border` / `BorderSide` / `Alignment` / `Protection` / `Color` / `Gradient`；`StylesLite` → 全量 `styles.xml` 读写；`StylePool` 深比较去重与自定义 `numFmt`（164 起） | 6 |
| M2-b 公式核心 | 词法 / 递归下降语法（Excel 优先级）/ `CalcValue` / 62 函数 / `Evaluator` / `DependencyGraph` / `CalcEngine`；共享公式平移、数组公式口径 | 20 |
| M2-c 扩展 | 再 81 个函数（总计 **143**）；易失函数共享单次求值上下文；未知函数 `#NAME?` + `CalcIssue` | 8 |
| M2-d 时长/富文本 | `CellValue.TimeSpan`（`[h]` 类格式，100h 可往返）；`RichText` / `TextRun` / `RunFont` 读取 `<r><rPr>` | 6 |

全量 `cjpm test`：**137 通过 / 0 失败**。

### 15.2 与设计的差异

| # | 项 | 处理 |
|---|---|---|
| 1 | `CalcValue` 的数组分支 | 命名 `ArrayValue`，避免与内置 `Array` 冲突 |
| 2 | `CalcError` | 增加 `Circular`（`#CIRC!`）与 `Spill`（`#SPILL!`，M3 用） |
| 3 | `CellValue` | 新增 `TimeSpan(Duration)`；`Duration` 来自 `std.core`，不在 `std.time` |
| 4 | 函数实现 | 注册表统一 `(Evaluator, Array<Expr>)`，`IF`/`IFERROR` 惰性求值；其余函数按需自行求值 |
| 5 | `OFFSET` / `INDIRECT` | 作为动态依赖实现（不进静态依赖图），与设计 7.5.3 的口径一致 |
| 6 | 富文本写侧 | 仍平坦化为文本，`setRichText` 只影响内存模型；M3 再补写出 |
| 7 | 易失函数 | 一次 `evaluate` / `recalculate` 共用一个 `Evaluator`，`NOW`/`TODAY`/`RAND` 序列一致 |
| 8 | 数组公式 | 只保留原文 + 缓存值并告警（`ArrayFormulaUnsupported`），求值只看左上角 |

### 15.3 已知缺口（M3 起）

- `theme1.xml` 主题色板未完整解析，`Color.Theme` 按原值保留。
- 函数 143 个，离 350+ 还有距离；数据库/工程类未实现。
- 富文本写出、动态数组 `#SPILL!`、sharedStrings 磁盘索引、`eager=false` 未做。

---

## 16. M4 实施记录（v0.13）

### 16.1 已落地

| 项 | 内容 |
|---|---|
| 模型 | `ConditionalFormat` / `CfRule` / `CfRuleType`（13 种 + `Unknown`）/ `CfOperator` / `Cfvo` / `CfColorScale` / `CfDataBar` / `CfIconSet` / `CfFormat` / `CfMatch` |
| 解析 | `<conditionalFormatting sqref>`、`<cfRule>` 属性、`<formula>`、`colorScale`/`dataBar`/`iconSet` 的 `cfvo`/`color`；`<dxfs>` 的 fill/font/bold |
| 求值 | `Worksheet.matchedRules`（值规则）与 `CalcEngine.matchedRules`（含 `expression`，相对引用按区域左上角平移）；priority 升序 + `stopIfTrue` |
| 视觉 | `colorScale` 两色/三色线性插值（min/max/num/percent/percentile/formula 阈值）；`dataBar` 长度比例；`iconSet` 分档 |
| 写回 | `mergeCells` 之后按原顺序写 `<conditionalFormatting>`；`StylePool` 收集 dxf 并按值去重，`StylesWriter` 写 `<dxfs>` |
| API | `Worksheet.addConditionalFormat(range, rule)`、`conditionalFormats()`、`matchedRules(row, col)`；`CalcEngine.matchedRules(sheet, row, col)` |

全量 `cjpm test`：**147 通过 / 0 失败**；openpyxl 3.1.5 回读条件格式与 dxfId 正确。

### 16.2 差异与缺口

| 项 | 处理 |
|---|---|
| `Worksheet.matchedRules` 不含 `expression` | 公式求值需要引擎；由 `CalcEngine.matchedRules` 补齐 |
| `timePeriod` / `aboveAverage` | 解析与写回保留，求值不命中（M4 范围外） |
| `iconSet` | 返回 `name:index`，不生成图标图片 |
| `colorScale` 的 `formula` 阈值 | 按数字解析，不求公式 |
| 多段 `sqref` | 求值按段展开；写回保留原字符串 |

---

## 17. M3 实施记录（v0.14，部分）

### 17.1 已落地

| 子项 | 内容 |
|---|---|
| M3-a 磁盘索引 | `SharedStringIndex`：`<si>` 偏移表 + 临时文件按需读取；只用于 `ExcelSheetStream`（`sharedStringsIndex=true`）；临时文件在 `close()` 删除；建索引失败回退全量表 + `IndexDegraded` |
| M3-a2 按需解析 | `ExcelReadOptions.eager=false`：`Worksheet` 懒加载钩子，首次访问触发单表解析；`Path` 重开 ZIP，`InputStream` 先 spool；`skipSheets` 仍生效 |
| M3-b 数组 | 逐元素广播（标量/单行/单列/同形）；`FILTER` / `SORT` / `UNIQUE` / `SEQUENCE`；空筛选 `#CALC!` |
| M3-e ods | `ods-assessment.md`，结论暂不实现 |

### 17.2 已完成（补充）

- 函数库 **350 个**：数学/工程 62、统计/信息/文本 51、动态/查找/日期/财务 37、
  分布/数据库/杂项 53，其余为 M2 的 147。
- 紧凑单元格：`CellStore` 单有序数组 + 二分查找，替代 `HashMap<Int64, CellValue>`；
  顺序解析为追加，随机写入为二分插入，稀疏语义不变。

### 17.3 未完成

- 性能门禁（100 万行 / 100 MB / 100 万格 RSS）未测；20k 批量等价性用例通过。
- 动态数组的 `#SPILL!` 语义未实现（只返回数组值）。

### 17.4 差异

### 17.5 差异

| 项 | 处理 |
|---|---|
| 索引不可 seek 的输入 | 索引走临时文件 seek，不存在退化路径；建索引失败才回退 |
| 懒加载 `close()` | `ExcelDocument` 无 `close()`，`InputStream` spool 的临时文件在进程结束前保留（已文档化） |
| `eager=false` 的 `sheets()` | 返回未解析的 `Worksheet` 句柄，访问才解析 |
