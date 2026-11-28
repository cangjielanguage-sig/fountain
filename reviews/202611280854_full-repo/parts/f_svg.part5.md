# f_svg 模块审查报告（模块第 5/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（全部 301 个 `.cj` / 141 个 `.md`；**本部分**只覆盖 `files/f_svg.part5.txt` 的 18 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；所有问题来源记为「存量」）
- **审查重点**：M4 验收档案（4 份 verification）与 M5 变更文档（design / proposal / 两份 fix-plan / 10 份 delta spec）的内部一致性，以及与当前实现的规格漂移
- **报告版本**：v1.1（分报告，供主 Agent 合并；不写 `docs/review/` 模块报告。v1.1 为同日复跑：18 个文件全量重读，前 8 条结论逐条重新取证，另补发现 #9 / #10）

> 本部分文件全部为 `doc/spec/**` 规格与验收文档，没有可执行代码。因此「注入 / 转义 / OOM / 栈溢出 / 死代码 / 重复逻辑」在源码意义上的判定不适用；对应维度改为核对「规格是否声明了这些约束、声明是否与实现一致」。M5 十项能力在 `f_svg/src` 均已有实现（`SvgBlend.cj`、`CssCalc.cj`、`CssSelector2.cj`、`SvgBidi.cj`、`SvgElementApi.cj` 等 11 个新文件全部在位），故规格可被逐条对照。

## 发现

### [一般][存量] `calc()` 的「百分比与绝对长度混用无效」条款与本变更的 fix-plan、实现三方冲突

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md:268`（「混合百分比与绝对长度 SHALL 使表达式无效」）、`:292-295`（Scenario「混合单位无效」期望回退初始值 1）；`f_svg/doc/spec/add-f-svg-m5/design.md:64`；对照 `f_svg/doc/spec/add-f-svg-m5/fix-plan.md:39`、`fix-plan-2.md:31`
- **来源**：存量（快照模式无基线；`git blame` 不可用于历史结论）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `SvgStyleResolver.cj:503-512` 为 `x` / `width` / `cx` / `rx`（宽度）与 `y` / `height` / `cy` / `ry`（高度）、`r`（宽高均值）提供百分比参考值；`CssCalc.cj:232-236` 在有参考值时把 `%` 直接换算为绝对长度，`combineCssCalcAdd` 因此接受 `10% + 5px`。`fix-plan.md:39` 的用例 `x: calc(10% + 5px)`、200 宽视口 → 25，正是要求混用可用。
- **描述**：规格把「混合无效」写成无条件 SHALL，但实现按属性分两类：几何长度属性（9 个）把 `%` 解析为视口比例后允许与 `px` 相加；`stroke-width` / `letter-spacing` / `word-spacing` / `stroke-dashoffset` 没有参考值，仍按「混用无效」处理。照规格实现会拒掉 fix-plan 明确要求支持的 `x` / `width` 写法；照实现写用例又与 Requirement 冲突。Scenario `:292-295` 只在非几何属性上成立，规格却未限定范围。
- **建议**：把 `:268` 改为「同一表达式中的 `%` 与绝对长度 SHALL 先按参考盒换算（几何长度属性用视口宽高，其余属性视为无效）」，并把 `:292-295` 的 Scenario 限定为 `stroke-width`；`design.md:64` 同步。

### [一般][存量] `svg-geometry` 的元素级 API 签名少了 `mediaWidth` / `mediaHeight`，且未说明缺省 300×150 的语义

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md:7`（`getBBox(options!: SvgBBoxOptions = SvgBBoxOptions()): ?SvgBounds`）、`:66-68`（`getCTM(): SvgMatrix`、`getScreenCTM(viewport!: ?SvgViewportTransform = None)`）；实现 `f_svg/src/SvgElement.cj:452-456`、`:477-480`、`:485-491`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」、§14「公开 API 未文档化」
- **证据**：静态确定 —— 三个公开方法都带 `mediaWidth!: ?Float64 = None` 与 `mediaHeight!: ?Float64 = None`；`getBBox` 在两者为 `None` 时固定按 `300 × 150` 计算样式与百分比几何（`SvgElement.cj:457-461`），`SvgElementApi.cj:304-343` 同构。
- **描述**：`@media` 与百分比几何都依赖媒体宽度，而规格正文只给无参签名。调用方按规格文档调用时，样式按 300×150 求值，与 `render(options.width: 800)` 的结果不一致；这正是 `fix-plan-2.md:35`（N10）要求补进文档的签名差异，但只落到 README，delta spec 未更新。
- **建议**：在 `:7` / `:66` 补可选具名参数，并新增一条「未提供媒体宽度时 SHALL 按 300×150 求值，与渲染入口可能不同」的 Scenario。

