# f_orm 模块审查报告（第 5/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（全模块 111 个源文件；**本部分覆盖 15 个**：`base/TrsactionHooks.cj`、`base/converter.cj`、`base/imports.cj`、`base/UpdateResult_test.cj` 与 `exception/` 下 11 个异常类，共 609 行）
- **基线**：工作区快照（`git log -1` = `8c0ce643a` 2026-11-28 合并提交；`git status` 仅多出本轮 `reviews/`、`docs/review/`）。快照模式无 diff，本部分发现**全部记为「存量」**，逐条给 `git blame` 依据
- **审查重点**：事务钩子 / converter / 导入 / 异常体系的一致性、错误处理、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1（`f_orm` 模块 8 个子轮中的第 5 部分，待主 Agent 合并为 `docs/review/f_orm_review_20261128.md`）
- **说明**：本文件统计**只含第 5/8 部分**，合并时不要与其余七部分的数字直接相加覆盖

## 发现

### [严重][存量] 钩子 `order` 排序恒不生效：`compare` 读的是包装体自己的默认 `order`（恒 `Int64.Max`），从未读被包装钩子

- **位置**：`f_orm/src/base/TrsactionHooks.cj:45-50`（`TransactionHookWrap.compare` 的 `this.order.compare(other.order)`）、`:22`（`TransactionHookWrap` 未覆写 `order`）
- **来源**：存量（`git blame -L 45,50` → `4be871f2f` 2026-10-02「统一换行符」机械提交，本次无 diff）
- **判据**：review-checklist §11（契约与实现不符）、§13（文档承诺与实现相反）
- **证据**：静态确定 —— `TransactionHookWrap` 只声明了 `hook`、`count` 两个字段；`order` 解析到 `TransactionHook` 的默认属性实现（`TransactionHook.cj:30-34`，`get() { Int64.Max }`），因此 `this.order` 对所有包装体恒为 `Int64.Max`、`other.order` 同理，`compare` 永远落进 `case EQ => count.compare(...)`，退化为「注册先后序」；被包装钩子自己的 `order` 一次都没被读。README:1638 明确承诺「`TransactionHookWrap.compare` 先比 `order`，再比注册序号」
- **描述**：用户通过 `prop order` 声明的优先级完全被静默忽略，钩子按注册顺序执行。依赖「审计钩子先于缓存清理钩子」「权限校验先于业务钩子」这类时序的业务会得到相反顺序，且无任何日志/异常提示。`f_orm/src` 下没有任何 `TransactionHook` 相关用例（`grep -rn TransactionHook --include=*_test.cj` 零命中），缺陷不会被现有测试发现；`fdemo/boot/src/TransactionHookImpl.cj` 也没声明 `order`，示例同样覆盖不到
- **建议**：改为比较被包装钩子：`this.hook.order.compare(other.hook.order)`（`hook` 为 struct 私有字段，同类内可见）。补一条用例：两个钩子 `order` 分别 1 / 2、按 2→1 的顺序注册，断言回调顺序为 1→2

### [严重][存量] `inTx` 钩子从不触发：接口与 README 都声明了它，事务模板不调用、聚合器也不转发

- **位置**：`f_orm/src/base/TrsactionHooks.cj:21-51`（`TransactionHookWrap` 未实现 `inTx` 转发）、`:53-94`（`TransactionHooks` 未实现 `inTx`）；承诺源 `f_orm/src/base/TransactionHook.cj:20`、`f_orm/README.md:1626`；调用方缺口在 `f_orm/src/base/SqlExecutor.cj:1037-1103`（范围外，仅作证据）
- **来源**：存量（`git blame` → `4be871f2f`；`git log -S inTx` → `96f73aeda`「feat(orm): 添加事务钩子中的inTx方法」，该提交只给接口加了 1 行声明，未加任何调用点）
- **判据**：review-checklist §3（接口给了默认空实现、实现/调用方未覆盖）、§14.1（半成品：承诺但未接线）
- **证据**：静态确定 —— 全仓 `grep -rn "\.inTx("` 只命中接口默认实现（`TransactionHook.cj:20`）与示例实现（`fdemo/boot/src/TransactionHookImpl.cj:29`），**无任何调用点**；`TransactionHooks` 的 7 个转发方法（`beforeTx`/`beforeCommit`/`afterCommit`/`afterThrowing`/`beforeRollback`/`afterRollback`/`afterComplete`，`:59-93`）里没有 `inTx`；README 两张「事务回调顺序」表（`:510-514`、`:1644-1646`）也不含 `inTx`，与 `:1626` 的接口清单自相矛盾
- **描述**：业务方按 README 实现 `inTx()` 后，该方法永远不会执行；事务内做「进入事务后一次性初始化」的钩子会整段失效且无报错。这是 `96f73aeda` 遗留的半成品：声明了扩展点、没接生命周期
- **建议**：两条路二选一——① 在 `SqlExecutor` 事务模板里 `newTxAndBegin` 成功之后、`executor(this)` 之前调用 `ORM.hooks.inTx()`，并给 `TransactionHookWrap`/`TransactionHooks` 补上 `inTx` 转发（否则包装体仍吞掉）；② 若短期不打算支持，删除接口成员与 README:1626 的列举，避免继续误导

