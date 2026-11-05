# add-f-svg-m3 校验报告

> 校验对象：`openspec/changes/add-f-svg-m3` 的 `proposal.md` / `design.md` / `tasks.md` / `specs/*`，以及 `openspec/specs/svg-*` 主规格。
> 对照实现：`f_svg/src/*.cj` 与全部 `*_test.cj`、`f_svg/testdata/render/*`。
> 校验方式：只读静态核对 + 实际执行 `cjpm build` / `cjpm test`；未修改代码、未归档、未使用 ssh / opsx 技能。

## 0. 结论摘要

- `cjpm test`：**466 / 466 通过，0 skipped，0 error，0 failed**（与 `verification.md` 的 466 一致）。
- `cjpm build`：成功；构建输出的 22 条 warning 全部来自 `f_xml` 等依赖模块，未发现 `f_svg/src` 自身 warning。
- 规格规模：**48 个 Requirement（其中 2 条为 REMOVED，无 Scenario；有效 46 条）/ 112 个 Scenario**。
- 落点规模：112 个 Scenario 全部有映射记录；`verification.md` 共 113 行（112 个 Scenario + 1 条补充覆盖），所有被引用的测试类与方法均存在。
- 落点质量：**通过 90 个、部分通过 21 个、失败 2 个**。失败项为 `svg-filter` 的“平铺”和 `svg-render-pipeline` 的“顺序确定”。
- 上限负向用例：核心上限大多有负向用例，但 **32 位乘积溢出、渲染级累计解码、gzip 后 maxDepth、PNG 结构变体、pattern/marker 内容自引用、marker/image 的 mask/filter 等仍缺口**。
- 默认输出：未发现 M1/M2 场景出现 >1 的像素漂移，但现有快照测试容差为 1，且没有 M2 字节级基线，**无法证明“逐字节一致”**。
- 分级：**CRITICAL = 7，WARNING = 22，SUGGESTION = 6**。

整体判断：M3 主体能力（模型、往返、PNG、SVGZ、图案、marker、textPath、滤镜原语像素算法）大体可运行，回归全绿；但**滤镜没有按元素级图层应用、`feTile` 在真实滤镜链中无效、解析 AA 未按规格算法实现、PNG/pattern 上限存在乘法溢出绕过、pattern/marker 内容自引用可无限递归、空 textPath 不降级、marker 公开 API 类型与规格不符**，这些问题会直接破坏验收契约，不能按“任务全部勾选”直接归档。

## 1. 校验事实

| 项目 | 结果 | 证据 |
|---|---|---|
| 构建 | 成功 | `cjpm build`；22 条 warning 均指向依赖模块，`grep f_svg/src` 为 0 |
| 单测 | 466/466 | `cjpm test` 汇总；与 `verification.md:4` 一致 |
| 既有 M1/M2 场景 | 通过 | `SvgScene_test` 的 basic / gradient / stroke / clip / text / animation |
| M3 场景 | 通过 | `SvgSceneM3_test` 的 m3-filter / m3-pattern / m3-image / m3-textpath / m3-marker |
| 映射表 | 名单全部存在 | 逐行解析 `verification.md` 的 `Class.method`，未发现不存在的类/方法 |
| M2 快照文件 | 未在 M3 期间改写 | `basic.rgba` 等 6 个文件 mtime 为 14:06，`text.rgba` 为 14:49；均早于 M3 新增源文件的 17:58 |
| M3 负向 fixture | 仅有占位 README | `testdata/render/m3/README.md`、`testdata/render/m3-negative/README.md` 仍写“占位” |

## 2. Completeness（完整性）

### 2.1 Requirement / Scenario 覆盖矩阵

| Spec | Requirement | Scenario | 有映射 | 通过 | 部分 | 失败 |
|---|---:|---:|---:|---:|---:|---:|
| svg-css | 1 | 3 | 3 | 3 | 0 | 0 |
| svg-document-model | 5 | 11 | 11 | 9 | 2 | 0 |
| svg-filter | 8 | 18 | 18 | 13 | 4 | 1 |
| svg-paint-and-clip | 4 | 9 | 9 | 8 | 1 | 0 |
| svg-png | 5 | 13 | 13 | 11 | 2 | 0 |
| svg-render-pipeline | 5 | 9 | 9 | 7 | 1 | 1 |
| svg-security | 4 | 11 | 11 | 8 | 3 | 0 |
| svg-text | 5 | 9 | 10（含 1 条补充） | 8 | 2 | 0 |
| svg-rasterization | 3 | 13 | 13 | 9 | 4 | 0 |
| svg-marker | 4 | 10 | 10 | 9 | 1 | 0 |
| svg-value-types | 4 | 6 | 6 | 5 | 1 | 0 |
| **合计** | **48** | **112** | **113** | **90** | **21** | **2** |

结论：**112/112 都有“落点”，但只有 90 个可判定为真正覆盖；2 个 Scenario 的实现与断言均不成立，21 个只覆盖了表层行为。**

### 2.2 逐 Scenario 落点

