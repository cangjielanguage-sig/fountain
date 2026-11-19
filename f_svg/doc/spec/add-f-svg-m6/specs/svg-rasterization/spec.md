# svg-rasterization

## MODIFIED Requirements

### Requirement: 抗锯齿

系统 SHALL 支持两档抗锯齿，由 `SvgRenderOptions.antiAlias` 选择：

- `Supersample`（默认）：每像素在 x 与 y 方向各取 `samplesPerPixel` 个子采样点，覆盖率由命中数平均；
- `Analytic`：使用解析覆盖率，`samplesPerPixel` 不参与计算。

`Supersample` 档下 `samplesPerPixel = 1` SHALL 关闭抗锯齿，用于像素精确用例；`2` / `4` SHALL 逐级提升边缘平滑度。

`Analytic` 档的覆盖率 SHALL 与同一几何的 **64× 超采样参考图**保持一致：对应像素的任一通道差值不超过 `2/255`。4× 点采样自身的量化误差可达约 `15/255`，不得作为 `2/255` 的判据。

元素的 `shape-rendering` 非 `auto` 时 SHALL 在本次绘制覆盖全局档位：`optimizeSpeed` 强制单采样，`crispEdges` 关闭形状与描边抗锯齿，`geometricPrecision` 提高曲线扁平化精度。缺省 `auto` SHALL 保持上述全局行为。

#### Scenario: 斜边覆盖

- **WHEN** `samplesPerPixel = 4` 填充一个 45° 三角形
- **THEN** 斜边经过的像素覆盖率严格介于 0 与 1 之间，且相邻像素覆盖率和约为 1

#### Scenario: 关闭抗锯齿

- **WHEN** `samplesPerPixel = 1` 填充同样的三角形
- **THEN** 每个像素覆盖率为 0 或 1

#### Scenario: 解析档

- **WHEN** `antiAlias = Analytic` 填充同样的 45° 三角形
- **THEN** 每个像素覆盖率介于 0 与 1 之间，且与 64× 超采样参考图的差值不超过 `2/255`

#### Scenario: optimizeSpeed 覆盖全局档位

- **WHEN** 全局 `samplesPerPixel = 4`，元素 `shape-rendering="optimizeSpeed"`
- **THEN** 该元素边缘像素覆盖率为 0 或 1

#### Scenario: 缺省不受影响

- **WHEN** 元素未声明 `shape-rendering`
- **THEN** 输出与 M5 逐字节一致

### Requirement: join 与 dash 规则

miter join 超过 `miterlimit` 时 SHALL 退化为 bevel。`miter-clip` SHALL 在超过 `miterlimit` 时把尖角截断到 `miterlimit × stroke-width / 2` 处，而不是退化为 bevel。`arcs` SHALL 以 `stroke-width / 2` 为半径生成圆弧连接。

round join / cap SHALL 按设备像素误差 ≤ 0.25 离散为折线。

dash SHALL 按 `dasharray` 周期切分中心线，奇数长度数组 SHALL 复制一次后使用，每段独立加 cap；`dasharray` 全为 0 或负数 SHALL 视为不描边。

路径存在合法 `pathLength` 时，`dasharray` 与 `dashoffset` SHALL 先乘以 `实际弧长 / pathLength` 再参与切分；未声明时 SHALL 保持原值。

#### Scenario: miter 截断

- **WHEN** 锐角 join、`miterlimit=2`
- **THEN** 尖角被截断为 bevel，不产生超长尖刺

#### Scenario: miter-clip

- **WHEN** 同一锐角、`miterlimit=2`、`stroke-linejoin="miter-clip"`
- **THEN** 尖角被垂直截断在 `1 × stroke-width` 处，截断端为直线

#### Scenario: arcs

- **WHEN** `stroke-linejoin="arcs"`、`stroke-width="4"`
- **THEN** 连接处为半径 2 的圆弧，覆盖区域与 round 的差异不超过 `1/255`

#### Scenario: dash 相位

- **WHEN** `stroke-dasharray="4 2"`、`stroke-dashoffset="2"`
- **THEN** 虚线相位整体前移 2 个用户单位，周期仍为 6

#### Scenario: pathLength 影响 dash

- **WHEN** 实际弧长 200、`pathLength="100"`、`stroke-dasharray="10"`
- **THEN** 实际虚线段长为 20 用户单位

#### Scenario: 非法 pathLength

- **WHEN** `pathLength="0"`
- **THEN** dash 行为与未声明时一致，并 warning

## ADDED Requirements

### Requirement: M6 渲染提示到光栅参数

`shape-rendering` / `text-rendering` / `color-rendering` SHALL 改变对应元素的曲线容差、采样档位或渐变查表精度；映射 SHALL 由属性取值唯一确定，并只作用于声明元素及其继承后代。`auto` SHALL 保持 M5 行为。

#### Scenario: shape geometricPrecision

- **WHEN** `shape-rendering="geometricPrecision"`
- **THEN** 曲线扁平化容差为 `auto` 的 0.25 倍

#### Scenario: text optimizeSpeed

- **WHEN** `text-rendering="optimizeSpeed"`
- **THEN** 文本曲线容差为 `auto` 的 2 倍，且不形成连字、不应用字距

#### Scenario: text optimizeLegibility

- **WHEN** `text-rendering="optimizeLegibility"`
- **THEN** 文本曲线容差为 `auto` 的 0.5 倍，且连字与字距按字体表启用

#### Scenario: text geometricPrecision

- **WHEN** `text-rendering="geometricPrecision"`
- **THEN** 文本曲线容差为 `auto` 的 0.25 倍，连字与字距仍按字体表启用

#### Scenario: 渐变量化

- **WHEN** 同一渐变分别以 `color-rendering="optimizeSpeed"` 与 `optimizeQuality` 渲染
- **THEN** 前者使用 128 级量化，后者使用 512 级量化，端点颜色不变

#### Scenario: 继承范围

- **WHEN** 组声明 `shape-rendering="crispEdges"`，子元素未声明
- **THEN** 子元素同样按 `crispEdges` 光栅化；组外元素不受影响

#### Scenario: 缺省一致

- **WHEN** 三个属性均为 `auto`
- **THEN** 输出与 M5 逐字节一致
