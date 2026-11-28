# f_email 模块审查报告

> **模块第 5/6 部分**（本报告只覆盖 `files/f_email.part5.txt` 列出的 20 个文件，全部为 `.cj`：`model/MailAddress` → `smtp/SmtpAuth`；本部分无 `.md`。模块其余 52 个 `.cj` + 16 个 `.md`（含 `README.md` / `README_en.md` / `doc/**`）由第 1–4、6 部分产出；本部分编号独立，合并时以主 Agent 为准。README 仅作为 `§14` 的取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（本部分 20 个 `.cj`，0 个 `.md`；模块共 72 `.cj` + 16 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 仅有两处未跟踪的 review 目录，源码无 diff ⇒ 全部问题记「存量」）
- **审查重点**：MIME 编解码与地址解析正确性、注入与安全、资源与连接、OOM、死代码、重复逻辑、存量 BUG（本部分实际落点：`AddressList` 组语法递归、QP 编码器行宽、`MailDate` 时间/时区、`MailMessageBuilder` 对象别名、POP3 回复与多行物化、`Spool` 临时文件权限）
- **报告版本**：v1（第 5/6 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | QP 解码的"每次 1 字节 + 每字节新建容器"占整封邮件解析耗时的显著比例（正文为 QP 时） | `f_email/src/model/QuotedPrintable.cj:218-234` | `QuotedPrintableDecoder.read` 的自耗时占比、`ArrayList` 分配次数 | `cjprof record` 解析 100 封 500 KB quoted-printable 正文的邮件（`-O2`），看 `read`/`decodeSome` 占比与 GC 次数；同时用 `getAllocatedHeapSize()` 对照 |
| 2 | `AddressList.parse` 在 64 KiB `To:` 头上的 O(n²) 拼接是解析主路径热点 | `f_email/src/model/MailAddress.cj:364-409` | 6 档输入长度（1/4/16/64 KiB）的耗时曲线是否平方 | 写 `cjpm bench` 用例对 `AddressList.parse` 扫长度，取中位数；再对真实收件箱样本（1000 封）`cjprof` 看 `String.+` 占比 |
| 3 | `list()` / `uidl()` 在大邮箱上的峰值内存是现场 OOM 的来源之一 | `f_email/src/pop3/Pop3Client.cj:293-331`、`Pop3Reply.cj:130-146` | 20 万封邮箱 `LIST` 的 `getUsedHeapSize()` 峰值与回复字节数之比 | 用本地脚本 POP3 服务端生成 20 万行 `LIST`，解析前后采样 `getUsedHeapSize()`/RSS，记录比值；再验证加上限后的回落 |
| 4 | `Spool.createFile` 的 16 次重试在 `ENOSPC`/`EACCES` 下会把失败延迟放大到毫秒级并掩盖根因 | `f_email/src/model/Spool.cj:47-64` | 单次失败耗时、重试 16 次的总耗时、各 errno 分布 | 在只读目录 / 满盘 tmpfs 上各跑 100 次 `createFile`，记录耗时分布与最终异常文案 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/src/model/MailAddress.cj` | .cj | ✅ | 见 #1（组语法递归无上限）、#7（地址结构校验缺失）；`stripComments` 与 `MailDate.cj:332-366` 逐行同义（并入 #10）；`decodeDisplayName` 的引号反转义与 `MimeParameter.unquote` 重复（并入 #10）；未命中项：`lastIndexOfTopLevel` 的引号/转义状态机正确，`parseMailbox` 的 `lt/gt` 边界（`110-122`）在缺 `>` 时显式抛错 |
| 2 | `f_email/src/model/MailDate.cj` | .cj | ✅ | 见 #3（时间字段 `getOrThrow` + 十进制溢出）、#4（`offsetMinutes` 默认 0）；`now()`（`46-60`）的偏移反推算法正确，`parseZone` 的时区表与 `±HHMM` 解析（`286-329`）有上界校验，`twoDigitYear` 分界（`113-119`）与 RFC 5322 一致；`stripComments` 重复见 #10 |
| 3 | `f_email/src/model/MailDate_test.cj` | .cj | ✅ | 12 条用例覆盖两位年份、缺时区告警、月份大小写、注释剥离、宽松/严格模式、round-trip、`toUtc`；**未覆盖** #3 的 `ab:cd` 与超长数字、#4 的公共构造器路径（`MailDate(DateTime)` 零用例），是上述两条缺陷未被发现的原因 |
| 4 | `f_email/src/model/MailException.cj` | .cj | ✅ | 6 个异常子类 + 2 个枚举（`IoStage`/`LimitKind`）全部为对外契约；`toString` 分支穷尽；`MailProtocolException.capability` 的注释举例含 `MOVE`/`CONDSTORE`（IMAP 侧复用同类型，`src/imap/` 在用），不是错误；`MailAuthException.code` 在 POP3 侧恒为 `None`（`Pop3Client.cj:599`），注释说"只保留机制名与状态码"，属轻微文案漂移，不单列（信息项）|
| 5 | `f_email/src/model/MailMessage.cj` | .cj | ✅ | 见 #5（`build()` 共享 `HeaderMap`）；`findBody`（`124-159`）对 `multipart` 先扫直接匹配叶子再递归（`141-154`），两层循环有一遍重复遍历（子节点被 `typeMatches` 与 `isAttachment` 各判两次），量级为 2× 常数、不单独计缺陷，建议随 #10 的抽取一起收敛；`attachments()` 的根守卫无效见 #11 |
| 6 | `f_email/src/model/Message_test.cj` | .cj | ✅ | 四个 `@Test` 类（`Address_test`/`MailMessage_test`/`Envelope_test`/`BodySource_test`）共 19 条用例，覆盖组语法、引号显示名、注释转显示名、encoded-word、domain-literal、废弃路由、注入拒绝、boundary 唯一性；**未覆盖** #5 的二次 `build()`、#7 的无 `@` 地址、#11 的根即附件 |
| 7 | `f_email/src/model/MimeParameter.cj` | .cj | ✅ | RFC 2231 三段优先级（`name*` > 续行 > `name`）实现正确（`175-197`），续行循环按 `index += 1` 必然终止（`199-245`）；`percentDecode` 的 `i + 2 < bytes.size` 边界正确（`327`，末三位 `%XX` 仍可解）；`unquote` / `escapeQuoted` 与 `MailAddress` 的同名逻辑重复（并入 #10）；`splitSegments` 的 O(n²) 拼接见优化方案 2 |
| 8 | `f_email/src/model/MimePart.cj` | .cj | ✅ | `contentType`/`disposition`/`charsetUsed` 三个惰性缓存字段在 getter 内写入、无同步（见 #16）；`isAttachment`（`176-189`）的 `disposition` 优先级与注释一致；`collectAttachments`（`192-200`）递归深度受解析期 `maxDepth = 32`（`MimeOptions.cj:46`）约束，不构成无界递归；`readAll` 见优化方案 3 |
| 9 | `f_email/src/model/QuotedPrintable.cj` | .cj | ✅ | 见 #2（`lineLength` 死配置）、优化方案 1（解码 1 字节/次）；`pendingSpaces`（`88`、`113-116`）在"超长空格行"下会缓存整行（每字节 1 个 `Byte`），量级与输入同阶、不构成独立 OOM 面，随优化方案 3 的流式改造一并收敛；`finish()`（`123-134`）正确补尾部 `=20`/`=09`；`CollectingOutput`/`ArrayInput` 两个内部类均有使用（后者被 `BodySource.cj:49` 复用） |
| 10 | `f_email/src/model/Secret.cj` | .cj | ✅ | 仅 4 个成员（`of`/`use`/`toString` + 私有构造），`use<T>` 泛型回调透传返回值、`toString` 恒 `<redacted>`；注释明确"Cangjie `String` 无零化接口"的限制，属诚实契约；无缺陷 |
| 11 | `f_email/src/model/Secret_test.cj` | .cj | ✅ | 2 条用例（回调内取值、`toString` / 插值都是 `<redacted>`）；未覆盖嵌套 `use`，但无逻辑风险 |
| 12 | `f_email/src/model/Spool.cj` | .cj | ✅ | 见 #9（`chmod` 返回值忽略、异常被吞）；目录回退链（`67-94`）与注释 4 步一致，`@When` 两个平台分支穷尽（`108-130`），`isWindows` 的两份平台实现无重复符号冲突；`createFile` 无配套删除 API（唯一调用方 `MimeParser.cj:493` 自己 `removeIfExists`），属对外契约未声明，不单列 |
| 13 | `f_email/src/model/Spool_test.cj` | .cj | ✅ | 2 条用例依赖 `stat -c %a` 与硬编码 `/tmp/f_email_spool_test`，只能在 Linux/WSL 跑（模块测试基线即 WSL，见 `fountain-baseline.md §1`），可移植性问题不计缺陷；用例只断言 `600`，未覆盖 `chmod` 失败分支（#9） |
| 14 | `f_email/src/model/TransferEncoding.cj` | .cj | ✅ | 见 #12（注释承诺"无法识别按 7bit 处理并告警"，实现无告警通道）；`TransferDecoder.stream`（`56-67`）对 `7bit`/`8bit`/`binary` 直通，被 `MimeParser.cj:182/298` 使用 |
| 15 | `f_email/src/pop3/Pop3Capabilities.cj` | .cj | ✅ | `supports`/`args`/`get`（`66-94`）三段同构线性查找（并入 #10 的重复逻辑）；`-ERR` 回空表的约定（`31-37`）与 `Pop3ClientBuilder.readCapabilities`（`747-756`）一致；`authMechanisms`/`implementation`/`expire` 的取值逻辑无越界 |
| 16 | `f_email/src/pop3/Pop3Client.cj` | .cj | ✅ | 见 #6（多行物化 + 二次搬运）、#8（解析失败后不失步）、#3（`parseUnsigned` 溢出）；`login`/`apop`/`authenticate` 的 `beginSensitive`/`endSensitive` 对称（`165-174`、`197-203`、`213-221`），`PASS`/`APOP` 凭据不会进 trace（`LineChannel.cj:480` 只对 `C` 方向做屏蔽）；`AUTH` 续行判定见 #13；`quit` 吞掉原始异常（`434-442`）属轻微、不单列（信息项） |
| 17 | `f_email/src/pop3/Pop3Reply.cj` | .cj | ✅ | 见 #6（`readAll` 无上限）；`parse`（`99-109`）的 `+OK`/`-ERR` 前缀长度校验正确，`extractErrorCode`（`111-120`）无越界；`splitLines`（`153-172`）正确处理裸 LF 与 `\r\n` |
| 18 | `f_email/src/pop3/Pop3_test.cj` | .cj | ✅ | 25 条用例覆盖 `+OK/-ERR` 分类、`CAPA -ERR` 回空表、`APOP` RFC 示例摘要、`AUTH PLAIN/LOGIN`、`STAT/LIST/UIDL`、`RETR` dot-unstuffing 与 10 KB 长行、`TOP` 能力缺失、`DELE` 仅 `QUIT` 后提交、`STLS` 缺失拒绝、明文认证需显式放行、`chunkSize = 1` 的慢流；**未覆盖** #6 的无上限、#8 的失步后重试、#13 的 `+OK` 误判续行 |
| 19 | `f_email/src/smtp/SendReport.cj` | .cj | ✅ | 见 #14（`toString` 比较枚举）、#15（未使用 `import` ×3）；`isRetryable(error)` 对 `MailTlsException` 一律返回 true，与 `MailException.cj:203` 注释"证书问题除外、但归类为网络层可重试"一致，不判缺陷；`isRetryable(report)`（`96-109`）对 `aborted` 与 4xx/5xx 混合的分类正确，`isCompleteSuccess`（`85-87`）语义与注释一致 |
| 20 | `f_email/src/smtp/SmtpAuth.cj` | .cj | ✅ | 四个机制的编码实现与 RFC 一致（`CRAM-MD5` 用 `HMAC(password, MD5)` + `hex` + `base64(user + " " + digest)`，`72-79`）；`NUL`/`SOH` 常量（`46-47`）用法正确；`user` 含空格会破坏 `CRAM-MD5` 的 `user digest` 分隔与 `XOAUTH2` 的 `user=` 字段，但上游 `SmtpClient` 是否允许此类用户名属其他部分，本部分只记为待确认、不计缺陷 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

（`轻微` 的 8 条为 #10 重复逻辑、#11 无效守卫 + 根即附件丢失、#12 `TransferEncoding.parse` 注释承诺告警、#13 `AUTH` 续行判定、#14 枚举 `toString` 比较、#15 未使用 `import`、#16 惰性缓存无同步、#17 README 成员遗漏；「待验证假设」4 条不计入统计。）

## 总评

本部分是 `f_email` 的"数据模型 + POP3 客户端"层：地址/日期/MIME part 的内存模型、QP 编解码、临时文件、POP3 状态机与 SMTP 认证编码。整体形态是**防御意识明确但落点不均匀**——CR/LF 注入在传输层（`LineChannel.writeLine`）、头层（`HeaderMap.validateValue`）、参数层（`needsExtended` 强制 RFC 2231）三道都堵住了，`Secret` 的凭据封装闭环也干净；但结构校验、递归边界、配置接线这三类"半道防线"留下了实质缺口：

- **阻塞项**：#1 `AddressList.parseInto` 的组语法自递归没有任何深度上限，一封 `To: a:a:a:…:x@y;` 的邮件就能把解析线程的栈打穿。这是本部分唯一会**崩溃进程**的问题，修法不复杂（迭代化或加 `LimitKind.Depth` 限深），建议优先排期。
- **契约面**：#2 `bodyLineLength` 对 QP 完全不生效（`Base64` 分支正常，两条分支行为不一致）；#3 宽松日期解析会因为一个 `ab:cd` 抛 `NoneValueException`/`ArithmeticException`，与"回退 1970 并告警"的承诺相反；#4 `MailDate(DateTime.now())` 会把墙上时间配上 `+0000`，静默产生 8 小时偏差；#5 `MailMessageBuilder.build()` 二次调用会改掉上一封邮件的 boundary，让收件方把整封正文当一个 part。这四条都是"看起来能跑、结果错"，比崩溃更难发现，且都缺一条回归用例（见「文件覆盖」第 2、3、6 行）。
- **资源与连接**：#8 是 POP3 侧最值得修的一条——协议解析失败后连接既不关闭也不标记失步，后续命令会把上一条回复的残留当作状态行解析，最坏情况静默返回错误邮件数；`MailIoException` 的注释已经写明"出错即不可信"，只是这条分支没落实。#6 的多行物化在正常邮箱规模下只是慢，在恶意/异常回复下是 OOM 面。
- **安全**：#7 的地址结构校验缺失不构成注入（传输层已挡 CR/LF），但会把畸形片段当合法地址送进 `MAIL FROM:`/`RCPT TO:`，错误表现离根因很远；#9 的 `chmod` 返回值忽略让"临时文件 0600"的承诺在部分文件系统上失效，附件正文可能以 `0644` 留在共享 `/tmp`。
- **可维护性**：#10 的五组复制（转义/反转义/注释剥离/线性查找/读流样板）目前语义一致、还没漂移，#2 正是"两处同形实现漂移出不同行为"的实例，抽取时应顺手把 `lineLength` 的缺口一起补上；#14 的 `toString` 比较枚举（4 处）与 #15 的 3 个未使用 `import` 属低成本清理；#12 / #13 / #17 是"注释与实现不符、协议边界按首字节判、README 漏成员"这类文档/契约债，合并时注意与其它子轮去重。
- **性能与内存**：本部分没有任何改前/改后数据，2 条优化方案与 4 条假设都不进修复清单。下一轮最值得补的是假设 1（QP 解码 1 字节/次）与假设 2（地址解析 O(n²)），它们决定要不要动解码器状态机与 `splitTopLevel`。
- **已确认没有的问题**：`Secret` 的凭据保护、`HeaderMap`/`LineChannel` 的注入防线、`MimeParameter` 的 RFC 2231 续行解析与 `%XX` 边界、`MailDate` 的时区表与两位年份换算、`Pop3Client` 的 `beginSensitive`/`endSensitive` 对称与 `DELE` 只在 `QUIT` 后提交的语义、`SmtpAuth` 四个机制的编码、`QuotedPrintable` 的软换行与尾部空格编码状态机。

**存量 17 条（严重 1 / 一般 8 / 轻微 8），是否纳入修复待用户决定。**
