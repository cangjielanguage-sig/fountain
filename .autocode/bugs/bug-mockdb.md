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

> 修复进度（2026-10-04）：§1.1 `MOCK-1`、§1.2 `MOCK-2`、§1.3 `MOCK-3`、§2.1 `MOCK-4`、§2.2 `MOCK-5`、§2.3 `MOCK-6`、§2.4 `MOCK-7`（①③）、§2.5 `MOCK-8` 已修复 ⇒ **待修严重级 0 条、中危 0 条**；低危批次（§3.3：`MOCK-L1`/`L2`/`L4`/`L5`/`L6`/`L7`）与审查后新增的 `MOCK-L8`（§3.4）已修复 ⇒ 低危 8 条全清，`MOCK-L3` 暂不处理，`MOCK-V1` 判为不成立（见 §3.2）。仍未动：§2.4 的 ②（未绑定 vs 绑定 NULL）、§3.2 的 `MOCK-V2`（覆盖缺口）。并入状态：`MOCK-1`/`MOCK-2` 已并入 `sts/1.3.x`（合并提交 `12c19d94`）；`MOCK-3`~`MOCK-8` 与低危批次在分支 `fix/mock-1-query-isolation`（`e904ac87`/`ba04b79f`/`80d67a36`/`edb10235`/`7704cd91`/`924ec6f8`/`0742124b` + 本次提交），待下次同步。标记补录提交：`fa822423`、`cd429689`、`cee6dc6d`、`78bc9f30`。

**建议修复顺序**：

1. `MOCK-1`（§1.1）查询结果行不按「一次执行」清理 —— 事务内第二条语句读到第一条的行（静默错数据，实测复现）　**✅已修复（2026-10-04，见 §1.1 修复标记）**
2. `MOCK-2`（§1.2）`MockUpdateResult` 惰性读全局 —— 两个 update 结果互相串（实测复现）　**✅已修复（2026-10-04，见 §1.2 修复标记）**
3. `MOCK-3`（§1.3）`getOrNull` 越界/未就绪返回 None（std 契约要求抛 `SqlException`），类型不匹配也静默 None　**✅已修复（2026-10-04，见 §1.3 修复标记）**
4. `MOCK-4`（§2.1）`close()` 后 `isClosed()` 仍为 false、`state` 仍为 `Connected`（实测复现）　**✅已修复（2026-10-04，见 §2.1 修复标记）**
5. `MOCK-5`（§2.2）`MockConnection.close()` 隐式清空夹具，且是外部唯一可用的重置入口　**✅已修复（2026-10-04，见 §2.2 修复标记）**
6. `MOCK-7`（§2.4）参数槽语义：跨执行累积、`None<Any>` 兼作「未绑定」与「绑定 NULL」
7. 其余见 §2、§3

---

## 1. 严重（3 条）

### 1.1 [严重｜正确性] `MOCK-1` 查询结果行不按「一次执行」清理 —— 同一线程内多次 query 的行互相叠加（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（worktree `.worktrees/mock-1-query-isolation`，基线 `4184f45c` = 审查分支 `review/f_mockdb` 现值），**代码、用例、本标记在同一提交**。

提交 `75d72989`；**已并入 `sts/1.3.x`**（合并提交 `12c19d94`，2026-10-04）。

- 改动：①`src/mockdb.cj` 新增 `public static func clearQueryResult()`（只清 `queryResultList_` / `queryResultColumnInfos_`，不动 `execution` 与 `toThrowOn*` 标志），`clear()` 改为复用它；②`src/Statement.cj` 的 `update()` / `query()` 在调 `MOCKDB.execution(sql, args)` **之前**先 `MOCKDB.clearQueryResult()`；③`src/QueryResult.cj` 的行数据与列信息改成**构造时快照**（`getQueryResultRows().toArray()` / `queryResultColumnInfos`），已交给调用方的结果集不再被后续执行改变。
- 用例：`src/mockdb_core_test.cj` 新增 3 条 —— `testQueryResultRowsIsolatedPerExecution`（两条 SQL 各 1 行，各自只看到自己的行）、`testQueryResultRowIsSnapshot`（后续执行不改变已返回的结果集）、`testClearQueryResultKeepsFlagsAndExecution`（`clearQueryResult()` 清结果但保留 `execution` 与标志）。
- 测量证据：**修复前**（先写用例钉现状）`cjpm test --no-capture-output` = PASSED 30 / **FAILED 2**（EXIT=1）：`testQueryResultRowsIsolatedPerExecution` 在 `@Assert(2, rs2.get<Int64>(0))` 失败（left 2 / right 1，第二次查询的第一行是第一次的行）、`testQueryResultRowIsSnapshot` 在 `@Assert(false, rs1.next())` 失败（得 true）；**修复后** = **33/33 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条与修复前一致（未新增）。日志 `/tmp/mock1_before.log`、`/tmp/mock1_after.log`。
- 行为变化（与 README 用法一致）：夹具若在 `execution` **之外**预先写行/列信息，会被执行前的 `clearQueryResult()` 清掉；README 与既有用例都是「在 `execution` 内写入」，`f_orm` 的 mockdb 路径同样如此。
- 未覆盖：`f_orm` 侧 mockdb 路径（`f_orm/src/wrap/DatabasePool_test.cj`，含 10 线程 + 30s 压测）本轮未复跑；`MOCK-8`（`toThrowOnExecuting` 判定在夹具之后）本轮未动，故「声明抛异常的语句仍会先写行」保持原样。

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

