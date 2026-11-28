# f_email 模块审查报告

> **模块第 4/6 部分**（本报告只覆盖 `files/f_email.part4.txt` 列出的 20 个文件：`src/imap` 的 `ImapSpecialUse` / `ImapUtf7` / `ImapValue` / `Imap_test`，`src/mime` 的 `Boundary` / `MimeOptions` / `MimeParser` / `MimeStreamBuffer_test` / `MimeWriter` / `Mime_test`，`src/model` 的 `Base64Codec` / `BodySource` / `CharsetResolver` / `Codec_test` / `ContentType` / `ContentType_test` / `EncodedWord` / `Envelope` / `HeaderMap` / `HeaderMap_test`。其余 52 个 `.cj` 与 16 个 `.md` 由第 1/2/3/5/6 部分产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（本部分 20 个源文件，全部 `.cj`；本部分不含 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：MIME 编解码与地址解析正确性、注入与安全、资源与连接、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 4/6 部分）

---

## 发现

### [严重][存量] #1 multipart 首个 boundary 行不认「传输填充」，合法邮件的第一段（或整封）被当成 preamble 静默丢弃

- **位置**：`f_email/src/mime/Boundary.cj:287-316`（关键对比：`297` 行 `text == "--${boundary}"`、`305` 行 `text == "--${boundary}--"`；同一文件 `243-248` 行的 `atBoundary` 却明确允许行尾空白）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 语义与实现不符」、§2（同一判定两套规则）；契约源：设计文档 §5.4 第 3 点与 `atBoundary` 自己的实现
- **证据**：静态确定 —— `skipToFirstBoundary` 对整行做**字符串全等**比较，边界行只要带一个行尾空格/制表符就不匹配；而 `atBoundary`（`244-248`）用 `next == b'\r' || b'\n' || b'-' || b' ' || b'\t'` 显式接受传输填充。RFC 2046 §5.1.1 的 delimiter 行允许 `transport-padding`（LWSP），设计文档 `doc/f_email设计文档.md:906` 也写明「结束 boundary 是 `--boundary--`，后面可以有空白再 CRLF」。
- **描述**：`--b␠\r\n` 这类边界行（规范允许、部分客户端/MTA 会生成）在 `skipToFirstBoundary` 里不匹配，于是继续按「preamble 行」读取：
  1. 只有首个 boundary 带空白时，第一个 part 的头部与正文全部进入 `preamble`，`parse` 返回的 `parts` 从第二个 boundary 开始 —— **第一个 part 静默消失**；
  2. 所有 boundary 行都带空白时，读到 EOF 也没匹配，`closed = true`、`parts = []`、`preamble` = 整封正文 —— `MailMessage.text()` / `attachments()` 全部返回空，**整封邮件看起来是空的，且不抛异常**。
- **建议**：把「判断一行是否是 boundary」抽成一个函数（例如 `matchBoundaryLine(line) -> ?closing`），`skipToFirstBoundary`、`readEpilogue` 与 `atBoundary` 共用；判定时 `trimAsciiEnd` 后再比较，并保留「`--b--` 之后只允许空白」的规则。补用例：preamble 之后的 `--b ` + 正文 + `--b-- `，断言 `text()` 仍在。

### [严重][存量] #2 preamble / epilogue 无上限物化，且用 `out = out + item` 逐行拼接（O(n²)），完全绕过 `maxBodyBytes`

- **位置**：`f_email/src/mime/Boundary.cj:287-316`（`skipToFirstBoundary` 收集 `preambleLines`）、`324-336`（`readEpilogue`）、`339-345`（`joinLines` 的 `out = out + item + "\n"`）；调用点 `f_email/src/mime/MimeParser.cj:140`、`248`、`159`、`269`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「一次性物化 / 平方级增长 / 无拒绝路径」、§6.4「循环内字符串 `+`」、§11「与配置上限契约不符」
- **证据**：静态确定 —— 两条路径都只有「按行读到 EOF → 全量装进 `ArrayList<String>` → `joinLines` 拼成一个 `String`」，中途不查任何字节上限；`MimeParseOptions.maxBodyBytes`（默认 `0`，`MimeOptions.cj:48`）只在 `readLeaf`（`MimeParser.cj:318-321`）与 `streamLeaf`（`191-193`）检查，**preamble/epilogue 从不经过它**，所以即使调用方设了 `maxBodyBytes` 也拦不住。`joinLines` 每行做一次整串复制，n 行总复制量 = Σ 前缀长度 ≈ O(n²)。
- **描述**：触发条件极简 —— 头部写 `Content-Type: multipart/mixed; boundary=b`，正文里只要不出现 `--b` 行（或全部带行尾空白，见 #1），整封正文就变成 preamble。以 100 MB、每行 10 字节计：`preambleLines` 约 1000 万条 `String`（每条约 40 字节对象头 + 内容 ≈ 数百 MB），`joinLines` 需要复制 ≈ 5×10¹⁴ 字节 —— 实际表现为「解析线程占满 CPU 且堆持续上涨」，默认配置下先 OOM 再谈耗时。epilogue 更隐蔽：`parse` 每解析完一个 multipart 都无条件调用 `readEpilogue()`（`159` / `269`），正常邮件只要在结束 boundary 后塞大段字节同样命中。
- **建议**：preamble/epilogue 只保留有限前缀（例如 4 KB，超出截断并置标志），或提供 `keepPreamble: Bool = false` 开关默认丢弃；收集阶段就累加字节数并与 `maxBodyBytes` 共享一个上限；拼接改用 `StringBuilder`，或者干脆只在需要时 `joinLines`。同时把「preamble/epilogue 长度」计入 `MailLimitException`（`LimitKind.Body`）以便调用方观测。

### [严重][存量] #3 `PartStream.read` 把连续的 CR/LF 全部堆在 `pending`，纯空行正文可以绕过所有上限把堆撑爆

- **位置**：`f_email/src/mime/Boundary.cj:158-201`（`177-180` 收 `\r` 进 `pending`、`181-185` 收 `\n` 进 `pending` 后 `continue`；只有 `186` 行读到**非 CR/LF** 字节时才 `flushPending`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器 / 按不可信长度累积」、§11「边界未处理」
- **证据**：静态确定 —— 循环条件是 `while (out < target.size && !done)`，而 `pending.add(...) + continue` 不增加 `out`，因此一整个 part 正文若只由 `\r\n` 组成，`read()` 会一直读到 boundary/EOF 才返回；这期间 `pending`（`ArrayList<Byte>`）累积了**该 part 的全部字节**，且扩容是倍增的（峰值 ≈ 2 倍）。
- **描述**：攻击/异常输入 = `Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\n` + 500 MB 的 `\r\n`。`readLeaf` 侧看到的是 `decodedStream.read(chunk)` 长时间返回 0（`total` 始终 0），`maxBodyBytes`、`spoolThreshold`、`inlineTextLimit` 全部不触发，堆先涨到 GB 级。这不是「正文大所以要占内存」（正文本应流式），而是**输出为 0 时仍然按输入大小累积**，与 `ByteSource` 注释里「不能把整段正文读进内存」的承诺相反。
- **建议**：`pending` 只用于延迟判断「这一行是不是 boundary」，因此最多需要保留「当前行已读的 CR/LF 数」而不是字节内容：连续空行可以直接输出前一行留下的 CRLF（或统计计数，等确认非 boundary 后按需补写）。若不想改状态机，至少在 `pending.size` 超过一个阈值（如 8 KB）时立即 flush 到 `target`/下游，把内存与 `target.size` 绑定。补用例：正文为 1 MB 纯 `\r\n`，断言 `getAllocatedHeapSize()` 峰值不超过常量级。

