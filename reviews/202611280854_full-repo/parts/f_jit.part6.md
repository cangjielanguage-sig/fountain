# f_jit 模块审查报告（模块第 6/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 5 个文件；模块整体 305 个 `.cj` + 290 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，未对照远端分支）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（仅本部分；模块级报告由主 Agent 合并；第二轮补充 #18–#22）
- **本部分覆盖**：`doc/jit-bytecode-m3.md`（M3 规格，v0.3.24）、`doc/optimize-call-path.md`（调用路径优化台账）、`doc/optimize-compile-path.md`（编译路径优化台账）、`doc/perf-m1.md`、`doc/perf-m2.md`

> 说明：本部分只有规格与性能台账文档，无 `.cj` 源码。因此「发现」以**文档承诺与实现/测试的不一致**、**文档内部自洽性**、**基线数据可用性**为主；引用的实现行号只作判据证据，不单独计为本部分文件。所有问题均为**存量**（快照模式无基线可比）。

## 发现

> 编号索引（正文与「文件覆盖」「覆盖自检」的 `#n` 均指此处）：#1 容器转型键值校验缺失（严重）· #2 签名表 128 上限与 T56 计数 · #3 `enabled` 非原子开关 · #4 perf-m1 aarch64 基线失效 · #5 perf-m2 口径自相矛盾 · #6 `isJitBacked` 断言缺失 · #7 `ti` 惰性化的成本转移 · #8 签名表作用域「桥实例级」 · #9 H63 执行流漏 adapter · #10 perf-m2 待决表过期 · #11 过期引用（1.5–3× / 三钉子）· #12 `AdapterRegistry` 论证对象不存在 · #13 行号漂移与头部索引 · #14 空 C3 行与 TLS 计数 · #15 实验规则重复且漂移 · #16 审计表两套隔离机制 · #17 JSON 常量上限未文档化 · #18 `json_set` 写值域与实现不符 · #19 helper 编号沿革注记 · #20 错误码映射范围 · #21 探针路径不存在 · #22 14 目标 aux 规则。

### [严重][存量] §5/§9.1/T39 承诺的「容器转型元素/键值校验」实现里不存在：Map 键型完全不判，`is Map<String,Any>` 对 Int64 键表为真

- **位置**：`f_jit/doc/jit-bytecode-m3.md:113`（§5「容器转型的元素/键值校验（前提 P2）……命中条件 = 是 List 且元素类型一致」）、`:171`（§9.1「落地形态 = 按 `(typecode, aux)` 的有限分支表……`case 10_0 => box is ArrayList<Bool>` 形式的静态分支」）、`:190`（T39 断言「元素/键值不符 → 拒绝」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）、§11（契约与实现不符）、§3（承诺的行为在实现中为空）
- **证据**：静态确定 —— 实现只做固定形态判定：`case 10 => v is ArrayList<Any> && listAuxMatches(aux)`、`case 11 => v is HashMap<ConstMapKey, Any> && mapAuxMatches(aux)`（`f_jit/src/runtime/AnyHelpers.cj:156-158`）；`listAuxMatches` 仅接受 `aux=15` 或 `0xFFFF`（`:207-209`），`mapAuxMatches` **只比较低字节（值码）**，注释明写「键码被 `ConstMapKey` 包装**擦除**……无法也不应校验」（`:217-223`）。世界内 `Map<Int64,Any>` 与 `Map<String,Any>` 运行期同形（`HashMap<ConstMapKey, Any>`）。用例也只锁定了值码：`mapAuxChecksValueType` 断言 `1039`(String→Any) 命中、`1024`(String→Int64) 不命中，**没有任何键码对拍**（`f_jit/src/runtime/AnyHelpers_test.cj:223-241`）
- **描述**：把一个 `Map<Int64,Any>` 装进 Any 后，`is Map<String,Any>` 返回 1、`as Map<String,Any>` 成功（规格承诺这里是 22）。随后按 String 键读会落到「缺键 5」，写会造出 Int64/String 混键的同一张表——规格 §5/§9.1/T39 冻结的键型校验在实现中是**空**的。List 侧同理只有「元素 = Any」命中，`List<Int64>` 恒不命中，与 §9.1 的「枚举元素码 0–3 / 4–11 / 14 / 16–19」完全不同。文档把 P2 实测（`:157`「泛型实参参与运行期判定」）当成「走校验路径」的依据，但实测只证明「`is` 能区分泛型实参」，推不出「键型可判」——键在 M1 就被 `ConstMapKey` 擦除了。
- **建议**：二选一并写进 §5/§9.1/T39：① 收窄承诺为「容器转型只保证**元素为 Any**（世界内唯一形态）；Map 键型不可判，`as Map<K,Any>` 只校验值码」；② 若确需键型安全，给 Map 句柄条目增加键码 tag 并在 `as` 时比对（格式/内存增量需单独立项）。T39 补负向用例「`as Map<String,Any>` 对 `Map<Int64,Any>` → 22」，当前缺这条断言。

### [一般][存量] §13.1「签名空间有界、无需淘汰」与实现 `MAX_ENTRIES = 128` 不符，T56 的「构建计数 = 不同签名数」在超限后失效

- **位置**：`f_jit/doc/jit-bytecode-m3.md:314`（「签名键 = 类型码序列（T/R ∈ 0–8/10–11……）——表条目数**天然有界、无需淘汰**」）、`:193`（T56「同签名只建一次〔构建计数 = 不同签名数〕」）、`:309`（Layer A 生命周期「桥实例级；只读共享」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）、§14.1（规格不足以支撑其断言）、§11（契约不符）
- **证据**：静态确定 —— `SignatureTable.MAX_ENTRIES = 128`，超限分支「不缓存，但计数仍 +1」，且每次超限 `getOrBuild` 都在写锁内 `SignaturePlan(sig)` + `current.store(PlanSnapshot(...))`（`f_jit/src/runtime/SignaturePlan.cj:138`、`:166-181`）；上限本身有用例（`f_jit/src/runtime/SignaturePlan_test.cj:224-229`）。而 M3 自己已把 9、14、16–19 并入可转集与签名面（`jit-bytecode-m3.md:46`、`:238`「可直接作参数/返回/局部变量、进签名（含跨桥形参/返回）」），文档 `:314` 的 T/R 范围停留在 M2 口径
- **描述**：三处后果。① 文档说「无需淘汰」，实现有 128 条上限且**没有**淘汰——超限后退化成「每次调用现造 plan + 取写锁 + 分配新快照」，是未记录的性能台阶；② T56 的「构建计数 = 不同签名数」只在 `entryCount < 128` 时成立，超过后每次调用都 +1，按断言写用例会假红/假绿；③ `:314` 的签名空间估算与 `:46`/`:238` 自相矛盾，读者无法判断签名表到底有多大。
- **建议**：§13.1 补「条目上限 128；超限不缓存、每次现造（写锁 + 快照分配），行为等价但无加速」，T56 的计数断言限定 `entryCount < MAX_ENTRIES`，并把 T/R 范围改为「0–19（M3 合法集）」。

