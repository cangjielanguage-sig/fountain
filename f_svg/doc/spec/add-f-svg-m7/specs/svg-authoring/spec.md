# svg-authoring

## Purpose

为 `fountain::f_svg` 提供从 Cangjie 代码生成 SVG 的公开契约：链式构建文档、写入形状与样式、追加类型化 SMIL 动画、构造 `begin` / `end` 表达式，并输出浏览器可直接渲染与播放的 XML 文本或文件。生成侧只新增类型与文件，不改变既有解析、渲染与时间轴语义。

## ADDED Requirements

### Requirement: 链式构建器的根与游标

系统 SHALL 提供 `SvgBuilder`，其构造参数为 `width`、`height` 与可选 `viewBox`，并生成一个 `svg` 根元素。`width` / `height` SHALL 以 `px` 写入；`viewBox` 存在时 SHALL 以既有 `SvgViewBox` 的规范形式写入。

`group(id!)` SHALL 追加一个 `g` 元素、把游标移入该组；`end()` SHALL 把游标退回父元素。游标栈栈底 SHALL 为根元素，在栈底调用 `end()` SHALL 无副作用且不抛异常。

#### Scenario: 根尺寸与 viewBox

- **WHEN** 构造 `SvgBuilder(200.0, 100.0, viewBox: SvgViewBox(0.0, 0.0, 200.0, 100.0))`
- **THEN** `document().root` 为 `svg`，`width="200px"`、`height="100px"`、`viewBox="0 0 200 100"`

#### Scenario: 分组嵌套与回退

- **WHEN** 依次调用 `group(id: "outer")`、`group()`、`rect(...)`、`end()`、`circle(...)`、`end()`
- **THEN** `rect` 位于内层 `g`，`circle` 位于 `outer` 组，根元素只有 `outer` 一个子元素

#### Scenario: 根级 end 无副作用

- **WHEN** 未调用 `group()` 就调用 `end()`
- **THEN** 不抛异常，后续 `rect(...)` 仍追加到根元素

### Requirement: 形状、文本与引用元素写入

系统 SHALL 提供 `rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`、`path`、`text`、`use`、`image` 十个构建方法。每个方法 SHALL 创建既有模型类型（`SvgRect`、`SvgCircle` 等）、追加到当前游标元素，并把游标指向新元素。

几何数值 SHALL 以 `px` 写入；`polyline` / `polygon` 的 `points` 与 `path` 的 `d` SHALL 按调用方传入的字符串原样写入。`text(content!)` SHALL 追加文本节点，文本内容 SHALL 由 `SvgWriter` 统一转义。

#### Scenario: 几何属性序列化

- **WHEN** 调用 `rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)`
- **THEN** 输出包含 `<rect x="10px" y="30px" width="40px" height="40px"`

#### Scenario: 文本内容转义

- **WHEN** 调用 `text(content: "a<b&c")`
- **THEN** 输出中的文本为 `a&lt;b&amp;c`，元素结构不被破坏

#### Scenario: 引用元素

- **WHEN** 调用 `use(href: "#r", x: 1.0, y: 2.0)` 与 `image(href: "a.png", x: 0.0, y: 0.0, width: 10.0, height: 10.0)`
- **THEN** 分别生成 `use` 与 `image` 元素，`href`、`x`、`y`、`width`、`height` 按规则写入

### Requirement: 样式与通用属性作用于当前元素

系统 SHALL 提供 `fill`、`stroke`、`strokeWidth`、`opacity`、`fillOpacity`、`strokeOpacity`、`transform`、`attr`、`id`、`className` 十个写入方法，全部作用于当前游标元素。

样式 SHALL 写成呈现属性，SHALL NOT 生成 `<style>` 元素或 CSS 规则。`fill` / `stroke` / `transform` / `id` / `class` 按传入字符串原样写入；`strokeWidth` SHALL 以 `px` 写入；`opacity` / `fillOpacity` / `strokeOpacity` SHALL 写为无单位数值。

#### Scenario: 样式落在当前形状

- **WHEN** 调用 `rect(...)` 后调用 `fill("#3366cc")`、`stroke("#000")`、`strokeWidth(2.0)`、`opacity(0.5)`
- **THEN** 这些属性出现在该 `rect` 上，`stroke-width="2px"`、`opacity="0.5"`

#### Scenario: 分组样式

- **WHEN** 调用 `group(id: "g")` 后调用 `fill("red")`
- **THEN** `fill="red"` 写在 `g` 上，不写给其子元素

#### Scenario: 不生成 style 元素

- **WHEN** 只使用样式方法构建文档
- **THEN** 生成的文档中不存在 `style` 元素

### Requirement: 类型化动画元素的属性映射

系统 SHALL 提供 `SvgAnimate`、`SvgAnimateTransform`、`SvgAnimateMotion`、`SvgSet` 与 `SvgMpath`，它们 SHALL 继承 `SvgElement` 并以 `setAttr` 写入属性。

