# f_ticktock 模块审查报告（模块第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_ticktock`（本部分 20 个文件：17 个 `.cj` + 3 个 `.md`；模块合计 31 个 `.cj` + 3 个 `.md`，`TicktockIndex` / `TicktockUnit` / `TicktockInitializer` / `Trigger` / `imports.cj` / `macros/` / 其余测试属第 2 部分）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 基线；`git log` 最新提交 `270378aaa 2026-11-27`）
- **审查重点**：定时调度语义（`Timer.after` 回调返回值即下次延迟、`Some` 自动重排）、时间轮/注册表与候选正确性、并发安全与锁粒度、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件仅为分报告，模块报告由主 Agent 合并产出）

## 发现

### [严重][存量] `|` 多表达式任务在同一 tick 被候选缓冲重复收集，业务被执行两次

- **位置**：`f_ticktock/src/Ticktock.cj:238-246`（`emit` 复制候选到 `batch`，不去重）、`:261-266`（每个 batch 元素各 `spawn` 一次 `executeOne`）；重复来源 `f_ticktock/src/TicktockIndex.cj:189-206`（`collect` 依次追加 `always` / 值桶 / `wildcard` / `dynamic`，无去重）
- **来源**：存量（`git blame -L 236,246` → `560a4fb0e 2026-11-27`「运行期时间索引与表达式编译驻留（对外行为不变）」，索引改造引入；快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§10（正确性）
- **证据**：静态确定 —— ① `CronCompiler.compile` 对 `a|b` 返回两个 `CronDataCollection`（`CronCompiler.cj:78-83`），`Ticktock.register` 对每个 collection 各调一次 `index.add(id, cron)`（`Ticktock.cj:223-225`）；② `TicktockIndex.add` 对全通配 collection 走 `always.add(id)` 后 `return`（`TicktockIndex.cj:103-106`），对受约束 collection 写入 `buckets`，对未约束单位写入 `wildcard`（`:80-112`）；③ `collect` 把 `always`、`buckets[unit][value]`、`wildcard[unit]`、`dynamic[unit]` 四组 id **直接 append 进同一个 buffer**，`HashSet` 只保证单组内唯一；④ `keep`/`filterInPlace` 对重复 id 双双保留；⑤ `emit` 对 `candidateIds` 逐个 `entries[id]` 入 `batch`，`batch` 里同一个 `TicktockEntry` 出现几次就 `spawn` 几次。
- **描述**：只要一条任务由 `|` 组合出两条约束单位不同的表达式，同一 tick 就会被执行两次（甚至多次）。最小复现：`addOrReplaceTask(task, "0 5 * * * *|* * 8 * * *")` —— 每分钟第 5 分，`wildcard[MINUTELY]`（第二条表达式未约束分）与 `buckets[MINUTELY][5]`（第一条）同时含该 id，`collect` 追加两次；若当前时间同时满足 `matches`，`executeOne` 跑两遍。加全通配段（`"0 0 8 * * *|* * * * * *"`）更典型：命中时刻 `always` 与值桶必然同时含该 id。改造前的实现是「每任务一次 `spawn`，线程内 `for (cron ...) { run; break }`」（见 `doc/性能基准测试与优化方案.md:697-705` 的代码快照），同一条任务在一个 tick 内只会执行一次，所以这是**索引改造引入的语义回归**。`concurrentable=false` 的任务只有在第一次执行尚未结束时才会被记账拦住，业务短任务（占多数）直接重复执行 —— 重复扣款、重复发通知、重复写审计。`once` 任务同样会进入 `batch` 两次（第一次执行后 `removeTask` 只清注册表，不影响已复制的 `batch`）。
- **建议**：在 `emit` 的收集阶段去重（`HashSet<Int64>` 或对 `batch` 用 `set` 辅助，tick 级容器可像 `candidateIds` 一样做成员复用）；或让 `TicktockIndex.collect` 只从一个来源追加、其余来源做「不在已收集集合内」判断。补一条用例：`"0 5 * * * *|* * 8 * * *"` 在 5 分整执行 1 次（对拍旧实现的 `break` 语义）。第 2 部分审查 `TicktockIndex.cj` 时会从索引侧再次命中同一根因，合并时按一条计。

### [严重][存量] 延迟任务的 cron 由 `now + delay` 的日历字段拼成，亚秒 delay 永不触发、整秒 delay 最多提前 1 秒

- **位置**：`f_ticktock/src/DelayedTicktockTask.cj:26-31`（`cron` 用 `t.second/t.minute/t.hour/t.dayOfMonth/t.month/t.dayOfWeek/t.year` 拼 7 段表达式）、`f_ticktock/src/Chrono.cj:36-43`（tick 只在整秒边界触发）、`f_ticktock/src/Ticktock.cj:150-163`（`addOrReplaceDelayTask0` 用它注册）
- **来源**：存量（blame `4be871f2fd 2026-10-02`；快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 语义与注释不符）、§13（文档与实现不符）
- **证据**：静态确定 —— `cron` 的三段取值全部来自「秒级截断后的绝对时刻」：`DateTime.now() + delay` 的小数秒部分被丢弃。`Chrono.start` 的 `next(now, n)` 是 `DateTime.of(..., second: now.second) + Duration.second * n`，即 tick 只落在 `hh:mm:ss.000`；`CronData.matches` 用 `unit.current(date)` 比较整秒。两步相除的唯一结果是：`delay < 1s` 时生成的 cron 指向**已经过去的秒**，此后每 tick 的 `second` 都不相等，任务永不执行；`delay` 非整秒时（如 `1.5s`）任务在 `floor(now+delay)` 那一秒触发，最多提前近 1 秒。
- **描述**：README 把 `'500ms'` 列为 `@DelayedTask[delay: ...]` 的**推荐写法**（`README.md:130`、`README_en.md:131`），但 `delay: '500ms'` 的延迟任务注册后一次也不会跑，且没有任何告警（`emit` 只有在 `matches` 抛异常时才 warn）。第二次及以后的周期由 `run()` 的 `nextCall()` 重新登记同样的秒级 cron，误差不会自愈。`immediate: true` 只能保证登记时跑一次，之后的周期同样丢失。README 只写了「精度为秒」（`:131`），没有说明「<1s 永不触发」「向前取整」这两个后果。
- **建议**：延迟任务不要经 cron 表达；在 `Ticktock` 内单独维护一个「到期时刻 + 任务」的最小堆/时间槽（`delay` 直接用 `Duration`），或在拼 cron 前把 `now + delay` **向上取整到下一秒**并校验「结果 > now」，同时把不可用区间（`delay < 1s`）在 `addOrReplaceDelayTask` 里显式报错而不是静默登记。文档侧补一句「延迟精度为向上取整的秒，最小 1 秒」。

