# fountain实现思想与应用第十二弹

##### ——数据库中间件

项目链接：https://gitcode.com/Cangjie-TPC/fountain

数据库中间件的介绍通常从分库分表算法开始，但决定它能不能落地的往往不是路由算法，而是：

> **现有代码要改多少行？**

如果为了接中间件，业务要把 `Connection`、`Statement`、`ResultSet` 全换一遍、把 ORM 换掉，分片算法再完整也难以推广。fountain 的数据库中间件围绕这个问题设计，答案拆成三个模块：

| 模块 | 角色 | 形态 |
| --- | --- | --- |
| `f_dbd` | 应用侧驱动 | 动态库，实现 `std.database.sql` 的 `Driver` |
| `fdbm` | 中间件本体 | 可执行程序，常驻监听 8112 |
| `f_dbm` | 扩展契约 | 动态库，第三方算法/ID 生成器的接口 |

```
   app（f_orm / 任何 std.database.sql 代码）
        │   URL: fdbm://user:pwd@host:8112/order
        ▼
   f_dbd   驱动层：只发 SQL 和参数、按需拉结果
        │   CONSUME(SqlPayload) / NEXT_ROW / UNSUBSCRIBE
        ▼
   fdbm    代理层：解析 SQL → 路由 → 改写 → 下推 → 汇总
        │   物理驱动（driver/ 目录里恰好一个）
        ▼
   PostgreSQL / MySQL（多节点、多物理库）
```

---

## 一、最重要的一步：做成一个「标准驱动」

`f_dbd` 没有发明新 API。它实现的是 `std.database.sql` 的 `Driver` / `Datasource` / `Connection` / `Statement` / `QueryResult` / `Transaction`，所以应用侧看到的就是标准接口：

```cangjie
import std.database.sql.*
import fountain::f_dbd.*

main() {
    let driver = dbdDriver()
    let datasource = driver.open("fdbm://user:pwd@127.0.0.1:8112/order", [])
    let connection = datasource.connect()
    let statement = connection.prepareStatement("select id, name from t where id = ?")
    statement.set<Int64>(0, 1)
    let result = statement.query()
    while (result.next()) {
        println(result.get<Int64>(0))
        println(result.getOrNull<String>(1) ?? "")
    }
    result.close()
    connection.close()
}
```

这段代码里，只有 `dbdDriver()` 和 URL 的 scheme 是 fountain 的，其余全是标准库。**中间件替掉物理驱动时，`prepare` / `query` / `get` 这一段业务代码一行不用改**——这才是中间件该有的接入成本。

### 一个反直觉的配置：`dbd_driverName` 必须是物理库方言

```bash
export dbd_driverName=postgres
```

不能写成 `fdbm`：**fdbm 是代理，它自己没有方言**。SQL 方言（标识符要不要用双引号、`LIMIT` 怎么写、`RETURNING` 支不支持）最终由物理库决定；而 `f_orm` 这类上层是按**驱动名**选方言的。

所以这个配置项的本质是：「**告诉上层，这个连接背后是哪种方言**」。名字取错，SQL 渲染就会用错规则——这是接入时第一个要检查的地方。

未配置或为空时，包初始化只记 INFO 并跳过注册，**不结束进程**；真正取用 `dbdDriver()` 时才抛 `DbdException(CONFIG)`。这个「晚失败」的选择是为了让「同一个二进制里既有数据库业务、也有不碰数据库的命令」的场景不至于起不来。

---

## 二、逻辑库、物理库、节点：三层层级

fdbm 的配置模型只有三层，理解了这三层，后面所有配置项都能对上号。

```
 逻辑库 order            ← 应用看到的库（fdbm_db_logicalDatabase_order）
   ├── 物理库 order_0     ← 一个物理库一个连接池
   │    ├── 节点 db1:5432
   │    └── 节点 db1_s:5432   （从库，读权重）
   └── 物理库 order_1
        ├── 节点 db2:5432
        └── ...
```

```bash
# 节点清单：<node>@<host>:<port>
export fdbm_db="db1@10.0.0.1:5432;db1_s@10.0.0.2:5432;db2@10.0.0.3:5432"

# 每个节点的驱动与承载的物理库（逗号分隔，每库一个池）
export fdbm_db_driver_db1=postgres
export fdbm_db_database_db1=order_0,order_1
export fdbm_db_username_db1=app
export fdbm_db_password_db1=secret

# 逻辑库 → 物理库列表
export fdbm_db_logicalDatabase_order=order_0,order_1
```

