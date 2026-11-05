# svg-render-pipeline

## ADDED Requirements

### Requirement: switch 条件求值

`switch` SHALL 按子元素顺序求值，选择第一个满足条件的可渲染子元素，其余子元素 SHALL 不参与渲染；全部不满足时输出为空。

条件判定 SHALL 为：

- 无任何条件属性时视为满足；
- `requiredFeatures` 按空白或逗号分隔，全部为已知特性才满足；未知特性视为不满足；
- `requiredExtensions` 非空即不满足（本模块不提供扩展）；
- `systemLanguage` 与 `SvgRenderOptions.languages` 做大小写不敏感的前缀匹配，`zh` SHALL 匹配 `zh-CN`；
- 选中元素 `display="none"` 时 SHALL 跳过并继续尝试下一个子元素。

求值 SHALL 在渲染期完成，且不修改文档。

#### Scenario: 语言匹配

- **WHEN** `systemLanguage="fr"` 与 `systemLanguage="zh"` 两个子元素，`languages = ["zh-CN"]`
- **THEN** 选择第二个子元素

#### Scenario: 已知特性通过

- **WHEN** `requiredFeatures="http://www.w3.org/TR/SVG11/feature#Shape"`
- **THEN** 该子元素被选中

#### Scenario: 未知扩展跳过

- **WHEN** `requiredExtensions="http://example.com/ext"`
- **THEN** 跳过该子元素，继续求值后续元素

#### Scenario: 全部不满足

- **WHEN** 所有子元素的条件均不满足
- **THEN** `switch` 不产生任何绘制指令

#### Scenario: display 交互

- **WHEN** 第一个满足条件的子元素 `display="none"`
- **THEN** 跳过它并选择下一个满足条件的子元素

### Requirement: 渲染语言选项

`SvgRenderOptions` SHALL 新增 `languages: Array<String>`，缺省为 `["en"]`。

`languages` SHALL 只影响 `switch` 的 `systemLanguage` 判定，不影响文本、字体解析或其他属性；未传入时既有调用编译通过且输出与 M3 逐字节一致。

#### Scenario: 默认语言

- **WHEN** 未设置 `languages`，`switch` 子元素为 `systemLanguage="en-US"` 与 `"zh"`
- **THEN** 选择 `en-US` 项

#### Scenario: 多语言优先级

- **WHEN** `languages = ["en", "zh"]`，两个子元素分别为 `"zh"` 与 `"en"`
- **THEN** 选择 `en` 项（按子元素顺序，不按 languages 顺序）

#### Scenario: 新字段默认值

- **WHEN** 构造 `SvgRenderOptions()`
- **THEN** `languages` 为单元素数组 `["en"]`

### Requirement: M4 效果应用顺序

元素效果 SHALL 按固定顺序应用：marker / pattern 派生 → 元素内容 → `filter` → `clip` → `clip-path` → `mask` → 组透明度。

`clip` SHALL 在其 CTM 下转为覆盖率蒙版后与后续裁剪逐像素相乘；`overflow` 视口裁剪 SHALL 在对应视口的内容坐标系完成。

同一元素同时声明多种效果时，顺序 SHALL NOT 随遍历方式变化；重复渲染 SHALL 输出逐字节一致。

#### Scenario: clip 与 clip-path 顺序

- **WHEN** 元素同时声明 `clip` 与 `clip-path`
- **THEN** 结果与「先 `clip` 后 `clip-path`」一致，与声明顺序无关

#### Scenario: 与滤镜组合

- **WHEN** 元素同时带 `filter` 与 `clip`
- **THEN** 滤镜对未裁剪内容生效，裁剪作用于滤镜输出

#### Scenario: 视口裁剪

- **WHEN** 嵌套 `svg` 的 `overflow="hidden"` 且子元素越界
- **THEN** 越界内容在进入父层前被裁剪

### Requirement: view 不参与默认渲染

`view` 元素 SHALL NOT 直接产生绘制指令，也 SHALL NOT 改变 `render(document)` 的默认视口；本模块不实现 `url(#view)` 片段导航。

`render(element, width, height)` 对 `view` 元素 SHALL 返回空画布，不抛异常。

#### Scenario: 默认渲染不变

- **WHEN** 文档含带 `viewBox` 的 `view` 元素但根元素未引用它
- **THEN** 渲染输出与删除该 `view` 后逐字节一致

#### Scenario: 单独渲染 view

- **WHEN** `render(viewElement, 10, 10)`
- **THEN** 返回 10×10 全透明位图