### [一般][存量] 钩子注册与事务线程共用同一个非并发 `ArrayList`，运行期注册会与迭代竞争

- **位置**：`f_orm/src/base/TrsactionHooks.cj:54`（`private let list = ArrayList<TransactionHookWrap>()`）、`:55-58`（`add` + `sort`）、`:59-93`（事务线程遍历）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：静态确定 —— 共享路径：`ORM.hooks` 是 `static let`（`ORM.cj:40`），`beforeTx`/`afterCommit` 等由任意业务线程在 `SqlExecutor` 事务模板（`SqlExecutor.cj:1039-1100`）里调用；写入路径：`ORM.registerTransactionHook<T>` 是 `public`（`ORM.cj:70`），无锁、无「已冻结」标志，直接 `list.add` 并 `sort(list)`。`ArrayList` 不具备并发安全契约，迭代中 `add`/`sort` 可导致漏执行、`ConcurrentModification` 或顺序错乱。触发前提是**运行期注册**（启动期一次性注册则无竞争）
- **描述**：一旦有插件/热加载在运行期注册钩子，正在提交的事务可能跳过部分 `beforeCommit`/`afterCommit`（提交后钩子漏跑）或读到一个正在重排的列表，属于数据竞争；现有实现也没有任何「只能启动期注册」的断言或文档约束
- **建议**：启动期注册后冻结（`initialize()` 完成后置 `frozen`，再注册直接抛 `ORMException`）；若确需运行期注册，改为不可变快照原子替换（`private var snapshot: Array<TransactionHookWrap>`，注册时构造新数组再整体赋值），读路径锁外读快照

