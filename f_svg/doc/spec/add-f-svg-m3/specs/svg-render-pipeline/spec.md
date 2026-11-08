# svg-render-pipeline

## REMOVED Requirements

### Requirement: image 占位

**Reason**：M2 规定 `<image>` 只绘制占位、不解码任何位图；M3 增加 data URI 与调用方注入 provider 两条解码路径，该 Requirement 的「不解码」前提不再成立。

**Migration**：默认 `SvgRenderOptions.images = None` 且非 data URI 时仍绘制占位；只有合法 `data:image/png` 或显式注入的 provider 才会产生像素。新增的 `image 绘制` Requirement 取代本条目。

## ADDED Requirements

### Requirement: image 资源解析

系统 SHALL 在渲染 `<image>` 时按下述顺序解析资源：

1. `href` 以 `data:image/png;base64,` 开头且 `allowDataImages` 为真时，内置 base64 解码与 PNG 解码；
2. 其他 `href` 仅在 `SvgRenderOptions.images` 非 `None` 时调用 `SvgImageResourceProvider.resolve(href)`；
3. 资源不可用、解码失败或未注入 provider 时，按 `x` / `y` / `width` / `height` 绘制透明占位，并追加 warning；设置 `SvgRenderOptions.background` 时按 M2 用背景色填充占位。

#### Scenario: data URI

- **WHEN** `<image href="data:image/png;base64,<合法 1×1 红点>" width="10" height="10"/>`
- **THEN** 目标区域中心像素为红色，且无 `image` 占位 warning

#### Scenario: provider 注入

- **WHEN** 注入返回红色 PNG 字节的 `SvgImageResourceProvider`，`href="mem://red"`
- **THEN** 目标区域绘制红色，provider 只被调用一次（同一 href 的多次引用共享缓存）

#### Scenario: 未注入 provider

- **WHEN** `images = None` 且 `href="mem://red"`
- **THEN** 绘制透明占位（设置 `background` 时按 M2 用背景色填充）并追加 warning，不抛异常

### Requirement: image 映射与取样

绘制 SHALL 按 `preserveAspectRatio` 映射到目标矩形：`none` 直接拉伸，`meet` 完整放入，`slice` 填满并裁剪。

取样质量 SHALL 由计算样式 `image-rendering` 决定：`auto` / `optimizeQuality` 使用双线性，`pixelated` / `optimizeSpeed` 使用最近邻；缺省为双线性。

同一 `href` 的解码结果 SHALL 在单次 `render` 内缓存，不重复解码；缓存不得跨 `render` 复用。

`<image>` 的 `opacity`、`clipPath`、`mask`、`filter` SHALL 与其他图形元素一致生效。

#### Scenario: meet 映射

- **WHEN** 100×50 源图绘制到 50×50 目标且 `preserveAspectRatio="xMidYMid meet"`
- **THEN** 图像按 0.5 缩放居中，上下各留 12.5 像素空白

#### Scenario: slice 映射

- **WHEN** 同一源图 `preserveAspectRatio="xMidYMid slice"`
- **THEN** 图像填满目标矩形，左右被裁剪

### Requirement: 渲染树 M3 展开顺序

渲染树 SHALL 在展开元素时按以下顺序处理 M3 效果：

1. 解析 `marker-*` 并派生 marker 实例；
2. 解析 `fill` / `stroke` 的 `pattern` 引用并取样；
3. 渲染元素自身与 marker 子内容；
4. 对元素内容应用 `filter`；
5. 应用 `clipPath`、`mask` 与组透明度。

同一元素同时引用多种效果时，上述顺序 SHALL 固定，不得因遍历顺序变化而改变输出。

效果展开 SHALL NOT 修改 `SvgDocument`；所有派生实例与缓冲只存在于本次渲染。

#### Scenario: 顺序确定

- **WHEN** 同一元素同时带 `filter`、`clipPath` 与 `marker-end`
- **THEN** marker 参与滤镜输入，滤镜结果再被裁剪；重复渲染输出逐字节一致

#### Scenario: 文档只读

- **WHEN** 渲染带 pattern / marker / filter 的文档两次
- **THEN** 渲染前后 `SvgDocument` 的属性、子节点与 warnings 不变

### Requirement: 渲染选项扩展

`SvgRenderOptions` SHALL 新增带默认值的字段：

- `images: ?SvgImageResourceProvider = None`；
- `antiAlias: SvgAntiAliasMode = Supersample`。

既有字段 `width` / `height` / `background` / `samplesPerPixel` / `maxPixels` / `fonts` / `devicePixelRatio` 的名称、类型与默认值 SHALL NOT 改变。

未传入新字段的既有调用 SHALL 编译通过，且输出与 M2 一致；`antiAlias = Analytic` 时 `samplesPerPixel` 不参与覆盖率计算。

#### Scenario: 既有调用不变

- **WHEN** 使用 `SvgRenderOptions(width: 50, height: 50)` 渲染基础形状
- **THEN** 输出与 M2 同参数结果逐字节一致

#### Scenario: 选项校验

- **WHEN** `antiAlias = Analytic` 且 `samplesPerPixel = 1`
- **THEN** 渲染成功，覆盖率使用解析档而非单采样
