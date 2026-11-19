# Proposal: 实现 f_excel M3（规模化、公式扩展、ods 评估）

## Why

M2 把语义补全了，但还有三类问题：

1. **规模化**：流式读仍会因 `sharedStrings` 全量驻留而随唯一字符串数增长；整文档模式仍然"打开即全解析"，
   100 MB 文件 RSS 波动大；单元格对象开销偏高。
2. **公式完整度**：M2 只有 140 个函数，数组/动态数组只求左上角；与 Excel 的差距会在迁移真实文件时暴露。
3. **格式边界**：ods 已被点名评估；模块名已解耦，但需要一份可落地的结论而不是"永远不做"。

M3 不改变 M1/M2 的公开语义，只做**增强与补全**；所有新增开关默认保持现状。

## What Changes

### M3-a 流式读增强

- `sharedStrings` **磁盘索引**：`ExcelStreamReadOptions.sharedStringsIndex = true` 时，
  解析 `<si>` 只记偏移，按需读取；内存与唯一字符串数解耦。
- `spool` 零拷贝：输入已是文件路径时跳过 spool；`InputStream` 场景评估 `sendfile`/`transferTo` 可行性。
- 新增指标：`RowReader` 已读字节 / 索引命中率（只读，供调优）。

### M3-a2 按需解析

- `ExcelReadOptions.eager = false`：`ExcelDocument` 打开时只解析 workbook/rels/styles，
  `Worksheet` 首次访问单元格时才解析该 sheet（惰性 + 一次缓存）。
- 语义不变：`sheetNames()` 不触发解析；`cell()` / `rowValues()` 触发。

### M3-b 数组 / 动态数组

- 数组公式：`t="array"` 全区域求值并按 `ref` 广播；`#SPILL!` / `#CALC!` 语义。
- 动态数组函数：`FILTER` / `SORT` / `UNIQUE` / `SEQUENCE` / `XLOOKUP`。
- 溢出区域与普通区域冲突 → `#SPILL!`。

### M3-c 函数库补全

- 函数总数 ≥ 350：补齐统计/工程/数据库/文本/日期/财务/信息类。
- 每个函数都有 Excel 对照用例；未实现函数明确 `#NAME?`，不静默错算。

### M3-d 紧凑单元格结构

- `Worksheet` 内部由 `HashMap<Int64, CellValue>` 改为**列压缩结构**（按行分块 + 列偏移数组），
  100 万单元格目标 < 20 MB；公开 API 不变。
- 与 `RowData` 的稀疏语义保持一致。

### M3-e ods 评估

- 产出可行性报告：ods 的 `content.xml` / `styles.xml` 与 OOXML 的映射、复用面、风险与工作量。
- 本变更**不实现** ods；只决定"做 / 不做 / 何时做"。

## Impact

- 新增 `SharedStringIndex.cj`、`SheetLazyLoader.cj`、`CompactRowStore.cj`、`ArrayFormula.cj`、函数扩展若干。
- 选项新增（默认关闭/保持现状）：`sharedStringsIndex`、`eager`。
- 性能门禁：100 万行流式读/写 RSS、100 MB 文件打开 RSS、350 函数覆盖率达到设计 §9 目标。
- 测试：规模化基准 + 函数对照 + 数组语义；预计新增 150+ 用例。

## Out of Scope

- ods 的实际实现。
- 条件格式（M4）。
- 多线程求值（不引入并发复杂度）。
