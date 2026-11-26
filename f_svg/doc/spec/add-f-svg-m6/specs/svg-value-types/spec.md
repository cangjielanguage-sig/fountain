# svg-value-types

## ADDED Requirements

### Requirement: M6 交互与渲染提示枚举

系统 SHALL 提供 `SvgPointerEvents`（`Auto` / `None` / `VisiblePainted` / `VisibleFill` / `VisibleStroke` / `Visible` / `Painted` / `Fill` / `Stroke` / `All` / `BoundingBox`）、`SvgShapeRendering`、`SvgTextRendering`、`SvgColorRendering`、`SvgColorInterpolation`。每个枚举 SHALL 提供大小写不敏感的字符串解析与规范 `toString`；未知输入 SHALL 返回 `None` 或回退 `auto` 并 warning。

#### Scenario: pointer-events 往返

- **WHEN** 解析 `visiblePainted`、`bounding-box`、`none`
- **THEN** 依次得到 `VisiblePainted`、`BoundingBox`、`None`，`toString` 还原为 `visiblePainted`、`bounding-box`、`none`

#### Scenario: 大小写不敏感

- **WHEN** 解析 `CRISPEDGES`
- **THEN** 得到 `SvgShapeRendering.CrispEdges`

#### Scenario: 未知值

- **WHEN** 解析 `painted-fast`
- **THEN** 返回 `None`，不抛异常

#### Scenario: 渲染提示字符串

- **WHEN** 对四个渲染提示枚举调用 `toString`
- **THEN** 返回 CSS 小写形式（`optimizeSpeed`、`optimizeLegibility`、`optimizeQuality`、`linearRGB`）

### Requirement: M6 字体与装饰值类型

系统 SHALL 提供 `SvgFontStretch`（9 个关键字或百分比）、`SvgTextDecorationStyle`（`solid` / `double` / `dotted` / `dashed` / `wavy`）与 `SvgTextUnderlinePosition`（`auto` / `under` / `above`）。`SvgFontStretch` SHALL 暴露百分比数值与是否关键字；百分比 SHALL 保留数值精度，关键字 SHALL 映射到 CSS 规范百分比。

#### Scenario: 关键字映射

- **WHEN** 解析 `condensed`
- **THEN** 百分比为 75，`isKeyword` 为真

#### Scenario: 百分比保留

- **WHEN** 解析 `87.5%`
- **THEN** 百分比为 87.5，`isKeyword` 为假

#### Scenario: 非法百分比

- **WHEN** 解析 `0%` 或 `-10%`
- **THEN** 返回 `None`

#### Scenario: 装饰样式往返

- **WHEN** 依次解析五种 `text-decoration-style`
- **THEN** `toString` 与输入一致

### Requirement: M6 根与视图值类型

系统 SHALL 提供 `SvgZoomAndPan`（`Disable` / `Magnify`，缺省 `Disable`）与 `SvgViewState`。`SvgViewState` SHALL 含可读写 `currentScale: Float64`（缺省 1）与可读写 `currentTranslate: SvgPoint`（缺省原点），并 SHALL 提供 `toMatrix()` 返回 `translate(currentTranslate) × scale(currentScale)`。

#### Scenario: zoomAndPan 解析

- **WHEN** 解析 `magnify` 与 `disable`
- **THEN** 分别得到 `Magnify` 与 `Disable`；未知值回退 `Disable`

#### Scenario: 视图状态矩阵

- **WHEN** `currentScale = 2`、`currentTranslate = (10, 20)`
- **THEN** `toMatrix()` 把点 `(1, 1)` 映射为 `(12, 22)`

#### Scenario: 缺省视图状态

- **WHEN** 新建 `SvgViewState()`
- **THEN** `currentScale == 1`、`currentTranslate == (0, 0)`，`toMatrix()` 为单位矩阵

### Requirement: M6 值类型工厂方法

系统 SHALL 为 `SvgPoint`、`SvgMatrix`、`SvgTransform` 提供静态工厂 `create`：`SvgPoint.create(x, y)`、`SvgMatrix.create(a, b, c, d, e, f)`、`SvgTransform.create(operations)`。工厂 SHALL 返回对应类型的实例，不新增子类型，不改变既有构造器与字段语义。

#### Scenario: 点工厂

- **WHEN** 调用 `SvgPoint.create(3, 4)`
- **THEN** 返回 `x == 3`、`y == 4` 的 `SvgPoint`

#### Scenario: 矩阵工厂

- **WHEN** 调用 `SvgMatrix.create(1, 0, 0, 1, 5, 6)`
- **THEN** 返回与 `SvgMatrix(1, 0, 0, 1, 5, 6)` 相等的矩阵

#### Scenario: 变换工厂

- **WHEN** 调用 `SvgTransform.create([Translate(1, 2)])`
- **THEN** 得到包含一个平移操作的变换，`toMatrix()` 与直接构造一致

### Requirement: M6 矢量效果与连接枚举扩展

`SvgVectorEffect` SHALL 新增 `NonScalingSize` / `NonRotation` / `FixedPosition` 三个静态取值，解析与 `toString` SHALL 使用 `non-scaling-size` / `non-rotation` / `fixed-position`；既有 `NoEffect` / `NonScalingStroke` 语义不变。`SvgLineJoin` SHALL 新增 `MiterClip` 与 `Arcs` 两个构造器，字符串形式为 `miter-clip` / `arcs`。

#### Scenario: 新矢量效果往返

- **WHEN** 依次解析三个新名称
- **THEN** 得到对应取值，`toString` 与输入一致

#### Scenario: 旧取值不变

- **WHEN** 解析 `non-scaling-stroke`
- **THEN** 仍得到 `NonScalingStroke`，`strokeScale` 行为不变

#### Scenario: 新连接值

- **WHEN** 解析 `miter-clip` 与 `arcs`
- **THEN** 得到 `MiterClip` 与 `Arcs`；未知值仍返回 `None`

#### Scenario: 既有连接值

- **WHEN** 解析 `miter` / `round` / `bevel`
- **THEN** 行为与 M4 完全一致
