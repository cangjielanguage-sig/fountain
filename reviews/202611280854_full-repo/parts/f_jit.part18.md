# f_jit 模块审查报告（模块第 18/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（全模块 305 `.cj` / 290 `.md`；**本部分 20 个文件，全部是 `.md`**：六组归档变更 `optimize-compile-lookup / -compile-path / -decode-alloc / -emit-audit / -emit-fixup / -helper-table` 的 proposal / design / tasks / verify）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源写「存量」
- **审查重点**：f_jit 专项（动态调用/桥接正确性、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑）在本部分的落点是「归档规格与当前实现的漂移、护栏承诺与护栏实存、测量口径」
- **报告版本**：v1（分部分报告，供主 Agent 合并到 `f_jit_v2.md`；不写 `docs/review/` 下的模块报告）。**本版为复核合并版**：`parts/f_jit.part18.md` 已有一份同日 14:25 的初稿，本轮全量重读 20 个文件后逐条复核初稿结论——保留其成立项，补入本轮新取证项，并修正初稿的一处误判（「全量 1206 vs 1210」，见覆盖自检 §13 行）
- **本部分性质**：无 `.cj`。方法是「文档承诺 ↔ 代码事实双向取证」：规格声称落地的实现、护栏用例、判定闸门与基线数字，逐条回 `f_jit/src` 现场核对（`A64Emitter` / `A64Compiler` / `A64Lower` / `X86Lower` / `CompileCache` / `Compiler` / `JitFunction` / `UserHelperTable` / `FbcReader` / 15 个测试文件），不编译、不改源码

## 发现

### [一般][存量] 两份 design 的护栏清单列了仓内不存在的用例（合计 3 条），且与同变更 tasks / verify 的条数冲突

- **位置**：
  - `f_jit/doc/spec/optimize-emit-fixup/design.md:84-92`：表列 5 条，其中 `:92` 的 `missingLabelStillResolvesLikeBefore`（未绑定名字 → `labelOffset == -1`、`finishOrNull` 不 panic）**全仓只有这一行文档**
  - `f_jit/doc/spec/optimize-helper-table/design.md:60-67`：表列 4 条，其中 `:66 buildTableKeepsHidOrder`、`:67 pushTableDoesNotCopy` 同样只存在于本文档
  - 同变更自相矛盾：`optimize-emit-fixup/tasks.md:11-12`（E2.1「五条用例（见 design §4）」/ E2.2「4 条全绿（PASSED: 4）」）、`tasks.md:22`（E4.1「护栏四条全绿」）、`optimize-emit-fixup/verify.md:40-47`（只列 4 条）；`optimize-helper-table/tasks.md:10`（H2.1「3 条」）、`verify.md:26-32`（3 条）
- **来源**：存量（快照模式无 diff 基线）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §13（同一变更内数字/断言自相矛盾）
- **证据**：静态确定 —— `missingLabelStillResolvesLikeBefore` / `buildTableKeepsHidOrder` / `pushTableDoesNotCopy` 全仓 grep 0 命中（仅两份 design.md）；实际用例数：`f_jit/src/backend/A64EmitterFixup_test.cj` 4 个 `@TestCase`（`:39/:68/:79/:101`），`f_jit/src/HelperTableScope_test.cj` 3 个（`:52/:65/:82`，第三条实际名 `hidOrderIsPreserved`）
- **描述**：两份 design 的论证方式都是「护栏描述既有语义，改前也必须全绿」，护栏是等价性证明的主要凭据，缺两条后论证不闭合：
  1. `missingLabelStillResolvesLikeBefore` 缺失。`labelOffset` 由线性扫改为 `HashMap.get(...) ?? -1`（`A64Emitter.cj:90-95`），未绑定标签直接进入 `delta = labelOffset(r.label) - r.at`（`:136`）；`checkRange=false` 时 `finish()` 会把 `delta = -1-at` 无条件回填（`:150-161`）。旧实现同样如此，属既有语义，但正是需要一条断言钉住的边界，现在 `finishOrNull` 在未绑定标签上的行为没有任何用例覆盖
  2. `pushTableDoesNotCopy` 缺失。design 自己在 `:69` 承认「把 `pushTable` 改回每次 `buildTable`，功能仍绿」——说明该改动的引用语义本来就没有功能护栏；少这一条后，`pushTable` 退化成「压一份拷贝」不会被任何用例发现（性能回退无声，只能靠 A/B 数据）
- **建议**：二选一并落到文档 —— (a) 补两条用例（`missingLabelStillResolvesLikeBefore`：`bind` 后对未绑定名断 `labelOffset == -1` 且 `finishOrNull()` 返回 None 不抛；`pushTableDoesNotCopy`：同一张表 push 两次、pop 一次后 `find` 仍命中）；(b) 把两份 design 的表改成实际条目，并显式写「未绑定标签边界未覆盖、`pushTable` 引用语义仅由 A/B 数据判定」，同时统一 tasks / verify 的条数。不要留「设计 5 条 / 任务 5 条 / 验证 4 条」三份口径