### [一般][存量] #4 头部折行只在空格断行，无空格时把 token 从中间硬断并靠「折叠空格」还原 —— 字段值被插入空格；998 硬上限从未校验

- **位置**：`f_email/src/mime/MimeWriter.cj:291-386`（`336` 行只在 `b' '` 记 `lastBreak`；`339-347` 行 `lastBreak <= 0` 时 `lastBreak = options.maxLineLength` 硬断；`348-370` 行切分时在续行前补一个空格）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与规格不符」、§2（同一 `998` 常量两份）；契约源：设计文档 §5.6「头部折行」、`HeaderMap.cj:34` 的 `MAX_LINE_OCTETS = 998`（`src/` 内零引用）
- **证据**：静态确定 —— 只有空格会更新 `lastBreak`（逗号/分号断点未实现，设计文档 `doc/f_email设计文档.md:995` 要求「在空白、逗号、分号处断行」）；超宽且无空格时 `lastBreak = maxLineLength` 落在任意字节上，`separator = 0`，续行以 `' '` 开头，于是展开（RFC 5322 unfolding 只删 CRLF、保留 WSP）后的字段值比原值**多出一个空格**。
- **描述**：`Mime_test.cj:86-95` 的 `headersFoldWithinLimit` 正好构造了这种输入（120 个 `x` 的 Subject），但它只断言每行 ≤ 78，没有断言往返值 —— 实际写出的是 `Subject: xxx…(78)\r\n xxxx…`，收件端 `subject()` 得到 121 个字符（中间多一个空格）。对 `Message-ID` / `References` / 长 URL / `DKIM-Signature` 一类「不能插入空白」的字段，这等于改写了协议值。另外「超 998 抛 `MailLimitException`」在设计文档里是硬契约，实现里没有任何 998 检查（唯一一处 998 是正文的 `isSevenBitSafe`，`169` 行），超长 header name（无长度校验）可以写出 >998 的行。
- **建议**：断点集合按文档补上 `,` `;`（引号内除外）；确实没有合法断点时，优先抛 `MailLimitException(LimitKind.Line, 998, current.size)` 而不是改写 token —— 让调用方决定要不要用 encoded-word；折行宽度判断改用 `HeaderMap.MAX_LINE_OCTETS`（同时也消掉 #18 里重复的 998 字面量）。补一条往返用例：120 字符无空格 Subject，断言 `parse(write(m)).subject() == 原值`。

### [一般][存量] #5 流式正文只按前 64 KB 采样决定 `Content-Transfer-Encoding`，后续字节的 8 位/超长行不再校验 —— 头部声明与实际内容不符

- **位置**：`f_email/src/mime/MimeWriter.cj:90-113`（`95` 行 `readUpTo` 只读一块、`101` 行 `chooseEncoding(sample, isText)`、`104-111` 行把余下字节原样交给编码器）、`159-175`（`isSevenBitSafe` 的 `≤998` 与 8 位检查只作用于采样）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」；设计文档 `doc/f_email设计文档.md:984-990` 的判定表写的是「正文是 7bit 安全（**全部** ≤0x7F 且行 ≤998）→ 7bit」
- **证据**：静态确定 —— `PartBody.Data` 走 `writeLeafStream`，`sample` 恒为前 `STREAM_BUFFER_BYTES = 65536` 字节；`chooseEncoding` 之后 `openEncoder` 对 `_` 分支（7bit/8bit/binary）只做 CRLF 归一（`199` 行 `CrlfNormalizingOutput`），不再有安全判定。
- **描述**：>64 KB 的 `PartBody.Data`，只要前 64 KB 「看起来是 7bit」，就会被标成 `Content-Transfer-Encoding: 7bit` 并在后面原样写出 8 位字节（甚至 `0x00`）。接收端按 7bit 处理（部分 MTA 会剥掉高位或拒绝），表现为附件损坏 / 正文乱码；`binary` 附件（CSV、日志、以 ASCII 开头的归档）最容易命中。设计文档的「全部」是实现没有做到的。
- **建议**：对 `PartBody.Data` 二选一：(a) 采样不足以判定时保守选 `base64`（除 `forceEncoding` 外不再输出 7bit）；(b) 先用 `BodySource.size` 与 `reusable` 判断能否两遍扫描，`reusable == true` 时先把整段扫一遍再决定编码。两种做法都要把「样例判定」写进 `MimeWriteOptions` 的注释，避免调用方以为 7bit 已被全文校验。

### [一般][存量] #6 `writeHeaders(withTransferEncoding(...))` 直接改调用方的 `HeaderMap` —— 序列化有副作用，复用同一封信时会写出与正文不一致的 CTE

- **位置**：`f_email/src/mime/MimeWriter.cj:177-182`（`headers.set("Content-Transfer-Encoding", ...)` 成功即改原对象）、调用点 `86` / `102`；`MimePart.headers` 是 `let`（`MimePart.cj:65`），`HeaderMap.set` 原地修改（`HeaderMap.cj:86-102`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符 / 副作用」、§12.1「共享可变状态无保护」
- **证据**：静态确定 —— `withTransferEncoding` 返回的就是入参 `headers` 本身，`set` 只在「不存在同名项」时写入；因此写过的 `MailMessage` 被永久打上第一次选择的编码。
- **描述**：`MimeWriter` 的类注释（`23-30`）把「保存草稿」当主要用途，而草稿保存后往往还要再发送一次。第二次用不同 `MimeWriteOptions`（例如首次 `allow8Bit=false` 得 QP，重发时 `allow8Bit=true`）写同一棵树时，`withTransferEncoding` 看到已有 CTE 就不覆盖，正文却按新策略编码 —— **`quoted-printable` 头 + `8bit` 正文**，收件端解码失败。`MimePart.cj:57-63` 又明确警告「解析完成后不要再改 headers」，序列化器自己就在违反这条。并发角度：同一 `MailMessage` 被两个线程同时 `write` 时，两边都会对同一个 `ArrayList<(String,String)>` 做 `set`（无锁），属数据竞争（仓内当前没有这种调用，故按一般计）。
- **建议**：`writeHeaders` 接收 `(name, value)` 覆盖项而不是改 `HeaderMap`；或复制一份头部（`HeaderMap` 增加 `copy()`）再写。若保留原地修改，至少在类注释里写明「`write` 会修改入参」，并把 CTE 覆盖改成无条件 `set`（结果一致但至少不会出现「头旧体新」）。

### [一般][存量] #7 `MimeWriter` 丢弃 `Multipart.preamble` / `epilogue`，与解析侧「保留」不对等 —— 保存草稿丢内容

