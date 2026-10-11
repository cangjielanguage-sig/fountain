# 代码审查报告：f_base（`FutureTask` 及关联 API）

- 审查日期：2026-10-11
- 审查基线：`sts/1.3.x`，HEAD `fe8a1886`（工作区干净）；被审文件 `f_base/src/FutureTask.cj` sha256 `f67a776c740a62a91019eb0bbe8df3f5b8baffe15e2911f34ade3aa5ac93e38e`
- 审查范围：`f_base/src/FutureTask.cj`（190 行）全部公开/内部类型 —— `AbstractFutureTask`、`FutureTask<T>`、`AbstractInheritedTaskLocal`、`InheritedTaskLocal<T>`、`FutureTaskException`，以及与它们直接相关的 API（`Thread.currentThread.id`/`hasPendingCancellation`、`Future.cancel`、`ConcurrentHashMap`、`HashSet`）
- 环境：Cangjie Compiler `1.3.0-alpha.20261007001050 (cjnative)`，target `x86_64-unknown-linux-gnu`，WSL Ubuntu-24.04（`CJPM_CONFIG=/mnt/d/docs/work/cangjie/repository`）
- 审查依据：`cangjie-code-review`（性能优化 / 内存优化两套清单）＋ `cangjie-doc-lookup`（std 与语言文档原文核对）＋ 15 组探针实测
- 复核口径：**§1/§2 每条都有本机实测数字**（§5 给出实验编号与命令）；§3 为低危/契约/文档口径项；§4 记录**已实测排除**的怀疑，避免重复上报
- 本次审查**只读**：未改动 `f_base` 任何代码；探针工程在 `.autocode/tmp/ftask_probe/`（gitignore 区），`f_base` 用逐字节副本构建（构建时 sha256 与仓库一致）
- 该能力在本仓**无调用方**，只被 `f_base/README.md:612-656` 与 `docs/speech/speech.md:3750-3751` 文档化 —— 属面向应用项目的能力，下列结论按"应用侧使用者"的影响评估

## 0. 摘要

| 严重度 | 条数 | 编号 |
|---|---|---|
| 高 | 2 | `FT-1`、`FT-2` |
| 中 | 4 | `FT-3` ~ `FT-6` |
| 低 / 登记 | 4 | `FT-L1` ~ `FT-L4` |
| 已排除（不作问题） | 1 | `FT-X1` |
| 合计 | 11 | — |

**建议修复顺序**：

1. `FT-1`（§1.1）`InheritedTaskLocal` 在 owner 线程启动前写入的值 99.6% 读不到（hashCode 取可变的 `tid`）——静默丢值，且是"构造任务后预置上下文"这条最自然的用法　**✅已修复（2026-10-11，见 §1.1 修复标记）**
2. `FT-2`（§1.2）`shutdownSubOnFinish` 承诺不成立（父任务先结束时 96% 子任务不被取消）＋ `subTasks` 无互斥（`HashSet` 共享无共同锁）　**✅已修复（2026-10-11，见 §1.2 修复标记）**
3. `FT-3`（§2.1）`shutdownCurrentSubThreads`/`current()` 按 `FutureTask<T>` 过滤，异类型子任务被静默跳过（100% 复现）　**✅已修复（2026-10-11，见 §2.1 修复标记；`current()` 那半见 §2.1 补充修复）**
4. `FT-4`（§2.2）`InheritedTaskLocal` 的写入目标固定为 owner（四个出口，含"owner 已结束时 `set` 后自读 `None`"）—— **已拍板：路线 2（`set`/`remove` 写当前任务）；`getOrSet`/`getOrCompute` 二次决策改为二段检查锁**　**✅已修复（2026-10-11，见 §2.2 修复标记与二次修正）**
5. `FT-5`（§2.3）父任务先结束后子任务继承不到值（返回 None）——**作者定性为缺陷**，继承改走构造期固定的父链　**✅已修复（2026-10-11，见 §2.3 修复标记）**
6. `FT-6`（§2.4）性能：**全部候选已实施（2026-10-11，⑥+①③④⑤ 四笔提交）** —— 端到端 `FutureTask<Int64>{1}` + `get()` **33.9 ~ 36.2 µs → 21.0 µs**（同批裸 `spawn{1}`+`get()` ~2.9 µs ⇒ 比值 **13× → ~7.2×**）、命中 `InheritedTaskLocal.get()` **700 ~ 870 ns → ~300 ns**；量化数据与逐项标记见 §2.4　**✅已修复**
7. `FT-L1` ~ `FT-L4`（§3）低危/契约/文档项　**登记**

**修复时间线（2026-10-11，分支 `fix/futuretask`，worktree `.worktrees/futuretask`，基线 `fe8a1886`）**：

| 提交 | 内容 |
|---|---|
| `0fcdbd23` | `fix(f_base): FT-1 任务身份改用构造期固定 id，hashCode/== 不再取可变 tid` |
| `07bed369` | `fix(f_base): FT-2 子任务登记前移到创建线程并纳入共享锁，shutdown 不再漏取消` |
| `471ed6dc` | `perf(f_base): FT-2 细化：登记不包住 spawn，消除构造路径上的锁竞争`（性能复测驱动） |
| `59055200` | `fix(f_base): FT-3 取消能力上移到 AbstractFutureTask，异类型子任务不再被跳过` |
| `0fa1852b` | `docs(f_base): FT-4 详述（四个出口 + EXP17）与路线决策：采用路线 2` |
| `c89cb7cf` | `fix(f_base): FT-4 set/remove 写当前任务（路线 2），getOrSet/getOrCompute 保持 owner 共享槽` |
| `83b55f87` | `fix(f_base): FT-4 二次决策：getOrSet/getOrCompute 改用二段检查锁（只算一次）` |
| `77488c97` | `docs(f_base): 回填 FT-4 的三个提交号与 19/19 总验证` |
| `b7226c17` | `fix(f_base): FT-3 遗留收口：current() 类型无关化，异常可捕获` |
| `a776708d` | `docs(f_base): FT-L1 前半（异常可见性）标记为随 b7226c17 已修` |
| `e905ca9c` | `fix(f_base): FT-5 继承改走构造期固定的父链，父任务先结束不再切断继承` |
| `8f7d2ff5` | `docs(f_base): FT-6 分项量化（EXP18：端到端 10.5x、可归因项与可省上限 1.5~2x）` |
| `d90e338e` | `perf(f_base): FT-6 ⑥+① local 改 Mutex+HashMap 并首次写入才建表（-7.4us/任务，命中读 700->507ns）` |
| `0287d2b8` | `perf(f_base): FT-6 ③ 叶子任务短路 teardown 清理（hasChildren，-1.6us/任务）` |
| `118dc494` | `perf(f_base): FT-6 ④ 读路径缓存当前任务并移除 taskMap（-3.1us/任务，读 505->298ns）` |
| `569aa503` | `perf(f_base): FT-6 ⑤ 压缩登记注销（创建者整体清桶 + 完成态剪枝，-0.9us/任务）` |
| `40d64573` | `style(f_base): 子任务集合与剪枝遍历改用 for-in（元素类型已是 AbstractFutureTask）` |

**修后总验证（FT-1~FT-5 阶段）**：worktree 内 `cjpm test` = `TOTAL: 26, PASSED: 26, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`；修前基线为 6 条既有用例全绿，本次累计新增 20 条用例）。探针（`.autocode/tmp/ftask_probe`，按 worktree 的 `f_base` 副本构建）：`EXP3`（父任务先结束的继承）由 `done:None` 10/10 变 **`done:Some` 10/10**、`EXP4B diff=true`、`EXP5 50/50`、`EXP9` 仍 `Some(7)`、`EXP10 500/500`、`EXP11` 父任务由 `Some(2)` 变 **`Some(1)`**、`EXP12` 消息由"没有任务"变为**说明泛型实参问题**、`EXP13 a==b 0/500`、`EXP15` 与 `EXP16` 均 100/100 轮整组取消、`EXP17` 由 `None` 变 **`Some(9)`**；`EXP6` 的 FT/spawn 比值为 12.9x / 13.4x（修前区间 12.9x ~ 13.9x）。未修的 `FT-6`（性能机会）与 `FT-L1` 后半、`FT-L2` 见对应条目。

