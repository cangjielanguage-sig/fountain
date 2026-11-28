# f_email 模块审查报告

> **模块第 6/6 部分**（分报告）。本部分只覆盖 SMTP 客户端与传输层 16 个文件（`src/smtp/*`、`src/transport/*`）；
> 同模块其余文件见 `parts/f_email.part1..5.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（本部分 16 个源文件：16 个 `.cj` + 0 个 `.md`；全模块 72 个 `.cj` + 16 个 `.md`）
- **基线**：工作区快照（`git status` 干净，无 diff）；本部分代码全部来自 `164ed4e540`（2026-10-28）与 `d9809c4196` / `7ef50c5206`（2026-10-29），按「存量」计
- **审查重点**：SMTP/MIME 侧编解码与回复解析正确性、CRLF 注入与凭据脱敏、连接与资源、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LineChannel.fill` + 逐字节 `add` 是 IMAP 批量 FETCH 的主要分配/CPU 来源之一 | `f_email/src/transport/LineChannel.cj:403-434` | `fill` 自耗时占比、每轮分配量 | `cjprof record` 跑 100 封 × 1 MB 的 `fetch`，取 `fill` / `readLine` 的 self time 与 `getAllocatedHeapSize()` 差值 |
| 2 | `readExact` 的 64 KB 块分配在长连接上是可测量的稳态分配 | `f_email/src/transport/LineChannel.cj:215` | 每秒 `readExact` 次数 × 64 KB | 在 `readExact` 入口加计数器，跑 10 分钟稳态 FETCH，算每秒分配字节数 |
| 3 | 每读写设置 socket 超时（`setReadTimeout`/`setWriteTimeout`，`tlsSocket` + `tcp` 各一次）在短命令往返中占比可观 | `f_email/src/transport/LineChannel.cj:370-401`、`MailConnection.cj:165-192` | 单次 setsockopt 开销、每命令调用次数 | `strace -c` 统计 `setsockopt` 次数与耗时，对照 `NOOP` 往返 P50/P99 |
| 4 | `prepare` 的双序列化在 1 MB 以上邮件上占总发送耗时 20% 以上 | `f_email/src/smtp/SmtpClient.cj:414-418` | 序列化耗时占比（内存 sink） | 分段计时：`prepare` 内 `MimeWriter.write(counter)` 与 `writeData` 各计一次，同输入 1 KB / 1 MB / 10 MB |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_email.part6.txt` 一一对应（本部分 16 行，全部为 `.cj`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/src/smtp/SmtpCapabilities.cj` | .cj | ✅ | `size` 解析无溢出保护、与 `SmtpReply.parseInt` 重复（#13）；其余 prop 为对外 API |
| 2 | `f_email/src/smtp/SmtpClient.cj` | .cj | ✅ | DATA 失败当成功（#1）、空收件人越界（#2）、`sendReset` 吞异常（#5）、并发无保护（#6）、DSN 静默（#9）、死变量/恒真条件（#10）、分支重复（#11）、枚举字符串比较（#12）、`Message-ID`（#15）、`noop/reset`（#16）、空反路径（#18） |
| 3 | `f_email/src/smtp/SmtpClientBuilder.cj` | .cj | ✅ | AUTH 早成功不返回（#3）、`selectMechanism` 死代码（#10）、枚举字符串比较（#12） |
| 4 | `f_email/src/smtp/SmtpReply.cj` | .cj | ✅ | 多行回复无上限（#4）、「第一行」注释与实现不符（#17）、`toArray` 调两次 |
| 5 | `f_email/src/smtp/Smtp_test.cj` | .cj | ✅ | `caught` 死存储（#19）；缺 552/554 用例（#1 的缺失证据） |
| 6 | `f_email/src/transport/DotStuff.cj` | .cj | ✅ | 写侧状态机行为正确（空正文/跨块/CRLF 归一并有用例）；`ensure` 扩容分支不可达（#10）、逐字节拷贝（#14） |
| 7 | `f_email/src/transport/DotStuff_test.cj` | .cj | ✅ | 8 个用例覆盖行首点、空正文、跨块、单字节块、双点行；未发现重复或弱断言 |
| 8 | `f_email/src/transport/LineChannel.cj` | .cj | ✅ | 不可达 `return`（#10）、64 KB 注释不符（#17）、逐字节拷贝（#14）、读块分配（优化 #2/#3）；CRLF 注入防线实现正确（`:305-320`） |
| 9 | `f_email/src/transport/LineChannelLargeRead_test.cj` | .cj | ✅ | 128 KB literal × 4 种分块，逐字节断言一致；`BufferSink` 为测试桩 |
| 10 | `f_email/src/transport/LineChannel_test.cj` | .cj | ✅ | 覆盖 CRLF/裸 LF、注入拒绝、超长行、literal 残留、软超时、脱敏；`RecordingIoTimeout.lastWrite` 未断言（测试桩，不报） |
| 11 | `f_email/src/transport/MailConnection.cj` | .cj | ✅ | `isClosed` 可见性（#6）；`closeUnderlying` 重复关闭有 try/catch 保护；TLS 升级会 `invalidate` 旧通道，正确 |
| 12 | `f_email/src/transport/MailConnection_test.cj` | .cj | ✅ | 真 socket 用例使用固定端口 24655-24658（端口占用时用例失败，属测试环境风险，不报）；覆盖跨线程 close 与命令总超时 |
| 13 | `f_email/src/transport/MailTrace.cj` | .cj | ✅ | `APOP` 未脱敏（#7）；`AUTH` 保留机制名、`PASS`/`LOGIN` 丢弃参数，与注释一致 |
| 14 | `f_email/src/transport/TlsMode.cj` | .cj | ✅ | `idle` 无消费方（#8）、`Deadline.expired` 死方法（#10）；`remaining` 语义正确（每次读写前折算） |
| 15 | `f_email/src/transport/TransportFactory.cj` | .cj | ✅ | `eofAtEnd` 死字段（#10）；`ScriptedTransport` 为公开测试替身（README 已列），`ScriptedInput.setWriteTimeout` 空实现属接口要求 |
| 16 | `f_email/src/transport/TransportTestSupport_test.cj` | .cj | ✅ | `FixedInput` / `CollectOutput` / `RecordingTrace` 均被其他测试引用，无死代码 |

