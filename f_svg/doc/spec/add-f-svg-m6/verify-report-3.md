# add-f-svg-m6 第三轮只读终验报告

- 复验对象：`openspec/changes/add-f-svg-m6`（第三轮范围 `4e51fa29..HEAD`，HEAD `0143cc20`）。
- 复验依据：`f_svg/doc/spec/add-f-svg-m6/verification.md` 第三轮块、`fix-plan-3.md`、`verify-report-2.md`。
- 复验方式：只读代码审阅 + `cjpm test` + `cjpm build` + 快照 SHA-256 / 逐字节复核 + delta spec 与覆盖矩阵逐行比对。
- 约束：未改代码、未归档、未执行 git 写操作；worktree 的 git 读取使用显式 `GIT_DIR` / `GIT_WORK_TREE`，未运行 `git worktree`。

## 0. 门禁结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | **1186 / 1186 PASSED / 0 SKIPPED / 0 ERROR / 0 FAILED** | `f_svg/cjpm test`（本次实测） |
| 构建 | `cjpm build success`；日志中的 22 条 warning 均来自依赖 `f_xml`，未观察到 `f_svg` 源码 warning | `f_svg/cjpm build` |
| delta 规模 | **55 Requirement / 256 Scenario** | 10 个 `specs/*/spec.md` 标题计数 |
| 覆盖矩阵 | **55 Requirement / 256 Scenario**，场景名逐字一致 | 对 `verification.md` 第 1 节与 delta spec 做脚本比对，无缺失/多余 |
| M1–M5 快照 | **25/25 逐字节一致** | 17 张 M1–M4 SHA-256 与 `doc/perf-baseline.md` 一致；8 张 M5 由 `SvgSnapshotM6_test` 逐字节比对通过；`git diff f3aa5dec..HEAD -- f_svg/testdata/render` 只有 `A m6-*` |
| M6 快照 | 9/9 未变且确定性通过 | `SvgSnapshotM6Scenes_test.scenesExact/scenesAreDeterministic` |
| CRITICAL | **0** | N1 指定验收路径关闭；边界项见 §3 |

## 1. N1 与 W1–W10 逐条结论

