# f_jit 模块审查报告（第 17/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个文件，全部为 `doc/spec/**` 归档规格：`optimize-call-path-phase1/2/4`、`optimize-compile-copy`、`optimize-compile-hotpath`、`optimize-compile-lookup`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；无 diff ⇒ 全部问题记「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：本部分分报告（`parts/f_jit.part17.md`），由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`（同日抽样版为 `f_jit.md`）
- **本部分性质**：20 个文件全为 `.md`（归档变更的 proposal / design / tasks / verify），无 `.cj`。因此本部分的审查方法是「**文档承诺 ↔ 代码事实双向取证**」：每条规格声称的落地实现、判定闸门、基线数字，都回到 `f_jit/src` 现场核对（核对点见各条「位置」）。

## 发现

### [一般][存量] 规格把「逃逸提升 ↔ 释放/收窗」并发划出承诺范围，但同一槽位字段由两把不同锁写、且无任何线程约束校验

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-call-path-phase2/design.md:36-37`（"`escapeFlags` 仍由 `mtx` 侧（`moveOutGroup`/`escape`）写；同槽「提升」与「释放」并发属调用方非法用法…不在本变更承诺范围"）、`f_jit/doc/spec/optimize-call-path-phase2/verify.md:75`
  - 代码：`f_jit/src/runtime/HandleTable.cj:1034-1040`（`escape` 在 `synchronized(mtx)` 内写 `escapeFlags`）、`HandleTable.cj:1109-1117`（`moveOutGroup` 在 `mtx` 内写）、`HandleTable.cj:1072-1077`（`resetWindow` 在**分片锁**内读 `escapeFlags`）、`HandleTable.cj:1020-1024`（`releaseEscaped` 在**分片锁**内清 `escapeFlags`）、`HandleTable.cj:670-678`（`isEscaped` 完全无锁读）
- **判据**：review-checklist §12.1（共享可变状态无统一同步手段）/ §11（契约与实现不符）
- **证据**：静态确定 —— `escapeFlags[off]` 的写者分属 `mtx` 与「`idx & 63` 分片锁」两把互不排斥的锁，读侧又分别在分片锁内（`resetWindow`）与完全无锁（`isEscaped`）下进行，三者之间不存在任何 happens-before。触发面为待确认：需要「同一句柄在一个线程 `escape`/`promote`、同时另一线程 `release` 或该句柄所属窗口收尾」。
- **描述**：该字段承载的是「**槽已提升 ⇒ 窗口收尾不得释放**」这一句柄生命周期不变式。`mtx` 侧的 `escape` 与分片锁侧的 `resetWindow` 不互斥，最坏情形是收窗读到旧值 `false`，把一个已提升（`PromotionGroup` 仍在册、引用计数 > 0）的槽释放掉：此后闭包调用读到 `gen` 不匹配 → 抛 6 `NULL_HANDLE`（判定口径见 `HandleTable.cj:965-976`），或者槽被别的对象复用后经旧 ID 落到失败路径，属于**句柄生命周期错误**而不是性能问题。规格用「调用方非法用法」把它排除，但三点支撑不足：
  1. `promote` / `escape` / `release` / `releaseEscaped` 都是 `public` API（`HandleTable.cj:986`、`:1006`、`:1029`、`:1138`），`f_jit/README.md` 只写了「`IterTable` 游标线程私有」（`:596`），全模块公开文档没有写「同一句柄不得跨线程同时提升与释放」这条前置条件；
  2. 同模块的并发设计把这件事当成**已支持**：`f_jit/doc/design-parallel-call.md:168` 的 P4 写「跨线程包装 + `PromotionGroup` 原子化 | A 建包装、B/C 调用、D 释放」，`:196` 的风险表把「提升/释放跨线程」列为已用「`PromotionGroup` 原子引用计数」处置的风险项。也就是说，phase2 用「调用方非法用法」排除的正是另一份设计文档承诺要保护的场景。
  3. `moveOutGroup` 用的是**调用线程的窗口**（`HandleTable.cj:1107-1108` `currentWin()`），对「槽不属于本线程窗口」既无校验也不报错：`moveOutGroup` 内层只有 `w.appendIds` 命中才扣记账（`:1118-1130`），跨线程调用时静默不扣、也不提示。`PromotionGroup` 的类注释（`f_jit/src/runtime/PromotionGroup.cj:39-44`）恰恰声明支持「A 线程创建、B/C 调用、D 线程释放」。
- **建议**：三选一并落到规格里：(a) 把 `escapeFlags` 的读写统一到分片锁（`escape`/`moveOutGroup` 在写前取 `mtx → 分片锁`，与 `releaseConst` 现有锁序一致，见 `HandleTable.cj:651-654`），代价是提升冷路径多一次分片锁；(b) 保留现状但在 `escape`/`moveOutGroup`/`release` 的公开注释与 README 明确线程约束，并在 `moveOutGroup` 检测「槽不在本线程任何窗口」时显式记诊断而不是静默；(c) 若确认桥接层存在「调用中把闭包/句柄交给宿主、宿主再跨线程提升」的路径，则本条应升为**严重**并优先修锁。

### [一般][存量] 四份规格的 keep 判定与 `doc/optimize-call-path.md` §1 自定的 MOV 闸门不可复算（闸门被事后放宽或绕过）

- **位置**：
  - `f_jit/doc/spec/optimize-call-path-phase2/verify.md:60-65`（S4 4 线程中位 **2.40 → 2.17**，即 −9.6%，判「噪声而非回退」）
  - `f_jit/doc/spec/optimize-call-path-phase4/proposal.md:41`（B 项验收："维持 2.2–2.4×（当前 2.28×）不回退"）vs `optimize-call-path-phase4/tasks.md:25-26`（"不得低于 2.0×"）vs `optimize-call-path-phase4/verify.md:66-69`（实测 **2.00×**，keep）
  - `f_jit/doc/spec/optimize-compile-copy/verify.md:31-33`（"中位数 −18.0%（12.20 → 10.01，**5.0× 离散度**内一致方向）…均 ≥ MOV"）vs `optimize-compile-copy/proposal.md:37`（预期"−25~35%"）
  - `f_jit/doc/spec/optimize-compile-hotpath/verify.md:21-24`（"点估计 **−1~8%**…按 MOV 判定为 keep（边际）"）
  - `f_jit/doc/spec/optimize-compile-lookup/tasks.md:8-10`（同一场景基线 **47.7 / 24.9 / 24.9 ms**，据此算「名字查找 ≤50 µs ≈ 0.2%」）
  - 判据源：`f_jit/doc/optimize-call-path.md` §1 规则 3（"其它指标中位数回退 ≤ 2%"、"不可协商"）、MOV = `max(3%, 2×离散度)`
- **判据**：review-checklist §13（规格与实现/规格自身漂移）+ `scope.md`「每条发现必须可复核」；判定闸门是后续所有性能改动的验收契约
- **证据**：静态确定 —— 文档内数字与文档自定的闸门直接冲突，且冲突处没有记录任何「闸门变更」决策：
  1. 规则 3 要求「其它指标中位回退 ≤ 2%」，phase2 的 S4 中位回退 −9.6% 仍保留，解释为「两次低值同时伴随 Q1/F1/F4 变差（机器负载）」；该噪声豁免在规则文档里不存在。phase1 的 P1.3 也记录了 S4 −9.9%（`optimize-call-path-phase1/verify.md:10`），但那次 revert 的主因是「无指标达 MOV」，S4 只是附带数据——真正的口径问题是 phase2 单方面以噪声解释越过「回退 ≤2%」，文档没给噪声判据。
  2. phase4 B 项的验收线在 proposal（2.2–2.4×）与 tasks（≥2.0×）之间被下调，最终值恰好落在下调后的下限 2.00×，verify 以「单线程基线大幅变快导致扩展比下降」解释。绝对成本减半是真的，但「扩展比不回退」这一条实际未达成，文档未标注为「指标口径变更」。
  3. compile-copy 自报「5.0× 离散度」，而 MOV = max(3%, **2×离散度**)：若 5.0× 就是离散度，−18% 达不到该闸门；「5.0×」未定义（是极差比？5 次测量？），算式无法复算。同时实测 −18% 低于 proposal 承诺的 −25~35%，verify 未点明未达预期。
  4. hotpath 点估计下沿 −1%、三分之二的「阶段 × 模式」配对只有 −0.3% ~ −1.3%，低于 3% 的 MOV 下限；判 keep（边际）时未给 2× 离散度的具体数值。
- **描述**：这些归档件是「为什么保留这段代码」的唯一凭据。闸门可被事后解释绕开后，后续同类改动的「保留/回滚」失去共同基准；更实际的风险是：phase2 的 S4 回退与 phase4 的扩展比下降都被归因为机器噪声，但两次归因都没有给出线程状态或独占机复测（规则 5 要求的专用 ≥8 核复测至今是遗留项，`optimize-call-path-phase1/verify.md:60`）。
- **建议**：在 `doc/optimize-call-path.md` §1 增补「噪声豁免」的判定条件（例如：同一臂 ≥3 次、配对样本、给出 BLOCKED/WAITING 或 load 证据），并在每份 verify 的判定行旁标注「本条闸门：keep 依据 = 指标 X 中位 a→b、离散度 d、MOV=…」。未达原承诺的项（compile-copy −18% vs −25~35%、phase4 扩展比 2.00×）显式写「未达预期但按 MOV 保留」。

### [轻微][存量] 规格文本与仓库事实不符（符号名、测试路径、声称的断言）

- **位置**：
  - `f_jit/doc/spec/optimize-call-path-phase2/proposal.md:24`：「常量路径（**`markConst`** / `releaseConst`）保留 `mtx`」——仓内无 `markConst` 函数，实际为 `HandleTable.pinConst`（`f_jit/src/runtime/HandleTable.cj:606`）；`markConst` 全仓仅出现在 `HandleTable.cj:139` 的注释里
  - `f_jit/doc/spec/optimize-compile-copy/proposal.md:41`：「+ 护栏 `src/backend/CompileCopy_test.cj`」——同变更 `tasks.md:11` 写的是 `src/compiler/CompileCopy_test.cj`，实际文件在 `f_jit/src/compiler/CompileCopy_test.cj`（`src/backend/` 下不存在该文件）
  - `f_jit/doc/spec/optimize-call-path-phase4/tasks.md:19-20`：B1 声称护栏断言「返回值单调不减**且最终等于高水位**」——`f_jit/src/runtime/HandleTableStripeConcurrency_test.cj:89-104` 只断言单调不减与 `liveCount==0`，无「等于高水位」
  - `f_jit/doc/spec/optimize-call-path-phase2/design.md:44`：「退休槽不进任何分片（**`retiredCount` 不变**）」——`HandleTable.cj:1153-1156` 每次退休 `retiredSlots.fetchAdd(1)`，且 `retiredCount()`（`:1271-1273`）对外暴露该递增计数；同变更 `verify.md:25` 又写「`retiredSlots` 改 `AtomicInt64`」，两处口径相反
- **判据**：review-checklist §13（API / 路径 / 断言与源码不符）
- **证据**：静态确定 —— 逐条全仓搜索：`markConst` 0 个函数定义；`CompileCopy_test.cj` 仅存在于 `src/compiler/`；测试文件正文无高水位相等断言；`retiredSlots` 有 `fetchAdd`。
- **描述**：四处均为归档记录的**事实性错误**，不影响当前运行行为，但会把后续维护者引到不存在的符号/路径上；`retiredCount` 一处还与同变更的 verify 自相矛盾，读者无法判断「退休槽数到底变不变」。
- **建议**：把 `markConst` 改为 `pinConst`；`proposal.md:41` 的路径改为 `src/compiler/CompileCopy_test.cj`；`tasks.md` B1 的断言描述改成实际断言，或给用例补 `slotCount()==高水位`；`design.md:44` 的括注改为「退休槽不进任何分片（`retiredCount` **+1**，槽位永久不可复用）」。

### [轻微][存量] `optimize-compile-copy` 全量计数与「临时探针已删除」互斥，并被下一份 verify 当基线沿用

- **位置**：`f_jit/doc/spec/optimize-compile-copy/verify.md:62-63`；传播到 `f_jit/doc/spec/optimize-compile-hotpath/verify.md:47`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格内部数字不自洽）
- **证据**：静态确定 —— copy/verify.md:62 记 `1241 / 1241，0 失败 0 错误`，:63 括注 `较改前 1239 多出本次新增的 1 条护栏，另 1 条为临时探针，已删除`。按该括注自身算术：1239 + 1 护栏 + 1 探针 = 1241，探针删除后应为 **1240**；若坚持 1241 为收口值，则「改前 1239」写错（应为 1240）。两个数字必有一个错，文档未给第三种解释。hotpath/verify.md:47 又以 `较改前 1241 多出本次新增的 3 条护栏` 得 1244，把该口径继续往下传
- **描述**：全量用例总数是各变更「零失败」结论的唯一量化凭据；此处无法判断 1241 是否含已删除的探针，后续基线（1241→1244）随之不可复核。不影响运行代码，属归档记录缺陷
- **建议**：按该提交实测 `TOTAL` 回填两处：copy/verify.md:62-63 写成「改前 1239 / 新增 1 条护栏（1240）/ 临时探针 1 条另计、收口已删」，hotpath/verify.md:47 改用同一基线；若确有并行增补，把该条用例写进文档

## 优化可行性方案

> 本部分 20 个文件均为归档规格文档，不含可改造的实现代码；本轮不产出堆内存 / CPU 方案（0 / 0）。文档中残留的「下一步线索」（`optimize-compile-hotpath/verify.md:51-59`：`A64Emitter` 审计表 ThreadLocal、`bind('L${off}')` 字符串建键、`InsnDecoder.decode` 操作数数组）经核对已被后续变更处理或仍在待测状态：审计表已改实例字段（`f_jit/doc/optimize-compile-path.md` §12）、降低期已改直读操作数（`X86Lower.cj:114-120`、`Assembler.cj:181-184`），`bind` 字符串键仍是 `A64Lower` 现状，无论证数据前不列为方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `escapeFlags` 的跨锁访问在真实负载下可复现为「已提升槽被收窗释放」 | `HandleTable.cj:1038` / `:1074` / `:1117` | 触发频率与后果形态 | 写定向压测：线程 A 循环 `openWindow→append→escape→（延迟）resetWindow`，线程 B 对同一 ID 反复 `promote`/`release`；断言 `isEscaped` 与 `liveCount` 一致；再补同类数据竞争检测工具（若工具链支持）或插桩记录「resetWindow 读到 false 但 PromotionGroup.contains==true」的次数 |
| 2 | `totalSlots` 改 `AtomicInt64` 后，`pinConst` 的常量去重扫描可能漏扫未发布段，导致同一常量重复占槽 | `HandleTable.cj:615`（`pinConst` 扫上界）、`:1202-1212`（`ensureSegLocked` → `totalSlots.store`）、`optimize-call-path-phase4/design.md:76-78` | `AtomicInt64.load/store` 的默认内存序是否 SeqCst；漏扫发生率 | 先查 SDK 实现/文档确认默认内存序（std 文档只写「默认内存排序方式」，未明确 SeqCst）；再压测：多线程并发 `pinConst` 同一字符串 + 触发段增长，统计 `slotCount` 与 `const` 槽数比值 |
| 3 | phase2 S4（2.40→2.17）与 phase4 B（2.28→2.00×）是机器噪声而非真实回退 | `optimize-call-path-phase2/verify.md:60-65`、`optimize-call-path-phase4/verify.md:63-69` | 专用 ≥8 物理核机器上的同臂复测（规则 5 至今未做） | 专用机 `taskset` 绑核，两臂各 5 次，给中位数 + 极差 + 线程 BLOCKED/WAITING 时长；与共享 VM 数据并列 |
| 4 | `optimize-compile-copy` 收口时的真实全量用例数是 1240 而非 1241（或改前基线是 1240 而非 1239） | `optimize-compile-copy/verify.md:62-63`、`optimize-compile-hotpath/verify.md:47` | 提交 `27cfc3116` 与 `8aa56b3ac` 上 `cjpm test --parallel 1` 的 `TOTAL` 行 | WSL 里 checkout 两个提交各跑一次全量，读 `TOTAL`；本轮不改代码、不跑构建 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/optimize-call-path-phase1/verify.md` | .md | ✅ | 判定与实施记录；P1.1/P1.2 落地已核（`HostCall.cj:229-318`、`HostField.cj:85-141`），P1.3 回滚已核（`enterPauseHook`/`lateEnterAfterStateReadIsRejected` 全仓 0 命中）；见发现 #2、待验证假设 #3 |
| 2 | `f_jit/doc/spec/optimize-call-path-phase2/design.md` | .md | ✅ | 锁归属/分配/释放设计；D1/D2/D3 与 `HandleTable.cj` 一致，D3 的范围声明见发现 #1，D4 的 `retiredCount` 与 happened-before 论证见发现 #3、待验证假设 #2 |
| 3 | `f_jit/doc/spec/optimize-call-path-phase2/proposal.md` | .md | ✅ | 争用探针数据与变更清单；`markConst` 符号名错误见发现 #3 |
| 4 | `f_jit/doc/spec/optimize-call-path-phase2/tasks.md` | .md | ✅ | 任务全 [x]；H1.2 的 `slotCount ≤ 线程数×64` 与用例 `HandleTableStripeConcurrency_test.cj:65` 一致 |
| 5 | `f_jit/doc/spec/optimize-call-path-phase2/verify.md` | .md | ✅ | A4 0.79×→2.64× 算式自洽（79→264）；S4 噪声判定见发现 #2；第 75 行范围声明见发现 #1 |
| 6 | `f_jit/doc/spec/optimize-call-path-phase4/design.md` | .md | ✅ | A 快照化与 `JitBindSupport.cj:39-144` 逐条一致；B 的 `totalSlots` 原子化与 `HandleTable.cj:195/409/1202-1212` 一致；风险表仅论证 `liveCount`，未覆盖 `pinConst` 扫描 |
| 7 | `f_jit/doc/spec/optimize-call-path-phase4/proposal.md` | .md | ✅ | 动机数据（0.40×convoy、openWindow 每调用取锁）与代码现状相符；B 验收线见发现 #2 |
| 8 | `f_jit/doc/spec/optimize-call-path-phase4/tasks.md` | .md | ✅ | B1 声称的断言见发现 #3 |
| 9 | `f_jit/doc/spec/optimize-call-path-phase4/verify.md` | .md | ✅ | A 2.13× / B 2.00× 数据自洽；B 的扩展比下降见发现 #2 |
| 10 | `f_jit/doc/spec/optimize-compile-copy/design.md` | .md | ✅ | 五处改动逐条落地已核：`JitCompiler.cj:74-113`（两遍+预分配）、`FbcWriter.cj:88-147`（`payload()`/单次 CRC）、`Assembler.cj:79`（`clone()`）、`JitExecutor.cj:101-108`（删重复 `flushICache`）；§2.5 的「缓存 DecodedInsn」已被后续 `optimize-decode-alloc` 改成直读（`X86Lower.cj:114-120`），属历史记录 |
| 11 | `f_jit/doc/spec/optimize-compile-copy/proposal.md` | .md | ✅ | 基线 44.3→6.4~11.1 ms；护栏路径错误见发现 #3；预期区间与实测差异见发现 #2 |
| 12 | `f_jit/doc/spec/optimize-compile-copy/tasks.md` | .md | ✅ | F2.1 的路径（`src/compiler/`）与仓库一致，与 proposal 冲突见发现 #3 |
| 13 | `f_jit/doc/spec/optimize-compile-copy/verify.md` | .md | ✅ | 1241/1241 与「1239+1 护栏+1 探针」算术互斥，见发现 #4；「5.0× 离散度」与 MOV 见发现 #2 |
| 14 | `f_jit/doc/spec/optimize-compile-hotpath/design.md` | .md | ✅ | 按字存储与 `A64Emitter.cj:47-123` 一致；`validateFunc` 免解码与 `Assembler.cj:165-274` 一致（`effectArgc` 直读偏移与 `OpInfo.len` 相容：CALL_* 均 len≥2）；CRC 预分配与 `FbcReader.cj:228-243` 一致 |
| 15 | `f_jit/doc/spec/optimize-compile-hotpath/proposal.md` | .md | ✅ | 分段实测数据；基线口径与其它规格不可比，见发现 #2 |
| 16 | `f_jit/doc/spec/optimize-compile-hotpath/tasks.md` | .md | ✅ | G2.1/G3.x 与 `A64EmitterSize_test.cj` 落地一致 |
| 17 | `f_jit/doc/spec/optimize-compile-hotpath/verify.md` | .md | ✅ | 1244/1244 自洽；点估计下沿低于 MOV 见发现 #2；§6 遗留线索已核（审计表已改实例字段、译码数组已直读） |
| 18 | `f_jit/doc/spec/optimize-compile-lookup/design.md` | .md | ✅ | 判定「不做」；D1 的反例对比与 `doc/optimize-compile-path.md` §15.3 可对上 |
| 19 | `f_jit/doc/spec/optimize-compile-lookup/proposal.md` | .md | ✅ | 三处 O(n) 点与代码现状一致（`PredefinedSnapshot` 仍线性扫、`ClassRegistryView.classOf` 仍线性扫） |
| 20 | `f_jit/doc/spec/optimize-compile-lookup/tasks.md` | .md | ✅ | 全 [x] 但明确标注「不做」；L1.1/L1.2 的 47.7/24.9/24.9 ms 与「50 µs ≈ 0.2%」算式自洽，但分母（24.9 ms）与同期规格的 1239 用例 / 12.20 ms 基线不可比，见发现 #2 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

