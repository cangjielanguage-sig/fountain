# 并发审计与加固清单（2026-11-27）

> 结论先说：**没有发现可达的并发缺陷**（1253 条用例 + 本次专项探针全绿）。
> 本文记录 6 条**脆弱点 / 未定义语义**，逐条对应一个 openspec 变更，按风险从高到低排列。

## 1. 复核范围与方法

1. **静态扫描**：`src/` 下全部 25 个进程级 `static let/var`，逐个确认保护方式（锁 / 原子 / 不可变快照 / TLS / 定长数组）。
2. **专项探针**（临时用例，跑完即删）：
   - 6 线程同时编译同一**非法**源码 ⇒ 6/6 全部失败、无半成品（`bad=0`）；
   - 4 线程同时 `close` 同一单元 ⇒ 4/4 返回 true、`isClosed=true`、不崩；
   - 编译失败后再编译同 key ⇒ 仍失败（失败缓存稳定）。
3. **并发矩阵**（`ConcurrencyMatrix_test`，本日新增）：编译同源/异源、调用同闭包/异闭包、编译+调用混合。
4. **基准**：`CallPathBench_test` + 同单元/异单元对比探针。

已确认安全的共享点：

| 共享状态 | 保护方式 |
| --- | --- |
| `CompileCache` 三张表 + `pipelineRuns` | 全局 `mtx`；同键 `claim/awaitReady` 去重 |
| `ClassRegistry` / `ReflectRegistrar.retained` | 各自 `Mutex` |
| `JitBindSupport` 登记表 | `AtomicReference` + 不可变快照，读零锁 |
| `HandleTable.segDir` | **定长**数组、只替换元素 ⇒ 读者无锁（ID 跨线程传递必经同步点） |
| 句柄分配/释放 | 64 分片，每片独立锁；`totalSlots` 原子 |
| `RuntimeEnv` / `UserHelperTable` / `IterTable` | 全部 TLS |
| `NativeMem` 计数 | `AtomicInt64` |
| A64 编译审计 / x86 编译审计 | 实例字段 / `ThreadLocal` |

## 2. 六条遗留隐患

### H1 编译缓存与单元的 ABBA 锁序（脆弱设计）

- **位置**：`src/CompileCache.cj` `finish()` 在 `synchronized(mtx)` 内调用 `fn.bindCacheKey(key)`
  （要 `JitFunction.mtx`）；`src/JitFunction.cj` `close()` 在 `synchronized(this.mtx)` 内调用
  `CompileCache.remove(k)`（要 `CompileCache.mtx`）。
- **机制**：两条路径的加锁顺序相反。线程 A 在 `finish`（持缓存锁 → 等单元锁）、线程 B 在 `close`
  （持单元锁 → 等缓存锁）即死锁。
- **可达性**：**当前不可达**——`finish` 发生时该单元尚未写入 `ready`，外部拿不到引用，
  因此不存在对同一对象的并发 `close`。但这是**依赖调用图**的隐式不变式，任何一次
  「先发布、后 bind」的改动都会把它变成真缺陷。
- **修法**：`bindCacheKey` 移到全局锁之外（发布前调用，对象仍不可见，安全）。
- **验证**：`CompileCache_test` + 并发矩阵 + 全量；并用「finish 期间其它 key 的 claim 不被阻塞」的
  压力用例佐证。

### H2 `NativeAssets` 计数非原子（并发下丢计数）

- **位置**：`src/backend/NativeAssets.cj` `allocs` / `frees` 是普通 `Int64`，`onAlloc` / `onFree`
  直接 `+1`；`liveCount()` 无锁读差值。
- **机制**：`read-modify-write` 竞争 ⇒ 并发编译/卸载时计数丢失，`liveCount()` 可能偏低甚至为负。
- **可达性**：只影响**测试断言**（T27/T29 的泄漏检查）与诊断；运行时正确性不依赖它。
- **修法**：改 `AtomicInt64`（`fetchAdd` / `load` / `store`）。
- **验证**：新增并发计数用例——4 线程各 alloc 100 次后 `liveCount()==400`，各 free 后回到 0；
  非原子实现在第一步就会低于 400（可变异复现）。

### H3 `JitFunction.lastEscaped` 的并发写（语义未定义）

- **位置**：`src/JitFunction.cj` 普通 `call` 返回闭包时 `this.lastEscaped = Some(e)` 在锁外写；
  `lastEscapedClosure()` / `lastPromotionGroup()` 无锁读。
- **机制**：多线程同时返回闭包时互相覆盖；读者可能拿到别的调用的提升组。
- **可达性**：**生产路径不受影响**——`callForFn` 已改用每次调用私有的 `CallOut`；该字段只剩
  单线程诊断（`JitFunctionClosure_test` 一处）与兼容访问器。
- **修法**：写/读都进 `this.mtx`（只在「返回闭包」的调用上多一次锁，低频），并在两个访问器的
  文档注释里明确「单线程诊断口径，并发下值不确定；并发请用 `callForFn`」。
