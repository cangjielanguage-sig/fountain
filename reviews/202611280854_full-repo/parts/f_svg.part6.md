# f_svg 模块审查报告（模块第 6/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（模块共 301 个 `.cj` + 141 个 `.md`；**本部分 15 个文件，全部为 `.md`**：`doc/spec/add-f-svg-m5` 的 3 份验收文档、`doc/spec/add-f-svg-m6` 的 5 份过程/设计文档、7 份 m6 delta 规格）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线，问题来源统一记「存量」）
- **审查重点**：本部分无 `.cj`，按审查目标落到「规格/设计/验收文档与实现的一致性」——逐条核对文档承诺的公开 API、限值、渲染语义、用例计数与文件清单是否在 `f_svg/src` 成立；顺带核对文档内部自洽与引用可追溯性
- **报告版本**：v1

## 发现

### [一般][存量] `text-decoration-color` 缺省值：规格承诺 `currentColor`，实现取文本 `fill`；同一属性在计算样式里还有「初始串 currentColor / 类型化 getter 返回 None」两套答案

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-css/spec.md:254-257`（Scenario「缺省颜色」）、`f_svg/doc/spec/add-f-svg-m6/design.md:162`（D13「颜色缺省取字形 `fill`」）、`f_svg/src/SvgComputedStyle.cj:148`（`SvgPropertySpec("text-decoration-color", false, "currentColor")`）、`f_svg/src/SvgComputedStyle.cj:503-514`（`textDecorationColor()` 缺省返回 `None`）、`f_svg/src/SvgRenderer.cj:335-338`、`:352-370`（`None` 时回落到 `style.fill()`）、`f_svg/src/SvgTextRenderer.cj:71`（注释「`None` 沿用文本填充」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符 / 语义与注释不符」
- **证据**：静态确定 —— 规格场景写「未声明 `-color` → 颜色取 `currentColor`」；`SvgComputedStyle.textDecorationColor()` 在 `sourceOf == Default` 时直接返回 `Option.None`，`SvgRenderer` 对 `None` 的 run 用 `style.fill()` 作 paintOverride（`SvgRenderer.cj:337`、`:357-359` 的 `None` 分支最终走 `drawFill` 的 fill），缺省路径没有任何地方读 `color` 属性
- **描述**：`currentColor` 在 CSS 里解析为 `color` 属性值，而实现解析为 `fill`。当文本 `color` 与 `fill` 不同（例如 `color="blue" fill="red"`，或 `fill` 为渐变/`url()`）时，缺省装饰线的颜色与规格、与浏览器都不一致；`text-decoration-color: currentColor` 显式声明时又会按 `color` 解析（`SvgComputedStyle.cj:505`），于是「显式写 currentColor」与「不写」在同一文档里得到两种颜色。规格与设计本身也互相矛盾（spec 说 currentColor，design D13 说 fill），属 M6 收口时留下的契约分叉
- **建议**：二选一并写进规格：①按 CSS 语义把缺省值解析为 `style.color()`（`SvgComputedStyle.color()` 已存在），并补「`fill` 为 paint server 时装饰线仍是纯色」的用例；②若确定沿用 `fill`，则把 `svg-css` 场景与 `SvgPropertySpec` 的初始串一并改为「缺省取 `fill`」，去掉 `currentColor` 字样，避免使用者按 CSS 语义预期

### [一般][存量] `SvgTimeline.duration()` 未随 M6 `max` 钳制更新：条款承诺「最晚结束时间」，实现返回未截断的 `begin + dur`

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-animation/spec.md:58`（`duration()` SHALL 返回所有动画的最晚结束时间）、同文件 `:170`（`min` / `max` 生效活动时长钳制）、`f_svg/src/SvgTimeline.cj:179-186`（构造期 `spec.end = begin + max(total, minValue)`，**未套 `maxValue`**）、`f_svg/src/SvgTimeline.cj:191-199`（`duration()` 直接取 `spec.end` 最大值）、`f_svg/src/SvgTimeline.cj:769-773`（采样时 `effectiveEnd` 才用 `begin + maxValue` 截断）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格两条要求互相冲突」、§11「契约与实现不符」
- **证据**：静态确定 —— `dur="10s" max="3s"` 时 `spec.end = begin + 10`，`duration()` 返回 10；而 `animationStateAt` 收到的 `effectiveEnd` 被钳到 `begin + 3`，动画在 3 秒结束。两个数在同一个类里来自两条不同计算路径
- **描述**：`max` 是 M6 新增能力，`duration()` 条款没有同步。调用方按 `duration()` 决定时间轴长度、循环采样或导出帧序列时，会在 3 秒后拿到整段「已结束、值不再变化」的空白时间；反过来若把 `duration()` 当动画真实终点判断「是否播完」，永远等不到。同一文档里 `animations()` 返回的 `end` 也是未截断值（`SvgTimeline.cj:201-209`），存在同样偏差
- **建议**：`spec.end` 计算时把 `maxValue` 一并纳入（`min(max, max(min, total))`），或在 `duration()` / `animations()` 里统一走 `effectiveEnd`；若「duration 表示未钳制的名义时长」是有意设计，则改规格措辞并新增「钳制后实际终点由 `sample` 决定」的说明与用例（`dur=10s max=3s` 时 `duration()` 期望值需明确）

