# 待改进的模块
./f_io

# 已完成

## testAllocSlotWaitsAfterFullThenRecycles 长时间不结束✅
**根因**: `IoUringLockFree.waitAndReap()` 中先调用 `reap()`（`reaper.reapAll`），一次收割所有可用的 CQE。当 4 个 NOP 在 submit 后全部完成，第一次 `waitAndReap()` 就处理了全部 4 个 CQE，后续 3 次调用陷入无限阻塞（`ring.waitCQE()` 等待永远不会到达的 CQE）。

**修复**: `waitAndReap()` 中的非阻塞收割从 `reapAll` 改为 `reapN(1)`，每次只收割一个 CQE。保证可被多次调用逐次收割。

## testPoolConcurrentAccess # 错误✅
**根因**: `IoUringPool.getRing()` 用 round-robin 分配 ring。快速线程会消费多个轮询索引，抢走慢速线程的 ring 索引，导致两个线程**共享同一非线程安全的 IoUring 实例**调用 `getSQE()`/`submit()`，SQ ring 状态损坏。

**修复**: 测试改为显式分配 ring：线程 0 用 `pool.getRing(0)`，线程 1 用 `pool.getRing(1)`，避免并发竞争。
