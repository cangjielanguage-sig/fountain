# 任务：add-f-svg-m6

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每组结束 `cjpm test` 必须全绿；每组独立提交，全部工作位于 `feature/f-svg-m6` 分支。
> M6 只增不改 M1–M5 公开 API 语义；不新增模块、子包或第三方依赖；不改根 `cjpm.toml`、`.modules` 与聚合根 shim。
> 验证命令默认在 `f_svg/` 下执行；快照比对使用 `f_svg/testdata/render/` 的 `.rgba` 期望文件。

## 1. 准备与基线

- [x] 1.1 从当前工作基线切出 `feature/f_svg`，`git status --short` 为空、`git branch --show-current` 为 `feature/f_svg`（按用户指定分支名执行）
- [x] 1.2 运行 `cjpm test`，确认 `TOTAL: 997 / PASSED: 997 / FAILED: 0`，把耗时与结果写入本任务备注（基线 997 已记录于 `verification.md`）
- [x] 1.3 运行 `cjpm build`，确认 `f_svg` 自身 0 warning，并记录基线
- [x] 1.4 记录既有 25 张快照（M1–M4 17 张、M5 8 张）的 SHA-256 到 `doc/perf-baseline.md` 的 M6 小节，作为逐字节回归基准（M1–M4 17 张已入表；M5 8 张由 M5 提交保持）
- [x] 1.5 通读 `doc/f_svg-M6设计.md`、本变更 `proposal.md` / `design.md` / `specs/`，在任务备注中列出七个阶段的实施边界与「不做」清单
- [x] 1.6 新建空实现骨架（仅包声明与 `TODO`）：`SvgPointerEvents.cj`、`SvgHitTest.cj`、`SvgCursor.cj`、`SvgForeignObject.cj`、`SvgExternalDocument.cj`、`SvgInitialView.cj`、`SvgRenderingHints.cj`、`SvgColorProfile.cj`、`SvgFontVariant.cj`、`SvgTextDecoration2.cj`、`SvgGsubContext.cj`、`SvgPathLength.cj`、`SvgAnimationControl.cj`、`SvgHitQueries.cj`、`SvgMutation.cj`、`SvgVectorEffect2.cj`、`SvgLineJoin2.cj`、`SvgAutoSize.cj`；`cjpm build` 通过且 0 warning（`SvgColorProfile` / `SvgAnimationControl` / `SvgLineJoin2` 最终按职责并入 `SvgRenderingHints.cj` / `SvgTimeline.cj` / `SvgShape.cj` + `SvgStrokeOutliner.cj`）
- [x] 1.7 建立 `testdata/render/m6-*` 场景与 `testdata/fonts/m6-*` fixture 目录，只放占位说明，确认 `cjpm test` 仍为 997 全绿（字体 fixture 最终以 `m5BuildLayoutTtf` 代码构造，未落盘）
- [x] 1.8 新增 `SvgSnapshotM6_test.cj` 辅助：按文件名读取 `.svg` / `.rgba` 并逐字节比较；先对 25 张既有快照跑通，确认无差异

## 2. P1 静态交互

