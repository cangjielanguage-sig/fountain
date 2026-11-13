# svg-document-model

## ADDED Requirements

### Requirement: view 元素模型

系统 SHALL 把 `view` 映射为 `SvgView <: SvgElement`，提供 `viewBox: ?SvgViewBox`、`preserveAspectRatio: SvgPreserveAspectRatio` 与 `viewTarget: ?String`。

`SvgDocument` SHALL 提供 `views(): ArrayList<SvgView>` 与 `view(id: String): ?SvgView`：前者按文档顺序返回全部 `view`，后者按 `id` 返回第一个匹配项。

`view` SHALL 可解析、可修改、可无损写回；`viewBox` 非法时 SHALL 保持 `None` 并记 warning。

#### Scenario: 解析与往返

- **WHEN** 解析 `<view id="v" viewBox="0 0 10 20" preserveAspectRatio="xMinYMax slice" viewTarget="a b"/>`
- **THEN** 类型化字段与源属性一致，写回后再解析结构等价

#### Scenario: 文档顺序

- **WHEN** 文档含 `view` `id="a"` 与 `id="b"`
- **THEN** `views()` 依次返回 `a`、`b`，`view("b")` 返回第二个

#### Scenario: 缺失 id

- **WHEN** `view("missing")`
- **THEN** 返回 `None`，不抛异常

### Requirement: 链接查询

`SvgDocument` SHALL 提供 `anchors(): ArrayList<SvgAnchorInfo>`，按文档顺序返回所有 `a` 元素；`SvgAnchorInfo` SHALL 含 `element`、`href` 与 `target`。

`href` SHALL 读取 `href` 或 `xlink:href`，类型为 `?String`；缺失或为空时为 `None`，`a` 元素仍会被返回。`target` 缺省为空字符串。外部 `href` SHALL 按既有安全策略在解析期移除或拒绝，移除后该 `a` 以 `href=None` 返回。

`anchors()` SHALL NOT 联网、不触发导航、不执行事件，也不改变渲染行为。

#### Scenario: 嵌套顺序

- **WHEN** 文档含 `<a href="#x"><a href="#y" target="_blank"/></a>`
- **THEN** `anchors()` 依次返回 href 为 `#x`、`#y` 的两项，第二项 `target` 为 `_blank`

#### Scenario: 默认 target

- **WHEN** `<a href="#x"/>` 未写 `target`
- **THEN** 对应 `SvgAnchorInfo.target` 为空字符串

#### Scenario: 外部链接移除

- **WHEN** 解析 `<a href="https://example.com">x</a>` 且未放行外部引用
- **THEN** `anchors()` 包含该项且 `href=None`，`warnings` 含外部引用告警

### Requirement: M4 滤镜原语元素

系统 SHALL 把下列标签映射为独立类型，而不是 `SvgUnknownElement` 或通用容器：

- `feComponentTransfer` / `feFuncR` / `feFuncG` / `feFuncB` / `feFuncA`；
- `feMorphology` / `feConvolveMatrix` / `feTurbulence` / `feDisplacementMap` / `feImage`；
- `feDiffuseLighting` / `feSpecularLighting` / `feDistantLight` / `fePointLight` / `feSpotLight`。

新元素 SHALL 提供与 SVG 属性同名的类型化读写；未设置的属性 SHALL 为 `None` 或规范缺省值，解析阶段不补齐。

#### Scenario: 全部新原语类型化

- **WHEN** 解析含上述全部标签的 `<filter>`
- **THEN** 每个子元素都得到对应类型，`primitives.size` 等于 `fe*` 原语数量

#### Scenario: 属性读写

- **WHEN** 设置 `feTurbulence.baseFrequency` 为双值并写回
- **THEN** 输出 `baseFrequency="0.05 0.1"`，再次解析得到相同双值

#### Scenario: 光照子元素

- **WHEN** 解析 `<feDiffuseLighting><feSpotLight x="1" y="2" z="3"/></feDiffuseLighting>`
- **THEN** 光照原语持有 `SvgFeSpotLight` 子元素，`x/y/z` 可读
