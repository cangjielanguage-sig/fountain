# add-f-svg-m4 校验报告

校验时间：2026-11-06
校验对象：`openspec/changes/add-f-svg-m4` 的 `proposal.md`、`design.md`、`tasks.md`、10 个 delta spec，`openspec/specs/svg-*` 主规格，`f_svg/src` 与全部 `*_test.cj`
校验方式：静态对照 + 源码审阅 + 测试执行；未修改任何实现代码，未归档。

## 1. 执行结果摘要

- `cjpm test`：`TOTAL: 656 / PASSED: 656 / FAILED: 0`，基线 533 条无失败。
- `cjpm build`：成功；`f_svg/src` 自身未出现 warning，依赖 `f_xml` 产生 22 条 warning。
- delta spec 统计：10 个能力、43 个 Requirement、145 个 Scenario，计数与任务/提案一致。
- 结论：主体实现完整，A/B/C 三组代码均已落地；但存在 5 个 CRITICAL，主要集中在 M3 字节一致性验收缺失、`screenCTM` 矩阵顺序错误、TTF 恶意输入边界、公开 API 与 spec 不一致、形态学半径无上限。

## 2. Completeness（完整性）

### 2.1 Requirement / Scenario 落点总表

| 能力 | Requirement | Scenario | 落点判定 |
|---|---:|---:|---|
| svg-value-types | 5 | 11 | 完整；公开类型形状存在 1 处不一致（见 C4） |
| svg-css | 3 | 8 | 完整 |
| svg-geometry | 4 | 15 | 场景均有测试；`screenCTM` 语义错误（见 C2） |
| svg-rasterization | 1 | 4 | 完整 |
| svg-paint-and-clip | 3 | 12 | 完整；旋转视口裁剪使用 AABB（见 W7） |
| svg-document-model | 3 | 9 | 完整；`anchors()` 对无 href 的 `a` 有偏差（见 W8） |
| svg-render-pipeline | 4 | 13 | 12 个有直接断言，`多语言优先级` 缺测试（W2） |
| svg-security | 4 | 12 | 7 个有直接断言，3 个仅部分覆盖（W2） |
| svg-text | 8 | 31 | 29 个有直接断言，2 个仅部分覆盖（W2） |
| svg-filter | 8 | 30 | 27 个有直接断言，3 个仅部分覆盖/未覆盖（W2） |
| **合计** | **43** | **145** | 43/43 Requirement 至少有一个 Scenario；134/145 Scenario 有独立可判定断言 |

说明：43 个 Requirement 全部至少有一个 Scenario，未发现“Requirement 无 Scenario”的硬缺口。145 个 Scenario 也都能在实现中找到对应代码路径；问题在于其中 9 个缺少独立测试断言，详见 2.2。

### 2.2 缺少独立断言的 9 个 Scenario

| # | 能力 | Scenario | 现状 |
|---|---|---|---|
| 1 | svg-filter | 锐化核 | `SvgFilterPrimitives2M4_test.convolve` 只测单位核/均值核/bias/edgeMode/preserveAlpha；`m4-filter.svg` 虽含锐化核，但只做快照，没有“边缘像素高于内部像素”的断言 |
| 2 | svg-filter | 零尺寸输入 | 没有 0×0 缓冲测试；`SvgFilterPrimitives2` 各原语对 0×0 直接返回空缓冲，未追加 warning |
| 3 | svg-filter | 非有限参数 | 只测了 `surfaceScale="nan"` 与 kernel 的 NaN；未测 spec 示例 `feDisplacementMap scale="nan"` |
| 4 | svg-render-pipeline | 多语言优先级 | 未构造 `languages=["en","zh"]`、子元素顺序 `zh` 在前的用例；现有测试只验证单语言/默认语言 |
| 5 | svg-security | 解码预算共享 | 只验证 `feImage` 单独超预算；未验证同一次渲染中 `<image>` 与 `feImage` 共用 `SvgDecodeBudget` 的累计超限 |
| 6 | svg-security | 渲染不加载文件 | 没有 `font-family="file:///etc/fonts/x.ttf"` 的渲染用例；实现确实不读文件，但该安全场景没有回归测试 |
| 7 | svg-security | 元素总数仍受限 | 既有 `SvgSecurity_test.maxElements` 未包含 `switch` 子元素；未验证 `switch` 不绕过 `maxElements` |
| 8 | svg-text | 截断表 | `tableDirectoryAndReaders` 截断的是整个文件头，`locaNonMonotonic` 改的是单调性；没有“字节在 loca 表中间截断”的专用用例 |
| 9 | svg-text | 两列顺序 | `twoColumns` 通过显式 `x=[20,20,10,10]` 构造两列，未验证无显式 `x` 时的列容量/列推进行为 |

### 2.3 A/B/C 三包与任务完成度

