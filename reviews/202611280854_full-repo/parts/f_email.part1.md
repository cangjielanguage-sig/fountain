# f_email 模块审查报告

> **模块第 1/6 部分**：只覆盖 `files/f_email.part1.txt` 列出的 3 个文件——`f_email/README.md`、`f_email/README_en.md`、`f_email/doc/f_email设计文档.md`。`doc/spec/**` 与全部 `src/**`（72 个 `.cj`）由第 2–6 部分产出，本报告不对其单独下结论；本报告引用的 `.cj` 行号只作为「文档声明 vs 实现」的取证，不重复计入覆盖表。

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（本部分 0 个 `.cj` + 3 个 `.md`；README 305/306 行，设计文档 2492 行）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）；三个文件在 `git status` 中均无改动
- **审查重点**：MIME 编解码与地址解析正确性、注入与安全、资源与连接、OOM、死代码、重复逻辑、存量 BUG（本部分落在「文档承诺 ↔ 实现」这一侧）
- **报告版本**：v1（第 1/6 部分）

## 发现

### [一般][存量] README 把正文落盘阈值写成单级 256 KB，实际是 256 KB / 1 MB 两级：256 KB–1 MB 的正文仍整段驻留内存

- **位置**：`f_email/README.md:159`（`README_en.md:160` 同文）
- **来源**：存量（`git blame` → `b555d80162`，2026-10-29；工作区无改动）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」；§5「OOM 判据必须量化」；§7「流式化 / 有界化」的现状口径
- **证据**：静态确定 —— `MimeOptions.cj:36` `inlineTextLimit` 默认 `256 * 1024`、`:38` `spoolThreshold` 默认 `1024 * 1024`；`MimeParser.cj:301` 用 **spoolThreshold** 构造 `LeafBuffer`（超 1 MB 才 `spill()` 落盘），`MimeParser.cj:324` 只用 **inlineTextLimit** 决定是否进 `PartBody.Text`。两者之间的 256 KB–1 MB 正文走 `MemoryBodySource`，在堆上整段保留。
- **描述**：README 的原话是「解码后 ≤ 256 KB 的文本进内存，其余落临时文件（权限 0600）」。按此描述，调用方会认为「>256 KB 的正文已不在内存」，从而按「单封邮件常驻 ≈ 头部 + 256 KB」做容量规划。实际常驻上界是 `min(正文, 1 MB) × 叶子 part 数`：`MimeParseOptions.maxParts` 默认 1000（`MimeOptions.cj:32`），`maxBodyBytes` 默认 0（不限），因此一封构造出来的邮件（1000 个 part，每个 0.9 MB 的 `application/octet-stream`）可以在堆上留下约 900 MB 的 `MemoryBodySource` 字节数组，期间只有落盘那部分才离开堆。这不是「文档写得粗糙」，而是把内存上界低估了近 4 倍（1 MB vs 256 KB）并隐藏了「part 数会乘上去」这一维。
  同时「权限 0600」在 Windows 上不成立：`Spool.cj:117-120` 的 `restrictPermissions` 是空实现（注释说明 ACL 由系统继承），而 `cjpm.toml` 明确支持 `x86_64-w64-mingw32`。
- **建议**：README 改成三段式并给出参数名：`≤ inlineTextLimit(256 KB)` → `PartBody.Text`；`inlineTextLimit..spoolThreshold` → 内存 `BodySource`；`> spoolThreshold(1 MB)` → 临时文件（仅 POSIX 0600）。补一句「常驻上界 ≈ 每 part 1 MB × maxParts，需要更紧的上界就调小 spoolThreshold / maxParts」。文中说明 `maxBodyBytes` 默认不限、`maxParts` 默认 1000。
  范围外提示：`maxParts × spoolThreshold` 的实际峰值与是否需要「全局字节预算」属 `MimeParser`（第 4 部分）判定，本报告只指出文档口径错误。

### [一般][存量] 文档承诺临时文件「`close()` 删除 + 进程退出 `deleteOnExit` 兜底」，实现既无 `deleteOnExit`，`MailMessage`/`MimePart` 也不是 `Resource`——大附件落盘后没有统一释放入口

