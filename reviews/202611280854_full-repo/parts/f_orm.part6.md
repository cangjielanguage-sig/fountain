# f_orm 模块审查报告（第 6/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 20 个源文件：`src/exception/` 14 个 + `src/macros/` 4 个 + `src/migro/` 2 个；模块合计 111 个 `.cj` + 11 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支，无 diff 可比）
- **审查重点**：executor 生命周期与线程内复用语义、连接与事务、SQL 注入与参数绑定、大粒度锁、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块分报告，由主 Agent 合并进 `docs/review/2026-11-28/f_orm.md`）
- **本部分范围**：`{workdir}/files/f_orm.part6.txt` 全部 20 个文件，逐个读完；模块其余文件属第 1–5、7、8 部分

> 说明：本部分不含任何 `.md`，所有 `.md` 相关维度（§13 / §14 的 README 侧）以第 1、2 部分的结论为准；本报告仅在需要「承诺源」时引用 `f_orm/README.md` 的行号，不重复统计。

## 发现

### [严重][存量][S1] schema 查询 PO 的列集/类型与真实结果集不对齐，`listTables` / `findTableSchema` / `findIndexes` 必然抛异常

- **位置**：`f_orm/src/migro/MysqlSchema.cj:25-50`（两个 PO 定义）、`:59-68`（`listTables`）、`:69-79`（`findTableSchema`）、`:80-96`（`findIndexes`）；`f_orm/src/migro/PostgresSchema.cj:25-68`（两个 PO 定义）、`:76-86`（`listTables`）、`:87-106`（`findTableSchema`）
- **来源**：存量（快照模式，无 git 基线；`git log` 显示这两个文件由 `a77900c79 feat(f_orm): 实现数据库表元数据解析和迁移功能` 引入，后续 `53e453d54` / `84617aecf` 只修了 driverName / DROP TABLE / 转义，未触及本问题）
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性（`Option` 被静默丢弃 / 非空映射）
- **证据**：静态确定 —— 四处查询可逐列比对；映射链路为 `QueryMappers.map` 对每个 mapper 无条件 `populate`（`f_orm/src/base/QueryMappers.cj:77-83`）→ 非空简单类型字段的 putter 是 `x.getOrThrow{ORMException(...)}`（`f_orm/src/macros/QueryMappersGenerator.cj:370-378`），而缺列时 `QueryResultWrap.getOrNull(columnName)` 返回 `None`（`f_orm/src/wrap/QueryResultWrap.cj:988-993`）。`is_nullable` / `non_unique = 0 as is_unique` 的类型转换属**需实测**（取决于驱动上报类型），但缺列问题不依赖驱动。
- **描述**：一个 PO 被复用来承载两种不同的结果集，导致「PO 字段集」与「SELECT 列表」永远对不齐：
  1. `MysqlSchema.cj:59-68` 的 `select table_name` 只有 1 列，而 `MysqlTableSchemaPO` 有 6 个字段、其中 5 个非空（`column_name` / `column_type` / `is_nullable` / `extra` / `table_name`）→ 第一行映射就在 `column_name` 上 `getOrThrow` 抛 `ORMException`。
  2. `MysqlSchema.cj:69-79` 的 `findTableSchema` 不查 `table_name`，但 PO 有非空字段 `tableNameFromDb`（`MysqlSchema.cj:38-39`）→ 同样抛异常。
  3. `PostgresSchema.cj:76-86` 的 `select table_name` 同样缺 PO 的 4 个非空字段。
  4. `PostgresSchema.cj:87-106` 不查 `table_name`，但 PO 有非空 `tableNameFromDb`（`PostgresSchema.cj:39-40`）；且 `generation_expression`（`:34-35`）对普通列在 `information_schema.columns` 里是 NULL，非空 `String` 字段同样会在 `getOrThrow` 上抛异常。
  5. 类型侧：`is_nullable` 在 information_schema 里是字符串 `'YES'/'NO'`，而字段声明为 `Bool`（`MysqlSchema.cj:32-33`、`PostgresSchema.cj:32-33`）；`QueryResultWrap.convertFromString` 的 `match(None<T>)` 没有 `?Bool` 分支，落到 `case _ => throw ORMException('String YES cannot be parsed to ...')`（`f_orm/src/wrap/QueryResultWrap.cj:108-128`）。`non_unique = 0 as is_unique`（`MysqlSchema.cj:83`）在 MySQL 里是 BIGINT 0/1，映射到 `unique: Bool`（`MysqlSchema.cj:48-49`）同样走 `_ => throw`（`QueryResultWrap.cj:196-198` 同型分支）。
- **后果**：`dbmigro` 的取库现状环节整体不可用——要么抛异常中断，要么（若某驱动把缺列当空串）得到「库里没有这张表」的假象，进而对**已存在的表**生成 `create table`、并跳过 `drop table` 清理。README 承诺的「比对数据库现状生成 DDL」（`f_orm/README.md:1814`、`:2010-2016`）因此不成立。
- **建议**：拆 PO——`listTables` 用只含 `table_name` 的单字段 PO，`findTableSchema` 用不含 `table_name` 的 PO；`is_nullable` 用 `String` 字段（或 SQL 侧 `is_nullable = 'YES' as nullable` 转成布尔）；`unique` 改为 `non_unique = 0` 与 `Bool` 的显式转换（`CAST(... AS SIGNED) = 1` 或直接映射 `?Int64` 再自行比较）；`generation_expression` 改 `?String`。补一条连真库的集成测试（当前 `migro_test.cj` 只测 DDL 字符串，三个取库方法零覆盖）。

