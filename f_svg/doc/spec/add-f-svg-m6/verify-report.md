# add-f-svg-m6 校验报告

- 校验对象：`openspec/changes/add-f-svg-m6`（proposal / design / tasks / 10 个 delta spec）与 `openspec/specs/svg-*` 主规格
- 校验代码：`f_svg/src` 全量（280 个源文件，155 个 `*_test.cj`）
- 校验方式：规格逐条对照源码与测试；不修改代码、不归档
- 基线：`997` 条 M5 用例；当前 `cjpm test` 实测 **1137 / 1137 PASSED**
- 快照：M1–M5 `25` 张 + M6 `9` 张，逐字节比较
- delta spec 规模：**54 Requirement / 255 Scenario**（实测计数与任务描述一致）

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 完整度 | 54/54 Requirement 都有源码符号落点；但严格口径下只有 **36/54** 可判通过，**18/54** 存在阻断项 |
| 正确性 | 发现 **13 项 CRITICAL**：命中 API 缺失、`pointer-events: auto` 语义错误、变更事件契约不符、装饰长属性未接线、stretch/连字/字距开关未接线、text-rendering 容差未实现、textPath pathLength 未接线、渐变级颜色插值未接线、外部文档深度上限不可达、vector-effect 多值不可达、auto 尺寸缺 warning |
| 一致性 | 25 张 M1–M5 快照确为逐字节不变；9 张 M6 快照虽字节稳定，但 `m6-color-interpolation`、`m6-hit-queries`、`m6-svg2` 语义覆盖不足；CHANGELOG / design 计数与现状不符；`verification.md` 覆盖矩阵缺失 |
| 测试可信度 | 存在明确的“实现后补测试”假覆盖：单元直调未走真实调用链（装饰、stretch、textPath、vector-effect、字体特性开关） |

`cjpm test` 结果：

```text
Summary: TOTAL: 1137
    PASSED: 1137, SKIPPED: 0, ERROR: 0
    FAILED: 0
cjpm test success
```

`cjpm build` 结果：`cjpm build success`。clean build 共 22 条 warning，全部位于 `f_base` / `f_xml` 依赖源码，`f_svg` 自身 0 warning。

---

## 1. 方法、基线与阶段顺序

### 1.1 规格规模实测

| 能力域 | Requirement | Scenario |
|---|---:|---:|
| svg-animation | 6 | 33 |
| svg-css | 9 | 41 |
| svg-document-model | 5 | 23 |
| svg-geometry | 3 | 16 |
| svg-paint-and-clip | 3 | 12 |
| svg-rasterization | 3 | 18 |
| svg-render-pipeline | 9 | 33 |
| svg-security | 2 | 13 |
| svg-text | 9 | 48 |
| svg-value-types | 5 | 18 |
| **合计** | **54** | **255** |

### 1.2 P 阶段顺序

`feature/f_svg` 的提交顺序为：

```text
d12d1a47 feat(f_svg): M6 P1 静态交互
f8b4c49b feat(f_svg): M6 P2 文档与嵌入
d052cf67 feat(f_svg): M6 P3 渲染提示与颜色
f0d369c0 feat(f_svg): M6 P4 字体与文本细节
b257b993 feat(f_svg): M6 P6 动画控制
a061fe1e feat(f_svg): M6 P7 DOM API
f8a36a45 feat(f_svg): M6 P8 SVG 2 收尾
```

P1 → P2 → P3 → P4 → P6 → P7 → P8 顺序正确；P5 按 proposal 不存在，不属于缺项。后续 `55b1ffd7`、`0a5bc715`、`9b9c907c` 等为修复/补测提交，未打乱阶段顺序。`tasks.md` 第 1–8 组全部勾选，仅 9.8（合并共享分支）保持未勾选，符合“等待用户确认”。

### 1.3 快照基线

`git diff f3aa5dec feature/f_svg -- f_svg/testdata/render` 的结果只有 18 个 M6 新增文件（9 个 `.svg` + 9 个 `.rgba`），**没有任何 M1–M5 `.rgba` 的修改记录**。M1–M5 文件时间戳停留在 2026-11-05 至 2026-11-07 02:50，M6 文件为 2026-11-07 16:49/16:52，与提交顺序吻合。

---

## 2. Completeness（完整性）

### 2.1 CRITICAL

#### CP-01 `SvgHitTest` 未提供规格要求的公开 API

- 规格：`specs/svg-geometry/spec.md:7` 要求 `SvgHitTest.elementsAt(root, point, viewport, styles)` 与 `SvgHitTest.elementAt(...)`。
- 实现：`f_svg/src/SvgHitTest.cj:139-197` 只有 `hitTest(document, point, options, maxElements)` 与 `hitTest(root, point, options, maxElements)`；全仓 grep `elementsAt|elementAt` 为零。
- 测试：`SvgHitTestM6_test.cj` 全部调用 `hitTest`，没有按规格签名编译的用例。
- 影响：按规格编写的下游代码无法编译；调用方无法显式传入 `viewport` / `styles`，与规格的“注入视口与样式树”设计不一致。
- 处理建议：补齐规格 API（`elementsAt` / `elementAt`）并保留 `hitTest` 兼容别名，或修改规格。二者必须选一，当前处于“规格与实现各说各话”。

