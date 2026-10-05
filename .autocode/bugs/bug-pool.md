# 代码审查报告：f_pool

- 审查分支：`review/f_pool`（基线 `7cd7863e`，即 `sts/1.3.x` 现值；worktree `.worktrees/review-f_pool`）
- 审查范围：`f_pool` 全模块 —— 25 个 `.cj`（约 3300 行），含 `src/`（`KeyPool`/`Pool`/`ArrayPool`/`ArrayListPool`/`BytesListOutputStream`/`BytesCopier`/`Ref`/`UnitKeyPool`/`BaseKeyPool`/`IKeyPool`/`Mode`/`PoolException`）、`src/base/`（`BasePool`、`collection` 的 `SyncDeque`/`LinkedNode`）、`src/diagnostics/`、7 个测试文件；逐文件通读
- 审查依据：`cangjie-code-review`（性能优化 / 内存优化两套清单）＋ 归档报告 `.autocode/bugs/bug-archived-on-20261004.md` 的 §6/§7（f_pool 历史问题逐条比对，凡已修/已拍板项不重复上报，见 §4）
- 复核口径：**§1 的 5 条全部在本机实测复现**（探针与数字见 §5）；§2 带 `文件:行号` 证据，其中 4 条也有实测；§3 为低危或读码推理项，未复现的一律标注并给出验证方法
- 基线状态：本 worktree 内 `cjpm build` **BUILD_EXIT=0**、`cjpm test` **TEST_EXIT=0**（f_pool 全量用例通过，与 README/归档记录的 29 条一致）
- 本次审查**只读**，未改动 `f_pool` 任何代码；探针工程在 `.autocode/tmp/pool_probe/`（工作区忽略区，不提交）

## 0. 摘要

| 严重度 | 条数 | 编号 |
|---|---|---|
| 严重 | 5 | `POOL-1` ~ `POOL-5` |
| 中 | 8 | `POOL-6` ~ `POOL-13` |
| 低危 / 待验证 | 9 | `POOL-L1` ~ `POOL-L9` |
| 合计 | 22 | — |

> 计数修正（2026-10-05）：§1.1 `POOL-1` 已修复 ⇒ 待修严重级 **4** 条（`POOL-2`~`POOL-5`）；上表保留审查当时的原始计数。
> 二次修正（2026-10-05）：§1.2 `POOL-2`、§1.5 `POOL-5`、§2.1 `POOL-6` 已修复（同一次提交）⇒ 待修严重级 **2** 条（`POOL-3`、`POOL-4`），中危 **7** 条。
> 三次修正（2026-10-05）：§1.3 `POOL-3` 已修复 ⇒ 待修严重级 **1** 条（`POOL-4`），中危 **7** 条。
> 四次修正（2026-10-05）：§1.4 `POOL-4` 判定为**误判**（设计目的，不修改）⇒ 待修严重级 **0** 条，中危 **7** 条；上表保留审查当时的原始计数。
> 五次修正（2026-10-05）：§2.2 `POOL-7` 已修复 ⇒ 待修中危 **6** 条（`POOL-8`~`POOL-13`）。

**建议修复顺序**：

1. `POOL-1`（§1.1）借出中的池项被 GC 终结器销毁 → 池的「借出期所有权」契约不成立（实测借出对象被打上已销毁标记）　**✅已修复（2026-10-05，见 §1.1 修复标记）**
2. `POOL-2`（§1.2）`KeyPool.get` 有限超时分支在池耗尽时**无让步忙等** → 编码热路径（`DefaultCodec` 的 `build(timeout: 5s)`）整核空转（实测 2s 等待烧 2.25s 用户态 CPU）　**✅已修复（2026-10-05，见 §1.2 修复标记：等待改条件变量通知）**
3. `POOL-3`（§1.3）巡检把**满载 key** 的空闲项当「校验不过」摘掉，并整轮跳过用户 checker → 稳态抖动、`connectionLife`/`idleTimeout` 判定被绕过（实测满载空闲池 idle 2→1）　**✅已修复（2026-10-05，见 §1.3 修复标记：size&lt;max 只约束补建）**
4. `POOL-4`（§1.4）creator/checker 持续失败时**无退避紧重试** → 对下游的重连风暴 + 每轮一条 WARN（实测 300ms 内 75,976 次尝试）　**❌误判（2026-10-05：设计目的，不修改；见 §1.4 误判标记）**
5. `POOL-5`（§1.5）`maxWaiting = Duration.Max` 的「真无限等待」实际只等 1s 就**静默放弃**（实测 1008ms 返回 `None`，对照 30s 档 2016ms 返回项）；同一分支还会吞掉丢失的唤醒　**✅已修复（2026-10-05，随 §1.2 的统一等待重写一并解决，见 §1.5 修复标记）**
6. 其后按 §2 顺序：`POOL-6`（关停不唤醒/归还竞态）**✅已修复（2026-10-05，见 §2.1 修复标记）** → `POOL-7`（关池泄漏线程）**✅已修复（2026-10-05，见 §2.2 修复标记：线程句柄 + cancel + 每轮判状态 + 带超时出队）** → `POOL-8`（队列按 `totalSize` 预分配 + 两个池默认 `maxSize=Int64.Max` 构造即 OOM）→ `POOL-9`（`release` 后仍可写，实测污染池项）→ `POOL-10`~`POOL-13`

---

## 1. 严重（5 条）

### 1.1 [严重｜正确性] `POOL-1` 借出中的池项会被 `Ref` 终结器销毁（显式销毁路径还会被销毁第二次）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_pool`（worktree `.worktrees/review-f_pool`，基线 `5b76b7a2`，已合入 `sts/1.3.x`；worktree 注册目录曾被并行会话的 WSL `git worktree prune` 删掉，已按 `.git/worktrees/review-f_pool/{gitdir,commondir,HEAD}` + `read-tree` 重建，未丢改动），代码、用例、本标记在**同一提交**（提交 `411714dc`，提交信息 `fix(f_pool): POOL-1 借出/显式销毁改用 Ref.take()，终结器不得提前或重复销毁池项`）。

- 改动（给 `Ref` 加「取走并置空」，所有「值离开 `Ref` 保护」的路径都改走它）：
  1. `f_pool/src/Ref.cj:37-47`：新增 `take(): ?T`（返回值并把 `value` 置 `None`）；
  2. 三处借出 `f_pool/src/KeyPool.cj:464 / 474 / 491`：`r.get()` → `r.take()`；
  3. `f_pool/src/KeyPool.cj:424`（`keyedDestroy`：借出/归还校验不过而销毁）→ `ref.take()`；
  4. `f_pool/src/KeyPool.cj:326`（巡检判失效后销毁）、`:409`（`close()` 清池）→ `r.take()`。
  只读用途（`keyedCheck`、巡检里 `valid = … r.get()`）保持不变。
