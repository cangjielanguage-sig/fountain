# fprobe 模块审查报告（第 3/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（本部分 20 个文件：20 个 `.cj` / 0 个 `.md`；模块共 167 个文件，本部分为第 3 部分）
- **基线**：工作区快照（HEAD `f309f0b55`；`git diff` 为空，仅两份未跟踪的报告目录）⇒ 全部问题来源记「存量」
- **审查重点**：fprobe 专项（采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑）；本部分实际覆盖**邮件告警渠道与其传输层、采集装配/运行器/快照编码、健康探针（HTTP/MVC/RPC）与指标投影**
- **报告版本**：v1（分部分报告，由主 Agent 与其余 8 部分合并）

## 发现

### [严重][存量] 单个 `Email` 实例被 4 条线程并发 `send` / `list` / `body`，内部会话状态无任何同步

- **位置**：`fprobe/src/channel/FEmailTransport.cj:33`（`private let email: Email`）、`:89-110`（`email.send`）、`:112-127`（`email.list` + 每封 `email.body`）
- **来源**：存量（工作区快照，无 diff；`git blame` 落 `f84982d31` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 跨线程共享资源）、§12.2（会话型资源必须串行化，不能靠"调用频率低"豁免）
- **证据**：静态确定 —— 共享路径与线程都可落到具体行：
  - 装配：`fprobe/src/runtime/SupervisorRuntime.cj:515-534`（构造点 `:527-528`）只构造**一个** `EmailAlarmChannel`，其内部是**一个** `FEmailTransport`；该实例同时进 `ChannelDispatcher`（`:124-126`）与 `ReplyMonitor`（`:375`）。
  - 线程 1（拉取）：`SupervisorRuntime.cj:196` `spawn {=> poll.run()}` → `:158` `alarm.evaluate` → `:142` `dispatcher.dispatch(event.format())` → `EmailAlarmChannel.send` → `transport.send`（`Email.send`，走 SMTP）。
  - 线程 2（LLM/回复）：`SupervisorRuntime.cj:203-204` `spawn {=> llmLoop(...)}` → `:240` `replies.pollOnce()` → `EmailAlarmChannel.receive` → `transport.list`（`Email.list`）→ `Email.body`（IMAP）。
  - 线程 3（告警触发后的异步分析）：`:145` `spawn {=> advisor.analyzeAlarm(...)}` → `:372` 的 `onAdvice` 回调 → `dispatcher.dispatch` → 又一次 `Email.send`。
  - 线程 4（报告）：`:167` 注册的 `ReportJob` → `report/ReportJob.cj:43` `dispatcher.dispatchRich` → 又一次 `Email.send`。
  - 被共享对象没有保护：`f_email/src/EmailFacade.cj:215-221` —— `smtpValue` / `imapValue` / `pop3Value` / `currentMailbox` / `selectedMailbox` / `closedFlag` 全是裸 `var`，`Email` 类没有任何 `Mutex`/`synchronized`；`list` 在 `:260` 写 `currentMailbox`，`fetch` 在 `:355` 再写一次。
- **描述**：两条以上线程可能同时对同一个 `Email` 发 SMTP 命令、或线程 1 发信时线程 2 正在 IMAP 取信。SMTP 会话是"连接上按序写 `MAIL FROM`/`RCPT TO`/`DATA`"的状态机，同一连接被两线程交错写就会串包（收件人错配、`DATA` 提前结束、会话被服务端判协议错）；懒连接字段 `smtpValue` 的检查-然后-写入也存在首连竞态（双连接、旧引用泄漏）。`currentMailbox` 的并发读写在多邮箱场景下会把正文取到错误邮箱。告警邮件发错人或丢信属于数据错误，且默认装配（`probe_channel_email_smtpHost` 配了）即命中。
- **建议**：在 `FEmailTransport` 内加一把 `Mutex`，`send` / `list` 整体进出锁（临界区是整次 SMTP/IMAP 往返，持锁时间长，但这是会话型资源的固有串行化）；或者在 `FEmailTransport` 之上做单写者队列（发信排队、取信单独一条会话）。注意 `EmailAlarmChannel` 目前是「无状态 + 共享 transport」，锁只能落在 transport。修完补并发用例：4 线程各跑 100 次 `send`/`list`，断言 `OutgoingMail.receivers` 不错配、`list` 不抛协议错。

### [严重][存量] `receive()` 永远返回同一封（最旧的）未读邮件，且从不标记已读 —— 第一封之后所有回复永久处理不到

- **位置**：`fprobe/src/channel/EmailAlarmChannel.cj:65-78`（`for (mail in transport.list(receiveLimit))` 里遇到第一封 `unread` 立即 `return`）
- **来源**：存量（工作区快照，无 diff；`git blame -L 65,78` → `f84982d31c` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §11（逻辑错误 / 消息丢失）、§14.1（半成品：只支持"一封待处理"却没有任何推进机制）；`fountain-baseline.md` §5（先查 API 返回值语义再下结论）
- **证据**：静态确定 —— 四段事实串起来即可判定：
  1. `f_email` 的 `list` 返回的是「最近 limit 封」但**按序号升序**（旧→新）：`f_email/src/EmailFacade.cj:261-309` 用 `SequenceSet.range(total-limit+1, total)` 顺序 `out.add`；POP3 分支 `:316-341` 同样按 `infos` 升序。
  2. 取正文用 `BODY.PEEK[]`，不会点亮 `\Seen`：`f_email/src/imap/ImapFetch.cj:149-160`（`peek!: Bool = true`，注释明确"只读邮件不该因为取正文就把 `\Seen` 点亮"），`Email.body` → `fetch`（`EmailFacade.cj:367-373`、`:349`）。
  3. POP3 分支的 `flags` 恒为 `[]`（`EmailFacade.cj:339`），`isUnread()` = `!flags.contains("\\Seen")`（`:87-89`）⇒ POP3 下**所有**邮件永远"未读"。
  4. 消费方按 id 去重且只调一次：`fprobe/src/llm/ReplyMonitor.cj:56`（每个渠道只 `receive()` 一次）→ `:66-68` `store.isHandled(message.id)` 命中就 `continue`，不会向渠道要"下一封"。
