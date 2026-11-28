# fdbm 模块审查报告

> **模块第 1/6 部分**：只覆盖 `files/fdbm.part1.txt` 列出的 10 个文件（两份 README + `doc/spec/**` 的 8 份变更文档）。模块的 55 个 `.cj` 与 `doc/开发计划.md`、`doc/详细设计.md` 等其余 `.md` 由第 2–6 部分产出，本报告不对其下结论。
> 为核对文档承诺，本部分按需读取了 `src/config/**`、`src/server/**`、`src/resources/DatabaseResources.cj`、`src/execute/{session,cursor,executors}.cj`、`src/route/cache.cj`、`src/sql/SqlParser.cj`，只把它们当**取证来源**，不重复后续部分的源码级审查。

- **审查日期**：2026-11-28
- **模块路径**：`fdbm`（本部分 0 个 `.cj` + 10 个 `.md`；模块共 55 个 `.cj` + 15 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）
- **审查重点**：多数据源管理正确性、连接生命周期、启动期装配（配置先于装配、重名报错）、并发安全、死代码、重复逻辑、存量 BUG；本部分载体是文档，故以「文档承诺 vs 实现」为主线取证
- **报告版本**：v1（第 1/6 部分）

## 发现

### [严重][存量] 会话关闭与在途请求只做了「引用摘除」：游标与 pin 连接会在使用中被另一线程关闭

- **位置**：
  - `fdbm/src/server/SessionRegistry.cj:112-141`（巡检线程：`takeCursor`/`session.close()`）
  - `fdbm/src/execute/session.cj:100-131`（`installCursor`/`takeCursor`）、`:147-163`（`close()` 摘除后立即关）
  - `fdbm/src/execute/cursor.cj:42-64`（`CursorSegment.close`）、`:112-209`（`QueryCursor.next/cell/close` 的 `closed`/`rowValid`/`cells`/`streams`/`segmentIndex` 全是普通字段，文件未 import 任何锁）
  - `fdbm/src/server/handler.cj:132-139`（`requireCursor` 拿到引用后，在会话锁之外调用 `next()`/`cell()`）
  - `fdbm/src/execute/executors.cj:82-97`（`borrow` 拿到 `pinned.connection` 后在锁外执行 SQL）、`:1372-1384`（commit 的 `finally` 里 `unpin()+close`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「跨线程资源：连接/迭代器被多线程共享」；§11「并发正确性」；§13 规格与实现漂移（`doc/spec/harden-fdbm-stack-defects/spec.md:73-74,93-97,570-581` 承诺「同一游标只能被关闭一次、连接只归还一次、请求收到 `CURSOR_STATE`」）
- **证据**：静态确定 —— `DbdSession` 的 `Mutex` 只保护 `cursor`/`pinned` 两个**引用**；`takeCursor()`/`unpin()` 把对象交给调用者后，被引用的 `QueryCursor`、`CursorSegment`、`PinnedConnection` 内部没有任何同步（`closed: Bool` 非原子、`cells`/`streams` 是普通 `HashMap`），而请求线程此时仍持有同一对象并在其上 `next()`/读列/执行 SQL。`f_dbpool` 的 `PooledConnection.close()` 用 CAS 归还并**立即**把连接放回池（`f_dbpool/src/DatabasePool.cj:259-272`）。
- **描述**：触发条件不需要「客户端违规」，只需要客户端在语句执行中断开（或 `fdbm_shutdownTimeout` 到期后 `stop()` 继续关会话）：
  1. 请求线程正在 `QueryCursor.next()` 读物理结果集；巡检发现 `buffer.isClosed()` → `sweep` 摘除会话 → `QueryCursor.close()` 把 `result/statement/connection` 全关掉；请求线程继续在已关闭对象上读 ⇒ 数据竞争，具体表现是异常或读到错乱缓冲。
  2. 请求线程正在事务里用 `pinned.connection` 执行 SQL；`DbdSession.close()` 归还该连接 ⇒ 连接已回池，另一个会话可立刻借到**同一条物理连接**，两个线程同时在同一连接上收发 ⇒ 结果集串包/协议错位；随后请求线程再次 `close` 时 `PooledConnection` 抛 `ConnectionException('returned multiple times')`，被 `handler` 映射成 `INTERNAL`。
  3. `CursorSegment.close()` 同时被 `QueryCursor.next()`（段耗尽时，`cursor.cj:147`）与 `QueryCursor.close()`（`cursor.cj:205-208`）调用，`closed` 检查与置位非原子 ⇒ 同一 segment 可能被两条线程同时关闭。
  这正是 spec 场景「巡检与在途请求并发」（`spec.md:93-97`）要求排除的情形，实现未提供任何「使用中」保护。
