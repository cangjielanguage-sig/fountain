# Verify Report — add-f-svg-m5

- 校验对象：`openspec/changes/add-f-svg-m5`（proposal / design / tasks / 10 个 delta spec）与 `f_svg/src` 全部实现、测试
- 校验基线：`feature/f_svg` @ `5b7678bb`；工作树内执行，未改代码、未归档
- 校验口径：Completeness / Correctness / Coherence；分级 CRITICAL / WARNING / SUGGESTION
- 说明：环境无 `openspec` CLI，`openspec validate --strict` 未复跑；以下结论来自规范逐条比对、源码审阅、全量测试与快照哈希复核

## 0. 结论摘要

M5 的 P1→P4 提交顺序正确，17 张 M1–M4 快照确实逐字节一致，941 条测试全绿，`f_svg` 自身 0 warning。但本变更存在 **10 个 CRITICAL**：其中 1 个公开类型完全缺失（`SvgTransformBox`），GPOS/GSUB 的 feature 过滤与 GPOS format 2 Coverage 语义缺失，`@font-face` 未注册目标的降级与规格相反，`width: calc()` 场景未落地，GSUB lookup 深度上限未实现，`mix-blend-mode` 对多命令元素按命令而非整组合成，连字簇的列表项消费未实现，文本整形管线顺序与规格相反，`transform-origin` 未覆盖 clipPath/mask/use/嵌套 svg/root 等路径。

这些不是文档措辞问题，而是可复现的行为偏差；其中多项被现有测试以“实现后补测试”的方式固化成了假绿。

## 1. 门禁与统计

| 项目 | 结果 | 证据 |
|---|---|---|
| delta 规范规模 | 39 Requirement / 153 Scenario | 10 个 spec 文件标题计数；`svg-css` 11/47、`svg-value-types` 5/13、`svg-text` 7/27、`svg-geometry` 4/16、`svg-render-pipeline` 4/16、`svg-paint-and-clip` 2/9、`svg-rasterization` 1/5、`svg-filter` 2/6、`svg-document-model` 2/8、`svg-security` 1/6 |
| 场景去重 | 153 个标题中 2 个为逐字重复 | `svg-value-types` 的「绘制顺序解析」「重复项去重」同时出现在「M5 混合模式枚举」与「M5 绘制顺序值类型」下；唯一场景 151 个 |
| 全量测试 | `TOTAL: 941 / PASSED: 941 / FAILED: 0` | `cjpm test`（2026-11-06） |
| 新增测试 | 231 个 `@TestCase` / 38 个 `*M5_test.cj` | 941 − 710 = 231 |
| 构建 | `cjpm build success`；`f_svg` 自身 0 warning | 22 条 warning 全部来自依赖 `f_xml` |
| 既有测试改动 | 仅 `CssStyleSheet_test.cj` 的 2 条用例 | `git diff d4610b1e..HEAD` |
| 17 张快照 | 17/17 SHA-256 与 `doc/perf-baseline.md` 一致 | `sha256sum` 复核；M5 提交未改动旧 `.rgba` |
| P1→P4 顺序 | 正确 | 提交链见 §2.3 |
| 任务完成度 | 除 13.7 外均已勾选 | `tasks.md:138` |

## 2. Completeness

### 2.1 Requirement 落点总表

状态口径：

- ✅：至少有直接断言，且覆盖规范主要语义
- ⚠️：有测试，但只覆盖部分语义、测试较弱，或实现与规范文字有偏差
- ❌：没有实现或没有可执行落点

