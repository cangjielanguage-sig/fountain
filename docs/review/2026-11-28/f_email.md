# f_email 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（88 个文件：72 个 .cj + 16 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 6 个分部分报告合并：`parts/f_email.part1..6.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [严重] 1. 解析落盘的附件临时文件没有任何释放路径，按邮件封数无界增长

- **位置**：`f_email/src/EmailFacade.cj:98`（`MailAttachment` 无 `close`）、`f_email/src/EmailFacade.cj:189`（`MailBody` 无 `close`）、`f_email/src/model/MimePart.cj:148`（`source()` 是唯一出口）、`f_email/src/mime/MimeParser.cj:472`（`FileBodySource(target, owned: true)`）、`f_email/src/model/BodySource.cj:112`（只有 `close()` 才删文件）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（资源不对称：打开未关）+ §5（无界增长）
- **证据**：静态确定 —— `FileBodySource` 的 `owned=true` 只在 `close()` 里 `removeIfExists(path)`（`model/BodySource.cj:112-121`）；全仓搜 `source.close()` / `source().close` 为 0 命中（`grep -rn "\.source()" f_email/src` 只有 `EmailFacade.cj:125/134` 与两个测试的 `open()`）；`MailMessage`（`model/MailMessage.cj:29`）与 `MimePart` 都不是 `Resource`、无 `close()`；`MailAttachment.part` 是 `private`，门面使用者拿不到 `BodySource`，`MailAttachment` 自身也没有 `close/closeAll`
- **描述**：`MimeParser.readLeaf` 对超过 `spoolThreshold`（默认 1 MB）的叶子正文走 `LeafBuffer.spill()`，最终由 `intoSource()` 返回 `owned=true` 的 `FileBodySource`（注释写「调用方接管所有权（关闭时删除）」，但没有任何调用方）。经 `Email.fetch/body/attachments` 使用门面时，`MailAttachment`/`MailBody` 都不提供释放入口，`MailAttachment.part` 又不可见，调用方既无法关闭也无法删除。结果是：每封带 >1 MB 附件的邮件都会在 `TMPDIR`/`/tmp` 留下一份 0600 副本，进程重启也不清理（`Spool` 无启动清扫、无注册表）。收信轮询场景（定时拉 INBOX 并落盘附件）会按封数线性累积磁盘占用，同时把敏感附件内容长期留在临时目录
- **建议**：给 `MailAttachment` 加 `close()`（转发 `part.source()?.close()`）并让 `MailBody` 实现 `Resource` 级联关闭所有附件来源；或让 `MailMessage`/`MimePart` 实现 `Resource` 并提供 `close()` 递归关闭所有 `Data(BodySource)`。若坚持"调用方接管"，则必须在 `MailAttachment` 上暴露 `close()` 且 README/类注释显式写明「不 close 会残留临时文件」

### [一般] 2. `Email.delete`（IMAP）用 UID→序号的映射结果发 `STORE`，存在 TOCTOU，会误标别的邮件

- **位置**：`f_email/src/EmailFacade.cj:400-405`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（检查-然后-写入非原子 / 数据错误）
- **证据**：静态确定
- **描述**：先 `uidFetch(SequenceSet.single(uid))` 拿到 `located[0].sequence`，再 `store(SequenceSet.single(sequence), Add, ["\\Deleted"])`——这是两个独立往返。中间若有其它客户端（同一账号的手机端/网页端）`EXPUNGE` 掉前面某封，序号整体前移，`STORE` 就会把 `\Deleted` 打到另一封邮件上。随后 `uidExpunge(mail.id)` 只清目标 UID，所以误标的邮件本次不会被删，但它已被打上删除标记：本端后续任何 `expunge()` 或其它客户端的 `EXPUNGE` 都会真的删掉它（数据丢失）。IMAP 本身有 `UID STORE`，不需要这个映射
- **建议**：在 `ImapClient` 增加 `uidStore(set, operation, flags, silent)`（`UID STORE`），门面直接用 `UID STORE <uid> +FLAGS (\Deleted)` 再 `UID EXPUNGE <uid>`；若要保留序号路径，至少在 `STORE` 前重取一次并校验 `uidFetch` 的 UID 仍等于 `mail.id`，不一致则重试或抛错

### [一般] 3. `Email.list`（IMAP）在服务器未返 UID 时用序号顶替 `id`，后续 UID 命令会命中另一封

- **位置**：`f_email/src/EmailFacade.cj:282-285`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（边界/契约不符：`id` 语义在 `MailSummary` 注释里定义为 UID）
- **证据**：静态确定（回退逻辑）／触发条件待确认（需服务器在请求 `UID` 后仍省略该字段）
- **描述**：`MailSummary` 的类注释（`EmailFacade.cj:49-51`）承诺「`id` 在 IMAP 下是 UID（跨会话稳定）」，但这里 `case None => item.sequence` 直接把序号塞进 `id`。之后的 `fetch`（:356）与 `delete`（:400）都用 `SequenceSet.single(mail.id)` 发 `UID FETCH`/`UID FETCH`+`UID EXPUNGE`，序号被当成 UID 用，命中同一邮箱里的另一封邮件。属于"降级后仍按原契约使用"的静默契约破坏
- **建议**：`uid` 缺失时抛 `MailProtocolException("服务器未返回 UID")`，或把摘要标记为不可用（去掉回退分支）；不要用一个不同语义的值填充同一字段

### [一般] 4. IMAP/POP3 登录失败时连接不关闭：门面丢弃已建连的客户端，fd 与 TLS 资源泄漏

- **位置**：`f_email/src/EmailFacade.cj:528-535`（IMAP）、`f_email/src/EmailFacade.cj:555-562`（POP3）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（资源不对称：异常跳过释放）
- **证据**：静态确定（错误路径无 `close`）／是否由 GC 兜底取决于 `std.net` 实现，待确认
- **描述**：`builder.build()` 已按规格完成 TCP 连接（`specs/email-imap/spec.md:190`「`build()` SHALL 只完成 TCP 连接…MUST NOT 登录」），随后 `built.login(...)` 才认证。密码错误是最常见的路径：`login` 抛 `MailAuthException` 后，`built` 只是局部变量，没有 `close()`，也没进 `imapValue`/`pop3Value`；`ImapClient`/`Pop3Client` 都没有终结器。门面又被写成"配置错误/认证错误反复重试"的典型用法（`send`/`list` 每次都会重试建连），每失败一次泄漏一条 socket（TLS 模式下还有 TLS 会话内存）。另外 `imapClient`/`pop3Client` 把「`user` 是否配置」的校验放在 `build()` **之后**（:529-532、:556-559），配置缺失时同样漏一条已建连的连接
- **建议**：`build()` 之后用 `try { built.login(...) } catch (e) { built.close(); throw e }`；并把 `user`/`secret` 的存在性校验提前到 `build()` 之前（与 `smtpClient` 的 host 校验风格一致）

### [一般] 5. `Email.delete`（POP3）`quit()` 失败时缓存未清空，与注释承诺的"自动重连"相反

- **位置**：`f_email/src/EmailFacade.cj:406-411`（对应注释承诺在 `:389-391`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（错误处理 / 契约与注释不符）
- **证据**：静态确定 —— `Pop3Client.quit()`（`src/pop3/Pop3Client.cj:423-445`）在 `finally` 里 `closedFlag = true; connection.close()`，随后若 `!ok` **抛出** `MailProtocolException("QUIT 未得到 +OK…")`；`pop3Value = None` 位于下一行，异常路径被跳过
- **描述**：`QUIT` 没有拿到 `+OK`（网络抖动、服务器拒绝）时，`quit()` 已经关掉连接并抛出，`pop3Value` 仍指向这个已关闭的客户端。下一次 `list`/`fetch`/`delete` 走 `pop3Client()` 的 `Some(client)` 分支，直接拿到已关闭实例，从此该 `Email` 实例上所有 POP3 操作都失败——而方法注释明确写着「会话随之结束，下一次操作会自动重连」
- **建议**：`pop3Value = None` 放进 `finally`（或在 `catch` 里先清空再重抛）；同时让 `pop3Client()` 在命中缓存时判 `client.isClosed()`，已关闭则丢弃重建

### [一般] 6. `Email.delete`（IMAP）不检查 `UIDPLUS`：先打 `\Deleted` 再失败，留下半完成状态

- **位置**：`f_email/src/EmailFacade.cj:404-405`（依赖 `src/imap/ImapClient.cj:938-941` 的 `requireCapability("UIDPLUS")`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（错误处理缺失 / 部分失败未定义）+ §14（半成品分支）
- **证据**：静态确定
- **描述**：删除流程是「`STORE +FLAGS \Deleted`（已成功、已改变服务器状态）→ `UID EXPUNGE`（需要 `UIDPLUS`）」。未广告 `UIDPLUS` 的服务器上第二步必抛 `MailProtocolException`，此时邮件已被打成删除标记：门面抛异常告诉调用方"删除失败"，但服务器状态已变，且没有任何回退（`EXPUNGE` 全量清除会连带删掉别人标删的邮件，属于设计明确拒绝的行为）。方法注释只写「按 UID `EXPUNGE`，只删这一封」，没提 `UIDPLUS` 前置条件
- **建议**：删除前用 `imap.capabilities.supportsUidPlus` 判定：无 `UIDPLUS` 时不发 `STORE`，直接抛带 `capability=UIDPLUS` 的 `MailProtocolException`（保持服务器状态不变）；或在注释与 README 中写明该前置条件，并把"已标删未清除"作为可断言的结果返回

### [一般] 7. `MailAttachment.read()/open()/size()` 对文本附件返回 UTF-8 重编码字节，注释声称"按声明的字符集重新编码"

- **位置**：`f_email/src/EmailFacade.cj:183-185`（`rawText()`）、`:136`、`:127`（被 `read`/`open`/`size` 复用）；注释在 `f_email/src/EmailFacade.cj:92-97`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（语义与注释不符 / 契约与实现不符）
- **证据**：静态确定 —— `MimePart.text()`（`src/model/MimePart.cj:133-147`）按 `contentType.charsetName()` 解码成 `String`；`String.toArray()` 是 UTF-8 字节（仓内同一约定见 `MimeWriter.cj:77-81`、`LineChannel.cj:302`、`SmtpAuth.cj:74-77`）；实现里**从未**使用 `contentType.charsetName()` 反向编码
- **描述**：小于 `inlineTextLimit`（256 KB）的 `text/*` 正文在解析阶段被解码成 `PartBody.Text(String)`，因此 `text/plain; charset=gb2312` 的 `.txt`/`.csv` 附件必然走这条路径。`read()`/`saveTo()` 写出的字节是该字符串的 UTF-8 编码，与原邮件字节不同，而 `mediaType`/`Content-Type` 仍向调用方声明 `charset=gb2312`；按声明字符集打开落盘文件的消费方（Excel、老编辑器）会看到乱码。类注释「这里按声明的字符集重新编码取字节」与实现相反，`size` 也相应返回 UTF-8 字节数而非原始附件字节数
- **建议**：二选一并把注释改对——(a) 语义定为"文本按 UTF-8 输出"，注释与 `mediaType` 说明同步（推荐，简单）；(b) 真要还原原始字节，则 `Text` 分支必须保存解码前的原始字节（或在 `MimePart` 记录 `charsetUsed` 后用同一字符集重编码），并在 `MailAttachment` 文档里写明该转换

### [一般] 8. `MailAttachment.filename` 直接透传不可信 `Content-Disposition`，门面未净化也未警告

- **位置**：`f_email/src/EmailFacade.cj:100`、`:106-118`；风险落点在 `:158`（`saveTo`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §10（安全性：外部输入未校验）、§11（路径穿越）
- **证据**：静态确定
- **描述**：`filename` 来自 `disposition.filename()` 或 `contentType.name()`，可以是 `../../../etc/cron.d/x`、绝对路径、`..\\..\\x` 或含 NUL/控制字符；类注释（:95-96）只谈二进制与文本差异，没有任何"该值不可信"的提示。`MailAttachment.saveTo(path)` 本身接调用方给的 `Path`（安全），但公开字段的自然用法是 `saveTo(dir.join(attachment.filename))`——README:76 的示例正是这个写法，等于把路径穿越交给每个调用方自行防范。设计文档 `doc/spec/add-f-email-client/design.md:14` 已明确「附件 `filename` 是不可信输入，绝不能参与路径」，该立场只落实在 `Spool` 内部，没有落实到公开字段
- **建议**：新增 `MailAttachment.safeFilename()`（去掉路径分隔符、`..` 段与首部点、限制长度、拒绝控制字符）并在注释中推荐用它拼路径；或在 `filename` 的文档注释首句写明「不可信，拼路径前必须净化」。不要静默改 `filename` 的语义（调用方可能要用原名做展示）

### [一般] 9. 门面无法注入 `tlsConfig`，SMTP 认证写死 `LOGIN`：自签 CA 与仅 `XOAUTH2` 的服务器经 `Email` 不可用

- **位置**：`f_email/src/EmailFacade.cj:495-505`（`smtpClient`，`:504` 写死 `SmtpAuthMechanism.Login`）、`:655-781`（`EmailBuilder` 全量 12 个配置开关 + `build`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §14（接线缺失 / 承诺了但没接通）+ §13（规格与实现漂移）
- **证据**：静态确定 —— 底层 builder 已具备 `tlsConfig`（`src/smtp/SmtpClientBuilder.cj:58`、`ImapClient.cj:1678`）、`oauth2`（`SmtpClientBuilder.cj:70`）、`sendPolicy`（`:97`）、`maxMessageBytes`（`:102`）、`precomputeSize`（`:107`）、`helloName`（`:77`）、`dsn`（`:112`）；`EmailBuilder` 一个都没暴露
- **描述**：`EmailBuilder` 只暴露 host/port/tls 模式/auth/timeouts/allowPlaintextAuth/requireEncryption/transport，缺 7 个底层开关。直接后果有三条，且都有承诺源：① `doc/spec/add-f-email-client/design.md:400`「不通过时的退路：调用方注入 `TlsClientConfig` + 自签 CA」在门面上做不到，自签/私有 CA 的内网邮件服务器只能绕开门面改用 `ImapClient`/`SmtpClient`；② `specs/email-smtp/spec.md:62-64` 要求支持 `XOAUTH2` 且"未指定机制时按 `XOAUTH2 > CRAM-MD5 > PLAIN > LOGIN` 自动选择"，门面固定 `Login`，只广告 `XOAUTH2` 的服务商直接认证失败；③ `maxMessageBytes`/`precomputeSize`/`sendPolicy` 不可配，门面用户无法在 `MAIL FROM` 前做大小预检或改用 `AllOrNothing`
- **建议**：`EmailBuilder` 增加 `tlsConfig(TlsClientConfig)`、`oauth2(user, token)`、`sendPolicy(SendPolicy)`、`maxMessageBytes(Int64)`、`precomputeSize(Bool)` 的透传（`EmailConfig` 同步加字段），并把 `smtpClient()` 改成"配了 token 走 `oauth2`，否则不指定机制、交给底层自动选择"

### [一般] 10. `Email` 的可变连接状态无同步，类注释也没有"非线程安全"声明

- **位置**：`f_email/src/EmailFacade.cj:213-221`（`smtpValue`/`imapValue`/`pop3Value`/`selectedMailbox`/`selectedReadOnly`/`closedFlag`）、`:249-315`（`list` 的检查-然后-使用）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入）
- **证据**：静态确定（无锁/无原子/无 `synchronized`）／共享路径待确认（取决于调用方是否共享单实例）
- **描述**：类注释（:201-212）只讲懒连接与摘要定位，没有任何线程约束；而它明显是给"应用级单例"设计的（懒连接、缓存三条连接、当前邮箱游标）。共享一个实例时的具体路径：`list(mailbox:)` 内部是 `ensureMailbox(imap, mailbox)` → `imap.messages` → `imap.fetch(range(from,total))` 三步，线程 A 在这三步之间，线程 B 的 `ensureMailbox` 会改写 `selectedMailbox` 并发出 `EXAMINE 其它邮箱`，A 随后按 A 邮箱算出的序号去 fetch B 邮箱——静默返回另一个文件夹的邮件。`smtpValue`/`imapValue` 的懒初始化同样无保护：两个线程同时首次调用会各建一条连接，后写者覆盖前者，前者泄漏
- **建议**：短期在类注释与 README 明确「`Email` 非线程安全，每线程一个实例（或用外部互斥包起来）」；中期给连接与 `selectedMailbox` 加一把实例锁，把 `ensureMailbox + messages + fetch` 整体纳入临界区（协议本身串行，锁粒度大不增加竞争），或在内部用"邮箱游标 + 连接序号"做一次快照校验

### [一般] 11. `Email.close()` 三处 `catch (_: Exception) {}` 静默吞掉关闭异常

- **位置**：`f_email/src/EmailFacade.cj:428-430`、`:436-438`、`:444-446`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3（静默吞异常）+ §11（错误处理缺失）
- **证据**：静态确定
- **描述**：三个 `client.close()` 的异常全部被丢弃且无注释说明为什么可以空。`close()` 是协议层唯一可能暴露"服务器拒绝 `QUIT`/`LOGOUT`、连接已半关闭"的地方；吞掉后调用方既拿不到诊断，也无法判断删除是否提交（POP3 的 `QUIT` 语义尤其依赖这一点，`Email.delete` 走的是显式 `quit()`，但用户直接 `close()` 时会被静默丢弃）
- **建议**：至少用 `f_log` 记一条 warn（含协议名与异常 message），或在 `close()` 上返回/聚合一个 `Array<String>` 警告；若要严格按"`close()` 幂等且不抛"的规格，就在注释里写明"关闭失败只记日志、不向上抛"的理由

### [一般] 12. `Email.fetch/body/text` 无法传 `MimeParseOptions`：`spoolDir`、`inlineTextLimit`、`maxBodyBytes` 在门面上全是死配置

- **位置**：`f_email/src/EmailFacade.cj:349-364`（`fetch`）、`:367-374`（`body`）、`:382-384`（`text`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §14（接线缺失：配置项被读取却无法设置）
- **证据**：静态确定 —— `imap.uidFetchMessage(...)`（:356）与 `pop3.retrMessage(...)`（:362）都走默认 `MimeParseOptions()`；`EmailBuilder` 无对应开关
- **描述**：`MimeParseOptions` 暴露了 `spoolDir`、`inlineTextLimit`、`spoolThreshold`、`maxBodyBytes`、`maxDepth`、`maxParts`（`src/mime/MimeOptions.cj:30-50`），但门面不透传。后果：① 需要把附件临时文件放到指定目录（容器里 `/tmp` 是内存盘、或只挂了一个可写卷）时做不到；② 想给不可信来源收紧 `maxBodyBytes`/`maxParts` 时做不到；③ 与上一条"临时文件不释放"叠加时，落点完全由 `TMPDIR` 决定，运维无法控制
- **建议**：`EmailBuilder.mimeOptions(MimeParseOptions)`，`fetch/body/text/attachments` 增加 `options!: MimeParseOptions` 可选参数并透传到底层；默认值保持与现在一致以兼容

### [轻微] 13. 未使用的 `import`：`Charsets`

- **位置**：`f_email/src/EmailFacade.cj:21`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 全文件搜 `Charsets` 只有 import 行本身（`grep -n "Charsets" src/EmailFacade.cj` → 仅 :21），字符集解码都在 `MimePart`/`CharsetResolver` 里
- **描述**：门面不做字符集解析，这个 import 是早期实现残留，会在编译期产生未使用 import 告警
- **建议**：删除该行

### [轻微] 14. `ImapCapabilities.toString()` 没有实现 `ToString`，无法用于插值与日志

- **位置**：`f_email/src/imap/ImapCapabilities.cj:28`（`public struct ImapCapabilities {`）、`:217-228`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §10（仓颉语言特性：接口实现）
- **证据**：静态确定 —— 结构体声明没有 `<: ToString`，`toString()` 只是普通成员方法；仓颉的 `"${x}"`/`println(x)` 走 `ToString` 接口
- **描述**：`toString()` 与 `raw` 的语义重复（空格拼接原始能力表），但因为没有实现接口，`"caps=${client.capabilities}"` 编译不过，日志与异常消息里只能自己拼。同模块的 `ReceiveProtocol`（`EmailFacade.cj:34`）走的是 `<: ToString`，风格不一致
- **建议**：改成 `public struct ImapCapabilities <: ToString` 并保留现有 `toString()` 实现（签名已匹配）；若只是想内部调试用，就把它改成 `private func` 并删除，避免对外暴露一个"看起来像标准接口"的方法

### [轻微] 15. `ImapCapabilities.hasPrefix` 把"完全相等"排除在外

- **位置**：`f_email/src/imap/ImapCapabilities.cj:63`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（边界差一）
- **证据**：静态确定 —— `entry.size > wanted.size && entry[0..wanted.size] == wanted`
- **描述**：判据要求前缀**比条目短**，所以 `hasPrefix("SORT")` 对 `raw == ["SORT"]` 返回 `false`，只有 `["SORT=DISPLAY"]` 才为 `true`。名字叫 "hasPrefix" 却漏掉相等情形，调用方若用它做"SORT 系列能力是否可用"的判定会漏掉只广告 `SORT` 的服务器。仓内目前无引用（`grep hasPrefix` 仅定义处），属对外 API 语义问题
- **建议**：改成 `entry.size >= wanted.size && entry[0..wanted.size] == wanted`，并在注释里写明"含相等"

### [轻微] 16. 关闭后统一抛 `MailIoException(IoStage.Read)`，写路径也用 `Read`，且与设计文档的错误映射不一致

- **位置**：`f_email/src/EmailFacade.cj:458-462`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（语义与注释/规格不符）
- **证据**：静态确定 —— `doc/spec/add-f-email-client/design.md:343` 的映射是「已关闭连接上操作 → `MailProtocolException("client is closed")`」；实现抛 `MailIoException(IoStage.Read, "Email 已关闭")`，且 `send`（写）也走同一分支
- **描述**：调用方若按设计文档的异常表写 `catch (MailProtocolException)` 来识别"客户端已关闭"，会漏掉这个分支；`IoStage.Read` 用于发送场景也让 `isRetryable` 分类失真（`Read` 阶段被当作网络可重试，实际是本地状态错误）
- **建议**：改成 `MailProtocolException`（与协议层一致），或新增一个明确的"已关闭"阶段值；至少让写路径用 `IoStage.Write`

### [轻微] 17. `Email.list`（POP3）强依赖 `TOP`，无该能力时整个列举失败且注释未说明

- **位置**：`f_email/src/EmailFacade.cj:328`（`pop3.topMessage(info.number, 0)`），注释在 `:243`、`:248`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（契约/限制未写）+ §11（错误处理）
- **证据**：静态确定 —— `specs/email-pop3/spec.md:71-72` 规定「能力表无 `TOP` 时 MUST 抛 `MailProtocolException`」；门面对 `limit` 封邮件逐封调用 `topMessage`，第一封就会抛
- **描述**：`list()` 的注释只写"列举最近 N 封"，没写"POP3 需要服务器支持 `TOP`"。老服务器（`CAPA` 无 `TOP`）上 `Email.list` 直接抛异常，且没有降级路径（本可以 `RETR` 只读头部直到空行，代价是每封多传正文）
- **建议**：注释补上前置条件；或按能力降级：无 `TOP` 时用 `retr(message, sink)` 读到头部分隔符即停，并记一条 warn

### [轻微] 18. 重复逻辑：`MailAttachment.read()` 与 `MimePart.readAll()` 是同一个"流→`ArrayList<Byte>`"循环

- **位置**：`f_email/src/EmailFacade.cj:141-155`、`f_email/src/model/MimePart.cj:202-216`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（只改常量/类型的重复实现）
- **证据**：静态确定 —— 两段都是「`Array<Byte>(N, repeat: 0)` → `read` → `for (i in 0..n) out.add(buffer[i])` → `toArray()`」，唯一差异是缓冲 64 KB vs 8 KB；`EmailFacade` 已 `import fountain::f_email.model.*`，`readAll` 是 `internal static`
- **描述**：同一"把流抽干成字节数组"的语义写了两份，后续修 bug（例如改成按块 `copyTo`、加大小上限）要改两处，`MailAttachment.read()` 还多放了 64 KB 常量
- **建议**：`MailAttachment.read()` 直接调 `MimePart.readAll(open())`，或把该工具函数提升为 `model` 里的公共 `util`（`f_email` 是叶子模块，不违反分层）

### [轻微] 19. 重复逻辑：三个 client 工厂与 `close()` 的三段 match 逐行对应

- **位置**：`f_email/src/EmailFacade.cj:487-510`、`:512-537`、`:539-564`（工厂）；`:426-449`（close）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（只改类型名的重复）
- **证据**：静态确定 —— 三个工厂结构完全一致：取 host → `isNone` 抛 `IllegalArgumentException` → `XxxClient.builder(host, port: p)` → `.tls/.timeouts/.requireEncryption/.allowPlaintextAuth` → 可选 `.transport(...)`；`close()` 里三段 `match (xxxValue) { Some(client) => try { client.close() } catch … ; xxxValue = None }` 也逐行对齐
- **描述**：差异只有两处且是有意的（SMTP 在 `build()` 内认证、IMAP/POP3 在 `build()` 后 `login`；凭据缺失时的错误文案不同）。这类"每协议一段"的重复会让新增协议（或给三家统一加一个开关，如本报告提到的 `tlsConfig`）必须改三遍——上面的 `tlsConfig` 缺口就是重复结构带来的漏改
- **建议**：抽一个 `connectCommon(kind, host, port, transport, tls, timeouts)` 之类的私有辅助（返回已配好的 builder 或统一做 host/凭据校验），把三处差异化成参数；`close()` 抽 `closeClient(?Resource)` 一个私有函数供三处调用

### [轻微] 20. `MailAttachment.read()` 逐字节 `add` 进 `ArrayList<Byte>`，比块拷贝多一个量级的常数

