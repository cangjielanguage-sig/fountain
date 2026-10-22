# R2: f_dbd 测试覆盖审查 + f_dbm 全部文档/代码/测试审查

审查时间：2026-10-21

### 审查范围

**f_dbd（全部 `*_test.cj` + 其被测源码）**

- 测试：`f_dbd/src/dbd_test.cj`、`f_dbd/src/common/{DbdException,column,error,payload,result,sqltypes,types,dispatch_perf}_test.cj`、`f_dbd/src/driver/{DbdUrl,DbdDriver,DbdConnection,DbdStatement,DbdTransaction,DbdTransport,testkit,stub_fdbm}_test.cj`、`f_dbd/src/exception/Reexport_test.cj`、`f_dbd/src/multid/{MultiD,MultiDatasource,stub}_test.cj`
- 被测源码：`f_dbd/src/dbd.cj`、`f_dbd/src/common/*.cj`、`f_dbd/src/driver/*.cj`、`f_dbd/src/exception/*.cj`、`f_dbd/src/multid/*.cj`
- 参照文档：`f_dbd/README.md`、`f_dbd/README_en.md`、`f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/{tasks.md,specs/f-dbd/spec.md}`、`f_dbd/doc/详细设计.md`

**f_dbm（5 个 tracked 文件全部）**

- `f_dbm/README.md`、`f_dbm/README_en.md`、`f_dbm/cjpm.toml`、`f_dbm/src/IdGenerator.cj`、`f_dbm/src/PartitionAlgorithm.cj`

**为核对 f_dbm 文档承诺而阅读的参照实现（只读，不评价其自身质量）**

- `fdbm/src/server/CustomLoader.cj`、`fdbm/src/server/handler.cj`、`fdbm/src/config/FdbmConfig.cj`、`fdbm/src/route/{algorithms,router}.cj`、`fdbm/src/execute/executors.cj`、`fdbm/src/idmaker/{IdMakers,IdMakers_test}.cj`、`fdbm/doc/详细设计.md` §10.5、`fdbm/doc/开发计划.md`
- `f_app/src/Initializer.cj`、`f_base/src/BaseException.cj`、`f_config/src/Config.cj`、`f_dbd/doc/spec/.../tasks.md`

**规模统计**：f_dbd 21 个测试文件 / 24 个 `@Test` 类 / 180 个 `@TestCase`；f_dbm 0 个测试文件 / 0 个用例。

**方法与限制**：只读静态审查。未执行 `cjpm test`（`f_dbd/src/driver/DbdDriver.cj:53` 的包级 `static init` 依赖环境变量，见发现 G3；`dispatch_perf_test.cj` 单轮约 5 亿次分派，不适合在审查内联跑）。所有结论均以源码/文档行号为据；仓颉语义结论（`String` 下标与切片按 UTF-8 **字节**计）已核对本地 std 文档 `core_package_structs.md` §`struct String`。

---

### 覆盖矩阵

图例：✅ 有直接断言；◐ 部分分支/部分类型；❌ 无用例。

#### A. `fountain::f_dbd.common`

