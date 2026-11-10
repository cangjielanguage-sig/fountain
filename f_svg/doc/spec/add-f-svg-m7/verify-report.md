# add-f-svg-m7 校验报告

> 校验对象：`openspec/changes/add-f-svg-m7` 的 proposal / design / specs / tasks，以及 `f_svg/doc/f_svg-M7设计.md`、`f_svg/src` 下全部实现与 `*_test.cj`。
>
> 校验方式：只读代码与规格；执行 `cjpm test`、`cjpm build`（含独立 target 目录的全新构建）、`openspec validate --strict`、`git diff` / `git status`。**未修改任何源码、未归档、未生成 plan。**
>
> 分支：`feature/f_svg`；工作区：`git status --short` 为空。

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| Completeness | 11 / 11 Requirement、31 / 31 Scenario 均有实现与测试落点；新增 38 条用例 |
| Correctness | 1225 / 1225 用例通过（既有 1187 + 新增 38）；无阻断性功能缺陷 |
| Coherence | `f_svg/src` 仅 11 个新增文件（7 实现 + 4 测试）；`SvgTag` / `SvgTimeline` / `SvgParser` / `SvgWriter` 零改动 |
| 构建 | `cjpm build` 成功；`f_svg/src` 0 warning；22 条 warning 全部来自依赖 `f_base` / `f_xml` |
| OpenSpec | `openspec validate add-f-svg-m7 --strict` → `Change 'add-f-svg-m7' is valid` |
| **CRITICAL** | **0** |
| WARNING | 5 |
| SUGGESTION | 9 |

总体判断：**实现完整、可运行、无回归、无临界缺陷**。存在的 5 项 WARNING 均为覆盖强度、浏览器兼容性或 API/状态一致性风险，不阻塞验收；9 项 SUGGESTION 为规格措辞、测试补强与文档一致性问题。

---

## 1. 校验证据

### 1.1 命令与结果

| 命令 | 结果 |
|---|---|
| `cd f_svg && cjpm test` | `TOTAL: 1225`、`PASSED: 1225`、`SKIPPED: 0`、`ERROR: 0`、`FAILED: 0` |
| `cd f_svg && cjpm build` | `cjpm build success` |
| `cjpm build --target-dir /tmp/f_svg_m7_build2` | 全新构建成功；22 条 warning，warning 文件只出现在 `f_base/src` 与 `f_xml/src`，`f_svg/src` 为 0 |
| `npx @fission-ai/openspec@1.16.1 validate add-f-svg-m7 --strict` | `Change 'add-f-svg-m7' is valid` |
| `git diff --name-status 48dd131e..HEAD -- f_svg/src` | 11 个文件全部为 `A`（新增），无 `M` / `D` |
| `git diff --name-only 48dd131e..HEAD -- f_svg/src/SvgTag.cj f_svg/src/SvgTimeline.cj f_svg/src/SvgParser.cj f_svg/src/SvgWriter.cj` | 空输出 |

### 1.2 测试计数

- 当前 `@TestCase` 总数：1225。
- M7 新增：`SvgBuilderM7_test` 18 条、`SvgAnimateM7_test` 9 条、`SvgBeginM7_test` 6 条、`SvgAuthoringTypesM7_test` 5 条，共 38 条。
- 推导既有基线：1225 − 38 = 1187；且 `f_svg/src` 下既有测试文件在 M6 归档提交 `48dd131e` 之后无任何修改，因此「1187 条零改动、零回归」成立。
- 当前 `@Test` 类总数 213，与 `verification.md` 的 209 → 213 记录一致。

### 1.3 新增文件清单

实现 7 个：

- `SvgAuthoringBuilder.cj`（作者侧 `SvgBuilder`）
- `SvgAnimate.cj`
- `SvgAnimateTransform.cj`
- `SvgAnimateMotion.cj`
- `SvgSet.cj`
- `SvgBegin.cj`
- `SvgAuthoringTypes.cj`

测试 4 个：

- `SvgBuilderM7_test.cj`
- `SvgAnimateM7_test.cj`
- `SvgBeginM7_test.cj`
- `SvgAuthoringTypesM7_test.cj`

---

## 2. Completeness：11 Requirement / 31 Scenario 落点

### 2.1 Requirement 与 Scenario 逐条映射