属性名 SHALL 按 SVG 拼写映射：`attributeName`、`from`、`to`、`by`、`values`、`dur`、`begin`、`end`、`repeatCount`、`repeatDur`、`fill`、`calcMode`、`keyTimes`、`keySplines`、`additive`、`accumulate`、`restart`、`path`、`keyPoints`、`rotate`、`type`。`values` / `keyTimes` / `keySplines` SHALL 按分号分隔字符串原样保存；未知取值 SHALL 原样输出，生成侧 SHALL NOT 校验或改写。

#### Scenario: animate 属性映射

- **WHEN** 设置 `SvgAnimate` 的 `attributeName = "x"`、`from = "10"`、`to = "150"`、`dur = "2s"`、`repeatCount = "indefinite"`
- **THEN** 序列化为 `attributeName="x" from="10" to="150" dur="2s" repeatCount="indefinite"`

#### Scenario: animateTransform 追加类型

- **WHEN** 构建 `animateTransform(attribute: "transform", transformType: SvgAnimationTransformType.Rotate, from: "0", to: "360", dur: "1s")`
- **THEN** 生成 `animateTransform` 元素并带 `type="rotate"`

#### Scenario: animateMotion 与 mpath

- **WHEN** 调用 `animateMotion(mpath: "#p", dur: "2s")`
- **THEN** 生成 `animateMotion` 元素，其唯一子元素为带 `href="#p"` 的 `mpath`

#### Scenario: set 元素

- **WHEN** 调用 `set(attribute: "visibility", to: "hidden", begin: SvgBegin.offset(1.0))`
- **THEN** 生成 `set` 元素，带 `attributeName="visibility"`、`to="hidden"`、`begin="1s"`

### Requirement: 动画元素不进入解析注册表

动画标签 SHALL NOT 注册到 `SvgTag`：`SvgTag.isKnown("animate")`、`isKnown("animateTransform")`、`isKnown("animateMotion")`、`isKnown("set")`、`isKnown("mpath")` SHALL 返回 `false`。

解析既有文档时动画元素 SHALL 仍按通用元素保留标签与属性，解析结果与 M6 一致；`SvgTimeline` 的 `sample`、`animations`、`duration` 语义 SHALL NOT 因 M7 改变。

#### Scenario: 解析生成结果保持结构

- **WHEN** 把 `rect + animate` 的生成文本交给 `SvgParser` 宽松模式解析
- **THEN** 子元素标签仍为 `animate`，`attributeName` 等属性与生成时一致

#### Scenario: 注册表不变

- **WHEN** 查询 `SvgTag.isKnown` 的五个动画标签
- **THEN** 全部为 `false`

### Requirement: SvgBegin 表达式工厂

系统 SHALL 提供 `SvgBegin`，支持 `offset(seconds)`、`clock(value)`、`at(id, begin!)`、`after(id, offset!)`、`repeatOf(id, iteration)`、`event(name)`、`indefinite()`、`literal(value)` 与 `join(other)`。时间项 SHALL 只保存调用方输入，SHALL NOT 在生成侧解析、校验或改写。

#### Scenario: 偏移与时钟

- **WHEN** `SvgBegin.offset(0.0).toString()` 与 `SvgBegin.clock("500ms").toString()`
- **THEN** 分别为 `0s` 与 `500ms`

#### Scenario: id 引用

- **WHEN** `SvgBegin.at("a")`、`SvgBegin.at("a", begin: false)`、`SvgBegin.after("a", 1.0)`
- **THEN** 分别为 `a.begin`、`a.end`、`a.end+1s`

#### Scenario: 重复与事件

- **WHEN** `SvgBegin.repeatOf("a", 2)`、`SvgBegin.event("click")`、`SvgBegin.indefinite()`
- **THEN** 分别为 `a.repeat(2)`、`click`、`indefinite`

### Requirement: SvgBegin 序列化与多值列表

`toString()` SHALL 按 SVG 语法输出：偏移为秒数加 `s`；`at` 为 `id.begin` 或 `id.end`；`after` 为 `id.end` 拼接带符号秒数，零偏移省略符号；`repeatOf` 为 `id.repeat(n)`；`event` 与 `literal` 原样输出。

`join` SHALL 生成以 `"; "` 分隔的列表，参与项按调用顺序排列，且 SHALL NOT 修改任一入参。

#### Scenario: 负偏移与零偏移

- **WHEN** `SvgBegin.after("a", -0.5)` 与 `SvgBegin.after("a", 0.0)`
- **THEN** 分别为 `a.end-0.5s` 与 `a.end`

#### Scenario: 多值列表

- **WHEN** `SvgBegin.offset(0.0).join(SvgBegin.after("a", 1.0)).join(SvgBegin.event("click"))`
- **THEN** `toString()` 为 `0s; a.end+1s; click`

#### Scenario: join 不修改入参

