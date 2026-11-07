# add-f-svg-m6 校验报告（verification）

- 校验对象：`openspec/changes/add-f-svg-m6`（proposal / design / tasks / 10 个 delta spec）与 `f_svg/src` 全部实现、测试。
- 校验基线：`feature/f_svg`；任务 1.2 记录的原始基线为 **997** 条用例，M6 完成后为 **1137** 条，第二轮修复后为 **1178** 条，第三轮修复后为 **1186** 条。
- 校验方式：只读审阅 + 全量测试 + 构建 + 快照逐字节/哈希复核；未归档、未执行 `git worktree` 或改写 `.git`。
- 环境说明：工作树 `.git` 指向 `/storage/...`（实际挂载为 `/mnt/linux_share/storage/...`），git 读写使用显式 `GIT_DIR` / `GIT_WORK_TREE` 完成。

## 0. 门禁结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | `TOTAL: 1137 / PASSED: 1137 / SKIPPED: 0 / ERROR: 0 / FAILED: 0` | `f_svg/cjpm test`（2026-11-07） |
| 构建 | `cjpm build success`；`f_svg` 自身 **0 warning** | 重编译日志中 0 条 warning 指向 `f_svg/src`（依赖模块既有 warning 不计） |
| 既有快照 | M1–M5 **25/25** 逐字节一致 | 17 张 M1–M4 与 `doc/perf-baseline.md` 的 SHA-256 一致；8 张 M5 快照工作区无改动；`SvgSnapshotM6_test` 逐字节比对通过 |
| M6 快照 | 9/9 新增且重复渲染逐字节一致 | `SvgSnapshotM6Scenes_test.scenesExact/scenesAreDeterministic` |
| delta 规范规模 | **55 Requirement / 256 Scenario** | 10 个 `specs/*/spec.md` 标题计数 |
| CRITICAL | **0** | C1、C2 修复；C3、C4 落地并有直接用例 |

## 1. Requirement / Scenario 覆盖矩阵

口径：每个 Scenario 单列一行，场景名与 `specs/*/spec.md` 逐字一致；"落点"为直接断言或该 Requirement 的专用测试入口。所有列出的用例均在 **1186** 条全绿结果内（第三轮结束后）。

### svg-animation

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 时间模型 | 毫秒解析 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 2 | 时间模型 | id.begin | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 3 | 时间模型 | 重复次数 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 4 | 时间模型 | repeatDur 截断 | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 5 | 时间模型 | fill freeze | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 6 | 时间模型 | 事件型 begin | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
| 7 | 时间模型 | begin indefinite | `SvgAnimation_test`；`SvgAnimationControlM6_test.timeSource` | ✅ |
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
| 22 | M6 动画写入类型 | XML 默认 | `SvgAnimationControlM6_test.attributeTypeCss/attributeTypeInvalid` | ✅ |
| 23 | M6 动画写入类型 | CSS 写入 | `SvgAnimationControlM6_test.attributeTypeCss/attributeTypeInvalid` | ✅ |
| 24 | M6 动画写入类型 | 保留既有内联样式 | `SvgAnimationControlM6_test.attributeTypeCss/attributeTypeInvalid` | ✅ |
| 25 | M6 动画写入类型 | 非法值 | `SvgAnimationControlM6_test.attributeTypeCss/attributeTypeInvalid` | ✅ |
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
| 38 | M6 装饰长属性 | 简写展开 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry`；`SvgDecorationM6_test` | ✅ |
| 39 | M6 装饰长属性 | 组合线型 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry`；`SvgDecorationM6_test` | ✅ |
| 40 | M6 装饰长属性 | 缺省颜色 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry`；`SvgDecorationM6_test` | ✅ |
| 41 | M6 装饰长属性 | 非法样式 | `SvgFontDetailsM6_test.decorationLonghands/decorationGeometry`；`SvgDecorationM6_test` | ✅ |

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
| 10 | M6 变更监听 | 属性变更通知 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit/removeListenerByReference/namespacedAttributesNotify` | ✅ |
| 11 | M6 变更监听 | 子节点变更通知 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit/removeListenerByReference/namespacedAttributesNotify` | ✅ |
| 12 | M6 变更监听 | 上限 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit/removeListenerByReference/namespacedAttributesNotify` | ✅ |
| 13 | M6 变更监听 | 异常隔离 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit/removeListenerByReference/namespacedAttributesNotify` | ✅ |
| 14 | M6 变更监听 | 移除 | `SvgDomApiM6_test.mutationListeners/listenerExceptionIsolated/listenerLimit/removeListenerByReference/namespacedAttributesNotify` | ✅ |
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
| 1 | M6 命中测试 | 顶层优先 | `SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` | ✅ |
| 2 | M6 命中测试 | 设备坐标换算 | `SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` | ✅ |
| 3 | M6 命中测试 | 空文档 | `SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` | ✅ |
| 4 | M6 命中语义 | pointer-events: none | `SvgHitTestM6_test.visibilityCombinations/allUsesGeometry/autoEqualsVisiblePainted/fillVersusStroke/boundingBox/textHit/rootNonePrunes` | ✅ |
| 5 | M6 命中语义 | 仅描边命中 | `SvgHitTestM6_test.visibilityCombinations/allUsesGeometry/autoEqualsVisiblePainted/fillVersusStroke/boundingBox/textHit/rootNonePrunes` | ✅ |
| 6 | M6 命中语义 | bounding-box | `SvgHitTestM6_test.visibilityCombinations/allUsesGeometry/autoEqualsVisiblePainted/fillVersusStroke/boundingBox/textHit/rootNonePrunes` | ✅ |
| 7 | M6 命中语义 | 隐藏元素 | `SvgHitTestM6_test.visibilityCombinations/allUsesGeometry/autoEqualsVisiblePainted/fillVersusStroke/boundingBox/textHit/rootNonePrunes` | ✅ |
| 8 | M6 命中语义 | auto 等价 visiblePainted | `SvgHitTestM6_test.visibilityCombinations/allUsesGeometry/autoEqualsVisiblePainted/fillVersusStroke/boundingBox/textHit/rootNonePrunes` | ✅ |
| 9 | M6 pathLength 校准 | 校准比例 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 10 | M6 pathLength 校准 | 斜率相同 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 11 | M6 pathLength 校准 | 非法值 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 12 | M6 pathLength 校准 | 缺失属性 | `SvgFontDetailsM6_test.pathLengthRatio/pathLengthDashRendering/textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 13 | M6 矢量效果几何语义 | 去缩放 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` | ✅ |
| 14 | M6 矢量效果几何语义 | 去旋转 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` | ✅ |
| 15 | M6 矢量效果几何语义 | 固定位置 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` | ✅ |
| 16 | M6 矢量效果几何语义 | 组合顺序 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` | ✅ |
| 17 | M6 矢量效果几何语义 | 既有值不受影响 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` | ✅ |

### svg-paint-and-clip

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 线性渐变 | 端点颜色 | `SvgGradientSampler_test` | ✅ |
| 2 | 线性渐变 | 中点插值 | `SvgGradientSampler_test` | ✅ |
| 3 | 线性渐变 | spreadMethod | `SvgGradientSampler_test` | ✅ |
| 4 | 线性渐变 | stop 乱序与越界 | `SvgGradientSampler_test` | ✅ |
| 5 | 线性渐变 | linearRGB 中点 | `SvgGradientSampler_test` | ✅ |
| 6 | M6 颜色插值模式 | 缺省不变 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline`、`SvgGradientColorSpaceM6_test` | ✅ |
| 7 | M6 颜色插值模式 | 线性光两端一致 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline`、`SvgGradientColorSpaceM6_test` | ✅ |
| 8 | M6 颜色插值模式 | 与滤镜独立 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline`、`SvgGradientColorSpaceM6_test` | ✅ |
| 9 | M6 颜色插值模式 | 继承 | `SvgRenderingHintsM6_test.linearRgbInterpolation/srgbUnchanged/linearRgbPipeline`、`SvgGradientColorSpaceM6_test` | ✅ |
| 10 | M6 颜色配置回退 | 缺省 | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty`、`SvgGradientColorSpaceM6_test.gradientColorProfileWarns` | ✅ |
| 11 | M6 颜色配置回退 | 已声明非 sRGB | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty`、`SvgGradientColorSpaceM6_test.gradientColorProfileWarns` | ✅ |
| 12 | M6 颜色配置回退 | 未声明名称 | `SvgRenderingHintsM6_test.colorProfileRendering/colorProfileProperty`、`SvgGradientColorSpaceM6_test.gradientColorProfileWarns` | ✅ |

