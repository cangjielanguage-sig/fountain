# 设计：f_svg（M3）

## Context

M1 / M2 已交付的能力与当前实现事实（实施前已核对源码）：

- `SvgTag.create` / `isKnown` 是标签到模型的唯一映射入口（`f_svg/src/SvgTag.cj:24`）；`filter` 当前不在映射表内，`pattern` / `marker` 映射为 `SvgContainer`，由 `SvgContainerKind` 区分（`f_svg/src/SvgContainer.cj:19`）。
- `SvgBuilder` 用 `SvgTag.create` 构建元素，并维护属性白名单（`f_svg/src/SvgBuilder.cj:151`）；新增标签只需扩展 `SvgTag` 与白名单，不触碰 `f_xml`。
- `SvgParseOptions` / `SvgSecurityOptions` 位于 `f_svg/src/SvgOptions.cj`；`SvgRenderOptions` 位于 `f_svg/src/SvgBitmap.cj:194`，现有字段为 `width` / `height` / `background` / `samplesPerPixel` / `maxPixels` / `fonts` / `devicePixelRatio`。
- `SvgParser` 有文本 / 字节 / 流 / 路径 / `XmlDocument` 五个 `parse` 重载（`f_svg/src/SvgParser.cj:28`）；`SvgWriter` 与顶层 `writeSvgString` 是既有生成入口（`f_svg/src/SvgWriter.cj:55`、`:216`）。
- 渲染链路为 `SvgRenderTreeBuilder` → `SvgDisplayList` → `SvgRenderer`（`f_svg/src/SvgRenderTree.cj:160`、`f_svg/src/SvgRenderer.cj:47`）；`<image>` 目前只产生占位（`f_svg/src/SvgRenderTree.cj:552`）。
- `SvgRasterizer` 固定 `samplesPerPixel ∈ {1,2,4}` 超采样，覆盖率以命中计数计算（`f_svg/src/SvgRasterizer.cj:67`）；`fillContours` / `fillContoursShader` 是描边、渐变共用的内部入口。
- `SvgTextRenderer.layout(text, style)` 已实现字形 advance、`x`/`y`/`dx`/`dy`、`letter-spacing`/`word-spacing`、`text-anchor`/`textLength`（`f_svg/src/SvgTextRenderer.cj:139`）；`SvgTextPath` 已有 `href` / `startOffset` 模型，`SvgTextElement.rotate` 已是 `?Array<Float64>`（`f_svg/src/SvgTextElement.cj:150`），但两者都未参与渲染。
- `SvgPngEncoder` 已依赖 `stdx.compress.zlib` 的 `CompressOutputStream` / `WrapType.DeflateFormat`，并自带 `SvgCrc32`（`f_svg/src/SvgPngEncoder.cj:19`、`f_svg/src/SvgCrc32.cj`），M3 解码可直接复用。
- `SvgCoordinateUnits` 已存在于 `f_svg/src/SvgGradient.cj:23`，取值为 `UserSpaceOnUse` / `ObjectBoundingBox`。
- 渐变、裁剪、蒙版的离屏层与 `maxPixels` 校验模式可直接复用（`SvgClipMask`、`SvgRenderer.applyEffects`）。
- 源码共 348 个 `@TestCase`（测试用例）与 53 个 `@Test`（测试类标注，非用例）；`cjpm test` 实测为 348 条，与 M2 归档一致。

M3 缺的是「效果与资源」：滤镜链、图案、位图解码、SVGZ、文本路径、marker 与解析 AA。设计遵循 `f_svg/doc/f_svg-M3设计.md`，并保持 M1/M2 公开 API 只增不改、单包不新增模块。

## Goals / Non-Goals

**Goals**

