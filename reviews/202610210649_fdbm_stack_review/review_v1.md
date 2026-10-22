# R1: f_dbd 全部文档与源码的功能完备性

审查时间：2026-10-21 06:59

### 审查范围

基线 `7ca82fcc`，工作树 `.worktrees/review_fdbm_stack_202610210649`（只读，未修改任何源码）。

- 文档：`f_dbd/README.md`、`f_dbd/README_en.md`、`f_dbd/doc/详细设计.md`、`f_dbd/doc/开发计划.md`、`f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/{design.md,proposal.md,tasks.md}`、`.../specs/f-dbd/spec.md`、`.../specs/f-protocol/spec.md`、`f_dbd/cjpm.toml`
- 源码（非测试）：`src/dbd.cj`、`src/common/{types,error,payload,column,result,DbdException,placeholder}.cj`、`src/exception/DbdException.cj`、`src/driver/{DbdDriver,DbdDatasource,DbdConnection,DbdStatement,DbdTransaction,DbdTransport,DbdUrl,DbdOptions,placeholder}.cj`、`src/multid/{MultiD,Datasource,Url,Config,placeholder}.cj`
- 交叉参照：`fdbm/src/execute/cursor.cj`、`f_net/src/client/client.cj`、`f_dbpool/src/DatabasePool.cj`、`f_protocol/src/default/Message.cj`（仅用于确认调用链与接口契约）

本轮不含测试用例覆盖度（R2）。

### 功能完备性覆盖矩阵

