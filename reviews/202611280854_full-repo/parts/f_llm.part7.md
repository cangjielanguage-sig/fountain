# f_llm 模块审查报告（第 7/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 13 个 `.cj` + 7 个 `.md`；模块整体 368 个 `.cj` + 112 个 `.md`）
- **本部分范围**：`doc/spec/**`（`perf-retrieval-candidates`、`refactor-retrieval-scoring` 两个已完成变更）、`doc/todo.md`、`src/agents/**`、`src/balance/**`、`src/channel/Channel{Bootstrap,Bootstrap_test,Contract,Functions}.cj`
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支）→ 本部分全部问题来源均为**存量**
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全
- **报告版本**：v1 分报告（第 7/25 部分；同一部分本轮重跑结果，模块报告由主 Agent 合并生成）

## 发现

### [严重][存量] AgentTask 构造器用 `producingEvents` 的长度索引 `acceptableEvents`：越界崩溃 + `nextEvent` 枚举内容错

- **位置**：`f_llm/src/agents/AgentTask.cj:82-84`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界越界 / 语义与命名不符）+ §1（读了不用的正常字段）
- **证据**：静态确定 —— `for(i in 0 .. agent.producingEvents.size)` 的上界来自 `producings` 列，循环体却取 `agent.acceptableEvents[i]`；两列是 `agents` 表里独立的 `acceptable` / `producings` 字段（`f_llm/src/model/po/Agent.cj:32-35,47-56`、`f_llm/tables-pg.sql:39-40`），没有等长约束
- **描述**：`producingEventJsons` 的语义是「本智能体能产出的下游事件」，最终作为工具参数 `nextEvent` 的 `enum` 注入（`AgentTask.cj:394-398`）。现在装的是「本智能体接受的事件」：
  1. `producings` 比 `acceptable` 长（或 `acceptable` 为 `NULL`/空串——`''.split(',')` 只得到 1 个空元素）时，构造 `AgentTask` 直接 `IndexOutOfBoundsException`，属于装配期崩溃；
  2. 长度恰好相等时，枚举里仍是入参事件名，模型会被引导去选一个不会发生的下游事件。`src/agents` 下没有任何测试，这个错位不会被用例拦住。
- **建议**：改为直接遍历产出一侧（`for(e in agent.producingEvents){ list.add(JsonString(e)) }`）；在 `Agent` 上加一条 `producings` 非空校验，并补 `AgentTask` 构造用例覆盖 `acceptable.size != producings.size`。

### [严重][存量] 余额查询关闭 TLS 校验：Bearer API Key 与云账单 AK/SK 可被中间人截获或篡改

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:41-43`（`verifyMode = CertificateVerifyMode.TrustAll`）、`:76-80`（`defaultBalanceGet` → `f_llm/src/util/http.cj:20,25-27` 同一 TrustAll）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（安全性：敏感数据）+ §11（契约与实现不符）
- **证据**：静态确定 —— 两条余额取数路径都显式把 `CertificateVerifyMode` 设为 `TrustAll`；官方文档明确 `TrustAll` 表示「本端不作对对端证书的校验……一般仅在开发测试阶段使用」（`cangjie_stdx-main-doc/doc/libs_stdx/net/tls/common/tls_common_package_api/tls_common_package_enums.md:20-22`）
- **描述**：`defaultBalanceGet` 发的是 `Authorization: Bearer <DeepSeek API Key>`（`util/http.cj:20`），`defaultPost` 发的是腾讯/火山签名头（`Authorization=...Credential=<AK>/...`）。TLS 校验关闭后，同网段攻击者可自签证书完成 MITM，直接读走明文密钥，或篡改余额响应使告警与预算判断失真。`doc/todo.md` §3 只登记了「HTTP 建连超时缺失」，没有说明为什么必须 TrustAll，看起来是绕证书问题的临时手段被固化成了默认值。
- **建议**：默认改回 `CertificateVerifyMode.Default`；自签/代理场景用配置项（如 `llm_balanceInsecureTls`）显式打开并限制在余额路径；`util/http.cj` 的同名问题属其它部分，需一并处理。

### [一般][存量] 余额响应按「结构一定正确」解析：金额解析失败静默变 `0.00`，结构不符时抛裸异常

- **位置**：`f_llm/src/balance/BalanceUnits.cj:41-47`（`catch(_){ 0.0f64 }`）；`f_llm/src/balance/BalanceQueriers.cj:86-90`（`asBool().value`）、`:91-113`（`asArray()` 与 `balance_infos` 缺失返回空列表）、`:148-155`（`Response`/`Error` 直接 `asObject()`）、`:212-221`（同上）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理静默 / 外部输入未校验）+ §3（`catch` 吞异常）
- **证据**：静态确定 —— `BalanceUnits.parse` 吞掉 `Float64.parse` 失败；`Option.value` 在 `None` 时抛 `NoneValueException`（`core_package_enums.md:400-406`），`asArray()`/`asObject()` 在类型不符时抛 `JsonException`（`f_data/src/json/JsonValue.cj:70-75`）
- **描述**：接口注释明写「查不到就是抛异常，不得返回 0 或空快照——余额为 0 与查不到是两件事」（`BalanceQuerier.cj:64-69`），实现却有两条反向路径：
  1. 金额是 `"abc"`、字段缺失、`balance_infos` 缺失时得到 `total="0.00" / totalValue=0.0`，`mark()` 再把 `low` 置真（`BalanceQuerier.cj:135-145`）——「接口坏了」被报成「余额为零」，`queryAll` 也不会记 warn；
  2. `is_available` 不是 bool、`balance_infos` 不是数组、`Response` 不是对象时，抛的是未包装的 `NoneValueException`/`JsonException`，调用方拿不到「哪个平台、什么字段」的上下文。
- **建议**：`parse` 改返回 `?Float64` 或抛 `BalanceUnsupportedException`；`parse*` 在必需字段缺失/类型不符时抛带平台与字段名的异常，并对 `balance_infos` 缺失显式报错而不是返回空列表；「金额为 0」与「金额不可读」用 `available`/错误字段区分。

### [一般][存量] `BalanceMediator.ensureLoaded` 吞掉 bean 扫描异常并置 `loaded=true`：一次瞬时失败永久禁用全部余额查询

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:147-161`（`catch(e){ log.warn }` 后无条件 `loaded = true`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞异常）+ §11（失败路径当成功）
- **证据**：静态确定 —— `loaded = true` 在 `catch` 之后、`synchronized` 块内无条件执行；`lookupList<BalanceQuerier>()` 初始化失败后注册表保持空
- **描述**：`lookupList` 只要抛一次（bean 构造失败、依赖未就绪），注册表就永远为空且不再重扫，之后每次 `query()` 都报 `balance query is not supported for provider: X, available: []`，把「启动态瞬时故障」固化成「该平台不支持余额」。本仓其它装配代码也承认「库/凭据比应用晚就绪是常态」（`ChannelBootstrap.cj:39`）。
- **建议**：只在扫描成功时置 `loaded = true`；失败保留 `false` 并按时间退避重试，或把异常直接抛给调用方，不要降级成「不支持」。

