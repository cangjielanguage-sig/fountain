# add-f-svg-m3 修复后复验报告（第二轮）

> 复验对象：`f_svg/doc/spec/add-f-svg-m3/verification.md` 第 6 节、`openspec/changes/add-f-svg-m3/specs/*`、`openspec/specs/svg-*` 主规格。
> 对照实现：`f_svg/src/*.cj` 与全部 `*_test.cj`、`f_svg/testdata/render/*`。
> 方式：只读静态核对 + 实际执行 `cjpm test` / `cjpm build`；未修改代码、未归档、未提交。

## 0. 结论摘要

- `cjpm test`：**512 / 512 通过，0 skipped，0 error，0 failed**；与 `verification.md` 第 6 节的 512 一致。
- `cjpm build`：成功；22 条 warning 全部来自 `f_xml` 等依赖模块，`grep f_svg/src` 为 **0**。
- 默认渲染回归：`SvgSceneByteBaseline_test` 的 6 个 M1/M2 场景以 **容差 0** 对既有 `.rgba` 快照逐字节比较，全部通过；6 个快照文件 mtime 仍为 14:06/14:49，未在 M3 修复期间改写。
- C1-C7：**已清除 5 项（C1、C2、C3、C5、C7），仍存在 2 项（C4、C6）**。
- 指定 WARNING：W1、W3、W4、W5、W7、W9、W10、W11、W12、W13、W20、W22 已落地；W2、W14、W17、W19、W21 仍有残留。
- 分级：**CRITICAL = 2（C4、C6），WARNING = 5 项未完全落地 + 若干新发现（见 §3）**。

## 1. C1-C7 逐条确认

| 编号 | 状态 | 核心理由 |
|---|---|---|
| C1 | 已清除 | 滤镜按元素级图层执行，marker 进入元素滤镜输入，fill+stroke 只执行一次 |
| C2 | 已清除 | `feTile` 在真实滤镜链中按非透明内容平铺，空输入透明 + warning |
| C3 | 已清除 | PNG/pattern/位图上限改为除法判定，32 位边界乘积不再绕过 `Limit` |
| C4 | **仍存在** | `SvgRenderer` 路径已共享守卫，但公开 `SvgPatternSampler.sample` 与 `SvgRenderTreeBuilder.build` 直接调用仍可在内容自引用时无限递归 |
| C5 | 已清除 | 空 path / 零长度路径降级为普通水平文本；但引入短路径全截断时的降级错误，见 §3 N1 |
| C6 | **仍存在** | 8×8 子采样已删除，但 D11/spec 要求的“按像素列累加有符号面积”仍未实现；现为 32 条 y 向子扫描线的近似，且 `circleMatchesSupersampling` 仍是全图平均差 |
| C7 | 已清除 | `refX` / `refY` / `markerWidth` / `markerHeight` 已改为 `?SvgLength`，使用处按 0/0/3/3 兜底 |

### C1. 元素级滤镜：已清除

- `SvgRenderTree.cj:392-393` 把 `filter` 纳入 `grouped`；`:423-440` 为组滤镜计算子命令并集包围盒；`:603-656` 对 shape 用 `appendFilteredGroupBegin` 把 fill / stroke / marker 包进同一图层；`:758-789` 对 image、`:336-366` 对 text 同样处理。
- `SvgRenderer.cj:143-178` 在 `GroupEnd` 先执行 `filters.apply`，再执行 `clipPath` / `mask` / 透明度；单条命令路径 `:190-204` 也保持 filter → clip/mask 的顺序。
- 用例证据：`SvgElementFilterM3_test` 的 `groupFilterApplies` / `fillAndStrokeFilteredOnce` / `markerParticipatesInFilter` / `groupAndChildFiltersStack` 全部通过；`SvgAnalyticRasterizer_test.combinedDeterminism` 现在使用真实 `path` + `marker-end`，能统计到蓝色 marker 像素。
- 结论：C1 的核心缺陷（组 filter 丢失、fill/stroke 双重滤镜、marker 不进入滤镜输入）已清除。