| # | Requirement | Scenario | 测试落点 | 判定 |
|---|---|---|---|---|
| 1 | 链式构建器的根与游标 | 根尺寸与 viewBox | `SvgBuilderM7_test.rootSizeAndViewBox` | 已覆盖 |
| 1 |  | 分组嵌套与回退 | `SvgBuilderM7_test.groupScenarioWithShapes`、`groupNestingAndEnd` | 已覆盖 |
| 1 |  | 根级 `end` 无副作用 | `SvgBuilderM7_test.endAtRootIsNoop` | 已覆盖（用的是 `group`，见 S-2） |
| 2 | 形状、文本与引用元素写入 | 几何属性序列化 | `SvgBuilderM7_test.shapeGeometry` | 已覆盖 |
| 2 |  | 文本内容转义 | `SvgBuilderM7_test.textUseAndImage` | 已覆盖 |
| 2 |  | 引用元素 | `SvgBuilderM7_test.textUseAndImage` | 已覆盖 |
| 3 | 样式与通用属性作用于当前元素 | 样式落在当前形状 | `SvgBuilderM7_test.styleMethods` | 已覆盖 |
| 3 |  | 分组样式 | `SvgBuilderM7_test.styleTargetsCurrentElementOnly` | 已覆盖 |
| 3 |  | 不生成 `style` 元素 | `SvgBuilderM7_test.stylesNeverCreateStyleElement` | 已覆盖 |
| 4 | 类型化动画元素的属性映射 | animate 属性映射 | `SvgAnimateM7_test.attributeMapping` | 已覆盖 |
| 4 |  | animateTransform 追加类型 | `SvgAnimateM7_test.animateTransformTypeMapping` | 已覆盖 |
| 4 |  | animateMotion 与 mpath | `SvgAnimateM7_test.animateMotionAttributes`、`animateMotionMpath`、`SvgBuilderM7_test.animateMotionMpathConvenience` | 已覆盖 |
| 4 |  | set 元素 | `SvgAnimateM7_test.setElementAttributes` | 已覆盖 |
| 5 | 动画元素不进入解析注册表 | 解析生成结果保持结构 | `SvgAnimateM7_test.generatedAnimationSurvivesParse` | 已覆盖 |
| 5 |  | 注册表不变 | `SvgAnimateM7_test.animationTagsStayUnknown` | 已覆盖 |
| 6 | SvgBegin 表达式工厂 | 偏移与时钟 | `SvgBeginM7_test.offsetSeconds`、`clockValue` | 已覆盖 |
| 6 |  | id 引用 | `SvgBeginM7_test.atReference` | 已覆盖 |
| 6 |  | 重复与事件 | `SvgBeginM7_test.repeatEventIndefiniteAndLiteral` | 已覆盖 |
| 7 | SvgBegin 序列化与多值列表 | 负偏移与零偏移 | `SvgBeginM7_test.afterOffset` | 已覆盖 |
| 7 |  | 多值列表 | `SvgBeginM7_test.joinKeepsOperandsImmutable` | 已覆盖 |
| 7 |  | join 不修改入参 | `SvgBeginM7_test.joinKeepsOperandsImmutable` | 已覆盖 |
| 8 | 生成枚举的规范拼写 | restart 与 fill | `SvgAuthoringTypesM7_test.restartSpelling`、`animationFillSpelling` | 已覆盖 |
| 8 |  | 变换类型 | `SvgAuthoringTypesM7_test.transformTypeSpelling` | 已覆盖 |
| 8 |  | 运动旋转 | `SvgAuthoringTypesM7_test.motionRotateSpelling`、`motionRotateEquality` | 已覆盖 |
| 9 | XML 文本输出契约 | 声明与命名空间 | `SvgBuilderM7_test.toSvgStringContract` | 已覆盖 |
| 9 |  | 缩进选项 | `SvgBuilderM7_test.toSvgStringContract` | 已覆盖 |
| 9 |  | 浏览器可播放 | `SvgBuilderM7_test.designExampleEndToEnd`、`animationMethodsAppendToCursor` | 已覆盖 |
| 10 | 文件落盘 | 落盘可重解析 | `SvgBuilderM7_test.saveWritesParseableFile` | 已覆盖 |
| 10 |  | 写入失败 | `SvgBuilderM7_test.saveFailureWrapsAsInvalidValue` | 已覆盖 |
| 11 | 生成侧兼容边界 | 既有用例零改动 | `git diff` + 1225 条全量测试 | 已验证（非单元测试） |
| 11 |  | 扩展 begin 不破坏时间轴 | `SvgBuilderM7_test.extendedBeginKeepsTimelineStable` | 已覆盖（断言偏弱，见 W-2） |