- [x] 2.1 先写 `SvgPointerEventsM6_test.cj`：11 个取值的解析、大小写、`toString` 往返、未知值回退；实现 `SvgPointerEvents` 后转绿
- [x] 2.2 先写 `SvgCursorM6_test.cj`：关键字白名单、`url(...)` 回退 `auto`、未知值 warning、大小写；实现 `SvgCursor` 后转绿
- [x] 2.3 先写 `CssInteractionM6_test.cj`：`:hover` / `:focus` 解析、复合选择器、`:not()`、特异性 `(0,0,1)`、空状态永不匹配；实现 `CssPseudoClass.Hover/Focus` 与 `CssInteractionState` 后转绿
- [x] 2.4 先写 `:focus` 唯一性用例：`focusedIds` 多个 id 时只第一个可解析的匹配；无 id 元素永不匹配
- [x] 2.5 先写 `SvgStyleResolverM6_test.cj`：`compute(interaction!)` 重载、交互规则参与级联、普通规则与 `:hover` 同特异性时后出现者胜出；实现 resolver 字段与重载后转绿
- [x] 2.6 先写 `SvgComputedStyleM6_test.cj`：`pointer-events` / `cursor` 的初始值、继承、`inherit` / `initial` / `unset`、非法值 warning；实现属性表注册与 `pointerEvents()` / `cursor()` getter 后转绿
- [x] 2.7 先写 `SvgHitTestM6_test.cj`：重叠矩形顶层优先、`pointer-events: none` 剪枝、`visibleFill` / `visibleStroke` / `painted` / `bounding-box` / `all`、`visibility: hidden`、`image` 矩形、`text` 轮廓
- [x] 2.8 实现 `SvgHitTest` 的设备坐标换算（DPR + 矩阵逆）与填充 / 描边命中；用例 2.7 转绿
- [x] 2.9 先写命中测试边界用例：点落在路径外、描边外缘、zero-length 路径、空文档、`maxElements` 超限；确认返回空列表 / `None` 或 `Limit`，不崩溃
- [x] 2.10 先写缺省一致性用例：文档不含交互属性与伪类时，渲染输出与 M5 逐字节一致；用 25 张既有快照确认
- [x] 2.11 更新 README 的交互章节，记录 `pointer-events` / `cursor` / `:hover` / `:focus` 的静态求值边界与安全说明

## 3. P2 文档与嵌入

- [x] 3.1 先写 `SvgRootAttrsM6_test.cj`：`baseProfile()` / `version()` / `zoomAndPan()`、缺省 `None` / `Disable`、非法值 warning；实现文档查询后转绿
- [x] 3.2 先写 `SvgForeignObjectM6_test.cj`：注入位图、缺少 renderer、renderer 返回 `None`、缺少尺寸、XHTML 子节点不遍历、warning 文案；实现 `SvgForeignObjectRenderer`、`SvgDisplayCommand.bitmap` 与渲染树分支后转绿
- [x] 3.3 先写 foreignObject 像素用例：2×2 红色位图缩放到 `0 0 10 10` 后矩形全红；未提供 renderer 时保持透明
- [x] 3.4 先写 `SvgExternalDocumentM6_test.cj`：provider 被调用一次、片段定位、无片段用根、缺少 provider warning、未放行外部引用时 warning；实现 provider 接口与 `use` 分支后转绿
- [x] 3.5 先写外部文档负向用例：5 层嵌套、16 MiB + 1 字节、循环引用、外部文档自身再引用外部；确认 `Limit` 与 warning 口径
- [x] 3.6 先写 `SvgInitialViewM6_test.cj`：`#id` / `id`、命中 `view` 的视口覆盖、未命中 warning、无 `viewBox` 回退、`viewTarget` 不参与、缺省逐字节一致；实现后转绿
- [x] 3.7 先写 `SvgViewport` 集成用例：`initialView` 下输出尺寸不变、内容按 `preserveAspectRatio` 裁剪
- [x] 3.8 先写 `discard` 元素模型用例：标签保留、属性往返、不产生绘制指令、缺少 `begin` warning；实现 `SvgTag` 注册与渲染树跳过后转绿
- [x] 3.9 更新 README 的嵌入章节，记录 provider 安全边界、外部引用放行前提与 `initialView` 用法

## 4. P3 渲染提示与颜色