### C2. `feTile` 真实链平铺：已清除

- `SvgFilterPrimitives.cj:415-447` 的 `tileFilterBuffer` 以非透明内容包围盒为 tile，按 `positiveMod` 周期写入；`SvgFilterRenderer.cj:301-307` 在真实链中调用的是 `tileFilterBuffer(input, input.width, input.height)`，不再使用旧的身份式 `input.width/height` 作为 tile 尺寸。
- `SvgFilterTileChainM3_test.tileRepeatsAcrossRegion` 在 6×6 滤镜区域、2×2 红色输入的条件下逐像素断言 6×6 全红；`emptyTileWarns` 断言全透明 + warning，均通过。
- 说明：实现以“非透明内容包围盒”而非完整输入缓冲作为 tile，若输入包含透明 padding / 偏移，平铺相位与规格字面“输入缓冲”存在口径差异（见 §3 N3），但原 C2 的“真实链恒等”缺陷已消除。

### C3. 上限乘法溢出：已清除

- `SvgPngDecoder.cj:90-105` 先以 `width > 0x7FFFFFFF` / `width > SVG_MAX_IMAGE_PIXELS / height` 判定，再计算 `pixels`；`height` 在 `:276-278` 已保证为正，因此不会出现除零。
- `SvgBitmap.cj:94-101` 用 `2305843009213693951 / height` 在分配前阻止 `width * height * 4` 溢出。
- `SvgPatternSampler.cj:186-201` 先拒绝单边超过 4 MiB，再用 `pixelWidth > SVG_MAX_PATTERN_TILE_PIXELS / pixelHeight` 判定。
- `SvgOverflowM3_test` 的 `pngDimensionOverflow`（0xFFFFFFFF²、0x80000000²、0x7FFFFFFF²）、`bitmapAllocationOverflow`、`patternTileOverflow` 全部通过。

### C4. pattern / marker 内容自引用：仍存在

- `SvgRenderer.render` 路径：`SvgRenderer.cj:81-82` 把 `builder` 绑定到 `sessionGuard`；`:124-125` 把 guard 交给 pattern sampler；`SvgPatternSampler.cj:135-157` 在 `sampleTile` 进入/离开 `guard.enter/leave`；`SvgRenderTree.cj:705-727` 在 marker 展开时同样进入/离开。该路径的循环 warning 与 64 层 `Limit` 已被 `SvgContentCycleM3_test` 覆盖并通过。
- **公开 API 缺口**：`SvgPatternSampler.sample`（`SvgPatternSampler.cj:99-113`）是规格声明的公开入口，但没有 guard；它进入 `sampleTile` 后 `guard` 仍为 `None`，`sampleTileUncached` 在 `:246-254` 回退到 `SvgRenderer(options: options)`，该嵌套 renderer 在 `SvgRenderer.cj:66` 创建**新的** `SvgRenderGuard`，而不是共享外层。若 pattern 子内容 `fill="url(#同一个pattern)"`，每次递归都会得到新 guard，永不命中循环，也不累计深度，最终栈溢出。
- **公开 builder 缺口**：`SvgRenderTreeBuilder.build`（`SvgRenderTree.cj:180-216`）是 public，`guard` 只在 `SvgRenderer` 中通过 `attachGuard` 注入（`SvgRenderer.cj:81-82`）。直接调用 `build` 时 `addMarkers` 的 `this.guard` 为 `None`（`SvgRenderTree.cj:705-712`），marker 内容里的 shape 再带 `marker-*` 会反复 `buildContent`，同样无循环保护。
- 现有测试 `SvgContentCycleM3_test` 只走 `SvgRenderer.render`，未覆盖上述两个公开入口，因此不能判定 C4 已真正清除。

### C5. 空 textPath 降级：已清除

