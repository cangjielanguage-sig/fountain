# fprobe 模块审查报告（模块第 6/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（本部分 20 个文件：`src/llm/*` 14 个 + `src/main.cj` + `src/report/*` 5 个）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部记「存量」
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑；本部分实际落在 LLM 建议链路（解析/提示词/调用/回复去重）与报告生成链路上
- **报告版本**：分部分报告 v1（`parts/fprobe.part6.md`，由主 Agent 合并进 `fprobe_v2.md`）

## 发现

### [一般][存量] `truncate` 用字节下标截断，非 ASCII 回复必抛 `IllegalArgumentException`，整轮轮询中断

- **位置**：`fprobe/src/llm/ReplyMonitor.cj:128-134`（调用点 `:63`）
- **来源**：存量（快照模式无基线可比；文件自 16.4 任务引入，未改动）
- **判据**：review-checklist §11（边界 / 越界）+ 仓颉 `String` 语义文档
- **证据**：静态确定 —— `String` 的 `size`、下标、切片均按 UTF-8 **字节**计；`operator func [](Range<Int64>)` 明确「起止点必须位于字符边界上，否则抛出 `IllegalArgumentException`」（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:9383`，异常条目见 `:9403`）。`raw[0..120]` 的右端点 120 由常量写死，与字符边界无关。
- **描述**：非法回复日志路径 `logWarning('渠道 ${name} 收到非法回复: ${truncate(raw)}')` 在 `pollOnce` 的渠道循环里、且不在任何 `try` 内。只要某条非 JSON 回复的前 120 字节末落在某个多字节字符（中文/emoji）中间，`truncate` 抛异常 → 本轮 `for ((name, channel) in channels)` 直接中断，后续渠道本轮不再轮询；异常由 `SupervisorRuntime.llmLoop` 的 `catch (e: Exception)`（`SupervisorRuntime.cj:239-245`）吞成一条「回复轮询失败」。该消息也走不到 `store.markHandled`，若渠道不标已读（设计文档 `doc/spec/add-fprobe/design.md:605` 明确提到 IMAP 可能重复投递），每轮都会再次命中同一条坏消息，形成「每轮都失败一次」的稳定退化。
- **建议**：按字符边界截断，例如 `if (raw.size > 120) { let runes = raw.toRuneArray(); String(Array<Rune>(min(120, runes.size)) {i => runes[i]}) + "..." }`；或退化为按 `\u{FFFD}` 安全替换（`String.fromUtf8` 前用 `String.checkUtf8Encoding` 校验）。同时把 `truncate` 调用挪进渠道级 `try`，使单条坏消息不影响其余渠道。

### [一般][存量] `PromptBuilder.build` 无规模上限：全节点 × 22 指标 × 20 历史点一次性拼进单个提示词

- **位置**：`fprobe/src/llm/PromptBuilder.cj:30-106`（节点循环 `:39`，历史循环 `:93-103`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无界容器）+ §14.1（只处理部分输入规模的半成品）
- **证据**：静态确定（无任何上限判断）+ 需实测（触发规模取决于 `probe_nodes` 条数）
- **描述**：`build` 对 `states` 全量展开：每个节点先按 `ProjectionCatalog.all()`（22 个指标，`src/tui/RenderPlan.cj:66-115`）逐 agent 求值，再对 22 个指标各输出最多 `historyPoints`（生产写死 20，`SupervisorRuntime.cj:373`）个历史点。单节点约 22 行指标 + 22 行历史（每行 ≈150-200 字节）≈ 3.5 KB；1000 个节点即 ≈3.5 MB 提示词，远超常见上下文窗口与请求体上限，且按 token 计费会线性放大成本。`PromptBuilder` 是 `public` API，`states` 由调用方任意传入，内部没有任何长度/条数上限，也没有截断或摘要策略，失败只表现为上游 4xx 或截断，而不是本地拒绝。
- **建议**：在 `build` 内加两级上限：节点数上限（如 50，超出按告警相关度/状态取前 N）与字符预算（如 32 KB，超出停止追加并写「…已省略 N 个节点」）；`historyPoints` 由 `probe_historyPoints` 或新配置项派生，而不是硬编码 20。上限值写常量或配置，超限走「省略」而不是抛异常。

### [一般][存量] 每条告警 `spawn` 一次完整 LLM 分析，无 single-flight / 并发上限，告警风暴会放大成 N×R 次全量提示词请求

- **位置**：`fprobe/src/llm/ProbeAdvisor.cj:77-82`（`analyzeAlarm`）、`:92-107`（`analyze`）
- **来源**：存量
- **判据**：review-checklist §12.1（有界性 / 异步语义）+ §6.3（并发串行与并行度上限）
- **证据**：静态确定（`ProbeAdvisor` 无在途标记、无队列、无去重；调用方每事件一个 `spawn`）
- **描述**：`SupervisorRuntime.cj:143-146` 对**每个** `AlarmEvent` 执行 `spawn {=> advisor.analyzeAlarm(event, stateStore.all(), historyStore)}`，`ProbeAdvisor` 侧没有任何「已在分析中则跳过/合并」的逻辑，也没有并发度限制。一次 `alarm.evaluate(states)` 若命中 N 个节点 × R 条规则，即刻产生 N×R 个并发 `analyze`，每个都调用上一节的 `PromptBuilder.build`（全量节点 × 22 指标）并各自发一次 HTTP。后果是：上游 429/超时（每条错误只记一条 ERROR，用户看到的是「建议变少」而非「被限流」）、瞬时线程与内存放大、token 成本按 N×R 倍增长。`LlmTrigger.ALARM` 是本模块默认触发方式（`SupervisorRuntime.cj:354` 默认 `"alarm"`），该路径是主路径。
- **建议**：在 `ProbeAdvisor` 内加单飞标记（`AtomicBool.compareAndSwap`，分析中直接 return 并记一次 INFO），或改为「事件入有界队列（容量 1-4）+ 单消费者」；如需保留多事件语义，把同批次事件合并成一次 `events` 数组传入（`analyzeInterval` 已支持 `events:` 参数）。补充并发压力用例：20 线程同时 `analyzeAlarm`，断言实际 `client.chat` 调用次数 ≤ 1。

### [一般][存量] 报告把「节点 × 22 指标」张 SVG 全量物化后再整串复制一次，无图表上限

- **位置**：`fprobe/src/report/ReportBuilder.cj:97-133`（图表循环）、`:172-173`（`joinLines` + `toArray()`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无界容器）、§7（去副本）
- **证据**：静态确定（无图表数量/总字节上限，全部驻留 `html` 数组后一次拼成 `String`，再 `toArray()` 复制一份同尺寸字节数组）；单张 SVG 尺寸需实测
- **描述**：`build` 对每个 `state` 遍历 22 个投影，凡有历史就渲染一张内联 SVG 并追加进 `html`（`Array<ChartSpec>` 与 `String` 同时存活）。节点数 N 时图表数 = 22×N，且没有任何上限或抽样；随后 `joinLines(html, "")` 以 `+=` 逐行拼接（O(total²) 前缀复制），最后 `htmlText.toArray().size` 为了打印字节数又把整份 HTML 复制成一个 `Array<Byte>`。按 100 节点、每张 SVG 3 KB 估算，正文 ≈6.6 MB，峰值同时存在「各行字符串 + 拼接中间串 + 完整 HTML + 完整字节副本」四份形态。
- **建议**：改为 `StringBuilder` 单次构造（消除 O(n²) 与中间串），日志改用 `htmlText.size`（`String.size` 即 UTF-8 字节数，`core_package_structs.md` prop size）；对图表数/总字节设上限（如每节点最多 6 张、正文 ≤8 MB），超出退化为纯文本行并记一条 WARN。若必须全量，考虑把图表分页或改为可下载附件（当前 `ReportJob.runOnce` 明确 `attachments: []`）。

### [轻微][存量] `stripFence` 只认首行围栏，模型带前导说明时结构化建议整体丢失

- **位置**：`fprobe/src/llm/AdviceParser.cj:50-65`
- **来源**：存量
- **判据**：review-checklist §11（语义与承诺不符 / 边界未覆盖）、§14.1（只处理部分输入）
- **证据**：静态确定 —— 只有 `lines[0].trimAscii().startsWith("```")` 才剥离；`"以下是分析：\n```json\n{...}\n```"` 这类输出直接走 `JsonValue.fromStr` 失败分支
- **描述**：失败后按类注释的既定契约把整段原文当 `summary` 返回（`AdviceParser.cj:47`），因此不会崩溃，但 `solutions` 为空 → `ActionWhitelist` 无动作可执行、`formatAdvice` 只发出一大段含 Markdown 围栏的原文。提示词已要求「只输出 JSON」，但模型不遵守时的退化路径比预期窄（剥围栏只覆盖严格格式）。
- **建议**：改为在整段文本里找第一个 ` ``` ` 与最后一个 ` ``` `（`indexOf` / `lastIndexOf`），取其间内容；或在解析失败时再尝试「截取第一个 `{` 到最后一个 `}`」作为二次兜底。补一条用例：前导说明 + 围栏 + JSON。

### [轻微][存量] 拓扑渲染成功的分支里 `case None => text.add("拓扑不可用")` 逻辑不可达

- **位置**：`fprobe/src/report/ReportBuilder.cj:158-169`（`:164`）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `topologySvg` 只在 `match (topology) { case Some(sample) => ... }` 分支里被赋成 `Some`（`:145-157`），故进入 `case Some(svg)` 时 `topology` 必为 `Some`，内层 `case None` 永不执行
- **描述**：死分支，且它与外层 `case None`（`:166-168`）文案相同，读代码时容易误以为存在两种「拓扑不可用」来源。
- **建议**：把 `Some(sample)` 直接与外层 match 合并（`case Some(sample) => match (topologyRender(sample)) { ... }`），删掉内层对 `topology` 的二次匹配；或在 `Some(svg)` 分支用 `sample.devices.size` 时改为携带 `sample` 的元组。

### [轻微][存量] `parse` 只校验 `id` 非空，`from` 为空时仍向空地址回信

- **位置**：`fprobe/src/llm/ReplyMonitor.cj:107-126`（校验）、`:70-72`（回信）
- **来源**：存量
- **判据**：review-checklist §11（空值未处理）
- **证据**：静态确定 —— `ChannelMessage.from` 默认 `""`（`src/channel/ChannelMessage.cj:22`），`{"id":"x"}` 也能 `populate` 成功并通过 `message.id.isEmpty()` 检查
- **描述**：随后 `isAuthorized(conf, "")` 为 false，走未授权分支 `channel.send(UNAUTHORIZED_REPLY, [""])`，把空字符串当收件人交给渠道（邮件渠道可能抛异常并被 catch 成 WARN，也可能发给空地址失败）。同时该 `id` 被标记已处理，看不出异常。
- **建议**：`parse` 里同时要求 `id` 与 `from` 非空（`body` 允许为空），否则按「非法回复」记 WARN 并跳过，不进入授权/回信分支。

### [轻微][存量] `ChartSelector.SUPPORTED_TYPES` 是 public 可变数组，外部可改写全局类型表

- **位置**：`fprobe/src/report/ChartSelector.cj:27`
- **来源**：存量
- **判据**：review-checklist §10（封装 / 共享可变状态）
- **证据**：静态确定 —— `public static let SUPPORTED_TYPES = ["line", "area", "bar"]`，`let` 只禁止重新赋值，`Array` 元素仍可写
- **描述**：任何下游代码 `ChartSelector.SUPPORTED_TYPES[0] = "sankey"` 都会改变本进程内所有 `select` 的判定与 `supports` 的返回值，且无任何日志。README 把它列为公开常量（`fprobe/README.md:535`），却无法保证不变。
- **建议**：改为 `public static let SUPPORTED_TYPES: Array<String> = [...]` 的内部只读封装：私有数组 + `public static func supportedTypes(): Array<String>` 返回副本，`supports` 内部用私有数组。

### [轻微][存量] 测试替身 `FakeLlm.prompts` 只写不读

- **位置**：`fprobe/src/llm/LlmTestSupport_test.cj:29`（声明）、`:39`（`prompts.add`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）
- **证据**：静态确定 —— 全仓 `grep "\.prompts\b"` 在 `fprobe` 内零命中（唯一命中都在 `f_llm`/`f_mcp`，与 `FakeLlm` 无关），`prompts` 只被 `add` 追加、从未读取；每次 `chat` 都会多留一条提示词副本
- **描述**：注释写「记录每次提示词」，但没有任何用例断言提示词内容；属于写而不读的残留状态（同文件 `LlmFakeHistory` / `FakeReplyChannel` 的字段都有读取点，可排除误报）。
- **建议**：要么在 `PromptBuilder` 相关用例里断言 `prompts[0].contains(...)`（顺带替代 `PromptBuilder_test` 的重复断言），要么删除该字段。

### [轻微][存量] `analyze` 只把 `client.chat`/`onAdvice` 包进 `try`，`PromptBuilder.build` 的异常会逸出到无 `try` 的 `spawn`

- **位置**：`fprobe/src/llm/ProbeAdvisor.cj:92-107`（`:94` 在 `:95` 的 `try` 之外）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 与类注释契约不符）
- **证据**：待确认 —— 类注释承诺「模型异常/空响应只记录 ERROR，不影响调用方的拉取、告警与报告」，但提示词构造失败（`ProjectionCatalog`/`history.values`/`spawn` 内未捕获异常）不在该 `try` 内；仓颉 `spawn` 内未捕获异常的具体后果（线程静默结束还是打印）本轮未实测
- **描述**：`SupervisorRuntime.cj:145`/`:250` 的 `spawn` 内没有 `try`，`build` 抛出的异常不会被 `logError` 记录，失败原因不可见；好在每轮重新 `spawn`，不会永久停摆。
- **建议**：把 `PromptBuilder.build` 移入 `try`（错误文案改为「提示词构造失败」），或在 `spawn` 侧统一 `try/catch` 并 `logError`。

### [轻微][存量] 回复状态直接覆盖写文件，非原子落盘；每条消息全量重写一次

- **位置**：`fprobe/src/llm/ReplyStateStore.cj:96-112`（`persist`）、`:51-58`（`markHandled` 每次落盘）
- **来源**：存量
- **判据**：review-checklist §11（资源/持久化对称性）、§13 契约（类注释承诺「重启不重复」）
- **证据**：静态确定 —— `File.writeTo(path, array.toString().toArray())` 直接覆盖目标文件，没有临时文件 + rename
- **描述**：写入中途崩溃/断电会留下截断的 JSON，下次 `load` 走 `catch` 分支 `ids.clear()` 按空集合启动（`:81-87`），此前所有已处理 id 丢失 → 渠道重投的旧回复会被再执行一次（例如重复 mute、重复触发报告）。窗口很小（≤1000 条 id，约 20 KB），但后果是「已授权的动作重复执行」。
- **建议**：写 `path + ".tmp"` 后 rename 覆盖；`markHandled` 可改为「内存累加 + 定时/批量落盘」以减少整文件重写次数（回复频率低，此项优先级低于原子性）。

### [轻微][存量] 4 处语义相同的「分隔符拼接」循环重复实现

- **位置**：`fprobe/src/llm/AdviceParser.cj:67-78`（`join`）、`fprobe/src/llm/PromptBuilder.cj:119-130`（`joinNumbers`）、`fprobe/src/llm/PromptBuilder.cj:132-143`（`joinLines`）、`fprobe/src/report/ReportBuilder.cj:205-216`（`joinLines`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件 / 只改类型名）
- **证据**：静态确定 —— 四个函数体逐行对齐：`var result = ""; var first = true; for (x in xs) { if (!first) { result += sep }; result += x; first = false }`，差异只有集合类型（`ArrayList<String>` / `Array<Float64>`）与元素是否先 `toString()`
- **描述**：语义完全一致（首元素前不加分隔符、空集合得空串），但分散在两个包（`fprobe.llm` / `fprobe.report`）。std 已提供 `String.join(Array<String>, delimiter!)`（`core_package_structs.md:6454`）；同模块 `src/tui/FprobePainter.cj:314` 还有第 5 份（范围外提示）。这类实现漂移会表现为「某处改了分隔符规则，其余没改」。
- **建议**：`fprobe.llm` / `fprobe.report` 共用一份工具函数（放模块内 util，或直接用 `StringBuilder` + `String.join`），`joinNumbers` 保留但改为内部调用同一实现。注意差异点：`ReportBuilder` 传的分隔符是 `""`，`PromptBuilder` 是 `"\n"`/`", "`，参数化即可，不改变行为。

### [轻微][存量] 3 处「JSON 文本 → `DataObject.populate`」样板重复

- **位置**：`fprobe/src/llm/AdviceParser.cj:31-46`、`fprobe/src/llm/ReplyMonitor.cj:107-126`
- **来源**：存量
- **判据**：review-checklist §2（跨层复制 / 换控制流）
- **证据**：静态确定 —— 三处（含范围外的 `src/runtime/SupervisorRuntime.cj:330-338`）都是同一串：`JsonValue.fromStr` → 判 `case object: JsonObject` → `DataObject<T>.populate(object.toData())` → `case None` 兜底 + `catch Exception/Error`；本包已有 `jsonToData(text): ?Data`（`src/collect/JsonData.cj:28`）做前半段，但两处都绕过它直接调 `JsonValue`
- **描述**：同一套「容错解析」写了三遍，兜底策略已经出现漂移：`AdviceParser` 静默吞掉、`ReplyMonitor` 转成 `None` 让调用方写 WARN、`SupervisorRuntime` 转成 `continue` 不记日志。判据差异属于业务要求，但「解析 + 转 DTO」不需要各写一份。
- **建议**：在 `fprobe.collect` 补一个 `parseDataObject<T>(text: String): ?T`（内部复用 `jsonToData` + `DataObject.populate`），三处改为调用它并保留各自的兜底文案；`AdviceParser` 的「退回原文 summary」与 `ReplyMonitor` 的「记 WARN」作为调用方策略保留。

### [轻微][存量] 两份 HTML 转义表重复，转义字符集完全一致

- **位置**：`fprobe/src/report/ReportBuilder.cj:218-220`（`escape`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 与 `src/channel/EmailAlarmChannel.cj:182-188` 的 `escapeHtml` 转义序列相同（`&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&quot;`，顺序也一致），只是一处链式 `replace`、一处逐步赋值（后者为范围外文件，仅作证据）
- **描述**：报告正文与邮件正文各有一套转义，任一新增字符（如 `'`）时容易只改一处，导致两处输出不一致。
- **建议**：抽到模块内 `util`（如 `fprobe/channel/HtmlText.cj` 的 `escapeHtml`）供两处共用，并补一条「`'` 与 `&amp;` 双转义」的用例防回归。