- [x] 4.1 先写 `SvgRenderingHintsM6_test.cj`：四个属性的合法取值、缺省 `auto`、继承、非法值 warning、`toString` 往返；实现枚举与属性表注册后转绿
- [x] 4.2 先写 `shape-rendering` 光栅用例：`optimizeSpeed` 边缘覆盖率为 0/1、`crispEdges` 关闭描边 AA、`geometricPrecision` 折线段数增加
- [x] 4.3 实现 `SvgRasterizer` 的可选容差倍率与 AA 覆盖参数；用例 4.2 转绿，确认默认调用输出不变
- [x] 4.4 先写 `text-rendering` 用例：`optimizeSpeed` 关闭连字与字距、`optimizeLegibility` 启用、`geometricPrecision` 容差 ×0.25；实现文本布局接线后转绿
- [x] 4.5 先写 `color-rendering` 用例：`auto` 解析式、`optimizeSpeed` 128 级、`optimizeQuality` 512 级、端点颜色不变；实现量化参数后转绿
- [x] 4.6 先写 `color-interpolation` 用例：`auto` / `sRGB` 与 M5 逐字节一致、`linearRGB` 红蓝中点约 `(188, 0, 188)`、端点不漂移、继承、与滤镜独立
- [x] 4.7 实现 `SvgGradientSampler` 的线性光 stop 预转换与查表；用例 4.6 转绿，确认 `sampleStops` 默认分支未变
- [x] 4.8 先写 `@color-profile` 解析用例：名称与 `src` 记录、缺少 `src`、重复声明、普通规则 `order` 不受影响；实现 `CssColorProfileRule` 与 `CssStyleSheet.colorProfiles` 后转绿
- [x] 4.9 先写 `color-profile` 属性用例：`auto` / `sRGB` / 已声明名称 / 未声明名称、非 sRGB warning 只记一次、像素按 sRGB；实现归一化与渲染侧回退后转绿
- [x] 4.10 先写组合场景：四个提示属性同时声明时渲染稳定、重复渲染逐字节一致；无声明文档与 M5 一致
- [x] 4.11 更新 README 的渲染提示与颜色章节，逐条对照 4.1–4.10 的用例确认文档无夸大

## 5. P4 文本与字体

- [x] 5.1 先写 `SvgFontStretchM6_test.cj`：9 个关键字与百分比解析、关键字→百分比映射、非法值、`toString` 往返；实现 `SvgFontStretch` 后转绿（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.2 先写注册表用例：`register(family, font, stretch!)`、`resolve(..., stretch!)`、精确匹配、最近百分比、无匹配回退 100%、原三参数调用不变；实现注册表扩展后转绿
- [x] 5.3 先写 stretch 合成用例：仅 100% 字体 + `80%` 时字形与 advance 水平缩放 0.8；复用 `scalePathX` 后转绿
- [x] 5.4 先写 `small-caps` 用例：`"ab"` 输出大写字形、缩放 0.8、advance 同步、缺大写字形 warning；实现 `scalePathUniform` 与映射后转绿（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.5 构造含 `OS/2.sxHeight` 的最小 TTF fixture；先写 `SvgFontSizeAdjustM6_test.cj`：字号修正、缺表忽略 + warning、`none` 不改变输出；实现 `xHeightRatio()` 后转绿（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.6 先写 `SvgFontFeaturesM6_test.cj`：`font-feature-settings` 解析（`0` / `1` / `on` / `off`、单双引号、64 条上限）、`font-variant-ligatures` 五值、合并优先级、`font-kerning` 覆盖 `kern`（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.7 实现 `SvgFontFeatures` 与样式层合并；确认默认集合下 M5 连字 / 字距用例全部保持
- [x] 5.8 重构 `SvgOpenTypeLayout` 为按特性分组；先跑 M5 的 `SvgGsubM5_test` / `SvgKerningLayoutM5_test`，确认零差异后再加新用例（实际由 `SvgFontFeatures` + `SvgGsubContextTable` 完成分组）
- [x] 5.9 构造 GSUB Type 5 format 3 fixture；先写 `SvgGsubContextM6_test.cj`：单层上下文替换、前后文匹配、覆盖表越界、不支持 format 2
- [x] 5.10 构造 GSUB Type 6 format 3 fixture；先写链式上下文用例：回溯 / 输入 / 前瞻、嵌套连字 lookup、第 9 层停止 + warning
- [x] 5.11 实现 Type 5/6 解析与应用（lookup 栈深度 8，只允许 Type 1 / 4 替换）；用例 5.9–5.10 转绿
- [x] 5.12 先写 `SvgTextDecorationM6_test.cj`：长属性解析、简写展开、缺省颜色 `currentColor`、非法样式 warning、`double` / `dotted` / `dashed` / `wavy` 几何、`text-underline-position` 三值（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.13 实现 `SvgTextDecorationSpec` 与装饰线生成；确认仅声明简写时输出与 M5 逐字节一致
- [x] 5.14 先写 `SvgPathLengthM6_test.cj`：合法比例、缺省 1、`0` / 负数 / 非有限 / 非数字 warning（实际用例并入 `SvgFontDetailsM6_test`）
- [x] 5.15 先写 pathLength 消费用例：`dasharray` / `dashoffset` 缩放、`textPath` `startOffset` 绝对值缩放、百分比仍按实际弧长、`totalLength` 不变；实现 `SvgPathLength` 后转绿
- [x] 5.16 先写文本合成交互用例：stretch + small-caps + size-adjust 组合、装饰线厚度按最终字号、`textLength` 在合成 advance 上计算
- [x] 5.17 更新 README 的字体与文本章节，记录新属性、特性开关、GSUB 5/6 范围与 `pathLength` 校准口径

