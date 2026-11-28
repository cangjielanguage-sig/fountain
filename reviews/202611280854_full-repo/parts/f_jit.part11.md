# f_jit 模块审查报告（模块第 11/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/doc/spec/**`（本部分 20 个文件，全部为 `.md`；`.cj` 0 个）
- **基线**：工作区快照（`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：模块专项为「typecode 分支表 / 句柄与资源生命周期 / 并发安全 / 递归与栈溢出 / 死代码 / 重复逻辑」；本部分文件是 OpenSpec 变更归档规格，故落点为 **§13 规格-实现一致性 + §14 功能完备性**，并用 `.cj` 交叉取证（只读，不改）
- **报告版本**：v1（分部分；合并稿见 `docs/review/2026-11-28/f_jit_v2.md`）

> **口径**：`f-jit-m3`（`proposal.md:21`「M3 已归档」）、`feat-f-jit-interface-and-inheritance`（`verify.md:42` 归档路径）、`feat-f-jit-parallel-call`（`tasks.md:45` 已归档）三份均为已归档变更。按 checklist §13 误报边界（`doc/spec/<已归档变更>/` 按「当时结论是否自洽」核对），本报告只报两类：
> ① **文档集内部/互相矛盾**；
> ② **文档把某状态写成「最终口径 / 已完成 / 已验收」，而代码另有明确说明该口径已变**（这类仍算文档缺陷）。
> 纯历史描述（如 parallel-call `design.md:5` 引用的变更前行号）不计入问题，只在覆盖表说明。

## 发现

### [严重][存量] `any_box`/`any_as` 的 Float64 分支用 `Int64(x.toBits())` 编码，负浮点必然溢出成 `99 HELPER_PANIC`

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:83`（`any_as` 的 `case 1u16 => Int64(f.toBits())`）；同型写法另见 `f_jit/src/runtime/HostCall.cj:91`、`f_jit/src/runtime/HostField.cj:177`、`f_jit/src/runtime/HandleTable.cj:1409`、`f_jit/src/runtime/Helpers.cj:425`
- **来源**：存量（快照模式无基线）
- **判据**：checklist §11「边界 / 空值 / 契约不符」；文档侧 `doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md:66`（可转集含 `0–8`，即 `1 = Float64` 是合法装箱/转型目标）、`doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:39-42`（「装箱往返 THEN 值型逐位相等」）、`doc/spec/f-jit-m3/design.md:20`（「helper 边界不抛异常：失败一律转错误码」）
- **证据**：静态确定
  - `Float64.toBits(): UInt64`（本机 `cangjie-coding` 知识库签名表 `toBits(): UInt64`，文档 `std.core`）；拿最高位为 1 的位模式去做 `Int64(...)` 是**整型转换**，而仓颉默认策略 `@OverflowThrowing` 明确作用于「函数内的整数运算和整型转换」，溢出抛 `ArithmeticException`（本地文档 `language/reflect_and_annotation/1-注解/1-1-整数溢出注解.md`）。全仓 `f_jit/src` 无任何 `@OverflowWrapping` / `@OverflowSaturating`（逐文件 grep 命中 0）。
  - 同仓已有 3 处**符号安全**的等价实现：`f_jit/src/runtime/Interp.cj:451-457`（`fromBits`：`b >= 0x8000…u64` 时 `Int64(b - 2^63) + Int64.Min`）、`f_jit/src/CallMarshal.cj:399`（`bitsOfCell2`）、`f_jit/src/runtime/Interp_test.cj` 的同名测试辅助。两条口径不可能同时正确。
  - helper 外层的 catch-all 会把非契约异常兜成 `ErrCode.HELPER_PANIC(99)`（`f_jit/src/runtime/HelperCore.cj` 的转码模板，见 `design.md:20` 的约定），不会落到 8/22。