**Completeness 判定：31 / 31 有真实落点，无 Requirement 缺失。**

### 2.2 关键实现是否齐全

| 要求 | 实现位置 | 判定 |
|---|---|---|
| `SvgBuilder(width, height, viewBox!)` 根尺寸 `px` | `SvgAuthoringBuilder.cj:36-47` | 通过 |
| `group` / `end` 游标栈、栈底 `end` 无操作 | `SvgAuthoringBuilder.cj:74-95` | 通过 |
| 十种形状/文本/引用方法，游标指向新元素 | `SvgAuthoringBuilder.cj:98-198`、`382-386` | 通过 |
| 十个样式/通用属性，写呈现属性 | `SvgAuthoringBuilder.cj:201-252` | 通过 |
| 四种动画追加到当前元素 | `SvgAuthoringBuilder.cj:255-380` | 通过 |
| `document` / `toSvgString` / `save` | `SvgAuthoringBuilder.cj:50-71` | 通过 |
| 类型化动画元素与 SVG 属性名 | `SvgAnimate.cj:76-260`、`SvgAnimateTransform.cj:31-52`、`SvgAnimateMotion.cj:19-110`、`SvgSet.cj:19-69` | 通过 |
| `SvgBegin` 九类工厂 + `join` | `SvgBegin.cj:27-107` | 通过 |
| 四个生成枚举 | `SvgAuthoringTypes.cj:19-115` | 通过 |
| 动画标签不进入 `SvgTag` | `SvgTag.cj:79-93` 未改动 | 通过 |

---

## 3. Correctness：行为核查

### 3.1 游标、分组与结构

实现内部同时持有 `container`（新元素挂载点）与 `cursor`（样式/动画作用点），见 `SvgAuthoringBuilder.cj:31-34`：

- `group()` 把当前 `container` 压栈，`container` 与 `cursor` 同时指向新 `g`（`74-85`）；
- `end()` 弹栈，二者同时回到父元素；栈空时不做任何事（`88-95`）；
- `adopt()` 只把新元素挂到 `container`、把 `cursor` 指向新元素，不改变 `container`（`382-386`）。

由此得到的行为：

- `group(outer) → group(inner) → rect → end → circle → end`：`rect` 在内层 `g`，`circle` 在 `outer`，根只有 `outer`；由 `groupScenarioWithShapes` 实测通过；
- 根级 `end()` 后再 `group()` 仍挂根；`endAtRootIsNoop` 实测通过；
- 同一父元素下多个兄弟按调用顺序排列；`siblingOrderFollowsCalls` 实测通过；
- `rect(...).fill(...)` 只写 `rect`，后续 `circle()` 不继承；`styleTargetsCurrentElementOnly` 实测通过；
- 四种动画方法追加到当前 `cursor` 且不移动游标，因此可连续追加多个动画到同一个形状；`animationMethodsAppendToCursor` 实测通过。

结论：游标语义自洽，无结构错挂或属性串写。

### 3.2 形状、文本与引用元素

- 七种几何形状全部构造既有类型并写 `px`：`SvgAuthoringBuilder.cj:98-167`；`shapeGeometry` 断言 `rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path` 的标签与几何值，通过。
- `text` 使用 `SvgText` + `appendText`（`169-176`），`textUseAndImage` 同时断言模型文本 `a<b&c` 与序列化后的 `a&lt;b&amp;c`，转义路径真实。
- `use` / `image` 使用既有 `href` 属性（`178-198`）；模型层 `readSvgHref` 与坐标/尺寸断言通过。`SvgUse` / `SvgImage` 的 `href` setter 会写 `xlink:href`，`SvgWriter` 默认再归一化，引用语义正确。
- `points` / `d` 均通过 `setAttr` 原样写入（`148-167`），无生成侧改写。

结论：形状与引用元素正确。

### 3.3 样式与单位

- `fill` / `stroke` / `transform` / `attr` / `id` / `className` 原样写字符串（`201-252`）；
- `strokeWidth` 构造 `SvgLength(value, unit: Px)` 后输出，`2.0 → "2px"`（`211-215`）；
- `opacity` / `fillOpacity` / `strokeOpacity` 走 `formatSvgNumber`，无单位（`217-231`）；
- 不生成 `<style>`：实现中没有任何创建 `style` 元素的路径；`stylesNeverCreateStyleElement` 实测全文无 `<style` 且重解析无 style。