### svg-rasterization

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 抗锯齿 | 斜边覆盖 | `SvgRasterizer_test` | ✅ |
| 2 | 抗锯齿 | 关闭抗锯齿 | `SvgRasterizer_test` | ✅ |
| 3 | 抗锯齿 | 解析档 | `SvgRasterizer_test` | ✅ |
| 4 | 抗锯齿 | optimizeSpeed 覆盖全局档位 | `SvgRasterizer_test` | ✅ |
| 5 | 抗锯齿 | 缺省不受影响 | `SvgRasterizer_test` | ✅ |
| 6 | join 与 dash 规则 | miter 截断 | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 7 | join 与 dash 规则 | miter-clip | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 8 | join 与 dash 规则 | arcs | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 9 | join 与 dash 规则 | dash 相位 | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 10 | join 与 dash 规则 | pathLength 影响 dash | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 11 | join 与 dash 规则 | 非法 pathLength | `SvgStrokeOutliner_test`、`SvgLineJoinM6_test`、`SvgFontDetailsM6_test.pathLengthDashRendering` | ✅ |
| 12 | M6 渲染提示到光栅参数 | shape geometricPrecision | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 13 | M6 渲染提示到光栅参数 | text optimizeSpeed | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 14 | M6 渲染提示到光栅参数 | text optimizeLegibility | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 15 | M6 渲染提示到光栅参数 | text geometricPrecision | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 16 | M6 渲染提示到光栅参数 | 渐变量化 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 17 | M6 渲染提示到光栅参数 | 继承范围 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |
| 18 | M6 渲染提示到光栅参数 | 缺省一致 | `SvgRenderingHintsM6_test.shapeRenderingPipeline/colorRenderingQuantization/combinedHintsStable`、`SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering` | ✅ |

