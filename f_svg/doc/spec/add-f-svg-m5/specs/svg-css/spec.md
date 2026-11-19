# svg-css

## MODIFIED Requirements

### Requirement: CSS 规则集解析

系统 SHALL 提供 `CssStyleSheet.parse(text)` 与 `CssStyleSheet.parse(text, warnings)`，把 CSS 文本解析为有序规则列表；同时 SHALL 提供 `CssStyleSheet.empty()` 表示空样式表。

支持的语法子集 SHALL 为：规则集 `selectorList { declarations }`、`@media <query-list> { rules }`、`@font-face { declarations }`、声明 `property: value;`、`/* ... */` 注释、`!important`、单引号与双引号字符串、`url(...)` 原样保留、属性选择器、结构伪类、`:not()`、`+` / `~` 兄弟组合器。

不支持的构造 SHALL 为：`@import`、`@charset`、`@supports`、`@layer`、`@container`、伪元素（`::before` / `::after`）、选择器中的命名空间前缀（`|`）与反斜杠转义。遇到不支持的 at-rule SHALL 跳过其整段（含配对花括号），遇到不支持的规则 SHALL 跳过整条规则，均不影响后续规则，并在提供 `warnings` 时追加一条包含构造名的告警。

`@media` 规则 SHALL 保留其条件与源顺序；`@font-face` SHALL 解析为独立的字体别名条目，不参与普通规则列表。每条普通规则的 `order` SHALL 为其在样式表中出现的顺序（从 0 递增）；`@media` 内规则按展开后的源顺序参与级联。规则的 `selectors` 保留分组顺序，`declarations` 保留源顺序。

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

### Requirement: 选择器模型与匹配

系统 SHALL 提供 `CssSelector`，由有序的复合选择器部分与组合符 `CssCombinator`（`Descendant` / `Child` / `AdjacentSibling` / `GeneralSibling`）构成。

单个复合选择器 SHALL 由有序的 `CssSimpleSelectorKind` 组成，种类为 `Universal`、`Type(String)`、`Id(String)`、`Class(String)`、`Attribute(CssAttributeSelector)`、`PseudoClass(CssPseudoClass)`；`CssSelectorPart` 的既有 `typeName` / `id` / `classes` 字段 SHALL 保留，并分别反映该复合选择器中的类型、id 与类名集合。

`CssSelector.matches(element)` SHALL 按「最右部分匹配当前元素、向左逐段回溯」的规则求值；`Descendant` 允许任意祖先，`Child` 只允许直接父元素，`AdjacentSibling` 只允许紧邻的前一个元素兄弟，`GeneralSibling` 允许任意前序元素兄弟。id SHALL 精确匹配 `id` 属性；类 SHALL 按空白分隔的 `class` 属性逐词匹配；类型 SHALL 匹配 `tag`。

`CssSpecificity` SHALL 为 `(ids, classes, types)` 三元组；id 计 `(1,0,0)`，类与属性选择器各计 `(0,1,0)`，类型选择器与伪类各计 `(0,0,1)`，`*` 不计入；`:not()` 只计伪类自身一次，参数不另计。比较顺序为 `ids` → `classes` → `types`。

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

## ADDED Requirements

### Requirement: 属性选择器

系统 SHALL 支持 `[attr]`、`[attr=v]`、`[attr~=v]`、`[attr|=v]`、`[attr^=v]`、`[attr$=v]`、`[attr*=v]` 七种属性选择器，并 SHALL 支持在右方括号前追加 `i` 标志使值比较对 ASCII 大小写不敏感。

属性值 SHALL 接受不带引号、单引号与双引号三种写法；不带引号的值只含标识符字符。属性不存在时全部七种形式均不匹配；`~=` 按空白分词后整词比较，`|=` 匹配等于值或以「值 + `-`」开头的值。

空属性值、缺少属性名、运算符后缺少值 SHALL 使该选择器无效并被跳过，同时记 warning。

#### Scenario: 存在与等值

- **WHEN** 元素为 `<rect fill="red" data-x="a b"/>`
- **THEN** `[fill]`、`[fill=red]`、`[data-x~=b]` 匹配，`[fill=blue]` 不匹配

#### Scenario: 前缀后缀子串

- **WHEN** 元素属性为 `data-code="zh-CN-01"`
- **THEN** `[data-code^=zh]`、`[data-code$=01]`、`[data-code*=CN]` 均匹配

