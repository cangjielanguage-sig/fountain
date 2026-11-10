# 设计：f_svg（M4）

## Context

M1–M3 已交付的模型与渲染事实（实施前已核对源码）：

- `SvgTag.create` / `isKnown` 是标签到模型的唯一映射入口（`f_svg/src/SvgTag.cj:24`）；`view` 与 M4 的 15 个新 `fe*` 标签当前不在表内，会落入宽松模式的 `SvgUnknownElement`。
- `SvgBuilder` 按 `SvgTag` 构建元素并在解析期执行安全策略（`f_svg/src/SvgBuilder.cj:139`）；新增标签只需扩展 `SvgTag` 与构建器校验，不触碰 `f_xml`。
- 属性级联由 `SvgPropertySpec` 表驱动（`f_svg/src/SvgComputedStyle.cj:76`），值归一化集中在 `SvgStyleResolver.normalizeValue`（`f_svg/src/SvgStyleResolver.cj:356`）；M4 属性必须进入该表，才能同时支持呈现属性、`<style>` 与内联样式。
- 渲染链路为 `SvgRenderTreeBuilder` → `SvgDisplayCommand` → `SvgRenderer`（`f_svg/src/SvgRenderTree.cj:191`、`f_svg/src/SvgRenderer.cj:185`）；显示指令已有 `clipRect`（轴对齐视口矩形）与 `clipPath` 两条裁剪通路。
- 嵌套 `<svg>` 当前**无条件**裁剪到视口（`f_svg/src/SvgRenderTree.cj:472`）；`use` 引用带 `viewBox` 的 `symbol` 也会无条件裁剪（`f_svg/src/SvgRenderTree.cj:541`）；`pattern` 内容因 tile 位图尺寸天然被裁剪；`marker` 内容当前**不裁剪**（`f_svg/src/SvgMarkerExpander.cj:330`）。`clip` / `overflow` / `vector-effect` 属性均不存在。
- 滤镜链在 `SvgFilterRenderer.apply` 内按 `SvgFilterBuffer` 逐原语执行（`f_svg/src/SvgFilterRenderer.cj:84`），新原语只需扩展 `runPrimitive` 分派并复用缓冲与 `primitiveScale` 换算。
- 文本布局由 `SvgTextRenderer.layout` 按字符 advance 生成字形位置（`f_svg/src/SvgTextRenderer.cj:143`）；`SvgTextPathLayout.place` 已有独立的弧长采样（`f_svg/src/SvgTextPathLayout.cj:77`）；`SvgFont` 只暴露 `glyphPath` / `advance` / `ascent` / `descent` / `glyphBounds`（`f_svg/src/SvgFont.cj:26`），没有字体文件解析。
- `SvgPathData` 只提供解析、绝对化与序列化（`f_svg/src/SvgPathData.cj:161`），没有长度或取点 API；`SvgGeometry` 只有 `bounds` / `strokeBounds` / `absoluteBounds`（`f_svg/src/SvgGeometry.cj:31`）。
- `SvgViewport` 已封装根视口与嵌套视口变换（`f_svg/src/SvgViewport.cj:24`），`SvgPreserveAspectRatio.toMatrix` 已覆盖 meet / slice / none（`f_svg/src/SvgPreserveAspectRatio.cj:126`），M4 直接复用，不实现第二套映射。
- `SvgImageResource` 已有 `data:image/png;base64,` 解码、provider 注入、单次渲染缓存与 `SvgDecodeBudget`（`f_svg/src/SvgImageResource.cj`、`f_svg/src/SvgPngDecoder.cj:30`），`feImage` 复用同一预算。
- 源码现有 533 个 `@TestCase` 与 67 个 `@Test` 类标注，M1–M3 快照 6 个 M1/M2 场景 + 5 个 M3 场景。

M4 缺的是「保真、排版、查询」：裁剪与描边语义、7 类滤镜原语、pattern 视口、基线 / 装饰 / 竖排 / textPath 选项、TrueType、`view` / `switch` / `anchors` / 路径长度 / CTM。约束是**只增不改**公开 API 语义、单包、默认输出稳定。

## Goals / Non-Goals

**Goals**

1. 所有 M4 行为都通过「计算样式 → 渲染树 → 显示指令」既有链路生效，不引入旁路属性表。
2. 像素/几何语义确定性：同一文档、选项与字体注册表多次渲染逐字节一致。
3. 复用既有基础设施：`SvgCoverageMask`、`SvgFilterBuffer`、`SvgImageResource` / `SvgDecodeBudget`、`SvgViewport`、`SvgPreserveAspectRatio`、`SvgPatternSampler` 缓存与 `SvgRenderGuard`。
4. 路径弧长只有一份实现，`textPath` 与 `totalLength` / `pointAtLength` 共用。
5. 默认输出稳定：未声明 M4 属性的文档与 M3 逐字节一致；`SvgRenderOptions` 只加 `languages`。

