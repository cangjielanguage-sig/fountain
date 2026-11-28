# f_jit 模块审查报告（第 20/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src` 根包（本部分 5 个 `.cj`）+ `f_jit/doc/spec/**`（本部分 15 个 `.md`），共 20 个文件
- **基线**：工作区快照（master 与 sts/1.3.x 同提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**（f_jit 专项）：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（本文件是 `parts/` 分部分报告，合并结果由主 Agent 写入 `docs/review/2026-11-28/f_jit_v2.md`）

## 发现

### [一般][存量] `AdapterRegistry` 生产路径零接线：整类只在测试里被调用，`size()` 连测试都不用

- **位置**：`f_jit/src/AdapterRegistry.cj:27`（类声明）、`:33`（`register`）、`:50`（`lookup`）、`:58`（`removeUnit`）、`:74`（`size`）
- **来源**：存量（`git blame` 显示 `048fb7624f 2026-10-18` 引入类，`328c7d32e1` 引入字段）
- **判据**：review-checklist §1「注册了但永不触发」「非 public 顶级声明里的成员无使用即死代码」+ §14.1「接线缺失」
- **证据**：静态确定 ——
  1. 全仓（排除 `.worktrees`）`grep -rn "AdapterRegistry" --include=*.cj` 仅命中 `AdapterRegistry.cj` 自身、`AdapterRegistry_test.cj`、`Root.cj:21`（注释）三处，**没有任何生产代码写入或读取**；
  2. `design-m1.md:862` 把 `AdapterRegistry` 定义为「`(单元指纹, fnId, T)` → 单态化适配器」，`design-m1.md:915` 写明调用关系是「call 第 5 步；卸载」，`design-m1.md:961` 写「跨模块/动态 → AdapterRegistry 运行期校验 → 19」；
  3. `size()`（`:74`）在测试与生产代码中均无调用者 —— 属于「protected 类里的 public 成员，全项目无使用」。
- **描述**：`protected class` 对外不可见，其 `public` 成员只是包内放宽。该注册表当前完全靠 `AdapterRegistry_test.cj` 自证：测试注册、测试查找、测试移除，生产路径（`Compiler.compile` / `JitFunction.call` / `unload`）一次都没接线。对照 `design-m1.md:961`，`call` 第 5 步的「跨模块/动态 T 一致性运行期校验」实际由别处完成（`CallMarshal`/`isInstanceOfHost` 等），本类没有承担其设计的职责。
- **建议**：二选一并写清结论 ——（a）按设计接线：在 `call` 第 5 步失败分支与卸载终态各调一次 `register`/`removeUnit`；（b）确认职责已由 `CallMarshal` 承担则删除本类与 `AdapterRegistry_test.cj`，同步 `design-m1.md:862/915/961` 的描述。无论哪种，都应补 `resetForTest()`——同包的 `SignatureRegistry` 已有同名复位钩子（`HostClosureAdapter_test.cj:62` 处约定「每个用例结束都要 resetForTest」），本类缺这个钩子，正是它测试污染的原因（见下一条）。

### [一般][存量] 根包再导出缺 `CallContext` 与 `InterruptedException`，而二者都在 public 调用契约里

- **位置**：`f_jit/src/Root.cj:23-46`（再导出清单，缺这两项）；契约侧 `f_jit/src/JitFunction.cj:159`（`public func call<T>(args: Array<Any>, options: CallContext)`）、`f_jit/src/JitReport.cj:41`（`throw InterruptedException(...)`）
- **来源**：存量（`Root.cj` 与 `JitFunction.cj` 均为既有文件，快照无 diff）
- **判据**：review-checklist §13（文档承诺与实现不符）+ §14.1（公开 API 能力接不上）
- **证据**：静态确定 ——
  1. `design-m1.md:923` 明确承诺 `public import fountain::f_jit.base.*` 再导出含 `CallContext`（原文列举「…SourcePos、CallContext、SourceUnit…」）；
  2. 实际 `Root.cj:23-46` 是逐项 `public import`，清单里没有 `CallContext`，也没有 `InterruptedException`（`grep "^public import" f_jit/src` 全量 19 行，无此二者）；
  3. 仓内用例已实证该缺口：`AnyBridgeCall_test.cj:22` 必须额外写 `import fountain::f_jit.base.CallContext` 才能调用带选项的重载。
