# f_orm 模块审查报告（第 4/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（全模块 111 个源文件；**本部分覆盖 15 个**：`SqlPartial.cj`、`TableClause.cj`、`TableMeta.cj`、`TableMetas.cj`、`TableSchema.cj`、`TransactionAspect.cj`、`TransactionHook.cj`、`TransactionStatus.cj`、`Transactional.cj` 与 6 个 `*_test.cj` 夹具，共约 1450 行）
- **基线**：工作区快照（`git log -1` = `8c0ce643a` 2026-11-28 合并提交；`git status` 仅多出本轮 `reviews/`、`docs/review/`；快照模式无 diff，本部分发现**全部记为「存量」**，逐条给了 `git blame` 依据）
- **审查重点**：SQL 执行 / 部分更新 / 结果缓存流 / 事务状态与钩子、并发安全、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（`f_orm` 模块 8 个子轮中的第 4 部分，待主 Agent 合并为 `docs/review/f_orm_review_20261128.md`）
- **说明**：本文件统计**只含第 4/8 部分**，合并时不要与其余七部分的数字直接相加覆盖。

## 发现

### [严重][存量] 按 Map 更新时「列是否命中」与「是否补逗号」解耦：缺任意一个非主键列就生成 `SET a=?, , WHERE` 的非法 SQL

- **位置**：`f_orm/src/base/SqlPartial.cj:160-167`（`UPDATE<T>(values: Map<String, Any>)`）、`:203-210`（`UPDATE<T, ID>(values: Map<String, Any>, id)`)
- **来源**：存量（`git blame -L 150,180` → `ae7aa2263c` 2026-09-13；两处同源代码同批引入）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）、§2（近似重复导致同源缺陷两处）
- **证据**：静态确定 —— `if(sql.size > sqlsize){ sql.append(', ') }` 写在 `values.get(field)` / `values.get(column)` **之前**，且不在任何 `if` 分支内。第一次追加列后 `sql.size > sqlsize` 恒成立，之后每个**未命中**的 mapper 仍会补一个 `', '` 却不追加列。
- **描述**：接口注释（`SqlPartial.cj:34`）只要求「values 必须包含主键键值对」，即支持部分列更新。以 `OrmUpdateProbe(id/name/age/nick_name)` + `{'name': 'n', 'id': 7}` 为例，循环产出：

  `UPDATE t SET name=?, , WHERE id=?`（gap 场景）或 `UPDATE t SET name=?, age=?, WHERE id=?`（尾列缺失场景）。

  两条路径（含 `UPDATE<T, ID>` 的显式 id 重载）都受影响，后果是驱动侧语法错误 / 参数占位与列不匹配，部分列更新这条主路径**不可用**；`SqlPartialColumnKey_test` 的三个用例全部给满 `name/age/id`，且只断言「数组重载与 Map 重载输出相等」，两个重载错得一样，测试因此全绿（见轻微项「测试断言不足」）。
- **建议**：把分隔符判定挪到「确实追加了列」之后（用 `wroteColumn` 布尔或先收集 `Array<(String, Any)>` 再一次性 join）；`INSERT_INTO`/`UpdateClause.SET` 已经是「先收集后拼接」，可直接复用同一形态。补一条只含部分列（含尾列缺失）的用例，并断言 SQL 里 `SET` 与 `WHERE` 之间无连续逗号。

### [一般][存量] `ORDER_BY` / `GROUP_BY` 的 `Array<Column>` 重载用空格连接多列，两列起即生成非法 SQL

- **位置**：`f_orm/src/base/TableClause.cj:162-171`（`ORDER_BY(order: Array<Column>)` 的 `columns.append(' ')`）、`:257-266`（`GROUP_BY(group: Array<Column>)` 同样写法）
- **来源**：存量（`git blame -L 162,171` → `5f431b4c8f` 2026-09-16）
- **判据**：review-checklist §11（逻辑错误）、§2（同一「数组+分隔符拼接」的 4 份实现里 2 份分隔符写错）
- **证据**：静态确定 —— `Column.toString()`（`Columns.cj:120-143`）返回带前后空格的 `' col '`，这里再以 `' '` 连接，得到 `order by  a  b `；同文件 `columns2string`（`:311-320`）与 `SET(Array<LogicalExpr>)`（`:384-395`）用的都是 `', '`，`ORDER_BY(() -> String)`/`GROUP_BY(() -> String)` 也依赖调用方自带逗号。
- **描述**：`ORDER_BY([a, b])` / `GROUP_BY([a, b])` 产出 `order by a b`，PG/MySQL 均按语法错误拒绝（`b` 不是合法排序方向）；单列时看不出来，仓内唯一调用 `fdbm/test/e2e/orm_client/src/main.cj:177` 恰好是单列，问题未暴露。排序方向本身由 `Column.ASC()/DESC()` 携带（`Column.toString` 的 `sort` 分支），因此多列**必须**用逗号，不存在「用空格表达方向」的语义。
- **建议**：两处统一改成 `', '`（与 `columns2string` 一致），并补一条两列排序的用例；顺手把四份「数组+分隔符拼接」抽成一个 `joinExpressions(Array<SqlExpr>, sep)`。