### [一般][存量] `immediate` 分支绕过 `run()`：不记账、不受 `concurrentable`/`once` 约束、异常无人处理

- **位置**：`f_ticktock/src/Ticktock.cj:153-163`（`addOrReplaceDelayTask0`）、对照 `Ticktock.cj:270-290`（`executeOne`：`try/catch` + warn + `once` 移除）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（错误处理不对称）、§12.1（并发语义）
- **证据**：静态确定 —— `spawn { task.execute() }` 直接调 `execute()`，既不经过 `TicktockTask.run()`（`TicktockTask.cj:27-37` 的 `stamped`/`executing`/`reset` 记账），也没有 `try/catch`；`immediate && !once` 时紧接着还会走 `addOrReplaceTask(task, task.cron)` 进入正常调度。
- **描述**：三点后果：① 立即执行不计入「正在执行」，`concurrentable=false` 的任务会出现「立即那次」与「首个周期」重叠；② `execute()` 抛异常时没有 `catch`，异常从 `spawn` 线程逸出，既不打 `Ticktock.emit:...` 日志也不受 `executeOne` 的异常隔离保护（`DefaultTicktockTaskExecuting` 的槽也不会被污染，因为根本没登记）；③ 两条路径的日志语义不同：正常路径每次执行有一行 debug，立即执行没有。
- **建议**：立即执行也走 `executeOne`（构造一个 `TicktockEntry(name, task, emptyList)` 或用私有函数复用 `run()+once+log+catch`），让记账、异常隔离、日志三处口径统一。

### [一般][存量] `once` 任务执行完按 name 删除，可能删掉并发注册的同名新任务

- **位置**：`f_ticktock/src/Ticktock.cj:277-280`（`executeOne` 里 `if (once) { this.removeTask(task) }`）、`:206-227`（`register` 按 name 复用 id）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（检查-然后-写入 / 跨线程状态）、§11（并发正确性）
- **证据**：静态确定 —— `removeTask(task)` 只按 `task.name` 到 `idByName` 查 id 后无条件 `index.removeId + entries[id] = None + idByName.remove`。`run()` 与 `removeTask` 之间没有版本号或对象身份校验。
- **描述**：`once` 任务执行期间（`run()` 可能耗时数秒），若有另一线程用同名 `addOrReplaceTask` 完成了一次替换（配置热更新、延迟任务自注册、注解任务重建），`executeOne` 的 `removeTask(task)` 会把这个**新注册**静默删除：任务从此消失，日志上只有一行 debug。索引改造后 id 复用更频繁（`freeIds`），该窗口的影响面比旧实现更大。
- **建议**：`removeTask` 增加「按 id + 任务引用/版本」比对（`idByName[name] == id && entries[id].task == task` 才删），或让 `register` 维护单调递增的 `registerSeq` 断点，`executeOne` 携带断点做 CAS 式删除。

### [一般][存量] `executing(stamp)` 名为查询实为「占位」，对外可覆盖 API 的文档语义与副作用不符

- **位置**：`f_ticktock/src/DefaultTicktockTaskExecuting.cj:24-26`（`addIfAbsent` 会插入）、`f_ticktock/src/TicktockTaskDef.cj:41-48`（注释「当前任务是否正在执行」）、`f_ticktock/src/TicktockTask.cj:79-81`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（语义与命名/注释不符）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— std 文档 `collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1132-1147`：`addIfAbsent(k, v)` 在键不存在时**写入**并返回 `None`，存在时返回 `Some(旧值)`。因此 `executing(name, stamp)` 同时承担「进入临界区」与「查询」两种职责：返回 `true` 表示此前已有执行者。
- **描述**：`TicktockTaskDef` 把 `executing` 文档化为「当前任务是否正在执行」（谓语）并声明为 `public open` 供使用者覆盖（README `:43-46` 也这么写），但默认实现带写副作用。使用者按文档实现一个纯查询（`return running;`）时：`run()` 的 `!executing(...)` 永远不会写入占位，`concurrentable=false` 的任务会变成「永远可执行」（每次都并发执行），或者反向实现成「首次返回 true」则任务永久阻塞；且 `reset` 的 `removeIf(value == stamp)` 会因槽里没有自己的 stamp 而失效。这类错误只在压测时表现为「不并发也不串行」，很难定位。
- **建议**：拆成显式的 `enter(stamp): Bool`（占位成功才执行）+ `reset(stamp)`，或把现有函数改名 `tryEnter` 并在文档里写清「有写副作用，必须与 reset 成对」。保留旧签名时至少把注释改成「返回 false 表示本次进入成功（已占位）」。

### [一般][存量] `shutdown()` 不可恢复，`instance` 仍返回已停摆的调度器，注册后任务静默不执行