- **描述**：任何负 Float64 走 `any_as` 拆箱（`any_box(-1.5)` 后取回、宿主闭包返回负浮点、读负浮点字段、`dec_to_f64` 得到负数）都不是取值失败而是**引擎缺陷码 99**，宿主会看到 `JitException(99)`；`-0.0`、负 NaN 同路径。现有用例只覆盖正值（`HostCallTrampoline_test` 用 `1.25+0.5`、`AnyBridgeCall_test` 用 `0.0`），5 处全部没被负值触发过，所以归档时的「装箱往返值型逐位相等」仍然全绿。
- **建议**：5 处统一改用已有的补码转换（`Interp.fromBits` / `CallMarshal.bitsOfCell2`，或在 `HandleTable` 收一个 `f64Cell`），并在 `AnyHelpers_test` / `HostCallTrampoline_test` 各补 `-1.5`、`-0.0`、负 NaN 三条。复核成本极低：一条 `call<Float64>([-1.5])` 用例即可证实或证伪。
- **移交说明**：本部分只审文档；该缺陷落在 `.cj`，请与负责 `runtime/AnyHelpers.cj`、`runtime/HostCall.cj`、`runtime/HostField.cj` 的分部分报告去重，定稿级别以那边为准。

### [一般][存量] 未注册的父接口被静默跳过：spec 要求「一并登记」、design 承诺「注册期诊断并拒绝」，只有 verify 说了实话

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md:9`、`.../design.md:36`、`.../verify.md:32`；代码 `f_jit/src/ReflectRegistrar.cj:421-432`
- **来源**：存量
- **判据**：checklist §13（文档集内部不自洽）+ §3（静默降级）
- **证据**：静态确定
  - spec `:9`：「注册类或接口时，**父类型的公共成员 SHALL 一并登记**：…接口沿 `superTypes` 链」。
  - design `:16`/`:36`：父接口须先注册，未注册时「注册期诊断并**拒绝**，不做静默降级」。
  - verify `:32`：「父接口必须先注册，否则其方法不会并入（**当前静默跳过**；`verify` 记录为已知边界）」。
  - 代码 `ReflectRegistrar.cj:421-432`：`match (into.resolve(pname)) { case Some(pd) => …; case None => () }`，且 `parents` 仍原样写入描述符（`:438-440`）。
- **描述**：同一变更的三份文档三种口径（必须登记 / 拒绝注册 / 静默跳过）。实现选的是 design 明确排除的那一种，且 `parents` 仍保留 `Named`，于是前端按接口名查方法时才报「类 Greeter 未注册方法 name」——调用方拿不到「父接口没注册」这一诊断。
- **建议**：按 design 的承诺改成注册期抛 `RegistrationException`（`ReflectRegistrar.cj:415-418` 已有「接口必须用 @JitBind」的先例）；若确实要保留宽容语义，则 spec `:9` 必须写明「父接口未注册时其方法缺失」，并把 `parents` 的记载与「已并入」解耦，同时改掉 design `:16`/`:36`。

### [一般][存量] JSON 写入值域在规格里含 Float64，前端与运行期都拒绝：按文档写 `j['k'] = 1.5` 必然编译错误

- **位置**：文档 `f_jit/doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:70`、`f_jit/doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md:88`；实现 `f_jit/src/compiler/Lowerer.cj:1927-1943`、`f_jit/src/runtime/JsonHelpers.cj:136-155`
- **来源**：存量
- **判据**：checklist §13（规格与实现漂移）+ §2（同一张值域表多处枚举）
- **证据**：静态确定
  - 文档两处：「值域 = 值型 0–3（Unit 除外）/ String / JSON 节点（码 16–19）」，「值型 0–3 除 Unit」= `{0, 1, 2}`，含 `F64(1)`。
  - 前端 `checkJsonWriteValue`（`Lowerer.cj:1928-1929`）只收 `I64(0)`/`Bool(2)`/`String(4)`/`16–19`，并对 `F64` 专门给诊断「JSON 无二进制浮点」（`:1931-1932`）。
  - 运行期 `jsonValueOf`（`JsonHelpers.cj:144-155`）只有 `0/2/4/16/17/18/19` 分支，其余 `failWith(HANDLE_TYPE)`；其注释（`:140-142`）自述「旧实现放行 Float64、这里落到 `case _` 报 8，正是 P3-3 的『规格-前端-运行期』三处不一致」。
- **描述**：P3-3 收口只改代码、没回写 spec。值域这张表在 4 处分别枚举（两份 spec + 前端 + 运行期），是漂移的直接成因；按 spec 写浮点写入会编译失败，绕过前端直接调 helper 则得 8。
- **建议**：两份 spec 改为「`Int64`(0)/`Bool`(2)/`String`(4)/JSON 节点(16–19)；`Float64` 与 `Decimal` 不在值域内」；若要把值域变成单一来源，在 `base` 收 `isJsonWritable(code)` 供两端引用。`JsonHelpers.cj:136` 的「0–3（Unit/Float64 除外）」字面也不成立，一并改。

### [一般][存量] 反引号 JSON 字面量的取界机制与文档相反：文档写「JSON 字符串感知 + 括号配平」，实现是「扫到下一个反引号」

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md:47`（另 `:48`「无匹配闭合 SHALL 交解析器报错」）；实现 `f_jit/src/compiler/Lexer.cj:432-452`
- **来源**：存量
- **判据**：checklist §13（规格与实现漂移）
- **证据**：静态确定
  - 文档 `:47`：「取界规则 = JSON 字符串感知 + 括号配平（`{"a":"}"}`、`["]"]`、嵌套 `[{…}]` 均正确取界）」。
  - 实现 `scanJson`（`Lexer.cj:439-452`）：`while (!isEof() && bs[cur] != 0x60) bump()`，纯反引号终结，无字符串状态机、无括号计数；同文件 `:436-437` 注释直接写「取界 = **下一个反引号**」。
  - 未闭合时在**词法层**报 `UNTERMINATED_STRING`（`:445-448`），`JsonLit_test.rejectsUnterminatedJson` 断言的也是词法错误，与 `:48` 的「交解析器报错」不符。
