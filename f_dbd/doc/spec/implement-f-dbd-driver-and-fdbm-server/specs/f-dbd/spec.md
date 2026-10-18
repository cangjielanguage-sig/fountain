## ADDED Requirements


### Requirement: 共用载荷的字段可解码性与线上键名（MUST）

本要求为强制要求（MUST）。

`SqlPayload` / `UpdateResultPayload` / `QueryResultServerPayload` / `QueryResultColumnPayload` / `QueryResultClosePayload` / `ColumnInfoImpl` / `DbdErrorPayload` 必须能被两端各自编码、解码；数据字段一律 `private var` 且在声明处带初值，接口只读属性以 `@DataExclude[field]` 排除出序列化。

#### Scenario: 载荷编解码往返保真

- **GIVEN** 一个填好字段的 `SqlPayload`（含 2 个参数）与一个全参构造的 `ColumnInfoImpl`
- **WHEN** 用 `DefaultCodec` 编码后再解码
- **THEN** 各字段逐个保真，参数个数与顺序一致

#### Scenario: 线上键集合恰好等于数据字段短名

- **GIVEN** `UpdateResultPayload(3, 7)` 与一个全参 `ColumnInfoImpl`
- **WHEN** 取 `toData()` 的键集合
- **THEN** 前者恰好是 `{rc, liid}`，后者恰好是 `{nm, tn, len, scl, nl, ds}`，**一个不多**（接口属性 `rowCount`/`name`/… 不得出现）

#### Scenario: 写成 let 字段会静默丢值（回归红线）

- **GIVEN** 一个把数据字段声明为 `private let` 的载荷变体
- **WHEN** 走默认 flag 解码
- **THEN** 该字段停留在构造初值（值丢失），用例必须按 `var` 写法保持通过

### Requirement: 异构载荷的严格判别（MUST）

本要求为强制要求（MUST）。

`decodeStrict<T>` 必须用 `DEFAULT_DATA_FLAG & !SILENCE`（保留溢出策略位、清掉全部 `IGNORE_*`），使"这一条 CONSUME 上是哪种载荷"只由结构决定。

#### Scenario: 各类载荷都能被严格解出

- **GIVEN** `SqlPayload` / `QueryResultColumnPayload` / `QueryResultServerPayload` / `UpdateResultPayload` / `DbdErrorPayload` 各自的编码结果
- **WHEN** 逐个用 `decodeStrict<对应类型>` 判别
- **THEN** 各自恰好命中自身类型（含整数字段的四类均能解出）

#### Scenario: 交叉喂入互相不命中

- **GIVEN** 上述任意两类载荷的 `DataObject`
- **WHEN** 交叉喂给对方的 `decodeStrict`
- **THEN** 返回 `None`，不抛异常、不产出"字段为空的同形对象"

#### Scenario: 结构合法但数值越界仍算命中

- **GIVEN** 一个字段为越界 `DataReal` 的合法载荷
- **WHEN** 用 `decodeStrict` 判别
- **THEN** 命中（返回 `Some`），且**不抛出 `OverflowException`**

### Requirement: 查询首包只描述列信息（MUST）

本要求为强制要求（MUST）。

`QueryResultServerPayload` 只携带 `columnInfos`，**不携带任何行状态**（无 `hasData`、无首行数据）；它不实现 `QueryResult`。

#### Scenario: 首包不含行状态字段

- **GIVEN** 一次查询的 RESP
- **WHEN** 解出 `QueryResultServerPayload`
- **THEN** 只有 `columnInfos`，没有任何表示"是否有第一行"的字段

#### Scenario: 空结果集与空列信息都可构造

- **GIVEN** 服务端返回 0 行的结果集
- **WHEN** f_dbd 解出首包并构造结果集对象
- **THEN** 构造成功，`columnInfos` 与服务端一致，且不产生任何行状态假设

### Requirement: 列读与推进共用 QueryResultColumnPayload（MUST）

本要求为强制要求（MUST）。

同一 payload 用 `index >= 0` 表示读当前行第 index 列、用 `NEXT_ROW(-1)` 表示推进；**不存在** `CLOSE_CURSOR(-2)` 之类的关闭哨兵，也没有 `closeCursor()` 工厂。

#### Scenario: 单元格请求

