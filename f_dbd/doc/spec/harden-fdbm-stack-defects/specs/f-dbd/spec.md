## MODIFIED Requirements

### Requirement: 参数编码（MUST）

本要求为强制要求（MUST）。

`Statement.set<T>(index, value)` 在**运行期**按受支持类型判定（`T` 无编译期约束），命中即编码为对应 `Data`；`ToData` 兜底；不支持的类型抛异常并统一包装为 `DbdException(CONVERSION)`。索引 0 起，空洞按 `DataNone` 编码。

`InputStream` 参数必须**按有界块**读到 EOF 后再编码：单次临时缓冲不超过 `DEFAULT_STREAM_CHUNK`，总内存上界为「对象自身大小 + 一块缓冲」，**不得**按剩余长度或 `Int64.Max` 申请数组；读取期异常必须包成 `DataException` 并由 `Statement` 边界转为 `DbdException(CONVERSION)`。

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

#### Scenario: 流参数按块物化

- **GIVEN** 一个 1 MiB 的 `InputStream` 参数
- **WHEN** `set` 并执行语句
- **THEN** 编码成功、字节与源一致；编码器单次 `read` 的缓冲不超过 `DEFAULT_STREAM_CHUNK`，且不出现按剩余长度整块申请

#### Scenario: 流读取失败映射

- **GIVEN** 一个 `read` 抛 `IOException` 的流
- **WHEN** `set`
- **THEN** `DbdStatement` 抛 `DbdException(CONVERSION)`（不泄漏裸 `IOException`）

### Requirement: 流列分块读与随行失效（MUST）

本要求为强制要求（MUST）。

`get<InputStream>(index)` 返回 `DbdInputStream`：优先消费本地块，块空才发下一次块请求；返回 `0` 表示 EOF（服务端返回空数组）；**短块不算 EOF**；流随 `next()` 推进与 `close()` 失效。

NULL 判定：首次打开流列时发送 `CELL(index, bufSize = -1)` 的**探测**请求。服务端回 `DataNone` → `getOrNull<InputStream>` 返回 `None<InputStream>`、`get<InputStream>` 抛 `DbdException(CONVERSION)`；回字节块 → 该块作为流的首块先被消费。非 NULL 的空 BLOB 与 NULL 必须可区分。

流列**只能**以 `InputStream` 读取：对声明为流列的列调用 `get<Array<Byte>>` / `get<String>` 等标量目标 → `DbdException(CONVERSION)`，且**不发**列读请求（不得把首块当作完整值返回）。

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
- **THEN** 服务端收到的 `bufSize` 为 7（探测请求除外，缺省为 `DEFAULT_STREAM_CHUNK`）

#### Scenario: NULL 与空 BLOB 可区分

- **GIVEN** 同一查询的两行，一行为 NULL 流列，一行为 0 字节 BLOB
- **WHEN** `getOrNull<InputStream>`
- **THEN** 前者返回 `None`，后者返回 `Some(流)`（读即 0）；`get<InputStream>` 对前者抛 `CONVERSION`

#### Scenario: 探测请求向后兼容

- **GIVEN** 服务端尚未实现 `bufSize = -1`（按 `<= 0` 返回首块）
- **WHEN** 客户端打开 NULL 流列
- **THEN** 退化为「`Some(空流)`」而不报错、不崩溃（兼容旧服务端）

#### Scenario: 流列拒绝标量读取

- **GIVEN** 列类型为 `std.io.InputStream`
- **WHEN** 调用 `get<Array<Byte>>(i)` 或 `get<String>(i)`
- **THEN** 抛 `DbdException(CONVERSION)`，桩服务端未收到列读请求

### Requirement: 单元格取值的严格（B）口径（MUST）

本要求为强制要求（MUST）。

`get<T>` / `getOrNull<T>` 一律使用 `CELL_READ_FLAG`（`THROWING_ON_INT_OVERFLOW | IGNORE_FIELD_TYPE_NOT_MATCH`）：SQL NULL、数值越界、带小数部分、类型不可转换、索引越界 → 均抛 `DbdException(CONVERSION)`；不静默回绕或截断。