#### CP-02 `text-decoration` 长属性只进了计算样式，没有进入渲染

- 规格：`specs/svg-css/spec.md:240-262` 与 `specs/svg-text/spec.md:59-112` 要求 `-style` / `-color` / `-thickness` / `text-underline-position` 参与绘制，且简写展开为长属性。
- 实现：
  - `SvgTextDecoration2.cj:96-199` 的 `SvgTextDecorationSpec` 与 `outline()` 只在 `SvgComputedStyle.cj:495` 返回，渲染侧没有消费点。
  - 实际绘制在 `SvgTextRenderer.cj:773-812`，固定使用 `SvgTextDecorationGeometry.thickness()`、`underlineOffset()`、`overlineOffset()`、`lineThroughOffset()`；完全不读取 `textDecorationStyle/Thickness/Color/UnderlinePosition`。
  - `SvgRenderer.cj:309-345` 绘制装饰线时使用文本自身 `style` 的填充，未使用 `text-decoration-color`。
  - `SvgTextRenderer.cj:898-928` 的 `effectiveTextDecoration` 只看 `text-decoration` 简写来源；子元素声明 `text-decoration-line="none"` 时仍会继承父级简写。
- 直接失败的 Scenario：
  - “样式与厚度”（dashed + thickness 3）
  - “双线”（double）
  - “独立颜色”（blue vs red）
  - “none 关闭”（子级 longhand 覆盖父级）
  - “简写展开”中的 `-color`（`text-decoration: underline dotted red`）
- 假覆盖：`SvgFontDetailsM6_test.cj:289-318` 只测试了未被渲染器调用的 `SvgTextDecorationSpec.outline()`；`decorationLonghands` 只断言计算样式。
- 影响：用户声明 `text-decoration-style/color/thickness/text-underline-position` 时输出不变，属于功能未交付。

#### CP-03 `text-rendering` 只实现了整形开关，没有实现曲线容差

- 规格：`specs/svg-rasterization/spec.md:94-107` 要求 `optimizeSpeed` 容差 ×2、`optimizeLegibility` ×0.5、`geometricPrecision` ×0.25。
- 实现：`SvgTextRenderer.cj:410` 与 `:446` 仅根据 `OptimizeSpeed` 关闭连字/字距；全文件没有任何文字曲线容差倍率。`SvgRenderingHintsM6_test.cj` 对 `text-rendering` 只有计算样式断言，没有渲染断言。
- 影响：`text-rendering` 的精度语义三个 Scenario 均不成立；`optimizeSpeed` 只关闭整形，曲线仍按 auto 容差。
- 处理建议：在文本轮廓扁化处引入与 `shape-rendering` 同构的容差倍率，并补像素/几何断言。

#### CP-04 `textPath` 的 `pathLength` 校准没有接入真实排版调用

- 规格：`specs/svg-text/spec.md:125,137-140` 要求绝对 `startOffset` 与字形累计弧长乘以 `actualLength / pathLength`。
- 实现：`SvgTextPathLayout.cj:72,106` 支持 `pathLengthRatio`，但真实调用点 `SvgTextRenderer.cj:639-650` 没有传该参数（默认 1.0）；全仓除测试外没有其他调用者。
- 测试：`SvgFontDetailsM6_test.cj:371-390` 直接调用 `place(..., pathLengthRatio: 2.0)`，属于绕过真实渲染链的假覆盖。
- 影响：`<textPath pathLength="...">` 的 `startOffset` 不会缩放，字形弧长也没有按比例缩放；“pathLength 校准起点”Scenario 在真实渲染中不成立。

#### CP-05 渐变元素自身的 `color-interpolation` / `color-profile` 未接入

- 规格：`specs/svg-paint-and-clip/spec.md:35-66` 要求 `linearRGB` 生效并可从渐变祖先继承；`specs/svg-css/spec.md:168-190` 要求 `color-profile` 作用于渐变。
- 实现：`SvgGradientSampler` 的 `colorInterpolation` 来自 `SvgRenderer.cj:450` 的 **使用元素样式**，再传给 `fillGradient/strokeGradient`（`:504,:517`）；`SvgGradient.cj` 从不读取渐变元素自身的 `color-interpolation` 或 `color-profile`，`SvgRenderer` 也没有把渐变元素的 `SvgComputedStyle` 交给采样器。
- 像素证据：`m6-color-interpolation.svg` 把 `color-interpolation="sRGB"` 与 `"linearRGB"` 分别写在两个 `<linearGradient>` 上；实测 `m6-color-interpolation.rgba` 在 `(31,16)` 与 `(31,48)` 均为 `[130,0,125,255]`，两条色带完全相同。说明 `linearRGB` 声明未生效。
- 直接失败的 Scenario：
  - `linearRGB` 中点（写在渐变上时）
  - `color-interpolation` 继承（渐变祖先）
  - `color-profile` 声明/未声明若写在渐变元素上也不产生对应 warning
- 影响：M6 P3 的核心颜色能力只在“把属性写到使用元素上”时可用，与规格的渐变级语义不符；M6 快照制造了“已覆盖”的假象。