结论：单位与呈现属性正确，设计文档 D4 的「透明度无单位」例外已被实现并测试。

### 3.4 类型化动画属性名与序列化

`SvgAnimate` 的 17 个属性全部按 SVG 拼写写入（`SvgAnimate.cj:85-260`）：

`attributeName`、`from`、`to`、`by`、`values`、`dur`、`begin`、`end`、`repeatCount`、`repeatDur`、`fill`、`calcMode`、`keyTimes`、`keySplines`、`additive`、`accumulate`、`restart`。

- 属性名大小写与 SVG 规范一致；
- `values` / `keyTimes` / `keySplines` 保持分号字符串，不拆分（`121-129`、`214-230`）；
- 未知 `calcMode` 通过 `setAttr` 写入时原样输出，getter 返回 `None`；`unknownValuesPassThrough` 实测通过；
- `SvgAnimateTransform` 的 `type` 输出 `translate|scale|rotate|skewX|skewY`（`SvgAnimateTransform.cj:42-52`），测试逐项通过；
- `SvgAnimateMotion` 的 `path` / `keyPoints` / `rotate`（`SvgAnimateMotion.cj:48-91`）输出正确；
- `SvgSet` 的 `attributeName` / `to` / `begin` / `restart`（`SvgSet.cj:24-68`）输出正确；
- `SvgMpath` 输出 `<mpath href="#p"/>`（`SvgAnimateMotion.cj:19-39`、`SvgAnimateM7_test.animateMotionMpath`）。

结论：属性名与序列化整体符合浏览器 SVG 语法；`mpath` 的 `href` 形式存在兼容性提示，见 W-3。

### 3.5 `SvgBegin` 多值、偏移、repeat、事件、indefinite

`SvgBegin.cj` 内部只保存 `ArrayList<String>`，每个工厂返回新实例，`join` 复制两侧后返回新实例（`27-107`）。实测：

| 表达式 | 输出 | 测试 |
|---|---|---|
| `offset(0.0)` | `0s` | `offsetSeconds` |
| `offset(1.5)` | `1.5s` | `offsetSeconds` |
| `clock("500ms")` | `500ms` | `clockValue` |
| `at("a")` | `a.begin` | `atReference` |
| `at("a", begin: false)` | `a.end` | `atReference` |
| `after("a", 1.0)` | `a.end+1s` | `afterOffset` |
| `after("a", -0.5)` | `a.end-0.5s` | `afterOffset` |
| `after("a", 0.0)` | `a.end` | `afterOffset` |
| `repeatOf("a", 2)` | `a.repeat(2)` | `repeatEventIndefiniteAndLiteral` |
| `event("click")` | `click` | `repeatEventIndefiniteAndLiteral` |
| `indefinite()` | `indefinite` | `repeatEventIndefiniteAndLiteral` |
| `literal("5s")` | `5s` | `repeatEventIndefiniteAndLiteral` |
| `offset(0).join(after("a",1)).join(event("click"))` | `0s; a.end+1s; click` | `joinKeepsOperandsImmutable` |

`join` 不修改入参由 `joinKeepsOperandsImmutable` 直接验证：同一个 `base` 分别与两个表达式 `join`，`base.toString()` 仍为 `0s`，两次结果互不影响。

结论：多值、带符号偏移、零偏移省略符号、repeat、事件、indefinite 与不可变性均正确。`SvgBegin.offset` 对非有限值会经 `formatSvgNumber` 抛错，见 S-5。

### 3.6 生成字符串、XML 声明与 `xmlns`

`toSvgString` 直接委托 `writeSvgString(document(), options)`（`SvgAuthoringBuilder.cj:55-57`），构建器不拼 XML 字面量。`save` 也复用同一文本（`65-71`）。实测生成文件：

```xml
<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="200px" height="100px"><rect x="10px" y="30px" width="40px" height="40px" fill="#3366cc"><animate attributeName="x" from="10" to="150" dur="2s" begin="0s" repeatCount="indefinite"/></rect></svg>
```

- 以 `<?xml version="1.0" encoding="UTF-8"?>` 开头；
- 根带 `xmlns="http://www.w3.org/2000/svg"`；
- 紧凑输出；`indent: Some("  ")` 时两空格缩进；
- `toSvgStringContract` 分别解析紧凑与缩进输出并比较 `rect` 属性，结构一致。