### [轻微][存量] `design.md` / `proposal.md` 的代码规模、文件清单、行号锚点与结构描述未随 M6 实现回流

- **位置**：`f_svg/doc/spec/add-f-svg-m6/design.md:5`（「288 个源文件，其中 163 个测试文件」）、`:11`（`SvgElement.cj:333` 指 `getBBox`）、`:12`（`SvgRenderTree.cj:534` 指 `foreignObject`）、`:13`（`SvgRenderTree.cj:700` 指 `use`）、`:17`（`SvgRasterizer.cj:118` 指固定容差 0.25）、`:149`（D12 的 `SvgGsubFeatureSet`）、`:211`（D18「15 个新文件」）、`:218`（「新文件只放内部实现与公开枚举 / 结构体」）、`f_svg/doc/spec/add-f-svg-m6/proposal.md:87`（列 18 个新增文件）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 链接失效」、§14.1「接线缺失（文件地图与实现不符）」
- **证据**：静态确定 ——
  - `ls f_svg/src/*.cj | wc -l` = **301**、`*_test.cj` = **169**（文档写 288 / 163）。
  - `proposal.md:87` 的 `SvgColorProfile.cj`、`SvgAnimationControl.cj`、`SvgLineJoin2.cj` 三个文件在 `f_svg/src` 不存在（`design.md:211` 已说明并入 `SvgRenderingHints.cj` / `SvgTimeline.cj` / `SvgShape.cj`，但 proposal 未同步）。
  - 行号锚点全部漂移：`SvgElement.cj:333` 实际是 `false`（`getBBox` 在 `:452`），`SvgRenderTree.cj:534` 实际是 `expandUse` 分支（`foreignObject` 分支在 `:646`/`:651`），`SvgRasterizer.cj:118` 是空行（`0.25` 容差在 `:103`）。
  - `design.md:211` 称 15 个新文件，实际 M6 新增 16 个：`f_svg/src/SvgViewState2.cj:19`（`public class SvgViewState`）由 M6 P7 提交 `a061fe1ef` 引入，不在清单内。
  - `design.md:218` 称新文件只放内部实现与公开枚举 / 结构体，实际新文件声明了公开类并带 public 方法：`SvgHitTest.cj:142`（`public class SvgHitTest`）、`:203`/`:240`（`public static func elementsAt`/`elementAt`）、`SvgAutoSize.cj:32`、`SvgMutation.cj:42`、`SvgHitTest.cj:26`（`SvgInteractionState`）。
  - `design.md:149` 要求的 `SvgGsubFeatureSet` 全仓无定义；实现是单一 `SvgGsubLigatures`（`SvgOpenTypeLayout.cj:535`）加 `ligatureAt(..., feature:)`（`SvgTextRenderer.cj:1851`）。
