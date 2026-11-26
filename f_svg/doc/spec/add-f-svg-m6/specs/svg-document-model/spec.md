# svg-document-model

## MODIFIED Requirements

### Requirement: 文档对象

系统 SHALL 提供 `SvgDocument`，包含 `root`（`SvgRoot`）、`declaration`、`doctype`、`prolog`、`epilog`、`warnings`，并提供 `elementById`、`elementsByTag`、`toXmlDocument()`、`toString()`。

`declaration` 与 `doctype` SHALL 复用 `f_xml::XmlDeclaration` 与 `f_xml::DocTypeInfo`，保证可无损往返。

`elementById` SHALL 深度优先返回第一个匹配元素；`elementsByTag` SHALL 返回全部后代中 local name 匹配的元素（不区分命名空间）。

`SvgDocument` SHALL 新增根属性查询 `baseProfile()`、`version()`、`zoomAndPan()`；前两者返回根属性原文或 `None`，`zoomAndPan` 返回 `SvgZoomAndPan`，缺省 `Disable`，非法值回退 `Disable` 并 warning。

`SvgDocument` SHALL 新增命中查询 `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure`，以及变更监听 `addMutationListener` / `removeMutationListener`。命中查询与变更监听 SHALL NOT 修改文档。

#### Scenario: 按 id 查找

- **WHEN** 文档中有两个同 id 元素
- **THEN** `elementById` 返回文档序中第一个

#### Scenario: 按标签查找

- **WHEN** 文档中 `use` 与 `x:use` 各一个
- **THEN** `elementsByTag("use")` 返回两个

#### Scenario: 根属性

- **WHEN** 根元素含 `version="1.1"`、`baseProfile="full"`、`zoomAndPan="magnify"`
- **THEN** `version()` 为 `1.1`、`baseProfile()` 为 `full`、`zoomAndPan()` 为 `Magnify`

#### Scenario: 根属性缺省

- **WHEN** 根元素未声明三者
- **THEN** `version()` 与 `baseProfile()` 为 `None`，`zoomAndPan()` 为 `Disable`

#### Scenario: 根属性非法

- **WHEN** `zoomAndPan="spin"`
- **THEN** 返回 `Disable` 并追加一条 warning

## ADDED Requirements

### Requirement: M6 元素结构变更

`SvgElement` SHALL 新增 `insertBefore(node, reference)` 与 `removeChild(node)`。`insertBefore` 在 `reference` 位于子节点列表时插入其前，`reference` 为 `None` 时等价追加；`reference` 不是直接子节点时 SHALL 抛 `InvalidValue`。`removeChild` 移除直接子节点并返回是否成功。

成功插入或移除 SHALL 设置 / 清空被操作节点的 `parent`，并 SHALL 在返回前同步通知文档的变更监听器。既有 `appendChild` SHALL 保持原语义并纳入通知。

#### Scenario: 插入到指定位置

- **WHEN** 子节点为 `[a, c]`，对 `b` 调用 `insertBefore(b, c)`
- **THEN** 子节点顺序为 `[a, b, c]`，`b.parent` 为当前元素

#### Scenario: 追加语义

- **WHEN** 调用 `insertBefore(b, None)`
- **THEN** `b` 追加到末尾，与 `appendChild` 结果一致

#### Scenario: 非法引用

- **WHEN** `reference` 不是直接子节点
- **THEN** 抛 `InvalidValue`，子节点列表不变

#### Scenario: 移除

- **WHEN** 对直接子节点调用 `removeChild`
- **THEN** 返回 `true`、节点从列表移除、`parent` 清空；再次移除返回 `false`

### Requirement: M6 变更监听

系统 SHALL 提供 `SvgMutationListener` 接口与 `SvgMutationEvent`。事件 SHALL 含 `kind`（`Attribute` / `ChildList`）、`element` 与可选 `attributeName`。文档 SHALL 在 `setAttr` / `removeAttr` / `appendChild` / `removeChild` / `insertBefore` 完成后同步通知全部已注册监听器。

监听器数量上限 SHALL 为 32；超过时 `addMutationListener` SHALL 抛 `InvalidValue`。监听器抛出的异常 SHALL 被捕获并追加 warning，SHALL NOT 中断变更或影响其他监听器。移除未注册的监听器 SHALL 无副作用。

#### Scenario: 属性变更通知

- **WHEN** 注册监听器后对元素调用 `setAttr("fill", "red")`
- **THEN** 监听器收到一次 `Attribute` 事件，`attributeName == "fill"`

#### Scenario: 子节点变更通知

- **WHEN** 调用 `appendChild` 或 `removeChild`
- **THEN** 监听器收到 `ChildList` 事件

#### Scenario: 上限

- **WHEN** 注册第 33 个监听器
- **THEN** 抛 `InvalidValue`，前 32 个仍有效

#### Scenario: 异常隔离

- **WHEN** 第一个监听器抛异常，第二个正常
- **THEN** 第二个仍被调用，`warnings` 含该异常信息，属性变更已生效

#### Scenario: 移除

- **WHEN** 移除后再次修改属性
- **THEN** 被移除的监听器不再收到事件

### Requirement: M6 命中查询 API

`SvgDocument` SHALL 提供 `getIntersectionList(rect, reference)`、`getEnclosureList(rect, reference)`、`checkIntersection(element, rect)` 与 `checkEnclosure(element, rect)`。`rect` SHALL 为用户空间轴对齐矩形；`reference` 为 `None` 时以根为范围，否则只考察其后代（不含自身）。

相交 / 包含判定 SHALL 基于元素 `getBBox()`；`pointer-events: none` 或 `visibility: hidden` 的元素 SHALL 被排除，其子树按自身样式独立判定。两个列表方法 SHALL 按文档顺序返回新建集合，不缓存、不修改文档。

#### Scenario: 相交列表

- **WHEN** 矩形与两个矩形元素部分重叠
- **THEN** `getIntersectionList` 按文档顺序返回两者

#### Scenario: 包含列表

- **WHEN** 矩形完全包含一个小元素、部分覆盖一个大元素
- **THEN** `getEnclosureList` 只返回小元素

#### Scenario: 单元素检查

- **WHEN** 对同一元素与矩形调用 `checkIntersection` / `checkEnclosure`
- **THEN** 结果与列表方法是否包含该元素一致

#### Scenario: pointer-events 筛选

- **WHEN** 元素声明 `pointer-events: none`
- **THEN** 不在任一列表中；其后代未声明 none 时仍可被返回

#### Scenario: reference 范围

- **WHEN** `reference` 指向一个组
- **THEN** 只返回该组的后代，组自身与其他分支不参与

#### Scenario: 空交集

- **WHEN** 矩形与任何元素都不相交
- **THEN** 返回空集合，`check*` 均为 `false`

### Requirement: M6 discard 元素模型

系统 SHALL 把 `discard` 识别为已知动画辅助元素并保留其属性；`discard` SHALL NOT 产生绘制指令，SHALL NOT 进入渲染树。缺少 `begin` 时 SHALL warning 并在文档中保留。

#### Scenario: 解析与往返

- **WHEN** 解析 `<discard begin="3s"/>`
- **THEN** 元素被保留、`tag == "discard"`、`begin == "3s"`，写回后再解析结构等价

#### Scenario: 不参与渲染

- **WHEN** 文档仅含一个 `discard` 与被其引用的目标
- **THEN** 渲染树不含 `discard` 对应指令，输出与不含 `discard` 时逐字节一致

#### Scenario: 缺少 begin

- **WHEN** 解析 `<discard/>`
- **THEN** 元素仍保留，`warnings` 含缺少 `begin`
