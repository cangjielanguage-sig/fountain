# 代码审查报告：f_mockdb

- 审查分支：`review/f_mockdb`（基线 `859e3759`，即 `sts/1.3.x` 现值）
- 审查范围：f_mockdb 生产代码 10 个文件 595 行（`src/*.cj` 去掉 3 个用例文件）+ 用例 3 个文件 414 行，共 1009 行，逐文件通读
- 审查依据：`cangjie-code-review`（性能优化 14 节 / 内存优化 11 节）；契约依据：`std.database.sql` 本地文档（`cangjie_runtime/std/doc/libs/std/database_sql`），逐条比对驱动契约
- 实测口径：`cjpm test --no-capture-output` 基线 **30/30 PASSED（EXIT=0）**；另写一个临时探针用例实测 5 项行为（探针已删除、未入库，日志 `/tmp/mockdb_base.log`、`/tmp/mockdb_probe.log`）
- 编号：`MOCK-x`（模块 f_mockdb）；按严重程度降序排列，同一级内按「静默错数据 → 契约不符 → 噪声/诊断」

## 0. 摘要

| 严重度 | 条数 |
|---|---|
| 严重 | 3 |
| 中 | 5 |
| 低危 / 待验证 | 9 |

**建议修复顺序**：

1. `MOCK-1`（§1.1）查询结果行不按「一次执行」清理 —— 事务内第二条语句读到第一条的行（静默错数据，实测复现）
2. `MOCK-2`（§1.2）`MockUpdateResult` 惰性读全局 —— 两个 update 结果互相串（实测复现）
3. `MOCK-3`（§1.3）`getOrNull` 越界/未就绪返回 None（std 契约要求抛 `SqlException`），类型不匹配也静默 None
4. `MOCK-4`（§2.1）`close()` 后 `isClosed()` 仍为 false、`state` 仍为 `Connected`（实测复现）
5. `MOCK-5`（§2.2）`MockConnection.close()` 隐式清空夹具，且是外部唯一可用的重置入口
6. `MOCK-7`（§2.4）参数槽语义：跨执行累积、`None<Any>` 兼作「未绑定」与「绑定 NULL」
7. 其余见 §2、§3

---

## 1. 严重（3 条）

### 1.1 [严重｜正确性] `MOCK-1` 查询结果行不按「一次执行」清理 —— 同一线程内多次 query 的行互相叠加（f_mockdb）

位置：`src/mockdb.cj:77-88`（`addQueryResultRow` 只追加、`getQueryResultRows` 返回**同一个** `ArrayList` 实例）、`src/Statement.cj:56-62`（`query()` 不清理）、`src/QueryResult.cj:20`（`rowData` 直接持有该实例）、`src/Connection.cj:36-38`（**生产代码里 `clear()` 的唯一调用点**）

旁证：本模块 30 个用例几乎每个开头都写 `MOCKDB.clear()`（`src/mockdb_core_test.cj:24,40,63,78,92,107,123,139,161,182,194,207`、`src/mockdb_transaction_test.cj:14,25,35,48,61,75,83,96,110,124,133,142,151`、`src/mockdb_exception_test.cj:14,32,47`）——「夹具必须手工清」在包内是常识，但这个入口对包外不可见（见下）。

实测（探针，`/tmp/mockdb_probe.log:36-37`）：

```
PROBE_ROWS_Q1=1      // 第一条 SQL "A"，夹具加 1 行 ⇒ 读到 1 行 ✓
PROBE_ROWS_Q2=2      // 第二条 SQL "B"，夹具同样加 1 行 ⇒ 读到 2 行 ✗（A 的行仍在）
```

影响：`MOCKDB` 的夹具数据只有 `MOCKDB.clear()` 会清，而 `clear()` **没有 `public`**（默认 `internal`，只到 `fountain::f_mockdb` 包及子包）⇒ 包外（`f_orm`、`fcoder`、`fdemo` 等）既不能主动清、也没有别的清理点，除非关连接（见 §2.2）。触发条件很常见：

