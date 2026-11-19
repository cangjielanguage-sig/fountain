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

`x` / `y` 缺省时 SHALL 从 `(0, 0)` 起排；字号 SHALL 取计算样式 `font-size`（`font-size-adjust` 生效时为修正后的字号）。

生效的 `text-rendering: optimizeSpeed` SHALL 关闭连字与字距；`optimizeLegibility` SHALL 开启连字与字距；`auto` / `geometricPrecision` SHALL 按字体表能力与 `font-kerning` / `font-feature-settings` 决定。

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

#### Scenario: optimizeSpeed 关闭整形

- **WHEN** `text-rendering="optimizeSpeed"`，字体含 `liga` 与 `kern`
- **THEN** `fi` 不形成连字，且 `AV` 不应用字距

### Requirement: 文本装饰线

系统 SHALL 按计算样式 `text-decoration-line` 为字形绘制装饰线，颜色取 `text-decoration-color`（缺省 `currentColor`），样式取 `text-decoration-style`，厚度取 `text-decoration-thickness`（缺省 `max(1, fontSize / 14)`）。

`underline` 位置 SHALL 由 `text-underline-position` 决定：`auto` 位于基线下 `0.10 × fontSize`，`under` 再向下偏移当前字体 descent，`above` 位于基线上方。`overline` 位于 `ascent` 处，`line-through` 位于 `0.55 × ascent`。

渐变装饰线 SHALL 按字形包围盒取样（每个字形独立 `objectBoundingBox`）。装饰线 SHALL 随字形旋转（含 `textPath` 切线），同一文本内不因 `tspan` 断开。

`text-decoration-line` SHALL NOT 被继承，但祖先元素的声明 SHALL 向下传播到后代文本；后代再次声明时以最近祖先的声明为准。

#### Scenario: 下划线像素

- **WHEN** 字号 20 的文本 `text-decoration-line="underline"`
- **THEN** 基线下方 2 个用户单位处出现厚度不小于 1 的装饰线

#### Scenario: 组合装饰

- **WHEN** `text-decoration-line="underline line-through"`
- **THEN** 同时绘制下划线与删除线

#### Scenario: 与填充同色

- **WHEN** 文本 `fill="red"`、`text-decoration-line="overline"`
- **THEN** 上划线像素为红色

#### Scenario: 沿路径旋转

- **WHEN** `textPath` 路径切线为 45°，文本带下划线
- **THEN** 下划线与字形同步旋转 45°

#### Scenario: 祖先传播

- **WHEN** `<text text-decoration="underline">A<tspan>B</tspan></text>`
- **THEN** `A` 与 `B` 都绘制下划线

#### Scenario: none 关闭

- **WHEN** 父元素 `text-decoration="underline"`，子文本显式 `text-decoration-line="none"`
- **THEN** 子文本不绘制装饰线

#### Scenario: 独立颜色

- **WHEN** `text-decoration-color="blue"`、`fill="red"`
- **THEN** 装饰线为蓝色，字形为红色

#### Scenario: 样式与厚度

- **WHEN** `text-decoration-style="dashed"`、`text-decoration-thickness="3"`
- **THEN** 装饰线为 3 用户单位厚的虚线

#### Scenario: 双线

- **WHEN** `text-decoration-style="double"`
- **THEN** 绘制两条平行细线，总厚度等于 `text-decoration-thickness`

### Requirement: textPath 路径与起点

系统 SHALL 提供 `SvgTextPathLayout`，把文本字形序列沿 `SvgPathData` 的弧长排版，返回每个字形的 `(x, y, tangentAngle)`。

路径来源 SHALL 按以下优先级解析：

1. `textPath` 自身的 `path` 属性（`d` 语法）；
2. `href="#id"` 指向的 `path` 元素。

`startOffset` SHALL 同时接受长度与百分比：长度按用户单位解释，百分比按路径总弧长换算。`startOffset` 为负或超过路径长度时 SHALL 钳制到路径端点。

路径存在合法 `pathLength` 时，`startOffset` 的绝对值与字形弧长 SHALL 乘以 `实际弧长 / pathLength` 后再落位；百分比仍按实际弧长换算。

#### Scenario: 水平路径

- **WHEN** 路径为 `M0 0 L100 0`，文本为两个各宽 10 的字形，`startOffset="0"`
- **THEN** 第一个字形中心在 x≈5、y≈0，第二个在 x≈15，切线角均为 0

#### Scenario: 百分比起点

- **WHEN** 路径总长 100，`startOffset="50%"`
- **THEN** 排版从弧长 50 处开始

#### Scenario: pathLength 校准起点