| Spec | Scenario | 可执行用例 | 判定 | 说明 |
|---|---|---|---|---|
| svg-css | 初始值 | `SvgComputedStyleM3_test.imageRendering` | 通过 | 断言 auto |
| svg-css | 内联覆盖 | 同上 | 通过 | inline pixelated |
| svg-css | 非法值 | 同上 | 通过 | auto + warning |
| svg-document-model | filter 类型化 | `SvgFilter_test.typeAndPrimitiveOrder` | 通过 | primitives 顺序 |
| svg-document-model | pattern 兼容 | `SvgPattern_test.typeAndDefaults` | 通过 | is SvgContainer + kind |
| svg-document-model | 属性往返 | `SvgFilter_test.regionDefaults`、`SvgRoundTripM3_test.m3ElementsStructuralEquivalence` | 通过 | set/get + 写回重解析 |
| svg-document-model | 原语类型化 | `SvgFilter_test.primitiveProperties` | 通过 | 8 种 fe* |
| svg-document-model | 非 fe 子元素 | `SvgFilter_test.nonPrimitiveChildWarns` | 通过 | 不进 primitives |
| svg-document-model | parseAuto 识别 | `SvgGzip_test.parseAutoMatchesText` | 通过 | 文本/gzip 快照一致 |
| svg-document-model | 纯文本不误判 | `SvgGzip_test.parseAutoMatchesText` | 部分 | 未显式断言“未走解压分支” |
| svg-document-model | 截断 gzip | `SvgGzip_test.corruptInputsRejected` | 部分 | 走 `parseGzip`，未走 `parseAuto` 魔数路径 |
| svg-document-model | gzip 往返 | `SvgGzip_test.roundTrip` | 通过 | 结构等价 |
| svg-document-model | 压缩炸弹 | `SvgGzip_test.decompressionLimit` | 通过 | 16 字节上限触发 Limit |
| svg-document-model | 输出确定性 | `SvgGzip_test.outputDeterminism` | 通过 | 两次字节一致、mtime 0 |
| svg-filter | 默认区域 | `SvgFilterRenderer_test.defaultRegion` | 通过 | (80,90,240,120) |
| svg-filter | userSpaceOnUse 区域 | `SvgFilterRenderer_test.userSpaceRegion` | 通过 | 50×50 不缩放 |
| svg-filter | 区域超限 | `SvgFilterRenderer_test.regionLimit` | 部分 | 只断言 Limit，未验证“未分配区域缓冲” |
| svg-filter | 隐式图连接 | `SvgFilterChainM3_test.implicitChaining` | 部分 | 只有 feFlood + feOffset；缺 feBlend 与 in2 默认断言 |
| svg-filter | 未定义引用 | `SvgFilterRenderer_test.undefinedReference` | 部分 | 只有单个原语，未验证“后续仍执行” |
| svg-filter | 空滤镜链 | `SvgFilterRenderer_test.emptyChainPassthrough` | 通过 | 逐字节等于 source |
| svg-filter | σ=0 直通 | `SvgFilterPrimitive_test.gaussianBlur` | 通过 | 缓冲逐字节一致 |
| svg-filter | 单值标准差 | `SvgFilterChainM3_test.singleDeviation` | 通过 | x/y 对称 |
| svg-filter | 偏移越界 | `SvgFilterPrimitive_test.offset` | 通过 | 正负方向补透明 |
| svg-filter | 洪水填充 | `SvgFilterPrimitive_test.flood` | 通过 | (0,255,0,128) |
| svg-filter | normal 等价 over | `SvgFilterPrimitive_test.blend` | 通过 | 逐字节一致 |
| svg-filter | multiply | 同上 | 通过 | 红×蓝=黑 |
| svg-filter | 算术合成 | `SvgFilterPrimitive_test.composite` | 通过 | 钳制到 255 |
| svg-filter | merge 顺序 | `SvgFilterPrimitive_test.merge` | 通过 | b over a |
| svg-filter | 亮度转 alpha | `SvgFilterPrimitive_test.colorMatrix` | 通过 | 白→alpha 255 |
| svg-filter | 平铺 | `SvgFilterPrimitive_test.tile` | **失败** | 只测 `tileFilterBuffer` 2×2→6×6；真实链中为恒等，见 C2 |
| svg-filter | 不修改输入 | `SvgFilterRenderer_test.deterministic` | 部分 | 只检查 source 首像素，未检查 filter/options |
| svg-filter | 缺失滤镜引用 | `SvgFilterRenderM3_test.missingFilterReference` | 通过 | 跳过 + warning |
| svg-paint-and-clip | 图案作为填充 | `SvgPatternSampler_test.tilePeriod` | 通过 | 四角取样 |
| svg-paint-and-clip | href 继承 | `SvgPatternSampler_test.hrefInheritance` | 通过 | 自身优先 |
| svg-paint-and-clip | 循环引用 | 同上 | 通过 | warning 不递归 |
| svg-paint-and-clip | tile 尺寸 | `SvgPatternSampler_test.unitsConversion` | 通过 | 0.5→50 |
| svg-paint-and-clip | patternTransform 旋转 | `SvgPatternSampler_test.patternTransform` | 部分 | 只断言“有别”，未验证 45° 方向 |
| svg-paint-and-clip | 裁剪到填充区域 | `SvgPatternSampler_test.clippedToFillRegion` | 通过 | 圆外 alpha 0 |
| svg-paint-and-clip | 空 tile | `SvgPatternSampler_test.tileLimits` | 通过 | 透明 + warning |
| svg-paint-and-clip | 超大 tile | 同上 | 通过 | 3000×3000 触发 Limit |
| svg-paint-and-clip | 渲染失败降级 | `SvgPatternSampler_test.contentFailureFallsBack` | 通过 | 缺 clip 引用 |
| svg-png | 最小 PNG | `SvgPngDecoder_test.minimalRgba` | 通过 | 1×1 RGBA |
| svg-png | 输入不被修改 | `SvgPngDecoder_test.inputImmutable` | 通过 | 两次一致 + 字节不变 |
| svg-png | 灰度展开 | `SvgPngDecoder_test.grayVariants` | 通过 | 1/2/4/8-bit |
| svg-png | 调色板 | `SvgPngDecoder_test.paletteAndTransparency` | 通过 | 4-bit 索引 |
| svg-png | tRNS | 同上 | 部分 | 只测 RGB/palette，未测灰度 tRNS |
| svg-png | Paeth 行 | `SvgPngDecoder_test.filterTypesRoundTrip` | 通过 | 整行 0–4 回环 |
| svg-png | Adam7 与非交错一致 | `SvgPngDecoder_test.adam7MatchesProgressive` | 通过 | 8×8 逐像素 |
| svg-png | 坏 CRC | `SvgPngDecoder_test.chunkStateMachine` | 通过 | Syntax |
| svg-png | 截断 IDAT | 同上 | 通过 | Syntax |
| svg-png | 缺 IEND | 同上 | 通过 | Syntax |
| svg-png | 解码炸弹 | `SvgPngDecoder_test.pixelLimits` | 部分 | 无 32 位乘积溢出用例，见 C3 |
| svg-png | RGBA 回环 | `SvgPngDecoder_test.encoderRoundTrip` | 通过 | 8×8 随机 RGBA |
| svg-png | 全透明保留 | 同上 | 通过 | (0,0,0,0) |
| svg-render-pipeline | data URI | `SvgImageRenderM3_test.dataUriDrawn` | 通过 | 中心红色 |
| svg-render-pipeline | provider 注入 | `SvgImageRenderM3_test.providerDrawnAndCached` | 通过 | 单次渲染缓存 |
| svg-render-pipeline | 未注入 provider | `SvgImageRenderM3_test.missingProviderPlaceholder` | 通过 | 透明 + warning |
| svg-render-pipeline | meet 映射 | `SvgImageRenderM3_test.preserveAspectRatioModes` | 通过 | 上下留白 |
| svg-render-pipeline | slice 映射 | 同上 | 通过 | 左右裁剪 |
| svg-render-pipeline | 顺序确定 | `SvgAnalyticRasterizer_test.combinedDeterminism` | **失败** | 只断言确定性；marker 未参与元素 filter，见 C1 |
| svg-render-pipeline | 文档只读 | `SvgRenderReadOnlyM3_test.documentReadOnly` | 通过 | 两次渲染前后快照一致 |
| svg-render-pipeline | 既有调用不变 | `SvgScene_test` 全部既有场景、`SvgFilterRenderM3_test.emptyFilterMatchesUnfiltered` | 部分 | 场景容差 1，无 M2 字节基线，见 W1 |
| svg-render-pipeline | 选项校验 | `SvgAnalyticRasterizer_test.samplesPerPixelIgnored` | 通过 | 1/4 采样输出一致 |
| svg-security | 外部 CSS 引用 | `SvgSecurity_test`（M2 既有） | 通过 | 移除 + warning |
| svg-security | 外部图片 | `SvgSecurity_test`、`SvgImageRenderM3_test.missingProviderPlaceholder` | 通过 | 不打开文件 |
| svg-security | 未注入图片资源 | `SvgImageRenderM3_test.missingProviderPlaceholder` | 通过 | 占位 + warning |
| svg-security | 注入 provider | `SvgImageRenderM3_test.providerDrawnAndCached` | 部分 | 未在同文档验证“其他 href 仍占位” |
| svg-security | 动画不执行脚本 | `SvgAnimation_test`（M2 既有） | 通过 | 忽略事件动画 |
| svg-security | 单图超限 | `SvgPngDecoder_test.pixelLimits` | 通过 | 25M/100M 像素 |
| svg-security | base64 超限 | `SvgImageResource_test.base64Limit` | 部分 | 用 max=3 自定义上限，未测默认 32 MiB |
| svg-security | 图案深度 | `SvgLimitsM3_test.patternDepthLimit` | 通过 | 70 链触发 Limit |
| svg-security | marker 截断 | `SvgMarkerExpander_test.markerLimits` | 通过 | 2000→1024 + warning |
| svg-security | 告警可审计 | `SvgLimitsM3_test.warningAudit` | 部分 | 只查关键词，未验证定位信息 |
| svg-security | 不中断渲染 | 同上 | 通过 | 位图非空 |
| svg-text | textPath 降级 | `SvgTextPathRender_test.textPathAndDegrade` | 通过 | 缺 href |
| svg-text | rotate 生效 | `SvgTextRotate_test.rotateLists` | 部分 | 只测 resolver 值，未测 3 字形落位 |
| svg-text | 水平路径 | `SvgTextPathLayout_test.horizontalPlacement` | 通过 | 中心 x=5/15 |
| svg-text | 百分比起点 | `SvgTextPathLayout_test.startOffsetForms` | 通过 | 50%→55 |
| svg-text | 切线角 | `SvgTextPathLayout_test.tangentAngle` | 通过 | 45° |
| svg-text | 文本溢出 | `SvgTextPathLayout_test.truncation` | 通过 | 2 字形 + warning |
| svg-text | 单值 | `SvgTextRotate_test.rotateLists` | 通过 | 全 15° |
| svg-text | 短列表复用 | 同上 | 通过 | 10/20/20/20 |
| svg-text | 与 textPath 叠加 | `SvgTextPathInteraction_test.rotateStacksOnTangent` | 部分 | 只断言像素不同，未验证 40° |
| svg-text | 降级不影响其他文本（补充） | `SvgTextPathInteraction_test.degradeDoesNotAffectOthers` | 通过 | 两段文本均有墨迹 |
| svg-rasterization | 高 DPI | `SvgViewport_test`、`SvgRenderer_test`（M2） | 通过 | 200×200 |
| svg-rasterization | 默认尺寸 | `SvgDocument_test` / `SvgRoot_test`（M2） | 通过 | 120×80 |
| svg-rasterization | 无尺寸根元素 | `SvgDocument_test`（M2） | 通过 | 300×150 |
| svg-rasterization | 非法采样数 | `SvgBitmap_test`（M2） | 通过 | InvalidValue |
| svg-rasterization | 新字段默认值 | `SvgValueTypesM3_test.renderOptionsDefaults` | 通过 | images None / Supersample |
| svg-rasterization | 斜边覆盖 | `SvgAnalyticRasterizer_test.diagonalCoverageConservation` | 部分 | Analytic 4×4，不是 samplesPerPixel=4 超采样 |
| svg-rasterization | 关闭抗锯齿 | `SvgRasterizer_test.antialiasing`（M2） | 通过 | 1 采样 0/1 |
| svg-rasterization | 解析档 | `SvgAnalyticRasterizer_test.circleMatchesSupersampling` | 部分 | 平均差 ≤2，不是逐像素 ≤2/255 |
| svg-rasterization | 覆盖率守恒 | `SvgAnalyticRasterizer_test.diagonalCoverageConservation` | 通过 | 1/255 |
| svg-rasterization | 圆的误差 | `SvgAnalyticRasterizer_test.circleMatchesSupersampling` | 部分 | 同上 |
| svg-rasterization | 自交 nonzero | `SvgAnalyticRasterizer_test.selfIntersectionRules` | 通过 | 中心实心 |
| svg-rasterization | 自交 evenodd | 同上 | 通过 | 中心空洞 |
| svg-rasterization | 组合确定性 | `SvgAnalyticRasterizer_test.combinedDeterminism` | 部分 | 缺描边、渐变、蒙版组合 |
| svg-marker | 缺省值 | `SvgMarker_test.typeAndDefaults` | 通过 | 默认 3 / 0 |
| svg-marker | 属性往返 | `SvgMarker_test.propertiesRoundTrip` | 通过 | set/get；往返另见 RoundTripM3 |
| svg-marker | start 与 end 对齐 | `SvgMarkerExpander_test.vertexDerivation` | 通过 | (0,0)/(10,0) |
| svg-marker | mid 顶点 | 同上 | 通过 | 仅 (5,5) |
| svg-marker | strokeWidth 缩放 | `SvgMarkerExpander_test.strokeWidthScaling` | 通过 | 4× |
| svg-marker | auto 起点反向 | `SvgMarkerExpander_test.orientations` | 通过 | 180° |
| svg-marker | 固定角度 | 同上 | 通过 | 45° |
| svg-marker | 数量上限 | `SvgMarkerExpander_test.markerLimits` | 通过 | 1024 + warning |
| svg-marker | marker 内裁剪 | `SvgMarkerClipM3_test.markerContentClipped` | 部分 | 仅 clipPath，未测 mask/filter |
| svg-marker | 缺失引用 | `SvgMarkerExpander_test.markerLimits` | 通过 | 不绘制 + warning |
| svg-value-types | 混合模式解析 | `SvgValueTypesM3_test.blendAndComposite` | 通过 | 枚举字符串 |
| svg-value-types | orient 角度 | `SvgValueTypesM3_test.markerEnums` | 通过 | Angle(45).toString=45 |
| svg-value-types | 未知值回退 | `SvgValueTypesM3_test.unknownEnumFallsBackWithWarning` | 部分 | 只测未被生产代码调用的 `fromNameOrWarn`；真实文档路径只由 Builder 泛化 warning 兜底 |
| svg-value-types | 单值标准差 | `SvgFilterPrimitive_test.gaussianBlur`、`SvgFilterChainM3_test.singleDeviation` | 通过 | x/y 同值 |
| svg-value-types | 矩阵值个数 | `SvgFilterPrimitive_test.colorMatrix` | 通过 | 10 值直通 + warning |
| svg-value-types | 负标准差 | `SvgFilterChainM3_test.negativeDeviation` | 通过 | 按 0 + warning |

