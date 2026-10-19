# 设计：f_dbd 驱动与 fdbm 服务端实现

> **本文不复制现有详细设计**。`f_dbd/doc/详细设计.md` 与 `fdbm/doc/详细设计.md` 已给出包结构、每个顶级声明的公共成员与调用关系；两份 `开发计划.md` 已给出逐成员的红→绿步骤。本文只记录四类内容：① 权威口径与文档对齐项；② 详细设计未决或需跨模块接线才能定的决策；③ 开发阻塞项；④ 实施顺序与门禁。实现与用例一律以详细设计 + 开发计划为准。

## Context

- **权威口径**：`f_dbd/doc/详细设计.md`（2026-10-17 拍板：无预读、关闭走 `UNSUBSCRIBE`/`ACK` + 当前行缓冲、`qid` 显式标识、连接级结果集独占、客户端不缓存）。
- **待对齐的过时描述**（实现前必须改完，否则用例会按旧协议写）：
  - `fdbm/doc/详细设计.md` §9.1 `QueryCursor.hasData`（"构造即预取第一行"）、§9.1 游标规则 1（首次 `next()` 不发请求）、§9.2 `ExecutionOutcome.hasData`、§10.2 请求处理表里的 `CLOSE_CURSOR → DataNone`、§13 不变量 2（`CLOSE_CURSOR` 幂等）、§12 取舍表"缓存容量"相邻行里关于预取的措辞。
  - `fdbm/doc/开发计划.md` Step 7.1（`hasData` 构造即预取、跨段预取、`next()` 序列 `true,true,false`）、Step 8.1（首行预取契约、`CLOSE_CURSOR` 幂等）、Step 0–6 中与上面同源的表述。
  - `f_dbd/doc/开发计划.md` Step 1.3（`init(columnInfos, hasData)`、`hasData` props）、Step 1.4（`CLOSE_CURSOR(-2)`、`closeCursor()` 工厂）、Step 1.9（`hasData=false → false 且桩计数 0`、"同列二次访问不再发请求"的行缓存）、Step 3.5/3.7（请求序列含 `CLOSE_CURSOR(-2)`）。
- **新口径一句话**：查询首包只有列信息；客户端**每次** `next()`（含第一次）都发 `NEXT_ROW`；服务端每次 `NEXT_ROW` 执行一次物理 `next()` 并**重建/清空当前行缓冲**；列读从当前行缓冲应答；关闭走 `UNSUBSCRIBE(qid)` → `ACK`。

## Goals / Non-Goals

**Goals**

1. 四份文档口径一致，且与将要写出的代码一致。
2. `f_protocol` 提供带载荷的 `UNSUBSCRIBE` 构造器。
3. `f_dbd` 完整实现 `std.database.sql`，可作为 `DriverManager` 的 `fdbm` / `multidbd` 驱动被 `f_orm` 直接使用。
4. `fdbm` 作为可执行文件提供分库路由、读写分离、全局表广播、ID 生成、分库缓存与优雅停止。
5. 全过程 TDD，`get<T>` 分派在性能实验出结论后才实现。

**Non-Goals**

- 不改 `f_dbd` 协议本体；不实现同连接多游标；不做方言转换与聚合/子查询支持。
- 不实现跨版本兼容、不做灰度或回滚工具。
- 不优化"列读 1+n 次往返"（先正确性，测量数据出来后再按 `f_dbd` §10.2 风险表决定是否整行预取）。

## Decisions

### D1 以 f_dbd 协议为准，fdbm 侧文档回改

fdbm 是服务端，但它与 f_dbd 是一对一端点，协议事实来源只有一处。选 `f_dbd/doc/详细设计.md` 为准（它是最新拍板、且定义了客户端可见行为）。回改范围见 Context 的清单；回改与实现同提交（`AGENTS.md`：实现与文档偏差时同提交改文档）。

### D2 `f_protocol` 新增 `unsubscribe<T>(data!: T)`

```cangjie
public static func unsubscribe<T>(data!: T): Message where T <: ToData {
    build<T>(UNSUBSCRIBE, data)
}
```

