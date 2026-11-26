# 设计：f_svg（M2）

## Context

M1 已经落地 `fountain::f_svg` 的静态文档能力，当前可复用的实现事实是：

- `SvgElement` 的 `attributes`（`ArrayList<SvgAttribute>`）是唯一可写状态，类型化 getter 按 `attributesVersion` 缓存；
- `SvgDocument` 持有 `root`、`declaration`、`doctype`、`prolog` / `epilog` 与 `warnings`，提供 `elementById` 与 `elementsByTag`；
- `SvgRoot` 已有 `x` / `y` / `width` / `height` / `viewBox` / `preserveAspectRatio`；
- `SvgMatrix` 提供 `multiply` / `apply` / `determinant` / `invert` 与六个工厂；`SvgPreserveAspectRatio.toMatrix(viewBox, width, height)` 已实现 SVG 1.1 的 `meet` / `slice`；
- `SvgPathData` 保留命令序列与绝对/相对标志，`toAbsolute()` 只做坐标绝对化，不做弧的中心参数化；
- `SvgPaint` 区分 `None` / `CurrentColor` / `Color` / `Reference`，`Reference` 只接受 `#id`；
- `SvgShape` 已有 `fill` / `stroke` / `strokeWidth` / `strokeLineCap` / `strokeLineJoin` / `strokeMiterLimit` / `strokeDashArray` / `strokeDashOffset` / `opacity` / `color` / `fillRule`；
- `SvgTextElement` 已有 `x` / `y` / `dx` / `dy` / `rotate` / `textLength` / `lengthAdjust` / `textAnchor` 与字体属性；
- `SvgGradient` / `SvgLinearGradient` / `SvgRadialGradient` / `SvgStop` 已有渐变属性；
- `SvgContainer`、`SvgUse`、`SvgImage`、`SvgUnknownElement` 均已建模；
- `f_svg/cjpm.toml` 已配置 `${CANGJIE_STDX_DYNAMIC_PATH}`，但当前源码不引用 stdx；M1 测试用例 216 条。

M2 缺的是「从文档到像素」与「从时间到文档」两条链路，以及这两条链路共同依赖的 CSS 计算样式与几何。设计遵循 `f_svg/doc/f_svg-M2设计.md`，并保持 M1 公开 API 只增不改。

## Goals / Non-Goals

**Goals**

1. CSS 子集解析、选择器匹配、级联、继承与计算样式快照。
2. 形状 / 路径 / 描边 / 变换后包围盒，以及 `viewBox` 到设备坐标的映射。
3. CPU 软件光栅：填充、抗锯齿、描边、渐变、裁剪、蒙版、组透明度。
4. 可插拔字体接口 + 内置 Hershey ASCII 文本布局与渲染。
5. 确定性 PNG 编码。
6. SMIL 时间轴与采样快照，且不修改原文档。
7. 全部新增能力有单元测试；M1 216 条用例零回归；`f_svg` 自身 0 warning。

**Non-Goals（M2 不做）**

- 滤镜、`foreignObject` 内部 XHTML、`pattern`。
- `<image>` 的位图解码与任何外部资源访问。
- 完整 CSS3：伪类、属性选择器、媒体查询、`@font-face`、CSS 动画/过渡。
- 双向文本、连字、字形替换、内置 CJK 字体、TTF/OTF 解析。
- `textPath` 排版、文本 `rotate` 列表、事件驱动动画与脚本。
- 流式序列化、SVGZ、GPU / native 光栅后端。
- 对 `f_xml` / `f_base` 的任何修改。

## 架构

```
                       SvgDocument（M1 模型，不被修改）
                         │
        ┌────────────────┼─────────────────┐
        │                │                 │
 SvgStyleResolver   SvgGeometry       SvgTimeline
 (Css* , 计算样式)   SvgViewport       (SvgClock / 插值)
        │                │                 │
        └────────┬───────┘           sampled SvgDocument
                 │                          │
          SvgRenderTreeBuilder ◄────────────┘
          （展开 use / symbol / clipPath / mask / 渐变）
                 │
           SvgDisplayList（FillPath / StrokePath / Image / Text）
                 │
           SvgRasterizer ── SvgStrokeOutliner / SvgTextRenderer / 渐变采样
                 │
            SvgBitmap ── SvgPngEncoder
```

四条数据流：

