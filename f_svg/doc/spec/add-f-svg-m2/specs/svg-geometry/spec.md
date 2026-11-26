# svg-geometry

## ADDED Requirements

### Requirement: 包围盒代数

系统 SHALL 提供 `SvgBounds`（`x` / `y` / `width` / `height`），并支持 `empty()`、`isEmpty()`、`union(that)`、`intersect(that)`、`transform(matrix)`、`inflate(amount)`。

`empty()` SHALL 用负尺寸哨兵表示空包围盒，`isEmpty()` 仅在宽或高为负时为真；宽或高为 0 的退化盒（点、水平线、垂直线）是合法几何，参与 `union` 时 SHALL 保留而不是被忽略。

`inflate(amount)` SHALL 向四周扩展 `amount`；负值 SHALL 收缩并把宽高钳制到 0，不产生负宽高；空盒扩展后仍为空。`intersect` 无交集时 SHALL 返回 `empty()`。

`transform(matrix)` SHALL 变换包围盒四角并取轴对齐包围盒；允许结果比真实几何包围盒更保守，但不得漏掉任何被变换后的点。

#### Scenario: 并集与空盒

- **WHEN** `SvgBounds.empty().union(SvgBounds(0, 0, 10, 20))`
- **THEN** 结果为 `(0, 0, 10, 20)`

#### Scenario: 退化盒参与并集

- **WHEN** `SvgBounds(5, 5, 0, 0).union(SvgBounds(10, 10, 4, 4))`
- **THEN** 结果为 `(5, 5, 9, 9)`，点没有被丢弃

#### Scenario: 相交为空

- **WHEN** 相交 `(0,0,10,10)` 与 `(20,20,5,5)`
- **THEN** `isEmpty()` 为真

#### Scenario: 绕中心旋转 45 度

- **WHEN** 对 `(0, 0, 2, 2)` 应用 `SvgMatrix.rotateAround(45, 1, 1)`
- **THEN** 结果宽高均约为 `2√2`，中心仍为 `(1, 1)`

#### Scenario: 扩展描边

- **WHEN** `SvgBounds(10, 10, 20, 20).inflate(2)`
- **THEN** 结果为 `(8, 8, 24, 24)`

### Requirement: 基本形状包围盒

系统 SHALL 提供 `SvgGeometry.bounds(element, style!)`，返回元素自身坐标系中的几何包围盒（不含描边）；不支持的或不可渲染的元素 SHALL 返回 `None`。

各形状规则 SHALL 为：

- `rect`：`x` / `y` / `width` / `height`，负宽高按 `InvalidValue` 语义忽略并返回 `None`；
- `circle`：`(cx-r, cy-r, 2r, 2r)`；
- `ellipse`：`(cx-rx, cy-ry, 2rx, 2ry)`；
- `line`：两端点构成的包围盒；
- `polyline` / `polygon`：所有点的包围盒，少于 1 个点返回 `None`；
- `path`：按路径段累加。

#### Scenario: 矩形与圆

- **WHEN** `rect(x=10,y=20,width=30,height=40)` 与 `circle(cx=50,cy=50,r=5)`
- **THEN** 包围盒分别为 `(10,20,30,40)` 与 `(45,45,10,10)`

#### Scenario: 负数尺寸

- **WHEN** `rect` 的 `width` 为 `-10`
- **THEN** `bounds` 返回 `None`

#### Scenario: 折线单点

- **WHEN** `polyline` 只有一个点 `(5, 5)`
- **THEN** 返回 `(5, 5, 0, 0)`，`isEmpty()` 为假（零尺寸点仍是合法几何）

### Requirement: 路径包围盒

路径包围盒 SHALL 覆盖全部路径命令：

- `M` / `L` / `H` / `V` / `Z`：取端点与子路径起点；
- 三次贝塞尔 `C` / `S`：对每个坐标分量求导数零点，把区间内的极值点与端点纳入；
- 二次贝塞尔 `Q` / `T`：按解析极值 `t = (p0 - p1) / (p0 - 2p1 + p2)` 求极值；
- 弧 `A`：端点参数转中心参数，按扫描角范围纳入四个轴向极值点与端点。

退化段 SHALL 被忽略而不是让整个包围盒失效：零长度段、`rx` 或 `ry` 为 0 的弧（按直线处理）、`NaN` / 无穷参数。

#### Scenario: 三次贝塞尔同侧控制点

- **WHEN** `M0 0 C0 10 10 10 10 0`
- **THEN** 包围盒高度约为 `7.5`（`y` 极值在 `t = 0.5`），不是 `10`

#### Scenario: 二次贝塞尔极值

- **WHEN** `M0 0 Q10 20 20 0`
- **THEN** 包围盒 `y` 最大值为 `10`

#### Scenario: 半圆弧

- **WHEN** `M0 0 A10 10 0 0 1 20 0`（`sweep=1`，y 轴向下）
- **THEN** 包围盒为 `(0, -10, 20, 10)`

#### Scenario: 大弧与小弧

- **WHEN** 同一端点参数分别使用 `largeArc=false` 与 `largeArc=true`
- **THEN** 两者包围盒不同，且都包含各自弧段真实经过的轴向极值

