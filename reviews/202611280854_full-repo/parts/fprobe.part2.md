# fprobe 模块审查报告（第 2/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（本部分 20 个文件：9 个 `.cj` + 11 个 `.md`；模块共 167 个文件，本部分为第 2 部分）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `f309f0b55`；`git log 120fd2542..HEAD -- fprobe/src fprobe/doc` 为空，即被审源码与文档自 `120fd2542` 起未变；`git status` 仅两份未跟踪报告目录）⇒ 全部问题来源记「存量」
- **审查重点**：fprobe 专项（采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑）；本部分实际覆盖**告警引擎 / 事件 / 规则 / 缺失数据追踪 / 渠道分发**及其文档
- **报告版本**：v1（分部分报告，由主 Agent 与其余 8 部分合并）

## 发现

### [严重][存量] `AlarmEngine.mute` 在 LLM 回复线程写 `mutedUntil`，`evaluate` 在拉取线程读同一 `HashMap`，无任何同步

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:46`（`private let mutedUntil = HashMap<String, Int64>()`）、`:62-70`（`mute` 做 `get` + `add` 写）、`:269-274`（`isMuted` 做 `get` 读）、`:230` / `:244`（`evaluate` 调用 `isMuted`）
- **来源**：存量（`git blame` → `f84982d31` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §12.1（共享可变状态无保护）、§6.2（跨线程写同一容器）
- **证据**：静态确定 —— 两条线程路径都已定位到具体行：
  - 拉取线程：`fprobe/src/runtime/SupervisorRuntime.cj:196` `spawn {=> poll.run()}` → `:158` `alarm.evaluate(states)` → `AlarmEngine.cj:269` `mutedUntil.get(rule)`；
  - LLM/回复线程：`SupervisorRuntime.cj:203` `spawn {=> llmLoop(...)}` → `:240` `replies.pollOnce()` → `ActionWhitelist.cj:85` `mute(rule, nowMs() + muteSeconds*1000)` → `SupervisorRuntime.cj:361` 绑定的 `alarm.mute(...)` → `AlarmEngine.cj:63/68` 对同一 `mutedUntil` 做 `get`+`add`；
  - 文档判据：`std/collection/collection_package_overview.md:27` —— "collection 包提供的集合类型都不支持并发安全"。
- **描述**：`mute` 由运维回复（`同意 mute cpu-high`）触发，`evaluate` 按 `probe_pollIntervalMs`（默认 5 秒）执行；两者对同一个 `HashMap` 并发读/写，没有任何 `Mutex`、不可变快照或消息传递。标准库明确声明该容器不支持并发安全，因此这里的正确性没有依据可循：轻则 `mute` 丢失（运维以为已静音却继续告警）、`isMuted` 读到脏值，重则在表扩容与读取交错时读到不一致结构。该竞态不在 CPU profile 里可见，也不是"理论上可能"——两条路径都是生产默认装配下的常驻线程。
- **建议**：只保护这一个不变量，任选其一：(a) 给 `mutedUntil` 配一把 `Mutex`，`mute`/`isMuted` 全部进出锁（临界区只有一次 map 操作）；(b) 改成不可变快照 + 原子替换（`mute` 复制 map 后 `AtomicReference` 交换，`isMuted` 只读快照）；(c) `ConcurrentHashMap`。修完补一条"回复线程 mute 与 evaluate 并发跑 1000 轮，断言静音生效"的压力用例。

### [一般][存量] 规则引用的 `kind` 缺失时，`MissingDataTracker` 每 tick 交替产生「已恢复」+「缺监控项」，去重完全失效

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:83-89`（`collectRecovered` 在规则评估**之前**执行）、`:91-95`（随后才跑 `evaluateRules`）、`:166-173`（`case None` 才把 `${node}|kind|${kind}` 写入 `currentMissing`）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §11（语义与契约不符）、§12.1（状态机跨 tick 不变量）；spec `fprobe/doc/spec/add-fprobe/specs/probe-supervisor/spec.md:96-113`（同类缺失只应告警一次）
- **证据**：静态确定 —— 推演两个 tick：
  - Tick N：`evaluateMissing`（`:98-149`）只登记 `expectKinds`、`agent.error`、节点离线三类键，不含"规则引用的 kind"；`collectRecovered` 无键可收；`evaluateRules` 的 `case None`（`:165-173`）写入键并 `raise` → 首发 `KIND_MISSING`，键进入 `active`。
  - Tick N+1：`collectRecovered`（`:83`）拿到的 `currentMissing` 仍不含该键（`probe_expectKinds` 为空或不含该 kind），而节点在 `batchNodes` 中 → 判为"已恢复"，发 `RECOVERY` 并 `active.remove`；紧接着 `evaluateRules` 再次 `raise` → 再发 `KIND_MISSING`。