- **位置**：`f_email/src/mime/MimeWriter.cj:75-82`（只写 `--boundary`、各 part 与 `--boundary--`）；对照 `f_email/src/mime/MimeParser.cj:269-277`（解析时填 `preamble` / `epilogue`）与 `Mime_test.cj:190-207`（用例断言两者被保留）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 数据丢失」；设计文档 `doc/f_email设计文档.md:886-887`「preamble / epilogue 保留但不解释」
- **证据**：静态确定 —— `writeMultipart(multipart)` 的签名拿到了整个 `Multipart`（含两个字段），但函数体只读 `parts` 与 `boundary`，`multipart.preamble` / `multipart.epilogue` 在 `src/` 内零读取。
- **描述**：`parse` → `write` 往返后，preamble/epilogue 静默消失。对「保存草稿」（类注释明确的目标场景）来说是不可见的数据丢失：某些客户端把签名/免责声明放在 preamble 或 epilogue 里；某些工控/老系统把校验信息放 epilogue。
- **建议**：`writeMultipart` 在首个 `--boundary` 之前写 `preamble`（无则 `""`），在结束 boundary 之后写 `epilogue`；写之前统一 CRLF 归一。若判定「不应保留」，就把 `Multipart` 的两个字段注释改成「仅供解析侧读取，生成侧忽略」，并让 `Mime_test` 的用例显式断言丢弃，避免两处语义各说各话。

### [一般][存量] #8 `parse` 中途失败时不清理已落盘的临时文件（含 `LeafBuffer.write` 未纳入 `discard`）

- **位置**：`f_email/src/mime/MimeParser.cj:291-338`（`317` 行 `buffer.write(slice)` 在 `try` 之外、只有 `304-309` 的 `read` 被 `catch` 包裹）；清理只有 `buffer.discard()`（`307` / `319`）与 `BodySource.close()`（`BodySource.cj:112-122`，无析构）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称 / 异常跳过释放」、§5「长期持有（临时文件）」
- **证据**：静态确定 —— `parseEntity` / `walkEntity` 递归中途抛错（`LimitKind.Depth` / `Parts` / `Body`、`MimeException("multipart 缺少结束 boundary")`、`String.fromUtf8` 见 #11）时，之前已经 `spill()` 成功并返回 `PartBody.Data(FileBodySource(path, owned: true))` 的叶子只存在于即将被丢弃的局部树里；`parse`（`61-67`）没有任何 `try/finally`，`FileBodySource` 也没有析构函数兜底 ⇒ 文件留在 `spoolDir` 直到进程重启。
- **描述**：两条泄漏路径：
  1. 后续 part 触发上限 → 前面所有落盘附件全部残留；
  2. `LeafBuffer.write` 自身抛错（磁盘满、`File` 打开失败）时 `readLeaf` 的 `catch` 覆盖不到它 —— 此时 `spill()` 已 `Spool.createFile` 建了文件（`492-502`），`file`/`path` 字段已赋值但异常向上冒，没人调 `discard()` ⇒ 既泄漏文件句柄也泄漏磁盘文件。
  常驻进程里反复收这类邮件（攻击者只要让第 1001 个 part 超限）会把 `spoolDir` 撑满，属于可被外部输入驱动的资源耗尽。
- **建议**：`parse`/`walk` 用 `try { ... } catch (e) { cleanup(state); throw e }` 把「已建立的 `FileBodySource`」集中登记（`ParseState` 里加一个 `ArrayList<FileBodySource>`），失败时逐个 `close()`；把 `buffer.write(slice)` 也放进 `readLeaf` 的 `try`；`FileBodySource` 增加析构（`~init()`）在 `owned && !closed` 时删文件，作为最后一道兜底。

### [一般][存量] #9 `walkEntity` 与 `parseEntity` 是两份逐行复制的实现，默认值已经漂移

- **位置**：`f_email/src/mime/MimeParser.cj:94-172`（walk 版）vs `213-289`（parse 版）；配套的 `streamLeaf`（`174-203`）vs `readLeaf`（`291-338`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 跨层复制的重复逻辑」「近似重复导致行为漂移」
- **证据**：静态确定（逐行对齐后差异点如下）：
  - 深度/parts 计数、`multipart` 循环、`stream.closing || !stream.sawBoundary` 收尾、`scanner.readEpilogue()`、`endPart` 与 `onPartEnd` 一一对应，属同一状态机的两份抄写；
  - **Content-Type 默认值不同**：walk 用 `ContentType.parse(headers.get("Content-Type") ?? "text/plain")`（`124` 行，无 charset 参数），parse 用 `part.contentType`（`237` 行 → `MimePart.cj:82-86` → `ContentType.defaultText()`，即 `text/plain; charset=us-ascii`）。当前 walk 不做字符集解码，所以还没造成可见错误，但只要后续给 walk 加上 charset 处理就会分叉；
  - `readLeaf` 有 `spoolThreshold` / `inlineTextLimit` 分流与 `markCharset`，`streamLeaf` 没有；`maxBodyBytes` 在两处的检查时机不同（walk 按解码累计、parse 按 `buffer.total`，`buffer.total` 与解码累计同源，暂无差异）。
- **描述**：这是本模块最容易在后续改动中「改一处忘一处」的地方：`MimeAction` 的语义（`SkipPart` 不读、`Stop` 抛内部异常）已在两份里各写一遍；`strict` 缺边界判定也各写一遍。任何 `maxDepth` / `maxParts` / 缺边界策略的调整都必须同时改两处。
- **建议**：把「读头 + 判定 Content-Type + 递归 multipart + 叶子交给 sink」抽成一个泛型骨架（`sink` 抽象成 `onStart/onData/onEnd`，`parse` 的实现把块攒成 `LeafBuffer`、`walk` 的实现直接回调），两份只保留「块去哪」的差异；`ContentType` 默认值统一走 `MimePart.contentType`。至少要给两份实现写一组共享用例（同一封邮件分别 `parse` 与 `walk`，比对 `walk` 收到的字节与 `parse` 的 `Data`/`Text`）。

### [一般][存量] #10 叶子正文没有「全封邮件」级的聚合内存上限：1000 个 part × 1 MB 可以全部留在堆里

- **位置**：`f_email/src/mime/MimeParser.cj:291-338`（`324-337` 决定 `Text` / `MemoryBodySource`）、`429-503`（`LeafBuffer` 每实例最多攒 `spoolThreshold` 字节）；默认值 `f_email/src/mime/MimeOptions.cj:44-50`（`maxParts = 1000`、`spoolThreshold = 1 MB`、`maxBodyBytes = 0`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器 / 最坏输入规模 × 单元素内存 ≈ 峰值」（要求量化）
- **证据**：静态确定（算术可复核）—— `LeafBuffer.write` 在 `total > limit` 前不会落盘（`443-455`），`readLeaf` 对未落盘的叶子返回 `PartBody.Data(MemoryBodySource(buffer.bytes()))`，`bytes()` 是一次 `toArray()` 复制（`457-459`）。因此单叶子堆内保留 ≤ `spoolThreshold` = 1 MB；`state.parts` 上限 1000 ⇒ **单封邮件最多约 1 GiB 常驻**（峰值还要加当前叶子最多 2 倍复制），而 `maxBodyBytes` 默认 `0` = 不限。
- **描述**：`maxParts` 与 `spoolThreshold` 各自都有上界，但两者相乘没有上界；对邮件网关/收件箱扫描这类「不可信输入 + 常驻进程」的场景，1 GiB 已经足以在小规格容器上 OOM。`MimePart.text()` 在 `Data` 上还会再 `readAll` 一次（`MimePart.cj:133-145`），把单叶子再放大一倍。
- **建议**：给 `MimeParseOptions` 增加 `maxInlineBytes`（全封邮件内存态正文总量，超出后强制 `spill`），或把 `spoolThreshold` 改成「按剩余预算动态收缩」：`min(spoolThreshold, maxInlineBytes - 已用)`。默认值建议 `maxInlineBytes = 4–8 MB`，与 `maxHeaderBytes` 同一量级；同时把「已用」暴露成 `MailLimitException(LimitKind.Body)` 便于观测。

