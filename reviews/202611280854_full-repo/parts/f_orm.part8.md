# f_orm 模块审查报告（模块第 8/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 `f_orm/src/wrap` 下 7 个文件：5 个 `.cj` 实现 + 2 个 `.cj` 测试；本部分无 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支）；`git blame` 可查（见各条「来源」）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件是模块分报告，最终模块报告由主 Agent 合并 `parts/*.md` 生成）

## 发现

### [严重][存量] `InputStreamSqlArg` 的 `==` / `hashCode` 完全忽略流内容，导致「同一 SQL + 不同流参数」命中同一条结果缓存

- **位置**：`f_orm/src/wrap/SqlArg.cj:456-461`（`==`）、`f_orm/src/wrap/SqlArg.cj:450-455`（`hashCode`）；缓存键构造在 `f_orm/src/base/SqlExecutor.cj:905-906`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02；快照模式无基线可比）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §12.1（缓存键语义）
- **证据**：静态确定 —— `hashCode` 只用 `index` + `TypeInfo.of<InputStream>()` + 常量串 `'std.io.InputStream'`；`==` 在 `equals(other)`（同 index、同类、同 hash）成立后直接 `case x: InputStreamSqlArg => true`。两个内容完全不同的 `InputStream`，只要绑定位置相同，哈希相同、`==` 为 true
- **描述**：`SqlExecutor.execute<T>` 的缓存分支条件是 `useCache && !clearCache && isSelectStatement(sql)`（`SqlExecutor.cj:905`），`useCache` 默认 `true`（`SqlExecutor.cj:62`）；规避缓存的唯一措施是「结果里交出过流」（`lastResultHadStream`，`SqlExecutor.cj:915`、`978`），**只看结果方向、不看参数方向**。于是「参数是流、结果是标量」的 SELECT（如 `select id from attachment where digest = ?`，`RootDAO.arg(InputStream)` → `SqlArgs.add(InputStream)`）在**同一事务内**（`tx.isSome()` 时 `exec()` 不 close，缓存不清）连续执行两次、换一条内容不同的流，第二次直接命中第一次的结果 —— 返回上一次的行，属数据错误。可达性还有一条旁路：`_connection_` 已为 `NoneConnection` 时 `SqlExecutor.close()` 的 `!isClosed()` 短路会让缓存**不被清空**（`NoneConnection.isClosed()` 恒 `true`，`NoneConnection.cj:39-41`；`close()` 见 `SqlExecutor.cj:154-157`），executor 也留在 `currents` 线程表中继续复用
- **建议**：`InputStreamSqlArg` 的 `hashCode`/`==` 必须能区分实例（至少用 `refEq`，或按流身份生成单调 id）；更稳妥的做法是给 `SqlArg` 增加「是否可缓存（cacheable）」标记，`InputStreamSqlArg` 返回不可缓存，`SqlExecutor.execute` 在构造 key 前检查（与 `lastResultHadStream` 对称）。补一条用例：同一 executor 内两次不同流的同 SQL 查询必须各自执行

### [一般][存量] `SqlArgs` 即可变、又被 `SqlCacheKey` 直接持有，且 `==` 用 `refEq` 短路 —— 缓存键的「对象身份」被当成「参数内容相等」