- A 包：`clip` / `overflow` / `vector-effect`（A1–A3）和 7 类滤镜原语、光照（A4–A10）、`pattern` 视口（A11）均有对应源文件和测试。
- B 包：基线、装饰线、书写模式、`textPath` 扩展、TrueType（B1–B5）均已落地；`SvgTrueTypeTables` 的测试实际写在 `SvgTrueTypeM4_test.cj`，未单独创建 `SvgTrueTypeTables_test.cj`（任务命名偏差，非功能缺陷）。
- C 包：`view` / `switch` / `anchors` / 路径长度 / CTM 均已落地；C5 的 `screenCTM` 存在矩阵顺序错误（C2）。
- 任务清单除 `18.8` 外均为 `[x]`。`18.8`（合并回上游并删除分支）仍未完成，这与本次“不归档、只校验”的约束一致，但意味着变更验收尚未闭环。
- 任务勾选存在“提前打勾”：
  - `5.3` 的 `edgeMode` 三档：实现支持 `wrap`，但没有专门的 `wrap` 行为断言。
  - `6.4` 的 `preserveAspectRatio` 三档与 base64 超限：只测了 meet/none，slice 与 base64 长度上限未测。
  - `8.2` 的“无 viewBox 输出与 M3 一致”：只做了像素点断言，未做字节比较。
  - `10.3` 的“渐变按字形起点取样”：实现未按字形起点取样（W5）。
  - `12.3` 的“缺省行为与 M3 逐字节一致”：只比较了同一套新实现的两个入口，未与 M3 字节比较。
  - `17.5` 的“M1–M3 全部快照仍逐字节一致”：实际没有 M3 字节级用例（C1）。
  - `18.6` 的 `openspec validate --strict`：本机无 `openspec`，未执行，仅人工核对。
- 顺序：任务文档与代码分层符合设计 §8 的 A1–A3 → A4–A10 → A11 → B1–B2 → B3–B4 → B5 → C1–C3 → C4–C5。由于 git 元数据不可用（见第 5 节），无法核验真实提交顺序；文件 mtime 显示 B5（08:03–08:39）与 C1–C3（08:17–08:18）时间重叠，不能证明严格串行。

### 2.4 上限负向用例

spec 明确列出的上限均有负向用例：

| 上限 | 负向用例 | 结果 |
|---|---|---|
| `feConvolveMatrix order` 任一维 > 9 | `SvgLimitsM4_test.limits`、`SvgFilterPrimitives2M4_test.convolveValidation` | 抛 `Limit` |
| `feTurbulence numOctaves` > 8 | `SvgLimitsM4_test.limits`、`SvgFilterNoiseM4_test.turbulence` | 抛 `Limit` |
| TTF 表目录项 > 64 | `SvgTrueTypeM4_test.tableLimits` | 抛 `Limit` |
| TTF 单表 > 16 MiB | `SvgTrueTypeM4_test.tableLimits` | 抛 `Limit` |
| TTF 单字形点数 > 10000 | `SvgTrueTypeM4_test.fontLimits` | 抛 `Limit` |
| TTF 复合字形深度 > 8 | `SvgTrueTypeM4_test.fontLimits` | 抛 `Limit` |
| `feImage` 解码预算 | `SvgFilterNoiseM4_test.feImageDataAndBudget`、`SvgLimitsM4_test.limits` | 抛 `Limit` |

缺口：`feMorphology.radius` 没有上限也没有负向用例，见 C5；`<image>` 与 `feImage` 共享预算的累计场景没有专门用例（W2）。

## 3. Correctness（正确性）

### CRITICAL

#### C1. M3 默认渲染“逐字节一致”没有验收用例

证据：

- `f_svg/src/SvgScene_test.cj:28-54` 的 `compareScene` 容差为 1，逐通道 `difference > 1` 才失败。
- `f_svg/src/SvgScene_test.cj:95-120` 的 5 个 M3 场景全部调用 `compareScene`，即只保证 ±1。
- `f_svg/src/SvgScene_test.cj:124-180` 的 `SvgSceneByteBaseline_test` 只覆盖 M1/M2 的 `basic` / `gradient` / `stroke` / `clip` / `text` / `animation-*`，没有覆盖 `m3-filter` / `m3-pattern` / `m3-image` / `m3-textpath` / `m3-marker`。
- `openspec/changes/add-f-svg-m4/tasks.md:135` 声称“确认 M1–M3 全部快照仍逐字节一致”，实际不成立。
- `f_svg/README.md:269` 与 `README_en.md:263` 对外声称“未声明 M4 属性的文档渲染输出与 M3 逐字节一致”，但没有对应门禁。

补充观察：`m3-*.rgba` 的修改时间为 2026-11-05 19:29，早于 M4 代码（2026-11-06 06:35 之后），说明快照确实是 M3 期望图；但测试只允许 ±1，不能证明当前输出与快照逐字节相同。`m3-marker.svg` 的三个 marker 内容都在各自视口内，因此 marker 新裁剪理论上不影响该快照；`m3-textpath` 的弧长采样被重构为 `SvgPathMeasure.buildSegments(..., refine: false)`，是最可能出现 1 级漂移的点，但没有字节级断言。

影响：这是本变更最核心的兼容性验收条件，当前“通过”不能证明“逐字节一致”。

建议：为 5 个 M3 快照增加与 `SvgSceneByteBaseline_test.compareExact` 相同的逐字节断言，并纳入 CI；在此之前不要宣称 M3 字节一致。

#### C2. `SvgGeometry.screenCTM` 矩阵乘法顺序错误

证据：

- `f_svg/src/SvgGeometry.cj:168-171`：
  `ctm(element).multiply(viewport.matrix).multiply(SvgMatrix.scale(dpr, dpr))`
- 渲染器实际顺序见 `f_svg/src/SvgRenderTree.cj:215-217`：
  `scale(dpr).multiply(viewport.transform(root)).multiply(elementTransformMatrix(root))`，随后逐级右乘元素变换。