| 能力域 | Requirement | Scenario | 落点证据 | 状态 |
|---|---|---|---|---|
| svg-css | CSS 规则集解析 | 5 | `CssStyleSheet_test`、`CssMediaM5_test`、`CssFontFaceM5_test` | ✅ |
| svg-css | 选择器模型与匹配 | 4 | `CssSelector_test`、`CssSelectorCascadeM5_test` | ✅ |
| svg-css | 属性选择器 | 5 | `CssSelectorAttributeM5_test` | ✅ |
| svg-css | 结构伪类 | 4 | `CssSelectorStructuralM5_test`、`CssSelectorNthM5_test` | ✅ |
| svg-css | 否定伪类 | 3 | `CssSelectorNotM5_test` | ✅ |
| svg-css | 兄弟组合器 | 3 | `CssSelectorSiblingM5_test` | ✅ |
| svg-css | @media 求值 | 5 | `CssMediaM5_test`、`CssMediaWidthM5_test` | ✅ |
| svg-css | @font-face 别名 | 3 | `CssFontFaceM5_test`、`CssFontAliasM5_test` | ⚠️ 未注册目标行为错误，见 C4 |
| svg-css | CSS 变量 | 5 | `CssVariablesM5_test`、`CssVariablesNegativeM5_test` | ✅ |
| svg-css | calc() 表达式 | 6 | `CssCalcM5_test`、`CssCalcPropertyM5_test` | ⚠️ `width: calc()` 未落地，见 C5 |
| svg-css | M5 属性注册 | 4 | `SvgComputedStyleM5_test` | ✅ |
| svg-value-types | M5 混合模式枚举 | 5 | `SvgBlendM5_test`、`SvgBlendPixelsM5_test` | ✅ |
| svg-value-types | M5 绘制顺序值类型 | 2 | `SvgPaintOrderM5_test` | ✅（场景重复） |
| svg-value-types | M5 变换参考盒枚举 | 1 | 无 `SvgTransformBox` 声明、无测试 | ❌ 见 C1 |
| svg-value-types | M5 文本方向枚举 | 2 | `SvgDirectionM5_test`、`SvgBidiM5_test` | ⚠️ `SvgFontKerning` 为 struct 非 enum |
| svg-value-types | M5 枚举回退 | 3 | `SvgComputedStyleM5_test.invalidValuesWarn` 等 | ✅ |
| svg-text | 文本布局（MODIFIED） | 6 | `SvgTextRenderer_test` + `SvgKerningLayoutM5_test` | ⚠️ 连字簇列表项未落地，见 C8 |
| svg-text | M3 文本边界（MODIFIED） | 3 | `SvgTextPathLayout_test`、`SvgDirectionM5_test.defaultsMatchM4` | ⚠️「一个连字字形」断言与实现相反 |
| svg-text | OpenType 字距调整 | 4 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ⚠️ GPOS 未按 kern feature 过滤，见 C2 |
| svg-text | 标准连字 | 3 | `SvgOpenTypeLayoutM5_test` 的 `SvgGsubM5_test` | ⚠️ 深度上限缺失，见 C6 |
| svg-text | 双向文本重排 | 4 | `SvgBidiM5_test`、`SvgDirectionM5_test` | ✅（单元级；集成级偏弱） |
| svg-text | M5 文本方向属性 | 4 | `SvgDirectionM5_test` | ⚠️ embed/竖排列序/几何不变未落地，见 W6 |
| svg-text | 字体别名解析 | 3 | `CssFontAliasM5_test` | ⚠️ 目标缺失错误、weight/style 未用，见 C4/W8 |
| svg-geometry | M5 元素级包围盒 API | 5 | `SvgElementApiM5_test` | ⚠️ clipped 仅根视口、fonts/文本未测，见 W5 |
| svg-geometry | M5 容器与引用包围盒 | 4 | `SvgElementApiM5_test.containerBBox`、`useAndImageBBox` | ✅ |
| svg-geometry | M5 元素级 CTM API | 4 | `SvgElementApiM5_test.ctm/screenCtm/ctmWithOrigin` | ✅（嵌套 svg 未测） |
| svg-geometry | M5 路径元素级长度 API | 3 | `SvgElementApiM5_test.pathLength` | ✅ |
| svg-render-pipeline | M5 paint-order 渲染顺序 | 4 | `SvgPaintOrderRenderM5_test` | ✅ |
| svg-render-pipeline | M5 混合与隔离合成位置 | 4 | `SvgBlendLayerM5_test`、`SvgGroupCompositorM5_test` | ⚠️ 整组混合无直接测试，多命令元素按命令混合，见 C7 |
| svg-render-pipeline | M5 transform-origin / transform-box | 4 | `SvgTransformOriginM5_test`、`...RenderM5_test` | ⚠️ 次级渲染路径未接线，见 C10 |
| svg-render-pipeline | M5 媒体宽度来源 | 4 | `CssMediaWidthM5_test` | ✅ |
| svg-paint-and-clip | M5 混合模式与隔离组 | 5 | `SvgBlendPixelsM5_test`、`SvgBlendLayerM5_test` | ✅ |
| svg-paint-and-clip | M5 上下文画笔 | 4 | `SvgContextPaintM5_test`、`...RenderM5_test` | ✅ |
| svg-rasterization | M5 混合模式像素合成 | 5 | `SvgBlendPixelsM5_test`、`SvgGroupCompositorM5_test` | ✅ |
| svg-filter | feDropShadow 投影原语 | 4 | `SvgDropShadowM5_test`、`...RenderM5_test` | ✅ |
| svg-filter | feDropShadow 参数与区域 | 2 | `SvgDropShadowRenderM5_test` | ⚠️ 负 stdDeviation 回退错误，见 W4 |
| svg-document-model | M5 元素查询 API | 5 | `SvgElementApiM5_test.queries/queriesAreReadOnly` | ✅ |
| svg-document-model | M5 feDropShadow 元素模型 | 3 | `SvgDropShadowM5_test` | ✅ |
| svg-security | M5 上限与降级 | 6 | 各上限负向用例 | ⚠️ GSUB 深度缺失，见 C6 |

合计：**24 ✅ / 14 ⚠️ / 1 ❌**。

### 2.2 没有真实落点的 Scenario

以下 9 个场景没有可执行的真实落点，或落点与场景文字相反：

1. `svg-css` / calc() / **括号**：场景用 `width: calc((10px + 5px) * 2)`，但实现只对 `stroke-width` / `letter-spacing` / `word-spacing` / `font-size` / `stroke-dashoffset` 生效，`width` 不是计算样式属性（C5）。
2. `svg-value-types` / **变换参考盒**：要求 `SvgTransformBox.FillBox` / `.ViewBox`，代码中不存在该公开类型（C1）。
3. `svg-text` / 文本布局 / **连字消费列表项**：`dx="5 9"` 中 9 应被跳过，实际仍参与 `pen` 计算（C8）。
4. `svg-text` / 标准连字 / **深度上限**：lookup 链深度 8 无实现、无测试（C6）。
5. `svg-text` / M5 文本方向属性 / **竖排列顺序**：`direction` 在竖排下完全未参与列序计算（W6）。
6. `svg-css` / @font-face 别名 / **未注册目标**：默认注册表非空时，Missing 被映射到首个 family（Hershey），而不是不生效并 warning（C4）。
7. `svg-geometry` / 元素级包围盒 API / **视口裁剪**：`clipped` 只处理根视口，嵌套 `svg` 与 `viewBox` 未参与（W5）。
8. `svg-render-pipeline` / 混合与隔离 / **整组混合**：只用容器隔离测试过；形状/文本多命令元素实际逐命令混合（C7）。
9. `svg-text` / M3 文本边界 / **基础整形可用**：测试断言 `layout.glyphs.size == 2`，与「输出一个连字字形」的规范文字相反（C8/W9）。

另有 3 个场景仅弱覆盖：方向属性「不改变几何」无断言、rasterization「同一 8×8 图层两次 screen」未精确复现、`fi` 连字测试把 2 个 glyph 当作期望。

### 2.3 P1–P4 顺序

提交链顺序正确，未发现 P2 先于 P1、P4 先于 P3 的情况：