- **验证**：并发 `call`（返回闭包）+ 并发 `callForFn` 混合，断言包装结果全部正确、不崩。

### H4 `HandleTable` 的可调配置在运行中改（数据竞争）

- **位置**：`src/runtime/HandleTable.cj` `initialCapacity` / `capacityLimit` 是 `public static var`，
  `openWindowWith` / `newSlot` 直接读。
- **机制**：另一个线程写这两个字段时，读者可能看到撕裂值（64 位在 32 位平台）或旧值；
  语义上「调小不追溯」也没有同步保证。
- **可达性**：只有测试会改；生产通常在启动前设定。
- **修法**：改 `AtomicInt64` + `mut prop` 访问器（`HandleTable.initialCapacity = 128` 的赋值语法不变）。
- **验证**：并发改 `initialCapacity`（在两值间切换）+ 并发 `openWindow`/调用，断言不崩、
  窗口容量恒为两个合法值之一。

### H5 `Compiler.registerClass` 的锁外注册（并发注册语义未定义）

- **位置**：`src/Compiler.cj` `registerClass()` 先 `this.classes.register(desc)`（锁外），
  再 `synchronized(this.mtx)` 把方法并入函数表并清快照缓存；`registerType` / `registerInterface`
  同理（反射注册在锁外）。
- **机制**：并发注册时可能出现「类已注册、方法尚未进入函数快照」的窗口，
  此时并发编译拿到的是半套快照。
- **可达性**：注册通常在启动期单线程完成；未在文档中承诺线程安全。
- **修法**：把 `classes.register` / 反射注册整体移入 `synchronized(this.mtx)`。锁序变为
  `this.mtx → classes.mtx`，与 `snapshot()` 一致（后者已在 `this.mtx` 内调 `autoFunctions()`）。
- **验证**：4 线程并发注册 100 个不同类 + 另一线程并发编译，断言注册全部成功、
  `registeredNames()` 不丢项、编译不失败。

### H6 `awaitReady` 超时与「编译失败」语义混淆

- **位置**：`src/CompileCache.cj` `awaitReady()` 30 s 超时返回 `None`；
  `src/CompilePipeline.cj` 的 `None` 分支统一抛 `CompileFailed`。
- **机制**：等待者超时与「首编线程失败」共用一条错误路径，调用方无法区分
  「源码有问题」与「等太久」。
- **可达性**：只有单次编译超过 30 s 才会触发（正常 < 10 ms）。
- **修法**：超时上限提为可配置（测试用 1 ms），`None` 分支按「有失败文本 / 仍在编译 / 其它」
  三态给出不同 kind：`CompileFailed` 与 `CompileTimeout`，超时文案写明秒数。
- **验证**：`claim` 后 `awaitReady` 在 1 ms 内返回 `None` 且 `isCompiling==true`；
  三态选择逻辑的直接断言。

## 3. 实测数据（2026-11-27，构建机 7 核共享 VM）

```
B1 单线程短调用   L1 = 2971 ns/call    Q1 = 336k calls/s
B1 4 线程         Q4 = 807k/s          = 2.40×
B4 ctx create+free C1 = 411 ns          = L1 的 13.8%

4 线程 × 80000 次（同一进程内相邻测量）：
  同一个单元   1886 ns/call  （1.54×）
  各自单元     1002 ns/call  （2.91×）   ← 差 1.88×
```

**纠错（同日 3 轮交替复测）**：同单元 vs 异单元的 1.88× 是**测量伪影**——统一 n 后
`same=1111 ns` vs `diff=1077 ns`（差 3%，噪声内）。`enter/exit` 的两次 `synchronized`
在 4 线程下没有可测代价，原「原子化可 +70%」的预估作废。

**已尝试且无收益**（`optimize-jitcontext-pool`，已回退）：`JitContext` 池化。
- `ThreadLocal` 池：`C1` 405→**855 ns**（`std.ThreadLocal` 单次约 300 ns，比 malloc/free 还贵）；
- `RuntimeState` 池：`C1` 405→348–376（−14%），但 `L1` 2952→3128/3248（+6~10%），
  热路径的 `Some(rs)` 构造与池操作把收益吃回去，端到端无可采纳收益。

## 4. 状态

| 编号 | 隐患 | 变更 | 状态 |
| --- | --- | --- | --- |
| H1 | ABBA 锁序 | `fix-compilecache-lock-order` | 已完成（4a8…已归档） |
| H2 | 计数非原子 | `fix-native-assets-atomic` | 已完成（改前红 left=396） |
| H3 | `lastEscaped` 并发写 | `clarify-last-escaped-scope` | 已完成（语义收敛，无可测差异） |
| H4 | 配置数据竞争 | `fix-handle-config-race` | 已完成（原子化，无可测差异） |
| H5 | 锁外注册 | `fix-compiler-register-lock` | 已完成（旧实现窗口窄，未复现） |
| H6 | 超时语义 | `fix-await-timeout-semantics` | 已完成（`CompileTimeout` 三态） |