- `SvgTextRenderer.cj:268-272` 在 `placed.size == 0` 时不再设置 `placements`，因此 `:294-302` 的 `placements == None` 分支会使用水平 `positions`；`:273-274` 对 `resolveTextPathData` 返回 `None` 也降级。
- `SvgTextPathLayout.cj:100-104` 对零长度路径返回空数组并 warning。
- `SvgTextPathEmptyM3_test.emptyPathAttributeDegrades` 与 `zeroLengthPathDegrades` 均断言输出与普通文本逐字节一致且含“降级”warning，通过。
- 注意：`placed.size == 0` 同时也覆盖了“有效路径但所有字形都被截断”的情况，见 §3 N1。

### C6. 解析覆盖率：仍存在

- `SvgAnalyticRasterizer.cj:45` 仍保留 `// TODO(M3-9): 解析覆盖率光栅化。`。
- 实现 `:65-66` 定义 `ANALYTIC_SUB_SCANLINES = 32`；`:158-188` 对每条子扫描线收集交点的 x 跨度，再按像素列累加 `(right - left) * weight`。这不是 design.md D11 与 `specs/svg-rasterization/spec.md:76-81` 要求的“每条线段按像素列累加有符号面积”，而是“x 方向精确 + y 方向 32 条子扫描线”的近似超采样。
- 原 C6 的“复杂路径退化为 8×8 子采样”确实已删除；复杂/自交路径现在统一走 `analyticCoverage`，`SvgAnalyticComplexM3_test` 的甜甜圈/多轮廓以 128×128 密度参考逐像素 ≤2 通过。
- 但规格的验收口径仍未满足：`SvgAnalyticRasterizer_test.cj:39-59` 仍以“全图平均差 ≤ 2”而不是“对应像素通道差 ≤ 2/255”比较 Analytic 与 4× Supersample；`:28-37` 的斜边用例仍是 4×4 helper 级检查。`circleMatchesSupersampling` 没有证明规格要求的逐像素阈值。
- 结论：8×8 问题已消除，但“有符号面积累加”算法与规格验收阈值仍未落地，C6 不能判为已清除。

### C7. `SvgMarker` 公开类型：已清除

- `SvgMarker.cj:151-185` 四个属性均为 `?SvgLength`；`SvgMarkerExpander.cj:347-353` 使用 `?? SvgLength(3.0)` / `?? SvgLength(0.0)` 兜底。
- `SvgMarker_test.typeAndDefaults` 断言缺省时 `refX/refY/markerWidth/markerHeight` 均为 `None`；`explicitZeroIsNotAbsent` 断言显式 0 与缺省可区分；`defaultSizeUsedByViewBox` 验证缺省 3×3 的映射。测试通过。

## 2. WARNING 未完全落地项