### 1.2 [严重｜正确性] `MOCK-2` `MockUpdateResult` 不是快照 —— 惰性读线程局部状态，两个 update 结果互相串（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-1 之后追加提交），**代码、用例、本标记在同一提交**。

提交 `ab85d051`；**已并入 `sts/1.3.x`**（合并提交 `12c19d94`，2026-10-04）。

- 改动：①`src/UpdateResult.cj` 的 `MockUpdateResult` 改为携带快照（构造函数 `MockUpdateResult(lastInsertId_, rowCount_)`，两个属性返回字段）；②`src/Statement.cj` 的 `update()` 在夹具执行后取快照 —— `MockUpdateResult(MOCKDB.lastInsertId, MOCKDB.rowCount)`。
- 用例：`src/mockdb_core_test.cj` 新增 2 条 —— `testUpdateResultIsSnapshot`（两次 update 各设 `lastInsertId/rowCount` = 11/1 与 22/2，断言两个返回值互不干扰）、`testUpdateResultSurvivesLaterReset`（拿到返回值后 `MOCKDB.clear()`，断言旧返回值不变）。
- 测量证据：**修复前** PASSED 33 / **FAILED 2**（EXIT=1）：`testUpdateResultIsSnapshot` 在 `@Assert(11, ur1.lastInsertId)` 失败（left 11 / right 22）、`testUpdateResultSurvivesLaterReset` 在 `@Assert(11, ur.lastInsertId)` 失败（right 0）；**修复后** = **35/35 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock2_before.log`、`/tmp/mock2_after.log`。
- 影响面：`MockUpdateResult` 的构造点全仓只有 `Statement.cj` 一处（`git grep MockUpdateResult`）；`f_orm` 的 `SqlExecutor.cj:407/422` 本来就是「拿到就立刻读」，语义不变。

位置：`src/UpdateResult.cj:19-28`（`lastInsertId`/`rowCount` 的 getter 现读 `MOCKDB.lastInsertId` / `MOCKDB.rowCount`）、`src/Statement.cj:49-55`（`update()` 不取值、只返回 `MockUpdateResult()`）

实测（探针，`/tmp/mockdb_probe.log:38-39`）：

```
PROBE_UR1_ROWCOUNT=22   // 第一次 update（夹具设 rowCount=11）返回的对象，读到的是第二次的 22
PROBE_UR2_ROWCOUNT=22
```

影响：`UpdateResult` 是「一次执行的结果」的载体，判空/计数/自增 ID 都该是**那一次**的值。当前实现下列场景全错且不报错：同一线程连续两次 insert 后分别读两个返回值；把返回值存起来稍后再读；连接关闭（`MOCKDB.clear()`）后读旧对象 → 全部变成 0。`f_orm` 目前是「拿到就立刻读」（`SqlExecutor.cj:407/422`、`DatabasePool.cj:121`），所以暂时看不出问题——正因如此没有用例拦住。

修法：`public class MockUpdateResult(lastInsertId!: Int64, rowCount!: Int64)`（或私有字段 + 构造器），`MockStatement.update()` 里 `MockUpdateResult(MOCKDB.lastInsertId, MOCKDB.rowCount)` 取快照。

DT：两次 update 分别设 11 / 22，断言两个返回值各为 11 / 22（现有 `testUpdateResult`/`testDeleteUpdateResult` 都是「设完立刻读」，拦不住）。

### 1.3 [严重｜正确性] `MOCK-3` `getOrNull` 偏离 std 契约：越界/行未就绪应抛 `SqlException`，实测静默返回 None；类型不匹配也静默 None（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-2 之后追加提交），**代码、用例、本标记在同一提交**。

提交 `e904ac87`；尚未并入 `sts/1.3.x`（待下次同步）。

- 改动：`src/QueryResult.cj` 的 `getOrNull<T>` 按 std 契约分三种情况 —— ①行未就绪（`rowIndex < 0 || rowIndex >= rowData.size`）⇒ `throw SqlException('row data is not ready, invoke next() before reading column N')`；②列越界（`index < 0 || index >= row.size`）⇒ `throw SqlException('column index N is out of range, the current row has M columns')`；③值既不是 `T` 也不是 SQL NULL ⇒ `throw SqlException('value of column N is <实际类型>, which does not match <T>')`（用 `TypeInfo.of` 打印两侧类型）；④真正的 SQL NULL（槽里是 `None<Any>`）仍返回 `None`。
- 用例：改造 1 条 + 新增 3 条 —— 旧用例 `testGetOrNullReturnsNone`（把「越界返回 None」当期望）改名为 `testGetOrNullOutOfRangeThrows`，断言越界（含 `-1`）抛 `SqlException`；新增 `testGetOrNullBeforeNextThrows`（未 `next()` 抛）、`testGetOrNullTypeMismatchThrows`（`Int64` 列按 `String` 取抛）、`testGetOrNullNullValueReturnsNone`（真 NULL 仍返回 None 的回归护栏）。
- 测量证据：**修复前** PASSED 35 / **FAILED 3**（EXIT=1）：`testGetOrNullOutOfRangeThrows`、`testGetOrNullBeforeNextThrows`、`testGetOrNullTypeMismatchThrows` 三条都在「应当抛异常」处走到 `@Assert(false)`（`getOrNull` 静默返回 None）；**修复后** = **38/38 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条与修复前逐条一致（未新增）。日志 `/tmp/mock3_before.log`、`/tmp/mock3_after.log`。
- 保留行为（有意）：`get<T>` 仍是 `getOrNull<T>(index).getOrThrow()` ⇒ 真 SQL NULL 时抛 `NoneValueException`（值确实是 null，属仓颉语义）；越界与类型不符改走 `SqlException`，与真驱动一致。
- 影响面核查：`f_orm/src/wrap/QueryResultWrap.cj:46-50` 自己先判 `columns.size <= index` 就返回 `None`，不依赖 mock 的越界行为；`DatabasePool_test` 的夹具 `typeName='SqlBigInt'` 配 `[1]`（Int64）类型一致 ⇒ 本次改动只影响**直接使用 mock 驱动**的用例（本模块 38 条 + 将来的直连用例）。

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

### 2.1 [中｜契约] `MOCK-4` 关闭语义完全没建模：`close()` 之后 `isClosed()` 仍 false、`state` 仍是 `Connected`（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-3 之后追加提交），**代码、用例、本标记在同一提交**。

提交 `ba04b79f`；尚未并入 `sts/1.3.x`（待下次同步）。

- 改动：四个类各加 `private var closed_ = false` —— ①`src/Connection.cj`：`state` 关后返回 `Closed`（否则 `Connected`）、`isClosed()` 返回标志、`close()` 置标志（**仍保留** `MOCKDB.clear()` 副作用，解耦留给 §2.2 MOCK-5）；②`src/Statement.cj`、③`src/QueryResult.cj`、④`src/Datasource.cj`：`close()` 置标志、`isClosed()` 返回标志（重复关闭幂等）。
- 用例：`src/mockdb_core_test.cj` 新增 3 条 —— `testConnectionCloseState`（关前 `false`/`Connected` → 关后 `true`/`Closed` → 双关幂等）、`testStatementAndQueryResultCloseState`、`testDatasourceCloseState`。
- 测量证据：**修复前** PASSED 38 / **FAILED 3**（EXIT=1，三条都失败在「`close()` 后 `isClosed()` 仍为 false」）；**修复后** = **41/41 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock4_before.log`、`/tmp/mock4_after.log`。
- 与既有调用方的兼容性：`f_orm/src/base/SqlExecutor.cj:370-386`（`connection` prop 按 `state` 判断「复用还是重取」）与 `:99-113`（`getInstance` 对 `Closed` 置 `NoneConnection`）在 mock 下从此走**重取连接**分支（更贴近真驱动）；`statement` prop（`:396-404`）每次执行都新建 `Statement` ⇒ 关闭位不影响它；`DatabasePool` 回收时 `!(assigned || connection.isClosed())` 的判断也从此正确。
- 未覆盖：`f_orm` 侧唯一的 mockdb 用例 `f_orm/src/wrap/DatabasePool_test.cj`（已被并行会话改成可终止的冒烟用例：借还一次连接 + `pool.close()`）本轮**未复跑**；建议合并回主线后于主工作区跑 `cjpm test --filter DatabasePoolTest`（其断言 `c.isClosed() == false` 与本次改动方向一致）。
- 保留（属 §2.2 MOCK-5）：`MockConnection.close()` 仍会调 `MOCKDB.clear()`（关连接 = 清夹具）；本次只让「关闭」这件事可观测，未涉及「关闭后继续使用是否报错」。

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

