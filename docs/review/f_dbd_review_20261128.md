# f_dbd 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（49 个 `.cj` 源文件；模块内另有 20 个 `.md` 文档，见「文件覆盖」说明）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce64`；`git status` 仅见审查产物，源码无改动 ⇒ 全部按「存量」记录）
- **审查重点**：协议载荷 / 列 / 结果集、驱动 / 连接 / 语句 / 事务生命周期、传输层 / URL、多数据源路由；正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发安全与锁粒度、存量 BUG、内存 / CPU 优化、local mode 可行性
- **报告版本**：v1（由 `reviews/202611280829_full/parts/f_dbd.part1.md` ～ `part4.md` 合并；同根因已合并、严重程度取更严、统计已去重）

> 合并说明：part1 覆盖 `src/common/` 15 个文件，part2 覆盖驱动层 15 个，part3 覆盖传输 / URL / multid 15 个，part4 覆盖 multid 测试 4 个，合计 49 个 `.cj`，无遗漏。合并时把「placeholder 空 / 过期说明」「`freePort` 重复」「`database` 首段口径」「`MaxWaiting` 不生效」「死代码 / 未使用 import」五组跨部分重复各并为一条；`MaxWaiting` 由 part3 的「一般」与 part4 的「轻微」合并后取「一般」。

## 发现

### [严重][存量] `decodeStrict` 的严格 flag 实际恒为 0，与自身注释冲突：含整数字段的载荷可能永远解不出

- **位置**：`f_dbd/src/common/types.cj:54`（注释自述在 `:49-50`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee` 引入；诱因是 `f_data` 2026-10-15 `f8b45cccd` 把 `DEFAULT_DATA_FLAG` 从 `WRAPPING|SILENCE` 改为纯 `SILENCE`）
- **判据**：review-checklist §11（错误处理静默失效 / 契约与实现不符）、§3（静默吞失败）
- **证据**：静态确定 —— `f_data/src/base/global_objects.cj:42-51` 中 `SILENCE = 1|2|4|8 = 15`、`DEFAULT_DATA_FLAG = SILENCE`，故 `DEFAULT_DATA_FLAG & !SILENCE == 0`；同函数 `:49-50` 的注释明确写「`flag: 0` 时所有含整数字段的载荷都解不出来」；`f_data/src/base/NumberData.cj:244-273` 在 flag 为 0 时落到 `throw DataException`。唯一不确定点是 `f_data/src/base/DataObject.cj:208-213` 的 `populate` 早退（同型 `DataObject<T>` 不转换、flag 不生效），端到端是否已暴露见「待验证假设 #1」。
- **描述**：`decodeStrict` 等价于「用 flag 0 解码」，凡载荷含 `Int64` 字段（`UpdateResultPayload.rc/liid`、`ColumnInfoImpl.len/scl/ds`、`DbdErrorPayload.code`、`QueryResultColumnPayload.index/bufSize`）都抛 `DataException` 并被本函数吞成 `None`。范围外影响：`DbdStatement.cj:86/108` 会把每条查询 / 更新响应判成 `PROTOCOL`，`DbdTransport.cj:128` 会把每个 `ERROR` 降级成 `PROTOCOL` 并丢掉错误码与 sqlState。
- **建议**：改为显式策略位，如 `flag: THROWING_ON_INT_OVERFLOW`，不依赖 `DEFAULT_DATA_FLAG` 的当前取值；补 `UpdateResultPayload` / `DbdErrorPayload` 各一条 `decodeStrict` 往返用例。

### [严重][存量] 连接级「结果集独占」是检查-然后-发包-再登记，并发 `query()` 可同时通过闸门，两个游标并存导致行数据错位

- **位置**：`f_dbd/src/driver/DbdStatement.cj:82-98`（`ensureExecutable()` → `connection.request(...)` → `openResult = result` → `registerResult(result)` 跨一次网络往返）；闸门与登记在 `f_dbd/src/driver/DbdConnection.cj:124-142`
- **来源**：存量（`git blame -L 120,142 -- f_dbd/src/driver/DbdConnection.cj` 全部落在 `ef7b9b06ee` 2026-10-18）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§6.2（复合操作未原子化）、§11（契约与实现不符）
- **证据**：静态确定 —— `ensureNoOpenResult` 只在 `synchronized(lock)` 内读 `activeResult` 后立即释放锁，`query()` 随后在锁外调用 `connection.request(...)`，直到拿到 `QueryResultServerPayload` 才 `registerResult`（`:138-141`，无条件覆盖，既不校验 `closed` 也不校验已有值）。两个线程可同时通过闸门并各自发包。
- **描述**：类注释 `DbdConnection.cj:28-35` 把「同一时刻连接上至多一个未关闭 `QueryResult`」写成不变量 6，理由（`QueryResultColumnPayload` 不带结果标识）也写明；当前只挡住顺序复用，挡不住并发。两个 `QueryResultImpl` 同时存活、`activeResult` 被后者覆盖后，两个线程的 `NEXT_ROW` 交替打到同一连接级游标，`next()` / `get<T>(i)` 返回对方的行且不抛异常。触发面：连接池归还后又被另一线程借出，或调用方自行共享连接；`DbdStatement` / `DbdTransaction` 自身无同步，同源。
- **建议**：把闸门从 check 改成 acquire：在同一临界区内判断并写入 `queryInFlight` 占位，失败路径在 `finally` 释放；`registerResult` 校验占位归属，`close()` 一并清占位。补并发用例：8 线程对同一连接各 `query()` 一次，断言恰好 1 个成功、其余 `CURSOR_STATE`。

### [一般][存量] `QueryResultImpl.next()` 异常路径不复位行状态，后续 `get()` 可能读到未定义行

- **位置**：`f_dbd/src/common/result.cj:91-112`（`98` 发包、`101` 抛 `PROTOCOL`、`105-110` 才更新状态）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §11（错误处理缺失 / 状态机不一致）、§12.1（异步失败后状态未处理）
- **证据**：静态确定 —— 三种失败路径（`send_` 超时 / IO、响应不是 `DataBool`）都在 `rowValid`/`exhausted` 更新之前退出，两个字段保持上一行值；`ensureReadable`（`:209-212`）只看 `rowValid`，失败后 `get()/getOrNull()` 仍认为当前行可读。
- **描述**：`NEXT_ROW` 失败后服务端游标可能已推进或连接已断（`DbdTransport.cj:134-146` 自述「可能已错位」），客户端继续用旧 `rowValid=true` 读列，返回上一行或错位行的单元格。fdbm 侧同类缺陷已按 G28 修过（`fdbm/src/execute/cursor.cj:122-129`：推进失败先 `rowValid = false; clearRow()`），客户端漏了同一处理。
- **建议**：把 `send_` 放进 `try`，任何失败先 `rowValid = false; invalidateStreams()` 再重抛；或抽 `private func failRow()` 统一复位。

### [一般][存量] `readData` 的流列分支整块物化且无上限，同时丢失 IO 异常包装

- **位置**：`f_dbd/src/common/types.cj:368`（`readChunk(readStream(result, index), 0).toData()`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`；2026-10-21 `eda252b8f` D02 明确改成「整读」）
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）、§11（错误处理不对称）
- **证据**：静态确定（规模可量化）—— `readChunk(..., 0)` 走 `toEnd` 分支（`:406-420`），把整个 `InputStream` 读进 `ArrayList<Byte>` 再 `toArray()`；峰值约「值大小 V × 2 + 64 KiB」，1 GiB LOB 即 ≥2 GiB 峰值，无上限、无超限抛错路径。
- **描述**：fdbm 游标路径是分块流式（`fdbm/src/execute/cursor.cj:169-187`），但 `readData` 这条「一次性」路径（`fdbm/src/execute/executors.cj:404/636/1051` 对 `RETURNING` 类语句使用）对所有 `InputStream` 列整读。`readChunk` 内 `stream.read` 的异常未包装，会以驱动原始异常穿透到 fdbm 与调用方；同文件 `encodeParameter`（`:462-468`）却包装成 `DataException`，同一模块两套错误契约。
- **建议**：给整读加可配置上限（如 `max_lob_bytes`），超限抛 `DbdException(CONVERSION/CONFIG)`；至少用 `try/catch` 把非 `DbdException` 包成 `DataException`，与 `encodeParameter` 对齐。

### [一般][存量] 归一化表缺 `int` 基名：`INT(11)` / `INT(11) UNSIGNED` 被归一成 `String`

- **位置**：`f_dbd/src/common/types.cj:250-256`（`PAREN_BASES` 无 `int`）、`:241-248`（`parenBaseOf`）、`:214-227`（去括号重试）、`:320-345`（`resolveDialect` 只认精确 `int`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §11（语义与规格不符）、§2（两张表不一致导致行为漂移）
- **证据**：静态确定 —— `"int(11)"` 在 `resolveCangjieName` 无匹配，`resolveDialect` 只认精确 `'int'/'integer'`，`endsWith(' unsigned')` 不成立，`PAREN_BASES` 有 `'integer'` 但无 `'int'` 且 `'int(11)'` 不以 `'integer'` 开头，最终返回 `None`，`canonicalName` 兜底 `'String'` 并打 WARN；`"int(10) unsigned"` 同理。
- **描述**：MySQL/MariaDB 最常见的整型拼写带长度后缀，归一后列 `typeName` 变成 `String`：`ColumnInfo` 元数据错报（影响 ORM 映射），`readData` 按 `String` 读列（多一次驱动侧字符串化 + 客户端再解析），而 `bigint(20)` / `smallint(6)` / `mediumint(8)` / `tinyint(4)` 都正常。现有用例只覆盖 `TINYINT(1)` / `varchar(64)` / `decimal(10,2)`（`sqltypes_test.cj:105-109`）。
- **建议**：在 `PAREN_BASES` 补 `'int'`，并让 `parenBaseOf` 校验基名之后紧跟 `(`，避免 `int4range` / `interval(x)` 误命中；补 `readType('int(11)') → I32`、`readType('int(10) unsigned') → U32` 两条用例。

### [一般][存量] 未知列类型的 WARN 打在逐单元格路径上（日志放大）

- **位置**：`f_dbd/src/common/types.cj:370-372`
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §8（日志放大，`perf §9.1`）、§6.4（同一输入重复计算）
- **证据**：静态确定 —— `readData` 每读一格调用一次 `readType(typeName)`，`Unknown` 分支的 `logger.warn(...)` 无去重、无节流；列类型是每列固定值，同一列 N 行即 N 条同文案 WARN。
- **描述**：`GEOMETRY` / `inet` / `tsvector` 这类列（`sqltypes_test.cj:113-118` 承认是 WARN 兜底族）在 10 万行结果集上产生 10 万条 WARN，日志成本与磁盘占用按行数放大，并把真正的告警淹没。列信息归一（`canonicalName`，`types.cj:155-162`）已在「每列一次」的位置打过同样 WARN。
- **建议**：`readData` 的 `Unknown` 分支去掉日志（信息已由 `canonicalName` 报过），或按 `typeName` 做一次性去重（`HashSet<String>` + 上限）。

### [一般][存量] `QueryResultImpl` / `DbdInputStream` 未声明线程封闭，可变状态无任何同步