- **描述**：文档列举的三个用例（字符串内含 `}`、`]`、嵌套）在「扫到下一个反引号」下恰好也通过，机制差异被 scenario 掩盖。真实后果只有一条：JSON 字符串里出现**反引号**（U+0060，JSON 合法字符）时字面量提前截断，后续字节按源码语法报错，合法 JSON 无法书写（只能写 `\u0060` 规避）。属「承诺的健壮性未实现」，不是数据损坏。
- **建议**：二选一并同步 scenario：①实现字符串感知 + 配平的取界；②把 `:47` 改成「取界 = 下一个反引号；字符串内的反引号须写 `\u0060`」，`:48` 改为「词法错误」。倾向 ②，成本最低且行为可预期。

### [一般][存量] 「父类型的公共成员一并登记」未记录已知限制：父类方法含引用型参数/返回时被跳过

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md:9`、`.../design.md:15`；实现 `f_jit/src/ReflectRegistrar.cj:589-605`、`:722-731`
- **来源**：存量
- **判据**：checklist §13（承诺面大于交付面）+ §14.1（只处理部分输入）
- **证据**：静态确定 —— 父类方法无 `@JitBind` 时走反射；若 `unsafeForReflect(sig, ret)` 为真（参数/返回落在引用型码，`:722-731`）则 `skip(diag, …, '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13），请给父类加 @JitBind')` 并 `continue`，该成员不进子描述符。
- **描述**：design `:15` 写「方法用『父类 `@JitBind` 登记』**或父类反射 `FunctionInfo`**（具体方法可 apply，子实例可上转）」，读起来二选一皆可；实际反射路只对值型签名成立。spec 的「SHALL 一并登记」因此有例外，而例外只写在代码注释（GAP-13）里。归档 scenario（`c.parentMethod() + c.parentField`）不含引用型参数，用例不暴露。
- **建议**：spec `:9` 与 design `:15` 各补一句「父类方法含引用型参数/返回时必须 `@JitBind`，否则注册期记诊断并跳过」，并列入 verify「语义边界」。

### [轻微][存量] 特化开关的落点与 plan 生命周期：文档写 `CompilePipeline` + per-call，实现是 `SignatureTable.enabled` + 条目级常驻缓存

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-facade-bridge/spec.md:55`（开关落点）、`:108`（`HostCallback.plan` per-call）；实现 `f_jit/src/runtime/SignaturePlan.cj:129-138`、`f_jit/src/runtime/Signature.cj:383-392`
- **来源**：存量
- **判据**：checklist §13（API 位置 / 生命周期与文档不符）
- **证据**：静态确定
  - 文档 `:55`：「桥 SHALL 在 `CompilePipeline` 暴露特化开关（强制通用 / 强制特化），默认开启特化」；`:108`：「`HostCallback` SHALL 增加 `plan` 绑定，生命周期 **per-call**（随条目 try/finally 释放）」。
  - 实现：开关是 `public static var enabled`（`SignaturePlan.cj:134-135`），读点 `getOrBuild`（`:141-144`）；`CompilePipeline` 无任何特化成员（全仓 grep `specializ|forceGeneric|planMode` 命中 0，只命中文档与测试注释）。
  - `plan` 是 `HostCallback` 的 `public let`（`Signature.cj:383`，构造期 `:391` 赋值），并被 `SignatureTable` 以不可变快照**跨调用长期持有**（`SignaturePlan.cj:129-138`，`MAX_ENTRIES = 128`），没有 per-call 释放。
