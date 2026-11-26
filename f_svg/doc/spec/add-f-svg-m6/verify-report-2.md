# add-f-svg-m6 第二轮修复复验报告

- 复验对象：`feature/f_svg`（HEAD `07a97769`），第二轮修复范围 `5e726c5d..HEAD`。
- 复验方式：只读审阅 + 全量测试 + 构建 + 规格计数 + git 快照/用例差异核对；未改代码、未归档、未执行 git 写操作。
- 只读命令均使用 worktree 专属 `GIT_DIR`（`.git/worktrees/f_svg`），避免误读主工作树。

## 0. 门禁与基线

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | `TOTAL: 1178 / PASSED: 1178 / SKIPPED: 0 / ERROR: 0 / FAILED: 0` | `f_svg/cjpm test` |
| 构建 | `cjpm build success`；22 条 warning 全部来自 `f_base` / `f_xml`，`f_svg` 自身 0 warning | `f_svg/cjpm build` |
| delta 规模 | **55 Requirement / 256 Scenario** | 10 个 `specs/*/spec.md` 标题计数（6+9+5+4+3+3+9+2+9+5；33+41+23+17+12+18+34+12+48+18） |
| M1–M5 快照 | **25/25 未被修改** | `git diff --name-status f3aa5dec..HEAD -- f_svg/testdata/render` 仅出现 `A m6-*`，无任何 M1–M5 `.rgba` 变更 |
| 第二轮 M6 快照变更 | 仅 3 张 `.rgba` 重生成，另修改 2 个 `m6-*` 场景 `.svg` | `git diff --name-status 5e726c5d..HEAD -- f_svg/testdata/render` |
| 17 张 M1–M4 哈希 | 与 `doc/perf-baseline.md` 的 SHA-256 全部一致 | `sha256sum` 逐项比对 |

## 1. C1–C13 逐条结论

| 编号 | 结论 | 证据与说明 |
|---|---|---|
| C1 命中规格 API | **已清除** | `SvgHitTest.cj:202-261` 提供 `elementsAt` / `elementAt`；`hitTest` 与二者共用 `svgHitCollect`；`SvgHitTestM6_test.elementsAtSpecApi` 覆盖顺序、`None`、空列表与旧 API 一致性。遗留：实现为实例方法，fix-plan 写的是 `public static func`，按 `SvgHitTest.elementsAt(...)` 直接调用无法编译（见新 W-6）。 |
| C2 装饰长属性 | **已清除** | `SvgTextDecoration2.cj:159-374` 逐属性解析并与 `SvgRenderer.cj:313-360` 接线；`SvgDecorationM6_test` 8 条覆盖 dashed/3 单位、double、独立颜色、子级 none、简写颜色、wavy 包围盒、百分比厚度、下划线位置。遗留：wavy 以开放折线进入 FillPath（见新 W-3）。 |
| C3 text-rendering 容差 | **已清除** | `SvgRenderer.cj:1210-1217` 映射 2 / 1 / 0.5 / 0.25，`SvgRenderer.cj:457-460` 传入光栅器；`SvgTextToleranceM6_test` 覆盖四档与 optimizeSpeed 关闭连字。遗留：文本容差还乘以 `shape-rendering` 的倍率（见新 W-2）。 |
| C4 textPath pathLength | **已清除** | `SvgTextRenderer.cj:644-694` 以 `actual/pathLength` 同时缩放 advance 与绝对 `startOffset`；百分比起点仍按实际弧长。`SvgTextPathLengthM6_test.textPathPathLengthCalibratesLayout` 断言首字形位置与截断。 |
| C5 渐变颜色空间 | **已清除** | `SvgRenderer.cj:1227-1273` 优先读取渐变元素计算样式，`auto` 回退使用元素；`svgWarnColorProfile` 对非 sRGB warning。`SvgGradientColorSpaceM6_test` 3 条 + 像素中点差异。 |
| C6 vector-effect 多值 | **已清除** | `SvgComputedStyle.cj:378-400` 多值解析，`SvgStyleResolver.cj:666-681` 未知值 warning，`SvgVectorEffect2.cj:27-56` 固定顺序，`SvgRenderTree.cj:1865-1881` 全数组接线；delta 规格与 design D16 已统一为固定顺序。 |
| C7 auto 尺寸 | **已清除** | `SvgAutoSize.cj:33-129` 单轴按 viewBox 比例、无 viewBox 取内容包围盒、无法确定 warning、嵌套 auto 由 `SvgViewport.nestedViewport` 取父视口；`SvgAutoSizeM6_test` 5 条。 |
| C8 外部文档不递归 | **仍存在（CRITICAL）** | 默认 `unsafePolicy=Remove` 下测试通过；但 `svgExternalParseOptions`（`SvgRenderTree.cj:1849-1861`）原样复制 `unsafePolicy`。若主文档使用 `Reject`，外部文档内的外部 `href` 在解析期抛 `Security` 而非 warning；若使用 `Keep`，href 被保留，`resolveExternalUse`（`:871-936`）在 `externalDepth=1` 时仍会再次调用 provider，直到深度 4 才抛 `Limit`。两种情况都违反 `svg-security` / `svg-render-pipeline` 的“外部文档不再次触发外部加载、按缺失引用 warning”。`SvgExternalDocumentM6_test.noRecursion` 只覆盖默认 Remove。 |
| C9 auto=visiblePainted | **已清除** | `SvgHitTest.cj:475-500` 将 `Auto` 纳入 visibility 与 painted 判定；`SvgHitTestM6_test.autoEqualsVisiblePainted` 覆盖 hidden 默认与 bounding-box 不越过 visibility。 |
| C10 变更事件契约 | **已清除** | `SvgMutation.cj:21-39` 仅 `Attribute` / `ChildList`；插入/移除在 `SvgElement.cj:267,293,328` 均发 `ChildList`，`child` 区分目标。 |
| C11 按引用移除监听器 | **已清除** | `SvgMutation.cj:86-93` 使用 `refEq`；`SvgDomApiM6_test.removeListenerByReference` 验证移除 B 后 A 仍收到事件、移除未注册对象无副作用。 |
| C12 font-stretch 匹配 | **已清除** | `SvgFont.cj:144-211` 返回实际命中 stretch，`SvgTextRenderer.cj:1915-1934` 仅在命中 100% 时合成；`SvgFontStretchMatchM6_test` 覆盖精确 75% 与仅 100% 两例。遗留：请求 80%、仅注册 75% 面时命中 75% 且不再按 `80/100` 合成（见新 W-4）。 |
| C13 字体特性开关 | **已清除** | `SvgFontVariant.cj:182-212` 合并 variant-ligatures / feature-settings / font-kerning，`SvgTextRenderer.cj:1774-1845` 按 `liga` / `hlig` 选择 Type 4，`applyFontKerning` 读取 `kern` 开关；`SvgFontFeatureApplyM6_test` 3 条通过。遗留：`clig` 只进入开关集合，从未真正参与 Type 4 替换（见新 W-5）。 |