- **描述**：触发条件是"规则里的 `kind` 在快照中不存在"（例如规则写了 `kind=rpc-health` 但该探针未启用，或扩展探针加载失败）。此后每个 tick 都发一条"已恢复"和一条"缺少监控项"，5 秒一封告警邮件，且恢复通知是假的。现有用例无法发现：`AlarmEngine_test.cj:221-233` 只测了 `probe_expectKinds` 路径，没有"规则 kind 缺失连续两 tick"的用例。
- **建议**：把 `collectRecovered` 移到规则评估之后（两阶段都填完 `currentMissing` 再统一结算），或在 `evaluateMissing` 里先把 `rules` 引用的 `kind` 也登记进 `currentMissing`；两条路径共用同一个 `key` 生成函数，避免再漂移。补用例：规则 kind 缺失连续 3 个 tick，断言事件数 == 1。

### [一般][存量] `probe_alarmCooldownSeconds` / `lastSentAt` / `cooldownElapsed` 实际恒真，冷却窗口从未生效

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:262-267`（`cooldownElapsed`）、`:230`（唯一调用点）、`:243`（恢复分支把 `lastSentAt` 清成 `None`）、`:231-232`（只在已发告警时写 `lastSentAt`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用的配置 / 恒真分支）、§11（配置与行为不符）；spec `probe-supervisor/spec.md:82-94`（冷却 300 秒内同一节点同一规则只发一次）与 `SupervisorRuntime.cj:446-455`（默认 300）
- **证据**：静态确定 —— 不变量推导：`lastSentAt` 只在 `state.firing = true` 的同一分支被赋值（`:231-232`），而唯一的清零点是 `else` 分支（`:241-243`，同时 `firing = false`）；因此"`lastSentAt` 有值 ⇒ `firing == true`"恒成立。调用点 `:230` 的前置条件正是 `!state.firing`，代入即 `lastSentAt == None`，`cooldownElapsed` 必然返回 `true`。
- **描述**：去重实际由 `firing` 闩锁完成（条件持续期间不再发），冷却参数没有任何影响。于是"恢复→再命中"的抖动场景（`firing` 被清、`lastSentAt` 被清）会在每个 tick 重新发告警，即使 `probe_alarmCooldownSeconds=300`。配置项与文档都在承诺一个不存在的抑制窗口，运维按文档调大冷却也不会有任何变化。
- **建议**：恢复分支保留 `lastSentAt`（只清 `firing`/`since`），发告警前用 `now - lastSentAt >= cooldownMs` 判定；若确认要"恢复后立即视为新告警"，就删掉 `cooldownMs`/`lastSentAt`/`cooldownElapsed` 与文档里的冷却承诺，二者取一。加用例：冷却 300s 内"命中→恢复→再命中"，断言只发 1 条 FIRING。

### [一般][存量] 规则的 `path` 启动期不校验，运行期 `DataPath.solid` 抛异常被吞 → 规则永久静默失效

- **位置**：`fprobe/src/alarm/AlarmRule.cj:167-169`（`validate` 只判 `path` 非空）、`fprobe/src/alarm/AlarmEngine.cj:192-210`（`DataPath.solid(rule.path)` 与取值整体包在 `try` 内，`catch (_: Exception) → None`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理静默）、§14.1（半成品：校验只做了一半）；spec `probe-supervisor/spec.md:77-80`（非法规则 MUST 启动失败并指出第几条）
- **证据**：静态确定 —— `f_data/src/path/DataPath.cj:70-81`：`solid()` → `doCompile()`，路径不以 `$`/`@` 开头直接 `throw DataException(...)`；`AlarmEngine` 的 `catch (_: Exception)` 把这个异常变成 `None`，随后 `:176-179` 的 `case None => ()` 什么也不做，连 WARN 都没有。
- **描述**：`probe_alarmRules` 里写 `"path":"usagePercent"`（漏 `$.`）或 `"$.a[0"`（括号不配对）都能通过启动校验；运行期每次评估都抛异常、被吞掉，规则永远不触发，日志里没有任何痕迹。对监控系统来说这等价于"规则悄悄消失"，且比启动失败更难发现。
- **建议**：`AlarmRule.validate` 里执行一次 `DataPath.solid(rule.path)`（或调用 `DataPath.cache` 预编译并缓存到规则对象），异常转成 `invalid(position, "path 无法解析: ...")`；`AlarmEngine.valueOf` 的 `catch` 至少记一条带规则名的 WARN（配合下面的 CPU 方案，预编译后该异常分支可直接删除）。

### [一般][存量] `AlarmEngine.emit` 把 `onEvent` 的所有异常（含 `Error`）静默吞掉，告警丢失无痕迹

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:276-284`
- **来源**：存量（同日 `docs/review/2026-11-28/fprobe.md` 已按抽样口径报过同一处，此处补全完整证据；两条请合并为一条）
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）、§11（失败当成功）
- **证据**：静态确定 —— 4 行空 catch，连 `Error` 一起吞；`emit` 是 `FIRING`/`RECOVERY`/`KIND_MISSING`/`PROBE_ERROR`/`NODE_UNREACHABLE` 全部事件的唯一出口（`:85/106/131/144/171/233/245`）。
- **描述**：`onEvent`（`SupervisorRuntime.cj:135-148`）里做事件入队、`dispatcher.dispatch`（含 SMTP 发送、日志）和 `spawn` 分析；其中任何一步抛异常，事件既没发出去、也没进队列，引擎继续跑，运维只能看到"没有告警"。`catch (_: Error)` 更糟：`OutOfMemoryError` 一类错误也被吞掉，进程带着坏状态继续。
- **建议**：`emit` 只包 `Exception`；`Error` 分支先 `eprintln` 一行带 `eventType`/`node`/`rule` 的记录再重新抛出（或至少不要静默继续）。再加一个"告警投递失败计数"供 TUI/report 展示。若吞异常是为了"单条事件不影响后续规则"，把 try 放进循环体并保留日志即可。

