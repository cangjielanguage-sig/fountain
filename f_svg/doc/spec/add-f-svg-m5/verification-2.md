# add-f-svg-m5 修复后复验报告（verify-report-2）

- 复验对象：`openspec/changes/add-f-svg-m5` 的修复提交（`83ebf85d`、`ac149cc6`、`44ea4177`、`e71103da`、`4a54a0ad`、`cc2a04a3`、`ca72d35c`、`98580139`、`f72f24c1`）及其后续文档提交
- 复验基线：`feature/f_svg` @ `8555821b`（代码修复止于 `f72f24c1`，其后 `effce846` / `2a517e09` / `8555821b` 仅文档）
- 复验方式：只读审阅 + 全量测试 + 快照哈希复核；未改代码、未归档、未执行 git 写操作
- 说明：工作树 `.git` 指向 `/storage/...`（实际挂载为 `/mnt/linux_share/storage/...`），git 读取使用显式 `GIT_DIR` / `GIT_WORK_TREE` 完成，不改变工作树
- 对照材料：`f_svg/doc/spec/add-f-svg-m5/verification.md` §8、`fix-plan.md`、`openspec/changes/add-f-svg-m5/specs/*`、`openspec/specs/svg-*`、`f_svg/src` 全部实现与 `*_test.cj`

## 0. 门禁复核

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | `TOTAL: 987 / PASSED: 987 / SKIPPED: 0 / ERROR: 0 / FAILED: 0` | `f_svg/cjpm test`（2026-11-07 复跑） |
| 构建 | `cjpm build success`；`f_svg` 自身 **0 warning** | 全量重编译日志：22 条 warning 全部指向 `f_xml/src/*`，无一条指向 `f_svg/src` |
| 17 张 M1–M4 快照 | **17/17 SHA-256 与 `doc/perf-baseline.md` 一致** | 对 17 个 `.rgba` 重新 `sha256sum`；`5b7678bb..HEAD` 未修改这 17 个文件 |
| M5 快照改动 | 仅 `m5-shaping.rgba`/`.svg`/`README.md` 按 S3 更新 | `git diff --stat 5b7678bb..HEAD -- f_svg/testdata/render` |
| 基线表 | `doc/perf-baseline.md` 自 `878a35d8` 起未被修改 | `git log -- f_svg/doc/perf-baseline.md` |
| M1–M4 既有测试 | 未修改（diff 中无 M1–M4 测试文件） | `git diff --stat 5b7678bb..HEAD -- f_svg/src` |

结论：**测试数与快照门禁成立，未发现“先改旧快照再宣称零回归”**。以下规范性结论均建立在 987 条测试全绿的前提下，不能以“测试通过”替代规范符合度判断。

## 1. C1–C10 逐条复验

判定口径：

- **已清除**：原报告指出的可复现缺陷已消失，且规范主要语义有实现与测试落点；
- **部分清除**：原缺陷消失，但同一 Requirement 仍有场景无落点或无有效断言；
- **仍存在**：原缺陷仍可复现或修复未触及规范要求。