## 2. W1–W14 与 S1–S4 落地情况

| 编号 | 结论 | 证据与说明 |
|---|---|---|
| W1 根 pointer-events none | ✅ | `SvgHitTest.cj:286-292` 先检查根；`SvgHitTestM6_test.rootNonePrunes`。 |
| W2 命中安全上限 | ✅ | `SvgHitTest.cj:151-157` 读取 `document.parseOptions.security.maxElements`，显式参数优先；`securityMaxElements`。 |
| W3 text 轮廓缺失 | **部分未落地** | `SvgHitTest.cj:520-525` 已改为不命中 + warning；但 `all` 仍在 `:434-438` 直接走包围盒，`text` 也到不了 `:452-453` 的字形轮廓分支。规格要求“仅 bounding-box 用 bbox、text 用字形轮廓”，未完全满足。 |
| W4 嵌套 discard | ✅ | `SvgTimeline.cj:228-234` warning + continue；`nestedDiscardWarns`。 |
| W5 非法 attributeType | ✅ | `SvgTimeline.cj:516-521` 回退 XML + warning；`attributeTypeInvalid`。 |
| W6 min 断言 | ✅ | `SvgAnimationControlM6_test.minMax` 断言 min 延长期间保持末帧。 |
| W7 size-adjust 逐字体 | ✅ | `SvgTextRenderer.cj:1982-1999` 缺失 OS/2 时 `continue`；`sizeAdjustContinuesAfterMissingOs2`。 |
| W8 命名空间属性通知 | ✅ | `SvgElement.cj:175-223` 两条路径均发 `Attribute`；`namespacedAttributesNotify`。 |
| W9 visible 语义 | ✅ | design D2 `:65` 已改为“内区或描边几何，不要求 fill/stroke 非 none”。 |
| W10 CHANGELOG 计数 | ✅ | `CHANGELOG:17` 为 1178。 |
| W11 design 规模 | ✅ | `design.md:5` 为 288 源文件 / 163 测试文件；实测 `find f_svg/src -name '*.cj'`=288、`*_test.cj`=163。 |
| W12 规格冲突 | **部分未落地** | vector-effect 顺序已统一；但 `design.md:87` 仍写“深度计数器随嵌套 use 递增，超过 4 抛 Limit”，与“外部文档不递归加载、不抛 Limit”的已修正规格冲突。 |
| W13 覆盖矩阵/文件表/快照说明 | **部分未落地** | D18 文件清单、D19 快照语义已更新；但 `verification.md` 第 1 节场景矩阵仍是修正前口径：`svg-security` 仍列已删除的“外部文档深度”（13 行 vs 规格 12）、`svg-geometry` 缺“auto 等价 visiblePainted”（16 vs 17）、`svg-render-pipeline` 缺“外部文档不递归”（33 vs 34），表内合计 255 与文中 256 不一致。 |
| W14 特性 warning / foreignObject 上限 | ✅ | `SvgFontDetailsM6_test.featureWarningSurfacesInRenderer`、`SvgForeignObjectM6_test.pixelBudgetCheckedBeforeRenderer`（`renderer.calls == 0`）。 |
| S1 删除调试输出 | ✅ | `SvgAnimationControlM6_test.cj` 无 `println` / `print`。 |
| S2 公开枚举解析 | ✅ | `SvgPointerEvents`、`SvgShapeRendering`、`SvgTextRendering`、`SvgColorRendering`、`SvgColorInterpolation` 的 `fromName` 均为 public。 |
| S3 LineJoin 字符串口径 | ✅ | `SvgShape.cj:81-86` `toString()` 统一转调 `attrName()`。 |
| S4 删除装饰死代码 | ✅ | 仓库中已无 `SvgTextDecorationSpec.outline`；`decorationGeometry` 测共享分段函数。 |