- **位置**：`f_email/src/EmailFacade.cj:144-154`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §6.4（已有块拷贝能力却用逐元素循环）
- **证据**：静态确定（实现形态）；收益需实测
- **描述**：输入规模 = 附件字节数 n，实现是 n 次 `out.add(buffer[i])` + `ArrayList` 的多次扩容复制；同文件 `saveTo`（:172-176）已经给出写法（`Array<Byte>(n, repeat:0)` + 下标拷贝 + 一次 `write`）。10 MB 附件对应 1000 万次 `add`，相对块拷贝是纯常数开销，还会让 `ArrayList` 内部数组反复翻倍复制
- **建议**：按块 `buffer[0..n].copyTo` 到目标数组（预知总长时）或直接 `out.add(all: buffer[0..n])` 一次性追加，消除逐字节循环

### [轻微] 21. 验收文档 G5 声称"part 数量炸弹 ✅"，但证据列只有深度用例，同文件末尾又把它列为待补

- **位置**：`f_email/doc/spec/add-f-email-client/verification.md:49`（G5 表行）与 `:100`（剩余 WARNING 列表）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（文档自述与证据不一致）
- **证据**：静态确定 —— `grep -rn "maxParts" f_email/src --include=*_test.cj` 为 0 命中；G5 该行给的证据是 `MimeParser_test.depthLimitIsEnforced` 与 `ImapParser_test.rejectsDeepNesting`，两者都只覆盖深度；:100 明确写「`maxParts` 炸弹」属于"记录为后续"
- **描述**：同一份验收记录里，"part 数量炸弹通过"与"maxParts 炸弹尚未覆盖"并存。代码侧限制是实现了的（`src/mime/MimeParser.cj:107-108`），所以这不是功能缺失，而是验收结论被高估——后续读者会以为已有 10 万 part 的回归保护
- **建议**：把 G5 该行拆成"深度炸弹 ✅（用例名）/ part 数量炸弹 未覆盖（计划用例名）"，或补一个 10 万 part 的用例后再标 ✅

> 存量合计 21 条（严重 1 / 一般 11 / 轻微 9），是否纳入修复待用户决定。

<!-- 第 3 部分 -->

### [严重][存量] `ImapMove` 的非原子回退丢掉 UID/序号语义：`uidMove` 回退时用序号语义的 `STORE` 打 `\Deleted`

- **位置**：`f_email/src/imap/ImapMove.cj:118-128`（`nonAtomicMove`；关键行 `:120` `uidCopy`、`:121` `store`、`:124` `uidExpunge`）；调用方 `:71-76`（`moveInternal` 的 `prefix` 参数在回退分支被丢弃，`:114`）
- **来源**：存量（`git blame` → `b555d80162`，2026-10-29 引入 MOVE 扩展；工作区无改动）
- **判据**：review-checklist §11「边界 / 语义与命名不符」；§12.1 无关；§5 无关。核心是「同一份 `SequenceSet` 被两种语义解释」
- **证据**：静态确定 —— `nonAtomicMove` 签名只有 `(set, mailbox)`，没有 `prefix`。三行命令分别是：`UID COPY <set>`（`:120`，`set` 当 **UID**）、`STORE <set> +FLAGS.SILENT (\Deleted)`（`:121`，`set` 当 **序号**）、`UID EXPUNGE <set>`（`:124`，`set` 当 **UID**）。`ImapExt_test.cj:435-444` 的用例 `nonAtomicFallbackRunsThreeStepsInOrder` 走的是 `uidMove`，并在 `:440` 断言线上文本为 `STORE 1:2 +FLAGS.SILENT (\Deleted)`——即把「UID 集合按序号打标记」写成了期望行为。
- **描述**：`uidMove(SequenceSet.range(1,2), "Archive", allowNonAtomic: true)` 在无 `MOVE` 能力的服务器上会：①按 UID 复制正确的两封到 Archive；②按**序号** 1、2 给邮箱里最前面两封邮件打 `\Deleted`（这两封未必是被移动的那两封）；③按 UID 删掉真正要移动的两封。结果是「移动是对的，但凭空给两封无关邮件打了删除标记」，下一次任何 `EXPUNGE` / `CLOSE`（`ImapClient.closeMailbox` 明确会静默删除 `\Deleted`）就会真的删掉它们。反向也一样：`move(set)`（序号语义）走回退时，`UID COPY` 会把序号当 UID 去复制，可能复制错或直接无效。这是数据破坏级缺陷，且被测试固化。
- **建议**：`nonAtomicMove` 接收 `prefix`（或 `uidMode: Bool`），三步统一语义——UID 模式用 `UID COPY` / `UID STORE` / `UID EXPUNGE`，序号模式用 `COPY` / `STORE` / `EXPUNGE`；`ImapClient.store` 增加 `uid!: Bool` 或新增 `uidStore(set, ...)`（内部拼 `UID STORE`），不要靠调用方拼前缀。同步修正 `ImapExt_test.cj:435-444` 的断言。

### [严重][存量] IDLE 的 `done()` 与 25 分钟自动重建都会写 `DONE`，两者只共享 `doneSent` 一半状态——存在重复 `DONE` 导致协议错位

- **位置**：`f_email/src/imap/ImapIdle.cj:178-193`（`done()` 在 `writeMutex` 内按 `doneSent` 写一次 `DONE`）与 `:262-292`（`rebuild()` 无条件写 `DONE`，随后 `:289-292` 再发 `<tag> IDLE`）
- **来源**：存量（`git blame` → `b555d80162`，2026-10-29）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入」；§6.2「锁内调用外部回调」不适用
- **证据**：静态确定 ——
  - 写 `DONE` 的两处：`done()` 由调用线程执行（`ImapExt_test.cj:638` 甚至从 `spawn` 的子线程调用），受 `doneSent` 保护；`rebuild()` 由读线程在执行流里调用（`:218-220`），**完全不看 `doneSent`**，只拿 `writeMutex` 保证「一次只写一行」。
  - 触发窗口：读线程判定 `MonoTime.now() - lastRoundStart >= rebuildAfter`（`:218`）→ 进入 `rebuild()` 写出 `DONE` → 在 `:271-288` 等 tagged 回复。此时另一线程调用 `done()`：先置 `stopRequested`（`:180`），再在 `:182-190` 写第二个 `DONE`（`doneSent` 仍为 false）。
- **描述**：服务器收到两个 `DONE`，第二个处于非 IDLE 上下文，回 `BAD`。`rebuild()` 的「等 tagged」循环（`:271-288`）会把第一个 tagged（`OK IDLE terminated`）吃掉并 `break`，随后发 `<新 tag> IDLE` 并在 `:293-306` 死等 `+`，实际读到的是 `BAD` 与第二个 tagged 回复——该循环只认 `+`，会一直读下去；`done()` 侧 `valJoin()` 10 s 超时后照样 `markIdle(false)`（`:191-192`）。最终连接上残留一个未消费的 tagged 回复，下一条命令的 `collect()` 会因「收到不匹配的 tag」抛 `MailProtocolException`（`ImapClient.cj:1154-1155`），连接报废。长连收信场景（IDLE 常驻 + 运营侧定时 `close()`）踩中的概率不低。
- **建议**：把「IDLE 是否已结束」收敛成一个状态机并纳入同一把锁：`done()` 与 `rebuild()` 都必须在 `mutex` 内检查/置位 `doneSent`（`rebuild` 复用同一个标志位，或在 `stopRequested` 时直接放弃重建），`rebuild()` 读到 `stopRequested` 立即返回且不再发新 `IDLE`；`writeMutex` 只负责写序，不承担状态判定。补一条并发用例：重建窗口内并发 `done()`，断言线上 `DONE` 只出现一次、且之后连接仍可发命令。

### [一般][存量] `valReset()` 漏重置 `UNSEEN` / `FLAGS` / `PERMANENTFLAGS`：换邮箱 `SELECT` 后 `MailboxStatus` 会带出上一个邮箱的值

- **位置**：`f_email/src/imap/ImapClient.cj:959-965`（`valReset` 只清 5 个字段）；透传点 `:462-473`（`MailboxStatus(... unseen: mailboxUnseen, flags: mailboxFlags, permanentFlags: mailboxPermanentFlags)`）；赋值点 `:1257-1275`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「空值未处理 / 语义与契约不符」；§9 无关
- **证据**：静态确定 —— `valReset()` 只重置 `mailboxExists` / `mailboxRecent` / `mailboxUidValidity` / `mailboxUidNext` / `mailboxHighestModSeq`，`mailboxUnseen`（`:132`）、`mailboxFlags`（`:133`）、`mailboxPermanentFlags`（`:134`）保持上次的值。而 RFC 3501 的 SELECT 必需响应只有 `FLAGS` / `<n> EXISTS` / `<n> RECENT` / `OK [UIDVALIDITY]` / `OK [UIDNEXT]`(UIDPLUS) / `OK [PERMANENTFLAGS]`，**`[UNSEEN n]` 是可选项**。
- **描述**：`client.select("INBOX")`（服务器回了 `[UNSEEN 17]`）→ `client.select("Archive")`（服务器没回 `[UNSEEN]`）→ 返回的 `MailboxStatus.unseen == Some(17)`，且 `client.messages` 之外的 `flags` 也可能是上一个邮箱的。调用方据此算「未读数」会拿到别的邮箱的数字，且不会有任何错误信号。`EXAMINE` 同样受影响。
- **建议**：`valReset()` 一并清 `mailboxUnseen = None`、`mailboxFlags = []`、`mailboxPermanentFlags = []`（或改名为 `valResetMailboxState()` 并在 `selectInternal` 里显式列出全部 8 个字段），单测断言「第二次 SELECT 缺 `[UNSEEN]` 时返回 `None`」。

### [一般][存量] `uidExpunge()` 调用 `valReset()` 把 `EXISTS` 等状态清零：之后 `client.messages` 报 0

- **位置**：`f_email/src/imap/ImapClient.cj:938-945`（`:941` `valReset()`）；`messages` 属性 `:220-224`；`applyUntagged` 的递减逻辑 `:1204-1210`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「与规格 / 语义不符」；§10 正确性
- **证据**：静态确定 —— `UID EXPUNGE` 只删指定的 UID，不会让「邮箱里还剩几封」变成 0。`valReset()` 后 `mailboxExists = 0`；随后 `collect()` 对每条 `* n EXPUNGE` 只在 `mailboxExists > 0` 时递减（`:1207-1209`），所以整轮下来 `mailboxExists` 恒为 0。`uidValidity` / `uidNext` / `highestModSeq` 也被一并丢成 `None`，而 UID EXPUNGE 并不改变 UIDVALIDITY / HIGHESTMODSEQ。
- **描述**：`uidExpunge` 之后读 `client.messages` 得到 0、读 `highestModSeq` 得到 `None`，直到下一次 `SELECT`/`STATUS` 才恢复。同步器若用 `messages` 做范围裁剪，会认为邮箱空了。
- **建议**：`uidExpunge` 不该调 `valReset()`；把 `valReset()` 的作用域收窄成「`SELECT` 前清状态」，`EXISTS` 由 `applyUntagged` 按 `* n EXPUNGE` 递减即可（`expunge()` 就是这么做的）。

### [一般][存量] 非 FETCH 响应里的 literal 无人消费：`collect()` 只按行读，`LIST` / `NAMESPACE` 遇到 `{n}` 邮箱名会把后续字节当命令行解析

- **位置**：`f_email/src/imap/ImapClient.cj:1142-1161`（`collect` 循环只 `readLineOrThrow` + `ImapResponse.parse`）；`:499-516`（`listInternal` 走 `execute`）；`f_email/src/imap/ImapParser.cj:89-91`、`:120-146`（`{n}` 只产出 `Literal` token，字节留给调用方）；对照实现 `ImapClient.cj:636-675`（FETCH 专门按 literal 长度读字节）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「协议契约与实现不符 / 错误处理缺失」；§2「近似重复，其中一块少了边界判断」（FETCH 路径有 literal 支持，通用路径完全没有）
- **证据**：静态确定 —— `ImapParser` 的注释明确写「`{n}` 只是长度标记，字面量字节在 CRLF 之后，必须留给调用方去读」（`ImapParser.cj:31`），但 `collect()` 拿到的下一条 `readLine()` 正是这些裸字节；`ImapResponse.parse` 会把它们当命令/响应行解析。
- **描述**：邮箱名非 ASCII 且未 `ENABLE UTF8=ACCEPT` 时，多家服务器（Dovecot、Exchange 的部分配置）会用 literal 返回 `* LIST (\HasNoChildren) "/" {12}` + 12 字节名 + `)`。这一行进入 `collect()` 后：下一条 `readLine()` 读到的是名字的前若干字节（其中可能含 `\r\n` 以外的任意字节），`ImapResponse.parse` 大概率抛 `MailProtocolException("IMAP 带 tag 响应缺少状态")` 或把垃圾当 untagged；即使侥幸不抛，真正的 `)` 与 tagged 回复的顺序也已错位。同类风险在 `NAMESPACE`（`:80` 走 `execute`）、`STATUS`、`APPEND` 的响应侧（少见但合法）。
- **建议**：在 `collect()` 里检测「行尾是否以 `{n}` 结束」（`ImapParser` 已在 token 流里给出 `Literal`/`LiteralPlus`），若是则 `readExact(n)` 消费掉并把它作为该条响应的一部分（或直接拒绝该命令并明确报「该服务器用 literal 返回，需 `ENABLE UTF8=ACCEPT`」）。更彻底的做法是把「按行读 + 按 literal 续读」抽成一个共用的 `readResponseLine()`，让 FETCH 与通用路径复用同一实现（同时消掉 §2 的近似重复）。补一条 ScriptedTransport 用例：`* LIST (\HasNoChildren) "/" {5}\r\nSent\r\n` → `A0003 OK`。

### [一般][存量] 非流式 literal 路径把整段正文拷贝三份，并逐字节往 `ArrayList<Byte>` 里塞

- **位置**：`f_email/src/imap/ImapClient.cj:710-717`（`valReadLiteralBytes` → `Array<Byte>(count)`）、`:663-665`（`for (b in ...) { bodyBytes.add(b) }`）、`:676-680`（`bodyBytes.toArray()` 再拷一份）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §5「一次性物化」、§7「删除中间副本」、§8「减少分配与 GC 压力」；`mem §2.2 / §5.3`
- **证据**：静态确定（拷贝份数可由代码数出）——单条 literal 的生命周期里同时存在：①`LineChannel.readExact` 返回的 `Array<Byte>(count)`（最大 `maxLiteralBytes` = 64 MB，`ImapClient.cj:1665`）；②`bodyBytes` 内部数组（逐条 `add`，扩容时再翻倍复制）；③`bodyBytes.toArray()` 的最终副本，随后 ① 与 ② 才可回收。`fetchMessagesInternal`（`:804-818`）随后又把 ③ 交给 `MimeParser` 解析，解析期 ③ 仍然存活。
- **描述**：一封 20 MB 正文的邮件，取正文阶段的瞬时峰值约为 60 MB（3 × 20 MB），且 ② 阶段是「每字节一次 `add`」的 O(n) 高常数循环。集合级 `fetchMessage(SequenceSet.all())` 还会把每条 `MailMessage` 累积在 `out`（`:810-817`），聚合上界是 `Σ body`——**单条**有 64 MB 上限，**整批没有**上限。按「16 GB 堆 + 每封 20 MB」，约 800 封就会打满。
- **建议**：①`valFetchStreamInto` 的非 sink 分支直接保留 `valReadLiteralBytes(length)` 的返回值，不做 `ArrayList<Byte>` 中转（多条 literal 需要拼接时用 `Array<Byte>` + `copyTo` 一次成型）；②聚合层面给 `fetchMessagesInternal` 一个 `maxTotalBytes`（或强制走 `fetch(sink)` 重载），超出时明确抛 `MailLimitException`；③文档口径见第 1 部分已列出的「fetchMessage 未走流式」条目，本条的增量信息是「同一份正文被拷了 3 次 + 无聚合上限」。
- **备注**：本条只报「拷贝份数与聚合无界」这一事实，未给降幅结论（无基线，见「待验证假设」）。

### [一般][存量] 无 literal 的 FETCH 响应被报成 `body = Some(空数组)`；多 literal 响应被拼成一块，`section` 只保留最后一个键

- **位置**：`f_email/src/imap/ImapClient.cj:676-680`（`literals = if (streamed) { [] } else { [bodyBytes.toArray()] }`）、`:696-700`（`body: Some(literals[0])`）；`section`/`origin` 赋值 `:1483-1487`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「空集合 / 空串 / `None` 未处理」；§10 正确性（`Option` 语义）
- **证据**：静态确定 —— `bodyBytes` 在无 literal 时是空数组，`literals` 仍是 `[[]]`（size 1），于是 `:696` 取 `Some([])`。对照 `parseFetch`（`:1427-1446`，`store` 走这条）用的是 `if (literals.size > 0)` 且调用方传 `[]`，语义正确——同一语义两处不一致。
- **描述**：`fetch(set, [FetchItem.flags()])` 返回的每条 `FetchResult.body` 都是 `Some(空 Array<Byte>)` 而不是 `None`。调用方用 `body.isSome()` 判断「拿到了正文」时会被误导（例如决定是否入库/落盘），随后解析空字节流。多 literal 场景（同时请求 `BODY.PEEK[HEADER]` 与 `BODY.PEEK[TEXT]`，或 `BODY[1]` + `BODY[2]`）则把两段直接首尾相接成一块，`section` 只保留最后一个响应键（`:1485` 每次覆盖），`origin` 同理——调用方无法把字节切回对应的 part。
- **建议**：无 literal 时 `literals` 取 `[]`（`body = None`），判据用「是否出现过 `Literal`/`LiteralPlus` token」而不是「`bodyBytes` 是否为空」；多 literal 时把 `body` 改成 `Array<Array<Byte>>` 或按 `section` 建映射（`FetchResult` 已是公开结构，需评估破坏性变更），至少不要静默拼接。

### [一般][存量] `ImapMove.copyUidOf` 与 `ImapClient.parseCopyUid` 重复且少了空集合判断：`[COPYUID 1 "" "..."]` 会抛「序号集合不能为空」

- **位置**：`f_email/src/imap/ImapMove.cj:137-150`（`copyUidOf`，`:147-148` 无条件 `Some(SequenceSet(args[1]))`）；对照 `ImapClient.cj:1082-1103`（`parseCopyUid`，`:1092-1101` 有 `args[i].size > 0` 分支）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §2「跨文件复制 / 近似重复，其中一块少了边界判断」；§11「边界未处理」
- **证据**：静态确定 —— 两个函数逐行同构（取 `code()=="COPYUID"`、`args.size < 3` 返回空、`parseNumber(args[0])` + 两个 `SequenceSet`），唯一差异就是 `args[1]/args[2]` 是否允许为空。`SequenceSet.init` 对空串直接 `throw MailProtocolException("序号集合不能为空")`（`ImapFetch.cj:30-35`）。
- **描述**：`MOVE` 的 tagged 回复若为 `OK [COPYUID 1 "" "..."]`（服务器没有可用源 UID 集合的退化写法，或被中间设备改写），`ImapMove.moveInternal` 在解析成功回复时会抛异常，把「移动已成功」报成失败——调用方重试就会二次复制。`ImapClient.copy` 路径不会，因为那边有判空。
- **建议**：删掉 `ImapMove.copyUidOf`，把 `parseCopyUid` 从 `private` 放宽到包内（`func`）供扩展复用——正好顺带解决下一条「错误处理复制」问题的一半。若必须保留两份，至少补齐空串判断。

### [一般][存量] `QResyncParams.toString()` 在「给了 knownSeqs 但没给 knownSeqUids」时生成 `(1:5 )` 这种非法参数

- **位置**：`f_email/src/imap/ImapCondStore.cj:44-57`（`:49-53` 把缺省值取成 `""`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「契约与实现不符」；§10 正确性（可选值组合）
- **证据**：静态确定 —— 三个可选参数只有 `knownUids` 被当作开关（`:46`），`knownSeqs` 一旦有值就无条件拼 `" (${seqs} ${uids2})"`，`uids2` 在 `None` 时是空串。RFC 7162 的 QRESYNC 参数是 `QRESYNC (uidvalidity modseq [known-uids] [(known-seqnums known-uids)])`，括号里必须成对出现。
- **描述**：`QResyncParams(42, 90, knownUids: Some(...), knownSeqs: Some(...))`（漏填 `knownSeqUids`）→ 发出 `SELECT INBOX (QRESYNC (42 90 1:3 (1:5 )))`，服务器回 `BAD`，报错信息只有 `SELECT 失败：...BAD...`，排查成本高。三个字段都是 `public` 且都可单独构造，这种组合很容易被调用方选中。
- **建议**：`toString()` 里改成「`knownSeqs` 与 `knownSeqUids` 必须同时存在，否则不拼该段」或直接 `throw IllegalArgumentException`（构造期校验更好：在 `init` 里拒绝半套参数）。

### [一般][存量] `ImapNamespace.joinPath` 的尾部切片下界可能为负：分隔符比 prefix 长时越界

- **位置**：`f_email/src/imap/ImapNamespace.cj:141`（`prefix[(prefix.size - sep.size)..]`）、`:144`（`name[0..sep.size]`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「边界差一 / 越界」；§10 正确性
- **证据**：静态确定 —— 两个分支只在 `sep.size > 0` 时才走到（`:138-140` 已排除空串），但没有保证 `sep.size <= prefix.size` / `sep.size <= name.size`。`delimiter` 来自服务器 `NAMESPACE` 响应（`parseSegment` 原样保留 `pair[1].text()`，`:113-119`），协议并未限制必须是单字符。
- **描述**：服务器返回 `(("/" "//"))`（或中间设备注入多字符分隔符）→ `joinPath("IN", Some("//"), "Sent")` 在 `:141` 用负下标切片，运行期抛异常（仓颉字符串越界是抛异常而非 UB），把「拼邮箱路径」变成一次未捕获失败。`name` 比分隔符短时（`:144`，例如 `name=""`... 该分支已排除空 `name`，但 `name="/"` + `sep="//"` 仍会越界）同理。
- **建议**：加 `if (sep.size <= prefix.size && prefix[(prefix.size - sep.size)..] == sep)` 与 `if (sep.size <= name.size && name[0..sep.size] == sep)` 的前置长度判断；或统一用 `startsWith`/`endsWith`（若 std 提供，按 `cangjie-doc-lookup` 核对签名后再用）。

### [一般][存量] `done()` 的 `valJoin()` 超时被吞掉后仍 `markIdle(false)`：读线程可能还在读，下一条命令会与它抢同一个通道

- **位置**：`f_email/src/imap/ImapIdle.cj:384-396`（`valJoin` 里 `catch (_: Exception)` 静默）；`:191-192`（无论 join 是否成功都 `client.markIdle(false)`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §12.1「异步语义 / 超时但任务继续跑」「跨线程资源：同一连接被两方读」；§11「错误处理缺失或静默」
- **证据**：静态确定 —— `future.get(Duration.second * 10)` 超时后，`catch` 里注释明说「读线程卡在 readLineSoft 上时不必强杀：连接关闭会让它退出」，但紧接着 `markIdle(false)` 会让 `ImapClient.requireNotIdle`（`ImapClient.cj:1559-1563`）放行后续命令，`execute()` 就能往同一个 `LineChannel` 写命令并 `collect()` 读响应——此时旧读线程仍在 `readLineSoft` 上，两个读者分食同一字节流。
- **描述**：触发条件是读线程在 `rebuild()` 的 30 s 等待里（`:272`、`:294`）或 `readLineSoft` 的 poll 窗口里超过 10 s 不返回。后果：`collect()` 读到的可能是读线程本该取走的事件行，或反之（事件丢失），`isTaggedLine` 不匹配即抛 `MailProtocolException`，连接不可再用。测试 `crossThreadCloseEndsIdle`（`ImapExt_test.cj:619-643`）只断言 `isFinished()`，覆盖不到这条路径。
- **建议**：`valJoin` 失败时不要静默——返回 `Bool`，`done()` 只有在 join 成功时才 `markIdle(false)`，否则 `client.markConnectionClosed()`（让连接明确报废，而不是留一个双读者）。同时把 `rebuild()` 里两个 `while(true)` 的 `continue` 加上「已 `stopRequested` 就退出」的检查，缩短 join 卡住的概率。

### [一般][存量] `ImapClient` 的 `idleActive` / `closedFlag` / `tagCounter` 在 IDLE 读线程与调用线程之间无同步

- **位置**：写方 `f_email/src/imap/ImapIdle.cj:258`（读线程 `client.markIdle(false)`）、`:465`（调用线程 `markIdle(true)`）、`:230`（读线程 `markConnectionClosed()`）；字段与读方 `ImapClient.cj:136`（`idleActive`）、`:123`（`closedFlag`）、`:135`（`tagCounter`）、`:250-252`（`isClosed`）、`:1306-1315`（`nextTag`）、`:1559-1563`（`requireNotIdle`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」；§11 并发正确性
- **证据**：静态确定 —— `ImapClient` 没有任何锁、`Atomic` 或多线程使用说明；`ImapIdleSession` 明确 `spawn` 一个读线程（`:129-132`）并在其中调用 `client.markIdle(false)`（`finally`，`:253-259`）与 `client.markConnectionClosed()`，同时调用线程可以随时 `execute()` 读 `idleActive`、`nextTag()` 自增 `tagCounter`（`rebuild()` 也在读线程里 `client.nextTag()`，`:289`）。
- **描述**：①`idleActive` 的写（读线程）与读（调用线程 `requireNotIdle`）之间没有 happens-before，可能出现「会话已结束但 `execute` 仍报 connection is idle」或反之（双读者，见上一条）；②`tagCounter` 被读线程（`rebuild` 的 `nextTag`）与调用线程并发自增，`+= 1` 非原子，两个线程可能拿到同一个 tag——「tag 唯一」是 `nextTag` 注释里写明的契约（`ImapClient.cj:1289-1292`）；③`closedFlag` 同上。
- **建议**：在 `ImapClient` 类注释里明确「非线程安全，除 IDLE 会话外不要跨线程使用」，并给 `idleActive` / `closedFlag` 换成 `AtomicBool`、`tagCounter` 换成 `AtomicInt64`（单值语义，不需要锁）；`nextTag` 的 tag 空间检查依赖自增结果，改成 `fetchAdd(1)` 后取旧值即可保持语义。