- **GIVEN** 当前行可读
- **WHEN** 调用 `get<T>(0)`
- **THEN** 发出 `QueryResultColumnPayload(index = 0, bufSize = 0)`（流列按 `chunkSize` 填 `bufSize`）

#### Scenario: 推进请求

- **GIVEN** 一个已构造的结果集
- **WHEN** 调用 `next()`
- **THEN** 发出 `QueryResultColumnPayload(index = NEXT_ROW)`，并以 `DataBool` 响应判定是否有新行

#### Scenario: 关闭哨兵不存在

- **GIVEN** `QueryResultColumnPayload` 的工厂方法集合
- **WHEN** 检查其可构造的 `index`
- **THEN** 只有单元格与 `NEXT_ROW` 两种语义，不存在表示"关闭"的负索引哨兵

### Requirement: 关闭游标走 UNSUBSCRIBE/ACK 且携带 qid（MUST）

本要求为强制要求（MUST）。

结果集的 `close()` 必须发 `Message.unsubscribe(data: QueryResultClosePayload(qid))` 并等到 `ACK`；`qid` 取自查询 RESP 的 `Message.id.toString()`。关闭**不**走列读通道。

#### Scenario: 关闭握手时序

- **GIVEN** 一个已打开的结果集，服务端可应答
- **WHEN** 调用 `close()`
- **THEN** 发出一条 `UNSUBSCRIBE`，载荷为 `QueryResultClosePayload(qid)`，`qid` 等于该查询 RESP 的 `Message.id.toString()`
- **AND** 收到 `ACK` 后 `isClosed()` 为 `true`，本地状态已释放

#### Scenario: close 幂等

- **GIVEN** 一个已 `close()` 的结果集
- **WHEN** 再次 `close()`
- **THEN** 不再发任何请求，仍返回成功

#### Scenario: 关闭失败仍本地关闭

- **GIVEN** 一个结果集，服务端对 `UNSUBSCRIBE` 回 `ERROR` 或超时
- **WHEN** 调用 `close()`
- **THEN** 异常被吞掉、`isClosed()` 为 `true`、已打开的流失效；`ERROR` 时连接保持可用，超时/断链才置 `Broken`

#### Scenario: qid 不匹配时服务端幂等 ACK

- **GIVEN** 服务端当前没有与 `qid` 匹配的游标
- **WHEN** 收到该 `UNSUBSCRIBE`
- **THEN** 服务端回 `ACK`，且**不关闭**任何其它游标

### Requirement: 结果集无预读、无缓存（MUST）

本要求为强制要求（MUST）。

`next()` 每次调用（含第一次）都真正发一次 `NEXT_ROW`；`get`/`getOrNull` 每次调用都真正发一次列读请求；客户端不保存行缓冲或单元格缓存。唯一例外是"已耗尽/已关闭"两个终态。

#### Scenario: 首次 next 就发包

- **GIVEN** 一个结果集，桩服务端脚本化 3 行
- **WHEN** 第一次调用 `next()`
- **THEN** 桩收到 1 次 `NEXT_ROW` 请求并返回 `true`

#### Scenario: 重复 get 重复发包

- **GIVEN** 当前行第 0 列已被读取一次
- **WHEN** 再次 `get<String>(0)`
- **THEN** 桩收到第 2 次 `CELL(0)` 请求，值由服务端当前行缓冲应答

#### Scenario: 耗尽是终态

- **GIVEN** `next()` 已返回 `false`
- **WHEN** 再次调用 `next()`
- **THEN** 仍返回 `false`，且**不再发请求**

#### Scenario: 构造期不发请求

- **GIVEN** 一个桩发送器（计数为 0）
- **WHEN** 由首包构造结果集
- **THEN** 桩计数仍为 0

### Requirement: 单元格取值的严格（B）口径（MUST）

本要求为强制要求（MUST）。

`get<T>` / `getOrNull<T>` 一律使用 `CELL_READ_FLAG`（`THROWING_ON_INT_OVERFLOW | IGNORE_FIELD_TYPE_NOT_MATCH`）：SQL NULL、数值越界、带小数部分、类型不可转换、索引越界 → 均抛 `DbdException(CONVERSION)`；不静默回绕或截断。

#### Scenario: 区间内精确取值