- **位置**：`f_orm/src/wrap/SqlArgs.cj:120-122`（`refEq` 短路）、`f_orm/src/wrap/SqlArgs.cj:31-37`（`add` 复位 `h`）、`f_orm/src/wrap/SqlArgs.cj:109-119`（`h` 记忆化）；键持有参数见 `f_orm/src/base/SqlExecutor.cj:25-38`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §11（并发/语义）+ §1（hash/equals 契约一致性）；`SqlArgs` 的注释 `SqlArgs.cj:33-35`、`SqlExecutor.cj:100-103` 已记录同类历史缺陷 ORM-1
- **证据**：静态确定（不变量层面）；是否会产出**用户可见的错误结果**为待确认 —— 需要「同一 SQL 文本 + 复用同一 `SqlArgs` 实例 + 参数内容不同」三条件同时成立
- **描述**：ORM-1 的修法是「执行后换新 `SqlArgs` 实例」（`clearSql` → `this.args = SqlArgs()`，`SqlExecutor.cj:104`），但 `setSql(sql, clearArgsAfterExec=false)` 是公开参数，仓内 `f_orm/src/base/SqlPartial.cj:295`、`298` 正在使用它。这条路径下：①同一实例被连续两次当作键，`refEq` 让内容不同的参数判等（ORM-1 复活）；②`SqlCacheKey.h` 在构造时固化（`SqlExecutor.cj:27-32`），而 `SqlArgs.add` 会把 `SqlArgs.h` 置 0 重算，于是**已入表**的键 `hashCode()` 漂移、`HashMap` 里再也找不到自己（条目悬挂，直到 `cache.clear()`）。`page()` 路径因两条 SQL 文本不同未触发①，但②在每次 `page()` 都会留下悬挂条目
- **建议**：`SqlArgs` 改为「写入期可变、入键前冻结」：`SqlCacheKey` 构造时把参数压成不可变快照（`(index, TypeInfo, value)` 的紧凑数组或参数哈希 + 长度），不要持有 `SqlArgs` 实例；`==` 去掉 `refEq` 短路，或保证只有冻结实例能进缓存

### [一般][存量] 绑定参数原文（含凭据与整块 BLOB）被拼进 debug 日志与异常消息

- **位置**：`f_orm/src/wrap/SqlArg.cj:60-62`（`toString<T>(value)` 输出 `${value}`）、`f_orm/src/wrap/SqlArg.cj:513-515`（`ByteArraySqlArg.toString` 输出整个字节数组）、`f_orm/src/wrap/SqlArgs.cj:105-107`；消费方 `f_orm/src/base/SqlExecutor.cj:432-442`（`logMsg`）、`f_orm/src/base/SqlExecutor.cj:36-38`（`SqlCacheKey.toString`）、`f_orm/src/base/SqlExecutor.cj:909`（把 `key` 插进 `ORMException` 消息）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §10（敏感数据进日志）+ §5（按不可信长度做字符串化）+ `fountain-baseline.md` §6（日志中不得出现凭据、完整报文）
- **证据**：静态确定（构造路径）；实际暴露面为待确认 —— 需确认生产是否开 DEBUG
- **描述**：每次执行 SQL 都会 `logger.debug(logMsg(...))`（`SqlExecutor.cj:936`），闭包插值 `${args}` 逐参数调 `SqlArg.toString`，`String`/`Decimal`/`DateTime`/`Array<Byte>` 全部按原文输出。后果两条：①口令、令牌、身份证等以参数形式出现的敏感值进入日志文件；②BLOB 参数被整体格式化成字符串（`Array<Byte>.toString` 形如 `[1, 2, 3]`，见 std 文档 `core_package_structs.md:2760` 的输出样例），一个 10 MB 的 BLOB 在日志字符串里约放大到 40 MB 字符量级，且与 `SqlCacheKey.toString` 的异常消息共用同一路径
- **建议**：把「日志用」与「诊断用」的 `toString` 分开：日志侧只输出 `index + 类型 + 长度/摘要`（`InputStreamSqlArg` 已经是这种写法，`SqlArg.cj:447-449`，可作为范式）；确需原文时按 `orm_logArgs` 之类开关显式开启，并对 `Array<Byte>` 走长度 + 前缀哈希

### [轻微][存量] `SqlArg` 各子类 `==` 里 14 处跨类型比较分支永不可达