### [一般][存量] compile-path 的 D2 伪代码仍是「空转次数」退避，与 verify 和实现（墙钟 1 µs→500 µs）差一个数量级

- **位置**：`f_jit/doc/spec/optimize-compile-path/design.md:30-46`（`:37 backoff = min(backoff * 2, 8192)`、`:38` 纯 CPU 空转、`:44`「最坏等待粒度 = 8192 次空转（数十 µs），远小于一次编译（0.4–0.9 ms）」）vs 同变更 `verify.md:41`（「墙钟退避（1 µs → 500 µs，预算 30 s）」）vs 实现 `f_jit/src/CompileCache.cj:130`（`backoffNs = 1000`）、`:143-147`（空转到 `backoffNs` 再翻倍，上限 `500000`）、`:43`（`awaitTimeoutNs = 30000000000`）
- **来源**：存量
- **判据**：review-checklist §13（同一变更内设计与验证结论不一致）
- **证据**：静态确定 —— 设计伪代码的退避单位是「次数」，实现与 verify 的单位是「纳秒」；最坏粒度 8192 次空转（数十 µs）vs 500 µs，相差一个数量级
- **描述**：归档件是后来者判断「这段自旋为什么这么写」的唯一依据。按 design 读会以为最坏只等数十 µs；按实现读最坏 500 µs，已是「一次编译 0.4–0.9 ms」的同一量级（占比 55%–125%），design `:44` 的核心论据（等待粒度远小于一次编译）在实现口径下不成立。同一份计划的另一副本 `f_jit/doc/optimize-compile-path.md:45-55`（本部分范围外）也是 64/8192 版本，而该文件 `§4` 决策日志与 `§7` 已按「1 µs→500 µs」记录 —— 一份文档内部两套参数
- **建议**：design D2 的伪代码与 `:44` 结论改成实现口径，并补一句「最坏 500 µs ≈ 半次编译，单 key 等待者唤醒延迟上限 0.5 ms 量级」；若认为 500 µs 过大，写明「上限由 8192 次空转改为 500 µs 的理由」。`doc/optimize-compile-path.md §2` 同步

### [一般][存量] compile-path 的「4 线程扩展比 ≥2.0×」目标未达成，规格与模块文档都没有「按停止条件结项」的结论句

- **位置**：`f_jit/doc/spec/optimize-compile-path/verify.md:10,61,74-75`
- **来源**：存量
- **判据**：review-checklist §13（文档结论与目标冲突）、§14.1（承诺与实现）
- **证据**：静态确定 —— 同一变更的 `proposal.md:3` 以「扩展比只有 1.3–1.7×」立题；`f_jit/doc/optimize-compile-path.md:21-22`（§1，范围外）把目标写成「提到 ≥2.0×（本机上限 2.2–2.4×）」；verify 实测 **1.84×**（`:61`），`:74-75` 只说「剩余差距不在 mmap、不在本变更的锁，需要专用机 + profile」，没有「目标未达成 / 按 §5 停止条件结项」的判定。模块文档顶部 `:3` 标「状态：**全部完成并归档**」
- **描述**：「全部完成」指 M0/C1/C2 工作项，容易被读成目标达成。实际停止条件（`§5`：C1/C2 连续两项未达门槛 ⇒ 停止）被触发了一半（C2 达门槛、整体扩展比未达 2.0×），但没有记录这个判定 —— 下一轮无法从文档判断「编译路径优化是否已关闭、还要不要再立项」
- **建议**：verify 结论表加一行「4 线程扩展比目标 ≥2.0×：未达成（1.84×），剩余差距按 §5 停止条件挂起，需专用机 profile」；模块文档 §1 目标行标注实际值

