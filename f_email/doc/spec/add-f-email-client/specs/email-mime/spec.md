## ADDED Requirements

### Requirement: Content-Type 与 Content-Disposition 解析

`ContentType.parse` SHALL 支持带引号参数（含 `\"` 转义）、参数间注释、分号在引号内不切分；
类型与子类型 MUST 统一小写后比较，参数名小写、参数值保留原样。缺失 `Content-Type` 时
MUST 默认 `text/plain; charset=us-ascii`；缺失 `Content-Transfer-Encoding` 时 MUST 默认 `7bit`。
未知类型 MUST 保留原样并按 `application/octet-stream` 处理正文。

#### Scenario: 引号内分号

- **WHEN** 解析 `Content-Type: application/octet-stream; name="a;b.bin"`
- **THEN** 参数 `name` 的值为 `a;b.bin`，不会被切成两个参数

#### Scenario: 缺失头

- **WHEN** 解析一个没有 `Content-Type` 的 part
- **THEN** `contentType` 为 `text/plain`，`charset()` 返回 us-ascii 对应的字符集

### Requirement: RFC 2231 参数解析与生成

参数解析 SHALL 同时接受 `name*=charset'lang'value`、续行 `name*0*`/`name*1*` 与
旧客户端的 `name="=?UTF-8?B?...?="`，优先级为 `name*` > 续行 > `name` > RFC 2047。
续行 MUST 按数字顺序拼接后再 percent-decode，缺号时停止并记告警。生成时非 ASCII
MUST 使用 `name*=UTF-8''...`，纯 ASCII MUST 使用 `name="..."`，MUST NOT 用 RFC 2047 生成参数。

#### Scenario: 单段扩展值

- **WHEN** 解析 `filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf`
- **THEN** 得到文件名 `中文.pdf`

#### Scenario: 续行拼接

- **WHEN** 解析 `filename*0*=UTF-8''%E4%B8%AD; filename*1*=%E6%96%87.pdf`
- **THEN** 得到文件名 `中文.pdf`

#### Scenario: 生成不用 RFC 2047

- **WHEN** 用文件名 `中文.pdf` 生成 `Content-Disposition`
- **THEN** 输出包含 `filename*=UTF-8''` 而不含 `=?`

### Requirement: 传输编码

系统 SHALL 支持 `7bit`/`8bit`/`binary`/`quoted-printable`/`base64` 五种传输编码的编解码。
QP 编码 MUST 把 `=` 编为 `=3D`、行尾空格与制表符编为 `=20`/`=09`、十六进制大写、
每行不超过 76 字符且软换行 `=\r\n` 不落在 `=XX` 中间。base64 编码 MUST 每 76 字符插入
`\r\n` 并补齐 padding；解码 MUST 忽略空白并容忍缺失 padding。
非法序列在宽松模式下 MUST 原样保留并记告警，严格模式下抛 `MimeException`。

#### Scenario: QP 行尾空格

- **WHEN** 编码一行结尾带空格的文本
- **THEN** 该空格被编码为 `=20`，解码回来后与原文字节一致

#### Scenario: QP 软换行跨块

- **WHEN** `=3D` 被分块边界切开（第一次读到 `=3`）
- **THEN** 解码器保留残留字节，下一次读入后正确还原为 `=`

#### Scenario: base64 缺 padding

- **WHEN** 解码 `SGVsbG8`（无 `=`）
- **THEN** 返回 `Hello`，不抛异常

### Requirement: RFC 2047 encoded-word

`EncodedWord.decode` SHALL 支持 `=?charset?B?...?=` 与 `=?charset?Q?...?=`；Q 编码中
`_` MUST 还原为空格。相邻 encoded-word 之间的空白 MUST 丢弃后再拼接，普通文本的空白 MUST 保留。
charset 未知时 MUST 走字符集回退链，仍失败则原样保留整段并记告警。