- `SvgMatrix.multiply` 是标准矩阵乘（`A.multiply(B)` 先应用 B，见 `SvgMatrix.cj:67-83`），因此正确顺序应为
  `scale(dpr) × viewport.matrix × ctm(element)`；
  当前实现是 `ctm(element) × viewport.matrix × scale(dpr)`。
- 测试 `f_svg/src/SvgGeometryApiM4_test.cj:139-156` 只使用无 `transform` 的 `rect`，即 `ctm == identity`，恰好掩盖了顺序错误；`viewBox` 也没有 meet/slice 产生的平移。

最小反例：文档 100×100、`viewBox="0 0 50 50"`、`devicePixelRatio=2`，`<g transform="translate(10,10)"><rect/></g>`。

- 渲染器：`S2 × V2 × T(10,10)` 把 `(0,0)` 映射到 `(40,40)`。
- 当前 `screenCTM`：`T(10,10) × V2 × S2` 把 `(0,0)` 映射到 `(10,10)`。

即使 `ctm == identity`，当 `preserveAspectRatio` 产生 meet 平移时，`viewport × scale` 与 `scale × viewport` 也会给出不同结果（平移是否被 DPR 缩放）。

影响：C5 的公开 API 在带 `transform` 或 meet/slice 平移的元素上返回错误的设备矩阵，违反“结果 SHALL 与渲染器为该元素生成的设备矩阵一致”。

建议：改为 `scale(dpr).multiply(viewport.matrix).multiply(ctm(element))`，并增加“带 `g transform` + viewBox meet”的用例。

#### C3. TTF 对恶意 `endPtsOfContours` 可抛出非 `SvgException` 的越界异常

证据：

- `f_svg/src/SvgTrueTypeFont.cj:333-339`：`pointCount = endPoints[numberOfContours - 1] + 1`，只检查最后一项是否超过 10000，没有检查 `endPtsOfContours` 单调递增。
- `f_svg/src/SvgTrueTypeFont.cj:410-414`：按每个 contour 的 `endPoint` 调用 `appendTtfContour`。
- `f_svg/src/SvgTrueTypeFont.cj:578-612`：`appendTtfContour` 以 `startPoint + index` 访问 `flags` / `xs` / `ys`，数组长度只有 `pointCount`。
- 若字体声明 2 个 contour，`endPoints = [1000, 1]`，则 `pointCount = 2`，第一个 contour 会访问索引 1000，直接触发运行时数组越界异常；该异常不是 `SvgException(kind: Syntax)`，会穿透 `SvgTrueTypeFont.parse` / `glyphPath` / 渲染链。
- 现有 `SvgTrueTypeM4_test.fontLimits` 只改最后一项制造点数超限，没有覆盖“非单调 endPts”这条路径。

同类风险：

- `f_svg/src/SvgTrueTypeTables.cj:116` 使用 `String.fromUtf8(bytes[entry..entry + 4])` 读取表 tag。恶意 tag 字节不是合法 UTF-8 时，可能抛出 `String.fromUtf8` 的非法参数异常，而不是 `Syntax`。
- 表/字形的读取只校验整个文件边界，未校验“当前表/当前字形的局部边界”；`head.length < 20`、`cmap` 子表长度不足等结构错误可能读到相邻表数据并继续误解析（W3）。

影响：违反 spec“截断或结构错误 SHALL 抛 `SvgException(kind: Syntax)`”，对直接 `parse(Array<Byte>)` 的调用方和渲染链都构成健壮性/安全缺口。

建议：

1. 在 `parseSimpleGlyph` 中校验 `endPoints[i] < endPoints[i+1]` 且最后一项 < 10000，失败抛 `Syntax`；同时在 `appendTtfContour` 入口再次检查 `endPoint < pointCount`。
2. 表 tag 改为按字节读取/ASCII 校验，非法 tag 抛 `Syntax`。
3. 所有表读取改为带 `table.offset/length` 的局部边界读取器。

#### C4. `SvgVectorEffect` 公开 API 与 spec 不一致

证据：

- delta `openspec/changes/add-f-svg-m4/specs/svg-value-types/spec.md:50` 要求公开枚举：
  `SvgVectorEffect`：`None` / `NonScalingStroke`，字符串形式 `none` / `non-scaling-stroke`。
- 实现 `f_svg/src/SvgVectorEffect.cj:26-52` 是 `class`，用私有 `ordinal` 和静态属性 `NoEffect` / `NonScalingStroke` 建模，没有 `SvgVectorEffect.None`。
- 测试也按实现写：`f_svg/src/SvgComputedStyleM4_test.cj:38`、`SvgValueTypesM4_test.cj:91` 使用 `SvgVectorEffect.NoEffect`。

影响：按 spec 编写的调用方（`SvgVectorEffect.None`、`match` 枚举分支）无法编译；公开 API 与 delta spec 的契约不一致。若为避免与 `Option.None` 冲突而有意采用类，应修改 spec 并明确 `NoEffect`，或提供 `None` 别名/枚举方案。

建议：在归档前统一 spec 与实现；优先让 spec 明确采用 `NoEffect`，或在语言允许范围内提供 `SvgVectorEffect.None`。

#### C5. `feMorphology.radius` 无上限，可造成无界计算（DoS）

证据：

- `f_svg/src/SvgFilterPrimitives2.cj:911-912`：
  `pixelRadiusX = round(radiusX * scaleX)`、`pixelRadiusY = round(radiusY * scaleY)`，没有上限检查。