### svg-render-pipeline

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 渲染选项扩展 | 既有调用不变 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 2 | 渲染选项扩展 | 选项校验 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 3 | 渲染选项扩展 | 空交互集合 | `SvgSnapshotM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 4 | use 展开 | 基本复用 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 5 | use 展开 | 引用 symbol | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 6 | use 展开 | 循环引用 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 7 | use 展开 | 外部文档 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 8 | use 展开 | 外部文档缺 provider | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 9 | use 展开 | 外部文档上限 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 10 | use 展开 | 外部文档不递归 | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion/externalDocumentForcesRemovePolicy/providerNoneCached` | ✅ |
| 11 | view 不参与默认渲染 | 默认渲染不变 | `SvgInitialViewM6_test.viewTargetIgnored` | ✅ |
| 12 | view 不参与默认渲染 | 单独渲染 view | `SvgInitialViewM6_test.viewTargetIgnored` | ✅ |
| 13 | M6 初始视图片段导航 | 命中 view | `SvgInitialViewM6_test` | ✅ |
| 14 | M6 初始视图片段导航 | 不带井号 | `SvgInitialViewM6_test` | ✅ |
| 15 | M6 初始视图片段导航 | 未命中 | `SvgInitialViewM6_test` | ✅ |
| 16 | M6 初始视图片段导航 | 缺省 | `SvgInitialViewM6_test` | ✅ |
| 17 | M6 foreignObject 注入渲染 | 注入位图 | `SvgForeignObjectM6_test` | ✅ |
| 18 | M6 foreignObject 注入渲染 | 缺 renderer | `SvgForeignObjectM6_test` | ✅ |
| 19 | M6 foreignObject 注入渲染 | renderer 返回空 | `SvgForeignObjectM6_test` | ✅ |
| 20 | M6 foreignObject 注入渲染 | 缺少尺寸 | `SvgForeignObjectM6_test` | ✅ |
| 21 | M6 foreignObject 注入渲染 | 不解析 XHTML | `SvgForeignObjectM6_test` | ✅ |
| 22 | M6 交互状态贯通 | hover 改变填充 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 23 | M6 交互状态贯通 | 级联优先级 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 24 | M6 交互状态贯通 | 非交互文档不变 | `CssInteractionM6_test`、`SvgStyleResolverM6_test`、`SvgHitTestM6_test.renderInteractionAndByteStability` | ✅ |
| 25 | M6 视图状态 | 缩放 | `SvgDomApiM6_test.viewState` | ✅ |
| 26 | M6 视图状态 | 平移 | `SvgDomApiM6_test.viewState` | ✅ |
| 27 | M6 视图状态 | 缺省 | `SvgDomApiM6_test.viewState` | ✅ |
| 28 | M6 自动尺寸 | 根自动宽度 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged`、`SvgAutoSizeM6_test` | ✅ |
| 29 | M6 自动尺寸 | 嵌套自动尺寸 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged`、`SvgAutoSizeM6_test` | ✅ |
| 30 | M6 自动尺寸 | 无法确定 | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged`、`SvgAutoSizeM6_test` | ✅ |
| 31 | M6 自动尺寸 | 未声明 auto | `SvgSvg2M6_test.autoSize/explicitSizeUnchanged`、`SvgAutoSizeM6_test` | ✅ |
| 32 | M6 矢量效果的矩阵应用 | 应用顺序 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.renderTreeWiring` | ✅ |
| 33 | M6 矢量效果的矩阵应用 | 父子累乘 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.renderTreeWiring` | ✅ |
| 34 | M6 矢量效果的矩阵应用 | 既有描边 | `SvgSvg2M6_test.vectorEffectMatrix/nonScalingStrokeUnaffected`、`SvgVectorEffectMultiM6_test.renderTreeWiring` | ✅ |

### svg-security

| # | Requirement | Scenario | 落点 | 状态 |
|---|---|---|---|---|
| 1 | 渲染期无外部访问 | 外部 CSS 引用 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 2 | 渲染期无外部访问 | 外部图片 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 3 | 渲染期无外部访问 | 未注入图片资源 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 4 | 渲染期无外部访问 | 注入 provider | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 5 | 渲染期无外部访问 | 动画不执行脚本 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 6 | 渲染期无外部访问 | 外部文档不递归加载 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 7 | 渲染期无外部访问 | foreignObject 不经库渲染 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test` | ✅ |
| 8 | M6 上限与降级 | 外部文档字节 | `SvgExternalDocumentM6_test.byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgAnimationControlM6_test.nestedDiscardWarns`、`SvgHitTestM6_test.boundaries/securityMaxElements` | ✅ |
| 9 | M6 上限与降级 | 特性条目上限 | `SvgExternalDocumentM6_test.byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgAnimationControlM6_test.nestedDiscardWarns`、`SvgHitTestM6_test.boundaries/securityMaxElements` | ✅ |
| 10 | M6 上限与降级 | 监听器上限 | `SvgExternalDocumentM6_test.byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgAnimationControlM6_test.nestedDiscardWarns`、`SvgHitTestM6_test.boundaries/securityMaxElements` | ✅ |
| 11 | M6 上限与降级 | discard 嵌套 | `SvgExternalDocumentM6_test.byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgAnimationControlM6_test.nestedDiscardWarns`、`SvgHitTestM6_test.boundaries/securityMaxElements` | ✅ |
| 12 | M6 上限与降级 | 命中测试规模 | `SvgExternalDocumentM6_test.byteLimit`、`SvgFontDetailsM6_test.fontFeatureParsing`、`SvgDomApiM6_test.listenerLimit`、`SvgAnimationControlM6_test.nestedDiscardWarns`、`SvgHitTestM6_test.boundaries/securityMaxElements` | ✅ |

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
| 8 | 文本装饰线 | 下划线像素 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 9 | 文本装饰线 | 组合装饰 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 10 | 文本装饰线 | 与填充同色 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 11 | 文本装饰线 | 沿路径旋转 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 12 | 文本装饰线 | 祖先传播 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 13 | 文本装饰线 | none 关闭 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 14 | 文本装饰线 | 独立颜色 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 15 | 文本装饰线 | 样式与厚度 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 16 | 文本装饰线 | 双线 | `SvgTextDecorationM4_test`、`SvgFontDetailsM6_test.decorationGeometry/decorationThicknessFollowsFinalFontSize`、`SvgDecorationM6_test` | ✅ |
| 17 | textPath 路径与起点 | 水平路径 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 18 | textPath 路径与起点 | 百分比起点 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 19 | textPath 路径与起点 | pathLength 校准起点 | `SvgTextPathLayout_test`、`SvgTextPathExtensionM4_test`、`SvgFontDetailsM6_test.textPathPathLength`、`SvgTextPathLengthM6_test` | ✅ |
| 20 | OpenType 字距调整 | kern 表配对 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 21 | OpenType 字距调整 | GPOS 优先 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 22 | OpenType 字距调整 | font-kerning none | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 23 | OpenType 字距调整 | 跨 tspan 不配对 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 24 | OpenType 字距调整 | 特性开关关闭 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 25 | OpenType 字距调整 | font-kerning 优先 | `SvgKernTableM5_test`、`SvgKerningLayoutM5_test` | ✅ |
| 26 | 标准连字 | fi 连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test`、`SvgFontFeatureApplyM6_test` | ✅ |
| 27 | 标准连字 | 最长匹配优先 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test`、`SvgFontFeatureApplyM6_test` | ✅ |
| 28 | 标准连字 | 深度上限 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test`、`SvgFontFeatureApplyM6_test` | ✅ |
| 29 | 标准连字 | 关闭常见连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test`、`SvgFontFeatureApplyM6_test` | ✅ |
| 30 | 标准连字 | 历史连字 | `SvgOpenTypeLayoutM5_test`、`SvgKerningLayoutM5_test`、`SvgFontFeatureApplyM6_test` | ✅ |
| 31 | M6 字体匹配与合成 | stretch 精确匹配 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio/sizeAdjustContinuesAfterMissingOs2`、`SvgFontStretchMatchM6_test` | ✅ |
| 32 | M6 字体匹配与合成 | 百分比合成 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio/sizeAdjustContinuesAfterMissingOs2`、`SvgFontStretchMatchM6_test` | ✅ |
| 33 | M6 字体匹配与合成 | small-caps | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio/sizeAdjustContinuesAfterMissingOs2`、`SvgFontStretchMatchM6_test` | ✅ |
| 34 | M6 字体匹配与合成 | font-size-adjust | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio/sizeAdjustContinuesAfterMissingOs2`、`SvgFontStretchMatchM6_test` | ✅ |
| 35 | M6 字体匹配与合成 | 缺少 OS/2 | `SvgFontDetailsM6_test.stretchSynthesisScalesGlyphAndAdvance/smallCapsUsesUppercaseGlyph/sizeAdjustUsesXHeightRatio/sizeAdjustContinuesAfterMissingOs2`、`SvgFontStretchMatchM6_test` | ✅ |
| 36 | M6 字体特性开关 | 默认开启 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle`、`SvgFontFeatureApplyM6_test` | ✅ |
| 37 | M6 字体特性开关 | none 关闭 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle`、`SvgFontFeatureApplyM6_test` | ✅ |
| 38 | M6 字体特性开关 | discretionary | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle`、`SvgFontFeatureApplyM6_test` | ✅ |
| 39 | M6 字体特性开关 | contextual | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle`、`SvgFontFeatureApplyM6_test` | ✅ |
| 40 | M6 字体特性开关 | 显式覆盖 | `SvgFontDetailsM6_test.featureMerge`、`SvgGsubContextM6_test.featureGroupingGatesContext/featureGroupingRespectsStyle`、`SvgFontFeatureApplyM6_test` | ✅ |
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