- **建议**：把保护从「引用」下沉到「对象」——`QueryCursor` / `CursorSegment` / `PinnedConnection` 内部各持一把 `Mutex`，`closed` 改 `AtomicBool`，`next/cell/close/drain` 全程串行；或在会话层引入使用租约（请求取游标/pin 时引用计数 +1，`sweep` 只置 `closed` 标志，最后一个使用者释放时才真正 `close`）。用例：客户端查询中途断开、`maxSize=1`、1000 轮，断言 `connection.close` 次数等于借出次数、无 `INTERNAL`，且后续请求仍能借到连接。

### [一般][存量] 事务只能作用于 pin 的那个物理库，README 未写、spec 写成「Single 不受影响」

- **位置**：`fdbm/src/execute/executors.cj:84-89`（`borrow`：`pinned.database != database` → `ROUTE_FAILED`）、`:1332-1347`（`pinTarget` 固定取默认逻辑库的**排序首个**物理库）、`:1262-1266`（事务内 DDL 一律拒绝）；文档侧 `fdbm/README.md:196`、`README_en.md:215`、`doc/spec/harden-fdbm-stack-defects/spec.md:514`、`specs/fdbm/spec.md:515`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「只做了一半的分支 / 承诺缺失」、§11「契约与实现不符」
- **证据**：静态确定 —— `BEGIN` 时 pin 到 `smallestName(catalog.physicals(session.database))`；之后**任何**语句（含 `Single` 单目标）只要路由到别的物理库，`borrow` 都抛 `ROUTE_FAILED`。`ensurePinnedTargets` 只拦 `count > 1`，真正的单目标跨库拦截在 `borrow` 里。
- **描述**：README 的事务行只写「`BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT` 透传到会话 pin 住的物理连接」，没有写「事务期间只能访问该物理库」；spec 的「事务 pin 的目标唯一性」更明确写「`Single` 路由与 `Empty` 路由不受影响」，与实现相反。实际影响：4 片部署下 `begin; insert into orders(id,...) values(10000001,...); commit` 会直接 `ROUTE_FAILED`，用户按文档无法预判；事务内 DDL 被拒绝同样未进 README（只在 spec D04 里有）。
- **建议**：README「SQL 能力」事务行补两条硬约束：① 事务固定 pin 在会话默认逻辑库的排序首个物理库，语句命中其它物理库（即使只有一个）→ `ROUTE_FAILED`；② 事务内 DDL → `ROUTE_FAILED`。spec 把「Single 不受影响」改为「目标库 == pin 库时 Single 可执行」。

### [一般][存量] 同一个变更里两份 spec 已漂移：全局表是否隐式展开逻辑库，两份结论相反

- **位置**：`fdbm/doc/spec/harden-fdbm-stack-defects/spec.md:467`（「`fdbm_partition__*` **/ `fdbm_global__*`** 引用的逻辑库隐式映射到全部物理库」）vs `fdbm/doc/spec/harden-fdbm-stack-defects/specs/fdbm/spec.md:467-468`（「`fdbm_global__*` **不**触发隐式展开，必须引用已存在的逻辑库，否则 `CONFIG`」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」；§2「重复逻辑（同一规格两份维护）」
- **证据**：静态确定 —— 两份文件 655 / 656 行，`diff` 仅此一处不同；对照 `design.md:117`（`fdbm_global__*` 不触发隐式展开，`validateGlobalTables` 报 `CONFIG`）、`README.md:120`（全局表不创建逻辑库）、`src/config/catalog.cj:72-77`（只为 `partitions` 调 `ensure`，全局表完全不参与 catalog 构建）、`src/config/FdbmConfig.cj:491-499`（`validateGlobalTables` 要求 `catalog.contains`）。
- **描述**：根目录那份 spec 的写法恰好把 G08 要防的问题写了回去——若实现者按它做，`fdbm_global__dict='cfg'` 的拼写错误会被静默展开成「全部物理库」，全局表写会广播到所有库，属于越界写。同一变更的两份规格给出相反验收口径，归档后无法判断哪份是准。
- **建议**：删除根目录副本，只保留 `specs/fdbm/spec.md` 作为唯一 delta（openspec 的规范位置），或在根目录放指向它的短文件，避免二次维护。