### [一般][存量] `ensureLoaded` 的自动发现绕过「同名注册直接失败」约定：重复 provider 静默覆盖

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:75`（注释承诺）、`:153-155`（`queriers[querier.provider] = querier`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ `fountain-baseline.md §4`（同名注册启动直接失败，不做隐式优先级）
- **证据**：静态确定 —— `register()` 在 `:90-92` 检查重复并抛 `IllegalArgumentException`，`ensureLoaded()` 的 bean 扫描分支直接 `put`，没有 `contains` 检查
- **描述**：两个 `@Bean` 实现声明同一个 `provider`（例如两个类都返回 `"deepseek"`）时，谁生效取决于 `lookupList` 的遍历顺序，后者静默覆盖前者；显式 `register` 同名反而会失败。与项目基线要求的「启动直接失败」相反，出问题时只能靠行为差异猜。
- **建议**：把插入收敛到一个 `insertOrThrow(querier)` 私有方法，两条注册路径共用；同名时抛带两个实现类名的异常。

### [一般][存量] `ensureLoaded` 在锁内执行 `lookupList`（bean 实例化），临界区长度不可控

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:148-155`；调用侧 `:87-95`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.2 / §12.2（临界区里做 I/O、构造等可能阻塞的动作）
- **证据**：静态确定（锁内调用 `lookupList`）+ 待确认（是否真有 bean 在构造期回调 `register`）。`lookupList` 会实例化所有 `BalanceQuerier` bean；`std.sync.Mutex` 在仓颉 1.3 是**可重入**的（`sync_package_classes.md:8919-8930`），因此重入不会死锁，但会在 `loaded` 仍为 `false` 时再次进入 `lookupList`
- **描述**：临界区里跑的是「例化全部下游实现 + 写 HashMap」，单次持有时长取决于各实现构造开销（读配置、建连）。若某个 bean 构造期调用 `BalanceMediator.instance.register(...)`，会重入 `ensureLoaded` 并再次扫描；`register` 本身也会先 `ensureLoaded`（`:88`），形成重复扫描与部分初始化状态可见。
- **建议**：锁外先 `lookupList` 到局部列表，锁内只做 `if(!loaded){ 批量 put; loaded = true }`；`register` 在 `loaded=true` 后不再触发扫描。

