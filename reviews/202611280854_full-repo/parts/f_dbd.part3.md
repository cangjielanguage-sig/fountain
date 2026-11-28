# f_dbd 模块审查报告

> **模块第 3/5 部分**（本报告只覆盖 `files/f_dbd.part3.txt` 列出的 20 个文件，全部为 `src/common` 与 `src/driver` 下的 `.cj`：`dispatch_perf_test` → `DbdOptions`。模块共 49 个 `.cj` + 20 个 `.md`，`README*.md` / `doc/**` 及其余 29 个 `.cj` 由第 1、2、4、5 部分产出；本部分编号独立，合并时以主 Agent 为准。`.md` 只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（本部分 20 个 `.cj`，0 个 `.md`；模块共 49 `.cj` + 20 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：数据库驱动协议正确性（`QueryResultColumnPayload` 的 `NEXT_ROW` / `CELL` / NULL 探测语义）、类型映射（`SqlTypes.resolve` 归一表）、资源与连接生命周期（`DbdConnection` / `DbdDatasource` / `DbdInputStream`）、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 3/5 部分）

## 发现

### [一般][存量] #1 类型归一表缺 `int(…)` 与 `real`：MySQL / PG 的常见数值列被降级成 `String`

- **位置**：`f_dbd/src/common/types.cj:250-256`（`PAREN_BASES` 里只有 `integer`、没有 `int`）、`f_dbd/src/common/types.cj:320-345`（`resolveDialect` 有 `float4`/`float`、没有 `real`）、`f_dbd/src/common/types.cj:213-227`（去括号后缀的重试分支）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`，`af3ca77d8` 只改了 `readChunk`，未动归一表）
- **判据**：review-checklist §11「契约与实现不符 / 语义与命名不符」、§10 正确性（类型映射）；fountain-baseline §2「驱动上报的就是仓颉类型名」
- **证据**：静态确定 —— 按 `resolve()`（`types.cj:171-233`）的判定顺序逐条走一遍：
  1. `'int(11)'`：`resolveCangjieName('int(11)')` 无命中 → `resolveDialect('int(11)')` 无命中 → `key.contains('(')` 分支调 `parenBaseOf('int(11)')`，`PAREN_BASES` 里 `'integer'`、`'mediumint'`、`'bigint'`、`'tinyint'`、`'smallint'` 都不是 `'int(11)'` 的前缀，`'int'` 根本不在表里 ⇒ 返回 `None`；
  2. `'int(11) unsigned'`：`resolveUnsigned('int(11)')` 无命中 → `parenBaseOf('int(11)')` 同上无命中 → 仍 `None`；
  3. `'real'`：`resolveCangjieName` / `resolveDialect` 都没有该拼写（表里只有 `'float4' | 'float'`）⇒ `None`。
  三条都落到 `SqlTypes.readType` 的 `Unknown`，`canonicalName` 则命中 `types.cj:158-161` 的兜底 `'String'` 并打一条 WARN。
- **描述**：MySQL 8.0.19 之前与 MariaDB 的列定义常带显示宽度（`int(11)`），驱动把 `ColumnInfo.typeName` 报成该拼写时即命中本条（具体驱动是否保留宽度需按驱动版本实测；但无论宽度是多少，归一表缺 `int` 都落到同一结果）；PostgreSQL 的 `real` 是核心类型，属表项缺漏。这两类列现在会被上报成 `String`：`fdbm` 的 `QueryCursor` 把它当文本格读（`SqlTypes.readData` 的 `Unknown` 分支 → `cellOf<String>`，`types.cj:370-372`），`ColumnInfo.typeName` 传给客户端也是 `'String'`。数据本身还能靠 `DataString → Int64` 的宽松转换读出来（`CELL_READ_FLAG` 含 `THROWING_ON_INT_OVERFLOW`），所以**不会报错、只会类型漂移**：`f_orm` / 业务侧按 `String` 拿到的数值列会走字符串比较与字符串排序（`'10' < '9'`），且每次读格都多打一条 WARN。仓内测试只覆盖了 `varchar(64)` / `decimal(10,2)` / `TINYINT(1)`（`sqltypes_test.cj:105-109`），`int(11)` 与 `real` 没有任何用例。
- **建议**：`PAREN_BASES` 在 `'integer'` 之后补 `'int'`（顺序不能放在 `'integer'` 之前，否则 `integer(11)` 会先命中 `'int'` 而少一次精确匹配；两者都映射 `Int32`，放后面最安全），`resolveDialect` 在 `'float4' | 'float'` 一行补 `'real'`；再在 `sqltypes_test` 加 `readType('int(11)') == I32`、`canonicalName('real') == 'Float32'`、`canonicalName('int(11) unsigned') == 'UInt32'` 三条回归。

### [一般][存量] #2 `decodeStrict` 的 flag 恒为 `0`，与紧邻注释的结论正好相反；"严格解码"对同型载荷不做任何字段级校验

- **位置**：`f_dbd/src/common/types.cj:52-58`（`convert<T>(data, flag: DEFAULT_DATA_FLAG & !SILENCE)`）与 `types.cj:43-51` 的注释；对照 `f_data/src/base/global_objects.cj:51`（`DEFAULT_DATA_FLAG = SILENCE`）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`；`f_data` 侧把 `DEFAULT_DATA_FLAG` 从 `WRAPPING_ON_INT_OVERFLOW | SILENCE` 改成 `SILENCE` 是 `f8b45cccde 2026-10-15`，本行写于其后）
- **判据**：review-checklist §11「语义与注释不符 / 错误处理缺失」、§3「静默吞异常」、§10 正确性
- **证据**：静态确定（flag 取值）+ 待确认（真实影响面）——
  - `DEFAULT_DATA_FLAG` 的值就是 `SILENCE`（`f_data/src/base/global_objects.cj:42-51`），而 `!` 在整数上是**按位求反**（`cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md:265`、`Appendix/operator.md:14`），所以 `SILENCE & !SILENCE == 0`；注释 `types.cj:49-50` 自己写着"**为什么不能取 `flag: 0`**：…`flag: 0` 时所有含整数字段的载荷都解不出来"，代码算出来的正是这个被禁止的值。
  - 现状没有炸，靠的是 `f_data` 的**类型快路径**：`DataObject<T>.populate(src, flag)` 在 `src` 运行时类型恰好是 `DataObject<T>` 时直接 `return d.data`（`f_data/src/base/DataObject.cj:208-213`），字段级转换整段被跳过。于是 `decodeStrict` 对"类型恰好对得上"的载荷（`types_test.cj:28-38`、`DbdTransport_test.cj:58` 全部属于这一类：服务端编过该类型 ⇒ 本进程 `typeMurmurCreators` 里登记的就是 `DataObject<T>` 的 creator，见 `f_codec/src/default/DefaultCodec.cj:88-95`、`963-985`）等于**原样返回，没有做任何"字段缺失 / 类型不匹配 / 无法转换"的校验**——注释承诺的严格性并不存在。
  - 反过来，一旦输入不是 `DataObject<T>`（`DataAny` 之外的包装、自定义 `SimpleDataObject` 实现、`DataCollection` 里的同形元素等），`populate` 会走逐字段 `set(..., flag: 0)`；而此时 `Int64.tryFromData(DataReal, 0)` 落到 `f_data/src/base/NumberData.cj:252-253` 的 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(...)` ⇒ **任何含整数字段的载荷必然解不出**，被 `decodeStrict` 吞成 `None`。调用方拿到 `None` 后走的是 `PROTOCOL` / `CONVERSION` 分支（`DbdTransport.cj:126-131`、`DbdStatement.cj:86-90`），错误码与 `sqlState` 全部丢失。
- **描述**：这条是"注释写的与代码算的不一致"，属于潜伏型：今天能跑是因为快路径遮住了，任何一次把载荷改成非 `DataObject<T>` 形态（例如统一包一层 `DataAny`、或换用自定义 `SimpleDataObject` 实现）都会让所有带 `Int64` 字段的载荷（`QueryResultColumnPayload.index/bufSize`、`UpdateResultPayload.rc/liid`、`DbdErrorPayload.code`）一次性变成解不出。
- **建议**：把 flag 显式写成策略位，例如 `convert<T>(data, flag: THROWING_ON_INT_OVERFLOW)`（`types.cj:40` 的 `CELL_READ_FLAG` 已示范该位；严格语义要求**不带**任何 `IGNORE_*`，所以不能直接复用 `CELL_READ_FLAG`）。同时在 `types_test` 补一条"字段缺失 / 类型不符的非同型对象 → `None`、字段齐全的同型对象 → `Some`"的用例，把两条路径都钉死；并把注释改成"flag 必须显式带一个溢出策略位"。

### [一般][存量] #3 `DbdConnection.close()` 与 `registerResult()` 缺状态互斥：并发下新游标会脱离登记、永不关闭

- **位置**：`f_dbd/src/driver/DbdConnection.cj:97-113`（`close()`）、`DbdConnection.cj:137-142`（`registerResult()`）、`DbdConnection.cj:124-135`（`ensureNoOpenResult()` 不检查 `closed`）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 跨线程资源」、§11「资源不对称」；`fountain-baseline` 无相反约定
- **证据**：静态确定（代码路径确定）／触发需并发（需实测）——`activeResult` 只在 `Mutex` 内读写，但 `close()` 把"置 `closed`、取 `activeResult`"和"把 `activeResult` 清空"拆成了两个临界区（`98-101` 与 `109-111`），中间夹着 `r.close()` 的阻塞 I/O。于是存在这条交错：线程 A 进入 `close()`，锁内置 `closed = true` 并取走 `pending`，随后在锁外等 `UNSUBSCRIBE` 的 ACK；线程 B 的 `DbdStatement.query()` 此时没有被拦住（`ensureNoOpenResult` 只判 `activeResult`，不判 `closed`），发完 SQL、拿到首包后调 `registerResult`（`DbdStatement.cj:96`）把新结果集写进 `activeResult`；A 回来后执行 `activeResult = None`（`110`）——新结果集既不在连接上登记，也不会再被任何 `close()` 关闭：服务端游标（`qid`）与本地 `streams_` 句柄一直留到 `DbdConnection` 被 GC，而 `transport.close()` 已在其后执行，该结果集后续 `next/get` 只会拿到 `IO`。
- **描述**：`DbdConnection` 自带 `Mutex`（`40`），说明作者按"会被多线程调用"设计（`f_dbpool` 池化后连接会在不同请求线程间传递），因此这条交错不是纯理论。同类次级问题：`ensureNoOpenResult` 与 `prepareStatement` / `createTransaction` 在 `closed == true` 之后仍放行，调用方看到的是 `IO`（transport 已关）而不是明确的"连接已关闭"状态错误。
- **建议**：把 `closed` 纳入两处闸门——`registerResult` 在锁内 `if (closed) throw DbdException(CURSOR_STATE, ...)`，`ensureNoOpenResult`（及 `prepareStatement`）同样先判 `closed`；`close()` 改成"锁内取走 `pending` 并把 `activeResult` 立刻置 `None`"，`r.close()` 仍在锁外做，避免第二次临界区覆盖新登记。补一条并发用例：一个线程反复 `close()`、另一个线程反复 `prepareStatement(...).query()`，断言"凡是 `query()` 返回的结果集，最终都 `isClosed()`"。

### [一般][存量] #4 `SqlTypes.readData` 的流列分支整块物化 LOB，没有长度上限

- **位置**：`f_dbd/src/common/types.cj:368`（`case SqlReadType.Stream => readChunk(readStream(result, index), 0).toData()`）、`types.cj:405-422`（`readChunk` 的 `size <= 0` 语义 = 读至 EOF）
- **来源**：存量（`git blame`：`eda252b8f 2026-10-16` 引入"流列整读"，`af3ca77d8` 改成复用缓冲）
- **判据**：review-checklist §5「一次性物化 / 无拒绝路径」、§11「资源与边界」
- **证据**：静态确定（无任何上限判断）+ 需实测（真实 LOB 长度分布）——`readChunk(..., 0)` 的循环条件是 `while (toEnd || got < size)`，`toEnd` 恒真时只有"流返回 0"才退出，途中 `out.add(all: buf[0..n])` 把每一块追加进 `ArrayList<Byte>`，直到 `toArray()` 再整体复制一次。
- **描述**：`fdbm` 的正常游标路径已按块读流（`fdbm/src/execute/cursor.cj:169-187`），所以这条分支只在"把流列直接交给 `readData`"的调用点生效：`fdbm/src/execute/executors.cj:404` / `636` / `1051` 都传 `query.columnInfos[0].typeName` 或 `typeName`，命中 `std.io.InputStream` 列时会先读至 EOF 再 `toData()`。峰值内存 ≈ `n（LOB 字节数） + 64 KiB`，`ArrayList` 扩容期间另有 1.5–2× 的旧数组暂存，最坏到 2–3 n；没有 size 上限、没有拒绝路径、也没有可配置的阈值。一个 1 GiB 的 `bytea` 列（或攻击者可控的大对象）会直接把进程堆顶到 2–3 GiB。
- **建议**：`readData` 的 `Stream` 分支加一个显式上限（常量或配置，例如 `maxLobBytes`），超限抛 `DbdException(CONVERSION, 'LOB of column ... exceeds ...')`——比 OOM 崩溃可诊断得多；需要全量内容的场景由调用方改用 `readStream(result, index)` 自己分块。同时在 `SqlTypes` 的文档注释里写清"该分支会整块物化"，避免下一个调用方误以为它是流式。

### [轻微][存量] #5 流列字节解码的两段 `try/catch` 重复，差异只有错误文案前缀

- **位置**：`f_dbd/src/common/result.cj:326-338`（`openStreamAsAny` 的探测解码）、`result.cj:362-377`（`requestBlock` 的块解码）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2「只改字面量 / 同输入-输出-副作用」
- **证据**：静态确定 —— 两段结构逐行对齐：`try { match (SqlTypes.decode<Array<Byte>>(x)) { case Some(b) => b; case None => throw DbdException(CONVERSION, '<前缀> is not a byte array') } }` + `catch (DataException)` / `catch (OverflowException)` / `catch (Exception)` 三个包装分支，异常码统一 `CONVERSION`；唯一差异是 `'stream probe of column'` 与 `'stream block of column'` 两个前缀，以及 `requestBlock` 多一个 `DataNone → 空数组` 的前置判断。
- **描述**：两处的 `DataException` / `OverflowException` / `Exception` 分支文案也不同（一处合并写、一处分开写），后续想统一错误格式时容易只改一处，形成行为漂移。
- **建议**：抽成 `private static func bytesOf(data: Data, what: String, index: Int64): Array<Byte>`（内部统一三个 catch），两处只传 `what`；`DataNone` 的短路留在 `requestBlock` 里。

### [轻微][存量] #6 自己抛出的 `DbdException` 被同层 `catch (e: Exception)` 再包一层，消息重复

- **位置**：`f_dbd/src/common/result.cj:329-331` → `335-338`；`result.cj:365-367` → `374-377`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11「错误处理」、§10 正确性（异常链）
- **证据**：静态确定 —— `case None => throw DbdException(CONVERSION, '... is not a byte array')` 写在 `try` 块内，同一 `try` 的 `catch (e: Exception)` 会接住它并重新抛 `DbdException(CONVERSION, '... is not a byte array: ${e.message}', cause: e)`。
- **描述**：最终错误文案变成 `... is not a byte array: DbdException: ... is not a byte array`，`cause` 指向自己刚造的那个异常；排查时容易误以为有两层失败。严重度低（码值仍是 `CONVERSION`），但异常链是给使用者看的对外契约。
- **建议**：在 `catch (e: Exception)` 之前加 `catch (e: DbdException) { throw e }`，或把 `None` 分支移到 `try` 外先判掉。

### [轻微][存量] #7 `DbdOptions.apply` 三个超时 key 的分支逐行重复

- **位置**：`f_dbd/src/driver/DbdOptions.cj:57-71`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2「只改字段名」
- **证据**：静态确定 —— `ConnectionTimeout` / `QueryTimeout` / `UpdateTimeout` 三块各 5 行，`timeoutOf` 调用与 `case None => ()` 的注释（只有第一块写了注释）完全同构，只有赋值目标字段不同。
- **描述**：加第四个超时（例如 `transaction_timeout`）必须再抄一遍；`None => ()` 的"保留原值"注释只在第一块出现，另两块靠读者推断。
- **建议**：`match (key)` 先选出一个 setter 闭包（或返回 `?DbdOptions -> ?Duration` 的写入口），再统一 `match (timeoutOf(key, value))`，注释只写一次。

### [轻微][存量] #8 `dispatch_perf_test` 默认就跑约 4.8×10^8 次分派，没有像同包基准那样做开关门控

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:47-51`（`WARMUP = 10_000` / `LOOPS = 1_000_000` / `ROUNDS = 5`）、`dispatch_perf_test.cj:60-116`（19 个类型 × 4 组合 + 5 个未命中探针 × 4 组合）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §10 可维护性（测试成本）、§14.1「半成品/接线」的邻居约定
- **证据**：静态确定 —— 计算量 = (19 + 5) × 4 × (10^4 + 5 × 10^6) ≈ 4.8×10^8 次分派调用，全部走 `println` 输出；而同包 `ReadChunkReuse_test.cj:76-91` 的 `benchToEnd` 用 `F_DBD_BENCH == 1` 门控（`benchEnabled()`，`101-106`），只有显式打开才跑。
- **描述**：`cjpm test` 默认会执行本类，把一次普通回归变成数秒到数十秒的基准跑，且输出大量表格；CI 上它与功能用例混在一起，失败时难以区分"用例错"与"机器噪声"。
- **建议**：沿用 `F_DBD_BENCH` 门控（或 `@Configure` + `@Skip`）：未开启时只跑 `semanticDifferenceOnInterfaceImplementor` 与 `nullShortCircuit` 这两个语义断言，性能矩阵在开启时才跑。

