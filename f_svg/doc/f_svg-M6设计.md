# f_svg M6 —— 静态交互 / 嵌入 / 渲染提示 / 字体细节 / 动画 / DOM API / SVG 2 收尾

> 定位：M6 处理 M1–M5 之后剩余的非脚本类 SVG 能力，按 **P1 静态交互 → P2 文档与嵌入 → P3 渲染提示 → P4 文本与字体 → P6 动画 → P7 DOM API → P8 SVG 2** 顺序实施。
> 图像格式（JPEG/GIF/WebP/SVG-as-image）与 `mesh` / `hatch` 留 M7。
> 安全边界不变：`<script>`、`on*` 事件属性、事件监听、链接激活不做。

## 0. M6 特性清单

### P1 静态交互（无脚本）

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P1-1 | `pointer-events` | 解析全部 SVG 取值（`auto` / `none` / `visiblePainted` / `visibleFill` / `visibleStroke` / `visible` / `painted` / `fill` / `stroke` / `all` / `bounding-box`），提供命中测试语义 |
| M6-P1-2 | `cursor` | 解析并存入计算样式，供调用方读取；不产生 UI |
| M6-P1-3 | `:hover` / `:focus` | 通过 `SvgRenderOptions.hoveredIds` / `focusedIds` 静态求值，无事件循环 |

### P2 文档与嵌入

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P2-1 | `foreignObject` 注入渲染 | `SvgForeignObjectRenderer` 接口；默认不渲染并记 warning，不实现 XHTML |
| M6-P2-2 | 外部文档引用 | `SvgExternalDocumentProvider` 供 `use` 指向外部 SVG；深度 ≤ 4，字节上限 16 MiB |
| M6-P2-3 | `view` 片段导航 | `SvgRenderOptions.initialView`：按 `viewBox` + `preserveAspectRatio` 改变初始视口 |
| M6-P2-4 | `baseProfile` / `version` / `zoomAndPan` | 解析并暴露查询；`zoomAndPan` 只存值，不影响渲染 |

### P3 渲染提示与颜色

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P3-1 | `shape-rendering` | `auto` / `optimizeSpeed` / `crispEdges` / `geometricPrecision`，映射到 AA 与曲线容差 |
| M6-P3-2 | `text-rendering` | 映射到曲线容差与连字开关 |
| M6-P3-3 | `color-rendering` | `auto` / `optimizeSpeed` / `optimizeQuality`，当前影响渐变采样精度 |
| M6-P3-4 | `color-interpolation` | `auto` / `sRGB` / `linearRGB`，用于渐变插值 |
| M6-P3-5 | `@color-profile` 最小支持 | 解析声明与 `color-profile` 属性；仅 sRGB 生效，其他 profile 回退 sRGB + warning |

### P4 文本与字体细节

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P4-1 | `font-stretch` | 关键字与百分比，参与字体选择与合成拉伸 |
| M6-P4-2 | `font-variant` small-caps | 合成 small-caps：大写字形按 0.8 缩放 |
| M6-P4-3 | `font-size-adjust` | 按字体 x-height 比例修正字号 |
| M6-P4-4 | `font-feature-settings` | `"liga" 0` / `"kern" 0` 等 tag 透传到整形 |
| M6-P4-5 | `font-variant-ligatures` | `none` / `common-ligatures` / `discretionary-ligatures` / `historical-ligatures` / `contextual` |
| M6-P4-6 | `text-decoration` 长属性 | `-line` / `-style` / `-color` / `-thickness` + `text-underline-position` |
| M6-P4-7 | GSUB Type 5/6 子集 | Context / ChainContext format 3，链式 lookup 深度 ≤ 8 |
| M6-P4-8 | `pathLength` 校准 | 影响 `stroke-dasharray` / `stroke-dashoffset` 与 `textPath` 弧长 |

