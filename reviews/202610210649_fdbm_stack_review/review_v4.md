# R4: fdbm SQL 层（token / AST / 解析 / 渲染 / 参数绑定 / 方言 / 占位符）

审查时间：2026-10-21

### 审查范围

工作树：`.worktrees/review_fdbm_stack_202610210649`（只读）

- `fdbm/src/sql/token.cj`（词法）
- `fdbm/src/sql/ast.cj`（AST）
- `fdbm/src/sql/SqlParser.cj`（解析器、会话控制快速识别、形状校验）
- `fdbm/src/sql/SqlRenderer.cj`（AST → SQL、引用符重写、字面量渲染）
- `fdbm/src/sql/ParameterBinder.cj`（`?` → 字面量）
- `fdbm/src/sql/PartitionKeyExtractor.cj`（分库键抽取）
- `fdbm/src/sql/Dialect.cj`（方言族与引用符）
- `fdbm/src/sql/placeholder.cj`（包占位）
- 测试：`SqlParser_test.cj`、`SqlSupport_test.cj`、`SqlFeature_test.cj`
- 对照依据：`fdbm/doc/详细设计.md` §8.1/§8.2（另参照 §6.1/§6.2/§9.5）、
  `fdbm/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md`（“SQL 子集与错误码”）、
  `f_dbd/src/common/{payload,error}.cj`、`f_data/src/base/*`（`Data` 族）、`fdbm/src/execute/{dispatcher,executors}.cj`、`fdbm/src/route/router.cj`（调用方语义核对）

### 发现

#### [严重] 非字符串/数值类型的参数绑定后渲染成裸文本，产生非法 SQL

- **位置**：`fdbm/src/sql/SqlRenderer.cj:348-355`（`literal()` 的 `case other => other.toString()`）、`fdbm/src/sql/ParameterBinder.cj:142`
- **描述**：`ParameterBinder` 直接把 `DataAny.data` 塞进 `LiteralExpression`，`SqlRenderer.literal` 只对 `DataString` / `DataReal` / `DataBool` / `DataNone` 有分支，其余类型走 `other.toString()`。协议层 `SqlPayload.add<T>(param: T) where T <: ToData`（`f_dbd/src/common/payload.cj:41-43`）允许任意 `ToData`，因此以下参数都会生成**语法非法**的下推 SQL：
  - `DateTime` → `where created_at = 2026-10-21T06:49:00+08:00`（未加引号、未按方言转义）；
  - `Duration` → `=1d`；
  - `Array<Byte>` / 大对象 → 数组文本（且未做十六进制/bytea 处理）；
  - `DataUnit`、`DataList`/`DataMap` 等 → 集合的调试文本。

  这类错误发生在**渲染之后**，最终以物理库的语法错误（`DB_ERROR`）返回，错误码与文案都不会指出“参数类型不支持”。现有用例只覆盖了 `DataReal` / `DataString`（`SqlSupport_test.cj:31-32`、`62-66`），因此未被发现。
- **建议**：`literal()` 改为穷举分支：`DataDateTime` 按方言输出带引号的字面量（或 `timestamp '...'`）、`DataDuration`/二进制显式拒绝或转十六进制、集合/对象类参数直接抛 `FdbmException(UNSUPPORTED_SQL 或 CONVERSION, ...)`；对未识别 `Data` 实现不要落回 `toString()`。同时补 `DataDateTime` / `DataNone` / `DataBool` / 二进制参数的绑定用例。

#### [严重] 数值字面量经 `Float64` 中转，大整数与高精度小数被静默改写