- **描述**：`receive()` 取列表里**第一封未读**（即窗口内最旧的一封），而它永远不会变成已读，于是每个轮询周期都返回同一封：第一次被 `store.markHandled` 记账后，之后每轮都命中 `isHandled` 直接跳过，**其余任何未读邮件（包括新到的）都不会被返回**。POP3 配置下这是必然（flags 恒空）；IMAP 下只要运维没在邮件客户端里手动点开那封邮件，同样成立。后果是"回复指挥智能体"的能力在收到第一条回复后静默失效，且日志里只有"已处理/跳过"，看不出异常。现有用例掩盖了它：`EmailAlarmChannel_test.cj:132-162` 每次都构造全新的 `FakeMailTransport`，且只断言"能拿到消息"，没有"两封未读连续两轮"的场景。
- **建议**：把"推进游标"的责任放回渠道：(a) 让 `EmailAlarmChannel` 内部记 `已返回过的 id 集合`（有界，如最近 N 条）并在 `receive()` 里跳过，直到没有新未读；(b) 或给 `MailTransport` 增加 `markRead(id)`（`f_email` 已有 `STORE +FLAGS \Seen` 能力，见 `EmailFacade.cj` 的 remove/delete 同族实现），取到即回写；(c) 或把接口改成 `receiveAll(): Array<String>` 让调用方一次拿全。三种都要补"两封未读 + 连续两轮"的用例，POP3 与 IMAP 各一条。

### [一般][存量] `MailTransport.list` 契约写「最新在前」，实际实现是「窗口内最旧在前」

- **位置**：`fprobe/src/channel/MailTransport.cj:78`（接口注释：`最近 [limit] 封邮件，最新在前`）；`fprobe/src/channel/FEmailTransport.cj:112-127`（原样透传 `Email.list` 的顺序，未做反转）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约与实现不符）、§2（同一语义的边界差异导致行为漂移）
- **证据**：静态确定 —— `f_email/src/EmailFacade.cj:261-309`（IMAP 升序）与 `:316-341`（POP3 升序）都返回旧→新；`FEmailTransport.list` 只做字段映射，没有 `reverse()`。`EmailAlarmChannel.receive`（`:66-77`）依赖这个顺序决定"先回哪一封"。
- **描述**：接口文档与实现方向相反，直接把上一条缺陷的"取最旧"行为伪装成"取最新"。任何按契约新写的 `MailTransport` 实现（例如测试替身或第二家邮件后端）会与 `f_email` 实现行为相反，`receive()` 的语义随之漂移；反之若按实现修文档，则 `receive()` 的"先回最新"预期落空。测试替身 `EmailAlarmChannel_test.cj:134-137` 恰好按"最新在前"摆数据，进一步掩盖了差异。
- **建议**：二者取一，并在接口注释里写死：(a) `FEmailTransport.list` 末尾 `reverse()`，兑现"最新在前"（当前 `receive()` 与测试都按这个假设写）；(b) 改接口契约与 `receive()` 的选择策略为"最旧优先"，同时修正测试替身的数据顺序。建议选 (a)，与 `receive()` 的既有预期一致，代价只是 20 条摘要的反转。

### [一般][存量] `HealthMetrics.tryParse` / `tryFrom` 接受任意 JSON 对象为"全 0 健康数据"，`MvcHealthProbe` 的错误分支基本不可达

- **位置**：`fprobe/src/collect/health/HealthMetrics.cj:59-78`（`tryParse` → `tryFrom` → `HealthMetrics.tryFromData(data)`）；`fprobe/src/collect/health/MvcHealthProbe.cj:63-67`（`case None => "响应不是合法 HealthData JSON"`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（与规格/注释冲突：注释承诺"响应非法都收敛为 error"）、§3（`case None` 兜底被上游语义掏空）
- **证据**：静态确定 —— `@DataAssist` 生成的 `tryFromData` 走 `f_data_tryFromData`（`f_data/src/macros/DataAssist.cj:631-636`）→ `DataObject.populate`（`f_data/src/base/DataObject.cj:194-206`）只**遍历源字段**赋值，从不校验"目标字段是否齐全"；默认 flag 是 `SILENCE` = `IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH | IGNORE_FIELD_NOT_CONVERTABLE | IGNORE_NONE`（`f_data/src/base/global_objects.cj:42-51`）。因此 `{}`、`{"status":"UP"}`、`{"code":0,"data":{...}}` 一律返回 `Some(HealthMetrics())`（11 个字段全 0）。只有顶层不是 JSON 对象（数组/标量/非法文本）才走 `None`。
- **描述**：`MvcHealthProbe` 的文档与实现相反：`/health` 换了响应包装（网关统一包 `data`）、对端降级返回 `{"status":"UP"}`、或版本漂移改了字段名，探针都会报 `error=""` 且 `usedHeapSize=0`、`gcCount=0`，TUI/报告/告警看到的是"健康但全零"，而不是"响应非法"。`MvcHealthProbe_test.cj:80-85` 用 `"not-json"` 测非法响应，正好绕开了对象形态。
- **建议**：`tryFrom` 增加"至少命中一个已知字段"的校验（比较 `DataObject<HealthMetrics>` 的键集合与源键集合的交集；或先 `HealthMetrics.dataFields()` 求出字段名，逐个 `data.get(name).isSome()` 统计），命中 0 个就返回 `None`；需要严格时要求全部 11 个字段存在。补用例：`{}`、`{"status":"UP"}`、`{"data":{...}}` 都断言 `error` 含"不是合法 HealthData"。