### [轻微][存量] `normalizeNewlines` 的调用次数与调用方记错（写 4 次、实为 5 处，且写错一个组件）

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/design.md:79-80`（「`normalizeNewlines` 在整条管线被调 **4 次**（`SourceCompiler` / `Parser` / `Lexer` / `NameResolver` / `DefiniteAssignment` 各一次），实测合计 38 µs」）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致；一行内自相矛盾）
- **证据**：静态确定 —— 一行里既说「4 次」又列了 5 个组件；实际调用点 **5 处**：`f_jit/src/compiler/SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`、`DefiniteAssignment.cj:51`、`PredefinedSnapshot.cj:141`（定义在 `Lexer.cj:123`）；`NameResolver` **0 处**
- **描述**：「4 次 / 38 µs / 占改后总延迟 0.5%」这三个数互相依赖，次数错了分母就不可复算；第 5 处落在 `PredefinedSnapshot.cj`（design 未列的组件），意味着「顺手去掉重复 normalize」的改造面比文档写的大。这是后续决定「要不要动它」的直接依据，属会误导立项的漂移
- **建议**：改成「5 处（`SourceCompiler` / `Parser` / `Lexer` / `DefiniteAssignment` / `PredefinedSnapshot`），合计 38 µs」；若 38 µs 是按 4 次测的，重测或注明「按 4 处测得，第 5 处未计」

### [轻微][存量] emit-fixup 护栏的标签规模：design 写 200，verify 与用例都是 300

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/design.md:88`（「建 200 个 `L<k>` 标签」）vs 同变更 `verify.md:44`（「300 条 `b`」）vs 实现 `f_jit/src/backend/A64EmitterFixup_test.cj:43`（`while (k < 300)`，断言 `:60` 为 `1 + k % 4`）
- **来源**：存量
- **判据**：review-checklist §13
- **证据**：静态确定 —— 用例循环上界 300，design 表写 200
- **描述**：单看是数字笔误，但它是「护栏覆盖多大标签表」的唯一描述，与 `branchesResolveToExactOffsets` 的强度直接相关（200 vs 300 决定是否覆盖到 `L2xx` 三位数名字的比较路径 —— 旧实现的字符串比较成本正来自同长度共享前缀）
- **建议**：design 改为 300，或注明「设计时按 200 估算，落地用 300」

### [轻微][存量] 已被本模块自己否证的「`ThreadLocal.get ≈ 300 ns」仍被后续规格当作决策依据

- **位置**：`f_jit/doc/spec/optimize-helper-table/design.md:56`（§2.4「收益仅为每次 find 省一次 TLS get（~300 ns），风险不成比例」）；源头 `f_jit/doc/spec/optimize-emit-audit/verify.md:18-24`、`proposal.md:7`
- **来源**：存量
- **判据**：review-checklist §13（模块内文档结论互相冲突）、§8（无基线的成本估算不得当依据）
- **证据**：静态确定（文档对文档）—— emit-audit 的 verify 明确写「『`ThreadLocal.get ≈ 300 ns`』的估算在本场景**未兑现**（598 × 300 ns ≈ 180 µs 应能在快模式看出 ~8%，实测没有）」，并把「跨场景外推微基准单项成本不可靠」写成教训；helper-table 的 design 仍用同一数字论证「不做 TLS 迁移」
- **描述**：结论方向（不做）安全，但依据已被同模块证伪，等于把一次失败的外推再用一次；后来者若据此外推别的热点（300 ns × N 次）会重复同一个错误
- **建议**：helper-table §2.4 改为「单项收益未测（emit-audit 已证该外推不可靠），故不以性能为由改契约」；`doc/optimize-call-path.md` 若引用同一数字，一并标注

### [轻微][存量] emit-fixup 的 tasks 只留最优配对性能数，与 verify 的保守口径不一致

- **位置**：`f_jit/doc/spec/optimize-emit-fixup/tasks.md:25-26`
- **来源**：存量
- **判据**：review-checklist §8 验证要求（不接受只报最优值）、§13（同一变更内记录口径不一致）
- **证据**：静态确定 —— `tasks.md:25` 记「端到端 44.32 ms → 6.42 ms（−85.5%）」，未标注是最优配对；`verify.md:29-36` 给出同批三次运行（44.32/24.06/45.07 → 11.06/11.10/6.42），并明确「保守取两臂最差配对（24.06 → 11.10）也有 −53.9%」
- **描述**：tasks 是被当作「已达成指标」扫读的文件，只留 −85.5% 会掩盖同批数据 3.7× 的离散度（改前 24.06–45.07 ms）。verify 做法正确，tasks 没跟上
- **建议**：`tasks.md:25` 补「（最优配对；保守配对 −53.9%，见 verify §3）」

### [轻微][存量] `A64Emitter` 的审计注释前半段仍主张 ThreadLocal，与后半段「用实例字段」及字段实现直接矛盾

- **位置**：文档 `f_jit/doc/spec/optimize-emit-audit/proposal.md:20`（「`ThreadLocal` 字段与 `auditList()` 删除」）、`design.md:16-29`（改实例字段的等价性论证）；代码 `f_jit/src/backend/A64Emitter.cj:446-452`
- **来源**：存量（`optimize-emit-audit` 落地时漏改上文注释）
- **判据**：review-checklist §13（注释/文档与实现不符）
- **证据**：静态确定 —— `A64Emitter.cj:450-452` 写「审计必须**按编译线程隔离**……放在 ThreadLocal 里零锁、零共享」，紧接着 `:453-459` 的字段注释写「用**实例字段**而不是 ThreadLocal」，`:460` 是 `private let audit: ArrayList<Int64>`；全文 `auditTls` / `auditList` 在 `A64Emitter.cj` 0 命中
- **描述**：前 3 行是 `optimize-compile-path` C0（并发编译 `IndexOutOfBoundsException`）时期的旧论证，留着会让后来者以为并发隔离靠 TLS，进而可能把 `audit` 改回静态/TLS；与紧随其后的实现说明直接矛盾，属可读性缺陷而非行为缺陷
- **建议**：删 `:446-452` 中的「放在 ThreadLocal 里零锁、零共享」，把「C0 曾用 TLS、后被 `optimize-emit-audit` 改为实例字段」压成一句历史注记，保留 `:453-459` 的实例字段说明

