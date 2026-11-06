# 任务：add-f-svg-m5

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每组结束 `cjpm test` 必须全绿；每组独立提交，全部工作位于 `feature/f-svg-m5` 分支。
> M5 只增不改 M1–M4 公开 API 语义；不新增模块、子包或第三方依赖；不改根 `cjpm.toml`、`.modules` 与聚合根 shim。
> 验证命令默认在 `f_svg/` 下执行；快照比对使用 `f_svg/testdata/render/` 的 `.rgba` 期望文件。

## 1. 准备与基线

- [ ] 1.1 从当前工作基线切出 `feature/f-svg-m5`，`git status --short` 为空、`git branch --show-current` 为 `feature/f-svg-m5`
- [ ] 1.2 运行 `cjpm test`，确认 `TOTAL: 710 / PASSED: 710 / FAILED: 0`，把耗时与结果写入本任务备注
- [ ] 1.3 运行 `cjpm build`，确认 `f_svg` 自身 0 warning，并记录基线
- [ ] 1.4 记录 17 张既有快照（M1–M3 13 张、M4 4 张）的 SHA-256 到 `doc/perf-baseline.md` 的 M5 小节，作为后续逐字节回归基准
- [ ] 1.5 通读 `doc/f_svg-M5设计.md`、本变更 `proposal.md` / `design.md` / `specs/`，在任务备注中列出四个阶段的实施边界
- [ ] 1.6 新建空实现骨架（仅包声明与 `TODO`）：`CssSelector2.cj`、`CssMedia.cj`、`CssVariables.cj`、`CssCalc.cj`、`SvgBlend.cj`、`SvgPaintOrder.cj`、`SvgTransformOrigin.cj`、`SvgContextPaint.cj`、`SvgOpenTypeLayout.cj`、`SvgBidi.cj`、`SvgElementApi.cj`；`cjpm build` 通过且 0 warning
- [ ] 1.7 建立 `testdata/render/m5-*` 场景与 `testdata/fonts/m5-*` fixture 目录，只放占位说明，确认 `cjpm test` 仍为 710 全绿
- [ ] 1.8 新增 `SvgSnapshotM5_test.cj` 辅助：按文件名读取 `.svg` / `.rgba` 并逐字节比较；先对 17 张既有快照跑通，确认无差异

## 2. P1 选择器模型与匹配

- [ ] 2.1 先写 `CssSelectorAttributeM5_test.cj`：七种属性选择器、三种引号、`i` 标志、空值 / 缺名 / 缺值非法；实现后用例转绿
- [ ] 2.2 先写 `CssSelectorStructuralM5_test.cj`：`:root`、`:first-child`、`:last-child`、`:only-child`、`:first-of-type`、`:last-of-type`、`:only-of-type`、`:empty` 在含文本 / 注释节点时的行为；实现 `elementSiblingIndex` / `previousElementSibling` 辅助后转绿
- [ ] 2.3 先写 `:nth-child` / `:nth-of-type` 表达式用例：`odd`、`even`、`2n+1`、`-n+2`、`n`、非法 `2n+`；实现 `An+B` 解析后转绿
- [ ] 2.4 先写 `:not()` 用例：单个类 / 属性 / 结构伪类、嵌套与复合参数被拒绝；实现否定匹配后转绿
- [ ] 2.5 先写兄弟组合器用例：`+` 相邻、`~` 一般、文本节点穿插、跨父元素不匹配；实现 `AdjacentSibling` / `GeneralSibling` 分支后转绿
- [ ] 2.6 先写特异性用例：`rect[data-x]`、`:first-child`、`:not(.x)`、分组选择器取最高值；实现 `CssSimpleSelectorKind` 计分后转绿
- [ ] 2.7 先写 256 个简单选择器上限用例：257 个时整条规则跳过且 `warnings` 含选择器片段；实现上限检查后转绿
- [ ] 2.8 先写 `SvgStyleResolver` 集成用例：新选择器参与级联、与 `!important` / 内联 / 呈现属性竞争结果正确；确认 2.1–2.7 的选择器在真实级联中生效
- [ ] 2.9 改写 `CssStyleSheet_test.unsupportedSelectorsAreSkipped`：`rect:hover` 仍被跳过，`rect[width]` 与 `g > circle` 正常解析，`warnings` 只含 `:hover` 一条；确认用例转绿
- [ ] 2.10 更新 `f_svg/README.md` / `README_en.md` 的选择器能力列表，并用文档中的示例执行一次 `CssSelector.parse` 验证可解析

## 3. P1 @media / @font-face / 变量 / calc() 与属性注册

