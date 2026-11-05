# f_svg M3 —— 滤镜 / 图案 / 位图 / 文本路径设计

> 定位：M3 是 f_svg 的**收口里程碑**。M1 解决「把 SVG 文档讲清楚、改对、写回去」，M2 解决「从文档到像素、从时间到文档」；
> M3 补齐 SVG 1.1 中仍缺失的**效果与资源类能力**：滤镜、图案、位图、SVGZ 容器、`textPath` 与 marker，
> 并把抗锯齿从 4× 超采样升级为可选的解析覆盖率。
>
> 边界不变：不联网、不读任意文件、不执行脚本；所有外部资源必须由调用方显式注入。

## 0. M3 特性清单

| 编号 | 特性 | 说明 |
|---|---|---|
| M3-1 | **滤镜框架** | `filter` 元素、滤镜区域（`filterUnits` / `primitiveUnits` / `x,y,width,height`）、`in`/`in2`/`result` 图连接、离屏 RGBA 缓冲链 |
| M3-2 | **滤镜原语** | `feGaussianBlur` / `feOffset` / `feFlood` / `feBlend` / `feComposite` / `feMerge` / `feColorMatrix` / `feTile` |
| M3-3 | **图案填充** | `pattern` 元素、`patternUnits` / `patternContentUnits` / `patternTransform`、`href` 继承、平铺与裁剪 |
| M3-4 | **PNG 解码** | 8-bit 灰度 / 灰度+α / RGB / RGBA / 调色板、filter 0–4、Adam7、CRC 与长度校验 |
| M3-5 | **`<image>` 绘制** | `data:image/png;base64,` 与调用方注入的 `SvgImageResourceProvider`；`preserveAspectRatio` 映射 |
| M3-6 | **SVGZ 容器** | gzip 读写的 `.svgz` 支持，`parseAuto` 按魔数自动识别 |
| M3-7 | **文本路径** | `textPath` 沿路径排版、`startOffset`、`text-anchor`、逐字旋转；`rotate` 列表 |
| M3-8 | **marker** | `marker-start` / `marker-mid` / `marker-end`、`markerUnits`、`orient`、`refX`/`refY`、溢出裁剪 |
| M3-9 | **解析覆盖率 AA** | `SvgAntiAliasMode.Analytic`：按像素面积累加求覆盖率，替代超采样作为可选档 |
| M3-10 | **测试与基准** | 滤镜 golden、pattern 平铺、PNG 解码回环、textPath/marker 快照、AA 覆盖率守恒、性能基准 |

### M3 明确不做

- JPEG / WebP / GIF 解码（无内置编解码器；需要时由 `SvgImageResourceProvider` 自行解码为位图）；
- `foreignObject` 内部 XHTML 语义；
- SMIL 动画扩展（`animateColor`、事件驱动、脚本）；
- `feImage` 外部图像原语（可由 `<image>` + 滤镜链替代）；
- 字体文件解析（TTF/OTF）与内置 CJK 字体；
- GPU / native 光栅后端。

## 1. 定位与兼容性

### 1.1 与 M1 / M2 的关系

| 层 | M1 | M2 | M3 |
|---|---|---|---|
| 文档模型 | 类型化 DOM、值类型、解析/生成 | — | 新增 `filter` / `pattern` / `fe*` 类型化元素 |
| 渲染 | — | CSS 级联、光栅、PNG 编码、SMIL | 滤镜链、图案、位图、marker、textPath、解析 AA |
| 容器 | — | — | SVGZ |
| 公开 API | 值类型与模型 | 渲染、动画、PNG | 只**新增**，不改 M1/M2 已有签名 |

**兼容性约束**：

- `SvgRenderOptions` 只加带默认值的字段（`images`、`antiAlias`），既有调用方无需改动；
- `SvgRenderOptions` 的默认行为保持 M2 输出（超采样 4×）；解析 AA 必须显式开启；
- `SvgParser` / `SvgWriter` 的既有入口不变；SVGZ 走新增入口；
- 新增元素类型继承既有 `SvgElement` / `SvgContainer`，不改变既有标签映射结果（`filter` / `pattern` 从容器/未知升级为类型化元素，`SvgContainerKind` 保留）。

### 1.2 依赖

| 依赖 | 用途 | 备注 |
|---|---|---|
| `fountain::f_xml` | XML 解析与生成 | 与 M1 一致 |
| `stdx.compress.zlib` | gzip / zlib 解压与压缩 | `WrapType.GzipFormat` / `ZlibFormat`，PNG 解码与 SVGZ 共用 |
| `fountain::f_base` | 集合与字符串扩展 | 与 M2 一致 |