- **位置**：`f_email/doc/f_email设计文档.md:723`（§4.4.1）、`:2023`（§9「临时文件泄露」行）；`f_email/README.md:159` 只提「落临时文件」，未提释放
- **来源**：存量（`git blame` → `135d723bdf`，2026-10-28 初版设计稿）
- **判据**：review-checklist §11「资源不对称：打开未关 / 异常跳过释放」；§13「文档承诺与实现不符」；§5「长期持有：注册表不注销」
- **证据**：静态确定 ——
  - 删除只有两条路径：`FileBodySource.close()` 且 `owned=true`（`BodySource.cj:112-123`）、`MimeParser` 失败清理（`:485` `removeIfExists`）。全仓 `grep` `delete|removeIfExists|deleteOnExit` 仅命中这两处 + `Spool_test.cj`，**没有** `deleteOnExit`，`Spool` 也不登记已创建路径（`Spool.cj:41-64`）。
  - 持有链：`LeafBuffer.spill()`（`MimeParser.cj:489-497`）→ `Spool.createFile` → `LeafBuffer.intoSource()` 返回 `FileBodySource(target, owned: true)`（`MimeParser.cj:472`）→ `PartBody.Data` → `MimePart`（`MimePart.cj:64`，不是 `Resource`、无 `close`）→ `MailMessage`（`MailMessage.cj:29`，同样无 `close`）。
  - 门面路径同理：`Email.body()` 返回的 `MailBody`/`MailAttachment`（`EmailFacade.cj:189-199`、`104-190`）持有 `MimePart`，而 `Email.close()` 只关三个协议客户端（`EmailFacade.cj:418-446`），不碰任何 `BodySource`。
- **描述**：一封带 20 MB 附件的邮件，解析后附件在 `/tmp` 留一个 0600 临时文件；调用方按 README 的用法（`email.body()` → `attachments` → `saveTo`）走完，**没有任何 API 提示他还要去关掉 `BodySource`**，`MailMessage`/`MimePart` 也没有 `close()` 可调。文件因此活到进程退出，且进程异常退出时永久残留（文档承诺的 `deleteOnExit` 兜底并不存在）。对长期运行的发信/收信服务，这是磁盘只增不减；对解析外部邮件的场景，残留文件里是明文附件内容。
- **建议**：三选一并同步文档：①`MailMessage`/`MimePart` 实现 `Resource`，`close()` 递归关闭叶子 `Data(BodySource)`（`BodySource.close()` 已有删除语义，改动小、最符合现有设计）；②`MimeParser` 接受一个「临时文件登记表」（或返回 `MailMessage` 时携带），由调用方统一 `cleanup()`；③至少把 `deleteOnExit` 的承诺删掉，并在 README 的 MIME 示例里显式写 `try (message) { ... }` / `part.source()?.close()`。
  另外 `README.md:159` 的「权限 0600」应注明仅 POSIX 生效。

### [一般][存量] 文档称 `FETCH BODY[]` 的 literal「直接交给 MimeParser、不整体驻留」，实际 `fetchMessage` 先把整封邮件读成 `Array<Byte>` 再解析

- **位置**：`f_email/README.md:22`（「FETCH（含 literal 的流式与内存两路）」）、`f_email/README_en.md:24`；`f_email/doc/f_email设计文档.md:1876`（§8.5「两者都把 literal 直接交给 `MimeParser`」）、`:1839-1841`（§8.4 明确把「读进 `Array<Byte>`」列为错误做法）
- **来源**：存量（`git blame` → `b555d80162`，2026-10-29；设计稿 `135d723bdf`）
- **判据**：review-checklist §13「文档承诺与实现相反」；§5「一次性物化」；§7「流式化」
- **证据**：静态确定 —— `ImapClient.fetchMessagesInternal` 先 `fetchInternal(...)`（`ImapClient.cj:809`），拿到 `FetchResult.body: ?Array<Byte>`（`ImapFetch.cj:567`），再 `MimeParser.parse(MemoryBodySource(bytes).open(), ...)`（`ImapClient.cj:813`）；literal 早在 `ImapClient.cj:1431` 就 `body = Some(literals[0])` 整段进了内存。真正流式的是另一个重载 `fetch(set, items, sink)`（`ImapClient.cj:575`），`fetchMessage` 没走它。
- **描述**：设计文档在 §8.4 用一张表否掉了「读进 `Array<Byte>`（峰值 20 MB，无法处理 1 GB 邮件）」，并在 §8.5 承诺 `fetchMessage` 走流式；实现恰好落在被否掉的那一档。后果是可量化的：一封 20 MB 附件的邮件，base64 后约 27 MB 先完整驻留，`MimeParser` 再按 `spoolThreshold` 落一份盘，解析期间堆上同时存在 27 MB 原始字节 + `LeafBuffer` 的 1 MB 内存段；`Email.body()`（`EmailFacade.cj:356` → `uidFetchMessage`）走的就是这条路，所以门面用户的「读正文」也承受这份峰值。
  上限由 `maxLiteralBytes` 默认 64 MB 兜底（`ImapClient.cj:1665`、`:711`），所以是「有界但远大于文档描述」，按后果定「一般」而非「严重」。
