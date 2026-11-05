# add-f-svg-m2 归档后实现校验报告

## 0. 校验结论

- 本次为只读校验：未修改 `f_svg/src`、`f_svg/testdata`、`openspec/specs` 或归档目录；仅执行了 `cjpm test` / `cjpm build`，会更新 `target` 缓存。
- `cjpm test`：**330 / 330 通过，0 failed，0 skipped**。
- `cjpm build`：`f_svg` 自身 errlog 为 **0 字节**；构建输出中的 warning 均来自 `f_base`、`charset4cj` 等依赖。
- `tasks.md`：**157 / 157 全部勾选**。
- 但“全部勾选”不等于“全部真实完成”。至少 `6.4`、`11.3`、`14.11`、`14.13`、`16.7` 存在不成立或部分成立；其中 `16.7` 声称“逐条确认场景有用例”，与实际情况不符。
- 分级结果：**CRITICAL = 9，WARNING = 16，SUGGESTION = 6**。

整体判断：**实现主体完整、回归通过，但归档主规格中的多个 SHALL/Scenario 未落地，且部分测试把与规格相反的行为固化，不能认定 157 个任务全部真实完成。**

---

## 1. CRITICAL（9）

### C1. 动画非法条目未被忽略，反而进入 `animations()` 并可能污染采样文档

**规格**：`svg-animation/spec.md:36` 明确要求：缺少 `attributeName` 的 `animate` / `set`、缺少 `type` 的 `animateTransform`、既无 `path` 又无可解析 `mpath` 的 `animateMotion` **SHALL 被忽略并记 warning**；`spec.md:12` 还要求被忽略动画 **SHALL NOT** 出现在 `animations()`。

**实现**：
- `f_svg/src/SvgTimeline.cj:300-320`：只追加 warning，仍返回 `SvgAnimationSpec`。
- `f_svg/src/SvgTimeline.cj:265-273`：`collectAnimationSpecs` 对四类动画标签一律 `out.add(...)`，没有过滤。
- 缺少 `type` 的 `animateTransform` 会默认按 `translate` 处理；缺少 `attributeName` 的动画在采样时可能执行 `target.setAttr("", value)`（`SvgTimeline.cj:222` 附近），向快照写入空属性名。

**测试**：`f_svg/src/SvgAnimation_test.cj:64-76` 只断言 `warnings.size >= 3`，**没有断言 `animations().size == 0` 或 `kind` 列表为空**，因此未发现该问题。

**影响**：非法动画会出现在对外 API `animations()` 中，`duration()` 也可能被其 `end` 时间污染；缺失 `type` 的动画会实际产生 transform；缺失 `attributeName` 可能破坏快照序列化。

---

### C2. 递归/循环深度上限语义整体与安全规格相反

**规格**：`svg-security/spec.md:156-182`：
- 循环引用：深度 64 终止并记 warning，渲染继续；
- **非循环引用但深度超过 64：抛 `SvgException(kind: Limit)`**；
- `use`、嵌套 `<svg>`、渐变 `href`、`clipPath` / `mask`、`mpath` 均适用。

**实现**：
- `f_svg/src/SvgRenderTree.cj:398-401`：`use` 深度 `>= 64` 只记 warning 并停止；
- `f_svg/src/SvgRenderTree.cj:360-361`：嵌套 `<svg>` 深度 `> 64` 只记 warning；
- `f_svg/src/SvgGradient.cj:441-443`：渐变 `href` 深度 `>= 64` 只记 warning；
- `f_svg/src/SvgTimeline.cj:437`：`mpath` 深度 `> 64` 直接抛 `Limit`，对“循环”也不区分，和规格要求的“循环 warning”相反；
- `clipPath` / `mask` 没有递归解析与深度/循环检测（`SvgClipMask.cj:76-102` 只渲染直接子内容）。

**测试**：
- `f_svg/src/SvgGradientSampler_test.cj:292` 对 70 层**非循环**渐变链只断言 `warnings.size >= 1`，把“应抛 Limit”固化成“仅 warning”；
- 没有 65 层非循环 `<use>` 抛 `Limit` 的用例；
- 没有 `mpath` 循环引用应 warning 的用例。