### 2.3 上限负向用例矩阵

| 上限 | 规格值 | 现有负向用例 | 判定 |
|---|---|---|---|
| 单张解码图像素 | 16 MiB 像素 | `SvgPngDecoder_test.pixelLimits` 25M / 100M | 覆盖，但无 32 位乘积溢出（C3） |
| 单次渲染累计解码 | 64 MiB 像素 | `SvgImageResource_test.decodeBudget` 预算 5、`SvgPngDecoder_test.pixelLimits` 预算 3 | 只有资源/解码器单测，无 renderer 级累计超限 |
| base64 文本 | 32 MiB | `SvgImageResource_test.base64Limit` max=3 | 机制覆盖，默认 32 MiB 未测 |
| gzip 解压输出 | 64 MiB | `SvgGzip_test.decompressionLimit` max=16 | 机制覆盖 |
| 滤镜区域像素 | 同 `maxPixels` | `SvgFilterRenderer_test.regionLimit` | 覆盖，但检查晚于输出画布分配（W3） |
| pattern tile 像素 | 4 MiB | `SvgPatternSampler_test.tileLimits` 3000×3000 | 覆盖，但乘法溢出未测（C3） |
| pattern 引用深度 | 64 | `SvgLimitsM3_test.patternDepthLimit` | 覆盖 |
| marker 引用深度 | 64 | `SvgMarkerExpander_test.markerLimits` | 覆盖 |
| marker 数量 | 1024 | `SvgMarkerExpander_test.markerLimits` | 覆盖，warning 截断 |
| gzip 后元素数 | `maxElements` | `SvgGzip_test.decompressedStillBounded` | 覆盖 |
| gzip 后 maxDepth | `maxDepth` | 无 | **缺失** |
| pattern 内容自引用 | 循环 warning 停止 | 无（只测 href 循环） | **缺失**（C4） |
| marker 内容自引用 | 循环 warning 停止 | 无（只测 href 循环） | **缺失**（C4） |
| marker 内 mask/filter | 正常生效 | 只测 clipPath | **缺失** |
| image 的 mask/filter | 正常生效 | 只测 opacity/clipPath | **缺失** |
| 灰度 tRNS | 生效 | 未测 | **缺失** |
| 重复 IHDR / 非法 tRNS 长度 | Syntax | 未测 | **部分缺失** |
| `SvgPngDecoder.decode(stream)` | 入口存在 | 无测试 | **缺失** |
| 空 `filter` 属性 warning | 记 warning | 无测试，且代码不告警（W4） | **不符合** |
| 警告可定位 | 含元素/属性 | 只查关键词 | **部分缺失**（W21） |

