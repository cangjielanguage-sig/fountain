# f_orm 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 24 条**：严重 3（§1.1 `ORM-1`、§1.5 `ORM-C1`、§1.13 `ORM-2`）、中 7（§2.1 `ORM-C2`、§2.8 `ORM-C5`、§2.10 `ORM-3`、§2.11 `ORM-4`、§2.12 `ORM-5`、§2.13 `ORM-6`、§2.14 `ORM-7`）、低危+待验证 14（§3）。
- **状态（截至 2026-10-05）**：`ORM-1` ✅已修复（§1.1）、`ORM-C1` ✅已修复（§1.5）、`ORM-C2` ✅已修复（§2.1）、`ORM-2` ✅已修复（§1.13，严重｜性能，分支 `fix/orm`）；`ORM-C5` ❌误判（§2.8，非缺陷：`argInSql` 是设计目的，已补 README §11.5 说明与口径用例）；`ORM-3` ⏸决定不修（§2.10，已知开销保留：否决「加静态集合」与「就地复位」两方案）；`ORM-4` ⏸决定不修（§2.11，借连接校验与默认值均不改、语句复用经四家驱动源码调研后判定不值得在 f_orm 层做）；**待修** §2.12–§2.14（性能中危 3 条）、§3 的 14 条低危/待验证（`ORM-L3` 已随 §1.13 一并消掉；`ORM-C3`：`SqlArgs.clone()` 仍共享同一 `ArrayList`，未随 §1.1 一并处理）。

## 1. 严重（本模块 3 条）

### 1.1 [严重｜正确性+性能] `ORM-1` 结果缓存的键实际只剩 SQL 文本这一维（`h` 与 `==` 代码上都含 args，失效点在 `SqlArgs`）（f_orm）✅已修复（2026-10-04）

**✅ 修复记录（2026-10-04）**

- **改动三处**：①`f_orm/src/base/SqlExecutor.cj:82-91`：`clearSql()` 里 `args.clear()` → `this.args = SqlArgs()`（换实例：旧实例从此冻结、只被缓存 key 引用）；②`f_orm/src/wrap/SqlArgs.cj`：删除 `clear()`（全仓唯一调用点已改）；③`SqlArgs.add(arg: SqlArg)` / `add(all!: SqlArgs)` 内 `h = 0`（内容变更时让 `hashCode` 的记忆失效）。
- **用例**：`f_orm/src/base/SqlResultCache_test.cj` —— `testSameSqlDifferentArgsMustNotHitCache`（不同参数不得串缓存）、`testSameSqlSameArgsStillHitsCache`（同参数必须命中，用 mock 调用计数断言 = 1）、`testCacheKeyMustDependOnArgsContent`（键只由 SQL + 参数内容决定）。每个用例用各自 SQL 文本并在结束处 `close()`：executor 与缓存按线程复用，共用 SQL 文本会互相污染。
- **修复前基线**（临时 `git stash` 掉三处改动后跑同一套用例）：`[FAILED] testSameSqlDifferentArgsMustNotHitCache`，`Assert Failed: Some(2) != values[1]`，`DEBUG case1: first=Some(1) second=Some(1)` 且 mock 只被调用 1 次 ⇒ **误命中复现** ✓。
- **修复后**：3/3 PASSED；`case1: first=Some(1) second=Some(2)`（两次都真的执行）、`case2 fires=1`（同参数命中缓存）、`key1 == key2`。
- **③ 的必要性（本次探针实测）**：`SqlExecutor` 在两次查询之间会执行空 SQL 的检查类语句，把当时**还是空**的 `SqlArgs` 实例哈希一次（`h = H([])`）；之后 `add` 填了参数却不让记忆失效 ⇒ 同样参数的两个 key 哈希不同。探针证据（做了 ①②、未做 ③ 时）：

  ```
  PROBE get: sql=[select ? as case2] keyHash=6578699273789510219 args=[(0, Int64, 7)] hit=false
  PROBE put: keyHash=6578699273789510219 args=[(0, Int64, 7)]
  PROBE get: sql=[select ? as case2] keyHash=5544947046349531277 args=[(0, Int64, 7)] hit=false   ← 同 sql、同参数内容，哈希却不同
  PROBE path: sql=[] args=[[]]                        ← 空 SQL/空参数也会走缓存路径并被哈希
  PROBE put: keyHash=4727480832456190669 args=[[]]
  ```

  补上 ③ 后：两侧 `keyHash=5544947046349531277` 一致，`hit=true`、`fires=1`。
- **失败模式提醒**：`h` 的记忆必须与内容同生命周期。只做 ①② 会从「返回别的参数的结果」变成「缓存永不命中」（每次查询都多打一次库），两者都不可接受。
- **顺带**：`f_orm` 测试套件原本编译不过（`src/base/Driver_test.cj` 的 `DatasourceCreatorImpl` 缺接口要求的 `driverName`；`src/wrap/DatabasePool_test.cj` 是用了旧构造签名 + 无限 `spawn` + `sleep(30s)` 的脚手架）⇒ 已修好，见单独提交。


位置：`src/base/SqlExecutor.cj:25-39, 48, 82-87, 134-138, 840-849`、`src/wrap/SqlArgs.cj:23-25, 106-120`