| 公开 API | 覆盖用例 | 状态 |
| --- | --- | --- |
| `decodeStrict<T>` | `DecodeStrictTest` 4 例（正例/交叉负例/DataAny/越界） | ✅ |
| `SqlReadType.toString` / `of` / `==` | `sqlReadTypeToString`、`readType*` 间接 | ✅ |
| `SqlTypes.readType` | 4 例覆盖 Sql*/仓颉名/方言名/未知 | ✅ |
| `SqlTypes.canonicalName` | 3 例（含未知 → `String`） | ◐ 未知分支只断言返回值，未断言 spec 承诺的 WARN 含原始 `typeName` |
| `SqlTypes.readData` | `readDataEncodesCells`：`Int64`/`String`/NULL | ◐ 19 个 `SqlReadType` 分支中仅 3 个；`UInt*`/`Float*`/`Decimal`/`BigInt`/`DateTime`/`Duration`/`Bytes`/`Stream` 走 `readStream` 的分支均未覆盖 |
| `SqlTypes.readStream(result,index)` | NULL → 空流；非流列 → `SqlException` 透传 | ✅ |
| `SqlTypes.readChunk` | 循环读满、短块非 EOF、EOF | ◐ `size <= 0` → `DEFAULT_STREAM_CHUNK` 未测 |
| `SqlTypes.readStream(result,index,size)` | 透传用例 | ✅ |
| `SqlTypes.encodeParameter` | `encodeParameterSupportedTypes`：仅 `Bool`/`Int64`/`String` | ❌ 其余 16 类 + `InputStream` 分支 + 不支持类型分支（`types.cj:454`）均无用例 |
| `SqlTypes.decode` | NULL/区间/越界/分数/宽松 `String`/不可转换 | ✅ |
| 4 个公开常量 | `topLevelConstants`（含位组合红线） | ✅ |
| `ColumnInfoImpl` 全成员 | 6 例（默认值/全参/字段可变/键集合/实现接口/往返/严格解码） | ✅ |
| `SqlPayload` / `UpdateResultPayload` / `QueryResultServerPayload` / `QueryResultColumnPayload` / `QueryResultClosePayload` | `PayloadTest` 18 例 | ✅ |
| `DbdErrorCode.value/toString/==/parse` | `ErrorCodeTest` 5 例 | ◐ `toString` 仅 2/16，`parse` 仅越界值与间接路径 |
| `DbdErrorPayload` | 6 例（默认/全参/往返/越界兜底） | ✅ |
| `DbdException`（2 构造器/`code`/`cause`） | `DbdExceptionTest` 7 例 + `ReexportTest` 3 例 | ✅ |
| `QueryResultImpl.columnInfos` / `next()` / `next(values)` | 构造 2 例、`next` 6 例、deprecated 1 例 | ✅ |
| `QueryResultImpl.getOrNull/get` | NULL、越界索引、未 `next`、越界值、宽松、不支持类型、7 类型表驱动 | ◐ 16 类型中 7；`Rune` 多字符报错、`Decimal`/`BigInt`/`Duration`/`UInt*` 未覆盖 |
| `QueryResultImpl.close/isClosed` | 幂等、发 `UNSUBSCRIBE(qid)`、关闭失败仍释放 | ✅ |
| `QueryResultImpl.requestBlock`（包内） | 经流用例间接 | ◐ 非 `Array<Byte>` 载荷 → `CONVERSION` 未测 |
| `DbdInputStream.read` | 多块/EOF/短块/余量/行失效/句柄复用/`chunkSize` 缺省 | ◐ 空 buffer 立即返回 0（`result.cj:378`）未测 |

#### B. `fountain::f_dbd.driver`

| 公开 API | 覆盖用例 | 状态 |
| --- | --- | --- |
| `DbdUrl.parse/tryParse/toUrl/toUrlMasked` | 13 例（完整/缺省端口/%编码/IPv6/路径段/5 类非法/往返/脱敏） | ◐ **全部为 ASCII**；非 ASCII 凭据与库名、残缺 `%`、IPv6 无端口未测（见发现 S3） |
| `DbdUrl.withCredentials`（包内） | `optionsOverrideCredentials` 间接 | ✅ |
| `DbdDriver.init/name/preferredPooling/version/open` | `DbdDriverTest` 4 例 | ◐ 断言 `name == 'fdbm'`，与文档建议值冲突（见 G3） |
| `dbdDriver()` | `registersItself` 与全部 driver 用例入口 | ◐ 依赖环境变量 |
| `DbdDatasource.init/connect/setOption/close/isClosed` | `DbdDatasourceTest` 6 例 | ◐ `connection_timeout` 非正/非法、`fetch_rows` 非法值未测 |
| `DbdOptions.apply/copy`（包内） | 仅经 `setOption` 间接 | ❌ `timeoutOf` 的 `ms <= 0` → `None`、非法数字 WARN、`fetch_rows` 非法值、`copy()` 隔离性均无用例 |
| `DbdConnection.state/prepareStatement/createTransaction/getMetaData/close/isClosed` | 6 例（状态机/独占闸门/关闭握手/密码不外泄） | ✅ |
| `DbdStatement.set/setNull/query/update/setOption/close/isClosed` | 7 例 + 接线 4 例 | ◐ 见 G6：`parameterColumnInfos`、`close()` 后执行、`update_timeout`、`update()` 错误载荷、`set<InputStream>`/`SqlBlob`、未支持 `SqlDbType` 全无用例 |
| `DbdStatement.query(params)/update(params)`（deprecated） | 1 例 | ◐ 仅 `SqlBigInt`/`SqlNullableVarchar` 两种 |
| `DbdTransaction.*`（3 属性 + 6 方法） | 5 例 | ◐ `save/rollback(name)/release` 未 `begin` → `TX_STATE` 未测；`execute` 的 `query_timeout` 未直接断言 |
| `DbdTransport.request/unsubscribe/ping/close/isClosed` | 10 例 | ◐ `onNoResponse` 的 `IO` 分支（`transport.cj:139-145`）、`ping` 非 `ACK` → `PROTOCOL` 未测（代码注释已声明 ping 超时分支不可达，属可接受） |

#### C. `fountain::f_dbd.multid` / 根包 / exception

