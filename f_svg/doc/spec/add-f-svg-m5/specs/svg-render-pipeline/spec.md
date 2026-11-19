# svg-render-pipeline

## ADDED Requirements

### Requirement: M5 paint-order 渲染顺序

渲染树 SHALL 按计算样式 `paint-order` 决定图形元素自身绘制命令的顺序：`fill`、`stroke`、`markers` 三者按给定序列发出，未列出的项 SHALL 按 `fill stroke markers` 的默认相对顺序追加在末尾。

缺省 `fill stroke markers` SHALL 与 M4 的发出顺序逐字节一致。`markers` 在序列中的位置 SHALL 决定 marker 命令相对填充与描边的先后，SHALL NOT 改变 marker 的派生位置、数量或朝向。滤镜、`clip`、`clip-path`、`mask` 与组透明度的处理顺序 SHALL 保持 M4 语义不变。

非法值 SHALL 回退默认顺序并记 warning。

#### Scenario: 描边优先

- **WHEN** 元素同时有填充与描边，`paint-order="stroke fill"`
- **THEN** 显示列表中描边命令先于填充命令，重叠处最终显示填充

#### Scenario: 缺省不变

- **WHEN** 元素未声明 `paint-order`
- **THEN** 命令顺序为填充、描边、marker，与 M4 相同

#### Scenario: marker 位置

- **WHEN** `paint-order="markers fill stroke"`
- **THEN** marker 命令先于填充与描边，marker 数量与位置不变

#### Scenario: 非法值

- **WHEN** `paint-order="shadow fill"`
- **THEN** 使用默认顺序并追加 warning

### Requirement: M5 混合与隔离的合成位置

`mix-blend-mode` SHALL 在元素内容完成滤镜、`clip`、`clip-path`、`mask` 与组透明度之后，作为整组结果与父图层合成；SHALL NOT 对元素内部逐条命令应用混合。

`mix-blend-mode` 非 `normal` 或 `isolation: isolate` 时 SHALL 为该元素建立离屏隔离层；`isolation: isolate` 且混合为 `normal` 时 SHALL 以普通 source-over 合成回父层。隔离层内的子元素 SHALL 只在层内互相混合，不得读取父层像素。M4 的效果应用顺序 SHALL 保持不变。

#### Scenario: 整组混合

- **WHEN** `<g mix-blend-mode="multiply">` 内含两个重叠的半透明矩形
- **THEN** 两个矩形先在隔离层内合成，再以 multiply 与父层合成一次

#### Scenario: isolate 建立隔离

- **WHEN** 子元素 `mix-blend-mode="screen"`，父组 `isolation="isolate"`
- **THEN** 子元素只与父组内已有内容混合，不与组外内容混合

#### Scenario: 顺序不变

- **WHEN** 元素同时有 `filter`、`clip-path` 与 `mix-blend-mode="multiply"`
- **THEN** 先滤镜、再裁剪、最后混合，重复渲染逐字节一致

#### Scenario: 默认不建立层

- **WHEN** `mix-blend-mode="normal"`、`isolation="auto"` 且无其他效果
- **THEN** 不建立额外离屏层，输出与 M4 逐字节一致

### Requirement: M5 transform-origin 与 transform-box

元素的 `transform` SHALL 按 `T(origin) × M × T(-origin)` 应用，其中 `origin` 由 `transform-origin` 与 `transform-box` 共同确定。

`transform-box: view-box` SHALL 以最近视口的用户坐标系为参考，`fill-box` SHALL 以元素几何包围盒为参考。`transform-origin` 的百分比 SHALL 相对参考盒的宽高解析；关键字 `left` / `center` / `right` 映射水平 0% / 50% / 100%，`top` / `center` / `bottom` 映射垂直 0% / 50% / 100%。缺省 `0 0` 与 `view-box` SHALL 保持 M1–M4 的绕原点变换语义。

元素无 `transform` 时原点 SHALL 不影响输出；非法值 SHALL 回退缺省值并记 warning。

#### Scenario: 绕中心旋转

- **WHEN** `transform="rotate(90)"`、`transform-origin="50 50"`，矩形覆盖 `(0,0)-(100,100)`
- **THEN** 旋转后矩形仍覆盖 `(0,0)-(100,100)`

#### Scenario: fill-box 百分比

- **WHEN** 元素包围盒为 `(10,20,40,20)`、`transform-box="fill-box"`、`transform-origin="50% 50%"`
- **THEN** 原点为 `(30, 30)`

#### Scenario: 缺省绕原点

- **WHEN** 元素只声明 `transform="rotate(90)"`
- **THEN** 输出与 M4 绕原点旋转逐字节一致

#### Scenario: 非法原点

- **WHEN** `transform-origin="left middle"`
- **THEN** 回退 `0 0` 并追加 warning

### Requirement: M5 媒体宽度来源

渲染入口 SHALL 把逻辑视口宽度作为 `@media` 宽度查询的比较值：`render(document)` 使用 `SvgRenderOptions.width` 大于 0 时的值，否则使用根元素绝对宽度，再否则使用 300；`render(element, width, height)` 使用传入的 `width`。

该宽度 SHALL 只影响 `@media` 求值，SHALL NOT 改变 `SvgRenderOptions` 的既有字段语义、视口矩阵或输出尺寸。文档不含 `@media` 时输出 SHALL 与 M4 逐字节一致。

#### Scenario: 选项宽度

- **WHEN** `SvgRenderOptions(width: 800)` 且样式表含 `@media (min-width: 600px)`
- **THEN** 媒体查询命中

#### Scenario: 根元素宽度

- **WHEN** 未设置选项宽度、根元素 `width="500"`、查询为 `(min-width: 400px)`
- **THEN** 媒体查询命中

#### Scenario: 默认 300

- **WHEN** 根元素与选项都未提供宽度、查询为 `(min-width: 400px)`
- **THEN** 媒体查询不命中，输出尺寸仍为 300×150

#### Scenario: 单元素渲染

- **WHEN** `render(element, 200, 100)` 且查询为 `(max-width: 250px)`
- **THEN** 媒体查询命中