合计：**55 Requirement / 256 Scenario**（命中需求已拆为「命中测试」与「命中语义」），全部有可执行落点；无 `❌`。Requirement 级落点说明见上表，场景级断言由对应测试类/用例直接或间接覆盖。

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
| W3 覆盖矩阵 | **本文件** | 上表 55 Requirement / 256 Scenario 逐条映射。 |
| W4 README_en | **已落地** | `README_en.md` 新增 7 个 M6 章节，与中文 README 的边界、上限、API 说明一致。 |
| W5 tasks 勾选 | **已落地** | `tasks.md` 按实际状态逐项勾选；1.1 分支改为 `feature/f_svg`，1.2 基线 997 已记录；9.5 因环境无 `openspec` CLI 保持未勾选，9.8 等待用户确认。 |

## 4. 结论

- **CRITICAL = 0**；C1–C4 全部关闭，W1–W5 全部落地（W5 的 9.5/9.8 属环境/流程边界，不计功能缺陷）。
- M6 新增用例未改变 M1–M5 默认路径：25 张既有快照逐字节一致，9 张 M6 快照确定性通过。旧 M1–M5 用例并非逐字未改：`CssStyleSheet_test.cj`、`CssSelectorCascadeM5_test.cj`、`CssSelectorStructuralM5_test.cj` 把“不支持伪类”样本由 `:hover` 改为 `:active`（适配 M6 新增 hover 支持），`SvgKerningLayoutM5_test.cj` 的 `m5BuildLayoutTtf` 增加可选 `cmap` / `os2` 参数（纯扩展）；未削弱任何旧断言。
- `cjpm test` 0 error / 0 failed，`cjpm build` 成功且 `f_svg` 自身 0 warning。

---

# 第二轮修复验证（fix-plan-2）

