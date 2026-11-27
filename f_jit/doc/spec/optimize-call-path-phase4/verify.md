# 验证：Phase 4（JitBindSupport 快照化 + totalSlots 原子化）

## 结论

两项都保留：

| 项 | 目标指标 | 基线 → 改动后 | 判定 |
| --- | --- | --- | --- |
| A. `JitBindSupport` 快照化 | `acceptsInterface` 4 线程扩展比 | 0.40× → **2.13×**（731 → 113 ns/op） | **keep** |
| B. `totalSlots` 原子化 | 窗口开合绝对成本 | 1 线程 1374 → **632 ns/op**（−54%）；4 线程 602 → 315 ns/op（−48%） | **keep** |

全量 **1206 / 1206 通过 / 0 失败 / 0 error**。

## A. `JitBindSupport` 快照化

### 改动

`enrolled` 与 `interfaceAccepts` 两张 `HashMap` 合成不可变 `BindSnapshot`：
写（`enrollOf` / `enrollInterfaceOf`）在 `writeMtx` 内复制两张表、填好后
`AtomicReference.store` 发布；读（`acceptsInterface` / `isInterface` / `enrolledOf`）只 `load()` 后查表。

### 护栏（`JitBindSupportSnapshot_test`，3 条）

| 用例 | 作用 | 旧实现 | 新实现 |
| --- | --- | --- | --- |
| `enrolledInterfaceIsVisibleToReaders` | 登记可见性 / 未知名返回 false | PASSED | PASSED |
| `concurrentEnrollAndReadStayConsistent` | 4 写 + 4 读 × 2000 次，结果恒真 | PASSED | PASSED |
| `publishedSnapshotIsAlwaysComplete` | **发布时序**：写者在钩子里停住时读者必须已能看到本次登记 | PASSED | PASSED |

**变异验证**：把 `enrollInterfaceOf` 改成「先 `store` 空表、后填充」，第三条用例
`FAILED: publishedSnapshotIsAlwaysComplete`（`left=false / right=true`）；恢复后全绿。
> 第一版护栏用「已登记过的类名」，变异被旧快照里的同名项掩盖（变异仍绿）；
> 改用从未登记过的 `SnapshotFreshHost` 后才真正复现。这一步本身说明「用例必须先证明能红」。

`publishHook` 是 package-internal 测试钩子（默认 `None`），只在包初始化 / `registerClass`
的冷路径多一次 Option 匹配。

### 数据（临时探针，已删除）

| | 1 线程 | 4 线程每 op | 扩展比 |
| --- | --- | --- | --- |
| 改动前 | 293 ns | 731 ns | 0.40× |
| 改动后 | 241 ns | 113 ns | **2.13×** |

（本机 4 线程实际上限 2.2–2.4×。）

## B. `totalSlots` 原子化

### 改动

`totalSlots` → `AtomicInt64`；`openWindow` 的 `base` 改为 `load()`（删掉每次调用一次的
`synchronized(mtx)`）；`growSlot` 仍在 `mtx` 内保证段发布、写用 `store`；
`pinConst` / `liveCount` 扫描上界各缓存一次 `load`；`slotCount` / `resetWindow` 栈空分支同步。

### 护栏

`HandleTableStripeConcurrency_test` 新增 `slotCountReadsAreMonotonicUnderChurn`：
4 线程 churn 的同时主线程读 5000 次 `slotCount()`，断言单调不减、结束后 `liveCount==0`。
旧实现与新实现均通过（行为等价）。

### 数据（临时探针，已删除）

| | 1 线程 | 4 线程每 op | 扩展比 |
| --- | --- | --- | --- |
| 改动前 | 1374 ns | 602 ns | 2.28× |
| 改动后 | **632 ns** | **315 ns** | 2.00× |

绝对成本双减半。扩展比从 2.28× 降到 2.00× 的原因：去掉全局锁后单线程基线大幅变快，
剩余成本主要是 `Win` 的 GC 分配（扩展性更差），不是新增争用。

## 回归

| 范围 | 结果 |
| --- | --- |
| `JitBind_test` / `JitMemberAccess_test` / `Interface_test` / `Inheritance_test` / `JitBindIgnore_test` | 4+4+4+2+5 全绿 |
| `HandleTable_test` / `HandleTableM2_test` / `HandleTableGenExhaustion_test` | 18+7+2 全绿 |
| `HandleTableStripeConcurrency_test` / `WindowIsolation_test` / `T40Account_test` / `AnyHostCast_test` | 2+3+3+4 全绿 |
| 全量 `cjpm test --parallel 1` | **1206 / 1206 / 0 失败** |

## 风险与后续

- `publishHook` 是常驻测试脚手架；若要清除，可改为仅在测试进程设置（当前实现只多一次 Option 匹配）。
- 快照复制成本随注册项数线性增长，但注册是冷路径（一次几十~几百项），远低于一次编译。
- 剩余可选项只有 `PromotionGroup` 的每 id 原子计数（不在普通 `call` 上）与专用机 profile。