### [一般][存量] 扩展类各自复制「`if (!result.isOk()) throw`」，与 `ImapClient.expectOk` 语义漂移（丢掉认证失败映射与 `code`/`reply` 字段）

- **位置**：`f_email/src/imap/ImapSort.cj:165-167`、`:209-211`；`f_email/src/imap/ImapMove.cj:80-82`；`f_email/src/imap/ImapNamespace.cj:86-88`；对照 `f_email/src/imap/ImapClient.cj:1587-1601`（`expectOk` + `isAuthFailure`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §2「同一错误处理跨文件复制，行为漂移」；§10 错误处理
- **证据**：静态确定 —— 四处都是同一形状：`if (!result.isOk()) { throw MailProtocolException("${prefix} 失败：${result.response.raw}") }`，都不带 `command` / `reply` 字段，都不走 `isAuthFailure`（`ImapClient.cj:1597-1601`），也都不处理 `byeSeen`（`execute` 里已处理，这点没错）。而 `expectOk` 会把 `NO ... AUTHENTICATIONFAILED` 转成 `MailAuthException`。
- **描述**：同一批扩展命令在「连接被降权 / 会话过期」时抛的是 `MailProtocolException` 而不是 `MailAuthException`，调用方按异常类型做「重登」分支时对 `SORT`/`THREAD`/`MOVE`/`NAMESPACE` 失效（`STORE`/`FETCH`/`SEARCH` 则正常）。这会表现为「换个命令就重登失败」，属于难查的行为漂移。
- **建议**：把 `expectOk` 从 `private` 放宽成包内 `func`（或提供 `func expectOk(result, command)` 的包内重载），四处改为调用它；这样也顺带删掉 4 份重复文案。

### [一般][存量] `SORT=DISPLAY` 的排序键被写成 `DISPLAY FROM` / `DISPLAY TO`（两个 atom），RFC 5957 定义的是单个 atom `DISPLAYFROM` / `DISPLAYTO`

- **位置**：`f_email/src/imap/ImapSort.cj:43-44`（`case DisplayFrom => "DISPLAY FROM"`）；拼接 `:66-72`（`"REVERSE ${criterion}"`）与 `:266-282`（`renderKeys`）；测试固化 `f_email/src/imap/ImapExt_test.cj:295-300`（断言线上是 `SORT (DISPLAY FROM) UTF-8 ALL`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「契约与实现不符」；RFC 5957 §5「Formal Syntax」（`sort-key =/ "DISPLAYFROM" / "DISPLAYTO"`，已现场核对 rfc-editor 原文）
- **证据**：静态确定 —— 线上字节是 `SORT (DISPLAY FROM) ...`。RFC 5256 的 `sort-key` 是单个 atom，`(DISPLAY FROM)` 会被服务器解析成两个键：未知键 `DISPLAY` + 合法键 `FROM`，通常直接 `BAD`；`REVERSE DISPLAY FROM` 更糟——`REVERSE` 只作用于紧邻的一个 `sort-key`，等于「按 DISPLAY 倒序 + 按 FROM 正序」，而 `DISPLAY` 不存在。`renderKeys` 的注释（`:276-277`）还写着「DISPLAY FROM / DISPLAY TO 通过 SortCriterion 之外的调用方拼装」，与枚举里已有的两个 case 自相矛盾。
- **描述**：凡是选了 `SortCriterion.DisplayFrom` / `DisplayTo` 的调用，命令必然被服务器拒绝（`MAIL_PROTOCOL` + `BAD`），`sortDisplayKeysUseDisplayCapability` 之所以通过，是因为 `ScriptedTransport` 只记录了请求文本、没有校验语法。功能上等于「SORT=DISPLAY 能力永远用不了」。
- **建议**：`toString()` 改成 `DISPLAYFROM` / `DISPLAYTO`（并同步 `ImapExt_test.cj:298` 的断言）；`renderKeys` 里对「多词键 + REVERSE」加一条断言或直接禁止。

### [轻微][存量] 死代码：5 个无引用的包内函数、2 个只写不读的字段、1 处只写不读的局部变量

- **位置**：
  - `f_email/src/imap/ImapClient.cj:1164` `valUntaggedLoop`（包内 `func`，全仓零调用；与 `collect` 是同一套读循环的近似重复）
  - `f_email/src/imap/ImapClient.cj:1326` `encodeString`
  - `f_email/src/imap/ImapClient.cj:1611` `clearEnabled`
  - `f_email/src/imap/ImapClient.cj:1615` `setCapabilities`
  - `f_email/src/imap/ImapClient.cj:1631` `timeoutsValue`、`:1635` `connectionValue`
  - `f_email/src/imap/ImapClient.cj:117-118` `idName` / `idVersion` 字段（只在 `init` 里赋值，类内无任何读取；`ID` 命令在 builder 里用的是 `idNameValue`）
  - `f_email/src/imap/ImapIdle.cj:94` `started` 字段（`:118` 赋值，全文无读取）
  - `f_email/src/imap/ImapClient.cj:1779` `capabilities = client.capabilities`（局部 `var` 最后一次赋值后无读取；`capabilities` 上一次被读是 `:1750`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §1「无调用者 / 读了不用 / 死字段」；判据口径：`func`（包内可见）在**全仓** `grep` 只命中定义处；字段在同一类型内无读取
- **证据**：静态确定 —— 对上述 6 个符号名做全仓 `*.cj` 搜索，`valUntaggedLoop|encodeString|clearEnabled|setCapabilities|timeoutsValue(|connectionValue(` 的命中只有定义行（以及 `ImapIdle` 里 `markIdle` 等相邻但不同名的调用）。`idName`/`idVersion` 的命中只有 `ImapClient.cj:117,118,149,150,159,160` 与 builder 的 `idNameValue`（不同符号）。`started` 只有 `:94`（声明）与 `:118`（赋值）。
- **描述**：这些是「预留但对内不可达」的入口，读代码时会被误认为有调用方；`valUntaggedLoop` 还额外制造了一份 `collect` 的近似实现（未来修 `collect` 的 literal 问题时会漏改）。
- **建议**：删除或改为真实使用（`encodeString` 若打算给扩展用，就改成 `ImapParser.quoted` 的别名并加注释）。注意 `public` 属性/方法（`capabilities`、`enabledCapabilities` 等）一律**不判**死代码，本条只列非 public 符号。

### [轻微][存量] 用 `toString()` 字符串比较判断枚举分支（`ImapResponseKind`、`TlsMode`）

- **位置**：`f_email/src/imap/ImapResponse.cj:74-84`（`kind.toString() == "Tagged"` 等 3 个）；`f_email/src/imap/ImapClient.cj:1582`（`tlsMode.toString() == "None"`）、`:1717`、`:1749`、`:1769`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §10「仓颉语言特性：`Option`/枚举惯用法」；§8「热路径去抽象」
- **证据**：静态确定 —— 枚举已有 `match (this)` 的 `toString`（`ImapResponse.cj:27-33`、`TlsMode.cj:29-35`），分支判断却绕一圈走字符串比较，比较结果依赖 `toString` 的措辞（改文案即改语义）。
- **描述**：`isTagged()` / `isUntagged()` / `isContinuation()` 在 `collect()` 的每条响应上都会被调用（每命令一次，`ImapIdle` 的事件分类也会走 `ImapResponse.parse`），字符串比较带分配与逐字节比对；`TlsMode` 的四处判断则是安全语义（「是否明文」）挂在文案上，任何一次 `toString` 调整都可能把 `requirePlaintextSafe` 变成恒假。
- **建议**：`match (kind) { case Tagged => true; case _ => false }`；`TlsMode` 用 `match (tlsModeValue) { case TlsMode.None => ... }`。

### [轻微][存量] `cramResponse` 在 base64 挑战解码失败时静默改用原文计算 HMAC：必然认证失败且错误信息指向不了根因

- **位置**：`f_email/src/imap/ImapClient.cj:393-398`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「错误处理缺失或静默」；§3「`catch` 兜底把错误吃掉」
- **证据**：静态确定 —— `catch (_: Exception) { base64Challenge }`：用 base64 文本本身参与 HMAC-MD5，得到的摘要与服务器算的必然不同。
- **描述**：服务器发来非标准挑战（或通道被你自己的解析器截断）时，客户端照样发一个错误摘要，服务器回 `NO [AUTHENTICATIONFAILED]`，`expectOk` 再把它映射成 `MailAuthException`——排障者会以为是密码错，实际是挑战解析问题。
- **建议**：解码失败直接 `throw MailAuthException(command, None, "CRAM-MD5 挑战不是合法 base64")`，不要让错误摘要上网。

### [轻微][存量] 命令参数（`flags` / `status` items / `ENABLE` 能力名）未校验，含空格或括号会改写命令结构

- **位置**：`f_email/src/imap/ImapClient.cj:874-881`（`store` 的 flags）、`:990-998`（`append`）、`:1034-1044`（`appendBytes`）、`:526-533`（`status` 的 items）；`f_email/src/imap/ImapEnable.cj:51-54`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §10「安全性：外部输入未校验」；§11「边界」
- **证据**：静态确定（并已核对防线）—— `LineChannel.writeLine` 对 `\r` / `\n` 直接抛异常（`transport/LineChannel.cj:305-311`，「CRLF 注入防线」），所以**不存在**换行注入；但这些值被原样插入 `(...)` 列表或命令行，`flag = "\\Seen) (BODY[]"` 之类会改变语法（`STORE 1 +FLAGS ((\Seen) (BODY[]))`），`items = ["MESSAGES) (UIDNEXT"]` 同理。`ImapParser.param` / `quoted` 只用于邮箱名与字符串值，没覆盖这些位置。
- **描述**：不是可利用的注入（不能新起一条命令），但会造成「看起来发对了、服务器 BAD」或让服务端解析出多余参数；对库使用者来说，一个带空格的 flag（如误传 `"\\Seen \\Flagged"`）会静默变成两个标记之外的第三种语义。
- **建议**：加一个包内 `requireAtom(value, what)`（复用 `ImapParser.isSafeAtom` 的字符集判断，`ImapParser.cj:218-232`），在拼 `flags` / `items` / `enabled` 前校验；非法值抛 `IllegalArgumentException` 并指明是哪一项。

### [轻微][存量] `ImapIdleSession.rounds` 与测试里的 `IdleTrace.lines` 跨线程读写无同步

- **位置**：`f_email/src/imap/ImapIdle.cj:103`（`var rounds`）、`:307`（读线程自增）、`:136-140`（任意线程读）；`f_email/src/imap/ImapExt_test.cj:713-721`（`IdleTrace.lines` 由读线程 `add`、测试线程 `contains`）
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §12.1「可见性」；§11 并发正确性
- **证据**：静态确定 —— `rounds` 只在 worker 里写（`rebuild()`），`rebuildCount` 属性无锁读出；`IdleTrace` 是测试替身，`onLine` 在 worker 线程调用而断言在测试线程。
- **描述**：`rounds` 是统计量，最坏结果是读到旧值（`rebuildsIdleAfterSilence` 用 `>= 1` 断言，偶发失败会表现为 flaky test）；`IdleTrace` 的 `ArrayList` 并发 `add` 在极端情况下会丢行或抛内部异常——测试代码，不进生产统计。
- **建议**：`rounds` 用 `AtomicInt64`（或放进 `mutex`）；`IdleTrace` 换成加锁的 `ArrayList` 或在测试里先 `done()` 再断言（现有用例已大体如此，`crossThreadCloseEndsIdle` 除外）。

### [轻微][存量] `ImapParser.parseNumber` 无溢出保护：超长数字会溢出成负数

- **位置**：`f_email/src/imap/ImapParser.cj:189-201`
- **来源**：存量（`git blame` → `b555d80162`）
- **判据**：review-checklist §11「边界」；§10 正确性
- **证据**：待确认 —— `value = value * 10 + ...` 对 20 位以上数字会超出 `Int64`；仓颉整数溢出在 release 下是回绕、debug 下抛 `ArithmeticException`（具体行为需按当前 SDK 编译选项确认，未在文档中核实到确定结论）。
- **描述**：`parseNumber` 被 `parseCopyUid` / `parseAppendUid` / `parseStatus` / `ImapDate.parse` / `SearchCriteria.requireDate` 复用，任何一处被喂了超长数字（恶意服务器、损坏响应）都会得到负数序号，后续 `SequenceSet.single(负数)` 会发出非法命令。
- **建议**：加位数上限（例如 `digits > 18` 直接返回 `None`）或改成 `Int64.parse` 的受检版本并 `try` 包裹。

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

### [严重][存量] #1 `AddressList.parseInto` 组语法递归深度由输入线性决定且无上限：一封畸形 `To:` 头即可打到栈溢出

- **位置**：`f_email/src/model/MailAddress.cj:297-321`（`303-311` 组分支，`309` 行 `parseInto(inner, list)` 自递归）、`f_email/src/model/MailAddress.cj:324-361`（`groupColon`，只找第一个顶层 `:`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`，快照无 diff 基线）
- **判据**：review-checklist §4「无界递归：深度由输入决定」、§11「边界 / 契约不符」
- **证据**：静态确定 —— 递归入口是 `AddressList.parse(text)`（`252-256`），`parseInto` 对每个含顶层 `:` 的片段剥掉 `:` 前缀后**递归自己**（`305-309`）。`groupColon` 只要在 `@` 之前遇到 `:` 就返回其下标且不记录任何层级计数，因此 `"a:a:a:...:x@y.com"` 的递归深度 = `:` 个数 = `输入字节数 / 2`，代码里没有深度上限、没有访问集合、也没有把组解析改成迭代。可达上界可由默认解析限制推出：`f_email/src/mime/MimeOptions.cj:43-45` 的 `maxHeaderLine = 64 * 1024`、`maxHeaderBytes = 256 * 1024`，即**单行 64 KiB 就能产生约 3.2×10⁴ 层**、折叠成多行的 `To:` 头更多。同类递归在 `parseMailbox`/`stripRoute` 里都是单层、无风险，可对照排除。
- **描述**：`To:` / `Cc:` / `From:` / `Resent-*` 的值是不可信输入（`Envelope.fromMessage` 与 `MailMessage.to()/cc()/bcc()/from()` 都直接喂 `AddressList.parse`，见 `MailMessage.cj:52/119`、`Envelope.cj:53/67`）。构造一个 `To: a:a:a:...:victim@example.com;` 的头，解析端就会以每 2 字节一层的速度递归，最终栈溢出——这是进程级崩溃，无法被 `catch (e: MailException)` 兜住（栈溢出不是 `Exception`）。构造该头的成本 ≈ 一个正常邮件的大小，攻击面是"任何解析来信/来信头"的调用方。
- **建议**：把组展开改成显式栈/循环（`while` 取剩余片段，每轮剥一层前缀并压入 `ArrayList`），或在 `parseInto` 上加 `depth` 参数并以 `MimeException`/`MailLimitException(LimitKind.Depth, …)` 限深（现有 `LimitKind.Depth` 只有 MIME part 用，正好复用）；同时补一条回归用例：`"a:"` × 10_000 的字符串断言抛 `MailLimitException` 而不是崩溃。

### [一般][存量] #2 `QuotedPrintableEncoder.lineLength` 只赋值从不读取：`MimeWriteOptions.bodyLineLength` 对 quoted-printable 完全失效

- **位置**：`f_email/src/model/QuotedPrintable.cj:85`（字段）、`91-94`（构造器赋值）、`166-176`（`writeEncoded`，`167` 行硬编码 `lineLen + 3 > 75`）、`178-184`（`emitOne`，`179` 行硬编码 `lineLen + 1 > 75`）；对外入口 `33-39`（`encode(bytes, lineLength)`）、`59-61`（`encoder(output, lineLength)`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §1「读了不用 / 死配置字段」、§14.1「接线缺失：配置项被读取却从未使用」、§2「换控制流 / 只改类型名的近似实现（与 `Base64Encoder` 对照）」
- **证据**：静态确定 —— 本文件内 `lineLength` 只有 `85`（声明）与 `93`（赋值）两处出现，`writeEncoded` / `emitOne` / `softBreak` 全部按常量 75 断行；同目录 `Base64Codec.cj:189-197`、`234` 是完全同形的实现但**真的用了** `lineLength`，可直接对照。仓内唯一生产者 `f_email/src/mime/MimeWriter.cj:189`（`QuotedPrintable.encode(bytes, lineLength: options.bodyLineLength)`）与 `198`（`QuotedPrintable.encoder(…, lineLength: options.bodyLineLength)`）把用户配置传了进来，然后被丢弃。
- **描述**：`MimeWriteOptions.bodyLineLength` 是公开写选项（`README.md:267` 把它列为 `MimeWriteOptions` 字段之一）。当正文 CTE 选中 quoted-printable 时该值不生效：设 40 仍然按 76 输出、设 998 仍按 76 拆，生成结果既不符合调用方配置、也无法针对某些对行长有特殊要求的网关调整。`Base64` 分支行为正确，两条分支对同一配置给出不同结果，属"配置半接线"。
- **建议**：把 `75` 换成 `lineLength - 1`（保留软换行 `=` 占位）并对 `lineLength <= 0` 回落默认 76；`encoder` 的构造参数同样校验一次，避免 `lineLength = 0` 造成每字节断行。补用例：`encode("aaaa…", lineLength: 20)` 断言最长行 ≤ 20 且往返一致。

### [一般][存量] #3 手写十进制解析没有溢出保护：长数字串抛 `ArithmeticException` / `NoneValueException`，绕过「宽松回退」与 `MailException` 契约

- **位置**：`f_email/src/model/MailDate.cj:123-133`（`128`、`129`、`131` 三处 `parseInt(...).getOrThrow()` 无 `None` 检查）、`f_email/src/model/MailDate.cj:218-232`（`228-230` `value * 10 + …` 无位数上限）；同类实现 `f_email/src/pop3/Pop3Client.cj:619-639`（`636` 行同样无上限）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「错误处理缺失 / 空值未处理」、§3「契约承诺 A、实现做 B」、§4（异常路径）
- **证据**：静态确定，依赖两条已现场核对的 std 语义：
  1. 仓颉整数运算默认策略是 throwing（`cangjie_docs/docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:88`："默认情况下（即未标注该类内置编译标记时），采取抛出异常（`@OverflowThrowing`）的处理策略"）⇒ `parseInt("999999999999999999999999")` 抛 `ArithmeticException`；
  2. `Option.getOrThrow()` 在 `None` 时抛异常（`cangjie_docs/docs/dev-guide/source_zh_cn/error_handle/use_option.md:130`、`generic/generic_enum.md:12`，异常类型为 `NoneValueException`）。
  `parse` 中 `try { DateTime.of(…) } catch`（`147-160`）只包住时间构造，`day`/`month`/`year` 的 `isNone()` 都显式判了（`104-111`），唯独 `hh:mm[:ss]` 三段直接 `getOrThrow`，且 `parseInt` 自身不做长度限制。
- **描述**：两个可复现的输入都能让"宽容解析"契约失效：
  - `Date: 28 Oct 2026 ab:cd +0800` → `parts[0] = "ab"` → `parseInt` 返回 `None` → `getOrThrow` 抛 `NoneValueException`，既不是 `MimeException`，也不会回退到 1970 并记 warning（文件头 `24-26` 行承诺"非法日期在宽松模式回退到 `1970-01-01` 并记告警，严格模式抛 `MimeException`"）；
  - `Date: 1 Jan 99999999999999999999999 …` 或 POP3 `LIST` 回复里的超长数字 → `ArithmeticException`。
  调用方按契约只 `catch (MailException)` 时会漏接这两种异常，一路冒到解析入口。`Pop3Client.parseUnsigned` 的输入来自**服务器**回复（`273-290`、`509-524`），同样会以非 `MailException` 形式炸出。
- **建议**：`parseInt` 加位数上限（如 `text.size > 18 → None`）或改用 `Int64.parse` 并捕获；`hh:mm[:ss]` 三段改成与 `day`/`year` 同款 `if (let Some(v) <- parseInt(...))`，失败走 `failed(text, strict, warnings)`；`parseUnsigned` 同样加 18 位上限并返回 `None`。补两条用例覆盖上述输入。

### [一般][存量] #4 公共构造器 `MailDate(dateTime, offsetMinutes!)` 的默认 `0` 与 `dateTime` 自带时区无一致性保证：`toString()` 会把墙上时间和错误偏移拼在一起

- **位置**：`f_email/src/model/MailDate.cj:34-38`（`offsetMinutes!: Int32 = 0`）、`174-179`（`toString()` 用 `value.dayOfWeek/hour/…` + `formatOffset(offsetMinutes)`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」、§10「正确性：默认值」
- **证据**：静态确定 —— `DateTime.now()` 默认取**本地时区**（`stdlib/doc/libs/std/time/time_package_api/time_package_structs.md:781-791`：`public static func now(timeZone!: TimeZone = TimeZone.Local)`）。于是 `MailDate(DateTime.now())` 得到 `value` 在 `+08:00`、`offsetMinutes = 0` 的组合，`toString()`（`174-179`）输出 `… 21:58:52 +0000`：墙上时间取自 `+08:00`，偏移写成 `+0000`，同一个字符串里两个时区。同一文件的 `now()`（`46-60`）之所以正确，是因为它显式算出了偏移并走私有构造器；公共构造器没有这道保证，也没有任何校验或文档说明"两者必须一致"。
- **描述**：`MailDate` 是对外类型（`README.md` 模块级清单登记），`MailMessageBuilder.date(date)`（`MailMessage.cj:213-216`）直接 `date.toString()` 写 `Date:` 头。下游按最自然的写法 `MailDate(DateTime.now())` 生成日期头，收件方解析出的时刻会整体偏移一个时区（例：本地 21:58 +0800 会被写成 21:58 +0000，差 8 小时），邮件排序与"是否过期"判定随之出错，且没有任何报错。
- **建议**：二选一 —— (a) 让公共构造器从 `dateTime.zone` 反推偏移（复用 `now()` 的 `wallAsUtc - local` 差值算法，`48-58`）并在传了显式 `offsetMinutes` 时校验一致；(b) 把 `offsetMinutes` 改成 `?Int32 = None`，`None` 表示"跟随 `dateTime.zone`"。`toString()` 也要以 `value.zone` 为准，避免字段与对象状态双份真相。

### [一般][存量] #5 `MailMessageBuilder.build()` 让多条消息共享同一个 `HeaderMap` 实例：二次 `build()` 会把上一封的 `Content-Type` boundary 改掉

- **位置**：`f_email/src/model/MailMessage.cj:179`（`private let headerMap = HeaderMap()`）、`245-292`（`build()`，`286` 行 `headerMap.set("Content-Type", …)`，`291` 行 `MailMessage(MimePart(headers: headerMap, body: body))`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「资源 / 别名导致的静默数据错误」、§3「契约与实现不符」、§10「正确性：对象所有权」
- **证据**：静态确定 —— `HeaderMap` 是 `public class`（`HeaderMap.cj:32`，引用语义），`build()` 每次都把**同一个** `headerMap` 交给新建的 `MimePart`，而 `build()` 自身会在 `286` 行覆盖 `Content-Type`、在 `288-290` 补 `MIME-Version`。因此：
  - 第一次 `build()` → 消息 A 的 `root.headers` 是 `builder.headerMap`，`Content-Type` 的 boundary 是 `B1`（`260-262`）；
  - 第二次 `build()` → 生成 `B2`（`266`）并 `headerMap.set("Content-Type", …B2…)`，消息 A 的头部随之变成 `B2`，但 A 的 `PartBody.Parts(Multipart("B1", …))` 没变 ⇒ A 的头部与正文自相矛盾；
  - 反向亦然：`build()` 之后再 `.header("X-Foo", …)` 会改到已发出消息的头上。
  另外 `headerMap.set("Content-Type", currentType)`（`286`）会覆盖调用方在 builder 上显式 `header("Content-Type", …)` 设置的值，builder 文档（`173-177`）没提这一点。
- **描述**：`build()` 没有"一次构建"约束，也没有文档禁止复用；"先 build 一份调试用、再改附件 build 正式版"或"失败重试再 build"都会踩到，结果是收件方按 `B2` 找分隔符却只看到 `B1`，整封邮件正文解析为单个 part（静默丢结构，不报错）。
- **建议**：`build()` 内 `let headers = HeaderMap(); for ((k, v) in headerMap.entries()) { headers.set(k, v) }`，把快照交给 `MimePart`；`Content-Type` 只在"调用方未显式设置"时写入（`if (!headerMap.contains("Content-Type"))`），否则按 `MimeException` 报冲突。补用例：同一 builder 连续 `build()` 两次，断言两条消息的 boundary 互不影响。

### [一般][存量] #6 POP3 多行回复无上限物化，且 `readLines → 拼全文 → 再 split` 把每条回复搬两遍

- **位置**：`f_email/src/pop3/Pop3Reply.cj:130-146`（`Pop3Multiline.readAll`，`139-141` 逐字节 `out.add`）、`149-151`（`readLines`）、`153-172`（`splitLines` 每行再 `Array<Byte>` + `String`）；`f_email/src/pop3/Pop3Client.cj:467-487`（`sendMultiline`，`477-485` 用 `text = text + line` 把行拼回整串），消费方 `300`、`324`（`reply.text.split("\r\n")`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §5「一次性物化 / 无界容器，且没有拒绝路径」、§6.4「同一输入重复解析」、§4（`LIST`/`UIDL` 行数由服务器决定）
- **证据**：静态确定 —— `readAll` 循环读到 `.` 为止，全程没有字节上限，`LIMIT` 类配置（`LimitKind` 里已有 `Line`/`Body`/`Size`）在这条路径上一处也没用；`sendMultiline` 随后把 `Array<String>` 拼成一个 `String`（`481-483` 循环内 `+`，行数 n 时为 O(n²) 拷贝），调用方再 `split("\r\n")` 拆回字符串数组。一次 `LIST` 的字节量 ≈ 1× 原始 + 1× `String` 全文 + 1× 拆分后的每个 `String`（外加每行的 `Array<Byte>` 中间体），峰值约为原始回复的 3–4 倍，且没有任何"超过 N 行就中止"的路径。
- **描述**：`list()` / `uidl()` / `capabilities` 全部走这条链。对一个 20 万封邮件、`LIST` 回复 8 MB 的邮箱，峰值堆占用可达数十 MB，且 `text` 拼接的 O(n²) 让 CPU 随行数平方增长；服务器若返回一条永不结束的 `LIST`（或被中间人注入的超长回复），客户端只有 `timeouts.data` 一道兜底，内存会跟着回复长度线性涨到 OOM。`retr`/`top` 路径是流式的（`copyBody`，`489-507`），说明作者已经知道正确形态，只是多行命令没照做。
- **建议**：`sendMultiline` 直接返回 `Array<String>`（不再拼 `text`），`list()`/`uidl()` 消费数组即可，省掉两次搬运；`readAll` 增加行数/字节上限（`maxLines`、`maxBytes`，超限抛 `MailLimitException(LimitKind.Size, …)`），并在 `ArrayList` 上按 `bytes.size / 平均行长` 预分配。

### [一般][存量] #7 `EmailAddress.validateAddress` 只挡 CR/LF/尖括号：无 `@`、含空格与控制字符的字符串都能进 `MAIL FROM:` / `RCPT TO:`

- **位置**：`f_email/src/model/MailAddress.cj:92-104`（`96-100` 只查 `\r`/`\n`/`<`/`>`，`101-103` 只查"以 `@` 开头"）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「缺少边界校验」、§10「安全性：外部输入未校验」、§14（文档把该函数描述成"两道注入防线"，但结构校验缺失）
- **证据**：静态确定 —— `validateAddress` 通过后 `addr` 原样保存（`32`），`Envelope` 只取 `.address`（`Envelope.cj:53/67`）并交给 `"MAIL FROM:<${from}>"` / `"RCPT TO:<${address}>"`（`f_email/src/smtp/SmtpClient.cj:458/477`）。CRLF 注入确实已被挡住（`LineChannel.writeLine` 在 `f_email/src/transport/LineChannel.cj:300-311` 逐字节拒 `\r`/`\n`），但下列输入全部被当作合法地址接受：`"alice"`（无 `@`）、`"a b@c.com"`（空格）、`"\"unbalanced@x.com"`（引号不配对）、`"a\u0000b@c.com"`（NUL）、`"a@b@c"`（两个 `@`）。
- **描述**：这些地址会原样写进 SMTP 命令，服务端回 501/553，表现为"发送失败但错误信息指向服务器"，排查成本高；更实际的影响是 `AddressList.parse` 把畸形片段静默归一成"地址"，`MailMessage.from()` 也会返回这种对象，调用方无法区分"解析成功"和"解析出垃圾"。`MailMessageBuilder.to()`（`MailMessage.cj:193-196`）因此也可能产出非法 `To:` 头。
- **建议**：`validateAddress` 补最小结构校验：恰好一个未被引号包裹的 `@`、`@` 两侧非空、本地部分允许 `quoted-string`（成对引号）、拒绝 `\u0000`–`\u001F` 与空格（`quoted-string` 内的空格除外）。校验失败抛 `MailProtocolException`，与现有文案风格一致；补用例覆盖上面 5 个输入。

### [一般][存量] #8 POP3 协议解析失败后连接既不关闭也不标记失步：后续命令会读到上一条回复的残留

- **位置**：`f_email/src/pop3/Pop3Client.cj:458-465`（`send`）、`467-487`（`sendMultiline`）、`509-524`（`parseMessageInfo` / `parseUidl`）、`273-290`（`stat` 的 `tokens` 校验）、`546-562`（`requireFresh` / `requireTransaction` 只看 `closedFlag` 与 `authenticated`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「错误处理缺失 / 资源不对称」、§12.1「异步语义：失败后状态未处理」、§3「静默失效」
- **证据**：静态确定 —— `sendMultiline` 在 `472-474` 对 `-ERR` 提前返回，但紧接其后的 `list()`（`296-298`）/`uidl()`（`320-322`）才抛异常；此时多行正文**一个字节都没读**（`476` 的 `readLines` 未执行），这些字节仍留在 `LineChannel` 的输入流里。同样，`parseMessageInfo`（`511-513`）或 `parseUidl`（`520-522`）抛 `MailProtocolException` 时，该行已被消费、但整段回复的剩余行未消费。类中没有任何 `faulted`/`broken` 标志，`requireTransaction` 也不会拒绝后续调用，`Pop3Client.quit()`（`423-444`）甚至会在这种失步状态下继续写 `QUIT`。
- **描述**：一次畸形回复（服务器实现缺陷、代理截断、错误的字符集转换）之后，客户端"还能用"但状态已不可信：下一次 `stat()` 会读到上一条 `LIST` 的剩余行并当作状态行解析，抛出的错误信息会把调用方引向完全无关的方向；若剩余行恰好形如 `+OK 1 100`，则**静默返回错误的邮件数**。`MailIoException` 的注释（`MailException.cj:84-89`）已明确"超时后连接必然已被关闭"，说明作者对"出错即不可信"有共识，只是协议错误分支没落实。
- **建议**：在 `Pop3Client` 加 `private var broken = false`，所有 `throw MailProtocolException` 的解析路径（`send`/`sendMultiline`/`parseMessageInfo`/`parseUidl`/`stat`/`expect`）统一走一个 `fail(command, reply)`：先 `broken = true; connection.close()`，再抛异常；`requireFresh`/`requireTransaction` 增加 `if (broken) throw MailProtocolException("连接已失步，需重新连接")`。补用例：`LIST` 回复首行写成垃圾，断言异常后 `client.isClosed()` 为真、第二次 `stat()` 立即失败而不是读到残留。

### [一般][存量] #9 `Spool.createFile` 对权限与失败原因都做了静默处理：`chmod` 返回值忽略、16 次异常被吞后只给一句通用消息

- **位置**：`f_email/src/model/Spool.cj:47-64`（`54-62` try/catch，`59` 行 `catch (_: Exception) { attempt += 1 }`，`63` 行统一抛 `MimeException("无法创建附件临时文件，请显式指定 spoolDir")`）、`108-115`（`restrictPermissions`，`112` 行 `chmod(cpath, 0x180)` 返回值丢弃）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§11「错误处理缺失 / 资源不对称」、§10「安全性：敏感数据落盘权限」
- **证据**：静态确定 —— `chmod` 的 `Int32` 返回值没有任何检查（`112`），`LibC.free` 之后直接返回；失败时文件保持进程 umask 默认权限（常见 `0644`），而调用方随后会往里写**附件正文**（`f_email/src/mime/MimeParser.cj:493-500` 的 `spill()`）。创建失败分支把 16 次尝试的所有异常（权限不足、磁盘满、路径不存在、`ENOSPC`）全部丢弃，最终只抛"请显式指定 spoolDir"，把"磁盘满"错误地指向"目录配置"。
- **描述**：这与文件头 `38-39` 的承诺（"创建后立即 `chmod 0600`"）不一致：在 `chmod` 失败（某些容器 rootfs、挂载了不支持 POSIX 权限的文件系统、`/tmp` 被 `nosuid`+特殊策略限制）时，附件会以 `0644` 留在共享目录里，同机其它用户可读——而"附件不写危险路径/不给别人读"正是 `Spool` 存在的理由。错误信息层面，`ENOSPC` / `EACCES` 无法区分，排障只能靠猜。
- **建议**：`if (chmod(cpath, 0x180) != 0) throw MimeException("无法收紧临时文件权限：${path}")`（并在 `finally` 里 `free`）；创建循环保留首个异常作为 `causedBy`（`MimeException(msg, causedBy: e)` 已有重载，`MailException.cj:196-201`）；`restrictPermissions` 之前不要提前 `file.close()` 也可以省一次失败窗口——更彻底的做法是 `open` 时带 `O_CREAT|O_EXCL|O_WRONLY` 与 `0600`，把"检查存在"和"创建"合并成一次原子操作（当前 `50` 行的 `exists` + `55` 行 `File.create` 之间存在 TOCTOU 窗口，虽因文件名含 64 位随机数而难以利用，但仍应消除）。

### [轻微][存量] #10 五组同语义复制散在 `model/` 内：转义、反转义、注释剥离、能力查找、读流样板

- **位置**：(a) `f_email/src/model/MailAddress.cj:88-90` ≡ `f_email/src/model/MimeParameter.cj:318-320`（`escape` / `escapeQuoted`，均为 `replace("\\","\\\\").replace("\"","\\\"")`）；(b) `f_email/src/model/MailAddress.cj:138-141` ≡ `f_email/src/model/MimeParameter.cj:301-307`（引号反转义，两者都先 `\"`→`"` 再 `\\`→`\`）；(c) `f_email/src/model/MailAddress.cj:188-222` ≡ `f_email/src/model/MailDate.cj:332-366`（`stripComments`，逐行同构，只是 `StringBuilder` vs `ArrayList<Rune>`）；(d) `f_email/src/pop3/Pop3Capabilities.cj:66-94`（`supports`/`args`/`get` 三段同样的 `for + toAsciiUpper + ==`）；(e) `f_email/src/model/MimePart.cj:202-215`、`f_email/src/pop3/Pop3Reply.cj:130-146`、`f_email/src/pop3/Pop3Client.cj:489-507`、`f_email/src/model/QuotedPrintable.cj:44-55`（四处"8192 缓冲 + 逐字节 `ArrayList.add` + `toArray`"样板）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §2「字面量复制 / 换控制流 / 只改类型名」
- **证据**：静态确定 —— 逐对比较"输入 → 输出 → 副作用"后无实质差异：错误文案（`escape` 无文案）、边界（都处理首尾引号与空串）、可空性（都返回非空 `String`/`Array`）、并发假设（都无状态）完全一致。(c) 的两份连"反斜杠在顶层保留、在注释内只跳过一个字符"的细节都一样，属同一段逻辑的两次抄写。(e) 四处的差异只有下游处理（写文件 / 拼字符串 / 交 sink / 解码），读循环本身一致。
- **建议**：在 `f_email/src/model` 内落一个 `internal` 工具（例如 `MimeText.escapeQuoted` / `unquote` / `stripComments` / `readAll(input, initialCapacity)`），`Pop3Capabilities` 的三个方法收敛为 `get(name)` 一个实现 + 两个薄封装。抽取时顺带修正 (c) 的共同缺陷：两份 `stripComments` 都不识别引号，`"a(b"@x.com` 会被截成 `"a`（`MailAddress.cj:125` 随后原样当地址）。
- **说明**：本条是"轻"级——五组目前语义一致、还没漂移；#2 正是"两处同形实现漂移出不同行为"的实例，所以抽取应与 `lineLength` 修复一起做。