### [一般][存量] `BalanceMediator.names()` 无锁遍历被 `register()` 加锁修改的 `HashMap`

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:97-104`（读侧）对比 `:87-95`（写侧）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（迭代与修改并发）
- **证据**：待确认 —— `for((name, _) in queriers)` 完全在 `synchronized` 之外，`register`/`ensureLoaded` 的写入都在锁内；仓内没有运行期 `register` 调用（仅测试），触发面取决于下游是否在运行期注册
- **描述**：`names()` 是 public，且被 `query()` 的失败信息调用（`:114`）。一旦有线程 `register()` 扩容 `HashMap`，遍历线程会读到不一致的内部状态。同模块 `ChannelMediator.platforms()` 把遍历放在锁内（`ChannelMediator.cj:99-108`），写法不一致。
- **建议**：遍历整体进锁，或先拷一份名字数组再排序返回（与 `ChannelMediator.providerPlatforms()` 同构）。

### [一般][存量] `accessLLM` 重试预算默认为「无限」，退避 sleep 不校验剩余预算

- **位置**：`f_llm/src/agents/AgentTask.cj:414-453`（`:424` 循环条件、`:432-440` 斐波那契退避）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（异步/超时语义）+ §11（边界）
- **证据**：静态确定 —— `maxCount` / `maxElapsed` 默认 `Int64.Max`（`f_llm/src/config/LLMConfig.cj:245-250`）；`elapsed` 只在 `catch` 里更新，`sleep(sleepDuration)` 前不比较剩余时长
- **描述**：（1）默认配置下「次数 + 总时长」双无限，持续失败会长期占住调用线程；（2）退避 1/1/2/3/5/8… 秒无上限，第 20 次失败会 sleep 上千秒，即使 `maxElapsed` 只剩 1 秒也照睡满整个窗口；（3）`finally` 固定打 `count + 1`，成功与失败的 tried 语义混在一起。注：与 `parts/f_llm.part1.md`、`parts/f_llm.part2.md` 对同文件的记录同源，合并时去重。
- **建议**：`sleep` 取 `min(backoff, 剩余预算)`，预算不足直接抛；退避加封顶；在 README 配置表写明默认值；`resp` 改用 `?LLMResp` 替代 `unsafeZeroValue`（`:423`）。

### [一般][存量] Token 用量落库失败会让整次智能体事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:456-457`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失）+ §10（次要副作用失败应降级）
- **证据**：静态确定 —— `saveTokenUsage` 是裸 DAO 插入、无 try/catch（`f_llm/src/store/postgres/TokenUsageSaver.cj:33-38`，MySQL 同构），调用点也不在 try 内
- **描述**：LLM 已成功、工具已执行，只因用量表插入失败（库不可用、表缺失、唯一键冲突）就抛出，调用方拿不到 `DataEvent`，整轮对话作废。`DummyTokenUsageSaver` 的存在说明这条链路允许空实现，统计本身不是强一致数据。
- **建议**：包 try/catch 并 `log.warn`（或异步 fire-and-forget），失败只计入指标；不要阻断业务事件。

### [一般][存量] 模型给的工具参数 JSON 在 `try` 之外解析：一次坏参数就让整个事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:473-476`（`JsonValue.fromStr(arguments).asObject()` 在 `:477` 的 `try` 之前）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 外部输入未校验）
- **证据**：静态确定 —— `fromStr` / `asObject` / `json.add` 三条语句都在 `try{ let fnResult = FunctionMediator.call(...) }` 之前；`fromStr` 对非法 JSON、`asObject` 对数组/标量都抛 `JsonException`（`f_data/src/json/JsonValue.cj:70-75,156-179`）
- **描述**：工具参数由模型生成，截断、少引号、对象写成字符串都是常态。现在这种本可恢复的工具错误会直接抛出 `exec`；而同文件对 `FunctionMediator.call` 的失败已有「回写错误 ToolMessage 让模型自我修正」的处理（`:501-504`），两段语义不一致。
- **建议**：把 `fromStr`/`asObject` 一起纳入 `try`，失败时 `addToolMsg('工具参数不是合法 JSON: ...')` 并继续下一个 tool call；同时校验 `function.name` 非空。

### [一般][存量] 技能里出现未注册的函数名时，`getDefinitions` 直接抛异常，整次事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:411`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失）+ §14.1（接线缺失/半成品）
- **证据**：静态确定 —— `FunctionMediator.getMeta` 未命中时 `throw FunctionNotFoundException(function)`（`f_llm/src/tool/FunctionMediator.cj:125-131`），`AgentTask` 对 `getDefinitions` 没有 try/降级
- **描述**：`functionNames` 来自技能定义（DB 运行期数据）。技能里留一个已下线/拼错的函数名（或对应模块没进 workspace）时，整个 `exec` 在调用 LLM 之前就抛异常，表现为「智能体彻底不响应」，而不是「少了一个工具」。
- **建议**：逐个 `try` 取定义，缺失函数名 `log.warn` 后跳过，并把缺失项回灌到提示词或事件数据；或在装配技能时预校验。

### [一般][存量] 通道装配报告被丢弃：README 承诺「单条非法只跳过并 warn」，实现没有 warn

- **位置**：`f_llm/src/channel/ChannelBootstrap.cj:76-79`；生产调用点 `f_llm/src/loom/LoomWiring.cj:119`；承诺源 `f_llm/README.md:790` / `f_llm/README_en.md:781`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）+ §3（静默吞错误）
- **证据**：静态确定 —— `ChannelBootstrap` 全文没有 `log.*`；唯一生产调用方把返回值赋给 `_`；`ChannelInstallReport.errors` 无人读取，`summary()` 也不含 `errors`（`:31-33`）
- **描述**：`llm_channels` 配错（缺 `smtpHost`、端口越界、平台未实现）时只静默少一个账号：无日志、无指标，之后 `channelSend` 报「channel not found」。中英文 README 都明确写「skipped with a warning / 跳过并 warn」。
- **建议**：`install()` 在 `catch` 里直接 `log.warn`（带 platform/account，不带 password），或让调用方消费报告并在 `errors.size > 0` 时 warn；`summary()` 补 `errors.size`。

### [一般][存量] `channelInbox` 的 `limit` 无上限，由模型参数直接透传到 IMAP 拉取