口径有三条，都很重要：

1. **只有显式声明的名字才是逻辑库**，物理库不会自动变成逻辑库；
2. 被 `fdbm_partition__<table>` 引用但没声明的逻辑库，隐式包含**全部**物理库；
3. **全局表不创建逻辑库**——这是刻意的，避免 `fdbm_global__<table>` 的值拼错时，启动阶段发现不了。

第 3 条体现了一个一致的原则：**能启动自检发现的问题，不要留到运行期**。fdbm 在 accept 第一个连接之前会做完整自检（驱动唯一性、扩展加载与重名、跨项引用、算法参数、超时取值），任一失败直接退出：

| 失败 | 错误码 |
| --- | --- |
| 配置缺失/非法 | `CONFIG` |
| `driver/` 里不是恰好一个驱动 | `NO_DRIVER` |
| 分区算法配置错 | `PARTITION_CONFIG` |
| ID 生成器配置错 | `ID_GENERATOR` |

宁可起不来，也不要带着错配置对外服务——**中间件一旦带病运行，排查成本会摊到每个业务方身上**。

---

## 三、路由：五种结果，而不是「命中/不命中」

fdbm 把一条 SQL 的路由结果分成五态（`RouteKind`）：

| 状态 | 含义 | 典型语句 |
| --- | --- | --- |
| `Single` | 命中一个物理库 | 带分库键的 `SELECT` / `INSERT` |
| `Multi` | 命中多个物理库 | 不带分库键但可枚举的查询 |
| `Broadcast` | 广播到逻辑库全部物理库 | 全局表写入、DDL |
| `Empty` | 结果必然为空 | 分库键落在不存在的库 |
| `Unroutable` | 无法路由 | 没有分库键条件的 `UPDATE` / `DELETE` |

这个五态划分比「路由成功/失败」有用得多，因为它直接决定了执行策略：

- `Single`：原语句下推，一次往返；
- `Multi`：逐库执行，游标按库顺序拼接结果；`count(*)` 求和，但 **`ORDER BY` / `LIMIT` 是按分片下推的**，不是全局排序、全局分页；
- `Broadcast`：写全部下推（全局表），读只取一份副本；
- `Empty`：直接返回空结果，**不碰数据库**；
- `Unroutable`：报 `ROUTE_FAILED`，**不做全分片删除**。

`DELETE` 在没有分库键条件时，fdbm 的做法是「先按条件查出受影响行的分库键，再逐库删除」，而不是「广播删除」。这不是能力不足，而是**拒绝执行危险的默认行为**：一条不带条件的 `delete from t` 广播到分片环境，无法回滚。

### 分库算法

```bash
# <逻辑库>,<算法>,<分库列>
export fdbm_partition__order="order,hash,user_id"
export fdbm_partition_step=10000000
export fdbm_partition_substr__order="0,4,crc32"
```

内置 8 种：`step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr`。`substr` 还需要单独的配置指明「起始位置、长度、哈希算法」。

算法本身没什么可讲的，值得讲的是**分库缓存**：

```bash
export fdbm_cache=true
export fdbm_cache_expire=30s     # 留空 = 永不过期
export fdbm_cache_size=0         # 0 = 不限；超限后不再写入新键（既有键照常命中）
export fdbm_cachePath=./cache
```

它缓存的是「分库键 → 物理库」的映射，落在 `f_store`（本地文件）里。分库键的分布**高度倾斜**：电商场景里 80% 的查询集中在 20% 的热门用户上，每次用 `murmur` 算一遍不贵，但每次都走一遍 SQL 解析 + 路由决策，成本更高。

注意 `size` 超限后的行为是「不再写入新键」，而不是 LRU 淘汰——**已有的热键继续命中，冷键退化成实时计算**。这是一个偏保守但不会抖动的策略。

---

## 四、读写分离：不新增机制，只调权重

读写权重写成 `w,<n>;r,<n>`，`0` 表示不参与该方向：

```bash
# 主库：可写可读
export fdbm_loadbalance_weight_db1="w,1;r,0"
# 从库：只读
export fdbm_loadbalance_weight_db1_s="w,0;r,1"
```

`w` 是写权重，`r` 是读权重，`0` 表示不参与该方向。于是：