### [轻微][存量][待确认] 五份 tasks 勾选的 openspec 归档 / `validate --strict` 在仓库里没有对应产物

- **位置**：`f_jit/doc/spec/optimize-compile-path/tasks.md:23-24`（X.1「`openspec validate --strict`；归档 `2026-11-27-optimize-compile-path`」）、`optimize-emit-fixup/tasks.md:32-33`（E5.2/E5.3）、`optimize-emit-audit/tasks.md:28`（I5.2/I5.3）、`optimize-decode-alloc/tasks.md:9`（J4.2/J4.3）、`optimize-helper-table/tasks.md:28-29`（H5.2/H5.3）
- **来源**：存量
- **判据**：review-checklist §14.1（记录不可复核 / 接线缺失）
- **证据**：待确认 —— `openspec/changes/` 下只有 `add-f-a2a/` 与 `archive/`；`openspec/changes/archive/` 只有 5 个 `2026-11-20-*` 目录；全仓无 `2026-11-27-optimize-*` 产物。缺的信息：这些变更是否在别的机器/分支做过 openspec 归档后被清理，或从未真正归档
- **描述**：五份规格都把「归档 + `validate --strict`」勾成已完成，仓库里唯一产物是 `f_jit/doc/spec/<change>/` 镜像。`optimize-compile-path/tasks.md:3` 的 `skip_specs: true` 能解释「`openspec/specs/` 没有能力条目」，解释不了「`changes/archive/` 没有变更目录」。后果是归档链断在那里：复核「当时 accept 的是哪版 proposal」只能依赖镜像，而镜像本身没有校验记录
- **建议**：补回归档目录，或把这五处勾改成「归档产物仅保留 `f_jit/doc/spec/` 镜像（`skip_specs: true`）」

### [轻微][存量][待确认] 「多线程并发只读同一张 `HashMap` 是安全的」是断言，缺标准库依据

- **位置**：`f_jit/doc/spec/optimize-helper-table/design.md:31-32`（§2.2）；实现 `f_jit/src/JitFunction.cj:612-613`、`f_jit/src/runtime/UserHelper.cj:83-86,101-113`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态的并发访问需给出同步手段或证明线程封闭）
- **证据**：待确认 —— 本机没有仓颉 std 文档（`~/.autocode` 不存在，`cangjie-doc-lookup` 的本地文档源不可用），无法核对 `std.collection.HashMap.get` 的读路径是否纯读；仓内也没有并发 `find` 同一张表的用例
- **描述**：改后每个单元只建一张表，所有线程、所有嵌套调用共享同一 `HashMap` 实例（`helperTableCache` 在 `bindUserHelpers` 写入，`callLocked` 反复读）。发布本身有 happens-before（`CompileCache` 的 `synchronized(mtx)` 就绪门），这一点没问题；缺的是「并发 `get` 无副作用」的依据。若 `get` 内部有惰性写（统计/扩容），这里就是无同步的数据竞争
- **建议**：查 std `HashMap` 文档确认 `get` 不写；若要彻底消除该类风险，可在 `bindUserHelpers` 把表固化为 `Array<(Int64, UserHelperEntry)>`（hid 连续可直接下标）或有序数组二分，`pushTable` 压只读数组

> **存量 10 条（0 严重 / 3 一般 / 7 轻微），是否纳入修复待用户决定。**

## 优化可行性方案

本部分 20 个文件均为归档规格，不含可改造实现，**堆内存 0 条、CPU 0 条**。

文档里残留的「下一步线索」已逐条核对去处：`optimize-emit-fixup/verify.md:73-74` 的「`compileUnitWith` 逐字节 `for (x in b) out.add(x)` 拷贝」已由 `optimize-compile-copy` 处理（`f_jit/doc/optimize-compile-path.md §10`）；`design.md:79-80` 的 `normalizeNewlines` 与两组「未测得收益」改动（emit-audit、decode-alloc）都没有同进程改前基线 ⇒ **一律只进待验证假设，不进方案**。

