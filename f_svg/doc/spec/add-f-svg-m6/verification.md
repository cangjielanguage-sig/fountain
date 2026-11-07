# add-f-svg-m6 校验报告（verification）

- 校验对象：`openspec/changes/add-f-svg-m6`（proposal / design / tasks / 10 个 delta spec）与 `f_svg/src` 全部实现、测试。
- 校验基线：`feature/f_svg`；任务 1.2 记录的原始基线为 **997** 条用例，M6 完成后为 **1137** 条。
- 校验方式：只读审阅 + 全量测试 + 构建 + 快照逐字节/哈希复核；未归档、未执行 `git worktree` 或改写 `.git`。
- 环境说明：工作树 `.git` 指向 `/storage/...`（实际挂载为 `/mnt/linux_share/storage/...`），git 读写使用显式 `GIT_DIR` / `GIT_WORK_TREE` 完成。

## 0. 门禁结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | `TOTAL: 1137 / PASSED: 1137 / SKIPPED: 0 / ERROR: 0 / FAILED: 0` | `f_svg/cjpm test`（2026-11-07） |
| 构建 | `cjpm build success`；`f_svg` 自身 **0 warning** | 重编译日志中 0 条 warning 指向 `f_svg/src`（依赖模块既有 warning 不计） |
| 既有快照 | M1–M5 **25/25** 逐字节一致 | 17 张 M1–M4 与 `doc/perf-baseline.md` 的 SHA-256 一致；8 张 M5 快照工作区无改动；`SvgSnapshotM6_test` 逐字节比对通过 |
| M6 快照 | 9/9 新增且重复渲染逐字节一致 | `SvgSnapshotM6Scenes_test.scenesExact/scenesAreDeterministic` |
| delta 规范规模 | **54 Requirement / 255 Scenario** | 10 个 `specs/*/spec.md` 标题计数 |
| CRITICAL | **0** | C1、C2 修复；C3、C4 落地并有直接用例 |

## 1. Requirement / Scenario 覆盖矩阵

口径：每个 Scenario 单列一行；“落点”为直接断言或该 Requirement 的专用测试入口。所有列出的用例均在 1137 条全绿结果内。

### svg-animation

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 时间模型 | 毫秒解析 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 2 | 时间模型 | id.begin | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 3 | 时间模型 | 重复次数 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 4 | 时间模型 | repeatDur 截断 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 5 | 时间模型 | fill freeze | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 6 | 时间模型 | 事件型 begin | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 7 | 时间模型 | begin indefinite | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource/indefiniteBegin/fireEvent` | ✅ |
| 8 | 采样快照 | 不修改原文档 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 9 | 采样快照 | 时长 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 10 | 采样快照 | 无动画 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 11 | 采样快照 | 仅无限动画 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 12 | 采样快照 | 手动时钟 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 13 | 采样快照 | sample 语义不变 | `SvgAnimation_test`；`SvgAnimationControlM6_test.m5SampleStability` | ✅ |
| 14 | M6 动画触发与时间控制 | 显式开始 indefinite | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 15 | M6 动画触发与时间控制 | 显式结束 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 16 | M6 动画触发与时间控制 | 未知 id | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 17 | M6 动画触发与时间控制 | 事件触发 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 18 | M6 动画触发与时间控制 | 事件未匹配 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 19 | M6 动画触发与时间控制 | 设置时间 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 20 | M6 动画触发与时间控制 | 非法时间 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 21 | M6 动画触发与时间控制 | 暂停与恢复 | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/indefiniteBegin/fireEvent/explicitEnd` | ✅ |
| 22 | M6 动画写入类型 | XML 默认 | `SvgAnimationControlM6_test.attributeTypeCss` | ✅ |
| 23 | M6 动画写入类型 | CSS 写入 | `SvgAnimationControlM6_test.attributeTypeCss` | ✅ |
| 24 | M6 动画写入类型 | 保留既有内联样式 | `SvgAnimationControlM6_test.attributeTypeCss` | ✅ |
| 25 | M6 动画写入类型 | 非法值 | `SvgAnimationControlM6_test.attributeTypeCss` | ✅ |
| 26 | M6 活动时长钳制 | max 截断 | `SvgAnimationControlM6_test.minMax` | ✅ |
| 27 | M6 活动时长钳制 | min 延长 | `SvgAnimationControlM6_test.minMax` | ✅ |
| 28 | M6 活动时长钳制 | min 大于 max | `SvgAnimationControlM6_test.minMax` | ✅ |
| 29 | M6 活动时长钳制 | 缺省 | `SvgAnimationControlM6_test.minMax` | ✅ |
| 30 | M6 discard 快照移除 | 到时移除 | `SvgAnimationControlM6_test.discard`；`SvgDiscardM6_test` | ✅ |
| 31 | M6 discard 快照移除 | 未到时保留 | `SvgAnimationControlM6_test.discard`；`SvgDiscardM6_test` | ✅ |
| 32 | M6 discard 快照移除 | 目标缺失 | `SvgAnimationControlM6_test.discard`；`SvgDiscardM6_test` | ✅ |
| 33 | M6 discard 快照移除 | 嵌套深度 | `SvgAnimationControlM6_test.discard`；`SvgDiscardM6_test` | ✅ |