- `f_svg/src/SvgFilterPrimitives2.cj:925-950`：对每个像素按 `offsetY ∈ [-pixelRadiusY, pixelRadiusY]`、`offsetX ∈ [-pixelRadiusX, pixelRadiusX]` 双层循环。
- 例如 100×100 缓冲、`radius="1000000000"` 时循环规模约 `100*100*4*(2e9)^2`，渲染会长时间不返回。
- `svg-security` 的 M4 上限表只列了卷积核、湍流倍频、TTF、`feImage` 预算，没有形态学半径；`SvgLimitsM4_test` 也没有对应负向用例。

影响：对不可信 SVG 文档构成算法复杂度型拒绝服务；这是 M4 新增原语引入的安全缺口，而不是既有行为。

建议：为 `feMorphology` 半径设置与 `maxPixels`/核尺寸相称的上限（例如按滤镜区域宽高或固定像素半径上限），超限抛 `SvgException(kind: Limit)`，并补充负向用例；同时在 `svg-security` 的 M4 上限表登记。

### WARNING

#### W1. 任务勾选与验收结论存在过度声明

除 C1 的 17.5 外，以下勾选项没有对应断言或实现：

- `5.3`：`edgeMode="wrap"` 只被 round-trip 解析，未测行为。
- `6.4`：`feImage` 的 `slice` 与 base64 超限未测；现有 `feImage` 只测 meet/none。
- `8.2` / `12.3`：只比较新实现的两个入口，未与 M3 字节比较。
- `10.3`：渐变装饰线未按字形起点取样（见 W5）。
- `16.3`：warning 审计只检查 `clip` / `vector-effect` / `feImage`，未覆盖每条 M4 warning 都含元素路径或属性名。
- `18.6`：未执行 `openspec validate --strict`，只人工核对。
- `18.8`：未合并、未删除分支。

#### W2. 9 个 Scenario 缺独立断言

见 2.2。建议至少补齐：锐化核、零尺寸输入、`feDisplacementMap scale="nan"`、多语言优先级、`<image>`+`feImage` 预算共享、字体不读文件、`switch` 的 `maxElements`、loca 中间截断、无显式 `x` 的竖排列推进。

#### W3. TTF 表级边界不完整

`SvgTrueTypeFont` 的读取器只校验整个 `bytes` 数组边界；`head` / `hhea` / `maxp` / `hmtx` / `cmap` / `glyf` 的读取没有先校验“偏移 + 所需长度 ≤ 表 offset + 表 length”。恶意字体可以让 `head.length = 0` 但 offset 指向其他表，解析出错误值而不是 `Syntax`；`cmap` 的子表长度也没有完整校验。建议引入 `SvgTtfTableReader`，所有读取基于表边界。

#### W4. `text-decoration` 的祖先传播只认呈现属性

- `f_svg/src/SvgTextRenderer.cj:587-606` 的 `effectiveTextDecoration`：当前元素样式来源不是 Default 时读计算样式；否则沿 `parent` 只读 `element.attr("text-decoration")`。
- 因此 `<g style="text-decoration: underline"><text>...</text></g>` 以及 `<style>g { text-decoration: underline }</style>` 不会传播到子文本，违反 svg-css “同时支持呈现属性、`<style>`、内联 `style`”以及 svg-text “祖先声明向下传播”的组合要求。
- 同类问题：`collectSvgTextChars` 在 `SvgTextRenderer.cj:678-696` 对 `tspan` 的 `dominant-baseline` / `alignment-baseline` / `baseline-shift` / `text-decoration` 只读原始属性，不读 tspan 的计算样式；`style="baseline-shift:super"` 的 tspan 不生效。
- `alignment-baseline` 在无显式属性时重置为 `Auto`，没有继承父 tspan 的值（与 svg-css 的“可继承”登记不一致）。

建议：在 `SvgTextRenderer` 中接收 `SvgComputedStyleTree`（或为 tspan 预先解析样式），统一用计算样式；祖先传播改为从计算样式树读取最近声明祖先。

#### W5. 装饰线渐变未按字形起点取样

- svg-text 要求“颜色取当前 `fill`，渐变按字形起点取样”。
- `f_svg/src/SvgTextRenderer.cj:473-520` 生成一个合并的装饰线路径；`f_svg/src/SvgRenderer.cj:278-289` 用 `text` 命令的 `bounds`（整段文本包围盒）对该路径执行 `drawFill`。
- 结果是渐变按整段文本包围盒采样，而不是每个字形起点采样；`decorationColor` 只测了纯色。
- 纯色、组合、厚度、旋转测试均通过，因此这是渐变场景的语义缺口。

#### W6. `textPath` 的 `stretch` / `exact` 语义不完整

- `f_svg/src/SvgTextPathLayout.cj:90-96` 的 `method="stretch"` 只缩放 `advance`，没有像 `textLength` 的 `spacingAndGlyphs` 那样缩放字形路径宽度；spec 要求“规则与 textLength 的 spacingAndGlyphs 一致”。
- `f_svg/src/SvgTextPathLayout.cj:122-124` 的 `spacing="exact"` 只消费 `dx`，完全忽略 `letter-spacing`；spec 要求 `dx` / `letter-spacing` 的精确定位。
- `exactSpacing` 测试只覆盖 `dx`，未覆盖 `letter-spacing` 与“未提供时等同 auto”。

#### W7. 旋转视口/标记裁剪使用轴对齐 AABB