> 注：`files/f_jit.part17.txt` 共 20 行（phase1 1 件 + phase2 4 件 + phase4 4 件 + compile-copy 4 件 + compile-hotpath 4 件 + compile-lookup 3 件：design/proposal/tasks），与上表 20 行一一对应。`optimize-compile-lookup/verify.md` 不在本部分清单内，本文仅在发现 #2 中把它当旁证引用一次，不计入本部分覆盖。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 本部分无 `.cj`，无代码逻辑可判；按「文档承诺即契约」把每条可言伪的声称都回到源码核对（合计为发现 #1/#3）。typecode 分支表（`LocalType` 码 0–21 / `TypeToken`）在本部分 20 个文件中没有对应表格或分支描述，未命中。语言特性一项：`AtomicInt64` / `AtomicReference` 语义已查 std 文档（`sync_package_api/sync_package_classes.md:2085-2130`，只写「默认内存排序方式」，未写 SeqCst），据此把内存序问题降级为待验证假设 #2，未当作缺陷 |
| §1 死代码 | 0 | 已机械核对本部分引用的全部符号/文件：`markConst`（0 个定义，见发现 #3）、`CompileCopy_test.cj`（实际在 `src/compiler/`）、`A64EmitterSize_test`/`HandleTableStripeConcurrency_test`/`JitBindSupportSnapshot_test`/`HostFaultTls_test`/`HandleTableGenExhaustion_test`/`ParallelThroughput_test`/`ParallelCall_test`/`UnloadConcurrency_test`/`PromotionGroupConcurrency_test`/`WindowIsolation_test`/`T40Account_test`/`AnyHostCast_test` 等引用用例均存在；`enterPauseHook`、`lateEnterAfterStateReadIsRejected` 已按 verify 所述删除（全仓 0 命中）。本部分无代码可判死代码 |
| §2 重复逻辑 | 0 | 已两两比对 20 个文件的「输入-输出-副作用」：proposal/design/tasks/verify 四件套是模板分工（为什么/怎么做/做什么/结果），不是同语义复写；phase2 与 phase4 都描述 `HandleTable` 锁改造，但前者是分片空闲表、后者是 `totalSlots` 原子化与 `JitBindSupport` 快照，改动面不重叠，合并会丢失「逐项可回滚」的决策粒度 |
| §3 空实现 | 0 | 归档件里「不做」的三项（`optimize-compile-lookup` 的 L3.1–L3.3）在 `tasks.md:3-4` 明确标注「数据不支持，不做」，并给了收益上限 0.2% 与 MOV 对比，属有意不做，不是空实现 |
| §4 栈溢出 | 0 | 本部分无代码。文档涉及的递归结构仅 `CallMarshal.promoteClosureGraph`（`optimize-call-path-phase2` 未涉及、`phase4` 只在 `PromotionGroup` 语义里提到「槽级免级联」）；已核对 `CallMarshal.cj:288-309` 用 `visited` 做环检测、深度受闭包捕获链限制，未在本部分文件内命中风险 |
| §5 OOM | 0 | 本部分无代码。文档承诺的容量面（`capacityLimit`、`FREE_STRIPES=64`、`retiredSlots` 退休上限）与 `HandleTable.cj:177-202` 一致，均为有界结构；未发现「只增不减」的承诺 |
| §6.1 热点瓶颈 | 0 | 本部分只有测量记录，没有本轮采集的 profile；文档中的热点结论（`translate` 1.41–1.65 ms、`validate` 0.21–0.23 ms、A4/S4 扩展比）属历史数据，本轮无同机复测，故不新增热点结论，只把不可复算处列入发现 #2、把机器差异列入待验证假设 #3 |
| §6.2 大粒度锁 | 0 | 文档声称的两处锁清理均已落地并与代码一致（`openWindow` 不再取 `mtx`：`HandleTable.cj:407-413`；`JitBindSupport` 读路径零锁：`JitBindSupport.cj:147-171`）。剩余 `mtx` 临界区为冷路径（`growSlot`、`pinConst` 全表扫、`moveOutGroup`、`resetForTest`），本轮无持有时间数据，不判为热点 |
| §6.3 并发串行 | 0 | 本部分无 `spawn().get()` 一类代码；`HandleTableStripeConcurrency_test.cj:59-61` 是先提交后汇合的正确形态 |
| §6.4 低效算法 | 0 | 文档点名的三处 O(n)（`PredefinedSnapshot.slotOf`、`ClassRegistryView.classOf`、`ClassRegistry.snapshot` 双拷贝）已用 0.2% 收益上限论证不做，算式自洽（50 µs / 24.9 ms）；`pinConst` 的全表线性扫在写路径、频次低，无数据前不作低效结论 |
| §7 降堆内存方案 | 0 | 归档件不产生新代码；`phase2/verify.md:71-76` 的「后续」只列了 B1 单次调用成本，无堆内存方案 |
| §8 降 CPU 方案 | 0 | 同上；文档遗留线索（审计表 TLS、`bind` 字符串键、`decode` 数组）中两项已由后续变更加工，剩 `bind` 键无实测，见「优化可行性方案」说明 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象；`scope.md` 的 LocalMode 资料针对 `docs/` 全局方案，不属于 `f_jit` 这 20 个文件的可判范围 |
| §11 现有代码的 BUG（存量） | 4 | 发现 #1（句柄生命周期：提升与释放双锁）、#2（性能判定闸门不可复算，属记录缺陷）、#3（四处文档事实性错误）、#4（全量计数与已删探针互斥）。均已给位置 + 判据 + 证据等级；全部为存量（快照模式无 diff 基线） |
| §12 并发安全与锁粒度 | 1 | 发现 #1 即并发安全项：指出具体共享字段（`escapeFlags`）、两个并发访问者（`escape`/`moveOutGroup` vs `release`/`resetWindow`）与缺失的同步手段（两把锁不互斥）。锁粒度项：`mtx` 已按 phase2/phase4 收缩为冷路径，未发现「该分片而未分片」的新证据 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README/`README_en`。文档承诺的 6 项能力已逐项在代码中确认存在：HostFault 线程私有（`HostCall.cj:229-318` + `JitContext.cj:199-203`）、HostField 快照（`HostField.cj:85-141`）、`HandleTable` 分片+原子 `totalSlots`（`HandleTable.cj:195-202`）、`JitBindSupport` 快照（`JitBindSupport.cj:39-144`）、`FbcWriter.payload` / `Assembler.clone` / 单次 `flushICache` / `A64Emitter` 按字存储 / `checkCrc32` 预分配；无「承诺但未实现」 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，全部 20 个 `.md` 逐个读完；`.cj` 只作交叉取证，不计入本部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 4 条（发现全部为存量；快照模式无 diff 基线），是否纳入修复待用户决定。