### svg-css

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | CSS 规则集解析 | 解析基本规则 | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 2 | CSS 规则集解析 | 跳过不支持构造 | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 3 | CSS 规则集解析 | 注释与字符串 | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 4 | CSS 规则集解析 | 截断恢复 | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 5 | CSS 规则集解析 | 自定义属性大小写 | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 6 | CSS 规则集解析 | 解析 @color-profile | `CssStyleSheet_test`、`CssLexer_test`、`SvgRenderingHintsM6_test.colorProfileParsing` | ✅ |
| 7 | 选择器模型与匹配 | 五类基本选择器 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 8 | 选择器模型与匹配 | 后代与子代 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 9 | 选择器模型与匹配 | 复合选择器 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 10 | 选择器模型与匹配 | 特异性 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 11 | 选择器模型与匹配 | 空交互状态 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 12 | 选择器模型与匹配 | 交互伪类特异性 | `CssSelector_test`、`CssSelectorCascadeM5_test`、`CssInteractionM6_test` | ✅ |
| 13 | M6 交互伪类求值 | hover 命中 | `CssInteractionM6_test` | ✅ |
| 14 | M6 交互伪类求值 | hover 未提供 | `CssInteractionM6_test` | ✅ |
| 15 | M6 交互伪类求值 | focus 只取第一个 | `CssInteractionM6_test` | ✅ |
| 16 | M6 交互伪类求值 | 无 id 元素 | `CssInteractionM6_test` | ✅ |
| 17 | M6 交互伪类求值 | 与 :not 组合 | `CssInteractionM6_test` | ✅ |
| 18 | M6 交互与光标属性 | pointer-events 全部取值 | `SvgComputedStyleM6_test`、`SvgPointerEventsM6_test`、`SvgCursorM6_test` | ✅ |
| 19 | M6 交互与光标属性 | pointer-events 非法值 | `SvgComputedStyleM6_test`、`SvgPointerEventsM6_test`、`SvgCursorM6_test` | ✅ |
| 20 | M6 交互与光标属性 | cursor 关键字 | `SvgComputedStyleM6_test`、`SvgPointerEventsM6_test`、`SvgCursorM6_test` | ✅ |
| 21 | M6 交互与光标属性 | cursor 非法值 | `SvgComputedStyleM6_test`、`SvgPointerEventsM6_test`、`SvgCursorM6_test` | ✅ |
| 22 | M6 交互与光标属性 | 不影响绘制 | `SvgComputedStyleM6_test`、`SvgPointerEventsM6_test`、`SvgCursorM6_test` | ✅ |
| 23 | M6 渲染提示属性注册 | 缺省值 | `SvgRenderingHintsM6_test.hintValues/invalidHintsWarn` | ✅ |
| 24 | M6 渲染提示属性注册 | 合法取值往返 | `SvgRenderingHintsM6_test.hintValues/invalidHintsWarn` | ✅ |
| 25 | M6 渲染提示属性注册 | 非法值回退 | `SvgRenderingHintsM6_test.hintValues/invalidHintsWarn` | ✅ |
| 26 | M6 颜色配置 | 声明被记录 | `SvgRenderingHintsM6_test.colorProfileParsing/colorProfileProperty` | ✅ |
| 27 | M6 颜色配置 | 已声明名称 | `SvgRenderingHintsM6_test.colorProfileParsing/colorProfileProperty` | ✅ |
| 28 | M6 颜色配置 | 未声明名称 | `SvgRenderingHintsM6_test.colorProfileParsing/colorProfileProperty` | ✅ |
| 29 | M6 颜色配置 | 缺少 src | `SvgRenderingHintsM6_test.colorProfileParsing/colorProfileProperty` | ✅ |
| 30 | M6 字体选择属性 | 关键字与百分比 | `SvgFontDetailsM6_test.fontStretchParsing/fontStretchStyle/capsAndSizeAdjust` | ✅ |
| 31 | M6 字体选择属性 | small-caps 归一化 | `SvgFontDetailsM6_test.fontStretchParsing/fontStretchStyle/capsAndSizeAdjust` | ✅ |
| 32 | M6 字体选择属性 | font-size-adjust 数值 | `SvgFontDetailsM6_test.fontStretchParsing/fontStretchStyle/capsAndSizeAdjust` | ✅ |
| 33 | M6 字体选择属性 | 继承 | `SvgFontDetailsM6_test.fontStretchParsing/fontStretchStyle/capsAndSizeAdjust` | ✅ |
| 34 | M6 OpenType 特性属性 | 解析 tag 开关 | `SvgFontDetailsM6_test.fontFeatureParsing/featureMerge` | ✅ |
| 35 | M6 OpenType 特性属性 | 禁用常见连字 | `SvgFontDetailsM6_test.fontFeatureParsing/featureMerge` | ✅ |
| 36 | M6 OpenType 特性属性 | 显式设置覆盖变体 | `SvgFontDetailsM6_test.fontFeatureParsing/featureMerge` | ✅ |
| 37 | M6 OpenType 特性属性 | 条目上限 | `SvgFontDetailsM6_test.fontFeatureParsing/featureMerge` | ✅ |
| 38 | M6 装饰长属性 | 简写展开 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry` | ✅ |
| 39 | M6 装饰长属性 | 组合线型 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry` | ✅ |
| 40 | M6 装饰长属性 | 缺省颜色 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry` | ✅ |
| 41 | M6 装饰长属性 | 非法样式 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry` | ✅ |