### [轻微][存量] #9 测试里存在完全同体的用例与同体的桩助手

- **位置**：`f_dbd/src/common/result_test.cj:441-450` 与 `result_test.cj:454-463`（`emptyBlobIsSomeEmptyStream` / `probeIsBackwardCompatibleWithOldServer`）；`f_dbd/src/common/types_matrix_test.cj:198-209`（`matrixResult`）与 `f_dbd/src/common/sqltypes_test.cj:332-343`（`mockResult`）
- **来源**：存量（`ef7b9b06ee` / `eda252b8f`）
- **判据**：review-checklist §2「同输入-输出-副作用」
- **证据**：静态确定 —— 两个用例的准备、断言、顺序完全一致（`addBlock([])` → `getOrNull<InputStream>` → `isSome` → `read` 为 0）；两个助手函数体逐行一致（`MOCKDB.clear()` / `MOCKDB.execution = {...}` / `toThrowOnExecuting = false` / `prepareStatement` / `query` / `next`），只有函数名不同，且同属 `fountain::f_dbd.common` 包。
- **描述**：`probeIsBackwardCompatibleWithOldServer` 的注释声称验证"旧服务端把 -1 当 <=0 返回首块"，但桩 `StubSender.send`（`result_test.cj:591-600`）对 `bufSize < 0` 只在 `nullProbe` 为真时回 `DataNone`，否则一律按块游标返回 —— 用例并没有构造出与 `emptyBlobIsSomeEmptyStream` 不同的输入，所谓"向后兼容"实际没被覆盖。
- **建议**：两个用例合并成一个（或真的给 `StubSender` 加"旧服务端语义"开关再保留两条）；`mockResult` / `matrixResult` 保留一个，另一个删掉或改名转调。

