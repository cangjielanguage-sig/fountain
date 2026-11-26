# add-f-svg-m3

## Why

M1 让 `fountain::f_svg` 能解析、修改、生成 SVG 文档；M2 补齐了 CSS 级联、几何、CPU 光栅、描边、渐变、裁剪蒙版、文本布局、PNG 编码与 SMIL 动画。但 M2 交付的渲染仍是「基础绘图」：没有滤镜、没有图案填充、不会解码位图、不支持 SVGZ，`textPath` 只建模不排版，marker 只作为容器存在，抗锯齿也只有固定超采样一档。

这会让调用方在真实素材前反复卡壳：

- 拿到带 `filter`、`pattern`、`marker` 的 SVG，渲染结果静默丢效果；
- `<image>` 只能画占位，`data:` 图片与调用方自有图片都无法进入渲染；
- 收到 `.svgz` 必须先自己解压，且没有统一的解压上限；
- 文本沿路径排版、逐字旋转需要业务层重算；
- 4× 超采样在大图上成本固定，缺少只算边缘覆盖率的低成本档。

M3 按 `f_svg/doc/f_svg-M3设计.md` 收口 SVG 1.1 的**效果与资源类能力**，让 `f_svg` 在「不联网、不读任意文件、不执行脚本」的前提下，覆盖常见 SVG 1.1 素材的完整渲染链路。M3 只新增公开 API，不改 M1/M2 已有签名，不新增模块或第三方依赖。

## What Changes

- **M3-1 滤镜框架**：`SvgFilter`、滤镜区域（`filterUnits` / `primitiveUnits` / `x` / `y` / `width` / `height`）、`in` / `in2` / `result` 图连接、RGBA8 离屏缓冲链、`SvgFilterRenderer.apply`。
- **M3-2 滤镜原语**：`feGaussianBlur`、`feOffset`、`feFlood`、`feBlend`、`feComposite`、`feMerge`、`feColorMatrix`、`feTile` 八种类型化原语与像素算法。
- **M3-3 图案填充**：`SvgPattern`、`patternUnits` / `patternContentUnits` / `patternTransform`、`href` 继承、平铺取样 `SvgPatternSampler` 与填充区域裁剪。
- **M3-4 PNG 解码**：`SvgPngDecoder` 支持 8-bit 灰度 / 灰度+α / RGB / RGBA / 调色板、1/2/4-bit 展开、filter 0–4、Adam7、逐 chunk CRC 与结构校验。
- **M3-5 `<image>` 绘制**：`data:image/png;base64,` 内置解码、调用方注入 `SvgImageResourceProvider`、`preserveAspectRatio` 的 `meet` / `slice` / `none` 映射、`image-rendering` 两档取样、单次渲染内按 `href` 缓存。
- **M3-6 SVGZ 容器**：`SvgParser.parseAuto` / `parseGzip` 与 `writeGzip`，按 `1F 8B` 魔数识别，解压输出上限防压缩炸弹，固定 mtime 保证字节确定。
- **M3-7 文本路径与 rotate**：`textPath` 沿路径弧长排版、`startOffset`、`text-anchor`、切线旋转；`rotate` 单值 / 列表 / 短列表复用，与 `textPath` 叠加。
- **M3-8 marker**：`SvgMarker` 类型化模型、`marker-start` / `marker-mid` / `marker-end` 顶点派生、`markerUnits`、`orient`、`refX` / `refY`、`viewBox`、溢出裁剪与数量上限。
- **M3-9 解析覆盖率 AA**：新增 `SvgAntiAliasMode.Analytic`，用有符号面积累加求像素覆盖率；默认仍为 M2 的 `Supersample`。
- **M3-10 测试与基准**：滤镜 golden、pattern 平铺、PNG 解码回环、textPath / marker 快照、AA 覆盖率守恒、上限负向用例与性能基准。

## Impact

