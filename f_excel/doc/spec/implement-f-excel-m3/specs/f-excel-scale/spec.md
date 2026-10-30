# Spec Delta — f-excel-scale

## ADDED Requirements

### Requirement: sharedStrings 磁盘索引

`ExcelStreamReadOptions.sharedStringsIndex = true` 时，`ExcelSheetStream` SHALL 只记录每个 `<si>` 的
偏移与长度，按需读取；结果 SHALL 与全量表一致。不可 seek 的输入 SHALL 退化并记 `IndexDegraded`。

#### Scenario: 索引读

- **WHEN** 100 万个唯一字符串、只读取前 10 行
- **THEN** 不构建全量字符串表，结果与全量模式逐格一致

### Requirement: 按需解析

`ExcelReadOptions.eager = false` 时，`ExcelDocument` SHALL 延迟到首次访问该 sheet 才解析；
`sheetNames()` / `sheetCount()` SHALL NOT 触发解析；`InputStream` 输入 SHALL 自动 spool 并记 `SpoolForLazy`。

#### Scenario: 延迟

- **WHEN** `eager=false` 打开含 3 个 sheet 的文件后只访问第 2 个
- **THEN** 第 1、3 个 sheet 未被解析，第 2 个只解析一次

### Requirement: 紧凑单元格结构

`Worksheet` 内部存储 SHALL 为列压缩结构，公开 API 与 `RowData` 语义不变；
100 万非空单元格的模型内存 SHALL < 20 MB。

#### Scenario: 等价

- **WHEN** 同一份 100 万格数据分别用旧/新结构读取
- **THEN** `cell` / `rowValues` / `range` 输出完全一致