### [一般][存量] `svg-text` 的字体别名「区分 font-weight / font-style」条款无对应实现

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md:189`、Scenario `:196-199`；实现 `f_svg/src/SvgFont.cj:96-131`；`f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md:41`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」
- **证据**：静态确定 —— `SvgFontRegistry.derived` 只建立 `family → family` 的 `aliases` 映射，`rule.weight` / `rule.style` 在 `SvgFont.cj:96-131` 内没有任何读取；`CssFontFaceRule` 虽保留这两个字段（`CssStyleSheet.cj:103-104`），全仓无消费点。`fix-plan-2.md:41` 已把「`@font-face` 的 weight/style 限定」记为「M6 处理」。
- **描述**：Requirement 写「别名 SHALL 区分 `font-weight` / `font-style`」，但实现里别名与字重、字形无关。Scenario「权重回退」之所以能过，是因为 `resolveDetailed` 在 family 内自带 `normal/normal` 回退（`SvgFont.cj:198-206`），与别名是否区分无关——用例通过不能证明条款成立。按规格验收会得出「已实现」的错误结论。
- **建议**：要么把该句降级为「别名按 family 映射；字重 / 字形回退沿用既有 family 内回退」，并删除 `:196-199` 的 Scenario 或改成「别名目标只有 normal 时按 family 内回退取 normal」；要么在 M6 实现 face 级别名并保留条款。

### [一般][存量] `@font-face` 的 `src` 在同一条 Requirement 里既「决定别名目标」又「被忽略并告警」，实现告警文案与行为相反

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md:212`（目标取自 `src: local(<family>)`）与 `:214`（`src` 被忽略、追加 warning 且不加载文件）；实现 `f_svg/src/CssStyleSheet.cj:348`；`design.md:70`、`:76`；`proposal.md:23`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与命名 / 注释不符」
- **证据**：静态确定 —— 实现把 `src` 原文保留在 `CssFontFaceRule.src`（`CssStyleSheet.cj:107`），`SvgFont.cj:106-117` 用其中的 `local()` 选目标 family；同时解析阶段固定追加「已忽略 @font-face 的 src（不加载字体文件）：<原文>」（`CssStyleSheet.cj:348`）。`design.md:70` 的 `CssFontFaceRule(family, weight, style, srcPresent)` 字段表仍无 `src`，`:76` 与 `proposal.md:23` 仍写「src 忽略并记 warning」。
- **描述**：`src: local(Brand)` 实际生效时，日志仍声称「已忽略」，使用者会误判别名没生效而反复排查；规格同一 Requirement 的两段互相否定，实现只能同时满足字面（告警）与语义（使用）中的一半。这是 `fix-plan-2.md:13-16`（N1）引入 `local()` 后未回收旧文案与旧设计决策的残留。
- **建议**：`src` 有 `local()` 命中时不告警；仅对 `url(...)` 或无法解析的 `src` 记「不加载文件」。规格 `:214` 改为「`url(...)` 与其余声明 SHALL 被忽略并记 warning」，`design.md:70,76` 与 `proposal.md:23` 同步 `src` 字段与 `local()` 语义。

