# svg-css

## MODIFIED Requirements

### Requirement: CSS 规则集解析

系统 SHALL 提供 `CssStyleSheet.parse(text)` 与 `CssStyleSheet.parse(text, warnings)`，把 CSS 文本解析为有序规则列表；同时 SHALL 提供 `CssStyleSheet.empty()` 表示空样式表。

支持的语法子集 SHALL 为：规则集 `selectorList { declarations }`、`@media <query-list> { rules }`、`@font-face { declarations }`、`@color-profile <name> { declarations }`、声明 `property: value;`、`/* ... */` 注释、`!important`、单引号与双引号字符串、`url(...)` 原样保留、属性选择器、结构伪类、交互伪类、`:not()`、`+` / `~` 兄弟组合器。

不支持的构造 SHALL 为：`@import`、`@charset`、`@supports`、`@layer`、`@container`、伪元素（`::before` / `::after`）、选择器中的命名空间前缀（`|`）与反斜杠转义。遇到不支持的 at-rule SHALL 跳过其整段（含配对花括号），遇到不支持的规则 SHALL 跳过整条规则，均不影响后续规则，并在提供 `warnings` 时追加一条包含构造名的告警。

`@media` 规则 SHALL 保留其条件与源顺序；`@font-face` SHALL 解析为独立的字体别名条目，`@color-profile` SHALL 解析为独立的颜色配置条目，二者均不参与普通规则列表。每条普通规则的 `order` SHALL 为其在样式表中出现的顺序（从 0 递增）；`@media` 内规则按展开后的源顺序参与级联。规则的 `selectors` 保留分组顺序，`declarations` 保留源顺序。

`CssDeclaration.value` SHALL 保留声明值的原文（含引号与 `url()`），但去除首尾空白与尾部 `!important`；`important` 标志单独记录。普通属性名 SHALL 转小写；以 `--` 开头的自定义属性名 SHALL 保留原始大小写。

#### Scenario: 解析基本规则

- **WHEN** 输入 `rect { fill: red } .a, #b { stroke: blue !important }`
- **THEN** 得到两条规则：第一条 1 个选择器、1 条声明；第二条 2 个选择器、1 条声明且 `important == true`；`order` 分别为 0、1

#### Scenario: 跳过不支持构造

- **WHEN** 输入 `@import url(x.css); @supports (display: grid) { rect { fill: red } } rect { fill: blue }` 并传入 `warnings`
- **THEN** 结果只含 `rect { fill: blue }` 一条规则，`warnings` 至少两条分别包含 `@import` 与 `@supports`

#### Scenario: 注释与字符串

- **WHEN** 输入 `rect { /* x */ fill: "a;b" }`
- **THEN** 解析成功，声明值为 `"a;b"`（含引号原样保留），注释不产生规则

#### Scenario: 截断恢复

- **WHEN** 输入 `rect { fill: red`（缺少右花括号）
- **THEN** 解析成功并保留已读声明，同时向 `warnings` 追加一条截断告警

#### Scenario: 自定义属性大小写

- **WHEN** 输入 `rect { --Brand-Color: red; FILL: blue }`
- **THEN** 自定义属性名为 `--Brand-Color`（大小写保留），普通属性名为 `fill`

#### Scenario: 解析 @color-profile

- **WHEN** 输入 `@color-profile display-p3 { src: url(p3.icc) } rect { fill: red }`
- **THEN** 得到一条 `color-profiles` 条目（名称 `display-p3`）与一条普通规则，普通规则的 `order` 为 0

### Requirement: 选择器模型与匹配

系统 SHALL 提供 `CssSelector`，由有序的复合选择器部分与组合符 `CssCombinator`（`Descendant` / `Child` / `AdjacentSibling` / `GeneralSibling`）构成。