### [轻微][存量] #10 `sqltypes_test.cj:172-174` 的注释与当前实现相反

- **位置**：`f_dbd/src/common/sqltypes_test.cj:172-175`
- **来源**：存量（`eda252b8f 2026-10-16` 之后未同步）
- **判据**：review-checklist §11「语义与注释不符」、§13 同类（文档/注释与实现一致性）
- **证据**：静态确定 —— 注释写"当前实现按 `Int64.Max` 申请，会抛分配失败"，而 `types.cj:405-422` 已改成固定 64 KiB 缓冲分块读（`Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`）；`f_dbd/src` 里 `Int64.Max` 只出现在这条注释本身与 `types_test.cj:70/73`（`UpdateResultPayload.rc` 的越界用例），`readChunk` / `encodeParameter` 中没有任何按剩余长度整块申请的分支。
- **描述**：这条注释是用来解释"为什么必须有 `encodeParameterStreamReadsToEnd` 这个用例"的，留着会误导后来人以为代码里还有一处待修的大分配。
- **建议**：改成描述历史（"旧实现按剩余长度整块申请"）或直接删掉后半句。

### [轻微][存量] #11 类型归一对 `sql` 前缀短路返回，未命中的 `Sql*` / `sql_…` 拼写不再走后面的方言表

- **位置**：`f_dbd/src/common/types.cj:181-184`（`if (key.startsWith('sql')) { return resolveSqlName(...) }`）
- **来源**：存量（`ef7b9b06ee`）
- **判据**：review-checklist §11「分支只做了一半」、§10 正确性（类型映射）
- **证据**：静态确定（控制流）+ 待确认（是否有驱动真的上报这类名字）—— `resolveSqlName`（`259-275`）只覆盖 21 个 `Sql*` 抽象名；`return` 之后 `TINYINT(1)`、`resolveCangjieName`、`resolveDialect`、`unsigned`、去括号、前缀匹配六条后续规则全部跳过。例如 `sql_variant`（MSSQL）或 `sqlbit` 会直接落 `None`，而同样的拼写不带 `sql` 前缀时 `bit` 是能映射到 `Array<Byte>` 的。
- **描述**：前缀判断假设"以 `sql` 开头的只可能是 `Sql*` 抽象名"，但方言里确实存在 `sql_` 开头的类型名；命中不了也不会报错，只是静默降级成 `String` + WARN（与本报告 #1 同一个后果面）。
- **建议**：改成"命中则返回，未命中继续往下走"（`match (resolveSqlName(...)) { case Some(n) => return Some(n); case _ => () }`），与 `types.cj:189-196` 的写法保持一致。