| 提交 | 阶段 | 内容 |
|---|---|---|
| `878a35d8` | 准备 | 骨架、基线、快照辅助 |
| `6296495f` | P1 | 选择器（属性/结构伪类/nth/not/兄弟/特异性/上限） |
| `70736a7e` | P1 | @media / @font-face / 变量 / calc / 新属性 |
| `0c14b252` | P2 | paint-order |
| `3a1e78a0` | P2 | 混合模式与隔离 |
| `359da01a` | P2 | feDropShadow |
| `1119e105` | P2 | transform-origin / transform-box |
| `519d83c6` | P2 | context-fill / context-stroke |
| `420059ec` | P3 | kern/GPOS、GSUB liga、UAX#9 子集、direction |
| `2ef62b12` | P4 | 元素级 API 与验收 |
| `5b7678bb` | 文档 | strict 校验完成标记 |

注意：每个阶段只有 1 个功能提交，实现与测试在同一提交内，无法从历史审计 Red-Green；见 W12。

### 2.4 任务勾选

`tasks.md` 1.1–13.6 全部勾选，13.7（合并回 master、删除分支）未完成，符合“只校验、不归档”的边界。但 1.1 声称分支为 `feature/f-svg-m5`，实际分支为 `feature/f_svg`，见 W11。

## 3. Correctness

### CRITICAL

#### C1. 公开类型 `SvgTransformBox` 完全缺失

- 规范：`svg-value-types` /「M5 变换参考盒枚举」要求公开枚举 `SvgTransformBox`（`ViewBox` / `FillBox`、`Equatable`、`ToString`、大小写不敏感解析）。
- 证据：全 `f_svg/src` 无 `SvgTransformBox` 声明；`transform-box` 只作为字符串存在于 `SvgComputedStyle.cj:121` 与 `SvgTransformOrigin.cj:96`。`SvgComputedStyleM5_test` 只断言 `style.get("transform-box") == "view-box"`。
- 影响：该 Requirement 及其唯一 Scenario 没有任何实现/测试落点；调用方无法按规范使用类型化 API。
- 结论：必须补类型并接线，或修改规范；当前实现不能宣称符合 M5。

#### C2. GPOS 未按 `kern` feature 过滤；GSUB 未按 `liga` feature 过滤

- 规范：`svg-text` /「OpenType 字距调整」要求「优先读取 GPOS 的 kern 特性 Pair Adjustment」；「标准连字」要求只应用 `liga` 特性；原始设计 `doc/f_svg-M5设计.md` §4.2 明确要求解析 ScriptList / FeatureList / LookupList 且只处理 `liga`。
- 证据：
  - `SvgOpenTypeLayout.cj:132` 直接取 `reader.u16(8)`（LookupList offset），完全跳过 ScriptList（4）与 FeatureList（6）；
  - `SvgOpenTypeLayout.cj:146` 只按 `lookupType == 2` 收集所有 PairPos；
  - `SvgOpenTypeLayout.cj:387` / `:400` 对 GSUB 同样直接读 LookupList，只按 `lookupType == 4` 收集所有连字；
  - 测试 fixture `SvgOpenTypeLayoutM5_test.cj:25`、`:37`、`:65` 把 ScriptList / FeatureList 都写成 0，因此测试永远无法验证 feature 过滤。
- 影响：任何 GPOS PairPos（包括非 `kern` 特性，如 `vkrn` 或其他特性）都会被当作字距应用；任何 GSUB Type 4（包括 `dlig` / `clig`）都会被当作 `liga`。反过来，当 GPOS 存在但没有 `kern` 特性时，`SvgTrueTypeFont.kerningAdjust`（`SvgTrueTypeFont.cj:292-297`）仍优先使用 GPOS，不会回退 `kern` 表。字距和连字结果会随字体特性集合错误变化。

#### C3. GPOS PairPos format 2 忽略 Coverage，测试把错误行为写成期望

- 规范：Pair Adjustment 的 Coverage 决定哪些左字形参与配对。
- 证据：
  - `SvgGposPairs.adjust`（`SvgOpenTypeLayout.cj:113-127`）在 class matrix 路径只查 `class1` / `class2`，从不检查 `covered`；
  - `covered` 只在 `SvgOpenTypeLayout.cj:246` 写入，之后从未读取；
  - 测试 `SvgOpenTypeLayoutM5_test.cj:116-117` 明确断言 `adjust(9, 2) == -70`，而 fixture 的 Coverage 只包含 glyph 1，glyph 9 不应有调整。
- 影响：所有未被 Coverage 覆盖的左字形都会落入 class 0 并错误获得 class pair 字距；这是 M5 字距的核心正确性问题，且现有测试把它固化为“通过”。

#### C4. `@font-face` 未注册目标被静默映射到首个已注册 family

- 规范：`svg-css` /「@font-face 别名」要求目标 family 未注册时「别名 SHALL 不生效并记 warning」；原始设计 §2.3 明确「按 family 精确匹配；未注册则不生效」。
- 证据：`SvgFont.cj:66-76` 在 `base.hasFamily(name)` 为假时取 `base.primaryFamily()` 作为目标；`defaultRegistry()`（`SvgFont.cj:125-131`）首个 family 是 `Hershey`，因此任何默认注册表下缺失目标都会被映射到 Hershey。`derived` 没有 warnings 参数，缺少目标时不可能产生 warning。
- 测试盲区：`CssFontAliasM5_test.cj:73-79` 的 `missingTarget` 使用空注册表，`primaryFamily()` 为 `None`，测试恰好通过；默认注册表/任意非空注册表场景未覆盖。
- 影响：`@font-face { font-family: Missing; src: url(x.ttf) }` 会静默使用 Hershey 而不是回退并 warning；`Body → Brand` 场景也只有在 Brand 是唯一/首个 family 时成立。

#### C5. `calc()` 的 `width` 场景未实现