- **描述**：design 是后续维护者读 M6 的第一入口，规模、文件清单、行号锚点与 D12/D18 的结构描述同时漂移会让「按文档找实现」失效：按 proposal 找 `SvgColorProfile.cj` 会扑空，按 design 的 `SvgElement.cj:333` 找不到 `getBBox`，按 D18 会认为新文件里没有公开 API，按 D12 会去找不存在的 `SvgGsubFeatureSet`
- **建议**：规模数字改为「以 `f_svg/src` 为准，不写死」或每次收口用脚本刷新；proposal 的 Affected code 列表加一句「最终文件清单见 design D18」；行号锚点改为「函数名 + 文件」而非裸行号；D18 补 `SvgViewState2.cj` 并把「新文件只放内部实现与公开枚举 / 结构体」改为「新文件可声明公开类型，新增到既有类型的方法仍写在原类体内」；D12 改为实际的「单一 `SvgGsubLigatures` + feature 参数按名查询」

### [轻微][存量] 过程文档引用的 `openspec/changes/add-f-svg-m5|m6/...` 路径在仓库中不存在；m5/m6 delta 规格声明为 `MODIFIED Requirements`，但 `openspec/specs` 里没有对应 `svg-*` 主规格

- **位置**：`f_svg/doc/spec/add-f-svg-m6/fix-plan-2.md:3`、`f_svg/doc/spec/add-f-svg-m6/fix-plan-3.md:3`、`f_svg/doc/spec/add-f-svg-m5/verification.md:3`、`f_svg/doc/spec/add-f-svg-m5/verification-2.md:35`、`:69`；`f_svg/doc/spec/add-f-svg-m6/specs/*/spec.md`（7 份 delta 均以 `## MODIFIED Requirements` 开头）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」、§14.1「能力未接入 / 版本与索引漂移」
- **证据**：静态确定 —— `ls openspec/changes` 只有 `add-f-a2a/` 与 `archive/`，没有 `add-f-svg-m5` / `add-f-svg-m6`；`ls openspec/specs` 只有 `data-assist-compare` / `data-assist-supertypes` / `jwt-signature` / `orm-result-type-mapping` / `uring-async-io`，无 `svg-css` / `svg-text` 等能力域。文档内容实际存放在 `f_svg/doc/spec/add-f-svg-m*`（`m5/verification.md:393` 自述「`openspec/` 被 `.gitignore` 忽略，仅工作树生效」）
- **描述**：fix-plan-2 把 `openspec/changes/add-f-svg-m6/verify-report.md` 写成依据，fix-plan-3 把 `verify-report-2.md` 写成依据，这两条路径今天都打不开（同名文件在 `f_svg/doc/spec/add-f-svg-m6/verify-report*.md`）；m5 的验收报告把校验对象写成 `openspec/changes/add-f-svg-m5`。同时 7 份 delta 规格声明的 `MODIFIED Requirements` 没有可对照的主规格，「改写了哪条既有要求」无法验证，归档动作（m5 tasks 13.7 / m6 tasks 9.8）也失去前置条件
- **建议**：把过程文档里的 `openspec/changes/...` 统一改为 `f_svg/doc/spec/...` 的实际路径，或补回被忽略的目录；delta 规格若要继续保留 `MODIFIED` 语义，应同时提交 `openspec/specs/svg-*` 主规格（或改为 `ADDED Requirements` 并在归档时再合并）

### [轻微][存量] M5 同目录两份复验报告结论相反，且未标注取代关系