1. 类型化 `filter` / 8 个 `fe*` / `pattern` / `marker`，解析、修改、生成可往返。
2. 滤镜区域、图连接与离屏缓冲链，八个原语的确定性像素算法。
3. 图案平铺与 `href` 继承，接入既有画笔解析与 shader 填充。
4. 完整 PNG 解码：颜色类型 0/2/3/4/6、位深 1/2/4/8、filter 0–4、Adam7、CRC 与结构校验。
5. `<image>` 的 data URI 与 provider 两条路径，`preserveAspectRatio` 三档映射与取样质量两档。
6. SVGZ 读写与 `parseAuto` 魔数识别，解压上限防炸弹。
7. `textPath` 沿弧长排版、`startOffset`、`text-anchor`、逐字旋转与 `rotate` 列表。
8. marker 顶点派生、单位 / 朝向 / 对齐 / 上限。
9. 解析覆盖率 AA 作为可选档，默认输出与 M2 保持一致。
10. 每个 Requirement 至少一个可执行 Scenario；M1/M2 用例零回归；`f_svg` 自身 0 warning。

**Non-Goals（M3 不做）**

- JPEG / WebP / GIF 解码、`feImage`、`foreignObject` 内部 XHTML。
- SMIL 扩展（`animateColor`、事件驱动、脚本）。
- TTF/OTF 字体解析、内置 CJK 字体、复杂字形整形与双向文本。
- GPU / native 光栅后端与任何新的 native 依赖。
- 浏览器逐像素兼容；只保证设计文档定义的语义与自有快照稳定。

## 架构

```
                         SvgDocument（M1 模型，只读）
                              │
                    SvgRenderTreeBuilder
             ┌────────────────┼─────────────────┐
             │                │                 │
   SvgPatternSampler   SvgMarkerExpander   filter 引用解析
   （tile 位图）        （顶点派生实例）      （SvgFilter）
             │                │                 │
             └────────┬───────┴─────────────────┘
                      │
                SvgDisplayList
        （FillPath / StrokePath / Image / Text / Group）
                      │
                SvgRenderer
        ┌─────────────┼──────────────┬──────────────┐
        │             │              │              │
  SvgRasterizer  SvgImageDecoder  SvgFilterRenderer  SvgGroupCompositor
  （Supersample   （PNG → 位图）    （离屏缓冲链）      （裁剪 / 蒙版 / 透明度）
   或 Analytic）
```

- 图案、marker、滤镜全部在**渲染树展开阶段**派生，不写回 `SvgDocument`。
- 滤镜与图案的离屏缓冲先校验像素数再分配；所有外部字节只来自 `data:` 或调用方 provider。

## Decisions

### D1. 复用 `SvgCoordinateUnits`，不新增 `SvgUnits`

设计文档写的是 `SvgUnits`，但 M1 已有语义完全相同的 `SvgCoordinateUnits`（渐变、mask 已在用）。M3 的 `filterUnits` / `primitiveUnits` / `patternUnits` / `patternContentUnits` 一律复用该枚举，避免同一概念两套公开类型。`SvgMarkerUnits` / `SvgMarkerOrient` 语义不同，新增独立枚举。

### D2. `pattern` / `marker` 升级为 `SvgContainer` 子类，`filter` 为 `SvgElement` 子类

- `SvgPattern <: SvgContainer`，构造时传 `SvgContainerKind.Pattern`；`SvgMarker <: SvgContainer`，传 `SvgContainerKind.Marker`。既有 `is SvgContainer` 判断、`kind` 比较与标签名回写保持兼容，`SvgContainerKind` 枚举值不变。
- `filter` 从未进入 `SvgTag`，M3 直接新增 `SvgFilter <: SvgElement`，内部持有 `primitives`；`fe*` 是 `SvgFilterPrimitive <: SvgElement` 的八个具体子类。
- `SvgTag.create` 先把 `pattern` / `marker` 指向新类型，`filter` 与 `fe*` 新增分支；`SvgBuilder` 的属性白名单同步扩展，未知属性仍按 M1 规则原样保留。

### D3. 滤镜缓冲为画布尺寸，区域外透明

`SvgFilterRenderer.apply(filter, source, objectBounds, transform, options)` 返回**与 `source` 同尺寸**的位图：先按 `filterUnits` / `primitiveUnits` 计算滤镜区域，裁剪到画布，再在区域对应的子缓冲中执行原语链，最后把结果写回画布坐标，区域外保持透明。缓冲类型 `SvgFilterBuffer` 记录 `width` / `height` / `pixels`（RGBA8 非预乘），每个原语产生新缓冲，避免原地读写歧义。滤镜区域像素数超过 `maxPixels` 时先抛 `SvgException(kind: Limit)` 再分配。

