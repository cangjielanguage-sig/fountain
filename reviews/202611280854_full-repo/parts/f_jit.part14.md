# f_jit 模块审查报告（第 14/38 部分）

> 本报告只覆盖 `files/f_jit.part14.txt` 列出的 20 个文件，全部是 `f_jit/doc/spec/**` 下的 `.md`：`fix-f-jit-x86-stack-align` 1 个、`fix-handle-config-race` 3 个、`fix-handle-gen-exhaustion` 5 个、`fix-jit-unary-not` 8 个、`fix-native-assets-atomic` 3 个。这些 spec 都是已完成变更的过程文档，故按「文档承诺 → 源码落点」逐条取证；源码只作判据引用，不计入本部分覆盖。

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（代码基线 `120fd2542`；`HEAD f309f0b55` 是审查流程文档提交，`git diff` 无源码改动）⇒ 全部问题记「存量」
- **审查重点**：动态调用/桥接正确性、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑。本部分实际内容为四条修复记录（A64 `NOT_B` 位域、句柄 gen 退休、句柄配置原子化、原生资产计数原子化）加一条 x86 栈对齐记录，重点落在：**文档声称的「已修复 / 已验证 / 未变」是否与源码一致，以及规格内部是否自洽**（`NOT_B` 的 `{0,1}` 前提、释放路径锁纪律、兼容性结论、README 覆盖）
- **报告版本**：v1（第 14/38 部分；本部分编号与同模块其余 37 份独立，合并时以主 Agent 为准）

## 发现

### [一般][存量] #1 D3（`!` 按类型分派）未回写到「不做的事」与「兼容性」结论，文档说「字节码不变」，实现改了字节码

- **位置**：
  - `f_jit/doc/spec/fix-jit-unary-not/proposal.md:25`（「**不改**：Parser / Lexer / Lowerer 的既有行为（已证伪，见 design §2.2）」）
  - `f_jit/doc/spec/fix-jit-unary-not/proposal.md:44`（「同一源单元前后只差 `NOT_B` 的 4 个机器字节；字节码、verMajor、规则集、helper 编号、缓存键全部不变」）
  - `f_jit/doc/spec/fix-jit-unary-not/design.md:110-111`（§3.4「不做的事：不改 `Lowerer`、`Parser`、`Lexer`、`Interp`（已证伪）」）
  - `f_jit/doc/spec/fix-jit-unary-not/design.md:169-171`（影响表「`.fbc` / 规则集 / 缓存键 | 不变（只改机器码生成）」）
  - `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md:7`（「前端对 `!operand` SHALL 产出……+ 单条 `NOT_B`」）
- **来源**：存量（快照；`git blame`：这些行均为 `d71346a21` 初版，D3 修订 `ca05c75c5` 只改了 proposal:20 / design §3.3 / spec:21-24，未覆盖上述五行）
- **判据**：review-checklist §13「文档承诺与实现相反 / 规格与实现漂移」、§14.1「承诺与实现不一致」
- **证据**：静态确定 — 实现 `f_jit/src/compiler/Lowerer.cj:1727-1740` 已按 `LocalType` 分派：`BOOL → NOT_B`、`I64 → BNOT_I`、其余 `diagFail(TYPE_MISMATCH)`。于是 `{ n: Int64 => !n }` 的字节码由 `NOT_B` 变为 `BNOT_I`（D3 自己的要求），`{ s: String => !s }` 由「能编译」变为编译期报错；两者都与 proposal:44 / design:169-171 的「字节码不变」「只改机器码生成」直接矛盾，也与 proposal:25 / design:111 的「不改 Lowerer」矛盾（同文 design:94-107 的 D3 又明确要改）。`spec.md:7` 的 SHALL 是全称的，而同一文件 21-24 行自证 Int64 走 `BNOT_I`。
- **描述**：这不是措辞洁癖：后续审计若引用「同一源单元只差 4 个机器字节」，`BNOT_I` 分支的差分/形状回归会被判为「无需覆盖」；按 `spec.md:7` 验收则会把正确的 `BNOT_I` 判成违规。缓存层面本身安全——`CompileCacheKey`（`src/backend/CompileCacheKey.cj:21-46`）以 `(arch, cpuFeatures, bytecodeFingerprint)` 为键且仅驻内存，字节码变了键自动变——但文档给出的理由（「字节码不变」）是错的，正确理由没写。
- **建议**：proposal:25 与 design:111 改为「不改 Parser / Lexer / Interp；`Lowerer` 仅改 `Bang` 分支（D3）」；proposal:44 与 design:169-171 改为「Bool 分支只差 `NOT_B` 的 4 个机器字节；Int64 分支字节码由 `NOT_B` 改为 `BNOT_I`，非法类型改为编译期 `TYPE_MISMATCH`；缓存键随字节码指纹自动变化」；`spec.md:7` 的 SHALL 收窄为「BOOL 操作数产出单条 `NOT_B`」或改述为「按类型分派后恰好一条取反指令」。