- **位置**：`f_orm/src/wrap/SqlArg.cj:283-285`（`Float16SqlArg`）、`309`、`311-312`（`Float32SqlArg`）、`333-334`、`336`（`Float64SqlArg`）、`357-359`（`DecimalSqlArg`）、`403`（`RuneSqlArg`）、`424`（`StringSqlArg`）；根因 `f_orm/src/wrap/SqlArg.cj:70-73`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（恒假分支）+ §2（重复逻辑导致的行为漂移）
- **证据**：静态确定 —— `equals(other)` 要求 `ClassTypeInfo.of(this) == ClassTypeInfo.of(other)`，`Float16SqlArg` 与 `Float32SqlArg` 的运行时类不同，`equals` 必为 `false`，`&&` 之后的跨类型 `case` 永不执行
- **描述**：代码想表达「数值型参数按数值相等、`Rune` 与 `String` 按字符相等」，实际只实现了「同类同值」。这 14 个分支既误导读者（以为跨类型相等成立），也让「`Float16(1.5)` 与 `Float32(1.5)` 是否同一参数」的答案依赖不可达代码。当前唯一消费者是缓存键与测试，所以后果仅限语义含糊
- **建议**：二选一 —— 要么删掉跨类型分支、把「严格同类型相等」写进注释与 README；要么把 `equals` 改成「先比 `index`，再按数值域比较」，并让各子类 `hashCode` 统一到数值域（注意 `Float16→Float32` 的绑定约定会让「相等但绑定类型不同」自相矛盾）

### [轻微][存量] 三张并行的「参数类型分派表」重复且已漂移：`SqlArg.new` / `SqlArgs.add` 20 个重载 / `SqlExecutor.add<T>` 38 个分支

- **位置**：`f_orm/src/wrap/SqlArg.cj:34-58`（19 个 `case`）、`f_orm/src/wrap/SqlArgs.cj:38-100`（20 个 `add` 重载，每个都是 `add(XxxSqlArg(args.size, arg))`）、`f_orm/src/base/SqlExecutor.cj:610-654`（38 个 `case`）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §2（只改类型名 / 字面量表复制）+ §14.1（接线缺失导致的漂移）
- **证据**：静态确定 —— 新增一种参数类型要同时改三处；`SqlArg.new` 对未知类型 `throw SqlArgException`（`SqlArg.cj:56`），而 `SqlExecutor.add<T>` 的兜底是 `case x => add(x.toString())`（`SqlExecutor.cj:652`）**静默转字符串**。同一概念（「这个值能不能当参数」）两条路径结论相反：`SqlArg.new(0, someCustomObj)` 抛异常，`executor.add(someCustomObj)` 存成字符串
- **描述**：`SqlArg.new` 仓内零引用（见下一条），等于一张无人维护的表；`SqlArgs.add` 的 20 个重载纯机械重复（`SqlArg.cj` 20 个子类也几乎逐行相同，仅类型名不同，其中 `Float16→Float32` 加宽、`BigInt→String` 转换、`InputStream` 忽略值、`Array<Byte>` 走字符串哈希是四处真实差异）。这类「改一处漏一处」的结构正是 `Float16` 静默丢参（ORM-N2）能存活的原因
- **建议**：把「类型 → SqlArg」收敛为一处（例如以 `SqlArg.new` 为唯一工厂，`SqlArgs.add<T>` 只做 `add(SqlArg.new<T>(args.size, arg))`，`SqlExecutor.add<T>` 只做可空拆包）；未知类型的处理口径统一（建议统一抛 `SqlArgException`，若要保留 `toString` 兜底必须写进 README）。合并前把四处差异显式列出，避免把 `Float16` 加宽等约定改掉

### [轻微][存量] 死代码：`ByteSqlArg` 类型别名、`SqlArgs` 的 protected 主构造、`SqlArgs.add(all!)` 整条链