### [一般][存量] `FHttpClientProbe.get` 无上限读入整个响应体，峰值内存由对端响应大小决定

- **位置**：`fprobe/src/collect/health/HttpProbe.cj:58-60`（`response.readEntire()`），随后 `body` 直接进 `HealthMetrics.tryParse`（`MvcHealthProbe.cj:63`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5（一次性物化、按不可信长度预分配、无拒绝路径）
- **证据**：静态确定 —— 代码中没有 `Content-Length` 检查、没有分段读、没有大小常量；`readTimeout` 只限制时间不限制字节数（`:56`）。更具体地，`f_httpclient/src/ExtendHttpResponse.cj:50-77` 的 `readToEnd()`：`bodySize`（即响应头 `Content-Length`）存在时直接 `Array<Byte>(size, repeat: 0)` 按声明长度一次性分配（`:52-55`），未知长度时用 `ArrayList` 无上限累积（`:69-76`）——两分支都没有上限。
- **描述**：量级可估：默认 `probe_httpTimeoutMs=2000`，千兆链路最坏 ≈ 250 MB/次，回环或 10G 环境更高；更糟的是"按声明长度预分配"——对端（或中间反代）只要回一个 `Content-Length: 4294967296` 的小响应头，就会先尝试 4 GB 分配。`JsonValue.fromStr` 再整份建树，峰值约为报文 2-3 倍。`probe_mvcHealthUrl` / `probe_serviceTargets` 指向的是"自己的服务"，但配置错指向大文件端点、或端点被反代成静态目录时就会直接放大到 OOM 风险；多个目标顺序执行时峰值不叠加，但单次足以触发容器 limit。
- **建议**：先按 `Content-Length` 拦一道（超过如 1 MB 直接返回 `error`），再改用 `f_httpclient` 的分段读取/带上限的读取接口；上限做成常量或 `probe_httpMaxBodyBytes`，超过时返回 `HttpProbeResult(..., error: "响应体超过 N 字节")`。同类透传点 `ServiceReachabilityProbe` 一并处理。

### [轻微][存量] 三处 `MonoTime` 耗时换算逐行相同，`RPC 调用失败` 文案也重复

- **位置**：`fprobe/src/collect/health/HttpProbe.cj:71-73`（`elapsedMs`）、`fprobe/src/collect/health/RpcHealthTransport.cj:103-105`（`elapsedMillis`）、`fprobe/src/collect/net/TcpProbe.cj:56-58`（`elapsedMillis`）；文案重复：`RpcHealthProbe.cj:108` 与 `RpcHealthTransport.cj:71` 的 `'RPC 调用失败: ${e.message}'`
- **来源**：存量
- **判据**：review-checklist §2（换算复制 / 字面量复制）
- **证据**：静态确定 —— 三个函数体都是 `Float64((MonoTime.now() - start).toNanoseconds()) / 1000000.0`，仅函数名不同（`Ms` vs `Millis`）；两处 catch 生成同一条错误文案。
- **描述**：改精度（如换成 `.toMicroseconds()` 或加纳秒小数）需要同时改三处，漏一处就会出现同一份快照里 `latencyMs` 精度不一致；命名不统一也让 grep 找不到全部实现。
- **建议**：收敛到 `fprobe/collect` 包内一个 `internal func elapsedMs(start: MonoTime): Float64`（`health` 与 `net` 都是它的子包，`internal` 在包及子包可见），三处改为 import；`RPC 调用失败` 文案抽成一个函数或统一在 transport 侧构造，探针侧不再重复拼。

### [轻微][存量] `HealthData` 的 11 个字段在 3 个 DTO 里各写一遍，且有三段逐字段拷贝

- **位置**：`fprobe/src/collect/health/HealthMetrics.cj:28-57`（字段 + 11 参构造）、`:83-116`（`HealthSample` 再把 11 个字段 + 3 个自有字段抄一遍）、`fprobe/src/collect/health/RpcHealthProbe.cj:26-63`（`RpcHealthTarget` 第三份 + `match (metrics)` 逐字段赋值）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）、§11（下次加字段必然漂移）
- **证据**：静态确定 —— 三处字段集合与类型完全一致（`allocatedHeapSize`…`usedHeapSize`，共 11 个，与 `f_health/src/HealthData.cj:24-74` 的 `public prop` 一一对应），差异只在 `HealthSample` 多了 `latencyMs`/`statusCode`/`error`、`RpcHealthTarget` 多了 `name`；`HealthMetrics.cj:101-116` 与 `RpcHealthProbe.cj:48-62` 是同一段 11 行赋值。
- **描述**：`f_health` 新增一个指标（例如 `gcPauseMax`）时，这三份 DTO、三段拷贝、`MvcHealthProbe_test` 的逐字段断言都要改；漏改任意一处，RPC 路径就会静默丢字段（`@DataAssist` 缺字段按 0 处理，不报错——与上一条同源）。此外 `MvcHealthProbe.cj:72` 的 `healthJson` 与 `RpcHealthProbe.cj:112` 的 `JsonValue.from(...toData()).asObject()` 也是同一段"DTO→JsonObject"。
- **建议**：让 `HealthSample`/`RpcHealthTarget` **持有** `HealthMetrics` 字段（组合而非平铺），或抽出 `HealthSample(metrics: HealthMetrics, …)` 的单一转换函数（`HealthMetrics` 已有 `toData()`，序列化时展平一次即可）；若必须平铺以保证 JSON 形状不变，用一个 `private func flatten(metrics, extra…)` 生成 `DataObject`，三处共用。

