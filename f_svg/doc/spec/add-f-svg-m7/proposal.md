# add-f-svg-m7

## Why

M1–M6 的 `fountain::f_svg` 只覆盖「解析 + 渲染」：调用方要产出一个可被浏览器直接播放 SMIL 的 SVG，必须手工拼 XML 或绕过类型化模型，既容易漏掉 XML 声明与 `xmlns`，也无法复用既有的元素类型与安全转义。M7 补上生成侧的易用 API，让同一套 Cangjie 类型既能读也能写。

## What Changes

- **新增链式构建器 `SvgBuilder`**：以 `SvgBuilder(width, height)` 起步，支持 `group` / `end` 维护游标栈，十种形状与引用元素，样式与通用属性写入当前元素，动画追加到当前元素，`document()` / `toSvgString()` / `save(path)` 三种输出。
- **新增类型化动画元素**：`SvgAnimate`、`SvgAnimateTransform`、`SvgAnimateMotion`、`SvgSet`、`SvgMpath`，全部以 `setAttr` 写属性，属性值原样输出，不做生成侧校验。
- **新增 `SvgBegin` 表达式**：覆盖绝对偏移、时钟字符串、`id.begin` / `id.end`、`id.end±offset`、`id.repeat(n)`、事件名、`indefinite` 与 `literal`，并支持 `join` 生成分号列表。
- **新增四个枚举**：`SvgRestart`、`SvgAnimationFill`、`SvgAnimationTransformType`、`SvgMotionRotate`，只负责生成侧拼写。
- **新增 `.save(path)` 落盘**：把 `SvgWriter` 接到 `std.fs.File`，失败统一包装为 `SvgException(kind: Io)`。
- **兼容约束**：只新增文件、类型与方法；不修改既有源码、公开 API、`SvgTag` 注册表与 `SvgTimeline`；既有 1187 条用例零改动、零回归。

## Capabilities

### New Capabilities

- `svg-authoring`: SVG 生成侧的链式构建契约，包括构建器游标与结构、形状与样式写入、类型化动画元素、`begin` / `end` 表达式、生成枚举、XML 文本与文件输出，以及「不改变解析与时间轴」的兼容边界。

### Modified Capabilities

无。M7 的全部行为都属于新能力域；既有 `svg-document-model`、`svg-animation` 等能力的 REQUIREMENT 不变，解析既有文档时动画仍按通用元素处理，`SvgTimeline` 的采样语义不变。

## Impact

- **新增文件**（全部位于 `f_svg/src`，不新建模块、子包或第三方依赖）：
  - `SvgAuthoringBuilder.cj`（类 `SvgBuilder`）、`SvgAnimate.cj`、`SvgAnimateTransform.cj`、`SvgAnimateMotion.cj`、`SvgSet.cj`、`SvgBegin.cj`、`SvgAuthoringTypes.cj`；
  - 对应测试 `SvgBuilderM7_test.cj`、`SvgAnimateM7_test.cj`、`SvgBeginM7_test.cj`、`SvgAuthoringTypesM7_test.cj`。
- **设计文档偏差**：`f_svg/doc/f_svg-M7设计.md` §2 把构建器文件名写作 `SvgBuilder.cj`，但该文件已存在且承担解析期构建（`buildSvgDocument` / `fillSvgAttributes`）。为满足「不改既有源码」的硬约束，作者侧类 `SvgBuilder` 放入新文件 `SvgAuthoringBuilder.cj`，类名与全部公开签名保持设计原样。
- **公开 API 增量**：`SvgBuilder`、`SvgAnimate`、`SvgAnimateTransform`、`SvgAnimateMotion`、`SvgSet`、`SvgMpath`、`SvgBegin`、四个枚举；不修改任何既有类型、函数签名或枚举构造器。
- **兼容性**：不注册动画标签到 `SvgTag`，解析结果与 M6 一致；不修改 `SvgTimeline`，`sample(time)` 与 `animations()` 行为不变；既有 1187 条 `@TestCase` 不改一行。
- **验收锚点**：既有 1187 条用例全绿；新增用例覆盖设计 §8 的每一条验收项；`cjpm build` 后 `f_svg` 自身 0 warning；`openspec validate --strict` 通过。
