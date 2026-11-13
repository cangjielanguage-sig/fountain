# add-f-svg-m7 验证记录

> 验证命令均在 `f_svg/` 下执行。基线：M6 结束时 209 个 `@Test` 类、1187 条 `@TestCase`。

## 1. 基线（任务 1.2 / 1.3）

| 项 | 命令 | 结果 |
|---|---|---|
| 单元测试 | `cjpm test` | `TOTAL: 1187`、`PASSED: 1187`、`SKIPPED: 0`、`ERROR: 0`、`FAILED: 0`；测试耗时约 87.9s，命令实际耗时 1m48s |
| 构建 | `cjpm build` | `cjpm build success`；`f_svg/src` 0 warning。编译器共打印 22 条 warning，全部来自依赖模块 `f_xml` / `f_base`，与 M7 无关 |

### 1.1 分支与工作区

- 分支：`feature/f_svg`（与前序里程碑一致，未新建分支、未使用 `git worktree`）。
- 开工时 `git status --short` 为空。

### 1.2 已裁决偏差

见 `tasks.md` 末尾「已裁决偏差与不做清单」：D1 文件名冲突落到 `SvgAuthoringBuilder.cj`；D9 `save` 失败使用 `SvgErrorKind.InvalidValue`。

## 2. 最终验收（任务 7.1 / 7.2 / 7.3 / 7.6）

| 项 | 命令 | 结果 |
|---|---|---|
| 全量单元测试 | `cjpm test` | `TOTAL: 1226`、`PASSED: 1226`、`SKIPPED: 0`、`ERROR: 0`、`FAILED: 0`。其中既有 1187 条零改动，M7 新增 39 条 |
| 构建 | `cjpm build` | `cjpm build success`；`f_svg/src` 0 warning；22 条 warning 仍全部来自 `f_xml` / `f_base` |
| 兼容边界 | `git diff --stat c41a0847 -- f_svg/src` | 仅 11 个新增文件（实现 7 个、测试 4 个），既有源码 0 改动 |
| 规格校验 | `openspec validate add-f-svg-m7 --strict` | `Change 'add-f-svg-m7' is valid` |

`@Test` 类从 209 增至 213：新增 `SvgBeginM7_test`、`SvgAuthoringTypesM7_test`、`SvgAnimateM7_test`、`SvgBuilderM7_test`。

## 3. Requirement / Scenario 到测试的映射

### Requirement: 链式构建器的根与游标

| Scenario | 测试类.方法 |
|---|---|
| 根尺寸与 viewBox | `SvgBuilderM7_test.rootSizeAndViewBox` |
| 分组嵌套与回退 | `SvgBuilderM7_test.groupScenarioWithShapes`、`groupNestingAndEnd` |
| 根级 end 无副作用 | `SvgBuilderM7_test.endAtRootIsNoop` |

### Requirement: 形状、文本与引用元素写入

| Scenario | 测试类.方法 |
|---|---|
| 几何属性序列化 | `SvgBuilderM7_test.shapeGeometry` |
| 文本内容转义 | `SvgBuilderM7_test.textUseAndImage` |
| 引用元素 | `SvgBuilderM7_test.textUseAndImage` |

### Requirement: 样式与通用属性作用于当前元素

| Scenario | 测试类.方法 |
|---|---|
| 样式落在当前形状 | `SvgBuilderM7_test.styleMethods` |
| 分组样式 | `SvgBuilderM7_test.styleTargetsCurrentElementOnly` |
| 不生成 style 元素 | `SvgBuilderM7_test.stylesNeverCreateStyleElement` |

### Requirement: 类型化动画元素的属性映射

| Scenario | 测试类.方法 |
|---|---|
| animate 属性映射 | `SvgAnimateM7_test.attributeMapping` |
| animateTransform 追加类型 | `SvgAnimateM7_test.animateTransformTypeMapping` |
| animateMotion 与 mpath | `SvgAnimateM7_test.animateMotionAttributes`、`animateMotionMpath`、`SvgBuilderM7_test.animateMotionMpathConvenience` |
| set 元素 | `SvgAnimateM7_test.setElementAttributes` |

补充覆盖：`SvgAnimateM7_test.unknownValuesPassThrough`（未知 `calcMode` 原样输出）、`beginAndEndAttributes`（可空 `begin` / `end` 与清除）。

### Requirement: 动画元素不进入解析注册表

| Scenario | 测试类.方法 |
|---|---|
| 解析生成结果保持结构 | `SvgAnimateM7_test.generatedAnimationSurvivesParse` |
| 注册表不变 | `SvgAnimateM7_test.animationTagsStayUnknown` |

### Requirement: SvgBegin 表达式工厂