- **位置**：`f_dbd/src/common/result.cj:55-62`（5 个可变字段）、`:392-398`（`DbdInputStream` 的 `pending/pos/eof/dead`）、`:345-351`（`invalidateStreams`）
- **来源**：存量（`git blame` 2026-10-18 `ef7b9b06ee`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）
- **证据**：待确认 —— 共享路径：`next()` 在调用线程写 `dead=true` 并清空 `pending`（`:346-350` → `:440-444`），若另一线程正在同一 `DbdInputStream` 上 `read()`（读 `dead`/`pending`/`pos`），构成无同步的数据竞争（可见性 + 撕裂读）；同一结果集并发 `get()/next()` 还会交错发包打乱服务端单一游标。缺的信息：std.database.sql 是否承诺 `QueryResult` 单线程使用，本仓类型上没有任何线程约束注释。
- **描述**：类型对外是 `public class ... <: QueryResult`，无 `@ThreadSafe` 也无「仅限单线程」文档；一旦被连接池 / 异步框架跨线程使用，错误是沉默的数据错乱而非异常。
- **建议**：在类注释写明「单线程使用，禁止跨线程共享」（若契约允许），或对 `closed_/rowValid/exhausted/dead` 使用原子 / 锁并说明并发语义；不要为降锁粒度牺牲正确性。

### [一般][存量] `SqlPayload` 参数按最大 index 逐位补 NULL，`set(index)` 只挡负数 —— 巨大 index 直接 O(n) 分配

- **位置**：`f_dbd/src/driver/DbdStatement.cj:249-266`（`sqlPayloadOf` 的 `while (i <= max)`）、`:64-73`（`set` / `setNull`）、`:168-172`（`checkIndex` 只判 `< 0`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信长度预分配 / 一次性物化）、§6.4（已知规模却用线性填充）
- **证据**：静态确定 —— `max` 只由调用方传入的 `index` 决定，`checkIndex` 仅拒绝负数；`while (i <= max)` 对每个空洞 `payload.addNull()`，`params` 长度恒为 `max + 1`，每元素是一个 `DataAny` 包装。
- **描述**：`Statement.set<T>(index, value)` 是 std 公开契约，`index` 由应用给出。写错一个量级（如 `set(1_000_000, v)`，或把 0 起索引误当 1 起）就构造百万级 `DataAny` 并在编码时全部上链：按单元素 30–50 字节估算即数十 MB 瞬时分配，`Int64` 上界的一半就是必然 OOM / 长时间卡在 `while`；当前无上界，也无「参数个数 vs SQL 中 `?` 个数」核对。
- **建议**：给 index 加上界（如 `> 65535` 抛 `CONVERSION`），并在执行前核对参数个数与占位符数；若要保留稀疏语义，记录 `holes` 数量而非逐位补对象。

### [一般][存量] 连接上无事务互斥：两个 `DbdTransaction` 可同时 `begin`，std 契约要求的「已处于事务状态」拦截缺失

- **位置**：`f_dbd/src/driver/DbdConnection.cj:72-74`（`createTransaction()` 直接 new，不登记）、`f_dbd/src/driver/DbdTransaction.cj:72-78`（`begin()` 只校验自身 `begun`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `DbdConnection` 只有 `activeResult` 一个连接级状态，没有「当前事务」字段；`DbdTransaction.begun` 是实例字段，`txA.begin()` 不影响 `txB.begun`。std 文档（`database_sql_package_interfaces.md:116-127`）要求 `createTransaction()` 在已处于事务状态且不支持并行事务时抛 `SqlException`。
- **描述**：`txA.begin(); txB = connection.createTransaction(); txB.begin()` 会把第二条 `begin` 发到同一会话。MySQL 语义下第二条 `BEGIN` 会隐式提交前一个事务（待确认），最坏是把未提交事务静默提交、破坏原子性；客户端两条 `DbdTransaction` 都认为自己在事务中，后续 `commit/rollback` 归属混乱。结果集有独占闸门，事务反而没有，同一层不变量缺了一半。
- **建议**：在 `DbdConnection` 增加 `activeTx: ?DbdTransaction`，`createTransaction()` 在 `synchronized(lock)` 内检查并登记（已有未结束事务 → `TX_STATE`），`commit/rollback` 结束（含失败路径）注销。

### [一般][存量] 关闭连接时用 `query_timeout` 等 `UNSUBSCRIBE` 的 ACK，未配置超时即最长阻塞 6 小时

- **位置**：`f_dbd/src/driver/DbdConnection.cj:97-113`（`close()` 里 `r.close()`）、`f_dbd/src/driver/DbdStatement.cj:84-92`（`closer` 捕获 `timeoutOf(options.queryTimeout)`）、`f_dbd/src/driver/DbdTransport.cj:32`（`NO_TIMEOUT = Duration.hour * 6`）、`f_dbd/src/common/result.cj:185-197`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源释放路径的阻塞风险）、§12.1（关闭路径可挂死）
- **证据**：静态确定 —— `QueryResultImpl.close()` 首次调用同步等待 `closer_` 返回，`closer_` 是 `{request => connection.unsubscribe(request, timeout)}`；`timeout` 在 `query()` 时取值，`queryTimeout` 为 `None` 时等于 `NO_TIMEOUT`（6 小时）。
- **描述**：连接上有未关闭游标时，`close()` 先同步发 `UNSUBSCRIBE` 并等 ACK。对端半死（TCP 未断但不处理）时要等满超时；未配置 `query_timeout` 的应用（默认 `None`，`DbdOptions.cj:35`）等 6 小时。连接池淘汰、进程优雅退出、健康检查回收都会走这条路径，表现为「关闭动作卡死」，比直接报错更难排查。
- **建议**：关闭路径改用独立短超时（如 `min(queryTimeout, 默认 1–2s)`），或先 `transport.close()` 让在途请求 fail-fast 再尝试 `UNSUBSCRIBE`；不要复用查询超时。

### [一般][存量] `DbdDatasource.setOption` 与 `connect()` 并发：选项表是裸 `var`，可能取到错配的 user/password

- **位置**：`f_dbd/src/driver/DbdDatasource.cj:34-46`（`credential()` 读 `options.user` / `options.password`）、`:86-88`（`setOption` → `options.apply`）、`f_dbd/src/driver/DbdOptions.cj:30-39`（字段全是普通 `var`，无同步）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护）、§11（线程安全声明缺失）
- **证据**：静态确定 —— `DbdDatasource` 是公开长生命周期对象（被 `f_dbpool.DatabasePool` 持有并多线程 `connect()`）；`setOption` 直接改 `options`，`connect()` 在 `credential()` 里分两次读 `user` 与 `password`，再 `options.copy()` 逐字段读一遍；无锁、无原子、无 `volatile` 语义。注释（`:80-85`）只说「下次 `connect()` 生效」，未声明线程安全。
- **描述**：一个线程 `connect()` 与另一个线程 `setOption(username/password)` 并发时，可能建出「新用户名 + 旧密码」的连接（认证失败且错误信息带新用户名，排查会误判为密码错），也可能 `copy()` 读到半更新的超时组合。触发面窄（配置通常启动期写一次），但 `setOption` 是公开 API 且文档允许运行期调用。
- **建议**：二选一并写进注释：(1) 声明选项只能在 `connect()` 之前设置，运行期 `setOption` 抛 `CONFIG`；(2) 选项表改成不可变快照 + 原子替换，`connect()` 只读一次快照。

### [一般][存量] `dbdDriver()` 注释与实现相反，且按需补注册是 check-then-act，并发首用会抛出未包装的 `SqlException`

- **位置**：`f_dbd/src/driver/DbdDriver.cj:132-152`（注释 `:133` 说「没注册到就抛 `DbdException(CONFIG)`」，实现 `:147-150` 是按需补注册）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符 / 错误契约不符）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `DriverManager.getDriver(name)` 返回 `None` 后才 `DriverManager.register(name, driver)`；std 文档（`database_sql_package_classes.md:149-165`）写明 `register` 并发安全，但名称已存在时抛 `SqlException`。
- **描述**：两个线程在「配置晚于包初始化写入」的场景同时首次调用，都能看到 `None`，都构造并注册：先到者成功，后到者拿到 `SqlException`。该异常不是 `DbdException`，绕过「对外只抛 `SqlException`/`DbdException`」的统一错误面；按 `DbdException.code` 分支的调用方会直接漏到通用异常处理。注释声称的 `CONFIG` 也与实现相反。
- **建议**：补注册路径捕获 `SqlException` 后重查 `getDriver`（拿到即返回，仍为空才抛 `DbdException(CONFIG, cause: e)`）；同步修正 `:133` 注释。若认为配置不应再变，则删掉补注册分支、恢复为抛 `CONFIG`。

### [一般][存量] `Transaction` 的 `isoLevel` / `accessMode` / `deferrableMode` 只记录不生效，设置后静默无效

- **位置**：`f_dbd/src/driver/DbdTransaction.cj:44-69`（三个 `mut prop` 只读写本地字段）、`:24-28`（注释自认「只作记录」）、`:72-78`（`begin` 恒发 `'begin'`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（公开契约承诺行为但实现为空分支）、§11（语义与约定不符）
- **证据**：静态确定 —— 三个字段除 getter/setter 外无任何读取点（全文件仅 `begin()` 发固定 `'begin'`）；`DbdTransaction_test.cj:29-51` 把该行为固化成断言。std 文档（`database_sql_package_interfaces.md:590-620`）把三者定义为事务的访问模式 / 延迟模式 / 隔离级别，是描述驱动器行为的契约。
- **描述**：`tx.isoLevel = Serializable` 后 `begin()` 仍发裸 `begin`，事务实际隔离级别完全由后端默认值决定，客户端不报错、不告警。调用方据此认为已获得串行化隔离，一旦用于扣减 / 对账会直接落地成数据一致性问题。
- **建议**：三选一并在 README 写明：(1) 非 `Unspecified` 赋值在 `begin()` 时按方言拼 `begin isolation level ...`；(2) 不支持时 `begin()` 抛 `DbdException(UNSUPPORTED/CONFIG)`，绝不静默；(3) 保留现状但每次 `begin()` 打 WARN。同时删除或改写 `:24-28` 的「只作记录」注释。

### [一般][存量] 关闭状态的边界检查不完整：已关闭连接仍可 `prepareStatement`/`createTransaction`，`registerResult` 不校验 `closed`，`close()` 只关闭快照中的结果集

- **位置**：`f_dbd/src/driver/DbdConnection.cj:65-74`（两个工厂方法不查 `closed`）、`:97-113`（先取快照 `pending` 再在锁外 `r.close()`，最后 `activeResult = None`）、`:138-141`（`registerResult` 无条件覆盖）；`f_dbd/src/driver/DbdStatement.cj:64-73`（`set`/`setNull` 不查 `closed`）、`:121-132`（`close()` 只关自己的 `openResult`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（状态边界、资源释放不对称）、§12.1（关闭与在途请求竞态）
- **证据**：静态确定 —— 读 `closed` 的只有 `state`、`isClosed`、`ensureExecutable`；`registerResult` 与 `prepareStatement` 完全不看它。`close()` 的 `pending` 是锁内快照，之后 `r.close()` 在锁外执行，期间别的线程仍可通过闸门（`closed` 不参与判断）并 `registerResult`。`DbdStatement.close()` 关掉结果集后不通知连接，`connection.activeResult` 继续强引用已关闭的结果集。
- **描述**：(1) `connection.close()` 之后 `prepareStatement("select 1")` 成功返回句柄，真正错误要等到发包时才以 `IO` 出现；(2) 关闭与在途 `query()` 竞态时，快照之后登记的结果集不会被 `close()` 收掉，随后的 `transport.close()` 让它变成悬空游标（下一次 `next()` 抛 `IO`），其 `UNSUBSCRIBE` 永远不会发；(3) `statement.close()` 之后 `set(0, x)` 仍写入 `parameters`，句柄不会再用，纯属滞留内存。
- **建议**：`prepareStatement` / `createTransaction` / `set` / `setNull` 先判 `closed` 抛 `DbdException(CURSOR_STATE)`；`registerResult` 在锁内校验 `closed`，已关闭则立即 `result.close()` 并抛错；`close()` 改为「锁内置 `closed` + 取走 `activeResult` 置 `None`」，锁外关闭。

### [一般][存量] `DbdTransport` 只处理 `transfer` 返回 `None`，f_net 直接抛出的异常会穿透成非 `DbdException`，且传输不拆链

