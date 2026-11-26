# Tasks

> 每一项都必须走完「基线 → 实现 → 复测 → keep/revert」四步，缺任一步不算完成。
> 判定阈值来自 `f_jit/doc/optimize-call-path.md` §4；数据一律写回该文档 §6/§7 表。
> 编号对应：本文件 **P2 / P3 / P4** 分别对应 `optimize-call-path.md` 的 **P1.1 / P1.2 / P1.3**（P1 是测量工具）。
> 环境：按仓库既有 cjpm 运行环境准备（STDX 路径、uring 链接）；全量命令以 `unset CJPM_CONFIG` 起头。
> 本机 `cjpm --filter` 只接受以 `*` 结尾的通配形式，故命令写作 `--filter 'Xxx_test*'`。

## P0 前置（只读，不改产品代码）

- [x] P0.1 核实三个 API 的真实形态（本地 std 文档 / 最小探针，**不猜**）：
  `std.sync.AtomicReference` 是否存在且可发布引用；`AtomicInt64` 的 CAS 方法名与语义；
  `ThreadLocal` 的写法与 `RuntimeEnv.cj:35-44` 一致。任一不成立 ⇒ 停下来回报，不自行发明替代方案
- [x] P0.2 记录基线环境：`uname -a`、物理核数、`load average`、是否有调频信息、本次基线 commit
  （写入文档 §3 的环境行与 §7 第一行）

## P1 测量工具与基线（T0，不参与 keep/revert）

- [x] P1.1 新增 `src/CallPathBench_test.cj`：非门槛 `@Test` 类，4 个 `@TestCase`
  （B1 短调用 `{ n: Int64 => n + 1 }`、B2 H64 字段读循环、B3 分配型单元、B4 `JitContext.create + free`），
  只打印 `CP-BENCH scene=… metric=… value=… unit=…`，**无时序断言**
- [x] P1.2 `ParallelThroughput_test` 增加 `PAR-BENCH jitBacked=…` 打印（恒打印；断言按 design「isJitBacked 的处理」决定是否固化）
- [x] P1.3 **基线采集**：`cjpm test --filter 'CallPathBench_test*' --parallel 1 --show-all-output` 与
  `cjpm test --filter 'ParallelThroughput_test*' --parallel 1 --show-all-output` 各跑 5 次，
  记录 `Q1/Q4/L1/F1/F4/A4/C1/S2/S4/S8` 的 5 个原始值与中位数，计算 `d` 与 `MOV = max(3%, 2d)`，写入文档 §6
- [x] P1.4 **工具门槛**：Phase 1 使用的 Q1/Q4/L1/F1/F4/C1/S4 均已 `d < 10%`（见文档 §3.1）；
  A4 仍不稳定，**按 §10 的 gen 阻断暂不作为 Phase 1 指标**，Phase 2 修复后重测
- [ ] P1.5 提交 T0（只含测试文件，无产品代码改动）

## P2 P1.1 HostFault 线程本地化

- [x] P2.1 **基线**：在 T0 的 commit 上重采 `Q1/Q4/L1`（辅助 `C1`）各 5 次，中位数记入文档 §6 的 P1.1 行
- [x] P2.2 **失败用例先行（Red）**：
  - **必须先红**：A 线程 `record` 后，B 线程以同一 ctx `causeOf` ⇒ 期望 `None`（旧全局表会返回 Some）；
  - 两线程并发各触发一次宿主异常，各自 `causeOf` 只看到自己的 cause，且互不覆盖（3 轮）；
  - 记录后 `JitContext.free` ⇒ 同线程再查 `None`；
  - 确认第一条因断言失败（非编译错误）变红后，才进入 P2.3
- [x] P2.3 **实现**：`HostFault` 改 `ThreadLocal<HashMap<UInt64, FaultEntry>>`（`FaultEntry{text, ex}` 合并两张表）；
  `record/causeOf/exceptionOf/takeCause/clear` 全走本地表；`clear` 在无表时 no-op，`causeOf` 在无表时不创建表
- [x] P2.4 **回归**：`HostCallTrampoline_test`、`HostFieldGet_test`、`HostFieldSet_test`、`Q6Acceptance_test` 全绿；
  P2.2 新增用例 3 轮全绿
- [x] P2.5 **复测**：`Q1/Q4/L1/C1` 各 5 次，算中位数与 Δ%，同时抄 `F1/F4` 用于判断「其它指标回退 ≤2%」
- [x] P2.6 **判定**：`Q4` 提升 ≥ MOV **或** `L1` 下降 ≥ MOV，且其它指标回退 ≤2%，且全量零失败 ⇒ **keep**（独立提交，提交信息带数据）；
  否则 **revert** 并写 §7「无效 + 数据」。无指标变化时**不得**以「代码更干净」为由保留

## P3 P1.2 HostFieldTable 不可变快照

- [x] P3.1 **基线**：重采 `F1/F4`（辅助 `Q1/Q4`）各 5 次，写入文档 §6 的 P1.2 行
- [x] P3.2 **护栏用例先行（characterization）**：本项是纯性能重构，**没有行为 Red**（设计「TDD 与验证策略」已声明例外）：
  - 同 index 注册 A、B 两个类，按注册序各自命中一次（顺序语义锁定）；
  - 一线程反复 `find`、另一线程并发 `register` 新 index ⇒ 不崩、不空表、不死锁（3 轮）；
  - 访问器的 `accepts` 内部再 `register` ⇒ 不死锁、本次查找仍按已取快照完成；
  - `resetForTest()` 后 `find` 返回 `None`；
  - 这些用例在实现前也应通过；**keep/revert 只由 P3.5 的 `F1/F4` 数据决定**