### [轻微][存量] `AlarmRule.parse` 的 `DataObject.populate` 会抛 `DataException`，绕过 `invalid(position, …)`，启动错误丢失"第 N 条"与 CONFIG 码

- **位置**：`fprobe/src/alarm/AlarmRule.cj:135-138`
- **来源**：存量
- **判据**：review-checklist §11（错误路径与契约不符）；spec `probe-supervisor/spec.md:77-80`（必须指出第几条）
- **证据**：静态确定 —— `f_data/src/base/DataObject.cj:119-130` 的 `set` 在字段不可转换时 `throw DataException("source field … connot be converted")`，`populate`（`:194-206`）不捕获；`AlarmRule.parse` 只在 `fromStr`（`:109-113`）与"非数组/非对象/缺字段"（`:115-138`）路径上转成 `ProbeException(CONFIG)`。
- **描述**：`"threshold":"high"` 或 `"forSeconds":{}` 这类类型错配会让 `load()` 抛出裸 `DataException`，最终由 `main.cj:136-141` 打成 `fprobe supervisor: 启动失败: source field threshold …`——不带规则序号、不带 `CONFIG` 错误码，与同文件其它校验的错误形态不一致。
- **建议**：把 `populate` 包进 `try`，`catch (e: Exception) => throw invalid(position, e.message)`，保持单一错误契约。

### [轻微][存量] 两个 public 成员仓内零引用，且恢复判定靠文案而非 `isRecovery()`