#### CP-06 `vector-effect` 多值组合不可达

- 规格：`specs/svg-geometry/spec.md:72,89-92` 要求多个新值按顺序组合；`specs/svg-value-types/spec.md:93` 与 proposal 也写明 `non-scaling-size` / `non-rotation` / `fixed-position` 可组合。
- 实现：
  - `SvgComputedStyle.cj:379` 只返回单个 `SvgVectorEffect`；`SvgStyleResolver.cj:666` 用单值解析，空格分隔的多值会整体解析失败。
  - 渲染接线 `SvgRenderTree.cj:1841-1844` 只传 `[style.vectorEffect()]`，永远只有一个元素。
  - `SvgVectorEffect2.apply` 虽然接收数组，但只被测试直接调用；且其循环按传入顺序执行，未强制 `non-scaling-size → non-rotation → fixed-position`（design D16 的固定顺序）。
- 影响：“组合顺序”Scenario 无法从 SVG/CSS 声明触发；规格中“按声明顺序组合”与 design 的“固定顺序”也相互冲突。

#### CP-07 `width/height: auto` 缺少“无法确定”的 warning，单轴未按 viewBox 比例推导

- 规格：`specs/svg-render-pipeline/spec.md:186-208` 要求根单轴 auto 按内容包围盒与 `viewBox` 比例推导，无法确定时 warning；嵌套 auto 取父视口 100%。
- 实现：`SvgAutoSize.cj:31-77` 没有 `warnings` 参数，`width <= 0 || height <= 0` 时直接 `return` 回退（`:73-76`），不会 warning；单轴 auto 直接取 `box.width` / `box.height`（`:52-57`），没有 design D17 所述的“按 viewBox 宽高比从另一轴推导”。
- 测试：`SvgSvg2M6_test.cj:107-119` 只测“双轴 auto + 内容恰好等于 viewBox”的 happy path；`autoSize` 没有单轴、嵌套、无内容、无 viewBox 的负向用例。
- 影响：“无法确定”Scenario 直接失败；“根自动宽度”“嵌套自动尺寸”没有真实落点。

#### CP-08 外部文档深度上限 4 实际不可达，5 层 Scenario 被测试改成 warning

- 规格：`specs/svg-render-pipeline/spec.md:43,72-75` 与 `specs/svg-security/spec.md:65,75-78` 要求第 5 层抛 `Limit`。
- 实现：
  - `SvgExternalDocument.cj:25-30` 有 `SVG_EXTERNAL_MAX_DEPTH = 4` 与 `svgExternalDepthAllows`。
  - `SvgRenderTree.cj:1820-1832` 的 `svgExternalParseOptions` 强制 `allowExternalReferences: false`，外部文档解析时外部 `href` 已被移除，因此外部文档无法再解析出指向另一外部文档的 `use`。
  - `SvgExternalDocumentM6_test.cj:157-191` 的 `depthLimit` 断言 `provider.calls == 1` 且 warning，而不是 `Limit`；它实际上验证了“不会递归”，不是深度上限。
- 影响：`depth >= 4` 的抛错分支在真实渲染中不可达；规格的两个要求（深度 4 抛 Limit vs 外部文档不递归加载）互相排斥，当前实现和测试选择了后者但未改规格。

### 2.2 WARNING

#### CP-09 `verification.md` 覆盖矩阵缺失

`tasks.md:121`（9.7）标记完成并声称“记录覆盖矩阵到 verification.md”，但 `openspec/changes/add-f-svg-m6/` 只有 `design.md` / `proposal.md` / `specs/` / `tasks.md`，没有 `verification.md`。这是验收材料的缺失，不是代码缺陷。

#### CP-10 design 声明的 18 个新文件有 3 个不存在

design D18 与 proposal Impact 均列出 `SvgColorProfile.cj`、`SvgAnimationControl.cj`、`SvgLineJoin2.cj`；实际三文件不存在，功能分别并入 `SvgRenderingHints.cj`、`SvgTimeline.cj`、`SvgShape.cj` + `SvgStrokeOutliner.cj`。`tasks.md:15` 有合并备注，但 design/proposal 未同步，属于文档漂移。

#### CP-11 9 张 M6 快照中至少 3 张语义覆盖不足

- `m6-color-interpolation`：两条色带像素完全相同（见 CP-05），不能证明 `linearRGB`。
- `m6-hit-queries`：`m6RenderScene` 对该场景只走普通 `SvgRenderer().render(document)`（`SvgSnapshotM6_test.cj:23-45`），没有调用任何命中查询；它只是一张带 `pointer-events` 属性的普通渲染图。
- `m6-svg2`：`vector-effect="non-scaling-size"` 所在元素没有祖先缩放，视觉上无法验证矩阵修正；只验证了 `miter-clip` / `arcs` 的绘制。

这些快照能证明“字节稳定”，不能证明对应能力。

#### CP-12 `font-feature-settings` 样式层解析的 warning 被丢弃

`SvgFontFeatures.fromStyle`（`SvgFontVariant.cj:191-198`）为 `parse` 新建了局部 `warnings` 列表，却没有把它并入 `SvgStyleResolver` / `SvgTextRenderer` 的 warning。超过 64 条的样式声明不会产生规格要求的 warning；非法 tag 同样静默丢弃。

