# Tasks

## P0 存储层选型 spike

- [x] P0.1 验证 `std.sync.AtomicInt64`（已探针确认可用）与分块存储可行性；测「预分配 vs 分块」的内存与吞吐
- [x] P0.2 定「有活跃窗口时不搬迁」的机制：分配器在切片分配前预扩容，或分块目录定长
- [x] P0.3 结论写入 design D3

## P1 窗口切片

- [x] P1.1 红用例：两线程同时跑分配型单元（`any_box`/容器），断言各自句柄数正确、不互相清窗（当前必然串行/错乱）
- [x] P1.2 分配器 + 切片化 `openWindow/resetWindow`；`ctx.hwBase/hwTop` 成为真值
- [x] P1.2b **读路径去锁**：`getAny/getAs/isType/tagOfHandle/fetch*` 去掉全局锁，改为「所有权 + 发布后不可变」；`alive/gen` 原子发布
- [x] P1.2c `pin` 去重收窄：窗口内线程本地 map + 常量全局锁，删除全表线性扫描
- [x] P1.2d `freeSlots` 争用评估：P6 基准 4 线程 2.40×，分配锁未成瓶颈 ⇒ 保持全局短锁（切片池留作后续优化，见 design D3d）
- [x] P1.3 窗口栈改线程私有（重入仍正确）
- [x] P1.4 `IterTable` 改调用私有：红用例——两线程各自 `for (k in map)` 互不干扰，且 `next/key/value` 不再走全局锁
- [x] P1.5 `NativeMem.malloc/freeCount` 改 `AtomicInt64`（只读 prop 保持读法）；`ParallelCall_test` 断言并发后 `outstanding()` 回基线

## P2 去全局环境

- [x] P2.1 `deadline` / `fnTableBase` / `user-helper 栈` 改 `ThreadLocal`；删 `envMtx`
- [x] P2.2 红用例：A 线程带 deadline 调用的同时 B 线程长调用不被误中断（当前会串味；环境层 TLS 用例已覆盖，端到端长调用证据并入 P3.2/P6.2）

## P3 去调用锁

- [x] P3.1 删 `callMtx`；`lastEscaped` 改为调用返回；`callForFn` 取本次调用自己的组
- [x] P3.2 红用例：同一单元 4 线程 × N 次并发调用，结果/错误码/site 与串行逐位一致，句柄无泄漏

## P4 跨线程包装

- [x] P4.1 红用例：A 线程 `callForFn` 创建包装，B/C 线程调用；`unloadFn` 在 D 线程释放
- [x] P4.2 `PromotionGroup` 引用计数原子化；提升/释放并发安全

## P5 生命周期

- [x] P5.1 `state/active` 并发安全（当前由单元 `mtx` 保证；原子化留待 P6 视瓶颈）；`unload` 等待**所有线程**排空
- [x] P5.2 红用例：并行调用中 `unload` → 在飞调用完成、新调用 19、超时回退可用

## P6 验收

- [x] P6.1 全量 **1188/1188 / 0 失败**（含基准用例）；单线程路径行为不变（既有用例全绿）
- [x] P6.2 基准：2/4/8 = 1.27×/2.40×/1.91×（共享 7 核 VM、负载 3+，8 线程超订；目标 5× 需专用 8 核，已写入 verify）
- [x] P6.3 句柄/内存无泄漏：并发调用后 `liveCount` 与 `NativeMem.outstanding()` 均回基线（`ParallelCall_test` + 基准用例）
- [x] P6.4 文档：README/README_en 已加并发 Q8、design 状态已更新；已归档