- [ ] 3.1 先写 `CssMediaM5_test.cj` 解析用例：`screen` / `all` / `print`、`and`、逗号列表、`min-width` / `max-width`、非法查询；实现 `CssRule.media` 与嵌套块解析后转绿
- [ ] 3.2 先写媒体求值用例：宽度 800 / 400 / 300、根元素宽度、`render(element, w, h)` 宽度来源；实现宽度贯通（样式解析前计算逻辑宽度）后转绿
- [ ] 3.3 先写 `@font-face` 解析用例：`font-family` / 可选 `font-weight` / `font-style`、缺失 family、`src` 忽略并 warning；实现 `CssFontFaceRule` 与 `CssStyleSheet.fontFaces` 后转绿
- [ ] 3.4 先写字体别名用例：别名命中、权重回退、目标缺失、连续两次渲染不污染输入注册表；实现 `SvgFontRegistry.derived` 与构建器接线后转绿
- [ ] 3.5 先写 `CssVariablesM5_test.cj`：声明 / 继承 / 覆盖、`var()` 基本替换、fallback、空值、大小写保留；实现自定义属性级联与展开后转绿
- [ ] 3.6 先写变量负向用例：循环引用、8 层上限、9 层引用、fallback 内再 `var()`；实现深度与访问栈检测后转绿
- [ ] 3.7 先写 `CssCalcM5_test.cj`：`+` / `-` / `*` / `/`、括号、`px` / `em` / `%`、除零、混合单位、16 层嵌套；实现递归下降求值后转绿
- [ ] 3.8 先写 `calc()` 与属性归一化集成用例：`stroke-width`、`letter-spacing`、`font-size`、非法表达式回退；确认结果字符串可被既有 `SvgLength` 解析
- [ ] 3.9 先写 `SvgComputedStyleM5_test.cj`：8 个新属性的初始值、继承性、`inherit` / `initial` / `unset`、`transform-origin` 单值补 `center`、非法值 warning；实现属性表注册后转绿
- [ ] 3.10 改写 `CssStyleSheet_test.atRulesAreSkipped`：`@import` 仍跳过，`@media` / `@font-face` 正常解析，`warnings` 数量按新契约修正；确认用例转绿
- [ ] 3.11 先写组合场景：`@media` + 变量 + `calc()` + 新选择器同时生效，且不含这些特性的对照文档输出与 M4 一致；实现后提交本组
- [ ] 3.12 更新 README 的 CSS 能力与限制说明，逐条对照 3.1–3.10 的用例确认文档无夸大

## 4. P2 paint-order

- [ ] 4.1 先写 `SvgPaintOrderM5_test.cj`：`paint-order` 解析、缺省补齐、重复去重、未知关键字、`toString` 往返；实现 `SvgPaintOrder` 后转绿
- [ ] 4.2 先写 `SvgRenderTree` 用例：`stroke fill`、`fill stroke`、`markers fill stroke` 的命令顺序；实现按元素命令缓冲后转绿
- [ ] 4.3 先写 marker 位置用例：`markers` 在序列首 / 中 / 尾时 marker 命令位置变化，但数量、朝向、`refX/refY` 不变；实现后转绿
- [ ] 4.4 先写缺省一致性用例：未声明 `paint-order` 的文档命令序列与 M4 完全相同；用 `SvgSnapshotM5_test` 比对既有快照逐字节一致
- [ ] 4.5 更新 README 的渲染顺序说明并加入 `paint-order` 示例，确认示例渲染输出可通过 `cjpm test` 中的场景断言

## 5. P2 混合模式与隔离

- [ ] 5.1 先写 `SvgBlendM5_test.cj`：12 种模式的解析、`toString`、未知值回退；确认 `SvgBlendMode` 仍为 5 个取值
- [ ] 5.2 先写纯函数像素用例：`normal` 等价 source-over、`multiply` 白底红源、`screen` 红蓝、`difference` 白底白源、`αb=0`、`αs=0`、通道钳制；实现混合函数后转绿
- [ ] 5.3 先写 `SvgGroupCompositor` 重载用例：旧三参数调用输出与 M4 逐字节一致；新重载在 `normal` 下与旧调用等价；实现后转绿
- [ ] 5.4 先写显示命令与层触发用例：非 `normal` 元素必须建层，`normal` + `auto` 不建层；实现 `blendMode` / `isolated` 字段与 `needsLayer` 判定后转绿
- [ ] 5.5 先写 `isolation: isolate` 用例：组内 screen 不与组外白色背景混合；无其他效果时也建组；实现容器 `grouped` 判定后转绿
- [ ] 5.6 先写组合与确定性用例：滤镜 + 裁剪 + 混合顺序固定，连续渲染逐字节一致；确认 M4 效果顺序未变
- [ ] 5.7 更新 README 的混合与隔离章节，附一个 multiply 场景并确认渲染产物与断言一致

## 6. P2 feDropShadow

