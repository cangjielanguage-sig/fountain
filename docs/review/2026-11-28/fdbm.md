# fdbm 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `fdbm_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`fdbm`（75 个文件：60 个 .cj + 15 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：连接/事务的获取与归还、跨库写的事务语义、`insert … select` 的物化边界、错误路径的资源回收
- **报告版本**：v1（由主 Agent 直接审查；`execute/executors.cj` 的借还、事务组、逐条执行、`insert…select` 逐段读，其余为机械检索）

## 发现

### [严重][存量] `insert … select` 把整个结果集物化到堆，没有任何行数/字节上限

- **位置**：`fdbm/src/execute/executors.cj:830-849`（`let rows = ArrayList<Array<SqlExpression>>()` → `while (cursor.next()) { … rows.add(...) }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（全量物化 → OOM）
- **证据**：静态确定 —— 物化循环没有计数、没有上限、没有分页；注释说明了**为什么**必须物化（游标持有物理连接，`maxSize` 默认 1 时再借会自锁），但没有给出任何容量保护
- **描述**：`insert into t (...) select ... from 大表` 会把源表的每一行都变成 `Array<SqlExpression>` 放进 `ArrayList`。100 万行 × 20 列时，仅表达式对象就是数百万个堆对象，加上 `LiteralExpression(cursor.cell(...))` 把每个单元格值复制一份 —— 这是典型的「一条 SQL 打爆进程」，而且发生在 `fdbm` 未设任何 `maxRows` 的默认配置下
- **建议**：加 `insertSelectMaxRows`（默认按行数，如 10 万）与累计字节估算，超限抛 `UNSUPPORTED_SQL`/`LIMIT_EXCEEDED`；或分批「读 N 行 → 关闭游标 → 写 → 再开游标」

### [一般][存量] `executeOneByOne` 部分写入无法回滚，异常里也不带已完成条数

- **位置**：`fdbm/src/execute/executors.cj:796-806`
- **来源**：存量
- **判据**：review-checklist §11（错误信息与状态一致性）、§3（失败不可观测）
- **证据**：静态确定 —— `for (statement in statements) { let result = executeSingle(session, statement); rowCount += … }` 没有 try/catch；对照同文件 `executeAll`（`:751-786`）在失败时会显式拼出 `committed: [db1, db2]`
- **描述**：10 条 INSERT 走到第 3 条失败时，前 2 条已经各自提交（`executeSingle` 独立借还连接），异常只带第 3 条的错误；调用方既不知道该重试还是该补偿，也拿不到「已写 2 条」这个关键事实。同一个模块里两条路径（`executeAll` / `executeOneByOne`）的失败契约不一致
- **建议**：捕获后包装成带 `writtenCount` / `writtenIds` 的 `FdbmException`；或统一走 `executeAll` 的事务组

### [轻微][存量] `BootScriptWriter` 的一处空 catch

- **位置**：`fdbm/src/config/BootScriptWriter.cj:475`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）
- **证据**：静态确定 —— `catch (_: Exception) {}`
- **描述**：启动脚本生成过程中的清理失败没有痕迹；该文件其余 `synchronized`（`:96/104/147`）覆盖得当
- **建议**：补 `debug` 日志

## 优化可行性方案

### [堆内存] `insert … select` 改成分批物化

- **现状**：一次性物化全部结果行（`executors.cj:830-849`），峰值内存与源表行数线性相关
- **方案**：按批（如 1000 行）读 → 关游标 → 写 → 重开游标并跳过已读行（或按主键区间推进）
- **预期**：峰值从 O(全表) 降到 O(批大小)；需实测确认「重开游标 + 跳过」的总耗时增量
- **代价**：需要稳定的排序键才能安全推进；无主键表只能退回全量物化（此时应配上限）
- **验证**：`cjpm bench -O2` 对 10 万 / 100 万行两档，比较峰值 `getUsedHeapSize()` 与总耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 生产里 `insert … select` 的典型行数 | `executors.cj:838` | 行数分布 | 在物化循环里按 1k/10k/100k 分桶计数，跑一周 |
| 2 | 逐条 INSERT 与事务组的吞吐差 | `executors.cj:796-806` vs `:751-786` | 批量 100 条的中位耗时 | `cjpm bench -O2` 两档对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1–15 | `fdbm/README.md`、`README_en.md`、`doc/**`（13 个） | .md | 未读 | 设计文档里大量 `W-`/`G`/`§9.x` 编号被代码引用，本轮未逐篇核对 |
| 16 | `fdbm/src/execute/executors.cj` | .cj | ✅（核心段） | 见发现 1/2；借还（`:36-99`）、事务组（`:745-794`）、逐条（`:796-806`）、`insert…select`（`:814-858`）逐段读 |
| 17 | `fdbm/src/execute/cursor.cj` | .cj | 部分 | 抽查三段 `close` 的失败处理（`:48-60`、`:147`、`:206`），均为「失败降级为日志」 |
| 18 | 其余 43 个 .cj（`sql/SqlParser.cj`、`config/FdbmConfig.cj`、`config/BootScriptWriter.cj`…） | .cj | 未读 | 仅按 `synchronized` / `catch (_` / `.close()` 机械检索 |
| 19–20 | `Dispatcher_test.cj` 等 14 个测试 | .cj | 未读 | — |

合计：`.cj` 2 个逐段读完 / 58 个未读；`.md` 15 个未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 发现 2 |
| §1 死代码 | 0 | 未做（未读文件过多，不宣称） |
| §2 重复逻辑 | 1 | `executeAll` 与 `executeOneByOne` 的失败契约不一致（并入发现 2）；两者本身职责不同，不算同构 |
| §3 空实现 | 2 | 发现 2/3 |
| §4 栈溢出 | 0 | 已读范围内无递归 |
| §5 OOM | 1 | 发现 1 |
| §6.1 热点瓶颈 | 0 | 无 profile |
| §6.2 大粒度锁 | 0 | 已读段无显式锁（连接由 `NodeAccessor` 池化，池内同步在 f_pool/f_dbd） |
| §6.3 并发串行 | 0 | 未展开 |
| §6.4 低效算法 | 0 | 未展开 |
| §7 降堆内存方案 | 1 | 分批物化 |
| §8 降 CPU 方案 | 0 | 需 bench |
| §9 local mode 可行性 | 0 | 物化结果是返回值，必须逃逸 |
| §11 现有代码的 BUG（存量） | 2 | 发现 1/2 |
| §12 并发安全与锁粒度 | 0 | 已读段：`borrow` 的 pin 校验（`W-1`）保证事务不跨片，逻辑正确 |
| §14 功能完备性与 README 覆盖 | 0 | README 未读 |
| 文件覆盖（§13 等） | 3/75 | 见上表 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 1 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

已读的核心执行路径质量高：借还（`borrow`）把「事务 pin 的连接只对 begin 时的物理库有效」这条硬约束写成显式拒绝，跨库写入用「按库分组 + 显式 begin/commit/rollback + 失败时报告已提交库」处理，`closeAfterExecution` 明确区分「执行成功后关连接失败要抛」与「执行已失败时关连接失败只记 warn」——这些细节说明作者认真对付过线上故障。两个问题都在「边界规模」上：`insert … select` 的全量物化没有上限（可能一条 SQL 打爆进程），以及逐条执行路径的失败契约不如事务组完整。**覆盖有限**：60 个 .cj 只精读 2 个（`executors.cj` 的 execute 段约占该文件一半），SQL 解析与配置层未展开。存量 3 条（严重 1 / 一般 1），是否纳入修复待用户决定。