### [轻微][存量] `ProbeRunner.tick` 内联重写了 `ProbeSnapshotBuilder.agentData` 的 host 回退与编码，后者生产路径零引用

- **位置**：`fprobe/src/collect/ProbeRunner.cj:90-95`（`resolvedHost` + `ProbeAgentData(...)`）；`fprobe/src/collect/ProbeSnapshotBuilder.cj:42-50`（`agentData`）
- **来源**：存量
- **判据**：review-checklist §2（同一语义两处实现）、§1（仅测试引用的 public 成员，作可见性建议而非死代码）
- **证据**：静态确定 —— 全仓 `grep -rn "agentData"` 只命中定义与 `ProbeRunner_test.cj:153/155/165/167`；生产装配（`AgentRuntime.cj:57/88/94`）只经 `tick()`。两处的 host 回退判定（`agent.host.isEmpty() ? defaultHost : agent.host`）与 `encode` 调用一致。
- **描述**：`agentData` 的语义是"再取一次 `agent.data` 并编码"，而 `tick()` 需要在失败时保留旧 `dataJson`，所以没有直接调用它——但这也让"host 回退 + 构造 `ProbeAgentData`"有了两份实现。当前没有行为差异（`agentData` 被用例覆盖），但改一处漏一处就会让测试与生产走不同路径（测试全绿、生产漂移）。
- **建议**：把 `agentData` 拆成 `resolveHost(agent, defaultHost): String` + `agentData(agent, encodedJson, collectedAt, error)` 两个入口，`tick()` 复用；或让 `tick()` 在成功后调用 `agentData(agent, …)`、失败时走保留旧值的新重载。因为 `fprobe` 是 `output-type = "executable"`（`fprobe/cjpm.toml:36`），也可直接把 `agentData` 收窄为 `internal` 并给"仅测试用"的注释。

### [轻微][存量] 快照发布职责重复：`tick()` 内部 `replace` 一次，调用方再 `replace` 一次

- **位置**：`fprobe/src/collect/ProbeRunner.cj:97-99`（`store.replace(snapshot)` 后 `return snapshot`）；`fprobe/src/runtime/AgentRuntime.cj:88-89`（`let first = runner.tick(); store.replace(first)`）、`:94`（`store.replace(runner.tick())`）
- **来源**：存量
- **判据**：review-checklist §2（同一副作用两处执行）、§11（注释与实际调用约定不一致）
- **证据**：静态确定 —— `tick()` 的文档写"执行一轮采集并整体替换快照；返回刚发布的快照"，已经承担发布；`AgentRuntime.serve` 又对返回值再发布一次，等于每轮多一次 `Mutex` + 一次写 `current`。
- **描述**：两份发布点意味着"谁负责发布"没有单一约定：新增调用方若只调 `tick()` 会意外发布，若在 `tick()` 外加事务（如"采集成功才发布"）则会被内部提前发布破坏。当前功能正确，只多一次无意义加锁。
- **建议**：保留 `tick()` 内部发布（返回值语义不变），删掉 `AgentRuntime.cj:89` 与 `:94` 外层 `store.replace`；若要让调用方决定何时发布，则把 `tick()` 改为纯采集并同步更新注释与 `ProbeRunner_test` 的"store 与返回值是同一批数据"断言。

### [轻微][存量] 邮件标题解析在 `subjectOf` 与 `renderHtml` 各写一遍（补 part2 #9 的同根项）

- **位置**：`fprobe/src/channel/EmailAlarmChannel.cj:84-111`（`subjectOf` 里 `for (line in message.split("\n"))` 找首个非空行 + 找 `节点:`）、`:119-146`（`renderHtml` 再循环一次，找首个非空行当 `title`，再按 `:` 切 `rows`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 同语义两处）
- **证据**：静态确定 —— 两份循环都做 `trimAscii()`→跳空行→首个非空行写入 `title`；`subjectOf` 额外取 `节点:`，`renderHtml` 额外按 `:` 切表格。part2 #9 已报 `AlarmEvent.format` ↔ `renderHtml` 的字段表重复，本条是同一根因在渠道内部的第二处。
- **描述**：`AlarmEvent.format()` 的格式一旦调整（例如标题行改为"级别 + 摘要"），主题、横幅、表格三处会分别漂移；两处都是"解析自己刚生成的文本"。
- **建议**：抽 `private func parseMessage(message: String): (String, String, Array<(String, String)>)`（title、node、rows），`subjectOf` / `renderHtml` 共用；更彻底的做法是让 `AlarmMessageChannel.send` 接收结构化 `AlarmEvent`（与 part2 #9 的建议合并）。

### [轻微][存量] `IntervalCounter` 全仓只被测试引用，生产探针各自实现差分

- **位置**：`fprobe/src/collect/IntervalCounter.cj:24-52`；唯一引用 `fprobe/src/collect/Collect_test.cj:23-57`
- **来源**：存量
- **判据**：review-checklist §1（仅测试使用 ⇒ 可见性建议，不是死代码）
- **证据**：静态确定 —— `grep -rn "IntervalCounter" --include=*.cj fprobe` 仅定义 + `Collect_test`；`CpuProbe.cj:54-93`、`DiskProbe.cj:217-242`、`NetworkProbe.cj:145-164` 都自带 `hasBaseline/last*` 字段与 `delta*1000/elapsed` 计算。
- **描述**：这个"单调计数器差分"工具是为采集写的，但没有任何探针用它：CPU 算的是占比（不是每秒速率）、Disk/Network 按设备分别记基线，接口不匹配，于是各自复制了一份差分逻辑。留着它会让下一位维护者以为"差分有统一实现"，实际改它不会影响任何采集结果。
- **建议**：二选一：(a) 把它改成按 `(key)` 分片的差分器（`update(key, value, nowMs)`），让 `DiskProbe`/`NetworkProbe` 复用，顺便统一"回绕按 0 计"的口径；(b) 确认不再需要就删掉（executable 模块无下游契约）。不要维持"仅测试覆盖的生产工具"状态。