### [一般][存量] §13.1「读路径无锁（不可变发布）」漏掉进程级 `public static var enabled`：热路径读非原子开关，并发切换语义未定义

- **位置**：`f_jit/doc/jit-bytecode-m3.md:317`（「SignatureTable 首建 = 锁 + 双检……读路径无锁（不可变发布）」）、`:193`（T56「强制通用 / 强制特化双路径」）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）、§13（文档未覆盖实现的状态）
- **证据**：静态确定 —— `public static var enabled = true`，`getOrBuild` 首行读它（`f_jit/src/runtime/SignaturePlan.cj:135`、`:141-144`）；`resetForTest()` 与宿主/测试都会写（`:194-199`；用例 `SignaturePlan_test.cj:105/123-127/177-179`）。文档只描述「不可变快照发布」，未提这个**不在快照里**的可变开关
- **描述**：开关的读者在每次 H63 调用上，写者可以是任意线程（T56 要求能切换两条路径，宿主侧也可关）。普通 `var` 跨线程读写没有 happens-before，`enabled` 的翻转可能对不同线程长时间不可见，甚至与正在进行的首建交叉出「本应通用却拿到 plan / 本应特化却拿到 None」的混合观测。文档对此完全没有定义（也没有说明「只在无并发调用时切换」）。
- **建议**：把开关纳入 `PlanSnapshot`（原子替换），或改 `AtomicBool`；§13.1 增一句「开关仅在无并发调用时切换（启动期/测试）」，并把该纪律写进 T56。

### [一般][存量] `perf-m1.md` 的 aarch64 JIT 基线已被后续优化推翻且无日期/SDK，与 x86 表差 88×，不能再作为 M1 性能基线

- **位置**：`f_jit/doc/perf-m1.md:8-17`（aarch64 表：JIT 200,867,356 ns，n=200000×5 轮 → 200 ns/轮；相对 cjnative 1949%）、`:19-31`（x86 真机表：JIT 2,276,989 ns → 2.3 ns/轮，比 cjnative 快 29%）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 基线不可复现）、§6.1（无对照数据的性能结论不成立）
- **证据**：静态确定 —— 同一份栈机产物、同一用例，两架构单轮成本差 88×，文档没有任何解释；aarch64 表**没有日期与 SDK 版本**，x86 表有（`:21`）。同仓 `f_jit/doc/optimize-call-path.md:402-412` 在同一台 aarch64 上实测：`interrupt_poll` 回边 poll 让空循环从 15 ns/轮 涨到 662 ns/轮（占 97.7%），修复后回到 15 ns/轮（`:439-447`）。perf-m1 的 200 ns/轮正落在「修复前」量级
- **描述**：aarch64 那组数写在 `optimize-loop-safepoint` 之前，主体开销是已被删除的逐回边 helper 调用，不是代码生成质量。它给出的「JIT 相对 cjnative 约 19× 慢」是**历史结论**，按当前实现复跑应显著收敛；继续当作 M1 基线会误导后续判断（例如以为 aarch64 代码生成有结构性问题）。
- **建议**：aarch64 表补日期/SDK 并按当前实现复跑 `PerfCompare_test`；若确认被 safepoint 修复取代，标注「历史基线（pre-`optimize-loop-safepoint`）」或直接替换数值；两架构数值并列时必须写明差异归因。

### [一般][存量] `perf-m2.md` 的方法、列头单位与单次换算三者互相矛盾，所述方法无法复现该基线

- **位置**：`f_jit/doc/perf-m2.md:10-11`（「预热 64 次……随后各跑 **2000** 次」）、`:15-18`（列头「user helper（ns/10k）」15,271,110 / 70,732,890）、`:20`（「换算单次：user helper 约 **153 ns**，宿主闭包约 **707 ns**」）
- **来源**：存量
- **判据**：review-checklist §13（数据单位/口径与自述不符）、§6.1（基线缺可复核口径）
- **证据**：静态确定 —— 15,271,110 ns ÷ 2000 = 7 636 ns/call，与 153 差 50×；按「10k 次」记则是 1 527 ns/call，仍不等于 153；只有按 **100k 次**才是 152.7 ns（70,732,890/100k = 707.3 ns，与 707 完全对上）。现行用例已不是文档所述口径：`rounds = 4000`、`MonoTime`、3 轮比值取中位数（`f_jit/src/PerfM2_test.cj:54-113`）
- **描述**：三个数字只能同时成立于「每臂 100k 次」，而正文写 2000 次、列头写 ns/10k。读者按文档方法重跑得不到同一数量级，也无法判断 4.63×/5.75× 的比值是在什么迭代规模下取的（比值本身不受影响，绝对 ns 受影响）。
- **建议**：方法段改为「每臂 100k 次、3 轮取中位数、`MonoTime`」，列头改「每臂总 ns」或直接给 ns/call；并注明这组数是旧版用例（2000 次两轮）的历史留档。

### [一般][存量] `optimize-call-path.md` §2.2 承诺给 `ParallelThroughput_test` 补 `@Assert(f.isJitBacked(), true)`，实现只有打印；S2/S4/S8 的「机器码基线」缺护栏

