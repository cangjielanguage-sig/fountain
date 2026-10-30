# Tasks — implement-f-excel-m4

> 前置：M2 公式引擎、M2-a `dxfs`。每步 Red → Green。

- [ ] 1.1 失败用例 `ConditionalFormat_test`：`sqref` 单段/多段、13 种 `CfRuleType` 解析
- [ ] 1.2 失败用例：未知类型 `Unknown(raw)` 原样写回
- [ ] 1.3 失败用例 `Dxfs_test`：`dxfId` 读写、与 `cellXfs` 隔离
- [ ] 2.1 失败用例 `CfEval_test`：`cellIs` 各比较符、`expression`、`containsText`
- [ ] 2.2 失败用例：相对引用平移到目标格；`$` 不动
- [ ] 2.3 失败用例：`top10` / `duplicateValues` / `timePeriod`
- [ ] 3.1 失败用例：`colorScale` 两色/三色插值（num/percent/percentile/formula）
- [ ] 3.2 失败用例：`dataBar` 长度比例、`iconSet` 分档
- [ ] 4.1 失败用例：`priority` 排序、`stopIfTrue`、`matchedRules` 顺序
- [ ] 4.2 失败用例：多规则命中时 `CfFormat` 合并
- [ ] 5.1 实现模型/解析/写回/求值
- [ ] 5.2 openpyxl 回读条件格式结构（`ws.conditional_formatting`）
- [ ] 6.1 `cjpm test` 全绿，记录用例数
- [ ] 6.2 README/设计文档、verify + archive
