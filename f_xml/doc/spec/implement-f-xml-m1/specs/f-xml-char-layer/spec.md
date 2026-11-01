# Spec Delta — f-xml-char-layer

## ADDED Requirements

### Requirement: 数据源抽象

`f_xml` SHALL 只以 `std.io.InputStream` 作为字节输入，SHALL NOT 依赖或 import `f_io.ByteBuffer`
或任何具体缓冲区实现。以下入口 SHALL 存在：

- `XmlParser.parse(input: InputStream, options!)`
- `XmlParser.parse(bytes: Array<Byte>, options!)`
- `XmlParser.parse(text: String, options!)`
- `XmlParser.parse(path: Path, options!)`
- `XmlPullParser.init(input: InputStream, options!)`
- `XmlWriter.init(output: OutputStream, options!)`

`parse(text)` SHALL 跳过字节嗅探（输入已是字符）；其余入口 SHALL 走嗅探。

#### Scenario: 自定义 InputStream 可直接解析

- **WHEN** 传入一个仅实现 `read(buffer: Array<Byte>): Int64` 的自定义流（模拟 TCP）
- **THEN** 解析成功，且 `f_xml/cjpm.toml` 的依赖表中不出现 `f_io`

#### Scenario: parse(path) 读到 EOF

- **WHEN** `parse(path)` 指向一个 3 字节的 `<a/>`
- **THEN** 返回的 `XmlDocument.root` 非 `None`，且没有因「流永不结束」而阻塞

#### Scenario: parse(text) 不重新编码

- **WHEN** `parse("<?xml version=\"1.0\" encoding=\"GBK\"?><a>中</a>")`（已是 String）
- **THEN** 解析成功，不因声明与实际编码不符报错（`text` 入口不做字节解码）

### Requirement: 字节嗅探

嗅探 SHALL 按 `BOM → XML 声明 → UTF-8` 的优先级确定字符集（BOM / 附录 F 魔数 / 声明的具体
字节模式见 `design.md` §6.1）。BOM 与 `encoding` 声明**冲突**时 SHALL 抛 `XmlException`
（致命错误），消息 SHALL 带出两个编码名与行列号；无 BOM 时声明才是决定性线索。
嗅探消费的字节 SHALL 全部进入 `PrefixStream` 回放，SHALL NOT 丢弃。

#### Scenario: UTF-8 BOM 被跳过

- **WHEN** 输入为 `EF BB BF` + `<a>x</a>`
- **THEN** 根元素名为 `a`，文本为 `x`；不产生以 `U+FEFF` 开头的文本节点

#### Scenario: UTF-16LE 带 BOM

- **WHEN** 输入为 `FF FE` + `<a>x</a>` 的 UTF-16LE 编码
- **THEN** 解析成功，文本为 `x`

#### Scenario: UTF-32LE 不被误判成 UTF-16LE

- **WHEN** 输入为 `FF FE 00 00` + UTF-32LE 内容
- **THEN** 按 UTF-32LE 解码成功（4 字节 BOM 优先于 2 字节 BOM）

#### Scenario: 无 BOM 的 UTF-16BE 靠魔数识别

- **WHEN** 输入为 `00 3C 00 3F` 开头的 UTF-16BE 文档
- **THEN** 按 UTF-16BE 解码成功

#### Scenario: BOM 与声明冲突报致命错误

- **WHEN** 输入为 UTF-8 BOM + `<?xml version="1.0" encoding="GBK"?><a>中</a>`（内容实为 UTF-8）
- **THEN** 抛 `XmlException`，消息含 `GBK`、`UTF-8` 与行列号；SHALL NOT 按任何一种编码
  把文档解析成功

#### Scenario: 无 BOM 时声明决定编码

- **WHEN** 输入无 BOM，`<?xml version="1.0" encoding="GBK"?>`，内容为 GBK 字节
- **THEN** 按 GBK 解析成功（此时声明是唯一线索，不构成冲突）

### Requirement: 前缀回放流

`PrefixStream` SHALL 实现 `InputStream`，把 `prefix` 先输出、`rest` 后接；读完后返回 `0`（`InputStream` 契约）；
`close()` SHALL 关闭 `rest`。`prefix` 类型 SHALL 为 `Array<Byte>`，SHALL NOT 做任何编码判断。

#### Scenario: 前缀与剩余拼成连续流

- **WHEN** `prefix = [0x3C, 0x61]`、`rest` 提供 `>x</a>`
- **THEN** 连续读出 `<a>x</a>`，EOF 后返回 `0`

#### Scenario: close 关闭底层流