- **位置**：`f_svg/doc/spec/add-f-svg-m5/verification-2.md:144-147`；`f_svg/doc/spec/add-f-svg-m5/verification.md:411`、`:423`、`:456`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 文档结论与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— `verification-2.md:144-147` 的最终结论为「C4 部分清除（`Body → Brand` 别名主场景仍未实现）」「在该 CRITICAL 解决前，不应把本变更归档为 M5 完成」，`:147` 明写 `CRITICAL=1`；`verification.md:411` 的 §9 标题为「第二轮复验修复（fix-plan-2 / verify-report-2）」，`:423` 的 N1 行结论为「已清除」，`:456` 为「CRITICAL=0」，即 §9 是晚于 verify-report-2 的修复记录。当前实现支持 §9：`SvgFont.cj:91-104` 已按 `src: local(<family>)` 建立目标别名，`CssFontAliasM5_test.cj:59` 的 `localSourceAliasesRegisteredFamily` 用例存在
- **描述**：同一变更目录里两份文档对「能否归档」给出相反答案，而 `verification-2.md` 既没有指向 §9 的前向说明，文件名（`verification-2.md`）与正文标题（`add-f-svg-m5 修复后复验报告（verify-report-2）`）也不一致。按目录顺序阅读会先看到「CRITICAL=1、不应归档」，据此做归档门禁判断会得到错误结论
- **建议**：在 `verification-2.md` 顶部加一行状态说明「本报告结论已被 `verification.md` §9 取代：N1 已清除，CRITICAL=0」；文件名改为 `verify-report-2.md`，与 `add-f-svg-m6` 目录的 `verify-report*.md` 命名保持一致

> 存量缺陷共 5 条，是否纳入修复待用户决定。

**范围外提示**（证据所在的文件属于第 7 部分，不计入本部分统计）：

- `f_svg/doc/spec/add-f-svg-m6/verification.md` 的最终门禁数字自相矛盾（`:4`、`:543-544` 为 1186，`:580`、`:590`、`:599-600` 为 1187），且 `:178-182` 把「抗锯齿」5 个场景的落点标成 `SvgRasterizer_test`（该类无 `antiAlias` 断言），建议由第 7 部分复核。
- `f_svg/src/SvgHitQueries.cj:28`、`:46`、`:82-83` 把样式与 bbox 的视口固定成 `300 × 150`，含 `@media` 或百分比几何的文档按 `width=800` 渲染时查询结果会与渲染不一致（该文件不在本部分清单内，仅记一句）。

## 优化可行性方案

本部分为设计/规格/验收文档，未产出可量化的堆内存或 CPU 方案（性能候选项缺改前/改后对照，已降级到「待验证假设」）。