- **GIVEN** 列值为 `DataReal(1)`
- **WHEN** 分别 `get<Int64>` / `get<Int32>`
- **THEN** 得到精确值，无精度损失

#### Scenario: 越界与分数即报错

- **GIVEN** 列值 `DataReal(300)` 与 `DataReal(3.7)`
- **WHEN** 以 `get<Int8>` / `get<Int64>` 读取
- **THEN** 抛 `DbdException(CONVERSION)`，且**不**返回回绕/截断后的值

#### Scenario: NULL 的可空语义

- **GIVEN** 列值为 `DataNone`（SQL NULL）
- **WHEN** 调用 `getOrNull<T>`
- **THEN** 返回 `None<T>`；`get<T>` 则抛 `DbdException(CONVERSION)`

#### Scenario: 宽松转换保留

- **GIVEN** 任意类型的列值
- **WHEN** 以 `get<String>` 读取
- **THEN** 得到 `toString()` 结果，不报错

### Requirement: 列类型只认仓颉类型名（MUST）

本要求为强制要求（MUST）。

`f_dbd` 只识别 `f_dbd/doc/详细设计.md` §8 表内的仓颉类型名（`String`/`Bool`/`Int*`/`UInt*`/`Float*`/`Decimal`/`BigInt`/`Array<Byte>`/`InputStream`/`DateTime`/`Duration`）；未知拼写按 `String` 读取并记 WARN。识别顺序：精确匹配 → 去包名前缀 → 兜底。**不做**方言与 `Sql*` 名的归一；归一表实现在 `f_dbd.common.SqlTypes`（供 fdbm 复用），但 f_dbd 的连接与结果集路径不调用它，线上只出现仓颉类型名。

#### Scenario: 仓颉类型名原样命中

- **GIVEN** `typeName` 为 `Int64` / `std.io.InputStream` / `std.time.DateTime` / `Array<Byte>`
- **WHEN** 解析读取类型
- **THEN** 分别命中 `Int64` / `Stream` / `DateTime` / `Bytes`（带包名前缀形式与短名等价）

#### Scenario: 未知类型兜底为字符串

- **GIVEN** `typeName` 为某个未收录的拼写
- **WHEN** 读取该列
- **THEN** 按 `String` 读取并记一次 WARN，日志含原始 `typeName`

### Requirement: 参数编码（MUST）

本要求为强制要求（MUST）。

`Statement.set<T>(index, value)` 在**运行期**按受支持类型判定（`T` 无编译期约束），命中即编码为对应 `Data`；`ToData` 兜底；不支持的类型抛异常并统一包装为 `DbdException(CONVERSION)`。索引 0 起，空洞按 `DataNone` 编码。

#### Scenario: 表驱动编码

- **GIVEN** §8 左列每种受支持类型的值
- **WHEN** 逐个 `set`
- **THEN** 编码为对应的 `Data` 子类（`DataBool` / `DataReal` / `DataString` / `DataDateTime` / `DataDuration` / `DataCollection<Array<UInt8>, UInt8>`）

#### Scenario: 顺序与空洞

- **GIVEN** `set<String>(0,'a')`、`set<Int64>(2,1)`（跳过 1）
- **WHEN** 执行语句
- **THEN** 服务端收到的参数按索引升序为 `['a', DataNone, 1]`

#### Scenario: 不支持的类型

- **GIVEN** 一个既不在支持表内、也不实现 `ToData` 的值
- **WHEN** `set`
- **THEN** 抛 `DbdException(CONVERSION)`

### Requirement: 流列分块读与随行失效（MUST）

本要求为强制要求（MUST）。

`get<InputStream>(index)` 返回 `DbdInputStream`：优先消费本地块，块空才发下一次块请求；返回 `0` 表示 EOF（服务端返回空数组）；**短块不算 EOF**；流随 `next()` 推进与 `close()` 失效。

#### Scenario: 多块顺序读出

- **GIVEN** 服务端按 3 块应答
- **WHEN** 反复 `read(buffer)`
- **THEN** 字节序与总长正确，读尽后返回 0

#### Scenario: 短块不是 EOF

- **GIVEN** 服务端某次只回了小于 `buffer` 长度的字节
- **WHEN** 继续 `read`
- **THEN** 继续请求下一块，不把短块当作流结束