### 2.2 [中｜正确性] `MOCK-5` `MockConnection.close()` 带隐藏全局副作用：关连接 = 清空当前线程夹具，而且是包外唯一可用的重置入口（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-4 之后追加提交），**代码、用例、本标记在同一提交**。

提交 `80d67a36`；尚未并入 `sts/1.3.x`（待下次同步）。

- 改动：①`src/Connection.cj` 的 `close()` 只置 `closed_`，**不再**调 `MOCKDB.clear()`（夹具与连接生命周期解耦）；②`src/mockdb.cj` 的 `static func clear()` 提升为 **`public static func clear()`** 并补文档注释（「清空当前线程的全部夹具：查询结果、`lastInsertId`/`rowCount`、`toThrowOn*` 标志、metadata，不动 `execution`；用例开头调一次」，只清结果的入口仍是 `clearQueryResult()`）——包外（`f_orm` / `fcoder` / `fdemo`）与 `fountain::fountain.mockdb` 门面从此可以显式重置夹具，不必再借「关连接」这个副作用。
- 用例：`src/mockdb_core_test.cj` 新增 2 条 —— `testCloseKeepsFixture`（跑一次查询后关连接：断言行、列信息、`toThrowOnExecuting`、metadata 都还在，只有 `isClosed()` 变 true）、`testClearResetsFixture`（显式 `clear()` 后行、列信息、标志、`lastInsertId`、`rowCount`、metadata 全部回默认）。
- 测量证据：**修复前** PASSED 42 / **FAILED 1**（EXIT=1）：`testCloseKeepsFixture` 在 `@Assert(1, MOCKDB.getQueryResultRows().size)` 失败（left 1 / right 0 —— `close()` 把夹具清掉了）；**修复后** = **43/43 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock5_before.log`、`/tmp/mock5_after.log`。
- 影响面核查：`MOCKDB.clear()` 的生产调用点全仓只有 `Connection.cj` 这一处（改后为 0），其余都是各用例开头的显式调用；仓内除 f_mockdb 外只有 `f_orm/src/wrap/DatabasePool_test.cj` 使用 mockdb（夹具写在 `execution` 内、用 `pool` 借还连接），不依赖「关连接清夹具」。
- 行为变化（有意）：`MockConnection.close()` 不再是「重置夹具」的隐式入口；包外用例若此前依赖这个副作用，改成显式 `MOCKDB.clear()` 即可（README 相应补充见 §3.1 `MOCK-L4`）。

位置：`src/Connection.cj:36-38`（`close()` → `MOCKDB.clear()`）、`src/mockdb.cj:46-59`（`clear()` 清 11 个 ThreadLocal：行、列信息、`toThrowOn*` 标志、metadata、`lastInsertId`、`rowCount`）

影响：

- 语义错位：关闭一条连接不该影响夹具内容与事务/执行标志；但 `f_orm` 在每次非事务执行结束都会关连接（`SqlExecutor.cj:836`），于是**夹具被静默重置**——用例在 `execution` 之外设置的 `MOCKDB.metadata` / `addQueryResultRow` / 标志位，会被任意一次连接关闭清掉，随后的断言读到默认值（0 / 空 map / false）。这类失败方向不确定（取决于执行顺序），排查成本高。
- 唯一性：`clear()` 是 `internal`，包外无法主动重置；于是「想重置夹具」只能「假装关一下连接」，把内部实现细节写进了使用方式（`f_orm/src/wrap/DatabasePool_test.cj` 就是靠这个副作用在一轮轮 `pool.connect()` 里自愈的）。

修法：把「清夹具」与「关连接」解耦——`close()` 只做 §2.1 的关闭状态；新增 `public static func clear(): Unit`（或 `clearQueryResult()`，见 `MOCK-1`），文档写明「用例开头调用一次」。

DT：`close()` 后断言夹具未变；显式 `clear()` 后断言夹具已清（并保留 `execution`）。

### 2.3 [中｜契约] `MOCK-6` `MockColumnInfo` 的 `displaySize` / `length` / `scale` 直接抛 `MockDbException('not supported')`（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-5 之后追加提交），**代码、用例、本标记在同一提交**：提交 `edb10235`（`fix(f_mockdb): MOCK-6 MockColumnInfo 三个成员返回契约值（bug-mockdb §2.3 修复标记）`）；尚未并入 `sts/1.3.x`（待下次同步）。

- 改动：`src/ColumnInfo.cj` 的 `displaySize` / `length` / `scale` 由 `throw MockDbException('not supported')` 改为返回 std 契约值 —— `Int64.Max`（「如果无限制，则应该返回 `Int64.Max`」）、`0`（「对于列大小不适用的数据类型，返回 0」）、`0`（「如果无小数部分，返回 0」），各带一行注释标明契约来源。
- 用例：`src/mockdb_core_test.cj` 新增 `testColumnInfoContractValues` —— 跑一次查询后取 `rs.columnInfos[0]`，断言三个值分别为 `Int64.Max` / `0` / `0`。
- 测量证据：**修复前** PASSED 43 / **ERROR 1**（EXIT=1，`testColumnInfoContractValues`）：`REASON: An exception has occurred:Exception: not supported`，栈 `MockColumnInfo.displaySize.get() (src/ColumnInfo.cj:26)`；**修复后** = **44/44 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock6_before.log`、`/tmp/mock6_after.log`。
- 影响面：`f_orm` 的列映射只按 `typeName` 分派（`QueryResultWrap.cj:973`），不用这三个属性 ⇒ 本次只把「一碰就抛」换成契约默认值，不改变任何既有行为。
- 未做（能力补齐，另行评估）：让夹具能填真实长度/精度 —— 给 `MockColumnInfo` 与 `MOCKDB.addQueryResultColumnInfo` 加可选参数 `displaySize!` / `length!` / `scale!`。