- **描述**：下游只写 `import fountain::f_jit.*` 时，无法构造 `CallContext(deadline: …)`，也就**用不了** `call<T>(args, CallContext)` 这条公开重载（deadline 中断是本模块对外承诺的能力）；`deadline` 到期抛出的 `InterruptedException`（`JitReport.cj:41`，类定义 `base/InterruptedException.cj:26`）同样无法按名捕获，只能退化成 `catch (e: Exception)`。这与 `design-m1.md:27`「`import fountain::f_jit.*` 后能做编译 → 调用 → 卸载」的目标直接冲突。`SourceUnit` / `TypeToken` / `Version` 也在设计清单里但当前没有公开签名承载（`Compiler` 只剩 `compile(source: String)`，`CompileOptions.verMajor` 是 `UInt16`），故只报 `CallContext` / `InterruptedException` 两项确有后果的缺项。
- **建议**：在 `Root.cj` 补 `public import fountain::f_jit.base.CallContext` 与 `…base.InterruptedException`（并补一条只导根包的用户面用例，参照 `surface/FacadeSurface_test.cj` 的做法）；若刻意不导出，则改 `design-m1.md:923` 与 `doc` 的表述，别让文档承诺与可见性相反。

### [一般][存量] `BaseVisibility_test` 无法验证它自称守护的「再导出清单不缺项」

- **位置**：`f_jit/src/BaseVisibility_test.cj:20`（`import fountain::f_jit.base.*`）、`:28-31` 与 `:36-41`（自述目的）
- **来源**：存量
- **判据**：review-checklist §3（契约测试失效，等价「看起来能编译」）+ §13（文档/注释与实现不符）
- **证据**：静态确定 ——
  1. 文件头写「缺任一项本文件即编译失败」，但测试自己对 `base` 做了通配导入（`:20`），`CallContext`、`SourceUnit`、`TypeToken`、`Version`、`DiagCode` 等符号**无论根包是否再导出都能解析**，断言恒成立；
  2. 项目自己在别处已承认这一点：`f_jit/src/surface/FacadeSurface_test.cj:18-23` 的注释写「根包内的文件可以自己 `import …base.*`（那样测不出再导出缺失，**M1 的 `BaseVisibility_test` 正是如此**）」，并另建独立包做真正的用户面探针；
  3. 结果就是上一条的缺口长期未被这张「护栏」发现：`FacadeSurface_test` 只钉住注册协议 8 个符号，`CallContext` / `InterruptedException` 两边都没覆盖。
- **描述**：这条用例实际只证明「base 包里的这些声明存在且可用」，证明不了「根包把它们再导出了」。它守的是用户面冻结验收（S6.11），但目前是假绿；同时文件头 `:28-31` 的「用户面清单」已与 `Root.cj` 实际清单不符（少了 `DiagCode`、`DummyDiagnosticsSink` 与注册协议 7 个类型，多了实际未导出的 `CallContext`/`SourceUnit`/`TypeToken`/`Version`）。
- **建议**：把该用例迁到独立包（如 `surface`）并改成只 `import fountain::f_jit.{…}` 的显式列举，让缺项变成编译错误；文件头清单改为引用 `Root.cj` 而不再手抄一份。若保留在根包，则把注释改成「仅验证 base 声明可用」，别再声称守再导出。

### [一般][存量] 规格承诺「卸载中到达的同键编译会等待后重编」，设计与实现都不做