#### Scenario: 行切换后旧流失效

- **GIVEN** 当前行上已打开一个流
- **WHEN** 调用 `next()` 后对该旧流 `read`
- **THEN** 抛 `DbdException(CURSOR_STATE)`

#### Scenario: 块大小可配

- **GIVEN** 连接级/语句级 `fetch_rows = 7`
- **WHEN** 读流列
- **THEN** 服务端收到的 `bufSize` 为 7（缺省为 `DEFAULT_STREAM_CHUNK`）

### Requirement: 打开的 QueryResult 独占连接（MUST）

本要求为强制要求（MUST）。

同一连接上只要有未关闭的 `QueryResult`（**含已耗尽但未 `close()`**），任何 `Statement` 的 `query`/`update` 与 `DbdTransaction` 的 `begin`/`commit`/`rollback`/`save`/`rollback(name)`/`release` 都必须直接抛 `DbdException(CURSOR_STATE)`，**不发任何包**。多个 `Statement` 对象可并存，`prepareStatement`/`createTransaction`/`set`/`Statement.close` 不受限。

#### Scenario: 结果集未关闭时拒绝新 SQL

- **GIVEN** 连接上有一个已打开的结果集
- **WHEN** 用同连接的任意 `Statement` 执行 `query()` 或 `update()`
- **THEN** 抛 `DbdException(CURSOR_STATE)`，桩服务端未收到任何请求

#### Scenario: 已耗尽但未 close 仍视为打开

- **GIVEN** `next()` 已返回 `false`，结果集未 `close()`
- **WHEN** 执行 `update()`
- **THEN** 抛 `DbdException(CURSOR_STATE)`，不发包

#### Scenario: 关闭后恢复

- **GIVEN** 结果集已 `close()`
- **WHEN** 再次执行 SQL
- **THEN** 正常发包执行

#### Scenario: Statement 对象可并存

- **GIVEN** 同连接上创建了两个 `DbdStatement`
- **WHEN** 仅做 `prepareStatement` / `set` / `Statement.close`
- **THEN** 不受结果集独占约束

### Requirement: 游标状态错误 fail-fast（MUST）

本要求为强制要求（MUST）。

服务端无游标（被新语句顶掉、连接被静默重建）时，`next()` 抛 `DbdException(CURSOR_STATE)`，**不得静默返回 `false`**；未 `next()` 就 `get` 同样抛 `CURSOR_STATE`。

#### Scenario: 无游标时 next 报错

- **GIVEN** 服务端当前会话没有游标
- **WHEN** 客户端调用 `next()`
- **THEN** 抛 `DbdException(CURSOR_STATE)`，不返回 `false`

#### Scenario: 未定位就取值

- **GIVEN** 结果集尚未 `next()` 或当前行已失效
- **WHEN** 调用 `get`/`getOrNull`
- **THEN** 抛 `DbdException(CURSOR_STATE)`

#### Scenario: 连接静默重建后 fail-fast

- **GIVEN** f_net 客户端心跳失败并静默重建了 TCP 连接
- **WHEN** 客户端继续操作旧游标
- **THEN** 得到 `CURSOR_STATE`（事务操作得到 `TX_STATE`），不产生静默的错误数据

### Requirement: 单节点驱动的 URL、选项与注册（MUST）

本要求为强制要求（MUST）。

`DbdDriver` 在 `static init` 注册为 `fdbm`，`preferredPooling = true`，`open()` 不产生 IO；URL 形如 `fdbm://user:pwd@host:port/database`，凭据支持 % 编码，缺省端口 8112；`database` 必填。

#### Scenario: URL 解析与重建

- **GIVEN** `fdbm://u:p%40w@127.0.0.1:8112/db0`
- **WHEN** `DbdUrl.parse` 后 `toUrl()`
- **THEN** 各段解析正确（密码已 % 解码），重建结果与原文等价（密码重新 % 编码）

#### Scenario: 省略端口与缺库

- **GIVEN** 省略端口的 URL，以及 `database` 为空的 URL
- **WHEN** 解析
- **THEN** 前者端口取 8112，后者抛 `DbdException(CONFIG)`

#### Scenario: open 不建链

- **GIVEN** 一个未被监听的地址
- **WHEN** `DriverManager.getDriver('fdbm').open(url, opts)`
- **THEN** 返回 `DbdDatasource` 成功（连接发生在 `connect()`）

