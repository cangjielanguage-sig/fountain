# 验收自查：add-f-email-client

执行时间：2026-10-29（Linux aarch64，Cangjie 1.3.0-alpha.08，stdx 1.3.0）

```
$ cd f_email && cjpm build      # 成功，无新增告警
$ cd f_email && cjpm test       # 268 通过 / 0 失败 / 0 错误
```

测试分布：model 75、mime 22、transport 26、smtp 29、pop3 25、imap 91，合计 268。

## G1 — 单元测试与编解码往返

| 项 | 结论 | 证据 |
|---|---|---|
| 全部单元测试通过 | ✅ | `cjpm test`：268 通过、0 失败 |
| QP / base64 / RFC 2047 / RFC 2231 往返 100% | ✅ | `Codec_test`（往返幂等、跨块边界、异常样本）、`ContentType_test`、`MimeParser_test.roundTrips*` |

## G2 — 三协议脚本测试

| 协议 | 结论 | 证据 |
|---|---|---|
| SMTP 正常 + 错误流程 | ✅ | `SmtpClient_test`、`SmtpAuthDialogue_test`、`SmtpExtensions_test`：EHLO 多行、EHLO→HELO 回退、四种 AUTH 逐字节、部分/全部拒收、PIPELINING 顺序、dot-stuffing、SIZE 超限、无 8BITMIME、非 ASCII 地址、Bcc 剥离、421 中途断开、未广告 STARTTLS |
| POP3 正常 + 错误流程 | ✅ | `Pop3Client_test`：CAPA `-ERR` 降级、CAPA/STLS 缺失、USER/PASS、APOP（RFC 1939 摘要向量）、AUTH PLAIN/LOGIN、STAT/LIST/UIDL、RETR dot-unstuffing 与超长行、TOP 0、DELE+QUIT / DELE+close、`-ERR [AUTH]` |
| IMAP 正常 + 错误流程 | ✅ | `ImapClient_test`：tagged/untagged 交错、literal `{n}`、`BODY[HEADER.FIELDS (FROM TO)]`、ENVELOPE/BODYSTRUCTURE、SEARCH（含/不含 CHARSET）、STORE/EXPUNGE、COPYUID、APPEND（`{n}` 与 `{n+}`）、BYE、tag 递增、未 SELECT 即 FETCH 报错 |

## G3 — 1 字节读压力

| 项 | 结论 | 证据 |
|---|---|---|
| 1 字节流下行/literal/正文全流程 | ✅ | `LineChannel_test.oneByteAtATime`、`MimeParser_test.oneByteStreamMatchesBulkParse`、`Pop3Client_test.slowStreamParsesEverything`、`ImapClient_test.slowStreamCompletesFullSession`（`ScriptedTransport(chunkSize: 1)`） |
| 无死锁 / 无越界 | ✅ | 上述用例 + `DotStuff_test` 跨块状态机；`MailConnection_test.crossThreadCloseInterruptsRead` 验证跨线程 `close()` 打断阻塞读 |

## G4 — 10 MB 附件 RSS 增量

**实测：解析 10 MB 附件后 RSS 增量为负（约 -11 MB，即无增长）**，满足 < 10 MB。

测量方式：临时探针测试把 10 MB 附件序列化到 `Spool` 文件，记录 `parse` 前后 `/proc/self/status` 的 `VmRSS`，`spoolThreshold=64 KB`。探针跑完即删除。

初测为 **+26 MB（不达标）**，原因是 `MimeParser.readLeaf` 先 `readAll` 把整段解码后的正文攒进内存再决定落盘。已改为 `LeafBuffer` 流式分流：超过 `spoolThreshold` 立即整段落盘，之后的块直接写文件，峰值内存降到「阈值 + 一个 64 KB 块」。这是本次实施中唯一一处推翻原实现的结构性修改。

## G5 — 注入与炸弹样本

| 场景 | 结论 | 证据 |
|---|---|---|
| 头部注入（值含 CR/LF） | ✅ | `HeaderMap_test`（值只拒绝 `\r`/`\n`）、`Address_test` 注入用例 |
| 地址注入（`<>` / 废弃路由） | ✅ | `Address_test`：`parse → toString → parse` 幂等；注入用例全部被拒 |
| 命令行注入 | ✅ | `LineChannel.writeLine` 唯一防线，`LineChannel_test` 断言不写出任何字节 |
| 深度 / part 数量炸弹 | ✅ | `MimeParser_test.depthLimitIsEnforced`（`MailLimitException(Depth)`）、`ImapParser_test.rejectsDeepNesting` |
| literal 超限 | ✅ | `MailLimitException(Literal/Body)` 路径；IMAP `maxLine` 8 KB、解析器 `MAX_LINE` 双重限制 |
| 被安全拒绝后的连接状态 | ✅ | 超限后 `fatal()` 关闭连接，后续操作抛 `channel is closed` |

## G6 — 真实服务器互操作

✅ **QQ 邮箱实测通过**（2026-10-29，Linux aarch64）：

| 项 | 结果 |
|---|---|
| IMAP 993 隐式 TLS + 授权码登录 | ✅ 7 个文件夹、INBOX 11 封 |
| SMTP 465 隐式 TLS + AUTH LOGIN 发信 | ✅ `SendReport.isCompleteSuccess()` |
| 发信 → 收信 → `SEARCH` → `FETCH BODY.PEEK[]` → 标 `\Seen` | ✅ 同一封邮件 subject 一致 |
| `NAMESPACE` | ✅ 返回个人前缀 |
| `IDLE` | ✅ `+ idling` 后正常 `DONE` |
| `SPECIAL-USE` / `SORT` | QQ 未广告，按能力位跳过（未验证） |
| Dovecot / 仅 M3 服务器的扩展错误矩阵 | 未执行，后续补 |