- **建议**：`fetchMessagesInternal` 改走 `fetch(..., sink)`，在 `onBodyChunk` 里直接喂 `MimeParser`（`MimeParser` 已按 `spoolThreshold` 分流，不需要中间整段）；或者把文档改成「整封物化，受 `maxLiteralBytes`（默认 64 MB）限制；大附件请用 `fetch(sink)` 或 `BODY.PEEK[1.2]` 分段取」，并删掉 §8.5 的「直接交给 MimeParser」表述。两条路都要同步 §8.4 的对照表，避免设计文档自相矛盾。

### [一般][存量] README 的包清单漏掉 `fountain::f_email.model`——24 个源文件、绝大多数公开类型都在这个包里

- **位置**：`f_email/README.md:5`、`f_email/README_en.md:5`
- **来源**：存量（`git blame` → `164ed4e540`，2026-10-28）
- **判据**：review-checklist §13「API / 路径与源码不符」；§14.2「公开 API 未文档化 / 索引未登记」
- **证据**：静态确定 —— `grep "^package " src/**/*.cj` 的分布是 `f_email` 3 / `f_email.imap` 17 / `f_email.mime` 6 / **`f_email.model` 24** / `f_email.pop3` 4 / `f_email.smtp` 7 / `f_email.transport` 11；README 只列了 transport / mime / smtp / pop3 / imap 五个子包。设计文档附录 A.1/A.2（`:2425-2440`）明确写了「编解码器在实现时改放到 `model/`」并列出 `f_email.model` 类型表——README 没同步。
- **描述**：`HeaderMap`、`MailMessage`、`MailMessageBuilder`、`EmailAddress`、`ContentType`、`Secret`、全部 `Mail*Exception`、`Base64Codec`/`QuotedPrintable`/`EncodedWord`/`CharsetResolver` 都在 `fountain::f_email.model`。README 第 194 行起的「其他公开 API」只按「模块级 / 类型」分组、不标包名，加上第 5 行又漏掉 model，使用者只能靠编译器猜 import 路径（`import fountain::f_email.model.HeaderMap` 无处可查）。
- **建议**：第 5 行补 `f_email.model`；「其他公开 API」每个类型后缀标包名，或直接照搬附录 A.2 的「包 → 类型」表（那张表已经是对的，只差搬进 README）。

### [一般][存量] README「其他公开 API」清单不完整，末行还停在一个没写完的签名上（两个 README 都是）

- **位置**：`f_email/README.md:305`（文件最后一行）、`f_email/README_en.md:306`；缺项见 `README.md:208/256/264/267/290`
- **来源**：存量（`git blame` → `f624bf2faa`，2026-11-11「各模块按最新代码补『其他公开 API』小节」）
- **判据**：review-checklist §14.2「公开 API 未文档化」；§13「示例 / 文档不能用」
- **证据**：静态确定 ——
  - 末行是 `- \`TransferDecoder\`：\`static func stream(\``，签名在左括号处截断，`TransferDecoder.stream` 的参数与返回类型完全缺失；`README_en.md` 同位置同样是 `static func stream(`。两个文件都以此为最后一行，说明是生成时被截断而非有意留白。
  - 同一清单里 `MimeWriteOptions`（`README.md:267`）没有 `allow8Bit`，而 `README.md:164` 的示例正在写 `MimeWriteOptions(allow8Bit: true)`；`MimeParseOptions`（`:264`）没有 `strict`，示例 `:160` 正在写 `MimeParseOptions(strict: false)`（实参在 `MimeOptions.cj:40` / `:71`）。
  - 其余缺项：`SendReport.rejected`（`SendReport.cj:67`，示例 `README.md:108` 在用）、`ContentDisposition.filename()`（`ContentType.cj:210`）、`MailBody.text` / `MailBody.attachments`（`EmailFacade.cj:190-192`）、`MailAttachment.filename` / `size` / `saveTo`（`EmailFacade.cj:104`、`:123`、`:157`）、`MailSummary` 的 `sequence` / `subject` / `from` / `receivedAt` / `size` / `flags` / `isUnread()`（`EmailFacade.cj:54-86`，示例 `:64-71` 在用前三个）、`SearchCriteria.andWith`（`ImapSearch.cj:54`，示例 `README.md:138` 在用）。