## 总评

本部分是 `f_jit` 六个性能/编译优化变更的**归档规格**（proposal / design / tasks / verify），不含源码。就文档本身看，质量在平均线之上：每条改动都给了改前基线、护栏用例、变异验证与回滚条件，并且声称落地的代码我逐条核过，**全部真实存在**（`HandleTable` 64 分片 + `AtomicInt64 totalSlots`、`JitBindSupport`/`HostFieldTable` 写时复制快照、`FbcWriter.payload`、`A64Emitter` 按字存储、`Assembler.validateFunc` 免解码、`checkCrc32` 预分配、`JitExecutor.create` 去重复 `ICache` 刷新），未发现「文档写了、代码没做」的情况。

主要风险集中在两处，都不在代码正确性而在**承诺边界**：

1. **并发承诺边界**（发现 #1）：`escapeFlags` 由 `mtx` 与分片锁两把锁分别写、读侧还有完全无锁的 `isEscaped`，规格用「调用方非法用法」把它排除，但 public API 没有写这条约束，`moveOutGroup` 对跨线程调用又是静默 no-op。这条最值得排期——它影响的是句柄生命周期不变式，一旦命中，表现是「已提升句柄被收窗释放」，排查成本远高于修复成本。建议先按「统一锁 or 显式拒绝」二选一，再补一条跨线程逃逸的压测。
2. **判定闸门可复算性**（发现 #2）：四份 verify 里至少四处「保留」决定与本文档自己写的 `MOV = max(3%, 2×离散度)` / 「其它指标回退 ≤2%」不一致，且都以「机器噪声」解释而无线程状态或独占机复测。代码本身没问题，但归档件的价值是「为什么保留这段代码」；闸门被事后放宽后，后续同类改动的去留就没有共同基准。建议单独补一版闸门说明，而不是改动结论。

其余为事实性与计数笔误（发现 #3/#4），可在下一次触碰这些目录时顺手改掉。整体判断：**无阻塞项（本部分无代码），发现 #1 建议进修复清单、#2 建议进流程改进、#3/#4 随手修**。
