# fdbm 模块审查报告（第 6/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fdbm`（本部分覆盖 `src/sql/` 尾部 6 个文件 + `test/e2e` 联调夹具 7 个文件，共 13 个）
- **基线**：工作区快照（HEAD `f309f0b55`，源码无改动，仅 `docs/review/`、`reviews/` 未跟踪）⇒ 所有问题来源记「存量」
- **审查重点**：多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑（本部分实际落在 SQL 解析/渲染边界与 e2e 夹具上）
- **报告版本**：v1（分部分报告，供主 Agent 合并；不覆盖 `docs/review/` 下的模块报告）

## 发现

### [一般][存量] UPDATE / DELETE 的 JOIN 只按 MySQL 形状渲染，方言参数被忽略

- **位置**：`fdbm/src/sql/SqlRenderer.cj:190-202`（`renderUpdate` 的 join 段）、`fdbm/src/sql/SqlRenderer.cj:225-237`（`renderDelete` 的 join 段）
- **来源**：存量（快照无基线；`git blame` 到 `c81e5dcc2a 2026-10-18`）
- **判据**：review-checklist §11「契约与实现不符」+ §13；承诺源 `doc/详细设计.md:571`（`update t join ... set ...`，多表更新按 JOIN 收敛规则路由）、`doc/开发计划.md:99-100`（UPDATE/DELETE 的 join 用例）
- **证据**：静态确定 —— `renderUpdate`/`renderDelete` 的 join 段没有任何 `dialect` 分支，`SqlDialect.Postgres` 与 `SqlDialect.MySql` 输出同一句 `update t inner join u on … set …` / `delete from t inner join u on …`；下推侧直接取该字符串下发（调用方 `fdbm/src/execute/executors.cj:518`、`fdbm/src/execute/executors.cj:588`，无方言拦截）
- **描述**：`UPDATE … JOIN … SET` 是 MySQL 家族语法；PostgreSQL 家族需要 `UPDATE t SET … FROM u WHERE …`。`DELETE FROM t JOIN u ON …` 在两种方言里都不成句（MySQL 需要 `DELETE t FROM t JOIN u …` 或 `DELETE FROM t USING t JOIN u …`）。因此契约里承诺的「带 join 的更新/删除」一旦落到 PG 物理库上必然在 DB 侧报语法错误，`DB_ERROR`；该路径在 e2e 里从未被执行（`fdbm/test/e2e/client/src/main.cj:619-624` 的 DELETE 无 join，`fdbm/test/e2e/client/src/main.cj:675-677` 的 UPDATE 无 join），只有解析用例 `fdbm/src/sql/SqlParser_test.cj:211-215` 覆盖了「能解析」
- **建议**：`renderUpdate`/`renderDelete` 增加方言分支（PG 走 `FROM`/`USING` 形式）；无法等价改写时在渲染阶段抛 `UNSUPPORTED_SQL`（与 `DbdErrorCode` 现有口径一致），并补一条 PG/MySQL 双后端「join 更新、join 删除」的 e2e 用例

### [一般][存量] 派生表嵌套的递归没有深度上限

- **位置**：`fdbm/src/sql/SqlRenderer.cj:47` ↔ `fdbm/src/sql/SqlRenderer.cj:262`（`renderSelect`/`renderTable` 互递归）；`fdbm/src/sql/ast.cj:240-245` ↔ `fdbm/src/sql/ast.cj:338-353`（`TableRef.collectTables`/`SelectStatement.tables` 互递归）
- **来源**：存量
- **判据**：review-checklist §4「无界递归」
- **证据**：静态确定（两处递归都没有深度计数、没有层数上限）；崩溃阈值需实测
- **描述**：递归深度 = `from (select … from (select …)) as x` 的嵌套层数，完全由客户端 SQL 文本决定（每层约 6 字节），`tables` 每次访问还会每层新建 `ArrayList` + `toArray`。解析器侧同类递归（`SqlParser` 派生表解析）也在此链路上，三层递归（解析 → 绑定 `ParameterBinder.bindTable` → 渲染/收集）深度相同
- **建议**：在派生表解析处加显式层数上限（如 8 层）并抛 `UNSUPPORTED_SQL`；或在 `renderTable`/`collectTables` 改为带深度参数的迭代实现