### [一般][存量] 分页入口不校验 `size > 0`：`size = 0` 时在 `Pagination` 构造里除零崩溃

- **位置**：`f_orm/src/base/SqlPartial.cj:296`（`Pagination<R>(page: page, rows: count, size: size)`）、入口 `:304`（`page`）、`:307`（`singlePage`）；触发点 `f_orm/src/base/Pagination.cj:36`（`rows / size`）
- **来源**：存量（`git blame -L 286,309` → `ae7aa2263c`）
- **判据**：review-checklist §11（边界差一 / 除零）、§10（边界校验）
- **证据**：静态确定 —— `Pagination` 的 `init(page!size!rows!list!)` 无条件执行 `rows / size + ...`，`selectPage` 把调用方的 `size` 原样透传，全链路无 `size > 0` 检查；`page <= 0` 时 `(page-1)*size` 为负偏移，`limit(size, offset)` 同样产不出合法 SQL。
- **描述**：`page(size = 0)` 的后果是 `ArithmeticException`（除零），而不是可读的参数错误；`page = 0` 生成 `limit ? offset ?` 绑定负偏移，由驱动/DB 报错。这类入参多来自前端的 `pageSize`，属于典型的不可信边界。
- **建议**：在 `selectPage` 入口校验 `size > 0 && page >= 1`，不满足抛 `SqlArgException`（模块内已有的参数异常类型）；`Pagination` 构造器自身可再加一道 `require(size > 0)` 兜底。

### [一般][存量] `deleteById` 用查询通道执行 DELETE 且无 `RETURNING`，`?T` 返回值恒为空或直接抛错

- **位置**：`f_orm/src/base/TableClause.cj:292-300`（三个 `deleteById` 重载，均 `executor.setSql('delete ...').first<T>()`）
- **来源**：存量（`git blame -L 292,300` → `5f431b4c8f`）
- **判据**：review-checklist §11（契约与实现不符）、§10（返回值语义）
- **证据**：静态确定（返回值不可达）+ 待确认（各驱动对「在 DML 上 query」的容忍度）—— SQL 里没有 `RETURNING`，`first<T>` 走 `execute<Option<T>>` → `stmt.query()`（`SqlExecutor.cj:963-1014`），删除语句不可能产出被删行的列；MySQL Connector/J、PG JDBC 对 `executeQuery` 执行 DELETE 直接抛 `SQLException`。
- **描述**：API 名与签名承诺「按 id 删除并返回被删实体」，实现要么抛驱动异常，要么永远 `None`；调用方若按 `Some/None` 判断「是否删到」，会得到恒 `None` 的错误结论。仓内暂无调用（`deleteById` 只在定义处出现），属对外 API 的潜伏缺陷。
- **建议**：返回类型改 `Int64`（`rowCount`，走 `.delete`）；确需回传实体时显式拼 `delete ... returning *`（仅 PG/OpenGauss，需方言分支），并在 README/注释写清方言限制。

### [一般][存量] `@Transactional` 存在时 `rollbackFor` / `noRollbackFor` 恒为 `Some("")`，全局配置被静默忽略

- **位置**：`f_orm/src/base/TransactionAspect.cj:51-52`（`noRollbackFor = x.noRollbackFor`、`rollbackFor = x.rollbackFor`）与 `:66-71`（`if(...isNone()){ 读配置 }`）；来源字段默认值 `f_orm/src/base/Transactional.cj:28-29`（`String = ''`）
- **来源**：存量（`git blame -L 51,52` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（读配置却永不生效 / 死分支）、§14（接线缺失）
- **证据**：静态确定 —— 注解字段是 `String` 而非 `?String`，赋值到 `?String` 变量后得到 `Some("")`，`.isNone()` 恒假；后续 `SqlExecutor.execute` 用 `noRollbackFor.size > 0` 判定（`SqlExecutor.cj:1068`），空串等于「未配置」。同一函数里 `propagation/isoLevel/accessMode/deferrableMode` 用的都是 `?T`，能正常回退到配置（`:54-65`），只有这两个字段失效。
- **描述**：只要方法标了 `@Transactional`（不写 `rollbackFor`），`orm_transactionRollbackFor` / `orm_transactionNoRollbackFor` 配置就完全不生效；不标注解的方法反而生效。行为随「有没有注解」反转，排查成本高，且回滚范围错误意味着部分提交/该回滚的没回滚。
- **建议**：把 `Transactional.rollbackFor/noRollbackFor` 改成 `?String = None`；或保留 `String` 但在装配时用 `if (x.rollbackFor.size > 0) { Some(x.rollbackFor) } else { None }`。补一条「注解无属性 + 全局配置」的用例。