| # | 文档承诺（出处） | 实现位置 | 结论 |
| --- | --- | --- | --- |
| 1 | 四个子包 `common`/`exception`/`driver`/`multid`（README 包结构、设计 §2） | 对应目录均存在 | 符合 |
| 2 | 根包 `fountain::f_dbd`：驱动注册入口、版本信息、对 `common` 的公开重导出（设计 §2:54） | `src/dbd.cj:16-20` 只有一条注释 | **缺失**（见 G3） |
| 3 | `SqlPayload` + `add`/`addNull`（设计 §3.3） | `common/payload.cj:28-49` | 符合 |
| 4 | `UpdateResultPayload <: UpdateResult`，键名 `rc`/`liid`（§3.4） | `common/payload.cj:57-81` | 符合 |
| 5 | `QueryResultServerPayload` 仅列信息（§3.5） | `common/payload.cj:89-98` | 符合 |
| 6 | `QueryResultColumnPayload.cell/nextRow`，无关闭哨兵（§3.6） | `common/payload.cj:106-125` | 符合 |
| 7 | `QueryResultClosePayload(qid)`（§3.6.1） | `common/payload.cj:133-142` | 符合 |
| 8 | `ColumnInfoImpl <: ColumnInfo`，短键名（§3.7） | `common/column.cj:32-90` | 符合 |
| 9 | `DbdErrorCode` 16 个码 + `value`/`parse`/`toString`/`==`（§3.8） | `common/error.cj:31-120` | 符合（编号与设计逐项一致） |
| 10 | `DbdErrorPayload.errorCode()`（§3.8） | `common/error.cj:122-140` | 符合 |
| 11 | `decodeStrict<T>`（§3.2） | `common/types.cj:52-58` | 符合 |
| 12 | `SqlTypes` 八个方法（§3.9） | `common/types.cj:138-501` | 方法齐全；`readData`/`encodeParameter` 有缺陷（S1/S2） |
| 13 | `SqlReadType` + 别名口径（§8） | `common/types.cj:70-128` | 基本符合；`of()` 不接受 `InputStream`/`std.time.DateTime` 别名（M5） |
| 14 | `QueryResultImpl`：`columnInfos`/`next`/`next(values)`/`get`/`getOrNull`/`close`/`isClosed`（§3.10） | `common/result.cj:47-341` | 全部实现；NULL 流列语义偏差（G6）、流列标量读取截断（G7） |
| 15 | 游标不变量 1–8（§3.10） | `common/result.cj:89-206,311-317` | 规则 2/5/6/7/8 实现；规则 1 在 `next()` 异常时未生效（M1） |
| 16 | `DbdInputStream`（§3.11） | `common/result.cj:350-405` | 符合（含 EOF 终态偏差登记） |
| 17 | `DbdException <: SqlException` + `exception` 重导出（§4） | `common/DbdException.cj:34-64`、`exception/DbdException.cj:28` | 符合 |
| 18 | `DbdUrl.parse/tryParse/toUrl`、默认端口 8112、database 必填、%XX（§5.1） | `driver/DbdUrl.cj:35-161` | 主要功能符合；非 ASCII %XX 解码错误（G1）、端口 0 放行（M4） |
| 19 | `DbdDriver` 注册/`name`/`preferredPooling`/`version`/`open`（§5.2） | `driver/DbdDriver.cj:42-93` | 功能符合；注册名文档冲突（G4）、包初始化即 `exit` 的耦合（G5） |
| 20 | `DbdDatasource.connect/setOption/close/isClosed` + 6 个选项（§5.3） | `driver/DbdDatasource.cj:29-98`、`DbdOptions.cj:28-94` | 选项齐全；非法超时值语义错误（G2） |
| 21 | `DbdConnection.state/prepareStatement/createTransaction/getMetaData/close/isClosed` + 连接级结果集独占（§5.4） | `driver/DbdConnection.cj:36-152` | 符合；`Connecting` 态不可达（M3） |
| 22 | `DbdStatement` 全接口 + deprecated 重载 + 空洞参数（§5.5） | `driver/DbdStatement.cj:36-262` | 符合 |
| 23 | 参数编码表含 `InputStream`（§5.5「InputStream 读出全部字节」） | `common/types.cj:452` | **不可用**（S1） |
| 24 | `DbdTransaction` 三属性 + 6 个方法 + savepoint 注入防护（§5.8） | `driver/DbdTransaction.cj:31-158` | 符合 |
| 25 | `DbdTransport.request/unsubscribe/ping/isClosed/close`（§5.9） | `driver/DbdTransport.cj:45-147` | 行为符合；构造签名与设计不符（M8） |
| 26 | 报文矩阵 CONSUME/RESP/UNSUBSCRIBE/ACK/ERROR（§7.1） | `DbdTransport.cj:60-96`、`DbdStatement.cj:82-113`、`result.cj:174-186` | 符合 |
| 27 | 查询时序/关闭握手/qid（§7.2、§7.3） | `DbdStatement.cj:91-97`、`result.cj:174-186` | 符合 |
| 28 | 超时与断链 fail-fast（§7.4） | `DbdTransport.cj:134-146`、`DbdConnection.cj:51-63` | 符合（传输关闭即 Broken） |
| 29 | `MultiDConfig` 14 个 `get*`（§6.1） | `multid/Config.cj:29-177` | 符合，默认值与设计一致 |
| 30 | `MultiDUrl` 双 scheme + `parse/tryParse`（§6.2、§6.3） | `multid/Url.cj:31-119` | 符合 |
| 31 | `MultiD` 注册 `multidbd`、`preferredPooling=false`、`open`（§6.3） | `multid/MultiD.cj:32-74` | 符合 |
| 32 | `MultiDatasource` 每节点一池、加权随机/轮询、close 不等待（§6.4） | `multid/Datasource.cj:33-195` | 符合；错误分类靠字符串匹配（G8） |
| 33 | `cjpm.toml` 版本 1.3.16 / category 五项 / 依赖（设计 §9 偏离 9） | `f_dbd/cjpm.toml:1-59` | 符合（`f_codec` 未被直接 import，无功能影响） |
| 34 | 空实现 / TODO / `Unimplemented` / 空函数体 | 全 `src` 扫描 | 未发现空函数体；存在 5 处「阶段 0 仅建骨架」残留（M6） |

结论：**公开 API、配置项、URL、协议、错误码、事务、流式结果、MultiD 均有实现，无 `throw Unimplemented`、无空函数体**；缺口集中在两处数据路径实现错误（S1/S2）、根包缺失、若干文档—代码口径不一致。

### 发现

#### [严重] `set<InputStream>` 参数编码会申请约 9 EiB 内存，文档承诺的 BLOB 参数路径必然失败