单个复合选择器 SHALL 由有序的 `CssSimpleSelectorKind` 组成，种类为 `Universal`、`Type(String)`、`Id(String)`、`Class(String)`、`Attribute(CssAttributeSelector)`、`PseudoClass(CssPseudoClass)`；`CssSelectorPart` 的既有 `typeName` / `id` / `classes` 字段 SHALL 保留，并分别反映该复合选择器中的类型、id 与类名集合。

`CssSelector.matches(element)` SHALL 按「最右部分匹配当前元素、向左逐段回溯」的规则求值；`Descendant` 允许任意祖先，`Child` 只允许直接父元素，`AdjacentSibling` 只允许紧邻的前一个元素兄弟，`GeneralSibling` 允许任意前序元素兄弟。id SHALL 精确匹配 `id` 属性；类 SHALL 按空白分隔的 `class` 属性逐词匹配；类型 SHALL 匹配 `tag`。

`CssSpecificity` SHALL 为 `(ids, classes, types)` 三元组；id 计 `(1,0,0)`，类与属性选择器各计 `(0,1,0)`，类型选择器与伪类各计 `(0,0,1)`，`*` 不计入；`:not()` 只计伪类自身一次，参数不另计。比较顺序为 `ids` → `classes` → `types`。

`CssPseudoClass` SHALL 新增 `Hover` 与 `Focus` 构造器。`CssSelector.matches(element)` SHALL 等价于在空交互状态下求值，交互伪类永不匹配；新增重载 `CssSelector.matches(element, interaction)` SHALL 按显式交互状态求值。交互伪类 SHALL 可出现在复合选择器与 `:not()` 参数中，特异性仍各计 `(0,0,1)`。

#### Scenario: 五类基本选择器

- **WHEN** 元素为 `<rect id="b" class="a c"/>`
- **THEN** `rect`、`.a`、`.c`、`#b`、`*` 均匹配

#### Scenario: 后代与子代

- **WHEN** 结构为 `svg > g > rect`
- **THEN** `g rect` 与 `svg > g` 匹配，`svg > rect` 不匹配

#### Scenario: 复合选择器

- **WHEN** 选择器为 `rect.a#b[data-x]`，元素为 `<rect id="b" class="a" data-x="1"/>`
- **THEN** 匹配；元素缺少 `data-x` 时不匹配

#### Scenario: 特异性

- **WHEN** 选择器分别为 `#a`、`.x.y`、`rect[data-x]`、`:first-child`、`*`、`:not(.x)`
- **THEN** 特异性依次为 `(1,0,0)`、`(0,2,0)`、`(0,1,1)`、`(0,0,1)`、`(0,0,0)`、`(0,0,1)`

#### Scenario: 空交互状态

- **WHEN** 选择器为 `rect:hover`，调用 `matches(element)`（不传交互状态）
- **THEN** 不匹配

#### Scenario: 交互伪类特异性

- **WHEN** 选择器分别为 `:hover`、`:focus`、`rect:hover`、`:not(:hover)`
- **THEN** 特异性依次为 `(0,0,1)`、`(0,0,1)`、`(0,0,2)`、`(0,0,1)`

## ADDED Requirements

### Requirement: M6 交互伪类求值

系统 SHALL 提供显式交互状态，包含 `hoveredIds` 与 `focusedIds` 两个字符串集合。元素 `id` 在 `hoveredIds` 内时 SHALL 匹配 `:hover`；`focusedIds` 中第一个能解析到文档元素的 id SHALL 作为唯一聚焦元素匹配 `:focus`。无 `id` 的元素 SHALL 永不匹配交互伪类。

#### Scenario: hover 命中

- **WHEN** 文档含 `<rect id="a"/>`，交互状态 `hoveredIds = ["a"]`
- **THEN** `rect:hover` 匹配该矩形

#### Scenario: hover 未提供

- **WHEN** 交互状态为空
- **THEN** `rect:hover` 不匹配任何元素

#### Scenario: focus 只取第一个

- **WHEN** `focusedIds = ["outer", "inner"]`，两个元素均存在
- **THEN** 只有 `outer` 匹配 `:focus`，`inner` 不匹配

#### Scenario: 无 id 元素

