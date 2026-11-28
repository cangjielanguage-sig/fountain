# f_email 模块审查报告（模块第 2/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_email`（模块第 2/6 部分：4 个 `.cj` + 13 个 `.md`，共 17 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本部分全部记「存量」）
- **审查重点**：门面 `Email` 的正确性与资源生命周期、`ImapCapabilities` 能力位语义、MIME/地址相关契约在门面层的落地、注入与安全、OOM/资源泄漏、死代码、重复逻辑、存量 BUG；本部分文件以 `doc/spec/**` 与门面源码为主，故同时核对「规格 ↔ 实现」的漂移
- **报告版本**：v1（本文件为 `f_email` 拆分子轮的分报告，最终模块报告由主 Agent 合并；本部分只统计本部分 17 个文件）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MailAttachment.read()` 的逐字节 `add` 在 MB 级附件上是主要开销 | `f_email/src/EmailFacade.cj:144-154` | 该函数自耗时占 `read()` 的比例 | `cjprof record` 跑 `read()` 10 MB × 100 次；对照块拷贝版本（`cjpm bench -O2`，中位数 + 离散度） |
| 2 | `Email.list(limit: 0)` 在万封信箱上既有内存峰值也有超时风险 | `f_email/src/EmailFacade.cj:316-344` | 1 万封时的耗时分布与摘要数组峰值 | 本地假 POP3 服务器造 1 万封，测 `list(limit: 0)` 的 P50/P95 与 `getAllocatedHeapSize()` 增量 |
| 3 | 大文本正文的 4–5 份副本是收信路径的峰值内存主因 | `f_email/src/model/MimePart.cj:133-147`、`f_email/src/EmailFacade.cj:183-185` | 解析→取正文的峰值 RSS 拆分 | `parse`、`text()`、`size()`、`read()` 四段分别记 RSS/heapUsed，样本 1 MB、8 MB |
| 4 | `Email.text()+attachments()` 的两次 `fetch` 在 IMAP 上是可感知延迟 | `f_email/src/EmailFacade.cj:367-384` | 两次 `BODY.PEEK[]` 各自的往返耗时 | `ScriptedTransport` 记录命令数 + 真实服务器分段计时（同一封 2 MB 邮件） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_email/doc/spec/add-f-email-client/design.md` | .md | ✅ | 归档变更设计；§12「明确不做」与实现一致；`:14`（filename 不可信）、`:343`（关闭异常映射）、`:400`（注入 TlsClientConfig 退路）三处承诺在门面层未落地，见 #8、#16、#9 |
| 2 | `f_email/doc/spec/add-f-email-client/proposal.md` | .md | ✅ | 范围与排除项与实现一致，未发现漂移 |
| 3 | `f_email/doc/spec/add-f-email-client/specs/email-imap/spec.md` | .md | ✅ | 深度 64 / 行 8 KB、literal 64 MB、`ENABLE` 回显语义与实现一致（`ImapParser.MAX_DEPTH=64`、`MAX_LINE=8192`）；`:190`「build 只建连不登录」是 #4 泄漏的前提 |
| 4 | `f_email/doc/spec/add-f-email-client/specs/email-message/spec.md` | .md | ✅ | 默认限额（256 KB / 64 KB / 1000 / 32）与 `MimeOptions.cj:44-50` 一致；`BodySource` 一次性语义与 `BodySource.cj` 一致 |
| 5 | `f_email/doc/spec/add-f-email-client/specs/email-mime/spec.md` | .md | ✅ | 限额与临时文件规则（`:213-228`）与 `Spool`/`LeafBuffer` 一致；`filename` 不参与路径已落实，但公开字段未净化，见 #8 |
| 6 | `f_email/doc/spec/add-f-email-client/specs/email-pop3/spec.md` | .md | ✅ | `TOP` 缺失必须抛错（`:71-72`）是 #17 的依据；`QUIT` 提交语义与 `Pop3Client.quit` 一致 |
| 7 | `f_email/doc/spec/add-f-email-client/specs/email-smtp/spec.md` | .md | ✅ | 四种 AUTH 与自动选择（`:62-64`）、TLS 注入与门面缺口，见 #9 |
| 8 | `f_email/doc/spec/add-f-email-client/specs/email-transport/spec.md` | .md | ✅ | TLS 默认校验、`writeLine` 注入防线、跨线程 `close()` 与实现一致 |
| 9 | `f_email/doc/spec/add-f-email-client/tasks.md` | .md | ✅ | 全量 `[x]`；10.18 勾选但同时写「Dovecot 与仅 M3 服务器的扩展错误矩阵留后续」，属已知取舍，未单列问题 |
| 10 | `f_email/doc/spec/add-f-email-client/verification.md` | .md | ✅ | G5 行与文末 WARNING 冲突，见 #21；测试分布 268 未含后加的 `EmailFacade_test`(6) 与 stream-buffer 用例（现 279），因文档带 2026-10-29 时间戳，按历史记录不判问题 |
| 11 | `f_email/doc/spec/reuse-f-email-stream-buffers/design.md` | .md | ✅ | 单缓冲复用方案与 `MimeWriter`/`LineChannel` 现状一致；D4 的基准口径写明"只记录，不作门禁" |
| 12 | `f_email/doc/spec/reuse-f-email-stream-buffers/proposal.md` | .md | ✅ | `:12`「I/O 形参阻断、不做 local 化」是 §9 判不可行的依据 |
| 13 | `f_email/doc/spec/reuse-f-email-stream-buffers/tasks.md` | .md | ✅ | 与 proposal/design 自洽 |
| 14 | `f_email/src/EmailFacade.cj` | .cj | ✅ | 本部分主要问题集中地：#1–#13 与 #16–#21 多数在此 |
| 15 | `f_email/src/EmailFacade_test.cj` | .cj | ✅ | 6 个用例覆盖 build 校验/SMTP 委托/IMAP 列表/正文附件/删除/POP3；缺"POP3 `QUIT` 失败"、"UID 缺失回退"、"Text 附件字节"三类回归 |
| 16 | `f_email/src/email.cj` | .cj | ✅ | 6 个 `public import` 与 `F_EMAIL_VERSION`；版本常量 `0.1.0` 与 `cjpm.toml` 的 `1.3.2021` 不一致（见总评，非本部分判据内的缺陷） |
| 17 | `f_email/src/imap/ImapCapabilities.cj` | .cj | ✅ | 能力位与 `ImapEnable`/`ImapCondStore`/`ImapSort` 的用法一致；`toString`/`hasPrefix` 两个语义问题见 #14、#15 |

