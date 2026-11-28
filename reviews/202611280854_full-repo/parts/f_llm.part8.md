# f_llm 模块审查报告 —— 第 8/25 部分

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个 `.cj` + 0 个 `.md`）
- **本部分范围**：`src/channel/**`（`ChannelFunctions_test`、`ChannelMediator`、`ChannelMediator_test`、`EmailChannel`、`EmailChannel_test`）、`src/config/**`（`LLMConfig`、`LLMConfig_test`）、`src/constant/**`（13 个常量文件，含 `ModelNames` / `ModelNames_test`）
- **基线**：工作区快照（HEAD `f309f0b55`；`git diff 120fd2542 HEAD -- f_llm` 为空、`git status -- f_llm` 为空）⇒ 本部分全部问题来源为**存量**
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全
- **报告版本**：v1（本部分第 2 稿 —— 第 1 稿已完成，本稿在其结论上补充 6 条新发现、按严重度重排编号；与模块抽样版 `f_llm.md` 无继承关系）
- **与其他部分的分工**：`ChannelBootstrap/ChannelContract/ChannelFunctions` 由第 7 部分覆盖；`AttachmentSink` 单锁串行、`checkAttachment` 缺 `isRegular`/符号链接校验已分别由第 4、3 部分登记，本部分只做交叉引用、不重复计数

## 发现

### [严重][存量] 接收落盘目录 `downloadDir` 不过沙箱：模型可控参数可向任意可写目录新建文件

- **位置**：`f_llm/src/channel/EmailChannel.cj:258-278`（`receive` 把 `downloadDir` 原样交给 `AttachmentSink.save`）、`:148-155`（`save` 只校验「非空 + 存在」）
- **来源**：存量（`git blame -L 148,177` 指向 2026-11-06 `6d706eb81f`）
- **判据**：review-checklist §10（安全性：外部输入未校验）+ §11（同一约束在两个方向上不对称）
- **证据**：静态确定 —— ①发送方向有白名单（`EmailChannel.send:204-217` → `checkAttachment:220-246`，越界即整封失败）；②接收方向只有 `dir.isEmpty()` / `!exists(dir)` 两个判断；③`downloadDir` 来自工具入参 `ChannelInboxParam.downloadDir`（`ChannelFunctions.cj:64`，由模型调用时直接填，`ChannelFunctions.cj:126` 无二次校验）；④项目自身把模型可见的文件操作钉在沙箱里：`f_llm/src/tool/AbstractFileFunction.cj:31`、`CommandFunction.cj:55`。
- **描述**：`channelInbox` 的 `downloadDir` 是模型可控参数。提示注入可让模型取 `downloadDir=/home/u/.ssh`，再用攻击者邮件里的附件名投放 `authorized_keys`（`freeName` 会避开已存在文件，因此**新建**而非覆盖，但新建已足够）；同理可向 `~/.config`、`/etc/cron.d` 等可写目录写入内容。第 1 稿定为「一般」，本稿按「安全漏洞」口径上调为**严重**：绕开了本仓对模型可见文件操作的统一沙箱约定。README:558 只承诺「发送按路径给出且必须在允许根目录内」，接收方向未写限制。
- **建议**：接收侧复用同一套根目录语义（`channelSendRoots()` 或独立的 `llm_channelReceiveRoots`），`canonicalize(downloadDir)` 必须落在允许根之内，否则单条附件返回 `error` 而不写入；同时把该约束写进 README 通道配置表。

### [严重][存量] 收信路径全量物化且无上限：附件整块进内存 + `limit` 无上界

- **位置**：`f_llm/src/channel/EmailChannel.cj:260`（`for (mail in transport.receive(limit))`）、`:269`（`AttachmentSink.save(downloadDir, item.filename, item.read())`）、`:360`（`ReceivedAttachment(..., {=> item.read()})`）、`:351-356`（`email().list(limit: limit)` + 每封 `email().body(summary)`）
- **来源**：存量（同上，`6d706eb81f`）
- **判据**：review-checklist §5（一次性物化 / 无界容器 / 无拒绝路径）
- **证据**：静态确定 —— ①`EmailChannel.receive` 把 `limit` 原样下传，自身无上限；②`f_email/src/EmailFacade.cj:252-258` 的 `Email.list` 规定 **`limit <= 0` 表示全部**，而公共入口 `ChannelMediator.receive`（`ChannelMediator.cj:203-205`）直接转发，`0`/负数不会被拒；③每个附件的字节由 `ReceivedAttachment.read: () -> Array<Byte>`（`EmailChannel.cj:29`）整体返回，落盘前必须先拿完整数组；④`f_email/src/EmailFacade.cj:141-155` 的 `MailAttachment.read()` 用 `ArrayList<Byte>` 逐字节 `add` 再 `toArray()`（≈2× 附件字节 + 扩容余量）。
- **描述**：三层叠加成无界内存面：邮件数（`limit` 无上限、`<=0` 语义反转）× 每封正文（`body()` 整封 fetch）× 每个附件（2× 字节）。峰值 ≈ Σ(正文 + 2×附件字节)。`InboundAttachment.size` 已带回字节数，代码里没有任何一处用它做拒绝；工具侧 `ChannelFunctions.cj:119-121` 只保证「`<=0` 时取 10」，正数一律放行。第 1 稿把「单附件物化」写成优化方案，本稿按「无界增长导致 OOM」口径升级为**严重**，因为 `limit` 与 `downloadDir` 都来自模型输入，不是内部常量。
- **建议**：`Channel.receive` 对 `limit` 做 `[1, 上限]` 夹取并显式拒绝 `<=0`（不要落到 f_email 的「全部」语义）；附件通道改为流式（`open(): InputStream` 或 `saveTo(path: Path)`，复用 `EmailFacade.cj:158-180` 的 64 KiB 缓冲）；超过配置上限（如 `llm_channelAttachmentMaxBytes`）直接记 `error`、不落盘。

### [一般][存量] 只有 HTML 正文的邮件，正文被静默丢成空串