## 3. Correctness（正确性）

### 3.1 CRITICAL

#### C1. 滤镜没有按元素级图层应用：组 filter 丢失、fill/stroke 双重滤镜、marker 不参与滤镜

**规格**
- `specs/svg-render-pipeline/spec.md:56-68`：展开顺序 SHALL 为 marker → pattern → 元素自身/marker 子内容 → **对元素内容应用 filter** → clipPath/mask/opacity。
- 同文件 `:70-73` Scenario：同一元素同时带 `filter`、`clipPath` 与 `marker-end` 时，**marker 参与滤镜输入**，滤镜结果再裁剪。
- `specs/svg-filter/spec.md:154-160`：`filter` 引用用于元素渲染。

**实现**
- `SvgRenderTree.cj:360-373`：`grouped` 只判断 opacity / clipPath / mask / clipRect，没有 filter；`GroupBegin` 构造也没有传 `filter`。
- `SvgRenderer.cj:105-117`：处理 `GroupBegin` 时只创建图层，从不应用 `command.filter`。因此 `<g filter="url(#f)">` **完全无效果**。
- `SvgRenderTree.cj:560-594`：同一 shape 的 FillPath 与 StrokePath 两条命令都带同一个 `filter`；`SvgRenderer.cj:145-174` 对每条命令各自建层并各自执行滤镜。带填充+描边的元素会被滤镜两次，结果与“元素内容整体滤镜”不同。
- `SvgRenderTree.cj:595-629`：marker 指令在 fill/stroke 之后作为兄弟指令追加，不在元素滤镜图层内，因此 marker 不会进入该元素的 filter 输入。

**测试**
- `SvgAnalyticRasterizer_test.cj:104-123` 的 `combinedDeterminism` 只断言两次渲染一致；其中 `<circle marker-end="url(#m)">` 本身不会产生 marker（`SvgMarkerExpander` 只支持 path/line/polyline/polygon），所以该用例连“存在 marker”都没有做到，更无法证明“marker 参与滤镜”。
- 没有 `<g filter>` 的像素用例，没有“fill+stroke+filter”的像素用例。

**影响**：常用 `<g filter>` 静默失效；填充+描边的滤镜结果错误；Scenario“顺序确定”不成立。

#### C2. `feTile` 在真实滤镜链中是恒等操作

**规格**
- `specs/svg-filter/spec.md:142`：`SvgFeTile` SHALL 以输入缓冲为一个 tile，在滤镜区域内平铺；输入尺寸为 0 时输出透明并记 warning。
- 同文件 `:149-152` Scenario：2×2 输入、6×6 滤镜区域，输出应按 2×2 周期重复。

**实现**
- `SvgFilterRenderer.cj:274-275`：`tileFilterBuffer(input, input.width, input.height)`。输出尺寸等于输入尺寸，循环 `x % input.width` 与 `y % input.height` 恒等于 `x` / `y`，结果与输入逐字节相同。
- `SvgFilterBuffer.cj:28-35` 明确拒绝 0 尺寸，因此“输入尺寸为 0 时输出透明并记 warning”在当前模型下不可达。

**测试**
- `SvgFilterPrimitive_test.cj:214-227` 只直接调用 `tileFilterBuffer(input, 6, 6)`，没有走 `SvgFilterRenderer.apply` 的真实缓冲链。测试通过不能说明 `feTile` 原语有效。

**影响**：M3-2 八种原语中 `feTile` 实际未实现；Scenario“平铺”属于“helper 级通过、管线级失败”。

#### C3. PNG 像素上限与 pattern tile 上限使用未防溢出的 Int64 乘法，可被绕过

**规格**
- `specs/svg-png/spec.md:85-94`：单张解码像素数超过 `16 × 1024 × 1024` 时 SHALL 在解压前抛 `SvgException(kind: Limit)`。
- `specs/svg-security/spec.md:47-59`：所有上限 SHALL 在分配缓冲或解压前检查。
- `specs/svg-paint-and-clip/spec.md:63`：tile 像素数超过 `4 × 1024 × 1024` 抛 `Limit`。

**实现**
- `SvgPngDecoder.cj:76-82`：
  - `let pixels = header.width * header.height;`
  - `if (pixels > SVG_MAX_IMAGE_PIXELS) ...`
  - `width` / `height` 由 `readU32BE` 读入，最大 0xFFFFFFFF；两者乘积可超过 Int64 上限并溢出。溢出为负/异常后，`Limit` 检查失效。
- `SvgBitmap.cj:93-100` 随后用 `width * height * 4` 分配像素；同样可能溢出。
- `SvgPatternSampler.cj:142-149` 也存在 `pixelWidth * pixelHeight > SVG_MAX_PATTERN_TILE_PIXELS` 的同类溢出。

**测试**
- `SvgPngDecoder_test.cj:435-454` 只覆盖 5000×5000 与 100000×100000，都没有触及 32 位无符号边界的乘积溢出。
- `SvgPatternSampler_test.cj:221-239` 只覆盖 3000×3000。

