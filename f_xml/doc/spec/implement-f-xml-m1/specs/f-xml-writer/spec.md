# Spec Delta — f-xml-writer

## ADDED Requirements

### Requirement: 构造与生命周期

`XmlWriter` SHALL 提供：

- `init(output: OutputStream, options!: XmlWriterOptions = XmlWriterOptions())`
- `write(doc: XmlDocument): Unit`
- `write(element: XmlElement): Unit`
- `flush(): Unit`
- `close(): Unit`

`close()` 之后调用任何方法 SHALL 是**未定义行为**；类注释与 README SHALL 明确写出
「close 后不得再调用任何方法」。

`flush()` SHALL 冲刷自身缓冲，并对底层 `output` 调用 `flush()`。

#### Scenario: close 后冲刷底层

- **WHEN** 写入后调用 `close()`
- **THEN** 底层 `OutputStream` 收到全部字节，并被 `flush()`

#### Scenario: 不 flush 时数据可能停在缓冲

- **WHEN** 写入后既不 `flush()` 也不 `close()` 就读取底层缓冲
- **THEN** 允许内容不完整（这是文档已声明的契约，不是缺陷）

### Requirement: 紧凑与缩进

`indent` 默认 `None`（紧凑），SHALL NOT 在两个标签之间插入任何空白。
`indent = Some(s)` 时 SHALL 用 `s` 逐层缩进，换行只由 `indent` 产生。

#### Scenario: 紧凑模式不产生额外空白

- **WHEN** 生成 `<a><b>x</b></a>` 的 DOM
- **THEN** 输出逐字节等于 `<a><b>x</b></a>`（无换行、无空格）

#### Scenario: 缩进模式只在元素之间换行

- **WHEN** `indent = Some("  ")` 生成同上 DOM
- **THEN** 输出为多行，且 `<b>x</b>` 内部的 `x` 前后没有额外空白

### Requirement: 转义表

写侧 SHALL 按下列规则转义：

| 字符 | 文本节点 | 属性值 |
|---|---|---|
| `&` | `&amp;` | `&amp;` |
| `<` | `&lt;` | `&lt;` |
| `>` | `&gt;` | `&gt;` |
| `"` | 不转 | `&quot;`（双引号包裹） |
| `'` | 不转 | `&apos;`（单引号包裹） |
| `\r` | `&#13;` | `&#13;` |

`\r` SHALL 必须转义，否则写出再读回会被行尾归一成 `\n`，往返不一致。

#### Scenario: 文本里的回车

- **WHEN** 文本节点为 `"a\rb"`
- **THEN** 输出含 `a&#13;b`，且重新解析后文本仍为 `"a\rb"`

#### Scenario: 属性值里的引号

- **WHEN** 属性值为 `a"b`
- **THEN** 输出用双引号包裹并写成 `a&quot;b`

### Requirement: 非法字符拒绝

XML 1.0 不允许的字符（`0x00`–`0x08`、`0x0B`、`0x0C`、`0x0E`–`0x1F`）SHALL 抛 `XmlException`，
消息 SHALL 指出所在元素名或属性名。SHALL NOT 静默剔除。

#### Scenario: 文本含 NUL

- **WHEN** 文本节点含 `0x00`
- **THEN** 抛 `XmlException`，消息含元素名与码点

#### Scenario: 属性值含控制字符

- **WHEN** 属性值含 `0x0B`
- **THEN** 抛 `XmlException`，消息含属性名

### Requirement: CDATA 模式

`CdataMode` SHALL 有三个值，SHALL 声明 `<: Equatable<CdataMode> & ToString`，并 SHALL
**显式实现** `operator func ==`（仓颉 enum 不自动派生）：

| 值 | 行为 |
|---|---|
| `Auto`（默认） | 常规转义，不产 CDATA |
| `Always` | 所有**文本节点**用 `<![CDATA[ … ]]>` 包裹 |
| `Never` | 强制转义，即使内容适合 CDATA |

`Always` 下若文本含 `]]>`，SHALL 拆成 `]]]]><![CDATA[>`。
属性值 SHALL NOT 使用 CDATA（CDATA 只存在于元素内容），`Always` 不影响属性值转义。

#### Scenario: Always 包裹普通文本

- **WHEN** `cdata = Always`，文本为 `a<b`
- **THEN** 输出含 `<![CDATA[a<b]]>`

#### Scenario: ]]> 被拆分

- **WHEN** `cdata = Always`，文本为 `a]]>b`
- **THEN** 输出含 `a]]]]><![CDATA[>b`，且重新解析后文本仍为 `a]]>b`

#### Scenario: Always 不影响属性值