不新增模块，不引入第三方依赖。

### 1.3 对象生命周期

```
字节流 ──parseAuto──▶ SvgDocument ──styleResolver──▶ 渲染树 ──renderer──▶ SvgBitmap ──▶ PNG
                          │                          │
                          │                          ├─ pattern: 引用 defs 中的图案
                          │                          ├─ filter: 离屏缓冲链
                          │                          ├─ image: 资源提供者
                          │                          └─ marker: 由顶点派生实例
                          └─ textPath: 复用 SvgPathData 采样
```

渲染全程只读 `SvgDocument`；图案、marker、滤镜都在渲染树展开阶段派生，不回写文档。

## 2. 滤镜层（M3-1 / M3-2）

### 2.1 模型

```cangjie
/** filter 元素。 */
public class SvgFilter <: SvgElement {
    public mut prop x: ?SvgLength
    public mut prop y: ?SvgLength
    public mut prop width: ?SvgLength
    public mut prop height: ?SvgLength
    public mut prop filterUnits: SvgUnits          // userSpaceOnUse | objectBoundingBox
    public mut prop primitiveUnits: SvgUnits
    public prop primitives: ArrayList<SvgFilterPrimitive>
}

/** 滤镜原语基类。 */
public abstract class SvgFilterPrimitive <: SvgElement {
    public mut prop inSource: ?String              // 对应 in
    public mut prop result: ?String
}

public class SvgFeGaussianBlur <: SvgFilterPrimitive { public mut prop stdDeviation: SvgNumberList }
public class SvgFeOffset <: SvgFilterPrimitive { public mut prop dx: SvgLength; public mut prop dy: SvgLength }
public class SvgFeFlood <: SvgFilterPrimitive { public mut prop floodColor: SvgPaint; public mut prop floodOpacity: SvgNumber }
public class SvgFeBlend <: SvgFilterPrimitive {
    public mut prop in2: ?String
    public mut prop mode: SvgBlendMode              // normal|multiply|screen|darken|lighten
}
public class SvgFeComposite <: SvgFilterPrimitive {
    public mut prop in2: ?String
    public mut prop operator: SvgCompositeOperator  // over|in|out|atop|xor|arithmetic
    public mut prop k1: SvgNumber; public mut prop k2: SvgNumber
    public mut prop k3: SvgNumber; public mut prop k4: SvgNumber
}
public class SvgFeMerge <: SvgFilterPrimitive { public prop inputs: ArrayList<String> }
public class SvgFeColorMatrix <: SvgFilterPrimitive {
    public mut prop matrixType: SvgColorMatrixType  // matrix|saturate|hueRotate|luminanceToAlpha
    public mut prop values: Array<Float64>
}
public class SvgFeTile <: SvgFilterPrimitive { public mut prop inSource: ?String }
```

### 2.2 语义

- **滤镜区域**：`x/y/width/height` 默认 `-10% / -10% / 120% / 120%`，`filterUnits=objectBoundingBox` 时按元素包围盒换算；超出画布的部分裁掉。
- **图连接**：`in` 缺省为前一个原语的 `result`，首个原语缺省为 `SourceGraphic`；`in2` 未指定时按原语语义取 `SourceGraphic`（`feBlend` / `feComposite`）。
- **未定义引用**：`in` / `in2` / `result` 指向不存在的名字时，该原语输出透明黑并记 warning。
- **颜色空间**：默认在 sRGB 空间计算；`color-interpolation-filters="linearRGB"` 时在进入/离开滤镜链时做一次转换。
- **缓冲格式**：RGBA8 非预乘；滤镜链内部使用 `SvgFilterBuffer`（宽高 + `Array<Byte>`），每次原语产生新缓冲。
- **空滤镜链**：`<filter></filter>` 视为无效果，直接返回 `SourceGraphic`。

### 2.3 原语算法