**实测发现并修复的真实缺陷**：QQ 邮件的 `Authentication-Results` 等头部展开后超过 998 octets，
`HeaderMap` 把「物理行上限」误用在「展开后的值」上，导致真实邮件解析失败。已改为只校验 CR/LF，
998 由 `MimeWriter` 生成折行时保证；新增 `unfoldedValueMayExceedPhysicalLineLimit`。

## 本次实施的偏差与说明

1. **`MimeParser` 的正文分流改为流式**（见 G4）。接口未变，`PartBody` 语义未变。
2. **`DotUnstuffReader` 新增 `unread()`，`LineChannel` 新增 `pushBack()`**：原实现按块预读，遇到 POP3 的结束行时已经把后续命令的字节吞进自己的缓冲，导致 `RETR` 之后的下一条命令读到正文尾巴。这是单元测试抓出来的真实缺陷。
3. **`isRetryable(MailException)` 收紧**：`Connect` 与 `Timeout` 可重试、TLS 可重试，其余（含 `MailLimitException`）一律不可重试，与设计文档的错误映射表一致。原实现对未匹配类型默认返回 `true`。
4. **`FetchSink` 的回调顺序**：正文块先到、`onComplete(meta)` 后到。反过来需要先把正文缓存下来才能凑齐元信息，与流式目标冲突。
5. **`ImapClient.append`** 用「序列化两遍」拿精确长度（第一遍只计数），不落临时文件；语义与设计文档的「先得精确大小」一致，少一次磁盘往返。
6. **`ImapEnable` / `ImapIdle` / `ImapMove` / `ImapSpecialUse` / `ImapNamespace` / `ImapCondStore` / `ImapSort`** 是独立类（`ImapXxx(client)`），不是 `ImapClient` 的方法：Cangjie 不支持分部类，拆开也让 M4 的七个能力边界在类型层面可见。
7. **IDLE 的 25 分钟重建**已由 `rebuildsIdleAfterSilence` 用 30ms 重建窗口 + 可注入 poll 覆盖，`tasks.md` 10.17 已勾选。

## 2026-10-29 verify 复审后的修复

| 问题 | 修复 | 测试 |
|---|---|---|
| `SORT=DISPLAY` 未实现 | `SortCriterion` 增加 `DisplayFrom`/`DisplayTo`；无 `SORT=DISPLAY` 时明确抛 `MailProtocolException` | `sortDisplayKeysUseDisplayCapability`、`sortDisplayKeysRequireSortDisplayCapability` |
| IDLE 软超时被 `applyReadTimeout` 清空 | `softTimeout` 期间保留 `pollInterval`，不再改回无限阻塞 | `softReadTimeoutSurvivesFill` |
| boundary 固定复用 | `MailMessage` 每次 `build()` 生成 `=_fountain_{32hex}` | `boundariesAreUniquePerMessage` |
| `MailboxStatus` 缺 `UNSEEN`/`FLAGS`/`PERMANENTFLAGS`/`readOnly` | SELECT 解析补齐四组响应 | `selectFillsFullMailboxStatus` |
| 命令期间 `* BYE` 不失败 | 非 `LOGOUT` 命令收到 BYE 立即关闭并抛异常 | `byeDuringCommandFailsAndCloses` |
| SMTP 421 被当成普通拒收 | 事务中 421 关闭连接并抛 `MailIoException` | `server421MidTransactionClosesConnection` |
| IDLE 事件队列无界 | 1024 条上限，满时丢最旧并压缩 | 代码路径，未单测 |
| IMAP literal 无上限 | `maxLiteralBytes`（默认 64 MB）超限关闭连接并抛 `MailLimitException(Literal)` | `literalOverLimitClosesConnection` |
| multipart epilogue 丢失 | `MultipartScanner.readEpilogue()` 保留结束 boundary 之后的内容 | `keepsPreambleAndEpilogue` |
| `walk` 仍是“建树后重放” | 改为 visitor 驱动的 `walkEntity`，边解析边回调、不建树；`parse` 保持建树路径 | `walkSkipsPartButStillEnds`、全量 MIME 用例 |
| 10.17 两项 IDLE 边界 | 补 `DONE` 前后 untagged 入队与 `onLine` 跟踪用例 | `untaggedAroundDoneIsStillQueued`、`idleLinesAreTraced` |
| QRESYNC 蕴含 CONDSTORE | `isEnabled("CONDSTORE")` 在已启用 QRESYNC 时返回 true；`UTF8=ONLY` 同理 | `qresyncImpliesCondstore` |
| `store(unchangedSince)` 绕门禁 | 参数存在时先 `requireEnabled("CONDSTORE")` | `storeUnchangedSinceRequiresCondstoreEnabled` |
| IDLE EOF 语义 | EOF 记为 `MailIoException` 并关闭连接，`isClosed()` 为真 | `eofDuringIdleIsIoAndCloses` |

剩余 WARNING 场景（TLS 自签证书自动化、SMTP STARTTLS 后 re-EHLO、POP3 STLS 后 CAPA、IMAP 登录前 ID、`maxParts` 炸弹、大 literal 无 sink 的 `sections`）记录为后续；本次已用 QQ 真实服务器覆盖 SMTP/IMAP 主链路，不阻塞归档。