### [一般][存量] #2 `f-jit-compiler-frontend` 的 spec delta 有一个空 scenario：`!~` 的验收项被「类型分派形状」截断

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md:19-27`（19 行标题「正则取反同样单条」后直接是 21 行「类型分派形状」；属于正则的 26-27 行 `WHEN 编译 re !~ s` / `THEN … 恰好一条 NOT_B` 落在「类型分派形状」名下）
- **来源**：存量（快照；标题与正文为 `d71346a21`，`ca05c75c5` 在两者之间插入新 scenario 造成错位）
- **判据**：review-checklist §13「验收口径不可执行」、§14.1「只做了一半的分支」
- **证据**：静态确定 — 按 `#### Scenario:` 标题切分时，19 行标题与下一个标题（21）之间没有任何正文，构成空 scenario；26-27 的正文追加在已有自己 WHEN/THEN（23-24）的「类型分派形状」之后，同一 scenario 出现两组 WHEN/THEN。`tasks.md:51`（N5.2）声称「三个 capability 的 delta 全量落地」。
- **描述**：`re !~ s` 追加恰好一条 `NOT_B` 这条验收在契约层是悬空的：实现侧（`Lowerer.cj:3049-3056`）与用例 `bytecodeShapeOfRegexNegation` 都有，缺的只是 spec 表述；逐 scenario 核对或做严格校验时会读到一个空场景。
- **建议**：把 26-27 两行移回 19 行标题之后，「类型分派形状」只保留 23-24；顺手对三份 delta 各跑一次 `openspec validate --strict`，避免「归档即通过」。

### [轻微][存量] #3 `fix-handle-gen-exhaustion` 任务书把旧实现失败形态写成「负 ID」，与同批 verify 的 `OverflowException` 矛盾

- **位置**：`f_jit/doc/spec/fix-handle-gen-exhaustion/tasks.md:7-9`（G1.1「旧实现第 32768 轮返回负 ID ⇒ `id > 0` 断言失败」）；对照 `f_jit/doc/spec/fix-handle-gen-exhaustion/verify.md:13-22`（Red 实测为 `OverflowException`）、`design.md:9-10`（「`Int64(u)` 是受检转换，直接抛 `OverflowException`；若换成非受检位转换则会得到负 ID」）
- **来源**：存量（`55ddaca48` 一次写入，verify 回填时未回改任务书）
- **判据**：review-checklist §13「规格与实现漂移」、§11「证据与结论不符」
- **证据**：静态确定 — verify 的 Red 原始输出是 `OverflowException: The result would be greater than Int64.Max`，栈落 `HandleTable.makeId`；负 ID 只存在于「非受检位转换」这个假想分支，且 design:9-10 与 proposal:8-9 都把它写作备选路径。
- **描述**：按任务书复跑的人会等不到「负 ID」，或误以为 Red 用例没命中溢出点；`id > 0` 的断言红实际以异常（ERROR）形式出现，统计口径也不同。
- **建议**：`tasks.md:8` 改为「旧实现抛 `OverflowException`（受检转换，ERROR 而非断言红）；若改非受检位转换则得到负 ID」，并把 G1.1 的「确认是断言红」改为「确认命中 `makeId`」。

