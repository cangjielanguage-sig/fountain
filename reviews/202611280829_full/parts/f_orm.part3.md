# f_orm 模块审查报告（第 3/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（全模块 111 个源文件；**本部分覆盖 15 个**：`base/Pagination` / `base/Partials` / `base/QueryMapper` / `base/QueryMapperConverter` / `base/QueryMappers` / `base/QueryMappersInit` / `base/QueryResultIterator` / `base/QueryResultIterator_test` / `base/QueryResult_test` / `base/RootDAO` / `base/RootService` / `base/SqlDSL` / `base/SqlExecutor` / `base/SqlExecutorArgBranches_test` / `base/SqlExecutorConnectingTimeout_test`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，工作区干净；快照模式无 diff，本部分发现全部记为「存量（快照模式无基线）」）
- **审查重点**：分页 / 查询映射 / 结果迭代 / SQL 执行器的正确性、连接生命周期、并发安全、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，待主 Agent 合并为 `docs/review/f_orm_review_20261128.md`）
- **统计口径**：只含本部分 15 个文件。第 2/8 部分已就 `DirtyTag`（`f_orm/src/base/DirtyTag.cj`）与 `newNest`/`newGrouped` 等 5 个 `newXxx` 死代码出过结论，本部分只在涉及本部分文件处交叉引用，**不重复计数**。本部分无 `.md` 文件；为核对契约读过 `f_orm/README.md` §8、§12、§13.1-13.3、§3.1、§14 相关行。

## 发现

### [严重][存量] `QueryMappers.create` 合并父类 mapper 时下标少减偏移：父类字段被丢弃或直接越界崩溃

