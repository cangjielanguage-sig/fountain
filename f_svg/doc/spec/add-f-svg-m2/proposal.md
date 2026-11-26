# add-f-svg-m2

## Why

M1 交付的 `fountain::f_svg` 只解决「把 SVG 文档讲清楚、改对、写回去」：值类型、类型化 DOM、基于 `f_xml` 的解析与生成、安全过滤、结构等价往返。调用方拿到 `SvgDocument` 之后，仍然无法回答三个最基本的问题：

- 这个元素最终**长什么样**（`<style>` 规则、`style=""`、呈现属性、继承与 `currentColor` 谁生效）；
- 它**占多大地方**（形状 / 路径 / 描边 / 变换后的包围盒、`viewBox` 到输出像素的映射）；
- 它**动起来是什么样**（SMIL 动画在某个时间点的取值）。

这三件事散落在业务代码里会重复实现且极易出错；塞进 `f_xml` 又完全不属于 XML 语义。因此 M2 在 M1 模型之上补齐 **CSS 级联与计算样式、几何包围盒与视口、CPU 软件光栅渲染、PNG 输出、SMIL 动画**，让 `f_svg` 从「文档库」变成「可离线出图的 SVG 库」。

M2 是纯增量：只新增公开 API，不修改任何 M1 签名；仍然单包 `fountain::f_svg`，不新增模块，不新增第三方依赖。

## What Changes

按 `f_svg/doc/f_svg-M2设计.md` 的特性清单落地：

- **M2-1 CSS 解析**：`CssStyleSheet` / `CssRule` / `CssSelector` / `CssDeclaration`，支持元素、`.class`、`#id`、`*`、复合、后代、子代、分组与 `!important`；`@media` / `@import` / 伪类 / 属性选择器整条跳过并记 warning。
- **M2-2 级联与计算样式**：`SvgStyleResolver` / `SvgComputedStyle` / `SvgComputedStyleTree`；来源顺序为 UA 默认 < 呈现属性 < `<style>` < 内联 < `!important`，同来源按特异性与源顺序；支持继承、`inherit` / `initial` / `unset`、`currentColor`。
- **M2-3 几何包围盒**：`SvgBounds` / `SvgGeometry`；覆盖七种形状、路径（三次/二次贝塞尔极值、弧的中心参数化与轴向极值、退化段忽略）、描边外扩与斜接修正、变换后轴对齐包围盒。
- **M2-4 视口映射**：`SvgViewport`；`viewBox` 缺省时用户单位等于设备单位，`preserveAspectRatio` 复用 M1 的 `toMatrix`，嵌套 `<svg>` 按祖先矩阵累乘。
- **M2-5 光栅化核心**：`SvgBitmap` / `SvgRasterizer`；RGBA8 非预乘、扫描线 + 边表、`nonzero` / `evenodd`、SSAA 1/2/4（默认 4）、预乘内部 `over` 合成、`maxPixels` 硬上限。
- **M2-6 描边**：`SvgStrokeOutliner`；宽度、`linecap`、`linejoin`、`miterlimit`、`dasharray` / `dashoffset`；矩形 / 圆 / 椭圆走解析轮廓，其余走通用偏移轮廓。
- **M2-7 渐变**：线性 / 径向渐变、`stops`、`spreadMethod`（pad/repeat/reflect）、`gradientTransform`、`gradientUnits`（userSpaceOnUse / objectBoundingBox）、`href` 模板继承；图案留 M3。
- **M2-8 裁剪与蒙版**：`clipPath`（覆盖率蒙版、`clip-rule`、`clipPathUnits`）、`mask`（alpha / luminance、`maskUnits` / `maskContentUnits`）、组透明度与隔离组。
- **M2-9 文本渲染**：`SvgFont` 接口 + `SvgFontRegistry` + 内置 Hershey ASCII 单线字体；`x` / `y` 列表、`dx` / `dy`、`letter-spacing`、`word-spacing`、`text-anchor`、`textLength` + `lengthAdjust`；字形路径与形状共用同一套填充/描边。
- **M2-10 PNG 编码**：`SvgPngEncoder` 与 `SvgBitmap.writePng` / `toPngBytes` / `savePng`；PNG 签名 + `IHDR`（8-bit RGBA）+ `IDAT` + `IEND`，zlib 使用 `stdx.compress.zlib` 的 `DeflateFormat` 并手工包装 zlib 头与 Adler-32，CRC-32 在 `f_svg` 内部实现；同一输入字节级确定。
- **M2-11 SMIL 动画**：`SvgTimeline` / `SvgAnimation` / `SvgClock`；`animate` / `animateTransform` / `animateMotion` / `set`，时间解析（`0s` / `1.5s` / `500ms` / `indefinite` / `id.begin` / `id.end`）、重复、`freeze` / `remove`、线性 / 离散 / 样条插值；采样返回新 `SvgDocument`，不修改原文档。
- **M2-12 渲染入口**：`SvgRenderOptions` / `SvgRenderTree` / `SvgRenderer.render` / `renderToPng`；`use` 展开与循环检测、嵌套 `<svg>`、`<image>` 不解码只占位。
- **M2-13 测试与基准**：几何数值、CSS 级联矩阵、光栅基元像素断言、场景快照（容差 ≤ 1）、动画采样、PNG 结构校验与解压回读、性能基准记录。

