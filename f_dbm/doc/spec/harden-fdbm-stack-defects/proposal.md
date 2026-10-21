# Change: 修复 fdbm 栈全量评审缺陷并补齐回归

## Why

`reviews/202610210649_fdbm_stack_review/todo.md`（基线 `7ca82fcc`）对 `fdbm` / `f_dbd` / `f_dbm`
做了六轮全量审查，记录 **16 严重 + 51 一般**。按根因去重后为 **12 个 P0 缺陷族 + 29 个 P1 缺陷族**
（其余 17 条一般项按归属并入 P0 族或落为 P2 测试工作流，逐条处置见 `design.md` §2）。

其中会造成**可见错误结果或数据丢失**的问题：

1. **流参数必然失败**：`set<InputStream>` 在编码阶段按 `Int64.Max` 申请临时数组（约 9 EiB），
   BLOB 参数路径 100% 抛分配失败，且异常未被包成 `DbdException`，破坏「对外只抛 `SqlException`」。
2. **流列静默截断**：`SqlTypes.readData` 对流列只读一块 64 KiB，`Unknown` 类型还误走流分支；
   `fdbm` 的 `count(*)` / `returning` / DELETE 取键都直接调用它。
3. **分库整体失效**：`logicalDatabases()` 把每个物理库名也注册成逻辑库，会话默认库落到物理库名，
   `('db_0','orders')` 查不到规则 `('order','orders')`，所有未限定读写静默落到 `db_0`。
4. **事务内重复执行**：`borrow()` 在 pin 时无条件返回同一连接，`Multi` 路由的 UPDATE/DELETE/DDL
   在同一物理库上执行 N 次并累加 `rowCount`，其余分片完全未修改。
5. **越界广播**：`Unroutable` SELECT 取部署内**全部**物理库，多逻辑库部署下读到别的逻辑库数据，
   `count(*)` 一并求和，DDL 改到别的逻辑库的表。
6. **非法 SQL 与静默精度丢失**：非标量参数按 `toString()` 拼进 SQL；大整数/高精度小数经 `Float64`
   中转后改写；派生表形状校验漏掉 JOIN 与 UPDATE/DELETE。
7. **扩展可覆盖内置**：自定义 `hash` 会静默替换内置实现，所有按该算法的写入改落到别的物理库。

其余为文档/配置口径、生命周期与并发安全、测试完整性缺口。本次一次性收口，避免「修严重项、留一般项」
在下一次评审重复出现。

## What Changes

### P0 正确性（12 个缺陷族，D01–D12）

| ID | 修复 | 代表证据 |
| --- | --- | --- |
| D01 | `InputStream` 参数按有界块物化；`readChunk` 不再按 `Int64.Max` 分配、退化为 O(n) | R1S1 / R2S1 |
| D02 | `readData` 对流列读至 EOF；`Unknown` 按 `String` 读并 WARN | R1S2 |
| D03 | 逻辑库与物理库命名空间隔离：不再注入物理名、未配置逻辑库隐式展开、会话默认库/ SHOW / `sequenceDatabase` 统一按逻辑库口径 | R3S1 / R5S3 / R5G1 / R5G2 / R3G |
| D04 | 事务 pin 只允许单目标；SELECT/UPDATE/DELETE/DDL 的多目标在 pin 下拒绝 | R5S1 / R5S4 |
| D05 | `Unroutable` 广播与 DDL 限定在该语句所属逻辑库的物理库集合内 | R5S2 |
| D06 | 参数→SQL 字面量改为类型白名单，非标量参数在绑定阶段报 `CONVERSION` | R4S1 |
| D07 | 数值字面量按原文交给 `Decimal`，不再经 `Float64` | R4S2 |
| D08 | 派生表形状校验覆盖 JOIN、UPDATE、DELETE | R4S3 |
| D09 | 自定义扩展名与内置名冲突在启动自检拒绝；工厂优先级语义与文档一致 | R2S4 / R5G10 / R6S1 |
| D10 | UUID v1/v6 真正写入时间戳与序列；不再每次生成临时目录/文件 | R3S2 |
| D11 | `IdGeneratorException` → `ID_GENERATOR`；按生成器**实际能力**选择 `nextIntId`/`nextStringId` | R2S2 |
| D12 | `DbdUrl` 统一按 UTF-8 字节下标；`%XX` 按字节解码；`database` 同样解码；非 ASCII 往返成立 | R2S3 / R1G1 |

### P1 文档 / 配置 / 生命周期（29 项，G01–G29）

