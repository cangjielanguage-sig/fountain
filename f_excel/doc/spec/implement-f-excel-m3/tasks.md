# Tasks — implement-f-excel-m3

> 前置：M2 已完成（样式/公式/时长富文本）。每步 Red → Green。

## 0. 基准与前置

- [ ] 0.1 建立规模化基准：100 万行读/写、100 MB 打开、100 万单元格，记录当前 RSS
- [x] 0.2 确认 ZipReader 能重复打开条目、deflate 流是否可 seek（决定索引退化策略）

## 1. M3-a sharedStrings 磁盘索引

- [x] 1.1 失败用例：索引构建只存 offset/length；按需读取与全量表结果一致
- [x] 1.2 失败用例：不可 seek 流 → `IndexDegraded` + 结果仍正确
- [x] 1.3 实现 `SharedStringIndex.cj` 并接入 `ExcelSheetStream`

## 2. M3-a2 按需解析

- [x] 2.1 失败用例：`eager=false` 构造不解析 sheet；首次 cell 触发一次解析
- [x] 2.2 失败用例：`InputStream + eager=false` 自动 spool + `SpoolForLazy`
- [x] 2.3 实现 `SheetLazyLoader` 与 `ExcelDocument` 分支

## 3. M3-b 数组/动态数组

- [x] 3.1 失败用例：数组公式 `ref` 广播、`#SPILL!`、`#CALC!`
- [x] 3.2 失败用例：FILTER/SORT/UNIQUE/SEQUENCE/XLOOKUP
- [x] 3.3 实现 `CalcValue.Array`、广播与溢出检测

## 4. M3-c 函数库

- [x] 4.1 失败用例：分批新增函数（每批 ≥ 20），逐一对 Excel
- [x] 4.2 失败用例：`CalcReport.unsupportedFunctions` 完整列出未实现函数
- [x] 4.3 实现至 ≥ 350 函数

## 5. M3-d 紧凑单元格

- [x] 5.1 基准 + 等价性用例：新旧存储在 100 万格上结果一致
- [x] 5.2 实现行块结构，替换 `Worksheet` 内部存储

## 6. M3-e ods 评估

- [x] 6.1 产出 `ods-assessment.md`（映射、复用、差异、结论、估算）

## 7. 收尾

- [ ] 7.1 性能门禁全部达标并记录
- [ ] 7.2 `cjpm test` 全绿、README/设计文档更新、verify + archive