## 3. 新发现

### 3.1 CRITICAL

1. **CR-2-01 外部文档不递归只在默认 `unsafePolicy=Remove` 下成立**（同时使 C8 仍存在）。
   - `svgExternalParseOptions`（`SvgRenderTree.cj:1849-1861`）复制主文档的 `unsafePolicy`，但只把 `allowExternalReferences` 置 false。
   - `SvgBuilder.handleHrefValue`（`SvgBuilder.cj:445-463`）在 `Reject` 时直接抛 `Security`；在 `Keep` 时保留外部 href，`resolveExternalUse`（`SvgRenderTree.cj:871-936`）会用 `externalDepth=1` 再次调用 provider，直到 `SVG_EXTERNAL_MAX_DEPTH=4` 抛 `Limit`。
   - 影响：`SvgParseOptions(strict: true)` 或 `unsafePolicy: Reject/Keep` 的用户在外部文档含外部引用时得到异常或二次外部加载，而非规格要求的“跳过并 warning、provider 只调用一次、不联网”。
   - 现有 `noRecursion` / `externalDocumentCannotChain` 只覆盖默认 Remove，未覆盖上述分支。

### 3.2 WARNING

1. **W-1 `pointer-events: all` 仍按包围盒命中**（W3 残留）。`SvgHitTest.cj:434-438` 对所有非容器元素先判 `All → svgHitBBoxContains`，`text` 永远到不了 `:452-453` 的字形轮廓分支。圆角、斜边、文本空白区会被误命中；规格要求“其余使用路径 / 描边区域，`text` 使用字形轮廓”。
2. **W-2 文本容差被 `shape-rendering` 二次缩放**。`SvgRenderer.cj:457-460` 用 `textTolerance * svgShapeTolerance(style)`；当 `shape-rendering="geometricPrecision"` 时，`text-rendering="optimizeSpeed"` 实际为 0.5 而非 2。`text-rendering` 的映射不再由自身取值唯一确定，违反 `svg-rasterization` 的“映射由属性取值唯一确定”。
3. **W-3 wavy 装饰线以开放折线进入填充管线**。`SvgTextDecoration2.cj:199-215` 只生成 `MoveTo/LineTo`，`SvgRenderer.cj:326-360` 以 `FillPath` 绘制。开放正弦折线被隐式闭合后形成双叶填充带，不是等厚波浪线；`SvgDecorationM6_test.wavyLine` 只断言包围盒高度，未做像素断言。
4. **W-4 font-stretch 非精确匹配时不按百分比合成**。`SvgFont.cj:183-195` 会选中最近的非 100% 面（如 75%），`SvgTextRenderer.cj:1925-1927` 因 `matchedStretch != 100` 直接跳过合成；而 delta 规格写“声明为百分比且无精确匹配时 SHALL 应用百分比 / 100 的水平缩放”。当前用例只覆盖“精确 75%”和“仅 100%”，未覆盖“仅 75% + 请求 80%”。
5. **W-5 `clig` 从未参与 Type 4 替换**。`SvgFontVariant.cj:186-211` 会设置 `clig` 开关，但 `SvgTextRenderer.cj:1784-1845` 只读取 `liga` / `hlig`，`SvgTrueTypeFont` 也只解析 `liga` / `hlig` 表。`font-variant-ligatures: none` 对 `clig` 的关闭不可观测，默认开启 `clig` 也未实现。
6. **W-6 规格命中 API 形态与修复计划不一致**。`SvgHitTest.cj:202,239` 为实例方法；fix-plan 要求 `public static func`，规格以 `SvgHitTest.elementsAt(...)` 书写。按规格直接静态调用无法编译，现有用例全部使用 `SvgHitTest().elementsAt(...)`。
7. **W-7 provider 失败结果未缓存**。`SvgRenderTree.cj:889-908` 仅在解析成功时写入 `externalDocuments`；同一 `href` 返回 `None` 时，每次 `use` 都会再次调用 provider，与“同一 href 一次渲染内只调用一次”的字面要求不符。成功路径由 `providerCalledOnce` 覆盖，失败路径未覆盖。
8. **W-8 旧 M1–M5 用例存在非纯新增改动**。`git diff --name-status f3aa5dec..HEAD -- f_svg/src` 显示：
   - `CssStyleSheet_test.cj`、`CssSelectorCascadeM5_test.cj`、`CssSelectorStructuralM5_test.cj` 把“不支持伪类”的样本从 `:hover` 改为 `:active`（M6 新增 hover 支持，属语义适配，但确实改了旧断言期望）；
   - `SvgKerningLayoutM5_test.cj` 的 `m5BuildLayoutTtf` 增加可选 `cmap` / `os2` 参数（纯扩展，既有用例行为不变）；
   - `SvgRenderTree_test.cj` 纯新增 use 深度用例。
   因此“旧 M1–M5 用例未改”不是字面成立；未发现旧断言被削弱以掩盖回归。

