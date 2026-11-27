# 验证：编译路径并发优化（M0 / C0 / C1 / C2；C3 取消）

## 结论

| 项 | 结果 | 判定 |
| --- | --- | --- |
| M0 mmap/mprotect 占比 | 2.4%（1T）/ 5.9%（4T） | **C3 取消**（门槛 15%） |
| C0 发射审计表共享（新发现） | 并发编译 `IndexOutOfBoundsException` | **修复**（ThreadLocal） |
| C1 `awaitReady` 退避 | 其它 key 的 claim+finish 187 071 → **3 003 ns**（−98.4%） | **keep** |
| C2 `snapshot` 缓存 | F=200 共享 Compiler，4 线程每编译 813 → **584 µs**（−28%），扩展比 1.53× → 1.84× | **keep** |

全量 **1210 条**：一次运行 1209 通过 + `PerfOverride_test` 高负载假失败（单跑通过）。

## M0：mmap 占比（先只测不改）

临时给 `CodeBuffer.alloc` / `seal` 加计数与计时（**已删除**）：

| | mmap（次/耗时） | mprotect（次/耗时） | 单编译占比 |
| --- | --- | --- | --- |
| 1 线程 × 12 编译 | 12 / 97 188 ns | 12 / 97 657 ns | **2.4%**（16.2 µs / 687 µs） |
| 4 线程 × 48 编译 | 48 / 751 568 ns | 48 / 789 689 ns | **5.9%**（32.1 µs / 547 µs） |

每编译恰好 1 次 mmap + 1 次 mprotect（4 KiB）。**C3（池化）不做**。

## C0：并发编译缺陷（C2 测量时撞出）

- 现象：4 线程共享 `Compiler` 并发编译时抛
  `IndexOutOfBoundsException: index 25, size 24`，栈在 `A64Emitter.noteMemBase` 的 `ArrayList.add`。
- 根因：`A64Emitter.auditMemBases` 是**进程级** `ArrayList`；并发 `add` 越界，
  `resetAuditMemBases` 还会清掉别的编译的审计项（审计静默失效）。
- 修复：改 `ThreadLocal<ArrayList<Int64>>`（审计生命周期 = 一次 `compileOnce`）。
- 测试：
  - `A64AuditIsolation_test`（确定性 Red）：另一线程写一条后，本线程快照必须为空 —— 旧实现必红（实测 FAILED）；
  - `CompileConcurrency_test`（压力）：4 线程共享 Compiler 各编 10 段，结果逐位正确。

## C1：`awaitReady` 指数退避

| | 其它 key 的 `claim+finish` |
| --- | --- |
| 自旋 500 万次 + 每轮取锁 | 187 071 ns/次 |
| 墙钟退避（1 µs → 500 µs，预算 30 s） | **3 003 ns/次（−98.4%）** |

`CompileCache_test`（含 T17 同键管线只跑一次）/ `CompilePipeline_test` / `RunUnit_test` 全绿。

## C2：`Compiler.snapshot()` 缓存

测量（临时统计，已删除）：

| 场景 | snapshot 占单编译 |
| --- | --- |
| 空注册表 | 0.69% |
| F=200，1 线程 | **11.6%**（144 µs / 1 247 µs） |
| F=200，4 线程共享 | **41.5%**（13.5 ms / 32.5 ms，全在 `this.mtx` 内串行） |

缓存后（同一探针）：

| 场景 | 改前 | 改后 | Δ |
| --- | --- | --- | --- |
| F=200，1 线程每编译 | 1 247 µs | 1 076 µs | −13.7% |
| F=200，4 线程每编译 | 813 µs | **584 µs** | **−28.2%** |
| 扩展比（4T vs 1T） | 1.53× | **1.84×** | +20% |

失效语义用例 2 条：注册后立即生效、注销后立即失效（`CompilerSnapshotCache_test` 2/2）。

## 回归

- 单类：`A64Emitter_test` 13/13、`CompilerRegistration_test` 7/7、`CompileConcurrency_test` 1/1、
  `A64AuditIsolation_test` 1/1、`CompilerSnapshotCache_test` 2/2、`CompileCache_test` 4/4；
- 全量：**1210 条**，1209 通过；唯一失败为既有 `PerfOverride_test` 高负载假失败
  （`ref=3773ns ov=4914ns`），单跑通过。

## 未解决 / 风险

- 并发编译 4 线程扩展比约 1.8×（本机上限 2.2–2.4×）；剩余差距不在 mmap、不在本变更的锁，
  需要专用机 + profile 才能定位（构建机无 `perf`、无 `strace`）。
- `snapCache` 为 `Compiler` 实例字段；同一实例「注册 + 编译」并发时，编译可能用旧快照 ——
  与「注册不影响已编译产物」的既有语义一致，且注册会立即失效供后续编译使用。