- **WHEN** 调用 `close()`
- **THEN** `rest` 的 `close()` 被调用一次

### Requirement: 字符来源与位置

`RuneSource` SHALL 提供 `peek(offset: Int64): ?Rune`（`0` = 当前字符）、`advance(): ?Rune`、
`position(): SourcePosition`。`peek` SHALL 只在 `offset ≤ 4` 时保证有效（实现可用固定
8 槽环形缓冲）。SHALL NOT 提供 `byteOffset`。

`SourcePosition` SHALL 是 1-based 的行列号（`line` / `column`）。

#### Scenario: 前瞻不移动游标

- **WHEN** 当前字符为 `<`，调用 `peek(1)` 两次
- **THEN** 两次都返回同一个字符，且随后 `advance()` 仍返回 `<`

#### Scenario: 行列号 1-based

- **WHEN** 输入为 `<a>\n<b>`，消费到 `<b>` 的 `<`
- **THEN** `position()` 为 `(line = 2, column = 1)`

### Requirement: UTF-8 解码策略选择

三个实现 SHALL 存在：`Utf8RuneSource`、`CharsetRuneSource`（`charset4cj.TextReader`）、
`BlockRuneSource`（固定块解码）。`Utf8RuneSource` SHALL 按 `InvalidByteMode` 选择解码策略：
`Strict` 与 `Replace` 均走自研 UTF-8 字节解码（`Utf8Strict` / `Utf8ReplaceDecoder`），并与 `BlockRuneSource`
共用同一 `ByteDecoder`（固定块读取、块尾回退、行列号推进）。两条策略 SHALL NOT 互相替代。

#### Scenario: 三种字符来源都能构造

- **WHEN** 分别用 UTF-8、GBK、UTF-16LE 输入构造 `RuneSource`
- **THEN** 都返回可用实现，首次 `position()` 为 `(line = 1, column = 1)`

### Requirement: 行拼接与行尾归一

字符层 SHALL 把 `readln()` 的结果拼回字符窗口，并满足：

1. `Some("")` 是**空行**，SHALL 补一个 `\n`；`None` 是**流结束**，SHALL NOT 补 `\n`。
2. `\r\n` 与孤立 `\r` SHALL 归一成 `\n`，且归一 SHALL 只在字符层做一次。
3. SHALL NOT 假设「一行等于一个 token」——属性值、注释、CDATA 可跨行。

#### Scenario: 空行与 EOF 区分

- **WHEN** 输入为 `"<a>\n"`（一行内容 + 终止换行）
- **THEN** 文本节点为 `"\n"`，不是 `"\n\n"`

#### Scenario: 孤立 CR 归一

- **WHEN** 输入为 `"<a>x\ry</a>"`
- **THEN** 文本节点为 `"x\ny"`

#### Scenario: CRLF 只归一一次

- **WHEN** 输入为 `"<a>x\r\ny</a>"`
- **THEN** 文本节点为 `"x\ny"`，不是 `"x\n\ny"` 或 `"x\r\ny"`

#### Scenario: 属性值跨行

- **WHEN** 属性值跨越 3 个物理行
- **THEN** 属性值完整，行内换行按规范化规则变成空格

### Requirement: UTF-16/32 不走行切分

UTF-16 与 UTF-32 输入 SHALL 使用 `BlockRuneSource` 固定块解码，SHALL NOT 使用 `readln()`。
块尾不完整字符 SHALL 留到下一块（UTF-16 回退 ≤ 3 字节，UTF-32 回退 ≤ 3 字节）。
`BlockRuneSource` 与 UTF-8 的 `Replace` 路径 SHALL 共用 `ByteDecoder` 的块边界与回退逻辑。

GBK 等多字节编码 SHALL 仍走 `readln()`（尾字节范围不含 `0x0A`）。

#### Scenario: UTF-16 文档跨块边界

- **WHEN** 用 `bufSize = 16` 解析一份 4 KB 的 UTF-16LE 文档，其中含 3 字节的非 ASCII 字符
- **THEN** 全部字符正确，无 U+FFFD，无丢字

#### Scenario: UTF-16 的 U+0A00 不被当换行

- **WHEN** UTF-16LE 文档文本中出现 U+0A00（低字节为 `0x0A`）
- **THEN** 该字符作为一个完整字符读出，行列号不分裂，且该字符不丢失

### Requirement: 读方向的解码失败策略

`InvalidByteMode` SHALL 有两个值，且两条路径 SHALL 由不同解码实现承担：

