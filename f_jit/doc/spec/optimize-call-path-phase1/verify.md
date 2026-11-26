# Verify

## 范围与结论

| 项 | 结果 |
| --- | --- |
| T0 基准与基线 | `CallPathBench_test`（B1–B4）+ `ParallelThroughput_test` 的 `jitBacked` 观测；5 次基线写入 `doc/optimize-call-path.md` §3.1 |
| P1.1 HostFault TLS | **keep**：Q4 195595 → 444715 calls/s（+127.4%），C1 615 → 280ns（−54.5%） |
| P1.2 HostField 快照 | **keep**：F1 848 → 507ns（−40.2%），F4 1710 → 219ns（−87.2%） |
| P1.3 生命周期原子化 | **revert**：Q4 +1.2%、L1 −0.1%、S4 −9.9%，无指标达 MOV；代码/测试/钩子已删除 |
| 实施中新发现 | `HandleTable` gen 编码在 32768 次复用后产生负 ID（code 99），已记录 `optimize-call-path.md` §10，独立修复 |

> 判定全部按 `doc/optimize-call-path.md` §1：5 次中位数、`MOV = max(3%, 2d)`、其它指标回退 ≤2%、
> 全量零失败。P1.3 的拒绝是数据结论，不是实现失败。

## TDD / 验证证据

| 项 | 证据 |
| --- | --- |
| P1.1 Red | `HostFaultTls_test.causeIsInvisibleAcrossThreads` 在旧全局表上失败（B 线程读到 Some）；实现后 3/3 绿 |
| P1.2 | 纯性能重构，设计声明的 TDD 例外：4 条 characterization 用例（注册序、并发读/注册、accepts 重入、复位空快照）实现前后均绿；keep 只由 F1/F4 数据决定 |
| P1.3 | 用 `enterPauseHook` 固定「读 state 后、active+1 前」窗口；变异（去掉复读 state）后 `lateEnterAfterStateReadIsRejected` 变红（left=1 / right=19），证明用例有效；随后因无收益整体回滚 |

## 回归

| 项 | 结果 |
| --- | --- |
| 全量（回滚 P1.3 后） | **1199 / 1199 通过 / 0 失败 / 0 error** |
| 并发集 | `ParallelCall_test`、`UnloadConcurrency_test`、`PromotionGroupConcurrency_test`、`WindowIsolation_test` 各 3 轮全绿 |
| 用户面冒烟 | `FacadeRegistry_test` 5/5、`Q6Acceptance_test` 33/33 |

## 规格增量

| Capability | 变更 |
| --- | --- |
| `f-jit-runtime` | MODIFIED `H64 / H65 字段读写`（不可变快照、查找无锁无分配、注册序不变） |
| `f-jit-runtime` | MODIFIED `宿主异常专用码与异常栈`（cause 线程私有、free 即清、跨线程读为空） |

P1.3 相关的 `f-jit-facade-bridge` 增量已从变更中移除（未实施，不写入主规格）。

## 提交

| 提交 | 内容 |
| --- | --- |
| `5f754e18c` | T0 基准工具与基线 |
| `ad2756644` | P1.1 HostFault TLS（keep，带数据） |
| `15f5e1dc1` | P1.2 HostField 快照（keep，带数据） |
| （无） | P1.3 已回滚，不留提交 |

## 未做 / 后续

- `JitContext` 池化（需先改 `NativeMem` 计数口径，独立 OpenSpec）；
- `HandleTable` 分片空闲表 + 原子 `totalSlots`（Phase 2，A4 需先修 gen）；
- `SignatureTable` / `AdapterRegistry` COW（Phase 3，按 profile）；
- 专用 8 核复测 8 线程 ≥5×（仍为跨变更遗留项）。