- 基线：第一轮 `1137` 条用例；本轮结束 `1178` 条（新增 41 条）。
- 代码规模：`f_svg/src` 288 个源文件，其中 163 个 `*_test.cj`。
- 门禁：`cjpm test` **1178 / 1178 PASSED**；`cjpm build success`，`f_svg` 自身 **0 warning**（clean build 的 22 条 warning 全部来自 `f_base` / `f_xml`）。
- 约束：未运行 `git worktree`；未改写 `.git`；M1–M5 公开 API 语义未改，25 张快照逐字节一致。
- 规格同步（主流程）：三处冲突已修正（vector-effect 固定顺序、visible 语义、外部文档不递归），`svg-security` 的「深度 4 抛 Limit」条目与场景已删除；delta 规模由 54/255 调整为 **55 Requirement / 256 Scenario**。

## 1. CRITICAL 修复结果

| 编号 | 结论 | 实现落点 | 直接用例 |
|---|---|---|---|
| C1 命中 API | ✅ | `SvgHitTest.elementsAt/elementAt`（第三轮改为 `public static`），`hitTest` 转调同一核心 | `SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` |
| C2 装饰长属性 | ✅ | `resolveSvgDecorationStyle` + `appendSvgDecorationSegments`；style/color/thickness/underline-position 进入渲染 | `SvgDecorationM6_test` 8 条 |
| C3 text-rendering 容差 | ✅ | `svgTextTolerance` → 文本指令 `textTolerance` → 光栅容差 | `SvgTextToleranceM6_test.textToleranceFactors/textRenderingTolerance` |
| C4 textPath pathLength | ✅ | 真实排版传入 `actual/pathLength`，起点与字形弧长同步缩放 | `SvgTextPathLengthM6_test` |
| C5 渐变颜色空间 | ✅ | 采样读取渐变元素自身/祖先计算样式；非 sRGB profile warning | `SvgGradientColorSpaceM6_test` 3 条 |
| C6 vector-effect 多值 | ✅ | `vectorEffects()`、多值解析 warning、固定顺序应用 | `SvgVectorEffectMultiM6_test` 3 条 |
| C7 auto 尺寸 | ✅ | 单轴 viewBox 推导、无法确定 warning、嵌套 100% | `SvgAutoSizeM6_test` 5 条 |
| C8 外部文档不递归 | ✅ | 第二层外部引用 warning；`noRecursion` 用例 | `SvgExternalDocumentM6_test.noRecursion` |
| C9 auto=visiblePainted | ✅ | `svgHitRequiresVisible` 纳入 `Auto`；bounding-box 不越过 visibility | `SvgHitTestM6_test.autoEqualsVisiblePainted` |
| C10 变更事件契约 | ✅ | `SvgMutationKind` = `Attribute` / `ChildList` | `SvgDomApiM6_test.mutationListeners` |
| C11 监听器按引用移除 | ✅ | `SvgMutationHub.remove` 使用 `refEq`；监听器改为抽象类以承载引用相等 | `SvgDomApiM6_test.removeListenerByReference` |
| C12 font-stretch 匹配 | ✅ | `resolveDetailed` 返回实际 stretch；仅 100% 字体做合成缩放 | `SvgFontStretchMatchM6_test` 2 条 |
| C13 字体特性开关 | ✅ | Type 4 `liga`/`hlig` 选择与 `kern` 门禁 | `SvgFontFeatureApplyM6_test` 3 条 |

## 2. WARNING 落地

| 编号 | 结论 | 证据 |
|---|---|---|
| W1 根 pointer-events none | ✅ | `SvgHitTestM6_test.rootNonePrunes`；`svgHitCollect` 显式检查根 |
| W2 命中安全上限 | ✅ | `SvgHitTestM6_test.securityMaxElements`；文档重载缺省读 `parseOptions.security.maxElements` |
| W3 text 轮廓缺失 | ✅ | `SvgHitTestM6_test.textWithoutOutlineWarns`；不再回退 bbox |
| W4 嵌套 discard | ✅ | `SvgAnimationControlM6_test.nestedDiscardWarns` |
| W5 非法 attributeType | ✅ | `SvgAnimationControlM6_test.attributeTypeInvalid` |
| W6 min 断言 | ✅ | `SvgAnimationControlM6_test.minMax`；`min` 延长期间保持末帧 |
| W7 size-adjust 逐字体 | ✅ | `SvgFontDetailsM6_test.sizeAdjustContinuesAfterMissingOs2` |
| W8 命名空间属性通知 | ✅ | `SvgDomApiM6_test.namespacedAttributesNotify` |
| W9 visible 语义 | ✅ | design D2 改为“内区或描边几何，不要求 fill/stroke 非 none” |
| W10 CHANGELOG 计数 | ✅ | 更新为 1178 |
| W11 design 规模 | ✅ | 更新为 288 源文件 / 163 测试文件 |
| W12 规格冲突 | ✅ | 外部文档不递归、vector-effect 固定顺序已由主流程统一 |
| W13 覆盖矩阵/文件表/快照说明 | ✅ | 本文件 + design D18 文件清单 + 快照原因 |
| W14 特性 warning / foreignObject 上限 | ✅ | `featureWarningSurfacesInRenderer`、`pixelBudgetCheckedBeforeRenderer` |

## 3. SUGGESTION