位置：`src/ColumnInfo.cj:24-33,44-48`

契约（std 文档 `database_sql_package_interfaces.md:18-75`）：`displaySize` 无限制时应返回 `Int64.Max`；`length` 对不适用的类型返回 `0`；`scale` 无小数部分返回 `0`。

影响：这三项当前 `f_orm` 没用（`QueryResultWrap.cj:973` 只按 `typeName` 分派），所以现在不炸；但任何「打印/校验列信息」「按 length 预分配」「按 scale 格式化小数」的通用逻辑（例如以后给 ORM 加列信息校验，或使用者直接遍历 `columnInfos`）一碰就抛异常，且异常类型是 `MockDbException`，与「mock 不支持该 API」的真实含义（应返回契约默认值）不同。

修法：三个属性分别返回 `Int64.Max` / `0` / `0`（或按 `typeName` 粗分：`SqlVarchar` 之类给一个可配置的 `length`），把「不可用」留给将来真正需要的字段。

DT：断言三个属性返回契约值、不抛异常。

### 2.4 [中｜正确性] `MOCK-7` `MockStatement` 参数槽三处语义问题：跨执行累积、`None<Any>` 双关、负索引异常类型（f_mockdb） → ✅已修复（2026-10-04，①③；②单列待定）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-6 之后追加提交），**代码、用例、本标记在同一提交**：提交 `7704cd91`（`fix(f_mockdb): MOCK-7 参数槽执行后清空 + 负索引抛 SqlException（bug-mockdb §2.4 修复标记）`）；尚未并入 `sts/1.3.x`（待下次同步）。

