# fdbm 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`fdbm`（75 个文件：60 个 .cj + 15 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 6 个分部分报告合并：`parts/fdbm.part1..6.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [一般][存量] §10.6 的 `boot.sh` 示例与 `normalize()` 的值解析不兼容，按示例部署二次启动会失效

- **位置**：`fdbm/doc/详细设计.md:1037`、`:1039`、`:1041`、`:1114`（示例把 `fdbm_bootScript` / `fdbm_driverDir` / `fdbm_customDir` / `fdbm_cachePath` 写成 `"$(cd "$(dirname "$0")" && pwd)/…"`）；实现 `fdbm/src/config/BootScriptWriter.cj:343-355`（`parseExport` → `shellUnquote`）、`:510-515`（只剥单引号）、`:497-507`（`shellQuote` 无条件包单引号）、`:169-188`（重渲染整块）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例代码不能用」「规格与实现漂移」；文档自身 §3.5 第 5/7 条（`详细设计.md:286-289`，要求「值按 shell 单引号转义」「两次 flush 字节一致」）
- **证据**：静态确定 —— `shellUnquote` 只在「首尾都是单引号」时剥一层，双引号值**原样返回**（含 `"` 与 `$`）；`renderBlock` 再用 `shellQuote` 整体包单引号。因此示例行会被重写成 `export fdbm_bootScript='"$(cd "$(dirname "$0")" && pwd)/boot.sh"'`，shell 不再做命令替换
- **描述**：`normalize()` 在 `FdbmServer` 构造期无条件执行（`fdbm/src/server/FdbmServer.cj:136`、`:226-235`）。按 §10.6 落地的脚本**第一次启动就被改写**：当前进程不受影响（环境变量已展开），**下一次启动** `fdbm_bootScript` 是含字面 `"`/`$` 的路径（`bootScriptOf` 拿不到可读文件 → `export` 落盘不可用），`fdbm_driverDir` 同理失效 → `DriverLoader` 找不到驱动目录 → `NO_DRIVER` → 进程以 1 退出。与文档「规范脚本不产生写回 / 幂等」的承诺相反
- **建议**：`parseExport` 对双引号 / `$(...)` / 反引号值**整行保留、不参与重渲染**（或记 WARN 后跳过该键）；§10.6 示例改成生成器真实输出（`'./boot.sh'` 这类相对路径，见 `fdbm/boot.sh:12-20`）。用例：取 §10.6 脚本连续 `normalize()` 两次，断言第二次返回 `false` 且 `export fdbm_bootScript=` 行语义不变

### [一般][存量] `bufSize` 三档语义：§9.1 与 §14.4 自相矛盾，且 §9.1 / 开发计划与实现相反

- **位置**：`fdbm/doc/详细设计.md:738`（§9.1 注释「`readChunk(stream, bufSize)` 读下一块（`bufSize<=0` → `DEFAULT_STREAM_CHUNK`）」）、`fdbm/doc/详细设计.md:1249`（§14.4「首次打开流列发送 `CELL(index, bufSize = -1)` 探测 NULL」）、`fdbm/doc/开发计划.md:222`（阶段 7 Step 7.1 验收项 ⑤ 同 §9.1 口径）；实现 `fdbm/src/execute/cursor.cj:170-186`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」「文档内部不一致」；§11「语义与文档不符」
- **证据**：静态确定 —— 实现 `<0` 走 NULL 探测（`getOrNull<InputStream>`，NULL 回 `DataNone`，否则回**首块**），`==0` 才用 `DEFAULT_STREAM_CHUNK`（`cursor.cj:170-178`、`:186`）
- **描述**：同一份详细设计对 `bufSize` 给了两种口径。按 §9.1 写客户端：对 NULL 列发 `-1` 会得到 `DataNone`（被当成「空块」或直接判 EOF），对非 NULL 列发 `-1` 得到的是首块而非后续块；按 §14.4 写才对。这是线上列读协议，不是措辞问题
- **建议**：§9.1 注释改成三档（`<0` = NULL 探测，回 `DataNone` 或首块；`=0` = `DEFAULT_STREAM_CHUNK`；`>0` = 指定字节数），`开发计划.md:222` ⑤ 同步；归档 `spec.md:100-104` 的 `<=0` 保留原文，只在 §9.1 加一句「已被 §14.4 取代」

### [一般][存量] 流列 `-1` 分支绕过句柄缓存：重复探测会重复打开并重放首块（违反 §9.1 规则 5 与 spec MUST）

- **位置**：`fdbm/src/execute/cursor.cj:170-178`；文档 `fdbm/doc/详细设计.md:769`（规则 5「绝不重复打开」）、`:752`、`:739`；`fdbm/doc/spec/.../spec.md:82-86`（「`get<InputStream>` 只被调用 1 次」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§13；spec 的 MUST 项
- **证据**：静态确定 —— `if (bufSize < 0)` 分支直接 `currentResult().getOrNull<InputStream>(index)` 并覆盖 `streams[index]`，**不查** `streams`；只有 `>=0` 路径先查缓存（`:179-185`）
- **描述**：`bufSize` 由客户端控制。同一行同一列发第二次 `-1`：物理 `get<InputStream>` 再次执行（对真流式驱动等于重取列值，旧句柄被覆盖且未关闭），返回的又是**第一块**，块序错乱。文档把「每行每列只打开一次」当服务端契约（§9.1 规则 5），实现只在 `>=0` 路径上成立；§14.4 仅约定「客户端只发一次」，服务端没有防御
- **建议**：`<0` 分支先查 `streams`，已存在则按 `DEFAULT_STREAM_CHUNK` 读下一块（或回 `CURSOR_STATE` 拒绝重复探测）；首次打开后缓存。用例：连续两次 `cell(i, -1)`，断言打开计数为 1 且第二次不是首块重放

### [一般][存量] §2 包结构表把自定义扩展写成 `fountain::fdbm.custom` / `src/custom/`，仓库无此目录

- **位置**：`fdbm/doc/详细设计.md:76`；实现 `fdbm/src/server/CustomLoader.cj:16`（`package fountain::fdbm.server`）、`:29`（`CustomExtensions`）、`:65`（`CustomLoader`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期（已改名）」；§14.1「接线缺失」的文档侧对应
- **证据**：静态确定 —— `fdbm/src/custom` 不存在，`CustomExtensions`/`CustomLoader` 都在 `server` 包；同一文档 §10.5 也把它们放在 server 章节
- **描述**：§2 与 §10.5 互相矛盾。按 §2 找扩展入口（`custom` 包的职责、依赖 f_app/f_dbm/f_log）会落空，判断「`execute` 能否依赖自定义扩展」会得出错误结论
- **建议**：删除该行或改为 `fountain::fdbm.server`（`CustomLoader.cj`），依赖列写 `f_app / f_dbm / f_log / exception`

### [一般][存量] §10.3 声称会话键是连接对象，实现用 `remoteAddress` 文本

- **位置**：`fdbm/doc/详细设计.md:939`（「键即连接对象，不需要断连回调」）、`:925-929`；实现 `fdbm/src/server/SessionRegistry.cj:46-58`、`:152-159`（`keyOf` = `buffer.remoteAddress.toString()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13；§12.1「跨线程资源 / 会话隔离」
- **证据**：漂移静态确定；后果待确认 —— 「同一 4 元组在旧会话被巡检移除前被复用」需要 `f_net` 侧地址复用与 TCP 复用路径的证据
- **描述**：`of()` 只按地址文本查表。若旧会话仍在表里（巡检周期 30s 内）而新连接复用了同一地址，`of()` 直接返回旧 `DbdSession`，它带着上一条连接的游标与事务 pin，而 `session.buffer` 指向旧连接——文档「键即连接对象」的隔离承诺不成立。`size()` 与巡检也按文本键聚合
- **建议**：用连接身份（或 `f_net` 暴露的连接 id）做键；坚持文本键时在 `of()` 校验 `session.buffer` 与入参为同一对象，不同则关闭旧会话再新建。用例：同地址字符串的两个不同 buffer，断言 `of()` 返回不同会话

### [一般][存量] 详细设计的类型声明与签名已落后于实现（多处悬空引用）

- **位置**（文档 → 实现）：
  - `fdbm/doc/详细设计.md:396-398`：三个独立类 `Crc16Partition` / `Crc32Partition` / `Crc64Partition`。实现是单个 `protected class CrcPartition`（`fdbm/src/route/algorithms.cj:172`），三个类名在 `src/` 中不存在；`开发计划.md:162` 同
  - `fdbm/doc/详细设计.md:339-344`：`protected struct DatabaseResources` + 字段 `readNodes`/`writeNodes`/`pools`/`names`。实现为 `protected class`（`fdbm/src/resources/DatabaseResources.cj:46`），字段是 `readNodes_`/`writeNodes_`（`:48-49`），另有 `writePools`/`readPoolNames`/`poolLabels`/`driverNames`/`closed`
  - `fdbm/doc/详细设计.md:707`：`installCursor(cursor: QueryCursor): Unit`。实现返回 `Bool`（`fdbm/src/execute/session.cj:100`，`false` 表示会话已关闭且新游标已被关闭）
  - `fdbm/doc/详细设计.md:783-789`：`ExecutorDispatcher.init(router, globals, resources, idMakers, bootScript, config: FdbmConfig)`。实现 8 参（`idmaker`、`sequenceDatabase`、`customIdGenerators`、`catalog!`，`fdbm/src/execute/dispatcher.cj:44-47`），`FdbmConfig` 不再是入参
  - `fdbm/doc/详细设计.md:886`：要求 `Server<DataAny>(bufferQueueSize!: …)` 显式传。实现未传（`fdbm/src/server/FdbmServer.cj:155-160`）
  - `fdbm/doc/详细设计.md:127-147`（§3.2）：成员全写 `public static func`，实现是包内 `static func`（`fdbm/src/config/FdbmConfig.cj:40`）；清单缺 `getPartitionStep`（`:140`）、`getLogicalDatabases`（`:149`）、`getCheckDuration`（`:317`）、`getUnavailableChecked`（`:325`）、`getSequenceDatabase`（`:337`）；`validate` 实际多 `source!` 参数（`:376-377`）
  - `fdbm/doc/详细设计.md:44-60`（§1.2 依赖表）：漏 `fountain::f_data`（`fdbm/cjpm.toml:7`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」「文档过期」；§14.1「接线缺失」
- **证据**：静态确定 —— 上述符号在全仓搜索要么不存在（`Crc16Partition` 等），要么签名不同（`installCursor`、`ExecutorDispatcher.init`）
- **描述**：详细设计是唯一的实现说明（README 只讲用法），但它记录的是编码期草案：算法类被合并、`struct` 变 `class`、两个关键签名改了没回填、config 成员表不完整。按文档找代码会落空，按文档写扩展会编译不过（`installCursor` 的返回值、`ExecutorDispatcher` 的参数个数）
- **建议**：以 `src/` 为准回填 §1.2 / §3.2 / §5 / §6.1 / §9.1 / §9.2 / §10.1；或在这些片段前统一标注「示意，签名以源码为准」

### [轻微][存量] §3.5 的写回细节与实现不符：END 标记、临时文件名、权限位三项

- **位置**：`fdbm/doc/详细设计.md:282-289`（只描述新旧两个标记、`boot.sh.tmp`、「复制原文件权限位」）；实现 `fdbm/src/config/BootScriptWriter.cj:35-37`（三个标记，含 `END_MARKER`）、`:188`（总会写 END 标记）、`:463`（临时文件是 `<target>.tmp.<serial>`）、`:454-458`（注释自认权限位与设计不符并称「已在详细设计登记」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 设计全文没有 `fdbm managed exports end`、没有 `.tmp.<serial>`、也没有权限位偏差的登记（「权限」只出现在 §3.5「复制权限位」与 §13 测试策略）
- **描述**：实现写出的区块比文档多一行 END 标记（`fdbm/boot.sh:93` 有，§10.6 示例 `:1030-1116` 没有）；代码注释指向的「已登记」不存在，读者会以为完整 mode 位被保留（实际只保留可执行位）。缺 END 标记时 `parseBlock` 靠首个非 export/注释行截断（`BootScriptWriter.cj:317-339`），所以不致命，但两处描述都对不上实现
- **建议**：§3.5 补 END 标记的作用与缺省兼容行为、改成 `.tmp.<serial>`、写明「只保留可执行位」；或删掉代码注释里的「已登记」

### [轻微][存量] §10.1 把装配步骤写成 `start()` 的流程，且 `ServerContext` 多一个 `inFlight` 成员

- **位置**：`fdbm/doc/详细设计.md:878-888`（步骤 1-9）、`:294`（`normalize()` 在「§10.1 第 6 步」）、`:897-903`（`ServerContext.inFlight`）；实现 `fdbm/src/server/FdbmServer.cj:56-143`（装配全在构造函数）、`:150-180`（`start()` 只建 `Server` + 注册退出回调 + `server.start`）、`fdbm/src/server/context.cj:22-33`（无 `inFlight`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13、§14.1「接线缺失」
- **证据**：静态确定 —— `CustomLoader`/`validate`/`DriverLoader`/`DatabaseResources`/`Router`/`normalize`/`SessionRegistry` 都在构造函数里；`InFlight` 是静态 `struct`（`fdbm/src/server/InFlight.cj:28`），不是注入依赖
- **描述**：行为上仍满足「接受连接前完成自检」，但按文档排查启动顺序（`normalize()` 时机、巡检定时器何时启动）会定位错位置；`ServerContext` 的 `inFlight` 让读者以为在途计数可按实例替换。另：§10.1 第 4/5 步顺序与实现相反——实现先 `PartitionRouter`（`FdbmServer.cj:99`）后 `DatabaseResources`（`:108`）
- **建议**：§10.1 改成「构造期：1-7；`start()`：8-9」，§3.5 的时机改成「构造期（监听之前）」；删掉 `ServerContext.inFlight` 或注明是全局静态；调整第 4/5 步顺序

### [轻微][存量] §6.1 写「Murmur 取低 64 位」，实现用 `UInt128.hashCode()`

- **位置**：`fdbm/doc/详细设计.md:399`、`fdbm/doc/开发计划.md:162`；实现 `fdbm/src/route/algorithms.cj:224-226`、`:284-286`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `murmurHash` 返回 `UInt128`，实现直接 `.hashCode()` 取模，没有显式低 64 位截取
- **描述**：同一键在当前 SDK 内稳定，但与文档承诺不一致；`hashCode` 不属于跨版本稳定契约，若 SDK 调整实现，murmur 分片会整体漂移（存量数据读不到）。影响面待确认
- **建议**：显式 `UInt64(hash & 0xFFFF_FFFF_FFFF_FFFF)` 再取模并固定下来，或把文档改成「按 SDK 的 `hashCode` 取模」

### [轻微][存量] §7 写「默认逻辑库的第一个物理库」，§14.1 与实现是「物理库排序首项」

- **位置**：`fdbm/doc/详细设计.md:534` vs `:1227`、`:119`；实现 `fdbm/src/config/FdbmConfig.cj:337-368`（`smallest()` 取字典序最小）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档内部不一致）
- **证据**：静态确定 —— `smallest()` 逐项比较取名序最小，不是配置书写顺序首项
- **描述**：同一参数两种口径。`fdbm_db_logicalDatabase_order='db2,db1'` 时读者预期 `db2`、实现取 `db1`；`fountain_sequence` 建错库会在启动自检报 `ID_GENERATOR`
- **建议**：统一为「物理库名排序首项」，§7 与 §14.1 同步

### [轻微][存量] `开发计划.md` 的文件清单、测试替身名与两处签名已过期

- **位置**：`fdbm/doc/开发计划.md:9`（`src/resources/fake_accessor_test.cj` + `FakeNodeAccessor`）、`:34`（阶段 1 漏 `catalog.cj` / `models.cj` / `source.cj`）、`:129`（`accessor.cj`、`fake_accessor_test.cj`）、`:141`（`init(nodes, pools, weights)`）、`:155`（`algorithm.cj` / `PartitionRule.cj` / `PartitionRouter.cj` / `PartitionCache.cj` / `GlobalTableRouter.cj`）、`:204`（`IdMakers.forTable(config, resources, logical, table)`）、`:222` ⑦（越界 index → `CURSOR_STATE`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「路径失效」「示例引用了不存在的 API」
- **证据**：静态确定 —— 实际文件是 `src/resources/DatabaseResources.cj`、`src/route/{algorithms,router,cache,global}.cj`；`FakeNodeAccessor` 全仓只在 `DatabaseResources.cj:28` 的注释里出现，测试用 `RecordingAccessor`/`FailingAccessor`（`src/execute/Dispatcher_test.cj:1002`、`:1045`）；`forTable` 实为 6 参（`src/idmaker/IdMakers.cj:229-231`）；越界 index 实际抛 `CONVERSION`（`src/execute/cursor.cj:151-153`）；`DatabaseResources.init` 第二参是 `PoolConfig`（`src/resources/DatabaseResources.cj:68-69`）
- **描述**：计划书是 TDD 执行入口，按图索骥找不到文件、找不到夹具、断言错错误码。计划文档存在本身就是给后来者照着做的
- **建议**：补一句「文件名为计划期命名，实际见 `src/`」，并回填上述 5 处；或整体标注「历史计划，验收记录见文末 2026-10-21 一节」

### [轻微][存量] §6.3 / §10.4 的缓存实现细节与代码不符（`unsafeBytes`、`syncWAL`）

- **位置**：`fdbm/doc/详细设计.md:490`（`'…'.unsafeBytes()` / `<physical>.unsafeBytes()`）、`:948`（「`syncWAL` 后关闭」）；实现 `fdbm/src/route/cache.cj:83-84`、`:126-128`（`toArray()`）、`:109-120`（只调 `store.close()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13
- **证据**：静态确定 —— `fdbm` 全仓无 `syncWAL` 调用；键值字节内容等价，所以不是数据错误
- **描述**：文档描述的 API 与落盘步骤不存在，按文档做容量 / 性能评估会建立在错误假设上（`unsafeBytes` 免拷贝、`syncWAL` 显式刷盘）
- **建议**：文档改成 `toArray()` 与「依赖 `Store.close()` 内部 flush」，或实现补 `syncWAL()`

