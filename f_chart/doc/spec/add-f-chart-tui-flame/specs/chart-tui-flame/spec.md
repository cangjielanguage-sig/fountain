## ADDED Requirements

### Requirement: TUI 火焰图类型

模块 MUST 提供 `fountain::f_chart.tui.TuiFlameChart`，实现 `fountain::f_chart.Chart`，只接受 `type = "flame"` 的 JSON。

#### Scenario: 基本渲染

- **WHEN** 用合法 `flame` JSON 调用 `TuiFlameChart().draw`
- **THEN** 返回非空 ANSI 字符画
- **AND** 标题与节点名称出现在输出中

#### Scenario: 类型不匹配

- **WHEN** 用 `type = "icicle"` 调用 `TuiFlameChart().draw`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 节点布局

火焰图 MUST 按 `nodes` 构造单根树；根节点 MUST 恰好一个；子节点值之和 MUST NOT 超过父节点值；未知父节点、重复 id、非正值与环 MUST 抛出 `InvalidValue`。

节点宽度 MUST 按 `value / root.value` 比例映射到绘图区列；节点层级对应行；`bottom-up` 时根在底部、子节点向上展开，`top-down` 时根在顶部、子节点向下展开。

#### Scenario: 单根校验

- **WHEN** `nodes` 中存在两个 `parent = null` 节点
- **THEN** 抛出 `InvalidValue`

#### Scenario: 未知父节点

- **WHEN** 节点 `parent` 指向不存在的 id
- **THEN** 抛出 `InvalidValue`

#### Scenario: 子节点超限

- **WHEN** 子节点值之和大于父节点值
- **THEN** 抛出 `InvalidValue`

### Requirement: 真彩配色

`draw` MUST 输出 ANSI 24 位真彩色（`ESC[38;2;R;G;Bm`）；每个节点 MUST 有非空前景色。

- `colorBy = "name"`：颜色 MUST 由节点名称稳定散列到 `theme.palette`，同名节点同色。
- `colorBy = "value"`：颜色 MUST 由 `value / root.value` 映射到热力色阶。
- 标签颜色 MUST 根据块背景亮度选择黑色或白色，保证可读性。

#### Scenario: 名称配色稳定

- **WHEN** 同一 JSON 连续渲染两次
- **THEN** 输出完全一致

#### Scenario: 数值配色

- **WHEN** `colorBy = "value"` 且根节点占比为 1.0
- **THEN** 输出包含根节点的热力色 ANSI 序列

### Requirement: 尺寸与标签

`width` / `height` MUST 按字符列/行解释，缺省 80×24，最小 20×8。`frameHeight` MUST 作为每层最大字符行数，并与可用高度取较小值；至少 1 行。块宽不足以容纳名称时 MUST 跳过标签。输出行数 MUST 等于 `height`。

#### Scenario: 缺省尺寸

- **WHEN** JSON 未提供 `width` / `height`
- **THEN** 输出 24 行

#### Scenario: 自定义尺寸

- **WHEN** `width = 60`、`height = 18`
- **THEN** 输出 18 行

#### Scenario: 层数超出可用行数

- **WHEN** 节点层数超出绘图区可用行数
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