- **位置**：`f_llm/src/channel/EmailChannel.cj:357`（`let text = body.text ?? ''`），所在函数 `FEmailTransport.receive:351-374`
- **来源**：存量（`git blame` 指向 `6d706eb81f`，2026-11-06）
- **判据**：review-checklist §11（数据丢失）+ §3（`case None` 兜底把内容吃掉）
- **证据**：静态确定 —— `f_email` 的 `MailBody` 同时给出 `text: ?String` 与 `html: ?String`（`f_email/src/EmailFacade.cj:189-193`），`f_email/src/model/MailMessage.cj:97` 说明 `text()` 只取 `text/plain`；`html` 在 `f_llm/src/channel/` 里零引用（只命中发送侧 `EmailChannel.cj:329-332`），收发不对称。
- **描述**：大量真实邮件是 `text/html` 单段（营销、通知、企业系统邮件），`message.text()` 返回 `None` → `InboundMessage.text` 为空串 → `ChannelFunctions.render` 把 `"text":""` 交给模型（`ChannelFunctions.cj:142`）。调用方无法区分「正文为空」与「邮件没有纯文本段」，模型只能看到标题、发件人和附件。
- **建议**：`let text = body.text ?? body.html ?? ''`；若要保留语义差别，可在 `InboundMessage` 加 `textKind`（`plain`/`html`）。补一条「只有 html 段」的 `FEmailTransport.receive` 用例。

### [一般][存量] `InboundMessage.receivedAt` 恒为空串：可用的收信时间没接线

- **位置**：`f_llm/src/channel/EmailChannel.cj:363`（`receivedAt: ''` 硬编码）
- **来源**：存量（`git blame` 指向 `6d706eb81f`）
- **判据**：review-checklist §14.1（接线缺失）+ §11（契约与实现不符）
- **证据**：静态确定 —— ①`MailSummary` 带 `date: ?MailDate` 与 `receivedAt: ?MailDate`（`f_email/src/EmailFacade.cj:59-60`），IMAP 分支已填 `receivedAt: imapDate(item.internalDate)`（`EmailFacade.cj:309`）；②`f_llm` 侧只有 `EmailChannel.cj:363` 一处构造 `ReceivedMail`，写死空串；③该字段会被渲染进工具结果（`ChannelFunctions.cj:142`），README:934 也把它列为公开字段。
- **描述**：唯一已实现的通道产出的每封信 `receivedAt` 都是 `""`，模型无法按时间排序或判断新旧。POP3 分支 `receivedAt` 为 `None` 但 `date` 有值，可直接回落。`EmailChannel_test.cj:113` 用假数据填了该字段，测试因此看不出生产路径恒空。
- **建议**：`receivedAt: (summary.receivedAt ?? summary.date)?.toString() ?? ''`；补一条「摘要带日期 → 输出非空」的用例。

### [一般][存量] 发送侧 `html` 非空即丢弃 `text`，未走 multipart/alternative

- **位置**：`f_llm/src/channel/EmailChannel.cj:329-333`
- **来源**：存量（`git blame -L 329,333` 指向 2026-11-06）
- **判据**：review-checklist §11（能力被丢弃）+ §14.1（只做了一半的分支）
- **证据**：静态确定 —— 代码是 `if (html.isEmpty()) builder.text(...) else builder.html(...)`，永远只调一个；`f_email/src/model/MailMessage.cj:176` 明确「`text` + `html` 同时存在时自动生成 `multipart/alternative`」，`Message_test.cj:99-115` 即该用例。`OutboundMessage`（`ChannelContract.cj:60-74`）同时提供两字段且无「二选一」说明。
- **描述**：调用方同时给纯文本与 HTML 时纯文本被静默丢弃：邮件只带单 part，纯文本客户端/网关看到空正文且无法降级。这是上层把已有能力收窄，不是 f_email 的限制。
- **建议**：两个字段都非空时都调（`builder.text(...)` + `builder.html(...)`），交给 `MailMessage` 生成 `multipart/alternative`；两者皆空时返回明确的 `SendReceipt.failure`。

### [一般][存量] `ModelNames.normalize` 默认分支不做小写化：小写匹配、原样返回，能力判断会漂

- **位置**：`f_llm/src/constant/ModelNames.cj:33-47`（`match(trimmed.toAsciiLower())` 各 `case` 返回常量，`case _ => trimmed`）
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）+ §10（正确性：同一函数两套归一规则）
- **证据**：静态确定 —— 匹配用 `toAsciiLower()`，未命中却返回**未小写**的 `trimmed`。唯一调用点 `f_llm/src/llm/ModelCapabilities.cj:42-52` 用它做等值比较（`model == MODEL_NAME_DEEPSEEK_FLASH` 等）。因此 `'DeepSeek/DeepSeek-Flash'`（带平台前缀）能归一到常量，而裸名 `'DeepSeek-Flash'` / `'GLM-5'` 被原样返回、比较失败。`ModelNames_test.cj:25-45` 只覆盖带前缀的大小写混写（`:28`），未覆盖裸名大写。
- **描述**：`conf.actualLlmName` 由配置/DB 提供，大小写不受框架约束。写成 `DeepSeek-Reasoner` 时 `ModelCapabilities.resolve` 落到默认 `Toggle`，`ThinkingPolicy` 不移除 `temperature`，上游可能 400 或静默忽略参数；`isFlash('DeepSeek-Flash')` 同样返回 `false`。注释已写明「归一**只用于能力判断/日志分类**」，补齐小写化不影响实际发出的模型名。
- **建议**：`case _ => trimmed.toAsciiLower()`，注释注明「返回值恒为小写，报文请用 `conf.actualLlmName`」；补 `normalize('DeepSeek-Flash')` / `normalize('GLM-5')` 用例。

### [一般][存量] `FEmailTransport` 惰性建连无任何同步：共享实例上的 `Email` 会被并发读写