### [一般][存量] `TableMetas.clear()` 用 `unsafeZeroValue` 替换静态表：留下空引用，下一次注册/遍历即崩，且是非原子发布

- **位置**：`f_orm/src/base/TableMetas.cj:36-38`（`schemas = unsafeZeroValue<ConcurrentHashMap<TypeInfo, TableMeta>>()`）；声明 `:24`
- **来源**：存量（`git blame -L 36,38` → `4be871f2fd`）
- **判据**：review-checklist §12.1（发布逸出 / 可见性）、§11（错误处理）、§3（清空语义与命名不符）
- **证据**：静态确定（语义）+ 待确认（当前仓内无调用者，未触发）—— `unsafeZeroValue<T>` 对引用类型产出零值对象而非「空容器」，本仓已有同源结论：`f_rpc/src/server/LogMessage.cj:20` 注释明确「unsafeZeroValue 是零值对象，反射式遍历会直接段错误」。`clear()` 之后再 `schemas[...] = ...`（`register`，`:28`）或 `schemas.iterator()`（`tableMetas`，`:34`）就作用在零值对象上。全仓搜索 `TableMetas.clear` 无调用者，所以是潜伏缺陷。
- **描述**：名为 `clear` 却不具备「清空后仍可用」的语义；一旦有人（测试或 schema 重扫）调用，表注册表进入不可用状态，后续 `register<T>` 或 `migro` 的 `tableMetas()` 会崩溃。另外这是普通 `var` 非原子替换，若在运行时被多线程调用，读写线程可能看到半初始化引用（`register/tableMetas` 是多线程可调的：`TableMetas` 是模块级静态状态，`f_orm/src/migro/SchemaFinderMediator.cj:29` 在启动期读取）。
- **建议**：改为 `schemas.clear()`（若 `ConcurrentHashMap` 无该方法，则 `schemas = ConcurrentHashMap<...>()` 重新赋新实例即可，仍是原子引用替换）；`clear` 上加注释说明「仅供测试/重扫使用，调用后注册表为空但可用」。

### [一般][存量] dirty 更新失败时 `finally` 仍清空脏字段集合：失败后重试变成静默 no-op

- **位置**：`f_orm/src/base/SqlPartial.cj:230-234`（`try { return UPDATE<T>(..., includingColumns: dirtyFields, ...) } finally { dirtyFields.clear() }`）
- **来源**：存量（`git blame -L 226,235` → `ae7aa2263c`）
- **判据**：review-checklist §11（错误处理 / 数据丢失）、§3（失败路径当成功）
- **证据**：静态确定 —— `DirtyTag.getDirtyFields<T>()`（`DirtyTag.cj:59-65`）返回的是线程本地活集合，`finally` 无视更新是否成功一律 `clear()`；`update` 抛异常（约束冲突、连接断开、SQL 非法）时异常向上抛，但脏标记已消失。
- **描述**：业务代码常见形态是 `try { UPDATE(entity, dirty: true) } catch { 重试 }`；重试时 `dirtyFields.isEmpty()` 直接 `return 0`（`:227-229`），调用方看到「更新 0 行」而实体改动永久丢失，且没有任何日志。
- **建议**：只在成功路径清空（`let r = UPDATE(...); dirtyFields.clear(); r`，异常时不进入清理），或 `catch` 时保留集合并记录 warn；清空也可改用 `DirtyTag.clear<T>()`，与脏标记的统一入口保持一致。

### [一般][存量] `TableMeta.new` 两处 `catch(_) {}` 吞掉反射异常：注解存在但读取失败时列元数据静默缺失

- **位置**：`f_orm/src/base/TableMeta.cj:44-55`（`getInstanceProperty` / `getInstanceVariable` 两次 `try` + `catch(_){}`）
- **来源**：存量（`git blame -L 43,60` → 2026-09 提交，同批 schema 元数据实现）
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）、§11（错误处理缺失）
- **证据**：静态确定（吞异常事实）+ 待确认（反射调用是否会出现除「成员类型不匹配」之外的失败）—— 两个 `try` 都只为了区分「成员是 property 还是 variable」，但 `catch(_)` 同时吞掉了 `getInstanceProperty` 内部的其它异常；两次都失败时该列被 `.filter{opt => opt.isSome()}` 丢掉，`TableMeta.columns` 比实体字段少。
- **描述**：后果是 `migro` 比对 schema 时把「没读到的列」当成「不该存在的列」，可能生成 `drop column` / 不生成 `add column`（`f_orm/src/migro/PostgresSchema.cj` 以 `TableMeta.columns` 为基准）。错误只在注册期发生一次，日志里也没有痕迹。
- **建议**：只捕获「成员不存在 / 类型不是成员」这一种预期异常（按具体异常类型收窄），其余 `catch (e) { log.warn(...) }` 并让该列以 `None` 显式上报；若两次都取不到，至少 warn 出 `fieldName`，不要静默过滤。