**Non-Goals**

- 不实现片段导航（`url(#view)`）、链接激活、事件、脚本。
- 不做 CFF/OTF 轮廓、字体整形、GSUB/GPOS/kern、双向文本。
- 不做 pattern「跨 tile 溢出」的无限内容绘制（tile 即采样周期，见 D3）。
- 不做 GPU、新依赖、新模块或子包。

## 架构

```
                    SvgDocument（只读）
                          │
                 SvgRenderTreeBuilder
        ┌─────────────┬───┴────────────┬──────────────┐
   switch 求值    overflow/clip    条件样式/基线       marker/pattern
        │             │              │                 │
        └─────────────┴──────┬───────┴─────────────────┘
                             │
                     SvgDisplayCommand
        （FillPath / StrokePath / Image / Text / Group
          + clip / clipPath / clipRect / overflow / vector-effect）
                             │
                      SvgRenderer
        ┌────────────┬───────┴────────┬───────────────┐
  SvgClipCoverage  SvgStrokeOutliner  SvgFilterRenderer  SvgTextRenderer
  （clip 覆盖率）   （vector-effect）  （11 类原语+光照） （基线/装饰/竖排）
```

- `clip` 走覆盖率蒙版（可旋转），`clipRect` 继续承担轴对齐视口裁剪，两者不合并。
- 所有派生数据只存在于本次渲染；`SvgDocument` 不被修改。

## Decisions

### D1. M4 属性进入既有级联表，而不是新增渲染期解析

在 `SVG_PROPERTY_TABLE` 注册 `clip` / `overflow` / `vector-effect` / `dominant-baseline` / `alignment-baseline` / `baseline-shift` / `text-decoration` / `writing-mode`，并在 `normalizeValue` 增加归一化分支。

- 继承性按 spec：`dominant-baseline` / `alignment-baseline` / `baseline-shift` / `writing-mode` 可继承；`clip` / `overflow` / `vector-effect` / `text-decoration` 不可继承。
- `overflow` 的初始值取 `hidden`。SVG 1.1 对 viewport 元素使用 UA 样式表给 `hidden`，本模块只对 viewport 类元素消费该属性，因此把初始值直接定为 `hidden` 比「初始 visible + 元素类型补丁」更简单且无歧义。
- `text-decoration` 不继承，但渲染阶段从最近的声明祖先向下传播（SVG 语义）；传播在样式快照之外完成，避免改变级联结果。

**替代方案**：只在渲染树读原始属性。被否：内联样式与 `<style>` 不生效，且与 M2 起的 CSS 契约冲突。

### D2. `clip` 用覆盖率蒙版，不用轴对齐 bounds

`clip: rect(t, r, b, l)` 的四个分量允许 `auto`，且矩形随元素 CTM 旋转，不能用轴对齐 `SvgBounds` 表达。

实现：

1. `SvgClipProperty.parse` 产出 `SvgClipRect`（四边 `?Float64`），非法值返回 `None` 并 warning；
2. 渲染树把 `SvgClipRect` 放进 `SvgDisplayCommand.clip`；
3. `SvgClipCoverage.render(clip, ctm, width, height, samples)` 用四个角构造路径，复用 `SvgRasterizer` 的填充覆盖率得到 8-bit 蒙版；
4. 渲染器在 `filter` 之后、`clipPath` 之前乘到像素覆盖率上。

与 `clip-path` 共存时「先 clip 后 clip-path」由固定应用顺序保证，与声明顺序无关。仅对已渲染内容生效，不影响几何包围盒。

### D3. `overflow` 按元素类型决定裁剪，marker 新增视口裁剪

- 嵌套 `<svg>` / `symbol`：保留现有视口矩阵计算，仅在计算样式 `overflow != visible` 时把 `clipRect` 传给子树；`visible` 时不传。
- `marker`：`SvgMarkerExpander` 在派生实例时按 `markerWidth × markerHeight`（缺省 3×3）构造内容空间矩形，经实例矩阵转到设备空间后作为 `clipRect`；`visible` 时不加。这是 M4 唯一会改变既有输出的点：只有内容越出 marker 视口的文档受影响，M1–M3 的 6 个场景与 5 个 M3 快照均不越界，快照保持逐字节一致。
- `pattern`：tile 位图即采样周期，内容在 tile 外无法定义。`overflow="hidden"`（缺省）与 M3 一致；`overflow="visible"` 仍以 tile 边界取样，不向相邻 tile 扩展，并在文档中声明该限制。这样既不引入非周期采样，也不改变默认输出。
- `overflow` 对普通图形/文本/组不产生裁剪（与 CSS 的 viewport 语义一致）。