### [严重][存量][S2] `resource{}` 里交出懒加载迭代器，迭代器在语句/连接已关闭后消费

- **位置**：`f_orm/src/migro/MysqlSchema.cj:60-67`、`:70-78`、`:81-95`；`f_orm/src/migro/PostgresSchema.cj:77-85`、`:88-105`、`:108-122`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（资源不对称 / 生命周期）+ 本模块 `SqlExecutor` 自身的移交契约
- **证据**：静态确定 —— `resource(res, fn)` 在 `finally` 无条件 `res.close()`（`f_base/src/resource.cj:18-24`）；`SqlExecutor.close()` 会关语句、关连接并把线程内 current executor 摘掉（`f_orm/src/base/SqlExecutor.cj:153-174`）；而 `iterator<T>()` 返回的 `QueryResultIterator` 是**懒**的，`next()` 时才 `mappers.doMap(result)`（`f_orm/src/base/QueryResultIterator.cj:68-88`），`QueryResultWrap` 构造只取列信息、不预取行（`f_orm/src/wrap/QueryResultWrap.cj:48-55`）。`SqlExecutor` 的注释明确禁止在迭代器关闭前归还连接：「结果集已移交迭代器（executeIterator 通道）时不能在这里归还连接」（`f_orm/src/base/SqlExecutor.cj:893-899`），靠 `activeQueryResult` 标记（`:963-1006`）保护，而 `resource` 的显式 `close()` 绕过了这层保护。
- **描述**：六个方法都在 `resource(ORM.executor(driverName)){exe => ...}` 内构造 `.iterator<T>().map{...}` 后就返回，`resource` 退出时连接与语句已关闭，调用方（`SchemaFinderMediator` 在 `findTableSchema(...).fold(...)` 处才开始消费）读到的是已关闭的结果集。
- **后果**：表现为空迭代器或 `SQLException`（取决于驱动是否整包缓冲结果集）。空迭代器的后果与上一条相同：把现有表判成新表；同时 `activeQueryResult` 留在 `true`、连接被提前归还，后续在同一 executor 上的执行会报 "cannot execute SQL while a previous query result is still active"。
- **建议**：不要用 `resource` 包裹「交出迭代器」的方法；改为在方法内部就地物化（`fold(ArrayList())` 后返回 `list.iterator()`），或返回已带 `Resource` 语义的迭代器（`QueryResultIterator` 自己实现 `Resource`，调用方 `try (it = ...)`）；若必须流式，让调用方持有 `exe` 并负责 `close()`。

### [严重][存量][S3] 列重命名同时生成 `rename/change` 与 `add column`，DDL 冲突

- **位置**：`f_orm/src/migro/MysqlSchema.cj:124-139`（`:126` 生成 `change old new`，`:136-138` 又生成 `add column`）；`f_orm/src/migro/PostgresSchema.cj:157-201`（`:159` 生成 `rename column ... to`，`:192-193` 又生成 `add column`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）+ §2（近似重复：两段分支少了「排除已重命名列」的判断）
- **证据**：静态确定 —— 第一轮遍历 `currentColumnMap` 用 `oldColumnMap` 命中重命名列并生成改名语句；第二轮遍历 `new` 时，新列名在 `currentColumnMap` 里必然不存在（库里仍是旧名），于是落进 `else` 的 `add column`。README 承诺「`oldColumnName` 非空且与库中不一致 → 按重命名处理」（`f_orm/README.md:2016`）。
- **描述**：对 `oldColumnName = "email"`、`columnName = "email_addr"` 的列，MySQL 生成 `alter table t change email email_addr ...` + `alter table t add column email_addr ...`；Postgres 生成 `rename column name to full_name` + `add column full_name ...`。后者必然报「column already exists」。
- **后果**：任何带改名的迁移都会在中途失败（`auto` 模式下该语句失败后继续执行后续语句，库处于半迁移状态）。现有测试恰好掩盖了它：`f_orm/src/migro/migro_test.cj:113-122`、`:169-178` 只断言 `sqls[0]`/`sqls[last]`，不断言语句条数。
- **建议**：第二轮遍历增加跳过条件（`column.oldColumnName != ''` 且已由第一轮处理），或先把「重命名列」从 `new` 的 add 候选集里剔除；同时把测试改为断言完整语句列表。

### [严重][存量][S4] Postgres 新建索引只输出一个 `";"`：索引与唯一约束静默不创建

- **位置**：`f_orm/src/migro/PostgresSchema.cj:204-219`（`:214`、`:216` 直接拼 `"${i.def};"`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §11（静默失效）
- **证据**：静态确定 —— `new` 侧的 `IndexMeta` 来自 `IndexMeta(schema: IndexSchema)`，该构造器只设 `name/columns/unique`，`def` 保持 `''`（`f_orm/src/base/TableMeta.cj:106-110`，字段默认值见 `:99`）；`def` 只在读库路径被赋成 `pg_indexes.indexdef`（`PostgresSchema.cj:119`）。因此新索引的 `def` 恒为空串。
- **描述**：`generateIndexSql` 对「新索引」和「变更索引」都执行 `'${i.def};'`，`def` 为空时产出的是一条只有分号的语句。README 承诺「对比新旧索引生成变更语句（增删索引）」「索引优先使用 `IndexMeta.def` 原样重建」（`f_orm/README.md:2016`），但新建索引没有任何可原样重建的 `def`。
- **后果**：Postgres/OpenGauss 上新增索引不会生效，`unique` 索引对应的唯一性约束也不会建立——不报错、不中断，属于静默的数据完整性缺口；drop 旧索引却照常执行，所以「先删后建」的变更会让索引彻底消失。
- **建议**：`def` 为空时按 `columns/unique` 生成 `create [unique] index ${name} on ${table} (${columns})`；`def` 仅用于「库中已有索引」的重建路径，并在 `IndexMeta` 文档里写清这个前提。