- 规范：`svg-css` /「calc() 表达式」的「括号」场景要求 `width: calc((10px + 5px) * 2)` → `30px`，并声明「在长度属性上支持 calc()」。
- 证据：`SvgStyleResolver.cj:762-766` 只允许 `stroke-width` / `letter-spacing` / `word-spacing` / `font-size` / `stroke-dashoffset`；`width` 不在 `SVG_PROPERTY_TABLE`，几何属性由 `SvgLength.tryParse` 直接解析，不经过 calc。测试 `CssCalcM5_test.cj:52-54` 把同一表达式改写成 `stroke-width`，没有覆盖规范场景。
- 影响：规范中的 `width` 场景无法通过；任何 `width` / `height` 等几何长度上的 calc 都不支持。

#### C6. GSUB lookup 深度上限 8 未实现也没有负向用例

- 规范：`svg-text` /「标准连字」要求 lookup 深度不超过 8；`svg-security` /「M5 上限与降级」要求超限停止替换并 warning；`tasks.md` 10.3 声称有「lookup 深度 9」用例。
- 证据：`SvgOpenTypeLayout.cj` 只有 `CSS_GSUB_MAX_INPUT`（:22），没有任何 depth 常量、递归/链式 lookup 遍历或 depth 检查；`SvgGsubLigatures.findLigature` 只对单个已解析表做匹配。`SvgOpenTypeLayoutM5_test.cj` 没有深度用例。
- 影响：`GSUB lookup depth = 8` 的安全上限没有落地，也不存在“第 9 层停止替换”的行为；这是安全 Requirement 的直接缺口。

#### C7. `mix-blend-mode` 对多命令元素按命令混合，未过滤文本甚至丢失 blend

- 规范：`svg-render-pipeline` /「M5 混合与隔离的合成位置」要求混合在元素完成滤镜、裁剪、mask、组透明度后「作为整组结果」合成，且「SHALL NOT 对元素内部逐条命令应用混合」。
- 证据：
  - 形状的 FillPath / StrokePath 命令都携带 `blendMode: svgMixBlendModeOf(style)`（`SvgRenderTree.cj:824`、`:853`）；
  - 未过滤的文本 `Text` 命令（`SvgRenderTree.cj:479-495`）没有设置 `blendMode`，构造参数缺省为 `Normal`，因此文本的 `mix-blend-mode` 完全不会生效；只有 `filtered` 文本在 `GroupBegin` 上带 blend（`:476`）；
  - `SvgRenderer` 的 `needsLayer` 只要某个 command 的 blend 非 normal 就为该 command 单独建层并合成（`SvgRenderer.cj:212-215`、`:245`）。
- 影响：`<rect fill=... stroke=... style="mix-blend-mode: multiply">` 会先混合填充、再混合描边，而不是把填充+描边作为整体混合一次；未过滤文本的 blend 丢失；`paint-order` 与 blend 同时使用时混合结果也随命令顺序变化。`SvgBlendLayerM5_test.multiplyAppliesOnce` 只用单条填充命令的矩形，`m5-blend.svg` 也只覆盖单填充矩形，均无法发现该问题。

#### C8. 连字簇没有消费/跳过 `x`、`y`、`dx`、`dy` 列表项

- 规范：`svg-text` /「文本布局」要求连字簇视为单个布局单元，消费簇内首个字符的 `x` / `y` / `dx` / `dy` / `rotate` 列表项，其余字符的列表项 SHALL 被跳过；`svg-render-pipeline` 的连字场景也以 `dx="5 9"` 为例。
- 证据：
  - `SvgTextRenderer.cj:1336-1349` 把被消费字形的 `advances` 置 0、`paths` 置 `None`，但保留 `chars.size` / `count`；
  - `SvgTextRenderer.cj:391-406` 的定位循环仍对每个被消费的 slot 执行 `pen += char.dx` 或 `pen = char.xOverride`；
  - `SvgTextRenderer.cj:374-381` 的自然宽度与 `textLength` 计算仍对被消费 slot 计入 `letter-spacing` / `word-spacing`。
- 影响：`"fi"` + `dx="5 9"` 时总前进量会多出 9；连字后还有字符时，被消费 slot 还会额外贡献一次字距，`textLength`、`text-anchor`、后续字形位置都会偏移。`SvgKerningLayoutM5_test.ligatureReplacesAdvance` 只断言 `glyphs.size == 2` 与 advance，没有覆盖列表项。

#### C9. 文本整形管线顺序与规范相反（bidi → kern → liga）

- 规范：`svg-text` /「文本布局」明确「先应用 GSUB 连字，再应用 kern / GPOS 字距，最后按双向算法生成视觉顺序」。
- 证据：
  - `SvgTextRenderer.cj:323-324` 在任何字体解析、字距、连字之前执行 `reorderBidiChars`；
  - `SvgTextRenderer.cj:363-364` 先 `applyFontKerning`、后 `applyFontLigatures`，与「GSUB → kern/GPOS」相反。
- 影响：RTL + 连字/字距组合时，连字在视觉序列上匹配，可能跨逻辑边界；字距基于原始字符而非整形后的字形，连字消费的字形对之间的调整会被丢弃或作用于错误 pair。现有测试没有锁定管线顺序。

#### C10. `transform-origin` / `transform-box` 只覆盖主渲染路径，clipPath/mask/use/嵌套 svg/root 仍走 M4 矩阵

- 规范：`svg-render-pipeline` /「M5 transform-origin 与 transform-box」要求元素的 `transform` 按 `T(origin) × M × T(-origin)` 应用；`design.md` D8 还要求 `SvgClipMask.elementTransformMatrix` 统一走 `effectiveElementTransform`。
- 证据：
  - `SvgClipMask.cj:648` 仍是 M4 的私有 `elementTransformMatrix(element)`，只返回 `transform.toMatrix()`；`:296`、`:401` 的 clip/mask 子元素都调用它；
  - `SvgRenderTree.cj:265`（root）、`:605`/`:608`（嵌套 svg）、`:726`（use 目标）调用不带 style 的 `elementTransformMatrix`；
  - `SvgRenderTree.cj:436-441`（text）与 `:522-527`（container）调用 `elementTransformMatrix` 时没有传 `bounds`，所以 `transform-box: fill-box` 在 `g` / `text` 上退化为 viewport 参考盒；
  - `SvgElementApi.cj:144-148` 的容器子元素 bbox 也使用裸 `transform.toMatrix()`。
