# Spec Delta — f-xml-stream-parser

## ADDED Requirements

### Requirement: 事件模型

`XmlEvent` SHALL 是事件的**唯一定义**，不另设 kind 枚举。分支 SHALL 为：

`StartDocument`、`XmlDeclaration(version, encoding, standalone)`、`DocType(name, publicId, systemId)`、
`StartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool)`、`EndElement(name)`、
`Text(String)`、`CData(String)`、`Comment(String)`、`ProcessingInstruction(target, data)`、`EndDocument`。

#### Scenario: 分支集合固定且可穷尽

- **WHEN** 对 `XmlEvent` 写 `match` 覆盖上述 10 个分支
- **THEN** 编译通过，无需 `_` 兜底

### Requirement: 事件文本格式与顺序

`XmlEvent` SHALL 实现 `ToString`，输出**稳定文本**（用于推 / 拉事件日志逐行 diff），
SHALL NOT 实现 `Equatable`（带载荷的比较无语义）。

事件顺序 SHALL 固定为：

```
StartDocument → XmlDeclaration? → DocType? → (Comment | ProcessingInstruction)*
→ StartElement(root) → …递归… → EndElement(root) → (Comment | ProcessingInstruction)* → EndDocument
```

#### Scenario: 前导区多注释与 PI 交替

- **WHEN** 文档在根元素前有 `<!--a--><?p d?><!--b-->`
- **THEN** 事件序列中三者顺序与原文一致，且都在 `StartElement(root)` 之前

#### Scenario: 尾部注释

- **WHEN** 文档为 `<a/><!--tail-->`
- **THEN** `EndElement(a)` 之后仍有 `Comment("tail")`，最后是 `EndDocument`

#### Scenario: 声明最多一次

- **WHEN** 文档出现两个 `<?xml ...?>`
- **THEN** 第二个抛 `XmlException`（声明只能出现在最前）

### Requirement: 自闭合标签产出两条事件

`<a/>` SHALL 产出 `StartElement(a, [], selfClosing: true)` 后**立即**产出 `EndElement(a)`。
SHALL NOT 为省一条而只发 Start。

#### Scenario: 自闭合与空元素事件一致

- **WHEN** 分别解析 `<a/>` 与 `<a></a>`
- **THEN** 两次的事件序列除 `selfClosing` 字段外完全相同

### Requirement: 文本可能拆成多次回调

`Text` 事件 SHALL 允许把一段连续文本拆成多条（实体边界、CDATA 边界、缓冲边界）。
消费方 SHALL 自行拼接，解析器 SHALL NOT 承诺「一条 Text = 一个完整文本节点」。

#### Scenario: 文本内实体导致拆分

- **WHEN** 解析 `<a>x&amp;y</a>`
- **THEN** 允许产出 `Text("x")`、`Text("&")`、`Text("y")` 三条；DOM 侧合并为一个 `"x&y"`

### Requirement: 控制流返回值

`XmlAction` SHALL 有三个值 `Continue` / `SkipSubtree` / `Stop`，SHALL 声明
`<: Equatable<XmlAction> & ToString`，并 SHALL **显式实现** `public operator func ==(that: XmlAction): Bool`
（仓颉 enum 不自动派生 `==`，只声明接口会编译失败）。`InvalidByteMode` / `InvalidCharMode` /
`CdataMode` / `EntityOverflowPolicy` / `EntityLimitKind` 同样 SHALL 显式实现 `operator func ==`。

`XmlEventHandler` 的**所有方法 SHALL 带默认实现**（返回 `Continue`），实现方只需覆盖关心的
方法。SHALL NOT 提供 `stop()` / `skipCurrentElement()` 之类的 parser 侧方法。

#### Scenario: 只关心一个事件的 handler 不写空方法

- **WHEN** 定义 `class H <: XmlEventHandler { public func onEndElement(n: QName): XmlAction { … } }`
- **THEN** 编译通过，无需实现其余 9 个方法

