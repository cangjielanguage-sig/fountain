# fprobe 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `fprobe_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（167 个文件：142 个 .cj + 25 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：外部命令执行的超时与进程回收、采集器的错误契约、告警引擎的异常吞噬、无界增长
- **报告版本**：v1（由主 Agent 直接审查；`collect/hw/CommandRunner.cj` 逐段读，告警与采集为定向检索 + 抽查）

## 发现

### [一般][存量] `CommandRunner.run` 有两套错误契约：参数校验抛异常，执行失败返回 `CommandResult`

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:61-88`（`validate(command)` 在 `try` 之前，`run` 声明的返回类型是 `CommandResult`）、`:91-105`（`validate` 抛 `ProbeException`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约一致性）
- **证据**：静态确定 —— `run` 内部对 `launch` 失败、超时都返回 `CommandResult(...failed=true...)`，唯独 `validate` 直接抛 `ProbeException(COLLECT)`
- **描述**：同一个函数，一条路径返回结果、一条路径抛异常。采集器若只判 `result.failed` 就会漏掉异常分支（异常冒到 supervisor，整个探针被记一次 error，而不是「这个命令参数非法」这一条采集失败）；若用 try 包裹又得处理两种失败形态
- **建议**：`validate` 的失败也折成 `CommandResult(-1, "", "", true, "invalid command: …")`，或统一改成抛异常，二选一

### [一般][存量] 超时后 `terminate(force: true)` 的结果被丢弃，进程可能残留

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:77-84`
- **来源**：存量
- **判据**：review-checklist §11（资源回收）、§3（静默失败）
- **证据**：静态确定 —— `try { process.terminate(force: true) } catch (_: Exception) { () }`，紧接着返回超时结果；`spawn { process.waitOutput() }` 的 future 没有 join 也没有取消
- **描述**：`SIGKILL` 之后子进程可能短暂残留在进程表（等待 `waitOutput` 的线程回收），若 `terminate` 本身失败（权限、进程已消失但句柄无效）则完全无痕。采集器按分钟级周期跑 `smartctl` / `ipmitool` 时，偶发残留会累积成「僵尸/半死进程」堆积
- **建议**：`terminate` 失败记 `warn`；超时分支显式 `pending.get(...)` 一个短超时或提供 `kill + wait` 收尾

### [一般][存量] 告警引擎多处 `catch (_: Exception)` 静默，告警丢失时无可观测痕迹

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:208`、`:279-282`（`catch (_: Exception)` 与 `catch (_: Error)`）、`fprobe/src/alarm/AlarmRule.cj:111`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）、§11
- **证据**：静态确定 —— 空 catch；`AlarmEngine.cj:281` 连 `Error` 都吞
- **描述**：告警是「最后一道通知」，它自己失败时最需要留痕。现在渠道发送/规则求值抛异常会被彻底吞掉，运维只会看到「没有告警」，无法区分「一切正常」与「告警链路坏了」
- **建议**：至少 `warn` 一条带规则名/渠道名的日志，并累加「告警失败计数」指标

### [轻微][存量] `String.fromUtf8(stdout)` 在非 UTF-8 输出上会抛错，被外层误报成「无法执行命令」

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:76`（在 `:70-87` 的 try 内）
- **来源**：存量
- **判据**：review-checklist §11（错误归因）
- **证据**：静态确定 —— 解码在 `try` 内，外层 `catch (e: Exception)` 统一返回「无法执行命令 ${program}」
- **描述**：`smartctl` 在某些 locale 下输出非 UTF-8 字节，解码失败会被报成「命令无法执行」，实际命令已成功执行，误导排查方向
- **建议**：解码单独 try，失败时用 `String.fromUtf8` 的宽松替代（或保留原始字节 + 标注编码失败）

## 优化可行性方案

无（本轮未取得可支撑优化的测量数据）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 采集周期内子进程残留数量 | `CommandRunner.cj:74-84` | 残留进程数与存活时长 | 压测「命令必超时」场景 1 小时，`ps` 采样统计 |
| 2 | `AlarmEngine` 吞掉的异常频率 | `AlarmEngine.cj:208/279` | 每秒失败次数 | 临时把空 catch 改成计数，跑一周 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1–25 | `fprobe/README.md`、`README_en.md`、`doc/**`（23 个） | .md | 未读 | 未逐篇核对 |
| 26 | `fprobe/src/collect/hw/CommandRunner.cj` | .cj | ✅ | 见发现 1/2/4 |
| 27 | `fprobe/src/alarm/AlarmEngine.cj` | .cj | 部分 | 抽查空 catch（`:208/279/281`） |
| 28 | `fprobe/src/alarm/AlarmRule.cj` | .cj | 部分 | 抽查空 catch（`:111`） |
| 29 | 其余 139 个 .cj（`runtime/SupervisorRuntime.cj`、`tui/RenderPlan.cj`、`collect/**`、`report/**`、`config/**`…） | .cj | 未读 | 仅按 `while(true)` / `ArrayList<` / `catch (_` / `spawn` 机械检索 |

合计：`.cj` 1 个逐段读完 + 2 个抽查 / 139 个未读；`.md` 25 个未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 发现 1（错误契约） |
| §1 死代码 | 0 | 未做 |
| §2 重复逻辑 | 0 | 未做 |
| §3 空实现 | 2 | 发现 2/3 |
| §4 栈溢出 | 0 | 未发现递归（已读文件） |
| §5 OOM | 0 | 检索未见无界累积（未读文件不宣称） |
| §6.1 热点瓶颈 | 0 | 无 profile |
| §6.2 大粒度锁 | 0 | 未展开 |
| §6.3 并发串行 | 0 | 采集器是否串行执行未核对 |
| §6.4 低效算法 | 0 | 未展开 |
| §7 降堆内存方案 | 0 | 无证据 |
| §8 降 CPU 方案 | 0 | 无证据 |
| §9 local mode 可行性 | 0 | 采集结果需跨线程持有 |
| §11 现有代码的 BUG（存量） | 4 | 发现 1/2/3/4 |
| §12 并发安全与锁粒度 | 0 | 已读段只有 `spawn` + future，未发现共享状态 |
| §14 功能完备性与 README 覆盖 | 0 | README 未读 |
| 文件覆盖（§13 等） | 3/142 | 见上表 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

已读的命令执行层结构正确（参数数组直传不走 shell、校验拒绝空白与空参、超时后强杀），并发上只用一个 `spawn` + `get(timeout)`，没有共享可变状态。问题集中在**失败的可观测性**：同一函数两套错误契约、强制终止的失败被吞、告警链路自己失败时静默。对一个「监控系统」来说，这三种失败都直接损害它最核心的价值（可信的告警）。**覆盖严重不足**：142 个 .cj 只读了 1 个、抽查 2 个，采集器与 supervisor 主循环未展开，本报告不能代表整个 fprobe。存量 4 条（一般 3 / 轻微 1），是否纳入修复待用户决定。