- **位置**：`f_dbd/src/common/types.cj:452`（`case x: InputStream => readChunk(x, Int64.Max).toData()`），分配点在 `f_dbd/src/common/types.cj:403`（`Array<Byte>(want - got, repeat: 0u8)`）
- **描述**：`readChunk(stream, Int64.Max)` 在第一轮循环就按 `want = Int64.Max` 分配临时数组，之后才 `read`。因此任何 `set<InputStream>`（含 deprecated 重载 `SqlBlob`/`SqlClob`/`SqlNullableBlob`/`SqlNullableClob`，见 `DbdStatement.cj:215,219,234,238`）都会在编码阶段抛分配失败/溢出异常，而不是像设计 §5.5 表格承诺的「读出全部字节后编码」。该异常不是 `DataException`，也不会被 `DbdStatement.encode`（`DbdStatement.cj:198-205`）包成 `DbdException(CONVERSION)`，直接破坏「对外只抛 `SqlException`」的契约。
- **建议**：`encodeParameter` 改为按固定块循环读取（如 8 KiB/64 KiB）累积到 `ArrayList<Byte>` 直到 `read` 返回 0；或给 `readChunk` 增加流式累加分支，禁止 `size` 超过 `DEFAULT_STREAM_CHUNK` 的整数倍上限。补一个「多块 InputStream 参数」用例（R2 同步）。

#### [严重] `SqlTypes.readData` 对流列只取一块 64 KiB，静默截断大对象

- **位置**：`f_dbd/src/common/types.cj:367-369`（`case _ => readStream(result, index, DEFAULT_STREAM_CHUNK).toData()`）
- **描述**：注释写「整块读出」，但 `SqlTypes.readStream(result, index, size)`（`types.cj:420-422`）只调用一次 `readChunk`，最多返回 `size` 字节。任何以 `SqlReadType.Stream`（或归一到 `Unknown` 的拼写）交给 `readData` 的列，超过 64 KiB 的部分会被**静默丢弃**且不报错，违反设计 §3.9「`readData` 是 fdbm 侧唯一取值入口」的语义。当前 fdbm 的游标路径（`fdbm/src/execute/cursor.cj:155-165`）绕开了本函数，但 `executors.cj:314,533,819` 直接调用 `readData`，属潜在数据丢失路径；同时 `Unknown` 走 `case _` 落到流分支，而设计 §8 要求 `Unknown` 按 `String` 处理（`canonicalName` 的兜底才是 String）。
- **建议**：`readData` 对 `Stream` 显式循环 `readChunk` 直到空块再返回；对 `Unknown` 按 `Text` 分支处理（或先调用 `canonicalName` 再分派）；保留「一次性整块读」注释与实际行为一致。

#### [一般] `DbdUrl` 的 `%XX` 解码按 Rune 还原字节，非 ASCII 凭据/库名变成乱码

- **位置**：`f_dbd/src/driver/DbdUrl.cj:197-218`（关键行 `206`：`out.add(Rune(UInt32(n)))`）
- **描述**：`percentEncode`（`DbdUrl.cj:225-250`）明确按 UTF-8 字节逐字节编码（`你` → `%E4%BD%A0`），但 `percentDecode` 把每个 `%XX` 直接构造成 `Rune(U+00XX)`，得到 `ä½ ` 三个 Latin-1 字符而不是 `你`。README.md:38-39 与 README_en.md:39-40 都承诺「凭据支持 `%XX` 编码」，设计 §5.1 还要求 `toUrl()` 能反向重建；非 ASCII 用户名/口令会解析错误，`parse → toUrl` 往返也不成立。`database` 只做 `percentEncode` 不做 decode（`DbdUrl.cj:67`），同样不对称。
- **建议**：先按字节收集 `%XX`，再整体 `String.fromUtf8`；或复用 `f_base` 的 URL 编解码工具。补一条非 ASCII 凭据的往返用例。

#### [一般] 非法超时配置被静默改成「无限等待」，与注释和设计意图相反

- **位置**：`f_dbd/src/driver/DbdOptions.cj:68-81`（`case None => ... None<Duration>`）
- **描述**：`timeoutOf` 的注释写「非法时记 WARN 并保持原值不变」，但实现返回 `None`，而 `apply`（`DbdOptions.cj:57-62`）直接把返回值赋给字段，等于把已经配置的超时清成「无限」（`DbdStatement.timeoutOf` → `NO_TIMEOUT = 6h`）。配置写错（如 `query_timeout=30s`）会从「30 秒」变成「6 小时」，正好违背注释里「配置写错不该让请求无限等待」。
- **建议**：`timeoutOf` 非法时返回原值（把当前字段传进去或返回 `?Duration` 并在 `apply` 中仅在 `Some` 时赋值）；`ms <= 0` 才表示「无限」。补一条「非法值不改写已有超时」的用例。

