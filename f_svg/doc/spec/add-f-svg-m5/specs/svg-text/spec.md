# svg-text

## MODIFIED Requirements

### Requirement: 文本布局

文本渲染 SHALL 按整形后的字形序列累加布局，支持：

- `x` / `y` 列表：逐字符定位，列表短于字符数时复用最后一个值；
- `dx` / `dy` 列表：在当前前进量上叠加偏移；
- `letter-spacing`：每个字符后追加间距；
- `word-spacing`：空格字符后追加间距；
- `text-anchor`：`start` 从起点向右、`middle` 以总宽居中、`end` 以终点向左；
- `textLength` + `lengthAdjust`：`lengthAdjust` 缺省为 `spacing`（只调整字符间距），`spacingAndGlyphs` 同时缩放字形与间距；无 `textLength` 时不调整。

整形 SHALL 先于定位：同一文本 run 内先应用 `GSUB` 连字，再应用 `kern` / `GPOS` 字距，最后按双向算法生成视觉顺序。连字簇 SHALL 视为单个布局单元，其 advance 为连字字形的 advance，并消费簇内首个字符的 `x` / `y` / `dx` / `dy` / `rotate` 列表项；簇内其余字符的列表项 SHALL 被跳过。双向重排 SHALL 只改变字形在视觉序列中的顺序，不改变每个字形已绑定的偏移与旋转。`text-anchor` 与 `textLength` SHALL 按视觉序列计算。

`x` / `y` 缺省时 SHALL 从 `(0, 0)` 起排；字号 SHALL 取计算样式 `font-size`。

文本节点中的空白 SHALL 按原样参与布局（连续空格产生对应 advance）；SHALL NOT 实现 `xml:space` 折叠。

#### Scenario: 连续空格

- **WHEN** 文本内容为 `"A  B"` 且空格的 advance 为 5
- **THEN** `B` 相对 `A` 的起点偏移为 `advance(A) + 10`

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

#### Scenario: 连字消费列表项

- **WHEN** `"fi"` 形成连字，`dx="5 9"`、`letter-spacing=1`
- **THEN** 连字簇只取 `dx=5`，`9` 被跳过，总前进量在连字 advance 后加一次字距

### Requirement: M3 文本边界

M3 起 `textPath` 排版与逐字符 `rotate` SHALL 由 `SvgTextPathLayout` 与 `SvgTextRenderer` 实现，不再按普通文本忽略：

- `textPath` 的 `href` 指向可解析路径时，内容 SHALL 沿路径排版；
- `href` 缺失、指向不存在的元素、或路径为空时，内容 SHALL 降级为普通水平文本并记 warning；
- `rotate` 列表 SHALL 参与字形落位，不再被忽略；
- 任何降级不得影响同一文档中其他文本的布局。

M5 起 SHALL 支持基础双向文本（UAX#9 子集）与拉丁 / 希腊 / 西里尔标准连字；阿拉伯 / 印度系复杂脚本整形、上下文替换与竖排连字仍不在支持范围内。

#### Scenario: textPath 降级

- **WHEN** `<text><textPath href="#missing">abc</textPath></text>`
- **THEN** `abc` 按普通水平文本绘制，并产生一条包含 `textPath` 的 warning

#### Scenario: rotate 生效

- **WHEN** `rotate="10 20 30"` 且文本为三个字符
- **THEN** 三个字形分别旋转 10°、20°、30°

#### Scenario: 基础整形可用

- **WHEN** 字体含 `liga` 且文本为 `"fi"`
- **THEN** 输出一个连字字形，不再报「复杂整形不支持」

## ADDED Requirements

### Requirement: OpenType 字距调整

系统 SHALL 在文本布局中应用字体字距：优先读取 `GPOS` 的 `kern` 特性 Pair Adjustment（lookup type 2，format 1 与 format 2），字体无 `GPOS` 时读取 `kern` 表 format 0。

字距调整 SHALL 只修改相邻字形的 x advance，SHALL 以字体设计单位读取并按 `fontSize / unitsPerEm` 缩放。只 SHALL 在同一文本 run、同一字体与同一字号内配对；跨 `tspan` 字体或字号变化处 SHALL 不配对。`font-kerning: none` SHALL 关闭调整，`normal` SHALL 强制启用，`auto` SHALL 在字体含 `kern` 或 `GPOS` 时启用。

单字形 `advance(codePoint, fontSize)` 的既有语义 SHALL NOT 改变；字距只在布局阶段叠加。

#### Scenario: kern 表配对

- **WHEN** 字体 `kern` 表含 `A` + `V` 的 -80 单位、`unitsPerEm=1000`、`font-size=10`
- **THEN** `AV` 的总 advance 比两个单字 advance 之和少 `0.8`

#### Scenario: GPOS 优先

- **WHEN** 字体同时含相邻值的 `kern` 表与不同的 `GPOS` pair
- **THEN** 布局使用 `GPOS` 的值

#### Scenario: font-kerning none

- **WHEN** 同一字体设置 `font-kerning="none"`
- **THEN** 总 advance 等于单字 advance 之和

#### Scenario: 跨 tspan 不配对

