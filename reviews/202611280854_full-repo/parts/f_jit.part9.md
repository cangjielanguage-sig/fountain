# f_jit 模块审查报告（模块第 9/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（全模块 305 个 `.cj` + 290 个 `.md`；**本部分 20 个文件，全部为 `.md`**）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；无 diff 可比，全部问题来源记「存量」）
- **审查重点**：动态调用 / 桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG；本部分文件全部是 `doc/spec/**` 规格与验收文档，重点落在「规格与实现是否一致、文档内部是否自洽」
- **报告版本**：v1（本文件是分报告，由主 Agent 合并进 `docs/review/2026-11-28/f_jit.md`）
- **本部分范围**：`f-jit-m1`（proposal / 9 份 spec / tasks / verify）、`f-jit-m2.1`（design / proposal / facade-bridge spec / tasks / verify）、`f-jit-m2.2`（design / proposal / base-contracts spec）

## 发现

### [一般][存量] M1「用户面再导出」清单与实现不一致：`CallMarshal` 被说成用户面、`HandleTable` 从未再导出

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:137`、`f_jit/doc/spec/f-jit-m1/proposal.md:43`；实现侧 `f_jit/src/CallMarshal.cj:41`、`f_jit/src/runtime/JitContext.cj:114`、`f_jit/src/Root.cj:23`–`f_jit/src/Root.cj:46`、`f_jit/src/runtime/HandleTable.cj:142`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API / 契约与实现不符）、§14.2（公开 API 未按契约暴露）
- **证据**：静态确定 —— ① spec:137 的 requirement 原文要求「用户 SHALL 能通过一次导入见到全部用户面声明（门面、产物句柄、**封送**、**句柄表**、类型与错误码常量…）」；② `CallMarshal` 实际是 `protected class`（`CallMarshal.cj:41`），根包 `Root.cj:23-46` 的 19 条 `public import` 里既无 `CallMarshal` 也无 `runtime.HandleTable`；③ `HandleTable` 是 `public class`（`runtime/HandleTable.cj:142`）但只存在于子包，用户 `import fountain::f_jit.*` 后不可见，必须自己猜到 `fountain::f_jit.runtime.HandleTable` 才能用；④ `proposal.md:43` 同一行既把 `CallMarshal` 列进「新增用户面」，又把它列进「为 `protected`，不进用户面」，自相矛盾；⑤ 项目自己的设计文档 `f_jit/doc/design-m1.md:679`、`:925` 明确 `HandleTable` 属用户面（宿主需 pin/release 逃逸句柄）、`CallMarshal` 为 `protected`（同文件 `:863`）；⑥ 同一条 `proposal.md:43` 还把 `JitContext` 写成「`protected`，不进用户面」，实际声明是 `public class JitContext`（`runtime/JitContext.cj:114`），其它包可直接 `import fountain::f_jit.runtime.JitContext` 引用——同句中 `Engine`/`JitValue` 确为 `protected`（`base/Engine.cj:29`、`base/JitValue.cj:42`），说明只有 `JitContext` 一条漂移
- **描述**：规格把两类声明都写进用户面，但实现只放行其一、且放行的那个不是规格点名的那个。后果：宿主按 spec / design 写 `HandleTable.pin(...)` 时，照「一次导入」的习惯写法编译不过；而 `CallMarshal` 被 spec 承诺可见、实际不可见（这一侧代码是正确的，错在文档）。同时暴露一个真实缺口：`HandleTable` 目前只能经子包路径访问，与「用户唯一入口」的门面设计不一致。`JitContext` 的可见性错标则相反：文档说内部、代码是 `public`，若后续按文档收窄，会被下游当作破坏性变更。
- **建议**：二选一并回写文档：① 在 `Root.cj` 补 `public import fountain::f_jit.runtime.HandleTable`（与 design §7.6 一致，同时确认不连带导出 ctx/IterTable）；② 若后续已决定收紧用户面，则把 `facade-bridge/spec.md:137` 的「封送、句柄表」删掉，并从 `proposal.md:43` 的用户面清单里移除 `CallMarshal`。无论哪种，`proposal.md:43` 的双重列举都必须改。

### [一般][存量] 两份 M1 规格对「编译缓存键」给出互斥定义，且实现含规格未写的维度

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:90`、`f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md:108`、`f_jit/doc/spec/f-jit-m1/verify.md:38`；实现 `f_jit/src/CompilePipeline.cj:59`、`f_jit/src/CompilePipeline.cj:96`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（规格与实现漂移、同名概念两套口径）、§11（契约与实现不符）
- **证据**：静态确定 —— ① facade spec:90 写「编译缓存 SHALL 为进程级并以源码（或整份字节码）的 128 位指纹为键」；② backend spec:108 写「编译缓存键 SHALL **仅包含**架构、处理器特性与字节码指纹」（对应 `src/backend/CompileCacheKey.cj:24`，三字段实现确实是 arch/cpuFeatures/fingerprint，此侧自洽）；③ 门面层真正的缓存键是 `'src/${modeKey(jit)}/v${verMajor}/fp${strictFp}/${fnv1a128(source)}'` 与 `'fbc/${modeKey(jit)}/${fnv1a128(raw)}'`（`CompilePipeline.cj:59`、`:96`），含 **JIT 模式、verMajor、strictFp** 三个规格里没有的维度；④ `verify.md:38` 自己记录了「缓存键加入引擎维度：`src/<off|auto|force>/<fingerprint>`」以修掉 CRITICAL-01，但两份 spec 均未回写
- **描述**：同一个术语「编译缓存键」在 mirror 内出现两个互不相容的定义（一个是纯指纹、一个是 arch+features+fingerprint），而实现是第三种（指纹前缀 + 引擎/版本/严格浮点）。这不是措辞问题：按 facade spec 写断言（同源不同 `JitMode` 命中同一条目）会得到错误结论；history 里 Off 与 Auto 串用同一产物正是这个「按指纹做键」的直接后果（verify.md:32）。
- **建议**：facade spec 的 requirement 改为「以 `(JitMode, verMajor, strictFp, 源码/整份字节码 128 位指纹)` 为键」，并在 scenario 里补一条「同源不同 `JitMode`/`strictFp` 不共享条目」；backend spec 的「编译缓存键」改称「后端代码缓存键（`CompileCacheKey`）」，与门面缓存区分命名。

