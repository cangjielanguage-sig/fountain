# Spec Delta — f-excel-conditional-format

## ADDED Requirements

### Requirement: 条件格式保留

`Worksheet` SHALL 解析并保留 `<conditionalFormatting>` / `<cfRule>`（13 种 `CfRuleType`）；
写回 SHALL 在 `mergeCells` 之后按 `priority` 升序输出，结构与 `sqref` 不变。
未知类型 SHALL 以 `Unknown(raw)` 保留并原样写回。

#### Scenario: 往返不丢

- **WHEN** 读取一个含 `cellIs` 与 `colorScale` 的文件并写回
- **THEN** 两条规则的 `sqref` / `type` / `priority` / 公式完全一致

### Requirement: 规则求值

`Worksheet.matchedRules(row, col)` SHALL 按 priority 升序返回命中规则；`stopIfTrue` SHALL 截断后续规则。
`cellIs` / `expression` / `containsText` / `timePeriod` / `top10` / `duplicateValues` SHALL 按 Excel 语义求值。

#### Scenario: 比较规则

- **WHEN** `A1=5`、规则 `cellIs greaterThan 3`
- **THEN** `matchedRules(1,1)` 含该规则

#### Scenario: stopIfTrue

- **WHEN** 第一条命中且 `stopIfTrue=true`
- **THEN** 后续规则不再出现在结果中

### Requirement: 视觉规则

`colorScale` / `dataBar` / `iconSet` SHALL 返回 `CfFormat`（颜色/长度/图标）；
`Cfvo` 为 `num` / `percent` / `percentile` / `formula` 时 SHALL 各自计算阈值。

#### Scenario: 三色刻度

- **WHEN** min=0（红）、mid=50（黄）、max=100（绿），单元格值 25
- **THEN** 返回红黄之间的插值颜色

### Requirement: 与合并/空值边界

条件格式区域与合并区域重叠时 SHALL 只对左上角求值；空单元格 SHALL 按 Excel 语义参与（不命中数值规则）。

#### Scenario: 空值

- **WHEN** 空单元格命中 `cellIs greaterThan 0` 规则
- **THEN** 不命中