**修后总验证（FT-6 阶段，2026-10-11）**：worktree 内 `cjpm test` = `TOTAL: 31, PASSED: 31, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`；本阶段新增 5 条用例：⑥+① 1 条、③ 1 条、④ 1 条、⑤ 2 条）。探针（EXP18，同进程，按 worktree 的 `f_base` 副本构建）：端到端 `FutureTask<Int64>{1}` + `get()` **33.9 ~ 36.2 µs → 21.0 µs**（同批裸 `spawn{1}` + `get()` ~2.9 µs ⇒ **13× → ~7.2×**）；`currentOrNone()` ~330 → **~88 ns**；命中 `InheritedTaskLocal.get()` 700 ~ 870 → **~300 ns**（对照 `ThreadLocal.get()` 88~100 ns ⇒ 约 3.2×）。行为探针：`EXP3` 10/10 `Some`、`EXP5` 50/50、`EXP9` `Some(7)`、`EXP10` 500/500、`EXP11` 子 `Some(2)`/父 `Some(1)`、`EXP12` 消息不变、`EXP15` 100 轮 4/4、`EXP16` 0/0/0/0/100、`EXP17` `Some(9)`、`EXP19` 0/300 —— 全部保持。剩余未修的只有 `FT-L1` 后半与 `FT-L2`。

---

## 1. 严重（2 条）

### 1.1 [严重｜正确性·静默丢值] `FT-1` `InheritedTaskLocal` 在任务线程启动前写入的值永久不可读 ✓已复核 → ✅已修复（2026-10-11）

**✅ 修复标记（2026-10-11）**：分支 `fix/futuretask`（worktree `.worktrees/futuretask`，基线 `fe8a1886`；Windows 侧建的 worktree，WSL 侧 git 不识别属预期）。代码、用例、本标记在同一提交（提交信息 `fix(f_base): FT-1 任务身份改用构造期固定 id，hashCode/== 不再取可变 tid`；提交号见 §0 时间线回填）。

- 改动（`f_base/src/FutureTask.cj:35-51`）：`AbstractFutureTask` 新增静态 `nextTaskId = AtomicInt64(0)` 与实例 `taskId = nextTaskId.fetchAdd(1)`（**构造期分配、终生不变**）；`hashCode()` 返回 `taskId`，`operator ==` 比较 `taskId`。`tid`/`parentTID` 的用途不变（仍用于 `taskMap` 按"当前运行线程"索引与父链查找）。
- 用例：`f_base/src/FutureTask_test.cj` → `FutureTask_test.testLocalSetBeforeTaskRunsIsVisible`（构造后由创建线程 `set`，任务内必须读到；200 轮）、`FutureTask_test.testDistinctTasksAreNotEqualBeforeStart`（两个未启动任务必须互不相等；200 轮）。
- 测量证据（同机、`cjpm test --no-color`，日志 `/tmp/ftask_test.log`）：
  - **修前**：`FAILED 2` —— `(lost == 0)` left: **199** / right: 0；`(equalCount == 0)` left: **192** / right: 0；既有 6 条仍 PASSED（TOTAL: 8, PASSED: 6）。
  - **修后**：`TOTAL: 8, PASSED: 8, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`），两条新用例各自 PASSED。
- 未覆盖 / 影响面：`hashCode()` 的**取值**变了（不再是线程 id）；`AbstractInheritedTaskLocal.hashCode()`（`:161-163`）随之变为"同 owner 稳定"，这正是 `local` 表的键所需要的。公开签名未变，`Hashable` 契约只要求"相等对象同哈希"，未发现依赖 hashCode 具体取值的代码（本仓无调用方）。修前写入错误桶的**历史条目**无法找回（本来就是查不到的值），无需迁移。

**位置**：`f_base/src/FutureTask.cj:36-42`（`local` 表 + `hashCode`）、`:38`（`tid` 初值 0）、`:97`（线程体才 `store` 真实 id）、`:161-163`（`AbstractInheritedTaskLocal.hashCode` 转发给 owner 的 `hashCode`）

```cangjie
private let local = ConcurrentHashMap<AbstractInheritedTaskLocal, Any>()
protected let tid = AtomicInt64(0)
public func hashCode(): Int64 {
    tid.load()
}
```

**机制**：`local` 以 `AbstractInheritedTaskLocal` 为键，键的哈希值 = **owner 任务的 `tid`**。`tid` 在构造期是 `0`，任务线程体开头才写入真实线程 id。于是在"构造任务 → 由创建线程 `newLocal()` + `set(v)` → 任务内 `get()`"这条链上：

1. `set(v)` 发生在 `tid` 仍为 0 的窗口 ⇒ 条目落进 hash=0 的桶；
2. 任务内 `get()` 用真实 `tid` 计算哈希 ⇒ 查不到，返回 `None`；
3. 同一原因 `remove()` 也删不掉（条目残留到任务对象被回收）。

**实测**（EXP10 / EXP10b，机制对照）：

| 场景 | 读到 `Some(5)` | 读到 `None`（值丢失） |
|---|---|---|
| 构造后立即 `set`（delay 0ms） | 2 / 500 | **498 / 500（99.6%）** |
| 延迟 20ms（等任务线程先存好 `tid`）再 `set` | **500 / 500** | 0 / 500 |

窗口是**常态而非窄竞争**：EXP13 显示构造后立刻取样时 `hashCode()==0` 占 **497/500**。

**影响**：应用侧用 `InheritedTaskLocal` 给任务预置上下文（配置、traceId、请求作用域对象）会**静默失效**，调用方无从察觉。

**修复方向（内部实现，不改公开签名）**：把"身份"与可变的 `tid` 解耦 —— 构造期由类级 `AtomicInt64` 分配不可变 `id`，`hashCode()`/`operator ==` 与 `AbstractInheritedTaskLocal` 的键哈希一律用它；`tid` 只保留"这个任务跑在哪根线程上"的用途（`taskMap` 仍按线程 id 索引）。

**验证方法**：`run.sh exp10`（丢值）与 `run.sh exp10b`（对照，应 0 丢失）；修后两者都应为 `Some(5)=500 / None=0`。

### 1.2 [严重｜承诺不成立＋数据竞争] `FT-2` 父任务结束时子任务经常不会被取消 ✓已复核 → ✅已修复（2026-10-11）

**✅ 修复标记（2026-10-11）**：分支 `fix/futuretask`（worktree `.worktrees/futuretask`，基线 `fe8a1886`）。代码、用例、本标记在同一提交（提交信息 `fix(f_base): FT-2 子任务登记前移到创建线程并纳入共享锁，shutdown 不再漏取消`；提交号见 §0 时间线回填）。

- 改动（`f_base/src/FutureTask.cj`）：
  1. `:46-47`：`subTasks` 从 `FutureTask<T>` 移到 `AbstractFutureTask`（泛型类静态成员本来就共享，移上去后语义直白），并新增 `static let subTasksLock`；
  2. `:125-161`（`init`）：子任务**登记改由创建线程在起线程之前同步完成**——登记先于 `spawn` ⇒ 子任务开始运行时必然已在表里；能对该任务调 `shutdown` 的只有它的创建线程（此刻正忙于本构造函数），因此"登记完成、`future` 尚未赋值"这段窗口不会造成漏取消；登记与注销/整体取走全部走 `subTasksLock`；
  3. `:149-156`（finally 注销）：`get → set.remove → 空则删外层表项` 全部放进同一把锁 ⇒ 原先的 check-then-act 竞争消失；
  4. `:105-121`（`shutdownCurrentSubThreads`）：锁内**整体取走**该父任务的子任务表，锁外再逐个 `shutdown()` ⇒ 迭代不再与并发 `add/remove` 打架，用户可见的取消动作也不在锁里做；
  5. 删除已无用途的 per-instance `private let mutex = Mutex()`（原代码里它保护不了任何东西，还平白多一次分配）。