| 编号 | 结论 | 复核依据 |
|---|---|---|
| C1 | **已清除** | `SvgTransformBox.cj:19-54` 提供 `ViewBox`/`FillBox`、`Equatable`、`ToString`、大小写不敏感 `fromName`；`SvgComputedStyle.cj:368-370` 类型化 getter；`SvgStyleResolver.cj:752-755` 归一化；`SvgTransformBoxM5_test` 覆盖解析、往返、计算样式与非法值 warning。渲染/几何均从枚举取值（`SvgClipMask.cj:337`、`:485`，`SvgGeometry.cj:955`，`SvgRenderTree.cj:549`）。 |
| C2 | **已清除** | `SvgOpenTypeLayout.cj:99-143` 解析 ScriptList → FeatureList → LookupList，按 `kern` / `liga` 过滤；`SvgGposPairs.parse`（`:255-295`）与 `SvgGsubLigatures.parse`（`:515-554`）只使用特性引用的 lookup；`SvgTrueTypeFont.cj:283-295` 在 GPOS 不存在时回退 kern 表。用例：`SvgGposM5_test.otherFeatureIsIgnored`、`SvgGsubM5_test.otherFeatureIsIgnored`、`SvgKerningLayoutM5_test.gposWithoutKernFallsBackToKern` / `gsubWithoutLigaDoesNotApply` 均存在且通过。 |
| C3 | **已清除** | `SvgGposPairs.adjust`（`SvgOpenTypeLayout.cj:234-253`）在 class matrix 路径先检查 `covered`；`parseGposPairSubtable` 仅把 Coverage 内左字形写入 `covered`（`:375-377`）。测试已改为 `adjust(9, 2) == 0`（`SvgOpenTypeLayoutM5_test.cj:219`），不再把错误行为固化为期望。 |
| C4 | **部分清除** | 原缺陷（未注册目标静默回退首个 family）已消除：`SvgFont.cj:60-80` 在 `!base.hasFamily(name)` 时只记 warning、不建别名；`CssFontAliasM5_test.missingTargetDoesNotUsePrimaryFamily` 覆盖默认注册表场景。**但**同 Requirement 的「别名指向已注册字体」场景（`openspec/changes/add-f-svg-m5/specs/svg-css/spec.md:216-219`：注册表有 `Brand`，`@font-face { font-family: Body }`，文本用 `Body` 应得到 `Brand`）仍无落点：`derived` 只建立 `Body → Body` 自映射（`SvgFont.cj:77`），没有任何 `Body → Brand` 的目标推导；`CssFontAliasM5_test.aliasHitsRegisteredFamily` 先注册 `Body` 再声明 `Body`，即使删除别名逻辑也会通过，属自证测试。详见 N1。 |
| C5 | **已清除** | `x/y/width/height/cx/cy/r/rx/ry` 已进入 `SVG_PROPERTY_TABLE`（`SvgComputedStyle.cj:117-125`）；`cssCalcAppliesTo` 覆盖这些属性（`SvgStyleResolver.cj:806-812`）；`CssGeometryCalcM5_test` 4 条用例覆盖 `width: calc((10px + 5px) * 2)`=30、`x: calc(10% + 5px)`、非法 calc 回退与渲染读取。但混合单位语义与 delta 规范冲突，见 N5。 |
| C6 | **已清除（形式）** | 新增 `CSS_GSUB_MAX_DEPTH = 8`（`SvgOpenTypeLayout.cj:23`），`cssLayoutLookupRefs` 在 `depth > 8` 时丢弃并 warning（`:129-135`）；`SvgGsubM5_test.lookupDepthLimit` 覆盖“深度 8 正常、9 停止”。**语义保留**：这里的 depth 是 FeatureList 中 lookup 的**序号**，不是 OpenType 链式 lookup 的嵌套深度；测试 `m5GsubChain` 构造的是 9 个并列 lookup（`SvgOpenTypeLayoutM5_test.cj:174-191`），与规范“lookup 链深度”（`svg-text/spec.md:126-129`）不同构。见 N6。 |
| C7 | **已清除** | 形状 Fill/Stroke 命令不再携带 blend（`SvgRenderTree.cj:896-940` 均未传 `blendMode`）；元素级 `GroupBegin` 携带 blend（shape `:869-882`、text `:492-505`、image `:1154-1167`）；`SvgRenderer.cj:199-204` 在 GroupEnd 只合成一次。用例：`SvgElementBlendM5_test.shapeBlendIsGrouped` / `textBlendIsGrouped` / `paintOrderBlendsOnce` / `multiCommandShapeMatchesGroupReference` / `textMatchesGroupReference`。`<use>` 的元素样式仍未接线，见 N7。 |
| C8 | **已清除** | `applyFontLigatures` 标记 `consumed`（`SvgTextRenderer.cj:1630-1634`）；主流程在字距/定位前过滤被消费字符（`:411-434`），因此其 `x/y/dx/dy` 不再推进笔位、不计字距；`textLength`/`text-anchor`/后续字形只按簇首计算。用例：`ligatureReplacesAdvance`（`glyphs.size == 1`）、`ligatureConsumesDxList`（dx="5 9" 只加 5）、`ligatureConsumesXList`、`ligatureConsumesRotateList`。 |
| C9 | **已清除** | 顺序为 `applyFontLigatures`（`:410`）→ 过滤消费字符 → `applyFontKerning`（`:436`）→ `shouldReorderBidi`/`bidiArrangement`（`:438-469`）。镜像后按新码点重取字形（`:446-468`）。用例：`ligatureAppliedBeforeBidi`、`kerningUsesShapedGlyphs`。 |
| C10 | **已清除（列举路径）** | `SvgClipMask.cj:352-360`、`:501-508` 的 clipPath/mask 子元素改用 `effectiveElementTransform`；`SvgRenderTree.cj:267-274`（root）、`:648-654`（嵌套 svg）、`:789-796`（use 目标）、`:453-460`（text）、`:563-570`（container）均传 style/bounds；`SvgElementApi.cj:192-205` 容器子变换、`:301-320` CTM 使用样式上下文。用例：`SvgTransformPathM5_test` 4 条 + `SvgBBoxM5_test.containerChildTransformOrigin`。保留缺口见 N8/N9。 |