```cangjie
// SqlExecutor.cj:28    h = HashBuilder().append(sql).append(args).build()          // ← 代码上确实算了 args
// SqlExecutor.cj:34    refEq(this, other) || (h == other.h && sql == other.sql && args == other.args)   // ← 也确实比较了 args
// SqlExecutor.cj:48    private var args: SqlArgs = SqlArgs()                       // 整个 executor 只有这一个实例，之后从不重新赋值
// SqlExecutor.cj:82-87 protected func clearSql(...) { sql_ = ''; if(clearArgsAfterExec){ args.clear() } }
// SqlArgs.cj:23-25     protected func clear() { args = ArrayList<SqlArg>() }       // 只换内部 list，实例身份不变
// SqlArgs.cj:106-117   private var h = 0; public func hashCode() { if (h == 0) {...} h }   // 记忆值，clear()/add() 都不复位
// SqlArgs.cj:118-120   operator func ==(other) { refEq(this, other) || args == other.args }
// SqlExecutor.cj:841   let key = SqlCacheKey(sql, args)                            // 全仓唯一的 key 构造点，用的就是这个字段实例
```

影响：**代码上** `h` 与 `==` 都把参数算进去了，但 `args` 这一维度被三处实现抵消，key 的**实际**区分能力只剩 SQL 文本：

1. `SqlExecutor.cj:48` 整个生命周期只有**一个** `SqlArgs` 实例（全仓 grep 无 `args = SqlArgs()` 之类的重新赋值；每次收尾走 `clearSql()` → `args.clear()`，见 `82-87`，而 `SqlArgs.clear()` 只替换内部 `ArrayList`，**实例身份不变**）⇒ 两次查询的两个 key 指向**同一个** `SqlArgs`；
2. `SqlArgs.==` 先 `refEq(this, other)`（`118-120`）⇒ 同一实例**恒真** ⇒ `args == other.args` 恒真；
3. `SqlArgs.hashCode()` 把结果记忆在 `h` 字段（`106-117`），而 `clear()`/`add()` 都不复位 ⇒ 同一 executor 构造出的所有 key，`h` 里的参数分量都等于**第一次**算出的那份 ⇒ `h == other.h` 也恒成立。

⇒ 两次「同 SQL 文本、不同参数」的查询，key 相等。触发条件与后果：

- 缓存需跨查询存活：`execute` 的非事务路径执行完就 `close()`（`830-836`），而 `close()` 里的缓存清理带 `tx.isNone()` 守卫（`134-138`，事务内直接跳过）⇒ **事务内**同一 SQL 文本的第二次调用**直接返回第一次的结果**（静默错数据）；若两次期望的 `T` 不同，则抛 `type of cached data with key ... does not match`（`844`）。
- `README.md:384-389` 写的是「键基于 SQL 与参数」——那描述的是代码意图，与实际行为不一致。
- 边界：若 `HashBuilder().build()` 恰好得 0，第 3 条不成立（`hashCode()` 每次重算）⇒ 两个 key 的 `h` 可能不同、`cache.get` 不命中，退化为「缓存不复用、事务内每个参数组合新增一个条目」（不返回错数据，但条目随查询数增长）。

修法（2026-10-04 二次复核后定稿）：

1. **修复本体（两步，即为此条的正解）**：`SqlExecutor.cj:85` 的 `args.clear()` 换成 `this.args = SqlArgs()`，并删掉 `SqlArgs.clear()`（全仓只此一个调用点）。
   为什么这就够了：两条 key 只有在**同一个 `SqlArgs` 实例**上才会被 `refEq` 短路，而同一实例只可能来自「同一个保留窗口」（`clearArgsAfterExec: false` 期间没有任何重置）。在该窗口内 `SqlArgs` 的内容只可能被 `add`/`add(all:)` **追加**（`clear()` 已删，模块内再无替换内容的入口），从下标 0 开始的前 n 个参数（n = 该 SQL 的占位符个数）始终是同一批值，且 `SqlArg` 不可变（`private let value`）⇒ 有效参数不变，命中旧结果**是正确的**，不会返回错数据。而默认路径（`clearArgsAfterExec: true`）每次执行后换新实例 ⇒ 旧实例冻结、只被 key 引用 ⇒ 同一 SQL 文本 + 不同参数必产生不同实例 ⇒ `refEq` 不再短路，退化为内容比较（`SqlArg` 的 `==`/`hashCode` 均是内容比较）⇒ 键不再相等，误命中消失；同参数重复查询依旧命中（缓存不被修坏）。
2. `SqlArgs.hashCode()` 的 `h` 记忆必须与内容同生命周期：内容变更（`add` / `add(all:)`）时复位为 0 —— 实测必需（见上面的修复记录 ③），否则换实例后缓存永不命中；`cache` 容量上限可选。
3. **可选（与正确性无关，只为命中率）**：让 key 持**冻结快照** —— `SqlArgs.clone()` 改成真拷贝（`ArrayList<SqlArg>(args)`，顺带修 `ORM-C3`）+ `SqlExecutor.cj:841` 用 `SqlCacheKey(sql, args.clone())`。保留窗口内 key 现在持 live 实例，实例被追加后同一实例的旧 key 与后续新实例的 key 不再相等 ⇒ 该窗口会少命中几次、条目略增；用快照可消掉这点小损失。

修完补三条 DT：①同一 executor 上「同 SQL、不同参数」两次查询结果必须不同（事务内执行才稳定复现，非事务路径每次 `close()` 清缓存）；②同参数重复查询**应命中缓存**（确认没修成「永不命中」）；③事务内同一 SQL 用不同参数查两次，断言两次都真的落到数据库（日志或行数计数）。