- **WHEN** 实际弧长 200、`pathLength="100"`、`startOffset="20"`
- **THEN** 排版从实际弧长 40 处开始

### Requirement: OpenType 字距调整

系统 SHALL 在文本布局中应用字体字距：优先读取 `GPOS` 的 `kern` 特性 Pair Adjustment（lookup type 2，format 1 与 format 2），字体无 `GPOS` 时读取 `kern` 表 format 0。

字距调整 SHALL 只修改相邻字形的 x advance，SHALL 以字体设计单位读取并按 `fontSize / unitsPerEm` 缩放。只 SHALL 在同一文本 run、同一字体与同一字号内配对；跨 `tspan` 字体或字号变化处 SHALL 不配对。`font-kerning: none` SHALL 关闭调整，`normal` SHALL 强制启用，`auto` SHALL 在字体含 `kern` 或 `GPOS` 时启用。

`font-feature-settings` 中 `"kern" 0` SHALL 关闭字距；`font-kerning: none` SHALL 优先于 `"kern" 1`。`text-rendering: optimizeSpeed` SHALL 关闭字距，`optimizeLegibility` SHALL 开启字距。

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

#### Scenario: 特性开关关闭

- **WHEN** `font-feature-settings: "kern" 0`
- **THEN** 总 advance 等于单字 advance 之和

#### Scenario: font-kerning 优先

- **WHEN** `font-kerning="none"` 与 `font-feature-settings: "kern" 1` 同时声明
- **THEN** 字距仍关闭

### Requirement: 标准连字

系统 SHALL 解析 `GSUB` 的 ScriptList / FeatureList / LookupList，并应用 `liga` 特性的 Lookup Type 4 format 1 替换。

连字匹配 SHALL 以字形序列为单位，单次替换最多消费 4 个输入字形；替换后 SHALL 以连字字形的 advance 与轮廓参与布局。lookup 链深度 SHALL 不超过 8；特性直接引用的 lookup 记为第 1 层，Extension lookup（Type 7）指向的目标逐层递增。上下文替换（Type 5 / 6）SHALL 按 `M6 GSUB 上下文替换` 的要求处理；Extension lookup SHALL 仅用于定位其目标的实际 lookup。

不存在的 feature、越界的 coverage / ligature set、截断的表 SHALL 使该 lookup 不生效并记 warning，不得中断整段文本渲染。

`font-variant-ligatures` 与 `font-feature-settings` 的开关 SHALL 决定 `liga` / `clig` / `dlig` / `hlig` / `calt` 是否参与；`text-rendering: optimizeSpeed` SHALL 关闭全部连字。

#### Scenario: fi 连字

- **WHEN** 字体 `liga` 将 `f` + `i` 映射为 `fi` 连字
- **THEN** `"fi"` 输出一个连字字形，总 advance 为连字 advance

#### Scenario: 最长匹配优先

- **WHEN** 同一 `f` 起始同时存在 2 字形与 3 字形连字
- **THEN** 优先选择 3 字形连字

#### Scenario: 深度上限

- **WHEN** Extension lookup 链使实际连字 lookup 位于第 9 层
- **THEN** 第 9 层不再替换并追加 warning，前 8 层结果保留

#### Scenario: 关闭常见连字

- **WHEN** `font-variant-ligatures: none`
- **THEN** `liga` 与 `clig` 都不参与替换

#### Scenario: 历史连字

- **WHEN** `font-variant-ligatures: historical-ligatures` 且字体含 `hlig`
- **THEN** `hlig` 参与替换，`liga` 仍按缺省参与

## ADDED Requirements

### Requirement: M6 字体匹配与合成

`font-stretch` SHALL 作为字体匹配条件：注册表按 family、weight、style、stretch 选取最接近的字体；无匹配时按 100% 使用。声明为百分比且无精确匹配时 SHALL 对字形应用水平缩放 `请求值 / 选中面 stretch`（如请求 80%、选中 75% 时为 80/75）。

`font-variant: small-caps` SHALL 把小写字母映射为大写字形并缩放到 `0.8 × fontSize`；`normal` SHALL 不做处理。

`font-size-adjust` SHALL 按 `adjustedSize = fontSize × adjust / xHeightRatio` 修正字号，`xHeightRatio` 取 TTF `OS/2.sxHeight / unitsPerEm`；字体缺少 `OS/2` 或 `sxHeight` 为 0 时 SHALL 忽略并 warning。

#### Scenario: stretch 精确匹配

- **WHEN** 同一 family 注册 75% 与 100% 两个字重，声明 `font-stretch: condensed`
- **THEN** 选择 75% 的字体

