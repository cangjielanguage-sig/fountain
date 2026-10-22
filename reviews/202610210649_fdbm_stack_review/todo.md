# fdbm / f_dbd / f_dbm 评审 TODO（严重 / 一般）

## R1

### [严重] `set<InputStream>` 参数编码会申请约 9 EiB 内存，文档承诺的 BLOB 参数路径必然失败

- **位置**：`f_dbd/src/common/types.cj:452`（`case x: InputStream => readChunk(x, Int64.Max).toData()`），分配点在 `f_dbd/src/common/types.cj:403`（`Array<Byte>(want - got, repeat: 0u8)`）
- **描述**：`readChunk(stream, Int64.Max)` 在第一轮循环就按 `want = Int64.Max` 分配临时数组，之后才 `read`。因此任何 `set<InputStream>`（含 deprecated 重载 `SqlBlob`/`SqlClob`/`SqlNullableBlob`/`SqlNullableClob`，见 `DbdStatement.cj:215,219,234,238`）都会在编码阶段抛分配失败/溢出异常，而不是像设计 §5.5 表格承诺的「读出全部字节后编码」。该异常不是 `DataException`，也不会被 `DbdStatement.encode`（`DbdStatement.cj:198-205`）包成 `DbdException(CONVERSION)`，直接破坏「对外只抛 `SqlException`」的契约。

### [严重] `SqlTypes.readData` 对流列只取一块 64 KiB，静默截断大对象

- **位置**：`f_dbd/src/common/types.cj:367-369`（`case _ => readStream(result, index, DEFAULT_STREAM_CHUNK).toData()`）
- **描述**：注释写「整块读出」，但 `SqlTypes.readStream(result, index, size)`（`types.cj:420-422`）只调用一次 `readChunk`，最多返回 `size` 字节。任何以 `SqlReadType.Stream`（或归一到 `Unknown` 的拼写）交给 `readData` 的列，超过 64 KiB 的部分会被**静默丢弃**且不报错，违反设计 §3.9「`readData` 是 fdbm 侧唯一取值入口」的语义。当前 fdbm 的游标路径（`fdbm/src/execute/cursor.cj:155-165`）绕开了本函数，但 `executors.cj:314,533,819` 直接调用 `readData`，属潜在数据丢失路径；同时 `Unknown` 走 `case _` 落到流分支，而设计 §8 要求 `Unknown` 按 `String` 处理（`canonicalName` 的兜底才是 String）。

### [一般] `DbdUrl` 的 `%XX` 解码按 Rune 还原字节，非 ASCII 凭据/库名变成乱码

- **位置**：`f_dbd/src/driver/DbdUrl.cj:197-218`（关键行 `206`：`out.add(Rune(UInt32(n)))`）
- **描述**：`percentEncode`（`DbdUrl.cj:225-250`）明确按 UTF-8 字节逐字节编码（`你` → `%E4%BD%A0`），但 `percentDecode` 把每个 `%XX` 直接构造成 `Rune(U+00XX)`，得到 `ä½ ` 三个 Latin-1 字符而不是 `你`。README.md:38-39 与 README_en.md:39-40 都承诺「凭据支持 `%XX` 编码」，设计 §5.1 还要求 `toUrl()` 能反向重建；非 ASCII 用户名/口令会解析错误，`parse → toUrl` 往返也不成立。`database` 只做 `percentEncode` 不做 decode（`DbdUrl.cj:67`），同样不对称。

### [一般] 非法超时配置被静默改成「无限等待」，与注释和设计意图相反

- **位置**：`f_dbd/src/driver/DbdOptions.cj:68-81`（`case None => ... None<Duration>`）
- **描述**：`timeoutOf` 的注释写「非法时记 WARN 并保持原值不变」，但实现返回 `None`，而 `apply`（`DbdOptions.cj:57-62`）直接把返回值赋给字段，等于把已经配置的超时清成「无限」（`DbdStatement.timeoutOf` → `NO_TIMEOUT = 6h`）。配置写错（如 `query_timeout=30s`）会从「30 秒」变成「6 小时」，正好违背注释里「配置写错不该让请求无限等待」。

### [一般] 根包 `fountain::f_dbd` 是空包，设计承诺的注册入口与重导出均不存在

- **位置**：`f_dbd/src/dbd.cj:16-20`
- **描述**：设计 §2:54 定义根包职责为「驱动注册入口、版本信息、对 `common` 的公开重导出」，但 `src/dbd.cj` 只有一条文件注释，全仓库没有 `public import`（`grep -rn "public import" f_dbd/src` 只命中 `exception/DbdException.cj`）。注释内容仍是「阶段 0 仅建骨架，实现在后续阶段落地」，与模块已完成的状态不符；`dbd_test.cj:23` 同样写着「阶段 0 的平凡用例」。

### [一般] 驱动注册名三处文档互相矛盾：`fdbm` vs `dbd_driverName`

- **位置**：`f_dbd/src/driver/DbdDriver.cj:39-41`（类注释「应用侧只要 import 到本包即可用 `DriverManager.getDriver('fdbm')` 取到它」）；`f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md:315`（「`DbdDriver` 在 `static init` 注册为 `fdbm`」）；`f_dbd/doc/spec/.../tasks.md:68`（「`static init` 注册 `fdbm`」）
- **描述**：实现（`DbdDriver.cj:53-56`）只注册 `Config.getString('dbd_driverName')`，不存在 `fdbm` 这个固定注册名；README.md:23-24 与设计 §5.2:555 则要求驱动名 = 后端方言名。按 spec/tasks/类注释接入的应用会 `getDriver('fdbm')` 得到 `None` 并抛 `CONFIG`。当前测试（`DbdDriver_test.cj:32-41`）把环境配置成 `fdbm` 才通过，掩盖了口径冲突。

### [一般] `DbdDriver.static init` 在未配置 `dbd_driverName` 时直接 `exit(1)`，连只用 MultiD 的进程也被杀

- **位置**：`f_dbd/src/driver/DbdDriver.cj:53-56`、`DbdDriver.cj:95-117`
- **描述**：`multid/MultiD.cj:24` 依赖 `fountain::f_dbd.driver`（`MultiDatasource` 使用 `DbdDatasource`/`DbdUrl`），加载 `multid` 包即触发 `driver` 包初始化 → `DbdDriver.static init` → `configuredName()` → 未配置就 `exit(1)`。因此一个只用 `multidbd` 的应用必须额外配置单节点驱动的 `dbd_driverName`，否则进程在 import 阶段退出；这与 README「多节点版本为 `multidbd`」的独立用法冲突，且库级 `exit` 使问题难以在应用侧捕获。

### [一般] `getOrNull<InputStream>` 对 SQL NULL 列返回 `Some(空流)`，违反「可空但精确」契约

- **位置**：`f_dbd/src/common/result.cj:123-134`、`f_dbd/src/common/result.cj:296-309`
- **描述**：`getOrNull<T>` 在 `isStreamTarget<T>()` 为真时直接 `openStreamAsAny` 返回句柄，**不发列读请求**，因此无法区分 NULL 与空值。设计 §3.10:429 与 §3.9:391 明确「`getOrNull<T>` 只对 SQL NULL（`DataNone`）返回 `None<T>`」，README.md:61-62 也把「NULL 只有 `getOrNull` 返回 `None`」列为协议口径。实际对 NULL 的流列，应用拿到的是 `Some(DbdInputStream)`，首次 `read` 返回 0，无法与「空 BLOB」区分。

### [一般] 对流列做标量读取（`get<Array<Byte>>`/`get<String>`）只返回首块且不报类型错误

- **位置**：`f_dbd/src/common/result.cj:129-133`（`send_(QueryResultColumnPayload.cell(index))`）；服务端行为见 `fdbm/src/execute/cursor.cj:155-164`
- **描述**：`columnInfos[i].typeName == 'std.io.InputStream'` 的列，若应用调用 `get<Array<Byte>>(i)`，客户端按普通列发 `CELL(index, bufSize=0)`，fdbm 对流列固定按 `DEFAULT_STREAM_CHUNK` 返回**一块**字节；客户端 `decode<Array<Byte>>` 成功，于是应用拿到被截断到 64 KiB 的「完整值」，既不抛 `CONVERSION` 也无任何提示。这违反 B 口径「类型不符必须抛 `DbdException`」（设计 §10.3 不变量 2、spec.md:159）。

### [一般] `MultiDatasource.connect()` 用异常消息子串区分「池已关闭」，映射脆弱

- **位置**：`f_dbd/src/multid/Datasource.cj:113-121`
- **描述**：`if (e.message.contains('database pool is closed'))` 依赖 `f_dbpool` 的英文消息文本；该文本一旦调整或本地化，「池已关闭」会被误映射成 `TIMEOUT`，调用方按 `CONFIG` 处理的逻辑失效。设计 §6.4:828 要求「池已关闭 → `CONFIG`；池耗尽 → `TIMEOUT`」，说明这是有语义区分的契约。

## R2