- 用例：`f_pool/src/KeyPool_test.cj` → `KeyPoolTest.borrowedItemMustNotBeDestroyedByFinalizer`（借出后强制 `gc()`×2：销毁计数必须为 0、归还后仍能借出；`close()` 显式销毁一次后再 `gc()`×2：计数不得变 2）。
- 测量证据：
  - **修前**：该用例 `[ FAILED ]`（`Assert Failed: (destroyed.load() == 0)  left: 1  right: 0`，`TEST_EXIT=1`）—— 借出期间被终结器销毁；
  - **修后**：单用例 `PASSED: 1, FAILED: 0`（`FILTERED_EXIT=0`）；`f_pool` 全量 `cjpm test` = **`PASSED: 38, SKIPPED: 0, ERROR: 0, FAILED: 0`**（`FULL_EXIT=0`，日志 `.autocode/tmp/pool_fix_{pre,post}.log`）；
  - 探针复测（`.autocode/tmp/pool_probe_fixed`，path 依赖指向本 worktree 的 `f_pool`）：`finalizer: destroyed_before_gc=0 after_gc=0 borrowed_is_destroyed=false`（修前 `after_gc=1`、`true`）、`double_destroy: after_close=1 after_gc=1`（修前 `after_gc=2`）。
- 未覆盖：公开 API 未变（仍 `get(): ?V`），但**「借出后漏归还」的兜底弱化**：`take()` 之后该项的 `Ref` 已空，终结器不再为「借出未还」补销毁 —— 原来那个兜底正是提前销毁的来源；若要真兜底需让 `get` 返回句柄（`Ref<V>`），属破坏性 API 变更，不在本条。

**现象**：`KeyPool.get` 借出时返回的是**解包后的 `V`**，包着它的 `Ref<V>` 在函数返回后立即不可达；`Ref` 的终结器 `~init()` 正是「谁值还在就销毁谁」——于是**借用方还在用这个对象时，下一次 GC 就会调 `destroier` 把它销毁掉**。

**证据**：

```24:34:f_pool/src/Ref.cj
    ~init(){
        if(let Some(v) <- value){
            try{
                destroy(v)
            }catch(e: Exception){
                logger.warn('Error on destroying', e)
            }finally{
                value = None
            }
        }
    }
```

借出点只有三处（`453:459` 非阻塞、`469` `Duration.Max`、`486` 有限超时），三处都是 `let Some(r) <- pool.get(...) && let Some(v) <- r.get()`：`r` 是 `Ref<V>`，出了这个表达式就没人再引用它（`SyncDeque.remove` → `ValueNode.nextForGet()` 返回 `x.value` 后节点已 `doRemove()` 摘链，队列不再引用该 `Ref`）。归还时 `KeyPool.giveBack` **另建一个新的 `Ref`**（`397:397-399`），所以借出期的那个 `Ref` 永远回不到池里。

**实测（`main finalizer`）**：`Pool<Holder>(initSize:1, maxSize:1)` 借出一件后 `gc()`：

```
finalizer: destroyed_before_gc=0 after_gc=1 borrowed_is_destroyed=true
```

两次运行结果一致。`Holder` 的 `destroy` 只是把自身 `destroyed` 置真；对**任何** `destroy` 不幂等/不自守卫的池项（连接、句柄、缓冲区），这就是「借出对象在借用方手里被销毁」。

**同一根因的第二个面（`main double_destroy`）**：显式销毁后 `Ref.value` 仍是 `Some`，终结器会再销毁一次 —— `close()` 清池、`SyncDeque.discardItem` 销毁、`BaseKeyPool.destroy` 都走这条路：

```
double_destroy: after_close=1 after_gc=2
```

**影响面（诚实说明）**：当前仓库里唯一带真实 `destroier` 的调用方是 `f_orm` 连接池，其 `PooledConnection.destroy()` 用 `assigned` 自救（`f_orm/src/wrap/DatabasePool.cj:229-240`，借出中拒绝关闭）⇒ 侥幸不出事；`ArrayPool`/`ArrayListPool` 的 `destroier` 是空实现 ⇒ 看不出症状。也就是说：**这是靠调用方各自自救兜住的设计缺口**，池自身的「借出期不销毁」契约并不成立。

**建议修法（二选一，都不破坏公开 API）**：

1. 让 `Ref` 只对「还在池里」的项负责：`KeyPool.get` 拿到 `r` 后先 `r.take()`（新增，取出值并把 `value` 置 `None`）再返回 `v` —— 借出期终结器就是空转，显式销毁路径也不会二次销毁；
2. 或者去掉 `Ref` 的终结器，改为「归还时才建 `Ref`」＋借出计数超时告警（丢掉「借漏兜底」，但语义最干净）。

修法 1 需要同时改 `keyedDestroy`/`checkingLoop` 里对 `r.get()` 的用法（当前 `r.get()` 是「读」而非「取走」，正好配合 `take()` 无冲突）。

### 1.2 [严重｜性能+可用性] `POOL-2` `KeyPool.get` 的「有限超时」分支在池耗尽时无让步忙等 ✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：与 `POOL-6`（§2.1）、`POOL-5`（§1.5）**同一次提交**（提交 `315ada9e`，提交信息 `fix(f_pool): POOL-2/POOL-6/POOL-5 池等待改条件变量通知（去掉 1ms 轮询与忙等）`），分支 `review/f_pool`。

- 改动（等待从「轮询/自旋」改成「条件变量通知」）：
  1. `f_pool/src/KeyPool.cj:174-186`：新增等待设施 —— `waitMutex` / `waitCond` / `available`（「池状态可能变好」的纪元号）/ `waiters`（无人等待时空通知的短路计数）；
  2. `KeyPool.cj:466-500` 新增 `waitItem(remain)`：在条件变量上 park（真无限档 `wait()`，有限档 `wait(timeout: remain)`）；登记 `waiters` 后**持锁复检纪元**，关掉「通知早于 park」的丢唤醒窗口；
  3. `KeyPool.cj:501-547` `get`：两条等待路径合并为「取项 → 需要就入队建项 → 算剩余预算 → park」，**删除 `sleep(1ms)` 与自旋**（有限档与 `Duration.Max` 档共用）；
  4. `wakeWaiters()`（`:367-374`）四处调用：创建线程处理完一条任务（`:419`）、`close()`（`:431`）、归还（`:558`）、巡检每轮（`:360`，腾出额度时）；
  5. 旧机制删除：`waitChunk`、每等待者一个的 `PoolTask` 类（`tasks` 元素类型改为 `K`）。