- **位置**：`f_llm/src/channel/ChannelFunctions.cj:118-126`（只把 `<=0` 归一到 10）；透传路径 `ChannelMediator.receive` → `f_llm/src/channel/EmailChannel.cj:258-260`（`transport.receive(limit)` 原样使用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信长度处理 / 无拒绝路径）
- **证据**：静态确定 —— `ChannelInboxParam.limit` 默认 10（同文件 `:61-62`），`call` 只判 `> 0`，下游 `receive` 无 clamp
- **描述**：`limit` 是模型可写的工具入参，`limit=100000` 会驱动一次巨量 IMAP FETCH，把邮件头/正文全量物化进 `ArrayList<InboundMessage>`，又长又贵的网络往返也会占满工具调用超时预算。这同时是 §5 的「无拒绝路径」和 §6.4 的输入放大。
- **建议**：在 `ChannelInboxFunction` 里设上限（如 `min(max(limit,1), 50)`），越界裁剪并回写提示；`EmailChannel.receive` 亦应自带 clamp 守住接口契约。

### [一般][存量] `AgentEventData` 被整对象塞回 `data`：多跳后 `ToData` 负载丢失，模板占位符不再替换

- **位置**：`f_llm/src/agents/AgentTask.cj:350`（`eData = any`）、`:379`（`eData = agentData`）、`:458`（`data: eData`）；消费点 `:354`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）+ §10（正确性）
- **证据**：静态确定（类型链）+ 待确认（是否存在 ≥3 跳的 Agent 链）。`AgentEventData` 没有实现 `ToData`（`AgentEventData.cj:18`），而下一跳只认 `let Some(any: ToData) <- agentData.data`（`:354`）
- **描述**：第 1 跳（事件 data 是 `SimpleDataObject`）把 `ToData` 存进 `eventData.data`，第 2 跳能取到并替换模板；但第 2 跳结束时 `eData = agentData`，于是 `eventData.data = Some(AgentEventData)`。第 3 跳再进 `:354` 时类型不匹配，落入 `assembleNoParamPrompts`，`{{...}}` 保持原样——负载在第二跳之后丢失。`AgentTask` 头注释（`:47-48`）明确要求把 `e.data` 转成 `SimpleDataObject` 做模板参数，嵌套包装与该约定冲突。
- **建议**：转发时保留原始负载：`eData = agentData.data ?? (agentData as Any)`，或给 `AgentEventData` 实现 `ToData` 并把 `data` 透传；补一条 3 跳链的用例断言第 3 跳仍能替换占位符。

### [轻微][存量] 三处非 public 符号全项目零引用（死代码）

- **位置**：`f_llm/src/agents/AgentEventData.cj:19`（`var skillIds = HashSet<String>()`）、`f_llm/src/balance/BalanceQuerier.cj:164-166`（`func LLMConfig_balanceLowThreshold()`）、`f_llm/src/balance/BalanceQueriers.cj:271-273`（`func numberOf(obj:key:)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（非 public 无调用者）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`）搜索 `skillIds`、`LLMConfig_balanceLowThreshold`、`numberOf(` 只有定义处命中；三者都不带 `public`，`AgentEventData` 也没有 `@DataAssist` 反射入口
- **描述**：`skillIds` 是被私有 `skillReferences` 取代后遗留的可变字段；`LLMConfig_balanceLowThreshold` 与 `mark()` 里 `Float64(LLMConfig.getBalanceLowThreshold())`（`BalanceQuerier.cj:136`）是同一换算的第二份拷贝；`numberOf` 是 `BalanceUnits.parse(balanceTextOf(...))` 的无人使用封装。
- **建议**：删除三处；需要测试入口时改为私有 helper，让测试走公开路径。

### [轻微][存量] `AgentEvent` 四个公开构造函数逐字相同，只差参数类型；`(data as Any).getOrThrow()` 恒成功

- **位置**：`f_llm/src/agents/AgentEvent.cj:23-38`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名的重复）+ §10（可读性）
- **证据**：静态确定 —— 四个 `public init` 的构造体都是 `this(..., data: (data as Any).getOrThrow(), ...)`；参数静态类型本身就是目标类型，`as Any` 不可能返回 `None`
- **描述**：重载本身必要（仓颉无隐式上转），但每个构造都带一次「看起来会失败、实际不会失败」的断言，读者需要额外确认；真正的契约（`TaskEvent.data` 是 `Any`）反而没有注释。
- **建议**：保留重载，去掉 `as Any` 直接传 `data`，并加一行注释说明 `TaskEvent.data` 统一存 `Any`。

### [轻微][存量] `AgentTask` 三个惰性字段无同步：`tokenUsageSaverLookuped` 可能先于赋值可见

- **位置**：`f_llm/src/agents/AgentTask.cj:102-113`、`:114-125`、`:126-138`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（惰性初始化 / 可见性）
- **证据**：待确认 —— 缺「`AgentTask` 实例是否被多线程共用」的证据；字段是普通 `var`（非原子、非 volatile）
- **描述**：`skillsFinder_`/`orgFinder_` 重复 lookup 只损失启动开销，可接受；`tokenUsageSaverLookuped` 是「标志位 + 值」的发布问题：另一线程可能先看到 `true`、后看到旧值，从而长期拿 `DummyTokenUsageSaver`，用量统计静默丢失且无日志。
- **建议**：改用单一 `?TokenUsageSaver` 字段（与上面两个 prop 写法统一），或在 `exec` 入口解析一次后作为局部变量传递（`exec` 每事件一次，天然线程封闭）。