- **WHEN** 元素没有 `id`，交互状态非空
- **THEN** `:hover` 与 `:focus` 均不匹配

#### Scenario: 与 :not 组合

- **WHEN** 元素 `id="a"` 在 `hoveredIds` 内，选择器为 `rect:not(:hover)`
- **THEN** 不匹配；把元素从集合移除后匹配

### Requirement: M6 交互与光标属性

`pointer-events` SHALL 接受 `auto` / `none` / `visiblePainted` / `visibleFill` / `visibleStroke` / `visible` / `painted` / `fill` / `stroke` / `all` / `bounding-box`，初始值 `auto`，可继承；`cursor` SHALL 解析为字符串，初始值 `auto`，可继承。两者 SHALL 只进入计算样式并供命中测试 / 查询使用，SHALL NOT 改变绘制输出；`cursor` SHALL NOT 加载任何光标资源。

#### Scenario: pointer-events 全部取值

- **WHEN** 声明 `pointer-events` 为 11 个合法取值之一
- **THEN** 计算样式返回该取值，`warnings` 为空

#### Scenario: pointer-events 非法值

- **WHEN** 声明 `pointer-events: magic`
- **THEN** 计算样式回退 `auto`，`warnings` 含该属性名

#### Scenario: cursor 关键字

- **WHEN** 声明 `cursor: crosshair`
- **THEN** 计算样式返回 `crosshair`，不产生 warning

#### Scenario: cursor 非法值

- **WHEN** 声明 `cursor: url(cursor.cur)`
- **THEN** 计算样式回退 `auto` 并 warning，不读取该资源

#### Scenario: 不影响绘制

- **WHEN** 同一文档分别声明与不声明 `pointer-events: none`
- **THEN** 两次渲染的位图逐字节一致

### Requirement: M6 渲染提示属性注册

`shape-rendering` / `text-rendering` / `color-rendering` / `color-interpolation` SHALL 可继承，初始值均为 `auto`。合法取值分别为：`shape-rendering` 的 `auto` / `optimizeSpeed` / `crispEdges` / `geometricPrecision`；`text-rendering` 的 `auto` / `optimizeSpeed` / `optimizeLegibility` / `geometricPrecision`；`color-rendering` 的 `auto` / `optimizeSpeed` / `optimizeQuality`；`color-interpolation` 的 `auto` / `sRGB` / `linearRGB`。非法值 SHALL 回退 `auto` 并 warning。

#### Scenario: 缺省值

- **WHEN** 文档未声明四个属性
- **THEN** 四个计算样式均为 `auto`

#### Scenario: 合法取值往返

- **WHEN** 分别声明 `shape-rendering: crispEdges`、`text-rendering: optimizeLegibility`、`color-rendering: optimizeQuality`、`color-interpolation: linearRGB`
- **THEN** 四个计算样式返回对应字符串

#### Scenario: 非法值回退

- **WHEN** 声明 `shape-rendering: sharp`
- **THEN** 计算样式为 `auto`，`warnings` 含 `shape-rendering`

### Requirement: M6 颜色配置

系统 SHALL 解析 `@color-profile <name> { src: ... }` 并通过 `CssStyleSheet.colorProfiles` 暴露名称与 `src` 原文；`color-profile` 属性 SHALL 接受 `auto` / `sRGB` / 已声明名称，初始值 `auto`。未声明的名称与其他值 SHALL 回退 `sRGB` 并 warning；除 `sRGB` 外的 profile SHALL 按 sRGB 计算，SHALL NOT 做 ICC 变换。

#### Scenario: 声明被记录

- **WHEN** 输入 `@color-profile p3 { src: url(a.icc) }`
- **THEN** `colorProfiles` 含名称 `p3` 与 `src` 原文 `url(a.icc)`

#### Scenario: 已声明名称

- **WHEN** 声明 `p3` 后设置 `color-profile: p3`
- **THEN** 计算样式返回 `p3` 并 warning「按 sRGB 处理」，渲染像素与 `sRGB` 一致