### [一般][存量] README「其他公开 API」段与「不提供库级 API」自相矛盾，且把内部成员当公开 API、长签名被截断

- **位置**：`fdbm/README.md:20-30`（「fdbm 是常驻服务，不提供库级 API……对外接口只有四类」）与 `:257-262`（「其他公开 API」）；`fdbm/README_en.md:22-34` 与 `:295-300`；被当作公开 API 的条目来自 `src/execute/session.cj:27`（`transactionOpen`）、`:100-145`（`installCursor`/`takeCursor`/`pin`/`unpin`）等 `protected class` 成员
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「示例代码不能用」「文档自相矛盾」；§14.2「公开 API 未文档化 / 索引登记」；硬原则一（对外不可达的成员不是公开契约）
- **证据**：静态确定 —— 抽取该行内所有 `` `public static func ...` `` 代码片段，长签名一律缺右括号与返回类型：`public static func create(name: String, databases: Array<String>, step: Int64`、`forTable(config: IdMakerConfig, resources: NodeAccessor`、`handle(context: ServerContext, buffer: SocketBuffer`、`render(statement: SqlStatement, dialect!: SqlDialect = SqlDialect.Unknown`；`installCursor`/`takeCursor`/`pin`/`unpin`/`transactionOpen` 全部是 `protected class DbdSession` / `QueryCursor` / `PinnedConnection` 的成员，仓外不可达。
- **描述**：同一份文档先说「不提供库级 API」，末尾又列出上百个「其他公开 API」；列表是机械生成的，未按可达性过滤，且按固定宽度截断签名 ⇒ 用户拿到的函数签名不可用、也不知道属于哪个类型（`close`/`get`/`parse` 之类重名条目无归属）。这会把下游引向内部实现（例如按 `installCursor` 语义写代码），一旦内部重构即破坏兼容。
- **建议**：该段改为「按类型分组 + 代码块保留完整签名」，只列对外可达的 `public` 顶层声明（实际只有 `FdbmException`、`asciiEquals`、`ConfigSource` 三个有意义入口）；或直接删除该段，改为「实现细节见 src/」。`README_en.md` 同步。

### [一般][存量] 会话以 `remoteAddress` 文本为键，`of()` 不校验连接身份 ⇒ 端口复用可能让新连接继承已关闭的旧会话

- **位置**：`fdbm/src/server/SessionRegistry.cj:46-58`（`of`：命中即返回，不检查 `buffer` 是否同一实例/会话是否已关闭）、`:152-159`（`keyOf` = `buffer.remoteAddress.toString()`）；文档侧 `fdbm/README.md:228`、`README_en.md:261`（「会话 = 一条 TCP，同一连接同一会话」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「跨线程资源 / 唯一性假设」；§13
- **证据**：待确认 —— 缺两项信息：① `f_net.SocketBuffer.remoteAddress` 的文本是否包含客户端临时端口（含端口才近似唯一）；② 客户端在 30s 巡检窗口内复用同一源端口的实际概率（NAT/连接池场景）。
- **描述**：会话表键是地址字符串，`of()` 命中后直接复用旧 `DbdSession`（可能已被 `closeAll`/`sweep` 关闭，游标已关、pin 已归还）。若新 TCP 连接拿到与旧连接相同的地址串，它会继承一个不可用会话：所有查询回 `CURSOR_STATE`，或写入一个已从注册表摘除的会话。README 承诺的是「同一连接同一会话」，实现只能近似到「同一地址同一会话」。
- **建议**：会话条目同时保存 `SocketBuffer` 引用，命中后先比较实例身份（或 f_net 提供的连接 id/句柄），不一致或 `session.isClosed()` 时新建并关闭旧条目；`sweep` 摘除时用同一把锁保证不会与新连接竞争同一键。

### [一般][存量] `INSERT ... SELECT` 全量物化整份结果集，无行数/字节上限，README 未提示

- **位置**：`fdbm/src/execute/executors.cj:808-817`（注释「先**物化**全部行再关闭游标」，实现按此）；文档侧 `fdbm/README.md:191`、`README_en.md:210`（只写「拆成 SELECT + 逐行 INSERT」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「一次性物化」「无拒绝路径（大小上限、分页、流式、背压）」；§13
- **证据**：静态确定（物化行为）—— 行数据以 `Array<Data>` 逐行累积，`insertFromSelect` 先把游标读尽再逐行 INSERT；代码里没有行数上限、字节上限或分批参数。峰值内存量级需实测。
- **描述**：`insert into t(...) select ... from big_table` 在服务端把整个结果集读进堆（每行一份 `Array<Data>`，字符串/字节列各自持有），然后才逐行下推。README 用「拆成 SELECT + 逐行 INSERT」描述，容易被理解成流式；实际上单条语句即可按结果集大小线性吃内存，直到 OOM，且没有拒绝路径。
- **建议**：改为分批（按源库/分片或 `LIMIT` 游标窗口）执行，或引入可配置的「物化行数/字节上限」，超限报 `UNSUPPORTED_SQL`/`CONFIG`；README 在 `INSERT ... SELECT` 处写明内存约束与上限位置。

