# svg-paint-and-clip

## ADDED Requirements

### Requirement: M5 混合模式与隔离组

系统 SHALL 支持 `mix-blend-mode` 的 `normal` / `multiply` / `screen` / `overlay` / `darken` / `lighten` / `color-dodge` / `color-burn` / `hard-light` / `soft-light` / `difference` / `exclusion`。

混合 SHALL 在预乘 RGBA 上按 CSS Compositing and Blending 的可分离混合公式计算：先由预乘值还原非预乘颜色，按模式求混合色，再按 `source-over` 组合 alpha，结果逐通道钳制到 `0..1`。`normal` SHALL 等价于既有 source-over。

`isolation: isolate` SHALL 建立隔离组，使子元素的非 `normal` 混合只读取组内已合成像素；`auto` SHALL 不额外隔离。缺少父图层时（如根元素）SHALL 以透明背景作为混合背景。

#### Scenario: multiply

- **WHEN** 不透明白色背景上以 `multiply` 绘制不透明红色
- **THEN** 结果为红色；以 `multiply` 绘制中性灰 `#808080` 时结果约为背景的一半亮度

#### Scenario: screen

- **WHEN** 不透明红与不透明蓝以 `screen` 合成
- **THEN** 结果为不透明洋红 `(255,0,255)`，容差 1/255

#### Scenario: difference

- **WHEN** 不透明白背景上以 `difference` 绘制不透明白色
- **THEN** 结果为黑色

#### Scenario: 隔离组

- **WHEN** 组内子元素 `mix-blend-mode="screen"`，组 `isolation="isolate"`，组外存在白色背景
- **THEN** 子元素不与组外白色背景混合，组按自身结果合成到父层

#### Scenario: 非 normal 建立层

- **WHEN** 单个元素 `mix-blend-mode="multiply"` 且无其他效果
- **THEN** 该元素先渲染到隔离层再混合，结果与逐命令直接绘制不同且可重复

### Requirement: M5 上下文画笔

系统 SHALL 支持 `fill` / `stroke` 取值为 `context-fill` / `context-stroke`。

该值 SHALL 只在 `use` 展开的实例内有效，并解析为被引用元素（`use.href` 目标）的计算 `fill` / `stroke`，而不是实例自身的画笔。被引用元素的画笔为 `context-fill` / `context-stroke` 时 SHALL 视为无上下文，回退 `none` 并记 warning。解析顺序 SHALL 为先 `context-*`，再 `currentColor`；两者不会同时生效。

不在 `use` 实例内使用该值 SHALL 回退 `none` 并记 warning，且不得影响同文档其他元素。

#### Scenario: 继承被引用元素画笔

- **WHEN** `<defs><rect id="r" fill="red"/></defs><use href="#r" fill="context-fill"/>`
- **THEN** 实例使用红色填充，而不是 `use` 自身的其他颜色

#### Scenario: 描边上下文

- **WHEN** 被引用元素 `stroke="blue"`，实例 `stroke="context-stroke"`
- **THEN** 实例描边为蓝色

#### Scenario: 无 use 上下文

- **WHEN** 普通 `<rect fill="context-fill"/>` 不在任何 `use` 实例内
- **THEN** 该矩形不填充并追加包含 `context-fill` 的 warning

#### Scenario: 自引用回退

- **WHEN** 被引用元素自身 `fill="context-fill"`，实例也使用 `context-fill`
- **THEN** 回退 `none` 并追加 warning，不递归解析
