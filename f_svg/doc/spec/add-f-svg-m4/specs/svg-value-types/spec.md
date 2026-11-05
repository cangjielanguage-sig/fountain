# svg-value-types

## ADDED Requirements

### Requirement: M4 文本排版枚举

系统 SHALL 新增以下公开类型，均实现 `Equatable` 与 `ToString`：

- `SvgWritingMode`：`LrTb` / `Lr` / `Tb` / `TbRl`；
- `SvgDominantBaseline`：`Auto` / `Alphabetic` / `Ideographic` / `Middle` / `Central` / `Hanging` / `Mathematical` / `TextBeforeEdge` / `TextAfterEdge`；
- `SvgAlignmentBaseline`：在 `SvgDominantBaseline` 的取值外增加 `Baseline` / `BeforeEdge` / `AfterEdge`。

`SvgWritingMode` 的字符串形式 SHALL 为 `lr-tb` / `lr` / `tb` / `tb-rl`。

#### Scenario: 书写模式解析

- **WHEN** 解析 `writing-mode="tb-rl"` 与 `writing-mode="lr"`
- **THEN** 分别得到 `SvgWritingMode.TbRl` 与 `SvgWritingMode.Lr`

#### Scenario: 基线字符串

- **WHEN** 对 `SvgDominantBaseline.TextBeforeEdge` 调用 `toString()`
- **THEN** 输出 `text-before-edge`

### Requirement: M4 基线偏移与装饰线值

系统 SHALL 提供 `SvgBaselineShift`，表示 `baseline` / `sub` / `super` 或一个 `SvgLength`（长度或百分比）。

系统 SHALL 提供 `SvgTextDecoration`，表示 `none` 或 `underline` / `overline` / `line-through` 的任意组合；解析 SHALL 接受空白分隔的多个关键字。

#### Scenario: 复合装饰线

- **WHEN** 解析 `text-decoration="underline line-through"`
- **THEN** 同时启用下划线与删除线

#### Scenario: 百分比基线偏移

- **WHEN** 解析 `baseline-shift="10%"`
- **THEN** 得到百分比长度 10，并在渲染时相对 `font-size` 解释

#### Scenario: 装饰线 none 优先

- **WHEN** 解析 `text-decoration="none underline"`
- **THEN** `none` 与其它关键字同时出现时按 `none` 处理并记 warning

### Requirement: M4 渲染保真枚举

系统 SHALL 新增以下公开枚举，均实现 `Equatable` 与 `ToString`：

- `SvgVectorEffect`：`None` / `NonScalingStroke`；
- `SvgOverflow`：`Visible` / `Hidden` / `Scroll` / `Auto`。

`SvgVectorEffect` 的字符串形式 SHALL 为 `none` / `non-scaling-stroke`；`SvgOverflow` 的字符串形式 SHALL 为 `visible` / `hidden` / `scroll` / `auto`。

#### Scenario: 非缩放描边

- **WHEN** 解析 `vector-effect="non-scaling-stroke"`
- **THEN** 得到 `SvgVectorEffect.NonScalingStroke`

#### Scenario: 溢出值

- **WHEN** 解析 `overflow="hidden"`
- **THEN** 得到 `SvgOverflow.Hidden`

### Requirement: M4 滤镜与光照枚举

系统 SHALL 新增以下公开枚举，均实现 `Equatable` 与 `ToString`：

- `SvgTransferFunctionType`：`Identity` / `Table` / `Discrete` / `Linear` / `Gamma`；
- `SvgMorphologyOperator`：`Erode` / `Dilate`；
- `SvgEdgeMode`：`Duplicate` / `Wrap` / `None`；
- `SvgChannelSelector`：`R` / `G` / `B` / `A`；
- `SvgTurbulenceType`：`FractalNoise` / `Turbulence`。

字符串形式 SHALL 与 SVG 属性值一致（`table` / `discrete` / `linear` / `gamma`、`erode` / `dilate`、`duplicate` / `wrap` / `none`、`R` / `G` / `B` / `A`、`fractalNoise` / `turbulence`）。

#### Scenario: 传递函数解析

- **WHEN** 解析 `type="gamma"`
- **THEN** 得到 `SvgTransferFunctionType.Gamma`

#### Scenario: 通道选择器大小写

- **WHEN** 解析 `xChannelSelector="r"` 与 `xChannelSelector="R"`
- **THEN** 两者均得到 `SvgChannelSelector.R`

### Requirement: M4 枚举回退

无法识别的 M4 枚举字符串 SHALL 回退到该属性的规范缺省值并记 warning：`writing-mode` → `lr-tb`、`vector-effect` → `none`、`overflow` → `hidden`、`dominant-baseline` / `alignment-baseline` → `auto`、`type`（传递函数）→ `identity`、`operator`（形态学）→ `erode`、`edgeMode` → `duplicate`、通道选择器 → `A`、`turbulence type` → `turbulence`。

解析 SHALL NOT 抛异常。

#### Scenario: 未知描边效果

- **WHEN** 解析 `vector-effect="scaling-stroke"`
- **THEN** 回退为 `SvgVectorEffect.None` 并追加 warning

#### Scenario: 未知光照通道

- **WHEN** 解析 `yChannelSelector="Z"`
- **THEN** 回退为 `SvgChannelSelector.A` 并追加 warning