**影响**：非循环合法深链被静默截断，安全规格的硬失败边界失效；`mpath` 循环则错误地变成 `Limit`，错误类型与恢复策略都不符合契约。

---

### C3. `animateMotion` 的 `keyPoints` 完全未实现

**规格**：`svg-animation/spec.md:32` 要求 `animateMotion` 支持 `path` / `mpath` / `rotate` / `keyPoints`；`spec.md:210` 要求 `keyPoints` 与 `keyTimes` 配合控制沿路径进度分布，缺省按路径长度匀速。

**实现**：`src/` 中 **没有任何 `keyPoints` 引用**（`grep` 无结果）。`SvgTimeline.cj` 的运动采样只按 `progress` 乘以总路径长度。

**测试**：`f_svg/src/SvgAnimation_test.cj:207-235` 只覆盖直线运动、`rotate=auto` 与固定角度，没有 `keyPoints`。

**任务**：`tasks.md` 的 `14.11` 明确要求“先写 animateMotion 用例：… keyPoints”，但被勾选为完成。

---

### C4. `calcMode="paced"` 未实现，实际按 linear 处理

**规格**：`svg-animation/spec.md:105`、`spec.md:133-136`：`calcMode` SHALL 支持 `linear` / `discrete` / `spline` / `paced`；`paced` 按数值距离分配时间，而不是按时间片均分。

**实现**：
- `f_svg/src/SvgInterpolator.cj:60-65`：`numeric` 只对 `Discrete` 特判，`Paced` 与 `Linear` 走同一分支；
- `f_svg/src/SvgTimeline.cj:589` 把 `Paced` 传给 `numeric`，但没有按数值距离重排关键帧；
- 没有 `paced` 的端到端测试。

**影响**：`paced` 只是枚举值存在，行为未实现。规范给出的 `values="0;10;0"` 中点场景可能“碰巧”得到 10，因此现有测试无法暴露该缺陷。

---

### C5. `CssSelectorPart` 缺少公开字段 `combinator`

**规格**：`svg-css/spec.md:46` 要求 `CssSelectorPart` 暴露 `typeName`、`id`、`classes` 与 **`combinator: ?CssCombinator`**，其中 `combinator` 表示该部分与左侧部分的组合关系，最左部分为 `None`。

**实现**：`f_svg/src/CssSelector.cj:43-52` 只有 `typeName` / `id` / `classes`，没有 `combinator`；组合符单独存放在 `CssSelector.combinators`（`CssSelector.cj:124-128`），不符合主规格的公开 API 形状。

**说明**：旧版 `f_svg/doc/spec/add-f-svg-m2/specs/svg-css/spec.md` 没有这句话，主规格是在归档时新增的契约；这属于**归档规格与实现/旧规格副本的漂移**。但既然主规格是当前验收依据，应按 CRITICAL 处理。

---

### C6. `SvgBounds.inflate` 负值未钳制到 0，测试断言与规格相反

**规格**：`svg-geometry/spec.md:14`：`inflate(amount)` 负值 SHALL 收缩并把宽高钳制到 `0`，**不产生负宽高**；空盒扩展后仍为空。

**实现**：`f_svg/src/SvgBounds.cj:110-115` 直接计算 `width + 2*amount` / `height + 2*amount`，没有 `max(0, ...)`。

**测试**：`f_svg/src/SvgBounds_test.cj:44` 断言 `first.inflate(-20.0).isEmpty()`，即把规格禁止的“负尺寸/空盒”结果固化为期望值。正确结果应是宽高为 0 的非空退化盒。

**影响**：调用方用负 `inflate` 做裁剪/收缩时，会提前得到空盒，进而影响 `union` / `intersect` / 渲染脏矩形。

---

### C7. Hershey 空格 `glyphPath` 返回 `None`，测试断言与规格相反

