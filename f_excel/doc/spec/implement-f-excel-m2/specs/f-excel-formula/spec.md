# Spec Delta — f-excel-formula

## ADDED Requirements

### Requirement: 公式解析

`FormulaParser` SHALL 把公式原文解析为 AST，支持：数字/字符串/布尔/错误字面量、单元格引用（含 `$`）、
区域、函数调用、`+ - * / ^ %`、`&`、比较运算、括号、一元负号。
非法公式 SHALL 返回 `#NAME?` 或 `#VALUE!` 对应的解析错误，不抛未捕获异常。

#### Scenario: 优先级

- **WHEN** 解析 `1+2*3^2`
- **THEN** AST 等价于 `1+(2*(3^2))`

#### Scenario: 非法输入

- **WHEN** 解析 `SUM(`
- **THEN** 返回解析失败，求值为 `#NAME?`

### Requirement: 求值与函数库

`CalcEngine.evaluate(sheet, ref)` SHALL 返回该单元格的 `CellValue`；`recalculate()` SHALL 重算全表。
M2 SHALL 提供至少 140 个函数（数学/文本/逻辑/日期/查找/统计/财务/信息）。
`NOW` / `TODAY` / `RAND` / `RANDBETWEEN` SHALL 在同一次 `recalculate()` 内保持一致。

#### Scenario: 基础函数

- **WHEN** `A1=2, A2=3, B1=SUM(A1:A2)*2`
- **THEN** `evaluate("Sheet1", B1) == Number(10)`

#### Scenario: 未知函数

- **WHEN** `=FOO(1)`
- **THEN** 结果为 `#NAME?` 且记录 `CalcIssue`

### Requirement: 依赖图与循环引用

`DependencyGraph` SHALL 收集跨单元格/跨表依赖并给出拓扑序；出现环 SHALL 在环上单元格写 `#CIRC!`，
`CalcReport` SHALL 报告环成员。求值 SHALL 带 memo，避免重复计算。

#### Scenario: 循环

- **WHEN** `A1=B1`、`B1=A1`
- **THEN** 两格均为 `#CIRC!`，`CalcReport.cycles` 含这两个坐标

### Requirement: 共享公式平移

`t="shared"` 的非主单元格 SHALL 按主公式与偏移量平移相对引用；`$` 修饰的行/列不动；
平移越界 SHALL 得到 `#REF!`。

#### Scenario: 平移

- **WHEN** 主公式 `A2*2` 位于 `B2`，`B3` 共享
- **THEN** `B3` 的等效公式为 `A3*2`

#### Scenario: 绝对引用

- **WHEN** 主公式 `$A$2*2`，`B3` 共享
- **THEN** `B3` 仍为 `$A$2*2`

### Requirement: 求值时机

读取 SHALL 返回缓存值，不自动重算；`recalculate()` 只改内存模型，`write()` 才落盘。
`recalculate(writeBack: true)` SHALL 把结果写回 `Formula.cached`。

#### Scenario: 默认不重算

- **WHEN** 打开一个缓存值为 1、实际应为 2 的文件
- **THEN** 读到 1；调用 `recalculate()` 后为 2
