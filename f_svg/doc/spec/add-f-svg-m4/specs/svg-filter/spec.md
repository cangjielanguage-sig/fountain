# svg-filter

## ADDED Requirements

### Requirement: 分量传递

系统 SHALL 提供 `SvgFeComponentTransfer`，含 `feFuncR` / `feFuncG` / `feFuncB` / `feFuncA` 四个函数子元素。每个通道 SHALL 独立按 `type` 计算：`identity` 直通；`table` 在 `tableValues` 间分段线性插值；`discrete` 取 `floor(C × n)` 对应值；`linear` 为 `slope × C + intercept`；`gamma` 为 `amplitude × C^exponent + offset`。

结果 SHALL 钳制到 `0..1`；缺少某通道函数时 SHALL 按 `identity` 处理。

#### Scenario: table 插值

- **WHEN** `feFuncR type="table" tableValues="0 1"`，输入红色通道为 `0.5`
- **THEN** 输出红色通道约为 `0.5`

#### Scenario: discrete 阶梯

- **WHEN** `type="discrete" tableValues="0 0.25 0.5 0.75"`，输入 `0.6`
- **THEN** 输出为 `0.5`（索引 `floor(0.6 × 4) = 2`）

#### Scenario: linear 钳制

- **WHEN** `type="linear" slope="2" intercept="0"`，输入 `0.8`
- **THEN** 输出为 `1.0`，不产生溢出

#### Scenario: 缺失通道函数

- **WHEN** 只有 `feFuncR`，没有 `feFuncG/B/A`
- **THEN** G、B、A 通道保持输入值

#### Scenario: 表值个数不足

- **WHEN** `type="table"` 且 `tableValues` 为空
- **THEN** 该通道按直通处理并追加 warning

### Requirement: 形态学

`SvgFeMorphology` SHALL 提供 `operator`（`erode` / `dilate`，缺省 `erode`）与 `radius`（1 或 2 个非负长度，缺省 0）。

算法 SHALL 用矩形核在 RGBA 各通道取局部最小（`erode`）或最大（`dilate`）；半径按 `primitiveUnits` 换算到设备像素后取整；半径 0 SHALL 直通。

#### Scenario: 腐蚀收边

- **WHEN** 不透明 10×10 方块、`operator="erode"`、`radius="1"`
- **THEN** 输出不透明区域缩小到 8×8

#### Scenario: 膨胀扩边

- **WHEN** 同一输入、`operator="dilate"`、`radius="1"`
- **THEN** 不透明区域扩大到 12×12

#### Scenario: 零半径

- **WHEN** `radius="0"`
- **THEN** 输出与输入逐字节一致

#### Scenario: 负半径

- **WHEN** `radius="-1"`
- **THEN** 按 0 处理并追加 warning

### Requirement: 卷积矩阵

`SvgFeConvolveMatrix` SHALL 提供 `order`（1 或 2 个正整数，缺省 3）、`kernelMatrix`、`divisor`、`bias`（缺省 0）、`targetX` / `targetY`、`edgeMode`（`duplicate` 缺省 / `wrap` / `none`）与 `preserveAlpha`。

系统 SHALL 直接做二维卷积，结果除以 `divisor`（缺省为核和，核和为 0 时取 1）再加 `bias` 并钳制；`preserveAlpha` 为真时只卷积 RGB，alpha 保持输入。

`kernelMatrix` 长度不等于 `orderX × orderY`、`order` 不是正整数或 `kernelMatrix` 含非有限值时 SHALL 记 warning 并按直通处理；`order` 任一维超过 9 时 SHALL 抛 `SvgException(kind: Limit)`。

#### Scenario: 单位核

- **WHEN** `order="3"`、`kernelMatrix="0 0 0 0 1 0 0 0 0"`、`divisor="1"`
- **THEN** 输出与输入逐字节一致

#### Scenario: 锐化核

- **WHEN** `kernelMatrix="0 -1 0 -1 5 -1 0 -1 0"`、`divisor="1"`、输入为实心方块
- **THEN** 边缘像素值高于内部像素

#### Scenario: edgeMode 边界

- **WHEN** 同一输入分别使用 `edgeMode="duplicate"` 与 `"none"`
- **THEN** `duplicate` 的边缘像素保持不透明，`none` 的边缘像素因越界补透明而变暗

#### Scenario: 核超限

- **WHEN** `order="10 10"`
- **THEN** 抛 `SvgException(kind: Limit)`，且未分配卷积缓冲

### Requirement: 湍流

`SvgFeTurbulence` SHALL 提供 `turbulenceType`（`fractalNoise` 缺省 / `turbulence`）、`baseFrequency`（1 或 2 个非负数）、`numOctaves`（缺省 1）、`seed`（缺省 0）与 `stitchTiles`（`noStitch` 缺省 / `stitch`）。

系统 SHALL 以 `seed` 决定梯度表，按倍频叠加 Perlin 风格噪声并输出 RGBA8：RGB 取噪声映射，A 为 255。`numOctaves` 超过 8 时 SHALL 抛 `SvgException(kind: Limit)`。

#### Scenario: 确定性