- **配置与文档口径**：非法超时不清空既有值（G01）；根包补齐重导出与版本入口（G02）；驱动注册名统一为
  `dbd_driverName` 且包初始化不再 `exit(1)`（G03）；`sessionSweepInterval` 正数校验（G29）。
- **资源与生命周期**：启动失败释放已建资源（G14）；监听失败不再以退出码 0 结束（G12）；优雅停止记录
  `closeAndAwait` 结果（G13）；`show tables` 失败归还语句与连接（G23）；`begin/commit` 失败清理 pin（G26）。
- **并发安全**：`BootScriptWriter` 加锁 + 唯一临时文件（G11）；会话 `cursor`/`pinned` 加锁与关闭标志（G16）；
  `PartitionCache.closed_` 原子化、关闭后报 `CACHE`（G15）；`QueryCursor.next()` 异常后复位行状态（G28）。
- **协议语义补强**：`getOrNull<InputStream>` 对 NULL 返回 `None`（G04，`bufSize = -1` 探测，向后兼容）；
  流列标量读报 `CONVERSION`（G05）；`MultiDatasource` 用状态而非消息文本判定池已关闭（G06）；
  连接池异常映射 `TIMEOUT`（G07）。
- **SQL 语义**：WHERE 子查询统一 `UNSUPPORTED_SQL`（G17）；引用符按 AST 各部分保留（G18）；
  标识符 ASCII 大小写不敏感（G19）；别名限定的分库键可抽取（G20）；MySQL 字符串转义反斜杠（G21）；
  下推去掉逻辑库限定符（G22）；同分库维度比较物理库集合（G27）。
- **启动自检**：`fdbm_global__<table>` 逻辑库引用校验（G08）；`sequence` 检查 `fountain_sequence` 表存在（G09）；
  启动整理「区块内优先」并记 WARN（G10）；多行 INSERT 按目标库分组、组内同一事务（G24）。

### P2 测试完整性（12 个工作流，T01–T12）

`f_dbm` 首次补齐单测；清理空测试/无断言测试；补齐类型矩阵、并发、优雅停止、列类型归一、
自定义扩展真 e2e、启动自检负例全表、连接归还断言、`f_dbd` 公开行为缺口、URL 往返矩阵、
流列/流参数矩阵，并把 e2e 改为「逻辑库名 ≠ 物理库名」的部署。

## Impact

- **代码**：`f_dbd/src/{common,driver,multid}`、`fdbm/src/{config,sql,route,execute,idmaker,server,resources}`、
  `f_dbm/src`（仅文档/测试，不改接口）。逐文件清单见 `design.md` §3。
- **文档**：`fdbm/doc/详细设计.md`（§3.1 / §3.5 / §5 / §6.2 / §7 / §8.1 / §8.2 / §9 / §10 / §11）、
  `f_dbd/doc/详细设计.md`（§3.9 / §3.10 / §5.1 / §5.2 / §5.5 / §6.4）、三个模块 README 与
  `fdbm/doc/开发计划.md`、`f_dbd/doc/开发计划.md`。
- **测试**：`f_dbd`、`fdbm` 既有 `*_test.cj` 增补；新增 `f_dbm/src/*_test.cj`；
  `fdbm/test/e2e/backends/*.sh` 与 client 增加逻辑库/限定名/扩展用例。
- **协议**：消息形状、命令枚举、错误码数值均不变；仅新增保留值 `bufSize = -1` 的语义
  （NULL 探测），旧客户端不发送、旧服务端按既有 `<= 0` 处理，双向兼容（见 `design.md` §5）。
- **不改动**：`f_orm/**`；`f_dbm` 的 `PartitionAlgorithm` / `IdGenerator` 接口签名；错误码枚举。
- **兼容性**：驱动注册名以 `dbd_driverName` 为准，`fdbm` 仅作为兼容别名保留；`DbdDriver()` 无配置时
  由 `exit(1)` 改为抛 `DbdException(CONFIG)`（进程不再被杀）。完整清单见 `design.md` §5。

## Out of Scope

- 不做跨物理库两阶段提交：多行 INSERT 跨库、全局表写与会话事务的组合只保证「同库事务」，
  全局表写在事务内仍走独立连接（本次改为显式文档化 + WARN + 用例固定，见 G25）。
- 不新增 SQL 能力（不引入任意子查询、聚合、跨片排序/分页下推）。
- 不改 `f_orm` 的分页/方言实现，不改 `f_dbm` 接口形状。
- 不做连接池指标 API（`f_dbpool` 无活跃/空闲计数）；归还断言改用 `maxSize=1` 强约束表达。
- 不重构 SQL 词法/解析器结构，只补形状校验与错误码。