### [轻微][存量] `svg-value-types` 把 `paint-order` 的两条 Scenario 混进「混合模式枚举」Requirement 并原样重复

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-value-types/spec.md:16-24`（`M5 混合模式枚举` 下的「绘制顺序解析」「重复项去重」）与 `:42-50`（`M5 绘制顺序值类型` 下同名同文）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「重复逻辑（字面量复制）」、§13「规格与实现漂移」
- **证据**：静态确定 —— 两处 Scenario 的 WHEN/THEN 文本逐字相同（`paint-order="stroke fill"`、`paint-order="fill stroke fill"`），前者挂在只讨论 `SvgMixBlendMode` 的 Requirement 下，后者才属于 `SvgPaintOrder`。
- **描述**：`paint-order` 行为被记在混合模式 Requirement 名下，Requirement → Scenario 的对应关系错位；同时 Scenario 计数被虚增 2 条，而该计数是本变更「每个 Requirement 至少 1 个可执行 Scenario」验收口径的一部分。
- **建议**：删除 `:16-24` 的两条 Scenario，保留 `:42-50`；若需强调与混合模式无耦合，在混合模式 Requirement 里加一句非 Scenario 说明。

### [轻微][存量] m4 `verification.md` 的 C5 修复行仍记录已被同文件否决的 4096 上限

- **位置**：`f_svg/doc/spec/add-f-svg-m4/verification.md:339`（C5「已修复」，上限 `min(4096, max(区域宽, 区域高))`）与 `:374`（C5-2，固定 16 + 64 Mi 采样预算）；实现 `f_svg/src/SvgFilterPrimitives2.cj:22-24`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 自相矛盾」
- **证据**：静态确定 —— 实现常量为 `SVG_FE_MORPHOLOGY_MAX_RADIUS = 16.0` 与 `SVG_FE_MORPHOLOGY_SAMPLE_BUDGET = 64 * 1024 * 1024`；`verification-2.md:25`、`:89-92` 已判定 4096 版本仍可造成小时级 DoS 并推翻该行结论，但 `verification.md:339` 未加前向指针或修订标记。
- **描述**：同一文件第 7 节把被否决的上限写成「已修复」，第 8 节才给出真正的 16 + 预算。按第 7 节抽查实现或按该行归档，会把一个已被安全复验否决的阈值当成现行契约。
- **建议**：在 `:339` 行首标注「已被 §8 C5-2 取代：4096 → 16 + 采样预算」，或直接改写该行的修复内容。

### [轻微][存量] m5 两份 fix-plan 的「依据」文件 `verify-report*.md` 不存在

- **位置**：`f_svg/doc/spec/add-f-svg-m5/fix-plan.md:3`（依据 `verify-report.md`，CRITICAL 10 / WARNING 14 / SUGGESTION 6）、`f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md:3`（依据 `verify-report-2.md`，CRITICAL 1 + WARNING 12）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— `add-f-svg-m5/` 目录只有 `design.md`、`proposal.md`、`tasks.md`、`fix-plan.md`、`fix-plan-2.md`、`verification.md`、`verification-2.md`、`specs/`；全目录 `find -name "verify-report*"` 无命中（同类文件只存在于 `add-f-svg-m6` / `add-f-svg-m7`）。
- **描述**：修复计划的编号体系（C1–C10 / N1–N12）全部指向不存在的报告，读者无法核对每条 CRITICAL 的原始判据与证据；`verification-2.md` 也不含这些编号的完整原表。
- **建议**：把两份 `verify-report*.md` 补入目录，或在 `fix-plan*.md` 头部改为引用 `verification-2.md` 的对应小节。注：m4 的同类死引用已由本模块 part4 报告记录，本条只记 m5 实例，不重复计数。

### [轻微][存量] `svg-render-pipeline` 的媒体宽度来源未覆盖 `width="auto"` 分支

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md:89`（`options.width > 0` → 根绝对宽度 → 300）；实现 `f_svg/src/SvgRenderTree.cj:294-311`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「只做了一半的分支 / 规格未覆盖实现行为」
- **证据**：静态确定 —— 当根元素 `width` 或 `height` 为 `auto` 且 `options.width <= 0 && options.height <= 0` 时，实现先用 `SvgAutoSize.rootSize` 求内容尺寸、重算一次样式，再用该尺寸作为媒体宽度；规格只描述「根元素绝对宽度」，`auto` 既不是绝对值也不在 300 的回退口径内。
- **描述**：`width="auto"` + `@media` 的文档，其媒体宽度由内容自适应结果决定，规格无法推导；这条分支还会额外做一次全量样式计算（`SvgRenderTree.cj:289-292`、`:305-311`、`:315-320` 共三次 `compute`），文档未提示该成本。
- **建议**：在 `:89` 补一句「根 `width` / `height` 为 `auto` 且未给选项宽高时，媒体宽度取内容自适应结果」；若要控制成本，注明该分支会多算一次样式。

