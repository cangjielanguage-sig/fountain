# f_jit 模块审查报告（第 3/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 3 个文件，全部为 `.md`：0 个 `.cj` + 3 个 `.md`；模块全量 305 个 `.cj` + 290 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支）
- **审查重点**：本部分为设计文档（M2 / M3 / 并行调用），逐条把文档承诺与 `src/` 实现对照；重点核对动态调用与 typecode 分支表、句柄与资源生命周期、并发语义、错误码分派、声明总览完备性
- **报告版本**：v1（分报告，不产出 `docs/review/` 模块报告）

> 本部分文件全部是设计文档，因此「缺陷」表现为**文档与实现不符、文档自相矛盾、增量未回写**；每条均给出文档行号 + 代码取证。代码中被撞见的存量问题只作「范围外提示」，不计入统计。

## 发现

### [一般][存量] 并行调用文档状态行写「未实施」，与 §9「P0–P6 已落地并归档」相反，§1「现状」仍描述已删除的实现

- **位置**：`f_jit/doc/design-parallel-call.md:3`（状态行）、`:9-21`（§1 现状表）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期 / 与实现相反）、§14（能力未接线口径）
- **证据**：静态确定 —— 文档第 3 行写「状态：**已设计、未实施**」，而同一文件 `:223`「已落地（P0–P6）」、`:249`「P6 → 已完成并归档」、`:251`「调用链不再有任何每调用一次的全局锁」；§1 所列「现状」在代码中已全部不成立：`JitFunction.cj` 已无 `callMtx`（仅 `:47`/`:500` 两处注释提及），`RuntimeEnv.cj:41-51` 的 `deadline` 已随 `stateTls`（`ThreadLocal<RuntimeState>`）改为线程私有，`HandleTable.cj:86` 已是 `FreeStripes`（分片锁）而 §1 `:15` 引用的 `HandleTable.cj:88-141` 现在落在 `FreeStripes` 定义区（`:86` 起），`envMtx`、`freeSlots` 全仓已无实现（`src/` 内仅剩注释）。
- **描述**：读者按第 3 行判断该能力「未实施」，会把 `:9-21` 当成现行瓶颈去重做一遍；而 `:13`/`:14`/`:19` 的行号引用（`JitFunction.cj:49/150`、`backend/JitExecutor.cj:37/126/150`、`RuntimeEnv.cj:30`）指向的代码已不存在，按引用去核对会得到错误结论。文档自身没有「§1 为设计前快照」的标注。
- **建议**：状态行改为「已实施（P0–P6，2026-11-26，后续优化 2026-11-27）」；把 §1 整体加一句「以下为设计前现状（历史），当前实现见 §9」并删除/刷新已失效行号；`HandleTable.cj:88-141` 的引用改成「分片空闲表前的全局 `freeSlots`」并去掉行号。

### [一般][存量] P6 验收门槛「8 线程 ≥ 5× 单线程」未达成，文档却记「P6 已完成并归档」

- **位置**：`f_jit/doc/design-parallel-call.md:170`、`:210`（门槛），`:233`（实测），`:249`（结论）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §8（性能结论必须给对照与门槛）、§13（文档结论与数据相反）
- **证据**：静态确定 —— `:170`/`:210` 写验收「8 线程 ≥ 5× 单线程」，`:233` 实测「2/4/8 线程 = 1.27×/2.40×/1.91×（共享 7 核 VM，8 线程超订）」；`:249` 仍记「P6 → 已完成并归档」，`:253`「验收：全量 1210 用例（1209 通过 + PerfOverride_test 高负载假失败）」。
- **描述**：同一文档内「门槛」与「实测」相差 2.6 倍，且 8 线程比 4 线程还低（1.91× < 2.40×），这是超订导致的真实扩展性上限信号；文档既未判定门槛失效、也未把结论降级为「共享 VM 下的参考值」，直接以「已归档」收口，会让后续优化误以为并行度已达标。`PerfOverride_test` 的「高负载假失败」同样只有断言、没有「为何是假」的证据。
- **建议**：把 `:170`/`:210` 的门槛改为**按环境分段**（独占核 N 核 ≥ X×、共享 VM 仅记录参考值），或在 `:233` 明确「门槛未达成，已按实测修订」；`:249` 的「归档」补一句「性能门槛未达成，转 P6b 待优化」，并把 8 线程低于 4 线程的现象作为已知结论写进风险表。

