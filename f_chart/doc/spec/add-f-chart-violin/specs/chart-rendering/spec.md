# Spec Delta

## ADDED Requirements

### Requirement: 小提琴密度轮廓

`ViolinChart` SHALL 为每组数据计算核密度并以类别中心为轴镜像成闭合轮廓，class 为 `violin`。

#### Scenario: 三组分布

- **WHEN** `data` 为 3 个数值数组
- **THEN** 输出 3 条 `class="violin"`

### Requirement: 小提琴内嵌箱体

`showBox` 默认为 true，此时每组 MUST 额外输出 `class="box"` 箱体与 `class="median"` 中位线；`showBox` 为 false 时 MUST 不输出。

#### Scenario: 关闭箱体

- **WHEN** `showBox` 为 false
- **THEN** 不包含 `class="box"` 与 `class="median"`

### Requirement: 小提琴数据形状

`data` MUST 支持嵌套数组（每组一个）与扁平数组（单组）；同图内不得混用；每组不得为空。

#### Scenario: 扁平数据

- **WHEN** `data` 为扁平数值数组
- **THEN** 输出 1 条 `class="violin"`

#### Scenario: 空组

- **WHEN** 某个子数组为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 小提琴校验

`bandwidth` MUST 大于 0；数据 MUST 全为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法带宽

- **WHEN** `bandwidth` 为 -1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