## 6. P6 动画控制

- [x] 6.1 先写 `SvgAnimationControlM6_test.cj`：`currentTime()` / `setCurrentTime()`（负值按 0、NaN 抛 `InvalidValue`）、`pause()` / `unpause()` 的冻结与恢复
- [x] 6.2 先写触发用例：`begin="indefinite"` + `begin(id)`、`end(id)`、未知 id warning、`fill="freeze"` 保留末值；实现时间源与触发表后转绿
- [x] 6.3 先写 `fireEvent` 用例：`click` / `mouseover` / `accessKey` / `wallclock`、大小写、分号列表、`begin` 与 `end` 项分别生效、未匹配无副作用
- [x] 6.4 先写 `attributeType` 用例：`XML` 默认写属性、`CSS` 写内联样式、保留既有内联声明、样式表冲突时动画胜出、非法值 warning；实现 `svgSetInlineStyleProperty` 后转绿
- [x] 6.5 先写 `min` / `max` 用例：`max` 截断、`min` 延长、`min > max` 忽略 + warning、缺省与 M5 一致
- [x] 6.6 先写 `discard` 用例：到时移除、未到时保留、目标缺失、嵌套深度 1、采样快照不影响原文档；实现移除逻辑后转绿
- [x] 6.7 先写回归用例：M5 既有动画文档在未调用新 API 时 `sample(t)` 输出逐字节一致
- [x] 6.8 更新 README 的动画章节，说明触发 API、时间控制、`attributeType` 与 `discard` 的边界

## 7. P7 DOM API

- [x] 7.1 先写工厂方法用例：`SvgPoint.create` / `SvgMatrix.create` / `SvgTransform.create` 与既有构造器等价；实现后转绿
- [x] 7.2 先写 `SvgViewState` 用例：缺省单位矩阵、缩放 + 平移映射、`SvgRenderOptions.viewState` 渲染输出、缺省逐字节一致；实现后转绿
- [x] 7.3 先写 `insertBefore` / `removeChild` 用例：插到指定位置、`None` 追加、非法 reference 抛 `InvalidValue`、移除返回布尔、`parent` 维护；实现后转绿
- [x] 7.4 先写 `SvgMutationM6_test.cj`：属性事件、子节点事件、事件字段、32 上限、异常隔离、移除后不再通知；实现文档 hub 与沿 `parent` 链查找后转绿（实际用例并入 `SvgDomApiM6_test`）
- [x] 7.5 先写 `SvgHitQueriesM6_test.cj`：相交 / 包含、`check*` 一致性、`pointer-events: none` 与 `visibility: hidden` 筛选、`reference` 范围、空交集（实际用例并入 `SvgDomApiM6_test.hitQueries`）
- [x] 7.6 实现四个命中查询（复用 `getBBox` 与一次样式树计算）；用例 7.5 转绿
- [x] 7.7 先写负向与只读用例：`reference` 为叶子、矩形为空、连续调用前后文档不变、结果集合为新建实例
- [x] 7.8 先写性能用例：1000 元素文档的 `getIntersectionList` 与单次命中查询耗时；在 `doc/perf-baseline.md` 记录实测值
- [x] 7.9 更新 README 的 DOM API 章节，逐条对照 7.1–7.8 的签名与返回值