#### [一般] 根包 `fountain::f_dbd` 是空包，设计承诺的注册入口与重导出均不存在

- **位置**：`f_dbd/src/dbd.cj:16-20`
- **描述**：设计 §2:54 定义根包职责为「驱动注册入口、版本信息、对 `common` 的公开重导出」，但 `src/dbd.cj` 只有一条文件注释，全仓库没有 `public import`（`grep -rn "public import" f_dbd/src` 只命中 `exception/DbdException.cj`）。注释内容仍是「阶段 0 仅建骨架，实现在后续阶段落地」，与模块已完成的状态不符；`dbd_test.cj:23` 同样写着「阶段 0 的平凡用例」。
- **建议**：要么补上根包的 `public import fountain::f_dbd.common.*` 等重导出（与设计一致），要么修改设计 §2 删除该职责；同时清掉「阶段 0」残留措辞。

#### [一般] 驱动注册名三处文档互相矛盾：`fdbm` vs `dbd_driverName`

- **位置**：`f_dbd/src/driver/DbdDriver.cj:39-41`（类注释「应用侧只要 import 到本包即可用 `DriverManager.getDriver('fdbm')` 取到它」）；`f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md:315`（「`DbdDriver` 在 `static init` 注册为 `fdbm`」）；`f_dbd/doc/spec/.../tasks.md:68`（「`static init` 注册 `fdbm`」）
- **描述**：实现（`DbdDriver.cj:53-56`）只注册 `Config.getString('dbd_driverName')`，不存在 `fdbm` 这个固定注册名；README.md:23-24 与设计 §5.2:555 则要求驱动名 = 后端方言名。按 spec/tasks/类注释接入的应用会 `getDriver('fdbm')` 得到 `None` 并抛 `CONFIG`。当前测试（`DbdDriver_test.cj:32-41`）把环境配置成 `fdbm` 才通过，掩盖了口径冲突。
- **建议**：统一到「注册名 = `dbd_driverName`」并修正 spec.md/tasks.md/DbdDriver 类注释；若确需兼容 `fdbm`，在 `static init` 额外注册别名（需评估与物理驱动重名）。

#### [一般] `DbdDriver.static init` 在未配置 `dbd_driverName` 时直接 `exit(1)`，连只用 MultiD 的进程也被杀

- **位置**：`f_dbd/src/driver/DbdDriver.cj:53-56`、`DbdDriver.cj:95-117`
- **描述**：`multid/MultiD.cj:24` 依赖 `fountain::f_dbd.driver`（`MultiDatasource` 使用 `DbdDatasource`/`DbdUrl`），加载 `multid` 包即触发 `driver` 包初始化 → `DbdDriver.static init` → `configuredName()` → 未配置就 `exit(1)`。因此一个只用 `multidbd` 的应用必须额外配置单节点驱动的 `dbd_driverName`，否则进程在 import 阶段退出；这与 README「多节点版本为 `multidbd`」的独立用法冲突，且库级 `exit` 使问题难以在应用侧捕获。
- **建议**：把「缺配置即退出」推迟到 `dbdDriver()` / `DbdDriver.open()` 首次调用（或只在注册单节点驱动时判断），让 `MultiD` 与单节点驱动解耦；至少为 `static init` 提供可关闭的开关。

#### [一般] `getOrNull<InputStream>` 对 SQL NULL 列返回 `Some(空流)`，违反「可空但精确」契约

- **位置**：`f_dbd/src/common/result.cj:123-134`、`f_dbd/src/common/result.cj:296-309`
- **描述**：`getOrNull<T>` 在 `isStreamTarget<T>()` 为真时直接 `openStreamAsAny` 返回句柄，**不发列读请求**，因此无法区分 NULL 与空值。设计 §3.10:429 与 §3.9:391 明确「`getOrNull<T>` 只对 SQL NULL（`DataNone`）返回 `None<T>`」，README.md:61-62 也把「NULL 只有 `getOrNull` 返回 `None`」列为协议口径。实际对 NULL 的流列，应用拿到的是 `Some(DbdInputStream)`，首次 `read` 返回 0，无法与「空 BLOB」区分。
- **建议**：首次 `getOrNull<InputStream>` 时先发一次 `CELL(index, bufSize=0)` 探测 `DataNone`（可把响应当作首块缓存，避免额外 RTT），NULL 返回 `None<T>`；或在设计/README 中显式登记「流列不支持 NULL 判别」的例外。