## 2. W1–W6 / W9 / W10 / W11 / W14 落地情况

| 编号 | 结论 | 复核依据 |
|---|---|---|
| W1 | **落地** | `SvgFontKerning` 已是枚举（`SvgBidi.cj:83-113`）；`SvgGeometry.screenCTM` 增加 `styles!` 重载（`SvgGeometry.cj:244-252`）；用例 `SvgDirectionM5_test.enumParsing`、`SvgTransformPathM5_test.screenCtmAcceptsStyles`。旧重载的视口传递问题见 N3。 |
| W2 | **落地** | `SvgContextPaint.cj:20-60` 已是实际实现，迁入 `useContextFrame` / `resolveContextPaintOf`，不再是 TODO 骨架。 |
| W3 | **落地** | `normalizeCssPaintOrder`（`SvgPaintOrder.cj:117-123`）委托 `SvgPaintOrder.parse` 逐项丢弃未知关键字并 warning；`SvgPaintOrderM5_test.unknownKeywordIsDroppedInComputedStyle` 断言 `stroke shadows fill` → `stroke fill markers`。 |
| W4 | **落地** | 负 `stdDeviation` 回退 2 且滤镜区域同步（`SvgFilterPrimitives.cj:505-515`、`SvgFilterRenderer.cj:434-440`）；非法 `flood-color` 回退黑色 + warning（`SvgFilterPrimitives.cj:520-535`）；用例 `negativeDeviationFallsBackToDefault` / `invalidFloodColorFallsBackToBlack` 为像素级等价断言。 |
| W5 | **基本落地** | `applyBBoxClip` 处理根视口与嵌套 svg（`SvgElementApi.cj:251-286`）；`nestedSvgClipRect` 使用 `viewBox` 宽高（`:288-298`）；`display:none`/`visibility:hidden`（`:130-132`、`:151-153`）；use 循环保护（`:213`）、symbol 目标（`:225-229`）、子变换走 `effectiveElementTransform`（`:192-205`）；用例 `SvgBBoxM5_test` 5 条。缺口：嵌套 `viewBox` 的 `min-x`/`min-y` 未参与裁剪，见 N4。 |
| W6 | **落地** | `unicode-bidi: embed` 产生更高嵌入层级（`SvgTextRenderer.cj:1445-1450`）；tspan 的 `direction`/`unicode-bidi` 进入 `SvgTextChar`（`:207`、`:224`）；`B` 分段（`:1467-1489`）；竖排列序由 `direction` 决定（`:554-564`）；rotate 绑定逻辑字符（`:157-166` + bidi 排列）。用例：`tspanDirectionRtl`、`embedCreatesLayer`、`paragraphBreakSegmentsBidi`、`verticalColumnOrderFollowsDirection`、`rotateFollowsLogicalCharacters`、`directionDoesNotChangeGeometry`。注：`embed` 是“元素级层级近似”，非完整 UAX#9 层栈；在 M5 的子集声明内可接受。 |
| W9 | **落地** | `componentCount > CSS_GSUB_MAX_INPUT`（`SvgOpenTypeLayout.cj:598-601`）严格拒绝 5 个输入；`applyFontLigatures` 的 `runEnd` 在字体/字号/字重/字形样式变化处截断（`SvgTextRenderer.cj:1604-1615`）。用例：`SvgGsubM5_test.inputLimit`、`SvgKerningLayoutM5_test.ligatureDoesNotCrossTspanBoundary`。 |
| W10 | **落地（主矛盾已消）** | `f_svg/README.md:334-337` 的 M4 限制段已改为“M5 起解析 kern/GPOS/kern 特性与 GSUB liga”；`:529-539` 与 `README_en.md:572-573` 的能力描述与实现一致；`:586` 的“M3 不做什么”已加 M5 支持说明。遗留：元素级 API 代码块未同步新增的 `mediaWidth`/`mediaHeight`（`README.md:552-556`、`README_en.md:592-594`），见 N10。 |
| W11 | **未完全落地** | 已修的两处：`openspec/specs/svg-css/spec.md:12` 已把 `@media`/`@font-face`/属性选择器/伪类/兄弟组合器列入支持；`openspec/specs/svg-text/spec.md:145` 已改为“M5 起支持基础双向文本与标准连字”。**但**：① `openspec/specs/*` 仍没有 M5 的 `SvgTransformBox`、calc、连字/字距、mix-blend-mode 等 Requirement（`grep SvgTransformBox openspec/specs` 无结果），与 delta 规范不是“三方一致”；② 主 `svg-css` 自身新矛盾：`:12` 声称支持 `@media`，`:25-28` 的「跳过不支持构造」场景仍断言 `@media` 被跳过并 warning。`verification.md` §8.2 声称“主规格与 M5 行为同步”不成立。 |
| W14 | **落地** | `getBBox` / `getCTM` / `getScreenCTM` 增加 `mediaWidth` / `mediaHeight`（`SvgElement.cj:333-377`、`SvgElementApi.cj:301-352`）；`absoluteBounds` 增加真实视口参数（`SvgGeometry.cj:82-102`）；用例 `SvgBBoxM5_test.bboxMediaWidth` / `ctmUsesViewportFallback` / `absoluteBoundsUsesViewport`。旧 `SvgGeometry.screenCTM` 重载的视口缺口见 N3。 |