### [轻微][存量] `design.md` D10 描述的整形接口与实现完全不同，四个符号在仓内从未存在

- **位置**：`f_svg/doc/spec/add-f-svg-m5/design.md:117-120`（`SvgShapingFont` 接口、`shape(glyphIds, fontSize, features): SvgShapedRun`、`glyphId(codePoint)`、`glyphPathById(gid, fontSize)`）；实际实现 `f_svg/src/SvgGsubContext.cj:515`（`shapeGlyphs`）、`f_svg/src/SvgTrueTypeFont.cj:383`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「死代码（声明无定义 / 无消费）」、§13「文档过期」
- **证据**：静态确定 —— `grep -rn "SvgShapingFont\|SvgShapedRun\|glyphId\|glyphPathById" f_svg/src` 无命中；`git log -S "SvgShapingFont" -- f_svg/src`、`git log -S "SvgShapedRun" -- f_svg/src` 均为空，说明该接口从未落地（不是后续里程碑删除）。实现走内部 `SvgTrueTypeFont.shapeGlyphs` + `SvgGsubContext`，`SvgFont` 仍只有 5 个码点方法（`SvgFont.cj:26`），这一点与 D10 的结论一致。
- **描述**：D10 是本变更「文本整形」的对外扩展点设计：它向第三方字体实现承诺了 `SvgShapingFont` 这一旁路接口。按设计文档实现自定义字体时，编译器会报类型不存在；而实际整形能力只对内置 `SvgTrueTypeFont` 生效，第三方 `SvgFont` 实现无法接入 `liga` / `kern`。设计文档与实现相差的不是行号，而是整个接口形状。
- **建议**：把 D10 改写为实际方案（内部 `shapeGlyphs` + 字形 id 级接口），或在 `f_svg-M5设计.md` / README 明确「M5 的整形只覆盖内置 TrueType 字体，未提供 `SvgShapingFont` 扩展点」；若确需该扩展点，另开变更实现并保留 D10 作为目标设计。

### [轻微][存量] `svg-text` 只承诺「无 `GPOS` 时回退 `kern`」，实现还会在「有 `GPOS` 但无 `kern` 特性」时回退

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md:82`；实现 `f_svg/src/SvgOpenTypeLayout.cj:315-354`（`cssLayoutLookupRefs` 未找到 `kern` 特性引用或无 Type 2 子表时返回 `None`）、`f_svg/src/SvgTrueTypeFont.cj:345-352`（`gposPairs == None` 时改用 `kernPairs`）；决策 `f_svg/doc/spec/add-f-svg-m5/fix-plan.md:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `SvgGposPairs.parse` 在 `parsed == false` 时返回 `Option<SvgGposPairs>.None`（`SvgOpenTypeLayout.cj:347-349`），即便字体有 `GPOS` 表；`kerningAdjustByIds` 只按 `gposPairs` 是否为 `Some` 选择数据源。`fix-plan.md:21` 的 C2 明确要求「无 `kern` 特性时回退 `kern` 表」，规格未同步这一更宽的回退条件。
- **描述**：规格把回退条件限定为「字体无 `GPOS`」，实现的实际条件是「`GPOS` 中没有可用的 `kern` 特性 Type 2 lookup」。对同时含 `GPOS`（无 `kern` feature）与 `kern` 表的字体，实现会应用 `kern` 字距，而按规格应视为「有 GPOS，不读 kern」。这会让「GPOS 优先」的验收用例边界含糊：测试只需造一个 `GPOS` 表就能验证不回退，但真实字体常是「有 GPOS 表、无 kern feature」。
- **建议**：把 `:82` 改为「优先读取 `GPOS` 的 `kern` 特性 Pair Adjustment；`GPOS` 不存在或其中没有可用的 `kern` 特性 Type 2 lookup 时读取 `kern` 表 format 0」，并补一条「`GPOS` 存在但无 `kern` feature → 使用 `kern` 表」的 Scenario。