### [轻微][存量] #4 `x86-verification.md` 的预期总数与任务闭合数与产物不符（1163 vs 1171、24/24 vs 任务书 23/24）

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/x86-verification.md:40`（「`cjpm test` 全量 `1163 passed / 0 failed`」）、同文件 `:64`（「`fix-jit-unary-not` 的 24/24 任务闭合」）；对照 `verify.md:91-92`（x86 实测 `TOTAL 1171`）、`tasks.md:52`（`- [ ] N5.3 合并`）
- **来源**：存量（快照；`aae68ebe9` 回填 x86 证据时只改了头部，未同步预期表与任务书）
- **判据**：review-checklist §13「同一变更内两份文档结论相反 / 文档过期」
- **证据**：静态确定 — 同文件 6-7 行的头部已回填「全量 1171 首跑全绿」，与 40 行预期表自相矛盾；`tasks.md:52` 仍未勾选，但 `git log -1 f5498e554` = `2026-10-31 15:26:37 merge: 合入 fix-jit-unary-not`，`git branch --contains f5498e55` 含 `master`/`sts/1.3.x`，`git merge-base --is-ancestor f5498e554 HEAD` 为真（归档 15:18 早于合并，N3.4 回填 16:39 晚于合并）。
- **描述**：x86 与 AArch64 用例数不同本身正常（条件编译），错在把 AArch64 的 1163 写成 x86 的预期判据；「24/24」与任务书的一处未勾选并存，会让接手人误判变更状态——实际合并已完成，是任务书漏勾，不是未完成。
- **建议**：40 行改为「与 AArch64 侧同量级（实测 1171，差异见 verify §4）」；勾选 N5.3 并注明「由 `f5498e554` 完成」（或保留未勾选但补一句「合并已由该提交完成」）。

### [轻微][存量] #5 `design.md` §4.2 的期望值笔误未回写，verify 的「两处笔误」只有一处可定位

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/design.md:132`（比较族 `!(n != 5)` 在 `n = 5` 期望 `0`）；对照 `verify.md:155-157`
- **来源**：存量（`d71346a21` 写入 design；`bf8d7bc31` 在 verify 中记录订正，未回改 design）
- **判据**：review-checklist §13「规格与验收口径不一致」
- **证据**：静态确定 — `5 != 5` 为假，取反得 `1`，不是 `0`；verify:155 承认「`!(!=)` 在 `n = 5` 上取反得 `1` 而非表中 `0`」。但 verify 同时声称第二处是 `!(a || b)` 在 `(true,false)` 期望 `1`，而 `design.md:135` 只有「各类 / 与 `&&`/`||` 真值取反一致」的定性描述、**没有**数值行 —— 该第二处**待确认**（可能镜像与 openspec 侧文本不同，或缺原始表）。
- **描述**：错误期望值会被下一个写用例的人抄走，制造「按规格写、按语义红」的假失败；verify 已知道却只改用例不改规格，订正链在归档时断开。
- **建议**：`design.md:132` 改为 `0 / 0 / 1`；核对 `openspec/changes/archive/**/fix-jit-unary-not` 与镜像是否同源，若第二处笔误只存在于 openspec 侧则同步回写，否则删掉 verify 中无法定位的半句。

### [轻微][存量] #6 `NOT_B` 的「三引擎逐位一致」承诺缺前置不变量：等价只在 `{0,1}` 域成立，spec 未写明

- **位置**：`f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-backend/spec.md:7`（「两侧 SHALL 只翻转 bit0」）、`:29-31`（「三引擎 SHALL 对同一源码给出逐位一致的结果」）；对照 `design.md:81`（「在 `{0,1}` 域上完全等价」）、`design.md:87-89`（D2 否决理由：「x86 侧不同构（`xor 1` 只在 `{0,1}` 域等价）」）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「契约前置条件缺失」、§13「规格与实现漂移」
- **证据**：静态确定 — 解释器 `Interp.cj:533` 为 `a == 0 ? 1 : 0`，A64 `A64Lower.cj:326-329` 为 `eor #1`、x86 `X86Lower.cj:975` 为 `xor qword [rsp],1`；若 Bool cell 非规范 0/1（如 2），解释器给 `0`、两后端给 `3`，桥按 `cell != 0` 解包即 `false` vs `true`。当前所有 Bool 生产者（比较 `cset`、`PUSH_BOOL`、host 参数解包）都产 0/1，故现在不可达。
- **描述**：契约比实现强。将来任何非规范 Bool 来源（新 helper 直接回写宿主返回值、常量池伪造 Bool 常量、优化把 `!=0` 折叠成原值）都会让 `!` 静默分歧，而 spec 里没有能拦住它的条款。
- **建议**：在该 requirement 补一句「Bool cell SHALL 规范化为 0/1；`NOT_B` 的三引擎等价以该不变量为前提」；若要彻底摆脱前提，按 design §3.2 / D2 改 `cmp + cset eq`（需同时改 x86 与 Interp 契约，另立变更）。