**影响**：恶意 PNG/pattern 可绕过解码炸弹上限，进入超限分配或在非 `Limit` 异常处失败，违反安全验收。

#### C4. pattern / marker 内容自引用没有跨渲染递归防护，可无限递归

**规格**
- `specs/svg-security/spec.md:76-82`：pattern / marker / gradient 的循环引用 SHALL 追加 warning 并停止展开，不抛异常。
- `specs/svg-paint-and-clip/spec.md:59-67`：pattern 引用深度超过 64 抛 `Limit`，子内容失败降级。

**实现**
- `SvgPatternSampler.cj:186-193`：每个 pattern tile 内部新建 `SvgRenderer(options: options)` 渲染内容。
- `SvgRenderer.cj:97-102`：每次 `renderDisplayList` 都新建 `SvgPatternSampler`，缓存是实例级的。
- 若 pattern 内容自身 `fill="url(#同一个pattern)"`，`drawPaint`（`SvgRenderer.cj:361-410`）会重新解析同一个 pattern，进入新的 sampler/renderer，没有任何共享 visited 集合或全局深度计数。
- marker 同理：`SvgRenderTree.cj:608-629` 每次展开新建 `SvgMarkerExpander`，marker 内容中的 shape 再带 `marker-*` 会再次进入 `addMarkers`。

**测试**
- `SvgLimitsM3_test.patternDepthLimit`、`SvgPatternSampler_test.hrefInheritance` 只覆盖 **href 链** 循环；`SvgMarkerExpander_test.markerLimits` 也只覆盖 marker href 链。没有“内容通过 fill/marker-* 指回自身”的用例。

**影响**：恶意或误写的 SVG 会导致栈溢出/无限渲染；与“循环引用只 warning 不递归”的安全契约相反。

#### C5. 空 `textPath` 路径不降级，所有字形被丢弃

**规格**
- `specs/svg-text/spec.md:14-18`：`href` 缺失、指向不存在元素、**或路径为空**时，内容 SHALL 降级为普通水平文本并记 warning。

**实现**
- `SvgTextRenderer.cj:246-265`：`resolveTextPathData` 对 `textPath path=""` / `d=""` 返回 `Some(SvgPathData([]))`；`SvgTextPathLayout.place` 在 `total <= 0` 时返回空数组并只写 warning。
- `SvgTextRenderer.cj:284-290`：只要 `placements` 是 `Some`，`index >= placed.size` 就 `continue`；`placements` 为空时所有字形都不绘制，不会回退到 `positions[index]` 的水平布局。

**测试**
- `SvgTextPathRender_test.textPathAndDegrade`（`SvgTextPathLayout_test.cj:164-213`）只覆盖 `href="#missing"`，没有覆盖 `path=""`、`d=""` 或零长度路径。

**影响**：空路径不是“降级为普通文本”，而是“文本完全消失”，直接违反 Scenario。

#### C6. 解析 AA 未按规格的“有符号面积累加”实现，复杂路径退化为 8×8 子采样

**规格**
- `specs/svg-rasterization/spec.md:72-90`：`Analytic` SHALL 把路径离散为设备空间线段，**每条线段按像素列累加有符号面积**；像素内外由 nonzero/evenodd 独立判定；覆盖率与 4× 超采样逐像素差 ≤ `2/255`。
- `design.md:150-158` D11 同样要求“按像素列累加有符号面积”。

**实现**
- `SvgAnalyticRasterizer.cj:100-108`：
  - 单轮廓且不自交：`clipToPixel` 后直接算多边形面积；
  - 其余（多轮廓/自交）：`inside * 65535 / 64` 的固定 **8×8 子采样**（`:109-133`）。
- 代码中不存在“按像素列累加有符号面积”的实现；复杂路径不是解析覆盖率，而是低档超采样。

**测试**
- `SvgAnalyticRasterizer_test.cj:40-59` 的“圆的误差”只断言 **全图平均通道差 ≤ 2.0**，不是规格要求的“对应像素通道差 ≤ 2/255”；这会把局部超差平均掉。
- `:28-37` 的斜边守恒只在 4×4 上检查两个像素；没有验证规格要求的 samplesPerPixel=4 超采样对比。

**影响**：M3-9 的核心算法与验收阈值没有落地；复杂自交路径的“解析 AA”名不符实。

#### C7. `SvgMarker` 的 `refX` / `refY` / `markerWidth` / `markerHeight` 公开类型与规格不符

**规格**
- `specs/svg-marker/spec.md:9-12`：`refX` / `refY` 为 `?SvgLength`（缺省 0）；`markerWidth` / `markerHeight` 为 `?SvgLength`（缺省 3）。

**实现**
- `SvgMarker.cj:151-187`：四个属性全部声明为 `SvgLength`（非可选），无法表达“属性缺失”与“显式 0/3”的区别。
- `SvgMarker_test.cj:36-39` 直接把 `refX == SvgLength(0.0)`、`markerWidth == SvgLength(3.0)` 固化为通过条件，测试与规格方向相反。

**影响**：公开 API 形状与主规格不一致；调用方无法判断属性是否存在，后续写出/继承逻辑也无法区分缺省与显式值。

### 3.2 WARNING

#### W1. “默认渲染输出与 M2 逐字节一致”没有可执行基线

- 规格 `specs/svg-rasterization/spec.md:17`、`specs/svg-render-pipeline/spec.md:91-94`、`README.md:191` 都声明逐字节一致。
- `SvgScene_test.cj:46-60` 的 `compareScene` 容差为 **1**，只比较差值 >1 的像素；M1/M2 场景即使整体漂移 1 也通过。
- M2 六个 `.rgba` 的 mtime 为 14:06（`text.rgba` 为 14:49，仍早于 M3 源文件 17:58），且测试全绿，这是“未发生明显漂移”的间接证据；但仓库没有 M2 位图哈希/字节基线，无法证明逐字节一致。
- 结论：**不能把“逐字节一致”判为已验证**；需要字节级基线或 `pixels ==` 的固定期望。

#### W2. `primitiveUnits` 被解析但从未参与滤镜计算

- `SvgFilter.cj:91-106` 提供 `primitiveUnits`；`SvgFilterRenderer.cj:184-278` 的原语执行只读取原始 `stdDeviation` / `dx` / `dy`，没有按 `objectBoundingBox` 缩放，也没有把 `primitiveUnits` 传给任何原语。
- 当 `primitiveUnits="objectBoundingBox"` 时，`feGaussianBlur`、`feOffset`、`feFlood` 的数值语义会错误。
- 没有对应测试。

#### W3. 滤镜区域上限检查晚于输出位图分配

- `SvgFilterRenderer.cj:88` 先 `let output = SvgBitmap(source.width, source.height)`，到 `:92` 才检查 `width > options.maxPixels / height`。
- 规格 `specs/svg-filter/spec.md:20` 要求“在分配缓冲前抛 Limit”；`README.md:197` 也写了“分配缓冲前”。
- 当前测试 `regionLimit` 只断言异常 kind，无法发现分配顺序问题。

