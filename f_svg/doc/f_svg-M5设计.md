# f_svg M5 —— CSS 扩展 / SVG 2 渲染 / 文本整形 / 元素级 API

> 定位：M5 补齐 M1–M4 之后影响真实文档兼容性的四类能力，按 **P1 CSS 扩展 → P2 SVG 2 渲染 → P3 文本整形 → P4 元素级 API** 顺序实施。
> 一个 OpenSpec 变更 `add-f-svg-m5`；只增不改 M1–M4 公开 API 语义，未使用新特性的文档输出保持逐字节一致。

## 0. M5 特性清单

### P1 CSS 扩展

| 编号 | 特性 | 说明 |
|---|---|---|
| M5-P1-1 | 属性选择器 | `[attr]`、`[attr=v]`、`[attr~=v]`、`[attr\|=v]`、`[attr^=v]`、`[attr$=v]`、`[attr*=v]`，支持 `i` 大小写不敏感标志 |
| M5-P1-2 | 结构伪类 | `:root`、`:first-child`、`:last-child`、`:only-child`、`:nth-child(An+B)`、`:first-of-type`、`:last-of-type`、`:nth-of-type`、`:only-of-type`、`:empty` |
| M5-P1-3 | 否定伪类 | `:not(<简单选择器>)`，仅接受单个简单选择器，不支持嵌套 |
| M5-P1-4 | 兄弟组合器 | `A + B`（相邻）、`A ~ B`（一般兄弟） |
| M5-P1-5 | `@media` | `screen` / `all`、`(min-width: Npx)` / `(max-width: Npx)`、`and`、逗号列表；宽度取渲染视口宽度 |
| M5-P1-6 | `@font-face` | 仅把 `font-family` 别名映射到已注册字体；`src` 忽略并记 warning，不加载文件 |
| M5-P1-7 | CSS 变量 | `--name: value` 声明与继承，`var(--name, fallback)`，嵌套上限 8 层，循环记为无效 |
| M5-P1-8 | `calc()` | 长度四则运算与括号，支持 `px` / `%` / `em`，仅用于长度属性 |

### P2 SVG 2 渲染

| 编号 | 特性 | 说明 |
|---|---|---|
| M5-P2-1 | `paint-order` | `fill` / `stroke` / `markers` 的任意子集，缺省 `fill stroke markers` |
| M5-P2-2 | `mix-blend-mode` | `normal` / `multiply` / `screen` / `overlay` / `darken` / `lighten` / `color-dodge` / `color-burn` / `hard-light` / `soft-light` / `difference` / `exclusion` |
| M5-P2-3 | `isolation` | `auto` / `isolate`；`isolate` 或非 `normal` 混合时建立隔离组 |
| M5-P2-4 | `feDropShadow` | 等价于 blur + offset + flood + merge 的复合原语 |
| M5-P2-5 | `transform-origin` / `transform-box` | 原点支持长度、百分比、关键字；`transform-box` 支持 `view-box` / `fill-box` |
| M5-P2-6 | `context-fill` / `context-stroke` | `use` 实例内解析为被引用元素的 `fill` / `stroke` |

### P3 文本整形

| 编号 | 特性 | 说明 |
|---|---|---|
| M5-P3-1 | 字距调整 | `kern` 表（format 0）与 `GPOS` Pair Adjustment（format 1/2，仅 x advance） |
| M5-P3-2 | 标准连字 | `GSUB` Lookup Type 4（`liga`，format 1） |
| M5-P3-3 | 双向文本 | UAX#9 子集：L / R / AL / EN / AN / WS / ON，按段落方向分段重排 |
| M5-P3-4 | `direction` / `unicode-bidi` | `ltr` / `rtl`；`normal` / `embed` / `bidi-override` |
| M5-P3-5 | `font-kerning` | `auto` / `normal` / `none`，缺省 `auto`（有 `kern`/`GPOS` 时启用） |

### P4 元素级 API

