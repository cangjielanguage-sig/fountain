# f_svg M7 设计：SVG 生成 API

## 0. 定位

M1–M6 的 f_svg 是「解析 + 渲染」库；M7 只补**生成侧**的易用 API：

- 输入：Cangjie 代码中的链式调用；
- 输出：浏览器可直接渲染并播放 SMIL 动画的 `.svg` 文本 / 文件；
- 约束：**不改既有源码与公开 API**，只新增文件、类型、文档与测试。

M7 不实现 CSS 动画、脚本动画，也不改变 f_svg 自身的 `SvgTimeline` 采样能力。

## 1. 目标用法

```cangjie
SvgBuilder(width: 200.0, height: 100.0)
    .rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)
    .fill("#3366cc")
    .animate(
        attribute: "x",
        from: "10",
        to: "150",
        dur: "2s",
        begin: SvgBegin.offset(0.0),
        repeatCount: "indefinite"
    )
    .save("card.svg")
```

生成结果：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="200px" height="100px">
  <rect x="10px" y="30px" width="40px" height="40px" fill="#3366cc">
    <animate attributeName="x" from="10" to="150" dur="2s" begin="0s" repeatCount="indefinite"/>
  </rect>
</svg>
```

## 2. 新增内容（全部为新文件）

| 文件 | 职责 |
|---|---|
| `SvgBuilder.cj` | 链式文档构建器：形状、样式、分组、动画、输出 |
| `SvgAnimate.cj` | 类型化 `<animate>` |
| `SvgAnimateTransform.cj` | 类型化 `<animateTransform>` + 变换类型枚举 |
| `SvgAnimateMotion.cj` | 类型化 `<animateMotion>` + `<mpath>` + `rotate` 枚举 |
| `SvgSet.cj` | 类型化 `<set>` |
| `SvgBegin.cj` | `begin` / `end` 表达式构造（多值、偏移、repeat、事件、indefinite） |
| `SvgAuthoringTypes.cj` | `SvgRestart`、`SvgAnimationFill`、`SvgAnimationTransformType`、`SvgMotionRotate` |

不修改 `SvgTag`、`SvgTimeline`、`SvgParser`、`SvgWriter` 等既有文件。

## 3. `SvgBuilder` API 草案

```cangjie
public class SvgBuilder {
    public init(
        width: Float64,
        height: Float64,
        viewBox!: ?SvgViewBox = None
    )

    // 结构
    public func group(id!: ?String = None): SvgBuilder
    public func end(): SvgBuilder

    // 形状
    public func rect(x!: Float64 = 0.0, y!: Float64 = 0.0, width!: Float64, height!: Float64, rx!: ?Float64 = None, ry!: ?Float64 = None): SvgBuilder
    public func circle(cx!: Float64 = 0.0, cy!: Float64 = 0.0, r!: Float64): SvgBuilder
    public func ellipse(cx!: Float64 = 0.0, cy!: Float64 = 0.0, rx!: Float64, ry!: Float64): SvgBuilder
    public func line(x1!: Float64, y1!: Float64, x2!: Float64, y2!: Float64): SvgBuilder
    public func polyline(points!: String): SvgBuilder
    public func polygon(points!: String): SvgBuilder
    public func path(d!: String): SvgBuilder
    public func text(content!: String, x!: Float64 = 0.0, y!: Float64 = 0.0): SvgBuilder
    public func use(href!: String, x!: Float64 = 0.0, y!: Float64 = 0.0): SvgBuilder
    public func image(href!: String, x!: Float64, y!: Float64, width!: Float64, height!: Float64): SvgBuilder

    // 样式与通用属性（作用于当前元素）
    public func fill(paint: String): SvgBuilder
    public func stroke(paint: String): SvgBuilder
    public func strokeWidth(value: Float64): SvgBuilder
    public func opacity(value: Float64): SvgBuilder
    public func fillOpacity(value: Float64): SvgBuilder
    public func strokeOpacity(value: Float64): SvgBuilder
    public func transform(value: String): SvgBuilder
    public func attr(name: String, value: String): SvgBuilder
    public func id(value: String): SvgBuilder
    public func className(value: String): SvgBuilder

    // 动画（追加到当前元素）
    public func animate(
        attribute: String,
        from!: ?String = None,
        to!: ?String = None,
        by!: ?String = None,
        values!: ?Array<String> = None,
        dur!: ?String = None,
        begin!: ?SvgBegin = None,
        end!: ?SvgBegin = None,
        repeatCount!: ?String = None,
        repeatDur!: ?String = None,
        fill!: ?SvgAnimationFill = None,
        calcMode!: ?SvgCalcMode = None,
        keyTimes!: ?String = None,
        keySplines!: ?String = None,
        additive!: ?String = None,
        accumulate!: ?String = None,
        restart!: ?SvgRestart = None
    ): SvgBuilder
    public func animateTransform(
        attribute: String,
        transformType: SvgAnimationTransformType,
        from!: ?String = None,
        to!: ?String = None,
        by!: ?String = None,
        values!: ?Array<String> = None,
        dur!: ?String = None,
        begin!: ?SvgBegin = None,
        repeatCount!: ?String = None,
        fill!: ?SvgAnimationFill = None,
        restart!: ?SvgRestart = None
    ): SvgBuilder
    public func animateMotion(
        path!: ?String = None,
        mpath!: ?String = None,
        dur!: ?String = None,
        begin!: ?SvgBegin = None,
        repeatCount!: ?String = None,
        rotate!: ?SvgMotionRotate = None,
        keyPoints!: ?String = None,
        keyTimes!: ?String = None,
        fill!: ?SvgAnimationFill = None,
        restart!: ?SvgRestart = None
    ): SvgBuilder
    public func set(
        attribute: String,
        to: String,
        begin!: ?SvgBegin = None,
        restart!: ?SvgRestart = None
    ): SvgBuilder