- 用例：`f_pool/src/KeyPool_test.cj` → `KeyPoolTest.finiteTimeoutWaitMustNotBurnCpu`（池借空后 `get(timeout: 300ms)` 期间进程 CPU 增量必须 < 10 tick；`/proc/self/stat` 的 utime+stime，1 tick ≈ 10ms；非 Linux 拿不到该文件则只验语义）。
- 测量证据：
  - **修前**：`[ FAILED ] Assert Failed: (a - b < 10)`（≈30 tick 的忙等；探针 `spin_finite` 里 2s 等待烧 user 2.25s）；
  - **修后**：`[ PASSED ]`（`FILTERED_EXIT=0`）；`f_pool` 全量 **`PASSED: 42, SKIPPED: 0, ERROR: 0, FAILED: 0`**（`FULL_EXIT=0`，日志 `.autocode/tmp/pool_fix2_{pre,post}.log`）。
- 未覆盖：`PoolTask` 的去留顺带把「每次取项都新建一个等待者对象」也去掉了（原来是每等待者一个 `PoolTask` + 一个 `Mutex`+`Condition`）；`tasks` 队列容量仍是 `totalSize`（`POOL-8` §2.3 未动，仍待修）。

**现象**：`timeout == Duration.Max` 分支每轮 `sleep(1ms)`（注释里专门写了「不是忙等」），但**有限超时分支没有任何 `sleep`/让出**：一旦 `pool.size >= totalSize` 或 `keyedSize(key) >= maxSize`，`else if` 的整个链短路，循环变成「查一次池 → 立刻再查一次池」的热自旋，直到超时。

```483:494:f_pool/src/KeyPool.cj
        }else{
            let start = MonoTime.now()
            while(running.load() && MonoTime.now() < start + timeout) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()) {
                    return v
                }else if (pool.size < totalSize && pool.keyedSize(key) < maxSize && 
                    let Some(x) <- tryAddTask(key) && 
                    let wait <- start + timeout - MonoTime.now() && (wait <= Duration.Zero || !x.wait(wait))) {
                    break
                }
            }
        }
```

`pool.get` 失败时先判 `pool.size < totalSize`：池满（`totalSize` 计的是「空闲+借出」）就会短路 ⇒ 不建任务、不等待、不留步。

**热路径**：`f_codec/src/default/DefaultCodec.cj:115-119` 每次编码取缓冲都用**有限超时** `byteListOutputBuilder.build(timeout: Duration.second * 5)`；即编码池（`initSize=minSize=maxSize=1024`）被借空时，每个等待的编码线程都会烧满一个核、最长 5s（并发 N 个线程就是 N 个核）。这与归档报告 §6.3 修掉的那个忙等是同类，只是那条只修了 `Duration.Max` 分支。

**实测**：

| 探针 | 场景 | wall | user CPU |
|---|---|---|---|
| `main spin_finite` | maxSize=1 借空后 `get(timeout: 2s)` | 2000ms | **2.25s** |
| `main spin_max` | 同一场景改用 `get()`（`Duration.Max` 分支） | 2002ms | 0.11s |

（`real 4.30s / 4.84s` 里另有约 2.3s 是进程启动装载依赖库的开销，`user` 差值是关键证据。）

**建议修法**：有限分支与 `Duration.Max` 分支共用「等待步」——最省事的是把 `sleep(Duration.millisecond)` 也放到有限分支的循环末尾（等待语义不变，最坏多睡 1ms）；更好的做法是：池满时改为「按剩余预算等一次 `PoolTask`」，或直接复用一段公共等待实现。

### 1.3 [严重｜正确性+资源抖动] `POOL-3` 巡检把「满载 key」的空闲项当「校验不过」摘掉，并整轮跳过用户 checker ✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_pool`，代码、用例、本标记在**同一提交**（提交 `a1f5decc`，提交信息 `fix(f_pool): POOL-3 巡检的 size<max 只约束补建，checker 照常执行`）。

- 改动（把 `p.size < max` 从 checker 挪到「补建」上）：
  1. `f_pool/src/BaseKeyPool.cj:55-61`：`{v => p.size < max && checker(k, v)}` → `{v => checker(k, v)}`，守卫移到 taskPusher：`{if (p.size < max) { taskPusher(k) }}`（注释里写明「checker 返回 false = 摘节点」这一语义）；
  2. `f_pool/src/UnitKeyPool.cj:41-44`：同样处理 → `{v => checker(eternity, v)}` + `{if (size < max) { taskPusher(eternity) }}`。
- 用例：`f_pool/src/KeyPool_test.cj` → `checkMustNotDropIdleItemWhenAtCap`（满载 + `checkInterval=50ms` 跑 ~10 轮巡检：可借数仍为 2、creator 仍只调用 2 次、destroyed 仍为 0）、`checkerMustRunWhenAtCap`（满载且 checker 恒判失效：checker 调用数 > 0 且该项被销毁）。
- 测量证据：
  - **修前**：两条都 `[ FAILED ]`（`Assert Failed: (held.size == 2)`、`(calls.load() > 0)`；与探针 `churn` 的 `created 2->2 / destroyed 0->0 / idle 2→1` 一致）；
  - **修后**：两条 `[ PASSED ]`（`FILTERED_EXIT=0`）；全量 **`PASSED: 44, SKIPPED: 0, ERROR: 0, FAILED: 0`**（`FULL_EXIT=0`，日志 `.autocode/tmp/pool_fix3_{pre,post}.log`）。
- 未覆盖：`p.size < max` 这个补建守卫在「刚摘完节点」的调用序下几乎恒真（`SyncDeque.check` 只在摘节点之后才调 taskPusher），保留它只为保住原意、不改变行为；`minSize` 补足路径（`checkingLoop`）不受影响。

**现象**：`BaseKeyPool.check` 把「池满就不再校验」写成了 checker 的**与条件**：

```55:58:f_pool/src/BaseKeyPool.cj
    public func check(running: () -> Bool, checker: (K, V) -> Bool, taskPusher: (K) -> Unit): Unit {
        for ((k, p) in map){
            p.check(running, {v => p.size < max && checker(k, v)}){taskPusher(k)} |>
            s.fetchSub
```

而 `SyncDeque.check` 的语义是「checker 返回 **false = 这项失效 ⇒ 摘节点**」：

```291:293:f_pool/src/base/collection/SyncDeque.cj
                if(!n.check(checker, onRemoved: {=> s.fetchSub(1)})){
                    taskPusher()
                    rm++
```

于是只要 `p.size >= max`（**满载是池的正常稳态**：`initSize == maxSize` 或跑热之后），该轮巡检对每个满载 key 都会：① **完全跳过用户 checker**（`isIdleTimeout()`、`DatabasePool` 的 `connectionLife` 判定都不会执行）；② 把**尾部的空闲项**当作失效摘掉；③ 推一个补建任务（补建能否落地取决于与 `s.fetchSub` 的竞态，见下）。`UnitKeyPool` 同样（`f_pool/src/UnitKeyPool.cj:41-43`）。

**实测（`main churn`）**：`KeyPool<String, Holder>(initKeys=2, maxSize=2, totalSize=2, checkInterval=50ms, idleTimeout=1h)`，创建完成后空闲 400ms 再观察 500ms（约 10 轮巡检）：

```
churn: created=2->2 destroyed=0->0 idle_now=1
```