- 写请求只会路由到 `w > 0` 的节点 → 主库；
- 读请求只会路由到 `r > 0` 的节点 → 从库。

**读写分离不需要独立的开关、不需要 SQL 改写规则、不需要单独的连接池**，它就是负载均衡权重的一个特例。这套机制还能继续叠加：主库 `w,1;r,1`、从库1 `w,0;r,2`、从库2 `w,0;r,1`，就得到「写走主、读按 2:1 分摊到两个从库」。

库级权重 `fdbm_loadbalance_weight_<node>__<db>` 优先于节点级，用于「同一个节点上，`order` 库可读、`log` 库只写」这类细粒度控制。

---

## 五、结果集协议：用 RTT 换内存

传统 JDBC 风格的做法是「查询时预读一批到客户端缓冲」，fdbm 的做法是**完全不预读**：

| 动作 | 协议 | 说明 |
| --- | --- | --- |
| 查询 | `CONSUME(SqlPayload)` → `RESP(QueryResultServerPayload)` | 首包**只有列信息**，没有数据 |
| 取行 | `NEXT_ROW` | **每次** `next()`（含第一次）都发一次，服务端执行一次物理 `next()` |
| 读列 | 列读请求 | **每次** `get` / `getOrNull` 都发一次，服务端从「当前行缓冲」应答 |
| 关闭 | `UNSUBSCRIBE(QueryResultClosePayload(qid))` → `ACK` | 幂等，不存在 `CLOSE_CURSOR` 负索引哨兵 |

代价是一次 1000 行的查询、每行读 5 列，需要 1 + 1000 + 5000 次往返。同机房低延迟网络下可以接受；跨机房时往返次数不变，总延迟按次数线性增长。

收益是**服务端的内存占用与结果集大小无关**：一个 `select * from big_table` 不会因为客户端忘记 `close()` 而占满中间件内存；游标只是一个「位置」，缓冲只有当前一行。

所以这套协议适合的场景是：**结果集大小不可控、或者客户端处理速度慢于生产速度**。fdbm 用 `fdbm_databasePoolMaxSize` 控制并发长游标数——因为每个打开的游标都占着一个物理连接：

```bash
export fdbm_databasePoolMaxSize=1     # 默认 1；并发长游标/长事务多时必须调大
```

默认值 1 偏保守：每个打开的游标占一个物理连接，并发长游标一多就会等连接。业务出现等连接时，先检查这个值。

几个协议细节：

- **类型口径 B**：线上只出现仓颉类型名（`String` / `Int64` / `Decimal` / `DateTime` / `Array<Byte>`…），NULL 只有 `getOrNull` 返回 `None`，`get` 遇到 NULL 抛 `CONVERSION`。
- **流列**：只有物理驱动自报 `InputStream` 时才是流；同一行同一列只打开一个句柄，按 `fetchRows` 分块读，空块表示 EOF。
- **NULL 与空 BLOB 的区分**：首次打开流列会发 `CELL(index, -1)` 探测。SQL NULL → `getOrNull<InputStream>` 返回 `None`；空 BLOB → `Some(空流)`。这两个如果不区分，业务会把「没有照片」和「照片是 0 字节」当成一回事。
- **流列只能按流读**：对 `InputStream` 列调 `get<Array<Byte>>` 直接抛 `CONVERSION`，不发列读请求。

### 会话与退出

**一条 TCP 就是一个会话**，同一连接同一会话。`f_net` 没有断连回调，所以 fdbm 靠 `fdbm_sessionSweepInterval`（默认 30s）巡检回收会话、游标和连接。

优雅停止的顺序是固定的：

```
停止接受新连接 → 等在途请求（fdbm_shutdownTimeout，默认 30s）
→ 关闭全部会话与游标（归还借用连接）→ 逐池 closeAndAwait
→ 关闭分库缓存 → 退出码 0
```

注意「关闭游标」要在「关池」之前：游标持有借用连接，先关池会卡住。

---

## 六、主键怎么办：ID 生成器的介入时机

分库之后，自增主键会冲突。fdbm 的 ID 生成器有一个很克制的设计：**只在 INSERT 缺分库列值时介入**。

```bash
export fdbm_idmaker=uuid,1          # uuid[,1|4|6|7]
export fdbm_idmaker=snowflake,3     # snowflake[,0..1023]
export fdbm_idmaker=sequence
export fdbm_sequenceDatabase=order_0
```