- **事务内**：`f_orm/src/base/SqlExecutor.cj:828-838` 在 `tx.isSome()` 时**跳过** `this.close()` ⇒ 整个事务期间连接不关闭 ⇒ `MockConnection.close()` → `MOCKDB.clear()` 不会被调用 ⇒ 事务里第二条 SELECT 会带上第一条 SELECT 的行；连接在事务结束（`SqlExecutor.cj:1005`）才关闭。
- 结果集本身也不是快照：`MockQueryResult.rowData` 是 live 引用，已交给调用方的结果集会被**后续** `addQueryResultRow` 改变。

对 `f_orm` 用例的后果与 `ORM-1`/`ORM-C1` 同类：拿到的行数是错的，但用例不报错。

修法（任一，建议第 1 条）：

1. 新增 `public static func clearQueryResult(): Unit`，只清 `queryResultList_` 与 `queryResultColumnInfos_`（**不动** `toThrowOn*` 标志与 `execution`），并在 `MockStatement.query()` / `update()` 调 `MOCKDB.execution(sql, args)` **之前**调用 ⇒ 与 README「在 execution 里决定本次查询结果」的既有用法一致；
2. 或把 `MockQueryResult` 改成在 `query()` 时对行做快照，`query()` 内部先清空行槽；同时把 `clear()`（或新函数）提升为 `public`，让包外能显式重置。

DT：①同一连接上两条 SELECT（各 1 行）断言第二条只返回 1 行；②事务内两条 SELECT 同样断言（在 f_orm 层加，语义归属事务层）；③`conn.close()` 后断言夹具已清空。

### 1.2 [严重｜正确性] `MOCK-2` `MockUpdateResult` 不是快照 —— 惰性读线程局部状态，两个 update 结果互相串（f_mockdb）

位置：`src/UpdateResult.cj:19-28`（`lastInsertId`/`rowCount` 的 getter 现读 `MOCKDB.lastInsertId` / `MOCKDB.rowCount`）、`src/Statement.cj:49-55`（`update()` 不取值、只返回 `MockUpdateResult()`）

实测（探针，`/tmp/mockdb_probe.log:38-39`）：

```
PROBE_UR1_ROWCOUNT=22   // 第一次 update（夹具设 rowCount=11）返回的对象，读到的是第二次的 22
PROBE_UR2_ROWCOUNT=22
```

影响：`UpdateResult` 是「一次执行的结果」的载体，判空/计数/自增 ID 都该是**那一次**的值。当前实现下列场景全错且不报错：同一线程连续两次 insert 后分别读两个返回值；把返回值存起来稍后再读；连接关闭（`MOCKDB.clear()`）后读旧对象 → 全部变成 0。`f_orm` 目前是「拿到就立刻读」（`SqlExecutor.cj:407/422`、`DatabasePool.cj:121`），所以暂时看不出问题——正因如此没有用例拦住。

修法：`public class MockUpdateResult(lastInsertId!: Int64, rowCount!: Int64)`（或私有字段 + 构造器），`MockStatement.update()` 里 `MockUpdateResult(MOCKDB.lastInsertId, MOCKDB.rowCount)` 取快照。

DT：两次 update 分别设 11 / 22，断言两个返回值各为 11 / 22（现有 `testUpdateResult`/`testDeleteUpdateResult` 都是「设完立刻读」，拦不住）。

### 1.3 [严重｜正确性] `MOCK-3` `getOrNull` 偏离 std 契约：越界/行未就绪应抛 `SqlException`，实测静默返回 None；类型不匹配也静默 None（f_mockdb）

位置：`src/QueryResult.cj:37-52`（`get<T>` = `getOrNull<T>(index).getOrThrow()`；`getOrNull` 对「行未就绪 / 列越界 / 类型不符」一律 `None`）

契约（std 文档 `database_sql_package_interfaces.md:316-334`）：`getOrNull<T>(index)`「检索指定列的值，数据库列允许 SQL NULL」；**异常：`SqlException` —— 索引超出列范围，或者行数据未准备好时，抛出异常**。

实测（探针，`/tmp/mockdb_probe.log:40-41`）：

