# 代码审查报告：f_orm / f_mvc / f_bean / f_aspect

- 审查分支：`review/orm-mvc-bean-aspect`（基线 `5a5d6cf3`，即 `sts/1.3.x` 现值）
- 审查范围：4 个模块、183 个 `.cj`、19706 行（f_orm 11587 / f_mvc 5044 / f_bean 1939 / f_aspect 1136），逐文件通读
- 审查依据：`cangjie-code-review`（性能优化 14 节 / 内存优化 11 节）；结论以「瓶颈证据 + 调用频率 + 功能等价」为准，未做实测的项一律标注
- 复核口径：所有「严重」级问题**已回到源码逐行复核**（行号见各条）；「中」及以下带 `文件:行号` 证据
- **编排方式**：按**严重程度降序**（严重 → 中 → 低/待验证），不按模块分节；同一级内按「静默错误/崩溃 → 语义与内容损坏 → 资源泄漏 → 热点开销 → 局部浪费」排序。模块归属只体现在每条编号上：`ORM-x`（f_orm）、`MVC-x`（f_mvc）、`BEAN-x`（f_bean）、`ASP-x`（f_aspect）、`X-x`（跨模块）
- 模块的结构小结与「已确认无实例」的维度集中在 §4（只作覆盖面证据，不含定级）
- 同目录另有两份归档报告（`bug-archived-20261004-2.md`、`bug-archived-on-20261004.md`），本文件是**当前活动报告**

## 0. 摘要

| 严重度 | f_orm | f_mvc | f_bean | f_aspect | 跨模块 | 合计 |
|---|---|---|---|---|---|---|
| 严重 | 3 | 4 | 1 | 5 | 1 | **14** |
| 中 | 7 | 8 | 4 | 4 | 1 | **24** |
| 低 / 待验证 | 14 | 13 | 9 | 8 | 0 | **44** |
| 合计 | 24 | 25 | 14 | 17 | 2 | **82** |

> 计数修正（2026-10-04）：§1.3 `ASP-1` 判定为**误判**（设计目的，非缺陷）⇒ 待修严重级 **13** 条（f_aspect 严重 4 条）；上表保留审查当时的原始计数。
> 二次修正（2026-10-04）：§1.4 `ASP-2` 已修复 ⇒ 待修严重级 **12** 条（f_aspect 严重 3 条）。
> 三次修正（2026-10-04）：§1.6 `ASP-4` 已修复 ⇒ 待修严重级 **11** 条（f_aspect 严重 2 条）。
> 四次修正（2026-10-05）：§1.7 `ASP-5` 已修复 ⇒ 待修严重级 **10** 条（f_aspect 严重 1 条）。
> 五次修正（2026-10-05）：§1.8 `BEAN-1` 已修复 ⇒ 待修严重级 **9** 条（f_bean 严重 0 条）。
> 六次修正（2026-10-05）：§1.5 `ORM-C1` 已修复（迭代器持有结果集/语句所有权、事务感知关闭），§2.1 `ORM-C2` 一并修复 ⇒ 严重级待修再减 1（**f_orm 严重级清零**）。**核对**：把此前已修复的 `X-1`、`ORM-1` 一并计入后，实际剩余严重级 **6** 条 —— §1.9 `MVC-4`、§1.10 `MVC-1`、§1.11 `MVC-3`、§1.12 `MVC-2`、§1.13 `ORM-2`、§1.14 `ASP-3`（前述逐次递减的「9 条」未扣减 `X-1` 与 `ORM-1`）。
> 七次修正（2026-10-05）：§1.10 `MVC-1` 判定为 ❌**误判**（「无上限」是设计目的、静态文件本就要求常驻内存；「负缓存」不成立）；§1.11 `MVC-3` 已修复 ⇒ 剩余严重级 **3** 条 —— §1.12 `MVC-2`、§1.13 `ORM-2`、§1.14 `ASP-3`（另：§1.9 `MVC-4` 已在 `fix/mvc-4` 修复，待并入 `sts/1.3.x`）。

**建议修复顺序**（即严重级内部的落地顺序）：

1. `ORM-1`（§1.1）结果缓存键退化 —— 事务内可能返回**别的参数**的查询结果（静默错数据）　**✅已修复（2026-10-04，见 §1.1 修复标记）**
2. `X-1`（§1.2）`TypeInfos.get(String)` 无限递归 —— 波及 14 处调用（f_bean 条件装配、f_aspect 三条规则、f_orm 一处）　**✅已修复（2026-10-04，见 §1.2 修复标记）**
3. `ASP-2`（§1.4）切面链共享参数槽 —— 并发下参数互串（原先并列的 `ASP-1`/§1.3 已于 2026-10-04 判定为**误判**：链按类型缓存、链尾固化首次 `callee` 是设计目的，非缺陷）　**✅已修复（2026-10-04，见 §1.4 修复标记）**
4. `ORM-C1`（§1.5）`iterator` 返回前结果集已被关闭 —— 真实驱动下不可用　**✅已修复（2026-10-04，见 §1.5 修复标记）**
5. `ASP-4`/`ASP-5`（§1.6/§1.7）参数注解规则越界崩溃 / 恒不织入　**ASP-4 ✅已修复（2026-10-04，见 §1.6 修复标记）；ASP-5 ✅已修复（2026-10-05，见 §1.7 修复标记）**
6. `BEAN-1`（§1.8）宏生成不存在的 `lookupSet` —— `HashSet`/`Set` 形参直接编译失败　**✅已修复（2026-10-05，见 §1.8 修复标记）**
7. `MVC-4`（§1.9）`download` 输出整块缓冲 —— 下载内容损坏
8. `MVC-1`/`MVC-3`（§1.10/§1.11）静态资源缓存无界（含 404 负缓存）/ WS ping Timer 每断链泄漏一个周期任务　**MVC-1 ❌误判（2026-10-05：无上限是设计目的、负缓存不成立，见 §1.10）；MVC-3 ✅已修复（2026-10-05，见 §1.11 修复标记）**
9. `MVC-2`、`ORM-2`、`ASP-3`（§1.12–§1.14）三个热点：每请求全量序列化 / 逐单元格类型分派 / 每调用重建元信息

---

## 1. 严重（14 条）

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

### 1.2 [严重｜正确性] `X-1` `f_base.TypeInfos.get(String)` 无限递归（跨模块）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/x-1-typeinfos-get`（worktree `.worktrees/x-1-typeinfos-get`，基线 `8be67951`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_base): X-1 TypeInfos.get(String) 改查 std.reflect 注册表，无限递归→InfoNotFoundException`）。

- 改动：`f_base/src/TypeInfos.cj:47` 的 `TypeInfos.get(qualifiedName)` → `TypeInfo.get(qualifiedName)`（按名称查 std.reflect 类型注册表；未注册类型由 `TypeInfo.get` 抛 `InfoNotFoundException`）。`INFOS` 缓存与双检锁保留不变。
- 用例：`f_base/src/TypeInfos_test.cj` → `TypeInfos_test.testGetByQualifiedName`（已注册全限定名返回正确 `TypeInfo`）、`TypeInfos_test.testGetUnregisteredThrows`（未注册名抛 `InfoNotFoundException`，不再递归）。
- 测量证据：**修前基线** `cjpm test --filter TypeInfos_test` 卡在 `testGetByQualifiedName`（0/2 用例，2:33 未返回），worker 进程 `f_base@fountain` 101% CPU、`VmRSS 1374372 kB`（`VmSize 2365304 kB`）、CPU 时间 2:49，无任何异常/栈溢出输出，手工 `kill` 终止 ⇒ 无限递归（持锁、吃内存）**不是**可恢复的失败。**修后** `cjpm test --filter TypeInfos_test` = `PASSED: 2, FAILED: 0, ERROR: 0`；`f_base` 全量 `cjpm test` = `PASSED: 3, FAILED: 0, ERROR: 0`（含既有 `Comparator_test.test`），两次都 `cjpm test success`（EXIT=0）。
- 未覆盖：14 处调用方（f_aspect 三条规则 / f_bean 条件装配 / f_orm 回滚规则）只做了同一 API 的直连验证，未逐个跑其端到端用例（f_aspect/f_bean 测试编译耗时长，留给对应条目修复时一并验证）。

位置：`f_base/src/TypeInfos.cj:37-51`

```cangjie
// TypeInfos.cj:37-48
public static func get(qualifiedName: String): TypeInfo {
    if (let Some(x) <- INFOS.get(qualifiedName)) { x }
    else { synchronized(MUTEX) {
        if (let Some(x) <- INFOS.get(qualifiedName)) { x }
        else { let info = TypeInfos.get(qualifiedName)      // ← 调用的还是这个重载（参数是 String）
               INFOS[qualifiedName] = info; info } } }
}
```

影响：`INFOS` 未命中时自调用同一重载（无参重载是 `get<T>()`，不参与重载决议）⇒ 无限递归 ⇒ `StackOverflow`（且持锁递归）。**调用方共 14 处**：