`EncodedWord.encode` MUST 只在确实需要时编码（含非 ASCII 或控制字符），
每个 encoded-word MUST 不超过 75 字符，多个词之间用 `CRLF + 空格` 折行，
MUST NOT 在多字节字符中间切断。

#### Scenario: 主题被拆成两段

- **WHEN** 解析 `=?UTF-8?B?5Lit?= =?UTF-8?B?5paH?=`
- **THEN** 结果为 `中文`，两段之间的空格被丢弃

#### Scenario: 混排保留普通空白

- **WHEN** 解析 `hello =?UTF-8?Q?world?= again`
- **THEN** 结果为 `hello world again`

#### Scenario: 不切断多字节字符

- **WHEN** 对一长串中文主题调用 `encode(text, maxWordLength: 75)`
- **THEN** 每个 encoded-word 解码后都是完整字符，拼接结果与原文相等

### Requirement: multipart 解析

`MimeParser` SHALL 用字节级 boundary 扫描解析 multipart：boundary 只在行首有效
（`CRLF + "--" + boundary`），并接受正文偏移 0 即为 boundary 的空 preamble 情形；
结束 boundary `--boundary--` 之后允许空白再 CRLF。preamble 与 epilogue MUST 保留但不解释。
嵌套 part MUST 按各自 `Content-Type` 递归解析，`message/rfc822` 解析为完整 `MailMessage`，
`multipart/digest` 的子 part 默认按 `message/rfc822` 处理。
缺失结束 boundary 时宽松模式 MUST 把剩余字节作为最后一个 part 并记告警，严格模式抛 `MimeException`。

#### Scenario: 正文里的伪 boundary

- **WHEN** 某个 part 的正文中间出现 `--boundary` 子串但不在行首
- **THEN** 解析器不在此处切分

#### Scenario: 缺失结束 boundary（宽松）

- **WHEN** 报文只有 `--b` 开头的分隔而没有 `--b--`
- **THEN** 最后一个 part 包含剩余全部字节，且产生一条告警

#### Scenario: 嵌套转发

- **WHEN** 解析一个 `multipart/mixed` 内含 `message/rfc822` 的邮件
- **THEN** 该 part 的 body 为 `Embedded`，可继续取到内层邮件的主题

### Requirement: 流式解析与两种模式

解析器 SHALL 提供 `parse`（建 `MailMessage` 树）与 `walk`（不建树、分块回调）两种模式。
`walk` 的 `onBodyData` 收到的字节 MUST 已做 CTE 解码、MUST NOT 做字符集解码。
`MimeAction.SkipPart` MUST 跳过当前 part 正文与子树但仍回调 `onPartEnd`，
`MimeAction.Stop` MUST 终止整个解析。任意一次 `read` 只返回 1 字节时，两种模式都必须产生正确结果。

#### Scenario: 1 字节流

- **WHEN** 底层 `InputStream` 每次 `read` 只返回 1 字节
- **THEN** `parse` 与 `walk` 的结果与一次性读入完全一致

#### Scenario: SkipPart 保持栈平衡

- **WHEN** visitor 在某个 part 上返回 `SkipPart`
- **THEN** 该 part 的正文与子树不再回调，但仍收到该 part 的 `onPartEnd`

### Requirement: 生成

`MimeWriter` SHALL 流式写出报文并提供 `bytesWritten()`。编码选择规则为：正文全部
`<= 0x7F` 且行 `<= 998` 时用 `7bit`；文本且非 ASCII 字节占比低于 20% 时用
`quoted-printable`；其余用 `base64`；服务器支持 `8BITMIME` 且 `allow8Bit=true` 时文本可用 `8bit`。
`forceEncoding` MUST 是硬约束，与内容冲突时直接抛 `MimeException`，MUST NOT 静默换编码。
写入前 MUST 把 `\r\n`、裸 `\n`、裸 `\r` 统一为 CRLF。头部折行 MUST 不在引号字符串内部、
不在 encoded-word 内部断开，续行以单个空格开头，每行不超过 78 octets。
`MimeWriter` MUST 原样写出 `Bcc`（是否删除由 SMTP 客户端决定）。