### [轻微][存量] 死代码：`FdbmConfig.getLogicalDatabases` 全仓零引用

- **位置**：`fdbm/src/config/FdbmConfig.cj:148-152`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「无调用者」（包内符号全仓搜索）
- **证据**：静态确定 —— `grep -rn "getLogicalDatabases" --include=*.cj .`（排除 `.worktrees`）只命中定义行；`FdbmSettings.load()` 直接调 `LogicalCatalog.of(nodes, partitions, source)`（`settings.cj:82`）。
- **描述**：该包装函数已无调用者，且它把 `partitions` 传成 `[]`，与真实装载语义（分库规则会建立隐式逻辑库）不一致——留着既是死代码，也是「被误用后得到不同 catalog」的隐患。
- **建议**：删除；若保留，让 `FdbmSettings.load()` 走它并传入 `partitions`，避免两份装载路径。

### [轻微][存量] 重复逻辑：动态库枚举/扩展名判定/排序在两个 loader 里逐字复制，另有 4 份手写插入排序

- **位置**：`fdbm/src/server/DriverLoader.cj:95-139` 与 `fdbm/src/server/CustomLoader.cj:120-163`（`librariesOf`/`isLibrary`/`withoutExtension`/`sort` 四个函数体逐行相同）；`fdbm/src/config/catalog.cj:184-197`、`fdbm/src/execute/executors.cj:1203-1220`、`fdbm/src/config/BootScriptWriter.cj:530-544` 另有三处插入排序
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」「重复逻辑导致的行为漂移」
- **证据**：静态确定 —— 两个 loader 的实现除函数名外保持一致；扩展名集合 `.so`/`.dll`/`.dylib` 在两处硬编码；`DriverLoader` 的 `sort` 与 `CustomLoader` 的 `sort` 完全同构。
- **描述**：新增平台或修正扩展名判定时改一处漏一处，就会出现「驱动目录认、custom 目录不认」这类只有到现场才发现的偏差；5 份插入排序（O(n²)）虽规模只有个位到百，但属于纯粹重复实现，标准库已有 `sort`。
- **建议**：把「目录 → 动态库清单（排序）」抽成一个包内 helper（放 `fountain::fdbm.server`，两个 loader 同包，不必新建共享包）；排序统一用 std 的 `sort`。

### [轻微][存量] 节点重名校验写了两遍，第二处不可达

- **位置**：`fdbm/src/config/FdbmConfig.cj:78-81`（`getNodes` 用 `HashSet` 拒绝重名）与 `:408-415`（`validateNodes` 再查一次，异常文案同为 `duplicated node name`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「重复逻辑」、§1「恒真恒假分支 / 不可达语句」
- **证据**：静态确定 —— `FdbmSettings` 的构造器是 `private init`（`settings.cj:48`），实例只能经 `FdbmSettings.load()` 产生，而 `load()` 必先调 `getNodes`；因此 `validateNodes` 的失败分支永远不成立。
- **描述**：两条路径维护同一不变量，读代码时容易误以为第二处是「兜底」，实际是死分支；将来若允许其它方式构造 settings，两处文案/判定口径也可能漂移。
- **建议**：删掉 `validateNodes`，把重名判定留在唯一入口 `getNodes`；若出于内嵌场景保留，则注明「仅防御非 load 构造」。

### [轻微][存量] README 的 SQL 能力表比实现窄：漏 `DROP`/`TRUNCATE` 与 `BETWEEN`