- **位置**：`f_jit/doc/optimize-call-path.md:61-62`（「补 `@Assert(f.isJitBacked(), true)`——当前 734 ms / 2M 次循环很可能走解释器」）、`:111`（「`jitBacked=1`：……基线不是解释器数据」）、`:253`（「`S4` 仍 < 2.6× ⇒ 先查 `isJitBacked`」）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但未实现）、§13（文档与测试不符）
- **证据**：静态确定 —— 用例只有 `println('PAR-BENCH jitBacked=…')`，没有任何 `@Assert`（`f_jit/src/ParallelThroughput_test.cj:52`）；文件注释还明确「本用例不设吞吐门槛」（`:28-33`），但 `isJitBacked` 是正确性护栏、不是吞吐门槛
- **描述**：整份调用路径优化的第一层前提是「执行本身已无锁，机器码承载」；一旦环境变化导致单元回退解释器，`S2/S4/S8` 会静默变成解释器并行度，而用例仍然全绿、`PAR-BENCH` 里的 `jitBacked=0` 只出现在日志里。文档 §3.1 的基线结论与 §8 的停止条件都依赖这个值。
- **建议**：补 `@Assert(f.isJitBacked(), true)`（或在 `Off` 模式下显式跳过并打印原因）；文档同步说明「该断言不是吞吐门槛」。

### [一般][存量] §15.4 的 `ti` 惰性化把 `FunctionTypeInfo.of` 从「每条目一次」变成「每次反射/plan 调用一次」，文档只写「行为等价」，未记录成本转移

- **位置**：`f_jit/doc/optimize-call-path.md:498-512`（「`cb.ti` 只在反射路径用……带签名的构造却无条件 `probeType`——纯浪费」「`reflectiveInvoke*` 本就接受 `cached = None` 并现场探测，**行为等价**」）、`:461-465`（`TypeInfo.of`(probeType) 116 ns、4 线程扩展比 0.31–0.35×）
- **来源**：存量
- **判据**：review-checklist §6.1（性能结论缺对照）、§13（文档遗漏实现的成本变化）
- **证据**：静态确定 —— 带签名构造把 `ti` 置 `None`（`f_jit/src/runtime/Signature.cj:389`），而两条非 adapter 路径在 `cached == None` 时**每次**都现场 `FunctionTypeInfo.of(fn)`（`f_jit/src/runtime/ReflectiveCall.cj:34-42`；`f_jit/src/runtime/SignaturePlan.cj:202-219`）。`HostCallback` 是**per 桥调用**创建、在一个 JIT 调用内的 5 万次回调循环里被复用（`PerfM2_test`/`HostClosureAdapter_test` 的形态），因此缓存从「每条目一次」退化为「每次回调一次」
- **描述**：文档的 A/B 只测了 `HostCallback` **构造**，结论「单线程几乎不变」成立；但它没有说明被搬走的 `TypeInfo.of` 现在落在**每次反射调用**上，且 §15.4 自己测到该调用 4 线程扩展比只有 0.31–0.35×（std 反射元数据缓存的内部争用）。也就是说：无 adapter 的回调密集场景，构造变快了，循环里每次回调多了一次元数据查找与争用。这是「行为等价」掩盖下的成本转移，报告把它当纯收益收口（`:516-517` 只给构造数据）。
- **建议**：文档补一句「反射/plan 路径每次调用一次 `FunctionTypeInfo.of`；adapter 未登记的密集回调场景需单独实测」；若确认有回退，可在首次探测后回填条目缓存（`ti` 改 `var` 或加旁路缓存，条目在单次调用内复用）。

### [轻微][存量] §13.1 把 `SignatureTable` 写成「桥实例级」，实现是进程级静态表（多 `Compiler`/多用例共享、无卸载回收）

- **位置**：`f_jit/doc/jit-bytecode-m3.md:309`（Layer A 生命周期「**桥实例级**；只读共享」）、`:318`（「SignatureTable / plan 不入 `.fbc`」）
- **来源**：存量
- **判据**：review-checklist §13（作用域与实现不符）、§12.1（共享状态的隔离）
- **证据**：静态确定 —— `private static let current = AtomicReference<PlanSnapshot>(...)`、`private static let writeMtx`，全进程唯一，只有 `resetForTest()` 能清（`f_jit/src/runtime/SignaturePlan.cj:130-132`、`:194-199`）
- **描述**：plan 身份无关，所以「共享」本身安全；但「桥实例级」会让实现者以为多 `Compiler`/多租户之间天然隔离、卸载单元会回收对应条目——实际是进程级常驻（≤128 条），且没有任何按单元/按实例的清理点。
- **建议**：改为「进程级、进程生命周期；不随单元卸载回收（身份无关、容量 128 封顶）」，或按 `Compiler` 持有实例表（需评估跨实例构建重复成本）。

### [轻微][存量] §13.1 / §13.3 的 H63 执行流漏掉类型化 adapter 层：实现顺序是 adapter → plan → 反射，「唯一可观察差异是性能」未覆盖「根本不进 plan」

- **位置**：`f_jit/doc/jit-bytecode-m3.md:313`（「H63 新执行流：fetch → `entry.plan`（命中则跳过 ② 的解释循环……）→ 调用 `fn`」）、`:334`（§13.3「每个转换器直接复用 H63 通用流程的同一转换函数」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现流程不符）
- **证据**：静态确定 —— 实现先 `match (cb.adapter)`，命中直接 `ad(cb.fn, convertArgs(sig, a))`，**完全不看 plan**；未命中才 `match (cb.plan)`，再退反射（`f_jit/src/runtime/HostCall.cj:63-74`）。`HostCallback` 构造同刻两者都绑定（`f_jit/src/runtime/Signature.cj:390-392`）
- **描述**：对已登记签名，T56 测的 plan 路径根本不会执行（adapter 先命中），「特化 ≡ 通用」的对拍实际是三方对拍。§13 只写 plan 一处快路径，实现者按文档接入会漏掉 adapter 优先级，也无法从文档判断某个用例到底走了哪条路。
- **建议**：§13.1 的执行流补成三级「adapter（若登记）→ plan（若启用且未超限）→ 通用反射」，并说明 T56 的两条强制路径如何与 adapter 共存（是否需要在 T56 里禁用 adapter）。

### [轻微][存量] `perf-m2.md` 的「可选路径（待决）」与「`SignatureRegistry` 当前已无调用方」已过期：同文后节已交付，且它已在生产路径上

