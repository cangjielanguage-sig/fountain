# svg-text

## ADDED Requirements

### Requirement: 文本基线表

文本渲染 SHALL 由字体 `ascent` / `descent` 与 `font-size` 建立基线表：`alphabetic` 为 0，`text-before-edge` 位于 em 盒顶部，`hanging` 位于顶部与中线之间，`middle` / `central` 为 em 盒中线，`ideographic` / `text-after-edge` 位于 em 盒底部，`mathematical` 为 x-height 中线。

Hershey 字体 SHALL 使用 `ascent = 0.8 × fontSize`、`descent = 0.2 × fontSize`；字体未提供度量（返回 0）时基线偏移 SHALL 按 0 处理。

#### Scenario: 五种基线顺序

- **WHEN** 同一文本分别使用 `dominant-baseline="text-before-edge"`、`"hanging"`、`"middle"`、`"alphabetic"`、`"text-after-edge"`
- **THEN** 字形基线 y 依次递增，且 `alphabetic` 与未设置时一致

#### Scenario: 无字体度量的回退

- **WHEN** 字体只实现 `advance` 与 `glyphPath`，返回的 `ascent` / `descent` 为 0
- **THEN** 基线偏移按 0 处理，文本仍绘制且不抛异常

### Requirement: 基线偏移与对齐

文本渲染 SHALL 按「基线表 → `dominant-baseline` 偏移 → `baseline-shift`」计算字形基线 y。

`baseline-shift` 的长度与百分比 SHALL 相对 `font-size` 解释，正值向上；`sub` 下移 `0.2 × fontSize`，`super` 上移 `0.4 × fontSize`。`alignment-baseline` SHALL 让所属 `tspan` 相对父基线偏移，`auto` / `baseline` 不偏移。

#### Scenario: 上下标

- **WHEN** `baseline-shift="super"` 与 `"sub"` 分别作用于同一字形
- **THEN** `super` 比默认高 `0.4 × fontSize`，`sub` 比默认低 `0.2 × fontSize`

#### Scenario: 百分比偏移

- **WHEN** `font-size="20"`、`baseline-shift="10%"`
- **THEN** 字形相对默认基线上移 2 个用户单位

#### Scenario: tspan 对齐基线

- **WHEN** `<text y="100">A<tspan alignment-baseline="middle">B</tspan></text>`
- **THEN** `B` 相对 `A` 的基线向上偏移 em 盒中线距离

### Requirement: 文本装饰线

系统 SHALL 按计算样式 `text-decoration` 为字形绘制装饰线：`underline` 位于基线下 `0.10 × fontSize`，`overline` 位于 `ascent` 处，`line-through` 位于 `0.55 × ascent`；厚度 SHALL 为 `max(1, fontSize / 14)`。

颜色 SHALL 取当前 `fill`，渐变按字形起点取样。装饰线 SHALL 随字形旋转（含 `textPath` 切线），同一文本内不因 `tspan` 断开。

`text-decoration` SHALL NOT 被继承，但祖先元素的声明 SHALL 向下传播到后代文本；后代再次声明时以最近祖先的声明为准。

#### Scenario: 下划线像素

- **WHEN** 字号 20 的文本 `text-decoration="underline"`
- **THEN** 基线下方 2 个用户单位处出现厚度不小于 1 的装饰线

#### Scenario: 组合装饰

- **WHEN** `text-decoration="underline line-through"`
- **THEN** 同时绘制下划线与删除线

#### Scenario: 与填充同色

- **WHEN** 文本 `fill="red"`、`text-decoration="overline"`
- **THEN** 上划线像素为红色

#### Scenario: 沿路径旋转

- **WHEN** `textPath` 路径切线为 45°，文本带下划线
- **THEN** 下划线与字形同步旋转 45°

#### Scenario: 祖先传播

- **WHEN** `<text text-decoration="underline">A<tspan>B</tspan></text>`
- **THEN** `A` 与 `B` 都绘制下划线

#### Scenario: none 关闭

- **WHEN** 父元素 `text-decoration="underline"`，子文本显式 `text-decoration="none"`
- **THEN** 子文本不绘制装饰线

### Requirement: 书写模式

`writing-mode` SHALL 支持 `lr-tb` / `lr`（水平）与 `tb` / `tb-rl`（竖排）。

竖排时字形 SHALL 顺时针旋转 90°，沿 y 递增排布，列沿 x 递减（从右到左）；`x` SHALL 表示列位置、`y` 表示列内起点；`text-anchor` SHALL 沿列方向生效。

`writing-mode` 与 `textPath` 同时出现时 SHALL 忽略 `writing-mode` 并记 warning。

#### Scenario: 两列顺序

- **WHEN** 竖排文本 `"ABCD"`，每列容量 2 个字形
- **THEN** `A`、`B` 位于右侧列，`C`、`D` 位于左侧列

#### Scenario: 字形旋转

- **WHEN** `writing-mode="tb-rl"` 渲染单个字形
- **THEN** 字形相对水平方向顺时针旋转 90°

#### Scenario: 列方向居中

- **WHEN** `writing-mode="tb-rl"`、`text-anchor="middle"`、`y=100`、列长 40
- **THEN** 文本沿列以 `y=100` 为中心分布

#### Scenario: 与 textPath 冲突

- **WHEN** 同一 `<text>` 同时含 `writing-mode="tb-rl"` 与 `textPath`
- **THEN** 按 `textPath` 水平排版并追加包含 `writing-mode` 的 warning

### Requirement: textPath 方向与排布模式

`textPath` SHALL 支持 `side` / `method` / `spacing`：