| 公开 API | 覆盖用例 | 状态 |
| --- | --- | --- |
| `MultiDConfig` 14 个 getter | 4 例（显式/三种写法/非法回落/`MaxWaiting=0`） | ✅ |
| `MultiDUrl.parse/tryParse` | 4 例（双 scheme/单节点/6 类非法） | ◐ 非 ASCII 未测（实现按字节切片，行为正确） |
| `MultiD.init/name/preferredPooling/version/open`、`multiDDriver()` | 2 例 | ✅ |
| `MultiDatasource.init/connect/setOption/close/isClosed` | 5 例（权重 2:1、零权重、随机、非法权重、池耗尽、close 幂等、`setOption` 转发） | ◐ `ConnectionException` 文案嗅探分支（`Datasource.cj:116`）、`close()` 后池内部任务未测 |
| `fountain::f_dbd` 根包 | `dbd_test.cj` 1 例（仅断言 `FountainVersion` 非空） | ◐ 占位用例，未触达本包任何声明 |
| `exception` 重导出 | `ReexportTest` 3 例 | ✅ |

#### D. `fountain::f_dbm`（5 文件）

| 公开 API | 用例 | 状态 |
| --- | --- | --- |
| `PartitionAlgorithm.name` | 无 | ❌ |
| `PartitionAlgorithm.partition<K>` | 无 | ❌ |
| `IdGenerator.name` | 无 | ❌ |
| `IdGenerator.nextStringId()` 默认实现（抛 `IdGeneratorException`） | 无 | ❌ |
| `IdGenerator.nextIntId()` 默认实现（抛 `IdGeneratorException`） | 无 | ❌ |
| `IdGeneratorException.init(message)` / `message` 保真 | 无 | ❌ |

f_dbm 目录内不存在任何 `*_test.cj`、`test/` 目录，`cjpm.toml` 也无 `[test-dependencies]`；`tasks.md:126`（任务 14.1）明确要求"`IdGenerator` 默认实现与 `IdGeneratorException`（接口在 `f_dbm`，**用例在 f_dbm**）"，该交付项缺失。`fdbm/doc/开发计划.md:199-203` 同样计划"默认实现抛 `IdGeneratorException`""`IdGeneratorException` message 保真""`UuidIdGenerator.nextIntId()` → `IdGeneratorException`"等用例，实际 `fdbm/src/idmaker/IdMakers_test.cj` 只有 3 条正例，无一条负例。

#### E. 文档承诺 → 测试对照（f_dbd）

| 文档承诺 | 位置 | 测试现状 |
| --- | --- | --- |
| 参数编码"表驱动编码 §8 左列每种受支持类型" | `specs/f-dbd/spec.md:209-213` | 仅 3 类（G4） |
| 未知 `typeName` "按 `String` 读取并记一次 WARN，日志含原始 `typeName`" | `spec.md:197-201` | 只断言返回值，未断言 WARN 内容 |
| `cjpm test` 可直接运行 | `README.md:72-76` | 未导出 `dbd_driverName` 时包级 `static init` 即 `exit(1)`（G3） |
| 流列"按 `fetch_rows` 分块读" | `README.md:63-64` | ✅（`DbdStreamTest.readsBlocksInOrder`） |
| 关闭失败"`ERROR` 保持可用、超时/断链置 `Broken`" | `spec.md:113-117` | ◐ `ERROR` 侧有（`closeFailureStillReleasesLocalState`），超时/断链侧靠 `DbdTransportTest` 间接 |
| 连接静默重建后 cursor 操作 `CURSOR_STATE`、事务 `TX_STATE` | `spec.md:305-309` | ❌ 无自动化用例（需真实断链） |

#### F. 无效/空/占位测试清单（判定依据）

| 判定 | 位置 | 依据 |
| --- | --- | --- |
| 无任何断言 | `dispatch_perf_test.cj:123-135`（`nullShortCircuit`） | 函数体内只有 6 行 `println`，无 `@Assert`，`shortCircuitOf` 走 `timed`（不做 witness 校验），用例不可能失败 |
| 名实不符 + 反向断言 | `sqltypes_test.cj:140-149`（`encodeParameterUnsupportedTypeThrows`） | 名称为"不支持类型应抛"，体内 `catch` 后 `@Assert(!threw)`；`SqlPayload` 实现 `ToData`，实际命中 `types.cj:453` 兜底分支，`types.cj:454` 的 `throw` 从未被执行 |
| 仅"不抛异常" | `DbdDriver_test.cj:157-164`（`unknownOptionIsIgnored`） | 只有 `setOption`/`close` 调用，无 `@Assert`；语义即"调用不炸" |
| 占位/平凡用例 | `dbd_test.cj:22-35` | 注释自述"阶段 0 的平凡用例……占位"，断言对象是 `FountainVersion` 而非 f_dbd 行为 |
| 空体/被注释/禁用 | 无 | 全量 180 个 `@TestCase` 无 `@Ignore`/`@Skip`/`@Disabled`/注释掉的用例；无空 `@Test` 类 |