**明确不做（M2 边界）**：滤镜与 `feGaussianBlur`、`foreignObject` 内部 XHTML、`<image>` 的 PNG/JPEG 解码、完整 CSS3（伪类、媒体查询、`@font-face`、CSS 动画/过渡）、双向文本与复杂字形整形、内置 CJK 字体、流式序列化、事件驱动动画（`begin="click"`）与脚本、`pattern`、`textPath` 排版、文本 `rotate` 列表。

## Impact

- **Affected specs**：
  - 新增 `svg-css`、`svg-geometry`、`svg-rasterization`、`svg-paint-and-clip`、`svg-text`、`svg-render-pipeline`、`svg-png`、`svg-animation`；
  - 增量修改 `svg-security`（新增渲染期无 I/O、资源上限、递归与规模上限三项 Requirement，不动既有 Requirement）。
- **Affected code**：
  - `f_svg/src/` 新增 CSS、几何、渲染、文本、PNG、动画文件与同名 `*_test.cj`（单包，不建子包）；
  - `f_svg/testdata/render/` 新增六个场景 SVG 与对应 `.rgba` 期望图；
  - 更新 `f_svg/README.md` / `README_en.md`、`f_svg/doc/f_svg-M2设计.md` 的发布说明，修正 `src/f_svg.cj` 包注释中「不渲染、不做 CSS、不做动画」的过时描述；
  - 不改 `f_svg/cjpm.toml` 依赖：`stdx.compress.zlib` 由 stdx 提供，`f_svg` 已配置 `${CANGJIE_STDX_DYNAMIC_PATH}`。
- **不修改**：M1 的 `SvgParser` / `SvgWriter` / 值类型 / 模型 / 安全策略签名；`f_xml`、`f_base` 的任何公开 API；根 `cjpm.toml`、根 `.modules`、聚合根 shim。
- **兼容性**：纯新增；M1 的 216 条用例必须全部保持通过（验收文档中的 216 条为下限）。
- **验收锚点**：`cjpm test` 全绿、`f_svg` 自身 0 warning；CSS 1000 规则 × 1000 元素匹配 ≤ 20 ms；六个场景快照逐像素容差 ≤ 1；PNG 解压回读与位图一致；动画采样不修改原文档。

## Non-goals

- 不做像素级浏览器兼容：不追求与 Chrome/Firefox 逐像素一致，只保证设计文档定义的 SVG 1.1 语义与自有快照稳定。
- 不引入 GPU、FreeType、Skia、Cairo、libpng、libjpeg 或任何 native 依赖。
- 不扩展 `f_xml::XmlWriter` 的流式输出，不实现 SVGZ。
- 不把渲染态字段塞进 `SvgElement`；渲染树与计算样式都是独立快照。
- 不提供字体文件解析（TTF/OTF），字体只能通过 `SvgFont` 外部注入或使用内置 Hershey。