- `f_aspect/src/AspectRoute.cj:114, 116, 118, 140, 183` ⇒ `ArgsRouteRule`/`ReturnTypeRouteRule`/`TargetRouteRule` 三条规则一用就崩
- `f_bean/src/BeanDefCondition.cj:91, 93, 95, 97, 99, 122, 123, 124` ⇒ `@Bean[cond: Current("...")]` 一类的条件装配不可用
- `f_orm/src/base/SqlExecutor.cj:967`

修法：该分支应改为「按名称构造 `TypeInfo`」的实现（例如从 `qualifiedName` 解析包名/类型名后查 `TypeInfo` 注册表，或抛明确的「未注册类型」异常），绝不能回调自身；修完补一条 `TypeInfos.get("a.b.C")` 的单测（断言不递归、返回值或异常符合约定）。

### 1.3 [误判｜非缺陷] `ASP-1` 拦截器链把「首次调用的 `fn`」永久烧进静态缓存（f_aspect）✓已复核 → ❌误判（2026-10-04：设计目的，非缺陷）

**❌ 误判标记（2026-10-04）**：判定为**误判**，非缺陷（理由见下方判定）。分支 `docs/asp-1-design-note`（worktree `.worktrees/asp-1-design-note`，基线 `8be67951`），**代码注释与本标记在同一提交**：`31c023bf docs(f_aspect): 补切面链缓存的设计说明注释；bug.md §1.3 ASP-1 判定为误判`；该分支已并入 `sts/1.3.x`（合并提交 `b1a706ad`）。代码侧设计说明见 `f_aspect/src/Aspects.cj:25-33`（`aspects` 声明处）与 `f_aspect/src/Aspects.cj:44`（链尾 `{args => fn(args)}` 处）。收尾时 worktree 与分支已按约定删除（分支 was `31c023bf`）。

**判定（2026-10-04）：误判，非缺陷。** 链按「(类型, 函数)」**只在切点函数首次被调用时构建一次、之后一直复用**，以及由此产生的「链尾固化首次调用传入的 `callee`（含该次调用的接收者）」，两者都是**刻意的设计**：

- 为什么只建一次：建链要遍历 IoC 中全部 `Aspect` bean 并逐条做织入规则匹配（`Aspects.cj:36-56`），成本高，而匹配结果只取决于切点函数的签名（类型 + 函数），与实例无关 ⇒ 只算一次；
- 织入的粒度是「**类型**」而不是「实例」：同一类型的多个实例共享同一条链，不按实例建链（`f_aspect/README.md`：「织入逻辑会在这些函数首次调用时执行」）；
- 使用前提：被织入的对象必须是 **IoC 管理的 bean**（`singleton` 或 `prototype` 均可），手工 `new` 出来的实例不在支持范围内。

本条目不再进入修复队列（§0 建议修复顺序第 3 条已同步去列）。

**以下为审查时的原始判断与证据（已作废，留档对照）**：

位置：`src/Aspects.cj:25-46`（配合 `macros/PointCut.cj:109-118`）

```cangjie
// Aspects.cj:25   private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Array<Any>) -> Any>()
// Aspects.cj:35   var f: (Array<Any>) -> Any = {args => fn(args)}     // 捕获 doProceed 的形参 fn
// Aspects.cj:39-43 f = { args => funcInfo.setArgs(args); BeanFactory.instance.get<Aspect>(aspectName)... }
// PointCut.cj:111-113  func callee(args: Array<Any>){ $argVars; $(decl.block.nodes) }   // 在被织入函数体内 ⇒ 捕获 this
```

影响：链按 (TypeInfo, InstanceFunctionInfo) 只建一次，链尾永远是最早那次调用的 `callee`；`callee` 定义在原方法体内（宏展开见 `PointCut.cj:109-118`）⇒ 捕获首个接收者 `this` ⇒ **prototype / 手工 `new` 的实例上会在错误对象上执行方法体**；同时该实例被静态 map 永久引用（无法回收）。修法：链里只保存切面名列表，把 `fn`（与 args）作为参数逐次传入。（原始提案，已作废——见上方判定：按类型建链、固化首次 `callee` 即为设计目的。）

### 1.4 [严重｜正确性] `ASP-2` 缓存的 `InvocationFuncInfo` 每调用被改写参数，并发下互相覆盖（f_aspect）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/asp-2`（worktree `.worktrees/asp-2`，基线 `859e3759`），代码、用例、README、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-2 实参逐调用传递，切面链不再共享可变参数槽（§1.4）`）。**落地方式与原「修法」不同**：不需要改成 `proceed(funcInfo, args, fn)`，而是在层闭包内用本次调用的 `args` 新建 `InvocationFuncInfo`——`Aspect.proceed(funcInfo, point)` 签名与 `point(args)` 语义都不变。（原条目引用的 `Aspects.cj:41/47/64` 在 §1.3 补注释后为 `51/57/74`，均已改掉。）

- 改动：`f_aspect/src/Aspects.cj` doProceed —— 链只捕获不可变的 `qualifiedFuncInfo`；层闭包把 `funcInfo.setArgs(args)` 换成 `InvocationFuncInfo(qualifiedFuncInfo, args)` 后交给切面（实参逐调用、逐层传递）。链仍按 `(类型, 函数)` 只在首次调用构建、链尾仍固化首次 `callee`（§1.3 判定的设计不动）。`f_aspect/src/QualifiedFuncInfo.cj`：`_args` 改 `private let`、删 `setArgs`（全仓唯一调用点已移除）；`f_aspect/README.md` 的 `InvocationFuncInfo` 片段同步（`var`→`let`）。
- 用例（f_aspect 原先没有测试目录，本提交新建）：`aspect_args_race_test.cj`（并发串台回归：切面无状态、不加锁、不读 args，用 `AtomicBool` 制造确定性交错）、`aspect_chain_capture_test.cj`（每次调用各自的 info、实参与元数据正确；切面经 `point()` 改造实参的语义保留）。
- 测量证据：**修前** `T1 传入实参 1，业务方法实收 2；T2 传入实参 2，业务方法实收 2`，`Assert Failed: (r1 == 1)`，`FAILED: 1`（EXIT=1）；**修后** `T1 传入实参 1，业务方法实收 1；T2 传入实参 2，业务方法实收 2`，三条用例 `PASSED: 3, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。机制用例的实测行：`切面拿到的 info 与本次入参是同一实例（第1/2次）：false/false`、`两次拿到的 info 是同一实例：false`、`切面在两次调用里看到的实参：1/2`、`切面把实参 7 改成 100，业务方法实收 100`。
- 后续（2026-10-04，同一分支 `fix/asp-2`）：按用户要求把 `InvocationFuncInfo` 从 `class` 改为 `struct`（值类型、不可变、按值传递）——「跨调用共享参数槽」在语言层面不再可能；用例改为值语义断言（struct 下对象身份断言无意义）；三条用例仍 `PASSED: 3, FAILED: 0`；`f_aspect/README.md` 的 `InvocationFuncInfo` 片段与说明同步为 `struct`。
- 未覆盖：`f_orm`/`f_rpc` 未重跑构建——本次不改公开 API（两模块只是实现 `Aspect`、读 `funcInfo.args`），如需可单独 `cjpm build`。

位置：`src/Aspects.cj:41`（配合 `:47`）

```cangjie
// Aspects.cj:41    funcInfo.setArgs(args)      // funcInfo 是 ASP-1 缓存里的同一个对象
// Aspects.cj:47    match (f(funcInfo.args)) { case x: T => x ... }
// Aspects.cj:64    case Some(_) => fn(funcInfo.args)
```

影响：两个线程调用同一织入函数时，A 的参数可能被 B 覆盖；切面在 `around` 里读 `funcInfo.args` 会拿到别人的参数（`f_orm` 的 `TransactionAspect.proceed` 正是基于 `funcInfo` 判断）。修法：去掉可变共享槽，`proceed(funcInfo, args, fn)` 显式传参。

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

### 1.6 [严重｜正确性] `ASP-4` 前缀/后缀参数注解规则用 `params.size` 索引注解数组 ⇒ 越界崩溃（f_aspect）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `51030f8c`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-4 前缀/后缀参数注解规则按下标对齐，越界/恒 true → false（§1.6）`）。

