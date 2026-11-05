# svg-css

## ADDED Requirements

### Requirement: CSS 规则集解析

系统 SHALL 提供 `CssStyleSheet.parse(text)` 与 `CssStyleSheet.parse(text, warnings)`，把 CSS 文本解析为有序规则列表；同时 SHALL 提供 `CssStyleSheet.empty()` 表示空样式表。

支持的语法子集 SHALL 为：规则集 `selectorList { declarations }`、声明 `property: value;`、`/* ... */` 注释、`!important`、单引号与双引号字符串、`url(...)` 原样保留。

不支持的构造 SHALL 为：`@media`、`@import`、`@font-face`、任何伪类、任何属性选择器。遇到时 SHALL 跳过整条规则（不影响后续规则），并在提供 `warnings` 时追加一条包含构造名的告警。

每条规则的 `order` SHALL 为其在样式表中出现的顺序（从 0 递增）；规则的 `selectors` 保留分组顺序，`declarations` 保留源顺序。

#### Scenario: 解析基本规则

- **WHEN** 输入 `rect { fill: red } .a, #b { stroke: blue !important }`
- **THEN** 得到两条规则：第一条 1 个选择器、1 条声明；第二条 2 个选择器、1 条声明且 `important == true`；`order` 分别为 0、1

#### Scenario: 跳过不支持构造

- **WHEN** 输入 `@media screen { rect { fill: red } } rect { fill: blue }` 并传入 `warnings`
- **THEN** 结果只含 `rect { fill: blue }` 一条规则，`warnings` 至少一条包含 `@media`

#### Scenario: 注释与字符串

- **WHEN** 输入 `rect { /* x */ fill: "a;b" }`
- **THEN** 解析成功，声明值为 `"a;b"`（含引号原样保留），注释不产生规则

#### Scenario: 截断恢复

- **WHEN** 输入 `rect { fill: red`（缺少右花括号）
- **THEN** 解析成功并保留已读声明，同时向 `warnings` 追加一条截断告警

### Requirement: 选择器模型与匹配

系统 SHALL 提供 `CssSelector`，由有序的 `CssSelectorPart` 与组合符 `CssCombinator`（`Descendant` / `Child`）构成。

单个选择器部分 SHALL 支持类型选择器、`.class`、`#id`、`*` 及其复合形式（如 `rect.foo#bar`）。

`CssSelector.matches(element)` SHALL 按「最右部分匹配当前元素、向左逐段回溯」的规则求值；`Descendant` 允许任意祖先，`Child` 只允许直接父元素。ID SHALL 精确匹配 `id` 属性；类 SHALL 按空白分隔的 `class` 属性逐词匹配；类型 SHALL 匹配 `tag`。

`CssSpecificity` SHALL 为 `(ids, classes, types)` 三元组，`*` 不计入；比较顺序为 `ids` → `classes` → `types`。

#### Scenario: 五类基本选择器

- **WHEN** 元素为 `<rect id="b" class="a c"/>`
- **THEN** `rect`、`.a`、`.c`、`#b`、`*` 均匹配

#### Scenario: 后代与子代

- **WHEN** 结构为 `svg > g > rect`
- **THEN** `g rect` 与 `svg > g` 匹配，`svg > rect` 不匹配

#### Scenario: 复合选择器

- **WHEN** 选择器为 `rect.a#b`，元素为 `<rect id="b" class="a"/>`
- **THEN** 匹配；元素改为 `class="ab"` 时 `.a` 不匹配

#### Scenario: 特异性

- **WHEN** 选择器分别为 `#a`、`.x.y`、`rect`、`*`
- **THEN** 特异性依次为 `(1,0,0)`、`(0,2,0)`、`(0,0,1)`、`(0,0,0)`

### Requirement: 级联顺序与特异性

系统 SHALL 按以下优先级从低到高确定每个属性的胜出值：

1. UA 默认值；
2. 呈现属性（如 `fill="red"`）；
3. `<style>` 规则（按特异性，再按源顺序）；
4. 内联 `style=""` 声明；
5. `!important` 声明。

排序键 SHALL 依次为：`important` 标志、来源等级、特异性、源顺序。内联样式在非 `!important` 组中 SHALL 拥有高于任何选择器的特异性；内联 `!important` 与样式表 `!important` 竞争时同样按内联最高特异性处理。

`<style>` 规则的源顺序 SHALL 取「文档中 `<style>` 元素顺序 + 规则在该样式表中的 `order`」的合并顺序。

#### Scenario: 呈现属性被样式表覆盖

- **WHEN** `<rect fill="red" class="a"/>` 且样式表含 `.a { fill: blue }`
- **THEN** 计算得到的 `fill` 为蓝色

#### Scenario: 内联覆盖样式表

- **WHEN** 元素 `style="fill: green"`，样式表含 `#x { fill: blue }`
- **THEN** 计算得到的 `fill` 为绿色

#### Scenario: important 覆盖内联

- **WHEN** 元素 `style="fill: green"`，样式表含 `rect { fill: blue !important }`
- **THEN** 计算得到的 `fill` 为蓝色

#### Scenario: 同特异性按源顺序

