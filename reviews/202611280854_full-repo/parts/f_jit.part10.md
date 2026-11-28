# f_jit 模块审查报告（模块第 10/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个文件：0 个 `.cj` / 20 个 `.md`，全部位于 `doc/spec/f-jit-m2*`）
- **基线**：工作区快照（无 diff 基线；`_dispatch.md` 记基线提交 `120fd2542`，当前工作区 HEAD 为 `f309f0b55`，差异仅影响标注；本部分结论全部记为「存量」）
- **审查重点**：f_jit 专项（typecode 分支表、句柄/资源生命周期、并发、递归、死代码、重复逻辑）在本部分表现为「归档规格 ↔ 实现 / ↔ 同变更其它文档」的一致性：文档声明的符号与失败码/编号/API 名是否真实存在、验收证据是否可复核
- **报告版本**：v1（模块第 10/38 部分；只统计本部分，模块级结论由主 Agent 合并）

> 本部分不含源码。归档目录按 checklist §13 误报边界只要求「当时结论自洽」，因此**跨里程碑的正常演进不判**；只报「同一归档内自相矛盾」「归档结论与当日实现相反」「验收证据不可复核」三类。每条都给出文档行号与代码行号两侧证据；凡是能跑的只读校验（`check_scenarios.sh`、`grep`）都实际跑了。

## 发现

### [一般][存量] m2 设计把验签写成「单次 `is (T1..Tn) -> R`」，与同变更 runtime spec、权威规格、实现全部相反

- **位置**：`f_jit/doc/spec/f-jit-m2/design.md:62-66`（D3）、`:238`（Risks 行「验签依赖 P1」）、`:9`（「`jit-bytecode-m2.md` **v0.8.32**」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— 同变更 `f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:122` 已改为 `SignatureVerifier.verifyReflective`（`std.reflect.FunctionTypeInfo.of` 取真实签名逐位比对、14 按具体类名），并明写「原 `verify`（分步核对、仅 0–2 元）SHALL NOT 作为验签主路」；权威规格 `f_jit/doc/jit-bytecode-m2.md:3` 的 v0.8.33 条目写「原『单次 `is (T1..Tn) -> R`』语言上不可实现（T/R 是运行期数据、`is` 右侧须静态类型，物化路径 11^(n+1) 分支）」；实现 `f_jit/src/runtime/Signature.cj:111`（`verifyReflective`）、`f_jit/src/runtime/ReflectiveCall.cj:29`（`FunctionTypeInfo.apply`）；本变更 `verify.md:218` 亦记「规格 §4 的『单次 `is`』语言上根本不成立……改用 `std.reflect.FunctionTypeInfo`」
- **描述**：D3 是「怎么做」的权威锚点（`design.md:6` 自述），却保留了被 GAP-04/GAP-05 否决的方案，并把「P1 已实测」列为已缓解风险；读者照 D3 实现会回到 11^(n+1) 分支表或 0–2 元上限——正是验收里被判阻塞的两条。`:9` 的权威版本指针也已落后（现 `jit-bytecode-m2.md` 为 v0.8.34）
- **建议**：D3 改为「验签 = `FunctionTypeInfo.of` 取形参类型名序列 + 返回类型名逐位比对（元数不限、14 位置按具体类名逐字相等）；调用 = `apply(fn, args)`」，把「单次 `is`」标为已否决方案并给否决理由；Risks 行改为「反射签名取用与参数打包的固定开销（见 `doc/perf-m2.md`）」；`:9` 改 `v0.8.33` 起并注明后续增补