#### [一般] 对流列做标量读取（`get<Array<Byte>>`/`get<String>`）只返回首块且不报类型错误

- **位置**：`f_dbd/src/common/result.cj:129-133`（`send_(QueryResultColumnPayload.cell(index))`）；服务端行为见 `fdbm/src/execute/cursor.cj:155-164`
- **描述**：`columnInfos[i].typeName == 'std.io.InputStream'` 的列，若应用调用 `get<Array<Byte>>(i)`，客户端按普通列发 `CELL(index, bufSize=0)`，fdbm 对流列固定按 `DEFAULT_STREAM_CHUNK` 返回**一块**字节；客户端 `decode<Array<Byte>>` 成功，于是应用拿到被截断到 64 KiB 的「完整值」，既不抛 `CONVERSION` 也无任何提示。这违反 B 口径「类型不符必须抛 `DbdException`」（设计 §10.3 不变量 2、spec.md:159）。
- **建议**：`getOrNull` 在非流目标分支里检测 `isStreamColumn(index)`：若目标类型不是 `InputStream`，直接抛 `CONVERSION` 并提示「stream column must be read as InputStream」；`Array<Byte>` 的整块读取应走「循环读尽」而不是单块。

#### [一般] `MultiDatasource.connect()` 用异常消息子串区分「池已关闭」，映射脆弱

- **位置**：`f_dbd/src/multid/Datasource.cj:113-121`
- **描述**：`if (e.message.contains('database pool is closed'))` 依赖 `f_dbpool` 的英文消息文本；该文本一旦调整或本地化，「池已关闭」会被误映射成 `TIMEOUT`，调用方按 `CONFIG` 处理的逻辑失效。设计 §6.4:828 要求「池已关闭 → `CONFIG`；池耗尽 → `TIMEOUT`」，说明这是有语义区分的契约。
- **建议**：先查 `isClosed()` / 遍历 `pools` 判断是否已关闭，再做兜底映射；或请 `f_dbpool` 暴露可判别的错误类型/错误码，而不是匹配消息。

#### [轻微] `next()` 请求失败时未失效当前行，`rowValid` 保持 `true`

- **位置**：`f_dbd/src/common/result.cj:89-110`（`send_` 在 `rowValid`/`invalidateStreams` 之前）
- **描述**：`send_` 抛超时/断链/`CURSOR_STATE` 时，函数直接退出，`rowValid` 仍是上一行的 `true`，已打开的流也未失效。后续 `get` 会继续向已损坏的传输发请求（得到 `IO`），而不是按 §7.4「失效当前游标」立即给出 `CURSOR_STATE`。虽然客户端不缓存行数据、不会读出错值，但状态机与文档不一致。
- **建议**：在 `next()` 中先 `rowValid = false` + `invalidateStreams()` 再发包，异常路径即天然失效；或在 `catch` 中统一失效后重抛。

#### [轻微] 并发模型不一致：连接层有锁，Statement/结果集/数据源选项无锁

- **位置**：`f_dbd/src/driver/DbdStatement.cj:41-43`（`parameters`/`openResult`）、`f_dbd/src/common/result.cj:55,301-308`（`streams_`）、`f_dbd/src/driver/DbdDatasource.cj:31,86-88`（`options`）
- **描述**：`DbdConnection` 用 `Mutex` 保护 `activeResult`，但同一连接上的 `DbdStatement.set`、`QueryResultImpl.get<InputStream>`（`streams_` 查重+追加）、`DbdDatasource.setOption`（与 `connect().options.copy()` 竞争）都没有同步。多线程使用时会重复打开流句柄（两个 `DbdInputStream` 交错消费同一物理流）或看到半更新的选项表。
- **建议**：在类型注释中明确「驱动对象非线程安全、单连接单线程」的约束（与 JDBC 惯例一致），或对上述三处加锁/改用不可变快照。

#### [轻微] `DbdConnection.state` 永远不会返回 `Connecting`

- **位置**：`f_dbd/src/driver/DbdConnection.cj:51-63`
- **描述**：设计 §5.4:617 声明状态机含 `Connecting / Connected / Broken / Closed`，但 `DbdConnection` 只在传输建好之后才构造，`state` 只有三个分支。
- **建议**：从设计删除 `Connecting`，或在 `DbdDatasource.connect()` 期间先构造连接并置 `Connecting`。