### [轻微][存量] `genSkillDetails` 两分支是同一段模板的复制；无引用时也照打「技能引用列表」标题

- **位置**：`f_llm/src/agents/AgentTask.cj:149-170`、`:241-251`、`:258-259`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流的重复）+ §10（可维护性）
- **证据**：静态确定 —— 两分支模板逐行相同，仅是否经过 `populatePromptsParams` 不同；`assembleSkillReference` 在 `references.size == 0` 时直接返回，但调用方已先追加 `'#### 技能引用列表\n'`
- **描述**：提示词模板是行为契约，改一处漏一处风险实打实；空引用时提示词里会留一个悬空小标题，模型可能误判「引用列表丢了」。
- **建议**：先算出 `title`/`details` 两个字符串再走一次模板；把「技能引用列表」标题的追加挪进 `assembleSkillReference`，有引用才写。

### [轻微][存量] 三个余额解析函数是三份同构的「取字段 → 换算 → 构造快照」

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:83-115`（DeepSeek）、`:147-179`（腾讯）、`:212-244`（火山）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 三段都是「`json.get` 取 N 个金额字段 → `BalanceUnits.toYuan` → 填 13 个同名字段 → `ArrayList.add`」，差异只有字段名、单位、错误结构；`queriedAt: DateTime.now().toString()` 也各写一遍
- **描述**：`BalanceSnapshot` 以后加字段要改三处，容易漏；单位/错误结构差异需要显式保留，不能简单合并掉。
- **建议**：抽一个私有 `snapshotOf(fields, unit, provider, account, raw)` 构造器，三个 `parse*` 只负责取字段与校验错误结构；`balanceTextOf` 与 `ChannelBootstrap.strOf` 的 `JsonNull`/非字符串语义差异要写进注释。

### [轻微][存量] `channelInbox` 失败时返回对象、成功时返回数组，同一工具两种结果形状

- **位置**：`f_llm/src/channel/ChannelFunctions.cj:127-130`（失败对象）对比 `:133-156`（成功数组）；描述 `:114`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ §10（可读性）
- **证据**：静态确定 —— `description` 声明「返回 JSON 数组」，失败分支返回 `{"ok":false,"error":...}`，与 `channelSend` 的 `{ok:...}` 也不统一
- **描述**：模型侧要写两种解析路径，容易把失败对象当数组处理。
- **建议**：统一为 `{"ok":bool,"messages":[...],"error":""}`，同步更新 `description`。

### [轻微][存量] 空响应/被截断时不报错，产出 `name=''` 的事件

- **位置**：`f_llm/src/agents/AgentTask.cj:459-512`（`eventName` 默认 `''`，只在 tool call 分支赋值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空集合未处理 / 失败路径当成功）
- **证据**：静态确定 —— `resp.messages` 为空或只有非 `ToolCallMessage`/`AssistantMessage` 时，仍构造并返回 `DataEvent`；`LLMResp.finishReason`（`f_llm/src/llm/LLMResp.cj:24-29`）在本流程从未被读取
- **描述**：`length` 截断、内容过滤拦空、上游空 choices 三种情况都会产出「没有内容但事件名为空串」的下游事件，排障只能靠猜。
- **建议**：`eventName.isEmpty()` 且没有 assistant 文本时抛明确异常或在事件数据里写 `finishReason`；`finishReason == 'length'` 记 warn。

### [轻微][存量] `ChannelInstallReport.summary()` 不含 `errors`，装配报告的主要信息读不到

- **位置**：`f_llm/src/channel/ChannelBootstrap.cj:31-33`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可维护性/可观测）
- **证据**：静态确定 —— `summary()` 只拼 `installed` / `skipped`；`errors` 需要调用方自行遍历，而唯一生产调用方根本不看报告（`LoomWiring.cj:119`）
- **描述**：跳过几条、为什么跳过是装配期最需要的信息。
- **建议**：`summary()` 追加 `errors=${errors.size}`，新增 `errorDetails(limit)` 供日志截断输出。

### [轻微][存量] README 写 `llm_balanceLowThreshold` 默认「无」，代码默认 `100`

- **位置**：文档 `f_llm/README.md:787`、`f_llm/README_en.md:778`；代码 `f_llm/src/config/LLMConfig.cj:199-204`；判定 `f_llm/src/balance/BalanceQuerier.cj:136`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（配置默认值与源码不符）
- **证据**：静态确定 —— README 默认列写「无 / none」，`getBalanceLowThreshold()` 返回 `Config.getValue<Int64>(...) ?? 100`
- **描述**：按 README 理解「不配就没有告警」，实际不配时所有 < 100 的余额都会被标 `low` 并打 warn。README 属本模块其它部分范围，此处因涉及本部分阈值判定一并记录，合并时归到 README 的 §13。
- **建议**：README 默认值改 `100`，或代码默认改为「不告警」并同步注释。

### [轻微][存量] 余额查询失败也抛 `BalanceUnsupportedException`，与「平台未实现」混为一类

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:150-155`（腾讯 `Error`）、`:214-221`（火山 `Error`）；异常定义 `f_llm/src/balance/BalanceQuerier.cj:57-62`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名 / 注释不符）
- **证据**：静态确定 —— `BalanceUnsupportedException` 的注释是「平台没有可用的余额查询实现」，但两个 `parse*` 在上游返回 `Error`（鉴权失败、限流）时也抛它
- **描述**：调用方无法区分「该平台不支持」与「本次查询失败」；现在 `queryAll` 用 `catch(e: Exception)` 兜住，暂时无行为差异，但任何按类型分支的上层都会误判。
- **建议**：新增 `BalanceQueryFailedException`（或复用 `LLMException`）表达上游错误，`Unsupported` 只留给未实现平台。