#### Scenario: 枚举比较走显式实现

- **WHEN** 对 `XmlAction` 的三个取值做自反与两两比较
- **THEN** 同值返回 `true`、异值返回 `false`；比较不依赖编译器自动派生

#### Scenario: Stop 立即终止

- **WHEN** 在 `onEndElement` 第 3 次触发时返回 `Stop`
- **THEN** 不再有第 4 次回调，且底层流不被继续读取

#### Scenario: SkipSubtree 跳过子树

- **WHEN** 在 `onStartElement(b)` 返回 `SkipSubtree`，`b` 内有 1000 个子元素
- **THEN** `b` 的子元素、文本、注释、PI 都不回调，但 `onEndElement(b)` 仍回调一次

### Requirement: 拉模式是唯一内核

`XmlPullParser` SHALL 提供 `nextEvent(): ?XmlEvent`、`skipElement(): Unit`、`close(): Unit`。
`None` 表示文档结束（`EndDocument` 之后）。

推模式与单回调 SHALL 建立在拉模式之上（同一输入的事件日志逐行一致）。

#### Scenario: 推与拉事件日志一致

- **WHEN** 同一份含自闭合、CDATA、注释、PI、命名空间的文档分别用
  `XmlPullParser.nextEvent()` 与 `XmlParser.parse(input, handler)` 消费
- **THEN** 两份事件日志文本逐行相同

#### Scenario: 事件日志覆盖自闭合

- **WHEN** 输入为 `<a><b/></a>`
- **THEN** 日志中 `b` 有 START 与 END 各一条

### Requirement: 单回调重载

`XmlParser.parse(input, onEvent: (XmlEvent) -> XmlAction, options!)` SHALL 存在，返回 `Unit`，
SHALL NOT 产生 DOM。

#### Scenario: 一行 lambda 消费

- **WHEN** `XmlParser.parse(input) { e => XmlAction.Continue }`
- **THEN** 解析完整执行，无返回值可丢弃

### Requirement: skipElement 的前置条件与配对

`skipElement()` SHALL 在「刚产出 `StartElement`」之后调用才合法，其他位置 SHALL 抛
`XmlException("skipElement 必须在 StartElement 之后调用")`。

- 跳过范围 SHALL 是**当前元素的子节点**，匹配的 `EndElement` SHALL 仍然发出。
- 配对 SHALL 按**深度**，SHALL NOT 按「下一个同名 EndElement」。
- `selfClosing = true` 时 SHALL 是空操作（不吞掉待发的 `EndElement`）。
- 跳过期间 SHALL 只做标签级扫描：不解析属性值、不解码实体、不建节点，但 SHALL 正确处理
  引号内的 `>`、`<!-- -->`、`<![CDATA[ ]]>`、`<? ?>`。

#### Scenario: 同名元素嵌套

- **WHEN** `<a><b><b/></b></a>`，在 `a` 的 Start 之后 `skipElement()`
- **THEN** 只收到 `EndElement(a)`；内层 `b` 与 `<b/>` 都不产出事件

#### Scenario: 注释里的 > 不结束标签

- **WHEN** 跳过 `<a><!-- a > b --><c/></a>` 的子树
- **THEN** 正确跳到 `</a>`，不把 `<!-- a >` 当成标签结束

#### Scenario: 属性值里的 > 不结束标签

- **WHEN** 跳过 `<a><b x="1 > 0"/></a>` 的子树
- **THEN** 跳过成功，`</a>` 位置正确

#### Scenario: 自闭合 skip 是空操作

- **WHEN** 收到 `<a/>` 的 `StartElement(selfClosing: true)` 后调用 `skipElement()`
- **THEN** 下一次 `nextEvent()` 返回 `EndElement(a)`

#### Scenario: 非法位置调用报错

- **WHEN** 在 `Text` 事件之后调用 `skipElement()`
- **THEN** 抛 `XmlException`，消息含「StartElement」

### Requirement: 词法硬点（标签与属性）