---

### 发现

#### [严重] `set<InputStream>` 参数路径会一次性分配 `Int64.Max` 字节

- **位置**：`f_dbd/src/common/types.cj:452`（`readChunk(x, Int64.Max)`）→ `f_dbd/src/common/types.cj:398-413`（`readChunk`）
- **描述**：`encodeParameter` 把 `InputStream` 参数交给 `readChunk(x, Int64.Max)`；`readChunk` 第一行即 `Array<Byte>(want - got, repeat: 0)`，`want = Int64.Max`。结果是每次把流当参数绑定都试图申请约 9.2 EB 内存（`OutOfMemory`/构造失败），且循环内每轮都重新申请"剩余全部"大小，正常大流也退化为 O(n²) 拷贝。该路径同时被 `DbdStatement.setSqlDbType` 的 `SqlBlob`/`SqlClob` 分支（`DbdStatement.cj:215,219`）使用。全库无一条用例覆盖 `set<InputStream>`（`f_dbd/src/driver/DbdStatement_test.cj` 内无 `InputStream` 参数），因此该缺陷从未被触发暴露。
- **建议**：`readChunk` 改为固定上限的循环（如每次 `min(8 KiB, 剩余)`，累积到 `ArrayList<Byte>`），`encodeParameter` 的流参数改为 `readChunk(x, DEFAULT_STREAM_CHUNK)` 反复读至 EOF；补 `set<InputStream>`（含大流、空流、`SqlBlob` 重载）用例。

#### [严重] `IdGeneratorException` 无消费者侧映射：文档约定抛它，实际回 `INTERNAL`

- **位置**：`f_dbm/src/IdGenerator.cj:42-49`（默认实现）↔ `fdbm/src/server/handler.cj:41-47`（异常→错误码）；触发点 `fdbm/src/execute/executors.cj:743-750`
- **描述**：`f_dbm` README 与类注释要求"生成器实现应抛 `IdGeneratorException`"（`f_dbm/README.md:28`、`IdGenerator.cj:21-24`）。但 `fdbm` 全仓 `grep IdGeneratorException` 命中 0 处：`FdbmHandler.handle` 只区分 `FdbmException` / `SqlException` / `Exception`，而 `IdGeneratorException <: BaseException <: Exception`（`f_base/src/BaseException.cj:44`），于是落到 `catch (e: Exception)` → `errorOf(..., DbdErrorCode.INTERNAL, ...)`。更直接的是组合路径：`InsertExecutor.idLiteral` 按**算法名**决定调 `nextIntId()` 还是 `nextStringId()`（`executors.cj:745-749`），而默认 `fdbm_idmaker=uuid,1` 的 `UuidIdGenerator` 只实现 `nextStringId()`（`fdbm/src/idmaker/IdMakers.cj:30-55`）；因此"`fdbm_partition__t=db0,step,id` + 默认 idmaker"这一合理配置会在每次缺列 INSERT 时调用 `nextIntId()` 默认实现 → 抛 `IdGeneratorException` → 客户端收到 `INTERNAL`（而非文档口径的 `ID_GENERATOR`）。同一规则也让"自定义生成器只支持一种 ID"的用法必然返回 `INTERNAL`。该约定在 f_dbm 与 fdbm 两侧都没有任何用例。
- **建议**：`FdbmHandler` 增加 `catch (e: IdGeneratorException) => errorOf(id, DbdErrorCode.ID_GENERATOR, ...)`（或让 `IdMakers`/`idLiteral` 捕获后包成 `FdbmException(ID_GENERATOR)`）；`FdbmConfig.validateIdMaker` 对 `step/snowflake/sequence` 与 `uuid` 的组合给出启动期 `CONFIG` 提示；补两条负例（默认实现抛 `IdGeneratorException`、`step`+`uuid` 组合）。

#### [严重] `DbdUrl` 混用字节下标与字符下标：非 ASCII 凭据被静默截断、非 ASCII 库名直接失败