**替代方案**：为 pattern 渲染带 padding 的 tile 或在填充区逐 tile 绘制。前者会在 tile 周期内读到 padding，后者成本与填充面积线性相关；都不适合 M4 的确定性目标。

### D4. `vector-effect` 在渲染树换算，不改描边器

显示指令增加 `nonScalingStroke: Bool`。渲染树在生成 `StrokePath` 时，若计算样式为 `non-scaling-stroke`：

- 有效 `stroke-width = stroke-width / sqrt(|det(CTM)|)`；
- `stroke-dasharray` 与 `stroke-dashoffset` 各分量除以同一系数；
- 行列式为 0 或不可逆时按 `none` 并 warning。

`SvgStrokeOutliner` 继续只吃用户空间宽度，所有 join / cap / dash 逻辑不变。**替代方案**：让描边器感知设备矩阵。被否：会波及大量既有快速路径与快照。

### D5. 新滤镜原语按「统一缓冲 + 逐原语纯函数」实现

- `SvgFilterPrimitives2.cj` 实现 `feComponentTransfer`（含 `SvgFeFunc*`）、`feMorphology`、`feConvolveMatrix`、`feTurbulence`、`feDisplacementMap`、`feImage`；
- `SvgFilterLighting.cj` 实现 `feDiffuseLighting` / `feSpecularLighting` 与三种光源；
- `SvgFilterRenderer.runPrimitive` 增加 7 个分派；每个原语输入一个 `SvgFilterBuffer`，输出新缓冲，不原地读写；
- 长度类参数（`radius`、`surfaceScale`、`scale`）用既有 `primitiveScaleX/Y` 换算到设备像素；`baseFrequency` 反向换算为用户空间频率；
- 湍流用整数哈希梯度表 + 固定遍历顺序，`seed` 只改变哈希种子，保证跨平台确定性；振幅按倍频归一；
- 卷积按 `edgeMode` 取边界样本，`divisor` 缺省为核和（0 时取 1），`bias` 加在归一化通道上；
- 光照由 alpha 的中心差分求法线，diffuse 为 `color × kd × max(N·L, 0) × alpha`，specular 为 `color × ks × max(N·H, 0)^exp × alpha`，alpha 透传；
- `feImage` 复用 `SvgImageResource`（同一实例、同一 `SvgDecodeBudget`），按 `preserveAspectRatio` 映射到滤镜区域。

原语参数非法时按 spec 的「直通或透明」语义降级；`Limit` 一律向上抛。

### D6. TrueType 用独立表读取器 + 纯内存字体对象

- `SvgTrueTypeTables.cj` 提供带边界检查的 `be16` / `be32` / `i16` 读取与表目录定位，所有偏移在读前校验；
- `SvgTrueTypeFont` 组合 `head` / `hhea` / `maxp` / `hmtx` / `loca` / `cmap`（4、12）/ `glyf`；
- `glyf` 简单字形转 `M/L/Q/Z`（二次曲线按 `Q` 输出，隐式中点按两点间插入），复合字形按标志递归组合，深度 ≤ 8；
- 坐标缩放 `fontSize / unitsPerEm`，y 取负；`advance` 仅来自 `hmtx`；
- 有 `CFF ` 表或 `head.indexToLocFormat` 非法 → `Unsupported` / `Syntax`；
- `load(Path)` 只读取调用方给的路径，渲染链路永远不调用它（见 svg-security）。

**替代方案**：把 TTF 转成 `SvgPathData` 列表缓存。被否：字体对象可能被多个注册表复用，按需解析更省内存，且 `glyphBounds` 需要原始度量。

### D7. 文本排版在现有布局器上叠加三个阶段

`SvgTextRenderer.layout` 已产出每个字形的 `(x, y)` 与旋转角，M4 只加三处：

