# f_orm 模块审查报告

> **模块第 5/8 部分**（本报告只覆盖 `files/f_orm.part5.txt` 列出的 20 个文件，全部位于 `f_orm/src/base/`：`SqlExecutorConnectingTimeout_test` → `imports.cj`，其中 8 个 `*_test.cj`（5 个含测试用例、3 个是测试替身）、12 个实现/定义文件，**0 个 `.md`**。模块共 111 `.cj` + 11 `.md`，其余文件由第 1–4、6–8 部分产出；本部分编号独立，合并时以主 Agent 为准。README / `doc/**` 不在本部分文件清单内，只在需要对照契约时被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`HEAD 97507061b 2026-11-28`；`git status` 对本部分文件无改动 ⇒ 全部问题记「存量」；关键行 `git blame`：`SqlPartial.cj:160` = `ae7aa2263c 2026-09-13`、`TableClause.cj:166` = `5f431b4c8f 2026-09-16`、`TableClause.cj:20` = `245fecb0cb 2026-10-05`、`TrsactionHooks.cj:46` = `4be871f2fd 2026-10-02`、`TableMeta.cj:49/55` = `4be871f2fd 2026-10-02`）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 5/8 部分）

本部分是**链式 DSL 与事务钩子的结合部**：`TableClause`（`From` / `Update` / `Into` 三个子句 + `WHERE/ORDER_BY/GROUP_BY/SET` 拼接）、`SqlPartial`（`SqlExecutor` 上的 `UPDATE/INSERT/PAGE` 扩展）、`TransactionHook` / `TransactionHooks` / `TransactionAspect` / `Transactional` / `TransactionStatus`、`TableMeta(s)` / `TableSchema`（反射取列/索引元数据）、`ORMConverter`、`imports.cj`，外加 5 个用例文件与 3 个测试替身。三条最重的问题都集中在「生成的 SQL 文本」与「钩子契约」：`UPDATE(Map)` 的 SET 逗号拼接、`ORDER_BY/GROUP_BY(Array<Column>)` 的空格分隔、以及 `TransactionHook.inTx()` 全链路无人调用。参数绑定本身全程走 `arg()` 占位符，本部分**未发现 SQL 注入**；本部分**无任何锁**（`grep synchronized|Mutex` 为空），锁粒度维度不适用。

## 发现

### [严重][存量] #1 `TransactionHook.inTx()` 永远不会被调用：接口与 README 都承诺了，框架侧既无调用点也没被 `TransactionHookWrap` 转发

- **位置**：`f_orm/src/base/TransactionHook.cj:19-20`（接口默认空实现）；`f_orm/src/base/TrsactionHooks.cj:21-51`（`TransactionHookWrap` 只转发 7 个方法，缺 `inTx`）；调用侧 `f_orm/src/base/SqlExecutor.cj:1039-1100`（只有 `beforeTx/beforeCommit/afterCommit/afterThrowing/beforeRollback/afterRollback/afterComplete`）
- **来源**：存量（`git blame`：`TransactionHook.cj:20` 与 `TrsactionHooks.cj:24-44` 均落在 `4be871f2fd 2026-10-02`；`git status` 无改动）
- **判据**：review-checklist §3「接口给了默认空实现 / 公开契约承诺有行为，实现为空」、§14.1「承诺了但没实现」、§1「注册了但永不触发」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）`grep -rn "inTx"` 的命中只有三处：`TransactionHook.cj:20` 的接口默认实现、`TrsactionHooks.cj` 内**没有**对应方法、以及 `f_orm/README.md:1626` 把 `func inTx(): Unit {}` 列进公开接口清单。`SqlExecutor.execute` 的钩子调用序列里没有任何 `inTx()`。`TransactionHookWrap`（`TrsactionHooks.cj:21`）虽然 `TransactionHook` 有默认实现，但它不转发，所以即使将来补上调用点，包裹层里的真实钩子也收不到。
- **描述**：`TransactionHook` 是公开扩展点，`inTx()` 的语义（"事务已开始、业务函数执行中"）在下游被用来绑定线程上下文（会话变量、审计、`SET LOCAL`）。当前它 100% 静默失效：用户在钩子里写的逻辑一行都不会跑，且没有任何编译告警或日志。`fdemo/boot/src/TransactionHookImpl.cj:29` 就实现了这个方法（只打日志），所以连"仓内无人实现"的兜底解释都不成立。
- **建议**：二选一，不要停在中间态：①在 `execute` 里 `newTxAndBegin(...)` 之后、`executor(this)` 之前调用 `ORM.hooks.inTx()`，并在 `TransactionHookWrap` 里补 `public func inTx(): Unit { hook.inTx() }`；②若语义未定型就先从接口删掉，README 同步删除——留着空实现的公开钩子比没有更危险。补一条用例：注册一个只置位 `Box<Bool>` 的 hook，`execute{}` 后断言置位。

### [一般][存量] #2 `UPDATE(Map<String, Any>)` 两个重载先把 `, ` 写进 SET 再判断该列是否在 map 里：缺列时留下孤立逗号，生成 `SET a=?, , b=?`

- **位置**：`f_orm/src/base/SqlPartial.cj:160-168`（`161` 行无条件 `sql.append(', ')`，`163-167` 才判断列是否存在）；同一缺陷复制到 `f_orm/src/base/SqlPartial.cj:203-211`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`，`160-168` 整段同一次提交）
- **判据**：review-checklist §11「逻辑错误（生成非法 SQL）」、§2「字面量复制（同缺陷两处）」
- **证据**：静态确定 —— 逗号写在 `if(sql.size > sqlsize)` 里，只以"已经写过内容"为条件；紧随其后的 `if(let Some(v) <- values.get(field)) … else if … values.get(column)` 两个分支都可能**都不命中**（该列既不按字段名、也不按列名出现在 map 中），此时逗号已经落盘，列没有落盘。两种形态：①中间缺列 —— mapper 顺序 `name, age, nick`，map 只给 `name` 与 `nick` ⇒ `SET \`name\`=?, , \`nick\`=?`；②末尾缺列 —— 只给 `name` ⇒ `SET \`name\`=?,  WHERE \`id\`=?`（逗号紧贴 WHERE）。反过来，"map 里只有主键"时因为第一个非 id 列就没命中、逗号从未写入，`sql.size == sqlsize` 成立，`171-172` 的 `no column to update` 能正常抛出——说明该校验本身没问题，问题只在"部分命中"的形状。
- **描述**：部分字段更新的常见写法（只传脏字段）一旦字段顺序有"空洞"就必然报 SQL 语法错误；错误信息来自驱动（`You have an error in your SQL syntax near ','`），排查时看不出是 ORM 拼串问题。列全在、或缺失列都排在最后时不触发，所以单列/连续列的用例守不住。`f_orm/src/base/SqlPartial.cj:247-254`（`ObjectData` 路径）把逗号放在过滤分支**内部**，说明正确写法是已知的，这两处是漏改。
- **建议**：把逗号改成"追加列之前才判断"：先算出 `let val = values.get(field) ?? values.get(column)`，命中后再 `if(sql.size > sqlsize) { sql.append(', ') }` 然后 `append(involve(column)…arg(v))`；同时把两处重复的 SET 构建抽成一个私有函数（`值解析 + 逗号 + 绑定`），顺带修掉两处 `'no column to udpate'` 拼写。补用例：三列 mapper、map 只给第 1、3 列，断言 SQL 不含 `, ,` 且 `args.size == 2`。