- **位置**：`f_dbd/src/driver/DbdUrl.cj:180-190`（`take` 按 `toRuneArray()` 取字符）、`DbdUrl.cj:62-111`（调用方传入的 `indexOf`/`lastIndexOf` 返回值）、`DbdUrl.cj:197-218`（`percentDecode` 逐字节 `Rune(UInt32(n))`）
- **描述**：
  1. 仓颉 `String` 的 `size`、`[]`、切片、`indexOf` 全部按 **UTF-8 字节**计（std 文档 `core_package_structs.md` §`struct String` 明确说明），而 `take()` 用 `toRuneArray()` 的**字符**下标；两者只在纯 ASCII 前缀下等价。`DbdUrl.cj:236-240` 的注释"仓颉 `String` 没有切片/子串 API"也不成立（同仓库 `MultiDUrl.cj:57,105,116` 就在用 `s[a..b]`）。
  2. 实例如 `fdbm://u:密@host:9000/db`：`lastIndexOf('@')` 返回字节 5，`take(authority, 0, 5)` 却取前 5 个**字符** `"u:密@h"`，切出 `user="u"`、`password="密@h"` —— 密码被静默污染（今日凭据只进 `getMetaData`，故不报错；鉴权上线后即变成难以定位的认证失败）。非 ASCII 用户名或库名则因 `start > end` 得到空串，抛 `CONFIG: database is empty`（合法 URL 被拒）。
  3. `percentDecode` 对 `%E5%AF%86` 逐个十六进制字节造 `Rune(0xE5)`/`Rune(0xAF)`/`Rune(0x86)`，再拼回 `String` 时每个 Rune 重新编码为 UTF-8，多字节字符被放大错乱；`percentEncode` 侧是字节正确的（`DbdUrl.cj:225-250`），故 `parse(toUrl(x))` 对非 ASCII 不成立，与 README"凭据支持 `%XX` 编码"（`f_dbd/README.md:38-39`）相悖；`%FFFFFF` 之类还会让 `Rune(UInt32)` 抛非 `DbdException` 异常。
  4. `DbdUrl_test.cj` 13 条用例全部 ASCII，无一覆盖上述路径。
- **建议**：统一口径——把 `take`/`countOf` 改为按字节切片（`value[start..end]`，注意落在字符边界），或全部改用 `toRuneArray()` 后的字符下标（此时 `indexOf` 结果也要换算）；`percentDecode` 改为先把 `%XX` 还原成字节数组再 `String.fromUtf8`；补 4 条用例（非 ASCII 用户名/密码/库名往返、残缺 `%`、越界 `%`）。

#### [严重] 内置与自定义分区算法重名未拒绝，实现静默覆盖内置（与文档承诺相反）

- **位置**：`f_dbm/README.md:59`（"与内置重名同样拒绝，不允许覆盖"）、`fdbm/src/config/FdbmConfig.cj:421-429`（`validatePartitions` 只做并集，无冲突判定）、`fdbm/src/route/algorithms.cj:288-294`（工厂"先查自定义（同名可覆盖内置）"）
- **描述**：`f_dbm` 给第三方的加载约定第 3 条承诺"自定义之间重名 → `CONFIG`/`PARTITION_CONFIG`；与内置重名同样拒绝，不允许覆盖"；`fdbm/doc/详细设计.md` §10.5 同样写"与内置……重名由 `FdbmConfig.validate` 拒绝……**不允许覆盖内置实现**"。实际 `validatePartitions` 把 `BUILTIN_ALGORITHMS` 与 `customAlgorithms` 直接并成 `known` 集合（无交集检查），`CustomLoader` 也只拒绝自定义之间的重名；而工厂 `create` **先**查 `custom.get(name)`。因此一个名为 `hash` 的扩展库会被接受并在运行期悄悄替换内置 `hash`，所有按该算法的分库写入都会改落到另一物理库——按 README 部署的人完全不会预期这一点，且没有任何测试覆盖"内置名冲突"场景。
- **建议**：在 `FdbmConfig.validatePartitions`（或 `CustomLoader.load` 收集阶段）显式比对 `BUILTIN_ALGORITHMS` 与自定义名，冲突抛 `PARTITION_CONFIG`；同时把 `PartitionAlgorithmFactory.create` 的"custom 优先"改为"内置优先"或直接去掉覆盖语义；补 `Route_test`/`CustomLoader` 各一条冲突负例。

#### [一般] f_dbm 零测试：扩展契约的默认行为与异常类型完全无回归

- **位置**：`f_dbm/`（无任何 `*_test.cj`）；`f_dbm/src/IdGenerator.cj:42-49`；`f_dbm/src/PartitionAlgorithm.cj:25-31`
- **描述**：`f_dbm` 是第三方扩展的唯一契约面（`README.md:3-5`），但两个接口、默认方法、异常类型均无用例（矩阵 D 全 ❌）。`f_dbd/doc/spec/.../tasks.md:126` 与 `fdbm/doc/开发计划.md:199-203` 都把"默认实现抛 `IdGeneratorException`""message 保真"列为计划内的用例，属未兑现的交付项；也因此 [严重] 第 2 条（异常未被映射）在两侧都没有任何自动化门槛。仓库内 `f_app`/`f_health` 同样无测试，故不按"严重"计，但 `f_dbm` 有明确的契约与计划要求，应补齐。
- **建议**：新增 `f_dbm/src/IdGenerator_test.cj`：① 只实现 `nextStringId` 的桩 → `nextIntId()` 抛 `IdGeneratorException` 且 `message` 含 `name`；② 反向同理；③ `IdGeneratorException` 可被 `BaseException`/`Exception` 捕获且 `message` 保真；④ `PartitionAlgorithm` 桩的 `name`/`partition` 泛型调用（`Int64`/`String` 两种 key）。`cjpm.toml` 补 `[test-dependencies]`（当前无）。