#### [轻微] `DbdUrl` 接受端口 0

- **位置**：`f_dbd/src/driver/DbdUrl.cj:152-161`
- **描述**：`parsePort` 只拒绝负数与超过 `UInt16.Max`，`fdbm://h:0/db` 会解析成功，随后 `connect` 到 0 端口得到一个与「非法 URL → `CONFIG`」不符的错误（`IO`）。
- **建议**：端口有效区间改为 `1..=65535`。

#### [轻微] `SqlReadType.of` 不接受设计 §8 声明的等价别名

- **位置**：`f_dbd/src/common/types.cj:105-127`
- **描述**：设计 §8:943-944 写明 `InputStream` ≡ `std.io.InputStream`、`DateTime` ≡ `std.time.DateTime`、`Array<Byte>` ≡ `Array<UInt8>`「等价」，但公开的 `SqlReadType.of('InputStream')` / `of('std.time.DateTime')` / `of('Array<UInt8>')` 都返回 `Unknown`。`canonicalName`/`readType` 走 `resolve` 时没问题，直接调用 `of` 的调用方会踩到。
- **建议**：在 `of` 内补齐别名，或收敛为 `private`（对外只保留 `readType`）。

#### [轻微] 残留的「阶段 0 仅建骨架」占位文件与注释

- **位置**：`f_dbd/src/common/placeholder.cj:19`、`f_dbd/src/driver/placeholder.cj:19`、`f_dbd/src/multid/placeholder.cj:19`、`f_dbd/src/dbd.cj:19`、`f_dbd/src/dbd_test.cj:23`
- **描述**：模块已全量实现，但这 5 处仍声明「阶段 0 / 骨架 / 占位」；三个 `placeholder.cj` 只包含包注释、没有任何声明，属于死文件，会误导读者以为对应包未完成（尤其与 G3 的根包缺失叠加）。
- **建议**：删除三个 `placeholder.cj`，更新 `dbd.cj`/`dbd_test.cj` 的注释为当前职责。

#### [轻微] README_en 与 README.md 的异常口径不一致；设计 §5.9 的构造签名与实现不符

- **位置**：`f_dbd/README_en.md:75-79`（缺少 README.md:70「`SqlException` 的 `get` 失败映射成 `CONVERSION` 并保留 `cause`」）、`f_dbd/doc/详细设计.md:737-740`（`init(host, port, options)`）vs `f_dbd/src/driver/DbdTransport.cj:49`（`init(host, port)`）
- **描述**：中英 README 对同一契约的描述不同步；设计中的 `DbdTransport` 构造签名多一个 `options` 参数，实际超时由每次请求传入、`connection_timeout` 由 `DbdDatasource` 单独 `ping` 承担（`DbdDatasource.cj:66-76`），设计与实现各自表述。
- **建议**：补齐 README_en 的 `CONVERSION`/`cause` 说明；把设计 §5.9 的签名改为实际形态，并在 §5.3 注明 `connection_timeout` 通过一次 PING 生效。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 8 |

### 总评

f_dbd 的**功能骨架是完整的**：README/详细设计列出的公开 API、18 个包级类型与常量、16 个错误码、URL 两种 scheme、CONSUME/RESP/UNSUBSCRIBE/ACK/ERROR 报文矩阵、连接级结果集独占、事务透传、流式分块、MultiD 加权随机/轮询与全部 `multidbm_*` 配置项都有对应实现，未发现空函数体、`throw Unimplemented`、TODO/FIXME 或永远返回常量的占位分支；`DbdException` 的异常收口、`close()` 幂等、qid 关闭握手等关键不变量实现得比较扎实。

主要风险是两条**数据路径的实现错误**，它们不会被常规用例发现：`set<InputStream>` 因 `readChunk(Int64.Max)` 必然分配失败（S1），`readData` 对流列只取一块导致静默截断（S2）。其次是**契约与文档的口径漂移**：根包空实现、驱动注册名在 spec/tasks/类注释三处写成 `fdbm`、`getOrNull<InputStream>` 对 NULL 返回 `Some`、非 ASCII `%XX` 解码错误、非法超时被静默改成无限等待。这些不影响主链路联调，但会让按文档接入的使用者在边界场景拿到与承诺不一致的行为。

建议优先修 S1/S2 与 G1（凭据解码），再统一 G3/G4/G5 的注册与包结构口径；其余为可维护性改进。
