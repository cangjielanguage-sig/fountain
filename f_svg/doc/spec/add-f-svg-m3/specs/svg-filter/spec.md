# svg-filter

## ADDED Requirements

### Requirement: 滤镜模型

系统 SHALL 提供 `SvgFilter <: SvgElement`，包含 `x` / `y` / `width` / `height`（`?SvgLength`）、`filterUnits` 与 `primitiveUnits`（`SvgCoordinateUnits`）以及 `primitives: ArrayList<SvgFilterPrimitive>`。

`x` / `y` / `width` / `height` 的缺省值 SHALL 分别为 `-10%` / `-10%` / `120%` / `120%`；`filterUnits` 缺省为 `ObjectBoundingBox`，`primitiveUnits` 缺省为 `UserSpaceOnUse`。

#### Scenario: 默认区域

- **WHEN** 元素包围盒为 `(100, 100, 200, 100)`，`<filter>` 未写区域属性
- **THEN** 滤镜区域为 `(80, 90, 240, 120)`，即包围盒四周各扩 10%

### Requirement: 滤镜区域与上限

滤镜区域 SHALL 按 `filterUnits` 换算：`ObjectBoundingBox` 时相对元素包围盒，`userSpaceOnUse` 时使用当前用户坐标。区域 SHALL 与画布求交，超出画布的部分不参与计算。

区域像素数超过 `SvgRenderOptions.maxPixels` 时，系统 SHALL 在分配缓冲前抛 `SvgException(kind: Limit)`。

#### Scenario: userSpaceOnUse 区域

- **WHEN** `filterUnits="userSpaceOnUse"` 且 `x=0 y=0 width=50 height=50`
- **THEN** 区域为 `(0, 0, 50, 50)`，不随元素包围盒缩放

#### Scenario: 区域超限

- **WHEN** 滤镜区域像素数超过 `maxPixels`
- **THEN** 抛 `SvgException(kind: Limit)`，且未分配区域缓冲

### Requirement: 图连接与缓冲

系统 SHALL 提供 `SvgFilterPrimitive <: SvgElement` 基类，含 `inSource: ?String` 与 `result: ?String`。

`in` / `in2` 的解析 SHALL 遵循：

- 首个原语缺省 `in` 为 `SourceGraphic`；
- 后续原语缺省 `in` 为前一个原语的 `result`；
- `in2` 缺省为 `SourceGraphic`；
- 引用不存在的名字时，该原语 SHALL 输出透明黑并追加 warning，滤镜链继续执行。

滤镜链 SHALL 使用 `SvgFilterBuffer`（`width` / `height` / RGBA8 非预乘 `pixels`），每个原语产生新缓冲。

`<filter>` 不含任何原语时，系统 SHALL 返回 `SourceGraphic` 的拷贝。

`color-interpolation-filters="linearRGB"` 时，系统 SHALL 在进入与离开滤镜链时各做一次 sRGB ↔ linearRGB 转换；缺省按 sRGB 计算。

#### Scenario: 隐式图连接

- **WHEN** 滤镜含 `feFlood`、`feOffset`、`feBlend` 三个原语，且只有第一个写了 `result="a"`
- **THEN** `feOffset` 的输入为 `a`，`feBlend` 的输入为 `feOffset` 的结果，`in2` 为 `SourceGraphic`

#### Scenario: 未定义引用

- **WHEN** 某原语 `in="missing"`
- **THEN** 该原语输出全透明黑，`warnings` 至少一条包含 `missing`，后续原语仍执行

#### Scenario: 空滤镜链

- **WHEN** `<filter></filter>` 应用于红色矩形
- **THEN** 输出像素与未加滤镜时逐字节一致

### Requirement: 高斯模糊与偏移

`SvgFeGaussianBlur` SHALL 提供 `stdDeviation: SvgNumberList`：

- 单值 SHALL 同时作为 x / y 标准差；
- 二元组 SHALL 分别作为 x / y 标准差；
- 核半径 SHALL 为 `ceil(3σ)`，并做可分离的两次一维卷积；
- 任一分量为 0 时该方向直通；两分量均为 0 时整体直通。

`SvgFeOffset` SHALL 提供 `dx` / `dy`（`SvgLength`），按整数像素平移，越界区域补透明。

#### Scenario: σ=0 直通

- **WHEN** `stdDeviation="0"`
- **THEN** 输出缓冲与输入缓冲逐字节一致

#### Scenario: 单值标准差

- **WHEN** `stdDeviation="2"`，输入为单个不透明像素
- **THEN** 输出在 x、y 方向的扩散范围对称，且中心像素不再为全不透明

#### Scenario: 偏移越界