### [一般] 分页结果按 offset 生成互不相同的缓存键，事务内连续翻页把每页结果都留在结果缓存里

- **位置**：`f_orm/src/base/SqlPartial.cj:296-299`（每页 SQL 为 `'select * from (${partial}) as __tmp___ limit ? offset ?'`，args 含 `offset`）；缓存侧 `f_orm/src/base/SqlExecutor.cj:905-917`（SELECT 结果写 `cache`）、`:153-174`（`close()` 带 `tx.isNone()` 守卫才清缓存）
- **来源**：存量（`git blame` 同 `ae7aa2263c`）
- **判据**：review-checklist §5（缓存键无界 / 无容量与淘汰）、§7（有界化）
- **证据**：静态确定（机制）+ 需实测（峰值）—— `cache` 是 `HashMap<SqlCacheKey, Any>`，无容量/淘汰/TTL；`SqlCacheKey` 由 SQL 文本 + 参数内容决定（`SqlExecutor.cj:25-39`），翻页时 `offset` 变化即产生新键。非事务路径每次 DAO 调用 `close()` 会 `cache.clear()`；但在 `execute { e => ... }` 事务作用域内 `close()` 被 `tx.isNone()` 挡住，缓存与连接同寿命。
- **描述**：在长事务里做分页遍历（报表导出、批量对账），每页结果（`size` 行 × 每行 Map/实体）都会常驻，直到事务结束。规模估算：100 万行、`size = 100` ⇒ 1 万个缓存条目、约 100 万行对象；按每行 Map 数百字节计是数百 MB 级，属于「事务越久越涨」的可控但无上界的增长。
- **建议**：给结果缓存加容量上限或按 SQL 前缀排除分页查询（`limit/offset` 的 SQL 不进缓存）；或对 `Pagination` 的取数调用显式 `clearCache`（模块内已有 `clearCache` 标志）。收益量级需按上述场景实测后再定容量。

### [轻微][存量] 零散死代码 5 处：不可达 `else if`、未使用局部、恒 true 的参数、注释掉的接口默认实现、重复 import

- **位置与证据**（均静态确定）：
  1. `f_orm/src/base/SqlPartial.cj:256-263` —— `:256-258` 已在 `sql.size == sqlsize` 时 `return 0`，`:261-262` 的 `else if (sql.size == sqlsize) throw SqlArgException(...)` 恒假（同层不可达分支，§1）。
  2. `f_orm/src/base/SqlPartial.cj:192` —— `let dialect = this.dialect` 之后全函数未使用（`:194-218` 只调 `involve`/`arg`），未使用局部（§1「读了不用」）。
  3. `f_orm/src/base/TableClause.cj:355-360` —— `private func count(clearArgsAfterExec: Bool)` 唯一调用点 `:356` 传字面量 `true`，`false` 分支无调用者（§1「死配置」，参数可删）。
  4. `f_orm/src/base/SqlPartial.cj:21-28` —— 接口里两段被注释掉的默认实现（`INTO<T>(values)`、`INSERT_INTO<T>(values)`），属兼容残留（§1）。
  5. `f_orm/src/base/TransactionAspect.cj:19` 与 `:24` —— `import fountain::f_aspect.*` 与 `public import fountain::f_aspect.*` 重复（后者已包含前者，§1 未使用 import）。
- **来源**：存量（`git blame` 分别落在 `ae7aa2263c` / `5f431b4c8f` / `4be871f2fd`）
- **判据**：review-checklist §1
- **描述**：单条影响都很小，但第 1 条是「重复判定」留下的残留，容易被误读为「此处还有第三种错误路径」。
- **建议**：逐条删除；第 3 条若确无「保留参数以备将来」的需求，直接改成 `count(): Int64` 并把 `clearArgsAfterExec: true` 内联。

### [轻微][存量] `SqlPartial` 里「`Column`/`(Column, Any)` → 名称/Map」的转换复制 8 份，形态各异（下标 / iterator / Map 构造）

- **位置**：`f_orm/src/base/SqlPartial.cj:60-65`（`HashSet<Column>` → `Array<String>`，用 iterator）、`:69-74`（`Array<Column>` → `Array<String>`，用下标，两份重载）、`:123-129` / `:130-136` / `:137-143` / `:181-187`（`Array<(Column, Any)>` / `Map<Column, Any>` → `HashMap<String, Any>`，4 份逐行相同）
- **来源**：存量（`git blame` → `ae7aa2263c`）
- **判据**：review-checklist §2（只改类型名 / 换算复制）
- **证据**：静态确定 —— 4 份 `for((k, v) in values){ values2[k.name] = v }` 完全同构；2 份 `Array<Column>` 重载的 `Array<String>(...){i => ...name}` 与 `HashSet<Column>` 版本只差遍历方式。
- **描述**：目前行为一致，但「名称解析」这一语义散在 8 处，任何一处调整（例如改成 `involve` 后的列名、或支持 `tableAlias`）都会漏改。本部分 `[严重]` 的逗号缺陷正是同一函数族里两份近似实现同时写错。
- **建议**：抽 `private func toNameArray(columns: Array<Column>): Array<String>` 与 `private func toValueMap(values: Iterable<(Column, Any)>): HashMap<String, Any>`，各重载只做一次转发；转换语义只保留一份。

