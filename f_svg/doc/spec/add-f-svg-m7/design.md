# Design

## Context

M6 结束时 `f_svg` 的生成能力只有 `SvgWriter` / `writeSvgString`（`f_svg/src/SvgWriter.cj:216`）：调用方必须先手工搭出 `SvgDocument` 与 `SvgElement` 树，才能得到文本。既有的 `SvgBuilder.cj` 并不是作者侧构建器，而是解析期把 `f_xml` DOM 转成 `SvgDocument` 的内部函数集合（`buildSvgDocument`，`f_svg/src/SvgBuilder.cj:34`）。`SvgTag` 的已知标签表是封闭的（`f_svg/src/SvgTag.cj:79`），动画标签不在其中；`SvgTimeline` 独立解析 `begin` / `dur` / `repeatCount` 等属性。

M7 的约束决定了实现边界：

- 只新增文件、类型、文档与测试，不修改既有源码与公开 API；
- 不把动画元素注册进 `SvgTag`，不修改 `SvgTimeline`；
- 既有 209 个 `@Test` 类、1187 条 `@TestCase` 零改动；
- 生成的文本必须带 XML 声明与 `xmlns`，可被浏览器直接渲染并播放 SMIL。

设计文档 `f_svg/doc/f_svg-M7设计.md` 的 §2 文件表与 §3 API 草案是本次实现的主依据；与仓库现状冲突的两处以本文件的决策为准。

## Goals / Non-Goals

**Goals:**

- 用一次链式调用完成「根尺寸 → 形状 → 样式 → 动画 → 输出」；
- 生成侧复用既有模型类型、`setAttr` 与 `SvgWriter`，不另建 DOM 或序列化器；
- `begin` / `end` 表达式覆盖多值、偏移、repeat、事件与 `indefinite`，拼写符合 SVG 语法；
- 输出与落盘均可被 `SvgParser` 重新解析，结构与属性一致。

**Non-Goals:**

- 不接入解析器与时间轴：动画标签仍是解析期的通用元素，扩展 `begin` 形式仍按 M6 规则 warning 后忽略；
- 不做 CSS 动画、脚本动画、`@keyframes`、事件绑定；
- 不做 SVG 语法校验器、自动布局或生成侧属性值过滤；
- 不改变 `SvgWriteOptions` 的默认值，也不默认美化输出。

## Decisions

### D1 作者侧构建器放入新文件 `SvgAuthoringBuilder.cj`

设计文档 §2 把构建器文件命名为 `SvgBuilder.cj`，但仓库中该文件已被解析期构建占用。若覆盖或改写它会直接违反「不改既有源码」。因此：

- 新文件：`f_svg/src/SvgAuthoringBuilder.cj`；
- 类名与公开签名：仍为设计文档中的 `public class SvgBuilder`，不额外加前缀；
- 解析期代码不动，二者靠文件与文档注释区分。

备选「把作者侧类命名成 `SvgAuthoringBuilder`」会让设计文档的目标用法（`SvgBuilder(...)`）失效，否决。

### D2 游标用「当前元素 + 父栈」，`end()` 在栈底为无操作

构建器内部持有 `root: SvgRoot`、`cursor: SvgElement` 与 `stack: ArrayList<SvgElement>`。`group()` 把当前游标压栈并把游标指向新 `SvgContainer(SvgContainerKind.Group)`；`end()` 弹栈并把游标指回父元素。

在栈底调用 `end()` 选择**无操作**而不是抛异常：链式 API 的调用方常在循环末尾统一 `end()`，抛异常会让正常用法变脆。备选「抛 `InvalidValue`」会让「多写一个 `end()`」成为运行期错误，且设计文档没有定义该错误，否决。

### D3 形状创建复用既有类型，`points` / `d` 原样写入

每个形状方法 `new` 既有类型（`SvgRect`、`SvgCircle`、`SvgEllipse`、`SvgLine`、`SvgPolyline`、`SvgPolygon`、`SvgPath`、`SvgText`、`SvgUse`、`SvgImage`），用类型化属性写长度，再 `appendElement` 并把游标指向新元素。

