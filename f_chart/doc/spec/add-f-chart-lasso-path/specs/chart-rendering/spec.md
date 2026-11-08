# Spec Delta

## ADDED Requirements

### Requirement: LASSO 路径

`LassoPathChart` MUST 为每个系列输出一条 `class="lasso-line"` 折线，按 `x` 升序连接全部数据点，并 MUST 为每个数据项输出一个 `class="lasso-point"` 圆点。

#### Scenario: 四条路径

- **WHEN** `series` 有 4 项、每项 4 个点
- **THEN** 输出 4 条 `lasso-line` 与 16 个 `lasso-point`

### Requirement: LASSO 图例

`LassoPathChart` MUST 输出每个系列名称的图例文本。

#### Scenario: 变量名

- **WHEN** 系列名为 `年龄`、`血压`
- **THEN** SVG 包含 `年龄` 与 `血压`

### Requirement: LASSO 校验

`series` MUST 非空且每个 `data` MUST 非空；`x`、`y` MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** 某系列 `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `LassoPathChart` 渲染 `type` 为 `learning-curve` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