- **位置**：`f_jit/doc/perf-m2.md:33-38`（方案 A/B/C 表；B 行「`SignatureRegistry` 复活（**当前已无调用方**）」）、`:41`（「当前代码停在 A 的实现形态」）、`:79`（「M2 仍按用户裁定停在现状（4.6×）」）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 内部结论相反）、§14.1（已交付能力未回写）
- **证据**：静态确定 —— `SignatureRegistry.adapterOf` 已是 `HostCallback` 带签名构造的必经调用（`f_jit/src/runtime/Signature.cj:390`），H63 命中 adapter 时静态调用（`HostCall.cj:63-65`）；同文 `:135-170` 三节（M2.2/M2.3）已给出 adapter 3.25–3.56× / 2.83× 的实测，与 `:33-41` 的「待决 / 停在 A」互斥
- **描述**：读者读到 `:33-42` 会以为快速路径仍未决、`SignatureRegistry` 是死代码；实际它已是默认路径的一环，且 B 方案（静态绑定）只以 adapter 形态部分落地。文档缺少「本节结论已被后节取代」的指针。
- **建议**：`:33-42` 改为历史留档并加指针「结论见本文件后三节（M2.1–M2.3）」，删除「当前已无调用方」这类会随时间腐烂的现状断言。

### [轻微][存量] 过期引用：`perf-m2` 与 m3 §13 仍引已被废止的「1.5–3×」估算；m3 §12-9 仍称三个钉子待裁

- **位置**：`f_jit/doc/perf-m2.md:3`（「规格 `jit-bytecode-m2.md` §5 的估算为 **1.5–3×**」）、`:37`（「把 §5 的估算改为实测区间」）；`f_jit/doc/jit-bytecode-m3.md:299`（承接 m2 §8「估算为 user helper 调用的 1.5–3×」）、`:292`（§12-9「其开放钉子（plan 构建时点 / argc 展开阈值 / 调用级身份缓存的三条启用门槛）见 §13.5」）
- **来源**：存量
- **判据**：review-checklist §13（引用已废止数据 / 状态过期）
- **证据**：静态确定 —— m2 头部变更记录与 §8 已写明「实测 4.6–5.8×，**原估 1.5–3× 废止**」（`f_jit/doc/jit-bytecode-m2.md:3`、`:210`）；m3 §13.5 里前两个钉子已裁定（`:346-347`），只剩 Layer C（`:351`）
- **描述**：m3 §13 是 CALL_HOST 特化的活规格，开篇用废止数字描述需求，会让读者低估特化收益上限（真实差距比 1.5–3× 更大）；§12-9 的「三个钉子待裁」与 §13.5 的「两个已裁」矛盾，追进度的人会去等已经结束的裁定。
- **建议**：`perf-m2.md:3/:37` 与 `m3:299` 统一改为「4.6–5.8×（1.5–3× 已废止）」；`m3:292` 改为「钉子 ①② 已裁（§13.5），仅 Layer C 待定」。

### [轻微][存量] `optimize-compile-path` / `optimize-call-path` 对 `AdapterRegistry` 的锁与 UAF 分析指向一个生产零引用、且不存代码地址的表

- **位置**：`f_jit/doc/optimize-call-path.md:196-203`（P3.2「`AdapterRegistry.lookup` 都在全局锁内；……在编译/注册/查适配器时用」）、`:205-209`（P3.3「`AdapterRegistry` 存的是**代码地址**；COW 读者若持有旧快照，必须在代码释放前离开」）、`:219`（「P3.2 × 卸载 | 适配器是代码地址；依赖 close 排空，否则 UAF」）
- **来源**：存量
- **判据**：review-checklist §13（文档描述与实现不符）、§11（契约不符）
- **证据**：静态确定 —— `AdapterRegistry` 是 `protected class`，全仓 `.cj` 里除自身与 `AdapterRegistry_test.cj` 外只有 `Root.cj:21` 的一行注释命中，**无生产调用点**；表值是 `Int64`（`HashMap<String, Int64>`），不是代码地址（`f_jit/src/AdapterRegistry.cj:27-60`）
- **描述**：P3.2/P3.3 用「代码地址 + 旧快照 → UAF」的论证否决/约束一个改造项，但该表既不在执行路径上（P3.2 自己也承认），也不持有地址，UAF 前提不成立。这条分析既不能作为「不做」的证据，也不能作为「做」的设计约束，属无效论证。同时它掩盖了真正的问题：该类型是否应删除或收窄可见性（仅测试使用）。
- **建议**：把 P3.2/P3.3 标注为「分析对象已无生产调用点，结论作废」，改为「`AdapterRegistry` 是测试专用残留，建议删除或降为测试内工具」；若保留，则按实际存储（Int64 id）重写失效分析。

### [轻微][存量] `optimize-call-path` 的行号引用已漂移，头部状态摘要停在 §14、未收录 §15–§18 的四个 keep

- **位置**：`f_jit/doc/optimize-call-path.md:399`（「临时注释 `A64Lower.cj:368` 的 `helperCall0(22)`」）、`:449-450`（「`X86Lower.cj:1032` 一直有 `helper(22, 0, 0)`」）、`:3-10`（状态行只写「§14 是新的量级发现」，关联归档只列到 phase2）
- **来源**：存量
- **判据**：review-checklist §13（链接/位置失效）、§14.1（已交付项未入索引）
- **证据**：静态确定 —— 回边 poll 实际在 `f_jit/src/backend/A64Lower.cj:379`（`this.helperCall0(22)`）与 `f_jit/src/backend/X86Lower.cj:1043`（`this.helper(22, 0, 0)`）；§15/§16/§17/§18 共四处 keep（签名两表 −52%/−84%、TLS −32~36%、helper 表 −96%）与 `optimize-signature-tables`/`optimize-runtime-tls`/`optimize-helper-table`/`optimize-call-alloc2` 均未进头部
- **描述**：按文档去定位变异点会打空；按头部判断会认为调用路径优化止于 §14，实际后面还有三项数量级收益——这是文档的「索引层」失效，影响的是后来者对该模块性能现状的判断。
- **建议**：行号改为符号引用（`A64Lower` 回边 `helperCall0(22)` 调用点）或同步到 379/1043；头部状态行补 §15–§18 的一句话结论与归档名。

### [轻微][存量] `optimize-compile-path` 决策日志残留空 C3 行；§11.4 与 §12.2 的 TLS 调用次数估算不一致