| 编号 | 状态 | 说明 |
|---|---|---|
| W1 | 已落地 | `SvgSceneByteBaseline_test` 以容差 0 比较 6 个 M1/M2 场景，全部通过；快照 mtime 未变 |
| W2 | 部分未落地 | `primitiveUnits=objectBoundingBox` 的 stdDeviation/dx/dy 已按包围盒尺寸缩放，但未乘上 `transform` 的 CTM 缩放；测试只用 identity |
| W3 | 已落地 | 区域上限检查已移到 `SvgBitmap` 与 `SvgFilterBuffer.fromBitmap` 之前（`SvgFilterRenderer.cj:90-101`） |
| W4 | 已落地 | 空/非 `url()` 的 filter 由 `SvgStyleResolver` 的非法属性回退路径产生 warning；`SvgFilterAttributeM3_test` 通过 |
| W5 | 已落地 | `SvgBuilder.cj:534-539` 增加 feColorMatrix `type` 校验；`colorMatrixFor` 对 saturate/hueRotate 非有限值 warning + 直通；测试通过 |
| W7 | 已落地 | pattern tile 的嵌套 `SvgRenderer` 通过 `sessionImages` 共享 `SvgDecodeBudget`；`SvgNestedDecodeBudgetM3_test` 通过 |
| W9 | 已落地 | `SvgMarkerExpander.shapeContours` 对 path 返回所有非空子路径；`SvgMarkerSubpathM3_test` 断言 4 个 marker 通过 |
| W10 | 已落地 | `resolveTextRotations` 在结构化 `rotate` 解析失败时回退到 `parseLenientRotateList`，非法项按 0；`SvgTextRotatePartialM3_test` 通过 |
| W11 | 已落地 | 未知 critical chunk 抛 `Syntax`（`SvgPngDecoder.cj:319-324`）；`SvgPngChunkErrorM3_test` 通过 |
| W12 | 已落地 | tRNS 长度按颜色类型校验（`:117-130`），并补充重复 IHDR、空 PLTE、缺 PLTE；`SvgPngStructureM3_test` 通过 |
| W13 | 已落地 | `SvgPatternSampler.cj:223-230` 对 objectBoundingBox 内容加包围盒原点平移；`resolveAxis`/`resolveOrigin` 对 userSpaceOnUse 百分比用视口尺寸；`SvgPatternUnitsM3_test` 通过 |
| W14 | 未落地 | M3 delta 的 `specs/svg-render-pipeline/spec.md:19` / `:34` 仍只写“透明占位”，未写“设置 background 时使用背景色”；实现 `SvgRenderer.cj:293-304` 与 README `f_svg/README.md:238-239` 仍是背景色语义 |
| W17 | 部分未落地 | gzip maxDepth、image/marker 的 mask+filter、真实 marker 组合用例均已补；但 `tasks.md:13.1` 仍宣称逐条补齐负向用例，`tasks.md:15.7` 仍宣称逐条核对全部 Scenario，`verification.md` §2.2 也仍保留旧的“2 失败 / 21 部分”表，未与第 6 节同步 |
| W19 | 部分未落地 | `filterAxis` 的 userSpaceOnUse 百分比用 `source.width/height`（设备像素）求值（`SvgFilterRenderer.cj:229-232`），随后又对结果应用 `transform`（`:54-61`）；在 dpr≠1 或 viewBox 缩放时百分比会被二次缩放。`SvgFilterPercentRegionM3_test` 只用 identity |
| W20 | 已落地 | `decode(stream)` 默认 `SVG_MAX_PNG_STREAM_BYTES = 64 MiB`，超限抛 `Limit`（`SvgPngDecoder.cj:65-89`）；`SvgPngStreamLimitM3_test` 通过 |
| W21 | 部分未落地 | `SvgTextRenderer.cj:274` 的“路径缺失或为空”warning 仍未带 `${location}`；`SvgTextWarningLocationM3_test` 只用 `path=""`（走 `:269` 的带位置分支），未覆盖 `href="#missing"` |
| W22 | 已落地 | `f_svg/README.md:230-232` 与 `README_en.md:222-224` 已说明 `mem://` 需 `unsafePolicy: Keep` |

### W2 / W19 的量化说明

- 过滤器链的 `source` 是设备像素的全画布图层（`SvgRenderer.cj:130` / `:188`），`SvgFilterBuffer` 因此也是设备像素坐标。
- W2：`SvgFilterRenderer.cj:109-112` 只取 `objectBounds.width/height`（局部用户单位）作为 `primitiveScaleX/Y`，没有乘入 `transform` 的缩放；例如 dpr=2 或 viewBox 2× 时，`stdDeviation="0.1"` 的模糊半径会只有正确值的一半。
- W19：`filterAxis` 对 userSpaceOnUse 百分比返回 `value / 100 * source.width`，`source.width` 已是设备像素；`:54-61` 再应用 `transform`，导致 viewBox / dpr 下区域百分比二次缩放。现有测试都使用 identity，无法发现。

## 3. 新发现的 CRITICAL 与 WARNING

### CRITICAL

- 无“新类型”的 CRITICAL；但 C4、C6 是原 CRITICAL 未真正清除，仍计入 CRITICAL 总数（见 §4）。

### WARNING

1. **N1（C5 修复引入）短路径全截断被误判为“路径为空”**
   - `SvgTextPathLayout.place` 在“第一个字形的 advance 都放不下”或 `startOffset` 被钳制到路径末端时，会把 `result` 保持为空并仅记截断 warning（`SvgTextPathLayout.cj:132-145`）。
   - `SvgTextRenderer.cj:268-271` 用 `placed.size == 0` 判断“路径为空”，于是把上述合法但无字形可放的路径降级为完整水平文本，而不是按规格截断为空。这违反了 `specs/svg-text/spec.md:59` 的“截断后已排版字形保持原位置”。
   - 现有 `SvgTextPathEmptyM3_test` 只覆盖真正的空路径，没有覆盖“有效路径 + 短于首个字形”的用例。