**关于 `SqlArgs.clear()` 的处理**（2026-10-04 讨论，含一次自我修正）：

- 单独删声明 ✗：全仓唯一调用点 `SqlExecutor.cj:85` 编译不过（`grep 'args\.clear()'` 仅此一处）。
- 连调用一起删 ✗：参数在 executor 生命周期内只增不减 —— `SqlArg` 的序号来自 `args.size`（`SqlArgs.cj:38`），绑定是 `statement.set<T>(index, x)`（`SqlArg.cj:20-28`），`args.set(stmt)`（`SqlExecutor.cj:400`）会把历史参数一并绑定 ⇒ 后续查询序号错位、绑定多余参数；参数值（`String`/BLOB/`InputStream`）随查询累积（事务内为整个事务）；还会破坏 `clearArgsAfterExec: true`（默认）那条「每条 SQL 执行完清参数」的隔离契约（`SqlPartial.cj:295-301` 正是靠 `false` + 显式 `clearSql(clearArgsAfterExec: true)` 实现「分页 count 与 select 共用一批参数、之后收尾清空」）。
- **删声明 + 调用点换成 `this.args = SqlArgs()` ✓ 就是正解**（见上面第 1 条）。`SqlArgs` 全仓只被 `SqlCacheKey` 与 `SqlExecutor` 持有 ⇒ 换实例不影响别处；`add` 的序号从 0 重新开始 ⇒ 绑定正确；不累积。
- **自我修正**：我先前写过「`clearArgsAfterExec: false` 的保留路径仍会误命中、必须靠 key 持快照才能关掉」——**这个判断不成立**。它默认了保留窗口内还能替换参数，而替换的唯一入口就是 `clear()`；删掉它之后，保留窗口内的内容只能追加，有效参数不会变，因此命中旧结果不构成错数据。快照因此从「必需」降级为「可选（命中率）」。

### 1.5 [严重｜正确性] `ORM-C1` `iterator`/`singleIterator` 在返回前就把结果集关掉了（f_orm）✅已修复（2026-10-04）

**✅ 修复记录（2026-10-04）**

- **改动（6 处）**：
  1. `SqlExecutor.cj:893` 语句级 `execute` 与 `:914` 结果级 `execute` 都加 `closeBeforeReturning: Bool`：是否关闭 Statement、是否关闭结果集并复位 `activeQueryResult` 统一听这个开关；消费型路径（`first`/`singleFirst`/`list`/`one`/…）传 `true`，语义不变；
  2. 新增迭代器专用通道 `SqlExecutor.cj:964` `executeIterator`（= `execute(false, …)`）；`singleIterator*`（`:484/:487/:492`）与 `iterator<T>(mappers)`（`:547`）改走它 ⇒ **返回前不关结果集**；
  3. 非事务收尾跳过「已移交」的查询：基座 `exec()` 的 `finally` 改为 `if (!activeQueryResult) { this.close() }`（`:852`）——否则返回迭代器时就把连接还掉了；Statement 也保留在 `this.stmt` 槽位，由 `SqlExecutor.close()` 统一关闭；
  4. 移交结果集的查询不写结果缓存（`:866`）：迭代器有状态，否则同一「SQL + 参数」的第二次调用会命中缓存拿到同一个已被消费的迭代器（还会绕过 `activeQueryResult` 守卫）；
  5. `QueryResultIterator.cj:34` 新增公共父类 `AbstractQueryResultIterator<T> <: Iterator<T> & Resource`，持有 `result` + **`statement`** + `executor`：`close()`（`:45`）顺序固定为 **结果集 → 语句 → `executor.releaseActiveQueryResult()`**（`:166`，= 复位 `activeQueryResult` + `close()`，**不关语句**；语句由迭代器自己关，关失败只记日志）。**连接是否归还**由 `close()` 自己的 `tx.isNone()` 判断：不在事务中时归还连接，在事务中不动它（留给事务结束后的 `close()`）；
  6. `next()`（`QueryResultIterator.cj:77/:101`）读尽即自动 `close()`；三个入口的静态返回类型统一收窄/统一为 `Resource`（`Iterator<T>` 本身不继承 `Resource`，仓颉库同款实现如 `EmptyIterator<T> <: Iterator<T>`）。
- **用例**：`f_orm/src/base/QueryResultIterator_test.cj`（5 条）—— 非事务返回后可逐行读、读尽自动关闭且 Statement+Connection 已关；事务中 `close()` 关结果集与语句、连接仍在（`testIteratorCloseInTransactionKeepsConnection`）、同一事务可继续查询，事务结束后连接才关；未关闭的迭代器拦住同 executor 的后续查询；`try (it = …)` 自动关闭；`singleIterator<T>(column:)` 按列名取值（同批修复，见 §2.1）。判据用 `it.isClosed()`（mock 的 `MockQueryResult.close()` 会置内部 `closed_`）与 `ex.isClosed()`。
- **修复前基线**（把 3 个入口临时退回消费型 `execute` 后跑同一套用例）：**5/5 FAILED**，首条断言即 `Assert Failed: (false == it.isClosed())`（返回时结果集已关闭）⇒ 与本节描述的形态一致 ✓。
- **修复后**：`f_orm` 构建 **exit 0**（0 error）；`cjpm test` 该项目 **32 PASSED / 1 ERROR / 0 FAILED**，新用例 **5/5 PASSED**。唯一 ERROR 是既有环境相关用例 `f_orm.wrap / ORMConfigTest.testPoolMaxWaiting`（断言 45s/1m，本机读到 4s；与本次改动无关）。
- **残留（已随 2026-10-05 调整消除）**：原先「事务中移交出去的 Statement 只由 `this.stmt` 单槽位引用，被同一事务里的下一条 SQL 覆盖而漏关」⇒ 现在 Statement 由迭代器直接持有并自行关闭，不再依赖槽位；`SqlExecutor.stmt` 槽位里的引用只作「迭代器一直未关闭」时的兜底（`close()` 会跳过已关闭的语句）。
- **2026-10-05 调整**：迭代器改为持有 `Statement`（原先只持 executor），`close()` 顺序固定为 结果集 → 语句 → `releaseActiveQueryResult()`；后者不再涉及语句 ⇒ 上一行的残留随之消失。
- **顺带**：`QueryMappers.iterator(result)` 签名改为 `iterator(result, executor)`（迭代器需要 executor 才能做事务感知收尾）；README §5.2 / §13.2 / §13.4 已同步。