### [一般][存量] #3 `ORDER_BY(Array<Column>)` / `GROUP_BY(Array<Column>)` 用**空格**而不是逗号分隔列，多列时生成 `order by a b`

- **位置**：`f_orm/src/base/TableClause.cj:162-171`（`166` 行 `columns.append(' ')`）、`f_orm/src/base/TableClause.cj:257-266`（`261` 行同样写法）
- **来源**：存量（`git blame`：`5f431b4c8f 2026-09-16`）
- **判据**：review-checklist §11「逻辑错误（生成非法 SQL）」、§2「近似重复（两处同错）」
- **证据**：静态确定 —— `Column.toString()`（`f_orm/src/base/Columns.cj:120-143`）本身就返回带首尾空格的 `' name '`，所以两段之间只会有空格，绝不出现 `,`；`appendPartial(' order by ', ',', …)` 的 trim 只裁首尾逗号，不会补中间分隔符。两列时文本为 `order by `id`  `name``，缺逗号；`GROUP_BY` 同理。
- **描述**：多列排序/分组是常规需求（`ORDER_BY([t.id.ASC(), t.name.DESC()])`），当前必然被数据库拒绝。仓内唯一活调用 `fdbm/test/e2e/orm_client/src/main.cj:177` 只传一个元素，README 的两个示例（`README.md:1155`、`1353`）也都是单元素，所以缺陷没被任何用例覆盖到。
- **建议**：两处 `append(' ')` 改成 `append(', ')`；顺手把这段"`Array<Column>` → 逗号串"提取为与 `columns2string(Array<SqlExpr>)`（`TableClause.cj:311-320`）同源的私有函数，避免第三份。补用例：两列 `ORDER_BY`，断言 SQL 含 `order by` 且逗号数 = 1。

### [一般][存量] #4 `appendPartial` 的 `and|or` 裁剪正则与 `Condition.TRIM_AND_OR` 语义不一致：首部 `' or …'`、尾部 `'… and '` 裁不掉

- **位置**：`f_orm/src/base/TableClause.cj:20`（`^(\s*and|or\s*)|(\s*and|or\s*)$`）对照 `f_orm/src/base/Condition.cj:33`（`^\s*(and|or)\s*|\s*(and|or)\s*$`）
- **来源**：存量（`git blame`：`245fecb0cb 2026-10-05`，注释自称"模式文本与原先每次插值出的完全一致"，即沿用了旧语义）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（同一归一化两份实现已漂移）」、§11「逻辑错误」
- **证据**：静态确定 —— 分支优先级决定语义：`^(\s*and|or\s*)` 的两个选择是「行首 + 空白* + `and`」与「`or` + 空白*（必须紧贴行首）」，因此行首带空白的 `or` 不匹配；对称地，`(\s*and|or\s*)$` 的 `\s*and$` 要求 `and` 紧贴行尾，行尾带空白的 `and` 不匹配。`Condition` 那份把 `\s*` 提到分组外，两种情形都覆盖。两处归一化的是同一种"首尾 `and|or`"条件串，只是分属两条路径：前者服务 `AND/OR/WHERE/HAVING` 的字符串重载（`TableClause.cj:153/177/183/189/271`），后者服务 `Condition.SET/WHERE` 的构建器。
- **描述**：`WHERE(' and x=1 ')` 能裁掉，`WHERE(' or x=1')` 留下来变成 `where  or x=1`（语法错误）；`AND('x=1 and ')` 留下尾部 `and`，同样语法错误。手写条件串是该 API 的公开用法（`AND(condition: String)`、`WHERE(condition: String)`），所以可达；`Partials`/`Condition` 生成的串已预先裁剪，日常链路不会踩。
- **建议**：直接复用 `Condition.TRIM_AND_OR` / `TRIM_COMMA`（把 `Condition` 的常量提到包级或给 `Condition` 加 `internal static func trimAndOr`），删掉 `TableClause.cj:20-21` 这一份；若要保留两份，至少把 `\s*` 提到分组外并对齐替换目标（`Condition` 替换为 `' '`、这里替换为 `''`，这是有意差异，应在注释里写明而不是写成"完全一致"）。

### [一般][存量] #5 `TransactionHookWrap` 不转发 `order`：`compare` 比较的是包裹层自己的默认值 `Int64.Max`，钩子顺序配置完全失效

- **位置**：`f_orm/src/base/TrsactionHooks.cj:45-50`（`46` 行 `this.order.compare(other.order)`）；`order` 的默认实现 `f_orm/src/base/TransactionHook.cj:30-34`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符」、§13「文档与实现不一致」（`README.md:1638` 写明"先比 `order`，再比注册序号"）
- **证据**：静态确定 —— `TransactionHookWrap <: TransactionHook` 只重写了 7 个回调（`TrsactionHooks.cj:24-44`），没有重写 `order`，因此 `this.order` 与 `other.order` 都取接口默认的 `Int64.Max`，`compare` 必然走 `case EQ => count.compare(...)`。`register` 也没有把 `hook.order` 存进 wrap（`TrsactionHooks.cj:22` 只有 `hook` 与 `count` 两个字段）。
- **描述**：`prop order` 是唯一的排序手段，用户按 README 把"日志钩子 `order=1`、审计钩子 `order=100`"排好，实际执行顺序永远是注册顺序。若某个钩子依赖先后（例如先初始化会话再写审计），会得到错误的执行序列，且没有任何提示。顺序错误不会抛异常，属于"静默错序"。
- **建议**：`TransactionHookWrap` 增加 `public prop order: Int64 { get() { hook.order } }`（或把 `order` 在构造时快照成字段，避免运行期读钩子的可变属性）。补用例：注册两个 `order` 相反的 hook，断言 `beforeTx` 的调用序列。