- **位置**：`f_jit/doc/optimize-compile-path.md:91`（`| | C3 | 4 线程扩展比 | | | | |` 空行）、`:268-270`（§11.4「每函数约 **1000** 次 ⇒ 约 **0.3 ms**（预期 −8%）」）、`:286-295`（§12.2「**598** 次 TLS get × 约 300 ns ≈ 180 µs」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不一致 / 模板残留）、§3（占位空行）
- **证据**：静态确定 —— 同一份文档对同一次改动给出 1000 次与 598 次两个计数；§6 已判 C3 取消（`:98-109`），决策日志末尾仍留着未填的 C3 模板行
- **描述**：C3 空行会被后续填写者当成「待办」；TLS 次数从 1000 改成 598 说明 §11.4 的估算口径有误，而 §12.2 的结论（未测得收益）正是靠 598 推出来的——两个数并列会让读者怀疑结论的算术基础。
- **建议**：删掉空 C3 行（或填「取消，见 §6」）；§11.4 改为「598 次（实测计数）」，并注明 1000 是早期估算。

### [轻微][存量] 两份 `optimize-*.md` 重复定义同一套实验硬规则，且已漂移（假失败豁免、≥8 核复测只在一份里有）

- **位置**：`f_jit/doc/optimize-call-path.md:17-31`（硬规则 1–7：先基线后改码 / 一次一项 / 三项同时满足 / MOV / 共享机只初筛、`8 线程 ≥5×` 必须专用 ≥8 核复测 / 语义改动走 OpenSpec）、`f_jit/doc/optimize-compile-path.md:75-80`（测量协议：MOV、5 次、≥2% 回退、全量零失败）、`:93-96`（停止条件）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：同一套规则两处措辞、字面量复制）
- **证据**：静态确定 —— 两份文件各自定义 `MOV = max(3%, 2×离散度)`、5 次取中位数、其它指标回退 ≤2%、全量零失败；差异：call-path 给 `PerfOverride_test` 高负载假失败豁免（「单跑 3 次至少 2 次通过」，`:24`）并要求 ≥8 物理核复测（`:26-27`），compile-path 两者都没有
- **描述**：同一治理规则写两遍，已经出现实质漂移：按 compile-path 的口径，`PerfOverride_test` 在共享机上的假失败会直接否决改动；按 call-path 的口径则允许保留。两个台账对「达标」的定义不一致，跨文档比较结论时会冲突。
- **建议**：抽一份 `doc/optimize-protocol.md`（或让 compile-path 直接引用 call-path §1/§2.2），只保留「编译路径特有」的部分（如同进程 A/B、双峰分峰比较），并显式说明假失败豁免是否适用于编译路径。

### [轻微][存量] 两个后端的发射审计表用两套隔离机制（A64 实例字段 / x86 `ThreadLocal`），且 §8 的「改为 ThreadLocal」已被 §12 取代但未标注历史

- **位置**：`f_jit/doc/optimize-compile-path.md:120-129`（§8 C0「`A64Emitter.noteMemBase` 的 `ArrayList.add`……改为 `ThreadLocal`」）、`:275-283`（§12.1「`A64Emitter.auditTls`（`ThreadLocal<ArrayList<Int64>>`）→ 实例字段 `audit`」）、`:351-353`（§14.2「选 ThreadLocal 而非实例字段，是因为 x86 的发射助手是静态函数、`EmitAudit_test` 也依赖静态采集 API」）
- **来源**：存量
- **判据**：review-checklist §2（同一能力两套实现）、§13（被取代的表述未标注）
- **证据**：静态确定 —— A64 侧现为实例字段 `private let audit: ArrayList<Int64>`（`f_jit/src/backend/A64Emitter.cj:460`，`resetAudit`/`auditSnapshot` 为实例方法 `:466-470`）；x86 侧为 `private static let auditTls = ThreadLocal<ArrayList<Int64>>()`（`f_jit/src/backend/BackendSelector.cj:258`）
- **描述**：同一「审计表生命周期 = 一次 `compileOnce`」的不变量，一处靠对象生命周期、一处靠线程生命周期；§12.2 已实测实例字段「严格更少工作」但没收益，§14.2 仍以「静态助手」为由保留 TLS，两处理由并列但没有统一裁定。§8 的「改为 `ThreadLocal`」在 A64 侧已不成立，却没有任何历史标注。
- **建议**：在 §8 该条加「已被 §12 取代（A64 改实例字段）」；补一句统一口径「审计表隔离优先用实例字段，仅在发射助手必须为静态时用 `ThreadLocal`」，并把 x86 的静态助手迁到实例作为后续项（需先测）。

### [轻微][存量] m3 §11 未记录 JSON 常量的 16 MiB 与空串拒绝上限，读者按规格会以为只受 `u32` 长度约束

- **位置**：`f_jit/doc/jit-bytecode-m3.md:231`（「发射常量引用：kind 11 = Json（payload = **u32 长度** + UTF-8 原始字节串）」）、`:236`（加载期「防御性再校验失败 → 加载期拒绝」）、`:224`（常量/运行期构造的区分）
- **来源**：存量
- **判据**：review-checklist §13（限制条件缺失）、§5（资源上限未文档化）
- **证据**：静态确定 —— 拼装期硬拒绝「JSON 常量载荷为空」「超长 > 16 MiB」（`f_jit/src/bytecode/ConstRegistry.cj:258-268`），加载期另有长度一致性校验（`:620-631`）；m3 §11 全文无 16 MiB 与「空串必拒」的记载
- **描述**：`u32` 上限是 4 GiB，但实际可用上限是 16 MiB，且空 JSON 字面量（`` `` ``）在两个阶段都被拒。作者按规格写大 JSON 字面量时会在编译期拿到「超长」而不是 §11 描述的「加载期拒绝」，错误面与文档不符；OOM 面因此是有界的（好事），但边界没写在契约里。
- **建议**：§11「编译期」条补「常量载荷 1 B–16 MiB（空串与超长在拼装期拒绝，码 18）」，并在 §10 T41 的负向集里加一条超长用例。

### [一般][存量] §11/T61 的 `json_set` 写值域仍写「值型 0–3」，实现与前端已收窄为 Int64/Bool/String/JSON 节点，Float64 编译期拒绝