### [一般][存量] 钩子注册无去重、`ORM.initialize()` 不幂等：同一钩子会被重复回调

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55-58`；`f_orm/src/base/ORM.cj:65-71`（`registerTransactionHooks`/`registerTransactionHook`）、`:151`（`initialize()` 内 `registerTransactionHooks<TransactionHook>()`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（契约不符：`register()` 对数据源是幂等的 `addIfAbsent`，钩子路径不幂等）、§12.1（无界容器）、fountain-baseline §4（同名注册应启动失败而不是静默叠加）
- **证据**：静态确定 —— `list.add` 前没有任何身份/类型判断；`ORM.initialize()` 每次都会把 `lookupList<TransactionHook>()` 全量再注册一遍。仓内已有重复调用路径：`f_llm/src/service/LLMConfService_test.cj:60` 与 `:111` 在同一测试进程内各调一次 `ORM.initialize()`，第二次起每个钩子的 `beforeTx`/`afterCommit` 都会执行两遍
- **描述**：`afterCommit` 里做「清理一次」「发一条审计」的钩子会重复执行，`beforeCommit` 里做计数/校验的会重复累加；且列表随重复注册无界增长（每次 `initialize` 翻倍），既无上限也无告警。数据源注册是幂等的，钩子不是，二者行为不一致
- **建议**：`register` 按「钩子类型 + 实例」去重（或重复注册直接抛 `ORMException`，与 baseline §4 对齐）；`initialize()` 内加一次性守卫，避免重复注册

### [一般][存量] 钩子异常未隔离：`afterCommit` 抛异常会把已提交事务拖进回滚分支，且 `afterComplete` 仍报 `Committed`

- **位置**：`f_orm/src/base/TrsactionHooks.cj:59-93`（7 个循环均无 per-hook `try/catch`，任一钩子抛出即中断后续钩子）；后果路径在 `f_orm/src/base/SqlExecutor.cj:1039-1101`（范围外，仅作证据）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（错误处理缺失、失败路径当成功）
- **证据**：静态确定 —— `SqlExecutor.cj:1051` 的 `ORM.hooks.afterCommit()` 位于 `try` 块内；钩子抛出后进入 `:1056` 的 `catch`，先 `afterThrowing(e)`，再走 `:1093` 的「一般异常」分支 `beforeRollback(e)` → `this.rollback()` → `afterRollback(e)`。但此时事务在 `:1049` 已 `commit()`、`:1050` 已把 `txStatus` 置为 `Committed`，`finally`（`:1099-1101`）仍会 `afterComplete(Committed)`。同样地 `:1039` 的 `beforeTx` 在 `newTxAndBegin` 之前，钩子抛出时事务尚未创建，catch 分支仍会对未开启的事务调 `rollback`
- **描述**：提交成功后一个纯观测性质的 `afterCommit` 抛异常，会引发「已提交事务上再 rollback」（驱动侧通常直接抛 `no transaction in progress` 之类错误，把钩子的原始异常盖掉），同时 `afterComplete` 上报 `Committed`，状态与异常路径互相矛盾。钩子是外部代码，抛出属于正常输入，不应改变事务结论
- **建议**：「事后」钩子（`afterCommit`/`afterComplete`/`afterRollback`）单独 `try/catch` + 日志，不向上抛、不影响 `txStatus`；`beforeTx` 单独放在 `try` 之外或失败即视为事务未开始；`beforeCommit`/`beforeRollback` 若要保持「校验失败即中止事务」的语义，需在 README 写清并只让它们在提交/回滚前生效

### [一般][存量] `ORMConverter` 是被宏生成代码引用的公开 API，README 全文未提

- **位置**：`f_orm/src/base/converter.cj:20-36`；文档侧 `f_orm/README.md`（`grep ORMConverter` 0 命中）
- **来源**：存量（`git blame -L 20,35` → `4be871f2f`）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— `ORMConverter` 是顶层 `public struct`，`convert`/`convertNullable` 均为 `public static`；`f_orm/src/macros/QueryMappersGenerator.cj:250-257` 把 `ORMConverter.convert<$dataType>(v)` 直接写进**用户工程**的生成代码里（`putter: {o, v => o.$fieldName = ORMConverter.convert<$dataType>(v)}`），因此它是事实上的对外契约；README 无任何 `ORMConverter`、`convertNullable` 字样，只有 `:2086` 对 `ORMException` 的笼统描述
- **描述**：使用者遇到 `ORMException("type of param does not match generic type")` 或 `value is none` 时，文档里找不到判定规则（`T` → `?T` → `ToString` 三段匹配、不支持数值宽化/字符串解析），只能读源码；也没说明 `convertNullable` 在类型不匹配时**抛异常**而非返回 `None`
- **建议**：README「QueryMapper / 类型转换」相关章节补一小节：三条匹配规则、`toString` 兜底只对 `T = String` 生效、类型不匹配抛 `ORMException`、支持的仓颉类型清单；或至少给 `ORMConverter` 两个方法加 KDoc 并指到 README

### [轻微][存量] `SqlArgException` 直接继承 `BaseException`，按 `ORMException` 统一捕获会漏

- **位置**：`f_orm/src/exception/SqlArgException.cj:18`；文档 `f_orm/README.md:2058-2059`、`:2087`
- **来源**：存量（`git blame -L 18,30` → `4be871f2f`）
- **判据**：review-checklist §11（与规格/文档一致性——文档已注明「注意：直接继承 BaseException」，属有意设计）
- **证据**：静态确定 —— 层级为 `SqlArgException <: BaseException`，与其余 `ORMException` 家族平行；仓内 `SqlArgException` 的抛出点有 5 处（`LogicalExpr.cj`、`SqlPartial.cj`、`RootDAO.cj`、`TableClause.cj`、`wrap/SqlArg.cj`），而唯一按父类捕获的地方 `SqlExecutor.cj:368` 捕的是 `BaseException`，所以仓内不受影响；下游用户写 `catch (e: ORMException)` 时这些参数错误会穿透
- **建议**：若允许破坏性变更，改为 `<: ORMException`（异常体系收敛到单一根）；否则在 README §17.1 的代码块旁补一句「统一兜底请捕 `BaseException`，`SqlArgException` 不在 `ORMException` 之下」

### [轻微][存量] 11 个异常类的 4 个构造器为逐字样板重复，基类演进需改 11 处

- **位置**：`f_orm/src/exception/{Connection,DirtyField,MandatoryTransaction,MockDB,NeverTransaction,NoId,NoneTransaction,ORM,Propagation,SqlArg,StartFailureTransaction}Exception.cj:18-30`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 11 个文件的 `init()`/`init(message)`/`init(caused)`/`init(message, caused)` 除 `super(...)` 的接收者与基类名外逐字相同，属「模板展开」型重复；差异只有基类与 `open` 修饰符（已与 README:2058-2070 对齐，这点无误）
- **建议**：可用 `f_macros` 生成或集中到一个 `exception` 宏；若不改，至少在某一处注明「新增构造器需同步 11 个文件」。另：`DirtyFieldException`、`NoneTransactionException` 仓内零抛出点（`grep -rl` 仅定义文件），属对外可达的 `public` 类型**不算死代码**，但 README:2092/2095 的「典型抛出场景」读起来像在用，建议标注「预留」

### [轻微][存量] `convertNullable` 两处相同 `throw` 文案 + 「可空」命名与「不匹配即抛」的契约不清

- **位置**：`f_orm/src/base/converter.cj:29-34`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §2（同文件字面量复制）、§11（命名与语义不符）
- **证据**：静态确定 —— `:31` 与 `:33` 是同一句 `throw ORMException("type of param does not match generic type")`，分属内层/外层两个 `case _`；方法名暗示「类型不匹配返回 `None`」，实际返回 `None` 只发生在入参本身是 `None` 时，类型不匹配一律抛异常（调用方 `QueryMapper.cj:86` 的 `if (let Some(v) <- convertNullable<T>(v))` 正是按「不匹配就跳过」的直觉写的）
- **建议**：合并为一个 `case _`（把内层 `match` 的结果赋给局部变量后再统一判定）；方法上加注释写明「`None` 仅表示入参为空，类型不匹配抛 `ORMException`」，或另开 `tryConvert` 返回 `None`

### [轻微][存量] `convert` 的 `'value is none'` 缺少类型与字段上下文

- **位置**：`f_orm/src/base/converter.cj:23`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（错误消息不足以定位）
- **证据**：静态确定 —— 消息是常量字符串，不含 `TypeInfo.of<T>()`，也不含列名/字段名；同一消息会从 `QueryMapper`（每列）、`GroupedQueryMapper.cj:65`（列表元素）等多处路径抛出，线上只能看到「value is none」，无法判断是哪一列
- **建议**：`getOrThrow {ORMException("value is none, requires ${TypeInfo.of<T>()}")}`；需要列名时由调用方补（`QueryMapper` 已持有 `dataType.columnName`），与 README:2086 描述的「列转换错误带 index/type/name」口径对齐

### [轻微][存量] `TransactionHooks.register<T>` 的泛型形参 `T` 不参与实现，调用方被迫显式写 `<T>`

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §10（设计合理性 / 冗余抽象）
- **证据**：静态确定 —— 形参是 `hook: TransactionHook`，`T` 只出现在 `where T <: TransactionHook` 约束里，函数体不引用 `T`；因为 `T` 无法从参数推导，`ORM.cj:67` 必须写 `hooks.register<T>(hook)`。它还造成「调用方以为做了 `T` 类型校验、实际没有」的错觉（校验在 `ORM.registerTransactionHook<T>(hook: T)` 的形参上已完成）
- **建议**：去掉泛型：`func register(hook: TransactionHook): Unit`，`ORM` 侧同步去掉 `<T>`；若未来要按类型去重，再把 `T` 用于 `TypeInfo.of<T>()` 索引

### [轻微][存量] 测试夹具 `UpdateResultTest` 放在 `src/` 且为 `public`、无用途注释

- **位置**：`f_orm/src/base/UpdateResult_test.cj:18-29`
- **来源**：存量（`git blame -L 18,20` → `4be871f2f`）
- **判据**：review-checklist §10（可维护性）
- **证据**：静态确定 —— 仅 `Statement_test.cj:29`、`:34` 使用；文件按仓颉 `_test.cj` 约定只在测试构建中编译（本轮未跑构建，未实测），因此不构成产品死代码；类没有任何注释说明「这是固定返回 1/1 的测试替身」，`public` 在测试包内也无必要
- **建议**：收窄为 `class`（包内可见）并加一行注释「测试替身：`rowCount`/`lastInsertId` 恒为 1，仅供 `Statement_test` 断言 SQL 文本用」

### [轻微][存量] `imports.cj` 里混放内部业务函数；文件名 `TrsactionHooks.cj` 拼写错误

- **位置**：`f_orm/src/base/imports.cj:36-42`（`EMPTY_LOGICAL_EXPR` + `emptyLogicalExpr`）；`f_orm/src/base/TrsactionHooks.cj:1`（文件名）
- **来源**：存量（`imports.cj:36-41` → `245fecb0c` 2026-10-05；文件名 → `4be871f2f`）
- **判据**：review-checklist §10（可读性 / 可维护性：职责划分、命名）
- **证据**：静态确定 —— `imports.cj` 承担 `public import` 重导出职责（`f_base`/`f_bean`/`f_config`/`f_data`/`ORMConfig`），同时定义了 `internal func emptyLogicalExpr`（被 `LogicalExpr.cj:239`、`TableClause.cj:58` 调用）；文件名 `Trsaction` 少一个 `n`，与模块内 `Transaction*` 系列不一致，`grep`/跳转时容易漏
- **建议**：函数迁到 `LogicalExpr.cj` 或独立 `EmptyExpr.cj`（若因 `@ORMEmbedSensitive` 需要与 `public import fountain::f_config.*` 同文件，则必须在原处留一行「为什么放在这里」的注释——当前注释只解释了「为什么在函数之前」）；文件名建议改为 `TransactionHooks.cj`，代价是 `git blame` 断代，需与仓库其他重命名节奏一起做

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分代码无长生命周期容器、无全量物化、无大对象；唯一随调用增长的容器（钩子列表）已按缺陷（重复注册/无界）处理，不重复出优化方案。

（本部分无满足「可执行 + 可验证 + 有基线」三条件的堆内存 / CPU 优化方案。）

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ORMConverter` 在结果集映射时按列调用（`Any` 装箱 + 三段类型匹配 + `ToString` 兜底可能生成临时字符串），在大结果集上是分配与 CPU 热点 | `f_orm/src/base/converter.cj:22-35`（调用点 `QueryMapper.cj:86,90`、`GroupedQueryMapper.cj:65`） | 单次映射自耗时占比、每行分配量 | `cjprof record` 跑 10 万行 × 20 列的 `QueryMappers` 全量映射（`-O2`），对比「开启结果缓存/关闭缓存」两组，看 `convertNullable` 自耗时占比与 GC 次数 |
| 2 | `emptyLogicalExpr` 每次条件拼接都做一次正则匹配，在高 QPS 的 DSL 拼接路径上占比可观 | `f_orm/src/base/imports.cj:40-42`（调用点 `LogicalExpr.cj:239`、`TableClause.cj:58`） | 调用次数 / 自耗时占比 | 在 `EMPTY_LOGICAL_EXPR.matches` 外包分段计时（或 `cjprof`）跑「每秒 1 万次带 5 条件查询构建」场景 60s，取中位数；与此前「插值构造 key + 缓存查表」实现对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/TrsactionHooks.cj` | .cj | ✅ | 本部分主缺陷源：`order` 不生效、`inTx` 未转发、注册无同步/无去重、钩子异常未隔离 |
| 2 | `f_orm/src/base/UpdateResult_test.cj` | .cj | ✅ | 测试替身（`Statement_test.cj:29,34` 使用），`_test.cj` 不进产品构建；`public` 可收窄 |
| 3 | `f_orm/src/base/converter.cj` | .cj | ✅ | `T`→`?T`→`ToString` 三段匹配；公开 API 未进 README、错误消息缺上下文、两处重复 `throw` |
| 4 | `f_orm/src/base/imports.cj` | .cj | ✅ | `public import` 聚合重导出 + 敏感信息注解；`internal import` 为模块级可见（`SqlPartial.cj:91` 未自带 `f_log` 导入即依赖它），**不是未使用导入**；混放 `emptyLogicalExpr` |
| 5 | `f_orm/src/exception/ConnectionException.cj` | .cj | ✅ | `<: ORMException`、`open`，与 README:2058-2070 一致 |
| 6 | `f_orm/src/exception/DirtyFieldException.cj` | .cj | ✅ | `<: ORMException`；仓内零抛出点（public 对外可达，不判死代码） |
| 7 | `f_orm/src/exception/MandatoryTransactionException.cj` | .cj | ✅ | `<: PropagationException`，`DummyTransaction` 使用，与 README:2094 一致 |
| 8 | `f_orm/src/exception/MockDBException.cj` | .cj | ✅ | `<: ORMException`；`Dialect.cj` 使用 |
| 9 | `f_orm/src/exception/NeverTransactionException.cj` | .cj | ✅ | `<: PropagationException`；`SqlExecutor.cj`/`DummyTransaction.cj` 使用 |
| 10 | `f_orm/src/exception/NoIdException.cj` | .cj | ✅ | `open`；`SqlPartial.cj` 使用 |
| 11 | `f_orm/src/exception/NoneTransactionException.cj` | .cj | ✅ | `<: TransactionException`；仓内零抛出点（public，不判死代码） |
| 12 | `f_orm/src/exception/ORMException.cj` | .cj | ✅ | 家族根，4 构造器与 README 一致（`:22` 多一个空行，仅格式） |
| 13 | `f_orm/src/exception/PropagationException.cj` | .cj | ✅ | `open`，传播异常基类，与 README:2058-2070 一致 |
| 14 | `f_orm/src/exception/SqlArgException.cj` | .cj | ✅ | 直接继承 `BaseException`（README:2087 已注明），捕获口径见轻微项 |
| 15 | `f_orm/src/exception/StartFailureTransactionException.cj` | .cj | ✅ | `<: TransactionException`；`DummyTransaction.cj` 使用 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分清单无 `.md`，模块 README 由其他子轮覆盖；本报告只就与本部分文件直接相关的 README 断言取证）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性：`order` 失效、`inTx` 不触发；错误处理：钩子异常未隔离；设计：`register<T>` 冗余泛型、`SqlArgException` 层级、converter 契约；可读性：测试夹具、`imports.cj` 职责与文件名。无外部输入、无 SQL 拼接、无凭据落日志，安全性本部分无命中 |
| §1 死代码 | 1 | 逐个核对：`TransactionHookWrap`（含 8 个转发方法，被 `TransactionHooks` 调用）、`TransactionHooks`（`ORM.cj:40` 使用，7 个方法与 `register` 均有调用）、`EMPTY_LOGICAL_EXPR`/`emptyLogicalExpr`（`LogicalExpr.cj:239`、`TableClause.cj:58` 使用）、`ORMConverter.convert/convertNullable`（`QueryMapper.cj:86,90`、`GroupedQueryMapper.cj:65`、宏生成代码）、`UpdateResultTest`（`Statement_test.cj:29,34`）；异常类均为对外可达 `public` 顶层声明，不判死代码（`DirtyFieldException`/`NoneTransactionException` 零引用仅记录）。唯一命中：`converter.cj:21` 的 `private init()` 全仓无调用（防实例化惯用法，但无注释）。`imports.cj` 的 `internal import` 经 `SqlPartial.cj:91` 反证为模块级可见、非死导入 |
| §2 重复逻辑 | 2 | 已两两比对 15 个文件内的全部函数体（7 个钩子转发 + 7 个遍历 + `compare` + `convert`/`convertNullable` + `matches`）：7 个遍历循环形状相同但属接口实现必需、闭包化会牺牲可读性，不判重复；命中 ① 11 个异常类构造器逐字样板；② `convertNullable` 内两处相同 `throw` 文案。跨文件搜了 `type of param does not match generic type`（仅 converter）、`[\s()]` 正则（仅 imports.cj）、`order.compare`（仅本文件） |
| §3 空实现 | 1 | `TransactionHooks`/`TransactionHookWrap` 继承 `inTx` 的默认空实现且全链路无调用（严重项）；`UpdateResultTest` 返回常量属测试替身、`TransactionHook` 各钩子默认空实现属扩展点默认值，均非缺陷 |
| §4 栈溢出 | 0 | 无递归：`compare` 只比两层字段，`convertNullable` 只有一层 `match`，钩子遍历为单层 `for`；无自引用结构、无深度拷贝 |
| §5 OOM | 0 | 无全量物化、无按报文长度预分配；唯一无界容器是钩子 `list`，其增长路径已并入「重复注册无去重」缺陷（一般项），不重复计 OOM |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench（`scope.md`「已有性能资料」为空），不成立热点；converter 与 `emptyLogicalExpr` 的两条疑似点已写入「待验证假设」并给采法 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`；钩子路径完全无同步（问题在 §12.1，不在锁粒度） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无批处理窗口 |
| §6.4 低效算法 | 0 | `register` 每次 `sort(list)` 是 O(n log n)、n = 钩子数（个位数）、仅注册期执行，不构成低效；`convertNullable` 三段 `match` 为常数级；`matches` 走预编译常量正则（`245fecb0c` 已优化） |
| §7 降堆内存方案 | 0 | 无中间副本、无缓存、无池化对象；`ArrayList` 元素为 struct 包装体，n 极小，收益无法量化 |
| §8 降 CPU 方案 | 0 | 同 §6.1：无基线数据，任何「减少类型匹配/正则调用」的收益都只能是待验证假设 |
| §9 local mode 可行性 | 0 | 本部分无函数内大临时对象；`TransactionHookWrap` 为 2 字段小 struct、`ORMConverter` 无中间集合，无峰值内存收益可证 |
| §11 现有代码的 BUG（存量） | 5 | `order` 失效、`inTx` 不触发、注册并发竞争、重复注册/`initialize` 不幂等、钩子异常未隔离；另核对了 `convertNullable` 的空值/类型不匹配边界（`QueryMapper.cj:86` 的可空路径行为正确）、11 个异常类的 `open`/构造器与 README 逐项一致，未再发现缺陷 |
| §12 并发安全与锁粒度 | 2 | 共享路径与缺失同步手段已在两条发现里写明（`ORM.hooks` 静态 + `public registerTransactionHook` + `ArrayList` 无锁）；锁粒度无可谈（无锁可缩）；线程封闭无法证明（库级 API） |
| §13 文档一致性 | 1 | README:1638「`compare` 先比 `order`」与实现相反（并入 `order` 严重项）；README:1626 列 `inTx` 但两张回调顺序表不含它（并入 `inTx` 严重项）；README §17 异常体系（`:2058-2095`）与 11 个类逐项核对**一致**（父类、`open`、4 构造器全对）；本部分无 `.md` 文件 |
| §14 功能完备性与 README 覆盖 | 2 | ① `inTx` 承诺未接线（严重项）；② `ORMConverter`（宏生成代码引用）完全未文档化（一般项）。`TransactionHookWrap`/`TransactionHooks`/`emptyLogicalExpr` 为 internal，按 §14.2 免报；异常类已由 §17 覆盖 |
| 文件覆盖（§13 等） | 15/15 | 无遗漏、无未读文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 13 条（本部分无 diff，全部为存量），是否纳入修复待用户决定。

