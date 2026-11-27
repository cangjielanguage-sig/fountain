# 任务：fix-handle-config-race

- [x] T1.1 `initialCapacity` / `capacityLimit` 改 `AtomicInt64` + `public static mut prop`（赋值语法不变）。
- [x] T1.2 所有内部读点确认走 getter（`winStackOf` / `openWindowWith` / 分配路径）。
- [x] T1.3 新增 `HandleTableConfigRace_test`：1 线程在两值间切换配置，3 线程并发开窗，容量恒为合法值。
- [x] T2.1 `HandleTable_test` / `WindowIsolation_test` / `HandleTableStripeConcurrency_test` / 新用例全绿。
- [x] T2.2 全量零失败。
- [x] T3.1 `verify.md`（明确「无可测差异」）；T3.2 镜像；T3.3 归档 + 提交。