- **描述**：能力齐备且默认开启，「双路径对拍」用例也成立，但落点与生命周期与文档相反：按文档去 `CompilePipeline` 找开关会扑空；按「per-call 释放」推断内存模型会高估释放频率（实际 128 条常驻）。`plan` 身份无关，常驻不构成泄漏。
- **建议**：文档改为「开关位于 `SignatureTable.enabled`（运行期）；plan 归属条目并由 `SignatureTable` 快照常驻，上限 128」，或在 `CompilePipeline` 加一层转发属性以兑现原措辞。

### [轻微][存量] 并行调用变更的「完成态」描述与实现不符：`state/active` 未原子化、`lastEscaped` 仍是单元级字段

- **位置**：`f_jit/doc/spec/feat-f-jit-parallel-call/proposal.md:14`、`:15`、`design.md:60`（D6）、`tasks.md:37`（P5.1）；实现 `f_jit/src/JitFunction.cj:86-87`、`:109`、`:198-212`、`:539-545`
- **来源**：存量
- **判据**：checklist §13（设计决策 / 任务清单 / 实现三方不一致）
- **证据**：静态确定
  - `proposal.md:14`「`lastEscaped`（改为 `callForFn` 的返回值，**不再是单元级字段**）」；字段仍在（`JitFunction.cj:109`），仍由 `synchronized(this.mtx)` 写入（`:668-670`），并由 `internal func lastEscapedClosure()`（`:539-545`）读出，供单线程手工包装/诊断。
  - `proposal.md:15` 与 `design.md:60` D6 都写「`state`/`active` 改原子」；实现仍是普通 `private var Int64`（`:86-87`），读写全在 `mtx` 内（`:198-212`、`:336-349`）。
  - `tasks.md:37` P5.1 勾 `[x]` 但正文写「原子化**留待 P6 视瓶颈**」，P6（`:40-45`）没有任何原子化条目。
- **描述**：三处口径互相打架：proposal/design 写成已定决策，tasks 承认延后，代码保持 `mtx`。当前实现是安全的（同锁内访问），所以这是记录不一致而非并发缺陷；风险在于后人按 D6 认定「已无锁」而在锁外读 `active`。
- **建议**：design D6 / proposal 补「实施口径：保留单元 `mtx`，未原子化（P5.1 裁定）」；或把原子化补回 P6 任务。`lastEscaped` 的「仅单线程手工包装」限定目前只写在 `JitFunction.cj:536-538`，应上移到 proposal。

### [轻微][存量] 接口变更 design 自相矛盾：父类字段「追加到尾部」对「子类字段排在继承字段之后 / 先占号」