### [一般][存量] 两份 spec delta 的签名类型定义没有类名载体，与同一 spec 的「14 按具体类名判定」不可兼容

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:113`（`SignatureDescriptor(params: Array<UInt16>, ret: UInt16, validate())`）；`f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md:127-129`（`HostClosureT(Array<UInt16>, UInt16)`）
- **来源**：存量
- **判据**：review-checklist §13「文档与实现不符 / 文档内部矛盾」
- **证据**：静态确定 —— 同 spec `specs/f-jit-runtime/spec.md:127` 的场景要求「14 位置的具体类名不符 → None」，仅凭类型码无法比对类名；同 spec `specs/f-jit-compiler-frontend/spec.md:129` 自己解释「`(User) -> R` 与 `(Order) -> R` 的码完全相同（都是 `[14] -> R`）」。实现已是四元：`f_jit/src/compiler/Ast.cj:80-84`（`HostClosureT(Array<UInt16>, Array<String>, UInt16, String)`）、`f_jit/src/base/HostSignature.cj:44-63`（`paramNames` / `retName` / `display` / `adapter`）、`sameShape` 逐位比对（`:74-86`）
- **描述**：这是 GAP-04 的文本根因（`verify.md:200-208` 原文即「`SignatureDescriptor` 只有 `params`，无类名」）。结案时只补了代码与 `verify.md`，delta 的结构声明没回写，后来者读 spec 会得出「14 只能比大类」的相反结论
- **建议**：`runtime` spec 补 `paramNames: Array<String>` / `retName: String`（空串 = 只比大类），`compiler` spec 的 `HostClosureT` 改四元并写明参数序；两处都注明「14 位置按类名逐字比对」

### [一般][存量] m2.2 的 `as` 语法面与转型面与自家验收矩阵、后继里程碑相反

- **位置**：`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-compiler-frontend/spec.md:8`（requirement：下转型/无法静态判定「SHALL 编译期拒绝」；「裸 `as`（缺 `??`）与裸 `??` SHALL 以语法错误拒绝」）、`:15-18`、`:25-28`、`:35-38`（Scenario 语法拒绝面）
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§2「同一规则在两处给出相反结论」
- **证据**：静态确定 —— ① 裸 `as`：`f_jit/src/compiler/CastOrParse_test.cj:64-67` 的 `bareAsIsRecognized` 断言 `x as Int64` 解析为 `castor(var(x) as Int64)`（**合法**），同变更 `scenario-map.tsv:15` 把「语法拒绝面」映射到 `bareAsIsRecognized,...` 且强度 `full`，`f-jit-m2.3/specs/f-jit-compiler-frontend/spec.md:49-50` 明写裸 `as` 合法；② 下转型/类名未跟踪：同变更 `scenario-map.tsv:9-10`、`:12-13` 已标「本条已作废（M2.3 改为运行期判定）」，spec 正文仍是无条件 SHALL 编译期拒绝
- **描述**：同一份归档里 spec、验收矩阵、后继 delta 三方对 `as` 的语法面与转型面各说一套；矩阵还把「合法 + 非法」两种输入塞进同一条「均以语法错误拒绝」的场景并给 `full`，该强度因此不成立。按 spec 实现会拒掉今天合法的 `x as Int64`
- **建议**：requirement 改为「裸 `as` 合法（失败报 7 `BAD_CAST`）；裸 `??` 与 `?` 为语法错误」，转型判定改为「编译期优先、判不了落 `$as$<C>` 运行期」；两条已作废场景加「（M2.3 起…）」注记

### [一般][存量] m2.2 / m2.3 的验收声明不可复核：`verify.md` 不存在，m2.2 矩阵条目数写错且 1 条用例名已改名

- **位置**：`f_jit/doc/spec/f-jit-m2.2/tasks.md:13`、`f_jit/doc/spec/f-jit-m2.3/tasks.md:13`（「全量测试通过（见 `verify.md` / `scenario-map.tsv`）」）；`f_jit/doc/spec/f-jit-m2.2/scenario-map.tsv:2`（「21 条 scenario」）、`:19`（`closeIsIdempotentAndReleasesGroup`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」、§3「承诺无实体（验收声明没有可核对证据）」
- **证据**：静态确定 + 已执行只读校验 —— 两个目录都只有 `design.md` / `proposal.md` / `tasks.md` / `scenario-map.tsv` / `specs/`，无 `verify.md`。`bash f_jit/scripts/check_scenarios.sh m2.2` 实测输出：`MISSING test: f-jit-facade-bridge / close 协议 -> closeIsIdempotentAndReleasesGroup`，末行 `20 条映射（full 17 / partial 1 / 缺口 0 / N/A 2），未映射 0，缺失 1`——即表头自写 21 条、实际 20 条；该用例现名 `wrapperUnloadIsIdempotentAndReleasesGroup`（`f_jit/src/JitFunctionClosure_test.cj:101`）
- **描述**：归档 tasks 用「全量测试通过」作完成判据，但证据文件不存在；m2.2 矩阵本身解析不过，说明归档时没重跑脚本，而 `check_scenarios.sh` 正是本变更声明的验收手段
- **建议**：两个 tasks 改成「见 `scenario-map.tsv`（`check_scenarios.sh m2.2|m2.3`）」；表头改 20；`:19` 改用例现名；若要保留 `verify.md` 口径，补一份含总数/失败数/平台的最小 verify

### [一般][存量] 两份 tasks 的归档反写不可复核：m2.2 粘的是 M2 任务清单，m2.3 溯源到不含 M2.3 内容的 `plan-m2.md`

- **位置**：`f_jit/doc/spec/f-jit-m2.2/tasks.md:3-9`；`f_jit/doc/spec/f-jit-m2.3/tasks.md:3`、`:5-9`
- **来源**：存量
- **判据**：review-checklist §14「承诺源与缺失证据」、§13「文档自相矛盾」
- **证据**：静态确定 —— m2.2 的五条任务是「`SignatureDescriptor` 与验签 / `CALL_HOST` 发射与 H63 / 特化 trampoline / 捕获分析 `CaptureDescriptor` / 提升组计数与 `close`」，而 `SignatureDescriptor`、`CaptureDescriptor`、`trampoline` 在 m2.2 三份 spec 里 **grep 0 命中**（`H63` 与「提升组」只作为被复制条款的定语出现，不是本变更的 requirement 主题）；反而本变更真正的改动（`ClassDescriptor.parents`、`PublicMethod.bind.retName`、`as T ?? F` 静态收窄、`JitHost.registerSignature` 类型化 adapter）无一条任务。m2.3 五条（`castRelation` 三态、`$as$<C>` 合成、H77、`SignaturePlan`/adapter、`as T ?? V` 求值时机）在 `f_jit/doc/plan-m2.md` 中不存在：该文件只有 `### Q0`–`### Q6`（:35–:112），全篇 grep `castRelation|$as$|H77|SignaturePlan|JitSignatures` **0 命中**
- **描述**：m2.2 的任务表等于宣称「本变更做的是宿主闭包通道与提升组」，与 proposal/design/spec（父链 + `as` 静态收窄 + 类型化 adapter）冲突；m2.3 的溯源链断裂，「全部已完成」对不到任何步骤表。两份 tasks 都失去审计价值
- **建议**：m2.2 按 5 条 requirement 重写任务（父子链与 `retName`、`as` 三态判定、adapter 登记与查找时机、回归口径）；m2.3 溯源改为 `design-m2.md §12.4/§16` + `jit-bytecode-m2.md` v0.8.34（或补 `plan-m2.3.md`）