- **位置**：`f_orm/src/wrap/SqlArg.cj:139`；`f_orm/src/wrap/SqlArgs.cj:19`；`f_orm/src/wrap/SqlArgs.cj:101-104`（唯一调用者 `f_orm/src/base/SqlExecutor.cj:867-869`）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（`internal`/`protected` 无引用；`protected` 只有「`public open` / `public abstract` 非 `sealed` 类的成员」才豁免）
- **证据**：静态确定 —— 全仓搜 `ByteSqlArg` 只有定义处 1 处命中；搜 `SqlArgs` 无任何子类，`SqlArgs` 又是 `public class`（非 `open`），其 `protected` 构造在本模块外不可继承、模块内无 `super(...)` 调用；搜 `add(all:` 在 `f_orm` 内只有 `SqlArgs.cj:102` 与 `SqlExecutor.cj:868`，而 `SqlExecutor.add(all!: SqlExecutor)` 自身零调用者（`exe.add(otherExe)` 会落到 `add(arg: Any)` 并抛 `SqlException`），整条链不可达
- **描述**：`ByteSqlArg` 是 `Byte`→`UInt8` 时代的兼容残留；`SqlArgs(args)` 主构造只剩「能被继承」这一个用途，而类不可继承。附带一个潜在缺陷：`add(all!: SqlArgs)` 直接把对方列表并入，**保留对方的 `index`**，若目标列表非空会出现重复 `index`（后者覆盖前者的绑定位置）—— 该缺陷随死链一起存在，复活前必须先修索引
- **建议**：删除三处；`add(all!)` 若确需保留，重排索引（`for (a in all.args) add(...)` 而不是 `args.add(all:)`）

### [轻微][存量] `imports.cj` 的 `std.ast.*` 在本包内零使用

- **位置**：`f_orm/src/wrap/imports.cj:18`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 在 `f_orm/src/wrap` 全包搜 `ast` 只有这一行；搜 `Token` / `Decl` / `Expr` / `Position` / `quote(` / `MacroContext` 均 0 命中。Cangjie 的 `import` 默认 `internal`（包内可见，见 `docs/dev-guide/source_en/class_and_interface/class.md:370-375` 对可见性层级的说明），所以这条 import 对整个 `f_orm.wrap` 包生效而非仅本文件
- **描述**：模块复制骨架时留下的无用依赖；`fountain::f_data.*` 与 `fountain::f_regex.*` 同样没有直接符号引用，但二者可能通过扩展成员（`Regex` 扩展、`@Data` 宏）生效，**未确认前不算死代码**
- **建议**：删除 `std.ast.*`；`f_data` / `f_regex` 用编译器 unused-import 诊断或逐个摘除试验确认后再删

### [轻微][存量] `TransactionWrap.setIsoLevel` / `setAccessMode` / `setDeferrableMode` 与同名 mut prop 完全重复，仓内零引用

- **位置**：`f_orm/src/wrap/TransactionWrap.cj:32-35`、`44-47`、`56-59`；对应 prop 在 `36-43`、`48-55`、`60-67`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §2（同一写操作的两种入口）+ §1 信息项
- **证据**：静态确定 —— 两套实现都只做 `transaction.xxx = value`，返回 `this` 与返回 `Unit` 是唯一差异；全仓搜 `setIsoLevel|setAccessMode|setDeferrableMode` 只有定义处命中，`SqlExecutor.createTransaction` 用的是 prop 赋值（`SqlExecutor.cj:274`、`277`、`280`）。`TransactionWrap` 是顶层 `public` 类，成员对外可达，**按硬原则一不算死代码**，只作 API 面重复
- **建议**：保留 prop（它与 `Transaction` 接口语义一致），把三个 `setXxx` 标注 `@Deprecated` 或直接删除；若要保留链式写法，至少让 `setXxx` 内部调用 prop setter，避免将来只改一处

### [轻微][存量] `StatementWrap` 让 `Statement` 接口的参数版 `update(params)` / `query(params)` 恒抛异常

- **位置**：`f_orm/src/wrap/StatementWrap.cj:38-43`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）+ §3（接口方法被实现成不可用）
- **证据**：待确认 —— 仓内没有任何代码通过 `Statement` 接口调用这两个方法（`f_orm` 内搜 `update(params)` / `query(params)` 只命中各驱动的实现与测试桩），所以当前不会崩；但 `ConnectionWrap.prepareStatement` 返回的就是 `StatementWrap`（`ConnectionWrap.cj:46`），任何按 `std.database.sql.Statement` 通用写法使用该语句的代码都会拿到 `ORMException`
- **描述**：README 第 2192 行已声明这是有意为之（「参数版直接抛 `ORMException('current access is deprecated')`」），因此不是「忘写实现」；问题是异常被抛在**具备该能力**的类型上，破坏了 `Statement` 的可替换性，且异常文案是英文短语而非可判定的错误码
- **建议**：把「不支持参数版」写进 `StatementWrap` 的类注释并改用专用异常类型（如 `UnsupportedOperationException` 语义的 `ORMException` 子类），或在包装层直接不实现 `Statement`、改用更窄的自有接口