### [一般][存量] `HelperId` 增量表仍是旧编号 66/67/68/73/74/75，与同文档 §5.0 和实现 78–83 冲突

- **位置**：`f_jit/doc/design-m3.md:144`（§5.4 `HelperId` 行）；对照 `:98-102`（§5.0）、`:106-122`（§5.1/§5.2）、`:379`（附 B）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（配置/常量与源码不符）+ §2（同一事实多处重复 → 漂移）
- **证据**：静态确定 —— `:144` 写 `H_ANY_BOX=66`、`H_ANY_IS=67`、`H_ANY_AS=68`、`H_JSON_GET=73`、`H_JSON_SET=74`、`H_JSON_NEW=75`，同一行的备注却写「JSON 面 v0.3.15 顺延 H81–H83」；`src/runtime/HelperId.cj:102-107` 实为 `ANY_BOX=78 / ANY_IS=79 / ANY_AS=80 / JSON_GET=81 / JSON_SET=82 / JSON_NEW=83`（`src/compiler/Ops.cj:247-253` 同值），且 `:98-102` 明写「旧编号 … 在本文档 … **已全部替换**」。
- **描述**：73–76 在代码中已被时间/间隔构造占用（`DATETIME_NOW/PARSE/OF=73/74/75`、`DURATION_PARSE=76`、`CAST_FAIL=77`，见 `HelperId.cj:99`、`:115-118`），按 `:144` 分配编号会与既有 helper 撞号；66/67/68 在 `HelperId.cj` 已属保留区，而 §5.0 自己也宣告「66–68 已被占用」，同一份文档对这三个号给出两种状态。§5.0 声称旧编号「已全部替换」，实际未替换，属于典型的「同一张表在正文/附录重复、只改了一处」。这一行还写 `HelperId` 常量为 `H_ANY_BOX` 前缀，代码里没有 `H_` 前缀。
- **建议**：`HelperId` 行改为 `ANY_BOX=78 / ANY_IS=79 / ANY_AS=80 / JSON_GET=81 / JSON_SET=82 / JSON_NEW=83`，并删掉「编号接 H65 之后」的旧措辞；长期建议只保留 §5.1/§5.2 一处编号定义，§5.4 用「见 §5.1/§5.2」引用，避免第三次漂移。

### [一般][存量] 验签口径自相矛盾：§5.1.2 / §9 / §10 M2-1 仍称「单次 `is` 主线成立」，§11 已认定该方案语言上不可实现

- **位置**：`f_jit/doc/design-m2.md:171`（§5.1.2 `verify` 行）、`:380`（§9 决策行）、`:391`（§10 M2-1）；对照 `:474`（§11 第 1 条）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档自相矛盾 / 与实现相反）
- **证据**：静态确定 —— `:171` 写「验签 = **单次 `is (T1..Tn) -> R`**」、`:380` 写「验签口径 = 单次 `is (T1..Tn) -> R`（语言子类型语义）」、`:391` 写「**已实测确认** … `is` 支持函数类型 … **结案**——主线验签成立」；`:474` 写「**原方案语言上不可实现**：`T`/`R` 是运行期数据，`is` 右侧须静态类型，物化路径为 11^(n+1) 分支」。实现侧 `src/runtime/Signature.cj:92-97` 注释给出同一结论，主线是 `verifyReflective`（`Signature.cj:111`，`FunctionTypeInfo.of` 逐位比对），旧 `verify` 仅保留 0–2 元（`Signature.cj:169`），`CallMarshal.cj:177` 走的是 `verifyReflective`。
- **描述**：§11 是「实施偏差回写」，但它只说「本节记不一致」，没有把正文标为作废；`:391` 尤其危险——它宣称该方案「已实测确认、主线成立、结案」，是后续实现与测试的**选型依据**，而事实相反。按 `:171` 实现会得到只对 0–2 元、不校验具体类名的验签器（即代码里被 GAP-04/05 修掉的那一版）。
- **建议**：`:171`/`:380`/`:391` 就地加「**已被 §11 第 1 条废止**」，或直接改写为「`FunctionTypeInfo.of` 逐位比对」；`:391` 的「已实测确认」改成「已实测确认 `is` 支持函数类型，但**无法**用于运行期签名比对（见 §11-1）」。