流列按上一条要求以探测请求判定 NULL：`getOrNull<InputStream>` 只对 SQL NULL 返回 `None`，`get<InputStream>` 对 NULL 抛 `CONVERSION`。

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

#### Scenario: 流列 NULL 同样精确

- **GIVEN** 流列值为 SQL NULL
- **WHEN** `getOrNull<InputStream>`
- **THEN** 返回 `None<InputStream>`

### Requirement: 列类型只认仓颉类型名（MUST）

本要求为强制要求（MUST）。

`f_dbd` 只识别 `f_dbd/doc/详细设计.md` §8 表内的仓颉类型名（`String`/`Bool`/`Int*`/`UInt*`/`Float*`/`Decimal`/`BigInt`/`Array<Byte>`/`InputStream`/`DateTime`/`Duration`）；未知拼写按 `String` 读取并记 WARN。识别顺序：精确匹配 → 去包名前缀 → 兜底为 `String`（**不得**把未识别类型当作流列）。**不做**方言与 `Sql*` 名的归一；归一表实现在 `f_dbd.common.SqlTypes`（供 fdbm 复用），但 f_dbd 的连接与结果集路径不调用它，线上只出现仓颉类型名。

`SqlTypes.readData` 是 fdbm 侧唯一取值入口：`Stream` 必须读到 EOF 后整块返回，`Unknown` 必须按 `String` 读取（并记 WARN），两者都不允许静默截断。

#### Scenario: 仓颉类型名原样命中

- **GIVEN** `typeName` 为 `Int64` / `std.io.InputStream` / `std.time.DateTime` / `Array<Byte>`
- **WHEN** 解析读取类型
- **THEN** 分别命中 `Int64` / `Stream` / `DateTime` / `Bytes`（带包名前缀形式与短名等价）

#### Scenario: 未知类型兜底为字符串

- **GIVEN** `typeName` 为某个未收录的拼写
- **WHEN** 读取该列
- **THEN** 按 `String` 读取并记一次 WARN，日志含原始 `typeName`

#### Scenario: 流列整块读出

- **GIVEN** 一个 200 KiB 的流列
- **WHEN** `SqlTypes.readData` 取值
- **THEN** 返回完整 200 KiB（不是首块 64 KiB）

### Requirement: 单节点驱动的 URL、选项与注册（MUST）

本要求为强制要求（MUST）。

驱动注册名 = `dbd_driverName`（后端物理库的方言名，如 `postgres` / `mysql`）；`fdbm` 只作为兼容别名保留（未被占用时注册），不再是规范名。`static init` 在未配置时**不得**结束进程：仅记 INFO 跳过注册，由 `dbdDriver()` 在取用时抛 `DbdException(CONFIG)`；`DbdDriver()` 无配置时同样抛 `CONFIG`（不 `exit`）。

`preferredPooling = true`，`open()` 不产生 IO；URL 形如 `fdbm://user:pwd@host:port/database`，凭据与 database 支持 `%XX`（按 UTF-8 字节编解码），缺省端口 8112；`database` 必填。

URL 解析的下标必须与 `String` 的字节下标一致：`indexOf`/`lastIndexOf` 的返回值直接用于字节切片；`%XX` 按字节解码后整体按 UTF-8 还原，非法 UTF-8 或残缺 `%` → `DbdException(CONFIG)`。

#### Scenario: URL 解析与重建

- **GIVEN** `fdbm://u:p%40w@127.0.0.1:8112/db0`
- **WHEN** `DbdUrl.parse` 后 `toUrl()`
- **THEN** 各段解析正确（密码已 % 解码），重建结果与原文等价（密码重新 % 编码）

#### Scenario: 非 ASCII 往返

- **GIVEN** 用户名、口令、库名均含中文的 URL（口令里的 `@`/`:` 用 `%40`/`%3A`）
- **WHEN** `parse` 后再 `toUrl()` 再 `parse`
- **THEN** 三次结果完全相同，无乱码、无截断

#### Scenario: 非法百分号编码