### [轻微][存量] `findById` / `deleteById` / `byId` 三组各 3 份「仅类型不同」的实现；另有 4 份「数组+分隔符拼接」

- **位置**：`f_orm/src/base/TableClause.cj:282-290`、`:292-300`、`:413-421`（`Int64` / `UInt64` / `String` 三个重载，函数体逐行相同）；`:162-171`、`:257-266`、`:311-320`、`:384-395`（`ORDER_BY`/`GROUP_BY`/`columns2string`/`SET` 的拼接循环，仅分隔符与容器类型不同）
- **来源**：存量（`git blame` → `5f431b4c8f`）
- **判据**：review-checklist §2（只改类型名 / 换控制流）
- **证据**：静态确定 —— 三组 id 重载只在参数类型与 `executor.arg(id)` 的静态分派上不同，SQL 模板逐字相同；4 份拼接循环只有 `StringGenerator` / `StringBuilder` 与分隔符差异，其中 2 份分隔符写错（见 `[一般]` 的 `ORDER_BY` 条目）。
- **描述**：id 三份属于「泛型没上的复制」，可合并为 `byId<T: ToString>`（`arg<T>` 已有重载）；拼接四份合并后，「多列必须逗号」这条规则只剩一处可写错。
- **建议**：改 `private func byIdOf(id: Any): Int64`（内部 `arg(id)`）或泛型版；拼接抽 `joinExprs(items: Array<...>, sep: String)`，`columns2string` 保留为薄封装。

### [轻微][存量] `Transactional` 的 4 个 getter 与 `TransactionAspect` 的「注解 → 配置」回退逻辑重复，且 getter 全仓零引用

- **位置**：`f_orm/src/base/Transactional.cj:32-64`（`getPropagation` / `getIsoLevel` / `getAccessMode` / `getDeferrableMode`）对比 `f_orm/src/base/TransactionAspect.cj:54-71`（同样的 fallback，逐字段手写）
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §2（跨层复制导致行为漂移）、§1（对外可达 public 只记「仓内无引用」，不判死代码）
- **证据**：静态确定 —— 全仓搜索 `getPropagation|getIsoLevel|getAccessMode|getDeferrableMode` 只命中定义处（`Transactional.cj:32/38/47/56`），切面自己重新实现了同一套 `if (let Some(x) <- ...) else ORMConfig.get...(driverName)`；且两者已经有漂移可能：切面用 `propagation ?? Required`，getter 用 `match { Some => p; _ => Required }`（等价），但 `driverName` 取值时机不同（切面用注解里的 `driverName`，getter 用 `this.driverName`）。
- **描述**：`Transactional` 是 `public` 顶层注解、成员对外可达，因此**不按死代码处理**；但 4 个 getter 属于「写了没人用」的重复实现，后续改回退策略时极易只改一边。
- **建议**：切面改为直接调用这 4 个 getter（删掉 `:54-71` 的手写回退），或反过来删掉 getter。二者保留一份即可；若保留 getter，建议在类注释里写明它是唯一入口。

### [轻微][存量] `IntoClause.VALUES(Array<Any>)` 不校验列数与值数一致，不匹配时产出列值错位的 SQL

- **位置**：`f_orm/src/base/TableClause.cj:479-492`（`VALUES(values: Array<Any>)` 只按 `values.size` 拼 `?`，与 `fields.size` 无关）
- **来源**：存量（`git blame` → `5f431b4c8f`）
- **判据**：review-checklist §11（缺少边界校验）、§10
- **证据**：静态确定 —— 同文件 `VALUES<D>(value: D)`（`:493-542`）走 `0..fields.size`，与列清单严格对齐；`Array<Any>` 重载没有对齐检查，也没有「多值/少值」的报错路径。
- **描述**：`values.size != fields.size` 时生成 `insert into t(a,b) values(?)`（少）或 `values(?,?,?)`（多），由驱动报「参数个数不匹配」；错误信息与真实原因（调用方传错数组）距离较远，且不会提示是哪一列。
- **建议**：入口加 `if (values.size != fields.size) throw SqlArgException('expect ${fields.size} values but got ${values.size}')`；更彻底的做法是把该重载改为接收 `Map<Column, Any>`，从类型上排除错位。

