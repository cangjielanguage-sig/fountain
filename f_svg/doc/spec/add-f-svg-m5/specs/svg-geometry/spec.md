# svg-geometry

## ADDED Requirements

### Requirement: M5 元素级包围盒 API

`SvgElement` SHALL 提供 `getBBox(options!: SvgBBoxOptions = SvgBBoxOptions()): ?SvgBounds`，返回元素自身用户坐标系中的轴对齐包围盒。

`SvgBBoxOptions` SHALL 含 `stroke: Bool = false`、`clipped: Bool = false` 与 `fonts: ?SvgFontRegistry = None`。`stroke` 为真时 SHALL 并入描边外扩；`clipped` 为真时 SHALL 与元素的有效视口裁剪矩形（根视口、嵌套 `svg`、`viewport` 类元素）求交，`clip-path` 与 `mask` SHALL NOT 参与；`fonts` 为 `None` 时 SHALL 使用默认字体注册表。

不可渲染或几何无效的元素 SHALL 返回 `None`。方法 SHALL NOT 修改文档，SHALL NOT 跨调用缓存结果。

#### Scenario: 形状包围盒

- **WHEN** `<rect x="10" y="20" width="30" height="40"/>` 调用 `getBBox()`
- **THEN** 返回 `(10, 20, 30, 40)`

#### Scenario: 描边外扩

- **WHEN** 同一矩形 `stroke-width="4"`、`stroke="red"`，调用 `getBBox(options: SvgBBoxOptions(stroke: true))`
- **THEN** 返回 `(8, 18, 34, 44)`

#### Scenario: 无描边不扩展

- **WHEN** `stroke="none"` 且 `stroke: true`
- **THEN** 返回几何包围盒

#### Scenario: 视口裁剪

- **WHEN** 元素因祖先 `<svg>` 视口只显示一部分，调用 `clipped: true`
- **THEN** 结果被裁剪到可见视口内

#### Scenario: 不可渲染元素

- **WHEN** 对 `defs` 或空路径调用 `getBBox()`
- **THEN** 返回 `None`，不抛异常

### Requirement: M5 容器与引用包围盒

`getBBox` SHALL 对 `g` / `a` / `switch` / 嵌套 `svg` 返回后代几何包围盒的并集，并计入子元素自身的 `transform`；`options.stroke` 为真时 SHALL 对每个后代分别并入描边。

对 `use` SHALL 返回被引用元素包围盒叠加 `x` / `y` 平移后的结果；对 `image` SHALL 返回 `x` / `y` / `width` / `height` 矩形；对 `defs` / `symbol` / 渐变 / 滤镜 / 裁剪 / 蒙版等定义型元素 SHALL 返回 `None`。无可见后代的容器 SHALL 返回 `None`。

#### Scenario: 组并集

- **WHEN** `<g><rect x="0" y="0" width="10" height="10"/><rect x="20" y="5" width="10" height="10"/></g>`
- **THEN** 组包围盒为 `(0, 0, 30, 15)`

#### Scenario: 子变换计入

- **WHEN** 组内第二个矩形 `transform="translate(100,0)"`
- **THEN** 组包围盒右边界扩展到 110

#### Scenario: use 平移

- **WHEN** `<defs><rect id="r" width="10" height="10"/></defs><use href="#r" x="5" y="6"/>`
- **THEN** `use` 的包围盒为 `(5, 6, 10, 10)`

#### Scenario: image 与定义型元素

- **WHEN** `<image x="1" y="2" width="30" height="40"/>` 与 `<defs/>` 分别调用
- **THEN** 前者返回 `(1, 2, 30, 40)`，后者返回 `None`

### Requirement: M5 元素级 CTM API

`SvgElement` SHALL 提供 `getCTM(): SvgMatrix` 与 `getScreenCTM(viewport!: ?SvgViewportTransform = None): SvgMatrix`。

`getCTM` SHALL 返回元素到根用户空间的矩阵，包含祖先 `transform`、嵌套 `svg` 的视口变换与 `transform-origin`；元素不在文档树中时 SHALL 返回单位矩阵。`getScreenCTM` SHALL 再乘视口矩阵与 `devicePixelRatio`；`viewport` 为 `None` 时 SHALL 由文档根尺寸构造，`devicePixelRatio` 取 1。

既有 `SvgGeometry.ctm(element)` / `screenCTM(element, viewport)` 的行为 SHALL 保持不变；新增的可选计算样式上下文 SHALL 只影响 `transform-origin` 与 `transform-box` 的解析。

#### Scenario: 祖先变换

- **WHEN** `<g transform="translate(10,0)"><rect/></g>` 对 `rect` 调用 `getCTM()`
- **THEN** `(0,0)` 映射到 `(10,0)`

#### Scenario: 屏幕矩阵含 DPR

- **WHEN** 根 `width="100"`、`devicePixelRatio=2`、构造对应视口后调用 `getScreenCTM`
- **THEN** 用户坐标 `(10,10)` 映射到设备坐标 `(20,20)`

#### Scenario: 不在文档树

- **WHEN** 新建 `SvgRect` 且未挂载到任何根，调用 `getCTM()`
- **THEN** 返回单位矩阵

#### Scenario: transform-origin 参与

- **WHEN** 元素 `transform="rotate(90)"`、`transform-origin="50 50"`
- **THEN** `getCTM()` 把 `(50,50)` 映射回自身，与渲染矩阵一致

### Requirement: M5 路径元素级长度 API

`SvgPath` SHALL 提供 `getTotalLength(): Float64` 与 `getPointAtLength(distance: Float64): SvgPoint`。

两者 SHALL 复用 `SvgPathData.totalLength()` 与 `pointAtLength()` 的弧长实现与默认容差；`d` 缺失或为空路径时 `getTotalLength` SHALL 返回 `0`，`getPointAtLength` SHALL 返回 `(0, 0)`。负距离与超过总长的距离 SHALL 分别钳制到起点与终点。

#### Scenario: 直线长度与取点

- **WHEN** `<path d="M0 0 L100 0"/>` 调用 `getTotalLength()` 与 `getPointAtLength(25)`
- **THEN** 分别返回 `100` 与 `(25, 0)`

#### Scenario: 端点钳制

- **WHEN** 同路径调用 `getPointAtLength(-5)` 与 `getPointAtLength(500)`
- **THEN** 分别返回 `(0,0)` 与 `(100,0)`

#### Scenario: 空路径

- **WHEN** `<path/>` 调用两个方法
- **THEN** 返回 `0` 与 `(0,0)`，不抛异常