- **位置**：`fprobe/src/alarm/AlarmEvent.cj:75-77`（`isRecovery()`）、`fprobe/src/alarm/AlarmRule.cj:63-72`（`AlarmOp.toString()`）
- **来源**：存量
- **判据**：review-checklist §1（可见性建议，非死代码——两者都是公共顶层类型的 `public` 成员，但 `fprobe` 的 `cjpm.toml:36` 是 `output-type = "executable"`，不存在下游链接方）、§2（同一语义两处实现）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`、`target/`）`grep -rn "isRecovery|AlarmOp.*toString"` 只命中定义处；而 `EmailAlarmChannel.cj:130` 判恢复事件用的是 `title.startsWith("【已恢复】")`，即 `AlarmEvent.title()`（`:65-73`）的文案被当成协议。
- **描述**：`isRecovery()` 写好了却没人用，渠道改用字符串前缀判断横幅颜色；一旦标题文案（`【已恢复】`）调整，恢复邮件会变红色横幅，且编译器不会提示。`AlarmOp.toString()` 也无人调用（`AlarmRule` 只做 `parse`）。
- **建议**：`EmailAlarmChannel` 改为 `event.isRecovery` 语义（或让 `AlarmEvent` 自带 `bannerColor()`），删掉 `AlarmOp.toString()` 或补一条 round-trip 用例给它存在理由。因为模块是 executable，删除不涉及对外契约。

### [轻微][存量] `ChannelDispatcher` 用 `HashMap.add` 静默覆盖同名渠道，`enabled` 也不去重

- **位置**：`fprobe/src/channel/ChannelDispatcher.cj:36-38`（构造时 `this.channels.add(name, channel)`，返回值丢弃）、`:39-44`（`enabled` 原样保存）、`:50-58`/`:61-77`（按 `enabled` 逐个发）
- **来源**：存量
- **判据**：`fountain-baseline.md` §4（同名注册必须启动直接失败，不做隐式优先级）、review-checklist §11（静默覆盖）
- **证据**：静态确定 —— `HashMap.add` 语义为"已存在的键替换值并返回旧值"（`std/collection/collection_package_api/collection_package_class.md:4866`），代码丢弃返回值；`enabled` 未做 `HashSet` 去重。
- **描述**：两处后果：(a) 构造入参里出现同名渠道时后者静默替换前者（当前生产装配只放 `email`，属潜在路径）；(b) `probe_alarmChannels=email,email` 会把同一条告警发两遍、日志也打两遍（`SupervisorRuntime.buildChannels` 不去重）。
- **建议**：`add` 的返回值 `case Some(_) => throw ProbeException(CONFIG, "告警渠道重复: name")`；`enabled` 用 `HashSet` 过滤。两条都用现有 `ChannelDispatcher_test` 的表驱动风格补用例。

### [轻微][存量] 缺失键登记模板复制 4 份，`dispatch`/`dispatchRich` 与 `format`/`renderHtml` 各有一对同语义实现

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:99-147`（`evaluateMissing` 里节点/缺 kind/采集错误三段形状一致）、`:164-173`（第四份）、`fprobe/src/channel/ChannelDispatcher.cj:50-58` vs `:61-77`、`fprobe/src/alarm/AlarmEvent.cj:80-101` vs `fprobe/src/channel/EmailAlarmChannel.cj:119-146`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：字面量复制 / 换控制流）
- **证据**：静态确定 —— 四处均为 `current.add(key)` + 构造 `AlarmEvent` + `if (missing.raise(key, event)) { emit(event) }`；`dispatchRich` 的 `for + match + try/catch` 与 `dispatch` 仅差调用哪个方法（`sendOne` 只覆盖了纯文本分支）；`AlarmEvent.format` 枚举"节点/规则/监控项/当前值/阈值/级别/时间"，`EmailAlarmChannel.renderHtml` 又按 `:` 拆分同一份文本重建这份字段表。
- **描述**：缺失键登记这一段重复是上面"kind 缺失抖动"的直接成因——同一个键空间在 `evaluateMissing` 与 `evaluateRules` 里各写一遍，登记时机却不同；`format`/`renderHtml` 的字段表重复则让"给 `AlarmEvent` 加字段"必须同时改两处，而且 HTML 表格是通过解析自己生成的文本得到的，`value` 里出现 `:` 就会被错误拆行。
- **建议**：抽 `private func raiseMissing(key: String, event: AlarmEvent, current: HashSet<String>)`（4 处归一）；`dispatchRich` 内联的 try/catch 与 `dispatch` 共用一个 `(AlarmMessageChannel) -> Unit` 包装；`EmailAlarmChannel` 改成接收结构化 `AlarmEvent` 生成表格（或让 `AlarmEvent` 提供 `fields(): Array<(String,String)>`，`format()` 与 HTML 共用同一份字段表）。