存量缺陷共 12 条（一般 6 / 轻微 6），是否纳入修复待用户决定；其中 `boot.sh` 示例改写（#1）、`bufSize` 三档口径（#2）、流列重复探测（#3）建议优先。

<!-- 第 3 部分 -->

### [严重][存量] EXPORT 的键空间无上限：`pending` 与 boot.sh 无界增长，且每次 `flush` 全量重写（O(N²)）

- **位置**：`fdbm/src/config/BootScriptWriter.cj:91`（`set` 累积 `pending`）、`fdbm/src/config/BootScriptWriter.cj:109`（`flushLocked` 全量读→全量写）、`fdbm/src/config/BootScriptWriter.cj:485`（`isWritableKey` 前缀白名单）
- **来源**：存量（快照模式无基线；`git blame` 显示 `set`/`pending` 写于 `c81e5dcc2a`(2026-10-18) 与 `81084fb094`(2026-10-21)，早于本次快照 `120fd2542`）
- **判据**：review-checklist §5（无界容器 / 按不可信输入增长）、§14.1（无配额、无拒绝路径）
- **证据**：静态确定 —— `isWritableKey` 只做前缀匹配（`fdbm_db_driver_` / `fdbm_db_database_` / `fdbm_db_username_` / `fdbm_db_password_` / `fdbm_db_logicalDatabase_` / `fdbm_databasePool*` / `fdbm_loadbalance_weight_` / `fdbm_partition__` / `fdbm_partition_substr__` / `fdbm_global__`），后缀是任意长度任意内容；`pending[key] = value`（:98）之后再无删除路径（`flush` 只合并不清理）；`ExportExecutor`（`fdbm/src/execute/executors.cj:1231`）对每条 EXPORT 都执行 `set` + `flush`，全链路无 key 数量、文件大小或频率限制。
- **描述**：`EXPORT` 是协议可达的普通 SQL（设计 §8.1 表格第 `EXPORT <key>=<value>` 行），任何能发 SQL 的客户端都能用不同后缀无限追加键。每追加一个键：① 进程内 `pending` 永久多一条；② boot.sh 多两行；③ 下一次 `flush` 重新读入整个文件、重建整个块、回写整个文件。N 次 EXPORT 的累计 I/O 与 CPU 为 O(N²)，文件与内存随 N 线性增长，没有任何拒绝路径（到 OOM / 磁盘满才终止）。这与「配置项数量由部署决定」的实际语义不符——白名单只是前缀，不是有限集合。
- **建议**：把可写键收敛为「有限集合 + 已配置实体」：`fdbm_db_*_<node>` 的 `<node>` 必须出现在 `fdbm_db` 里、`fdbm_partition__<table>` / `fdbm_global__<table>` 必须是已存在的表名、`fdbm_databasePool` 只接受 §3.4 列出的 12 个后缀；同时对 `pending` 条数与 boot.sh 大小设上限（超额抛 `CONFIG`）。

### [一般][存量] EXPORT 只校验键名不校验值：非法值会持久化，下次启动直接 CONFIG 失败

- **位置**：`fdbm/src/config/BootScriptWriter.cj:91`（仅 `isWritableKey(key)`，值原样 `shellQuote` 落盘）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（半接线：写入侧有校验、读取侧才有语义校验）、§11（契约与实现不符）
- **证据**：静态确定 —— `set` 只判键名；`ExportStatement.value` 来自单个 token（`fdbm/src/sql/SqlParser.cj:584`，`Text`/`Ident`/`Number` 三选一，原样取 `token.text`），可自由携带 `'a,bogus,c'`、`'abc'`、`'garbage'`；`FdbmSettings.load` 在下次启动会经 `FdbmConfig.get*` 重新解析并抛 `FdbmException(CONFIG)`（如 `fdbm_partition__x` 算法名非法 → `PARTITION_CONFIG`，`fdbm_port=abc` → `CONFIG`）。
- **描述**：运行期 `EXPORT fdbm_partition__t 'a,bogus,c'` 会成功返回（`Config.set` 立即生效、脚本已改），但这条规则不会参与本轮启动的路由构建，只会在**下一次启动**让进程起不来。运维视角是「昨天成功的一条 SQL 让今天服务无法启动」，且错误位置离操作现场很远。
- **建议**：落盘前用「键 → 解析器」映射做一次试解析（可用 `MapConfigSource` 构造单键源后调对应 `FdbmConfig.get*` / `validate*`），非法值直接回 `CONFIG`，与读取侧共用同一套校验，避免写入侧与读取侧规则漂移。

### [一般][存量] `normalize()` 的缩进判定与设计不符：tab 缩进的顶层 export 会被迁出函数，无区块时插入点可能落在函数体内

- **位置**：`fdbm/src/config/BootScriptWriter.cj:377`（只判 `!lines[i].startsWith(' ')`）、`fdbm/src/config/BootScriptWriter.cj:421`（无区块时按 `startsWith('export fdbm_')` 找插入点，完全不判缩进）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§13（`doc/详细设计.md:295`「只整理脚本中已有的顶层（行首无缩进）`export fdbm_*` 行……缩进在其他函数/条件里的 `export` 原样保留」）
- **证据**：静态确定 —— ①`'\texport fdbm_port=1'` 的 `startsWith(' ')` 为 false，会被当成顶层行迁走并从原位置删除，函数体里少一条 export；②无 managed 区块时，插入点只搜 `outside[i].startsWith('export fdbm_')`（:424），若第一条这类行是 `    export fdbm_port=1`（缩进在函数内，仓库自带的 `fdbm/boot.sh:127` 就有这种形态的 `export LD_LIBRARY_PATH`），新区块会被整段插进函数体。
- **描述**：`normalize()` 在每次 `FdbmServer.start()` 都会跑（`fdbm/src/server/FdbmServer.cj:230`），失败不阻塞启动、也不报错，所以脚本结构被改坏是静默的。判据两处用了两套缩进口径（一处只排空格、一处完全不判），同一份脚本可能同时踩到「迁多了」和「插错位置」。
- **建议**：抽一个 `isTopLevel(line)` 判定（`line` 首字符不是空格 / tab 且不以 `#` 开头），迁移与插入点搜索共用；插入点搜索只认 `isTopLevel && startsWith('export fdbm_')`，找不到就追加到文件末尾。

### [一般][存量] `parseBlock` 把任意 `export ` 行当作块内容：END 标记缺失时，块后无关 export 被静默删除

- **位置**：`fdbm/src/config/BootScriptWriter.cj:330`（`if (trimmed.startsWith('export ')) { if (let Some(...) = parseExport(...)) {...}; end += 1; continue }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 数据丢失）、§3（失败路径当成功）
- **证据**：静态确定 —— 循环只在命中 `END_MARKER`（:322）或遇到既非空行、非注释、非 `export ` 的行（:337）时结束；`parseExport` 对非 `fdbm_` 键返回 `None` 后**仍然** `end += 1` 把它们吞进块区间。`flushLocked`（:133）与 `normalizeText`（:401）随后用 `[start, end)` 整段替换 ⇒ 这些行被丢弃。
- **描述**：正常形态下块内有 END 标记，行为符合「区块由 fdbm 独占」。但一旦 END 标记缺失（手工编辑、旧格式只带起始标记、写入被截断），块区间会一路吃掉紧随其后的 `export logger_appender_console=...`、`export protocol_hostId=...`（仓库自带 `fdbm/boot.sh:98/108` 就是这种紧邻形态）这类**非 fdbm 的 export**，直到第一条非 export 语句为止。这些行既不在 managed 块内、也不属于 fdbm，删除前只字未提（无 WARN）。
- **建议**：`export ` 分支里先判 `key.startsWith('fdbm_')`，非 fdbm 行直接 `break`（保留在原地）；END 标记缺失时额外记一条 WARN 说明「块未闭合，按首个非 fdbm export 截断」，避免静默吞行。

### [一般][存量] 重写 boot.sh 只复制可执行位：原始权限位丢失，内含明文 `fdbm_db_password_*` 的脚本可能被放宽为组/其他可读

- **位置**：`fdbm/src/config/BootScriptWriter.cj:460`（`writeAtomically`，仅 :466 `canExecute()` + :467 `setExecutable(true)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（安全性 / 资源不对称）、§13（`doc/详细设计.md:287` 仍写「复制原文件权限位」，代码注释 :456 却称「已在详细设计登记」，设计里查不到该偏差）
- **证据**：静态确定（只搬可执行位，代码注释与设计文本自认）；最终 mode 待确认 —— 缺 `std.fs` 的默认创建权限与 umask 实测数据，无法断言具体数值。
- **描述**：临时文件由 `File.writeTo` 新建后仅 `setExecutable(true)`，再 `rename` 覆盖原文件。原脚本若是 `0600` / `0640`（部署时保护 `fdbm_db_password_name0` 的常见做法），重写后变成「默认创建权限 + 可执行位」，通常即 `0755`/`0644`，等于把明文凭据从「仅属主可读」放宽到「同机其他用户可读」。触发点有两条：启动期 `normalize()`（每次启动都跑）与任意一次 `EXPORT`。测试 `flushKeepsExecutableBit`（`BootScriptWriter_test.cj:219`）只断言可执行位，覆盖不到这条。
- **建议**：`rename` 前把原文件的完整权限位补到临时文件（`std.fs` 若无等价 API，至少显式 `setReadable/ setWritable` 到「属主读写、其他不读」并记一条 WARN）；同时把设计 §3.5 第 6 条改成实际行为，或按设计补齐实现。测试补一条「原文件 0600，flush 后仍不可被其他用户读」。

### [一般][存量] 连接池参数缺少下界校验：负数直接传给 `f_pool`，与同文件其它数值项的校验口径不一致

- **位置**：`fdbm/src/config/FdbmConfig.cj:97`（`getPool` 的 12 个参数全部走 `intOf`）、`fdbm/src/config/FdbmConfig.cj:658`（`maxWaitingOf` 把 `<= 0` 一律当无限等待）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界校验）、§10（错误处理）
- **证据**：静态确定（无任何范围检查）；后果待确认 —— `f_pool` 的 `Pool` 构造（`f_pool/src/Pool.cj:141`）也未校验 `minSize/maxSize`，负 `maxSize` 具体表现（永久借不到连接 / 立即抛错 / 静默死锁）需实测。
- **描述**：`fdbm_partition_step`（:140）与 `fdbm_cache_size`（:286）都做了正值/非负校验，但池参数完全没有：`fdbm_databasePoolMaxSize=-1`、`InitSize=-5`、`ConnectTimeout=-1` 都会被接受并传入连接池；`MaxWaiting=-1` 又被 `maxWaitingOf` 静默当成「无限等待」，把一处配置笔误变成「池耗尽即永久阻塞」。
- **建议**：在 `getPool` 里补一组校验（`InitSize/MinSize/MaxSize >= 0`、`MinSize <= MaxSize`、`ConnectTimeout > 0`、`MaxWaiting >= 0` 且 `-1` 不接受），失败抛 `CONFIG` 并带键名与原值；`maxWaitingOf` 只对 `0` 特判为无限。

### [轻微][存量] 死代码：`FdbmConfig.getLogicalDatabases` 全仓无引用

- **位置**：`fdbm/src/config/FdbmConfig.cj:149`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal`/默认可见性符号，本包及子包内无调用者）
- **证据**：静态确定 —— 排除 `.worktrees` 后全仓 `grep -F "getLogicalDatabases"` 仅命中定义行；`FdbmSettings` 的 `logicalDatabases` 字段实际由 `catalog.toMap()` 填充（`fdbm/src/config/settings.cj:63`），设计 §3.2 的 `FdbmConfig` 成员表也没有它。
- **描述**：遗留的便捷封装，已被 `settings.cj` 的写法取代；保留会让人误以为存在第二条装载路径（它会用空 `partitions` 重建 catalog，语义与 `load()` 不同）。
- **建议**：删除；若要保留，改成 `catalog.toMap()` 的直通并在设计 §3.2 登记。

### [轻微][存量] 恒假/不可达分支三处

- **位置**：`fdbm/src/config/FdbmConfig.cj:631`（`durationOf` 的 `seconds: false` 分支）、`fdbm/src/config/FdbmConfig.cj:225`（`getIdMaker` 的 `parts.size == 0`）、`fdbm/src/config/FdbmConfig.cj:469`（`!catalog.contains(rule.database)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒真恒假分支）
- **证据**：静态确定 —— ①`durationOf` 的 3 个调用点（:306/:310/:318）全部传 `seconds: true`，毫秒分支永不执行；②`String.split` 至少返回 1 个元素，`parts.size == 0` 不可能成立；③`LogicalCatalog.of` 在 :75 对每条规则执行 `ensure(mapping, rule.database, all)`，而 `confs.catalog` 就是由同一份 `confs.partitions` 构建的（`settings.cj:82`），故该 `contains` 对 `load()` 产出的 settings 恒为 true（`FdbmSettings` 构造器是 `private`，没有第二条构造路径）。
- **描述**：三处都不会被触发，但都保留了「有分支」的假象：`seconds` 参数实际是常量、`catalog.contains` 看起来在校验分库规则的库名而实际不校验（未知库名被隐式展开为全部物理库，这是设计 §3.1 的既定行为，不是缺陷）。
- **建议**：`durationOf` 去掉 `seconds` 参数（或补一个真正使用毫秒的调用点/用例）；`getIdMaker` 简化为 `let kind = parts[0].trimAscii().toLower()`；`validatePartitions` 删掉这条永假校验并在注释里写明「分库规则的库名为隐式展开」。

### [轻微][存量] 未使用的 import：`fountain::f_data.DataParsable`

