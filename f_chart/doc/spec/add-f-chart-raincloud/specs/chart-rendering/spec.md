# Spec Delta

## ADDED Requirements

### Requirement: 雨云图云、雨、箱

`RaincloudChart` MUST 为每个系列输出一条 `class="raincloud-cloud"` 半小提琴路径；`showRain` 为真时 MUST 为每个数值输出一个 `class="raincloud-rain"` 圆点；`showBox` 为真时 MUST 输出一个 `class="raincloud-box"` 矩形、一条 `raincloud-median` 中位线与两条 `raincloud-whisker` 须线。

#### Scenario: 单组十二个值

- **WHEN** 一个系列有 12 个数值且三个开关均为默认
- **THEN** 输出 1 条 `raincloud-cloud`、12 个 `raincloud-rain`、1 个 `raincloud-box`、1 条 `raincloud-median`、2 条 `raincloud-whisker`

### Requirement: 雨云图开关

`showCloud` 为 `false` 时 MUST 不输出云路径；`showRain` 为 `false` 时 MUST 不输出散点；`showBox` 为 `false` 时 MUST 不输出箱体与须线。

#### Scenario: 关闭雨点

- **WHEN** `showRain` 为 `false`
- **THEN** 输出 0 个 `raincloud-rain`

### Requirement: 雨云图密度

`bandwidth` 给出时 MUST 用于核密度估计且 MUST 大于 0；缺省时 MUST 使用 `defaultBandwidth`。

#### Scenario: 非法带宽

- **WHEN** `bandwidth` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 雨云图校验

`series` MUST 非空且每个 `data` MUST 非空；`data` 元素 MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** 某系列 `data` 为空数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `RaincloudChart` 渲染 `type` 为 `violin` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