（可读性层面的唯一动作是合并重复段落：同一份 C1 计划现存在 `design.md:30-46` 与 `doc/optimize-compile-path.md:45-55` 两处且已漂移，见发现 #2；这属文档维护，不计入本模块堆/CPU 统计。）

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `awaitReady` 的忙等退避在多等待者下会把 CPU 从「正在编译的线程」抢走，抵消 C1 的收益 | `f_jit/src/CompileCache.cj:143-147`（`while ((MonoTime.now() - t)… < backoffNs) {}`，无 `yield`/休眠），依据 `optimize-compile-path/verify.md:41` | 等待者数 → CPU 占用 / 编译线程推进速率的曲线；`MonoTime.now()` 单次成本 | 1 线程占住 key K 不 `finish`，起 1/4/16 个等待者，另一线程对 key X 反复 `claim+finish`；`cjprof record` 取 CPU self time 与线程状态，给 P50/P95 |
| 2 | `CompileCache.ready` 只增不减（按源码指纹键，仅 `JitFunction.close` 时 `remove`），长期运行会累积 `JitFunction` + 已 `mmap` 的机器码 | `f_jit/src/CompileCache.cj:31,81-87`；`f_jit/src/JitFunction.cj:260-263`；文档只给 `failures` 256 上限（`CompileCache.cj:95-105`） | 稳态下 `ready.size` 与 RSS 随编译次数是常数还是有斜率 | 连续编译 10⁴ 份不同源码且不 `close`，每 1 000 次采 `ready` 条数 / `getUsedHeapSize()` / RSS；对照「全部 `close`」组 |
| 3 | 4 线程编译扩展比的剩余差距（1.84× vs 本机上限 2.2–2.4×）在 GC / 分配器而非 codegen 共享状态 | `f_jit/doc/spec/optimize-compile-path/verify.md:74-75` | 编译期 GC 次数、分配量、线程状态（RUNNABLE/BLOCKED 占比） | 专用机（构建机无 `perf` / `strace`）：`cjprof record` 跑「4 线程 × 6 段不同源码」稳态 + 线程状态采样；对照 `JitMode.Off` 的 2.68–3.71× |
| 4 | 降低期直读操作数省下的 250 次小数组分配是否可测（verify 判为噪声内） | `f_jit/doc/spec/optimize-decode-alloc/verify.md:7-15` | `getAllocatedHeapSize()` 前后差、GC 次数差 | 同进程 A/B 各 21 次编译，读 `getAllocatedHeapSize()` 与 GC 次数（±40% 墙钟波动下墙钟无分辨率） |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jit.part18.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/optimize-compile-lookup/verify.md` | .md | ✅ | 判「不做」；0.2% 收益上限算式与 `slotOf` 线性扫现状一致，`50×200×5 ns = 50 µs` 与 `50 µs/24.9 ms ≈ 0.2%` 复算正确，无缺陷 |
| 2 | `f_jit/doc/spec/optimize-compile-path/design.md` | .md | ✅ | D3 `snapCache` 与 `Compiler.cj:43/80/95/127/140/155/190-219` 一致；D1 探针确已删除（`CodeBuffer` 无 `statsSnapshot`）；D2 伪代码见发现 #2 |
| 3 | `f_jit/doc/spec/optimize-compile-path/proposal.md` | .md | ✅ | 扩展比 1.23–1.70× 与「瓶颈在发射/可执行内存」自洽；两处引用路径（`f_jit/doc/optimize-compile-path.md`、`doc/optimize-call-path.md`）均存在且章节号对得上 |
| 4 | `f_jit/doc/spec/optimize-compile-path/tasks.md` | .md | ✅ | C3 取消与 doc §6 的 2.4%/5.9% 一致；归档勾选见发现 #9 |
| 5 | `f_jit/doc/spec/optimize-compile-path/verify.md` | .md | ✅ | C1（1 µs→500 µs、30 s）与实现一致；C0 记「改 ThreadLocal」属当时事实（后被 emit-audit 改实例字段，doc §12 已同步）；目标 ≥2.0× 见发现 #3 |
| 6 | `f_jit/doc/spec/optimize-decode-alloc/design.md` | .md | ✅ | §1 下标换算 `ops[k] ≡ code[off+1+k]` 推导正确；§3「跳过 decode 检查」经 `FbcReader.checkInstructionSet`（`:270-294`，FORBID/RSVD + 截断 + `p != end`）核实成立 |
| 7 | `f_jit/doc/spec/optimize-decode-alloc/proposal.md` | .md | ✅ | 37+36=73 处与 design/verify 自洽；`A64Lower.cj:148`、`X86Lower.cj:753` 新签名一致，`X86Lower` 无 `insns/offs` |
| 8 | `f_jit/doc/spec/optimize-decode-alloc/tasks.md` | .md | ✅ | J1–J4 全 [x]；J4.3 归档见发现 #9 |
| 9 | `f_jit/doc/spec/optimize-decode-alloc/verify.md` | .md | ✅ | 「未测得收益」记录诚实（快 +6.6% / 慢 −6.1%，±40% 跨进程波动），保留理由不含加速宣称 |
| 10 | `f_jit/doc/spec/optimize-emit-audit/design.md` | .md | ✅ | §3 等价性表逐条对上（`A64Emitter.cj:460-482`：允许集 `{19,20,29,31}`、reset 在 prologue 后、`auditAllows` 静态） |
| 11 | `f_jit/doc/spec/optimize-emit-audit/proposal.md` | .md | ✅ | 「删 ThreadLocal 字段」为真（0 命中），代码注释残留见发现 #8；x86 延后项已由 `fix-x86-audit-isolation` 落地（`BackendSelector.cj:258-289` 仍 TLS，与该变更为 x86 选 TLS 的口径一致），非悬空承诺 |
| 12 | `f_jit/doc/spec/optimize-emit-audit/tasks.md` | .md | ✅ | I4.2「无显著差异」与 verify §2 一致；`EmitAudit_test` 6 条（A64 实例 API 2 条）与 verify 吻合；I5.3 归档见发现 #9 |
| 13 | `f_jit/doc/spec/optimize-emit-audit/verify.md` | .md | ✅ | 598 次/编译与 `EmitAudit_test` 一致；「TLS ≈300 ns 未兑现」的教训记录完整（发现 #6 引用） |
| 14 | `f_jit/doc/spec/optimize-emit-fixup/design.md` | .md | ✅ | §2.2 单遍回填与 `A64Emitter.cj:131-165` 一致；`farCond` 第二遍真实（`A64Compiler.cj:55-62` 越界后新建发射器）；§4 护栏表见发现 #1，`:88` 200/300 见发现 #5，`:79-80` 见发现 #4 |
| 15 | `f_jit/doc/spec/optimize-emit-fixup/proposal.md` | .md | ✅ | 分段占比（`finishOrNull` 78–92%）与 tasks/verify 三处一致；「首个绑定优先」与 `bind` 实现一致（`:82-88`）；「失败时半成品字节不可观察」成立 |
| 16 | `f_jit/doc/spec/optimize-emit-fixup/tasks.md` | .md | ✅ | E2.1/E2.2 条数自相矛盾见发现 #1；E4.4 只记最优配对见发现 #7；E5.3 归档见发现 #9 |
| 17 | `f_jit/doc/spec/optimize-emit-fixup/verify.md` | .md | ✅ | 数据与推算全部复核通过（−85.5%/6.9×、−93.1%/14.4×、−96.1%/25.4×、保守 −53.9%）；4 条护栏与用例文件逐条对应 |
| 18 | `f_jit/doc/spec/optimize-helper-table/design.md` | .md | ✅ | §2.2/§2.3 伪代码与 `JitFunction.cj:587-593,612-613` 一致；§3 护栏表见发现 #1；`:56` 300 ns 见发现 #6；`:31` HashMap 只读论断见发现 #10 |
| 19 | `f_jit/doc/spec/optimize-helper-table/proposal.md` | .md | ✅ | 456–925 ns/helper 除法复算正确；`buildTable`/`pushTable`/`push` 三件套在 `UserHelper.cj:71-96` 齐备 |
| 20 | `f_jit/doc/spec/optimize-helper-table/tasks.md` | .md | ✅ | H2.1/H4.1「3 条」与实测 3 条一致（与 design 的 4 条冲突，见发现 #1）；H5.3 归档见发现 #9 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，**全部读完**。`.cj` 只作交叉取证（`A64Emitter` / `A64Lower` / `X86Lower` / `A64Compiler` / `Compiler` / `CompileCache` / `JitFunction` / `UserHelper` / `FbcReader` / 8 个测试文件），不计入本部分覆盖。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无 `.cj`。按「文档承诺即契约」把每条可证伪的声称回源码核对，命中：护栏清单与实际用例不符（发现 #1）、注释与实现相反（发现 #8）。语言特性只用两条：`Array` 引用语义 + `HashMap` 只读并发（后者降为发现 #10）、`internal` 只到本包（`A64Emitter` 为 `internal class`，`:39`）。typecode 分支表（`LocalType` 0–21 / `TypeToken`）在这 20 个文件中无对应描述，未涉及 |
| §1 死代码 | 0 | 本部分无代码可判，改做「文档点名的符号是否真实存在」的机械核对：声称**已删除**的 `A64Label`（全仓 `.cj` 0 命中）、`auditTls`/`auditList`（`A64Emitter.cj` 0 命中）、`CodeBuffer.statsSnapshot/resetStats`（0 命中）、`X86Lower` 的 `insns`/`offs`、`CompileStageProbe_test.cj`（文件不存在）—— 6 项全部兑现；声称**新增**的 `labels: HashMap`/`bind`/`labelOffset`/`resolve`/`finishOrNull`、`audit`/`resetAudit`/`auditSnapshot`/`auditAllows`、`buildTable`/`pushTable`/`helperTableCache`/`helperTableRef`、新 `translate(op, code, opsAt, …)` 全部存在。无「说删了还在 / 说加了没有」。`UserHelperTable.push(base, entries)` 现仅测试引用，属 design §2.1 明示保留的兼容入口，不计死代码 |
| §2 重复逻辑 | 1 | 跨文件复制段落已漂移：同一份 C1 退避计划在 `design.md:30-46` 与 `doc/optimize-compile-path.md:45-55` 各存一份，参数与实现脱节（发现 #2）。其余：proposal/design/tasks/verify 分工属模板，非重复逻辑；emit-fixup 测量表在 `verify.md` 与 doc §9.3 各一份，数字逐项一致（镜像无漂移）；`normalizeNewlines` 的复述漂移单独按 §13 记（发现 #4），不重复计数 |
| §3 空实现 | 0 | 无空函数体/占位 TODO；两处「不做」都有量化依据（compile-lookup 收益上限 0.2% < MOV 3%；C3 取消凭 M0 2.4%/5.9% < 15%）。`push` 作为兼容包装有 design 说明，不是接口默认空实现 |
| §4 栈溢出 | 0 | 本部分无递归实现或递归结构描述；唯一遍历是 `resolve` 对扁平 `relocs` 的单层循环（`A64Emitter.cj:135`），与调用深度无关 |
| §5 OOM | 0 | 唯一的全量物化面是 `Compiler.snapshot()` 的 O(F) 拷贝，已被 C2 缓存消掉（`Compiler.cj:190-219` 命中即返回）；helper 表由「每次调用建一张」改为「每单元一张」，方向是降内存。`ready` 无上限属旁证，记待验证假设 #2 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史测量（`finishOrNull` 78–92%、`snapshot` 41.5%@4T、helper 表 456–925 ns/F/call），本轮未复测、无 `cjprof`/`cjpm bench` 数据 ⇒ 不新增热点结论；`verify.md:74` 明说剩余差距需专用机 + profile |
| §6.2 大粒度锁 | 1 | `awaitReady` 已从「每轮取全局锁」改为墙钟退避（`CompileCache.cj:128-150`，与 −98.4% 一致），锁粒度问题解决；剩忙等本身（无 `yield`）作 CPU 侧问题记待验证假设 #1。`Compiler.snapshot()` 的 O(F) 构造在 `mtx` 内（`Compiler.cj:191-218`），C2 后命中路径只剩两次取值，不再构成大粒度锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn(...).get()` 类描述；C0/C1/C2 三段都是「4 线程共享 Compiler」的并发测量，方向正确（先提交后汇合） |
| §6.4 低效算法 | 1 | 按文档核对三处复杂度修复真实生效：标签线性扫 → `HashMap`（`A64Emitter.cj:54/82-95`，O(R×L) → O(R)）、`finishOrNull`+`finish` 双遍 → 单遍 `resolve`、helper 表 O(F)/call → O(1)/call（`JitFunction.cj:613`）。仍存的名字线性扫（`PredefinedSnapshot.slotOf`）已由 compile-lookup 用 0.2% 上限论证不做，算式自洽，不重报 |
| §7 降堆内存方案 | 0 | 本部分无实现；文档内「下一步」只列 CPU 项，且 `compileUnitWith` 逐字节拷贝已由 `optimize-compile-copy` 处理，无可量化堆方案 |
| §8 降 CPU 方案 | 0 | 同上。两组「未测得收益」改动（emit-audit、decode-alloc）无改后基线，按铁律只保留「严格更少工作」的定性理由，不写成优化结论 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象；`scope.md` 的 LocalMode 资料针对 `docs/LocalMode*.md` 全仓方案，不在这 20 个文件的可判范围 |
| §11 现有代码的 BUG（存量） | 10 | 本部分无 `.cj`，「存量 BUG」表现为规格事实性错误：发现 #1–#10 全部为存量，均给出位置 + 判据 + 证据等级。同时核对 6 条关键语义在实现中成立：`bind` 首次绑定优先（`A64Emitter.cj:82-88`）、`resolve` 的 `done` 幂等（`:131-165`）、失败丢弃发射器（`A64Compiler.cj:55-62`）、`snapCache` 5 个入口全失效（`Compiler.cj:80/95/127/140/155`）、30 s 墙钟预算（`CompileCache.cj:43`）、helper 表绑定期构建（`JitFunction.cj:402-406`）—— 无「规格与实现相反」 |
| §12 并发安全与锁粒度 | 1 | 发现 #10：共享 `HashMap` 只读并发的安全性是断言、缺 std 依据（待确认）。其余已核：审计表由 ThreadLocal 改实例字段后，隔离性由「每次 `compileOnce` 新建发射器」保证（`A64Compiler.cj:71`）；helper 表在 `bindUserHelpers` 发布前构建，发布经 `CompileCache` 的 `synchronized(mtx)` 就绪门，具备 happens-before |
| §14 功能完备性与 README 覆盖 | 3 | 发现 #1（两处 design 护栏未落地）、#3（目标未达成无结项）、#9（归档记录无产物）。本部分不含 README/`README_en`（在其它部分）。规格点名的 15 个测试文件与 6 个实现符号全部存在，`X86Compile_test` 实际在 `src/compiler/`、文档只写文件名，不算错误 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，20 个 `.md` 逐个读完。（**初稿更正**：初稿把「`verify.md:12` 1210 条 vs `doc/optimize-compile-path.md:88` 1206 条」判为漂移。实际是同一变更的两个时点 —— 1206 是 C1 完成时的全量，C0/C2 又新增 `A64AuditIsolation_test` 1 + `CompileConcurrency_test` 1 + `CompilerSnapshotCache_test` 2 = 4 条后成为 1210，与 emit-fixup 的 4 条护栏无关。1206→1210 属正常增量，不判缺陷） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 10 条（发现全部为存量；快照模式无 diff 基线），是否纳入修复待用户决定。待验证假设 4 条不计数。