- 与既有 `subscribe<T>(data!: T)` 完全同构：复用 `private static func build<T>(command, data: ?T)`，`MessageID` 由 `Message(command, data)` 构造器自动生成。
- 既有 `unsubscribe(id)` / `unsubscribe(id, data!)` 一个字不改（f_rpc 等既有调用方无感）。
- 只加构造器 + 单测，不动编解码、不动 `Command` 位定义。

### D3 服务端"当前行缓冲"的口径：惰性填充 + 生命周期随行

**决策**：`QueryCursor` 持有"当前行的单元格缓冲"，**首次**请求某列时才从物理 `QueryResult` 读一次并缓存；`NEXT_ROW` 推进与 `UNSUBSCRIBE` 关闭时整表清空；流列缓存的是 **`InputStream` 句柄**（不是数据），句柄同样随行失效。

**理由**

- 客户端不缓存，同一单元格重复 `get` 会重复请求（`f_dbd` §3.10），服务端必须能低成本应答重复请求。
- 流列**绝不能重复打开**（`f_dbd` §3.9 `readStream` 明确"同一行同一列只调用一次"；对真流式驱动重复 `get<InputStream>` 等于重复取列值），句柄必须跨多次块请求存活 —— 这与"句柄随行失效"是同一张表的两个侧面。
- 不采用"`NEXT_ROW` 时整行预读"：宽表无谓开销，且流列无法整行物化（大对象可能远超内存预算）。

**代价**：宽结果集上"只读少数列"也只付少数列的代价，但客户端逐列读的总往返数不变（1+n），见 Non-Goals。

### D4 `qid` 的产生与匹配

- f_dbd：查询 RESP 的 `Message.id.toString()` 即 `qid`（RESP 回带请求 id），由 `DbdStatement.query()` 捕获并交给 `QueryResultImpl`（`f_dbd` §5.5、§3.6.1）。
- fdbm：在创建 `QueryCursor` 时把该次查询 CONSUME 的 `Message.id.toString()` 记为游标的 `qid`。
- `UNSUBSCRIBE` 到达时：`qid` 不匹配 / 无游标 / 已关闭 → **直接回 `ACK`（幂等，不得关掉别的游标）**；匹配才执行"清空缓冲 → 读尽物理结果集 → `close()` → 归还连接 → 回 `ACK`"，且**无论中途是否抛异常都要回 `ACK`**（`f_dbd` §7.3 第 1–5 步）。

### D5 `get<T>` 的类型分派：性能前置实验是硬门禁

- 在 `f_dbd` 阶段 1 的 Step 1.9 之前完成实验（实验口径、用例矩阵、判定规则见 `f_dbd/doc/详细设计.md` §10.1，本文不复制）。
- **门禁**：实验未出结论，不写 `QueryResultImpl.get<T>` / `getOrNull<T>` 的分派代码；其余成员（构造、`next()`、流、关闭握手）不受阻塞，可先行。
- 结论回写 `f_dbd/doc/详细设计.md` §3.10（实现口径）与 §10.1（结果表 + 日期），与代码同提交。
- 语义一致性优先于速度：候选 B 若对"`T` 为接口实现类/别名"与候选 A 行为不同，必须补子类型兜底，**不得仅凭速度选 B**。

### D6 实施顺序（门禁式推进）

```
T1 文档对齐（四份文档）
 └─ T2 f_protocol: unsubscribe(data!)
     └─ T3 f_dbd 阶段0 骨架 → T4 阶段1 common（含 T4.5 性能实验门禁 + Step 1.9）
         └─ T5 阶段2 exception → T6 阶段3 driver → T7 阶段4 multid
             └─ T8 fdbm 阶段0（含 executable 可测性前置验证）→ T9..T16 阶段1..8
                 └─ T17 集成 / 端到端 / 收尾
```

先 f_dbd.common 后 fdbm：fdbm 依赖 `fountain::f_dbd.common` 的 payload 与 `SqlTypes`，且 f_dbd 的桩发送器单测不需要 fdbm 存在。

### D7 测试替身口径（沿用两份开发计划的既有约定，不新增机制）

- `f_dbd`：协议/驱动层用**进程内 `f_net.Server<DataAny>` 桩**（端口先 `TcpServerSocket(bindAt: 0)` 探空闲端口）；`QueryResultImpl`/`DbdInputStream` 用**桩发送器 + 桩 closer**，不起网络。
- `fdbm`：`FakeNodeAccessor`（记录下推 SQL/参数/池名/广播次数）+ `f_mockdb`；协议与会话用例**必须走回环连接**（`f_net.SocketBuffer` 无公开构造）。
- `f_mockdb` 边界：进程级单一驱动、无多库隔离、无真事务、借用时执行 `checkSql`（夹具必须让任何 SQL 都返回至少一行）。