### [一般][存量] #6 钩子注册非幂等且无同步：重复 `ORM.initialize()` 会让钩子成倍执行，注册与遍历并发时 `ArrayList` 无保护

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55-58`（`list.add(...)` + `sort(list)`，无去重、无锁）；入口 `f_orm/src/base/ORM.cj:65-72`（`registerTransactionHooks` 无条件遍历注册）、`f_orm/src/base/ORM.cj:148-155`（`initialize()` 每次都调）
- **来源**：存量
- **判据**：review-checklist §5「无界容器 / 全局集合只增不减」、§12.1「检查-然后-写入 / 迭代与修改并发」
- **证据**：静态确定 —— `register` 只有 `add`，没有任何"已注册则跳过"的判断；`ORM.hooks` 是 `static let`（`ORM.cj:40`），生命周期等于进程。`ORM.initialize()` 在仓内被多次调用（`f_llm/src/service/LLMConfService_test.cj:60` 与 `:111` 各一次，`f_orm/src/base/ORMInitializer.cj:36` 一次），同一进程内每调一次就把 `lookupList<TransactionHook>()` 的结果整体追加一遍。`hooks` 的遍历（`TrsactionHooks.cj:59-93`）与 `register` 的 `add/sort` 之间没有同步手段，而 `ORM.registerTransactionHook<T>`（`ORM.cj:69-72`）是 public 的，可在运行期被调用。
- **描述**：①重复初始化 ⇒ `beforeTx/beforeCommit/afterCommit` 每个执行 N 次：审计重复落库、计数器翻倍、`SET LOCAL` 重复执行；并且 `list` 只增不减（内存随初始化次数线性增长，量级小但无界）。②运行期注册与事务遍历并发 ⇒ `ArrayList` 结构性修改，可能读到半成品排序结果或越界。
- **建议**：`TransactionHooks` 内维护一个 `HashSet<TypeInfo>` 记录已注册的钩子类型，重复注册直接跳过（`T` 参数正好用上，见 #14），或让 `ORM.initialize()` 幂等（首次注册后置标志）；注册路径加锁，或改成"拷贝-排序-原子替换 `let list`"的写时复制，让遍历读不可变快照。

### [一般][存量] #7 `TableMeta.new` 静默吞异常并静默丢列；`TableMetas.register` 只 warn 不抛：表元信息缺失后迁移会直接少建列

- **位置**：`f_orm/src/base/TableMeta.cj:43-60`（`49`/`55` 两处 `catch(_){}`，`57` 行 `filter{opt => opt.isSome()}`）；`f_orm/src/base/TableMetas.cj:26-32`（`29-31` 捕获全部异常只 `log.warn`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3「`catch (_: Exception) {}` 静默吞掉异常」、§14.1「半成品 / 接线缺失」
- **证据**：静态确定 —— 每个 mapper 依次尝试 `getInstanceProperty` 与 `getInstanceVariable`，任何反射异常都被空 `catch` 吞掉；两个 `if (let Some(schema) <- …)` 都不命中时返回 `None`，随后被 `filter` 丢弃。全过程无日志、无计数、无异常。`TableMetas.register` 把 `TableMeta.new` 的任何失败降级为一行 `warn`。
- **描述**：`@ColumnSchema` 少写一个、字段写成 `static`、反射 API 对某成员抛错——结果都是"这一列从 `TableMeta.columns` 里消失"。下游 `SchemaFinderMediator` 用它生成 `CREATE TABLE` / `ALTER TABLE`（`f_orm/src/migro/SchemaFinderMediator.cj:29`），于是建表少一列、或者对着已有表永远认为"该列不存在"，而构建与启动都成功。缺列的影响面是数据面，不是日志面。
- **建议**：空 `catch` 改为 `catch (e: Exception) { log.debug(...) }` 或直接不捕获（`getInstanceProperty` 找不到时本身返回 `None` 语义的 API 更合适）；两个分支都不命中时收集成列表，在 `TableMeta.new` 结束前统一抛 `TableMetaException('columns without @ColumnSchema: …')`。`TableMetas.register` 至少把 `warn` 提升为 `error` 并保留异常堆栈。

### [轻微][存量] #8 `UPDATE<T>(values: T, …, dirty: true)` 在"无列可更新"时提前 `return 0`，掩盖了主键缺失；紧随其后的 `else if` 恒不可达

- **位置**：`f_orm/src/base/SqlPartial.cj:256-263`（`256` 先 `return 0`，`259` 才判 `idColumn.isEmpty()`，`261` 的 `else if (sql.size == sqlsize)` 永假）；对照 `f_orm/src/base/SqlPartial.cj:169-172`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」、§11「错误处理缺失（失败路径当成功）」
- **证据**：静态确定 —— 控制流上 `256` 行已把所有 `sql.size == sqlsize` 的情形 `return 0`，`261` 行的同一条件不可能再为真。触发 `sql.size == sqlsize` 的现实路径是"过滤条件把所有列都排掉"：`dirty: true` 时 `DirtyTag` 给出的字段名与实际列名不匹配（`includingColumns` 收不到任何 mapper），或 `includingColumns` 传的是列名而 mapper 的 `columnName` 与之不一致。
- **描述**：此时函数返回 `0`（"没有行被更新"），而不是像 Map 重载那样抛 `NoIdException`/`SqlArgException`；如果真实原因是"主键映射缺失"，业务侧看到的是一个合法的 0，永远查不出配置错误。无主键但**有**可更新列时仍会正常抛 `NoIdException`，所以这不是"无主键必静默"，而是"无列可更新时不再检查主键"。
- **建议**：把 `idColumn.isEmpty()` 的判断提到 `return 0` 之前（与 `169-172` 一致），删掉 `261` 的不可达分支；`sql.size == sqlsize` 时仍返回 0（这是合法语义），但要与"无主键"区分开、必要时 `log.debug` 记录被跳过的原因。

### [一般][存量] #9 `@ColumnSchema[comment: …]` 只被搬进 `ColumnMeta.comment`，全仓无任何消费：列注释永远不会出现在 DDL 里

- **位置**：`f_orm/src/base/TableSchema.cj:44-53`（`52` 行 `comment!`）、`f_orm/src/base/TableMeta.cj:72`（字段）/`81`（赋值）；生成侧 `f_orm/src/migro/MysqlSchema.cj:100-102`（`generateColumn` 只拼列名/类型/nullable/default/extra）、`f_orm/src/migro/PostgresSchema.cj` 同样无注释语句
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用（死配置字段）」
- **证据**：静态确定 —— 全仓 `grep -rn "\.comment\b" --include=*.cj`（排除 `.worktrees`）在 `f_orm` 内只有 `TableMeta.cj:81` 的赋值；`grep -rn "comment" f_orm/src/migro` 结果为空。`f_orm/src/migro/MysqlSchema.cj` 的 `generateColumn` 只拼列名/类型/nullable/default/extra。
- **描述**：注解参数对外可见（`public let comment!`），使用者按常规语义写 `@ColumnSchema[typeName: 'varchar(64)', comment: '用户昵称']`，期望 `CREATE TABLE`/`ALTER TABLE` 带上 `COMMENT '用户昵称'`；实际被丢弃。同类字段 `IndexMeta.def` 有人消费（`PostgresSchema.cj:119`），`comment` 则完全没有，说明不是"故意留给下游"。
- **建议**：要么在 `generateColumn`/`generateAlterSql` 里接上（MySQL `comment '…'`、Postgres `comment on column …`），要么把 `comment!` 从 `ColumnSchema` 与 `ColumnMeta` 删掉，避免给出不存在的承诺。注意 `ColumnMeta.hashCode/==` 也不含 `comment`（`TableMeta.cj:83-92`），接线时需一并纳入比较，否则"只改注释"不会被识别为变更。

### [一般][存量] #10 `page` / `singlePage` 不校验 `size`，`size == 0` 在 `Pagination` 构造里除零抛 `ArithmeticException`

- **位置**：`f_orm/src/base/SqlPartial.cj:304-309`（`size` 原样下传）、`f_orm/src/base/SqlPartial.cj:296-299`（`Pagination<R>(page: …, size: size)`）；除零点 `f_orm/src/base/Pagination.cj:36`（`this.pages = rows / size + …`）
- **来源**：存量
- **判据**：review-checklist §11「除零 / 缺少边界校验」、§10「正确性」
- **证据**：静态确定 —— `selectPage`、`page`、`singlePage` 对 `size` 没有任何 `> 0` 断言，`Pagination` 构造函数直接 `rows / size`。仓颉整数除零抛 `ArithmeticException`（官方文档 `cangjie_docs/docs/dev-guide/.../core_package_api/core_package_exceptions.md`，`ArithmeticException` 条目："算术错误（如除零）"）。
- **描述**：`size` 通常来自请求参数（`?size=`），传 0 或负数时：0 ⇒ 抛 `ArithmeticException`（栈顶在 `Pagination`，与"分页参数非法"毫无关联，容易被当成框架 bug）；负数 ⇒ `rows / -1` 得到负页数、`limit` 收到负值，SQL 行为依驱动而异。注意 `rows == 0` 也挡不住：`Pagination` 的次构造函数只把 `list()` 换成空列表，`pages` 的计算仍在主构造函数里执行（`Pagination.cj:30-48`），所以空表同样除零。
- **建议**：在 `selectPage` 入口统一校验 `size > 0`（`page >= 1`），不合法时抛 `SqlArgException` 并在消息里带上入参；`Pagination` 构造函数同样加保护（它是 public API，可被直接调用）。

### [一般][存量] #11 `FromClause.first/singleFirst/firstToMap` 靠"往 `sqlgen` 追加 LIMIT"实现，子句被复用后 `count()` / `list()` 会带着上一次的 `limit 1`

- **位置**：`f_orm/src/base/TableClause.cj:302-353`（`303`、`306`、`325`、`352` 行 `LIMIT(1)` 写进 `sqlgen`）、`f_orm/src/base/TableClause.cj:235-240`（`LIMIT` 追加到 `sqlgen`）、`f_orm/src/base/TableClause.cj:355-360`（`count()` 复用 `sqlgen`）
- **来源**：存量
- **判据**：review-checklist §11「状态副作用 / 语义与命名不符」、§2「近似重复（四个入口同一写法）」
- **证据**：静态确定 —— `LIMIT(...)` 的返回值是 `This`，被插值进字符串时走 `toString()` 得到"完整 sqlgen"；副作用是把 ` limit ? offset ?` 永久追加到 `sqlgen`，且 `executor.add(one).add(two)` 已绑定 2 个参数。`sqlgen` 是子句实例字段（`TableClause.cj:24`），生命周期 = 子句对象，四个入口都改它。
- **描述**：`let q = FROM<UserPO>().WHERE{…}` 之后先 `q.first<UserPO>()` 再 `q.count()`：count 的内层变成 `select 1 from user where … limit ? offset ?`，而上一句执行完 `clearSql()` 已把绑定参数清空 ⇒ 占位符 2 个、参数 0 个，驱动报参数个数不匹配（宽松绑定时 `limit NULL` 同样不合法）。同理 `q.list<UserPO>()` 会带着残留的 limit 一起执行。链式 API 的惯例是"子句用完即弃"，所以这是陷阱而非必然崩溃，但 `first`（语义是"只取一条"）不该改写对象状态。
- **建议**：`first/singleFirst/firstToMap` 改成不改 `sqlgen`：用局部副本拼 `select * ${sqlgen}${dialectLimitSql}`（把 `dialect.limit` 的 SQL 片段单独取出，参数仍旧 `add`），或干脆调用 `page(size: 1)` 的实现路径。子句若支持复用，应在 `count()` 里显式剥掉 LIMIT；若不支持，加注释并在 `toString()` 外部说明单次使用。

### [一般][存量] #12 `Transactional.getPropagation()` 等 4 个公共 getter 与 `TransactionAspect` 重复实现且已漂移：getter 说 `Required`，实际生效的是配置值

- **位置**：`f_orm/src/base/Transactional.cj:32-64`（`getPropagation` / `getIsoLevel` / `getAccessMode` / `getDeferrableMode`）对照 `f_orm/src/base/TransactionAspect.cj:45-71`（切面自己的 6 段 `if (x.isNone()) { …ORMConfig.get… }` 回落逻辑）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制（同一回落规则两份实现）」「重复逻辑导致的行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `getPropagation()` 在注解未指定时硬编码 `Required`，而切面用的是 `ORMConfig.getTransactionPropagation(driverName:)`；`getIsoLevel/getAccessMode/getDeferrableMode` 三个 getter 虽然读了配置，但 `TransactionAspect` 完全不调用它们（全仓 `grep "getPropagation()\\|getIsoLevel()"` 只命中定义处）。也就是说同一个注解有两套"默认值解析"，其中一套没人用、且结论不同。
- **描述**：`transactional.getPropagation()` 是 public API（注解对象对外可见），下游若用它判断"这个函数会以什么传播行为执行"会得到 `Required`，而真实执行可能是配置里的 `RequiresNew`——诊断/自省场景直接误判。后续若有人给 `ORMConfig` 增加新的回落维度，必须记得改两处。
- **建议**：让切面调用注解自身的 getter（`x.getPropagation()` / `x.getIsoLevel()`…），把"注解优先、配置回落、最终默认"收敛到 `Transactional` 一处；`driverName` 需要在 getter 内部解析（`driverName.isEmpty()` ⇒ 默认驱动）后再查配置。

### [轻微][存量] #13 `appendPartial` 的"自定义 trim"分支在仓内不可达（14 处调用实参只有 `''` / `'and|or'` / `','`）

- **位置**：`f_orm/src/base/TableClause.cj:48-56`（`53-55` 的 `else` 分支）；调用点 `TableClause.cj:142/153/170/177/183/189/233/255/265/271/382/414/417/420`
- **来源**：存量（`git blame`：`245fecb0cb 2026-10-05`）
- **判据**：review-checklist §1「恒真恒假分支 / 无调用者的分支」
- **证据**：静态确定 —— `grep -n "appendPartial("` 的全部调用第三个实参（`trim`）都是字面量 `'and|or'`、`','`、`''`；`condition(...)` 转发时 `trim` 也只来自 `WHERE/AND/OR/NOT/HAVING` 的固定 `'and|or'`。`TableClause` 是 `abstract sealed`（`TableClause.cj:23`），子类只能在本包内，仓内只有 `FromClause` / `UpdateClause` / `IntoClause` 三个，都在同一文件。
- **描述**：该分支动态构造正则（`solid: true`，不转义 `trim`），无任何用例覆盖；它同时是 #4 那份"漂移正则"的来源。留着它使人以为支持自定义 trim，实际一旦传入含正则元字符的值（如 `'('`）就会在编译正则时抛错。
- **建议**：删掉该分支，`trim` 改成枚举/常量集合（`''`、`'and|or'`、`','`），非法值直接抛 `IllegalArgumentException`；若确实要保留扩展点，补一条自定义 trim 的用例并转义输入。

### [轻微][存量] #14 `TransactionHooks.register<T>` 的类型参数 `T` 在函数体内完全未使用

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55`（`func register<T>(hook: TransactionHook): Unit where T <: TransactionHook`）；调用方 `f_orm/src/base/ORM.cj:71`（`hooks.register<T>(hook)`）
- **来源**：存量
- **判据**：review-checklist §1「死代码（死类型参数）」、§10「可读性」
- **证据**：静态确定 —— 形参表只有 `hook: TransactionHook`，函数体只有 `list.add(TransactionHookWrap(hook, list.size)); sort(list)`，`T` 不出现在任何位置，也不参与重载解析（`ORM.registerTransactionHook<T>` 已把 `hook: T` 上转成 `TransactionHook`）。
- **描述**：读者会以为注册按类型去重或按类型分组，实际没有；结合 #6，`T` 正是实现去重最自然的抓手。
- **建议**：要么用它做去重（以 `T` 为 key 记录已注册类型），要么删掉类型参数与调用处的 `<T>`。