### D4. 图连接按 SVG 1.1 的默认值解析

- 首个原语的 `in` 缺省为 `SourceGraphic`；后续原语缺省为前一个原语的 `result`。
- `in2` 缺省为 `SourceGraphic`（`feBlend` / `feComposite`）。
- `result` 未命名时按位置隐式命名，不参与后续引用。
- 引用不存在的名字、或引用自身未定义的 `result`：该原语输出透明黑并追加 warning，链继续执行。
- 空 `primitives` 直接返回 `SourceGraphic` 拷贝。
- `color-interpolation-filters="linearRGB"` 时只在进入 / 离开链时各做一次 sRGB ↔ linearRGB 转换；默认 sRGB。

### D5. 图案走「渲染 tile 位图 + shader 取样」

`SvgPatternSampler.sample(pattern, objectBounds, transform, options)`：

1. 解析 `href` 继承链（自身属性优先），循环引用记 warning 并停止；
2. 按 `patternUnits` 把 `x/y/width/height` 换算为 tile 尺寸，按 `patternContentUnits` 建立内容矩阵；
3. 用现有渲染树/光栅器把 pattern 子内容渲染为 `SvgBitmap` tile；
4. 把 `patternTransform` 合成到 tile → 用户空间矩阵；
5. 把 tile 作为 REPEAT shader 交给 `fillContoursShader`，按填充区域裁剪。

空 tile（宽或高 ≤ 0）返回 `None` 并记 warning；tile 像素数超过 4 × 1024 × 1024 抛 `Limit`；引用深度超过 64 抛 `Limit`。

### D6. PNG 解码复用现有 CRC 与 zlib，严格按 chunk 状态机

`SvgPngDecoder.decode` 只做字节处理，不依赖渲染器：

- 签名 → `IHDR`（必须是第一个 chunk）→ 任意 `IDAT` 连续段 → `IEND`；缺失、乱序、重复 `IHDR`、`IDAT` 不连续均抛 `Syntax`。
- 每 chunk 校验长度与 CRC-32，复用 `SvgCrc32.checksum`。
- `stdx.compress.zlib.DecompressInputStream` + `WrapType.ZlibFormat` 解压 `IDAT`；解压输出上限按行数 × 行字节数计算，防解压炸弹。
- 反 filter 0–4 在每行独立进行；Adam7 七个 pass 各自反 filter 后写入最终像素。
- 调色板读 `PLTE` 与 `tRNS`；1/2/4-bit 灰度与调色板按位展开到 8-bit。
- 未知颜色类型 / 位深 / 压缩方法 / 过滤方法抛 `InvalidValue`；结构错误抛 `Syntax`；超上限抛 `Limit`。

### D7. `<image>` 由 data URI 与 provider 两条路径构成，默认不改变 M2 输出

- `href` 以 `data:image/png;base64,` 开头时内置 base64 解码 + PNG 解码，受 `allowDataImages` 与 base64 长度上限约束。
- 其他 `href` 只在 `SvgRenderOptions.images` 非 `None` 时调用 `resolve(href)`；返回 `None` 或未注入 provider 时按 M2 画占位并记 warning。
- 每次 `render` 内按 `href` 缓存解码结果；跨 render 不缓存。
- `preserveAspectRatio` 复用 `SvgPreserveAspectRatio.toMatrix`，`none` 直接拉伸，`meet` / `slice` 取对应矩阵。
- 取样质量由计算样式 `image-rendering` 决定：`auto` / `optimizeQuality` 走双线性，`pixelated` / `optimizeSpeed` 走最近邻；默认双线性。

### D8. SVGZ 由 `parseAuto` / `parseGzip` / `writeGzip` 三个入口承担

- `SvgParser.parseAuto(bytes, options!)` 检测前两字节 `1F 8B`，命中走 gzip，否则按 UTF-8 文本解析；魔数误判导致解压失败时抛 `Syntax`，不静默回退。
- `parseGzip` 强制按 gzip 解压；非 gzip 输入抛 `Syntax`。
- `writeGzip(document)` 复用 `writeSvgString` 得到 UTF-8 字节，再用 `CompressOutputStream(..., WrapType.GzipFormat)` 压缩；gzip 头 mtime 固定 0，保证同文档同字节。
- 解压输出上限由 `SvgSecurityOptions.maxDecompressedBytes`（新增字段，默认 64 MiB）控制，超限抛 `Limit`。