#### Scenario: 连字符匹配

- **WHEN** 元素属性为 `lang="zh-CN"`
- **THEN** `[lang|=zh]` 与 `[lang|=zh-CN]` 匹配，`[lang|=z]` 不匹配

#### Scenario: 大小写不敏感

- **WHEN** 元素属性为 `data-x="Red"`，选择器为 `[data-x=red i]`
- **THEN** 匹配；去掉 `i` 后不匹配

#### Scenario: 非法选择器

- **WHEN** 样式表含 `[data-x=] { fill: red }` 并传入 `warnings`
- **THEN** 该规则被跳过，`warnings` 包含属性选择器相关告警

### Requirement: 结构伪类

系统 SHALL 支持 `:root`、`:first-child`、`:last-child`、`:only-child`、`:nth-child(An+B)`、`:first-of-type`、`:last-of-type`、`:nth-of-type(An+B)`、`:only-of-type`、`:empty`。

结构伪类 SHALL 只按元素兄弟计数，忽略文本、注释与处理指令节点。`:root` SHALL 匹配没有父元素的文档根元素；`:empty` SHALL 在元素没有元素子节点且文本内容为空白时匹配。`An+B` SHALL 接受 `odd` / `even` / 整数 / `An+B` / `An-B` / `n` / `-n+B`，索引从 1 开始且只匹配正索引。

非法 `An+B` 表达式 SHALL 使该规则被跳过并记 warning。

#### Scenario: 首尾与唯一

- **WHEN** `<g><rect/><circle/><rect/></g>`
- **THEN** 第一个 `rect` 匹配 `:first-child`，最后一个 `rect` 匹配 `:last-child`，`circle` 匹配 `:only-of-type` 但不匹配 `:only-child`

#### Scenario: nth-child 表达式

- **WHEN** 父元素有 5 个元素子节点
- **THEN** `:nth-child(odd)` 匹配第 1、3、5 个，`:nth-child(2n+1)` 结果相同，`:nth-child(-n+2)` 只匹配前两个

#### Scenario: root 与 empty

- **WHEN** 文档根为 `<svg><g/></svg>`，其中 `g` 只含空白文本
- **THEN** `svg` 匹配 `:root`，`g` 匹配 `:empty`

#### Scenario: 非法 nth

- **WHEN** 样式表含 `:nth-child(2n+) { fill: red }`
- **THEN** 该规则被跳过并追加 warning

### Requirement: 否定伪类

系统 SHALL 支持 `:not(<简单选择器>)`，其中参数 SHALL 为单个简单选择器（类型、`*`、`.class`、`#id`、属性选择器或结构伪类）。

`:not()` SHALL 不匹配参数本身命中的元素；参数为结构伪类时按同一兄弟上下文求值。嵌套 `:not(:not(...))`、复合参数（如 `:not(.a.b)`）与空参数 SHALL 使该规则被跳过并记 warning。

#### Scenario: 排除类

- **WHEN** 样式表为 `rect:not(.skip) { fill: red }`，文档含 `class="skip"` 与无类名的两个 `rect`
- **THEN** 只有无类名的 `rect` 被填充

#### Scenario: 否定结构伪类

- **WHEN** 选择器为 `rect:not(:first-child)`
- **THEN** 父元素下第一个 `rect` 不匹配，其余 `rect` 匹配

#### Scenario: 嵌套被拒绝

- **WHEN** 样式表含 `:not(:not(.a)) { fill: red }` 并传入 `warnings`
- **THEN** 该规则被跳过并追加 warning

### Requirement: 兄弟组合器

系统 SHALL 支持相邻兄弟组合器 `+` 与一般兄弟组合器 `~`。

`A + B` SHALL 只匹配紧邻 `A` 之后的元素 `B`；`A ~ B` SHALL 匹配 `A` 之后任意位置的元素 `B`。两者 SHALL 忽略文本、注释与处理指令节点，只按元素兄弟计算；跨父元素不匹配。组合器两侧允许任意空白。

#### Scenario: 相邻兄弟

- **WHEN** 结构为 `<rect/><circle/><rect/>`
- **THEN** `rect + circle` 匹配 `circle`，`circle + rect` 匹配第三个元素

#### Scenario: 一般兄弟