### [一般][存量] #11 preamble / epilogue 的按行读取路径与「宽松解析」目标冲突：非 UTF-8 直接抛异常、单行 8192 硬上限且按 `Header` 报错

- **位置**：`f_email/src/mime/Boundary.cj:296` 与 `331`（`String.fromUtf8(line.getOrThrow())` 无兜底）、`290` 与 `327`（`readLine(8192)` 硬编码，超限抛 `MailLimitException(LimitKind.Header, 8192, size)` 见 `112-126`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 语义与命名不符」、§2（同一模块内两种字节转字符串策略）
- **证据**：静态确定 —— `String.fromUtf8` 是**校验版**（非法 UTF-8 抛异常，`md/doc/cjapi/core.md:80-81` 明确另有 `fromUtf8Unchecked`）；同模块 `MimeParser.bytesToString`（`399-409`）已经写了「try `fromUtf8` / 失败按字节映射」的兜底，preamble 路径没用它。8192 也与 `maxHeaderLine`（默认 64 KB，`MimeOptions.cj:45`）无关 —— 报出来的类别是 `Header`，调用方会以为是头部超限。
- **描述**：preamble 是「客户端写给用户看的说明文字」，编码完全不受约束（GBK 提示语、二进制垃圾都见过）。默认 `strict = false` 的语义是「尽量把邮件读出来」，但这里一个非 UTF-8 字节就让整封解析失败；反过来 8192 的硬上限又会让「一行很长的 preamble」直接抛限错。两者都与「preamble 不影响正文解析」的定位不符。
- **建议**：preamble/epilogue 用 `MimeParser.bytesToString` 同样口径转换；行上限改为 `options.maxHeaderLine`（或单独的 `maxPreambleLine`，默认 64 KB），`LimitKind` 增加 `Preamble`/`Epilogue` 或复用 `Body`。更彻底的做法是按 #2 的建议「只保留有限前缀」，连行长问题一起消失。

### [一般][存量] #12 `MimeWriteOptions.boundaryPrefix` 定义了但从未被读取 —— 配置项没有接线

- **位置**：`f_email/src/mime/MimeOptions.cj:80` / `90` / `98`（声明、默认值 `"=_fountain_"`、赋值）；每次 `MimeWriteOptions(...)` 都可以传，但 `src/` 内零读取
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「死配置字段」、§14「接线缺失」；承诺源：设计文档 `doc/f_email设计文档.md:971`（`public let boundaryPrefix!: String = "=_fountain_"`）与 `README.md:267`（`MimeWriteOptions`：`boundaryPrefix`）
- **证据**：静态确定 —— `grep -rn "boundaryPrefix" --include=*.cj f_email/src` 只命中定义与赋值三行；boundary 实际由 `MailMessageBuilder.newBoundary()`（`MailMessage.cj:310-312`）硬编码 `"=_fountain_" + randomLowerHex(32)` 生成，与 writer 的选项无关。
- **描述**：调用方按文档设置 `boundaryPrefix: "----=_Part"` 后行为完全不变（仍在 `Content-Type` 里看到 `=_fountain_`），排查时会误以为是别的环节覆盖。同时「生成侧可配置前缀」这个能力事实上不存在。
- **建议**：把它接到真正生成 boundary 的地方（`MailMessageBuilder` 需要一个 options 参数，或在 `writePart` 遇到 `Multipart` 且 boundary 为空时用 `boundaryPrefix` 生成）；短期至少删掉该字段并同步 README / 设计文档，避免「文档承诺但实现为空」。

---

### [轻微][存量] #13 `EncodedWord.encodedSize` 是死代码

- **位置**：`f_email/src/model/EncodedWord.cj:163-169`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「无调用者（private）」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜索 `encodedSize` 只命中定义行；`encode` 用的是 `qEncodedSize`（`105` 行）与内联的 `4 * ((chunkBytes + bytes + 2) / 3)`（`109` 行）。
- **描述**：方法体与 `qEncodedSize` 的前半段重复，保留只会让后来者以为它是编码宽度计算的唯一入口。
- **建议**：删除；若想保留「按字符估算宽度」的单一入口，就把 `105-119` 行的估算改为调用它。

### [轻微][存量] #14 `ByteSource.readLine` 末尾的 `return None` 不可达

- **位置**：`f_email/src/mime/Boundary.cj:134`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「不可达语句（`return` 之后的同层语句）」
- **证据**：静态确定 —— `while (true)` 循环体的每个出口都 `return`（`121` / `129` / `131`），循环外语句永远不执行。
- **描述**：不影响行为，但会掩盖「这里少了一个分支」的错觉。
- **建议**：删除该行（或用 `while (true) { ... }` 后置 `throw` 让编译器确认穷尽）。

### [轻微][存量] #15 `normalizeCrlf` 与 `CrlfNormalizingOutput.write` 是同一套换行归一的两份实现

- **位置**：`f_email/src/mime/MimeWriter.cj:217-245` 与 `428-451`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（同一状态机两份）」
- **证据**：静态确定 —— 两份都是 `pendingCr` 状态机：`\r` 挂起、`\r\n` 折叠、裸 `\n` → CRLF、EOF 时补 CRLF，逐分支等价（内存版末尾补 `\r\n`，流式版由 `finish` 之前的 `pendingCr` 在下一块或结束处理）。
- **描述**：后续若要支持 `\r` 归一策略开关或修边界 bug，必须改两处。
- **建议**：`writeEncoded` 的 `_` 分支也走 `CrlfNormalizingOutput`（经 `CollectingOutput` 收尾），删掉数组版；或把状态机抽成 `normalizeCrlf(bytes, pendingCr) -> (out, pendingCr)` 供两边共用。

### [轻微][存量] #16 `ContentType` 的 media type 切分在构造器与 `parse` 里各写一遍

- **位置**：`f_email/src/model/ContentType.cj:32-42`（`init(mediaType:)`）与 `73-82`（`parse`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「同一判定两份」
- **证据**：静态确定 —— 两处都是 `indexOf("/")` → 左 `trimAscii().toAsciiLower()`、右 `trimAscii().toAsciiLower()`，`slash < 0` 时走「整体当 type」的分支；差异仅在于 `parse` 在 `75` 行漏了 `trimAscii()`（调用方已 trim，暂无影响）。
- **描述**：属于「只改类型名」型重复；`parse` 那一份多一次 `trimAscii`，两处一旦分别演进就会产生「`ContentType("text /plain")` 与 `ContentType.parse("text /plain")` 结果不同」。
- **建议**：`parse` 只负责切分「media type 段 + 参数段」，然后统一 `ContentType(mediaType, parameters:)`；`init` 内的 `trimAscii` 保持一致。