#### W4. `filter` 属性为空时没有 warning

- 规格 `specs/svg-filter/spec.md:160`：`filter` 属性为空时 SHALL 跳过滤镜并记 warning。
- `SvgRenderTree.cj:668-691` 的 `resolveUrlRef` 在 `trimmed.size < 4` 或不是 `url(` 时直接 `return None`，不写 warning；`filter=""` 因此静默跳过。
- 没有测试。

#### W5. `feColorMatrix` 的类型/非有限值校验不完整

- `SvgBuilder.cj:494-531` 的 `isValidSvgAttribute` **没有 `type` 分支**，`<feColorMatrix type="bogus">` 不会在解析期产生 warning，`SvgFilterPrimitive.cj:460-475` 静默回退 `Matrix`。
- `SvgFilterPrimitives.cj:362-396` 只对 `Matrix` 检查 `NaN`/`Inf`；`Saturate` / `HueRotate` 的 values 非有限值没有 warning，直接参与计算。
- 现有 `colorMatrix` 用例只测 `Matrix` 值个数，不测上述路径。

#### W6. `linearRGB` 下 `feFlood` / `feMerge` 的常量颜色未线性化

- `SvgFilterRenderer.cj:99-112` 只在进入/离开链时对 `sourceBuffer` / `result` 做 sRGB↔linearRGB 转换。
- `SvgFilterPrimitives.cj:169-187` 的 `floodFilterBuffer` 直接把 `SvgColor` 的 sRGB 字节填入“线性”缓冲；`feMerge` 只是 over 合成，不会转换常量颜色。
- 结果是 `color-interpolation-filters="linearRGB"` + `feFlood` 的颜色与浏览器/规格不一致；无测试。

#### W7. 嵌套 pattern / marker 渲染重置了解码像素预算

- `SvgRenderer.cj:97-100` 每次 `renderDisplayList` 新建 `SvgDecodeBudget(64M)`。
- `SvgPatternSampler.cj:186-193` 为 tile 新建 `SvgRenderer`，因此 tile 内 `<image>` 的解码像素不计入外层渲染预算；递归图案可重复放大总解码量。
- 规格 `specs/svg-security/spec.md:54` 要求“单次渲染解码总像素 64M”。

#### W8. marker `href` 链只返回最深元素，不继承属性/内容

- `SvgMarkerExpander.cj:166-214` 的 `resolveMarker` 沿 `href` 走到最后一个 marker 后直接返回该元素；调用方 marker 自身的 `markerWidth`、`viewBox`、`refX`、子内容都被忽略。
- 规格只明确“引用链深度 64”，没有写 href 继承；但 `SvgMarker` 模型和 SVG 1.1 语义都依赖模板继承。当前实现会让 `<marker id="a" href="#base" viewBox="...">` 的自身属性失效。
- 无测试。

#### W9. `SvgMarkerExpander` 对 `path` 只处理第一个子路径

- `SvgMarkerExpander.cj:234-245`：`flattenPathData` 后 `return contour`（第一个非空 contour），后续子路径的顶点全部丢失。
- 规格 `specs/svg-marker/spec.md:28-35` 说“path 的扁平化顶点”派生 marker，多子路径应参与；现有测试只测单子路径 path。

#### W10. `rotate` 列表部分非法时整表丢弃

- `SvgTextElement.cj:280-299` 的 `tryParseSvgNumberArray` 是 all-or-nothing：任一值非法/非有限就返回 `None`。
- `SvgTextRenderer.cj:537-557` 收到 `None` 后写一条 warning，并把所有字形角度置 0。
- 规格 `specs/svg-text/spec.md:84` 要求“忽略该值，其余字形继续使用可解析值”。测试 `invalidRotate` 只覆盖全非法 `"abc"`，没有覆盖 `"10 bogus 30"`。

#### W11. PNG 未知关键 chunk 抛 `Unsupported`，不在规格枚举的错误分类内

- `SvgPngDecoder.cj:288-290` 对未知 critical chunk 抛 `SvgErrorKind.Unsupported`。
- 规格 `specs/svg-png/spec.md:9-13` 只列 `Syntax`（结构）、`InvalidValue`（不支持组合）、`Limit`（超限）；`Unsupported` 属于额外分类，调用方按规格 catch 不到。
- 无测试。

#### W12. PNG 结构校验与 tRNS 变体覆盖不全

- `SvgPngDecoder.cj:264-268` 对 `tRNS` 只存字节，不校验长度（灰度应 2、RGB 应 6、调色板应 ≤ 调色板项数；后者在 `:94-96` 校验）。
- 缺少重复 `IHDR`、`PLTE` 长度 0、调色板缺失 `PLTE`、`tRNS` 超长等用例；现有 `chunkStateMachine` 只测 CRC/截断/缺 IEND/IDAT 不连续/IHDR 非首。
- 规格 `specs/svg-png/spec.md:38-40` 要求相应结构错误抛 `Syntax`。

#### W13. pattern 内容单位与 userSpaceOnUse 百分比的坐标语义不完整

- `SvgPatternSampler.cj:166-170` 在 `patternContentUnits=objectBoundingBox` 时只做 `scale(boxWidth, boxHeight)`，没有平移 `objectBounds.x/y`；当包围盒原点非 0 时内容原点会偏移。
- `SvgPatternSampler.cj:273-310` 对 `userSpaceOnUse` 的百分比直接使用 `length.value`，没有按视口尺寸解释。
- `SvgPatternSampler_test.unitsConversion` 只使用 `(0,0,100,100)` 的包围盒，无法发现原点问题。

#### W14. `<image>` 占位的“透明”与 M2 兼容语义冲突

- 新规格 `specs/svg-render-pipeline/spec.md:19` 写“绘制透明占位”。
- `SvgRenderer.cj:249-264` 在 `options.background` 非空时用背景色填 `x/y/width/height`。
- 这与 M2 `specs/svg-render-pipeline/spec.md:114-116`（若设置 background 则使用背景色）和 proposal 的“未注入资源时仍按 M2 画占位”一致，但**新规格文本已删除该限定**。属于规格/实现文字漂移，归档前应统一。

#### W15. 21 个 Scenario 仅“部分覆盖”

见 §2.2 的“部分”行，汇总为：

- `svg-document-model`：纯文本不误判、截断 gzip（未直接验证 `parseAuto` 分支）。
- `svg-filter`：区域超限（未验证未分配）、隐式连接（缺 feBlend/in2）、未定义引用（未验证链继续）、不修改输入（只查 source 首像素）。
- `svg-paint-and-clip`：patternTransform 旋转（只比较“有差异”）。
- `svg-png`：tRNS（无灰度）、解码炸弹（无 32 位溢出）。
- `svg-render-pipeline`：既有调用不变（无字节基线）。
- `svg-security`：provider 注入（未验证其他 href）、base64 默认 32 MiB、告警可审计（只查关键词）。
- `svg-text`：rotate 生效（只测 resolver）、与 textPath 叠加（只比较“有差异”）。
- `svg-rasterization`：斜边覆盖（用 Analytic 而非 Supersample 4×4）、圆的误差（平均差而非逐像素）、组合确定性（缺描边/渐变/蒙版）。
- `svg-marker`：marker 内裁剪（仅 clipPath，未测 mask/filter）。
- `svg-value-types`：未知值回退（测试未被生产代码调用的 helper）。