合计：`.cj` 4 个 / `.md` 13 个 / 共 17 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 11 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分（门面 + 汇总 + 能力位 + 13 份规格/验收文档）的代码密度低但职责重：`Email` 是这套邮件库对外唯一"能用起来"的门面，规格文档里大量承诺（TLS 注入退路、四种 AUTH、`MimeParseOptions` 限额）最终都要在这里兑现，因此问题集中在**门面层与协议层的契约落差**，而不是算法错误。

阻塞项只有一条：附件临时文件（`MimeParser:472` 的 `owned=true` `FileBodySource`）在门面层完全不可释放——收信轮询是这个库的主要用法，磁盘按封数线性增长是必然发生的，且残留的是 0600 的敏感附件。建议与 `MailMessage <: Resource` 一起改，一次把生命周期讲清楚。

排期项是四条"静默错位"：`delete` 的 UID→序号 TOCTOU 与 `UIDPLUS` 缺失、`list` 的 UID 回退、POP3 `quit` 失败后的死缓存、IMAP/POP3 登录失败漏关连接。前三条都会让"看起来成功/看起来失败"与服务器真实状态不一致，第四条在密码错误重试下会累积 fd。这些都不是老代码质量差，而是门面的"便利层"缺少对协议层前置条件（UIDPLUS、TOP、序号稳定性）的显式处理。

其余为可读性与契约声明问题（未使用 import、`ToString` 未实现、`hasPrefix` 排除相等、关闭异常静默、注释与实现不符）。`ImapCapabilities` 本身写得干净：能力位与 `ENABLE` 回显的区分、`SORT=DISPLAY` 蕴含 `SORT`、`AUTH=` 前缀提取都正确，只有 `hasPrefix` 的边界与 `toString` 的接口实现两处小问题。

另附两点不作为本部分缺陷的信息：`email.cj:28` 的 `F_EMAIL_VERSION = "0.1.0"` 与 `cjpm.toml` 的 `version = "1.3.2021"` 不同步（模块版本常量与制品版本各说一套，是否算问题取决于仓库对版本常量的约定）；`verification.md` 的 268 例统计未含后加的 `EmailFacade_test`（6 例）与 stream-buffer 用例（现 279 例），因文档带 2026-10-29 时间戳，按历史记录处理。