### D9. `textPath` 独立成布局器，`rotate` 在字形落位阶段消费

- `SvgTextPathLayout` 复用 `SvgPathData` 扁平化与弧长采样，接受「字形 advance 序列」返回每个字形的 `(x, y, tangentAngle)`。
- 路径来源：`href="#id"` 指向 `path`（也接受 `textPath` 自身的 `path` 属性）；不存在或为空时回退普通文本并 warning。
- `startOffset` 百分比按路径总长换算，长度按用户单位；`text-anchor` 调整整体起点。
- 路径短于文本时截断并 warning；`side` 属性不支持，忽略不报错。
- `rotate` 单值作用于全部字形，列表按字形索引消费，短列表复用末值；与 `textPath` 同时存在时角度相加。

### D10. marker 在渲染树阶段展开为普通绘制指令

- 对 `path` / `line` / `polyline` / `polygon` 的扁平化顶点，按 `marker-start` / `marker-mid` / `marker-end` 派生实例。
- `markerUnits=strokeWidth` 时缩放系数取元素 `stroke-width`（缺省 1）；`userSpaceOnUse` 不缩放。
- `orient=auto` 用进入 / 离开切线角；`auto-start-reverse` 仅对 `marker-start` 加 180°；固定角度直接使用。
- `refX` / `refY` 把 marker 内容原点对齐到顶点；`viewBox` + `preserveAspectRatio` 复用 M1 的 `toMatrix`。
- marker 内容作为独立子树进入渲染树，`clipPath` / `mask` / `filter` 正常生效；每个元素最多 1024 个，超出 warning 并停止。

### D11. 解析 AA 用有符号面积累加，内外判定仍走 nonzero / evenodd

`SvgAnalyticRasterizer` 与 `SvgRasterizer` 共享扁平化轮廓：

1. 对每条设备空间线段，按像素列累加有符号面积到覆盖率缓冲；
2. 用扫描线 / 缠绕数确定像素中心的内外，避免面积符号被自交路径抵消；
3. 覆盖率按 `source-over` 与颜色合成，边缘像素覆盖率之和与几何面积一致（误差 ≤ 1/255）。

`SvgAntiAliasMode.Analytic` 只改变覆盖率来源，不改变填充规则、变换、裁剪或合成顺序。默认 `Supersample` 时 `samplesPerPixel` 语义完全不变。

### D12. 新增枚举与选项全部带默认值

- `SvgRenderOptions` 新增 `images: ?SvgImageResourceProvider = None`、`antiAlias: SvgAntiAliasMode = Supersample`；既有字段与顺序不动，构造参数全部有默认值。
- `SvgSecurityOptions` 新增 `maxDecompressedBytes: Int64 = 64 * 1024 * 1024`，其余字段不动。
- 其余上限（单图像素、总解码像素、base64 长度、图案 tile、marker 数、引用深度）以 `f_svg` 内部常量实现，不扩大公开选项面；需要时通过新的命名常量暴露，不改既有行为。

### D13. 确定性优先于微优化

- 滤镜、图案、marker、AA 的所有中间缓冲按固定顺序遍历，不使用哈希表迭代或并行归约。
- PNG 解码只依赖输入字节；gzip 输出固定 mtime；`<image>` 缓存键为 `href` 原文。
- 同一文档 + 同一选项 + 同一 provider，输出逐字节一致。

## 关键契约

- `filter` / `pattern` / `marker` / `fe*` 解析后可无损写回；未知属性仍按 M1 规则保留。
- `pattern` / `marker` 的 `SvgContainerKind` 值不变；`filter` 不再落入 `SvgUnknownElement`。
- 所有解码 / 解压 / 滤镜 / 图案 / marker 上限在分配前检查。
- 外部资源只能来自 `data:` 或 `SvgImageResourceProvider`；库内无网络、无任意路径读取、无脚本执行。
- 默认 `SvgRenderOptions` 的输出与 M2 一致（合法 data URI 除外）。
- 异常统一为 `SvgException`：结构错误 `Syntax`、非法值 `InvalidValue`、超限 `Limit`、安全策略 `Security`。

