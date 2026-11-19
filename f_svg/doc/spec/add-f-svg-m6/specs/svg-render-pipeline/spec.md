# svg-render-pipeline

## MODIFIED Requirements

### Requirement: 渲染选项扩展

`SvgRenderOptions` SHALL 新增带默认值的字段：

- `images: ?SvgImageResourceProvider = None`；
- `antiAlias: SvgAntiAliasMode = Supersample`；
- `hoveredIds: Array<String> = []`；
- `focusedIds: Array<String> = []`；
- `initialView: ?String = None`；
- `foreignObjectRenderer: ?SvgForeignObjectRenderer = None`；
- `externalDocuments: ?SvgExternalDocumentProvider = None`；
- `viewState: ?SvgViewState = None`。

既有字段 `width` / `height` / `background` / `samplesPerPixel` / `maxPixels` / `fonts` / `devicePixelRatio` 的名称、类型与默认值 SHALL NOT 改变。

未传入新字段的既有调用 SHALL 编译通过，且输出与 M5 一致；`antiAlias = Analytic` 时 `samplesPerPixel` 不参与覆盖率计算。`hoveredIds` / `focusedIds` SHALL 只影响选择器求值，`viewState` SHALL 只影响根矩阵。

#### Scenario: 既有调用不变

- **WHEN** 使用 `SvgRenderOptions(width: 50, height: 50)` 渲染基础形状
- **THEN** 输出与 M5 同参数结果逐字节一致

#### Scenario: 选项校验

- **WHEN** `antiAlias = Analytic` 且 `samplesPerPixel = 1`
- **THEN** 渲染成功，覆盖率使用解析档而非单采样

#### Scenario: 空交互集合

- **WHEN** 不传 `hoveredIds` / `focusedIds`
- **THEN** 交互伪类不匹配任何元素，输出与 M5 逐字节一致

### Requirement: use 展开

`use` SHALL 按 `href` / `xlink:href` 解析同文档片段引用，克隆目标子树并叠加 `x` / `y` 平移。

`use` 引用 `symbol` 时 SHALL 按嵌套视口处理其 `viewBox`；引用缺失或非片段引用 SHALL 跳过并记 warning。

当 `SvgRenderOptions.externalDocuments` 非空时，指向外部文档的 `href` SHALL 交由该 provider 解析为 SVG 字节并按 `use` 规则实例化；`href` 中的片段 SHALL 在外部文档内按 id 定位，无片段时使用外部文档根。外部文档单文档字节上限 16 MiB，超限 SHALL 抛 `Limit`。外部文档内部的外部引用 SHALL NOT 再次触发 provider（不递归加载），遇到时跳过并 warning；同一 `href` 在一次渲染内 provider SHALL 只被调用一次。未提供 provider 时外部引用 SHALL 跳过并 warning。

循环引用 SHALL 在深度 64 处终止并记 warning，不得栈溢出。

#### Scenario: 基本复用

- **WHEN** `<defs><rect id="r" width="10" height="10"/></defs><use href="#r" x="5" y="6"/>`
- **THEN** 在 `(5,6)` 处绘制 10×10 矩形

#### Scenario: 引用 symbol

- **WHEN** `use` 引用带 `viewBox` 的 `symbol`，`use` 自身有 `width` / `height`
- **THEN** 内容按 symbol 的 `viewBox` 缩放到 `use` 的尺寸

#### Scenario: 循环引用

- **WHEN** `<g id="a"><use href="#a"/></g>`
- **THEN** 渲染在深度 64 处停止，产生 warning，不崩溃

#### Scenario: 外部文档

- **WHEN** `use href="icons.svg#star"`，provider 返回含该 id 的文档
- **THEN** provider 被调用一次，实例内容按 `use` 规则绘制

#### Scenario: 外部文档缺 provider

- **WHEN** `use href="icons.svg#star"` 且未提供 provider
- **THEN** 跳过该 `use` 并 warning，不联网、不读文件

#### Scenario: 外部文档上限

- **WHEN** provider 返回超过 16 MiB 的字节
- **THEN** 抛 `Limit`

#### Scenario: 外部文档不递归

- **WHEN** provider 返回的文档内部再声明 `use href="other.svg#x"`
- **THEN** provider 只被调用一次，第二层外部引用被跳过并 warning，不抛 `Limit`

### Requirement: view 不参与默认渲染

`view` 元素 SHALL NOT 直接产生绘制指令，也 SHALL NOT 改变 `render(document)` 的默认视口；只有显式传入 `SvgRenderOptions.initialView` 时才参与视口覆盖。

`render(element, width, height)` 对 `view` 元素 SHALL 返回空画布，不抛异常。

#### Scenario: 默认渲染不变

- **WHEN** 文档含带 `viewBox` 的 `view` 元素但根元素未引用它
- **THEN** 渲染输出与删除该 `view` 后逐字节一致

#### Scenario: 单独渲染 view

- **WHEN** `render(viewElement, 10, 10)`
- **THEN** 返回 10×10 全透明位图

## ADDED Requirements

### Requirement: M6 初始视图片段导航

`SvgRenderOptions.initialView` SHALL 接受 `#id` 或 `id`。命中 `view` 时，系统 SHALL 用该 `view` 的 `viewBox` 与 `preserveAspectRatio` 覆盖根视口矩阵；未命中、无 `viewBox` 或 id 为空时 SHALL warning 并保持根视口。`viewTarget` SHALL NOT 参与渲染。

#### Scenario: 命中 view

- **WHEN** 根 `viewBox="0 0 100 100"`，文档含 `<view id="v" viewBox="10 10 20 20"/>`，`initialView="#v"`
- **THEN** 输出只显示 `(10,10)-(30,30)` 区域，尺寸仍取 `options.width` / `height`