#### Scenario: 百分比合成

- **WHEN** 仅注册 100% 字体，声明 `font-stretch: 80%`
- **THEN** 字形水平缩放 0.8，advance 同步缩放

#### Scenario: small-caps

- **WHEN** `font-variant: small-caps`，文本 `"ab"`
- **THEN** 输出 `A`、`B` 的大写字形，字号为 `0.8 × fontSize`

#### Scenario: font-size-adjust

- **WHEN** `font-size="20"`、`font-size-adjust="0.5"`、字体 x-height 比例 0.4
- **THEN** 实际字号为 25

#### Scenario: 缺少 OS/2

- **WHEN** 字体无 `OS/2` 表且声明 `font-size-adjust`
- **THEN** 按原字号排版并 warning

### Requirement: M6 字体特性开关

系统 SHALL 把 `font-feature-settings` 与 `font-variant-ligatures` 合并为 OpenType 特性开关集合，并在整形阶段按开关决定 `liga` / `clig` / `dlig` / `hlig` / `calt` / `kern` 是否应用。显式 `font-feature-settings` SHALL 覆盖 `font-variant-ligatures`；`font-kerning` SHALL 覆盖 `kern` 开关。

#### Scenario: 默认开启

- **WHEN** 未声明两项属性
- **THEN** `liga` 与 `clig` 开启，`dlig` / `hlig` 关闭，行为与 M5 一致

#### Scenario: none 关闭

- **WHEN** `font-variant-ligatures: none`
- **THEN** `liga` 与 `clig` 关闭

#### Scenario: discretionary

- **WHEN** `font-variant-ligatures: discretionary-ligatures`
- **THEN** `dlig` 开启，`liga` 仍按默认开启

#### Scenario: contextual

- **WHEN** `font-variant-ligatures: contextual` 且字体含 `calt`
- **THEN** 上下文替换参与整形

#### Scenario: 显式覆盖

- **WHEN** `font-variant-ligatures: none` 且 `font-feature-settings: "liga" 1`
- **THEN** `liga` 开启

### Requirement: M6 GSUB 上下文替换

系统 SHALL 支持 `GSUB` Context（Type 5）与 ChainContext（Type 6）的 format 3 子集：覆盖表 + 回溯 / 输入 / 前瞻字形序列 + 替换 lookup 列表。

上下文匹配 SHALL 以字形序列为单位，替换 SHALL 只执行单字形替换（Type 1）与连字替换（Type 4），SHALL NOT 执行多字形插入。嵌套 lookup 深度 SHALL 不超过 8；超过时 SHALL 停止该分支并 warning。越界 coverage、截断子表与不支持的 format SHALL 忽略该子表并 warning。

#### Scenario: 单层上下文替换

- **WHEN** 字体含 Type 5 format 3，输入序列 `a` 后接 `b` 时把 `a` 替换为 `a.alt`
- **THEN** `"ab"` 的第一个字形为 `a.alt`

#### Scenario: 链式上下文

- **WHEN** Type 6 format 3 同时约束前一个与后一个字形
- **THEN** 只有前后文都匹配时才替换

#### Scenario: 嵌套连字

- **WHEN** 上下文替换的 lookup 列表引用 Type 4 连字
- **THEN** 匹配后生成连字字形，advance 取连字

#### Scenario: 深度上限

- **WHEN** 嵌套 lookup 达到第 9 层
- **THEN** 第 9 层停止并 warning，前 8 层结果保留

#### Scenario: 不支持 format

- **WHEN** Type 5 子表为 format 2
- **THEN** 忽略该子表并 warning，文本继续排版

### Requirement: M6 字号与装饰的交互

`font-size-adjust`、small-caps 与 `font-stretch` 合成 SHALL 共同决定最终字形尺寸与 advance；装饰线厚度 SHALL 按最终字号计算，下划线偏移 SHALL 按最终字号与字体 ascent 计算。`textLength` SHALL 在合成后的 advance 上计算。

#### Scenario: 组合合成

- **WHEN** 同时声明 `font-stretch: 80%`、`font-variant: small-caps` 与 `font-size-adjust`
- **THEN** 字形先按修正字号生成，再按 0.8 缩放，advance 与装饰线厚度按合成结果计算

#### Scenario: textLength 兼容

- **WHEN** 合成后总宽 100，`textLength="50"`
- **THEN** 最终总宽为 50，调整方式遵循 `lengthAdjust`

#### Scenario: 缺省不合成

- **WHEN** 三项属性均为初始值
- **THEN** 输出与 M5 逐字节一致