### [轻微][存量] `verify.md` 自报的 requirement 总数（40）与文件实际（77）不符

- **位置**：`f_jit/doc/spec/f-jit-m1/verify.md:4`；对照 `verify.md:181`–`verify.md:191` 的逐 capability 表
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）
- **证据**：静态确定 —— `verify.md:4` 写「9 份 spec（**40 requirement** / 156 scenario）」；同文件逐 capability 表 9 行的 requirement 列相加为 7+4+8+10+10+11+10+10+7 = **77**；对 `doc/spec/f-jit-m1/specs/*/spec.md` 统计 `^### Requirement` 亦为 **77**（scenario 156 与文档一致）
- **描述**：校验报告开头把被校验对象规模写小了一半，读者据此会低估覆盖面（也会让「9 份 spec 全绿」的结论失去量纲）。scenario 数正确，说明是 requirement 一处陈旧值未随规格扩写更新。
- **建议**：改为 77，并在 `scripts/check_scenarios.sh` 输出里同时打印 requirement 计数，避免下轮再手写。

### [轻微][存量] `verify.md` 第五 / 第六轮的用例增量与总数算术不自洽

- **位置**：`f_jit/doc/spec/f-jit-m1/verify.md:281`–`verify.md:284`（第五轮）、`verify.md:304`（第六轮）；基线 `verify.md:272`（1108/1108）
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）、§8（基线可复现性）
- **证据**：静态确定 —— 第五轮结论写「f_jit 全量 **1112/1112**，新增 **3 例**」，但 1108→1112 是 +4，且同一张表实际列出 4 个新用例（`EmitAudit_test.absoluteAddressIsExempt` + `JitBacked_test` 的 `plainUnitStaysJitBacked`、`constMirrorUnitStaysJitBacked`、`recursiveUnitStaysJitBacked`）；第六轮写「`Pow_test` 6 例 + `NumberLitSci_test` 3 例；全量 **1123/1123**」，但 1112 + 9 = 1121
- **描述**：两处都有 2 例的口径差。若确有未列出的用例（如 `***` 词法、负指数分支），文档应补列；若没有，则总数记错。无论哪种，「用例数单调增长」这条验收口径都失去可核对性。
- **建议**：列出每轮新增用例名与数量，使 `上一轮总数 + 新增 = 本轮总数` 恒成立；或直接引用 `cjpm test` 输出原文。