### [一般][存量] §9 决策行称「非闭包实例 `close` → 19、`isClosed` = false」，与 §6.1.4 和实现的 `Resource` 契约相反

- **位置**：`f_jit/doc/design-m2.md:383`（§9 最后一行）；对照 `:256-258`（§6.1.4）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档自相矛盾）、§11（契约与实现不符）
- **证据**：静态确定 —— `:258` 写「**`Resource` 契约**：入口实例 `close(timeoutMs)` 卸载**单元** … 包装实例 `close(timeoutMs)` 释放本闭包」；`:383` 写「（非闭包实例：`close` → 19、`isClosed` = false）；`unload` 保持**单元级**不变」。实现与 `:258` 一致：`JitFunction.cj:227-232` 由 `owner.isSome()` 分派，入口实例走单元卸载，`:471-475` `isClosed()` 对入口实例返回 `state == 2`。
- **描述**：两句话对**入口实例**给出互斥语义（报错 vs 卸载）。按 `:383` 实现会让 `JitFunction` 无法满足 `Resource` 契约（`close()` 必然抛 19），M1 的 `unload` 语义也会断掉；`:383` 还把 `close` 与 `unload` 说成两个东西，而代码里 `unload` 就是入口 `close`。
- **建议**：删除 `:383` 括号内的「非闭包实例：`close` → 19、`isClosed` = false」，改为「入口实例 `close` = 单元卸载、`isClosed` = 已进终态（同 §6.1.4）」。

### [一般][存量] design-m2 未回写 M2.2 / M2.3 两个增量，且自称权威版本 v0.8.33 而规格已到 v0.8.34

- **位置**：`f_jit/doc/design-m2.md:3`（依据写 v0.8.28）、`:39-43`（§1「包与声明增量总览」）、`:469`（§11 写「权威语义以 v0.8.33 为准」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期）、§14（声明总览不完备 → 增量未接线口径）
- **证据**：静态确定 —— `doc/jit-bytecode-m2.md:3` 的版本日志已推进到 **v0.8.34**，新增「M2.3：裸 `as T` 合法（失败置 **7 BAD_CAST**）；`as T ?? V` 惰性取 `V`；下转型/类名未跟踪落到运行期 `$as$<C>`；新增固定 helper **H77 `cast_fail`**；新增 `@JitSignatures` 宏」。这些在 `design-m2.md` 中**一次都没有出现**（对 `SignatureRegistry`/`parents`/`cast_fail`/`H77`/`JitSignatures`/`as T ??` 全量 grep 均 0 命中），但代码已落地：`src/base/ClassRegistration.cj:174` `ClassDescriptor.parents`（注明 M2.2）、`src/compiler/Ops.cj:245` `CAST_FAIL=77`、`src/compiler/Lowerer.cj:2872-2896`（`$as$` 运行期判定 + H77）、`src/macros/JitSignature.cj:47` `@JitSignatures`。另有 M2.2 的类型化 adapter（`src/runtime/Signature.cj:375` `HostCallback.adapter`、`src/AdapterRegistry.cj`）同样未进 §1 总览。
- **描述**：§1 声称列出 M2 的**全部**新增声明与受影响声明，实际缺三类能力（M2.2 类型化 adapter + `ClassDescriptor.parents`；M2.3 `as` 收窄转型 + H77 + `@JitSignatures`）；`:3` 与 `:469` 两个「权威版本」还互相不一致（v0.8.28 vs v0.8.33），而两者都已落后于规格。只按本文件实施的人会漏掉运行期 `as` 路径，把 `as` 当纯编译期动作，错误码写成 7/22 之外的第三种或不报错。
- **建议**：`design-m2.md` 增「§11.1 M2.2 增量」「§11.2 M2.3 增量」两节（照 §11 表格体例），§1 总览补 `SignatureRegistry`/`HostCallback.adapter`/`ClassDescriptor.parents`/`H77`/`@JitSignatures`；`:3` 与 `:469` 统一改为当前规格版本。