- [ ] 6.1 先写 `SvgDropShadowM5_test.cj`：标签映射、五个属性缺省值、`stdDeviation` 单 / 双值、读写往返；实现元素类型与 `SvgTag` / `SvgBuilder` 注册后转绿
- [ ] 6.2 先写渲染用例：默认投影、`dx=10` / `dy=0` / `stdDeviation=0` 硬边、`flood-opacity=0.5`；实现 blur → offset → flood → merge 后转绿
- [ ] 6.3 先写区域与非法参数用例：小区域裁剪、负 `stdDeviation`、非法 flood 颜色、`filterUnits` 生效；实现区域外扩与 warning 后转绿
- [ ] 6.4 先写等价性与确定性用例：`<feDropShadow/>` 与手写 `feGaussianBlur` + `feOffset` + `feFlood` + `feMerge` 链在同一输入上逐字节一致；同输入连续渲染两次也逐字节一致
- [ ] 6.5 更新 README 滤镜原语列表与示例，确认示例中的 `<feDropShadow/>` 可通过解析测试

## 7. P2 transform-origin / transform-box

- [ ] 7.1 先写 `SvgTransformOriginM5_test.cj`：长度、百分比、`left/center/right`、`top/center/bottom`、单值补 `center`、非法值回退；实现解析与归一化后转绿
- [ ] 7.2 先写 `effectiveElementTransform` 单元用例：原点 `(50,50)` 的 90° 旋转、`fill-box` 百分比、`view-box` 百分比、缺省短路；实现后转绿
- [ ] 7.3 先写渲染集成用例：`transform-origin` 作用于 `rect` / `g` / `text` / `image`，输出与手算矩阵一致；实现 `SvgRenderTree` 与 `SvgClipMask` 接线后转绿
- [ ] 7.4 先写 `SvgGeometry.ctm` / `absoluteBounds` 的样式重载用例：带 `transform-origin` 时与渲染矩阵一致，不传样式时保持 M4 结果；实现可选 `styles` 参数后转绿
- [ ] 7.5 先写缺省一致性用例：`0 0` + `view-box` 的文档输出与 M4 逐字节一致；用既有快照确认
- [ ] 7.6 更新 README 的变换章节，说明 `transform-origin` / `transform-box` 的参考盒与缺省值

## 8. P2 context-fill / context-stroke

- [ ] 8.1 先写 `SvgContextPaintM5_test.cj`：`SvgPaint.parse` 识别两个字面量、`toString` 往返、`SvgPaintKind` 新值；实现后转绿
- [ ] 8.2 先写 `use` 实例用例：引用元素 `fill="red"`、实例 `fill="context-fill"`；`stroke` 同理；嵌套 `use` 取最近帧；实现上下文帧后转绿
- [ ] 8.3 先写降级用例：无 `use` 上下文、引用元素自身为 `context-*`、帧内为 `none`；确认回退 `none` + warning 且不递归
- [ ] 8.4 先写与 `currentColor` 的优先级用例：两者同时声明时先解析 `context-*`，`currentColor` 不覆盖；实现顺序后转绿
- [ ] 8.5 更新 README 的 `use` 与画笔章节，记录 `context-*` 的实例边界和降级行为

## 9. P3 字距：kern 与 GPOS

- [ ] 9.1 构造最小 TTF fixture：含 `kern` format 0 的 `AV` 负字距；写 `SvgKernTableM5_test.cj` 覆盖读取、单位换算、截断与 65536 上限
- [ ] 9.2 实现 `kern` 表读取与 65536 条目上限；超限忽略整表并 warning，用例转绿
- [ ] 9.3 构造含 `GPOS` PairPos format 1（glyph pair）与 format 2（class pair）的 fixture；写读取与 Coverage / ClassDef / ValueRecord xAdvance 用例
- [ ] 9.4 实现 GPOS 解析与 65536 pair 上限；超限忽略子表并 warning，用例转绿
- [ ] 9.5 先写字距优先级用例：有 GPOS 时忽略 kern、`font-kerning: none/normal/auto` 三档、跨 `tspan` 不配对；实现布局接线后转绿
- [ ] 9.6 先写非整形字体用例：普通 `SvgFont` 实现与内置 Hershey 输出与 M4 逐字节一致；确认 `SvgFont.advance` 语义未变
- [ ] 9.7 更新 README 字体章节，说明字距只在布局阶段生效、`advance` 不变

## 10. P3 标准连字：GSUB liga

- [ ] 10.1 构造含 `GSUB` ScriptList / FeatureList / LookupList 与 Type 4 format 1 的 fixture；写 `SvgGsubM5_test.cj` 覆盖 `fi` 连字与最长匹配
- [ ] 10.2 实现 GSUB 表读取与连字替换；用例转绿
- [ ] 10.3 先写上限与降级用例：lookup 深度 9、输入 5 个字形、越界 coverage、截断表；实现后逐条确认 warning 且渲染继续
- [ ] 10.4 先写布局交互用例：连字 advance 取连字字形、簇消费首个字符的 `x/dx/rotate`、`textLength` 按整形后宽度计算；实现后转绿
- [ ] 10.5 更新 README 的 OpenType 支持范围，明确 `liga` 与不支持的上下文替换