结论：XML 文本输出契约成立，可被 `SvgParser` 重新解析。

### 3.7 `save`

- `save(path: String)` 委托 `save(Path(path))`（`60-62`）；
- `save(path: Path)` 使用 `File.writeTo`（`65-71`），UTF-8 字节；
- `saveWritesParseableFile` 断言两种重载写入字节完全一致、内容等于 `toSvgString()`、落盘后可 `SvgParser.parse(path)`；
- 目标目录不存在时捕获 `FSException` 并抛 `invalidValue`，`saveFailureWrapsAsInvalidValue` 断言 `kind == InvalidValue` 且消息含路径。

`SvgErrorKind` 确无 `Io`（`SvgException.cj:21-38`），`SvgBitmap.savePng` 也采用同一口径（`SvgBitmap.cj:172-178`），D9 的偏差裁决与既有先例一致。

### 3.8 既有用例零改动、零回归

- `git diff --name-status 48dd131e..HEAD -- f_svg/src` 只有 11 个 `A`，无既有文件 `M` / `D`；
- `SvgTag.cj`、`SvgTimeline.cj`、`SvgParser.cj`、`SvgWriter.cj` 的 diff 为空；
- 全量 `cjpm test`：1225 / 1225，0 SKIPPED、0 ERROR、0 FAILED；
- 新增 38 条，既有 1187 条按「总数 − 新增」推导，且源码字节未变。

结论：只新增文件、未改四个既有核心文件，既有用例零改动零回归。

### 3.9 动画追加与时间轴兼容

- 动画元素以 `setAttr` 为唯一事实源，未注册进 `SvgTag`；`animationTagsStayUnknown` 对五个标签逐一断言 `false`；
- 生成文档交给 `SvgParser` 后 `<animate>` 标签与属性保持；`generatedAnimationSurvivesParse` 通过；
- `SvgTimeline` 未修改；`extendedBeginKeepsTimelineStable` 对含 `a.end+1s`、`a.repeat(2)` 的文档调用 `sample(0.5)` 不抛异常，并断言 `warnings.size > 0`。

结论：兼容边界成立；但时间轴用例断言强度不足，见 W-2。

---

## 4. Coherence：规格、设计与交付一致性

### 4.1 只新增文件与禁止改动核查

| 检查项 | 结果 |
|---|---|
| `f_svg/src` 既有文件修改 | 无 |
| `SvgTag` 注册表修改 | 无 |
| `SvgTimeline` 修改 | 无 |
| `SvgParser` 修改 | 无 |
| `SvgWriter` 修改 | 无 |
| 新增第三方依赖 | 无 |
| 新增模块/子包 | 无 |
| `README.md` / `README_en.md` / `CHANGELOG` | 已更新（任务 6.6 允许） |
| `openspec validate --strict` | 通过 |

### 4.2 设计偏差记录

- **D1 文件名冲突**：设计 §2 写 `SvgBuilder.cj`，仓库中该文件已承担解析期 `buildSvgDocument`；作者侧 `SvgBuilder` 放入 `SvgAuthoringBuilder.cj`。proposal、design、tasks、verification 均有记录，**已闭环**。
- **D9 错误 kind**：设计 §3 写 `SvgException(kind: Io)`，但 `SvgErrorKind` 无 `Io`；实现按 `SvgBitmap.savePng` 先例抛 `InvalidValue`。spec 已写 `InvalidValue`，**已闭环**。
- 设计 §8 的「四种动画元素均可重解析」验收未完全测试，见 W-1。

### 4.3 文档与实现一致性

- README / README_en 的链式示例、形状/样式/动画/`SvgBegin`/`save`/已知限制与实现一致；
- CHANGELOG 记录了 M7 新增类型与「不修改四个既有文件」；
- `verification.md` 的 1187 基线、1225 终值、38 新增、213 个 `@Test` 类与实测一致；
- 存在若干措辞/记录不一致，见 S-8。

---

## 5. WARNING（5 项）

### W-1 设计 §8 的四种动画元素重解析验收只覆盖了 `animate`