### [轻微][存量] 两个测试的断言与夹具问题：`contains` 过宽导致 `Int8`/`UInt8` 不可区分；配置还原用 `set` 而非 `remove`

- **位置**：`f_orm/src/wrap/SqlArgBinding_test.cj:95-101`（`contains(expected)`），受影响的用例 `119-127`；`f_orm/src/wrap/QueryResultWrap_test.cj:168-189`（`Config.set` 还原）
- **来源**：存量（`git blame`：测试文件 `2026` 年版权头，属快照既有内容）
- **判据**：review-checklist §11（测试断言不成立 = 覆盖缺口）+ §1（机械检查）
- **证据**：静态确定 —— 记录串形如 `set<core.UInt8>(0)`，`'set<core.UInt8>(0)'.contains('Int8')` 为 `true`，所以 `check('Int8','Int8',…)` 在误绑 `UInt8` 时同样通过（`UInt16`/`Int16`、`UInt32`/`Int32`、`UInt64`/`Int64` 同理）；`Config.set` 是进程内全局表（`f_config/src/Config.cj:107-129`），`Config.remove` 才是「本来没有这个键」的正确还原（`Config.cj:130-139` 的注释明确写了这一点），用例却把键改成 `'true'` 留下残键
- **描述**：`expectOnce` 是本文件唯一的类型断言，它区分不了有/无符号，恰好放过了「窄类型绑错」这类历史缺陷（`ORM-N2`）；另外 `90` 行注释明说 `InputStream` 与 `Array<Byte>` **未覆盖**，而 `InputStreamSqlArg` 的等值缺陷（本报告第 1 条）正落在未覆盖区
- **建议**：`expectOnce` 改成精确比较完整类型名（`set<core.Int8>(0)` 全等），或直接解析出 `<>` 内的类型串做相等比较；配置还原改 `Config.remove(key)`；补 `InputStream` / `Array<Byte>` 的绑定与缓存键用例

## 优化可行性方案

### [堆内存] `SqlCacheKey` 持有整个 `SqlArgs`（含参数值与流引用），缓存条目钉住参数对象

- **现状**：每条缓存条目 = `SqlCacheKey(sql, args)` + 结果值。`args` 是执行期的 `SqlArgs` 实例，内部 `ArrayList<SqlArg>` 每个元素持有一个装箱值：`String` 参数整串、`Array<Byte>` 整块、`InputStream` 是**调用方的流对象**（`SqlArg.cj:441`）。生命周期：至少到下一次 `close()` 的 `cache.clear()`（`SqlExecutor.cj:157`），事务内跨语句一直存活
- **方案**：`SqlCacheKey` 只存 `sql` + 参数个数 + 参数哈希（现有 `h` 已够用），去掉 `args` 强引用；`==` 退化为「`sql` 相等 + `h` 相等」（哈希碰撞时按保守方式视为不同，宁可不命中）
- **预期**：每条缓存条目少持有 N 个 `SqlArg` 及其参数值（BLOB 场景单条即 N 字节级 → 命中期间常驻），事务内长查询序列的峰值可降；具体幅度未知
- **代价**：碰撞时退化为不命中（正确性不受损，只是缓存命中率略降）；`SqlCacheKey.toString` 失去参数明细，异常诊断信息变弱（可用参数个数 + 哈希替代）
- **验证**：同输入事务（20 条 SELECT，含 1 个 5 MB BLOB 参数）多轮跑，对比 `getAllocatedHeapSize()` / RSS 与 `cache.size`；`-O2`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 堆内存] `ByteArraySqlArg.hashCode` 走 `value.toString()` 全量字符串化

