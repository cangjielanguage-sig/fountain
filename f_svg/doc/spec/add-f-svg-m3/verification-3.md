# add-f-svg-m3 第三轮只读终验报告

> 校验对象：`f_svg/doc/spec/add-f-svg-m3/verification.md` 第 6 / 7 节、`verification-2.md`、`openspec/changes/add-f-svg-m3/specs/*`、`openspec/specs/svg-*` 主规格、`f_svg/src/*.cj` 与全部 `*_test.cj`。
> 校验方式：只读静态核对 + 实际执行 `cjpm test` / `cjpm build`。未修改代码、未归档、未执行任何 git 写操作。

## 0. 结论摘要

| 项目 | 结果 |
|---|---|
| `cjpm test` | **525 / 525 通过，0 skipped，0 error，0 failed** |
| `cjpm build` | 成功；`f_svg/src` 自身 warning 为 **0**（构建日志只命中 `f_base` / `f_mockdb` / `f_version` 等依赖模块） |
| M1/M2 逐字节基线 | `SvgSceneByteBaseline_test` 6 个场景以容差 0 全部通过；快照 mtime 仍为 2026-11-05 14:06（`text.rgba` 为 14:49），未被改写 |
| C4 | **已清除** |
| C6 | **已清除** |
| N1、N2、N3、N4 | 已落地 |
| W2、W14、W19、W21 | 已落地（W21 的文本类缺口已补；同类 warning 定位仍有残留，见 NEW-W3） |
| W17 | 部分落地（`f_svg/doc` 副本已改；`openspec/changes` 副本仍是旧文本，见 NEW-W2） |
| C1、C2、C3、C5、C7 | 无回退 |
| 默认渲染逐字节一致 | 仍成立 |
| 新发现 CRITICAL | 0 |
| 新发现 WARNING | 4 |

## 1. 逐条确认

### C4（公开入口 guard）——已清除

**规格**
- `openspec/specs/svg-security/spec.md`：pattern / marker / gradient 循环引用 SHALL 只追加 warning 并停止展开；pattern / marker 引用深度 64。
- `openspec/changes/add-f-svg-m3/specs/svg-paint-and-clip/spec.md`：pattern 子内容失败应降级。

**实现**
- `SvgRenderGuard.cj:29-55`：渲染会话级引用栈，`enter` 命中循环返回 `false` 并 warning，深度达到 64 抛 `Limit`。
- 公开 `SvgPatternSampler.sample`（`SvgPatternSampler.cj:144-158`）→ `sampleTile`（`:160-182`）在无外部会话时 `ensureGuard()`（`:118-127`）自建守卫；`enter` / `leave` 用 `try { … } finally { … }` 配对（`:170-181`）。
- `sampleTileUncached` 把同一 guard 传给内容构建器与嵌套渲染器（`SvgPatternSampler.cj:255-276`），嵌套 pattern 的 `fill="url(#p)"` 会命中同一栈。
- 公开 `SvgRenderTreeBuilder.build` / `buildContent` / `buildElement`（`SvgRenderTree.cj:191-301`）均先 `ensureGuard()`；`addMarkers`（`:704-748`）对每个 marker 实例 `enter`，并在 `try/finally` 内调用 `buildContent`，嵌套 marker 复用同一 guard。
- `SvgRenderer.render` / `render(element,…)`（`SvgRenderer.cj:80-98`）把会话 guard 注入构建器；`renderDisplayList`（`:124-125`）把 guard 与解码预算交给 pattern sampler。

**用例**
- `SvgContentCycleM3_test.cj:67-113`：直接调用公开 `SvgPatternSampler.sample` 渲染自引用 pattern，返回 `None` 且含“循环”warning。
- `SvgContentCycleM3_test.cj:96-113`：公开 sampler 70 层合法链抛 `Limit`。
- `SvgContentCycleM3_test.cj:115-145`：直接调用公开 `SvgRenderTreeBuilder.build` 的自引用 marker 与 70 层 marker 链，分别 warning 与 `Limit`。
- `SvgContentCycleM3_test.cj:147-171`：一次 `Limit` 后复用同一 renderer 可继续正常渲染，无残留引用栈。