#### W16. 上限负向用例仍有缺口

见 §2.3，重点缺口：

- 无 gzip 后 `maxDepth` 用例；
- 无 renderer 级 64M 累计解码用例；
- 无默认 32 MiB base64 用例；
- 无 0xFFFFFFFF 级 PNG 尺寸（C3）；
- 无 pattern/marker 内容自引用（C4）；
- 无 marker/image 的 mask/filter 组合；
- 无灰度 tRNS、重复 IHDR、PLTE 长度 0、tRNS 超长；
- 无 `SvgPngDecoder.decode(stream)`；
- 无空 `filter` 属性 warning（W4）；
- “所有上限在分配前”没有顺序断言。

#### W17. 任务/文档存在过度声明

- `tasks.md:4.7` 要求“解压后仍受元素数 / 深度上限约束”，实际只有 `maxElements` 用例（`SvgGzip_test.decompressedStillBounded`），没有 `maxDepth`。
- `tasks.md:6.7` 要求确认 image 的 `opacity/clipPath/mask/filter` 生效，测试 `opacityAndClip` 只覆盖 opacity/clipPath。
- `tasks.md:11.7` 要求 marker 的 `clipPath/mask/filter` 生效，测试只覆盖 clipPath。
- `tasks.md:12.7` 要求与描边、渐变、图案、滤镜、marker、裁剪、蒙版组合，`combinedDeterminism` 只覆盖图案/滤镜/marker/裁剪，且 marker 实际未生成（circle 不支持 marker）。
- `tasks.md:13.1` 要求逐条补负向用例，§2.3 仍有缺口。
- `tasks.md:15.7` 声称逐条核对 Scenario，但 21 个仅部分覆盖、2 个失败。
- `README.md:258` 声称“所有检查都发生在分配大缓冲之前”，与 W3 不符。
- `f_svg/doc/perf-baseline.md` 末尾写“461 条用例”，当前实际 466 条。

#### W18. `SvgPatternSampler.sample` 的 `transform` 参数除可逆性检查外未使用

- `SvgPatternSampler.cj:99-113`：`sample(pattern, objectBounds, transform, options)` 只用 `transform.invert().isNone()` 判断，随后完全忽略 `transform`，tile 的坐标映射由 `sampleTile` 和调用方 shader 完成。
- 公开 API 的 `transform` 参数语义不明确，调用方无法通过该参数控制 tile 映射；与规格给出的签名含义存在偏差。

#### W19. `userSpaceOnUse` 下滤镜区域百分比按数值解释

- `SvgFilterRenderer.cj:197-213` 的 `filterAxis` 在 `objectUnits=false` 时直接返回 `length.value`，`x="10%"` 被当作 10 用户单位，而不是视口百分比。
- 规格 `specs/svg-filter/spec.md:18` 只说 userSpaceOnUse 使用当前用户坐标，未细化百分比；但 SVG 1.1 的百分比语义应相对视口。无测试。

#### W20. `SvgPngDecoder.decode(stream)` 无上限地读完整流

- `SvgPngDecoder.cj:63-72` 循环读取 `InputStream` 到 `ByteBuffer`，在解码前没有总字节上限；超大输入可先耗尽内存。
- 规格 `specs/svg-png/spec.md:7` 只要求入口存在，未给字节上限；属于健壮性 WARNING。

#### W21. 部分 warning 缺少可定位信息

- 规格 `specs/svg-security/spec.md:89-102` 要求每条 warning 包含可定位的元素或属性信息。
- `SvgTextRenderer.cj:540` 的“文本 rotate 列表为空”与 `:555` 的“文本 rotate 的值不合法”没有元素路径/id；`SvgTextPathLayout.cj:102` / `:145` 的路径为空/截断 warning 也没有元素信息。
- `SvgLimitsM3_test.warningAudit` 只检查 `pattern` / `marker` / `image` 关键词，不检查定位信息。

#### W22. README 的 `SvgImageResourceProvider` 示例在默认安全策略下不可用

- README `f_svg/README.md:217-228` 直接构造 `SvgRenderOptions(images: Some(MemoryImages()))` 并渲染文档；但若文档由默认 `SvgParser.parse` 解析，`mem://logo` 会在 `SvgBuilder.cj:419-436` 被当作外部引用移除（默认 `allowExternalReferences=false`）。
- 示例没有说明需要 `SvgUnsafePolicy.Keep` 或 `allowExternalReferences=true`，照抄无法解析出 provider 请求。

## 4. Coherence（一致性）

### 4.1 SUGGESTION

#### S1. 清理 M3 骨架遗留 TODO / 未使用代码

- `SvgFilterPrimitive.cj:177`：`// TODO(M3-1/M3-2): 滤镜原语基类与八个 fe* 原语模型。`，但下方已完整实现。
- `SvgGzip.cj:96`：`// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。`，入口已在 `SvgParser.cj:71-92` 实现。
- `SvgAnalyticRasterizer.cj:45`：`// TODO(M3-9): 解析覆盖率光栅化。`，但下方已有实现。
- `SvgBlendMode.fromNameOrWarn` / `SvgCompositeOperator.fromNameOrWarn` / `SvgMarkerOrient.fromNameOrWarn` 在生产代码中没有调用；`SvgValueTypesM3_test.unknownEnumFallsBackWithWarning` 只测试这些死代码。建议要么接入模型/Builder，要么删除并在真实文档路径上补测试。

#### S2. 清理/落实占位 fixture 目录

- `f_svg/testdata/render/m3/README.md` 与 `f_svg/testdata/render/m3-negative/README.md` 仍写“占位”，但实际 M3 场景已直接放在 `testdata/render/m3-*.svg`。
- 建议删除这两个目录，或把实际负向 fixture 放进去并更新说明，避免后续维护者误判“M3 负向素材尚未生成”。

#### S3. 合并 `SvgRenderOptions` 的重复规格条目

- `specs/svg-rasterization/spec.md` 的 MODIFIED“渲染选项”新增 `images` / `antiAlias`；
- `specs/svg-render-pipeline/spec.md` 的 ADDED“渲染选项扩展”再次定义同一组字段。
- 归档后会形成两条描述同一公开类型的 Requirement，容易再次漂移。建议保留一条（渲染选项归 `svg-rasterization`，`svg-render-pipeline` 只引用）。

#### S4. 场景快照应改为只读并增加 M2 字节基线

- `SvgScene_test.cj:28-34` 在 `.rgba` 缺失时自动写入文件并让用例失败；建议缺失时直接失败，禁止测试运行时生成期望值。
- 为支撑“默认输出与 M2 逐字节一致”，建议为 M1/M2 六个场景保存字节哈希或直接 `pixels ==` 比较的基线，而不是仅容差 1。