- **位置**：`f_ticktock/src/Ticktock.cj:292-294`（`shutdown` 只 `ticktock.shutdown()`）、`f_ticktock/src/Chrono.cj:45-48`、`Ticktock.cj:63-67`（`instance` 恒返回 `instance_` 里的旧对象）、`:128-131`（`env.atExit(shutdown)`）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（半成品：生命周期只有单向）
- **证据**：静态确定 —— std 文档 `sync/sync_package_api/sync_package_classes.md:11013-11021`：`Timer.cancel()` 后「关联 Task 将不再被调度执行」，且「调用多次等同于只调用一次」，没有 restart。`instance_` 只在 `getInstance` 成功创建时写入，`shutdown` 不清空它。`Launcher_test.cj:345` 在 `test10` 末尾 shutdown 之后，`:348-366` 的 `test11/12/13` 仍通过 `Ticktock.instance` 注册任务并等待 tick —— `test12/test13` 的 `waitAndShutdown` 只能等满 30s 超时。
- **描述**：调用 `shutdown()` 之后 `Ticktock.instance` 继续返回同一个已停摆的对象：`addOrReplaceTask` 正常返回、索引正常建立、`emit` 再也不会被调用，任务静默不执行；`getInstance` 也不会重建（`instance_.load()` 命中 Some 直接返回）。测试里表现为用例顺序依赖 + 30s 空等，生产里的表现是「停服钩子被误调/重复初始化后，此后所有定时任务消失」。
- **建议**：`shutdown` 时把 `instance_` CAS 回 `None`（并让 `Chrono` 支持重新 `start`），或明确文档化为「进程终止专用、调用后不可再用」并在 `instance` 里对已停摆实例抛异常；测试侧改成本地 `Ticktock` 实例或每个用例独立进程。

### [一般][存量] `FuncInvocationTask` 的可变字段被 tick 线程读取且无同步，`name` 注册后仍可改

- **位置**：`f_ticktock/src/FuncInvocationTask.cj:19-22`（`name_` / `concurrentable_` / `once_` / `function` 均为普通 `var`）、`:29-40`（setter）、`:41-58`（`name`/`concurrentable`/`once`/`execute` 在 `spawn` 线程里读）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（共享可变状态无保护、发布逸出）、§11（契约与命名）
- **证据**：静态确定 —— `Ticktock.emit` 把 `entry.task` 交给 `spawn { executeOne(...) }`（`Ticktock.cj:261-265`），该线程读 `task.once` / `task.concurrentable`（`:276-280` 与 `run()`），而 setter 由调用方线程写；没有任何锁、原子或 `let` 约束。`name` 同时是注册键（`Ticktock.cj:206`）与 `DefaultTicktockTaskExecuting` 的记账键（`DefaultTicktockTaskExecuting.cj:25`），但 `setName` 之后这两处都用旧值。
- **描述**：① 运行期 `setFunction`/`setOnce` 与 tick 线程形成数据竞争（可见性与撕裂，`once` 的布尔翻转还可能导致任务被误移除或永不移除）；② 注册后再 `setName`，`removeTask(task)` 会按新名查找 → 找不到，任务无法移除；`executing` 记账也会换键 → 同名并发保护失效。类本身是 `public open`，这两种用法对外都可达，且文档没有任何「注册后不可变」的约束。
- **建议**：注册相关字段改成 `let`（构造注入），或提供 `withXxx` 返回新对象；若必须保留 setter，把可变状态收敛到一个 `@Frozen` 快照并在 `register` 时冻结，同时禁止 `setName`（改为 `rename` 时同步注册表）。

### [一般][存量] 日/月/周字段的 `0/n` 实际语义与 `Ticktock` 类注释承诺不符

- **位置**：`f_ticktock/src/CronCompiler.cj:103-105`、`:117-119`、`:129-131`（`if (start == 0 && start < ticktockUnit.min) { start = ticktockUnit.min }`）；对照 `f_ticktock/src/Ticktock.cj:42-44`（类注释「0/2 的取值范围分别是 2 4 6 … 30」「月的 0/2 是 2 4 6 8 10 12」）、`:46-49`（星期「0/n 转换为 n/n,7」）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（语义与注释不符）、§13（文档与实现不符）
- **证据**：静态确定 —— 三个分支都在解析出 `start = 0` 后先钳到该单位的 `min`（日/月/周均为 1），再调 `convertDuration(start, end, duration)`；而 `TicktockUnit.convertDuration` 里「`oneStart && start == 0` 时从 `duration` 起算」的分支（`TicktockUnit.cj:202-204`，第 2 部分文件）因此在 `CronCompiler` 这条唯一入口上**不可达**。逐字推导：`MONTHLY` 的 `0/2` → `start=1` → `1..=12:2` → 1,3,5,7,9,11（注释写 2,4,6,8,10,12）；`MONTH_DAILY` 的 `0/2` → 1,3,…,31（注释写 2,4,…,30）；`WEEK_DAILY` 的 `0/3` → 1,4,7（注释写 3,6,7）。现有测试未覆盖这三种写法（`Launcher_test.cj:270`、`:293` 只验「不抛异常」）。
- **描述**：按类注释写 `0 0 8 1/2 * *` 这类表达式时，实际触发日与文档差一天（月/周同理），而且是**静默**的语义漂移；反过来，注释里那套「从 n 起算」的规则只对直接调 `TicktockUnit.convertDuration` 的调用者成立，两条入口语义不一致。
- **建议**：先确认预期语义。若以注释为准：`CronCompiler` 去掉钳位，把 `start == 0` 交给 `convertDuration` 的 `oneStart` 分支处理（但需同时处理 `0` 不是合法日/月值的错误提示）；若以当前实现为准：改 `Ticktock.cj:42-49` 与 README `:67-80` 的描述，并补 `0/2`、`0/3` 的用例锁死行为。

### [一般][存量] 字段数 > 7 的表达式抛 `IndexOutOfBoundsException`，与 public API 的错误契约不符