- **位置**：`f_dbd/src/driver/DbdTransport.cj:63`（`request`）、`:73`（`unsubscribe`）、`:88`（`ping`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失）/ §3（契约与实现不符）；契约源 `f_dbd/README.md:142`「对外只抛 `DbdException`」、`DbdTransport.cj:38-43` 类注释
- **证据**：静态确定 —— `f_net.Client.transfer` 只在连接显式 close 时返回 `None`（`f_net/src/client/client.cj:324-327`）；其余失败由 `MessageFuture` 存 `failure` 并在 `tryGet` 里 `throw error`（`f_net/src/MessageFuture.cj:46-48,63-72`），包括读线程解码失败 / pending.close（`client.cj:100-133`）、写 socket 失败（`client.cj:334-343`）、`DbdTransport.close()` 时有在途请求（`client.cj:240-252`）。
- **描述**：三处只 `match` `Some/None`，没有 `catch`，上述任一失败都会把 `ClientException` / `IllegalArgumentException` 原样抛给 `DbdConnection` → `DbdStatement` → 应用，违反「对外只抛 `SqlException`」的公开契约。同时这些路径不调用 `close()`：`isClosed()` 只看 `Client.closed`（`client.cj:254-256`），socket 已被 reader 关闭时仍为 `false`，后续请求会走 f_net 自动重连，把「已断链」当正常连接继续用，与类注释 §7.4「可能已错位必须立即关闭」矛盾。`DbdTransport_test.cj` 只覆盖超时（`None`）分支。
- **建议**：把 `client.transfer` 包在 `try { ... } catch (e: Exception) { throw onBroken(e) }`，`onBroken` 内先 `close()` 再抛 `DbdException(IO, ..., cause: e)`；三处抽同一个私有 `transfer()`，顺带消除命令校验重复。

### [一般][存量] `DbdUrl` 的解析异常消息直接拼入带明文口令的整串 URL 与凭据片段

- **位置**：`f_dbd/src/driver/DbdUrl.cj:58,60,65,69,98,109,155,158`（`${url}`）与 `:214,221,232`（`${value}`，即 user / password / database 片段）；同根因 `f_dbd/src/multid/Url.cj:49-70,95-98`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 安全性 / `fountain-baseline §6`「日志中不得出现凭据、令牌」
- **证据**：静态确定 —— 消息模板为 `'illegal fdbm url \'${url}\': ...'`，`url` 是调用方原样传入的连接串；`percentDecode` 的错误里 `${value}` 是 `authority[0..colon]` / `authority[colon+1..at]` 等凭据切片。异常被上层 `catch` 后打日志（f_orm / fboot 启动失败日志、`SqlException.message` 上报）即泄露明文密码。
- **描述**：同文件 `toUrlMasked()`（`:143`）专门为避免明文密码外泄而存在，但解析失败路径绕过它：最需要排障的配置写错场景恰好把密码打进日志。`%` 转义写错（`p%4`）、非 UTF-8（`%FF`）、端口非数字都会命中。part3 已记录 `DbdUrl` 与 `multid/Url.cj` 同根因，合并为一条。
- **建议**：错误消息改用脱敏串（解析早期用「scheme + host 段 + `:***@`」轻量脱敏），或只报 `scheme/host/database` 与出错位置；`percentDecode` 的细节消息去掉 `${value}`，改为「credentials 段第 N 个字节」。

### [一般][存量] `multidbm_databasePoolMaxWaiting` 在 multid 路径完全不生效（读了不用），池耗尽 50ms 即 `TIMEOUT`；测试同值配置掩盖了该缺陷

- **位置**：`f_dbd/src/multid/Datasource.cj:72`（读取）、`:87`（传给池）；`f_dbd/src/multid/Config.cj:126-134`；测试侧 `f_dbd/src/multid/MultiDatasource_test.cj:149-161,105,130`
- **来源**：存量（快照模式无基线；part3 原判「一般」，part4 原判「轻微」，合并取更严格的「一般」）
- **判据**：review-checklist §1（读了不用 / 死配置字段）、§14.1（配置项被读取却从未使用）、§11（测试未覆盖宣称契约）
- **证据**：静态确定 —— `MultiDatasource` 同时把 `maxWaiting` 与 `connectTimeout`（默认 50ms，`Config.cj:122-124`）传给 `DatabasePool`；`DatabasePool.getConnection(timeout!: Duration = connectTimeout)`（`f_dbpool/src/DatabasePool.cj:224`）与无参 `connect()`（`:242`）都只用 `connectTimeout`；`KeyPool.get` 明确写 `let limit = if (timeout == Duration.Max) { maxWaiting } else { timeout }`（`f_pool/src/KeyPool.cj:764`）。multid 路径永远不会传 `Duration.Max`，`maxWaiting` 永不参与计算。`useConfig` 把两者写成同值，`poolExhaustionAndClose` 只断言 `TIMEOUT`、不断言耗时归属，因此无论 `MaxWaiting` 是否接线都会通过。
- **描述**：README（`f_dbd/README.md:104`）与设计（`doc/详细设计.md:773`）都承诺该项是「池耗尽等待上限（`0`=无限等待）」。实际默认 `maxSize=1`/节点、`ConnectTimeout=50ms`，并发借连接超过 50ms 就 `TIMEOUT`；用户把 `MaxWaiting` 调到 30s 也无效，只能改 `ConnectTimeout`，正常排队被误报成超时，配置语义与文档相反。
- **建议**：二选一 —— ①`MultiDatasource` 改传 `Duration.Max` 让 `maxWaiting` 生效（建链超时另走 `connection_timeout`）；②删掉 `getMaxWaiting()` 与 README/设计里的该项，只保留 `ConnectTimeout` 并改文档。测试拆两条：现状用「小 ConnectTimeout、大 MaxWaiting」钉死，修复后用「大 ConnectTimeout、小 MaxWaiting」断言耗时接近 `MaxWaiting`；同时补 `useConfig('roundrobin,-1,2') → CONFIG` 的负权重用例。

### [一般][存量] `MultiDatasource.connect()` 只映射 `ConnectionException`，其余异常（含负载均衡器自身抛出的）原样逃逸

- **位置**：`f_dbd/src/multid/Datasource.cj:113-122`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 契约不符）、§12.1（并发路径）
- **证据**：静态确定（catch 覆盖范围）＋需实测（触发概率）—— `catch (e: ConnectionException)` 之外的异常全部不包装。`loadbalance.call(())` 实现为 `tree.forward(algo.next(), inclusive: true).next().getOrThrow()[1](data)`（`f_concurrent/src/LoadBalance.cj:88-90`），找不到桶时抛通用异常；`RoundRobin.next()` 的自增在锁内、回绕判断在锁外（`:35-49`），线程 A 把 `current` 推到 `Σw+1` 后让出，线程 B 读到 `Σw+1` 并返回，`forward(Σw+1)` 为空 ⇒ 抛非 `DbdException`。
- **描述**：`roundrobin` 是默认可选算法之一，多线程借用时会偶发抛出 f_concurrent 的通用异常（不是 `SqlException`），破坏 README:142 的异常契约；调用方也无法按错误码区分「池耗尽」「节点不可达」「算法越界」。
- **建议**：`connect()` 用 `catch (e: DbdException) { rethrow }` + `catch (e: Exception) { throw DbdException(INTERNAL, ..., cause: e) }` 兜底；`f_concurrent.RoundRobin.next()` 的回绕竞态另单独立项。若无法改 f_concurrent，至少在 `MultiDatasource` 侧把越界异常归一成 `INTERNAL` 并记录算法名与 `Σw`。

### [一般][存量] README 把 `MultiDConfig` 的 `protected` 静态方法列为「模块级 public API」，且 `DbdDatasource` 示例签名与实现不符

- **位置**：`f_dbd/src/multid/Config.cj:29`（`protected struct MultiDConfig`）+ `:50,70,85,...`（`public static func get*`）；`f_dbd/README.md:165`（14 个 getter 列为「模块级」）；`f_dbd/README.md:25`（`DbdDatasource(url: String, opts!)`）vs `f_dbd/src/driver/DbdDatasource.cj:34`（`init(url: DbdUrl, opts!)`）
- **来源**：存量（快照模式无基线；README:25 在 part2 仅作「范围外提示」，与 README:165 同属 README 与实现不符，合并后取更严格的「一般」）
- **判据**：review-checklist §13（文档与实现不符）/ §14.2（公开 API 清单错误）
- **证据**：静态确定 —— 顶层声明是 `protected struct`，其 `public` 成员对外不可达（只在模块内可见）；仓内除 `f_dbd.multid` 包与测试外无引用。README `:165` 却把 `getCheckInterval` / `getCheckOnBorrowing` / `getCheckOnCreation` / `getCheckOnReturning` / `getCheckSql` / `getConnectTimeout` / `getConnectionLife` / `getIdleTimeout` / `getInitSize` / `getLoadBalance` / `getMaxSize` / `getMaxWaiting` / `getMinSize` / `getWeights` 全部列为「模块级」公开函数；全仓搜索确认没有同名模块级 `func`。README:25 的 `String` 形参在源码中不存在，照抄示例会编译失败。
- **描述**：外部使用者按 README 调用 `f_dbd.multid.getCheckSql()` 之类会编译失败（`MultiDConfig` 不可见、方法也不是模块级）；`DbdDatasource` 的示例会直接编译失败。两处都是「写了但写错」的契约错误，会把使用者带沟里。
- **建议**：README 把这 14 个函数标注为「内部配置读取（`MultiDConfig`，`protected`）」，或若确需对外开放则在 `Config.cj` 增加模块级 `public func` 转发（推荐前者）；README:25 改为 `DbdDatasource(url: DbdUrl, opts!)` 并给 `DbdUrl.parse` 的示例。

### [轻微][存量] `SqlReadType.==` 用 `toString()` 比较

- **位置**：`f_dbd/src/common/types.cj:100-102`
- **来源**：存量
- **判据**：review-checklist §10（语言特性 / 惯用法）、§8（可降 CPU）
- **证据**：静态确定 —— 枚举本身可默认判等，当前每次比较产生 2 次字符串分配并逐字符比较。
- **描述**：比较开销与枚举名长度相关，且在热路径（类型判定）上被反复调用；语义上也没有必要经由字符串。
- **建议**：删除自定义 `==`，使用枚举默认判等；若必须保留，改为直接比较枚举值。

### [轻微][存量] `DbdErrorCode` 的 `value` / `toString` / `parse` 是三份 16 分支同构表

- **位置**：`f_dbd/src/common/error.cj:50-119`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— 三个函数各自维护一份 16 个枚举值与字符串的对应关系，新增一码需改 3 处；`parse` 未命中时静默兜底 `INTERNAL`。
- **描述**：三份表靠手工对齐，漏改即出现「`toString` 有、`parse` 没有」或码值漂移；`parse` 静默兜底会把未知码伪装成内部错误。
- **建议**：以 `value` 为唯一数据源，`toString` / `parse` 由它派生；加一条「表长 = 枚举数」的用例；`parse` 对未知码至少 WARN 或返回 `None`。

### [轻微][存量] `DbdException` 构造器对同一 payload 调用两次 `errorCode()`

- **位置**：`f_dbd/src/common/DbdException.cj:60-61`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 重复取值）
- **证据**：静态确定 —— 同一 `payload` 连续两次 `errorCode()`，第二次结果与第一次相同。
- **描述**：多一次调用与一次可能的字符串/分支处理，读起来也像两个不同来源。
- **建议**：取一次存局部变量后复用。

### [轻微][存量] `QueryResultImpl.next(values)` 忽略 `values` 参数，std 契约未履行