### [轻微][存量] #7 native-assets 的护栏声称「旧实现必须红」，并发丢增量并不能保证每次复现

- **位置**：`f_jit/doc/spec/fix-native-assets-atomic/proposal.md:31`（「护栏在旧实现上必须**红**（并发增量丢失）」）、`tasks.md:4`（T1.2「必须 FAILED」）、`verify.md:13-25`（仅一次 `left: 396 / right: 400`）
- **来源**：存量（`e785109e7d` 一次写入）
- **判据**：review-checklist §11（并发验证证据）/ §12.1（数据竞争的可观测性）
- **证据**：需实测 — `allocs = allocs + 1` 的丢增量依赖调度与核数；在单核、低竞争或编译器把读改写优化成单条指令的宿主上，同一用例完全可能得到 400，护栏漏报。
- **描述**：护栏是本次变更唯一的并发证据来源；若它在错误实现上可能通过，回归价值就取决于环境，「改前红」不再成立。变更本身的 `AtomicInt64` 修法正确（`NativeAssets.cj:35-54`），风险仅在证据强度。
- **建议**：改成多轮（如 ≥50 轮统计失败率）或做变异验证（临时换回普通 `Int64` 跑 N 轮），verify 记录「旧实现 N 轮中 M 轮失败」；也可用可控屏障放大竞争窗口。

## 优化可行性方案

本部分 20 个文件全部是 `doc/spec/**` 过程文档，没有可执行的 CPU / 堆内存路径，不产出优化方案（0 条）。文档中出现的三处成本/容量数字（`openWindow` 的 1 ns 原子读、`onAlloc` 的原子加、退休槽 3e-5 槽/次）均无基线，列入下方待验证假设，不作结论。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「`openWindow` 每次多一次原子读，在 2971 ns/call 里是 1 ns 量级」 | `f_jit/doc/spec/fix-handle-config-race/proposal.md:34-35` | 2971 ns/call 的出处；改前/改后对照 | `cjpm bench -O2` 同机、同输入、≥10 轮取中位数与 P95，分别跑 `mut prop` 版与旧 `static var` 版 |
| 2 | 「`onAlloc`/`onFree` 多一条原子加可忽略」 | `f_jit/doc/spec/fix-native-assets-atomic/verify.md:55-56` | 单次 alloc/free 的绝对耗时与占单单元比例 | 微基准 1e6 次 alloc/free，与普通 `Int64` 自增对照 |
| 3 | 退休槽导致 `totalSlots` 单向增长，「1M × 32767 ≈ 3.4e10 次分配 / 1M QPS 约 9.3 小时」触顶 | `f_jit/doc/spec/fix-handle-gen-exhaustion/design.md:26-30` | 真实分配率、单槽复用分布、触顶后错误 16 的业务影响 | 长跑压测 ≥1 h，埋点 `slotCount()` / `retiredCount()` 斜率与 QPS 一起记录，再乘峰值推算 |
| 4 | A4 分配型基准可作收益判据 | `f_jit/doc/spec/fix-jit-unary-not/verify.md:74-83` | 稳定基线：三次数值 76 / 138 / 79（×100）离散约 1.8× | 专用机器（无共享 VM 噪声）≥10 轮，报中位数/离散度，或改短调用口径重采 |

## 文件覆盖