- **WHEN** 结构为 `<rect/><g/><circle/>`
- **THEN** `rect ~ circle` 匹配 `circle`，`circle ~ rect` 不匹配

#### Scenario: 不跨父元素

- **WHEN** 结构为 `<g><rect/></g><circle/>`
- **THEN** `rect + circle` 不匹配

### Requirement: @media 求值

系统 SHALL 解析 `@media <query-list> { rules }` 并只在条件匹配时把内部规则纳入级联。

媒体类型 SHALL 只认 `screen` 与 `all`，`print`、`speech` 等其他类型视为不匹配。媒体特性 SHALL 只认 `(min-width: Npx)` 与 `(max-width: Npx)`，比较对象为渲染视口宽度（逻辑宽度）；条件之间 SHALL 支持 `and`，多个查询之间 SHALL 支持逗号分隔的「或」语义。

不匹配的查询 SHALL 整段跳过，且不产生 warning；无法解析的查询 SHALL 跳过该查询并记 warning。媒体宽度 SHALL 由渲染入口传入；独立调用样式解析且未提供宽度时 SHALL 使用 300。

#### Scenario: 宽度命中

- **WHEN** 视口宽 800，样式表含 `@media screen and (min-width: 600px) { rect { fill: red } }`
- **THEN** 规则生效，`rect` 填充为红

#### Scenario: 宽度不命中

- **WHEN** 视口宽 400，同一规则
- **THEN** 规则不生效，不产生 `@media` 相关 warning

#### Scenario: 逗号或列表

- **WHEN** 视口宽 400，查询为 `(max-width: 500px), (min-width: 1000px)`
- **THEN** 因第一个查询命中而生效

#### Scenario: 非 screen 类型

- **WHEN** 查询为 `print and (min-width: 0px)`
- **THEN** 规则不生效

#### Scenario: 非法查询

- **WHEN** 查询为 `screen and (min-width: abc)` 并传入 `warnings`
- **THEN** 该查询被跳过，`warnings` 包含 `@media` 与 `min-width`

### Requirement: @font-face 别名

系统 SHALL 解析 `@font-face` 的 `font-family`、可选 `font-weight` 与 `font-style`，把该 family 名称注册为字体别名。目标 family SHALL 取自 `src` 中的 `local(<family>)`；`src` 无 `local()` 时，仅当同名 family 已注册才建立恒等别名。

`src`、`unicode-range`、`font-display` 等其余声明 SHALL 被忽略，且 `src` SHALL 追加一条 warning；本模块 SHALL NOT 加载任何字体文件或发起网络请求。别名只在本次渲染内生效，SHALL NOT 修改调用方传入的字体注册表。目标 family 未注册时别名 SHALL 不生效并记 warning。

#### Scenario: 别名指向已注册字体

- **WHEN** 注册表已注册 family `Brand`，样式表声明 `@font-face { font-family: Body; src: local(Brand) }`，文本 `font-family="Body"`
- **THEN** 文本使用 `Brand` 的字体渲染

#### Scenario: 未注册目标

- **WHEN** `@font-face { font-family: Missing; src: url(x.ttf) }` 且注册表没有 `Missing`
- **THEN** 别名不生效，文本按常规 family 回退并记 warning

#### Scenario: 不修改输入注册表

- **WHEN** 使用同一 `SvgFontRegistry` 连续渲染两个文档，第二个文档不含 `@font-face`
- **THEN** 第二个文档的别名解析结果与首个文档渲染前一致

### Requirement: CSS 变量

系统 SHALL 支持自定义属性 `--name: value` 的声明、继承与 `var(--name, fallback)` 引用。

自定义属性 SHALL 按元素计算样式继承，声明值 SHALL 保留原文；空值 SHALL 视为无效。`var()` SHALL 在属性值归一化前展开，嵌套解析深度 SHALL 不超过 8 层；引用不存在且未提供 fallback、或检测到循环引用时，该声明 SHALL 无效并记 warning。fallback 内 SHALL 允许再出现 `var()`。

`var()` SHALL 可用于普通属性值与 `calc()` 内部；展开结果 SHALL 再按该属性的既有规则归一化。自定义属性本身 SHALL NOT 参与渲染。

#### Scenario: 基本替换

- **WHEN** `:root { --brand: red } rect { fill: var(--brand) }`
- **THEN** `rect` 的计算 `fill` 为红色