### [轻微][存量] 节点转 OFFLINE 的那一 tick，上一帧的 `PROBE_ERROR` / 缺项会各收到一条假「已恢复」

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:98-111`（`OFFLINE` 早返回，不登记任何键）、`:113-116`（无快照直接 return）、`:83-89`（`collectRecovered` 随后把旧键判为恢复）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符：条件并未恢复）
- **证据**：静态确定 —— 节点由 ONLINE 转 OFFLINE 时，`batchNodes` 仍含该节点，`currentMissing` 里没有任何 `node|kind|*` / `node|error|*` 键，于是 `MissingDataTracker.collectRecovered` 把它们全部当"已恢复"发出 `RECOVERY`。
- **描述**：一次断线会先收到若干条"监控项 X 已恢复"，紧接着才是"节点不可达"，顺序与语义都反了，收敛阶段还会多一轮邮件。只影响通知语义，不影响状态机主流程。
- **建议**：`OFFLINE` 分支先把上一帧属于该节点的键原样写入 `currentMissing`（保持"条件未恢复"），由"节点不可达"事件承担解释；或在 `collectRecovered` 里跳过非 `ONLINE` 节点的键。

### [轻微][存量] `AlarmEngine.cj` 导入的 `ArrayList` 未使用

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `grep ArrayList` 只命中第 18 行；实际只用 `HashMap`、`HashSet`、`Array`。
- **建议**：改为 `import std.collection.{HashMap, HashSet}`。

## 优化可行性方案

### [CPU] 每条规则重复做一次 JSON 全量解析 + 路径编译 + 运算符解析

- **现状**：`AlarmEngine.evaluate` 每个 tick、每个节点、每条规则都调用 `jsonToData(data.dataJson)`（`:186`）、`DataPath.solid(rule.path)`（`:193`）、`AlarmOp.parse(rule.op)`（`:215`）。同一 `kind` 下 N 条规则会把同一份 `dataJson` 解析 N 次；`dataJson` 是探针整棵树（磁盘 mounts、网络 interfaces 数组），单份量级为百字节到数 KB。默认 5 秒 tick、10 节点 × 20 规则 ⇒ 每秒约 40 次解析 + 40 次路径编译，全部落在拉取线程的 `evaluate` 里，与 `onEvent` 的同步发送串在一起。
- **方案**：(a) 加载期把 `path` 预编译成 `DataPath`、`op` 解析成 `AlarmOp`，随 `AlarmRule` 持有（`DataPath.cache` 亦可，但要注意其全局缓存的并发语义）；(b) `evaluate` 内按节点先建 `kind → Data` 的一次性映射（每 tick 每 kind 解析一次），规则只做取值比较。
- **预期**：解析/编译次数从 `规则数 × 节点数` 降到 `用到的 kind 数 × 节点数`（本仓库默认配置下约 5-10 倍），单次成本不变；端到端收益取决于 `valueOf` 在 tick 里的占比（未知）。
- **代价**：`AlarmRule` 多两个字段、加载期多一次校验（正好补上面第 4 条缺陷）；`DataPath.cache` 有全局状态，优先用规则对象自带实例；无接口变更。
- **验证**：`cjpm bench -O2`，同输入（10 节点 × 20 规则 × 60 tick，fixture `dataJson` 固定）；`cjprof record` 看 `valueOf`/`jsonToData` 自耗时占比与 GC 分配量（每 tick 生成的 `DataObject` 树）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `valueOf` 的 JSON 解析 + `DataPath.solid` 编译占单 tick 的显著比例 | `fprobe/src/alarm/AlarmEngine.cj:185-212` | 自耗时占比、每 tick 分配字节 | `cjprof record`，10 节点 × 20 规则 × 60 tick；对照预编译版本 |
| 2 | `onEvent` 同步做 SMTP 发送，把拉取 tick 串行化（锁竞争之外的第二类阻塞） | `AlarmEngine.cj:233/245` → `SupervisorRuntime.cj:142` → `ChannelDispatcher.cj:68` | tick 实际间隔 P95、SMTP 单次耗时 | 分段计时：`evaluate` 前后、`dispatch` 前后各打时间戳；线程状态采样看 WAITING（CPU profile 看不到） |
| 3 | 抖动场景下的事件量（每 tick 2 条）是否已构成邮件/日志放大 | `AlarmEngine.cj:83-95`、`:166-173` | 每节点每小时事件条数 | 在 `emit` 处加计数器，跑 1 小时"kind 缺失"稳态场景 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/doc/spec/add-fprobe/specs/probe-agent/spec.md` | .md | ✅ | 归档变更 spec；端口/间隔/主机默认值与 `config/AgentSettings.cj:32-38` 一致；命令不走 shell、超时等承诺在 `collect/hw` 未在本部分展开 |
| 2 | `fprobe/doc/spec/add-fprobe/specs/probe-contract/spec.md` | .md | ✅ | 归档变更 spec；`f_probe/cjpm.toml` 依赖确为 `f_base`+`f_data`，与「依赖收敛」场景一致 |
| 3 | `fprobe/doc/spec/add-fprobe/specs/probe-reporting/spec.md` | .md | ✅ | 归档变更 spec；附件模型已被 `inline-report-charts` 取代，两份并存无交叉引用（见 §13 说明，不记缺陷） |
| 4 | `fprobe/doc/spec/add-fprobe/specs/probe-supervisor/spec.md` | .md | ✅ | 默认值与 `SupervisorSettings.cj:32-35` 一致；冷却语义与实现不符 → 发现 #3 |
| 5 | `fprobe/doc/spec/add-fprobe/specs/tui-backend/spec.md` | .md | ✅ | `f_tui/cjpm.toml` 依赖确为 `f_base` + 五个 ratatui 基础包，无 `crossterm`/`ratatui_widgets` |
| 6 | `fprobe/doc/spec/add-fprobe/tasks.md` | .md | ✅ | 任务清单；`:170` 的镜像路径 `openspec/changes/add-fprobe/` 已不存在 → §13 说明 |
| 7 | `fprobe/doc/spec/inline-report-charts/design.md` | .md | ✅ | 归档变更 D1-D11 与后续 tasks 一一对应，内部自洽 |
| 8 | `fprobe/doc/spec/inline-report-charts/proposal.md` | .md | ✅ | 与 design/spec/tasks 口径一致 |
| 9 | `fprobe/doc/spec/inline-report-charts/specs/probe-reporting/spec.md` | .md | ✅ | MODIFIED/REMOVED/ADDED 三段与 design 决策对应 |
| 10 | `fprobe/doc/spec/inline-report-charts/tasks.md` | .md | ✅ | 1.1-5.2 与 design 的风险缓解项对应 |
| 11 | `fprobe/doc/tui.md` | .md | ✅ | 与实际实现逐条核对通过：非 TTY 退出码 2 + 文案（`tui/TtyDetector.cj:46`、`tui/SupervisorApp.cj:96-99`）、图表阈值 8 行/20 列（`tui/ChartPanel.cj:30-31`）、页→图类型（`tui/ViewModel.cj:56-62`）、按键表（`tui/KeyMap.cj`/`TtyKeySource.cj:77-80`）、底部 ` \| ` 拼接（`tui/FprobePainter.cj:299-304`）、退出顺序（`SupervisorApp.cj:142-151`） |
| 12 | `fprobe/src/Main_test.cj` | .cj | ✅ | `dispatchWith` 的 help/agent/supervisor+resident/空参/未知命令/前置选项 6 类分支均有用例 |
| 13 | `fprobe/src/alarm/AlarmEngine.cj` | .cj | ✅ | 发现 #1-#5、#10、#11；优化方案 1 |
| 14 | `fprobe/src/alarm/AlarmEngine_test.cj` | .cj | ✅ | 覆盖 forSeconds/冷却/恢复/缺失/静音；缺「规则 kind 缺失跨 tick」用例（发现 #2） |
| 15 | `fprobe/src/alarm/AlarmEvent.cj` | .cj | ✅ | 发现 #7；`format()` 字段表与 EmailAlarmChannel 重复（发现 #9） |
| 16 | `fprobe/src/alarm/AlarmRule.cj` | .cj | ✅ | 发现 #4、#6、#7 |
| 17 | `fprobe/src/alarm/AlarmRule_test.cj` | .cj | ✅ | 解析/六种比较/大小写容错均有覆盖 |
| 18 | `fprobe/src/alarm/MissingDataTracker.cj` | .cj | ✅ | 键空间有界（节点×kind×规则），无泄漏；去重语义问题见 #2/#10 |
| 19 | `fprobe/src/channel/ChannelDispatcher.cj` | .cj | ✅ | 发现 #8、#9；`case None => ()` 为构造期已校验后的防御分支，未单列 |
| 20 | `fprobe/src/channel/ChannelDispatcher_test.cj` | .cj | ✅ | 覆盖多渠道/失败隔离/未知渠道/富消息透传 |