- **位置**：`f_dbd/src/common/result.cj:114-117`
- **来源**：存量
- **判据**：review-checklist §3（空实现 / 参数被忽略）、§14（契约未履行）
- **证据**：静态确定 —— 方法体不读写 `values`，调用方传入的数组不会被填充。
- **描述**：`next(values: Array<T>)` 的 std 语义是把当前行填入调用方数组；当前实现只推进游标，调用方拿到的仍是原数组内容，且没有任何提示。
- **建议**：按 std 契约填充 `values`（长度不足时的行为需与文档一致），或明确改为 `next()` 并在类型注释说明不提供该重载；补一条「填充后数组内容正确」的用例。

### [轻微][存量] 性能实验代码复制生产分派链，且无 `F_DBD_BENCH` 门禁

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:405-429`（`canonicalB` 与生产 `decodeCellAsAny`（`result.cj:231-251`）逐分支同形）、`:46-51`（19 类型 × 4 组合 × 10⁶ 次 × 5 轮，随 `cjpm test` 默认执行）、`:165`（悬空的「三组对照」注释）
- **来源**：存量
- **判据**：review-checklist §2（跨层复制）、§6.1（性能实验需门禁与数据）
- **证据**：静态确定 —— `canonicalB` 与生产分派逐分支同形，新增类型要改两处，否则实验数据静默漏项；测试无环境变量门禁，默认跑 3.8 亿次分派；注释声称的三组对照下文体只测了 A 的 NULL 短路。
- **描述**：复制生产分派会让「性能实验」与真实实现漂移；默认执行会显著拉长 `cjpm test`，且注释与代码不符会误导读者。
- **建议**：让 harness 直接调用生产分派，或明确标注「仅历史实验」并加 `F_DBD_BENCH` 门禁；删掉悬空注释或补齐三组对照。

### [轻微][存量] `codeOf` 测试辅助三份重复，且把「没有抛异常」也映射成 `INTERNAL`

- **位置**：`f_dbd/src/common/result_test.cj:627-636`、`f_dbd/src/driver/testkit_test.cj:27`、`f_dbd/src/multid/MultiD_test.cj:209`
- **来源**：存量（part1 记录语义问题，part3 记录三份重复，合并为一条）
- **判据**：review-checklist §2（跨包复制）、§11（测试断言强度）
- **证据**：静态确定 —— 三份 `codeOf` 逐行相同（只差 `DbdErrorCode` 前缀）；`result_test.cj` 版本在「没有抛异常」时返回 `INTERNAL`，与「确实抛了 INTERNAL」不可区分。
- **描述**：对断言 `INTERNAL` 的用例存在假阳性风险；三份复制会各自漂移。
- **建议**：收敛到各包一个 `testkit_test.cj`（同包才可见时至少加注释指明另两份位置）；`codeOf` 在未抛异常时返回 `None` / 直接断言失败，不要兜 `INTERNAL`。

### [轻微][存量] `sqltypes_test.cj` 注释仍描述「按 `Int64.Max` 申请、会抛分配失败」

- **位置**：`f_dbd/src/common/sqltypes_test.cj:172-176`
- **来源**：存量
- **判据**：review-checklist §13（测试注释与实现不一致）
- **证据**：静态确定 —— 当前 `types.cj:405-422` 已是分块读取，不再按 `Int64.Max` 预分配。
- **描述**：过期注释会让人误判内存行为，甚至在排障时按错误前提排查。
- **建议**：改写为「分块读取，峰值 ≈ 块大小 × 2 + 缓冲」并指向 `readChunk`。

### [轻微][存量] `placeholder.cj` 三份：空占位 / 「阶段 0 仅建骨架」过期说明

- **位置**：`f_dbd/src/common/placeholder.cj:18-20`（无任何声明，注释称「保留以兼容既有 import」）、`f_dbd/src/driver/placeholder.cj:19`、`f_dbd/src/multid/placeholder.cj:18-21`
- **来源**：存量（part1 记 `common` 空文件，part3 记 `driver` 过期，part4 记 `multid` 过期；同一模板复制，合并为一条）
- **判据**：review-checklist §1（无声明文件）、§3（空实现）、§13（文档过期）
- **证据**：静态确定 —— 三个文件都只有 `package` 与包级文档注释，没有任何声明；`driver` / `multid` 包均已完整实现传输、连接、语句、配置、数据源、URL 等，「阶段 0 仅建骨架」与现状相反。
- **描述**：读者打开这些文件会以为对应包只有骨架；`common/placeholder.cj` 声称「保留以兼容既有 import」，但实际没有类型可 import，属于无效占位。
- **建议**：删除 `common` 的空文件；`driver` / `multid` 改写为「包职责 + 入口清单」（`DbdDriver` / `DbdDatasource` / `DbdConnection` / `DbdStatement` / `DbdTransaction`，`MultiD` / `MultiDatasource` / `MultiDUrl`）或并入主类注释，删除「阶段 0」。

### [轻微][存量] 重复逻辑：`?Duration` → `NO_TIMEOUT` 的兜底写了两遍，同名 `timeoutOf` 还有第三种语义

- **位置**：`f_dbd/src/driver/DbdStatement.cj:161-166`（`private static func timeoutOf(configured: ?Duration)`）与 `f_dbd/src/driver/DbdTransaction.cj:113-116`（`execute()` 内联 `match`）；同名不同义：`f_dbd/src/driver/DbdOptions.cj:82-95`（字符串 → `?Duration`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复 / 命名漂移）
- **证据**：静态确定 —— 两处「`Option` 为空则取 `NO_TIMEOUT`」逐行等价；`DbdOptions.timeoutOf` 名字相同但参数/返回完全不同（解析 + 校验）。
- **描述**：改默认超时策略时必须同时改两处，漏改即行为漂移；同名函数承担解析与解包两种职责，搜索 `timeoutOf` 会误读。
- **建议**：抽成包内顶层 `func effectiveTimeout(configured: ?Duration): Duration`（放 `DbdOptions.cj` 或 `DbdTransport.cj` 旁），`DbdOptions` 的解析函数改名 `parseTimeout`。

### [轻微][存量] 死代码与未使用 import：`StubFdbm.consumes/clear`、`DataAny`、`getGCCount`、测试重复 import

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:80-88`（`consumes`）、`:91-94`（`clear`）；`f_dbd/src/driver/DbdStatement.cj:23`（`DataAny` 只出现在 import 行）；`f_dbd/src/driver/PayloadWrapping_test.cj:21`（`getGCCount`）；`f_dbd/src/driver/DbdDriver_test.cj:18-20`（通配 + 具名重复 import）
- **来源**：存量（part2 记 import，part3 记 `StubFdbm` 死方法，合并为一条）
- **判据**：review-checklist §1（非 public 符号无调用者 / 未使用的 import）
- **证据**：静态确定 —— `class StubFdbm` 默认 `internal`、成员默认 `internal`；全仓（排除 `.worktrees/`）`grep -rn "\.consumes()"` 与 `".clear()"` 只有定义行（其余 `.clear()` 命中是 `parameters.clear()` / `MOCKDB.clear()` 等其它对象）；`DataAny` 在 `DbdStatement.cj` 仅第 23 行；`getGCCount` 仅在 import 行；`DbdDriver_test.cj` 的具名 import 与通配 import 覆盖同一批符号。
- **描述**：`consumes()` 注释说「Node 站位用得到」，但对应用例不存在；`clear()` 注释说「多阶段用例分段断言」，实际无使用。死方法与重复 import 会随实现漂移，误导下一位读者。
- **建议**：删除 `consumes` / `clear` / 未使用的 `DataAny` / `getGCCount`；`DbdDriver_test.cj` 保留具名 import、删掉通配（或反之）。若确需「按命令过滤」，让 `QueryScript`/`allReceived` 承担，不要保留两套。

### [轻微][存量] 类型矩阵测试用 `toString()` 比较、不释放结果集、依赖全局 `MOCKDB`

- **位置**：`f_dbd/src/common/types_matrix_test.cj:112-119`（`@Assert(actual.toString(), expected.toString())`）、`:178-209`（`QueryResultImplTestResult` 与 `matrixResult` 从不 `close()` 语句/结果集，且每次先 `MOCKDB.clear()` 改全局状态）
- **来源**：存量
- **判据**：review-checklist §11（测试的资源对称性 / 断言强度）、§13 误报边界（测试准备代码不算重复逻辑，但断言写法仍可评）
- **证据**：静态确定 —— 断言两侧都转成字符串；`matrixResult` 返回 `QueryResult` 后调用方只 `readData` / `get`，无 `close`；三个 `@TestCase` 共享 `MOCKDB` 单例。
- **描述**：`toString()` 相等会把「类型错了但文本一样」判为通过（如 `String` 与 `Decimal` 都渲染成 `123.45`），矩阵判别力被削弱；不关闭结果集靠 GC 兜底，`MOCKDB` 若未来支持并行执行，`clear()` + `execution` 覆写会互相污染。
- **建议**：按 `Data` 具体分支断言（`match (actual) { case d: DataString => ... }` 或直接 `actual == expected`）；调用方 `try/finally` 关闭结果集；`MOCKDB` 准备逻辑收敛到 `@BeforeEach`。

### [轻微][存量] `MultiDConfig` 数值项没有范围校验：负值静默生效，超大值在 `Duration *` / 权重求和处溢出并抛非 `DbdException`

- **位置**：`f_dbd/src/multid/Config.cj:110-134`（`Duration.second * intOf(...)` / `Duration.millisecond * intOf(...)`）、`f_dbd/src/multid/Datasource.cj:56-59`（`total += weight`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定（代码路径）＋待确认（`Duration` 乘法溢出后的具体异常类型）—— `intOf` 只做 `tryParse`，不校验正负与上界；`Int64` 运算溢出按仓颉默认策略抛异常（开发指南 `basic_data_type/integer.md:137`）。例如 `multidbm_databasePoolConnectionLife=9223372036854775807` 会让 `Duration.second * n` 溢出，在 `MultiDatasource` 构造期抛非 `DbdException`；两个接近 `Int64.Max` 的权重会让 `total` 溢出成负数，`Int64Weight(1, total)` / `RoundRobin(1,1,total)` 以非法区间构造。负值则被静默接受：`IdleTimeout` 为负等价于「不过期」，`ConnectionLife` 为负绕过寿命检查。
- **描述**：配置错误属于部署期高频问题，当前表现是「启动时抛一个与数据库无关的算术异常」或「策略静默失效」，都不满足「非法配置 → `DbdException(CONFIG)`」的既有风格（`DbdUrl` 与 `effectiveWeights` 都做了这一点）。
- **建议**：在 `intOf` 外增加 `positiveIntOf(key, fallback, max)`：拒绝负数、拒绝超过 `Duration` 可表示范围的毫秒/秒数，超限回落 fallback 并 WARN；`effectiveWeights` 求和前用 `Int64.Max - total` 做上界检查，溢出抛 `DbdException(CONFIG)`。

### [轻微][存量] 零权重节点仍会建池、建连接（`initSize`>0 时白占 TCP 与线程）

- **位置**：`f_dbd/src/multid/Datasource.cj:75-89`（对所有节点建池）与 `:94-99`（只注册 `weight > 0` 的节点）
- **来源**：存量
- **判据**：review-checklist §7（缩短生命周期）、§11（资源使用不对称）
- **证据**：静态确定 —— `builtPools` 循环遍历全部 `datasources`，零权重节点照样 `DatabasePool(datasource, initSize: 1, ...)`；随后注册时 `if (weights[i] > 0)` 跳过该节点，池从此无人借用。
- **描述**：默认 `initSize=1` 时，每个 `weight=0` 节点都常驻 1 条 TCP、f_net 读写线程与心跳，且不在任何负载均衡桶里。运维用「权重 0」摘流时连接并不会停，反而多一条永不使用的连接。
- **建议**：`weights[i] == 0` 时跳过建池（或 `initSize: 0`），并在文档写明「权重 0 = 不建连」。