### [轻微][存量] #17 用 `MimeAction.toString()` 做分支判定（6 处）

- **位置**：`f_email/src/mime/MimeParser.cj:113`、`116`、`118`、`195`、`198`、`206`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「仓颉语言特性 / 可读性」、§11「语义与实现不符（枚举比较写成字符串比较）」
- **证据**：静态确定 —— 都是 `action.toString() == "Stop"` / `"SkipPart"`；`MimeAction` 是 `public enum <: ToString`，`==` 直接可用。`toString()` 每次比较都分配一个 `String`，且新增枚举值时编译器不会提示遗漏分支（`match` 会）。
- **描述**：功能上等价，但既多一次分配，又让「枚举覆盖完整性」失去编译期保障 —— 本模块已经出现过 `MimeAction` 语义要在 `walk`/`parse` 两处同步的问题（#9）。
- **建议**：改成 `match (action) { case Stop => ... case SkipPart => ... case Continue => () }`；`MimeAction.toString()` 只留给日志。

### [轻微][存量] #18 `MimeWriteOptions` 的 `bodyLineLength` / `maxLineLength` 未校验，`<= 0` 时输出畸形（每个 base64 字符前插一个 CRLF）

- **位置**：`f_email/src/model/Base64Codec.cj:232-241`（`if (line == lineLength)` 在 `lineLength == 0` 时对每个字符都成立）；`f_email/src/mime/MimeOptions.cj:86-87` 没有任何校验；对照 `Base64Codec.encode`（`34-38`）在数组版里做了 `lineLength <= 0` 的保护
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」、§3「配置非法时静默产出错误数据」
- **证据**：静态确定 —— `Base64Encoder.push` 每次 `line == lineLength` 就写 `\r\n`，`lineLength = 0` 时每个字符前都写一行空行；`MimeWriter.writeLeafStream`（`197` 行）直接把 `options.bodyLineLength` 传进去，没有经过 `encode` 的保护分支。`foldHeader` 在 `maxLineLength <= 0` 时同样退化成「每字节一行」。
- **描述**：只在调用方传错参数时触发，但后果是静默产出无法解码的正文/头部，且没有异常提示。
- **建议**：在 `MimeWriteOptions.init` 里做 `require(bodyLineLength > 0 && maxLineLength > 0)`（或 `min` 钳制到 76/78 并记一条日志）；`Base64Encoder` / `Base64Codec.encoder` 内部对 `lineLength <= 0` 也做同样的保护。

---

## 优化可行性方案

> 本部分没有 `cjprof` / `cjpm bench` 基线，三条都只是「结构上可以更好」，均标 `无基线（待验证，不进 tasks）`。性能结论未测，只能作为下一轮补数据的对象。

### [CPU] #O1 base64 流式编解码「每 3 字节一组对象」：解码器每个四元组 new 一个 `ArrayList`，编码器每 3 字节 new 一个数组 + 字符串

- **现状**：`Base64Decoder.fillPending`（`Base64Codec.cj:299-335`）在 `groupSize == 4` 后 `Base64Codec.emitQuad(group, 3, pending)` 就 `return`，而 `read`（`279-295`）每轮开头 `pending = ArrayList<Byte>()` —— **每解码 3 字节分配一个 `ArrayList`（含其后备数组）**；10 MB 附件 ≈ 340 万次。`nextByte`（`355-375`）每次填充还先 `Array<Byte>(8192)` 再逐字节拷进 `inputBuffer`。编码侧 `Base64Encoder.emitThree` → `encodeUnwrapped([a,b,c])`（`228-230`）每 3 字节 new 一个数组 + `ArrayList` + `String`，`push` 再 `text.toArray()` 复制一次。
- **方案**：解码器改成「固定 3 字节输出缓冲 + 位置游标」，`read` 直接从该缓冲拷给调用方，`pending` 只保留未消费的 1–2 字节；`nextByte` 直接读进 `inputBuffer`（不再经 `tmp`）。编码器用 64 项查表把 4 个字符直接写进 `lineBuffer`，不再生成中间 `String`。
- **预期**：分配对象数从「O(解码字节数)」降到「O(1)」（结构性推论：每 3 字节 → 每块 1 次）；GC 压力与单次解码耗时下降幅度需实测，不下结论。
- **代价**：跨块 `carry` 语义要重新走一遍等价性用例（`Codec_test.cj:71-75` 的 1 字节分块、`MimeStreamBuffer_test.cj` 的 32/64/192 KB 往返）；状态字段增加，可读性略降。
- **验证**：`cjpm bench -O2`，10 MB base64 解码/编码各 100 次，记录中位耗时与 `getAllocatedHeapSize()` 增量；`cjprof` 看 `Base64Decoder.fillPending` / `Base64Encoder.push` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #O2 `readLeaf` 每个 64 KB 块复制一次、`LeafBuffer` 再逐字节 `add` 一次

- **现状**：`MimeParser.cj:313-317` 对每个解码块 `Array<Byte>(n, repeat: 0)` 后逐字节 `slice[i] = chunk[i]`，再 `buffer.write(slice)`；`LeafBuffer.write`（`443-455`）在未落盘时又 `for (b in bytes) memory.add(b)`。一次 10 MB 附件：160 个 64 KB 块 → 每块两次全量拷贝（一次显式、一次 `ArrayList` 扩容复制），外加 10 MB 的临时块数组垃圾。
- **方案**：`LeafBuffer.write(bytes: Array<Byte>, count: Int64)`（或直接收 `chunk[0..n]`，`Array` 切片本身即一次复制），内存路径用批量 `add(all: ...)`/预分配 `Array` 后按段写入；落盘路径直接 `file.write(chunk[0..n])`，省掉中间 `slice`。
- **预期**：每块少一次全量复制 + 省掉 `n` 次逐元素 `add`（结构性收益；绝对量需实测），峰值少一份 64 KB 临时数组。
- **代价**：`LeafBuffer` 的接口变更（内部类，改动面小）；`Array` 切片语义要确认是复制（若为视图需保留显式复制）。
- **验证**：`MimeStreamBuffer_test.benchStreamBuffer`（已有 `F_EMAIL_BENCH=1` 门禁，`allocPerWrite` 输出）改前/改后对比；再跑 `Mime_test.largeAttachmentIsSpooled` 保证落盘路径字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #O3 每个 part 都新建 64 KB 的 `ByteSource` 缓冲