- 改动：`f_aspect/src/AspectRoute.cj:290` 的公共实现 `matches(asc:...)` —— `range` 改为按 `annotations.size` 收敛、下标基准换成「规则项下标」（前缀 `offset = 0`、后缀 `offset = params.size - annotations.size`，规则项**正序**对应最后 N 个参数）；`params.size < annotations.size` 时返回 `false`；规则项补 `trimAscii()`；判定维持"参数**拥有**该注解即通过"（同文件 `contains :197-206` 的写法）。两个规则类本体不变，其文档示例（`:311-317`、`:324-330`）现在成立。
- **实测修正（与审查原文不同）**：原后缀分支 `params.size - 1..=0` **缺 `: -1`** ⇒ 按语言语义是**空循环**（最小实验：`for (i in 3..=0)` 迭代 0 次，`3..=0 : -1` 才是 `3 2 1 0`；仓库其它降序循环都写 `: -1`）⇒ 后缀规则的真实症状是**不校验任何参数、恒 `true`（过织入）**，不是越界；越界崩溃只发生在前缀分支（`0..params.size` + 规则项更少时）。两者同根：都用**参数下标**去索引规则项。
- 用例：`f_aspect/src/test/arg_prefix_suffix_route_test.cj` —— 规则项数 == / < / > 参数数 × 前缀/后缀、参数无注解（必须 `false`，防"空集合真空通过"）、参数多注解（"拥有"即可，`true`），共 2 个 `@TestCase`。
- 测量证据：**修前** `testPrefixRule` = `[ ERROR ] IndexOutOfBoundsException: Index out of bounds: index is '2', but array size is '2'`；`testSuffixRule` = `[ FAILED ] Assert Failed: (rule.matches(info('test3', 3)) == false)`（空循环误判 `true`）；合计 `PASSED: 3, ERROR: 1, FAILED: 1`（EXIT=1）。**修后** `PASSED: 5, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。
- 未覆盖：`ArgAnnotationsRouteRule` 的"恒 `false`"属 §1.7 `ASP-5`，本次未动。

位置：`src/AspectRoute.cj:290-309, 318-336`

```cangjie
// AspectRoute.cj:291  let annotations = annotationTypes.split(',')
// AspectRoute.cj:293-297  let range = if (asc) { 0..params.size } else { params.size - 1..=0 }
// AspectRoute.cj:298-299  for (i in range) { let current = annotations[i]      // ← 用 params 的长度索引 annotations
```

影响：规则项少于参数个数时抛 `IndexOutOfBoundsException`（无人捕获，直接从 `Aspects.doProceed` 冒泡到业务调用方 ⇒ 该函数**每次调用都失败**）。而 `AspectRoute.cj:311-317` 的文档示例恰好就是这个形状：`a.Annotation1,b.Annotation2` 匹配 `test2(@Annotation1 a, @Annotation2 b, c)`（3 参数 2 规则项）。修法：`range` 按 `annotations.size` 收敛（suffix 反向同理），并在长度不匹配时明确返回 `false`。

### 1.7 [严重｜正确性] `ASP-5` `ArgAnnotationsRouteRule` 恒返回 false（静默不织入）（f_aspect）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `7cd7863e`），代码、用例、README、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-5 ArgAnnotationsRouteRule 命中判定修正 + 长度必须逐参数一致（§1.7）`）。

- 改动：`f_aspect/src/AspectRoute.cj:255` —— ①内层命中改为置 `matched` 标志、循环后 `if (!matched) { return false }`（原来 `continue` 只结束内层循环，随后必然走到 `return false` ⇒ 恒 false）；②`params.size != annotationNames.size` 时返回 `false`（原来 `for (i in 0..params.size)` 配 `annotationNames[i]`，首项为 `*` 且规则项更少时越界崩溃）；③判定维持"参数**拥有**该注解即通过"（多注解也算命中、无注解不得命中）。**分隔符保持 `&`**（2026-10-05 决定），类注释与 `f_aspect/README.md` 的示例由 `,` 改成 `&`，并写明"个数必须与参数个数一致"。
- 用例：`f_aspect/src/test/arg_annotations_route_test.cj` —— 逐位命中、`*` 占位跳过、位置/顺序不符、参数无注解、参数多注解、规则项多于参数、规则项少于参数（首项 `*`，修前越界）。
- 测量证据：**修前** `testPositionalMatch` = `[ FAILED ] Assert Failed: (ArgAnnotationsRouteRule('${ARG1}&${ARG2}').matches(info('both', 2)) == true)`；`testRuleLengthMustEqualParamCount` = `[ ERROR ] IndexOutOfBoundsException: Index out of bounds: index is '1', but array size is '1'`；合计 `PASSED: 5, ERROR: 1, FAILED: 1`（EXIT=1）。**修后** `PASSED: 7, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。
- 兼容性：改前该规则只有"全部项为 `*`"才可能返回 `true`，没有可依赖的旧行为；分隔符维持 `&` 不变。

位置：`src/AspectRoute.cj:258-273`

```cangjie
// AspectRoute.cj:261-271
for (i in 0..params.size) {
    ...
    for (annotation in param.annotations where ...qualifiedName == annotationName) {
        continue        // ← 命中后只是 continue，循环正常结束后继续往下走
    }
    return false        // ← 因此任何非 '*' 项都会走到这里
}
```

影响：内层 `for ... where` 无论命中与否都正常结束，随后必然执行 `return false` ⇒ 只要规则里写了非 `*` 的注解，该规则**永不匹配**（静默失效、无任何提示）；全部写成 `*` 才会返回 `true`（`272`）。修法：命中置标志，循环结束后 `if (matched) { continue }` 再继续外层。

### 1.8 [严重｜正确性] `BEAN-1` 宏生成不存在的 `lookupSet`（f_bean）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `ba6fc979`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_bean): BEAN-1 @Constructor 集合形参改用 lookupHashSet/lookupHashMap，Map 键必须 String（§1.8）`）。

