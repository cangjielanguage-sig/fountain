# Spec Delta

## ADDED Requirements

### Requirement: 和弦外圈

`ChordChart` MUST 为每个节点输出一条 `class="chord-arc"` 圆弧，弧长按该节点关联总流量占全部总流量的比例分配，分段之间留 `padAngle` 间隔。

#### Scenario: 四个节点

- **WHEN** `nodes` 有 4 项
- **THEN** 输出 4 条 `chord-arc`

### Requirement: 和弦带状线

`ChordChart` MUST 为每条链接输出一条 `class="chord-ribbon"` 二次贝塞尔曲线，线宽由 `chordWidth` 决定。

#### Scenario: 五条链接

- **WHEN** `links` 有 5 项
- **THEN** 输出 5 条 `chord-ribbon`

### Requirement: 和弦标签

`showLabels` MUST 默认为 false；为 true 时 MUST 为每个节点输出一个 `class="chord-label"` 文本。

#### Scenario: 显示标签

- **WHEN** `showLabels` 为 true 且 `nodes` 有 4 项
- **THEN** 输出 4 个 `chord-label`

### Requirement: 和弦图校验

`nodes` MUST 至少两个且 id 唯一；`links` MUST 非空；`source` / `target` MUST 指向存在的节点；`value` MUST 大于 0；`padAngle` MUST 非负且分段后仍有正角度；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 间隔过大

- **WHEN** `nodes` 有 4 项且 `padAngle` 为 2
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 未知端点

- **WHEN** 某链接 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
