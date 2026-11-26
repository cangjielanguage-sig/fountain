# svg-geometry

## ADDED Requirements

### Requirement: 路径长度测量

`SvgPathData` SHALL 提供 `totalLength(tolerance!: Float64 = 0.25): Float64` 与 `pointAtLength(distance: Float64, tolerance!: Float64 = 0.25): SvgPoint`。

长度 SHALL 由各路径段按扁平化容差离散为折线后累加；弧段 SHALL 转中心参数化后细分。`pointAtLength` SHALL 把负值钳制到起点、超过总长的值钳制到终点，并返回该弧长处的点；空路径 SHALL 返回 `(0, 0)`。

容差非正或非有限时 SHALL 抛 `SvgException(kind: InvalidValue)`。该实现 SHALL 与 `textPath` 排版共用同一套弧长逻辑。

#### Scenario: 直线长度

- **WHEN** `M0 0 L100 0`
- **THEN** `totalLength()` 为 100

#### Scenario: 折线长度

- **WHEN** `M0 0 L3 4 L3 14`
- **THEN** `totalLength()` 为 15

#### Scenario: 圆长度

- **WHEN** 两个半圆弧组成的半径 10 圆
- **THEN** `totalLength()` 约为 `62.83`，误差不超过 0.1

#### Scenario: 中点取点

- **WHEN** `M0 0 L100 0`、`pointAtLength(50)`
- **THEN** 返回 `(50, 0)`

#### Scenario: 端点钳制

- **WHEN** 总长 100，分别取 `-10` 与 `200`
- **THEN** 分别返回起点与终点

#### Scenario: 容差收敛

- **WHEN** 同一圆弧分别用容差 0.5 与 0.01 计算长度
- **THEN** 两者差值不超过较长者的 1%

### Requirement: 元素 CTM

`SvgGeometry.ctm(element)` SHALL 返回元素局部坐标到根用户空间的矩阵，按文档树从根到元素累乘 `transform` 与嵌套 `svg` 的 `viewBox` / `preserveAspectRatio` 变换。

`use` 实例化产生的额外变换 SHALL NOT 计入；元素不在文档树中时 SHALL 返回 `SvgMatrix.identity`。

#### Scenario: 嵌套 g

- **WHEN** `<g transform="translate(10,0)"><g transform="scale(2)"><rect/></g></g>`
- **THEN** `ctm(rect)` 把 `(0,0)` 映射到 `(10,0)`，把 `(1,1)` 映射到 `(12,2)`

#### Scenario: 嵌套 svg

- **WHEN** 内层 `svg` 有 `viewBox="0 0 10 10"` 与 `x="10" y="20" width="20" height="20"`
- **THEN** `ctm` 包含内层视口平移与 2 倍缩放

#### Scenario: 无变换

- **WHEN** 元素及祖先都没有 `transform` 与 `viewBox`
- **THEN** `ctm(element)` 为 `SvgMatrix.identity`

### Requirement: 屏幕 CTM

系统 SHALL 提供 `SvgViewportTransform`，包含 `width`、`height`、`matrix`（`viewBox` → 逻辑画布）与 `devicePixelRatio`，并提供 `from(root, options)` 构造入口。

`SvgGeometry.screenCTM(element, viewport)` SHALL 等于 `ctm(element) × viewport.matrix × scale(devicePixelRatio)`，结果 SHALL 与渲染器为该元素生成的设备矩阵一致。

#### Scenario: 与渲染坐标一致

- **WHEN** 100×100 文档 `viewBox="0 0 50 50"`、`devicePixelRatio=2`，元素位于用户坐标 `(10,10)`
- **THEN** `screenCTM` 把该点映射到设备坐标 `(40,40)`

#### Scenario: 无 viewBox

- **WHEN** 根元素无 `viewBox`、`devicePixelRatio=1`
- **THEN** `screenCTM` 等于 `ctm`

### Requirement: 视图视口换算

`SvgViewport` SHALL 提供 `forView(view: SvgView, viewportWidth: Float64, viewportHeight: Float64): SvgMatrix`，按 `view` 的 `viewBox` 与 `preserveAspectRatio` 计算内容到视口的映射。

`view` 无 `viewBox` 时 SHALL 返回 `SvgMatrix.identity`；视口宽高非正时 SHALL 抛 `SvgException(kind: InvalidValue)`。

#### Scenario: meet 映射

- **WHEN** `viewBox="0 0 100 50"`、视口 200×200、缺省 `preserveAspectRatio`
- **THEN** 缩放为 2，内容垂直居中

#### Scenario: none 拉伸

- **WHEN** `preserveAspectRatio="none"`、同一 `viewBox` 与视口
- **THEN** x 缩放为 2，y 缩放为 4

#### Scenario: slice 裁剪

- **WHEN** `preserveAspectRatio="xMidYMid slice"`、`viewBox="0 0 100 50"`、视口 100×100
- **THEN** 缩放为 2，左右内容被裁掉

#### Scenario: 非法视口

- **WHEN** `viewportWidth = 0`
- **THEN** 抛 `SvgException(kind: InvalidValue)`