- **描述**：该小节自称「以下声明未在上文展开……完整语义见 `src/`」，读者会把它当完整索引。结果是：①最常用的 `MailSummary` 字段只列了 `date`/`id`/`mailbox`，示例里用的 `subject`/`receivedAt`/`isUnread()` 在清单里查不到；②两个 options 结构体的字段清单与同页示例直接矛盾；③末行截断让 `TransferDecoder` 这个 public 类只有半个签名。这类「生成后未校验」的清单会持续漂移，每加一个 public 成员就多一处缺口。
- **建议**：重新生成清单并在 CI 里加一条机械校验（用 `grep -rhoE "^public (open |abstract |sealed )?(class|struct|enum|interface|func|let) [A-Za-z_0-9]+"` 的结果与本文件比对，缺项即失败）；补齐上述成员与 `TransferDecoder.stream(...)` 的完整签名。清单与用法示例放在同一文件时，至少保证「示例用到的成员必须出现在清单里」。

### [一般][存量] 设计文档承诺「所有写入日志的协议行先转义控制字符」，`MailTrace` 只做凭据脱敏，不做控制字符转义

- **位置**：`f_email/doc/f_email设计文档.md:2020`（§9 安全表「日志注入」行）
- **来源**：存量（`git blame` → `135d723bdf`，2026-10-28）
- **判据**：review-checklist §13「文档承诺与实现相反」；§14.1「承诺了但没实现」；§11「日志注入 / 语义与注释不符」
- **证据**：静态确定 —— `MailTrace.cj:38-52` 的 `redactLine` 只按行首命令做三件事：`AUTH` 保留机制名、`PASS`/`LOGIN` 丢参数、其余原样返回；没有对 `<0x20`、`0x7F` 做转义。`LineChannel.traceLine`（`LineChannel.cj:471-483`）把 `String.fromUtf8(bytes)` 的结果直接 `t.onLine(direction, redactLine(text))`，而入站行来自服务器，内容不可信（`readLine` 只去掉行尾 CRLF，行内裸 CR、ESC、BEL 都保留）。
- **描述**：文档把「日志注入」列为已防威胁，实现只防了「凭据泄露」这一半。触发条件是任意的：服务器（或中间人、或伪造的测试脚本）回一行 `250-\x1b]0;pwned\x07` 或含裸 CR 的文本，`MailTrace` 的接收方若把行写进 `f_log`/文件，就会出现终端控制序列注入、或一行被拆成两行伪造日志。写出行有 `writeLine` 的 CR/LF 防线（`LineChannel.cj:305-311`，已核对），所以这半边成立；读入行没有任何转义。
- **建议**：在 `traceLine` 统一过一遍 `sanitizeForLog`（`<0x20` 除 TAB、`0x7F` → `\xNN`，或至少把 CR/LF 换成 `\\r`/`\\n`），与 `redactLine` 合并成一个函数，保证「写日志的行 = 脱敏 + 转义」；若决定不转义，则在 `MailTrace` 的接口注释与设计文档 §9 明确「trace 内容是未转义的服务器原文，调用方写日志前必须自行转义」，把承诺改成现状。

### [轻微][存量] 设计文档正文的 API 块与文件树未随实现更新，与附录 A 的「以代码为准」并存，容易照错