- **位置**：`f_ticktock/src/CronCompiler.cj:84-86`（`for (i in 0..units.size) { TicktockUnit.valueOf(i) }`）、`f_ticktock/src/TicktockUnit.cj:57-59`（`values[value]` 无边界检查，第 2 部分文件）
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界/越界、错误处理缺失）、§14.1（未处理部分输入）
- **证据**：静态确定 —— `TicktockUnit.values` 是长度 7 的数组（`TicktockUnit.cj:52-56`），`valueOf(7)` 直接下标越界；`compile` 对 `units` 数量不做任何校验，也没有 `catch` 转换。同模块所有非法表达式路径抛的都是 `IllegalArgumentException`，`Launcher_test.cj:193-346` 的用例正是按 `catch (e: IllegalArgumentException)` 写的。
- **描述**：`addOrReplaceTask(task, "0 0 8 * * * * 2030")`（多写一个字段，很容易发生在把 6 段表达式改成 7 段时）抛出的是 `IndexOutOfBoundsException`，调用方按文档捕获 `IllegalArgumentException` 会漏掉它 → 启动/热更新路径直接崩溃，且错误信息是「数组下标越界」而不是「cron 表达式非法」。反之，少于 7 段是合法写法（尾字段视为 `*`），所以只有「多段」这一侧无保护。
- **建议**：`compile` 开头校验 `units.size <= 7`，超出抛 `IllegalArgumentException("cron expression has ${units.size} fields, at most 7 (second minute hour day month weekday year)")`；`TicktockUnit.valueOf` 对越界也改成显式异常。

### [轻微][存量] 死代码：`Launcher_test` 的 12 个任务类、`TestCurrently`、`CronCompiler_test` 的空循环

- **位置**：`f_ticktock/src/Launcher_test.cj:411-430`（`LauncherTestTask0`）、`:432-448`（`1_1`）、`:450-466`（`1_2`）、`:468-486`（`Task2`）、`:488-499`、`:501-512`、`:514-525`、`:527-538`、`:540-551`、`:553-564`、`:566-576`（`Task9`）、`:636-646`（`Task14`）；`f_ticktock/src/TestCurrently_test.cj:20-29`；`f_ticktock/src/CronCompiler_test.cj:39-41`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（无调用者 / 读了不用）
- **证据**：静态确定 —— 全仓 `*.cj` 检索：这 12 个类与 `TestCurrently` 的**唯一引用全部落在 `Launcher_test.cj:34-192`、`:367-408` 的注释块里**（`// @TestCase` 已整体注释）；`CronCompiler_test.cj:39-41` 是 `for (unit in TicktockUnit.values) { }` 的空循环，循环体无语句、循环变量未使用。`TestCurrently` 是 `public class` 且位于 `*_test.cj`（只在测试构建内编译），按硬原则一不判为对外 API 死代码，此处按「仅供注释代码使用的测试辅助类」记录。
- **描述**：这些类被注释掉的用例淘汰后仍保留：`LauncherTestTask3..Task9` 七个类除 `name` 字面量外逐行相同（与 §2 重复逻辑同源），`LauncherTestTask12/13` 的 `executed` 还是未同步的普通 `var`（被 `spawn` 写）。保留它们让「哪些用例还在跑」不可读，也拖慢测试构建。
- **建议**：删除注释用例与不再引用的任务类；如需保留场景，把 `@TestCase` 恢复并改成断言执行次数（`LauncherTestTask12/13` 的 `executed` 换 `AtomicInt64`）。`TestCurrently` 若要留，移到需要的用例旁并收窄为 `internal`。

### [轻微][存量] 重复逻辑：`CronTicktockTaskImpl.extract<T>` 与 `DelayedTicktockTaskImpl.extract<T>` 逐行相同

- **位置**：`f_ticktock/src/CronTask.cj:73-83` 与 `:116-126`
- **来源**：存量（blame `270378aaa 2026-11-27`；快照模式无基线）
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 两个函数体逐语句对齐：`ClassTypeInfo.of<T>()` → `for (f in klass.instanceFunctions where f.parameters.isEmpty())` → `findAnnotation<A>()` → `list.add((a, f.name))`；差异只有注解类型 `CronTask` / `DelayedTask` 与返回元组类型。错误文案、边界（无参方法）、顺序（`instanceFunctions` 顺序）完全一致。
- **描述**：同一套「扫无参成员 + 取注解」的反射逻辑维护两份，后续加「排除 static / 排除 private」这类过滤时极易漏改一边。
- **建议**：抽一个 `private static func extractAnnotated<T, A>(list: ArrayList<(A, String)>) where A <: Annotation`（或返回 `ArrayList<(A, String)>` 的泛型辅助），两个 `extract` 各转调一行；注解参数无实质差异，可直接合并。

### [轻微][存量] 重复逻辑：接口默认实现与基类覆盖逐行相同；延迟任务的记账骨架被复制

- **位置**：`f_ticktock/src/TicktockTaskDef.cj:24-39`、`:46-55`（默认 `once`/`concurrentable`/`executing`/`reset`）与 `f_ticktock/src/TicktockTask.cj:57-67`、`:79-88`（同名覆盖）；`f_ticktock/src/DelayedTicktockTask.cj:52-68` 与 `TicktockTask.cj:29-36`（`stamped.fetchAdd(1) + 1` + `executing` + `reset` 骨架）
- **来源**：存量（blame `4be871f2fd 2026-10-02` / `270378aaa 2026-11-27`）
- **判据**：review-checklist §2（换控制流 / 近似重复）
- **证据**：静态确定 —— 接口里 4 个默认成员与 `TicktockTask` 的覆盖体逐行相同（`return false`、`DefaultTicktockTaskExecuting.executing(name, stamp)`、`.reset(name, stamp)`），而 `TicktockTask <: TicktockTaskDef` 且 `Ticktock` 只接受 `TicktockTask`（`Ticktock.cj:201`），直接实现接口的类型无法注册 → 接口默认分支在仓内不可达。`DelayedTicktockTask.run()` 复制的记账骨架与 `TicktockTask.run()` 语义相同，唯一实质差异是「已在执行且不可并发」时它调 `nextCall()` 重新登记（`DelayedTicktockTask.cj:63-65`），这是业务要求，不能简单合并。
- **描述**：两处都是「看起来冗余、改动时容易只改一处」的形态：接口默认值改了不会影响实际行为（被基类覆盖），延迟任务改了记账顺序会影响并发判定。
- **建议**：接口只保留 `name` / `execute` / `toString` 的契约（默认值删掉，或在注释里写明「仅为直接实现者提供，时间轮不使用」）；把 `stamped` + `executing` + `finally reset` 抽成 `TicktockTask` 的 `protected func withExecutionSlot(body: () -> Unit): Bool`，延迟任务复用并只在返回 false 时补 `nextCall()`。