- **WHEN** 样式表依次为 `rect { fill: red }` 与 `rect { fill: blue }`
- **THEN** 计算得到的 `fill` 为蓝色

### Requirement: 属性继承元数据

系统 SHALL 维护属性元数据表，标注每个支持属性的「是否继承」与「初始值」。

可继承属性至少 SHALL 包含：`fill`、`fill-rule`、`stroke`、`stroke-width`、`stroke-linecap`、`stroke-linejoin`、`stroke-miterlimit`、`stroke-dasharray`、`stroke-dashoffset`、`stroke-opacity`、`color`、`font-family`、`font-size`、`font-weight`、`font-style`、`text-anchor`、`letter-spacing`、`word-spacing`、`visibility`、`clip-rule`。

不可继承属性至少 SHALL 包含：`opacity`、`display`、`clip-path`、`mask`、`stop-color`、`stop-opacity`。

#### Scenario: 继承可继承属性

- **WHEN** `<g fill="red"><rect/></g>`
- **THEN** `rect` 的计算 `fill` 为红色

#### Scenario: 不继承 opacity

- **WHEN** `<g opacity="0.5"><rect/></g>`
- **THEN** `rect` 的 `opacity` 为 `1`，组透明度在渲染阶段整体作用于 `<g>`

### Requirement: 关键字与 currentColor

显式关键字 SHALL 支持：`inherit`（取父元素计算值）、`initial`（取初始值）、`unset`（可继承属性等于 `inherit`，否则等于 `initial`）。

`currentColor` SHALL 在计算阶段替换为元素自身的计算 `color`；`color` 缺省继承父元素，根元素缺省为黑色。

#### Scenario: initial 与 unset

- **WHEN** 父元素 `fill="red"`，子元素 `fill="initial"`
- **THEN** 子元素 `fill` 为初始值黑色

#### Scenario: currentColor 两级继承

- **WHEN** `<g color="red"><g color="blue"><rect fill="currentColor"/></g></g>`
- **THEN** `rect` 的 `fill` 为蓝色

### Requirement: 计算样式快照

系统 SHALL 提供 `SvgComputedStyle`（只读快照）与 `SvgComputedStyleTree`（元素到快照的映射）。

`SvgComputedStyle` SHALL 提供 `get(name)`、`has(name)`、`fill()`、`stroke()`、`strokeWidth()`、`opacity()`、`color()`、`fontFamily()`、`fontSize()` 与 `source`；类型化 getter 遇到无法解析的值 SHALL 回退到初始值并在解析告警中记录，不得抛异常。

`SvgStyleResolver` SHALL 提供 `init(sheet!: CssStyleSheet = CssStyleSheet.empty())`、`compute(root)` 与 `computeElement(element, parent)`。

`compute(root)` SHALL 先按文档顺序收集根子树内的 `<style>` 元素并解析，再与构造时传入的样式表合并；不修改任何 `SvgElement` 的属性。

#### Scenario: 快照只读

- **WHEN** 对同一文档连续调用两次 `compute(root)`
- **THEN** 两次得到的同名属性值一致，且文档的属性表在调用前后完全相同

#### Scenario: 元素级计算

- **WHEN** 已知父元素快照且父元素 `fill="red"`，子元素没有 `fill`
- **THEN** `computeElement` 返回的子快照 `fill()` 为红色

#### Scenario: 来源可审计

- **WHEN** 属性仅来自呈现属性
- **THEN** 对应快照的 `source` 为 `Presentation`

### Requirement: 非法声明降级

未知属性名 SHALL 被忽略且不报错；已知属性的非法值 SHALL 回退到「继承值或初始值」，并向样式解析告警追加一条包含属性名与元素路径的记录。

`url()` 在 M2 的 CSS 解析中 SHALL 只作为字符串保留；计算阶段只有 `#id` 形式的引用会被接受为画笔引用，其余形式按无画笔处理并记 warning。

#### Scenario: 未知属性忽略

- **WHEN** 样式表含 `rect { foo: bar; fill: red }`
- **THEN** 计算样式没有 `foo`，`fill` 为红色，且不抛异常

#### Scenario: 非法值回退

- **WHEN** 样式表含 `rect { fill: not-a-color }`
- **THEN** `fill` 回退到初始值黑色，并产生一条 warning

#### Scenario: 外部 url 不接受

- **WHEN** 样式表含 `rect { fill: url(http://x/y.svg#g) }`
- **THEN** 该填充按 `SvgPaint.None` 处理并产生一条 warning，渲染器不发起任何请求

### Requirement: CSS 匹配性能

在 1000 条规则 × 1000 个元素的合成文档上，`SvgStyleResolver.compute(root)` 的样式匹配阶段 SHALL 在参考环境中 ≤ 20 ms（单次、`-O2`、不含解析与渲染）。

该指标 SHALL 以 `*_test.cj` 中的基准用例记录实测值；未达标时用例仍可通过，但必须在 `doc/perf-baseline.md` 记录差距。

#### Scenario: 规模基准

- **WHEN** 生成 1000 条简单类选择器规则与 1000 个元素并执行 `compute`
- **THEN** 匹配阶段耗时被测量并输出，且不超过 20 ms 或已记录差距
