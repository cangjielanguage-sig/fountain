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
- [ ] P1.2d（P1 后续）`freeSlots` 切片私有（全局只回收整段/切片池），消除 pop/push 的全局争用
- [x] P1.3 窗口栈改线程私有（重入仍正确）
- [x] P1.4 `IterTable` 改调用私有：红用例——两线程各自 `for (k in map)` 互不干扰，且 `next/key/value` 不再走全局锁
- [ ] P1.5（P1 后续）`JitContext.malloc/freeCount` 原子化（或每线程计数）；断言并发下计数准确

## P2 去全局环境

- [ ] P2.1 `deadline` / `fnTableBase` / `user-helper 栈` 改 `ThreadLocal`；删 `envMtx`
- [ ] P2.2 红用例：A 线程带 deadline 调用的同时 B 线程长调用不被误中断（当前会串味）

## P3 去调用锁

- [ ] P3.1 删 `callMtx`；`lastEscaped` 改为调用返回；`callForFn` 取本次调用自己的组
- [ ] P3.2 红用例：同一单元 4 线程 × N 次并发调用，结果/错误码/site 与串行逐位一致，句柄无泄漏

## P4 跨线程包装

- [ ] P4.1 红用例：A 线程 `callForFn` 创建包装，B/C 线程调用；`unloadFn` 在 D 线程释放
- [ ] P4.2 `PromotionGroup` 引用计数原子化；提升/释放并发安全

## P5 生命周期

- [ ] P5.1 `state/active` 原子化；`unload` 等待**所有线程**排空
- [ ] P5.2 红用例：并行调用中 `unload` → 在飞调用完成、新调用 19、超时回退可用

## P6 验收

- [ ] P6.1 全量零失败；单线程路径逐位不变
- [ ] P6.2 基准：1/2/4/8 线程吞吐；目标 8 线程 ≥ 5×（写入 verify）
- [ ] P6.3 句柄/内存无泄漏（`liveCount`、`mallocCount`）
- [ ] P6.4 文档（README 并发章节、design-m1/m3 的窗口描述）与归档