- **位置**：`fdbm/src/config/FdbmConfig.cj:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件对 `DataParsable` 的命中只有 import 行本身（`grep -n DataParsable` 仅 1 行）；`tryParse` 由 `std.convert.*` 提供。
- **描述**：多余的编译期依赖，会让 `f_data` 的变更无谓牵动本文件。
- **建议**：删除该 import。

### [轻微][存量] 重复逻辑：同语义的解析/去重/包含/排序/默认值各写两份

- **位置**：
  - `FdbmConfig.splitNonEmpty`（`fdbm/src/config/FdbmConfig.cj:808`）≡ `LogicalCatalog.splitValue`（`fdbm/src/config/catalog.cj:138`）：都是「按 `,` 切、trim、丢空、全空则抛」，错误文案逐字相同
  - `FdbmConfig.containsName`（`FdbmConfig.cj:558`）≡ `FdbmConfig.isSubstrHash`（`FdbmConfig.cj:799`）：同样的线性查找，且都在重复 `Array.contains`
  - `BootScriptWriter.sortedByKey`（`BootScriptWriter.cj:530`）≡ `LogicalCatalog.sortInPlace`（`catalog.cj:184`）：逐行对齐的插入排序，只差元素类型
  - `LogicalCatalog.dedup`（`catalog.cj:152`）与 `sortedPhysicals`（`catalog.cj:163`）内联的 `seen.add` 去重环：同一去重语义两份
  - `FdbmConfig.getPool` 的 12 个默认值（`FdbmConfig.cj:99`）≡ `PoolConfig` 构造器默认值（`fdbm/src/config/models.cj:69`）：同一张字面量表两份
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改类型名 / 字面量复制）
- **证据**：静态确定（逐函数体摘要比对：输入→输出→副作用一致，无语义差异）
- **描述**：目前两两行为一致，但任何一次单边修改都会造成漂移：例如改了 `splitNonEmpty` 的错误文案，`splitValue` 不会跟；改了池默认值，`getPool` 与 `PoolConfig()` 会给出两个「默认值」。
- **建议**：`splitValue` 收敛到 `FdbmConfig.splitNonEmpty`（catalog 依赖 config 会形成环，正确落点是把该工具提到 `config` 包内的一个 `internal func`，两处共用）；`containsName`/`isSubstrHash` 直接用 `Array.contains`；两处插入排序换成 `std.sort`（见「优化可行性方案」）；池默认值只保留 `PoolConfig` 一份，`getPool` 用 `PoolConfig()` 取值作 fallback。

### [轻微][存量] 近似重复＋行为漂移：`durationOf` 与 `durationValue` 对裸数字的态度不同

- **位置**：`fdbm/src/config/FdbmConfig.cj:619`（`durationOf`，接受裸数字，`seconds` 决定单位）vs `fdbm/src/config/FdbmConfig.cj:643`（`durationValue`，只接受 `Duration` 文本）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复，其中一块少了分支 —— 往往同时是缺陷）
- **证据**：静态确定 —— `fdbm_cache_expire=3600` 走 `durationValue` → `CONFIG('not a Duration')`；同样写法的 `fdbm_checkDuration=3600`、`fdbm_sessionSweepInterval=3600`、`fdbm_shutdownTimeout=3600` 都被 `durationOf` 当秒接受。README 只对 `fdbm_cache_expire` 标注了「`Duration`，如 `30s`」，所以文档没错，是同一模块内两套时长口径。
- **描述**：使用者很容易按「裸数字＝秒」的惯例配置缓存过期时间，得到一条启动失败；换个键同样的写法又能用。
- **建议**：两者合并为一个 `durationOf(source, key, fallback, unit!)`，`fdbm_cache_expire` 也接受裸数字（`0` 表示不过期或保持「空＝永久」），或反过来在文档与错误信息里明确「本键必须带单位」。

### [轻微][存量] `BootScriptWriter` 内同一份「键族」被三张平行表重复描述

- **位置**：`fdbm/src/config/BootScriptWriter.cj:485`（`isWritableKey`）、`fdbm/src/config/BootScriptWriter.cj:193`（`groupOf`）、`fdbm/src/config/BootScriptWriter.cj:256`（`commentOf`），另有 `FIXED_COMMENTS`（:40）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一组字段名/前缀散落多处）
- **证据**：静态确定 —— 新增一个配置键要同步改 4 处：不写 `isWritableKey` → EXPORT 被拒；写了但不写 `groupOf` → 落到「9. 其他」；不写 `commentOf` → 注释退化为「未归类」；不写 `FIXED_COMMENTS` → 分组/注释/白名单全丢。
- **描述**：不是当前缺陷（现有键四处一致），但漏改一处不会编译失败、也不会报错，只会在 boot.sh 里静默降级。
- **建议**：合并成一张 `Array<(prefix, group, commentTemplate)>` 表，`isWritableKey`/`groupOf`/`commentOf` 都从它派生；新增键只需加一行。

### [轻微][存量] 直接下标取首元素三处，未处理空集合

- **位置**：`fdbm/src/config/catalog.cj:79`（`all[0]`）、`fdbm/src/config/FdbmConfig.cj:355`（`catalog.allPhysicals()[0]`）、`fdbm/src/config/FdbmConfig.cj:361`（`smallest` 的 `physicals[0]`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空集合未处理）
- **证据**：静态确定（下标无保护）；实际可达性待确认 —— 生产路径由 `getNodes`（requery + `splitNonEmpty` 保证每节点至少一个库、至少一个节点）保证非空，但 `LogicalCatalog.of` 是 `protected` 类型的 `public` 成员，传空节点数组即 panic。
- **描述**：当前靠上游不变量兜底，属于「隐式契约」。一旦有人给 `LogicalCatalog.of` 传空 `nodes`（测试或后续新增调用点），得到的是 `IndexOutOfBounds` 而不是带键名的 `CONFIG` 错误。
- **建议**：在 `LogicalCatalog.of` 开头判 `all.isEmpty()` → `FdbmException(CONFIG, 'no physical database is configured')`；`smallest` 改 `physicals.fold` 或先判空，`getSequenceDatabase` 的兜底分支随之简化。

### [轻微][存量] `flush` 复用进程生命周期内的全部历史 `pending`，与设计「本次 set 的键值」不符

- **位置**：`fdbm/src/config/BootScriptWriter.cj:120`（合并 `pending`）、`fdbm/src/config/BootScriptWriter.cj:98`（只增不删）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与设计/注释不符）
- **证据**：静态确定 —— `flushLocked` 用整个 `pending` 覆盖块内同名键；设计 `doc/详细设计.md:283` 写的是「用**本次** `set` 的键值覆盖/追加」。
- **描述**：`EXPORT a` 之后管理员手工把块里的 `a` 改成别的值（虽不推荐，但块是纯文本），再 `EXPORT b` 会把 `a` 改回旧值且不提示。反过来说，`pending` 与运行期 `Config` 保持一致是合理语义，所以影响有限；问题是「不清理」既让语义偏离设计，也让上面的无界增长无法通过重启外的任何手段回收。
- **建议**：`flush` 成功后清空 `pending`（本次 set 的语义），或保留现状但把设计 §3.5 第 2 条改成「本进程内 set 过的全部键值」，二者取一。

### [轻微][存量] 权重键的「后缀不能以 `_` 结尾」校验会误伤以 `_` 结尾的合法节点名

- **位置**：`fdbm/src/config/FdbmConfig.cj:127`（`suffix.endsWith('_')` → `CONFIG`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界校验口径不一致）
- **证据**：静态确定（校验口径不一致）；`fdbm_db` 的节点名只要求非空（`FdbmConfig.cj:75`），`name_` 是合法节点名，但 `fdbm_loadbalance_weight_name_` 会被当成「缺节点名」直接拒绝；是否需要支持下划线结尾的节点名属部署约定，待确认。
- **描述**：这条校验本意是拦住 `fdbm_loadbalance_weight__` 这类只有分隔符的键，却顺带否掉了以 `_` 结尾的节点名；这类节点无法配置节点级权重，只能退化为默认 1/1。数据库级键 `node__db` 的后缀以库名结尾，永远不会命中该判断，所以它只对节点级键生效。
- **建议**：改成「按 `__` 切开后 node 段必须非空」的结构化判断（与 `validateWeights` :428 的切分逻辑共用），不再用 `endsWith('_')` 这种字符启发式。

### [轻微][存量] README「其他公开 API」未收录 `ConfigSource` / `EnvConfigSource` / `MapConfigSource`

- **位置**：`fdbm/README.md:257`（「其他公开 API」清单）、`fdbm/README_en.md:295`；对应声明 `fdbm/src/config/source.cj:27` / `:33` / `:44`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— 两版 README 对三个符号的检索命中数为 0，而同一清单收录了 `PoolConfig` / `NodeWeight` 等更细碎的成员（含 `canRead` / `canWrite`）。
- **描述**：README 首段声明「fdbm 是常驻服务，不提供库级 API」，因此这三处缺失的实际影响很小（外部无从使用）；但清单既然按「模块级 / 类型」穷举，漏三个 `public class` 会让读者以为配置源是内部实现。
- **建议**：在 `其他公开 API` 的类型分组里补三行（或说明「仅供测试/内部装配」），两版同步。

> 信息（按硬原则一不算死代码，仅记录）：`NodeWeight.canWrite` / `canRead`（`models.cj:99/103`）与 `FdbmException(code, caused)` 构造器（`FdbmException.cj:39`）在仓内只被测试引用——前者是 `protected` 类的 `public` 成员，路由侧实际直接用 `weight.write/read`（`fdbm/src/resources/DatabaseResources.cj:102`），可考虑作为「可见性建议」收窄或在路由侧改用 `canWrite/canRead`；后者是设计 §4 登记的对外构造形式，保留即可。

<!-- 第 4 部分 -->

### [严重][存量] 每行 INSERT 都新建 `SnowflakeIdGenerator`，同一毫秒内两次构造返回相同 ID

- **位置**：`fdbm/src/idmaker/IdMakers.cj:262`（`return Some(SnowflakeIdGenerator(serial))`）；触发点 `fdbm/src/execute/executors.cj:898`（`fillAndRoute` 里**每行**调用 `IdMakers.forTable`）；机理依据 `f_util/src/IdMaker.cj:26,32,41`
- **来源**：存量（`git blame` c81e5dcc2a，2026-10-18，`IdMakers.cj:262` 与 `executors.cj:897-913` 同一提交）
- **判据**：review-checklist §11（数据错误 / 契约不符）+ §5（`IdMakers.cj:31-37` 注释声称「进程级复用」，实现每次新建，语义与注释不符）
- **证据**：静态确定 —— `IdMaker` 的种子是实例字段 `startMillis = now().toMilliseconds()`（`IdMaker.cj:26`），初值 `current = (hostSerial << 53) | (startMillis << 12)`（`:32`），`nextInt64()` 返回 `current.fetchAdd(1)` 的自增前值（`:41`）。两个实例若 `hostSerial` 相同且在同一毫秒内构造，则初值完全相同，首个 `nextInt64()` 必然返回同一个 `Int64`
- **描述**：`insert into t (name) values ('a'), ('b')`（未给分库列）在 `insertRows` 里逐行走 `fillAndRoute`（`executors.cj:705-711`），每行都新建一次生成器。分库键通常就是该 ID（主键/唯一键），两行拿到同一个值 → 第二条 INSERT 主键冲突，或（无唯一约束时）出现两条同 ID 记录，路由与唯一性契约同时被破坏。`insert ... select` 逐行插入时同样成立。概率取决于两行之间是否跨毫秒（同一语句内通常在同一毫秒），因此表现为「偶发重复键」，最难定位
- **建议**：生成器按 `(kind, arg)`（或按分库表）在 `InsertExecutor` 构造期缓存一份，`fillAndRoute` 只取缓存实例；`fillAndRoute` 本身也应改为一次取生成器、多行复用。若短期不改缓存，至少在 `SnowflakeIdGenerator` 内部把 `IdMaker` 做成 `static`（按 serial 分桶）以保证同进程单调唯一。补一条用例：`insert into t (name) values ('a'),('b')` 在 snowflake 表上断言两个分库键不同

### [严重][存量] `insert ... select` 全量物化后再逐行插入，无任何行数上限

- **位置**：`fdbm/src/execute/executors.cj:830-857`（`rows = ArrayList<Array<SqlExpression>>()`，`while (cursor.next())` 全读）
- **来源**：存量（`git blame` c81e5dcc2a，2026-10-18）
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）
- **证据**：静态确定 —— 物化循环无 `limit`、无分批、无行数上限；随后 `for (row in rows) statements.add(fillAndRoute(...))` 又把每行扩成一条 `InsertStatement`（每行再分配 3 个 `ArrayList` + 3 个 `Array`，`executors.cj:864-918`）。**峰值内存阈值需实测**
- **描述**：`insert into t (c1,c2) select ... from big_table` 会把源结果整表读进内存：每行 ≈ 1 个 `Array<SqlExpression>` + 每列 1 个 `LiteralExpression`/`Data`，加上第二阶段的 `InsertStatement` 常驻副本。按 1M 行 × 5 列、每格 50–100 B 粗估，单次插入峰值可达 0.5–1 GB 量级；源表由用户决定，服务端没有拒绝路径，容器内存上限到达即 OOM。`executors.cj:809-812` 的注释只解释了「为什么要物化」（游标占连接 → `maxSize=1` 会自锁），没有给出容量约束
- **建议**：改为有界分批（例如每 N 行一组：物化 → `executeAll` → 释放），`N` 取池大小与行宽的折中并写进配置；或先对源 SELECT 施加 `limit` 上限并在超限时返回明确错误码。分块后仍需保证「同库同事务」的分组语义（可复用 `executeAll` 的按库分组逻辑）
- **验证**：同输入下记录 `getUsedHeapSize()` / RSS 峰值与插入耗时，确认峰值与总行数脱钩

### [一般][存量] 无列清单的 INSERT 生成了分库 ID 却丢弃，最终以「无法判定目标库」报错

- **位置**：`fdbm/src/execute/executors.cj:905-913`（`literal` 已算好，只在 `columns` 非空或 `hasPairs` 时追加）
- **来源**：存量（`git blame` 4aa0684f2c / c81e5dcc2a，2026-10-18）
- **判据**：review-checklist §11（语义与命名/注释不符、错误处理不准确）
- **证据**：静态确定 —— `missing` 为真（`columns` 与 `pairs` 都为空时恒真，`:894-896`），生成器被调用（`:905` 产生了副作用），随后 `if (!columns.isEmpty()) … else if (hasPairs) …` 两个分支都不成立，`literal` 被直接丢弃
- **描述**：`insert into t values (…)`（省略列清单）在分库表上会先生成 ID（`sequence` 生成器会真的开事务、`update fountain_sequence`；`snowflake` 会消耗一个时间戳序号），然后把值扔掉。该语句随后在 `router.insertConstraint`（`route/router.cj:384-397`）因「列清单为空且 setPairs 为空」返回 `None` → `RoutePlan.unroutable()` → `executors.cj:1003-1005` 抛 `ROUTE_FAILED: insert cannot determine a target database`。用户看到的是路由错误而不是「省略列清单时无法补分库列」，同时白烧一次序列值
- **建议**：`missing && columns.isEmpty() && !hasPairs` 时直接抛 `UNSUPPORTED_SQL`/`ROUTE_FAILED`：「省略列清单的 INSERT 必须显式提供分库列」；或在生成 ID 之前就判定，避免生成器副作用

### [一般][存量] 分库缓存容量计数只增不减，TTL 过期后永久停写新键

- **位置**：`fdbm/src/route/cache.cj:36,67-90`（`count_` 只在 `put` 自增、`remove` 自减）
- **来源**：存量（本文件 2026-10 提交，快照模式无 diff）
- **判据**：review-checklist §11（契约与实现不符）+ §5（缓存键无界 / 计量漂移）
- **证据**：静态确定 —— `f_store` 的 TTL 是**读取时过滤**（`f_store/src/Store.cj:149-170` 的 `checkExpiryAndGet`，`LevelManager.get(key, now)`），过期条目不会回调 `PartitionCache.remove`；而 `closed`/`count_` 没有任何重算路径。`init` 只在启动时扫一次 prefix 计数（`cache.cj:45-51`）
- **描述**：进程长期运行后，凡是写过的键数累计到 `fdbm_cache_size`，`put` 就永久走 `count_ >= capacity` 分支停止写新键（每个新键只 WARN 一次），即便其中绝大多数条目已过期、store 实际体积已回落。更进一步：同一键过期后再次 `put`，`store.get(key).isNone()` 为真 → `count_` 再加 1，漂移比真实键数更快。表现为「缓存跑一段时间后突然全部不命中」，而 `fdbm_cache_size` 形同虚设
- **建议**：计数改为「写时按 store 返回值判定 + 定期重算」（例如每 N 次 `put` 或每次启动后按 `store.prefix` 重新计数，或把过期条目在 `put` 路径上顺带 remove）；容量判定改用 `store` 的真实键数或独立的持久化计数键

### [一般][存量] `DbdSession.installCursor` 在互斥锁内关闭旧游标（含连接归还与驱动 I/O）

- **位置**：`fdbm/src/execute/session.cj:100-122`（`synchronized(lock)` 内 `existing.close()`）
- **来源**：存量
- **判据**：review-checklist §12.2 / §6.2（锁内 I/O）
- **证据**：静态确定 —— `QueryCursor.close()`（`cursor.cj:198-209`）→ `CursorSegment.close()`（`cursor.cj:42-64`）→ `result.close()` / `statement.close()` / `connection.close()`，后者把连接归还 `DatabasePool`（可能触发驱动侧的往返或池内 `checkOnReturning` 校验）；同类 `DbdSession.close()`（`session.cj:147-164`）采用的是「先 `takeCursor()` 摘除，再在锁外关闭」，本方法没有沿用
- **描述**：会话锁同时保护 `pinned`（`pinnedConnection()`）与 `cursor`。旧游标关闭期间的网络/池等待全部落在锁内，此时另一线程（巡检 `SessionRegistry`、关停线程）取 `pinnedConnection()` 会被一起阻塞；`maxSize=1` 或池等待上限较长时，阻塞时间可达秒级。正确性没有问题（没有回调回本锁），但这是「锁内做大粒度 I/O」
- **建议**：与 `close()` 对齐：锁内 `let old = cursor; cursor = Some(value)`，锁内只做「已关闭则关新游标」的判定，`old.close()` 移到锁外

### [一般][存量] 事务 pin 的「检查已 pin」与「写入 pin」分两次取锁

- **位置**：`fdbm/src/execute/executors.cj:1352-1362`（`if (session.isPinned())` … 之后 `session.pin(pinned)`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入）
- **证据**：待确认 —— `isPinned()`（`session.cj:78-82`）与 `pin()`（`:133-137`）是两次独立加锁；当前依赖上层「每个连接独占一个处理线程」的约束（`server/handler.cj:100` 注释「正常客户端按连接级独占拦截」），因此现状不会并发进入。缺的信息：是否存在其他线程对同一 `DbdSession` 执行语句（例如未来的并行执行或后台重放）
- **描述**：一旦同一会话被两个线程同时执行 `BEGIN`，两者都会看到 `isPinned() == false`，第二个 `pin()` 覆盖第一个 `PinnedConnection` 且不关闭它 → 池连接泄漏 + 事务归属错乱。后果是资源泄漏与事务语义破坏，但因为当前有上层独占约束，暂定「一般」
- **建议**：把「检查 + pin」收成一个原子方法（`tryPin(value): Bool`，锁内判空后写入），`Begin` 分支用它的返回值决定是否关闭新连接

### [轻微][存量] `PinnedConnection.transactionOpen` 只写不读

- **位置**：`fdbm/src/execute/session.cj:27`（声明）；唯一写入点 `fdbm/src/execute/executors.cj:1361`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 全仓搜索 `transactionOpen`：代码侧只有声明与 `pinned.transactionOpen = true` 一处写入；其余命中都在 `fdbm/README.md:261`、`README_en.md:299`、`doc/详细设计.md:719` 的「公开 API」列表里
- **描述**：字段对外不可达（所属 `PinnedConnection` 是 `protected class`），仓内零读取，属于兼容残留/预留位。它同时被 README 当作公开能力描述，会把使用者引向并不存在的语义
- **建议**：删除字段并同步 README 的「其他公开 API」段；若要保留「事务是否打开」的可观测性，至少让 `SessionCtlExecutor` 在读侧使用它（例如 `COMMIT` 前后校验），并补用例

### [轻微][存量] `warnPinnedGlobalWrite` 每条语句都打 WARN，与「首次发生」的注释不符

- **位置**：`fdbm/src/execute/executors.cj:140-146`（函数内无 once 标志），调用点 `:504`、`:568`、`:994`
- **来源**：存量
- **判据**：review-checklist §11（注释与实现不符）+`perf §9.1`（日志放大）
- **证据**：静态确定 —— 注释写「首次发生时记 WARN」，实现每次调用都 `execLogger.warn(...)`
- **描述**：事务内的批量全局表写入（循环 INSERT / 批量 UPDATE）会为每条语句输出一条同样的 WARN，把限制说明变成噪声；若日志按条同步落盘还会放大延迟
- **建议**：改为「每会话一次」（`DbdSession` 加 `globalWriteWarned: Bool`，锁内判定）或「每进程一次」（`AtomicBool`），并让注释与实现一致

### [轻微][存量] DDL 广播用「全局 firstCause」当收尾失败标志，后续库的收尾异常被吞

- **位置**：`fdbm/src/execute/executors.cj:1299-1306`（`closeAfterExecution(found, firstCause.isSome())`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理不完善 / 资源释放不对称）
- **证据**：静态确定 —— `firstCause` 是整轮循环的累计状态：只要前面任一库失败过，后面**成功**库的 `connection.close()` 异常都会走「已失败」分支只记 WARN（`executors.cj:36-45`），不再抛给调用方
- **描述**：失败库数 ≥1 时，后续库的归还失败（连接未真正回到池里、池计数漂移）在日志级别上与首错混在一起，既不计数也不回报，`closeAndAwait` 之后才暴露。`broadcastWrite` 用的是逐库 `try { close } catch { warn }`，语义可接受；这里的问题是把「本轮是否已失败」当成「本次关闭是否需要上报」
- **建议**：把标志改为本次迭代的局部 `failed`（与 `DmlExecutor` 的 `var failed` 写法一致），首错仍由 `firstCause` 保留，两者分开

### [轻微][存量] `DeleteExecutor.queryKeys` 用 `ArrayList.contains` 去重，复杂度 O(n²)

- **位置**：`fdbm/src/execute/executors.cj:635-644`
- **来源**：存量
- **判据**：review-checklist §6.4（热点里对 `ArrayList` 反复 `contains`）
- **证据**：静态确定（复杂度）；实际耗时占比未测
- **描述**：`delete from t where …` 命中 k 行去重分库键时是 O(k²) 字符串比较，k 由受影响行数决定（无 `limit`）。键值基数通常远小于行数，所以多数场景不痛；大范围 DELETE 时会变成主要 CPU 项。同类去重散落在 `router.cj:337-343`、`:402-408`（`ArrayList.contains` 去重）
- **建议**：改用 `HashSet<String>` 去重后再 `toArray()`；`router.cj` 的同款写法一并处理

### [轻微][存量] `MemoryQueryResult` 的 `close()` 是空转，`next()` / `getOrNull()` 也不检查 `closed`

- **位置**：`fdbm/src/execute/cursor.cj:250-322`（`close()` 只置 `closed = true`；`next()` `:267-270`、`getOrNull()` `:284-313` 均未检查）
- **来源**：存量
- **判据**：review-checklist §3（空实现）+ §11（契约与实现不符：`QueryCursor` 关闭后访问抛 `CURSOR_STATE`，内存结果不抛）
- **证据**：静态确定 —— `QueryCursor.close()`（`cursor.cj:198-209`）只关闭 `segments`，从不关闭 `memory`；全仓也没有其它调用 `MemoryQueryResult.close()` 的路径，因此 `closed` 永远为 `false`
- **描述**：`SHOW DATABASES` / `count(*)` 走内存结果，客户端在 `UNSUBSCRIBE` 之后再发 `NEXT_ROW`/列读时：`QueryCursor` 会抛 `CURSOR_STATE`，而内存通道（若游标还没被摘下）仍能继续返回行。两套结果通道的关闭语义不一致，属于「关闭后仍可读」
- **建议**：`next()`/`getOrNull()` 首行加 `if (closed) throw FdbmException(CURSOR_STATE, …)`，并让 `QueryCursor.close()` 一并关闭 `memory`

### [轻微][存量] 重复逻辑：逐库执行与「广播 + 部分失败」模板各写了多份

- **位置**：逐库执行块 3 份 —— `fdbm/src/execute/executors.cj:521-536`（UPDATE）、`:591-606`（DELETE）、`:1016-1031`（INSERT）；广播 + 部分失败聚合 2 份 —— `:224-256`（`broadcastWrite`）、`:1283-1313`（`DdlExecutor.execute`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 跨函数复制）
- **证据**：静态确定 —— 逐库块逐行同构（`borrow` → `executeUpdate` → 累加 `rowCount`/`lastInsertId` → `finally { if (owns) closeAfterExecution(connection, failed) }`），只有「执行什么」不同；广播块同构（遍历库 → `try` 执行 → `succeeded`/`failed` 列表 → `firstCause` → `DB_ERROR: … success: […] failed: […]`），差异只有连接来源（`selectAllWrite` vs `borrow`）与是否累加 `lastInsertId`
- **描述**：三份逐库块已经出现漂移风险信号（DDL 那份把失败标志写成全局 `firstCause`，见上一条）；两份广播块的错误消息前缀不同（`'global table write partially failed'` vs `'ddl partially failed'`），文案可参数化
- **建议**：抽两个模块内辅助：`forEachTarget(session, databases, write, (Connection) -> UpdateResult)` 返回 `(rowCount, lastInsertId)`；`broadcastEach(databases, openConnections, what, (Connection) -> Unit)` 统一部分失败聚合。语义差异（错误前缀、是否 `lastInsertId`）显式参数化，不合并成泛型模板

### [轻微][存量] 重复逻辑：`joinNames` / 收尾工具 / 桶下标计算 / 测试 `codeOf` 各有多份

- **位置**：
  - `joinNames`：`fdbm/src/execute/executors.cj:194-203`、`fdbm/src/route/router.cj:477`（`Array<String>` 版）、`fdbm/src/server/DriverLoader.cj:84`（`ArrayList<String>` 版）
  - 收尾工具：`fdbm/src/execute/executors.cj:36-45`（`closeAfterExecution`）与 `fdbm/src/idmaker/IdMakers.cj:171-180`（`SequenceIdGenerator.closeResource`），语义完全一致（`!failed` 则抛出，否则 WARN），只有日志文案不同
  - 哈希 → 桶下标：`fdbm/src/route/algorithms.cj:163`、`:226`、`:270`、`:283` 四份 `((hash % n) + n) % n`，而 `:28-31` 已有 `bucketOfString`（仅覆盖 `UInt64`）
  - 测试 `codeOf` 系列：`fdbm/src/route/Route_test.cj:459`（`partitionCode`）与 `:472`（`cacheCodeOf`）**函数体逐字相同**，另有 `fdbm/src/resources/DatabaseResources_test.cj:159`（`fdbmCodeOf`）、`fdbm/src/execute/Dispatcher_test.cj:1297`、`fdbm/src/execute/Cursor_test.cj:50`、`fdbm/src/server/Server_test.cj:382`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定（函数体两两比对；`partitionCode` 与 `cacheCodeOf` 逐行相同）
- **描述**：`cacheCodeOf` 与同文件 `partitionCode` 完全重复（名字不同、语义相同），属于纯冗余；`closeAfterExecution` / `closeResource` 的一致性靠人工维持，后续任一处改动都会让「首错优先」规则在两条路径上分叉
- **建议**：`executors.cj` 与 `IdMakers.cj` 共用同一个收尾辅助（放 `fdbm/src/execute` 或 `fdbm/src/util`，同包内可见即可）；`algorithms.cj` 把有符号哈希的取模也收进 `bucketOfString`（重载 `Int64` 版）；测试 `codeOf` 合并成一个包内 `func`（`fdbmCodeOf` 已是最通用名字，其余别名删除）

### [轻微][存量] 测试断言强度不足：自比较断言、靠 `sleep` 制造竞态、码点切分未验证

- **位置**：`fdbm/src/route/Route_test.cj:70,74,76,84,93`（`@Assert(x.partition(k), x.partition(k))` 同一表达式自比较）；`:88`（只断言 `size > 0`）；`:178`（`sleep(5ms)` 后 `close`，`concurrentPutsAndCloseStayConsistent`）；`fdbm/src/main_test.cj:28`（只断言版本串非空）
- **来源**：存量
- **判据**：review-checklist §11（可测试性）/ §14（示例覆盖）
- **证据**：静态确定 —— 自比较断言对「分布是否合理」「跨进程是否稳定」没有任何约束；`substringPartitionUsesRunes` 的注释声称「多字节按码点切，不会切出半个字符」，但没有一处断言实际切片结果（例如 `partition('中文')` 等于 `partition('中')` 在 1 码点规格下的值）；`sleep(5ms)` 期间若 1000 次 `put` 已经跑完，该用例根本没有覆盖 `close` 与 `put` 的交错
- **描述**：这些用例能让 CI 常绿，但无法发现本部分最需要保护的两类回归：哈希/切片分布漂移、缓存关闭竞态
- **建议**：`partition` 用例改为断言**已知期望值**（先跑一次固化期望，或用固定算子的 `FixedAlgorithm` 作对照）；`substringPartitionUsesRunes` 断言 `runes` 级切片结果；竞态用例改为「持有 `Store` 锁/屏障 + 确定性交错」，或至少断言「观察到至少一次 `CACHE` 异常」

### [轻微][存量] 仅被测试引用的包内 API（可见性建议，不计死代码）

- **位置**：`fdbm/src/route/global.cj:70-75`（`GlobalTableRouter.tables`，只被 `Route_test.cj:336` 用）；`fdbm/src/resources/DatabaseResources.cj:35,232-237`（`NodeAccessor.readNodes` / 实现，仅 `DatabaseResources_test.cj:97,122` 用）；`fdbm/src/route/cache.cj:103-107`（`PartitionCache.count`，仅测试用）
- **来源**：存量
- **判据**：review-checklist §1（仅测试使用 → 可见性建议，不是死代码）
- **证据**：静态确定 —— 在 `fdbm/src` 全量搜索，三者都只在 `*_test.cj` 命中；`readNodes` 是接口成员（实现类必须提供），不判死代码
- **描述**：三个符号在生产路径零引用，只有测试在用；`readNodes` 的接口声明还要求所有 `NodeAccessor` 实现（含测试桩）都实现它
- **建议**：保留但显式注释「测试/诊断用」；或把 `readNodes` 从 `NodeAccessor` 移到 `DatabaseResources` 的具体方法上（测试直接依赖具体类型），减少实现桩的负担

<!-- 第 5 部分 -->

### [严重][存量] 非分库列条件被展开成「全部分片」，UPDATE/DELETE 静默广播到所有物理库

- **位置**：`fdbm/src/route/router.cj:316`、`:320-336`（`expressionConstraint`）；配合 `fdbm/src/sql/PartitionKeyExtractor.cj:79-90`、`:289-296`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）、§2（近似重复导致的分支漂移）；设计承诺见 `doc/详细设计.md:460`、`:464`
- **证据**：静态确定 —— 逐分支推演即可复现（见描述）
- **描述**：
  1. `RangeContext.collect` 对非 `AND/OR/`比较运算/`NOT`/`IN` 的子树直接返回 `RangeResult(true)`（`PartitionKeyExtractor.cj:293`），即「可判定但无边界」。于是 `WHERE name = 'x'`、`WHERE name LIKE 'a%'`、`WHERE id != 5` 这类条件经 `extractRange` 得到 `Some(PartitionRange(None, true, None, true))`（`PartitionKeyExtractor.cj:86-89`）。
  2. `expressionConstraint` 只用 `ranges.isNone()` 区分「有没有范围条件」（`router.cj:316`），把「无边界」当成「有范围」；`case step` 分支随即调用 `step.partitionRange(None, true, None, true)`（`router.cj:324`），该实现把无边界视为完整数据域 `[1, N*step]`（`fdbm/src/route/algorithms.cj:91`、`:104`），返回**全部**物理库。
  3. 结果：`plan.kind == Multi`（全部库）而不是 `Unroutable`。`UpdateExecutor`/`DeleteExecutor` 对 `Multi` 逐库执行并累加 `rowCount`（`fdbm/src/execute/executors.cj:521-537`、`:591-...`），只有 `Unroutable` 才报 `ROUTE_FAILED`（`:513-516`、`:577-580`）。受影响面是 `step` 分片；其它算法走 `router.cj:330-333` 的 `case _` 分支，无等值时返回 `None`，行为正确。
  4. 与设计相反：设计明确「有分片表但抽不到条件 → `Unroutable`」「`UPDATE`/`DELETE` 缺分库列条件 → 报错 `ROUTE_FAILED`」（`doc/详细设计.md:460`、`:464`）。实际效果是 `DELETE FROM t WHERE name='x'` 在**所有分片**上执行，唯一的安全闸门被绕过；事务内还会因为 `Multi` 触发 `ensurePinnedTargets` 得到另一种错误，行为前后不一致。
  5. 旁证：`PartitionRange.isEmpty()`（`PartitionKeyExtractor.cj:37-53`）从未被调用——「空/无边界」的判定本应在这里，但没接线。
  6. 现有用例只覆盖「完全无 WHERE」（`fdbm/src/route/Route_test.cj:266-269`）与「等值 + 范围」（`:290-295`），没有「只有非分库列条件」的用例，所以缺陷未被发现。
- **建议**：在 `expressionConstraint` 里显式区分「有边界」与「无边界」：
  ```cangjie
  let hasBound = match (ranges) {
      case Some(r) => r.lo.isSome() || r.hi.isSome()
      case None => false
  }
  if (equals.isEmpty() && !hasBound) { return None<Array<String>> }
  ```
  并补两条用例：`update t set name=1 where name='x'` → `RouteKind.Unroutable`；`delete from t where id != 5` → `Unroutable`。`PartitionRange.isEmpty()` 要么接到这里，要么删除（见轻微条目）。

### [严重][存量] 递归下降解析器无深度上限，单条深嵌套 SQL 可使 fdbm 进程栈溢出

- **位置**：`fdbm/src/sql/SqlParser.cj:601-603`、`:613-626`、`:628-667`、`:714-735`（`factor` 的 `LParen` 分支在 `:731-735` 回到 `expression()`）；同类递归 `:845-853`（派生表 `tableRef` → `select()`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归）、§11（崩溃）
- **证据**：静态确定 —— 递归入口只由输入 token 驱动，代码中无深度计数、无迭代栈、无长度上限
- **描述**：`expression → orExpression → andExpression → notExpression → comparison → additive → multiplicative → factor`，每遇到一个 `(`、一个 `NOT` 或一层派生表就再进一轮（约 7~8 个栈帧/层）。SQL 文本来自客户端，`Dispatcher.execute` 对每条语句直接 `SqlParser.parse`（`fdbm/src/execute/dispatcher.cj:79`）；`f_protocol` / `f_net` 未发现单条报文长度上限（全仓无 `maxLength`/`sizeLimit` 类限制）。因此 `select ((((…1…))))` 这类几千层括号的请求即可耗尽 worker 线程栈，栈溢出导致整个 fdbm 进程退出（不是单请求失败）。`notExpression` 的 `not not not …` 与派生表嵌套同理。同一输入还会依次进入 `PartitionKeyExtractor.collect`、`BindContext.bindExpression` 的递归，深度与解析深度同阶，属同一根因。
- **建议**：在 `SqlParser` 增加 `depth: Int64` 字段，`expression()` / `tableRef()` 进入时 `+= 1`、退出 `-= 1`，超过常量（如 200）抛 `FdbmException(UNSUPPORTED_SQL, 'expression nesting too deep')`；或在 lexer 层限制括号嵌套深度。补一条超深输入的负向用例。

### [一般][存量] 无 `from` 的常量查询（如 `select 1`）被路由成 Broadcast，结果按物理库份数重复

- **位置**：`fdbm/src/route/router.cj:166-178`（`!hasNonGlobalTable` 分支）；配合 `fdbm/src/execute/executors.cj:311-315`、`:331-336`、`:294-308`
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）、§10（正确性）
- **证据**：静态确定 —— 路由分支 + 执行器合并路径可完整推演
- **描述**：
  1. `select 1` 的 `statement.tables` 为空（`fdbm/src/sql/ast.cj:338-353`），`route()` 的循环不执行，`hasNonGlobalTable` 与 `hasPartitionedTable` 均为 `false`，于是进入 `:172` 的「全部是全局表」分支，取 `globals.physicalDatabases(logical)`。该映射来自 `LogicalCatalog`，被分库规则引用的逻辑库会隐式展开为**全部**物理库（`fdbm/src/config/catalog.cj:75-77`），因此 `plan.kind == Broadcast`（`:174-176`）。
  2. `SelectExecutor.targetDatabases` 对 Broadcast 只做「全局表只取一份」的优化，而 `globalOnly()` 对空 `tables` 明确返回 `false`（`executors.cj:313-315`），于是所有物理库都保留；`:297-301` 每库开一段 `CursorSegment`，:308 串成一个游标 → 客户端读到 N 行 `1`（N = 物理库数）。
  3. 影响：`select 1` / `select 'x'` / `select ?` 这类探活、常量查询在分片库上返回重复行；客户端 `query.next()` 循环、`count` 统计都会多算。f_dbd 的池检查 SQL 默认就是 `select 1`（`f_dbd/src/multid/Config.cj:137`），只调 `next()` 时不会报错，所以问题被掩盖。该问题只在 `logicalDatabases` 已装配（生产路径由 `FdbmServer.cj:81-82` 传入 `catalog.toMap()`）时出现；`Handler_test` 的 `Harness` 用 `GlobalTableRouter([])` 未传映射，`physicals` 为空 → 走 `Unroutable`，因此现有用例覆盖不到。
- **建议**：在 `route()` 开头对 `statement.tables.isEmpty()` 单独处理：返回 `RoutePlan.single(physicals[0])`（逻辑库首个物理库，与「未分库表」一致），或在执行器侧把「无表」视作只需一份副本（`globalOnly` 返回 `true`）。补用例：双物理库下 `select 1` 只返回 1 行。

### [一般][存量] 优雅停止存在会话泄漏窗口：`InFlight` 与 `SessionRegistry` 都不检查 `closed`

- **位置**：`fdbm/src/server/FdbmServer.cj:197-199`、`fdbm/src/server/InFlight.cj:36-38`、`fdbm/src/server/SessionRegistry.cj:46-58`（`of`）、`:71-94`（`closeAll`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 异步语义）、§11（资源不对称）
- **证据**：静态确定（缺失守卫）+ 依赖 `f_net` 的关闭语义：`Server.close()` 只关监听与缓冲，不 join 每连接线程、不等待 `executors.call` 排队中的任务（`f_net/src/server/server.cj:169`、`:209-211`）
- **描述**：`stop()` 先用 `InFlight.await` 等在途请求归零（只统计**已经**调用过 `enter()` 的请求），再 `sessions.closeAll()`、`resources.closeAndAwait()`。但 `f_net` 的关闭不等待已排队/正在启动的 handler，于是存在如下交错：`await` 返回 `true` → `closeAll()` 清空并关闭全部会话、取消巡检定时器 → 一个刚被调度到的 `FdbmHandler.handle` 才执行 `InFlight.enter()`（`handler.cj:64`）→ `sessions.of(buffer)`（`handler.cj:79`）在 `closed == true` 的注册表里**新建并放入**一个会话。该会话此后既不会被巡检回收（`timer.cancel()` 已执行），也不会再被 `closeAll` 关闭，其游标/`pin` 连接留到进程退出；若它借到了正在关闭的连接池，还会让 `closeAndAwait` 走到超时分支（`:199-201` 只记 WARN）。
- **建议**：`SessionRegistry.of()` 先判 `closed.load()`，关闭后不再新建：返回一个已关闭的会话，或让 `of` 返回 `?DbdSession` 并在 handler 回 `CURSOR_STATE`/`INTERNAL`；同时让 `InFlight.enter()` 返回 `Bool`（`closed` 则拒绝），`handle` 在 `closed` 时直接回错误包。这样「关闭后不再产生新会话/新查询」成为显式契约，而不是依赖 `f_net` 恰好没有排队任务。

### [一般][存量] `stop()` 与 `start()` 对 `server` 字段的发布无同步，启动期停止可能漏关监听

- **位置**：`fdbm/src/server/FdbmServer.cj:50`（`private var server`）、`:151-165`（写）、`:188-196`（读）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出）
- **证据**：静态确定（无锁、无原子、非线程封闭；`closed`/`started` 的原子操作不覆盖该字段的读写配对）
- **描述**：`start()` 在 `:151` 检查 `closed`/`started` 后构造 `Server` 并在 `:165` 赋值 `this.server`；`stop()` 在 `:184` 置 `closed` 后于 `:188` 读 `server`。若另一线程（内嵌用法、信号线程）在 `:151` 与 `:165` 之间调用 `stop()`，它会看到 `server == None` 而跳过 `close()`，随后继续关会话与连接池并返回；`start()` 接着进入 `server.start` 的 accept 循环，`closed` 已为 `true` 但监听无人关闭，再次调用 `stop()` 又在 `:184` 直接返回。后果：进程不退出、端口继续监听，而连接池已关，接入的请求全部 `INTERNAL`。窗口很窄（构造 `Server<>` 期间），但 `stop()` 是公开方法，任何线程都可调用。
- **建议**：把 `server` 的发布/读取纳入同一把锁（或用一个 `AtomicOptionReference`/`Mutex` 保护的 `Option<Server>`），并在 `start()` 赋值后再检查一次 `closed`：已关闭则立刻 `server.close()` 并返回。另可让 `stop()` 在 `server == None` 时记 WARN，便于发现该路径。

### [一般][存量] 协议错误日志打印完整客户端 payload，存在日志放大与敏感数据落盘

- **位置**：`fdbm/src/server/handler.cj:213`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据进日志）；`fountain-baseline.md` §6（不得记录凭据 / 完整报文）
- **证据**：静态确定 —— `message.data` 是客户端原始 payload（`CONSUME` 时可能是含 SQL 与参数的 `SqlPayload`），日志未截断、未脱敏
- **描述**：`protocolError` 在无法识别 payload / command 时执行 `logger.warn('${reason} (command=${message.command}, payload=${message.data})')`。两个问题：(a) `message.data` 长度由客户端决定，可把任意大小的报文一次性写进日志（`WARN` 级别通常默认开启），构成日志放大；(b) SQL 文本与绑定参数、以及任意二进制内容会原样落盘，且内容中的换行可污染按行解析的日志。
- **建议**：只记录 `message.id`、`command` 的类型名与 `payload` 的类型/字节长度（例如 `payloadType=SqlPayload, size=…`）；确需细节时用 `debug` 且截断到固定长度。错误响应（`DbdErrorPayload`）已带原因，日志无需重复报文。

### [一般][存量] `CustomLoader` 与 `DriverLoader` 四个辅助函数逐字复制，且 `joinNames` 有三份、分隔符不一致

- **位置**：`fdbm/src/server/CustomLoader.cj:120-163` 与 `fdbm/src/server/DriverLoader.cj:96-139`（`librariesOf` / `isLibrary` / `withoutExtension` / `sort`）；`fdbm/src/route/router.cj:477-488`、`fdbm/src/server/DriverLoader.cj:84-93`、`fdbm/src/execute/executors.cj:194-202`（`joinNames`）
- **来源**：存量
- **判据**：review-checklist §2（只改参数名的复制、字面量复制导致的行为漂移）
- **证据**：静态确定 —— 四处函数体逐行对齐，仅形参名不同；`joinNames` 一处用 `','`、两处用 `', '`
- **描述**：`librariesOf`（目录遍历 + `isLibrary` + 插入排序）、`isLibrary`、`withoutExtension`、`sort` 在两文件里完全一致，约 70 行重复；插入排序另在 `fdbm/src/config/catalog.cj:184-195`、`fdbm/src/execute/executors.cj:1206-1218` 还有两份，共 4 份。重复已经开始漂移：`isLibrary` 大小写不敏感、`withoutExtension` 大小写敏感（见轻微条目），两处副本同时带着这个缺陷，说明是复制而来。`joinNames` 三个副本的拼接分隔符不同（`a,b` vs `a, b`），同一类错误信息在不同执行器里格式不一致。
- **建议**：两个 loader 同在 `fountain::fdbm.server` 包内，抽一个包级 `internal` 辅助（如 `server/LoaderSupport.cj`：`librariesOf(dir)`、`isLibrary`、`withoutExtension`、`sortedInPlace`），两侧改为调用；`joinNames` 收敛到一处（建议统一 `', '`），其余两处删除。抽取消除了 `:151-163` 与 `:127-139` 的整段重复，也让大小写修复只需改一处。插入排序若要复用，应放到 `fdbm` 内的通用 util，而不是跨层依赖 `f_util`（`f_dbm` 层不得反向依赖上层）。

### [轻微][存量] `isLibrary` 与 `withoutExtension` 的大小写口径不一致

- **位置**：`fdbm/src/server/CustomLoader.cj:137-149`；同缺陷复制在 `fdbm/src/server/DriverLoader.cj:113-125`
- **来源**：存量
- **判据**：review-checklist §11（同一功能内判定口径不一致）、§2（复制后漂移）
- **证据**：静态确定 —— `isLibrary` 先 `name.toLower()` 再判后缀（`:137-140`），`withoutExtension` 直接对原串 `endsWith('.so')`（`:142-149`）
- **描述**：名为 `PG.DLL` / `libFoo.SO` 的驱动或扩展会被 `isLibrary` 认定为库并进入 `librariesOf` 结果，但 `withoutExtension` 不会剥离大写扩展名，`PackageInfo.load('/…/PG.DLL')` 直接失败，启动报 `CONFIG`/`NO_DRIVER`，而正确行为应是加载成功。
- **建议**：`withoutExtension` 与 `isLibrary` 共用同一份小写判定：先 `let lower = path.toLower()`，命中后缀后按 `ext.length` 切片；两处修复后合并为同一辅助函数（见发现 #7）。

### [轻微][存量] 7 处未使用 import

- **位置**：`fdbm/src/server/FdbmServer.cj:18`（`HashMap`）、`fdbm/src/server/InFlight.cj:18`（`Condition`）、`fdbm/src/server/handler.cj:26`（`ExecutionOutcome`）、`fdbm/src/server/GracefulShutdown_test.cj:20`（`DataAny`）、`fdbm/src/server/Handler_test.cj:24`（`DataBool`）、`fdbm/src/server/Handler_test.cj:35`（`DbdSession`）、`fdbm/src/server/Server_test.cj:27`（`LoggerFactory`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 逐个符号在本文件内做整词搜索，仅 import 行命中（`UnicodeStringExtension` 这类为扩展方法提供可见性的 import 已排除，不算未使用）
- **描述**：冗余 import 不影响运行，但会掩盖真实的依赖方向，且 `cjlint` 会报警告。
- **建议**：删除上述 7 个符号；`FdbmServer` 若后续需要 `HashMap` 再引入。

### [轻微][存量] 无引用声明与不可达语句

- **位置**：`fdbm/src/route/router.cj:271-273`（`PartitionRouter.isPartitioned`）、`fdbm/src/sql/PartitionKeyExtractor.cj:37-53`（`PartitionRange.isEmpty`）、`fdbm/src/server/Handler_test.cj:466-476`（`freePort`）、`fdbm/src/server/Handler_test.cj:439`（`while (true)` 之后的 `0`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 顶级声明里的 public 成员无使用 = 死代码；return 之后同层语句）
- **证据**：静态确定 —— 在 `fdbm/src`、`f_orm/src`、`f_dbd/src` 全量搜索符号名，仅定义处命中；`PartitionRouter` 与 `PartitionRange` 都是 `protected` 类型，对外不可达，成员 `public` 不构成对外契约；`freePort` 仅在一行注释里被提到
- **描述**：四处均为历史残留。`PartitionRange.isEmpty()` 尤其值得注意：它本可用于区分「无边界」，但调用点缺失（见发现 #1）。
- **建议**：`isPartitioned`、`freePort`、`uniquePort` 末尾的 `0` 直接删除；`isEmpty()` 若用于修复发现 #1 则保留并接线，否则删除。

### [轻微][存量] `SqlParser.factor` 解析完函数实参后立即抛错，`args` 从未被读取

- **位置**：`fdbm/src/sql/SqlParser.cj:768-776`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 无效工作）
- **证据**：静态确定 —— `args.add(...)` 之后无条件 `throw unsupported(...)`，`args` 与 `expect(RParen)` 的结果都不参与错误消息
- **描述**：函数调用一律不支持，解析实参只为推进游标；游标随后丢弃（异常直接上抛），因此这段解析完全是白做的，且在超长实参列表上白白消耗 CPU。
- **建议**：`if (accept(TokenKind.LParen))` 后直接抛 `unsupported`；若要保留「定位到右括号」的错误信息，应把 `peek().position` 用进消息，而不是构造 `args`。

### [轻微][存量] 测试夹具忽略 `waitForPort` 的返回值

- **位置**：`fdbm/src/server/Handler_test.cj:403`、`fdbm/src/server/Integration_test.cj:304`
- **来源**：存量
- **判据**：review-checklist §11（返回值被忽略导致失败点错位）
- **证据**：静态确定 —— `waitForPort` 返回 `Bool`（`Handler_test.cj:443`），两处调用都丢弃结果
- **描述**：端口在 5s 内没有就绪时，后续 `Client.build()` 会抛连接异常，测试失败信息指向「连接被拒」而不是「服务未起来」，排查成本高；`Server_test` 的正确用法是 `@Assert(waitForPort(port), true)`（`:237`、`:316`）。
- **建议**：两处改为断言或抛带端口的明确错误。

<!-- 第 6 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [CPU] 会话查找：每请求一次全局锁 + 一次 `remoteAddress.toString()`

- **现状**：每个请求都走 `SessionRegistry.of(buffer)`，在同一把全局 `Mutex` 内做 `keyOf(buffer)`（`remoteAddress.toString()` 字符串分配）与 `HashMap` 查找（`SessionRegistry.cj:46-58,152-159`）；临界区短，但**所有连接**在该锁上串行。会话数 = 并发连接数，字符串长度约 20 字节。
- **方案**：在 handler 入口按连接缓存 `DbdSession`（f_net 若提供连接级上下文则直接挂载；否则在 `SocketBuffer` 对象身份上做一次解析后缓存），后续请求不再进全局表；或把会话表按连接 id 分片成 N 把锁。键改整数/句柄，避免每请求字符串分配。
- **预期**：每请求去掉 1 次字符串分配 + 1 次全局锁往返；高并发（≥32 连接）下 p99 与 QPS 的改善幅度未知。
- **代价**：依赖 f_net 暴露稳定连接标识；`closeAll`/`sweep` 需要同时失效缓存，增加一处状态同步点；实现不当会重新引入「已关闭会话被复用」。
- **验证**：`cjprof record` 跑 1/8/32 连接各 10k 次查询，对照 `SessionRegistry.of` 自耗时与 p99；同时看分配量（`getAllocatedHeapSize`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

无。本部分只有文档；文档描述的 DELETE 键物化（`详细设计.md:797` + `src/execute/executors.cj`）等代码侧内存/CPU 议题留给对应源码部分，避免同一模块重复统计（按 §7 要求也缺改前基线）。

<!-- 第 3 部分 -->

### [CPU] 用 `std.sort` 替换两处手写插入排序

- **现状**：`BootScriptWriter.sortedByKey`（`fdbm/src/config/BootScriptWriter.cj:530`）与 `LogicalCatalog.sortInPlace`（`fdbm/src/config/catalog.cj:184`）各 15 行插入排序；作用规模是「managed 块内键数」（当前 `fdbm/boot.sh` 为 30 项左右）与「物理库数」（个位数）
- **方案**：`import std.sort.*` 后 `sort(entries) {a, b => a[0] < b[0]}` / `values.sort()`，`sortedByKey` 的 `let copy = entries` 一并去掉（`Array` 是引用类型，`copy` 并未复制，命名有误导）
- **预期**：n≤50 时收益在噪声内（n²/4 ≈ 600 次比较），只有配置项上千时才可能看见；同时消掉一份重复实现
- **代价**：需确认 `std.sort` 的稳定排序语义不改变「同键」顺序（键唯一，无影响）；改动集中、可等价性验证
- **验证**：`cjpm bench -O2`，输入 10 / 1000 个键，各 5 轮取中位数；对照 `boot.sh` 字节输出一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU/IO] EXPORT 改为增量写：只重写受影响的块

- **现状**：每次 `flush` 完整读入 → 重建全部块 → 回写全文件（`BootScriptWriter.cj:109`），成本 O(文件大小)；N 次 EXPORT 累计 O(N²)
- **方案**：保留现有的 `parseBlock` 定位能力，但只为「本次 key 所在的块」重新渲染并替换对应行区间，其余块与块外内容原样拼接；块内仍保持 key 排序
- **预期**：单次 `flush` 的 I/O 从「整个文件」降到「一个块」，N 次 EXPORT 的总 I/O 从 O(N²) 降到 O(N·块)；在 30 个键的现状下差异 <1ms
- **代价**：需要处理「跨块移动键」（同一个 key 换了分组前缀时旧块要删行）、幂等性与 `normalize()` 的全量规范化路径要分开；实现复杂度明显上升
- **验证**：构造 10k 次 EXPORT（交替 5 个键）的压测，比较端到端 P50/P99 与写入字节数；同时断言 10k 次后文件内容等于一次性全量渲染结果
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 去掉 `flush` 路径上的多份文本副本

- **现状**：一次 `flush` 同时存活 `lines: Array<String>`（读入）、`merged: ArrayList<String>`、`block: Array<String>`、`joinLines` 的 `StringBuilder`，峰值约为文件字节数的 4–5 倍
- **方案**：`writeAtomically` 接受一个「逐行产出」的闭包/迭代器，边生成边写临时文件；`merged` 改为直接追加到 `StringBuilder`
- **预期**：峰值降到约 1 倍文件大小；当前 boot.sh 约 2–3 KB，收益在 10 KB 量级，可忽略
- **代价**：写出不再是「先拼完整串再原子写」，需保证异常路径仍能清理临时文件；代码可读性下降
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10k 次 flush 的峰值；只在 boot.sh 增长到 MB 级时才有意义
- **证据状态**：`无基线（待验证，不进 tasks）`；按当前规模不建议实施

<!-- 第 4 部分 -->

> 以下都不是缺陷；均无改前基线，按铁律只能作为「待验证」的候选，不进 `tasks.md`。

### [堆内存] 游标行缓冲用两个 `HashMap` 改为按列下标的 `Array<?Data>`

- **现状**：`QueryCursor` 持有 `cells: HashMap<Int64, Data>` 与 `streams: HashMap<Int64, InputStream>`（`fdbm/src/execute/cursor.cj:85-86`），每行 `clearRow()`（`:242-246`）清空再逐格 `add`。列数在 `infos` 里已知，但缓冲仍按哈希表组织：每格一次哈希 + 每次 `add` 可能的扩容；`clear()` 只清元素不还物理内存（`mem §3.2`），行缓冲的桶数组会长期驻留
- **方案**：改为 `Array<?Data>(infos.size, repeat: None)` + `Array<?InputStream>`，`clearRow()` 改成「按已写下标置 `None`」或直接 `Array` 重建（`infos.size` 是常量级小数组）
- **预期**：每行每列省一次哈希与装箱查找；行缓冲常驻内存从「按峰值列数 × 负载因子」降到「列数 × 8B 指针」；`clear()` 不再留下不回收的桶数组
- **代价**：`cell(index)` 的越界判定改用 `infos.size`（已有），语义不变；`streams` 需要额外的「已打开」标记来区分 `None`（未打开）与「打开后为 null」，实现上比 `HashMap` 多一个布尔数组
- **验证**：同 SQL、同结果集（1 万 / 10 万行，10 列）跑 `cjpm bench -O2`，对照 `getAllocatedHeapSize()` 增量与单行 `NEXT_ROW`+列读的中位耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 分库缓存启动期全量 prefix 计数改为持久化计数

- **现状**：`PartitionCache.init`（`fdbm/src/route/cache.cj:45-51`）用 `store.prefix(Array<Byte>())` 遍历**全部**键来初始化 `count_`，每个键分配一次迭代器条目；键数到百万级时启动时间与峰值内存都随库体积线性增长
- **方案**：在同一个 `Store` 里维护一个保留键（例如 `\x00.count`）记录键数，`put`/`remove` 原子更新；启动时只读一个键。若担心历史数据没有计数键，可只在「计数键缺失」时退回一次全量扫描并写回
- **预期**：启动期从 O(键数) 降为 O(1)；启动峰值内存不再随缓存体积增长
- **代价**：多一次 `Store` 读写（`put` 路径），计数与真实键数仍可能漂移（需与「TTL 过期」一并处理，见「一般」条目）
- **验证**：预置 100 万键的 store 目录，对照 `PartitionCache` 构造耗时与 RSS 峰值（改前/改后各 5 次取中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 按表缓存 ID 生成器，去掉逐行构造与逐行读配置

- **现状**：`InsertExecutor.fillAndRoute` 每行调用 `IdMakers.forTable`（`fdbm/src/execute/executors.cj:898`）→ `uuid` 每次新建 `TimeBasedUUIDBuilder` 并 `registerSequenceGenerator()`（分配 2 个原子 + 闭包，`f_util/src/uuid.cj:689-704`）；`snowflake` 无 `arg` 时每行 `Config.getValue<Int64>(IdMaker.HOST_SERIAL)`（`IdMakers.cj:255-260`）；`IdMaker` 构造还要取一次毫秒时间戳
- **方案**：`InsertExecutor` 构造期按 `(logical, table)`（或 `(kind, arg)`）建 `HashMap<String, IdGenerator>` 缓存；`fillAndRoute` 只查表。与「每行新建生成器导致重复 ID」是同一处改动
- **预期**：每行省掉 1 次生成器构造 + 1 次配置读取 + 1 次时间戳/随机数初始化；批量 INSERT 的固定开销与行数解耦
- **代价**：生成器变成进程级共享，必须保证线程安全（`UuidIdGenerator` 已有 `Mutex`，`SequenceIdGenerator` 每次借连接，`IdMaker` 内部是 `AtomicInt64`）；配置变更不再对已缓存的生成器生效（配置本来只在启动读一次，符合基线 §5）
- **验证**：`cjpm bench -O2`，1000 行单语句 INSERT（uuid v1 / snowflake 各一组），对照总耗时中位数与 `cjprof` 里 `IdMakers.forTable` 的自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 分库缓存：去掉重复 `store.get`，把磁盘 I/O 移出会话级热点锁

- **现状**：`PartitionCache.put`（`fdbm/src/route/cache.cj:74,81`）对同一个 key 连续 `store.get` 两次；`get`/`put`/`remove` 全部在**同一把** `Mutex` 内做 `f_store` 读写（磁盘/内存表 + WAL append），而路由在每次未命中时都会调用 `routeByValue` → `store.get`（`route/router.cj:222`）
- **方案**：`put` 先算 `existing = store.get(key)` 复用结果（`store.add` 的返回值本身也带回旧值，可直接用）；锁内只做 `count_` 与容量判定的状态维护，`store.get`/`store.add` 移到锁外（注意 `count_` 的检查-然后-写入需与 `store` 操作配对，可用「先占位后写」或按 key 分片）
- **预期**：每次 `put` 少一次 `get`；`maxSize=1` 部署下路由不因缓存写盘阻塞其它会话
- **代价**：锁外 I/O 需要重新设计 count 的不变量（容量上限可能被短暂突破），或改分片锁
- **验证**：`cjprof` 看 `routeByValue` 自耗时占比 + 线程状态（BLOCKED 时长）；10 万次不重复键的路由调用
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

> 不是缺陷，是「还能更好」。以下均无改前/改后对照数据，**不进 `todo.md` / `tasks.md`**。

### [堆内存] 缓存 `statement.tables` 的展开结果，避免每次路由重复构造

- **现状**：`SelectStatement.tables` 是计算属性，每次访问都新建 `ArrayList` 并递归 `collectTables()`（`fdbm/src/sql/ast.cj:338-353`）。`route()` 一次调用里至少访问两次（`:147` 循环、`:262` `logicalOf`），`qualifiersOf`（`:416`）还会对每个分片表再访问一次；每条 SELECT 至少多出 2~3 个数组与一轮递归展开。
- **方案**：在 `PartitionRouter.route` 入口取一次 `let tables = statement.tables`，把 `logicalOf`/`qualifiersOf` 改为接收该数组；或在 AST 构造时把 `tables` 作为 `let` 字段计算一次（AST 不可变，缓存无失效问题）。
- **预期**：每条 SELECT 少 2~3 次 O(表数) 分配与递归；对象数下降与语句数成正比。
- **代价**：改 3 个私有函数签名；AST 增加一个字段（构造期一次展开）。
- **验证**：`cjpm bench -O2` 跑 10k 条 1~3 表 SELECT，对比中位数与 `getAllocatedHeapSize()`。
- **证据状态**：`无基线（待验证）`

### [CPU] 每条 SQL 被词法分析两次

- **现状**：`SqlParser.parse` 先调 `parseSessionCtl(sql)`（内部 `Lexer(sql).tokenize()`，`:62-64`），返回 `None` 后再 `Lexer(sql).tokenize()` 一次（`:52`）。非会话语句（绝大多数请求）都走两遍；`Dispatcher.execute` 每条语句都调用 `parse`（`fdbm/src/execute/dispatcher.cj:79`）。
- **方案**：先 tokenize 一次，把 token 数组同时用于会话控制判定与完整解析；`parseSessionCtl` 保留一个接收 `Array<Token>` 的重载（现有测试签名不变）。
- **预期**：词法分析次数减半，每语句少一次 O(n) 扫描 + 一个 token 数组分配（n = SQL 长度）。
- **代价**：小重构，`parseSessionCtl` 多一个入口；会话控制判定逻辑不变。
- **验证**：`cjpm bench -O2` 对 `Dispatcher.execute` 跑 10k 条典型 SQL（10~200 字符）对比中位数；`cjprof` 看 `Lexer.tokenize` 自耗时占比。
- **证据状态**：`无基线（待验证）`

### [CPU] 缩小 `SessionRegistry.sweep` 的临界区（锁内不做跨对象调用）

- **现状**：`sweep()` 在 `synchronized(mutex)` 内遍历全部会话，并逐条调用 `isBufferClosed(buffer)`（`SessionRegistry.cj:117-133`）；同一把 `mutex` 在请求主路径的 `of()`（`:48`）与 `size()`（`:106`）上被争用。`buffer.isClosed()` 是跨对象调用（可能抛异常、由 `isBufferClosed` 吞掉），其耗时不在本模块可控范围。
- **方案**：锁内只拷贝 `(key, session)` 快照并释放；锁外判定 `isBufferClosed`；再进锁按 key 删除，删除前比对引用（`sessions.get(key)` 仍是同一 session 才删），避免误删巡检期间重建的会话。
- **预期**：巡检的锁持有时长从「O(会话数) × isClosed」降为「O(会话数) 拷贝」，缩短请求路径的等待。
- **代价**：多一次快照分配与一次引用比对；删除逻辑从无条件 `remove` 变为条件删除，需补并发用例（巡检与 `of` 并发 100 轮，断言不误删活跃会话——可扩展 `Server_test.cj:330-349`）。
- **验证**：1000 连接、1ms 巡检周期下采样线程状态（BLOCKED 时长）与 `of` 的 P99；`cjprof record` 线程状态。
- **证据状态**：`无基线（待验证）`

<!-- 第 6 部分 -->

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

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `PartitionCache` 构造时全量遍历 `f_store` 只为计数，启动耗时随缓存键数线性增长 | `fdbm/src/route/cache.cj:45-51` | 键数 → 构造耗时曲线 | 造 1k/10k/100k 键后各启动 5 次，记构造分段耗时中位数 |
| 2 | `SessionRegistry.of` 的全局锁与字符串键在并发下成为串行段 | `fdbm/src/server/SessionRegistry.cj:46-58` | 该函数自耗时占比、锁等待 | `cjprof record` 跑 32 连接 × 10k 查询；另采线程 BLOCKED 时长 |
| 3 | `DatabaseResources` 同步建池（`initSize × 库数`）拉长启动时间，多库部署下明显 | `fdbm/src/resources/DatabaseResources.cj:66-104` | 库数/initSize → 构造耗时 | 10/100 个物理库、`initSize=1/8` 各启动 5 次，记 `FdbmServer` 构造耗时 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 同源端口复用时 `SessionRegistry.of` 命中旧会话，导致游标/事务串台 | `fdbm/src/server/SessionRegistry.cj:152-158` | `f_net` 的 `remoteAddress` 复用条件与复现路径 | 同源端口重连压测 + 断言会话 id 变化 |
| 2 | `UInt128.hashCode()` 跨 SDK 版本变化会让 murmur 分片整体漂移 | `fdbm/src/route/algorithms.cj:225` | 两版 SDK 对同一组键的输出 | 1 万个键在两版 SDK 下比对库下标 |
| 3 | `normalize()` 的改写不只影响 §10.6 示例，也影响真实部署脚本 | `fdbm/src/config/BootScriptWriter.cj:343-355` | 真实 `boot.sh` 样本与两次启动的 diff | 用真实脚本连续启动两次，逐行 diff |
| 4 | 详细设计其余「声明片段」仍有未比对的漂移（§8.2 AST 字段、§6.3 缓存成员） | `fdbm/doc/详细设计.md` §8.2 / §6.3 | 声明片段与 `src/` 的完整差异清单 | 脚本把文档 ```cangjie 代码块的 `protected class/struct/interface` 与 `grep -rn "^protected \(class\|struct\|interface\)" fdbm/src` 做集合差 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 高频 EXPORT 下 `flush` 的全量重写成为请求延迟热点 | `fdbm/src/config/BootScriptWriter.cj:109` | 单次 flush 耗时随文件行数的曲线、EXPORT 在真实负载中的 QPS | 用 1k/10k/100k 行 boot.sh 各跑 1000 次 `flush`，`cjprof record` 取 `flushLocked` 自耗时占比 |
| 2 | 配置项很多时启动期多次全量遍历 `source.all()` 有可见开销 | `FdbmConfig.cj:122/155/162/203`、`catalog.cj:55` | `Config.getAll()` 是否每次复制整个 map、单次耗时 | 构造 1000 个配置键，分段计时 `FdbmSettings.load`；先查 `f_config` 文档确认 `getAll` 返回语义 |
| 3 | `sortedByKey` 的插入排序在键数增长后成为可见成本 | `BootScriptWriter.cj:530` | n=1k 时的绝对耗时 | `cjpm bench -O2` 对照 `std.sort`，同输入 5 轮中位数 |
| 4 | `File.writeTo` + `rename` 未 fsync，掉电后可能出现空/截断的 boot.sh | `BootScriptWriter.cj:460` | 平台文件系统语义、是否需要断电一致性 | 查 `std.fs` 文档确认 `writeTo` 是否 fsync；需要一致性时再补 `fsync` 目录/文件 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `insert ... select` 的峰值内存与源行数线性相关，1M 行时进入 GB 量级 | `fdbm/src/execute/executors.cj:830-857` | 每行实测字节数、峰值 RSS | 造 10 万/100 万行源表，记录 `getAllocatedHeapSize()` 与 RSS 峰值，中位数 5 次 |
| 2 | 逐行构造 ID 生成器在批量 INSERT 中占可观自耗时 | `fdbm/src/execute/executors.cj:898`、`fdbm/src/idmaker/IdMakers.cj:262` | `IdMakers.forTable` 的 self time 占比 | `cjprof record` 跑 1000 行/语句 uuid v1 与 snowflake，对比缓存版 |
| 3 | 分库缓存 `Mutex` 内的 `f_store` 读写在并发路由下形成串行段 | `fdbm/src/route/cache.cj:54-101` | 锁等待时长、BLOCKED 线程数 | 8 线程 × 10 万次未命中路由，采线程状态（CPU profile 看不到锁竞争） |
| 4 | `queryKeys` 的 O(n²) 去重在大范围 DELETE 上是主要 CPU 项 | `fdbm/src/execute/executors.cj:635-644` | 命中行数 k 与该方法耗时占比 | 对 1 万/10 万行 DELETE 分段计时，配合 `HashSet` 版对照 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `statement.tables` 重复展开在单次路由中的占比可观（表多时更明显） | `fdbm/src/route/router.cj:147`、`:262`、`:416` | `collectTables` 自耗时占比、每语句分配次数 | `cjprof record` 跑 10k 条 1/3/5 表 SELECT，按表数分组 |
| 2 | `sweep` 的锁等待会拉高请求路径 P99（连接数大、巡检周期短时） | `fdbm/src/server/SessionRegistry.cj:117-133` | 锁等待时长、BLOCKED 线程数 | 1000 空闲连接 + 1ms 巡检，采样线程状态 10 分钟 |
| 3 | 双重词法分析占端到端比例（短 SQL 上可能低于噪声） | `fdbm/src/sql/SqlParser.cj:48`、`:52` | `Lexer.tokenize` 自耗时占比、SQL 长度分布 | `cjprof record` + 分段计时，分别统计会话控制与非会话语句 |

<!-- 第 6 部分 -->

> 没有性能数据支撑的猜测，不进 `todo.md` / `tasks.md`

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词法分析（含 `upper` 复制）占单条语句解析耗时的主要部分 | `fdbm/src/sql/token.cj:90-300` | 自耗时占比 | `cjprof record` 跑 10 万条 `f_orm` 生成的 SQL，看 `Lexer.tokenize` self time |
| 2 | `isKeyword` 的 `toUpper` 分配是解析期主要分配源之一 | `fdbm/src/sql/token.cj:69` | 分配量/GC 次数 | `cjprof heap` + 解析压测，对比「换成 `asciiEquals`」版本 |
| 3 | 大 SQL（≥256 KB）解析期峰值内存放大到 6 倍以上 | `fdbm/src/sql/token.cj:92`、`:64` | 峰值 RSS / 堆峰值 | 200 KB / 1 MB 两档输入，量 `getAllocatedHeapSize()` 与 RSS |
| 4 | `parse` 对非会话语句做了两次完整词法分析 | 调用方 `fdbm/src/sql/SqlParser.cj:48-53`（**范围外提示**：该文件属本模块其它部分） | 两次 tokenize 的耗时占比 | 分段计时：`parseSessionCtl` 与 `tokenize` 各计一次 |
| 5 | `tables` 重建容器在 QPS 上千时产生可观测的 GC 压力 | `fdbm/src/sql/ast.cj:338-353` | 每请求分配字节数 | 埋点统计每秒分配量，对照 `cjprof heap` |

## 文件覆盖

> 与 `files/fdbm.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/README.md` | .md | ✅ | — |
| 2 | `fdbm/README_en.md` | .md | ✅ | — |
| 3 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/design.md` | .md | ✅ | — |
| 4 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/proposal.md` | .md | ✅ | — |
| 5 | `fdbm/doc/spec/fix-fdbm-integration-test-driver-name/tasks.md` | .md | ✅ | — |
| 6 | `fdbm/doc/spec/harden-fdbm-stack-defects/design.md` | .md | ✅ | — |
| 7 | `fdbm/doc/spec/harden-fdbm-stack-defects/proposal.md` | .md | ✅ | — |
| 8 | `fdbm/doc/spec/harden-fdbm-stack-defects/spec.md` | .md | ✅ | — |
| 9 | `fdbm/doc/spec/harden-fdbm-stack-defects/specs/fdbm/spec.md` | .md | ✅ | — |
| 10 | `fdbm/doc/spec/harden-fdbm-stack-defects/tasks.md` | .md | ✅ | — |
| 11 | `fdbm/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md` | .md | ✅ | — |
| 12 | `fdbm/doc/开发计划.md` | .md | ✅ | — |
| 13 | `fdbm/doc/详细设计.md` | .md | ✅ | — |
| 14 | `fdbm/src/config/BootScriptWriter.cj` | .cj | ✅ | — |
| 15 | `fdbm/src/config/BootScriptWriter_test.cj` | .cj | ✅ | — |
| 16 | `fdbm/src/config/FdbmConfig.cj` | .cj | ✅ | — |
| 17 | `fdbm/src/config/FdbmConfig_test.cj` | .cj | ✅ | — |
| 18 | `fdbm/src/config/catalog.cj` | .cj | ✅ | — |
| 19 | `fdbm/src/config/models.cj` | .cj | ✅ | — |
| 20 | `fdbm/src/config/settings.cj` | .cj | ✅ | — |
| 21 | `fdbm/src/config/source.cj` | .cj | ✅ | — |
| 22 | `fdbm/src/exception/FdbmException.cj` | .cj | ✅ | — |
| 23 | `fdbm/src/exception/FdbmException_test.cj` | .cj | ✅ | — |
| 24 | `fdbm/src/execute/Cursor_test.cj` | .cj | ✅ | — |
| 25 | `fdbm/src/execute/Dispatcher_test.cj` | .cj | ✅ | — |
| 26 | `fdbm/src/execute/ExecutorFeature_test.cj` | .cj | ✅ | — |
| 27 | `fdbm/src/execute/cursor.cj` | .cj | ✅ | — |
| 28 | `fdbm/src/execute/dispatcher.cj` | .cj | ✅ | — |
| 29 | `fdbm/src/execute/executors.cj` | .cj | ✅ | — |
| 30 | `fdbm/src/execute/placeholder.cj` | .cj | ✅ | — |
| 31 | `fdbm/src/execute/session.cj` | .cj | ✅ | — |
| 32 | `fdbm/src/idmaker/IdMakers.cj` | .cj | ✅ | — |
| 33 | `fdbm/src/idmaker/IdMakers_test.cj` | .cj | ✅ | — |
| 34 | `fdbm/src/idmaker/placeholder.cj` | .cj | ✅ | — |
| 35 | `fdbm/src/main.cj` | .cj | ✅ | — |
| 36 | `fdbm/src/main_test.cj` | .cj | ✅ | — |
| 37 | `fdbm/src/resources/DatabaseResources.cj` | .cj | ✅ | — |
| 38 | `fdbm/src/resources/DatabaseResources_test.cj` | .cj | ✅ | — |
| 39 | `fdbm/src/resources/placeholder.cj` | .cj | ✅ | — |
| 40 | `fdbm/src/route/Route_test.cj` | .cj | ✅ | — |
| 41 | `fdbm/src/route/algorithms.cj` | .cj | ✅ | — |
| 42 | `fdbm/src/route/cache.cj` | .cj | ✅ | — |
| 43 | `fdbm/src/route/global.cj` | .cj | ✅ | — |
| 44 | `fdbm/src/route/placeholder.cj` | .cj | ✅ | — |
| 45 | `fdbm/src/route/router.cj` | .cj | ✅ | — |
| 46 | `fdbm/src/server/CustomLoader.cj` | .cj | ✅ | — |
| 47 | `fdbm/src/server/DriverLoader.cj` | .cj | ✅ | — |
| 48 | `fdbm/src/server/FdbmServer.cj` | .cj | ✅ | — |
| 49 | `fdbm/src/server/FdbmTestSetup_test.cj` | .cj | ✅ | — |
| 50 | `fdbm/src/server/GracefulShutdown_test.cj` | .cj | ✅ | — |
| 51 | `fdbm/src/server/Handler_test.cj` | .cj | ✅ | — |
| 52 | `fdbm/src/server/InFlight.cj` | .cj | ✅ | — |
| 53 | `fdbm/src/server/Integration_test.cj` | .cj | ✅ | — |
| 54 | `fdbm/src/server/Server_test.cj` | .cj | ✅ | — |
| 55 | `fdbm/src/server/SessionRegistry.cj` | .cj | ✅ | — |
| 56 | `fdbm/src/server/context.cj` | .cj | ✅ | — |
| 57 | `fdbm/src/server/handler.cj` | .cj | ✅ | — |
| 58 | `fdbm/src/sql/Dialect.cj` | .cj | ✅ | — |
| 59 | `fdbm/src/sql/ParameterBinder.cj` | .cj | ✅ | — |
| 60 | `fdbm/src/sql/PartitionKeyExtractor.cj` | .cj | ✅ | — |
| 61 | `fdbm/src/sql/SqlFeature_test.cj` | .cj | ✅ | — |
| 62 | `fdbm/src/sql/SqlParser.cj` | .cj | ✅ | — |
| 63 | `fdbm/src/sql/SqlParser_test.cj` | .cj | ✅ | — |
| 64 | `fdbm/src/sql/SqlRenderer.cj` | .cj | ✅ | — |
| 65 | `fdbm/src/sql/SqlSupport_test.cj` | .cj | ✅ | — |
| 66 | `fdbm/src/sql/ast.cj` | .cj | ✅ | — |
| 67 | `fdbm/src/sql/placeholder.cj` | .cj | ✅ | — |
| 68 | `fdbm/src/sql/token.cj` | .cj | ✅ | — |
| 69 | `fdbm/test/e2e/README.md` | .md | ✅ | — |
| 70 | `fdbm/test/e2e/client/src/main.cj` | .cj | ✅ | — |
| 71 | `fdbm/test/e2e/custom_ext/src/ext.cj` | .cj | ✅ | — |
| 72 | `fdbm/test/e2e/driver_bundle_mysql/src/main.cj` | .cj | ✅ | — |
| 73 | `fdbm/test/e2e/driver_bundle_postgres/src/main.cj` | .cj | ✅ | — |
| 74 | `fdbm/test/e2e/orm_client/src/main.cj` | .cj | ✅ | — |
| 75 | `fdbm/test/postgres_e2e/README.md` | .md | ✅ | — |

合计：`.cj` 60 个 / `.md` 15 个 / 共 75 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 文档侧的「正确性」= 文档与实现是否一致：命中 `bufSize` 三档矛盾（发现 2）与流列句柄契约落空（发现 3）。安全性：§3.5 要求日志不含密码值，`commentOf` 只输出键名（`BootScriptWriter.cj:269-271`），未见敏感值进日志的文档缺陷；设计/可读性见发现 6、8、11、12 |
| §1 死代码 | 0 | 3 个文件无函数/声明可判。等价机械动作=「文档引用的每个路径/类型/成员在 `src/` 是否存在」：逐条 grep 后命中 3 处悬空引用（`src/custom/`、`fake_accessor_test.cj`+`FakeNodeAccessor`、`Crc16/32/64Partition`），已并入发现 4、11、6，不重复计数；`src/` 内非 public 符号的死代码判定留给源码部分 |
| §2 重复逻辑 | 0 | spec / 详细设计 / 开发计划 之间确有整段复述（§3.1/§3.5/§11/§12 与各 Step），按 §2 误报边界属「规格-设计-计划分层」的刻意重复，不判重复；只有 §7 与 §14.1 的 sequence 默认库口径已漂移，按 §13 记发现 10 |
| §3 空实现 | 0 | `normalize()` 的 `catch` 记 ERROR 后返回 `false`（`BootScriptWriter.cj:151-159`）是文档明确要求的「失败不阻塞启动」，不算静默吞异常；§11 自检项与 `FdbmConfig.validate` 逐项对应（抽查 driver 唯一性 / weight 后缀 / substr / snowflake / sequence / 时长类），无「承诺了但代码空」 |
| §4 栈溢出 | 0 | 文档未承诺递归结构；派生表递归展开（§8.2 `TableRef.collectTables`）的深度风险属代码侧，留给源码部分 |
| §5 OOM | 0 | 文档已自带限制登记（缓存只增不减、`size=0` 不限、f_store 无淘汰，§6.3/§12）；DELETE 键物化的规模评估需运行期数据，属代码侧 |
| §6.1 热点瓶颈 | 0 | 本部分无代码、无 profile / bench；`scope.md` 给的 `docs/LocalMode*.md` 不覆盖 fdbm 文档，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档未描述锁内 I/O；`BootScriptWriter` 的 `set/flush/normalize` 共用一把 `Mutex`（`BootScriptWriter.cj:78-79`）是脚本不被交错写坏的必需设计，临界区只含内存与一次原子写，不构成大粒度锁缺陷 |
| §6.3 并发串行 | 0 | f_net 每条连接串行执行请求（`f_net/src/server/Server.cj:169` 的 `call(...).get`），fdbm 侧无「spawn 后立刻 get」 |
| §6.4 低效算法 | 0 | 无规模数据；`sortInPlace` 只用于配置项/物理库/缓存键等小集合 |
| §7 降堆内存方案 | 0 | 无源码与改前基线；文档侧唯一相关项（缓存无淘汰）已由文档自己登记为限制，不重复出方案 |
| §8 降 CPU 方案 | 0 | 同上，无可量化热点 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时对象，也无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 1 | 流列 `-1` 重复打开句柄（发现 3，静态确定）；其余文档承诺的边界（UNSUBSCRIBE 幂等、Empty 不借连接、多段行序、无预读）已对照实现确认成立 |
| §12 并发安全与锁粒度 | 1 | 会话键用 `remoteAddress` 文本（发现 5：漂移静态确定、后果待确认）。另核实：`QueryCursor` 无锁但同连接请求由 f_net 串行化；巡检关闭与在途请求的竞态缺证据，列入待验证假设 1 |
| §14 功能完备性与 README 覆盖 | 1 | 文档承诺的 `custom` 包与 CRC 三个实现类在代码中不存在（发现 4、6）；README 覆盖属 part1，不在本部分 |
| 文件覆盖（§13 等） | 3/3 | 3 个 `.md` 全部读完，无缺失；§13 命中 11 条（发现 1、2、4-12） |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：「normalize 缩进」「parseBlock 吞行」「恒假分支」「空集合下标」；安全性：「权限位丢失」；设计合理性：「重复逻辑」「三张 key 表」。语言特性方面：`Array` 是引用类型（`sortedByKey` 的 `copy` 未复制）、`if (let Some(x) <- ...)` 惯用法使用正确；`Option` 未被静默丢弃，唯一例外是 `parseExport` 返回 `None` 时该行被当作「块内非 fdbm 行」跳过（已在「parseBlock 吞行」说明） |
| §1 死代码 | 3 | 逐个 private/internal/protected 符号搜过引用：`BootScriptWriter` 全部 private 方法与常量均有调用者；`FdbmConfig` 除 `getLogicalDatabases`（见「getLogicalDatabases 死代码」）外全部有调用；`catalog`/`models`/`settings` 的 private 符号均有调用；`return/throw/break` 后无同层语句；未使用 import 1 处（见「未使用 import」）；恒假分支 3 处（见「恒假分支」）；`public` 且对外可达的声明（`ConfigSource`、`EnvConfigSource`、`MapConfigSource`、`FdbmException`）按硬原则一不判 |
| §2 重复逻辑 | 3 | 已把 12 个文件的函数体压成「输入→输出→副作用」两两比对：5 对同语义实现（见「重复逻辑」）、1 对近似重复且漂移（见「时长口径漂移」）、1 组三张平行 key 表（见「三张 key 表」）；跨文件搜过错误文案/前缀表/默认值字面量，其余（如 `parseWeight` 与 `validateWeights`）语义不同，不合并 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`；两处 `catch` 均有日志或显式重抛（`normalize` 吞异常是设计 §3.5 明确要求，且记 ERROR）；`EnvConfigSource`/`MapConfigSource` 为真实实现 |
| §4 栈溢出 | 0 | 本部分无递归：`parseBlock`/`normalizeText`/`flushLocked` 都是单层循环，无自引用结构遍历、无递归拷贝 |
| §5 OOM | 1 | 唯一无界增长点是 EXPORT 键空间（见「EXPORT 键空间无上限」）；`boot.sh` 全量读入的内存与文件大小成正比，文件由部署方提供、非不可信长度，未单列（见「优化可行性方案」末条） |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 profile / bench 数据；`flush` 的全量重写、`sortedByKey`、`source.all()` 多次遍历都只有线索，已全部降级为「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | `BootScriptWriter.lock` 的临界区确实包含文件读写，但它保护的就是「文件内容 + `pending` + 临时文件名」这个不变量（设计 G11），无更细粒度可切；EXPORT 属运维低频操作，没有竞争证据，不作为发现 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无单消费者队列；`concurrentExportsAreSerialized` 与 `concurrentRequestsDoNotSerialize` 两个用例分别验证了「写脚本串行」与「执行器不串行」 |
| §6.4 低效算法 | 0 | 插入排序（n 很小）与 `source.all()` 多次遍历属线索，不构成复杂度缺陷；无 `remove(at: 0)`、无热点 `contains`、无循环内字符串拼接 |
| §7 降堆内存方案 | 1 | `flush` 路径 4–5 份文本副本（末条方案）；当前规模收益可忽略，标「无基线」 |
| §8 降 CPU 方案 | 2 | `std.sort` 替换手写插入排序、EXPORT 增量写；两条均标「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 本部分是启动期一次性解析与低频落盘，临时对象生命周期短但峰值极小（KB 级），没有可用峰值内存对照证明收益；且 `BootScriptWriter` 的状态跨函数存活，逃逸检查不通过 |
| §11 现有代码的 BUG（存量） | 6 | 「EXPORT 值不校验」（下次启动失败）、「normalize 缩进」、「parseBlock 吞行」、「权限位丢失」、「池参数下界」、「空集合下标」；本轮读到的 12 个文件里 `getNodes`/`parseAddress`/`parsePort`/`parseWeight`/`parseSubstring` 的边界（空串、缺 `@`、缺端口、IPv6 方括号、权重分隔符）逐一核对，未发现新问题 |
| §12 并发安全与锁粒度 | 0 | 唯一共享可变状态是 `BootScriptWriter` 的 `pending`/`serial`，读写在 `Mutex` 内；`Config.set` 在同一临界区；全模块无第二处跨线程状态；`FdbmConfig`/`LogicalCatalog` 都是不可变构造（`let` 字段），构造后只读。锁粒度评述见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 1 | 承诺源逐项核对：设计 §3.5 的 `normalize` 缩进契约（见「normalize 缩进」）、设计「复制原文件权限位」（见「权限位丢失」，实现缺失）、README「其他公开 API」（见「README 未收录」，遗漏 3 个 public 类型）；`BootScriptWriter.normalize` 已在 `FdbmServer.cj:230` 接线，`ExportExecutor` 已接入 `set/flush`，无「承诺但未接线」项 |
| 文件覆盖（§13 等） | 12/12 | 12 个文件全部读完；`.md` 文件不在本部分清单内（由第 1/2 部分覆盖），本报告涉及的文档位置只用于提供判据 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：重复 ID、丢弃生成的 ID、缓存计数漂移、内存结果关闭语义；设计：`DdlExecutor` 借用 `GlobalTableRouter` 解析 DDL 目标库（能用但职责错位，未单列）；安全性：SQL 全部经 `SqlRenderer.literal` 渲染，未见拼接注入 |
| §1 死代码 | 1 | 已逐个比对：`private`（`pinTarget`、`queryKeys`、`openSegment`、`closeResource`、`hasColumn`、`isCountOnly`、`hasDerivedTable`、`keyOf`、`bucketOfString`…）均有调用者；`internal` 顶层函数（`borrow`/`dialectOf`/`joinNames`/`broadcastWrite`/`smallestName`/`allDatabases`/`int64Of`/`detailOf`/`ensurePinnedTargets`/`warnPinnedGlobalWrite`/`reasonSuffix`/`closeAfterExecution`）全部有引用；`protected` 类型成员逐个搜过，唯一无读取的是 `PinnedConnection.transactionOpen`（已报）；接口实现（`PartitionAlgorithm`/`IdGenerator`/`QueryResult`/`Resource`/`NodeAccessor` 成员）按豁免不判；对外不可达的 `public` 成员（`MemoryQueryResult.close`、`CursorSegment.statement` 等）均在类内或测试中被使用 |
| §2 重复逻辑 | 2 | 已把本部分全部函数体压成「输入→输出→副作用」两两比对；同文件内命中：`partitionCode`/`cacheCodeOf`（逐字相同）、桶下标计算 4 份；跨文件命中：逐库执行 3 份、广播+部分失败 2 份、`joinNames` 3 份、收尾工具 2 份、测试 `codeOf` 7 份 |
| §3 空实现 | 1 | 全部函数体与分支均已读；无 TODO/FIXME、无「开关打开走进空分支」；`CursorSegment.close`（`cursor.cj:42-64`）等关闭路径上的 `catch (_: Exception) {}` 属有意 no-op（关闭失败无处上报，且按序尽力而为），不判；命中项为 `MemoryQueryResult.close()` 空转 |
| §4 栈溢出 | 0 | 已核对：本部分无递归函数（`sortedNames` 插入排序、`broadcastWrite`/`executeAll` 均为迭代），无自引用结构遍历，无每帧大对象 |
| §5 OOM | 1 | 命中 `insertFromSelect` 全量物化（严重）；`queryKeys` 的全量键收集为有界于行数，已归到 §6.4；`PartitionCache` 的键数受 `capacity` 约束（但计数漂移，见一般条目） |
| §6.1 热点瓶颈 | 0 | 本轮未提供 `cjprof`/`cjpm bench` 数据，任何「热点」结论都不成立；已转成「待验证假设」4 条（生成器构造、缓存锁、queryKeys、物化峰值） |
| §6.2 大粒度锁 | 0 | `PartitionCache` 的「一把锁 + 锁内磁盘 I/O」形态成立，但缺单次持有时长与竞争线程数；按铁律未定为缺陷，写入优化方案与待验证假设第 3 行。`DbdSession.installCursor` 的锁内关闭按 §12.2 记为一般（静态可判，不需要测量） |
| §6.3 并发串行 | 0 | 本部分无 `spawn … get()`、无单消费者队列、无并发度=1 的批处理；游标多段是「按库串行打开」但不同库对应不同池，不构成串行段 |
| §6.4 低效算法 | 1 | `queryKeys` 的 `ArrayList.contains` 去重（O(k²)）；`route/router.cj` 的同款去重记为同一根因 |
| §7 降堆内存方案 | 2 | 游标行缓冲改 `Array`、缓存启动计数；两条均无基线 |
| §8 降 CPU 方案 | 2 | 生成器缓存、缓存重复 `get` + 锁内 I/O 外移；两条均无基线 |
| §9 local mode 可行性 | 0 | 本部分最大临时对象是 `insertFromSelect` 的 `rows`，它必须逃逸到后续 `executeAll`（跨函数、进 `InsertStatement` 列表），逃逸检查不通过；其余临时对象（`joinNames` 的 `StringBuilder`、`keyOf` 的字节数组）为短小单次分配，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | 本部分 15 条发现全部为存量（快照模式无基线）；其中逻辑/契约/资源/错误处理类 8 条：重复 ID、`insert…select` 全量物化、丢弃已生成的 ID、缓存计数漂移、锁内关闭游标、pin 检查-然后-写入、DDL 收尾标志、内存结果关闭语义。已核对本部分全部边界/空值/错误/资源路径：`partitionRange` 的 `Int64.Max/Min` 与 `low>high`、`StepPartition` 的 `N*step` 溢出校验、`step` 的 `[1, N*step]` 边界、`MemoryQueryResult` 的行/列越界、`QueryCursor` 的段耗尽与 `closed` 状态、`DatabaseResources` 的建池失败回滚与 `closeAndAwait` 参数校验均正确 |
| §12 并发安全与锁粒度 | 2 | 已列出共享点：`DbdSession.cursor/pinned`（`Mutex` + `AtomicBool`，语义正确）、`DatabaseResources` 构造后不可变 + `AtomicBool`、`PartitionCache.count_/capacityWarned`（单锁）、`IdMaker.current`（`AtomicInt64`）、`UuidIdGenerator`（`Mutex`）。命中：锁内关闭旧游标（12.2）、pin 的检查-然后-写入（12.1，依赖上层独占，记待确认） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无对外可达的 `public` 新能力（全部为 `protected` 实现），故不存在「public API 未进 README」；README 与 `protected` 成员的错配已在其它部分报告（`transactionOpen` 等）。`insert … select`、`show tables`、`export`、DDL/事务控制均已在 dispatcher 完整接线，无空分支、无 TODO |
| 文件覆盖（§13 等） | 19/19 | `files/fdbm.part4.txt` 逐行核对，无未读文件；本部分无 `.md`，§13 不适用 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 发现 #1/#3/#5/#6 + 轻微 #8/#12；语言特性方面核对了 `Array` 引用语义、`Option` 处理与 `synchronized` 返回值，未发现按值/按引用误用 |
| §1 死代码 | 3 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用：`isPartitioned`（router.cj:271）与 `PartitionRange.isEmpty`（PartitionKeyExtractor.cj:37）零引用；`freePort` 零引用；`uniquePort` 末尾 `0` 不可达；`factor` 的 `args` 只写不读；另 7 处未使用 import。`InFlight.count`/`SessionRegistry.size`/`FdbmServer.isClosed` 仅测试引用，属可见性建议，不计死代码 |
| §2 重复逻辑 | 1 | 发现 #7：`librariesOf`/`isLibrary`/`withoutExtension`/`sort` 两文件逐行相同；`joinNames` 三份且分隔符不一致；插入排序全模块 4 份。其余函数已按「输入-输出-副作用」两两比对，无同语义实现 |
| §3 空实现 | 0 | `catch (_: Exception) { () }` 全部位于清理/幂等路径（`closeCache`、`installCursor` 的关闭失败、`takeCursor` 后重复关闭），吞掉的是清理动作本身的失败，不影响主流程返回值；无 `TODO`/`FIXME`/`UnsupportedException` 占位在主路径 |
| §4 栈溢出 | 1 | 发现 #2：表达式/派生表递归无深度上限；`route` 的 `selectConstraint` 递归深度受同一输入约束（同根因，未重复计数） |
| §5 OOM | 0 | 路由与加载器处理的是启动期配置规模（规则数、物理库数）；无按报文长度预分配、无全局只增容器；`protocolError` 的日志放大归入安全性条目，不计 OOM |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，三处线索（双次词法、`tables` 重复展开、`sweep` 锁）全部列入「待验证假设」，未作缺陷 |
| §6.2 大粒度锁 | 0 | `sweep` 临界区含 `isBufferClosed` 跨对象调用，但没有持有时长/竞争线程数数据，只写成优化方案 3；判定依据为设计面（§12.2），不作性能结论 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` 后立即 `get()`、无单消费者串行段（测试夹具里的并发用例不属于产品路径） |
| §6.4 低效算法 | 0 | `intersect`/`sameSet` 用 `contains` 为 O(n²)，但 n = 物理库数（个位数）；`remove(at: 0)`、循环拼串、重复解析正则均未出现。`tables` 重复展开归入 §8 方案 |
| §7 降堆内存方案 | 1 | 方案 1（缓存 `statement.tables`）；无基线，标注待验证 |
| §8 降 CPU 方案 | 2 | 方案 2（去掉一次词法分析）、方案 3（缩小 `sweep` 临界区）；均无基线 |
| §9 local mode 可行性 | 0 | 解析产物（AST/token）作为返回值逃逸出 `parse`，不满足 local region 的逃逸约束；loader/路由为启动期一次性路径，峰值内存不构成问题。结论：本部分无可行改造点 |
| §11 现有代码的 BUG（存量） | 5 | 发现 #1/#2/#3/#4/#5 均为本轮读到的既有逻辑缺陷，逐条给了位置与推演；`handler` 的游标状态机、`ParameterBinder` 的参数计数、`insertConstraint` 的列匹配已逐分支核对，未发现额外缺陷 |
| §12 并发安全与锁粒度 | 3 | 发现 #4（关闭竞态）、#5（`server` 字段发布）、优化方案 3（`sweep` 锁粒度）；`InFlight` 的 `enter/leave/notifyAll` 配对与 `Condition.wait` 返回值语义已按文档核对 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分清单不含 `README.md` / `README_en.md` / `doc/**`，无法做 README 对照；留给包含文档的部分，避免重复统计 |
| 文件覆盖（§13 等） | 18/18 | 清单 18 个 `.cj` 全部读完；本部分无 `.md`，§13 不适用 |

### 第 6 部分

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
| 严重 | 6 |
| 一般 | 28 |
| 轻微 | 53 |
| 其中存量 | 87 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：这批文档的密度与准确度明显高于一般项目：配置默认值、逻辑库命名空间规则、池参数、错误码、优雅停止顺序都能在源码里逐条对上，`harden-fdbm-stack-defects` 的 D/G 编号与实现也基本自洽。真正需要先处理的是**并发契约没有落到对象层**：`DbdSession` 的锁只保护引用，`QueryCursor`/`CursorSegment`/`PinnedConnection` 在巡检或关停线程里被摘除后立即关闭，而在途请求仍在使用同一对象；配合 `f_dbpool` 的「close 即回池」语义，存在同一条物理连接被两个借用者并发使用的风险（#1，阻塞项）。其次是与用户契约相关的两处文档问题：事务只能作用于 pin 的那个物理库、事务内 DDL 一律拒绝，README 完全没写而 spec 还写反（#2）；同一变更的两份 spec 对全局表是否隐式展开结论相反（#3）。这两条不修，按文档接入的人会直接踩到 `ROUTE_FAILED` 或误判全局表广播范围。其余为文档可读性与可维护性（API 段截断、死代码、重复 helper、README 能力表漏项），可以排期处理。另有一组小型文档账目建议随同一次整理收口：协议 `-1` 保留值只写在详细设计、README 仍按 `<= 0` 描述（#12），fdbm.sh 必填项与退出码描述比实现窄（#14、#16），fix 变更设计文档引用了一个不存在的目录（#13），`fdbm_checkDuration` 的「有限」校验与 spec 文本不对称（#15）。

**第 2 部分**：这批文档质量整体偏高：路由五态、多段游标、UNSUBSCRIBE 幂等、DELETE 三步、优雅停止顺序、启动自检清单都能在实现里逐条对上，MUST 级协议语义基本没有落空，限制（无 2PC、多库 `order by`/`limit` 不严格、缓存只增不减、Windows 无优雅停止）也登记得比较诚实。

问题集中在两处根因：**① 文档没随 2026-10-21 那轮 `harden-fdbm-stack-defects` 回填**（类型被合并、包被并入 server、签名与装配顺序变了），发现 4、6-12 都是这一类，纯文档改动、风险为零，建议一次性回填；**② 协议细节的口径分裂**，即发现 1-3：`bufSize` 三档语义在详细设计内部就矛盾，流列 `-1` 分支又真的与「句柄只打开一次」的契约冲突，`boot.sh` 示例与 `normalize()` 的解析规则互斥。

按后果排序，建议优先：#3（重复 NULL 探测会重放首块，属实现缺陷，需改 `cursor.cj`）、#2（协议口径，决定客户端怎么写）、#1（按示例部署二次启动起不来，运维可见）。其余为文档漂移，排期回填即可。严重度按 §13 的文档类定级规则给出（示例跑不通 → 一般），若按「二次启动失败」的运维后果衡量，#1 应视为阻塞项并随实现修复同批处理。

**第 3 部分**：本部分的代码质量整体偏上：配置解析几乎每条 `get*` 都做到「键缺失取默认、键存在但非法立刻抛带键名与原值的 `CONFIG`」，`validate` 把跨项引用（驱动唯一性、权重/分片/全局表/ID 生成器）放在启动期一次收口，比运行期才炸好得多；`BootScriptWriter` 用「临时文件 + rename + 单一 Mutex」把并发写脚本这条容易出错的路收敛得比较干净，测试也覆盖了幂等、转义、旧标记迁移与并发 EXPORT。

真正的阻塞项只有一个：**EXPORT 的键空间没有边界**，任意客户端都能用无限后缀的键让 `pending` 和 boot.sh 持续增长，且每次落盘全量重写造成 O(N²) 的 I/O——这与「配置项由部署决定」的语义不匹配，建议优先把它收敛成「有限键集合 + 已配置实体校验」，顺带解决同一处「只校验键名不校验值」导致的下次启动失败问题。

其余四项「一般」都属于运维可感知但非阻塞：`normalize` 的缩进判定与设计不一致（tab 缩进/插入点，改坏脚本是静默的）、`parseBlock` 在 END 标记缺失时会吞掉块后的非 fdbm export、重写 boot.sh 只搬可执行位（内含明文库密码，权限可能被放宽），以及连接池参数完全没有下界校验。这四条都建议排期，其中权限位那条与设计文档存在一对矛盾表述，修实现或改文档必须选一个。

十条「轻微」以死代码、重复逻辑和文档遗漏为主：`getLogicalDatabases` 无人调用、三处恒假分支、一个多余 import、五对同语义工具函数（含一份重复的池默认值表）、三张平行的 key 表、三处裸下标取首元素、`durationOf`/`durationValue` 的时长口径漂移、`pending` 全量复用与设计表述不符、权重键 `endsWith('_')` 误伤合法节点名，以及 README 漏收三个 `public` 配置源类型。它们不影响当前行为，但都会让下一次「加一个配置键」变成多处同步修改，属于可以顺手清掉的技术债。性能方面的结论全部没有基线，已按要求放进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。

**第 4 部分**：本部分（执行器 / ID 生成 / 资源装配 / 路由算法）整体工程质量偏上：资源收尾几乎每条路径都有 `try/finally` + `closeAfterExecution`，错误统一走 `FdbmException(code)`，事务 pin、游标摘除、缓存关闭都有并发用例，`warn/fail` 的边界注释也写得清楚。**两个阻塞项都在「取号」与「物化」上**：

1. **每行新建 ID 生成器导致同毫秒重复 ID**（`IdMakers.cj:262` + `executors.cj:898`）——数据正确性问题，且只在多行 INSERT/`insert … select` 上偶发，建议优先修并补用例；
2. **`insert … select` 全量物化无上限**（`executors.cj:830-857`）——OOM 面，需要分批或行数上限。

其余为「一般」4 条（无列清单 INSERT 白烧一次 ID、缓存容量计数漂移、会话锁内关闭游标、pin 的检查-然后-写入）与 9 条轻微（死字段、日志放大、DDL 收尾标志、O(n²) 去重、内存结果关闭语义、两组重复逻辑、测试强度、仅测试 API）。重复逻辑集中在「逐库执行 / 广播部分失败」模板与 `codeOf` 系列测试辅助，是后续改动最可能产生行为分叉的地方，建议与上述修复同期收敛。

本部分 **存量缺陷 15 条**（严重 2 / 一般 4 / 轻微 9），是否纳入修复待用户决定；4 条优化方案与 4 条待验证假设均无基线，不进入 `tasks.md`。

**第 5 部分**：本部分代码的整体结构是健康的：`FdbmServer` 在构造期完成「自定义扩展 → 配置校验 → 驱动唯一性 → 资源/路由/缓存」的装配，失败路径对缓存与连接池做了成对清理（`FdbmServer.cj:88-134`），`handler` 的每个分支都保证回包，会话/游标的关闭顺序有专门用例（`GracefulShutdown_test`），加载器的错误码区分也符合设计。分层与依赖方向没有违规：`route` 不借连接、`sql` 不感知执行器、`server` 只做协议编排。

阻塞项有两个，都属于「唯一闸门失效」类：
1. **范围路由把「无边界」当「全范围」**（发现 #1）——`UPDATE`/`DELETE` 缺少分库键条件时不会按设计报错，而是静默在全部物理库执行。这是本轮最该先修的一条，改动仅在 `expressionConstraint` 的一个判定加两条用例。
2. **解析器递归无深度上限**（发现 #2）——SQL 是客户端可控输入，且协议层没有长度上限，深嵌套即可打崩整个 fdbm 进程，属于远程 DoS 面。建议按常量深度上限拦截并补负向用例。

其余为排期级：`select 1` 重复行（发现 #3）影响探活/常量查询的正确性，值得随 #1 一起修；关闭期会话泄漏与 `server` 字段发布竞态（#4/#5）窗口窄、影响限于停机流程，可在下个迭代补守卫；错误日志打印完整 payload（#6）按安全基线整改；加载器四函数重复（#7）与 5 条轻微项属可维护性，可与本轮修复一并处理。

性能方面本轮没有可复核数据，三处线索（每条 SQL 两次词法分析、`statement.tables` 重复展开、`sweep` 锁内跨对象调用）只列入优化方案与待验证假设，未计入缺陷，也未进修复清单。

本部分共 12 条发现（严重 2 / 一般 5 / 轻微 5），全部为存量；是否纳入修复待用户在门禁决定。

**范围外提示**：`fdbm/src/execute/executors.cj:882-913` 的 `fillAndRoute` 在「无列清单、无 SET 对」（如 `insert into t values (1,'a')`）时会先调用 `idLiteral` 生成并消费一个 ID，但 `columns`/`pairs` 两个分支都为空，生成的 ID 被丢弃，随后仍按 `Unroutable` 处理；该文件不在本部分清单内，仅记一句，交由对应部分核实。

**第 6 部分**：`src/sql/` 这一层的手写词法/AST/渲染实现整体是干净的：AST 全不可变、无同步状态、参数走白名单字面量（不存在拼串注入面），往返用例（`parse → render → parse`）覆盖了主要语句形状，代码质量在「能工作且可读」一档。

本部分真正需要排期的只有两条一般项：**DML 的 JOIN 渲染没有方言分支**（`update/delete ... join` 在 PG 上必然语法错误，而这两条能力写在设计文档里，且 e2e 从未执行过它们），以及**派生表递归无深度上限**（深度由客户端 SQL 控制，三层递归链叠加）。前者建议直接补方言改写 + 双后端用例，后者加一个层数上限即可闭环。

轻微项集中在三处：一是残留物（`SqlKind` 与 8 个 `kind`、16 行空文件 `placeholder.cj`、只被测试触达的 `renderShow`），二是同规则两份实现（`renderName`/`renderIdentifier`、十六进制方言分支、`literal`/`isLiteral` 白名单），三是 e2e 夹具的断言强度与 README 登记（7 个真实生效的环境变量、自定义扩展那一轮完全没写）。这些都属可排期清理，不阻塞发布。

性能面没有 profile/bench 数据，本部分一律不写成缺陷：`Lexer` 的全量物化与每 token 大写副本、`quoteText` 的三份临时副本是最值得先拿数据的两处（优化方案 1、2），local mode 因 `tokens` 逃逸判定为不可行。