1. **书写模式**：`SvgTextWritingMode` 在布局前把「沿 x 前进」改为「沿 y 前进、列沿 x 递减」，字形角加 90°；`text-anchor` 改按列长调整；`textPath` 存在时忽略并 warning。
2. **基线**：`SvgTextBaseline.offset(...)` 按以下表计算（`A = ascent`、`D = descent`、`fs = fontSize`，正值向下）：

   | 取值 | 偏移 |
   |---|---|
   | `alphabetic` / `auto` | `0` |
   | `text-before-edge` / `before-edge` | `-A` |
   | `hanging` | `-0.8A` |
   | `middle` / `central` | `(D - A) / 2` |
   | `mathematical` | `-0.5A` |
   | `ideographic` / `text-after-edge` / `after-edge` | `+D` |

   `dominant-baseline` 用该表；`alignment-baseline` 用同一张表计算 `tspan` 相对父基线的差值；`baseline-shift` 最后叠加，正值向上，`sub = -0.2fs`、`super = +0.4fs`。Hershey 的 `A = 0.8fs`、`D = 0.2fs`。
3. **装饰线**：`SvgTextDecoration` 在每个字形落位后生成矩条：下划线 `baseline + 0.10fs`，上划线 `baseline - A`，删除线 `baseline - 0.55A`，厚度 `max(1, fs/14)`；按字形旋转矩阵变换，渐变取字形起点颜色。

`textPath` 扩展在落位阶段消费：`side` 沿法线平移 `±0.5fs` 且不改切线角；`method=stretch` 先按路径长 / 文本 advance 缩放 advance 与字形 x 比例；`spacing=exact` 只使用显式 `dx` / `letter-spacing`，缺省回落 `auto`。

**替代方案**：重写布局器支持任意书写模式。被否：M4 只要求 `lr-tb` 与 `tb-rl`，在现有 advance 模型上换轴足够，且能保持 M3 快照。

### D8. 路径测量单一实现，textPath 改为消费它

`SvgPathMeasure`：

1. 按容差把 `SvgPathData` 绝对化后逐段离散：直线一段；二次/三次按既有细分逻辑；弧转中心参数化后按容差分段；
2. 产出 `Array<SvgPathSegment>`（起点、终点、长度、累计长度）；
3. `totalLength()` 取末段累计；`pointAtLength()` 二分定位段内比例并线性插值；
4. 负值/超长钳制，空路径返回 `(0, 0)`；
5. `SvgTextPathLayout` 删除私有采样，改用 `SvgPathMeasure` 的段表与取点。

`tolerance` 缺省 0.25，非正/非有限抛 `InvalidValue`。**替代方案**：让 `SvgPathData` 自己实现采样。被否：会与 textPath 出现两套弧长。

### D9. `ctm` / `screenCTM` 复现渲染器的矩阵链

- `SvgGeometry.ctm(element)`：从元素沿 `parent` 上溯到根，按「根视口矩阵 × 各级 `transform` × 嵌套 `svg` 的 `translate(x,y) × viewBox 矩阵`」正向累乘；`use` 不在文档树上，天然不计入；
- 百分比尺寸的嵌套 `svg` 以根视口 `300×150`（或根绝对尺寸）为基准，与 `SvgViewport.from` 一致；
- `SvgViewportTransform` 保存 `width` / `height` / `matrix` / `devicePixelRatio`，`from(root, options)` 复用 `SvgViewport.from` + `transform`；
- `screenCTM = ctm × viewport.matrix × scale(dpr)`。

为保证与渲染一致，渲染树与 `SvgGeometry` 共用 `elementTransformMatrix` 与 `SvgViewport.nestedTransform`，不复制公式。

### D10. `switch` 在渲染树求值，条件集合固定

- 只检查 `switch` 的直接子元素，按文档顺序；
- 已知特性集合为固定常量数组（`Structure` / `Shape` / `Text` / `Paint` / `Color` / `Filter` / `Image` / `Pattern` / `Marker` / `Clip` / `Mask` / `Gradient` / `Style` / `View` / `Animation` / `Hyperlinking` / `XlinkAttribute`），其余不满足；
- `requiredExtensions` 非空即失败；
- `systemLanguage` 与 `SvgRenderOptions.languages` 做大小写不敏感的前缀匹配，边界为 `-`（`zh` 匹配 `zh-CN`，不匹配 `zhx`）；
- 命中后检查计算样式 `display == none`，是则继续；
- 求值只读文档；选中子树走正常 `walkElement`。

### D11. `view` 与 `anchors` 是纯查询，不进入渲染

- 新增 `SvgView <: SvgElement`（`tag = "view"`），属性缓存复用 `SvgValueCache`；
- `SvgDocument.views()` 前序遍历收集 `SvgView`；`view(id)` 复用 `elementById` 再判类型；
- `anchors()` 前序遍历收集 `SvgContainerKind.Anchor`，构造 `SvgAnchorInfo(element, href, target)`；`href` 读 `href` / `xlink:href`，`target` 缺省 `""`；
- 渲染树对 `view` 直接跳过；`a` 仍按容器渲染，行为与 M3 相同。