- 影响：clipPath/mask 内容、`use` 目标、嵌套 `svg`、根元素、`g`/`text` 的 `fill-box` 百分比原点都与渲染矩阵不一致；同一元素在 `getCTM` 与渲染中可能得到不同矩阵。

### WARNING

#### W1. 公开 API 形状与规范不一致

- `svg-value-types` 要求 `SvgFontKerning` 为枚举，实际是 `public struct`（`SvgBidi.cj:83`），用 static let 模拟 `Auto` / `Normal` / `None`；
- proposal 第 83 行声称 `SvgGeometry.screenCTM` 新增可选计算样式上下文重载，实际只给 `ctm` 增加 `styles`（`SvgGeometry.cj:180` / `:229`），`screenCTM` 仍是 M4 签名。

#### W2. `SvgContextPaint.cj` 仍是 TODO 骨架

`SvgContextPaint.cj:22` 只有 `// TODO(M5): SvgContextPaint`；实际逻辑散落在 `SvgPaint.cj` 与 `SvgRenderTree.cj`。功能通过测试，但 `design.md` D14 的文件职责映射未落实，后续维护者会被误导。

#### W3. `paint-order` 对未知关键字采用整值回退，而不是丢弃未知项

- 规范：`svg-value-types` /「M5 枚举回退」要求未知关键字「被丢弃后按默认顺序补齐」。
- 证据：`SvgStyleResolver.cj:694` 走 `normalizeCssPaintOrder`；该函数遇到未知 token 直接返回 `None`，随后级联回退初始值 `fill stroke markers`，而不是保留合法项。`paint-order="stroke shadows fill"` 会得到 `fill stroke markers`，按规范应为 `stroke fill markers`。
- 现有测试只覆盖 `shadow fill`（合法项恰好与默认顺序一致），无法区分两种语义。

#### W4. `feDropShadow` 非法参数降级不完整

- `SvgFilterPrimitives.cj:507-510` 对负 `stdDeviation` 记 warning 后按 **0** 处理；规范要求回退缺省值 **2**（`svg-filter` /「feDropShadow 参数与区域」）。
- 非法 `flood-color` 在 `SvgFilterPrimitive.cj:360-365` 的 getter 中 `tryParseSvgPaint` 返回 `None` 后直接缺省黑色，没有 warning；规范要求「非法颜色 SHALL 回退缺省值并记 warning」。
- `SvgDropShadowRenderM5_test.cj:84-91` 的 `invalidParameters` 只检查 `warnings` 是否含 `stdDeviation`，不检查回退值，属于假负向覆盖。

#### W5. `getBBox` 的裁剪/不可渲染语义与测试覆盖不足

- `SvgElementApi.cj:189-210` 的 `applyBBoxClip` 只处理 `SvgRoot`，注释虽写「只处理根与非嵌套 svg 视口」，代码没有嵌套 `svg` / `viewport` 分支；`viewBox` 也未参与裁剪矩形（用 `viewport.width` / `height`）。
- `svgBBoxOf` 未检查 `display:none` / `visibility:hidden`，容器只有隐藏后代时仍返回包围盒，与「无可见后代返回 None」不符。
- `svgContainerBBox` 的子变换使用裸 `transform.toMatrix()`（`SvgElementApi.cj:144-148`），忽略 `transform-origin`。
- `svgUseBBox` 无循环保护（`<use href="#u">` 自引用可无限递归），也未应用目标元素自身的 `transform`；`symbol` 目标返回 `None`。
- 测试只覆盖根视口裁剪、矩形/组/use/image，没有文本 bbox、`SvgBBoxOptions.fonts`、`a`/`switch`/嵌套 `svg` 的用例。

#### W6. bidi / 竖排 / rotate 列表绑定不完整

- `unicode-bidi: embed` 在 `SvgTextRenderer.cj:1240-1265` 与 `normal` 走完全相同的路径，没有建立嵌入层；`direction` / `unicode-bidi` 取的是 `<text>` 根样式，`tspan` 上的方向被忽略。
- `SvgBidi.cj` 的 `svgBidiLevels` 不对 `B` 分段，多个段落会作为一段重排。
- `SvgDirectionM5_test.cj:98-106` 的竖排用例只断言首字符不被重排，没有验证两列的列序；实现中 `direction` 完全不参与列序。
- `rotate` 在重排后按视觉下标取（`SvgTextRenderer.cj:558`、`:573`），与规范「列表在逻辑字符上绑定」不符；rotate + bidi 无测试。

#### W7. `transform-origin` 的 em/ex 与关键字顺序

- `SvgTransformOrigin.cj:146-150` 将 `Em` 固定按 16px、`Ex` 固定按 8px 换算，没有使用元素计算 `font-size`。
- `normalizeCssTransformOrigin` 只接受「水平 + 垂直」顺序，`top left` 这类合法 CSS 双关键字顺序会被判非法；规范未明确禁止，但与 CSS 行为不一致。

#### W8. `@font-face` 的 `font-weight` / `font-style` 解析后未使用

`CssStyleSheet.cj:299-313` 保存 `weight` / `style` 到 `CssFontFaceRule`，但 `SvgFontRegistry.derived`（`SvgFont.cj:63-76`）完全忽略它们；别名对所有 weight/style 生效，不会按 `@font-face` 声明的组合限定。规范要求别名区分 weight/style。

#### W9. GSUB 输入上限的边界与跨 tspan 连字