#### Scenario: 未声明名称

- **WHEN** 设置 `color-profile: unknown`
- **THEN** 计算样式回退 `sRGB` 并 warning

#### Scenario: 缺少 src

- **WHEN** 输入 `@color-profile empty { }`
- **THEN** 仍记录该名称，`src` 为 `None`

### Requirement: M6 字体选择属性

`font-stretch` SHALL 接受 `ultra-condensed` / `extra-condensed` / `condensed` / `semi-condensed` / `normal` / `semi-expanded` / `expanded` / `extra-expanded` / `ultra-expanded` 与百分比，初始值 `normal`；`font-variant` SHALL 接受 `normal` 与 `small-caps`，初始值 `normal`；`font-size-adjust` SHALL 接受 `none` 或正数，初始值 `none`。三者 SHALL 可继承并参与字体匹配与文本布局；非法值 SHALL 回退初始值并 warning。

#### Scenario: 关键字与百分比

- **WHEN** 声明 `font-stretch: condensed` 与 `font-stretch: 75%`
- **THEN** 计算样式分别返回 `condensed` 与 `75%`

#### Scenario: small-caps 归一化

- **WHEN** 声明 `font-variant: small-caps`
- **THEN** 计算样式返回 `small-caps`

#### Scenario: font-size-adjust 数值

- **WHEN** 声明 `font-size-adjust: 0.5`
- **THEN** 计算样式返回 `0.5`；声明 `-1` 时回退 `none` 并 warning

#### Scenario: 继承

- **WHEN** 父元素声明 `font-stretch: expanded`，子元素未声明
- **THEN** 子元素计算样式为 `expanded`

### Requirement: M6 OpenType 特性属性

`font-feature-settings` SHALL 解析为有序的 OpenType tag 开关集合，语法为 `"tag" <0|1|on|off>` 列表；条目超过 64 时 SHALL 忽略多余条目并 warning。`font-variant-ligatures` SHALL 接受 `none` / `common-ligatures` / `discretionary-ligatures` / `historical-ligatures` / `contextual`，初始值 `normal`。两者可继承；合并时 `font-feature-settings` 优先于 `font-variant-ligatures`。

#### Scenario: 解析 tag 开关

- **WHEN** 声明 `font-feature-settings: "liga" 0, "kern" 1`
- **THEN** 得到 `liga=off`、`kern=on` 两个开关

#### Scenario: 禁用常见连字

- **WHEN** 声明 `font-variant-ligatures: none`
- **THEN** `liga` 与 `clig` 均关闭

#### Scenario: 显式设置覆盖变体

- **WHEN** 同时声明 `font-variant-ligatures: none` 与 `font-feature-settings: "liga" 1`
- **THEN** `liga` 开启，`clig` 关闭

#### Scenario: 条目上限

- **WHEN** 声明 65 个 tag 开关
- **THEN** 只保留前 64 个并 warning

### Requirement: M6 装饰长属性

系统 SHALL 注册 `text-decoration-line` / `text-decoration-style` / `text-decoration-color` / `text-decoration-thickness` 与 `text-underline-position`；`text-decoration` 简写 SHALL 展开为对应长属性。长属性缺省时 SHALL 沿用简写值或缺省值；非法值 SHALL 回退并 warning。

#### Scenario: 简写展开

- **WHEN** 声明 `text-decoration: underline dotted red`
- **THEN** `-line` 为 `underline`、`-style` 为 `dotted`、`-color` 为 `red`

#### Scenario: 组合线型

- **WHEN** 声明 `text-decoration-line: underline overline line-through`
- **THEN** 三条线均启用

#### Scenario: 缺省颜色

- **WHEN** 声明 `text-decoration-line: underline`，未声明 `-color`
- **THEN** 颜色取 `currentColor`

#### Scenario: 非法样式

- **WHEN** 声明 `text-decoration-style: zigzag`
- **THEN** 回退 `solid` 并 warning