### [一般][存量] M3-7「`as` 在左值非 15 时不经 helper、7 只出自 CAST」已被 M2.3 推翻，却被当作「结构性不重叠」的依据

- **位置**：`f_jit/doc/design-m3.md:287`（M3-7「为什么分列站得住」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（规格与实现漂移）、§11（契约与实现不符）
- **证据**：静态确定 —— `:287` 写「`as` 在**左值静态类型非 15** 时不经 helper（上行零操作 / 不相容 = 编译错误）⇒ 22 只出自盒面；7 只出自 `CAST`——**结构性不重叠**」。M2.3（`doc/jit-bytecode-m2.md:3`）已把非盒 `as` 改为「编译期优先 + 运行期兜底」，实现 `src/compiler/Lowerer.cj:2872-2896`：类名未跟踪时插入 `$as$<C>` 调用，失败分支发 `CALL_HELPER H77`（`CAST_FAIL`，恒置 7）；`src/compiler/Ops.cj:245`。
- **描述**：「22 只在盒面」仍成立，但「7 只出自 `CAST`」在**行为上也不成立**了——非 15 的 `as` 在类名未跟踪时经 H77 同样产出 7，两种码按接收者类型分派而非按来源分派。`:288` 的再启条件「若真出现串号（如把 `as` 的非盒路径接去 `CAST`）」描述的正是 M2.3 已落地的形态，读起来像「未发生」，会误导 T38 对拍用例的设计（例如断言非盒 `as` 不产生 helper 调用）。
- **建议**：`:287` 改为「22 只在 15 盒面（H80）、7 在 `CAST` 与 `H77 cast_fail`（非盒 `as` 运行期兜底）——**按接收者类型分派**，不按错误码来源分派」；`:288` 的再启条件改为「若出现同一接收者类型同时产出 7/22」。

### [一般][存量] `SignatureDescriptor.validate` 合法集仍写 0–8/10–11/14，与 M3「JSON 可作签名」和实现（含 16–19）冲突

- **位置**：`f_jit/doc/design-m2.md:170`（validate 行）；对照 `f_jit/doc/design-m3.md:81`（TypeRef JSON 可作签名）、`f_jit/doc/design-m3.md:379`（附 B helper 形参 16）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API/合法集与源码不符）
- **证据**：静态确定 —— `design-m2.md:170` 写「合法性（T/R ∈ 0–8、10–11、14；12/13 拒）」；实现 `src/runtime/Signature.cj:80-84` 的 `isLegalCode` 额外放行 `JSON_VALUE–JSON_NULL`（16–19，注释标「m3 §11 JSON 码 16–19 零注册」）。`design-m3.md:81` 明确「JSON 类型可作**参数 / 返回 / 局部 / 签名**（含跨桥）」，但 m3 全文没有一句回写「`SignatureDescriptor.validate` 合法集扩至 16–19」。
- **描述**：跨桥时 JSON 形参/返回要进 `SignatureDescriptor`，按 m2 `:170` 的规则会被判非法 → 验签失败 → 19。M3 只声明了能力、没声明被改的校验规则，交叉引用断链。
- **建议**：`design-m3.md` §1 `base` 行或 §5.1 补「`SignatureDescriptor.isLegalCode` 合法集 = 0–8/10–11/14/16–19」；`design-m2.md:170` 加「M3 起扩至 16–19（见 design-m3 §1）」。

### [轻微][存量] 特化面 API 名与实现不符（`plan`/`size`/`marshalArgs`/`plan` 可变性/开关归属）