- **位置**：`f_orm/src/base/QueryMappers.cj:53-60`（关键行 `:58` `else { mappers[i] }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一 / 越界）、§1（恒真恒假分支中 `TypeInfo.of<O>().isSubtypeOf(TypeInfo.of<Object>())` 恒真）
- **证据**：静态确定 —— 数组长度为 `oMappers.size + mappers.size`，lambda 的 `i` 从 `0` 遍历到 `size-1`；`i >= oMappers.size` 时取的是**子类** mappers 数组，正确下标应为 `i - oMappers.size`，代码写的是 `mappers[i]`。
- **描述**：`create<T>` 是「PO 继承映射 PO」的唯一合并入口（README `:1392`「继承场景：把父类 O 的 mapper 与子类新增 mapper 合并」、`:1735`；宏在 `f_orm/src/macros/QueryMappersGenerator.cj:138-144` 对每个父类型生成 `QueryMappers<$st>.create<$name>(creator, mappers)`）。设父类有 `p` 个 mapper、子类新增 `c` 个：
  - `c > p` 时全部越界（`i` 最大到 `p+c-1 >= c`），构造期抛 `IndexOutOfBoundsException`，该 PO 的 `queryMappers()` 静态初始化直接失败——该类所有查询不可用；
  - `c <= p` 时不越界但取到错误的 mapper：子类第 1 个字段用第 `p+1` 个 mapper 填充、前 `p` 个新字段丢失，**列与字段错位映射**（不报错的数据错误）。
  仓内现有 PO（`fdemo/user/src/model/po/UserPO.cj`、`f_llm/src/model/po/*.cj`）都没有「继承自另一个映射 PO」的形态，所以这是**未被现有测试触发的潜伏缺陷**，但 README 明确承诺该能力。
- **建议**：`else { mappers[i - oMappers.size] }`；同时删掉恒真的 `TypeInfo.of<O>().isSubtypeOf(TypeInfo.of<Object>())` 条件。补一个用例：父 PO 3 列 + 子 PO 2 列，断言 `queryMappers().mappers.size == 5` 且每列 `columnName` 与期望顺序一致。

### [严重][存量] `QueryMappers.create` 用基类 `QueryMapper.new<T>()` 复制父类 mapper：嵌套 / 集合字段的映射逻辑被静默丢弃

- **位置**：`f_orm/src/base/QueryMappers.cj:56`（`oMappers[i].new<T>()`）；被调方 `f_orm/src/base/QueryMapper.cj:37-44`；丢失行为的三个子类 `NestQueryMapper.cj:25-35`、`NestQueryMapper.cj:46-57`、`GroupedQueryMapper.cj:27-42`（另有 `GroupedQueryMapper.cj:52-67`、`:78-104`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 静默失效）、§3（实现被空实现替代）、§2（`newXxx` 系列与 `new<T>` 的分支复制）
- **证据**：静态确定 —— `QueryMapper.new<T>()` 返回的是 **`QueryMapper<T>` 基类实例**，其 `putter` 是 `{instance, value => putter((instance as O).getOrThrow(), value)}`；而 `NestQueryMapper` / `NullableNestQueryMapper` / `GroupedQueryMapper` / `GroupedSingleQueryMapper` / `NullableGroupedQueryMapper` 覆盖的是 **`populate`**（`NestQueryMapper.cj:31-35`、`GroupedQueryMapper.cj:38-42`），并且专门提供了 `newNest` / `newNullableNest` / `newGrouped` / `newGroupedSingle` / `newNullableGrouped` 做「换宿主类型」。全仓 `grep` 这 5 个 `newXxx` 只有定义处（与第 2/8 部分「5 个 `newXxx` 死代码」同一批符号），`create` 走的是 `new<T>()`。
- **描述**：父类上任何 `@QueryMappers` 嵌套对象 / 一对多集合字段，在子类继承合并后都会退化成基类 mapper：`dataType` 是 `UnknownDataType(true,'','')`（`NestQueryMapper.cj:23`），`putter` 是 `{o,v =>}` 空实现，`populate` 用基类版本 → **该字段永远不被填充且不报错**（嵌套对象为默认构造的空对象、集合为 null/空）。叠加同函数的下标缺陷，继承映射这条路径当前不可用，且失败形态可能是「静默丢字段」而非异常。
- **建议**：把「按运行时类型换宿主」做成 `QueryMapper` 的 `open func rebind<SUB>(): QueryMapper<SUB>`（基类返回 `new<SUB>()`，五个子类各自返回对应 `newXxx`），`create` 改为 `oMappers[i].rebind<T>()`；`newNest`/`newGrouped` 等随之接线，同时消掉第 2/8 部分记的那批死代码。补用例：父 PO 含一个嵌套对象 + 一个集合字段，子类继承后查询两行，断言嵌套与集合都被填充。

### [严重][存量] `sql` setter 对整条 SQL 折叠连续空白：字符串字面量 / `LIKE` 模式被改写，静默查出或写入错误数据

- **位置**：`f_orm/src/base/SqlExecutor.cj:71-88`（关键行 `:76` `blankRegex.replaceAll(value, " ")`；`blankRegex` 定义在 `:43`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名 / 注释不符、静默数据错误）、§10（外部输入未校验）
- **证据**：静态确定 —— `Regex(#"\s{2,}"#)` 作用于**整条 SQL 文本**，不区分是否处于 `'...'` / `"..."` / `$$...$$` 字面量或注释内。
- **描述**：`setSql("insert into t(v) values ('a  b')")` 会被改写成 `'a b'` 再执行：写入值与调用方给的字符串不同；查询侧同理，`where name = 'a  b'` / `like '%x  %'` 会变成另一个模式，**不报错但结果错误**。`setSql` 是公开入口（README §3 与各 DAO 生成代码都走它），任何手写含连续空白的字面量都会中招；如果两个只差空白的字面量被归一成同一文本，还会共用同一份结果缓存（见下条「缓存」）。
- **建议**：归一化只做「首尾 trim」与「把 `\r\n`/`\n`/`\t` 换成单个空格」，且必须跳过字面量：最简单是直接不做内部空白折叠（驱动的 prepare 允许任意空白）；如要保留归一化，需用 `cangjieLex` 之类的词法层只处理非 `STRING_LITERAL`/注释 token，并补一条用例断言 `'a  b'` 原样进入 SQL。

### [严重][存量] `SingleColumnIterator.next()` 把「单元格为 NULL」当成「结果集结束」：静默截断结果并让 executor 一直处于「有活动结果集」状态

- **位置**：`f_orm/src/base/QueryResultIterator.cj:101-115`（`getOrNull` 返回 `None` 时直接 `return`，且**不** `close()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空值未处理 / 静默丢数据）、§3（`None` 当兜底把错误吃掉）、§12.1（资源持有）
- **证据**：静态确定 —— `SingleColumnIterator.next()` 的返回类型是 `?T`，`None` 同时承载「无更多行」与「本行该列为 NULL」两种语义；NULL 分支（`getOrNull<T>` 返回 `None`，`QueryResultWrap.cj:94-984` 的 `case x: ?T => x`）只 `return`，既不 `close()` 也不置 `closed_`。
- **描述**：`ex.setSql('select score from t order by id').singleIterator<Int64>()` 读到第一条 NULL 时调用方 `while (let Some(v) <- it.next())` 直接结束：**后续所有行被静默丢弃**；同时 `activeQueryResult` 仍为 `true`（`SqlExecutor.cj:964`），此后同一 executor 的任何查询都抛 `ORMException("cannot execute SQL while a previous query result is still active")`，直到调用方显式 `close()`。`close()` 本来只在「真正读尽」分支里调（`:111-113`），NULL 分支恰好绕过了它。
- **建议**：区分两种语义——`next()` 返回 `?T` 时把「列 NULL」映射为 `None<T>` 之外的可辨识值（例如改返回 `??T` 或 `Option<Option<T>>`，或提供 `nextRow(): Bool` + `current(): ?T` 的两段式 API）；做不到就至少在该分支 `close()` 并抛 `ORMException`（不要静默截断），README §14（`:1477`）需同步说明 NULL 行为。补用例：3 行含 1 行 NULL，断言要么 3 行都返回、要么显式报错。

### [严重][存量] `SqlDSL` 的 `:{...}` 数据路径解析用错循环变量：README 承诺的语法 100% 不可用，并会吞掉 `}` 之后的所有 token

- **位置**：`f_orm/src/base/SqlDSL.cj:63-91`（关键行 `:71` `while(i < tokens.size && token.kind != RCURL)`、`:75` 的完整性判断、`:85` 取 `name`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）、§14（承诺了但没实现）
- **证据**：静态确定 —— `:64` 的 `let token = tokens[i]` 此刻是 **`LCURL`**（`{`），`:71` 的 `token.kind != RCURL` 恒真，循环只由 `i < tokens.size` 终止：
  1. 路径会把 `}` 以及其后的**所有 token** 收进 `path`（`:72-73`），`i` 走到 `tokens.size`；
  2. `:75` 的第二个判断改成检查「整条 DSL 的最后一个 token 是否是 `}`」，于是 `select ... where a = :{x.y} and b = 1` 直接抛 `IllegalArgumentException('not completely data path ...')`；
  3. 即使 `:{...}` 恰好在 SQL 末尾，`path[path.size-1].value` 也是 `}` 的文本（`:85` → `name = '}'`），拼出的 `path.toString()` 带尾随 `}` 交给 `DataPath.solid`（`:86`），后者只接受 `$`/`@` 前缀并重新词法分析（`f_data/src/path/DataPath.cj:76-81`），必然抛 `DataException`。
- **描述**：README §8.1（`:822` `:{a.b.c}`、`:823` `:{name}` 等价 `:name`、`:827` PO 允许 `:{user.name}`/`:{$.user.name}`）描述的整块能力当前对任何输入都失败；错误形态还是「吞掉剩余 SQL 后报一个与真实原因无关的异常」，排查成本高。
- **建议**：循环条件改为 `tokens[i].kind != RCURL`；循环结束后单独判断 `i < tokens.size && tokens[i].kind == RCURL`（缺 `}` 才报错）并 `i++` 跳过 `}`；`path` 用 `Tokens` 的切片而不是累加「到末尾」；`name` 取路径最后一段的**字段名**（`path[path.size-1].value` 前先剔除 `RCURL`）。补三条用例：`:{a}`、`:{a.b}` 在 SQL 中间、`:{a.b}` 在末尾，逐字节断言生成的 SQL 与参数个数。

### [严重][存量] `SqlDSL.convert` 的 `Iterable<Data>` 分支为每个元素多生成一个占位符、逗号位置也错：`IN` 展开后 SQL 与参数数不符

- **位置**：`f_orm/src/base/SqlDSL.cj:112-123`（`convert` 的 `case Some(x: Iterable<Data>)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（逻辑错误 / 参数与占位符错位）、§2（与 `RootDAO.arg<I,T>`（`RootDAO.cj:323-389`）同一件事的第二套实现）
- **证据**：静态确定 —— 循环体先调 `convert<T>(...)`（标量分支在 `:125` 统一 `sqlgen.append(' ? ')`），再 `if(c > 0) sqlgen.append(',')`、`sqlgen.append('?')`。3 个元素实际生成 `" ? ? ? ,? ? ,?"`（**6 个 `?`**），而只绑定了 3 个参数。
- **描述**：README `:828` 承诺「`Iterable<Data>` → 展开为逗号分隔的多个 `?`（便于 `IN` 使用）」。任何 PO / Map 里以数组字段参与 `:{field}` 绑定的写法（`DataCollection<C,T> <: Collection<Data>`，`f_data/src/base/CollectionData.cj:27`，除 `Array<Byte>` 外都会落到这个分支）都会拼出错误 SQL：驱动报参数个数不符，或（若后续还有 `?`）参数按位置错位绑定，**条件被换成别的值**。
- **建议**：循环内不要调会追加 `' ? '` 的 `convert`；改为「每元素只做 `exe.arg(...)` 绑定 + 自己决定分隔符与 `?`」，或复用 `RootDAO.arg<I,T>` 的唯一实现；补用例逐字节断言 `' (?,?,?)'`（对齐 `f_orm/src/base/ArgSqlText_test.cj` 的写法）。

### [严重][存量] 结果缓存键把「任意两个 `InputStream` 参数」判为相等：同一事务内不同 BLOB 参数命中同一缓存，返回别人的结果

- **位置**：`f_orm/src/base/SqlExecutor.cj:905-919`（`:906` `let key = SqlCacheKey(sql, args)`、`:907-908` 命中即返回）；相等性来源 `f_orm/src/wrap/SqlArg.cj:455-459`（`case x: InputStreamSqlArg => true`），哈希 `:445-452` 只含 `index`/类型
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缓存键不完整 → 数据错误）、§12.1（跨请求共享可变结果）
- **证据**：静态确定 —— `SqlArgs.==` 逐元素比 `SqlArg.==`（`wrap/SqlArgs.cj:120-122`）；`InputStreamSqlArg.==` 在 `equals(other)（同为 `InputStreamSqlArg` 且 `index` 相同）后直接 `true`，**不比较流内容**。因此 `select digest from doc where body = ?` 用流 A 执行后再用流 B 执行，得到完全相同的 `SqlCacheKey`。
- **描述**：缓存只在「事务内」生效（非事务路径每条语句结束时 `close()` → `cache.clear()`，见下条），触发条件是「同一事务里用同一 SQL、不同 BLOB 参数查了两次」——返回第一次的结果，**第二个 BLOB 拿到第一个 BLOB 的查询结果**，且完全静默。这是典型的「缓存键不含参与判定的输入」缺陷；同理 `SqlCacheKey` 也不含结果类型（见「一般」第 1 条）。
- **建议**：`InputStreamSqlArg` 不应参与缓存键——两条路：① `SqlArgs` 暴露 `hasStream`，`SqlExecutor` 见到流参数就不建 key（已对「含流的结果」这么做，`lastResultHadStream`，把「含流的参数」也纳入同一判断）；② 给流参数分配一次性单调 id 并放进键（必然不命中，等价于禁用缓存）。补用例：同事务内两个不同流参数查询，断言两次都真的执行（mock 记录执行次数）。

### [一般][存量] 结果缓存键不含结果类型：同一 SQL 用不同类型读取时抛 `ORMException` 而不是重新查询

- **位置**：`f_orm/src/base/SqlExecutor.cj:905-919`（`:909` `case Some(_) => throw ORMException("type of cached data ... does not match")`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§3（合法调用被拒）
- **证据**：静态确定 —— `SqlCacheKey` 只含 `sql` + `args`（`SqlExecutor.cj:25-39`）；`execute<T>` 用运行期类型 `T` 匹配缓存值，不匹配即抛。
- **描述**：事务内 `ex.setSql('select count(*) from t').first<Int64>()` 之后，同 SQL 调 `singleList<Int64>()` / `mapList()` 会撞上「类型不符」异常；这是合法且常见的用法（同一计数 SQL 既取单值也取列表）。README `:393` 把该行为写成「设计」，但对使用者是陷阱：缓存命中与否取决于**此前是否有人用另一种类型读过同一 SQL**。
- **建议**：把结果类型纳入键（`SqlCacheKey(sql, args, TypeInfo.of<T>())`，或按 `T` 分桶）；或者命中类型不符时退化为「重新执行并覆盖」，不抛异常。

### [一般][存量] 非事务路径下结果缓存「写入即清空」，只剩每条 SELECT 的建键开销；缓存容器本身无上限

- **位置**：`f_orm/src/base/SqlExecutor.cj:923-926`（`cache.clear()`）、`:153-157`（`close()` 里 `cache.clear()`）、`:886-900`（非事务 exec 的 `finally` 调 `close()`）、`:54`（`cache: Map` 无容量上限）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4（无效工作）、§5（无界容器）、§7（可降堆内存）
- **证据**：静态确定 —— 非事务语句的执行顺序是「`cache[key] = v`（`:916`）→ finally `this.close()`（`:897`）→ `cache.clear()`（`:157`）」；下一次 SELECT 必然 miss。缓存只在事务中（`tx.isSome()` 时 `close()` 不动）才有命中机会。另外 `cache` 是普通 `HashMap`，事务里无淘汰、无上限，长事务里每条不同 SQL 都留一份完整结果对象。
- **描述**：默认 `useCache = true`，于是**每条 SELECT 都要付一次建键成本**（哈希 SQL + 遍历参数哈希；参数含 `Array<Byte>` 时还会走 `ByteArraySqlArg.hashCode` 的 `value.toString()`，`wrap/SqlArg.cj:513-515`，1 MB BLOB ≈ 2~3 MB 临时字符串），而收益为零；README `:181`/`:388` 把它描述成常规读优化，使用者会误以为跨语句有效。事务内的无上限缓存则是另一头的 OOM 面（一条事务跑 1 万条不同 SQL，结果集（含 `ArrayList` 元素）全量常驻）。
- **建议**：二选一并写进 README：① 明确「结果缓存只服务事务内重复读」，非事务时不建键（把 `if (useCache && !clearCache && sql select)` 收紧为「`tx.isSome()` 且 useCache」），省掉纯开销；② 若要保持跨语句缓存，则不能再在每个 `close()` 清空，并需给 `cache` 加上限 + LRU。`ByteArraySqlArg.hashCode` 改成按字节（长度 + 首尾片段）计算，避免整串格式化。

### [一般][存量] 每次执行/失败都把完整 SQL 与全部参数值写进日志（含 `String`、`Array<Byte>` 原文）

- **位置**：`f_orm/src/base/SqlExecutor.cj:928-936`（warn）、`:935-939`（debug）、`:432-442`（`logMsg`）；参数格式化 `f_orm/src/wrap/SqlArg.cj:60-62`（`'(${index}, ${TypeInfo.of<T>()}, ${value})'`）、`wrap/SqlArgs.cj:105-107`
- **来源**：存量（快照模式无基线）
- **判据**：`fountain-baseline.md` §6（日志中不得出现凭据、令牌、完整报文）、review-checklist §10（敏感数据进日志）
- **证据**：静态确定 —— `logMsg` 捕获 `this.args` 原对象，闭包插值即 `SqlArgs.toString()`，逐参数输出**值本身**；`Array<Byte>` 参数走 `toString(value)` 输出整段字节。
- **描述**：登录/凭据类查询（`where account = ? and password_hash = ?`）、带 BLOB 的写入，在 debug 级别和任何异常路径（warn）都会把参数原文落到日志文件；`Array<Byte>` 还会把整个二进制内容展开成字符串，单条日志可达 MB 级（日志放大见 `perf §9.1`）。
- **建议**：参数格式化改为「只在 debug 且显式开关（如 `orm_logArgs`）下输出值，默认只输出 `TypeInfo` + 长度/掩码」；`Array<Byte>`/`InputStream` 一律只输出字节数；warn 路径建议只出 SQL 与异常，不出参数。

### [一般][存量] `readOnly` 只置真、永不复位，且只认 `select` 前缀：事务钩子拿到的只读标记不可信

- **位置**：`f_orm/src/base/SqlExecutor.cj:46-47`、`:84-86`（唯一赋值点 `readOnly = true`）、`:97-106`（`clearSql` 不复位）、`:107-111`（`isReadOnly`）、消费点 `:1048`/`:1071`/`:1087`（`ORM.hooks.beforeCommit(this.isReadOnly)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名不符 / 状态未复位）
- **证据**：静态确定 —— 全文件 `readOnly` 只有 `false` 初值与 `= true` 一处写入；`setSql` 每次都会被调用，但只有以 `select` 开头的语句会置真，之后任何 `update`/`insert`/`delete` 都不会把它改回 `false`。
- **描述**：一个 executor 只要执行过一条 SELECT（含 `selectPage` 的 count 查询），本事务后续 `beforeCommit(readOnly: true)` 全部误报只读；反过来 `with ... select`（CTE）与 `show`/`explain` 之类被当成非只读。任何依赖该标记做「只读事务优化 / 审计」的 `TransactionHook` 实现都会拿到错值。
- **建议**：在 `clearSql()` 里 `readOnly = false`（每条语句重新判定），并把判定从「前缀 `select`」改为「前缀 `select|with|show|explain|desc`」；`isReadOnly` 语义在 README 中写清是「当前/最近一条语句」。

### [一般][存量] 事务进行中连接被判 `Closed`/`Broken` 时，`getInstance` 直接换连接但保留 `tx`：事务静默失效，后续写入自动提交

- **位置**：`f_orm/src/base/SqlExecutor.cj:113-132`（`:117-128` 重置 `_connection_`，不动 `tx`/`hasRealTx`）、`:154`（`close()` 在 `tx.isSome()` 时直接返回）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 状态不一致）、§12.1（共享状态与生命周期）
- **证据**：静态确定 —— `getInstance` 只处理连接对象（`NoneConnection` / `close()`），`this.tx` 与 `hasRealTx` 保持原值；`statement` getter 走 `connection`，后者在 `NoneConnection` 时新建连接（`:428`），新连接**没有 `BEGIN`**。
- **描述**：驱动把连接判成 `Closed`（服务端重启、idle timeout、池回收）后：同一线程再次 `ORM.executor()` 拿到同一个 executor，`_connection_` 被换成新连接，`tx` 仍是 `Some(旧 TransactionWrap)`。于是后续 DAO 语句在新连接上以自动提交执行——**本应回滚的写入被真实提交**；最后 `commit()` 在旧连接上抛异常，调用方以为「整个事务失败」。触发依赖驱动的状态判定，但代码路径是确定的。
- **建议**：`getInstance`（及 `connection` 的 `Closed`/`Broken` 分支）发现 `tx.isSome()` 时不要静默换连接：抛 `TransactionException('transaction lost: connection closed')` 并清空 `tx`/`hasRealTx`，让上层明确失败；或在换连接前先 `tx.rollback()` 尽力收尾。

### [一般][存量] `Any` 参数分派表三份手工副本已漂移：`?InputStream` 与 `Data` 在部分入口静默退化成 `toString()` 绑定

- **位置**：`f_orm/src/base/SqlExecutor.cj:610-654`（`add<T>`）、`:859-866`（`add(Any)`）、`f_orm/src/base/RootDAO.cj:252-307`（`arg(Any)`）、`:323-389`（`arg<I,T>`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量/分支表复制导致行为漂移）、§11（静默丢参类型）
- **证据**：静态确定 —— 逐分支比对：`add<T>`（`:632-650`）有 `?Int64…?Array<Byte>` 但**没有 `?InputStream`**，也没有 `Data`；`add(Any)`（`:860-865`）有 `?InputStream` 但**没有 `Data`**（`Data` 实现 `ToString`，会走 `case x: ToString => add<ToString>(x)` → `add<T>` 兜底 `add(x.toString())`）；`RootDAO.arg(Any)`（`:280-304`）两者都有。三处注释都写着「与 X 的分支顺序保持同步」（`:607-609`、`RootDAO.cj:327`、`:253`），靠人工维护。
- **描述**：`ex.add(anyWhereValueHolds?InputStream)`（例如从 `Map<String,Any>`/反射取到的可选流）会落进 `add(x.toString())`，绑定字符串 `"Some(...)"` 而不是 NULL/BLOB；`ex.add(someData)`（`DataString`/`DataCollection` 等）同样被字符串化。这与已修的 ORM-N2（Float32 静默丢参）同源：**兜底分支把「不支持」变成「静默绑定垃圾值」**。
- **建议**：收敛成一处实现（例如 `SqlArg.new<T>(index, value)` 已有完整分派，`add`/`arg` 都复用它），`add<T>` 补齐 `?InputStream`，`add(Any)` 补 `Data` 分支；兜底从 `add(x.toString())` 改为抛 `SqlArgException`（与 `RootDAO.arg(Any)` 一致）。

### [一般][存量] `DataReal` 一律按字符串绑定：DSL / `arg(Data)` 的数值参数在强类型库上可能类型不匹配

- **位置**：`f_orm/src/base/RootDAO.cj:239-251`（`:242` `case x: DataReal => arg(x.data.toString())`）、`f_orm/src/base/SqlDSL.cj:103-126`（`:111` 同一写法）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§2（同一映射两处复制）
- **证据**：静态确定（类型流）+ 需实测（驱动行为）—— `DataReal.data` 是 `Decimal`（`f_data/src/base/DataReal.cj:18-20`）；而 `Int64.toData()` 返回 `DataReal`（`f_data/src/base/NumberData.cj:18-21`），所以 `setSqlFromMap('delete ... where id = :id', map['id']=1)` 最终走 `arg(Decimal.toString())` → `add(String)`。
- **描述**：README `:828` 把「数值 → 以字符串形式绑定」写成规则，`:836` 的示例正是 `map['id']=1` 删主键。以 `setString` 把 `"1"` 绑到 `bigint/numeric` 参数上，PostgreSQL/openGauss 会报 `operator does not exist: bigint = text`（MySQL 会隐式转换）。是否需要隐式转换取决于驱动，仓内没有该场景的用例。
- **建议**：`DataReal` 绑 `Decimal`（`add(x.data)`），由驱动按列类型转换；如担心 `Decimal` 驱动的支持面，至少在 README §8.1 标注「数值以文本绑定，强类型库需自行转 `Decimal`」并补一条 PG 集成用例。

### [一般][存量] `QueryMapperConverter.convert` 用 `StringReader.readToEnd()` 全量物化 CLOB，无长度上限

- **位置**：`f_orm/src/base/QueryMapperConverter.cj:43-57`（`:52`）、`:60-81`（`:67`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（一次性物化 / 按不可信长度读取）
- **证据**：静态确定 —— `readToEnd()` 把整个流读成 `String`，随后 `JsonValue.fromStr(json)` 再建整棵 JSON 树；两步都没有大小上限或拒绝路径。
- **描述**：`@ORMField[converter: 'QueryMapperJsonConverter']` 的列若存的是大 JSON（驱动给的是 `InputStream`/`SqlClob`），单行即可产生「原始字节 + UTF-8 字符串 + JSON 节点」三份驻留，100 MB CLOB 的最坏峰值是数百 MB 量级，且发生在结果映射主路径上，多行叠加可打爆堆。
- **建议**：加可配置上限（默认如 8 MB），超限抛 `ORMException`；或改成流式解析（`JsonValue` 是否支持增量解析需查 `f_data` API）。至少要在 README 的 converter 段落写明「整段读入」。

### [一般][存量] `Pagination` 不校验 `size`/`page`：`size == 0` 直接除零 panic，`page <= 0` 生成负偏移

- **位置**：`f_orm/src/base/Pagination.cj:36-41`（`rows / size`）、`:49-53`（`(page - 1) * size` 作为 offset 传出）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 除零）、§10（缺少边界校验）
- **证据**：静态确定 —— 构造函数对 `size`/`page` 无任何检查；`rows / size` 在 `size == 0` 时抛 `ArithmeticException`（不是 `ORMException`），`page == 0` 时 offset = `-size`，交给 `Dialect.limit`（`f_orm/src/base/SqlPartial.cj:296-299`）拼进 SQL。
- **描述**：`page<R>(sql, size, page!)` 的 `size`/`page` 常直接来自 HTTP 查询参数；`size=0` 让进程抛运行时 panic（框架若未统一兜底就是 500/崩溃日志），`page=0` 让数据库报 `OFFSET must not be negative`。README `:1328` 只写「page 从 1 开始」，没有校验承诺。
- **建议**：构造期校验：`size > 0`、`page >= 1`，不满足抛 `ORMException`（带实际值）；`rows < 0` 同样拒绝。补用例覆盖 `0`/负数/`page` 超页数。

### [一般][存量] `Pagination.tryFromData` 恒失败：`dataFields` 的 creator 直接抛 `IllegalAccessException`，`list` 还是只读字段

- **位置**：`f_orm/src/base/Pagination.cj:57-59`（`tryFromData`）、`:60-71`（`dataFields`，`:69` creator `{=> throw IllegalAccessException()}`、`:67` `list` 用 `ReadonlyField`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（公开契约承诺有行为、实现为空/抛异常）、§14（承诺了但没实现）
- **证据**：静态确定 —— `f_data_tryFromData` → `DataObject<O>.populate(src, flag)` → `T.dataFields().create()`（`f_data/src/base/DataObject.cj:208-212`）→ 调用 creator → 必然抛 `IllegalAccessException`；即便 creator 可用，`list` 是只读字段，`set` 也填不进去。
- **描述**：README `:1346` 明确写「`Pagination` 可作为 PO 的字段类型（实现了 `ObjectData`），并支持与 `Data` 互转（`toData()` / `tryFromData`）」。实际 `toData()`（序列化）可用，`tryFromData`/`convert<Pagination<T>>` 一律抛一个与业务无关的 `IllegalAccessException`；作为 PO 字段从 JSON 反序列化同样失败。仓内唯一的 `creator: () -> Object` 抛异常实现就在此处（其余 `ObjectData` 均走生成器）。
- **建议**：二选一：① 提供真实 creator（`Pagination<T>(page: 1, size: 1, rows: 0, list: ArrayList<T>())` 之类可构造的默认值）并把 `list` 改为可写字段（或用 `ReadonlyField` + `populate` 里整体替换的钩子）；② 明确「Pagination 只支持序列化」，把 `tryFromData` 改成抛 `UnsupportedException` 并在 README 删掉「互转」承诺。两条都要动 README `:1346`。

### [一般][存量] `waitConnecting` 是无退避忙等：连接停在 `Connecting` 时整核空转到超时

- **位置**：`f_orm/src/base/SqlExecutor.cj:400-408`（`while (state == Connecting) { if (now - start >= timeout) throw ... }`）
- **来源**：存量（快照模式无基线；`:395-399` 的注释已承认「原先无 sleep、无超时」）
- **判据**：review-checklist §6.4（空转）/ §8（降 CPU）
- **证据**：静态确定 —— 循环体内只有 `MonoTime.now()` 与比较，没有 `sleep`/条件等待；上限默认 5s（`SqlExecutorConnectingTimeout_test.cj:95` 注释）。
- **描述**：驱动异步建连卡住时，调用线程 100% 占一个核，最长等于 `orm_connectingTimeout`；并发 10 个线程同时建连即 10 核空转。这不是「疑似热点」，而是确定的 CPU 浪费（量级由超时长度决定）。
- **建议**：改成条件等待（驱动的连接状态没有回调时至少 `sleep(1~5ms)` 轮询），或把等待挪到驱动/连接池的 `connectTimeout` 里；超时语义与 `ConnectionException` 文案保持不变。

### [轻微][存量] §1 死代码：`Partials` 的 8 个函数、`SqlFunc.init(String,String)`、`SqlExecutor.add(all:)`、一个未用 import 组

- **位置**：
  - `f_orm/src/base/Partials.cj:40-57`（`AND`/`OR`/`NOT` 的 `String` 与闭包两种重载共 6 个）、`:23-35`（`append(op: String, sql: String)` 与 `append(op: String, sql: () -> Unit)`，仅被上面 6 个调用）
  - `f_orm/src/base/RootDAO.cj:560-562`（`init(fnname: String, column: String)`，internal）
  - `f_orm/src/base/SqlExecutor.cj:867-869`（`protected func add(all!: SqlExecutor)`）
  - `f_orm/src/base/QueryMapper.cj:18-21`（`std.collection.{ArrayList, Map, HashMap, Set, List}` 与 `OverSizeException`/`EmptyMap` 未使用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`protected class` 的非豁免成员 / internal 无调用者 / 未用 import）
- **证据**：静态确定（全仓搜索）——
  - `Partials` 是 `protected class`（顶层非 public），其 `protected` 成员无「外部子类」豁免；`TableClause.cj:138-145`/`:193-198`、`ChooseCondition.cj:114`、`MeetCondition.cj:47`、`RootDAO.cj:400` 只用 `clear()` / `append(String)` / `operator ()`（`PAREN`）/ `toString()`；`partials.AND|OR|NOT` 全仓 0 命中，6 个重载与它们独占的 2 个 `append` 私有重载共 8 个函数无调用者。
  - `SqlFunc(...)` 全仓只有 `RootDAO.cj:526-541` 的 6 处（走私有主构造 `:559`），`init(fnname: String, column: String)` 0 调用；类成员默认 `internal`（`class.md:370`），下游不可见。
  - `add(all:` 在 `f_orm` 内 0 调用（其余命中是 `f_base`/`f_cache` 的 `ArrayList.add(all:)`，与此无关）。
- **建议**：直接删除这 10 个符号与未用 import。注意与第 2/8 部分「`ExtendString` 与 `Partials` 两套 AND/OR/NOT 重复」是同一组符号的两侧：那边删 `ExtendString` 的一套，这边删 `Partials` 的一套，只保留 `operator ()` / `append(String)`（它们才是 `ExtendString` 真正用到的入口）。

### [轻微][存量] §2 重复逻辑：`arg`/`add` 各 40 个同形重载、`singleFirst|singleList` 的 index/column 两套、`first|list|one` 的 `isSimpleData` 三分支、两个 JSON converter 的取值块

- **位置**：`f_orm/src/base/RootDAO.cj:39-238`（40 个 `arg` 重载）与 `f_orm/src/base/SqlExecutor.cj:655-858`（40 个 `add` 重载）；`SqlExecutor.cj:475-518`；`SqlExecutor.cj:541-547`/`:566-572`/`:599-605`；`f_orm/src/base/QueryMapperConverter.cj:43-57` 与 `:60-81`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名 / 跨文件复制）
- **证据**：静态确定 —— `arg(?T)` 与 `add(?T)` 的函数体除类型名外逐行一致（`match Some/None`）；`singleFirst(index)`/`singleFirst(column)`（`:478-495`）、`singleList(index)`/`singleList(column)`（`:499-518`）是同语义两份；三个泛型入口的 `if (T.isSimpleData()) singleXxx else Xxx(T.queryMappers())` 完全同构。
- **描述**：真正的差异点只有「绑定的静态类型」与「取值是列下标还是列名」；当前每加一个可绑定类型要改 3~4 张表（见上「一般」里的漂移），`singleFirst/singleList` 的 index/column 分叉也多一次改动面。两个 converter 的 JSON 取值块 12 行完全重复，错误消息还都硬编码成 `'QueryMapperJsonConverter'`（`QueryMapperConverter.cj:54`/`:69`，后者的类名是 `QueryMapperWithTypeNameJsonConverter`，报错会指错类）。
- **建议**：`?T` 组用「`Option<T>` 到 `SqlArg` 的统一入口 + 一次 `add` 调用」替代（`SqlArg.new` 已按运行期类型分派）；`singleFirst/singleList` 合并成 `fetch<T>(selector: Int64|String)`；converter 的「取 JSON 文本」抽成一个私有函数，错误消息用 `TypeInfo.of(this)`。合并前先确认 `arg` 的 40 个重载是否被下游按位置依赖（`arg<T>(?T)` 泛型化会改变重载解析结果），这一点建议单独排期，不要顺手改。

### [轻微][存量] 并发小疵：`SqlFunc.h` 惰性哈希无同步；`QueryMapperConverter.lookup` 在 `computeIfAbsent` 内跑反射与 bean 查找

- **位置**：`f_orm/src/base/RootDAO.cj:576-586`（`private var h` + `hashCode()` 懒算）；`f_orm/src/base/QueryMapperConverter.cj:26-39`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（惰性初始化 / 锁内调用外部代码）
- **证据**：静态确定（代码形态）+ 待确认（是否真被多线程共享）——
  - `SqlFunc` 的 `h` 是非原子的「读-算-写」记忆，两个线程同时 `hashCode()` 会重复计算（结果相同、幂等），在 64 位平台不会撕裂；风险仅在于 `Columns` 之类的共享单例把同一个 `SqlFunc` 暴露给多线程（第 1/8 部分已记录 `Columns` 单例被跨线程使用）。
  - `lookup` 在 `ConcurrentHashMap.computeIfAbsent` 的映射函数里做 `lookupOption`/`lookupList`（bean 注册表）与 `ClassTypeInfo.construct`（反射构造）；若某个 converter 的构造器又调 `lookup`（同段）则可能自锁。仓内两个 converter 都没有构造逻辑，当前不触发。
- **建议**：`SqlFunc.h` 改成「构造期算一次」或使用原子；`lookup` 改成「先 `get`，miss 则构造后用 `addIfAbsent` 发布」（避免在 map 的映射函数里跑外部代码）。

### [轻微][存量] 可读性：`doMap` 用 `while + return` 表达 `if`；`groupedList` 缺 id mapper 时抛无信息的 `NoneValueException`

- **位置**：`f_orm/src/base/QueryMappers.cj:70-75`、`:94`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性 / 错误信息）
- **证据**：静态确定 —— `while (result.next()) { return map(result) }` 与 `if` 等价；`(this.idMapper.getOrThrow() as IdQueryMapper<ID, O>).getOrThrow()` 在「有 grouped mapper 但没有 id mapper」时抛 std 的 `NoneValueException`（无消息、无列名）。
- **建议**：`doMap` 改成 `if (result.next()) { Some(map(result)) } else { None }`；`groupedList` 在 `idMapper.isNone()` 时抛 `ORMException('grouped mapping requires an id mapper on ${TypeInfo.of<O>()}')`，并把 ID 类型不匹配（`:94` 的 `as` 失败）也换成带类型名的异常。

### [轻微][存量] 测试夹具质量：`QueryResult_test.cj` 的取值逻辑没有被任何用例读到；`QueryResultTest.getOrNull` 用 `match(None<T>)` 做类型分派，语义脆弱

- **位置**：`f_orm/src/base/QueryResult_test.cj:18-90`（`:71-89` `getOrNull`）、唯一使用点 `f_orm/src/base/Statement_test.cj:25`/`:37` → `f_orm/src/base/Connection_test.cj:33`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用 / 仅作占位）、§10（可测试性）
- **证据**：静态确定 —— `StatementTest` 只在 `Connection_test` 里被当作 `prepareStatement` 的返回值构造，`query()` 返回的 `QueryResultTest` 没有被 `next()`/`get()` 消费；因此 `QueryResultTest` 里 `next()`/`next(values)`/`getOrNull` 的计数与类型分派逻辑实际未被任何断言覆盖（它的 `match (None<T>) { case _: Int64 => … }` 与 `QueryResultWrap.cj:111` 是同一套脆弱写法，真正需要护栏的正是后者）。
- **建议**：要么给 `QueryResultTest` 补一个直接消费它的用例（覆盖 `get<T>` 的各类型分支与「行数用尽」），要么删掉这段未被覆盖的分派、只保留 `next()==false` 的最小替身；`SqlExecutorArgBranches_test.cj` 已经证明「用 mock 驱动 + 捕获参数」比这套夹具更可靠。

## 优化可行性方案

> 本部分未提供 bench / profile 数据（`scope.md`「已有性能资料」为空），下列方案**全部为无基线**，不进 `todo.md` / `tasks.md`，只作为下一轮补数据的对象。

### [堆内存] 结果缓存的容量与键成本

- **现状**：`SqlExecutor.cache: Map<SqlCacheKey, Any>` 无上限（`SqlExecutor.cj:54`），事务内每条不同「SQL + 参数」保留一份完整结果（`ArrayList<O>`、`HashMap`、含 `InputStream` 的结果已排除）；键为 `sql` + 参数哈希，`Array<Byte>` 参数在建键时被整体 `toString()`（每 MB 约 2~3 MB 临时串）。非事务路径写入后立即 `clear()`，命中率为 0。
- **方案**：① 非事务不建键（`tx.isSome()` 才走缓存分支）；② 给 `cache` 加容量上限 + LRU（可复用 `f_cache.HeapCache`，`maxSize` 按 PO 结果大小估）；③ `ByteArraySqlArg.hashCode` 改为「长度 + 首 32 字节 + 末 32 字节」。
- **预期**：非事务 SELECT 少一次键构造与一次 `HashMap` 读写；含 BLOB 参数的 SELECT 峰值临时内存从 `O(参数字节 × 2~3)` 降到常量级；长事务缓存占用有界。
- **代价**：②引入淘汰后「同 SQL 重复读」可能 miss（语义变差但不会错）；③哈希碰撞率上升，只会多 miss，不会误命中。
- **验证**：`cjprof heap` + `getAllocatedHeapSize()`，场景「10 万次 `select ... where id = ?`（含 1 MB BLOB 参数 100 次）」与「单事务 1 万条不同 SQL」，对照改前/改后峰值与 RSS；缓存命中计数埋点需同时给出。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `QueryMapperConverter` 的 CLOB 物化

- **现状**：`readToEnd()` + `JsonValue.fromStr` 两步各持一份完整副本，无上限（`QueryMapperConverter.cj:52`、`:67`）。
- **方案**：加 `orm_converter_maxBytes`（默认 8 MB）在读取前/读取中拒绝；若 `JsonValue` 支持流式解析则改流式。
- **预期**：单行最坏峰值从「数百 MB」降到「上限 × 常数」；超限从 OOM 变成可诊断的 `ORMException`。
- **代价**：大 JSON 列需要调大配置或改用手写 mapper。
- **验证**：构造 1/8/64 MB 三档 CLOB，测 `getAllocatedHeapSize()` 峰值与 `RSS`；断言超限路径抛 `ORMException`。
- **证据状态**：`无基线（待验证）`

### [CPU] `waitConnecting` 自旋

- **现状**：`Connecting` 期间纯忙等，单线程 100% 占核至 `orm_connectingTimeout`（默认 5s）。
- **方案**：`sleep(1ms)` 起步、指数退避到 `10ms`；或直接依赖驱动的连接超时。
- **预期**：卡连期间 CPU 占用从 1 核降到近 0，超时精度损失 ≤ 10ms。
- **代价**：连接就绪的感知延迟最多 +10ms（仅首次建连）。
- **验证**：用 `SqlExecutorConnectingTimeout_test` 的 `StuckDriver` 跑 10 线程，采 `top`/`cjprof` 的 CPU 时间与总耗时，断言耗时仍在 40~200ms 区间。
- **证据状态**：`无基线（待验证）`

### [CPU] 迭代器每行一次 `isClosed()`

- **现状**：`QueryResultIterator.next()`（`QueryResultIterator.cj:77-80`）与 `SingleColumnIterator.next()`（`:101-104`）每行都调 `isClosed()`，后者又会穿透到 `QueryResultWrap.isClosed()` → 驱动的 `result.isClosed()`（`QueryResultWrap.cj:1035-1037`）；即**每行一次驱动调用**。
- **方案**：`next()` 只用本地 `closed_` 判断（`isClosed()` 保留给外部 API）；驱动侧关闭由 `result.next()` 的 `false` 或异常体现。
- **预期**：每行省一次跨 FFI 调用；10 万行结果集约省 10 万次驱动调用（单次开销待测）。
- **代价**：外部在迭代器被驱动侧关闭时提前感知的能力变弱（仍会在 `next()` 抛错或返回 false 时体现）。
- **验证**：mock 驱动计 `isClosed` 调用次数（应为 1 次而非 N 次）+ `cjpm bench -O2` 前后对照（10 万行 `singleIterator<Int64>`）。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每条 SELECT 的 `SqlCacheKey` 构造（含参数逐个哈希、`Array<Byte>` 整体 `toString`）在短查询里占比可观 | `SqlExecutor.cj:905-906`、`wrap/SqlArg.cj:513-515` | 建键自耗时占比；含/不含 BLOB 参数的分配量 | `cjprof record` 跑 10 万次 `where id = ?`；另一组把参数换成 1 MB `Array<Byte>`，比 `getAllocatedHeapSize()` |
| 2 | `blankRegex.replaceAll` 每条 `setSql` 一次全串正则替换是固定开销 | `SqlExecutor.cj:76`、`:43` | 单次耗时、SQL 长度分布 | 20 列 × 10 万次 `setSql`，分段计时 + `cjprof` 看 `Regex.replaceAll` self time |
| 3 | `QueryResultWrap.getOrNull` 的逐列 `match` + `list[index]`（每个单元格一次）是映射主路径热点 | `wrap/QueryResultWrap.cj:94-984`（本部分经 `QueryMappers.map`/`SingleColumnIterator` 调用） | 每行/每列自耗时占比 | 10 万行 × 20 列 `list<T>()`，`cjprof` 看 `getOrNull` 与 `TypeInfo` 检查占比 |
| 4 | 迭代器每行一次 `result.isClosed()` 的驱动调用（见优化方案 [CPU]） | `QueryResultIterator.cj:78`、`:102` | 每行额外耗时 | mock 驱动计调用次数 + `cjpm bench -O2` 前后对照 |
| 5 | 事务内无上限结果缓存在长事务里把峰值堆显著抬高 | `SqlExecutor.cj:54`、`:916` | 单事务 1 万条不同 SQL 的 `usedHeap` 峰值 | 压测 harness 跑单事务 1 万条不同 SELECT，采 `getUsedHeapSize()` / `RSS` / `cache.size` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/Pagination.cj` | .cj | ✅ | 见「严重」无、「一般」9/10（`size<=0` 除零、`tryFromData` 恒失败） |
| 2 | `f_orm/src/base/Partials.cj` | .cj | ✅ | 见「轻微」1（8 个死函数）；`toString`/`clear`/`append(String)`/`operator ()` 均有用 |
| 3 | `f_orm/src/base/QueryMapper.cj` | .cj | ✅ | 见「严重」2（`new<T>` 是降级根源）、「轻微」1（未用 import）；`get`/`populate`/`protected` 成员均有用或属 `public open` 扩展点 |
| 4 | `f_orm/src/base/QueryMapperConverter.cj` | .cj | ✅ | 见「严重」7 的关联、「一般」8（`readToEnd`）、「轻微」2（两处 JSON 取值复制 + 错误消息硬编码）、「轻微」3（`computeIfAbsent` 内跑反射） |
| 5 | `f_orm/src/base/QueryMappers.cj` | .cj | ✅ | 见「严重」1/2（继承合并）、「轻微」4（`doMap` / `groupedList` 异常信息）；`groupedList` 仓内无调用（public，按硬原则一不判死代码） |
| 6 | `f_orm/src/base/QueryMappersInit.cj` | .cj | ✅ | 与 README `:1364-1381` 逐项一致（`isSimpleData→true`、`tableName→''`、`queryMappers→抛` 均已文档化）；无缺陷 |
| 7 | `f_orm/src/base/QueryResultIterator.cj` | .cj | ✅ | 见「严重」4（NULL 当结束）、优化方案 [CPU]（每行 `isClosed`）；资源关闭顺序与注释一致 |
| 8 | `f_orm/src/base/QueryResultIterator_test.cj` | .cj | ✅ | 5 个用例覆盖读尽关闭 / 事务内关闭 / 活动结果集阻塞 / `try`-with-resources / 按列名取值；缺「NULL 值」用例（见「严重」4 建议） |
| 9 | `f_orm/src/base/QueryResult_test.cj` | .cj | ✅ | 见「轻微」5（取值逻辑无用例覆盖） |
| 10 | `f_orm/src/base/RootDAO.cj` | .cj | ✅ | 见「严重」无、「一般」6/7（`Data`/`DataReal` 绑定、分派表漂移）、「轻微」1/2/3（`SqlFunc.init` 死代码、重载重复、`SqlFunc.h` 无同步） |
| 11 | `f_orm/src/base/RootService.cj` | .cj | ✅ | `executor(name)/executor()/dao<T>(driver)/dao<T>()` 四个默认方法；与 `ORM.executor` 的 `hasDefault()` 语义一致，无缺陷（`dao` 的 `as` 失败有明确 `ORMException`） |
| 12 | `f_orm/src/base/SqlDSL.cj` | .cj | ✅ | 见「严重」5（数据路径解析）、「严重」6（`Iterable` 占位符）、「一般」7（`DataReal` 文本绑定）；`dslcache` 为 `HeapCache`（`ConcHashMap`，线程安全、上限 10000） |
| 13 | `f_orm/src/base/SqlExecutor.cj` | .cj | ✅ | 见「严重」3/7、「一般」1/2/3/4/5/6、「轻微」1/2/3、优化方案 3 条；与第 2/8 部分交叉的 `DirtyTag.setBeforeDirty/clearAll` 已在那边记录，本部分不重复计数 |
| 14 | `f_orm/src/base/SqlExecutorArgBranches_test.cj` | .cj | ✅ | 用 mock 驱动捕获参数、逐类型断言「不落 `toString` 兜底」，质量好；`?:` 断言只覆盖 21 个类型（注释 `:47-50` 已说明 BigInt/Decimal/Float16 靠机械核对），未覆盖 `?InputStream`/`Data`（正对应「一般」6 的漂移） |
| 15 | `f_orm/src/base/SqlExecutorConnectingTimeout_test.cj` | .cj | ✅ | 用 `StuckDriver` 钉住 `Connecting` 超时（`<driver>_orm_connectingTimeout=50`）；未断言 CPU 占用（见优化方案 [CPU] `waitConnecting`） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性：严重 1/3/4/5/6/7、一般 1/5/9/10；设计：`Pagination` 构造函数里做查询（`Pagination.cj:49-53`，未单列，与严重 1 的「合并路径」同层）；语言特性：`as`/`getOrThrow` 的 `Option` 语义逐个核对过（`class.md:370`、`function/define_functions.md:86-111` 的返回类型推断已现场查文档确认）；可读性：轻微 4；安全性：一般 3（日志泄露参数） |
| §1 死代码 | 1（10 个符号） | 逐符号机械过：`Partials` 8 个（protected class，无豁免）、`SqlFunc.init(String,String)`（internal，全仓 0 调用）、`SqlExecutor.add(all:)`（protected，非 open 类）、`QueryMapper.cj` 未用 import 组。`protected` 成员逐个判定：`QueryMapper`/`FieldQueryMapper` 是 `public open`（豁免，且都被用），`QueryMappers.idName`（public 非 open 类）被 `TableClause.cj:283-299` 使用，`AbstractQueryResultIterator` 是 `public abstract`（豁免）。对外可达的 public 只记「仓内无引用」不作问题：`QueryMappers.groupedList`、`QueryMapperWithTypeNameJsonConverter.toJson`、`QueryMapperJsonConverter` / `QueryMapperWithTypeNameJsonConverter` 两个内置转换器、`Pagination` 全量 API |
| §2 重复逻辑 | 2 | 见「轻微」2 与「一般」6：逐对比较了 `arg(?T)`×40 / `add(?T)`×40（仅类型名不同）、`singleFirst|singleList` 的 index/column、`first|list|one` 的 `isSimpleData` 三分支、两个 JSON converter 的 12 行取值块、`RootDAO.arg(Any)`/`arg<I,T>`/`add<T>`/`add(Any)` 四张分派表（已漂移）；`meet` 8 个重载与 `SqlFunc` 6 个聚合函数差异是业务语义，不判重复 |
| §3 空实现 | 1 | `Pagination.dataFields` 的 creator 抛异常（「一般」10）。其余空实现均为有意的 Null Object / 文档化默认（`SimpleDataQueryMappersInit.tableName→''`、`QueryMappersInit.queryMappers→抛`，README `:1371` 已写明）；无 `catch {}` 静默吞异常（`SqlExecutor` 的 `catch` 都带 `logger.warn/error`，`QueryResultIterator` 的 `catch` 只吞关语句失败并有注释） |
| §4 栈溢出 | 0 | 唯一的自递归是 `SqlExecutor.connection`（`SqlExecutor.cj:428-430`）：`getConnection` → `ORM.connection` → `NamedDatasource.connect` 必然返回 `ConnectionWrap`（`wrap/NamedDatasource.cj:47-49`），不会停在 `NoneConnection`，因此递归深度 1 即终止；`as`/`getOrThrow` 链无递归。提示：若下游把 `ORM.connection` 改成可能返回 `NoneConnection`，该处会变成无出口递归 |
| §5 OOM | 2 | 一般 2（缓存无上限）、一般 8（`readToEnd` 全量物化）；`Parser/list` 的全量物化是 API 语义（有 `iterator` 可流式），不判；`Pagination` 的 `list` 大小由「每页 size」决定，不构成无界增长 |
| §6.1 热点瓶颈 | 0 | 本轮无 bench / profile（`scope.md` 明确未提供），所有疑似热点写入「待验证假设」5 条，不写成结论 |
| §6.2 大粒度锁 | 0 | `SqlExecutor` 无线程锁（状态全在 `ThreadLocal` 的 executor 实例上）；唯一的「锁内跑外部代码」在 `QueryMapperConverter.lookup` 的 `ConcurrentHashMap.computeIfAbsent`，已记「轻微」3 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future.get`；每条语句一个连接，无批内串行化 |
| §6.4 低效算法 | 2 | 一般 11（`waitConnecting` 忙等，静态确定的 CPU 空转）、一般 2 的建键开销（无数据，主结论放待验证假设 #1）；其余（`groupedList` 用 `LinkedHashMap` 去重、`QueryMappers.map` 逐列遍历）都是 O(行×列) 的必要工作 |
| §7 降堆内存方案 | 2 | 优化方案 [堆内存]×2（缓存容量/键成本、CLOB 物化），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 [CPU]×2（`waitConnecting` 自旋、每行 `isClosed`），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内释放的大临时对象」：`SqlDSL.compile` 的产物进全局 `HeapCache`（逃逸），`QueryResultWrap` 的逐行 `ArrayList` 挂在 result 上（逃逸到调用方），`QueryMappers.map` 的对象返回给调用方（逃逸）；`Pagination`/`list` 的结果必须返回，`exclave` 也只能搬运不计收益。无前后峰值数据前不给结论 |
| §11 现有代码的 BUG（存量） | 20 | 严重 7 + 一般 11 + 轻微 4（含死代码/重复/并发小疵/夹具），全部标「存量（快照模式无基线）」；本部分读到的边界/空值/资源/并发路径逐条核对过（见各条证据） |
| §12 并发安全与锁粒度 | 3 | 安全前提已逐条论证：`SqlExecutor` 的 `sql_`/`args`/`stmt`/`tx`/`cache`/`partials`/`activeQueryResult` 全部挂在「每线程一份」的实例上（`currents`/`current` 是 `ThreadLocal`，`close()` 从 `currents` 移除）；`SqlDSL.dslcache` 是 `HeapCache`（`ConcHashMap` 分段锁 + 上限）；`QueryMapperConverter.converters` 是 `ConcurrentHashMap`。命中的三条：轻微 3（`SqlFunc.h` 无同步、`computeIfAbsent` 内跑反射）、一般 5（事务中换连接）、一般 6 的「静默退化」不涉并发。锁粒度上无可优化对象（本部分没有本模块自建的锁） |
| §14 功能完备性与 README 覆盖 | 3 | ①`:{...}` 数据路径（README `:822-827`，见严重 5）；②继承合并父类 mapper（README `:1392`/`:1735`，见严重 1/2）；③`Pagination` 与 `Data` 互转（README `:1346`，见一般 10）。另记「README 把结果缓存的类型不符抛错写成设计」（`:393`，见一般 1），属文档与可用性冲突，不单列 |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个 `.cj` 全部读完，无 `.md`；README 作为契约源读过 §3.1、§8、§12、§13.1-13.3、§14 相关行（不占用本部分文件清单） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 7 |
| 一般 | 11 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是全模块的「执行器 + 映射」核心，代码质量呈现明显的两极：

**好的一面**：资源所有权与关闭顺序（迭代器持 `QueryResult`/`Statement`、`releaseActiveQueryResult`、`activeQueryResult` 互斥）设计清楚且有针对性用例钉住；`SqlArg` 体系的「绑定即校验、不静默丢参」方向正确（ORM-N2 的教训已落到 `setValue` 的 throw 上）；注释密度高，多数「为什么这样写」都能对上代码。

**风险集中在三条主线**：

1. **继承映射（严重 1/2）** —— `QueryMappers.create` 一个函数里同时有下标差一与 mapper 降级两个缺陷，叠加后「PO 继承映射」这条 README 明确承诺的能力完全不可用，且失败形态可能是静默丢字段。虽然仓内现有 PO 都不继承，但这是对外 API，下游一用就中，建议列为**阻塞项**（改动小、收益明确：两行 + 一个 `rebind`）。
2. **SQL 文本与参数的拼装（严重 3/5/6、一般 6/7）** —— `sql` setter 的全局空白折叠会改写字面量（静默错数据）；DSL 的数据路径解析与 `Iterable` 展开两处都是「读一遍代码就能看出」的逻辑错，任何按 README §8 使用模板 SQL 的下游都会失败。这三条互相独立、修复都很局部，建议一起修并补逐字节断言的用例（`ArgSqlText_test.cj` 已有可复用的框架）。
3. **结果缓存（严重 7、一般 1/2）** —— 键缺「流参数内容」与「结果类型」、非事务路径命中率为 0 却照付建键开销、容器无上限。当前缓存既可能返回别人的数据，又基本不产生收益，建议在修完键的两处缺陷后再决定是「只服务事务内」还是「做成真正的跨语句缓存」——这是设计取舍，需要拍板，不适合顺手改。

其余（`Pagination` 边界与反序列化承诺、日志泄露参数、`readOnly` 标记、事务中换连接、分派表漂移、`waitConnecting` 自旋、10 个死符号）都是可排期的中等/轻微项，单条修复面都在 10 行以内。

**存量说明**：本部分 23 条发现全部为存量（快照模式无基线可比），是否纳入修复待用户决定；与第 2/8 部分同源的 `DirtyTag` 结论与 5 个 `newXxx` 死代码不在此重复计数。