> 与 `files/f_jit.part14.txt` 一一对应，20 行全列。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/verify.md` | .md | ✅ | 结论与实现一致（`X86Depth.analyze` / `alignBeforeCall` / `X86Lower.lower` 三遍均存在）；数值自洽（1084+3+4=1091；1094+0+4=1098；+7 例）；4 条 FAILED 为当时既有失败，后续 `fix-f-jit-strictfp-deadline-x86` 已承接；性能数字无基线，不作结论 |
| 2 | `f_jit/doc/spec/fix-handle-config-race/proposal.md` | .md | ✅ | H4 动机与实现一致；「内部 9 处读点」实测 10 处（`HandleTable.cj` 210/410/701/1058/1094/1314 + 706/707/716/1206），计数偏差不单列 |
| 3 | `f_jit/doc/spec/fix-handle-config-race/tasks.md` | .md | ✅ | T1.1–T3.3 全 `[x]`，与 `HandleTableConfigRace_test.cj`（1 用例）存在一致 |
| 4 | `f_jit/doc/spec/fix-handle-config-race/verify.md` | .md | ✅ | diff 与 `HandleTable.cj:149-169` 逐行一致；§2 诚实说明「旧实现也不会失败」；1255+1=1256 自洽 |
| 5 | `f_jit/doc/spec/fix-handle-gen-exhaustion/design.md` | .md | ✅ | `GEN_MAX=0x7FFF` 与 `makeId` 位域推导成立；容量/时长量化自洽。D3/D4 的 `freeOrRetireLocked` 与「调用方持 `mtx`」对 `55ddaca48` 当时实现是准确的，后由 `591bce866`（64 分片 + `AtomicInt64`）改写；按归档规格「当时自洽」口径不判缺陷，阅读时以现码 `HandleTable.cj:1153/1159` 为准 |
| 6 | `f_jit/doc/spec/fix-handle-gen-exhaustion/proposal.md` | .md | ✅ | 与 design/verify 一致（受检转换 → `OverflowException`） |
| 7 | `f_jit/doc/spec/fix-handle-gen-exhaustion/specs/f-jit-runtime/spec.md` | .md | ✅ | 三个 Scenario 与 `HandleTableGenExhaustion_test.cj` 两条用例对应；「`slotCount` 恰增 1」指新槽，与 verify:36 的高水位 +2 口径可互相解释 |
| 8 | `f_jit/doc/spec/fix-handle-gen-exhaustion/tasks.md` | .md | ✅ | G1.1 的 Red 形态见 #3；其余勾选与实现/verify 对应 |
| 9 | `f_jit/doc/spec/fix-handle-gen-exhaustion/verify.md` | .md | ✅ | Red/Green/变异/单类/全量/基准解禁齐全；`lastId=281487861612546` 解出 `gen=1,tag=3,idx=2`，与「新槽接管」语义一致；A4 噪声已自陈（假设 #4） |
| 10 | `f_jit/doc/spec/fix-jit-unary-not/design.md` | .md | ✅ | 位域解码与最终编码 `0xD2400129` 正确（`A64Lower.cj:326-329`、`A64Emitter.cj:389-391`）；问题见 #1、#5、#6 |
| 11 | `f_jit/doc/spec/fix-jit-unary-not/proposal.md` | .md | ✅ | 根因与影响面正确；「不改 Lowerer」「字节码不变」见 #1 |
| 12 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-backend/spec.md` | .md | ✅ | 编码契约与 `A64NotBEncoding_test.cj:47-49` 常量一致；`{0,1}` 前提缺失见 #6 |
| 13 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 场景错位见 #2；第 7 行 SHALL 的全称问题见 #1 |
| 14 | `f_jit/doc/spec/fix-jit-unary-not/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | 与 `UnaryNotDiff_test`（10 条）逐条可对上（`reportedCase`/`comparisonBoundary`/…）；「绝对值锚定」落实在用例里 |
| 15 | `f_jit/doc/spec/fix-jit-unary-not/tasks.md` | .md | ✅ | N0–N5 与 verify 对应；N5.3 未勾选但合并已完成，见 #4 |
| 16 | `f_jit/doc/spec/fix-jit-unary-not/verify.md` | .md | ✅ | 1145+18=1163 自洽；x86 1171 与 1163 的差异为宿主条件编译新增用例，非矛盾；§6.1 的订正记录见 #5；§5 的 B7 见范围外提示 |
| 17 | `f_jit/doc/spec/fix-jit-unary-not/x86-verification.md` | .md | ✅ | 预期总数与任务闭合数见 #4；`7f5dea83` 经确认是 `05d0ed6f` 的祖先，两份文档的基线不冲突 |
| 18 | `f_jit/doc/spec/fix-native-assets-atomic/proposal.md` | .md | ✅ | 与 `NativeAssets.cj:35-54` 一致；「必须红」见 #7 |
| 19 | `f_jit/doc/spec/fix-native-assets-atomic/tasks.md` | .md | ✅ | 6 项全 `[x]`，`NativeAssetsConcurrency_test.cj` 存在；T1.2 同 #7 |
| 20 | `f_jit/doc/spec/fix-native-assets-atomic/verify.md` | .md | ✅ | 396/400 红态、4+1 用例、1253+1=1254 自洽；精确值断言依赖「测试独占进程」，并行跑时对其它用例的资产分配敏感（测试文件属其它部分，此处只提示） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | #1（兼容性结论与 D3 相反、规格 SHALL 全称化）。语言特性面核对了 `Int64(UInt64)` 受检转换、`AtomicInt64.load/store/fetchAdd`、`mut prop` 赋值语法、`!` 的「按位求反/逻辑非」双语义（官方 `Appendix/operator.md:14`），均与文档一致；本部分无外部输入、凭据、注入面 |
| §1 死代码 | 0 | 本部分无代码声明。改用等价机械检查：文档引用的符号/路径是否仍存在——`A64Exec_test`、`AstShape`、`CodeDump`、`A64Emitter.eorImm1`、`X86Depth.analyze`、`alignBeforeCall`、`freeOrRetireLocked`（在 `55ddaca48` 中存在，后被改名）、`HandleTableM2_test`/`T40Account_test`/`PromotionGroupConcurrency_test`/`WindowIsolation_test`/`HandleTableStripeConcurrency_test`/`NativeAssets_test`/`X86Depth_test` 均命中；README 索引遗漏见范围外提示 |
| §2 重复逻辑 | 0 | 已两两比对 5 个变更目录的 proposal/design/tasks/verify 叙述：重复仅为统一模板与必要前后引用；反复出现的测试总数 1098 → 1145 → 1201 → 1254 → 1256 单调且与各批增量自洽（+7 / +18 / +53 / +2）。真正逐字重复的 `0x50–0x6F` 指令表在 part2 的两份 design 文档中，列范围外 |
| §3 空实现 | 0 | 20 份文档均有实体内容，无 `TODO` 占位；`spec.md:19` 的空 scenario 已按 §13 计入 #2（结构错位而非占位） |
| §4 栈溢出 | 0 | 修复对象是 3~4 条定长机器码指令；`X86Depth.analyze` 是工作列表迭代；句柄 32768 轮用例是 `while` 循环，无递归 |
| §5 OOM | 0 | 唯一增长面是退休槽（永久占索引），已量化（3e-5 槽/次、默认 `capacityLimit` 1M、目录 4M），有拒绝路径（触顶 → 错误 16）；估算本身进假设 #3 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；三处成本/容量断言进待验证假设 #1–#3，不作性能结论 |
| §6.2 大粒度锁 | 0 | 文档所述临界区只有「状态复位 + 世代号 + 归还索引」；现码 `release`/`releaseEscaped`/`resetWindow` 持分片锁、`releaseConst` 持 `mtx → 分片`，无 I/O/解析/日志。归档 design 的「持 `mtx`」是 P2.1 之前形态，不判 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get` 的描述；两个并发用例都是先提交后统一 `get` |
| §6.4 低效算法 | 0 | 无复杂度描述；`resetWindow` 为 O(appendIds)，`popFreeWith` 最多扫 64 分片，与文档一致 |
| §7 降堆内存方案 | 0 | 本部分无源码；`NativeAssets` 只做计数，非 GC 内存由 `JitFunction` 持有，无优化落点 |
| §8 降 CPU 方案 | 0 | 同上；原子增量按文档「每单元各一次」，不在调用热路径，无逆向优化必要 |
| §9 local mode 可行性 | 0 | 文档未涉及 local region / `exclave` / `demode`，无改造面可评 |
| §11 现有代码的 BUG（存量） | 2 | #3（Red 形态与实测不符）、#7（并发护栏不可保证红）。另重新用 `grep CMP_I` 核实 B7 仍无 Lowerer 生产者；句柄判空 `id <= 0`、`release` 幂等、逃逸槽归宿、`FnTable.free` 幂等均已核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 逐点核对 H2/H4/H1：`NativeAssets` 计数已原子（`NativeAssets.cj:35-54`）；`HandleTable` 配置读走 `AtomicInt64`（`:149-169`）；4 处释放点都持归属分片锁，`popFreeWith` 在取 `mtx` 前已释放分片锁，无 ABBA。`liveCount` 的跨字段快照问题属范围外（见总评） |
| §14 功能完备性与 README 覆盖 | 1 | #6（spec 承诺缺 `{0,1}` 前置不变量）。README 的 API 索引与 `!` 语义覆盖属 part1，列范围外提示 |
| 文件覆盖（§13 等） | 3 | #2、#4、#5（均为 §13 文档一致性）；20/20 文件全部读完，无缺读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2（#1 #2） |
| 轻微 | 5（#3 #4 #5 #6 #7） |
| 优化方案（堆内存 / CPU） | 0 / 0 |