## 总评

本部分是 `f_jit` 六组归档规格（编译路径并发、降低期直读操作数、发射审计、分支回填、helper 表、名字查找判定），不含源码。文档质量在平均线以上，最值得肯定的是**测量诚实**：emit-audit、decode-alloc 两组在实测没有收益时都明确写「未测得收益」，保留理由降级为「严格更少工作」，并把「跨场景外推微基准单项成本不可靠」写成教训；compile-lookup 更是在算出 0.2% 收益上限后直接判「不做」并保留测量记录。我逐条回代码核对，**声称落地的实现全部真实存在**：`labels` 改 `HashMap` 且首次绑定优先、`resolve(checkRange)` 单遍回填、`audit` 改实例字段、`translate(op, code, opsAt, …)` 去解码、`helperTableCache` 建在 `bindUserHelpers`、`snapCache` 在 5 个入口失效、`CodeBuffer` 探针已删 —— 没有「文档说改了、代码没改」。

剩余 10 条问题都不影响当前运行行为，但都是「归档件作为唯一凭据」时的可信度问题，按优先级：

1. **护栏清单有两处不实**（发现 #1，一般）：`missingLabelStillResolvesLikeBefore`、`pushTableDoesNotCopy` 只活在 design 表格里。等价性论证靠护栏，缺这两条时「改前也全绿」不再覆盖「未绑定标签」与「引用语义」，且 tasks/verify 的 4 条 vs 5 条、3 条 vs 4 条口径互相冲突。建议补用例而非改措辞。
2. **结论级漂移**（发现 #2/#3，一般）：`awaitReady` 的最坏等待粒度在 design 里是「数十 µs」、实现是 500 µs（半次编译）；compile-path 的 ≥2.0× 目标实测 1.84× 却没结项句，模块文档还标着「全部完成并归档」。这两条会直接影响下一轮调参与「要不要继续立项」的判断。
3. **同一事实多份复述且已漂移**（发现 #4/#5/#7）：`normalizeNewlines` 4 次 vs 实际 5 处（且把 `PredefinedSnapshot` 写成了 `NameResolver`）、200 vs 300 标签、tasks 只留 −85.5% 的最优配对而 verify 的保守值是 −53.9%。
4. **记录性残留**（发现 #6/#8/#9/#10）：300 ns 估算已被证伪仍被复用、`A64Emitter.cj:446-452` 的 ThreadLocal 旧论证与实例字段实现矛盾、五份 tasks 勾选的 openspec 归档在仓库里找不到产物、共享 `HashMap` 只读断言缺 std 依据。

无阻塞项。建议 #1 进修复清单（补两条护栏用例，成本很小），#2/#3 在下一次触碰这些目录时改（都是改文档，不动代码），#4/#5/#7/#8 顺手改，#9/#10 先把口径写清（「镜像即归档」/「待查 std 文档」），不必立刻补产物。

**范围外提示**（只记一句，不占统计）：`A64Lower.cj` 改用 `op = code[off]` 直读后不再做操作数长度校验，而 `FbcReader.cj:361` 的 `LoadedUnit` 有 `public init` —— 绕过 `load()` 直接构造的单元（截断/非法 opcode）会在 `A64Lower.i32/i64` 越界 panic，`decode-alloc/design.md §3` 的前提只对生产路径成立；`A64Emitter.finish()` 的 `case None => this.bytes()`（`A64Emitter.cj:167-172`）不可达且「先 `finish()` 后 `finishOrNull()`」会跳过范围校验（生产只用 `finishOrNull`，`finish` 仅测试用）；`CompileCache.cj:149` 的 `return None` 在 `while (true)` 之后不可达；`doc/optimize-compile-path.md:91` 决策日志留有一行空的 C3 模板行（C3 已在 M0 行判定「不立项」）。
