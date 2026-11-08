# Spec Delta

## ADDED Requirements

### Requirement: 螺旋路径与数据点

`SpiralChart` MUST 输出一条 `class="spiral-path"` 折线，串联全部数据点，并 MUST 为每个数据项输出一个 `class="spiral-point"` 圆点。

#### Scenario: 六个月度数据

- **WHEN** `data` 有 6 项
- **THEN** 输出 1 条 `spiral-path` 与 6 个 `spiral-point`

### Requirement: 螺旋坐标

`spiralPoint` MUST 返回相对圆心的 `[x, y]`：第 i 个点的半径 MUST 为 `maxRadius * (i + 1) / count`，角度 MUST 为 `startAngle + direction * turns * 360 * i / (count - 1)`，其中 `direction` 在顺时针时为 1、逆时针时为 −1。

#### Scenario: 首点

- **WHEN** count 为 4、turns 为 1、startAngle 为 −90、顺时针、maxRadius 为 100、i 为 0
- **THEN** 返回 `[0, -25]`（允许浮点误差）

#### Scenario: 末点

- **WHEN** 同样的参数、i 为 3
- **THEN** 返回 `[0, -100]`（允许浮点误差）

### Requirement: 螺旋标签

每个数据项 MUST 输出 `class="spiral-label"` 文本，内容为 `period`。

#### Scenario: 标签数量

- **WHEN** `data` 有 6 项
- **THEN** 输出 6 个 `spiral-label`

### Requirement: 螺旋校验

`turns` MUST 大于 0；`series` MUST 恰好 1 个且 `data` MUST 非空；每项 MUST 提供字符串 `period` 与非负数字 `value`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 圈数为零

- **WHEN** `turns` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `SpiralChart` 渲染 `type` 为 `radar` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