### D12. `SvgRenderOptions.languages` 只影响 switch

新增 `languages: Array<String> = ["en"]`，追加在既有字段末尾并带默认值；不参与文本、字体、裁剪或缓存键。为空数组时 `systemLanguage` 永不匹配。

### D13. 确定性与兼容性护栏

- 所有新算法只依赖输入与选项；湍流用整数哈希、光照用固定差分顺序、卷积固定核遍历顺序；
- 新缓存（TTF 字形、pattern tile）仍在单次 render 或字体对象内，不跨实例共享；
- 快照对比覆盖 `testdata/render/` 全部场景，新增 `m4-*` 场景；
- 每阶段结束跑 `cjpm test`，M1–M3 用例零回归。

## 关键契约

- `SvgRenderOptions` 只加 `languages`；既有构造调用不需要修改。
- `SvgPathData` / `SvgGeometry` / `SvgDocument` 只加方法，不改既有签名。
- 未声明 `clip` / `overflow` / `vector-effect` / 基线 / 装饰 / 书写模式时，输出与 M3 一致；唯一条件性差异是越出 marker 视口的内容按 SVG 1.1 被裁剪。
- 异常语义沿用 M1–M3：结构 `Syntax`、非法值 `InvalidValue`、超限 `Limit`、安全 `Security`、不支持的字体轮廓 `Unsupported`。
- 外部资源仍只来自 `data:` 与调用方 provider；字体只由调用方显式加载。

## Risks / Trade-offs

| 风险 | 取舍 |
|---|---|
| `clip` 覆盖率蒙版增加一次全画布光栅 | 只在该元素有 `clip` 时创建；沿用它已有的 `SvgCoverageMask` 与 `maxPixels` 检查 |
| marker 视口裁剪改变个别素材输出 | 仅影响越界内容；M1–M3 快照经比对保持逐字节一致；在 README 与 CHANGELOG 说明 |
| pattern `overflow="visible"` 受限 | tile 即采样周期，不实现跨 tile 溢出；在 spec / README 明示 |
| 卷积与湍流成本高 | `order` ≤ 9×9、`numOctaves` ≤ 8；区域外不计算；先检查像素上限 |
| TTF 解析器易受恶意字节攻击 | 所有读取带边界检查；表数 / 表长 / 点数 / 复合深度先检查；只解析白名单表 |
| 竖排与 textPath / letter-spacing 交互复杂 | 竖排只换轴并固定 90°；与 textPath 冲突时按 spec 忽略 writing-mode 并 warning |
| `ctm` 的百分比嵌套视口缺基准 | 统一以根视口（绝对尺寸或 300×150）为基准，与渲染入口一致 |
| 基线表无 x-height 度量 | `middle` 与 `central` 取 em 中线，`mathematical` 取 `-0.5A`，在文档中写明近似 |
| 默认行为漂移 | `overflow` 初始 hidden 只影响 viewport 元素；其余属性缺省即 M3 语义；快照全量比对 |

## Migration Plan

- 在 `feature/f-svg-m4` 分支开发（从当前 `f_svg` 工作分支切出），按任务阶段独立提交，完成后 `git merge --no-ff` 回上游并删除分支。
- 实施顺序按设计文档 §8：A1–A3 → A4–A10 → A11 → B1–B2 → B3–B4 → B5 → C1–C3 → C4–C5 → 文档与验收。
- 无数据迁移；调用方不传 `languages` 且不使用新属性时行为不变。
- 文档同步：`README.md` / `README_en.md` 增加 M4 能力表与示例；`doc/f_svg-M4设计.md` 作为设计依据保留不动；`doc/perf-baseline.md` 增加滤镜与 TTF 基准记录。

## 假设与待确认

1. `overflow` 在 `pattern` 上的 `visible` 不扩展到相邻 tile（tile 是采样周期），按 D3 的限制实现并在文档声明。
2. `text-decoration` 的祖先传播按「最近声明祖先」生效，子元素显式 `none` 可关闭。
3. `baseline-shift` 的百分比以 `font-size` 为基准（设计文档 §3.1），而非行高。
4. `view` 的 `viewTarget` 只做模型往返，不参与渲染或导航。
5. 标记为条件性兼容差异的 marker 裁剪按 SVG 1.1 执行；若后续要求严格保持 M3 字节，可把 marker 裁剪改为只在显式 `overflow="hidden"` 时启用。