### [轻微][存量] 腾讯/火山请求 URL 与签名器各写一份 host/action/version，存在漂移风险

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:142`（腾讯 host）与 `f_llm/src/balance/sign/Signers.cj:109`；`BalanceQueriers.cj:204-206`（火山 action/version）与 `Signers.cj:150-155`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 火山 URL 里手写 `Action=QueryBalanceAcct&Version=2022-01-01`，同时又把同样两个字面量作为参数传给 `VolcSigner.headers`；腾讯 host 在 URL 与签名器的 `canonicalHeaders` 各写一次
- **描述**：改版本号或 host 时只改一处，签名就会对不上（表现为 403，而不是编译错误），排障成本高。
- **建议**：把 host/action/version 提成 `Signers` 或 `BalanceQueriers` 的常量，URL 与签名串都从同一组常量拼。

### [轻微][存量] 多币种余额共用一个无单位阈值

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:135-145`；阈值来源 `f_llm/src/config/LLMConfig.cj:199-204`；多币种用例 `f_llm/src/balance/Balance_test.cj:25-32`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（注释与实现不符 / 契约）
- **证据**：静态确定 —— `LLMConfig` 注释写「与余额同币种口径」，但 `getBalanceLowThreshold()` 只返回一个 `Int64`，`mark()` 直接拿 `snapshot.totalValue < threshold`，不读 `snapshot.currency`
- **描述**：DeepSeek 同时返回 CNY 与 USD 时，100 的阈值会按同一数值套到 USD 上（90 USD 被标 low，110 USD 反而正常）；多平台汇总时也无法按币种配置。
- **建议**：阈值改为按币种配置（`llm_balanceLowThreshold_<currency>` 或 JSON map），缺省回落到一个基准币种并显式换算/标注。

### [轻微][存量] `perf-retrieval-candidates` 的「默认 400 条候选」只落实到带 embedder 的构造

- **位置**：文档 `f_llm/doc/spec/perf-retrieval-candidates/specs/loom-flow/spec.md:15-18`、`tasks.md:9`；代码 `f_llm/src/store/mysql/KnowledgeStore.cj:41,45`（1000）与 `:55`（400），`f_llm/src/store/postgres/KnowledgeStore.cj:40,44` 同构；可达路径 `f_llm/src/store/mysql/ContentStore.cj:50`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：待确认 —— 无 embedder 的 `MySqlKnowledgeStore()` 仍用 `maxCandidates=1000`，而 `ContentStore` 在 `model == None` 时正走这个构造；spec 的 Scenario 写「默认参数 → 最多 400」
- **描述**：若「默认参数」指无 embedder 的词面路径，则 spec 的验收口径与实现不一致；这类部署仍会拉 1000 条候选，与本次性能变更的目标相反。
- **建议**：确认无 embedder 路径是否是生产默认；是则把 1000 也降到 400，或把 spec 措辞限定为「带 embedder 的默认参数」。

## 优化可行性方案

> 下列不是缺陷。**本部分没有改前基线数据**，全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [CPU] `ChannelInboxFunction.render` 用 `+=` 逐段拼 JSON

- **现状**：`f_llm/src/channel/ChannelFunctions.cj:133-156`，双层循环里对 `text` 连续 `+=`（每条消息 6 次、每个附件 3 次），`String` 不可变 ⇒ 每轮复制已拼内容；输入规模 = `limit` 条 × 附件数
- **方案**：改用 `StringGenerator`（同模块 `AgentTask` 已在用），或直接 `JsonArray`/`JsonObject` 组装后 `toString()`
- **预期**：拼接成本从 O(total²) 降到 O(total)；`limit` 越大收益越明显（默认 10 条时可忽略）
- **代价**：无（输出字节需逐字符比对，转义继续走 `JsonString`）
- **验证**：`cjpm bench -O2` 对 `render` 做 1/10/100 条消息 × 0/5 附件的时间对照，取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `populatePromptsParams` 每次调用都重新编译同一段 `TextTemplate`

- **现状**：`f_llm/src/agents/AgentTask.cj:230-236` 在每次事件、每个技能上调用 `TextTemplate.compile(...)`；`skill.details` 是 DB 里的稳定文本，同一技能在多轮对话中被反复编译
- **方案**：按模板串内容做小容量 LRU（上限几十条），或把编译结果挂到技能只读视图
- **预期**：省掉每轮 N 次模板解析（N = 主技能数 + 辅助技能数）；端到端占比未测
- **代价**：多一份缓存；用内容 hash 作键可在技能更新后自然失效
- **验证**：`cjprof record` 跑「5 主技能 + 10 辅助技能」的事件，看 `TextTemplate.compile` self time；改后同场景对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `BalanceSnapshot.raw` 在多币种/多平台结果里重复持有整段响应