## 优化可行性方案

### [堆内存] `readChunk` 固定 64 KiB 缓冲 + 双重拷贝 + 未按已知 `size` 预分配

- **现状**：`f_dbd/src/common/types.cj:405-422` 每次调用都无条件 `Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)`（64 KiB），再按轮 `stream.read(buf[0..want])`（切片复制）→ `out.add(all: buf[0..n])`（第二次复制）。`fdbm/src/execute/cursor.cj:186-187` 把客户端请求里的 `bufSize` 原样作为 `size` 传进来，所以"客户端要 1 字节读一块"时，为读 1 字节会分配并清零 64 KiB（放大约 65536×），`out` 也从容量 0 开始按倍增扩容。
- **方案**：`size > 0` 时用 `let cap = min(size - got, DEFAULT_STREAM_CHUNK)` 决定缓冲大小（一次分配、逐轮复用），并用 `ArrayList<Byte>(size)` 预分配容量；`size <= 0` 的整读路径保持不变。
- **预期**：小 `bufSize` 的分块读每次分配量从 64 KiB 降到 `min(size, 64 KiB)`；整读路径少掉 `ArrayList` 的数次扩容复制（n=1 MiB 时约 2 MiB 的额外复制量）。均为静态推算，未测。
- **代价**：每次调用多一次 `min` 判断；`size` 极大时缓冲仍不超 64 KiB，语义不变（短块不是 EOF，见 `types.cj:397-404` 的约定）。
- **验证**：`F_DBD_BENCH=1 cjpm test`（`ReadChunkReuse_test.benchToEnd` 已有 `getAllocatedHeapSize` 口径）在 `bufSize = 1 / 64 / 1024` 三档下对比 `alloc`；再用 `getUsedHeapSize()` / RSS 看稳态。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `DbdInputStream.read` 用逐字节循环搬运