- **位置**：`fdbm/src/sql/SqlParser.cj:742-755`（`numberOf`）、`fdbm/src/sql/SqlParser.cj:757-770`（`negatedNumberOf`）
- **描述**：解析路径是“`Int64.tryParse` 成功则 `DataReal(Int64)`，否则 `Float64.tryParse` → `DataReal(Float64)`”。于是：
  - `insert into t (amount) values (12345678901234567890)` → 超出 `Int64`，落到 `Float64`，再 `Decimal(Float64)`，写成 12345678901234567000 之类的近似值；
  - `values (123456789012345678.90)` → `Float64` 只有约 15~17 位有效数字，小数部分被破坏。

  该值随后由 `SqlRenderer.literal` 原样下推写入物理库，属于**静默的数据失真**（无错误码、无日志）。`f_data` 已提供 `DataReal(data: String)`（`f_data/src/base/DataReal.cj:68-70`，内部走 `Decimal.parse`），实现没有利用。
- **建议**：整数字面量用 `BigInt`/`Decimal` 承载；含小数点或指数的字面量直接用 `DataReal(token.text)`（`Decimal.parse`）保留原文精度，仅当解析失败时抛 `SQL_SYNTAX`；补大整数、高精度小数、`1e3`、负数边界的渲染往返用例。

#### [严重] 派生表形状校验只覆盖 SELECT 的 `from` 列表，JOIN 与 UPDATE/DELETE 中的派生表被放行

- **位置**：`fdbm/src/sql/SqlParser.cj:247-294`（`validateSelectShape`，统计只遍历 `statement.from`，`derivedCount == 0` 时在 `273` 直接返回）；`fdbm/src/sql/SqlParser.cj:348-367`（`joinClause` 复用 `tableRef()`，允许派生表）；`fdbm/src/sql/SqlParser.cj:449-499`（`update`/`delete` 完全不调用形状校验）
- **描述**：设计 §8.1/§8.2 与错误码表明确要求“派生表外层只允许「唯一派生表 + 列清单 + 可选 limit/offset」”、“派生表外层带 where / JOIN / order by / distinct / group by → `UNSUPPORTED_SQL`”。实际实现只对 `from` 列表计数，以下语句都能通过解析：
  - `select * from u join (select * from t where id = 5) c on u.tid = c.id`（派生表在 JOIN 中）；
  - `update t join (select * from u) x on t.id = x.id set t.name = 'a'`；
  - `delete from t join (select * from u) x on t.id = x.id`。

  后果有三层：① 错误码从 `UNSUPPORTED_SQL` 变成执行期的广播 / `ROUTE_FAILED`；② `PartitionRouter.selectConstraint`（`route/router.cj:285-293`）只沿 `statement.from` 递归，JOIN 中的派生表条件被完全忽略，SELECT 会走 `Unroutable → 全库广播`，跨分片 JOIN 的结果可能静默缺行；③ 派生表 `TableRef` 的占位 `name` 是 `''`（`fdbm/src/sql/SqlParser.cj:790`），`UpdateStatement.tables` / `DeleteStatement.tables`（`ast.cj:389-398`、`418-427`）不做 `collectTables()` 展开，空表名会进入路由查规则。现有用例 `SqlFeature_test.cj:194-205` 只覆盖了“外层 from 为派生表 + join”的反向形状，未覆盖“派生表位于 join”。
- **建议**：把派生表校验提升为独立 `validateNoDerivedInJoin(joins)`，在 `select`/`update`/`delete` 的 JOIN 解析处以及 `tableRef(allowAlias: true)` 的派生分支统一拒绝（`UNSUPPORTED_SQL`）；同时让 `Update/DeleteStatement.tables` 用 `collectTables()` 展开（或显式禁止）。补上述三条语句的错误码用例。

#### [一般] `WHERE` 中的非派生表子查询返回 `SQL_SYNTAX`，与设计要求的 `UNSUPPORTED_SQL` 不符

- **位置**：`fdbm/src/sql/SqlParser.cj:633-642`（`inExpression` 直接 `expression()`）、`fdbm/src/sql/SqlParser.cj:731-736`（`factor` 把 `select` 当普通标识符）
- **描述**：设计 §8.1 写明“派生表以外的子查询 … 一律不支持 → 报 `UNSUPPORTED_SQL`（错误文案给出语句位置）”，主规范 `fdbm/spec.md:392` 同款要求。实际行为：
  - `select * from t where id in (select id from u)` → `inExpression` 把 `select` 解析成 `ColumnExpression`，随后 `expect(RParen)` 失败，抛 `SQL_SYNTAX`；
  - `select * from t where exists (select 1 from u)`、`select (select 1)` 同样落到 `SQL_SYNTAX`。

  用例 `SqlParser_test.cj:183-188` 只验证了 `union` 与 `group by`，没有覆盖子查询。