- **位置**：`f_jit/doc/spec/feat-f-jit-interface-and-inheritance/design.md:15`（D2）对 `:34`（风险表）、`verify.md:21`/`:27`；实现 `f_jit/src/ReflectRegistrar.cj:140`、`:526`
- **来源**：存量
- **判据**：checklist §13（同一文档内结论相反）
- **证据**：静态确定
  - `:15`：「字段**追加到子描述符尾部并重新编号**」。
  - `:34`：「仅在**子类**描述符内追加，父类描述符编号不变；**子类新增字段排在继承字段之后**」。
  - verify `:21`/`:27`：「`mergeAncestorFields`（**自有字段之前**，先占号）…自有字段从 k 开始编号」，并记录了顺序写错导致的 `32≠33` 缺陷。
  - 代码与后者一致：`mergeAncestorFields` 先于自有字段被调用（`:140`），编号为 `fields.size` 递增（`:526`）。
- **描述**：D2 的「追加到尾部」是笔误级错误，但它描述的正是本变更踩过的坑（字段全局 index 空间 + `accepts` 区分），按 D2 实现会直接复现 32≠33。
- **建议**：`:15` 改为「父类字段先登记（先占号 0..k-1），自有字段从 k 起编号；父类描述符自身编号不变」，并删掉与 `:34` 的重复表述。

