# 任务

> 两项均为行为等价重构：先写 characterization + 并发护栏（旧实现上必须绿），
> 再实现，再用微基准判定 keep/revert；每项独立提交、可单独回滚。

- [x] A1 **护栏用例先行**：`JitBindSupportSnapshot_test`（根包）
  - 登记某接口后 `isInterface` 为真、`acceptsInterface` 对该类实例为真、对未知名为假；
  - 4 写线程重复登记同一接口 + 4 读线程并发查询 × 2000 次：不崩、结果恒真；
  - 旧实现上先跑 3 轮，确认全绿（这是 characterization，不是 Red）。

- [x] A2 **实现**：`BindSnapshot` + `writeMtx` + `AtomicReference`；
  `enrollOf`/`enrollInterfaceOf` 走写时复制；`acceptsInterface`/`isInterface`/`enrolledOf` 改无锁读。

- [x] A3 **Green + 变异验证**：A1 全绿；把发布改成「先清空再填」的变异必须让并发护栏变红，验证后恢复。

- [x] A4 **微基准与判定**：`acceptsInterface` 1 vs 4 线程（基线 293 ns / 731 ns，0.40×）；
  目标 4 线程 ≥2×，未达则回滚 A。记录数据后**单独提交** A。

- [x] B1 **护栏用例**：`HandleTableStripeConcurrency_test` 增一条
  「churn 期间并发读 `slotCount()`，返回值单调不减且最终等于高水位」；旧实现上绿。

- [x] B2 **实现**：`totalSlots` → `AtomicInt64`；`growSlot`/`openWindow`/`resetWindow`/
  `liveCount`/`slotCount`/`resetForTest` 改用 `load()`/`store()`。

- [x] B3 **Green + 微基准**：窗口开合 1 vs 4 线程（基线 1374 ns / 602 ns，2.28×），
  不得低于 2.0×；`HandleTable_test` / `HandleTableM2_test` / `WindowIsolation_test` /
  `HandleTableGenExhaustion_test` 全绿；**单独提交** B。

- [x] C1 **全量回归**：`cjpm test --parallel 1` 零失败（1203+ 用例）。

- [x] C2 **verify + 文档 + 归档**：写 `verify.md`；`doc/optimize-call-path.md` 增 §13；
  `openspec validate --strict` 通过；镜像落盘 `f_jit/doc/spec/optimize-call-path-phase4/`；归档。

## 不做

- 不改 `PromotionGroup` / `HostFieldTable.writeMtx` / `CompileCache` / `Compiler` / `ClassRegistry`；
- 不改公开 API、错误码、注册顺序。