### [一般][存量] `CALL_HOST` 降低语序：requirement 写「实参 → `LOADL fn`」，同文件 scenario 与实现是「`LOADL fn` → 实参」

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md:59`
- **来源**：存量
- **判据**：review-checklist §13「文档自相矛盾」、§11「与规格冲突」
- **证据**：静态确定 —— 同文件 `:63-64` scenario 写「产物依次为 `a1`、`a2` 的求值指令、`LOADL fn`、`CALL_HOST 2`、`CHECK_ERR`」；实现 `f_jit/src/compiler/Lowerer.cj:2904` 注释「先求句柄存临时槽 → `LOADL`（栈底）→ 实参左→右 → `CALL_HOST`」、`:2946` 同口径；本变更 `verify.md:303-305` 已判「偏差 A（可接受偏离）」并明确建议「archive 前把 frontend delta 的语序改为『`LOADL fn` → 实参左→右』，纯文档修订」——该修订未执行
- **描述**：`[h_fn, a1..an]` 要求句柄在栈底（最先压栈），与 requirement 的「实参左→右入栈 → LOADL」互斥。规格是验收口径，保留矛盾会让正确实现被判违规，或反向改成错的发射顺序
- **建议**：requirement 改为「`LOADL fn`（句柄压栈底）→ 实参左→右 → `CALL_HOST u8 argc` → 自动 `CHECK_ERR`」

### [一般][存量] m2.3 设计不变量「执行路径零反射」与 `$as$` / 字段访问器的实现、以及本变更自己的 spec 相反

- **位置**：`f_jit/doc/spec/f-jit-m2.3/design.md:19`（不变量第 2 条）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」、§12.1（执行期类型判定的实际手段）
- **证据**：静态确定 —— 同变更 `specs/f-jit-compiler-frontend/spec.md:15` 自己写「`$as$<类名>`……**按反射父链判定**，子类实例算命中」；实现 `f_jit/src/ReflectRegistrar.cj:384-390` 合成的 `$as$` 闭包体调用 `isInstanceOfClass`，后者 `:972-987` 用 `ClassTypeInfo.of(o)` + `superClass` 逐级走查；字段/属性访问器的 `accepts`（`:181`、`:544`）也落到同一函数（`:1001`）
- **描述**：「所有判定在注册期绑定」讲的是**绑定时机**，但绑定出来的函数体在执行期仍调用 `std.reflect`。于是每次 `as`、每次 H64/H65 字段匹配都要付一次反射取用 + 父链走查（上限 64 层）。「零反射」会让后续性能审计与 local mode 评估拿到相反前提
- **建议**：改为「执行路径**无动态成员解析**（注册表查找 / bind / 访问器选择都在注册期完成）；类型判定仍用 `std.reflect.ClassTypeInfo` 的父链走查」，并在 spec 里给出父链长度上界

### [轻微][存量] `HostCallback.sig` 文档类型非可选，实现是 `?SignatureDescriptor`，与同 spec 的「未验签返回 None」不自洽

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md:113`；`f_jit/doc/spec/f-jit-m2/design.md:70`（D4 tag 10：`HostCallback{fn: Any, sig: SignatureDescriptor}`）
- **来源**：存量
- **判据**：review-checklist §13「类型与实现不符 + 文档内部矛盾」
- **证据**：静态确定 —— 实现 `f_jit/src/runtime/Signature.cj:351-355` 为 `public let sig: ?SignatureDescriptor`（注释「`None` = 尚未验签」）；同 spec `:122`、`:132` 要求「未验签时 `cached` 返回 None」——非可选字段无法表达该状态
- **描述**：三处（spec 定义、design D4、spec 缓存语义）对同一字段给出两种类型
- **建议**：文档类型改 `?SignatureDescriptor`，补「pin 时未验签为 None，验签后写入」