合计：`.cj` 16 个 / `.md` 0 个 / 共 16 个，全部读完（`.md` 与其余 56 个 `.cj` 见第 1-5 部分）。

## 覆盖自检

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
| 严重 | 2 |
| 一般 | 7 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

传输层（`LineChannel` / `DotStuff` / `MailConnection`）的工程质量明显高于协议会话层：CRLF 注入防线放在唯一写入口且「先校验后写」、dot-stuffing 与 un-stuffing 是跨块安全的显式状态机、`readExact` 会先消费行缓冲残留、STARTTLS 升级后旧通道立刻 `invalidate`，这些都有对应的细粒度用例（含单字节慢流、128 KB 跨界 literal）。脱敏、超时折算（单次超时 vs 命令总超时）也是按规范做的，不是「看起来能跑」。

真正的阻塞项集中在 `SmtpClient` 的事务收尾：**DATA 阶段的失败没有回写收件人状态**（#1），552/554 这类常规拒收被报告成 `isCompleteSuccess() == true`——静默丢信，而默认配置（不发 `SIZE=`）恰好把这条路变成常态；**空收件人信封**（#2）则在公开 API 上抛越界异常并留下半开事务。这两条建议本轮修复，各补一组用例（DATA 失败三码、空 recipients）。次一级是 `AUTH LOGIN`/`CRAM-MD5` 早成功分支不 `return`（#3，表现为建连挂 60 s）与 `sendReset` 吞异常（#5，会话状态不可知），修法都是几行。

可维护性上，本部分有 7 处不可达/死代码（其中 `selectMechanism` 意味着「自动选机制」能力实际不存在）、`writeData` 两支逐字相同（正是 #1 的现场）、枚举经字符串比较 7 处（改名即静默失效），以及两组重复实现（数字解析、逐字节拷贝）。这些不阻塞上线，但会持续拖慢 #1 的修复与后续缓冲优化。

安全面除 #7（APOP 摘要进 trace）外，注入防线是完整的：`writeLine` 拒绝 CR/LF 且一个字节都不写，地址进 SMTP 命令前经 `EmailAddress.validateAddress` 拒绝 `<`/`>`（`MailAddress.cj:92-99`），`AUTH` 期间整行进 `sensitive` 模式。需要补的是「凭据类命令全家桶」的脱敏清单。

性能方面没有可用的 profile / bench 数据，四个候选（`fill` 分配、`readExact` 读块、每次读写 setsockopt、`prepare` 双序列化）全部只放在「待验证假设」，不进修复清单。

建议排期：#1、#2 立刻修并补用例；#3、#5、#7 同批；#8（`idle` 旋钮）、#9（DSN warning）、#18（空反路径规格）需先定契约；#10-#19 随重构一起做。本部分存量 19 条，是否纳入修复待用户决定。