## 总评

本部分代码量小、结构清楚：异常体系（11 个类）与 README §17 逐项对齐，`open` 修饰符、4 个构造器、父类层级均无偏差，`imports.cj` 的聚合导入与 `@ORMEmbedSensitive` 组合也自洽，没有空实现、递归、无界物化一类问题。

真正的风险集中在**事务钩子这一条扩展链**，且都是「静默失效」型：`TransactionHookWrap.compare` 读自己的默认 `order`，导致 README 承诺的排序能力形同虚设（严重）；`inTx` 是只加了声明、没接生命周期的半成品（严重）。两者都因为模块内完全没有 `TransactionHook` 用例而长期未被发现（`fdemo` 的示例钩子也没设 `order`）。这两条属阻塞项，建议合并前先修。

其次，钩子注册面（`public ORM.registerTransactionHook` + 无锁 `ArrayList` + 无去重 + `initialize()` 非幂等）在多线程和重复初始化场景下会漏执行或重复执行回调；`afterCommit` 抛异常会把已提交事务拖进 rollback 分支，属错误处理缺口。这四条可排期，修复方式都在启动期冻结 + 事后钩子隔离这一层，不涉及大改。

`converter.cj` 功能可用但缺文档：它是宏生成代码直接引用的公开 API，README 零提及，使用者只能读源码猜转换规则；同时错误消息缺类型/列上下文，排障成本高。异常体系与重复样板属轻微，可作为一次清理批次处理。