#### CP-13 `foreignObject` 返回位图没有 `maxPixels` 保护

design 风险表写明位图受 `maxPixels` 与 `maxElements` 约束、构建期分配前校验；`SvgRenderTree.cj:635-681` 的 `addForeignObject` 直接接收 renderer 返回的 `SvgBitmap` 并写入 Image 指令，没有尺寸/像素数检查，也没有对应负向用例。

---

## 3. Correctness（正确性）

### 3.1 CRITICAL

#### CR-01 `pointer-events: auto` 没有按 `visiblePainted` 处理隐藏元素

- 规格：`specs/svg-geometry/spec.md:9` 明确 `auto` 等价 `visiblePainted`；`visible*` 要求 `visibility != hidden`。
- 实现：`SvgHitTest.cj:358-363` 的 `svgHitRequiresVisible` 只把 `VisiblePainted/VisibleFill/VisibleStroke/Visible` 视为需要可见，`Auto` 不在其中；`svgHitElementMatches` 在 `:323` 只在 `hidden && requiresVisible` 时返回 false，因此默认 `auto` 的隐藏元素会继续走填充/描边命中。
- 测试：`SvgHitTestM6_test.cj:118-131` 的 `visibilityCombinations` 只测 `visible`（不命中）、`all`（命中）、`fill`（命中），没有测默认 `auto`。
- 影响：`<rect visibility="hidden"/>` 在默认 `pointer-events` 下仍然可被命中，违反 SVG 的 `auto = visiblePainted` 语义。

#### CR-02 `SvgMutationKind` 公开枚举值与规格不一致

- 规格：`specs/svg-document-model/spec.md:72` 要求 `kind`（`Attribute` / `ChildList`）。
- 实现：`SvgMutation.cj:21-42` 使用 `Attribute` / `ChildInserted` / `ChildRemoved`；`SvgDomApiM6_test.cj:127,130` 也按实现名断言。
- 影响：按规格编写的下游 `match` 无法编译；插入与移除被拆成两个值，规格没有这个契约。这是“测试跟着实现写”的典型迹象。

#### CR-03 `removeMutationListener` 移除的是第一个监听器，不是传入的监听器

- 规格：`specs/svg-document-model/spec.md:74` 要求移除指定监听器；未注册移除应无副作用。
- 实现：`SvgMutation.cj:89-95` 注释写明“接口无引用相等”，实际执行 `this.listeners.remove(at: 0)`；参数只用于 `let _ = listener`。
- 测试：`SvgDomApiM6_test.cj:132-134` 只注册一个监听器再移除，无法暴露该 bug。
- 影响：注册 A、B 后移除 B，实际移除 A；移除未注册对象也会误删第一个监听器。

#### CR-04 `font-stretch` 没有参与真实字体匹配，且合成缩放无条件执行

- 规格：`specs/svg-text/spec.md:219-235` 要求 `font-stretch` 作为 family/weight/style/stretch 四维匹配条件，精确匹配 75% 字体；百分比仅在无精确匹配且最终使用 100% 字体时做水平缩放。
- 实现：
  - `SvgTextRenderer.cj:377` 仍调用三参数 `registry.resolve(char.family, char.weight, char.style)`；`SvgFont.cj:128-130` 该重载固定 `stretch: 100.0`。
  - `applyFontStretchSynthesis`（`SvgTextRenderer.cj:1755-1771`）只要 `font-stretch` 不是 100% 就乘 factor，不判断最终选中的字体是否已经是 75%/80% 面。
- 测试：
  - `SvgFontDetailsM6_test.cj:175-190` 只直接测注册表 `resolve(..., stretch:)`；
  - `stretchSynthesisScalesGlyphAndAdvance`（`:407-425`）只注册 100% 字体，无法证明“精确匹配优先”。
- 影响：“stretch 精确匹配”Scenario 在渲染中失败；若后续把 stretch 传入 resolve，当前无条件缩放还会造成 0.75 × 0.75 的双重缩放。

#### CR-05 `font-variant-ligatures` / `font-feature-settings` 的 liga/clig/hlig/kern 开关没有真正控制 M5 连字与字距

- 规格：`specs/svg-css/spec.md:216-238`、`specs/svg-text/spec.md:252-279` 要求 `font-variant-ligatures: none` 关闭 `liga`/`clig`，`historical-ligatures` 开启 `hlig`，`"kern" 0` 关闭字距。
- 实现：
  - `applyFontLigatures`（`SvgTextRenderer.cj:1626-1691`）没有任何 feature 参数；唯一门禁是 caller 的 `textRendering != OptimizeSpeed`（`:410`）。
  - `applyFontKerning`（`:1588-1623`）只检查 `fontKerning() == None`，不读取 `fontFeatures().enabled("kern")`。
  - `style.fontFeatures()` 只在 `applyFontContextShaping`（`:1694-1752`）中使用；该函数只对“带 Type 5/6 上下文表”的字体生效，普通 `liga` Type 4 字体完全绕过特性开关。