### [轻微][存量] #15 三个测试替身（`StatementTest` / `UpdateResultTest` / `TransactionTest`）放在 `src/base/` 且是 `public`，随模块一起发布

- **位置**：`f_orm/src/base/Statement_test.cj:18`、`f_orm/src/base/UpdateResult_test.cj:18`、`f_orm/src/base/Transaction_test.cj:18`（另 `QueryResult_test.cj` 不在本部分）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用（可见性建议）」、§14.2「测试辅助不算公开 API，但不应出现在公开面」
- **证据**：静态确定 —— 三个类都是 `public class … <: std.database.sql 接口`，位于 `src/`（非 test 包），只被 `f_orm/src/base/Connection_test.cj:27/33` 与 `Statement_test.cj:25/29/34` 引用。`TransactionTest.begin/commit/rollback` 全是空实现（`Transaction_test.cj:43-48`），`StatementTest.set` 也是空实现（`Statement_test.cj:31`）。
- **描述**：它们对外可见：下游可以 `TransactionTest()` 拿到一个"commit 什么都不做"的事务对象，静默丢事务；也污染了模块的公开 API 面。作为测试替身本身没问题，位置与可见性不对。
- **建议**：移到 `f_orm/src/test/`（或 `internal`），需要跨包使用时用测试专用依赖；`TransactionTest` 至少让 `commit/rollback` 记录调用，避免"空实现即通过"。