**规格**：`svg-text/spec.md:44`、`spec.md:51-54`：空格 SHALL 有前进宽度，`glyphPath(32, ...)` SHALL 返回**命令列表为空的 `SvgPathData`（非 `None`）**；不可打印字符才返回 `None`。

**实现**：`f_svg/src/SvgHersheyFont.cj:35-67` 在 `HERSHEY_GLYPHS` 无 32 或命令为空时统一返回 `None`；`advance(32)` 有宽度，但路径为 `None`。

**测试**：`f_svg/src/SvgFont_test.cj:51` 明确断言 `glyphPath(32, 10.0).isNone()`，与主规格场景相反。

**影响**：渲染器在 `SvgTextRenderer.cj:270-277` 对 32 做了特判，所以像素输出暂时正常；但公开 `SvgFont` 契约错误，外部调用方无法区分“空格空字形”和“缺字”。

---

### C8. 线性渐变 `p0 == p1` 取首 stop，规格要求取末 stop；测试断言首 stop

**规格**：`svg-paint-and-clip/spec.md:12`：`p0 == p1` 时 SHALL 取**最后一个 stop** 的颜色，不得崩溃。

**实现**：`f_svg/src/SvgGradient.cj:287-289` 在分母接近 0 时返回 `t = 0.0`，即取第一个 stop。

**测试**：`f_svg/src/SvgGradientSampler_test.cj:70-73` 断言退化渐变采样结果为红色（第一个 stop），与主规格的“最后一个 stop（蓝色）”相反。

**说明**：旧版 `doc/spec` 写的是“最后一个（或第一个，二者一致的退化处理不得崩溃）”，主规格删除了“或第一个”的容错；实现和测试仍停留在旧语义。

---

### C9. 文本 `x` / `y` 列表短于字符数时未复用最后值

**规格**：`svg-text/spec.md:70`：`x` / `y` 列表逐字符定位，**列表短于字符数时复用最后一个值**。

**实现**：`f_svg/src/SvgTextRenderer.cj:353-368`：
- `x`：仅 `index < values.size` 时设置 `xOverride`，之后的字符继续按 advance 排列，没有复用最后值；
- `y`：`else` 分支使用 `values[0]`，复用的是**第一个值**，不是最后一个值。

**测试**：`f_svg/src/SvgTextRenderer_test.cj:68-75` 只使用与字符数等长的列表，没有覆盖短列表。

**影响**：`x="10"` 这类单值列表应为所有字符提供同一起点，当前只有第一个字符生效；`y` 的语义同样错误。

---

## 2. WARNING（16）

### W1. 径向渐变 `r <= 0` 仍会绘制末端颜色

- 规格 `svg-paint-and-clip/spec.md:42-44`：`r <= 0` 时 SHALL **不绘制**并 warning。
- `f_svg/src/SvgGradient.cj:314-318` 返回 `t = 1.0`，采样结果是最后一个 stop 的颜色，仍会填充。
- `SvgGradientSampler_test.cj:128-137` 只断言 warning，没有断言“不绘制”。
- `SvgGradient.cj:316` 的 warning 文案甚至写“已按末端颜色处理”，与规格相反。

### W2. CSS 继承属性非法值回退到初始值，而不是父元素计算值

- 规格 `svg-css/spec.md:187`：已知属性非法值时，可继承属性 SHALL 回退到**父元素计算值**，不可继承属性回退初始值。
- `f_svg/src/SvgStyleResolver.cj:204-212` 在 `normalizeValue` 失败后统一 `normalizeValue(name, spec.initial, parent)`，没有按 `spec.inherited` 选择父值。
- 现有 `invalidValuesDegrade` 只测无父元素场景，未覆盖“父 fill=red，子 fill=bogus”。

### W3. `stop-color` / `stop-opacity` 被错误标为可继承；`clip-path` / `mask` 不在属性表

- 规格 `svg-css/spec.md:119-121`：`stop-color`、`stop-opacity` 属于**不可继承**属性；不可继承属性至少还应包含 `clip-path`、`mask`。
- `f_svg/src/SvgComputedStyle.cj:99-100` 把两者标为 `inherited = true`；
- 属性表（`SvgComputedStyle.cj:82-101`）完全没有 `clip-path` / `mask`，因此 CSS `style="clip-path:..."` / `mask` 不会进入计算样式，渲染器仍只读原始属性。

