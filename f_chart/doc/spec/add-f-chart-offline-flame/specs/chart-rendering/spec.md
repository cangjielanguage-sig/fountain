# Spec Delta

## ADDED Requirements

### Requirement: 离线子树

`OfflineFlameChart` MUST 只绘制 `root` 指定节点及其后代；`root` 缺省时 MUST 绘制整棵树。节点矩形 class `offline-flame-node`。

#### Scenario: 指定子树

- **WHEN** `root` 为 render 且该子树有 5 个节点
- **THEN** 输出 5 个 `offline-flame-node`

#### Scenario: 缺省根

- **WHEN** 未提供 `root`
- **THEN** 输出全部 7 个 `offline-flame-node`

### Requirement: 深度限制

`maxDepth` 提供时 MUST 只绘制相对于 `root` 深度不超过该值的节点；`maxDepth` MUST 为非负整数。

#### Scenario: 深度为零

- **WHEN** `maxDepth` 为 0
- **THEN** 只输出根节点 1 个 `offline-flame-node`

#### Scenario: 深度为一

- **WHEN** `root` 为 render、`maxDepth` 为 1
- **THEN** 输出 render 及其两个子节点共 3 个 `offline-flame-node`

### Requirement: 离线火焰宽度

子树的根节点 MUST 占满绘图区宽度，后代宽度 MUST 按 `value / 子树根 value` 分配。

#### Scenario: 子树归一化

- **WHEN** 子树根 value 为 60
- **THEN** 该节点矩形宽度等于绘图区宽度

### Requirement: 离线火焰校验

`nodes` MUST 非空；id MUST 唯一；`parent` MUST 指向存在的节点；MUST 恰好有一个树根；`root` 提供时 MUST 指向存在的节点；`value` MUST 大于 0。

#### Scenario: 未知 root

- **WHEN** `root` 为不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负 maxDepth

- **WHEN** `maxDepth` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