- **WHEN** 同一 `seed` 与参数连续执行两次
- **THEN** 两次输出逐字节一致

#### Scenario: 两类噪声

- **WHEN** 同一输入分别使用 `fractalNoise` 与 `turbulence`
- **THEN** 两者输出不同，且 `turbulence` 的通道均值更低

#### Scenario: 倍频超限

- **WHEN** `numOctaves="9"`
- **THEN** 抛 `SvgException(kind: Limit)`

### Requirement: 位移映射

`SvgFeDisplacementMap` SHALL 提供 `scale`（缺省 0）、`xChannelSelector` / `yChannelSelector`（缺省 `A`）。

系统 SHALL 按 `offset = scale × (channel / 255 - 0.5)` 计算位移，用 `in2` 的对应通道偏移 `in` 的采样坐标，采样 SHALL 使用双线性插值，越界 SHALL 取透明。

`in2` 缺省为 `SourceGraphic`；输入缓冲缺失时 SHALL 输出透明并记 warning。

#### Scenario: 零位移

- **WHEN** `scale="0"`
- **THEN** 输出与输入逐字节一致

#### Scenario: 通道位移

- **WHEN** `scale="10"`、`xChannelSelector="R"`，`in2` 全红不透明
- **THEN** 输出相对输入右移 5 像素

#### Scenario: 越界透明

- **WHEN** 位移把采样坐标推出输入边界
- **THEN** 对应输出像素为透明

### Requirement: 图像原语

`SvgFeImage` SHALL 提供 `href` 与 `preserveAspectRatio`（缺省 `xMidYMid meet`）。

资源 SHALL 只接受 `data:image/png` 与 `SvgImageResourceProvider` 注入，并按 `preserveAspectRatio` 映射到滤镜区域。资源不可用或解码失败时 SHALL 输出透明并记 warning，不抛异常（`Limit` 继续向上抛）。解码 SHALL 与 `<image>` 共享单次渲染预算。

#### Scenario: data URI

- **WHEN** `href` 为合法 1×1 红色 PNG 的 data URI
- **THEN** 滤镜区域填满红色

#### Scenario: provider

- **WHEN** 注入返回 PNG 字节的 provider，`href="mem://tex"`
- **THEN** 滤镜区域绘制该图像，且同一 `href` 只解析一次

#### Scenario: 资源不可用

- **WHEN** 未注入 provider 且 `href="mem://tex"`
- **THEN** 输出全透明并追加 warning

#### Scenario: 预算超限

- **WHEN** `feImage` 解码像素使单次渲染累计超过预算
- **THEN** 抛 `SvgException(kind: Limit)`

### Requirement: 光照

系统 SHALL 提供 `SvgFeDiffuseLighting` 与 `SvgFeSpecularLighting`，含 `surfaceScale`、`diffuseConstant` / `specularConstant`、`specularExponent`、`lighting-color` 与唯一光源子元素。

法线 SHALL 由输入 alpha 的有限差分求；`diffuse` 按 Lambert 计算，`specular` 按 Blinn-Phong 计算；输出 alpha SHALL 等于输入 alpha。光源 SHALL 支持 `feDistantLight`（`azimuth` / `elevation`）、`fePointLight`（`x` / `y` / `z`）与 `feSpotLight`（`pointsAtX` / `pointsAtY` / `pointsAtZ`、`specularExponent`、`limitingConeAngle`）。

缺少光源或光源类型未知时 SHALL 输出透明并记 warning。

#### Scenario: 平行光漫反射

- **WHEN** 输入为不透明平面、`feDistantLight elevation="90"`
- **THEN** 输出为 `lighting-color × diffuseConstant`，alpha 与输入一致

#### Scenario: 点光源渐变

- **WHEN** `fePointLight` 位于平面一侧
- **THEN** 输出亮度随到光源距离衰减，近处更亮

#### Scenario: 高光

- **WHEN** `feSpecularLighting specularExponent="20"` 且光源与视线接近
- **THEN** 输出出现高光峰值且峰值通道不超过 255

#### Scenario: 无光源

- **WHEN** 光照原语没有光源子元素
- **THEN** 该原语输出透明并追加 warning，链继续执行

### Requirement: 新原语共同约束

新增原语 SHALL 输出与输入同尺寸（滤镜区域），越界按透明处理；输入尺寸为 0 时 SHALL 输出透明并记 warning。

参数非法（非有限、维度不符）时 SHALL 记 warning，并按各原语定义的直通或透明语义处理；上限类失败仍抛 `SvgException(kind: Limit)`。所有原语 SHALL 确定性，同一输入与参数多次执行输出逐字节一致。

#### Scenario: 零尺寸输入

- **WHEN** 上游原语输出 0×0 缓冲
- **THEN** 新原语输出透明并追加 warning，不抛异常

#### Scenario: 非有限参数

- **WHEN** `feDisplacementMap scale="nan"`
- **THEN** `scale` 按 0 处理并追加 warning

#### Scenario: 确定性

- **WHEN** 含湍流与光照的滤镜链连续执行两次
- **THEN** 两次输出逐字节一致