位置（修复前形态）：`src/base/SqlExecutor.cj:473-482, 533-537`（关闭点在 `904-906`）

```cangjie
// SqlExecutor.cj:474  execute<Iterator<T>> {r => SingleColumnIterator<T>(r, index: index)}
// SqlExecutor.cj:534  execute<QueryResultIterator<T>> {r => mappers.iterator(r)}
// SqlExecutor.cj:904-906  } finally { try{ r?.close() } ...
// SqlExecutor.cj:919        activeQueryResult = false
```

影响：`iterator`/`singleIterator` 把迭代器包在 `execute<T>` 里返回，而该重载的 `finally` 是 `r?.close()` ⇒ 方法一返回底层结果集已关闭；`activeQueryResult` 也随之复位（后续查询不会报「上一个结果集还活着」）。`f_mockdb` 的 `QueryResult.close()` 是空实现（`f_mockdb/src/QueryResult.cj:53-56`）所以单测看不出来；**待验证**：真实驱动（postgres/mysql）下 `close()` 后 `next()` 的行为。修法：`iterator*` 路径不走 `finally close`，把资源所有权交给返回的迭代器。

### 1.13 [严重｜性能] `ORM-2` 逐单元格做运行时类型分派 + 字符串 `typeName` 匹配（f_orm）✅已修复（2026-10-05）

**✅ 修复记录（2026-10-05，分支 `fix/orm`）**

- **改动**：`f_orm/src/wrap/QueryResultWrap.cj`（1 文件，33+/29-）：
  1. 新增 `private let columns: Array<ColumnInfo>`：构造期取一次 `result.columnInfos`，复用于 `columnInfoMap` 构建、`columnInfos` 属性与取值路径 ⇒ 每格的 `result.columnInfos` 穿透与 `toMap()` 的重复访问（`ORM-L3`）一并消掉；
  2. 把「列类型 → 取值」的 18 分支 `match(typeName)` 从 `getOrNull<T>(index)` 的逐单元格内联闭包抽成 `private static func makeReader(result: QueryResult, typeName: String): (Int64) -> Any`，取值器**按需构造**（不预先为每列建表），行内循环改为 `i + indexStartsWith |> makeReader(result, columns[i].typeName) |> list.add`；
  3. 第二级 `match(list[index])`（类型窄化 / `convertFromString` 兜底 / 报错口径）一行未动，语义不变。
- **为什么 `makeReader` 必须是 `static`**：仓颉不允许构造期调用实例方法（探针实测报 `'x' is not allowed to be accessed before all member variables are initialized`）；闭包体里 `result.getOrNull<?T>`（`?String` 等）向上转 `Any` 可编译（`Array<(Int64) -> Any>` + 分支闭包，最小探针 `EXIT=0`）。
- **用例**：`f_orm/src/wrap/QueryResultWrap_test.cj`（5 条）—— ①按索引/按列名取值同源、未知列名与越界索引 → `None`、列信息顺序；②18 个取值器分支与别名全覆盖（String / Clob·Blob（最小 `InputStream` 实现，按 tag 断言取回同一实例）/ Binary / Decimal / Bool / Int8…UInt64 / Float32 / Float64 / DateTime / 空 `typeName` / Duration / 未知 typeName 走 String 兜底）；③`indexStartsWith` 非 0 的驱动（`Config.set` 把探针驱动的 `…_indexStartsWithZero` 置 false）逻辑列 i ↔ 物理列 i+1；④驱动给 String、请求数值类型走转换兜底，不可解析抛 `ORMException`；⑤`next()` 按行重置取值缓存。
- **前后对照（同一套用例、同一台机器）**：把 `QueryResultWrap.cj` 临时还原为 HEAD 再跑 —— 新用例 **5/5 PASSED**（钉的是语义不变，故两边都必须过）；修复前全项目 **TOTAL 40 / PASSED 39 / ERROR 1 / FAILED 0**，修复后一致（唯一 ERROR 仍是既有环境相关 `ORMConfigTest.testPoolMaxWaiting`）。
- **计时对照**（探针 `.autocode/tmp/orm2_mapList_bench.cj`，20 列 × 2000 行 × 3 轮取最优；拷回 `f_orm/src/base/` 可复跑）：
  - `SqlExecutor.mapList()`（端到端，含夹具 / 每行 HashMap / 执行器与池开销）：前 **58.8ms** → 后 **76.9ms**（同期各轮读数在 58–115ms 间漂移，机器上有并行会话在构建 ⇒ 差异在噪声内）；
  - `QueryResultWrap.toMap()` 循环（纯 wrap 逐列取值）：前 **54.5ms** → 后 **54.8ms**（无差异）。
  ⇒ **mockdb 口径下前后无可辨差异**：mock 的 `columnInfos` 本就是缓存数组，省掉的每格属性访问本来就很便宜。本条的实际收益是「不再逐格穿透 `result.columnInfos`」+ 列信息只取一次 + 判定收敛到每列一次；**真实驱动下是否显著取决于各驱动 `columnInfos` 是否每次分配** —— 即 `ORM-L3` 的验证项（`columnInfos` 是否已缓存数组），未实测。