| 编号 | 结论 | 证据 |
|---|---|---|
| S1 删除调试输出 | ✅ | `SvgAnimationControlM6_test` 不再含 `println` |
| S2 公开枚举解析 | ✅ | `SvgPointerEvents/ShapeRendering/TextRendering/ColorRendering/ColorInterpolation.fromName` 公开 |
| S3 LineJoin 字符串口径 | ✅ | `toString()` 统一为 `attrName()`（`miter-clip` / `arcs`） |
| S4 装饰死代码 | ✅ | 删除 `SvgTextDecorationSpec.outline`，`decorationGeometry` 改测共享分段函数 |

## 4. 快照变更

| 快照 | 处理 | 原因 |
|---|---|---|
| `m6-hit-queries` | 重新生成 | 场景加入 `rect:hover`，渲染前真实调用 `SvgHitTest.elementsAt` 并注入 `hoveredIds`；`SvgHitTestM6_test.snapshotDrivenByHitQuery` 断言查询结果改变像素 |
| `m6-color-interpolation` | 重新生成 | C5 后渐变元素自身的 `linearRGB` 生效，两条色带中点不再相同 |
| `m6-svg2` | 重新生成 | 为 `non-scaling-size` 增加祖先 `scale(2)`，使矩阵修正可见 |
| M1–M5 25 张 | 未改动 | `SvgSnapshotM5_test` / `SvgSnapshotM6_test` 逐字节通过 |

## 5. 更新后的 Requirement 覆盖矩阵

口径：Requirement 级；✅ 表示有真实调用链与可执行断言。Scenario 级细分沿用第 1 节矩阵并已由本轮新用例补强。

### svg-animation（6）

| Requirement | 状态 | 证据 |
|---|---|---|
| 时间模型 | ✅ | `SvgAnimation_test`、`SvgAnimationControlM6_test` |
| 采样快照 | ✅ | `SvgAnimationControlM6_test.m5SampleStability` |
| M6 动画触发与时间控制 | ✅ | `SvgAnimationControlM6_test.timeSource/pauseAndUnpause/fireEvent` |
| M6 动画写入类型 | ✅ | `attributeTypeCss`、`attributeTypeInvalid` |
| M6 活动时长钳制 | ✅ | `minMax`（含 min 延长断言） |
| M6 discard 快照移除 | ✅ | `discard`、`nestedDiscardWarns`、`SvgDiscardM6_test` |

### svg-css（9）

| Requirement | 状态 | 证据 |
|---|---|---|
| CSS 规则集解析 | ✅ | `CssStyleSheet_test`、`SvgRenderingHintsM6_test` |
| 选择器模型与匹配 | ✅ | `CssSelector*_test`、`CssInteractionM6_test` |
| M6 交互伪类求值 | ✅ | `CssInteractionM6_test` |
| M6 交互与光标属性 | ✅ | `SvgPointerEventsM6_test`、`SvgCursorM6_test` |
| M6 渲染提示属性注册 | ✅ | `SvgRenderingHintsM6_test.hintValues/invalidHintsWarn` |
| M6 颜色配置 | ✅ | `SvgRenderingHintsM6_test.colorProfile*` |
| M6 字体选择属性 | ✅ | `SvgFontDetailsM6_test`、`SvgFontStretchMatchM6_test` |
| M6 OpenType 特性属性 | ✅ | `featureMerge`、`SvgFontFeatureApplyM6_test` |
| M6 装饰长属性 | ✅ | `SvgDecorationM6_test`、`decorationLonghands` |

### svg-document-model（5）

| Requirement | 状态 | 证据 |
|---|---|---|
| 文档对象 | ✅ | `SvgRootAttrsM6_test`、`SvgDocumentApiM4_test` |
| M6 元素结构变更 | ✅ | `SvgDomApiM6_test.childMutations` |
| M6 变更监听 | ✅ | `mutationListeners`、`removeListenerByReference`、`namespacedAttributesNotify` |
| M6 命中查询 API | ✅ | `SvgDomApiM6_test.hitQueries`、新旧 `SvgHitTest` API |
| M6 discard 元素模型 | ✅ | `SvgDiscardM6_test` |

### svg-geometry（4）

| Requirement | 状态 | 证据 |
|---|---|---|
| M6 命中测试 | ✅ | `SvgHitTestM6_test.elementsAtSpecApi/elementsAtStaticApi` |
| M6 命中语义 | ✅ | `autoEqualsVisiblePainted`、`visibleFillAndPainted`、`boundingBox` |
| M6 pathLength 校准 | ✅ | `SvgTextPathLengthM6_test`、`pathLengthRatio` |
| M6 矢量效果几何语义 | ✅ | `SvgVectorEffectMultiM6_test.fixedApplicationOrder/renderTreeWiring` |

### svg-paint-and-clip（3）

| Requirement | 状态 | 证据 |
|---|---|---|
| 线性渐变 | ✅ | `SvgGradientSampler_test` |
| M6 颜色插值模式 | ✅ | `SvgGradientColorSpaceM6_test.gradientOwnInterpolation/inheritedFromGradientAncestor` |
| M6 颜色配置回退 | ✅ | `gradientColorProfileWarns` |

### svg-rasterization（3）

| Requirement | 状态 | 证据 |
|---|---|---|
| 抗锯齿 | ✅ | `SvgRasterizer_test` |
| join 与 dash 规则 | ✅ | `SvgLineJoinM6_test`、`SvgStrokeOutliner_test` |
| M6 渲染提示到光栅参数 | ✅ | `SvgRenderingHintsM6_test`、`SvgTextToleranceM6_test` |

### svg-render-pipeline（9）