- **位置**：`fdbm/README.md:190-195`、`README_en.md:209-214`；实现 `src/sql/SqlParser.cj:152-155`（`create|alter|drop|truncate` 一律进 `ddl()`）、`:559-581`（`drop table [if exists]` 解析）、`:658`（`between`）；`src/execute/executors.cj:1243-1314`（DDL 原样广播，不再校验动词）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「README 覆盖不足」、§13「文档过期」
- **证据**：静态确定 —— 解析器接受 `DROP`/`TRUNCATE` 并原样下推；`BETWEEN` 被解析且是 `step` 范围路由（`Single`/`Multi`/`Empty`）的唯一入口（`doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md:224`）。
- **描述**：README 的 DDL 行只写 `CREATE TABLE` / `ALTER TABLE`，用户会以为 `DROP`/`TRUNCATE` 被拒；WHERE 列表只写「比较/IN/LIKE/括号」，漏掉 `BETWEEN`，而范围分片恰恰是 `step` 算法最有价值的能力，文档里完全看不到。两处都是「实现比承诺多」，属于文档缺口而非代码缺陷。
- **建议**：DDL 行改为「`CREATE` / `ALTER` / `DROP` / `TRUNCATE`（`TABLE` 形式解析目标表，其余原样广播）」；WHERE 行补 `BETWEEN`，并注明「范围路由只对 `step` 生效，其它算法 → `Unroutable`」。

### [轻微][存量] README 配置表漏掉 `idMakerHostSerial`（snowflake 无参时的回退键）

- **位置**：`fdbm/README.md:160-168`、`README_en.md:175-184`；实现 `src/config/FdbmConfig.cj:512-529`；另有说明 `fdbm/doc/详细设计.md:1149`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「配置项未文档化」
- **证据**：静态确定 —— `fdbm_idmaker=snowflake` 且未带参数时，`validateIdMaker` 回退读 `idMakerHostSerial`；两者都没有则启动报 `CONFIG`。README 配置表没有该键。
- **描述**：只按 README 配置的运维会先拿到一条 `CONFIG` 报错，再回头翻代码/详细设计才知道存在这个兼容键；而 README 的表格标题是「配置项」，读者会当成全集（详细设计里虽有登记，但那是设计文档，不是运维手册）。
- **建议**：配置表补一行「`idMakerHostSerial` | 无 | 否 | `snowflake` 未在 `fdbm_idmaker` 带节点号时的兼容来源（0..1023）」；若已不打算支持，删除回退并在 `fdbm_idmaker` 缺失时报错。

### [一般][存量] 协议口径「`bufSize <= 0` 取默认块大小」已被 `-1` NULL 探测打破，README 未同步

- **位置**：`fdbm/README.md:225`（`README_en.md:257`）；实现 `fdbm/src/execute/cursor.cj:170-176`、`:186`；设计侧 `fdbm/doc/详细设计.md:1247-1251`（§14.4）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「参数默认值/语义与源码不符」、§14.2「客户端可见的协议保留值未文档化」
- **证据**：静态确定 —— `cell(index, bufSize)` 对流列先判 `bufSize < 0`（NULL 探测：NULL → `DataNone`，非 NULL → 首块），只有走到 `cursor.cj:186` 才用 `bufSize <= 0 → DEFAULT_STREAM_CHUNK`；README / `README_en.md` 全篇检索 `bufSize` 只命中该一处，均未出现 `-1`，而 `详细设计.md:1249` 已把「首次打开流列发 `CELL(index, -1)`」写成客户端行为
- **描述**：README 的「协议口径」声明「与 f_dbd 一致，这里是服务端实现」，却比实现少一个保留值语义。按 README 实现或排障的客户端会认为 `-1` 等同 `0`（返回首块），实际 NULL 列得到 `DataNone`；这也正是 harden 变更新增的兼容点（`design.md:290-297` 的兼容性论证依赖它）
- **建议**：README「协议口径」补一条：「流列 `bufSize < 0` = NULL 探测（保留值，`DataNone` 表示 SQL NULL），`bufSize == 0` = 默认块大小」；`README_en.md` 同步

### [轻微][存量] fix-fdbm-integration-test-driver-name 设计文档引用不存在的源码路径

- **位置**：`fdbm/doc/spec/fix-fdbm-integration-test-driver-name/design.md:55`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— 文中写 `` `fdbm/src/server/DatabaseResources.cj:69-73` ``，实际文件是 `fdbm/src/resources/DatabaseResources.cj:69-73`（`DriverManager.getDriver(node.driverName)` 正在 69 行），`fdbm/src/server/` 下无同名文件；同段其余引用均核对正确（`Integration_test.cj:295`、`FdbmTestSetup_test.cj:22`、`Server_test.cj:371-378`、`FdbmServer.cj:90-96`）
- **描述**：失效路径会让读者找不到「服务端按节点配置取物理驱动」这条论证的原文；同目录 `tasks.md` 附录 B 的 K1/K2 路径都正确，仅此处写错目录
- **建议**：改为 `fdbm/src/resources/DatabaseResources.cj:69-73`