### [严重] `set<InputStream>` 参数路径会一次性分配 `Int64.Max` 字节

- **位置**：`f_dbd/src/common/types.cj:452`（`readChunk(x, Int64.Max)`）→ `f_dbd/src/common/types.cj:398-413`（`readChunk`）
- **描述**：`encodeParameter` 把 `InputStream` 参数交给 `readChunk(x, Int64.Max)`；`readChunk` 第一行即 `Array<Byte>(want - got, repeat: 0)`，`want = Int64.Max`。结果是每次把流当参数绑定都试图申请约 9.2 EB 内存（`OutOfMemory`/构造失败），且循环内每轮都重新申请「剩余全部」大小，正常大流也退化为 O(n²) 拷贝。该路径同时被 `DbdStatement.setSqlDbType` 的 `SqlBlob`/`SqlClob` 分支（`DbdStatement.cj:215,219`）使用。全库无一条用例覆盖 `set<InputStream>`（`f_dbd/src/driver/DbdStatement_test.cj` 内无 `InputStream` 参数），因此该缺陷从未被触发暴露。

### [严重] `IdGeneratorException` 无消费者侧映射：文档约定抛它，实际回 `INTERNAL`

- **位置**：`f_dbm/src/IdGenerator.cj:42-49`（默认实现）↔ `fdbm/src/server/handler.cj:41-47`（异常→错误码）；触发点 `fdbm/src/execute/executors.cj:743-750`
- **描述**：`f_dbm` README 与类注释要求「生成器实现应抛 `IdGeneratorException`」（`f_dbm/README.md:28`、`IdGenerator.cj:21-24`）。但 `fdbm` 全仓 `grep IdGeneratorException` 命中 0 处：`FdbmHandler.handle` 只区分 `FdbmException` / `SqlException` / `Exception`，而 `IdGeneratorException <: BaseException <: Exception`（`f_base/src/BaseException.cj:44`），于是落到 `catch (e: Exception)` → `errorOf(..., DbdErrorCode.INTERNAL, ...)`。更直接的是组合路径：`InsertExecutor.idLiteral` 按**算法名**决定调 `nextIntId()` 还是 `nextStringId()`（`executors.cj:745-749`），而默认 `fdbm_idmaker=uuid,1` 的 `UuidIdGenerator` 只实现 `nextStringId()`（`fdbm/src/idmaker/IdMakers.cj:30-55`）；因此「`fdbm_partition__t=db0,step,id` + 默认 idmaker」这一合理配置会在每次缺列 INSERT 时调用 `nextIntId()` 默认实现 → 抛 `IdGeneratorException` → 客户端收到 `INTERNAL`（而非文档口径的 `ID_GENERATOR`）。同一规则也让「自定义生成器只支持一种 ID」的用法必然返回 `INTERNAL`。该约定在 f_dbm 与 fdbm 两侧都没有任何用例。

### [严重] `DbdUrl` 混用字节下标与字符下标：非 ASCII 凭据被静默截断、非 ASCII 库名直接失败

- **位置**：`f_dbd/src/driver/DbdUrl.cj:180-190`（`take` 按 `toRuneArray()` 取字符）、`DbdUrl.cj:62-111`（调用方传入的 `indexOf`/`lastIndexOf` 返回值）、`DbdUrl.cj:197-218`（`percentDecode` 逐字节 `Rune(UInt32(n))`）
- **描述**：
  - 仓颉 `String` 的 `size`、`[]`、切片、`indexOf` 全部按 **UTF-8 字节**计（std 文档 `core_package_structs.md` §`struct String` 明确说明），而 `take()` 用 `toRuneArray()` 的**字符**下标；两者只在纯 ASCII 前缀下等价。`DbdUrl.cj:236-240` 的注释「仓颉 `String` 没有切片/子串 API」也不成立（同仓库 `MultiDUrl.cj:57,105,116` 就在用 `s[a..b]`）。
  - 实例如 `fdbm://u:密@host:9000/db`：`lastIndexOf('@')` 返回字节 5，`take(authority, 0, 5)` 却取前 5 个**字符** `"u:密@h"`，切出 `user="u"`、`password="密@h"` —— 密码被静默污染（今日凭据只进 `getMetaData`，故不报错；鉴权上线后即变成难以定位的认证失败）。非 ASCII 用户名或库名则因 `start > end` 得到空串，抛 `CONFIG: database is empty`（合法 URL 被拒）。
  - `percentDecode` 对 `%E5%AF%86` 逐个十六进制字节造 `Rune(0xE5)`/`Rune(0xAF)`/`Rune(0x86)`，再拼回 `String` 时每个 Rune 重新编码为 UTF-8，多字节字符被放大错乱；`percentEncode` 侧是字节正确的（`DbdUrl.cj:225-250`），故 `parse(toUrl(x))` 对非 ASCII 不成立，与 README「凭据支持 `%XX` 编码」（`f_dbd/README.md:38-39`）相悖；`%FFFFFF` 之类还会让 `Rune(UInt32)` 抛非 `DbdException` 异常。
  - `DbdUrl_test.cj` 13 条用例全部 ASCII，无一覆盖上述路径。

### [严重] 内置与自定义分区算法重名未拒绝，实现静默覆盖内置（与文档承诺相反）

- **位置**：`f_dbm/README.md:59`（「与内置重名同样拒绝，不允许覆盖」）、`fdbm/src/config/FdbmConfig.cj:421-429`（`validatePartitions` 只做并集，无冲突判定）、`fdbm/src/route/algorithms.cj:288-294`（工厂「先查自定义（同名可覆盖内置）」）
- **描述**：`f_dbm` 给第三方的加载约定第 3 条承诺「自定义之间重名 → `CONFIG`/`PARTITION_CONFIG`；与内置重名同样拒绝，不允许覆盖」；`fdbm/doc/详细设计.md` §10.5 同样写「与内置……重名由 `FdbmConfig.validate` 拒绝……**不允许覆盖内置实现**」。实际 `validatePartitions` 把 `BUILTIN_ALGORITHMS` 与 `customAlgorithms` 直接并成 `known` 集合（无交集检查），`CustomLoader` 也只拒绝自定义之间的重名；而工厂 `create` **先**查 `custom.get(name)`。因此一个名为 `hash` 的扩展库会被接受并在运行期悄悄替换内置 `hash`，所有按该算法的分库写入都会改落到另一物理库——按 README 部署的人完全不会预期这一点，且没有任何测试覆盖「内置名冲突」场景。

### [一般] f_dbm 零测试：扩展契约的默认行为与异常类型完全无回归

- **位置**：`f_dbm/`（无任何 `*_test.cj`）；`f_dbm/src/IdGenerator.cj:42-49`；`f_dbm/src/PartitionAlgorithm.cj:25-31`
- **描述**：`f_dbm` 是第三方扩展的唯一契约面（`README.md:3-5`），但两个接口、默认方法、异常类型均无用例（矩阵 D 全 ❌）。`f_dbd/doc/spec/.../tasks.md:126` 与 `fdbm/doc/开发计划.md:199-203` 都把「默认实现抛 `IdGeneratorException`」「message 保真」列为计划内的用例，属未兑现的交付项；也因此 [严重] 第 2 条（异常未被映射）在两侧都没有任何自动化门槛。仓库内 `f_app`/`f_health` 同样无测试，故不按「严重」计，但 `f_dbm` 有明确的契约与计划要求，应补齐。

### [一般] `encodeParameterUnsupportedTypeThrows` 名实不符，`unsupported parameter type` 分支零覆盖

- **位置**：`f_dbd/src/common/sqltypes_test.cj:140-149`（用例）、`f_dbd/src/common/types.cj:453-454`（被测分支）
- **描述**：用例名叫「不支持类型应抛」，实现却断言 `@Assert(!threw)`（第 148 行）。原因是用 `SqlPayload('x')` 作探针，而 `SqlPayload` 实现 `ToData`，会命中 `types.cj:453` 的 `case x: ToData` 兜底而不抛异常；真正该覆盖的 `types.cj:454`（`_ => throw DataException('unsupported parameter type ...')`）在全仓没有任何用例，`DbdStatement.encode` 把它包成 `CONVERSION` 的那层（`DbdStatement.cj:198-205`）只被 `NotEncodable` 一条用例覆盖（`DbdStatement_test.cj:83`）。

### [一般] f_dbd 测试套件依赖环境变量 `dbd_driverName=fdbm`，且断言值与文档推荐值相反

- **位置**：`f_dbd/src/driver/DbdDriver.cj:53-56`（`static init` 读配置注册）、`DbdDriver.cj:108-117`（未配置即 `exit(1)`）、`f_dbd/src/driver/DbdDriver_test.cj:31-41`（断言 `name == 'fdbm'`、`getDriver('fdbm')` 非空）
- **描述**：`DbdDriver` 的注册名取自 `dbd_driverName`，未配置或为空时在 `static init` 阶段 `exit(1)`；而 f_dbd 内没有任何 `Config.set('dbd_driverName', ...)`（`grep` 全模块只有 `multidbm_*`），仓库脚本也未导出该变量。于是 `README.md:72-76` 给出的 `cjpm test` 在干净环境会在包初始化时终止整个测试进程；反过来，若按文档 `export dbd_driverName=postgres`（`README.md:44-46`、`详细设计.md:570-577`）运行，`registersItself` 里 `@Assert(driver.name, 'fdbm')` 与 `DriverManager.getDriver('fdbm')` 会直接失败。`tasks.md:185` 记录的「180 条全绿」只能在 `dbd_driverName=fdbm` 这一未文档化的前提下复现。