**WARNING 未落地项（按本轮 fix-plan 第 2 节口径）**：

- W11：仅做了两处文字修正，主规格未同步 M5 能力，且 `svg-css` 主规格内部仍自相矛盾。
- W5 / W10 / W14：主体落地，但分别存在 `viewBox min-x/min-y`、README API 签名、`screenCTM(styles)` 视口传递的边界缺口（详见第 3 节）。

## 3. 新发现的问题

### CRITICAL

#### N1. `@font-face` 跨 family 别名仍未实现，规范场景无落点且测试自证

- 规范：`openspec/changes/add-f-svg-m5/specs/svg-css/spec.md:216-219` 明确要求：注册表已注册 `Brand`，声明 `@font-face { font-family: Body; src: url(x.ttf) }`，文本 `font-family="Body"` 时使用 `Brand` 的字体渲染。
- 实现：`SvgFontRegistry.derived`（`SvgFont.cj:60-80`）只在 `base.hasFamily(name)` 为真时执行 `result.aliases[name] = name`，即**把 family 映射到自身**；当 `Brand` 存在而 `Body` 不存在时直接 warning 并跳过，没有任何 `Body → Brand` 的目标推导。`expandUse`/`SvgTextRenderer` 也没有其他别名来源。
- 后果：`@font-face` 对字体选择是**功能性 no-op**——声明 `Body` 且注册表恰有 `Body` 时结果与不声明完全相同；注册表只有 `Brand` 时规范场景失败。这与 fix-plan C4 的验收点“`Body → Brand` 仅在 Brand 存在时生效”直接冲突。
- 测试盲区：`CssFontAliasM5_test.aliasHitsRegisteredFamily`（`CssFontAliasM5_test.cj:53-64`）先 `register("Body")` 再声明 `family: Body`，删除别名代码后仍通过；仓库内无任何 `Brand` 用例（`grep Brand f_svg/src/*_test.cj` 只命中变量名）。
- 结论：C4 的“未注册目标回退首个 family”原缺陷已消除，但该 Requirement 的别名主场景仍无实现/无有效测试，按规范口径计为 CRITICAL。

### WARNING

#### N2. 主规格与 delta 规范仍不同步，`svg-css` 主规格新引入自相矛盾

- `openspec/specs/svg-css/spec.md:12` 已声明支持 `@media`，但 `:25-28` 的场景仍写“输入 `@media screen {...}` → 结果只含 `rect { fill: blue }`，warnings 含 `@media`”。
- `openspec/specs/svg-value-types/spec.md`、`svg-text` 等主规格仍无 `SvgTransformBox`、calc 几何属性、GSUB/GPOS 等 M5 Requirement；`verification.md` §8.2 的“主规格同步”表述超出事实。
- 影响：归档前若以主规格为唯一事实源，会得到与实际行为相反的结论。属 W11 未完成部分。