- 嵌套 `svg` / `symbol` 的 `overflow` 裁剪在 `f_svg/src/SvgRenderTree.cj:493-508` 和 `584-589` 通过 `transformedRectBounds` 计算设备空间 AABB。
- marker 裁剪在 `f_svg/src/SvgRenderTree.cj:758-773` 同样使用 `transformedRectBounds`。
- `clipRect` 只能表达轴对齐矩形；当祖先或 marker 自身旋转时，真实视口是旋转矩形，AABB 会放行旋转矩形之外、AABB 之内的内容，违反“按视口矩形裁剪”。
- `marker` 还在 `:769` 做了 `.inflate(1.0)`，比 `markerWidth × markerHeight` 多 1 个设备像素，和 spec 的精确视口有偏差（测试只检查 4×4 内/外，未覆盖边界）。
- 影响是“裁剪不够严格”，不会误裁已有内容；但与 svg-paint-and-clip 的“在内容坐标系完成裁剪”不完全一致。

#### W8. `anchors()` 漏掉无 href 的 `a`

- svg-document-model 要求“按文档顺序返回所有 `a` 元素”。
- `f_svg/src/SvgDocument.cj:137-152` 只有在 `readSvgHref` 返回非空 href 时才加入 `SvgAnchorInfo`；`<a><rect/></a>` 不会出现在 `anchors()` 中。
- `SvgAnchorInfo.href` 是 `?String`，本可以表达无 href 的情况。建议要么把无 href 的 `a` 也返回（href=None），要么把 spec 改成“返回所有有 href 的 `a`”。

#### W9. `switch` 的默认兼容性与空条件边界

- M3 的 `SvgContainerKind.Switch` 若按普通容器遍历，会绘制全部子元素；M4 只选第一个满足条件的子元素。对于只含无条件 `<switch>`、没有声明任何 M4 属性的既有文档，输出会变化，而 README/提案的兼容性例外只列了“marker 溢出”，没有列 `switch`。这是文档层面的兼容性声明不完整（若 M3 确实渲染全部子元素）。
- `f_svg/src/SvgSwitch.cj:78-88`：`requiredFeatures=""` 或纯空白时 `features.size == 0` 直接返回 `false`；SVG 语义中空条件属性应视为“无要求”，应满足。建议补测并修正。
- `SvgSwitch` 的条件求值本身只读文档，未发现修改状态。

#### W10. 滤镜零尺寸/非整数参数/测试覆盖

- 零尺寸：`SvgFilterRenderer.apply` 在 `f_svg/src/SvgFilterRenderer.cj:111-113` 对 0×0 区域直接返回空位图，不追加 warning；各原语收到 0×0 缓冲时也不会 warning。与 svg-filter “零尺寸输入 SHALL 输出透明并记 warning”不符。
- `f_svg/src/SvgFilterPrimitives2.cj:969-975`：`order` 用 `round` 转整数，`order="2.5"` 会被当成 3，而 spec 要求“不是正整数时 warning 并按直通处理”。建议先校验 `value == floor(value)` 且 `1..9`，再做 Limit 判断。
- `feDisplacementMap` 的非有限 `scale` 在实现中已处理（`SvgFilterPrimitives2.cj:1239-1243`），但缺测试。
- `feImage` 的 `preserveAspectRatio="slice"` 与 base64 长度超限缺测试。
- `feConvolveMatrix` 的 `edgeMode="wrap"` 实现存在（`SvgFilterPrimitives2.cj:1083-1085`），但缺行为测试。

#### W11. 非缩放描边的奇异 CTM 分支缺测试

- `f_svg/src/SvgVectorEffect.cj:59-69` 在行列式接近 0 时返回 0；`f_svg/src/SvgRenderer.cj:379-386` 回退为 none 并追加 warning。
- 现有 `SvgVectorEffectM4_test` 只测 `strokeScale` 返回 0，没有测“渲染时该元素按 none 描边且 warning 出现”。建议补一条 `scale(0)` 或退化矩阵用例。

#### W12. `SvgView` 的“可修改并无损写回”只做了结构往返

- `SvgView` 的 `viewBox` / `preserveAspectRatio` / `viewTarget` propeller 已实现（`SvgView.cj:29-73`），但 `SvgDocumentApiM4_test.model` 只解析并 `toString()`，没有“修改字段再写回”的断言。
- `preserveAspectRatio` setter 即使设为默认值也会写入属性（`:61-63`），对“无损”而言是新增属性而非删除属性；若测试期望属性集合不变，需要明确。

### SUGGESTION

