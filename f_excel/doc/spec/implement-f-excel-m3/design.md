# Design: f_excel M3

> 依据 `f_excel模块设计.md` v0.11 第 2.7 / 7 / 9 章。M3 只做增强，不改变 M1/M2 默认行为。

## 1. sharedStrings 磁盘索引（M3-a）

```
首次打开（index 构建）:
  xl/sharedStrings.xml 事件流 → entries: ArrayList<IndexedString{offset, length}>
                                ↳ 只记录 <si> 文本在解压流中的字节区间
读取某个索引 i:
  ZipReader 重开条目 → 跳到 offset → 只解到 length
```

- 索引本身是 `Int64` 对，百万条约 16 MB；仍优于存字符串。
- 只在 `ExcelStreamReadOptions.sharedStringsIndex = true` 时启用；`ExcelDocument` 保持全量表。
- 解压流不可 seek 时（deflate）退化为"顺序扫描到目标"，并记 `IndexDegraded` warning。

## 2. 按需解析（M3-a2）

`ExcelDocument` 增加 `eager: Bool = true`：
- `eager = false`：构造只读 workbook/rels/styles；`Worksheet` 持 `partName` 与 `loaded` 标志；
  首次 `cell` / `rowValues` / `range` / `mergedRanges` 触发 `loadSheet()`，之后缓存。
- `sheetNames` / `sheetCount` 不触发。
- `close` 不存在（ZipReader 在构造后关闭）；每次 `loadSheet` 重新打开 `ZipReader(path)`；
  `InputStream` 输入在 `eager=false` 时自动 spool（否则无法二次打开），并记 `SpoolForLazy`。

## 3. 数组与动态数组（M3-b）

- `CalcValue.Array(rows, cols, values)`；数组公式 `ref` 区域逐格写入结果。
- 广播规则：标量与数组、行列向量与矩阵按 Excel 规则扩展；不匹配 → `#VALUE!`。
- 动态数组：`FILTER/SORT/UNIQUE/SEQUENCE/XLOOKUP` 返回 `Array`；溢出区域写入 `ref`，
  与已有非空单元格冲突 → `#SPILL!`。
- 数组公式结果写回 `Formula.cached` 仅左上角，其余格写 `ArrayValue`（内部）。

## 4. 函数库补全（M3-c）

- `FunctionRegistry` 按组拆文件；每个函数注册元数据（名称、参数个数、是否易失）。
- 覆盖目标 ≥ 350；以 Excel 函数列表为基准，缺一个就在 `CalcReport.unsupportedFunctions` 里列出。
- 数据库函数（`DSUM` 等）在 M3 只做常用 10 个，其余明确 `#NAME?`。

## 5. 紧凑单元格（M3-d）

```
Worksheet:
  rows: ArrayList<RowBlock>          // 按行号分块（每块 1024 行）
  RowBlock: rowIndex + ArrayList<(col, CellValue)>
```

- 写侧 `setCell` 定位块 + 二分插入；读侧遍历块内数组。
- 与 `rowValues` 输出顺序一致；`clearCell` 删除。
- 目标：100 万非空单元格 < 20 MB（不含 sharedStrings）。

## 6. ods 评估（M3-e）

产出 `doc/spec/implement-f-excel-m3/ods-assessment.md`：
- ods 的 `content.xml`（`table:table` / `table:table-row` / `table:table-cell`）与 OOXML 映射；
- 可复用的部分（`f_zip`、`f_xml`、`CellValue`、`DateSerial`）；
- 差异（公式语法、样式模型、日期基准、合并/图片）；
- 结论：做 / 不做 / 何时做 + 工作量估算。

## 7. 性能门禁（设计 §9）

| 场景 | 目标 |
|---|---|
| 100 万行流式写 | RSS < 20 MB |
| 100 万行流式读（index 开） | RSS < 50 MB |
| 100 MB 文件 `eager=false` | RSS < 100 MB |
| 100 万单元格 | < 20 MB |
| 350 函数覆盖率 | 100% 有对照用例或明确 unsupported |

## 8. 风险

| 风险 | 应对 |
|---|---|
| sharedStrings 索引在不可 seek 流上退化 | 记 `IndexDegraded`，保留全量模式 |
| 数组公式广播规则复杂 | 先实现 1D/2D 基础规则，边缘样例列 TODO 并明确 `#VALUE!` |
| 紧凑结构改动面大 | 先加基准与等价性用例，再替换内部存储（公开 API 不变） |
| 350 函数预期值来源 | 沿用 M2 的 Excel 对照样本；分批合入，每批必须有对照 |