### [一般] 类型矩阵测试显著少于 spec 承诺（「§8 每种受支持类型」）

- **位置**：`f_dbd/src/common/sqltypes_test.cj:134-138`（编码）、`sqltypes_test.cj:246-253`（`readData`）、`f_dbd/src/common/result_test.cj:201-220`（`everyTypeReadsBack`）；对应承诺 `f_dbd/doc/spec/.../specs/f-dbd/spec.md:209-213`
- **描述**：spec 的「表驱动编码」要求 §8 左列**每种**类型都有用例；实际 `encodeParameter` 只断言 `Bool`/`Int64`/`String`，`readData` 只断言 `Int64`/`String`/NULL，`QueryResultImpl.get<T>` 只覆盖 7/16 个具体类型（缺 `Rune` 之外的 `Int16`/`Int32`/`UInt*`/`Float32`/`Decimal`/`BigInt`/`Duration`）。这些分支的代码是逐个 `case` 手写的（`types.cj:348-369`、`result.cj:220-239`），错一行不会有任何用例失败；上述 [严重] 第 1 条正是藏在这片空白里。

### [一般] `nullShortCircuit` 无任何断言（无效测试）

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:123-135`
- **描述**：该 `@TestCase` 体内只有 `println`，`shortCircuitOf` 用 `timed`（不做 witness 校验），也不比对各 `T` 的计时关系。用例除了「不崩溃」不验证任何东西，且每次 `cjpm test` 都会把基准表打进测试输出。

### [一般] 公开行为缺口清单（无用例的直接路径）

- **位置**：
  - `f_dbd/src/driver/DbdStatement.cj:52-56` `parameterColumnInfos` 恒为空数组 —— 无用例（spec 未承诺，但属 `Statement` 接口可见行为）。
  - `f_dbd/src/driver/DbdStatement.cj:150-155` `close()` 后 `query()/update()` → `CURSOR_STATE` —— 无用例（`prepareStatementIsLocal` 只测了 `isClosed()`）。
  - `f_dbd/src/driver/DbdStatement.cj:104-113` `update()` 载荷不符 → `PROTOCOL` —— 只测了 `query()` 侧。
  - `f_dbd/src/driver/DbdStatement.cj:115-118` `update_timeout` 生效 —— 只测 `query_timeout`。
  - `f_dbd/src/driver/DbdStatement.cj:211-253` `setSqlDbType` 的 `case _`（未支持 `SqlDbType` → `CONVERSION`）与 `SqlBlob`/`SqlClob` —— 无用例。
  - `f_dbd/src/driver/DbdTransaction.cj:92-108` `save/rollback(name)/release` 在未 `begin` 时 → `TX_STATE` —— 只测了 `commit`/`rollback`。
  - `f_dbd/src/common/result.cj:320-340` `requestBlock` 载荷解不出 `Array<Byte>` → `CONVERSION` —— 无用例。
  - `f_dbd/src/common/result.cj:260-271` `runeOf` 多字符/空串 → `CONVERSION` —— 只测了单字符成功路径。
  - `f_dbd/src/common/result.cj:373-380` `read(空 buffer)` 返回 0 —— 无用例。
  - `f_dbd/src/driver/DbdOptions.cj:69-81` 超时配置为 `0`/负数/非数字时的行为（负数 → 变成 `NO_TIMEOUT` 6 小时，而非「不限时/报错」）—— 无用例；`copy()` 的隔离性也无直接用例。
- **描述**：以上均为对外可见的错误码/分支，且多数是 fail-fast 契约的一部分（`spec.md:287-303`）；缺失使这些分支只有在生产事故中才会被首次执行。

## R3

### [严重] 逻辑库集合被自动填入物理库名，导致会话默认库错位、分库规则整体失效

- **位置**：`fdbm/src/config/FdbmConfig.cj:519-529`、`fdbm/src/config/settings.cj:109-117`
- **描述**：
  - `logicalDatabases()` 在读完 `fdbm_db_logicalDatabase_<logical>` 后，额外把**每一个物理库名**也注册成一个逻辑库（`if (!logicals.contains(database)) logicals[database] = all`）。于是：① 只要配置了 `fdbm_db_logicalDatabase_order='db_0,db_1,db_2,db_3'`（设计 §10.6 与随包 `boot.sh:50` 的示例），`logicals` 就至少有 4 个 key（`order` + `db_0..db_3`），`logicals.size == 1` 永不成立；② `defaultDatabaseOf` 走 `nodes[0].databases[0]`，会话当前库变成**物理库名** `db_0`；③ 路由器按 `(currentDatabase, table)` 查规则（`route/router.cj:143`），`('db_0','orders')` 查不到 `('order','orders')`，于是该表被当成「未分库表」，`PartitionRouter.route` 走 `Single(physicals[0])`（`route/router.cj:166-172`）；④ 结果：所有不带 `order.` 限定的读写全部静默落到 `db_0`，水平分库完全失效，且**没有任何错误或日志**。
  - 证据：`fdbm/test/e2e/backends/mysql.sh:92` 把逻辑库名故意取成物理库名 `db0`（`fdbm_db_logicalDatabase_db0=$DB_LIST`），`fdbm_db_database_name0=db0,db1,db2,db3`，从而让 `defaultDatabase == 'db0'` 与规则 `fdbm_partition__t_step="db0,step,id"` 恰好对上；`Integration_test.cj:221-242` 也只有物理库名、没有逻辑库映射。两套测试都因此绕开了该缺陷。
  - 连带现象：`SHOW DATABASES` 永远看不到 `order`；`show tables`（无参，取 `session.database='db_0'`）反而可用，但 `show tables order` 报 `ROUTE_FAILED`。

### [严重] `UuidIdGenerator` 的 v1/v6 时间戳恒为 0，且每生成一个 ID 新建一个临时目录与文件

- **位置**：`fdbm/src/idmaker/IdMakers.cj:46-53`
- **描述**：
  - `case 6 => UUID.timeBased().randomNode().toString()` / `case _ => UUID.timeBased(timeLowFirst: true).registerFileSequenceGenerator().randomNode().toString()`。`f_util` 的 `TimeBasedUUIDBuilder` 只有 `randomSeq`/`serialSeq` 两个属性会调用 `genTimestampAndSequence`（`f_util/src/uuid.cj:477-501`），而 `randomNode()`/`node()`/`generate()` 直接使用 `timestamp`、`seq` 字段（`uuid.cj:585-600`）。本实现从未触发时间戳/序列生成，因此 v1/v6 的 `time_low/time_mid/time_hi` 与 clock_seq **恒为 0**，UUID 之间只靠 6 字节随机 node 区分——v1/v6 的时间有序语义完全丢失（设计 §7 明确要求 v6 用 `UUID.timeBased()`）。
  - 另外 `registerFileSequenceGenerator()` 每次调用都会 `Directory.createTemp('/tmp')` + 建文件（`f_util/src/uuid.cj:650-655`），而本路径生成的 builder 用完即弃，只靠 `TimestampSequenceBuilder` 的 `~init()` 在 GC 时关文件、临时目录永不删除。设计默认 `fdbm_idmaker=uuid,1`（`详细设计.md:107`），即「INSERT 缺分库列值」这条高频路径每生成一个 ID 就在 `/tmp` 留一个目录与文件，长时间运行会耗尽 inode。

### [一般] `SHOW DATABASES` / `SHOW TABLES` 只认物理库名，与「列出逻辑库」的文档承诺不符

- **位置**：`fdbm/src/execute/executors.cj:860-892`（`Databases` 分支取 `resources.databases()`；`Tables` 分支用 `resources.contains(database)` 校验）
- **描述**：设计 §8.1 要求 `SHOW DATABASES` 列出**全部逻辑库名**、§9.5 要求返回「`fdbm_db_logicalDatabase_*` 与节点配置推导出的逻辑库集合」。`ShowExecutor` 只持有 `NodeAccessor`（物理库视图），拿不到 `FdbmSettings.logicalDatabases`；`SHOW TABLES <logical>` 用 `contains()` 判定，逻辑库名会被判为「unknown database」并回 `ROUTE_FAILED`。此前 e2e/集成用例的库名恰好同形，掩盖了该问题。

### [一般] 未配置的逻辑库未按设计「隐式包含全部物理库」展开，分区规则在启动自检被拒

- **位置**：`fdbm/src/config/FdbmConfig.cj:506-531`、`fdbm/src/config/FdbmConfig.cj:434-437`
- **描述**：设计 §3.1 规定「未配置的逻辑库视为包含全部物理库」。实现只把**物理库名**补成逻辑库，任意逻辑名（如 `order`）若没有对应的 `fdbm_db_logicalDatabase_order`，就不会出现在 `logicals` 里，于是 `validatePartitions` 的 `if (!logicals.contains(rule.database))` 直接抛 `PARTITION_CONFIG`，进程起不来。也就是说「只写一条 `fdbm_partition__orders='order,hash,id'`」这种符合文档的最简配置无法启动。

### [一般] 自定义扩展与内置名称重名未被启动自检拒绝，可静默覆盖内置实现

- **位置**：`fdbm/src/config/FdbmConfig.cj:420-454`（`validatePartitions`）、`fdbm/src/config/FdbmConfig.cj:456-493`（`validateIdMaker`）、`fdbm/src/server/CustomLoader.cj:92-114`
- **描述**：`CustomLoader` 只拒绝「自定义之间」重名；`validate` 把内置名与自定义名合成一个 `known` 集合，只校验「配置里引用的名字是否在集合中」，**从不检查自定义名是否与内置名相同**。而 `PartitionAlgorithmFactory` 先查自定义（`详细设计.md:419`），`IdMakers.forTable` 也先查 `custom.get(config.kind)`（`IdMakers.cj:184-186`），因此一个名为 `hash`/`uuid` 的扩展库会**静默替换**内置实现。设计 §10.5/§11 明确「不允许覆盖内置实现，启动失败」。

### [一般] `fdbm_global__<table>` 的逻辑库未做启动校验，错误推迟到运行期

- **位置**：`fdbm/src/config/FdbmConfig.cj:201-218`、`fdbm/src/config/FdbmConfig.cj:345-379`（`validate` 未涉及 `confs.globalTables`）、`fdbm/src/route/global.cj:59-64`
- **描述**：`validate` 只校验 `confs.partitions` 的逻辑库引用，全局表配了不存在的逻辑库（`fdbm_global__dict='cfg'` 而 `cfg` 既不是逻辑库也不是物理库）时启动照常成功；运行期 `GlobalTableRouter.physicalDatabases('cfg')` 返回空数组，路由退化为 `Unroutable`/空广播，客户端只看到 `ROUTE_FAILED`。设计 §11 的「引用完整性」应覆盖这一类。

### [一般] `sequence` 启动自检缺少 `fountain_sequence` 表存在性检查

- **位置**：`fdbm/src/config/FdbmConfig.cj:479-484`
- **描述**：设计 §11 与 spec「启动自检失败即结束进程」要求「`fdbm_idmaker=sequence` 但分配库中不存在 `fountain_sequence` 表 → `ID_GENERATOR`，退出码非 0」。实现只校验 `sequenceDatabase` 是已知物理库（不存在时也报 `ID_GENERATOR`，但语义不同），表缺失要等第一条缺分库列值的 INSERT 才在 `readSequence` 抛出。开发计划「阶段 6」也要求该负例。

### [一般] `fdbm_sequenceDatabase` 的「逻辑库 vs 物理库」口径自相矛盾

- **位置**：`fdbm/src/config/FdbmConfig.cj:325-337`、`fdbm/src/config/FdbmConfig.cj:479-484`；（文档侧）`fdbm/doc/详细设计.md:119`、`fdbm/doc/详细设计.md:1089`、`fdbm/boot.sh:80`
- **描述**：文档 §3.1 说默认值是「逻辑库的第一个物理库」，§10.6 的 `boot.sh` 示例直接写 `export fdbm_sequenceDatabase='order'`（逻辑库名）；实现 `getSequenceDatabase` 默认取 `nodes[0].databases[0]`（第一个节点的第一个物理库，可能与目标逻辑库的物理库集合不相交），`validateIdMaker` 又要求该值**必须是物理库名**（`databases.contains`）。按文档示例配置 `order` 时启动直接失败。随包 `boot.sh:80` 已改成物理库 `db_0`，与 §10.6 示例不一致。

### [一般] 连接池异常未映射为 `TIMEOUT`/`IO`，池耗尽统一变成 `INTERNAL`

- **位置**：`fdbm/src/resources/DatabaseResources.cj:146-162`、`fdbm/src/server/handler.cj:45-47`
- **描述**：设计 §5 明确「池耗尽等待超时同样表现为 `ConnectionException`（映射 `TIMEOUT`）」，开发计划 Step 4.2 也要求「池耗尽 → `TIMEOUT`」用例。实现里 `selectRead`/`selectWrite`/`selectAllWrite` 直接透传 `f_dbpool` 的 `ConnectionException`，全仓 `fdbm/src` 没有任何 `ConnectionException` 捕获（`grep` 为空），最终落到 handler 的 `catch (e: Exception)` → `DbdErrorCode.INTERNAL`。`DbdErrorCode.TIMEOUT` 在 fdbm 内**零引用**，`CACHE` 同样零引用。

### [一般] `normalize()` 对「区块内外同键」的优先级与设计相反，且不记 WARN

- **位置**：`fdbm/src/config/BootScriptWriter.cj:343-379`（尤其 357-374 的区块外覆盖）
- **描述**：设计 §3.5「启动时自动整理」明确「同一键同时出现在区块内外时，**区块内优先**，记 WARN」。实现先把区块内可写键读入 `entries`，随后扫描区块外顶层 `export fdbm_*` 时执行 `entries[key] = value`，**区块外覆盖区块内**，且没有任何 WARN。运维手工在区块外补的一行会静默改写 managed 区块里的值，与「区块由 fdbm 独占、区块内为准」的模型冲突。

### [一般] `BootScriptWriter` 非线程安全：并发 `export` 会竞争 `pending` 与固定 `.tmp` 文件名

- **位置**：`fdbm/src/config/BootScriptWriter.cj:76`（`private let pending = HashMap<...>`）、`fdbm/src/config/BootScriptWriter.cj:87-94`（`set`）、`fdbm/src/config/BootScriptWriter.cj:96-127`（`flush`）、`fdbm/src/config/BootScriptWriter.cj:440-460`（`writeAtomically`，`'${target}.tmp'`）
- **描述**：`ExportExecutor` 在 f_net 的线程池上并发执行（`executors.call`），同一进程的多条 `export` 会同时 `set`/`flush`：`HashMap` 并发写无保护（可能破坏内部结构），两次 `flush` 共用同一个 `boot.sh.tmp` 并各自 `rename`（后写者覆盖，甚至 `rename` ENOENT 抛 `CONFIG`）。设计未提及并发约束，但服务端是对多连接并发的。

### [一般] `FdbmServer.start()` 吞掉监听循环异常，进程以退出码 0 结束

- **位置**：`fdbm/src/server/FdbmServer.cj:135-143`
- **描述**：`server.start {...}` 抛异常时只 `logger.error` 后正常返回，`main()` 随后 `return 0`。此时服务已不再接受连接，但 `boot.sh status`/容器编排看到的是「正常退出」，与 README「启动失败 → 退出码 1」以及开发计划 Step 8.4「启动自检失败 → 返回 1」不符。`boot.sh start` 只在「启动 10s 内进程消失」时判失败，接入 supervisor 时会被反复重启/误判。

### [一般] 优雅停止丢弃 `closeAndAwait` 结果，超时/异常无任何 WARN 日志

- **位置**：`fdbm/src/server/FdbmServer.cj:163`、`fdbm/src/resources/DatabaseResources.cj:226-241`
- **描述**：设计 §10.4 第 4 步要求「逐池 `closeAndAwait`，未按期终止则记 WARN 并继续收尾」。`FdbmServer.stop()` 丢弃返回值；`DatabaseResources.closeAndAwait` 对每个池 `catch (_: Exception) { all = false }` 也不记日志，`PartitionCache.close`/`DatabaseResources.close` 同样静默吞异常。关停期的连接未归还、池未终止在日志中完全不可见，事故排查只能靠猜。

### [一般] 会话游标状态无并发保护：巡检/关停与请求处理可能竞争

- **位置**：`fdbm/src/server/SessionRegistry.cj:112-142`（`sweep` 先摘表再 `session.close()`）、`fdbm/src/server/handler.cj:74-92`（`executeSql` 写 `session.cursor`）、`fdbm/src/execute/session.cj:49-79`（`DbdSession.cursor` 为普通 `var`）
- **描述**：`DbdSession.cursor` / `pinned` 是普通字段，读写分别发生在 f_net 的 executor 线程（handler）和 `Timer` 线程（`sweep`）/ 信号处理线程（`closeAll`）。典型交错：`sweep` 判定连接已关闭并把会话从表里摘掉 → 同时一个已受理的请求执行完查询，`session.cursor = Some(cursor)` 写回一个已「不存在」的会话 → 该游标再也不会被关闭，其持有的 `PooledConnection` 泄漏（`closeAndAwait` 随之超时）。`closeCursor` 与 `closeSessionCursor` 也存在同一把游标被两边 `close()` 的可能。

### [一般] `PartitionCache` 关闭标志非原子，关闭后静默降级

- **位置**：`fdbm/src/route/cache.cj:52-60`（`get` 读 `closed_`）、`62-85`（`put` 读 `closed_`）、`118-120`（`isClosed`）
- **描述**：`closed_` 是普通 `Bool`，在 `stop()`（信号线程）里被置位，同时在多个执行器线程里被读取，无锁也无 `AtomicBool`（同文件的 `count_` 另有保护，对比 `DatabaseResources.closed` 用了 `AtomicBool`）。此外关闭后 `get` 返回 `None`、`put`/`remove` 直接 `return`，调用方无法区分「未命中」与「缓存已关闭」；开发计划 Step 5.3 明确要求「关闭后 `get` 抛 `FdbmException(CACHE)`」，且 `DbdErrorCode.CACHE` 在 fdbm 内零引用。

### [一般] 启动失败路径未释放已创建的资源

- **位置**：`fdbm/src/server/FdbmServer.cj:64-100`（`PartitionCache` 在驱动校验/`DatabaseResources` 之前创建）、`fdbm/src/resources/DatabaseResources.cj:57-97`（构造中途 `driver.open`/`DatabasePool` 抛异常时已建池不回收）
- **描述**：`FdbmServer` 构造顺序是「缓存 → 路由 → 驱动 → 资源」，任一后续步骤抛错（典型：`NO_DRIVER`、某个节点连不通导致 `DatabasePool` 构造失败）时，已打开的 `f_store`（含后台 compaction 线程）与已建好的 `DatabasePool` 都不会被关闭；`DatabaseResources` 自身在循环中途抛错也会遗留前几个池。进程随后 `exit(1)` 由内核兜底，但在「进程内嵌 `FdbmServer` + 重试」的用法（构造函数支持 `driver!` 注入，说明存在这种用法）下就是泄漏。

## R4

### [严重] 非字符串/数值类型的参数绑定后渲染成裸文本，产生非法 SQL

- **位置**：`fdbm/src/sql/SqlRenderer.cj:348-355`（`literal()` 的 `case other => other.toString()`）、`fdbm/src/sql/ParameterBinder.cj:142`
- **描述**：`ParameterBinder` 直接把 `DataAny.data` 塞进 `LiteralExpression`，`SqlRenderer.literal` 只对 `DataString` / `DataReal` / `DataBool` / `DataNone` 有分支，其余类型走 `other.toString()`。协议层 `SqlPayload.add<T>(param: T) where T <: ToData`（`f_dbd/src/common/payload.cj:41-43`）允许任意 `ToData`，因此以下参数都会生成**语法非法**的下推 SQL：`DateTime` → `where created_at = 2026-10-21T06:49:00+08:00`（未加引号、未按方言转义）；`Duration` → `=1d`；`Array<Byte>` / 大对象 → 数组文本（且未做十六进制/bytea 处理）；`DataUnit`、`DataList`/`DataMap` 等 → 集合的调试文本。这类错误发生在**渲染之后**，最终以物理库的语法错误（`DB_ERROR`）返回，错误码与文案都不会指出「参数类型不支持」。现有用例只覆盖了 `DataReal` / `DataString`（`SqlSupport_test.cj:31-32`、`62-66`），因此未被发现。

### [严重] 数值字面量经 `Float64` 中转，大整数与高精度小数被静默改写

- **位置**：`fdbm/src/sql/SqlParser.cj:742-755`（`numberOf`）、`fdbm/src/sql/SqlParser.cj:757-770`（`negatedNumberOf`）
- **描述**：解析路径是「`Int64.tryParse` 成功则 `DataReal(Int64)`，否则 `Float64.tryParse` → `DataReal(Float64)`」。于是：`insert into t (amount) values (12345678901234567890)` → 超出 `Int64`，落到 `Float64`，再 `Decimal(Float64)`，写成 12345678901234567000 之类的近似值；`values (123456789012345678.90)` → `Float64` 只有约 15~17 位有效数字，小数部分被破坏。该值随后由 `SqlRenderer.literal` 原样下推写入物理库，属于**静默的数据失真**（无错误码、无日志）。`f_data` 已提供 `DataReal(data: String)`（`f_data/src/base/DataReal.cj:68-70`，内部走 `Decimal.parse`），实现没有利用。

### [严重] 派生表形状校验只覆盖 SELECT 的 `from` 列表，JOIN 与 UPDATE/DELETE 中的派生表被放行

- **位置**：`fdbm/src/sql/SqlParser.cj:247-294`（`validateSelectShape`，统计只遍历 `statement.from`，`derivedCount == 0` 时在 `273` 直接返回）；`fdbm/src/sql/SqlParser.cj:348-367`（`joinClause` 复用 `tableRef()`，允许派生表）；`fdbm/src/sql/SqlParser.cj:449-499`（`update`/`delete` 完全不调用形状校验）
- **描述**：设计 §8.1/§8.2 与错误码表明确要求「派生表外层只允许『唯一派生表 + 列清单 + 可选 limit/offset』」「派生表外层带 where / JOIN / order by / distinct / group by → `UNSUPPORTED_SQL`」。实际实现只对 `from` 列表计数，以下语句都能通过解析：`select * from u join (select * from t where id = 5) c on u.tid = c.id`（派生表在 JOIN 中）；`update t join (select * from u) x on t.id = x.id set t.name = 'a'`；`delete from t join (select * from u) x on t.id = x.id`。后果有三层：① 错误码从 `UNSUPPORTED_SQL` 变成执行期的广播 / `ROUTE_FAILED`；② `PartitionRouter.selectConstraint`（`route/router.cj:285-293`）只沿 `statement.from` 递归，JOIN 中的派生表条件被完全忽略，SELECT 会走 `Unroutable → 全库广播`，跨分片 JOIN 的结果可能静默缺行；③ 派生表 `TableRef` 的占位 `name` 是 `''`（`fdbm/src/sql/SqlParser.cj:790`），`UpdateStatement.tables` / `DeleteStatement.tables`（`ast.cj:389-398`、`418-427`）不做 `collectTables()` 展开，空表名会进入路由查规则。现有用例 `SqlFeature_test.cj:194-205` 只覆盖了「外层 from 为派生表 + join」的反向形状，未覆盖「派生表位于 join」。

### [一般] `WHERE` 中的非派生表子查询返回 `SQL_SYNTAX`，与设计要求的 `UNSUPPORTED_SQL` 不符

- **位置**：`fdbm/src/sql/SqlParser.cj:633-642`（`inExpression` 直接 `expression()`）、`fdbm/src/sql/SqlParser.cj:731-736`（`factor` 把 `select` 当普通标识符）
- **描述**：设计 §8.1 写明「派生表以外的子查询 … 一律不支持 → 报 `UNSUPPORTED_SQL`（错误文案给出语句位置）」，主规范 `fdbm/spec.md:392` 同款要求。实际行为：`select * from t where id in (select id from u)` → `inExpression` 把 `select` 解析成 `ColumnExpression`，随后 `expect(RParen)` 失败，抛 `SQL_SYNTAX`；`select * from t where exists (select 1 from u)`、`select (select 1)` 同样落到 `SQL_SYNTAX`。用例 `SqlParser_test.cj:183-188` 只验证了 `union` 与 `group by`，没有覆盖子查询。

### [一般] 引用别名与库限定名的引用符在 AST/渲染中丢失，`parse → render → parse` 不闭合

- **位置**：`fdbm/src/sql/SqlRenderer.cj:56-59`（`SelectItem.alias` 直接拼裸名）、`fdbm/src/sql/SqlRenderer.cj:268-275`（`table.database` 与 `table.alias` 直接拼接）、`fdbm/src/sql/ast.cj:274`（`SelectItem.alias: ?String`）、`fdbm/src/sql/ast.cj:192-210`（`TableRef` 只记录表名 `quoted`）
- **描述**：解析器允许引用别名（`expectIdent` 接受带引号的 `Ident`），但 AST 只保存裸字符串，渲染时不再加引用符。于是：`select id as "order" from t` → 渲染 `select id as order from t`，再次解析即语法错误；`select * from "shop"."T" as "select"` → 渲染 `shop.T as select`：schema 的引用符丢失导致 PostgreSQL 折叠成小写，语义改变甚至找不到表；别名同样丢失。`SqlSupport_test.cj:180-203` 的往返用例只用了未引用的别名与未限定的表名，因此未暴露。

### [一般] `ColumnExpression` 只有一个 `quoted` 标志，渲染时把表名一起引用

- **位置**：`fdbm/src/sql/SqlRenderer.cj:288-303`；来源 `fdbm/src/sql/ast.cj:95-106`、`fdbm/src/sql/SqlParser.cj:731-735`（`quoted: token.quoted || column.quoted`）
- **描述**：`select t."COL" from t` 解析后 `quoted = true`（来自列名），渲染成 `"t"."COL"`。表名本来未引用，改写后在 PostgreSQL 里表名保持大小写（原本裸名会被折叠），语义被改变；`"T".COL` 同理变成 `"T"."COL"`，把列名也强制成区分大小写。这是「只重写引用标识符的引用符」原则的偏差（设计 §8.2 末段）。

### [一般] 标识符比较大小写敏感，导致 `WHERE ID = 5` 这类语句无法路由（DML 直接失败）

- **位置**：`fdbm/src/sql/ast.cj:85-91`（`Identifier.==` / `equalsName` 精确比较）、`fdbm/src/sql/PartitionKeyExtractor.cj:92-108`（`c.column != column`）、调用方 `fdbm/src/route/router.cj:297`（传 `rule.table`）与 `router.cj:349`（`statement.columns[i].name == rule.column`）
- **描述**：设计 §8.2 声明「标识符大小写不敏感（保留原始拼写用于下推 SQL）」。实现只对关键字做了 `toUpper`，标识符一律精确比较。MySQL 的列名本身大小写不敏感，客户端写 `update t set name='x' where ID = 5` 完全合法，但 fdbm 抽不到分库键 → `UPDATE` 判 `Unroutable` → `ROUTE_FAILED`；`INSERT INTO t (ID) VALUES (5)` 同样失败。SELECT 则退化为全库广播（结果正确但代价高）。测试没有覆盖任何大写标识符。

### [一般] 别名限定的分库键抽取不到（`from users u where u.id = 5` 被判不可路由）

- **位置**：`fdbm/src/sql/PartitionKeyExtractor.cj:98-105`、调用方 `fdbm/src/route/router.cj:297`（`Some(rule.table)`）
- **描述**：`matches` 要求限定名与传入的 `table` 完全相等，而路由器传入的是规则里的**裸表名**。当语句使用别名并以其限定分库列（ORM 生成的 SQL 很常见）时，`u.id` ≠ `users` → 抽不到值 → `UPDATE`/`DELETE` 报 `ROUTE_FAILED`，SELECT 全库广播。用例 `SqlSupport_test.cj:91-95` 通过手工传 `Some('x')` 演示了「别名可用」，恰好掩盖了调用方不会传别名的事实。

### [一般] MySQL 家族字符串参数只做 `''` 转义，未处理反斜杠

- **位置**：`fdbm/src/sql/SqlRenderer.cj:358-360`（`quoteText`）
- **描述**：MySQL 默认 `sql_mode` 下反斜杠是字符串转义符。参数值以 `\` 结尾时（如 Windows 路径 `C:\`），`'\'` 会把闭合引号转义掉，字面量无法闭合，语句报语法错误；值中含 `\'` 组合时字面量边界会偏移（参数由发起 SQL 的同一客户端提供，因此不构成越权注入，但会破坏合法数据/语句）。