- 样式：`<style>` + `style=""` + 呈现属性 → `CssStyleSheet` → `SvgStyleResolver` → `SvgComputedStyleTree`。
- 几何：`SvgElement` + 计算样式 → `SvgBounds`；`SvgOffscreen` 只在 `opacity` / `mask` / `clipPath` 需要时创建。
- 渲染：文档 → 渲染树 → 显示列表 → 位图 → PNG。
- 动画：文档 + 时间 → 深拷贝快照 → 渲染。

## Decisions

### D1. 渲染态与文档模型严格分离

计算样式、渲染树、显示列表、位图都是独立对象；`SvgElement` 不新增任何公开可变字段，也不在渲染时写回属性。

理由：M1 的契约是「`attributes` 是唯一事实源，类型化值是缓存」。若渲染把计算样式写回 `attributes`，会破坏往返语义、让缓存失效不可预测，并让同一文档无法以不同选项重复渲染。动画也需要「原文档不变、快照可变」，分离后两条链路共享同一套克隆语义。

代价：渲染每次要构建样式树与渲染树；通过「文档不可变时可缓存样式树」的约定（调用方负责）降低重复成本。

### D2. `<style>` 由 resolver 在 `compute` 时收集，外部样式表合并

`SvgStyleResolver.init(sheet!)` 接受调用方显式提供的样式表（例如从 `.css` 文件读入）；`compute(root)` 另外按文档顺序遍历根子树，收集 `<style>` 元素的文本并解析，再与 `sheet` 按「外部样式表在前、文档内 `<style>` 在后」合并。

理由：设计文档的入口是 `CssStyleSheet.parse` + `SvgStyleResolver`，但调用方通常只持有 `SvgDocument`；把所有 `<style>` 留给调用方收集会让 `SvgRenderer` 的默认行为不符合直觉。合并顺序保证文档内样式可以覆盖外部基线。

代价：同一文档重复 `compute` 会重复解析 `<style>` 文本。实现按「文本内容 + 长度」做一次进程内小缓存（不跨文档共享可变状态）；缓存只影响性能，不影响正确性。

### D3. 属性元数据表驱动级联，支持集合固定

用一张编译期常量表描述每个支持的 CSS/SVG 属性：`name`、`inherited`、`initial`、`parse` 函数、对应呈现属性名。级联只处理表内属性；表外属性不进入计算样式（避免把任意未知属性塞进快照）。

初始值采用确定性约定（不依赖 UA）：`fill=black`、`stroke=none`、`fill-rule=nonzero`、`stroke-width=1`、`stroke-linecap=butt`、`stroke-linejoin=miter`、`stroke-miterlimit=4`、`opacity=1`、`color=black`、`font-family=sans-serif`、`font-size=16px`、`font-weight=normal`、`font-style=normal`、`text-anchor=start`、`letter-spacing=0`、`word-spacing=0`、`visibility=visible`、`display=inline`、`clip-rule=nonzero`、`stop-color=black`、`stop-opacity=1`。

理由：SVG 的「UA 默认值」本身允许实现差异；为了让快照测试可复现，必须把默认值固定为文档化常量。

代价：与某些浏览器默认值不一致（例如 `font-family`），但 `f_svg` 的目标是自有确定性渲染，不是浏览器像素克隆。

### D4. 级联排序键为 `(important, origin, specificity, order)`

`origin` 取值：UA 默认 0、呈现属性 1、`<style>` 2、内联 3；`important` 为布尔值且优先级最高。内联声明在非 `important` 组中直接取得 origin 3，不再单独计算选择器特异性；内联 `!important` 同样位于 origin 3。

`order` 为「`<style>` 元素序号 × 规则上限 + 规则 `order`」的单调值；内联声明排在所有样式表之后。

理由：与设计文档 §2.1 的五级来源一致，且实现只需一次稳定排序即可逐属性取胜出值。CSS 标准中内联 `!important` 与样式表 `!important` 同属作者来源、按特异性比较；本实现让内联整体位于更高 origin，结果与标准一致。

代价：若未来支持 `@layer` 或用户样式表，需要扩展 origin 枚举。

### D5. 关键字在「指定值 → 计算值」阶段解析，`currentColor` 最后解析

对每个属性：先按排序取指定值；若为 `inherit` 取父计算值，`initial` 取初始值，`unset` 按是否继承二选一；再按类型解析（长度、颜色、画笔、枚举）。`currentColor` 不在解析颜色时立即替换，而是等 `color` 属性计算完成后统一替换 `fill` / `stroke` / `stop-color` 中的 `CurrentColor`。

理由：`color` 本身可继承且可被同一元素的其他声明覆盖；提前替换会读到错误值。最后替换也能正确处理「`color` 来自父元素、`fill=currentColor` 来自子元素样式表」的两级继承。