### [轻微][存量] README 的 `ChartSpec` 条目漏掉 `fromValues`

- **位置**：`fprobe/src/report/ChartSpec.cj:75`（`public static func fromValues`）；承诺源 `fprobe/README.md:536`（条目只列 `jsonObject`）
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— `grep -n "fromValues" fprobe/README.md fprobe/README_en.md` 零命中；`ReportBuilder` 生成图表的唯一入口就是它（`ReportBuilder.cj:116`）
- **描述**：README「其他公开 API」是索引式清单，`ChartSpec` 只列了序列化方法，使用者按文档无法知道「如何从一组数值构造图表描述」，只能去读源码。
- **建议**：补 `fromValues`（func）到 `README.md:536` 与 `README_en.md` 对应条目；若要更完整，补一句参数含义（标签自动为 1..N）。

## 优化可行性方案

> 全部为「还能更好」，不进修复清单；均无改前/改后对照数据。

### [CPU] 用 `StringBuilder` / `String.join` 替换手写拼接

- **现状**：`PromptBuilder.joinLines` / `joinNumbers`、`ReportBuilder.joinLines`、`AdviceParser.join` 都是 `result += ...` 循环；报告场景单次拼接的 `html` 行数 ≈ 22×N，单行可达数 KB（内联 SVG），累计前缀复制量约 O(total²/2)
- **方案**：四处统一改为 `StringBuilder.append`（或 `String.join`），`ReportBuilder` 直接以 `StringBuilder` 累积正文
- **预期**：拼接阶段的临时字符串分配从 O(n²) 降到 O(n)，按 100 节点 / 6.6 MB 正文估算可省去数倍于正文的中间串拷贝（精确收益待测）
- **代价**：改动集中、行为不变；`String.join` 要求 `Array<String>`，`ArrayList` 需 `toArray()`，因此 `StringBuilder` 更合适
- **验证**：`cjpm bench -O2`，同一份 `NodeState[]`（100/1000 节点）跑 `ReportBuilder.build` 100 轮取中位数，同时记录 `getAllocatedHeapSize()` 增量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 提示词构造里按 agent 只解析一次 JSON