### [轻微][存量] 渲染器缺省分支静默返回空串

- **位置**：`fdbm/src/sql/SqlRenderer.cj:43`（`case _ => ''`）、`fdbm/src/sql/SqlRenderer.cj:355`（`case _ => ''`）
- **来源**：存量
- **判据**：review-checklist §3「空实现 / case None => () 吞掉错误」
- **证据**：待确认 —— `SqlStatement` 现有 8 个实现、`SqlExpression` 现有 10 个实现全部被前面分支覆盖，只有新增实现才会落到缺省分支；`protected interface` 未 `sealed`，子包仍可实现
- **描述**：新增一个语句/表达式实现而忘记补渲染分支时，`render` 会产出空串并照常下发（`executors.cj` 只 `prepareStatement(sql)`），失败点被推迟到物理库，且错误信息与真实原因无关。同一问题的反例是 `fdbm/src/execute/dispatcher.cj:91` 对未识别语句直接抛 `UNSUPPORTED_SQL`
- **建议**：缺省分支改为 `throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL, 'unsupported statement/expression')`，与 dispatcher 口径统一

### [轻微][存量] 死代码：`SqlKind` 枚举与 8 个 `kind` 属性全仓无引用

- **位置**：`fdbm/src/sql/ast.cj:22-24`（`protected enum SqlKind`）、`fdbm/src/sql/ast.cj:303-306`（接口声明）、`fdbm/src/sql/ast.cj:332-336`、`376-380`、`403-407`、`432-436`、`476-480`、`498-502`、`523-527`、`566-570`（8 个实现的 `public prop kind`）
- **来源**：存量（`git blame` 到 `c81e5dcc2a 2026-10-18`）
- **判据**：review-checklist §1 硬原则二（顶层声明 `SqlStatement` 是 `protected`，其成员对外不可达，全项目无使用即死代码）
- **证据**：静态确定 —— `grep -rn "SqlKind" fdbm/` 仅命中 `ast.cj` 自身；`grep -rn "\bkind\b" fdbm/src fdbm/test` 命中的全是 `IdMakerConfig.kind`、`RoutePlan.kind`、`RouteAlgorithm.kind`，没有一处读 `statement.kind`
- **描述**：语句种类判别的职责已由 dispatcher 的类型 `match`（`fdbm/src/execute/dispatcher.cj:82-92`）与各 executor 承担，`SqlKind` 是残留判别维度，10 处声明（枚举 + 接口 `prop` + 8 个实现）维护成本纯支出
- **建议**：删除 `SqlKind` 与 8 个 `kind` 实现（接口里的 `prop kind` 一并去掉）；若确实想留作对外契约，需先把类型改成 `public` 并在 README 登记

### [轻微][存量] `placeholder.cj` 是只有版权头的空文件

- **位置**：`fdbm/src/sql/placeholder.cj:1-16`
- **来源**：存量
- **判据**：review-checklist §1「兼容残留」/ §14「半成品」
- **证据**：静态确定 —— 全文 16 行 = Apache 版权头 + `package fountain::fdbm.sql`，没有任何声明
- **描述**：占位符逻辑实际在 `fdbm/src/sql/ParameterBinder.cj`（`bind`/`bindExpression`），本文件从无内容
- **建议**：删除该文件（`cjpm` 会照常构建），或补一句「占位符逻辑见 ParameterBinder.cj」的说明避免后续误加代码

### [轻微][存量] `--` 一律当行注释，与两种方言的词法都不一致

- **位置**：`fdbm/src/sql/token.cj:100-107`
- **来源**：存量
- **判据**：review-checklist §11「语义与命名/注释不符」+「错误处理静默」
- **证据**：静态确定 —— 只要出现连续 `--` 就跳到行尾，不检查后随字符；MySQL 要求 `--` 后跟空白/行尾才是注释，否则是「减负号」运算
- **描述**：`select * from t where id = 1--2` 在 fdbm 里被截成 `where id = 1`（条件被静默放宽，`render` 后实际下发的 SQL 与客户端意图不符），在 MySQL 里等价于 `id = 1 - (-2)`。是否可达取决于客户端是否走这条路径（`f_orm` 生成的语句不产生 `--`）→ 影响面待确认，故按轻微记
- **建议**：与 MySQL 对齐（要求 `--` 后为空白或行尾）或直接对 `--` 报 `SQL_SYNTAX`；不要保留「静默截断」语义