| 编号 | 结论 | 实现与证据 |
|---|---|---|
| **N1 外部文档不递归** | **已清除** | `SvgRenderTree.cj:1866-1884` 的 `svgExternalParseOptions` 对外部文档强制 `unsafePolicy=Remove`、`allowExternalReferences=false`，并置 `externalDocumentMode=true`；`SvgBuilder.cj:459` 仅在非外部文档模式才走 `strict` 抛错分支，外部 `href` 落到 `Remove + warning`。`SvgExternalDocumentM6_test.cj:283-316` 在 `strict=true` 下对 `Reject` / `Remove` / `Keep` 三策略断言 provider 只调用一次、无异常、有 warning，测试通过。data: 与 strict 非 href 边界见 §3 W-3-2/W-3-3。 |
| **W1 pointer-events: all** | **已清除** | `SvgHitTest.cj:435-470` 不再对非容器元素走 `All → bbox` 短路；`svgHitWantsFill/Stroke`（`:480-498`）把 `All` 纳入路径与描边几何且不检查 `visibility` / 画笔。`SvgHitTestM6_test.cj:105-118` 的三角形包围盒外负向、`fill/stroke:none` 与 `visibility:hidden` 正向断言通过。 |
| **W2 文本容差二次缩放** | **已清除** | `SvgRenderer.cj:489-493` 在 `command.textTolerance` 存在时直接使用，仅 `None` 回退 `svgShapeTolerance`；文本容差映射 `svgTextTolerance`（`:1255-1263`）只由 `text-rendering` 决定。`SvgTextToleranceM6_test.cj:107-111` 的 `optimizeSpeed` + `geometricPrecision` 像素一致断言通过。 |
| **W3 wavy 开放折线填充** | **已清除** | `SvgTextRenderer.cj:74-88, 882-892` 给装饰 run 标记 `wavy`；`SvgRenderer.cj:330-351` 对 wavy 使用 `StrokePath`、`strokeWidthOverride=thickness`，`drawPaint`（`:507-518`）在覆盖线宽时清空 dasharray/dashoffset。`SvgDecorationM6_test.cj:184-199` 的波谷下方 1px 仅描边可达断言通过。 |
| **W4 stretch 非精确匹配** | **已清除（按 fix-plan-3）** | `SvgTextRenderer.cj:1946-1968` 以 `请求值 / matchedStretch` 缩放，`percent == matched` 才跳过；`SvgFont.cj:149-211` 返回实际命中面 stretch。`SvgFontStretchMatchM6_test.cj:97-102` 的 75% 面 + 80% 请求断言通过。与 delta spec 的 `百分比/100` 文本口径差异见 §3 W-3-1。 |
| **W5 clig 未参与替换** | **已清除** | `SvgTrueTypeFont.cj:112-113, 285-296, 369-374` 解析/保存 `clig` 表并支持 `ligatureTableFor("clig")`；`SvgTextRenderer.cj:1791-1851` 按 `hlig` / `liga` / `clig` 选择 Type 4 表。`SvgFontFeatureApplyM6_test.cj:81-103` 的默认开启、`none` 关闭、显式 `clig 0` 关闭断言通过。 |
| **W6 命中 API 形态** | **已清除** | `SvgHitTest.cj:203, 240` 为 `public static func elementsAt/elementAt`；`SvgHitTestM6_test.cj:211-227` 以规格写法静态调用通过。仓颉不允许同名静态/实例方法混载，实例形态已移除；该偏差已在 `verification.md` §3“W6 兼容入口”明确记录。 |
| **W7 provider None 未缓存** | **已清除** | `SvgRenderTree.cj:257-261` 新增 `missingExternalDocuments`；`:895-907` 在 provider 返回 `None` 时写入负缓存，后续同 href 只 warning、不再调用 provider。`SvgExternalDocumentM6_test.cj:265-277` 两次 `use` 断言 `calls == 1`，通过。 |
| **W8 旧用例表述** | **已清除** | `verification.md` §4 已改为“未削弱旧断言”，列明 `CssStyleSheet_test.cj`、`CssSelectorCascadeM5_test.cj`、`CssSelectorStructuralM5_test.cj` 的 `:hover → :active` 适配与 `SvgKerningLayoutM5_test.cj` 的 helper 扩展。 |
| **W9 design 深度残留** | **已清除** | `design.md:85-96` 只保留负结果缓存、强制 `Remove` 与“深度常量仅异常路径防御”；`README.md:625-627`、`README_en.md:680` 同步。 |
| **W10 覆盖矩阵计数** | **已清除** | `verification.md` 第 1 节重生成；脚本比对 55 Requirement / 256 Scenario 的 Requirement 名与 Scenario 名均与 delta spec 逐字一致；分节计数：animation 6/33、css 9/41、document-model 5/23、geometry 4/17、paint 3/12、raster 3/18、render 9/34、security 2/12、text 9/48、value-types 5/18。 |

## 2. C1–C13 回退检查

结论：**未发现回退**。C1–C13 的直接用例均包含在本次 1186 条全绿结果内；M1–M5 旧用例与 25 张快照未受影响。

