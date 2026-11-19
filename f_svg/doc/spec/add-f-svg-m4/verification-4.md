# add-f-svg-m4 第四轮归档前只读终验报告

终验时间：2026-11-06
终验范围：`f_svg/doc/spec/add-f-svg-m4/verification.md` 第 9 节、`fix-plan-3.md`、`f_svg/src`、全部相关 `*_test.cj`、`f_svg/testdata/render/*.rgba`、`openspec/changes/add-f-svg-m4/specs/*`。
约束：未修改任何源码、规格或测试，未归档，未执行任何 git 写操作；本报告是本次唯一新增文件。

## 0. 结论摘要

| 项目 | 结论 |
|---|---|
| N2（bounds / clipBounds 拆分） | **已清除** |
| N3（layout 缓存不跨渲染且次数受控） | **已清除** |
| N5（嵌套 marker 回退裁剪） | **已清除** |
| N6（`load` 为唯一文件入口） | **已清除（可执行探针证明）** |
| C1–C5、C5-2、NEW-C1 | **无回退** |
| M1–M3 快照 | **13/13 逐字节一致** |
| `cjpm test` | **710 / 710 通过，0 失败** |
| `cjpm build` | **成功；`f_svg/src` 0 warning**（22 条 warning 均来自依赖 `f_base` / `f_xml`） |
| 新 CRITICAL | **0** |
| 新 WARNING | **0** |

**CRITICAL=0**

## 1. 核验方式与限制

1. 静态审阅 `verification.md` 第 9 节、`fix-plan-3.md`、N2–N6 相关实现与测试，并对照第一、二轮已修复项检查是否回退。
2. 实跑 `cjpm test` 与 `cjpm build`；测试输出保存后逐项核对用例名与计数。
3. git 仅做只读查询（`git status`、`git log`、`git diff`、`git rev-parse`、`git hash-object`），未执行 commit / merge / checkout / reset 等写操作。
4. 未修改代码，未归档，未合并分支；本报告只记录结论。
5. 本机仍无 `openspec` CLI，未执行 `openspec validate --strict`；本次计数为人工核对。

## 2. N2：bounds / clipBounds 拆分不影响文本渐变——已清除

实现证据：

- `f_svg/src/SvgRenderTree.cj:63-66`：`SvgDisplayCommand` 同时持有 `bounds`（绘制用，文本不含装饰线）与 `clipBounds`（裁剪 / 滤镜用，文本含装饰线）。
- `f_svg/src/SvgRenderTree.cj:111-114`：未显式传 `clipBounds` 时回退到 `bounds`，非文本指令行为不变。
- `f_svg/src/SvgGeometry.cj:101-119`：`renderBounds` 只返回 `layout(...).bounds`，不再并入 `decorationOutline`；注释明确“渐变仍按字形布局范围取样”。
- `f_svg/src/SvgGeometry.cj:126-171`：`renderClipBounds` 在布局包围盒上并入装饰线路径包围盒，仅用于裁剪 / 滤镜。
- `f_svg/src/SvgRenderTree.cj:407-422`：文本命令分别计算 `bounds` 与 `clipBounds`；`:437` 的滤镜组使用 `clipBounds`；`:442-450` 命令同时填充两个字段。
- `f_svg/src/SvgRenderer.cj:213`：滤镜区域使用 `command.clipBounds`；`:228` 的 `applyEffects`（clip / clip-path / mask / quad）使用 `clipBounds`；`:644` 的裁剪快路径判断使用 `clipBounds`。
- `f_svg/src/SvgRenderer.cj:284`、`:288`：文本字形填充 / 描边使用 `command.bounds`；`:305` 装饰线渐变使用各 `run.bounds`，不会被装饰线扩大整段文本的渐变基准。

测试证据：

- `f_svg/src/SvgTextDecorationM4_test.cj:146-186` `decorationKeepsTextFillBounds`：带 / 不带 `text-decoration` 的 Text 命令 `bounds` 完全相等，且同一像素颜色逐字节相等。
- NEW-W1 的紧视口下划线裁剪用例继续通过，说明拆分没有破坏“装饰线必须参与裁剪”。

判定：绘制与裁剪 / 滤镜的取值范围已正确分离，N2 的核心回归（渐变几何被装饰线改变）已消除。

## 3. N3：layout 缓存不跨渲染且次数受控——已清除

实现证据：