### [轻微][存量] SHOW 丢弃库名的引用符

- **位置**：`fdbm/src/sql/ast.cj:467`（`ShowStatement.database: ?String`，无 `databaseQuoted`）、`fdbm/src/sql/SqlRenderer.cj:250-253`
- **来源**：存量
- **判据**：review-checklist §13（与 `TableRef.databaseQuoted` 的 G18 口径不一致，`fdbm/src/sql/ast.cj:203`）
- **证据**：待确认 —— 生产路径由 `ShowExecutor` 直接生成内省 SQL（`fdbm/src/execute/executors.cj:1135` `tablesSql`），`renderShow` 实际只被测试经 `SqlRenderer.render` 触达；`show tables "App"` 渲染成 `show tables App`，`parse → render → parse` 后库名大小写/空格丢失
- **描述**：解析器接受引用标识符形式的库名（`fdbm/src/sql/SqlParser.cj:546-547`），但 `ShowStatement` 只存裸名，引用信息在 AST 里就丢了，渲染无法还回
- **建议**：`ShowStatement` 增加 `databaseQuoted`（或存 `Identifier`），与 `TableRef` 保持同一口径；若确定不支持引用形式，在解析处直接报 `UNSUPPORTED_SQL`

### [轻微][存量] 重复逻辑：`renderName` 与 `renderIdentifier` 逐行等价

- **位置**：`fdbm/src/sql/SqlRenderer.cj:291-297` 与 `fdbm/src/sql/SqlRenderer.cj:299-305`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 两者都是「`quoted` 为真 → `SqlDialects.quoteIdentifier(name, dialect)`，否则原文」，输入只差「`String`+`Bool`」还是「`Identifier`」
- **描述**：同一 G18 规则两处实现，改引用符策略时必须同步改两处
- **建议**：`renderIdentifier` 改成 `renderName(identifier.name, identifier.quoted, dialect)`（一行转发），保留语义零变化

### [轻微][存量] 重复逻辑：字面量规则（十六进制方言分支、可字面化类型白名单）各写两遍

- **位置**：`fdbm/src/sql/SqlRenderer.cj:316-320`（`HexLiteralExpression` 的 `X'..'` / `'\x..'`）与 `fdbm/src/sql/SqlRenderer.cj:413-423`（`byteLiteral` 同一分支）；`fdbm/src/sql/SqlRenderer.cj:370-381`（`literal` 的 6 个 case）与 `fdbm/src/sql/SqlRenderer.cj:384-394`（`isLiteral` 的同 6 个 case）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」
- **证据**：静态确定 —— 两处方言分支字符串完全相同；两份白名单 arm 一一对应
- **描述**：白名单漂移时是 fail-closed（`ParameterBinder` 先 `isLiteral`，`fdbm/src/sql/ParameterBinder.cj:146`），但漂移方向不同会导致错误码/时机不同（绑定期 `CONVERSION` vs 渲染期 `CONVERSION`），排查时容易误判。十六进制分支漂移则直接产出错误 SQL
- **建议**：`byteLiteral` 改为复用一个 `hexLiteral(hex, dialect)`；`isLiteral` 反过来「`try literal` 前先查表」不太合适，可抽 `private func literalKind(data): ?LiteralKind` 供两者共用

### [轻微][存量] 重复逻辑：SHOW 有两条实现，未使用的那条语法已漂移