- **位置**：`f_svg/doc/f_svg-M7设计.md:242-248` 要求 `rect + animate`、`animateTransform`、`animateMotion + mpath`、`set` 均能被 `SvgParser` 重新解析且结构/属性一致；实际 round-trip 测试只有 `SvgAnimateM7_test.generatedAnimationSurvivesParse`（`SvgAnimateM7_test.cj:216-251`）和 builder 的 `animate` 用例（`SvgBuilderM7_test.cj:525-573`、`480-506`）。
- **现状**：`animateTransform` / `animateMotion + mpath` / `set` 只在模型或 `SvgElement.toString()` 层断言（`SvgAnimateM7_test.cj:109-202`、`SvgBuilderM7_test.cj:329-445`），没有「`writeSvgString` → `SvgParser.parse`」的用例。
- **影响**：parser 未改动且未知标签走 `SvgUnknownElement` 保留（`SvgBuilder.cj:157-168`），实际风险不高；但设计验收项未闭环，若未来 parser/安全过滤调整，这三类生成元素可能先被破坏而无测试报警。
- **建议**：补充三种元素的生成 → 序列化 → 重解析用例，断言标签、父子结构与关键属性；或在 design/verification 中明确将 §8 收窄为「以 `animate` 为代表」。

### W-2 `SvgTimeline` 兼容用例只断言「有 warning」，未验证具体时间项被忽略

- **位置**：`SvgBuilderM7_test.cj:575-592`，断言仅为 `timeline.warnings.size > 0`（`591`）。
- **现状**：`SvgTimeline` 对无法解析的时间项会写 `无法解析动画时间「${text}」`（`SvgTimeline.cj:744-748`）。测试未断言 `a.end+1s`、`a.repeat(2)` 各自产生该 warning，也未断言不支持项的采样结果等价于被忽略，更未断言 `animations()` / `duration()` 语义不变。
- **影响**：若将来引入一个无关 warning（例如事件型时间、min/max 告警），测试仍会通过，形成「有 warning 即通过」的弱覆盖；无法证明 spec Req 11 的「按 M6 规则记录 warning 并忽略」。
- **建议**：断言 `warnings` 包含两条具体消息（或至少包含 `a.end+1s` / `a.repeat(2)` 文本），并补 `sample` 前后值与 `duration()` 断言。

### W-3 `mpath` 的 `href` 永远是裸 `href`，`xlink` 选项对其无效

- **位置**：`SvgAnimateMotion.cj:24-39` 的 `href` setter 写入裸 `href`；`SvgWriter.cj:190-202` 的 `isSvgReferencingElement` 只识别 `use` / `image` / `textPath` / 两个 gradient，不包含 `mpath`。
- **现状**：默认 `SvgWriteOptions(xlink: true)` 下，`use` / `image` 会输出 `xlink:href`，而 `mpath` 始终输出 `<mpath href="#p"/>`；`xlink: false` 也不会改变它（本来已是裸名）。
- **影响**：spec 的 mpath 场景期望 `href="#p"`，因此不算规格违反；但模块定位为 SVG 1.1，SVG 1.1 的 `mpath` 使用 `xlink:href`，部分旧浏览器/渲染器可能不识别裸 `href`。同时 README/design D3 只承诺 `use` / `image` 受 `xlink` 选项控制，未说明 `mpath` 的例外。
- **建议**：在 README / design / verification 中明确「`mpath` 固定输出裸 `href`，按 SVG 2 语义」；若必须兼容 SVG 1.1，可在不修改 `SvgWriter` 的前提下让 `SvgMpath.href` 写 `xlink:href`（与 `SvgUse` 一致），并补序列化/重解析断言。

### W-4 三个构建器方法的首参从设计稿的位置参数变成了命名参数

- **位置**：设计 API 草案 `design.md:94-143` 写 `animate(attribute: String, ...)`、`animateTransform(attribute: String, transformType: SvgAnimationTransformType, ...)`、`set(attribute: String, to: String, ...)`；实现为 `attribute!: String` / `transformType!: ...` / `to!: String`（`SvgAuthoringBuilder.cj:255-273`、`300-312`、`367-372`）。
- **影响**：设计稿中的示例全部使用命名实参，因此示例仍可编译；但按设计签名写位置调用（如 `builder.animate("x", from: "10")`）会编译失败。design D1 声称「类名与全部公开签名保持设计原样」（`design.md:34-42`），与实际不符。
- **建议**：要么把三个方法的首参改回非命名参数（保持调用兼容），要么在 design/proposal 中明确记录「为统一链式风格改为命名参数」的偏差，避免下游按设计稿调用失败。

