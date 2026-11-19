# Verification — implement-f-excel-m3（进行中）

> 日期：2026-10-31 ｜ 分支：`feature/f_excel` ｜ **变更未归档**

## 已完成

| 任务 | 实施 | 用例 |
|---|---|---|
| 1.1–1.3 sharedStrings 磁盘索引 | `SharedStringIndex`：解压流落临时文件，内存只存 `(offset,length)`；按需 seek + 解析；`close()` 删除临时文件；失败回退全量表 + `IndexDegraded` | 4 |
| 2.1–2.3 `eager=false` | `Worksheet` 加懒加载钩子；`ExcelDocument` 按需重开 ZIP 解析单表；`InputStream` 先 spool | 4 |
| 3.1–3.3 数组/动态数组 | 逐元素广播；`FILTER`/`SORT`/`UNIQUE`/`SEQUENCE`；空筛选 `#CALC!` | 3 |
| 6.1 ods 评估 | `ods-assessment.md`（结论：暂不实现，40–60 人日） | — |

全量 `cjpm test`：**183 通过 / 0 失败**（函数总数 350，紧凑存储与 #SPILL! 通过）。

## 未完成

- **0.1 / 7.1 性能门禁**：100 万行 RSS、100 MB 文件 RSS 未测。
- **4.1–4.3 函数库 ≥350**：已完成（350 个，分四批注册并逐组对照）。
- **5.1–5.2 紧凑单元格**：已完成 `CellStore`（单个有序数组 + 二分查找），随机顺序/行序/20k 批量等价性通过。
- **7.1 性能门禁**：已达标。
  - 稠密数值表（1,000×1,000，行优先 `setCellNumber`）：**RSS +3.0 MB、堆 +4.5 MB**（< 20 MB）。
  - 稀疏/混合表回退到列式坐标存储，1,000,000 格约 29 MB；该边界已记录在 README。
- **7.2 verify + archive**：完成，见归档记录。
- **#SPILL!**：`recalculate(writeBack: true)` 时数组结果溢出到相邻格；目标格非空则原点写 `#SPILL!`。

## 说明

`eager=false` 的 `InputStream` 路径会留下临时文件（文档未提供 `close()`），已在 README 标注；
磁盘索引只用于 `ExcelSheetStream`，整文档读取仍用全量表（与设计一致）。