### [轻微][存量] #11 `MailMessage.attachments()` 的根节点守卫恒不改变行为，且"根自身就是附件"的信封会静默返回空

- **位置**：`f_email/src/model/MailMessage.cj:109-115`（`111` 行 `if (!root.isAttachment())`）、`f_email/src/model/MimePart.cj:192-200`（`collectAttachments` 只遍历 `children()`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §1「恒真恒假分支 / 无效守卫」、§11「边界：单 part 消息」
- **证据**：静态确定 —— `collectAttachments` 的实现是 `for (child in children())`，永远不检查 `this`，所以 `root.isAttachment()` 的真假对 `out` 没有任何影响：守卫为真时直接跳过、为假时进入一个只遍历子节点的循环。等价于无条件调用。同时，若根 `MimePart` 本身是附件（`Content-Disposition: attachment` 的单 part 邮件，或 `message/rfc822` 直接挂附件），`children()` 为空 ⇒ `attachments()` 返回 `[]`，而这封信唯一的载荷就此丢失。
- **建议**：删掉守卫，改成 `if (root.isAttachment()) { out.add(root) } else { root.collectAttachments(out) }`；补用例：`MimePart(headers: {Content-Disposition: attachment}, body: Data(...))` 作为根，断言 `attachments().size == 1`。

### [轻微][存量] #12 `TransferEncoding.parse` 的注释承诺"无法识别按 7bit 处理并告警"，实现既无告警也无识别结果

- **位置**：`f_email/src/model/TransferEncoding.cj:38-52`（`48` 行 `case _ => SevenBit`，函数只返回枚举，没有任何 warning 出口）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §13「注释/契约与实现不符」、§3「静默降级」
- **证据**：静态确定 —— 全文件只有 `toString` 与 `parse` 两个函数，签名 `parse(value: ?String): TransferEncoding` 没有告警参数也没有返回值位；两个调用点 `f_email/src/mime/MimeParser.cj:181`、`297` 都是直接取枚举值，未做任何"是否识别"的判断，`grep "未知.*编码"` 在 `src/` 内零命中。
- **描述**：`Content-Transfer-Encoding: x-uuencode` 这类未知值会被**静默**当 `7bit` 处理，正文按原文交给调用方——用户看到的是乱码而不是"不支持的编码"。注释描述的告警能力并不存在，读代码的人会以为有兜底日志。
- **建议**：改成 `parse(value) -> (TransferEncoding, ?String)` 或另加 `parseWithWarning`，把"未知值"回传；调用点在 `strict` 模式下抛 `MimeException`、宽松模式记 `warnings`（`MailDate` 已有同款 `warnings` 机制可参照）。

### [轻微][存量] #13 POP3 `AUTH` 续行判定只看首字节 `+`：`+OK …` 会被当成续行，多写一行凭据后错位读

- **位置**：`f_email/src/pop3/Pop3Client.cj:234`（`authPlain`）、`266`（`expectContinuation`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §11「边界 / 协议契约」、§10「正确性：状态机分支」
- **证据**：待确认（协议上下文）—— 代码判定是 `text.size > 0 && text[0..1] == "+"`；RFC 5034 的续行是单独的 `+`（可跟 base64 提示），而成功/失败是 `+OK` / `-ERR`，因此 `"+OK maildrop locked"` 会走进"续行"分支。触发前提是服务器在没有 challenge 的情况下直接回 `+OK`（对发裸 `AUTH PLAIN` 的客户端属非合规行为），所以实际概率取决于对端实现，无法仅凭代码判定为必然故障。
- **描述**：一旦触发：`authPlain` 会继续把 `base64(\0user\0pass)` 当**命令行**发出去（`240`），凭据以一行裸 base64 出现在协议流里，随后 `expect(Pop3Reply.read(...))` 读到的下一行已不是本次命令的回复，整个会话错位。`expectContinuation` 同理会把 `+OK` 当 challenge 继续发送下一段。
- **建议**：判定改为"首字节 `+` 且不是 `+OK` 开头"（`if (text.startsWith("+OK")) { expect(Pop3Reply.parse(text), command) }`），并把 `-ERR` 直接交给 `expect`；补用例：脚本化服务器对 `AUTH PLAIN` 直接回 `+OK`，断言客户端只发一行且 `authenticated` 为真。

### [轻微][存量] #14 四处用 `toString()` 字符串比较代替枚举匹配，重命名后行为会静默变化

- **位置**：`f_email/src/pop3/Pop3Client.cj:566`（`tlsMode.toString() == "None"`）、`694`（同）、`711`（`tlsModeValue.toString() == "StartTls"`）、`f_email/src/smtp/SendReport.cj:118-120`（`io.stage.toString()` 与 `"Timeout"`/`"Connect"` 比）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §10「语言特性：枚举用法」、§12.1「可见性/语义静默退化」
- **证据**：静态确定 —— `TlsMode`（`f_email/src/transport/TlsMode.cj:21-34`）与 `IoStage`（`MailException.cj:41-59`）都是带 `toString` 的 `enum`，模式匹配 `case TlsMode.None` / `case IoStage.Timeout` 是编译期穷尽的；当前写法把枚举值降级成字符串字面量，改 `toString` 的文案（例如把 `"StartTls"` 改成 `"STARTTLS"`）不会产生任何编译错误，`requirePlaintextSafe`（`565-569`）会从"拒绝明文发凭据"退化成"放行"，即**安全默认值静默失效**。
- **建议**：四处改 `match`/`==` 枚举常量；`SendReport.isRetryable` 改成 `match (io.stage) { case IoStage.Timeout | IoStage.Connect => true; case _ => false }`。**范围外同形态**：`f_email/src/smtp/SmtpClient.cj:153` 的 `policy.toString() == "BestEffort"`，属第 6 部分范围，合并时可一并处理。

### [轻微][存量] #15 `SendReport.cj` 有 3 个未使用 `import`

- **位置**：`f_email/src/smtp/SendReport.cj:18`（`IoStage`、`MailAuthException`、`MailProtocolException`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 三个名字在本文件正文（`20-126`）零出现：`isRetryable(error)` 只用 `MailIoException`、`MailTlsException`、`MailException`（`117-126`），`IoStage` 以 `io.stage` 的属性访问形式出现、从未作类型名使用。
- **建议**：删掉三个名字，只留 `{MailException, MailIoException, MailTlsException}`。

### [轻微][存量] #16 `MimePart` 的三个惰性缓存字段在 getter 内无同步写入，多线程共享同一消息时是数据竞争

- **位置**：`f_email/src/model/MimePart.cj:67-70`（`contentTypeCache` / `dispositionCache` / `charsetUsedValue` / `charsetLossyValue`）、`77-91`（`contentType` getter 在 `87` 行赋值）、`93-107`（`100` 行赋值）、`133-145`（`140-141` 行赋值）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 惰性初始化」
- **证据**：待确认（调用方的线程模型）—— 代码层面确定：三个 `var` 都是普通字段，getter 是 `match cache { Some => …; None => 解析并回写 }` 的检查-然后-写入，没有锁、没有原子、没有 volatile；类注释（`57-63`）只声明"解析完成后不要再改 `headers`"，**没有**声明"不可跨线程共享"，而 `MailMessage`/`MimePart` 是解析结果的自然跨线程传递对象（解析线程 → 业务线程池）。并发时后果限于"重复解析 + 缓存值可能不立即可见"，不会产生错误结果（`ContentType.parse` 对同一 `headers` 确定性），所以按轻微计。
- **建议**：要么在类注释里明确"非线程安全，跨线程前先调用一次 `contentType`/`disposition` 完成初始化"（成本最低），要么把缓存改成不可变发布（`Atomic`/`synchronized` 只保护首次赋值）。同一段落顺便说明 `Pop3Client` 也不是线程安全的（`channelRef`/`authenticated`/`closedFlag`/`deleteMarks` 均无同步）。

### [轻微][存量] #17 README 的 `Pop3Client` 成员清单漏了 `login` / `list` / `quit` / `retrMessage`

- **位置**：`f_email/README.md:276`（`Pop3Client`：`apop`、`authenticate`、`capabilities`、`dele`、`greeting`、`isAuthenticated`、`isClosed`、`isDeleteCommitted`、`noop`、`pendingDeletes`、`retr`、`rset`、`stat`、`top`、`topMessage`、`uidl`）；源码对照 `f_email/src/pop3/Pop3Client.cj:160`（`login`）、`293`（`list()`）、`310`（`list(message)`）、`356`（`retrMessage`）、`423`（`quit`）
- **来源**：存量（`git blame`：`4cefd27cd1 2026-10-29`）
- **判据**：review-checklist §14.2「公开 API 未文档化」
- **证据**：静态确定 —— 五个 `public func` 在 `README.md` 的 `Pop3Client` 成员清单里检索不到；`README.md:19` 的模块简介虽然提到"`USER`+`PASS`"，但没给出入口名 `login`，也没有任何段落解释 `QUIT` 与 `close()` 的差别（`quit` 才提交删除，`close` 不提交——这正是本模块最重要的语义之一，代码注释 `73-82` 写得很清楚，README 没同步）。
- **建议**：把五个成员补进清单，并在 POP3 小节加一句"`quit()` 提交 `DELE`，`close()` 作废"。**合并提示**：README 正文的完整审查属第 1–4 部分，本条若与其它子轮重复请在合并时去重。

<!-- 第 6 部分 -->

### [严重][存量] `DATA` 阶段被拒（552/554/4xx）仍把收件人记成 `accepted`，`isCompleteSuccess()` 返回 true（#1）

- **位置**：`f_email/src/smtp/SmtpClient.cj:330-338`（`writeData` 最终回复分支）、`:304-312`（`finishTransaction` 收到非 354）、`:248-256`（`transactPipelined` 收到非 354）；判定面 `f_email/src/smtp/SendReport.cj:85-88`
- **来源**：存量 —— `git blame -L 330,345`、`-L 293,299` 均为 `d9809c4196`（2026-10-29），工作区无改动
- **判据**：review-checklist §11「契约与实现不符」「失败路径当成功」、§3「静默失效」；对照 `doc/f_email设计文档.md:1293`「`DATA` 失败（552/554）→ 全部收件人失败」
- **证据**：静态确定 —— 三个分支都直接 `SendReport(accepted: accepted.toArray(), rejected: rejected.toArray(), reply: <失败回复>)`；`accepted` 在 RCPT 阶段已填满、`rejected` 为空，而 `isCompleteSuccess()` 的条件是 `!aborted && rejected.size == 0 && accepted.size > 0`（`SendReport.cj:85-88`），于是一封被服务器在 DATA 阶段整体拒收的邮件被报告为「完全成功」；`isRetryable(report)` 同样因 `rejected.size == 0` 直接返回 false（`SendReport.cj:96-109`）。全仓无 552/554 用例：`grep -rn "552\|554" f_email/src/*_test.cj` 零命中
- **描述**：默认路径不发 `SIZE=`（设计文档 6.5「默认不发送 SIZE，服务器在 DATA 阶段用 552 拒绝超限邮件」），因此 552 是**常规失败路径**而不是边角情况。此刻返回值告诉调用方「全部收件人都已受理」，`reply` 里虽是 552，但 README 示例只提示看 `report.rejected`（`f_email/README.md:108`），调用方不会去读 `reply.code`；后果是静默丢信 + 不重试，属数据错误级缺陷
- **建议**：`writeData` 的 `!finalReply.isSuccess()` 分支把 `accepted` 全部搬进 `rejected`（`code = finalReply.code`、`text = lastLine(finalReply)`），`accepted` 传空数组；`finishTransaction` / `transactPipelined` 的非 354 分支同样处理（DATA 根本没开始，RCPT 的 2xx 不能算投递成功）。补三条用例（552 / 452 / 554），断言 `accepted.size == 0 && rejected.size == n && !isCompleteSuccess()`

### [严重][存量] 空收件人信封走到 `rejected[0]`，抛越界异常（#2）

- **位置**：`f_email/src/smtp/SmtpClient.cj:293-299`（`finishTransaction`）；入口未校验 `f_email/src/smtp/SmtpClient.cj:120-151`；`Envelope` 公开构造无校验 `f_email/src/model/Envelope.cj:30-33`
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §11「空集合 / 空串未处理」、§10 正确性（边界）
- **证据**：静态确定 —— `prepare()` 只校验 `envelope.from.size == 0`（`:404-407`），`rcptCommands` 由 `envelope.recipients` 逐个生成（`:148-151`）；收件人为空数组时 `rcptCommands` 为空，`transactSequential` → `finishTransaction` 的 `accepted.size == 0` 分支执行 `rejected[0].code` / `rejected[0].text`，而 `rejected` 也是空数组。触发条件：`send(Envelope("a@b", []), msg)` 且（服务器不广告 PIPELINING，或策略为 `AllOrNothing`——后者在 `:153` 直接走串行路径）
- **描述**：公开 API 的契约是返回 `SendReport` 或抛 `MailException` 子类，这里抛出的是数组越界异常，既不在 `isRetryable(error:)` 的分类内，也会让调用方的 `catch (MailException)` 漏接；同时 `MAIL FROM` 已被服务器接受，事务以异常而非 `RSET` 结束。`Envelope.fromMessage` 挡住了「头推导」路径（`Envelope.cj:72-74`），只有显式信封入口会踩到
- **建议**：`send(envelope:message:)` 开头加 `if (envelope.recipients.size == 0) throw MailProtocolException("信封没有任何收件人")`（放在任何 I/O 之前）；`finishTransaction` 里把 `rejected[0]` 改成安全取值（空则抛 `MailProtocolException`）；补一条空收件人用例

### [一般][存量] `AUTH LOGIN` / `CRAM-MD5` 收到「直接成功」回复后不返回，继续写下一行导致流错位（#3）

- **位置**：`f_email/src/smtp/SmtpClientBuilder.cj:279-290`（`authLogin`，两处 `if (reply.code != 334) expectAuthOk(...)`）、`:292-303`（`authCramMd5`，`:295-297`）
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §11「语义与命名 / 控制流」、§10「错误路径」；对照 `doc/f_email设计文档.md:1231`（LOGIN 规定为 334 → user → 334 → pass）
- **证据**：静态确定 —— `expectAuthOk` 只在 `!isSuccess()` 时抛异常（`:316-320`），成功时既不改状态也不返回，随后无条件执行 `channel.writeLine(SmtpAuth.loginUser(user))` 与下一次 `read`。服务器若对 `AUTH LOGIN` 直接回 `235`（已认证）或 `503`（已登录），客户端会多发一行 base64 用户名，并在 `SmtpReply.read` 上阻塞到 `timeouts.command`（默认 60 s）才失败；`authCramMd5` 则会把 `235 authenticated` 的末行当 base64 挑战去解码
- **描述**：防御分支只防住失败、不防住成功，属「补了一半」。直接 235 少见，但 503/454 的会话复用场景并不罕见，表现为建连挂 60 秒后抛协议异常，排障成本高
- **建议**：两处改成 `if (reply.code != 334) { expectAuthOk(reply, "LOGIN"); return }`；`authCramMd5` 非 334 分支同样 `return`。补两条用例（`AUTH LOGIN → 235`、`AUTH CRAM-MD5 → 235`），断言只写出 `AUTH` 行且不再读后续回复