- **位置**：`f_llm/src/channel/EmailChannel.cj:293-316`（`private var client: ?Email` + `email()` 的「读-建-写」）、`:376-384`（`close()` 置 `None`）
- **来源**：存量（`git blame` 指向 `6d706eb81f`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 惰性初始化竞态 / 跨线程资源）
- **证据**：静态确定 —— 共享路径：`ChannelMediator.instances`（`ChannelMediator.cj:37`，`static let`）→ `channel():152-197` 把**同一个** `Channel` 引用交给任意调用者 → `EmailChannel.send/receive` 直接调 `transport`。`FEmailTransport.client` 的赋值（`:314`）与读取（`:301-303`）都在无锁区，该文件与 `EmailChannel` 内既无 `Mutex` 也无 `synchronized`。`Email` 自身是「懒连接 + 会话状态」：`f_email/src/EmailFacade.cj:214-221` 持有 `smtpValue/imapValue/pop3Value/currentMailbox/selectedMailbox`，类注释未声明线程安全、全文件无 `Mutex`。
- **描述**：两条后果：(1) **首次并发建连竞态** —— 两线程同时看到 `None` 各建一个 `Email`，后写者覆盖前者，先建那个的 socket 再无引用可达，`close()` 只关最后一个 → 连接泄漏 + 重复认证；(2) **共享会话并发使用** —— 即便初始化完成，多线程同时 `send`/`receive` 打在同一个 `Email` 上，IMAP 命令-响应序列与「当前 mailbox」状态互相穿插，可能协议错位、取到别人的正文或直接抛 `ChannelException`。是否真并发取决于 agent 任务调度，**这一点需实测**，故本稿定为「一般」而非严重；但「代码层面无任何同步手段」是静态事实。
- **建议**：给 `email()` 加锁（双重检查 + 锁内二次判空），并把「同一 transport 上的 send/receive」串行化；更好的做法是 `Channel` 无状态、每次操作从连接池取独占连接（`f_email` 已支持 `MailSummary` 定位，复用连接不是硬需求）。

### [一般][存量] 全局锁内调用 `Channel.close()`：锁里做网络 I/O

- **位置**：`f_llm/src/channel/ChannelMediator.cj:98-114`（`register` 在 `synchronized(mutex)` 内 `previous.close()`）、`:208-219`（`closeAll` 在同一把锁内逐个 `close()`）
- **来源**：存量
- **判据**：review-checklist §6.2 / §12.2（锁内 I/O、锁内调用外部实现）
- **证据**：静态确定 —— `mutex` 是类级 `static let`（`:35`），`register` 临界区含 `instances.get` → `previous.close()` → `instances[key] = channel`；`closeAll` 遍历全部实例逐个 `close()` 再 `clear()`。`EmailChannel.close():286-288` → `FEmailTransport.close():376-384` → `f_email` 的 `Email.close()`（`EmailFacade.cj:421-447`，逐协议 `close()`，必发 QUIT/LOGOUT 并等响应）。
- **描述**：重装配（`ChannelBootstrap.install` 可重复调用，`ChannelBootstrap.cj:74` 逐条 `register`）或收尾（`closeAll`）时，全局锁在「等远端 QUIT 响应」的整段时间被持有：期间 `channel()`/`send`/`receive`/`platforms()` 全部阻塞；若 `close()` 因半死连接挂住（f_email 关闭路径无独立超时），所有工具调用一起卡住。未来接入的平台若在 `close()` 里回调中介者，`Mutex` 不可重入 → 自死锁。附带风险：`channel()` 返回共享引用，`register` 换新时关闭旧实例，正在使用旧实例的线程会遇到「已关闭的连接」（是否可触发取决于是否运行期重装配，见待验证假设 #3）。
- **建议**：锁内只做「取出旧实例 + 替换」，出锁后再 `close()`；`closeAll` 先在锁内 `swap` 出快照并 `clear`，再锁外逐个关。

### [一般][存量] `checkAttachment` 在根目录不可解析时 `continue` 吞掉原因，误报为「附件越界」

- **位置**：`f_llm/src/channel/EmailChannel.cj:230-245`（重点 `:232-236`），根目录来源 `f_llm/src/config/LLMConfig.cj:227-244`
- **来源**：存量
- **判据**：review-checklist §11（错误处理静默）+ §10（可诊断性）
- **证据**：静态确定 —— ①`canonicalize(Path(root))` 抛异常时 `catch { continue }`，该 root 被静默跳过，最终统一落到 `:245` 的 `attachment outside allowed roots`；②`channelSendRoots()` 的回落分支（`LLMConfig.cj:239-242`）只 `trimAscii` 取 `llm_fileSandboxPath` 原串，不像 `getFileSandboxPath()`（`:219-221`）那样先建目录，所以「只配了 sandbox 路径且目录尚未创建」是可达状态。
- **描述**：根目录写错、无权限、尚未创建时，用户看到的是「附件的路径不在白名单内」而不是「白名单根目录不可解析」，排查方向被带偏；同一个配置项在两处行为也不一致（一处建目录、一处不建）。
- **建议**：`canonicalize` 失败时把原因并入错误消息（区分「root 不可用」与「附件越界」），并保留最后一个失败原因；`channelSendRoots()` 回落分支复用 `getFileSandboxPath()` 的结果。

### [一般][存量] `LLMConfig.getPath` 在 getter 里建目录且不捕获异常；路径是文件时仍当目录返回

- **位置**：`f_llm/src/config/LLMConfig.cj:205-218`（`getPath`），调用方 `:219-221`、`:251-253`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失、语义与命名不符）+ §10（设计合理性）
- **证据**：静态确定 —— `if (!exists(path)) { Directory.create(path, recursive: true) }` 无 `try`；`exists(path)` 为真时不再区分文件/目录，直接把该 `Path` 返回。调用点 `f_llm/src/tool/AbstractFileFunction.cj:31`、`f_llm/src/tool/CommandFunction.cj:55` 在每次文件工具调用时都会走到这里。
- **描述**：一个「读配置」的函数带创建目录的副作用：(1) `llm_fileSandboxPath` 指向无权创建的位置时，每次工具调用抛 `FileException`，错误与「文件操作」无关且无上下文；(2) 配置误指向已存在的**文件**时 `exists` 为真 → 返回文件路径当沙箱根，后续 `join(p)` 得到 `file/xxx`，失败点被推到写入阶段。
- **建议**：拆成 `sandboxPath(): Path`（纯读）与 `ensureSandboxPath(): (Path, String)`（建目录并返回错误原因）；`exists` 为真时补 `isDirectory` 判定。

### [轻微][存量] 死代码两处：`freeName` 的 `while(true)` 之后不可达；测试替身 `closed` 只写不读