- 改动（`src/Statement.cj`）：**①跨执行累积** —— `update()` / `query()` 把 `MOCKDB.execution(sql, args)` 包进 `try { … } finally { args.clear() }`，一次执行结束即清空参数槽（夹具抛异常也清），语句复用时不再带上一次绑定的参数；**③负索引** —— `set<T>` / `setNull` 开头新增 `index < 0` 校验 ⇒ `throw SqlException('parameter index N is negative')`（按 std 契约，此前抛 `IndexOutOfBoundsException`）。
- 用例：`src/mockdb_core_test.cj` 新增 2 条 —— `testStatementReuseDoesNotKeepArgs`（同一语句两次执行、第二次只绑 0 号参数：夹具两次看到的参数个数应为 2、1）、`testSetNegativeIndexThrows`（`set(-1, …)` 与 `setNull(-1)` 都断言抛 `SqlException`）。
- 测量证据：**修复前** PASSED 44 / **FAILED 1 + ERROR 1**（EXIT=1）：`testStatementReuseDoesNotKeepArgs` 在 `@Assert(1, argSizes[1])` 失败（left 1 / right 2 —— 第二次仍带着上一次的参数）、`testSetNegativeIndexThrows` 报 `IndexOutOfBoundsException: Invalid index '-1': expected 0 to '0'`；**修复后** = **46/46 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock7_before.log`、`/tmp/mock7_after.log`。
- 行为变化（有意）：语句对象不再跨执行保留参数 —— 复用同一 `MockStatement` 时第二次执行前需重新 `set`（`f_orm` 每次执行都新建并关闭语句，`SqlExecutor.cj:396-404`，不受影响）；夹具在回调里看到的 `args` 仍是本次参数，但回调结束后该表被清空（若夹具保存了它的引用，之后会读到空表 —— 需要稳定快照再议）。
- 未做（本条目 ②「未绑定 vs 绑定 NULL 不可区分」）：要区分两者必须让夹具可见的表示能表达二者，而 `MOCKDB.execution` 的签名 `(String, ArrayList<Any>) -> Unit` 是公开 API（README、`f_orm/src/wrap/DatabasePool_test.cj`、本模块 40+ 处夹具都按它写），改动属**破坏性变更** ⇒ 单列待定（可选方向：改签名 `ArrayList<?Any>`、加哨兵值 + 判断辅助、保持现状并在 README 写明）。
- 顺带发现 → 已单列为 §3.1 `MOCK-L8`：`set<T>(bigIndex, v)` 会真的补出 `bigIndex + 1` 个占位符（例如索引 100 万就分配 100 万个 `None`）；2026-10-04 已修复（见 §3.4）。

位置：`src/Statement.cj:19`（`args` 生命周期 = 语句对象）、`35-40`（`set<T>` 用 `args.add(None<Any>)` 补位）、`41-48`（`setNull` 同一套 `None<Any>`）

1. **跨执行累积**：`args` 只在语句对象构造时创建，执行后不清。`Statement` 复用（std 允许）时，第二次执行会把上一次的参数一并交给 `execution`（例如第一次绑 0 与 1，第二次只绑 2 ⇒ 夹具看到 3 个参数）。`f_orm` 每次执行都新建并关闭语句（`SqlExecutor.cj:872-882`）所以躲过了；但这是使用方行为，不是 mock 的保证。
2. **`None<Any>` 双关**：补位用的是 `None<Any>`，与 `setNull` 写入的 `None<Any>` 完全一样 ⇒ 夹具拿到参数列表后无法区分「这个位置没绑」与「这个位置绑了 SQL NULL」，而这两者在真实驱动上一个是错误、一个是 NULL 值。
3. **负索引**：`set<T>(-1, v)` / `setNull(-1)` 会走到 `args[-1] = ...` ⇒ 抛 `IndexOutOfBoundsException`（std 的 `set` 契约是索引越界抛 `SqlException`），异常类型与真实驱动不一致。

修法：`args` 换成显式占位类型（如 `ArrayList<?Any>`，`None` = 未绑定，`Some(None<Any>)` = 绑定 NULL），执行结束后按需清空，并在 `set/setNull` 开头校验 `index >= 0`（越界抛 `SqlException`/`MockDbException`）。

DT：语句复用两次断言各自参数；未绑定位置断言与 `setNull` 可区分；负索引断言异常类型。

### 2.5 [中｜正确性] `MOCK-8` `toThrowOnExecuting` 在 `execution` 之后判定：声明抛异常的语句仍先跑完夹具（f_mockdb） → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在 MOCK-7 之后追加提交），**代码、用例、本标记在同一提交**（提交信息 `fix(f_mockdb): MOCK-8 toThrowOnExecuting 判定前移到夹具之前（bug-mockdb §2.5 修复标记）`；提交哈希由下一次标记同步补录）。

- 改动（`src/Statement.cj`）：`query()` / `update()` 里的 `toThrowOnExecuting` 判定从「夹具执行之后」前移到「`clearQueryResult()` 之后、`MOCKDB.execution(sql, args)` **之前**」⇒ 声明失败的语句不执行夹具、不产生结果（与真驱动一致）；参数槽的 `try/finally` 清空与 `MockUpdateResult` 快照逻辑不变（本次抛异常发生在清参数之前，参数槽保持为空即可）。
- 用例：`src/mockdb_core_test.cj` 新增 `testThrowOnExecutingSkipsFixture`（夹具记录被调用次数 + `toThrowOnExecuting = true`：断言抛 `MockDbException` **且** 夹具未被调用、`MOCKDB.getQueryResultRows()` 为空）；同时**调整既有 `testClearResetsFixture`** —— 它原先依赖「抛异常前夹具已执行」来填充夹具，改为「先正常执行一次查询填充、再置标志」，验证意图不变（`clear()` 复位全部夹具）。
- 测量证据：**修复前** PASSED 46 / **FAILED 1**（EXIT=1）：`testThrowOnExecutingSkipsFixture` 在 `@Assert(0, executed.size)` 失败（left 0 / right 1 —— 夹具被执行过，行也确实写进了结果集）；**修复后** = **47/47 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/mock8_before.log`、`/tmp/mock8_after.log`。
- 兼容性：既有异常用例 `testThrowOnExecutingQuery` / `testThrowOnExecutingUpdate` 只断言抛异常 ⇒ 不受影响；`f_orm` 不设该标志 ⇒ 无影响。