合计：`.cj` 9 个 / `.md` 11 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 #2（缺 kind 抖动）、#10（假恢复）、#6（错误契约）；分层与依赖方向正常（`alarm` 只依赖 `f_data`/`fprobe.snapshot`/`collect.Clock`），无注入面（`AlarmEvent.format` 只输出到文本/HTML，HTML 侧由 `EmailAlarmChannel.escapeHtml` 转义） |
| §1 死代码 | 2 | 发现 #11（unused import）；`isRecovery`/`AlarmOp.toString` 归入 #7 的可见性建议（executable 模块无下游）。机械核对过：`RuleState`、`ALARM_RULE_FIELDS`、`invalid`、`validate`、`sendOne`、`number`、`stateOf`、`isMuted`、`cooldownElapsed`、`emit` 均有调用者；`evaluateRules` 的 `case None => ()` 与 `dispatch` 的 `case None => ()` 是构造期校验后的防御分支，不判死代码 |
| §2 重复逻辑 | 3 | 发现 #9（三处同语义实现）；另比对了本部分 2 个 enum 的手写 `operator ==`（`AlarmEventType:26-32`、`AlarmOp:33-38`，同模块还有 `NodeStatus`/`ReplyDecision`/`WhitelistResult`/`UiKey` 同形），语言文档未提供枚举自动派生 `Equatable` 的依据，不据此判重复；测试里的 `dispatchWith` 样板属测试准备代码，不计 |
| §3 空实现 | 1 | 发现 #5（`emit` 空 catch）；无空函数体、无 TODO/占位实现 |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`evaluate → evaluateMissing/evaluateRules → applyRule → emit → onEvent` 是单向调用链，`onEvent` 不回调引擎；`DataPath` 的递归遍历在 `f_data`，深度由 `rule.path`（配置常量）决定 |
| §5 OOM | 0 | `states`/`mutedUntil`/`active` 三个容器键空间分别上界为 节点×规则名、规则名、节点×(kind+error)，均来自启动配置与授权回复；无按报文长度预分配、无全量物化 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`valueOf` 的重复解析只作为线索，已进「待验证假设 #1」与优化方案（无基线） |
| §6.2 大粒度锁 | 0 | 本部分未使用锁；真正的跨线程问题按 §12.1 记为严重（发现 #1），不重复计为锁粒度问题 |
| §6.3 并发串行 | 0 | 无 `spawn`/`get`；`onEvent` 同步发送导致 tick 与 SMTP 串行，属性能假设（待验证 #2），无测量数据不定性 |
| §6.4 低效算法 | 0 | `evaluateRules` 的 `rules × agents` 双层扫描规模为配置量级（≤ 数十），`valueOf` 的重复解析已按"无基线"处理，未写成缺陷 |
| §7 降堆内存方案 | 0 | 每 tick 的临时对象（2 个 `HashSet`、`DataObject` 树、事件对象）生命周期都在单次 `evaluate` 内，无长期持有；未取得分配量数据，不提方案 |
| §8 降 CPU 方案 | 1 | 优化方案 1（预编译 path/op + 每 kind 解析一次），证据状态「无基线」 |
| §9 local mode 可行性 | 0 | `AlarmEvent` 经 `onEvent`（`AlarmEngine.cj:276-284`）逃逸到 `SupervisorRuntime` 的事件表与告警渠道，直接违反 local mode 的逃逸约束；`DataObject` 树虽在函数内构建，但没有改前改后的峰值内存对照，收益无法证明 |
| §11 现有代码的 BUG（存量） | 5 | 发现 #2/#3/#4/#6/#10 |
| §12 并发安全与锁粒度 | 1 | 发现 #1（`mutedUntil` 跨线程无同步）；判定给出具体两条线程路径与缺失的同步手段 |
| §13 文档一致性 | 0 | `doc/tui.md` 逐条核对通过（见覆盖表 #11）。归档 spec 按「当时自洽」口径核对：默认值、依赖清单、错误码与任务勾选均自洽。两点说明不计缺陷：(a) `probe-reporting` 的附件模型被 `inline-report-charts` 取代，两份并存且无 superseded 指针；(b) `add-fprobe/tasks.md:170` 要求与 `openspec/changes/add-fprobe/` 保持镜像，而该目录已不存在（`ls openspec/changes` 仅 `add-f-a2a/`、`archive/`），属失效路径，建议合并时改成"本目录为唯一副本" |
| §14 功能完备性与 README 覆盖 | 1 | 发现 #3（`probe_alarmCooldownSeconds` 承诺的冷却窗口在实现中不存在）。README 不在本部分（属其它分部分），未做公开 API 对照 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