1. **S1** 把 M3 字节级比较接入 CI，并作为归档前的硬门禁；这是 C1 的最终修复。
2. **S2** 为 `feMorphology` 半径增加上限（C5），并纳入 `svg-security` 与 `SvgLimitsM4_test`。
3. **S3** 补齐 2.2 的 9 个 Scenario 测试；优先零尺寸、`scale="nan"`、预算共享、字体不读文件。
4. **S4** `SvgClipProperty.parse` 接受 `none`，与 CSS `clip` 的 `auto | rect()` 及 delta css 的初始值 `none` 存在口径差异；建议在 spec 明确“`none` 是 `auto` 别名”，避免两套语义。
5. **S5** `SvgPathMeasure.sample` 对只有 `M` 的空长度路径返回 `(0,0)` 而非路径起点；建议明确该边界，或在 `pointAtLength` 中返回唯一 MoveTo 点。
6. **S6** `SvgTrueTypeTables` 的测试类放在 `SvgTrueTypeM4_test.cj`，与任务 13.1 的 `SvgTrueTypeTables_test.cj` 命名不一致；建议统一文件/类名，便于审查。
7. **S7** 为 `clip` 增加文本/图像/组之外的专项像素用例（目前 shape/group 覆盖，text/image 只靠代码路径推断）。
8. **S8** 为 `anchors` 增加“渲染结果与删除 `a` 后一致”的用例（任务 14.6 要求，但当前测试只查模型）。
9. **S9** `SvgTextBaseline.shift` 注释写“正值向上”，但 `Sub` 返回正值、`Super` 返回负值（按 y 向下坐标系）；建议修正注释，避免维护者误解。
10. **S10** `SvgViewport.forView` 的 `view` 无 `viewBox` 时返回 identity；建议补一条“无 viewBox + 非法视口仍抛 InvalidValue”的边界测试（当前只测有 viewBox 的非法视口）。

## 4. Coherence（一致性）

### 4.1 delta spec 与实现

| 契约 | 实现 | 判定 |
|---|---|---|
| `SvgVectorEffect` 为 `None` / `NonScalingStroke` 枚举 | 类 + `NoEffect` | C4，不一致 |
| `SvgAnchorInfo` 含 `href` | `href: ?String` | 可接受，但 spec 未说明可空（W8/S10 相关） |
| `SvgTextDecoration` 支持 none/组合 | struct + 静态 none | 一致 |
| `SvgPathData.totalLength` / `pointAtLength` | 公开方法，默认 0.25 | 一致 |
| `SvgGeometry.ctm` / `screenCTM` | 公开方法 | ctm 一致；screenCTM 公式错误（C2） |
| `SvgDocument.views` / `view(id)` / `anchors` | 公开方法 | 一致（anchors 过滤无 href，W8） |
| `SvgRenderOptions.languages` 只影响 switch | 仅 `SvgRenderTree`/`SvgSwitch` 使用 | 一致 |
| `clip` 初始 `none`、`overflow` 初始 `hidden` | 属性表一致 | 一致 |
| `text-decoration` 支持 `<style>`/内联 | 文本自身支持，祖先前向传播不支持 | W4 |
| `feImage` 仅 data:image/png + provider | `SvgImageResource` 一致 | 一致 |
| TTF 结构错误 → Syntax | 存在非 SvgException 路径 | C3 |
| `feMorphology` 无上限 | 无上限 | C5（spec 本身也缺该上限） |

### 4.2 delta spec 与主规格

- 10 个 delta 能力与主规格目录一一对应，未发现重复 Requirement 标题；`svg-text` 的 MODIFIED 条目正确替换了主规格中“`side` 被忽略且不产生告警”的旧要求。
- 主规格 `svg-marker` 没有同步 marker 视口裁剪语义，M4 把该语义放在 `svg-paint-and-clip`；归档同步时需要确认 `svg-marker` 不会被遗漏，至少在 README/主规格中交叉引用。
- `svg-security` 主规格的“规模上限硬失败”没有 M4 的 `feMorphology` 半径上限；C5 修复时应补进 delta 的 M4 上限表，而不是只改实现。

### 4.3 提案/设计/任务与实现

- 提案 `proposal.md:75-76` 与 README 都声称“默认输出与 M3 逐字节一致”，但任务 17.5 的测试没有做到（C1）。
- 设计 D5 说“长度类参数（radius、surfaceScale、scale）用 primitiveScale 换算”；实现做了换算，但没有为 radius 设上限（C5）。
- 设计 D7 说“渐变取字形起点颜色”；实现用整段文本 bounds（W5）。
- 设计 D8 说 textPath 与 `totalLength` 共用弧长；实现共用 `SvgPathMeasure`，测试 `textPathConsistency` 通过。
- 设计 D9 说 `screenCTM = ctm × viewport.matrix × scale(dpr)`；该公式本身与“与渲染器一致”冲突，建议同时修正设计文档和实现（C2）。
- 设计 D10 的 switch 条件集合、display 交互与实现一致；空 `requiredFeatures` 边界未覆盖（W9）。
- 设计 D11 的 `view` / `anchors` 纯查询与实现一致；`anchors` 无 href 过滤是 spec 解释问题（W8）。

### 4.4 文档与任务

- `README.md` / `README_en.md` 的 M4 能力表、限制说明已更新；`f_svg.cj` 包注释已更新；`doc/perf-baseline.md` 有 M4 参考基准。
- `tasks.md` 的 18 组任务除 18.8 外全部 `[x]`，但 2.3 列出的若干项属于“提前勾选”，建议在归档前把未真正验证的项改成 `[ ]` 或补充证据。
- `openspec validate --strict` 未执行（本机无 CLI）；人工检查 43/43 Requirement 均有 Scenario，格式未见明显问题，但不能替代 CLI 校验。

## 5. 校验限制

1. **git 元数据不可用**：worktree 的 `.git` 文件指向 `/storage/Users/.../.git/worktrees/f_svg`，该路径在当前环境不存在（实际路径为 `/mnt/linux_share/storage/...`）。因此无法执行 `git status` / `git log` / `git diff`，也无法核验 1.1 的“工作区干净”、A/B/C 的真实提交顺序与 18.8 的分支状态。
2. **openspec CLI 不可用**：`which openspec` 失败，`openspec validate add-f-svg-m4 --strict` 未执行；本报告只能做人工结构核对。
3. **测试通过不等于验收通过**：656 条用例全绿，但 C1/C2/C3 都是“当前测试没覆盖到”的问题；测试通过不能反证这三项。
4. 本报告只做校验，不修改源码、不归档、不合并分支。