### [轻微][存量] README 的 fdbm.sh「必填项只有三项」与脚本自身标注的必填项不一致

- **位置**：`fdbm/README.md:64-66`；脚本 `fdbm/fdbm.sh:135-139`、`:146`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13（文档与随模块交付的脚本不符）
- **证据**：静态确定 —— README 说脚本只保留「不配置就无法启动」的 `fdbm_db` + 每节点 `driver`/`database`，其余一律注释掉；脚本实际还有 5 个有效 `export`：`logger_appender_console` / `logger_appender_FdbmConsole_level` / `logger_appender_FdbmConsole_pattern`（135–139 行，无默认值）与 `protocol_hostId`（146 行，脚本注释标【必填】，`MessageID` 拒绝 `hostId=0`），另有 `LD_LIBRARY_PATH`（181 行）
- **描述**：按 README 判断「必填只有三项」的运维在不用脚本、手写环境变量启动时会漏掉 `protocol_hostId`；脚本自己已用第九/十节把这些项单列为「不属于 fdbm 的配置项」，README 没同步这个边界
- **建议**：该段补一句「另有 `f_log` / `f_protocol` 的必要项（`logger_appender_*`、`protocol_hostId`）由脚本第九/十节单列」，或把口径改成「fdbm 自身配置项」

### [轻微][存量] 启动自检对 `fdbm_checkDuration` 只校验正数，未校验「有限」，与另两个超时键不对称

- **位置**：`fdbm/src/config/FdbmConfig.cj:399-401`（对照 `:396`、`:403-405`）；规格源 `fdbm/doc/spec/harden-fdbm-stack-defects/spec.md:109`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定（不对称性）/ 待确认（可触发性）—— spec 写「`shutdownTimeout` / `checkDuration` / `unavailableChecked` / `sessionSweepInterval` 均为正且**有限**」，实现里 `shutdownTimeout` 与 `sessionSweepInterval` 都判了 `<= Duration.Zero || == Duration.Max`，`checkDuration` 只判 `<= Duration.Zero`（与 `unavailableChecked <= 0` 合并在一行）；缺的信息是 `Duration.tryParse` / `Duration.second * n` 溢出时是抛异常还是饱和到 `Duration.Max`
- **描述**：若 `Duration.Max` 可达，心跳检查周期会退化为「永不到期」，规格承诺的早失败落空；若不可达，则该条规格应改成只约束实际校验的两个键，否则每轮审查都会重复提出
- **建议**：补 `confs.checkDuration == Duration.Max` 判断使三键同口径，或把 spec 第 109 行的「均为正且有限」限定到 `shutdownTimeout` / `sessionSweepInterval`

### [轻微][存量] README 把退出码 1 描述为「启动自检失败」，漏掉监听失败路径

- **位置**：`fdbm/README.md:26`（`README_en.md:28`）；实现 `fdbm/src/main.cj:34-43`、`fdbm/src/server/FdbmServer.cj:173-179`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13（进程契约与实现不符）
- **证据**：静态确定 —— `main()` 对任何 `FdbmException` / `Exception` 都返回 1；监听失败（端口占用等）在 `start()` 里被包成 `FdbmException(INTERNAL)` 抛出，因此同样得到 1；`spec.md:169-173` 明确要求「监听失败不以 0 退出」
- **描述**：端口占用时运维看到退出码 1，按 README 会误判为配置自检失败，排查方向被带偏
- **建议**：改为「0=正常停止；1=启动失败（自检失败或监听失败），stderr/日志含具体错误码」

> 存量缺陷共 16 条（本部分全部为存量），是否纳入修复待用户决定。

## 优化可行性方案

### [CPU] 会话查找：每请求一次全局锁 + 一次 `remoteAddress.toString()`