### P6 动画

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P6-1 | `begin="indefinite"` | `SvgTimeline.begin(id)` / `end(id)` 显式触发 |
| M6-P6-2 | 事件式 begin/end | `fireEvent(id, name)` 显式触发 `click` / `mouseover` / `accessKey` / `wallclock`；不接 UI 事件循环 |
| M6-P6-3 | 时间 API | `currentTime()` / `setCurrentTime(t)` / `pause()` / `unpause()` |
| M6-P6-4 | `attributeType` | `CSS` 写入样式覆盖层，`XML` 写属性 |
| M6-P6-5 | `min` / `max` | 活动时长钳制 |
| M6-P6-6 | `discard` | 时间到达后从采样快照移除元素 |

### P7 DOM API

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P7-1 | 命中测试查询 | `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` |
| M6-P7-2 | 工厂方法 | `createSVGPoint` / `createSVGMatrix` / `createSVGTransform` |
| M6-P7-3 | 视图状态 | `currentScale` / `currentTranslate`（`SvgViewState`，可选传给渲染） |
| M6-P7-4 | 变更观察者 | `SvgDocument.addMutationListener`，属性/子节点变更后通知 |

### P8 SVG 2 收尾（不含 mesh / hatch）

| 编号 | 特性 | 说明 |
|---|---|---|
| M6-P8-1 | `vector-effect` 扩展 | `non-scaling-size` / `non-rotation` / `fixed-position` |
| M6-P8-2 | `stroke-linejoin` 扩展 | `miter-clip` / `arcs` |
| M6-P8-3 | `width` / `height: auto` | 根与嵌套 `svg` 按内容包围盒确定尺寸 |

### M6 明确不做

- `<script>`、`on*` 属性、事件监听、链接激活；
- `foreignObject` 内部 XHTML 语义（只提供注入接口）；
- ICC 颜色变换（只有 `@color-profile` 解析与 sRGB 回退）；
- JPEG / GIF / WebP / SVG-as-image（M7）；
- `mesh` / `hatch` 渐变（M7）；
- GPU 后端。

## 1. 兼容性

- 未使用 M6 特性的文档输出与 M5 逐字节一致；
- `pointer-events` / `cursor` 只进计算样式，不改变绘制；
- `:hover` / `:focus` 在未提供 `hoveredIds` / `focusedIds` 时永不匹配，既有输出不变；
- `initialView` 缺省 `None`，不改变视口；
- `shape-rendering` / `text-rendering` / `color-rendering` / `color-interpolation` 缺省 `auto`，行为不变；
- `font-*` 新属性缺省值不改变既有字体选择；
- 动画新 API 不改变既有 `sample(time)` 行为；
- `SvgRenderOptions` 只新增带默认值字段。

## 2. P1 静态交互

### 2.1 `pointer-events`

```cangjie
public enum SvgPointerEvents {
    | Auto | None | VisiblePainted | VisibleFill | VisibleStroke | Visible
    | Painted | Fill | Stroke | All | BoundingBox
}
```

- 命中测试由 `SvgHitTest` 提供：输入设备坐标，返回最上层命中的元素列表；
- `visible*` 系列要求 `visibility != hidden`；`painted` 要求 `fill` / `stroke` 非 `none`；
- `bounding-box` 用包围盒命中，其余用路径/描边命中；
- `pointer-events: none` 的元素及其子树不参与命中。

### 2.2 `cursor`

- 解析为字符串并存入计算样式；非法值回退 `auto` + warning；
- 不加载光标资源、不产生 UI。

### 2.3 `:hover` / `:focus`

- `SvgRenderOptions.hoveredIds: Array<String> = []`、`focusedIds: Array<String> = []`；
- 选择器求值时，元素 `id` 在对应集合内即匹配；无 id 的元素永不匹配；
- `:focus` 仅匹配最内层聚焦元素（集合中的第一个匹配项）；
- 与 `:not()` 组合正常求值。

## 3. P2 文档与嵌入

### 3.1 `foreignObject`

```cangjie
public interface SvgForeignObjectRenderer {
    func render(
        element: SvgElement,
        width: Float64,
        height: Float64,
        options: SvgRenderOptions
    ): ?SvgBitmap
}
```