- **位置**：`f_jit/doc/design-m3.md:132`、`:133`、`:134`、`:136`、`:159`；`f_jit/doc/design-m2.md:163`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API 与源码不符）
- **证据**：静态确定 —— 文档称 `SignatureTable`（protected class，`:132`）有 `func plan(sig)`（`:132`）与 `func size()`（`:133`）；实现为 `public class SignatureTable`（`src/runtime/SignaturePlan.cj`），方法名 `getOrBuild`（`:141`）与 `entryCount`（`:189`），另有 `buildCount`。文档称 `SignaturePlan.marshalArgs(args: CPointer<Int64>, out: …)`（`:134`），实现为 `marshalArgs(a: Array<Int64>): Array<Any>`（`SignaturePlan.cj:82`）。文档称 `HostCallback.plan` 是 `var`、在「验签完成时绑定」（`design-m3.md:136`；`design-m2.md:163` 同样写 `var plan`），实现是 `public let plan`（`src/runtime/Signature.cj:383`），在 `HostCallback` 构造时 `SignatureTable.getOrBuild(sig)` 绑定（`:391`）。文档 `:159` 把「特化开关（强制通用 / 强制特化）」挂在 `CompilePipeline`，实际开关是 `SignatureTable.enabled`（`SignaturePlan.cj:135`），`CompilePipeline.cj` 对该符号零引用。
- **描述**：不是语义错误，但四处在同一节内，按文档写会找不到符号；`:136` 的「验签完成时绑定」与实际「装箱时绑定」在时序上也不同（影响失效面判断：条目在验签前就可能持有 plan）。
- **建议**：按实现改名为 `getOrBuild`/`entryCount`/`marshalArgs(Array<Int64>): Array<Any>`；`plan` 改 `let`、绑定时机改「条目构造（装箱）时——m3 §5.3 原文『验签即建』的实现落点」；`:159` 的开关归属改为 `SignatureTable.enabled`。

### [轻微][存量] M2 声明表与实现签名不符（`HostCallback.sig` 可空、`ClassRegistry` 三个解析方法实为顶层函数）

- **位置**：`f_jit/doc/design-m2.md:161-162`（HostCallback 成员）、`:226`（ClassRegistry 解析辅助）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（声明与源码不符）
- **证据**：静态确定 —— `:162` 写 `let sig: SignatureDescriptor`（非空），实现是 `public let sig: ?SignatureDescriptor`（`src/runtime/Signature.cj:354`，`None` = 未验签，`:349` 注释与 `cached` 的 `:341-343` 都依赖可空语义）。`:226` 写 `ClassRegistry` 的成员 `func classOfField(...)` / `classOfMethod(...)` / `classOfCtors(...)`，实现是 `src/ClassRegistry.cj:197/211/225` 的**顶层** `protected func classFieldOf(desc, field)` / `classMethodOf(desc, method)` / `classCtorsOf(desc)`（首参是描述符，不是 `this`）。
- **描述**：`sig` 的可空性是「缓存 = 条目字段存在性」这一设计（§5.1.2 `cached`）的载体，写成非空会让实现者做不出「已验签/未验签」区分；解析辅助的形态差异会造成按名搜不到（`ClassRegistry.classOfField` 全仓 0 命中）。
- **建议**：`sig` 改 `?SignatureDescriptor` 并注明 `None` = 未验签；`:226` 改为 `classFieldOf/classMethodOf/classCtorsOf`（顶层 protected，首参 `?ClassDescriptor`），或明确写出它们是 `ClassRegistry` 的门面包装。

### [轻微][存量] M3-5 仍标「待实施」，其两项待办（`cjpm` 依赖、加载期防御拒绝）均已落地

- **位置**：`f_jit/doc/design-m3.md:271-276`（M3-5 标题与「剩余仅 … 两项待办」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14（接线缺失的反面：已接线却记未完成）、§13（文档过期）
- **证据**：静态确定 —— `:272` 要求「`f_jit/cjpm.toml` 增 `fountain::f_data` 依赖」，`f_jit/cjpm.toml:21` 已有 `"fountain::f_data" = {path = "../f_data"}`；`:273` 要求「加载器对解析失败防御拒绝」，`src/bytecode/ConstRegistry.cj:432-437` `parseJsonConst` 在 `JsonValue.fromStr` 异常时 `rejectFormat('JSON 常量解析失败 …（M3 §11 加载期防御拒绝）')`，`ConstRegistry.cj:169` 在 `PJson` 分支调用它。
- **描述**：`:275` 的「现状核查（2026-10-13）… 剩余仅『cjpm 依赖 + 防御拒绝』两项待办」在实现完成后未更新，读者会重复排期。
- **建议**：M3-5 状态改为「已结案（依赖与防御拒绝均已落地，位置：`cjpm.toml:21`、`ConstRegistry.cj:432`）」。