#### [一般] `encodeParameterUnsupportedTypeThrows` 名实不符，`unsupported parameter type` 分支零覆盖

- **位置**：`f_dbd/src/common/sqltypes_test.cj:140-149`（用例）、`f_dbd/src/common/types.cj:453-454`（被测分支）
- **描述**：用例名叫"不支持类型应抛"，实现却断言 `@Assert(!threw)`（第 148 行）。原因是用 `SqlPayload('x')` 作探针，而 `SqlPayload` 实现 `ToData`，会命中 `types.cj:453` 的 `case x: ToData` 兜底而不抛异常；真正该覆盖的 `types.cj:454`（`_ => throw DataException('unsupported parameter type ...')`）在全仓没有任何用例，`DbdStatement.encode` 把它包成 `CONVERSION` 的那层（`DbdStatement.cj:198-205`）只被 `NotEncodable` 一条用例覆盖（`DbdStatement_test.cj:83`）。
- **建议**：改名或改正断言：用真正既不属受支持类型、也不实现 `ToData` 的值（例如测试私有 `class NotEncodable {}`）断言 `DataException`；并保留一条"实现 `ToData` 的自定义类型走兜底"的用例，两条语义分开钉住。

#### [一般] f_dbd 测试套件依赖环境变量 `dbd_driverName=fdbm`，且断言值与文档推荐值相反

- **位置**：`f_dbd/src/driver/DbdDriver.cj:53-56`（`static init` 读配置注册）、`DbdDriver.cj:108-117`（未配置即 `exit(1)`）、`f_dbd/src/driver/DbdDriver_test.cj:31-41`（断言 `name == 'fdbm'`、`getDriver('fdbm')` 非空）
- **描述**：`DbdDriver` 的注册名取自 `dbd_driverName`，未配置或为空时在 `static init` 阶段 `exit(1)`；而 f_dbd 内没有任何 `Config.set('dbd_driverName', ...)`（`grep` 全模块只有 `multidbm_*`），仓库脚本也未导出该变量。于是 `README.md:72-76` 给出的 `cjpm test` 在干净环境会在包初始化时终止整个测试进程；反过来，若按文档 `export dbd_driverName=postgres`（`README.md:44-46`、`详细设计.md:570-577`）运行，`registersItself` 里 `@Assert(driver.name, 'fdbm')` 与 `DriverManager.getDriver('fdbm')` 会直接失败。`tasks.md:185` 记录的"180 条全绿"只能在 `dbd_driverName=fdbm` 这一未文档化的前提下复现。
- **建议**：测试内自洽——在测试启动前显式 `Config.set([('dbd_driverName', 'testdialect')])`（或在 `testkit_test.cj` 提供 `initTestDriverName()` 并在每个用例前置调用），断言随之改为同一常量；`README.md` 的"测试"一节补一句前置条件（若保留外部 env，则写明 `dbd_driverName=fdbm cjpm test`）。

#### [一般] 类型矩阵测试显著少于 spec 承诺（"§8 每种受支持类型"）

- **位置**：`f_dbd/src/common/sqltypes_test.cj:134-138`（编码）、`sqltypes_test.cj:246-253`（`readData`）、`f_dbd/src/common/result_test.cj:201-220`（`everyTypeReadsBack`）；对应承诺 `f_dbd/doc/spec/.../specs/f-dbd/spec.md:209-213`
- **描述**：spec 的"表驱动编码"要求 §8 左列**每种**类型都有用例；实际 `encodeParameter` 只断言 `Bool`/`Int64`/`String`，`readData` 只断言 `Int64`/`String`/NULL，`QueryResultImpl.get<T>` 只覆盖 7/16 个具体类型（缺 `Rune` 之外的 `Int16`/`Int32`/`UInt*`/`Float32`/`Decimal`/`BigInt`/`Duration`）。这些分支的代码是逐个 `case` 手写的（`types.cj:348-369`、`result.cj:220-239`），错一行不会有任何用例失败；上述 [严重] 第 1 条正是藏在这片空白里。
- **建议**：按 §8 表生成参数化用例（值 + 期望 `Data` 子类），`readData`/`decodeCellAsAny` 各补一张同构表；对 `Stream` 列单独一条（`readData` → `readStream(...).toData()`）。