### [轻微][存量] #16 `UpdateClause.SET` 为空时不校验，`execute()` 会发出 `update t` 这种半截语句

- **位置**：`f_orm/src/base/TableClause.cj:381-411`（`382` 行 `appendPartial('set', ',', set())`；`409-411` 行 `execute()` 直接 `setSql().update`）
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」、§2「与 Map 路径不一致（`no column to update`）」
- **证据**：静态确定 —— `appendPartial` 在 `emptyLogicalExpr(sql)` 为真时**不追加** `set …`，`execute()` 没有任何"是否写过 set"的检查；`SqlPartial.UPDATE(Map)` 对同一情形抛 `SqlArgException`（`SqlPartial.cj:171-172`）。
- **描述**：`UPDATE<PO>().SET{ => '' }`（动态条件算出空串）或 `SET` 里全是空片段时，SQL 变成 `update \`t\``，驱动报语法错误；两条 UPDATE 入口对"无列可更新"的处理一个报清晰异常、一个把半截 SQL 丢给驱动。
- **建议**：`UpdateClause` 记录是否写入过 `set`（或在 `execute()` 里 `if (!sqlgen.contains(' set ')) throw SqlArgException('no column to update')`）；`VALUES` 同理校验列数（见 #17）。

### [轻微][存量] #17 `IntoClause.VALUES(values: Array<Any>)` 不校验元素个数与列数一致，绑定错位只能等驱动报错

- **位置**：`f_orm/src/base/TableClause.cj:479-492`（`481` 行按 `values.size` 生成占位符，从不与 `fields.size` 比较）
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」、§10「正确性」
- **证据**：静态确定 —— 列清单由构造函数按 `ignore/include` 过滤后存入 `fields`（`TableClause.cj:425/446/474`），`VALUES<D>` 版本按 `fields.size` 逐个取值（`496`），而 `VALUES(Array<Any>)` 只按入参长度循环；两者长度不等时生成 `insert into t(a,b,c) values(?,?)`。
- **描述**：调用方少传/多传一个值时得到驱动层语法错误；`ignoreColumns` 改变列数后忘记同步数组长度是常见误用，错误信息里没有列清单，排查成本高。
- **建议**：`if (values.size != fields.size) throw SqlArgException('values size ${values.size} does not match columns ${fields.size}')`，消息里带上列名。

### [轻微][存量] #18 `findById` / `deleteById` 各 3 个重载、`UPDATE` 的 `Array<(Column,Any)>` 与 `Map<Column,Any>` 转换、`IntoClause` 两个构造函数：同一份逻辑复制 2–6 份

- **位置**：`f_orm/src/base/TableClause.cj:282-300`（6 个函数体两两逐行相同：`findById` ×3、`deleteById` ×3，只差 `Int64`/`UInt64`/`String`）、`f_orm/src/base/SqlPartial.cj:123-143` 与 `181-187`（`Column.name → String` 映射写 4 遍）、`f_orm/src/base/TableClause.cj:427-450` 与 `451-478`（`IntoClause` 两个构造函数的过滤逻辑，一个用 `where` 谓词、一个用 `continue`，已出现写法漂移）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 跨层复制 / 近似重复」
- **证据**：静态确定 —— 三个 `findById` 与三个 `deleteById` 的 SQL 文本、参数顺序、错误路径完全一致；`UPDATE` 的 4 个转换块只有目标容器类型不同；`IntoClause` 两段过滤的判据表达式分别是 `!ignoresSet.contains(mapper.dataType.columnName) && (includesSet.isEmpty() || …)` 与 `if (ignoresSet.contains(column) || !(includesSet.isEmpty() || includesSet.contains(column))) { continue }`（德摩根等价，但阅读成本与改动风险不同）。
- **描述**：`findById` 的 `idName ?? 'id'` 回落规则改一次要改 3 处（`deleteById` 亦然），`IntoClause` 过滤规则改一次要改 2 处——#9 的 `comment` 漏接线就是这种复制结构的典型后果。差异点确实是类型（`Int64/UInt64/String` 与 `String/Column` 两套键），属于业务要求，所以不建议泛型化到"一个函数包打天下"。
- **建议**：类型重载保留签名、函数体收敛到 `private func findByIdRaw(id: Any): ?T` / `deleteByIdRaw(id: Any): ?T`；`Column` 键的 4 处映射抽成 `private func columnKeyed(values: Collection<(Column, Any)>): HashMap<String, Any>`；`IntoClause` 把过滤谓词抽成 `private func wanted(mapper: QueryMapper<T>, ignores: HashSet<String>, includes: HashSet<String>): Bool`。

### [轻微][存量] #19 钩子回调没有异常隔离：任一钩子抛错会跳过同阶段剩余钩子，并可能把提交路径变成回滚路径