### [一般] 逻辑库限定名原样下推，未按目标物理库重写（跨层，需与执行层确认）

- **位置**：`fdbm/src/sql/SqlRenderer.cj:268-271`（`table.database` 直接拼接）、`fdbm/src/execute/executors.cj:224`（对每个物理库复用同一份渲染结果）
- **描述**：`TableRef.database` 是**逻辑库**（`PartitionRule.database`，配置项 `fdbm_db_logicalDatabase_<logical>` 与 `fdbm_db_database_<node>` 是两套名字，见设计 §3.1）。渲染器把它原样写进 SQL，执行器却把同一份 SQL 发到各物理库连接。只要逻辑库名 ≠ 物理库名且客户端显式限定了库名（`select * from shop.t where id = 1001` 命中物理库 `db1`），下推语句会去读 `shop.t` 而不是 `db1.t`：轻则报表不存在，重则读到错误分片的数据。E2E 全部使用未限定表名（`fdbm/test/e2e/client/src/main.cj`），因此未覆盖。

## R5

### [严重] S1: 事务 pin 下多目标路由未拒绝，同一 SQL 在同一个 pin 连接上重复执行

- **位置**：`fdbm/src/execute/executors.cj:429-441`（UPDATE）、`:493-504`（DELETE）、`:523-524`（DELETE 查键）、`:228-231`（SELECT 多段）
- **描述**：`borrow()`（`:68-80`）在 `session.pinned.isSome()` 时无条件返回 pin 连接并标记 `owns=false`。于是 `plan.kind == Multi`（IN 列表 / step 范围命中多片）或 `Unroutable` 的 SELECT 广播时，循环里每个「物理库」实际拿到的都是同一个 pin 连接：UPDATE/DELETE 会在**同一物理库**上执行 N 次，`rowCount` 被累加 N 倍，其余分片的数据根本没有被修改，客户端却收到成功；SELECT 会同一结果集被打开 N 次（部分驱动会直接报「结果集独占」），或同一批行重复返回 N 遍。设计只对 `count(*)` 和 `returning` 显式拒绝（`executors.cj:285-289`、`:779-782`），说明作者已知 pin 只对应一个物理库，但 UPDATE/DELETE/SELECT 漏了同样的守卫。