## 待验证假设

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `design.md` D8 承诺「256 项查表缓存避免逐像素 `pow`」未实现，`linearRGB` 渐变每采样点做 3 次 `pow` 反变换，可能是渐变填充热点 | `f_svg/doc/spec/add-f-svg-m6/design.md:118`；`f_svg/src/SvgGradient.cj:287`（每样本 `svgColorFromLinear`）、`:591-609`（`pow`） | 该分支自耗时占比与相对 `sRGB` 的倍数 | `cjpm bench -O2` 同几何分别声明 `sRGB` / `linearRGB`，1000×1000 全屏线性渐变，取中位数；再用 `cjprof record` 看 `svgChannelFromLinear` self time |
| 2 | `getIntersectionList` / `checkEnclosure` 每次调用重算整棵样式树，1000 元素文档下已是 60–120 ms，更大文档（`maxElements` 默认 1e6）可能成为交互查询瓶颈 | `f_svg/doc/perf-baseline.md:131-142`（改前基线）；`f_svg/src/SvgHitQueries.cj:20-48` | 改后对照（缓存 / 复用样式树）与 5000 / 10000 元素的曲线 | 同机 `-O2`，1000 / 5000 / 10000 元素各跑 30 次取中位数与 P95，对照「复用同一 `SvgComputedStyleTree`」的实现 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/add-f-svg-m5/tasks.md` | .md | ✅ | 13 组任务（1.1–13.6）全勾选，仅 13.7（合并分支）未勾；`1.2` 基线 710 与 `13.1` 的「708 保持不变 + 2 条改写」自洽，无新问题 |
| 2 | `doc/spec/add-f-svg-m5/verification-2.md` | .md | ✅ | 第二轮复验（CRITICAL=1，C4 部分清除）；结论已被 `verification.md` §9 取代但无标注，见发现 #5；引用的 `openspec/changes/...` 路径失效，见发现 #4 |
| 3 | `doc/spec/add-f-svg-m5/verification.md` | .md | ✅ | 第一轮 10 CRITICAL + §8 修复结论 + §9 二轮修复；§9 与实现一致（`SvgFont.cj:91-104`）；与 `verification-2.md` 的结论冲突见发现 #5 |
| 4 | `doc/spec/add-f-svg-m6/design.md` | .md | ✅ | 19 条决策；D13 与 spec 的颜色冲突见发现 #1，规模/文件清单/行号/结构描述过期见发现 #3，D8 的「256 项查表缓存」未实现见待验证假设 #1；D5 外部文档不递归与实现一致 |
| 5 | `doc/spec/add-f-svg-m6/fix-plan-2.md` | .md | ✅ | 13 CRITICAL + 14 WARNING 清单；`依据` 指向的 `openspec/changes/...` 不存在（发现 #4）；清单项在源码中均可找到对应落点（`elementsAt` 静态化、`SvgMutationKind`、`vectorEffects()` 等） |
| 6 | `doc/spec/add-f-svg-m6/fix-plan-3.md` | .md | ✅ | 第三轮 N1 + W1–W10；N1（外部文档强制 `Remove`）在 `SvgRenderTree.cj:1871-1889` 落地；`依据` 路径同样失效（发现 #4） |
| 7 | `doc/spec/add-f-svg-m6/fix-plan.md` | .md | ✅ | 第一轮 C1–C4 + W1–W5；C1 的 `useDepth` 独立计数在 `SvgRenderTree.cj:981-983`/`:1095` 落地，循环优先于深度（`:976-980`）与规格一致；C3 的 GSUB 5/6 在 `SvgGsubContext.cj:48-308` 落地 |
| 8 | `doc/spec/add-f-svg-m6/proposal.md` | .md | ✅ | 18 个新增文件里 3 个未创建（发现 #3）；「997 基线 / 55 Requirement」与 verification 一致 |
| 9 | `doc/spec/add-f-svg-m6/specs/svg-animation/spec.md` | .md | ✅ | 33 Scenario；`duration()` 与 `max` 钳制冲突（发现 #2）；`setCurrentTime` 负数/NaN、`pause/unpause` 与 `SvgTimeline.cj:314-340` 一致 |
| 10 | `doc/spec/add-f-svg-m6/specs/svg-css/spec.md` | .md | ✅ | 9 Requirement / 41 Scenario；`@color-profile`、`pointer-events`、`cursor`、四渲染提示、字体属性、装饰长属性均能在 `SvgRenderingHints.cj` / `SvgPointerEvents.cj` / `SvgCursor.cj` / `SvgFontVariant.cj` 找到实现；装饰色冲突见发现 #1 |
| 11 | `doc/spec/add-f-svg-m6/specs/svg-document-model/spec.md` | .md | ✅ | 5 Requirement / 23 Scenario；`baseProfile` / `version` / `zoomAndPan`（缺省 `Disable` + warning）、`insertBefore` / `removeChild`（返回 `Bool`）、监听上限 32、`pointer-events: none` / `visibility: hidden` 过滤均与实现一致 |
| 12 | `doc/spec/add-f-svg-m6/specs/svg-geometry/spec.md` | .md | ✅ | 4 Requirement / 17 Scenario；`SvgHitTest.elementsAt(root, point, viewport, styles)` 静态签名、`DPR` 换算、`pathLength ratio = 实际/声明`（`SvgPathLength.cj:21-44`）、vector-effect 固定顺序均一致 |
| 13 | `doc/spec/add-f-svg-m6/specs/svg-paint-and-clip/spec.md` | .md | ✅ | 3 Requirement / 12 Scenario；`linearRGB` 中点 188 与 `SvgGradient.cj:591-609` 的转换公式吻合；`color-profile` 走 `SvgGradientSampler` 自身/祖先样式 |
| 14 | `doc/spec/add-f-svg-m6/specs/svg-rasterization/spec.md` | .md | ✅ | 3 Requirement / 18 Scenario；`Analytic` 档与 64× 参考图断言存在（`SvgAnalyticRasterizer_test.cj`）；覆盖矩阵落点标错属第 7 部分的 `verification.md`，已记入范围外提示 |
| 15 | `doc/spec/add-f-svg-m6/specs/svg-render-pipeline/spec.md` | .md | ✅ | 9 Requirement / 34 Scenario；外部文档 16 MiB / 单次 provider 调用 / 环引用深度 64 全部落地（`SVG_EXTERNAL_MAX_BYTES`、`missingExternalDocuments`、`useStack`），`foreignObject` 的 `maxPixels` 前置校验在 `SvgRenderTree.cj:665`、`:683` |

合计：`.cj` 0 个 / `.md` 15 个 / 共 15 个，全部读完（与 `files/f_svg.part6.txt` 的 15 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 文档承诺与实现语义不符 2 处（发现 #1、#2）；其余规格条款逐条对照实现通过。本部分无 `.cj`，语言特性与安全性（注入/转义）无直接载体；XML 边界与注入仅在 `svg-render-pipeline` / `svg-document-model` 中以外部文档、`foreignObject` 形式出现，其 `unsafePolicy=Remove`、`allowExternalReferences=false`、`maxPixels` 校验均已核对成立 |
| §1 死代码 | 0 | 本部分无代码。按「文档层面的死引用」机械核对：design/proposal 提到的每个新文件、每个公开符号是否可解析——3 个文件不存在、3 处行号锚点失效、`SvgGsubFeatureSet` 无定义，已合并进发现 #3，不重复计入 |
| §2 重复逻辑 | 0 | 已两两比对 15 份文档的功能重叠：`fix-plan` / `fix-plan-2` / `fix-plan-3` 是三轮独立记录，`verification` / `verification-2` 是两轮记录，属历史版本而非重复实现；7 份 delta 规格各自覆盖不同能力域，无同义 Requirement；proposal Impact 与 design D18 的清单差异按 §13 计（#3），不重复计入 |
| §3 空实现 | 0 | 逐份检查 `TBD` / `TODO` / 「待补」：7 份 m6 规格无占位；`tasks.md` 未勾选项仅 13.7（合并分支，流程项）；m5 `verification.md:440-445` 的「记录不改项」逐条点名能力与原因，无无归属的占位承诺 |
| §4 栈溢出 | 0 | 文档中唯一的递归语义是 `use` 展开：`svg-render-pipeline` 要求「环引用在深度 64 终止并 warning」，实现 `SvgRenderTree.cj:976-984` 先查 `useStack` 再判 `useDepth`，环不进入深度抛错分支；`foreignObject`/外部文档不递归，无无界递归承诺 |
| §5 OOM | 0 | 文档承诺的每个上限都核对到实现：外部文档 16 MiB（`SVG_EXTERNAL_MAX_BYTES`）、特性条目 64（`SvgFontVariant.cj:111`）、监听器 32（`SvgMutation.cj:72`）、`foreignObject` 位图 `maxPixels`、命中 `maxElements`；无「全量物化」类承诺 |
| §6.1 热点瓶颈 | 0 | 本部分不含 profile / bench 数据（`perf-baseline.md` 不在本部分清单），唯一性能疑点（`linearRGB` 逐样本 `pow`）无自耗时占比，已列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 15 份文档不涉及锁；`svg-document-model` 的变更监听是同步调用，未承诺线程安全 |
| §6.3 并发串行 | 0 | 无 `spawn` / 批处理相关条款 |
| §6.4 低效算法 | 0 | 文档未规定算法复杂度；`getIntersectionList` 的 60–120 ms/1000 元素已有改前基线，缺改后对照，列入待验证假设 #2 |
| §7 降堆内存方案 | 0 | 本部分无内存持有路径描述；`design.md` 的「不引入跨调用缓存」与实现一致，无「缓存无界」承诺 |
| §8 降 CPU 方案 | 0 | 见待验证假设 #1（无基线，不写成方案） |
| §9 local mode 可行性 | 0 | 本部分文档未提出 local mode 改造；相关数据在 `doc/perf-baseline.md`（不在本部分清单），且已有「8 MiB 门限 / ohos 不支持」结论 |
| §11 现有代码的 BUG（存量） | 2 | 发现 #1（装饰色缺省值）、#2（`duration()` 与 `max`）；两者都是「规格承诺 × 实现行为」双证后判定，非纯文档措辞 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程安全，也未引入共享可变状态；`SvgTimeline` 的 `pause/unpause`/触发状态是实例内字段，与规格「所有状态在实例内」一致，无并发契约可核对 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 7 份 delta 规格共 39 Requirement / 178 Scenario，逐条核对存在性：公开类型/方法（`SvgPointerEvents`、`SvgZoomAndPan`、`SvgViewState`、`SvgHitTest.elementsAt`、`SvgTimeline.fireEvent` 等）全部在 `f_svg/src` 命中；偏差只在文档落点与计数，已归 §13（发现 #3、#5） |
| 文件覆盖（§13 等） | 15/15 | 无缺文件；15 个 `.md` 全部读完，与 `files/f_svg.part6.txt` 行数一致 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 待验证假设 2 条，不计入统计；范围外提示 2 条，不计入统计。

## 总评

本部分是 f_svg 的 M5 收尾与 M6 全套过程文档（设计、三轮修复计划、验收报告、7 份 delta 规格），没有源码。文档整体质量高于一般项目：每条规格都带可执行 Scenario，限值（16 MiB / 64 / 32 / 8 层 / `maxPixels`）都能在源码里找到对应常量与前置检查，`use` 环引用先于深度判定、外部文档强制 `Remove`、`foreignObject` 像素预算这类容易漏的点也都落到了实现。

主要风险不在「文档没写」，而在**收口后的回流**：

- 两条契约分叉会直接影响使用者——`text-decoration-color` 缺省值（spec 说 `currentColor`，实现与 design 用 `fill`）和 `SvgTimeline.duration()` 未跟随 `max` 钳制。前者在 `color != fill` 时渲染结果与规格不符，后者会让「按 duration 采样到终点」的调用方多算一段空白时间；建议优先按发现 #1、#2 定口径，再决定改代码还是改规格。
- 验收材料可追溯性偏弱：design/proposal 的规模、文件清单、行号锚点与 D12/D18 结构描述均已过期，M5 两份复验报告结论相反且无取代标注，过程文档引用的 `openspec/changes/...` 路径与主规格在仓库中不存在。这些不影响当前渲染行为，但会让下一轮审计无法只凭文档复现结论。

结论：无阻塞项。建议把发现 #1、#2 作为「规格口径确认」一次性排期（各改一处即可闭合），#3–#5 归入文档治理批量修正；待验证假设 #1/#2 需补 `cjprof` / `cjpm bench` 数据后再决定是否立优化任务。范围外提示的 2 条（`m6/verification.md` 计数矛盾与覆盖矩阵落点、`SvgHitQueries` 固定视口）交由第 7 部分与本模块实现审查处理。
