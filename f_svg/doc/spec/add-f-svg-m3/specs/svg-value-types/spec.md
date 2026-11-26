# svg-value-types

## ADDED Requirements

### Requirement: M3 渲染枚举

系统 SHALL 新增以下公开枚举，均实现 `Equatable` 与 `ToString`：

- `SvgAntiAliasMode`：`Supersample` / `Analytic`；
- `SvgBlendMode`：`Normal` / `Multiply` / `Screen` / `Darken` / `Lighten`；
- `SvgCompositeOperator`：`Over` / `In` / `Out` / `Atop` / `Xor` / `Arithmetic`；
- `SvgColorMatrixType`：`Matrix` / `Saturate` / `HueRotate` / `LuminanceToAlpha`。

#### Scenario: 混合模式解析

- **WHEN** 解析 `mode="multiply"` 与 `operator="arithmetic"`
- **THEN** 分别得到 `SvgBlendMode.Multiply` 与 `SvgCompositeOperator.Arithmetic`

### Requirement: M3 标记与图像枚举

系统 SHALL 新增以下公开枚举，均实现 `Equatable` 与 `ToString`：

- `SvgMarkerUnits`：`StrokeWidth` / `UserSpaceOnUse`；
- `SvgMarkerOrient`：`Auto` / `AutoStartReverse` / `Angle(Float64)`；
- `SvgImageRendering`：`Auto` / `OptimizeQuality` / `Pixelated` / `OptimizeSpeed`。

`SvgMarkerOrient.Angle` SHALL 保存角度值；`toString` SHALL 输出不带单位的数值。

#### Scenario: orient 角度

- **WHEN** 解析 `orient="45"`
- **THEN** 得到 `SvgMarkerOrient.Angle(45.0)`，`toString()` 为 `45`

### Requirement: M3 枚举字符串与回退

坐标单位（`filterUnits` / `primitiveUnits` / `patternUnits` / `patternContentUnits`）SHALL 复用既有 `SvgCoordinateUnits`，不新增重复类型。

枚举的字符串形式 SHALL 与 SVG 属性值一致：`normal`、`multiply`、`screen`、`darken`、`lighten`、`over`、`in`、`out`、`atop`、`xor`、`arithmetic`、`matrix`、`saturate`、`hueRotate`、`luminanceToAlpha`、`strokeWidth`、`userSpaceOnUse`、`auto`、`auto-start-reverse`。

无法识别的枚举字符串 SHALL 回退到该属性的规范缺省值并记 warning，不得抛异常。

#### Scenario: 未知值回退

- **WHEN** `mode="unknown"`
- **THEN** 回退为 `SvgBlendMode.Normal` 并追加 warning


### Requirement: M3 数值列表与矩阵值

`SvgFeGaussianBlur.stdDeviation` SHALL 复用 `SvgNumberList`，接受空白或逗号分隔的 1 个或 2 个非负数；负数 SHALL 取绝对值或回退为 0，并记 warning。

`SvgFeColorMatrix.values` SHALL 为 `Array<Float64>`：

- `matrix` 需要 20 个值；
- `saturate` / `hueRotate` 需要 1 个值；
- `luminanceToAlpha` 忽略输入值。

值个数不符或包含非有限值时 SHALL 记 warning 并按该原语的直通语义处理。

#### Scenario: 单值标准差

- **WHEN** `stdDeviation="2"`
- **THEN** `SvgNumberList` 解析出一个值，渲染时同时用于 x 与 y

#### Scenario: 矩阵值个数

- **WHEN** `type="matrix"` 且只提供 10 个值
- **THEN** 记 warning，颜色矩阵按直通处理

#### Scenario: 负标准差

- **WHEN** `stdDeviation="-1"`
- **THEN** 记 warning，渲染按 0 处理，不抛异常