- `f_svg/src/SvgTextRenderer.cj:71-97`：新增 `SvgCachedTextLayout` 与 `SvgTextLayoutCache`，缓存键含元素身份 + 计算样式树版本 + 根元素身份。
- `f_svg/src/SvgTextRenderer.cj:227-263`：`layout` 命中缓存时直接复用 layout，并重放该 layout 产生的 warning；未命中才走 `layoutUncached`。
- `f_svg/src/SvgComputedStyle.cj:332`：`SvgComputedStyleTree` 使用单调递增的内部 `version`，区分不同样式上下文。
- `f_svg/src/SvgRenderTree.cj:208`：缓存由 `SvgRenderTreeBuilder` 创建；`:139`、`:149`、`:158` 由 `SvgDisplayList` 持有并传递给光栅化；`SvgRenderer.cj:269` 的 `outline` 与装饰线计算共用同一缓存。
- `f_svg/src/SvgRenderer.cj:87`、`:97`：每次 `render` / `renderElement` 都新建 builder，因此缓存不跨顶层渲染。
- `f_svg/src/SvgTextRenderer.cj:569-583`：`hasDecoration` 复用布局缓存，不额外排版。

测试证据（`f_svg/src/SvgTextLayoutCacheM4_test.cj:57-121`）：

- `singleTextRendersWithOneLayout`：单文本整次渲染 `advance` 恰好 1 次；带装饰线文本同样为 1 次。
- `decoratedTextLayoutCountStaysBounded`：带装饰线的布局调用次数不超过不带装饰线的 1.5 倍。
- `layoutCacheDoesNotOutliveRender`：第二次渲染重新布局（`advance` 仍为 1 次），证明缓存未跨渲染复用。

判定：原先单文本约 4 次布局已收敛为 1 次；缓存生命周期绑定单次显示列表构建 / 渲染，N3 已清除。

## 4. N5：嵌套 marker 回退裁剪——已清除

实现证据：

- `f_svg/src/SvgRenderTree.cj:1095-1104`：`markerContentFitsIn` 对子元素的 `filter` / `clip-path` / `mask` / `clip` / `marker-start` / `marker-mid` / `marker-end` 任何有效声明直接返回 `false`（需要裁剪）。
- `f_svg/src/SvgRenderTree.cj:1131-1140`：容器子树递归检查；`SvgShape` 的描边、文本、未知元素仍回退为需要裁剪。
- `f_svg/src/SvgRenderTree.cj:845-860`：marker 调用方先由 `markerViewBoxMatrix` 得到 `contentTransform`，再用 `contentTransform.apply(refX, refY)` 计算视口平移，与 NEW-C1 的坐标系修复保持配套。

测试证据：

- `f_svg/src/SvgOverflowM4_test.cj:285-301` `nestedMarkerContentStillClips`：外层 marker 视口 10×10，子路径 `marker-end` 指向 20×20 内层 marker；内层实例在视口外的 (15,8) 被裁掉、视口内的 (9,8) 保留。
- NEW-C1 的 `markerViewBoxScalingClips`、`markerStyledStrokeClips`、`markerStyledFilterClips`、`markerViewBoxReferenceClips`、`markerContentFitsSkipsMask` 全部通过。

判定：子元素自身 `marker-*` 不再被快路径忽略，N5 已清除。

## 5. N6：`load` 为唯一文件入口——已清除（可执行证明）

实现证据：

- `f_svg/src/SvgTrueTypeFont.cj:29-45`：内部 `SvgFontFileAccess` 是唯一读取探针；`read` 内调用 `File.readFrom`，`count` / `reset` 使用 `@When[test]` 限定测试构建。
- `f_svg/src/SvgTrueTypeFont.cj:242-249`：`SvgTrueTypeFont.load(path)` 只通过 `SvgFontFileAccess.read(path)` 读取，并把 `FSException` 转为 `SvgException(kind: Syntax)`。
- 全量静态检索 `readFrom`：库内仅 `SvgTrueTypeFont.cj:34` 一处；`SvgBitmap.cj:175` 是 PNG 写文件，不是读取入口。
- `f_svg/README.md:335-336`、`f_svg/README_en.md:335`、`f_svg/doc/f_svg-M4设计.md:189` 已明确 `load(path)` 是库内唯一的字体文件入口，`parse(bytes)` 与渲染链不访问文件系统。

测试证据：

- `f_svg/src/SvgSecurity_test.cj:224-242` `fontFileAccessConfinedToExplicitLoad`：
  - 内存 `parse(bytes)` 成功；
  - 渲染 `font-family="file:///etc/fonts/not-a-font.ttf"` 的文档后探针 `count() == 0`；
  - 显式 `load` 不存在路径时 `count() == 1` 且抛 `Syntax`。
- 既有 `renderDoesNotLoadFontFiles` 继续通过。

判定：N6 从“静态推断”升级为“探针计数可执行证明”，已清除。

## 6. C1–C5、C5-2、NEW-C1 无回退