| Requirement | 状态 | 证据 |
|---|---|---|
| 渲染选项扩展 | ✅ | `SvgSnapshotM6_test` |
| use 展开 | ✅ | `SvgRenderTree_test`、`SvgExternalDocumentM6_test.noRecursion` |
| view 不参与默认渲染 | ✅ | `SvgInitialViewM6_test` |
| M6 初始视图片段导航 | ✅ | `SvgInitialViewM6_test` |
| M6 foreignObject 注入渲染 | ✅ | `SvgForeignObjectM6_test`、`pixelBudgetCheckedBeforeRenderer` |
| M6 交互状态贯通 | ✅ | `CssInteractionM6_test`、`SvgHitTestM6_test` |
| M6 视图状态 | ✅ | `SvgDomApiM6_test.viewState` |
| M6 自动尺寸 | ✅ | `SvgAutoSizeM6_test` 5 条 |
| M6 矢量效果的矩阵应用 | ✅ | `SvgVectorEffectMultiM6_test.renderTreeWiring` |

### svg-security（2）

| Requirement | 状态 | 证据 |
|---|---|---|
| 渲染期无外部访问 | ✅ | `SvgExternalDocumentM6_test`（含 noRecursion） |
| M6 上限与降级 | ✅ | `byteLimit`、`listenerLimit`、`securityMaxElements`、`nestedDiscardWarns`、`pixelBudgetCheckedBeforeRenderer` |

### svg-text（9）

| Requirement | 状态 | 证据 |
|---|---|---|
| 文本布局 | ✅ | `SvgTextRenderer_test`、`SvgKerningLayoutM5_test` |
| 文本装饰线 | ✅ | `SvgDecorationM6_test` 8 条 + M4 像素用例 |
| textPath 路径与起点 | ✅ | `SvgTextPathLengthM6_test`、`SvgTextPathLayout_test` |
| OpenType 字距调整 | ✅ | `SvgKernTableM5_test`、`SvgFontFeatureApplyM6_test.featureKernZeroDisablesKerning` |
| 标准连字 | ✅ | `SvgOpenTypeLayoutM5_test`、`SvgFontFeatureApplyM6_test` |
| M6 字体匹配与合成 | ✅ | `SvgFontStretchMatchM6_test`、`sizeAdjust*` |
| M6 字体特性开关 | ✅ | `SvgFontFeatureApplyM6_test`、`featureWarningSurfacesInRenderer` |
| M6 GSUB 上下文替换 | ✅ | `SvgGsubContextM6_test` |
| M6 字号与装饰的交互 | ✅ | `SvgFontDetailsM6_test.combinedSynthesisAndTextLength` |

### svg-value-types（5）

| Requirement | 状态 | 证据 |
|---|---|---|
| M6 交互与渲染提示枚举 | ✅ | `SvgPointerEventsM6_test`、`SvgRenderingHintsM6_test`（`fromName` 已公开） |
| M6 字体与装饰值类型 | ✅ | `SvgFontDetailsM6_test` |
| M6 根与视图值类型 | ✅ | `SvgRootAttrsM6_test`、`SvgDomApiM6_test.viewState` |
| M6 值类型工厂方法 | ✅ | `SvgDomApiM6_test.factories` |
| M6 矢量效果与连接枚举扩展 | ✅ | `SvgSvg2M6_test.vectorEffectValues/lineJoinValues` |

**合计 55/55 Requirement ✅；256 条 Scenario 均有对应可执行断言。**

## 6. 结论

- 第一轮 13 项 CRITICAL 全部关闭；W1–W14、S1–S4 全部落地。
- 新增 41 条用例，`cjpm test` 1178 全绿；`cjpm build` 成功且 `f_svg` 0 warning。
- M1–M5 的 25 张快照逐字节一致；3 张 M6 快照因功能修正重新生成，原因见 §4。
- 说明：`svg-security` 的上限清单不含外部文档深度；`SVG_EXTERNAL_MAX_DEPTH` 与 `svgExternalDepthAllows` 仅保留为异常路径的防御性检查，外部文档不递归加载，正常渲染不会触达该分支。

---

# 第三轮修复验证（fix-plan-3）

- 基线：第二轮 **1178** 条用例；本轮结束 **1186** 条（新增 8 条）。
- 门禁：`cjpm test` **1186 / 1186 PASSED / 0 ERROR / 0 FAILED**；`cjpm build success`，`f_svg` 自身 **0 warning**（22 条 warning 全部来自 `f_base` / `f_xml`）。
- 约束：未运行 `git worktree`；未改写 `.git`；未修改 `M1–M5` 公开 API 语义；25 张 M1–M5 快照逐字节一致。
- 规格：本轮未修改 `specs/`（两份副本保持一致，仍为 **55 Requirement / 256 Scenario**）。

## 1. CRITICAL 修复结果

| 编号 | 结论 | 实现落点 | 直接用例 |
|---|---|---|---|
| N1 外部文档不递归 | ✅ | `SvgRenderTree.svgExternalParseOptions` 对外部文档强制 `unsafePolicy=Remove`、`allowExternalReferences=false`；`SvgParseOptions.externalDocumentMode` 使外部 `href` 绕过 `strict` 抛错分支，其余 `strict` 检查与安全上限沿用主文档 | `SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy`（`strict=true` 下 `Reject` / `Remove` / `Keep` 三策略，断言 provider 只调用一次、无异常、warning 存在） |

## 2. WARNING 落地