### [一般][存量][G1] `PostgresSchema.findIndexes` 忽略 `database` 参数且不按 schema 过滤

- **位置**：`f_orm/src/migro/PostgresSchema.cj:107-112`（SQL 只有 `tablename` 条件）、`:209`、`:213`（`drop index ${i.name}` 不带 schema）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（读了不用 / 语义与签名不符）+ §12.1 无关但同一根因：`listTables` 限定 `table_schema = 'public'`（`:82`），`findTableSchema` 只限定 `table_catalog`（`:101-102`），`findIndexes` 两者都不限定，三条查询的作用域不一致
- **证据**：静态确定 —— `database` 形参在方法体内零引用；`pg_indexes` 由 `(schemaname, tablename)` 共同定位
- **描述**：同名表存在于多个 schema 时，`findIndexes` 会把其它 schema 的索引一并取出，diff 后对它们生成 `drop index <name>`；`drop index` 不带 schema 又依赖 `search_path`，可能删错对象或因找不到而报错。
- **建议**：`where schemaname = 'public' and tablename = ${arg(tableName)}`（或把 `database` 实参拆成 `catalog` + `schema`），`drop index` 带上 `public.` 前缀；`findTableSchema` 同步补 `table_schema` 条件。

### [一般][存量][G2] `PostgresTableSchemaPO.extra` 无条件拼 `generated always (...) STORED`

- **位置**：`f_orm/src/migro/PostgresSchema.cj:42-46`（使用点 `:128` 的 `generateColumn`、`:193` 的 `add column`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（语义与命名不符）+ §14.1（半成品）
- **证据**：静态确定 —— getter 没有对 `generationExpression` 为空串的分支
- **描述**：普通列 `generationExpression` 为空，`extra` 得到 `generated always () STORED`，`generateColumn` 会把它贴到每一列的列定义后面，`create table` / `add column` 因此非法；而生成列本身也不对——PostgreSQL 需要 `GENERATED ALWAYS AS (expr) STORED`，这里缺 `AS`。
- **建议**：`if (generationExpression.isEmpty()) { '' } else { 'generated always as (${generationExpression}) stored' }`。

### [一般][存量][G3] `esc` 只转义单引号：MySQL 反斜杠可击穿字面量

- **位置**：`f_orm/src/migro/MysqlSchema.cj:97-99`、`f_orm/src/migro/PostgresSchema.cj:124-126`（同一实现两份）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §10 安全性（SQL 字面量转义不完整）+ §2（跨文件重复）
- **证据**：静态确定（MySQL 默认 `NO_BACKSLASH_ESCAPES` 关闭，`\` 是转义符；PostgreSQL 在 `standard_conforming_strings = on` 时反斜杠是普通字符，故只需处理单引号）
- **描述**：默认值以反斜杠结尾时（如 `default value = "C:\\"`），生成 `default 'C:\'`——反斜杠把收尾单引号转义掉，语句语法错误或把后续内容吞进字面量。默认值来自库元数据/注解，未必可信。
- **建议**：MySQL 侧按 `replace("\\", "\\\\").replace("'", "''")` 转义（或整体改用 `NO_BACKSLASH_ESCAPES` 会话模式并文档化）；把 `esc` 提到 `SchemaFinder` 同包的一个私有工具里，两处方言差异显式参数化。

### [一般][存量][G4] `listTables` 未过滤 `TABLE_TYPE`，视图被当成表

- **位置**：`f_orm/src/migro/MysqlSchema.cj:61-65`、`f_orm/src/migro/PostgresSchema.cj:78-83`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（错误处理/语义不符）
- **证据**：静态确定（`information_schema.tables` 同时含 `BASE TABLE` / `VIEW` / `FOREIGN`）；影响面待确认（库里是否存在视图）
- **描述**：视图会被算进「库里存在但定义里没有」的集合，生成 `drop table <view>`；反过来，若视图名与新表定义重名，会生成 `create table` 撞名。
- **建议**：`and table_type = 'BASE TABLE'`（Postgres 侧 `and table_type = 'BASE TABLE'`），并对已有视图单独出 `drop view` 或直接跳过。

### [一般][存量][G5] `@ORMField` 的 `var` 分支缺 `isPublic` 校验，`private` 成员被静默改成 `public mut prop`

