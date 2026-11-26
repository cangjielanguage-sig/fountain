# svg-paint-and-clip

## ADDED Requirements

### Requirement: clip 属性

系统 SHALL 支持 CSS 属性 `clip`：

- `auto` SHALL 不产生裁剪；
- `rect(<top>, <right>, <bottom>, <left>)` SHALL 以用户空间矩形裁剪，四分量支持长度与 `auto`，`auto` 表示该边不限制；
- 裁剪矩形 SHALL 随元素当前 CTM 变换后参与覆盖合成；
- 同时存在 `clip-path` 时，SHALL 先应用 `clip` 矩形再应用 `clip-path`；
- 非法值 SHALL 记 warning 并忽略，不抛异常。

本模块把 `clip` 放宽到任意已渲染的图形、文本、图像与组，不限于 viewport 元素。

#### Scenario: 四边裁剪

- **WHEN** 元素覆盖全画布，`clip: rect(0, 10, 10, 0)`
- **THEN** 只有 `(0,0)-(10,10)` 区域保留，其余透明

#### Scenario: 单边 auto

- **WHEN** `clip: rect(0, 10, auto, 0)`
- **THEN** 下方不裁剪，左、上、右按给定边界裁剪

#### Scenario: 旋转后的裁剪

- **WHEN** 元素 `transform="rotate(45)"` 且带 `clip: rect(0, 10, 10, 0)`
- **THEN** 裁剪区域随元素旋转，仍是 10×10 的用户空间矩形

#### Scenario: 与 clip-path 叠加

- **WHEN** 同一元素同时声明 `clip` 与 `clip-path`
- **THEN** 结果等于先按 `clip` 矩形、再按 `clip-path` 两次裁剪的交集

### Requirement: overflow 视口裁剪

`symbol` / `marker` / `pattern` / 嵌套 `svg` SHALL 按视口矩形裁剪内容：

- `overflow` 缺省为 `hidden`，此时超出视口的内容 SHALL 不被绘制；
- `overflow="visible"` SHALL 不裁剪；
- `marker` 的视口 SHALL 为 `markerWidth × markerHeight`（缺省 3×3）；
- `pattern` 的视口 SHALL 为 tile 边界；`overflow="visible"` SHALL NOT 让内容扩展到相邻 tile，tile 边界仍是采样周期；
- 裁剪 SHALL 在内容坐标系完成，再参与外层合成；
- `overflow` 只对上述视口类元素生效，普通图形元素设置该属性 SHALL 不产生裁剪。

#### Scenario: marker 默认裁剪

- **WHEN** `markerWidth="4" markerHeight="4"` 的 marker 内容绘制到 `(10, 10)`
- **THEN** 超出 4×4 视口的部分不被绘制

#### Scenario: marker 放行

- **WHEN** 同一 marker 设置 `overflow="visible"`
- **THEN** 越出 4×4 的内容完整绘制

#### Scenario: symbol 裁剪

- **WHEN** `use` 引用 `symbol` 且其子元素超出 `use` 的 `width` / `height`
- **THEN** 超出部分不绘制

#### Scenario: 嵌套 svg 放行

- **WHEN** 嵌套 `<svg overflow="visible">` 的子元素超出其视口
- **THEN** 超出部分仍绘制

#### Scenario: pattern tile 边界

- **WHEN** pattern 设置 `overflow="visible"`，内容绘制到 tile 之外
- **THEN** tile 内仍按边界取样，相邻 tile 不出现越界内容

### Requirement: pattern 视口

`SvgPattern` SHALL 支持 `viewBox` 与 `preserveAspectRatio`，用于定义 tile 内容的坐标映射：

- 声明 `viewBox` 时，SHALL 用 `preserveAspectRatio` 把 `viewBox` 映射到 tile 的 `width × height`；
- 声明 `viewBox` 时，`patternContentUnits` SHALL 被忽略；
- tile 尺寸 SHALL 仍由 `width` / `height` 与 `patternUnits` 决定；
- 未声明 `viewBox` 时，行为 SHALL 与 M3 一致。

#### Scenario: viewBox 放大

- **WHEN** `viewBox="0 0 10 10"`、tile 20×20
- **THEN** tile 内容按 2 倍放大绘制

#### Scenario: slice 裁剪

- **WHEN** `viewBox` 纵横比与 tile 不同且 `preserveAspectRatio="xMidYMid slice"`
- **THEN** 内容填满 tile 并按视口裁剪

#### Scenario: 无 viewBox 不变

- **WHEN** pattern 未声明 `viewBox`
- **THEN** 内容按 `patternContentUnits` 解释，输出与 M3 逐字节一致