- `SvgOpenTypeLayout.cj:463` 的检查是 `componentCount > CSS_GSUB_MAX_INPUT + 1`，即 5 个输入字形仍可进入规则表；`findLigature` 随后在 `consumed > 4` 时静默跳过，没有 warning。规范的安全上限是 4，负向用例只覆盖了 5 个字形规则的最终不匹配。
- `SvgTextRenderer.applyFontLigatures`（`:1329-1338`）构建 `remaining` 时没有在 tspan 的字体/字号边界截断，可能跨不同字体形成连字，违反「同一文本 run」语义。

#### W10. README 对 M5 能力的描述超过实现

- `README.md:530-538` 声称 GPOS 按 `kern` 特性优先、GSUB 只处理 `liga`、lookup 深度上限 8、连字簇消费首个字符列表项；这些在当前代码中不成立（C2/C6/C8/C9）。
- `README.md:544-546` 声称 `embed` 建立嵌入层、`direction` 决定竖排列序；实现未做到（W6）。
- `README.md:334` 的「M4 限制」仍写「不解析 GSUB / GPOS / kern，字距只来自 hmtx」，与同文件 528 行后的 M5 章节自相矛盾。

#### W11. 主规格与变更规格不一致

`openspec/specs/svg-css/spec.md:14-16` 仍规定 `@media` / `@font-face` / 伪类 / 属性选择器 / 兄弟组合器一律不支持；`openspec/specs/svg-text/spec.md:145` 仍写「双向文本与复杂字形整形不在支持范围」，`:408` 仍写 `advance` 不应用 kern/GSUB/GPOS。归档前主规格与实现、delta 规范三方矛盾。这是「未归档」的预期状态，但当前仓库不能仅读主规格来判断行为。

#### W12. 分支名、13.7 与 TDD 可审计性

- `tasks.md:10` 要求分支 `feature/f-svg-m5`，实际 `git branch --show-current` 为 `feature/f_svg`；13.7 未勾选（合并回 master、删分支未执行）。
- 每个阶段只有一个功能提交，测试与实现同提交；从 git 历史无法验证「先写失败用例、再实现」。这不等于未做 TDD，但不能作为已完成 Red-Green 的证据。

#### W13. M5 场景快照的覆盖与自证问题

- `m5-shaping.svg` 使用 `font-family="Hershey"`，Hershey 不含 `kern` / `GPOS` / `GSUB`，该快照不可能覆盖整形；它实际只覆盖 bidi/方向。
- `m5-element-api.svg` 只包含 CSS 规则和渲染，不调用 `getBBox` / `getCTM` / `querySelectorAll`，快照名与覆盖对象不符。
- 8 张 `m5-*.rgba` 均在 P4 提交 `2ef62b12` 中由当前实现生成；它们只能证明确定性，不是独立正确性 oracle。

#### W14. 元素级 API 的媒体宽度与绝对包围盒上下文

- `SvgElement.getBBox` 在 `SvgElement.cj:329-335` 用 `SvgStyleResolver().compute(root)`（默认 mediaWidth 300）计算样式；`getCTM` 同样默认 300（`SvgElementApi.cj:219-227`）。对含 `@media` 的文档，`getBBox` / `getCTM` 的样式可能与 `render(options.width=800)` 不一致。
- `SvgGeometry.absoluteBounds` 通过 `ancestorTransform`（`SvgGeometry.cj:937-945`）使用固定 300×150 作为 `view-box` 参考，与真实视口不一致。

### SUGGESTION

1. 为 GPOS/GSUB fixture 补真实 ScriptList / FeatureList，并新增「GPOS 存在但无 `kern` 特性时回退 kern 表」「Type 4 存在但无 `liga` 时不应用」的负向用例。
2. 补 §2.2 列出的 9 个场景测试：`width: calc()`、`SvgTransformBox`、连字列表项、GSUB 深度、竖排列序、@font-face 缺失目标、嵌套 svg 裁剪、整组混合、单连字字形。
3. 重新设计 M5 场景：`m5-shaping` 使用含 `kern`/`GPOS`/`GSUB` 的最小 TTF；`m5-element-api` 增加 API 结果的可断言输出，或改名为 `m5-css-query`。
4. 归档前同步 `openspec/specs/svg-*` 主规格；同时修正 README 的 M4 限制段落与 M5 章节的矛盾。
5. 将 `SvgContextPaint.cj` 落实为实现文件，或修改 `design.md` 的文件地图，避免“设计说在这里、代码在别处”。
6. 为多命令元素（填充+描边、文本多字形）增加 `mix-blend-mode` 像素级回归，锁定“整组一次混合”的结果。

## 4. 专项复核

### 4.1 M1–M4 的 17 张快照

复核方法：

1. 读取 `doc/perf-baseline.md` 的 M5 快照 SHA-256 表（在准备提交 `878a35d8` 中即已存在，未被后续 M5 提交修改）；
2. 对当前 17 个 `.rgba` 重新执行 `sha256sum`；
3. 检查 `git log`，确认 M5 功能提交没有修改这 17 个旧 `.rgba`；
4. 运行 `SvgSnapshotM5_test`：10 张 M1–M3 静态 + 3 张动画帧 + 4 张 M4，全部使用 `m5CompareExact`（容差 0）。

结果：

| 组 | 数量 | 结果 |
|---|---|---|
| M1–M3 静态（basic/gradient/stroke/clip/text/m3-filter/m3-pattern/m3-image/m3-textpath/m3-marker） | 10 | 17/17 SHA-256 一致，测试通过 |
| M1–M3 动画（animation-0/05/1） | 3 | 同上 |
| M4（m4-clip/m4-filter/m4-text/m4-view） | 4 | 同上 |

结论：**17 张既有快照仍逐字节一致 ✅**。未发现“先改 `.rgba` 再宣称零回归”的情况。

### 4.2 M5 上限负向用例