#### N3. `SvgGeometry.screenCTM(element, viewport, styles)` 解析 `view-box` 百分比原点时未传视口尺寸

- `SvgGeometry.cj:244-252` 的 `screenCTM` 调用 `ctm(element, styles: styles)`，未传 `viewportWidth`/`viewportHeight`；`ctm` 内因此使用默认 `300 × 150`（`SvgGeometry.cj:213-217`）。
- 当 `transform-box: view-box`、`transform-origin: 50% 50%` 且根尺寸不是 300×150 时，该重载返回的矩阵与 `getScreenCTM`（`SvgElementApi.cj:341-351` 正确传了 width/height）不一致。
- 现有 `SvgTransformPathM5_test.screenCtmAcceptsStyles` 使用 `fill-box`，绕开了该差异，属弱覆盖。
- 影响：W1 新增的公开重载在 `view-box` 百分比原点场景返回错误矩阵；`getScreenCTM` 路径正常。

#### N4. `getBBox(clipped: true)` 嵌套 `svg` 的 `viewBox` 裁剪忽略 `min-x` / `min-y`

- `SvgElementApi.cj:288-298` 的 `nestedSvgClipRect` 只取 `viewBox.width` / `height`，返回 `SvgBounds(0, 0, width, height)`；`viewBox="10 10 100 100"` 时正确裁剪矩形应为 `(10, 10, 100, 100)`。
- 现有 `SvgBBoxM5_test.nestedViewBoxClip` 只覆盖 `viewBox="0 0 100 100"`，无法发现。
- 影响：W5 的嵌套视口裁剪在非零 `min-x/min-y` 时偏移；`<view>` 类元素也未纳入裁剪链。

#### N5. 几何属性的 `calc()` 允许 `% + px` 混用，与 delta 规范“混合单位无效”冲突

- delta `svg-css/spec.md:268` 规定“混合百分比与绝对长度 SHALL 使表达式无效”；但 `SvgStyleResolver.cj:484-491` 对 `x/y/width/height/...` 提供 `mediaWidth/mediaHeight` 作为百分比参考，`CssCalc.cj:225-231` 在 `percentReference` 存在时把 `%` 直接换算为绝对像素，从而 `calc(10% + 5px)` 合法（`CssGeometryCalcM5_test.percentageCalcUsesViewportWidth` 断言 25）。
- 这不是回归（原实现不支持几何 calc），但修复引入的新行为与规范文字冲突；同时 `mediaWidth` 是渲染选项宽度，嵌套 svg 内的 `%` 仍按外层宽度而非父视口宽度解析。
- 影响：规范需明确“几何属性是否允许混合单位”，否则同类用例无法同时成立。

#### N6. C6 的“深度”是 FeatureList 中的 lookup 序号，不是 lookup 链深度

- `cssLayoutLookupRefs` 用 `position + 1` 作为 depth（`SvgOpenTypeLayout.cj:129-135`），`m5GsubChain` 构造的是 9 个并列 lookup（`SvgOpenTypeLayoutM5_test.cj:174-191`）。
- 规范 `svg-text/spec.md:126-129` 与 `svg-security/spec.md:44-47` 写的是“lookup 链深度为 9”。当前实现并未解析链式上下文 lookup（Type 5/6 本身不处理），因此该测试证明的是“特性引用第 9 个 lookup 被丢弃”，不是“第 9 层嵌套 lookup 停止替换”。
- 影响：安全上限的入口存在，但测试与规范语义不同构；后续若支持链式 lookup，需重做深度模型。

#### N7. `mix-blend-mode` 未覆盖 `<use>` 元素（其样式效果整体未接线）

- `SvgRenderTree.cj:431-433` 对 `SvgUse` 直接 `expandUse`，`expandUse`（`:700-820`）只应用 `x`/`y`/目标变换，从未读取 use 自身的 `style`，因此 `<use style="mix-blend-mode: multiply">`、`opacity`、`clip-path`、`mask` 均不生效。
- 这是 M4 既有的样式处理缺口，不是本次修复引入；但 C7 的规范文字是“元素级”而非“形状/文本/image”，`verification.md` §8.1 的“覆盖形状、文本、image”也未包含 use。
- 影响：C7 对 use 类型仍不符合 M5 文字；建议在验证报告中明确 M5 的适用元素集合，或补 use 的元素级 GroupBegin。