- `uuid` / `snowflake` 与表无关，全局可用；
- `sequence` 按 `(逻辑库, 表)` 在唯一分配库取号，要求存在
  `fountain_sequence(table_name, current_value, increment)`，取号走「事务 + `select ... for update`」；
- 没配生成器又缺分库列值 → `ROUTE_FAILED`。

「只在缺值时介入」意味着：**业务自己给的 ID 不会被覆盖**。迁移历史数据、或者用业务主键（订单号）做分片键时，中间件不覆盖业务给出的值。

---

## 七、扩展：为什么契约要单独一个模块

`fdbm` 是可执行程序，外部**无法 import 它的声明**。所以扩展契约下沉到了 `f_dbm`：

```cj
package fountain::f_dbm;

public interface PartitionAlgorithm {
    prop name: String                 // 对应 fdbm_partition__<table> 的算法名
    func partition<K>(key: K): String // 返回物理库名
}

public interface IdGenerator {
    prop name: String
    func nextStringId(): String       // 默认抛 IdGeneratorException
    func nextIntId(): Int64           // 默认抛 IdGeneratorException
}
```

写一个扩展：

```cj
package my.ext

import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_dbm.PartitionAlgorithm

class MyPartition <: PartitionAlgorithm & Initializer {
    static init() {
        InitializerCollection.register(MyPartition())   // 必须在 static init 里注册
    }
    private init() {}

    public prop name: String { get() { "myhash" } }

    public func partition<K>(key: K): String { /* ... */ }

    public func initialize(): Unit {
        // 只能读 Config、准备自身状态；此时 fdbm 的资源/驱动/服务都还没创建
    }
}
```

编译成动态库放进部署目录的 `custom/`，fdbm 启动时会：

1. 把 `custom/` 下**全部**动态库 `PackageInfo.load`；
2. 调一次 `InitializerCollection.initialize()`（这样各库 `static init` 的注册都能被看到）；
3. 用两轮模式匹配收集 `PartitionAlgorithm` 与 `IdGenerator`；
4. **名字必须唯一**：自定义之间重名 → 启动失败；与内置（`step`/`hash`/`std`/`crc16`/`crc32`/`crc64`/`murmur`/`substr`、`uuid`/`snowflake`/`sequence`）重名 → 也启动失败。

第 4 条是一个被反复讨论过的决策：**同名时命中哪个实现取决于加载顺序，排查成本极高；直接报错更好定位。** 它放弃了一点「可覆盖内置实现」的灵活性，换来的是「配置和实际行为永远一一对应」。

---

## 八、SQL 能力的边界（重要）

fdbm 不是「什么 SQL 都能跑」的透明代理，它解析并重写一个**明确定义的子集**：

| 语句 | 支持要点 |
| --- | --- |
| `SELECT` | 列清单 / `*` / `DISTINCT` / 多表 / `[INNER\|LEFT\|RIGHT] JOIN ... ON` / `WHERE`（比较、`AND`/`OR`/`NOT`、`IN`、`LIKE`、括号）/ `ORDER BY` / `LIMIT` / `OFFSET` / `?` / `count(*)` / 受限派生表 |
| `INSERT` | 多行 `VALUES` / `SET` / `INSERT ... SELECT` / `RETURNING <列>`（仅 PostgreSQL 家族、单目标路由） |
| `UPDATE` | 单表或 JOIN 更新；**无分库列条件 → `ROUTE_FAILED`** |
| `DELETE` | 先查出受影响行的分库键，再逐库删除并累加 `rowCount`；无分库列条件 → 拒绝 |
| `SHOW` | `SHOW DATABASES` / `SHOW TABLES` |
| DDL | `CREATE TABLE` / `ALTER TABLE` 原样透传到逻辑库全部物理库（不解析） |
| 其它 | `EXPORT <key>=<value>` 改配置并落 `boot.sh`；`BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT` 透传到会话 pin 住的连接 |

**不支持**：除 `count(*)` 外的聚合、`count(<表达式>)`、其它函数调用、派生表以外的子查询、`UNION`、`GROUP BY`、`HAVING`、存储过程。统一报 `UNSUPPORTED_SQL`，错误信息带语句位置。

这个边界不是「暂时没做」，而是「做了就守不住」：一旦允许任意子查询和聚合，中间件就要实现一个 SQL 引擎，跨分片语义、排序、分页都会变成无底洞。**明确拒绝，比含糊支持更负责。**