- `SvgRenderOptions.foreignObjectRenderer: ?SvgForeignObjectRenderer = None`；
- 提供时按其返回位图绘制到 `x/y/width/height`；返回 `None` 时按占位处理并 warning；
- 未提供时绘制透明占位 + warning（与 M4 `<image>` 语义一致）；
- 不解析 XHTML，调用方承担渲染与安全责任。

### 3.2 外部文档引用

```cangjie
public interface SvgExternalDocumentProvider {
    func resolveHref(href: String): ?Array<Byte>
}
```

- 仅 `use` 的外部 `href` 走该接口；解析为文档后按 `use` 规则实例化；
- 深度上限 4，单文档字节上限 16 MiB，超限 `Limit`；
- 循环引用 warning 并停止；
- 不联网、不读文件，provider 由调用方实现。

### 3.3 `view` 片段导航

- `SvgRenderOptions.initialView: ?String`，接受 `#id` 或 `id`；
- 命中 `SvgView` 时，用其 `viewBox` / `preserveAspectRatio` 覆盖根视口；
- 未命中记 warning 并使用根 `viewBox`；
- `viewTarget` 只保留在模型中，不参与渲染。

### 3.4 `baseProfile` / `version` / `zoomAndPan`

- `SvgDocument.baseProfile()` / `version()` 返回根属性值（缺省 `None`）；
- `zoomAndPan` 解析为 `SvgZoomAndPan`（`Disable` / `Magnify`），存入文档查询 API，不影响渲染。

## 4. P3 渲染提示与颜色

### 4.1 `shape-rendering`

| 值 | 行为 |
|---|---|
| `auto` | 现状（超采样 / 解析 AA） |
| `optimizeSpeed` | 强制 1× 采样，关闭描边 AA |
| `crispEdges` | 关闭形状 AA，描边对齐像素中心 |
| `geometricPrecision` | 提高曲线扁平化精度（容差 ×0.25） |

### 4.2 `text-rendering`

- `optimizeSpeed`：关闭连字与字距，扁平化容差 ×2；
- `optimizeLegibility`：启用连字与字距，容差 ×0.5；
- `geometricPrecision`：容差 ×0.25；
- `auto`：按字体表能力。

### 4.3 `color-rendering`

- `optimizeSpeed`：渐变采样点减半；
- `optimizeQuality`：渐变采样点加倍；
- `auto`：现状。

### 4.4 `color-interpolation`

- `sRGB` / `auto`：现状（sRGB 空间插值）；
- `linearRGB`：渐变 stop 先转线性光，插值后转回 sRGB；
- 与滤镜的 `color-interpolation-filters` 独立。

### 4.5 `@color-profile`

- 解析 `@color-profile <name> { src: ... }`；
- `color-profile` 属性只接受 `auto` / `sRGB` / 已声明名称；
- 非 sRGB profile 记 warning 并按 sRGB 处理（不做 ICC 变换）。

## 5. P4 文本与字体

### 5.1 `font-stretch` / `font-variant` / `font-size-adjust`

- `font-stretch`：9 个关键字 + 百分比，匹配字体族时作为筛选条件；无匹配时按 100% 使用并可选合成水平缩放（仅当 `font-stretch` 为百分比时）；
- `font-variant: small-caps`：小写字母使用大写字形并缩放到 `0.8 × fontSize`；`normal` 不做处理；
- `font-size-adjust`：`adjustedSize = fontSize × (adjust / xHeightRatio)`，`xHeightRatio` 来自 TTF `OS/2.sxHeight / unitsPerEm`；缺失时忽略并 warning。

### 5.2 `font-feature-settings` / `font-variant-ligatures`

- `font-feature-settings: "liga" 0, "kern" 1` 解析为 tag 开关集合；
- `font-variant-ligatures: none` 关闭 `liga` / `clig`；`common-ligatures` 开启 `liga` / `clig`；`discretionary-ligatures` 开启 `dlig`；`historical-ligatures` 开启 `hlig`；`contextual` 开启 `calt`；
- 开关按优先级合并：`font-feature-settings` 覆盖 `font-variant-ligatures`；
- `kern` 开关与 `font-kerning` 合并，后者优先。