### [轻微][存量] 同一「命令校验」逻辑写了三份，且 `ping` 的 `ERROR` 分支与另两处不一致（丢了错误码）

- **位置**：`f_dbd/src/driver/DbdTransport.cj:74-80`（`unsubscribe`）、`:89-93`（`ping`）、`:118-124`（`checked`）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑，含「近似重复但少一处边界」）
- **证据**：静态确定 —— 三处都是「`ACK`/`RESP` → 通过；`ERROR` → 抛；其它 → `PROTOCOL`」的同一判定，只有通过用的命令名不同。`request` 走 `checked`（`ERROR` → `errorOf` 保留 `DbdErrorCode`），`unsubscribe` 也走 `errorOf`，而 `ping`（`:90-93`）把 `ERROR` 落进 `other` 分支，报成 `PROTOCOL` 并丢掉服务端错误码与 `sqlState`。
- **描述**：重复逻辑已造成行为漂移：同一「服务端回 ERROR」在 `request`/`unsubscribe` 里是可诊断的业务错误，在 `ping` 里变成协议错误，心跳失败的真实原因被掩盖成 `PROTOCOL`。
- **建议**：抽 `private func expect(resp: Message, ok: (Command) -> Bool, request: String): Message`（或薄封装 `expectAck` / `expectResp`），统一 `ERROR → errorOf`；`ping` 对 `ACK` 通过、`ERROR` 还原错误码、其它 `PROTOCOL`。

### [轻微][存量] 重复逻辑：`legacySqlPayloadOf` 复制生产实现、`toUrl`/`toUrlMasked` 近似重复、测试 setup 行逐字复制

- **位置**：`f_dbd/src/driver/PayloadWrapping_test.cj:30-47` vs `f_dbd/src/driver/DbdStatement.cj:249-266`；`f_dbd/src/driver/DbdUrl.cj:124-131` vs `:143-150`；`f_dbd/src/multid/MultiDTestSetup_test.cj:22` vs `f_dbd/src/driver/DbdTestSetup_test.cj:22`
- **来源**：存量
- **判据**：review-checklist §2（语义相同的实现散落多处）
- **证据**：静态确定 —— `legacySqlPayloadOf` 与 `sqlPayloadOf` 除 `add<DataAny>(DataAny(data))` / `add<Data>(data)` 外逐行相同；`toUrl` 与 `toUrlMasked` 只有 `userInfo` 一行不同；两个 `testProtocolHostIdSetup` 是同一 `Config.set` 字面量在两个包各写一遍。
- **描述**：`legacySqlPayloadOf` 作为「旧写法基准」没有版本来源注释，生产实现一改它就跟着「一起对」，等价性断言会失效（当前只验证了 `Data`/`DataAny` 包装的编码等价）；`toUrl*` 的 mask 差异适合参数化；setup 复制会各自漂移。
- **建议**：`legacySqlPayloadOf` 注释补「来自 commit/版本」，或改成「手工期望字节」的黄金样本；`toUrl` 内部调 `render(maskPassword: Bool)`；setup 行保留但加交叉注释。

### [轻微][存量] `database` 首段口径不一致：`DbdUrl` 截断 `?` 并解码 `%XX`，`MultiDUrl` 都不做

- **位置**：`f_dbd/src/driver/DbdUrl.cj:67`（先 `firstSegmentOf` 再 `percentDecode`）、`:165-177`（同时按 `?` 与 `/` 截断）vs `f_dbd/src/multid/Url.cj:58`（原始路径段直接作为 database）、`:114-119`（`firstSegment` 只按 `/`）、`:93-99`（原样拼回节点 URL）
- **来源**：存量（part3 记录 `?` 分支，part4 补充 `%XX` 分支；同一根因合并为一条，严重程度两部分均为轻微）
- **判据**：review-checklist §2（近似重复、边界不同导致语义漂移）/ §11（同一 URL 的两个 public 类型给出不同库名）
- **证据**：静态确定 —— `DbdUrl.parse('fdbm://h/db?charset=utf8').database == 'db'`（`DbdUrl_test.cj:72` 已钉死）；`MultiDUrl.parse('multidbm://h/db?charset=utf8')` 的 `database` 为 `'db?charset=utf8'`；`.../db%20x` 时 `MultiDUrl.database == 'db%20x'`、`nodes[0].database == 'db x'`。`MultiDatasource` 只用 `parsed.nodes`（`Datasource.cj:45-51`），不影响建连；但 `MultiDUrl.database` 是公开字段（README:28 明确列出），调用方做诊断、日志或二次拼串时会得到错误库名。`MultiDUrl` 自己的用例只覆盖 `/db0/extra`（`MultiD_test.cj:151-156`）。
- **描述**：同一份「首个路径段」规则在 `DbdUrl` 与 `MultiDUrl` 各写一份，`DbdUrl` 截断 `?`、`/` 并解码 `%XX`，`MultiDUrl` 只截断 `/`、不解码；两个公开类型对同一 URL 给出不同库名。
- **建议**：把「路径首段 + 解码」抽成 `f_dbd.common` 的包内函数（`?` / `/` / `#` 统一截断并 `percentDecode`），两处共用；或 `MultiDUrl.parse` 直接取 `nodes[0].database`；补 `?` 与 `%20` 两个用例。

### [轻微][存量] 节点不可达与池耗尽都映射成 `TIMEOUT`，原始原因被上游丢弃

- **位置**：`f_dbd/src/multid/Datasource.cj:115-121`
- **来源**：存量
- **判据**：review-checklist §11（错误处理不精确 / 契约与注释不符）
- **证据**：静态确定 —— `DatabasePool.connect()` 是 `getConnection().getOrThrow{ConnectionException()}`（`f_dbpool/src/DatabasePool.cj:242`），空工厂丢掉 creator 的原始异常；`MultiDatasource` 只按「池是否关闭」二分，其余一律 `TIMEOUT`（注释也这么写）。节点 TCP 建链失败、握手失败最终都以「cannot borrow ... :」+空消息的 `TIMEOUT` 呈现。
- **描述**：这与 `DbdDatasource` 的对外承诺（建链失败 → `IO`）不一致：同一个节点故障，走单节点数据源得到 `IO`，走 multid 得到 `TIMEOUT`；排障时无法区分「节点挂了」和「池太小/排队久」。
- **建议**：`DatabasePool` 侧把 creator 的异常保留为 cause（上游改动）；在 multid 侧至少区分「`anyPoolClosed` → CONFIG」「cause 是 `DbdException(IO)` → IO」「否则 TIMEOUT」，并在消息里带节点索引。

### [轻微][存量] 文档签名与注释漂移：设计文档 `DbdTransport.init` 多一个 `options` 参数、`getMaxWaiting` 注释漏负值、类注释拼写错误

- **位置**：`f_dbd/doc/详细设计.md:740`（`init(host, port, options: DbdOptions)`）vs `f_dbd/src/driver/DbdTransport.cj:49`；`f_dbd/src/multid/Config.cj:126-134`（设计说 `0` → `Duration.Max`，代码是 `ms <= 0`）；`f_dbd/src/driver/DbdTransport.cj:39`（`idyllically with code` 应为 `ideally`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 与实现不一致）
- **证据**：静态确定 —— 三处均可在源码比对。
- **描述**：按设计文档写代码的人会多传一个参数；`getMaxWaiting` 注释漏了负值分支（负数同样变无限等待，属于未声明行为）；拼写错误影响可读性。
- **建议**：设计文档同步去掉 `options` 参数（或在实现里接收并断言未使用）；`getMaxWaiting` 注释改为「`<= 0` → `Duration.Max`」，并在 `intOf` 层拒绝负值；修正拼写。

### [轻微][存量] `freePort` / `freePortOf` 逐字重复，且「先 bind 再 close 再交给 `Server`」存在 TOCTOU，异常分支静默返回 0

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:45-46`（`Server(bindAt: port, ...)`）、`:101-112`（`freePort`）；`f_dbd/src/multid/stub_test.cj:66-77`（`freePortOf`）
- **来源**：存量（part3 记录 TOCTOU，part4 记录重复；同一段代码合并为一条）
- **判据**：review-checklist §2（只改函数名 / 注释的重复逻辑）、§11（边界 / 资源时序）
- **证据**：静态确定（时序与重复）＋需实测（出现频率）—— 两段实现逐行一致（`bindAt: 0` → `bind()` → `localAddress` 取端口 → `close()`），连 `case _ => port = 0` 的静默兜底都相同；探测 socket 关闭到 `Server` 重新 bind 之间端口可被同机其它进程/并行用例抢走，并行跑 `cjpm test` 时窗口更大。`localAddress` 不是 `IPSocketAddress` 时返回 `0`，会让 `MultiStub.port = 0`：`Server` 实际绑定随机端口，客户端却连 0 端口，失败信息与真实原因无关。
- **描述**：两份会各自漂移（本次已出现命名不一致 `freePort` / `freePortOf`）；TOCTOU 表现为 `Server` 构造抛绑定异常或客户端连到别人的端口，用例随机失败；静默 0 让失败信息彻底失真。
- **建议**：抽到测试专用共享包（若 `cjpm` 测试构建支持跨包可见），否则两处加交叉注释并统一命名；`Server` 若支持 `bindAt: 0` 并回读实际端口则去掉探测，否则在 `freePort` 外层加重试（最多 3 次，捕获绑定异常后重新探测）；`case _ =>` 改为抛异常或 `panic`，不要静默返回 0。

### [轻微][存量] `Reexport_test.typeIdentity` 的 `throw/catch` 是空动作，「跨包同一性」断言并未真正验证

- **位置**：`f_dbd/src/exception/Reexport_test.cj:58-68`
- **来源**：存量
- **判据**：review-checklist §3（`catch { () }` 静默吞掉）/ §11（测试未覆盖宣称的契约）
- **证据**：静态确定 —— `typeIdentity` 先 `throw e` 再 `catch (_: Exception) { () }`，既不改变 `e` 也不产生断言；随后的 `match (e) { case x: DbdException => ... }` 只证明传入值本身是 `DbdException`。测试注释声称「从 `exception` 包构造、按 `SqlException` 捕获」证明两包类型身份相同，但 `usableFromExceptionPackage` 里的 `DbdException(...)` 解析到的就是 `public import` 进来的同一个符号，没有第二个类型可对比。
- **描述**：该用例实际验证的是「重导出可编译」，这是有价值的；但静默吞异常与无意义 throw 会让读者误以为在验证运行时身份，未来若出现真正的双份定义也测不出来。
- **建议**：删掉 `throw/catch`，把断言改成「`DbdException` 实例可赋给 `SqlException` 并被 `catch (e: SqlException)` 接住、且 `e is DbdException`」；注释说明「同一性由 `public import` 保证，编译期即可证明」。

### [轻微][存量] `MultiDUrl.parse` 的 `nodes.isEmpty()` 分支不可达（死代码）

- **位置**：`f_dbd/src/multid/Url.cj:74-76`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `nodesPart` 已在 `:62-64` 判非空；`nodesPart.split(',')` 对非空串至少产生一段，每段经 `trimAscii()` 后为空会在 `:68-71` 抛 `CONFIG`，非空段必然 `nodes.add(...)`。循环结束时 `nodes.size >= 1` 恒成立，`:74` 的条件永远为假。
- **描述**：该检查是「节点数 0」契约的重复兜底，但实际不可达，会让人误以为存在「非空 nodesPart 却解析出 0 个节点」的路径。
- **建议**：删除 `:74-76`；若想保留防御，用 `assert(!nodes.isEmpty())`，并在 `:62` 注释「nodesPart 非空 ⇒ 至少一个节点」。

### [轻微][存量] 测试共享全局 `Config`，用例间残留 `loadbalance='bogus'` 等状态，存在顺序依赖

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:85-100`（`finally` 只关桩，不还原配置）、`:149-161`（只覆盖 9/13 个 `multidbm_*` 键）；受影响方 `f_dbd/src/multid/MultiD_test.cj:194-205`（`openAcceptsBothSchemes` 未设置 `loadbalance`）
- **来源**：存量
- **判据**：review-checklist §11（测试隔离）/ §12.1（共享可变状态；若用例并行执行则构成竞争）
- **证据**：静态确定（状态残留）＋需实测（`cjpm test` 的实际执行顺序与是否并行）—— `Config.set` 按 key 覆盖写入、不清理其它 key（`f_config/src/Config.cj:107-129`）；`invalidWeightsOrAlgorithmAreConfigErrors` 的最后一次写入是 `('multidbm_loadbalance', 'bogus')`，`finally` 未恢复。若 `MultiDatasourceTest` 先于 `MultiDTest` 执行，`MultiDTest.openAcceptsBothSchemes` 的 `open()` 会在 `algorithmOf` 处抛 `CONFIG`。另有 `IdleTimeout=5s` / `ConnectionLife=3600s` / `CheckInterval=120s` / `CheckSql='select 2'` 来自 `MultiD_test.cj:33-47`，`useConfig` 未覆盖这 4 个键。
- **描述**：注释「写一组确定的池/负载均衡配置（避免用例间顺序影响）」只对 `useConfig` 列出的键成立；它既受其它用例残留影响，也把非法 `loadbalance` 留给后续用例。`Config` 是进程级 `ConcurrentHashMap`，即使内存安全，逻辑上也会互相踩。
- **建议**：`useConfig` 补齐 13 个 `multidbm_*` 键；`invalidWeightsOrAlgorithmAreConfigErrors` 在 `finally` 恢复合法 `loadbalance`（或 `Config.remove`）；更彻底的做法是每个用例 `finally` 用 `Config.remove` 逐个还原本次写入的键。