即：满载（2 件全空闲）的池在巡检中**静默掉了一件**（`idle` 2→1），既没有走 `destroier`（`destroyed` 仍为 0 —— 这一项是被摘链后交给 GC 终结器兜底，见 `POOL-1`），也没有补建回来（`created` 仍为 2）；原因是 `taskPusher()` 在 `SyncDeque.check` 里先于 `|> s.fetchSub` 执行，创建线程若在外层 `s` 减 1 之前处理该任务，会看到 `keyedSize == maxSize` 而直接丢弃任务。若创建线程恰好晚一点读到，则会「掉一件再补一件」⇒ 稳态抖动（对 DB 连接池就是每次巡检断开一条再连一条）。

**影响**：`idleTimeout` / `connectionLife` 这类「按时间判失效」的语义在**满载时被整体绕过**，同时池项数量无谓抖动；`checkInterval=50ms` 的配置（`KeyPool_test.auditRunsFromSchedule` 就是）抖动频率就是巡检频率。

**建议修法**：`p.size < max` 是对 `taskPusher`（补建）的约束，不是对 checker 的约束 ——

- 若要「池满时不做校验」：必须返回 **true**（保持不动），即 `{v => p.size >= max || checker(k, v)}`；
- 若要「池满时不补建」：把守卫挪到 `taskPusher` 上（`{k => if (p.size < max) tryAddTask(k)}`），checker 照常执行。

推荐后者（保持 `idleTimeout`/`connectionLife` 始终生效，补建交给 `minSize` 与按需路径）。

### 1.4 [严重｜可用性+下游冲击] `POOL-4` creator/checker 持续失败时无退避紧重试（重连风暴 + 日志洪水）✓已复核 → ❌误判（2026-10-05：设计目的，非缺陷）

**❌ 误判标记（2026-10-05）**：**判定为误判，不修改**。用户口径：creator / checker 失败时**就该继续重试**（不在池里做退避节流）—— 这是设计行为；池不替调用方决定「下游不可用时要不要等」，等待与放弃由调用方的 `timeout` / 池参数 `maxWaiting` 表达。

- 现象与读数保留为**该设计的已知代价**（下游长时间不可用时会满速重试、每轮一条 WARN）：`main createflood` 300ms 内 **75,976** 次 creator 尝试。
- 下面的「建议修法」（10ms 起翻倍、1s 封顶 + 翻倍点告警）**不再执行**，仅作记录；若将来部署侧要求削峰可直接照做。

**现象**：`creationLoop` 的内层 `while` 是「失败就重试」的紧循环，唯一节流是 `sleep(Duration.Zero)`；`creator` 抛异常（下游不可用）或 `checkOnCreation=true` 且 checker 恒 false（新建的连接不可用）时，会以最大速度反复建/毁，并在每轮打一条 WARN：

```376:396:f_pool/src/KeyPool.cj
    private func creationLoop(): Unit {
        while(running.load() && let task <- tasks.remove()){
            while(running.load() && pool.size < totalSize && let k <- task.key && pool.keyedSize(k) < maxSize){
                try {
                    let object = creator(k)
                    if (checkOnCreation && !doCheck(k, object, checker)){
                        doDestroy(k, object, destroier)
                    } else {
                        pool.add(k, ref(k, object))
                        break
                    }
                }catch(e: Exception){
                    PoolDiagnostics.onCallbackError()
                    logger.warn('error on creating', e)
                }
                sleep(Duration.Zero)
                continue
            }
            task.notify()
        }
    }
```

**实测（`main createflood`）**：`creator` 恒抛 `Exception`，从建池起 300ms 内：

```
createflood: creator_attempts_in_300ms=75976
```

≈ **25 万次/秒**，每次都会 `PoolDiagnostics.onCallbackError()` + `logger.warn('error on creating', e)`（应用里 logger 已初始化时即「每次一条 WARN + 异常栈」；探针未初始化 logger，所以消息没落到我抓取的输出里）。对应到 `f_orm` 连接池：数据库宕机期间 = 每秒 25 万次 `ds.connect()` 尝试 + 同等量日志。

**建议修法**：失败重试加**指数退避 + 上限**（如 10ms → 20ms → … → 1s，成功即复位），并把「连续失败 N 次」升级为一条错误统计而不是每轮一条 WARN；`checkOnCreation` 判不过时同样适用（现在也是零延迟重建）。

### 1.5 [严重｜可用性+语义] `POOL-5` `maxWaiting = Duration.Max` 的「真无限等待」实际只等 1s 就静默放弃 ✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：**随 `POOL-2`/`POOL-6` 的统一等待重写一并解决**（同一提交；分支 `review/f_pool`）—— 「分片超时当截止」的那段（旧 `waitChunk` 给 1s 分片 + `!x.wait(remain)` → `break`）在重写中整体删除：真无限档现在直接 `waitCond.wait()`（**无超时**），只等「创建完成 / 归还 / 关停」的通知；有限档的截止只由「剩余预算 ≤ 0」判定。

- 用例：`f_pool/src/KeyPool_test.cj` → `KeyPoolTest.infiniteWaitMustWaitForSlowCreation`（creator 睡 2s、`maxWaiting = Duration.Max`：必须 `Some` 且耗时 ≥ 1.8s）。
- 测量证据：**修前** `[ FAILED ] Assert Failed: (got.isSome())`（1008ms 就返回 `None`，与探针 `slowcreate` 的 1008ms 一致）→ **修后** `[ PASSED ]`（`PASSED: 42` 全量全绿）。
- 备注：**这条不在你这次的点名范围内**，但它的根因正落在被重写的那段等待逻辑上（要保留旧行为得刻意写回 `break`）；如果希望它单独走一个条目/提交，可以把这块拆出来。

**现象**：README（`:240-241`）与归档 §7.6 的口径是「`maxWaiting` 传 `Duration.Max` = **真无限等待**；实现按固定分片等待，既避免 `MonoTime + Duration.Max` 溢出，**也保证能及时看见 `running` 变化**」。但实现把「分片超时」当成了「截止」：`waitChunk` 每片返回 1s，`x.wait(1s)` 一旦超时就让 `else if` 为真 ⇒ `break` ⇒ 返回 `None`，而且这条路径**不打 WARN**（WARN 只在 `maxWaiting != Duration.Max` 的检查里）。

```443:453:f_pool/src/KeyPool.cj
    private func waitChunk(waitStart: MonoTime): Duration {
        if (maxWaiting == Duration.Max) {
            return Duration.second
        }
        let remain = waitStart + maxWaiting - MonoTime.now()
        ...
    }
```

```468:481:f_pool/src/KeyPool.cj
            while(running.load()) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()) {
                    return v
                }else if (pool.size < totalSize && pool.keyedSize(key) < maxSize && 
                    let Some(x) <- tryAddTask(key) && 
                    let remain <- waitChunk(waitStart) && (remain <= Duration.Zero || !x.wait(remain))) {
                    break
                }
                if (maxWaiting != Duration.Max && MonoTime.now() - waitStart >= maxWaiting) { ... }
                sleep(Duration.millisecond)
            }
```