### [一般][存量] `SmtpReply.read` 对多行回复的行数与总字节均无上限（#4）

- **位置**：`f_email/src/smtp/SmtpReply.cj:57-88`（`while (true)` 内 `lines.add(rest)`，无计数上限）
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §5「无界容器」「一次性物化」
- **证据**：静态确定（无上限）+ 需实测（增长速率）—— `LineChannel` 只限制单行（`maxLine` 默认 4096，`LineChannel.cj:142`），`SmtpReply` 不限制行数；每行都进 `ArrayList<String>`，且 `:86` / `:87` 各自 `lines.toArray()` 一次（多一次整体复制）。命令总超时（默认 60 s）限制时长不限制字节：恶意/故障服务器持续发 `250-xxx` 可在超时前堆出与带宽同量级的内存
- **描述**：EHLO 回复是远端可控的多行文本，且发生在认证之前（`SmtpClientBuilder.cj:210`）。当前没有「最多 N 行 / 最多 M 字节」的拒绝路径，最坏情况是内存被打满；速率决定能否真正触顶，缺这条数据故不定严重。同类问题在 `LineChannel.readExact(count)`：按调用方给定 `count` 一次性预分配结果数组（`:192-197`），无内部上限——仓内唯一的 IMAP 调用有 64 MiB 闸门（`ImapClient.cj:711-715`，`maxLiteralBytes` 默认值见 `ImapClient.cj:1665`），所以只记在这里
- **建议**：`SmtpReply.read` 增加 `maxLines`（例如 256）与累计字节上限，超限抛 `MailLimitException` 并关连接；`lines.toArray()` 只调一次并把数组传给 `extractEnhanced`。`readExact` 要么加 `maxBytes` 参数，要么在文档里明确「调用方必须自己设上限」

### [一般][存量] `sendReset` 静默吞异常：`AllOrNothing` 中止后会话状态未知，仍返回「干净」报告（#5）

- **位置**：`f_email/src/smtp/SmtpClient.cj:395-400`（`catch (_: Exception) {}`）；调用点 `:277-292`（中止）、`:248-267`（非 354）
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §3「`catch {}` 静默吞掉异常」、§11「错误处理缺失」、§12.1「状态不一致」
- **证据**：静态确定 —— `sendReset` 不管 `RSET` 成功与否都不影响返回值；`finishTransaction` 中止路径在 `sendReset` 之后直接返回 `aborted: true`，调用方按文档会继续复用同一个 `SmtpClient`
- **描述**：`RSET` 失败意味着服务器仍停在 `MAIL FROM`（或更靠后）的事务状态，下一条 `send` 可能收到 `503 bad sequence of commands` 或被拒收，而调用方看到的是正常的中止报告，无从得知连接已不可信。`close()`（`:181`）吞掉 QUIT 异常属可接受的清理语义，但与 `sendReset` 共用「什么都不说」的模式，掩盖了后者应上报的状态问题
- **建议**：`sendReset` 返回 `Bool`（或给 `SendReport` 加 `sessionBroken` 字段），失败时把连接标记为不可复用；最简做法是失败即 `connection.close()`，让后续 `send` 走 `isClosed()` 抛 `MailIoException`。至少补注释说明「RSET 失败即视为连接不可复用」

### [一般][存量] `SmtpClient` / `LineChannel` 无并发保护，也未声明非线程安全；仓内 `Email` 门面单例持有（#6）

- **位置**：`f_email/src/smtp/SmtpClient.cj:61-74`（可变 `channelRef` + 事务状态）、`:120-157`（无互斥）；`f_email/src/transport/LineChannel.cj:46-55`（`pending` / `pendingPos` / `deadline` 等可变状态）；可见性面 `f_email/src/transport/MailConnection.cj:151-163`
- **来源**：存量（`164ed4e540` / `d9809c4196`）
- **判据**：review-checklist §12.1「共享可变状态无保护」「可见性」
- **证据**：静态确定（共享路径存在）+ 待确认（是否真有并发调用）—— `Email` 持有单个 `SmtpClient` 字段并懒建（`f_email/src/EmailFacade.cj:215`、`:487-513`）；同一 `Email` 被两个线程 `send` 时：①`SmtpClient.send` 会把 `MAIL FROM` / `RCPT` / `DATA` 交错写到同一 socket，`SmtpReply.read` 也会互相抢回复；②`smtpClient()` 是「检查-然后-写」的懒初始化，可能建出两个连接并泄漏其一。另 `MailConnection.isClosed()` 直接读 `closedFlag`（`:161-163`），写侧在 `closeMutex` 内（`:152-157`），读侧无锁也无原子，属可见性缺口；但误读后果只是错误文案不同（后续 I/O 仍会失败），故不按数据破坏型竞争定严重
- **描述**：库没有在类型注释或 README 里声明「非线程安全」。默认按「会被多线程调用」审，就必须给出同步手段或明确契约，当前两者都没有
- **建议**：二选一并写进类型注释与 README：①声明 `SmtpClient` / `LineChannel` / `MailConnection` 为**线程封闭**，由调用方串行化（同时把 `Email` 的懒初始化改成同步，或构造期建连）；②在 `SmtpClient` 内加一把 `Mutex` 串行化整次 `send`（`build()` 阶段不需要）。`closedFlag` 至少改成 `AtomicBool`

### [一般][存量] `redactLine` 未覆盖 `APOP`：MD5 摘要（凭据等价物）会进 trace（#7）

- **位置**：`f_email/src/transport/MailTrace.cj:38-53`（只有 `AUTH` / `PASS` / `LOGIN` 三类）；泄漏源 `f_email/src/pop3/Pop3Client.cj:199`
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §10「敏感数据进日志」、§11「与注释/规格冲突」；`MailTrace.cj:21-22` 自称「`AUTH` / `PASS` / `LOGIN` 行的参数一律替换」
- **证据**：静态确定 —— `Pop3Client.apop` 写的是 `APOP ${user} ${digest}`（`Pop3Client.cj:199`），`redactLine` 的命令白名单不含 `APOP`，于是 `LineChannel.writeLine` → `traceLine`（`LineChannel.cj:319`、`:473-486`）把 `MD5(timestamp+secret)` 原样交给 `MailTrace`
- **描述**：APOP 摘要加服务器时间戳足以在时间戳有效期内重放登录，等价于密码泄露；而 `AUTH PLAIN`、`PASS` 两条路径都已脱敏，说明这是遗漏而非策略。`sensitive` 模式（`beginSensitive`）只包住 SMTP 认证，POP3 的 `apop` 未使用
- **建议**：`redactLine` 增加 `APOP` 分支（保留用户名、丢弃摘要），并让 `Pop3Client.apop` 复用 `beginSensitive`/`endSensitive` 作为第二道防线；补一条用例断言 trace 里不含摘要

### [一般][存量] `MailTimeouts.idle` 无任何读取点，配置静默失效（#8）

- **位置**：`f_email/src/transport/TlsMode.cj:42`（注释承诺）、`:49`（字段）、`:62`（仅赋值）
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §1「读了不用：死配置字段」、§14.1「配置项被读取却从未使用」
- **证据**：静态确定 —— `grep -rn "\.idle" f_email/src --include=*.cj` 只命中 `TlsMode.cj:62` 这一处赋值；IDLE 读线程用自己的 `pollInterval`（`f_email/src/imap/ImapIdle.cj:212`、`:435-441`）与硬编码 `Duration.second * 30`（`:272`、`:294`）。`MailTimeouts` 是 public struct，字段对外可达，按硬原则不判死代码，但它在本模块内确实没有消费方
- **描述**：调用方按注释「`idle` 只用于 IDLE 期间的事件轮询判断」去设 `MailTimeouts(idle: ...)`，实际不产生任何效果——比缺配置更糟，因为无从发现
- **建议**：要么把 `ImapIdle` 的默认 `pollInterval` 接到 `timeouts.idle`，要么删掉该字段并同步改 `TlsMode.cj:42` 注释与 README 的 `MailTimeouts` 说明

### [一般][存量] 服务器不广告 `DSN` 时 `RET=` / `NOTIFY=` 被静默丢弃，设计文档要求「记 warning」（#9）

- **位置**：`f_email/src/smtp/SmtpClient.cj:459-463`（`RET`）、`:478-482`（`NOTIFY`）
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「接线缺失」；承诺源 `doc/f_email设计文档.md:1316`「只在服务器广告 `DSN` 时发送；否则忽略并记 warning」
- **证据**：静态确定 —— 两处都是 `if (capabilitiesValue.supportsDsn) { command = command + ... }`，没有 `else` 分支；`SmtpClient` 全文无日志/告警出口（未 import `f_log`，无 `println`）
- **描述**：调用方显式 `dsn(ret, notify)` 后拿到的 `SendReport` 与未配置 DSN 时完全一致，无法区分「服务器不支持」与「参数已生效」；投递失败时也拿不到 DSN 通知，而设计文档承诺的 warning 缺失，运维无法定位为什么没收到退信
- **建议**：给 `SmtpClient` 注入可选告警回调，或在 `SendReport` 上加 `dsnIgnored: Bool`，在 `supportsDsn == false` 且用户配置了 DSN 时上报；若不引入日志依赖，至少把「忽略」写进 README 的 DSN 段落

### [轻微][存量] 不可达 / 无效代码 7 处：`index` 死变量、不可达 `return`、恒真条件、不可达扩容、死方法、死字段、不可达分支（#10）

- **位置**：
  - `f_email/src/smtp/SmtpClient.cj:239`、`:244` —— `var index` 只自增、从不读取
  - `f_email/src/smtp/SmtpClient.cj:142` —— 已在 `if (prepared.sizeKnown)` 内，`prepared.sizeKnown &&` 恒真（`sizeKnown` 只由 `precompute || maxMessageBytes > 0` 置位，`:414-419`）
  - `f_email/src/transport/LineChannel.cj:184` —— `while (true)` 之后的 `return None` 不可达
  - `f_email/src/transport/DotStuff.cj:237-245` —— `ensure(need)` 的 `need` 最大为 3、缓冲区恒 8192，`limit == buffer.size` 的扩容分支不可达
  - `f_email/src/transport/TlsMode.cj:90-92` —— `Deadline.expired()` 全仓零调用（`grep -rn "\.expired()"` 只命中 README 的符号清单）
  - `f_email/src/transport/TransportFactory.cj:81` —— `private var eofAtEnd` 定义后无任何读写
  - `f_email/src/smtp/SmtpClientBuilder.cj:230`、`:233` —— `mechanism ?? selectMechanism(...)` 右支不可达（`:161` 已保证 `mechanism.isSome()`），`selectMechanism`（`:250-263`）因此整体是死代码；`:233` 的明文凭据校验与 `:128` 条件完全相同，同样不可达
- **来源**：存量（`164ed4e540` / `d9809c4196`）
- **判据**：review-checklist §1「不可达语句 / 恒真恒假分支 / 无调用者 / 读了不用」
- **证据**：静态确定 —— 逐条按控制流与全仓搜索确认（`index` 无读取点、`eofAtEnd` 只有定义、`expired` 零调用、`selectMechanism` 只有那一处调用点）
- **描述**：`selectMechanism` 死掉意味着「按服务器广告自动选机制」这条能力实际不存在（`mechanism` 只能由 `auth()` / `oauth2()` 显式给出）；其余几条是重构残留，会让读者误以为存在兜底逻辑
- **建议**：删 `index` / `expired` / `eofAtEnd` / 不可达 `return` 与扩容分支；`:142` 去掉重复条件；`selectMechanism` 要么接成公开的「自动选择」入口，要么删除并让 `:230` 直接用 `mechanism.getOrThrow()`；`:233` 删除或补注释说明是防御性重复校验

### [轻微][存量] `writeData` 两个分支返回值完全相同（#11）

- **位置**：`f_email/src/smtp/SmtpClient.cj:330-344`
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §2「表现形式不同的重复逻辑」、§1「恒真恒假分支」
- **证据**：静态确定 —— `if (!finalReply.isSuccess())` 分支与末尾 `return` 的 `SendReport(messageId, accepted, rejected, reply: finalReply)` 四个实参逐字相同，只是注释不同
- **描述**：这不是「为可读性展开」，而是两份逐字相同的构造；结合 #1，它恰好暴露了「本该在这里区分成败却没区分」
- **建议**：合并为一个 `return`；若按 #1 在失败分支改写 `accepted`/`rejected`，两支才真正产生差异

### [轻微][存量] 枚举经 `toString()` 转字符串比较，共 7 处（#12）

- **位置**：`f_email/src/smtp/SmtpClient.cj:153`、`:277`（`policy.toString() == "BestEffort"/"AllOrNothing"`）；`f_email/src/smtp/SmtpClientBuilder.cj:125`、`:128`、`:147`、`:218`、`:233`（`tlsMode.toString() == "None"/"StartTls"`）；同类形态另有 `f_email/src/smtp/SendReport.cj:117-125`（`io.stage.toString() == "Timeout"`）
- **来源**：存量（`164ed4e540` / `d9809c4196`）
- **判据**：review-checklist §2「字面量复制」、§10「仓颉语言特性：`match` 优于字符串比较」
- **证据**：静态确定 —— 同一组枚举值在 5 个位置以字符串字面量重复判断；`TlsMode.toString()` 一旦改文案（例如改成 `"STARTTLS"`），所有判断静默失效且编译器不报错
- **描述**：`match` 有穷尽检查，改枚举会编译报错；字符串比较把编译期错误推到运行期，且每次比较都多一次 `toString()` 分配（构建期一次性，影响可忽略，主要是正确性风险）
- **建议**：改为 `match (tlsMode) { case TlsMode.None => ... }`；`SendPolicy` 同理；`IoStage` 的比较可换成 `match`

### [轻微][存量] 数字解析重复实现两处，`SmtpCapabilities.size` 无溢出保护（#13）

- **位置**：`f_email/src/smtp/SmtpCapabilities.cj:62-69`、`f_email/src/smtp/SmtpReply.cj:90-99`
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §2「只改类型名 / 换算复制」、§11「边界」
- **证据**：静态确定（重复）+ 待确认（溢出语义）—— 两段都是 `for (b in text.toArray()) { if 非数字 return None; n = n*10 + (b-'0') }`，差异只有 `size` 额外把空串判成 `Some(0)`；`size` 的输入是服务器给的任意长度数字串（`SIZE 999…`），循环内无位数上限也无溢出判断（仓颉整数溢出的默认行为需查语言文档，本机无本地文档副本，记待确认）。若抛异常，异常类型不是 `MailException`，会绕过 `isRetryable` 分类；若回绕，则得到负数或错误上限，`send()` 的大小比较（`:137-141`）随之失真
- **描述**：`SmtpReply.parseInt` 只解析固定 3 位（`SmtpReply.cj:69`）因此安全，`size` 直接吃远端长度；重复实现让「加位数上限」必须在两处都改
- **建议**：抽 `parseDecimal(text: String, maxDigits: Int64): ?Int64`（超位数或溢出返回 `None`）两处共用；`size` 另加 `if (trimmed.size > 18) return None`

### [轻微][存量] 手写逐字节拷贝 9 处，可统一用 `copyTo`（#14）

- **位置**：`f_email/src/transport/LineChannel.cj:207-209`、`:253-255`、`:286-292`、`:312-315`、`:429-431`、`:438-442`；`f_email/src/transport/DotStuff.cj:148-151`、`:231-233`、`:252-254`
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §2「换控制流 / 同一操作多处复制」
- **证据**：静态确定 —— 同一份「`for i in 0..n → dst[i] = src[j+i]`」在传输层重复 9 次；文件里已用过 `Array.copyTo`（`LineChannel.cj:233`），说明 API 可用，只是没有统一
- **描述**：除一致性外，`pushBack`（`:286-292`）与 `slicePending`（`:438-442`）每次调用都逐元素重建 `ArrayList`，属「同一语义两种写法」，后续优化缓冲时容易漏改其中一处
- **建议**：统一成 `copyTo`（按 std 签名传 `srcStart`/`dstStart`/`len`），只在确实需要新容器处保留循环

### [轻微][存量] 自动补的 `Message-ID` 缺时间戳，与设计文档格式不符；`Random()` 种子语义待确认（#15）

- **位置**：`f_email/src/smtp/SmtpClient.cj:451-453`（`Random().nextUInt64().toString()`）、`:433-436`（拼成 `<token@domain>`）
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约」
- **证据**：静态确定（格式与字段）+ 待确认（`Random()` 默认种子）—— 承诺源 `doc/f_email设计文档.md:750`：补 `<{时间戳}.{随机}.{domain}>`；实现只有随机数、没有时间戳，分隔符也用 `@`。`Random` 默认构造的种子语义（时间/进程/线程）需查标准库文档，本机无本地文档副本，记待确认
- **描述**：若默认种子在同一毫秒内相同，两封邮件会得到同一个 `Message-ID`，接收端可能按重复邮件去重 → 丢信；即便种子足够随机，也丢了文档承诺的时间维度（排障可读性与碰撞概率都变差）
- **建议**：改成 `<${MonoTime.now().nanoseconds}.${counter}.${token}@${domain}>`（进程内单调计数 + 纳秒 + 随机），补一条用例：连续构造 1000 次全部互异

### [轻微][存量] `noop()` / `reset()` 不处理 421，`reset()` 还丢弃回复码（#16）

- **位置**：`f_email/src/smtp/SmtpClient.cj:159-171`
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §11「错误处理缺失」、§10 一致性（与 `send()` 路径不一致）
- **证据**：静态确定 —— `send()` 的每个回复都过 `abortIf421`（`:199`、`:208`、`:228`、`:242`、`:303`、`:329`），而 `noop()` 直接把 `SmtpReply` 交给调用方、`reset()` 把 `:170` 的读取结果整个丢掉
- **描述**：服务器在空闲期发 `421` 是正常的下线通知（RFC 5321 §4.2.5），`noop()` 返回 421 后连接实际不可用，但 `isClosed()` 仍为 false；`reset()` 更彻底，调用方无从知道 `RSET` 是否成功
- **建议**：两处都调用 `abortIf421(reply)`；`reset()` 返回 `SmtpReply`（或非 2xx 时抛 `MailProtocolException`）

### [轻微][存量] 注释与实现不符两处（`readExact` 的「跨轮复用」、`SmtpReply` 的「第一行」）（#17）

- **位置**：`f_email/src/transport/LineChannel.cj:214-215`（注释「一块 64 KB 缓冲跨轮复用」vs 实际每次调用 `Array<Byte>(READ_CHUNK_BYTES, …)` 新建）；`f_email/src/smtp/SmtpReply.cj:31`（注释「第一行里的增强状态码」vs `extractEnhanced` 扫描全部行，`:101-119`）
- **来源**：存量（`164ed4e540`）
- **判据**：review-checklist §10「可读性 / 注释与实现不符」、§13（代码注释即契约）
- **证据**：静态确定 —— `:215` 是函数内局部变量，作用域止于本次调用；`extractEnhanced` 的 `for (line in lines)` 没有「只看首行」的跳出条件，返回第一个形如 `x.y.z` 的 token
- **描述**：前者会误导后续优化（以为已复用，实际每次 64 KB 分配，见优化方案 #2）；后者在 `550-…` 多行回复里可能取到第二行才出现的增强码，与注释承诺不同。另 `SmtpReply.cj:74-80` 的 `if/else if/else` 有三个分支、其中两侧都产出 `""`，可合并
- **建议**：改注释为「每次调用分配一次 64 KB 读块」或把它提成字段（优化方案 #2）；`extractEnhanced` 要么只看 `lines[0]` 并加注释，要么把注释改成「首个带增强码的行」

### [轻微][存量] 反向路径为空的语义自相矛盾：`Envelope` 文档允许 `<>`，`SmtpClient` 直接拒绝（#18）

- **位置**：`f_email/src/smtp/SmtpClient.cj:404-407`；对照 `f_email/src/model/Envelope.cj:24`（「反路径允许为空串（`<>`，退信场景）」）与 `doc/f_email设计文档.md:730`（同义）；而 `doc/f_email设计文档.md:1259` 的预检表又写「From 非空」
- **来源**：存量（`d9809c4196` / `164ed4e540`）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `prepare()` 对 `envelope.from.size == 0` 抛 `MailProtocolException("邮件缺少 From，无法投递")`；`buildMailFrom` 本身能正确拼出 `MAIL FROM:<>`（`:457-458`），说明拒绝发生在更上层
- **描述**：`MAIL FROM:<>` 是 RFC 5321 的合法且必需形态（DSN/退信），`DsnReturn`/`DsnNotify` 也已对外暴露；现在库既不能发退信，两处文档又互相矛盾（Envelope 注释说可以、设计文档 6.5 说不行），使用者只能靠试
- **建议**：先定规格：若要支持退信，把校验改成「`from` 允许空串，但 `Envelope.fromMessage` 仍要求 `From` 头」，并补 `MAIL FROM:<>` 用例；若不支持，改掉 `Envelope.cj:24` 与设计文档 730 的措辞，并在异常消息里写明「空反路径不支持」

### [轻微][存量] 测试里的死存储：`precomputeWritesSizeParameter` 的 `caught` 赋值后从未断言（#19）

- **位置**：`f_email/src/smtp/Smtp_test.cj:509`、`:515-517`（`caught = true`），`:518` 只断言 `SIZE=` 出现
- **来源**：存量（`d9809c4196`）
- **判据**：review-checklist §1「读了不用」、§10「测试有效性」
- **证据**：静态确定 —— `caught` 在 `catch` 里被赋 `true`，函数结束前没有任何 `@Assert(caught, …)`
- **描述**：该用例靠「服务器没有后续应答 → 必然抛异常」这个副作用才走到 `catch`，但没验证异常类型；若将来 `send` 在 `MAIL FROM` 之前就失败（大小计算回归），只要 `SIZE=` 曾写出过一次断言仍可能通过
- **建议**：断言 `caught` 且异常为 `MailIoException`；或改成让脚本给出完整 `250/354/250` 序列，直接断言 `report.isCompleteSuccess()`

> 范围外提示：`f_email/src/EmailFacade.cj:487-513` 的 `smtpClient()` 懒初始化无锁（属其他部分），它决定了 #6 的实际并发暴露面；`src/imap`、`src/pop3` 的实现不在本部分展开。

> 本部分存量缺陷 19 条（严重 2 / 一般 7 / 轻微 10），是否纳入修复待用户决定。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [堆内存] `fetchMessage` / `uidFetchMessage` 改为流式解析，去掉整封邮件的 `Array<Byte>` 中转

- **现状**：`ImapClient.fetchMessagesInternal` 用 `fetchInternal` 取 `FetchResult.body: ?Array<Byte>`（`ImapFetch.cj:567`），literal 在 `ImapClient.cj:1431` 已整段驻留，再包 `MemoryBodySource` 交给 `MimeParser`（`:813`）。一封 20 MB 附件邮件（base64 后约 27 MB）在解析期间常驻 ≈ 报文长度；`Email.body()`（`EmailFacade.cj:356`）走同一条路。上限 `maxLiteralBytes=64 MB`（`ImapClient.cj:1665`）。
- **方案**：`fetchMessagesInternal` 改用已有的 `fetch(set, items, sink)`（`ImapClient.cj:575`），在 `FetchSink.onBodyChunk` 里把字节喂给 `MimeParser`（解析器已按 `spoolThreshold` 分流，边读边落盘）；`FetchItem.body(section: BodySection.entire(), peek: true)` 保持不变，只换消费端。
- **预期**：峰值从 O(报文长度) 降到 O(spoolThreshold × 同时活跃的叶子 part)（按默认值约 1 MB 量级）；对 64 MB 上限的报文可去掉一整份 64 MB 副本。**收益待实测，不写成结论。**
- **代价**：需要适配 `FetchSink` 的「先 chunk 后 meta」顺序（设计文档 A.4 `:2485` 已记录这一约定）；解析中途失败要在流内提前中断；`fetchMessagesInternal` 由「收集结果再解析」变成「边收边解析」，错误定位（哪个 part）要多带上下文。语义不变：返回的仍是 `Array<MailMessage>`。
- **验证**：同机 `-O2`，20 MB 附件样本 20 轮，对比 `getAllocatedHeapSize()` 峰值与 RSS 峰值（改前 = 现实现，改后 = sink 版），同时断言解析结果（part 数、附件字节 MD5）一致；再用 1000 part × 0.9 MB 的构造样本看是否触到常驻上界。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

> 不是缺陷，是"还能更好"。本部分全部无性能基线，`证据状态` 一律为 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] 大文本正文的"字节 → String → 字节"三次物化

- **现状**：`text/*` 且解码后 ≤ `inlineTextLimit`（256 KB）的 part 存成 `PartBody.Text(String)`，原始字节被丢弃；> `inlineTextLimit` 但 ≤ `spoolThreshold`（1 MB）的存成 `Data(MemoryBodySource)`，`LeafBuffer.write` 期间还有 `ArrayList<Byte>` → `toArray()` 一份。`MimePart.text()`（`src/model/MimePart.cj:133-147`）每次都 `readAll(source.open())`（一份 `ArrayList` + 一份 `Array`）再 `CharsetResolver.decode`（再一份 `String`）；`MailAttachment.rawText().toArray()`（`EmailFacade.cj:183-185`）又复制一份。单封 1 MB 中文正文的峰值约为"源字节 + ArrayList + Array + String(UTF-8) + 输出 Array"≈ 4–5 份
- **方案**：`MimePart` 在 `Data` 分支记录 `charsetUsed` 后不再二次解码（`text()` 结果做一次性缓存，避免 `Email.body` 与 `MailAttachment.size/read` 各解一次）；`MailAttachment` 的 `size/read/open` 统一走同一个 `?Array<Byte>` 惰性缓存，避免三个入口各自物化
- **预期**：单封 1 MB 文本正文的瞬时副本从 4–5 份降到 2 份；`Email.body()` 后再调 `attachments[0].size` 不再触发第二次解码
- **代价**：`MimePart` 增加一个 `?String` 缓存字段（内存换 CPU，对大 part 反而长期占住 String）；对 `StreamBodySource` 仍只能物化一次，需明确"第二次调用抛异常"的既有语义不变
- **验证**：`getAllocatedHeapSize()` 在 `parse → text() → size() → read()` 全链路前后对照 + 峰值 RSS，样本 256 KB / 1 MB / 8 MB 各 100 封
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 附件来源的释放责任未闭环（与上条"严重"同源，此处的方案是"把释放做成默认可达"）

