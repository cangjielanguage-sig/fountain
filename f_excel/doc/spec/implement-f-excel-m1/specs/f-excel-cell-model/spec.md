# Spec Delta — f-excel-cell-model

## ADDED Requirements

### Requirement: 列字母与列号的互转

`columnIndex(letters: String): ?Int64` SHALL 把列字母转成 1 起的列号，
`columnLetters(col: Int64): String` SHALL 把列号转回大写字母。算法 SHALL 为

```
字母 → 列号：col = col * 26 + (ch - 'A' + 1)   （'A'=1 … 'Z'=26）
列号 → 字母：col -= 1; prepend('A' + col % 26); col /= 26   （循环至 col == 0）
```

`columnIndex` 的大小写不敏感；`col < 1` 或 `col > 16384` 时 `columnLetters` SHALL 抛
`ExcelException`（不返回空串，空串会被拼进无意义的位置）。

#### Scenario: 边界映射

- **WHEN** 依次转换 `A / Z / AA / AZ / BA / ZZ / AAA / XFD`
- **THEN** 得到 `1 / 26 / 27 / 52 / 53 / 702 / 703 / 16384`，且反向转换逐项还原

#### Scenario: 小写与首位

- **WHEN** `columnIndex("a")`
- **THEN** 返回 `Some(1)`

#### Scenario: 超上限拒绝

- **WHEN** `columnLetters(16385)`
- **THEN** 抛 `ExcelException`，消息含 `16385` 与上限 `16384`

### Requirement: `CellRef` 是值类型

`CellRef` SHALL 是 `struct`，字段全 `let`：`row: Int64`（1 起）、`col: Int64`（1 起）、
`rowAbs: Bool`、`colAbs: Bool`。SHALL 声明 `<: Equatable<CellRef> & ToString` 并
**显式实现** `operator func ==` 与 `operator func <`（先行后列）。

#### Scenario: 相等忽略 `$` 之外的差异

- **WHEN** `CellRef.parse("A1") == CellRef.parse("a1")`
- **THEN** 为 `true`

#### Scenario: 排序先行后列

- **WHEN** 比较 `B1` 与 `A2`
- **THEN** `B1 < A2` 为 `false`（第 1 行先于第 2 行）

### Requirement: `CellRef.parse` 的严格口径

`parse(s: String): ?CellRef` SHALL 按下列全表处理，**不得"尽力返回"**：

| 输入 | 结果 |
|---|---|
| `A1` | row=1, col=1 |
| `a1` | row=1, col=1 |
| `$A$1` | row=1, col=1, `rowAbs` 与 `colAbs` 均 `true` |
| `$A1` / `A$1` | 仅对应方向为 `true` |
| `A01` | row=1, col=1（前导零接受） |
| `A` | `None`（缺行号） |
| `1` | `None`（缺列号） |
| `A1B` | `None`（尾随垃圾） |
| `XFE1` | `None`（超列上限 16384） |
| `A1048577` | `None`（超行上限 1048576） |
| `A0` | `None`（行号 0 非法） |
| `""` | `None` |

`parseRange("A1:B2"): ?(CellRef, CellRef)` SHALL 接受单个 `:`，两侧各走 `parse`；
任一侧失败、或多于一个 `:`、或起止倒置（`B2:A1`）SHALL 返回 `None`。
`parseRange("A1")` SHALL 返回 `Some((A1, A1))`（单格区域，Excel 允许）。

#### Scenario: 超上限返回 None 而不是截断

- **WHEN** `CellRef.parse("XFE1")`
- **THEN** 返回 `None`

#### Scenario: 区域倒置拒绝

- **WHEN** `CellRef.parseRange("B2:A1")`
- **THEN** 返回 `None`

#### Scenario: 单格区域

- **WHEN** `CellRef.parseRange("c3")`
- **THEN** 返回 `Some((c3, c3))`

### Requirement: `CellRef` 的两种格式化

`toString()` SHALL 输出不带 `$` 的 A1 形式（`A1`、`XFD1048576`）。
`toA1()` SHALL 按 `colAbs`/`rowAbs` 输出 `$` 前缀，顺序固定为 `$列$行`。

#### Scenario: 绝对引用往返

- **WHEN** `CellRef.parse("$A$1")!.toA1()`
- **THEN** 为 `"$A$1"`

#### Scenario: 混合引用

- **WHEN** `CellRef.parse("A$1")!.toA1()`
- **THEN** 为 `"A$1"`；其 `toString()` 为 `"A1"`

### Requirement: `CellValue` 的七个分支

```cangjie
public enum CellValue {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)
    | Date(DateTime)
    | Formula(String, Option<CellValue>)
}
```

`CellValue` SHALL 声明 `<: ToString`。`Formula` 的第一个参数是**原文，不带前导 `=`**；
第二个是缓存值，`None` 表示文件里没有 `<v>`。读取 SHALL NOT 求值（M2 才提供显式求值）。

**M1 不含 `TimeSpan`**：`[h]:mm:ss` 与自定义「方括号内全为 h/m/s」的格式 SHALL 按 `Date`
返回，并记一条 `ExcelWarning(kind: UnsupportedTimeFormat)`（M2-d 改为 `TimeSpan`）。

#### Scenario: 公式只保留原文与缓存

- **WHEN** 单元格 XML 为 `<c r="B2"><f>SUM(A1:A10)</f><v>55</v></c>`
- **THEN** 值为 `Formula("SUM(A1:A10)", Some(Number(55.0)))`

#### Scenario: 公式无缓存值