#### S5. 在 `verification.md` / `tasks.md` 增加逐 Scenario 的真实判定

- 当前映射表只列“用哪个测试”，没有记录该测试是否真正覆盖 Scenario 的 THEN；21 个部分覆盖和 2 个失败无法从表中看出。
- 建议把 §2.2 的“判定/说明”列并入 `verification.md`，并修正 `tasks.md:15.7` 的“逐条核对”表述。

#### S6. 统一性能口径与测试数量

- `f_svg/doc/perf-baseline.md` 末尾写 461 条，实际 466 条；应更新。
- 同一文档明确写了“解析 AA 走逐像素精确裁剪、复杂自交路径退化为 8×8 子采样”，这与 `specs/svg-rasterization` 的“有符号面积累加”不一致；建议要么改规格/设计，要么按规格重写算法，避免文档与规格互相矛盾。

## 5. 分级统计

| 级别 | 数量 | 主要内容 |
|---|---:|---|
| CRITICAL | **7** | C1–C7 |
| WARNING | **22** | W1–W22 |
| SUGGESTION | **6** | S1–S6 |

## 6. 最后说明

- 本报告只读校验，未修改 `f_svg/src`、`f_svg/testdata`、`openspec/specs`，未归档、未提交；`cjpm test` 仅更新 `target` 缓存。
- 虽然 466 条用例全绿，但“全绿”不等于“规格全覆盖”：§2.2 的 2 个失败与 21 个部分覆盖、§2.3 的负向缺口，以及 C1–C7 都是当前测试没有暴露的契约问题。
- 若按本报告的严格口径，建议在归档前至少修复 C1–C7，并补齐 §2.3 中标为“缺失”的负向用例与 W1 的 M2 字节基线。

CRITICAL=7

## 6. 修复结果（本轮）

> 执行顺序：每项先写失败用例并确认失败原因，再写最小实现；全绿后独立提交。
> 本节编号沿用 `fix-plan.md` 约定，作为上面同名章节的追加复验结果。

| 编号 | 状态 | 修复内容 | 验证用例 |
|---|---|---|---|
| C1 | 已修复 | 渲染树把 fill/stroke/marker/组子内容包成元素级图层，滤镜在裁剪/蒙版/透明度前执行一次 | `SvgElementFilterM3_test`（组滤镜、fill+stroke、marker、组/子滤镜叠加） |
| C2 | 已修复 | `feTile` 按输入非透明内容尺寸平铺到滤镜区域；空输入透明 + warning | `SvgFilterTileChainM3_test` |
| C3 | 已修复 | PNG/位图/pattern 上限改为除法判定，32 位边界溢出不再绕过 `Limit` | `SvgOverflowM3_test` |
| C4 | 已修复 | 新增渲染会话级 `SvgRenderGuard`，嵌套渲染共享引用栈与解码预算；循环 warning，深度 65 抛 `Limit` | `SvgContentCycleM3_test`、`SvgNestedDecodeBudgetM3_test` |
| C5 | 已修复 | 空 / 零长度 textPath 路径降级为普通水平文本并 warning | `SvgTextPathEmptyM3_test` |
| C6 | 已修复 | 解析 AA 统一为逐扫描线按像素列累加覆盖，移除 8×8 子采样分支；nonzero/evenodd 独立判定 | `SvgAnalyticComplexM3_test`、`SvgAnalyticRasterizer_test` |
| C7 | 已修复 | `refX` / `refY` / `markerWidth` / `markerHeight` 改为 `?SvgLength`，使用处按 0/0/3/3 兜底 | `SvgMarker_test` |
| W1 | 已修复 | 增加 M1/M2 逐字节基线（容差 0）；快照缺失直接失败 | `SvgSceneByteBaseline_test` |
| W2 | 已修复 | `primitiveUnits=objectBoundingBox` 时缩放 stdDeviation / dx / dy | `SvgFilterPrimitiveUnitsM3_test` |
| W3 | 已修复 | 滤镜区域上限检查移到输出位图与区域缓冲分配之前 | `SvgFilterRegionOrderM3_test` |
| W4 | 已验证 | 空 / 非 `url()` 的 filter 值跳过并 warning（由属性校验路径提供） | `SvgFilterAttributeM3_test` |
| W5 | 已修复 | feColorMatrix 的 type 非法值解析期 warning；saturate/hueRotate 非有限值 warning + 直通 | `SvgColorMatrixValidationM3_test` |
| W7 | 已修复 | pattern tile / marker 嵌套渲染共享外层解码像素预算 | `SvgNestedDecodeBudgetM3_test` |
| W9 | 已修复 | marker 按 path 每个子路径的顶点派生 | `SvgMarkerSubpathM3_test` |
| W10 | 已修复 | rotate 列表逐项解析，非法项按 0 处理，其余项生效 | `SvgTextRotatePartialM3_test` |
| W11 | 已修复 | PNG 未知关键 chunk 归入 `Syntax` | `SvgPngChunkErrorM3_test` |
| W12 | 已修复 | 校验 tRNS 长度与颜色类型；补充重复 IHDR、空 PLTE、缺 PLTE 用例 | `SvgPngStructureM3_test` |
| W13 | 已修复 | patternContentUnits 内容平移到包围盒原点；userSpaceOnUse 百分比按视口解释 | `SvgPatternUnitsM3_test` |
| W14 | 已修复 | 规格与 README 统一 image 占位在设置 background 时使用背景色 | 文档（未改实现） |
| W17 | 已修复 | 补齐 gzip maxDepth、image/marker mask+filter、真实 marker 组合用例；修正 tasks/perf 口径 | `SvgGzipDepthM3_test`、`SvgImageEffectsM3_test`、`SvgMarkerEffectsM3_test`、`SvgAnalyticRasterizer_test.combinedDeterminism` |
| W19 | 已修复 | userSpaceOnUse 滤镜区域百分比按视口尺寸解释 | `SvgFilterPercentRegionM3_test` |
| W20 | 已修复 | `decode(stream)` 增加字节上限（默认 64 MiB），超限抛 `Limit` | `SvgPngStreamLimitM3_test` |
| W21 | 已修复 | 文本 rotate 与 textPath 类 warning 附带 `/svg[i]/...` 元素路径 | `SvgTextWarningLocationM3_test` |
| W22 | 已修复 | README provider 示例说明 `mem://` 需 `unsafePolicy: Keep` | 文档（中英文） |

### 6.1 复验数据

- `cjpm test`：**512 / 512 通过，0 skipped，0 error，0 failed**。
- `cjpm build`：成功；`f_svg/src` 自身 warning 数为 **0**（其余 warning 来自依赖模块）。
- 默认输出：`SvgSceneByteBaseline_test` 6 个 M1/M2 场景与既有 `.rgba` **逐字节一致**。
- 第 3 节记录不改项（W6、W8、W15、W16、W18 与 S1–S6 中未处理部分）**未改动**。
- 结论：本轮范围内 **CRITICAL = 0，选定 WARNING = 0**；剩余已知限制见第 3 节与上文 §2.2/§2.3。

CRITICAL=0