| 编号 | 特性 | 说明 |
|---|---|---|
| M5-P4-1 | `SvgElement.getBBox(options!)` | 用户空间包围盒；`options.stroke` / `options.clipped` / `options.fonts` |
| M5-P4-2 | `SvgElement.getCTM()` | 元素 → 根用户空间矩阵 |
| M5-P4-3 | `SvgElement.getScreenCTM(viewport!)` | 元素 → 设备空间矩阵（含 DPR） |
| M5-P4-4 | `SvgPath.getTotalLength()` / `getPointAtLength(d)` | 路径元素级薄封装，复用 `SvgPathData` |
| M5-P4-5 | `SvgElement.getElementsByClassName(name)` / `querySelectorAll(selector)` | 基于 M5-P1 选择器引擎的查询 |

### M5 明确不做

- CSS 动画/过渡、`@supports`、`@layer`、`@container`；
- 伪元素（`::before` / `::after`）；
- 阿拉伯/印度系复杂脚本整形、上下文替换（GSUB Type 5/6）、竖排连字；
- `direction` 与竖排组合的完整 UAX#9 行级重排；
- `mix-blend-mode` 的 `plus-lighter` 与 CSS 颜色空间混合；
- `foreignObject`、脚本/事件、JPEG/WebP/GIF、GPU 后端（沿用 M1–M4 边界）。

## 1. 兼容性

- 新 CSS 能力只在文档实际声明时生效；未声明的文档输出不变；
- `paint-order` 缺省为 `fill stroke markers`，与 M4 渲染顺序一致；
- `mix-blend-mode` 缺省 `normal`、`isolation` 缺省 `auto`，不改变既有合成；
- `transform-origin` 缺省 `0 0`，`transform-box` 缺省 `view-box`，与 M1 的变换语义一致；
- `font-kerning` 缺省 `auto`，但仅在字体含 `kern`/`GPOS` 时生效；内置 Hershey 无字距表，输出不变；
- `SvgElement` 只新增方法，不改既有签名。

## 2. P1 CSS 扩展

### 2.1 选择器引擎

现有 `CssSelectorPart` 扩展为：

```cangjie
public enum CssSimpleSelectorKind {
    | Universal
    | Type(String)
    | Id(String)
    | Class(String)
    | Attribute(CssAttributeSelector)
    | PseudoClass(CssPseudoClass)
}
```

- `CssAttributeSelector` 含 `name` / `operator`（`Exists` / `Equals` / `Includes` / `DashMatch` / `Prefix` / `Suffix` / `Substring`）/ `value` / `caseInsensitive`；
- `CssPseudoClass` 含 `Root` / `FirstChild` / `LastChild` / `OnlyChild` / `NthChild(a, b)` / `FirstOfType` / `LastOfType` / `NthOfType(a, b)` / `OnlyOfType` / `Empty` / `Not(CssSimpleSelector)`；
- 匹配在 `SvgStyleResolver` 内完成，需要父元素与同名兄弟位置：`SvgElement` 已维护 `parent` 与 `siblingIndex`，直接复用；
- `:empty` 指无元素子节点且无文本（空白文本视为空）；
- 选择器特异性：类型/伪类各 +1，id +100，类/属性 +10，与既有规则合并。

### 2.2 `@media`

- 解析 `@media <query-list> { rules }`；
- 媒体类型只认 `screen` / `all`，`print` 等视为不匹配；
- 特性只认 `min-width` / `max-width`，单位 `px`；
- 宽度来源：渲染时根视口宽度（`SvgRenderOptions.width` 或根 `width`，缺省 300）；
- 不匹配的规则整段跳过；解析错误记 warning 并跳过该规则。

### 2.3 `@font-face`

- 仅读取 `font-family` 与可选的 `font-weight` / `font-style`；
- `src` 不加载，记一条 warning；
- 注册为别名：`font-family` 名称 → `SvgFontRegistry` 中已注册的字体（按 family 精确匹配；未注册则不生效）。

### 2.4 CSS 变量与 `calc()`