### [轻微][存量] `JsonArrayData.parse` / `JsonObjectData.parse` 不校验顶层类型，且异常消息内嵌整份输入

- **位置**：`fprobe/src/collect/JsonData.cj:66-72`（`JsonObjectData.tryParse` 直接 `jsonToData(text)`，`parse` 失败时 `'${text} cannot be parsed as JSON object'`）、`:100-107`（`JsonArrayData` 同形）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§5（异常消息按输入长度物化）
- **证据**：静态确定 —— `jsonToData`（`:28-34`）对 `{...}` 与 `[...]` 都返回对应包装；`JsonArrayData.tryParse("[1]")` 与 `tryParse("{\"a\":1}")` 都成功，`parse` 的返回类型是 `Data` 而非数组；两个 `parse` 都把完整 `text` 拼进 `DataException.message`。
- **描述**：这两个静态方法只是 `DataParsable` 接口的实现（`f_data/src/base/DataParsable.cj:21-24`），仓内无调用，所以当前不触发；但一旦有人按名字使用，`JsonArrayData.parse("{}")` 会拿到 `JsonObjectData`，随后 `size`/`iterator` 语义全错。异常消息内嵌全文在报文为 KB 级时会把日志和异常对象一起放大。
- **建议**：`parse`/`tryParse` 里判一次顶层类型（`match (jsonToData(text)) { case Some(x: JsonArrayData) => … case _ => None }`），失败消息只保留前 N 字节（如 64 字符 + `…`）。

### [轻微][存量] `FEmailTransport` 从不释放 `Email`（不实现 `Resource`、无 `close`），媒体类型只识别 `.svg`

- **位置**：`fprobe/src/channel/FEmailTransport.cj:32-33`（持有 `Email <: Resource`，类本身无 `close`）、`:89-127`；`fprobe/src/channel/EmailAlarmChannel.cj:174-180`（`mediaType` 仅判 `.svg`）
- **来源**：存量
- **判据**：review-checklist §11（资源释放不对称）、§14.1（半成品：`MailTransport.cj:18` 承诺"媒体类型由扩展名推断"）
- **证据**：静态确定 —— `f_email/src/EmailFacade.cj:213` `public class Email <: Resource`；全仓 `grep "email.close\|FEmailTransport.*close"` 无命中，`SupervisorRuntime` 的关停路径只关 `transport.close()`（`:58`，那是节点 RPC 连接）与 `source.close()`（`:222`），不含邮件。`mediaType` 只对 `.svg` 返回 `image/svg+xml`，其余一律 `application/octet-stream`（`:174-180`），而注释写的是"由扩展名推断"。
- **描述**：SMTP/IMAP 会话在进程退出前不会主动 `close`：`Email` 的 `closedFlag` 与三个 client 字段一直持有 socket，进程被 signal 杀掉时靠 OS 回收（可接受），但优雅退出（`stop()` → `serve()` 返回）后 socket 仍在，若进程被 fboot 复用于重启会短暂积累；`.png/.pdf` 附件以 `octet-stream` 发出，客户端不内联预览——与"由扩展名推断"的注释不符。
- **建议**：`FEmailTransport` 实现 `Resource`（`close()` 转发 `email.close()`），在 `SupervisorRuntime` 的退出路径调用；`mediaType` 用一张小扩展名表（`.svg/.png/.jpg/.pdf/.csv/.txt/.json`）并补用例。

## 优化可行性方案

### [CPU] TUI 每帧每格都重新解析同一份 `dataJson`