| Scenario | 测试类.方法 |
|---|---|
| 偏移与时钟 | `SvgBeginM7_test.offsetSeconds`、`clockValue` |
| id 引用 | `SvgBeginM7_test.atReference` |
| 重复与事件 | `SvgBeginM7_test.repeatEventIndefiniteAndLiteral` |

### Requirement: SvgBegin 序列化与多值列表

| Scenario | 测试类.方法 |
|---|---|
| 负偏移与零偏移 | `SvgBeginM7_test.afterOffset` |
| 多值列表 | `SvgBeginM7_test.joinKeepsOperandsImmutable` |
| join 不修改入参 | `SvgBeginM7_test.joinKeepsOperandsImmutable` |

### Requirement: 生成枚举的规范拼写

| Scenario | 测试类.方法 |
|---|---|
| restart 与 fill | `SvgAuthoringTypesM7_test.restartSpelling`、`animationFillSpelling` |
| 变换类型 | `SvgAuthoringTypesM7_test.transformTypeSpelling` |
| 运动旋转 | `SvgAuthoringTypesM7_test.motionRotateSpelling`、`motionRotateEquality` |

### Requirement: XML 文本输出契约

| Scenario | 测试类.方法 |
|---|---|
| 声明与命名空间 | `SvgBuilderM7_test.toSvgStringContract` |
| 缩进选项 | `SvgBuilderM7_test.toSvgStringContract` |
| 浏览器可播放 | `SvgBuilderM7_test.designExampleEndToEnd`、`animationMethodsAppendToCursor` |

补充覆盖：`SvgBuilderM7_test.unitsAndEscaping`（无单位透明度、`px` 描边、属性转义与重解析）。

### Requirement: 文件落盘

| Scenario | 测试类.方法 |
|---|---|
| 落盘可重解析 | `SvgBuilderM7_test.saveWritesParseableFile` |
| 写入失败 | `SvgBuilderM7_test.saveFailureWrapsAsInvalidValue` |

### Requirement: 生成侧兼容边界

| Scenario | 验证方式 |
|---|---|
| 既有用例零改动 | `git diff --stat c41a0847 -- f_svg/src` 显示既有文件 0 改动；`cjpm test` 中 1187 条全部通过 |
| 扩展 begin 不破坏时间轴 | `SvgBuilderM7_test.extendedBeginKeepsTimelineStable` |

## 4. 已知限制

- `SvgTimeline` 仍按 M6 规则解析 `begin`；`a.end+1s`、`a.repeat(2)` 等扩展形式只保证浏览器播放，采样时记录 warning 后忽略。测试断言具体 warning 文本（分别含 `a.end+1s` / `a.repeat(2)`）、`animations().size == 3` 与 `duration() > 0`。
- 生成侧不校验属性合法性；`values` / `keyTimes` / `keySplines` 按分号字符串原样保存。
- 默认输出为紧凑格式；设计文档 §1 的缩进示例是可读性示意，需要缩进时显式传 `SvgWriteOptions(indent: Some("  "))`。

## 5. 文档示例核对

- `README.md` / `README_en.md` 的 M7 链式示例与 `SvgBuilderM7_test.designExampleEndToEnd` 使用同一组参数（`rect(x:10, y:30, width:40, height:40)`、`fill("#3366cc")`、`animate(attribute:"x", from:"10", to:"150", dur:"2s", begin: offset(0.0), repeatCount:"indefinite")`），示例输出已被该用例断言并落盘重解析。
- `CHANGELOG` 顶部新增 2026-11-08 条目，记录 M7 新增类型、输出能力与文档更新。

## 6. 校验 WARNING 修复

| 编号 | 结论 | 处理 |
|---|---|---|
| W-1 动画元素重解析覆盖 | 已修复 | 新增 `SvgAnimateM7_test.generatedAnimationElementsSurviveParse`：`animateTransform` / `animateMotion + mpath` / `set` 均走 `writeSvgString → SvgParser.parse` 并断言标签、父子结构与关键属性 |
| W-2 时间轴断言偏弱 | 已修复 | `extendedBeginKeepsTimelineStable` 改为断言 `a.end+1s` / `a.repeat(2)` 两条具体 warning、动画数 3、时长 > 0 |
| W-3 `mpath` 的 `href` | 记录边界 | README 中英与设计文档明确：`mpath` 固定输出裸 `href`（SVG 2 写法），`xlink` 选项不影响它 |
| W-4 构建器首参命名参数 | 记录偏差 | 设计文档补充：为使 `animate(attribute: "x")` 可编译，首参改为命名参数，行为不变 |
| W-5 替换 `mpath` 遗留父引用 | 已修复 | 改用 `removeChild` 删除旧 `mpath`，清空 `parent` 并发送 `ChildList` 事件；`animateMotionMpath` 断言旧引用 `parent.isNone()` |

修复后复跑：`cjpm test` **1226 / 1226 PASSED**，`f_svg` 0 warning；既有 1187 条仍零改动。