#### Scenario: forceEncoding 冲突

- **WHEN** 指定 `forceEncoding = SevenBit` 但正文含 8 位字节
- **THEN** 抛 `MimeException`，不产生任何输出

#### Scenario: 生成结果可读回

- **WHEN** 用 `MimeWriter` 写出一封含中文主题、HTML 正文与一个二进制附件的邮件，
  再用 `MimeParser` 读回
- **THEN** 主题、HTML 正文、附件字节与原始输入完全一致

#### Scenario: 保留 Bcc

- **WHEN** 直接用 `MimeWriter` 写一封带 `Bcc` 的邮件
- **THEN** 输出中包含 `Bcc` 头

### Requirement: 字符集解析与回退链

`CharsetResolver` SHALL 内置邮件常见字符集别名表（`us-ascii`/`ascii`、`utf8`、
`gb2312`/`gbk`/`cp936`、`gb18030`、`big5`/`cp950`、`iso-8859-1`/`latin1`、
`shift_jis`/`sjis`/`cp932`、`euc-kr`/`ks_c_5601-1987`、`iso-2022-jp`）。
回退链 MUST 为：声明且可解析 → 使用；声明缺失 → `defaultCharset`；声明未知 →
依次尝试 UTF-8 → GB18030 → WINDOWS_1252；全部失败 → WINDOWS_1252 逐字节映射并置 `lossy=true`。
实际使用的字符集与是否损失 MUST 可通过 `charsetUsed` / `charsetLossy` 读取。

#### Scenario: 声明 gb2312 实为 GBK

- **WHEN** 解析 `charset=gb2312` 但正文含 GBK 扩展字符
- **THEN** 文本正确解码，`charsetUsed` 反映实际字符集，`charsetLossy` 为 false

#### Scenario: 未知字符集

- **WHEN** 解析 `charset=x-unknown-42` 的正文
- **THEN** 不抛异常，按回退链产出文本，并标记实际使用的字符集

### Requirement: 解析限制

解析器 SHALL 强制以下默认上限并在超限时抛 `MailLimitException`：
头部总字节 256 KB（`Header`）、单个头部行 64 KB（`Header`）、part 数量 1000（`Parts`）、
嵌套深度 32（`Depth`）、`maxBodyBytes` 非 0 时的解码后正文（`Body`）、
非法 boundary 长度（1–70，超范围视为普通文本并告警）。

#### Scenario: 嵌套炸弹

- **WHEN** 解析一个 100 层嵌套的 multipart
- **THEN** 抛 `MailLimitException(kind=Depth)`

#### Scenario: part 数量炸弹

- **WHEN** 解析一个含 100000 个 part 的 multipart
- **THEN** 抛 `MailLimitException(kind=Parts)`，不继续分配内存

### Requirement: 临时文件暂存

超过 `spoolThreshold` 的叶子正文 SHALL 落到临时文件。临时目录解析顺序 MUST 为：
`spoolDir` → 环境变量 `TMPDIR` → 系统临时目录 → 当前工作目录下的 `.fountain_tmp/`。
临时文件名 MUST 由内部随机生成且 MUST NOT 使用附件 `filename`；创建权限 MUST 为 0600；
`BodySource.close()` MUST 删除文件。四处都不可用时 MUST 抛 `MimeException`。

#### Scenario: 附件名不影响路径

- **WHEN** 附件的 `filename` 为 `../../../etc/passwd`
- **THEN** 临时文件名与它无关，落盘位置仍在临时目录内

#### Scenario: 大附件落盘

- **WHEN** 解析一个解 CTE 后 2 MB 的附件（`spoolThreshold` 默认 1 MB）
- **THEN** 该 part 的 body 为 `Data(FileBodySource)`，文件权限为 0600