- 测试：
  - `featureMerge`（`SvgFontDetailsM6_test.cj:215-234`）只断言计算样式开合；
  - `featureGroupingRespectsStyle`（`SvgGsubContextM6_test.cj:393-418`）特意使用带上下文表的字体，掩盖了普通字体路径；
  - 没有 `font-variant-ligatures: none` 作用于标准 `fi` 连字的布局断言。
- 影响：“关闭常见连字”“历史连字”“特性开关关闭（kern 0）”等 Scenario 在普通字体上失败。

### 3.2 WARNING

#### CR-06 根元素 `pointer-events: none` 未生效

`SvgHitTest.hitTest` 从 `root.children` 开始递归（`SvgHitTest.cj:186-194`），从未读取根元素自身的 `pointer-events`。根声明 `none` 时，子树仍可命中。

#### CR-07 命中测试的 `maxElements` 没有读取 `SvgSecurityOptions.maxElements`

规格 `specs/svg-security/spec.md:71,100-103` 要求受 `SvgSecurityOptions.maxElements` 约束；实现 `SvgHitTest.hitTest` 的 `maxElements` 是独立参数，默认 `1_000_000`（`:146`），完全不看 `options.security` / `document.parseOptions.security`。显式传参的负向用例存在，但安全选项链路没有落地。

#### CR-08 `text` 命中在轮廓缺失时回退到包围盒

`SvgHitTest.cj:405,420` 在 `renderer.outline` 返回 `None` 时调用 `svgHitBBoxContains`。规格要求 `text` 使用字形轮廓；回退会让空白区域也被命中。`textHit` 只用 `pointer-events="all"` 且点在包围盒内，未验证轮廓。

#### CR-09 `discard` 嵌套只静默跳过，没有 warning

`SvgTimeline.cj:228-230` 对 `svgDiscardNestingDepth(element) > 1` 直接 `continue`，不调用 `warnings.add`；规格 `specs/svg-animation/spec.md:211-214` 与 `specs/svg-security/spec.md:98` 要求“只处理最外层并 warning”。`SvgAnimationControlM6_test.cj:183-194` 只测单层 discard。

#### CR-10 `attributeType` 非法值没有 warning

`SvgTimeline.cj:513` 只做 `toAsciiUpper()`；`svgAnimationWriteValue`（`:1314-1326`）将非 `CSS` 一律当 XML，没有对 `AUTO` 等非法值 warning。规格 `specs/svg-animation/spec.md:163-166` 要求回退 XML 并 warning；测试没有非法值用例。

#### CR-11 `min` 延长用例没有断言

`SvgAnimationControlM6_test.cj:162-166` 生成 `min="15s"` 文档后只执行 `println("MIN_X=...")`，没有任何 `@Assert`。该用例即使实现完全错误也会通过，不能作为“min 延长”覆盖证据。

#### CR-12 `font-size-adjust` 在遇到第一个缺 OS/2 的字体时用 `return` 终止整个循环

`SvgTextRenderer.cj:1828-1833` 在 `ratio` 为 `None` 时 `warnings.add(...); return`，而不是 `continue`。同一文本 run 中若第一个字体缺 `OS/2`、后续字体有 `OS/2`，后续字形不会得到修正；反之也会提前结束。规格要求“缺少 OS/2 时忽略并 warning”，应逐字体处理。

#### CR-13 命名空间版 `setAttr` / `removeAttr` 不触发变更通知

规格 `specs/svg-document-model/spec.md:72` 要求 `setAttr` / `removeAttr` 后通知。`SvgElement.cj:152-173` 的裸名 `setAttr` 与 `:212-230` 的裸名 `removeAttr` 会通知；`:175-204` 的 `setAttr(namespace:local:value:)` 与 `:189-204` 的 `removeAttr(namespace:local:)` 不通知。解析器内部使用命名空间重载，调用方也可能使用。

#### CR-14 `pointer-events: visible` 的几何语义与 design 不一致

design D2 写 `visible` 命中包围盒；`SvgHitTest.cj:365-383` 将 `Visible` 视为同时 wantsFill/wantsStroke，按路径/描边几何判定。规格文本较模糊（“其余使用路径/描边区域”），但 design 与实现不一致；需要统一。

---

## 4. Coherence（一致性）

### 4.1 WARNING

#### CO-01 CHANGELOG 的用例数与实际不符

`CHANGELOG:17` 写“1104 条用例全绿”；实测 `@TestCase` 为 1137，`cjpm test` 也是 1137。数字明显早于最终提交，属于验收记录失真。

#### CO-02 design 的代码规模描述过期

`design.md:5` 写“245 个源文件，其中 99 个测试文件”；实际 `f_svg/src` 为 280 个文件、155 个 `*_test.cj`。不影响功能，但会误导后续审计。

#### CO-03 外部文档“深度上限”与“外部文档不再递归加载”互相矛盾

`specs/svg-render-pipeline/spec.md:43` 要求外部文档深度 4、超限抛 `Limit`；`specs/svg-security/spec.md:20` 要求外部文档不得因自身引用再次触发外部加载。当前实现选择后者，导致前者的 5 层 Scenario 永远无法成立（见 CP-08）。必须修改其中一个规格，或提供“外部文档内引用由同一 provider 受控递归”的明确例外。