### [轻微][存量] `MultiStub` 统计所有非 PING 请求却自称「CONSUME 条数」，且对 `UNSUBSCRIBE` 回 `RESP`

- **位置**：`f_dbd/src/multid/stub_test.cj:41-49`（无命令判断即 `hits.fetchAdd(1)` 并统一 `Message.resp`）、`:56-59`（`received()` 注释）
- **来源**：存量
- **判据**：review-checklist §11（测试替身语义与命名 / 注释不符）
- **证据**：静态确定 —— `Server.start` 在调用 handler 之前就拦截了 `PING`（`f_net/src/server/server.cj:165-168`），handler 会收到 `CONSUME` 与 `UNSUBSCRIBE` 两类；当前用例只发 `CONSUME`，所以 67/33 成立。但新增游标用例后：`UNSUBSCRIBE` 会被计入 `hits`（污染权重断言），且回 `RESP` 会让 `DbdTransport.unsubscribe` 抛 `PROTOCOL`（它期望 `ACK`，`DbdTransport.cj:74-80`）。
- **描述**：测试替身的契约比它声称的宽：名字是「收到的 CONSUME 条数」，行为是「收到的所有非 PING 报文数」；对关闭游标的响应命令也不对。
- **建议**：按 `request.command` 分支——只对 `Command.CONSUME` 计数；`UNSUBSCRIBE` 回 `Message.ack(request.id)`，其它命令回 `ERROR`（或 `None`）。若短期不支持游标，把 `received()` 改名为 `requests()` 并注释「不支持 UNSUBSCRIBE」。

## 优化可行性方案

### [堆内存] `readChunk` 每调用固定分配 64 KiB 缓冲，且输出经「复制进 `ArrayList` → `toArray`」两次搬运

- **现状**：`types.cj:409` 每次调用 `Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`（64 KiB，清零）；`:418` 的 `out.add(all: buf[0..n])` 复制进 `ArrayList`，`:421` 的 `toArray()` 再复制一次。单次块读实际分配约 64 KiB + 块长×2；fdbm 每个流列块请求都新建一份缓冲（`fdbm/src/execute/cursor.cj:175/187` 调 `readChunk`），不跨请求复用（`ReadChunkReuse_test.cj` 只证明同一调用内跨轮复用）。
- **方案**：① 缓冲大小跟随 `want`（`min(size, DEFAULT_STREAM_CHUNK)`），`size` 很小时不付 64 KiB 代价；② 「读至 EOF」场景先按已知长度预分配，或直接返回 `ArrayList` 避免 `toArray` 终态复制；③ 若需跨调用复用，用可归还的线程本地缓冲（必须有上限与清理路径）。
- **预期**：小 `bufSize` 时单次分配从 64 KiB 降到 `bufSize`；整读 1 MiB 时省掉一次 1 MiB 级终态复制（对象数 -1，峰值 -1×V）。
- **代价**：① 无语义变化；② 改变返回类型或要求调用方给长度，需同步改 fdbm 两处调用；③ 池化是最后手段，必须带上限。
- **验证**：`ReadChunkReuse_test.benchToEnd`（已有 `F_DBD_BENCH=1` 门禁，统计 `alloc`）改前/改后各跑 5 轮取中位数；配 `getAllocatedHeapSize()` + RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 流列 `DbdInputStream.read` 逐字节拷贝

- **现状**：`result.cj:431-434` 用 `while (i < n) { buffer[i] = pending[pos + i]; i += 1 }` 把待消费块搬进调用方缓冲；BLOB 每个字节都经过一次仓颉层循环（数组边界检查 + 逐元素赋值），调用方缓冲通常只有 4~8 KiB，同一块会被反复分段搬。
- **方案**：改成整段拷贝，如 `pending[pos..pos + n].copyTo(buffer, 0, 0, n)`（测试里的 `PatternStream.read` 即如此，`ReadChunkReuse_test.cj:39`），并顺手把 `pos`/`n` 的类型判断收敛到一次。
- **预期**：拷贝段从 O(n) 解释执行降为一次 memmove；单次块搬运的 CPU 常数级下降（量级需 profile 确认）。
- **代价**：无（`copyTo` 语义等价，需补一条「跨块 + 小缓冲」的等价性用例，`leftoverIsKeptForNextRead` 已覆盖）。
- **验证**：`cjprof record` 跑「读 1 GiB BLOB」场景，看 `DbdInputStream.read` 自耗时占比；或 `cjpm bench -O2` 前后对照 `read` 的 ns/byte。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每单元格重复归一化 `typeName`（可加类型名 → 读类型缓存）

- **现状**：`readData`（`types.cj:348-349`）每读一格都调 `readType(typeName)` → `resolve` → `trimAscii()` + `toAsciiLower()`（两次 `String` 分配）+ 最多 8 级判定。`typeName` 是每列常量，但调用频次是「行数 × 列数」（`fdbm/src/execute/cursor.cj:192` 每格一次）。
- **方案**：在 `SqlTypes` 内做 `typeName → SqlReadType` 的有界缓存（类型名种类有限，容量上限如 256 + 直接淘汰），或把归一化结果前移到 `ColumnInfoImpl`（列信息构建时算一次，`cursor.cj:100` 已在做 `canonicalName`）。
- **预期**：每格省 2 次 `String` 分配 + 一次多级字符串比较链；100 万格约省 200 万次短生命周期分配（GC 压力下降）。
- **代价**：共享缓存需并发安全（不可变 `HashMap` 快照或每线程缓存），否则引入锁竞争；类型名可能来自服务端，需带上限。
- **验证**：`cjprof record` 看 `SqlTypes.resolve` / `String.toAsciiLower` 在 `readData` 调用链上的自耗时占比；`cjpm bench -O2` 跑 10 万行 × 10 列读取。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `DbdUrl.percentEncode` 逐字节构造临时数组与十六进制字符串

- **现状**：`toUrl()` / `toUrlMasked()` 每次调用对 user、database 逐 `Rune` 处理：ASCII 分支每个字符新建 `[UInt8]` 数组（`DbdUrl.cj:244-248`），非 ASCII 分支每个 `Rune` 新建 `String` 再取字节；每个「非 unreserved」字节还要 `toHex(byte).toAsciiUpper()` 生成两个临时 `String`（`:255-258`）。输入规模 = 凭据/库名长度（典型 < 100 字节）；`getMetaData()` 每次调用都会触发（`DbdConnection.cj:85,88`）。
- **方案**：改为单遍写 `ArrayList<Byte>`：ASCII 直接 `out.add(UInt8(UInt32(b)))`，非 ASCII 用 `String([b]).unsafeBytes()` 只在该分支执行；十六进制用 `const HEX: Array<UInt8>` 直接写两位（`out.add(HEX[byte >> 4]); out.add(HEX[byte & 0xf])`），去掉 `toHex`/`toAsciiUpper` 与逐字符数组。
- **预期**：单次 `toUrl` 的临时对象从 O(字节数) 个降到 1 个 `ArrayList` + 1 个结果数组；凭据 40 字节时约省 40~80 次小对象分配（具体字节量待测，不作结论）。
- **代价**：无语义变化；需保证 `HEX` 表大写、`isUnreserved` 判定不变（现有 `DbdUrl_test` 往返用例可回归）。
- **验证**：`cjpm bench -O2`（同 SDK/机器，`toUrl` 1e6 次，取中位数与离散度）＋ `getAllocatedHeapSize()` 前后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `MultiDatasource.connect()` 每次借连接都走 `TreeMap.forward` + 闭包 + 轮询锁