解析器 SHALL 对下列标签 / 属性层情形报错（well-formedness 错误，全部带行列号）：

| 情形 | 例子 |
|---|---|
| 属性值里的裸 `<` | `<a b="<"/>` |
| 文本里的裸 `<` 后跟非法名字首字符 | `<a><1/></a>` |
| 标签名后缺空白 | `<a b="1"c="2"/>` |
| 属性值引号不配对 | `<a b="1'/>` |
| 同一元素重复属性（按**展开名**） | `<a x="1" x="2"/>`、`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>` |

#### Scenario: 重复属性按展开名判定

- **WHEN** 解析 `<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>`
- **THEN** 抛 `XmlException`（字面名不同但展开名相同）

#### Scenario: 属性值裸小于号

- **WHEN** 解析 `<a b="<"/>`
- **THEN** 抛 `XmlException`，消息提示应使用 `&lt;`

### Requirement: 词法硬点（结构、注释与上限）

解析器 SHALL 对下列结构层情形报错（well-formedness 错误，全部带行列号）：

| 情形 | 例子 |
|---|---|
| 注释含 `--` | `<!-- a -- b -->` |
| 注释以 `-` 结尾 | `<!-- a --->` |
| PI target 为 `xml`（任意大小写） | `<?XML x?>` |
| 结束标签与栈顶不匹配 | `<a></b>` |
| 多个根元素 | `<a/><b/>` |
| 无根元素 | 空文档 / 纯空白 / 只有注释 |
| 提前 EOF | `<a><b>` |
| 元素深度 > `maxElementDepth` | 5000 层嵌套 |
| 单个属性值长度 > `maxAttributeValueLength` | 2 MB 字面属性值 |

#### Scenario: 超深嵌套不栈溢出

- **WHEN** 解析 10000 层嵌套
- **THEN** 抛 `XmlException`（`maxElementDepth`），进程不崩溃

### Requirement: 字符引用与预定义实体

解析器 SHALL 支持 `&lt; &gt; &amp; &quot; &apos;`、`&#DDD;`、`&#xHHH;`。
其余命名实体（如 `&nbsp;`）SHALL 报错，SHALL NOT 从 HTML 实体表里猜。

非法码点（`&#0;`、代理区 `#xD800`–`#xDFFF`、`> #x10FFFF`、`#xZZ` 等形式）SHALL 报错。
`&#x1F600;` 这类 > U+FFFF 的码点 SHALL 正确产出**一个**码点。

#### Scenario: 高位码点

- **WHEN** 解析 `<a>&#x1F600;</a>`
- **THEN** 文本内容为 1 个字符 `😀`

#### Scenario: HTML 实体报错

- **WHEN** 解析 `<a>&nbsp;</a>`
- **THEN** 抛 `XmlException`，消息指出该实体未声明

#### Scenario: 裸 & 报错

- **WHEN** 解析 `<a>a & b</a>`
- **THEN** 抛 `XmlException`

#### Scenario: 代理区码点报错

- **WHEN** 解析 `<a>&#xD800;</a>`
- **THEN** 抛 `XmlException`，消息含码点

### Requirement: CDATA

`<![CDATA[ … ]]>` SHALL 原样保留内容，不解析实体、不解析标签；只有 `]]>` 结束。
相邻多个 CDATA SHALL 各触发一次 `CData`。空 CDATA SHALL 合法并产出空文本。

#### Scenario: CDATA 内的小于号与 &
- **WHEN** 解析 `<a><![CDATA[<b>&amp;]]></a>`
- **THEN** `CData` 内容为 `<b>&amp;`（不展开）

#### Scenario: CDATA 内的 ]]
- **WHEN** 解析 `<a><![CDATA[a]]b]]></a>`
- **THEN** 内容为 `a]]b`（只有 `]]>` 才结束）

#### Scenario: 空 CDATA

- **WHEN** 解析 `<a><![CDATA[]]></a>`
- **THEN** 产出一次 `CData("")`