- **现状**：`f_orm/src/wrap/SqlArg.cj:516-518` 用 `hashCode<String>(value.toString())` 求哈希；`Array<Byte>.toString` 会生成 `[1, 2, 3]` 形态字符串（std 文档 `core_package_structs.md:2760`），一个 n 字节的 BLOB 约产生 4n 个字符 + 一次完整数组遍历，每次 SELECT 建缓存键都会走一遍（`SqlExecutor.cj:905-906`）
- **方案**：改为按块喂 `HashBuilder`（`for (b in value) hasher.append(b)` 或分块 `append(Array<Byte>)`），不再构造字符串；`toString` 只输出长度 + 前 16 字节摘要
- **预期**：BLOB 参数建键的分配量从 O(4n) 字符降到 O(1) 额外对象；单次哈希耗时从「格式化 + 哈希」降为「一遍哈希」
- **代价**：哈希分布变化 → 已存在的缓存条目失效一次（进程内缓存，无持久化影响）
- **验证**：固定 1 MB / 10 MB 两个尺寸，`cjpm bench -O2` 对比 `SqlCacheKey` 构造耗时与分配量；`cjprof record` 看 `HashMap` 建键路径占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次绑定都新建 `SqlArg` 对象（20 类 × 每参数 1 个）

- **现状**：`SqlArgs.add` 的每个重载都 `new XxxSqlArg(...)`（`SqlArgs.cj:38-100`）；一条 20 参数的 INSERT 每次执行分配 20 个 `SqlArg` + 20 个装箱值，`args` 换实例后全部成为垃圾（`SqlExecutor.cj:104`）
- **方案**：`SqlArgs` 内部改用「类型标签 + 值」的紧凑数组（`Array<Int64>` 索引 + `Array<Any>` 值 + 复用缓冲），`SqlArg` 降级为绑定视图；或在 executor 生命周期内复用 `SqlArgs` 的存储槽（配合本报告第 2 条的冻结语义）
- **预期**：每参数分配从 2 个对象降到 0～1 个；GC 压力与 `SqlArg` 构造开销下降
- **代价**：`SqlArg` 的 `protected` 扩展点与各子类语义要重新设计（对外 `SqlArg` 是 public 抽象类，属契约变更）；`index`/`TypeInfo` 语义必须保持
- **验证**：`cjpm bench -O2` 跑 10 万次 20 参数 INSERT 的绑定阶段（不连库，用 `RecordingStatement` 桩），对比耗时中位数、分配量、GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SqlCacheKey` 构造（含 `SqlArgs.hashCode`）在含大参数事务里占端到端 5% 以上 | `f_orm/src/base/SqlExecutor.cj:905-906` | 自耗时占比 + 参数规模 | `cjprof record` 跑「事务内 20 条 SELECT，1 个 10 MB BLOB 参数」，看建键路径 self time |
| 2 | 结果缓存命中率低于 30%，当前 `refEq` + 实例替换策略抵消了大部分收益 | `f_orm/src/base/SqlExecutor.cj:905-919` | 命中/未命中计数 | 在 `cache.get(key)` 两分支加计数埋点，跑 10 分钟稳态负载 |
| 3 | 生产开 DEBUG 时参数日志占日志量主要部分并抬高 RSS | `f_orm/src/base/SqlExecutor.cj:936` | 日志字节数 / 单条格式化耗时 | 打开 DEBUG 跑 1 万条带 1 KB 字符串参数的查询，测日志字节数与堆峰值 |
| 4 | 每次执行重建 `SqlArgs` 造成的分配在 ORM 侧分配量中占比可观 | `f_orm/src/wrap/SqlArgs.cj:19-22`、`SqlExecutor.cj:104` | 分配采样 | `cjprof heap` 对比 1 万次 20 参数绑定前后的分配直方图 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/wrap/QueryResultWrap_test.cj` | .cj | ✅ | 测试；夹具全局态与配置还原见「轻微 10」 |
| 2 | `f_orm/src/wrap/SqlArg.cj` | .cj | ✅ | 20 个 `SqlArg` 子类 + 基类；本报告 #1/#4/#5/#6 |
| 3 | `f_orm/src/wrap/SqlArgBinding_test.cj` | .cj | ✅ | 绑定出口契约用例；断言过宽见「轻微 10」 |
| 4 | `f_orm/src/wrap/SqlArgs.cj` | .cj | ✅ | 参数集合；本报告 #2/#6 |
| 5 | `f_orm/src/wrap/StatementWrap.cj` | .cj | ✅ | 索引基数偏移 + 参数版恒抛；见「轻微 9」 |
| 6 | `f_orm/src/wrap/TransactionWrap.cj` | .cj | ✅ | 事务包装；见「轻微 8」 |
| 7 | `f_orm/src/wrap/imports.cj` | .cj | ✅ | 包级 import 汇总；见「轻微 7」 |