- **现状**：每个请求都走 `SessionRegistry.of(buffer)`，在同一把全局 `Mutex` 内做 `keyOf(buffer)`（`remoteAddress.toString()` 字符串分配）与 `HashMap` 查找（`SessionRegistry.cj:46-58,152-159`）；临界区短，但**所有连接**在该锁上串行。会话数 = 并发连接数，字符串长度约 20 字节。
- **方案**：在 handler 入口按连接缓存 `DbdSession`（f_net 若提供连接级上下文则直接挂载；否则在 `SocketBuffer` 对象身份上做一次解析后缓存），后续请求不再进全局表；或把会话表按连接 id 分片成 N 把锁。键改整数/句柄，避免每请求字符串分配。
- **预期**：每请求去掉 1 次字符串分配 + 1 次全局锁往返；高并发（≥32 连接）下 p99 与 QPS 的改善幅度未知。
- **代价**：依赖 f_net 暴露稳定连接标识；`closeAll`/`sweep` 需要同时失效缓存，增加一处状态同步点；实现不当会重新引入「已关闭会话被复用」。
- **验证**：`cjprof record` 跑 1/8/32 连接各 10k 次查询，对照 `SessionRegistry.of` 自耗时与 p99；同时看分配量（`getAllocatedHeapSize`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `PartitionCache` 构造时全量遍历 `f_store` 只为计数，启动耗时随缓存键数线性增长 | `fdbm/src/route/cache.cj:45-51` | 键数 → 构造耗时曲线 | 造 1k/10k/100k 键后各启动 5 次，记构造分段耗时中位数 |
| 2 | `SessionRegistry.of` 的全局锁与字符串键在并发下成为串行段 | `fdbm/src/server/SessionRegistry.cj:46-58` | 该函数自耗时占比、锁等待 | `cjprof record` 跑 32 连接 × 10k 查询；另采线程 BLOCKED 时长 |
| 3 | `DatabaseResources` 同步建池（`initSize × 库数`）拉长启动时间，多库部署下明显 | `fdbm/src/resources/DatabaseResources.cj:66-104` | 库数/initSize → 构造耗时 | 10/100 个物理库、`initSize=1/8` 各启动 5 次，记 `FdbmServer` 构造耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/README.md` | .md | ✅ | 配置表/生命周期/协议口径与实现基本一致；API 段、事务口径、协议保留值与漏项见 #2、#4、#10、#11、#12、#14、#16 |
| 2 | `fdbm/README_en.md` | .md | ✅ | 与中文版逐节对应，无缺节；同源缺陷（#2、#4、#10、#11、#12、#14、#16）同步存在 |
| 3 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/design.md` | .md | ✅ | 与 `FdbmTestSetup_test.cj:22-31`、`Integration_test.cj:344-348` 一致 |
| 4 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/proposal.md` | .md | ✅ | 影响面描述与落地文件一致 |
| 5 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/tasks.md` | .md | ✅ | 勾选与证据自洽 |
| 6 | `fdbm/doc/spec/harden-fdbm-stack-defects/design.md` | .md | ✅ | D01–D12 / G01–G29 与实现逐项抽查一致；全局表口径与 #3 相关 |
| 7 | `fdbm/doc/spec/harden-fdbm-stack-defects/proposal.md` | .md | ✅ | 数量口径（12 P0 + 29 P1 + 51 一般）自洽 |
| 8 | `fdbm/doc/spec/harden-fdbm-stack-defects/spec.md` | .md | ✅ | 与 `specs/fdbm/spec.md` 仅差一行且该行写反，见 #3 |
| 9 | `fdbm/doc/spec/harden-fdbm-stack-defects/specs/fdbm/spec.md` | .md | ✅ | 该份与 design/代码一致 |
| 10 | `fdbm/doc/spec/harden-fdbm-stack-defects/tasks.md` | .md | ✅ | 附录 B 的 K1–K4 与代码现状吻合（K2 datasource 未关闭仍存在） |

