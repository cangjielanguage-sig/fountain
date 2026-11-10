# svg-text

## REMOVED Requirements

### Requirement: M2 文本边界
**Reason**: M3 实现 `textPath` 排版与逐字符 `rotate`，旧的「忽略并记 warning」边界不再成立。
**Migration**: 由新增的 `M3 文本边界`、`textPath 排版` 与 `文本 rotate 列表` 承接。

## ADDED Requirements

### Requirement: M3 文本边界

M3 起 `textPath` 排版与逐字符 `rotate` SHALL 由 `SvgTextPathLayout` 与 `SvgTextRenderer` 实现，不再按普通文本忽略：

- `textPath` 的 `href` 指向可解析路径时，内容 SHALL 沿路径排版；
- `href` 缺失、指向不存在的元素、或路径为空时，内容 SHALL 降级为普通水平文本并记 warning；
- `rotate` 列表 SHALL 参与字形落位，不再被忽略；
- 任何降级不得影响同一文档中其他文本的布局。

`foreignObject` 内部文本、双向文本与复杂字形整形仍不在支持范围内。

#### Scenario: textPath 降级

- **WHEN** `<text><textPath href="#missing">abc</textPath></text>`
- **THEN** `abc` 按普通水平文本绘制，并产生一条包含 `textPath` 的 warning

#### Scenario: rotate 生效

- **WHEN** `rotate="10 20 30"` 且文本为三个字符
- **THEN** 三个字形分别旋转 10°、20°、30°

### Requirement: textPath 路径与起点

系统 SHALL 提供 `SvgTextPathLayout`，把文本字形序列沿 `SvgPathData` 的弧长排版，返回每个字形的 `(x, y, tangentAngle)`。

路径来源 SHALL 按以下优先级解析：

1. `textPath` 自身的 `path` 属性（`d` 语法）；
2. `href="#id"` 指向的 `path` 元素。

`startOffset` SHALL 同时接受长度与百分比：长度按用户单位解释，百分比按路径总弧长换算。`startOffset` 为负或超过路径长度时 SHALL 钳制到路径端点。

#### Scenario: 水平路径

- **WHEN** 路径为 `M0 0 L100 0`，文本为两个各宽 10 的字形，`startOffset="0"`
- **THEN** 第一个字形中心在 x≈5、y≈0，第二个在 x≈15，切线角均为 0

#### Scenario: 百分比起点

- **WHEN** 路径总长 100，`startOffset="50%"`
- **THEN** 排版从弧长 50 处开始

### Requirement: textPath 字形落位与截断

每个字形 SHALL 落在其 advance 中点的弧长处，并按该点的切线方向旋转。

`text-anchor` SHALL 调整整体起点：`start` 从 `startOffset` 开始，`middle` 把文本中心对齐到 `startOffset`，`end` 让文本末端落在 `startOffset`。

路径短于文本总 advance 时 SHALL 截断超出部分并追加 warning；截断后已排版的字形保持原位置。

`side` 属性 SHALL 被忽略且不产生告警。

#### Scenario: 切线角

- **WHEN** 路径为 `M0 0 L10 10`（45°）
- **THEN** 字形旋转角约为 45°

#### Scenario: 文本溢出

- **WHEN** 路径长 20，文本总 advance 为 50
- **THEN** 只绘制落在路径内的字形，并追加截断 warning

### Requirement: 文本 rotate 列表

`rotate` SHALL 同时接受单值与列表：

- 单值 SHALL 作用于全部字形；
- 列表 SHALL 按字形索引依次消费；
- 列表短于字形数时，剩余字形复用列表末值；
- 列表长于字形数时，多余值忽略。

`rotate` 角度 SHALL 以度为单位，正值顺时针；与 `textPath` 同时存在时，最终角度为切线角与 `rotate` 角之和。

`rotate` 含非有限值或无法解析时 SHALL 忽略该值并记 warning，其余字形继续使用可解析值。

#### Scenario: 单值

- **WHEN** `rotate="15"`，文本为 5 个字形
- **THEN** 5 个字形均旋转 15°

#### Scenario: 短列表复用

- **WHEN** `rotate="10 20"`，文本为 4 个字形
- **THEN** 角度依次为 10°、20°、20°、20°

#### Scenario: 与 textPath 叠加

- **WHEN** 路径切线角为 30°，`rotate="10"`
- **THEN** 最终旋转角为 40°