- **位置**：`f_orm/src/migro/../macros/ORMField.cj:46-76`（判定条件在 `:48`，对比 `PropDecl` 分支 `:78` 有 `propDecl.isPublic()`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（契约与实现不符 / 可见性）+ §2（同一意图的两分支，一处少了校验）
- **证据**：静态确定 —— `varDecl.keyword.kind == VAR && !varDecl.isStatic()` 之外没有可见性判断，生成的 tokens 固定是 `public mut prop`（`:63`）；而同文件的错误消息与文档都要求「must be modified by `public var` or `public mut prop`」（`:75`、`:82`）、「使用宏@ORMField 注解public mut prop或public var」（`:26`）
- **描述**：`@ORMField[...] private var x: Int64` 会把私有成员提升为公开属性（本模块 `MysqlTableSchemaPO` / `PostgresTableSchemaPO` 正是靠这个副作用工作）。对外部使用者来说，一个笔误的 `private` 会静默变成公共 API，且与文档/错误消息矛盾。
- **建议**：二选一并写进文档——要么 `var` 分支加 `varDecl.isPublic()` 校验（与 `prop` 分支对称）并修正本模块两个 schema PO 的写法，要么明确「`private var` 会被改写成 `public mut prop`」并给出诊断提示（`diagReport(WARNING, ...)`）。

### [一般][存量][G6] `dirty` 注入的两处静默失效：类型 token 数启发式 + `catch(_){}`

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:203`（类型 token 数判定）、`:205-207`（`try{...}catch(_){}`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §3（`catch {}` 静默吞异常）+ §11（契约不符）
- **证据**：静态确定 —— `DirtyTag.setDirtyField<T>(field: String)` 的 `T` 是被修饰的**类**，与字段类型无关（`f_orm/src/base/DirtyTag.cj:34`），所以 `dts.size == 1 || ?T || Option<T>` 这个限制没有语义依据；`Map<String, Int64>`（6 token）、`pkg.Type`（3 token）等属性会被静默跳过。
- **描述**：文档承诺「`dirty` 指定这个属性……会向 ORM 标记修改历史」（`:36-38`），但多 token 类型的属性、以及没有 setter 的属性（`decl.setter` 取不到时抛异常被吞）都不会打上脏标记，`update<T>(dirty: true)` 因此少更新字段——不报错、不告警。
- **建议**：去掉 token 数条件（改为「有 setter 就注入」）；`catch` 分支至少 `diagReport(WARNING, ...)` 或加注释说明「抽象属性无 setter，跳过」，不要空吞。

### [一般][存量][G7] 属性解析无边界检查，缺值/缺冒号时抛越界异常而非编译诊断

- **位置**：`f_orm/src/macros/ORMField.cj:123-137`（`case 'column'` 的 `i += 2` 后直接 `attrs[i]`）、`:138-140`（`converter` 同型）；`f_orm/src/macros/QueryMappersGenerator.cj:415-429`（`table:` / `classPrefix:` 等五处 `attrs[i + 2]`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（边界/越界）+ §10 错误处理
- **证据**：静态确定 —— 五处取值都没有 `i + 2 < attrs.size` 判断，也没有校验中间那个 token 是 `COLON`
- **描述**：`@ORMField[column]`、`@QueryMappersGenerator[table:]`、`@QueryMappersGenerator[classPrefix: 'U']` 末尾缺值时，宏在编译期抛 `IndexOutOfBounds` 类异常，用户看到的是宏内部堆栈而不是「attr 缺少取值」的编译错误；若写成 `classPrefix LowerUnderScore`（漏冒号）则会静默取到错位的 token。
- **建议**：抽一个 `attrValueAt(attrs, i)` 小工具，统一校验 `i + 2 < size` 与 `attrs[i + 1].kind == COLON`，失败时 `diagReport(ERROR, attrs, ...)` 并抛 `ORMException`。

### [一般][存量][G8] 列名直接当标识符生成 `prop`，非法/重名列名只会炸在生成代码里

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:462-473`（`Token(IDENTIFIER, mapperMetaFn(identifier.value)[1])`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（缺少边界校验）+ §10 可维护性
- **证据**：静态确定 —— token 拼接，无关键字/字符集/重名校验
- **描述**：`@ORMField[true "user-name"]`、列名以数字开头、列名是 `type`/`class` 之类关键字、两个字段映射同一列名，都会让生成的 `Columns` 类出现非法或重复成员；`@ORMField` 文档明确允许列名是任意字符串（`ORMField.cj:28`、`:36`），所以这是可达输入。错误最终表现为生成代码的语法错误，难以回溯到注解。
- **建议**：生成前做「列名 → 合法标识符」的显式映射（非法字符替换 + 数字开头加前缀 + 关键字加后缀），或改用 `Column("user-name")` 的索引/常量形式；重名列名直接 `diagReport(ERROR, ...)`。

### [一般][存量][G9] `ColumnMeta.comment` 不参与任何 DDL 与比较，列注释静默丢失

- **位置**：`f_orm/src/migro/MysqlSchema.cj:100-141`、`f_orm/src/migro/PostgresSchema.cj:127-203`（`generateColumn` / `generateAlterSql` 均未使用 `comment`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（读了不用 / 半成品）+ §14.1
- **证据**：静态确定 —— 在 `f_orm/src/migro/` 全目录搜 `comment` 零命中；`ColumnMeta.comment` 由 `ColumnSchema.comment` 灌入（`f_orm/src/base/TableMeta.cj:72`、`:81`），`ColumnMeta.==` 也不含 `comment`（`:86-92`）
- **描述**：PO 上声明的列注释不会出现在 `create table`，改注释也不会产生任何 `alter`（`column != c` 对注释差异为 false）。用户以为注解生效，实际静默丢弃。
- **建议**：MySQL 追加 `comment '...'`（同样要 `esc`）、Postgres 追加 `comment on column` 语句；或明确从 `ColumnSchema` 移除该字段并写进文档。