- 用例：`f_base/src/FutureTask_test.cj` → `testChildCancelledWhenParentFinishesImmediately`（20 轮 fire-and-forget，子任务必须收到取消）、`testConcurrentChildrenAllCancelled`（30 轮 × 4 个同类型子任务并发登记，必须全部被取消）、`testShutdownSubOnFinishFalseKeepsChildRunning`（行为保持：`shutdownSubOnFinish = false` 时不得取消子任务）。
- 测量证据（`cjpm test --no-color`，日志 `/tmp/ftask_test.log`）：
  - **修前**：`FAILED 2` —— `(notCancelled == 0)` left: **20** / right: 0；`(partial == 0)` left: **7**（30 轮）/ right: 0；行为保持用例 PASSED。
  - **修后**：`TOTAL: 11, PASSED: 11, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
- **复测驱动的细化（同一天的第二笔独立提交）**：性能复测发现第一版把 `spawn` 也包进了 `subTasksLock` 的临界区，子任务拆除时会抢同一把锁 ⇒ 构造+get 由 28826 升到 **32792 ns/op**（探针 exp6，同进程 FT/spawn 比值 12.9x → **14.9x**）。改为"登记仍在起线程之前，但临界区只包住登记本身"后复测 **30684 / 31974 ns/op**、比值 **12.9x / 13.4x**，回到修复前区间（12.9x ~ 13.9x），单测行为不变（提交信息 `perf(f_base): FT-2 细化：登记不包住 spawn，消除构造路径上的锁竞争`）。
- 独立探针复测（`exp15`、`exp16`，取自本 worktree 的最终代码）：**100/100 轮全部 4/4 被取消**（修前 79~83 与 85，另有 17~21 / 15 轮部分丢失）。
- 未覆盖 / 新边界：
  - 迭代仍按 `FutureTask<T>` 匹配（异类型子任务照旧被跳过）—— 属 `FT-3` 范围，本条刻意不动，便于单独归因；
  - 登记提前到构造期后，若 `shutdownSubOnFinish = false` 且某个子任务**始终未被调度运行**，它的表项会留到进程结束（极端边界；正常调度下子任务跑完即自行注销）；
  - `cancel()` 仍是协作信号、不终止线程（std 语义，未改，见本节"现象"段的说明）。
- 验证方法：worktree 内 `f_base` 跑 `cjpm test` 应为 11/11；探针 `run.sh exp5 / exp15 / exp16` 应为 100%（见 §5）。

**位置**：`f_base/src/FutureTask.cj:89-90`（`subTasks` + 每实例 `mutex`）、`:99-107`（子任务线程体内的登记）、`:110-123`（finally 的注销 + `shutdownSubOnFinish`）、`:150-157`（`shutdownCurrentSubThreads`）

```cangjie
private static let subTasks = ConcurrentHashMap<Int64, HashSet<AbstractFutureTask>>()
private let mutex = Mutex()
```

**机制（三条独立缺陷叠加）**：

1. **登记发生在子任务自己的线程体里**（`:99-107` 在 `spawn` 的闭包内）⇒ 父任务的 finally 调 `shutdownCurrentSubThreads()` 时，**尚未开始运行的子任务根本不在表里** ⇒ 永久漏取消；父任务摘掉的 `subTasks[parentTID]` 表项还会被子任务随后重新建出来，但已经没人再关它。
2. **`synchronized(mutex)` 用的是每个子任务自己的锁**（`mutex` 是实例字段，`:90`）⇒ 同一父任务的多个子任务之间**毫无互斥**；`get → else 新建 set → add`（`:100-106`）与 `set 空则删表项`（`:112-119`）都是 check-then-act，两个并发首注册的子任务可能丢掉一个 `set`（后来者覆盖前者的表项 ⇒ 前者的子任务再也关不掉）。
3. **`HashSet` 非线程安全**，而父任务的 `shutdownCurrentSubThreads` 正在**迭代**它（`:152-155`），子任务同时在 `add/remove`。

另：`Future.cancel()` 按 std 文档只发送协作取消信号、**不终止线程**（须由被取消方自查 `hasPendingCancellation`）；EXP14 实测 `shutdown()` 后 `get()` 仍返回 42、任务照常跑完 ⇒ README 里"结束当前 FutureTask"的措辞与实际能力不符。

**实测**：

| 实验 | 场景 | 结果 |
|---|---|---|
| EXP5 | 父任务创建子任务后立即结束（fire-and-forget，50 轮） | 被取消 **2 / 50**（未被取消 48，未上报 0） |
| EXP15 | 父任务先等 300ms 让 **4 个同类型**子任务登记完（100 轮，复跑 1 次） | 4/4 全取消 79、83；**部分被取消 21、17**；全不取消 0 |
| EXP16 | 同上，但子任务不提前结束（消除"迭代期间自摘"这一竞争源） | 被取消数 0/1/2/3/4 = **0/3/8/4/85** ⇒ 登记/迭代完整性本身就会丢 |

**影响**：`shutdownSubOnFinish = true`（默认值）在真实用法下**基本不生效**；且失败的形态是"部分子任务静默存活"，比全失败更难发现。

**修复方向**：

1. 子任务登记改到 `init` 里由**父线程同步完成**（父任务结束前必然已登记，消除时序竞争）；
2. `subTasks` 的"取或建 + 增删"改成原子语义（父任务级锁，或 `computeIfAbsent` 等价物），不再依赖"非线程安全 `HashSet` + 各自为政的 mutex"；
3. `shutdown()`/`shutdownCurrentSubThreads()` 的命名与 README 措辞改为"发送取消请求"，或另配一个能真正终止的机制（如协作式轮询约定）。

**验证方法**：`run.sh exp5`（期望 50/50 被取消）、`run.sh exp15` 与 `run.sh exp16`（期望每轮 4/4）。

---

## 2. 中（4 条）

### 2.1 [中｜静默跳过·确定性复现] `FT-3` 泛型实参过滤使异类型子任务不被取消 ✓已复核 → ✅已修复（2026-10-11）

**✅ 修复标记（2026-10-11）**：分支 `fix/futuretask`（worktree `.worktrees/futuretask`，基线 `fe8a1886`）。代码、用例、本标记在同一提交（提交信息 `fix(f_base): FT-3 取消能力上移到 AbstractFutureTask，异类型子任务不再被跳过`；提交号见 §0 时间线回填）。

- 改动（`f_base/src/FutureTask.cj`）：
  1. `AbstractFutureTask:99-121`：新增 `public func shutdown()`（= `cancelSelf()` + `shutdownCurrentSubThreads()`）、`protected open func cancelSelf(): Unit {}`、`public static func shutdownCurrentSubThreads()`——迭代元素类型改为 **`AbstractFutureTask`**，不再按 `FutureTask<T>` 过滤；
  2. `FutureTask<T>:184-186`：删除同名的 `shutdown()` / `shutdownCurrentSubThreads()`，改为覆写 `cancelSelf()`（`future?.cancel()`）。
- 兼容性：`FutureTask<T>.shutdown()` 与 `FutureTask<T>.shutdownCurrentSubThreads()` 照旧可用（成员继承；`AbstractFutureTask` 是 `sealed`，子类仅本包内），用例里加了一处**编译期调用点**确认解析没断；公开签名集合只增不减（`AbstractFutureTask` 多了 `shutdown()`）。
- 用例：`f_base/src/FutureTask_test.cj` → `testMixedTypeChildrenAreCancelledToo`（3 轮；父任务 `FutureTask<Unit>` 同时创建 `FutureTask<Unit>` 与 `FutureTask<Int64>` 两个子任务，父任务结束时**两个都必须收到取消信号**）。
- 测量证据：
  - **修前**：`FAILED 1` —— `(notCancelled == 0)` left: **3**（3 轮各丢一个 `Int64` 子任务；同轮的 `Unit` 子任务正常取消）。
  - **修后**：`TOTAL: 12, PASSED: 12, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
  - 独立探针 exp4B：修前 `same=true, diff=false` → 修后 **`same=true, diff=true`**。
- 未覆盖 / 待拍板：`FutureTask<T>.current()` 的泛型实参问题（EXP12）—— 见下面的"补充修复"。

**✅ 补充修复（2026-10-11，作者拍板后实施）**：`FutureTask<T>.current()` 类型无关化。

- 拍板口径（作者）：`AbstractFutureTask` 只有 `FutureTask<T>` 一个子类，因此 `current()` 里没必要区分"其它形状的任务"——模式匹配收成单点判断；其余按原方案做。
- 改动（`f_base/src/FutureTask.cj`）：
  1. `AbstractFutureTask` 新增 `public static func current(): AbstractFutureTask`（不在任务里抛 `FutureTaskException`）与 `public static func currentOrNone(): ?AbstractFutureTask`（不在任务里返回 `None`，便于分支处理而不是拿异常当控制流）；
  2. `FutureTask<T>.current()` **签名不变**（返回类型仍是 `FutureTask<T>` ⇒ 非破坏性），实现改为单点 `if(let Some(t: FutureTask<T>) <- AbstractFutureTask.currentOrNone())`；取不到时抛出的消息改为**说明实参问题**（旧消息 `No task found in current thread` 把 API 限制误报成"没有任务"）；
  3. `FutureTaskException` 由 `private` 改 `public` ⇒ 调用方可以按类型捕获；
  4. `InheritedTaskLocal.writeTarget()` 改用 `currentOrNone()`（"当前任务"只剩一个定义点，不再直接访问 `taskMap`）。