| 原语 | 算法 |
|---|---|
| `feGaussianBlur` | `stdDeviation` 为二元组或单值；按 σ 计算核半径 `ceil(3σ)`，分离式两次一维卷积；σ=0 直通 |
| `feOffset` | 整数平移，越界补透明 |
| `feFlood` | 用 `flood-color` × `flood-opacity` 填满滤镜区域 |
| `feBlend` | 逐通道可分离混合；`normal` 等价于 over |
| `feComposite` | `over/in/out/atop/xor` 按 Porter-Duff；`arithmetic` 用 `k1·i·j + k2·i + k3·j + k4` 并钳制 |
| `feMerge` | 按 `feMergeNode` 顺序 over 合成 |
| `feColorMatrix` | 4×5 矩阵；`saturate` / `hueRotate` / `luminanceToAlpha` 生成矩阵后同路径处理 |
| `feTile` | 以输入缓冲为一个 tile，平铺填满滤镜区域 |

### 2.4 API

```cangjie
/** 滤镜渲染入口（内部由 SvgRenderer 调用，公开供高级用法）。 */
public class SvgFilterRenderer {
    public init(registry: SvgFontRegistry)
    public func apply(
        filter: SvgFilter,
        source: SvgBitmap,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        options: SvgRenderOptions
    ): SvgBitmap
}
```

### 2.5 测试矩阵

- 每个原语 1 组像素断言（含边界：零区域、全透明、越界）；
- 图连接：链式 3 原语、`result` 复用、未定义引用 warning；
- 区域：`objectBoundingBox` 与 `userSpaceOnUse` 的换算差异；
- 组合：blur + offset + merge 的 golden；
- 上限：滤镜区域像素数超 `maxPixels` 抛 `Limit`。

## 3. 图案层（M3-3）

### 3.1 模型与语义

```cangjie
public class SvgPattern <: SvgContainer {
    public mut prop x: ?SvgLength
    public mut prop y: ?SvgLength
    public mut prop width: ?SvgLength
    public mut prop height: ?SvgLength
    public mut prop patternUnits: SvgUnits
    public mut prop patternContentUnits: SvgUnits
    public mut prop patternTransform: ?SvgTransform
    public mut prop href: ?String
}
```

- `patternUnits` 默认 `objectBoundingBox`，`patternContentUnits` 默认 `userSpaceOnUse`；
- `href` 继承：自身属性优先，缺省项从被引用 pattern 继承，循环引用记 warning 并停止；
- 平铺：以 `patternTransform` 变换 tile，再按用户空间裁剪到填充区域；
- 空 tile（宽或高 ≤ 0）不绘制并记 warning；
- 递归引用自身（pattern 内再引用 pattern）按深度上限处理。

### 3.2 API

图案解析并入现有画笔解析：`SvgPaint.Reference` 指向 `pattern` 时，`SvgPatternSampler` 返回可平铺的 `SvgBitmap`，由光栅器按 `shader` 取样。

```cangjie
public class SvgPatternSampler {
    public init(registry: SvgFontRegistry)
    public func sample(
        pattern: SvgPattern,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        options: SvgRenderOptions
    ): ?SvgBitmap
}
```

### 3.3 测试矩阵

- 20×20 tile 平铺 100×100 区域，四角颜色正确；
- `objectBoundingBox` vs `userSpaceOnUse` 的 tile 尺寸差异；
- `patternTransform` 旋转 45°；
- `href` 继承与循环引用；
- 空 tile、超大 tile（超 `maxPixels`）的降级与报错。

## 4. 位图层（M3-4 / M3-5）

### 4.1 PNG 解码

```cangjie
public class SvgPngDecoder {
    public static func decode(bytes: Array<Byte>): SvgBitmap
    public static func decode(stream: InputStream): SvgBitmap
}
```

支持范围：

| 维度 | 支持 |
|---|---|
| 位深 | 8-bit（1/2/4-bit 调色板与灰度按规范展开到 8-bit） |
| 颜色类型 | 0 灰度、2 RGB、3 调色板、4 灰度+α、6 RGBA |
| 行过滤 | 0 None / 1 Sub / 2 Up / 3 Average / 4 Paeth |
| 交错 | Adam7 |
| 校验 | 每个 chunk 的 CRC-32、IHDR 合法性、IDAT 连续性、IEND 必须存在 |

错误语义：结构错误抛 `SvgException(kind: Syntax)`；超上限抛 `SvgException(kind: Limit)`；未知颜色类型/位深抛 `InvalidValue`。

### 4.2 `<image>` 绘制

```cangjie
public interface SvgImageResourceProvider {
    /** 返回图片原始字节；返回 None 表示不提供。不得联网或读任意文件。 */
    func resolve(href: String): ?Array<Byte>
}
```

