# Spec Delta

## ADDED Requirements

### Requirement: 堆叠柱状图布局

`StackedBarChart` SHALL 把同一类目的系列柱叠放在同一 x 位置；正值从 0 基线向上堆叠，负值从 0 基线向下堆叠。

#### Scenario: 两组三系列

- **WHEN** 输入 2 个系列、3 个类目
- **THEN** 输出包含 6 个 `class="bar"`，且同类目的柱 x 坐标相同

### Requirement: 堆叠范围

y 轴范围 SHALL 按每个类目的正值总和与负值总和的极值计算，而不是按单个系列值。

#### Scenario: 总量大于单系列

- **WHEN** 类目 A 的两段为 60 与 40，类目 B 为 50 与 30
- **THEN** y 轴上界至少覆盖 100

### Requirement: 堆叠柱的缺测与负值

`null` 段 MUST 跳过；负值段 MUST 从 0 基线向下并与负值段连续堆叠。

#### Scenario: 缺测

- **WHEN** 数据为 `[10, null]` 与 `[20, 30]`
- **THEN** 只生成 3 段柱

#### Scenario: 负值

- **WHEN** 某类目存在负值
- **THEN** 对应段带 `bar-negative` 标记