### W4. 非 `font-size` 长度属性的 `em` / `ex` 未按当前字号解析

- 规格 `svg-css/spec.md:123`：其他长度属性中的 `em` / `ex` SHALL 使用当前元素计算字号。
- `f_svg/src/SvgStyleResolver.cj:368-379` 对 `stroke-width` / `letter-spacing` / `word-spacing` / `stroke-dashoffset` 只做 `SvgLength.tryParse` 并原样 `toString()`，没有把 `2em` 解析成 `32px`。
- 这会让 `strokeWidth().value` 读到 2 而不是 32，影响描边与包围盒。

### W5. `SvgViewport.from` 在两个 fallback 都 ≤ 0 时未抛 `InvalidValue`

- 规格 `svg-geometry/spec.md:168`：`fallbackWidth` / `fallbackHeight` 两者都 ≤ 0 时 SHALL 抛 `SvgException(kind: InvalidValue)`。
- `f_svg/src/SvgViewport.cj:78-84` 在 fallback 非法时静默替换为 300 / 150。
- 现有 `sizeResolution` 只测缺省和非法根尺寸，没有测双 fallback ≤ 0。

### W6. 最终像素尺寸使用 `round` 而不是 `ceil`

- 规格 `svg-rasterization/spec.md:65`：最终像素尺寸 SHALL 为 `ceil(width × devicePixelRatio)` × `ceil(height × devicePixelRatio)`。
- `f_svg/src/SvgRenderTree.cj:168-169` 与 `:208-209` 使用 `Int64(round(...))`。
- 整数 DPR 场景测试通过，但 1.1 / 1.3 等非整数 DPR 下会与规格差 1 像素。

### W7. `keyTimes` / `keySplines` 数量不符时没有 warning

- 规格 `svg-animation/spec.md:107-109`：数量不一致时回退并记 warning。
- `f_svg/src/SvgTimeline.cj:612-625` 的 `effectiveKeyTimes` 静默回退均匀分布；
- `SvgTimeline.cj:632-634` 对 `keySplines` 数量不足也只是跳过 spline，没有 warning。
- 没有对应测试用例。

### W8. `clipPath` / `mask` 的递归引用与循环检测未实现

- 规格 `svg-security/spec.md:158-160`：`clipPath` / `mask` 引用递归深度不超过 64，循环在 64 终止并 warning，非循环超限抛 `Limit`。
- `f_svg/src/SvgClipMask.cj:76-102` 只遍历直接子元素并光栅化，不递归解析子元素上的 `clip-path` / `mask` 引用，也没有深度/循环控制。
- 结果是嵌套裁剪/蒙版被静默忽略，而不是按规格处理。

### W9. 自定义字体注册表未传入几何包围盒；文本 bbox 不遵循布局

- 设计假设 8（`design.md:342`）要求渲染器把实际字体注册表传给 `SvgGeometry.bounds`，保证文本包围盒与实际字形一致。
- `f_svg/src/SvgRenderTree.cj:268` 调用 `SvgGeometry.bounds(text, style: style)` 时没有传 `options.fonts`；构建器上下文中也没有字体注册表。
- `f_svg/src/SvgGeometry.cj:762-812` 的文本 bbox 只累加 `advance` 和首字符 `x` / `y`，忽略 `tspan` 字号、`dx` / `dy`、`letter-spacing`、`word-spacing`、`textLength`。
- 使用自定义字体或复杂文本时，对象包围盒（渐变 `objectBoundingBox`、裁剪）会与实际渲染不一致。

### W10. CSS 解析 warning 缺少元素路径

- 规格 `svg-css/spec.md:187`：非法值 warning SHALL 包含属性名与**元素路径**。
- `f_svg/src/SvgStyleResolver.cj:210` 只写属性名和值；`:437` 的外部画笔 warning 也只有属性名。
- 现有测试只检查 warning 数量，没有检查可定位信息。