#### CO-04 `vector-effect` 组合顺序在三处表述不一致

- `specs/svg-geometry/spec.md:72` 写固定顺序 `non-scaling-size → non-rotation → fixed-position`；
- 同文件 `:89-92` Scenario 写“按声明顺序逐个应用”；
- design D16 写固定顺序；实现 `SvgVectorEffect2.apply` 按数组顺序，渲染侧又只有单值。

在 CP-06 修复前，这条规格无法被一致实现。

#### CO-05 README 对 M6 能力有超前描述

`f_svg/README.md:645-678` 声称 `text-rendering` 提高精度、装饰长属性按 double/dotted/dashed/wavy 绘制、`pathLength` 校准 textPath；`:699-716` 声称 vector-effect 按固定顺序、auto 无法确定时 warning。上述能力分别对应 CP-02/03/04/06/07 的缺口。README 与 CHANGELOG 应在修复后再宣称这些行为。

#### CO-06 9 张 M6 快照的语义覆盖与命名不匹配

见 CP-11。尤其是 `m6-color-interpolation` 的像素证据（两条色带相同）会被误读为“linearRGB 已覆盖”，建议在修复 CP-05 后重新生成，或删除该快照并改用像素断言。

#### CO-07 `verification.md` 缺失与任务勾选不一致

见 CP-09。`tasks.md` 9.7 已勾选，但覆盖矩阵没有落地文件，属于流程记录不一致。

#### CO-08 design 的“18 个新文件”与实际文件集合不一致

见 CP-10。

### 4.2 SUGGESTION

#### CO-S1 测试中的调试输出应删除

`SvgAnimationControlM6_test.cj:145` 的 `println("CSS_STYLE=..." )` 与 `:166` 的 `println("MIN_X=..." )` 会污染测试输出；后者还替代了断言。

#### CO-S2 枚举解析 API 对外不可见

`SvgPointerEvents.fromName`、`SvgShapeRendering.fromName`、`SvgTextRendering.fromName`、`SvgColorRendering.fromName`、`SvgColorInterpolation.fromName` 均为 `internal`。规格要求“每个枚举提供字符串解析”，当前只有同包测试能调用；建议公开或明确为内部实现。

#### CO-S3 `SvgLineJoin.toString` 与“字符串形式”不一致

`SvgShape.cj:86-87` 的 `toString` 返回 `MiterClip` / `Arcs`，`attrName()` 返回 `miter-clip` / `arcs`；规格 `svg-value-types:93` 说“字符串形式为 miter-clip / arcs”。既有 M4 值也是大写 `toString`，建议在规格中明确“字符串形式”指 `attrName`，或统一 `toString`。

#### CO-S4 删除或接线 `SvgTextDecorationSpec.outline`

该函数目前是死代码，且其 `underlinePosition` 几何（`Above => -2*thickness`、`Under => 3*thickness`）与 `SvgTextDecorationGeometry` 的真实语义不同。保留会诱导后续误用。

---

## 5. Requirement / Scenario 落点矩阵

### 5.1 严格口径统计

- **54/54 Requirement 有源码符号落点**（无 `TODO` 空实现、无未注册标签）。
- 按“规格语义 + 真实调用链 + 可执行断言”三项同时满足判定：**36/54 通过，18/54 阻断**。
- **255 条 Scenario**：至少 **20 条按当前实现直接不成立**；至少 **12 条没有直接可执行断言**（仅直调内部函数、仅计算样式或用 `println` 代替断言）；其余有直接或间接覆盖。

### 5.2 按能力域

| 能力域 | Req/Scen | 通过 Req | 阻断 Req | 主要阻断 Requirement |
|---|---:|---:|---:|---|
| svg-animation | 6/33 | 4 | 2 | 动画写入类型、discard 快照移除 |
| svg-css | 9/41 | 7 | 2 | OpenType 特性属性、装饰长属性 |
| svg-document-model | 5/23 | 4 | 1 | 变更监听 |
| svg-geometry | 3/16 | 0 | 3 | 命中测试、pathLength 校准、矢量效果几何语义 |
| svg-paint-and-clip | 3/12 | 2 | 1 | 颜色插值模式 |
| svg-rasterization | 3/18 | 2 | 1 | 渲染提示到光栅参数 |
| svg-render-pipeline | 9/33 | 6 | 3 | use 展开、自动尺寸、矢量效果矩阵应用 |
| svg-security | 2/13 | 1 | 1 | M6 上限与降级 |
| svg-text | 9/48 | 5 | 4 | 文本装饰线、textPath、字体匹配与合成、字体特性开关 |
| svg-value-types | 5/18 | 5 | 0 | 无 |
| **合计** | **54/255** | **36** | **18** | |

### 5.3 明确不成立的 Scenario（至少 20 条）