### [轻微][存量] H79 失败码只列 8、并称「纯读」，实现经 `$as$<C>` 可抛 21

- **位置**：`f_jit/doc/design-m3.md:109`（H79 行）；对照 `:169`（§7.1「问答 = 纯读」）、`:232`（§9「is/as 纯读 ⇒ 重放安全」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（错误码面与实现不符）、§12.1（失败路径 / 异步语义）
- **证据**：静态确定 —— `src/runtime/AnyHelpers.cj:52-63` 的 `anyIs` 在 `anyMatches` 命中 14 型时进入 `case 14`（`AnyHelpers.cj:160-161`），后者调用 `classBoundHit`；`classBoundHit`（`AnyHelpers.cj:177-196`）在判定体抛出普通异常时经 `:190-191` 转成 `HOST_EXCEPTION`（21），条目缺失 / 签名不符 / 返回非 Bool 则 `HANDLE_TYPE`（8）。
- **描述**：H79 的失败面是 {8, 21}，不是文档写的仅 8；它也不是严格意义的「纯读」——14 类界判定要执行一次宿主侧 helper。对盒与句柄表确实无写入，所以 §9 的「重放安全」结论不一定错，但前提没有被文档写清（失败即终止、不产生可观察副作用）。
- **建议**：H79 失败码改为 `8, 21`；§9 决策行补「纯读指不修改盒 / 句柄表；14 类界判定经 `$as$<C>`，失败 21 即 fail-fast 终止，重放不受影响」。若要求 `is` 永不失败，可把 `classBoundHit` 的异常降级为「不命中」，但那会改变错误码契约，需用户拍板。

### [轻微][存量] Map 的 `aux` 写「键码 << 8 | 值码」，实现只校验值码，键类型不可区分

- **位置**：`f_jit/doc/design-m3.md:112`（类型描述符）、`:114`（容器转型「精确区分」）、`:356`（附 A 同表述）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（规格与实现漂移）、§11（语义与规格不符）
- **证据**：静态确定 —— 前端确实压入 `(键码 << 8) | 值码`（`src/compiler/Lowerer.cj:2667`），但运行期 `mapAuxMatches`（`src/runtime/AnyHelpers.cj:217-221`）只检查 `(aux & 0xFF) == ANY`（或 `0xFFFF`），**完全忽略键码**；注释明确写键码被 `ConstMapKey` 包装擦除，「无法也不应校验」。因此 `box is Map<String,Any>` 对 `Map<Int64,Any>` 同样返回 1，`as Map<String,Any>` 同样命中。
- **描述**：文档把 `aux` 定义为「键码 + 值码」并声称按 `(typecode, aux)` 精确区分，但键维度实际不参与判定；这是**静默命中**（不报 22），使用者无法用 `is/as` 排除键类型不符的 Map。与发现 #8（签名合法集）同属「M3 能力声明未回写校验面」。
- **建议**：§5.1 / §5.2 / 附 A 补一句「Map 键类型在 `ConstMapKey` 处擦除，`is/as` 只校验值码；键类型一致性由宿主契约保证」；若要键级判定，需在 `ConstMapKey` 保留键码或改走宿主 `is HashMap<String,Any>`，并补 T38 正负用例。

## 优化可行性方案