- **位置**：`f_jit/doc/jit-bytecode-m3.md:268`（§11「写（H82 `json_set`；变更型）：`v` ∈ 值型 **0–3**（Unit 除外）/ String / JSON 节点（码 16–19）」）、`:194`（T61「写值域（值型/String/JSON 节点……）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）、§11（契约与实现不符）
- **证据**：静态确定 —— 前端 `checkJsonWriteValue` 只接受 `LocalType.I64` / `BOOL` / `STRING` / `16–19`，Float64 直接 `diagFail`，消息明写「JSON 无二进制浮点」（`f_jit/src/compiler/Lowerer.cj:1927-1943`）；运行期 `jsonValueOf` 也只分派 `0 / 2 / 4 / 16–19`，Float64（1）与 Decimal（5）落 `case _ => 8`（`f_jit/src/runtime/JsonHelpers.cj:136-154`）。用例把裁定写死了：「收窄为 `Int64 / Bool / String / JSON 节点`，**Float64 编译期拒绝**」（`f_jit/src/compiler/A7JsonSet_test.cj:28-41`），并断言 `1.5f64` 与 `2.5` 都报 `TYPE_MISMATCH`（`:33-41`）
- **描述**：`0–3` 去掉 Unit 就是 `Int64 / Float64 / Bool`，按规格 Float64 是可写值，实际是编译错误。`A7JsonSet_test` 的标题就是「值域在**规格 / 前端 / 运行期**三处一致」，但规格这一方没有随 P3-3 收窄——三方一致性只剩两方。用户按 m3 §11 写 `o.k = 1.5` 会拿到与文档相反的拒绝，且 T61 仍写「值型」而非具体集合，无法从测试矩阵看出边界。
- **建议**：§11 与 T61 统一改为「Int64 / Bool / String / JSON 节点（Float64/Decimal 编译期拒绝：JSON 无二进制浮点；小数写 JSON 字面量或字符串）」；T61 负向集补 Float64/Decimal 两条，与 `A7JsonSet_test` 对齐。

### [轻微][存量] m3 的 helper 编号沿革注记三处互相矛盾（「接 H65」「原 H72–H82」「H72/H81/H82」），与 H69–H83 的实际占位不符

- **位置**：`f_jit/doc/jit-bytecode-m3.md:103`（「编号接 H65——H78–H80」）、`:14`（版本行「v0.3.12 再 +3 helper：**原 H72–H82**；v0.3.15 顺延为 H81–H83」）、`:3`（v0.3.12 条「+3 helper（**H72** `json_get` / **H81** `json_set` / **H82** `json_new`）」）、`:272`（「编号顺延——H72 已被 M1 v0.18.19 的 `regex_replace_range` 占用」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部不一致 / 编号引用过期）
- **证据**：静态确定 —— 实际占位：H66–H68 保留、H69–H72 为 M1 v0.17/0.18 的 `str_to_regex/list_new/map_new/regex_replace_range`、H73–H76 时间构造、H77 `cast_fail`、H78–H83 为 M3（`f_jit/src/runtime/HelperId.cj:69-112`）。H72 确实是 `REGEX_REPLACE_RANGE`（`:112`），所以「接 H65」既跳过 H66–H77，也与 H78 的实际起始不符；「原 H72–H82」是 11 个编号，不可能是「+3 helper」；v0.3.12 条又把 `json_get/json_set/json_new` 写成 H72/H81/H82（应为连续的 H72–H74，v0.3.15 后为 H81–H83）
- **描述**：实现者按「接 H65」会从 H66 起编号，按 v0.3.12 条会得到不连续的三号；正文 §5/§11 虽然给出 H78–H83，但沿革注记没有一处能自洽地解释为什么是这六个数。
- **建议**：统一为一句「M3 顺延为 H78–H80；JSON 面 H81–H83（v0.3.15 自 H72–H74 顺延，H72 已被 `regex_replace_range` 占用）；H66–H68 保留、H69–H76 为 M1 扩展、H77 `cast_fail`」，并把版本行的「原 H72–H82」改为「原 H72–H74」。

### [轻微][存量] §4/附表的「§2 错误码映射 1–22」遗漏已登记的 23（`ERR_CONCURRENT_MOD`）

- **位置**：`f_jit/doc/jit-bytecode-m3.md:97`（「§2 错误码映射 `1–22`」）、`:370`（附表「§2（映射 1–22）」）、`:373`（「§2 映射 1–22」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部不一致）
- **证据**：静态确定 —— 文档 §2 自己的错误码行已写「0–21、**23** / -1 / -2 / 99」，M3 只追加 22（`:61`）；实现 `ErrCode.CONCURRENT_MOD = 23` 且 `describe` 有 `case 23`（`f_jit/src/base/ErrCode.cj:87`、`:124`）
- **描述**：§2 的集合含 23，实施注记却把映射范围截到 22，照注记实现会漏掉 23 的描述/分支；三处同错说明是同一个过期模板。
- **建议**：三处统一改为「映射 `1–23`（含 M2 的 23 `ERR_CONCURRENT_MOD`）」。

### [轻微][存量] §9.1/§13.5 引用的探针目录 `.autocode/tmp/p2probe`、`.autocode/tmp/argcprobe` 已不存在，「可重跑」不可兑现

- **位置**：`f_jit/doc/jit-bytecode-m3.md:159`（「探针 `.autocode/tmp/p2probe/`，`run_all.sh` 一键重跑」）、`:348`（「探针 `.autocode/tmp/argcprobe/`，可重跑」）
- **来源**：存量
- **判据**：review-checklist §13（链接/路径失效、证据不可复现）
- **证据**：静态确定 —— 两个目录均不存在（`ls .autocode/tmp/p2probe` / `argcprobe` 均 No such file or directory；`.autocode/tmp` 下只剩其他历史文件）。P2 结论（`:155-169`）与 N=4 阈值（`:348`）都以这两组探针为唯一原始证据
- **描述**：文档把两个关键实测（「泛型实参参与运行期判定」「argc ≤ 4 占 99.7%」）标成可一键重跑，实际只剩结论数字；后续若要复核 P2 是否仍成立（换 SDK/平台），没有可执行的入口。
- **建议**：把探针脚本收进 `f_jit/scripts/`（可复现），或按 `optimize-call-path.md` 的写法标注「临时探针，已删除，数据留档」并给出复现步骤而不是死路径。

### [轻微][存量] §5 的 aux 规则写「其余类型 0xFFFF」，与 §3/§12 的「14 目标 aux=typeRef」及实现（`$as$<C>` 的 hid）不一致