- 文档：`f_base/README.md` 与 `README_en.md` 同批（`AbstractFutureTask` 代码块补两个入口；`current()` 注释改为"要求该任务的泛型实参恰好为 T"）。
- 用例（`f_base/src/FutureTask_test.cj`，4 条）：`testCurrentTypeAgnosticHandleMatchesTypedHandle`（类型无关句柄与按 `T` 取的是同一任务，且可直接 `newLocal`）、`testCurrentWithWrongTypeArgumentThrowsWithPreciseMessage`（消息须含类型实参信息 + 可按 `FutureTaskException` 捕获）、`testCurrentOrNoneOutsideTaskIsNone`、`testCurrentOutsideTaskThrows`（守卫：既有行为不变）。
- 测量证据：
  - 单测：`TOTAL: 23, PASSED: 23, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。**说明**：这 4 条依赖新增 API 与公开异常类型，修前是**编译不过**而不是断言红，因此本条没有"修前 FAILED"数字。
  - 探针 EXP12（独立复测）：在 `FutureTask<Int64>` 体内调 `FutureTask<Unit>.current()`，消息由 `No task found in current thread` 变为 **`No FutureTask with the requested type argument found in current thread (a task of another type argument may be running); use AbstractFutureTask.current() instead`**；同批复测 EXP10 `500/500`、EXP11 父任务 `Some(1)`、EXP17 `Some(9)` 均未变（`writeTarget()` 收口无副作用）。
- 未覆盖：**未删除 `FutureTask<T>.current()`**（保留签名以免破坏外部调用方）。若作者希望只留类型无关入口，删它是"5 行代码 + README 两处"的小改动。

**位置**：`f_base/src/FutureTask.cj:153-155`（`shutdownCurrentSubThreads` 的模式匹配）、`:129-135`（`current()`）

```cangjie
while(let Some(f: FutureTask<T>) <- itr.next()){
    f.shutdown()
}
```

**机制**：`subTasks` 元素类型是 `AbstractFutureTask`（`:89`），但匹配模式带泛型实参 `FutureTask<T>`；而仓颉**泛型类的静态成员是共享的**（官方《泛型类》原文："由于泛型类的静态成员变量的内存是共享的…"）⇒ 同一张表里混有各种 `T` 的子任务，只有与调用方**同一个 `T`** 的会被处理。根因是 `AbstractFutureTask` 没有声明 `shutdown()`，元素类型被迫写成 `FutureTask<T>`。

**实测**（EXP4）：父 `FutureTask<Unit>` + 两个同类型子任务 ⇒ `a1=true a2=true`；父 `FutureTask<Unit>` + 子 `Unit`/`Int64` ⇒ **`same=true`，`diff=false`**（确定性）。
同类问题（EXP12）：在 `FutureTask<Int64>` 体内调用 `FutureTask<Unit>.current()` ⇒ 抛 `No task found in current thread`（线程里其实有任务，只是 `T` 不同）。

**修复方向**：把 `shutdown()`（或 `cancel()`）提升到 `AbstractFutureTask`，迭代按 `AbstractFutureTask` 调用；`current()` 去掉泛型实参过滤，改为返回 `AbstractFutureTask` 或保留显式转换。

**验证方法**：`run.sh exp4`（期望 `diff=true`）、`run.sh exp12`（期望不再抛异常）。

### 2.2 [中｜语义·需作者拍板] `FT-4` `InheritedTaskLocal` 的"写入目标固定为 owner"（四个出口）

**位置（当前行号，已含 FT-1~FT-3 改动）**：`f_base/src/FutureTask.cj:59-61`（`setLocal` 写 `this.local`）、`:62-71`（`getLocal` 链式上溯）、`:72-78`（`removeLocal` 写 `this.local`）、`:79-86`（`getOrSetLocal` 未命中时 `setLocal` 到 `this`）、`:87-95`（`getOrComputeLocal` 同）、`:189`（`AbstractInheritedTaskLocal(let task:)` —— owner 构造期绑定）、`:202-218`（`InheritedTaskLocal` 的 `set/get/remove/getOrSet/getOrCompute` 全部以 owner 为 `this`）；`:41`（`local` 表）、`:144`/`:148`（`taskMap` 的登记与摘除）。

**机制**：**读**是链式上溯（从「当前线程所属任务」沿 `parentTID` 逐级查）；**写/删**却恒落在**创建该 local 的 owner 任务**的表上 ⇒ 写目标与读目标不同步。owner 一结束，`taskMap.remove(tid)`（`:148`）剪断链，写进 owner 表的值对任何人（含写者自己）都不可达。

**四个出口的实测/读码结论**：

| 出口 | 现象 | 证据 |
|---|---|---|
| `set` | 子任务 `set` 覆盖 owner 的值，且对整个子树（owner + 兄弟）可见 | EXP11：父 `set(1)` → 子 `set(2)` ⇒ 子读 `Some(2)`、**父随后也读到 `Some(2)`** |
| `set`（owner 已结束） | 子任务 `set` 完立刻 `get` → **`None`**（写进不可达的表） | EXP17：owner 已结束 = `None`；owner 存活 = `Some(9)` |
| `remove` | 子任务 `remove` 会清掉 owner 的值（同一代码路径，未单独实测） | 读码（`:72-78` + `:210-212`） |
| `getOrSet`/`getOrCompute` | 未命中时写 owner；**非原子**（两个并发调用方可能各算一次、各返回自己那份，槽里最后写入者胜） | 读码（`:79-95`），且本轮决策为"保持现状" |

**影响面与兼容事实**：本仓零调用方；但该类**已随发布版本存在**（`git tag --contains 254ef066` 首个即 `release-1.2.0.alpha`；`release-1.3.8.alpha` 内含 `f_base/src/FutureTask.cj`；f_base 属 1.3.8 已入库模块）⇒ 外部应用**可能**已按当前语义写代码。不过"写落到哪"**从未被文档化**（`f_base/README.md:647-648` 只写"无值时从父任务查""任务结束时移除"，`docs/speech/speech.md:3751` 只写"本任务没值就去父任务找"），因此行为变更可按**语义明确化**处理；版本号又全为 `.alpha`。

**候选路线**：

1. 只写文档 + 钉口径用例（非破坏性）：把"`set`/`remove` 作用在 owner"写进 README(zh+en) 与源码注释，并用例钉住现状（含 EXP17 的 `None`）。代价≈0.5h、零代码风险；**形态 2（`set` 后自读 `None`）作为已知坑长期存在**。
2. **写"当前任务"（语义修正）**：`set`/`remove` 的目标改为「当前线程所属任务」，调用方不在任务里（创建线程 / main 线程）时回退 owner。实现只动 `InheritedTaskLocal`（约 10 行，不碰存储层）。修好形态 1/2/3；对齐 Java `InheritableThreadLocal`。代价=行为变更（语义未文档化 + 全 alpha，按明确化处理）。
3. 保留现语义 + 新增显式入口（`setOnCurrent`/`removeOnCurrent`）：非破坏性，但 `set` 默认行为仍反直觉，形态 1/2 仍会被踩。
4. `newLocal(inherit: Bool)` 或拆成两个类型：最彻底，改动与长期维护成本最大。

**✅ 路线决策（2026-10-11，作者拍板）**：

- **采用路线 2**：`set`/`remove` 的写入目标改为「当前任务」，不在任务里时回退 owner（该回退同时保住 FT-1 的既有语义：构造后由创建线程预置上下文）；
- **`getOrSet`/`getOrCompute` 保持现状**（仍写 owner 的共享槽、不加锁）：即这两个入口的语义是"为**整条链都没有值**时，给 local 所属任务的共享槽做懒初始化（子树共享）"，与 `set` 的"覆盖本层"分工并列，两者都要在文档里写清；
- **二次决策（同日，作者改主意）**：`getOrSet`/`getOrCompute` **不再**"保持现状不加锁"，改用**二段检查锁**（粒度 = 每个 local）：第一段无锁快路径，未命中才进锁；锁内复查后只有一个调用方计算并写入，其余拿到同一个值；写入目标仍是 owner 的共享槽。`fn` 在锁内执行（`Mutex` 可重入 ⇒ `fn` 内再对同一 local 调用不死锁，那次会再算一次并覆盖，属已文档化的例外）。实现与证据见修复标记的"二次修正"。
- 实现与用例见下面的修复标记。

**✅ 修复标记（2026-10-11）**：分支 `fix/futuretask`（worktree `.worktrees/futuretask`，基线 `fe8a1886`）。代码、用例、README(zh+en)、本标记在同一提交（提交信息 `fix(f_base): FT-4 set/remove 写当前任务（路线 2），getOrSet/getOrCompute 保持 owner 共享槽`；提交号见 §0 时间线回填）。

- 改动（`f_base/src/FutureTask.cj`）：
  1. `:204-209`：`InheritedTaskLocal` 新增私有 `writeTarget()` —— `AbstractFutureTask.taskMap.get(Thread.currentThread.id)`，取到就是「当前任务」，取不到（创建线程 / main 线程等）回退 owner；
  2. `:211-213`：`set` → `writeTarget().setLocal(...)`；`:219-221`：`remove` → `writeTarget().removeLocal(...)`；
  3. `:215-217`：`get`（链式上溯）未改动；`getOrSet`/`getOrCompute` 见下面的"二次修正"。
- 文档：`f_base/README.md` 与 `f_base/README_en.md` 同批更新（FutureTask 章节的第 2 条说明 + `InheritedTaskLocal` 代码块注释），写明三条分工：`get` 链式上溯 / `set`·`remove` 只动当前任务这一层 / `getOrSet`·`getOrCompute` 未命中写创建该 local 的任务（子树共享槽、不加锁）。
- 用例（`f_base/src/FutureTask_test.cj`，5 条）：`testChildSetDoesNotAffectOwner`、`testChildSetVisibleToOwnDescendant`（守卫：子任务的写必须能被自己的后代读到）、`testSetThenGetInTaskWorksAfterOwnerFinished`、`testChildRemoveDoesNotClearOwner`、`testGetOrComputeStillPopulatesOwnerSlot`（钉住第 3 条决策）。
- 测量证据（`cjpm test --no-color`，日志 `/tmp/ftask_test.log`）：
  - **修前**：`TOTAL: 17, PASSED: 13, FAILED: 4` —— `box["owner"]=="2"`（期望 `"1"`）、`box["sibling"]=="2"`（期望 `"1"`）；`box["self"]=="None"`（期望 `"9"`，即 EXP17）；`box["childAfterRemove"]=="None"`、`box["owner"]=="None"`；`box["ownerOwn"]=="2"`（期望 `"1"`）。守卫用例与 `getOrCompute` 的 `ownerShared/childShared=="42"` 修前即通过。
  - **修后**：`TOTAL: 17, PASSED: 17, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