- **GIVEN** 含 `%FF`（非法 UTF-8）或 `%F`（残缺）的凭据/库名
- **WHEN** `parse`
- **THEN** 抛 `DbdException(CONFIG)`，不泄漏 `Rune` 构造异常

#### Scenario: 省略端口与缺库

- **GIVEN** 省略端口的 URL，以及 `database` 为空的 URL
- **WHEN** 解析
- **THEN** 前者端口取 8112，后者抛 `DbdException(CONFIG)`

#### Scenario: open 不建链

- **GIVEN** 一个未被监听的地址
- **WHEN** `DriverManager.getDriver('postgres').open(url, opts)`
- **THEN** 返回 `DbdDatasource` 成功（连接发生在 `connect()`）

#### Scenario: 未配置驱动名不影响进程

- **GIVEN** 未设置 `dbd_driverName`
- **WHEN** 首次加载 `fountain::f_dbd.driver`（如只使用 `multid`）
- **THEN** 包初始化正常完成；`dbdDriver()` 抛 `DbdException(CONFIG)`，进程继续运行

#### Scenario: 元数据不含密码

- **GIVEN** 一条已建链的连接
- **WHEN** 取 `getMetaData()`
- **THEN** 含 `driver`/`version`/`url`/`user`/`database`，**不含密码**

### Requirement: MultiD 多节点负载均衡（MUST）

本要求为强制要求（MUST）。

`MultiD` 注册为 `multidbd`、`preferredPooling = false`；URL scheme 接受 `multidbm://` 与 `multidbd://`；每个节点一个 `DatabasePool`（池化的是"到 fdbm 的连接"），按 `multidbm_loadbalance` 的加权随机/轮询选节点。

错误映射**只依据状态与异常类型**，不得依赖异常消息文本：本数据源或任一节点池已关闭 → `CONFIG`；其余 `ConnectionException`（池耗尽/等待超时）→ `TIMEOUT`。

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
- **THEN** 分别抛 `DbdException(CONFIG)` 与 `DbdException(TIMEOUT)`；把 `f_dbpool` 的关闭消息文本改掉后，`CONFIG` 判定仍成立

#### Scenario: scheme 两种写法都接受

- **GIVEN** `multidbm://…` 与 `multidbd://…` 两种连接串，以及一个其它 scheme
- **WHEN** `MultiD.open`
- **THEN** 前两者返回 `MultiDatasource`，第三者抛 `DbdException(CONFIG)`

## ADDED Requirements

### Requirement: 根包入口与公开重导出（MUST）

本要求为强制要求（MUST）。

`fountain::f_dbd` 根包必须提供：对 `common` 错误码与载荷类型、`exception.DbdException`、
`driver.{DbdDriver, DbdUrl, dbdDriver}`、`multid.{MultiD, MultiDUrl, MultiDatasource}` 的公开重导出，
以及取得模块版本字符串的入口。根包注释与文档不得再出现「阶段 0 / 空骨架」表述。

#### Scenario: 根包可直接取用

- **GIVEN** 只 `import fountain::f_dbd.*`
- **WHEN** 使用 `DbdUrl` / `DbdException` / `DbdErrorCode` / `MultiDUrl`
- **THEN** 编译通过，无需深层包路径

#### Scenario: 版本入口

- **GIVEN** 已链接 f_dbd
- **WHEN** 调用版本入口
- **THEN** 返回非空且含 `fountain`

### Requirement: 选项非法值不改变既有配置（MUST）

本要求为强制要求（MUST）。

`DbdOptions.apply` 对无法解析、`0`、负数的超时值必须**保留原值**并记 WARN；不得把已配置的超时清成「无限等待」。
`copy()` 返回独立副本，修改副本不影响源对象。

#### Scenario: 非法值保留原值

- **GIVEN** 已配置 `query_timeout = 30000`（毫秒）
- **WHEN** 再 `setOption(query_timeout, '30s')` 或 `'-1'`
- **THEN** 实际生效的超时仍为 30 秒，日志有 WARN

#### Scenario: 副本隔离

- **GIVEN** 源选项配置了超时
- **WHEN** 修改 `copy()` 的超时
- **THEN** 源对象的值不变
