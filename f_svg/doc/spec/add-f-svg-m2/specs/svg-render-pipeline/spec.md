# svg-render-pipeline

## ADDED Requirements

### Requirement: 渲染入口

系统 SHALL 提供 `SvgRenderer`（`init(options!)`）、`render(document)`、`render(element, width!, height!)`，以及顶层函数 `renderToPng(document, options!)`。

`render(document)` SHALL 返回 `SvgDocument.root` 对应的 `SvgBitmap`；`render(element, width, height)` SHALL 以给定尺寸渲染任意元素，元素的祖先变换 SHALL 被忽略，仅应用元素自身及其子树的变换。

`renderToPng` SHALL 等价于 `render(document)` 后调用 PNG 编码。

#### Scenario: 渲染文档

- **WHEN** 50×50 根元素含一个红色整幅矩形，使用默认选项
- **THEN** 返回 50×50 位图，中心像素为红色

#### Scenario: 渲染单个元素

- **WHEN** 对 `<g transform="translate(100,100)"><rect width="10" height="10"/></g>` 调用 `render(element, 20, 20)`
- **THEN** 输出 20×20 位图，矩形出现在 `(0,0)` 附近而不是 `(100,100)`

#### Scenario: 直接出 PNG

- **WHEN** `renderToPng(document)`
- **THEN** 返回以 PNG 签名开头的字节数组

### Requirement: 渲染树与计算顺序

渲染 SHALL 按以下顺序执行：计算样式 → 构建渲染树 → 生成显示列表 → 光栅化 → 输出位图。

渲染树 SHALL 在每次渲染时构建，展开 `use`、`clipPath`、`mask`、渐变引用，跳过 `display:none` 的子树；SHALL NOT 修改 `SvgDocument` 或其元素的任何属性。

显示列表 SHALL 为扁平绘制指令，至少包含 `FillPath`、`StrokePath`、`Image`、`Text`，每条指令携带设备矩阵、画笔、透明度与裁剪/蒙版引用。

#### Scenario: display none

- **WHEN** 元素 `style="display:none"`
- **THEN** 该元素及其子树不产生绘制指令

#### Scenario: 不修改文档

- **WHEN** 渲染前后序列化同一 `SvgDocument`
- **THEN** 两次序列化结果完全一致

#### Scenario: 指令顺序

- **WHEN** 文档中先画红矩形再画蓝矩形且两者重叠
- **THEN** 显示列表保持文档顺序，最终重叠处为蓝色

### Requirement: use 展开

`use` SHALL 按 `href` / `xlink:href` 解析同文档片段引用，克隆目标子树并叠加 `x` / `y` 平移。

`use` 引用 `symbol` 时 SHALL 按嵌套视口处理其 `viewBox`；引用缺失或非片段引用 SHALL 跳过并记 warning。

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

### Requirement: 嵌套 svg 视口

嵌套 `<svg>` SHALL 建立新的视口：其 `x` / `y` / `width` / `height` 与 `viewBox` / `preserveAspectRatio` 按 M1 视口算法生成局部矩阵，并与父矩阵累乘。

嵌套视口 SHALL 裁剪到自身 `x` / `y` / `width` / `height` 区域。

#### Scenario: 嵌套缩放

- **WHEN** 根 100×100，内层 `<svg x="10" y="10" width="50" height="50" viewBox="0 0 10 10">` 内画整幅矩形
- **THEN** 内层矩形占设备区域 `(10,10)-(60,60)`

#### Scenario: 嵌套裁剪

- **WHEN** 内层 svg 的子元素超出其视口
- **THEN** 超出的部分不被绘制

### Requirement: image 占位

M2 SHALL NOT 解码 `<image>` 的位图数据。渲染器 SHALL 在 `x` / `y` / `width` / `height` 指定的区域绘制透明占位（若设置了 `background` 则使用背景色），并记一条 warning。

`<image>` SHALL NOT 触发任何网络请求或文件读取。

#### Scenario: 占位矩形

- **WHEN** `<image href="data:image/png;base64,AAAA" x="10" y="10" width="20" height="20"/>`
- **THEN** 该区域保持透明，产生一条包含 `image` 的 warning

#### Scenario: 外部图片不加载

- **WHEN** `<image href="https://example.com/a.png"/>`
- **THEN** 渲染成功，不发起请求，产生 warning

### Requirement: 渲染确定性

在相同输入文档、相同 `SvgRenderOptions` 与相同字体注册表下，重复渲染 SHALL 产生逐字节一致的位图。

渲染 SHALL NOT 依赖系统时间、随机数、环境变量或全局可变状态（字体注册表与选项视为输入）。

#### Scenario: 重复渲染一致

- **WHEN** 对同一文档连续渲染两次
- **THEN** 两次 `pixels` 数组完全相等

#### Scenario: 不同选项独立

- **WHEN** 仅改变 `samplesPerPixel`
- **THEN** 输出可以不同，但各自重复执行仍一致