### 5.3 `text-decoration` 长属性

- `text-decoration-line`：`none` / `underline` / `overline` / `line-through` 组合；
- `text-decoration-style`：`solid` / `double` / `dotted` / `dashed` / `wavy`；
- `text-decoration-color`：颜色，缺省 `currentColor`；
- `text-decoration-thickness`：长度 / 百分比 / `auto`（`max(1, fontSize/14)`）；
- `text-underline-position`：`auto` / `under` / `above`；
- 简写 `text-decoration` 展开为上述长属性。

### 5.4 GSUB Type 5/6

- 支持 Context（Type 5）与 ChainContext（Type 6）的 format 3：覆盖表 + 回溯/输入/前瞻序列 + 替换 lookup 列表；
- 嵌套 lookup 深度 ≤ 8，超限停止并 warning；
- 只处理单字形替换与连字替换，不做多字形插入；
- 测试用合成字体构造两层链式替换。

### 5.5 `pathLength` 校准

- `pathLength` 存在时，路径的“声明长度”用于：
  - `stroke-dasharray` / `stroke-dashoffset` 按 `pathLength / actualLength` 缩放；
  - `textPath` 的 `startOffset` 与弧长按同一比例换算；
- `pathLength <= 0` 或非有限值 → 忽略 + warning。

## 6. P6 动画

### 6.1 触发 API

```cangjie
public class SvgTimeline {
    public func begin(animationId: String): Unit
    public func end(animationId: String): Unit
    public func fireEvent(animationId: String, event: String): Unit
    public func currentTime(): Float64
    public func setCurrentTime(time: Float64): Unit
    public func pause(): Unit
    public func unpause(): Unit
}
```

- `begin="indefinite"` 的动画在 `begin(id)` 前不活动；`begin(id)` 记录激活时刻；
- `fireEvent(id, "click")` 对 `begin="click"` 的动画等价于 `begin(id)`；
- `end(id)` 立即结束；
- `pause()` 冻结 `currentTime`，`unpause()` 继续。

### 6.2 `attributeType` / `min` / `max` / `discard`

- `attributeType="CSS"`：动画写入样式覆盖层（优先级高于样式表），采样快照中体现为计算样式变化；
- `attributeType="XML"`：写属性（默认）；
- `min` / `max`：活动区间钳制，`min > max` 时记 warning 并忽略；
- `discard`：在 `begin + dur` 后从快照移除目标元素；不支持 `discard` 的嵌套传播。

## 7. P7 DOM API

```cangjie
public class SvgDocument {
    public func getIntersectionList(rect: SvgBounds, reference: ?SvgElement = None): ArrayList<SvgElement>
    public func getEnclosureList(rect: SvgBounds, reference: ?SvgElement = None): ArrayList<SvgElement>
    public func checkIntersection(element: SvgElement, rect: SvgBounds): Bool
    public func checkEnclosure(element: SvgElement, rect: SvgBounds): Bool
    public func addMutationListener(listener: SvgMutationListener): Unit
    public func removeMutationListener(listener: SvgMutationListener): Unit
}
```

- 命中测试基于 `getBBox`；`pointer-events` 参与筛选；
- `getIntersectionList` 返回与矩形相交的元素，`getEnclosureList` 返回被矩形完全包含的元素；
- 工厂方法：`SvgPoint.create` / `SvgMatrix.create` / `SvgTransform.create`（静态工厂，不改变类型）；
- `SvgViewState`：`currentScale` / `currentTranslate`，可作为 `SvgRenderOptions.viewState` 传入；
- 变更监听在 `setAttr` / `removeAttr` / `appendChild` / `removeChild` / `insertBefore` 后同步通知；监听异常被捕获并记 warning，不影响文档。

## 8. P8 SVG 2 收尾

### 8.1 `vector-effect` 扩展