- 数值几何（`x` / `y` / `width` / `height` / `cx` / `cy` / `r` / `rx` / `ry` / `x1` / `y1` / `x2` / `y2`）统一构造 `SvgLength(value, unit: SvgLengthUnit.Px)`，序列化为 `10px`；
- `points` 与 `d` 是字符串输入，直接 `setAttr`，交给既有类型化 getter 与 `SvgWriter` 处理；
- `text(content)` 用 `appendText` 追加文本节点，转义由 `SvgWriter` 负责；
- `use` / `image` 走既有 `href` 属性，`SvgWriter` 的 `xlink` 选项决定最终写成 `href` 还是 `xlink:href`。

备选「用 `SvgTag.create(tag)` 统一创建」会在 `points` / `d` 上退化为字符串拼装，且拿不到类型化构造参数，否决。

### D4 样式写呈现属性，透明度保持无单位

`fill` / `stroke` / `transform` / `id` / `className`（写 `class`）直接 `setAttr`；`strokeWidth` 写 `SvgLength(value, unit: Px)`；`opacity` / `fillOpacity` / `strokeOpacity` 用 `formatSvgNumber`（`f_svg/src/SvgNumber.cj:32`）写无单位数值。

SVG 的 `opacity` 系列不接受长度单位，若统一写 `px` 会产生非法值并让浏览器忽略；这是对设计文档「数值一律写为 px」的必要例外，记录于此。样式方法不生成 `<style>`，避免引入 CSS 解析与级联路径。

### D5 动画元素以原始属性为唯一事实源

`SvgAnimate`、`SvgAnimateTransform`、`SvgAnimateMotion`、`SvgSet`、`SvgMpath` 全部 `init()` 无参，属性以 `?String` / 枚举类型暴露，setter 调 `setAttr`，getter 读 `attr`。这与 `SvgElement` 的既有约定一致（`f_svg/src/SvgElement.cj:152`），也保证「未知值原样输出」。

- `values` / `keyTimes` / `keySplines` 是分号分隔字符串，不做拆分；
- `SvgAnimateTransform.transformType` 与 `SvgAnimateMotion.rotate` 是设计文档要求的非可空枚举属性；Cangjie 的非可空字段必须有初值，内部初值分别为 `Translate` 与 `Auto`，但构造时不写属性，只有 setter 被调用才落盘；
- `SvgAnimateMotion.mpath(href)` 创建 `SvgMpath` 子元素并返回该子元素；`SvgMpath` 只提供 `href`；
- 动画元素不注册到 `SvgTag`，因此 `SvgParser` 宽松模式仍会把它们当作未知元素保留标签与属性。

备选「动画元素继承 `SvgContainer` 并复用子元素表」会扩大既有类型语义，且 `mpath` 是唯一需要子元素的动画，否决。

### D6 `SvgBegin` 用不可变项列表，`join` 返回新实例

`SvgBegin` 内部只保存 `ArrayList<String>` 项；每个静态工厂返回新实例；`join` 复制两侧项后返回新实例，不修改入参。这样同一个 `SvgBegin` 可安全复用于多个动画，不会因一次 `join` 污染其他调用点。

数值格式化统一走 `formatSvgNumber`，因此 `offset(0.0)` 是 `0s`、`offset(1.5)` 是 `1.5s`，不会出现 `1.500000s`。`after` 的偏移为 0 时只输出 `id.end`，正负号只在非零时拼接，与 SVG 的 `id.end+1s` / `id.end-0.5s` 语法一致。`toString` 用 `"; "` 连接，兼顾可读性与 SVG 分号列表语法。

备选「用一个字符串从头拼到尾」无法在 `join` 时保证分隔符正确，也会让多值场景依赖调用顺序的字符串技巧，否决。

### D7 四个枚举手工实现 `==` 与 `toString`