#### Scenario: 元数据不含密码

- **GIVEN** 一条已建链的连接
- **WHEN** 取 `getMetaData()`
- **THEN** 含 `driver`/`version`/`url`/`user`/`database`，**不含密码**

### Requirement: 请求传输、超时与断链（MUST）

本要求为强制要求（MUST）。

`DbdTransport.request` 发 `CONSUME(once: true, qos: AtMostOnce)` 并等 `RESP`/`ERROR`；`None` 视为超时/断链 → `DbdException(TIMEOUT|IO)` 并**立即关闭传输、置 `Broken`、失效当前游标与事务**；非 `RESP`/`ERROR` → `DbdException(PROTOCOL)`；`ERROR` 还原为 `DbdException`（含 `sqlState`），连接保持可用。

#### Scenario: 正常与错误回包

- **GIVEN** 桩分别回 `RESP` 与 `ERROR`
- **WHEN** 发请求
- **THEN** 前者返回响应；后者抛 `DbdException` 且 `code`/`sqlState` 与服务端一致

#### Scenario: 超时即断开并置 Broken

- **GIVEN** 桩不回包且超时很短
- **WHEN** 发请求
- **THEN** 抛 `DbdException(TIMEOUT)`，传输已关闭、`state` 为 `Broken`

#### Scenario: SQL 语义错误不毁连接

- **GIVEN** 服务端回 `ERROR(SQL_SYNTAX)`
- **WHEN** 继续在同一连接上发合法请求
- **THEN** 请求成功，连接未被置 `Broken`

### Requirement: 事务语句透传（MUST）

本要求为强制要求（MUST）。

`DbdTransaction` 把 `begin` / `commit` / `rollback` / `savepoint` / `rollback to savepoint` / `release savepoint` 作为 SQL 文本发给 fdbm；隔离级别等三个属性只记录、不下发；`savepoint` 名必须通过标识符校验。

#### Scenario: 语句透传

- **GIVEN** 一个事务对象
- **WHEN** 依次 `begin()` / `save('s1')` / `rollback('s1')` / `release('s1')` / `commit()`
- **THEN** 服务端依次收到对应的会话控制 SQL 文本

#### Scenario: 状态错误

- **GIVEN** 未 `begin()` 的事务
- **WHEN** `commit()` / `rollback()`
- **THEN** 抛 `DbdException(TX_STATE)`；已 `begin` 再 `begin` 同样报错

#### Scenario: savepoint 名注入防护

- **GIVEN** 含空格或分号的 savepoint 名
- **WHEN** 调用 `save(name)`
- **THEN** 抛 `DbdException(PROTOCOL)`，且未发出任何包

### Requirement: MultiD 多节点负载均衡（MUST）

本要求为强制要求（MUST）。

`MultiD` 注册为 `multidbd`、`preferredPooling = false`；URL scheme 接受 `multidbm://` 与 `multidbd://`；每个节点一个 `DatabasePool`（池化的是"到 fdbm 的连接"），按 `multidbm_loadbalance` 的加权随机/轮询选节点。

#### Scenario: 权重分布与桶内取值

- **GIVEN** 两节点权重 `2,1`，每次取到后立即归还
- **WHEN** 连续 `connect()` 100 次
- **THEN** 分布比例接近 2:1（统计断言，带容差）

#### Scenario: 只有首节点有权重时全落首节点

- **GIVEN** 权重列表只有第一个节点非零
- **WHEN** 连续 `connect()` 100 次
- **THEN** 全部落在第一个节点（钉死取值区间落在权重桶内部的接线）

#### Scenario: 池已关闭与池耗尽

- **GIVEN** `MultiDatasource` 已 `close()`，或池耗尽且等待超时
- **WHEN** `connect()`
- **THEN** 分别抛 `DbdException(CONFIG)`（`ConnectionException` 映射）与 `DbdException(TIMEOUT)`

#### Scenario: scheme 两种写法都接受

- **GIVEN** `multidbm://…` 与 `multidbd://…` 两种连接串，以及一个其它 scheme
- **WHEN** `MultiD.open`
- **THEN** 前两者返回 `MultiDatasource`，第三者抛 `DbdException(CONFIG)`