- **位置**：`fdbm/src/sql/SqlRenderer.cj:245-260`（`renderShow`，含 `show tables ${database} like …`）与 `fdbm/src/execute/executors.cj:1135`（`tablesSql`，实际生产路径）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制」+ §1「仅测试使用」（`renderShow` 仓内生产无调用者，dispatcher 把 `ShowStatement` 交给 `ShowExecutor`，`fdbm/src/execute/dispatcher.cj:87`）
- **证据**：静态确定 —— `SqlRenderer.render` 的调用点全部传具体 DML 类型（`executors.cj:293/376/458/518/588/623/762/996/1010`），唯一覆盖 SHOW 的是测试 `fdbm/src/sql/SqlSupport_test.cj:231-232`
- **描述**：`show tables db1 like 'a%'` 不是合法 MySQL（缺 `FROM`/`IN`），而真实路径用 `information_schema` 拼串，两条实现的语义已经不一致；后续若有人「复用渲染器」就会踩到坏掉的那条
- **建议**：删掉 `renderShow` 与 `render` 的 SHOW 分支（并同步删 `SqlSupport_test` 的往返用例），或让 `ShowExecutor` 复用它并把语法改成分方言的 `show tables from …`

### [轻微][存量] e2e 客户端重复 import

- **位置**：`fdbm/test/e2e/client/src/main.cj:21-22`（`import std.env.getVariable` 连写两行）
- **来源**：存量（`git blame`：第 21 行来自旧路径 `fdbm/test/postgres_e2e/client/src/main.cj`（`79d84c3a77`），第 22 行是 2026-10-21 迁到 `test/e2e/` 时（`9207e16b32`）新增）
- **判据**：review-checklist §2「字面量复制」/ §1「未使用的 import」
- **证据**：待确认 —— 未跑构建，不确定仓颉编译器对完全相同的重复 import 是报错还是仅告警
- **建议**：删一行

### [轻微][存量] e2e 断言强度不足：空结果与恒真比较

- **位置**：`fdbm/test/e2e/client/src/main.cj:165-181`（`firstInt` 无行时返回 `0`）、`fdbm/test/e2e/client/src/main.cj:81-97`（`firstText` 无行返回 `None`，调用处普遍 `?? ''`，如 `:304`、`:359-360`）、`fdbm/test/e2e/client/src/main.cj:205-207`、`:216-218`（DDL/insert 用 `>= 0`）；`fdbm/test/e2e/orm_client/src/main.cj:98-100`、`:156`（`update >= 0`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失或静默」在测试侧的等价形态
- **证据**：静态确定 —— `checkInt('count empty route', firstInt(…), 0)`（`:712-713`）在语句返回 0 行和返回一行值 0 时都通过；`update >= 0` 对任何非负 rowCount 恒真
- **描述**：这两类断言无法区分「结果为空」与「结果为 0」，弱化了 `fdbm` 的空路由、COUNT 语义回归保护；同文件 `:335`、`:337` 已经用精确值断言，口径不一致
- **建议**：`firstInt` 返回 `?Int64`，空结果直接 `check(…, false)`；DDL 断言统一改 `== 0`（与 `:335` 一致）

### [轻微][存量] e2e README 未登记实际生效的 7 个环境变量与自定义扩展覆盖

- **位置**：`fdbm/test/e2e/README.md:36-49`（「可用环境变量覆盖」表）、`fdbm/test/e2e/README.md:63-78`（「覆盖范围」表）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）/ §14（README 遗漏，需点名）
- **证据**：静态确定 —— 实现侧使用而 README 表里没有：`FDBM_E2E_BACKEND`、`FDBM_E2E_PORT`、`FDBM_E2E_PORT2`、`FDBM_E2E_PROBE`、`FDBM_E2E_CUSTOM`（`fdbm/test/e2e/run.sh:68-69/101/131`、`fdbm/test/e2e/client/src/main.cj:32/129/184/289`）、`CUSTOM_EXT_ALGORITHM`、`CUSTOM_EXT_IDGEN`（`fdbm/test/e2e/run.sh:118-119/155`、`custom_ext/src/ext.cj:47/85`）；README 全文检索「自定义」只命中 `:91` 的 `f_data` 线缆说明，`custom_ext/`（自定义分区算法 + 自定义 ID 生成器，客户端 `main.cj:198-242`）在覆盖范围表里没有任何行
- **描述**：`run.sh:131` 会单独跑一轮 `FDBM_E2E_CUSTOM=1` 的客户端（断言 7001 号自增 ID 真落库），这是 fdbm 扩展点的主要联调证据，但文档既不说明怎么跑，也不说明验证了什么；调试时也无法通过 README 知道 `PORT/PORT2/PORT3` 各自对应哪一轮
- **建议**：环境变量表补齐上述 7 项（含默认值），覆盖范围表补「自定义扩展：分区算法注册被拒/生效、自定义 ID 生成器」一行，并标注这是独立一轮客户端