- **位置**：`f_email/doc/f_email设计文档.md:160-207`（§1.5 文件树）、`:531`（§4.1 长度规则）、`:763-780`（§5.1 `ContentType`/`ContentDisposition`）、`:965-972`（§5.6 `MimeWriteOptions`）、`:1677-1686`（§8.2.1 `MailboxStatus`）
- **来源**：存量（正文 `git blame` → `135d723bdf`，2026-10-28；附录 A 由实现后补的 `b555d80162` 加入，2026-10-29，见 `:2419`）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「文档过期」
- **证据**：静态确定，逐条对照：
  - §4.1 写「单行硬上限 998 octets；超长抛 `MailLimitException`」，`HeaderMap.validateValue`（`HeaderMap.cj:192-199`）只拦 CR/LF，注释明确「998 是物理行上限，不是展开后字段值的上限……由 MimeWriter 折行保证」，即 `HeaderMap.set` 不会因超过 998 抛异常。
  - §5.1 写 `ContentType.prop type`（实为 `typeName`，`ContentType.cj:28`）、`parameters: HashMap<String,String>`（实为 `MimeParameters`，`:95`）、`ContentDisposition.prop filename: ?String`（实为 `func filename(): ?String`，`:210`）。
  - §5.6 的 `MimeWriteOptions` 缺 `allow8Bit` / `utf8Headers`（`MimeOptions.cj:71`/`:82`），而这两项是实现里真实存在且示例会用的。
  - §8.2.1 的 `MailboxStatus` 写 `exists` / `readOnly: ?Bool`，实际是 `messages` / `readOnly: Bool`（`ImapFetch.cj:694-704`）。
  - §1.5 的文件树列出 `src/MailException.cj`、`src/Secret.cj`、`src/MailAddress.cj`、`mime/ContentDisposition.cj`、`pop3/Pop3Multiline.cj`，这些文件都不存在（实际在 `model/` 下，POP3 多行在 `Pop3Reply.cj`）。
- **描述**：文档末尾（`:2415`、`:2421`）声明「API 签名在实现阶段可微调」「附录以代码实际形态为准」，所以不是致命错误；但正文章节没有逐条标注「已过时」，附录 A 只给了「类型清单 + 少量关键签名」，没有覆盖 `ContentType.type`、`MailboxStatus.exists` 这类**成员级**差异。按正文写代码的人会编译不过，且不知道去附录找。
- **建议**：给正文被附录覆盖的段落加「⚠ 已由附录 A 取代」标记（至少 §1.5、§4.1、§5.1、§5.6、§8.2.1），或把附录 A.4 扩成「正文 → 实际」的差异表并逐条列出上述成员级差异。

### [轻微][存量] 文档多处承诺「记 warning」，MIME 解析侧没有告警出口：宽容模式的降级对调用方不可见

- **位置**：`f_email/doc/f_email设计文档.md:909`（§5.4.6「缺失结束 boundary：宽松模式把剩余字节作为最后一个 part，记 warning」）、`:793`（§5.1「非法参数宽松模式跳过该参数并 warning」）；对照 `MimeParser.cj:259-263`、`:152`
- **来源**：存量（`135d723bdf`）
- **判据**：review-checklist §13「文档承诺与实现不符」；§3「`case None => ()` 把错误吃掉 / 静默降级」
- **证据**：静态确定 —— `MimeParser` 的宽松分支在 `:259-263` 直接 `if (stream.closing || !stream.sawBoundary) { scanner.closed = true }`，没有记录任何信息；`MimePart`/`MailMessage` 没有 `warnings` 字段（全仓 `warnings` 只出现在 `MailDate.cj:32` 与 `MailDate_test.cj`）。`LineChannel.protocolWarning` 是传输层的 trace 通道，与 MIME 解析结果无关。
- **描述**：文档开头把「读不懂要有明确的降级与告警」列为三条底线之一，实现只有「降级」没有「告警」。一封结束 boundary 缺失的邮件会被静默截断成「最后一个 part 到 EOF」，调用方拿到的 `MailMessage` 与正常邮件在类型上完全一样，无法判断附件是否被截断。这属于「静默降级」，不是崩溃，按轻微记；但它是文档承诺的能力缺口，不是纯措辞问题。
- **建议**：`MimeParseOptions` 加一个 `warnings!: ?(String) -> Unit` 或 `MimePart` 加 `warnings: Array<String>`（与 `MailDate.warnings` 同构），至少让「缺失结束 boundary / 非法参数 / 非法 boundary / 字符集回退」四处可观测；短期做不到就把 §5.1/§5.4 的「记 warning」删掉，改成「静默降级」。

### [轻微][存量] README 的「275 通过」与当前用例数（279 个 `@TestCase`）不符，且未标注环境与日期

