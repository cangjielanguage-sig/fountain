# Spec Delta

## ADDED Requirements

### Requirement: 散点图数据

`ScatterChart` SHALL 接受 `{x,y}` 对象数组；x/y MUST 为有限数；时间轴 x MUST 接受 `YYYY-MM-DD`。

#### Scenario: 三个点

- **WHEN** 一个系列含 3 个 `{x,y}`
- **THEN** 输出 3 个 `class="symbol"`

#### Scenario: 非法 x

- **WHEN** 点的 `x` 为字符串且轴不是时间轴
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 双数值轴

散点图 MUST 使用线性 x/y 比例尺，并按 nice 刻度绘制两轴。

#### Scenario: 数值刻度

- **WHEN** x 范围为 0–100
- **THEN** x 轴出现至少 2 个 `class="tick-label"`

### Requirement: 多系列样式

每个系列 SHALL 使用 `series[].color` 或调色板；`symbol` 支持 circle/square/diamond。

#### Scenario: 两系列颜色

- **WHEN** 两个系列未指定颜色
- **THEN** 两者颜色来自调色板前两位