**判定**：两个公开入口均已接入共享守卫，C4 标识的“公开 API 可无限递归”缺陷已消除。

### C6（逐像素列有符号面积累加 + 64× 参考图）——已清除

**规格**
- `openspec/changes/add-f-svg-m3/specs/svg-rasterization/spec.md:72-85`：`Analytic` SHALL 用有符号面积累加计算覆盖率；每条线段按像素列累加；`nonzero` / `evenodd` 独立判定；与 64× 参考图逐像素通道差 ≤ `2/255`。
- 同文件 `:92-105`：圆的误差与自交 nonzero / evenodd 场景均以 64× 参考图为判据。

**实现**
- `SvgAnalyticRasterizer.cj:117-180`：把轮廓离散为设备空间有向边，逐行处理。
- `SvgAnalyticRasterizer.cj:182-238`：每行收集顶点 / 交点 y 事件并按 y 分割子区间，保证子区间内左右次序不变。
- `SvgAnalyticRasterizer.cj:240-290`：子区间内按 `nonzero` 绕数 / `evenodd` 配对独立判定内部区间。
- `SvgAnalyticRasterizer.cj:292-319`：对内部区间逐像素列累加面积。
- `SvgAnalyticRasterizer.cj:321-371`：`∫ clamp(x(y)-column,0,1) dy` 的分段精确积分（列内零 / 线性 / 全 1 三段），即逐像素列的有符号面积贡献。
- 代码中已无 `ANALYTIC_SUB_SCANLINES`、`inside * 65535 / 64` 或 8×8 子采样残留（`grep` 为 0）。

**用例**
- `SvgAnalyticRasterizer_test.cj:39-73`：`circleMatchesSupersampling` 使用同一扁平化几何的 **64× 参考图**（`denseContourCoverage`，`:234-325`），逐像素取最大差，断言 `worst ≤ 2`。
- `SvgAnalyticRasterizer_test.cj:27-37`：45° 斜边相邻像素覆盖率各约 0.5，和与 1 的误差 ≤ `1/255`。
- `SvgAnalyticRasterizer_test.cj:75-88`：高度 0.01 的细条仍得到 2–4/255 覆盖率，排除旧子采样近似。
- `SvgAnalyticRasterizer_test.cj:341-440`：甜甜圈 / 多轮廓 / 自交路径与 128× 或 64× 参考的逐像素差 ≤ 2（自交为总面积差 ≤ 3 px²，见 NEW-W1）。

**判定**：8×8 子采样已实际删除，现为按像素列的精确面积积分；64× 参考图的逐像素阈值在圆与多轮廓场景已通过。C6 的核心算法缺陷已消除。

### N1——已落地

- `SvgTextPathLayout.cj:74-76` 新增 `pathEmpty`，`:104-108` 仅在总弧长 ≤ 0 时置位。
- `SvgTextRenderer.cj:260-281`：`placed.size == 0 && count > 0` 时，`pathEmpty` 为真才降级水平文本；否则保持 `placements = Some(empty)`，字形被截断而不是整段回退。
- `SvgTextPathLayout_test.cj:317-356` `shortValidPathDrawsNothing`：有效短路径输出无可见像素、只有“截断”warning、无“降级”warning。
- `SvgTextPathLayout_test.cj:358-378` `startOffsetAtEndDrawsNothing`：`startOffset` 钳制到末端同样不降级。
- 与规格 `svg-text` “路径短于文本时截断，截断后已排版的字形保持原位置”一致。

### N2——已落地

- `SvgPatternSampler.cj:176-180`：`enter` 后使用 `try { sampleTileUncached } finally { leave }`。
- `SvgRenderTree.cj:729-743`：marker 展开同样 `try/finally`。
- `SvgContentCycleM3_test.cj:147-171` `guardRecoversAfterLimit` 覆盖“触发 Limit 后复用 renderer”，断言后续渲染正常且无循环 warning。

### N3——已落地