- **位置**：①`f_llm/src/channel/EmailChannel.cj:134-142`（循环后的 `base`）；②`f_llm/src/channel/EmailChannel_test.cj:33`（`public var closed: Bool = false`）与 `:52-54`（唯一写入点）
- **来源**：存量
- **判据**：review-checklist §1（不可达语句 / 读了不用）
- **证据**：静态确定 —— ①`while (true)` 体内只有 `return candidate` 与 `index++`，无 `break`，循环后的 `base` 永不执行（是否为满足编译器类型检查而保留：待确认）；②全仓搜 `.closed` 只命中 `ChannelMediator_test.cj:192,193,224,225`（那是 `FakeChannel.closed`），`FakeEmailTransport.closed` 零读取点，也没有用例调用 `EmailChannel.close()`。
- **描述**：①典型「改成无限循环后忘删回退值」——读者会误以为存在「找不到空名就回退原名」的兜底，而该路径实际可能覆盖已有文件；②`close()` 的副作用无人断言，`EmailChannel.close → FEmailTransport.close`（含 `client = None` 重置）整条链路在测试里没被覆盖。
- **建议**：①删除 `:142` 的 `base`，或在循环里加探测上限并把它作为真实兜底；②补一条 `channel.close()` 后 `@Expect(transport.closed, true)` 的用例，否则删字段。

### [轻微][存量] `bareName` 按「字符数」截断，120 个多字节字符仍可能超过文件名上限

- **位置**：`f_llm/src/channel/EmailChannel.cj:99-110`（`MAX_NAME_CHARS = 120`，`for (rune in tail.runes())` 计 `count`）
- **来源**：存量
- **判据**：review-checklist §11（边界）+ §10（外部输入未校验）
- **证据**：静态确定 —— 截断单位是 rune，落盘用字节长度受限的底层 API：120 个 3 字节汉字 = 360 字节，超过常见文件系统 255 字节的单段名上限。
- **描述**：远端附件名长且为中文时 `File.create` 抛异常，`save` 返回 `('', 'write attachment failed: …')`。功能上是优雅失败，但用户只看到写盘失败，且原名已被截断，排查时对不上号。
- **建议**：按字节累加（`rune.toString().size`）并以 ~200 字节为界，保留扩展名。

### [轻微][存量] `AttachmentSink.save` 写失败后不清理已创建的文件

- **位置**：`f_llm/src/channel/EmailChannel.cj:160-176`（`File.create` 在锁内先建，`write` 在锁外，`catch` 只返回错误串）
- **来源**：存量
- **判据**：review-checklist §11（资源不对称 / 失败路径未清理）
- **证据**：静态确定 —— `catch` 分支只 `return ('', 'write attachment failed: …')`，没有 `delete`；`finally` 只 `close()`。
- **描述**：磁盘满或写入中途失败会留下 0 字节/半截文件；下次同名附件落盘时 `freeName` 看到它存在会顺延成 `-2`，垃圾逐步累积，用户也可能把半截文件当完整附件。
- **建议**：失败路径 `try { delete(Path(target)) } catch (_) {}`，或在 `finally` 里按成功标志决定是否删。

### [轻微][存量] `close()` 异常被静默吞掉且无日志：连接泄漏没有任何痕迹

- **位置**：`f_llm/src/channel/ChannelMediator.cj:106-110`、`:211-215`；同类 `f_llm/src/channel/EmailChannel.cj:366-372`（`receive` 部分结果后丢弃剩余失败）、`:171-175`（`save` 的 `finally`）
- **来源**：存量
- **判据**：review-checklist §3（`catch {}` 静默吞异常；此处无契约要求静默，降为轻微）+ §11
- **证据**：静态确定 —— 四处 `catch` 体都是 `()` / `{}`，无日志；`ChannelMediator` 内无 `LoggerFactory`（文件头只有 `std.collection/sort/sync`），`EmailChannel.cj:366-372` 在 `result` 非空时连 `e` 都不使用。
- **描述**：`close` 是对外连接的唯一释放点，关失败既不重试也不记录，`instances` 又被替换/清空，旧连接彻底失去引用，只能在 OS 层看到 CLOSE_WAIT 堆积。收信中途失败时调用方拿到「部分邮件」，无法区分「邮箱只有这些」与「第 N 封之后失败」。与本仓「日志走 `f_log`」的约定（`fountain-baseline.md` §6）不一致。
- **建议**：四处按 `f_log` 记 `warn`（带平台/账号/已完成条数）；`receive` 的部分失败在返回值里带出，至少不能静默。

### [轻微][存量] 重复逻辑：「平台是否已实现」的判定与「不支持」消息三处复制

- **位置**：`f_llm/src/channel/ChannelMediator.cj:91`（`create`）、`:172-181`（`channel` 有账号分支）、`:185-195`（`channel` 空账号分支）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 + 换控制流）
- **证据**：静态确定 —— `'channel platform not supported: ${…}'` 三处逐字相同；`:173-179` 与 `:187-193` 是同一段「取 `providers.contains(name)` → 不支持则抛 → 否则抛 not found」，只差上游条件与错误文案尾缀。
- **描述**：`channel()` 两段判定分别在「账号非空未命中」与「账号为空且零实例」路径上重复，`create()` 是同一语义的第三种写法；改一处漏一处会让不同入参给出不同的「不支持」文案。
- **建议**：抽 `private static func requireProvider(name: String, raw: String): Unit`（锁内取快照、锁外判定），`create` 与 `channel` 共用；两处 `not found` 保留各自文案并注释说明差异。

### [轻微][存量] `EmailChannel.isDirectory` 用 `canonicalize("<path>/.")` 复刻 std 能力