- **WHEN** `dx=10 dy=0` 且输入内容贴左边界
- **THEN** 右侧补透明，左侧越出的像素不参与合成

### Requirement: 洪水填充与混合

`SvgFeFlood` SHALL 用 `flood-color` 与 `flood-opacity` 的乘积填满滤镜区域；缺省颜色为黑色、缺省不透明度为 1。

`SvgFeBlend` SHALL 提供 `in2: ?String` 与 `mode: SvgBlendMode`，支持 `normal` / `multiply` / `screen` / `darken` / `lighten`。`normal` SHALL 等价于 `over`。

逐通道混合 SHALL 在非预乘 alpha 下计算，结果 alpha 按 `over` 规则合成，结果通道钳制到 `0..255`。

#### Scenario: 洪水填充

- **WHEN** `flood-color="#00FF00"`、`flood-opacity="0.5"`
- **THEN** 滤镜区域内所有像素为 `(0, 255, 0, 128)`

#### Scenario: normal 等价 over

- **WHEN** 同一对输入分别走 `feBlend mode="normal"` 与 `feComposite operator="over"`
- **THEN** 两者输出逐字节一致

#### Scenario: multiply

- **WHEN** 输入 A 为不透明红色、输入 B 为不透明蓝色，`mode="multiply"`
- **THEN** 输出为不透明黑色 `(0, 0, 0, 255)`

### Requirement: 合成与合并

`SvgFeComposite` SHALL 提供 `in2`、`operator: SvgCompositeOperator` 与 `k1` / `k2` / `k3` / `k4`。

`over` / `in` / `out` / `atop` / `xor` SHALL 按 Porter-Duff 规则逐像素计算；`arithmetic` SHALL 按 `k1·i·j + k2·i + k3·j + k4` 计算并钳制到 `0..1`，其中 `i` / `j` 为两输入的非预乘颜色。

`SvgFeMerge` SHALL 按 `feMergeNode` 子元素的顺序把各自 `in` 指向的缓冲以 `over` 合成；缺省 `in` 为前一个原语结果。

#### Scenario: 算术合成

- **WHEN** `operator="arithmetic"`、`k1=0 k2=1 k3=1 k4=0`，两输入均为不透明 `(128, 0, 0, 255)`
- **THEN** 输出红色通道为 255，其余通道为 0

#### Scenario: merge 顺序

- **WHEN** `feMergeNode in="a"` 后接 `feMergeNode in="b"`，a 为红、b 为半透明蓝
- **THEN** 最终像素以 b over a 计算

### Requirement: 颜色矩阵与平铺

`SvgFeColorMatrix` SHALL 提供 `matrixType: SvgColorMatrixType` 与 `values: Array<Float64>`：

- `matrix` SHALL 接受 20 个值，按 4×5 行优先矩阵作用于非预乘 RGBA；
- `saturate` SHALL 接受 1 个值，生成饱和度矩阵；
- `hueRotate` SHALL 接受 1 个值（角度），生成色相旋转矩阵；
- `luminanceToAlpha` SHALL 忽略输入值，生成亮度转 alpha 矩阵。

矩阵结果 SHALL 钳制到 `0..1`；值个数不符时 SHALL 记 warning 并直通输入。

`SvgFeTile` SHALL 以输入缓冲为一个 tile，在滤镜区域内平铺；输入尺寸为 0 时输出透明并记 warning。

#### Scenario: 亮度转 alpha

- **WHEN** 输入不透明白色，`matrixType="luminanceToAlpha"`
- **THEN** 输出 alpha 为 255，RGB 均为 0

#### Scenario: 平铺

- **WHEN** 输入为 2×2 缓冲、滤镜区域为 6×6
- **THEN** 输出按 2×2 周期重复，区域四角像素与输入 `(0,0)` 一致

### Requirement: 滤镜入口与确定性

系统 SHALL 提供 `SvgFilterRenderer`（`init(registry!)`）与 `apply(filter, source, objectBounds, transform, options)`，返回与 `source` 同尺寸的位图，滤镜区域外为透明。

`apply` SHALL 不修改 `filter`、`source` 或 `options`；同一输入与选项多次调用 SHALL 产生逐字节一致的输出。

滤镜引用的 `filter` 元素不存在或 `filter` 属性为空时，渲染 SHALL 跳过滤镜并记 warning，不抛异常。

#### Scenario: 不修改输入

- **WHEN** 对同一 `SvgFilter` 连续调用 `apply` 两次
- **THEN** 两次输出逐字节一致，且 `source.pixels` 与调用前一致

#### Scenario: 缺失滤镜引用

- **WHEN** 元素 `filter="url(#none)"`
- **THEN** 渲染按无滤镜处理并追加 warning，不抛异常