- **建议**：在 `factor`/`inExpression`/`tableRef` 的括号入口处统一识别 `select`（以及 `with`）并抛 `UNSUPPORTED_SQL`；补三个子查询形状的错误码断言。

#### [一般] 引用别名与库限定名的引用符在 AST/渲染中丢失，`parse → render → parse` 不闭合

- **位置**：`fdbm/src/sql/SqlRenderer.cj:56-59`（`SelectItem.alias` 直接拼裸名）、`fdbm/src/sql/SqlRenderer.cj:268-275`（`table.database` 与 `table.alias` 直接拼接）、`fdbm/src/sql/ast.cj:274`（`SelectItem.alias: ?String`）、`fdbm/src/sql/ast.cj:192-210`（`TableRef` 只记录表名 `quoted`）
- **描述**：解析器允许引用别名（`expectIdent` 接受带引号的 `Ident`），但 AST 只保存裸字符串，渲染时不再加引用符。于是：
  - `select id as "order" from t` → 渲染 `select id as order from t`，再次解析即语法错误；
  - `select * from "shop"."T" as "select"` → 渲染 `shop.T as select`：schema 的引用符丢失导致 PostgreSQL 折叠成小写，语义改变甚至找不到表；别名同样丢失。

  `SqlSupport_test.cj:180-203` 的往返用例只用了未引用的别名与未限定的表名，因此未暴露。
- **建议**：`SelectItem.alias` 与 `TableRef.alias` 改为 `?Identifier`（或增加 `aliasQuoted`），`TableRef` 增加 `databaseQuoted`；渲染时统一走 `renderIdentifier` / `quoteIdentifier`。补“引用别名 + 引用 schema”的往返用例。

#### [一般] `ColumnExpression` 只有一个 `quoted` 标志，渲染时把表名一起引用

- **位置**：`fdbm/src/sql/SqlRenderer.cj:288-303`；来源 `fdbm/src/sql/ast.cj:95-106`、`fdbm/src/sql/SqlParser.cj:731-735`（`quoted: token.quoted || column.quoted`）
- **描述**：`select t."COL" from t` 解析后 `quoted = true`（来自列名），渲染成 `"t"."COL"`。表名本来未引用，改写后在 PostgreSQL 里表名保持大小写（原本裸名会被折叠），语义被改变；`"T".COL` 同理变成 `"T"."COL"`，把列名也强制成区分大小写。这是“只重写引用标识符的引用符”原则的偏差（设计 §8.2 末段）。
- **建议**：拆成 `tableQuoted` / `columnQuoted` 两个标志（AST 变更），渲染时分别决定；否则至少在渲染时仅对确实来自引用符的一侧加引用。

#### [一般] 标识符比较大小写敏感，导致 `WHERE ID = 5` 这类语句无法路由（DML 直接失败）

- **位置**：`fdbm/src/sql/ast.cj:85-91`（`Identifier.==` / `equalsName` 精确比较）、`fdbm/src/sql/PartitionKeyExtractor.cj:92-108`（`c.column != column`）、调用方 `fdbm/src/route/router.cj:297`（传 `rule.table`）与 `router.cj:349`（`statement.columns[i].name == rule.column`）
- **描述**：设计 §8.2 声明“标识符大小写不敏感（保留原始拼写用于下推 SQL）”。实现只对关键字做了 `toUpper`，标识符一律精确比较。MySQL 的列名本身大小写不敏感，客户端写 `update t set name='x' where ID = 5` 完全合法，但 fdbm 抽不到分库键 → `UPDATE` 判 `Unroutable` → `ROUTE_FAILED`；`INSERT INTO t (ID) VALUES (5)` 同样失败。SELECT 则退化为全库广播（结果正确但代价高）。测试没有覆盖任何大写标识符。
- **建议**：在分库键匹配 / 列名匹配处使用大小写不敏感比较（或在解析时保留原名、比较时 `toLower`），引用标识符（`quoted == true`）保持精确比较；补 `WHERE ID = ?`、`insert into t (ID)` 的路由用例。