#### Scenario: 不带井号

- **WHEN** `initialView="v"`
- **THEN** 与 `initialView="#v"` 输出逐字节一致

#### Scenario: 未命中

- **WHEN** `initialView="#missing"`
- **THEN** 视口保持根 `viewBox`，`warnings` 含该 id

#### Scenario: 缺省

- **WHEN** `initialView = None`
- **THEN** 输出与 M5 逐字节一致

### Requirement: M6 foreignObject 注入渲染

系统 SHALL 提供 `SvgForeignObjectRenderer` 接口，方法为 `render(element, width, height, options)` 返回 `?SvgBitmap`。`foreignObject` 有 `x` / `y` / `width` / `height` 时 SHALL 把返回位图缩放到该矩形绘制；未提供 renderer 或返回 `None` 时 SHALL 绘制透明占位并 warning。系统 SHALL NOT 解析 XHTML，也不对渲染结果做安全审查。

#### Scenario: 注入位图

- **WHEN** renderer 返回 2×2 红色位图，`foreignObject` 为 `0 0 10 10`
- **THEN** 目标矩形被红色填满，无 warning

#### Scenario: 缺 renderer

- **WHEN** 未提供 renderer
- **THEN** 目标矩形透明，`warnings` 含 `foreignObject`

#### Scenario: renderer 返回空

- **WHEN** renderer 返回 `None`
- **THEN** 绘制透明占位并 warning

#### Scenario: 缺少尺寸

- **WHEN** `foreignObject` 缺少 `width` 或 `height`
- **THEN** 跳过该元素并 warning，不调用 renderer

#### Scenario: 不解析 XHTML

- **WHEN** `foreignObject` 内含 `<div xmlns="http://www.w3.org/1999/xhtml">`
- **THEN** 该子节点不产生任何绘制指令

### Requirement: M6 交互状态贯通

渲染树构建 SHALL 把 `SvgRenderOptions.hoveredIds` / `focusedIds` 传入样式计算，使 `:hover` / `:focus` 规则与普通规则走同一级联。命中查询与 `getBBox` 的样式计算 SHALL 使用同一交互状态入口；未显式传入时为空状态。

#### Scenario: hover 改变填充

- **WHEN** 样式 `rect:hover { fill: red }`，矩形原 `fill="blue"`，`hoveredIds=["r"]`
- **THEN** 渲染为红色；不传集合时为蓝色

#### Scenario: 级联优先级

- **WHEN** `:hover` 规则与普通规则同时命中，特异性相同
- **THEN** 后出现的规则胜出，与普通级联一致

#### Scenario: 非交互文档不变

- **WHEN** 文档不含交互伪类
- **THEN** 传与不传集合的输出逐字节一致

### Requirement: M6 视图状态

`SvgRenderOptions.viewState` 非空时，系统 SHALL 在根视口矩阵之后叠加 `translate(currentTranslate) × scale(currentScale)`。位图尺寸 SHALL 仍由 `width` / `height` / DPR 决定，SHALL NOT 随 `currentScale` 改变。

#### Scenario: 缩放

- **WHEN** `currentScale = 2`，其余缺省
- **THEN** 内容以画布左上角为原点放大两倍

#### Scenario: 平移

- **WHEN** `currentTranslate = (10, 20)`
- **THEN** 内容整体右下移动 `(10, 20)`

#### Scenario: 缺省

- **WHEN** `viewState = None`
- **THEN** 输出与 M5 逐字节一致

### Requirement: M6 自动尺寸

根 `svg` 显式声明 `width="auto"` 或 `height="auto"` 时，系统 SHALL 按内容包围盒与 `viewBox` 比例确定该轴尺寸；嵌套 `svg` 显式 `auto` 时 SHALL 取父视口对应轴的 100%。尺寸无法确定时 SHALL warning 并回退既有缺省。未声明 `auto` 的文档 SHALL 保持 M5 尺寸推导。

#### Scenario: 根自动宽度

- **WHEN** 根 `width="auto"`、`height="100"`、`viewBox="0 0 200 100"`，内容包围盒宽 200
- **THEN** 输出宽度按 `viewBox` 比例推导，高度 100

#### Scenario: 嵌套自动尺寸

- **WHEN** 嵌套 `<svg width="auto" height="auto">`，父视口 300×150
- **THEN** 嵌套视口为 300×150

#### Scenario: 无法确定

- **WHEN** 根两轴均为 `auto` 且无 `viewBox` 与可渲染内容
- **THEN** 回退缺省尺寸并 warning

#### Scenario: 未声明 auto

- **WHEN** 根未写 `width` / `height`
- **THEN** 尺寸推导与 M5 一致，不产生新 warning

### Requirement: M6 矢量效果的矩阵应用

渲染树 SHALL 在元素有效变换（含 `transform-origin`）之后应用 `vector-effect` 的几何修正，再与父矩阵累乘。`non-scaling-stroke` SHALL 保持既有描边路径，不与三个新值互相改写。

#### Scenario: 应用顺序

- **WHEN** 元素同时有 `transform="rotate(30)"`、`transform-origin="10 10"` 与 `vector-effect="non-rotation"`
- **THEN** 先按原点应用变换，再去旋转，结果与手算矩阵一致

#### Scenario: 父子累乘

- **WHEN** 父矩阵含 `scale(2)`，子元素 `non-scaling-size`
- **THEN** 子元素几何不继承缩放，平移仍继承

#### Scenario: 既有描边

- **WHEN** `vector-effect="non-scaling-stroke"`
- **THEN** 描边宽度处理与 M4 逐字节一致