`SvgRestart`、`SvgAnimationFill`、`SvgAnimationTransformType` 是无载荷枚举；`SvgMotionRotate` 需要同时表达 `auto`、`auto-reverse` 与固定角度，因此定义为 `Auto | AutoReverse | Fixed(Float64)`，`Fixed` 的 `toString` 走 `formatSvgNumber`。

Cangjie 的枚举 `==` 需要显式实现；四者都按仓库既有风格写 `operator func ==` 与 `toString()`，不依赖反射或 `Any` 比较。备选「`rotate` 用 `String` 承载」会丢掉类型化，且与设计文档的枚举要求不符，否决。

### D8 输出完全交给 `SvgWriter`，默认紧凑

`document()` 返回 `SvgDocument(root)`；`toSvgString(options!)` 等价于 `writeSvgString(document(), options)`；`save` 先取同一文本再落盘。

XML 声明、`xmlns`、`xlink` 声明、转义与缩进都由 `f_xml::XmlWriter` 产生（`svg-document-model` 的「生成与选项」已保证根元素带 `xmlns`）。因此构建器不拼任何 XML 字面量。

默认参数按设计文档保持 `SvgWriteOptions()`，即紧凑输出；设计文档 §1 的缩进示例是**可读性示意**，不是默认字节契约。需要美化输出时调用方显式传 `SvgWriteOptions(indent: Some("  "))`，验收用例按「含声明与 `xmlns`、可重解析」断言，不绑定空白。

### D9 `save` 复用 `File.writeTo`，失败按既有口径包装

`save(path: Path)` 调用 `File.writeTo(path, text.toArray())`；`save(path: String)` 委托 `Path(path)`。捕获 `FSException` 后抛 `invalidValue("无法写入 SVG：${path}")`。

设计文档 §3 写「失败抛 `SvgException(kind: Io)`」，但 `SvgErrorKind` 是封闭枚举且没有 `Io`（`f_svg/src/SvgException.cj:21`）。新增构造器会修改既有公开 API、并让下游穷尽 `match` 编译失败，与硬约束冲突。仓库已有同类先例：`SvgBitmap.savePng` 捕获 `FSException` 后抛 `invalidValue`（`f_svg/src/SvgBitmap.cj:173`）。M7 沿用该口径，`kind` 为 `InvalidValue`，消息保留路径。

### D10 兼容性靠「不接线」而非开关

作者侧类型不进入 `SvgTag`、不进入 `SvgTimeline`、不被 `SvgParser` 特判，因此既有解析、渲染、采样路径完全没有新分支。新增测试全部落在新文件 `SvgBuilderM7_test.cj`、`SvgAnimateM7_test.cj`、`SvgBeginM7_test.cj`、`SvgAuthoringTypesM7_test.cj`，既有 1187 条 `@TestCase` 不改一行。

## Risks / Trade-offs

- **扩展 `begin` 形式与时间轴不一致** → 生成侧只保证浏览器播放；`SvgTimeline` 仍按 M6 规则 warning 后忽略。在 README 与 CHANGELOG 标注为已知限制，测试只断言「不抛异常 + 有 warning」。
- **原样输出可能生成非法 SVG** → 设计明确「生成侧不校验」；这换取与 `setAttr` 一致的可预测行为。测试只用合法输入断言字符串，不承诺替调用方兜底。
- **默认紧凑输出与设计示例观感不同** → 用显式 `indent` 的用例覆盖美化路径，避免把空白写进默认契约。
- **`SvgBuilder` 类名与解析期文件名同名造成阅读混淆** → 新文件用 `SvgAuthoringBuilder.cj`，类注释明确「作者侧」；解析期 `SvgBuilder.cj` 不动。
- **`SvgMotionRotate.Fixed` 的浮点格式** → 统一走 `formatSvgNumber`，避免 `45.000000` 之类输出；负角度与 0 度按同一函数处理。

## Migration Plan

纯增量公开 API，无数据迁移、无配置迁移、无回滚步骤。发布说明只需列出新增类型与「不改既有行为」的结论；下游若已自行拼 XML，可逐步迁移到 `SvgBuilder`，旧路径保持可用。