代价：快照内部需要保存一份「尚未替换 currentColor」的中间值；只在计算阶段短暂存在。

CSS 来源的画笔值可能包含 `url(...)`。`SvgPaint.parse` 对非 `#id` 引用会抛 `Security`（M1 既有契约）；样式解析器 SHALL 捕获该异常，降级为 `SvgPaint.None` 并记 warning，而不是让整份文档的计算失败。这与「渲染器不发起外部访问」的安全边界一致。

### D6. 包围盒用解析极值，不靠扁平化采样

`SvgGeometry` 通过一个路径段迭代器（`M/L/H/V/C/S/Q/T/A/Z`）累加包围盒：

- 三次/二次贝塞尔：对 x、y 分别解 `B'(t)=0`，把 `[0,1]` 内的根与端点纳入；
- 弧：端点参数 → 中心参数，按起始/扫描角把 `0° / 90° / 180° / 270°` 中落在弧内的角度与端点纳入；
- 退化段（零长、`rx/ry = 0`、非有限值）跳过。

理由：扁平化采样的误差不可控，且 `strokeBounds` 需要稳定的几何盒。解析极值同时服务包围盒与后续的 `textLength` / 渐变 `objectBoundingBox`。

`SvgBounds.empty()` 用负尺寸哨兵表示；零宽或零高的退化盒（点、水平线、垂直线）是合法几何，参与 `union` 时保留。否则一个水平线段的包围盒会在组并集里被当成空盒丢弃。

代价：弧的中心参数化与角度归一化容易出错，必须用大弧/小弧/翻转标志/整圆/半圆的表驱动用例钉死。

### D7. 变换后的包围盒取四角轴对齐盒

`SvgBounds.transform(matrix)` 变换四个角后取 `min/max`；`SvgGeometry.absoluteBounds` 先把祖先链与自身 `transform` 合成为 `M_root × ... × M_element`，再应用。

理由：轴对齐包围盒在旋转下必然保守；四角法实现简单、不会漏点，且与「裁剪/脏矩形」的用途一致。真正的紧包围盒对 M2 的渲染没有收益。

代价：45° 旋转的包围盒偏大；文档明确记录该保守性。

### D8. 视口是 M1 `toMatrix` 的薄门面，嵌套视口按矩阵累乘

`SvgViewport.from(root, fallbackWidth, fallbackHeight)` 解析根尺寸：绝对长度直接取值，百分比或缺省用 fallback；`transform(root)` 在无 `viewBox` 时返回单位矩阵，否则调用 `SvgPreserveAspectRatio.toMatrix`。

嵌套 `<svg>` 的矩阵为 `M_parent × translate(x, y) × toMatrix(viewBox, width, height)`，并把子内容裁剪到 `width × height`。

理由：M1 已把 `preserveAspectRatio` 的九种对齐与 `meet/slice` 实现并测试过，M2 不再造第二套。

代价：`SvgViewport` 只处理根与嵌套 svg；`symbol` 的视口由渲染树构建器复用同一算法。

### D9. 渲染树每次构建，显示列表扁平化

`SvgRenderTreeBuilder` 每次渲染从 `SvgDocument`（可能是动画快照）构建不可变渲染树：

- 展开 `use`（含 `symbol` 视口）、跳过 `display:none`；
- 解析 `clipPath` / `mask` / 渐变引用；
- 把每类图元变成 `SvgDisplayList` 指令，指令携带设备矩阵、画笔、透明度、裁剪/蒙版引用。

理由：把「解析引用/继承/视口」集中在一次 DFS 中，光栅器只面对扁平指令，不需要理解 SVG 结构。渲染树不缓存引用 `SvgElement` 的可变状态，避免文档修改后出现悬挂。

代价：每次渲染有建树开销；M2 的性能目标按 512×512 场景核算，建树不计入光栅热点。

### D10. 光栅器按子扫描线处理，覆盖率为整数计数

采样模型固定为 `ss × ss`（`ss = samplesPerPixel`）：每个像素行拆成 `ss` 条子扫描线，每条子扫描线在 x 方向取 `ss` 个采样点。覆盖率 = 命中数 / `ss²`，量化为 `0..255` 的覆盖率字节。

填充规则：`nonzero` 对每条边按方向累计有向交点，`evenodd` 对交点排序后成对取区间。水平边不参与交点；顶点按半开区间 `[ymin, ymax)` 归属，避免重复计数。