#### Scenario: 退化段

- **WHEN** `M0 0 L0 0 A0 5 0 0 1 10 10`
- **THEN** 包围盒为 `(0, 0, 10, 10)`，不抛异常

### Requirement: 描边包围盒

`SvgGeometry.strokeBounds(element, style!)` SHALL 在几何包围盒基础上外扩 `strokeWidth / 2`。

当 `stroke` 为 `None` 或 `strokeWidth <= 0` 时，结果 SHALL 等于 `bounds`。

斜接（`linejoin=miter`）且实际斜接长度超过 `miterlimit × strokeWidth/2` 时，外扩量 SHALL 按 `miterlimit × strokeWidth/2` 截断；`round` 与 `bevel` 按 `strokeWidth/2` 外扩。

#### Scenario: 普通描边

- **WHEN** 几何盒 `(10,10,20,20)`，`stroke-width=4`
- **THEN** 描边盒为 `(8,8,24,24)`

#### Scenario: 无描边

- **WHEN** `stroke` 为 `none`
- **THEN** 描边盒等于几何盒

#### Scenario: miterlimit 截断

- **WHEN** 尖角路径、`stroke-width=10`、`miterlimit=2`
- **THEN** 外扩量不超过 `10`

### Requirement: 文本包围盒

`SvgGeometry.bounds` 对 `text` / `tspan` SHALL 通过 `SvgFontRegistry` 解析字体，按 `glyphBounds` 与布局累加得到包围盒。

未注册任何可用字体或字体没有该字符时，SHALL 返回 `None`，不抛异常。

#### Scenario: 有字体提供者

- **WHEN** 注册一个每字符 advance 为 10、高 8 的测试字体，渲染 `text` 内容 `"AB"`、字号 10
- **THEN** 包围盒宽度为 `20`，高度为 `8`

#### Scenario: 无字体提供者

- **WHEN** 未注册字体且请求文本包围盒
- **THEN** 返回 `None`

### Requirement: 绝对包围盒

`SvgGeometry.absoluteBounds(element, style!)` SHALL 把元素自身变换与所有祖先 `transform` 依次合成，再对几何包围盒应用合成矩阵。

祖先链 SHALL 按文档树从根到叶的顺序合成：`M_total = M_root × ... × M_parent × M_element`。

#### Scenario: 祖先变换累乘

- **WHEN** 根下 `<g transform="translate(10,0)"><rect transform="scale(2)" x="0" y="0" width="5" height="5"/></g>`
- **THEN** 绝对包围盒为 `(10, 0, 10, 10)`

#### Scenario: 无变换

- **WHEN** 元素及祖先都没有 `transform`
- **THEN** 绝对包围盒等于自身坐标系包围盒

### Requirement: 视口映射

系统 SHALL 提供 `SvgViewport`，包含 `width` / `height`、`from(root, fallbackWidth, fallbackHeight)` 与 `transform(root)`。

`viewBox` 缺省时 `transform` SHALL 返回 `SvgMatrix.identity`；存在 `viewBox` 时 SHALL 使用 M1 的 `SvgPreserveAspectRatio.toMatrix(viewBox, width, height)`（缺省 `xMidYMid meet`）。

`SvgViewport.from` SHALL 优先使用根元素的绝对长度 `width` / `height`，缺省或百分比无法解析时使用 `fallbackWidth` / `fallbackHeight`；两者都 ≤ 0 时 SHALL 抛 `SvgException(kind: InvalidValue)`。

嵌套 `<svg>` 的视口 SHALL 按 `父视口矩阵 × 自身 viewBox 矩阵 × x/y 平移` 累乘。

#### Scenario: 无 viewBox

- **WHEN** 根元素没有 `viewBox`
- **THEN** `transform(root)` 为 `SvgMatrix.identity`

#### Scenario: meet 映射

- **WHEN** `viewBox="0 0 100 50"`、视口 `200×200`、`preserveAspectRatio` 缺省
- **THEN** 缩放为 `2`，内容垂直居中，`y` 平移为 `50`

#### Scenario: none 拉伸

- **WHEN** `preserveAspectRatio="none"`、`viewBox="0 0 100 50"`、视口 `200×200`
- **THEN** x 缩放为 `2`、y 缩放为 `4`

#### Scenario: 嵌套 svg

- **WHEN** 外层 `viewBox="0 0 100 100"` 映射到 `200×200`，内层 `<svg x="10" y="20" viewBox="0 0 10 10" width="10" height="10">`
- **THEN** 内层用户坐标经「外层 × 内层」矩阵后落在设备坐标 `(20, 40)` 起点的 `20×20` 区域

### Requirement: 几何性能基准

1000 段路径的 `SvgGeometry.bounds` SHALL 在参考环境中 ≤ 2 ms（单次、`-O2`）。

该指标为参考目标、非 CI 门禁；未达标时用例仍可通过，但必须在 `f_svg/doc/perf-baseline.md` 记录实测值与差距。

#### Scenario: 千段路径

- **WHEN** 构造 1000 段直线与贝塞尔混合路径并调用 `bounds`
- **THEN** 实测耗时被记录，且不超过 2 ms 或已写入差距