- **注意（既有口径，未改）**：`toMap()` 自己的 `match(typeName)` 只认一小组别名，`text`/`money`/`int4`/`UInt16` 等会抛 `SqlException: Unsupported typeName …`（探针初版因此报错）；属 `toMap()` 的既有行为，不在本条整改面。

位置（修复前形态）：`src/wrap/QueryResultWrap.cj:46-107`（配合 `base/QueryMappers.cj:76-82`）

```cangjie
// QueryResultWrap.cj:47    let columns = result.columnInfos
// QueryResultWrap.cj:53-75 for (i in list.size..=index) { ... match(column.typeName){ case 'SqlChar'|'SqlVarchar'|... } }
// QueryResultWrap.cj:107   match(list[index]){ case x: T => x ... }   // 未命中再进 convertFromString 的 match 链
```

影响：`QueryMappers.map()` 对**每一行每一列**调用取值路径 ⇒ 调用频率 = 行数 × 列数，是模块内最热的代码。每个单元格都要：一次 `columnInfos` 属性访问、一次大 `match`（`Any` 类型判定）、未命中时又一次 `match(None<T>)` 链。修法：构造 `QueryResultWrap` 时按列预算好「取值函数/类型标签表」，行循环里只做一次数组查表 + 一次 `as T`；把 `columnInfos` 在构造时取一次存字段（同时消掉 §3.1 中 `ORM-L3` 的 O(n²) 风险）。

## 2. 中（本模块 7 条）

### 2.1 [中｜正确性] `ORM-C2` `SingleColumnIterator` 忽略 `column` 参数（f_orm）✅已修复（2026-10-04）

**✅ 修复记录（2026-10-04）**

- **改动**：`QueryResultIterator.cj:86` 的 `next()` 改为 `column` 非空时走 `result.getOrNull<T>(column)`，否则走 `index`（默认 0）；两者同时给出时以列名为准（与 `singleFirst<T>(column:)` 的取值口径一致）。
- **用例**：`QueryResultIterator_test.cj / testSingleIteratorByColumn` —— 同一行第 0 列 `id=7`、第 1 列 `name='bob'`，`singleIterator<String>('name')` 必须取到 `bob`；修复前该用例 FAILED ✓（随 §1.5 的修复前对照跑一并复现）。
- **文档**：README §13.4 的「已知问题」条目已删除并改写为正确语义（原条目指向的 §19.6 在 README 中并不存在，属死链）。

`src/base/QueryResultIterator.cj:34-46`（修复前）的 `next()` 只用 `index`，而 `SqlExecutor.cj:478-482` 的 `singleIterator<T>(column:)` 把 `column` 传了进来 ⇒ `singleIterator<String>('name')` 实际读第 0 列（静默读错列）。

### 2.8 [误判｜非缺陷] `ORM-C5` `argInSql` 把任意 `ToString` 值原样拼进 SQL（f_orm）✓已复核 → ❌误判（2026-10-05：设计目的，非缺陷）

**❌ 误判标记（2026-10-05）**：**判定为设计目的，不修改行为**（用户口径）。`argInSql` 是显式打开的「把值内联进 SQL 文本」开关，用于固定列名 / 表达式 / 驱动认得的关键字这类**必须内联的受控内容**；「绕过参数化」正是它的定义，不是缺陷。本轮只做文档与用例，代码与标记在同一提交：