### [严重] S2: Unroutable/广播回退到"全部物理库"，跨逻辑库查询、计数与 DDL

- **位置**：`fdbm/src/execute/executors.cj:260-272`（`targetDatabases` 的 `Unroutable` 分支返回 `allDatabases(resources)`）、`:280`（count 复用同一分支）、`:154`（`broadcastWrite` 的 `targets` 回退）、`:985`（DDL 的 `databases` 回退）
- **描述**：设计 §6.2/§9.2 要求 `Unroutable` 的 SELECT 与 DDL/全局表写只在**该逻辑库包含的物理库**内广播；实现直接取 `NodeAccessor.databases()`（部署内全部物理库）。多逻辑库部署下，逻辑库 A 的无分库条件查询会读到逻辑库 B 的物理库，`count(*)` 把 B 的数据一起求和，DDL/全局表写会改到 B 的表。这是可见的错误结果与越界写入。`emptyOutcome`（`:363-373`）取 `allDatabases(resources)[0]` 取列信息，也有同样的 scope 问题。

### [严重] S3: 会话默认库取到物理库名，未限定表名匹配不到分库/全局表规则

- **位置**：`fdbm/src/config/settings.cj:109-117`（`defaultDatabaseOf` 依赖 `logicals.size == 1`）+ `fdbm/src/config/FdbmConfig.cj:519-530`（把每个物理库名也注册为逻辑库键，且顺序来自 `HashSet` 迭代）
- **描述**：配置 `fdbm_db_logicalDatabase_app=db0,db1` 时，`logicalDatabases()` 会额外加入 `db0`、`db1` 两个「逻辑库」（映射到全部物理库），`logicals.size` 变成 3，`defaultDatabaseOf` 的「只有一个逻辑库时取它」分支永远不命中，会话默认库落到物理名 `db0`。随后 `PartitionRouter.route`（`router.cj:135-151`）用 `db0` 当作逻辑库去查 `fdbm_partition__t='app,step,id'`，key `db0.t` 不命中 ⇒ 分片表被当成「未分库表」，返回 `Single(physicals[0])`；而 `logicals['db0']` 的数组由 `HashSet` 迭代构造，`physicals[0]` 在进程间不确定。结果：未限定表名的 SELECT/INSERT/UPDATE 只在某一个分片上读写（写入位置不确定、读取结果缺片），全局表也不会被识别为全局。测试全部使用「逻辑库名 == 物理库名」（如 `db0`），因此没有暴露。