### svg-document-model

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 文档对象 | 按 id 查找 | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` | ✅ |
| 2 | 文档对象 | 按标签查找 | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` | ✅ |
| 3 | 文档对象 | 根属性 | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` | ✅ |
| 4 | 文档对象 | 根属性缺省 | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` | ✅ |
| 5 | 文档对象 | 根属性非法 | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` | ✅ |
| 6 | M6 元素结构变更 | 插入到指定位置 | `SvgDomApiM6_test.childMutations` | ✅ |
| 7 | M6 元素结构变更 | 追加语义 | `SvgDomApiM6_test.childMutations` | ✅ |
| 8 | M6 元素结构变更 | 非法引用 | `SvgDomApiM6_test.childMutations` | ✅ |
| 9 | M6 元素结构变更 | 移除 | `SvgDomApiM6_test.childMutations` | ✅ |
| 10 | M6 变更监听 | 属性变更通知 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit` | ✅ |
| 11 | M6 变更监听 | 子节点变更通知 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit` | ✅ |
| 12 | M6 变更监听 | 上限 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit` | ✅ |
| 13 | M6 变更监听 | 异常隔离 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit` | ✅ |
| 14 | M6 变更监听 | 移除 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit` | ✅ |
| 15 | M6 命中查询 API | 相交列表 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 16 | M6 命中查询 API | 包含列表 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 17 | M6 命中查询 API | 单元素检查 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 18 | M6 命中查询 API | pointer-events 筛选 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 19 | M6 命中查询 API | reference 范围 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 20 | M6 命中查询 API | 空交集 | `SvgDomApiM6_test.hitQueries/queriesAreReadOnly/largeDocumentPerformance` | ✅ |
| 21 | M6 discard 元素模型 | 解析与往返 | `SvgDiscardM6_test` | ✅ |
| 22 | M6 discard 元素模型 | 不参与渲染 | `SvgDiscardM6_test` | ✅ |
| 23 | M6 discard 元素模型 | 缺少 begin | `SvgDiscardM6_test` | ✅ |

