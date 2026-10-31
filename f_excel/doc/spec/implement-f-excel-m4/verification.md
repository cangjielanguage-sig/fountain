# Verification — implement-f-excel-m4

> 日期：2026-10-31 ｜ 分支：`feature/f_excel`

## 1. 测试

```
cd f_excel && cjpm test
TOTAL: 147    PASSED: 147    FAILED: 0    ERROR: 0
```

新增 7 条条件格式用例：解析 + cellIs 命中 + dxf 解析、三色刻度插值与中值、dataBar 长度、
stopIfTrue 截断、expression 相对引用平移、读写往返、编程式添加。

## 2. 外部工具

openpyxl 3.1.5 回读编程式写出的文件：

```
cf ranges ['A1:A3']
rule cellIs greaterThan ['50'] 0
A3 100
```

`<conditionalFormatting>` 与 `<dxfs>` 均被识别，dxfId 正确。

## 3. 与规格的差异

| 规格 | 实施 |
|---|---|
| 13 种 `CfRuleType` | 全部可解析/写回；求值覆盖 cellIs/expression/containsText/notContainsText/beginsWith/endsWith/top10/duplicate/unique/blank/error/colorScale/dataBar/iconSet |
| `Worksheet.matchedRules` | 值规则可用；`expression` 需 `CalcEngine.matchedRules`（公式引擎在引擎侧） |
| `Unknown(raw)` | 保留原文并可写回，不求值 |
| `priority` 排序 | 命中结果按 priority 升序；`stopIfTrue` 截断 |
| dxf 写回 | 由 `StylePool` 的 dxfs 表按值去重后重新编号，fill/fontColor/bold 保留 |

## 4. 未覆盖

- `timePeriod` / `aboveAverage` 求值（可解析、可写回，不命中）。
- `colorScale` 的 `formula` 阈值按数字解析，不求公式。
- 图标集只返回 `name:index`，不生成图片。
- 真实 Excel/WPS 的视觉核对（环境无 GUI）。

## 5. 结论

M4-a/b/c/d 的主路径有实现与用例；未覆盖项不影响结构保留与常见规则求值。可归档。