- **位置**：`f_orm/src/base/TrsactionHooks.cj:59-93`（7 个 `for (h in list) { h.xxx() }` 均无 `try/catch`）
- **来源**：存量
- **判据**：review-checklist §10「正确性（异常路径）」、§12.1「契约 / 异常语义」、§3「接口默认行为与实际语义不符」
- **证据**：静态确定 —— 遍历体直接调用，异常向上冒泡。`beforeCommit` 的异常会被 `SqlExecutor.execute` 的 `catch (e: Exception)` 当成业务异常（`SqlExecutor.cj:1056-1058`），进入 `afterThrowing` + `rollback` 分支，而事务其实还没提交。
- **描述**：一个钩子（比如审计写日志失败）会把"应该提交"的事务变成"回滚"，且回滚原因对业务方显示为业务异常；同时排在它后面的钩子（包括 `afterComplete` 的清理逻辑）不执行，容易留下未清理的线程上下文。
- **建议**：明确策略并写进接口注释——要么"钩子异常只记录不影响事务"（每个回调 `try/catch` + `log.error`），要么"`beforeCommit` 异常中止提交但保留原异常"（`addSuppressed`）。`afterRollback/afterComplete` 这类清理阶段应强制隔离。

### [轻微][存量] #20 `singleList()` / `singlePage(size, page)` 把默认列硬编码成 `'id'`，与 `findById/count` 的 `idName ?? 'id'` 回退策略不一致

- **位置**：`f_orm/src/base/TableClause.cj:342-344`（`singleList()` → `'id'`）、`f_orm/src/base/TableClause.cj:361-363`（`singlePage(size, page)` → `'id'`）；对照 `f_orm/src/base/TableClause.cj:283/293`（`T.queryMappers().idName ?? 'id'`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符 / 契约不一致」
- **证据**：静态确定 —— 同文件内两种"默认主键列"来源并存：`findById`/`deleteById`/`count` 走 `idName`，`singleList`/`singlePage` 直接用字面量 `'id'`。`README.md:969` 只承诺了前者。
- **描述**：主键列不是 `id`（如 `user_id`）的 PO 调 `singleList()` 会 `select id …` 直接报"列不存在"；而 `findById` 同类调用是正常的。用户必须显式传列名才能用，默认值形同陷阱。
- **建议**：两处都改成 `T.queryMappers().idName ?? 'id'`；`singlePage` 已有泛型约束 `R <: DataFields<R>`，取不到 mapper 时保留 `'id'` 并注释说明。

### [轻微][存量] #21 用例改完全局状态不恢复：`Config` 键、`stuck` 驱动、`MOCKDB.execution` 会泄漏到后续用例

- **位置**：`f_orm/src/base/SqlExecutorConnectingTimeout_test.cj:102-103`（`Config.set([('stuck_orm_connectingTimeout','50')])` + `ORM.register(StuckDriver(), …)` 之后无清理）；同类形态 `f_orm/src/base/SqlResultCache_test.cj:43-50`、`f_orm/src/base/SqlResultCacheStream_test.cj:47-51`、`f_orm/src/base/SqlPartialColumnKey_test.cj:93-99`
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（测试侧）」、§10「可测试性」
- **证据**：静态确定 —— 四个文件都在用例内改写下述之一：进程级 `Config`、`ORM` 的驱动注册表、`MOCKDB` 的全局 `execution` 闭包；`ex.close()` 只收尾 executor，不动这些。`SqlResultCache_test.cj:58-76` 的注释已经承认"executor 与缓存按线程复用，用例之间若共用 SQL 文本会互相污染"，靠"每个用例用不同 SQL 文本"绕开。
- **描述**：用例顺序或并行度一变就互相干扰（例如后续用例用 `mockdb` 默认驱动时被上一个用例的 `execution` 闭包接管）；`stuck_orm_connectingTimeout=50` 留在配置里，其他驱动若同名键会受影响。
- **建议**：`@AfterEach`/`@AfterAll` 里恢复：`Config` 还原原值、`ORM.deregister('stuck')`、`MOCKDB.clear()` + `MOCKDB.execution = 默认`；或把驱动名/SQL 文本改成带用例前缀的唯一值（已有部分用例这么做）。

### [轻微][存量] #22 文件名 `TrsactionHooks.cj` 拼写错误；`@ORMEmbedSensitive()` 落在文件末尾、目标不明确

- **位置**：`f_orm/src/base/TrsactionHooks.cj`（文件名，缺 `n`）；`f_orm/src/base/imports.cj:38`（注解）与其后 `:40` 的 `func emptyLogicalExpr`
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 可维护性」、§1「注解目标待确认」
- **证据**：待确认 —— 文件名拼写静态确定；注解部分：`ORMEmbedSensitive` 展开为 `private let _ = {=> … }`（`f_orm/src/ProtectedMacros/EmbedSensitive.cj:28-52`），是**声明**而不是修饰符，与 `imports.cj:38` 之后隔了一个空行的 `emptyLogicalExpr` 之间是否构成"注解 + 被注解声明"关系，仅靠读代码无法判定（仓内无第二处用法可对照，也没有编译产物可查）。
- **描述**：文件名拼错会让 `grep Trsaction`/按名跳转找不到定义。注解若绑定到 `emptyLogicalExpr`，该函数会被替换成 `private let _`，`TableClause.cj:58` 的调用将无法解析；若是独立宏调用，则它与"敏感配置注册"的语义和所在函数毫无关系，需要一行注释说明为什么放在这里。
- **建议**：文件重命名为 `TransactionHooks.cj`；把 `@ORMEmbedSensitive()` 放到明确的宿主声明上（或单独一个 `Sensitive.cj`），并加注释说明展开结果与放置原因。

### [轻微][存量] #23 `FromClause.deleteById` 返回 `?T`（实为对 DELETE 执行 `first<T>()`），调用方拿不到影响行数

- **位置**：`f_orm/src/base/TableClause.cj:292-300`
- **来源**：存量（`README.md:971` 已把该行为写成"注意事项"）
- **判据**：review-checklist §11「契约与实现不符（返回值语义）」、§10「设计合理性」
- **证据**：静态确定 —— 三个重载都是 `executor.setSql('delete …').first<T>()`，`first` 走查询通道；DELETE 不产生结果集，返回值恒为 `None`（或驱动直接报错），真实的行数被丢弃。同一文件的 `Delete()` 通道（`TableClause.cj:247-252`）返回 `Int64`，说明正确语义是行数。
- **描述**：`deleteById` 看起来"删完返回被删的对象"，实际永远 `None`；业务若用 `if (deleteById(id).isNone()) { 报未找到 }` 会 100% 走进"未找到"分支。README 已提示"日常建议用 `DELETE()`/`executor.delete`"，属于已知设计债。
- **建议**：改成 `Int64`（返回受影响行数），或保留签名但改为 `delete … ; select * …` 两步并在文档里写清；这是一次破坏性 API 变更，需要单列发布说明。

## 优化可行性方案

> 本部分没有 bench / profile 数据；以下两条都只有静态依据，收益必须实测后才能进 `tasks.md`。

### [堆内存] 去掉 `UPDATE` 数组/Map 重载的中间 `HashMap<String, Any>` 拷贝