- 变量声明 `--name: value` 进入元素的计算样式（可继承）；空值视为无效；
- `var(--name, fallback)` 在值解析前展开，最多 8 层；循环引用使该声明无效并记 warning；
- `calc()` 语法：`<length> (('+'|'-'|'*'|'/') <number>|<length>)*`，括号；只处理长度与数字；
- 百分比在需要具体尺寸的属性上按既有规则解析，无法解析时回退初始值。

## 3. P2 SVG 2 渲染

### 3.1 `paint-order`

- 值为 `fill` / `stroke` / `markers` 的排列，缺失项按默认顺序补齐；
- 渲染树按该顺序发出命令；marker 位置由 `markers` 在序列中的位置决定；
- 非法值记 warning 并用默认顺序。

### 3.2 混合与隔离

- `mix-blend-mode` 作用于元素的隔离组结果与父图层；
- 非 `normal` 或 `isolation: isolate` 时建立离屏图层，合成时使用对应混合公式；
- 混合在预乘 RGBA 上进行，结果钳制；
- 组透明度、clip、mask、filter 的处理顺序不变。

### 3.3 `feDropShadow`

- 参数：`dx` / `dy` / `stdDeviation` / `flood-color` / `flood-opacity`；
- 实现为：alpha 通道模糊 → 偏移 → flood 着色 → 与原图 merge；
- 复用现有 blur 与 merge 原语，不新增像素算法。

### 3.4 `transform-origin` / `transform-box`

- `transform-origin`：1–2 个值（x y），支持长度、百分比、`left` / `center` / `right` / `top` / `bottom`；
- `transform-box: view-box` 以根视口为参考；`fill-box` 以元素包围盒为参考；
- 变换矩阵变为 `T(origin) × M × T(-origin)`。

### 3.5 `context-fill` / `context-stroke`

- 仅在 `use` 展开的实例内有效；解析为被引用元素的 `fill` / `stroke`；
- 无上下文时回退 `none` 并记 warning；
- 与 `currentColor` 的解析顺序：先 `context-*`，再 `currentColor`。

## 4. P3 文本整形

### 4.1 字距（kern / GPOS）

- `kern` 表 format 0：按键值对 `<left, right>` 查字距；
- `GPOS` Pair Adjustment format 1（glyph pair）与 format 2（class pair），只取 x advance 调整；
- 字距单位为字体设计单位，按 `unitsPerEm` 缩放；
- `font-kerning: none` 关闭，`normal` 强制启用，`auto` 有表时启用；
- 上限：`kern` 表条目 ≤ 65536，GPOS pair 集 ≤ 65536，超出记 warning 并忽略。

### 4.2 标准连字（GSUB liga）

- 解析 `GSUB` ScriptList / FeatureList / LookupList，只处理 `liga` 特性与 Lookup Type 4 format 1；
- 输入字形序列匹配后替换为连字字形，advance 取连字字形；
- 单次替换最多 4 个输入字形；lookup 深度 ≤ 8；
- 不处理上下文替换、链式上下文、扩展替换。

### 4.3 双向文本（UAX#9 子集）

- 字符方向类别：L / R / AL / EN / AN / WS / ON / B；
- 按段落方向（`direction`）分段，生成视觉顺序的 run 列表；
- 数字在 RTL 段落内保持 LTR 顺序；
- 括号配对只做单层镜像；
- `unicode-bidi: bidi-override` 强制按段落方向排列；
- 与 `textPath` 同时存在时按视觉顺序逐字排布。

### 4.4 `direction` / `unicode-bidi` / `font-kerning`

- `direction` 可继承，缺省 `ltr`；
- `unicode-bidi` 不继承，缺省 `normal`；
- 两者与 `writing-mode: tb-*` 同时存在时按竖排方向处理，`direction` 只决定列顺序。

## 5. P4 元素级 API

```cangjie
public class SvgElement {
    public func getBBox(options!: SvgBBoxOptions = SvgBBoxOptions()): ?SvgBounds
    public func getCTM(): SvgMatrix
    public func getScreenCTM(viewport!: ?SvgViewportTransform = None): SvgMatrix
    public func getElementsByClassName(name: String): ArrayList<SvgElement>
    public func querySelectorAll(selector: String): ArrayList<SvgElement>
}

public class SvgPath {
    public func getTotalLength(): Float64
    public func getPointAtLength(distance: Float64): SvgPoint
}
```