## 6. 建议的归档前处理顺序

1. 修 C2（screenCTM 顺序）并补带 transform + meet 的测试。
2. 修 C3（endPts 单调性/局部边界/tag UTF-8），补恶意字体用例。
3. 统一 C4（`SvgVectorEffect` 的 spec 与实现）。
4. 修 C5（morphology 半径上限）并补负向用例。
5. 补 C1 的 M3 字节级测试；在此之前把 17.5 和 README 的“逐字节一致”改成“未验证”或“±1 容差”。
6. 处理 W1/W2 的任务勾选与 9 个 Scenario 测试，再执行 `openspec validate --strict`。
7. 以上完成后再考虑 18.8 的合并/删分支；本次按要求不归档。

CRITICAL=5

## 7. 修复结果

修复执行时间：2026-11-06；分支：`feature/f_svg`。以下每项均先补失败用例并确认失败原因，再实现并以 `cjpm test` 全绿提交。

| 编号 | 状态 | 修复内容与证据 |
|---|---|---|
| C1 | 已修复 | 5 个 M3 场景纳入 `compareSceneExact`（容差 0），新增单字节篡改检测用例；`clipRect` 完整覆盖内容时跳过离屏层，消除组合成二次量化，`m3-marker` 恢复逐字节一致 |
| C2 | 已修复 | `screenCTM` 改为 `scale(dpr) × viewport.matrix × ctm(element)`；新增 `g transform` + viewBox meet + DPR 2 用例，并同步设计文档 |
| C3 | 已修复 | 新增 `SvgTtfTableReader` 表级边界；`endPtsOfContours` 严格递增、`appendTtfContour` 端点校验；表 tag 按 ASCII 校验；`head` / `hhea` / `maxp` / `cmap` 子表长度校验；补非单调 endPts、非法 tag、声明长度为 0、cmap 子表越界、loca 中段截断用例 |
| C4 | 已修复 | 采用 `NoEffect` 方案；delta spec（两处副本）、`f_svg-M4设计.md`、README 中英统一为 `NoEffect` / `NonScalingStroke`，字符串 `none` / `non-scaling-stroke` 不变 |
| C5 | 已修复 | `feMorphology` 像素半径上限 `min(4096, max(区域宽, 区域高))`，超限抛 `Limit` 且检查在循环前；补 100×100 / 4×4 负向用例并登记 `svg-security` 上限表 |
| W1 | 已落地 | 复核 `tasks.md`：5.3、6.4、8.2、10.3、12.3、16.3、17.5 补齐证据或修正表述；18.6 因本机无 `openspec` CLI 保持未勾选并注明 |
| W2 | 已落地 | 补锐化核、零尺寸 warning、`feDisplacementMap scale="nan"`、多语言优先级、`<image>`+`feImage` 共享预算、字体不读文件、`switch` 受 `maxElements` 约束、loca 中段截断、无显式 `x` 竖排共 9 项断言 |
| W3 | 已落地 | 与 C3 合并：所有表读取以 `table.offset/length` 为界，越界抛 `Syntax` |
| W4 | 已落地 | `SvgDisplayList` 携带计算样式树；`tspan` 的基线 / 对齐 / 位移 / 装饰与祖先 `text-decoration` 统一从计算样式读取，支持 `<style>` 与内联 `style` |
| W5 | 已落地 | 装饰线按字形切分为 `SvgDecorationRun`，渐变以字形起点包围盒取样；纯色仍合并绘制以避免接缝二次混色 |
| W6 | 已落地 | `method="stretch"` 同步缩放字形宽度；`spacing="exact"` 计入 `letter-spacing`，缺省等同 `auto`；补字形宽度与 letter-spacing 用例 |
| W7 | 已落地 | 旋转嵌套 `svg` / `symbol` / marker 增加设备空间四边形覆盖率裁剪；marker 内容已完全落在视口内时跳过裁剪，去掉 `inflate(1.0)`；补旋转 45° 与 AABB 角部用例 |
| W8 | 已落地 | `anchors()` 返回所有 `a`，无 href 或外部 href 被移除时 `href=None`；同步 delta spec |
| W9 | 已落地 | `requiredFeatures` / `systemLanguage` 为空或纯空白视为无要求；README 与 proposal 补充 `switch` 条件性输出差异 |
| W10 | 已落地 | 零尺寸滤镜区域追加 warning；`feConvolveMatrix.order` 必须为正整数，非整数按直通 + warning；补 `edgeMode="wrap"`、`feImage slice`、base64 超限用例 |
| W11 | 已落地 | 补奇异 CTM 下 `non-scaling-stroke` 按 `none` 回退且追加 warning 的渲染用例 |
| W12 | 已落地 | 补 `SvgView` 修改 `viewBox` / `preserveAspectRatio` / `viewTarget` 后写回再解析断言，并说明 setter 写默认值会显式写出属性 |
| S4 | 已处理 | spec 明确 `clip: none` 是 `auto` 别名 |
| S5 | 已处理 | `pointAtLength` 对仅含 `MoveTo` 的零长度路径返回该起点 |
| S6 | 已处理 | TTF 表读取器用例拆分为 `SvgTrueTypeTables_test.cj` / `SvgTrueTypeTables_test` |
| S7 | 已处理 | 补 `clip` 作用于文本与图像的像素用例 |
| S8 | 已处理 | 补“`a` 容器渲染与去掉 `a` 逐字节一致”用例 |
| S9 | 已处理 | 修正 `SvgTextBaseline.shift` 注释的 y 轴方向 |
| S10 | 已处理 | 补 `view` 无 `viewBox` + 非法视口仍抛 `InvalidValue` 用例 |
| S1 / 18.8 | 按记录不改 | 仓库无 CI 配置，字节基线已进入 `cjpm test`；合并回上游与删除分支未执行 |

