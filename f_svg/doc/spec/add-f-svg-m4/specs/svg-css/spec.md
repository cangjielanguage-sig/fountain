# svg-css

## ADDED Requirements

### Requirement: M4 新增属性注册

`SvgComputedStyle` 的属性表 SHALL 注册 M4 属性，并定义继承性与初始值：

- `clip`：不可继承，初始 `none`；
- `overflow`：不可继承，初始 `hidden`（仅对视口类元素生效）；
- `vector-effect`：不可继承，初始 `none`；
- `dominant-baseline` / `alignment-baseline`：可继承，初始 `auto`；
- `baseline-shift`：可继承，初始 `baseline`；
- `text-decoration`：不可继承，初始 `none`；
- `writing-mode`：可继承，初始 `lr-tb`。

这些属性 SHALL 同时支持呈现属性、`<style>` 规则与内联 `style=""`，并遵循既有级联顺序。

#### Scenario: writing-mode 继承

- **WHEN** `<g writing-mode="tb-rl"><text>x</text></g>`
- **THEN** `text` 的计算 `writing-mode` 为 `tb-rl`

#### Scenario: text-decoration 不继承

- **WHEN** 父元素 `text-decoration="underline"`、子元素未声明该属性
- **THEN** 子元素的 `text-decoration` 计算值为 `none`，装饰线由文本渲染阶段按祖先传播规则决定

### Requirement: M4 属性值归一化

计算阶段 SHALL 归一化 M4 属性值：

- `clip` 接受 `auto`、`none` 或 `rect(<top>, <right>, <bottom>, <left>)`，四分量各为长度或 `auto`；`none` 是 `auto` 的别名（不裁剪）；
- `overflow` 的 `scroll` / `auto` SHALL 归一为 `hidden`；非法值 SHALL 回退到初始值 `hidden` 并记 warning；
- `baseline-shift` 的百分比 SHALL 在计算阶段解析为相对当前 `font-size` 的像素长度；`baseline` / `sub` / `super` 保留关键字；
- `text-decoration` SHALL 输出去重后按 `underline` → `overline` → `line-through` 顺序的关键字列表；
- `writing-mode` 的 `lr` / `tb` 别名 SHALL 保留原值，语义与 `lr-tb` / `tb-rl` 相同。

#### Scenario: clip 函数归一

- **WHEN** 元素 `style="clip: rect(1px, 2px, 3px, 4px)"`
- **THEN** 计算值保留四个分量且顺序为 top/right/bottom/left

#### Scenario: overflow scroll

- **WHEN** 元素 `overflow="scroll"`
- **THEN** 计算值为 `hidden`

#### Scenario: 百分比基线偏移

- **WHEN** `font-size="20"`、`baseline-shift="10%"`
- **THEN** 计算值归一为 `2px`

#### Scenario: 非法 clip

- **WHEN** `clip="rect(1px 2px)"`
- **THEN** 计算值为 `none`，渲染不裁剪，并追加包含 `clip` 的 warning

### Requirement: M4 关键字与非法值降级

`inherit` / `initial` / `unset` SHALL 按既有规则作用于 M4 属性；`initial` 对 `overflow` SHALL 得到 `hidden`。

非法值 SHALL 回退到父元素计算值（可继承属性）或初始值（不可继承属性），并追加包含属性名与元素路径的 warning。

#### Scenario: unset 表现

- **WHEN** 父元素 `writing-mode="tb-rl"`，子元素 `writing-mode="unset"`
- **THEN** 子元素计算值为 `tb-rl`（可继承属性等于 inherit）

#### Scenario: 非法基线

- **WHEN** `dominant-baseline="top"`
- **THEN** 计算值为 `auto` 并追加 warning