- **现状**：`Boundary.cj:28-37` 的 `ByteSource` 构造即 `Array<Byte>(65536, repeat: 0)`；`MimeParser.parseEntity` / `walkEntity`（`228` / `110`）**每进入一个 part 就新建一个**（嵌套 part 之间层层包裹），兄弟 part 之间各自新建。1000 个 part 的邮件 ⇒ 64 MB 分配（每个 part 结束即变垃圾），深度 32 ⇒ 至少 2 MB 峰值常驻。
- **方案**：初始容量按需（例如 4 KB），`ensure(n)` 里已支持扩容（`44-51`），只需把初始数组变小；或让兄弟 part 复用同一个缓冲（`PartStream` 是顺序消费，可把 `ByteSource` 的 buffer 从父级借出）。
- **预期**：小 part 场景分配量按 16 倍下降（64 KB → 4 KB），深嵌套峰值同步下降；大附件仍按需增长到 64 KB，不增加拷贝次数（`ensure` 的倍增路径已存在）。
- **代价**：`ensure` 的扩容分支会成为常态路径（当前几乎不触发），必须回归 boundary 相关用例（`Mime_test.parsesNestedMultipart`、`tenLevelNestingIsParsed`、`slowStreamCompletesFullSession`）。
- **验证**：1k part / 10 层嵌套两种输入的 `getAllocatedHeapSize()` 峰值与 `cjprof` 分配热点；确认 `parse` 结果字节级不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `PartStream.read` 的「逐字节 `source.readByte()` + 每次 `ensure`/边界判定」是解析 10 MB 附件时的主耗时（每字节至少一次虚调用 + `peekAt` 比较） | `f_email/src/mime/Boundary.cj:158-201`、`224-249` | 自耗时占比、调用次数 | `cjprof record` 跑 `MimeParser.parse` 解析 10 MB base64 附件（`Mime_test.largeAttachmentIsSpooled` 同款输入），看 `PartStream.read` / `ByteSource.readByte` / `atBoundary` 的 self time |
| 2 | `HeaderMap` 的线性查找 + `equalName` 每次 `toAsciiUpper()` 分配，在 1000 part 邮件里占解析时间的可观比例 | `f_email/src/model/HeaderMap.cj:51-78`、`171-173`；调用点 `MimeParser.cj:124-125`、`237` | 单封 1000 part 邮件里头部查找次数与分配量 | 在 `equalName` 加计数器 + `getAllocatedHeapSize()` 差值，跑 1000 part 输入；再试「存小写键 / 逐字节比较」版本对照 |
| 3 | #O1 的「3 字节一分配」对 GC 停顿的贡献高于其对总 CPU 的贡献（即先修 GC 比修算术更值） | `f_email/src/model/Base64Codec.cj:279-295`、`232-245` | GC 次数 / 停顿时间占比 | `cjprof heap` 或分配采样，解码 50 MB base64，记录 GC 次数与 STW 总时长 |
| 4 | 每 part 64 KB 缓冲（#O3）在「万级小 part」邮件上造成明显的分配抖动 | `f_email/src/mime/Boundary.cj:30` | 分配峰值与 GC 次数 | 构造 5000 个 1 KB part 的邮件，`getAllocatedHeapSize()` 峰值 + GC 次数，改初始容量后对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/src/imap/ImapSpecialUse.cj` | .cj | ✅ | `SpecialUse.parse` / `specialUseOf` / `indexBySpecialUse` 逻辑正确；用 `Other.toString() == ""` 当「未识别」哨兵（可读性隐患，未单列）；`indexBySpecialUse` 的 `seen` 线性扫描键空间 ≤ 7，不计低效 |
| 2 | `f_email/src/imap/ImapUtf7.cj` | .cj | ✅ | `decode` 的宽容/严格两态与 RFC 3501 §5.1.3 示例一致（`Imap_test.cj:159-191`）；`isAscii` 在仓内零引用（`public` 成员，按硬原则一不判死代码）；`strict` 下 `isBase64Rune` 仍接受非规范的 `/`（轻微，未单列） |
| 3 | `f_email/src/imap/ImapValue.cj` | .cj | ✅ | `text` / `items` / `number` / `toString` 均为接口实现或对外 API；`joinValues` 仓内零引用（`public` 顶层函数，不判死代码，仅记「对外 API，仓内无引用」）；`number()` 依赖 `ImapParser.parseNumber` 的溢出行为，属他部分 |
| 4 | `f_email/src/imap/Imap_test.cj` | .cj | ✅ | 覆盖 token 化、literal 长度、慢流（1 字节读）、literal 超限关连接、BYE、APPEND 的 `LITERAL+` 两态；未发现问题 |
| 5 | `f_email/src/mime/Boundary.cj` | .cj | ✅ | 见 #1（首边界不容忍空白）、#2（preamble/epilogue 无上限 + O(n²)）、#3（CRLF 全量进 `pending`）、#11（`fromUtf8` / 8192）、#14（不可达 `return`）；`ensure` 的倍增/搬移逻辑（`40-73`）正确 |
| 6 | `f_email/src/mime/MimeOptions.cj` | .cj | ✅ | 见 #12（`boundaryPrefix` 未接线）、#18（`bodyLineLength` / `maxLineLength` 未校验）；`maxBodyBytes = 0` 的「不限」语义与设计文档一致 |
| 7 | `f_email/src/mime/MimeParser.cj` | .cj | ✅ | 见 #2 / #5 / #7 / #8 / #9 / #10 / #17；`readHeaders`（`340-382`）的折行展开、`maxHeaderBytes` 累计、`bytesToString` 兜底均正确 |
| 8 | `f_email/src/mime/MimeStreamBuffer_test.cj` | .cj | ✅ | 32/64/192 KB 跨块往返用例覆盖面好；`benchStreamBuffer` 有 `F_EMAIL_BENCH` 门禁、不作硬断言，符合仓库基线 §8 |
| 9 | `f_email/src/mime/MimeWriter.cj` | .cj | ✅ | 见 #4（折行）、#5（采样）、#6（改 headers）、#7（丢 preamble/epilogue）、#15（CRLF 两份）、#18；`writeLeafStream` 复用同一块 `buf` 是安全的（`Base64Encoder` / `QuotedPrintableEncoder.write` 都即时消费，只保留 carry，已核对 `QuotedPrintable.cj:96-121`） |
| 10 | `f_email/src/mime/Mime_test.cj` | .cj | ✅ | 往返、Bcc 原样、8bit/QP 选择、嵌套 multipart、preamble 保留、深度上限、literal 类边界；`headersFoldWithinLimit` 只断言行宽不断言值（#4 的反证） |
| 11 | `f_email/src/model/Base64Codec.cj` | .cj | ✅ | 编解码语义（忽略空白、缺 padding、严格/宽松）经 `Codec_test` 验证正确；见 #O1（每 3 字节一分配）与 #18（`lineLength <= 0` 未保护）；`encode` 的 `lineLength <= 0` 短路（`36`）正确 |
| 12 | `f_email/src/model/BodySource.cj` | .cj | ✅ | 三种来源的 `open` / `reusable` / `close` 契约清晰（一次性流二次 `open` 抛错）；`FileBodySource` 无析构 ⇒ #8 的兜底缺口 |
| 13 | `f_email/src/model/CharsetResolver.cj` | .cj | ✅ | 别名表、四级回退、`latin1` 兜底与文档一致；`tryDecode` 抛异常才回退（`Codec_test.charsetResolverFallsBackForUnknownName` 证明 UTF-8 解码器对 GBK 字节确实抛错，故「声明 utf-8 实际 GBK」场景成立）；`allCharsets()` 每次 new 数组（待验证假设 2 的一部分，未单列） |
| 14 | `f_email/src/model/Codec_test.cj` | .cj | ✅ | base64 / QP / encoded-word / 字符集四条线覆盖到位（含 1 字节分块），未见缺口 |
| 15 | `f_email/src/model/ContentType.cj` | .cj | ✅ | `indexOfSemicolon` 的引号/注释/转义状态机正确；见 #16（media type 切分重复）；`charset()` 对未知名回落 UTF-8 属文档语义 |
| 16 | `f_email/src/model/ContentType_test.cj` | .cj | ✅ | 引号内分号、RFC 2231 单段/续行、RFC 2047 兼容、`toString` 往返均有覆盖 |
| 17 | `f_email/src/model/EncodedWord.cj` | .cj | ✅ | `decode` 的「相邻 encoded-word 空白丢弃 / 混排空白保留」与注释一致；见 #13（`encodedSize` 死代码）；`parseAt` 不支持 `charset*lang` 语法（RFC 2231 的 language 后缀，轻微，未单列） |
| 18 | `f_email/src/model/Envelope.cj` | .cj | ✅ | `Resent-*` 优先、`From` 缺失/收件人全空抛错的契约与注释一致；`From` 多地址只取第一个是策略选择（未单列）；依赖 `AddressList` 的组语法行为，属他部分 |
| 19 | `f_email/src/model/HeaderMap.cj` | .cj | ✅ | 保序、大小写不敏感、`set` 覆盖并删重、`remove` 返回原序均正确；`validateName` / `validateValue` 的 CR/LF 与 `:` 拦截构成头注入防线（`HeaderMap_test.cj:76-98` 有对应用例）；`MAX_LINE_OCTETS` 仓内零使用（并入 #4） |
| 20 | `f_email/src/model/HeaderMap_test.cj` | .cj | ✅ | 覆盖顺序、大小写、`set` 删重、`remove` 顺序、注入拒绝、裸 UTF-8 值，未见缺口 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单不含 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 正确性 #1–#11（11 条，含 #9 的双实现）、#12（选项未接线）；可读性 #14 / #17；语言特性方面 `Option` / `Result` 无被静默丢弃的点（`b.isNone()` 分支都有处理，`?? -1` 只用于 `indexOf`）。安全性：**未命中头注入** —— `HeaderMap.validateName` / `validateValue`（`HeaderMap.cj:180-202`）拒绝 `:`、CR、LF 与非可见 ASCII，`MimeWriter.foldHeader` 虽把 `\r\n` 原样写出（`322-334`）但唯一来源是 `EncodedWord.encode` 自己的折行；`MimeParameter.toHeaderValue` 走 RFC 2231 percent-encode + 引号转义，`Spool` 的临时文件名随机生成、不带附件名（`Spool.cj:43-64`），路径穿越与 SMTP 命令注入面都不在本部分的写入路径上。MIME 层真正的安全问题落在 #1 / #2 / #3 的拒绝服务面 |
| §1 死代码 | 3 | 逐个 `private` / `internal` / 顶层 `protected` 符号搜引用：`EncodedWord.encodedSize`（#13）零引用；`ByteSource.readLine:134` 不可达（#14）；`MimeWriteOptions.boundaryPrefix` 属「死配置字段」（#12）。其余：`PartStream.closing` / `sawBoundary`、`MultipartScanner.preamble` / `epilogue` / `closed`、`LeafBuffer.total` / `spilled` / `bytes` / `intoSource` / `discard`、`ByteSource.ensure` / `peekAt` / `readByte` / `readLine`、`joinLines`、`MimeParser.bytesToString`、`ParseState` 均有实际读取。`ImapUtf7.isAscii`、`ImapValue.joinValues`、`Base64Codec.decodeBytes`、`HeaderMap.MAX_LINE_OCTETS` 等 `public` 成员对外可达（硬原则一），只在文件覆盖表记「仓内无引用」，不判死代码 |
| §2 重复逻辑 | 4 | 同文件两两比对 + 跨文件按文案/状态机搜索：#9（`walkEntity` vs `parseEntity`，含 `streamLeaf` vs `readLeaf`，默认值已漂移）、#15（两套 CRLF 状态机）、#16（media type 切分两份）；另 #1 里「首边界判定 vs `atBoundary`」也是同一判定的两套规则（并入 #1 不重复计数）。已比对但不判的：`ImapSpecialUse.specialUseOf` 与 `indexBySpecialUse`（前者取单个属性、后者做去重归类，语义不同）；`Base64Codec.decode` / `decodeBytes`（后者是前者的实现体，属门面）；`CharsetResolver.resolve` / `decode` 的别名查找（`resolve` 带 strict 校验、`decode` 不带，差异是契约） |
| §3 空实现 | 0 | `MimeWriter.flush()`（`51-53`）空体但注释写明「底层是裸 socket / 内存流，无需额外 flush」，属有意的 no-op；`MimeParser.walk` 的 `catch (_: StopWalk) {}`（`83-85`）是控制流终止，不是吞错误（其他异常照常抛出）；`LeafBuffer.discard` 的 `catch (_: Exception) {}`（`476-490`）是清理路径的尽力而为，失败不影响主错误；`Spool` 的 Windows `restrictPermissions` 空体有注释说明「Windows 无 POSIX 权限位」。`StreamBodySource.close` 只丢引用不关底层流，注释写明「生命周期归构造方」，不算未实现 |
| §4 栈溢出 | 0 | 递归只有 `parseEntity` / `walkEntity`（每层 1 帧）与 `MailMessage.findBody` / `MimePart.collectAttachments`（他部分），深度由 `state.parts` 计数 + `maxDepth` 共同限制（默认 32，`MimeParser.cj:221-227` / `103-109`），输入深度无法绕过（每层都会消耗 `parts` 配额）。`ImapSpecialUse` / `ImapUtf7` / `Base64Codec` / `EncodedWord` / `ContentType` 全部是循环实现。**提示**：`maxDepth` 由调用方配置且无上限校验，调成极大值（如 `Int64.Max`）后深嵌套输入会先撞 `maxParts`（1000）再谈栈，故当前不成立 |
| §5 OOM | 3 | #2（preamble/epilogue 无上限物化 + O(n²)）、#3（连续 CRLF 全量进 `pending`）、#10（1000 × 1 MB 叶子内存无聚合上限）。另核对了 `MimeParser.drain` / `ByteSource.ensure` / `readLeaf` 的 `chunk` 分配：都是固定 8–64 KB，无「按报文字段预分配」；`spoolThreshold` / `maxParts` / `maxHeaderBytes` 三处上界存在 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，热点结论不成立；`PartStream.read` 逐字节、`Base64` 每 3 字节分配、`HeaderMap.equalName` 分配三条线索已列入「待验证假设」1–4，优化方案 #O1–#O3 标 `无基线` |
| §6.2 大粒度锁 | 0 | 本部分没有任何 `synchronized` / `Mutex` / `Atomic`：`MimeParser` / `MimeWriter` 的状态都在局部变量或每实例字段里，`ByteSource` / `PartStream` / `MultipartScanner` / `LeafBuffer` 都是「一次解析一个实例」 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池，`MimeStreamBuffer_test.benchStreamBuffer` 的循环是测试代码 |
| §6.4 低效算法 | 1 | `joinLines`（`Boundary.cj:339-345`）循环内字符串 `+` ⇒ O(n²)，已在 #2 内计数；`HeaderMap.names` / `ImapSpecialUse.indexBySpecialUse` 的线性去重键空间极小（头部数量、7 个系统属性），不计 |
| §7 降堆内存方案 | 2 | #O2（readLeaf 每块复制 + 逐字节 add）、#O3（每 part 64 KB 缓冲），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | #O1（base64 每 3 字节一组对象），标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选是 `readLeaf` 的 `chunk` / `slice` 与 `foldHeader` 的 `ArrayList` 副本：`chunk` 在循环内复用、`slice` 逃逸进 `LeafBuffer`（最终进 `PartBody.Data` 或临时文件），`foldHeader` 的缓冲逃逸进 `emitRaw` → `OutputStream`。三者都有逃逸，`@ local!` 不成立；且本部分没有函数级峰值内存前后对照数据，按 checklist §9「没有前后峰值数据只能是待验证假设」，不列方案 |
| §11 现有代码的 BUG（存量） | 18 | 本部分所有发现均为存量（快照无基线）：#1–#18。另逐条核对未列问题的边界：`Base64Codec.decodeBytes` 的 padding/尾部残组（`99-131`）、`ImapUtf7.decode` 的 `&-` / 孤立代理项（`54-63`、`199-220`）、`HeaderMap.remove` 的倒序删除再翻转（`111-129`）、`ContentType.indexOfSemicolon` 的注释嵌套（`134-166`）、`CharsetResolver.latin1`（`212-218`）、`Boundary.ensure` 的搬移（`40-73`）、`PartStream` 在边界处丢弃前导 CRLF（`163-169`）—— 均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 无线程共享路径：`MimeParser` / `MimeWriter` 都是「一次调用一个实例」，`HeaderMap` 按消息实例持有，`CharsetResolver` / `Base64Codec` / `EncodedWord` 是纯静态函数（无可变静态字段），`Spool.createFile` 的随机名 + 16 次重试对并发创建是安全的。唯一需要提醒的是 #6：同一个 `MailMessage` 被两个线程同时 `MimeWriter.write` 时会对同一个 `HeaderMap` 做 `set`（无锁）—— 仓内当前无此调用（`SmtpClient` / `Email` 都是单线程串行），故不单列为并发缺陷 |
| §13 文档与代码一致性 | 0 | 本部分文件清单不含 `.md`（README / `doc/**` 在其它子轮）。为判定 #4 / #5 / #7 / #12 的契约，交叉核对了 `f_email/README.md:159`（「解码后 ≤ 256 KB 的文本进内存，其余落临时文件」）与 `MimeOptions.cj:49-50`：实际是 ≤ `inlineTextLimit`(256 KB) 进 `Text`、≤ `spoolThreshold`(1 MB) 以 `Data(MemoryBodySource)` 留在内存、超过才落盘 —— 与 README 表述不一致，属 README 所在子轮的 §13 问题，本部分只记「范围外提示」 |
| §14 功能完备性与 README 覆盖 | 1 | #12：`MimeWriteOptions.boundaryPrefix` 是「能力未接线」—— 声明、默认值、README（`README.md:267`）与设计文档（`design:971`）都在，代码零读取。其余逐个对照 `public` 声明：`MimeParser.parse` / `walk`、`MimeWriter.write` / `bytesWritten` / `flush`、`MimeParseOptions` 10 个字段、`MimeWriteOptions` 6 个字段（除 #12）、`Base64Codec` / `Base64Encoder` / `Base64Decoder`、`BodySource` 三实现、`CharsetResolver` 5 个入口、`ContentType` / `ContentDisposition`、`EncodedWord` 3 个入口、`Envelope`、`HeaderMap` 全部成员、`ImapSpecialUse` / `ImapUtf7` / `ImapValue` 均可在 README 的「其他公开 API」段落检索到（`ImapValue.text()` / `toString()` 未单独列出，属 `ToString` 实现，不计遗漏） |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无缺文件；`.md` 计数为 0（本部分清单不含） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 9 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