颜色在内部用预乘 `SvgRgba`（Float64 通道），合成 `out = src + dst × (1 - src.a)`；写回位图前反预乘并量化到 8 位。

理由：子扫描线模型让覆盖率分母与实现一致（设计文档同时写了「y 方向 1 行」与「除以 `ss²`」，本设计取后者，否则 4×4 只有 4 个 x 采样点却除以 16）。预乘内部合成避免半透明边缘出现暗边。

代价：4×4 SSAA 下每个像素 16 次命中测试；按行处理、不分配整幅浮点缓冲来控制内存。

### D11. 描边先轮廓化，再按非零规则填充

`SvgStrokeOutliner` 把中心线拆成段：

- 每段生成左右偏移线；连接处按 `linejoin` 生成 miter / round / bevel；
- 端点按 `linecap` 生成 butt / round / square；
- dash 先按 `dasharray` / `dashoffset` 切分中心线，每段独立加 cap；
- 输出闭合轮廓，按 `nonzero` 光栅化；自交由填充规则自然处理。

`rect` / `circle` / `ellipse` / `line` 走解析轮廓（圆用多边形近似，误差 ≤ 0.25 设备像素），避免通用 outliner 的数值抖动。

理由：统一走「轮廓 + 填充」可以复用同一套覆盖率与渐变代码；解析快速路径保证常见图形的质量与性能。

代价：round join/cap 的离散精度与 dash 相位是测试重点。

### D12. 渐变在用户空间采样，`objectBoundingBox` 先归一化

线性渐变按 `t = dot(p-p0, p1-p0) / |p1-p0|²`；径向渐变按 `t = |p-f| / r`（设计文档的简化模型，不做精确的椭圆/焦点解析解）。`spreadMethod` 在 `t` 上做 pad/repeat/reflect 映射；stops 排序、钳制后按 sRGB 通道线性插值。

`gradientTransform` 的逆矩阵在采样前作用于点；`gradientUnits=objectBoundingBox` 时先用元素几何包围盒把点归一化到 `0..1`。`href` 继承通过「渐变模板链」解析，深度上限 64。

理由：简化径向模型足以覆盖 M2 场景快照，且与设计文档一致；精确模型（含 `fr`/`FR`）留 M3。

代价：偏心焦点与椭圆径向渐变与浏览器有可见差异，文档明确记录。

### D13. 裁剪/蒙版用 8 位覆盖率缓冲，组不透明度走隔离组

`clipPath` 渲染为 8 位覆盖率蒙版，与被裁剪指令的覆盖率相乘；`clip-rule` 复用填充规则；`clipPathUnits` 支持两种坐标系。

`mask` 生成 8 位 alpha 缓冲：默认按 luminance（`0.2125R + 0.7154G + 0.0721B`）乘 alpha；`mask-type="alpha"` 时直接取 alpha。`maskUnits` 默认 `objectBoundingBox`，`maskContentUnits` 默认 `userSpaceOnUse`。

`opacity < 1`、`mask`、`clipPath` 需要隔离的组一律先渲染到离屏 RGBA 缓冲，再整体预乘合成到父层。

理由：组透明度必须「整组合成一次」，逐元素应用会把重叠区域叠深；8 位蒙版与位图同尺寸，内存可控。

代价：离屏层按需创建；嵌套组会临时增加 `width × height × 4` 的缓冲，受 `maxPixels` 约束。

### D14. 文本通过 `SvgFont` 接口，内置 Hershey，字形缓存路径

`SvgFont` 只暴露字形路径、advance、ascent/descent、glyphBounds；`SvgFontRegistry` 按 family 列表回退，`defaultRegistry()` 注册 Hershey 到 `Hershey`、`serif`、`sans-serif`、`monospace`，保证未指定字体时也能出图。

文本布局按字符 advance 累加，处理 `x`/`y` 列表、`dx`/`dy`、`letter-spacing`、`word-spacing`、`text-anchor`、`textLength` + `lengthAdjust`。字形路径与形状共用填充/描边/渐变/裁剪管线。

字形路径按「字体实例 + 字号 + 字符」缓存；Hershey 数据为公开领域的单线笔画表，内嵌为静态数组。

`textPath` 与逐字符 `rotate` 在 M2 降级为普通文本并记 warning，不影响其他文本。

理由：接口化让 CJK/外部字体可注入，核心库零 native 依赖；Hershey 保证 ASCII 开箱可用。

代价：CJK 默认只能画占位方框；复杂脚本不支持。