### [严重] S4: DDL 在事务 pin 下对同一连接重复执行并逐库报成功

- **位置**：`fdbm/src/execute/executors.cj:990-1013`（`borrow` 在 `:994`）
- **描述**：DDL 广播循环对 `databases` 中每个物理库调用 `borrow`，pin 时全部返回同一个 pin 连接：`create table` 第一次成功、第二次通常报「表已存在」，于是把第二个库记为 failed 并抛 `DB_ERROR`（假失败）；`alter table` 之类幂等语句则会在同一库重复执行，并把**所有**库名加入 `succeeded`（假成功），真正的其它物理库从未收到 DDL。

### [一般] G1: `show tables` 把逻辑库名当物理库校验，限定逻辑库时必然失败

- **位置**：`fdbm/src/execute/executors.cj:876-885`
- **描述**：`database = statement.database ?? session.database` 后直接 `resources.contains(database)` 并 `resources.driver(database)`，两者都只认物理库名。设计 §8.1/§9.5 明确写成 `SHOW TABLES [<logical>]`，因此 `show tables app` 在正常部署（逻辑名 `app` ≠ 物理名 `db0`）下会返回 `ROUTE_FAILED('unknown database app')`。

### [一般] G2: `show databases` 返回物理库名，与设计"逻辑库清单"不符

- **位置**：`fdbm/src/execute/executors.cj:862-875`（`sortedNames(resources.databases())`）
- **描述**：设计 §8.1（`详细设计.md:570`）与 §9.5 要求返回逻辑库名；实现返回 `NodeAccessor.databases()`（物理库）。`Dispatcher_test.cj:343-359` 也按物理名断言，说明测试固化了错误语义。

### [一般] G3: `show tables` 失败路径泄漏语句与连接