- [x] P3.3 **实现**：`FieldSnapshot{ buckets: HashMap<UInt16, Array<HostFieldAccessor>> }`；
  注册在 `writeMtx` 内 COW 并发布；`find` 只 `load()` + 取数组 + 逐条 `accepts`，删除锁内拷贝与临时 `ArrayList`；
  `resetForTest` 发布空快照
- [x] P3.4 **回归**：`HostFieldGet_test`、`HostFieldSet_test`、`HostFieldAccessor` 相关注册期用例全绿；P3.2 用例 3 轮全绿
- [x] P3.5 **复测**：`F1/F4` 各 5 次（门槛 **≥10%**，高于 MOV），同时抄 `Q1/Q4` 与 `C1`
- [x] P3.6 **判定**：`F1` 或 `F4` 提升 ≥ 10%，且其它回退 ≤2%，且全量零失败 ⇒ **keep**；
  `F1/F4` < 10% 或字段/注册用例失败 ⇒ **revert**

## P4 P1.3 JitFunction / EscapedClosure state/active 原子化

- [ ] P4.1 **基线**：重采 `L1/Q1/Q4/S4` 各 5 次，写入文档 §6 的 P1.3 行；同时记录 `S4` 是否来自机器码路径（P1.2 的 `jitBacked` 结论）
- [ ] P4.2 **确定性竞态用例先行（Red）**：
  - 在 `enter` 的 `state.load()` 与 `active+1` 之间加 package-internal 测试钩子 `enterPauseHook`（默认 `None`，生产零成本）；
  - 用例：钩子内阻塞 → 另一线程 `close` 到终态 → 放行 → 该调用必须 19，且单元/闭包 `active` 均归零（旧实现无复读，此处会带入已释放单元 ⇒ 必红）；
  - 并发 `close` 4 线程 ⇒ 全部成功、`release` 回调只发生一次、终态后调用 19；
  - 包装实例在闭包已释放时调用 ⇒ 19 且两处 `active` 不残留
- [ ] P4.3 **实现**：
  - `state/active` 改 `AtomicInt64`（单元与 `EscapedClosure` 各一组）；
  - `enter`：「读 state → `active+1` → 复读 state」，变化则 `active−1` 抛 19；
  - `exit`：`active−1`；
  - `close`：CAS 0→1 决出胜者，轮询 `active==0`，胜者 `store 2` 并做冷路径收尾；超时 CAS 1→0 返回 false；败者只等终态；
  - 包装实例对单元与本闭包各做一次双检，失败按相反顺序撤销；
  - `escaped` / `escapedSeq` / `lastEscaped` / `cacheKey` / `release` **仍留在 `mtx`**（冷路径）
- [ ] P4.4 **变异验证**（硬要求）：临时去掉 `enter` 的「复读 state」后，P4.2 的**钩子阻塞晚到用例**必须变红；
  不变红说明用例没覆盖到，先补用例再继续。验证完恢复实现
- [ ] P4.5 **并发回归**：`ParallelCall_test`、`UnloadConcurrency_test`、`PromotionGroupConcurrency_test`、
  `WindowIsolation_test` 各 3 轮全绿
- [ ] P4.6 **复测**：`L1/Q1/Q4/S4` 各 5 次
- [ ] P4.7 **判定**：`Q4` 或 `S4` 提升 ≥ MOV，且 `UnloadConcurrency_test` 3 轮全绿，且其它回退 ≤2%，且全量零失败 ⇒ **keep**；
  任何指标未达 MOV ⇒ **revert**；出现 close 与晚到 enter 的竞态 ⇒ **revert** 并记录

## P5 收口

- [ ] P5.1 **全量**：`unset CJPM_CONFIG && cjpm test --parallel 1 --no-color --no-progress` 零失败
  （条数不再写死：基线 1188，T0 后 +4，各护栏用例再递增；判定标准是 0 失败）
- [ ] P5.2 **用户面门禁**：`f-jit-facade-bridge` 的「用户面再导出与冒烟」用例全绿，确认无 API 面扩散
- [ ] P5.3 **决策日志回填**：文档 §6 表逐行填「基线中位数 / 改动后中位数 / Δ% / 其它回退 / 全量 / 结论」，
  §7 填日期、项、指标、基线→改后、决策、提交号
- [ ] P5.4 **停止条件**：若连续 **2 项**未达 MOV ⇒ 停止继续堆优化，改用 `perf`/火焰图定位真实热点（文档 §8）
- [ ] P5.5 **文档状态**：`f_jit/doc/optimize-call-path.md` 的状态行按实际结果更新（已实施/部分实施 + 保留与回滚清单）
- [ ] P5.6 **提交拆分**：T0 / P1.1 / P1.2 / P1.3 各自独立提交，每个提交可单独 `git revert`；
  被 revert 的项在 §7 留痕，不在代码里留「注释掉的旧实现」

## 不做（本变更边界）

- [ ] 不做 `JitContext` 池化（依赖 P1.1，且需先改 `NativeMem` 计数口径 → 独立 OpenSpec）
- [ ] 不做 `HandleTable` 分片空闲表 / 原子 `totalSlots`
- [ ] 不做 `SignatureTable` / `AdapterRegistry` 的 COW
- [ ] 不改公开 API、错误码、计数口径、窗口与提升语义、编译管线与缓存锁