### [轻微][存量] `SqlPartialColumnKey_test` 只断言「两个重载输出相等 + 含 UPDATE/WHERE」，无法发现非法 SQL

- **位置**：`f_orm/src/base/SqlPartialColumnKey_test.cj:129-135`、`:152-157`、`:191-196`、`:212-216`（`@Assert(mapSql, arraySql)` + `contains('UPDATE')` / `contains('WHERE')`）
- **来源**：存量（`git blame` → 2026-09/10 测试新增提交）
- **判据**：review-checklist §11（测试把缺陷输出当作期望值）、§2
- **证据**：静态确定 —— 四个用例的 values 都含全部非主键列（`name`/`age`）与主键 `id`，字符串比较是「数组重载 vs Map 重载」互等，缺失任何列的组合都没有用例；`fieldNameAndColumnNameBothResolve` 也只比两份输出。
- **描述**：这组测试的实际保护面是「重载之间行为一致」，而 `[严重]` 项的缺陷恰恰对两个重载同时生效，测试因此给出假阳性安全感。
- **建议**：补一个「只给 `nick` + `id`」的用例，断言 `SET` 段只有一列且不含 `,,`；再补一个「尾列缺失」用例，断言 WHERE 前无尾逗号。断言建议直接用正则 `SET\s+([^,]+=(\?|\S+))(,\s*[^,]+=(\?|\S+))*\s+WHERE` 之类，避免只做 `contains`。

## 优化可行性方案

### [CPU] 分页先 `count(*)` 再取一页，同一份 WHERE 扫两遍

- **现状**：`SqlPartial.cj:294-299` 每次 `page()` 执行两条查询（`select count(*) from (partial)` + `select * from (partial) limit ...`），同一 `partial` 的 WHERE 被求值两次；页大小与偏移只在第二条里生效。
- **方案**：单查询方案 —— 结果集加 `count(*) over()` 列（PG/OpenGauss/Oracle 可用），或先取 `size+1` 行判断「还有下一页」并用缓存的总数（同一筛选条件下 `count` 只在首页执行）。
- **预期**：把分页的数据库往返从 2 次降到 1 次；延迟收益取决于 count 占比（大表上 count 往往是主要耗时）。
- **代价**：窗口函数需按方言分支（`Dialect` 已有扩展点）；「总数」语义会从「精确」变成「首屏快照」，需要接口说明。
- **验证**：`cjpm bench -O2`，10 万 / 100 万行表，`size = 20`，比较 P50/P95 端到端延迟与 `cjprof` 下 DB 等待占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 按 `Array<(Column, Any)>` / `Map<Column, Any>` 更新时的中间 Map 副本