### W11. 性能基准口径与规格不一致，几何基准缺失，且验收锚点未达成

- CSS：规格要求测量 **1000 条简单类选择器 × 1000 元素**的“匹配阶段” ≤ 20 ms；`SvgComputedStyle_test.cj:289-304` 使用 1000 条 `rect { ... }` 类型规则，并把整个 `compute`（含 1001 个元素样式构建）计时。`doc/perf-baseline.md` 记录约 217 ms，**未达 20 ms**。
- 渲染：规格目标为 512×512 / 50 形状 / 4×4 SSAA；`SvgBenchmark_test.cj:41` 用 `samplesPerPixel: 2`，`doc/perf-baseline.md` 也注明“本次用 2×2”。
- 渐变 + 裁剪：`SvgBenchmark_test.cj:54` 用 `samplesPerPixel: 1`，baseline 记录约 3979 ms，**远高于 200 ms**；规格允许记录差距，但提案把它列为验收锚点。
- `svg-geometry/spec.md:192-201` 的“1000 段路径 ≤ 2 ms”基准完全没有实现，`doc/perf-baseline.md` 也没有该记录。

### W12. 部分测试阈值宽于规格，抗锯齿/快速路径的断言不足

- `svg-rasterization/spec.md:183`：贝塞尔扁平化误差 ≤ **0.25** 设备像素；`SvgRasterizer_test.cj:177` 断言 `best <= 0.3`。
- `svg-rasterization/spec.md:179`：解析快速路径与通用 outliner 覆盖率差异 ≤ **1/255**；`SvgStrokeOutliner_test.cj:201` 使用 `tolerance: 3`。
- `svg-rasterization/spec.md:106`：45° 斜边“相邻像素覆盖率和约为 1”没有断言。
- `svg-geometry/spec.md:178-180` 的九种对齐只通过 M1 的解析测试覆盖，M2 视口矩阵只测了 3 种对齐。

### W13. PNG 逐 chunk CRC 场景没有测试；`savePng` 只比较文件大小

- 规格 `svg-png/spec.md:51-54`：每个 chunk 的 CRC-32 应重新计算并与存储值一致。现有 `SvgPngEncoder_test.cj` 只测 zlib 头、Adler-32、解压回读与确定性，没有逐 chunk CRC 校验。
- `SvgPngEncoder_test.cj:179-181` 只断言保存文件存在且大小等于 `toPngBytes()`，没有比较字节内容。

### W14. 渲染/安全的新增场景缺少端到端落点

以下场景没有对应断言：
- `svg-security/spec.md:125-128` 渲染入口 `maxPixels` 超大画布 → 只有 `SvgRenderOptions.validatePixels` / `SvgGroupCompositor.createLayer` 的单测，没有 `SvgRenderer.render` 超限测试。
- `svg-security/spec.md:146-149` `<image href="file:///etc/passwd">` → 只有渲染树 warning，没有“不打开文件/只画占位”的像素断言。
- `svg-render-pipeline/spec.md:26-29` 单元素 `render(element, width, height)` 不继承真实祖先样式 → 测试只验证尺寸，没有父 `fill=red` 的断言。
- `svg-render-pipeline/spec.md:53-56` 未引用 `<defs>` / `<symbol>` / 渐变不产生绘制指令 → 没有直接测试。
- `svg-render-pipeline/spec.md:139-142` 仅改变 `samplesPerPixel` 时各自重复执行仍一致 → 没有测试。
- `svg-security/spec.md:169-172` 65 层非循环 `<use>` 抛 `Limit` → 没有测试（见 C2）。

### W15. 任务真实性：至少 5 个勾选项与实际不符