### [轻微][存量] 自定义 ID 生成器示例是非原子的读改写

- **位置**：`fdbm/test/e2e/custom_ext/src/ext.cj:99-102`（`nextIntId` 里 `next += 1; next`）
- **来源**：存量
- **判据**：review-checklist §12.1「检查-然后-写入 / 共享可变状态无保护」
- **证据**：静态确定 —— `next` 是可变字段，`+=` 是非原子读改写；该类经 `static init` 注册进 `InitializerCollection`（`custom_ext/src/ext.cj:75-77`），由 fdbm 的 `CustomLoader` 装进服务端进程
- **描述**：并发插入时两个线程可能拿到同一个 ID（`next` 相同）→ 主键冲突或脏写。当前只在单客户端 e2e 里使用，实际风险低，但这段代码是「自定义 ID 生成器」的示例，容易被照抄
- **建议**：用 `Mutex` 或 `AtomicInt64`（若 std 提供）包住自增；或注释里明确「仅联调用、非线程安全」

### [轻微][存量] 注释与实现不符：doc 注释错位、构建壳注释与实际导出相反

- **位置**：`fdbm/test/e2e/client/src/main.cj:190-197`（第一段 `/** 真库联调客户端（设计 §13…） */` 与第二段 `/** T07 自定义扩展… */` 相邻，前者实际挂到了 `func customExtension` 上，而它描述的是整个客户端）；`fdbm/test/e2e/driver_bundle_mysql/src/main.cj:18-23` 与 `fdbm/test/e2e/driver_bundle_postgres/src/main.cj:18-23`（注释写「本身不导出任何东西」，但文件导出了 `public func bundleMarker()`）
- **来源**：存量
- **判据**：review-checklist §13「文档与代码不一致」
- **证据**：静态确定
- **建议**：把第一段注释移到 `main()` 上或改成普通 `//` 说明；构建壳注释改为「只导出 `bundleMarker` 作为构建标记」

### [轻微][存量] 两个构建壳文件除包名与字面量外逐行相同

- **位置**：`fdbm/test/e2e/driver_bundle_mysql/src/main.cj:16-26` 与 `fdbm/test/e2e/driver_bundle_postgres/src/main.cj:16-26`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定（两文件仅 `package`、注释里的驱动名、`bundleMarker` 返回串不同）
- **描述**：属于「为独立构建而必须复制」的场景（两个 `cjpm.toml` 各自依赖不同驱动），无可合并落点；仅记录，避免下一轮重复报
- **建议**：保留现状；若要收敛，只能给 `cjpm.toml` 加 `--cfg` 条件编译（收益低于复杂度）

## 优化可行性方案

> 以下是「还能更好」，不是缺陷。全部缺改前基线，**不进 `todo.md` / `tasks.md`**。

### [堆内存] Lexer 全量物化 SQL 并给每个 token 复制一份大写串

- **现状**：`fdbm/src/sql/token.cj:92` 把整条 SQL `toArray()` 成 `Array<UInt8>`；每个 `Token` 构造时（`fdbm/src/sql/token.cj:64`）都做一次 `text.toUpper()`，即 `Text`/`Number`/`HexText` token 也带一份等长副本。1 MB 的 SQL ⇒ 1 MB 字节数组 + 约 10 万个 `Token` 实例 + 约 10 万份 `upper` 串，峰值粗估 6–10 MB 量级（未测）
- **方案**：`Token.upper` 只在 `TokenKind.Ident` 上计算（其余置空或改 `?String`）；`isKeyword`（`token.cj:68-70`）改用 `asciiEquals` 折叠比较，不再每次 `word.toUpper()` 分配；`tokenize` 直接按 Rune 迭代，去掉 `source.toArray()`
- **预期**：每 token 少一次字符串复制（随 token 数线性），大 SQL 解析峰值随之下降（幅度待测）
- **代价**：关键字比较从「一次 `==`」变成「逐字节折叠比较」，CPU 略升；`Token` 从「全字段常量」变成需区分 `Ident` 分支
- **验证**：`cjprof heap` + 1 MB / 10 KB 两档 SQL 的解析峰值与耗时对照（`-O2`、同机、多轮取中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `quoteText` 先物化 Rune 数组、再复制一次整串