- **位置**：`fdbm/src/execute/executors.cj:886-891`
- **描述**：`selectRead` → `prepareStatement` → `query()` 之间没有 `try/finally`；`prepareStatement` 或 `query()` 抛异常时连接不会归还（`Connection` 只在 `CursorSegment.close()` 里关闭）。默认池 `maxSize=1`，一次失败即可把该物理库的连接永久占住，后续请求全部超时。

### [一般] G4: 多行 INSERT 未"同一事务内"执行，部分成功不回滚

- **位置**：`fdbm/src/execute/executors.cj:597-614`、`:663-668`（insert…select 逐行）、`:787-800`
- **描述**：设计 §9.2 明确「`values` 多行按行分组路由（逐行执行、**同一事务内**）」；实现每行都独立 `borrow` + `executeUpdate`，非 pin 时等价于逐条自动提交。第 3 行失败时前 2 行已落库，客户端只看到 `ERROR`，与「同一事务」承诺不符（同分片内本可用一次 `begin/commit` 包住）。

### [一般] G5: 全局表写广播绕过会话事务（pin 被静默忽略）

- **位置**：`fdbm/src/execute/executors.cj:152-192`（`broadcastWrite` 用 `selectAllWrite`）、`:413-416`、`:471-474`、`:767-771`
- **描述**：`begin` 之后对全局表做 INSERT/UPDATE/DELETE，写操作走独立连接并各自提交，`rollback` 无法撤销；客户端却认为这些写属于当前事务。设计 §9.3 要求「随后所有语句（含 SELECT）都走该连接」，§9.4 只说明「每库独立事务」，两者在全局表 + pin 的组合下冲突且实现选择了静默绕过。

### [一般] G6: 错误码映射缺口：连接池失败与 ID 生成异常落到 INTERNAL

- **位置**：`fdbm/src/resources/DatabaseResources.cj:146-162`（`selectRead`/`selectWrite` 未捕获 `ConnectionException`）、`fdbm/src/server/handler.cj:45-47`（兜底 `INTERNAL`）、`fdbm/src/execute/executors.cj:743-749`（`idLiteral` 直接调用生成器）
- **描述**：设计 §5 规定「池耗尽等待超时同样表现为 `ConnectionException`（映射 `TIMEOUT`）」，实现中 `fdbm/src` 完全没有 `ConnectionException` 与 `TIMEOUT` 的引用：不可达库/池耗尽/取连接超时都会冒泡到 handler 的通用 `catch (e: Exception)`，回 `INTERNAL`。同理自定义 `IdGenerator` 抛出的 `IdGeneratorException`（f_dbm 接口默认实现）在 `nextIntId/nextStringId` 处未包装，回 `INTERNAL` 而不是 `ID_GENERATOR`；`CACHE`/`IO` 两个错误码在本模块无任何落点。

### [一般] G7: `begin` 失败或 `commit/rollback` 归还失败后 pin 状态未清理

- **位置**：`fdbm/src/execute/executors.cj:1033-1042`（begin）、`:1043-1055`（commit/rollback）
- **描述**：`begin` 先 `session.pinned = Some(pinned)` 再执行 `begin`，若物理库返回错误（如连接已坏、权限不足），异常直接上抛，`pinned` 留在会话上且 `transactionOpen=true`，后续语句会继续复用这条连接，直到会话断开；`commit/rollback` 的 `finally` 里先 `pinned.close()` 再 `session.pinned = None`，`close()` 若抛出（`PinnedConnection.close` 已吞异常，但换成别的实现或未来改动时）`pinned = None` 会被跳过，会话永久卡在「已 pin」状态。

### [一般] G8: "同分库维度"判定未比较分片空间，跨逻辑库 JOIN 误判为 Empty

- **位置**：`fdbm/src/route/router.cj:396-404`
- **描述**：`allSameDimension` 只比较 `rule.column` 与 `rule.algorithm.name`。两个不同逻辑库（分片数不同）但同列、同算法的表会被当成同一维度，随后直接取库名交集（`:189-201`）。物理库名不同时交集为空 → 返回 `Empty`（0 行），而设计 §6.2 要求「不同维度…要求各表收敛到同一个物理库，否则 `Unroutable`（错误信息给出两张表的库名）」。用户看到的是「查询成功但无数据」，不是错误。

### [一般] G9: `QueryCursor.next()` 抛异常后行缓冲与 `rowValid` 未复位

- **位置**：`fdbm/src/execute/cursor.cj:126-138`
- **描述**：`segment.result.next()` 抛异常时，`rowValid` 仍是上一行的 `true`，`cells`/`streams` 也保留上一行内容。客户端收到 `NEXT_ROW` 的 `ERROR` 后再读列，会拿到**上一行**的缓存值（`cell()` 只在 `rowValid` 为 false 时才拒绝），造成静默串行数据。

### [一般] G10: 自定义分区算法可覆盖内置实现（与设计 §10.5 相反且未校验）

- **位置**：`fdbm/src/route/algorithms.cj:288-293`（「先查自定义（同名可覆盖内置）」）、`fdbm/src/config/FdbmConfig.cj:423-428`（自定义名只做并集，未拒绝与内置重名）
- **描述**：设计 §10.5 要求「与内置重名由 `FdbmConfig.validate` 拒绝，不允许覆盖内置实现」。实现中 `validate` 只把自定义名加入 `known`，`PartitionAlgorithmFactory` 又以自定义优先，因此一个叫 `step` 的自定义扩展会静默接管全部分片路由，且无启动报错。`IdGenerator` 一侧同理（`:489` 只判断 `contains`）。

### [一般] G11: 会话巡检与在途请求并发关闭同一会话

- **位置**：`fdbm/src/server/SessionRegistry.cj:112-141`（`sweep`）
- **描述**：`sweep()` 在定时线程里发现 `buffer.isClosed()` 就把会话移出并 `session.close()`（关游标、归还 pin 连接），此时 handler 线程可能仍在同一会话上执行语句/读游标（`Server` 的读循环与执行器不在同一线程）。结果是连接在查询进行中被归还或关闭，可能出现「归还后又 close」、结果集被并发关闭。

## R6

### [严重] 自定义扩展链路（f_dbm 的唯一交付物）零端到端用例，且唯一涉及内置重名的用例把"覆盖内置"固化为期望

- **位置**：`fdbm/src/route/Route_test.cj:113-116`；`fdbm/src/server/Server_test.cj:151-167`；`fdbm/src/server/CustomLoader.cj:65`；`fdbm/src/idmaker/IdMakers.cj:184-186`；`fdbm/test/e2e/run.sh:42`；`fdbm/test/e2e/lib.sh:66`
- **描述**：`f_dbm` 的全部职责就是「第三方实现 `PartitionAlgorithm` / `IdGenerator`，由 fdbm 从 `custom/` 发现并注入」。这条链路的每一段在测试里都被绕开了：
  - **f_dbm 侧 0 用例**（同 R2 矩阵 D）；
  - **发现层**只有两条负例——目录不存在（`Server_test.cj:152-156`）与库损坏（`:158-167`）；全仓没有一条用例加载过真实的自定义 `.so`；
  - **注入层**在 `Dispatcher_test.cj:176` 直接把 `HashMap<String, IdGenerator>` 传给 `ExecutorDispatcher`，跳过了 `IdMakers.forTable` 的 custom 分支（`IdMakers.cj:184-186`）；
  - **e2e 层** `run.sh:42` 建了 `$WORK/custom` 目录，`lib.sh:66` 把它作为 `fdbm_customDir` 传入，但从未向其中放入任何库——扩展目录在全部 e2e 中恒为空；
  - 唯一触及「内置名 + 自定义」的用例 `Route_test.cj:113-116` 注册 `custom['hash']` 并断言 `partition('x') == 'db1'`，即**断言自定义实现覆盖内置实现**。这与 `f_dbm/README.md:59`「与内置重名同样拒绝，不允许覆盖」相反。
  - 第 5 条是本轮新增的事实修正：R2 [严重] 第 3 条曾记「没有任何测试覆盖内置名冲突场景」；更准确的表述是——**唯一的冲突场景用例断言的正是那个错误语义**。这会带来两个后果：其一，按 README 修复 `validatePartitions`/工厂优先级时该用例必然变红，实施者若不了解上下文很可能反过来「修测试」；其二，这条链路改变的是分库**落点**（`hash` 被换掉后同一用户的数据会写到别的物理库），属于最需要回归网的位置，而它恰好处在三层测试的公共盲区。

### [一般] 列类型归一（§9.6）在 fdbm 侧无任何断言，mockdb 恒报仓颉类型名使该路径只走"透传"