本部分为设计文档，不含可执行的堆内存 / CPU 改造对象，**0 条**。文档中已有的两组实测数据（CALL_HOST 相对 user helper 4.6–5.8×，`design-m2.md:479`；并行扩展比 1.27×/2.40×/1.91×，`design-parallel-call.md:233`）已转入「待验证假设」，不在此当作结论。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 8 线程扩展比 1.91×（低于 4 线程 2.40×）是「共享 7 核 VM 超订」造成，独占核下可继续上升 | `f_jit/doc/design-parallel-call.md:233` | 独占核 / 独占 VM、8 线程 ≥10 轮的绝对值与离散程度 | `cjpm bench -O2` 跑 `ParallelThroughput_test` 1/2/4/8 线程，独占核 VM，取中位数与 P95；同时记录 `liveCount` 回基线 |
| 2 | M2.2 类型化 adapter 命中后，H63 仍余可观反射开销（文档自述 4.6–5.8×） | `f_jit/doc/design-m2.md:479`、`src/runtime/HostCall.cj:62-70` | adapter 命中率、`reflectiveInvoke` 自耗时占比 | 在 `HostCall.cj` 三路（adapter / plan / reflective）加计数埋点，配 `cjprof record` 跑 10 分钟稳态回调负载 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/design-m2.md` | .md | ✅ | M2 增量设计；与实现/规格漂移见发现 #4 #5 #6 #8 #10 |
| 2 | `f_jit/doc/design-m3.md` | .md | ✅ | M3 增量设计；编号表与特化面 API 漂移见发现 #3 #7 #9 #11 #12 #13 |
| 3 | `f_jit/doc/design-parallel-call.md` | .md | ✅ | 并行调用设计与实施记录；状态行/验收口径见发现 #1 #2 |

合计：`.cj` 0 个 / `.md` 3 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 三份均为设计文本，无可执行逻辑；「设计合理性」已按文档承诺 vs 实现（§13/§14）覆盖，命中见 #1–#13；无外部输入、无凭据与注入面 |
| §1 死代码 | 0 | 已把文档中出现的每个符号在 `src/` 全量检索：根包包装 `JitClosure`、`callWith`、`CFunc` 三条旧名在 `src/` 中已无定义（`grep "class JitClosure"` 只命中 `runtime/HandleTable.cj:1458` 的 **M1 内部闭包类**，与 §6.1.4 撤销的根包包装是同名的不同概念，属命名信息、非死代码）；`ClassRegistry.classOfField`、`SignatureTable.plan/size`、`H_ANY_BOX` 无实现但**属文档不符**，已归入 §13（#3 #9 #10），不重复计为死代码 |
| §2 重复逻辑 | 1 | 同一事实在正文/附录/决策表多处重复并已漂移：helper 编号（§5.0 叙述 / §5.4 表 / §5.1 / 附 B），单列为 #3（判据含 §2）；验签口径的重复（§5.1.2 / §9 / §10 / §11）归入 #4，不重复计数 |
| §3 空实现 | 0 | 三份文档无 `TODO`/`FIXME`/空承诺段落；唯一的「待实施」是 M3-5，经核对两项待办均已实现，按 §13 记 #11 |
| §4 栈溢出 | 0 | 文档描述的递归面（JSON 嵌套、链式成员访问、`TypeRef` 链）均为**前端编译期**且 design-m3 §4 明确括号配平为迭代取界；运行期无递归算法描述。无命中 |
| §5 OOM | 0 | 已核对文档给出的有界性主张：`SignatureTable` 实现有 `MAX_ENTRIES=128`（`SignaturePlan.cj:138`），`HandleTable` 分片空闲表定长目录 + 容量上限；文档 `design-m3.md:133`「天然有界」措辞不精确但结论成立，未达发现级 |
| §6.1 热点瓶颈 | 0 | 文档自带两组数据但均无「同环境改前/改后对照」，不构成发现，已列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 文档结论为「调用链不再有任何每调用一次的全局锁」，代码侧 `HandleTable.cj:86` 分片锁、`RuntimeEnv` TLS 与之相符；本部分无新增锁热点证据 |
| §6.3 并发串行 | 0 | 8 线程比 4 线程低（1.91× < 2.40×）只说明存在超订/串行信号，缺独占核线程状态证据，未定为并发串行缺陷；已列入待验证假设 #1，#2 只记「门槛与结论不一致」 |
| §6.4 低效算法 | 0 | 文档描述的热路径算法（helper 直调、plan 直通、argc≤4 展开）无复杂度问题；`SignatureTable` 线性扫 + 128 上限属有界小表，无热点证据 |
| §7 降堆内存方案 | 0 | 设计文档不持有对象；`PromotionGroup`/窗口记账的生命周期主张（`design-m2.md:463`、`design-parallel-call.md:122-127`）与实现一致，未见额外副本，无方案可提 |
| §8 降 CPU 方案 | 0 | 同上；唯一候选（反射路径占比）缺数据，见待验证假设 #2 |
| §9 local mode 可行性 | 0 | 三份文档未涉及 local mode，模块内也无「函数内大对象 + 峰值内存」证据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`，11 条缺陷全部来自文档契约（§13/§14），代码侧存量 BUG 计 0；为取证读到的实现（`Signature.cj`、`HostCall.cj`、`AnyHelpers.cj`、`JsonHelpers.cj`、`JitFunction.cj`、`HandleTable.cj`）未发现需计入本部分的存量缺陷，撞见的注释/默认值问题见「范围外提示」 |
| §12 并发安全与锁粒度 | 0 | 已核对 `design-parallel-call.md` 的 D2/D3/D3b/D3d/D6 去锁依据（所有权 + 发布后不可变、线程私有记账、提升槽只读）与实现一致（`FreeStripes`、`ThreadLocal`、`AtomicReference<PlanSnapshot>`），未发现同步缺失或锁顺序问题；`SignatureTable.enabled` 是 `public static var` 无同步读，但只作测试/宿主开关且为单值 Bool，未达发现级；文档状态与实测问题归 #1 #2（§13） |
| §14 功能完备性与 README 覆盖 | 2 | #6（M2.2/M2.3 增量未进声明总览）、#11（已完成项仍记待实施）；本部分不含 README，`README` 覆盖留给其他部分 |
| 文件覆盖（§13 等） | 3/3 | 无缺文件；`files/f_jit.part3.txt` 三行逐行对应 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 8 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分只有三份设计文档，代码质量风险不在语法层面，而在**文档作为契约的可靠度**：`design-parallel-call.md` 的状态行与 §9 完全相反、验收门槛 5× 与实测 1.91× 并存却记「已归档」，是读者最容易被带偏的一处；`design-m2.md` 虽有一节「实施偏差回写」，但正文的验签口径、`close`/`isClosed` 语义仍停留在被废止的版本，且 M2.2 / M2.3 两个增量整段缺失、权威版本号停在 v0.8.33；`design-m3.md` 的正文/附录大体与实现同步，只有 §5.4 的 helper 编号仍是 66–75 旧表（照抄会与 `cast_fail`、`datetime_*` 撞号）与 M3-7 的立论已被 M2.3 推翻。