### W-5 `SvgAnimateMotion.mpath` 直接删 `children`，留下过期 `parent` 且不通知 mutation

- **位置**：`SvgAnimateMotion.cj:94-110`，重复调用时用 `this.children.remove(at: index)` 删除旧 `mpath`。
- **现状**：`SvgElement.removeChild` 会同时清空 `element.parent` 并发送 `SvgMutationKind.ChildList` 事件（`SvgElement.cj:309-334`）；这里绕过了该 API。
- **影响**：调用方若保留上一次 `mpath("#p")` 返回的 `SvgMpath` 引用，其 `parent` 仍指向 `animateMotion`，`elementPath()` 等基于父链的计算会得到错误结果；注册在文档上的 mutation listener 也收不到删除事件。当前仅作者侧构建使用，影响面有限，但属于真实状态一致性问题。
- **建议**：改用 `removeChild(ElementNode(old))`，或删除后显式 `old.parent = None` 并发送同样的 mutation 事件；补一条「旧 mpath 的 parent 被清空」的断言。

---

## 6. SUGGESTION（9 项）

### S-1 规格「追加到当前游标元素」与实现的「追加到当前容器」不一致

- spec Req 2 写「追加到当前游标元素」（`spec.md:32`），design D2 写「`group()` 把当前游标压栈」（`design.md:44-48`）；实现实际维护 `container` 与 `cursor` 两个变量（`SvgAuthoringBuilder.cj:31-34`），形状挂到 `container`，`group()` 压的是 `container`（`74-85`、`382-386`）。
- 结果是 `rect(...).rect(...)` 生成兄弟而非嵌套（`shapeGeometry` 断言根下 7 个兄弟，已通过），这是正确的 SVG 行为；但 `rect(...).group().end().fill(...)` 会把 `fill` 写到根而不是 `rect`，与「游标栈」字面语义不同。
- **建议**：把 spec/design 的「游标」改为「当前容器 / 当前父元素」，并补一条「形状后接 `group()` 为兄弟」的说明或用例，避免调用方误解。

### S-2 「根级 `end` 无副作用」场景的测试对象与场景文字不一致

- spec 场景写「后续 `rect(...)` 仍追加到根元素」（`spec.md:25-28`）；`endAtRootIsNoop` 实际用 `group(id: "after")`（`SvgBuilderM7_test.cj:61-68`）。
- 行为等价，但没有直接覆盖场景文字中的 `rect`。建议在 `end()` 后补一个 `rect(...)` 并断言根子元素。

### S-3 `xmlDeclaration` / `xlink` 选项未通过构建器验证

- spec Req 9 要求 `xmlDeclaration`、`indent`、`xlink` 等字段按既有语义生效（`spec.md:175-194`）；`toSvgStringContract` 只验证了 `indent`（`SvgBuilderM7_test.cj:458`）。
- 实现是直接透传 `SvgWriteOptions`，风险低；建议补 `xmlDeclaration: false` 时不出现声明、`xlink: false` 时 `use` / `image` 输出裸 `href` 的用例。

### S-4 未知 `transformType` / `rotate` 的 getter 回退值未在文档中说明

- `SvgAnimateTransform.transformType` 对未知 `type` 返回 `Translate`（`SvgAnimateTransform.cj:42-52`），注释只说明「属性缺失时返回 `Translate`」；`SvgAnimateMotion.rotate` 对未知值回退 `Auto`（`SvgAnimateMotion.cj:72-87`）。
- 原始属性仍原样保留，序列化不受影响；建议在注释中补「未知值也回退默认」，避免调用方误以为 getter 能区分未知值。

### S-5 `SvgBegin.offset` 对非有限值会抛异常，与「生成侧不校验」措辞有张力

- `SvgBegin.offset` 走 `formatSvgNumber`（`SvgBegin.cj:35-37`），后者对 `NaN` / `Inf` 抛 `InvalidValue`（`SvgNumber.cj:33-35`）。
- spec Req 6 写「时间项 SHALL 只保存调用方输入，SHALL NOT 在生成侧解析、校验或改写」（`spec.md:116`）。有限值格式化是序列化必需，但非有限值抛错属于边界校验；建议在文档中明确「offset 仅接受有限秒数」，或补一条负向用例。

### S-6 测试固定写入 `target/` 下的文件名，存在陈旧文件/并发风险