### [轻微][存量] `tasks.md` 的完成口径与 `verify.md` 的未完成项并存，INFO-01 只订正了标题

- **位置**：`f_jit/doc/spec/f-jit-m1/tasks.md:125`、`tasks.md:127`、`tasks.md:150`；对照 `verify.md:23`（INFO-01）、`verify.md:162`–`verify.md:177`
- **来源**：存量
- **判据**：review-checklist §14.1（进度口径 / 半成品）、§13（文档自相矛盾）
- **证据**：静态确定 —— S5.4 同一个 `[x]` 条目内，括号里仍写「x86 执行证据因 x86 SDK alpha.07 缺 stdx.effect **未取**，按非原生跳过记录，待同版本 SDK/CI 补」，紧随的子项却写「已完成（口径更正 2026-10-19）… 真机 x86_64 **全绿**」；`verify.md:23` 的 INFO-01 已点名这处矛盾但状态是「留档」而非「已修复」，且只改了标题口径
- **描述**：tasks 115 项全勾，而 verify 明确写「apply 的 115/115 不等于规格全绿」（7 条 scenario 无断言、5 条部分覆盖、JIT 全局串行、非 Linux 无执行证据）。两者并存时，后续里程碑按 `[x]` 复用「已完成」印象的风险是真实存在的（INFO-01 原文即为此担忧）。
- **建议**：S5.4 的括号改为「框架/单指令断言已完成；整单元执行证据见 §5.8 与 verify 真机记录」，并把 verify 的 7 条缺口在 tasks 里以 `[ ]` 补登记（或加一节「未覆盖清单」），避免全勾假象。

### [轻微][存量] `tasks.md` 的构建与镜像对照命令指向已不存在的路径

- **位置**：`f_jit/doc/spec/f-jit-m1/tasks.md:7`–`tasks.md:8`、`tasks.md:173`
- **来源**：存量
- **判据**：review-checklist §13（链接 / 路径失效，复现命令不可执行）
- **证据**：静态确定 —— `tasks.md:7-8` 让读者 `cd /mnt/linux_share/.../.worktrees/f_jit/f_util && cjpm build`，当前仓库已无 `.worktrees/` 目录；`tasks.md:173` 声称镜像「与 `openspec/changes/f-jit-m1/` 逐字节一致」，当前 `openspec/changes/` 下只有 `archive/`（其内 5 个与本模块无关的变更），`git ls-files openspec` 返回 0（`openspec/` 被 `.gitignore:62` 忽略）
- **描述**：这两处是文档里唯一的「怎么复现」入口，都不可执行；镜像与源的「逐字节一致」结论也就无法复核。
- **建议**：把路径改为相对模块根（`cd f_jit && cjpm build`），并把「与 openspec 逐字节一致」改为「镜像时点的一次性校验记录（openspec 不入库）」。