- **WHEN** 单元格 XML 为 `<c r="B2"><f>SUM(A1:A10)</f></c>`
- **THEN** 值为 `Formula("SUM(A1:A10)", None)`

#### Scenario: 共享公式在 M1 只保留原文

- **WHEN** 单元格 XML 为 `<c r="B3"><f t="shared" si="0"/><v>30</v></c>`
- **THEN** 值 SHALL 是 `Empty` 或从主单元格复制来的原文，**不得**抛异常；
  并记一条 `ExcelWarning(kind: SharedFormulaUnsupported)`

### Requirement: 「没有记录」与「有记录但为空」必须可区分

`Worksheet.cell(...)` SHALL 返回 `?CellValue`，三种情况返回 `None`：坐标越界、单元格从未出现、
单元格被显式 `clearCell`。`Some(CellValue.Empty)` SHALL 只表示"文件里有这个单元格元素，但值为空"
（如 `<c r="A1" s="3"/>`）。

#### Scenario: 纯样式单元格

- **WHEN** 读取 `<c r="A1" s="3"/>`
- **THEN** `cell(1, 1)` 返回 `Some(Empty)`（不是 `None`）

#### Scenario: 越界

- **WHEN** `cell(0, 1)` 或 `cell(1048577, 1)`
- **THEN** 返回 `None`

### Requirement: 读写共用的行模型

```cangjie
public struct RowData {
    public let index: Int64                 // 1 起
    public let cells: Array<Cell>
    public let height: ?Float64
    public init(index: Int64, cells: Array<Cell>, height!: ?Float64 = None)
}

public struct Cell {
    public let col: Int64                   // 1 起
    public let value: CellValue
    public let numberFormat: ?NumberFormat  // None = 按值类型自动决定
    public init(col: Int64, value: CellValue, numberFormat!: ?NumberFormat = None)
}
```

`cells` SHALL 按 `col` 严格升序、只含实际出现的单元格（稀疏行天然表达）。读侧产出与写侧消费
SHALL 使用同一组类型，`RowReader` 可直接作为 `Iterator<RowData>` 喂给 `ExcelWriter.writeSheet`。

`NumberFormat` SHALL 有三个分支 `General` / `Builtin(Int64)` / `Custom(String)`，
SHALL 声明 `<: Equatable<NumberFormat> & ToString` 并显式实现 `==`（仓颉 enum 不自动派生）。
M1 只消费 `Builtin` 的日期子集（`14`–`22`、`45`–`47`）与 `General`；
`Custom` 与本变更内的其它 `Builtin` SHALL 原样写入但记一条
`ExcelWarning(kind: NumberFormatNotSupportedInM1)`（M2-a 接管）。

#### Scenario: 稀疏行

- **WHEN** 读 `<row r="5"><c r="C5"><v>1</v></c></row>`
- **THEN** 产出 `RowData(index: 5, cells: [Cell(col: 3, …)])`，不补 A/B 两列

#### Scenario: 读写同构

- **WHEN** 把 `RowReader` 直接传给 `ExcelWriter.writeSheet`
- **THEN** 不需要任何中间类型转换即可编译并写出

### Requirement: 异常与告警

`ExcelException` SHALL 继承 `f_base.BaseException`，提供 `init(message)` 与
`init(message, caused: Exception)`。`ExcelWarning` SHALL 是 `class`，字段
`kind: ExcelWarningKind` / `message: String` / `sheet: ?String` / `ref: ?CellRef`。

`ExcelWarningKind` SHALL 是闭集枚举并显式实现 `==`，至少覆盖：

| kind | 触发 |
|---|---|
| `MissingRowIndex` | `<row>` 缺 `r` |
| `MissingCellRef` | `<c>` 缺 `r` |
| `InvalidCellRef` | `<c r>` 非法 |
| `RowOrderViolation` | 流式读遇到行号乱序（照原样产出 + 告警） |
| `SharedStringIndexOutOfRange` | `t="s"` 索引越界 |
| `NumberParseFailed` | `<v>` 不是合法数字 |
| `UnknownCellType` | `t` 取到未定义值 |
| `DateSerial60` | 1900 基准下的 serial 60 |
| `UnsupportedTimeFormat` | `[h]` 类格式按 `Date` 处理 |
| `SharedFormulaUnsupported` | `t="shared"` 公式 |
| `AutoDetectDateDisabled` | `loadStyles=false` 导致日期识别降级 |
| `DateBaseMismatch` | 选项 `date1904` 与 `workbookPr` 相反 |
| `StylesMissing` | 缺 `styles.xml` |
| `SheetSkipped` | `skipSheets` 命中 |
| `SheetEntryMissing` | rels 指向的部件不存在 |
| `MaxRowsTruncated` / `MaxColsTruncated` | 触及 `maxRows` / `maxCols` |
| `SpoolDisabled` | `spool=false` 且输入不可定位 |
| `ControlCharStripped` | 写入时剔除非法控制字符 |
| `NumberFormatNotSupportedInM1` | 写入非 M1 支持的数字格式 |
| `MergedRangesUnavailable` | 流式读期间访问合并区域 |

#### Scenario: 告警不打断解析

- **WHEN** 一张表里有 3 个 `t="s"` 索引越界
- **THEN** 解析成功完成，这 3 格为 `Empty`，`warnings()` 里对应 3 条

#### Scenario: 异常可被 Exception 捕获

- **WHEN** `catch (e: Exception)` 捕获 `ExcelException`
- **THEN** 可以，且 `e.message` 含可读原因