- `Strict`（默认）：UTF-8 走自研 `Utf8Strict` 字节解码；字节序列不符合声明字符集时抛
  `XmlException`，消息带行号、列号、坏字节偏移。
- `Replace`：UTF-8 走自研 `Utf8ReplaceDecoder`，按 RFC 3629 maximal subpart 消费，每个最大
  子部分产出**恰好一个** `U+FFFD`；该解码器 SHALL 与 `BlockRuneSource` 共用 `ByteDecoder`。

`Strict` 路径 SHALL NOT 复用 `Replace` 解码器。两种模式的输出 SHALL 分别由 golden 测试钉住：
合法输入两模式逐字符一致；非法输入按上述规则分歧。SHALL NOT 提供「跳过」模式。

#### Scenario: Strict 报错带位置

- **WHEN** `onInvalidByte = Strict`，输入含非法 UTF-8 字节 `0xFF`
- **THEN** 抛 `XmlException`，消息含行号、列号与坏字节偏移

#### Scenario: Strict 的合法输入与 Replace 一致

- **WHEN** 同一份含 1/2/3/4 字节 UTF-8 字符的合法文档分别用 `Strict` 与 `Replace` 解析
- **THEN** 两次文本逐字符相同，不出现 `U+FFFD`

#### Scenario: Replace 产出单个替换符

- **WHEN** `onInvalidByte = Replace`，输入含 `0xE0 0x80`（不完整序列）
- **THEN** 文本中该位置是 **1 个** `U+FFFD`，后续字符不错位

#### Scenario: 每个最大子部分各产一个替换符

- **WHEN** 输入依次含 `0xE0 0x80`、`0xF0 0x80 0x80`、`0xF5` 三段坏序列
- **THEN** 每段只产 1 个 `U+FFFD`，三段之间的 ASCII 字符位置不变

#### Scenario: 块边界截断与块内截断一致

- **WHEN** `bufSize = 4` 与 `bufSize = 8` 让 2/3/4 字节序列跨块
- **THEN** 解码结果与整块读取逐字符相同，块边界不额外产生 `U+FFFD`

#### Scenario: Replace 的替换符参与长度与比较

- **WHEN** `onInvalidByte = Replace` 且文档含 1 个坏字节
- **THEN** 文本长度为 `U+FFFD` 计入的长度，且 `text().size` 与 `Strict` 下的差异可解释

### Requirement: 写方向的编码失败策略

`InvalidCharMode` SHALL 有两个值：`Throw`（默认，抛 `XmlException`，带码点与位置）、
`Replace`（用 `?`（`0x3F`）代替，SHALL NOT 用 `U+FFFD`）。

检测 SHALL 用**往返校验**（`encode → decode → 比较`），SHALL NOT 依赖 `Encoder.encode`
抛异常。UTF-8 / UTF-16 / UTF-32 SHALL 跳过该校验。

#### Scenario: GBK 写 emoji 抛错

- **WHEN** `charset = GBK`、`onInvalidChar = Throw`，写入文本 `😀`
- **THEN** 抛 `XmlException`，消息含码点 `U+1F600` 与文本内位置

#### Scenario: GBK 写 emoji 用问号替换

- **WHEN** 同上但 `onInvalidChar = Replace`
- **THEN** 输出字节解回来是 `?`，且字符数与原文本一致（不是被跳过而少字符）

#### Scenario: UTF-8 不做往返校验

- **WHEN** `charset = UTF-8` 写任意文本
- **THEN** 不执行 encode→decode 往返（用计数器断言调用次数为 0）

### Requirement: 文本累积

解析侧的文本累积 SHALL 使用 `fountain::f_base.StringGenerator`，SHALL NOT 使用
`std.core.StringBuilder`，也 SHALL NOT 用 `String +` 循环拼接。

`StringGenerator.unsafeBytes()` 的值 SHALL NOT 被缓存跨 `append` 使用；需要时重新取。

#### Scenario: 大文本不出现二次复杂度

- **WHEN** 解析一份 1 MB 文本内容的文档
- **THEN** 不出现逐字符新建 `String` 的路径（`append(r: Rune)` 或按段 `append`）

### Requirement: 缓冲大小可配

`XmlParserOptions.bufSize` SHALL 可配，默认 `8192`，并 SHALL 传给 `TextReader` / `BlockRuneSource`
作为块大小。

#### Scenario: 两种 bufSize 结果一致

- **WHEN** 同一份文档分别用 `bufSize = 512` 与 `bufSize = 65536` 解析
- **THEN** 两次产物 DOM 逐节点相同（文本、属性、顺序）