本部分的 5 个生产源文件（告警引擎、事件、规则、缺失追踪、渠道分发）结构清楚、职责单一，`AlarmRule` 的"配置阶段一次校验、运行期只按 `DataPath` 取值"这个方向是对的，`MissingDataTracker`、`RuleState` 的意图也都能从注释读出来。**主要风险集中在"告警可信度"而不是性能**：

1. **必须先修的阻塞项是发现 #1**——`mute` 与 `evaluate` 分属两条常驻线程，却共享一个未同步的 `HashMap`。这是唯一一条严重项，属于"默认按多线程审"下无法自证安全的情形；修法很小（一把锁或原子快照），但需要并发压测用例兜底。
2. **第二梯队是三条"告警会骗人"的缺陷**：#2（kind 缺失每 tick 伪造恢复+重复告警）、#3（冷却参数从未生效）、#4（`path` 写错则规则永久静默失效）。三者都直接损害监控系统最核心的价值，且都缺用例——现有 `AlarmEngine_test` 只覆盖了 happy path 与 `probe_expectKinds` 分支。
3. **可排期的是 #5 与 #6-#11**：静默吞异常、错误消息契约、同名渠道静默覆盖、四处缺失键模板与两对同语义实现、离线时的假恢复、未使用的 import 与两个零引用 public 成员。它们不影响主流程，但会让下一次改动继续踩同一类坑。
4. **性能结论一律没有资格下判断**：`valueOf` 的重复解析是明显的结构性浪费，但本轮没有基线，只能留在「优化方案（无基线）」与「待验证假设」里，不进修复清单。

范围外提示（不计入本部分统计，供合并时转给相应分部分）：(a) `SupervisorRuntime.cj:498-503` 对已注册的扩展渠道只做 `AlarmChannelRegistry.channel(...).isSome()` 判断并打印"已注册但未配置，已跳过"，从不实例化工厂——`probe_alarmChannels` 里的扩展渠道永远收不到告警，与 spec「多渠道分发」不符；(b) `SupervisorRuntime.cj:142` 在拉取线程内同步做 `dispatch`（含 SMTP），一次网络超时就会推迟整个 tick；(c) `tui/RenderPlan.cj:235` 把 `SystemClock().nowMs()` 原样拼成"刷新 1764…ms"，状态栏展示的是 epoch 毫秒而非时间。

存量合计 11 条（严重 1 / 一般 4 / 轻微 6），是否纳入修复待用户决定。