- **位置**：`f_email/README.md:30`、`f_email/README_en.md:33`
- **来源**：存量（`b555d80162`）
- **判据**：review-checklist §13「文档过期」；§8 基线「性能/验证结论要附环境」
- **证据**：静态确定（仅计数）—— `grep -c "@TestCase" src/**/*_test.cj` 合计 279，另有 44 个类级 `@Test`；README 写「全量 `cjpm test`：275 通过 / 0 失败」。只读审查无法运行测试，因此不能断言有失败，只能断言数字与当前用例数不一致。
- **描述**：模块被拆成 6 个子轮后，各部分新增/调整用例时这个数字不会自动更新。读者会把它当成当前质量门禁，实际它对应的是 2026-10-29 那次快照。
- **建议**：改成「截至 2026-10-29，Linux aarch64，275 通过 / 0 失败」，或直接去掉具体数字改为「全量 `cjpm test` 通过（见 `doc/spec/.../verification.md`）」，把易腐的数字收进验证记录文件。

## 优化可行性方案

### [堆内存] `fetchMessage` / `uidFetchMessage` 改为流式解析，去掉整封邮件的 `Array<Byte>` 中转

- **现状**：`ImapClient.fetchMessagesInternal` 用 `fetchInternal` 取 `FetchResult.body: ?Array<Byte>`（`ImapFetch.cj:567`），literal 在 `ImapClient.cj:1431` 已整段驻留，再包 `MemoryBodySource` 交给 `MimeParser`（`:813`）。一封 20 MB 附件邮件（base64 后约 27 MB）在解析期间常驻 ≈ 报文长度；`Email.body()`（`EmailFacade.cj:356`）走同一条路。上限 `maxLiteralBytes=64 MB`（`ImapClient.cj:1665`）。
- **方案**：`fetchMessagesInternal` 改用已有的 `fetch(set, items, sink)`（`ImapClient.cj:575`），在 `FetchSink.onBodyChunk` 里把字节喂给 `MimeParser`（解析器已按 `spoolThreshold` 分流，边读边落盘）；`FetchItem.body(section: BodySection.entire(), peek: true)` 保持不变，只换消费端。
- **预期**：峰值从 O(报文长度) 降到 O(spoolThreshold × 同时活跃的叶子 part)（按默认值约 1 MB 量级）；对 64 MB 上限的报文可去掉一整份 64 MB 副本。**收益待实测，不写成结论。**
- **代价**：需要适配 `FetchSink` 的「先 chunk 后 meta」顺序（设计文档 A.4 `:2485` 已记录这一约定）；解析中途失败要在流内提前中断；`fetchMessagesInternal` 由「收集结果再解析」变成「边收边解析」，错误定位（哪个 part）要多带上下文。语义不变：返回的仍是 `Array<MailMessage>`。
- **验证**：同机 `-O2`，20 MB 附件样本 20 轮，对比 `getAllocatedHeapSize()` 峰值与 RSS 峰值（改前 = 现实现，改后 = sink 版），同时断言解析结果（part 数、附件字节 MD5）一致；再用 1000 part × 0.9 MB 的构造样本看是否触到常驻上界。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `fetchMessage` 的整封物化是 `Email.body()` 路径的峰值主项 | `f_email/src/imap/ImapClient.cj:809-816`、`:1431` | 该路径堆峰值占端到端峰值的比例 | 20 MB 附件样本跑 `cjprof heap`，对照 sink 版本；记录 `getAllocatedHeapSize()` 与 RSS 峰值 |
| 2 | 1000 part × 每 part 0.9 MB 可把常驻内存推到接近 900 MB（`maxParts × spoolThreshold`） | `f_email/src/mime/MimeOptions.cj:32-38`、`MimeParser.cj:301` | 构造样本下的真实峰值与是否先被 `maxHeaderBytes`/`maxParts` 挡住 | 生成 1000 part 的 multipart 样本（每 part 0.9 MB 二进制），`cjpm bench` 或独立程序跑一轮，采 RSS |
| 3 | 未转义的服务器行写进 `f_log`/文件时确实能造成日志注入（终端控制序列 / 伪造行） | `f_email/src/transport/MailTrace.cj:38-52`、`LineChannel.cj:471-483` | 是否有调用方把 `MailTrace.onLine` 直接落文件 | 全仓搜 `MailTrace` 的实现类与 `onLine` 落盘路径；有则构造含 `\x1b`/裸 CR 的服务器回复复现 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/README.md` | .md | ✅ | 用法示例与实现签名逐条核对通过；见「一般 落盘阈值」「一般 包清单」「一般 API 清单」「轻微 275」「一般 FETCH 流式」「一般 临时文件」 |
| 2 | `f_email/README_en.md` | .md | ✅ | 与中文版逐节对应（无整节缺失）；同样的落盘阈值 / 包清单 / API 清单 / FETCH 流式 / 测试计数问题同位置存在 |
| 3 | `f_email/doc/f_email设计文档.md` | .md | ✅ | 2492 行全读（正文 §0–§14 + 附录 A/B/C + 实现后附录 A）；见「一般 临时文件」「一般 日志转义」「轻微 正文漂移」「轻微 warning 无出口」 |

合计：`.cj` 0 个 / `.md` 3 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分只有 3 个 `.md`，没有可执行的声明、类型或控制流，无法在本部分判定代码级正确性 / 设计 / 语言特性 / 可读性；安全性只在「文档承诺的安全防线是否落地」这一面成立，已分别记入 §13（2 条：日志转义、临时文件生命周期）与 §14（0 条）。MIME 编解码与地址解析的代码级正确性留给第 2–6 部分 |
| §1 死代码 | 0 | 本部分无源码声明；文档内的代码围栏是示意片段，不参与「无调用者」判定。为避免漏项，已确认 `^public ` 只出现在设计文档的 94 行代码围栏（API 示意块）里，两份 README 为 0 行，均不是本模块编译单元 |
| §2 重复逻辑 | 0 | 三份文档之间做过两两比对：README 与 README_en 是同一内容的双语版本（预期重复，不算问题）；设计文档正文的 API 块与附录 A.3「关键签名」确实重复且已漂移，但那是**文档漂移**，已作为 §13 的「轻微 正文漂移」一条合并记录，不按代码重复逻辑计数 |
| §3 空实现 | 0 | 文档没有实现体。唯一的「承诺行为但未实现」是日志控制字符转义与临时文件 `deleteOnExit`，已分别记入 §13 / §11 行，不在此重复计数 |
| §4 栈溢出 | 0 | 文档中的递归只出现在协议描述（multipart 递归、`message/rfc822` 嵌套），且都写明深度上限（§5.8 `maxDepth=32`、§8.3 IMAP 64）；本部分无可执行递归 |
| §5 OOM | 0 | 文档侧的 OOM 口径错误（落盘阈值、FETCH 物化）已归入 §13；`maxParts × spoolThreshold` 的实际上界需要构造样本实测，进「待验证假设」#2，不在此计数 |
| §6.1 热点瓶颈 | 0 | 本部分没有 profile / `cjpm bench` 数据；设计文档 §11.3 的目标值自己标注「待实测，不是承诺」，不能当基线，已进「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关代码；文档 §2.3 声明「所有客户端不是线程安全的、每连接一线程」，属契约描述，其实现是否成立由第 3/5 部分核对 |
| §6.3 并发串行 | 0 | 文档 §2.3 描述 IDLE 用「一个读线程 + 队列」，无 `spawn`+`get` 形态；实现侧留给第 3 部分 |
| §6.4 低效算法 | 0 | 文档 §11.1/§11.2 给的是复杂度声明（O(字节数)、滚动窗口扫描），属设计意图；无测量数据可判「低效」 |
| §7 降堆内存方案 | 1 | 命中 `fetchMessage` 流式化（无基线，标 `无基线（待验证）`） |
| §8 降 CPU 方案 | 0 | 无 CPU 测量数据，不产出 CPU 方案；文档 §11.3 的目标（1 MB 解析 < 30 ms 等）未实测，不进方案 |
| §9 local mode 可行性 | 0 | 文档未涉及 local mode；本部分也没有可分析的函数体。MIME 解析的临时对象是否适合 local region 属 `MimeParser`（第 4 部分）的判定，需要峰值内存对照，本次无数据 |
| §11 现有代码的 BUG（存量） | 1 | 命中「临时文件生命周期」：文档承诺 `close()` 删除 + `deleteOnExit`，实现无 `deleteOnExit`、`MailMessage`/`MimePart` 不可关闭 ⇒ 落盘附件无统一释放入口。其余边界/空值类 BUG 需读 `.cj`，留给第 2–6 部分 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享可变状态。文档 §2.3 的「`close()` 可从其他线程调用来中止阻塞读」是**实现契约**，能否成立要看 `MailConnection`/`ImapIdle` 的原子性（第 3/5 部分），本部分不据文档声明下结论 |
| §13 文档一致性 | 6 | 命中：落盘阈值、FETCH 流式、包清单、API 清单、日志转义、正文 API 块漂移；另 warning 出口、测试计数 2 条轻微。已核对并判为**一致**的项：`MimeParseOptions` 默认值（256 KB/64 KB/1000/32）、`LineChannel` 行上限（SMTP/POP3 4 KB、IMAP 8 KB）、`ImapParser.MAX_DEPTH=64`/`MAX_LINE=8192`、`maxLiteralBytes=64 MB`、STARTTLS 不降级 + 升级后重取 channel、`HeaderMap` CR/LF 拒绝与字段名白名单、`EmailAddress` 拒绝 `\r\n<>` 且解析接受废弃路由、`MailDate` 两位年/缺失时区/非法日期回退、`Spool` 0600（POSIX）、`redactLine` 的 AUTH/PASS/LOGIN 脱敏、`Bcc` 不修改调用方消息、`defaultText=text/plain; charset=us-ascii`、`MailMessage.headers === root.headers`、`multipart/digest` 默认 `message/rfc822` |
| §14 功能完备性与 README 覆盖 | 2 | 命中：包清单漏 `model`、API 清单不完整 + 末行截断。逐项核对公开类型：`grep -v _test` 的 180 个 `^public` 名字在 README 中均有出现（类型级无遗漏），问题集中在成员级 |
| 文件覆盖 | 3/3 | 无缺文件；README 的 2610 字符长行（`:198`）已用 `sed`/`fold` 取到尾部，确认是完整的模块级类型清单、非截断 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量缺陷合计 9 条（严重 0 / 一般 6 / 轻微 3），是否纳入修复待用户决定。

## 总评

本部分只覆盖文档，因此结论是「文档作为对外契约是否可信」，而不是「MIME/地址解析实现是否正确」。总体看，三份文档的质量高于一般库文档：`README` 的用法示例经逐条比对确实能编译（`Email.builder()`、`SmtpClient.builder(...).auth(...)`、`ImapIdle(client).start()` + `nextEvent(timeout:)`、`SearchCriteria.unseen().andWith(...)`、`MimeParseOptions(strict: false)`、`MimeWriteOptions(allow8Bit: true)` 全部与源码签名一致），设计文档把「三条底线」「STARTTLS 四条规则」「MIME 限制」「恶意样本」写得很实，且末尾的附录 A 主动承认「正文 API 会漂移、以代码为准」——这在同类模块里少见。核对过的安全防线（`writeLine` 拒绝 CR/LF、`HeaderMap` 头注入拦截、`EmailAddress` 拒绝 `\r\n<>`、STARTTLS 不降级、`maxLiteralBytes`/`maxDepth`/`maxParts` 上限、`Spool` 随机文件名 + 0600、`Secret`/trace 的凭据脱敏）都是真实现了的，不是纸面承诺。

需要收口的是三类「文档与实现的缝」：①**容量口径**——落盘阈值被写成单级 256 KB，实际是 256 KB/1 MB 两级且 `maxParts` 会乘上去；`fetchMessage` 被描述成流式，实际整封物化。这两条直接影响使用者的内存规划，是本部分最值得先修的。②**资源生命周期**——文档承诺 `close()` 删除 + `deleteOnExit` 兜底，实际临时文件没有统一释放入口（`MailMessage`/`MimePart` 不是 `Resource`，`Email.close()` 也不碰正文），长期服务会积累明文附件残片。③**索引完整性**——包清单漏掉承载 24 个源文件的 `f_email.model`，「其他公开 API」清单缺 `allow8Bit`/`strict`/`rejected`/`MailSummary` 字段等，末行还停在半个签名上；这类问题机械可查，建议做成 CI 校验而不是每次手补。

另外两处属于「承诺了告警但没出口」：MIME 解析的宽容降级（缺失结束 boundary、非法参数）在结果里完全不可见；`MailTrace` 只脱敏不转义控制字符，与 §9 的「日志注入」防线不符。前者影响调用方判断附件是否被截断，后者只影响启用了 trace 的调试场景，都可排期。

本部分无阻塞项（0 严重）。MIME 编解码 / 地址解析 / 注入防线的代码级正确性、死代码与重复逻辑的机械检查，需以第 2–6 部分的 `.cj` 结论为准；本报告只保证「文档说的和代码做的是否一致」这一层。