复验结果：

- `cjpm test`：`TOTAL: 691 / PASSED: 691 / FAILED: 0`，M1–M3 字节基线全部通过。
- `cjpm build`：成功；`f_svg` 自身 0 warning（依赖 `f_xml` 的既有 warning 不变）。
- 快照更新：`m4-text.rgba`（textPath stretch 现在缩放字形宽度）、`m4-clip.rgba`（marker 改为精确视口，不再放宽 1 像素）；M1–M3 快照未改动。
- 结论：本轮计划内 `CRITICAL=0`、`WARNING=0`；W1–W12 与第二轮新增项均已落地，剩余已知限制见第 8 节。

## 8. 第二轮修复结果（2026-11-06）

执行依据：`verification-2.md` 与 `fix-plan-2.md`。分支 `feature/f_svg`；每项先确认失败用例，再实现并跑全量测试后独立提交。

| 编号 | 状态 | 修复内容与证据 |
|---|---|---|
| C5-2 | 已清除 | `feMorphology` 像素半径固定上限 16；新增 `区域像素 × (2rx+1)(2ry+1) ≤ 64 × 1024 × 1024` 采样预算，两道检查均在循环前。`SvgLimitsM4_test` 覆盖 512×512 + radius 512、512×512 + radius 16、64×64 + radius 4；`svg-security` delta 与 M4 设计上限表同步 |
| NEW-C1 | 已清除 | `markerContentFits` 先用 viewBox / preserveAspectRatio 内容矩阵把子元素包围盒变换到 marker 视口坐标，再与视口比较；描边、滤镜、裁剪、蒙版改读计算样式，无法确定时回退为需要裁剪。marker 视口 `ref` 平移改为 `C(refX, refY)`。新增 viewBox 放大、viewBox + 非零 ref、样式化描边、样式化滤镜、快路径五个用例 |
| W1-2 | 已落地 | `tasks.md` 18.6 删除“保留未勾选”的矛盾说明，统一为“已由主流程执行核对并通过” |
| W2-2 | 已落地 | `loca` 用例改为文件完整、仅缩短表声明长度，目录解析通过后在表级长度检查抛 `Syntax`；字体用例增加内存 `parse` 成功与不存在路径 `load` 抛 `Syntax` 的边界；新增单次渲染中 `<image>` 与 `feImage` 共用预算用例；`emptyConditions` 补 `requiredExtensions=""` |
| W7-2 | 已落地 | 四边形覆盖率只在设备 AABB（外扩 1 像素）内光栅化，同一元素的多个 quad 共用交集缓冲；新增嵌套旋转 quad 像素用例与 100 个旋转裁剪元素的基准，`perf-baseline.md` 记录约 948 ms |
| W9-2 | 已落地 | `README.md` / `README_en.md` 的 M4 兼容性说明补充 `switch` 只选择第一个满足条件子元素的差异 |
| NEW-W1 | 已落地 | 文本 `renderBounds` 并入装饰线包围盒，`clipRectCoversCommand` 不再漏裁下划线；新增 0..21 紧视口下划线用例 |
| NEW-W2 | 已落地 | `SvgGeometry.bounds` / `renderBounds` 增加可选 `styles` 参数，渲染树传入计算样式树；新增样式化 `tspan` 基线包围盒用例 |
| NEW-W3 | 已落地 | 统一为“渐变按字形包围盒取样（每个字形独立 `objectBoundingBox`）”，同步 `svg-text` delta、M4 设计、任务与代码注释；现有逐字渐变断言继续覆盖 |
| NEW-W4 | 已落地 | delta 统计更新为 43 Requirement / 145 Scenario（`svg-security` 12 条）；结论改为“本轮计划内 CRITICAL=0、WARNING=0，剩余已知限制见第 8 节” |

实跑结果：

- `cjpm test`：`TOTAL: 704 / PASSED: 704 / FAILED: 0`。
- `cjpm build`：成功；依赖模块 `f_base` / `f_xml` 的既有 warning 不变，`f_svg/src` 0 warning。
- M1–M3 逐字节基线：13 个快照全部通过 `compareSceneExact`；`git diff a39db449..HEAD` 对 13 个 `.rgba` 为空，未被本轮修复重新生成。
- 本轮未修改 M1–M3 公开 API 语义；`SvgGeometry.bounds` / `renderBounds` 仅追加可选 `styles` 参数（默认 `None`）。

已知限制（按 `fix-plan-2.md` 第 3 节记录不改）：

- CI 接入（S1）仍未执行，逐字节基线目前只由 `cjpm test` 承载。
- W7 的裁剪精度之外的性能项未继续优化；四边形蒙版已按设备 AABB 限界并共用缓冲，但每个指令仍会做一次交集外的 alpha 清零。
- 与上表重复的 SUGGESTION 不再单独处理。