- **位置**：`f_jit/doc/spec/refine-f-jit-unload-api/specs/f-jit-facade-bridge/spec.md:49`（`SHALL`）；反证 `…/design.md:23-27`（D3 明确不在本次范围）、`…/verify.md:43-47`（已知边界）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」+ §14.1「承诺了但没实现」
- **证据**：静态确定 —— 规格原文要求「卸载期间到达的同键编译 SHALL **等待卸载完成后**按未命中重新编译并产出新句柄」；同一变更的 `design.md:25` 写「`state == 1`（卸载中）期间到达的同键编译，仍可能从缓存拿到正在卸载的单元并立即被 19 拒绝」，`verify.md:45` 重复同一结论并说明「要彻底解决需要给缓存项引入代次/状态维度」。即：规格的验收条款比落地范围宽，且**没有随范围收窄而改写**。同一句还镜像在 `doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md` 与 `doc/spec/jit-closure-unload-cascade/…/spec.md`（范围外，同根因）。
- **描述**：并发「卸载 + 同源编译」的窗口内，编译方会拿到一个正在卸载的单元并在调用时收到 19（契约类错误），而不是排队到卸载完成后拿到新单元。属**瞬态失败**，不是数据损坏；但按规格它是失败场景，按实现它是预期行为。两者不一致会让下一轮按规格写的验收用例必然红。
- **建议**：二选一——（a）把规格该句改成「**终态之后**到达的同键编译 SHALL 未命中重编；卸载中窗口内到达的编译 MAY 以 19 失败」，与 `design.md` D3 对齐；（b）立项做「缓存项代次/状态」维度，落地后再恢复现有 `SHALL`。别让 `SHALL` 长期悬空。

### [轻微][存量] `register` 对同一键重复登记会重复入 `units` 列表：与「同键覆盖；幂等」注释不符，`removeUnit` 计数虚高

- **位置**：`f_jit/src/AdapterRegistry.cj:40`（无条件 `list.add(k)`）、`:67`（`removeUnit` 返回 `list.size`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名/注释不符」+ §5「无界容器（潜在）」
- **证据**：静态确定 —— `register`（`:33-47`）对 `adapters[k]` 是覆盖写，但对 `units[u]` 是**追加**，没有去重；同一 `(fingerprint, fnId, tName)` 登记两次后 `units` 里就有两个相同 `k`，`removeUnit` 返回 2（实际只有 1 条适配器），列表也会随重复登记线性增长。
- **描述**：注释声称「注册（同键覆盖；幂等）」，覆盖与幂等只对 `adapters` 成立。若按设计接线到「每次调用前 pin 一次」的路径，重复登记会让 `units` 无界增长（§5 无界容器），`removeUnit` 的返回值也不再是「移除条数」。当前该类无生产调用者，故只按轻微计；一旦接线即升级为一般。
- **建议**：登记前先判 `list.contains(k)`，或把 `units` 的值换成 `HashSet<String>`；`removeUnit` 用「实际从 `adapters` 移除成功的次数」返回，而不是 `list.size`。

### [轻微][存量] `p0_6_deadlineRestoredAfterCall` 的空 `catch` 让用例在「根本没中断」时也能通过

- **位置**：`f_jit/src/AnyBridgeCall_test.cj:145-148`
- **来源**：存量
- **判据**：review-checklist §3「静默吞异常」+ 用例有效性
- **证据**：静态确定 —— `try { f.call<Int64>([Int64(100000000)], expired) } catch (_: InterruptedException) {}` 之后唯一断言是 `RuntimeEnv.deadlineNanos == -1`；若实现**压根没抛**中断（例如 −2 生产点回归），`f.call` 会跑完 1e8 次循环、`finally` 仍把期限恢复成 −1，断言照旧通过——用例名承诺的「内层调用（成功或中断）返回后期限恢复」中的「中断」分支没有被验证。
- **描述**：这条用例的设计意图（期限栈式恢复）只在「外层无期限 + 内层抛中断」这一组合下成立，而该组合恰由空 `catch` 抹掉了可观测证据。「中断确实发生」目前只由另一条用例 `p0_6_deadlineInterruptsLoop`（`:120-134`）覆盖，本用例的回归价值因此打折。
- **建议**：`catch (_: InterruptedException) { interrupted = true }` 后 `@Assert(interrupted, true)`；或把内层调用改成有界次数 + 断言抛出类型与 site。

