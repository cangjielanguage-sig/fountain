# f_email 模块审查报告

> **模块第 3/6 部分**：只覆盖 `files/f_email.part3.txt` 列出的 12 个文件——`f_email/src/imap/` 下的 `ImapClient.cj`、`ImapCondStore.cj`、`ImapEnable.cj`、`ImapExt_test.cj`、`ImapFetch.cj`、`ImapIdle.cj`、`ImapMove.cj`、`ImapNamespace.cj`、`ImapParser.cj`、`ImapResponse.cj`、`ImapSearch.cj`、`ImapSort.cj`（全部为 `.cj`，共 5472 行）。本部分不含 `.md`，README / `doc/**` 的一致性由第 1 部分产出；`ImapSpecialUse.cj`、`ImapUtf7.cj`、`Imap_test.cj`、`transport/**`、`mime/**`、`model/**` 不在本部分清单内，仅作为取证上下文引用，不重复计入覆盖表与统计。

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（本部分 12 个源文件，均为 `.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）
- **审查重点**：MIME 编解码与地址解析正确性、注入与安全、资源与连接、OOM、死代码、重复逻辑、存量 BUG（本部分落在 IMAP 协议层：响应解析、literal 处理、扩展命令、IDLE 并发）
- **报告版本**：v1（第 3/6 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `valFetchStreamInto` 的 token 化 + `ImapParser.parse` 每次响应都新建多个 `ArrayList<Byte>`/`String`，是 `UID FETCH 1:*` 批量同步的主要 CPU 项 | `ImapClient.cj:604-708`、`ImapParser.cj:39-59` | 自耗时占比、调用次数 | `cjprof record` 跑「5000 封 × 2 KB 的 `UID FETCH (UID FLAGS RFC822.SIZE)`」，看 `ImapParser.parse` / `parseAtom` self time |
| 2 | 非流式 literal 的「逐字节 `add` + `toArray`」在 20 MB 正文上占取正文时间的一半以上 | `ImapClient.cj:663-665` | 单封 20 MB 的分段耗时 | 分段计时（`readExact` / 累加 / `toArray` / `MimeParser.parse`）各跑 20 次取中位数 |
| 3 | `append` 的计数遍与写遍各占 `APPEND` 端到端 20%± | `ImapClient.cj:984-1016` | 两遍耗时与网络耗时 | `cjpm bench -O2`，10 MB 报文，100 次，记录两遍耗时 |
| 4 | IDLE 的 `pollInterval` 默认 5 s 让每条连接每 5 s 唤醒一次，连接数上千时是不可忽略的空转 | `ImapIdle.cj:423`、`:212` | 唤醒次数与 CPU 占比、连接数 | 1000 条 IDLE 连接空转 10 分钟，采进程 CPU 时间与 `epoll`/select 次数 |
| 5 | `enqueue` 满队列丢最旧事件会让长时间不同步的消费者错过 `EXPUNGE`，最终状态与服务器漂移 | `ImapIdle.cj:356-376` | 丢弃计数与漂移样本 | 加计数器（丢弃条数）+ 消费者停 10 分钟后比对 `SELECT` 的 `EXISTS` |
| 6 | `ImapResponse.isTagged()` 等字符串比较在每命令 N 条响应上有可测开销 | `ImapResponse.cj:74-84` | 占比 | 与改成 `match` 的版本做 A/B，`cjpm bench -O2`，10 万条响应 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/src/imap/ImapClient.cj` | .cj | ✅ | 1835 行全读；核心命令驱动、FETCH/literal、APPEND、tag 生成、builder |
| 2 | `f_email/src/imap/ImapCondStore.cj` | .cj | ✅ | QRESYNC 参数拼接问题见「发现」第 8 条 |
| 3 | `f_email/src/imap/ImapEnable.cj` | .cj | ✅ | 能力回显语义与文档一致；参数未校验见「轻微」条目 |
| 4 | `f_email/src/imap/ImapExt_test.cj` | .cj | ✅ | 721 行全读；两处把缺陷写成期望（`:298`、`:440`），见对应发现 |
| 5 | `f_email/src/imap/ImapFetch.cj` | .cj | ✅ | 值类型与解析器；`SequenceSet` 空串抛异常是 `copyUidOf` 缺陷的触发点 |
| 6 | `f_email/src/imap/ImapIdle.cj` | .cj | ✅ | 并发路径重点；双 `DONE`、join 超时、无同步字段见「发现」 |
| 7 | `f_email/src/imap/ImapMove.cj` | .cj | ✅ | UID/序号混用见「严重」第 1 条；`copyUidOf` 重复见「一般」 |
| 8 | `f_email/src/imap/ImapNamespace.cj` | .cj | ✅ | `joinPath` 越界见「一般」 |
| 9 | `f_email/src/imap/ImapParser.cj` | .cj | ✅ | 词法层；literal 只给长度（与 `collect` 不消费 literal 的缺陷同源） |
| 10 | `f_email/src/imap/ImapResponse.cj` | .cj | ✅ | 三类响应解析；`toString` 比较枚举见「轻微」 |
| 11 | `f_email/src/imap/ImapSearch.cj` | .cj | ✅ | 三种组合形状与日期校验未发现问题；`needsUtf8` 判定正确 |
| 12 | `f_email/src/imap/ImapSort.cj` | .cj | ✅ | `DISPLAY FROM` 见「一般」；`THREAD` 递归有 `MAX_DEPTH` 保护 |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 12 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