- 改动：`f_bean/src/macros/Constructor.cj` —— `lookupSet` → `lookupHashSet`（`:80`、`:92`）、`lookupMap` → `lookupHashMap`（`:83`、`:103`）；并按用户要求对 `HashMap`/`Map` 形参加**编译期检查**：键类型不是 `String` 时 `diagReport(ERROR, ...)` 报「the key type of the HashMap parameter X must be String」，附建议 `declare it as HashMap<String, T>`。
- **实测补充（报告只写了 `lookupSet`）**：`lookupMap` 同样缺失。名字集合对照：宏生成 `lookup`/`lookupList`/`lookupSet`/`lookupMap`/`lookupOption`；库只定义 `lookupHashSet`（`lookup.cj:52-58`）与 `lookupHashMap`（`:68-74`）（`lookupList`/`lookupOption`/`lookup` 有 ✓）。
- 用例：`f_bean/src/test/constructor_param_test.cj` —— `@Bean` + `@Constructor` 覆盖 `ArrayList`/`Array`/`HashSet`/`Set`/`HashMap<String,_>`/`Map<String,_>`/`Option` 七种形态，并在运行时断言各集合/可选形参都注入了注册的元素 bean（`list`/`arr`/`hashSet`/`set`/`hashMap`/`map` 各 `size == 1`、`opt.isSome()`）。
- 测量证据：**修前** `cjpm test` **编译失败**：`error: the error originates in the macro \`Bean\`` + `note: undeclared identifier 'lookupSet'`（`let hashSet = lookupSet < CtorParamItem >()`、`let set = lookupSet < CtorParamItem >()`）与 `note: undeclared identifier 'lookupMap'`（`hashMap`/`map` 两处），`EXIT=1`。**修后** `PASSED: 3, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0），含 `testCollectionParamsInjected`。**键检查探针**（临时文件，验证后已删）：`HashMap<Int64, CtorParamItem>` 形参报 `error: the key type of the HashMap parameter bad must be String`（附建议行），`EXIT=1`。
- 未覆盖：`Set`/`Map` 靠 `HashSet`/`HashMap` 隐式转换（已含在用例里）；`HashMap<K,V>`（K≠String）现在由编译期错误拦住，不再生成类型不符的代码。

位置：`src/macros/Constructor.cj:80, 92`；`src/lookup.cj`（只有 `lookupHashSet`、`lookupTreeSet`）

```cangjie
// Constructor.cj:80   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>($cond))
// Constructor.cj:92   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>())
```

已核实：全仓 `grep 'func lookupSet'` **无任何定义**，`lookupSet<` 仅出现在这两处宏输出里。影响：任何 `@Bean` + `@Constructor` 类只要有一个 `HashSet<T>`/`Set<T>` 形参，生成代码就引用未定义符号 ⇒ **编译失败**（不是运行时问题，所以只有用到该形参形态的类才暴露）。修法：改为 `lookupHashSet`（或补 `lookupSet` 别名）。建议同时给 `@Constructor` 加一条形参形态的编译期用例（`ArrayList/Array/HashSet/Option/HashMap` 各一）。

### 1.9 [严重｜正确性] `MVC-4` `download` 写出整个缓冲，而不是实际读到的长度（f_mvc）✓已复核

位置：`src/ResponseDownload.cj:44-47, 62-65`

```cangjie
// ResponseDownload.cj:44-47
let buf = Array<Byte>(1024, repeat: 0)
while(let bytes <- d[0].read(buf) && bytes > 0){
    fd.write(buf)          // ← bytes 只用于判断，写的是全部 1024 字节
}
```

影响：多文件/多流下载时，除最后一块外的每一块都会多输出「脏尾部」（`read` 只填充 `bytes` 字节，其余是 0 或上一轮残留）⇒ 下载内容长度与内容都错。同文件 `src/FileDownload.cj:57-59` 是正确的 `buf[0..len]` 写法，可直接对齐。修法：`fd.write(buf[0..bytes])`，并把缓冲分配移到循环外、改用 `MVCConfig.downloadBufferSize`。

### 1.10 [误判｜非缺陷] `MVC-1` 静态资源缓存「无上限、且不存在也建条目（负缓存）」（f_mvc）✓已复核 → ❌误判（2026-10-05：前者是设计目的，后者不成立）

**❌ 误判标记（2026-10-05）**：本条目整体判定为**误判、非缺陷**，不进入修复队列：

1. **「负缓存」不成立**：`std.collection` 的 `MapEntryView.value` 文档（`collection_package_interface.md:478-480`）写明「设置为 `None` 时，则会删除当前 Entry」；首次未命中时 `entryView` 给出的是该 key 的**空视图**，对它设 `None` 是空操作 ⇒ `RequestMeta.cj:122` 的 `view.value = None` 是**删除 / 保持无条目**，404 不会在表里留下任何东西，反而顺带做到了「文件消失后清掉旧条目」。原文「任何扫 404 的流量都会以每路径一条增长」作废。
2. **「无上限」是设计目的**：静态文件就是要「读入内存后一直驻留」，不做 TTL、不做淘汰；键是「去前导 '/' 的请求路径」、且不存在/目录不落条目 ⇒ 条目集合 ⊆ 现存静态文件，规模由部署决定。经用户 2026-10-05 确认：**保持 `sts/1.3.x` 的 `loadStaticResource` 原样**，不引入 LRU 或新的类型声明。
3. **一度按审查意见写过的 `StaticResourceCache`（有界 LRU + `mvc_staticResourceCacheSize` 配置位 + `RequestMeta` 接线）已在动手阶段全部回退**（本分支不包含这些改动，`MVCConfig.cj`/`RequestMeta.cj` 与 `sts/1.3.x` 一致）。
4. 另记一笔（**独立于本条目、未单列、待验证**）：审查时注意到请求路径未做 `..`/符号链接规范化，`STATIC_RESOURCE_ROOT.join` 后直接 `exists`/读取，理论上可指向静态根之外的可读文件——这属于「路径规范化」问题而非缓存问题，用户本次未要求跟进。

**以下为审查时的原始判断（已作废，留档对照）**：

位置：`src/RequestMeta.cj:24, 96-124`

```cangjie
// RequestMeta.cj:97    staticResourceBytes.entryView(path){view => ...
// RequestMeta.cj:113-119  view.value = if(let Some((last,_)) <- view.value && last < lastModified){ (lastModified, File.readFrom(p)) } ...
// RequestMeta.cj:122  }else{ view.value = None }     // 文件不存在：照样落一个条目
```

影响：键来自**请求路径**，无容量上限、无 TTL、无淘汰；命中后整文件 `Array<Byte>` 常驻。任何扫 404 的流量（爬虫、探测）都会以「每路径一条」的速度让这张表增长，并且 404 也会建条目。修法：改成有上限的 LRU/TTL 缓存，且只在「存在且为普通文件」时写条目（不存在不要落盘）。

### 1.11 [严重｜内存] `MVC-3` WS 的 ping `Timer` 只在收到 Close 帧时取消（f_mvc）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-3`（worktree `.worktrees/mvc-3`，基线 `sts/1.3.x` 的 `41c2df49`），代码与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-3 ping 定时器在 WS 读循环的 finally 里取消（§1.11）；并记录 §1.10 MVC-1 误判`）。

- 改动（两个提交，同属本条目）：①`WSMeta.exec` 的读帧循环改为调用新抽出的包内接缝 `pumpFrames`（见下），退出路径统一在 `finally` 里 `timer?.cancel()`，删掉原来只写在 `case CloseWebFrame` 的那一句；②**加固**（用户提出）：ping 回调里的 `ws.writePingFrame(h(...))` 包 `try/catch(_:Exception)`——stdx 契约明确「`closeConn` 关闭连接后调用写，抛出异常」，包一层可避免异常抛进定时器线程。
- **stdx 契约更正**：`WebSocket.read(): WebSocketFrame`（**非 Option**），连接结束时不是「返回 None」，而是**抛异常**（`ConnectionException`（对端已关闭连接）/ `SocketException` / `WebSocketException`，见 stdx.net.http 的 `WebSocket.read` 文档）。真实退出路径是：① 收到 Close 帧（`onFrame` 返回 true ⇒ 正常 `return`）；② 对端断开/连接被关（`read` 抛异常 ⇒ 穿出循环，经 `finally` 取消后继续向外传播）；③ 处理帧时抛出的异常（每帧的 `try/catch` 只吞「处理帧」的异常，`read` 的异常不吞）。原文「read 返回 None，落到循环之外」作废。
- **用例（B 方案：可测接缝）**：`f_mvc/src/WSMeta_test.cj`（新增，f_mvc 首个测试文件）。把「建定时器 + 读帧循环 + 退出取消」抽成 `WSMeta.cj` 的包内函数 `pumpFrames(readFrame, onFrame, ping, interval)`——形参不含 `HttpContext`/`WebSocket`（两者都是 stdx 的**类**，测试里造不出来：全仓 0 处构造、0 处实现，`CurrentHttpContext` 也只是读取点），于是用「假帧源 + 计数 ping 动作」即可测：`testPingStopsAfterConnectionDrops`（首读即抛异常 ⇒ 退出后 3 个周期内 ping 必须为 0）、`testPingRunsWhileAliveAndStopsAfterReturn`（read 阻塞 3 个周期 ⇒ 存活期间 ping ≥1 防空转；退出后先等 1 个周期让在途 tick 落地取基线，再等 3 个周期断言不再增长）。
- **RED/GREEN 实测**：把 `pumpFrames` 里 `finally` 的 `timer?.cancel()` 临时注释掉复跑 ⇒ **PASSED: 0 / FAILED: 2**，断言分别为 `Assert Failed: (0 == pings.value)`（实际 2 ⇒ 退出后定时器仍在 ping，泄漏复现 ✓）与 `(baseline == pings.value)`（3 → 6 持续增长）；恢复后复跑 ⇒ **PASSED: 2 / FAILED: 0**，`cjpm build` exit 0。
- **C（端到端）现状**：本仓库目前**没有任何 WS 端点或示例**（`frpcdemo` 里 0 处 `WebSocket`/`@WS`/`WSMeta`，`f_mvc/README.md` 也无 WS 章节）⇒ 端到端验证需要先新增一个最小 WS 服务（位置待用户指定），本条暂记**待办**。
- 顺带：本次同一分支曾按审查意见尝试 §1.10 `MVC-1` 的有界 LRU 缓存，经用户判定为误判后**已回退**（见 §1.10 误判标记第 3 点），本分支只保留 §1.11。

位置：`src/WSMeta.cj:158-168, 196-242`

```cangjie
// WSMeta.cj:163-165  Timer.repeat(duration, duration, {=> ws.writePingFrame(h(endpoint, ctx, pattern, ws, []))})
// WSMeta.cj:196      while(let frame <- ws.read()){
// WSMeta.cj:231      pingTimer?.cancel()        // 只有 case CloseWebFrame 这一条路
// WSMeta.cj:234-237  case _ => log.error(...); ws.closeConn()      // 不取消
// WSMeta.cj:242      }                          // read 返回 None 时直接返回，不取消
```

影响：客户端断网/直接断 socket（不发 Close 帧）时循环退出，定时器永久存活并持续向已关闭连接写帧；闭包捕获 `endpoint/ctx/pattern/ws` ⇒ 每断一条连接泄漏一个周期任务 + 一整条请求上下文。修法：把 `pingTimer?.cancel()` 放进该函数的 `finally`（或 `while` 外层的 `try/finally`）。

### 1.12 [严重｜性能] `MVC-2` `accessLog` 每请求无条件序列化全部参数与返回值（f_mvc）✓已复核

位置：`src/RequestMeta.cj:519-553`（调用点 `macros/Controller.cj:97` 的 `finally`）

```cangjie
// RequestMeta.cj:530   case x: ToData => return f_data.convert<JsonValue>(x.toData()).getOrThrow().toString()
// RequestMeta.cj:537-545  let argGen = StringGenerator().append('['); for (arg in args) { ... anyToString(arg) ... }
// RequestMeta.cj:546-549  let result = match (returned) { case Some(x) => anyToString(x) ... }   // 返回值再来一遍 JSON
// RequestMeta.cj:550   let log = LoggerFactory.getLogger<T>()
```

影响：`argGen`/`result` 在 `logContent` 闭包**之前**就算好了（闭包只推迟最后一次拼接）⇒ 即使日志关闭，每请求也要付出：全量参数序列化 + 返回值二次 JSON 序列化（`ToData` 分支）+ 一次 `LoggerFactory.getLogger<T>()`。修法：把两段构造移进 `logContent`，或先判 `log.isInfoEnabled`；logger 用类静态字段（`RequestMeta.cj:21` 已有 `log`）。

### 1.13 [严重｜性能] `ORM-2` 逐单元格做运行时类型分派 + 字符串 `typeName` 匹配（f_orm）

位置：`src/wrap/QueryResultWrap.cj:46-107`（配合 `base/QueryMappers.cj:76-82`）

```cangjie
// QueryResultWrap.cj:47    let columns = result.columnInfos
// QueryResultWrap.cj:53-75 for (i in list.size..=index) { ... match(column.typeName){ case 'SqlChar'|'SqlVarchar'|... } }
// QueryResultWrap.cj:107   match(list[index]){ case x: T => x ... }   // 未命中再进 convertFromString 的 match 链
```

影响：`QueryMappers.map()` 对**每一行每一列**调用取值路径 ⇒ 调用频率 = 行数 × 列数，是模块内最热的代码。每个单元格都要：一次 `columnInfos` 属性访问、一次大 `match`（`Any` 类型判定）、未命中时又一次 `match(None<T>)` 链。修法：构造 `QueryResultWrap` 时按列预算好「取值函数/类型标签表」，行循环里只做一次数组查表 + 一次 `as T`；把 `columnInfos` 在构造时取一次存字段（同时消掉 §3.1 中 `ORM-L3` 的 O(n²) 风险）。

### 1.14 [严重｜性能] `ASP-3` 每次调用都重建函数元信息（反射解析 + 2 个数组 + 参数装箱）（f_aspect）

位置：`src/macros/PointCut.cj:115`、`QualifiedFuncInfo.cj:70`、`PointCut.cj:87-94`

```cangjie
// PointCut.cj:115  let info = InvocationFuncInfo(TypeInfo.of(this), $funcName, $argTypes, $args)   // 在被织入函数体开头
// PointCut.cj:87   let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
// QualifiedFuncInfo.cj:70  this(typeInfo, typeInfo.getInstanceFunction(funcName, argTypes))
```

影响：每次调用 = `Array<Any>` + `Array<TypeInfo>` + `InvocationFuncInfo` + `QualifiedFuncInfo` 分配、每个值类型参数**装箱/解箱**（`as T` + `getOrThrow`）、一次 std.reflect 成员解析（`getInstanceFunction` 的实现不在仓库内，倍数**待验证**）。`@TransactionalService` 就是 `WeavedBean` 的别名（`f_orm/src/macros/TransactionalService.cj:19-20`），所以 ORM 的事务方法每次都付这份钱。修法：宏为每个函数生成静态元信息常量（或静态缓存 map），`args` 每调用单独传。

---

## 2. 中（24 条）

排序：语义/正确性 → 资源与状态 → 性能（按波及面从大到小）。

### 2.1 [中｜正确性] `ORM-C2` `SingleColumnIterator` 忽略 `column` 参数（f_orm）✅已修复（2026-10-04）

**✅ 修复记录（2026-10-04）**

- **改动**：`QueryResultIterator.cj:86` 的 `next()` 改为 `column` 非空时走 `result.getOrNull<T>(column)`，否则走 `index`（默认 0）；两者同时给出时以列名为准（与 `singleFirst<T>(column:)` 的取值口径一致）。
- **用例**：`QueryResultIterator_test.cj / testSingleIteratorByColumn` —— 同一行第 0 列 `id=7`、第 1 列 `name='bob'`，`singleIterator<String>('name')` 必须取到 `bob`；修复前该用例 FAILED ✓（随 §1.5 的修复前对照跑一并复现）。
- **文档**：README §13.4 的「已知问题」条目已删除并改写为正确语义（原条目指向的 §19.6 在 README 中并不存在，属死链）。

`src/base/QueryResultIterator.cj:34-46`（修复前）的 `next()` 只用 `index`，而 `SqlExecutor.cj:478-482` 的 `singleIterator<T>(column:)` 把 `column` 传了进来 ⇒ `singleIterator<String>('name')` 实际读第 0 列（静默读错列）。

### 2.2 [中｜正确性] `MVC-C3` 无 `Content-Type` 的请求直接 500（f_mvc）✓已复核

`src/ControllerFuncParam.cj:175`：`ctx.request.headers.getFirst("Content-Type").getOrThrow()` —— 空 body 的 POST/PUT、只带查询参数的调用会抛 `NoneValueException` ⇒ 500，而应 415/400。修法：缺失时按 `application/x-www-form-urlencoded` 或明确报错处理。

### 2.3 [中｜正确性] `MVC-C5` `FileDownload` 在 `spawn` 内执行后立即返回（f_mvc）

`src/FileDownload.cj:71-75` + `src/RequestMeta.cj:372-376`：`respond` 的 `finally` 立刻调 `OverallStopwatch.elapsed` ⇒ 下载耗时统计恒为 ~0；且 `spawn` 内异常无人接收（`Future` 被丢弃），`pipe.end()` 可能永不执行 ⇒ 客户端悬挂。修法：把耗时统计移进下载任务，或明确分离响应与传输阶段；`spawn` 的异常要有出口。

### 2.4 [中｜正确性] `ASP-9` 嵌套的织入方法调用整体跳过切面（f_aspect）

`src/Aspects.cj:63-65`：`recursiveInvocationFlag` 一旦为真就直接 `fn(funcInfo.args)`，A 的织入方法调 B 的织入方法时 B 的事务/日志切面完全不生效（静默语义缺失）。修法：按 `QualifiedFuncInfo` 记调用深度，只对同一函数判定递归。

### 2.5 [中｜内存｜待验证] `MVC-C2` `Resource` 在无 `Accept` 的路径上不关闭（f_mvc）

`src/RequestMeta.cj:303-309`：`Resource` 只在「非空结果 + 有 Accept + `genBody`」这条路上 `close()`；`accept` 缺失时直接落到 `313-318`，`InputStream`/`Resource` 结果不会被关闭 ⇒ 句柄泄漏。**待验证**：哪些返回类型同时实现 `ToData & Resource`。

### 2.6 [中｜内存+正确性] `MVC-8` 请求级 ThreadLocal 不清理（f_mvc）

`src/RequestMeta.cj:25-35, 552`：`currentResponseStatus` 只 set 不清 ⇒ `accessLog` 的 status 会沿用上一个请求（如前一个 401，本请求 200 也记 401）；`src/OverallStopwatch.cj:29-39`：`start` 在 404/405/OPTIONS 路径不调用 `elapsed` ⇒ 线程继续持有上个请求的 path 字符串。修法：请求 `finally` 统一清理。

### 2.7 [中｜内存] `MVC-6` WS continuation 帧累积无上限（f_mvc）

`src/WSMeta.cj:169-173`：`bytes.add(all: payload)`，只有 fin 才清空 ⇒ 客户端持续发 continuation 不发 fin 即可打爆单连接内存。修法：累积时校验总长上限（可配置），超限直接关连接。

### 2.8 [中｜安全] `ORM-C5` `argInSql` 把任意 `ToString` 值原样拼进 SQL（f_orm）

`src/base/LoopCondition.cj:99`、`src/base/MeetCondition.cj:80-81/100-101/124-127`、`src/base/ChooseCondition.cj:86/97`：传入 `String` 时绕过参数化（`executor.add`）⇒ 注入/语义错误面。修法：仅允许列名并做白名单校验，或加类型限制。

### 2.9 [中｜内存] `ASP-8` 切面链缓存只增不减、无失效接口（f_aspect）

`src/Aspects.cj:25`（全文无 `remove/clear`）：若某织入函数在切面 bean 注册完成前被调用过一次，**空链会被永久固化**（切面静默失效）；条目上界是织入函数数，但每条会持有首次调用传入的原函数体（`ASP-1` 的设计如此，非缺陷）。修法：暴露 `clear()/refresh()`，并在 bean 注册变更时清理。

### 2.10 [中｜性能] `ORM-3` 每条非事务 SQL 的 `close()` 都全量清扫脏字段注册表（f_orm）

`SqlExecutor.cj:153` → `DirtyTag.clearAll()`（`DirtyTag.cj:66-79`）遍历**所有已注册 PO 类型**并逐个新建 `DirtyTag` 写回 `ConcurrentHashMap`；`SqlExecutor.cj:836` 每次执行都走 `close()` ⇒ 成本 = O(已注册类型数) 次哈希查找 + 等量分配。修法：只清「本轮被标记过」的类型，或把 `clearAll` 移出每条 SQL 的执行路径。

### 2.11 [中｜性能] `ORM-4` 每次执行都重新 `prepareStatement`，借连接还额外 `select 1`（f_orm）

`SqlExecutor.cj:398`（`stmt.close()` 见 `878`，无语句复用）、`DatabasePool.cj:111-125` + `ORMConfig.cj:201-203`（`getCheckOnBorrowing` 默认 `true`）。修法：按 SQL 文本缓存 `Statement`；文档推荐 `orm_databasePoolCheckOnBorrowing=false`。

### 2.12 [中｜性能] `ORM-5` 每次拼条件片段都「动态构造正则 key + 查缓存 + 临时串」（f_orm）

`Condition.cj:65-67`、`TableClause.cj:39-49`、`imports.cj:35-37`：这些函数被 `WHERE/AND/OR/NOT/HAVING/ORDER_BY/GROUP_BY/SET` 每次调用 ⇒ 每构造一次动态 SQL 触发数次。修法：固定模式用 `static let` 的 `Regex` 常量；`trim` 用 `trimAscii` 手工裁剪。

### 2.13 [中｜性能] `ORM-6` 批量条件 DSL 循环体里逐元素大 `match` + `SqlArg` 分配（f_orm）

`LoopCondition.cj:85-113`、`MeetCondition.cj:41-111`、`ChooseCondition.cj:76-116`：`IN`/批量 insert 的参数规模就是业务集合大小（可上千）。修法：固定类型走参数化（`?`），把类型判定收敛。

### 2.14 [中｜性能] `ORM-7` `RootDAO.arg<I,T>(value)` 逐元素进入 40+ 分支 `match`（f_orm）

`RootDAO.cj:319-377`（`IN`/`NOT_IN` 于 `435-448`，`LogicalExpr.InExpr` 于 `175-181`）：上千 id 的 `IN` 就是上千次大 `match` + 两次对象分配。修法：把类型判定收敛为一次（或按静态类型分派）。

### 2.15 [中｜性能] `BEAN-2` 每请求 `getFirst<T>()` 重复 2 次 `TypeInfo.of<T>()` + 2 次 `isSubtypeOf` + 1 次 `as T`（f_bean）

`BeanFactory.cj:201, 203-206, 226, 228`；调用方 `f_mvc/src/RequestMeta.cj:191` 每请求一次。修法：`T` 的 `TypeInfo` 提到调用方缓存，并去掉「表 key 已保证类型」后的 `matches` 复检。

### 2.16 [中｜性能] `BEAN-3` `iterator<T>` 每次调用新建 filter 闭包并逐元素重跑判断（f_bean）

`BeanFactory.cj:328`（`getList/getMap/lookupHashSet/lookupTreeSet` 全走它）。`IgnoreCond` 恒真时应直接返回 `tree.iterator()`。

### 2.17 [中｜性能] `BEAN-4` 条件求值里每次现场构造通配/正则（f_bean）

`BeanStringCondition.cj:74-75`（`Regex.wildcard(v).matches(s)` / `v.regex().matches(s)`；前者是 6 次 `replace` + 缓存查表，见 `f_regex/src/ExtendRegex.cj:76-85`、`RegexFromString.cj:40-64`）。它又被 `BEAN-3` 逐元素调用 ⇒ 每元素 ~7 次字符串分配。修法：`StringCond` 内缓存编译好的 `Regex`。

### 2.18 [中｜性能｜待验证] `BEAN-5` 每次取 bean 都算 `scope.isSingleton`，其中 `==` 会求 `TypeInfo.of<SingletonBeanScope>()`（f_bean）

`BeanScope.cj:31, 38-42, 59-63` + `BeanManager.cj:90`。**待验证** `TypeInfo.of` 是否有运行时缓存（`f_base/src/TypeInfos.cj:32-36` 注释显示作者也想用静态 `INSTANCE`）。修法：`BeanManager` 构造时预存 `Bool` 字段。

### 2.19 [中｜性能] `MVC-5` 每个 `@PathVariable` 参数都做一次全路径解析 + 全量 `HashMap` 构造（f_mvc）

`ControllerFuncParam.cj:125` → `f_util/src/PathPattern.cj:173-195`：N 个 path 变量就重复 N 次切分（`f_util` 属跨模块，可加单变量轻量查找）。

### 2.20 [中｜性能] `MVC-7` 路由热路径每请求多次字符串分配（f_mvc）

`MultiRequestMethodHandler.cj:60` + `RequestMethod.cj:28-30, 55, 67-69`（`hashCode = toString().hashCode()`、`compare` 也走 `toString`）。修法：用 enum ordinal/常量名做哈希与比较。

### 2.21 [中｜性能] `MVC-9` 每请求一次反射式 bean 查找（f_mvc）

`RequestMeta.cj:191`（`BeanFactory.instance.getFirst<T>().getOrThrow()`）——与 `BEAN-2`/`BEAN-3` 是同一成本的两端，建议注册期解析一次并缓存实例。

### 2.22 [中｜性能] `ASP-6` 切点匹配在 `ConcurrentHashMap.computeIfAbsent` 的桶锁内执行（f_aspect）

`src/Aspects.cj:27-34`：锁内做「遍历全部切面 bean + 注解 + 正则匹配 + 建链」，同桶其它函数首次调用会被阻塞。修法：锁外算好链，再 `putIfAbsent` 写入。

### 2.23 [中｜性能] `ASP-7` 链里存切面**名字字符串**，每次调用重做查找（f_aspect）

`src/Aspects.cj:42`（`f_bean/src/BeanFactory.cj:208-234, 314-316`：`beans.get` + `isSubtypeOf` + 日志闭包）。修法：建链时解析成 `Aspect` 实例并缓存。

### 2.24 [中｜正确性] `X-2` `orm_databasePoolMaxWaiting` 的 Duration 配置解析与回退不符约定（跨模块：f_data/f_config）

> 2026-10-04 复跑 f_orm 全量用例时新发现；**追加在 §2 末尾以保持既有编号不变**，定级待复核。

位置：用例 `f_orm/src/wrap/ORMConfig_test.cj:27-44`（用例本身未改）；失败栈落在 `f_config/src/Config.cj:178/215` → `f_data/src/base/DataParsable.cj:30/58`（`Duration.tryParse`）。

证据（`cjpm test` 全量，f_orm）：

```
[ ERROR  ] CASE: testPoolMaxWaiting
Expect Failed: `(ORMConfig.getPoolMaxWaiting() == Duration.second * 45)`   left: 4s    right: 45s
Expect Failed: `(ORMConfig.getPoolMaxWaiting() == Duration.minute)`       left: 106751991167300d15h30m7s999ms999us999ns    right: 1m
An exception has occurred: fountain::f_data.exception.DataParsableException: abc cannot be parsed to Duration
Summary: TOTAL: 28   PASSED: 27, SKIPPED: 0, ERROR: 1, FAILED: 0
```

影响：`orm_databasePoolMaxWaiting`（连接池最大等待，按用例注释「≤0 表示真无限等待、非法值退回默认 30s」）读出来的值与配置文本不符 —— 输入 `45s` 得到 `4s`、`1m` 得到 `Duration.Max`；非法值 `abc` 直接抛 `DataParsableException` 而不回退 ⇒ 生产里配错一个字符可能让启动直接失败，或把等待时长设成错误值。

与 §1.1 的关系：调用链（`f_config`/`f_data`）与 `ORM-1` 的改动（`SqlArgs`/`SqlExecutor`）无交集；其余 27 例全过（含新增的 3 例）⇒ 属**既有缺陷**。

修法方向：先补 `f_data` 层 `Duration.tryParse` 的用例钉住约定（`45s`/`1m`/`0s`/`abc` 各自的期望），再决定是改解析规则还是改调用方（`Config.getData`）的回退分支。

---

## 3. 低危 / 待验证（44 条）

### 3.1 低危（36 条，按性质分组）

**健壮性 / 正确性**

- `ORM-C3` `SqlArgs.cj:26-28`：`clone()` 直接共享同一 `ArrayList`，不是快照（日志路径之后再 `add` 会污染已传出的「副本」）。
- `ORM-C4` `SqlExecutor.cj:77`（SQL 短于 6 字符越界）、`DatabasePool.cj:112`（`checkSql` 配短于 6 字符越界）：无长度保护的 `[0..6]` 切片；对比 `SqlPartial.cj:288` 有 `size >= 8` 保护。
- `BEAN-L9` `BeanFactory.cj:287-300`：`getFirstTuple<T>` 缺 `beanTypeIs<T>` 前置校验（`getFirst`/`iterator` 都有）⇒ 装配错误被静默吞成 `None`。
- `MVC-C6` `WSMeta.cj:176, 238-240`：文本/二进制帧到达但未配置对应 meta 时每条消息抛一次 `WSException`，并在 catch 里 `toBase64String(frame.payload)`（O(payload)）⇒ 异常驱动控制流 + 编码放大。

**内存 / 清理**

- `ORM-L7` `DirtyTag.cj:26, 72-79` + `SqlExecutor.cj:44-45`：`clearAll()` 只清**调用线程**的 `dirtyFields`；`currents/current` 只在 `close()` 时 `remove` ⇒ 线程池 + 多 PO 类型下 ThreadLocal 持有整组字段名集合。
- `BEAN-L2` `BeanManager.cj:40-44, 88-107` + `BeanFactory.cj:36-40`：容器与单例引用只增不减（`doDestroy()` 只调 `destroy()` 不清 `_bean`；三张表与 `registered` 无 reset/unregister）⇒ 已 destroy 的 bean 仍被强引用。修法：`doDestroy` 后 `_bean.store(None)`，补 `reset()/unregister()`。
- `BEAN-L3` `BeanFactory.cj:34` + `BeanInitializer.cj:19-21`：`ExitCallbacks.atExit` 与 `InitializerCollection.register` 只注册不注销（进程级单例，构建次数 1，不构成重复泄漏）。
- `ASP-L4` `Aspects.cj:52-66`：每次调用两次 ThreadLocal 访问（`get` + `set/remove`）并伴随 `?Bool` 装箱；`remove()` 实为 `set(None)`（`f_base/src/ExtendThreadLocal.cj:33-35`）。
- `MVC-L9` `HttpStatus.cj:806-878` / `Series.cj:38-42`：`values` 属性每次访问重建数组（模块内只用于 `static init`，影响为 0，但属公开 API 易误用）。

**性能微项**

- `ORM-L1` `SqlExecutor.cj:71-81`：`setSql` 每次做全串正则替换 + 两次 `trimAscii` + `[0..6]` 子串（见 `ORM-C4`），可换 `startsWithIgnoreAscii`。
- `ORM-L2` `SqlExecutor.cj:386-393, 859, 866`：每次执行都 `args.clone()`（实为共享，见 `ORM-C3`）并分配日志闭包，即使日志级别不输出。
- `ORM-L6` `SqlArg.cj:502-504`：`ByteArraySqlArg.hashCode` 用 `value.toString()` 格式化整个字节数组（BLOB 参数一次性等量大字符串峰值）；修法：长度 + 抽样字节。
- `ORM-L10` `TrsactionHooks.cj:53-58`：每次注册都对整个列表 `sort`，且只增不减、无注销 API（启动期调用，影响有限）。
- `ORM-L11` `ORMConfig.cj:94-113`：`getOption/getAllOptions` 每次复制一份全局配置 Map 并对每个 key 做 `replace`（启动路径）。
- `MVC-L1` `MultiRequestMethodHandler.cj:90-97`：OPTIONS 每次重建 Allow 字符串（`metas` 注册后不变，可预生成）；另有死变量 `let last = metas.size`。
- `MVC-L2` `FileDownload.cj:56` / `ResponseDownload.cj:44, 62`：每次下载重新分配缓冲并每次读配置（`MVCConfig.cj:257-261`）。
- `MVC-L3` `RequestMeta.cj:161-175, 298-302`：多值 `Accept` 每请求构造 `AcceptQueue`（内含 `PriorityQueue` + 比较闭包），浏览器默认多值 Accept 命中率极高。
- `MVC-L4` `RequestCondition.cj:154-170`：每次条件检查新建 `HashSet<String>(currentValues)`。
- `MVC-L5` `HttpRequestDistributorImpl.cj:57-63`：未命中路径每请求新建 `RequestMeta`（含闭包）⇒ 建议复用单例 404 handler。
- `MVC-L6` `global_func.cj:69-147`：数组参数解析用 `split`（无逗号也会切出 1 元素数组），可先判 `indexOf(',')` 或 `lazySplit`。
- `MVC-L7` `RequestMeta.cj:76-92`：比较器内构造两个 `TreeSet`（注册期 O(N log N) 次，可预算排序键）。
- `MVC-L8` `RequestMeta.cj:71`：404 日志用非惰性插值（`'...${path}'`），改 `log.warn{...}`。
- `MVC-L10` `RequestArgMeta.cj:21, 39`：同一次写入用 `[]` + `get` 双查表，可合并为一次 `get`。
- `BEAN-L1` `BeanFactory.cj:148-175` + `BeanDefCondition.cj:128-140`：启动期条件筛选近似 O(n²)（逐 bean 求条件、条件内再遍历该类型全部 manager；清理阶段对每个被丢弃 bean 全量遍历两张表，`161/165` 还无条件 `typeRemoved.add(t)`）。仅 `afterRegistered()` 一次。
- `BEAN-L4` `lookup.cj:104-109`（同 `80-86`）：按 label 查单个 bean 却先全量物化 `ArrayList` 再线性扫描；改用 `iterator<T>(cond)` 惰性遍历，首个命中即返回。
- `BEAN-L5` `lookup.cj:56-58, 64-66`：`lookupHashSet/lookupTreeSet` 双重物化（先 `ArrayList` 再目标集合，均从 0 容量扩容）。
- `BEAN-L6` `BeanFactory.cj:63-121`：类型表 `Any`/`Object` 键使每个 bean 都入表；std 过滤只作用于 `isClass` 分支，注解分支仍展开 `superInterfaces/superClass`（注册期内存与遍历量放大）。
- `BEAN-L7` `BeanFactory.cj:109-115`：注册循环体内定义局部函数并捕获 `isClass`（每类型节点一次闭包分配，注册期）。
- `ASP-L1` `AspectRoute.cj:85, 139, 162, 344`：每次匹配现构造正则（`Regex.wildcard` = 6 次 `replace` + 键串 + TTL 缓存查找；`Regex('^.+::')` 每次新建）；规则实例无状态，可缓存编译结果。
- `ASP-L2` `ConfigAspectRouteRule.cj:56, 72-242`（多处）：每次匹配重新 `Config.getString` + `split` + 构造新规则对象 + 传闭包；规则内可惰性解析一次并 memo。
- `ASP-L3` `AspectRoute.cj:189-213, 230, 245, 260, 282, 291`：匹配辅助函数每次分配临时 `HashSet`/`ArrayList` 并对每个注解做 `ClassTypeInfo.of`（集合选型本身是哈希，没问题）。
- `ASP-L5` `Aspect.cj:55-64`：每次回调包一层 try/catch/finally；`catch (e: Exception)` 包住全部步骤，默认 `throwing` 新建异常链，`finally` 里 `final()` 抛异常会覆盖原异常。
- `ASP-L6` `macros/PointCut.cj:52-56, 86-94`：宏展开期用 `+=` 在循环里累积 Tokens（编译期平方级拼接，大函数/多参数时明显）。
- `ASP-L7` `Aspects.cj:47-50`：结果统一走 `Any` 链，值类型返回值每次调用装箱（架构取舍，优先级最低）。

**死代码**

- `ORM-L4` `SchemaFinderMediator.cj:30-36`：构造了从未使用的 `existingTableNames`（`67-70` 又建了 `knownNames`）。
- `ORM-L5` `SqlDSL.cj:148-151`：`let fields = T.dataFields()` 求值后未使用。

### 3.2 待验证（8 条，均需实测/真实依赖才能定性）

- `ORM-L3` `QueryResultWrap.cj:26-32, 970-973`：`columnInfos` 在构造与 `toMap()` 中被重复访问（宽表 + `mapList` 放大）。**验证**：各驱动 `columnInfos` 是否已是缓存数组（否则是 O(n²) 分配）。
- `ORM-L8` `DatabasePool.cj:210-228`（配合 `f_pool/BasePool.cj:44-46`）：`PooledConnection.close()` 不校验 `assigned`，无条件 `returnFn(this)`。**验证**：池是否有身份去重（若无，重复 close 会让两个借用者拿到同一连接）。修法：`close()` 首行 `if(!assigned){ return }`。
- `ORM-L9` `SqlExecutor.cj:366-385`：`connection` getter 在 `Connecting` 状态用 `while ... continue` 忙等（无 sleep/yield/超时）。**验证**：驱动是否会出现长时间异步建连。
- `ORM-C6` `SqlArg.cj:426-448`（`InputStreamSqlArg` 把流交给驱动后模块内不关闭）、`QueryMapperConverter.cj:48-50`（`StringReader(x).readToEnd()` 未关闭）。**验证**：所有权约定（驱动/调用方是否负责关闭），否则是句柄泄漏路径。
- `MVC-L11` `RequestMeta.cj:303-318`：空结果的控制器函数在 `Accept` 不含 `*/*` 时被判为 406 而非 200 空体。**验证**：设计意图。
- `MVC-L12` `RequestMethod.cj:32-38`：`operator ==` 的分支里没有 `WS`，`(WS, WS)` 落到 `case _ => false`，而 `hashCode` 由 `toString` 生成。**验证**：若 `HashMap` 不做引用短路，WS 路由查不到（`RequestMethod.WS` 正是 WS 端点的注册键，见 `HttpRequestDistributorImpl.cj:36`）。
- `BEAN-L8` `BeanManager.cj:59-66` vs `:88-107`：`initIfNeed()` 无条件 `_bean.store(new())` 而 `bean` getter 用双检 ⇒ 若启动初始化与首次请求并发，非 lazy 单例可能被二次创建覆盖。**验证**：部署方是否保证请求晚于 initializer（正常启动流程下不触发）。
- `ASP-L8` `Aspects.cj:27`：链缓存命中依赖 `QualifiedFuncInfo.hashCode`（`QualifiedFuncInfo.cj:63, 72-80`，由 `typeInfo.hashCode()` + `funcInfo.hashCode()` 预处理）。**验证（关键假设）**：若 std.reflect 在不同调用间返回不同/非结构化哈希的 `InstanceFunctionInfo`，则缓存**永不命中** ⇒ 切点匹配、正则、建链每次调用重做，且 `aspects` 会**以每次调用一个 key 的速度无界增长**。建议加一条「同一函数多次调用命中同一链」的测试把该假设钉死。

---

## 4. 逐模块覆盖面（结构小结 + 已确认「无实例」的维度）

> 本节只作审查覆盖面证据，不含问题定级；问题清单见 §1–§3。

### 4.1 f_orm

**结构**：`base`（`SqlExecutor` 执行器 + SQL DSL + 分页/事务/DAO 基座）、`wrap`（驱动包装：连接/语句/事务/结果集/参数 + `DatabasePool` + `ORMConfig`）、`macros`（`@QueryMappersGenerator`/`@ORMField`/`@DAO` 代码生成）、`migro`（MySQL/PostgreSQL schema 对比迁移）。热路径：`SqlExecutor.execute` → 拼 SQL → 取连接 → `prepareStatement` → `QueryResultWrap` 逐单元格取值 → `QueryMappers` 逐行映射。

**无实例的维度**：无 CFFI `malloc/free` 不对称、无 `acquireArrayRawData/releaseArrayRawData`、无 `spawn`/显式锁（并发仅靠 `ConcurrentHashMap`/`ThreadLocal`/`AtomicUInt64`，故不涉及锁范围与 spawn 粒度）、无无界对象池（`DatabasePool` 受 `maxSize`/`connectionLife` 约束）、无 Future 历史堆积、无循环内逐项 IO/日志、无循环内 `clone()`/临时大集合、无 String↔Rune/Byte 反复转换热点。资源释放总体规范（`SqlExecutor` 在 `finally` 关闭语句与结果集、`migro` 用 `resource(...)`），例外见 `ORM-C1`/`ORM-C6`。

### 4.2 f_mvc

**结构**：请求链路 `HttpRequestDistributorImpl.distribute`（`57`）→ `PathPattern` 查表 → `MultiRequestMethodHandler.handle`（method/Content-Type 两级 `HashMap`）→ 宏生成闭包（`macros/Controller.cj:78-101`）→ `RequestMeta.checkAuth/extract/respond`。**路由表在注册期构建、请求期只查表**（`f_util/src/PathPattern.cj:153` + `MultiRequestMethodHandler.cj:37-54`），这部分设计是对的。

**无实例的维度**：路由匹配表**不是**每请求重建；热点循环里无 `Array/ArrayList.contains` 存在性判断（`consumes/produces` 用 `HashSet`、`checkHeader` 用 `HashSet.contains`、`HttpStatus/Series` 用 `HashMap`）；无循环字符串 `+`/插值（统一 `StringGenerator`）；无 String↔Rune/Byte 循环转换；锁只在注册期（`RequestMetas.add`、`register`、`AuthHandlerProxy` 首次初始化）；无「spawn 后立即 get」；无循环内同步 IO；无健康检查历史/中间件链增长；无 `catch NoneValueException` 式控制流（`tryParse` 系列均正确使用）；除 WS ping Timer 外无「注册无注销」；已知上界未预分配的分配点都在注册期。

### 4.3 f_bean

**结构**：「启动期注册 + 运行期查找」容器：`BeanFactory`（单例；`HashMap<String,BeanManager>` 名称表 + `HashMap<TypeInfo,TreeSet<BeanManager>>` 类型/注解表）在注册期把每个 bean 的本类、`Any`、`Object`、全部 `superInterfaces/superClass`/注解递归展开入表，`afterRegistered()` 冻结注册并跑一次条件筛选。`BeanManager` 管生命周期（单例走 `AtomicOptionReference` 双检锁缓存，prototype 每次 `new()`）。元数据**没有**每请求重建。

**无实例的维度**：模块内**没有**属性拷贝/深拷贝代码（`as T`/`<-` 仅 4 处，都在查找返回路径）；无每请求重建类型元信息（注册期构建 + `registered` 冻结）；无 `ThreadLocal`；无自建缓存（唯一正则缓存来自 `f_regex`，已有界 `maxLife/maxSize`）；无异常当控制流（无 `catch NoneValueException`、无捕越界/转换失败；`getOrThrow` 只在「bean 不存在」错误路径）；无线性 `contains`（容器查找走 `HashMap.get`/`TreeSet.contains`，仅 label 类语义查找是 O(n)，见 `BEAN-L4`）；无循环内字符串拼接热点。

### 4.4 f_aspect

**结构**：织入是**编译期宏**（`macros/PointCut.cj` 把每个公共实例函数体包进嵌套函数 `callee`，再调 `Aspects.proceed(info, callee)`），没有动态代理、没有运行时代码生成。运行期只有两个入口：`Aspects.proceed`（递归标志 → `doProceed` → `computeIfAbsent` 取/建拦截器链）与 `Aspect.proceed` 默认模板。**切点匹配已按函数缓存**（`Aspects.cj:27`），匹配不在每次调用的热路径上 —— 这点是对的。

**无实例的维度**：无每次调用新建代理对象/动态生成代理类（编译期宏改写 AST）；无每次调用重建拦截器列表（`computeIfAbsent` 已缓存）；无热点循环内创建 Lambda（建链循环每函数只走一次）；无线性 `contains`（注解名匹配用 `HashSet`）；无「已知规模不预分配」（`AspectRoute.cj:189-190` 反而有预分配）；生成代码里无循环拼接字符串，但**每调用生成 2 个临时集合**（见 `ASP-3`）；无 `catch` 吞异常式控制流（但存在真实越界，见 `ASP-4`）；ThreadLocal 有 `finally { remove() }`（只是 `remove` 非真清除，见 `ASP-L4`）。

---

## 5. 基线与验证状态

- 基线脚本：`cjpm build` + `cjpm test --no-capture-output`，模块顺序 `f_bean → f_aspect → f_mvc → f_orm`（日志 `/tmp/review_baseline.log`、`/tmp/bl_<模块>_{build,test}.log`）。
- 已完成：`f_bean` 的 `cjpm build` **exit 0**（0 条 error）。`f_bean` 的 `cjpm test` 长时间停留在**测试编译阶段**（编译 f_util 等测试依赖，非卡死），`f_aspect/f_mvc/f_orm` 尚未开始 ⇒ 本次审查未拿到 `cjpm test` 结果；本报告结论均来自代码阅读，不依赖该基线。
- 修复期验证（2026-10-04，本分支上的修复提交）：`f_orm` 的 `cjpm build` **exit 0**；`cjpm test` **TOTAL 33 / PASSED 32 / ERROR 1 / FAILED 0**。唯一 ERROR 是既有环境相关用例 `f_orm.wrap / ORMConfigTest.testPoolMaxWaiting`（用例先 `Config.set(key, '45s')` 再断言读出 45s，本机 `left: 4s` ⇒ 环境里该配置项已存在并压过内存设置；该用例不执行 SQL，与修复路径无交集）。本次修复新增的 5 条用例 **5/5 PASSED**（同一套用例在修复前对照跑为 **5/5 FAILED**），逐条记录见 §1.5 / §2.1。
- 本报告未做**运行时实测**（无 benchmark、无 heap profile）。凡标「**待验证**」的条目都给出了验证方法（见 §3.2），另补几条高危项的复现方式：
  - `ORM-1`：同一 executor 上「同 SQL、不同参数」两次查询，断言结果不同（✅ 已由 `SqlResultCache_test.cj` 落地，见 §1.1）；
  - `ORM-C1`：真实驱动（postgres/mysql）下取回 `iterator` 后逐行读，观察 `close()` 后行为（✅ 所有权/关闭语义已由 `QueryResultIterator_test.cj` 在 mock 上钉死，见 §1.5；真实驱动的 `next()` 仍未实测）；
  - `BEAN-1`：写一个含 `HashSet<T>` 形参的 `@Bean`+`@Constructor` 类，编译即见未定义符号；
  - `ASP-4`/`ASP-5`：按 `AspectRoute.cj:311-317` 的文档示例写规则，观察崩溃/不织入；
  - `X-1`：`TypeInfos.get("a.b.C")` 单测。

## 6. 审查方法与备注

- 方法：4 个模块并行全文通读（含 `macros` 子包），按「性能（复杂度/集合/分配/字符串/闭包/同步/IO/CFFI/数据表示/背压）+ 内存（堆与 RSS/临时对象/集合容量/缓存/大对象/对象图/闭包/线程/Resource/CFFI）」两套清单取证；每条结论要求 `文件:行号` + 证据片段 + 调用频率判断 + 修法，再对全部「严重」级条目回到源码逐行复核。
- 编排：按严重程度降序，模块归属用编号前缀表示；同一处问题若同时涉及性能与正确性，只在最高危那一处详述，其它位置用编号交叉引用（如 `MVC-4` 即原 `MVC-C1`），不重复计数。
- 本次审查**只读**，未改动这 4 个模块的任何代码；报告落在本分支 `.autocode/bugs/bug.md`。