- `non-scaling-size`：变换只保留平移与旋转，不缩放几何；
- `non-rotation`：去除变换中的旋转分量；
- `fixed-position`：元素位置固定在设备空间，不随祖先变换移动；
- 三者可组合，按 `non-scaling-size → non-rotation → fixed-position` 顺序应用。

### 8.2 `stroke-linejoin` 扩展

- `miter-clip`：斜接超过 `miterlimit` 时截断而不是退化为 bevel；
- `arcs`：圆角连接，半径 = `stroke-width / 2`。

### 8.3 `width` / `height: auto`

- 根 `svg`：`auto` 时按内容包围盒 + `viewBox` 比例确定；
- 嵌套 `svg`：`auto` 时按父视口 100%；
- 两者都记一条 warning（尺寸不确定时）。

## 9. 模块布局

| 文件 | 职责 |
|---|---|
| `SvgPointerEvents.cj` / `SvgHitTest.cj` | `pointer-events` 与命中测试 |
| `SvgCursor.cj` | `cursor` 解析 |
| `SvgForeignObject.cj` | 注入式 `foreignObject` 渲染 |
| `SvgExternalDocument.cj` | 外部文档 provider 与 `use` 解析 |
| `SvgInitialView.cj` | `initialView` 视口覆盖 |
| `SvgRenderingHints.cj` | 三个 rendering 属性与 `color-interpolation` |
| `SvgColorProfile.cj` | `@color-profile` 解析与查询 |
| `SvgFontVariant.cj` | `font-stretch` / `small-caps` / `font-size-adjust` |
| `SvgTextDecoration2.cj` | 装饰长属性与样式 |
| `SvgGsubContext.cj` | GSUB Type 5/6 |
| `SvgPathLength.cj` | `pathLength` 校准 |
| `SvgAnimationControl.cj` | 触发/时间/pause API |
| `SvgHitQueries.cj` | P7 命中查询 |
| `SvgMutation.cj` | 变更监听 |
| `SvgVectorEffect2.cj` | 新增 `vector-effect` 值 |
| `SvgLineJoin2.cj` | `miter-clip` / `arcs` |
| `SvgAutoSize.cj` | `width/height: auto` |

## 10. 安全与上限

| 项 | 默认上限 | 超限 |
|---|---|---|
| 外部文档深度 | 4 | `Limit` |
| 外部文档字节 | 16 MiB | `Limit` |
| GSUB 链式深度 | 8 | 停止 + warning |
| `font-feature-settings` 条目 | 64 | 忽略多余 + warning |
| 命中测试元素数 | 受 `maxElements` 约束 | — |
| 变更监听器数量 | 32 | 抛 `InvalidValue` |
| `discard` 嵌套深度 | 1 | warning 并忽略 |

## 11. 验收判据

- M1–M5 的 987 条用例零回归，17 张 M1–M4 快照逐字节一致；
- 每个 Requirement 至少 1 个可执行 Scenario；
- `cjpm test` 全绿，`f_svg` 自身 0 warning；
- 每类特性至少 1 个像素或几何断言；
- 所有上限有负向用例；
- `openspec validate --strict` 通过。

## 12. 实施顺序

1. P1 静态交互（pointer-events / cursor / hover / focus）；
2. P2 嵌入（foreignObject 注入、外部文档、initialView、根属性）；
3. P3 渲染提示与颜色；
4. P4 文本与字体（stretch/variant/adjust/features/decoration/GSUB 5-6/pathLength）；
5. P6 动画控制；
6. P7 DOM API 与变更监听；
7. P8 SVG 2 收尾；
8. 快照、基准、文档与验收。

## 13. 已定契约

- 未使用 M6 特性的文档输出与 M5 逐字节一致；
- 脚本、事件监听、链接激活仍不做；`:hover` / `:focus` 只做静态状态求值；
- `foreignObject` 只提供注入接口，不解析 XHTML；
- ICC 只做声明解析与 sRGB 回退；
- 新外部资源一律通过调用方 provider，库内不联网、不读文件；
- 动画触发与时间控制只通过显式 API，不接 UI 事件循环。