### [轻微][存量] 公开参数拼写 `concurrenctly`，与 `concurrentable`/`setConcurrentable` 命名不一致

- **位置**：`f_ticktock/src/Ticktock.cj:178`、`f_ticktock/src/FuncCronTicktockTask.cj:23`、`:48`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10（可读性 / 命名）
- **证据**：静态确定 —— 具名参数写作 `concurrenctly!`（多一个 `c`、少一个 `a`），而属性名是 `concurrentable`（`TicktockTaskDef.cj:35`），`FuncInvocationTask` 的 setter 是 `setConcurrentable`（`FuncInvocationTask.cj:32`）。
- **描述**：`addOrReplaceTask(taskName:..., concurrenctly: true, ...)` 是 public API 的具名参数，拼错后一旦有下游使用就无法无声改名（本项目允许破坏性变更，但需要一次性集中改）。
- **建议**：趁 1.3.x 统一为 `concurrently`（或直接复用属性名 `concurrentable`），并同步 README 与宏生成的调用点。

### [轻微][存量] README / README_en 的示例类写成 `public public open prop name`，示例无法编译

- **位置**：`f_ticktock/README.md:55`、`f_ticktock/README_en.md:56`
- **来源**：存量（blame `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— 源码里 `name` 是 `public open prop`（`TicktockTask.cj:68`），README 示例重复了两次 `public`；同时该示例把 `once`/`concurrentable`/`name`/`toString` 全部重写为与基类相同的内容，且 `executing`/`reset` 只有声明（`public func executing(stamp: Int64): Bool` 无函数体）—— 抄进工程会得到「重复修饰符」「缺少函数体」两类编译错误。
- **描述**：这是 README 里唯一的「自定义任务」完整示例，读文档的人第一步就会踩到；中英文两版同错。
- **建议**：示例改成最小实现（只保留 `cron` + `execute`，其余交给基类默认值），并删掉 `executing`/`reset` 的空声明；如要展示覆盖方式，给一个能编译的 `override` 版本。建议加一条「README 示例可编译」的检查（例如把示例抽到 `*_test.cj` 的文档测试）。

### [轻微][存量] 性能文档附录 C 的代码片段与仓内实现不一致，「入仓版」章节与历史方案混排

- **位置**：`f_ticktock/doc/性能基准测试与优化方案.md:593-715`（附录 C.2 的 `emit`：`for (cron in crons where cron.matches(now))` + `break`，单层 `spawn`）、`:634-644`（`addOrReplaceTask` 调 `CronCompiler.compile`）、`:370-382`（「改动基于工作区 1.3.16 源码，共三处」）；对照 `f_ticktock/src/Ticktock.cj:236-290`（现行：`candidateIds` → `batch` → `debugOn` → `executeOne` → `compileShared`）
- **来源**：存量（文档 `2026-10-14`；快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 与实现不符）
- **证据**：静态确定 —— 附录 C.2 的 `emit` 与当前 `Ticktock.emit` 结构不同（现行多一层 `executeOne`、`LOGGER.logLevelEnabled` 提升、`compileShared`）；附录 C.2 明确写「未改动的部分：… `addOrReplaceDelayTask0` …」，而 `Ticktock.cj:202` 已改用 `compileShared`。文档 §7（`:929-978`）又标称「入仓版复测」，读者无法判断该看哪一份代码。
- **描述**：附录 C/D 是历史方案快照，但同一文档里 §7 描述的是已入仓实现，两者混排且没有「本附录为第一轮方案、已被 §7 取代」的标注，容易被当成现状引用（尤其 `emit` 去重语义就是在这里被改掉的）。
- **建议**：附录 C/D 顶部加一句「历史方案，勿照抄；现行实现见 src/ 与 §7」，或把附录 C 的代码块替换成「见 `src/Ticktock.cj` 对应函数」的链接。

### [轻微][存量] README「其他公开 API」漏列多个 public 成员

- **位置**：`f_ticktock/README.md:160-177`（同 `README_en.md:161-178`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— README 声称「以下声明未在上文展开，按模块级/类型分组列出」，但漏掉：`Ticktock.removeTask`（`Ticktock.cj:133-148`）、`Ticktock.addOrReplaceTask` 三个重载（`:171-203`）、`CronData.start/end/last`（`CronData.cj:72-99`）、`CronDataCollection.get`（`CronDataCollection.cj:54-61`）、`FuncInvocationTask` 的 `name`/`execute`/`once`/`concurrentable`（`FuncInvocationTask.cj:41-58`）。`TicktockUnit` 只列了 `current`。
- **描述**：`removeTask` 是「任务下线」的唯一入口，README 全文搜不到；使用者只能读源码发现。
- **建议**：补齐上述符号（`TicktockUnit` 的 `min/max/lastRange/convert*` 若属实现细节，应在 README 里明确写「实现细节，不保证兼容」，否则同样列出）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分没有本机性能基线，下列结论全部标 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] `TicktockIndex.removeId` 每次替换任务都全单位全桶扫描

- **现状**：`TicktockIndex.removeId` 对 7 个单位逐个把 id 从 `wildcard` / `dynamic` / 全部值桶里摘除（`TicktockIndex.cj:116-131`）。桶规模由单位值域决定：秒 60 + 分 60 + 时 24 + 日 31 + 月 12 + 周 7 ≈ 194 个 `HashSet`/次。延迟任务每个周期都会走 `addOrReplaceTask`（`DelayedTicktockTask.cj:36`、`:45`、`:64`），即每个延迟任务每秒一次 `removeId + add`（后者还要重写若干个值桶）。10k 个 1s 延迟任务 ≈ 每秒 1.94M 次 `HashSet.remove`。
- **方案**：`add` 时把「本次写入过的 (unit, value)」记进 `HashMap<Int64, ArrayList<(Int64, Int64)>>`，`removeId` 只按记录精确摘除（同时删记录），并顺带清掉空桶；`trivial` 的维护仍需一次单位级扫描，但可以从「全桶扫描」降为「被记录桶数」。
- **预期**：`removeId` 的 `HashSet.remove` 次数从 O(值域) 降到 O(该表达式写入的桶数)（典型 cron 每单位 1 个值 → 7 次）；`addOrReplaceTask` 的注册期 CPU 与分配量随之下降。
- **代价**：每个 id 多一份「写入位置」索引（典型 7 个 `Int64` 对，10 万任务约 10 万 × ~200B），内存换 CPU；需要保持 `trivial` 语义不变。
- **验证**：`cjprof record` 跑 10k 个 `delay='1s'` 的 FixedDelay 任务 60s，对比 `removeId` 自耗时与注册/替换总 CPU；同时用 `getAllocatedHeapSize()` 对照分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 延迟任务每个周期重建 `TicktockEntry` 并重写索引桶

- **现状**：`FixedDelay`/`FixedRate` 的每个周期都调 `Ticktock.instance.addOrReplaceTask(this)`（`DelayedTicktockTask.cj:36`、`:45`、`:64`）→ `register` 新建一个 `TicktockEntry`（`Ticktock.cj:222`）→ `index.removeId` + 逐单位 `index.add`（`:223-225`）。10k 个 1s 延迟任务 ≈ 每秒 1 万个条目对象 + 7 万次桶写入 + 194 万次 `HashSet.remove`。
- **方案**：给「同一任务对象、同一 id、仅 cron 变化」的替换加一条原地更新路径：`register` 命中 `idByName` 且 `refEq(entries[id].task, task)` 时，只替换 `crons` 字段并重建该 id 的索引项（`TicktockIndex.replace(id, crons)`），不新建条目、不走全量 `removeId`。
- **预期**：延迟任务每周期减少 1 个 `TicktockEntry` 与一次全量摘除；稳态分配量随延迟任务数线性下降（比例待测）。
- **代价**：`TicktockEntry.crons` 需从 `let` 变成 `var`（或用 `AtomicOptionReference` 热替换以保持不可变发布），`emit` 读 `entry.crons` 时需拿到一致快照；语义上「替换同名任务」与「同一对象重排」要区分开，避免把真正的替换也走快路径。
- **验证**：同负载下 `getAllocatedHeapSize()` 增速、GC 次数、`register` 自耗时；确认 `removeTask` 仍能摘干净（`trivial` 不残留）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 大量延迟任务（每任务每秒一次换 cron）时，`removeId` 的全桶扫描是注册路径的主要 CPU | `f_ticktock/src/TicktockIndex.cj:116-131` | `removeId` 自耗时占比、每秒调用次数 | `cjprof record` 跑 10k 个 `delay='1s'`/FixedDelay 任务 60s；同时对 `register` 分段计时（`removeId` vs `add` vs `compileShared`） |
| 2 | 相邻两个 tick 的 `emit` 可能乱序执行（`Chrono` 每 tick `spawn` 一次，两次 `emit` 抢 `indexLock` 的顺序不确定） | `f_ticktock/src/Chrono.cj:39-41`、`Ticktock.cj:238-246` | 逆序比例、`indexLock` 等待时长 | 在 `executeOne` 记录 `(tickNow, 进入时刻)`，统计 `tickNow` 非单调的比例；`cjprof` 看线程状态（CPU profile 看不到锁等待） |
| 3 | 每秒一次的 `spawn`（`Chrono` 的 tick + 每次命中一个执行线程）在任务密集时抬高线程创建成本 | `f_ticktock/src/Chrono.cj:39-41`、`Ticktock.cj:261-265` | 线程创建次数/秒、单次成本 | 参考 `doc/性能基准测试与优化方案.md` §6.3（spawn ≈2.0µs/次、场景 A 600 次执行合计 ≈1ms），需在本机同 SDK 复测后才能作为结论 |

## 文件覆盖

> 与 `files/f_ticktock.part1.txt` 一一对应（20 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `README.md` | .md | ✅ | 见「示例 `public public open prop name` 无法编译」「其他公开 API 漏列」「`500ms` 延迟示例实际不触发」 |
| 2 | `README_en.md` | .md | ✅ | 与中文版同错（`:56`、`:131`），章节结构一致 |
| 3 | `doc/性能基准测试与优化方案.md` | .md | ✅ | 提供了本模块唯一的实测基线（场景 A/B、M1 驻留、②④ 收益）；附录 C/D 与现行实现不一致，见 §13 条 |
| 4 | `src/Chrono.cj` | .cj | ✅ | `Timer.after` 用法正确（返回 `Duration` 由编译器包成 `Some`，已核对 std 文档）；tick 由 `spawn` 执行，见待验证假设 #2 |
| 5 | `src/CronCompiler.cj` | .cj | ✅ | 静态正则 + 共享缓存（上限 4096）成立；见 `0/n` 语义、>7 字段越界两条 |
| 6 | `src/CronCompiler_test.cj` | .cj | ✅ | 无断言（只 `println`）；`:39-41` 空循环属死代码 |
| 7 | `src/CronData.cj` | .cj | ✅ | `matches` 的 `L` 分支与区间/步长判定正确（逐一核对 `start`/`end`/`duration` 边界） |
| 8 | `src/CronDataCollection.cj` | .cj | ✅ | `matches` 对「空 datas ⇒ 全通配」的处理正确；`put` 系列可变但与共享缓存隔离 |
| 9 | `src/CronTask.cj` | .cj | ✅ | `extract<T>` 两份重复；`DelayedTicktockTaskImpl.delay` 每次访问都 `Duration.parse`（`f_data` 扩展，import 不是死引用） |
| 10 | `src/CronTicktockTaskDef.cj` | .cj | ✅ | 仅 `prop cron`，无逻辑 |
| 11 | `src/Currently.cj` | .cj | ✅ | `TicktockUnit` 的实现契约，经接口分发（`TicktockIndex` 调 `u.current`），非死代码 |
| 12 | `src/DefaultTicktockTaskExecuting.cj` | .cj | ✅ | `executing()` 带写副作用，见 §12/§11 条；`static var` 可改 `let`（并入该条） |
| 13 | `src/DelayedPeriodic.cj` | .cj | ✅ | 两值枚举，无逻辑 |
| 14 | `src/DelayedTicktockTask.cj` | .cj | ✅ | `cron` 秒级截断（严重项）；`run()` 复制记账骨架（§2 条） |
| 15 | `src/Emitter.cj` | .cj | ✅ | `sealed interface`，仅 `Ticktock` 实现，无死代码 |
| 16 | `src/FuncCronTicktockTask.cj` | .cj | ✅ | 参数拼写 `concurrenctly`；`isExecuting`/`toReset` 默认闭包捕获 `taskName`，与 `name` 一致 |
| 17 | `src/FuncInvocationTask.cj` | .cj | ✅ | 可变字段无同步、`setName` 破坏注册键（一般项）；仓内零引用（对外 API，不判死代码） |
| 18 | `src/Launcher_test.cj` | .cj | ✅ | 12 个任务类只被注释代码引用；`test10` 后 `shutdown()` 使 `test11-13` 等满 30s |
| 19 | `src/TestCurrently_test.cj` | .cj | ✅ | 只被注释用例引用；`public var cur` 无同步 |
| 20 | `src/Ticktock.cj` | .cj | ✅ | 本部分主要缺陷集中地（候选重复、immediate、once 删除、shutdown、0/n 注释） |

合计：`.cj` 17 个 / `.md` 3 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 4（候选重复执行、延迟 cron 秒截断、once 误删、immediate 绕过记账）；设计 2（任务契约与记账耦合在 `executing`、`Ticktock` 兼注册表/索引/执行三职）；语言特性 2（`ConcurrentHashMap.addIfAbsent` 副作用被当成查询、`Timer.after` 返回值自动 `Some` 的语义已核对正确）；可读性 1（`|| return` 写法、`if (let list <- ...)` 不可失败绑定）。安全性：无外部输入面、无凭据，cron 文本只做正则匹配与整型解析，未见注入点 |
| §1 死代码 | 1 | 逐个 `private`/`internal`/`protected` 符号全仓检索：`Ticktock.addOrReplaceDelayTask0`/`register`/`executeOne`/`swapIfNone`/`doRegister`/`getTasksFromBeanFactory`/`getDelayedTasksFromBeanFactory`、`Chrono.start/shutdown`、`DefaultTicktockTaskExecuting.executing/reset`、`CronCompiler.compileShared/parsePart/putCronc` 均有调用者；`public open class TicktockTask`（非 sealed）的 `protected run()` 属扩展点豁免；`protected var function`（`FuncInvocationTask`）同为扩展点。命中：12 个 `LauncherTestTask*` + `TestCurrently` + `CronCompiler_test` 空循环（合并 1 条）。`TicktockTask.==` 里 `case _ => false` 在仓内唯一的实现链（`TicktockTask` 及其子类都是 `class`，属 `Object`）下不可达，并入该条说明，不单独计数 |
| §2 重复逻辑 | 2 | 已把 20 个文件的函数体压成「输入→输出→副作用」逐对比对：`CronTicktockTaskImpl.extract` vs `DelayedTicktockTaskImpl.extract`（逐行相同，仅类型不同）；`TicktockTaskDef` 4 个默认成员 vs `TicktockTask` 覆盖（逐行相同）+ `DelayedTicktockTask.run` 记账骨架（差异：已在执行且不可并发时调 `nextCall()`，已在条目里点名该语义差异，不合并）。`removeTask(task)`/`removeTask(name)`、`getTasksFromBeanFactory`/`getDelayedTasksFromBeanFactory`、`addOrReplaceDelayTask`→`...0` 属单行转发，未计为重复 |
| §3 空实现 | 0 | `Chrono.init() {}` 是「字段已有初值」的空构造，`CronTicktockTask` 空类体是抽象基类，`LauncherTestTask10.execute()` 是测试桩（其用例只验异常路径）——三者都不承诺行为，不判空实现。本部分没有 `TODO`/`FIXME`、没有 `catch {}` 静默吞异常；`emit` 的两处 `catch` 都 `LOGGER.warn`，`addOrReplaceDelayTask0` 的异常无人接管已按「一般」单列。`if (let list <- taskGetter() && ...)` 是不可失败绑定（不是空实现），并入可读性 |
| §4 栈溢出 | 0 | 无递归：`CronCompiler.compile` 是单层 `for`，`CronDataCollection.matches` 两层 `for`，`TicktockIndex` 全迭代；无自引用结构、无 `clone`/深拷贝、无递归打印 |
| §5 OOM | 0 | 无界容器检查：`sharedCache` 有 4096 上限（`CronCompiler.cj:42`、`:57-59`）；`entries`/`freeIds`/`idByName` 与任务数同阶且有 id 复用；`executingMap` 每条执行必有 `reset` 对称删除；`emit` 的 `batch` 与 `candidateIds` 每 tick 复用/重建，规模受候选数限制。无按不可信长度预分配、无 `readToEnd` |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof`/`cjpm bench` 原始数据；`doc/性能基准测试与优化方案.md` 的实测属模块级（场景 A/B、M1），未给出 `emit`/`removeId` 的 self-time 占比，故热点结论不成立，只列入待验证假设 #1-#3 |
| §6.2 大粒度锁 | 0 | `indexLock` 临界区内只有索引查询 + 一次 `entries[id]` 拷贝（`Ticktock.cj:238-246`），`matches`、`spawn`、日志都在锁外；`register` 把 `compileShared` 放在锁外（实参先求值，`:202`）。无锁内 I/O / 回调 / `spawn().get()`。`removeId` 的 O(194) 扫描是「临界区内的 CPU 工作」而非阻塞动作，已归入优化方案 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立刻 `get()`；`emit` 先收集 `batch` 再统一 `spawn`，任务之间并行；`indexLock` 只串行「候选计算」这一段（微秒级，无数据）。命中任务串行执行的怀疑见待验证假设 #2/#3 |
| §6.4 低效算法 | 0 | 无双层匹配循环（索引用值桶）、无热点 `contains`、无 `remove(at:0)` 当队列（`freeIds` 从尾部取）、无循环内字符串拼接；`CronCompiler` 的 18 项字符串比较是常量级。`removeId` 的全桶扫描属「常数大」而非复杂度问题，已进优化方案 |
| §7 降堆内存方案 | 1 | 延迟任务每周期重建 `TicktockEntry` + 重写桶（无基线） |
| §8 降 CPU 方案 | 1 | `removeId` 全桶扫描改按记录摘除（无基线） |
| §9 local mode 可行性 | 0 | 候选只有 `emit` 的 `batch`（`Ticktock.cj:237`），但元素是 `TicktockEntry` 引用、会经 `spawn` 闭包逸出到执行线程，不满足逃逸约束；`candidateIds` 是成员复用缓冲，生命周期跨函数，也不适用。`CronCompiler.compile` 的临时 `ArrayList` 会作为返回值逃逸。无峰值内存数据，结论：不成立 |
| §11 现有代码的 BUG（存量） | 9 | 均为存量：候选重复执行、延迟 cron 秒截断、immediate 绕过记账、once 误删同名新任务、`executing` 写副作用与文档不符、shutdown 不可恢复、`FuncInvocationTask` 可变状态、`0/n` 与注释不符、>7 字段抛错类型不符。逐条核对了边界（`start`/`end`/`duration` 的 0 与越界、`freeIds` 空/非空、`idByName` 命中/未命中）与空值路径（`entries[id]` 的 `None` 分支、`idByName.get` 的 `None` 分支） |
| §12 并发安全与锁粒度 | 4 | 已列出共享路径与同步手段：① `entries`/`freeIds`/`idByName`/index 由 `indexLock` 保护，`emit` 只在锁内取快照、锁外执行 —— 安全；② `TicktockTask.stamped` 是 `AtomicInt64`、`executingMap` 是 `ConcurrentHashMap` —— 安全；③ `FuncInvocationTask` 的可变字段（无同步，一般项）；④ `TicktockTaskDef.executing` 的「查询+占位」复合语义（一般项）。另：`Chrono` 每 tick `spawn { emit }` 使相邻 tick 可能乱序（待验证假设 #2），`spawn` 前已捕获 `now` 故不影响匹配基准；`instance_` 的 CAS 分支在 `mutex` 内不可能失败，`swapIfNone` 的失败分支（`:93-96`）实为不可达防御代码（并入 §1 说明） |
| §14 功能完备性与 README 覆盖 | 2 | ① README 把 `'500ms'` 当推荐 delay 写法，实际永不触发（与严重项同源）；② README「其他公开 API」漏列 `removeTask` 等（轻微）。另核对：`@TicktockTasks`/`@CronTask`/`@DelayedTask` 与「类名#方法名」约定在 `src/macros/TicktockTasks.cj:72-73` 确有其实现（宏本体属第 2 部分）；`TicktockInitializer` 存在并随 `f_app` 注册（第 2 部分）；`FuncInvocationTask`/`FuncInvocationCronTask` 仓内零引用但在 README 公开 API 表中，属对外能力，不判缺失 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完（17 `.cj` + 3 `.md`）；模块内 `TicktockIndex.cj` / `TicktockUnit.cj` / `TicktockInitializer.cj` / `Trigger.cj` / `imports.cj` / `macros/**` / 其余测试属第 2 部分，本部分仅按调用链查阅其实现以取证（`TicktockIndex.collect`、`TicktockUnit.values`），不计入本部分覆盖 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 7 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