- **现状**：`fdbm/src/sql/SqlRenderer.cj:428-440` 用 `value.toRuneArray()` 得到 `Array<Rune>`（约为字节数 4 倍），逐字符 append 到 `StringBuilder`，最后 `"'${builder.toString()}'"` 又复制一份。大字段参数（e2e 用到 200 KB）单次渲染至少 3 份临时副本
- **方案**：直接遍历 Rune（`for (ch in value.runes())` 或等价迭代），`StringBuilder` 以 `'` 起止，去掉 `toRuneArray` 与最后一次插值复制
- **预期**：单个 200 KB 字符串参数少 2 份临时副本（约数百 KB 峰值）；小参数也可省 2 次分配
- **代价**：无（输出字节完全一致）
- **验证**：同输入下 `getAllocatedHeapSize()` 增量 + 渲染耗时对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Token.isKeyword` 每次调用都 `word.toUpper()`

- **现状**：`fdbm/src/sql/token.cj:69` 每条关键字比较都构造一个大写串；一条语句几十次比较（`SqlParser.cj` 里 `isKeyword(` 出现 35 次，`matchKeyword` 内部同样走该函数）
- **方案**：调用方传预置大写常量（`'SELECT'` 等），或 `isKeyword` 内部改 `asciiEquals(upper, word)`
- **预期**：每条语句省下几十次小串分配；实际耗时占比未测（很可能在噪声内）
- **代价**：无
- **验证**：`cjpm bench -O2` 解析 10 万条 f_orm 语句的前后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次访问 `tables` 都重建容器

- **现状**：`fdbm/src/sql/ast.cj:338-353` 每次访问都 `new ArrayList` + `toArray`（二次复制）；`fdbm/src/sql/ast.cj:240-245` 非派生表也返回新数组 `[this]`。请求主路径上 `Dispatcher.ensureKnownLogicalDatabase`（`fdbm/src/execute/dispatcher.cj:64`）每请求访问一次
- **方案**：非派生表返回共享的静态单元素数组（AST 不可变，可安全共享）；派生表按需展开
- **预期**：每请求少 1–2 次小数组分配（对象数随 QPS 线性）
- **代价**：需保证 `tables` 返回值不被调用方就地修改（当前调用方只读）
- **验证**：`cjprof heap` 下每请求分配量对比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能数据支撑的猜测，不进 `todo.md` / `tasks.md`

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词法分析（含 `upper` 复制）占单条语句解析耗时的主要部分 | `fdbm/src/sql/token.cj:90-300` | 自耗时占比 | `cjprof record` 跑 10 万条 `f_orm` 生成的 SQL，看 `Lexer.tokenize` self time |
| 2 | `isKeyword` 的 `toUpper` 分配是解析期主要分配源之一 | `fdbm/src/sql/token.cj:69` | 分配量/GC 次数 | `cjprof heap` + 解析压测，对比「换成 `asciiEquals`」版本 |
| 3 | 大 SQL（≥256 KB）解析期峰值内存放大到 6 倍以上 | `fdbm/src/sql/token.cj:92`、`:64` | 峰值 RSS / 堆峰值 | 200 KB / 1 MB 两档输入，量 `getAllocatedHeapSize()` 与 RSS |
| 4 | `parse` 对非会话语句做了两次完整词法分析 | 调用方 `fdbm/src/sql/SqlParser.cj:48-53`（**范围外提示**：该文件属本模块其它部分） | 两次 tokenize 的耗时占比 | 分段计时：`parseSessionCtl` 与 `tokenize` 各计一次 |
| 5 | `tables` 重建容器在 QPS 上千时产生可观测的 GC 压力 | `fdbm/src/sql/ast.cj:338-353` | 每请求分配字节数 | 埋点统计每秒分配量，对照 `cjprof heap` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/src/sql/SqlParser_test.cj` | .cj | ✅ | 覆盖面尚可；缺「join 更新/删除」的执行与方言用例（见发现 #1） |
| 2 | `fdbm/src/sql/SqlRenderer.cj` | .cj | ✅ | 发现 #1/#2/#3/#8/#9/#10 主战场 |
| 3 | `fdbm/src/sql/SqlSupport_test.cj` | .cj | ✅ | `ParameterBinder`/`PartitionKeyExtractor` 用例，与实现一致 |
| 4 | `fdbm/src/sql/ast.cj` | .cj | ✅ | 发现 #2/#4/#7 |
| 5 | `fdbm/src/sql/placeholder.cj` | .cj | ✅ | 空文件，见发现 #5 |
| 6 | `fdbm/src/sql/token.cj` | .cj | ✅ | 发现 #6；性能见优化方案 1/3 |
| 7 | `fdbm/test/e2e/README.md` | .md | ✅ | 与 `run.sh` 主体一致，环境变量与自定义扩展覆盖缺失，见发现 #13 |
| 8 | `fdbm/test/e2e/client/src/main.cj` | .cj | ✅ | 发现 #11；断言强度见 #12 |
| 9 | `fdbm/test/e2e/custom_ext/src/ext.cj` | .cj | ✅ | 发现 #14 |
| 10 | `fdbm/test/e2e/driver_bundle_mysql/src/main.cj` | .cj | ✅ | 发现 #15/#16 |
| 11 | `fdbm/test/e2e/driver_bundle_postgres/src/main.cj` | .cj | ✅ | 同 #10 |
| 12 | `fdbm/test/e2e/orm_client/src/main.cj` | .cj | ✅ | 发现 #12（`>= 0` 恒真）；ORM 流程与文档一致 |
| 13 | `fdbm/test/postgres_e2e/README.md` | .md | ✅ | 兼容入口说明正确（`run.sh` 存在、相对链接 `../e2e/README.md` 有效） |

合计：`.cj` 11 个 / `.md` 2 个 / 共 13 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 发现 #1（方言契约）、#3（缺省分支）；其余：AST 全不可变、无外部字符串拼 SQL（参数经 `literal` 白名单 + 单引号翻倍，无注入面）、无 `Any` 装箱热点 |
| §1 死代码 | 2 | 逐个 private/internal/protected 符号搜过：`TokenKind`/`BinaryOp`/`ShowKind`/`SessionCtlVerb` 的 `index()` 均被 `==` 使用，`upperText`/`isKeyword`/`collectTables`/`withDerived`/`key()`/`equalsName` 均有调用；命中 `SqlKind` + 8 个 `kind`（#4）与空文件（#5）。`effectiveName` 仅测试引用 → 见下方可见性建议（按判据不算死代码） |
| §2 重复逻辑 | 4 | 同文件内两两比对 `SqlRenderer` 全部 13 个函数体 + `ast.cj` 的 `tables` 实现，命中 #8/#9/#10；跨文件搜相同字面量（`X'`/`'\x`、`show tables`）命中同两项；测试夹具重复另计 #11/#16 |
| §3 空实现 | 1 | 命中 #3（缺省返回空串）；其余 `case None => ()` 均为「可选部分缺失」的正常语义，`MarkerPartition.initialize/start` 空体是接口 no-op 策略（已注释） |
| §4 栈溢出 | 1 | 命中 #2（派生表三层递归无上限）；`Lexer`/`renderExpression` 的括号表达式递归深度同样由输入决定，已并入同一条 |
| §5 OOM | 0 | `Lexer` 全量物化按 §5 判据缺「最坏输入规模」数据（客户端 SQL 上界不在本部分），只记为优化方案 1 + 假设 #3，不按缺陷计 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`scope.md` 只给了 LocalMode 文档），热点结论未成立，全部转入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 I/O、无回调；`SqlRenderer`/`Lexer`/AST 全部无同步状态 |
| §6.3 并发串行 | 0 | 无 `spawn`、无任务提交、无共享 writer |
| §6.4 低效算法 | 0 | 逐函数看复杂度：渲染/词法均为线性单趟；`dateTimeText` 的 `'0'${text}` 最多 9 轮、`text.endsWith` 循环最多 9 轮，常数级；无嵌套循环或热点 `contains` |
| §7 降堆内存方案 | 2 | 优化方案 1/2（Lexer 物化、`quoteText` 副本） |
| §8 降 CPU 方案 | 2 | 优化方案 3/4（`toUpper` 分配、`tables` 重建）；均标 `无基线` |
| §9 local mode 可行性 | 0 | 不可行的判据明确：`Lexer.tokenize` 产出的 `tokens` 作为返回值逃逸（`SqlParser.cj:52` 接收），不满足逃逸检查；`quoteText` 的临时串虽不逃逸，但缺峰值内存对照，按规则只能是假设 |
| §11 现有代码的 BUG（存量） | 2 | 命中 #6（`--` 静默截断）、#12（`firstInt` 用 0 兼作空结果）；其余读到的边界（空 `from`、`limit/offset` 组合、`show tables` 未知库、空结果集、`X'..'` 未校验十六进制字符→交由 DB 拒绝）均核对过，未发现新的错值/越界 |
| §12 并发安全与锁粒度 | 1 | 本部分唯一跨线程可达的可变状态是 `MarkerIdGenerator.next`（`custom_ext/src/ext.cj:99-102`，#14）；`SqlRenderer`/`Lexer`/AST 无共享可变字段；`checks`/`failures` 是 `e2e` 单线程全局 |
| §14 功能完备性与 README 覆盖 | 1 | 命中 #13（README 少 7 个实际生效的环境变量、少「自定义扩展」覆盖行）；`test/postgres_e2e/README.md` 与其等价入口一致 |
| 文件覆盖（§13 等） | 13/13 | 无遗漏；`run.sh`/`lib.sh`/`backends/*.sh` 不在清单内，只作为证据引用 |

**可见性建议**（不是死代码，需用户确认无下游依赖）：`fdbm/src/sql/ast.cj:232` `TableRef.effectiveName()` 只有测试引用（`SqlParser_test.cj:38`）；`fdbm/src/sql/SqlRenderer.cj:262` `renderTable`、`:307` `renderExpression`、`:299` `renderIdentifier` 只在同文件内被调用，可加 `private`。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 14 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量 16 条（0 严重 / 2 一般 / 14 轻微），本部分无「本次改动」引入项；是否纳入修复待用户决定。

## 总评

`src/sql/` 这一层的手写词法/AST/渲染实现整体是干净的：AST 全不可变、无同步状态、参数走白名单字面量（不存在拼串注入面），往返用例（`parse → render → parse`）覆盖了主要语句形状，代码质量在「能工作且可读」一档。

本部分真正需要排期的只有两条一般项：**DML 的 JOIN 渲染没有方言分支**（`update/delete ... join` 在 PG 上必然语法错误，而这两条能力写在设计文档里，且 e2e 从未执行过它们），以及**派生表递归无深度上限**（深度由客户端 SQL 控制，三层递归链叠加）。前者建议直接补方言改写 + 双后端用例，后者加一个层数上限即可闭环。

轻微项集中在三处：一是残留物（`SqlKind` 与 8 个 `kind`、16 行空文件 `placeholder.cj`、只被测试触达的 `renderShow`），二是同规则两份实现（`renderName`/`renderIdentifier`、十六进制方言分支、`literal`/`isLiteral` 白名单），三是 e2e 夹具的断言强度与 README 登记（7 个真实生效的环境变量、自定义扩展那一轮完全没写）。这些都属可排期清理，不阻塞发布。

性能面没有 profile/bench 数据，本部分一律不写成缺陷：`Lexer` 的全量物化与每 token 大写副本、`quoteText` 的三份临时副本是最值得先拿数据的两处（优化方案 1、2），local mode 因 `tokens` 逃逸判定为不可行。