**实测（`main slowcreate`，creator 睡 2s 再返回对象）**：

```
slowcreate(maxWaiting=Duration.Max): got_some=false elapsed_ms=1008
slowcreate(maxWaiting=30s):          got_some=true  elapsed_ms=2016
```

无限等待档**在 1008ms 就放弃了**（创建任务还需要 1s 才完成），返回 `None` 且无任何告警；30s 档则正常等到并拿到项。任何「慢建连/慢打开」的池配上无限等待都会周期性假失败。

**同一分支的第二个面（未复现）**：`tryAddTask` 与 `x.wait(remain)` 之间若创建线程已完成 `task.notify()`，这次唤醒会**丢失**（`PoolTask` 没有 `notified` 状态）⇒ 等待者只能等到 `remain` 到期，然后同样走 `break` 返回 `None`（有限档则是「预算耗尽 + 静默丢唤醒」，最坏 30s 空等）。定向探针 `main lostwakeup` / `main lostwakeup_load`（100 次 × 2，负载版另加 30 个 CPU 线程压制）**未复现**（`none=0/100`、`max_ms=1050`），窗口在微秒级，但同一个 `break` 语义让它和上面的分片超时叠加在一起。

**建议修法**：分片超时**不是**截止 —— `x.wait` 返回 false 时不要 `break`，而是回到循环顶部（重查池 + 重判 `running`/`maxWaiting` 预算），让 `maxWaiting` 的预算检查（有限档）和 `running`（关停）决定何时退出；顺带给 `PoolTask` 加 `notified` 标志（`notify` 置位、`wait` 前先查，置位则直接返回「已被通知」），把丢唤醒窗口也关掉。

---

## 2. 中（8 条）

### 2.1 [中｜可用性+资源] `POOL-6` `close()` 不唤醒等待者；`giveBack` 与 `close` 的检查-使用竞态会让池项永久滞留 ✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：与 `POOL-2`（§1.2）、`POOL-5`（§1.5）**同一次提交**（提交 `315ada9e`；分支 `review/f_pool`）。

- 改动：
  1. **关停唤醒**：`close()` 置 `running=false` 后立刻 `wakeWaiters()`（`f_pool/src/KeyPool.cj:428-431`）⇒ 等待者当场复查到 `running=false` 返回 `None`，不再 park 到预算/分片到期；
  2. **归还竞态**：`giveBack` 入池后**复检 `running`**，若与 `close` 交错落败，把刚入池的那一项取出来销毁（`KeyPool.cj:549-556`），不让它留在一个已关闭的池里（原来会永久滞留：没人取、没人销毁，且池对象还被 `atExit` 回调长期持有，见 `POOL-13`）；
  3. 等待侧本身从轮询改成通知（同 `POOL-2`）—— 这条也把「等待者靠 1ms 轮询顺带发现 `running=false`」的隐式依赖去掉了。
- 用例：`f_pool/src/KeyPool_test.cj` → `closeMustWakeWaitingGetter`（`maxWaiting = Duration.Max` + 池借空，`close()` 后等待者在 700ms 内返回 `None`）、`giveBackRacingCloseMustNotStrandItem`（100 轮「归还 ‖ 关池」，每轮恰好销毁 1 次）。
- 测量证据：
  - **修前**：`giveBackRacingCloseMustNotStrandItem` **`[ FAILED ]`**（`Assert Failed: (destroyed.load() == i + 1)` —— 100 轮里竞态确实命中，有项没被销毁）；`closeMustWakeWaitingGetter` 修前**也通过**（修前等待者靠 1ms 轮询看到 `running`，延迟 ~1ms）⇒ 它的作用是**重写后的不变量守卫**（若通知漏了 `close` 这条就会挂住），不是失败复现；
  - **修后**：两条都 `[ PASSED ]`，全量 `PASSED: 42, SKIPPED: 0, ERROR: 0, FAILED: 0`。
- 未覆盖：`POOL-7`（`close()` 后**创建线程**仍可能永久阻塞在 `tasks.remove()`，与等待者无关）未动，仍待修。

- **关停延迟**：`close()`（`f_pool/src/KeyPool.cj:403-412`）只置 `running=false` + 排空任务队列 + `pool.destroy`，**不通知**正阻塞在 `PoolTask.condition` 上的等待者。等待者是按 `waitChunk` 给的预算 park 的（默认 `maxWaiting=30s`，即最长 30s）⇒ `get()` 可能在 `close()` 之后最长 30s 才返回。巡检线程同理（`sleep(checkInterval)` 在 `running` 复检之前，最坏睡到 `checkInterval`）。
- **归还竞态**：`giveBack` 先查 `running` 再入池（`497:498-507`），两步之间 `close()` 若已完成 destroy，这一项就会被加进**已关闭**的池的队列：既不会被销毁（没有 drain 了），也不会有人取走 —— 而池对象被 `atExit` 回调长期持有（见 `POOL-13`），于是这一项连同其资源**永久泄漏**。

**修法**：`close()` 在置位后 `notifyAll` 所有在等的 `PoolTask`（或用「关闭哨兵」唤醒创建线程）；`giveBack` 入池后补一次 `running` 复检，已关闭就把刚入池的项取出销毁。

### 2.2 [中｜资源泄漏] `POOL-7` `close()` 之后创建线程可能永久阻塞在 `tasks.remove()` ✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_pool`，代码、用例、本标记在**同一提交**（提交 `36615817`，提交信息 `fix(f_pool): POOL-7 内部线程句柄 + close 发取消 + 每轮判 hasPendingCancellation + 带超时出队`）。

- 改动（按指定方案：**保留线程句柄 → 关闭时发取消 → 线程每轮判状态 → 出队带超时**）：
  1. `f_pool/src/KeyPool.cj:183-184`：新增成员 `creationThread` / `checkingThread: ?Future<Unit>`（两个内部维护线程的句柄）；
  2. `close()`（`:453-462`）：`running=false` 之后对两个句柄调 `cancel()`（协作式取消请求：`Future.cancel()` 只发请求、不强制停线程）；
  3. `startCreationSchedule`（`:395`）/ `startCheckingSchedule`（`:315`）：把 `spawn` 的返回值存进成员；看护循环每轮判 `!Thread.currentThread.hasPendingCancellation && running.load()`（`:320`、`:400`），并把「取消/关停导致的异常」静默 `break`（不再记 WARN + 重开）；
  4. `creationLoop`（`:418-442`）：外层 `while(!hasPendingCancellation && running)`，出队用**带超时**的 `tasks.remove(Duration.second)`（`:425`）——超时拿到的 `None` 只表示「这一秒没任务」，回到循环顶再判一次取消/关停，**不算意外退出**（否则看护循环会每秒打一条「意外退出」WARN）；出队超时带 1s，`close()` 之后线程最迟 1s 内退出；
  5. `checkingLoop`（`:338-339`）：同样每轮判取消状态。
  说明：`ArrayBlockingQueue` 只有 `tryRemove()`（非阻塞）与 `remove(timeout: Duration)`（带超时、**位置参数**）两个重载，没有 `tryRemove(Duration)` —— 所以写的是 `tasks.remove(Duration.second)`。