| 编号 | 复核点 | 结果与证据 |
|---|---|---|
| C1 | M3 逐字节基线 | `SvgScene_test.cj:147-228` 的 11 个 `*Exact` 用例覆盖 13 个快照；`exactMismatchDetected` 仍验证单字节篡改会失败；全部通过 |
| C2 | `screenCTM` 顺序 | `SvgGeometry.cj:225-229` 仍为 `scale(dpr) × viewport.matrix × ctm(element)`；`SvgGeometryApiM4_test.cj:150`、`:177` 的 transform + meet + DPR 用例通过 |
| C3 | TTF 恶意输入 | `SvgTrueTypeFont.cj:377-381` 严格递增校验；`:667-668` 轮廓端点局部校验；`SvgTrueTypeTables.cj:134-145` 表 tag 可打印 ASCII 校验；`locaTruncatedInMiddle`、`cmapSubtableLength`、`locaNonMonotonic`、`tableLimits` 等通过 |
| C4 | `SvgVectorEffect` API | `SvgVectorEffect.cj:26-52` 仍为 `NoEffect` / `NonScalingStroke`；`openspec/changes/.../svg-value-types/spec.md:50` 已统一为 `NoEffect`，两处副本一致 |
| C5 / C5-2 | `feMorphology` 半径与预算 | `SvgFilterPrimitives2.cj:22-24` 上限 16 + 64 Mi 采样预算；`:933-951` 两道检查均在像素循环前；`openspec/changes/.../svg-security/spec.md:11-12,32-35` 已同步；`morphologyFixedRadiusLimit`、`morphologyComplexityLimit`、`morphologySmallRadiusAllowed` 通过 |
| NEW-C1 | marker 内容快路径 | `SvgRenderTree.cj:845-860` 的 `contentTransform` / `ref` 平移、`:1078-1146` 的样式与描边回退均保留；5 个 marker 用例通过 |

补充：`openspec/changes/add-f-svg-m4/specs/*` 人工统计为 43 Requirement / 145 Scenario，`svg-security` 12 条，与 `verification.md` 第 9 节一致；`svg-text` 的渐变描述为“按字形包围盒取样”，两份 delta 副本一致。

## 7. M1–M3 快照逐字节一致

- 13 个快照：`basic`、`gradient`、`stroke`、`clip`、`text`、`animation-0`、`animation-05`、`animation-1`、`m3-filter`、`m3-pattern`、`m3-image`、`m3-textpath`、`m3-marker`。
- `git diff --quiet a39db449 -- <13 files>` 退出码 0，无差异；逐文件对比 `git rev-parse a39db449:<path>` 与工作区 `git hash-object`，13/13 blob 哈希完全相同。
- `SvgSceneByteBaseline_test` 的 11 个 `*Exact` 用例（`animationExact` 覆盖 3 帧，共 13 个快照）与 `exactMismatchDetected` 本次全部 `[ PASSED ]`。
- 工作区 `git status --porcelain` 为空，未出现快照被重新生成或顺带修改。

## 8. 测试与构建

- `cjpm test`：`TOTAL: 710 / PASSED: 710 / FAILED: 0`，约 11.7 s；N2/N3/N5/N6 新增用例与全部既有用例均通过。
- `cjpm build`（clean 后）：成功；`22 warnings generated` 全部位于 `f_base/src` 与 `f_xml/src`，`f_svg/src` 无 warning。
- `cjpm test` 编译阶段另有既有测试文件（如 `SvgBitmap_test.cj`、`SvgGeometry_test.cj` 等）的 warning，均非本轮 N2–N6 新增文件，也不是库构建 warning；不影响“`f_svg/src` 0 warning”的验收口径。

## 9. 新发现

### CRITICAL

无。

### WARNING

无。

N2–N6 的实现改动未引入新的功能、安全、性能或兼容性缺陷；本轮新增测试均能稳定通过。以下两项为**非本轮新增、不计入新 WARNING** 的既有文档观察，供归档时顺手核对：

1. `openspec/changes/add-f-svg-m4/tasks.md:144` 的 18.5 仍写“691 条用例全绿”，实际为 710 条；该数字在本轮之前已存在，不影响 N2–N6 结论，但归档前建议更新。
2. 任务 18.6 声明 `openspec validate --strict`“通过”，本机仍无 `openspec` CLI；本轮未重复执行 CLI 校验，仅做人工结构核对。

## 10. 终验限制

1. 本报告为只读确认；未修改代码、未归档、未合并/删除分支。
2. 未使用 git 写操作；只读 git 命令均通过显式 `GIT_DIR` / `GIT_WORK_TREE` 指向当前 worktree。
3. 未执行 `openspec validate --strict`（本机无 CLI）。
4. 未做堆 profiler；性能结论仅依据现有基准与静态审阅。

**CRITICAL=0**