## 8. P8 SVG 2 收尾

- [x] 8.1 先写 `SvgVectorEffectM6_test.cj`：三个新值的解析 / `toString`、旧值不变、三个静态常量；实现枚举扩展后转绿（实际用例并入 `SvgSvg2M6_test`）
- [x] 8.2 先写矩阵语义用例：去缩放、去旋转、固定位置、三者组合顺序、`non-scaling-stroke` 不受影响；实现 `SvgVectorEffect2.apply` 后转绿
- [x] 8.3 先写渲染集成用例：`vector-effect` 与 `transform-origin` 的应用顺序、父子矩阵累乘、重复渲染一致
- [x] 8.4 先写 `SvgLineJoinM6_test.cj`：`miter-clip` / `arcs` 解析、`toString`、未知值；实现枚举扩展与所有内部 `match` 分支后转绿
- [x] 8.5 先写描边几何用例：`miter-clip` 截断位置、`arcs` 半径 2 的圆弧覆盖、`miterlimit` 边界、三种旧 join 逐字节一致
- [x] 8.6 先写 `SvgAutoSizeM6_test.cj`：根单轴 auto、双轴 auto、嵌套 auto 100%、无 `viewBox` / 无内容 warning、未声明 auto 与 M5 一致（实际用例并入 `SvgSvg2M6_test`）
- [x] 8.7 实现根与嵌套自动尺寸（显式 `auto` 才生效）；用例 8.6 转绿
- [x] 8.8 更新 README 的 SVG 2 章节，说明 `vector-effect` 组合、`miter-clip` / `arcs` 与 auto 尺寸的推导规则

## 9. 集成、快照与验收

- [x] 9.1 运行 `cjpm test`，确认新增用例全绿、既有 997 条用例保持不变
- [x] 9.2 用 `SvgSnapshotM6_test` 比对 25 张既有快照，确认逐字节一致
- [x] 9.3 新增并复核 `m6-interaction`、`m6-foreign-object`、`m6-initial-view`、`m6-rendering-hints`、`m6-color-interpolation`、`m6-font-details`、`m6-animation-control`、`m6-hit-queries`、`m6-svg2` 快照，确认同输入重复渲染逐字节一致
- [x] 9.4 运行 `cjpm build`，确认 `f_svg` 自身 0 warning
- [ ] 9.5 运行 `openspec validate add-f-svg-m6 --strict`，确认无 warning / error（当前环境无 `openspec` CLI，未复跑）
- [x] 9.6 更新 `CHANGELOG` 的 M6 条目，列明新增属性、API、上限与兼容性边界；对照 `proposal.md` 确认无遗漏项
- [x] 9.7 对照 `specs/` 逐条核对每个 Requirement 至少有一个可执行 Scenario，记录覆盖矩阵到 `verification.md`
- [ ] 9.8 合并回上游并删除分支——属共享分支操作，等待用户确认

## Workflow follow-up

- 代码审查与验收通过后归档本变更（`openspec archive add-f-svg-m6`）。
- 归档后核对 `openspec/specs/` 的 10 个能力域已合并新增要求，且无 `TBD` 残留。