- `6.4` 要求“大弧/小弧、翻转标志、rx/ry=0、四种轴向极值”；`SvgPathBounds_test.arcBounds` 只覆盖半圆、sweep 方向、整圆、`rx=0` 与一个非等比弧，没有 largeArc=true/false 对比，也没有四种轴向极值。
- `11.3` 要求先写 `SvgHersheyFont_test.cj`；该文件不存在，相关用例放在 `SvgFont_test.cj`，且空格断言与规格相反。
- `14.11` 要求 keyPoints 用例；没有。
- `14.13` 要求 `SvgTimeline_test.cj`；该文件不存在，`duration` / `animations` / 同元素多动画 / by/additive/accumulate 用例被放进 `SvgAnimation_test.cj`。
- `16.7` 声称逐条确认所有 spec 场景有用例；实际存在上述多处无落点场景（见 W14 与覆盖矩阵）。
- 另：测试数量口径不一致：`tasks.md:10` 写 M1 216 条，`proposal.md:46` / `design.md:311` 写 M1 245 条，本次实际总计 330 条（M2 相关约 120 条，M1 约 210 条）。

### W16. 归档结构存在重复规格目录，且与 `f_svg/doc/spec` 副本漂移

- `openspec/changes/archive/2026-11-05-add-f-svg-m2/specs/specs/` 下有一整套重复的 `svg-*` spec，且内容与 `specs/svg-*` 不同（例如 `svg-css` 外层 212 行、内层 188 行；内层缺少 `CssSelectorPart.combinator`、分组特异性等段落）。
- `f_svg/doc/spec/add-f-svg-m2/specs/` 是更早的副本，与 `openspec/specs/` 主规格也有差异（如 `svg-text` 缺少 weight/style 回退与默认注册表独立性）。
- 这会让后续维护者无法判断哪一份是验收依据；建议只保留一份并加索引。

---

## 3. SUGGESTION（6）

1. **清理 `f_svg/src/CssParser.cj`**：该文件只有 `package` 和 `// TODO(M2): CSS 规则解析器。`（`CssParser.cj:1-3`），实际解析在 `CssStyleSheet.cj`。建议删除或补充职责说明，避免被误认为未完成实现。
2. **场景快照测试改为只读**：`SvgScene_test.cj:30-33` 在 `.rgba` 缺失时会自动写入文件并让用例失败。建议缺失时直接失败，禁止测试运行时生成期望文件；同时记录 `.rgba` 的生成方式与固定环境。
3. **建立场景到测试的显式索引**：在 `tasks.md` 或测试注释中为每个 `#### Scenario` 标注对应测试用例，避免再次出现 `16.7` 这类“整体勾选但无法逐条核对”的情况。
4. **补充 CSS 选择器负向测试**：命名空间前缀 `|`、`+` / `~` 兄弟组合符、转义的跳过行为目前只靠 `CssSelector.parse` 抛错间接实现，建议显式测试并确认 warning 文案。
5. **明确默认字体回退语义**：`svg-text/spec.md:14` 要求 `resolve` 回退到“默认字体”，但 `SvgFontRegistry.resolve` 对未知 family 返回 `None`，`SvgFont_test.cj:41` 也断言 `resolve("Missing") == None`。建议要么实现默认 Hershey 回退并补测试，要么把规格改成“仅按 family 列表与 normal/normal 回退”。
6. **统一文档/规格副本**：删除归档中的 `specs/specs`，并让 `f_svg/doc/spec/add-f-svg-m2` 与 `openspec/specs` 保持单向同步，避免归档后出现第三套“事实源”。

---

## 4. 规格场景落点概览