- `SvgFilterPrimitives.cj:416-441`：`tileFilterBuffer` 以 `input.width` / `input.height` 为 tile 周期，不再使用非透明内容包围盒。
- `SvgFilterRenderer.cj:322-328`：真实链调用 `tileFilterBuffer(input, input.width, input.height)`；空内容输出透明并 warning。
- `SvgFilterTileChainM3_test.cj:52-68` `fullBufferIsTilePeriod`：4×4 输入缓冲、2×2 非透明内容，9×9 输出在 (0,0)/(4,4) 有内容、(2,2)/(6,6) 透明，验证周期为完整缓冲而非内容。

### N4——已落地

- `SvgGeometry.cj:90-108` 新增 `renderBounds`：文本缺字时仍返回占位字形布局的包围盒；公开 `bounds` 的 `None` 契约未变（`SvgGeometry.cj:794-800`）。
- `SvgRenderTree.cj:346-351` 文本渲染改用 `renderBounds`。
- `SvgElementFilterM3_test.cj:105-130`：缺字文本带 `filter` 时仍有可见像素。

### W2——已落地

- `SvgFilterRenderer.cj:124-133`：`primitiveScaleX/Y = (objectBoundingBox ? 包围盒尺寸 : 1) × CTM 缩放分量`。
- `SvgFilterRenderer.cj:279-301`：`stdDeviation`、`dx/dy` 均乘该缩放。
- `SvgFilterPrimitive_test.cj:362-390` `primitiveUnitsMultiplyCtmScale`：identity 下偏移 1 px，`scale(2)` 下偏移 2 px，直接锁定 CTM 缩放。

### W14——已落地

- `openspec/changes/add-f-svg-m3/specs/svg-render-pipeline/spec.md:19` / `:34` 已改为“未注入资源绘制透明占位；设置 `background` 时按 M2 用背景色填充”。
- `f_svg/README.md:238-239` 同步。
- 实现 `SvgRenderer.cj:292-304` 与之一致。
- 主规格 `openspec/specs/svg-render-pipeline/spec.md:112-116` 保持 M2 语义，归档时由 delta 覆盖，口径一致。

### W17——部分落地

- 已落地部分：`f_svg/doc/spec/add-f-svg-m3/tasks.md:156`（13.1）与 `:181`（15.7）已改为“按 `verification.md` §2.2 判定列记录”；`f_svg/doc/spec/add-f-svg-m3/verification.md` §2.1 / §2.2 已加入“判定/说明”列（99 通过 / 14 部分 / 0 失败）；gzip `maxDepth`、image / marker 的 mask+filter、真实 marker 组合用例均已存在并通过。
- 未落地部分：`openspec/changes/add-f-svg-m3/tasks.md:156` / `:181` 仍是旧的“逐条补负向用例 / 逐条核对”表述；`openspec/changes/add-f-svg-m3/verification.md:1-5` 仍写“466 条用例全绿”，且无判定列。两份副本已经漂移（详见 NEW-W2）。

### W19——已落地

- `SvgFilterRenderer.cj:48-80`：`userSpaceOnUse` 百分比用 `transform.invert()` 得到的用户空间视口尺寸求值，再用 CTM 映射到设备坐标。
- `SvgFilterRenderer.cj:236-255`：`filterAxis` 只在 `objectUnits=true` 时叠加 `base + fraction × extent`，`userSpaceOnUse` 的百分比不再使用设备像素尺寸。
- `SvgFilterRenderer_test.cj:321-342` `userSpacePercentUsesUserViewport`：`scale(2)` 下 10% / 50% 得到 40 / 200，证明未二次缩放。

### W21——已落地（文本类）

- `SvgTextRenderer.cj:240-246` 构造 `location = "元素「${svgElementPath(...)}」"`；`:257-281` 的 textPath 缺失 / 空路径 warning 均带该前缀；rotate warning 通过 `prefix` 注入（`:539-553`）。
- `SvgTextPathLayout_test.cj:410-445`：`warningsContainElementPath` 与 `missingHrefWarningContainsLocation` 均断言 `/svg[1]/text[1]`。
- 遗留：新增的 `SvgRenderGuard` 循环 warning 与 marker 类 warning 仍只有类型 / id，没有元素路径（见 NEW-W3）。