#### N8. `getCTM` 对容器/文本的 `fill-box` 与原点的解析与渲染路径不一致

- `SvgGeometry.ctm` → `elementMatrix`（`SvgGeometry.cj:934-965`）在 `transform-box: fill-box` 时调用 `SvgGeometry.bounds(element, style: resolved)`；但 `bounds` 只处理 rect/circle/ellipse/line/polyline/polygon/path/text（`:33-51`），对 `g`/`a`/`switch` 返回 `None`，对未传 `fonts` 的文本也可能返回 `None`，于是退化为 `view-box` 参考盒。
- 渲染路径 `SvgRenderTree.walkContainer` 用 `svgBBoxOf` 计算容器内容盒（`:549-561`），二者对同一 `g` 的 `fill-box` 百分比原点可能不同。
- 现有 `SvgTransformPathM5_test.ctmMatchesRenderMatrix` 只测 rect，未覆盖容器；`getCTM` 与渲染“同一元素同一矩阵”的 C10 目标在容器上未闭环。

#### N9. marker 裁剪优化仍使用不带样式的 `elementTransformMatrix`

- `SvgRenderTree.cj:1331`（`markerContentFitsIn`）仍调用 `elementTransformMatrix(child)`，未传 style/bounds/viewport，因此忽略 `transform-origin` / `transform-box`。
- 该函数只决定 marker 内容是否需要额外裁剪；若带 transform-origin 的 marker 子元素被误判为“完全在视口内”，会跳过本应施加的裁剪，导致边缘内容溢出。
- 未发现对应测试；`SvgTransformPathM5_test` 不覆盖 marker。

#### N10. README 元素级 API 代码块未同步新增参数

- 实现已是 `getBBox(options!, mediaWidth!, mediaHeight!)`、`getCTM(mediaWidth!, mediaHeight!)`、`getScreenCTM(viewport!, mediaWidth!, mediaHeight!)`（`SvgElement.cj:333-377`），但 `f_svg/README.md:552-556` 与 `README_en.md:592-594` 仍只列旧签名。
- W10 的 M4/M5 能力矛盾已修，但 API 文档与实现仍有偏差，属 W10 的遗留。

#### N11. 既有 bidi-override 单元测试被删除，且无等价直接替代

- `git diff 5b7678bb..HEAD -- f_svg/src/SvgBidiM5_test.cj` 删除了 `override()` 用例，同时 `svgBidiOverrideLevels` 函数被移除；现仅由 `SvgDirectionM5_test.paragraphBreakSegmentsBidi` 间接覆盖 `unicode-bidi="bidi-override"`。
- 行为未发现回归（987 条全绿），但原报告强调的“测试完整性”出现一次净减少；建议补一条直接断言强制层级的用例。

#### N12. GPOS 多个 format 2 子表会相互覆盖 class matrix

- `parseGposPairSubtable`（`SvgOpenTypeLayout.cj:345-380`）对每个 format 2 子表直接写 `target.classMatrix` / `class2Count`，后解析的子表覆盖先前的矩阵；`class1`/`class2`/`covered` 则累加。
- 真实字体常含多个 PairPos 子表；出现时前面的 class 字距会丢失。此问题在修复前已存在，但 C3 的 Coverage 修复使该路径更常被覆盖，建议纳入后续修复。
- 现有测试每个表只有一个子表，无法发现。

## 4. 结论

- **C1、C2、C3、C5、C6、C7、C8、C9、C10 已清除**；**C4 部分清除**（原“静默回退首个 family”已消除，但“Body → Brand”别名主场景仍未实现）。
- fix-plan 第 2 节的 WARNING：W1–W6、W9、W10、W14 主体落地；**W11 未完全落地**；W5/W10/W14 存在边界缺口。
- 工程门禁成立：987 条测试全绿、`f_svg` 自身 0 warning、17 张 M1–M4 快照逐字节一致，未发现由修复引入的既有行为回归。
- 规范符合度仍不达标：新增 CRITICAL 1 项（@font-face 跨 family 别名），另有 11 项 WARNING（N2–N12）。在该 CRITICAL 解决前，不应把本变更归档为“M5 完成”。

CRITICAL=1