### [轻微][存量] M1 门面「六步调用」把「解包」同时放在第 3 步与第 4 步

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md:53`、`spec.md:67`；实现 `f_jit/src/JitFunction.cj:555`
- **来源**：存量
- **判据**：review-checklist §13（契约描述自相矛盾，步骤边界不清）
- **证据**：静态确定 —— 三态收尾的定义（spec:53）已含「成功则**解包**返回」；统一调用包装（spec:67）又列「六步：参数个数校验 → 封送 → 三态收尾 → **解包** → 返回类型一致性校验 → 返回与清理」，解包出现两次、且第 5 步「返回类型一致性」在实现里被前置到封送之前（`JitFunction.cj:555` 起：先校验 `T` 与 `retType`，再开窗口/封送）
- **描述**：实现顺序与文档叙述不同（第 5 步前置是合理优化：早失败、省窗口与转储分配），但规格仍按「1→6」线性描述，且把解包拆成两步。按文档写用例的人会去断言「第 3 步不应已解包」，与实现冲突。
- **建议**：把六步改为「① 实参个数 ② 返回类型契约（前置） ③ 封送 ④ 执行 + 三态收尾（含解包） ⑤ 清理（全路径）」，并注明第 2 步前置的理由。

### [轻微][存量] `f-jit-m2.2` 归档缺 `verify.md`，1 条 partial 与 2 条 N/A 无书面理由

- **位置**：`f_jit/doc/spec/f-jit-m2.2/`（目录无 `verify.md`）、`f_jit/doc/spec/f-jit-m2.2/scenario-map.tsv`（`返回类名驱动静态解析` = partial；`下转型拒绝`、`无法静态判定拒绝` = N/A）；对照 `f_jit/doc/spec/f-jit-m2.1/verify.md:1`
- **来源**：存量
- **判据**：review-checklist §14.1（验收记录缺失）、§13（结论无法复核）
- **证据**：静态确定 —— m2.1 有 `verify.md` 且逐条解释 partial 的成因；m2.2 目录只有 design / proposal / scenario-map / specs / tasks，`proposal.md:22` 用「验收证据见同级 `verify.md`（**若存在**）」规避，于是 partial 与 N/A 的判定依据（为什么这两条无法用例化）在整个变更内无处可查
- **描述**：同一批次的三个里程碑验收体例不一致：M1 有完整 verify、M2.1 有收口 verify、M2.2 没有。`methodResultChain` 为何只是 partial（是结构性属性还是漏测）无法判断，下轮重审只能重新取证。
- **建议**：补一份最短 `verify.md`：列出 21 条映射的 full/partial/N/A 分布、partial 与 N/A 的理由、当时全量用例数；或把理由写进 `scenario-map.tsv` 的第 5 列。

### [轻微][存量] 后端规格中的繁体字笔误

- **位置**：`f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md:25`
- **来源**：存量
- **判据**：review-checklist §13（拼写 / 格式）
- **证据**：静态确定 —— 「镜像 SHALL 连续按 8 **字節**排布」，同文件其余处均为「字节」
- **描述**：不影响语义，属文档编辑残留。
- **建议**：改为「字节」。

### [轻微][存量] M2.x 镜像 spec 的公共结构字段清单落后于实现（`JitBindings` 六字段、`ClassDescriptor` 六字段）

- **位置**：`f_jit/doc/spec/f-jit-m2.1/specs/f-jit-facade-bridge/spec.md:20`（「`JitBindings` SHALL 携带四张表」）、`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-base-contracts/spec.md:8`（`ClassDescriptor` 枚举 5 字段）；实现 `f_jit/src/base/JitBindings.cj:47`–`JitBindings.cj:66`、`f_jit/src/base/ClassRegistration.cj:155`–`ClassRegistration.cj:177`
- **来源**：存量（归档期后由后续里程碑扩展，非本次改动）
- **判据**：review-checklist §13（API 清单与源码不符 / 文档过期）、§14.2（公开 API 未文档化）
- **证据**：静态确定 —— `JitBindings` 现有 6 个 `public let`：`methods`(47)、`fields`(48)、`ctors`(49)、`statics`(56)、`parents`(59)、`ignored`(66)，spec 只写「四张表」；`ClassDescriptor` 现有 6 个 `public let`（含 `isInterface`，`ClassRegistration.cj:177`），spec 只枚举 5 个。`parents` 是接口父接口名（宏登记），`ignored` 是 `@IgnoreJitBinding` 的成员级退出名单（D10：「既不由宏登记，也不退回反射包装」），两者在镜像里都没有说明。
- **描述**：两份镜像自称「该里程碑归档时的最终口径」（各自 `proposal.md` 的归档说明），但公共结构已比文档多两个字段。宿主按 spec 构造 `JitBindings` 不会知道 `ignored` 可以让某成员彻底退出绑定（这是「想跳过某个成员」的唯一入口）；手工构造 `ClassDescriptor` 漏填 `isInterface` 会默认 `false` 而走类分支诊断。镜像与主规范「互补、不重复」（`f-jit-m2.1/specs/f-jit-facade-bridge/spec.md:3-8`）的承诺因此出现空白。
- **建议**：按归档边界只补一句前向指引（「后续里程碑追加 `parents`/`ignored`（`JitBindings`）与 `isInterface`（`ClassDescriptor`），字段全集以 `src/base` 声明为准」），不重写当时验收口径；若希望镜像长期可读，把逐项枚举改为引用声明，只保留语义约束。

### 范围外提示（不计入本部分统计，供 `.cj` 部分接手）

- `src/runtime/HelperId.cj:121` 已登记 `IPOW = 84`，但 `name()` 的 `match` 只到 `83`（`:129`–`:203`），`84` 落到兜底 `'unknown(84)'`（`:213`–`:219`），`isFixed(84)` 因此为 `false`；同文件 `MAX_FIXED = 72`（`:125`）在 `src/` 内零引用且注释「M1 登记的 hid 合法值域」已与 H73–H84 的现状不符 —— 建议由运行期部分确认诊断文本与 `isFixed` 的消费面。
- `src/runtime/Interp.cj:603`（`CALL_FUNC`）与 `:664`（`runClosure`）都以宿主函数递归实现，`:212` 又把 `STACK_GUARD` 当 NOP；非尾递归深度由用户源码决定（`recursive` 仅尾位置改写为 `LOOP_BACK`），规格与实现均无深度上限或环检测 —— 属 §4 栈溢出面，建议由运行期 / 解释器部分评估可达深度。
- `doc/spec/feat-f-jit-pow-and-sci-notation/`（不在本部分）内部矛盾：`design.md:24`–`:25` 与 `proposal.md:30` 写 `IPOW = 77` / 「H77」，而 `tasks.md:14` 与实现是 `H84`（`HelperId.cj:121`）；77 实际已被 `CAST_FAIL` 占用（`HelperId.cj:99`）。

## 优化可行性方案

本部分 20 个文件全部为规格 / 验收文档，无可执行代码，无堆内存与 CPU 方案可提（0 / 0）。文档层面的可执行改进已并入上面各条「建议」，不重复计入本节。

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 文档记载的全量用例基线（560/560 → 859/859 → 1099/1099 → 1108/1108 → 1112/1112 → 1123/1123）在当前 HEAD 仍成立 | `f_jit/doc/spec/f-jit-m1/verify.md:7`、`:198`、`:244`、`:272`、`:284`、`:304` | 当前 HEAD 的 `cjpm test` 总数 / 通过数 / 失败数 | 融合环境（Linux，仓颉 1.3.0）`cd f_jit && cjpm test --parallel 1`，记录 TOTAL/PASSED/FAILED 并与文档对照 |
| 2 | `verify.md` 记录的 JIT 相对解释器吞吐（aarch64 43.8×、真机 x86_64 jit 2.28 ms vs interp 5.99 s）未随后续 `LOOP_BACK` H22 / 窗口池化改动漂移 | `verify.md:170`、`:158`、`:255` | 同机同 SDK 的改后中位数与离散度 | `cjpm bench -O2` 或 `PerfCompare_test`，同输入 200000 次、≥5 轮取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/f-jit-m1/proposal.md` | .md | ✅ | 目标与影响面；见发现 #1（`CallMarshal` 双重列举） |
| 2 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-backend/spec.md` | .md | ✅ | 10 requirement / 16 scenario；见发现 #2、#9 |
| 3 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-base-contracts/spec.md` | .md | ✅ | LocalType 0–12 / TypeToken 0–9 / ErrCode / Version(1,14,36,"FBC1") 与实现一致（后续里程碑已扩至 0–19、token 0–12，属正常演进） |
| 4 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | 26 B 目录项、256 项 opcode 表、HDR 新旧布局均与 `FuncDir.SIZE=26`、`OpInfo` 256 项、`FbcHeader` 一致 |
| 5 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 10 requirement / 24 scenario；与 tasks S3.x 逐条对应 |
| 6 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | T1–T29/T42–T48/T50–T53 = 40 项，与 `check_tmap.sh` 的 40 条一致 |
| 7 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 见发现 #1、#2、#7 |
| 8 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-module-skeleton/spec.md` | .md | ✅ | 六包结构与根包未登记 `f_jit` 的裁定与现状一致 |
| 9 | `f_jit/doc/spec/f-jit-m1/specs/f-jit-runtime/spec.md` | .md | ✅ | 64 B ctx 与 `JitContext`（`malloc<Int64>(count: 8)`）一致；helper 编号范围见范围外提示 |
| 10 | `f_jit/doc/spec/f-jit-m1/specs/f-util-fnv/spec.md` | .md | ✅ | FNV 黄金值抽验通过（`fnv1a64("123456789")=0x06D5573923C6CDFC`，空串基值、1024 位 16 字偏移基值与官方参考一致） |
| 11 | `f_jit/doc/spec/f-jit-m1/tasks.md` | .md | ✅ | 见发现 #5、#6 |
| 12 | `f_jit/doc/spec/f-jit-m1/verify.md` | .md | ✅ | 见发现 #2、#3、#4；场景矩阵数字经脚本复核（156 / full 139 / partial 5 / 缺口 7 / N/A 5）成立 |
| 13 | `f_jit/doc/spec/f-jit-m2.1/design.md` | .md | ✅ | 4 条不变量与 DAG 约束与模块结构一致 |
| 14 | `f_jit/doc/spec/f-jit-m2.1/proposal.md` | .md | ✅ | 归档反写声明与实际目录一致（`tasks.md` / `verify.md` 均在） |
| 15 | `f_jit/doc/spec/f-jit-m2.1/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 3 requirement / 14 scenario；「合并语义」「签名码不查 TypeInfo」两处收口已与 `JitBindings.withOverrides` / `JitBindSupport` 对齐；「四张表」清单见 #10 |
| 16 | `f_jit/doc/spec/f-jit-m2.1/tasks.md` | .md | ✅ | 5 项全勾，无空实现描述 |
| 17 | `f_jit/doc/spec/f-jit-m2.1/verify.md` | .md | ✅ | 14 条映射 13 full + 1 partial 与 `scenario-map.tsv` 一致 |
| 18 | `f_jit/doc/spec/f-jit-m2.2/design.md` | .md | ✅ | H63 / `CALL_HOST` 四步与 `HelperId.HOST_CALL_TRAMPOLINE=63` 一致 |
| 19 | `f_jit/doc/spec/f-jit-m2.2/proposal.md` | .md | ✅ | 见发现 #8（缺 verify.md，仅以「若存在」兜底） |
| 20 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-base-contracts/spec.md` | .md | ✅ | `ClassDescriptor.parents`（`ClassRegistration.cj:174`）、`PublicField` / `PublicMethod` / `PublicCtor` 均存在；`JsonFamily` / `ReflectionUnavailable` 拒绝 kind 与 `RegistrationException.cj:31-32` 一致；反射映射 4–11 / 其余 14 与 `ReflectRegistrar.mapType` 一致；`isInterface` 缺项见 #10 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无 `.cj`，无运行时语义可判；文档声称的类型码表（LocalType/TypeToken）、错误码表（1–20/23/99 + M2 的 21/22）、版本常量、容器头布局、缓存键组成已逐项落地比对，差异只出现在用户面清单与缓存键口径（见 #1/#2） |
| §1 死代码 | 0 | 文档无声明可判；做了等价机械检查：文档点名的每个符号 / 路径逐个在 `src/` 解析，均有实现（`Version.MAJOR/MINOR/HDR_SIZE`、`FuncDir.SIZE=26`、`CompileCacheKey{arch,cpuFeatures,fingerprint}`、`ClassDescriptor.parents`、`JitBindings.withOverrides`、`PublicCtor`、`RegistrationRejectKind.JsonFamily`、`ReflectRegistrar.mapType`、`Interp.CALL_FUNC`）。唯一解析不到的是 `HandleTable` 的**用户面可达性**（存在但未再导出），已按 #1 记为契约问题而非死代码 |
| §2 重复逻辑 | 0 | 已比对 9 份 M1 spec 的 requirement 标题/条文与 M2.1、M2.2 镜像：重复项仅为「MODIFIED 条文沿用 M1 原文」（镜像体例要求）与 `design.md` 的 4 条不变量模板（两处逐字相同），属 §2 误报边界内的刻意展开；`proposal.md` 的 What Changes 与 `design.md` 决策摘要逐字重复，同样属模板，不判 |
| §3 空实现 | 0 | 20 份文档无 `TODO` / 占位段落 / 「暂不支持」；唯一「勾了但没做完」的形态是 tasks 的完成口径（#5），已按 §14 归类 |
| §4 栈溢出 | 0 | 文档无递归实现可判；但规格未约定字节码递归深度上限，实现侧 `Interp.CALL_FUNC`/`runClosure` 为宿主递归 —— 已记入范围外提示，交给运行期部分定级 |
| §5 OOM | 0 | 文档给出的有界性承诺（窗口触顶 16、窗口倍增、迭代器条目 ≤ 嵌套深度、容器常量去重）与 tasks S4.3/S4.6 一致，未发现「按不可信长度预分配」被写成规范的地方 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史性能记录（`verify.md:158`、`:170`、`:255`），无 profile 自耗时占比；不据此下热点结论，已列入待验证假设 #2 |
| §6.2 大粒度锁 | 0 | 规格只承诺「注册与查找支持并发」（facade spec:81），临界区内容属实现；`verify.md:164` 已记录 JIT 全局串行（`envMtx`/`callMtx`）为已知工程债，本部分无法测持有时间 |
| §6.3 并发串行 | 0 | 同上；`verify.md:211` 建议改 per-call 隔离，属实现层任务，文档侧已如实登记，不重复计缺陷 |
| §6.4 低效算法 | 0 | 无代码；文档未对复杂度作可判定的承诺 |
| §7 降堆内存方案 | 0 | 文档层无可执行对象；`verify.md:152` 的「常量句柄泄漏 / 调用窗口泄漏」修复记录属实现部分 |
| §8 降 CPU 方案 | 0 | 仅 `verify.md:257`–`:259` 记录 H22 每回边分配数组（约 120 ns/迭代）待优化，位置在 `X86Lower`/helper，属实现部分，本部分不另提方案 |
| §9 local mode 可行性 | 0 | 本部分无函数体可做逃逸检查；`scope.md` 提到的 `docs/LocalMode.md` 是仓库级文档，不在本部分清单内 |
| §11 现有代码的 BUG（存量） | 10 | 本部分 10 条发现全部为存量（快照模式无基线）；其中 2 条一般（用户面契约、缓存键定义）、8 条轻微（数字/路径/步骤/验收记录/笔误/M2 镜像字段清单） |
| §12 并发安全与锁粒度 | 0 | 文档只描述并发承诺（适配器注册表并发、编译去重恰好一次、卸载排空），无法据文档判「不安全」；`verify.md:164`、`:175`、`:176` 已自陈排空与交错无用例，属已登记缺口 |
| §14 功能完备性与 README 覆盖 | 2 | #5（tasks 全勾 vs 未完成项）、#8（m2.2 缺验收记录）；本部分不含模块 README，`README` 覆盖检查留给含 README 的部分 |
| 文件覆盖（§13 等） | 8 | 20/20 全部读完；§13 命中 #1、#2、#3、#4、#6、#7、#9、#10（另 #5、#8 计入 §14） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 10 条（全部），是否纳入修复待用户决定；本部分未改任何源码。

## 总评

这 20 份文档质量在同类 JIT 规格里属上乘：requirement / scenario 编号可机检（`check_scenarios.sh` 复核 156 条、`check_tmap.sh` 无悬空），断言口径细到字节与错误码，且 `verify.md` 主动记录了自己的 CRITICAL / 未覆盖项（7 条无断言 scenario、5 条部分覆盖、JIT 全局串行），这种自我暴露在存量文档里少见。本轮没有发现与实现相反的**行为性**承诺（类型码表、错误码、版本常量、26 B 目录项、64 B ctx、FNV 黄金值全部对得上），也没有发现空实现或重复逻辑需要合并。

风险集中在两处「契约面」而不是算法面：① 用户面清单三处口径不一（spec 说「封送 + 句柄表」一次导入可见，实现里 `CallMarshal` 是 `protected`、`HandleTable` 根本未再导出，proposal 同一行还自我矛盾）——这是会让宿主按文档写代码就编译失败的那一类问题，建议优先回写；② 「编译缓存键」在两个 requirement 里被定义成互斥的两件事，实现是第三种，而 Off/Auto 串用产物正是这个定义缺口的直接后果，规格应把 `JitMode` / `verMajor` / `strictFp` 三个维度显式写进契约。

其余 8 条轻微项（requirement 计数 40 vs 77、用例增量 +3 vs +4、tasks 自相矛盾与失效路径、六步调用把解包算两次、m2.2 缺 verify、繁体笔误、M2 镜像字段清单落后（#10））都不影响运行语义，属文档维护债，可与下一轮规格回写一并处理。三条范围外提示（`HelperId.name(84)` 落到 `unknown(84)`、解释器非尾递归无深度上限、`pow` 变更文档写 H77 而实现是 H84）建议分别转给运行期、解释器与 `pow` 变更的负责部分，它们比本部分的文档问题更接近真实故障面。