## 优化可行性方案

本部分 18 个文件全部是 `.md`，不含可测量的 CPU / 堆内存执行路径，因此**没有**可执行的性能或内存优化方案（§7 / §8 计 0 / 0）。文档层面的可量化收益只有「减少复核成本」（死引用、重复 Scenario、被否决结论残留），属可维护性，不构成性能方案。

## 待验证假设

> 无性能数据支撑，**不进 `todo.md` / `tasks.md`**，仅供下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getBBox` 单次约 51 ms（1000 元素文档，含样式树重算）对循环调用方已是热点，`svg-geometry` 规格却无成本提示 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md:11`；基线 `f_svg/doc/perf-baseline.md:126` | 调用频次与端到端占比；缓存版对照 | 1000 元素文档循环 100 次 `getBBox`，对比「每次重算」与「按根缓存样式树」两版中位数（`-O2`，同机） |
| 2 | 含 `@media` 的文档在 `build` 阶段会执行 3 次全量样式计算，占比可能显著 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md:89`；实现 `f_svg/src/SvgRenderTree.cj:289-320` | 单次 `compute` 自耗时占比 | `cjprof record` 渲染 1000 份含 `@media` 文档，统计 `SvgStyleResolver.compute` self time |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_svg.part5.txt` 一一对应，18 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/spec/add-f-svg-m4/verification-2.md` | .md | ✅ | 第二轮复验：C1–C4 清除、C5 仍存在；W7 引入 marker 裁剪误判；发现 §4.1 与实现抽查一致（`markerContentFits` 用内容矩阵） |
| 2 | `f_svg/doc/spec/add-f-svg-m4/verification-3.md` | .md | ✅ | 第三轮：C5-2 实现 16 + 预算、规格副本未同步；`openspec/changes` 副本已不在仓内（见 §13 说明，已由 part4 记录） |
| 3 | `f_svg/doc/spec/add-f-svg-m4/verification-4.md` | .md | ✅ | 第四轮：N2–N6 全清除、710/710、13/13 快照一致；与 `verification.md` §9 口径一致 |
| 4 | `f_svg/doc/spec/add-f-svg-m4/verification.md` | .md | ✅ | 累积式验收档案：§7 C5 行仍留 4096 上限（见发现）；§8/§9 结论与实现一致 |
| 5 | `f_svg/doc/spec/add-f-svg-m5/design.md` | .md | ✅ | D1–D14 与实现总体一致（选择器复合视图、`SvgMixBlendMode` 独立枚举、`effectiveElementTransform`、11 个新文件全部在位）；D3 `calc` 混用、D4 `src` 字段为旧口径、D10 整形接口不存在（见发现） |
| 6 | `f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md` | .md | ✅ | N1–N12 与实现对应（`local()` 目标、GSUB 链式深度、GPOS class matrix 合并）；`:41` 记录 weight/style 推迟到 M6 |
| 7 | `f_svg/doc/spec/add-f-svg-m5/fix-plan.md` | .md | ✅ | C1–C10 / W1–W14 与后续轮次递进清晰；依据 `verify-report.md` 不存在（见发现） |
| 8 | `f_svg/doc/spec/add-f-svg-m5/proposal.md` | .md | ✅ | 范围与 M5-P1…P4 条目齐全；`:23` 仍写「src 忽略」旧口径（见发现） |
| 9 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md` | .md | ✅ | 选择器模型、特异性、`@media` 默认 300、属性注册与实现一致（`:not` 计 1 次已核对 `CssSelector2.cj:809-823`）；`calc` 混用与 `src` 两处不一致（见发现） |
| 10 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-document-model/spec.md` | .md | ✅ | `querySelectorAll` 复用 `CssSelector.parse` 并抛 `InvalidValue`（`SvgElementApi.cj:391-400`）、`SvgFeDropShadow` 缺省 2/黑/1 与实现一致 |
| 11 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-filter/spec.md` | .md | ✅ | `feDropShadow` 参数回退与告警、区域外扩 `|d|+3σ` 与 `SvgFilterPrimitives.cj:490-548` 一致 |
| 12 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md` | .md | ✅ | 包围盒 / CTM / 路径长度行为与实现一致；公开签名缺 `mediaWidth`/`mediaHeight`（见发现） |
| 13 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-paint-and-clip/spec.md` | .md | ✅ | 混合公式、`isolation` 隔离组、`context-*` 只在 `use` 内有效，与 `SvgBlend.cj` / `SvgContextPaint.cj` 一致 |
| 14 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-rasterization/spec.md` | .md | ✅ | 预乘 RGBA 公式与钳制条款、零点 alpha 等价 source-over，与 `SvgBlend.cj` 像素路径一致 |
| 15 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md` | .md | ✅ | `paint-order` 层序、混合位置、`transform-origin` 顺序已接线；媒体宽度来源漏 `auto` 分支（见发现） |
| 16 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-security/spec.md` | .md | ✅ | 七项上限与常量逐项命中（`CSS_VAR_MAX_DEPTH=8`、`CSS_CALC_MAX_DEPTH=16`、`CSS_MAX_SIMPLE_SELECTORS=256`、`CSS_KERN/GPOS_MAX_PAIRS=65536`、`CSS_GSUB_MAX_DEPTH`） |
| 17 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md` | .md | ✅ | 连字簇消费列表项、`textLength`、跨 tspan 不配对与实现一致；字体别名 weight/style 条款无实现、`kern` 回退条件比实现窄（见发现） |
| 18 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-value-types/spec.md` | .md | ✅ | 枚举清单（12 值混合、`SvgTransformBox`、`SvgDirection`/`SvgUnicodeBidi`/`SvgFontKerning`）与 `SvgBlend.cj:26-39`、`SvgBidi.cj:83` 一致；Scenario 错位重复（见发现） |

合计：`.cj` 0 个 / `.md` 18 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码。语义不符按 §11/§13 计 10 条；注入与 XML 边界专项：规格只在 `svg-css` 要求「不加载外部资源、不发网络请求」，`src: url` 路径已确认不读文件，未发现转义/实体相关承诺缺失 |
| §1 死代码 | 1 | 无源码可判。改为核对文档声明的符号是否都有定义与消费点：`SvgMixBlendMode`（73 处）、`SvgTransformBox`（24 处）、`SvgPaintOrder`、`SvgContextPaint`、`SvgBidi`、`SvgElementApi` 全部命中；`design.md` D10 的 `SvgShapingFont` / `SvgShapedRun` / `glyphId` / `glyphPathById` 在 `src` 与 git 历史均无命中（发现 #9）。`CssFontFaceRule.weight/style` 有定义无消费，按功能未落地计入 §14（发现 #3），不重复计死代码 |
| §2 重复逻辑 | 1 | 逐份比对 10 份 M5 spec 与 M4 design 的同一契约：`paint-order`（value-types / render-pipeline）、`calc`（css / design D3）、`context-*`（css 注册 / paint 语义）、`feDropShadow`（document-model / filter）均分层描述、无行为漂移；唯一字面重复是 `svg-value-types` 的两条 Scenario（发现 #5） |
| §3 空实现 | 0 | 未发现「承诺但实现为空」：P1–P4 共 24 个子项均能在 `src/` 找到实现与测试；`fix-plan` 记录的「记录不改」两项（weight/style、`<use>` 自身混合）已在发现 #3 单列，其余不属于空实现 |
| §4 栈溢出 | 0 | 规格涉及的递归都有显式上界：GSUB lookup 深度 8（`SvgOpenTypeLayout.cj:140-180` 走 Extension 链才递增）、CSS 变量 8 层、`calc` 16 层、选择器 256 个简单选择器；`bidi` 嵌入栈深度在 `design.md:128` 定为 64/16 并 warning |
| §5 OOM | 0 | 规格的七项上限全部在分配前检查（`CssVariables.cj:62`、`CssCalc.cj:185`、`SvgOpenTypeLayout.cj:233,388,412`），`kern`/`GPOS` 超限整表忽略而非部分加载；本部分未发现新的无界物化承诺 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`getBBox` 51 ms 与 `build` 三次样式计算两条线索转「待验证假设」，不作结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁描述；规格未声明线程安全契约，无可判对象 |
| §6.3 并发串行 | 0 | 纯文档，无 `spawn` / `Future` 路径 |
| §6.4 低效算法 | 0 | 唯一结构性线索是 `getBBox` 每次从根重算样式（`svg-geometry` 规格 `:11` 明确不缓存），缺调用频次数据，转「待验证假设」#1 |
| §7 降堆内存方案 | 0 | 文档无持有对象，不产出内存方案 |
| §8 降 CPU 方案 | 0 | 无基线数据，不做「能降 X%」的断言 |
| §9 local mode 可行性 | 0 | 本部分无函数体；M5 规格未引入 local mode 相关类型或标注 |
| §11 现有代码的 BUG（存量） | 1 | 发现 #4（告警文案陈述与行为相反）；另核对 `:empty` 全空白视为空、`transform-origin` 单值补 `center`、`SvgFeDropShadow` 缺省 2/黑/1 三处易错点，均与实现一致，未计 |
| §12 并发安全与锁粒度 | 0 | 纯文档；规格中的 `SvgFontRegistry.derived` 明确「不写入调用方注册表」，属不可变派生，未引入共享状态 |
| §13 文档一致性（.md） | 8 | 发现 #1/#2/#3/#6/#7/#8/#9/#10；另核对 `openspec/changes/add-f-svg-m4|m5` 与 `openspec/specs/svg-*` 死引用——该根因已由 part3/part4 记录，本部分不重复计数 |
| §14 功能完备性与 README 覆盖 | 2 | 发现 #3（别名区分未实现）、#8（`auto` 分支未入规格）；README 覆盖以 `README.md` 为基准，属本模块 README 部分，本部分不重复计 |
| 文件覆盖（§13 等） | 18/18 | 18 个 `.md` 全部逐行读完，无缺 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 10 条（0 严重 / 4 一般 / 6 轻微），是否纳入修复待用户决定。

## 总评

本部分是 f_svg 的 M4 验收档案与 M5 变更文档，不含运行时代码，因此没有可直接触发的注入、越界或崩溃路径；真正的风险是**「规格、修复计划、实现」三方不同源**。M5 的十项能力在代码里都已落地，抽查的枚举取值、上限常量、缺省值、合成顺序与规格基本吻合，说明实现完成度较高；但有三处规格级偏差会让「照文档实现 / 照文档验收」出错：`calc()` 混用单位被写成全局无效（实际几何属性支持）、元素级 API 签名漏 `mediaWidth`/`mediaHeight`（默认 300×150 与渲染宽度不一致）、字体别名声称区分字重与字形（实现只做 family 映射）。这三条与 `fix-plan` 的同一编号条目直接冲突，建议在归档前以 fix-plan 为准回收规格，而不是留待下一里程碑。

其余为档案质量问题：m4 `verification.md` 第 7 节残留被第 8 节否决的 4096 上限、m5 两份 fix-plan 的依据报告缺失、`svg-value-types` 两条 Scenario 错位重复、`width="auto"` 分支未入规格、`design.md` D10 承诺了一个从未实现的 `SvgShapingFont` 扩展点、`svg-text` 的 `kern` 回退条件比实现窄。这些不影响运行时行为，但会持续消耗复核成本，可排在规格修订同一批处理。本部分未发现阻塞项，也未发现 OOM / 栈溢出级别的规格缺陷；D10 的扩展点缺失若被下游当作可用能力（自定义 `SvgFont` 接入 `liga` / `kern`），会直接导致编译失败或能力误判，建议与三处规格偏差同批清理。
