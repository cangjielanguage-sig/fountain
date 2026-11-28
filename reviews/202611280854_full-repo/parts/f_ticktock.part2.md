# f_ticktock 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_ticktock`（本部分 14 个文件：14 个 `.cj` + 0 个 `.md`；模块合计 31 个 `.cj` + 3 个 `.md`，`.md` 与 `Ticktock.cj` / `CronCompiler.cj` / `CronData*.cj` / `Chrono.cj` 等在第 1 部分）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 基线；模块最近提交 `e66046232 2026-11-27 test(f_ticktock): 补齐 TicktockTasks 注解任务用例并放宽年份步长`，仓库 HEAD `97507061b` 只是审查流程提交）
- **审查重点**：定时调度语义（`Timer.after` 回调返回值即下次延迟、`Some` 自动重排）、时间轮/候选索引正确性、并发安全与锁粒度、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件仅为分报告，模块报告由主 Agent 合并 `parts/f_ticktock.part1.md` 后产出）
- **审查环境**：Windows 侧只读代码，未跑 `cjpm build` / `cjpm test`；本报告所有结论均来自源码与本地官方文档核对

## 发现

### [一般][存量] 测试阻塞等待没有总超时：`waitEntered` 超时后原地重等，用例可永久挂起

- **位置**：`f_ticktock/src/TicktockIndex_test.cj:483-489`（`IndexBlockingTask.waitEntered`）、`:476-480`（`execute` 里 `while (!released) releaseCondition.wait()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 资源不对称）+ §3（用例实际不产生判定）；API 语义核对 `std/sync/sync_package_api/sync_package_classes.md:8534-8549`——`Condition.wait(timeout!)` 返回 `Bool`（被唤醒 `true` / 超时 `false`），超时不抛异常
- **证据**：静态确定 —— `waitEntered(timeout: 5s)` 的循环条件是 `while (!entered_)`，`wait` 的返回值被丢弃；每次超时返回后条件依旧为假，于是重新等 5 秒，永不返回
- **描述**：若任务没有进入 `execute`（注册失败、`emit` 未命中、被测代码被改坏），`testNonConcurrentableSkipsWhileRunning` 会卡在 `waitEntered` 而不是失败；随后 `task.release()` 不会执行，`execute` 里无超时的 `releaseCondition.wait()` 也让 spawn 线程永久阻塞，`cjpm test` 无法退出（本地只能靠 Ctrl-C，CI 上按超时被杀，拿不到断言信息）
- **建议**：改成 deadline 循环（`while (!entered_ && DateTime.now() < deadline) { if (!cond.wait(timeout: remaining)) { break } }`），超时后 `@Fail` 给出明确原因；`execute` 的 release 等待加超时，或把 `release()` 放进 `finally` / `@AfterEach` 保证异常路径也会解锁

### [一般][存量] `TicktockLauncher_test.test` 无任何断言，固定睡 3 分钟并关闭进程级单例

- **位置**：`f_ticktock/src/TicktockLauncher_test.cj:22-28`（用例体）、`:31-45`（任务类 `println`）
- **来源**：存量
- **判据**：review-checklist §3（用例无可判定行为）+ §11（测试隔离）；对照 `Ticktock.cj:292-294`、`Chrono.cj:45-48`（`shutdown` 只 `timer.cancel()`，不清 `instance_`）
- **证据**：静态确定 —— 用例注册任务后 `sleep(Duration.minute * 3)`，再 `launcher.shutdown()`，全程没有 `@Assert`；唯一可观测输出是 `execute` 里的 `println`
- **描述**：这个用例证明不了任何东西（任务是否触发、触发几次都没断言），却让每次 `cjpm test` 固定多 3 分钟；`shutdown()` 关掉的是 `Ticktock.instance` 这个进程级单例的节拍线程，同进程内后续依赖后台 tick 的用例会因执行顺序不同而结果不同
- **建议**：删除，或改成「注册 → 显式 `emit` 一个确定时刻 → 用 `AtomicInt64` 断言执行次数」；不要关闭全局单例（真要覆盖 `shutdown`，用独立实例或把它放到最后一个用例并注释说明顺序依赖）

### [一般][存量] 索引对拍用例用 `HashSet` 吸收重复，结构上无法发现「同一任务被收集两次」

- **位置**：`f_ticktock/src/TicktockIndex_test.cj:130-147`（`:132-135` 把 `buffer` 灌进 `HashSet` 后再断言 `contains`）；被测实现 `f_ticktock/src/TicktockIndex.cj:189-206`（`collect` 依次追加 `always` / 值桶 / `wildcard` / `dynamic`，无去重）
- **来源**：存量
- **判据**：review-checklist §11（用例未覆盖真实不变量）+ §14（验收口径不足）；对应缺陷为第 1 部分「[严重] `|` 多表达式任务在同一 tick 被候选缓冲重复收集」
- **证据**：静态确定 —— 断言写成「命中集合 ⊆ 候选集合」，而候选集合先被 `HashSet` 去重；`buffer` 的长度、相邻重复都没有断言
- **描述**：`collect` 的四组集合可以重叠：① 同一任务的两个 `|` 分支一个全通配（进 `always`）、一个约束某单位（进值桶或 `wildcard`）；② 分支 A 约束单位 u（进 `buckets[u]`）、分支 B 不约束 u（进 `wildcard[u]`）；③ 年字段同理（`dynamic[6]` 与 `wildcard[6]`）。任一形态都会让同一 id 在 `buffer` 里出现两次，`Ticktock.emit` 不去重 → 同一 tick `spawn` 两次。本用例的 `EXPRS` 里第 15 条（`TicktockIndex_test.cj:85`）正是 `"1/3-45 * * * * * | 0 0 3 29 2 *"`，本可复现，但被 `HashSet` 吸收掉了
- **建议**：补断言 `@Assert(buffer.size, candidates.size)`（或对 `buffer` 排序后检查相邻不等），并新增「全通配 + 具体表达式」组合用例；修复侧见第 1 部分严重项，建议在 `collect` 入口按 id 去重（或 `emit` 的 `batch` 改 `HashSet<Int64>`）

### [轻微][存量] 死代码：`Trigger` 接口全仓零引用、零实现，且与 `Emitter` 职责重叠

- **位置**：`f_ticktock/src/Trigger.cj:20-26`
- **来源**：存量
- **判据**：review-checklist §1（无调用者 / 兼容残留；`sealed` 接口只能在包内实现，本包内没有任何实现者 ⇒ 该接口永远不可能有实例）
- **证据**：静态确定 —— 全仓搜 `Trigger` 只命中定义处；`Chrono.start(emitter: Emitter)`（`Chrono.cj:25`）与 `Ticktock <: Emitter`（`Ticktock.cj:55`）用的是 `Emitter.cj:18-20` 的 `emit(now: DateTime)`
- **描述**：`Trigger.emit(task: TicktockTask, now: DateTime): Bool` + `shutdown()` 是更早一版「一个 tick 内判断+执行」的设计残留，签名与现行 `Emitter` 不是同一套语义（现行是「tick 只 emit 时间，命中才 spawn」）；留着会让读者误以为存在第二种驱动方式
- **建议**：删除该文件

### [轻微][存量] 死代码 + 潜在溢出：`TicktockUnit.wheelSize()` 与 5 参 `init` 的 `rangeBase`（旧时间轮残留）

- **位置**：`f_ticktock/src/TicktockUnit.cj:215-217`（`wheelSize()` 返回 `range.end + 1`）、`:30`（`YEARLY` 的 range 上界是 `Int64.Max`）、`:37-51`（5 参 `init` 的 `rangeBase`）与 7 个子类的同名 5 参 `init`（`:224`、`:238`、`:252`、`:266`、`:283`、`:296`、`:340`）
- **来源**：存量
- **判据**：review-checklist §1（`TicktockUnit` 顶层未标 `public`，按 `package/toplevel_access.md:21` 默认 `internal`，其 `public` 成员对外不可达 ⇒ 仓内零引用即死代码；`rangeBase` 为未使用参数）+ §11（边界溢出）；溢出语义核对 `docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md:5`（算术结果会被检测并禁止值溢出）
- **证据**：静态确定 —— 全仓 `wheelSize` 只在定义处命中、`rangeBase` 除定义与 `super(...)` 转发外只有 `0` 这一个实参（`:38`、`:222`、`:236`、`:250`、`:264`、`:281`、`:294`、`:338`）；`YEARLY` 的 `range.end == Int64.Max`，`range.end + 1` 必抛
- **描述**：两者都是「时间轮槽=range.end+1、槽位可按 rangeBase 平移」这版设计的残留：现在索引按值桶工作，不需要槽数也不需要平移。`wheelSize()` 零调用还会掩盖一个问题——任何人按名字拿 `YEARLY` 的槽数都会撞 `Int64.Max + 1`；另外它没写返回类型（public 推断 `Int64`），也没进 README 的 API 表
- **建议**：删除 `wheelSize()` 与 5 参 `init`（统一 4 参、去掉 `rangeBase` 和 `@OverflowSaturating` 的 `newRange` 平移）；若确实要保留槽数语义，改成 `range.end - range.start + 1` 并显式声明返回类型

### [轻微][存量] 死链：`TicktockUnit.convert` / `YearlyTicktockUnit.convert` 唯一调用者是零调用的 `CronData.convert`

- **位置**：`f_ticktock/src/TicktockUnit.cj:110-112`（基类 `convert`）、`:343-350`（`YearlyTicktockUnit` 覆盖，`last=true` 抛异常）；唯一调用点 `f_ticktock/src/CronData.cj:63-66`
- **来源**：存量
- **判据**：review-checklist §1 硬原则二（`TicktockUnit` 顶层默认 `internal`，见 `package/toplevel_access.md:21`，其 `public` 成员全项目无使用即死代码）
- **证据**：静态确定 —— 全仓 `.convert(` 的命中只有这三处定义/转发；`CronData.convert` 本身也没有任何调用者；`L` 用在年字段的拒绝已由 `CronData.cj:37-39`（私有构造）与 `:47-49`（`createLast`）覆盖
- **描述**：整条 `convert` 链不可达：基类原样返回、`Yearly` 的抛错分支永远不会被执行；`TicktockUnit.convert` 声明成 `public open` 也没有任何多态调用点
- **建议**：删除 `TicktockUnit.convert` 与 `YearlyTicktockUnit.convert`；`CronData.convert` 是对外 API，删不删需用户拍板，若要保留就在注释里说明它没有运行期调用方

### [轻微][存量] 测试遗留：未使用的任务类 + 4 个未使用常量 + 无用 import

- **位置**：`f_ticktock/src/TicktockTaskTest_test.cj:18`（`import std.unittest.testmacro.*` 未使用）、`:20-33`（`TicktockTaskTest` 类无人构造、无 `@Test`）；`f_ticktock/src/TicktockTasks_test.cj:39`、`:45`、`:51`、`:57`（4 个 `let` 常量）
- **来源**：存量
- **判据**：review-checklist §1（无调用者 / 未使用 import）
- **证据**：静态确定 —— 全仓 `TicktockTaskTest(` 零命中；`TICKTOCK_TASKS_TWO_CRON` / `..._MIXED_CRON` / `..._NON_UNIT_CRON` / `..._ONCE_CRON` 只在定义行命中（对应注解里写的是同值字面量，如 `:106` 的 `"2 3 4 29 2 * 2032"`）
- **描述**：`TicktockTaskTest` 是早期夹具（`println("success")`），已被 `TicktockTasks_test` 里的 `@TicktockTasks` 样本类取代；4 个常量本意是「表达式与时刻成对」，但只在 `..._TIME` 一侧被用，字符串一侧退化成注释，读者会以为注解引用的是常量
- **建议**：删除 `TicktockTaskTest_test.cj`；4 个常量要么删掉、要么在注释里指明「注解参数必须是编译期字面量，故此处保留字面量并删除常量」

### [轻微][存量] 重复逻辑：`convertRange` 与 `convertDuration` 的边界校验几乎逐行相同

- **位置**：`f_ticktock/src/TicktockUnit.cj:130-148`（`convertRange`）与 `:181-201`（`convertDuration`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 字面量复制：同一套边界判定，只有消息文案与个别条件不同）
- **证据**：静态确定 —— 两处都是 `end == 0` → `start > range.end` → `end > range.end` →（`duration == 0`）→ `start > end` → `start < range.start` → `end < range.start` 的同构链，抛的都是 `IllegalArgumentException`，文案模板一致
- **描述**：差异只有三处：`convertRange` 多一步 `oneStart && start == 0 ⇒ begin = 1`；`convertDuration` 多一条 `duration == 0`；`convertRange` 在 `:172-176` 又把同样的区间检查用 `where` 重做了一遍。两份校验各自演进，新增时间单位或调整边界时容易只改一处
- **建议**：抽成 `private func checkBounds(unitName: String, begin: Int64, end: Int64, duration: Option<Int64>): Unit`，`oneStart` 归一化放在调用前；删除 `:172-176` 的二次检查（`convertRange` 已保证）

### [轻微][存量] 用例注释与实现不符：称「4 位年份无法通过表达式编译」

- **位置**：`f_ticktock/src/TicktockIndex_test.cj:242-244`
- **来源**：存量
- **判据**：review-checklist §13（注释/文档与实现漂移：给出两边位置）
- **证据**：静态确定 —— `CronCompiler.cj:35-38` 已有 `DURATION_RANGE_YEAR` / `DURATION_YEAR` / `RANGE_YEAR` / `SINGLE_YEAR` 四组 `\d{4}` 正则，`:98`、`:113`、`:125`、`:142` 对 `i == 6` 放行；`TicktockTasks_test.cj:268-271` 直接编译 `"1 2 3 29 2 * 2032"` 并断言命中，`:276-286` 还覆盖了 `2030/2` 与 `2030,2032`
- **描述**：该注释让后读者以为「年字段只能手工构造 `CronDataCollection`」，于是这个用例绕开 `CronCompiler` 手搓数据；实际 `compile` 已支持 4 位年份，用例既没覆盖编译路径，也留下了错误说明
- **建议**：删掉该说明，改用 `CronCompiler.compile("... 2030")` 构造；同时保留「索引对年约束取保守候选」的断言

## 与第 1 部分的交叉引用（不重复计数）

- **重复候选导致同 tick 执行两次**：第 1 部分已作为「严重」项报出（`Ticktock.cj:238-266` + `TicktockIndex.cj:189-206`）。本部分独立复核了产生条件（`always`/值桶/`wildcard`/`dynamic` 四组集合跨 `|` 分支重叠），并补充了「对拍用例用 `HashSet` 去重导致该缺陷不可见」（本部分「一般」第 3 条）。
- **`TicktockUnit.valueOf(value)` 越界**：第 1 部分「一般」项已报，位置 `TicktockUnit.cj:57-59` 属本部分文件，此处不重复。
- **`TicktockIndex.removeId` 全桶扫描**：第 1 部分优化项已报，不重复。
- **范围外提示（第 1 部分文件）**：`CronCompiler.cj:137` 的 `if (range.size == 3)` 恒假——`convertRange(start, end)` 最多返回 2 段（`WeekDailyTicktockUnit.convertRange` 的 `:307-318`），而 `convertRange` 分支只在 `size == 3` 时写第 2 段，因此这条路径上的第 2 段永远不会被 `put`（`convertDuration` 走的是 `putCronc` 的 `size > 1`，不受影响）。该分支属第 1 部分，未计入本部分统计。

## 优化可行性方案

### [堆内存] 索引桶位图化（对应性能文档 M2，本次未实施）

- **现状**：`TicktockIndex` 为每个「单位 × 取值」维护一个 `HashSet<Int64>`（`TicktockIndex.cj:54-56`、`:168-177`）。性能文档实测：10 万稀疏任务下索引额外占用 **+59.2 MiB（≈620 B/任务）**（`doc/性能基准测试与优化方案.md` §6.7 M2 的 `hwm 533524 → 594128 kB`）。最坏形态是宽区间表达式（如秒字段 `1-59`，不是 `min-max` 因而不会被 `CronCompiler.cj:88-96` 折叠成 `*`），单任务最多可写入 60+60+24+31+12+7 ≈ 194 个桶条目
- **方案**：把 `wildcard[unit]` / `dynamic[unit]` / `buckets[unit][value]` 的 `HashSet<Int64>` 换成按任务 id 的位图（每单位一张 `Array<UInt64>`，值桶按值分段），`collect` / `keep` / `sizeAt` 改为按字 AND/OR 与位测试；`removeId` 改为清位（比 `HashSet.remove` 更便宜）
- **预期**：文档估算 7 张 100k 位位图 ≈ 88 KB（稀疏形态），相对 59.2 MiB 减少约 99.8%；密集形态按「桶内元素数 × 取值个数」自适应切换到有序 `Int64` 数组。运行期候选求交在密集命中时也会变快（按字 AND 代替迭代 `HashSet`）
- **代价**：`candidates` 需要把置位字展开成 id 列表（与现在遍历 `HashSet` 等价，常数更小）；实现量中等；`entries`/`freeIds` 的 id 复用上限（`Ticktock.cj:119-124`）决定位图长度，删除任务后位图不缩短（与现在空 `HashSet` 残留一致）
- **验证**：`TicktockIndex_test` 的等价性对拍 + 新增「候选唯一性」断言；10 万任务两种形态（稀疏 `0 0 3 29 2 *`、宽区间 `1-59 * * * * *`）注册前后 `getAllocatedHeapSize()` / RSS 对照，`-O2`、同 SDK、同机器，取三次中位数
- **证据状态**：现状占用**已有基线**（文档实测 +59.2 MiB / 10 万任务）；位图改造收益**无基线（待验证，不进 tasks）**

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次执行都走一次反射取任务名（`name` → `ClassTypeInfo.of(this).qualifiedName`），10 万每秒任务即 10 万次/秒，占「记账 3.5 µs/次」的一部分 | `f_ticktock/src/TicktockTask.cj:68-72`、`:79-81`；`DefaultTicktockTaskExecuting.cj:24-26` | `name` 获取在单次执行成本中的占比 | 在 `frame_base` 场景（文档 §6.3）加开关：改前 `qualifiedName` vs 改后构造期缓存 `private let defaultName`，同进程 60 s 对照，`cjprof` 看 `ClassTypeInfo.of` 自耗时 |
| 2 | `TicktockUnit.values` 每次访问都新建 7 元素 `Array`，注册期每个字段一次（10 万任务 × 7 字段 = 70 万次分配） | `f_ticktock/src/TicktockUnit.cj:52-56`（`CronCompiler.cj:86` 每个字段调 `valueOf`） | 该分配的 GC 占比、注册 CPU 占比 | 注册 10 万任务时 `cjprof heap` 统计 `Array` 分配次数；或把 `values` 改静态 `let` 后对比注册 wall/CPU（三次取中位） |
| 3 | `testConcurrentAddRemoveWhileEmitting` 的 800 ms 静止窗口在高负载 CI 上不足，可能出现「移除后又被执行」的偶发失败 | `f_ticktock/src/TicktockIndex_test.cj:357-397`（`:375`、`:388` 的 `sleep`） | 失败率 | 同一机器连续跑 50 次该用例，统计失败次数与失败时的 `executed` 差值 |
| 4 | `TicktockIndex` 用 `HashMap<Int64, …>`（7 个单位）而不是按下标数组，每 tick 多付常数次哈希；在「候选≫命中」形态下是否有可测占比 | `f_ticktock/src/TicktockIndex.cj:53-60`、`:139-166` | 每 tick 候选计算的绝对耗时与占比 | 500 个 `* * * L * *` 任务（文档 §6.5 场景）跑 60 s，`cjprof` 看 `candidates`/`sizeAt` 自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_ticktock/src/TicktockIndex.cj` | .cj | ✅ | 值桶/`wildcard`/`dynamic`/`always`/`trivial` 语义逐条核对；重复候选来源见「一般」第 3 条与第 1 部分严重项；索引访问全在 `Ticktock.indexLock` 内，见 §12 行 |
| 2 | `f_ticktock/src/TicktockIndex_test.cj` | .cj | ✅ | 对拍/`L`/年约束/`once`/不可并发/同名替换/并发增删 7 组用例；阻塞等待与 `HashSet` 去重两条问题，注释过期一条 |
| 3 | `f_ticktock/src/TicktockInitializer.cj` | .cj | ✅ | 只注册 `Ticktock.loadTasks()`，`name`/`dependencies` 与 `f_app` 的 `Initializer` 契约一致（`f_app/src/Initializer.cj:21-45`）；无死代码 |
| 4 | `f_ticktock/src/TicktockLauncher_test.cj` | .cj | ✅ | 无断言的 3 分钟用例（「一般」第 2 条）；`CronTicktockTaskTest` 被该用例使用，不算死代码 |
| 5 | `f_ticktock/src/TicktockTask.cj` | .cj | ✅ | `run()` 的记账/并发语义已核（`executing` 的写副作用与 `once` 组合见第 1 部分）；`name` 反射调用列入待验证假设 #1 |
| 6 | `f_ticktock/src/TicktockTaskDef.cj` | .cj | ✅ | 接口默认实现与 `TicktockTask` 覆盖逐行相同，第 1 部分「重复逻辑」已报，不重复 |
| 7 | `f_ticktock/src/TicktockTaskTest_test.cj` | .cj | ✅ | 零引用夹具 + 无用 import（「轻微」测试遗留） |
| 8 | `f_ticktock/src/TicktockTasks_test.cj` | .cj | ✅ | 宏端到端用例（注册/触发/once/混合/立即执行/非 Unit 返回值/extract）；4 个未使用常量；`HashMap`/`lookup`/`BeanFactory` 的 import 是宏展开所需（`:18-19` 已注释说明） |
| 9 | `f_ticktock/src/TicktockUnit.cj` | .cj | ✅ | 7 个单位常量、`range`/`lastRange`/`oneStart` 语义、工作日 0 的三种转换逐条核对；`wheelSize`/`rangeBase`/`convert` 三项死代码，校验重复一条 |
| 10 | `f_ticktock/src/TicktockUnit_test.cj` | .cj | ✅ | 只覆盖 SECONDLY / MONTH_DAILY / WEEK_DAILY 的 `convertDuration`/`convertRange`；MONTHLY/HOURLY/YEARLY 与 `last()` 未直接覆盖（`L` 语义由 `TicktockIndex_test` 间接覆盖），不单列发现 |
| 11 | `f_ticktock/src/Trigger.cj` | .cj | ✅ | 零引用、零实现的 `sealed interface`（「轻微」死代码） |
| 12 | `f_ticktock/src/exception/TicktockException.cj` | .cj | ✅ | 4 个构造转发 `BaseException`，public 类属对外契约；无逻辑 |
| 13 | `f_ticktock/src/imports.cj` | .cj | ✅ | `public import` `HashMap` / `lookup` 是为宏展开后的下游代码备的名字（解释写在 `TicktockTasks_test.cj:18-19`，本文件无注释）；属可读性，不单列 |
| 14 | `f_ticktock/src/macros/TicktockTasks.cj` | .cj | ✅ | `expand(Decl)` 的注解包装剥离、方法表生成、`map[n]` 取值域与 `extract` 一致（`std/reflect` 的 `instanceFunctions` 只返回 **public** 实例函数且不含继承成员，`reflect_package_classes.md:13072-13090`）⇒ 不存在「私有方法注解导致 `map` 缺键」；非 public/带参/static 的注解方法被静默忽略（README:127 已声明该约束，不列为缺陷） |

合计：`.cj` 14 个 / `.md` 0 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 2（测试永久等待、索引对拍无去重断言）；可读性 0（命名与 `rangeBase`/`wheelSize` 归入死代码项）；设计 1（`Trigger` 与 `Emitter` 双驱动语义并存，已并入死代码项）。语言特性：`@Frozen` 是「实现冻结承诺」而非「禁止覆盖」（`Macro/builtin_compilation_flags.md:91-103`），与 `open` 同用不矛盾，未报；`@OverflowSaturating` 只包住 `newRange` 的平移，实际 `rangeBase` 恒 0，不构成溢出隐藏。安全性：本部分无外部输入面、无凭据、无 SQL/命令拼接，cron 文本只做正则匹配与整型解析 |
| §1 死代码 | 4 | 逐个符号搜过：`TicktockIndex`/`TicktockEntry`/`TicktockIndex.add/removeId/candidates/put/sizeAt/collect/keep/filterInPlace`、`TicktockInitializer`（经 `InitializerCollection.register`）、`TicktockTask.stamped/run/hashCode/==/!=`、`TicktockTaskDef` 全部成员、`TicktockException` 4 个构造、宏的 `expand`/`unwrapAnnotated`/`public import Bean` 均有使用或属接口实现/对外可达 public；`protected range`（sealed 类）被基类自身与子类使用，未判死。命中 4 条：`Trigger`、`wheelSize`+`rangeBase`、`convert` 死链、测试遗留（`TicktockTaskTest` + 4 个常量 + 无用 import）。`convertRange(ArrayList<Int64>)`（`:150-178`）全仓只在 `TicktockUnit_test` 命中，属「仅测试使用」→ 只记可见性建议（可收窄或标 `@TestOnly`），不计死代码。（`TicktockUnit` 未标 `public`，本行按文档默认 `internal` 判定；若编译器实际将其导出，`wheelSize`/`convert` 两条按硬原则一降为「对外 API 仓内零引用」，级别仍是轻微） |
| §2 重复逻辑 | 1 | 14 个文件的函数体逐对压成「输入→输出→副作用」比对：`convertRange`/`convertDuration` 校验链同构（已报）；`TicktockUnit` 7 个子类的 `init` 是必需的单行委托（不算重复）；`TicktockTask` 覆盖与接口默认实现逐行相同（第 1 部分已报，不重复）；`IndexCountingTask`/`IndexOnceTask` 只差 `once` 一个 prop（测试桩，为可读性刻意独立，不判重复）；`TicktockIndex.collect` 与 `keep` 是「收集 vs 判定」两种语义，不合并 |
| §3 空实现 | 1 | `TicktockInitializer` 的 `private init(){}`、`Chrono.init(){}`（第 1 部分）、`TicktockTasksExtractSample` 里的空方法体都是刻意的测试桩/无参构造，不判；命中 1 条：`TicktockLauncher_test.test` 无任何断言（用例不产生判定）。全部分文件无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 0 | 本部分无递归：`TicktockIndex` 全部是单层/双层 `while` 迭代，宏 `unwrapAnnotated` 是唯一递归函数，深度受注解嵌套层数限制（源码常量级，用户不可能构造循环），`expand(Decl)` 的 `while` 剥包装也是迭代；无自引用结构、无深拷贝 |
| §5 OOM | 0 | 上限核对：`buckets` 的键域固定为 7 个单位 × 值域（60/60/24/31/12/7），单任务最多展开 ≈194 个条目，规模与注册量成正比（见优化方案）；`always`/`wildcard`/`dynamic` 每任务最多各 1 条；`candidateIds` 复用且只受候选数限制；测试里的 `ArrayList<Collection<CronDataCollection>>` 规模是常量。无按不可信长度预分配、无 `readToEnd` |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` 原始数据；`doc/性能基准测试与优化方案.md` 给的是模块级场景数据（场景 A/B、`candidates_sum`），没有 `candidates`/`sizeAt` 的 self-time 占比 ⇒ 热点结论不成立，只进待验证假设 #1/#2/#4 |
| §6.2 大粒度锁 | 0 | `TicktockIndex` 内部无锁，调用方 `Ticktock.indexLock`（`Ticktock.cj:120`）的临界区只有 `candidates` + `entries[id]` 拷贝；本部分的 `removeId`/`add` 也在同一把锁内，临界区内无 I/O、无回调、无 `spawn().get()`。`filterInPlace` 的 `remove(at: size-1)` 是尾部删除，O(1)，不构成锁内长耗时 |
| §6.3 并发串行 | 0 | 生产代码无 `spawn`、无 `Future.get()`；`TicktockTask.run()` 由 `emit` 的 spawn 线程调用，任务之间并行。测试里唯一的 `spawn`（`TicktockIndex_test.cj:366-370`）是并发压测，100 次 `emit` 全部提交后才 `get()` 汇合，不是「spawn 后立刻 get」。被串行的只有 `indexLock` 内的候选计算（微秒级，无数据） |
| §6.4 低效算法 | 0 | 无双层匹配、无热点 `contains`、无 `remove(at: 0)`；`sizeAt` 的 argmin 是 7 次常数比较；`TicktockUnit.values` 的每次分配归入待验证假设 #2（无占比数据，不判低效） |
| §7 降堆内存方案 | 1 | 索引桶位图化（M2），现状占用有文档实测基线，改造收益待验证 |
| §8 降 CPU 方案 | 0 | 没有改前/改后对照，唯一候选（`name` 反射、`values` 分配）都缺占比数据 ⇒ 只进待验证假设，不写成方案 |
| §9 local mode 可行性 | 0 | `candidates` 的临时数据全部写进复用 `buffer`，无函数内大对象可改造；`TicktockUnit.values` 返回的数组被 `TicktockIndex.units_` 长期持有、`convertRange`/`convertDuration` 的结果被 `CronData` 长期持有，都属逃逸 ⇒ 不满足 local region 的「不离开函数」前提；索引里真正的大对象是跨 tick 存活的桶集合，正是 local mode 帮不上的部分。无峰值内存证据，判不可行 |
| §11 现有代码的 BUG（存量） | 5 | 本部分读到的函数边界与空值已逐个核对：`add` 的 `step==0` 不可达（`convertDuration` 拒绝 0）、`c` 集合非空（`put` 必加元素）、`buckets[unit]` 7 个键在 `init` 全部建好、`filterInPlace` 尾部删除不越界、`candidates` 空索引返回空、`last()` 对 YEARLY 不可达（`createLast` 先抛）；`TicktockTask.run` 的跨线程状态是 `AtomicInt64` + `ConcurrentHashMap.addIfAbsent`，未见数据竞争。命中 5 条：测试永久等待、`HashSet` 去重掩盖重复、`wheelSize` 溢出、`Launcher_test` 无效用例、注释过期 |
| §12 并发安全与锁粒度 | 0 | 共享点只有三处：① `TicktockIndex` 的 5 个容器——`add`/`removeId` 只在 `Ticktock.cj:207-226`、`:137-148`（`synchronized(indexLock)`）内调用，`candidates` 只在 `:238-246` 内调用，测试里各自 new 一个索引单线程用，故线程封闭成立；② `TicktockTask.stamped` 为 `AtomicInt64`；③ 跨线程的「是否在执行」由 `DefaultTicktockTaskExecuting` 的 `ConcurrentHashMap.addIfAbsent` + 条件删除保证（写副作用与语义偏差属第 1 部分）。测试夹具 `IndexBlockingTask` 的 `entered_`/`released` 都在各自 `Mutex` 内读写，无条件变量虚假唤醒问题（`wait` 在 `while` 里重查）。无多锁顺序、无锁内回调。锁粒度：`indexLock` 只保护索引与 `entries` 的一致性，`matches`/`spawn`/日志都在锁外，已是最小临界区，不再提优化 |
| §14 功能完备性与 README 覆盖 | 0 | README:107-131 覆盖 `@TicktockTasks`/`@CronTask`/`@DelayedTask` 的用法与「public、非 static、无参」约束（与 `macros/TicktockTasks.cj:61-70` 一致），README:137-146 列出 `TicktockInitializer`/`TicktockException`；本部分文件的 public 声明里，未进 README 的只有已废弃的 `Trigger`（顶层默认 `internal`、死代码）与 `wheelSize`（死代码），不算 README 遗漏。`TicktockInitializer` 已接线（`InitializerCollection.register` + `initialize → loadTasks`），无「承诺未实现」 |
| 文件覆盖（§13 等） | 14/14 | 14 个文件全部读完，无缺失；§13 命中 1 条（`TicktockIndex_test.cj:242-244` 注释过期）。`.md` 属第 1 部分，本部分不重复评 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

> 本部分为模块第 2/2 部分，统计只含本部分 14 个文件；模块级合计需与第 1 部分合并（第 1 部分：严重 2 / 一般 7 / 轻微 7 / 优化 1 + 1）。
> 存量缺陷共 9 条（一般 3 + 轻微 6），是否纳入修复待用户决定。

## 总评

本部分的核心是时间轮索引（`TicktockIndex`）与任务契约（`TicktockTask`/`TicktockTaskDef`）。索引的「只排除、不判定」设计是成立的：`trivial` 只跳过不可能过滤的单位，`always`/`wildcard`/`dynamic` 的并集覆盖了所有不该被排除的任务，`L` 用 `lastRange` 展开是 `matches` 真值集合的超集，逐单位求交的 `keep` 与 `collect` 口径一致，未发现漏命中路径；`removeId` 对 `trivial` 的重算也与「是否还有约束任务」等价。索引的全部访问都在 `Ticktock.indexLock` 内，线程封闭有据。

风险集中在两处。一是**候选缓冲可能含重复 id**：索引四组集合可跨 `|` 分支重叠，`Ticktock.emit` 不去重就会对同一任务 spawn 两次；该缺陷已由第 1 部分定为严重，本部分补充了「对拍用例用 `HashSet` 去重，结构上看不见重复」这一验收缺口——建议修复时同时补上候选唯一性断言，否则回归仍会漏。二是**测试基础设施质量**：唯一涉及阻塞任务的用例超时后原地重等可永久挂起，唯一涉及启动器/节拍的用例没有断言还固定睡 3 分钟并关闭全局单例；这类用例不会让 CI 变红，只会让 CI 变慢和偶发卡死。

其余是陈旧残留：`Trigger` 接口、`wheelSize`/`rangeBase` 的旧时间轮痕迹、`convert` 死链、测试夹具与常量、一处过期注释。都不影响运行期行为，但会持续误导后来者，建议随下一次改动一并清理。整体判断：索引实现可以直接留用；阻塞项是第 1 部分的重复执行问题；本部分的 3 条「一般」属测试可靠性，可与该修复同批处理。