2. **N2（C4 修复引入）`SvgRenderGuard` 异常路径不弹栈**
   - `SvgPatternSampler.cj:146-154` 与 `SvgRenderTree.cj:705-727` 都是 `enter` → 执行 → `leave`，没有 `try/finally`；若嵌套渲染抛 `Limit` / `SvgException`，栈不会回退。
   - 同一个 `SvgRenderer` 在捕获异常后再次 `render` 时，`sessionGuard` 仍保留旧栈，可能立即误报循环或错误地抛深度上限。现有测试每次新建 renderer，未覆盖复用场景。

3. **N3（C2 口径）`feTile` 以内容包围盒而不是完整输入缓冲为 tile**
   - `SvgFilterPrimitives.cj:415-447` 先用 `tileContentBounds` 取非透明内容包围盒，再以该宽高为周期；规格 `specs/svg-filter/spec.md:142` 写的是“输入缓冲为一个 tile”。
   - 当输入缓冲含透明 padding 或内容偏移时，实际平铺周期会变成内容尺寸而非输入缓冲尺寸；`SvgFilterTileChainM3_test` 的内容正好在 `(0,0)`，没有暴露这一点。

4. **N4（C1 边界）带滤镜的缺失字体文本可能整段消失**
   - `SvgGeometry.cj:765-777` 在 `layout.missingGlyph` 为真时返回 `None` 作为文本包围盒；`SvgRenderTree.cj:331-348` 把这个 `None` 传给滤镜组，`SvgFilterRenderer.cj:83-99` 在 objectBoundingBox 下得到空区域并返回全透明位图，随后组合成把文本（含占位字形）全部覆盖掉。
   - 未过滤时同一文本会绘制占位字形，因此存在“加 filter 后行为反而更差”的边界。

5. **N5（W17 文档一致性）`verification.md` 的旧 §2.2 与第 6 节结论冲突**
   - §2.2 仍列 `svg-filter` “平铺”失败、`svg-render-pipeline` “顺序确定”失败，以及 21 个部分覆盖；第 6 节却写“CRITICAL=0，选定 WARNING=0”。这不是代码问题，但会让归档前复核误判。

## 4. 回归检查

- `cjpm test`：512/512 通过；`SvgSceneByteBaseline_test` 的 6 个 M1/M2 场景全部按字节相等通过，`SvgScene_test` 的 basic / gradient / stroke / clip / text / animation 也全部通过。
- `SvgSceneM3_test` 的 5 个 M3 场景全部通过；`SvgElementFilterM3_test`、`SvgFilterTileChainM3_test`、`SvgOverflowM3_test`、`SvgContentCycleM3_test`、`SvgTextPathEmptyM3_test`、`SvgMarker_test` 等修复用例均实际执行并通过。
- 快照文件 `basic.rgba` / `gradient.rgba` / `stroke.rgba` / `clip.rgba` / `text.rgba` / `animation-*.rgba` 的 mtime 仍为 2026-11-05 14:06（`text.rgba` 为 14:49），未在 M3 修复期间改写；结合容差 0 用例，默认渲染逐字节一致得到直接证据。
- `cjpm build` 成功，`f_svg/src` 自身 warning 为 0（22 条 warning 均来自依赖模块）。
- 未发现 M1/M2 场景的像素漂移或既有测试回归。

## 5. 最终分级

- CRITICAL：**2**（C4：公开 sampler / builder 入口无跨渲染递归保护；C6：有符号面积解析 AA 未按规格实现）
- WARNING 未完全落地：**5**（W2、W14、W17、W19、W21）
- 新发现 WARNING：**5**（N1-N5，其中 N5 为文档一致性）

CRITICAL=2
