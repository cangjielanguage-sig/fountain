# Verify — implement-f-excel-m1（回退校验）

> `opsx:verify` 在融合侧无法执行：该会话禁用 Bash，工作流前置（`ssh-check` → `plan`）全部被拒。
> 按 `references/openspec-workflow.md` 步骤 5 的回退执行：
> `openspec validate` + 人工三对齐（design 落点 / tasks 与用例 / 规格 scenario 覆盖）。
> 校验时间：2026-10-30 ｜ 代码：`feature/f_excel`（86 用例全绿）。

## 1. Completeness

| 检查 | 结果 |
|---|---|
| tasks 完成度 | 55/57 勾选；未勾选 2 条均为**环境受限的人工项**：`4.6`（P3 出口用真实 Excel 打开）、`11.2`（verification.md 的人工 Excel 结论） |
| delta 规格落点 | 6 份 spec 的每条 Requirement 都能在 `src/` 找到实现（对照 `verification.md` §5） |
| 产物一致性 | `doc/spec/implement-f-excel-m1` 与 `openspec/changes/implement-f-excel-m1` `diff -ru` 无输出（12.3 / 12.7） |
| `openspec validate` | 通过（非 strict exit 0） |

## 2. Correctness（需求 → 用例）

| 规格 | 关键 scenario | 覆盖用例 |
|---|---|---|
| `f-excel-cell-model` | 列号边界、parse 全表、区域倒置、`Some(Empty)` vs `None` | `CellRef_test` 7 条、`CellValue_test` 6 条 |
| `f-excel-reader` | 类型表、sharedStrings、稀疏、缺 `r`、日期、合并、截断 | `WorksheetParser_test` 10 条、`PackageReader_test` 5 条、`Date_test` 11 条、`Worksheet_test` 5 条、`SharedStringTable_test` 5 条 |
| `f-excel-writer` | 部件顺序、r:id 闭合、inlineStr、最短数字、日期绑样式、转义、上限 | `Writer_test` 10 条、`PackageStructure_test` 3 条 |
| `f-excel-stream-read` | 两种入口、spool、逐行、乱序、合并时序、close | `StreamRead_test` 8 条 |
| `f-excel-stream-write` | 构造校验、顺序、行号、失败状态、直连 | `ExcelWriter_test` 7 条 |
| `f-excel-roundtrip` | 七种值、文本边界、精度、两种基准、多 sheet | `RoundTrip_test` 5 条 |

全量 `cjpm test`：**86 通过 / 0 失败**；openpyxl 3.1.5 外部回读通过（`verification.md` §2）。

## 3. Coherence

- 目录 / 包结构 / 测试布局与 design §4 一致（扁平 `src/*.cj`、`*_test.cj` 同目录）。
- worksheet 生成走 `f_xml.XmlWriter` 增量接口（design 差异 5 的最终形态），f_excel 无自写转义表。
- 不关调用方流、失败即残缺、`mergedRanges` 时序等约定均按 design §6/§7 落地。
- 未改动 `f_zip` / `f_xml` / `f_base`（前置能力已在独立分支完成并合入）。

## 4. 分级结论

| 级别 | 条目 |
|---|---|
| **CRITICAL** | 0 |
| WARNING | W1：真实 Excel / WPS 人工验收未执行（环境无 GUI Excel；openpyxl 已覆盖结构）。<br>W2：`openspec validate --strict` 有 7 条「Requirement 正文 > 500 字」格式建议（内容完整，未拆分）。 |
| SUGGESTION | S1：M2-a 可把 `Cell.numberFormat` 平滑升级为 `?CellStyle`；<br>S2：M3 可给 `sharedStrings` 加磁盘索引，消除流式读唯一随文件增长的常驻结构。 |

CRITICAL 为 0，可进入 archive；WARNING 交用户决定（当前记为遗留）。