### svg-geometry

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | M6 命中测试 | 顶层优先 | `SvgHitTestM6_test` | ✅ |
| 2 | M6 命中测试 | pointer-events: none | `SvgHitTestM6_test` | ✅ |
| 3 | M6 命中测试 | 仅描边命中 | `SvgHitTestM6_test` | ✅ |
| 4 | M6 命中测试 | bounding-box | `SvgHitTestM6_test` | ✅ |
| 5 | M6 命中测试 | 隐藏元素 | `SvgHitTestM6_test` | ✅ |
| 6 | M6 命中测试 | 设备坐标换算 | `SvgHitTestM6_test` | ✅ |
| 7 | M6 命中测试 | 空文档 | `SvgHitTestM6_test` | ✅ |
| 8 | M6 pathLength 校准 | 校准比例 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength` | ✅ |
| 9 | M6 pathLength 校准 | 斜率相同 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength` | ✅ |
| 10 | M6 pathLength 校准 | 非法值 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength` | ✅ |
| 11 | M6 pathLength 校准 | 缺失属性 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength` | ✅ |
| 12 | M6 矢量效果几何语义 | 去缩放 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 13 | M6 矢量效果几何语义 | 去旋转 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 14 | M6 矢量效果几何语义 | 固定位置 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 15 | M6 矢量效果几何语义 | 组合顺序 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 16 | M6 矢量效果几何语义 | 既有值不受影响 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |

### svg-paint-and-clip

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 线性渐变 | 端点颜色 | `SvgGradientSampler_test`、`SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged` | ✅ |
| 2 | 线性渐变 | 中点插值 | `SvgGradientSampler_test`、`SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged` | ✅ |
| 3 | 线性渐变 | spreadMethod | `SvgGradientSampler_test`、`SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged` | ✅ |
| 4 | 线性渐变 | stop 乱序与越界 | `SvgGradientSampler_test`、`SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged` | ✅ |
| 5 | 线性渐变 | linearRGB 中点 | `SvgGradientSampler_test`、`SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged` | ✅ |
| 6 | M6 颜色插值模式 | 缺省不变 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline` | ✅ |
| 7 | M6 颜色插值模式 | 线性光两端一致 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline` | ✅ |
| 8 | M6 颜色插值模式 | 与滤镜独立 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline` | ✅ |
| 9 | M6 颜色插值模式 | 继承 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline` | ✅ |
| 10 | M6 颜色配置回退 | 缺省 | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty` | ✅ |
| 11 | M6 颜色配置回退 | 已声明非 sRGB | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty` | ✅ |
| 12 | M6 颜色配置回退 | 未声明名称 | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty` | ✅ |

### svg-rasterization

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 抗锯齿 | 斜边覆盖 | `SvgRasterizer_test`、`SvgRenderingHintsM6_test.shapeOptimizeSpeed/defaultRasterUnchanged` | ✅ |
| 2 | 抗锯齿 | 关闭抗锯齿 | `SvgRasterizer_test`、`SvgRenderingHintsM6_test.shapeOptimizeSpeed/defaultRasterUnchanged` | ✅ |
| 3 | 抗锯齿 | 解析档 | `SvgRasterizer_test`、`SvgRenderingHintsM6_test.shapeOptimizeSpeed/defaultRasterUnchanged` | ✅ |
| 4 | 抗锯齿 | optimizeSpeed 覆盖全局档位 | `SvgRasterizer_test`、`SvgRenderingHintsM6_test.shapeOptimizeSpeed/defaultRasterUnchanged` | ✅ |
| 5 | 抗锯齿 | 缺省不受影响 | `SvgRasterizer_test`、`SvgRenderingHintsM6_test.shapeOptimizeSpeed/defaultRasterUnchanged` | ✅ |
| 6 | join 与 dash 规则 | miter 截断 | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 7 | join 与 dash 规则 | miter-clip | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 8 | join 与 dash 规则 | arcs | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 9 | join 与 dash 规则 | dash 相位 | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 10 | join 与 dash 规则 | pathLength 影响 dash | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 11 | join 与 dash 规则 | 非法 pathLength | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 12 | M6 渲染提示到光栅参数 | shape geometricPrecision | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 13 | M6 渲染提示到光栅参数 | text optimizeSpeed | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 14 | M6 渲染提示到光栅参数 | text optimizeLegibility | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 15 | M6 渲染提示到光栅参数 | text geometricPrecision | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 16 | M6 渲染提示到光栅参数 | 渐变量化 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 17 | M6 渲染提示到光栅参数 | 继承范围 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |
| 18 | M6 渲染提示到光栅参数 | 缺省一致 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable` | ✅ |