### C1 / C2 / C3 / C5 / C7——无回退

| 编号 | 回归证据 |
|---|---|
| C1 | `SvgRenderTree.cj:411-412` 把 filter 纳入 `grouped`；`:442-460` 为组滤镜计算子命令并集包围盒；`:604-656` 把 fill / stroke / marker 包进同一 filter 图层；`SvgElementFilterM3_test.cj:42-103` 的组滤镜、fill+stroke 单次滤镜、marker 参与、组/子滤镜叠加均通过；`SvgAnalyticRasterizer_test.cj:134-162` 的 `combinedDeterminism` 现在使用真实 `path` + `marker-end` 并统计到 marker 像素 |
| C2 | `SvgFilterPrimitives.cj:416-441` 完整缓冲周期平铺；`SvgFilterTileChainM3_test.cj` 三个用例通过；空内容透明 + warning |
| C3 | `SvgPngDecoder.cj:90-100` 先做 `> 0x7FFFFFFF` 与 `MAX / height` 除法判定；`SvgBitmap.cj:94-98` 用 `2305843009213693951 / height` 防 `width*height*4` 溢出；`SvgPatternSampler.cj:211-226` 同样先除法判定；`SvgOverflowM3_test.cj:22-76` 覆盖 0xFFFFFFFF²、0x80000000²、0x7FFFFFFF²、位图与 pattern |
| C5 | `SvgTextRenderer.cj:257-281` 空 / 零长度路径降级；`SvgTextPathLayout.cj:104-108` 置 `pathEmpty`；`SvgTextPathEmptyM3_test` 的空 path、零长度路径、href 缺失用例全部通过 |
| C7 | `SvgMarker.cj:151-187` 四个属性均为 `?SvgLength`；`SvgMarkerExpander.cj:347-353` 用 `?? SvgLength(3.0)` / `?? SvgLength(0.0)` 兜底；`SvgMarker_test` 的缺省、显式 0、默认 3×3 用例通过 |

### 默认渲染逐字节一致——仍成立

- `SvgScene_test.cj:124-186` 的 `SvgSceneByteBaseline_test` 对 `basic` / `gradient` / `stroke` / `clip` / `text` 与 `animation-0/05/1` 使用容差 0 逐字节比较；快照缺失直接 `@Fail`，不会现场生成期望值。
- 本轮 `cjpm test` 中该测试全部通过；6 个 M1/M2 `.rgba` 的 mtime 仍为 14:06（`text.rgba` 14:49），早于本轮任何源码修改，未发生快照改写。

## 2. 新发现

### CRITICAL

无。

### WARNING

#### NEW-W1. C6 的两个“自交”Scenario 没有按新规格做逐像素 64× 比较

- 规格 `openspec/changes/add-f-svg-m3/specs/svg-rasterization/spec.md:97-105` 要求自交 nonzero / evenodd 均与 64× 参考图“逐像素通道差 ≤ `2/255`”。
- 实际用例：
  - `SvgAnalyticRasterizer_test.cj:90-114` `selfIntersectionRules` 只断言中心像素 `alpha > 0.5` / `< 0.1`；
  - `SvgAnalyticComplexM3_test.selfIntersectionAreaDiffers`（`:410-440`）只比较全图**面积总和**，容差 3 px²。
- `f_svg/doc/spec/add-f-svg-m3/verification.md:151-152` 仍将这两个 Scenario 记为“通过 / 中心实心、中心空洞”，`§2.1` 的 99 通过 / 0 失败因此对这两条是高估。
- 影响：算法本身已在圆 / 多轮廓上逐像素验证，但自交路径的规格判据没有直接证据；属于测试覆盖缺口，不构成算法失败。
- 建议：为五角星分别生成 64× reference，按 `worst ≤ 2` 断言，替换现有面积总和判据。

#### NEW-W2. 两套 tasks / verification 副本漂移，归档副本仍是旧结论