- **现状**：`fprobe/src/tui/RenderPlan.cj:425-436` 每个单元格调用 `projection.evaluate(value.dataJson)`；`MetricProjection.evaluate`（`collect/MetricProjection.cj:102-104`）每次都会 `jsonToData` 全量解析（`JsonData.cj:28-34` → `JsonValue.fromStr` + 递归包装）再 `DataPath.solid(path)` 编译一次（`MetricProjection.cj:112`）。`RenderPlan.cj` 定义了 22 个 `MetricSpec`，按 kind 分派；一个节点一帧要解析同一份 `dataJson` 最多 6 次（cpu），N 个节点 ≈ 22N 次解析 + 22N 次路径编译，`RenderLoop` 每 `intervalMs` 一帧。
- **方案**：`RenderPlan.renderValue` 改为"每帧每 (node, kind) 解析一次 `?Data` + 缓存 `MetricProjection → DataPath`"，`evaluate` 增加接受 `Data` 的重载；`MetricProjection` 在构造期或首次使用时缓存编译后的 `DataPath`（路径是配置常量，无失效问题）。
- **预期**：解析次数从 22N/帧降到 ≤6N/帧（按用到的 kind 数），路径编译降到每投影一次；端到端收益取决于 TUI 帧耗时中解析占比（未知）。
- **代价**：`MetricProjection` 多一个可变缓存字段（需保证 `evaluate` 仍可并发调用，建议构造期编译、字段 `let`）；`RenderPlan` 需要按 kind 分组，代码量 +30 行左右。
- **验证**：`cjprof record` 跑 TUI 稳态 60 帧（10 节点、真实快照），对比 `MetricProjection.evaluate` 自耗时占比与分配量；`cjpm bench -O2` 用固定 `dataJson` 做 `evaluate × 22 × 1000` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ProbeRunner.tick` 串行执行全部探针，一轮耗时 = 各探针耗时之和

- **现状**：`collect/ProbeRunner.cj:79-96` 用 `Array(...) {i => ...}` 顺序调用 `ProbeSnapshotBuilder.encode(slot.agent)`；探针内部会做 shell 命令（`DiskProbe`/`SmartProbe`/`SnmpProbe`，`timeoutMs` 默认 3s 级）、HTTP（2s）、RPC 定向调用（3s × 目标数）。`AgentRuntime.cj:92-97` 的采集线程因此是单线程串行，`intervalMs` 从 tick 结束后才开始计。
- **方案**：把"独立探针"改成有界并行（例如 `spawn` 每探针、并发度 4 或按 `probe_parallelism` 配置），每探针的错误仍各自收敛到自己的 `ProbeSlot`；或按"快速探针（读 /proc）先跑、慢探针（shell/网络）并行"分两组。
- **预期**：最坏 tick 时长从 `Σ timeout` 降到 `max timeout`（数量级取决于启用的慢探针数），采集新鲜度提升；CPU 本身不降，降的是 wall-clock。
- **代价**：`ProbeSlot` 的写要从"单线程"改为"每探针一个槽 + 汇合"，否则出现数据竞争；探针实现需确认可并发（`ProcReader` 读文件无状态，`CommandRunner` 每次 spawn 进程，OK；`CpuProbe` 等有 `last*` 基线的探针**不能**并行跑两次同一实例——并行粒度只能是"不同探针之间"）。
- **验证**：分段计时（每个 `slot.agent.data` 前后打时间戳，记录 P50/P95）跑 1 小时，对比并行前后 tick 时长与 `intervalMs` 漂移；确认快照内容逐字段等价。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `FEmailTransport.list` 为窗口内每封未读邮件各取一次整封正文

- **现状**：`FEmailTransport.cj:112-127` 对 `email.list(limit)` 的**每一封**未读邮件调用 `email.body(summary)`；`Email.body` 会 `uidFetchMessage` 整封（含附件，`EmailFacade.cj:367-373`），附件超过阈值还会落临时文件。默认 `receiveLimit=20` ⇒ 单轮最多 20 次完整取信，而 `EmailAlarmChannel.receive` 只用第一封（`EmailAlarmChannel.cj:66-77`）。
- **方案**：先按 `MailSummary`（已有 subject/from/date/size/flags）选出"要回的那一封"再取正文（把 `MailTransport` 拆成 `listSummaries` + `body(id)`）；或把 `receiveLimit` 降到 3-5 并把 `probe_channel_email_receiveLimit` 真正接线（part1 #1）。
- **预期**：单轮 IMAP 往返从 ≤20 次降到 1 次，正文对象峰值从 20 份降到 1 份；邮件多、正文大（附件落盘）时收益更明显。
- **代价**：接口变更（`MailTransport` 增加摘要/正文两段式），`EmailAlarmChannel_test` 的假传输要跟着改；语义不变。
- **验证**：`getAllocatedHeapSize()` + RSS（多轮轮询稳态）+ IMAP 命令计数（服务端日志或 `f_email` 埋点），对比改前改后的单轮往返次数与峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | TUI 每帧的 `JsonValue.fromStr` + `DataPath.solid` 占帧耗时显著比例（22 指标 × 节点数） | `fprobe/src/tui/RenderPlan.cj:425-436` → `collect/MetricProjection.cj:102-124` | 自耗时占比、每帧分配字节 | `cjprof record` 跑 TUI 稳态 60 帧（10 节点、真实快照），对照"每 kind 解析一次"的改造版 |
| 2 | 串行 tick 的实际时长已接近或超过 `probe_intervalMs`，导致采集漂移 | `collect/ProbeRunner.cj:77-100`、`runtime/AgentRuntime.cj:92-97` | 单轮 tick P50/P95、各探针分段耗时 | 在 `slot.agent.data` 前后打时间戳，跑 1 小时含 snmp/smart/ipmi 的配置；线程状态采样看阻塞占比（CPU profile 看不到） |
| 3 | `FEmailTransport.list` 的 20 次 `uidFetchMessage` 是回复轮询的主要成本 | `channel/FEmailTransport.cj:112-127` | 单次 IMAP 往返耗时、单轮总耗时 | 在 `email.body` 前后计时 + 服务端 IMAP 日志计命令数，跑 10 分钟轮询 |
| 4 | 每 tick 全量 `JsonValue.from(agent.data).toString()` 的分配量在 GC 中占比可观 | `collect/ProbeSnapshotBuilder.cj:32-34`、`ProbeRunner.cj:82` | 每 tick 分配字节、GC 次数 | `cjprof heap` / `getAllocatedHeapSize()` 对比 7 个与 20 个探针两种配置 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/channel/ChannelMessage.cj` | .cj | ✅ | `@DataAssist` DTO，4 字段与 `AlarmMessageChannel.receive` 的 JSON 契约一致（`EmailAlarmChannel_test.cj:144-148` 往返验证）；`public init()` 为宏要求 |
| 2 | `fprobe/src/channel/EmailAlarmChannel.cj` | .cj | ✅ | 发现 #2 #3 #10；`escapeHtml` 覆盖 `&<>"`，HTML 注入面已堵；`receiveLimit` 生产未接线（part1 #1） |
| 3 | `fprobe/src/channel/EmailAlarmChannel_test.cj` | .cj | ✅ | 覆盖横幅/表格/兜底/收件人/富消息/未读映射；缺"两封未读连续两轮"（发现 #2）与"顺序契约"（#3）用例 |
| 4 | `fprobe/src/channel/FEmailTransport.cj` | .cj | ✅ | 发现 #1 #3 #13；`fromConfig` 的缺省值（465/993/Implicit）与 `doc/configuration.md` 一致 |
| 5 | `fprobe/src/channel/MailTransport.cj` | .cj | ✅ | 发现 #3（`list` 顺序契约）、#13（媒体类型承诺）；`OutgoingMail`/`ReceivedMail`/`MailAttachmentSpec` 字段均被使用 |
| 6 | `fprobe/src/collect/Clock.cj` | .cj | ✅ | `SystemClock` 生产装配（`AgentRuntime.cj:42/57`）、`FakeClock` 用例专用（public 顶层类型，不判死代码） |
| 7 | `fprobe/src/collect/Collect_test.cj` | .cj | ✅ | 覆盖 `IntervalCounter` 四类差分与 `MetricProjection` 七类投影；文件名与内容的对应偏弱（`IntervalCounter_test` + `MetricProjection_test` 同文件） |
| 8 | `fprobe/src/collect/IntervalCounter.cj` | .cj | ✅ | 发现 #11（仅测试引用）；差分语义（回绕按 0、时间不前进返回 None）与注释一致 |
| 9 | `fprobe/src/collect/JsonData.cj` | .cj | ✅ | 发现 #12；`adapt` 懒包装（对象/数组按需递归），`DataParsable` 静态方法为接口实现 |
| 10 | `fprobe/src/collect/MetricProjection.cj` | .cj | ✅ | 优化方案 1；`Aggregation.aggregate` 空数组返回 None、`evaluate` 的失败收敛与注释一致 |
| 11 | `fprobe/src/collect/ProbeFactory.cj` | .cj | ✅ | 6 个核心 kind + 3 个条件 kind + 无条件 `topology`（空配置下 `kinds()` 为 7，测试 `:76` 与此一致）；`registerIfAbsent` 启动期单线程，无竞态 |
| 12 | `fprobe/src/collect/ProbeFactory_test.cj` | .cj | ✅ | 覆盖注册/幂等/条件项/实例化；`conditionalKindsFollowConfiguration` 对 `topology` 的断言是恒真（该 kind 无条件注册），断言力度弱于测试名 |
| 13 | `fprobe/src/collect/ProbeRunner.cj` | .cj | ✅ | 发现 #8 #9（double publish 见 `AgentRuntime.cj:89/94`）；`slots` 仅采集线程写，`store` 有锁，线程封闭成立 |
| 14 | `fprobe/src/collect/ProbeRunner_test.cj` | .cj | ✅ | 覆盖失败保留旧值/恢复/预热基线/只读快照/编码往返；未覆盖"HOST 回退"的生产路径（见 #8） |
| 15 | `fprobe/src/collect/ProbeSnapshotBuilder.cj` | .cj | ✅ | 发现 #8；`encode` 往返等价有 `:143-149` 用例；`agentData` 仅测试引用 |
| 16 | `fprobe/src/collect/health/HealthMetrics.cj` | .cj | ✅ | 发现 #4 #7；11 字段与 `f_health/src/HealthData.cj:24-74` 一一对应 |
| 17 | `fprobe/src/collect/health/HttpProbe.cj` | .cj | ✅ | 发现 #5 #6；`TimeoutException` 与普通错误分开标记，`finally` 关连接 |
| 18 | `fprobe/src/collect/health/MvcHealthProbe.cj` | .cj | ✅ | 发现 #4；空 URL/超时/非 2xx/非法 JSON 四条分支与注释一致（除"对象即合法"这一条） |
| 19 | `fprobe/src/collect/health/MvcHealthProbe_test.cj` | .cj | ✅ | 覆盖正常映射/非 200/超时/非法 JSON/空 URL；缺"合法 JSON 但非 HealthData"（#4） |
| 20 | `fprobe/src/collect/health/RpcHealthProbe.cj` | .cj | ✅ | 发现 #7；逐目标 try/catch 隔离失败，目标串行（优化方案 2 的组成部分） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 发现 #2（回复饥饿）、#3（顺序契约）、#4（全 0 健康数据）、#13（未释放资源）；分层正常（`channel` 只依赖 `f_email`/`f_probe`/`f_data`，`collect` 不反向依赖 `runtime`）；HTML 侧 `escapeHtml`（`EmailAlarmChannel.cj:182-188`）覆盖 `& < > "`，告警文本进 HTML 前已转义，无注入；`Sql`/命令拼接不在本部分 |
| §1 死代码 | 2 | 机械核对过本部分全部 `private`/`internal` 符号：`subjectOf`/`renderHtml`/`fileName`/`mediaType`/`escapeHtml`（`EmailAlarmChannel.cj` 内互调）、`adapt`/`JsonObjectData`/`JsonArrayData`/`JsonArrayDataIterator`（`adapt` 与迭代器互引）、`healthJson`、`registerIfAbsent`、`collectValues`、`elapsedMs`、`ProbeSlot`（`ProbeRunner.cj:41/50` 使用）均有调用者；`DataParsable.parse/tryParse` 为接口实现不判。仅测试引用两项按可见性建议处理：`IntervalCounter`（发现 #11）、`ProbeSnapshotBuilder.agentData`（发现 #8）。`import` 逐个核对，无未使用导入 |
| §2 重复逻辑 | 5 | 发现 #6（耗时换算 ×3 + 文案 ×2）、#7（11 字段 ×3 + DTO→JsonObject ×2）、#8（host 回退/编码 ×2）、#9（发布职责 ×2）、#10（标题解析 ×2）；同文件内两两比对了 `EmailAlarmChannel` 的 5 个私有函数、`HealthMetrics`/`HealthSample` 的构造块、`MetricProjection.collectValues`，差异均为语义差异（错误文案、可空性） |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`（`grep` 空）、无 `throw UnsupportedException`；`catch (_: Exception)` 均有返回值或日志（`jsonToData`→None、`tryParse`→None、`collectValues`→空数组）属注释声明的降级语义；`HealthSample.init(){}`/`ChannelMessage.init(){}` 是 `@DataAssist` 生成所需 |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`adapt` 每次只包一层（深层走 `get`/迭代器，不递归整棵树），`jsonToData` 的解析深度由 `f_data` 的 `JsonValue.fromStr` 决定（远端 HTTP 响应），不在本部分；`renderHtml`/`subjectOf` 都是单层循环 |
| §5 OOM | 1 | 发现 #5（`readEntire` 无上限，量级 = 带宽 × 2s）。其余容器有界：`slots`（探针数）、`readings`（目标数）、`rows`（消息行数）、`specs`（附件数）、`list(20)` |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`evaluate` 重复解析、串行 tick、IMAP 逐封取信都只作线索，已进「优化方案（无基线）」与「待验证假设」表 1-3 行，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`SnapshotStore` 的锁在 `snapshot/ProbeSnapshot.cj:135-152`（范围外），临界区只做引用交换；发现 #1 是"缺少同步"而非"锁太大" |
| §6.3 并发串行 | 0 | `RpcHealthProbe` 逐目标串行、`ProbeRunner` 逐探针串行属结构性串行，但无测量数据，按 §6.3 要求放进优化方案 2 与待验证假设表第 2 行，不计缺陷 |
| §6.4 低效算法 | 0 | `subjectOf` 的 `split` 与 `renderHtml` 的 `indexOf(':')` 都是 O(行长)，消息行数为个位数；`Aggregation` 的 4 个分支均为单趟 O(n)；无嵌套循环匹配 |
| §7 降堆内存方案 | 1 | 优化方案 3（IMAP 逐封正文 → 摘要+按需正文），证据状态「无基线」 |
| §8 降 CPU 方案 | 2 | 优化方案 1（TUI 每格重解析）、2（串行 tick），均「无基线」 |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内释放"的大对象：`HealthSample`/`RpcHealthTarget` 经 `toData()` 变成 `JsonObject` 返回给 `ProbeAgent.data`，`OutgoingMail` 交给 transport，`renderHtml` 的字符串进 `OutgoingMail` —— 全部逃逸；且无改前/改后峰值内存对照，收益不可证 |
| §11 现有代码的 BUG（存量） | 7 | 发现 #1（并发竞争）、#2（回复饥饿）、#3（顺序契约）、#4（全 0 健康数据）、#5（无上限读响应体）、#12（`parse` 返回类型不符）、#13（未释放 `Email` 会话 / 媒体类型承诺） |
| §12 并发安全与锁粒度 | 1 | 发现 #1（`Email` 跨 4 条线程，给出线程路径与被共享字段）；`ProbeRunner` 的 `slots` 经核对为采集线程封闭（`AgentRuntime.cj:92-97` 单线程 tick，发布走 `SnapshotStore` 的锁），未判问题；`MetricProjection`/`Aggregation` 是只读值对象 |
| §13 文档一致性 | 0 | 本部分不含 `.md`（20 个文件全为 `.cj`）；`.cj` 内的接口注释与实现不一致已按 §11 报（#3 `list` 顺序、#13 媒体类型、#4 "非法响应"） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`，README 覆盖由其它部分核对。`probe_channel_email_receiveLimit` 未接线的承诺源在 part1（`doc/configuration.md:66`），源码落点 `EmailAlarmChannel.cj:35-41` 在本部分——已在跨部分提示里指明与 part1 #1 合并，不重复计数 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 3 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分的生产代码（邮件渠道 + 采集装配 + 健康探针 + 指标投影）整体结构清楚：渠道与传输用接口隔开、探针装配集中在 `ProbeFactory`、快照编码只有一个入口，失败都收敛成 `error` 字段而不是抛给调用方，注释也基本能对上实现。问题集中在两处：

