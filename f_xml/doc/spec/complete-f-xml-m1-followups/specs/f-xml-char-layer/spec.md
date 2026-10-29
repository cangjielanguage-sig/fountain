# Spec Delta — f-xml-char-layer

## Purpose

把字符层从「逐字符解码 + 两级环形缓冲」改写为「按块解码 + 单一活动缓冲」，在**不改公开
签名、不改事件序列、不改错误语义**的前提下，让事件模式解析达到 10 MB < 1 s，并让 RSS
不随文档线性增长。本 delta 覆盖 `implement-f-xml-m1/specs/f-xml-char-layer/spec.md` 的
五个 Requirement（字符来源、行归一、UTF-16/32、缓冲大小、文本累积），并新增四个
Requirement（块解码、缓冲合并、热路径零分配、语义等价）。

## MODIFIED Requirements

### Requirement: 字符来源与位置

`RuneSource` SHALL 提供 `peek(offset: Int64): ?Rune`（`0` = 当前字符）、`advance(): ?Rune`、
`position(): SourcePosition`，并 SHALL 同时提供热路径版本
`peekFast(offset: Int64): Int64` 与 `advanceFast(): Int64`（`-1` 表示流结束），两者语义
SHALL 与 `Option` 版本完全一致。

`peek` / `peekFast` SHALL 只在 `offset ≤ 4` 时保证有效；实现 SHALL 至少保留 8 个码点的
前瞻余量。实现 SHALL NOT 依赖固定 16 槽环形缓冲——容量 SHALL 由 `bufSize` 推导（见
「缓冲大小可配」）。SHALL NOT 提供 `byteOffset`。

`SourcePosition` SHALL 是 1-based 的行列号（`line` / `column`）。

#### Scenario: 前瞻不移动游标

- **WHEN** 当前字符为 `<`，调用 `peek(1)` 与 `peekFast(1)` 各两次
- **THEN** 两个版本返回同一个字符，且随后 `advance()` 仍返回 `<`

#### Scenario: 行列号 1-based

- **WHEN** 输入为 `<a>\n<b>`，消费到 `<b>` 的 `<`
- **THEN** `position()` 为 `(line = 2, column = 1)`

#### Scenario: 前瞻余量与块容量无关

- **WHEN** `bufSize = 4`、`bufSize = 65536` 分别解析同一份文档
- **THEN** `peekFast(0..4)` 在两者上都有效，返回的码点相同

### Requirement: 行拼接与行尾归一

字符层 SHALL 保证：

1. `Some("")` 是**空行**，SHALL 补一个 `\n`；`None` 是**流结束**，SHALL NOT 补 `\n`。
2. `\r\n` 与孤立 `\r` SHALL 归一成 `\n`，且归一 SHALL 只在字符层做一次。
3. SHALL NOT 假设「一行等于一个 token」——属性值、注释、CDATA 可跨行。
4. 归一 SHALL 在**块填充**时完成；`\r` 位于块尾、`\n` 位于下一块开头时 SHALL 用跨块状态
   吞掉该 `\n`，SHALL NOT 产出两个 `\n`。
5. 行列号 SHALL 只在消费（`advance` / `advanceFast`）时推进；填充 SHALL NOT 改变
   `position()`。

#### Scenario: 空行与 EOF 区分

- **WHEN** 输入为 `"<a>\n"`（一行内容 + 终止换行）
- **THEN** 文本节点为 `"\n"`，不是 `"\n\n"`

#### Scenario: 孤立 CR 归一

- **WHEN** 输入为 `"<a>x\ry</a>"`
- **THEN** 文本节点为 `"x\ny"`

#### Scenario: CRLF 只归一一次

- **WHEN** 输入为 `"<a>x\r\ny</a>"`
- **THEN** 文本节点为 `"x\ny"`，不是 `"x\n\ny"` 或 `"x\r\ny"`

#### Scenario: CRLF 跨块边界

- **WHEN** `bufSize ∈ {4, 8, 16, 64}`，`\r` 落在块尾、`\n` 落在下一块开头
- **THEN** 文本中只有一个 `\n`，且后续字符的行列号与整块读取一致

#### Scenario: 属性值跨行

- **WHEN** 属性值跨越 3 个物理行
- **THEN** 属性值完整，行内换行按规范化规则变成空格

### Requirement: UTF-16/32 不走行切分