### [轻微][存量] 三个用例文件对全局静态状态无复位或复位不彻底

- **位置**：`f_jit/src/AdapterRegistry_test.cj:77-78`（只移除 `100`/`103`，`101`/`102` 留在静态表里）；`f_jit/src/AnyHostCast_test.cj:100`（`HandleTable.resetForTest()` 清空全局句柄表且无 `finally` 恢复）、`:121-122`（对全局 `slotCount`/`liveCount` 断言）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态）+ 用例可重复性
- **证据**：静态确定（残留事实）；「是否真导致 flaky」需实测 —— 未知 CI 上 `cjpm test` 的 `--parallel` 取值
- **描述**：`AdapterRegistry` 没有 `resetForTest()`（同包 `SignatureRegistry` 有），用例只能靠「删掉自己造的键」收尾，`concurrentRegisterAndLookup` 漏了 `101`/`102` 两个指纹；`AnyHostCast_test` 则整体清空进程级 `HandleTable`（`resetForTest` 会把 `totalSlots` 复位为 1，`HandleTable.cj:1307`），若与持活句柄的用例并发执行，会造成假失败或假通过。当前项目默认 `--parallel 1`（`doc/spec/test-f-jit-parallel-calls/design.md:36`），所以现实风险低。
- **建议**：给 `AdapterRegistry` 加 `resetForTest()` 并在每条用例的 `finally` 里调用；`AnyHostCast_test` 的全局复位改为用例级独立上下文（或统一在 `@BeforeAll/@AfterAll` 复位），并把并行度假设写进用例注释。

### [轻微][存量] 两份 spec 目录内的统计口径互相冲突（变异结论、改名处数）

- **位置**：`f_jit/doc/spec/optimize-type-cache/verify.md:44-49` 与 `…/tasks.md:32-36`；`f_jit/doc/spec/refine-f-jit-unload-api/proposal.md:29`、`…/test-plan.md:12`、`…/tasks.md:5`、`…/verify.md:15-22`
- **来源**：存量
- **判据**：review-checklist §13（同一变更内文档自洽性）
- **证据**：静态确定 ——
  1. `optimize-type-cache`：`tasks.md:35-36` 写变异「`refEq` 恒 true ⇒ `alternatingTypesDoNotCross` ERROR，已恢复，重跑绿」，而 `verify.md:49` 同一变异写「待补（见下）」，且文中并无「见下」小节（§5 直接是「影响文件」）；`design.md:36-38` 的护栏描述用 `Int64` vs `Probe`，`verify.md:40` 用 `Int64` vs `Bool`。
  2. `refine-f-jit-unload-api`：同一个「`close()` 改名处数」有四个值 —— `proposal.md:29`=18、`test-plan.md:12`（16 处 + 3 条具名）=19、`tasks.md:5`=20、`verify.md:15-22` 表内合计 21。
- **描述**：结论型文档（tasks / verify）对同一实验给出相反状态，会让下一轮「按 verify 补数据」重复劳动；改名处数的四个值使「剩余调用点是否清零」无法机械核对。两处都不影响代码行为。
- **建议**：以 `verify.md` 为唯一结论源，`tasks.md` 只勾选状态；改名处数统一取 `grep -c` 的实测值并注明统计命令。注：`refine-f-jit-unload-api` 的 `unloadFn` 旧名属归档惯例（`align-jitfunction-close-naming/verify.md:16` 已说明历史归档不回改），**不判**。