| 编号 | 结论 | 实现落点 | 直接用例 |
|---|---|---|---|
| W1 `pointer-events: all` | ✅ | `SvgHitTest.svgHitElementMatches` 移除 `all` 的包围盒短路；`svgHitWantsFill/Stroke` 将 `all` 纳入填充与描边几何，且不检查 `visibility` / 画笔 | `SvgHitTestM6_test.allUsesGeometry`（三角形包围盒内路径外不命中、`fill/stroke:none` 仍命中、`visibility:hidden` 仍命中） |
| W2 文本容差二次缩放 | ✅ | `SvgRenderer.drawPaint` 在存在 `textTolerance` 时直接使用该值，仅 `None` 时回退 `svgShapeTolerance` | `SvgTextToleranceM6_test.textToleranceIndependentOfShapeRendering`（`optimizeSpeed` 叠加 `geometricPrecision` 像素一致） |
| W3 wavy 开放折线填充 | ✅ | `SvgDecorationRun.wavy` 标记波浪线；`SvgDisplayCommand.strokeWidthOverride` 提供线宽覆盖；`SvgRenderer` 以 `StrokePath`、线宽=`thickness`、空 dash 绘制 | `SvgDecorationM6_test.wavyStrokeWidth`（波谷下方 1px 仅描边可达） |
| W4 stretch 非精确匹配 | ✅ | `applyFontStretchSynthesis` 以 `请求值 / 实际命中面 stretch` 缩放，仅 `percent == matched` 跳过 | `SvgFontStretchMatchM6_test.synthesisUsesMatchedStretch`（仅 75% 面请求 80%） |
| W5 `clig` 未参与替换 | ✅ | `SvgTrueTypeFont` 解析并保存 `clig` 表，`ligatureTableFor` 支持 `clig`；`applyFontLigatures` 在 `hlig` / `liga` 之后按 `clig` 选择 Type 4 表 | `SvgFontFeatureApplyM6_test.contextualLigatureFeature`（默认开启、`none` 与显式 `clig 0` 关闭） |
| W6 命中 API 形态 | ✅ | `elementsAt` / `elementAt` 改为 `public static func`，语料与快照调用点同步更新 | `SvgHitTestM6_test.elementsAtStaticApi`；`elementsAtSpecApi` 改为静态调用 |
| W7 provider `None` 未缓存 | ✅ | `SvgRenderTreeBuilder.missingExternalDocuments` 缓存负结果，同一 href 单次渲染只询问一次 | `SvgExternalDocumentM6_test.providerNoneCached`（两次 `use` → `calls == 1`） |
| W8 旧用例表述 | ✅ | 本文件“第一轮结论”改为“未削弱旧断言”，列明 `CssStyleSheet_test.cj`、`CssSelectorCascadeM5_test.cj`、`CssSelectorStructuralM5_test.cj`（`:hover`→`:active` 样本适配）与 `SvgKerningLayoutM5_test.cj`（`m5BuildLayoutTtf` 增加可选 `cmap`/`os2`） | 文档核对 |
| W9 design 深度残留 | ✅ | `design.md` D5 删除“深度 4 抛 `Limit`”，改为负结果缓存 + 强制 `Remove` + 深度常量仅防御；README / README_en 同步 | 文档核对 |
| W10 覆盖矩阵计数 | ✅ | 第 1 节矩阵按 spec 重新生成：`svg-security` 12、`svg-geometry` 17、`svg-render-pipeline` 34，总计 **256**，场景名逐字一致 | 第 1 节矩阵 |

## 3. 偏差与说明

- **W6 兼容入口**：仓颉禁止同名静态与实例方法混载（编译器报 `overloaded functions 'elementsAt' cannot mix static and non-static`），因此静态化后不再保留实例形态。`elementsAt` / `elementAt` 属 M6 新增 API，`M1–M5` 公开 API 与 `hitTest` 未受影响。
- **W7 负结果缓存**：命中负结果缓存后仍逐次产生“不可用”warning，但不再调用 provider。
- **外部文档深度**：`SVG_EXTERNAL_MAX_DEPTH` 与 `svgExternalDepthAllows` 仅作为异常路径的防御性检查保留；外部文档不递归加载，正常渲染不触达。
- **`strict` 边界**：`strict` 仍随外部文档解析选项保留；仅外部 `href` 通过内部 `externalDocumentMode` 绕过 `strict` 的抛错分支并按 `Remove` 处理，其他受限内容（脚本、事件属性、未知结构）仍受 `strict` 约束。

## 4. 回归与快照

| 项目 | 结果 | 证据 |
|---|---|---|
| 全量测试 | 1186 / 1186 PASSED | `f_svg/cjpm test` |
| 构建 | success；`f_svg` 0 warning | `f_svg/cjpm build` |
| 25 张 M1–M5 快照 | 逐字节一致 | 17 张 M1–M4 SHA-256 与 `doc/perf-baseline.md` 全部一致；8 张 M5 由 `SvgSnapshotM6_test.m5SnapshotsExact` 通过 |
| 本轮 testdata 变更 | 无 | `git diff --name-status 4e51fa29..HEAD -- f_svg/testdata/render` 为空 |
| M6 快照 | 9/9 未变且确定性通过 | `SvgSnapshotM6_test.scenesExact/scenesAreDeterministic` |

## 5. 结论

- **CRITICAL = 0**：N1 已关闭，`Reject` / `Remove` / `Keep` 三策略下外部文档均不再二次调用 provider、不抛 `Security` / `Limit`。
- W1–W10 全部落地；覆盖矩阵重新生成后为 **55 Requirement / 256 Scenario**（security 12 / geometry 17 / render-pipeline 34）。
- `cjpm test` 1186 全绿，`cjpm build` 成功且 `f_svg` 0 warning；25 张 M1–M5 快照逐字节一致。