- **位置**：`fdbm/src/execute/cursor.cj:97-104`（唯一归一口 `QueryCursor.columnsOf` → `SqlTypes.canonicalName`）；举证：`fdbm/src/server/Handler_test.cj:56`（`typeName: 'Int64'`）、`fdbm/src/execute/Dispatcher_test.cj:747`（`'String'`）、`fdbm/src/server/Integration_test.cj:197`（`'Int64'`）；`fdbm/test/e2e/client/src/main.cj:433`（e2e 只读 `columnInfos[0].name`）
- **描述**：详细设计 §12 把「列类型只在线上出现仓颉类型名」列为拍板决策：物理方言的 `int4`/`TINYINT(1)`/`bytea`/`GEOMETRY` 必须由 fdbm 归一成 `Int32`/`Bool`/`Array<Byte>`/`String`，客户端不认识方言拼写。实现只有 `cursor.cj:100` 一处调用，而 **fdbm 的全部 190 条用例里，mockdb 的 `typeName` 都直接写成仓颉名**，于是 `canonicalName` 在执行器/协议层始终命中「原样返回」分支；e2e 只用真实驱动跑了 CRUD，客户端从不看 `typeName`，所以归一表在真实方言下也没有任何断言。现状是：映射函数本身有 3 条单测（`f_dbd/src/common/sqltypes_test.cj:96-122`），但它**是否被接到 RESP 里**没有任何用例钉住。若 `columnsOf` 被改成直接透传，或映射表少一行（例如 `int4 → Int32` 被误删），370 条用例全绿，而客户端 `get<Int32>` 会在运行期变成 `CONVERSION`。开发计划:235 ⑥ 已明确把这条列为验收项，属计划内未完成。

### [一般] 优雅停止的"等待与释放"语义无测试：`InFlight` 唤醒路径、`closeAll`、`closeAndAwait` 超时全部缺位

- **位置**：`fdbm/src/server/FdbmServer.cj:139-165`；`fdbm/src/server/InFlight.cj:52-71`；`fdbm/src/server/SessionRegistry.cj:71-94`；`fdbm/src/resources/DatabaseResources.cj:226-241`；用例侧 `fdbm/src/server/Server_test.cj:41-58,171-198`、`fdbm/src/resources/DatabaseResources_test.cj:102-118`、`fdbm/test/lifecycle_test.sh:72-82`
- **描述**：README（`fdbm/README.md:49-51`）承诺的停止顺序是「停止接受新连接 → 等在途请求 → 关闭全部会话与游标（归还借用连接）→ 逐池 `closeAndAwait` → 关缓存 → 退出码 0」。现有用例覆盖的是：
  - `InFlight` 的「计数为 0 立即返回」和「超时返回 false」（`Server_test.cj:41-58`），**`leave()` 触发 `condition.notifyAll()` 把阻塞中的 `await` 唤醒**这条路径从未执行——它是「等在途请求」唯一真正生效的分支；
  - `serverStartsServesAndStops`（`:171-198`）在**无在途请求、无打开游标、无 pin 事务**的空载状态下 stop；
  - `closeAndAwait` 的唯一断言是「`true`」（`DatabaseResources_test.cj:109`），但同一用例前一行已 `resources.close()`：`closeAndAwait` 进来时 `closed.swap(true)` 已为真，**直接返回 `true`（`DatabaseResources.cj:227-229`），逐池循环（`:231-239`）从未执行**。开发计划:149 要求的「有借用 + 1ms → false」和「`Zero`/`Max` → `IllegalArgumentException`」均缺；
  - `closeAll` 关闭会话时释放游标与 pin 连接（`SessionRegistry.cj:87-93`、`execute/session.cj:62-83`）无任何用例；
  - 进程级只验证 pid 消失与 `fdbm is stopping` 日志，`boot.sh stop` 是后台 `kill -TERM`，**脚本拿不到退出码**，因此「退出码 0」这条文档承诺没有任何可执行断言。
  - 影响：停止流程一旦顺序写错（例如先 `resources.closeAndAwait` 再 `sessions.closeAll`），空载用例照样全绿，而线上表现为「有长查询时停服把连接判为未归还、超时后强杀进程」。

### [一般] 零并发用例：服务端全部共享状态只在单线程下验证

- **位置**：`fdbm/src/server/Handler_test.cj:215-230`（`twoConnectionsHaveIndependentSessions`）；`fdbm/src/server/InFlight.cj:36-46`；`fdbm/src/server/SessionRegistry.cj:46-58`；`fdbm/src/route/cache.cj:62-96`；`fdbm/test/e2e/client/src/main.cj:164-202`（单客户端串行）
- **描述**：全仓测试中 `spawn` 只出现 5 次，且全部是「起服务端」的夹具（`stub_fdbm_test.cj:47`、`stub_test.cj:39`、`Handler_test.cj:318`、`Integration_test.cj:210`、`Server_test.cj:179`），**没有一处让两个请求同时执行**。`twoConnectionsHaveIndependentSessions` 名为「两个连接」，实际是 A 发完、B 再发（`:221-224`）。因此：`InFlight.enter/leave` 的并发增减（`AtomicInt64` + `Mutex` 组合）只在单线程计数 0→2→0；`SessionRegistry.of()` 的「同 buffer 取或建」只在同线程连续调用；`PartitionCache.put` 的容量判定与计数（`cache.cj:68-84`）虽整体在 `Mutex` 内，但只在单线程下验证过，并发写入时 `store` 的行为、`count_` 与落盘键数的一致性没有用例；设计 §12 明说「池 `maxSize` 需 ≥ 并发长查询数」，这条前提也没有任何用例测过并发长查询。对一个以「一条 TCP 一个会话 + 在途计数 + 周期巡检」为核心状态模型的中间件，这属于最大的结构性缺口。

### [一般] 启动自检负例覆盖 13/16 行，"配置错误 → 进程退出码 1"完全没测；`fdbm_sessionSweepInterval` 是唯一未做正数校验的时间参数

- **位置**：`fdbm/src/config/FdbmConfig.cj:296-322`（`sessionSweepInterval` 无校验；`shutdownTimeout`/`checkDuration`/`unavailableChecked` 有校验）、`:372-377`（validate 复检）、`:585-607`（`durationOf` 接受 0/负值）；`fdbm/src/config/FdbmConfig_test.cj:307-325`（只给正例 15/20s/45/5）；`fdbm/src/main.cj:30-41`；`fdbm/src/config/FdbmConfig_test.cj:449-459`
- **描述**：详细设计 §11 是「报错并结束进程」的清单，开发计划:59/278 要求「每条一个用例，断言 `FdbmException.code`」并「脚本化验证退出码非 0」。实际：
  - 已覆盖：驱动唯一性、坏库、分区缺 `__`、substr 规格缺失/非法 hash、权重后缀、逻辑库引用、未知算法、snowflake 序列号、sequence 分配库、节点地址、EXPORT 白名单；
  - 未覆盖：`checkDuration <= 0`、`unavailableChecked <= 0`、`shutdownTimeout <= 0 / Duration.Max`、自定义扩展与内置/自定义重名（§11 第 3 行）；另 `substr` 行的 `start < 0` / `length < 0`（`FdbmConfig.cj:441-443`）无负例；
  - `fdbm_sessionSweepInterval` 是唯一**既无校验也无负例**的时间键：`durationOf` 会把 `0`/负数原样返回，`SessionRegistry` 直接交给 `Timer.repeat(interval, interval)`（`SessionRegistry.cj:42`），配置成 0 可能形成忙轮询；
  - 全部用例都停在函数级，没有任何用例让 `main()` 以坏配置启动并断言「退出码 1 + 端口未监听」，而 `fdbm/README.md:70` 明确承诺「任一失败在接受连接之前报错退出」。

### [一般] 连接/游标的"归还"没有可观测断言，资源泄漏只能靠"后续还能跑"间接推断

- **位置**：`fdbm/src/resources/DatabaseResources.cj:164-187`（广播部分失败的连接清理）、`:226-241`（`closeAndAwait`）；用例侧 `fdbm/src/server/Integration_test.cj:88-105`、`fdbm/src/execute/Dispatcher_test.cj`（全部用例仅在 `finally` 里 `resources.close()`）
- **描述**：fdbm 侧没有任何用例读取连接池的活跃/空闲计数，也没有用 `maxSize=1` 制造「泄漏即失败」的强约束。因此：「关闭游标归还连接」只由 `closeSendsUnsubscribeAndReleasesCursor`（`Integration_test.cj:88-105`）间接证明——它的夹具 `maxSize=4`，即使泄漏一根也照样能跑第二条查询；`selectAllWrite` 在部分广播失败时关闭已借连接（`DatabaseResources.cj:176-185`）从未被执行：`FailingAccessor` 在 accessor 层抛错，绕过了 `DatabaseResources` 自己的 catch；`Dispatcher_test` 的 `resources.close()` 只保证「不挂」，不证明归还。这与优雅停止的「停止时归还」是同一观测能力缺失的两面。

## 统计

| 轮次 | 严重 | 一般 | 小计 |
| --- | --- | --- | --- |
| R1 | 2 | 8 | 10 |
| R2 | 4 | 6 | 10 |
| R3 | 2 | 14 | 16 |
| R4 | 3 | 7 | 10 |
| R5 | 4 | 11 | 15 |
| R6 | 1 | 5 | 6 |
| **总计** | **16** | **51** | **67** |