- **WHEN** `cdata = Always`，属性值为 `a<b`
- **THEN** 输出为 `a&lt;b`，不出现 CDATA

### Requirement: 自定义实体引用

写侧 SHALL 支持显式实体引用节点 `XmlNode.EntityRefNode(name)`（由 `XmlEntityRef(name)` 构造）：

- SHALL 直接输出 `&name;`，SHALL NOT 转义。
- 若 `options.doctype` 声明了该实体，SHALL 在 `write()` 开头输出
  `<!DOCTYPE name [ … ]>`（含内部子集）。
- 若未声明：`strictEntities = true`（默认）SHALL 在 `write()` 时抛 `XmlException`；
  `strictEntities = false` SHALL 只告警并输出。

#### Scenario: 已声明实体正常输出

- **WHEN** `doctype` 声明了 `company`，DOM 里有 `EntityRefNode("company")`
- **THEN** 输出 `<a>&company;</a>`，且开头有 `<!DOCTYPE … [ <!ENTITY company "…"> ]>`

#### Scenario: 未声明实体默认报错

- **WHEN** `strictEntities = true` 且未在 `doctype` 里声明 `company`
- **THEN** 抛 `XmlException`，消息含 `company`

#### Scenario: 关闭严格模式只告警

- **WHEN** `strictEntities = false`
- **THEN** 输出 `&company;`，不抛异常

### Requirement: 输出编码

`XmlWriterOptions.charset` 默认 `Charsets.UTF8`。

- UTF-8 SHALL 走 `std.io.StringWriter` + `StringGenerator.unsafeBytes()` 直接写字节。
- 其他编码 SHALL 走 `charset4cj.TextWriter`。
- UTF-16 / UTF-32 SHALL 在输出开头**自己写 BOM**；UTF-8 SHALL NOT 写 BOM。
- SHALL NOT 用 `writeln()` 生成 XML 内容。

#### Scenario: 默认无 BOM

- **WHEN** 用默认选项生成
- **THEN** 输出首字节为 `<`（`0x3C`），不是 `0xEF`

#### Scenario: UTF-16LE 带 BOM

- **WHEN** `charset = UTF-16LE`
- **THEN** 输出以 `FF FE` 开头，且内容正确

#### Scenario: GBK 输出可读

- **WHEN** `charset = GBK` 输出中文
- **THEN** 字节按 GBK 编码，用 GBK 解回内容一致

### Requirement: 输出缓冲

`XmlWriter` SHALL 在内部累积 token（`StringGenerator`），攒到 8~64 KB 再一次性写底层，
SHALL NOT 一个 token 一次 `write`。

#### Scenario: 底层写入次数远小于 token 数

- **WHEN** 生成一份含 5 万个 token 的文档，用一个计次的 `OutputStream`
- **THEN** 写次数显著少于 5 万（按缓冲大小换算的量级）

### Requirement: 写方向的编码失败策略

`XmlWriterOptions.onInvalidChar` SHALL 默认 `Throw`，语义 SHALL 与 `f-xml-char-layer` 的
「写方向的编码失败策略」一致（往返校验、`Replace` 用 `?`、UTF 系列跳过校验）。

#### Scenario: UTF-8 不校验

- **WHEN** `charset = UTF-8` 写出含任意 Unicode 的文档
- **THEN** 不抛异常，不做 encode→decode 往返

### Requirement: 命名空间声明最小化

序列化时 SHALL 只在**首次引入或改变绑定**时输出 `xmlns` / `xmlns:prefix`：

- 父元素已声明 `xmlns="A"`，子元素仍为 `A` → 子元素不重复声明。
- 子元素改为 `B` → 子元素声明 `xmlns="B"`。
- 子元素回到无命名空间 → SHALL 输出 `xmlns=""`。

#### Scenario: 不重复声明

- **WHEN** 生成 `<a xmlns="A"><b/></a>` 的 DOM
- **THEN** 输出中 `xmlns="A"` 只出现 1 次

#### Scenario: 重置必须写空串

- **WHEN** 元素从 `Some("A")` 变为 `None`
- **THEN** 输出含 `xmlns=""`

### Requirement: 写元素与写文档

`write(element)` SHALL 输出元素本身作为根（若元素有命名空间，SHALL 在该元素上声明）；
`write(doc)` SHALL 依次输出 `declaration`、`doctype`、`prolog`、`root`、`epilog`。

#### Scenario: 只写元素不带声明

- **WHEN** `write(element)`
- **THEN** 输出不以 `<?xml` 开头

#### Scenario: 写文档带声明与前导注释

- **WHEN** `write(doc)`，doc 有声明与 1 条前导注释
- **THEN** 输出顺序为声明 → 注释 → 根元素
