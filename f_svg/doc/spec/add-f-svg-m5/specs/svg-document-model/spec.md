# svg-document-model

## ADDED Requirements

### Requirement: M5 元素查询 API

`SvgElement` SHALL 提供 `getElementsByClassName(name: String): ArrayList<SvgElement>` 与 `querySelectorAll(selector: String): ArrayList<SvgElement>`。

两者 SHALL 只返回调用元素的**后代**元素，不包含调用元素自身；结果 SHALL 按文档顺序排列且不重复。`getElementsByClassName` SHALL 按空白分隔的 `class` 逐词精确匹配，空名称 SHALL 返回空列表。`querySelectorAll` SHALL 复用 `svg-css` 的选择器引擎，支持 M1–M5 的全部选择器与组合器；非法选择器 SHALL 抛 `SvgException(kind: InvalidValue)`，不得静默返回全部元素。

返回列表 SHALL 为独立快照，SHALL NOT 随文档后续修改自动更新；查询 SHALL NOT 修改文档。

#### Scenario: 类名查询

- **WHEN** `<g class="a"><rect class="a b"/><circle class="ab"/></g>` 对 `g` 调用 `getElementsByClassName("a")`
- **THEN** 只返回 `rect`，不含 `circle` 与 `g` 自身

#### Scenario: 文档顺序

- **WHEN** 后代中先出现 `rect` 后出现 `circle`，选择器同时命中两者
- **THEN** 结果顺序为 `rect`、`circle`

#### Scenario: 选择器复用

- **WHEN** `querySelectorAll("rect:not(.skip) + circle")`
- **THEN** 返回满足相邻兄弟与否定条件的 `circle`

#### Scenario: 非法选择器

- **WHEN** `querySelectorAll("[x=")`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

#### Scenario: 不修改文档

- **WHEN** 连续执行两次查询
- **THEN** 文档属性、子节点与 warnings 均不变，两次结果等价

### Requirement: M5 feDropShadow 元素模型

系统 SHALL 把 `feDropShadow` 映射为独立类型 `SvgFeDropShadow <: SvgFilterPrimitive`，而不是 `SvgUnknownElement` 或通用容器。

该元素 SHALL 提供与 SVG 属性同名的类型化读写：`dx` / `dy`（长度，缺省 2）、`stdDeviation`（1 或 2 个非负数，缺省 2）、`floodColor`（颜色，缺省黑色）、`floodOpacity`（缺省 1），并继承 `SvgFilterPrimitive` 的 `x` / `y` / `width` / `height` / `result` / `in`。

未设置的属性 SHALL 保留 `None` 或规范缺省值，解析阶段不补齐；属性 SHALL 可解析、可修改、可无损写回。

#### Scenario: 类型化解析

- **WHEN** 解析 `<filter><feDropShadow dx="4" dy="5" stdDeviation="3 1" flood-color="blue" flood-opacity="0.5"/></filter>`
- **THEN** `primitives` 中的元素为 `SvgFeDropShadow`，五个属性与源值一致

#### Scenario: 缺省值

- **WHEN** 解析空 `<feDropShadow/>`
- **THEN** `dx=2`、`dy=2`、`stdDeviation` 为单个 2、`floodColor` 为黑、`floodOpacity=1`

#### Scenario: 往返一致

- **WHEN** 设置上述属性后写回并再次解析
- **THEN** 结构与属性值等价