- **Affected specs**：
  - 新增 `svg-filter`、`svg-marker`；
  - 增量追加 `svg-document-model`（M3 类型化元素、SVGZ 容器）、`svg-value-types`（M3 枚举）、`svg-paint-and-clip`（图案）、`svg-png`（解码）、`svg-render-pipeline`（`<image>` 绘制、展开顺序、选项扩展）、`svg-text`（textPath、rotate）、`svg-rasterization`（解析 AA）、`svg-css`（`image-rendering` 属性）、`svg-security`（M3 资源上限）；
  - `svg-render-pipeline` 的 `image 占位` 与 `svg-security` 的 `渲染期无外部访问` 按 M3 语义改写：默认仍不解码未注入资源，只有 `data:` 与调用方显式注入的 provider 才会产生像素，库内仍无网络与任意文件访问。
- **Affected code**（全部位于 `f_svg/src` 单包，不新建模块或子包）：
  - 新增 `SvgFilter.cj`、`SvgFilterPrimitive.cj`、`SvgFilterRenderer.cj`、`SvgFilterBuffer.cj`、`SvgPattern.cj`、`SvgPatternSampler.cj`、`SvgPngDecoder.cj`、`SvgImageResource.cj`、`SvgGzip.cj`、`SvgTextPathLayout.cj`、`SvgMarker.cj`、`SvgMarkerExpander.cj`、`SvgAnalyticRasterizer.cj` 及对应 `*_test.cj`；
  - 修改 `SvgTag.cj`、`SvgBuilder.cj`、`SvgRenderTree.cj`、`SvgRenderer.cj`、`SvgTextRenderer.cj`、`SvgRasterizer.cj`、`SvgOptions.cj` / `SvgBitmap.cj`（`SvgRenderOptions` 新字段）、`SvgPngEncoder.cj`（复用 CRC 与 zlib 工具）、`SvgComputedStyle.cj`（`image-rendering`）；
  - `f_svg/testdata/render/` 新增滤镜、图案、位图、textPath、marker 场景与期望图；新增损坏 PNG、gzip 炸弹、超大 tile 的负向 fixture；
  - 更新 `f_svg/README.md` / `README_en.md`、`f_svg/doc/perf-baseline.md` 与包注释。
- **不修改**：M1/M2 的值类型、模型、`SvgParser` / `SvgWriter` 既有入口、`SvgRasterizer` 既有方法签名、`SvgRenderOptions` 既有字段语义；`f_xml` / `f_base` 公开 API；根 `cjpm.toml`、`.modules`、聚合根 shim；`f_svg/cjpm.toml` 不新增依赖。
- **兼容性**：现有 `cjpm test` 实测 348 条用例（348 个 `@TestCase`，另有 53 个 `@Test` 类标注），与 M2 归档一致，必须零回归。`SvgRenderOptions` 只新增带默认值字段，默认 `antiAlias = Supersample`、`images = None`，未注入资源时 `<image>` 仍按 M2 画占位。唯一可观察变化是合法 `data:image/png` 会被解码绘制。
- **验收锚点**：`cjpm test` 全绿、`f_svg` 自身 0 warning；PNG 解码回环、滤镜 golden、textPath / marker 快照、AA 覆盖率守恒四类断言全部通过；所有上限均有负向用例；同一文档 + 同一选项 + 同一 provider 输出逐字节确定。

## Non-goals

- 不做 JPEG / WebP / GIF 解码；需要时由调用方实现 `SvgImageResourceProvider` 并返回自行解码后的位图。
- 不做 `foreignObject` 内部 XHTML 语义。
- 不扩展 SMIL：不做 `animateColor`、事件驱动动画与脚本。
- 不做 `feImage` 外部图像原语。
- 不解析 TTF/OTF 字体，不内置 CJK 字体。
- 不做 GPU / native 光栅后端，不引入 libpng / libjpeg / Skia / Cairo / FreeType。
- 不改 `f_xml::XmlWriter` 为流式输出，不做超出 `parseAuto` / `parseGzip` / `writeGzip` 的容器能力。
- 不追求与浏览器逐像素一致；以设计文档定义的 SVG 1.1 语义与自有快照为准。