1. `svg-css` 装饰长属性：简写展开的 `-color` 未生效。
2. `svg-css` 装饰长属性：`text-decoration-line: underline overline line-through` 中 longhand 可计算，但渲染仍按简写/父级传播；组合线型只在计算样式层通过。
3. `svg-text` 文本装饰线：样式与厚度（dashed + thickness 3）。
4. `svg-text` 文本装饰线：独立颜色（blue vs red）。
5. `svg-text` 文本装饰线：双线（double）。
6. `svg-text` 文本装饰线：none 关闭（子级 longhand 覆盖父级简写）。
7. `svg-text` M6 字体匹配与合成：stretch 精确匹配（75% 字体不会被选中）。
8. `svg-text` M6 字体特性开关：`font-variant-ligatures: none` 关闭标准 `liga`。
9. `svg-text` 标准连字：历史连字 `hlig`（普通 Type 4 字体路径不读取 hlig）。
10. `svg-text` OpenType 字距调整：`font-feature-settings: "kern" 0`。
11. `svg-rasterization` 渲染提示：`text-rendering="optimizeSpeed"` 容差 ×2。
12. `svg-rasterization` 渲染提示：`optimizeLegibility` 容差 ×0.5。
13. `svg-rasterization` 渲染提示：`geometricPrecision` 容差 ×0.25。
14. `svg-text` textPath：`pathLength` 校准绝对 `startOffset`。
15. `svg-paint-and-clip` 颜色插值：渐变元素上的 `linearRGB` 中点。
16. `svg-paint-and-clip` 颜色插值：渐变祖先的 `color-interpolation` 继承。
17. `svg-render-pipeline` / `svg-security`：外部文档第 5 层抛 `Limit`。
18. `svg-geometry` 矢量效果：三值同时声明的组合顺序。
19. `svg-render-pipeline` 自动尺寸：无法确定时 warning。
20. `svg-animation` 写入类型：`attributeType="AUTO"` 回退 XML 并 warning。
21. `svg-animation` discard：嵌套 `discard` 只处理最外层并 warning。
22. `svg-text` 文本装饰线：`text-decoration: underline dotted red` 的简写颜色（与第 1 条同源，但独立 Scenario）。

### 5.4 仅有“假落点”的关键项

- `SvgTextDecorationSpec.outline`：有完整单测，但渲染器不调用。
- `SvgVectorEffect2.apply` 多值：有单测，但 CSS 解析和渲染只支持单值。
- `SvgFontRegistry.resolve(stretch:)`：有单测，但 `SvgTextRenderer` 调用三参数重载。
- `SvgTextPathLayout.place(pathLengthRatio:)`：有单测，但真实调用点不传参。
- `SvgFeature` 分组：只在带上下文表的字体上验证，绕过了标准 Type 4 连字。
- `min` 延长：只有 `println`，没有断言。
- `m6-hit-queries`：快照没有调用命中查询。
- `m6-color-interpolation`：两张色带像素相同，未证明 `linearRGB`。

---

## 6. 快照逐字节校验

### 6.1 M1–M5 的 25 张

- 覆盖：`SvgSnapshotM6_test.cj:78-120` 的 `M1_TO_M3`（10）、`animation`（3）、M4（4）、`M5_SCENES`（8），合计 25。
- 比较：`SvgSnapshotM5_test.cj:73-96` 的 `m5ExactMismatch` 按字节逐一比较，容差 0；缺失快照直接 `@Fail`，不会自动生成。
- 实测：`cjpm test` 中 25 张全部通过；`git diff f3aa5dec feature/f_svg -- f_svg/testdata/render` 没有修改任何既有 `.rgba`，只新增 18 个 M6 文件。
- 结论：**25/25 逐字节一致，成立。**

### 6.2 M6 的 9 张

- 覆盖：`SvgSnapshotM6_test.cj:47-73` 的 9 个场景，`scenesExact` 逐张 `m5CompareExact`，`scenesAreDeterministic` 二次渲染比较。
- 实测：9 张全部通过，重复渲染逐字节一致。
- 语义有效性：
  - `m6-interaction`：读取 `hoveredIds` / `focusedIds`，有效。
  - `m6-foreign-object`：注入 2×2 位图，有效。
  - `m6-initial-view`：`#detail` 覆盖视口，有效。
  - `m6-rendering-hints`：三种 shape-rendering + text-rendering，基本有效。
  - `m6-color-interpolation`：**无效**，两条色带像素相同（见 CP-05）。
  - `m6-font-details`：stretch/small-caps/underline 有视觉变化，但 `liga 0` 作用在 “AB” 上无意义，且装饰样式未覆盖。
  - `m6-animation-control`：`sample(2.0)` 有动画，有效。
  - `m6-hit-queries`：**无效**，没有调用任何命中查询。
  - `m6-svg2`：miter-clip/arcs 有效；`vector-effect` 无祖先缩放，不能验证矩阵修正。
- 结论：**9/9 字节一致，成立；其中至少 3 张语义覆盖不足。**

---

## 7. 断言真实性抽查（假覆盖证据）