## 总评

本部分覆盖 `f_email` 的 MIME 核心（边界扫描、part 状态机、编解码、头部/参数模型）与 IMAP 的 modified UTF-7 / token 值类型。**编解码算法本身写得相当扎实**：base64 的空白/缺 padding/非法字符三态、QP 的跨块 carry、modified UTF-7 的宽容回退、RFC 2047 相邻 encoded-word 空白丢弃、RFC 2231 续行拼接，都有对应实现与用例，`Codec_test` / `ContentType_test` 的覆盖质量高于模块平均水平；`HeaderMap` 的注入防线（字段名可见 ASCII、值拒绝 CR/LF）也是正确的位置。

风险集中在 **`Boundary.cj` 的「流式」承诺没有完全兑现**，而且三条都命中「不可信输入 → 资源耗尽 / 静默丢内容」：

- **阻塞项**：#3（连续 CRLF 全量进 `pending`）与 #2（preamble/epilogue 无上限 + O(n²) 拼接）是两处**与 `maxBodyBytes` 无关**的内存/CPU 放大面，输入只要几百 MB 就能让解析线程吃满 CPU 或 OOM，且 `MimeParseOptions` 现有限制一个都不触发。这两条应优先修（#3 改状态机，#2 加前缀上限 + 共享 `maxBodyBytes`）。
- **阻塞项**：#1（首边界不认传输填充）是**静默数据丢失**：第一个 part 或整封邮件变成 preamble，`text()` / `attachments()` 返回空且不抛异常。修法很小（抽一个边界行判定函数），但需要补一条带行尾空白的往返用例。
- **次阻塞项**：#4（无空格头部被硬断，值里多一个空格）、#5（只按前 64 KB 决定 CTE）、#6（序列化改调用方 headers）都在「生成侧」，影响的是发出去的邮件在**接收端**的表现，其中 #4 已有现成输入（`Mime_test.headersFoldWithinLimit`）可以立刻加断言复现。
- **资源与契约**：#8（异常路径不清理临时文件）、#10（1000 × 1 MB 的聚合上限缺失）、#7（丢 preamble/epilogue）、#11（preamble 非 UTF-8 直接失败 + 8192 硬上限）、#12（`boundaryPrefix` 未接线）都属于「排期修」的量级，单条改动都不大。
- **可维护性**：#9 的两份 `walk`/`parse` 实现是本模块最大的结构性隐患（默认值已经漂移），建议下一轮合并；#13–#18 是死代码、不可达语句、重复状态机、枚举用字符串比较等清理项。
- **性能与内存**：本部分**没有任何改前/改后测量数据**（无 `cjprof` / `cjpm bench` 基线），#O1–#O3 与四条待验证假设都不进修复清单；`Base64` 每 3 字节一分配（#O1）最值得下一轮先补 `allocPerWrite` 对照，因为 `MimeStreamBuffer_test.benchStreamBuffer` 已经提供了埋点。
- **已确认没有**的问题：头注入（`HeaderMap` 两道校验 + RFC 2231 编码，`MimeWriter` 的 CRLF 透传只来自 `EncodedWord` 自身折行）、路径穿越（`Spool` 随机名、不用附件名）、锁与死锁（无线程共享）、local mode 收益（候选全部逃逸）、按不可信长度预分配（无）。

存量缺陷共 18 条（严重 3 / 一般 9 / 轻微 6），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

> **范围外提示（1 条，不占本部分统计）**：`README.md:159`「解码后 ≤ 256 KB 的文本进内存，其余落临时文件」与 `MimeOptions.cj:49-50` 的实际分流（`inlineTextLimit` 256 KB 进 `Text`、`spoolThreshold` 1 MB 以内以 `Data(MemoryBodySource)` 留内存、超过才落盘）不一致，留待含 README 的子轮按 §13 处理。