- 用例：`f_pool/src/KeyPool_test.cj` → `KeyPoolTest.closeMustReclaimInternalThread`（建/关 20 个 `checkInterval = Duration.Zero` 的池 ⇒ 每池只有创建线程；关池后等 1.6s，线程数必须回到基线 +5 以内）。
- 测量证据：
  - **修前**：`[ FAILED ] Assert Failed: (after <= before + 5)`（线程 7→27、关池后仍 27；探针 `main threads` 同读数 `7->27->27`、`blocking 6->26->26`）；
  - **修后**：`[ PASSED ]`（`FILTERED_EXIT=0`）；全量 **`PASSED: 45, SKIPPED: 0, ERROR: 0, FAILED: 0`**（`FULL_EXIT=0`，日志 `.autocode/tmp/pool_fix7_{pre,post}.log`）。
- 未覆盖：`checkingLoop` 的 `sleep(checkInterval)` 本身不可取消 ⇒ `checkInterval` 很大（或 `Duration.Max`）时巡检线程仍要睡到点才醒；「每轮判状态」对它是同一套机制，但要真生效得把睡眠改成分片（`POOL-L2` §3，未修）。`tasks` 容量 = `totalSize` 的预分配问题（`POOL-8` §2.3）也未动。

**原分析（保留）**：`while(running.load() && let task <- tasks.remove())` 的 `running` 检查在**阻塞出队之前**：线程一旦 park 在空队列的 `remove()` 上，`close()` 的 `tryRemove` 排空与 `running=false` 都**不会唤醒**它（`ArrayBlockingQueue` 只提供阻塞出队/超时出队，没有 close/中断）。

**实测（`main threads`）**：连续建/关 20 个池（`checkInterval=Duration.Zero`，每池只有创建线程），关池后 500ms：

```
threads: threads 7->27->27, blocking 6->26->26
```

20 个池 = +20 线程、+20 个阻塞线程，关池后**一个都没回收**。按租户/请求动态建池的场景会线性泄漏线程（并因此长期持有 `KeyPool` 及池内对象）。

**修法**：用「入队元素即关闭哨兵」或 `remove(timeout:)` 轮询（如 500ms）替代无超时阻塞出队。

### 2.3 [中｜内存+API 契约] `POOL-8` `tasks` 队列按 `totalSize` 预分配；`ArrayPool`/`ArrayListPool` 的默认 `maxSize = Int64.Max` 直接构造失败

```209:209:f_pool/src/KeyPool.cj
        tasks = ArrayBlockingQueue<PoolTask<K>>(totalSize)
```

`std.collection.concurrent.ArrayBlockingQueue` 的 `init(capacity)` 会**立即** `Array(capacity, repeat: ...)` 并按容量 malloc 状态数组（`cangjie_runtime/std/libs/std/collection/concurrent/array_blocking_queue.cj:68-78`）—— 队列容量直接等于池容量。

**实测**：

- `main arraypool_default`：`ArrayPool<Int64>()`（README 记录的默认 `maxSize = Int64.Max`，`f_pool/src/ArrayPool.cj:25`）⇒ `An exception has occurred: Out of memory`、进程 **exit 1**（`try/catch` 都兜不住）。`ArrayListPool<T>` 同默认值（`f_pool/src/ArrayListPool.cj:25`）、`Pool<V>` 把 `totalSize` 直接取 `maxSize`（`f_pool/src/pool.cj:167`）⇒ 同一条路。
- `main queue_alloc`：`Pool<Object>(maxSize: 5_000_000)` 构造前后 `getAllocatedHeapSize()` **+80,004,832 B**（≈16 B/槽）——纯粹为任务队列白付的内存。

**修法**：任务队列容量与池容量解耦（固定小容量如 1024，或换成 `ArrayDeque` + 条件变量）；`ArrayPool`/`ArrayListPool` 的默认 `maxSize` 换成一个真实可用的上界（如 `10`/`1024`），或把 `Int64.Max` 当作「不限制」在构造队列时降级。

### 2.4 [中｜正确性] `POOL-9` `BytesListOutputStream.release()` 之后仍可写：下一个借用者拿到脏缓冲

`released` 只在 `release()` 里用（幂等保护），`write` / `asBytes` / `copy` **都不检查**：

```24:26:f_pool/src/BytesListOutputStream.cj
    public func write(bytes: Array<Byte>): Unit {
        list.add(bytes)
    }
```

**实测（`main useafterrelease`）**：`builder(clearOnReturning:false, maxSize:1)`：借出→写 3 字节→`release()`→再写 2 字节→再借出：

```
useafterrelease: second_is_empty=false second_bytes=5
```

下一个借用者拿到 5 字节脏内容。`clearOnReturning=true`（`BytesListOutputStream.builder` 的默认）只能清掉「归还那一刻」的内容，挡不住归还之后的写入；真实后果就是归档报告 §六那类「编码结果里混进上一条消息的字节」。`DefaultCodec.lastBuffer()` 的 `!buf.isEmpty` 守卫会把它变成 `CodecException`（可见失败，但仍是错误）。

**修法**：`write`/`asBytes` 首行 `if (released) { throw IllegalStateException('released') }`；`copy` 自带 `release`，可在 released 时直接返回或抛。

### 2.5 [中｜资源泄漏] `POOL-10` `BaseKeyPool.giveBack` 对「键对应的池不存在」静默丢弃对象

```34:36:f_pool/src/BaseKeyPool.cj
    public func giveBack(key: K, value: V, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): Unit {
        map.get(key)?.giveBack(value, keyedChecker(key, checker), keyedDestroier(key, destroier))
    }
```

`get` 会按需建池（`keyedPool`，`100-110`），`giveBack` 不会：键上没有池时 `?.` 静默跳过 —— 对象**既不归还也不销毁**，调用方（`KeyPool.giveBack`）返回 `Unit` 无任何反馈。典型触发：把 A 键借出的对象还到 B 键、或关闭后清理路径上按旧键归还。

**修法**：`giveBack` 未命中池时按 `!running` 分支处理（直接 `destroier(key, value)`），或至少 `PoolDiagnostics` 记一条告警。

### 2.6 [中｜内存] `POOL-11` key 表只增不减，巡检每轮 O(#keys)