本部分 7 条全部为存量（快照模式无基线，无本次改动）；是否纳入修复待用户决定。

## 总评

本部分没有源码，判的是「变更记录是否可信」。五条变更的实现侧都真实落了地，且质量不差：A64 的 `NOT_B` 已由 `eorImm1` 字段构造（`A64Emitter.cj:381-391`，位域注释齐全）、`gen` 退休在四处释放点统一收口（`HandleTable.cj:653/1000/1024/1077`）、句柄配置与原生资产计数都已原子化；`verify.md` 的「旧实现不会失败」这类诚实说明值得肯定。四条变更有三条带可复跑护栏，测试总数与增量逐批自洽，`git blame`/提交历史也能对上。**没有阻塞项，没有需要立即修的代码缺陷**；本部分未运行构建或测试，文档中的绿态数字只作记录核对，未独立复验。

问题集中在文档层，都是「变更做对了、文档没跟上」：#1 最值得排期（「不改 Lowerer / 字节码不变」会直接误导后续差分与缓存审计，且 `spec.md:7` 的全称 SHALL 会把正确的 `BNOT_I` 判成违规）；#2 的空 scenario 让 `!~` 的验收在契约层悬空，一次性修补即可。其余 5 条是验收记录与实测/仓库事实的偏差（Red 形态、x86 预期数、N5.3 状态、design 期望值、并发护栏强度），以及 `{0,1}` 这个隐式地基没写进 spec。