| 规格 | Requirement | Scenario | 主要测试文件 | 结论 |
|---|---:|---:|---|---|
| `svg-css` | 8 | 25 | `CssLexer_test` / `CssSelector_test` / `CssStyleSheet_test` / `SvgComputedStyle_test` | 主体有覆盖；缺分组级联结果、非法继承回退、元素路径 warning、选择器负向测试 |
| `svg-geometry` | 8 | 25 | `SvgBounds_test` / `SvgGeometry_test` / `SvgPathBounds_test` / `SvgViewport_test` | 缺 rotateAround 45°、大/小弧、四轴向极值、1000 段基准；`inflate` 测试与规格相反 |
| `svg-rasterization` | 11 | 24 | `SvgBitmap_test` / `SvgRasterizer_test` / `SvgStrokeOutliner_test` | 像素基元覆盖较好；缺 AA 覆盖率和、设备矩阵组合、renderer 级内存上限；部分容差偏宽 |
| `svg-paint-and-clip` | 6 | 21 | `SvgGradient_test` / `SvgGradientSampler_test` / `SvgClipMask_test` | 主体覆盖；`p0==p1` 相反、`r=0` 未断言不绘制、spread `t=1.25` 未区分、clip/mask 递归未测 |
| `svg-text` | 5 | 19 | `SvgFont_test` / `SvgTextRenderer_test` | 空格契约相反、x/y 短列表未测、连续空格未测、占位方框尺寸未断言 |
| `svg-render-pipeline` | 6 | 18 | `SvgRenderTree_test` / `SvgRenderer_test` | 缺单元素不继承祖先、defs 不绘制、外部图片、不同选项确定性、65 层 use Limit |
| `svg-png` | 6 | 13 | `SvgCrc32_test` / `SvgPngEncoder_test` | 结构/往返/确定性较好；缺逐 chunk CRC、savePng 字节相等 |
| `svg-animation` | 10 | 37 | `SvgAnimation_test` / `SvgInterpolator_test` / `SvgClock_test` | 缺口最大：非法条目、keyPoints、paced、keyTimes/keySplines 警告、set 定时、mpath 正例、auto-reverse、无动画 duration |
| `svg-security`（M2 增量） | 3 | 9 | 散落在 `SvgSecurity_test` / `SvgRenderTree_test` / `SvgGradientSampler_test` / `SvgAnimation_test` | 渲染资源上限、外部图片、非循环深链、clip/mask 递归缺端到端落点 |

> `svg-security` 的 3 个 Requirement / 9 个 Scenario 为 M2 增量；其余为 8 个新增 capability 的主规格。

---

## 5. 最终分级统计

| 级别 | 数量 | 摘要 |
|---|---:|---|
| **CRITICAL** | **9** | 动画非法条目、递归/循环上限、keyPoints、paced、`CssSelectorPart.combinator`、`inflate`、空格 glyphPath、`p0==p1`、文本 x/y 复用 |
| **WARNING** | **16** | 径向 r≤0、非法值回退、属性继承元数据、em/ex、视口 fallback、ceil、keyTimes/keySplines warning、clip/mask 递归、自定义字体 bbox、warning 路径、基准口径、测试阈值、PNG CRC、渲染安全覆盖、任务/归档一致性 |
| **SUGGESTION** | **6** | `CssParser` 清理、快照只读、场景索引、选择器负向测试、默认字体语义、文档副本统一 |

**CRITICAL = 9**，因此本次不能给出“无 CRITICAL、可认定归档完成”的结论。建议按 C1-C9 修复并补齐对应测试后，再重新执行 `cjpm test` 与 `16.7` 的逐场景核对。

---

## 6. 修复结果（2026-11-05，feature/f_svg）

修复依据：`fix-plan.md`。每项均先补失败用例（Red），确认失败原因后写最小实现（Green），并在 `cjpm test` 全绿后独立提交。