- **现状**：`SqlPartial.cj:123-143`、`:181-187` 为每次更新额外构造一个 `HashMap<String, Any>`（N 个条目 + 哈希桶），随后只被线性遍历一次；`UPDATE<T>(values: T, ...)` 还额外构造 `DataObject<T>` 包装。
- **方案**：让核心实现直接接收 `Array<(String, Any)>`（列名已解析），Map 重载只在入口做一次 `iterator().map` 视图，避免二次容器；`DataObject` 可复用（`DataObject<T>` 是否可缓存需先核对语义）。
- **预期**：每次更新少 1 个 Map（约 N 个 Entry，N = 列数）与一次哈希插入；对高频小更新（单行、十几列）是常数级减少。
- **代价**：重载签名增加一层转发；若 `DataObject` 有可变状态则不能复用。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10 万次单行更新吞吐（`-O2`，同机）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 长事务内翻页导致结果缓存峰值随页数线性增长（本报告 `[一般]` 项的实际量级） | `f_orm/src/base/SqlPartial.cj:296-299` + `SqlExecutor.cj:905-917` | 峰值堆内存 / 缓存条目数 | 事务内翻 1 万页（`size=100`，mock 或本地 PG），每 1000 页采 `getAllocatedHeapSize()` 与 `cache.size` 埋点 |
| 2 | `UPDATE<T>(values: T, ...)` 的 SQL 拼串 + `arg()` 装箱占单次更新自耗时的主要部分 | `f_orm/src/base/SqlPartial.cj:239-265` | 自耗时占比 | `cjprof record` 跑 10 万次单行更新（12 列实体），看 `StringGenerator.append` 与 `SqlArgs.add` 的 self time |
| 3 | `TableMeta.new` 的反射（`getInstanceProperty`/`getInstanceVariable` 各一次 + 注解查找）是启动期 schema 注册的主要开销 | `f_orm/src/base/TableMeta.cj:32-62` | 单表耗时与表数量 | 启动埋点：`TableMetas.register` 前后计时，50 / 200 张实体表各跑一次 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/SqlExecutorStatement_test.cj` | .cj | ✅ | 语句级契约用例；短 SQL 报 `ORMException`、只缓存 SELECT 两向都有覆盖 |
| 2 | `f_orm/src/base/SqlPartial.cj` | .cj | ✅ | 本部分主要缺陷来源（Map 更新的逗号、dirty 清空、分页边界） |
| 3 | `f_orm/src/base/SqlPartialColumnKey_test.cj` | .cj | ✅ | 重载互等断言；覆盖缺口见 `[轻微]` |
| 4 | `f_orm/src/base/SqlResultCacheStream_test.cj` | .cj | ✅ | 含流结果不进缓存 + 无流命中的双向护栏，逻辑与 `QueryResultWrap.hadStream` 一致 |
| 5 | `f_orm/src/base/SqlResultCache_test.cj` | .cj | ✅ | 缓存键按「SQL + 参数内容」区分；用例间 SQL 文本隔离得当 |
| 6 | `f_orm/src/base/Statement_test.cj` | .cj | ✅ | 测试替身（被 `Connection_test.cj:33` 使用），空实现属有意 no-op |
| 7 | `f_orm/src/base/TableClause.cj` | .cj | ✅ | `ORDER_BY`/`GROUP_BY` 分隔符、`deleteById`、`VALUES` 校验、重复拼接循环 |
| 8 | `f_orm/src/base/TableMeta.cj` | .cj | ✅ | 反射探测 + 两处 `catch(_)`；`ColumnMeta`/`IndexMeta` 的 hash/eq 与 `def` 用途核对一致 |
| 9 | `f_orm/src/base/TableMetas.cj` | .cj | ✅ | 静态表 + `clear()` 零值替换（无调用者，潜伏） |
| 10 | `f_orm/src/base/TableSchema.cj` | .cj | ✅ | 3 个注解定义，字段默认值与使用处一致 |
| 11 | `f_orm/src/base/TransactionAspect.cj` | .cj | ✅ | 注解 → 配置回退；`rollbackFor/noRollbackFor` 恒 `Some("")` |
| 12 | `f_orm/src/base/TransactionHook.cj` | .cj | ✅ | 全部默认空实现 + `order` 默认 `Int64.Max`；被 `TransactionHooks` 按 order 排序使用，属扩展点 |
| 13 | `f_orm/src/base/TransactionStatus.cj` | .cj | ✅ | 三态枚举 + 手写 `==`/`toString`/`isXxx`，与 finally 里的 `txStatus` 赋值一致 |
| 14 | `f_orm/src/base/Transaction_test.cj` | .cj | ✅ | 测试替身（被 `Connection_test.cj:27` 使用），setter 空实现属有意 no-op |
| 15 | `f_orm/src/base/Transactional.cj` | .cj | ✅ | 注解定义；4 个 getter 仓内零引用（见 `[轻微]`） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分清单无 `.md`，模块文档一致性由其他子轮覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性命中 2/2：Map 更新的逗号、脏标记清空；边界命中 3/4：分页 `size<=0`、`VALUES` 列数、`deleteById` 返回语义；设计命中 2/3：`TableMetas.clear` 语义与原子性、`Transactional` getter 与切面重复。安全性：SQL 全部走 `arg`/`involve`，未发现拼接外部输入；`SELECT`/`ON_CONFLICT` 等原样拼串的 API 属契约内的「片段」用法，未计 |
| §1 死代码 | 1 | 已逐文件机械过：`private` 符号（`sqlPartialLog`、`selectPage`、`limit`、`sqlWithLimit`、`columns2string`、`APPEND_TRIM_*`、`TinyStream`、`anyText`、`CapturedUpdate`、`executor`/`runOnce` 等）全仓/全文件搜引用均有调用者；`TableClause`/`ExceptInsertClause` 的 `protected` 成员虽属 `sealed`/抽象基类，但逐个确认有子类调用（`appendPartial`/`setSql`/`join`/`condition`）；对外可达 `public` 一律不判。命中 1 条（5 个位置：不可达 `else if`、未使用 `dialect`、恒 true 参数、注释掉的接口默认实现、重复 import）；闭包/宏生成成员按误报边界排除 |
| §2 重复逻辑 | 3 | 同文件内把 `SqlPartial` 的 12 个 UPDATE 重载、`TableClause` 的 20 余个链式方法逐个压成「输入→输出→副作用」比对：命中 3 条（Column 名/Map 转换 8 份、id 重载 9 份 + 拼接循环 4 份、`Transactional` getter 与切面回退）。`findById`/`byId` 的 SQL 模板逐字相同故算重复；`WHERE/AND/OR/NOT` 已由 keyword 参数化，不算 |
| §3 空实现 | 1 | `Statement_test`/`Transaction_test` 的空函数体、`TransactionHook` 的默认空钩子均核对为「测试替身 / 扩展点默认值」，不是缺陷；命中 1 条：`TableMeta.new` 两处 `catch(_){}` 静默吞异常。逐文件搜 `TODO`/`FIXME`/`UnsupportedException` 无命中 |
| §4 栈溢出 | 0 | 本部分无递归：`TableMeta.new` 用 `iterator().map().fold()`，`CapturedUpdate.lastArgs` 是单层循环，`TableClause` 全部为链式拼接；`SqlExecutor.connection` 的自递归不在本部分（已在其他子轮覆盖） |
| §5 OOM | 1 | 命中分页缓存键无界；其余 `mapList`/`list` 的全量物化是查询 API 的既定语义（调用方决定是否用 `iterator`），不计。无「按不可信长度预分配」：`Array<String>(columns.size)` 的上界来自调用方传入的列数组 |
| §6.1 热点瓶颈 | 0 | scope 未提供 bench/profile；本部分没有自耗时数据，唯一疑似热点（分页双查询、UPDATE 拼串）已写入「待验证假设」#1/#2，未按缺陷计 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件无 `synchronized`/`Mutex`/`Atomic`，无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用；分页两条查询是串行往返，但属协议顺序，不是并发配置问题（已并入优化方案） |
| §6.4 低效算法 | 0 | 逐个循环核对：`for (i in 0..order.size)` 为线性、无嵌套、无 `contains` 热点、无 `remove(at:0)`、无循环内字符串 `+`（均用 `StringGenerator`）。`TableMeta.new` 的 `map+fold` 属冷路径（启动期一次），未计 |
| §7 降堆内存方案 | 0 | 只给出 1 条无基线方案（更新路径的中间 Map），因缺改前/改后峰值对照，按规则不计入命中 |
| §8 降 CPU 方案 | 0 | 同上（分页双查询），`无基线（待验证）`，不计入命中 |
| §9 local mode 可行性 | 0 | 本部分函数均返回 `String`/实体/`Pagination`（逃逸到调用方或缓存），且 `TableMeta`/`TableClause` 的对象被字段/静态表强引用，逃逸检查不通过；无「函数内创建、函数内释放」的大临时对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | 逐函数核对了边界/空值/错误处理：命中 8 条（逗号、排序分隔符、除零、`deleteById`、rollback 配置、`clear()` 零值、脏标记、`catch(_)`）。空集合/空串路径（空 Map 更新、空 values、空条件）逐条走过：空 Map 与「无列可更新」已有异常，空条件由 `emptyLogicalExpr` 短路 |
| §12 并发安全与锁粒度 | 1 | 共享点只有 `TableMetas.schemas`（静态 `var` + `ConcurrentHashMap`）：正常读写走并发容器，但 `clear()` 是普通引用替换（非原子、无同步），已并入 `TableMetas.clear` 条目；其余 `SqlExecutor`/`Partials`/`DirtyTag` 均为线程本地（`ThreadLocal`/`ThreadLocal` 集合），`TableClause` 实例按调用新建。无锁粒度问题（本部分无锁） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 覆盖由同模块其他子轮核对；功能完备性方面逐个 public 声明核对了实现体（无 `TODO`/`UnsupportedException`），`Transactional` 4 个 getter 属「可见性建议」不属功能缺失，已在 §2 条目记录 |
| 文件覆盖（§13 等） | 15/15 | 清单 15 个文件全部读完；本部分无 `.md`，§13 文档一致性在模块其他子轮覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分的风险集中在 `SqlPartial` 的「按 Map 更新」与 `TableClause` 的链式拼接两处：前者有一个**确定会生成非法 SQL** 的逗号缺陷（部分列更新这条主路径不可用，且现有测试用「两重载互等」掩盖了它），后者有多列排序/分组用空格连接的同类拼接错误——两处同源，都是「先拼分隔符、后判是否命中」的顺序问题，建议合并成一次修复并补多列/缺列的用例。事务侧的问题不是崩溃而是**语义静默偏移**：`@Transactional` 一旦出现就让全局回滚配置失效，`dirty` 更新失败后脏标记被清掉，属于「不报错但结果不对」的一类，排查成本高，建议与 `SqlExecutor` 的回滚规则一起复核。

`TableMetas.clear()` 的零值替换与 `TableMeta.new` 的 `catch(_)` 都是潜伏项：前者无调用者，后者只在反射异常时触发，但一旦触发就是 schema 元数据静默缺失、`migro` 生成错误的 DDL，建议排期修掉。分页结果进缓存的问题依赖「长事务内翻页」这一使用方式，属于有界但无上界的增长，可按「待验证假设 #1」先量测再决定是否加容量或排除分页 SQL。

测试与夹具部分（`Statement_test`/`Transaction_test`/三个缓存与语句用例）质量尚可：替身实现意图明确，流缓存的正反两向都有护栏；唯一缺口是 `SqlPartialColumnKey_test` 的断言强度，建议作为 `[严重]` 项的回归用例补上。存量 8 条，是否纳入修复待用户决定。