文档侧没有阻塞级问题（不影响已交付代码的正确性），但这 13 条里有 6 条会直接导致「按文档实现就写错」：编号表（#3）、验签选型（#4）、`Resource` 契约（#5）、增量缺失（#6）、`as` 的 helper 路径（#7）、签名合法集（#8）。建议把 #3–#8 排进下一个文档修订批次，其余随各自模块的下一轮改动顺手更新。文档中出现的两组性能数字（4.6–5.8×、1.27/2.40/1.91×）均无同环境对照，只作为待验证假设保留，未进统计。

存量 13 条（一般 8 / 轻微 5），默认只报不修；是否纳入修复由用户决定。

## 范围外提示（不计入统计）

- `src/compiler/Ops.cj:245` 注释写「H66 `cast_fail`」，常量值为 77（`CAST_FAIL = 77u16`），注释编号是旧的 H66。
- `src/runtime/JsonHelpers.cj` `jsonNew`：`mode` 非 0 一律构造 `JsonArray`（`mode == 0` 才建对象），非法 mode 静默落数组，与 design-m3 §5.2「mode 0/1」无拒绝路径。
- `src/JitFunction.cj:227-269` 的 `close` 排空用 `spins * 100000` 忙等而非等待/让出，`timeoutMs` 的语义是「自旋次数」而非时间，长超时会烧满一个核。