- **现状**：`UPDATE<T>(values: Array<(Column, Any)>)`、`(Map<Column, Any>)` 及其带 `id` 的版本，先 new 一个 `HashMap<String, Any>`，把每个 `(Column, v)` 的 `name` 重新插入（`SqlPartial.cj:123-143`、`181-187`），随后 `Map` 版本又对它迭代一遍。列数为 N 时每次调用多 N 次装箱 + N 次哈希插入 + 一个容量 ≥N 的表，生命周期仅到本次 UPDATE 结束。
- **方案**：抽出 `private func updateByKeys<T>(lookup: (String) -> Option<Any>, id: …)`，让数组/`Map<Column,Any>` 版本直接提供查找闭包（数组版本可先只做"字段名/列名命中"的一次线性扫描，N 通常 < 20），不再构造中间 map。
- **预期**：每次 UPDATE 少 N 个临时对象与一次哈希表分配；对高频小批量更新（每秒数千次）可减少 young 区分配量。收益上限取决于 UPDATE 调用频次，未测量。
- **代价**：多一层闭包间接调用（`perf §11.3` 提示热路径去抽象，N 大时可能更慢）；需要保序与"后写覆盖先写"的语义（当前 map 版本对同名列是后者覆盖前者）。
- **验证**：`cjpm bench -O2` 跑固定 POJO（15 列）× 10 万次 UPDATE（mockdb 驱动），对照 `getAllocatedHeapSize()` 增量与中位耗时；再在真实 MySQL 上跑 1 万次确认无回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TableMeta.new` 的 `iterator().map().fold()` 两段式构建

- **现状**：列与索引各自走 `iterator().map{…}.fold(ArrayList(), …).unsafeData()`（`TableMeta.cj:38-60`），每个 PO 类型在静态初始化时构造 2 个迭代器链 + 若干闭包，并对每个字段做 1–2 次反射（`getInstanceProperty` → 失败 → `getInstanceVariable`）。PO 数量 M、平均字段 K 时启动期成本 ≈ M×K 次反射 + 2M 条闭包链。
- **方案**：改成一次 `ArrayList` + `for` 追加（`let list = ArrayList<ColumnMeta>(); for (m in …) { if (let Some(c) <- …) { list.add(c) } }`），省掉 `Map/Filter/Fold` 三层闭包与两处 `unsafeData()`；反射部分可先 `typeInfo.getInstanceVariable` 一次（`@DataAssist[fields]` 生成的 PO 多为 `var`），失败再回退 property，减少一半正常路径开销。
- **预期**：启动期反射次数与临时对象数近似减半；对 M 大（数百个 PO）的应用可缩短冷启动。单次成本很低，收益只在启动时可见。
- **代价**：改写顺序敏感（`oldColumnName`/`comment` 的搬运不能漏）；需要保持"字段顺序 = mapper 顺序"。
- **验证**：用 50/200/500 个 PO 的样例模块测冷启动（进程启动到 `ORM.initialize()` 返回）与 `cjprof record` 的 `TableMeta.new` 自耗时；`-O2`、同机器、3 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TableMeta.new` 的反射与闭包链是冷启动可观开销 | `f_orm/src/base/TableMeta.cj:38-60` | 启动 profile、PO 数量与字段数 | 造 200 个 `@QueryMappersGenerator` PO，`cjprof record` 覆盖启动前 3s，看 `TableMeta.new` / `findAnnotation` 自耗时占比 |
| 2 | `appendPartial` 的 `Regex.replaceAll` 在长条件链上占比可观 | `f_orm/src/base/TableClause.cj:56` | 单次调用耗时、每语句调用次数 | 构造 100 段 `AND(...)` 的条件构建循环，`cjpm bench -O2` 对照"预编译常量"与"纯字符串首尾裁切"两版 |
| 3 | `UPDATE` 的中间 `HashMap` 拷贝在批量更新场景产生可见 GC 压力 | `f_orm/src/base/SqlPartial.cj:123-143` | 分配量、GC 次数、UPDATE QPS | mockdb 驱动跑 10 万次 15 列 UPDATE，采 `getAllocatedHeapSize()` 增量与 GC 次数，中位数 3 轮 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/base/SqlExecutorConnectingTimeout_test.cj` | .cj | ✅ | 见 #21（配置/驱动不恢复）；`inTx` 相关无覆盖 |
| 2 | `f_orm/src/base/SqlExecutorStatement_test.cj` | .cj | ✅ | 覆盖 ORM-C4 短 SQL 与 ORM-L6 只缓存 SELECT，与实现一致 |
| 3 | `f_orm/src/base/SqlPartial.cj` | .cj | ✅ | 见 #2、#8、#10；`sqlWithLimit` 隐式返回类型见总评 |
| 4 | `f_orm/src/base/SqlPartialColumnKey_test.cj` | .cj | ✅ | 数组/Map/Column 键等价性用例；未覆盖 #2 的缺列逗号 |
| 5 | `f_orm/src/base/SqlResultCacheStream_test.cj` | .cj | ✅ | 含流不缓存用例，与 `QueryResultWrap.hadStream` 契约一致 |
| 6 | `f_orm/src/base/SqlResultCache_test.cj` | .cj | ✅ | 缓存键内容比较用例；依赖线程内复用语义的注释准确 |
| 7 | `f_orm/src/base/Statement_test.cj` | .cj | ✅ | 测试替身，见 #15；`set/setNull` 空实现 |
| 8 | `f_orm/src/base/TableClause.cj` | .cj | ✅ | 缺陷最集中：见 #3、#4、#11、#13、#16、#17、#18、#20、#23 |
| 9 | `f_orm/src/base/TableMeta.cj` | .cj | ✅ | 见 #7、#9；`ColumnMeta.==` 不含 `comment` |
| 10 | `f_orm/src/base/TableMetas.cj` | .cj | ✅ | 见 #7；`clear()` 用 `unsafeZeroValue` 重置静态表，仓内无调用 |
| 11 | `f_orm/src/base/TableSchema.cj` | .cj | ✅ | 三个注解定义；`comment` 未接线（#9） |
| 12 | `f_orm/src/base/TransactionAspect.cj` | .cj | ✅ | 见 #12；回调只记 start 不记 end/异常 |
| 13 | `f_orm/src/base/TransactionHook.cj` | .cj | ✅ | 见 #1、#5；8 个回调 + `order` 默认值 |
| 14 | `f_orm/src/base/TransactionStatus.cj` | .cj | ✅ | 三值枚举 + 三个 `is*` 断言，与 README 一致 |
| 15 | `f_orm/src/base/Transaction_test.cj` | .cj | ✅ | 测试替身，见 #15；`begin/commit/rollback` 全空实现 |
| 16 | `f_orm/src/base/Transactional.cj` | .cj | ✅ | 见 #12；4 个 getter 仓内零调用（public，不算死代码） |
| 17 | `f_orm/src/base/TrsactionHooks.cj` | .cj | ✅ | 见 #1、#5、#6、#14、#19、#22 |
| 18 | `f_orm/src/base/UpdateResult_test.cj` | .cj | ✅ | 测试替身，见 #15；`lastInsertId/rowCount` 恒为 1 |
| 19 | `f_orm/src/base/converter.cj` | .cj | ✅ | `convert/convertNullable` 的类型匹配分支；`case x: ToString` 分支只做 `case x: T` 类型判定（不是"把字符串解析成 T"），与分支外形暗示的语义不符，但无调用方依赖，未判缺陷 |
| 20 | `f_orm/src/base/imports.cj` | .cj | ✅ | 见 #22；包级 `internal import` 重导出经 `Regex(...)` 等使用方验证为必需 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 23 | #2–#4、#8、#10、#11 属正确性；#12、#18、#23 属设计；#22 属可读性；安全性（注入）专项结论见下 |
| §1 死代码 | 4 | 已逐个符号搜引用：`sqlPartialLog`/`involve`/`involveTable`/`limit`/`sqlWithLimit`/`APPEND_TRIM_*`/`EMPTY_LOGICAL_EXPR`/`emptyLogicalExpr`/`schemas`/`list` 等均有调用者；命中 4 条：#13（不可达分支）、#8（不可达 `else if`）、#14（死类型参数）、#15（仅测试使用的 public 替身，按可见性建议记录）。对外可达的 `public`（`TableClause` 系列子句、`ColumnMeta/IndexMeta`、`ORMConverter`、`Transactional`、`TransactionStatus`）零引用也不判死代码 |
| §2 重复逻辑 | 4 | 已两两比对同文件函数体并按相同错误文案/字面量跨文件搜：命中 #2（UPDATE 两重载同错）、#3（ORDER_BY 与 GROUP_BY）、#4（`TableClause` 与 `Condition` 的 trim 正则漂移）、#18（`findById`/`deleteById`/`Column` 键映射/`IntoClause` 两构造函数）；另 #12 为跨层复制 |
| §3 空实现 | 2 | #1（`inTx` 契约空：接口有默认空实现、框架从不调用）、#7（两处 `catch(_){}` + `register` 只 warn）；`StatementTest.set/TransactionTest.begin` 等测试替身空实现归入 #15；#19 属异常语义问题，记在正确性维度 |
| §4 栈溢出 | 0 | 本部分无递归调用：`TableClause.condition/PAREN` 只调用传入 lambda 一次，`IntoClause.VALUES` 内嵌套函数不递归，`TableMeta.new` 为迭代器链 |
| §5 OOM | 1 | #6（钩子列表随 `initialize()` 次数无界增长）；其余容器均以"每 PO 类型/每列"为界（`TableMetas.schemas`、`ColumnMeta` 数组），无按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`cjpm bench` 数据，未成立任何热点结论；三条线索已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 显式锁，无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 并行批处理 |
| §6.4 低效算法 | 0 | 循环均为 O(列数/Mapper 数)，`sort(list)` 只在注册期；无嵌套扫描、无 `remove(at: 0)`、无循环内字符串 `+`（统一 `StringGenerator`） |
| §7 降堆内存方案 | 1 | 「[堆内存] 去掉 UPDATE 中间 HashMap」（无基线） |
| §8 降 CPU 方案 | 1 | 「[CPU] `TableMeta.new` 迭代器链」（无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象（SQL 片段、`ArrayList`）都逃逸到 executor / 返回值，且峰值内存无对照数据，改造不成立 |
| §11 现有代码的 BUG（存量） | 9 | #2、#3、#4、#8、#9、#10、#11、#12、#23；另外 #6、#7、#19 同时具备并发/错误处理属性 |
| §12 并发安全与锁粒度 | 1 | 共享路径只有 `ORM.hooks.list`（static）与 `TableMetas.schemas`（`ConcurrentHashMap`，写入在静态初始化、读取走迭代器，安全）；命中 #6（注册无同步，与 `ORM.registerTransactionHook` 的 public 入口构成"检查-然后-写入 + 迭代中修改"）。#5 是顺序契约问题，不计入本行 |
| §14 功能完备性与 README 覆盖 | 2 | #1（`inTx` 未实现）、#9（`comment` 未接线）；README 中 `deleteById` 的怪异返回值已在 #23 记录，属"已文档化的债务" |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`，§13 不适用（模块 README/doc 由其他部分覆盖）；20 个 `.cj` 全部逐行读完 |