| 上限 | 负向用例 | 结果 |
|---|---|---|
| CSS 变量 8 层 | `CssVariablesNegativeM5_test.eightLevelsAreAccepted` / `nineLevelsAreRejected` | ✅ |
| calc() 16 层 | `CssCalcM5_test.nestingLimit`（16 有效、17 无效） | ✅ |
| 选择器 256 个简单选择器 | `CssSelectorLimitM5_test.atLimitIsAccepted` / `compoundOverLimitIsSkipped` / `descendantChainOverLimitIsSkipped` | ✅ |
| kern 65536 条 | `SvgKernTableM5_test.pairLimit`（7×10000=70000） | ✅ |
| GPOS 65536 pair | `SvgOpenTypeLayoutM5_test.pairLimit`（300×300 class matrix） | ⚠️ 覆盖 class matrix 上限，不是 65537 条 pair record 的精确场景 |
| GSUB lookup 深度 8 | 无 | ❌ 见 C6 |
| 单次连字输入 4 | `SvgOpenTypeLayoutM5_test.inputLimit`（5 字形规则不匹配） | ✅（边界 warning 见 W9） |

结论：**7 项中 6 项有负向用例，GSUB 深度 1 项完全缺失**；GPOS 的负向用例与规范文字的场景不完全同构。

## 5. 假覆盖清单（实现后补测试）

以下测试能通过，但没有证明规范行为，部分甚至把错误行为写成期望：

1. **GPOS/GSUB feature 测试**：fixture 的 ScriptList / FeatureList 均为 0（`SvgOpenTypeLayoutM5_test.cj:25` / `:37`），解析器跳过 feature 的缺陷无法暴露（C2）。
2. **GPOS format 2 Coverage**：测试断言未覆盖的 glyph 9 也获得 -70（`SvgOpenTypeLayoutM5_test.cj:116-117`），把 bug 固化为期望（C3）。
3. **@font-face 未注册目标**：`missingTarget` 使用空注册表（`CssFontAliasM5_test.cj:73-79`），绕开了默认注册表的 primary-family 回退（C4）。
4. **feDropShadow 非法参数**：只检查 warning 字符串存在，不检查负 stdDeviation 是否回退到 2、非法 flood-color 是否有 warning（W4）。
5. **连字布局**：`ligatureReplacesAdvance` 断言 `glyphs.size == 2`，没有 `dx`/`x`/`letter-spacing`/`textLength` 断言（C8）。
6. **clipped bbox**：仅根视口用例（`SvgElementApiM5_test.clippedBBox`），嵌套 svg 未覆盖（W5）。
7. **m5-shaping 快照**：使用 Hershey，字体不含任何 OpenType 表，无法证明 shaping（W13）。
8. **m5-element-api 快照**：不调用元素 API，无法证明 P4（W13）。
9. **竖直 bidi**：`verticalSkipsBidi` 只断言首字符 codePoint，没有两列/列序断言（W6）。

## 6. Coherence

- **规范 ↔ 实现**：delta spec 的 39 个 Requirement 中 1 个完全无实现（`SvgTransformBox`），14 个部分偏差；主规格仍停留在 M2/M4，与 delta 规范和实现冲突（W11）。
- **设计 ↔ 实现**：`design.md` D8 要求 `SvgClipMask` 统一走 `effectiveElementTransform`，实际仍用 M4 私有函数（C10）；D14 指定 `SvgContextPaint.cj` 承载上下文逻辑，实际是 TODO 骨架（W2）。
- **README ↔ 实现**：README 的 M5 章节声称 feature 过滤、GSUB 深度、连字列表项、`embed`、竖排列序均已支持，实际多项不成立（W10）。
- **任务 ↔ 仓库**：`tasks.md` 的 13.7 未完成；1.1 的分支名与实际分支不一致（W12）。
- **测试 ↔ 规范**：9 个场景无真实落点，3 个弱覆盖；多项测试以实现内部结构（glyph 数量、fixture 缺 feature 表）为期望，形成假覆盖（§5）。

## 7. 最终判定

M5 的工程门禁（941 测试、0 f_svg warning、17 张旧快照逐字节一致、P1→P4 顺序）是达标的；但规范符合度不达标。10 个 CRITICAL 中有多个会直接产生错误的字距、连字、混合、变换或字体选择结果，且现有测试无法发现，部分测试甚至把错误结果写成通过条件。

在这些 CRITICAL 修复前，本变更不应归档为“M5 完成”。

CRITICAL=10

## 8. 修复结果（2026-11-07）

- 分支：`feature/f_svg`；基线：`5b7678bb`
- 修复提交：`83ebf85d`、`ac149cc6`、`44ea4177`、`e71103da`、`4a54a0ad`、`cc2a04a3`、`ca72d35c`、`98580139`、`f72f24c1`
- 最终门禁：`cjpm test` TOTAL **987 / PASSED 987 / FAILED 0**；`cjpm build success`，`f_svg` 自身 **0 warning**（22 条 warning 全部来自依赖 `f_xml`）
- 17 张 M1–M4 快照：**17/17 SHA-256 与 `doc/perf-baseline.md` 一致**

### 8.1 CRITICAL