- **现状**：`f_llm/src/balance/BalanceQueriers.cj:110,176,241` 每条快照都保存完整 `body`；DeepSeek 多币种时同一 body 被复制 N 份（N=币种数），`queryAll` 汇总多平台后再叠加；生命周期到快照被丢弃为止
- **方案**：把 `raw` 提到「一次查询的结果」层（一个 body + 多个快照），或改成 `?String` 仅在排障开关打开时保存
- **预期**：单次查询 raw 占用从 N×body 降到 1×body（N=2 时 raw 部分约减半，整体占比很小）
- **代价**：排障需要改调用方式；`BalanceSnapshot` 构造参数变化
- **验证**：同响应跑 100 次查询，比较 `getAllocatedHeapSize()` 与峰值 `getUsedHeapSize()`；确认 raw 字段访问路径只有测试/排障
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `render` 的 `+=` 拼接在 `limit` 较大时成为工具调用耗时主项 | `f_llm/src/channel/ChannelFunctions.cj:133-156` | 单次 render 耗时随条数的曲线 | `cjpm bench -O2` 跑 10/100/1000 条消息，记录中位数与离散度 |
| 2 | `TextTemplate.compile` 在每事件重复编译上占可观 CPU | `f_llm/src/agents/AgentTask.cj:230-236` | 自耗时占比、每事件编译次数 | `cjprof record` 跑「15 技能 × 10 轮对话」 |
| 3 | `ensureLoaded` 锁内 bean 实例化的单次持有时长偏大 | `f_llm/src/balance/BalanceQuerier.cj:148-155` | 首次查询延迟、锁等待时长 | 计时 `lookupList` + 线程状态采样（BLOCKED） |
| 4 | 提示词组装（`genPromptsTemplate` + `genSkillDetails`）是每事件峰值内存的主要来源，local mode 可降峰值 | `f_llm/src/agents/AgentTask.cj:139-337` | 峰值 `getUsedHeapSize()` / RSS 对照 | 同输入跑改前改后，取峰值与 `getAllocatedHeapSize()`；注意 local region 不计入前者 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/doc/spec/perf-retrieval-candidates/specs/loom-flow/spec.md` | .md | 是 | 「默认 400 条」与无 embedder 构造的 1000 存在口径差，见轻微问题 |
| 2 | `f_llm/doc/spec/perf-retrieval-candidates/tasks.md` | .md | 是 | 5 条任务均带验证口径；2.1 的「默认 1000→400」只覆盖部分构造 |
| 3 | `f_llm/doc/spec/refactor-retrieval-scoring/design.md` | .md | 是 | D1-D3 与 `RetrievalScoring` 现状一致（类/常量/函数均 public） |
| 4 | `f_llm/doc/spec/refactor-retrieval-scoring/proposal.md` | .md | 是 | 4 处同构描述与代码对应，打分数值未变 |
| 5 | `f_llm/doc/spec/refactor-retrieval-scoring/specs/loom-flow/spec.md` | .md | 是 | 公式与 `RetrievalScoring` 一致（0.7/0.3、0.4/0.6、0.1/5.0） |
| 6 | `f_llm/doc/spec/refactor-retrieval-scoring/tasks.md` | .md | 是 | 2.2 声称补记忆设计文档 → `doc/f_llm-memory-design.md:337` 确有该句 |
| 7 | `f_llm/doc/todo.md` | .md | 是 | 与实现一致：三平台占位、`listByKind` 未下推均能在代码中找到对应；`known-limitations.md` §7 相符 |
| 8 | `f_llm/src/agents/AgentEvent.cj` | .cj | 是 | 4 个构造重复，见轻微问题 |
| 9 | `f_llm/src/agents/AgentEventData.cj` | .cj | 是 | `skillIds` 死字段，已并入 §1 |
| 10 | `f_llm/src/agents/AgentTask.cj` | .cj | 是 | 主要问题集中处：构造越界、负载嵌套、重试、用量落库、工具参数解析、惰性字段 |
| 11 | `f_llm/src/agents/imports.cj` | .cj | 是 | `internal import` 是包级可见（`cj_syntax.md:71`），不是死文件；所需符号均有使用 |
| 12 | `f_llm/src/balance/BalanceQuerier.cj` | .cj | 是 | 并发/降级/重复注册/锁粒度、死函数 |
| 13 | `f_llm/src/balance/BalanceQueriers.cj` | .cj | 是 | TrustAll、解析静默 0、三份同构、占位实现、死函数、URL/签名重复 |
| 14 | `f_llm/src/balance/BalanceUnits.cj` | .cj | 是 | `parse` 吞异常是根因；`format`/`floorDiv` 取整逐例核对（含负数），无缺陷 |
| 15 | `f_llm/src/balance/Balance_test.cj` | .cj | 是 | 覆盖解析/签名/阈值；未覆盖字段缺失、非数字金额、TLS 配置，故上述缺陷未被拦住 |
| 16 | `f_llm/src/balance/sign/Signers.cj` | .cj | 是 | TC3/V4 规范串逐行核对（含 canonicalHeaders 尾换行、UTC 日期换算），未发现签名算法缺陷 |
| 17 | `f_llm/src/channel/ChannelBootstrap.cj` | .cj | 是 | 报告丢弃、`summary()` 缺 errors、缺少 log |
| 18 | `f_llm/src/channel/ChannelBootstrap_test.cj` | .cj | 是 | 覆盖非法 JSON/缺字段/端口越界/starttls，未覆盖多账号空 account 的装配失败路径 |
| 19 | `f_llm/src/channel/ChannelContract.cj` | .cj | 是 | 接口与 DTO 定义，无逻辑；`OutboundAttachment.filename` 回落整条路径属信息性，未列为问题 |
| 20 | `f_llm/src/channel/ChannelFunctions.cj` | .cj | 是 | limit 无上限、失败结构不一致、render 拼接 |

合计：`.cj` 13 个 / `.md` 7 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 27 | 本部分全部发现（严重 2 / 一般 12 / 轻微 13），逐条判据见上；安全性 1 条、设计 3 条、可读性 3 条，其余以正确性为主 |
| §1 死代码 | 1 | 逐个检查了本部分全部非 public 符号（`private`/默认 `internal` 顶层与成员），并对 `public` 成员按对外可达性判定；3 个符号全仓零引用，合并为 1 条；`internal import` 属包级可见，不算死文件 |
| §2 重复逻辑 | 4 | 同文件函数体两两比对（AgentEvent 4 构造、genSkillDetails 2 分支、3 个 parse*、URL/签名常量）并对相同错误文案/字面量跨文件搜索；其余函数输入-输出-副作用不同，未合并 |
| §3 空实现 | 0 | 无空函数体/空 `catch`；三平台 `query()` 抛 `BalanceUnsupportedException` 属已登记占位（`doc/todo.md` §1、`known-limitations.md` §7），有明确异常与注释，不计缺陷；`catch` 均为记日志或转报告 |
| §4 栈溢出 | 0 | 本部分无递归函数（`SignUtil`/`parse*`/`AgentTask` 均为迭代）；`JsonValue.fromStr` 的递归属标准库/其它模块，不在本部分范围 |
| §5 OOM | 1 | `channelInbox` 的 `limit` 无上限（按不可信长度物化）；`llm_channels` JSON 由管理员配置且体量小，未计 |
| §6.1 热点瓶颈 | 0 | 未提供本部分任何 profile / bench 数据，热点不成立，已全部放入「待验证假设」 |
| §6.2 大粒度锁 | 1 | `ensureLoaded` 锁内做 bean 实例化；已核对 `Mutex` 可重入，不按死锁计 |
| §6.3 并发串行 | 0 | 本部分没有 `spawn`/`Future.get`，`queryAll` 是设计上的串行聚合，非并发串行 |
| §6.4 低效算法 | 0 | `render` 的 `+=` 与 `msgs × skills` 双层扫描规模受 `limit`/技能数约束，作为优化项而非缺陷；无证据表明已成瓶颈 |
| §7 降堆内存方案 | 1 | `BalanceSnapshot.raw` 重复持有整段响应；无基线，标待验证 |
| §8 降 CPU 方案 | 2 | `render` 拼接、`TextTemplate.compile` 重复编译；均无基线 |
| §9 local mode 可行性 | 0 | 提示词组装的临时对象会作为 `messages` 逃逸到 `LLMResp`/事件数据，收益只能用峰值内存证明；无数据，仅列入待验证假设 #4 |
| §11 现有代码的 BUG（存量） | 27 | 本部分全部发现均为存量（快照模式无 diff）；边界、空值、错误处理、资源、并发、契约逐类核对 |
| §12 并发安全与锁粒度 | 3 | `names()` 无锁遍历、`ensureLoaded` 锁粒度、`AgentTask` 惰性字段发布；`BalanceMediator` 的 `loaded` 仅在锁内读写，无问题 |
| §14 功能完备性与 README 覆盖 | 1 | `llm_channels` 承诺 warn 但实现无 warn（同时是 §13）；README 的逐符号成员表不在本部分文件清单，未重复统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；§13 命中 3 条（README 阈值默认值、channels warn、400/1000 候选口径） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 12 |
| 轻微 | 13 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

> 存量缺陷共 27 条（严重 2 / 一般 12 / 轻微 13），是否纳入修复待用户决定；本部分不代为拍板。

## 总评

本部分代码整体结构清晰：余额查询把「单位换算」「签名」「HTTP 注入点」分开，通道层用中介者隔离平台，`imports.cj` 的包级导入也符合仓颉语义。阻塞项有两处：`AgentTask` 构造器的列错位会在装配期直接崩溃且把 `nextEvent` 枚举指错，属于必须先修的正确性问题；余额查询的 `TrustAll` 把 API Key/AK-SK 暴露在 MitM 面前，属于安全问题而非风格问题。

其余风险集中在「异常输入的处理纪律」：余额解析把不可读金额静默成 0、工具参数 JSON 在 `try` 之外解析、技能函数名缺失直接抛、用量落库失败拖垮整轮事件——都是「次要步骤失败被当成主流程失败」或反之。并发面上 `BalanceMediator` 的懒加载与 `names()` 读路径不均衡，`Mutex` 虽可重入不锁死，但锁内做 bean 扫描仍会放大首查延迟并带来重入扫描。

文档方面，两个已完成变更的 spec 与实现基本一致，只有「400 条候选」在无 embedder 路径仍是 1000 这一处口径差需要确认；README 的 `llm_channels` warn 承诺与 `llm_balanceLowThreshold` 默认值都与实现不符。性能类结论本部分没有任何基线数据，全部只作为待验证假设与无基线优化项，未写成缺陷。