- **现状**：`PromptBuilder` 的 `for (spec in ProjectionCatalog.all()) { for (agent in snapshot.agents) { spec.projection.evaluate(agent.dataJson) } }`（`:49-67`）对每个 (指标 × agent) 组合各解析一次 JSON；`MetricProjection.evaluate` 内部走 `collectValues` → `jsonToData`（`src/collect/MetricProjection.cj:102-104`、`:107-124`），22 指标 × 约 6 个 agent ≈ 132 次解析/节点
- **方案**：每个 agent 解析一次为 `Data`，再对 22 个投影求值（`MetricProjection` 增加接收 `Data` 的重载，`evaluate(String)` 保留为薄封装）
- **预期**：解析次数 132 → 6（每节点），1000 节点单次提示词构造减少 ≈12.6 万次 JSON 解析（单次耗时需实测）
- **代价**：`MetricProjection` 需新增重载；需保证 `Data` 复用期间的只读语义（`DataPath.get` 不修改树）
- **验证**：`cjprof record` 对比 `PromptBuilder.build` 自耗时占比；输入 100 节点 × 22 指标 × 20 点
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 指标目录 `ProjectionCatalog.all()` 提到循环外

- **现状**：`ReportBuilder.build` 在**每个节点**循环内调用 `ProjectionCatalog.all()`（`ReportBuilder.cj:97`），而该函数每次都用嵌套循环 + 线性去重重建 22 条 `MetricSpec`（`src/tui/RenderPlan.cj:119-136`，O(n²) 且每次新分配），节点数 N 时重复 N 次；`PromptBuilder` 同样在节点循环内调用两次（`:49`、`:94`）
- **方案**：在建报告/提示词的作用域内只取一次（`let specs = ProjectionCatalog.all()`），或让 `ProjectionCatalog` 缓存为 `static let`
- **预期**：N 次重建降为 1 次；N=1000 时省去约 1000×(22² 次比较 + 22 个对象分配)
- **代价**：缓存需保证不可变（与上一条 `SUPPORTED_TYPES` 同类问题，建议只读快照）；`ProjectionCatalog` 属于 `fprobe.tui`，改动跨包但不改变分层
- **验证**：`cjprof record` 看 `RenderPlan.all` 的累计耗时占比；输入 1000 节点
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 报告字节数改用 `String.size`，去掉整份 HTML 的字节副本