UTF-16 与 UTF-32 输入 SHALL 使用 `BlockRuneSource` 固定块解码，SHALL NOT 使用 `readln()`。
块尾不完整字符 SHALL 留到下一块（UTF-16 回退 ≤ 3 字节，UTF-32 回退 ≤ 3 字节）。
`BlockRuneSource` 与 UTF-8 的 `Replace` 路径 SHALL 共用 `ByteDecoder` 的块边界与回退逻辑。

`BlockRuneSource` 的块解码 SHALL 一次产出多个码点（数量由 `bufSize` 推导），SHALL NOT
在 Lexer 热路径上逐字符调用解码器。

GBK 等多字节编码 SHALL 仍走 `charset4cj.TextReader`（尾字节范围不含 `0x0A`）。

#### Scenario: UTF-16 文档跨块边界

- **WHEN** 用 `bufSize = 16` 解析一份 4 KB 的 UTF-16LE 文档，其中含 3 字节的非 ASCII 字符
- **THEN** 全部字符正确，无 U+FFFD，无丢字

#### Scenario: UTF-16 的 U+0A00 不被当换行

- **WHEN** UTF-16LE 文档文本中出现 U+0A00（低字节为 `0x0A`）
- **THEN** 该字符作为一个完整字符读出，行列号不分裂，且该字符不丢失

### Requirement: 缓冲大小可配

`XmlParserOptions.bufSize` SHALL 可配，默认 `8192`，并 SHALL 作为 `TextReader` /
`BlockRuneSource` 的**字节块**大小。

码点块容量 SHALL 由 `max(64, min(bufSize, 1048576))` 推导（单位：码点）。下限 64 SHALL
保证 `peek(≤ 4)` 的前瞻余量与 `bufSize = 4 / 8 / 16` 的既有用例；上限 SHALL 保证
单块内存不超过 4 MiB。

`bufSize` SHALL 只影响性能与内存上界，SHALL NOT 影响解析结果、事件序列或错误消息。

#### Scenario: 两种 bufSize 结果一致

- **WHEN** 同一份文档分别用 `bufSize = 512` 与 `bufSize = 65536` 解析
- **THEN** 两次产物 DOM 逐节点相同（文本、属性、顺序）

#### Scenario: 极小 bufSize 仍然正确

- **WHEN** `bufSize = 4` 解析一份含 4 字节 UTF-8 字符与 `\r\n` 的文档
- **THEN** 解析成功，文本与 `bufSize = 65536` 完全一致

### Requirement: 文本累积

解析侧的文本累积 SHALL 使用 `fountain::f_base.StringGenerator`，SHALL NOT 使用
`std.core.StringBuilder`，也 SHALL NOT 用 `String +` 循环拼接。

`StringGenerator.unsafeBytes()` 的值 SHALL NOT 被缓存跨 `append` 使用；需要时重新取。

热路径 SHALL NOT 为每个字符构造 `String`；ASCII 字符 SHALL 走
`StringGenerator.append(Rune)` 的单字节快车道。

#### Scenario: 大文本不出现二次复杂度

- **WHEN** 解析一份 1 MB 文本内容的文档
- **THEN** 不出现逐字符新建 `String` 的路径（`append(r: Rune)` 或按段 `append`）

## ADDED Requirements

### Requirement: 码点块解码

`BufferedRuneSource` SHALL 按块产出码点：一次填充至多 `blockCapacity` 个码点到
`Array<Int32>`，`-1` 作为 EOF 哨兵，SHALL NOT 在块内逐字符分配 `Option` 或 `Rune` 包装
（`CharsetRuneSource` 的已登记例外见「热路径零 Option 分配」）。

UTF-8 块解码 SHALL 对连续 ASCII 段做批量搬运（一次循环搬多个字节，SHALL NOT 每字节一次
`ensure`）；多字节序列 SHALL 走既有单字符解码路径，块尾回退 SHALL 保持 ≤ 3 字节。
UTF-16 / UTF-32 块解码 SHALL 复用同一 `ByteDecoder` 与同一回退逻辑。

`BufferedRuneSource` SHALL 暴露内部计数（块填充次数、累计码点数），用于测试断言
「确实按块解码」；该计数 SHALL NOT 参与任何业务判断，也 SHALL NOT 进入公开 API。

#### Scenario: 块填充次数与字符数成数量级差

- **WHEN** 解析一份 1 MB 的 ASCII 文档（默认 `bufSize = 8192`）
- **THEN** 块填充次数 ≤ 码点数 / 64 + 1，而不是接近码点数

#### Scenario: 块解码与整块读取逐字符一致

