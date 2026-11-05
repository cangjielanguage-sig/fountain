# svg-text

## ADDED Requirements

### Requirement: 字体接口与注册表

系统 SHALL 提供 `SvgFont` 接口，包含 `glyphPath(codePoint, fontSize)`、`advance(codePoint, fontSize)`、`ascent(fontSize)`、`descent(fontSize)`、`glyphBounds(codePoint, fontSize)`。

系统 SHALL 提供 `SvgFontRegistry`，支持 `register(family, font)`、`resolve(family, weight, style)` 与静态 `defaultRegistry()`。

`resolve` SHALL 按「精确 family → 通用族（`serif` / `sans-serif` / `monospace`）→ 默认字体」的顺序回退；family 列表按逗号拆分并去除引号与空白。

`defaultRegistry()` SHALL 内置 Hershey ASCII 单线字体，且不内置任何 CJK 字体。

#### Scenario: 精确匹配

- **WHEN** 注册 family 为 `Test` 的字体后 `resolve("Test", "normal", "normal")`
- **THEN** 返回该字体

#### Scenario: family 列表回退

- **WHEN** 只注册了 `sans-serif`，请求 `"Missing, sans-serif"`
- **THEN** 返回 `sans-serif` 字体

#### Scenario: 默认注册表

- **WHEN** 调用 `SvgFontRegistry.defaultRegistry().resolve("Hershey", "normal", "normal")`
- **THEN** 返回非空字体，ASCII 字符 `A` 的 `advance` 与 `glyphPath` 均可用

### Requirement: 内置 Hershey ASCII 字体

系统 SHALL 提供 `HersheyFont`，覆盖 ASCII 可打印区间 32–126。

`glyphPath` SHALL 返回以折线构成的 `SvgPathData`（每条笔画为独立子路径）；`advance` SHALL 随 `fontSize` 线性缩放；`ascent` / `descent` SHALL 返回正数且满足 `ascent + descent > 0`。

空格 SHALL 有前进宽度，`glyphPath` SHALL 返回命令列表为空的 `SvgPathData`（非 `None`）。不可打印字符 SHALL 返回 `None`。

#### Scenario: 大写字母

- **WHEN** `HersheyFont.glyphPath(65 /* A */, 10)`
- **THEN** 返回非空路径，且所有坐标落在 `[0, advance] × [-ascent, descent]` 内

#### Scenario: 空格

- **WHEN** `glyphPath(32, 10)` 与 `advance(32, 10)`
- **THEN** 路径非 `None` 且 `commands` 为空，`advance > 0`

#### Scenario: 字号缩放

- **WHEN** 同一字符分别在字号 10 与 20 下取路径
- **THEN** 第二个路径的所有坐标是第一个的 2 倍

#### Scenario: 非 ASCII

- **WHEN** `glyphPath(0x4E2D /* 中 */, 10)`
- **THEN** 返回 `None`

### Requirement: 文本布局

文本渲染 SHALL 按字符 `advance` 累加布局，支持：

- `x` / `y` 列表：逐字符定位，列表短于字符数时复用最后一个值；
- `dx` / `dy` 列表：在当前前进量上叠加偏移；
- `letter-spacing`：每个字符后追加间距；
- `word-spacing`：空格字符后追加间距；
- `text-anchor`：`start` 从起点向右、`middle` 以总宽居中、`end` 以终点向左；
- `textLength` + `lengthAdjust`：`spacing` 只调整字符间距，`spacingAndGlyphs` 同时缩放字形与间距。

`x` / `y` 缺省时 SHALL 从 `(0, 0)` 起排；字号 SHALL 取计算样式 `font-size`。

#### Scenario: 连续布局

- **WHEN** 字符 `A`、`B` 的 advance 均为 10，`letter-spacing=2`
- **THEN** 第二个字符起点相对第一个为 12

#### Scenario: text-anchor middle

- **WHEN** 总文本宽度 100，`text-anchor="middle"`，起点 `x=200`
- **THEN** 第一个字符的绘制起点为 `150`

#### Scenario: dx/dy 偏移

- **WHEN** `dx="5"`、`dy="-2"`
- **THEN** 所有字形整体平移 `(5, -2)`

#### Scenario: textLength spacingAndGlyphs

- **WHEN** 原始宽度 100，`textLength=50`、`lengthAdjust="spacingAndGlyphs"`、`text-anchor="start"`
- **THEN** 布局总宽为 50，字形水平缩放 0.5

### Requirement: 字形渲染

字形 SHALL 以 `SvgPathData` 交给光栅器，与形状共用同一套填充、描边、渐变与裁剪能力。

文本元素的计算 `fill` / `stroke` / 字体属性 SHALL 作用于全部字形；`tspan` SHALL 继承父文本的布局起点并覆盖自身声明的属性。

字体缺失或字符未命中时 SHALL 绘制占位方框（边长约 `0.6 × fontSize`）并记 warning；SHALL NOT 抛异常。

`tspan` 的嵌套布局 SHALL 从父级当前笔位置继续，`dx` / `dy` 在进入与离开 `tspan` 时按 SVG 语义累加。

#### Scenario: 填充与描边共用光栅器

- **WHEN** 文本 `fill="red"`、`stroke="blue"`、`stroke-width=1`
- **THEN** 字形内部为红、边缘有蓝色描边，且可被 `clipPath` 裁剪

#### Scenario: tspan 覆盖字号

- **WHEN** `<text font-size="20">A<tspan font-size="10">B</tspan></text>`
- **THEN** `A` 按 20 号布局，`B` 按 10 号布局并紧接 `A` 的前进位置

#### Scenario: 缺失字形占位

- **WHEN** 文本含字体不支持的字符
- **THEN** 该字符位置绘制占位方框并产生一条 warning

#### Scenario: 无字体注册

- **WHEN** 注册表中没有任何字体
- **THEN** 文本不崩溃，按占位方框渲染并记 warning

### Requirement: M2 文本边界

M2 SHALL NOT 实现 `textPath` 排版与逐字符 `rotate`：

- `textPath` 内容 SHALL 按普通 `text` 布局忽略路径，并记 warning；
- `rotate` 列表 SHALL 被忽略，并记 warning。

上述忽略不得影响同一文档中其他文本的布局。

#### Scenario: textPath 降级

- **WHEN** `<text><textPath href="#p">abc</textPath></text>`
- **THEN** `abc` 按普通水平文本绘制，并产生一条包含 `textPath` 的 warning

#### Scenario: rotate 忽略

- **WHEN** `rotate="10 20 30"` 且文本为三个字符
- **THEN** 字形不旋转，布局宽度不变，并产生一条 warning