| 编号 | 结论 | 证据（当前实现 / 直接用例） |
|---|---|---|
| C1 命中规格 API | 无回退 | `SvgHitTest.cj:203, 240` 静态入口；`SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` 通过，旧 `hitTest` 与 `elementsAt` 结果一致。 |
| C2 装饰长属性 | 无回退 | `SvgRenderer.cj:313-393` 与 `SvgTextDecoration2.cj` 的 style/color/thickness/underline-position 接线保留；`SvgDecorationM6_test` 9 条通过（含新增 `wavyStrokeWidth`）。 |
| C3 text-rendering 容差 | 无回退 | `SvgRenderer.cj:308, 489-493, 1255-1263`；`SvgTextToleranceM6_test.textToleranceFactors/textRenderingTolerance/textToleranceIndependentOfShapeRendering` 通过。 |
| C4 textPath pathLength | 无回退 | `SvgTextRenderer.cj:653-703` 仍以 `actual/pathLength` 同步缩放 advance 与绝对起点；`SvgTextPathLengthM6_test.textPathPathLengthCalibratesLayout` 通过。 |
| C5 渐变颜色空间 | 无回退 | `SvgRenderer.cj:1270+` 的 `svgGradientColorInterpolation` 保留；`SvgGradientColorSpaceM6_test` 3 条通过。 |
| C6 vector-effect 多值 | 无回退 | `SvgComputedStyle.cj:387`、`SvgVectorEffect2.cj:21-56`、`SvgRenderTree.cj:1887+` 固定顺序接线保留；`SvgVectorEffectMultiM6_test` 3 条通过。 |
| C7 auto 尺寸 | 无回退 | `SvgAutoSize.cj` 单轴 viewBox / 内容包围盒 / warning / 嵌套 auto 逻辑未改；`SvgAutoSizeM6_test` 5 条通过。 |
| C8 外部文档不递归 | 无回退（并由 N1 加强） | `SvgRenderTree.cj:877-948`；`SvgExternalDocumentM6_test.noRecursion/externalDocumentCannotChain/externalDocumentForcesRemovePolicy` 通过。 |
| C9 auto=visiblePainted | 无回退 | `SvgHitTest.cj:473-477` 的 `Auto` 可见性判定，`:442-470` 的 painted 分支保留；`SvgHitTestM6_test.autoEqualsVisiblePainted` 通过。 |
| C10 变更事件契约 | 无回退 | `SvgMutation.cj:21-39` 仅 `Attribute` / `ChildList`；`SvgDomApiM6_test.mutationListeners/childMutations` 通过。 |
| C11 监听器按引用移除 | 无回退 | `SvgMutation.cj:86-93` `refEq` 逻辑保留；`SvgDomApiM6_test.removeListenerByReference` 通过。 |
| C12 font-stretch 匹配 | 无回退 | `SvgFont.cj:149-211` 精确/最近匹配逻辑保留；`SvgFontStretchMatchM6_test.exactStretchMatchSkipsSynthesis/synthesisWhenOnlyNormalFace` 通过；W4 仅扩展非精确匹配分支。 |
| C13 字体特性开关 | 无回退 | `SvgFontVariant.cj:109-212` 与 `SvgTextRenderer.cj:1749-1851` 的 `kern` / `liga` / `hlig` / `clig` 门禁保留；`SvgFontFeatureApplyM6_test` 4 条通过。 |

## 3. 新发现

### 3.1 CRITICAL

无。

### 3.2 WARNING

1. **W-3-1（W4 口径）**：实现与测试使用 `请求值 / 实际命中面 stretch`（`SvgTextRenderer.cj:1956-1961`；`SvgFontStretchMatchM6_test.cj:97-102`），而 delta spec `svg-text` 第 221 行写的是 `百分比 / 100`，`design.md:141` 仍写“最终使用 100% 字体时”才合成。三者对“仅 75% 面 + 请求 80%”的预期不一致：当前实现为 `80/75`，spec 文本为 `80/100`。这不影响 W4 的验收用例（仅 100% 面场景），但属于规格/设计未同步。
2. **W-3-2（N1 data: 旁路）**：`SvgBuilder.cj:451-455` 在 `allowDataImages=true`（默认）时保留 `href="data:..."`；`svgExternalParseOptions` 仍复制 `allowDataImages`（`SvgRenderTree.cj:1873`），而 `expandUse` 把任何非 `#` href 当外部文档（`:964-985`）。因此外部文档内的 `<use href="data:...">` 仍会再次调用 provider；若 provider 能解析 data URI，可递归至 `SVG_EXTERNAL_MAX_DEPTH` 后抛 `Limit`。N1 用例只覆盖 `https://...`，未覆盖该旁路。建议外部文档强制 `allowDataImages=false`，或在 `expandUse` 中拒绝 data URI。该项需要调用方 provider 配合解析 data URI，未构成默认路径网络访问，故列为 WARNING。
3. **W-3-3（N1 strict 非 href 边界）**：N1 只给 `href` 开了 `externalDocumentMode` 的 strict 旁路（`SvgBuilder.cj:459`）；外部文档中的 `<style>@import url(...)`（`:175-189`）与 `url(...)` 属性（`:372-390`）在 `strict=true` 时仍抛 `Security`。这与 delta `svg-security` “外部文档内部不安全内容一律按 Remove 处理”的字面表述不完全一致；`verification.md` §3 已把它记录为“其余 strict 检查沿用主文档”的设计边界。
4. **W-3-4（CHANGELOG 计数）**：`CHANGELOG:17` 仍写“1178 条用例全绿”，而当前实测为 1186 条；第三轮新增 8 条用例后未同步该数字。
5. **W-3-5（文档一致性，低优先级）**：`verification.md` 第一轮 W5 写“9.5 因环境无 openspec CLI 保持未勾选”，但 `tasks.md:119` 已勾选 9.5 并声称 strict 校验通过；当前环境确实无 `openspec` 命令。两者至少有一处表述已过期，归档前应统一。

