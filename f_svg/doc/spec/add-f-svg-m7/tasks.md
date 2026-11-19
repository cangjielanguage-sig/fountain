# 任务：add-f-svg-m7

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每组结束 `cjpm test` 必须全绿；每组独立提交，全部工作位于 `feature/f-svg-m7` 分支。
> M7 只新增文件；不修改既有源码与公开 API，不改 `SvgTag`、`SvgTimeline`、`SvgParser`、`SvgWriter`。
> 验证命令默认在 `f_svg/` 下执行；既有基线为 209 个 `@Test` 类、1187 条 `@TestCase`。

## 1. 准备与基线

- [x] 1.1 在现有 `feature/f_svg` 分支上继续（与前序里程碑一致，不新建分支、不使用 `git worktree`），确认 `git status --short` 为空
- [x] 1.2 运行 `cjpm test`，确认 `TOTAL: 1187 / PASSED: 1187 / FAILED: 0`，把耗时与结果记入 `verification.md` 基线小节
- [x] 1.3 运行 `cjpm build`，确认 `f_svg` 自身 0 warning，并记录基线
- [x] 1.4 通读 `doc/f_svg-M7设计.md`、本变更 `proposal.md` / `design.md` / `specs/svg-authoring/spec.md`，在本文件末尾列出「D1 文件名冲突、D9 错误 kind」两处已裁决偏差与「不做」清单
- [x] 1.5 只建立测试文件 `SvgBuilderM7_test.cj`、`SvgAnimateM7_test.cj`、`SvgBeginM7_test.cj`、`SvgAuthoringTypesM7_test.cj`（先不创建实现文件，避免无失败用例的生产代码）；`cjpm test` 仍为 1187 全绿

## 2. `SvgBegin` 与生成枚举

- [x] 2.1 先写 `SvgBeginM7_test.cj`：`offset(0.0)`→`0s`、`offset(1.5)`→`1.5s`、`clock("500ms")`→`500ms`、`at("a")`→`a.begin`、`at("a", begin: false)`→`a.end`；实现 `SvgBegin` 静态工厂与项列表后转绿
- [x] 2.2 先写 `after` 三态用例：`after("a", 1.0)`→`a.end+1s`、`after("a", -0.5)`→`a.end-0.5s`、`after("a", 0.0)`→`a.end`；实现符号与 `formatSvgNumber` 拼接后转绿
- [x] 2.3 先写 `repeatOf("a", 2)`→`a.repeat(2)`、`event("click")`→`click`、`indefinite()`→`indefinite`、`literal("5s")`→`5s`；实现后转绿
- [x] 2.4 先写 `join` 用例：`offset(0.0).join(after("a", 1.0)).join(event("click"))`→`0s; a.end+1s; click`，并断言 `join` 不修改任一入参（同一 `SvgBegin` 复用两次结果不变）；实现不可变项列表后转绿
- [x] 2.5 先写 `SvgAuthoringTypesM7_test.cj`：四个枚举的 `toString` 与 `==`，含 `SvgMotionRotate.Fixed(45.0)`→`45`、`Fixed(-0.5)`→`-0.5`、`Fixed(0.0)`→`0`；实现 `SvgRestart` / `SvgAnimationFill` / `SvgAnimationTransformType` / `SvgMotionRotate` 后转绿

## 3. 类型化动画元素

- [x] 3.1 先写 `SvgAnimateM7_test.cj`：十八个属性逐一映射到正确属性名，`values` / `keyTimes` / `keySplines` 原样保存，未知 `calcMode` 字符串原样输出；实现 `SvgAnimate` 后转绿
- [x] 3.2 先写 `SvgAnimate` 的 `begin` / `end` 属性用例：设置 `SvgBegin` 后序列化为 `begin="0s; a.end+1s"`，清空为 `None` 时属性被移除；实现可空属性与 `removeAttr` 后转绿
- [x] 3.3 先写 `SvgAnimateTransform` 用例：`transformType` 五种取值输出 `type="translate|scale|rotate|skewX|skewY"`，其余属性与 `SvgAnimate` 一致；实现后转绿
- [x] 3.4 先写 `SvgAnimateMotion` 与 `SvgMpath` 用例：`path` / `keyPoints` / `rotate` 映射，`mpath("#p")` 追加唯一子元素且 `href="#p"`；实现后转绿
- [x] 3.5 先写 `SvgSet` 用例：`attributeName` / `to` / `begin` / `restart` 映射，重复设置同名属性保持原位；实现后转绿
- [x] 3.6 先写注册表与解析边界用例：`SvgTag.isKnown` 对五个动画标签均为 `false`；把动画元素放进文档后 `writeSvgString` 再 `SvgParser.parse`（宽松模式），标签与属性快照一致；确认无需修改 `SvgTag` 即转绿

## 4. 构建器结构与形状

- [x] 4.1 先写 `SvgBuilderM7_test.cj` 的根用例：`SvgBuilder(200.0, 100.0)` 生成 `svg`、`width="200px"`、`height="100px"`；`viewBox` 传入后输出 `viewBox="0 0 200 100"`；实现根与 `document()` 后转绿
- [x] 4.2 先写 `group` / `end` 用例：两层嵌套的父子归属正确、根级 `end()` 无副作用、组内元素顺序与调用顺序一致；实现游标与父栈后转绿
- [x] 4.3 先写形状用例：`rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path` 的标签、几何属性与 `px` 单位；实现七个形状方法后转绿
- [x] 4.4 先写 `text` / `use` / `image` 用例：文本节点转义 `a<b&c`→`a&lt;b&amp;c`、`href` 与坐标尺寸正确；实现后转绿
- [x] 4.5 先写游标归属用例：`rect(...).fill("red")` 只写 `rect`，`group(...).fill("red")` 只写 `g`，形状之后的兄弟不继承属性；实现「游标指向新元素」语义后转绿