#### [一般] `nullShortCircuit` 无任何断言（无效测试）

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:123-135`
- **描述**：该 `@TestCase` 体内只有 `println`，`shortCircuitOf` 用 `timed`（不做 witness 校验），也不比对各 `T` 的计时关系。用例除了"不崩溃"不验证任何东西，且每次 `cjpm test` 都会把基准表打进测试输出。
- **建议**：要么删除，要么补断言（如"每种 `T` 的短路耗时 ≤ 完整分派"，或复用 `timedOrThrow` 校验 witness = 0 常量），并把基准输出改为 `@Bench`/单独脚本。

#### [一般] 公开行为缺口清单（无用例的直接路径）

- **位置/缺口**：
  1. `f_dbd/src/driver/DbdStatement.cj:52-56` `parameterColumnInfos` 恒为空数组 —— 无用例（spec 未承诺，但属 `Statement` 接口可见行为）。
  2. `f_dbd/src/driver/DbdStatement.cj:150-155` `close()` 后 `query()/update()` → `CURSOR_STATE` —— 无用例（`prepareStatementIsLocal` 只测了 `isClosed()`）。
  3. `f_dbd/src/driver/DbdStatement.cj:104-113` `update()` 载荷不符 → `PROTOCOL` —— 只测了 `query()` 侧。
  4. `f_dbd/src/driver/DbdStatement.cj:115-118` `update_timeout` 生效 —— 只测 `query_timeout`。
  5. `f_dbd/src/driver/DbdStatement.cj:211-253` `setSqlDbType` 的 `case _`（未支持 `SqlDbType` → `CONVERSION`）与 `SqlBlob`/`SqlClob` —— 无用例。
  6. `f_dbd/src/driver/DbdTransaction.cj:92-108` `save/rollback(name)/release` 在未 `begin` 时 → `TX_STATE` —— 只测了 `commit`/`rollback`。
  7. `f_dbd/src/common/result.cj:320-340` `requestBlock` 载荷解不出 `Array<Byte>` → `CONVERSION` —— 无用例。
  8. `f_dbd/src/common/result.cj:260-271` `runeOf` 多字符/空串 → `CONVERSION` —— 只测了单字符成功路径。
  9. `f_dbd/src/common/result.cj:373-380` `read(空 buffer)` 返回 0 —— 无用例。
  10. `f_dbd/src/driver/DbdOptions.cj:69-81` 超时配置为 `0`/负数/非数字时的行为（负数 → 变成 `NO_TIMEOUT` 6 小时，而非"不限时/报错"）—— 无用例；`copy()` 的隔离性也无直接用例。
- **描述**：以上均为对外可见的错误码/分支，且多数是 fail-fast 契约的一部分（`spec.md:287-303`）；缺失使这些分支只有在生产事故中才会被首次执行。
- **建议**：按上表逐条补最小用例（多数可在现有 `StubFdbm`/`StubSender` 上完成），优先补 2/3/4/6（错误码契约）与 5（与 [严重] 第 1 条同源）。

#### [轻微] 占位文件与过期注释残留

- **位置**：`f_dbd/src/common/placeholder.cj:18-20`、`f_dbd/src/driver/placeholder.cj:18-20`、`f_dbd/src/multid/placeholder.cj:18-20`、`f_dbd/src/dbd.cj:18-20`
- **描述**：4 个文件只含注释，内容仍是"阶段 0 仅建骨架"；`dbd.cj` 还声称"驱动注册入口与对 `common` 的公开重导出"，但文件里没有任何声明。实现早已完成，这些说明会误导阅读者以为模块仍是骨架。
- **建议**：删除 3 个 `placeholder.cj`，修正或删除 `dbd.cj` 的过期说明（若确需根包文档，改为描述当前包结构）。

#### [轻微] `unknownOptionIsIgnored` 仅"不抛异常"

- **位置**：`f_dbd/src/driver/DbdDriver_test.cj:157-164`
- **描述**：无用例内断言；"未知 key 被忽略"这一语义实际无法与"未知 key 抛异常"区分（抛了也会被测试当成失败，但无法确认是被忽略还是被静默丢弃）。
- **建议**：加一条可观测断言，例如设置 `fetch_rows` 后经 `connect()` 读流的 `bufSize`，或对未知 key 断言随后的合法 `connect()` 仍成功且 `fetch_rows` 值未被覆盖。

#### [轻微] `MultiDUrl.tryParse` 与 `DbdUrl.tryParse` 的捕获范围不一致

- **位置**：`f_dbd/src/multid/Url.cj:81-87`（`catch (_: Exception)`）↔ `f_dbd/src/driver/DbdUrl.cj:114-121`（`catch (_: DbdException)`）
- **描述**：同一语义的两个"不抛版本"一个吞 `Exception`（含内存/反射等非配置异常），一个只吞 `DbdException`；调用方无法预期哪种失败会变成 `None`。
- **建议**：统一为 `catch (_: DbdException)`（`parseNode` 已把节点错误包成 `DbdException(CONFIG)`），使 `None` 只表示"URL 非法"。

#### [轻微] 性能实验以普通单测常驻，且复制了一份分派表

- **位置**：`f_dbd/src/common/dispatch_perf_test.cj:44-270`、`Dispatch`（同文件 366-522）↔ 生产分派 `f_dbd/src/common/result.cj:216-249`
- **描述**：`perTypeMatrix` + `missProbes` 每轮约 4.8×10⁸ 次分派并打印 6 张报表，`README.md:78-80` 已把它当作常驻"性能前置实验"；同时 `Dispatch.canonicalB` 与 `decodeCellAsAny` 是两份手工维护的 19 分支表，`result.cj` 新增/调整类型时这份实验不会失败，覆盖会悄悄失真。
- **建议**：把基准移出默认 `cjpm test`（`@Bench` 或 `test/bench/` 脚本），仅保留 `semanticDifferenceOnInterfaceImplementor`（它才是选型结论的回归）；分派表改为引用生产实现（暴露一个包内 `dispatchIndex<T>()`）或在 `result_test.cj` 增加"每个 §8 类型都能读回"的表驱动用例以保证两处同步。

#### [轻微] `IdGeneratorException` 未提供携带 `cause` 的构造器

- **位置**：`f_dbm/src/IdGenerator.cj:25-29`
- **描述**：`BaseException` 已提供 `init(message, caused)`（`f_base/src/BaseException.cj:52-57`），而 `IdGeneratorException` 只暴露 `init(message)`。第三方生成器在包装底层异常（如序列库故障）时只能丢掉原始异常，而 `f_dbm` 的其他约定（`DbdException.cause` 保留原始异常）恰恰强调要保留链条。
- **建议**：补 `public init(message: String, cause: Exception)`（转发 `super(message, cause)`），并在 README 的扩展示例中示范。

#### [轻微] f_dbm README 未说明两个扩展接口共用同一个 `name`

- **位置**：`f_dbm/README.md:58`（"同一实例可同时命中两者"）、`f_dbm/src/PartitionAlgorithm.cj:27` 与 `f_dbm/src/IdGenerator.cj:39`（各自声明 `name`）、`f_app/src/Initializer.cj:27`（同样声明 `name`）
- **描述**：类同时实现 `PartitionAlgorithm & IdGenerator & Initializer` 时三个接口的 `name` 合成一个实现，该值同时充当"分区算法名""生成器名""Initializer 标识"；`CustomLoader` 也正是用这个值给两张表建键（`fdbm/src/server/CustomLoader.cj:92-112`）。fdbm 详细设计 §10.5 末段有一句说明，f_dbm README 完全没有，第三方很容易给出一个只对其中一张表有意义的名字。
- **建议**：在 README 接口小节加一条"同时实现多个扩展点时只有一个 `name`，它同时是算法名/生成器名与 `Initializer` 标识"的显式说明（中英同步）。

---

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 4 |
| 一般 | 6 |
| 轻微 | 6 |

### 总评

f_dbd 的测试工程质量**整体高于仓库平均水平**：180 个用例基本围绕"可观测行为"而非"能编译"，游标状态机（无预读/无缓存/终态/关闭握手）、连接级结果集独占闸门、savepoint 注入、`@DataExclude` 线上键集合、`DataNone` 语义等关键不变量都有"断言请求序列/桩计数"的硬用例，且注释写明了每条用例要钉住的设计条目；未发现空测试类、被注释/禁用的用例或 `TODO` 占位，f_dbm 也没有空实现（两个接口 + 一个异常即其全部职责）。

但**覆盖分布不均且空白恰好压在风险点上**：类型矩阵（编码/解码/`readData`）只测了 §8 表的少数几类，`InputStream` 参数、未支持 `SqlDbType`、`Statement.close()` 后执行、`update_timeout`、`save/rollback(name)` 未 `begin` 等分支零用例；本次发现的 4 个严重问题中有 2 个（`readChunk(Int64.Max)` 的必崩分配、`DbdUrl` 的字节/字符下标混用）完全落在这些空白里，说明"按 spec 表驱动补齐 + 按错误码补负例"应作为下一步的硬门槛，而不是继续增加正向 happy-path。另有两处"文档承诺—实现—测试"三方不一致需要定调：`IdGeneratorException` 从未被 fdbm 映射为 `ID_GENERATOR`（导致 `step`+默认 `uuid` 的合理组合在运行期回 `INTERNAL`），以及"与内置算法重名必须启动失败"的约定在实现里变成了静默覆盖——后者会改变分库落点，建议在合入前修掉。

f_dbm 作为对外契约库没有任何测试，且 `tasks.md` 已明确把该用例列为交付项，属于"计划内未完成"，建议与上述 `IdGeneratorException` 映射一并补齐，使扩展契约至少有最小回归网。