合计：`.cj` 0 个 / `.md` 10 个 / 共 10 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 事务契约与实现不符（#2）、README API 段不可用（#4）、重复校验（#9）、协议 `-1` 保留值未进 README（#12）；本部分无外部输入解析与凭据落盘代码，安全性仅核对 `export` 白名单（`BootScriptWriter.cj:485-494`，已实现） |
| §1 死代码 | 2 | 已逐个 private/internal 符号搜引用：`getLogicalDatabases` 零引用（#7）；`validateNodes` 分支不可达（#9）。`canWrite/canRead` 仅测试引用，按判据记「可见性建议」不作死代码；对外可达 `public` 不判 |
| §2 重复逻辑 | 2 | 两 loader 的四个 helper 逐字相同 + 5 份插入排序（#8）；节点重名校验两遍（#9）。另：两份 spec 655/656 行重复维护，已并入 #3 |
| §3 空实现 | 0 | 已核对本部分涉及的空分支：`CustomLoader.cj:102/112` 的 `case _ => ()` 是「扩展未实现任一接口则不收集」，随后 `validate` 会以 `unknown id generator` 暴露，不构成静默失效；`catch (_: Exception) { () }` 只出现在资源清理（`DatabaseResources.cj:108-112/252-256`、`BootScriptWriter.cj:474-477`），语义为清理期忽略 |
| §4 栈溢出 | 0 | 本部分为文档；为核对文档读取的 config/server/execute 代码无递归调用（SQL 解析器递归在后续部分评估） |
| §5 OOM | 1 | `INSERT ... SELECT` 全量物化且无上限（#6）；`PartitionCache` 构造为流式遍历，不累积 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 cjprof / bench 数据，热点未成立；已列入「待验证假设」3 条 |
| §6.2 大粒度锁 | 0 | 唯一锁内 I/O 是 `BootScriptWriter.set/flush/normalize`（`BootScriptWriter.cj:96-160`，含 `readText`/`File.writeTo`/`rename`）；`EXPORT` 是低频管理语句且必须串行化才能保证脚本一致，无数据表明构成热点，不列为缺陷 |
| §6.3 并发串行 | 0 | 本部分读取路径中无 `spawn(...).get()`、无批大小为 1 的并行结构；会话查找的串行风险按「待验证假设 #2」处理 |
| §6.4 低效算法 | 0 | 5 处插入排序的 n 为节点/库/扩展/缓存键数量级（个位到百），启动期一次性，按判据不足以构成瓶颈；重复性已计入 §2 |
| §7 降堆内存方案 | 0 | 本部分为文档；为核对文档读取的会话/缓存结构未发现可量化的长期持有增长点，缓存与游标内存由后续部分评估 |
| §8 降 CPU 方案 | 1 | 会话查找的全局锁 + 每请求字符串分配（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分无函数内大临时对象；无改前/改后峰值内存数据，不做结论 |
| §11 现有代码的 BUG（存量） | 4 | 会话关闭与在途请求竞争（#1）、事务 pin 口径（#2）、会话键复用（#5）、`INSERT ... SELECT` 物化（#6） |
| §12 并发安全与锁粒度 | 2 | #1（缺失同步，数据竞争）+ #5（会话身份假设）；`PartitionCache` 关闭与读写共用一把锁（`cache.cj:54-120`）已核对为正确取舍 |
| §14 功能完备性与 README 覆盖 | 6 | README API 段（#4）、SQL 能力表漏项（#10）、配置键漏项（#11）、协议保留值缺失（#12）、fdbm.sh 必填项口径不全（#14）、退出码描述不全（#16）；SPEC 承诺的能力（`RETURNING`、`count(*)`、派生表、全局表、缓存关闭报错）均已接线，仅 `DROP/TRUNCATE`、`BETWEEN`、`idMakerHostSerial` 未进 README |
| 文件覆盖（§13 等） | 10/10 | 无缺失；文档引用活性扫描另发现 1 处失效路径（#13），`Integration_test.cj:344/295`、`FdbmTestSetup_test.cj:22`、`Server_test.cj:371-378`、`FdbmServer.cj:90-96`、`CustomLoader.cj:58-92`、`DatabaseResources.cj:61-115`、`executors.cj:693-760` 均核对存在 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

这批文档的密度与准确度明显高于一般项目：配置默认值、逻辑库命名空间规则、池参数、错误码、优雅停止顺序都能在源码里逐条对上，`harden-fdbm-stack-defects` 的 D/G 编号与实现也基本自洽。真正需要先处理的是**并发契约没有落到对象层**：`DbdSession` 的锁只保护引用，`QueryCursor`/`CursorSegment`/`PinnedConnection` 在巡检或关停线程里被摘除后立即关闭，而在途请求仍在使用同一对象；配合 `f_dbpool` 的「close 即回池」语义，存在同一条物理连接被两个借用者并发使用的风险（#1，阻塞项）。其次是与用户契约相关的两处文档问题：事务只能作用于 pin 的那个物理库、事务内 DDL 一律拒绝，README 完全没写而 spec 还写反（#2）；同一变更的两份 spec 对全局表是否隐式展开结论相反（#3）。这两条不修，按文档接入的人会直接踩到 `ROUTE_FAILED` 或误判全局表广播范围。其余为文档可读性与可维护性（API 段截断、死代码、重复 helper、README 能力表漏项），可以排期处理。另有一组小型文档账目建议随同一次整理收口：协议 `-1` 保留值只写在详细设计、README 仍按 `<= 0` 描述（#12），fdbm.sh 必填项与退出码描述比实现窄（#14、#16），fix 变更设计文档引用了一个不存在的目录（#13），`fdbm_checkDuration` 的「有限」校验与 spec 文本不对称（#15）。