| 测试 | 直调对象 | 真实调用链 | 结论 |
|---|---|---|---|
| `SvgFontDetailsM6_test.registryStretch` | `registry.resolve(..., stretch:)` | `SvgTextRenderer.cj:377` 三参数 | 注册表能力有测试，排版不选 stretch 字体 |
| `SvgFontDetailsM6_test.textPathPathLength` | `SvgTextPathLayout.place(..., pathLengthRatio:2)` | `SvgTextRenderer.cj:639` 不传 ratio | textPath 真实渲染无校准 |
| `SvgFontDetailsM6_test.decorationGeometry` | `SvgTextDecorationSpec.outline` | `SvgTextRenderer.cj:794-806` 用旧几何 | 装饰样式/厚度/颜色未接线 |
| `SvgSvg2M6_test.vectorEffectMatrix` | `SvgVectorEffect2.apply([...])` | `SvgRenderTree.cj:1843` 只传单值 | 多值组合不可从 SVG 触发 |
| `SvgGsubContextM6_test.featureGroupingRespectsStyle` | 带 Type 5 上下文表的字体 | 普通 Type 4 字体走 `applyFontLigatures` | 标准连字开关未被覆盖 |
| `SvgAnimationControlM6_test.minMax` | `println("MIN_X=...")` | 无断言 | min 延长未被验证 |
| `SvgSnapshotM6Scenes_test.scenesExact` | `m6-color-interpolation` | 两条渐变均按 sRGB | 快照不能证明 linearRGB |
| `SvgDomApiM6_test.mutationListeners` | 单个监听器 | `SvgMutationHub.remove(at:0)` | 多监听器移除 bug 被隐藏 |
| `SvgHitTestM6_test.visibilityCombinations` | `visible`/`fill`/`all` | 未测默认 `auto` | auto 隐藏 bug 被隐藏 |
| `SvgSvg2M6_test.autoSize` | 双轴 auto + 内容=viewBox | 无单轴/无 warning/无嵌套 | 自动尺寸负向路径未覆盖 |

---

## 8. 上限负向用例核对

| 上限 | 规格值 | 负向用例 | 结论 |
|---|---|---|---|
| 外部文档深度 | 4，超限 `Limit` | `depthLimit` 断言 warning，不是 `Limit` | 不成立（CP-08） |
| 外部文档字节 | 16 MiB | `byteLimit` 16 MiB+1 抛 `Limit` | 成立 |
| GSUB 链式深度 | 8 | `nestedDepthStopsAtNine` 第 9 层 warning | 成立 |
| font-feature-settings 条目 | 64 | `fontFeatureParsing` 70 条保留 64 + warning | 成立（样式层 warning 丢失见 CP-12） |
| 变更监听器 | 32 | `listenerLimit` 第 33 个抛异常 | 成立 |
| discard 嵌套深度 | 1 | 无 nested discard 用例；实现也无 warning | 不成立（CR-09） |
| 命中测试元素数 | `maxElements` | `SvgHitTestM6_test.boundaries` 显式 `maxElements:1` 抛 `Limit` | 部分成立；未走 `SvgSecurityOptions`（CR-07） |

---

## 9. 最终判定与整改优先级

### 9.1 可确认通过的部分

- 25 张 M1–M5 快照逐字节不变；9 张 M6 快照字节稳定。
- `cjpm test` 1137 全绿；`cjpm build` 成功，依赖 warning 不来自 `f_svg`。
- P1→P2→P3→P4→P6→P7→P8 提交顺序正确。
- `foreignObject` 注入、`initialView`、`truncate` 外部字节上限、GSUB Type 5/6、`miter-clip`/`arcs`、命中查询主体、变更监听上限/异常隔离的主体实现成立。
- `pointer-events` 11 值、`cursor` 白名单、`:hover`/`:focus` 级联、`SvgViewState`、工厂方法、`SvgPathLength` 比例、`@color-profile` 解析等基础能力成立。

### 9.2 整改优先级（P0）

1. 补 `SvgHitTest.elementsAt` / `elementAt`，并修正 `auto` 隐藏命中。
2. 对齐 `SvgMutationKind` 为 `Attribute` / `ChildList`（或修改规格），修复 `removeMutationListener`。
3. 把 `text-decoration` 长属性接入 `decorationRuns` / `SvgRenderer`，包括 style、color、thickness、underline-position、子级 `-line:none` 覆盖和简写颜色展开。
4. 把 `font-stretch` 传入 `resolve`，并把合成缩放限定为“最终选中 100% 字体”。
5. 让 `font-variant-ligatures` / `font-feature-settings` 控制 M5 Type 4 连字与 `kern`。
6. 实现 `text-rendering` 容差映射。
7. 把 `pathLengthRatio` 从真实 textPath 调用传入，并缩放字形弧长。
8. 让渐变采样读取渐变元素自身的 `color-interpolation` / `color-profile`（或明确规格只认使用元素）。
9. 解决外部文档“深度 Limit”与“禁止递归加载”的规格冲突，给出可达语义与真实负向用例。
10. 支持 `vector-effect` 多值解析与渲染组合，并统一顺序定义。
11. 补 `auto` 无法确定的 warning、单轴 viewBox 推导和嵌套用例。

### 9.3 报告边界

- 本次只校验，不修改源码、不归档。
- `openspec validate add-f-svg-m6 --strict` 未执行：当前环境没有 `openspec` CLI（`command not found`），因此 tasks 9.5 的“已通过”无法在本环境复核。
- 未运行 `openspec archive`，未触碰 `openspec/specs/` 主规格。

---

**CRITICAL=13**