- **位置**：`f_jit/doc/jit-bytecode-m3.md:111`（「`aux` = 容器附加码——List(10)……Map(11)……**其余类型 aux = 0xFFFF**」）、`:81` / `:284`（14 目标「转换点携类身份（`typecode=14 + aux=typeRef`）」）
- **来源**：存量
- **判据**：review-checklist §13（同文档内描述符规则互相矛盾）、§11（按 §5 实现会弱化类界）
- **证据**：静态确定 —— 前端 `auxOf` 对 `HOST_OBJECT` 目标是取 `$as$<类名>` 的 helper id，只有取不到类名才回退 `0xFFFF`（`f_jit/src/compiler/Lowerer.cj:2664-2689`）；运行期 `anyMatches` 的 14 分支把 `aux` 当 `$as$<C>` 的 hid 用，`0xFFFF` 是「任意非 JSON 宿主对象」的兼容口径（`f_jit/src/runtime/AnyHelpers.cj:159-161`）。§5 的规则只给 List/Map 开了口，按字面实现会对 14 也发 `0xFFFF`
- **描述**：`0xFFFF` 在 14 上不是「无附加信息」，而是**关闭类界校验**；§5 把它写成所有非容器的默认值，与 §3「无继承关系不得转型」和 §12「任意 HostObject 不开放」直接冲突。实现用 `$as$` hid 而不是文档说的 `typeRef`，命名也对不上。
- **建议**：§5 表格改为「List → 元素码；Map → `(键码<<8)|值码`；14 → `$as$<C>` 的 hid（取不到类名时 `0xFFFF` 兼容口径，仅限无法携带类名的调用点）；其余 → `0xFFFF`」，并在 §3/§12 把「typeRef」改成与实现一致的「`$as$<C>` helper id」。

## 优化可行性方案

> 本部分只有规格与优化台账，无源码可改；且这四篇文档自身已明确「剩余开销进入测量分辨率以下」（`optimize-call-path.md:635-639`）。按铁律，没有改前基线 + 改后对照的方案不写成结论，本部分不产出堆内存 / CPU 方案。

（0 条堆内存方案 / 0 条 CPU 方案）

## 待验证假设

> 没有本部分代码的性能数据支撑，以下均不计入统计、不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ti` 惰性化后，无 adapter 的宿主闭包**每次回调**都做一次 `FunctionTypeInfo.of`（含 std 反射元数据缓存争用），回调循环会比改动前更慢 | `f_jit/doc/optimize-call-path.md:498-512` | 回调循环的 ns/次对照（改前/改后）、`FunctionTypeInfo.of` 自耗时占比 | 用 `HostClosureAdapter_test` 同款 5 万次回调单元、**不登记 adapter**，A/B 各 5 轮取中位数；`cjprof record` 看 `FunctionTypeInfo.of` 自耗时与线程状态 |
| 2 | 签名表超 128 条后每次调用重建 `SignaturePlan` + 写锁 + 快照分配，形成延迟台阶 | `jit-bytecode-m3.md:314` | 第 128/129… 个签名的单次 `getOrBuild` 与端到端 `call` 耗时 | 注册 127/128/200 个不同签名，各跑 1e5 次 `getOrBuild` 与 `call`，埋点 `entryCount`/`buildCount`，对比中位数与 P99 |
| 3 | 按当前实现复跑 aarch64 `PerfCompare_test`，JIT 单轮成本将远低于 200 ns/轮（回边 safepoint 修复后） | `f_jit/doc/perf-m1.md:8-17` | 修复后的 JIT / cjnative / 解释器三侧 5 轮耗时 | 同 SDK `-O2`、同机器复跑 `cjpm test --filter PerfCompare_test --no-capture-output`，5 次取中位数与离散度 |
| 4 | `perf-m2` 的 4.63×/5.75× 在现行用例（4000 次 × 3 轮中位数 + `MonoTime`）下会与旧值有系统偏差 | `f_jit/doc/perf-m2.md:13-21` | 现行用例的 `PERF-M2` 输出（三比值 + 单次 ns） | 跑 `cjpm test --filter PerfM2_test --no-capture-output`，收集 5 次 `PERF-M2 round*` 行，比对 4.63×/5.75× |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/jit-bytecode-m3.md` | .md | ✅ | 376 行全文（含第 3 行 10 992 字符的版本变更长行，分段读完）；与 `AnyHelpers`/`SignaturePlan`/`HostCall`/`ConstRegistry`/`LocalType`/`ErrCode`/`HelperId` 及 T39/T56/T61 用例逐条对照，见发现 #1–#3、#8–#9、#11、#17–#22 |
| 2 | `f_jit/doc/optimize-call-path.md` | .md | ✅ | 641 行全文；与 `HandleTable`/`JitContext`/`Signature`/`SignaturePlan`/`HostCall`/`JitFunction`/`CallMarshal`/`ParallelThroughput_test` 对照，见发现 #6–#7、#12–#13、#15 |
| 3 | `f_jit/doc/optimize-compile-path.md` | .md | ✅ | 358 行全文；与 `A64Emitter`/`BackendSelector`/`A64AuditIsolation_test`/`X86AuditIsolation_test` 对照，见发现 #14–#16 |
| 4 | `f_jit/doc/perf-m1.md` | .md | ✅ | 40 行全文；与 `PerfCompare_test` 对照，见发现 #4 |
| 5 | `f_jit/doc/perf-m2.md` | .md | ✅ | 173 行全文；与 `PerfM2_test`/`PerfAdapter_test`/`PerfOverride_test`/`design-m2.md` GAP-13 对照，见发现 #5、#10–#11 |