几个具体行为值得记住：

- **`count(*)`**：`Single` 原语句下推；`Multi` / 广播 / `Unroutable` 逐库执行并求和；`Empty` 直接返回 `0`；全局表只读一份副本。事务 pin 下命中多库 → `ROUTE_FAILED`。
- **`INSERT ... RETURNING`**：仅 PostgreSQL 家族 + 单目标路由；返回列必须是整型，取首行首列作为 `lastInsertId`。
- **派生表分页**：外层只允许「唯一派生表 + 列清单 / 唯一 `count(*)` + 可选 `LIMIT`/`OFFSET`」；带分页且目标库多于一个 → `ROUTE_FAILED`（不做跨分片错页）。
- **全局表写入**：INSERT/UPDATE/DELETE 广播到全部物理库，读只取一份副本。
- **DDL 部分失败**：广播到多个库时若某个库失败，已执行的分支**不会自动回滚**，错误信息给出失败库。

---

## 九、部署与自检

```bash
cjpm build
cjpm install
export LD_LIBRARY_PATH="$HOME/.cjpm/libs/fdbm:$LD_LIBRARY_PATH"
fdbm                                   # 无子命令，启动即监听 fdbm_port（默认 8112）
```

部署目录：

```
fdbm 可执行文件
├── driver/    物理驱动动态库，恰好一个
├── custom/    自定义扩展库（不存在表示没有扩展）
├── boot.sh    配置与进程管理（EXPORT 会写回 managed 区块）
└── fdbm.sh    start / stop / restart
```

- `driver/` 里的驱动注册名必须等于所有节点的 `fdbm_db_driver_<node>`，否则 `NO_DRIVER`；
- 同机多实例时改 `fdbm_port` 与 `fdbm_cachePath`；
- 普通用户部署先确认 `fdbm_cachePath` 可写。

`EXPORT` 语句是一个挺实用的设计：SQL 里直接 `EXPORT fdbm_cache_expire=60s`，配置会写回 `boot.sh` 的 managed 区块——**改配置不用登机器编辑文件，重启也不会丢**。

---

## 十、上线清单

1. **`dbd_driverName` 必须是物理库方言名**（`postgres` / `mysql`），不是 `fdbm`。
2. **`fdbm_databasePoolMaxSize` 默认 1**：并发长游标、长事务多时必须调大，否则业务在等连接。
3. **`fdbm_checkDuration` 与长语句相关**：语句执行期间读不到心跳，执行时长超过约 3 倍该值会被判死链断开。
4. **`DELETE` / `UPDATE` 必须带分库键条件**，否则 `ROUTE_FAILED`——这是保护，不是缺陷。
5. **跨分片查询的 `ORDER BY` / `LIMIT` 是分片内语义**，不是全局语义；需要全局排序 / 全局分页时在应用层做（派生表 + 分页在多目标时直接 `ROUTE_FAILED`）。
6. **分库缓存超限只拒写新键**，不淘汰旧键；预期冷热分离明显时才开。
7. **DDL 广播不是原子的**，多库执行失败时不会回滚，变更前先备份。
8. **`sequence` 依赖 `fountain_sequence` 表**，启动自检会查，`boot.sh` 里别忘了建表。
9. **扩展名不能和内置重名**，否则启动直接失败——这是刻意的。
10. **`EXPORT` 会写回 `boot.sh` 的 managed 区块**，重启后仍然生效；改动前先确认该配置项的生效时机（启动期读取的配置不会因为一次 `EXPORT` 而重建已有资源）。

---

## 一句话收尾

`f_dbd` 把中间件实现为标准驱动，`fdbm` 把分片、读写分离、全局表、ID 生成收进一套路由与权重配置，`f_dbm` 把扩展点从可执行文件里拆出来。

**接入成本集中在 URL 与驱动名：业务代码保持 `std.database.sql` 接口，分片在 fdbm 侧完成。**

---

**同系列**

- [编解码器与应用通讯协议](fountain实现思想与应用第10弹——编解码器与应用通讯协议.md)
- [RPC实现](fountain实现思想与应用第11弹——RPC实现.md)
- [消息队列](fountain实现思想与应用第13弹——消息队列.md)
- [JSONRPC & MCP](fountain实现思想与应用第14弹——JSONRPC&MCP.md)