```
PROBE_GETORNULL_OOR=None_NoThrow             // 列索引 99（只有 1 列）→ 返回 None，未抛 SqlException
PROBE_GETORNULL_TYPE_MISMATCH=None_NoThrow   // 列值是 Int64，取 getOrNull<String> → 静默 None
```

影响：

- 只按 mock 写的用例，测不到真实驱动的「索引越界 / 行未就绪 → SqlException」分支；换成真驱动就会从「None 静默」变成「抛异常」，mock 用例的结论不可迁移；
- 更实际的是**手写夹具的类型错误被静默抹平**：`typeName` 写 `SqlVarchar` 却 `addQueryResultRow([1])`（或反之）时，`getOrNull<String>` 返回 None，`f_orm` 的 `QueryResultWrap` 把它当「SQL NULL」继续往下走 ⇒ 类型映射错误变成空值，用例照样绿。本模块自己的 `testGetOrNullReturnsNone` 正是把「越界返回 None」固化成期望行为的例子（`src/mockdb_core_test.cj:122-135`）。

修法：`getOrNull` 区分三种情况——①行未就绪（`rowIndex < 0`）或列越界 → 抛 `SqlException`（mock 里可用 `MockDbException` 的替代实现，或直接抛 std 的 `SqlException`）；②取到的值是 `None<Any>`（SQL NULL）→ `None`；③类型不符 → 也抛（`SqlException` 或 `MockDbException`，二选一并在 README 写明）。同时修 `testGetOrNullReturnsNone` 的期望。

DT：越界与未 `next()` 时断言抛异常；类型不符断言抛异常；真正 SQL NULL 断言 `None`。

---

## 2. 中（5 条）

### 2.1 [中｜契约] `MOCK-4` 关闭语义完全没建模：`close()` 之后 `isClosed()` 仍 false、`state` 仍是 `Connected`（f_mockdb）

位置：`src/Connection.cj:19-23,33-35`、`src/Statement.cj:63-68`、`src/QueryResult.cj:53-56`、`src/Datasource.cj:19-22`

实测（探针，`/tmp/mockdb_probe.log:42-43`）：

```
PROBE_ISCLOSED_AFTER_CLOSE=false
PROBE_STATE_AFTER_CLOSE=Connected
```

契约：`Resource.isClosed()`「判断对象是否已关闭」；`ConnectionState.Closed`「表示连接对象已关闭」（std 枚举文档）。

影响：`f_orm` 里多处用 `isClosed()` 决定是否复用/关闭连接（`SqlExecutor.cj:131-135`、`DatabasePool.cj:230-235`、`ORM.cj:47-49`）——mock 下这些判断恒为「未关闭」，于是「关后再用」「重复关闭」「池回收已关连接」这些真实路径在 mock 用例里永远不会走到或被报错，用例对连接生命周期的覆盖是假绿。

修法：四个类各加 `private var closed_ = false`，`close()` 置 true、`isClosed()` 返回它、`Connection.state` 返回 `Closed`（`isClosed()` 后），并对「已关闭对象上继续 prepare/query/update」给出明确异常。

DT：`close()` 后断言 `isClosed()==true`、`state==Closed`；双关幂等；关闭后 query 抛异常。

### 2.2 [中｜正确性] `MOCK-5` `MockConnection.close()` 带隐藏全局副作用：关连接 = 清空当前线程夹具，而且是包外唯一可用的重置入口（f_mockdb）

位置：`src/Connection.cj:36-38`（`close()` → `MOCKDB.clear()`）、`src/mockdb.cj:46-59`（`clear()` 清 11 个 ThreadLocal：行、列信息、`toThrowOn*` 标志、metadata、`lastInsertId`、`rowCount`）

影响：

