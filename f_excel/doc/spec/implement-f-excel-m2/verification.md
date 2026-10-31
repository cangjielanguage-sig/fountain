# Verification — implement-f-excel-m2

> 日期：2026-10-31 ｜ 分支：`feature/f_excel`

## 1. 测试

```
cd f_excel && cjpm test
TOTAL: 137    PASSED: 137    FAILED: 0    ERROR: 0
```

覆盖：样式值语义/去重/上限/往返（6）、公式词法/语法/优先级/错误传播/依赖链/环/共享公式/数组口径（20）、
143 函数逐组对照（8）、TimeSpan 与富文本（6），其余为 M1 既有 90 条与图片 4 条。

## 2. 外部工具

- openpyxl 3.1.5：M2-a 样式回读（Arial/14/bold/italic/FFFF0000、solid/FFFFFF00、thin、center/wrap、
  `#,##0.00`）全部正确（见 M2-a 提交记录）。
- 公式求值没有外部对照工具（openpyxl 不求值），预期值来自 Excel 语义手工计算并固化在用例中。

## 3. 与规格的差异

| 规格 | 实施 |
|---|---|
| 140 个函数 | 143 个（62 核心 + 81 扩展） |
| 样式池上限 Linux 64000 / 其他 8192 | `SheetWriteOptions.maxCellStyles` 默认 64000；8192 由调用方按平台设置 |
| `Cell.numberFormat` 与 `style` 并存 | `style` 优先并告警 `NumberFormatNotSupportedInM1` |
| 富文本写侧 | 平坦化为 `inlineStr`（规格允许，样式丢失已文档化） |
| 数组公式 | 只求左上角 + `ArrayFormulaUnsupported` 告警（规格 M2 口径） |

## 4. 未覆盖

- 真实 Excel / WPS 打开带样式与公式的文件（环境无 GUI）。
- `theme1.xml` 主题色板（只保留 `Color.Theme(theme, tint)` 原值）。
- 大量函数与 Excel 的边界差异（如 `CEILING` 负数语义）只覆盖主路径。

## 5. 结论

M2-a / M2-b / M2-c / M2-d 的规格条目全部有实现与用例；剩余缺口显式记录在
`f_excel/doc/f_excel模块设计.md` §15.3，且不影响 M1 行为。可归档。