#### [一般] 别名限定的分库键抽取不到（`from users u where u.id = 5` 被判不可路由）

- **位置**：`fdbm/src/sql/PartitionKeyExtractor.cj:98-105`、调用方 `fdbm/src/route/router.cj:297`（`Some(rule.table)`）
- **描述**：`matches` 要求限定名与传入的 `table` 完全相等，而路由器传入的是规则里的**裸表名**。当语句使用别名并以其限定分库列（ORM 生成的 SQL 很常见）时，`u.id` ≠ `users` → 抽不到值 → `UPDATE`/`DELETE` 报 `ROUTE_FAILED`，SELECT 全库广播。用例 `SqlSupport_test.cj:91-95` 通过手工传 `Some('x')` 演示了“别名可用”，恰好掩盖了调用方不会传别名的事实。
- **建议**：`extract`/`extractRange` 接受别名集合（或接受 `TableRef` 而非表名字符串），由路由器传入 `TableRef.name` + `alias`；补 `from t x where x.id = 5` 的端到端路由用例。

#### [一般] MySQL 家族字符串参数只做 `''` 转义，未处理反斜杠

- **位置**：`fdbm/src/sql/SqlRenderer.cj:358-360`（`quoteText`）
- **描述**：MySQL 默认 `sql_mode` 下反斜杠是字符串转义符。参数值以 `\` 结尾时（如 Windows 路径 `C:\`），`'\'` 会把闭合引号转义掉，字面量无法闭合，语句报语法错误；值中含 `\'` 组合时字面量边界会偏移（参数由发起 SQL 的同一客户端提供，因此不构成越权注入，但会破坏合法数据/语句）。
- **建议**：按方言转义——MySQL 额外把 `\` 转成 `\\`（或在连接初始化时设置 `NO_BACKSLASH_ESCAPES`），PostgreSQL 保持 `''`；补含反斜杠参数的渲染用例。

#### [一般] 逻辑库限定名原样下推，未按目标物理库重写（跨层，需与执行层确认）

- **位置**：`fdbm/src/sql/SqlRenderer.cj:268-271`（`table.database` 直接拼接）、`fdbm/src/execute/executors.cj:224`（对每个物理库复用同一份渲染结果）
- **描述**：`TableRef.database` 是**逻辑库**（`PartitionRule.database`，配置项 `fdbm_db_logicalDatabase_<logical>` 与 `fdbm_db_database_<node>` 是两套名字，见设计 §3.1）。渲染器把它原样写进 SQL，执行器却把同一份 SQL 发到各物理库连接。只要逻辑库名 ≠ 物理库名且客户端显式限定了库名（`select * from shop.t where id = 1001` 命中物理库 `db1`），下推语句会去读 `shop.t` 而不是 `db1.t`：轻则报表不存在，重则读到错误分片的数据。E2E 全部使用未限定表名（`fdbm/test/e2e/client/src/main.cj`），因此未覆盖。
- **建议**：在渲染前按目标物理库替换/删除逻辑库限定（推荐 `TableRef` 携带 `logical`，渲染时输出物理库名或省略限定），并在 R5 执行层复核；补“显式逻辑库限定 + 多物理库”用例。

#### [轻微] `render` 兜底分支静默产出空 SQL

- **位置**：`fdbm/src/sql/SqlRenderer.cj:39`、`fdbm/src/sql/SqlRenderer.cj:344`
- **描述**：未知语句/表达式返回 `''`，一旦 AST 扩展而忘记补分支，会把空串下发到物理库（错误信息远离根因）。
- **建议**：兜底改为抛 `FdbmException(INTERNAL/UNSUPPORTED_SQL, ...)`；`SqlStatement` 是封闭集合时也可去掉兜底让编译器检查穷尽性。

#### [轻微] `FunctionExpression` 是死代码，渲染分支永不触发

- **位置**：`fdbm/src/sql/ast.cj:162-170`、`fdbm/src/sql/SqlParser.cj:721-729`、`fdbm/src/sql/SqlRenderer.cj:330-341`、`fdbm/src/sql/ParameterBinder.cj:153-158`
- **描述**：函数调用在 `factor` 中解析完实参后**立即**抛 `UNSUPPORTED_SQL`，`FunctionExpression` 从不被构造；`renderer`/`binder` 中的对应分支与“仅用于识别后报错”的注释不符（注释说用于识别，实际未使用）。
- **建议**：删除 `FunctionExpression` 及其分支，或改为构造后由形状校验统一拒绝（保留可测试的 AST 语义）。

#### [轻微] 形状校验的错误位置指向语句末尾，而非出错构造

- **位置**：`fdbm/src/sql/SqlParser.cj:260-292`（6 处 `peek().position`）
- **描述**：`validateSelectShape` 在所有 `unsupported(...)` 中统一用 `peek().position`。校验发生在 `select()` 返回前，`peek()` 通常已是 `limit`/EOF 等后继 token，错误文案位置与真正越界的 `count(*)`/派生表位置无关，主规范要求“错误文案含位置信息”只能算形式上满足。
- **建议**：把 `SelectStatement` 中相关节点的位置（或至少 `from`/`columns` 的起始 token 位置）带进校验函数。

#### [轻微] `INSERT` 未校验列数与值行长度一致

- **位置**：`fdbm/src/sql/SqlParser.cj:371-414`（`columns`、`values`、`valueRow` 各自独立解析，未交叉校验）
- **描述**：`insert into t (a, b) values (1)`、`insert into t (a) values (1, 2)` 都能通过解析并下推，最终由物理库报错（`DB_ERROR`），与“形状校验在下推前完成”的设计意图不一致；多行值长度不一致也无法在解析期发现。
- **建议**：`InsertStatement` 构造前校验每行 `size == columns.size`（`columns` 非空时），不一致抛 `SQL_SYNTAX`；`columns` 为空时校验各行等长。

#### [轻微] `LIMIT`/`OFFSET` 参数无类型校验

- **位置**：`fdbm/src/sql/ParameterBinder.cj:69-70`、`fdbm/src/sql/SqlParser.cj:296-305`、`fdbm/src/sql/SqlRenderer.cj:102-109`
- **描述**：`limit`/`offset` 的 `?` 绑定成任意 `Data` 后直接渲染，例如字符串参数会得到 `limit '10'`、`DateTime` 参数得到 `limit 2026-...`。设计只约定“整数或 `?`（绑定后为整数字面量）”，实现未在绑定阶段保证这一点。
- **建议**：绑定后对 `limit`/`offset` 做整数可解析校验（失败抛 `PROTOCOL` 或 `SQL_SYNTAX`），并补负数/非整数参数用例。

#### [轻微] 每条非会话语句被词法分析两次

- **位置**：`fdbm/src/sql/SqlParser.cj:44-50`（先 `parseSessionCtl(sql)` 内部 `Lexer(sql).tokenize()`，再 `Lexer(sql).tokenize()` 走完整解析）
- **描述**：会话控制快速路径对**所有** SQL 都会先完整 token 化一遍，随后主解析再 token 化一遍；对长 SQL（大 `IN` 列表、批量 INSERT）是纯重复开销，也与“快速识别、避免走复杂路径”的目标相悖。
- **建议**：让 `parseSessionCtl` 复用已产生的 token 数组（新增内部 `parseTokens`），或在 `parse` 中先做首 token 关键字预判再决定是否调 `parseSessionCtl`。

#### [轻微] 若干“额外支持/非标准渲染”未在设计中登记

- **位置**：`fdbm/src/sql/SqlParser.cj:149-152`（额外接受 `drop`/`truncate` 透传）、`fdbm/src/sql/SqlParser.cj:348-359`（JOIN 的 `on` 可省略）、`fdbm/src/sql/SqlParser.cj:213-233` / `485-499`（`delete from t join ...`，该写法不是 MySQL 合法多表删除语法）、`fdbm/src/sql/SqlRenderer.cj:236-251`（`show tables <db>` 渲染为非标准语法，当前仅本地执行未下推）
- **描述**：设计 §8.1 只登记 `CREATE TABLE`/`ALTER TABLE` 透传，未登记 `drop`/`truncate`；也未说明 JOIN 允许无 `ON`、DELETE 支持 JOIN。额外能力本身不一定有害，但属于“文档承诺与实现不一致”，且 `join` 无 `ON` 会渲染成隐式 CROSS JOIN，容易放大结果集。
- **建议**：要么在设计 §8.1 补齐并加用例，要么收紧解析（`on` 必填、`delete ... join` 拒绝）；`renderShow` 若只服务往返测试，建议注明“不用于下推”。

### 覆盖矩阵（功能完备性 / 测试覆盖）

| 设计条目（§8.1/§8.2） | 实现 | 用例 | 结论 |
| --- | --- | --- | --- |
| SELECT 列清单 / `*` / distinct / 多表 / `[inner\|left\|right] join on` / where / order by / limit / offset / `?` | `SqlParser.cj:182-239`、`SqlRenderer.cj:43-111` | `SqlParser_test.cj:29-61`、`SqlSupport_test.cj:181-203` | 覆盖充分 |
| `count(*)`（唯一聚合）与四类禁用组合 | `SqlParser.cj:713-720`、`247-272` | `SqlFeature_test.cj:177-185` | 覆盖充分 |
| 受限派生表（唯一 from 项 + 列清单 + limit/offset） | `SqlParser.cj:774-793`、`247-294` | `SqlFeature_test.cj:165-205` | **有缺口**：JOIN 内派生表未校验（严重#3） |
| `INSERT` values 多行 / set / select / returning | `SqlParser.cj:371-428` | `SqlParser_test.cj:94-108`、`SqlFeature_test.cj:135-157` | 覆盖充分（列数一致性未校验） |
| `UPDATE`（含 join）/ `DELETE` | `SqlParser.cj:449-499` | `SqlParser_test.cj:111-122` | 主路径覆盖；派生 JOIN 未拒绝 |
| `SHOW DATABASES` / `SHOW TABLES [db] [LIKE]` | `SqlParser.cj:503-521`、`SqlRenderer.cj:236-251` | `SqlParser_test.cj:125-136` | 覆盖充分（渲染语法非标准） |
| `CREATE/ALTER` 透传 | `SqlParser.cj:523-546` | `SqlParser_test.cj:139-146` | 覆盖充分（`drop`/`truncate` 未登记） |
| `EXPORT k=v` | `SqlParser.cj:548-561` | `SqlParser_test.cj:149-156` | 覆盖充分 |
| 会话控制（begin/start/commit/rollback/savepoint/rollback to/release） | `SqlParser.cj:59-129` | `SqlParser_test.cj:159-180` | 缺 `rollback to <sp>`（无 `savepoint` 关键字）、`release savepoint <sp>`、`commit work` 用例 |
| 错误码表（returning / count / 派生表） | 解析层 `SqlParser.cj`；returning 与多库判定在 `execute/executors.cj:754-823` | `SqlFeature_test.cj:148-205`、`ExecutorFeature_test.cj:43-133` | 基本对齐；子查询错误码不符（一般#1） |
| 引用标识符（`"..."` / `` `...` ``）+ 方言重写 | `token.cj:168-221`、`Dialect.cj:46-63`、`SqlRenderer.cj:278-284` | `SqlFeature_test.cj:28-58`、`241-278` | 主路径覆盖；别名/库名/列名引用语义有缺口 |
| `X'...'` 方言渲染 | `token.cj:126-141`、`SqlRenderer.cj:305-309` | `SqlFeature_test.cj:78-93` | 覆盖充分 |
| `?` 顺序绑定与个数校验 | `ParameterBinder.cj:29-37`、`134-161` | `SqlSupport_test.cj:28-69`、`SqlFeature_test.cj:213-234` | 仅 `Real/String`；其他 `Data` 类型缺失（严重#1） |
| 分库键抽取：等值 / IN / 范围 / BETWEEN / 保守 OR·NOT | `PartitionKeyExtractor.cj:65-137`、`152-315` | `SqlSupport_test.cj:76-173` | 覆盖较好；大小写、别名限定、`Int64` 边界缺口 |
| 数值字面量 | `SqlParser.cj:742-770` | 仅整数/简单小数 | 精度缺口（严重#2） |
| 边界：空 SQL / 未闭合引号 / 未闭合注释 / 多语句 | `SqlParser.cj:156-172`、`token.cj:100-123`、`142-221` | `SqlParser_test.cj:191-196`、`SqlFeature_test.cj:91-99` | 空 SQL、未闭合引号已覆盖；**未闭合块注释、`;` 后多语句、纯注释 SQL 无用例** |
| 边界：负数 limit / `limit a,b` / 大小写关键字 / `--` 与 `/* */` 注释 | `SqlParser.cj:221-234`、`303-305`；`token.cj:100-125` | 无 | **测试缺口** |

**测试充分性结论**：`fdbm/src/sql` 共 52 个 `@TestCase`（`SqlParser_test` 13、`SqlSupport_test` 16、`SqlFeature_test` 23），全部含 `@Assert`，**未发现空测试、无断言测试、被禁用/跳过的测试**；`placeholder.cj` 仅有包声明，是各包统一的占位文件（`route/execute/resources` 同样存在），不计为缺陷。主要缺口集中在“非标量参数 / 数值精度 / 引用符往返 / 大小写与别名 / 派生表在 JOIN / 注释与多语句 / 上表末两行的边界项”。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 3 |
| 一般 | 7 |
| 轻微 | 7 |

### 总评

SQL 层的骨架与设计 §8.2 高度吻合：词法（引用标识符、`''` 转义、`X'...'`、两种注释）、递归下降、`BETWEEN` 展开、`NotExpression`、形状校验、方言族映射与 `ParameterBinder` 的个数校验都实现得干净，错误码与文案位置信息基本到位，测试覆盖主路径且无空/跳过用例。`parseSessionCtl` 的形态匹配对 `rollback to [savepoint] x` / `release [savepoint] x` 的处理也正确（含尾部分号裁剪）。

但仍有 3 处影响数据正确性的硬缺陷：**非标量参数渲染成裸文本**（DateTime/二进制/集合参数直接产生非法 SQL）、**数值字面量经 `Float64` 中转造成大整数/高精度小数静默失真**、**派生表校验只覆盖 `from` 而放过 JOIN 与 UPDATE/DELETE 中的派生表**（会把设计明确禁止的形状放行到广播执行）。这三点建议在合入前修复，并各配一条回归用例。

其余问题集中在“引用符与别名在 AST 中的保真度”与“标识符比较口径”两条线上：渲染器只重写表名/列名的单一 `quoted` 标志，别名与库限定名的引用信息在解析时即被丢弃，导致 `parse → render → parse` 对含引用别名的语句不闭合（现有往返用例恰好未覆盖）；`matches`/`Identifier.==` 精确比较与小写裸表名，使 `WHERE ID = 5`、`from users u where u.id = 5` 这类合法语句在写入路径被判 `ROUTE_FAILED`。这两处不改变主流程，但会直接表现为“本该成功的语句失败”，建议与路由层一并修正。

文档一致性方面，子查询错误码（`SQL_SYNTAX` vs 规范要求 `UNSUPPORTED_SQL`）、`drop`/`truncate` 与 `delete ... join` 等额外语法未在设计 §8.1 登记，属于需要补齐文档或收紧实现的小偏差；逻辑库限定名是否应改写为物理库名，需 R5 结合执行层给出定论。