- **README**：§11.2 / §11.3 / §11.4 的 `argInSql` 条目均标注「见 11.5，谨慎使用」；新增 **§11.5「`argInSql`：把值直接拼进 SQL（谨慎使用）」**，写明**调用时实际会发生什么**（`ToString` 值按 `toString()` 原样拼接、不转义、不加引号、不绑定；非 `ToString` 值回落参数绑定；`IN`/`NOT_IN` 逐元素判定、可内联与绑定混用；`ChooseCondition` 的 `()` 只写片段）与后果边界（注入面、字符串要自带引号、值里别含 `?`、默认路径仍是参数化）。
- **用例**：`f_orm/src/base/ArgInSql_test.cj`（7 条，借 `MOCKDB.execution` 观察实际发给驱动的 SQL 与绑定参数）：默认参数化 / `argInSql`+`ToString` 内联（String 与 Int64）/ `argInSql`+`InputStream` 仍走 `?` 绑定 / `argInSql`+不可绑定的非 `ToString` 值抛 `SqlException: Unsupported data type` / `IN` 混用（`in (1,?)`）/ `LoopCondition` 内联 / `ChooseCondition` 的命中分支与 `()` 分支。
- **口径补正（写用例时实测）**：`argInSql` 下「非 `ToString` 值回落绑定」并非对所有类型成立 —— 绑定走 `SqlExecutor.add(Any)`（`SqlExecutor.cj:821-828`）：`ToString` → 按运行时类型绑定或转 `toString()` 文本、`InputStream` → 绑定、**其它类型直接 `throw SqlException("Unsupported data type")`**。README §11.5 的表格与边界已按这个真实口径写。
- **来源**：用户 2026-10-05 指示「这是设计。在 README 说明调用时会发生的结果，标注谨慎使用」。
- **顺带发现（未修，待定）**：核对 README 示例时发现 **§11.3 的 `executor.choose` 示例按当前 SDK（1.3.0-alpha）编译不过** —— ① `{ ('username like', '%${name}%') }` 这类字面 lambda 在 `() -> (String, Any)` / `() -> String` / `() -> Any` 三个重载之间**歧义**；② 元组 lambda 需显式写 `{=> ...}`（`{ (tuple) }` 直接报语法错）；③「只有片段、没有值」的分支（如 `1 = 1`）不配 `argInSql` 会为该片段留下一个多余 `?`。已验证的可用写法：实参先赋给带类型的局部变量（如 `let likeBranch: () -> (String, Any) = {=> ('username like', '%${name}%')}`）再传（探针 `.autocode/tmp/ormc5_overload_probe.sh`、`ormc5_choose_probe.cj`、`ormc5_tuple2_probe.cj`）。本轮只做 §11.5 与 `argInSql` 标注，**未改 §11.3 示例**——是否另立条目或顺手修由用户定。

**以下为审查时的原始判断（留档对照；其中「传入 `String` 时」的说法不准确——实际按 `ToString` 分派，数字/时间等绝大多数类型同样内联）**：

位置：`src/base/LoopCondition.cj:97-107`、`src/base/MeetCondition.cj:52/63/80/100/124-130`、`src/base/ChooseCondition.cj:83/95`（报告原文写 `LoopCondition.cj:99`、`MeetCondition.cj:80-81/100-101/124-127`、`ChooseCondition.cj:86/97`，行号有小幅漂移）。修法（**不再执行**）：仅允许列名并做白名单校验，或加类型限制。

### 2.10 [保留｜已知开销] `ORM-3` 每条非事务 SQL 的 `close()` 都全量清扫脏字段注册表（f_orm）✓已复核 → ⏸决定不修（2026-10-05：保留现状）

**⏸ 不修决定（2026-10-05）**：维持现状、不进修复队列，已知开销登记在案。用户口径与两轮方案评估：

- **方案 A（加静态集合，只清「曾置过 `beforeDirty`」的类型）→ 否决**：`setBeforeDirty<T>()` 是每条加载 PO 的查询都要走的热路径，加集合等于给它加一次写；而 `clearAll` 无论是否用集合都要逐个类型复位（`beforeDirty` 标志就存在 `DIRTY_TAGS` 的条目里），且会多出一份**必须与 `beforeDirty` 永远同步**的状态——一旦漂移，`setDirtyField` 会静默漏记脏字段（`UPDATE(dirty: true)` 少更新列），代价大于省下的开销。
- **方案 C（把 `beforeDirty` 挪到引用型 holder、`clear` 就地复位，省掉每类型一次结构体分配 + 一次 `ConcurrentHashMap` 写；遍历次数不变）→ 同样不做**：收益不足以动这段代码。
- 报告原文的「成本 = O(已注册类型数) 次哈希查找 + 等量分配」**仍成立**，作为**已知开销**保留。`ORM-L7`（`clearAll()` 只清调用线程 + ThreadLocal 长期持有字段名集合）是独立的低危条目，不随本条处理。

位置：`SqlExecutor.cj:157` → `DirtyTag.clearAll()`（`DirtyTag.cj:66-79`，遍历**所有已注册 PO 类型**并逐个新建 `DirtyTag` 写回 `ConcurrentHashMap`）；`SqlExecutor.close()` 在每条非事务执行（含迭代器 `releaseActiveQueryResult()`）后都会走到。

### 2.11 [保留｜已知开销] `ORM-4` 每次执行都重新 `prepareStatement`，借连接还额外 `select 1`（f_orm）✓已复核 → ⏸决定不修（2026-10-05：保留现状）

**⏸ 不修决定（2026-10-05）**：三个子项都维持现状、不进修复队列（用户逐项拍板）：

1. **借连接校验**（`checkOnBorrowing` 默认 true ⇒ 每次借出多打一条 `orm_databasePoolCheckSql`，默认 `select 1`）→ **不改**：不改默认值，也不加文档说明（README §3.3 配置表已列出该开关与 `checkSql`）。
2. **把 `checkOnBorrowing` 默认值改成 false** → **不改**：属行为变更，用户明确不做。
3. **语句复用**（按 SQL 文本缓存 `Statement`）→ **不做**：技术可行（见下方驱动调研），工程上不值得在 f_orm 层做——理由见「结论」。

**驱动调研（2026-10-05，读源码确认「Statement 能否缓存」；本机路径 + 版本 tip）**：

