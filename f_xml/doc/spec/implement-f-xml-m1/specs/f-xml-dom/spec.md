# Spec Delta — f-xml-dom

## ADDED Requirements

### Requirement: QName 与按 local name 匹配

`QName` SHALL 是 struct，字段 `prefix: ?String`、`local: String`、`uri: ?String`，
并 SHALL 实现 `ToString`（`"x:row"` 或 `"row"`）。

`XmlElement` 的便捷查询 SHALL 按 **local name** 匹配：

- `attr(name: String): ?String`
- `attr(ns: String, local: String): ?String`
- `child(name: String): ?XmlElement`
- `childrenOf(name: String): ArrayList<XmlElement>`

#### Scenario: 带前缀与不带前缀的同名元素都能命中

- **WHEN** 解析 `<r xmlns:x="u"><x:item/><item/></r>`
- **THEN** `r.childrenOf("item").size == 2`

#### Scenario: 按命名空间精确取属性

- **WHEN** 元素同时有 `id="1"` 与 `x:id="2"`（`xmlns:x="u"`）
- **THEN** `attr("id") == Some("1")`，`attr("u", "id") == Some("2")`

#### Scenario: QName 还原字面名

- **WHEN** `QName(Some("x"), "row", Some("u"))`
- **THEN** `toString() == "x:row"`

### Requirement: 节点模型

`XmlNode` SHALL 是 enum，分支至少包含：

| 分支 | 载荷 |
|---|---|
| `ElementNode` | `XmlElement` |
| `TextNode` | `String` |
| `CDataNode` | `String` |
| `CommentNode` | `String` |
| `PiNode` | `(String, String)`（target, data） |
| `EntityRefNode` | `String`（实体名，不含 `&` 与 `;`） |

`XmlEntityRef(name)` SHALL 是**工厂函数**，返回 `XmlNode.EntityRefNode(name)`。
SHALL NOT 存在 `class XmlEntityRef <: XmlNode`（仓颉不允许类继承 enum）。

#### Scenario: 显式构造实体引用节点

- **WHEN** 调用 `XmlEntityRef("company")`
- **THEN** 得到 `EntityRefNode("company")`，`match` 可穷尽

#### Scenario: 节点种类可穷尽匹配

- **WHEN** 对 `XmlNode` 写 `match` 覆盖 6 个分支
- **THEN** 编译通过且无 `_` 兜底

### Requirement: XmlElement 的可变结构

`XmlElement` SHALL 提供：

- `prop name: QName`
- `prop attributes: ArrayList<XmlAttribute>`
- `prop children: ArrayList<XmlNode>`
- `init(name: QName)`、`init(name: String)`（无命名空间便捷构造）
- `setAttr(name: String, value: String): Unit`
- `appendChild(node: XmlNode): XmlElement`（返回自身，便于链式）
- `withText(text: String): XmlElement`
- `text(): String`（拼接所有后代文本，含 CDATA，不含注释 / PI）

#### Scenario: setAttr 覆盖同名属性

- **WHEN** 元素已有 `a="1"`，调用 `setAttr("a", "2")`
- **THEN** 属性仍只有 1 个，值为 `"2"`

#### Scenario: text 跳过注释

- **WHEN** 元素子节点为 `Text("a")`、`CommentNode("c")`、`CDataNode("b")`
- **THEN** `text() == "ab"`

### Requirement: XmlDocument 结构

`XmlDocument` SHALL 提供：

- `prop root: ?XmlElement`
- `prop declaration: ?XmlDeclaration`（`version: String`、`encoding: ?String`、`standalone: ?Bool`）
- `prop doctype: ?DocTypeInfo`（`name`、`publicId`、`systemId`、`entities: Array<EntityDecl>`）
- `prop prolog: ArrayList<XmlNode>`（根元素前的注释 / PI）
- `prop epilog: ArrayList<XmlNode>`（根元素后的注释 / PI）

`XmlDocument` SHALL NOT 暴露 `DomBuilder`（构建完成后 builder 无用途）。

#### Scenario: prolog 与 epilog 分别保留

- **WHEN** 解析 `<?xml version="1.0"?><!--p--><a/><?q v?><!--e-->`
- **THEN** `prolog` 有 1 个 `CommentNode`，`epilog` 有 1 个 `PiNode` 与 1 个 `CommentNode`

#### Scenario: DOCTYPE 携带实体声明

- **WHEN** 解析内部子集声明了两个实体的文档
- **THEN** `doc.doctype.entities.size == 2`，顺序与声明顺序一致

### Requirement: DomBuilder 文本合并

`DomBuilder` 收到连续 `Text` 事件时 SHALL 合并到同一个 `TextNode`；SHALL NOT 创建多个相邻
文本节点。合并 SHALL 使用 `StringGenerator` 累积。

#### Scenario: 三段文本合成一个节点

- **WHEN** 事件序列为 `Text("a")`、`Text("b")`、`Text("c")`
- **THEN** 元素的 `children` 中只有 1 个 `TextNode("abc")`

#### Scenario: CDATA 不被合并进文本节点

- **WHEN** 事件序列为 `Text("a")`、`CData("b")`
- **THEN** 产生 `TextNode("a")` 与 `CDataNode("b")` 两个节点

### Requirement: 建树时的深度上限

`DomBuilder` SHALL 在元素深度超过 `XmlParserOptions.maxElementDepth` 时抛 `XmlException`，
SHALL NOT 递归到栈溢出。

#### Scenario: 深度超限

- **WHEN** `maxElementDepth = 100` 解析 101 层嵌套
- **THEN** 抛 `XmlException`，消息含深度与上限

### Requirement: 往返语义一致

`XmlDocument` → `XmlWriter`（紧凑）→ `XmlParser.parse` → `XmlDocument`，两次结果 SHALL 在
**语义**上相同：元素展开名、属性集合（展开名 + 值）、文本内容与顺序、CDATA 与注释位置。

属性顺序、命名空间声明位置、空白形态 SHALL NOT 作为比较项。

#### Scenario: 常见文档往返

- **WHEN** 对一份含命名空间、CDATA、注释、PI、自定义实体的文档做往返
- **THEN** 两次 DOM 逐节点比较相等（按上述口径）

#### Scenario: 往返后文本里的回车保留

- **WHEN** 文本节点含 `\r`，往返一次
- **THEN** 第二次的文本节点仍含 `\r`（写侧用 `&#13;` 转义）