设计侧有两点已登记、应按排期跟进的残留风险，不构成本轮缺陷：① 退休槽不可回收，默认 `capacityLimit`（1M）下约 3.3e10 次分配即触顶（1M 次/秒约 9 小时返回错误 16），design §D2 与 verify「风险与后续」已明示，高 QPS 服务上线前应评估是否调高上限或另立回收变更；② B7（`CMP_I`/`CMP_F` 符号约定与解释器相反）当前无 `Lowerer` 生产者、不可达，但已登记未修，后续接入生产者前必须先定规范。

**范围外提示（不占本轮统计）**：

- `f_jit/doc/design-m1.md:1524` 与 `f_jit/doc/jit-bytecode-m1.md:2129` 的 `CMP_I` A64 列仍是 `cset x11,lt; cset x12,gt; sub x11,x12`，而实现是 `cset 11,LT; cset 10,GT; sub 9,11,10`（`A64Lower.cj:787-795`），寄存器写错；同时其符号约定与 `Interp.cj:498` 相反（B7）。`verify.md:148-149` 把这处订正挂在「与 B7 同批订正」上，但仓库里没有对应变更，两表会一直错下去。两份文档属 part2，建议按一般处理。
- `f_jit/doc/design-m1.md:1521-1543` 与 `f_jit/doc/jit-bytecode-m1.md:2126-2148` 的 `0x50–0x6F` 表逐字重复（`diff` 为空），任何订正都要改两处，本次 B7 的寄存器错就是复制体未同步的实例（§2 重复逻辑，part2）。
- `f_jit/README.md:651` / `README_en.md:691` 的公开 API 索引把 `initialCapacity` 标为 `(var)`（实现已是 `public static mut prop`，`HandleTable.cj:149`），且缺 `capacityLimit`（prop，`:159`）与 `retiredCount()`（func，`:1271`）；`releaseEscaped` 只在正文出现（`README.md:576`）、未进索引。另外 README 全文没有 `!` 的类型分派说明（`!2 == -3`、`!s` 编译期报错），而 spec 已把它定为契约。README 属 part1。
- `NativeAssets.liveCount()` 用两次独立 `AtomicInt64.load()` 求差（`f_jit/src/backend/NativeAssets.cj:47-48`），仍不是一致快照，并发读可能瞬时为负；与 `fix-native-assets-atomic/proposal.md:11-12` 描述的「并发下偏低甚至为负」只在「丢增量」维度上被修复，建议由该源码所属部分复核其公开契约。