### Requirement: 命名空间解析

进入元素时 SHALL 把 `xmlns` / `xmlns:prefix` 压入作用域栈，出栈时弹出。

1. `xml` 前缀 SHALL 固定绑定 `http://www.w3.org/XML/1998/namespace`，无需声明。
2. `xmlns` SHALL 不能作为元素或属性的前缀，否则报错。
3. 未声明的前缀 SHALL 报错，SHALL NOT 静默当作无命名空间。
4. 默认命名空间 SHALL 只作用于**元素名**，SHALL NOT 作用于属性名。
5. `xmlns=""` SHALL 把默认命名空间重置为无命名空间。
6. 内层重定义同一前缀 SHALL 覆盖外层，出栈后恢复。
7. 多个前缀指向同一 URI SHALL 视为同一命名空间。

#### Scenario: 属性不受默认命名空间影响

- **WHEN** 解析 `<a xmlns="X" b="1"/>`
- **THEN** `a` 的 `uri = Some("X")`，`b` 的 `uri = None`

#### Scenario: xmlns="" 重置

- **WHEN** 解析 `<a xmlns="X"><b xmlns=""/></a>`
- **THEN** `a.uri = Some("X")`，`b.uri = None`

#### Scenario: 嵌套重定义后恢复

- **WHEN** 解析 `<a xmlns:p="u1"><b xmlns:p="u2"/><c/></a>`
- **THEN** `b.uri = Some("u2")`，`c.uri = Some("u1")`

#### Scenario: 未声明前缀报错

- **WHEN** 解析 `<p:a/>`
- **THEN** 抛 `XmlException`，消息含前缀 `p`

#### Scenario: xmlns 作元素前缀报错

- **WHEN** 解析 `<xmlns:a/>`
- **THEN** 抛 `XmlException`

#### Scenario: xml 前缀无需声明

- **WHEN** 解析 `<a xml:lang="zh"/>`
- **THEN** 属性名 `prefix = Some("xml")`、`uri = Some("http://www.w3.org/XML/1998/namespace")`

### Requirement: 空白策略

解析器 SHALL 原样回调节点间空白。`XmlParserOptions.trimWhitespaceOnly = true` 时
`DomBuilder` SHALL 丢弃**纯空白**文本节点；`xml:space="preserve"` 作用域内 SHALL 强制保留；
`xml:space="default"` SHALL 恢复默认行为。

#### Scenario: 默认保留缩进空白

- **WHEN** 默认选项解析 `<a>\n  <b/>\n</a>`
- **THEN** `a` 的子节点含一个纯空白 `TextNode`

#### Scenario: trimWhitespaceOnly 丢弃纯空白

- **WHEN** `trimWhitespaceOnly = true` 解析同上
- **THEN** `a` 的子节点只有 `b`

#### Scenario: xml:space=preserve 强制保留

- **WHEN** `trimWhitespaceOnly = true` 解析 `<a xml:space="preserve">  <b/>  </a>`
- **THEN** 空白文本节点被保留

### Requirement: 版本门禁

`<?xml version="1.0"?>` 或缺省 SHALL 正常解析；`version="1.1"` SHALL 抛
`XmlException("XML 1.1 尚未支持（M3）")`，SHALL NOT 降级按 1.0 解析。
其他版本号（`2.0`、`abc`）SHALL 报错。

#### Scenario: 1.1 拒绝

- **WHEN** 解析 `<?xml version="1.1"?><a/>`
- **THEN** 抛 `XmlException`，消息含 `1.1`

### Requirement: 错误必须带行列号

所有 `XmlException` SHALL 带 `line` / `column`（1-based）。位置未知的错误 SHALL 用
`line = 0, column = 0`，SHALL NOT 编造一个位置。

#### Scenario: 单行超长文档也能定位

- **WHEN** 解析一份只有 1 行、30 万字符的文档，在第 20 万字符处有畸形标签
- **THEN** `line = 1`，`column` 为精确列号