- **WHEN** 同一个 `SvgBegin.offset(0.0)` 先后与两个不同表达式 `join`
- **THEN** 两次结果互不影响，原对象的 `toString()` 仍为 `0s`

### Requirement: 生成枚举的规范拼写

系统 SHALL 提供四个生成侧枚举，其字符串形式 SHALL 与 SVG 属性值一致：`SvgRestart` → `always` / `whenNotActive` / `never`；`SvgAnimationFill` → `remove` / `freeze`；`SvgAnimationTransformType` → `translate` / `scale` / `rotate` / `skewX` / `skewY`；`SvgMotionRotate` → `auto` / `auto-reverse` / 数值角度。

`SvgMotionRotate` SHALL 支持固定角度构造，固定角度的字符串形式 SHALL 为无单位数值。

#### Scenario: restart 与 fill

- **WHEN** 设置 `restart = SvgRestart.WhenNotActive`、`fill = SvgAnimationFill.Freeze`
- **THEN** 输出 `restart="whenNotActive"`、`fill="freeze"`

#### Scenario: 变换类型

- **WHEN** 设置 `transformType = SvgAnimationTransformType.SkewX`
- **THEN** 输出 `type="skewX"`

#### Scenario: 运动旋转

- **WHEN** 分别使用 `SvgMotionRotate.Auto`、`SvgMotionRotate.AutoReverse`、`SvgMotionRotate.Fixed(45.0)`
- **THEN** 分别输出 `rotate="auto"`、`rotate="auto-reverse"`、`rotate="45"`

### Requirement: XML 文本输出契约

`toSvgString(options!)` SHALL 通过既有 `SvgWriter` / `writeSvgString` 输出 UTF-8 文本。默认输出 SHALL 包含 XML 声明与 `xmlns="http://www.w3.org/2000/svg"`，SHALL NOT 由构建器自行拼接 XML。

`options` SHALL 为既有 `SvgWriteOptions`，其 `xmlDeclaration`、`indent`、`xlink` 等字段 SHALL 按既有语义生效。

#### Scenario: 声明与命名空间

- **WHEN** 对任意构建器调用 `toSvgString()`
- **THEN** 结果以 `<?xml version="1.0" encoding="UTF-8"?>` 开头，根元素带 `xmlns="http://www.w3.org/2000/svg"`

#### Scenario: 缩进选项

- **WHEN** 调用 `toSvgString(options: SvgWriteOptions(indent: Some("  ")))`
- **THEN** 输出按两空格缩进，且重新解析后的结构与紧凑输出一致

#### Scenario: 浏览器可播放

- **WHEN** 按设计示例构建 `rect + animate` 并输出
- **THEN** 结果包含 `animate` 元素及其 `attributeName`、`from`、`to`、`dur`、`begin`、`repeatCount`，浏览器无需额外声明即可播放 SMIL

### Requirement: 文件落盘

系统 SHALL 提供 `save(path: String)` 与 `save(path: Path)`，把与 `toSvgString()` 等价的 UTF-8 内容写入调用方给定路径，SHALL NOT 读取其他文件或访问网络。

落盘后的文件 SHALL 能被 `SvgParser` 重新解析，且元素结构、标签与属性与生成时一致。文件系统失败 SHALL 包装为 `SvgException`，其 `kind` SHALL 为既有 `SvgErrorKind.InvalidValue`（与 `SvgBitmap.savePng` 的落盘失败口径一致；M7 不新增 `SvgErrorKind` 构造器）。

#### Scenario: 落盘可重解析

- **WHEN** 调用 `save("target/m7-card.svg")` 后把该路径交给 `SvgParser.parse(path)`
- **THEN** 解析成功，根为 `svg`，`rect` 与 `animate` 的属性与生成时一致

#### Scenario: 写入失败

- **WHEN** 目标路径位于不存在的目录
- **THEN** 抛出 `SvgException`，`kind` 为 `InvalidValue`，消息包含目标路径

### Requirement: 生成侧兼容边界

M7 SHALL 只新增文件、类型与方法，SHALL NOT 修改既有公开 API、既有源码、`SvgTag` 注册表或 `SvgTimeline`。既有 1187 条 `@TestCase` SHALL 保持零改动并通过。

生成侧写入的扩展 `begin` 形式（`a.end+1s`、`a.repeat(2)`）只保证浏览器播放；`SvgTimeline` 遇到不支持的形式 SHALL 保持 M6 的 warning 与忽略语义，SHALL NOT 抛异常。

#### Scenario: 既有用例零改动

- **WHEN** 执行完整 `cjpm test`
- **THEN** 既有 1187 条用例全部通过，且其源码与 M6 基线逐字节一致

#### Scenario: 扩展 begin 不破坏时间轴

- **WHEN** 用 `SvgTimeline` 采样一个含 `begin="a.end+1s"` 的生成文档
- **THEN** 采样不抛异常，不支持的时间项按 M6 规则记录 warning 并忽略