## 5. 构建器样式与通用属性

- [x] 5.1 先写样式用例：`fill` / `stroke` / `strokeWidth(2.0)`→`stroke-width="2px"` / `opacity(0.5)`→`opacity="0.5"` / `fillOpacity` / `strokeOpacity` / `transform` / `id` / `className`→`class`；实现十个方法后转绿
- [x] 5.2 先写单位与转义用例：透明度无单位、`strokeWidth` 带 `px`、`fill("url(#g)")` 原样、`attr("data-x", "a\"b")` 经 `SvgWriter` 转义；确认输出可重解析
- [x] 5.3 先写「不生成 style 元素」用例：只用样式方法构建文档，断言全文不含 `<style` 且属性都在元素上；实现后转绿

## 6. 构建器动画与输出

- [x] 6.1 先写动画追加用例：`animate(...)` / `animateTransform(...)` / `animateMotion(...)` / `set(...)` 追加到当前游标元素，`repeatCount` / `restart` / `fill` 正确落盘；实现四个方法后转绿
- [x] 6.2 先写 `animateMotion` 便捷用例：`mpath: "#p"` 自动生成 `mpath` 子元素，`path` 与 `mpath` 同时为空时不生成子元素；实现后转绿
- [x] 6.3 先写 `toSvgString` 用例：默认输出以 `<?xml version="1.0" encoding="UTF-8"?>` 开头、根带 `xmlns="http://www.w3.org/2000/svg"`；`options: SvgWriteOptions(indent: Some("  "))` 时按两空格缩进且重解析结构一致；实现后转绿
- [x] 6.4 先写 `save` 用例：`save("target/m7-card.svg")` 与 `save(Path("target/m7-card.svg"))` 内容一致、可被 `SvgParser.parse(path)` 重解析；写入不存在目录时抛 `SvgException` 且 `kind == InvalidValue`、消息含路径；实现后转绿
- [x] 6.5 先写设计文档 §1 端到端用例：`rect + animate(x, from 10, to 150, dur 2s, begin offset(0), repeatCount indefinite)` 的生成文本含全部属性，`SvgParser` 重解析后结构与属性一致；实现后用该用例收口
- [x] 6.6 更新 `f_svg/README.md` 与 `README_en.md` 的生成 API 章节：链式用法、形状/样式清单、动画元素与 `SvgBegin` 规则、`save` 语义、扩展 `begin` 的已知限制；更新 `CHANGELOG` 的新增条目；逐条执行文档示例，确认示例输出与正文一致

## 7. 兼容与整体验收

- [x] 7.1 运行完整 `cjpm test`，确认既有 1187 条与全部 M7 新增用例全绿、0 SKIPPED、0 ERROR
- [x] 7.2 运行 `cjpm build`，确认 `f_svg` 自身 0 warning
- [x] 7.3 用 `git diff --stat` 与 `git status --short` 核对：`f_svg/src` 下既有文件零改动，M7 改动只出现在新增文件、README/CHANGELOG 与本变更目录
- [x] 7.4 写 `SvgTimeline` 兼容用例：对含 `begin="a.end+1s"` 或 `a.repeat(2)` 的生成文档调用 `sample(t)` 不抛异常，并按 M6 规则产生 warning；确认未修改 `SvgTimeline`
- [x] 7.5 写 `verification.md`：逐条映射 `specs/svg-authoring/spec.md` 的 Requirement / Scenario 到测试类与方法，标注无遗漏；列出 1187 条基线零回归与 0 warning 的实测结果
- [x] 7.6 运行 `openspec validate add-f-svg-m7 --strict`，确认通过；修复所有 warning 后重跑

## Workflow follow-up

- 按项目评审要求完成代码审查与修复后，归档 `add-f-svg-m7` 并同步 `svg-authoring` 主规格。

## 已裁决偏差与不做清单

### 偏差 1：D1 文件名冲突

- 设计文档 §2 写 `SvgBuilder.cj`，但仓库中该文件已承担解析期 `buildSvgDocument`；为满足「不改既有源码」，作者侧 `public class SvgBuilder` 放入新文件 `SvgAuthoringBuilder.cj`，类名与公开签名保持设计原样。

### 偏差 2：D9 错误 kind

- 设计文档 §3 写 `save` 失败抛 `SvgException(kind: Io)`，但 `SvgErrorKind` 是封闭枚举且没有 `Io`；新增构造器会修改既有公开 API。M7 沿用 `SvgBitmap.savePng` 口径，抛 `SvgException(kind: InvalidValue)`，消息保留目标路径。

### 不做

- CSS 动画 / 过渡 / `@keyframes`；
- 脚本动画与事件绑定；
- 自动布局、SVG 语法校验器、生成侧属性值过滤；
- 把类型化动画元素注册进 `SvgTag` 或接入解析器；
- 修改 `SvgTimeline` 以支持扩展 `begin` 形式；
- 修改 `SvgWriteOptions` 默认值或默认美化输出。