合计：`.cj` 7 个 / `.md` 0 个 / 共 7 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`InputStreamSqlArg` 等值（#1）、`SqlArgs` 键语义（#2）；安全性：参数原文进日志（#3）；设计：三处分派表（#5）。语言特性已核对 `protected` = 模块内可见（`class.md:370-375`）、`TypeInfo.of(Any)` 取运行时类型（`reflect_package_classes.md:13524-13572`，故 `SqlArg.cj:30` 的诊断信息无缺陷）、`Array<T> ==` 为逐元素相等（`core_package_structs.md:2772-2790`） |
| §1 死代码 | 4 | 逐个 `private`/`internal`/`protected` 符号搜引用：`ByteSqlArg` 别名、`SqlArgs` protected 主构造、`SqlArgs.add(all!)` 链（其唯一调用者 `SqlExecutor.add(all!)` 也零调用）无引用 → 死代码；`std.ast.*` 未使用 → 死 import。`SqlArg` 为 `public abstract class`，其 `protected` 成员（`setValue`/`toString`/`hashCode`/`equals`/`index`/`h`）按扩展点豁免；`SqlArg.new`、`TransactionWrap.isDummy`/`setXxx` 虽仓内零引用但对外可达（硬原则一），只记信息 |
| §2 重复逻辑 | 2 | 三张类型分派表（#5）+ `TransactionWrap` 的 setXxx 与 mut prop（#8）；已逐个比对 `SqlArgs.add` 20 个重载（差异仅类型名）、`SqlArg` 20 个子类（差异为 `Float16→Float32`、`BigInt→String`、`ByteArray` 字符串哈希、`InputStream` 忽略值四处），并点名差异后给出合并建议 |
| §3 空实现 | 1 | `StatementWrap.update(params)`/`query(params)` 恒抛（计入 #9，语义为「不可用实现」而非空函数）；测试桩 `RecordingStatement.setOption` 空实现属测试专用、有注释，不计 |
| §4 栈溢出 | 0 | 本部分无递归：`SqlArgs.toString` → `ArrayList.toString` → `SqlArg.toString` → 值 `toString` 是单向有限的；`TransactionWrap.wrapping` 是单链（`tx.wrapping = this.tx` 后 `this.tx = tx`，无环，`SqlExecutor.cj:198-238`） |
| §5 OOM | 1 | BLOB 参数被 `Array<Byte>.toString` 全量字符串化（#3 描述），量级约 4n 字符；无按不可信长度预分配、无无界容器增长（`SqlArgs.args` 随 `add` 增长，但每条 SQL 执行后换实例 `SqlExecutor.cj:104`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，本部分未定位到任何自耗时占比；相关猜测已进「待验证假设」1-4 |
| §6.2 大粒度锁 | 0 | 本部分 7 个文件无 `synchronized` / `Mutex` / 锁对象；`SqlArgs.h` 是单实例记忆字段，无锁需求 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理 |
| §6.4 低效算法 | 0 | `SqlArgs.hashCode` 为 O(n) 但记忆化（每条语句一次）；`SqlArg.==` 先比缓存哈希再比字段（O(1)）；`ByteArraySqlArg` 的 O(n)+字符串化已作为 §7/§8 方案处理，不重复计 |
| §7 降堆内存方案 | 2 | 缓存键持有参数（方案 1）、`SqlArg` 每参数分配（方案 3）；均无基线 |
| §8 降 CPU 方案 | 2 | `ByteArray` 哈希字符串化（方案 2）、`SqlArg` 分配（方案 3）；均无基线 |
| §9 local mode 可行性 | 0 | 不可行：`SqlArg` 必然逃逸（存入 `SqlArgs` 字段、被 `SqlCacheKey` 长期持有、作为 `ArrayList` 元素跨函数传递），不满足 local region 的逃逸检查；且 `ArrayList<SqlArg>` 的接口元素仍需装箱，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 6 | #1 等值/哈希（严重）、#2 键语义、#3 日志与字符串化、#6 `add(all!)` 的索引重复隐患、#9 接口恒抛、#10 测试断言不成立；已逐个核对 20 个 `set` 实现的类型实参与 `setValue` 契约（`Float16→Float32` 与 `BigInt→String` 为既定约定，见 `SqlArgBinding_test.cj:128`） |
| §12 并发安全与锁粒度 | 0 | 已给线程封闭证据：`SqlExecutor` 构造为 private、实例只由 `ThreadLocal<HashMap<String, SqlExecutor>>` 生产（`SqlExecutor.cj:44`、`113-131`），`SqlArgs`/`StatementWrap`/`TransactionWrap` 都随 executor 线程封闭；未发现跨线程共享路径，故无「缺同步」可报 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；7 个 `.cj` 的对外声明与 README §19.2/19.3 逐项对照未发现「承诺未实现」（`StatementWrap` 参数版恒抛、`DummyTransaction` 空实现均在 README 第 2192/2194 行明写）。README 侧的不一致见「范围外提示」 |
| 文件覆盖（§13 等） | 7/7 | 清单 7 个文件全部读完；本部分不含 `.md`，文档一致性只能核对到 README 的跨部分条目（见范围外提示） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是 ORM 的「参数绑定 + 事务/语句包装」薄层，代码量不大，但**参数对象同时承担了三种角色**：绑定数据、缓存键成分、日志文本来源。三者耦合正是三个实质问题的根源：流参数按「不可比较」处理，却仍被拿去做缓存键（数据错误，唯一严重项）；可变参数对象被缓存键强引用，`refEq` 又让身份等同内容，ORM-1 的修复只在默认路径成立；`toString` 同时服务日志与异常消息，把参数原文和整块 BLOB 一起带出。