安全性专项补充（不计入上表）：本部分所有值绑定走 `arg()`/`argNull()`（`SqlPartial.cj:164/166/174/207/209/217/253/264`、`TableClause.cj:283-299/414-420/485`），未发现把外部输入插值进 SQL 的路径；`involve()` 只引用 mapper 的列名（受注解控制）。`WHERE(String)`/`ORDER_BY(() -> String)`/`ON_DUPLICATE_KEY_UPDATE` 等是显式的"原生 SQL 逃生口"，属既定设计，不在本部分判为注入。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 10 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 23 条，是否纳入修复待用户决定（本部分无「本次改动」项，基线为工作区快照）。

## 总评

本部分代码的**主线是链式 DSL 的字符串拼接与事务钩子的分发**，质量不均衡：`SqlPartial`/`TableClause` 的骨架清晰、参数绑定纪律好（全部 `arg()` 占位符，未见注入）、`Partials` 与 `Condition` 两层各司其职；但字符串拼接的边界处有三处成体系的缺陷（#2 的 SET 逗号、#3 的 ORDER BY 空格、#4 的 trim 正则），它们的共同点是"单列/连续列/已裁剪输入"的用例能过，一旦输入形状变化就生成非法 SQL，且没有一条用例守住——本部分的 5 个含用例文件里，没有一个覆盖 `ORDER_BY` 多列或 `UPDATE` 缺列。

**阻塞项**是 #1：`TransactionHook.inTx()` 是从接口到 README 都承诺了的扩展点，实际零调用、零转发，属于"静默失效的公开钩子"，用户代码放进去的上下文绑定/审计永远不会执行；它和 #5（`order` 不生效）叠加后，事务钩子这一整块的可信度都需要重新建立。建议这两条先修，再补一组钩子顺序与触发时机的用例（当前 `TransactionHook` 在仓内没有任何测试）。

**可排期**：`TableMeta`/`TableMetas` 的静默降级（#7）与 `comment` 未接线（#9）属迁移链路，影响面是"建表少列/注释丢失"，建议在动 `migro` 前先修；#8（无列可更新时静默 return 0）、#10（分页参数未校验，构造期抛 `ArithmeticException`）、#11（子句复用后 SQL 带着残留 LIMIT、参数已被清空）修起来都只要几行。重复逻辑（#18）与测试替身外泄（#15）属维护性债务，可随下一次重构一起收。

**未做的部分**：本部分未跑构建与用例（只读审查），所有结论均基于源码；两条性能优化与三条热点假设都没有基线数据，仅作下一轮取证清单。另有两处**范围外提示**（不计入统计）：①`SqlExecutor.waitConnecting()`（`SqlExecutor.cj:400-409`）虽已加超时，仍是**无 sleep 的忙等**，卡在 `Connecting` 的最长 5 秒会烧满一核，与 `SqlExecutorConnectingTimeout_test.cj` 钉住的超时路径叠在一起；②`SqlExecutor.setSql(clearArgsAfterExec: false)` 会把 `clearArgsAfterExec_`（`SqlExecutor.cj:57/872`）留在 `false`，`clearSql()` 的默认参数因此长期偏"不清参数"，`selectPage` 靠显式 `clearSql(clearArgsAfterExec: true)` 兜住——这两处都在第 4 部分的文件里，留给该部分与主 Agent 复核。