## 优化可行性方案

> 不是缺陷，是"还能更好"。下列两条都**没有**改前基线 + 改后对照，只能作为下一轮补数据的候选。

### [CPU] `AdapterRegistry` 的字符串键改为结构化键

- **现状**：`key()`（`AdapterRegistry.cj:80-82`）每次 `register` / `lookup` 都做一次三段插值，生成 `"fp/fnId/tName"` 新 `String` 再哈希；`units` 的键又是 `'${fingerprint}'` 的第二次插值（`:38`、`:59`）。若按设计接到 `call` 第 5 步，每次调用 = 2 次字符串分配 + 2 次长串哈希。
- **方案**：键改成 `(UInt64, UInt32, String)` 元组或 `struct AdapterKey { fingerprint, fnId, tName }`（`hashCode`/`equals` 手写，只对 `tName` 做哈希），`units` 用 `HashMap<UInt64, ArrayList<AdapterKey>>` 省掉一次插值。
- **预期**：单次 `lookup` 少 1–2 次堆分配与一次串哈希；绝对值未测。
- **代价**：`HashMap` 键类型变更（`std.collection` 对元组/自定义类型的 `hashCode` 要求需现场核对）；`removeUnit` 的列表元素类型跟着变。
- **验证**：接线后 `cjpm bench -O2`，同输入 50k 次 `call<注册类>`，中位数 + 离散度对照；`cjprof record` 看 `AdapterRegistry.lookup` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `units` 列表去重 + 容量上限