#### Scenario: 继承与覆盖

- **WHEN** `<g style="--c: red"><rect style="--c: blue"/><circle/></g>`
- **THEN** `rect` 使用蓝色，`circle` 继承红色

#### Scenario: fallback

- **WHEN** `fill: var(--missing, green)`
- **THEN** 计算 `fill` 为绿色，不产生 warning

#### Scenario: 循环引用

- **WHEN** `--a: var(--b); --b: var(--a);` 且 `fill: var(--a)`
- **THEN** 该 `fill` 声明无效并回退初始值，追加包含 `var` 的 warning

#### Scenario: 八层上限

- **WHEN** `--v1: var(--v2)` 至 `--v8: var(--v9)` 共 9 层引用
- **THEN** 展开在 8 层处停止，引用声明无效并追加 warning

### Requirement: calc() 表达式

系统 SHALL 在长度属性上支持 `calc()` 表达式，语法为长度或数字与 `+`、`-`、`*`、`/`、括号的组合。

运算数 SHALL 接受数字、`px`、`%`、`em` 长度；`*` 与 `/` 的至少一侧 SHALL 为数字，除数为 0 或非有限数 SHALL 使表达式无效。括号嵌套深度 SHALL 不超过 16 层。全为绝对长度（`px` / `em`，`em` 按当前字号换算）时结果 SHALL 归一为 `px`；全为百分比时结果 SHALL 归一为百分比；混合百分比与绝对长度 SHALL 使表达式无效。无效表达式 SHALL 回退该属性的既有初始值或继承值并记 warning。

`calc()` SHALL NOT 用于颜色、画笔、枚举与变换列表；出现在这些属性中 SHALL 按非法值处理。

#### Scenario: 四则运算

- **WHEN** `font-size="20"`、`stroke-width: calc(10px + 2 * 3px)`
- **THEN** 计算值为 `16px`

#### Scenario: em 换算

- **WHEN** `font-size="20"`、`letter-spacing: calc(1em - 5px)`
- **THEN** 计算值为 `15px`

#### Scenario: 括号

- **WHEN** `width: calc((10px + 5px) * 2)`
- **THEN** 计算值为 `30px`

#### Scenario: 百分比

- **WHEN** `stroke-width: calc(50% + 10%)`
- **THEN** 计算值为 `60%`

#### Scenario: 混合单位无效

- **WHEN** `stroke-width: calc(50% + 10px)`
- **THEN** 回退初始值 `1` 并追加包含 `calc` 的 warning

#### Scenario: 除零

- **WHEN** `stroke-width: calc(10px / 0)`
- **THEN** 回退初始值并追加 warning

### Requirement: M5 新增属性注册与归一化

计算样式 SHALL 注册 M5 新增属性并定义继承性与初始值：

- `paint-order`：可继承，初始 `fill stroke markers`；
- `mix-blend-mode`：不可继承，初始 `normal`；
- `isolation`：不可继承，初始 `auto`；
- `transform-origin`：不可继承，初始 `0 0`；
- `transform-box`：不可继承，初始 `view-box`；
- `direction`：可继承，初始 `ltr`；
- `unicode-bidi`：不可继承，初始 `normal`；
- `font-kerning`：可继承，初始 `auto`。

上述属性 SHALL 同时支持呈现属性、`<style>` 规则与内联 `style=""`，并遵循既有级联顺序；非法值 SHALL 回退初始值并记 warning。`transform-origin` SHALL 归一为「水平值 + 垂直值」，缺失的垂直值 SHALL 取 `center`。

#### Scenario: 缺省值

- **WHEN** 元素未声明上述任何属性
- **THEN** 计算值依次为 `fill stroke markers`、`normal`、`auto`、`0 0`、`view-box`、`ltr`、`normal`、`auto`

#### Scenario: 继承性

- **WHEN** 父元素声明 `paint-order="stroke fill"` 与 `mix-blend-mode="multiply"`
- **THEN** 子元素继承 `paint-order`，但 `mix-blend-mode` 为 `normal`

#### Scenario: transform-origin 单值

- **WHEN** `transform-origin="50%"`
- **THEN** 计算值归一为 `50% center`

#### Scenario: 非法混合模式

- **WHEN** `mix-blend-mode="plus-lighter"`
- **THEN** 计算值为 `normal` 并追加 warning