- 独立探针复测（按 worktree 的 f_base 副本构建）：`EXP11` 父任务由 `Some(2)` 变为 **`Some(1)`**、子任务仍 `Some(2)`；`EXP17` owner 已结束由 `None` 变为 **`Some(9)`**（owner 存活同样 `Some(9)`）；`EXP10` 仍 **500/500**（"构造后由创建线程 `set`"这条回退路径未被破坏，FT-1 语义保持）。
- 未覆盖 / 影响面：**行为变更** —— 依赖"子任务 `set` 改到父任务""子任务 `remove` 清掉父任务"的外部代码需改（语义此前未文档化、版本全为 `.alpha`，按"语义明确化"处理并在 README 写明）。

**✅ 二次修正（2026-10-11）**：`getOrSet`/`getOrCompute` 由"未命中写 owner + 不加锁"改为**二段检查锁**（作者同日改主意）。本标记上文"改动 3."与决策块里按第一版口径写的"保持现状"以本修正为准。

- 改动（`f_base/src/FutureTask.cj`）：
  1. `:206`：`AbstractInheritedTaskLocal` 新增 `let initLock = Mutex()`（包内可见；粒度 = 每个 local —— 一个 local 只对应某个任务表里的一个槽，正好覆盖该槽的全部写入者）；
  2. `:80-92`（`getOrSetLocal`）与 `:94-106`（`getOrComputeLocal`）改为二段检查：第一段无锁快路径 → 未命中则 `synchronized(local.initLock){ 锁内复查 → 命中即返回；否则计算/写入 }`。`fn()` 在锁内执行 ⇒ 只算一次；`Mutex` 可重入 ⇒ `fn` 内再对同一 local 调用不死锁（那次会再算一次并覆盖，属已文档化的例外）。
- 文档：`f_base/README.md` 与 `f_base/README_en.md` 同批改口径（删掉"不加锁、不保证只计算一次"，写明二段检查锁 + `fn` 在锁内 + `Mutex` 可重入）。
- 用例（`f_base/src/FutureTask_test.cj`，2 条）：`testGetOrComputeComputesOnceUnderConcurrency`（8 个子任务经 `AtomicBool` 闸门同时抢同一个 local 的 `getOrCompute`，`fn` 内 `sleep(20ms)` 放大"检查→写入"窗口）、`testGetOrComputeDoesNotComputeWhenValueExists`（守卫：链上已有值不再算、不覆盖）。
- 测量证据：
  - **修前**：`TOTAL: 19, PASSED: 18, FAILED: 1` —— `(computeCount.load() == 1)` left: **8**（8 个并发调用方各算一次）、`(allSame == true)` left: **false**（各拿到自己那份值）。
  - **修后**：`TOTAL: 19, PASSED: 19, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
- 未覆盖：`set`/`remove` 仍不加锁（它们按路线 2 写"当前任务"；只有调用方恰好是 owner 时才会与并发的 `getOrCompute` 撞同一个槽 ⇒ 那一种情况是"最后写入者胜"，DCL 的"只算一次"保证不受影响）。锁序只有 `initLock` → `subTasksLock`（`fn` 内建任务时才取后者），反向不存在，无环。

### 2.3 [中｜缺陷] `FT-5` 父任务先结束后，子任务继承不到值 ✓已复核 → ✅已修复（2026-10-11）

**✅ 修复标记（2026-10-11）**：分支 `fix/futuretask`（worktree `.worktrees/futuretask`，基线 `fe8a1886`）。作者定性为**缺陷**（不是"设计使然"）。代码、用例、README(zh+en)、本标记在同一提交（提交信息 `fix(f_base): FT-5 继承改走构造期固定的父链，父任务先结束不再切断继承`；提交号见 §0 时间线回填）。

- 根因：`getLocal` 的链式查找靠 `taskMap.get(父线程id)` 逐级上溯，而 `taskMap` 只登记**正在运行**的任务（父任务结束时摘除）⇒ "父任务已结束"会把继承链剪断 —— 但父子关系是**任务树的静态事实**，不该随存活状态消失。
- 改动（`f_base/src/FutureTask.cj`）：
  1. `AbstractFutureTask` 新增构造期固定的 `let parent: ?AbstractFutureTask = taskMap.get(Thread.currentThread.id)`（`:50-53`；创建线程不是任务时为 `None`）；
  2. `getLocal`（`:66-77`）改为：起点仍是"当前线程正在执行的任务"，之后沿 `task.parent` 上溯，不再查 `taskMap`。正向副作用：读路径不再依赖"线程 id 唯一且不重用"，也不会因线程 id 复用而走到无关任务上（即 `FT-L4` 的建议）。
- 生命周期口径：子任务因此**持有父任务（及其祖先）的强引用** —— 这是继承语义所要求的（父任务的值必须在其结束后仍能被已创建的后代读到）；父任务对象与它的值随最后一个引用它的后代一起被回收。原 README 那句"任务结束时相应的 InheritedTaskLocal 会被移除"与实现从来不符，本次连同 `FT-L3` 一起改为准确表述（`README.md` / `README_en.md` 同批）。
- 用例（`f_base/src/FutureTask_test.cj`，3 条）：`testChildInheritsAfterParentFinished`（父 `set(7)` 后立即结束，子任务在父任务结束之后读）、`testGrandChildInheritsAcrossFinishedAncestors`（两级祖先都已结束时，孙任务仍读到根的值）、`testChildSeesParentValueWrittenAfterCreation`（守卫：继承是活引用而非构造期快照 —— 父任务在子任务创建**之后**写的值也要能被读到）。
- 测量证据：
  - **修前**：`TOTAL: 26, PASSED: 24, FAILED: 2` —— `box["child"]=="None"`（期望 `"7"`）、`box["grand"]=="None"`（期望 `"7"`）；守卫用例 PASSED。
  - **修后**：`TOTAL: 26, PASSED: 26, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
  - 独立探针复测：`EXP3` 由 `done:None` 10/10 变为 **`done:Some` 10/10**；`EXP9`（父任务存活）仍 `Some(7)`；同批 `EXP10 500/500`、`EXP11` 父任务 `Some(1)`、`EXP17` `Some(9)` 均未变。
- 注意：`parentTID` 仍保留（`subTasks` 的登记/注销与 `shutdownCurrentSubThreads` 按"创建线程 id"索引，属 FT-2 的机制），只有**读路径**改走父链。

### 2.4 [中｜性能机会] `FT-6` 每任务固定开销 ≈ 7.2 倍裸 `spawn`（修前 13 倍）；`local` 读 ≈ 3.2 倍标准库（修前 8 倍）　**已量化 + 全部候选已实施（2026-10-11，见下）**

**实测**（EXP6，同进程内两轮对照，取第 2 轮为主证据）：

| 操作 | 耗时 |
|---|---|
| `spawn{1}` + `get()` | 2173 / 2230 ns/op |
| `FutureTask<Int64>{1}` + `get()` | 30304 / 28826 ns/op（**+26.6 µs，约 13×**） |
| 任务内 `InheritedTaskLocal.get()`（命中自己） | 747 ns/op |
| 任务内 `ThreadLocal.get()`（对照） | 84 ns/op（**约 8.9×**） |
| `Thread.currentThread.id`（单独测） | 17 ns/op |
| `local.get()` 未命中（owner 已结束，走链到 `None`） | 860 ns/op |