- 语义错位：关闭一条连接不该影响夹具内容与事务/执行标志；但 `f_orm` 在每次非事务执行结束都会关连接（`SqlExecutor.cj:836`），于是**夹具被静默重置**——用例在 `execution` 之外设置的 `MOCKDB.metadata` / `addQueryResultRow` / 标志位，会被任意一次连接关闭清掉，随后的断言读到默认值（0 / 空 map / false）。这类失败方向不确定（取决于执行顺序），排查成本高。
- 唯一性：`clear()` 是 `internal`，包外无法主动重置；于是「想重置夹具」只能「假装关一下连接」，把内部实现细节写进了使用方式（`f_orm/src/wrap/DatabasePool_test.cj` 就是靠这个副作用在一轮轮 `pool.connect()` 里自愈的）。

修法：把「清夹具」与「关连接」解耦——`close()` 只做 §2.1 的关闭状态；新增 `public static func clear(): Unit`（或 `clearQueryResult()`，见 `MOCK-1`），文档写明「用例开头调用一次」。

DT：`close()` 后断言夹具未变；显式 `clear()` 后断言夹具已清（并保留 `execution`）。

### 2.3 [中｜契约] `MOCK-6` `MockColumnInfo` 的 `displaySize` / `length` / `scale` 直接抛 `MockDbException('not supported')`（f_mockdb）

位置：`src/ColumnInfo.cj:24-33,44-48`

契约（std 文档 `database_sql_package_interfaces.md:18-75`）：`displaySize` 无限制时应返回 `Int64.Max`；`length` 对不适用的类型返回 `0`；`scale` 无小数部分返回 `0`。

影响：这三项当前 `f_orm` 没用（`QueryResultWrap.cj:973` 只按 `typeName` 分派），所以现在不炸；但任何「打印/校验列信息」「按 length 预分配」「按 scale 格式化小数」的通用逻辑（例如以后给 ORM 加列信息校验，或使用者直接遍历 `columnInfos`）一碰就抛异常，且异常类型是 `MockDbException`，与「mock 不支持该 API」的真实含义（应返回契约默认值）不同。

修法：三个属性分别返回 `Int64.Max` / `0` / `0`（或按 `typeName` 粗分：`SqlVarchar` 之类给一个可配置的 `length`），把「不可用」留给将来真正需要的字段。

DT：断言三个属性返回契约值、不抛异常。

### 2.4 [中｜正确性] `MOCK-7` `MockStatement` 参数槽三处语义问题：跨执行累积、`None<Any>` 双关、负索引异常类型（f_mockdb）

位置：`src/Statement.cj:19`（`args` 生命周期 = 语句对象）、`35-40`（`set<T>` 用 `args.add(None<Any>)` 补位）、`41-48`（`setNull` 同一套 `None<Any>`）

1. **跨执行累积**：`args` 只在语句对象构造时创建，执行后不清。`Statement` 复用（std 允许）时，第二次执行会把上一次的参数一并交给 `execution`（例如第一次绑 0 与 1，第二次只绑 2 ⇒ 夹具看到 3 个参数）。`f_orm` 每次执行都新建并关闭语句（`SqlExecutor.cj:872-882`）所以躲过了；但这是使用方行为，不是 mock 的保证。
2. **`None<Any>` 双关**：补位用的是 `None<Any>`，与 `setNull` 写入的 `None<Any>` 完全一样 ⇒ 夹具拿到参数列表后无法区分「这个位置没绑」与「这个位置绑了 SQL NULL」，而这两者在真实驱动上一个是错误、一个是 NULL 值。
3. **负索引**：`set<T>(-1, v)` / `setNull(-1)` 会走到 `args[-1] = ...` ⇒ 抛 `IndexOutOfBoundsException`（std 的 `set` 契约是索引越界抛 `SqlException`），异常类型与真实驱动不一致。

修法：`args` 换成显式占位类型（如 `ArrayList<?Any>`，`None` = 未绑定，`Some(None<Any>)` = 绑定 NULL），执行结束后按需清空，并在 `set/setNull` 开头校验 `index >= 0`（越界抛 `SqlException`/`MockDbException`）。

DT：语句复用两次断言各自参数；未绑定位置断言与 `setNull` 可区分；负索引断言异常类型。

### 2.5 [中｜正确性] `MOCK-8` `toThrowOnExecuting` 在 `execution` 之后判定：声明抛异常的语句仍先跑完夹具（f_mockdb）