阻塞项只有第 1 条（流参数缓存命中会返回上一次的行），修法明确、改动局部（`InputStreamSqlArg` 的 `==`/`hashCode` 或给 `SqlArg` 加 cacheable 标记）。第 2 条需要在合并模块报告时与 `base/SqlExecutor.cj` 的缓存实现一起看，属「按事务边界设计的缓存」被 `clearArgsAfterExec:false` 打开的口子。其余 7 条为死代码、重复逻辑与测试质量问题，可排期。

存量 10 条（严重 1 / 一般 2 / 轻微 7），是否纳入修复待用户决定；本部分未做任何源码修改。

**范围外提示**（不占本轮统计）：①`f_orm/README.md:2190` 仍写 `SqlArgs` 有 protected `clone()` / `clear()`，源码中这两个成员已删除（`SqlArgs.cj:23-25` 注释说明删除原因）；②`f_orm/README.md:2201` 与 `README_en.md:2388` 称 `arg(...)` 即 `SqlArg.new<T>`，实际 `RootDAO.arg` 走 `SqlExecutor.add` → `SqlArgs.add` 重载，`SqlArg.new` 无任何调用；③`base/SqlExecutor.cj:907-918` 命中缓存时直接返回同一个 `ArrayList` 实例，调用方修改返回值会污染缓存（属 base 部分）。