- `side="left"` SHALL 让字形沿路径法线左移 `0.5 × fontSize`，`right` 反向；`side` SHALL NOT 改变切线角；
- `method="align"`（缺省）按逐字 advance 排布；`method="stretch"` SHALL 把 advance 按路径全长缩放，规则与 `textLength` 的 `spacingAndGlyphs` 一致；
- `spacing="auto"`（缺省）使用字体 advance；`spacing="exact"` 使用 `dx` / `letter-spacing` 的精确定位，未提供时等同 `auto`。

非法取值 SHALL 回退到缺省值并记 warning。

#### Scenario: 左侧偏移

- **WHEN** 水平路径、`side="left"`、字号 20
- **THEN** 字形整体沿路径法线左移 10，切线角仍为 0

#### Scenario: 右侧偏移

- **WHEN** 同一路径 `side="right"`
- **THEN** 字形反向偏移 10，与 `left` 的偏移方向相反

#### Scenario: stretch 覆盖全长

- **WHEN** 路径长 100、文本原始 advance 50、`method="stretch"`
- **THEN** 字形间距放大，文本覆盖 100 的路径长度

#### Scenario: exact 使用 dx

- **WHEN** `spacing="exact"` 且有 `dx="5"`
- **THEN** 第一个字形相对 `align` 情形前移 5

#### Scenario: 非法 side

- **WHEN** `side="top"`
- **THEN** 按 `left` 处理并追加 warning

### Requirement: TrueType 字体解析

系统 SHALL 提供 `SvgTrueTypeFont`（实现 `SvgFont`）与 `parse(Array<Byte>)`、`load(Path)`、`unitsPerEm`。

解析 SHALL 支持 `cmap` format 4 与 12、`glyf` 简单与复合字形、`hmtx`、`head`、`hhea`、`maxp`、`loca`；复合字形递归深度不超过 8；`loca` 必须单调。

CFF / OTF 轮廓 SHALL 抛 `SvgException(kind: Unsupported)`；截断或结构错误 SHALL 抛 `SvgException(kind: Syntax)`。

#### Scenario: cmap4 查找

- **WHEN** 解析含 format 4 子表的最小 TTF，查询字符 `A`
- **THEN** 返回非 `None` 字形路径与正 advance

#### Scenario: 复合字形

- **WHEN** 解析含复合字形的 TTF 并取该字形
- **THEN** 路径包含各组件按偏移 / 缩放组合后的轮廓

#### Scenario: 字号缩放与 y 翻转

- **WHEN** `unitsPerEm=2048`，字形在字体空间 y 为正
- **THEN** `glyphPath(cp, 2048)` 的 y 坐标取负，坐标按 `fontSize / unitsPerEm` 缩放

#### Scenario: CFF 拒绝

- **WHEN** 解析 OpenType CFF 轮廓的字体
- **THEN** 抛 `SvgException(kind: Unsupported)`

#### Scenario: 截断表

- **WHEN** 输入字节在 `loca` 表中间截断
- **THEN** 抛 `SvgException(kind: Syntax)`

### Requirement: TrueType 字形输出

`glyphPath` SHALL 输出 `SvgPathData`：直线段为 `M` / `L` / `Z`，二次贝塞尔为 `Q`，闭合轮廓按字体标志补 `Z`；坐标 SHALL 按 `unitsPerEm` 缩放到 `fontSize` 并翻转 y 轴。

复合字形 SHALL 支持 `ARG_1_AND_2_ARE_WORDS`、`ARGS_ARE_XY_VALUES`、`MORE_COMPONENTS` 与 2×2 变换标志的组合。`glyphBounds` SHALL 覆盖变换后路径的控制点包围盒；空字形 SHALL 返回空路径与全 0 包围盒。

`advance` SHALL 只由 `hmtx` 决定，不应用 kern / GSUB / GPOS。

#### Scenario: 二次曲线

- **WHEN** 简单字形含 off-curve 控制点
- **THEN** 路径包含 `Q` 命令，且曲线端点与字体轮廓一致

#### Scenario: advance 缩放

- **WHEN** `hmtx` advance 为 1024、`unitsPerEm` 为 2048、`fontSize` 为 20
- **THEN** `advance` 返回 10

#### Scenario: 空字形

- **WHEN** `loca` 指向零长度字形
- **THEN** `glyphPath` 返回空命令列表，`glyphBounds` 为全 0，不抛异常

## MODIFIED Requirements

### Requirement: textPath 字形落位与截断

每个字形 SHALL 落在其 advance 中点的弧长处，并按该点的切线方向旋转。

`text-anchor` SHALL 调整整体起点：`start` 从 `startOffset` 开始，`middle` 把文本中心对齐到 `startOffset`，`end` 让文本末端落在 `startOffset`。

路径短于文本总 advance 时 SHALL 截断超出部分并追加 warning；截断后已排版的字形保持原位置。

`side` SHALL 按「沿路径法线偏移」的语义生效，`method` 与 `spacing` 的缺省值 `align` / `auto` SHALL 保持 M3 的落位结果。

#### Scenario: 切线角

- **WHEN** 路径为 `M0 0 L10 10`（45°）
- **THEN** 字形旋转角约为 45°

#### Scenario: 文本溢出

- **WHEN** 路径长 20，文本总 advance 为 50
- **THEN** 只绘制落在路径内的字形，并追加截断 warning

#### Scenario: side 生效

- **WHEN** 水平路径、`side="left"`、字号 20
- **THEN** 字形中心相对路径向下偏移 10，切线角不变