位置：`src/Statement.cj:49-55`（`update()`：先 `MOCKDB.execution(sql, args)` 再判 `toThrowOnExecuting`）、`56-62`（`query()` 同样）

影响：`MOCKDB.toThrowOnExecuting = true` 的语义是「执行这条 SQL 时抛异常」，但夹具已经执行、行已写进 `queryResultList_`（在事务内不会被清，正好放大 `MOCK-1`）。于是「本应失败的语句」也留下了副作用数据，后续语句会读到；用例若在断言里检查「失败后结果集为空」会得到相反结论。

修法：把标志判定放到 `execution` 之前（真驱动也不会执行失败的语句）；README 补一句说明「置 true 时夹具不执行」。

DT：`toThrowOnExecuting = true` 后执行，断言抛异常**且** `MOCKDB.getQueryResultRows().isEmpty()`。

---

## 3. 低危 / 待验证（9 条）

### 3.1 低危（8 条）

- **`MOCK-L1` 异常无 message，诊断差**：`src/Statement.cj:52,59`、`src/Transaction.cj:49,55,61,67,73,79` 全是 `throw MockDbException()`；事务/执行的失败信息里看不出是哪条 SQL、哪个 savepoint（有 message 的只有 `MockColumnInfo` 的 `'not supported'`、`MockQueryResult.columnInfos` 与 `Statement.query(params)/update(params)` 的 `'not supported'`）。修法：带 `sql` / `savePointName` / 触发标志名。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L2` 无条件输出到 stdout，无开关**：`src/mockdb.cj:25,29-31`（默认 `EMPTY_EXECUTION` 打印 `EMPTY_EXECUTION`）、`Driver.cj:40`、`Datasource.cj:27`、`Statement.cj:30`、`Transaction.cj:47,53,59,65,71,77`。批量用例下这些是主要 I/O，且污染测试输出；多线程用例（`f_orm` 的 `DatabasePool_test` spawn 10 线程）还会交织。修法：加 `MOCKDB.verbose`（默认 false），或走 `f_log` 的 debug 级别。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L3` 编译器 10 条警告（基线 errlog 证据）**：`target/release/.build-logs/f_mockdb@fountain/…errlog` = `unused import 'std.reflect.*'`（`src/mockdb.cj:20`）、`unused variable:'params'`（`Statement.cj:26,32`）、`unused variable:'values'`（`QueryResult.cj:30`）、`overridden function 'next'/'query'/'update' should be marked with @Deprecated`（`QueryResult.cj:30`、`Statement.cj:26,32`）、`interface 'SqlDbType' is deprecated`（3 处）。修法：删死导入、参数改 `_`、给废弃重载加 `@Deprecated`（`f_orm` 的 `Statement_test.cj` 也有同类实现，可一起统一）。　**⏸ 暂不处理（2026-10-04 决定，见 §3.3）**
- **`MOCK-L4` README 与实现不一致**：`f_mockdb/README.md:17` 写 `MOCKDB.execution = {sql: String, args: Array<Any> =>`（实际 `ArrayList<Any>`）、`:26` 写 `let rows: Array<Any> = MOCKDB.getQueryResultRows()`（实际 `ArrayList<Array<Any>>`）、`:31-35` 的 `MOCKDB.metadata = {=> …}()` 写法会让读者以为可以写闭包；README 也是**唯一**文档（模块没有 `doc/` 目录），却没有 `clear()`、`rowCount`/`lastInsertId` 默认值、`execution` 默认打印 `EMPTY_EXECUTION`、以及 `queryResultColumnInfos` 为空时抛异常这些关键约定。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L5` `getMetaData()` 的两种返回语义**：`src/mockdb.cj:130-137` 未设置时每次返回**新建**的空 `HashMap`（在它上面写东西会静默丢失），设置后返回的又是 live map（外部可改夹具）。修法：统一返回副本，或文档写明「未设置即空、只读」。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L6` 驱动的入口参数被忽略**：`src/Driver.cj:39-46` 的 `open(connectionString, opts)` 只打印 url、不透出连接串；`src/Datasource.cj:26-28` 的 `setOption` 只打印不保存 ⇒ 用例无法验证「连接串 / 选项是否正确传到驱动」，也无法回读选项。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L7` 事务无状态机**：`src/Transaction.cj:46-81` 允许重复 `begin()`、未 `begin()` 就 `commit()/rollback()`；`MockConnection.createTransaction()`（`src/Connection.cj:24-26`）永不失败，而 std 契约规定「已处于事务状态且不支持并行事务时应抛 `SqlException`」⇒ ORM 的事务传播/嵌套失败分支在 mock 下测不到。修法：加最小状态（`begun`），或在 README 写明「mock 不校验事务状态」。　**✅已修复（2026-10-04，见 §3.3）**
- **`MOCK-L8` `set` 的大索引会补出天量占位符（审查后新增）**：`src/Statement.cj` 的 `set<T>(index, …)` 用 `for(_ in args.size ..= index) { args.add(None<Any>) }` 补位 ⇒ `index = 1000000` 就真的分配 100 万个 `None`；真驱动按语句参数个数报「索引越界」，mock 原先不解析 SQL、定不出上界。修法：按 SQL 里的 `?` 个数定上界，越界抛 `SqlException`。　**✅已修复（2026-10-04，见 §3.4）**

### 3.2 待验证（2 条，需实测）

- **`MOCK-V1` 重复加载动态库时的驱动注册**：`src/Driver.cj:21-23` 在 `static init()` 里 `DriverManager.register('mockdb', MockDriver())`；fountain 的应用允许「同一动态库被主动加载 + 被依赖再加载」两次（`fboot run` 的 `--dylibPattern` 说明里明确提到重复加载），std 文档只写「名称和实例一一对应，本方法并发安全」，没定义同名重复注册是覆盖还是报错。验证：写一个只链 `f_mockdb` 的小程序，手动 `dlopen` 两次后 `DriverManager.getDriver('mockdb')`，观察是否异常/是否为后一次实例。　**✗ 不成立（2026-10-04 判定）**：重复加载与否由**运行时**决定 —— 用 `PackageInfo.load` 重复加载同一个动态库会直接**运行时崩溃**，不用它加载就不会重复加载；仓内唯一的加载入口是 `f_app/src/funcs.cj:61` 的 `PackageInfo.load`，一个库只会被加载一次 ⇒「重复加载 ⇒ 驱动重复注册」在本项目不可能发生，无需处理。
- **`MOCK-V2` 用例覆盖缺口（未被任何用例冻结的行为）**：`query(params)` / `update(params)` / `next(values)` 三个 `'not supported'` 分支、`getOrNull` 未 `next()` 与类型不符、`MockStatement.set` 负索引、语句复用的参数累积、`MockUpdateResult` 的惰性读取、`close()` 后的 `isClosed()`/`state`、`MOCKDB.execution` 缺省（`EMPTY_EXECUTION`）路径。现状 30 个用例全绿（§5），但这些分支一条都没测——修 §1/§2 时建议一并补上（否则改动没有回归网）。

---

### 3.3 低危批次修复记录（2026-10-04）

> 本批次一次处理 6 条低危（L1 / L2 / L4 / L5 / L6 / L7），**代码、用例、README 与本记录在同一提交**：提交 `924ec6f8`（`fix(f_mockdb): 低危批次 L1/L2/L4/L5/L6/L7（bug-mockdb §3.3）`）；尚未并入 `sts/1.3.x`（待下次同步）。
> 测量基线：**修复前** `cjpm test --no-capture-output` = PASSED 47 / **FAILED 4**（可钉的 L1×2、L5、L7）→ **修复后** = **53/53 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，编译警告 9 条无新增。日志 `/tmp/lowrisk_before.log`、`/tmp/lowrisk_after2.log`。

- **`MOCK-L1`（异常无 message）✅ 已修复**：`src/Statement.cj` 的 `toThrowOnExecuting` 分支改抛 `MockDbException('failed to execute sql: <SQL>')`；`src/Transaction.cj` 六个失败分支分别带 `begin` / `commit` / `rollback` / `release savepoint <名>` / `rollback to savepoint <名>` / `save savepoint <名>` 与 threadID。用例 `testExecutingExceptionMessage`（断言 message 含 SQL）、`testTransactionExceptionMessages`（断言含 `begin` 与 savepoint 名）；修复前两条都失败在「message 为空」。
- **`MOCK-L2`（无条件 stdout）✅ 已修复**：`MOCKDB` 新增 `public static mut prop verbose`（默认 false）与 `static func log(message)`；`open` / `setOption` / 事务六步 / 默认夹具 `EMPTY_EXECUTION` 全部改走 `log`。**端到端证据**（同一套件的日志计数）：修复前 `Transaction beginning` ×10、`Transaction committing` ×3 → 修复后 0；`testVerboseSwitch` 在 `verbose = true` 窗口内调一次 `setOption` ⇒ 日志里恰好 1 条 `Statement option`（开关双向生效）。用例 `testVerboseSwitch`（开关语义 + 两种取值下功能等价；静默本身无法在进程内断言，故以日志计数佐证）。
- **`MOCK-L4`（README 与实现不一致）✅ 已修复**：`f_mockdb/README.md` 的使用示例改成真实签名（`ArrayList<Any>` 参数、`ArrayList<Array<Any>>` 返回值），补 `MOCKDB.clear()`；新增「时序与约定」小节写明 —— 一次执行一份结果（夹具写在 `execution` 内）、参数槽执行后清空、`getOrNull` / `get` 的契约与异常、`ColumnInfo` 契约值、关闭语义（关连接不再清夹具）、`verbose` 输出开关、`MOCKDB` 公开成员清单、事务状态机、`MockDatasource.connectionString` / `options`。
- **`MOCK-L5`（`getMetaData()` 两种语义）✅ 已修复**：新增包内 `copyMap(...)`，`MockConnection.getMetaData()` 统一返回**副本**（未设置时返回空副本）。用例 `testMetadataReturnsCopy`（改副本不影响夹具与后续读取）；修复前该用例失败（读到被改写的 `changed`）。
- **`MOCK-L6`（驱动入口参数被忽略）✅ 已修复**：`MockDatasource` 记录 `connectionString`（`open` 时由驱动写入）与累积的 `options`，两者都有公开只读入口（`options` 返回副本）。用例 `testDriverOpenRecordsArguments`（`DriverManager` 取驱动 → `open('mockdb://localhost', [...])` → 断言连接串与两个选项可读回，且改副本不影响 mock）。属**接口补齐型**：修复前写不出该断言（编译不过），故没有「修复前失败」证据。
- **`MOCK-L7`（事务无状态机）✅ 已修复**：`MockTransaction` 增加 `begun_` / `finished_` 与 `requireBegun(step)` —— 未 `begin()` 就 `commit` / `rollback` / `save` / `release`、重复 `begin()`、事务已结束后再 `commit` / `rollback`，统一抛 `SqlException`（消息带动作）；失败模拟的抛点相应后移，且**模拟失败不改变事务状态**（`begin` 抛异常时 `begun_` 保持 false）。用例 `testTransactionStateMachine`；同时给 5 条既有用例补上 `begin()`（`testCommitThrows`、`testSavepointOperations`、`testSavepointSaveThrows`、`testSavepointReleaseThrows`、`testSavepointRollbackThrows`）。修复前 `testTransactionStateMachine` 失败（未 begin 就 commit 静默通过）。兼容性：`f_orm` 的事务路径始终以 `createTransaction(...).begin()` 起手（`SqlExecutor.cj:270`），`TransactionWrap` 只做委派 ⇒ mock 侧收紧不影响它。
- **`MOCK-L3`（编译器警告）⏸ 暂不处理**：2026-10-04 决定忽略（未使用参数、废弃重载未标 `@Deprecated`、`SqlDbType` 废弃提示等 9~10 条）。留档理由：纯噪声；改动会碰 `Statement.cj` / `QueryResult.cj` 里公开重载的注解，收益低。
- **顺带发现 → 已单列为 §3.1 `MOCK-L8`**：`MockStatement.set<T>(bigIndex, v)` 会真的补出 `bigIndex + 1` 个占位符（索引 100 万 ⇒ 100 万个 `None`）；2026-10-04 已修复（见 §3.4）。

---

### 3.4 `MOCK-L8` 修复记录（2026-10-04，审查后新增条目）

**✅ 修复标记（2026-10-04）**：分支 `fix/mock-1-query-isolation`（同一 worktree，在低危批次之后追加提交），**代码、用例、README 与本标记在同一提交**（提交 `0742124b`：`fix(f_mockdb): MOCK-L8 参数索引按 SQL 占位符个数定上界（bug-mockdb §3.4）`）。

- 改动（`src/Statement.cj`）：新增 `private func placeholderCount()`（数 `sql` 里的 `?` 字节，ASCII 安全）与 `private func checkIndex(index, parameters)` —— `set<T>` / `setNull` 改为先 `checkIndex(index, placeholderCount())`：`index < 0` 抛「negative」，`index >= 占位符个数` 抛「out of range, the sql has N parameters」。口径与真驱动（按语句参数个数判定越界）一致；SQL 字面量里出现的 `?` 只会把上界**放宽**，不会误拒合法绑定。
- 用例：`src/mockdb_core_test.cj` 新增 `testSetIndexBeyondSqlParametersThrows` —— 对只有 1 个占位符的 SQL 调 `set(1000000, …)` 与 `setNull(5)` 都断言抛 `SqlException`，随后用合法索引 `set(0, …)` 执行查询照常通过。
- 测量证据：**修复前** PASSED 53 / **FAILED 1**（EXIT=1），且该用例耗时 **35 270 059 ns（≈35.3 ms —— 真的分配了约 100 万个占位符之后断言失败）**；**修复后** = **54/54 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，同一用例耗时降到 **42 878 ns（≈42.9 µs，立即抛异常）** ⇒ **≈822×**；编译警告 9 条无新增。日志 `/tmp/l8_before.log`、`/tmp/l8_after.log`。
- 兼容性：现有 53 条用例里所有 `set` / `setNull` 的索引都与 SQL 占位符数量匹配（已全量核对 `f_mockdb/src` 内 `prepareStatement` × `set`/`setNull` 组合）⇒ 无行为回归；`f_orm` 的 mockdb 路径不绑定参数（`DatabasePool_test`）⇒ 无影响。
- 口径变化（有意）：在「SQL 无占位符」的语句上 `set(0, …)` 现在会抛 `SqlException` —— 与真驱动一致（语句没有参数却绑定参数属调用方错误）；README「参数槽」一节已同步。

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
- 本次审查**只读**，未改动 f_mockdb 任何代码；报告落在本分支 `.autocode/bugs/bug-mockdb.md`（与 `bug.md` 同目录）。探针文件与临时脚本已删除（`/tmp` 日志保留作证据）。
