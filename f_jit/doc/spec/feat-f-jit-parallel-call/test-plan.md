# 测试计划

基线：`9357e98f`（f_jit 全量 1145/1145/0）。

| 用例 | 断言 | 阶段 |
| --- | --- | --- |
| `concurrentWindowsDoNotInterfere` | 2 线程各 200 次分配型调用，各自句柄计数正确、结果正确 | P1 |
| `iterTablePerCallIsolation` | 两线程各自遍历 Map（各 1000 项），结果正确、游标互不可见、无全局锁争用 | P1 |
| `deadlineIsThreadLocal` | A 带 10ms deadline、B 长调用（100ms），B 不被中断；A 按时中断 | P2 |
| `sameUnitParallelCalls` | 4 线程 × 500 次同单元调用，结果/错误码/site 与串行一致；`liveCount` 回到基线 | P3 |
| `wrapperCrossThread` | A 创建包装 → B/C 调用 → D `unloadFn`；计数归零、无 UAF | P4 |
| `unloadDuringParallelCalls` | 并行调用中 `unload(timeout)`：在飞完成、新调用 19、超时返回 false 恢复可用 | P5 |
| `parallelThroughput`（基准） | 1/2/4/8 线程吞吐；8 线程 ≥ 5× 单线程 | P6 |

门槛：全量零失败；单线程路径与 `9357e98f` 逐位一致；无句柄/内存泄漏。