- **位置**：`f_llm/src/channel/EmailChannel.cj:248-256`
- **来源**：存量
- **判据**：review-checklist §2（标准库已有同语义实现）+ §10（标准库利用）
- **证据**：静态确定 —— `std.fs` 提供 `FileInfo.isDirectory(): Bool`（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:645-648`，另有 `isRegular`/`isSymbolicLink`）；本仓 `f_io/src/ExtendPath.cj:86-90` 已在用 `FileInfo.isRegular()` / `isSymbolicLink()`。
- **描述**：靠「拼 `/.` 再规范化」判目录，语义依赖 `canonicalize` 对「文件 + `/.`」抛异常这一未文档化细节，且每个附件多一次系统调用。第 3 部分已指出 `checkAttachment` 缺 `isRegular`/符号链接校验，改用 `FileInfo` 可一并解决。
- **建议**：`FileInfo(Path(actual)).isDirectory()`，异常/不存在按拒绝处理。

### [轻微][存量] 数值型配置项没有下界校验，0/负数把「保护」变成「立即失效」

- **位置**：`f_llm/src/config/LLMConfig.cj:177-183`（`getStreamIdleTimeout` / `getStreamMaxLineBytes`）、`:168-170`（`getCooldownDuration`）、`:164-166`（`getFailureThreshold`）、`:131-134`（`getEmbeddingRetries`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）+ §10（错误处理）
- **证据**：静态确定 —— 四个 getter 都是 `Config.getValue<Int64>(k) ?? <default>` 直接返回，无 `max(0)`、无上限。`Duration.second * (-1)` 得负 `Duration`（`std` 文档：`Duration` 范围 `[-2^63, 2^63)` 秒，只在越界时抛 `ArithmeticException`，不拒绝负数）；`Int64.Max` 秒的默认值已核对 `Duration.Max = (0x7FFF_FFFF_FFFF_FFFF, 999999999)`，**不会溢出**。
- **描述**：`llm_streamIdleTimeout=0`/负数会让流式读「每次判断都已超时」，与「防半死连接」的意图相反；`llm_cooldownSeconds` 为负会让熔断立即恢复；`llm_streamMaxLineBytes=0` 会让 SSE 首行即判超限。具体表现取决于使用点（`src/llm/**`，不在本部分），故只报边界缺失。
- **建议**：getter 内 `let v = … ?? default; if (v <= 0) { log.warn{…}; default } else { v }`，并给 `streamMaxLineBytes` 加上限（如 32 MiB）。

### [轻微][存量] Windows 下附件「是否在根目录内」的判定恒不成立

- **位置**：`f_llm/src/channel/EmailChannel.cj:237`（`actual == base || actual.startsWith('${base}/')`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：跨平台语义）+ §10
- **证据**：静态确定（有文档依据）—— `std.fs` 文档写明 Windows 路径分隔符为 `\`（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1186-1188`），而前缀比较硬编码 `/`。
- **描述**：`canonicalize` 在 Windows 返回 `D:\data\a.pdf` 形态，`base` 为 `D:\data`，`startsWith('D:\data/')` 为假 → 位于允许根内的附件全部被判 `outside allowed roots`，发信整体失效。是否需要支持 Windows 运行期部署待确认（`fountain-baseline.md` §1 只写了在 WSL 编译/测试；`f_llm/cjpm.toml` 有 `x86_64-w64-mingw32` target），故列轻微。
- **建议**：改用 `Path(actual).parent` 逐级比对，或统一分隔符后再比较；补「根目录末尾带分隔符」用例（`root='/data/att/'` 时 `'${base}/'` 会变双斜杠）。

### [轻微][存量] `register` 的文档注释与空账号实现相反

- **位置**：`f_llm/src/channel/ChannelMediator.cj:95`（注释「同 `(platform, account)` 重复登记按最新一次覆盖」）vs `:99-103`（空账号第二次登记直接 `throw`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 注释无「除空账号外」限定；`ChannelMediator_test.cj:198-211` 的用例名即 `testRegisterBlankAccountTwiceThrows`。
- **描述**：调用方照注释会以为「重复登记安全幂等」，实际空账号第二次抛异常，`ChannelBootstrap.install` 把它记成 `skipped` + error（`ChannelBootstrap.cj:76-79`），表现为「配置里两条同平台无账号条目只生效一条」。
- **建议**：注释改成「同键覆盖；账号留空时只允许一个实例，第二次登记抛 `ChannelException`」。

### [轻微][存量] `closeAll` 的「进程退出」路径未接线

- **位置**：`f_llm/src/channel/ChannelMediator.cj:207-219`（全仓仅 `ChannelMediator_test.cj:222` 调用）
- **来源**：存量
- **判据**：review-checklist §14.1（接线缺失）+ §11（注释承诺未兑现）
- **证据**：静态确定 —— `grep -rn "closeAll" --include=*.cj f_llm/src` 只命中定义与测试；`ChannelBootstrap` 只 `register`（`ChannelBootstrap.cj:74`），无关闭调用。注释写「进程退出 / 重装配用」。
- **描述**：注释承诺的关闭入口没有生产调用点，SMTP/IMAP 连接只能靠进程退出回收；`reset()` 被描述为「重装配用」但只 `instances.clear()`，每次重装配都遗留旧连接。
- **建议**：把 `closeAll` 接到模块卸载/优雅停机钩子（`fboot` 无钩子则在 `ChannelBootstrap` 提供 `shutdown()`）；`reset()` 注释改为「仅测试用」。

### [轻微][存量] 默认模型 `'chat-pro'` 复制两份；`_a2aEnabled` 键名内联未走常量

- **位置**：`f_llm/src/config/LLMConfig.cj:117-119` 与 `:156-158`（同为 `?? 'chat-pro'`）、`:66-68`（`LLM + '_a2aEnabled'`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 两处 getter 默认值相同但语义不同（裁剪 vs 摘要）；同文件其余键一律「`public static const` + getter」，只有 `_a2aEnabled` 在函数体里拼键名。
- **描述**：改默认模型要同时改两处，漏一处会出现两条路径用不同默认模型；`_a2aEnabled` 键名无法被外部引用/检索，与同文件约定不一致。
- **建议**：抽 `private static const DEFAULT_CHAT_LLM`（若两处允许独立演进则各留一个常量并注释）；`_a2aEnabled` 补 `public static let LLM_A2A_ENABLED`。

### [轻微][存量] 测试的全局状态不回收，且有两处断言可因错误原因通过

- **位置**：①`f_llm/src/channel/ChannelFunctions_test.cj:126`（`Config.set(llm_channelSendRoots, dir)` 后无 `Config.remove`）；②`f_llm/src/channel/ChannelMediator_test.cj:135-146`（注册 `demo` provider 后只 `reset()`，provider 表不清）；③`f_llm/src/channel/ChannelMediator.cj:228-234`（`resetAll` 注释称给「验证注册表本身」的用例用，全仓无调用者）；④`f_llm/src/channel/EmailChannel_test.cj:101-103`（`error.contains('ghost.pdf')`）；⑤`f_llm/src/channel/EmailChannel_test.cj:66-90`（`Config.set` 仅在末尾 `remove`，无 `finally`）
- **来源**：存量
- **判据**：review-checklist §1（无调用者）+ §11（测试隔离 / 断言质量）
- **证据**：静态确定 —— `ChannelMediator.instances`/`providers` 与 `Config` 都是进程级状态（`ChannelMediator.cj:36-37`），`reset()` 只清 `instances`（`:222-226`）；`grep "resetAll" f_llm/src` 只命中定义处。④未配置 roots 时错误串为 `attachment directory not configured (llm_channelSendRoots): ghost.pdf`（`EmailChannel.cj:208-209`），同样包含 `ghost.pdf`，所以该用例在「白名单未配置」路径上也会通过，没有真正覆盖 `checkAttachment` 的「文件不存在」分支。
- **描述**：测试类之间靠执行顺序互相污染：冒烟用例留下的 `llm_channelSendRoots` 让后续用例走「已配置」路径，`demo` provider 留在表里会让 `providerPlatforms()` 多一项、`create('demo')` 在别的用例里意外成功。`resetAll` 正为此准备却没人用，说明「知道问题但没接上」。`EmailChannel_test.cj:217-229` 已是 `try/finally` 写法，说明规范存在但未统一。
- **建议**：配置改动一律 `try { … } finally { Config.remove(...) }`；需要清 provider 的用例改用 `resetAll()`；④收紧为 `error.contains('attachment not found')`。

## 优化可行性方案

> 本部分没有可用的 bench / profile 数据，以下均为「还能更好」的结构性建议，收益未验证。

### [堆内存] 附件落盘改流式，去掉「整份 `Array<Byte>` + `toArray` 副本」的峰值

- **现状**：`ReceivedAttachment.read: () -> Array<Byte>`（`EmailChannel.cj:26-36`）把整份附件读成数组，`EmailChannel.receive:268-272` 再交给 `AttachmentSink.save(directory, filename, bytes)`（`:148`）。`f_email` 侧 `MailAttachment.read()` 是「64 KiB 缓冲逐块 `add` 进 `ArrayList<Byte>` 再 `toArray()`」（`f_email/src/EmailFacade.cj:141-155`），峰值 ≈ 2 × 附件字节 + 扩容余量。
- **方案**：把 `ReceivedAttachment` 的读取入口换成 `open(): InputStream` 或 `saveTo(path: Path)`，`AttachmentSink` 边读边写、单块 64 KiB，直接复用 `EmailFacade.cj:158-180` 的 `saveTo`。
- **预期**：单附件峰值从 ≈2n 降到 ≈64 KiB + 落盘缓冲；峰值只与「并发落盘的附件数」相关，不再随单个附件大小线性增长。
- **代价**：`AttachmentSink.save` 签名变更（`Array<Byte>` → 流/回调），测试里的假 `read` 闭包要改；写失败需删半截文件（见「轻微/失败不清理」）。
- **验证**：20 MiB / 100 MiB 附件各 1 次，`-O2`，记录 `getAllocatedHeapSize()` 峰值与 RSS 峰值，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 发送侧白名单每次重新解析 + 每个附件重新 `canonicalize` 全部根目录

- **现状**：`EmailChannel.send:205` 每次调用 `LLMConfig.channelSendRoots()`（`LLMConfig.cj:227-244`：读配置 + `split(',')` + `trimAscii` + 新建 `ArrayList`），随后对**每个附件**在 `checkAttachment:230-236` 里对**每个根目录**做一次 `canonicalize`（真实系统调用，含 `realpath` 解析）。
- **方案**：`channelSendRoots()` 结果按 `Channel` 生命周期缓存（`EmailChannel` 构造时解析一次，配置按 `fountain-baseline.md` §5「启动只读一次」本就不热更新）；`canonicalize(root)` 的结果与 roots 一起缓存。
- **预期**：把「附件数 × 根目录数」次 `realpath` 降到「根目录数」次；单封 5 附件、3 根目录时省 12 次系统调用（数量级推断，未计时）。
- **代价**：配置改后需重启（与现有语义一致）；缓存要在重装配时重建。
- **验证**：`cjpm bench -O2` 跑「单封 5 附件 × 1000 次 send」（FakeTransport 打桩，只测校验段），对比 p50/p99。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `freeName` 的线性探测：同名文件多时逐个 `exists`

- **现状**：`AttachmentSink.freeName:134-141` 从 `-2` 起逐个 `exists(Path(...))` 直到找到空位；同名附件长期累积时探测次数线性增长，且整段在 `sinkMutex` 内（`:160-164`）。
- **方案**：用「独占创建 + 失败换名」把探测与创建合并为一次系统调用，或先 `list` 一次目录建 `HashSet` 再选名。
- **预期**：k 次探测降为 1 次创建尝试；目录内已有 100 个同名文件时省 100 次 `stat`（量级推断，未计时）。
- **代价**：错误分类要区分「已存在」与「无权限/磁盘满」，避免把权限错误当成重名继续换名。
- **验证**：同一目录预置 10/100/1000 个 `a-N.txt`，对 `save` 分段计时，`-O2`，各 1000 次取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ChannelMediator.channel/platforms/accounts` 锁内对每个实例做 `normalize()`（`trimAscii + toAsciiLower`），账号多时锁内耗时上升 | `f_llm/src/channel/ChannelMediator.cj:118-145,157-167` | 实例数上限、锁内单次耗时、并发查询频率 | 造 10/100/1000 个实例，多线程并发 `channel()`，记录临界区 p99 与吞吐 |
| 2 | `FEmailTransport.receive` 每封信调一次 `email().body(summary)`，是否每次都触发完整 IMAP `FETCH` 往返，使 `channelInbox` 延迟随 `limit` 线性增长；元数据模式下是否白拉整封附件 | `f_llm/src/channel/EmailChannel.cj:351-374` | `body()` 的实现路径与单封往返耗时、字节量 | 对真 IMAP 邮箱取 1/10/50 封，分段计时（`list` / 逐封 `body` / 附件读），并记录服务端传输字节 |
| 3 | `ChannelMediator.register` 是否会在运行期被再次调用（重装配/配置刷新），从而与在途 `send`/`receive` 竞争 | `f_llm/src/channel/ChannelMediator.cj:96-115`、`ChannelBootstrap.cj:74,85-93` | `installFromConfig` 的完整调用链（本次只追到 `ChannelBootstrap`，未找到定时器/刷新入口） | 追调用方或观察重装配窗口内的 send 失败日志 |
| 4 | `AttachmentSink.freeName` 线性探测在「同名附件长期累积」目录里成为串行段（与第 4 部分登记的「单锁串行」同源） | `f_llm/src/channel/EmailChannel.cj:134-141,160-164` | 目录内同名文件数分布、`exists` 单次耗时 | 预置 1/100/1000 个同名文件，20 路并发 `save`，记录 p50/p99 与 CPU |
| 5 | `checkAttachment` 的「逐附件 × 逐根目录」`canonicalize` 在 send 主路径上的自耗时占比 | `f_llm/src/channel/EmailChannel.cj:220-246` | 该函数在 `send` 端到端里的占比 | `cjprof record` 跑 1000 次带 5 附件的 `send`（FakeTransport），看 `canonicalize` 自耗时 |
| 6 | `LLMConfig.getFileSandboxPath()` 每次文件工具调用都做 `exists`（可能建目录），属可省的启动期工作 | `f_llm/src/config/LLMConfig.cj:205-221` | 单次调用耗时与文件工具 QPS | `cjprof` 跑文件工具压测，或埋点统计 `exists` 调用次数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/channel/ChannelFunctions_test.cj` | .cj | ✅ | 6 个用例；`Config` 未回收，`resetAll` 未被使用 |
| 2 | `f_llm/src/channel/ChannelMediator.cj` | .cj | ✅ | 全局注册表；锁内 `close()`、重复判定、注释不符、吞异常、`closeAll` 未接线 |
| 3 | `f_llm/src/channel/ChannelMediator_test.cj` | .cj | ✅ | 11 个用例，覆盖覆盖/回落/多账号报错/closeAll；`demo` provider 未撤销 |
| 4 | `f_llm/src/channel/EmailChannel.cj` | .cj | ✅ | 问题集中处：downloadDir 沙箱、全量物化、html 正文、receivedAt、发送丢 text、并发、死代码、截断、残留文件、isDirectory、Windows 分隔符 |
| 5 | `f_llm/src/channel/EmailChannel_test.cj` | .cj | ✅ | 17 个用例；`closed` 只写不读、断言过弱、配置清理不对称 |
| 6 | `f_llm/src/config/LLMConfig.cj` | .cj | ✅ | 配置常量与 getter；`getPath` 副作用、数值无下界、`'chat-pro'` 重复、`_a2aEnabled` 内联键。`getLLMAccessTryingElapsed` 的 `Duration.second * Int64.Max` 已核 `Duration` 文档（`Duration.Max` 恰为 `Int64.Max` 秒）**不会溢出**，不报 |
| 7 | `f_llm/src/config/LLMConfig_test.cj` | .cj | ✅ | 5 个用例，supervisor/loom 依赖关系与实现一致 |
| 8 | `f_llm/src/constant/ConstantSize.cj` | .cj | ✅ | 2 个内容尺寸常量，对外可见，无问题（仓内零引用，按硬原则一不判） |
| 9 | `f_llm/src/constant/ContextPrunerName.cj` | .cj | ✅ | 类型别名 + 8 个策略常量；`DRC`/`Saturation` 各有使用 |
| 10 | `f_llm/src/constant/KnowledgeKind.cj` | .cj | ✅ | 10 个知识种类常量，对外可见；`SKILL_TOOL`/`COPYRIGHT` 仓内零引用 |
| 11 | `f_llm/src/constant/LLMAgent.cj` | .cj | ✅ | 1 个 agent 名常量，仓内零引用（对外 API） |
| 12 | `f_llm/src/constant/LLMType.cj` | .cj | ✅ | 9 个类型常量；`LLM_TYPE_CODE` 仓内零引用；注释中的 `prune` 由 `ContextPrunerName` 承载 |
| 13 | `f_llm/src/constant/ModelName.cj` | .cj | ✅ | `type ModelName = String` + 13 个常量；腾讯/搜索别名部分仓内零引用 |
| 14 | `f_llm/src/constant/ModelNames.cj` | .cj | ✅ | 归一逻辑（大小写缺陷见「一般」）；别名表缺 `zhipu/glm-5-flash`（仅记录） |
| 15 | `f_llm/src/constant/ModelNames_test.cj` | .cj | ✅ | 3 个用例，未覆盖裸名大写；类名 `ModelNamesTest` 与其他 `*_test` 不一致 |
| 16 | `f_llm/src/constant/Role.cj` | .cj | ✅ | 4 个角色常量，与 `ROLE_*` 使用一致 |
| 17 | `f_llm/src/constant/SkillType.cj` | .cj | ✅ | `AUXILIARY` 仓内零引用 |
| 18 | `f_llm/src/constant/SpecKind.cj` | .cj | ✅ | 7 个规格种类常量；`PRELIMINARY` 仓内零引用 |
| 19 | `f_llm/src/constant/SpecialAgentId.cj` | .cj | ✅ | `SpecialAgentId = Int64` + `SummarisingAgentId`（仓内零引用） |
| 20 | `f_llm/src/constant/SummaryActionKind.cj` | .cj | ✅ | `EXPERIENCE` 有使用，`INDIVIDUALITY` 无 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 安全性 1（downloadDir 沙箱）、正确性 4（html 正文、receivedAt、发送丢 text、normalize 大小写）、错误处理 2（canonicalize 吞原因、getPath 副作用）、并发 2（transport 无同步、锁内 close）、可读性/可维护性 3（重复消息、注释不符、默认值复制）。`Option` 均显式处理（`?? ''`、`match`），`EmailChannel.cj:165` 的 `getOrThrow` 前置已保证 `File.create` 成功 |
| §1 死代码 | 2 | 逐个 `private`/`internal` 全仓搜过：`ChannelMediator.normalize/keyOf/mutex/providers/instances`、`EmailChannel.checkAttachment/isDirectory`、`AttachmentSink.sinkMutex/FALLBACK_NAME/MAX_NAME_CHARS`、`FEmailTransport.email/conf/client`、`LLMConfig.getPath`、`ModelNames` 私有构造均有调用者；命中 2 处：`freeName` 不可达 `base`、`FakeEmailTransport.closed` 只写不读。`isAuto`/`resetAll`/`closeAll` 与 15 个 public 常量为对外可达 `public`，按硬原则一只记「仓内零引用」；`protected` 本部分为 0；未发现未使用 import（`EmailChannel_test.cj:20` 的 `std.sync.*` 供 `spawn`/`Future` 使用，未计入） |
| §2 重复逻辑 | 3 | 两两比对 34 个函数体（含测试类方法组）：`channel()` 两段 + `create()` 的「平台未知」三处（1）、`'chat-pro'` 默认值两处 + `_a2aEnabled` 内联键（2）、两个测试 Fake 的 `limit` 截断循环逐行相同（3）。`platforms()/accounts()/providerPlatforms()` 形态相近但去重规则不同，**不判**重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`/`throw UnsupportedException`（`grep` 本部分目录无命中）；命中 4 处静默 `catch`（合并为 1 条）。`case None => ()` 均为「可选值缺失」的正常分支 |
| §4 栈溢出 | 0 | 本部分无递归（`bareName`/`freeName`/`checkAttachment`/`render` 均为单层或「实例数」驱动）；`freeName` 的 `while(true)` 有 `return` 出口，不构成栈风险 |
| §5 OOM | 1 | 收信全量物化 + `limit` 无上界（`limit<=0` 被 f_email 解释为全部），峰值 ≈ Σ(正文 + 2×附件字节)；`instances`/`providers` 规模由配置条数约束，`bareName` 无按 `size` 预分配 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/bench 数据，热点不成立；锁内 `normalize`、逐封 `body()`、`canonicalize` 逐附件逐根目录、`getPath` 的 `exists` 四项写入待验证假设 1/2/5/6 |
| §6.2 大粒度锁 | 1 | `synchronized(mutex)` 里调 `Channel.close()`（网络 QUIT/LOGOUT）。`AttachmentSink.sinkMutex` 临界区只含「选名 + `File.create`」，无写入 I/O、无回调；单锁串行由第 4 部分登记 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` + `get()`、无批大小配置；`AttachmentSink` 的写盘本就在锁外并行；收信逐封 `body()` 是协议层串行，缺数据，见待验证假设 2 |
| §6.4 低效算法 | 1 | `freeName` 的线性探测（k 次 `exists`）；`platforms()` 的 `contains` 去重为 O(平台数²)，量级个位数，未报 |
| §7 降堆内存方案 | 1 | 附件流式落盘（无基线，待验证） |
| §8 降 CPU 方案 | 2 | 白名单解析 + `canonicalize` 缓存、`freeName` 探测（均无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象只有 `bareName` 的 `StringBuilder`（每次附件一次，KB 级）与 `channel()` 的 `ArrayList<Channel>`；`Array<Byte>` 由参数传入（逃逸），无「函数内创建、函数内用完的大对象」，收益无法用峰值内存证明。模块已启用 `--enable-local-mode`（`f_llm/cjpm.toml` 的 `compile-option`），无需额外改造 |
| §11 现有代码的 BUG（存量） | 14 | 20 个文件、约 60 个函数/属性逐一对过边界与空值：2 严重 + 8 一般 + 4 轻微（`bareName` 截断、失败残留文件、`register` 注释不符、Windows 分隔符）属存量缺陷/错误处理缺口。`getLLMAccessTryingElapsed` 的 `Int64.Max` 秒乘法按 `Duration` 文档核对后**不溢出**，不报；`bareName` 对空串/`.`/`..`/纯分隔符的处理已核对，正确 |
| §12 并发安全与锁粒度 | 3 | transport 无同步（共享路径 `ChannelMediator.instances`(static) → `channel()` → `EmailChannel.transport.client` → `Email` 可变会话状态）、锁内 I/O 与临界区过大、`closeAll`/`reset` 的生命周期接线。`ChannelMediator` 两表本身有 mutex 保护，`found`/`matches` 均为锁内取快照、锁外使用 |
| §14 功能完备性与 README 覆盖 | 3 | `receivedAt` 未接线、接收侧沙箱缺失（README:558 只承诺发送侧）、`closeAll` 无生产调用。其余 `public` 类型（`ChannelMediator`/`AttachmentSink`/`EmailChannel`/`EmailTransport`/`FEmailTransport`/`ReceivedMail`/`ReceivedAttachment`/`ModelNames`）在 README:879/934/1013 均有条目；`isAuto` 未文档化（已由第 2 部分登记，不重复计数） |
| 文件覆盖（§13 等） | 20/20 | 本部分 `files/f_llm.part8.txt` 共 20 行且全部为 `.cj`，`.md` 为 0，§13 文档一致性在本部分无取证对象（只引用了 README 作为承诺源）；20 个文件全部读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

> 存量缺陷 22 条（严重 2 + 一般 8 + 轻微 12），是否纳入修复待用户决定；本部分未修改任何源码，未运行构建或测试。

## 总评

本部分的骨架是干净的：中介者的「provider 表 + 实例表」两段式设计与 `fountain-baseline.md` §4 的中介者模式一致，`registerProvider` 同名不覆盖、空账号不猜、错误消息区分「不支持」与「找不到」，都是有意识的正确取舍；`AttachmentSink` 的路径穿越防护（`bareName` 只取最后一段）、同名顺延、选名与写盘分离也做得比一般实现扎实；13 个常量文件只是薄封装，无风险。

**阻塞项（严重 2 条）**：一是接收侧 `downloadDir` 完全没有沙箱约束，而这个值是模型可控的工具参数，绕开了本仓对模型可见文件操作的统一沙箱约定（可向任意可写目录新建文件）；二是收信路径把「邮件数 × 正文 × 2×附件字节」全量物化，`limit` 无上限且 `<=0` 被下游解释成「整箱全部」。两条都在 email 通道主路径上，建议最先修。

**可排期（一般 8 条）**：收发两侧的正文语义各自缺一块（发送丢纯文本、接收丢 HTML 正文）、`receivedAt` 恒空、`ModelNames.normalize` 大小写不对称会让 thinking 判断静默走错分支、`FEmailTransport` 的共享连接无同步、全局锁内关闭连接、根目录不可解析被误报为附件越界、`getPath` 在 getter 里建目录。都属于「功能看着正常、边界上不对」的类型。

**轻微 12 条**：重复判定与重复字面量、静默 catch、不可达兜底、复刻的 `isDirectory`、字节/字符截断、失败残留文件、注释与接线不符、测试隔离与弱断言，属维护性范畴。

**证据缺口**：本部分没有任何 bench/profile 数据，三条优化方案与六条待验证假设都未进入修复清单；最该补的是「元数据模式收信是否白拉整封附件」与「运行期是否会发生重装配」这两个决定了修复优先级的量。若后续能证明多会话并发调用通道是常态，`FEmailTransport` 的无同步问题应立刻上调为严重。