### D15. PNG 自实现 chunk 与 CRC，DEFLATE 复用 stdx

`SvgPngEncoder` 输出签名 + `IHDR` + `IDAT` + `IEND`；每行 filter 固定 0；`IDAT` 使用 `stdx.compress.zlib.CompressOutputStream(wrap: WrapType.DeflateFormat)`，再手工补 `0x78 0x9C` 头与 Adler-32 尾。

CRC-32 在 `SvgCrc32.cj` 内部实现查表算法（多项式 `0xEDB88320`），不新增 `f_util` 依赖；Adler-32 同样内部实现。

`f_svg/cjpm.toml` 已配置 `${CANGJIE_STDX_DYNAMIC_PATH}`，无需新增依赖项；`stdx` 不是 Maven 式依赖，不写进 `[dependencies]`。

理由：PNG 结构简单，自己写 chunk 能保证确定性并避免 native libpng；DEFLATE 没必要重写。

代价：编码器不支持调色板、灰度、16 位或隔行；M2 只需要 RGBA8。

### D16. 动画采样返回深拷贝快照

`SvgTimeline.sample(time)` 先深拷贝 `SvgDocument`（根、属性、子节点、prolog/epilog、warnings，并重建 `parent` 链使 `elementById` 在副本上可用），再在副本上按时间求值并 `setAttr`。原文档不被触碰。

时间轴以文档为 0 点；`begin` / `end` 解析为绝对秒，支持 `id.begin` / `id.end`（引用另一动画的边界）、`indefinite`；`repeatCount` / `repeatDur` 截断活动区间；`fill=remove` 结束后回到基础值，`freeze` 保持末值。

同一元素多动画按 `begin` 排序，后写覆盖先写；`additive="sum"` 时把动画值叠加到基础值。

理由：契约要求「采样返回新文档，不修改原文档」；深拷贝是最直接的隔离方式，也让调用方可以安全地并行渲染多个时间点。

代价：大文档每个采样点一次深拷贝；M2 接受，后续可按「结构共享 + 属性补丁」优化。

### D17. 兼容性与发布边界

- 公开 API 只增不改：M1 的所有类型、方法、构造与默认参数保持；
- 新增类型全部位于 `package fountain::f_svg`，不建子包；文件按 `Css*` / `Svg*` 主题命名；
- 不新增模块，不改根 `cjpm.toml` / `.modules` / 聚合根 shim；
- 不修改 `f_xml` / `f_base`；
- 版本号由发版流程处理，M2 规划不包含版本变更。

理由：M1 的兼容性是 M2 的硬约束；单包布局与 M1 一致，避免引入跨包可见性问题。

## 关键契约

| 契约 | 说明 |
|---|---|
| 模型不变 | 渲染 / 动画不得修改传入的 `SvgDocument` |
| 只增不改 | M1 公开签名保持；新增类型不改变既有行为 |
| 输出格式 | RGBA8、非预乘、行优先、`pixels.size == width × height × 4` |
| 确定性 | 同输入 + 同选项 → 逐字节一致的位图与 PNG |
| 无 I/O | 渲染不联网、不打开外部文件、不解码外部图像 |
| 硬上限 | `maxPixels`、非循环递归深度 64、动画 `values` 10000 超限抛 `Limit` |
| 循环引用 | 检测到循环时在深度 64 终止并 warning；非循环但超过 64 抛 `Limit` |
| 文本经接口 | 核心不内置 CJK，字体必须经 `SvgFont` / `SvgFontRegistry` |
| 单包 | 不新增子包、模块或聚合根 shim |

## 风险 / 取舍

| 风险 | 影响 | 缓解 |
|---|---|---|
| 弧的中心参数化与角度归一化出错 | 包围盒与渲染缺口 | 端点/中心转换单独实现，配大弧/小弧/翻转/整圆/半圆表驱动用例 |
| 4×4 SSAA 性能不达标 | 512×512 场景超 50 ms | 按子扫描线逐行处理、边表增量更新、避免整幅浮点缓冲；基准只记录不门禁 |
| CSS 匹配 O(规则 × 元素 × 深度) | 大文档样式计算慢 | 右端简单选择器建 id/class/type 倒排桶，先过滤再回溯；1000×1000 基准守护 |
| 渐变简化模型与浏览器差异 | 视觉不一致 | 文档声明 M2 使用简化径向模型；场景快照以自身输出为准 |
| 浮动舍入导致快照跨平台差异 | 快照测试抖动 | 基元用例用 `samplesPerPixel=1`；场景快照容差 ≤ 1；避免依赖 libm 特殊函数 |
| 深拷贝开销 | 动画采样慢 / 内存高 | 每帧一次拷贝，渲染后即可回收；文档记录后续结构共享优化 |
| `use` / 渐变 / 动画循环引用 | 栈溢出 | 统一深度上限 64 + 访问集合，超限终止并 warning |
| 字体缺失导致文本空白 | 用户误以为渲染失败 | 占位方框 + warning；默认注册表内置 Hershey |
| M1 缓存与计算样式不一致 | 读取到旧值 | 计算样式只读 `attributes`，不写缓存；M1 缓存机制不动 |