### D8 分支与提交

`feature/dbware` worktree 上开发；每 Step 一个提交，提交前统一 LF；每个提交前 `cjpm test` 全绿（遵循 `AGENTS.md`：有单元测试后再提交）。**不新建、不删除、不合并分支，不操作其他 worktree**——仓库里还有 `f_jit`、`mq` 等并行工作线。

### D9 common/exception 循环依赖：`DbdException` 实现体移入 common（2026-10-17 用户拍板）

`QueryResultImpl` / `DbdInputStream` 在 common 并抛 `DbdException`，而 `DbdException` 需要 common 的 `DbdErrorCode` / `DbdErrorPayload`，形成包级循环（cjpm 实测直接报 `cyclic dependency`）。采用方案 1：`DbdException` 类声明与实现放 `common`（`src/common/DbdException.cj`），`exception` 包只 `public import fountain::f_dbd.common.DbdException` 重导出。对外 `import fountain::f_dbd.exception.*` 不变；`common` 不 import `exception`，§2 的依赖方向保持原样。§4 的“声明位置”说明与开发计划阶段 2 同步调整。

## Risks / Trade-offs

| 风险 | 应对 |
| --- | --- |
| fdbm 是 executable 模块，仓内尚无 `cjpm test` 先例 | 阶段 0 Step 0.1 第一件事就是实跑验证；不支持则把全部逻辑放进同模块动态子模块、`fdbm` 只留薄 `main`，偏差同提交登记进详细设计 |
| 列读 1+n 次往返导致慢查询 | 阶段 3 用计时用例量化每行 RTT；优化留待测量后决定（Non-Goals） |
| 客户端漏做"连接级结果集独占"守卫时静默串数据 | 客户端守卫是**必须实现**项（`f_dbd` §5.4/§5.5/§5.8 + 不变量 6）；服务端"新语句先关旧游标"只作防御。加固（列读带 qid）留作后续版本 |
| `PackageInfo.load` 加载物理驱动的静态初始化时机 | fdbm 阶段 8 Step 8.3 首条用例即验证"加载后 `DriverManager.drivers()` 可见"，不成立则改显式注册入口 |
| 长游标占满池（`maxSize` 默认 1） | 单测覆盖"池耗尽 → `TIMEOUT`"；文档提示按并发调大 `maxSize` |
| 优雅停止仅在 POSIX 生效（`ExitCallbacks` 在 Windows 为空实现） | 停止用例只跑 Linux/macOS；Windows 用 `fboot shutdown <pid>` 或跳过 |
| 性能实验结论与预期相反 | 按 §10.1 判定规则执行（差距 < 5% 视为持平、按可维护性选），结论回写文档，不反向改代码 |

## Migration Plan

无。两个模块为全新增，`f_protocol` 为纯新增重载；没有已上线实现与持久化协议状态需要迁移。缓存目录（`fdbm_cachePath`）与 `boot.sh` 的 managed 区块在首次启动时创建/整理。

## Open Questions

1. `fdbm` 的 executable 模块能否 `cjpm test`（T8 Step 0.1 的前置验证给出答案，决定是否需要拆动态子模块）。
2. `get<T>` 分派实验 A/B 谁胜出（T4.5 给出答案；本文不预设）。
3. 客户端 `UNSUBSCRIBE` 未达（超时/断链）时，服务端只能靠 `fdbm_sessionSweepInterval` 巡检兜底回收游标 —— 当前设计接受这一窗口；若集成测试显示窗口内连接耗尽，再评估是否引入游标空闲超时。
4. `fdbm_checkDuration` 默认 30s 与广播 DDL / 大结果集首包的相互作用，需在集成阶段实测后决定是否调整默认值的文档建议。
5. `f_dbd` / `f_dbm` / `fdbm` 是否登记进 `.modules` 的 `[include]` 发布清单？本期不默认修改（避免替用户决定发布节奏），仅补齐三个模块的中英 README；发布登记待用户确认。