### [轻微][存量] 公开 API 名写作 `callFor`，实现是 `callForFn`

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md:64`、`:78`、`:112`；`design.md:124`（D13）、`:238`；`proposal.md:16`、`:32`、`:38`；`tasks.md:71`
- **来源**：存量
- **判据**：review-checklist §13「API 名与源码不符」
- **证据**：静态确定 —— 仓内只有 `public func callForFn<Fn>(args: Array<Any>): JitFunction`（`f_jit/src/JitFunction.cj:491`），全仓搜不到 `callFor<`；同变更 `scenario-map.tsv:101` 已用 `callForFnReturnsWrapperAndRejectsWrapperArg`，`f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:8`、`:22` 亦已是 `callForFn`（更名见 `jit-bytecode-m2.md:3` v0.8.28）
- **描述**：按 m2 规格写的调用无法编译。根因是 m2.2 把「统一调用包装」整段复制（逐行 diff 后唯一差异就是 `callFor`→`callForFn`），改名只改了复制件；两份镜像从此各说一套
- **建议**：m2 的 7 处统一为 `callForFn`；m2.2 删除这条未改动的复制件（引用主 spec 的 requirement 名），镜像只留本变更真正改动的条文

### [轻微][存量] `close` 协议文本已被后续实现推翻，归档 spec 无取代标注

- **位置**：`f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md:64`、`:81-84`；`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:8`、`:27-28`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」、§2（同一段 requirement 在两份 spec 中逐字复制，实现变更后两份同时失真）
- **证据**：静态确定 —— 两份 spec 都写「非闭包包装实例 `close` → 19（site=-1）、`isClosed` 恒 false」；实现 `f_jit/src/JitFunction.cj:227-236` 对入口实例执行的是**单元卸载**并返回 `Bool`，`:471-484` 的 `isClosed()` 对入口实例返回 `state == 2`，`:523-525` 的 `close(): Unit` 即 `close(0)`；用例 `f_jit/src/JitFunctionClosure_test.cj:138-143`（`entryCloseIsUnitLevel`）断言入口实例 `close(0)` 后 `isClosed()` 为真
- **描述**：按文档写用例必然失败；此类契约变更只存在于提交与测试注释里，`doc/spec/` 下没有任何 delta 记录
- **建议**：在两处 requirement 上加「已由 `JitFunction` 资源/close 对齐变更取代」，并在最近一个 milestone 的 delta 里登记新契约（入口实例 `close` = 单元卸载、返回 `Bool`、`isClosed` 随单元状态）

### [轻微][存量] `verify.md` 的总结论行未随结案更新，且 826 与 849 两套基线未标关系

- **位置**：`f_jit/doc/spec/f-jit-m2/verify.md:46`（对照 `:17`、`:376`）；`:366`（826/826）对照 `:43`（当前基线 849/849/0）
- **来源**：存量
- **判据**：review-checklist §13「同一文档结论相反 / 数据口径不明」
- **证据**：静态确定 —— `:17` 写「9/9 全部解决，可进入 archive」，`:46` 写「**总结论：需先补 9 项，暂不可进入 archive。**」，`:376` 写「**可以进入 archive。**」；`本轮执行的校验` 表记 826/826，而「当前基线」记 849/849/0，表格未标注已被取代
- **描述**：这是 archive 门禁的唯一证据文件，结论段自相矛盾会让下游（CI/归档脚本/下一轮审查）无法判断是否放行；两套数字并列也分不清哪次是终态
- **建议**：`:46` 改为「（历史结论，已由上方结案表推翻）」或直接删除；`本轮执行的校验` 加注「首轮 826；结案后 849」

### [轻微][存量] `@JitSignatures` 承诺可标注「任一 `func`」，宏生成名不含所属类型

- **位置**：`f_jit/doc/spec/f-jit-m2.3/specs/f-jit-facade-bridge/spec.md:9`
- **来源**：存量
- **判据**：review-checklist §14「承诺了但实现受限」、§13
- **证据**：待确认 —— 静态可读出生成名相同：`f_jit/src/macros/JitSignature.cj:62-70` 以 `'__jitSigRegister_' + funcNameOf(input)` 生成顶层 `public func` 与 `private let __jitSigApply_<同名>`；`funcNameOf`（`:110-115`）只取被标注声明的函数名、不带类型。故同包内两个同名方法各标注一次即产生两个同名**零参**顶层声明。未编译验证「仓颉对同名零参顶层函数是否报重定义」，故不定为缺陷严重度；现有用例只标注顶层函数（`f_jit/src/JitSignature_test.cj`）
- **描述**：spec 用「任一 `func`」描述能力面，实际可用面是「同包内函数名唯一」。该限制未出现在 spec 的边界段
- **建议**：生成名加入所属类型（`__jitSigRegister_<Type>_<func>`），或在 spec 边界写明「顶层 func 或同包内函数名唯一」，并让宏对重名给出显式诊断

> **范围外提示（不计入统计，均为读文档取证时撞见）**
> 1. `f_jit/src/compiler/Lowerer.cj:2695-2738`（`castRelation`，供 `is` 用）与 `:2802-2846`（`lowerCastOr`）是同一「左值/目标类型关系」判定的两份实现且已漂移：前者把 JSON 上行 `17/18/19 → 16` 判为静态放行，后者只判 `sCode != tCode` 就报「类型不相容」，`o as JsonValue` 疑似编译失败（未跑编译，待确认）。
> 2. `f_jit/src/runtime/HelperId.cj:21-22` 注释仍写「64–68 仍保留」，实际 64/65 已是 H64/H65、77–84 已登记；`isFixed` 实现为「名字已登记」（`:223-226`），与注释「63–68 与区间外 ⇒ false」不符；`MAX_FIXED=72`（`:125`）无任何使用；`f_jit/src/compiler/Ops.cj:244` 注释写「H66 `cast_fail`」，实际是 H77。
> 3. `f_jit/src/base/HostSignature.cj:98-99` 与 `f_jit/src/JitHost.cj:75` 注释写「未命中即编译错误」，与 m2.2 spec（未登记回退反射）及 `JitSignature_test.reflectionStillWorksWhenUnregistered` 相反。
> 4. `f_jit/src/ReflectRegistrar.cj:975` 的 `depth < 64` 是运行期父链硬上限，超出后 `$as$` 恒假，而 m2.3 spec 写的是无条件的「子类实例算命中」。

## 优化可行性方案

### [CPU] 让热点宿主闭包签名全部命中类型化 adapter，绕开 `FunctionTypeInfo.apply`

- **现状**：未登记签名走反射路径（`f_jit/src/runtime/HostCall.cj:62-70`）；同构一元 `(Int64)->Int64` 实测宿主闭包 ≈ 707 ns/次 vs user helper ≈ 153 ns/次 = **4.63×**（第二轮 5.75×），留档 `doc/perf-m2.md`，出处 `f_jit/doc/spec/f-jit-m2/verify.md:243`
- **方案**：对热点签名用 `@JitSignatures` / `JitHost.registerSignature` 登记，adapter 在 pin 时按「码 + 逐位类名 + 返回码 + 返回类名」命中（`f_jit/src/base/HostSignature.cj:135-190`），调用期零查找
- **预期**：m2.2 门禁要求 adapter 相对反射 ≥1.3×（`f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md:59-60`）。注意这是**相对反射**的收益，不等于相对 user helper 的端到端收益
- **代价**：每个热点签名多一份登记与一个 adapter 闭包；未登记仍回退反射（语义不变）；登记面扩大后 14 位置的类名必须写准（错写即不命中）
- **验证**：`cjpm bench -O2`，同输入（回调循环 5 万次）对照 adapter / 反射 / user helper 三路，报绝对值、中位数与离散程度
- **证据状态**：`无基线（待验证）` —— 4.63× 是「闭包 vs user helper」，adapter 覆盖后的端到端降幅没有改前/改后对照，不进 `tasks.md`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | CALL_HOST 在真实业务回调密度下仍是可测开销 | `f_jit/src/runtime/HostCall.cj:62` | 端到端自耗时占比、调用频次 | `cjprof record` 跑 ≥10k 次/秒回调 10 分钟，看 `apply` 与逐参 marshal 的自耗时 |
| 2 | 签名表线性扫描在 pin 期是否成热点（条目增多后） | `f_jit/src/base/HostSignature.cj:135-190` | 条目数 × pin 频次 | 埋点 `signatureCount()` 与 pin 次数，`cjpm bench -O2` 对照 K=1/10/50 个签名 |
| 3 | `$as$<C>` 的反射父链判定在转型密集循环中的占比 | `f_jit/src/ReflectRegistrar.cj:384-390`、`:972-987` | 自耗时占比、单次耗时 | `cjprof` 跑 10^6 次下转型循环（`-O2`），对比静态可判分支 |
| 4 | 字段访问的 `accepts` 按字段表线性尝试（每次一次反射判定），表项多时可能放大 | `f_jit/src/ReflectRegistrar.cj:181`、`:544`、`:1001` | 同 index 表项数、单次 `u.f` 耗时 | 注册 K 个类（K=1/10/50）后跑 10^6 次 `u.f`，`cjpm bench -O2` 比中位数 |

## 文件覆盖

> 与 `files/f_jit.part10.txt` 的 20 行一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 见发现 #3（裸 `as` / 下转型面与矩阵、m2.3 相反） |
| 2 | `f_jit/doc/spec/f-jit-m2.2/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 见 #9（`callForFn` 已更名）、#10（close 协议） |
| 3 | `f_jit/doc/spec/f-jit-m2.2/tasks.md` | .md | ✅ | 见 #4（无 `verify.md`）、#5（任务是 M2 清单副本） |
| 4 | `f_jit/doc/spec/f-jit-m2.3/design.md` | .md | ✅ | 见 #7（「执行路径零反射」不变量） |
| 5 | `f_jit/doc/spec/f-jit-m2.3/proposal.md` | .md | ✅ | `verify.md` 用「若存在」对冲，合规；与 design/spec 一致 |
| 6 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 三态转型、`castor`、7 `BAD_CAST` 与实现一致；`:15`/`:49-50` 是 #3、#7 的证据 |
| 7 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 宏生成物（公开登记函数 + 包级 let、扁平签名、14 记类名）与 `JitSignature.cj` 一致；见 #12 |
| 8 | `f_jit/doc/spec/f-jit-m2.3/specs/f-jit-runtime/spec.md` | .md | ✅ | H77 与 66–68 保留位与 `HelperId.cj:99`、`:197`、`:214-218`、`:223-226` 一致 |
| 9 | `f_jit/doc/spec/f-jit-m2.3/tasks.md` | .md | ✅ | 见 #4、#5（溯源 `plan-m2.md` 无出处） |
| 10 | `f_jit/doc/spec/f-jit-m2/baseline.md` | .md | ✅ | 560/560 与 `verify.md:8`、`:372` 三处自洽 |
| 11 | `f_jit/doc/spec/f-jit-m2/design.md` | .md | ✅ | 见 #1（D3 + 版本指针）、#8（D4 `sig`）、#9（`callFor`） |
| 12 | `f_jit/doc/spec/f-jit-m2/proposal.md` | .md | ✅ | 见 #9（`callFor` 三处；M2.2 已更名而此处未回写） |
| 13 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-base-contracts/spec.md` | .md | ✅ | 13/14 合法集、token 10/11、21/99、`RegistrationException` 与 `src/base` 一致 |
| 14 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | `0x79` 行与 `OpInfo.cj:255` 一致；`0x7A/0x7B` 保留与 `:256-257` 一致 |
| 15 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 见 #2（`HostClosureT` 二元）、#6（CALL_HOST 语序） |
| 16 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | 4.6–5.8×、10× 门禁与 `verify.md:243`、`PerfM2_test` 一致 |
| 17 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 见 #9（`callFor`）、#10（close 协议） |
| 18 | `f_jit/doc/spec/f-jit-m2/specs/f-jit-runtime/spec.md` | .md | ✅ | 见 #2、#8；H63/H64/H65 条款与 `HostCall.cj`、`Helpers.cj` 一致 |
| 19 | `f_jit/doc/spec/f-jit-m2/tasks.md` | .md | ✅ | 54 步全 `[x]`，与 `verify.md:58` 的镜像结论一致；见 #9 |
| 20 | `f_jit/doc/spec/f-jit-m2/verify.md` | .md | ✅ | 见 #11（结论行、826/849）；51/156 与 spec 实际计数一致（逐文件计数复核通过） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 12 条发现均为「文档契约 ↔ 实现」类（本部分无源码可判）；安全性无外部输入面 |
| §1 死代码 | 1 | 本部分无 `.cj` 符号，改为「文档声明的符号在仓内是否可达」：逐个全仓 grep `ClassDescriptor.parents`、`isSameOrSubclass`、`retName`、`JitHost.registerSignature`、`SignatureRegistry`、`$as$`、`CAST_FAIL`、`moveOutGroup`、`isLocalTypeInLegalSet`、`TCoverage`、`castor`、`callForFn` 共 12 个符号，均有实现；零命中的只有矩阵里的 `closeIsIdempotentAndReleasesGroup`（计入 #4）与 `callFor`（计入 #9，不重复计数） |
| §2 重复逻辑 | 1 | 机械比对 m2 / m2.2 / m2.3 三份镜像的 requirement 块：唯一逐行重复是 m2.2 `specs/f-jit-facade-bridge/spec.md:8-33` 对 m2 `:62-89` 的整段复制（仅 `callFor`→`callForFn`），并入 #9/#10；代码侧 `as`/`is` 的两份同源判定按「范围外提示」记，不占统计 |
| §3 空实现 | 1 | 两份 tasks 的「全量测试通过（见 `verify.md`）」无实体文件（#4）。无函数体可判 |
| §4 栈溢出 | 0 | 文档只承诺固定深度语义（`CALL_HOST` 重入 ≥3、构造嵌套一层），无「遍历用户可控结构」的递归条款；`$as$` 父链是 `while` + 64 层上限（范围外提示 4） |
| §5 OOM | 0 | 文档未承诺无界容器，窗口/提升组账目均写「每次至多 1 槽」；`SignatureRegistry` 规模由代码常量决定，未达「不可信长度」判据 |
| §6.1 热点瓶颈 | 0 | 无本部分相关的 profile；`verify.md:243` 只有闭包 vs helper 的比值，不足以定位热点，已转待验证假设 1–4 |
| §6.2 大粒度锁 | 0 | 文档只声明「句柄表操作有锁」「并发失败互不串扰」，未承诺锁内 I/O / 回调；临界区实现不在本部分 |
| §6.3 并发串行 | 0 | 文档无「并发度 = 1」类承诺；m2.2 的类型化快速路径本身是降低串行反射开销的方向 |
| §6.4 低效算法 | 0 | 文档无复杂度承诺；`$as$` 为 O(继承深度)、字段表 `accepts` 为 O(表项数)，均无规模数据（假设 3/4） |
| §7 降堆内存方案 | 0 | 本部分无分配量 / 峰值内存数据，仅有一个时间比值，按规则不出方案 |
| §8 降 CPU 方案 | 1 | adapter 覆盖热点签名（见「优化可行性方案」），证据状态 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；无峰值内存前后对照，且本部分无候选函数 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码；取证时撞见的代码侧问题按「范围外提示」记 4 条，不占统计 |
| §12 并发安全与锁粒度 | 0 | 文档层要求「新 ctx、独立事务、内层错误不覆盖外层」「句柄表有锁」，与本轮读到的实现一致，未发现相反承诺；`JitFunction` 状态机细节属模块其它部分 |
| §14 功能完备性与 README 覆盖 | 2 | #5（tasks 反写内容/溯源错误）、#12（「任一 func」承诺面）；本部分无 README，README 覆盖项不适用 |
| 文件覆盖（§13 等） | 20/20 | 无缺读文件；本部分 12 条均含 §13 要素（#4/#5 另计入 §14） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

本部分 20 份文档是 M2 系列的归档规格，**主体与实现贴合**：13/14 类型码与句柄 tag、`0x79` opcode 行、H63/H64/H65、H77 与 66–68 保留位、`$as$` 注册期合成、`@JitSignatures` 的「公开登记函数 + 包级 let」形态、`callForFn`、`ClassDescriptor.parents`、`M2.2/M2.3` 的 `as` 三态与运行期兜底，都能在代码里逐条对上；`verify.md` 的 51 requirement / 156 scenario 与 spec 实际计数一致，M1 基线 560 三处自洽。**没有严重项**：不存在会导致崩溃、数据错误或安全问题的契约矛盾。

需要处理的是三类「归档回写不彻底」，且都落在 M2 自己 verify 点名过的区域：

1. **验签方案与类型载体**（#1、#2）：design D3 与 tasks 仍写「单次 `is`」，`SignatureDescriptor`/`HostClosureT` 的 delta 仍只有类型码——正是 GAP-04/GAP-05 的文本根因，只改代码不改文档，下一轮还会被重新发现。建议无条件修（纯文字）。
2. **验收与任务链**（#4、#5）：m2.2/m2.3 没有 `verify.md`，m2.2 矩阵 21→20 且 1 条用例改名（脚本实测 `缺失 1`），两份 tasks 一份粘错清单、一份溯源到不含 M2.3 的 `plan-m2.md`。归档结论因此不可复核，建议下一轮补最小 verify 时一并处理。
3. **行为契约被后续实现推翻却无取代记录**（#8、#9、#10）：`HostCallback.sig` 可空、`callFor`→`callForFn`、`close` 协议（入口实例已改为单元卸载）。单条都只是轻微，但会让「按 spec 复核」得出错误结论。

另外 #3（m2.2 的裸 `as` 与下转型面）与 #6（CALL_HOST 语序）是**同一归档内 spec / 矩阵 / scenario / 实现互相矛盾**，建议优先修：它们直接决定读者对 `as` 语法面与 CALL_HOST 栈序的认知，而后者已被本变更 verify 判为「应在 archive 前修订」却未修订。

存量 12 条（一般 7 / 轻微 5），是否纳入修复待用户决定；本部分未发现需要阻塞合并的缺陷。