**开销来源**：构造期的 2 张并发表登记（`taskMap` + `subTasks`）+ `HashSet` + `Mutex` + `AtomicInt64` + **每实例一张 `ConcurrentHashMap`**（`:36`）；结束时要再走一遍注销 + `shutdownCurrentSubThreads`；另外同一 owner 的所有 local 哈希值相同（都等于 owner 的 `tid`）⇒ 在 `ConcurrentHashMap` 里退化成单桶链表。

**可选优化（只动成本不动能力，改后须同结构复测）**：

1. `local` 改为惰性分配（不用就不建表）；
2. 键哈希改用稳定 id（与 `FT-1` 同一处改动）；
3. 登记/注销各压到一次 map 操作（与 `FT-2` 同一处改动）；
4. 读路径缓存"当前任务"（例如每线程缓存 task 引用），避免每次 `local.get()` 都走 `Thread.currentThread.id` + map 查找；
5. `mutex` 若不再需要（见 `FT-2`）就删除，省掉每实例一次 Mutex 分配。

**📊 量化（2026-10-11，探针 `EXP18`，同进程内对照；A 组 n=2000、B 组 n=50000、C 组 n=20000，每项预热 1 轮 + 测 2 轮，跨 4 次运行取稳定区间）**

端到端（最稳的一层）：

| 项 | ns/op | 4 次运行范围 |
|---|---|---|
| `spawn{1}` + `get()`（裸基线） | ~3200 | 3035 ~ 3411 |
| `FutureTask<Int64>{1}` + `get()`（**当前修复版**） | **~34000** | 31916 ~ 37719 |
| 每任务增量 | **+30 ~ 33 µs（≈10.5×）** | — |
| `FutureTask<Int64>(false, …)` + `get()`（跳过 teardown 的 `shutdownCurrentSubThreads`） | ~32000 | 29393 ~ 34268 |

可归因分项（**关键：不要用"同线程 op 单价"估算优化收益，会低估 4~6 倍**）：

| 分项 | 实测 | 说明 |
|---|---|---|
| `local` 空 `ConcurrentHashMap` 构造 | **3.6 ~ 5.2 µs/次**（稳定） | 对照：空 `HashMap` **0.42 ~ 0.55 µs**、`Array<Int64>(16)` **0.27 µs** ⇒ 其中"分配"本身只占 ~0.3µs，其余是 `ConcurrentHashMap` 构造自身的固定开销（默认容量的表/段结构） |
| teardown 的 `shutdownCurrentSubThreads()` | **0.4 ~ 4.8 µs/任务**（均值 ~3µs） | 用 `shutdownSubOnFinish` true/false 直接 A/B 测得 |
| 记账（`taskMap.add/remove` + `subTasks` 登记/注销 + `HashSet` + 锁）**放在子线程里做** | **+3.0 ~ 9.5 µs/任务**（跨运行波动近 2×） | 同样几项在**同线程**的单价合计仅 ~1.6 µs（并发 map 1.24 + `HashSet` 0.33 + 空临界区 0.02）⇒ 差距来自跨核访问共享结构与 GC，故按区间给 |
| 共享锁争用（父线程登记 vs 子线程 teardown） | **≈ 0** | A7/A9/A9b 均 2.5 ~ 4.1 µs ≈ 裸基线 ⇒ 锁不是瓶颈 |
| 原子操作 / 空临界区 | 9 ~ 21 ns | 可忽略 |
| **未归因余量** | **≈ 8 ~ 19 µs（40~60%）** | 按单价推算仍主要是"分配"（任务对象、闭包、`AtomicInt64`、`Option` 包装）与跨线程对象传递/GC：A10"在子线程里分配一张空表并丢弃"整体 12~14 µs（含 3.2µs 基线）⇒ 子线程语境把分配放大 ~2× |

读路径（任务内）：

| 项 | ns/op |
|---|---|
| `InheritedTaskLocal.get()` 命中 | **700 ~ 870** |
| `ThreadLocal<Int64>.get()` 命中（对照） | **88 ~ 100**（≈ 8×） |
| `InheritedTaskLocal.get()` 未命中（沿父链 2 节点到 `None`） | 568 ~ 609 |
| `AbstractFutureTask.currentOrNone()`（= 线程 id + `taskMap` 查） | **317 ~ 342** |
| `Thread.currentThread.id`（单独测） | **20 ~ 24** |

⇒ 命中读的 ~700ns 里 **约 320ns 是"取当前任务"**（其中 id 仅 20ns，其余 ~300ns 是 `taskMap` 查），剩余 ~380ns 是一次 `ConcurrentHashMap.get` 加调用/包装开销。

**量化结论（可省上限）**：上面候选全做完，每任务约省 4µs（惰性分配）+ 3µs（短路 shutdown）+ 3~9.5µs（压缩记账）⇒ **33µs → 16~23µs（1.5~2×）**；读路径另可省 ~300 ns/次（缓存当前任务）与 ~200~400 ns/次（换结构）。**本条的天花板是"1.5~2×"，回不到裸 `spawn` 的 3µs 量级** —— 量级差距的主因是"每任务一张 `ConcurrentHashMap`（构造就要 3.6~5.2µs）＋ 每次构造/销毁的跨线程对象往返与分配"，要数量级改善必须动任务对象结构或 `spawn` 语义（超出本条候选清单）。
另记：`FT-5` 在构造期新增一次 `taskMap.get`（`parent`）≈ **+0.3 µs/任务**（按 C4 推断，未单独 A/B）。

**各候选的量化裁决**：

| 候选 | 可省 | 风险 / 前置条件 | 建议 |
|---|---|---|---|
| ① `local` 惰性分配 | **3.6 ~ 5.2 µs/任务（11~16%）** | 必须定"懒建表"的并发方案（两线程同时建表会丢一侧写入 ⇒ 一次性发布，不能裸判空后 `add`） | **✅已修复（2026-10-11，与 ⑥ 一并实施，见下）** |
| ③ 短路 `shutdownCurrentSubThreads()` | **~3 µs/任务（~9%）** | 只需一个"本任务是否登记过子任务"的线程局部标志/计数 | **✅已修复（2026-10-11，见下；实测 −1.6µs）** |
| ④ 读路径缓存"当前任务" | **~300 ns/次读（~40%）** | 每任务 2 次 `ThreadLocal` 写（~0.2µs） | **✅已修复（2026-10-11，见下；实测 −3.1µs/任务，读路径累计降到 ~300ns）** |
| ⑤ 压缩记账 | **3 ~ 9.5 µs/任务** | 要把"子任务 teardown 动共享结构"改成"父任务收尾整体清理"，牵动 `FT-2`/`FT-5` 的边界与泄漏口径 | **✅已修复（2026-10-11，见下；实测 −0.9µs，另一部分已随 ④ 兑现）** |
| ⑥ `local` 换 `Mutex`+`HashMap` | 构造 ~4µs + 单次 op ~0.9µs | 读要从"无锁并发读"变成"加锁读"（并发语义变化） | **✅已修复（2026-10-11，与 ① 一并实施，见下）** |
| ② 键哈希稳定 id / ⑦ 删 `mutex` | — | — | **✅ 已随 `FT-1` / `FT-2` 完成** |

**✅ 修复标记（2026-10-11，⑥+① 一并实施：`local` 改 `Mutex` + `HashMap`，且首次写入才建表）**

分支 `fix/futuretask`（worktree `.worktrees/futuretask`）。代码、用例、本标记、量化复测同一次提交。

- 改动：`f_base/src/FutureTask.cj` —— `local` 由 `ConcurrentHashMap<AbstractInheritedTaskLocal, Any>()`（eager）改为 `private var local: ?HashMap<…> = None` + `private let localLock = Mutex()`；新增 `readLocalRaw`/`writeLocalRaw`/`removeLocalRaw` 三个私有原语（各自在 `localLock` 内完成，**写路径首次调用时建表**），`setLocal`/`getLocal`/`removeLocal` 改为调用它们。
  - 并发口径：**读也加锁** ⇒ "懒建表"不需要额外的原子发布协议，也没有跨线程可见性问题；锁不跨越用户代码；锁序固定为 `local.initLock` → `task.localLock`（无反向；`Mutex` 本身可重入）。