- **现状**：`units` 每个单元一条 `ArrayList<String>`，元素为完整键串；`register` 重复登记会重复追加（见「发现」第 5 条），删除只发生在 `removeUnit`，没有容量上限。
- **方案**：值改 `HashSet<String>`（或在 `add` 前 `contains`）；`units` / `adapters` 加总条数上限（复用 `design-m1` 的 `maxPredefined` 风格常量），超限走「不登记、照常走原路径」的降级（与 `RuntimeState.typeCodes` 的 32 条上限同构，`doc/spec/optimize-type-cache/design.md:20-25`）。
- **预期**：稳态条目数 = 存活单元数 × 调用点 T 数，重复登记不再线性膨胀；具体字节量取决于单元数，未测。
- **代价**：超限后 `lookup` 恒未命中 → 走慢路径（语义不变）；需要新增一个「当前条数」诊断入口。
- **验证**：多轮「编译 → 卸载」循环下 `getAllocatedHeapSize()` + `AdapterRegistry.size()` 是否回到基线（`mem §1.2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 若 `AdapterRegistry.lookup` 接到 `call` 第 5 步，全局 `Mutex` + 字符串键会成为并发调用的串行段 | `f_jit/src/AdapterRegistry.cj:50-55` | 临界区持有时间、锁等待占比、并行度上限 | 接线后 `cjprof record` 跑 4 线程 × 50k 次 `call<注册类>`，另取线程状态（BLOCKED 时长）；CPU profile 看不到锁竞争，需线程状态证据 |
| 2 | `HandleTable.resetForTest()` 在 `--parallel > 1` 下会让并行用例互相干扰（假失败/假通过） | `f_jit/src/AnyHostCast_test.cj:100`、`f_jit/src/runtime/HandleTable.cj:1276-1307` | 并行度 > 1 时的失败率 | `cjpm test --parallel 4` 连续 20 轮，统计 `AnyHostCast_test` / 依赖句柄的用例失败次数 |
| 3 | `AdapterRegistry.register` 的重复登记在真实接线后会造成条目数随重编线性增长 | `f_jit/src/AdapterRegistry.cj:40` | 同一 `(fp, fnId, tName)` 的实际重复登记次数 | 接线后加计数埋点，跑「编译 → 卸载 → 同源重编」100 轮，观察 `units` 元素数与 `size()` |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jit.part20.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/optimize-type-cache/design.md` | .md | ✅ | D1–D5 与实现路径一致（`RuntimeState.typeCodes` ≤32、refEq 键、None 不缓存）；D5 护栏描述与 `verify.md:40` 的用例名/类型对不上（见发现「统计口径」） |
| 2 | `f_jit/doc/spec/optimize-type-cache/proposal.md` | .md | ✅ | 收益口径（−1.5 µs / −27%）在 `verify.md` 有 A/B 支撑，属「已有基线」；方案里 `public func typeCodeOf` 写作 public，实际落地为 `internal`（实现更严，不算缺陷） |
| 3 | `f_jit/doc/spec/optimize-type-cache/tasks.md` | .md | ✅ | C6.3「归档；提交」未勾选 ⇒ 该变更仍为活动态，其内部矛盾按 §13 计（见发现「统计口径」） |
| 4 | `f_jit/doc/spec/optimize-type-cache/verify.md` | .md | ✅ | §4 变异「恒 true」写「待补（见下）」且无「见下」小节，与 `tasks.md:35-36` 已实测冲突 |
| 5 | `f_jit/doc/spec/refine-f-jit-unload-api/design.md` | .md | ✅ | D3 自认「卸载中窗口」未解决，与同目录 `spec.md:49` 的 `SHALL` 冲突（见发现） |
| 6 | `f_jit/doc/spec/refine-f-jit-unload-api/proposal.md` | .md | ✅ | 「仓内调用方只有测试（18 处）」与 tasks/verify 的 20/21 不一致（见发现「统计口径」）；`unloadFn` 旧名属历史归档惯例，不判 |
| 7 | `f_jit/doc/spec/refine-f-jit-unload-api/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | `:5` 的 `unloadFn` 旧名不判（`align-jitfunction-close-naming` 已对齐主规格）；`:49`「等待」条款未实现（见发现） |
| 8 | `f_jit/doc/spec/refine-f-jit-unload-api/tasks.md` | .md | ✅ | H1.1 处数 20 与 proposal/verify 冲突 |
| 9 | `f_jit/doc/spec/refine-f-jit-unload-api/test-plan.md` | .md | ✅ | 「其余 16 处」与 verify 的 21 处冲突；`unloadTimeoutKeepsCacheEntry` 明确「未自动化」并给了代码结构依据，属有意取舍 |
| 10 | `f_jit/doc/spec/refine-f-jit-unload-api/verify.md` | .md | ✅ | 逐出时机表（终态逐出 / 超时不逐出 / 重复不逐出）与 `JitFunction.close` 现状需另部分核对（本部分不展开） |
| 11 | `f_jit/doc/spec/test-f-jit-parallel-calls/design.md` | .md | ✅ | D1–D5 自洽；`:36`「`--parallel 1` 是项目默认」是本部分用例隔离前提的唯一书面依据 |
| 12 | `f_jit/doc/spec/test-f-jit-parallel-calls/proposal.md` | .md | ✅ | 6 条用例与 `ParallelCall_test.cj` 现状一致；表内 `close()` 为当时 API（verify 已记录漂移） |
| 13 | `f_jit/doc/spec/test-f-jit-parallel-calls/tasks.md` | .md | ✅ | 1172 → 1178、变异「注释 `resetWindow` 必红」与 verify 对应 |
| 14 | `f_jit/doc/spec/test-f-jit-parallel-calls/test-plan.md` | .md | ✅ | 与 verify 的用例代价一致；`:11` `close()` 同属历史口径 |
| 15 | `f_jit/doc/spec/test-f-jit-parallel-calls/verify.md` | .md | ✅ | `:37-44` 分支 API 漂移已由 `align-jitfunction-close-naming` 结案；`:49`「全局 `RuntimeEnv.deadlineNanos`」现已是 TLS（`runtime/RuntimeEnv.cj:33/46-63`），属当时记录，不判 |
| 16 | `f_jit/src/AdapterRegistry.cj` | .cj | ✅ | 生产零接线 + 重复登记（见发现 1、5） |
| 17 | `f_jit/src/AdapterRegistry_test.cj` | .cj | ✅ | 3 条用例覆盖键/移除/并发；残留 `101`/`102`（见发现「全局状态」） |
| 18 | `f_jit/src/AnyBridgeCall_test.cj` | .cj | ✅ | 覆盖 P0-2 / P0-6 / A3.4 / A3.5；`:145-148` 空 `catch`（见发现） |
| 19 | `f_jit/src/AnyHostCast_test.cj` | .cj | ✅ | 覆盖 14 目标类界与 15/16–19 归还；全局复位问题见发现；`slotCount == base+1` 与 `HandleTable.resetForTest`（`totalSlots=1`）自洽 |
| 20 | `f_jit/src/BaseVisibility_test.cj` | .cj | ✅ | 再导出守护失效 + 头注释清单过期（见发现 3） |

合计：`.cj` 5 个 / `.md` 15 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 命中：再导出缺项（设计/契约）、`register` 语义与注释不符、`resetWindow`/`resetForTest` 的全局状态用法；安全面无用户输入（本部分无解析/拼接外部串，无注入面） |
| §1 死代码 | 2 | 已逐个符号机械过：`AdapterRegistry` 的 `private lock/adapters/units/key` 均有内部引用；`public register/lookup/removeUnit` 仅测试引用、`size()` 零引用 ⇒ 整类判「未接线/死成员」；5 个文件的 `import` 逐个核对均被使用；无 `return`/`throw` 后同层语句；`@Test`/`@TestCase` 成员按宏生成豁免；`ProbeSink`（private class）及其 `public` 成员在文件内被使用，不判 |
| §2 重复逻辑 | 0 | 已把本部分 5 个 `.cj` 的函数体压成「输入→输出→副作用」摘要两两比对：`AnyBridgeCall_test.compiler()` 与 `AnyHostCast_test.compiler()` 差异在「是否注册 3 个类」，非同语义；`AdapterRegistry_test` 两段 `match(lookup)` 分属不同键断言。跨文件检索 `func codeOf(` / `func castCode(`：`codeOf(body: () -> Unit)` 在 `CallMarshal_test`/`JitFunction_test`/`JsonBridge_test`/`CallMarshalM2_test` 各有副本（范围外文件），属 §2 误报边界「测试里的准备代码」，不计；本部分内 `castCode` 仅 1 处 |
| §3 空实现 | 1 | `AnyBridgeCall_test.cj:147` 空 `catch`（见发现）；`AdapterRegistry` 无 TODO/占位返回；`ProbeSink.diag` 有真实副作用；`DiagnosticsSink` 的默认便捷重载由 `BaseVisibility_test:63-72` 断言转发 `Unspecified`，非空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`AdapterRegistry` 全部为单层循环/哈希操作；4 个测试文件无自递归、无深遍历；`AnyBridgeCall_test` 的 1e8 是**循环**不是递归（有界、可中断） |
| §5 OOM | 1 | `AdapterRegistry.units` 重复登记线性增长 + 无容量上限（见发现 5、优化方案 2）；测试侧 `AnyHostCast_test` 的 5000 次 `openWindow/resetWindow` 成对弹出（`HandleTable.cj:1053-1096`），不累积窗口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；疑似热点（`AdapterRegistry.lookup` 的锁与字符串键）已降级为「待验证假设」#1，不进发现 |
| §6.2 大粒度锁 | 0 | `AdapterRegistry` 是单锁保护两张表，但临界区内只有哈希读写（无 I/O / 解析 / 回调），且当前无调用者；按「无数据不判热点」处理 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无批大小 1 的窗口；`AdapterRegistry_test:60-73` 是 4 线程先提交后统一 `get()`，形态正确 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)`、无循环内字符串 `+`；`key()` 的插值属常数开销，已归入优化方案 1 |
| §7 降堆内存方案 | 1 | `units` 去重 + 上限（见优化方案 2，无基线） |
| §8 降 CPU 方案 | 1 | 结构化键替代字符串键（见优化方案 1，无基线） |
| §9 local mode 可行性 | 0 | 不成立：`AdapterRegistry` 的键串与列表元素**逃逸到 static 容器**（`adapters`/`units`），按 §9 约束 2 不能作为 local 对象；测试侧临时对象量小且无峰值内存证据 |
| §11 现有代码的 BUG（存量） | 5 | 本轮读到的 `register/removeUnit/key/size` 与 4 个测试类的方法逐个核对边界与空值：`Option` 分支（`units.get` 的 `Some/None`）都处理了；`list.size` 返回语义与注释不符、空 `catch`、全局状态残留、文档口径冲突已单列；`key()` 用 `/` 拼接在三段均为数字/类型名时不会冲突（类型名不含 `/`），不判 |
| §12 并发安全与锁粒度 | 1 | 安全面：`AdapterRegistry` 全部状态在 `synchronized(lock)` 内读写，单锁、无嵌套、无锁内回调 ⇒ 无死锁/可见性缺陷；粒度面：单锁保护两张表但无私聊证据（无调用者），不判热点。命中项是测试对进程级 `HandleTable` / 静态注册表的共享与复位（见发现「全局状态」） |
| §14 功能完备性与 README 覆盖 | 2 | `AdapterRegistry` 未接线（设计 §7.3.5/§8.3 第 5 步）；根包再导出缺 `CallContext`/`InterruptedException`（设计 §7.3.6）。本部分不含 `README.md`，README 覆盖留待含 README 的部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；15 个 `.md` 全部按 §13 两两对照（文档↔代码 / 文档↔文档），命中见「统计口径」与「等待条款」两条 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量：8 条（4 一般 + 4 轻微），是否纳入修复待用户决定；本部分无「本次改动」条目（快照基线无 diff）。

## 总评

本部分是两个"面向验收的测试文件 + 一个未被接线的注册表 + 15 份变更记录"。代码层面没有崩溃、越界、数据竞争或资源泄漏：`AdapterRegistry` 的锁使用是正确的最小形态（单锁保护两张表、锁内无回调/IO），`HandleTable` 的窗口开/关在用例里严格配对，`JitContext` 有 `finally` 释放，任何一条用例都不存在无界分配。

真正需要排期的是**契约面**而不是算法面：

1. **`AdapterRegistry` 是一份没有接线的设计**（`call` 第 5 步 / 卸载都没有调用它，`size()` 连测试都不用）。它现在唯一的产出是让 `AdapterRegistry_test` 显得有覆盖率。要么接上，要么删掉并把 `design-m1` 的调用关系改掉——这是本部分最该拍板的一条。
2. **用户面再导出漏了 `CallContext` 和 `InterruptedException`**。这两个类型出现在 `JitFunction.call` 的公开签名与异常通道里，缺了它们，「只 `import fountain::f_jit.*`」这句设计承诺就不成立；而本该抓这个的 `BaseVisibility_test` 因为自己 `import …base.*` 而永远抓不到（项目在 `FacadeSurface_test` 里已经承认过同一个坑）。
3. 规格里「卸载中到达的同键编译要等待」这条 `SHALL` 与 `design.md` D3 的"已知边界"直接矛盾，属于必须二选一的文档债：收窄措辞，或立项做缓存代次。

四条轻微项（重复登记计数、空 `catch` 的假绿、用例对全局句柄表/静态注册表的复位缺失、两份 spec 目录的统计口径互相打架）都不影响运行行为，可随下一次触碰这些文件时顺手修。两条优化方案（结构化键、`units` 去重+上限）都**没有基线**，只能留在「待验证假设」里等接线后的 profile 数据，不进本轮修复清单。
