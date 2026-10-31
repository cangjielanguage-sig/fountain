# Spec Delta — f-excel-formula-ext

## ADDED Requirements

### Requirement: 数组公式

`t="array"` 的 `ref` 区域 SHALL 整体求值并按 Excel 广播规则写入；溢出与现有非空格冲突 SHALL 得到 `#SPILL!`；
无法广播 SHALL 得到 `#VALUE!`。

#### Scenario: 区域乘

- **WHEN** `{=A1:A3*B1:B3}` 写入 `C1:C3`
- **THEN** `C1..C3` 分别为对应乘积

### Requirement: 动态数组函数

`FILTER` / `SORT` / `UNIQUE` / `SEQUENCE` / `XLOOKUP` SHALL 返回数组并参与溢出；
空结果 SHALL 得到 `#CALC!`。

#### Scenario: FILTER

- **WHEN** `=FILTER(A1:A10, B1:B10>0)`
- **THEN** 返回满足条件的行，并在目标区域溢出

### Requirement: 函数库覆盖

`FunctionRegistry` SHALL 注册 ≥ 350 个函数；每个函数 SHALL 有 Excel 对照用例；
未实现的函数 SHALL 在 `CalcReport.unsupportedFunctions` 中列出并返回 `#NAME?`。

#### Scenario: 未实现函数

- **WHEN** 调用未注册的 `DGET`
- **THEN** 结果 `#NAME?`，报告中列出 `DGET`