- `href` 为 `data:image/png;base64,...` 时内置解密并解码；
- 其他 `href` 交给 `SvgRenderOptions.images`；未提供时画占位矩形并记 warning；
- 绘制按 `preserveAspectRatio` 映射到 `x/y/width/height`，使用最近邻 + 双线性两档（`imageRendering`）；
- 解码结果按 `href` 缓存，单次渲染内不重复解码；
- 安全：单图像素数、总解码像素数、base64 长度均受上限约束。

### 4.3 测试矩阵

- 6 种 PNG 变体（灰度、RGB、调色板、GA、RGBA、Adam7）回环：编码 → 解码 → 像素相等；
- 损坏文件：坏 CRC、截断 IDAT、缺 IEND、非法 IHDR；
- `<image>` 的 `meet` / `slice` / `none` 三档映射；
- data URI 与 provider 两条路径；
- 解码炸弹（超大宽高、超高压缩比）→ `Limit`。

## 5. SVGZ 容器（M3-6）

```cangjie
public static func parseAuto(bytes: Array<Byte>, options!: ?SvgParseOptions = None): SvgDocument
public static func parseGzip(bytes: Array<Byte>, options!: ?SvgParseOptions = None): SvgDocument
public func writeGzip(document: SvgDocument): Array<Byte>
```

- `parseAuto` 检测 `1F 8B` 魔数，命中走 gzip 解压，否则按纯文本解析；
- 解压后仍受 `SvgParseOptions` 的元素数、深度、文本长度上限约束；
- 解压输出上限（默认 64 MiB）防压缩炸弹；
- gzip 输出使用 `WrapType.GzipFormat`，mtime 固定为 0，保证同文档同字节。

### 5.1 测试矩阵

- 纯文本与 gzip 两条入口对同一文档解析结果一致；
- gzip 输出 → 解压 → 再解析的往返；
- 魔数误判、截断 gzip、解压超限。

## 6. 文本路径与 marker（M3-7 / M3-8）

### 6.1 `textPath`

- 取 `href` 指向的 `path`（或 `textPath` 自身 `path` 属性），按 `startOffset`（长度或百分比）定位起点；
- 按字形 advance 沿路径弧长推进，字形按切线方向旋转；`text-anchor` 调整整体起点；
- `side` 不支持；路径短于文本时截断并记 warning；
- 路径不存在或为空时降级为普通文本并记 warning。

### 6.2 文本 `rotate` 列表

- `rotate` 单值作用于全部字形，列表逐字消费，短列表复用末值；
- 与 `textPath` 同时存在时，在切线角基础上叠加。

### 6.3 marker

```cangjie
public class SvgMarker <: SvgContainer {
    public mut prop markerUnits: SvgMarkerUnits     // strokeWidth | userSpaceOnUse
    public mut prop refX: ?SvgLength
    public mut prop refY: ?SvgLength
    public mut prop markerWidth: ?SvgLength
    public mut prop markerHeight: ?SvgLength
    public mut prop orient: SvgMarkerOrient         // auto | autoStartReverse | angle
    public mut prop viewBox: ?SvgViewBox
    public mut prop preserveAspectRatio: SvgPreserveAspectRatio
}
```

- 在渲染树展开阶段，对 `path` / `line` / `polyline` / `polygon` 的顶点派生 marker 实例；
- `markerUnits=strokeWidth` 时按 `stroke-width` 缩放；
- `orient=auto` 按切线角，`auto-start-reverse` 仅对 `marker-start` 反转 180°；
- 每个元素最多派生 1024 个 marker，超出记 warning 并停止；
- marker 内部的 `clipPath` / `mask` 正常生效，`filter` 支持。

### 6.4 测试矩阵

- 沿路径的字符位置与旋转角；
- `startOffset` 百分比与长度两种形式；
- `rotate` 单值 / 列表 / 短列表复用；
- `marker-start` / `mid` / `end` 的 refX/refY 对齐；
- `orient=auto` 与固定角；
- marker 数量上限。

## 7. 解析覆盖率 AA（M3-9）

### 7.1 目标

M2 使用 `samplesPerPixel ∈ {1,2,4}` 的超采样。M3 增加解析覆盖率档：

```cangjie
public enum SvgAntiAliasMode {
    | Supersample
    | Analytic
}

public struct SvgRenderOptions {
    // M2 字段保持不变
    public var antiAlias: SvgAntiAliasMode = SvgAntiAliasMode.Supersample
}
```