## 4. 快照逐字节复核

- 17 张 M1–M4 快照的 SHA-256 与 `f_svg/doc/perf-baseline.md` 全部一致（本次逐项 `sha256sum` 比对）。
- 8 张 M5 快照（`m5-bidi` / `m5-blend` / `m5-drop-shadow` / `m5-element-api` / `m5-media` / `m5-selector` / `m5-shaping` / `m5-transform-origin`）由 `SvgSnapshotM6_test.m5SnapshotsExact` 逐字节比对通过。
- `git diff --name-status f3aa5dec..HEAD -- f_svg/testdata/render` 仅出现 9 组 `m6-*` 的 `A`，没有 M1–M5 的 `M/A/D`；第三轮 `4e51fa29..HEAD` 的 `testdata/render` 变更为空。
- 说明：`m5-shaping.rgba` 在 M5 校验阶段（`f72f24c1`）曾重新生成过，该提交早于 M6 基线 `f3aa5dec`；因此“25 张不变”的基线应取 `f3aa5dec`，本次核对的正是该基线。

## 5. 覆盖矩阵与规格计数

- delta spec：`svg-animation` 6/33、`svg-css` 9/41、`svg-document-model` 5/23、`svg-geometry` 4/17、`svg-paint-and-clip` 3/12、`svg-rasterization` 3/18、`svg-render-pipeline` 9/34、`svg-security` 2/12、`svg-text` 9/48、`svg-value-types` 5/18，合计 **55 / 256**。
- `verification.md` 第 1 节矩阵：按 Scenario 逐行抽取后与 delta spec 比对，10 个能力全部无缺失、无多余；Requirement 名也全部匹配。
- delta 的 `MODIFIED` Requirement 均存在于 `openspec/specs/svg-*` 主规格；`ADDED` Requirement 均为 M6 新增，未发现修改目标缺失的归档阻塞项。
- `f_svg/doc/spec/add-f-svg-m6/specs` 与 `openspec/changes/add-f-svg-m6/specs` 逐文件一致（`diff -rq` 无差异），两处计数均为 55/256。
- 主规格中与 M6 冲突的三处旧表述（vector-effect 顺序、visible 语义、外部文档不递归）已由 delta 的 MODIFIED 段落覆盖；未发现新的主规格冲突。

## 6. 结论

- **N1 的指定验收路径已清除**：`Reject` / `Remove` / `Keep` + `strict=true` 下外部 https 引用不再二次调用 provider、不再抛 `Security` / `Limit`。
- **W1–W10 全部落地**；W4 的实现口径与 spec 文本存在同步差异（W-3-1），W6 的静态方法偏差已记录。
- **C1–C13 未发现回退**；`cjpm test` 1186 全绿，`cjpm build` 成功。
- **25 张 M1–M5 快照 25/25 逐字节一致**；矩阵 **55 Requirement / 256 Scenario** 与规格逐字一致。
- **CRITICAL = 0**。WARNING 5 项（W-3-1 至 W-3-5），其中 W-3-1、W-3-2 建议在归档前处理或明确接受。