| 驱动 | 可复用？ | 关键证据（文件:行） | 对 f_orm 层缓存的意义 |
|---|---|---|---|
| `ZhaoJun-zfh/postgres-driver`（`D:\docs\work\cangjie\projects\postgres-driver`，tip `b9b4cca`，2026-09-28） | 是 | `pg_statement.cj:53-142`：`execute` 结果一次性读完、`close()` 幂等；**驱动自带 LRU 语句缓存** `PgStatementCache`（`pg_statement.cj:158-260`），容量 `PgDsn.statementCacheSize` 默认 **32**（`pg_conn.cj:20`；DSN `statement_cache_size`，0=关，负值报错 `pg_dsn.cj:321-322`）；命中不发 Parse（`pg_conn_query.cj:427-441`，批量 `pg_conn_batch.cj:31-33`）；DDL 后必须 `clearStatementCache()`（`pg_conn_statement.cj:102-135`），`drain()` 供连接关闭/**回滚**整体丢弃（`pg_conn.cj:415`）；cdbc 适配器 `cdbc_statement.cj:56-74` 的 `query()/update()` 自动走该缓存、`close()` 只置标志 | **零收益且重复**：f_orm 再加一层只是多一份缓存（f_orm 现在的 `prepareStatement` 对它只是廉价对象构造） |
| `aibrary/pgsql-driver`（`…\pgsql-driver`，tip `64d9fc1`，2026-06-23） | 是 | `statement.cj:25-159`：构造即 Parse + Describe（服务端命名语句）；执行后 `resetParams()`（`:142-146`）⇒ 每次必须全量重绑，否则 `no value specified for parameter N`；结果为缓冲的 `PgQueryResult(…, rows)`（无游标）；`close()` → `closePreparedStatement`（`:115-121`，幂等）；**全仓无语句缓存** | 缓存有**真实收益**（省每次 Parse/Describe 往返），但需 f_orm 自建服务端命名语句的生命周期管理 |
| `Cangjie-SIG/mysql-driver`（`…\mysql-driver`，tip `da987f2`） | 是 | `cdbc/connection.cj:59-71`：CRUD 首关键字 → `ServerPrepareStatement`（真服务端 prepare），其余 → 客户端拼串；`prepare_statement_server.cj:44-57/121-160`：构造即 `sendPrepare`、**执行后参数重置为全 None**（漏绑会**静默发 NULL**）、`close()` **二次调用抛 `SqlException`**；`prepare_statement_client.cj:104-150`：每次拼 SQL 文本执行、参数不随执行清空 | CRUD 走 server 模式 ⇒ 缓存能省每次 `COM_STMT_PREPARE`；但需 `isClosed()` 守卫 + 全量重绑不变量 |
| `Cangjie-SIG/mariadb-driver`（克隆在 `.autocode/tmp/drivers/mariadb-driver`，tip `f21a83a`，2026-07-02） | 是 | 与 mysql 版同源：`src/cdbc/prepare_statement_server.cj` 与 mysql 版差异仅包名/导入/一处方法拼写（`…WithCursor` vs `…WithCurosr`）；客户端版多一个拼好 SQL 的文本缓存（`cachedSql`，`set()` 时失效） | 同 mysql 的结论 |

**四家共同前提**（决定能否安全复用）：①结果集都一次性缓冲（除 mysql/mariadb 显式 `fetchSize` 走游标路径）；②语句是**服务端会话资源**（postgres 命名语句 / mysql·mariadb stmt id）⇒ 缓存必须有上限与淘汰，且连接销毁、DDL、回滚时失效；③参数必须每次全量重绑（f_orm 现有 `args.set(stmt)` 即全量 ✓）；④二次 `close()` 在 postgres 两家幂等、在 mysql/mariadb 抛错 ⇒ 关闭前一律 `isClosed()` 守卫（f_orm 现有守卫 ✓）。

**结论**：技术上四个驱动的 Statement **都可缓存**；但 f_orm 层做等于「对 ZhaoJun postgres 是重复实现（该驱动已内建 32 条 LRU + DDL/回滚失效处理）、对其余三家是把驱动已有的生命周期语义（按连接的缓存 + 上限淘汰 + 连接销毁/DDL/回滚失效 + 参数重绑不变量 + `StatementWrap` 所有权改动）在 f_orm 里重写一遍」，且真机验证缺位 ⇒ **不做**。将来若要做，依据本调研直接照 ZhaoJun 驱动那套（LRU + `clearStatementCache` 语义）移植即可。

位置：`SqlExecutor.statement`（`SqlExecutor.cj:409-417`，每次 `prepareStatement`）、`close()`（`:143-149` 关语句）、`DatabasePool.cj:111-125` + `ORMConfig.cj:201-203`（借连接校验开关）。

### 2.12 [中｜性能] `ORM-5` 每次拼条件片段都「动态构造正则 key + 查缓存 + 临时串」（f_orm）

`Condition.cj:65-67`、`TableClause.cj:39-49`、`imports.cj:35-37`：这些函数被 `WHERE/AND/OR/NOT/HAVING/ORDER_BY/GROUP_BY/SET` 每次调用 ⇒ 每构造一次动态 SQL 触发数次。修法：固定模式用 `static let` 的 `Regex` 常量；`trim` 用 `trimAscii` 手工裁剪。

### 2.13 [中｜性能] `ORM-6` 批量条件 DSL 循环体里逐元素大 `match` + `SqlArg` 分配（f_orm）

`LoopCondition.cj:85-113`、`MeetCondition.cj:41-111`、`ChooseCondition.cj:76-116`：`IN`/批量 insert 的参数规模就是业务集合大小（可上千）。修法：固定类型走参数化（`?`），把类型判定收敛。

### 2.14 [中｜性能] `ORM-7` `RootDAO.arg<I,T>(value)` 逐元素进入 40+ 分支 `match`（f_orm）

`RootDAO.cj:319-377`（`IN`/`NOT_IN` 于 `435-448`，`LogicalExpr.InExpr` 于 `175-181`）：上千 id 的 `IN` 就是上千次大 `match` + 两次对象分配。修法：把类型判定收敛为一次（或按静态类型分派）。

## 3. 低危 / 待验证（本模块 14 条）

### 3.1 低危（10 条）

**健壮性 / 正确性**

- `ORM-C3` `SqlArgs.cj:26-28`：`clone()` 直接共享同一 `ArrayList`，不是快照（日志路径之后再 `add` 会污染已传出的「副本」）。
- `ORM-C4` `SqlExecutor.cj:77`（SQL 短于 6 字符越界）、`DatabasePool.cj:112`（`checkSql` 配短于 6 字符越界）：无长度保护的 `[0..6]` 切片；对比 `SqlPartial.cj:288` 有 `size >= 8` 保护。

**内存 / 清理**

- `ORM-L7` `DirtyTag.cj:26, 72-79` + `SqlExecutor.cj:44-45`：`clearAll()` 只清**调用线程**的 `dirtyFields`；`currents/current` 只在 `close()` 时 `remove` ⇒ 线程池 + 多 PO 类型下 ThreadLocal 持有整组字段名集合。

**性能微项**

- `ORM-L1` `SqlExecutor.cj:71-81`：`setSql` 每次做全串正则替换 + 两次 `trimAscii` + `[0..6]` 子串（见 `ORM-C4`），可换 `startsWithIgnoreAscii`。
- `ORM-L2` `SqlExecutor.cj:386-393, 859, 866`：每次执行都 `args.clone()`（实为共享，见 `ORM-C3`）并分配日志闭包，即使日志级别不输出。
- `ORM-L6` `SqlArg.cj:502-504`：`ByteArraySqlArg.hashCode` 用 `value.toString()` 格式化整个字节数组（BLOB 参数一次性等量大字符串峰值）；修法：长度 + 抽样字节。
- `ORM-L10` `TrsactionHooks.cj:53-58`：每次注册都对整个列表 `sort`，且只增不减、无注销 API（启动期调用，影响有限）。
- `ORM-L11` `ORMConfig.cj:94-113`：`getOption/getAllOptions` 每次复制一份全局配置 Map 并对每个 key 做 `replace`（启动路径）。

**死代码**

- `ORM-L4` `SchemaFinderMediator.cj:30-36`：构造了从未使用的 `existingTableNames`（`67-70` 又建了 `knownNames`）。
- `ORM-L5` `SqlDSL.cj:148-151`：`let fields = T.dataFields()` 求值后未使用。

### 3.2 待验证（4 条）

- `ORM-L3` `QueryResultWrap.cj:26-32, 970-973`：`columnInfos` 在构造与 `toMap()` 中被重复访问（宽表 + `mapList` 放大）。**验证**：各驱动 `columnInfos` 是否已是缓存数组（否则是 O(n²) 分配）。
- `ORM-L8` `DatabasePool.cj:210-228`（配合 `f_pool/BasePool.cj:44-46`）：`PooledConnection.close()` 不校验 `assigned`，无条件 `returnFn(this)`。**验证**：池是否有身份去重（若无，重复 close 会让两个借用者拿到同一连接）。修法：`close()` 首行 `if(!assigned){ return }`。
- `ORM-L9` `SqlExecutor.cj:366-385`：`connection` getter 在 `Connecting` 状态用 `while ... continue` 忙等（无 sleep/yield/超时）。**验证**：驱动是否会出现长时间异步建连。
- `ORM-C6` `SqlArg.cj:426-448`（`InputStreamSqlArg` 把流交给驱动后模块内不关闭）、`QueryMapperConverter.cj:48-50`（`StringReader(x).readToEnd()` 未关闭）。**验证**：所有权约定（驱动/调用方是否负责关闭），否则是句柄泄漏路径。

## 4. 逐模块覆盖面（原 §4.1）

### 4.1 f_orm

**结构**：`base`（`SqlExecutor` 执行器 + SQL DSL + 分页/事务/DAO 基座）、`wrap`（驱动包装：连接/语句/事务/结果集/参数 + `DatabasePool` + `ORMConfig`）、`macros`（`@QueryMappersGenerator`/`@ORMField`/`@DAO` 代码生成）、`migro`（MySQL/PostgreSQL schema 对比迁移）。热路径：`SqlExecutor.execute` → 拼 SQL → 取连接 → `prepareStatement` → `QueryResultWrap` 逐单元格取值 → `QueryMappers` 逐行映射。

**无实例的维度**：无 CFFI `malloc/free` 不对称、无 `acquireArrayRawData/releaseArrayRawData`、无 `spawn`/显式锁（并发仅靠 `ConcurrentHashMap`/`ThreadLocal`/`AtomicUInt64`，故不涉及锁范围与 spawn 粒度）、无无界对象池（`DatabasePool` 受 `maxSize`/`connectionLife` 约束）、无 Future 历史堆积、无循环内逐项 IO/日志、无循环内 `clone()`/临时大集合、无 String↔Rune/Byte 反复转换热点。资源释放总体规范（`SqlExecutor` 在 `finally` 关闭语句与结果集、`migro` 用 `resource(...)`），例外见 `ORM-C1`/`ORM-C6`。