### [轻微][存量][M1] 未使用的 import：`fountain::f_regex.*`

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:22`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `Regex` / `regexp` / `f_regex` 除该 import 外零命中
- **描述**：历史残留，增加宏库的依赖面。
- **建议**：删除该行。

### [轻微][存量][M2] 重复逻辑：索引索引化、转义、删表语句、列定义串、putter 模板

- **位置**：`f_orm/src/migro/MysqlSchema.cj:53-58` vs `f_orm/src/migro/PostgresSchema.cj:70-75`（`indexColumns` / `indexIndexes` 4 个函数逐行相同）；`MysqlSchema.cj:97-99` vs `PostgresSchema.cj:124-126`（`esc`）；`MysqlSchema.cj:110-112` vs `PostgresSchema.cj:143-145`（`generateDropTableSql`）；`MysqlSchema.cj:101` 的列定义模板在 `:126`、`:134` 又内联两次；`QueryMappersGenerator.cj:286-289 / 311-315 / 342-346 / 362-368 / 373-377 / 382-386` 六份同构 putter 闭包
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 逐行比对
- **描述**：`indexColumns`/`indexIndexes` 两文件完全一致，`esc` 与 `generateDropTableSql` 亦同；列定义串三处内联导致「改默认值渲染」需要改三个地方（本次 `esc` 的差异就属于这种漂移风险）；六份 putter 模板只差 `converter` 分支。
- **建议**：`indexColumns`/`indexIndexes`/`generateDropTableSql` 提到 `migro` 包内的公共 `private func`（同包、不破坏分层）；方言差异（转义规则）显式参数化；列定义抽一个 `renderColumn(column, withDefault: Bool)`；putter 抽成宏内的一个辅助函数（`genPutter(name, dataType, nullable, converter)`）。差异点（MySQL 用 `change` 全量重写、Postgres 拆成多条 `alter`）属于方言要求，保留两份。

### [轻微][存量][M3] `dirty` 属性大小写判定不一致，`Dirty` 会多报一条 WARNING

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:122`（`token.value.toAsciiLower() == 'dirty'`）vs `:430`（`case (IDENTIFIER, 'dirty')`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（语义与命名不符 / 两处口径不一）
- **证据**：静态确定 —— `@QueryMappersGenerator[Dirty table: 'columns']` 在 `:122` 被认作 dirty，在 `:414-433` 落到 `case _` 报 `'Dirty is illegal attr'`
- **描述**：功能生效但同时输出误导性警告。
- **建议**：两处统一（都 `toAsciiLower()` 比较）。

### [轻微][存量][M4] 每个 `@QueryMappersGenerator` 类都注册 `TableMetas`，schema 内部 PO 启动期产生 warn 噪音

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:186-190`（生成 `private let _ = TableMetas.register<T>()`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（副作用过大）+ §1（注册了但永不使用的条目）
- **证据**：静态确定 —— `MysqlTableSchemaPO` / `MysqlIndexSchemaPO` / `PostgresTableSchemaPO` / `PostgresIndexSchemaPO` 均未标注 `@DatabaseSchema`（`MysqlSchema.cj:25-50`、`PostgresSchema.cj:25-68`），而 `TableMeta.new<T>` 找不到注解就抛 `TableMetaException`（`f_orm/src/base/TableMeta.cj:34`），`TableMetas.register` 捕获后只 `log.warn`（`f_orm/src/base/TableMetas.cj:26-32`）
- **描述**：每启动一次都会为这几个「只用来接结果集」的 PO 打 warn「register table meta error」，并把噪声混进真正的注册失败里。
- **建议**：给宏加一个「只生成映射、不注册表」的开关（如 `@QueryMappersGenerator[noRegister]`），schema 内部 PO 用它；或让 `register` 区分「缺注解 = 非表 PO」与真实失败。

### [轻微][存量][M5] `DAO` 宏的 70 行注释示例已过期，且对宏行为的描述与实现不符

- **位置**：`f_orm/src/macros/DAO.cj:21-26`（行为描述）、`:28-91`（示例代码）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（注释与实现不符）+ §13 精神（示例不可用）
- **证据**：静态确定 —— `:22` 写「在DAO接口函数的默认实现添加生成sql和调用RootDAO函数完成访问数据库的工作」，但 `expand` 只生成 `extend SqlExecutor <: $(d.identifier){}`（`:103-108`），函数体完全由使用者手写（对比 `f_llm/src/dao/mysql/MetaDAO.cj:26-38`）；示例里的 `fountain.orm.*` / `fountain.base.*`、`orm.convert<Int64>(v)`、`meet(...)`、`.donw()`（拼写错误）都已过时或不存在，`arg.name` 与函数名 `arg(...)` 同名冲突
- **描述**：注释是唯一说明 `@DAO` 用法的就地文档，照抄会编译不过，也误解宏职责。
- **建议**：把示例换成当前包名与 `ORMConverter.convert`，删掉 `meet/donw`，并改写 `:21-26` 的职责说明（「把 `SqlExecutor` 声明为 DAO 接口的实现，使接口默认方法里的 `executor` 指向当前 executor」）。

### [轻微][存量][M6] 无列场景下 `generateColumns` 生成非法代码

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:480-485`（`builder.substring(0, builder.size - 1)` 与 `iterator[0 .. iterator.size - 1]`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（空集合边界）
- **证据**：静态确定 —— 列数为 0 时 `toString` 走 `substring(0, -1)`、`iterator` 会把开头的 `[` 当末尾逗号裁掉；前提是存在没有任何 public 可变成员的 PO（标记类/空类）
- **描述**：编译期抛异常或生成 `[].iterator()` 之外的非法片段，错误信息指向生成代码。
- **建议**：`if (props.isEmpty() && vars.isEmpty())` 时直接生成 `''`/空迭代器分支，或提前 `diagReport(ERROR, ...)` 明确「该 PO 没有可映射列」。