- **现状**：每次 `connect()` → `LoadBalance.call` → `RoundRobin.next()` 取 `Mutex` 两次（`f_concurrent/src/LoadBalance.cj:35-49`）→ `TreeMap.forward` 分配迭代器 → 取闭包调 `pool.connect()`。桶数量 = 节点数（通常 2~8），单次成本很小，但这是每请求主路径。
- **方案**：`init` 后把「累计权重 → 池」展开成定长数组（大小 = `Σw`，或按最大公约数缩放），用 `AtomicInt64` 自增取模选下标；`roundrobin` 与 `random` 分别对应「自增取模」与「随机下标」，都不需要锁与树查找。只有权重和很大（如 1e6）时才需按节点数压缩成前缀和 + 二分。
- **预期**：借连接路径去掉 2 次 mutex 与 1 次迭代器分配；端到端收益取决于 `connect` 在请求中的占比（未知），只作为待验证项。
- **代价**：需保持「权重 0 不选中」「`Σw` 区间与现有语义一致」；必须保留现有测试口径（`MultiDatasource_test.cj` 的 67/33、100/0 用例）。
- **验证**：`cjpm bench -O2` 对 `borrowAndCount` 场景 1e5 次借还，对照中位数；`cjprof` 看 `RoundRobin.next`/`TreeMap.forward` 自耗时占比是否值得改。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MultiDatasource` 长期持有 `nodes: Array<DbdUrl>`（含明文口令），初始化后不再使用

- **现状**：`private let nodes`（`Datasource.cj:34`）在 `init` 中只用于建 `datasources`（`:47-51`）与权重校验（`:55`），之后无读取；它让 N 个 `DbdUrl`（每节点 user/password/host/database 字符串）随 datasource 生命周期常驻。`DbdDatasource` 已各自持有 `DbdUrl`，属重复引用，不增加字符串本体，只增加 1 个数组 + 指针。
- **方案**：把 `nodes` 改成 `init` 内局部变量（或直接遍历 `parsed.nodes`），不落字段；若诊断需要，另存脱敏后的 `Array<String>`（`toUrlMasked()`）。
- **预期**：每 datasource 省 1 个 `Array` 头 + N 个指针（N 通常 < 10，字节级），主要收益是减少明文口令的常驻副本（安全面）。
- **代价**：无行为变化；若后续要做「节点热替换/诊断输出」需重新引入，届时用脱敏串。
- **验证**：`getAllocatedHeapSize()` 前后对照；代码审查确认无其它读取点。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`；本表不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `decodeStrict` 恒 0 flag 是否已在端到端暴露（还是被 `populate` 同型早退掩盖） | `f_dbd/src/common/types.cj:54` | `UpdateResultPayload` / `DbdErrorPayload` 的 `decodeStrict` 往返用例结果 | 加两条 `@TestCase` 断言 `decodeStrict<UpdateResultPayload>(p.toData()).isSome()` 与 `decodeStrict<DbdErrorPayload>(p.toData()).getOrThrow().errorCode()==code`，跑 `cjpm test` |
| 2 | `SqlTypes.resolve` 是否为 `readData` 主路径的热点 | `f_dbd/src/common/types.cj:171-233,348-349` | 自耗时占比 + 分配量 | `cjprof record` 跑 10 万行 × 10 列查询，看 `resolve`/`toAsciiLower` 的 self time；`getAllocatedHeapSize()` 前后差值 |
| 3 | `DbdInputStream.read` 逐字节拷贝的实际占比 | `f_dbd/src/common/result.cj:431-434` | 单次 `read` 的 ns/byte 与整体占比 | `cjpm bench -O2` 读 1 GiB 流（分块 64 KiB、调用方缓冲 8 KiB）改前/改后对照，取 5 轮中位数 |
| 4 | 每行每列一次往返（无预读）使端到端延迟由 RTT 主导，`DbdConnection.request` 成为单位时间调用数最高的函数 | `f_dbd/src/driver/DbdConnection.cj:145-147`（经 `DbdStatement.query` / `QueryResultImpl.next` / `get`） | 请求数 / 行数比、单次 RTT、端到端 P95 | 对 1 万行 × 5 列的查询跑分段计时（`query` / `next` 循环 / `get` 循环），并统计 `transfer` 次数 |
| 5 | 连接池借出检查频繁调用 `isClosed()` → `state` 的 `Mutex`，在 32+ 并发借还下成为锁竞争点 | `f_dbd/src/driver/DbdConnection.cj:51-63,115-117` | `BLOCKED` 线程占比、锁等待时长 | 32 线程压 `PooledConnection` 借还 5 分钟，采集线程状态（CPU profile 看不出锁竞争） |
| 6 | `getMetaData()` 每次新建 `HashMap` 并做字符串拼接，被监控/上报按请求调用时可观 | `f_dbd/src/driver/DbdConnection.cj:81-91` | 调用频次、单次耗时与分配量 | 在 `getMetaData` 埋计数 + `getAllocatedHeapSize()` 对照，跑 10 分钟稳态 |
| 7 | `DbdTransaction` savepoint 名校验每次 `toRuneArray()` 分配，事务密集场景可优化为 `Byte` 扫描 | `f_dbd/src/driver/DbdTransaction.cj:136-147` | 每秒 savepoint 调用数、单次耗时 | `cjpm bench -O2` 对照 `save('sp1')` 100 万次 |
| 8 | 传输层每请求的 `Message` 编解码与 `PendingRequests` 锁是 CPU 热点 | `f_dbd/src/driver/DbdTransport.cj:60-67` | 自耗时占比、调用次数 | `cjprof record` 跑 10k 次 `request`（桩回 RESP），看 `Message.decode` / `encode` / `PendingRequests` self time |
| 9 | `roundrobin` 下 `RoundRobin.next` 的 mutex 在高并发借用时成为串行段 | `f_dbd/src/multid/Datasource.cj:114` → `f_concurrent/src/LoadBalance.cj:35-49` | 锁等待时长、BLOCKED 线程数 | 8 线程 × 1e5 次 `connect/close`，采线程状态＋`cjprof` 无法覆盖锁竞争，需另采 |
| 10 | `DbdUrl.percentEncode` 的分配在 `getMetaData()` 频繁调用场景下占比可观 | `f_dbd/src/driver/DbdUrl.cj:241-266` | 分配量 / 调用频次 | 在 `getMetaData` 外层加计数埋点，跑 10 分钟稳态，`getAllocatedHeapSize()` 差值 |
| 11 | 每个 `MultiStub` 的 `Server` 会创建 200 个 `Executor` 工作线程，且 `Server.close()` 不 `shutdown()`，测试进程线程数 / 常驻内存随桩数量线性增长 | `f_dbd/src/multid/stub_test.cj:38`；`f_net/src/server/server.cj:46,188-211` | 测试进程线程数、`getAllocatedHeapSize()` / RSS 随桩数量的曲线 | 在 `cjpm test` 前后读 `/proc/self/status` 的 `Threads` 与 `VmRSS`；或写一个只建/关 100 个 `MultiStub` 的用例，记录两轮数据 |

## 文件覆盖