- `saveWritesParseableFile` 使用 `target/m7-card.svg`、`target/m7-card-path.svg`（`SvgBuilderM7_test.cj:486-489`）；`designExampleEndToEnd` 使用 `target/m7-design-card.svg`（`554-556`）。
- 当前通过，但并行运行或上一次异常中断可能留下旧文件，导致断言受环境影响。建议使用唯一临时目录/文件名并在用例结束清理。

### S-7 `document()` 每次新建 `SvgDocument`，会重置根上的 mutation hub

- `SvgBuilder.document()` 每次 `SvgDocument(this.root)`（`SvgAuthoringBuilder.cj:50-52`）；`SvgDocument` 构造器会覆盖 `root.mutationHub`（`SvgDocument.cj:35-39`）。
- 若调用方在第一次 `document()` 返回的文档上注册 listener，之后再调用 `document()`，旧文档的 listener 将不再收到根上的变更。这是既有 `SvgDocument` 行为，但构建器把它暴露成常见路径；建议缓存同一个 `SvgDocument`，或在文档中注明。

### S-8 任务/设计文档存在少量记录不一致

- `tasks.md:4` 写「全部工作位于 `feature/f-svg-m7` 分支」，但 1.1（`tasks.md:10`）和实际分支都是 `feature/f_svg`；
- `tasks.md:26` 写「十八个属性逐一映射」，`SvgAnimate` 实际为 17 个属性（`SvgAnimate.cj:85-260`）；
- design §2 文件表把 `SvgAnimationTransformType` / `SvgMotionRotate` 归到 `SvgAnimateTransform.cj` / `SvgAnimateMotion.cj`（`design.md:45-51`），实现按 proposal/tasks 统一放在 `SvgAuthoringTypes.cj`（`SvgAuthoringTypes.cj:19-115`）。
- 不影响行为；建议统一措辞，避免后续审计误判。

### S-9 测试主要断言标签/属性，未直接断言「创建既有模型类型 / 继承 `SvgElement`」

- spec Req 2 要求创建 `SvgRect` / `SvgCircle` 等既有类型，Req 4 要求动画元素继承 `SvgElement`（`spec.md:30-34`、`72-76`）；测试目前通过 `tag` 与 `attr` 间接验证（如 `SvgAnimateM7_test.cj:43`、`SvgBuilderM7_test.cj:122-180`），没有 `rect is SvgRect`、`animate is SvgElement` 的直接断言。
- 行为已由类型化属性与序列化证明，风险低；若追求规格逐字对应，可补少量 `is` 断言。

---

## 7. 关于「实现后补测试的假覆盖」专项判断

- **提交顺序**：`6c89c945` 先建立 4 个测试文件骨架（每个仅 16 行头/导入，无实现）；`f51798c2`、`f4a993a9`、`99be5354`、`13b5ca1a`、`481ce3dc` 分别在新增实现的同时新增对应测试；`91661d8d` 在实现完成后补时间轴兼容用例与验收记录。没有发现「只改实现、测试另行伪造」的提交。
- **断言质量**：测试直接断言精确序列化字符串（如 `begin="0s; a.end+1s"`、`restart="whenNotActive"`、`type="skewX"`）、DOM 树父子关系、`writeSvgString → SvgParser.parse` 重解析结果、落盘字节与异常 kind/message；未使用 mock、未复制实现分支、未只断言「不抛异常」。
- **未发现系统性假覆盖**。
- **局部弱覆盖**：W-1（三种动画元素未 round-trip）、W-2（时间轴只断言有 warning）、S-3（`xmlDeclaration` / `xlink` 未过构建器）。建议按上述建议补强，但不影响当前「真实落点」结论。

---

## 8. 最终判定

- **Completeness**：11 / 11 Requirement、31 / 31 Scenario 均有实现与测试落点；新增 38 条用例全部通过。
- **Correctness**：游标/分组、十种形状、十种样式、四类动画、`SvgBegin` 全部工厂、四个枚举、XML 输出、`save`、重解析、既有 1187 条回归均通过；无功能性阻断。
- **Coherence**：只新增 `f_svg/src` 文件；`SvgTag` / `SvgTimeline` / `SvgParser` / `SvgWriter` 未改；两处设计偏差（D1 文件名、D9 错误 kind）已记录并被规格吸收。
- **非阻断问题**：5 项 WARNING、9 项 SUGGESTION，均不要求本次归档前修复，但建议在后续 M8 或补丁中处理 W-1 / W-2 / W-3 / W-4 / W-5。

CRITICAL=0