- **WHEN** `<text>A<tspan font-size="20">V</tspan></text>` 且两段字号不同
- **THEN** `A` 与 `V` 之间不应用字距

### Requirement: 标准连字

系统 SHALL 解析 `GSUB` 的 ScriptList / FeatureList / LookupList，并应用 `liga` 特性的 Lookup Type 4 format 1 替换。

连字匹配 SHALL 以字形序列为单位，单次替换最多消费 4 个输入字形；替换后 SHALL 以连字字形的 advance 与轮廓参与布局。lookup 深度 SHALL 不超过 8；上下文替换（Type 5 / 6）、链式上下文与扩展替换 SHALL NOT 处理。

不存在的 feature、越界的 coverage / ligature set、截断的表 SHALL 使该 lookup 不生效并记 warning，不得中断整段文本渲染。

#### Scenario: fi 连字

- **WHEN** 字体 `liga` 将 `f` + `i` 映射为 `fi` 连字
- **THEN** `"fi"` 输出一个连字字形，总 advance 为连字 advance

#### Scenario: 最长匹配优先

- **WHEN** 同一 `f` 起始同时存在 2 字形与 3 字形连字
- **THEN** 优先选择 3 字形连字

#### Scenario: 深度上限

- **WHEN** lookup 链深度为 9
- **THEN** 第 9 层不再替换并追加 warning，前 8 层结果保留

### Requirement: 双向文本重排

系统 SHALL 按 UAX#9 子集对文本分段并重排：字符方向类别至少覆盖 L / R / AL / EN / AN / WS / ON / B。

段落方向 SHALL 由 `direction` 决定，`rtl` 时基础层级为 1、`ltr` 时为 0。数字（EN / AN）SHALL 在其 RTL 段落内保持 LTR 顺序；中性字符 SHALL 按两侧强类型解析；成对括号 SHALL 做单层镜像。重排结果 SHALL 为视觉顺序的字形序列，且同一输入重复布局输出一致。

#### Scenario: 纯 RTL 反转

- **WHEN** `direction="rtl"`、文本为三个 R 类字符
- **THEN** 视觉序列与逻辑序列相反

#### Scenario: RTL 中的数字

- **WHEN** `direction="rtl"`、文本为 `"אב12"`
- **THEN** 两个希伯来字母反转，`12` 内部保持 `1` 在 `2` 之前

#### Scenario: LTR 不受影响

- **WHEN** `direction="ltr"`、纯拉丁文本
- **THEN** 视觉序列与逻辑序列相同

#### Scenario: 括号镜像

- **WHEN** `direction="rtl"`、文本含 `(` `)`
- **THEN** 视觉序列中括号按镜像字符绘制

### Requirement: M5 文本方向属性

系统 SHALL 支持 `direction`（`ltr` / `rtl`，可继承）与 `unicode-bidi`（`normal` / `embed` / `bidi-override`，不可继承）。

`unicode-bidi: normal` SHALL 按双向算法自然重排；`embed` SHALL 为元素内容建立与 `direction` 一致的新嵌入层；`bidi-override` SHALL 强制按段落方向排列，不再做弱类型与中性解析。三者与 `writing-mode: tb-*` 同时存在时 SHALL 按竖排方向处理，`direction` 只决定列顺序。

`direction` 只影响文本布局，SHALL NOT 改变元素几何或变换。

#### Scenario: 继承方向

- **WHEN** `<g direction="rtl"><text>אב</text></g>`
- **THEN** 文本按 RTL 重排

#### Scenario: bidi-override

- **WHEN** `direction="rtl"`、`unicode-bidi="bidi-override"`、文本为 `"abc"`
- **THEN** 三个字形按 RTL 顺序排列

#### Scenario: 竖排列顺序

- **WHEN** `writing-mode="tb-rl"`、`direction="ltr"`、文本需要两列
- **THEN** 列顺序为从左到右，列内方向仍按竖排规则

#### Scenario: 不改变几何

- **WHEN** 同一 `<text>` 分别设置 `direction="ltr"` 与 `"rtl"`
- **THEN** 元素的 `getBBox` 尺寸相同

### Requirement: 字体别名解析

字体解析 SHALL 先按别名把请求的 family 映射到已注册 family，再执行既有的「精确 family → 通用族 → 默认字体」回退。

别名 SHALL 区分 `font-weight` / `font-style`：未注册对应组合时回退到目标的 `normal` / `normal`。别名 SHALL 只存在于当前渲染上下文，SHALL NOT 写入调用方传入的注册表；别名目标不存在时 SHALL 视为未命中并继续常规回退。

#### Scenario: 别名命中

- **WHEN** 别名 `Body → Brand`，文本 `font-family="Body"`
- **THEN** 使用 `Brand` 的字体

#### Scenario: 权重回退

- **WHEN** 别名目标只注册了 `normal` / `normal`，文本请求 `bold`
- **THEN** 使用目标的 `normal` 字体

#### Scenario: 目标缺失

- **WHEN** 别名 `Ghost → Missing`，且注册表无 `Missing`
- **THEN** 按 `font-family` 列表继续回退，不抛异常