- **WHEN** 同一份含 1/2/3/4 字节 UTF-8 字符的文档，分别用 `bufSize = 4, 8, 16, 64, 8192`
- **THEN** 产出的码点序列完全一致，块边界不额外产生 `U+FFFD`

#### Scenario: 坏字节的报错时点与位置

- **WHEN** `bufSize = 8192`，文档在若干合法元素之后出现非法 UTF-8 字节
- **THEN** 坏字节之前的事件**先送达**；错误在解析器消费到该字符时才抛出，
  `line` / `column` 指向坏字符自身，消息仍含原字节偏移；`peek` 命中该位置同样抛错，
  不返回 `-1` 伪装 EOF

### Requirement: 三层缓冲合并

活动解析路径上 SHALL 只有一个码点块缓冲：`LineWindow` 的 `Array<Int32>`。
`BufferedRuneSource` SHALL 通过内部块读入口（`readCodePointBlock`，`internal`）把码点直接
写进 `LineWindow` 的数组，SHALL NOT 再维护一份供 `LineWindow` 使用的环形缓冲。

`BufferedRuneSource` 自身需要的块 SHALL 惰性分配：仅当调用方直接使用 `RuneSource`
的 `peek` / `advance` 时才分配；被 `LineWindow` 驱动时 SHALL NOT 分配。

`LineWindow` 遇到**不是** `BufferedRuneSource` 的 `RuneSource`（第三方直接实现接口）时
SHALL 回退到逐字符填充，结果 SHALL 与块路径逐字符一致。

#### Scenario: 主路径不分配第二份块

- **WHEN** 通过 `XmlParser.parse` 解析任意文档
- **THEN** `BufferedRuneSource` 的自有块始终未分配（内部断言），解码只写入 `LineWindow` 的数组

#### Scenario: 自定义 RuneSource 走回退路径

- **WHEN** 传入一个只实现 `RuneSource` 五个方法、不继承 `BufferedRuneSource` 的自定义源
- **THEN** 解析成功，事件日志与内置 UTF-8 源逐行一致

### Requirement: 热路径零 Option 分配

词法器扫描 SHALL 只用 `peekCp` / `advanceCp`（`Int64`），SHALL NOT 在扫描循环、固定串匹配、
实体帧与溢出读回中出现 `?Rune`、`match (Some/None)` 或 `Rune.position()`。固定串匹配 SHALL
使用预置码点常量（`Array<Int64>`），SHALL NOT 每次调用 `runesOf(text)`。例外
（`CharsetRuneSource` 块填充、`DoctypeParser` / `SkipScanner` 冷路径）见 `design.md`
§3.8 / §4.2，且 SHALL NOT 出现在 Lexer 的 `peekCp` / `advanceCp` 路径上。

#### Scenario: 扫描路径无 Option

- **WHEN** 对 `src/Lexer.cj` 的扫描方法做静态检查（`grep` 断言）
- **THEN** 文本 / 标签 / 属性 / 注释 / CDATA / PI / DOCTYPE 的循环体内不出现
  `peek(` / `advance(` / `Rune.position(`（异常消息与极少见路径除外，逐条列白名单）

#### Scenario: 固定串匹配不分配数组

- **WHEN** 解析一份含 10 万个 `?>` 的 PI 文档
- **THEN** 不出现每次匹配新建 `Array<Rune>` 的路径；耗时随字符数线性

### Requirement: 语义等价与回归护栏

字符层重写 SHALL 保持下列不变：

1. `peek` / `advance`（`Option` 版本）与 `peekFast` / `advanceFast` 的返回值逐字符一致；
2. `InvalidByteMode.Strict` 与 `Replace` 两条路径的输出逐字符不变，且互不替代；
3. 事件序列、文本内容、错误消息、`line` / `column`、`entityLimitKind` 不变；
4. 推模式与拉模式的事件日志逐行一致；
5. 公开类型与方法签名零变更。

#### Scenario: 块大小与编码矩阵等价

- **WHEN** 用 `bufSize ∈ {4, 8, 16, 64, 8192, 65536}` 解析 UTF-8（strict / replace）、
  GBK、UTF-16LE、UTF-16BE、UTF-32LE 六份文档
- **THEN** 事件日志、文本、`position()` 序列与错误消息全部一致

#### Scenario: 公开声明零变更

- **WHEN** 对比改动前后 `f_xml/src` 的 `public` 声明清单
- **THEN** 差集为空（新增的 `internal` 不计）