- `Analytic` 档把路径按现有扁平化容差离散为线段，用**有符号面积累加**求每个像素的覆盖率；
- 覆盖率与颜色按 `source-over` 合成，边缘像素的覆盖率之和守恒（误差 ≤ 1/255）；
- 与超采样相比，同样的视觉质量下像素填充次数更少；性能基准记录在 `doc/perf-baseline.md`；
- 复杂自交路径仍按 nonzero / evenodd 规则判定内外，面积累加只负责覆盖率。

### 7.2 测试矩阵

- 45° 斜线相邻像素覆盖率和 ≈ 1；
- 圆的解析覆盖率与 4× 超采样结果差 ≤ 2/255；
- 自交路径（nonzero 与 evenodd 各一例）；
- 与 marker / pattern / filter 组合时输出确定。

## 8. 模块布局

新增源文件（全部位于 `f_svg/src`，单模块内聚，不新增包）：

| 文件 | 职责 |
|---|---|
| `SvgFilter.cj` / `SvgFilterPrimitive.cj` | 滤镜元素与 `fe*` 类型化模型 |
| `SvgFilterRenderer.cj` / `SvgFilterBuffer.cj` | 滤镜链执行与离屏缓冲 |
| `SvgPattern.cj` / `SvgPatternSampler.cj` | 图案模型与平铺取样 |
| `SvgPngDecoder.cj` | PNG 解码 |
| `SvgImageResource.cj` | `SvgImageResourceProvider` 与 data URI |
| `SvgGzip.cj` | SVGZ 读写 |
| `SvgTextPathLayout.cj` | 路径排版与逐字旋转 |
| `SvgMarker.cj` / `SvgMarkerExpander.cj` | marker 模型与实例派生 |
| `SvgAnalyticRasterizer.cj` | 解析覆盖率光栅 |

现有文件改动：`SvgTag.cj`（新增标签）、`SvgBuilder.cj`（新元素构建）、`SvgRenderTree.cj`（marker/pattern/filter 展开）、`SvgRenderer.cj`（选项与入口）、`SvgTextRenderer.cj`（textPath/rotate）、`SvgRasterizer.cj`（AA 档分派）、`SvgOptions.cj`（新字段）。

## 9. 安全与上限

| 项 | 默认上限 | 超限行为 |
|---|---|---|
| 单张解码图像素 | 16 × 1024 × 1024 | `Limit` |
| 单次渲染解码总像素 | 64 × 1024 × 1024 | `Limit` |
| base64 长度 | 32 MiB | `Limit` |
| gzip 解压输出 | 64 MiB | `Limit` |
| 滤镜区域像素 | 同 `maxPixels` | `Limit` |
| 图案 tile 像素 | 4 × 1024 × 1024 | `Limit` |
| marker 派生数 / 元素 | 1024 | warning 并截断 |
| pattern / marker 引用深度 | 64 | `Limit` |
| 循环引用 | — | warning 并停止 |

外部资源一律不联网、不读任意路径；`SvgImageResourceProvider` 由调用方实现并承担安全责任。

## 10. 验收判据（M3）

- M1/M2 的 348 条用例零回归；
- 新增能力每个 Requirement 至少 1 个 Scenario 有可执行用例；
- `cjpm test` 全绿，`cjpm build` 中 `f_svg` 自身 0 warning；
- PNG 解码回环、滤镜 golden、textPath/marker 快照、AA 覆盖率守恒四类断言全部通过；
- 所有上限均有负向用例；
- `openspec validate --strict` 通过，`openspec validate --specs` 通过。

## 11. 实施顺序

1. 模型与标签：`filter` / `pattern` / `marker` / `fe*` 类型化元素 + 解析 + 往返；
2. SVGZ 与 PNG 解码（纯字节处理，无渲染依赖）；
3. `<image>` 绘制与资源提供者；
4. 图案平铺；
5. 滤镜框架与原语；
6. textPath 与 rotate；
7. marker 派生；
8. 解析覆盖率 AA；
9. 测试补齐、基准、文档与归档。

## 12. 已定契约

- `filter` / `pattern` / `marker` 从 M1 的容器/未知元素**升级为类型化元素**，但 `SvgContainerKind` 枚举值与既有标签映射结果保持兼容；
- `SvgRenderOptions` 只新增带默认值的字段，默认输出与 M2 逐字节一致；
- PNG 解码失败不抛裸异常，统一 `SvgException`；
- 所有外部资源必须显式注入，库内不联网、不读任意路径；
- 滤镜与图案的离屏缓冲都受 `maxPixels` 约束，先检查后分配；
- 同一文档 + 同一选项 + 同一资源提供者，输出逐字节确定。