- **现状**：`f_dbd/src/common/result.cj:429-435` 每次 `read` 最多执行 `chunkSize` 次单字节赋值（`while (i < n) { buffer[i] = pending[pos + i]; i += 1 }`），而 `n` 已算好、`pending` 是连续数组；这是流列读格的唯一搬运路径（每块 64 KiB 默认）。对比同仓 `f_multi`/测试里已用的 `copyTo` 写法（`ReadChunkReuse_test.cj:39`）。
- **方案**：`pending[pos..pos + n].copyTo(buffer, 0, 0, n)`（或先 `buffer[0..n]` 切片再拷）替换循环。
- **预期**：单块搬运由 O(n) 次带边界检查的赋值变成一次批量拷贝；能省多少取决于编译器是否已把循环向量化，未测。
- **代价**：多一次切片分配（若编译器不消除），需实测确认净收益为正；语义等价（`n` 已由 `min(buffer.size, pending.size - pos)` 限定）。
- **验证**：`cjprof record` 读 200 MiB LOB（`fetch_rows=65536`）对比 `read` 自耗时占比；或 `cjpm bench -O2` 对 1 MiB `DbdInputStream` 做吞吐对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 本部分没有提供任何 profile / bench 数据（`scope.md` 只给了 `docs/LocalMode*.md`，与本部分无关），下面四条都只是线索，不能作为缺陷或收益结论。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 小 `bufSize` 分块读时 `readChunk` 的 64 KiB 分配被放大 | `f_dbd/src/common/types.cj:409` | 每次调用的分配量与请求分布 | `F_DBD_BENCH=1` + `getAllocatedHeapSize()`，按 `bufSize = 1 / 64 / 1024` 各跑 10k 格 |
| 2 | `DbdInputStream.read` 的逐字节搬运在流列读中占比可观 | `f_dbd/src/common/result.cj:429-435` | 自耗时占比 | `cjprof record` 跑 200 MiB LOB 读，`fetch_rows=65536` |
| 3 | 未知 `typeName` 的逐格 WARN（`readData` 的 `Unknown` 分支）会放大日志与耗时 | `f_dbd/src/common/types.cj:370-372` | 日志行数、单格耗时 | 造 1 万格 `weird_type` 列跑一轮，统计日志行数与端到端耗时 |
| 4 | `dispatch_perf_test` 里测出的 A/B 分派耗时是否仍代表当前 `decodeCellAsAny`（实现已改成 `match case _: ?X` + 子类型兜底） | `f_dbd/src/common/dispatch_perf_test.cj:60-116` | 与真实 `get<T>` 的同环境对照 | 同 SDK、`-O2`，对同 19 个类型各跑 10^6 次真实 `QueryResultImpl.get` 与用例中的 `Dispatch.canonicalB` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/common/dispatch_perf_test.cj` | .cj | ✅ | 分派性能实验；见 #8 |
| 2 | `src/common/error.cj` | .cj | ✅ | 错误码 / 载荷；`value` / `parse` / `toString` 三张表一致 |
| 3 | `src/common/error_test.cj` | .cj | ✅ | 与实现一致 |
| 4 | `src/common/payload.cj` | .cj | ✅ | 四类载荷；`params` 必须 `var` 的原因有注释 |
| 5 | `src/common/payload_test.cj` | .cj | ✅ | 与实现一致 |
| 6 | `src/common/placeholder.cj` | .cj | ✅ | 只有 `package` + 一行包说明，无声明；无死代码 |
| 7 | `src/common/result.cj` | .cj | ✅ | `QueryResultImpl` / `DbdInputStream`；见 #5、#6 |
| 8 | `src/common/result_test.cj` | .cj | ✅ | 状态机 / 流列全覆盖；见 #9 |
| 9 | `src/common/sqltypes_test.cj` | .cj | ✅ | 归一表 / 编解码 / readChunk；见 #10 |
| 10 | `src/common/types.cj` | .cj | ✅ | 归一表 + 编解码 + readChunk；见 #1、#2、#4、#11 |
| 11 | `src/common/types_matrix_test.cj` | .cj | ✅ | 三层类型矩阵；见 #9 |
| 12 | `src/common/types_test.cj` | .cj | ✅ | `decodeStrict` 用例（只覆盖同型输入，见 #2） |
| 13 | `src/dbd.cj` | .cj | ✅ | 根包重导出（含 `common.*` ⇒ `DbdException` 可达）+ `fdBDVersion` |
| 14 | `src/dbd_test.cj` | .cj | ✅ | 重导出的编译期验证 |
| 15 | `src/driver/DbdConnection.cj` | .cj | ✅ | 连接状态机 / 结果集独占；见 #3 |
| 16 | `src/driver/DbdConnection_test.cj` | .cj | ✅ | 状态机与独占闸门；与实现一致 |
| 17 | `src/driver/DbdDatasource.cj` | .cj | ✅ | 惰性建链、凭据覆盖、幂等关闭；与注释一致 |
| 18 | `src/driver/DbdDriver.cj` | .cj | ✅ | `static init` 注册 + 别名；未配置时不注册（不结束进程） |
| 19 | `src/driver/DbdDriver_test.cj` | .cj | ✅ | 注册 / 选项解析 / 不建链；与实现一致 |
| 20 | `src/driver/DbdOptions.cj` | .cj | ✅ | 选项表；见 #7 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1、#2、#3、#4、#6；设计：`common` 只放可与 fdbm 共用的载荷与类型映射、`driver` 只放 std 接口实现，依赖方向单向（`driver → common`、`common` 不引用驱动），分层无违规；语言特性：`Array<ColumnInfoImpl> → Array<ColumnInfo>` 因泛型不变逐项转换（`result.cj:70-75`）正确、`asTarget` 用 `case x: T` 收口正确；安全性：metadata 走 `toUrlMasked()`，测试逐项断言密码不出现（`DbdConnection_test.cj:112-115`），无注入面（SQL 由 `SqlPayload` 参数化下发），本部分无裸凭据 |
| §1 死代码 | 0 | 已逐个搜：`private`（`asTarget` / `decodeCellAsAny` / `decoded` / `runeOf` / `fallbackAsAny` / `isStreamColumn` / `openStreamAsAny` / `invalidateStreams` / `ensureReadable` / `DbdTypeInfo` / `resolve*` / `parenBaseOf` / `cellOf` / `isIntegerTarget` / `TI_*` / `PAREN_BASES` / `configuredNameOrNone` / `missingNameError` / `configuredName` / `timeoutOf` / `codeOf` / `messageOf` / `formatPct` / `largerOf` / `medianOf` / `MissPlainClass` / `MyInputStream` / `MyStreamImpl` / `PlainValue` / `PlainProbe` / `DribbleStream` / `RecordingStream` / `FailingStream` / `Timing` / `Row` / `TypeInfoCache` / `Dispatch`）在 `f_dbd` 内全部有调用；`internal`（`requestBlock` / `columnIndex` / `invalidate` / `DbdInputStream.init` / `credential` / `ensureNoOpenResult` / `registerResult` / `request` / `unsubscribe` / `DbdOptions` 全部字段）在包内有调用；无 `protected` 声明；`public` 均为对外可达（`dbd.cj` 的 `public import` 链完整），按硬原则一不判。仅记录信息：`SqlTypes.readStream(result,index,size)`（`types.cj:428-430`）仓内只有 `sqltypes_test` 引用，但它是 `public struct` 的 `public static func`，属对外 API，不是死代码；`DbdDriver()` 无参构造（`DbdDriver.cj:43-45`）仓内无调用，同为对外 API |
| §2 重复逻辑 | 3 | 已把 20 个文件的函数体两两比对：#5（流解码两处 try/catch）、#7（三个超时分支）、#9（两个同体用例 + 两个同体桩助手）。`DbdErrorCode` 的 `value` / `toString` / `parse` 是同一张表的三个方向，输出不同，不算重复；`decodeCellAsAny` 的 19 个 `case` 与 `Dispatch.canonicalB` 形状相同但一个是生产代码、一个是实验桩，语义目标不同 |
| §3 空实现 | 0 | 全部分文件搜 `TODO` / `FIXME` / `UnsupportedException` 无命中；`QueryResultImpl.close()`（`result.cj:189-193`）与 `DbdConnection.close()`（`DbdConnection.cj:102-107`）的 `catch (_: Exception) { () }` 都有注释说明是"关闭失败不要求应用再写一遍清理"的有意策略，且随后一定置 `closed_` / 释放本地状态（有用例 `closeFailureStillReleasesLocalState` 钉住），不算静默吞异常 |
| §4 栈溢出 | 0 | 本部分无递归：`next` / `getOrNull` / `read` / `readChunk` 均为平铺循环；`toString` / `==` 都不递归子结构；无深拷贝 |
| §5 OOM | 1 | #4（LOB 整块物化）。其余容器都有界：`streams_` / `nullStreams_` 按列数（`result.cj:55-57`），`params` 由调用方逐个 `add`（`payload.cj:41-48`），`columnInfos` 由首包长度决定 |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` / `cjpm bench` 数据，`dispatch_perf_test` 只测分派本身（不含 I/O 与解码），不构成任何热点结论；四条线索已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | `DbdConnection` 唯一一把 `Mutex` 只保护 `closed` / `activeResult` 两个字段，临界区内无 I/O、无日志、无回调（`close()` 特意把 `r.close()` 挪到锁外，`DbdConnection.cj:98-108`）；不存在"一把全局锁保护多个无关资源" |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池使用；`DbdInputStream` 的块请求是同步往返，属协议约定（一问一答），不是"形式并发" |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无热路径 `contains` / `remove(at:)`；`medianOf` 的冒泡排序只在测试里对 5 个元素用；类型归一的 `PAREN_BASES` 是 39 项线性前缀扫描（每列一次，不随行数增长），不属热点 |
| §7 降堆内存方案 | 1 | `readChunk` 的固定 64 KiB 缓冲 + 双拷贝（无基线，已标「待验证」） |
| §8 降 CPU 方案 | 1 | `DbdInputStream.read` 的逐字节搬运（无基线，已标「待验证」） |
| §9 local mode 可行性 | 0 | 本部分临时对象峰值就是单块 64 KiB（`readChunk`）与 `query` 时的列信息数组，生命周期随单次调用结束但都要返回/逃逸（`Array<Byte>` 返回、`QueryResultImpl` 持有列信息），不满足"不离开函数"；要做也只能拿到峰值内存对照才成立，本部分无数据 |
| §11 现有代码的 BUG（存量） | 11 | #1–#11 全部标「存量」（4 一般 + 7 轻微）；本部分读到的其余函数（`DbdErrorCode.parse` 的越界回退、`UpdateResultPayload` 的 `@DataExclude` 线缆键、`QueryResultImpl` 的 `exhausted` 终态、`DbdInputStream` 的 EOF 幂等、`DbdDatasource.connect` 的异常清理）边界与空值均已逐条核对，无额外缺陷 |
| §12 并发安全与锁粒度 | 1 | #3（`close` / `registerResult` 的状态互斥缺失）。`QueryResultImpl` / `DbdInputStream` 自身无锁，它们按 `DbdConnection` 的"结果集独占"不变量（`DbdConnection.cj:28-35`）只在持有连接的单条执行链上使用，属线程封闭；本部分其余共享点只有 `DbdDriver` 的 `static init`（包初始化时执行一次）与 `DriverManager` / `Config`（std 与 `f_config` 自身线程安全）。锁粒度见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`，README / `fdbm/doc/详细设计.md` 的对照归第 1、2、4、5 部分；仅从代码侧核对：`dbd.cj` 的重导出覆盖了 `common.*`（含 `DbdException`，实现体在 `common/DbdException.cj`，`exception/` 只有一行 `public import`）与 `driver`/`multid` 的入口类型，`fdBDVersion` 有测试，无"注册了但没人用"的接线缺口（`fetchRows` 已在 `DbdStatement.cj:94` 接到 `chunkSize`） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，§13 的文档一致性不适用于本部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分（`common` 的载荷 / 结果集 / 类型映射 + `driver` 的四个入口类）整体质量偏好：状态机（`next` → `rowValid` → `exhausted` → `closed_`）、流列句柄复用与失效（`streams_` / `nullStreams_` / `invalidate`）、`NEXT_ROW(-1)` 与 `CELL(index,-1)` NULL 探测的协议约定都有注释与用例互相对齐，没有空实现、没有不可达代码、没有递归与无界容器；连接级"结果集独占"这一不太直观的不变量也有专门用例守住。

主要风险集中在两处：

1. **类型映射表的缺口（#1）**——这是唯一会直接产生"错误数据视图"的问题：`int(11)` / `real` 这类真实存在的列类型静默降级成 `String`，只在日志里留一条 WARN，业务侧看到的是字符串比较/排序。修起来只是补两个表项 + 三条用例，建议优先排期。
2. **`decodeStrict` 的 flag 恒为 0（#2）**——注释与代码互相矛盾，眼下靠 `DataObject<T>` 快路径遮住；它属于"下一次重构就会全线崩"的潜伏项，值得连带补一条非同型输入的用例。

资源与生命周期方面，`DbdConnection.close()` 与 `registerResult()` 的状态交错（#3）与 `readData` 的 LOB 整块物化（#4）是两个需要设计决策的点：前者要决定"关闭中的连接是否允许新游标"，后者要决定"是否给 LOB 设上限"。其余为重复逻辑与注释/测试质量问题，可随手清理。

无阻塞性（严重）问题；本部分共 **11 条存量缺陷（0 严重 / 4 一般 / 7 轻微）**，是否纳入修复、以及 #3、#4 是否需要先定契约，待用户决定。两条优化方案均无基线数据，仅作下一轮补测量的候选，不进 `tasks.md`。