### [轻微][存量][M7] exception 包的导入与继承口径不一致

- **位置**：`f_orm/src/exception/imports.cj:18`（`internal import fountain::f_exception.BaseException`）、`f_orm/src/exception/SqlArgException.cj:18`（`<: BaseException`）、`f_orm/src/exception/ORMException.cj:18`（同样 private 导入）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §10 设计合理性（异常层次一致性）+ §1（隐式依赖）
- **证据**：静态确定 —— `BaseException` 在本包内只有 `SqlArgException` 直接使用；`ORMException` 另行 private 导入，两条导入机制并存；其余 11 个异常都继承 `ORMException` / `TransactionException` 家族
- **描述**：`throw SqlArgException(...)`（`f_orm/src/base/RootDAO.cj:249` 等 24 处）不会被 `catch (e: ORMException)` 捕获，与同包其他异常的行为不一致；影响面待确认（取决于调用方是否只捕 `ORMException`）。
- **建议**：`SqlArgException` 改继承 `ORMException`（若确需与 ORM 业务错误区分，可继承 `ORMException` 的子类）；`imports.cj` 的整包重导出收窄为一个文件内的 private import，避免隐式可用。

## 优化可行性方案

### [堆内存] migro DDL 生成改为「按需流式」，去掉 `ArrayList` 全量暂存

- **现状**：`generateAlterSql`（`MysqlSchema.cj:123`、`PostgresSchema.cj:156`）与 `generateIndexSql`（`MysqlSchema.cj:145`、`PostgresSchema.cj:207`）把所有语句先攒进 `ArrayList<String>` 再 `iterator()`；`PostgresSchema.generateCreateSql:131-139` 额外把 `columns` 迭代器物化进 `ArrayList` 后遍历两次。规模 = 单表列数/索引数（通常 < 100），单条语句 100–300 字节
- **方案**：改用 `Sequence`/生成器式 `Iterator` 组合（`flatMap` + `intersperse`），或保留 `ArrayList` 但用 `ArrayList(capacity)` 预分配并按 `columns.size` 估容量；`generateCreateSql` 的 `list` 换成 `toArray()` 后复用同一数组
- **预期**：单表单次迁移少分配 O(列数) 个短命字符串容器；对「表多、每表列多」的库降低 GC 峰值
- **代价**：生成器组合可读性略降；`ArrayList` 版本便于一次看到完整 DDL，改成流式后打印顺序依赖消费方
- **验证**：`-O2` 下对 200 表 × 50 列的元数据跑 `dbmigro -m dry`，对照 `getAllocatedHeapSize()` 与 RSS 峰值（`mem §1.2`），各 10 轮取中位数
- **证据状态**：`无基线（待验证）`，不进 `tasks.md`

### [CPU] `Columns` 生成类的 `Column` 属性每次访问都新建对象