| 编号 | 结果 | 主要落点 |
|---|---|---|
| C1 | 已修复 | `SvgTimeline.buildAnimationSpec` 过滤缺少 `attributeName` 的 `animate`/`set`、缺少 `type` 的 `animateTransform`、无 `path`/`mpath` 的 `animateMotion`；`animations()`/`duration()`/`sample()` 不再包含非法条目。用例 `SvgAnimation_test.animationKindsAndWarnings` |
| C2 | 已修复 | `use`/嵌套 `svg`/渐变 `href`/`mpath` 统一为“循环 warning、非循环超深 `Limit`”；`SvgRenderTree_test.useExpansion`、`SvgGradientSampler_test.hrefInheritance`、`SvgAnimation_test.mpathCycleWarns`/`animationLimits` |
| C3 | 已修复 | `animateMotion.keyPoints` 解析、校验与 `keyTimes` 映射；用例 `SvgAnimation_test.animateMotionKeyPoints` |
| C4 | 已修复 | `calcMode=paced` 按数值距离生成时间分布；用例 `SvgAnimation_test.pacedInterpolation` |
| C5 | 已修复 | `CssSelectorPart.combinator` 公开字段，最左为 `None`；用例 `CssSelector_test.combinators` |
| C6 | 已修复 | `SvgBounds.inflate` 负值钳制宽高为 0；用例 `SvgBounds_test.basicAlgebra` |
| C7 | 已修复 | `HersheyFont.glyphPath(32)` 返回空命令 `SvgPathData`；用例 `SvgFont_test.hersheyCoverage` |
| C8 | 已修复 | 线性渐变 `p0 == p1` 取最后一个 stop；用例 `SvgGradientSampler_test.linearEndpoints` |
| C9 | 已修复 | 文本 `x`/`y` 短列表复用最后值；用例 `SvgTextRenderer_test.positioning`，并更新 `text.rgba` 场景快照 |
| W1 | 已修复 | 径向渐变 `r <= 0` 返回透明并不绘制；用例 `SvgGradientSampler_test.radialGradients` |
| W2 | 已修复 | 可继承属性非法值回退父计算值；用例 `SvgComputedStyle_test.invalidValuesDegrade` |
| W3 | 已修复 | `stop-color`/`stop-opacity` 改为不可继承，属性表加入 `clip-path`/`mask`，渲染器改读计算样式；同文件用例与 `SvgRenderer_test.paintAndClipPipeline` |
| W4 | 已修复 | 长度属性 `em`/`ex` 按当前元素字号解析；用例 `SvgComputedStyle_test.invalidValuesDegrade` |
| W5 | 已修复 | 视口双 fallback ≤ 0 抛 `InvalidValue`；用例 `SvgViewport_test.sizeResolution` |
| W6 | 已修复 | 最终像素尺寸改用 `ceil`；用例 `SvgRenderer_test.viewportAndVisibility`（101×101、DPR 1.1 → 112） |
| W7 | 已修复 | `keyTimes`/`keySplines` 数量不符回退并 warning；用例 `SvgAnimation_test.keyTimesAndSplinesWarnings` |
| W8 | 已修复 | `clipPath`/`mask` 子元素引用递归、循环 warning 与非循环超深 `Limit`；用例 `SvgClipMask_test.nestedReferences` |
| W9 | 已修复 | 文本 bbox 委托 `SvgTextRenderer.layout`，渲染树透传 `options.fonts`；用例 `SvgGeometry_test.textBoundsFollowLayout` |
| W10 | 已修复 | 非法值与外部画笔 warning 包含元素路径；用例 `SvgComputedStyle_test.invalidValuesDegrade` |
| W11 | 已记录 | `doc/perf-baseline.md` 统一 CSS 匹配口径、SSAA 档位、几何 bbox 基准与差距，标注参考、非门禁；新增 `SvgBenchmark_test.geometryBenchmark` |
| W12 | 已修复 | 扁平化阈值 0.25、快速路径覆盖率差 1/255、45° 相邻覆盖率之和≈1、补九种对齐；`SvgRasterizer_test`/`SvgStrokeOutliner_test`/`SvgViewport_test` |
| W13 | 已修复 | 逐 chunk CRC 校验与 `savePng` 字节相等；用例 `SvgPngEncoder_test.chunkChecksums`/`fileOutput` |
| W14 | 已修复 | 渲染 `maxPixels`、外部图片占位、单元素不继承祖先、定义容器不绘制、不同 SSAA 确定性；用例 `SvgRenderer_test` 新增三组 |
| W15 | 已修复 | 补大/小弧与四轴向极值用例（同时修正 `arcBounds` 旋转椭圆极值角），并更新 `tasks.md` 的 6.4/11.3/14.11/14.13/16.7 描述与真实测试映射 |

- **W16 / SUGGESTION 1-6**：不在本次必须修复范围，未改动。
- 最终验证：`cjpm test` **341 / 341 通过，0 failed，0 error**；`cjpm build` 成功，`f_svg` 自身 0 warning（构建输出 warning 均来自 `f_xml` 等依赖）。

