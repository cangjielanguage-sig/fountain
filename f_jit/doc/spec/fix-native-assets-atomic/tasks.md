# 任务：fix-native-assets-atomic

- [x] T1.1 新增 `src/backend/NativeAssetsConcurrency_test.cj`：4 线程 × 100 次分配，`liveCount()` 必须精确 400。
- [x] T1.2 在**未改动**实现上跑：必须 **FAILED**（证明增量确实会丢）。
- [x] T2.1 `allocs` / `frees` 改 `AtomicInt64`；`onAlloc`/`onFree` 用 `fetchAdd`，`liveCount` 用 `load`，`resetCounters` 用 `store`。
- [x] T3.1 护栏转绿；`NativeAssets_test` 4 条仍绿。
- [x] T3.2 全量零失败。
- [x] T4.1 `verify.md`（改前红、改后绿）；T4.2 镜像；T4.3 归档 + 提交。