## 11. P3 双向文本与方向属性

- [ ] 11.1 先写 `SvgBidiM5_test.cj` 类别用例：L / R / AL / EN / AN / WS / ON / B 的代表字符分类，未覆盖字符回退 L
- [ ] 11.2 先写段落层级与弱类型用例：`ltr` / `rtl` 基础层级、EN / AN 在 RTL 中保持 LTR、中性字符两侧解析；实现后转绿
- [ ] 11.3 先写重排与镜像用例：纯 RTL 反转、`"אב12"`、括号单层镜像、L2 结果稳定；实现视觉序列后转绿
- [ ] 11.4 先写 `direction` / `unicode-bidi` 用例：继承、`embed`、`bidi-override`、非法值回退；实现计算样式接线后转绿
- [ ] 11.5 先写文本渲染集成用例：RTL 文本的 `text-anchor`、`dx` 列表、`textPath` 视觉顺序落位；实现 `SvgTextRenderer` 管线后转绿
- [ ] 11.6 先写竖排组合用例：`writing-mode: tb-rl` + `direction` 只影响列序；确认与 M4 竖排快照在未声明 `direction` 时逐字节一致
- [ ] 11.7 更新 README 的文本章节，记录 UAX#9 子集范围与不支持项

## 12. P4 元素级 API

- [ ] 12.1 先写 `SvgElementApiM5_test.cj`：`getBBox` 形状 / 文本 / 描边 / 空路径 / 不可渲染元素；实现薄封装后转绿
- [ ] 12.2 先写容器与引用用例：`g` 并集、子 `transform` 计入、`use` 平移、`image` 矩形、定义型元素返回 `None`；实现后转绿
- [ ] 12.3 先写 `clipped` 与 `fonts` 选项用例：嵌套 `svg` 视口裁剪、自定义字体注册表、`clip-path` 不参与；实现后转绿
- [ ] 12.4 先写 `getCTM` / `getScreenCTM` 用例：祖先变换、嵌套 `svg`、DPR、未挂载元素、`transform-origin`、`viewport: None` 默认构造；实现后转绿
- [ ] 12.5 先写路径 API 用例：直线 / 折线 / 圆弧、负值与超长钳制、空 `d`；实现 `SvgPath` 转调后转绿
- [ ] 12.6 先写查询用例：`getElementsByClassName` 后代 / 顺序 / 去重、`querySelectorAll` 复用 M5 选择器、结果快照不随文档变化；实现后转绿
- [ ] 12.7 先写非法选择器与只读用例：`querySelectorAll("[x=")` 抛 `InvalidValue`；连续调用前后文档属性、子节点、warnings 不变
- [ ] 12.8 先写性能用例：1000 元素文档的 `querySelectorAll` 与单次 `getBBox` 耗时被记录；在 `doc/perf-baseline.md` 记录实测值
- [ ] 12.9 更新 README 的元素级 API 章节，逐条对照 12.1–12.7 的签名与返回值

## 13. 集成、快照与验收

- [ ] 13.1 运行 `cjpm test`，确认新增用例全绿、既有 708 条用例保持不变，2 条按新契约改写的用例（`atRulesAreSkipped` / `unsupportedSelectorsAreSkipped`）通过
- [ ] 13.2 用 `SvgSnapshotM5_test` 比对 17 张既有快照，确认逐字节一致
- [ ] 13.3 新增并复核 `m5-selector`、`m5-media`、`m5-blend`、`m5-drop-shadow`、`m5-transform-origin`、`m5-shaping`、`m5-bidi`、`m5-element-api` 快照，确认同输入重复渲染逐字节一致
- [ ] 13.4 运行 `cjpm build`，确认 `f_svg` 自身 0 warning
- [x] 13.5 运行 `openspec validate add-f-svg-m5 --strict`（通过，无 warning / error）
- [ ] 13.6 更新 `CHANGELOG` 的 M5 条目，列明新增属性、API、上限与兼容性边界；对照 `proposal.md` 确认无遗漏项
- [ ] 13.7 按仓库分支流程 `git merge --no-ff` 回 `master` 并删除 `feature/f-svg-m5`，确认合并后 `cjpm test` 仍全绿

## Workflow follow-up

- 代码审查与验收通过后归档本变更（`openspec archive add-f-svg-m5`）。
- 归档后核对 `openspec/specs/` 的 10 个能力域已合并新增要求，且无 `TBD` 残留。