### [轻微][存量] JSON 读出口的 requirement 文本与自身 scenario / 实现不符（`JsonDecimal → Decimal`）

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md:68`（requirement）对 `:74-77`（scenario）；实现 `f_jit/src/runtime/JsonHelpers.cj:116-128`
- **来源**：存量
- **判据**：checklist §13（同文件内 requirement 与 scenario 相反）
- **证据**：静态确定
  - `:68` 写「`JsonInt` 落 Int64 域内 → Int64 / 超域 → Decimal、`JsonDecimal` → Decimal」。
  - `:76-77` 的 scenario 却要求 `{"i":3}` 读出 **Int64 盒**、超大整数读出 Decimal 盒。
  - 实现 `JsonHelpers.cj:116-128`：`JsonDecimal` 若 `isInteger()` 且在 Int64 域内则返回 `Int64`，否则 `Decimal`；注释 `:117-119` 说明 `f_data` 把所有 JSON 数字都解析成 `JsonDecimal`，`JsonInt` 分支实际走不到。
- **描述**：实际规则是「整数且在 Int64 域内 → Int64，否则 Decimal」，与 scenario 一致、与 requirement 文本相反。按文本实现会把 `{"i":3}` 读成 Decimal，源级 `as Int64` 立刻 22（代码注释记载过这个坑）。
- **建议**：requirement 改为「数字节点：整数值且在 Int64 域内 → Int64，否则 Decimal（不区分载体内 `JsonInt`/`JsonDecimal`）」。

### [轻微][存量] `tasks.md` 的验收引用指向不存在的 `verify.md`，3 条 partial 既非 full 也未标 GAP

- **位置**：`f_jit/doc/spec/f-jit-m3/tasks.md:14`；对照 `.../specs/f-jit-differential-acceptance/spec.md:26-29`
- **来源**：存量
- **判据**：checklist §1（无下文的引用）/ §13（路径失效）/ §14.1
- **证据**：静态确定 —— `doc/spec/f-jit-m3/` 只有 `design.md` / `proposal.md` / `scenario-map.tsv` / `tasks.md` / `specs/`；同族 `f-jit-m1`、`f-jit-m2`、`f-jit-m2.1` 均有 `verify.md`。`scenario-map.tsv` 80 行、`GAP` 计数 0，但有 3 条 `strength=partial`（「宿主值不可常量化」「一次解析」「冷路径回退」）。
- **描述**：`proposal.md:22` 用「（若存在）」对冲，`tasks.md:14` 无条件引用，归档后成为断链。差分规格要求「未覆盖的 scenario 显式标 GAP，不得静默」，而缺口说明的唯一指定落点就是那个不存在的 `verify.md`，3 条 partial 因此悬空。
- **建议**：补 `verify.md`（全量计数、三引擎结论、GAP 清单），或把 `tasks.md:14` 与 `spec.md:28` 改为只引用 `scenario-map.tsv` 并给 3 条 partial 标 GAP。

### [轻微][存量] 「桥的错误码映射静态表 / 22 行独立存在」在实现中没有对应结构

- **位置**：`f_jit/doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md:57-60`；实现 `f_jit/src/JitReport.cj:38-55`
- **来源**：存量
- **判据**：checklist §13（文档描述的结构不存在，scenario 不可执行）
- **证据**：静态确定 —— `throwJit` 只对 `-2`（`InterruptedException`）与 `21`（附 `HostFault` cause）特判，其余一律 `throw JitException(code, site, fnId, None, report)` 原码透传；不存在逐码行表，22 也没有「独立一行」。`scenario-map.tsv` 把该 scenario 映射到 `fullPositiveCodeRangeMapsToJitException`（`JitReport_test.cj:125-150`），它是**循环验码**，不是遍历静态表。
- **描述**：要求写的是实现结构，而实现选了更简的通用透传；真正有价值的约束（22 不折叠成 7/21）只是靠两条独立代码路径成立，文档却声称存在可审计的映射表。
- **建议**：requirement 改为「桥 SHALL 按原码透传 1–23/99，仅 -2 转 `InterruptedException`、21 附原始异常；SHALL NOT 把 22 折叠为 7/21」，删掉「静态表 / 22 行」的说法。

## 优化可行性方案

本部分 20 个文件全部是 `.md`，不含可执行代码，**无堆内存 / CPU 优化方案（0 / 0）**。文档维护类改进已并入各条「建议」，不单列。

> 本轮未构建、未跑 profile / bench，不存在可引用的性能基线；任何「重构能降 X%」的推断都只会是猜测，按铁律不写入本节。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「严重」条的实际落地：负 Float64 拆箱返回 99（而非值或 22） | `f_jit/src/runtime/AnyHelpers.cj:83` 等 5 处 | 运行期异常路径是否真被 catch-all 兜成 99 | `@Assert(f.call<Float64>([-1.5]), -1.5)` 与 `any_as(any_box(-0.0))` 各一条，`cjpm test` 跑一次即定论 |
| 2 | `hasField`/`hasMethod` 线性去重在大成员类注册期占比可观 | `f_jit/src/ReflectRegistrar.cj:456-473` | 自耗时占比、成员数分布 | 注册含 200+ 成员的类 × 1000 次，`cjprof record -O2` 看两函数 self time |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/f-jit-m3/design.md` | .md | ✅ | 决策与不变量；依赖 DAG 成立（`runtime` 无 `import fountain::f_jit` 根包）、helper 不抛异常约定见 #1 |
| 2 | `doc/spec/f-jit-m3/proposal.md` | .md | ✅ | 反写说明自洽；`verify.md` 用「若存在」措辞，无问题 |
| 3 | `doc/spec/f-jit-m3/specs/f-jit-base-contracts/spec.md` | .md | ✅ | `LocalType` 0–19 / `isLegal` 版本分派 / `isHandle` / 可转集单点（`isConvertible`）/ `TypeToken` 12 项逐项核对一致；错误码表见 #11 |
| 4 | `doc/spec/f-jit-m3/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | kind 11 / `addJson` 空串与 16 MiB 拒绝 / 加载期一次实例化（`instanceAt` 缓存）/ frozen 均成立；跨平台字节一致成立——`Lexer.normalizeNewlines`（`:123-140`）在构造时整串归一（`:56-59`），本报告不将其列为缺陷 |
| 5 | `doc/spec/f-jit-m3/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 体首字符定类型、空形态 `json_new`、注释不剥离、二次装箱拒绝均一致；取界见 #4、写入值域见 #3 |
| 6 | `doc/spec/f-jit-m3/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | T37–T41/T56/T61 在 `src/**` 有 72 处标签命中；GAP 口径见 #10 |
| 7 | `doc/spec/f-jit-m3/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 封送/解包表与 `CallMarshal.cj:106-123`、`:210-229` 一致；开关与 plan 见 #6 |
| 8 | `doc/spec/f-jit-m3/specs/f-jit-runtime/spec.md` | .md | ✅ | H78–H83 的分配/纯读/变更型纪律、frozen 传播、`argc≤4` 展开（`SignaturePlan.cj:79-104`）均成立；出口解包见 #9、Float64 见 #1、写入值域见 #3 |
| 9 | `doc/spec/f-jit-m3/tasks.md` | .md | ✅ | 6 项全勾选；`verify.md` 断链见 #10 |
| 10 | `doc/spec/feat-f-jit-interface-and-inheritance/design.md` | .md | ✅ | D1/D3/D4/D5 与实现一致；D2 字段顺序见 #8、父方法反射限制见 #5 |
| 11 | `doc/spec/feat-f-jit-interface-and-inheritance/proposal.md` | .md | ✅ | 四道门槛与 `f_macros/src/CompositeDecl.cj:77` 的 `extend InterfaceDecl` 均核对成立 |
| 12 | `doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 父成员解析、覆盖优先与 `mergeAncestorMethods`「先子后父 + 同名跳过」一致 |
| 13 | `doc/spec/feat-f-jit-interface-and-inheritance/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | `registerInterface` 无 Object 约束、无字段/构造器、未绑定接口拒绝均成立；父成员见 #2/#5 |
| 14 | `doc/spec/feat-f-jit-interface-and-inheritance/tasks.md` | .md | ✅ | G1–G4 逐条可在代码对上（`parents` 透传、`enrollInterfaceOf`、`isInstanceOfHost`、`mapType`） |
| 15 | `doc/spec/feat-f-jit-interface-and-inheritance/verify.md` | .md | ✅ | 用例数核对：`Interface_test` 4 / `Inheritance_test` 2，与 `:9` 一致；`:32` 与 design `:36` 相反（#2） |
| 16 | `doc/spec/feat-f-jit-parallel-call/design.md` | .md | ✅ | 变更前行号（`HandleTable.cj:88-141` 等）属历史语境，不计问题；`:109-119` 实施状态逐条核对成立（分块存储、读路径去锁、`IterTable` 线程私有、`envMtx`/`callMtx` 已删、`NativeMem` 原子） |
| 17 | `doc/spec/feat-f-jit-parallel-call/proposal.md` | .md | ✅ | 串行根因与目标场景成立；`:14`/`:15` 见 #7 |
| 18 | `doc/spec/feat-f-jit-parallel-call/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 并发调用/跨线程包装/并发卸载与 `JitFunction.close`（`:227-260`）语义一致（`19` 拒新调用、等 `active==0`、超时回退） |
| 19 | `doc/spec/feat-f-jit-parallel-call/specs/f-jit-runtime/spec.md` | .md | ✅ | 窗口切片/倍增/槽级提升/try-finally 豁免与 `openWindowWith`/`resetWindow` 一致 |
| 20 | `doc/spec/feat-f-jit-parallel-call/tasks.md` | .md | ✅ | P0–P6 全勾选；用例数核对：`ParallelCall_test` 6、`WindowIsolation_test` 3、`ThreadLocalEnv_test` 3，与 design `:116-117` 一致；P6.2 吞吐数据属已有基线 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1（F64 位模式）、#3（写入值域）、#4（取界机制）；设计 #2/#5（父成员登记口径）。语言特性（值/引用语义、`protected` module 级可见性）文档描述与实现一致；安全性面无外部输入、无凭据陈述 |
| §1 死代码 | 1 | 文档层机械核对「引用是否有下文」：`design.md` 引用的 `design-m3.md`/`jit-bytecode-m3.md`/`plan-m3.md`、interface proposal 的 6 个影响文件、`f_macros` 的 `InterfaceDecl` 扩展全部存在；唯一断链是 `tasks.md:14 → verify.md`（#10）。本部分无 `.cj`，不涉符号级死代码 |
| §2 重复逻辑 | 1 | 文档层同义枚举逐一比对：①JSON 写入值域名 4 处（两份 spec + 前端 + 运行期）已漂移（#3）；②`LocalType↔TypeToken` 映射单点（`fromToken`），`TypeToken.cj` 不反向维护，成立；③换行归一单点（`Lexer.normalizeNewlines`，5 处调用同一实现），成立；④`scenario-map.tsv` 的 scenario 名与各 spec 标题逐条一致，无第二份表 |
| §3 空实现 | 1 | 父接口 `case None => ()` 静默跳过（#2）；文档内无 TODO/FIXME 占位 |
| §4 栈溢出 | 0 | 文档未描述递归接口；`mergeAncestor*` 的 32 层封顶属代码侧，不展开 |
| §5 OOM | 0 | 唯一量化上限是 `addJson` 的 16 MiB/条 与 `SignatureTable.MAX_ENTRIES=128`，均与文档一致，无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 未构建、无 profile，热点结论不成立；只保留 1 条待验证假设（#2） |
| §6.2 大粒度锁 | 0 | 本部分无代码；文档中「单表 + 单 Mutex」属变更前语境，不判 |
| §6.3 并发串行 | 0 | 同 §6.2；并行化结论由 `ParallelThroughput_test` 承载，本轮未复核数据 |
| §6.4 低效算法 | 0 | 文档无算法描述；`hasField` 线性去重列待验证假设，不作为发现 |
| §7 降堆内存方案 | 0 | 无代码、无基线，按铁律不出方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；被引用的解析/注册产物全部逃逸进常量表与描述符，`@local` 不成立 |
| §11 现有代码的 BUG（存量） | 1 | 仅 #1（为核对「装箱往返」契约而读到的实现缺陷，已标注移交）；其余代码面缺陷归各 `.cj` 分部分 |
| §12 并发安全与锁粒度 | 1 | `state/active` 的同步手段与文档「原子」口径不符（#7，当前实现安全、记录不一致）；未发现文档承诺线程安全而实现无同步的条目 |
| §14 功能完备性与 README 覆盖 | 2 | #3（规格承诺的写入值域未实现）、#10（M3 验收证据缺失）；本部分不含 README，public API 覆盖检查在 `.cj` 部分 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无缺项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 份规格文档的整体质量高于一般归档文档：决策都写了「为什么」，不变量（包依赖 DAG、执行路径零反射、helper 边界不抛异常、窗口/句柄记账）可直接对读代码；`LocalType` 0–19 与版本分派、可转集单一来源、`TypeToken` 12 项、`kind 11` 拼装期不解析与加载期一次实例化、`frozen` 经读/拆箱传播、接口 `@JitBind` 强绑定与 14 判定=类祖先∪接口谓词、窗口切片与读路径去锁，全部核对成立；`scenario-map.tsv` 与 spec 场景逐条对齐，用例数（Interface 4 / Inheritance 2 / ParallelCall 6 / WindowIsolation 3 / ThreadLocalEnv 3）经清点属实，未发现编造或空承诺。

风险集中在「文档比实现宽」这一个方向，且都发生在 P3-3 一类**收口只改代码不回写 spec** 的场合：

- JSON 写入值域（#3）：文档放行 Float64，前后端两侧都拒绝，代码注释自己承认「规格-前端-运行期三处不一致」——本部分最值得排期的一条。
- 反引号取界（#4）：文档描述的「字符串感知 + 括号配平」不存在，字符串内反引号无法书写；列出的三个 scenario 恰好都能通过，掩盖了差异。
- 未注册父接口（#2）：三份文档三种说法，实现选了 design 明确排除的「静默降级」。
- 父类方法反射限制（#5）：spec 的「一并登记」有一个只写在代码注释里的 GAP-13 例外。

唯一按严重记的是 #1（Float64 位模式），它把「合法输入」变成引擎缺陷码 99，且同仓已有 3 处符号安全的等价实现——两条口径不可能同时正确。该缺陷落在 `.cj`，已注明与相应分部分去重，定级以代码部分为准；复核成本是一条 `call<Float64>([-1.5])` 用例。

其余 6 条是记录一致性问题（开关落点/plan 生命周期、`state/active` 与 `lastEscaped`、字段编号顺序、`JsonDecimal` 出口、`verify.md` 断链与 partial 未标 GAP、错误码映射表），单条都不阻塞，但建议与上面几条一起做一次 **spec 回写**，否则下一轮会重复命中同一批偏差。

阻塞项：本部分文件为文档，无阻塞项；#1 虽按严重记，其性质是代码缺陷，需由对应 `.cj` 分部分复核后定稿。存量合计 11 条（严重 1 / 一般 4 / 轻微 6），是否纳入修复待用户决定。