> 「待验证假设」6 条不计入统计。存量缺陷 20 条（严重 2 + 一般 12 + 轻微 6），是否纳入修复待用户决定。

## 总评

这 12 个文件是整个 IMAP 客户端的骨架，工程化程度不低：tag 不回绕、literal 不变成 `String`、`ENABLE` 只认回显、`UNCHANGEDSINCE` 的 `MODIFIED` 与 `updated` 分离、IDLE 的「用户代码不在读线程执行」——这些都是踩过坑才会写出来的约束，注释也把「为什么」写清楚了。词法层（`ImapParser`）与响应层（`ImapResponse`）实现干净，递归都有深度上限，没有发现栈溢出面。

风险集中在三处：

1. **命令构造与响应消费的不对称**。写侧对「哪些位置可以放原样文本」没有统一约束（`flags` / `items` / 能力名直接拼），读侧只有 FETCH 一条路径会消费 literal，`collect()` 这条通用路径遇到 `{n}` 必然错位。两处一经真实服务器触发就是「命令失败」或「连接报废」，且错误信息指不到根因。
2. **扩展命令是被复制出来的**，不是从 `ImapClient` 的能力里长出来的。`copyUidOf` 抄 `parseCopyUid` 少一个判空、四处 `if (!isOk) throw` 绕开 `expectOk`、`SORT=DISPLAY` 的键名凭感觉写成两个词——这三条都是「复制时丢约束」的同一模式，而两条被测试写成了期望值，说明测试只验证了「我发了什么」，没验证「这个语法对不对」。建议这批扩展的公共动作（发命令、判结果、解析 `[CODE args]`）收进 `ImapClient` 的包内方法，扩展类只留语义差异。
3. **状态与并发的边界**。`valReset()` 的字段清单与「SELECT 之后哪些状态还有效」不对应（漏 3 个、多清 1 处），`ImapClient` 的可见性与自增语义没在 IDLE 双线程下重新审一遍，`done()` 与 `rebuild()` 的终止条件各写一套。这几条都不会在单线程顺序测试里暴露，但会让长连收信在运行数小时后出现「莫名 BAD」「未读数串味」。

阻塞项：`ImapMove` 的回退（会打错 `\Deleted`，数据破坏）与 IDLE 双 `DONE`（协议错位）建议先修。其余「一般」可以按「命令构造/响应消费统一」「扩展命令去重」「状态清单对齐」三组批量处理，改动都不大但需要补对应的协议级用例（ScriptedTransport 已经够用，只是要断言语法而非只断言子串）。轻微项与 4 条优化方案可与功能迭代同批做。
