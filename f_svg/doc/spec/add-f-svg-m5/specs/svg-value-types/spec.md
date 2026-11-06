# svg-value-types

## ADDED Requirements

### Requirement: M5 混合模式枚举

系统 SHALL 新增公开枚举 `SvgMixBlendMode`，取值 `Normal` / `Multiply` / `Screen` / `Overlay` / `Darken` / `Lighten` / `ColorDodge` / `ColorBurn` / `HardLight` / `SoftLight` / `Difference` / `Exclusion`，均实现 `Equatable` 与 `ToString`。`ToString` SHALL 输出 CSS 关键字。

既有 `SvgBlendMode` SHALL 保持原 5 个取值与语义，不因本要求扩展，以免破坏既有的穷尽匹配。

#### Scenario: 混合模式解析

- **WHEN** 解析 `mix-blend-mode="color-dodge"` 与 `"soft-light"`
- **THEN** 分别得到 `SvgMixBlendMode.ColorDodge` 与 `SvgMixBlendMode.SoftLight`，`toString` 分别输出 `color-dodge` 与 `soft-light`

#### Scenario: 绘制顺序解析

- **WHEN** 解析 `paint-order="stroke fill"`
- **THEN** `layers` 依次为 `Stroke`、`Fill`、`Markers`（缺失项按默认顺序补齐）

#### Scenario: 重复项去重

- **WHEN** 解析 `paint-order="fill stroke fill"`
- **THEN** 结果为 `Fill`、`Stroke`、`Markers`，并追加 warning

#### Scenario: 连字符关键字

- **WHEN** 对 `SvgMixBlendMode.ColorDodge` 调用 `toString()`
- **THEN** 输出 `color-dodge`

#### Scenario: feBlend 不受影响

- **WHEN** 对 `SvgBlendMode.Multiply` 调用 `toString()`
- **THEN** 输出 `multiply`，取值集合仍为 M3 的 5 个

### Requirement: M5 绘制顺序值类型

系统 SHALL 新增公开值类型 `SvgPaintOrder`，表示 `fill` / `stroke` / `markers` 的无重复有序子集，并提供 `parse(text)`、`layers` 与 `toString()`。

`layers` SHALL 按输入顺序排列；未出现的层 SHALL 按 `fill`、`stroke`、`markers` 的默认相对顺序追加。重复层 SHALL 只保留首次出现并记 warning。

#### Scenario: 绘制顺序解析

- **WHEN** 解析 `paint-order="stroke fill"`
- **THEN** `layers` 依次为 `Stroke`、`Fill`、`Markers`（缺失项按默认顺序补齐）

#### Scenario: 重复项去重

- **WHEN** 解析 `paint-order="fill stroke fill"`
- **THEN** 结果为 `Fill`、`Stroke`、`Markers`，并追加 warning

### Requirement: M5 变换参考盒枚举

系统 SHALL 新增公开枚举 `SvgTransformBox`，取值 `ViewBox` / `FillBox`，实现 `Equatable` 与 `ToString`；字符串形式 SHALL 为 `view-box` / `fill-box`，匹配 SHALL 大小写不敏感。

#### Scenario: 变换参考盒

- **WHEN** 解析 `transform-box="fill-box"` 与 `"view-box"`
- **THEN** 分别得到 `SvgTransformBox.FillBox` 与 `SvgTransformBox.ViewBox`

### Requirement: M5 文本方向枚举

系统 SHALL 新增公开枚举 `SvgDirection`（`Ltr` / `Rtl`）、`SvgUnicodeBidi`（`Normal` / `Embed` / `BidiOverride`）与 `SvgFontKerning`（`Auto` / `Normal` / `None`），均实现 `Equatable` 与 `ToString`。

字符串形式 SHALL 为 `ltr` / `rtl`、`normal` / `embed` / `bidi-override`、`auto` / `normal` / `none`。`font-kerning: auto` SHALL 表示字体含 `kern` 或 `GPOS` 时启用，`normal` 强制启用，`none` 关闭。

#### Scenario: 文本方向

- **WHEN** 解析 `direction="rtl"`、`unicode-bidi="bidi-override"`、`font-kerning="none"`
- **THEN** 分别得到 `SvgDirection.Rtl`、`SvgUnicodeBidi.BidiOverride`、`SvgFontKerning.None`

#### Scenario: 大小写不敏感

- **WHEN** 解析 `direction="RTL"` 与 `font-kerning="AUTO"`
- **THEN** 均解析成功并得到对应枚举

### Requirement: M5 枚举回退

无法识别的 M5 枚举字符串 SHALL 回退到该属性的规范缺省值并记 warning，不得抛异常：

- `mix-blend-mode` → `normal`；
- `paint-order` → `fill stroke markers`；
- `transform-box` → `view-box`；
- `direction` → `ltr`；
- `unicode-bidi` → `normal`；
- `font-kerning` → `auto`。

`paint-order` 中的未知关键字 SHALL 被丢弃后按默认顺序补齐；全部关键字未知时 SHALL 使用完整默认顺序。

#### Scenario: 未知混合模式

- **WHEN** 解析 `mix-blend-mode="plus-lighter"`
- **THEN** 回退为 `SvgMixBlendMode.Normal` 并追加 warning

#### Scenario: 未知绘制层

- **WHEN** 解析 `paint-order="fill shadows"`
- **THEN** 丢弃 `shadows`，结果仍为 `fill stroke markers`，并追加 warning

#### Scenario: 未知字距

- **WHEN** 解析 `font-kerning="always"`
- **THEN** 回退为 `SvgFontKerning.Auto` 并追加 warning