## Testing Strategy

全部按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。

- **CSS**：词法/字符串/url/注释/截断恢复；五类选择器、复合、后代/子代、分组；六级级联交叉矩阵；继承/关键字/currentColor 两级；非法值降级；1000×1000 匹配基准。
- **几何**：每个形状的精确 bbox；贝塞尔极值（同侧/异侧/退化）；弧的四种轴向极值、整圆、半圆、大弧/小弧/翻转；变换后 bbox；描边 bbox（miter/round/bevel）；空元素/零尺寸/非法值；视口 meet/slice/none/嵌套。
- **光栅**：`samplesPerPixel=1` 的像素精确用例（矩形边界、三角形、凹多边形 nonzero/evenodd、圆对称）；描边 cap/join/miter/dash；渐变端点/spread/stops；裁剪/蒙版/透明度；`testdata/render/*.svg` + `*.rgba` 场景快照（64×64，逐像素容差 ≤ 1）。
- **文本**：Hershey 覆盖 ASCII 32–126；advance/路径随字号缩放；x/y 列表、dx/dy、anchor、textLength、tspan、缺字占位、textPath/rotate 降级。
- **PNG**：签名/chunk 顺序/IHDR 字段/zlib 头/Adler-32/CRC；用 `DecompressInputStream` 解压回读逐字节比对；两次编码一致。
- **动画**：时间解析（`0s`/`1.5s`/`500ms`/`indefinite`/`id.begin`）、关键帧 linear/discrete/spline、repeat/repeatDur/freeze/remove、五种 transform、animateMotion 与 rotate、采样不修改原文档、0/0.5/1 秒像素快照。
- **回归**：M1 216 条用例全部保留并通过；`cjpm build` 无新增 warning。
- **基准**：更新 `f_svg/doc/perf-baseline.md`，记录 512×512 / 1024×1024 / PNG / CSS 匹配实测，非门禁。

## Migration / Rollout

纯新增能力，无数据迁移、无配置迁移、无依赖变更。实施顺序按设计文档 §10：

1. CSS 词法/解析/选择器/级联/计算样式；
2. 包围盒/视口；
3. 位图/光栅器基元；
4. 描边；
5. 渐变/裁剪/蒙版/组透明度；
6. 文本；
7. 渲染树/`SvgRenderer`/`use`/嵌套 svg；
8. PNG；
9. SMIL 动画；
10. 场景快照/基准/README/文档。

每个阶段结束 `cjpm test` 必须全绿，并在 `feature/f-svg-m2` 分支独立提交；全部完成后合并回 `feature/f_svg`（`--no-ff`）并删除分支。

## 假设与待确认

设计文档未明确、M2 规划采用以下假设（实现前若需调整，应先更新本文件与对应 spec）：

1. `SvgComputedStyleTree` 的公开形状定义为 `get(element: SvgElement): ?SvgComputedStyle` 与 `size`；设计文档只给了返回类型名。
2. `mask` 默认按 luminance 计算，`mask-type="alpha"` 作为 CSS Masking 兼容扩展识别；SVG 1.1 只定义 luminance。
3. `textPath` 与 `text rotate` 列表在 M2 降级为普通文本并记 warning，而不是静默忽略。
4. 默认字体族固定为 `sans-serif`，`defaultRegistry()` 把 Hershey 同时注册到三个通用族，保证确定性。
5. `maxPixels` 的「64M」按 `64 × 1024 × 1024` 像素解释。
6. 动画深拷贝是内部实现，不新增公开 `clone` API；若调用方需要显式克隆，留到后续版本。
7. `render(element, width, height)` 以该元素为样式根与变换根：不回溯真实祖先的属性继承与 `transform`，只处理元素自身子树；这样同一元素可以在任意画布中独立出图。
8. `mathml` / `foreignObject` 等未知元素在渲染时跳过并记 warning，不递归其内容。
