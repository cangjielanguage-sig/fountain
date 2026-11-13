# svg-css

## ADDED Requirements

### Requirement: image-rendering 属性

`SvgComputedStyle` SHALL 注册 `image-rendering` 属性，继承性与初始值定义如下：

- 初始值 SHALL 为 `auto`；
- 属性 SHALL 可继承；
- 取值 SHALL 接受 `auto` / `optimizeQuality` / `optimizeSpeed` / `pixelated`，大小写不敏感。

`image-rendering` SHALL 同时支持呈现属性与 `style=""` 内联声明，并遵循既有级联顺序。

非法值 SHALL 回退到初始值 `auto` 并记 warning；`optimizeQuality` 与 `auto` 等价，`optimizeSpeed` 与 `pixelated` 等价。

#### Scenario: 初始值

- **WHEN** 元素未声明 `image-rendering`
- **THEN** 计算样式返回 `auto`

#### Scenario: 内联覆盖

- **WHEN** 呈现属性为 `auto`，内联 `style="image-rendering: pixelated"`
- **THEN** 计算样式为 `pixelated`

#### Scenario: 非法值

- **WHEN** `image-rendering: nearest`
- **THEN** 计算样式为 `auto`，并追加 warning