- 用例（`f_base/src/FutureTask_test.cj`，新增 1 条）：`testConcurrentChildrenCreateOwnerMapLazily` —— owner 一张表都没有时，3 个子任务并发向 owner 写**不同**的 local，之后 owner 与"之后创建的后代"都要读回这三个值（钉住"并发懒建表不丢一侧写入"）。
- 测量证据（同进程，探针 `EXP18`；改前 4 次运行区间 → 改后）：
  - 端到端 `FutureTask<Int64>{1}` + `get()`：**33.9 ~ 36.2 µs → 25.5 ~ 27.7 µs**（同批裸 `spawn{1}`+`get()` 2.6 ~ 2.7 µs ⇒ 增量 **~31 µs → ~24 µs，−7.4 µs/任务（−22%）**）；
  - 读路径：命中 `InheritedTaskLocal.get()` **700 ~ 870 ns → 505 ~ 508 ns**；
  - 组件对照（未变，说明收益来自 ⑥+① 本身）：空 `ConcurrentHashMap` 构造 4.6 ~ 4.8 µs、`Mutex`+`HashMap` 的 add+remove 295 ~ 320 ns、`ThreadLocal.get()` 91 ~ 92 ns。
- 单测：`TOTAL: 27, PASSED: 27, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
- 行为变化 / 未覆盖：`local` 的读由"无锁并发读"变为"加锁读"（并发语义变化：大量并发读同一个 owner 的 local 会串行化；本结构的实际形态是"少数写、少量读"，故按收益取舍）。既有 26 条用例（含并发 DCL 用例 `testGetOrComputeComputesOnceUnderConcurrency`）全绿。

**✅ 修复标记（2026-10-11，③ 短路叶子任务的 teardown 清理）**

- 改动：`f_base/src/FutureTask.cj` —— 新增 `var hasChildren`（登记成功时给**创建者任务**打标：`if(let Some(creator) <- task.parent){ creator.hasChildren = true }`）；teardown 的 `if(shutdownSubOnFinish)` 改为 `if(shutdownSubOnFinish && task.hasChildren)`。字段只由创建线程自己写、自己读（登记在它自己的构造函数里，teardown 在同一个线程），无需原子。
- 用例：`f_base/src/FutureTask_test.cj` 新增 `testLeafTaskCreatesNoSubTaskBucket`（叶子任务不在自己 tid 下留桶 —— 短路的正确性前提）。**本项无用户可见行为变化**（叶子任务本来就没有桶要摘），因此没有"修前 FAILED"的数字，由既有 FT-2 用例（`testChildCancelledWhenParentFinishesImmediately`、`testConcurrentChildrenAllCancelled`、`testMixedTypeChildrenAreCancelledToo`）守卫。
- 测量证据（EXP18，同进程）：端到端 `FutureTask<Int64>{1}` + `get()` **26.6 µs → 25.0 µs（−1.6 µs/任务）**（同批裸基线 2.6 ~ 2.7 µs）。
- 行为探针复测（同一构建）：`EXP5` 50/50 被取消、`EXP15` 100 轮 4/4、`EXP16` 0/0/0/0/100、`EXP3` 10/10 `Some`、`EXP9` `Some(7)` —— 取消完整性与继承口径均未变。
- 单测：`TOTAL: 28, PASSED: 28, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。

**✅ 修复标记（2026-10-11，④ 读路径缓存"当前任务"，并移除 `taskMap`）**