1. **阻塞项是发现 #1**——同一个 `Email` 被拉取线程、回复线程、异步分析线程、报告线程同时使用，而 `f_email` 明确是"有会话状态、无锁"的对象。这是默认装配下就会命中的数据竞争，后果是告警邮件串包/错发，必须先加串行化再谈其它。
2. **第二梯队是发现 #2 + #3**——`receive()` 取窗口内第一封未读且永不推进，POP3 下 flags 恒空、IMAP 下 `BODY.PEEK` 永不打 `\Seen`，于是第一封回复之后渠道就"卡住"了，而消费方按 id 去重让这个卡住完全静默。修法不大（返回游标或标记已读），但要先把 `list` 的顺序契约写清，否则改了还是错方向。

其余是防御性与一致性问题：#4 的"任意 JSON 对象都当全 0 健康数据"会把对端异常包装成"健康但为零"，#5 的无上限读响应体是 OOM 面；#6-#13 是重复实现、双层发布、仅测试引用的工具类与未释放会话资源，可排期。性能方面本轮没有任何基线，`evaluate` 的重复解析、串行 tick、逐封取正文都只能留在优化方案与待验证假设里，不进修复清单。

跨部分提示（供合并去重，不计入本部分统计）：(a) part1 #1 的 `probe_channel_email_receiveLimit` 未接线，源码侧落点是 `EmailAlarmChannel.cj:35-41`，合并时与 part1 归一条；(b) part2 #9 已报 `AlarmEvent.format` ↔ `renderHtml` 的字段表重复与 `title.startsWith("【已恢复】")` 判恢复，本部分 #10 只补 `subjectOf` ↔ `renderHtml` 这一处，三处应合成一条；(c) `SupervisorRuntime.cj:142` 在拉取线程内同步做 `dispatch`（含 SMTP）会把一次网络超时带进 tick——与发现 #1 同源但属性能面，已并入待验证假设表第 2 行。

存量合计 13 条（严重 2 / 一般 3 / 轻微 8），是否纳入修复待用户决定。