    // 输出
    public func document(): SvgDocument
    public func toSvgString(options!: SvgWriteOptions = SvgWriteOptions()): String
    public func save(path: String): Unit
    public func save(path: Path): Unit
}
```

实现口径：

- 内部维护 `root` 与 `cursorStack`；`group()` 压栈，`end()` 弹栈；栈底为根。
- 形状方法创建既有类型（`SvgRect` / `SvgCircle` / `SvgPath` …）并 `appendChild`，同时把 `cursor` 指向新元素。
- 样式方法作用于 `cursor`，通过 `setAttr` 写呈现属性（不生成 `<style>`）。
- `text()` 追加文本节点，`content` 由 `SvgWriter` 负责转义。
- `save(path)` 使用 `std.fs.File.create` 打开后交给 `SvgWriter`；失败抛 `SvgException(kind: Io)`。
- 数值一律写为 `px`（`SvgLength(value, unit: Px)`），与既有输出习惯一致。

## 4. 类型化动画元素

```cangjie
public class SvgAnimate <: SvgElement {
    public init()
    public mut prop attributeName: ?String
    public mut prop from: ?String
    public mut prop to: ?String
    public mut prop by: ?String
    public mut prop values: ?String
    public mut prop dur: ?String
    public mut prop begin: ?SvgBegin
    public mut prop end: ?SvgBegin
    public mut prop repeatCount: ?String
    public mut prop repeatDur: ?String
    public mut prop fill: ?SvgAnimationFill
    public mut prop calcMode: ?SvgCalcMode
    public mut prop keyTimes: ?String
    public mut prop keySplines: ?String
    public mut prop additive: ?String
    public mut prop accumulate: ?String
    public mut prop restart: ?SvgRestart
}
```

`SvgAnimateTransform` 额外 `transformType: SvgAnimationTransformType`；`SvgAnimateMotion` 额外 `path` / `keyPoints` / `rotate: SvgMotionRotate` 与 `mpath(href)`（创建 `<mpath>` 子元素）；`SvgSet` 提供 `attributeName` / `to` / `begin` / `restart`。

约定：

- 所有属性通过 `setAttr` 写入，未知值原样输出，不在生成侧校验。
- `values` 是分号分隔字符串（与 SVG 属性一致），`keyTimes` / `keySplines` 同理。
- 动画元素只用于生成；**不注册到 `SvgTag.create`**，因此解析既有文档时动画仍是通用元素，行为不变。

## 5. `SvgBegin` 表达式

```cangjie
public class SvgBegin {
    public static func offset(seconds: Float64): SvgBegin
    public static func clock(value: String): SvgBegin          // "2s" / "500ms"
    public static func at(id: String, begin!: Bool = true): SvgBegin   // a.begin / a.end
    public static func after(id: String, offset: Float64 = 0.0): SvgBegin // a.end+1s
    public static func repeatOf(id: String, iteration: Int64): SvgBegin   // a.repeat(2)
    public static func event(name: String): SvgBegin           // click / mouseover
    public static func indefinite(): SvgBegin
    public static func literal(value: String): SvgBegin
    public func join(other: SvgBegin): SvgBegin                // 分号列表
    public func toString(): String
}
```

序列化规则：

| 表达式 | 输出 |
|---|---|
| `offset(0)` | `0s` |
| `clock("2s")` | `2s` |
| `at("a")` | `a.begin` |
| `at("a", begin: false)` | `a.end` |
| `after("a", 1.0)` | `a.end+1s` |
| `after("a", -0.5)` | `a.end-0.5s` |
| `repeatOf("a", 2)` | `a.repeat(2)` |
| `event("click")` | `click` |
| `indefinite()` | `indefinite` |
| `join(...)` | `0s; a.end+1s; click` |

## 6. 安全与兼容

- `SvgBuilder` 不访问网络、不读文件；`save` 只写调用方给定路径。
- 属性值由 `SvgWriter` 统一转义；不拼接原始 XML。
- 只新增公开类型与方法，不修改既有签名；既有 1187 条用例必须零改动、零回归。
- 生成侧写入的扩展 `begin` 形式（`a.end+1s`、`a.repeat(2)`）**只保证浏览器播放**；f_svg 的 `SvgTimeline` 仍按 M6 能力解析，遇到不支持形式会 warning（记录为已知限制）。

## 7. 不做

- CSS 动画 / 过渡 / `@keyframes`；
- 脚本动画与事件绑定；
- 自动布局、SVG 语法校验器；
- 把类型化动画元素接入解析器（会改动既有 `SvgTag` 行为）；
- 修改 f_svg 的时间轴以支持扩展 `begin` 形式。

## 8. 验收

- 生成字符串包含 XML 声明与 `xmlns`；
- 生成的 `rect + animate`、`animateTransform`、`animateMotion + mpath`、`set` 均能被 `SvgParser` 重新解析，且结构与属性一致；
- `save(path)` 写出的文件可被重新解析；
- `begin` 多值、`a.end+1s`、`a.repeat(2)`、`restart` 序列化与浏览器语法一致；
- 既有 1187 条用例零回归；`f_svg` 构建 0 warning。