位置：`src/Statement.cj:49-55`（`update()`：先 `MOCKDB.execution(sql, args)` 再判 `toThrowOnExecuting`）、`56-62`（`query()` 同样）

影响：`MOCKDB.toThrowOnExecuting = true` 的语义是「执行这条 SQL 时抛异常」，但夹具已经执行、行已写进 `queryResultList_`（在事务内不会被清，正好放大 `MOCK-1`）。于是「本应失败的语句」也留下了副作用数据，后续语句会读到；用例若在断言里检查「失败后结果集为空」会得到相反结论。

修法：把标志判定放到 `execution` 之前（真驱动也不会执行失败的语句）；README 补一句说明「置 true 时夹具不执行」。

DT：`toThrowOnExecuting = true` 后执行，断言抛异常**且** `MOCKDB.getQueryResultRows().isEmpty()`。

---

## 3. 低危 / 待验证（9 条）

### 3.1 低危（7 条）

- **`MOCK-L1` 异常无 message，诊断差**：`src/Statement.cj:52,59`、`src/Transaction.cj:49,55,61,67,73,79` 全是 `throw MockDbException()`；事务/执行的失败信息里看不出是哪条 SQL、哪个 savepoint（有 message 的只有 `MockColumnInfo` 的 `'not supported'`、`MockQueryResult.columnInfos` 与 `Statement.query(params)/update(params)` 的 `'not supported'`）。修法：带 `sql` / `savePointName` / 触发标志名。
- **`MOCK-L2` 无条件输出到 stdout，无开关**：`src/mockdb.cj:25,29-31`（默认 `EMPTY_EXECUTION` 打印 `EMPTY_EXECUTION`）、`Driver.cj:40`、`Datasource.cj:27`、`Statement.cj:30`、`Transaction.cj:47,53,59,65,71,77`。批量用例下这些是主要 I/O，且污染测试输出；多线程用例（`f_orm` 的 `DatabasePool_test` spawn 10 线程）还会交织。修法：加 `MOCKDB.verbose`（默认 false），或走 `f_log` 的 debug 级别。
- **`MOCK-L3` 编译器 10 条警告（基线 errlog 证据）**：`target/release/.build-logs/f_mockdb@fountain/…errlog` = `unused import 'std.reflect.*'`（`src/mockdb.cj:20`）、`unused variable:'params'`（`Statement.cj:26,32`）、`unused variable:'values'`（`QueryResult.cj:30`）、`overridden function 'next'/'query'/'update' should be marked with @Deprecated`（`QueryResult.cj:30`、`Statement.cj:26,32`）、`interface 'SqlDbType' is deprecated`（3 处）。修法：删死导入、参数改 `_`、给废弃重载加 `@Deprecated`（`f_orm` 的 `Statement_test.cj` 也有同类实现，可一起统一）。
- **`MOCK-L4` README 与实现不一致**：`f_mockdb/README.md:17` 写 `MOCKDB.execution = {sql: String, args: Array<Any> =>`（实际 `ArrayList<Any>`）、`:26` 写 `let rows: Array<Any> = MOCKDB.getQueryResultRows()`（实际 `ArrayList<Array<Any>>`）、`:31-35` 的 `MOCKDB.metadata = {=> …}()` 写法会让读者以为可以写闭包；README 也是**唯一**文档（模块没有 `doc/` 目录），却没有 `clear()`、`rowCount`/`lastInsertId` 默认值、`execution` 默认打印 `EMPTY_EXECUTION`、以及 `queryResultColumnInfos` 为空时抛异常这些关键约定。
- **`MOCK-L5` `getMetaData()` 的两种返回语义**：`src/mockdb.cj:130-137` 未设置时每次返回**新建**的空 `HashMap`（在它上面写东西会静默丢失），设置后返回的又是 live map（外部可改夹具）。修法：统一返回副本，或文档写明「未设置即空、只读」。
- **`MOCK-L6` 驱动的入口参数被忽略**：`src/Driver.cj:39-46` 的 `open(connectionString, opts)` 只打印 url、不透出连接串；`src/Datasource.cj:26-28` 的 `setOption` 只打印不保存 ⇒ 用例无法验证「连接串 / 选项是否正确传到驱动」，也无法回读选项。
- **`MOCK-L7` 事务无状态机**：`src/Transaction.cj:46-81` 允许重复 `begin()`、未 `begin()` 就 `commit()/rollback()`；`MockConnection.createTransaction()`（`src/Connection.cj:24-26`）永不失败，而 std 契约规定「已处于事务状态且不支持并行事务时应抛 `SqlException`」⇒ ORM 的事务传播/嵌套失败分支在 mock 下测不到。修法：加最小状态（`begun`），或在 README 写明「mock 不校验事务状态」。