合计：`.cj` 0 个 / `.md` 5 个 / 共 5 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性=容器转型与容器类型判定（#1）；设计=`SignatureTable` 作用域与开关（#2/#3/#8）；语言特性=「泛型实参参与 `is` 判定」已按 §9.1 实测结论核对，但「键型可判」不成立（#1）；可读性=索引/行号/模板残留（#13/#14）；安全性=Any 沙箱的类型边界被弱化（#1） |
| §1 死代码 | 0 | 本部分无 `.cj`，无 `private/internal/protected/public` 符号可判。文档侧逐节核对「承诺后未接线」：§12/§13 的每条裁定都能在 `src/` 找到落点（H78–H83、LocalType 16–19、`SignatureTable`、`MAX_ENTRIES`、T56/T61 用例），唯一缺口是缺失的测试护栏（记在 §14）。另记一条范围外提示：`CallMarshal.makeRetUnboxer`（`f_jit/src/CallMarshal.cj:187-189`）位于 `protected class` 内、只有测试调用，文档也自述「保留给测试」——属可见性问题，不按死代码计 |
| §2 重复逻辑 | 2 | 两份 `optimize-*.md` 重复定义同一套实验硬规则且已漂移（#15）；A64/x86 审计表两套隔离机制（#16）。文档内 `PublicField` 类重复已在上部分（part5）报过，本部分不重复计 |
| §3 空实现 | 0 | 五篇文档无 `TODO/FIXME/throw Unsupported`；§4 决策日志的空 C3 行是模板残留，计在 #14，不按「空实现」计 |
| §4 栈溢出 | 0 | 本部分无递归/自引用结构描述；m3 §13 的 H63 重入链已在 part5（m2 规格）报过，本部分不重复计 |
| §5 OOM | 1 | 无无界增长：JSON 常量有 16 MiB + 空串硬拒（`ConstRegistry.cj:258-268`），签名表有 128 上限。命中项是「上限未写进文档」（#17） |
| §6.1 热点瓶颈 | 0 | 文档内的性能结论都自带测点（`cjprof`/分段计时/同进程 A/B）。本部分未给出可复核数据的新热点只有 #7 的成本转移，已降为「待验证假设 #1」，不作发现 |
| §6.2 大粒度锁 | 0 | 台账已逐项拆锁（HostFault TLS、字段快照、句柄分片、签名两表、helper 表缓存），未见「锁内 I/O/回调」类描述；`SignatureTable.writeMtx` 内只做数组拷贝与发布 |
| §6.3 并发串行 | 0 | 已核对 `spawn` 用法（`ParallelThroughput_test` 先提交后统一 `get()`），无「spawn 后立刻 get」形态 |
| §6.4 低效算法 | 0 | 台账已覆盖线性扫标签、逐字节搬运、字符串键索引等，并给出「小表线性扫更快」的实测反证（`optimize-call-path.md:479-491`） |
| §7 降堆内存方案 | 0 | 无源码可改；plan 表 ≤128 条、helper 表按单元缓存，均已有界，无「缩短生命周期/去副本」的量化空间 |
| §8 降 CPU 方案 | 0 | 台账结论为「进入测量分辨率以下」（`optimize-call-path.md:635-639`）；本轮未取得新的同环境 A/B 数据，不产出方案 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时大对象；台账里每次调用的 `Win`/`Array<Any>` 属桥接层，改造收益只能用峰值内存证明，缺数据 |
| §11 现有代码的 BUG（存量） | 22 | 全部为「文档承诺 vs 实现/测试」类存量问题：#1–#22，均标 `[存量]`（快照模式无 baseline） |
| §12 并发安全与锁粒度 | 1 | `SignatureTable.enabled` 是进程级非原子开关、在每次 `getOrBuild` 上读，并发切换语义未定义（#3）。其余共享点（字段表、签名表快照、句柄分片）均为原子快照/双检发布，已核 |
| §14 功能完备性与 README 覆盖 | 3 | 承诺的容器键值校验未实现（#1）；T56 的构建计数断言在超限后失效（#2）；`ParallelThroughput_test` 的 `isJitBacked` 断言未落地（#6）。本部分无模块 README，未做 README 覆盖对照 |
| 文件覆盖（§13 等） | 5/5 | 5 个 `.md` 全部逐行读完；`jit-bytecode-m3.md:3` 的 10 992 字符变更行分段读取，无遗漏 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 14 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 22 条（含轻微），是否纳入修复待用户决定。

## 总评

本部分没有源码，风险集中在**规格与实现的最后一公里**和**性能台账的可复核性**。

最需要处理的是 m3 §5/§9.1/T39 的容器转型承诺：文档冻结了「元素/键值校验」，实现里 Map 键型**完全没有校验**（`ConstMapKey` 擦除），List 也只认 `Any` 元素，测试只锁了值码。后果不是崩溃，而是 `is`/`as` 的答案与契约相反（`Map<Int64,Any>` 被判成 `Map<String,Any>`），后续按键访问落成「缺键」或混键表——这是 Any 沙箱类型边界上唯一一条明确的缺口，建议按严重处理并二选一（收窄文档 / 加键码 tag）。

第二处会直接绊住使用者的是 m3 §11 的 `json_set` 写值域：规格仍写「值型 0–3（Unit 除外）」，把 Float64 算进可写域，而前端 `checkJsonWriteValue` 与运行期 `jsonValueOf` 都只收 Int64/Bool/String/JSON 节点，`A7JsonSet_test` 也已按「Float64 编译期拒绝」立了用例——规格是「规格 / 前端 / 运行期三处一致」里唯一没改的一方。按文档写 `o.k = 1.5` 会拿到编译错误，建议与 #1 一并修正规格文本并补 T61 负向用例。

`SignatureTable` 的三处偏差（128 上限未文档化、`enabled` 非原子、作用域写成「桥实例级」）属同一族：实现已经引入了文档没有的进程级可变状态与容量上限，而 §13 的「天然有界、无需淘汰」「读路径无锁」正好在这三点上失真；修文档即可，代价低。

性能台账方面，`perf-m1` 的 aarch64 基线已被 `optimize-loop-safepoint`（同一台机器、空循环 662→15 ns/轮）实质推翻却仍以现役基线示人；`perf-m2` 的次数/单位/换算三者互斥，按文档方法跑不出文档数字。这两处是「后来者会被带偏」的地方，优先在文档层修正；`optimize-call-path` §15.4 的 `ti` 惰性化则是一个尚未记录的成本转移（`TypeInfo.of` 从每条目一次变成每次回调一次），已放进待验证假设等数据，不写成结论。

其余是索引与治理层的瑕疵：两份台账重复定义实验规则且已漂移、行号与状态摘要过期、决策日志残留空行、`AdapterRegistry` 的 UAF 论证对象实际上没有生产调用点。这些不影响产品行为，但会让下一轮性能工作从错误的基线和错误的规则出发，建议与上述文档修正一并排期。