本部分 16 条发现全部为存量（工作区快照无 diff 基线，逐条已给 `git blame` 依据），是否纳入修复待用户决定；「待验证假设」3 条不计入统计，不进 `todo.md` / `tasks.md`。

## 总评

调度主干是清晰的：`Chrono` 用 `Timer.after` 的「回调返回值即下次延迟」实现绝对秒对齐的 tick（已对照 std 文档确认 `Duration` 会被包成 `Some` 从而自动重排，不是一次性定时器），`emit` 把候选筛选放在锁内、匹配与执行放在锁外、异常按任务隔离，`CronCompiler` 的静态正则 + 表达式驻留（上限 4096）与 `TicktockIndex` 的「只排除、不判定」设计都成立，索引改造的收益也有文档实测支撑（10 万稀疏任务运行期 CPU 118.21s → 0.36-0.46s/60s）。锁粒度在注册表侧做得比多数同类实现好：`indexLock` 只保护「索引 + 条目快照」，`compileShared` 在锁外。

**阻塞项两条**：① 索引候选缓冲不去重，使 `|` 多表达式任务在同一 tick 执行两次 —— 这是静默的业务重复执行（重复扣款/重复通知量级），且是索引改造引入的回归，必须在合并前修掉并补对拍用例；② 延迟任务的 cron 由 `now + delay` 的秒级字段拼成，README 推荐的 `500ms` 延迟**永不触发**、整秒延迟最多提前近 1 秒 —— 对外承诺的延迟语义不成立，需要改调度结构或在入口显式拒绝亚秒 delay。

**可排期**：`immediate` 分支绕过 `run()` 的记账与异常隔离、`once` 后按名删除可能误删同名新任务、`executing()` 的「查询即占位」语义陷阱、`shutdown` 不可恢复（测试顺序依赖已能看到后果）、`FuncInvocationTask` 的可变状态，都属「不常触发但一旦触发很难定位」，建议随下一个小版本一起收敛。`0/n` 与注释不符、>7 字段抛错类型不符是需要先定预期的契约问题。轻微项集中在测试死代码、两份 `extract` 重复、README 示例不可编译与性能文档附录过期，清理成本低。性能侧本轮不做结论：模块级基线在文档里，`removeId`/`emit` 级的自耗时占比没有数据，两条优化只作待验证假设。