- `openspec/changes/add-f-svg-m3/tasks.md:156` / `:181` 仍是旧的“逐条补负向用例 / 逐条核对每个 Scenario”表述；`f_svg/doc/spec/add-f-svg-m3/tasks.md:156` / `:181` 已是“按 §2.2 判定列记录”。
- `openspec/changes/add-f-svg-m3/verification.md:3` 仍写“`cjpm test` 466 条用例全绿”，无判定列；实际本轮为 525 条，且判定列只在 `f_svg/doc` 副本。
- `f_svg/doc/spec/add-f-svg-m3/verification.md:8-18` 的 §0 结论摘要仍是首轮的“466 / 466、CRITICAL=7、失败 2、部分 21”，而同一文件 §5（`:507-511`）与 §7（`:594-602`）已写“CRITICAL=0、525 通过”；§0 未标注为历史章节，容易让归档复核误判。
- 影响：不是代码问题，但归档读取 `openspec/changes` 副本时会再次看到 W17 已修正的旧声明。建议统一为单一副本，或在两份都同步并给 §0 加“历史”标记。

#### NEW-W3. C4 guard 的循环 / 深度 warning 缺少可定位信息

- 规格 `openspec/changes/add-f-svg-m3/specs/svg-security/spec.md:102`：每条 warning SHALL 包含可定位的元素或属性信息。
- `SvgRenderGuard.cj:36` 只写 `"${kind} 存在内容自引用循环，已停止展开"`，`:42` 的 `Limit` 消息也只写 `${kind}`；`kind` 仅为 `pattern` / `marker`，没有 pattern id 或元素路径。
- `SvgLimitsM3_test.cj:87-117` 的 `warningAudit` 只检查 `pattern` / `marker` / `image` 关键词，无法发现定位信息缺失。
- 影响：安全审计方无法从 warning 直接定位到具体元素；同类问题在 `SvgMarkerExpander.cj:187`（“marker 引用存在循环，已停止展开”）也存在。
- 建议：`enter` 接收元素 id / 路径，warning 形如 `pattern「p1」...` 或附带 `svgElementPath`。

#### NEW-W4. 公开 `SvgPatternSampler.sample` 在多次调用间复用首次的图片 provider

- `SvgPatternSampler.cj:130-141` 的 `ensureImages(options)` 只在 `this.images == None` 时用当前 `options.images` 构造资源；之后无论传入什么 `options`，都复用第一次创建的资源。
- `sample` 是公开入口（`:144-158`），同实例第二次调用传入不同 `options.images` 时，新 provider 不生效；`guard` 同样跨调用复用（对守卫无害，但对 options 语义有影响）。
- 类注释说明实例生命周期为“一次 render”，因此这是公开 API 在跨 render 复用时的语义缺口，非渲染主路径缺陷。
- 建议：在文档中明确“每 render 新建实例”，或按 `options.images` 身份缓存资源。

## 3. 回归与基线明细

- `cjpm test`：525 / 525 通过；`SvgElementFilterM3_test`、`SvgFilterTileChainM3_test`、`SvgOverflowM3_test`、`SvgContentCycleM3_test`、`SvgTextPathEmptyM3_test`、`SvgTextWarningLocationM3_test`、`SvgFilterPercentRegionM3_test`、`SvgFilterPrimitiveUnitsM3_test`、`SvgMarkerSubpathM3_test`、`SvgMarkerEffectsM3_test`、`SvgImageEffectsM3_test`、`SvgGzipDepthM3_test`、`SvgAnalyticComplexM3_test` 均实际执行并通过。
- `SvgSceneByteBaseline_test` 6 个 M1/M2 场景容差 0 通过；`SvgSceneM3_test` 5 个 M3 场景通过。
- `cjpm build` 成功；构建日志中 `f_svg/src` 出现次数为 0，warning 全部来自依赖模块。
- 本轮未改代码、未改 `testdata`、未改 `openspec/specs`、未归档、未执行 git 写操作。

## 4. 最终分级

- **CRITICAL = 0**
- 新发现 WARNING = 4（NEW-W1 ~ NEW-W4）
- 原 C4、C6 已清除；C1-C3、C5、C7 无回退；N1-N4、W2、W14、W19 已落地；W17 部分落地；W21 的文本类已落地。

CRITICAL=0