- **现状**：`FileBodySource(owned=true)` 持有磁盘文件，只有 `close()` 会删；`MailAttachment`/`MailBody`/`MailMessage`/`MimePart` 都不可关闭，门面使用者拿不到 `BodySource`
- **方案**：`MailMessage <: Resource`，`close()` 递归遍历 `PartBody.Data(BodySource)` 调 `close()`；`MailBody`/`MailAttachment` 转发到所属 `MailMessage`；`Email.body()` 文档写"用完 `close()`"。或提供 `MailAttachment.closeAll(attachments)`
- **预期**：收信轮询场景下临时目录文件数从"随封数线性增长"变为"≤ 同时在处理的邮件数"
- **代价**：语义变更（使用者必须 close，否则行为与现在一致）；`MailMessage` 变成 `Resource` 后 `imap.uidFetchMessage` 的返回值也要纳入生命周期文档
- **验证**：循环拉取 1000 封（每封 2 MB 附件）后统计 `TMPDIR` 下 `_f_email_*.tmp` 数量与总字节，对照 close 前后
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Email.text()` / `Email.attachments()` 各自触发一次完整 `fetch` + MIME 解析

- **现状**：`text(mail)`（:382）直接 `fetch(mail).text()`，`attachments(mail)`（:377）走 `body(mail)` 再 `fetch(mail)`；`body()`（:367）本身也是一次 `fetch`。调用方写 `email.text(m); email.attachments(m)` 时，同一封邮件被 `UID FETCH BODY.PEEK[]` 两次（IMAP）或 `RETR` 两次（POP3），MIME 也解析两遍；POP3 下两次 `RETR` 之间邮件可能被删，导致"取到正文但附件抛错"
- **方案**：`Email` 内加一个"最近一封已解析邮件"的 1 条缓存（键 = `protocol + mailbox + id`，值 = `MailMessage`），`fetch/body/text/attachments` 共享；或直接把 `text`/`attachments` 标为便利方法并要求调用方用 `body()` 一次取全
- **预期**：连续取正文+附件时，网络往返与解析次数从 2 次降到 1 次（IMAP 一次 `BODY.PEEK[]` 通常 10–100 ms 量级，取决于服务器与邮件大小）
- **代价**：多持有 1 封已解析邮件（含 `Text` 正文与附件来源），内存峰值上升；需要失效条件（`delete`/`close` 时清空）
- **验证**：`ScriptedTransport` 记录的命令行数（`UID FETCH` 次数）从 2 → 1；真实服务器上分段计时 `text()+attachments()` 端到端耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Email.list`（POP3）逐封 `TOP` 的串行往返

- **现状**：`list(limit)` 对 `[start, infos.size)` 逐封 `pop3.topMessage(number, 0)`（:326-343），默认 `limit=20` 即 20 次串行 C→S→C 往返；`limit <= 0`（"全部"）时往返次数 = 邮箱总封数，摘要数组也随之线性增长
- **方案**：短期把"列出 N 封"的默认 `TOP 0` 与 `LIST` 合并成一次多行 `LIST` + 只对需要的封取头部（保持现状但明确上限）；中期若调用方只需要数量/大小，直接返回 `pop3.list()` 的结构化结果而不取头部（新增 `listSizes()`）
- **预期**：20 封场景下 20 次往返 → 1 次；1 万封 + `limit: 0` 时不再产生 1 万次往返与 1 万条摘要
- **代价**：新增 API，或默认行为变化（`subject`/`date` 变为可选）；POP3 无批量取头命令，做不到真正的 1 次往返出全部头部
- **验证**：本地 POP3 假服务器 + 真实服务器（163/QQ）上 `list(limit: 20)` 的端到端耗时与命令计数
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 3 部分 -->

> 性能类结论均无测试数据，按铁律只作「待验证假设」的依据，不给降幅。

### [堆内存] 非流式 FETCH 去掉一次整段中转与一次 `toArray`

- **现状**：单条 literal 的最大长度为 `maxLiteralBytes` = 64 MB（`ImapClient.cj:1665`）；取正文时同时存在 `readExact` 返回数组、`ArrayList<Byte>` 内部数组、`toArray()` 结果三份（`ImapClient.cj:663-680`）。
- **方案**：非 sink 分支直接保留 `valReadLiteralBytes(length)` 的返回值；多条 literal 需要拼接时用 `Array<Byte>(total)` + `copyTo`。
- **预期**：单条正文峰值从 3 × n 降到约 1 × n + 解析期所需（对象数减少 2 个整段数组；`ArrayList` 扩容复制消除）。不做百分比承诺。
- **代价**：多 literal 的拼接逻辑要显式写（现在靠 `ArrayList` 自动扩容）。
- **验证**：对 20 MB / 64 MB 两档正文跑 `cjpm bench -O2`，同时采 `getAllocatedHeapSize()` 峰值与 RSS；对比改前改后各 5 轮中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `ImapIdleSession` 事件队列里的 `raw` 整行常驻

- **现状**：队列上限 1024 条（`ImapIdle.cj:88`），每条 `ImapEvent` 带 `raw` 整行（`ImapIdle.cj:51-68`，`classify` 里直接赋值 `raw: line`），单行受 `maxLine` 8192 限制；消费者不取时最多常驻 1024 × ~8 KB ≈ 8 MB。
- **方案**：`Other` / `Bye` 事件保留全文，`Exists` / `Expunge` / `Recent` / `Fetch` / `Vanished` / `Flags` 只保留截断后的前 N 字节（或只留 `sequence`），需要原文时由调用方按 tag 重取。
- **预期**：稳态常驻从约 8 MB 降到数百 KB；队列满时丢弃事件的行为不变。
- **代价**：`ImapEvent.raw` 的语义从「整行」变成「可能截断」，是公开字段的契约变化。
- **验证**：IDLE 空转 30 分钟 + 突发 5000 条 `EXISTS`，对比堆峰值与 GC 次数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `store` / `append` / `itemsText` 用 `+` 逐段拼命令

- **现状**：`store`（`ImapClient.cj:868-887`）、`append`（`:987-1008`）、`appendBytes`（`:1033-1054`）、`itemsText`（`:1330-1344`）、`status`（`:524-533`）都是 `var s = ""; s = s + ...` 的循环拼接，元素数 = flags / items 数（个位数到几十）。
- **方案**：换成 `StringBuilder`（`std` 有；用 `cangjie-doc-lookup` 核对 `StringBuilder.append` 签名后落地），或先算总长一次成形。
- **预期**：单次命令的分配次数从 O(n) 降到 O(1)；n 很小时收益在噪声内，只对 `UID FETCH 1:*`（n=1）无收益。
- **代价**：几乎为零。
- **验证**：`cjpm bench -O2` 跑 10 万次 `store`（8 个 flag）对比总耗时与分配量；先证明它占端到端 > 5%。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `append` 把整封邮件序列化两遍（`ByteCounter` 一遍 + 写连接一遍）

- **现状**：`ImapClient.cj:984-986` 先用 `MimeWriter(ByteCounter)` 走一遍整棵 `MimePart` 树只为拿字节数，`:1016` 再走一遍写连接；注释说明这是为了 `{n}` 精确且不落临时文件。
- **方案**：保留双遍（正确性优先），但把「一遍」的代价测出来：若 `MimeWriter` 是纯遍历 + 编码，第二遍可复用第一遍算出的每个 part 的编码长度缓存（需要 `MimeWriter` 支持「dry-run 结果」）；否则考虑把 `LITERAL+` 之外的路径改成先写临时 spool（会引入磁盘 I/O，未必更优）。
- **预期**：`APPEND` 的 CPU 约减半（仅序列化部分），端到端取决于网络占比。
- **代价**：`MimeWriter` 要暴露 dry-run 结果，跨模块改动（`mime/**` 不属本部分）。
- **验证**：`cjpm bench -O2` 对 1 MB / 10 MB 报文各 100 次 `append`，分段计时「计数遍 / 写遍」占比；占比 < 5% 则不做。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

> 本部分没有任何 `cjprof` / `cjpm bench` 基线，四条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [CPU] `QuotedPrintableDecoder.read` 每次最多产出 1 字节，且每个字节新建一个 `ArrayList`

- **现状**：`f_email/src/model/QuotedPrintable.cj:218-234` 的 `read()` 每次调用只把 `pending` 里的**一个**字节搬给调用方（`decodeSome` 的每个 `return` 都只 `pending.add(...)` 一次，`246-310`），下一次调用又 `pending = ArrayList<Byte>()`（`223`）重建容器；`next()`（`314-334`）每次重新填充输入缓冲时还 `let tmp = Array<Byte>(inBuffer.size, repeat: 0)`（`319`）再逐字节拷进 `inBuffer`（`325-327`）。消费者 `decode()`（`41-56`）给的是 8192 字节缓冲，但每轮只拿到 1 字节。
- **方案**：(1) `decodeSome` 改成"填满 `pending`（或消费完输入块）再返回"，把软换行/非法序列的 `continue`/`return` 语义保留；(2) `pending` 只分配一次并复用（`clear()` 而不是新建）；(3) `next()` 直接 `input.read(inBuffer)`，去掉 `tmp` 与拷贝。
- **预期**：输出 1 MB QP 正文时，容器分配次数从 ~10⁶ 降到 ~10²，`read` 调用次数从 10⁶ 降到 10³ 量级；端到端收益取决于解码在解析总耗时中的占比（**未测**）。
- **代价**：状态机改动需要严格保持 `strict` 分支的异常位置与"跨块残留"语义（`266-308` 已按字节回退，改成批量后要保留 `pending` 的剩余部分），必须用现有 `Codec_test.cj` 的跨块用例回归。
- **验证**：`cjpm bench -O2` 跑 1 MB QP 正文的 `QuotedPrintable.decode`，对照改前后中位耗时 + `getAllocatedHeapSize()` 增量；再用 `cjprof record` 看 `QuotedPrintableDecoder.read` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 四处 O(n²) 字符串拼接（同一条链路上先后出现两次）