### 3.2 待验证（2 条，需实测）

- **`MOCK-V1` 重复加载动态库时的驱动注册**：`src/Driver.cj:21-23` 在 `static init()` 里 `DriverManager.register('mockdb', MockDriver())`；fountain 的应用允许「同一动态库被主动加载 + 被依赖再加载」两次（`fboot run` 的 `--dylibPattern` 说明里明确提到重复加载），std 文档只写「名称和实例一一对应，本方法并发安全」，没定义同名重复注册是覆盖还是报错。验证：写一个只链 `f_mockdb` 的小程序，手动 `dlopen` 两次后 `DriverManager.getDriver('mockdb')`，观察是否异常/是否为后一次实例。
- **`MOCK-V2` 用例覆盖缺口（未被任何用例冻结的行为）**：`query(params)` / `update(params)` / `next(values)` 三个 `'not supported'` 分支、`getOrNull` 未 `next()` 与类型不符、`MockStatement.set` 负索引、语句复用的参数累积、`MockUpdateResult` 的惰性读取、`close()` 后的 `isClosed()`/`state`、`MOCKDB.execution` 缺省（`EMPTY_EXECUTION`）路径。现状 30 个用例全绿（§5），但这些分支一条都没测——修 §1/§2 时建议一并补上（否则改动没有回归网）。

---

## 4. 覆盖面（结构小结 + 已确认「无实例」的维度）

**结构**：静态门面 `MOCKDB`（1 个进程级 `execution_` + 11 个 `ThreadLocal` 夹具槽）+ `std.database.sql` 七个接口的实现（`MockDriver` / `MockDatasource` / `MockConnection` / `MockStatement` / `MockQueryResult` / `MockUpdateResult` / `MockColumnInfo`）+ `MockTransaction` + `MockDbException`。运行期无动态代理、无代码生成。

**无实例的维度**：

- 无反射调用（`src/mockdb.cj:20` 的 `std.reflect.*` 是死导入，见 `MOCK-L3`）；无宏。
- 无缓存、无对象池、无长期注册表；唯一进程级可变状态是 `execution_`（`AtomicOptionReference`，写入即替换 `Box`）。
- 无 spawn / Future / 线程创建；无锁与临界区（`AtomicOptionReference` 自身线程安全）。线程相关只有 `ThreadLocal` 夹具槽（11 个），`clear()` 会逐个 `set(None)`，覆盖当前线程。
- 无文件 / 网络 / CFFI / 原生内存 / 句柄类资源；`MockStatement.close()`、`MockQueryResult.close()`、`MockDatasource.close()` 都是空实现（见 `MOCK-4`），不存在泄漏面。
- 无热路径算法问题：没有循环内集合扫描、重复解析、正则、字符串拼接热点（唯一字符串操作是 `MOCK-L2` 的日志式输出）。
- 复制/分配：`queryResultColumnInfos` 每次返回 `toArray()` 副本（必要隔离，避免外部改夹具）；`MockQueryResult.rowData` 是 live 引用（问题见 `MOCK-1`，不是复制浪费）。
- 内存增长面：只在用例自身写入夹具时增长（行集与语句参数），无跨用例 GC 后仍存活的结构；`ThreadLocal` 跨线程残留情况与 `MOCK-5`/`MOCK-1` 同源（只有当前线程会被清）。