- **现状**：`QueryMappersGenerator.cj:464-470` 生成的 `public prop xxx: Column { get(){ Column("xxx") } }`，每次读取都构造一个 `Column`；`toString`（`:471`）与 `iterator`（`:472`）在拼 SQL 别名时按属性逐个访问，单次查询会为每列构造 1 个 `Column`
- **方案**：改为 `static let` 常量（`private static let c_xxx = Column("xxx")`）或在 `Columns` 实例里缓存
- **预期**：每列每次拼 SQL 少一次小对象分配；查询构建路径上约「列数」量级的分配减少
- **代价**：生成代码多几个静态字段；`Column` 若带可变状态则不能共享（需先确认 `Column` 无状态）
- **验证**：`cjpm bench -O2` 跑「同一 PO 连续构建 10 万次查询」对照；先用 `cjprof record` 看 `Column` 构造是否进入自耗时前 20
- **证据状态**：`无基线（待验证）`，不进 `tasks.md`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Columns` 属性每次新建 `Column` 是查询构建路径的分配热点 | `f_orm/src/macros/QueryMappersGenerator.cj:464-470` | `Column` 构造在分配总量/自耗时中的占比 | `cjprof record` 跑 10 万次列表查询构建，看 `Column.<init>` 占比与 `cjprof heap` 分配量 |
| 2 | 宏展开期 `generateColumns` 的 token 逐条 `+=` 拼接是编译热点（大 PO 时明显） | `f_orm/src/macros/QueryMappersGenerator.cj:462-485` | 编译期耗时占 `cjc --compile-macro` 的比例 | 对一个 100 列 PO 前后对照 `cjpm build` 墙钟时间；用 `--debug-macro` 粗看展开体量 |
| 3 | `dbmigro` 全量物化 SQL（`allSqls`）在大库下抬高峰值 RSS | 调用侧 `f_orm/src/migro/SchemaFinderMediator.cj:76-78`（本部分范围外） | 表数 × 语句数的实际量级 | 构造 500 表元数据跑 `-m dry`，量 RSS 峰值与 `getAllocatedHeapSize()` |
| 4 | `PostgresSchema.findIndexes` 的 `groupBy` 在索引数很大的库上占迁移时间主要部分 | `f_orm/src/migro/PostgresSchema.cj:113-121` | 单表索引数与单表耗时占比 | 对 200 索引的表分段计时 `findIndexes` 与 `generateIndexSql` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/src/exception/ConnectionException.cj` | .cj | ✅ | 4 个构造转发 `ORMException`，无问题 |
| 2 | `f_orm/src/exception/DirtyFieldException.cj` | .cj | ✅ | 对外 public，仓内零引用（不作死代码，见 §1 说明） |
| 3 | `f_orm/src/exception/MandatoryTransactionException.cj` | .cj | ✅ | 继承 `PropagationException`，一致 |
| 4 | `f_orm/src/exception/MockDBException.cj` | .cj | ✅ | 无问题 |
| 5 | `f_orm/src/exception/NeverTransactionException.cj` | .cj | ✅ | 无问题 |
| 6 | `f_orm/src/exception/NoIdException.cj` | .cj | ✅ | 无问题 |
| 7 | `f_orm/src/exception/NoneTransactionException.cj` | .cj | ✅ | 对外 public，仓内零引用（不作死代码） |
| 8 | `f_orm/src/exception/ORMException.cj` | .cj | ✅ | 与 `imports.cj` 的 `internal import` 重复导入 `BaseException`，见 M7 |
| 9 | `f_orm/src/exception/PropagationException.cj` | .cj | ✅ | 三个子类的基类 |
| 10 | `f_orm/src/exception/SqlArgException.cj` | .cj | ✅ | 直接继承 `BaseException`，层次不一致，见 M7 |
| 11 | `f_orm/src/exception/StartFailureTransactionException.cj` | .cj | ✅ | 无问题 |
| 12 | `f_orm/src/exception/TableMetaException.cj` | .cj | ✅ | 无问题 |
| 13 | `f_orm/src/exception/TransactionException.cj` | .cj | ✅ | 无问题 |
| 14 | `f_orm/src/exception/imports.cj` | .cj | ✅ | 包级 `internal import BaseException`，仅 `SqlArgException` 依赖 |
| 15 | `f_orm/src/macros/DAO.cj` | .cj | ✅ | 注释示例过期，见 M5 |
| 16 | `f_orm/src/macros/ORMField.cj` | .cj | ✅ | 可见性校验缺失（G5）、属性解析无边界检查（G7） |
| 17 | `f_orm/src/macros/QueryMappersGenerator.cj` | .cj | ✅ | 主要问题集中地：dirty 静默失效（G6）、属性解析边界（G7）、列标识符（G8）、重复 putter（M2）、未用 import（M1）、无列边界（M6）、注册噪音（M4）、dirty 大小写（M3） |
| 18 | `f_orm/src/macros/TransactionalService.cj` | .cj | ✅ | 仅重导出 `Pointcut` / `WeavedBean`，无问题 |
| 19 | `f_orm/src/migro/MysqlSchema.cj` | .cj | ✅ | S1–S3、G3、G4、G9 |
| 20 | `f_orm/src/migro/PostgresSchema.cj` | .cj | ✅ | S1–S4、G1–G4、G9 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 5（S1、S2、S3、G2、G9）、设计 2（G5 的宏副作用、M7 的异常层次）、语言特性 2（S1 的 `Option` 静默丢弃、G5 的展开期可见性）、可读性 2（M5、M6）、安全性 1（G3） |
| §1 死代码 | 1 | 逐个 private / internal 符号搜过引用：`expand`/`reportError`/`expandORMField`/`expandQueryMappers`/`generateMappers`/`transformTableName`/`generateColumns`/`indexColumns`/`indexIndexes`/`esc`/`generateColumn` 均有调用者；13 个异常类均为对外可达 `public`，按硬原则一**不判**死代码（`DirtyFieldException`、`NoneTransactionException` 仓内零引用，仅记录为信息）；命中项为未使用的 `import fountain::f_regex.*`（M1） |
| §2 重复逻辑 | 1 | 已把本部分 20 个文件的函数体压成「输入→输出→副作用」两两比对：异常类的 4 个构造（52 处）属语言限制（构造不被继承），不判；命中 5 组同语义实现（M2），另 S3 属「近似重复少了边界判断」的重复形态 |
| §3 空实现 | 1 | 空函数体只有异常类的 `public init(){}`（合法转发）；命中 `try{...}catch(_){}` 静默吞异常 1 处（G6 的后半） |
| §4 栈溢出 | 0 | `ORMField.expandORMField`（`:84-99`）与 `QueryMappersGenerator.expandQueryMappers`（`:73-78`）确有自递归，但深度 = 源码注解嵌套层数（由源文件写法限定，用户不可在运行期控制），且无环检测需求，不构成无界递归 |
| §5 OOM | 0 | 本部分唯一的全量物化是单表列/索引级别的 `ArrayList<String>`（数量由表结构决定，几十到几百条），无按不可信长度预分配、无全局增长容器；`TableMetas`/`DirtyTag` 的全局容器只增不减问题在 `src/base`（本部分范围外） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；宏只在编译期运行、migro 为 CLI 路径，无自耗时占比与调用频次证据，相关猜测已列入「待验证假设」#1–#4 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁原语（`synchronized` / `Mutex` / `Atomic` 零命中）；生成的 `TableMetas.register` 走 `ConcurrentHashMap`，不在本部分实现内 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future`；migro 全流程单线程遍历表，串行度由 CLI 语义决定，非热点 |
| §6.4 低效算法 | 0 | `generateAlterSql` / `generateIndexSql` 的查找全部走 `HashMap`（O(n)），无嵌套扫描、无 `remove(at: 0)`、无循环内字符串 `+`（用 `StringGenerator`）；`attrs` 解析为线性扫描 |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 / 堆内存」一条（`无基线（待验证）`） |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 / CPU」一条（`无基线（待验证）`） |
| §9 local mode 可行性 | 0 | 本部分热路径都在编译期（宏）或 CLI（migro），无高频短命临时对象；`Tokens` / `Token` 来自 `std.ast`，没有 local mode 重载，逃逸检查也无法通过（生成的 token 要作为编译产物返回），结论为不可行，不列方案 |
| §11 现有代码的 BUG（存量） | 20 | 全部 20 条均为存量（快照模式无 git 基线）；其中严重 4、一般 9、轻微 7 |
| §12 并发安全与锁粒度 | 0 | 宏在编译期单线程执行；migro 由 `SubCommand.exec` 单线程驱动；本部分代码内无共享可变状态、无线程池、无跨线程句柄（`SqlExecutor` 的线程内复用语义在 `src/base`，属第 3–5 部分） |
| §14 功能完备性与 README 覆盖 | 2 | 与 README `§16`（`f_orm/README.md:1974-2016`）逐条对照：`generateIndexSql` 承诺「增删索引」但 Postgres 新索引只产出 `";"`（S4）；`generateAlterSql` 承诺「按重命名处理」但实现同时 `add column`（S3）；其余方法签名与 README 一致 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md` 文件，§13 文档一致性在本部分无适用对象；README 侧结论归第 1、2 部分，本报告只引用其行号作「承诺源」 |

## 模块统计（仅第 6/8 部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 9 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

- 存量缺陷 20 条，是否纳入修复待用户决定。
- 「待验证假设」4 条，不计入统计，不进 `todo.md` / `tasks.md`。

## 范围外提示

> 追调用链时撞见、但文件不属于本部分的问题，只记一句，不占用本轮统计，交由对应部分处理。

1. `f_orm/src/base/TableMetas.cj:26-32`：`register` 把 `TableMeta.new<T>()` 的异常吞成 warn，而 `f_orm/src/migro/SchemaFinderMediator.cj:60-71` 会用「注册表里没有」反推「库里多余」并生成 `drop table`——注册失败（缺 `@DatabaseSchema`、反射失败）会直接变成删表建议，建议该链路改为「注册失败即拒绝生成 drop」。
2. `f_orm/src/base/DirtyTag.cj:27-32`、`:50-58`：`contains` 后 `put` 的检查-然后-写入在 `ConcurrentHashMap` 上不是原子操作，并发首次注册可能丢掉 `ThreadLocal` 集合，建议 `computeIfAbsent`。
3. `f_orm/src/migro/SchemaFinderMediator.cj:49`：对每个 driver 组插入 `use <database>;`，但 `use` 是 MySQL 语法，Postgres/OpenGauss 不认，PG 的迁移文件会带一条非法语句。
4. `f_orm/src/base/TableMeta.cj:43-60`：没有 `@ColumnSchema` 的 PO 字段被静默过滤掉，列不会进迁移但 mapper 照常读写，属「迁移漏列」的另一条路径。

## 总评

本部分代码分两块，质量差异很大。

`src/exception`（14 个文件）是纯样板：13 个异常类各 4 个转发构造，层次清楚，`imports.cj` 的整包重导出只为 `SqlArgException` 服务、且该类越级继承了 `BaseException`，是仅有的两处口径不一致，属可排期的小整理。

`src/macros` 的四条宏是本模块抽象度最高的地方，能跑通「内层 `@ORMField` 先展开 → 外层 `@QueryMappersGenerator` 收消息」的正确链路（符合 `implementation_of_macros.md:532-537` 的由内向外展开顺序），但**失败路径几乎全靠静默**：属性缺值抛越界、`dirty` 注入吞异常、多 token 类型静默不打脏标记、非法列名把错误推到生成代码里。这些不阻塞主流程，但让误用极难定位，建议统一走 `diagReport`。

真正需要优先处理的是 `src/migro` 两个方言实现——它们承载 README §16 承诺的整套迁移能力，却**没有任何连库测试**（`migro_test.cj` 只断言 DDL 字符串，`listTables`/`findTableSchema`/`findIndexes` 零覆盖）。四条严重问题全在这里：查询 PO 与结果集列集/类型不对齐（6 个取库方法必然抛异常）、`resource` 内交出懒迭代器导致结果集在关闭后被消费、列改名同时生成 `rename` 与 `add column` 的自相矛盾 DDL、Postgres 新索引 `def` 恒空只产出 `";"`（唯一约束静默不建立）。四者叠加意味着这条迁移链路当前不可用，且其中最后两条会**静默**产出错误/缺失的 DDL，属于阻塞项。

建议顺序：先补一条真库冒烟测试（建表 → 迁移 → 再迁移应为空 diff）把四条严重问题钉住，再统一 `esc`/`indexColumns`/`generateDropTableSql` 的重复实现，最后处理宏的静默失败与注释过期。