## 风险 / 取舍

| 风险 | 取舍 |
|---|---|
| 滤镜链全画布缓冲内存偏高 | 区域外不参与计算；先检查 `maxPixels`；原语间复用可回收缓冲 |
| 图案 tile 每次都重渲染 | 单次 render 内按 pattern 元素身份缓存 tile；跨 render 不缓存，保证文档只读 |
| PNG 解码实现量大 | 只支持 8-bit 与 1/2/4-bit 展开，不支持 16-bit；未知组合明确抛 `InvalidValue` |
| Adam7 易错 | 七个 pass 各写独立单测，并与非交错结果逐像素比对 |
| textPath 与字距 / anchor 交互复杂 | 复用现有 `SvgTextLayout` 的 advance，只替换落位与旋转；截断规则写进 Scenario |
| marker 数量爆炸 | 1024 硬截断 + warning；派生预算在展开前计算 |
| 解析 AA 自交路径面积抵消 | 内外用缠绕数独立判定，面积只算覆盖率；nonzero / evenodd 各有自交用例 |
| 默认行为漂移 | `antiAlias` 默认 `Supersample`；`images` 默认 `None`；只有合法 data URI 会从占位变为绘制 |

## Testing Strategy

- **TDD**：每个功能先写失败用例，确认失败原因与预期一致，再写最小实现，最后重构。
- **单元测试**（`f_svg/src/*_test.cj`）：
  - 模型与往返：`SvgTag` 映射、属性读写、`SvgRoundTrip_test`；
  - 滤镜：每原语像素断言、链式连接、区域换算、未定义引用 warning、上限；
  - 图案：tile 尺寸、四角取样、`patternTransform`、`href` 继承与循环、空 tile；
  - PNG：六类变体回环、filter 0–4、Adam7、坏 CRC / 截断 / 缺 IEND / 非法 IHDR；
  - `<image>`：meet / slice / none、data URI 与 provider、缓存、未注入占位；
  - SVGZ：纯文本与 gzip 结果一致、往返、魔数误判、截断、超限；
  - textPath / rotate：字符位置与切线角、startOffset 两种形式、短列表复用；
  - marker：start / mid / end 对齐、orient、markerUnits、上限；
  - AA：45° 斜线覆盖率和、圆与 4× 超采样差 ≤ 2/255、自交路径、组合确定性。
- **场景快照**（`SvgScene_test.cj` + `testdata/render/`）：滤镜、图案、位图、textPath、marker 各一张，逐像素容差 ≤ 1。
- **负向用例**：每一条上限至少一个，断言异常 kind 与「未分配大缓冲」。
- **性能基准**：滤镜 512×512 高斯、图案 512×512 平铺、解析 AA 1024×1024 圆，记录到 `f_svg/doc/perf-baseline.md`，标注「参考、非门禁」。

## Migration / Rollout

- 在 `feature/f-svg-m3` 分支开发（从当前 `f_svg` 工作分支切出），按任务阶段独立提交，完成后 `git merge --no-ff` 回上游并删除分支。
- 发布顺序即设计文档 §11：模型与标签 → SVGZ / PNG → `<image>` → 图案 → 滤镜 → textPath → marker → AA → 测试与文档。
- 无数据迁移；调用方不传新选项即保持 M2 行为。
- 文档同步：`README.md` / `README_en.md` 增加 M3 能力表与示例，`doc/f_svg-M3设计.md` 作为设计依据保留不动。

## 假设与待确认

1. `SvgFilterRenderer.apply` 返回画布尺寸位图（区域外透明），而非区域尺寸位图；这样调用方无需再处理偏移。
2. `filter` / `pattern` / `marker` 的数值上限使用内部常量，不新增公开配置字段；如后续需要可再加带默认值的选项。
3. `textPath` 的 `path` 属性与 `href` 同时存在时优先 `path`，与 SVG 1.1 的 `href` 优先级相反的场景（浏览器实现差异）不在 M3 兼容目标内。
4. `image-rendering` 作为新增 CSS 属性加入计算样式表；未设置时按 `auto`（双线性）。
5. 合法 `data:image/png` 从「占位」变为「绘制」是 M3 唯一默认输出变化，已在 proposal 的兼容性中声明。
