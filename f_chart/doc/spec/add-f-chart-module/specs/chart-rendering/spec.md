# Spec Delta

## Purpose

让调用方用一份 JSON 数据和统一的 `Chart` 接口生成 SVG 图表；不同图共享同一套 JSON 信封与错误语义，按需导入具体图实现。

## ADDED Requirements

### Requirement: 统一图表接口

模块 MUST 公开 `Chart` 接口，唯一下载入方法是 `draw(data: JsonObject): String`，其中 `JsonObject` 来自 `fountain::f_data.json`。返回值 MUST 是完整的 SVG 文档字符串。

#### Scenario: 按接口多态绘制

- **WHEN** 调用方持有 `Chart` 类型的引用并调用 `draw` 传入一个 `JsonObject`
- **THEN** 返回以 `<svg` 开头的 SVG 文档字符串

#### Scenario: 具体图实现可独立导入

- **WHEN** 调用方只导入某一个具体图的公开类型并实例化
- **THEN** 该类型可作为 `Chart` 使用，且不需要初始化全局注册表

### Requirement: 跨图一致的 JSON 信封

所有图 MUST 共用 `type`、`title`、`width`、`height`、`theme`、`legend`、`xAxis`、`yAxis`、`series`、`annotations` 这些顶层字段；`type` 为必填的图类型判别字段。图专属数据 MUST 通过追加字段表达，不得改变既有字段含义。

#### Scenario: 缺省尺寸

- **WHEN** 输入 JSON 未提供 `width` 或 `height`
- **THEN** 输出 SVG 使用文档规定的默认宽度与高度

#### Scenario: 未知图类型

- **WHEN** 输入 JSON 的 `type` 不是该实现支持的类型
- **THEN** `draw` 抛出 `ChartException`，其 `kind` 为 `UnsupportedChart`

### Requirement: 输出可被 f_svg 解析

`draw` 返回的字符串 MUST 可被 `f_svg` 的解析器解析，根元素 MUST 为 `svg`，并带有明确的宽度、高度与 `viewBox`。

#### Scenario: 往返解析

- **WHEN** 对任一图的 `draw` 结果调用 `SvgParser.parse`
- **THEN** 解析成功且根元素标签为 `svg`

### Requirement: 输入错误可诊断

输入 JSON 结构或数值不合法时，`draw` MUST 抛出 `ChartException`，并携带可区分的 `kind`（`InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`）与字段路径信息。

#### Scenario: 必填字段缺失

- **WHEN** 柱状图的 `series` 缺失或为空
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`，消息包含 `series`

#### Scenario: 数值不是数字

- **WHEN** `series[0].data` 中出现字符串或其他非数值
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`，消息包含字段路径