- 改动：`f_base/src/FutureTask.cj` —— 新增 `static let currentTask = ThreadLocal<AbstractFutureTask>()`（**包内可见**：`FutureTask<T>` 的构造与拆除要维护它；`private static` 在子类里不可见，编译期报 `can not access field 'currentTask'`）；`getLocal` 的起点、`currentOrNone()`、构造期的 `parent` 三处由 `taskMap.get(Thread.currentThread.id)` 改为 `currentTask.get()`；任务线程在 `spawn` 体内用 `set(task)` / `set(None)` 取代 `taskMap.add/remove`；**删除 `taskMap` 与只服务于它的 `protected let tid`**（`AbstractFutureTask` 是 `sealed`，删除不破坏外部子类）。
- 用例：`f_base/src/FutureTask_test.cj` 新增 `testCurrentTaskCacheClearedForReusedThreads` —— 200 轮"先跑一个 `FutureTask`，再在同一线程池上跑普通 `spawn`"，后者必须读不到**已结束**的任务（钉住缓存清理；原 taskMap 版本靠 `remove` 保证同一点）。
- 测量证据（EXP18，同进程）：端到端 `FutureTask<Int64>{1}` + `get()` **25.0 µs → 21.9 µs（−3.1 µs/任务）**；`currentOrNone()` **~330 ns → ~88 ns**；命中 `InheritedTaskLocal.get()` **~505 ns → ~298 ns**（累计 700~870 → ~300 ns）。−3.1µs 里除"省掉 ~240ns 的查表"外，还包含**移除 `taskMap` 带来的两次并发 map 写**（子任务启动/拆除各一次），故远大于单项预估的 ~0.3µs。
- 行为探针复测（同一构建）：`EXP3` 10/10 `Some`、`EXP9` `Some(7)`、`EXP10` **500/500**（FT-1 语义保持）、`EXP11` 子 `Some(2)` / 父 `Some(1)`（FT-4 路线 2，判定依赖"当前任务"）、`EXP12` 异类型实参消息不变、`EXP17` `Some(9)`、`EXP5` 50/50 —— 全数不变。
- 单测：`TOTAL: 29, PASSED: 29, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。

**✅ 修复标记（2026-10-11，⑤ 压缩登记/注销：桶由创建者整体清理，子任务不再自行注销）**

- 改动：`f_base/src/FutureTask.cj` ——
  1. 新增 `let finished = AtomicBool(false)`（teardown 一开始置位）；
  2. 登记路径：桶大小 ≥ 64 时先 `pruneFinishedChildren`（剪掉已结束项；摊还到每次登记约 1 个元素）；
  3. `shutdownCurrentSubThreads()`：取桶后逐个取消时**跳过 `finished` 的子任务**；
  4. teardown：`hasChildren` 为真 ⇒ `shutdownSubOnFinish` 走"取桶 + 锁外取消"，否则只把桶摘掉一次；`hasChildren` 为假 ⇒ 整段短路（③）。**创建者是任务时不再自行注销**（桶由创建者收尾整体摘除）；创建者不是任务（main、普通 spawn）时保留旧注销路径，避免表项堆积。
- 语义等价性（本条最关键的一处核对）：旧实现里**已结束的子任务会自行注销** ⇒ 父任务本来就够不到它的子树，因此"跳过已结束项"不削弱任何既有保证（`shutdown` 的递归只影响仍在运行的子树）。`EXP19`（对已结束任务 `cancel()` 300 次：0 次波及同线程后续任务）另佐证"跳过"只是省事、不是必需。
- 用例（`f_base/src/FutureTask_test.cj`，新增 2 条）：
  - `testParentTeardownRemovesItsSubTaskBucket`（`shutdownSubOnFinish=false` + 两个还在睡的子任务 ⇒ 父任务收尾必须把桶摘掉）—— **修前 `TOTAL: 31, PASSED: 30, FAILED: 1`（红的正是它：`subTasks.get(t).isNone()` left: false）→ 修后 31/31**；
  - `testLongLivedParentBucketStaysBounded`（长命父任务连续建 1000 个子任务，桶峰值 ≤ 200）—— 守卫"子任务不再自行注销"不会变成内存增长。
- 测量证据（EXP18，同进程）：端到端 **21.9 µs → 21.0 µs（−0.9 µs/任务）**；命中读 ~300 ns 不变。（原先预估的 3~9.5µs 里，`taskMap` 的两次并发 map 写已在 ④ 一并兑现。）
- 行为探针复测（同一构建）：`EXP5` 50/50、`EXP15` 100 轮 4/4、`EXP16` 0/0/0/0/100、`EXP3` 10/10 `Some`、`EXP11` 子 `Some(2)` / 父 `Some(1)` —— 取消完整性与继承口径不变。
- 单测：`TOTAL: 31, PASSED: 31, SKIPPED: 0, ERROR: 0, FAILED: 0`（`TEST_EXIT=0`）。
- 未覆盖：非任务创建者（main 线程）路径只有间接用例（`testLeafTaskCreatesNoSubTaskBucket` 与既有 fire-and-forget 用例）；64 这个剪枝阈值没有单独的边界用例。

---

## 3. 低危 / 登记（4 条）

- **`FT-L1`｜异常契约**：~~`current()` 抛出的 `FutureTaskException` 是 `private` ⇒ 应用侧无法按类型捕获~~ **✅ 前半已修（2026-10-11，随 `b7226c17`：`FutureTaskException` 改 `public`，用例 `testCurrentWithWrongTypeArgumentThrowsWithPreciseMessage` / `testCurrentOrNoneOutsideTaskIsNone` 按类型捕获）**；余下：`get()`/`get(timeout:)`/`tryGet()` 走 `future.getOrThrow()`，而 `future` 是可变 `var`，极端时序下会抛 Option 的异常而非本模块异常 —— 待处理。
- **`FT-L2`｜API 不对称**：`removeLocal` 返回 `?T`（`:62-68`）但 `InheritedTaskLocal.remove()` 丢弃返回值（`:181-183`）；`getOrSet`/`getOrCompute` 只挂在 `InheritedTaskLocal`，`AbstractFutureTask` 上没有对应公开入口。
- **`FT-L3`｜内存口径（结论修正，2026-10-11）**：**不应清理** `local`。父任务的值必须在其结束后仍能被已创建的后代读到（`FT-5` 已定性为缺陷并修复，见 §2.3），因此"任务结束时清空 `local`"会直接破坏继承；实现无需改动。README 里那句"FutureTask 初始化时的任务结束时，相应的 InheritedTaskLocal 会被移除"与实现从来不符，已随 FT-5 改为"值随任务对象一起被回收"（中英文同批）。
- **`FT-L4`｜防御性建议：✅ 已随 FT-5 实现（2026-10-11）**。`getLocal` 的读路径不再依赖"线程 id 在存活期内唯一、且不重用"的假设，改为**显式父子引用链**（`AbstractFutureTask.parent`，构造期固定 ⇒ 链必然无环，不需要跳数上限）；`parentTID` 仅剩 FT-2 的登记/注销用途。

---

## 4. 已排除的怀疑（`FT-X1`，不要再当问题上报）

**`FT-X1`｜`getLocal` 自旋死循环：不成立（未复现）**

- 理论条件：`taskMap[tid].parentTID == tid`，即"任务跑在创建它的那根线程上"（`FutureTask.cj:52-59` 的 `while` 会自环）。
- 实测反证：**EXP7** 顺序 `spawn` 20000 次得到 **20000 个不同 tid、零复用**；**EXP1/EXP2/EXP8** 共 **900 次**"父任务创建子任务后立即结束"（含先占 200 线程的饱和场景）**0 次**子任务落在创建它的线程上。
- 结论：当前 runtime 下不可达，只保留 `FT-L4` 的防御性建议。

**同时已核对为"正确"的实现细节**（避免重复怀疑）：

- `ConcurrentHashMap.add(key, value)` 是"键存在则**替换**旧值"（std 文档原文）⇒ `setLocal` 的覆盖语义、`taskMap.add` 的登记语义都正确；
- `taskMap` 的摘除在 `finally` 中，异常路径也覆盖，未发现脏登记/泄漏；
- `Thread.currentThread.id` 开销 17 ns/op，不是 `local.get()` 747 ns 的主要来源。

---

## 5. 探针与复现

**工程**：`.autocode/tmp/ftask_probe/`（gitignore 区，不提交）

- `setup.sh`：把仓库 `f_base` 逐字节复制到 `ftask_probe/f_base`（打印两份 `FutureTask.cj` 的 sha256 供核对），把 `probe/src/main.cj` 拷成副本的 `src/zz_probe_main.cj`，`sed` 把副本 `output-type` 改成 `executable`，再 `cjpm build`
- `build.sh`：单独重建（完整日志 `/tmp/ftask_build.log`）
- `run.sh <expN> [timeout秒]`：跑某一组实验（带 `timeout`，便于观察挂死）

```bash
wsl -d Ubuntu-24.04 -e bash -lc "cd /mnt/d/docs/work/cangjie/projects/fountain/.autocode/tmp/ftask_probe && bash setup.sh"
wsl -d Ubuntu-24.04 -e bash -lc "cd /mnt/d/docs/work/cangjie/projects/fountain/.autocode/tmp/ftask_probe && bash run.sh exp5 300"
```

> 注意：`setup.sh` 每次会重建 `f_base` 副本（`rm -rf`），跑实验前后都可用 `sha256sum` 核对仓库与副本一致。

**实验索引（编号 → 结论 → 数字）**：

| 实验 | 覆盖 | 关键数字 |
|---|---|---|
| EXP1 | 纯 std：子任务是否落在创建它的线程上 | 0 / 300 |
| EXP2 | 真实 `FutureTask`：子任务与父任务同 tid | 0 / 300 |
| EXP3 | fire-and-forget 下子任务 `local.get()` | `done:None` 10/10，无挂死 |
| EXP4 | `shutdownCurrentSubThreads` 泛型过滤 | A：a1=true a2=true；B：same=true **diff=false** |
| EXP5 | 父任务先结束 ⇒ 子任务是否被取消 | 被取消 **2 / 50** |
| EXP6 | 微基准（构造/读） | 见 §2.4 表 |
| EXP7 | 线程 id 是否复用 | 20000 次 spawn ⇒ 20000 个不同 tid、0 复用 |
| EXP8 | 先占 200 线程再测同 tid | 0 / 300 |
| EXP9 | 父任务存活时继承（正例） | 子任务读到 `Some(7)` |
| EXP10 | 构造后立即 `newLocal+set` | `Some=2` / **`None=498`**（500 轮） |
| EXP10b | 延迟 20ms 再 `set`（对照） | **`Some=500`** / `None=0` |
| EXP11 | 子任务 `set` 是否覆盖父任务 | 子 `Some(2)`、父随后 `Some(2)` |
| EXP12 | `FutureTask<Unit>.current()` 在 `FutureTask<Int64>` 体内 | 抛 `No task found in current thread` |
| EXP13 | 未启动任务的 `==` / `hashCode` | `a==b` 474/500；`hashCode==0` 497/500 |
| EXP14 | `shutdown()` 是否终止任务 | `get()` 仍返回 42，任务照常跑完 |
| EXP15 | 4 个同类型子任务并发登记的取消完整性（100 轮） | 全取消 79/83，**部分 21/17** |
| EXP16 | 同上但子任务不提前结束（消除迭代期自摘） | 0/1/2/3/4 = **0/3/8/4/85** |
| EXP17 | 子任务 `set(9)` 后自读（owner 已结束 vs 存活） | `None` / `Some(9)` |
| EXP18 | FT-6 分项量化（端到端 / 组件单价 / 任务内读路径） | 见 §2.4 量化表（4 次运行区间） |
| EXP19 | 对已结束任务 `cancel()` 是否误伤同线程后续任务 | **0 / 300**（未观察到误伤） |

**修后复测（2026-10-11，探针改为复制 worktree 的 f_base 构建）**：

| 实验 | 修前 | 修后 |
|---|---|---|
| EXP3（fire-and-forget 继承） | `done:None` 10/10 | **`done:Some` 10/10**（随 `FT-5` 修复） |
| EXP4B（混合类型子任务） | same=true, **diff=false** | **same=true, diff=true** |
| EXP5（父任务先结束） | 2 / 50 被取消 | **50 / 50** |
| EXP10（delay 0 丢值） | 2 / 500 读到 | **500 / 500** |
| EXP10b（delay 20ms） | 500 / 500 | 500 / 500 |
| EXP13（`a == b` 误判） | 474 / 500 | **0 / 500**（`hashCode==0` 1/500 是首个任务的合法 id） |
| EXP15（4 子任务并发登记） | 全取消 79 ~ 83 / 100 | **100 / 100** |
| EXP16（消除迭代期自摘） | 0/3/8/4/85 | **0/0/0/0/100** |
| EXP11（子任务 set 是否覆盖父任务） | 父任务读到 `Some(2)` | **`Some(1)`**（子任务仍 `Some(2)`） |
| EXP17（owner 已结束时子任务 set 后自读） | `None` | **`Some(9)`**（owner 存活同样 `Some(9)`） |
| EXP6-1（构造+get） | 28826 ~ 30304 ns/op（比值 12.9x ~ 13.9x） | 30684 ~ 31974 ns/op（比值 12.9x ~ 13.4x） |
| EXP6-2（任务内 `InheritedTaskLocal.get`） | 747 ns/op | 654 ~ 710 ns/op |
| EXP6-3（未命中走链） | 860 ns/op | 783 ~ 828 ns/op |
| EXP12（`current()` 泛型不匹配） | 抛异常 | 抛异常（**未变**，登记待拍板） |

复测命令与 §5 上文相同，只是 `setup.sh` 多一个可选参数：`bash setup.sh <worktree>/f_base`（不传则复制仓库主检出）。

**审查过程中踩到的两个工具坑（供后续复用探针时参考）**：

1. 独立探针工程用 `"fountain::f_base" = {path = "../f_base"}` 路径依赖会报 `imports package 'fountain.f_base' … not added as a dependency`（`f_exception` 等模块同样写法却正常，换成非点目录也一样），最终改为**把探针源码并进 f_base 副本的同一个包**；
2. 仓颉 lambda **只有尾随 lambda 能省 `=>`**，作为括号实参时必须写 `{ => expr }`（`f_base/src/FutureTask.cj` 里的 `spawn{ … }` 能省是因为它是尾随形式，写成 `FutureTask<Unit>({ … })` 会编译报 `expected '=>' in lambda expression`）。