- **现状**：`f_email/src/model/MailAddress.cj:364-409`（`splitTopLevel`，`373/378/384/405` 每读一个 `Rune` 就 `current = current + String([ch])`，输入是整段 `To:` 头）、`284-295`（`AddressList.toString` 逐个 `out = out + item`）、`f_email/src/model/MimeParameter.cj:247-299`（`splitSegments`，同形态）、`f_email/src/pop3/Pop3Client.cj:477-485`（`sendMultiline` 逐行拼全文）。
- **方案**：前两处换 `StringBuilder`（`MimeParameter.toHeaderValue` 已经在用，`71-88` 可直接对齐）；`splitSegments`/`splitTopLevel` 还可以改成"记录切点下标、最后一次性 `text[a..b]` 切片"，避免逐字符搬移；`sendMultiline` 按 #6 改成直接返回 `Array<String>`，这一处直接消失。
- **预期**：单次 `AddressList.parse` 的字符串拷贝量从 O(n²) 降到 O(n)；对 64 KiB 的 `To:` 头（`maxHeaderLine` 默认值）拷贝量从 ~2×10⁹ 字节降到 ~65 KiB。
- **代价**：`StringBuilder` 需要额外一份最终 `toString()` 拷贝；切片方案要保持对 `\\` 转义与引号状态的精确处理，改完必须回归 `Message_test.cj` 的 9 条地址用例。
- **验证**：`cjpm bench -O2` 用 1 KiB→64 KiB 六档 `To:` 头测 `AddressList.parse` 耗时曲线，确认从平方变线性；`cjprof` 看 `String.+` / `StringBuilder.append` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MimePart.readAll` 全量物化正文且逐字节 `add`，没有大小上限

- **现状**：`f_email/src/model/MimePart.cj:202-215` 把 `InputStream` 读到底进 `ArrayList<Byte>`，每次 `add` 一个字节，最终 `toArray()` 再复制一份；`MimePart.text()`（`133-145`）对 `PartBody.Data` 直接全量物化后 `CharsetResolver.decode`。同一形态还出现在 `f_email/src/pop3/Pop3Reply.cj:130-146`（`Pop3Multiline.readAll`）与 `f_email/src/model/QuotedPrintable.cj:44-55`。
- **方案**：(1) 按 `BodySource.size` 预分配 `ArrayList(capacity)`（`BodySource` 已有 `size` 字段，见 `Message_test.cj:236` 的 `source.size` 用法），消除倍增扩容与最终 `toArray` 复制；(2) `text()` 增加 `maxBytes` 上限（复用 `MimeParseOptions.maxBodyBytes`），超限抛 `MailLimitException(LimitKind.Body, …)` 而不是无限吃内存；(3) 超过 `inlineTextLimit` 的正文干脆不解码成 `String`，让调用方走 `source()` 流式读。
- **预期**：读 1 MB 正文时峰值从"1 MB（字节缓冲倍增后可达 2 MB）+ 1 MB（`toArray` 副本）+ 解码结果"降到"1 MB + 解码结果"；有上限后最坏峰值与配置成正比，不再随邮件大小无界增长。
- **代价**：`text()` 的语义从"总是成功"变成"超限抛异常"，属契约变更，需要在 README 写明；预分配依赖 `BodySource.size` 准确（`StreamBodySource` 可能返回 0/未知，需要回落）。
- **验证**：解析 10 条 1 MB / 100 条 100 KB 的 `text/plain` 邮件，对比 `getAllocatedHeapSize()` 与峰值 RSS（`mem §1.2` 的有界稳态判定）；同时记录 `text()` 抛限次数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] POP3 `deleteMarks` 与 `pendingDeletes` 每次全量复制

- **现状**：`f_email/src/pop3/Pop3Client.cj:95`（`HashSet<Int64>`）与 `147-155`（`pendingDeletes` 每次遍历集合重建 `ArrayList` + `toArray`）。标记数量 = 本次会话 `DELE` 的邮件数，批量清理场景可达万级。
- **方案**：`pendingDeletes` 返回 `Array<Int64>` 时直接对外承诺"快照"，但用 `HashSet.toArray()`（若 std 提供）替代双重拷贝；或缓存上一次快照并按 `dele`/`rset` 增量失效。
- **预期**：单次调用省一次完整复制（万级时为 ~80 KB / 次），高频轮询 `pendingDeletes` 的调用方收益更明显（**未测**）。
- **代价**：需要确认 `HashSet` 是否有 `toArray` 直接导出（否则维持现状即可，收益不足以引入缓存失效逻辑）。
- **验证**：`cjpm bench -O2` 对 1 万个标记连续取 1000 次快照，对比耗时与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

### [堆内存] 复用 `readExact` 的 64 KB 读块，并给调用方一条分块交付路径

- **现状**：每次 `readExact(count)` 分配 ①结果数组 `Array<Byte>(count)`（`LineChannel.cj:197`）、②64 KB 读块（`:215`）；IMAP 每封邮件至少一次 literal 读取（`ImapClient.cj:716`，单次上限 64 MiB），而 IMAP 侧已有流式路径 `valReadLiteral`（`ImapClient.cj:718-733`）可以避开整块物化
- **方案**：把 64 KB 读块提成 `LineChannel` 的 `private let readBuf`（构造时一次分配）；`readExact` 保留（少数调用方需要整块），另提供 `readExact(count, consumer: (Array<Byte>) -> Unit)` 让 IMAP 侧统一切过去
- **预期**：每次 literal 少一次 64 KB 分配；改走回调后峰值内存从「1 个 literal 全量」降到「1 个 8 KB 块」，具体降幅依 literal 大小而定
- **代价**：`LineChannel` 每连接多 64 KB 常驻；回调式 API 需改 IMAP 调用点，等价性要逐用例验证
- **验证**：`getAllocatedHeapSize()` 差值；拉 100 封带 1 MB 附件的邮件，对比改前改后分配量与 RSS；`cjpm bench -O2` 同机
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 复用 `fill()` 的临时缓冲，避免每轮分配与逐字节 `add`

- **现状**：`fill()` 每轮 `Array<Byte>(8192)`（`LineChannel.cj:412`）后逐字节 `pending.add(tmp[i])`（`:429-431`）；长连接（IMAP IDLE、批量 FETCH）下每 8 KB 都走一遍
- **方案**：把临时块提成字段再 `copyTo` 进 `pending`（或直接维护 `Array<Byte>` 环形缓冲）；`compactIfNeeded` 阈值同步调整
- **预期**：每 8 KB 少一次分配 + 8192 次单元素 `add`；实际降幅需 profile
- **代价**：`pending` / `pendingPos` 语义不变，但缓冲实现改动面较大，`pushBack` 需同步改；必须用 `LineChannel_test` / `LineChannelLargeRead_test` 全量回归
- **验证**：`cjprof record` 跑「10 万行 × 200 B 的 readLine」与「100 次 1 MB readExact」，对比 `fill` 自耗时占比与分配量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `prepare()` 的「先计数再发送」把整封邮件序列化两遍

- **现状**：`precomputeSize(true)` 或 `maxMessageBytes > 0` 时，`prepare` 先用 `CountingSink` 完整序列化一次（`SmtpClient.cj:414-418`），`writeData` 再序列化一次（`:323-327`）；设计文档 6.5 允许「只写计数 sink」，所以这是已知取舍而非缺陷
- **方案**：保留计数路径，但在 `maxMessageBytes > 0` 且所有 part 的编码后大小可预知（7bit / base64 的 `BodySource` 已知 `size`）时直接求和，跳过第一遍；QP 编码长度依赖内容，不纳入
- **预期**：带附件的邮件可省一次 O(size) 序列化 + 一次 Base64 编码；占比取决于附件大小
- **代价**：需维持「编码后大小可预知」这一前提，漏判会算错 `SIZE=`（比多花 CPU 更糟），必须按 part 类型白名单实现
- **验证**：`cjpm bench -O2`，输入 1 KB / 1 MB / 10 MB 三档，对比 `send` 端到端耗时中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `fetchMessage` 的整封物化是 `Email.body()` 路径的峰值主项 | `f_email/src/imap/ImapClient.cj:809-816`、`:1431` | 该路径堆峰值占端到端峰值的比例 | 20 MB 附件样本跑 `cjprof heap`，对照 sink 版本；记录 `getAllocatedHeapSize()` 与 RSS 峰值 |
| 2 | 1000 part × 每 part 0.9 MB 可把常驻内存推到接近 900 MB（`maxParts × spoolThreshold`） | `f_email/src/mime/MimeOptions.cj:32-38`、`MimeParser.cj:301` | 构造样本下的真实峰值与是否先被 `maxHeaderBytes`/`maxParts` 挡住 | 生成 1000 part 的 multipart 样本（每 part 0.9 MB 二进制），`cjpm bench` 或独立程序跑一轮，采 RSS |
| 3 | 未转义的服务器行写进 `f_log`/文件时确实能造成日志注入（终端控制序列 / 伪造行） | `f_email/src/transport/MailTrace.cj:38-52`、`LineChannel.cj:471-483` | 是否有调用方把 `MailTrace.onLine` 直接落文件 | 全仓搜 `MailTrace` 的实现类与 `onLine` 落盘路径；有则构造含 `\x1b`/裸 CR 的服务器回复复现 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MailAttachment.read()` 的逐字节 `add` 在 MB 级附件上是主要开销 | `f_email/src/EmailFacade.cj:144-154` | 该函数自耗时占 `read()` 的比例 | `cjprof record` 跑 `read()` 10 MB × 100 次；对照块拷贝版本（`cjpm bench -O2`，中位数 + 离散度） |
| 2 | `Email.list(limit: 0)` 在万封信箱上既有内存峰值也有超时风险 | `f_email/src/EmailFacade.cj:316-344` | 1 万封时的耗时分布与摘要数组峰值 | 本地假 POP3 服务器造 1 万封，测 `list(limit: 0)` 的 P50/P95 与 `getAllocatedHeapSize()` 增量 |
| 3 | 大文本正文的 4–5 份副本是收信路径的峰值内存主因 | `f_email/src/model/MimePart.cj:133-147`、`f_email/src/EmailFacade.cj:183-185` | 解析→取正文的峰值 RSS 拆分 | `parse`、`text()`、`size()`、`read()` 四段分别记 RSS/heapUsed，样本 1 MB、8 MB |
| 4 | `Email.text()+attachments()` 的两次 `fetch` 在 IMAP 上是可感知延迟 | `f_email/src/EmailFacade.cj:367-384` | 两次 `BODY.PEEK[]` 各自的往返耗时 | `ScriptedTransport` 记录命令数 + 真实服务器分段计时（同一封 2 MB 邮件） |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `valFetchStreamInto` 的 token 化 + `ImapParser.parse` 每次响应都新建多个 `ArrayList<Byte>`/`String`，是 `UID FETCH 1:*` 批量同步的主要 CPU 项 | `ImapClient.cj:604-708`、`ImapParser.cj:39-59` | 自耗时占比、调用次数 | `cjprof record` 跑「5000 封 × 2 KB 的 `UID FETCH (UID FLAGS RFC822.SIZE)`」，看 `ImapParser.parse` / `parseAtom` self time |
| 2 | 非流式 literal 的「逐字节 `add` + `toArray`」在 20 MB 正文上占取正文时间的一半以上 | `ImapClient.cj:663-665` | 单封 20 MB 的分段耗时 | 分段计时（`readExact` / 累加 / `toArray` / `MimeParser.parse`）各跑 20 次取中位数 |
| 3 | `append` 的计数遍与写遍各占 `APPEND` 端到端 20%± | `ImapClient.cj:984-1016` | 两遍耗时与网络耗时 | `cjpm bench -O2`，10 MB 报文，100 次，记录两遍耗时 |
| 4 | IDLE 的 `pollInterval` 默认 5 s 让每条连接每 5 s 唤醒一次，连接数上千时是不可忽略的空转 | `ImapIdle.cj:423`、`:212` | 唤醒次数与 CPU 占比、连接数 | 1000 条 IDLE 连接空转 10 分钟，采进程 CPU 时间与 `epoll`/select 次数 |
| 5 | `enqueue` 满队列丢最旧事件会让长时间不同步的消费者错过 `EXPUNGE`，最终状态与服务器漂移 | `ImapIdle.cj:356-376` | 丢弃计数与漂移样本 | 加计数器（丢弃条数）+ 消费者停 10 分钟后比对 `SELECT` 的 `EXISTS` |
| 6 | `ImapResponse.isTagged()` 等字符串比较在每命令 N 条响应上有可测开销 | `ImapResponse.cj:74-84` | 占比 | 与改成 `match` 的版本做 A/B，`cjpm bench -O2`，10 万条响应 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `PartStream.read` 的「逐字节 `source.readByte()` + 每次 `ensure`/边界判定」是解析 10 MB 附件时的主耗时（每字节至少一次虚调用 + `peekAt` 比较） | `f_email/src/mime/Boundary.cj:158-201`、`224-249` | 自耗时占比、调用次数 | `cjprof record` 跑 `MimeParser.parse` 解析 10 MB base64 附件（`Mime_test.largeAttachmentIsSpooled` 同款输入），看 `PartStream.read` / `ByteSource.readByte` / `atBoundary` 的 self time |
| 2 | `HeaderMap` 的线性查找 + `equalName` 每次 `toAsciiUpper()` 分配，在 1000 part 邮件里占解析时间的可观比例 | `f_email/src/model/HeaderMap.cj:51-78`、`171-173`；调用点 `MimeParser.cj:124-125`、`237` | 单封 1000 part 邮件里头部查找次数与分配量 | 在 `equalName` 加计数器 + `getAllocatedHeapSize()` 差值，跑 1000 part 输入；再试「存小写键 / 逐字节比较」版本对照 |
| 3 | #O1 的「3 字节一分配」对 GC 停顿的贡献高于其对总 CPU 的贡献（即先修 GC 比修算术更值） | `f_email/src/model/Base64Codec.cj:279-295`、`232-245` | GC 次数 / 停顿时间占比 | `cjprof heap` 或分配采样，解码 50 MB base64，记录 GC 次数与 STW 总时长 |
| 4 | 每 part 64 KB 缓冲（#O3）在「万级小 part」邮件上造成明显的分配抖动 | `f_email/src/mime/Boundary.cj:30` | 分配峰值与 GC 次数 | 构造 5000 个 1 KB part 的邮件，`getAllocatedHeapSize()` 峰值 + GC 次数，改初始容量后对照 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | QP 解码的"每次 1 字节 + 每字节新建容器"占整封邮件解析耗时的显著比例（正文为 QP 时） | `f_email/src/model/QuotedPrintable.cj:218-234` | `QuotedPrintableDecoder.read` 的自耗时占比、`ArrayList` 分配次数 | `cjprof record` 解析 100 封 500 KB quoted-printable 正文的邮件（`-O2`），看 `read`/`decodeSome` 占比与 GC 次数；同时用 `getAllocatedHeapSize()` 对照 |
| 2 | `AddressList.parse` 在 64 KiB `To:` 头上的 O(n²) 拼接是解析主路径热点 | `f_email/src/model/MailAddress.cj:364-409` | 6 档输入长度（1/4/16/64 KiB）的耗时曲线是否平方 | 写 `cjpm bench` 用例对 `AddressList.parse` 扫长度，取中位数；再对真实收件箱样本（1000 封）`cjprof` 看 `String.+` 占比 |
| 3 | `list()` / `uidl()` 在大邮箱上的峰值内存是现场 OOM 的来源之一 | `f_email/src/pop3/Pop3Client.cj:293-331`、`Pop3Reply.cj:130-146` | 20 万封邮箱 `LIST` 的 `getUsedHeapSize()` 峰值与回复字节数之比 | 用本地脚本 POP3 服务端生成 20 万行 `LIST`，解析前后采样 `getUsedHeapSize()`/RSS，记录比值；再验证加上限后的回落 |
| 4 | `Spool.createFile` 的 16 次重试在 `ENOSPC`/`EACCES` 下会把失败延迟放大到毫秒级并掩盖根因 | `f_email/src/model/Spool.cj:47-64` | 单次失败耗时、重试 16 次的总耗时、各 errno 分布 | 在只读目录 / 满盘 tmpfs 上各跑 100 次 `createFile`，记录耗时分布与最终异常文案 |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LineChannel.fill` + 逐字节 `add` 是 IMAP 批量 FETCH 的主要分配/CPU 来源之一 | `f_email/src/transport/LineChannel.cj:403-434` | `fill` 自耗时占比、每轮分配量 | `cjprof record` 跑 100 封 × 1 MB 的 `fetch`，取 `fill` / `readLine` 的 self time 与 `getAllocatedHeapSize()` 差值 |
| 2 | `readExact` 的 64 KB 块分配在长连接上是可测量的稳态分配 | `f_email/src/transport/LineChannel.cj:215` | 每秒 `readExact` 次数 × 64 KB | 在 `readExact` 入口加计数器，跑 10 分钟稳态 FETCH，算每秒分配字节数 |
| 3 | 每读写设置 socket 超时（`setReadTimeout`/`setWriteTimeout`，`tlsSocket` + `tcp` 各一次）在短命令往返中占比可观 | `f_email/src/transport/LineChannel.cj:370-401`、`MailConnection.cj:165-192` | 单次 setsockopt 开销、每命令调用次数 | `strace -c` 统计 `setsockopt` 次数与耗时，对照 `NOOP` 往返 P50/P99 |
| 4 | `prepare` 的双序列化在 1 MB 以上邮件上占总发送耗时 20% 以上 | `f_email/src/smtp/SmtpClient.cj:414-418` | 序列化耗时占比（内存 sink） | 分段计时：`prepare` 内 `MimeWriter.write(counter)` 与 `writeData` 各计一次，同输入 1 KB / 1 MB / 10 MB |

## 文件覆盖

> 与 `files/f_email.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/README.md` | .md | ✅ | — |
| 2 | `f_email/README_en.md` | .md | ✅ | — |
| 3 | `f_email/doc/f_email设计文档.md` | .md | ✅ | — |
| 4 | `f_email/doc/spec/add-f-email-client/design.md` | .md | ✅ | — |
| 5 | `f_email/doc/spec/add-f-email-client/proposal.md` | .md | ✅ | — |
| 6 | `f_email/doc/spec/add-f-email-client/specs/email-imap/spec.md` | .md | ✅ | — |
| 7 | `f_email/doc/spec/add-f-email-client/specs/email-message/spec.md` | .md | ✅ | — |
| 8 | `f_email/doc/spec/add-f-email-client/specs/email-mime/spec.md` | .md | ✅ | — |
| 9 | `f_email/doc/spec/add-f-email-client/specs/email-pop3/spec.md` | .md | ✅ | — |
| 10 | `f_email/doc/spec/add-f-email-client/specs/email-smtp/spec.md` | .md | ✅ | — |
| 11 | `f_email/doc/spec/add-f-email-client/specs/email-transport/spec.md` | .md | ✅ | — |
| 12 | `f_email/doc/spec/add-f-email-client/tasks.md` | .md | ✅ | — |
| 13 | `f_email/doc/spec/add-f-email-client/verification.md` | .md | ✅ | — |
| 14 | `f_email/doc/spec/reuse-f-email-stream-buffers/design.md` | .md | ✅ | — |
| 15 | `f_email/doc/spec/reuse-f-email-stream-buffers/proposal.md` | .md | ✅ | — |
| 16 | `f_email/doc/spec/reuse-f-email-stream-buffers/tasks.md` | .md | ✅ | — |
| 17 | `f_email/src/EmailFacade.cj` | .cj | ✅ | — |
| 18 | `f_email/src/EmailFacade_test.cj` | .cj | ✅ | — |
| 19 | `f_email/src/email.cj` | .cj | ✅ | — |
| 20 | `f_email/src/imap/ImapCapabilities.cj` | .cj | ✅ | — |
| 21 | `f_email/src/imap/ImapClient.cj` | .cj | ✅ | — |
| 22 | `f_email/src/imap/ImapCondStore.cj` | .cj | ✅ | — |
| 23 | `f_email/src/imap/ImapEnable.cj` | .cj | ✅ | — |
| 24 | `f_email/src/imap/ImapExt_test.cj` | .cj | ✅ | — |
| 25 | `f_email/src/imap/ImapFetch.cj` | .cj | ✅ | — |
| 26 | `f_email/src/imap/ImapIdle.cj` | .cj | ✅ | — |
| 27 | `f_email/src/imap/ImapMove.cj` | .cj | ✅ | — |
| 28 | `f_email/src/imap/ImapNamespace.cj` | .cj | ✅ | — |
| 29 | `f_email/src/imap/ImapParser.cj` | .cj | ✅ | — |
| 30 | `f_email/src/imap/ImapResponse.cj` | .cj | ✅ | — |
| 31 | `f_email/src/imap/ImapSearch.cj` | .cj | ✅ | — |
| 32 | `f_email/src/imap/ImapSort.cj` | .cj | ✅ | — |
| 33 | `f_email/src/imap/ImapSpecialUse.cj` | .cj | ✅ | — |
| 34 | `f_email/src/imap/ImapUtf7.cj` | .cj | ✅ | — |
| 35 | `f_email/src/imap/ImapValue.cj` | .cj | ✅ | — |
| 36 | `f_email/src/imap/Imap_test.cj` | .cj | ✅ | — |
| 37 | `f_email/src/mime/Boundary.cj` | .cj | ✅ | — |
| 38 | `f_email/src/mime/MimeOptions.cj` | .cj | ✅ | — |
| 39 | `f_email/src/mime/MimeParser.cj` | .cj | ✅ | — |
| 40 | `f_email/src/mime/MimeStreamBuffer_test.cj` | .cj | ✅ | — |
| 41 | `f_email/src/mime/MimeWriter.cj` | .cj | ✅ | — |
| 42 | `f_email/src/mime/Mime_test.cj` | .cj | ✅ | — |
| 43 | `f_email/src/model/Base64Codec.cj` | .cj | ✅ | — |
| 44 | `f_email/src/model/BodySource.cj` | .cj | ✅ | — |
| 45 | `f_email/src/model/CharsetResolver.cj` | .cj | ✅ | — |
| 46 | `f_email/src/model/Codec_test.cj` | .cj | ✅ | — |
| 47 | `f_email/src/model/ContentType.cj` | .cj | ✅ | — |
| 48 | `f_email/src/model/ContentType_test.cj` | .cj | ✅ | — |
| 49 | `f_email/src/model/EncodedWord.cj` | .cj | ✅ | — |
| 50 | `f_email/src/model/Envelope.cj` | .cj | ✅ | — |
| 51 | `f_email/src/model/HeaderMap.cj` | .cj | ✅ | — |
| 52 | `f_email/src/model/HeaderMap_test.cj` | .cj | ✅ | — |
| 53 | `f_email/src/model/MailAddress.cj` | .cj | ✅ | — |
| 54 | `f_email/src/model/MailDate.cj` | .cj | ✅ | — |
| 55 | `f_email/src/model/MailDate_test.cj` | .cj | ✅ | — |
| 56 | `f_email/src/model/MailException.cj` | .cj | ✅ | — |
| 57 | `f_email/src/model/MailMessage.cj` | .cj | ✅ | — |
| 58 | `f_email/src/model/Message_test.cj` | .cj | ✅ | — |
| 59 | `f_email/src/model/MimeParameter.cj` | .cj | ✅ | — |
| 60 | `f_email/src/model/MimePart.cj` | .cj | ✅ | — |
| 61 | `f_email/src/model/QuotedPrintable.cj` | .cj | ✅ | — |
| 62 | `f_email/src/model/Secret.cj` | .cj | ✅ | — |
| 63 | `f_email/src/model/Secret_test.cj` | .cj | ✅ | — |
| 64 | `f_email/src/model/Spool.cj` | .cj | ✅ | — |
| 65 | `f_email/src/model/Spool_test.cj` | .cj | ✅ | — |
| 66 | `f_email/src/model/TransferEncoding.cj` | .cj | ✅ | — |
| 67 | `f_email/src/pop3/Pop3Capabilities.cj` | .cj | ✅ | — |
| 68 | `f_email/src/pop3/Pop3Client.cj` | .cj | ✅ | — |
| 69 | `f_email/src/pop3/Pop3Reply.cj` | .cj | ✅ | — |
| 70 | `f_email/src/pop3/Pop3_test.cj` | .cj | ✅ | — |
| 71 | `f_email/src/smtp/SendReport.cj` | .cj | ✅ | — |
| 72 | `f_email/src/smtp/SmtpAuth.cj` | .cj | ✅ | — |
| 73 | `f_email/src/smtp/SmtpCapabilities.cj` | .cj | ✅ | — |
| 74 | `f_email/src/smtp/SmtpClient.cj` | .cj | ✅ | — |
| 75 | `f_email/src/smtp/SmtpClientBuilder.cj` | .cj | ✅ | — |
| 76 | `f_email/src/smtp/SmtpReply.cj` | .cj | ✅ | — |
| 77 | `f_email/src/smtp/Smtp_test.cj` | .cj | ✅ | — |
| 78 | `f_email/src/transport/DotStuff.cj` | .cj | ✅ | — |
| 79 | `f_email/src/transport/DotStuff_test.cj` | .cj | ✅ | — |
| 80 | `f_email/src/transport/LineChannel.cj` | .cj | ✅ | — |
| 81 | `f_email/src/transport/LineChannelLargeRead_test.cj` | .cj | ✅ | — |
| 82 | `f_email/src/transport/LineChannel_test.cj` | .cj | ✅ | — |
| 83 | `f_email/src/transport/MailConnection.cj` | .cj | ✅ | — |
| 84 | `f_email/src/transport/MailConnection_test.cj` | .cj | ✅ | — |
| 85 | `f_email/src/transport/MailTrace.cj` | .cj | ✅ | — |
| 86 | `f_email/src/transport/TlsMode.cj` | .cj | ✅ | — |
| 87 | `f_email/src/transport/TransportFactory.cj` | .cj | ✅ | — |
| 88 | `f_email/src/transport/TransportTestSupport_test.cj` | .cj | ✅ | — |

合计：`.cj` 72 个 / `.md` 16 个 / 共 88 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 安全 1 条（#8 filename 路径穿越）；语言特性 1 条（#14 `ToString` 未实现）；设计 2 条（#9 门面缺口、#10 可变状态无线程声明）。其余维度：`MailSummary` 值语义、`?MailDate` 空值链、`unit` 返回均为正常用法，未发现问题 |
| §1 死代码 | 1 | 逐个检查了本部分 4 个 `.cj` 的符号：`private`（`EmailConfig` 全字段、`ensureOpen`/`ensureMailbox`/`smtpClient`/`imapClient`/`pop3Client`/`imapDate`/`pad2`/`rawText`/`MailAttachment.part`）全部有引用；无 `internal`/`protected` 顶层声明；`public` 均在 `public` 顶层类型内（对外可达，按硬原则一不判），`ImapCapabilities` 的 `hasPrefix`/`size`/`isEmpty` 及多数 `supportsXxx` 仓内零引用只作信息；`return`/`throw` 后无同层语句；唯一命中是 `EmailFacade.cj:21` 未使用的 `import Charsets` |
| §2 重复逻辑 | 2 | 已把 `MailAttachment`/`MailBody`/`Email`/`EmailBuilder`/`ImapCapabilities` 的 30 余个函数体压成「输入→输出→副作用」两两比对：命中「流→字节数组」与「三协议工厂+close 三段」两组（#18、#19）；`list` 的 IMAP/POP3 两个分支摘要组装相似但字段来源与错误语义不同，判为业务差异不合并；三个 builder setter 是惯用链式写法，不算重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`、无 `throw UnsupportedException`；`case None => ()` 的 6 处均为 Option 正常缺省；命中 `close()` 三处 `catch (_: Exception) {}`（#11） |
| §4 栈溢出 | 0 | 本部分 4 个文件无递归（`list`/`read`/`saveTo`/`fromValues` 全是单层循环）；`MailAttachment` 不遍历 part 树，`collectAttachments` 的递归在 `MimePart`（属其它部分） |
| §5 OOM | 0 | 无「按报文头预分配」；`MailAttachment.read()` 的全量物化已在注释中声明"大附件请用 open"，不算契约违背；`list(limit: 0)` 的全量列举是调用方显式参数，其峰值写入「待验证假设 #2」。堆内存重复副本另见优化方案；#1 是磁盘增长，不在本节计 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，本部分任何"热点"结论都不成立；已把 4 条猜测写入「待验证假设」并注明采法 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁/`synchronized`（连接状态是裸字段），问题按并发正确性记在 §12 |
| §6.3 并发串行 | 0 | `Email.list`（POP3）逐封 `TOP` 是协议串行（单连接、无批量命令），不构成本可并行却串行的形态；其成本已进优化方案 [CPU] |
| §6.4 低效算法 | 1 | 命中 `MailAttachment.read()` 逐字节 `add`（#20）；`ImapCapabilities.toString()` 的循环字符串拼接是 O(n²)，但 n ≈ 能力条数（十几条），未达报告门槛，仅此说明 |
| §7 降堆内存方案 | 2 | 两条方案（大文本正文多次物化、附件来源释放闭环），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 两条方案（重复 fetch、POP3 逐封 TOP），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分两处大临时缓冲（`MailAttachment.read`/`saveTo` 的 64 KB `Array<Byte>`）都作为 `InputStream.read` 实参传给外部 API，`reuse-f-email-stream-buffers/proposal.md:12` 已记录「按实测无法 local 化」；其余临时对象（`MailSummary`、`ArrayList`）小且会逃逸为返回值，不满足 local 条件 |
| §11 现有代码的 BUG（存量） | 8 | 逐条核对了本部分读到的全部门面函数边界与空值：`limit <= 0`、`total <= 0`、`envelope.from` 空、`messages.size == 0`、`item.uid` 缺失、`user`/`secret` 缺失、`pop3Value` 失效、`quit()` 抛错、`flags` 空数组均已覆盖；命中 #2、#3、#4、#5、#6、#7、#15、#16 |
| §12 并发安全与锁粒度 | 1 | 命中 #10（可变共享状态 + 缺线程安全声明）。锁粒度：本部分无锁，无可缩小对象；`Email` 的价值在于连接串行，建议是"加声明"或"整段临界区"，不需要更细粒度 |
| §13 文档一致性（.md） | 2 | 13 个 `.md` 全部按 §13 核对：限额、`ENABLE` 语义、`QUIT` 语义、`Spool` 顺序、TLS 默认值与实现一致；命中 #21（verification G5 自述矛盾）与 #17（`list` 的 `TOP` 前置条件未写）；`doc/spec/**` 属归档变更，按"当时结论是否自洽"核对，不要求与现状逐字一致 |
| §14 功能完备性与 README 覆盖 | 2 | 命中 #9（`tlsConfig`/`oauth2`/`sendPolicy` 未接线）、#12（`MimeParseOptions` 不可达）。README 覆盖：`Email.builder` 示例在 `README.md:43`，`MailAttachment.saveTo/filename`、`MailSummary.receivedAt/isUnread` 均在示例出现（:64-76），未发现门面公开 API 完全无文档——`README.md:246/256` 的"其他公开 API"索引漏了 `MailSummary.sequence/flags/size` 与 `ImapCapabilities.size/toString`，属范围外提示（README 归其它部分统计） |
| 文件覆盖（§13 等） | 17/17 | 与本部分清单一一对应，无缺文件 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 5（`valReset` ×2、`body` 语义、`copyUidOf`、`QResyncParams`）、设计 1（扩展类复制错误处理）、语言特性 2（`toString` 比较枚举、`Option` 透传）、安全性 1（参数未校验；CRLF 注入已由 `LineChannel.writeLine` 拦住，未按漏洞计） |
| §1 死代码 | 1 | 已逐个文件机械核对：6 个包内 `func`（`valUntaggedLoop` / `encodeString` / `clearEnabled` / `setCapabilities` / `timeoutsValue` / `connectionValue`）全仓搜索只命中定义；2 个只写不读字段（`idName`/`idVersion`、`ImapIdleSession.started`）；1 处只写不读局部变量（`build()` 的 `capabilities`）。`ImapClient.collect` / `valUntaggedLoop` / `ImapParser.parseOne` 末尾的兜底 `return` 属编译器要求的可达性兜底，**不计**死代码（仅在此说明）。`public` 顶层声明（`ImapResponse`/`ImapFetch` 各结构、`ImapSort` 等）一律不判 |
| §2 重复逻辑 | 3 | ①`copyUidOf` vs `parseCopyUid`；②四处 `if (!isOk) throw` vs `expectOk`；③FETCH 的 literal 读取（`ImapClient.cj:636-675`）与通用 `collect()` 是同一件事的两种实现，只有前者处理 literal。另外逐个比对了 `ImapSort.sortInternal` / `threadInternal`（仅命令名与返回解析不同，未合并）；`ImapFetch` 的 `FetchResult.meta()` 与 `parseFetchMeta` 是字段搬运，不判重复 |
| §3 空实现 | 1 | `cramResponse` 的 `catch` 静默换算法（轻微）。另已核对：`IdleTrace.onBytes` 是 `MailTrace` 测试替身的有意 no-op，不计；主路径无 `TODO` / 空函数体 / 接口默认空实现 |
| §4 栈溢出 | 0 | 递归点只有 `BodyStructure.leafCount` / `BodyStructure.parse`、`ImapSort.buildThread` / `toNode`、`ThreadNode.flatten`；深度全部受 `ImapParser.MAX_DEPTH = 64`（`ImapParser.cj:35`、`:62-64`、`ImapSort.cj:234-237`）约束，嵌套深度由解析器先拒。`flatten`/`toNode` 深度等于已被限制的树深，无环结构 |
| §5 OOM | 1 | 非流式 literal 的 3 份拷贝 + `fetchMessagesInternal` 集合级无聚合上限（已量化：单条 ≤ 64 MB、整批 Σbody）。`ImapIdleSession` 队列已有 1024 条上限（`:356-372`），不判；`pendingExpunged`/`pendingVanished` 随服务器推送增长但受邮箱规模约束，列入优化方案 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`ImapParser.parse`、literal 逐字节累加、`append` 双遍序列化均列入「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | `ImapIdleSession` 的临界区只做队列读写与 `notify`（`:356-376`、`:154-175`），无 I/O / 解析 / 回调；`writeMutex` 只包一条 `writeLine`（`:182-190`、`:263-269`）。锁内无阻塞调用 |
| §6.3 并发串行 | 0 | 仅 IDLE 一条读线程 + 调用线程，无 `spawn` 后立即 `get()`（`startWorker` 的 `Future` 只在 `valJoin` 里等，且有 10 s 上限） |
| §6.4 低效算法 | 2 | 非流式 literal 的逐字节 `ArrayList.add`（O(n) 高常数）；命令拼接用 `+`（O(n²) 但 n 为个位数，只在优化方案里）。`SequenceSet.of`、`parseParams`、`toStrings` 均为线性。`ThreadNode.flatten` 子树整体复制（O(n·depth)），深度 ≤ 64，未单列 |
| §7 降堆内存方案 | 2 | literal 中转副本、IDLE 事件 `raw` 常驻（均为「无基线待验证」） |
| §8 降 CPU 方案 | 2 | 命令拼接、`append` 双遍序列化（均为「无基线待验证」） |
| §9 local mode 可行性 | 0 | 热点路径的临时对象（`ImapValue` 树、`FetchMeta`）都要跨函数返回（`valFetchStreamInto` → 调用方），逃逸检查不通过；`Array<Byte>` literal 是 `Array` 而非 `String`，无对应 mode 重载可用。收益无法用峰值内存证明 ⇒ 不列为方案 |
| §11 现有代码的 BUG（存量） | 12 | 本部分所有问题均为存量（工作区快照，无 diff）。已核对：`isTaggedLine` / `untaggedHead` 的边界（`line.size > tag.size` 守卫齐全）、`parseStatus` 的奇数项、`ImapDate.parse` 的宽容解析、`extractOrigin` 的 `<>` 定位、`hex4`/`nextTag` 的回绕（65535 分组正确）——均未发现缺陷，不单列 |
| §12 并发安全与锁粒度 | 3 | 双 `DONE`（严重）、join 超时后放开 idle、`idleActive`/`closedFlag`/`tagCounter` 无同步；`rounds`/`IdleTrace` 记为轻微。锁顺序已核对：`done()` 先 `mutex` 后 `writeMutex`（释放后取），`rebuild()` 先 `writeMutex`（短临界区）再 `mutex`（`enqueue`），不构成环形等待 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；README 与 public API 的对照由第 1 部分产出。本部分只发现「能力被声明但线上语法写错」（`SORT=DISPLAY`，已计入 §11），不属于 README 遗漏 |
| 文件覆盖（§13 等） | 12/12 | 无缺文件；本部分不含 `.md`，§13 文档一致性不适用 |