## 4. 回归与快照复核

### 4.1 M1–M5 25 张快照

- `git diff --name-status f3aa5dec..HEAD -- f_svg/testdata/render` 只包含 9 组 M6 新增文件，未出现任何 M1–M5 `.rgba` 的 `M/A/D`。
- 17 张 M1–M4 的 SHA-256 与 `f_svg/doc/perf-baseline.md` 全部一致。
- 8 张 M5 快照由 `SvgSnapshotM6_test.m5SnapshotsExact` 逐字节比对通过，且 git 无变更记录。
- 结论：**25/25 逐字节一致**。

### 4.2 3 张重生成的 M6 快照语义

| 快照 | 语义核验 | 结论 |
|---|---|---|
| `m6-color-interpolation` | 上带中点像素 `(125,0,130)`，下带中点 `(186,0,189)`，两带不同；符合 `sRGB` vs `linearRGB` | 有效 |
| `m6-hit-queries` | `(18,18)=#ffcc00`（`hit` 被命中后 hover 变色），`(42,18)=#0066cc`（`skip` 的 `pointer-events:none` 未命中），驱动链为 `SvgHitTest.elementsAt → hoveredIds → rect:hover` | 有效 |
| `m6-svg2` | 绿色矩形在 x≈6..22、y≈6..14 结束，证明祖先 `scale(2)` 被 `non-scaling-size` 抵消；`renderTreeWiring` 另断言声明顺序无关且不同于 `none` | 有效 |

### 4.3 旧用例

- M1–M5 快照测试、M1–M5 像素/几何断言全部通过。
- 旧测试文件的 5 处变更见 W-8；其中 3 处为 `:hover`→`:active` 的期望适配，未发现通过修改旧断言掩盖默认路径回归。

## 5. 结论

- C1–C7、C9–C13 的核心修复均已落地并有直接用例；C8 在非默认安全策略下仍存在，不能判定为“真正清除”。
- W1、W2、W4–W11、W14 与 S1–S4 已落地；W3、W12、W13 为部分落地。
- 25 张 M1–M5 快照逐字节一致；3 张重生成的 M6 快照语义有效；旧 M1–M5 用例存在 3 处期望适配 + 2 处扩展/新增，详见 W-8。
- **CRITICAL = 1**（CR-2-01，外部文档不递归/安全策略分支）。