- **现状**：`ReportBuilder.cj:173` 的 `htmlText.toArray().size` 把整份 HTML 复制成 `Array<Byte>` 只为取长度；报告正文规模 ≈ 22×N 张内联 SVG
- **方案**：改为 `htmlText.size`（`String` 的 `size` 即 UTF-8 字节长度，`core_package_structs.md` prop size）
- **预期**：省去一份与正文等大的临时数组（按 6.6 MB 正文估算，单次峰值降 ≈6.6 MB）
- **代价**：无，语义相同
- **验证**：`getUsedHeapSize()` 在 `build` 前后差值；100 节点固定输入跑 20 轮
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 回复去重集合换 `HashSet` + 环形队列

- **现状**：`ReplyStateStore` 用 `ArrayList<String>` 同时承担「查找」与「保持顺序」：`isHandled`/`markHandled` 各一次 O(n) `contains`，`trim` 用 `remove(at: 0)` 每次 O(n)（`ReplyStateStore.cj:42-58`、`:90-94`），n 上限 1000
- **方案**：`HashSet<String>` 判重 + 定长环形数组（或 `ArrayDeque`）维护淘汰顺序，`persist` 时按环形顺序序列化
- **预期**：单条消息处理从 O(1000) 降到 O(1)；1000 条稳态下每轮省 ~1000 次字符串比较（回复频率低，绝对值很小）
- **代价**：两处结构需保持一致（同一把「已处理」语义），`persist` 顺序语义不变；实现复杂度略升
- **验证**：`cjpm bench` 对 1000 条 `markHandled` 采样；真实场景观察 `pollOnce` 单轮耗时
- **证据状态**：`无基线（待验证，不进 tasks）`；按当前 30 s 轮询频率，收益大概率低于噪声，除非回复量级上升

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 报告生成是 supervisor 的 CPU 热点（22×N 张 SVG 渲染 + 拼接） | `fprobe/src/report/ReportBuilder.cj:97-133` | `build` 自耗时占比、单张 SVG 平均字节数 | `cjprof record` 跑 `ReportJob.runOnce`，输入 100/1000 节点、每指标 60 历史点 |
| 2 | 提示词构造中重复 JSON 解析占比可观（132 次/节点） | `fprobe/src/llm/PromptBuilder.cj:49-67` | `build` 自耗时、`jsonToData` 累计占比 | `cjprof record` 单次 `PromptBuilder.build`，1000 节点 |
| 3 | 报告正文规模已接近邮件/HTTP 体积上限 | `fprobe/src/report/ReportBuilder.cj:172-173` | 生产节点数与 `draft.html.size` 分布 | 在 `runOnce` 打点记录 `size`，跑一周 CRON |
| 4 | 告警风暴确实产生并发 LLM 请求峰值 | `fprobe/src/llm/ProbeAdvisor.cj:77-82` | 单轮 `analyzeAlarm` 实际并发数、上游 429 次数 | 在 `analyze` 入口计数（进入/退出）并统计 `client.chat` 失败码 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/llm/ActionWhitelist_test.cj` | .cj | ✅ | 用例覆盖 ack/mute/report/none、大小写与 trim、REJECT；断言 `601000` 与实现一致 |
| 2 | `fprobe/src/llm/AdviceParser.cj` | .cj | ✅ | 见 #5（围栏）、#13（JSON 样板）、#12（拼接重复） |
| 3 | `fprobe/src/llm/AdviceParser_test.cj` | .cj | ✅ | 4 条用例；缺「前导说明 + 围栏」与「单行围栏」用例（对应 #5） |
| 4 | `fprobe/src/llm/LlmAdvice.cj` | .cj | ✅ | 纯 DTO，`@DataAssist` + 双构造，无逻辑问题 |
| 5 | `fprobe/src/llm/LlmClient.cj` | .cj | ✅ | `chatByName(model, params)` 与 `LLMParams(model:)` 均传 model，冗余但无害；空 `messages` 返回 `""` 与 `ProbeAdvisor` 的空响应处理衔接 |
| 6 | `fprobe/src/llm/LlmTestSupport_test.cj` | .cj | ✅ | 见 #9（`prompts` 只写不读）；其余替身字段均有读取点 |
| 7 | `fprobe/src/llm/ProbeAdvisor.cj` | .cj | ✅ | 见 #3（并发无上限）、#10（build 在 try 外） |
| 8 | `fprobe/src/llm/ProbeAdvisor_test.cj` | .cj | ✅ | 6 条用例覆盖开关/触发/故障隔离，未覆盖并发（对应 #3） |
| 9 | `fprobe/src/llm/PromptBuilder.cj` | .cj | ✅ | 见 #2（无上限）、#12（拼接）、优化方案 2/3 |
| 10 | `fprobe/src/llm/PromptBuilder_test.cj` | .cj | ✅ | 2 条用例；只验证 contains，未验证规模上限（对应 #2） |
| 11 | `fprobe/src/llm/ReplyMonitor.cj` | .cj | ✅ | 见 #1（截断）、#7（from 未校验）、#13（JSON 样板） |
| 12 | `fprobe/src/llm/ReplyMonitor_test.cj` | .cj | ✅ | 4 条用例覆盖未授权/非法/去重/空箱；未覆盖含多字节字符的非法回复（对应 #1） |
| 13 | `fprobe/src/llm/ReplyStateStore.cj` | .cj | ✅ | 见 #11（非原子写）、优化方案 5（数据结构） |
| 14 | `fprobe/src/llm/ReplyStateStore_test.cj` | .cj | ✅ | 4 条用例覆盖重启/损坏/1000 上限/自动建目录；未覆盖写入中途截断（对应 #11） |
| 15 | `fprobe/src/main.cj` | .cj | ✅ | 分发参数前置、`--help`、`supervisor resident`、错误码 2/1 均与用例（`Main_test.cj`）一致；`dispatch`/`dispatchWith` 均有调用者 |
| 16 | `fprobe/src/report/ChartSelector.cj` | .cj | ✅ | 见 #8（公开可变常量）；`defaultType` 中 3 个显式 `"line"` 分支与兜底同值，属可读性冗余，不单列问题 |
| 17 | `fprobe/src/report/ChartSelector_test.cj` | .cj | ✅ | 4 条用例覆盖默认/自定义/回退/键名替换 |
| 18 | `fprobe/src/report/ChartSpec.cj` | .cj | ✅ | 见 #14（README 漏 `fromValues`）；`jsonObject` 改名 `type` 与 `@FieldAlias` 只作用于反序列化一致（`f_data/src/base/ObjectFields.cj:45-58`） |
| 19 | `fprobe/src/report/ChartSpec_test.cj` | .cj | ✅ | 3 条用例含真实 `SvgParser` 回读；未覆盖空 `values`（`fromValues` 无该边界用例） |
| 20 | `fprobe/src/report/ReportBuilder.cj` | .cj | ✅ | 见 #4（全量物化）、#6（死分支）、#12（拼接）、#15（转义重复） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。（本部分清单无 `.md`，README/doc 仅在核对 §13/§14 时按需引用，不计入本部分覆盖。）

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1/#7；设计 #3（副作用无隔离）；语言特性 #8（可变数组当常量）；安全性 0 —— 报告 HTML 对 `node`/`label`/`valueText`/`message` 均走 `escape`，SVG 内联依赖 `f_xml` 写出时的文本转义（`f_xml/src/XmlWriter.cj:436` → `Escaper.escapeText`），未发现未转义拼接 |
| §1 死代码 | 2 | 逐个 private/internal 符号搜引用：`stripFence`/`join`/`tail`/`joinNumbers`/`joinLines`/`isAuthorized`/`parse`/`truncate`/`load`/`trim`/`persist`/`inlineSvg`/`countAlarms`/`escape`/`configKey`/`defaultType`/`supports`/`wantsHelp`/`isResident`/`runAgent`/`runSupervisor`/`dispatch` 均有调用者；`dispatchWith` 仅 `Main_test` 引用（可见性建议，不算死代码）；命中 2 条为 #6（恒假分支）与 #9（只写不读字段）。`protected` 本部分无；`public` 成员所属顶层声明均为 `public`，按硬原则一不判死代码 |
| §2 重复逻辑 | 3 | 4 处拼接循环、3 处 JSON→DTO 样板、2 份 HTML 转义表（#12/#13/#15）；另比对过 `LlmAdvice`/`LlmSolution`、`ChartAxisSpec`/`ChartSeriesSpec` 的 DTO 样板（`@DataAssist` 生成，非重复逻辑）与两处 `catch (Exception)+catch (Error)` 成对捕获（仓颉 `Exception` 与 `Error` 互不继承，两分支都需要，不算重复） |
| §3 空实现 | 0 | `AdviceParser.cj:43-45` 的空 `catch` 有类注释与用例（`plainTextFallsBackToSummary`）承诺的兜底语义，非静默失效；`ProbeAdvisor` 的 `onAdvice: {_ => ()}` 是具名默认参数（测试专用），生产由 `SupervisorRuntime` 注入；本部分无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归：`stripFence`/`tail`/`join*`/`countAlarms`/`inlineSvg` 均为单层循环；`match` 无自引用结构，`LlmAdvice`↔`LlmSolution` 不互指 |
| §5 OOM | 2 | #2（提示词无规模上限）、#4（报告全量物化 + 字节副本）；`ReplyStateStore` 有 1000 条上限，`ReplyMonitor` 每轮只取一条，无累积 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`bench` 数据，热点未成立；候选写入「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁（`ProbeAdvisor`/`ReportBuilder`/`ChartSelector` 无可变字段，`ReplyStateStore` 无线程共享） |
| §6.3 并发串行 | 1 | #3：调用方逐事件 `spawn` 且 advisor 侧无合并/限流，实际并行度不受控（不是「串行」，是「无界并行」）；本部分内无 `spawn().get()` |
| §6.4 低效算法 | 3 | `remove(at:0)`+`contains`（优化方案 5）、22×agent 重复 JSON 解析（方案 2）、每节点重建指标目录（方案 3）；均无基线，只列方案 |
| §7 降堆内存方案 | 2 | 优化方案 4（`toArray` 副本）、5（去重集合结构）；#4 已作为缺陷记录规模风险，不重复计数 |
| §8 降 CPU 方案 | 3 | 优化方案 1（StringBuilder）、2（少解析 JSON）、3（少重建目录） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`ArrayList<String> lines/html`、SVG 中间串）最终作为 `String` 返回值逃逸（`ReportDraft`/`prompt`/`svg` 都返回给调用方），`ReportBuilder.build` 的产出还要跨线程发送；逃逸检查不通过，收益无法用峰值内存证明，故不立项 |
| §11 现有代码的 BUG（存量） | 3 | #1（字节切片抛异常）、#7（`from` 空值）、#11（非原子落盘）；另核对了 `ReportBuilder` 的 `stats[0..3]`（长度固定 4）、`values[size-1]`（有 `isEmpty` 前置）、`ChartSpec.jsonObject` 的 `type` 重复判断（有 `isNone` 守卫），均无越界 |
| §12 并发安全与锁粒度 | 1 | #3（有界性）。共享路径已逐一核对：`ProbeAdvisor` 字段全 `let`、`client` 无状态（`FLlmClient` 只持 `model`）；`ChartSelector`/`ChartRenderer`/`ReportBuilder` 无状态，可被报告线程与回复线程并发调用；`ReplyMonitor`/`ReplyStateStore` 仅由 `SupervisorRuntime.llmLoop` 单线程调用（`SupervisorRuntime.cj:237-246`），无第二访问者；`LlmTestSupport_test` 的可变状态只在单线程用例内使用 |
| §14 功能完备性与 README 覆盖 | 1 | #14（`ChartSpec.fromValues` 未进 README）；其余 public 符号逐个对照 `README.md:521-590` 均有条目（`ChartRenderer.render`、`ChartSelector.*`、`LlmTrigger.*`、`ProbeAdvisor.*`、`PromptBuilder.build`、`ReplyMonitor.*`、`ReplyStateStore.*`、`ReportBuilder.build`、`ReportDraft.*`、`AdviceParser.parse`） |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分清单不含 `.md`，§13 的文档一致性仅按需取证（`README.md:536`），完整文档核对归并到含 README 的部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量缺陷 15 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

本部分代码结构清晰、职责切分干净：`LlmClient` 端口化让用例可以完全脱离 `f_llm`，`ProbeAdvisor` 把「开关 / 触发 / 故障隔离」收敛在一处，`ChartSelector`/`ChartSpec`/`ChartRenderer` 三段式让报告用真实 SVG 而不必自己拼图，`ReplyStateStore` 的「损坏按空集合启动」也确实是可用的容错。没有发现崩溃级缺陷、数据损坏或死锁。

主要风险集中在**规模**而不是逻辑：`PromptBuilder` 与 `ReportBuilder` 都以「节点 × 22 指标」全量展开且无任何上限（#2/#4），`ProbeAdvisor` 又在每个告警事件上无界 `spawn`（#3）——三者叠加意味着「节点多 + 告警多」时内存、token 与上游配额会同时被放大，而失败表现是「建议变少 / 报告变慢」而不是明确报错，运维很难归因。建议把这四条（含 #1）排进最近的迭代：其中 #1 修法明确、成本极低，可立即做；#2/#4 需要定「上限值」，属于产品口径，建议由用户拍板后落地；#3 建议先加单飞标记，改动最小。

其余 11 条轻微项是健壮性与可维护性改进（截断边界、`from` 校验、原子落盘、四处拼接与两处转义的合并、README 补一条 API），可以排在功能迭代之后。所有性能类结论本轮都没有改前/改后数据，已按铁律只写入「优化可行性方案 / 待验证假设」，未进缺陷清单。