| 编号 | 修复内容 | 主要用例 | 结果 |
|---|---|---|---|
| C1 | 新增公开枚举 `SvgTransformBox`，计算样式 `transformBox()` 与渲染/几何统一取值 | `SvgTransformBoxM5_test.parseAndRoundTrip` / `computedStyleUsesEnum` | ✅ |
| C2 | GPOS/GSUB 解析 ScriptList → FeatureList → LookupList，仅应用 `kern` / `liga`；无特性时回退 kern 表 | `SvgGposM5_test.otherFeatureIsIgnored`、`SvgGsubM5_test.otherFeatureIsIgnored`、`SvgKerningLayoutM5_test.gposWithoutKernFallsBackToKern` / `gsubWithoutLigaDoesNotApply` | ✅ |
| C3 | GPOS PairPos format 2 先检查 Coverage，未覆盖左字形调整量为 0 | `SvgGposM5_test.pairFormatTwo` | ✅ |
| C4 | `@font-face` 目标未注册时不建立别名、不回退首个 family，并记 warning | `CssFontAliasM5_test.missingTargetDoesNotUsePrimaryFamily` / `missingAliasFallsBackToNextFamily` | ✅ |
| C5 | `x/y/width/height/cx/cy/r/rx/ry` 进入级联表并支持 `calc()`；几何/渲染优先读计算样式，元素 getter 保持原语义 | `CssGeometryCalcM5_test` 4 条用例 | ✅ |
| C6 | GSUB 特性 lookup 链深度上限 8，第 9 层停止替换并 warning | `SvgGsubM5_test.lookupDepthLimit`（深度 8 正常、9 停止） | ✅ |
| C7 | `mix-blend-mode` 移到元素级 `GroupBegin`，内部命令不再逐条混合；覆盖形状、文本、image | `SvgElementBlendM5_test` 5 条（结构 + 像素参考） | ✅ |
| C8 | 连字簇作为单布局单元：只消费簇首 `x/y/dx/dy/rotate`，输出单个字形，后续定位与 `textLength` 只按簇首计算 | `SvgKerningLayoutM5_test.ligatureReplacesAdvance` / `ligatureConsumesDxList` / `ligatureConsumesXList` / `ligatureConsumesRotateList` | ✅ |
| C9 | 整形顺序改为 GSUB 连字 → kern/GPOS 字距 → bidi 视觉重排；镜像后按新码点重取字形 | `SvgKerningLayoutM5_test.ligatureAppliedBeforeBidi` / `kerningUsesShapedGlyphs` | ✅ |
| C10 | `effectiveElementTransform` 接入 clipPath/mask 子元素、root、嵌套 svg、use 目标、`g`/`text` fill-box、元素级 bbox 与 CTM | `SvgTransformPathM5_test` 4 条、`SvgBBoxM5_test.containerChildTransformOrigin` | ✅ |

### 8.2 WARNING

| 编号 | 修复内容 | 主要用例 | 结果 |
|---|---|---|---|
| W1 | `SvgFontKerning` 改为枚举；`SvgGeometry.screenCTM` 增加可选样式上下文重载 | `SvgDirectionM5_test.enumParsing`、`SvgTransformPathM5_test.screenCtmAcceptsStyles` | ✅ |
| W2 | `SvgContextPaint.cj` 落实为实际实现文件，迁入 `useContextFrame` / `resolveContextPaintOf` | `SvgContextPaintM5_test`、`SvgContextPaintRenderM5_test` | ✅ |
| W3 | `paint-order` 未知关键字逐项丢弃并 warning，合法项保留后补齐默认顺序 | `SvgPaintOrderM5_test.unknownKeywordIsDroppedInComputedStyle` | ✅ |
| W4 | 负 `stdDeviation` 回退 2（含滤镜区域外扩）；非法 `flood-color` 回退黑色 + warning | `SvgDropShadowRenderM5_test.negativeDeviationFallsBackToDefault` / `invalidFloodColorFallsBackToBlack` | ✅ |
| W5 | `getBBox` 支持嵌套 svg viewBox 裁剪、`display:none` / `visibility:hidden`、use 循环保护、symbol 目标、子变换走 `effectiveElementTransform` | `SvgBBoxM5_test` 5 条、`SvgElementApiM5_test.clippedBBox` | ✅ |
| W6 | `unicode-bidi: embed` 嵌入层、tspan 方向、`B` 分段、竖排 `direction` 列序、rotate 逻辑字符绑定 | `SvgDirectionM5_test.tspanDirectionRtl` / `embedCreatesLayer` / `paragraphBreakSegmentsBidi` / `verticalColumnOrderFollowsDirection` / `rotateFollowsLogicalCharacters` / `directionDoesNotChangeGeometry` | ✅ |
| W9 | GSUB 输入上限严格为 4；连字不跨 tspan 字体/字号边界 | `SvgGsubM5_test.inputLimit`、`SvgKerningLayoutM5_test.ligatureDoesNotCrossTspanBoundary` | ✅ |
| W10 | README 的 M4 限制段与 M5 章节对齐（中英文） | `README.md` / `README_en.md` | ✅ |
| W11 | 主规格与 M5 行为同步（`openspec/` 被 `.gitignore` 忽略，仅工作树生效） | `openspec/specs/svg-css/spec.md`、`openspec/specs/svg-text/spec.md` | ✅ |
| W14 | `getBBox` / `getCTM` / `getScreenCTM` 增加 `mediaWidth` / `mediaHeight`；`absoluteBounds` 接收真实视口 | `SvgBBoxM5_test.bboxMediaWidth` / `ctmUsesViewportFallback` / `absoluteBoundsUsesViewport` | ✅ |

### 8.3 SUGGESTION

| 编号 | 处理 | 结果 |
|---|---|---|
| S1 | GPOS/GSUB fixture 改为真实 ScriptList / FeatureList，并补特性缺失与 Coverage 负向用例 | ✅ |
| S2 | 9 个场景测试全部落地（C1/C5/C6/C8/W5/W6/C4/C7/C9） | ✅ |
| S3 | `m5-shaping` 改用含 `kern` / `GPOS` / `GSUB` 的最小 TTF；`m5-element-api` 增加元素 API 可断言结果 | ✅ |
| S5 | 与 W2 合并，`SvgContextPaint` 文件职责落实 | ✅ |
| S6 | 多命令形状、文本与显式混合组的像素回归 | ✅ |
| S4 | 不在本轮 fix-plan 的第 3 节清单内；主规格同步由 W11 覆盖 | — |

### 8.4 结论

CRITICAL=0；第 2 节要求的 WARNING 全部落地；第 3 节 SUGGESTION 已处理；第 4 节记录不改项未动。M1–M4 公开 API 语义未改，17 张既有快照逐字节一致。