`BaseKeyPool.map`（`24:24`）没有任何 key 淘汰/移除入口（`destroy` 只清空各池的项，**不删 map 项**，`88-94`），`audit()`/`check()` 每轮都 `for(( _, p) in map)`（`70-87`、`55-64`）。按高基数键（用户/会话/文件）建池时：空池条目、队列对象、以及巡检的 O(#keys) 遍历都是永久成本。

**修法**：提供 `removeKey`/`evictEmptyKeys`（空闲且 `size == 0` 的 key 在巡检里回收），或在文档里明确「key 基数必须有界」。

### 2.7 [中｜正确性] `POOL-12` 归还路径上 `clear` 抛异常会丢池项

`KeyPool.giveBack` 的 `clear(key, object)` 没有 try（`504-506`），异常直接抛给调用方，而对象既不在池里也没被销毁 ⇒ 池项凭空消失（与 `checker`/`destroier` 都有 `doCheck`/`doDestroy` 包裹的处理不一致）。`ArrayPool` 的 `clear` 会写整个数组、`ArrayListPool`/`BytesListOutputStream` 走 `list.clear()`，正常不抛；但这是公开可注入的回调，契约上不该由它决定池项生死。

**修法**：`clear` 包 try（失败记 `PoolDiagnostics.onCallbackError()`，仍把池项放回），或按 `POOL-1` 的建议改为「返回前 `take()`」。

### 2.8 [中｜内存] `POOL-13` `ExitCallbacks.atExit(254, close)` 每次建池一条且不可注销

`KeyPool` 构造末尾注册 `ExitCallbacks.atExit(254, close)`（`226:226`），而 `ExitCallbacks`（`f_base/src/signal.cj:36-69`）只有 `atExit`、没有 `remove`：每建一个池就永久多一条回调，回调闭包持有 `KeyPool` 实例 ⇒ 已 `close()` 的池及其 `map`/`Ref` 图无法回收（配合 `POOL-11`，高基数键时期的对象会一直留到进程退出）。

**修法**：给 `ExitCallbacks` 加 `remove`（返回句柄）并在 `close()` 里注销；或改为「只注册一次静态钩子，遍历活池集合」。

---

## 3. 低危 / 待验证（9 条）

- `POOL-L1` **告警钩子在 `head.globalLock` 临界区内被调用**：`selfCheck` 的 `error`/`warn`（`SyncDeque.cj:63-73`）与 `reconcileIfWedge` 的 `warn`（`250`）都在 `synchronized` 块内，默认钩子写 stderr、应用可重定向到日志框架 —— 慢钩子会阻塞所有取还操作，钩子若重入池则死锁。建议：把消息攒到锁外再发。
- `POOL-L2` **`checkInterval = Duration.Max` 使巡检形同虚设**：`BytesListOutputStream.builder` 的默认 `checkInterval=Duration.Max`（`f_pool/src/BytesListOutputStream.cj:89`）通过 `if(checkInterval <= Duration.Zero) return`（`290:290`）后仍然起线程，随后 `sleep(checkInterval)`（`314`）实测**不抛异常**（`main sleep_max: threw=false`）⇒ 该线程此后永不醒来：`minSize` 补足、空闲回收、`audit()` 自愈对这类池全部失效，且关池后也不会退出（与 `POOL-7` 同类的线程滞留）。建议：`Duration.Max`（或 > 某上界）时不起巡检线程，或改成分片睡眠（如每次 ≤1s 并复检 `running`）。
- `POOL-L3` **`HeadNode.nextForGet` 递归扫描**（`LinkedNode.cj:95-111`）：队首连续非 idle 节点时按节点数递归（`ValueNode.nextForGet` 自身是迭代的，递归只发生在「队首非 idle」这一步）。极端情况（大量滞留 CHECKING 项）可加深调用栈，建议改迭代。
- `POOL-L4` **`selfCheck`/`audit` 的全队列遍历在锁内**：每 1e4 次操作一次 `countNodes()`（O(队列长度)，`SyncDeque.cj:59-74`、`227-254`）；长队列 + 高并发时是周期性长临界区。可只统计计数，或在锁外做快照核对。
- `POOL-L5` **`get` 内定义局部函数** `keyedCheck`（`455-457`、`501-503`）：每次调用建闭包并走闭包调用（借用/归还是热路径）。可提到成员函数/用 `checkOnBorrowing` 直接分派。
- `POOL-L6` **`waitChunk` 溢出**：`waitStart + maxWaiting - MonoTime.now()`（`443-453`）在 `maxWaiting` 取很大的有限值（如 `Duration.Max - 1`）时可能溢出成负 ⇒ 立即放弃；建议写成 `maxWaiting - (now - waitStart)` 并夹取。
- `POOL-L7` **`ArrayPool.giveBack` 拒绝尺寸不符的数组时既不销毁也不告警**（`f_pool/src/ArrayPool.cj:60-67`）：调用方漏判返回值就是泄漏；至少在 `PoolDiagnostics` 记一条。
- `POOL-L8` **重复归还的记账补充**（§7.3 的延续）：`markReturned` 的 `if (out.load() > 0)` 守卫（`SyncDeque.cj:80-84`）让「多还一次」只扣 `out`、不扣节点数 ⇒ `s` 与 `节点数+out` 双向脱钩（`out` 变小、节点数变大），自愈会把 `s` 拉高到含重复节点的值，重复节点此后可能被两个借用者同时持有。维持 §7.3 的「不改，靠自检告警 + `Releasable.release()` 幂等 + 调用方纪律」即可，这里只补记账侧的证据。
- `POOL-L9` **`WeakFifo/WeakLifo` 的值类型路径**：值类型会被 `Box<T>` 包一层再交给 `WeakRef<Object>(box, DEFERRED)`（`SyncDeque.cj:331-338`），而 `box` 只被弱引用持有 ⇒ 池项可能立刻被回收（`refChecker` 返回 false ⇒ 当作失效项销毁）。当前仓库无调用方（README 已注明），仅登记。

---

## 4. 与归档报告的边界（已修/已拍板项的复核）

逐条对照 `.autocode/bugs/bug-archived-on-20261004.md` §6/§7，以下项在其他 worktree/分支的历史修复**在本基线上仍然成立**，本次不重复上报：

| 归档项 | 本次复核结论 |
|---|---|
| §6.8 / §7.2 池记账脱钩的触发源（`ValueNode.nextForGet` 丢值） | 已修：`LinkedNode.cj:236-262` 有 `taken` 局部量再 return；`SyncDeque_test.testScanForwardMustReturnTakenElement` 在跑 |
| §7.2 check 异常安全、`BaseKeyPool.destroy` 同步计数、`WeakSyncDeque.remove` 引用类型 | 已修，代码注释与用例都在（`f_pool` 全量用例通过） |
| §7.4 `ValueNode.check(fn, onRemoved!)` 同临界区递减 | 已修（`LinkedNode.cj:305-323` + `SyncDeque.cj:291`） |
| §7.6 `maxWaiting` 语义（`Duration.Max` 也受上限约束、有限值返回 `None`） | 已实现且用例 `maxWaitingBoundsInfiniteWait` 在跑；但**无限档的分片等待被当成了截止**（`POOL-5`），本次新增 |
| §7.12 巡检/创建线程「看护重开」+ 诊断计数 + 崩溃取证 | 已实现（`KeyPool.cj:289-374`、`diagnostics/PoolDiagnostics.cj`）；本次新增的是「创建失败无退避」（`POOL-4`）与「关池后创建线程阻塞在出队」（`POOL-7`） |
| §7.3 重复归还「暂不改」的拍板 | 维持；本次只在 §3 补记账侧证据（`POOL-L8`） |
| `clear` 必须往下传（§六，`f_codec` 拆链风暴根因） | 已修且 README 已钉口径（`pool.cj:178-181`）；本次的新问题是「`clear` 抛异常丢项」（`POOL-12`）与「`release` 后仍可写」（`POOL-9`） |

---

## 5. 基线与实测证据

**基线**：`review/f_pool` worktree 内 `cjpm build` → `BUILD_EXIT=0`；`cjpm test --no-capture-output` → `TEST_EXIT=0`（日志 `.autocode/tmp/pool_baseline.log`）。

**探针**（临时工程，未提交：`.autocode/tmp/pool_probe/`，依赖 `../../../f_pool` 的 path 依赖；运行脚本 `.autocode/tmp/pool_probe_run*.sh`，日志 `.autocode/tmp/pool_probe_run*.log`）：

| mode | 场景 | 结果 |
|---|---|---|
| `spin_finite` | maxSize=1 借空后 `get(timeout:2s)` | wall 2000ms / **user 2.25s**（忙等） |
| `spin_max` | 同场景 `get()`（`Duration.Max` 分支，对照） | wall 2002ms / user 0.11s（让出） |
| `churn` | `KeyPool(maxSize=totalSize=2)` 满载空闲，巡检 50ms × ~10 轮 | created 2→2、destroyed 0→0、**idle 2→1** |
| `createflood` | creator 恒抛异常 | 300ms 内 **75,976** 次尝试（≈25 万/s） |
| `slowcreate` | creator 睡 2s；`maxWaiting=Duration.Max` 档 | `got_some=false`、**elapsed 1008ms**（真无限等待档只等 1s 就放弃） |
| `slowcreate`（对照） | 同场景 `maxWaiting=30s` 档 | `got_some=true`、elapsed 2016ms |
| `finalizer` | 借出 1 件后 `gc()`（两次运行） | destroy 0→1，**`borrowed_is_destroyed=true`** |
| `double_destroy` | `close()` 后 `gc()` | after_close=1 → **after_gc=2** |
| `threads` | 建/关 20 池（`checkInterval=0`） | threads 7→**27**→27，blocking 6→**26**→26 |
| `useafterrelease` | `release()` 后再 `write` | 下一个借用者 `isEmpty=false`、`byteSize=5` |
| `arraypool_default` | `ArrayPool<Int64>()`（默认参数） | `Out of memory`，进程 **exit 1** |
| `queue_alloc` | `Pool<Object>(maxSize:5_000_000)` | 堆 **+80,004,832 B** |
| `sleep_max` | `sleep(Duration.Max)` | 不抛异常（线程睡下去不醒） |
| `lostwakeup` / `lostwakeup_load` | 每次 get 都必须等新建（×100；负载版另加 30 个 CPU 线程） | none=0/100（**未复现**，见 `POOL-5` 第二个面） |

> `POOL-1` 修复后的复测：把探针的 path 依赖指向 worktree 的 `f_pool`（工程 `.autocode/tmp/pool_probe_fixed`，其余同）—— `finalizer` → `after_gc=0 / borrowed_is_destroyed=false`、`double_destroy` → `after_close=1 after_gc=1`（修前分别是 `1/true` 与 `2`）。即上表中这两行是**修前基线**，修复记录见 §1.1。

> `POOL-2`/`POOL-5`/`POOL-6` 修复后的复测：等待改成条件变量通知后，上表里 `spin_finite`/`slowcreate` 的旧读数不再适用，改由单测钉住 —— `finiteTimeoutWaitMustNotBurnCpu`（`/proc/self/stat` 的 utime+stime tick 断言，修前 ≈30 tick 失败、修后通过）与 `infiniteWaitMustWaitForSlowCreation`（修前 1008ms 返回 `None` 失败、修后 ≥1.8s 拿到项）；`giveBackRacingCloseMustNotStrandItem`（100 轮「归还 ‖ 关池」）修前失败、修后通过。全量 `cjpm test` = **`PASSED: 42, SKIPPED: 0, ERROR: 0, FAILED: 0`**（日志 `.autocode/tmp/pool_fix2_{pre,post}.log`）。

> `POOL-3` 修复后的复测：探针 `churn` 的场景改由单测钉住 —— `checkMustNotDropIdleItemWhenAtCap`（满载空闲跑 ~10 轮巡检后仍可借 2 件、creator 仍只调 2 次；修前 `held.size == 2` 断言失败）与 `checkerMustRunWhenAtCap`（满载时用户 checker 必须被调用；修前 `calls.load() > 0` 断言失败）。全量 `cjpm test` = **`PASSED: 44, SKIPPED: 0, ERROR: 0, FAILED: 0`**（日志 `.autocode/tmp/pool_fix3_{pre,post}.log`）。

> `POOL-7` 修复后的复测：`closeMustReclaimInternalThread`（建/关 20 个池后线程数回落到基线；修前 `after <= before + 5` 断言失败）与探针 `main threads` 的同一读数（修前 `7->27->27 / blocking 6->26->26`）。全量 `cjpm test` = **`PASSED: 45, SKIPPED: 0, ERROR: 0, FAILED: 0`**（日志 `.autocode/tmp/pool_fix7_{pre,post}.log`）。

复跑方式（WSL Ubuntu-24.04）：`source /mnt/d/docs/work/cangjie/cangjie.sh` → `cd .autocode/tmp/pool_probe && cjpm build` → 按脚本里的 `LD_LIBRARY_PATH`（各 `target/release/*@*` 目录**排在 `installed/libs/fboot` 之前**）直接跑 `target/release/bin/main <mode>`，用 `time -p` 量 CPU。

---

## 6. 审查方法与备注

- 方法：先通读 `f_pool` 全部源码与 7 个测试文件，再与归档报告 §6/§7 的历史问题逐条比对（避免把已修项当新问题）；对可疑点按「读码定位 → 最小探针实测 → 数字落报告」的次序处理：5 条严重、4 条中危有实测数字支撑，未复现的按读码推理并注明。
- 本次审查**只读**：未改 `f_pool` 任何代码，未动 `bug.md` 等其他会话的活动报告；报告落在本分支 `.autocode/bugs/bug-pool.md`。
- 探针工程与日志在 `.autocode/tmp/`（`.gitignore` 已覆盖），不进仓库；如需长期保留证据，把它们挪到 `.autocode/review-pool/` 再提交。