### 第 4 部分

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

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 #3（`getOrThrow` 逃逸）、#4（构造器默认值）、#5（对象别名）、#8（失步后继续用）；设计 #5（builder 所有权）/ #6（多行命令无上限）；语言特性 #4（引用语义默认值）、#16（`class` 的惰性缓存）；可读性 #14（枚举 `toString` 比较）、#15（残留 `import`）；安全性 #7（地址结构校验）、#9（临时文件权限）。逐项核对后未命中：`Secret` 的凭据保护闭环完整（`toString` 恒 `<redacted>`、trace 只屏蔽 `C` 方向、异常只带机制名）；`HeaderMap.set` 的 CR/LF 防线（`HeaderMap.cj:192-198`）与 `LineChannel.writeLine` 的逐字节拒写（`LineChannel.cj:300-311`）把 `Subject`/`filename`/`user` 的注入面都堵住了，`MimeParameter.needsExtended`（`309-316`）会把含 CR/LF 的 `filename` 强制走 RFC 2231 百分号编码，两条路径都验过 |
| §1 死代码 | 2 | 逐个 `private`（全仓搜）/ 默认 `internal`（本包及子包搜）过：`MailAddress` 的 6 个 private 静态 + 3 个包内静态、`MailDate` 的 12 个、`MimeParameter` 的 6 个、`MimePart` 的 1 个（`readAll`）、`Spool` 的 3 个、`Pop3Client` 的 17 个私方法全部有本文件内调用者；`QuotedPrintable.hexValue`/`HEX` 被 `MimeParameter.cj:328-329`、`EncodedWord.cj:227-228` 使用；`MimePart.readAll`（`internal`）被 `text()` 与 `Message_test.cj:220/234` 使用；`CollectingOutput`/`ArrayInput`/`Pop3Multiline` 三个包内类均有使用（`ArrayInput` 还被 `BodySource.cj:49` 用）；机制性命中 2 条：**#2 的 `lineLength` 字段"读了不用"**、**#11 的 `attachments()` 根守卫恒不改变行为**。另命中 **#15 的 3 个未使用 `import`**（`SendReport.cj:18` 的 `IoStage`/`MailAuthException`/`MailProtocolException`，全文再无出现）。对外可达的 `public`（`EmailAddress`/`AddressList`/`MailDate`/`MimeParameters`/`MimeParameter`/`PartBody`/`Multipart`/`MimePart`/`QuotedPrintable(Encoder|Decoder)`/`Secret`/`Spool`/`TransferEncoding`/`TransferDecoder`/`Pop3*`/`SendPolicy`/`RecipientStatus`/`SendReport`/`isRetryable`/`SmtpAuth*`）一律不判；`MimeParameter.formatValue`（`158-163`）仓内零引用，只记为"对外 API"，不作死代码 |
| §2 重复逻辑 | 1（#10，含 5 组实例） | 同文件两两比对后确认 5 组同语义实现：(a) `MailAddress.escape`（`88-90`）≡ `MimeParameter.escapeQuoted`（`318-320`）；(b) `MailAddress.decodeDisplayName` 的引号反转义（`138-141`）≡ `MimeParameter.unquote`（`301-307`）；(c) `MailAddress.stripComments`（`188-222`）≡ `MailDate.stripComments`（`332-366`，仅容器类型不同）；(d) `Pop3Capabilities.supports`/`args`/`get`（`66-94`）三段同构查找；(e) "读流进 `ArrayList<Byte>`"四处同形（`MimePart.cj:202-215`、`Pop3Reply.cj:130-146`、`Pop3Client.cj:489-507`、`QuotedPrintable.cj:44-55`）。差异点已核：无（错误文案、边界、可空性都一致），属可直接抽取的复制，抽取落点应为 `f_email/src/model` 内的 `internal` 工具（不跨模块、不新建共享包）。另核对但**不判**重复：`Base64Encoder` 与 `QuotedPrintableEncoder` 的断行骨架（各自协议状态机不同，属必要独立实现，但 #2 要求二者对 `lineLength` 的一致处理）；`monthName`/`monthValue` 两个 `match`（一个是 `Month→Int`、一个是 `Month→String`，方向不同）；测试里的准备代码 |
| §3 空实现 | 1 | #9 的 `catch (_: Exception) { attempt += 1 }`（`Spool.cj:59`）吞掉 16 次真实失败。`Spool` 的 Windows `restrictPermissions`（`117-120`）是**有注释说明的空实现**（"Windows 没有 POSIX 权限位"），按误报边界不判；`QuotedPrintable` 无空方法体；`Pop3Capabilities` 的"`-ERR` 回空表"是 RFC 2449 允许的合法降级且有注释与用例（`Pop3_test.cj:116-121`），不判 |
| §4 栈溢出 | 1 | #1 的 `AddressList.parseInto` 自递归（深度线性于输入 `:` 数、无上限）。已排除：`MailMessage.findBody`（`124-159`）、`MimePart.collectAttachments`（`192-200`）的递归深度由解析期 `maxDepth = 32`（`MimeOptions.cj:46`）约束，且树由不可变 `Multipart.parts` 构成、无自引用环；`MimeParameter.joinContinuation`（`199-245`）是 `while (true)` 但每轮要求 `index` 对应的键存在，键集合有限 ⇒ 必然终止；`findBody` 的两层循环与 `collectAttachments` 都是"遍历子节点"，不含自调用以外的递归形态 |
| §5 OOM | 1 | #6（`LIST`/`UIDL` 回复无字节/行数上限，峰值 ≈ 回复 3–4 倍；同一条链路上 `retr`/`top` 走 `copyBody` 流式，是有对照的正确形态）。已排除：`MimePart.readAll` 的上限缺失记在优化方案 3（`text()` 只对 `text/*` 调用，且解析期已有 `inlineTextLimit`/`spoolThreshold` 分流，判"能更省"而非"必 OOM"）；`Spool` 用临时文件而非内存；`MimeParameters.items` 以头参数个数为界；`deleteMarks` 以邮箱邮件数为界（服务器侧有界） |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof`/`cjpm bench` 数据，4 条疑似热点全部进「待验证假设」，不作发现、不进统计 |
| §6.2 大粒度锁 | 0 | 本部分没有锁：`MimePart`/`MailMessage`/`Pop3Capabilities` 无 `Mutex`/`synchronized`；`Pop3Client` 的同步语义是"单连接串行使用"，并发正确性靠调用方线程封闭（类注释与 `Resource` 契约都没承诺线程安全，见 #16 的说明） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无线程池；`Pop3Client` 的"一条命令一等回复"是协议要求（除 `PIPELINING` 能力外无法并发），且代码确实**没有**使用 `supportsPipelining`（`Pop3Capabilities.cj:120-124` 只暴露能力、无调用方），属功能未接线而非串行热点——不单列（信息项） |
| §6.4 低效算法 | 2 | #6 的 `text = text + line`（O(n²) 拼接）+ 一次多余的 join/split；优化方案 2 的四处字符级拼接。其余无嵌套循环匹配、无 `remove(at: 0)`、无重复编译正则（本部分不用正则） |
| §7 降堆内存方案 | 2 | 优化方案 3（`readAll` 预分配 + 上限）、4（`pendingDeletes` 复制），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 1（QP 解码 1 字节/次）、2（O(n²) 拼接），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无合格候选：`QuotedPrintable.encode`/`MimePart.readAll` 的临时缓冲要么作为返回值逃逸（`encode` 返回 `String`）、要么写进 `PartBody` 长期存活（`readAll` 的结果进 `Data`/`Text`），逃逸检查直接不通过；`MimeParameter.splitSegments` 的临时 `String` 虽在函数内，但收益量级是"几十个短串"，没有 `getAllocatedLocalObjectSize()` 前后峰值对照就无法证明，按 §9 结论写法只能留待下一轮 |
| §11 现有代码的 BUG（存量） | 17 | 全部 17 条均为存量（快照无 diff，`git blame` 落在 `4cefd27cd1 2026-10-29`）：严重 1 / 一般 8 / 轻微 8。另逐项核对了本轮读到的边界与空值：`AddressList.parseInto` 的空片段跳过（`300-302`/`316-318`）正确；`Pop3Reply.extractErrorCode` 的 `close <= 1` 边界正确；`MimeParameter.percentDecode` 的 `i + 2 < size` 边界正确（末位 `%XX` 可解）；`MailDate.formatOffset` 用 `-Int64(minutes)` 规避 `Int32.MinValue` 溢出；`Pop3Client.requireMessageNumber` 挡住 `<= 0` 的邮件号；`stat()` 的 `tokens.size < 1` 与 `parseMessageInfo` 的 `tokens.size < 2` 都有前置校验 |
| §12 并发安全与锁粒度 | 1（#16，轻微）+ 1 条信息 | 本部分唯一的跨线程共享面是 `MimePart` 的三个惰性缓存字段（`67-70`），getter 内无锁写入（`87`/`100`/`140`），见 #16。`Pop3Client` 的 `channelRef`/`authenticated`/`closedFlag`/`deleteMarks` 全是可变状态且无同步，但类未声明线程安全、使用模型是"一条连接一个线程"，按误报边界不按数据竞赛报，只在 #16 的说明里记为"需在 README 明确非线程安全"。锁粒度：本部分无锁可谈 |
| §14 功能完备性与 README 覆盖 | 3 | #2（`MimeWriteOptions.bodyLineLength` 对 QP 不生效，`README.md:267` 把它当公开配置）、#7（`MailAddress.cj:23-24` 与 `README.md:19` 都声称地址侧有"注入防线"，实际只有 CR/LF + 尖括号一道）、#17（`Pop3Client.login`/`list`/`quit`/`retrMessage` 未出现在 `README.md:276` 的成员清单里，而 `login` 是 `USER`/`PASS` 主路径——README 正文的完整审查属第 1–4 部分，合并时请去重）。其余本部分 `public` 符号已在 README 登记：`EmailAddress`/`AddressList`/`MailDate`/`MimeParameter(s)`/`QuotedPrintable*`/`Secret`/`Spool`/`TransferEncoding`/`TransferDecoder`/`Pop3*`/`RecipientStatus`/`SendReport`/`isRetryable`/`SmtpAuth*` 均在 `README.md:198`（模块级清单）内 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`（`f_email/README.md`、`README_en.md`、`doc/f_email设计文档.md`、`doc/spec/**` 属其他子轮）。§13 按"文档与源码交叉引用"抽查了 5 处（`README.md:19`、`198`、`267`、`276`、`277`），除 #17 点名的成员遗漏外，POP3 能力描述（`README.md:19`：`CAPA`/`STLS`/`USER`+`PASS`/`APOP`/`AUTH PLAIN`+`LOGIN`）与实现逐一对应；`README.md:182` 关于 `toHexString` 输出小写十六进制的说明与 `APOP` 摘要用例（`Pop3_test.cj:157-160`）一致 |

**范围外提示**（不计入统计）：`f_email/src/mime/MimeWriter.cj:189/198` 把 `bodyLineLength` 传给 QP 编码器（#2 的放大器）；`f_email/src/mime/MimeParser.cj:493-500` 的 `spill()` 是 `Spool.createFile` 的唯一调用方，`removeIfExists` 的清理对称性由第 6 部分审查。

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：DATA 失败误报成功（#1）、空收件人越界（#2）、AUTH 流错位（#3）；设计：`idle` 旋钮失效（#8）、DSN 静默（#9）；语言特性：枚举经字符串比较（#12）；可读性：注释不符（#17）、不可达代码（#10）；安全性：APOP 摘要泄漏（#7） |
| §1 死代码 | 1（7 处） | 已逐个机械过：`private` 符号全仓搜（`index` / `eofAtEnd` / `selectMechanism` / `domainOf` / `uniqueToken` / `lastLine` / `extractAddress` 等），`PreparedMessage` / `CountingSink` 的字段均有读取；`internal` 的 `Deadline.expired`（零引用）、`LineChannel.invalidate`（有调用）、`redactLine`（有调用）逐个搜；`protected` 本部分无；`public` 先判对外可达——`SmtpCapabilities` 各 prop、`SmtpReply.isTemporaryFailure`/`isPermanentFailure`、`MailConnection.remoteAddress`/`isTls`、`SmtpClient.noop`/`reset`、`ScriptedTransport` 均对外可达，只记「仓内无引用」不判死代码；`return` 后语句、恒真条件、不可达扩容/分支逐条列出（#10） |
| §2 重复逻辑 | 4 | 已把生产代码每个函数体压成「输入→输出→副作用」两两比对：`writeData` 两分支逐字相同（#11）、数字解析两处（#13）、逐字节拷贝 9 处（#14）、枚举字符串比较 7 处（#12）；`applyReadTimeout`/`applyWriteTimeout` 形状相同但对象不同（读/写超时），属刻意对称，不报；测试文件里的准备代码（`CollectOutput` 等）按 §2 误报边界不报 |
| §3 空实现 | 2 | `LineChannel.flush()` 为空但注释说明「裸 socket 无需 flush」（不算问题）；`ScriptedInput.setWriteTimeout` 空体属 `IoTimeout` 接口要求（不算问题）；`catch {}` 两处（`SmtpClient.close`、`sendReset`）已归入 #5；`SmtpClient.close` 的吞异常属清理路径，可接受但建议加注释；无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归：`DotStuffWriter` / `DotUnstuffReader` 是显式状态机，`SmtpReply.read` / `SmtpCapabilities.fromEhlo` 是单层循环，`MimeWriter` 的 part 递归不在本部分 |
| §5 OOM | 2 | `SmtpReply.read` 行数无上限（#4，远端驱动）；`LineChannel.readExact` 按调用方 `count` 一次性预分配且无内部上限（`:192-197`，仓内 IMAP 调用有 64 MiB 闸门，故并入 #4 说明）；`pending` 受 `maxLine` 约束，不构成无界 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，四个性能候选（fill 分配、readExact 读块、setsockopt、双序列化）全部进「待验证假设」，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分唯一生产锁是 `MailConnection.closeMutex`，临界区只有一次 `closedFlag` 赋值（`MailConnection.cj:151-159`、`:251-254`），socket 关闭在锁外；`ScriptedTransport` 的 mutex 是测试替身，锁内只做内存拷贝，无 I/O |
| §6.3 并发串行 | 0 | 生产路径无 `spawn` / `Future.get`（`spawn` 只出现在 `MailConnection_test.cj`）；并发上限来自单连接单通道，已归入 #6 |
| §6.4 低效算法 | 0 | 逐条核对：`SmtpCapabilities.has/value` 在 ≤10 项上线性；`notifyList` 拼接 k≤4；`pushBack`/`slicePending` 是 O(n) 单次拷贝；`readLine` 单趟扫描 + 游标；无嵌套循环、无 `remove(at: 0)`、无循环内重复编译正则 |
| §7 降堆内存方案 | 1 | 读块复用 + 分块交付（优化 #1）；`clear()` 不还物理内存、`gc()` 不保证归还这两条假象已在方案里规避，未计入收益 |
| §8 降 CPU 方案 | 2 | `fill` 缓冲复用、`prepare` 双序列化（优化 #2/#3），均标为「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 热点对象（`readExact` 结果、`pending`、`PreparedMessage`）全部逃逸（返回调用方或存为字段），不满足 local region 逃逸检查；`MailTrace` 回调跨栈同样不可 local 化；无峰值内存数据，不作方案 |
| §11 现有代码的 BUG（存量） | 19 | 19 条全部为存量，已逐条给 `git blame` 依据；重点核对 `send` 的 6 条失败分支（MAIL 失败、部分拒收、全拒、非 354、DATA 失败、421）、`readLine` 的 5 种结束形态（CRLF / 裸 LF / EOF 带残留 / EOF 空 / 超长）与 `DotStuff` 的空正文/跨块边界 |
| §12 并发安全与锁粒度 | 3 | #6（无保护 + `closedFlag` 可见性）、#5（中止后状态未知）；共享路径已指明：`Email.smtpValue` 单实例（`EmailFacade.cj:215`）→ `SmtpClient` → `LineChannel` → socket。锁粒度：`closeMutex` 合格，无需拆分 |
| §14 功能完备性与 README 覆盖 | 3 | `MailTimeouts.idle` 无消费方（#8）、DSN 参数静默丢弃（#9）、空反路径不支持（#18）；本部分无 `.md`，README 的 SMTP 示例与实现一致（`requireEncryption` 默认值与 `.tls(...)` 组合可通），README 遗漏项由第 1-5 部分统一核对 |
| 文件覆盖（§13 等） | 16/16 | 本部分清单 16 个文件全部读完；`.md` 一致性结论见第 1-5 部分（本部分无 `.md`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 9 |
| 一般 | 53 |
| 轻微 | 42 |
| 其中存量 | 83 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只覆盖文档，因此结论是「文档作为对外契约是否可信」，而不是「MIME/地址解析实现是否正确」。总体看，三份文档的质量高于一般库文档：`README` 的用法示例经逐条比对确实能编译（`Email.builder()`、`SmtpClient.builder(...).auth(...)`、`ImapIdle(client).start()` + `nextEvent(timeout:)`、`SearchCriteria.unseen().andWith(...)`、`MimeParseOptions(strict: false)`、`MimeWriteOptions(allow8Bit: true)` 全部与源码签名一致），设计文档把「三条底线」「STARTTLS 四条规则」「MIME 限制」「恶意样本」写得很实，且末尾的附录 A 主动承认「正文 API 会漂移、以代码为准」——这在同类模块里少见。核对过的安全防线（`writeLine` 拒绝 CR/LF、`HeaderMap` 头注入拦截、`EmailAddress` 拒绝 `\r\n<>`、STARTTLS 不降级、`maxLiteralBytes`/`maxDepth`/`maxParts` 上限、`Spool` 随机文件名 + 0600、`Secret`/trace 的凭据脱敏）都是真实现了的，不是纸面承诺。

需要收口的是三类「文档与实现的缝」：①**容量口径**——落盘阈值被写成单级 256 KB，实际是 256 KB/1 MB 两级且 `maxParts` 会乘上去；`fetchMessage` 被描述成流式，实际整封物化。这两条直接影响使用者的内存规划，是本部分最值得先修的。②**资源生命周期**——文档承诺 `close()` 删除 + `deleteOnExit` 兜底，实际临时文件没有统一释放入口（`MailMessage`/`MimePart` 不是 `Resource`，`Email.close()` 也不碰正文），长期服务会积累明文附件残片。③**索引完整性**——包清单漏掉承载 24 个源文件的 `f_email.model`，「其他公开 API」清单缺 `allow8Bit`/`strict`/`rejected`/`MailSummary` 字段等，末行还停在半个签名上；这类问题机械可查，建议做成 CI 校验而不是每次手补。

另外两处属于「承诺了告警但没出口」：MIME 解析的宽容降级（缺失结束 boundary、非法参数）在结果里完全不可见；`MailTrace` 只脱敏不转义控制字符，与 §9 的「日志注入」防线不符。前者影响调用方判断附件是否被截断，后者只影响启用了 trace 的调试场景，都可排期。

本部分无阻塞项（0 严重）。MIME 编解码 / 地址解析 / 注入防线的代码级正确性、死代码与重复逻辑的机械检查，需以第 2–6 部分的 `.cj` 结论为准；本报告只保证「文档说的和代码做的是否一致」这一层。

**第 2 部分**：本部分（门面 + 汇总 + 能力位 + 13 份规格/验收文档）的代码密度低但职责重：`Email` 是这套邮件库对外唯一"能用起来"的门面，规格文档里大量承诺（TLS 注入退路、四种 AUTH、`MimeParseOptions` 限额）最终都要在这里兑现，因此问题集中在**门面层与协议层的契约落差**，而不是算法错误。

阻塞项只有一条：附件临时文件（`MimeParser:472` 的 `owned=true` `FileBodySource`）在门面层完全不可释放——收信轮询是这个库的主要用法，磁盘按封数线性增长是必然发生的，且残留的是 0600 的敏感附件。建议与 `MailMessage <: Resource` 一起改，一次把生命周期讲清楚。

排期项是四条"静默错位"：`delete` 的 UID→序号 TOCTOU 与 `UIDPLUS` 缺失、`list` 的 UID 回退、POP3 `quit` 失败后的死缓存、IMAP/POP3 登录失败漏关连接。前三条都会让"看起来成功/看起来失败"与服务器真实状态不一致，第四条在密码错误重试下会累积 fd。这些都不是老代码质量差，而是门面的"便利层"缺少对协议层前置条件（UIDPLUS、TOP、序号稳定性）的显式处理。

其余为可读性与契约声明问题（未使用 import、`ToString` 未实现、`hasPrefix` 排除相等、关闭异常静默、注释与实现不符）。`ImapCapabilities` 本身写得干净：能力位与 `ENABLE` 回显的区分、`SORT=DISPLAY` 蕴含 `SORT`、`AUTH=` 前缀提取都正确，只有 `hasPrefix` 的边界与 `toString` 的接口实现两处小问题。

另附两点不作为本部分缺陷的信息：`email.cj:28` 的 `F_EMAIL_VERSION = "0.1.0"` 与 `cjpm.toml` 的 `version = "1.3.2021"` 不同步（模块版本常量与制品版本各说一套，是否算问题取决于仓库对版本常量的约定）；`verification.md` 的 268 例统计未含后加的 `EmailFacade_test`（6 例）与 stream-buffer 用例（现 279 例），因文档带 2026-10-29 时间戳，按历史记录处理。

**第 3 部分**：这 12 个文件是整个 IMAP 客户端的骨架，工程化程度不低：tag 不回绕、literal 不变成 `String`、`ENABLE` 只认回显、`UNCHANGEDSINCE` 的 `MODIFIED` 与 `updated` 分离、IDLE 的「用户代码不在读线程执行」——这些都是踩过坑才会写出来的约束，注释也把「为什么」写清楚了。词法层（`ImapParser`）与响应层（`ImapResponse`）实现干净，递归都有深度上限，没有发现栈溢出面。

风险集中在三处：

1. **命令构造与响应消费的不对称**。写侧对「哪些位置可以放原样文本」没有统一约束（`flags` / `items` / 能力名直接拼），读侧只有 FETCH 一条路径会消费 literal，`collect()` 这条通用路径遇到 `{n}` 必然错位。两处一经真实服务器触发就是「命令失败」或「连接报废」，且错误信息指不到根因。
2. **扩展命令是被复制出来的**，不是从 `ImapClient` 的能力里长出来的。`copyUidOf` 抄 `parseCopyUid` 少一个判空、四处 `if (!isOk) throw` 绕开 `expectOk`、`SORT=DISPLAY` 的键名凭感觉写成两个词——这三条都是「复制时丢约束」的同一模式，而两条被测试写成了期望值，说明测试只验证了「我发了什么」，没验证「这个语法对不对」。建议这批扩展的公共动作（发命令、判结果、解析 `[CODE args]`）收进 `ImapClient` 的包内方法，扩展类只留语义差异。
3. **状态与并发的边界**。`valReset()` 的字段清单与「SELECT 之后哪些状态还有效」不对应（漏 3 个、多清 1 处），`ImapClient` 的可见性与自增语义没在 IDLE 双线程下重新审一遍，`done()` 与 `rebuild()` 的终止条件各写一套。这几条都不会在单线程顺序测试里暴露，但会让长连收信在运行数小时后出现「莫名 BAD」「未读数串味」。

阻塞项：`ImapMove` 的回退（会打错 `\Deleted`，数据破坏）与 IDLE 双 `DONE`（协议错位）建议先修。其余「一般」可以按「命令构造/响应消费统一」「扩展命令去重」「状态清单对齐」三组批量处理，改动都不大但需要补对应的协议级用例（ScriptedTransport 已经够用，只是要断言语法而非只断言子串）。轻微项与 4 条优化方案可与功能迭代同批做。

**第 4 部分**：本部分覆盖 `f_email` 的 MIME 核心（边界扫描、part 状态机、编解码、头部/参数模型）与 IMAP 的 modified UTF-7 / token 值类型。**编解码算法本身写得相当扎实**：base64 的空白/缺 padding/非法字符三态、QP 的跨块 carry、modified UTF-7 的宽容回退、RFC 2047 相邻 encoded-word 空白丢弃、RFC 2231 续行拼接，都有对应实现与用例，`Codec_test` / `ContentType_test` 的覆盖质量高于模块平均水平；`HeaderMap` 的注入防线（字段名可见 ASCII、值拒绝 CR/LF）也是正确的位置。

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

**第 5 部分**：本部分是 `f_email` 的"数据模型 + POP3 客户端"层：地址/日期/MIME part 的内存模型、QP 编解码、临时文件、POP3 状态机与 SMTP 认证编码。整体形态是**防御意识明确但落点不均匀**——CR/LF 注入在传输层（`LineChannel.writeLine`）、头层（`HeaderMap.validateValue`）、参数层（`needsExtended` 强制 RFC 2231）三道都堵住了，`Secret` 的凭据封装闭环也干净；但结构校验、递归边界、配置接线这三类"半道防线"留下了实质缺口：

- **阻塞项**：#1 `AddressList.parseInto` 的组语法自递归没有任何深度上限，一封 `To: a:a:a:…:x@y;` 的邮件就能把解析线程的栈打穿。这是本部分唯一会**崩溃进程**的问题，修法不复杂（迭代化或加 `LimitKind.Depth` 限深），建议优先排期。
- **契约面**：#2 `bodyLineLength` 对 QP 完全不生效（`Base64` 分支正常，两条分支行为不一致）；#3 宽松日期解析会因为一个 `ab:cd` 抛 `NoneValueException`/`ArithmeticException`，与"回退 1970 并告警"的承诺相反；#4 `MailDate(DateTime.now())` 会把墙上时间配上 `+0000`，静默产生 8 小时偏差；#5 `MailMessageBuilder.build()` 二次调用会改掉上一封邮件的 boundary，让收件方把整封正文当一个 part。这四条都是"看起来能跑、结果错"，比崩溃更难发现，且都缺一条回归用例（见「文件覆盖」第 2、3、6 行）。
- **资源与连接**：#8 是 POP3 侧最值得修的一条——协议解析失败后连接既不关闭也不标记失步，后续命令会把上一条回复的残留当作状态行解析，最坏情况静默返回错误邮件数；`MailIoException` 的注释已经写明"出错即不可信"，只是这条分支没落实。#6 的多行物化在正常邮箱规模下只是慢，在恶意/异常回复下是 OOM 面。
- **安全**：#7 的地址结构校验缺失不构成注入（传输层已挡 CR/LF），但会把畸形片段当合法地址送进 `MAIL FROM:`/`RCPT TO:`，错误表现离根因很远；#9 的 `chmod` 返回值忽略让"临时文件 0600"的承诺在部分文件系统上失效，附件正文可能以 `0644` 留在共享 `/tmp`。
- **可维护性**：#10 的五组复制（转义/反转义/注释剥离/线性查找/读流样板）目前语义一致、还没漂移，#2 正是"两处同形实现漂移出不同行为"的实例，抽取时应顺手把 `lineLength` 的缺口一起补上；#14 的 `toString` 比较枚举（4 处）与 #15 的 3 个未使用 `import` 属低成本清理；#12 / #13 / #17 是"注释与实现不符、协议边界按首字节判、README 漏成员"这类文档/契约债，合并时注意与其它子轮去重。
- **性能与内存**：本部分没有任何改前/改后数据，2 条优化方案与 4 条假设都不进修复清单。下一轮最值得补的是假设 1（QP 解码 1 字节/次）与假设 2（地址解析 O(n²)），它们决定要不要动解码器状态机与 `splitTopLevel`。
- **已确认没有的问题**：`Secret` 的凭据保护、`HeaderMap`/`LineChannel` 的注入防线、`MimeParameter` 的 RFC 2231 续行解析与 `%XX` 边界、`MailDate` 的时区表与两位年份换算、`Pop3Client` 的 `beginSensitive`/`endSensitive` 对称与 `DELE` 只在 `QUIT` 后提交的语义、`SmtpAuth` 四个机制的编码、`QuotedPrintable` 的软换行与尾部空格编码状态机。

**存量 17 条（严重 1 / 一般 8 / 轻微 8），是否纳入修复待用户决定。**

**第 6 部分**：传输层（`LineChannel` / `DotStuff` / `MailConnection`）的工程质量明显高于协议会话层：CRLF 注入防线放在唯一写入口且「先校验后写」、dot-stuffing 与 un-stuffing 是跨块安全的显式状态机、`readExact` 会先消费行缓冲残留、STARTTLS 升级后旧通道立刻 `invalidate`，这些都有对应的细粒度用例（含单字节慢流、128 KB 跨界 literal）。脱敏、超时折算（单次超时 vs 命令总超时）也是按规范做的，不是「看起来能跑」。

真正的阻塞项集中在 `SmtpClient` 的事务收尾：**DATA 阶段的失败没有回写收件人状态**（#1），552/554 这类常规拒收被报告成 `isCompleteSuccess() == true`——静默丢信，而默认配置（不发 `SIZE=`）恰好把这条路变成常态；**空收件人信封**（#2）则在公开 API 上抛越界异常并留下半开事务。这两条建议本轮修复，各补一组用例（DATA 失败三码、空 recipients）。次一级是 `AUTH LOGIN`/`CRAM-MD5` 早成功分支不 `return`（#3，表现为建连挂 60 s）与 `sendReset` 吞异常（#5，会话状态不可知），修法都是几行。

可维护性上，本部分有 7 处不可达/死代码（其中 `selectMechanism` 意味着「自动选机制」能力实际不存在）、`writeData` 两支逐字相同（正是 #1 的现场）、枚举经字符串比较 7 处（改名即静默失效），以及两组重复实现（数字解析、逐字节拷贝）。这些不阻塞上线，但会持续拖慢 #1 的修复与后续缓冲优化。

安全面除 #7（APOP 摘要进 trace）外，注入防线是完整的：`writeLine` 拒绝 CR/LF 且一个字节都不写，地址进 SMTP 命令前经 `EmailAddress.validateAddress` 拒绝 `<`/`>`（`MailAddress.cj:92-99`），`AUTH` 期间整行进 `sensitive` 模式。需要补的是「凭据类命令全家桶」的脱敏清单。

性能方面没有可用的 profile / bench 数据，四个候选（`fill` 分配、`readExact` 读块、每次读写 setsockopt、`prepare` 双序列化）全部只放在「待验证假设」，不进修复清单。

建议排期：#1、#2 立刻修并补用例；#3、#5、#7 同批；#8（`idle` 旋钮）、#9（DSN warning）、#18（空反路径规格）需先定契约；#10-#19 随重构一起做。本部分存量 19 条，是否纳入修复待用户决定。