> 清单口径：`reviews/202611280829_full/plan.json` 的 `f_dbd.file_count = 49`，仅含 `.cj`。49 个 `.cj` 由 part1–part4 全部读完，下表逐行对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbd/src/common/DbdException.cj` | .cj | ✅ | 构造器重复 `errorCode()`（轻微） |
| 2 | `f_dbd/src/common/DbdException_test.cj` | .cj | ✅ | 7 个用例覆盖继承 / code / sqlState / cause / payload 还原 |
| 3 | `f_dbd/src/common/ReadChunkReuse_test.cj` | .cj | ✅ | 缓冲复用回归；`benchToEnd` 有 `F_DBD_BENCH` 门禁 |
| 4 | `f_dbd/src/common/column.cj` | .cj | ✅ | 6 短名数据字段 + 6 个 `@DataExclude[field]` 只读属性，形态与注释一致 |
| 5 | `f_dbd/src/common/column_test.cj` | .cj | ✅ | 钉住线上键集合恰为 6 个短名，覆盖严格解码 |
| 6 | `f_dbd/src/common/dispatch_perf_test.cj` | .cj | ✅ | 复制生产分派 + 无 bench 门禁（轻微） |
| 7 | `f_dbd/src/common/error.cj` | .cj | ✅ | `DbdErrorCode` 三份 16 分支表（轻微） |
| 8 | `f_dbd/src/common/error_test.cj` | .cj | ✅ | 码值表 / `toString` / 兜底 / 往返，覆盖充分 |
| 9 | `f_dbd/src/common/payload.cj` | .cj | ✅ | 载荷键集合与严格解码；形态与注释一致 |
| 10 | `f_dbd/src/common/payload_test.cj` | .cj | ✅ | 键集合红线 + 严格解码 + 常量断言，覆盖充分 |
| 11 | `f_dbd/src/common/placeholder.cj` | .cj | ✅ | 无任何声明的空占位，注释与内容不符（轻微，与另两份 placeholder 合并） |
| 12 | `f_dbd/src/common/result.cj` | .cj | ✅ | `next()` 失败不复位（一般）、线程封闭缺失（一般）、`next(values)` 忽略参数（轻微）；优化 1 条 |
| 13 | `f_dbd/src/common/result_test.cj` | .cj | ✅ | 状态机 / 流列 / 关闭握手覆盖良好；`codeOf` 语义问题（轻微） |
| 14 | `f_dbd/src/common/sqltypes_test.cj` | .cj | ✅ | 归一化用例缺 `int(n)`；过期注释（轻微） |
| 15 | `f_dbd/src/common/types.cj` | .cj | ✅ | 严格 flag（严重）、流列整块物化（一般）、`INT(n)` 归一（一般）、WARN 放大（一般）；优化 2 条 |
| 16 | `f_dbd/src/common/types_matrix_test.cj` | .cj | ✅ | `toString()` 比较 / 不释放 / 依赖全局 `MOCKDB`（轻微） |
| 17 | `f_dbd/src/common/types_test.cj` | .cj | ✅ | `decodeStrict` 正反例，覆盖到位 |
| 18 | `f_dbd/src/dbd.cj` | .cj | ✅ | 根包重导出 + 版本入口，无逻辑 |
| 19 | `f_dbd/src/dbd_test.cj` | .cj | ✅ | 重导出的编译期验证 |
| 20 | `f_dbd/src/driver/DbdConnection.cj` | .cj | ✅ | 结果集独占竞态（严重）、事务互斥缺失（一般）、关闭 6h（一般）、关闭边界（一般） |
| 21 | `f_dbd/src/driver/DbdConnection_test.cj` | .cj | ✅ | 状态机 / 独占闸门 / 关闭握手；独占用例只覆盖顺序复用 |
| 22 | `f_dbd/src/driver/DbdDatasource.cj` | .cj | ✅ | `setOption` 与 `connect` 选项竞态（一般） |
| 23 | `f_dbd/src/driver/DbdDriver.cj` | .cj | ✅ | `dbdDriver()` 注释反 + 补注册 check-then-act（一般） |
| 24 | `f_dbd/src/driver/DbdDriver_test.cj` | .cj | ✅ | 通配 + 具名重复 import（轻微） |
| 25 | `f_dbd/src/driver/DbdOptions.cj` | .cj | ✅ | `?Duration` 解析与「非法值保留原值」自洽；同名 `timeoutOf` 语义（轻微） |
| 26 | `f_dbd/src/driver/DbdStatement.cj` | .cj | ✅ | 独占竞态（严重）、参数 index 无上界（一般）、关闭 6h（一般）、关闭边界（一般）、`timeoutOf` 重复 / 未使用 import（轻微） |
| 27 | `f_dbd/src/driver/DbdStatement_test.cj` | .cj | ✅ | 参数顺序 / 空洞 / deprecated 重载 / 流列，覆盖较全 |
| 28 | `f_dbd/src/driver/DbdTestSetup_test.cj` | .cj | ✅ | 顶层 `let` 以初始化副作用写配置；与 multid 同名文件重复（轻微） |
| 29 | `f_dbd/src/driver/DbdTransaction.cj` | .cj | ✅ | 事务互斥缺失（一般）、三属性静默无效（一般）、`timeoutOf` 重复（轻微） |
| 30 | `f_dbd/src/driver/DbdTransaction_test.cj` | .cj | ✅ | 状态机 / savepoint 注入 / 结果集互斥；把「属性只记录」固化成断言 |
| 31 | `f_dbd/src/driver/DbdTransport.cj` | .cj | ✅ | 异常穿透不拆链（一般）、关闭 6h 的超时来源（一般）、命令校验三份（轻微） |
| 32 | `f_dbd/src/driver/DbdTransport_test.cj` | .cj | ✅ | 覆盖 RESP/ERROR/PROTOCOL/TIMEOUT/ACK；未覆盖 transfer 抛异常 |
| 33 | `f_dbd/src/driver/DbdUrl.cj` | .cj | ✅ | 凭据进异常消息（一般）、`database` 口径（轻微）、`toUrl*` 重复（轻微） |
| 34 | `f_dbd/src/driver/DbdUrl_test.cj` | .cj | ✅ | 覆盖 IPv6、非 ASCII、`%` 往返、脱敏；`?` 查询参数丢失未测 |
| 35 | `f_dbd/src/driver/PayloadWrapping_test.cj` | .cj | ✅ | 等价性 + 可选分配基准；未使用 import、复制生产实现（轻微） |
| 36 | `f_dbd/src/driver/placeholder.cj` | .cj | ✅ | 仅包级注释，内容过期（轻微，合并） |
| 37 | `f_dbd/src/driver/stub_fdbm_test.cj` | .cj | ✅ | f_net Server 桩；死方法 + `freePort` TOCTOU（轻微，合并） |
| 38 | `f_dbd/src/driver/testkit_test.cj` | .cj | ✅ | `codeOf`/`messageOf`/`waitUntil`；跨包重复（轻微） |
| 39 | `f_dbd/src/exception/DbdException.cj` | .cj | ✅ | 单行 `public import` 重导出，与注释一致；无问题 |
| 40 | `f_dbd/src/exception/Reexport_test.cj` | .cj | ✅ | 重导出验收；`typeIdentity` 空动作（轻微） |
| 41 | `f_dbd/src/multid/Config.cj` | .cj | ✅ | `MaxWaiting` 语义（一般，合并）、数值无范围校验（轻微）、注释漂移（轻微） |
| 42 | `f_dbd/src/multid/Datasource.cj` | .cj | ✅ | `MaxWaiting` 不生效（一般）、异常映射过窄（一般）、零权重建池（轻微）、TIMEOUT 归并（轻微） |
| 43 | `f_dbd/src/multid/MultiD.cj` | .cj | ✅ | 驱动注册与 open；无独立问题 |
| 44 | `f_dbd/src/multid/MultiDTestSetup_test.cj` | .cj | ✅ | 协议 hostId 测试前置；与 driver 同名文件逐字重复（轻微） |
| 45 | `f_dbd/src/multid/MultiD_test.cj` | .cj | ✅ | 配置 / URL / 驱动用例；`codeOf` 重复、`Config` 残留（轻微） |
| 46 | `f_dbd/src/multid/MultiDatasource_test.cj` | .cj | ✅ | 67/33、100/0、随机容差、非法权重/算法、池耗尽；同值配置掩盖 `MaxWaiting`、`Config` 无隔离（合并） |
| 47 | `f_dbd/src/multid/Url.cj` | .cj | ✅ | 凭据进异常消息（合并至一般）、`database` 口径（轻微）、`nodes.isEmpty` 死分支（轻微） |
| 48 | `f_dbd/src/multid/placeholder.cj` | .cj | ✅ | 仅包级注释，内容过期（轻微，合并） |
| 49 | `f_dbd/src/multid/stub_test.cj` | .cj | ✅ | `MultiStub` 统计/响应语义不符（轻微）、`freePortOf` 重复（轻微，合并） |

合计：`.cj` 49 个 / `.md` 0 个（清单口径）/ 共 49 个，全部读完。

> 文档侧说明：模块内另有 20 个 `.md`（`README.md`、`README_en.md`、`doc/开发计划.md`、`doc/详细设计.md` 及 4 组 `doc/spec/**`），不在 `plan.json` 的 49 个 `.cj` 清单内。part2/3/4 已按需交叉核对 `README.md:5,17,25,104,142,165`、`doc/详细设计.md:740,773`；本报告 §13 的结论只覆盖这些被引用位置，未逐篇通读全部 `.md`，下轮补全。

## 覆盖自检

> 命中数按「各部分自检之和 − 跨部分重复」计，重复项已在上文合并；同一条发现可能同时支撑多个维度，维度间不互相抵扣。待验证假设 11 条不计入。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 19 | 四部分合计 20，扣除 `database` 口径跨部分重复 1 条；正确性集中在严格 flag、行状态、类型归一化、事务与关闭边界；设计问题是「不变量只覆盖顺序路径」与两套异常契约；语言特性未发现误用；安全性命中 1 条（URL 异常消息带明文口令） |
| §1 死代码 | 6 | 已逐个 private / internal / protected / 非公共顶级声明内 public 成员搜引用：`resolveDialect` 4 个不可达 case、`resolveUnsigned` 分支不可达（part1 记 2 项）、`StubFdbm.consumes/clear` 与未使用 import（1 项）、`MultiDUrl.parse` 的 `nodes.isEmpty()`（1 项）、`multid/placeholder.cj` 无声明（1 项）、`common/placeholder.cj` 空文件（1 项）。对外可达的 public 声明未判死代码 |
| §2 重复逻辑 | 8 | 四部分合计 9，扣除 `database` 首段规则跨部分重复 1 条；其余为 `DbdErrorCode` 三表、`SqlReadType.toString/of`、`?Duration` 兜底、命令校验三份、`codeOf` 三份、`legacySqlPayloadOf`/`toUrl*`/setup 行、`freePort` 两份、`INT(n)` 两张表不一致 |
| §3 空实现 | 3 | `next(values)` 忽略参数、三份 `placeholder.cj` 空 / 过期说明、`Reexport_test` 的 `catch { () }`；`QueryResultImpl.close()` 吞异常是设计文档明确要求，不计 |
| §4 栈溢出 | 0 | 49 个 `.cj` 内无递归调用；`resolve` 的辅助函数是单向链（`resolve`→`resolveSqlName`/`resolveCangjieName`/`resolveDialect`/`parenBaseOf`），无环；`DbdUrl` / `MultiDatasource` / `DbdTransport` 均为单层循环；无自引用结构遍历 |
| §5 OOM | 2 | `readData` 流列整块物化（一般，已量化 V×2 + 64 KiB，无上限）；`sqlPayloadOf` 按不可信 index 逐位补 NULL（一般）。其余容器（`streams_` / `nullStreams_` / `params` / `cells`）都是每行/每语句作用域，无全局无界集合 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench（`scope.md`「已有性能资料」为空）；`resolve`、`DbdInputStream.read`、`request` 编解码、`RoundRobin` 锁、`getMetaData` 分配等只能是线索，已全部列入「待验证假设」1–11，不写成热点结论 |
| §6.2 大粒度锁 | 0 | 四部分无「大临界区」：`DbdConnection` 的互斥区只读写 `closed` / `activeResult`，网络 I/O 在锁外；`RoundRobin` 的 mutex 只包自增。`结果集独占`是复合操作未原子化（见严重第 2 条），不是粒度问题 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get`、无线程池、无任务窗口；一条连接天然串行是协议约束（`QueryResultColumnPayload` 无结果标识），不是可优化的串行段 |
| §6.4 低效算法 | 2 | `readChunk` 每调用恒定 64 KiB 分配 + 两次搬运；`resolve` 每格两次字符串分配 + 多级前缀比较（均见优化方案）。`medianOf` 对 5 元素冒泡代价可忽略，不提 |
| §7 降堆内存方案 | 2 | 优化方案「`readChunk` 缓冲 / 终态复制」「`MultiDatasource.nodes` 常驻凭据副本」（均无基线）；零权重节点建池归 §11 缺陷，不重复计方案 |
| §8 降 CPU 方案 | 4 | 优化方案「`DbdInputStream.read` 整段拷贝」「类型名缓存」「`percentEncode` 单遍写」「借连接路径去锁与树查找」（均无基线）；WARN 放大归 §6.4 / 一般发现 |
| §9 local mode 可行性 | 0 | 候选只有 `resolve` 的 `trimAscii()`/`toAsciiLower()` 临时串、`readChunk` 单块缓冲、URL 解析临时串；前者是 std `String` 无 mode 重载，后者生命周期跨 `stream.read` / 结果逃逸给 `MultiDatasource`；无峰值内存对照，收益无法证明，判不可行 |
| §11 现有代码的 BUG（存量） | 27 | 四部分合计 30，扣除 `MaxWaiting`、`database` 口径、`freePort` 三处跨部分重复各 1 条；覆盖错误处理、边界 / 空值、资源释放、状态机、契约不符。已核对未列为缺陷的边界：`readChunk` 的 `want>=1`、`ensureReadable` 的 index 上下界、`DbdInputStream.read` 的 `n=min(buffer, remaining)`、`sqlPayloadOf` 空参数集 `max=-1` 不进循环、`DbdTransaction.check` 先判空串 |
| §12 并发安全与锁粒度 | 7 | 共享路径逐条列：`DbdConnection.activeResult`（检查与登记跨 RTT）、`closed` 与 `registerResult`（关闭竞态）、`DbdDatasource.options`（裸 `var`）、连接级事务状态（缺失）、`QueryResultImpl`/`DbdInputStream`（无同步且未声明线程封闭）、`MultiDatasource.connect` 异常映射（`RoundRobin` 竞态触发）、测试全局 `Config`（顺序依赖）。锁粒度本身合理 |
| §14 功能完备性与 README 覆盖 | 3 | 四部分合计 4，扣除 `MaxWaiting` 测试项与 part3 重复 1 条；命中 `next(values)` 契约未履行、`MaxWaiting` 接线缺失、README 公开 API 清单 / `DbdDatasource` 签名错误。其余 public 声明在 README 均有段落；未发现「承诺但未接线」的其它功能 |
| 文件覆盖（§13 等） | 49/49 | 49 个 `.cj` 全部读完；`§13` 命中 3 条（README 公开 API、README 签名、设计文档 `init` 签名 / `getMaxWaiting` 注释）。模块 20 个 `.md` 未列入 `plan.json` 清单，只交叉核对被引用行，未逐篇通读——这是本轮唯一的覆盖缺口，见「文件覆盖」说明 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 17 |
| 轻微 | 23 |
| 优化方案（堆内存 / CPU） | 2 / 4 |

> 合并前各部分合计：严重 2 / 一般 17 / 轻微 28。轻微去重 5 条后为 23：`placeholder` 3→2（与文档漂移拆分）、`freePort` 2→1、`database` 口径 2→1、`MaxWaiting` 2→1、死代码 / 未使用 import 2→1。优化方案 6 条全部 `无基线（待验证）`，不进 `tasks.md`。待验证假设 11 条，不计入本表。

> 存量缺陷共 43 条（严重 2 / 一般 17 / 轻微 23），是否纳入修复待用户决定。

## 总评

f_dbd 的整体结构是清楚的：`common` 的载荷 / 列 / 结果集用「短名数据字段 + `@DataExclude[field]` 只读属性」并配了钉住线上键集合的回归用例；驱动层把「连接持有传输与结果集闸门、语句只收集参数、事务只发会话控制」分得很干净，锁的临界区刻意只包字段读写、把网络 I/O 留在锁外；`DbdUrl` 的 IPv6 / `%` 往返 / 非 ASCII / 端口范围覆盖完整；`multid` 用真实 `Server<DataAny>` 桩把 67/33、100/0 钉成确定性用例。这些是本文档里质量偏上的部分。

**阻塞项候选有两条**：

1. `decodeStrict` 的严格 flag 在 `f_data` 改 `DEFAULT_DATA_FLAG` 后退化为 0，而函数注释自己就写着「flag 0 解不出整数字段」。一旦端到端成立，`update()` / `query()` / `ERROR` 三条主路径同时失效。先补两条往返用例确认，成本极低。
2. 结果集独占是「检查 → 发包 → 登记」三段式，锁只保护中间空档，并发 `query()` 可让两个游标共存并静默错位行数据。这是本模块唯一的并发正确性阻塞项，修法是把闸门改成 acquire 占位。

**应优先排期的契约缺口**：`DbdUrl` 解析失败把明文口令写进异常消息（安全面，与 `toUrlMasked()` 的初衷相反）；关闭连接复用 `query_timeout`，未配置时最长阻塞 6 小时；事务三属性静默无效；连接级事务互斥完全缺失；`MaxWaiting` 在 multid 路径完全不生效且被测试同值配置掩盖；`DbdTransport` 让 f_net 异常以非 `DbdException` 穿透且不拆链。

**可排期的正确性 / 边界问题**：`readData` 流列整块物化无上限、`INT(n)` 归一成 `String`、参数 index 无上界、关闭状态边界不完整、`dbdDriver()` 的异常面与注释相反、`MultiDatasource.connect` 的异常映射过窄、节点不可达与池耗尽都报 `TIMEOUT`。

**可维护性**：三份 `placeholder.cj`、`codeOf` 三份、`freePort` 两份、`DbdErrorCode` 三表、命令校验三份、README 公开 API / 示例签名错误等，改动小但直接影响契约可信度，建议与上述修复同批处理。

性能方面本轮没有任何 profile / bench 数据，六个优化方向（`readChunk` 缓冲、流列整段拷贝、类型名缓存、`percentEncode`、借连接路径、`nodes` 常驻凭据）全部只作为「待验证假设」或 `无基线` 方案，不进修复清单；下一轮应先补 `cjprof` / `cjpm bench` 基线再决定是否落地。