- `getBBox` 复用 `SvgGeometry.bounds`；`options.stroke` 为真时并入描边外扩；
- `getCTM` / `getScreenCTM` 复用 `SvgGeometry.ctm/screenCTM`；
- `querySelectorAll` 复用 P1 选择器引擎，按文档顺序返回；
- 所有方法不修改文档，不缓存跨调用状态。

## 6. 模块布局

| 文件 | 职责 |
|---|---|
| `CssSelector2.cj` | 属性/伪类/兄弟组合器解析与匹配 |
| `CssMedia.cj` | `@media` 解析与求值 |
| `CssVariables.cj` | CSS 变量与 `var()` 展开 |
| `CssCalc.cj` | `calc()` 表达式求值 |
| `SvgBlend.cj` | 混合模式与隔离组 |
| `SvgPaintOrder.cj` | `paint-order` 排序 |
| `SvgTransformOrigin.cj` | `transform-origin` / `transform-box` |
| `SvgContextPaint.cj` | `context-fill` / `context-stroke` |
| `SvgOpenTypeLayout.cj` | `kern` / `GPOS` / `GSUB` 表读取与整形 |
| `SvgBidi.cj` | UAX#9 子集 |
| `SvgElementApi.cj` | 元素级 API 薄封装 |

现有改动：`SvgStyleResolver.cj`（选择器与 CSS 特性）、`SvgParser`/`CssStyleSheet`（`@media`/`@font-face`）、`SvgRenderTree.cj`（paint-order/混合/transform-origin）、`SvgRenderer.cj`（混合与隔离组）、`SvgTextRenderer.cj`（整形与 bidi）、`SvgTrueTypeFont.cj`（`kern`/`GPOS`/`GSUB`）、`SvgElement.cj`（API）、`SvgOptions.cj`（媒体宽度来源）。

## 7. 安全与上限

| 项 | 默认上限 | 超限 |
|---|---|---|
| CSS 变量嵌套 | 8 层 | 声明无效 + warning |
| `calc()` 嵌套 | 16 层 | 声明无效 + warning |
| 选择器长度 | 256 个简单选择器 | 跳过该规则 + warning |
| `kern` 表条目 | 65536 | 忽略表 + warning |
| GPOS pair 集 | 65536 | 忽略子表 + warning |
| GSUB lookup 深度 | 8 | 停止替换 + warning |
| 连字输入长度 | 4 个字形 | 不替换 |
| bidi 段落长度 | 受 `maxElements`/文本长度约束 | — |

## 8. 验收判据

- M1–M4 的 710 条用例零回归，M1–M3 的 13 张快照与 M4 的 4 张快照逐字节一致；
- 每个 Requirement 至少 1 个可执行 Scenario；
- `cjpm test` 全绿，`f_svg` 自身 0 warning；
- 选择器、`@media`、变量、`calc()`、混合模式、`feDropShadow`、`transform-origin`、整形、bidi、元素 API 均有独立断言；
- 所有上限有负向用例；
- `openspec validate --strict` 通过。

## 9. 实施顺序

1. P1 选择器（属性/伪类/兄弟）→ 2. P1 `@media` / `@font-face` / 变量 / `calc()`；
2. P2 `paint-order` → 混合与隔离 → `feDropShadow` → `transform-origin` → `context-*`；
3. P3 `kern`/`GPOS` → `GSUB` → bidi → 属性接入；
4. P4 元素级 API；
5. 快照、基准、文档与验收。

## 10. 已定契约

- 未声明新特性的文档输出与 M4 逐字节一致；
- 新增属性只进既有级联表，不改级联顺序；
- `@font-face` 不加载任何文件，只做别名；
- 文本整形只支持拉丁/西里尔/希腊与基础连字，不做复杂脚本；
- 元素级 API 为薄封装，不引入新的渲染状态；
- 选择器引擎与 `querySelectorAll` 共用同一实现。
