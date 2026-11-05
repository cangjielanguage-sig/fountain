# svg-rasterization

## MODIFIED Requirements

### Requirement: 渲染选项

系统 SHALL 提供 `SvgRenderOptions`，字段为 `width` / `height` / `background` / `samplesPerPixel` / `maxPixels` / `fonts` / `devicePixelRatio` / `images` / `antiAlias`。

默认值 SHALL 为：`width` / `height` 取根元素尺寸，根元素无绝对尺寸时取 300×150；`background` 为透明；`samplesPerPixel = 4`；`maxPixels = 64 × 1024 × 1024`；`devicePixelRatio = 1.0`；`images = None`；`antiAlias = Supersample`。

`width` / `height` 为 `0` SHALL 表示自动：取根元素绝对尺寸，根元素无绝对尺寸时取 300×150；负值抛 `InvalidValue`。`samplesPerPixel` SHALL 只接受 1、2、4，其余值抛 `InvalidValue`；`devicePixelRatio` ≤ 0 抛 `InvalidValue`。

`fonts` 为 `None` 时渲染器 SHALL 使用 `SvgFontRegistry.defaultRegistry()`；传入注册表时 SHALL 只使用传入的注册表。

`devicePixelRatio` SHALL 只影响最终像素尺寸与根设备矩阵（追加 `scale(dpr)`）；`viewBox` 到逻辑画布的映射仍按 `width × height` 计算。

新增字段 SHALL 全部带默认值，既有构造调用不需要修改；未使用新字段时输出与 M2 逐字节一致。

#### Scenario: 高 DPI

- **WHEN** 逻辑画布 100×100、`devicePixelRatio = 2`
- **THEN** 输出位图为 200×200，1 个用户单位对应 2 个设备像素

#### Scenario: 默认尺寸

- **WHEN** 根元素 `width="120" height="80"`，使用默认选项
- **THEN** 输出位图为 120×80

#### Scenario: 无尺寸根元素

- **WHEN** 根元素没有 `width` / `height`，使用默认选项
- **THEN** 输出位图为 300×150

#### Scenario: 非法采样数

- **WHEN** `samplesPerPixel = 3`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

#### Scenario: 新字段默认值

- **WHEN** 构造 `SvgRenderOptions()`
- **THEN** `images == None` 且 `antiAlias == Supersample`

### Requirement: 抗锯齿

系统 SHALL 支持两档抗锯齿，由 `SvgRenderOptions.antiAlias` 选择：

- `Supersample`（默认）：每像素在 x 与 y 方向各取 `samplesPerPixel` 个子采样点，覆盖率由命中数平均；
- `Analytic`：使用解析覆盖率，`samplesPerPixel` 不参与计算。

`Supersample` 档下 `samplesPerPixel = 1` SHALL 关闭抗锯齿，用于像素精确用例；`2` / `4` SHALL 逐级提升边缘平滑度。

`Analytic` 档的覆盖率 SHALL 与 `Supersample` 档保持视觉一致：同一图形的边缘像素差值不超过 `2/255`。

#### Scenario: 斜边覆盖

- **WHEN** `samplesPerPixel = 4` 填充一个 45° 三角形
- **THEN** 斜边经过的像素覆盖率严格介于 0 与 1 之间，且相邻像素覆盖率和约为 1

#### Scenario: 关闭抗锯齿

- **WHEN** `samplesPerPixel = 1` 填充同样的三角形
- **THEN** 每个像素覆盖率为 0 或 1

#### Scenario: 解析档

- **WHEN** `antiAlias = Analytic` 填充同样的 45° 三角形
- **THEN** 每个像素覆盖率介于 0 与 1 之间，且与 4× 超采样结果的差值不超过 `2/255`

## ADDED Requirements

### Requirement: 解析覆盖率

系统 SHALL 提供 `SvgAntiAliasMode`（`Supersample` / `Analytic`）与解析覆盖率光栅路径。

`Analytic` 档 SHALL 把路径按现有扁平化容差离散为设备空间线段，用有符号面积累加计算每个像素的覆盖率：

- 每条线段 SHALL 按像素列累加有符号面积；
- 像素内外 SHALL 由 `nonzero` / `evenodd` 规则独立判定，不得仅依赖面积符号；
- 覆盖率 SHALL 钳制到 `0..1`；
- 颜色 SHALL 按 `source-over` 合成，公式与 `Supersample` 档一致。

45° 斜线两侧相邻像素的覆盖率之和 SHALL 约等于 1（误差 ≤ `1/255`）；圆形边缘的解析覆盖率与 4× 超采样结果 SHALL 满足误差 ≤ `2/255`。

`Analytic` 档 SHALL 支持与描边、渐变、图案、滤镜、marker、裁剪、蒙版组合使用，且同一输入多次渲染输出逐字节一致。

#### Scenario: 覆盖率守恒

- **WHEN** 在 4×4 位图上用 `Analytic` 填充一条 45° 斜线穿过的区域
- **THEN** 斜线两侧相邻像素的覆盖率之和与 1 的误差不超过 `1/255`

#### Scenario: 圆的误差

- **WHEN** 用 `Analytic` 与 `Supersample`（4×）分别填充同一圆
- **THEN** 对应像素通道差值不超过 `2/255`

#### Scenario: 自交 nonzero

- **WHEN** 用 `Analytic` + `nonzero` 填充自交回旋路径
- **THEN** 重叠区域为实心，与 `Supersample` + `nonzero` 结果一致

#### Scenario: 自交 evenodd

- **WHEN** 用 `Analytic` + `evenodd` 填充同一路径
- **THEN** 重叠区域出现空洞，与 `Supersample` + `evenodd` 结果一致

#### Scenario: 组合确定性

- **WHEN** `Analytic` 与 marker、pattern、filter 同时启用，连续渲染两次
- **THEN** 两次输出逐字节一致