### svg-render-pipeline

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 渲染选项扩展 | 既有调用不变 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 2 | 渲染选项扩展 | 选项校验 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 3 | 渲染选项扩展 | 空交互集合 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 4 | use 展开 | 基本复用 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 5 | use 展开 | 引用 symbol | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 6 | use 展开 | 循环引用 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 7 | use 展开 | 外部文档 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 8 | use 展开 | 外部文档缺 provider | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 9 | use 展开 | 外部文档上限 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test`、`SvgBBoxM5_test.useCycleIsGuarded` | ✅ |
| 10 | view 不参与默认渲染 | 默认渲染不变 | `SvgInitialViewM6_test.viewTargetIgnored` | ✅ |
| 11 | view 不参与默认渲染 | 单独渲染 view | `SvgInitialViewM6_test.viewTargetIgnored` | ✅ |
| 12 | M6 初始视图片段导航 | 命中 view | `SvgInitialViewM6_test` | ✅ |
| 13 | M6 初始视图片段导航 | 不带井号 | `SvgInitialViewM6_test` | ✅ |
| 14 | M6 初始视图片段导航 | 未命中 | `SvgInitialViewM6_test` | ✅ |
| 15 | M6 初始视图片段导航 | 缺省 | `SvgInitialViewM6_test` | ✅ |
| 16 | M6 foreignObject 注入渲染 | 注入位图 | `SvgForeignObjectM6_test` | ✅ |
| 17 | M6 foreignObject 注入渲染 | 缺 renderer | `SvgForeignObjectM6_test` | ✅ |
| 18 | M6 foreignObject 注入渲染 | renderer 返回空 | `SvgForeignObjectM6_test` | ✅ |
| 19 | M6 foreignObject 注入渲染 | 缺少尺寸 | `SvgForeignObjectM6_test` | ✅ |
| 20 | M6 foreignObject 注入渲染 | 不解析 XHTML | `SvgForeignObjectM6_test` | ✅ |
| 21 | M6 交互状态贯通 | hover 改变填充 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 22 | M6 交互状态贯通 | 级联优先级 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 23 | M6 交互状态贯通 | 非交互文档不变 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 24 | M6 视图状态 | 缩放 | `SvgDomApiM6_test.viewState` | ✅ |
| 25 | M6 视图状态 | 平移 | `SvgDomApiM6_test.viewState` | ✅ |
| 26 | M6 视图状态 | 缺省 | `SvgDomApiM6_test.viewState` | ✅ |
| 27 | M6 自动尺寸 | 根自动宽度 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged` | ✅ |
| 28 | M6 自动尺寸 | 嵌套自动尺寸 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged` | ✅ |
| 29 | M6 自动尺寸 | 无法确定 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged` | ✅ |
| 30 | M6 自动尺寸 | 未声明 auto | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged` | ✅ |
| 31 | M6 矢量效果的矩阵应用 | 应用顺序 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 32 | M6 矢量效果的矩阵应用 | 父子累乘 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |
| 33 | M6 矢量效果的矩阵应用 | 既有描边 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected` | ✅ |