**性能定位**：f_mockdb 不在生产链路上；但 `f_orm` 支持把 `orm_drivers` 配成 `mockdb` 当「无库跑应用」的驱动（`f_orm/src/base/ORM.cj:138`、`fdemo/boot.sh:41` 注释示例、`fdemo/boot/src/boot.cj:26-42`），此时本节这些问题同样会在非用例场景出现。唯一可观测的性能开销是 `MOCK-L2` 的无条件 stdout 输出。

---

## 5. 基线与验证状态

| 项 | 命令 | 结果 |
|---|---|---|
| 既有用例 | `cjpm test --no-capture-output`（WSL Ubuntu-24.04，SDK 1.3.0-alpha.20261001001050） | **30/30 PASSED，ERROR 0，FAILED 0，`cjpm test success`（EXIT=0）**，日志 `/tmp/mockdb_base.log` |
| 探针用例 | 临时 `src/mockdb_review_probe_test.cj`（**已删除，未入库**） | 31/31 PASSED，打印 8 条实测值（`/tmp/mockdb_probe.log:36-43`），支撑 `MOCK-1`/`MOCK-2`/`MOCK-3`/`MOCK-4` |
| 编译警告 | 同上构建（基线产物 errlog） | 10 条 warning、0 条 error（清单见 `MOCK-L3`） |

探针原文（`MockDB.clear()` → 两次 query / 两次 update / `getOrNull` 越界与类型不符 / `close()` 后状态）：

```cangjie
MOCKDB.execution = {sql: String, _: ArrayList<Any> =>
    MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
    MOCKDB.addQueryResultRow([if (sql == "A") { 1 } else { 2 }])
    if (sql == "U1") { MOCKDB.rowCount = 11 }
    if (sql == "U2") { MOCKDB.rowCount = 22 }
}
// 同一连接、不关连接：A 查 1 行（对），B 查 2 行（错）；U1 的 UpdateResult 读到 22（错）
```

**未做**：基准（`cjpm bench`）、堆/RSS 采样（`cjprof heap`）、多线程压力、与真实驱动（opengauss/mysql）的对照跑。`MOCK-3` 的「真实驱动抛 `SqlException`」以 std 文档为契约依据，未在真实库上复测；`MOCK-V1` 需要实测。

**复现命令**（在 worktree 内）：

```bash
source /mnt/d/docs/work/cangjie/cangjie.sh
cd /mnt/d/docs/work/cangjie/projects/fountain/.worktrees/review-f_mockdb/f_mockdb
cjpm test --no-capture-output        # 基线 30/30
```

---

## 6. 审查方法与备注

- 方法：f_mockdb 全部 13 个 `.cj`（10 生产 + 3 用例）逐行通读；每条结论给 `文件:行号`；「严重 / 中」全部做了**实测**（探针）或**契约取证**（std 本地文档 `cangjie_runtime/std/doc/libs/std/database_sql`，逐条比对 `ColumnInfo`/`Connection`/`QueryResult`/`DriverManager`/`ConnectionState`）；编译器警告取自基线构建 errlog（外部证据）。
- 调用面（决定影响范围）：①仓内唯一直接使用者 `f_orm/src/wrap/DatabasePool_test.cj`（`MOCKDB.execution` + `DriverManager.getDriver('mockdb')`）；②`f_orm` 的 `MockdbDialect` / `ORM.register()` 支持把 `mockdb` 配成运行期驱动（也可用于非用例场景）；③门面包 `src/mockdb/mockdb.cj` 只 `public import`（`internal` 的 `clear()` 不会带出去）。
- 本模块是**测试替身**，所以「与真实驱动契约一致」是它的核心质量指标：本次 3 条严重里有 2 条（`MOCK-1`/`MOCK-3`）属于「mock 与真驱动行为不同且不报错」，会直接让上层 ORM 用例得出不可迁移的结论。
- 本次审查**只读**，未改动 f_mockdb 任何代码；报告落在本分支 `.autocode/bug-mockdb.md`。探针文件与临时脚本已删除（`/tmp` 日志保留作证据）。