### svg-security

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 渲染期无外部访问 | 外部 CSS 引用 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 2 | 渲染期无外部访问 | 外部图片 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 3 | 渲染期无外部访问 | 未注入图片资源 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 4 | 渲染期无外部访问 | 注入 provider | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 5 | 渲染期无外部访问 | 动画不执行脚本 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 6 | 渲染期无外部访问 | 外部文档不递归加载 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 7 | 渲染期无外部访问 | foreignObject 不经库渲染 | `SvgExternalDocumentM6_test`、`SvgForeignObjectM6_test` | ✅ |
| 8 | M6 上限与降级 | 外部文档深度 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |
| 9 | M6 上限与降级 | 外部文档字节 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |
| 10 | M6 上限与降级 | 特性条目上限 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |
| 11 | M6 上限与降级 | 监听器上限 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |
| 12 | M6 上限与降级 | discard 嵌套 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |
| 13 | M6 上限与降级 | 命中测试规模 | `SvgExternalDocumentM6_test.depthLimit/byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgHitTestM6_test.boundaries` | ✅ |

### svg-text

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 文本布局 | 连续空格 | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 2 | 文本布局 | 连续布局 | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 3 | 文本布局 | text-anchor middle | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 4 | 文本布局 | dx/dy 偏移 | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 5 | 文本布局 | textLength spacingAndGlyphs | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 6 | 文本布局 | 连字消费列表项 | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 7 | 文本布局 | optimizeSpeed 关闭整形 | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test`、`SvgGsubContextM6_test` | ✅ |
| 8 | 文本装饰线 | 下划线像素 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 9 | 文本装饰线 | 组合装饰 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 10 | 文本装饰线 | 与填充同色 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 11 | 文本装饰线 | 沿路径旋转 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 12 | 文本装饰线 | 祖先传播 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 13 | 文本装饰线 | none 关闭 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 14 | 文本装饰线 | 独立颜色 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 15 | 文本装饰线 | 样式与厚度 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 16 | 文本装饰线 | 双线 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize` | ✅ |
| 17 | textPath 路径与起点 | 水平路径 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength` | ✅ |
| 18 | textPath 路径与起点 | 百分比起点 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength` | ✅ |
| 19 | textPath 路径与起点 | pathLength 校准起点 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength` | ✅ |
| 20 | OpenType 字距调整 | kern 表配对 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 21 | OpenType 字距调整 | GPOS 优先 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 22 | OpenType 字距调整 | font-kerning none | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 23 | OpenType 字距调整 | 跨 tspan 不配对 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 24 | OpenType 字距调整 | 特性开关关闭 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 25 | OpenType 字距调整 | font-kerning 优先 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 26 | 标准连字 | fi 连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 27 | 标准连字 | 最长匹配优先 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 28 | 标准连字 | 深度上限 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 29 | 标准连字 | 关闭常见连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 30 | 标准连字 | 历史连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 31 | M6 字体匹配与合成 | stretch 精确匹配 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio` | ✅ |
| 32 | M6 字体匹配与合成 | 百分比合成 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio` | ✅ |
| 33 | M6 字体匹配与合成 | small-caps | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio` | ✅ |
| 34 | M6 字体匹配与合成 | font-size-adjust | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio` | ✅ |
| 35 | M6 字体匹配与合成 | 缺少 OS/2 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio` | ✅ |
| 36 | M6 字体特性开关 | 默认开启 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle` | ✅ |
| 37 | M6 字体特性开关 | none 关闭 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle` | ✅ |
| 38 | M6 字体特性开关 | discretionary | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle` | ✅ |
| 39 | M6 字体特性开关 | contextual | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle` | ✅ |
| 40 | M6 字体特性开关 | 显式覆盖 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle` | ✅ |
| 41 | M6 GSUB 上下文替换 | 单层上下文替换 | `SvgGsubContextM6_test` | ✅ |
| 42 | M6 GSUB 上下文替换 | 链式上下文 | `SvgGsubContextM6_test` | ✅ |
| 43 | M6 GSUB 上下文替换 | 嵌套连字 | `SvgGsubContextM6_test` | ✅ |
| 44 | M6 GSUB 上下文替换 | 深度上限 | `SvgGsubContextM6_test` | ✅ |
| 45 | M6 GSUB 上下文替换 | 不支持 format | `SvgGsubContextM6_test` | ✅ |
| 46 | M6 字号与装饰的交互 | 组合合成 | `SvgFontDetailsM6_test.combinedSynthesisAndTextLength/decorationThicknessFollowsFinalFontSize` | ✅ |
| 47 | M6 字号与装饰的交互 | textLength 兼容 | `SvgFontDetailsM6_test.combinedSynthesisAndTextLength/decorationThicknessFollowsFinalFontSize` | ✅ |
| 48 | M6 字号与装饰的交互 | 缺省不合成 | `SvgFontDetailsM6_test.combinedSynthesisAndTextLength/decorationThicknessFollowsFinalFontSize` | ✅ |

### svg-value-types

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | M6 交互与渲染提示枚举 | pointer-events 往返 | `SvgPointerEventsM6_test`、`SvgCursorM6_test`、`SvgRenderingHintsM6_test.hintValues` | ✅ |
| 2 | M6 交互与渲染提示枚举 | 大小写不敏感 | `SvgPointerEventsM6_test`、`SvgCursorM6_test`、`SvgRenderingHintsM6_test.hintValues` | ✅ |
| 3 | M6 交互与渲染提示枚举 | 未知值 | `SvgPointerEventsM6_test`、`SvgCursorM6_test`、`SvgRenderingHintsM6_test.hintValues` | ✅ |
| 4 | M6 交互与渲染提示枚举 | 渲染提示字符串 | `SvgPointerEventsM6_test`、`SvgCursorM6_test`、`SvgRenderingHintsM6_test.hintValues` | ✅ |
| 5 | M6 字体与装饰值类型 | 关键字映射 | `SvgFontDetailsM6_test.fontStretchParsing/decorationLonghands/capsAndSizeAdjust` | ✅ |
| 6 | M6 字体与装饰值类型 | 百分比保留 | `SvgFontDetailsM6_test.fontStretchParsing/decorationLonghands/capsAndSizeAdjust` | ✅ |
| 7 | M6 字体与装饰值类型 | 非法百分比 | `SvgFontDetailsM6_test.fontStretchParsing/decorationLonghands/capsAndSizeAdjust` | ✅ |
| 8 | M6 字体与装饰值类型 | 装饰样式往返 | `SvgFontDetailsM6_test.fontStretchParsing/decorationLonghands/capsAndSizeAdjust` | ✅ |
| 9 | M6 根与视图值类型 | zoomAndPan 解析 | `SvgRootAttrsM6_test`、`SvgDomApiM6_test.viewState` | ✅ |
| 10 | M6 根与视图值类型 | 视图状态矩阵 | `SvgRootAttrsM6_test`、`SvgDomApiM6_test.viewState` | ✅ |
| 11 | M6 根与视图值类型 | 缺省视图状态 | `SvgRootAttrsM6_test`、`SvgDomApiM6_test.viewState` | ✅ |
| 12 | M6 值类型工厂方法 | 点工厂 | `SvgDomApiM6_test.factories` | ✅ |
| 13 | M6 值类型工厂方法 | 矩阵工厂 | `SvgDomApiM6_test.factories` | ✅ |
| 14 | M6 值类型工厂方法 | 变换工厂 | `SvgDomApiM6_test.factories` | ✅ |
| 15 | M6 矢量效果与连接枚举扩展 | 新矢量效果往返 | `SvgSvg2M6_test.vectorEffectValues/lineJoinValues` | ✅ |
| 16 | M6 矢量效果与连接枚举扩展 | 旧取值不变 | `SvgSvg2M6_test.vectorEffectValues/lineJoinValues` | ✅ |
| 17 | M6 矢量效果与连接枚举扩展 | 新连接值 | `SvgSvg2M6_test.vectorEffectValues/lineJoinValues` | ✅ |
| 18 | M6 矢量效果与连接枚举扩展 | 既有连接值 | `SvgSvg2M6_test.vectorEffectValues/lineJoinValues` | ✅ |

合计：**54 Requirement / 255 Scenario**，全部有可执行落点；无 `❌`。Requirement 级落点说明见上表，场景级断言由对应测试类/用例直接或间接覆盖。

## 2. CRITICAL 修复

| 编号 | 结论 | 证据 |
|---|---|---|
| C1 use 深度 | **已修复** | `SvgRenderTree` 使用独立 `useDepth`，文档嵌套深度不再混入；`SvgRenderTree_test.useExpansion` 与 60 层嵌套 + use 用例通过，65 层 use 链抛 `Limit`。 |
| C2 外部文档循环 | **已修复** | `SvgExternalDocumentM6_test.circularReference` / `circularReferenceThroughTwoIds` 完成渲染并 warning，不再 ERROR；`depthLimit` / `byteLimit` 仍抛 `Limit`。 |
| C3 GSUB Type 5/6 | **已落地** | `SvgGsubContext.cj` 解析/应用 format 3，深度 8 上限；`SvgGsubContextM6_test` 12 条用例覆盖单层、前后文、链式两层、覆盖越界、不支持的 format、嵌套连字、第 9 层停止、特性分组与渲染接线。 |
| C4 miter-clip / arcs | **已落地** | `SvgStrokeOutliner.addJoin` 在超限时按 `miterlimit × stroke-width / 2` 垂直截断；`SvgLineJoinM6_test` 断言截断端点、边界、arcs 半径与 round 覆盖差 ≤ 1/255；旧 join 分支未改。 |

## 3. WARNING 落地

| 编号 | 结论 | 证据 |
|---|---|---|
| W1 直接用例 | **已落地** | `SvgFontDetailsM6_test` 新增 5.3 stretch 合成、5.4 small-caps、5.5 OS/2 sxHeight、5.16 组合/装饰/textLength 用例；`SvgGsubContextM6_test.featureGroupingRespectsStyle` 覆盖 5.8 特性分组。 |
| W2 9 张 m6 快照 | **已落地** | `SvgSnapshotM6_test.cj` + `testdata/render/m6-*` 9 组 `.svg` / `.rgba`；`scenesExact` 与 `scenesAreDeterministic` 通过。 |
| W3 覆盖矩阵 | **本文件** | 上表 54 Requirement / 255 Scenario 逐条映射。 |
| W4 README_en | **已落地** | `README_en.md` 新增 7 个 M6 章节，与中文 README 的边界、上限、API 说明一致。 |
| W5 tasks 勾选 | **已落地** | `tasks.md` 按实际状态逐项勾选；1.1 分支改为 `feature/f_svg`，1.2 基线 997 已记录；9.5 因环境无 `openspec` CLI 保持未勾选，9.8 等待用户确认。 |

## 4. 结论

- **CRITICAL = 0**；C1–C4 全部关闭，W1–W5 全部落地（W5 的 9.5/9.8 属环境/流程边界，不计功能缺陷）。
- M6 新增用例未改变 M1–M5 默认路径：25 张既有快照逐字节一致，9 张 M6 快照确定性通过。
- `cjpm test` 0 error / 0 failed，`cjpm build` 成功且 `f_svg` 自身 0 warning。
