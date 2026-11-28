# f_jit 模块审查报告 — 第 24/38 部分

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src`（本部分 18 个源文件，0 个 `.md`）
- **基线**：工作区快照（`git diff` 为空，HEAD `f309f0b55`；本部分所有问题均为存量，blame 落在 `bb87fa03af`/`5ef620d752`/`069e6e37c1`/`204f1bc1e6`，2026-10-19～10-23）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：分部分报告（由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）
- **本部分构成**：`ReflectRegistrar.cj`（唯一非测试源文件，反射自动注册）、`Root.cj`（用户面再导出）、其余 16 个测试文件

## 发现

### [一般][存量] `mapType` 按简单名前缀判定容器/区间类型，用户类名撞前缀即被误映射成句柄码

- **位置**：`f_jit/src/ReflectRegistrar.cj:792`、`f_jit/src/ReflectRegistrar.cj:795`、`f_jit/src/ReflectRegistrar.cj:798`
- **来源**：存量（`git blame` → `bb87fa03af`，2026-10-19）
- **判据**：checklist §11「契约与实现不符」+ 本模块专项「typecode 分支表正确性」
- **证据**：静态确定 —— `let n = info.name`（`mapType` 用的就是**简单名**），随后 `n.startsWith('Range')` → `LocalType.RANGE`（8）、`n.startsWith('ArrayList')` → `LIST`（10）、`n.startsWith('HashMap')` → `MAP`（11），没有分隔符或包名约束。
- **描述**：`ClassRegistry.isBuiltinName` 只拦住了 `Range`/`ArrayList`/`HashMap` 这几个**精确**名字（`f_jit/src/ClassRegistry.cj:145-153`），所以 `RangeFinder`、`ArrayListCache`、`HashMapShard` 这类类名可以正常注册（非内建、非关键字）。注册时 `mapType` 会把它们的字段/参数/返回码判成 8/10/11，而运行期 `hostGetField` 会按 `fieldToken(code)` 期望 `TypeToken.RANGE/LIST/MAP`（`f_jit/src/runtime/HostField.cj:196-202`）→ 类型不符 → `failWith(HELPER_PANIC)`（99）。后果是「类注册成功、字段访问恒 99」，且诊断里看不到任何线索。
- **建议**：改成精确匹配 —— `n == 'Range'`，或对泛型形态用 `n.startsWith('Range<')`；更稳的是用 `info.pkgName`（若 SDK 暴露，需先查 `std.reflect` 文档确认签名）限定 `std.core`/`std.collection` 后再判前缀。`isRefCode` 同理应改为复用 `LocalType.isHandle`（见下条重复逻辑）。

### [一般][存量] 父类字段并入子描述符后，无 `@JitBind` 的反射访问器在子类实例上必然抛异常 → 21

- **位置**：`f_jit/src/ReflectRegistrar.cj:541`（`pending.add` 注册）、`f_jit/src/ReflectRegistrar.cj:545`（`getter`）、`f_jit/src/ReflectRegistrar.cj:548`（`member.getValue(o)`）
- **来源**：存量（`git blame` → `069e6e37c1`，2026-10-23）
- **判据**：checklist §11「契约与实现不符」；本模块专项「句柄与资源生命周期 / 桥接正确性」
- **证据**：静态确定 —— 该访问器的 `accepts` 是 `isInstanceOf(o, rowAncestry)`，`rowAncestry[0]` = **子类**名，故任何子类实例都会命中；而 `getter` 回退路径是父类 `InstanceVariableInfo.getValue(o)`。同一个仓库里的用例自己固定了这条硬限制：`f_jit/src/ReflectRegistrar_test.cj:423-441`（`reflectGetValueRejectsSubclassInstance`）断言 `acc.getter(admin)` 抛 `IllegalTypeException`。
- **描述**：`ClassRegistry`/`Descriptor` 层面「子类可访问父类字段」是成立的（`mergeAncestorFields` 的注释 `f_jit/src/ReflectRegistrar.cj:499-504`），但执行层对纯反射访问器做不到。`hostGetField` 把该异常记为 `HostFault` 并返回 21（`f_jit/src/runtime/HostField.cj:163-170`），所以脚本读子类实例的继承字段会稳定拿到 `ERR_HOST_EXCEPTION`，而不是值，也不是「字段不存在」这类可诊断错误。只有宿主给了 `@JitBind`（`typedField` 命中）时才真正可用。
- **建议**：在 `mergeAncestorFields` 里对 `typed == None` 的父类字段**不注册**并记 `RegistrationSkipped`（理由写清「反射 getValue 不支持子类实例，请给父类加 @JitBind」），让失败提前到注册期；或在描述符里标记「仅 typed 可用」，由前端在编译期拒绝。当前形态等于把注册期可判定的限制推迟成运行期 21。

### [一般][存量] 性能门禁写在单元测试里，且两臂相减的算法在噪声下会假失败

- **位置**：`f_jit/src/PerfOverride_test.cj:110`（假失败记录）、`f_jit/src/PerfOverride_test.cj:121-131`（`rc`/`oc` 钳到 1）、`f_jit/src/PerfOverride_test.cj:152-155`（`median >= 800` 即 `@Fail`）；`f_jit/src/PerfM2_test.cj:104`、`f_jit/src/PerfM2_test.cj:121-124`
- **来源**：存量（`git blame` 落在 2026-10-19/20 的性能用例提交）
- **判据**：checklist §6.1（比值必须同环境对照、不能只看一次结果）+ §11「错误处理/判定不对称」
- **证据**：静态确定 —— 用例注释自己记录过假失败（`PerfOverride_test.cj:111`：「实测出现过比值 0.82 > 0.80 的假失败」）。算法上：`let rc = if (r > b) { r - b } else { 1 }`，一旦反射臂因调度抖动比空壳臂还快（`r <= b`），`rc` 被钳成 `1`，`q = oc * 1000 / 1` 必然 ≫ 800 → 直接 `@Fail`；`oc` 侧同理。即「噪声导致差值为负」被转成「确定性的门禁失败」。
- **描述**：`PerfOverride_test` / `PerfM2_test` 分别对 `JitFunction.call<T>` 的 6–9 µs 量级净成本、`user helper` vs 宿主闭包比值做硬门禁。这类比值对 CPU 频率、同机其他进程、GC 时机高度敏感，而它们跑在普通 `cjpm test` 里（不是 `cjpm bench`），CI 上并行跑其他用例时抖动更大；一旦假红，需要人工辨识，长期会让人习惯性重跑，门禁失效。`PerfM2` 的 1×–10× 区间相对宽松，风险低于 `PerfOverride` 的 800/1000 阈值。
- **建议**：把比值门禁移到 `cjpm bench -O2` 的独立作业（同机、同输入、中位数 + 离散度），单元测试只保留「两臂都能跑通且结果正确」；若必须留在用例里，给 `rc`/`oc` 加绝对下限（如 `rc < rounds * 200ns` 判为「无效测量」并跳过判定而非 `@Fail`），并对失败做一次重测再判。

### [轻微][存量] 死代码：无引用的 `sceneOk`、未使用的 import、写了不读的局部变量

- **位置**：
  - `f_jit/src/Q6Acceptance_test.cj:297-299`（`private static func sceneOk`：全仓 `grep -rn "sceneOk" f_jit/src` 仅命中定义处）
  - `f_jit/src/Q6Acceptance_test.cj:20`（`import std.reflect.TypeInfo`：文件内 `TypeInfo` 只出现在第 411 行注释里）
  - `f_jit/src/Q6Acceptance_test.cj:395`+`:400`（`var kind` 赋值后从不读取，断言只用 `msg`）
  - `f_jit/src/Q6Acceptance_test.cj:866`（`let base = HandleTable.liveCount()` 之后直接 `resetForTest()`，`base` 未读）
  - `f_jit/src/ReflectRegistrar.cj:172`+`:198`（`let rowName = name` 只为第 198 行 `let _ = rowName` 存在）
  - `f_jit/src/RuntimeStateIsolation_test.cj:91-95`、`f_jit/src/RuntimeStateIsolation_test.cj:126-130`（`var i` 只自增，从未参与断言）
- **来源**：存量（`git blame`：`sceneOk` → `5ef620d752`）
- **判据**：checklist §1「无调用者 / 未使用的 import / 读了不用」
- **证据**：静态确定 —— `private` 符号按「全仓搜索仅命中定义处」判；局部变量按「赋值后无读取」判。
- **描述**：`sceneOk` 是 `TCase.hit` 的薄包装，但 40 余处调用点都直接写 `TCase.hit(...)`，包装体已成孤儿；`kind`/`base`/`i` 属于旧断言残留，会让读者以为还有额外校验。
- **建议**：删除 `sceneOk` 与未用 import；删除 `kind`/`base`/`i`/`rowName`（`rowName` 若原本想用于诊断信息，应真正拼进 `skip(...)` 的 `member` 参数）。

### [轻微][存量] 重复逻辑：`median3` 三份；`code<T>`/`codeOf`、`codeOpt<T>`/`codeOptOf` 两两同义

- **位置**：`f_jit/src/PerfM2_test.cj:43`、`f_jit/src/PerfOverride_test.cj:70`、`f_jit/src/CallPathBench_test.cj:52`（三份 `median3` 逐行相同）；`f_jit/src/ReflectMap_test.cj:166` 与 `f_jit/src/ReflectMap_test.cj:181`（`code<T>` / `codeOf`）、`f_jit/src/ReflectMap_test.cj:173` 与 `f_jit/src/ReflectMap_test.cj:177`（`codeOpt<T>` / `codeOptOf`）
- **来源**：存量
- **判据**：checklist §2「只改类型名 / 换签名但语义相同」
- **证据**：静态确定 —— `median3` 三处函数体逐字一致；`code<T>()` 与 `codeOf(TypeInfo.of<T>())` 的输入输出完全等价（都是 `mapType` → `Some(c) => c` / `None => NONE`）。
- **描述**：`median3` 是本模块性能用例的公共判定工具，三份副本意味着后续若调整（例如改 5 轮取中位数）只改一处会造成判定口径漂移。`ReflectMap_test` 的四个 helper 里有两个纯属泛型/非泛型同名重复。
- **建议**：把 `median3`（以及 `PerfOverride_test.measure` 这类计时骨架）移到 `f_jit/src/test/` 下的测试辅助（如 `test/PerfSupport.cj`），三处引用同一实现；`ReflectMap_test` 只保留 `codeOf`/`codeOptOf`，泛型版直接写成 `codeOf(TypeInfo.of<T>())`。

### [轻微][存量] 重复的双实现：数组「替换/追加」与「类型码区间」各写两套

- **位置**：`f_jit/src/ReflectRegistrar.cj:693-714`（`appendMethod`/`appendFunction`）、`f_jit/src/ReflectRegistrar.cj:742-755`（`copyMethods`/`copyFunctions`）、`f_jit/src/ReflectRegistrar.cj:757-773`（`replaceFunction`）对照 `f_jit/src/base/JitBindings.cj:137-156`（`replaceMethod`）、`f_jit/src/base/JitBindings.cj:199-218`（`replaceStatic`）；`f_jit/src/ReflectRegistrar.cj:717-719`（`isRefCode` 4–14）对照 `f_jit/src/base/LocalType.cj:125-127`（`isHandle` 4–19）
- **来源**：存量
- **判据**：checklist §2「字面量复制 / 换类型名」
- **证据**：静态确定 —— `appendMethod`/`appendFunction`、`copyMethods`/`copyFunctions` 函数体逐行相同，仅元素类型不同；`replaceFunction` 与 `JitBindings.replaceStatic` 是同一语义（找同名 → 替换 → 未命中则追加）；`isRefCode` 是 `isHandle` 的手写子区间。
- **描述**：同一「按名替换/追加」能力存在两套实现，修改其中一处（例如改成稳定去重、或改成返回同一数组以避免拷贝）不会同步到另一处。`isRefCode` 与 `isHandle` 的上界不同（14 vs 19）目前是**有意**的（GAP-13 只针对 4–14 的反射 apply），但没有注释说明这层差异，后续加 15（Any）时很容易被误改。
- **建议**：上提一个泛型辅助（`replaceByName<T>(xs, name, v)`）或让 `ReflectRegistrar` 直接复用 `JitBindings` 的静态方法；`isRefCode` 改为 `c >= LocalType.STRING && c <= LocalType.HOST_OBJECT` 时补一句「与 `LocalType.isHandle` 刻意不同：GAP-13 只覆盖 4–14」的注释。

### [轻微][存量] `Skeleton_test` 的「六包齐备」护栏恒真，且注释与 import 不符

- **位置**：`f_jit/src/Skeleton_test.cj:24-34`（注释）、`f_jit/src/Skeleton_test.cj:39-46`（用例体）
- **来源**：存量
- **判据**：checklist §3「空实现 / 恒真断言」+ §11「注释与实现不符」
- **证据**：静态确定 —— 注释写「本文件顶部 import 了 `base`/`bytecode`/`compiler`/`runtime`/`backend`，任一个包声明文件缺失都会编译失败」，但该文件实际只 import 了 `f_base.*`/`f_regex.*`/`f_util.*`（`Skeleton_test.cj:20-22`）；用例体只有一个字面量数组 `layout`，断言 `layout.size == 6`。
- **描述**：这条用例无论子包是否存在、是否成环都会通过（数组是本地构造的），等于没有护栏；而注释会让后来者以为「删子包会红」。
- **建议**：改成真实引用各子包符号（如 `LocalType.I64`、`SourceCompiler(...)`、`HandleTable.windowUsed()`、`Assembler` 等），或直接删除该用例并把「包结构」交给 `cjpm build` 的编译失败来保证。

### [轻微][存量] `Q6Acceptance_test` 的注释与当前实现矛盾（19/20 口径、残留思考记录、两段互相否定的 doc）

- **位置**：`f_jit/src/Q6Acceptance_test.cj:406` 与 `:407-413`（同一函数上叠了两段 doc，前者说「>2 元是已知限制」，后者说已被解除）；`f_jit/src/Q6Acceptance_test.cj:474`（`// outer -> unitB -> leaf(10) + 10 = 20 -> +? 见下`）；`f_jit/src/Q6Acceptance_test.cj:1121`（「let 写 → 19」）、`f_jit/src/Q6Acceptance_test.cj:1195`（「裸 H65 → 19」）
- **来源**：存量
- **判据**：checklist §11「语义与命名/注释不符」
- **证据**：静态确定 —— `ErrCode.READONLY = 20`、`ErrCode.CALL_CONTRACT = 19`（`f_jit/src/base/ErrCode.cj:69-71`），而同文件 `t35FieldTypeMatrixAndDefense` 断言的正是 `ErrCode.READONLY`（`:1132`）；`runtime/HostField.cj:207-209` 也明确「`mutable=false` ⇒ **20（READONLY）**（A7/P3-4 口径统一）」。
- **描述**：`let` 字段写入的失败码是 20，注释两处写成 19（19 是调用契约错误）。这两处恰好是「口径统一」项目明确治理过的点，注释保留旧值会把下一个读者引向错误码。`474` 行的 `-> +? 见下` 是写作过程中的推演残留。406/407 行两段相邻 doc 结论相反（限制存在 / 限制已解除）。
- **建议**：删掉 `:406` 的旧限制段；`474` 行注释改为陈述最终结果（`outer -> b(=unitB(1)+10=11) -> 11`）；把两处 19 改成 20 并写明 `ErrCode.READONLY`。

### [轻微][存量] `RecReflectSink.onlySkipped()` 名不符实，两条断言实际只验证「诊断条数 > 0」

- **位置**：`f_jit/src/ReflectRegistrar_test.cj:366-368`（`diag` 丢弃 `level`/`code`）、`f_jit/src/ReflectRegistrar_test.cj:383-385`（`onlySkipped` 只判 `size > 0`）、调用点 `:117`、`:166`
- **来源**：存量
- **判据**：checklist §11「契约与实现不符」+ 本模块专项「重复逻辑/装配正确性」
- **证据**：静态确定 —— 函数体 `this.messages.size > 0`；`diag(level, code, message)` 的三个形参里只有 `message` 被保存。
- **描述**：用例名与断言意图是「**全部**诊断都是 `RegistrationSkipped`（没有 Error 级）」，实现只能证明「至少有一条诊断」。若注册期混入 `DiagCode` 其他码或 `DiagnosticLevel.Error`，`skipsStaticMutableMembersWithDiagnostics` / `nameConflictSkipsOnlyThatName` 仍然绿。
- **建议**：`messages` 改为存 `(DiagnosticLevel, DiagCode, String)` 三元组，`onlySkipped()` 判「非空且每条的 `code == DiagCode.RegistrationSkipped`」；顺带补一条「无 Error 级」的断言。

### [轻微][存量] `registerInterface` 对未注册的父接口静默跳过，无任何诊断

- **位置**：`f_jit/src/ReflectRegistrar.cj:421-432`（`match (into.resolve(pname)) { case None => () }`）
- **来源**：存量（`git blame` → `069e6e37c1`）
- **判据**：checklist §3「`case None => ()` 把缺失吃掉」
- **证据**：静态确定 —— 父接口名已在 `effective.parents` 里（说明宏侧认为它是父接口），此处解析不到只是 `()`，既不 `skip` 也不抛 `RegistrationException`。
- **描述**：父接口未注册（注册顺序问题或漏注册）时，子接口的描述符会少掉整组父方法，编译期表现为「函数未注册」，注册期没有任何提示。同一函数里其他拒绝路径都会抛 `RegistrationException`（`:415-418`），这条不一致。
- **建议**：`case None => ReflectRegistrar.skip(diag, '${name} extends ${pname}', '父接口未注册，父方法未并入')`；若要强约束则抛 `RegistrationException(RegistrationRejectKind.ReflectionUnavailable, ...)`。

### [轻微][存量] 祖先链遍历上限不一致（32 vs 64），超限静默截断

- **位置**：`f_jit/src/ReflectRegistrar.cj:509`（`mergeAncestorFields`，`depth < 32`）、`f_jit/src/ReflectRegistrar.cj:577`（`mergeAncestorMethods`，`depth < 32`）、`f_jit/src/ReflectRegistrar.cj:959`（`ancestryOf`，`depth < 64`）、`f_jit/src/ReflectRegistrar.cj:975`（`isInstanceOfClass`，`depth < 64`）
- **来源**：存量
- **判据**：checklist §11「边界」+ §4（有界递归/循环的上界必须与其它路径一致）
- **证据**：静态确定 —— 同一条祖先链在 `ancestryOf` 里取到 64 层，在字段/方法并入里只走到 32 层，且两处都没有诊断。
- **描述**：声明链深于 32 的类，`parents` 里有该祖先，但祖先的字段/方法没被并入子描述符：脚本按 `parents` 语义写 `c.grandField` 会编译失败，或落到 99。触发条件苛刻（>32 层继承），但两处常量没有注释说明为什么不同，容易被误认为笔误。
- **建议**：抽一个模块级常量（如 `ANCESTRY_LIMIT`）供四处共用；到达上限时 `skip(...)` 记一条「祖先链超过 N 层，后续祖先未注册」的诊断。

### [轻微][存量] 父类成员不可映射时静默 `continue`，与自有成员路径（有诊断）不对称

- **位置**：`f_jit/src/ReflectRegistrar.cj:521-524`（父类字段 `codeOpt.isNone()` → `continue`）、`f_jit/src/ReflectRegistrar.cj:626-629`（父类属性同上）对照 `f_jit/src/ReflectRegistrar.cj:153-157`、`:214-218`（自有字段/属性 `skip(diag, ...)`）
- **来源**：存量
- **判据**：checklist §2「近似重复但少一条边界处理」（差异导致行为漂移）
- **证据**：静态确定 —— 两条路径的类型映射逻辑逐行同构，唯独失败分支一条 `skip` 一条 `continue`。
- **描述**：父类有一个不可映射类型的字段时，注册完全静默：既不报「跳过」，使用者也不知道该字段在子类上不可用，排查成本落在运行期 99 上。
- **建议**：与自有成员路径对齐，补 `ReflectRegistrar.skip(diag, '${p.name}.${v.name}', '父类字段类型不可映射')` / `'父类属性类型不可映射'`；`mergeAncestorMethods` 的属性分支同理。

### [轻微][存量] `T40Deopt_test` 用裸数字当 helper id、`TCase.hit` 传常量 `true`、改写全局 `HandleTable` 配置不复位

- **位置**：`f_jit/src/T40Deopt_test.cj:51`（`invokeHelper(c, 78, ...)`）、`:56-57`（79/80）、`:65`（`TCase.hit('T40/deopt-replay', true)`）、`:45-46`（`HandleTable.initialCapacity = 128` / `capacityLimit = 1048576` 无 `finally` 复位）
- **来源**：存量（`git blame` → `204f1bc1e6`，2026-10-20）
- **判据**：checklist §11「字面量复制」+ `TCase` 自身契约（`f_jit/src/test/TCase.cj:22-28`：标签必须与它守卫的断言同生共死）+ §12「测试间全局状态」
- **证据**：静态确定 —— `HelperId.ANY_BOX/ANY_IS/ANY_AS` 就是 78/79/80（`f_jit/src/runtime/HelperId.cj:102-104`）；`:65` 的 `ok` 参数是字面量 `true`，与前一行的 `@Assert` 无耦合；`:45-46` 直接改静态字段，`HandleTable.resetForTest()`（`:44`）只清句柄不还原容量配置。
- **描述**：三处都属于「测试自身不严谨」：裸 78/79/80 在 `HelperId` 重排后会静默测错 helper（且报错信息里看不出来）；恒真标签违反 `TCase` 的设计意图（标签删改不会被发现）；容量配置泄漏到同进程后续用例（`RuntimeStateIsolation_test.cj:67` 就读 `HandleTable.initialCapacity` 当基准）。
- **建议**：改用 `Int64(HelperId.ANY_BOX)` 等常量；标签改为 `TCase.hit('T40/deopt-replay', f.isJitBacked() || true)` 这类真实条件或直接并入上一行 `@Assert`；容量配置放进 `try/finally` 复原（参考 `SignatureTableConcurrency_test.cj:171-176` 对 `SignatureTable.enabled` 的处理）。

### [轻微][存量] 字段访问器登记无去重/无上限；注册被拒时保活表仍留条目

- **位置**：`f_jit/src/ReflectRegistrar.cj:376-378`（`pending` 逐字段 `HostFieldTable.register`）、`f_jit/src/ReflectRegistrar.cj:129`（`retainClass` 早于 `:375` 的 `into.register`）
- **来源**：存量
- **判据**：checklist §5「无界容器 / 长期持有」+ §11「资源不对称」
- **证据**：静态确定 —— `HostFieldTable.register` 每次无条件 `list.add(acc)` 并整表重建（`f_jit/src/runtime/HostField.cj:96-113`），没有任何「同 (index, accepts, 类) 已登记」的判重；`ClassRegistry.register` 的 `DuplicateClass` 拒绝（`f_jit/src/ClassRegistry.cj:72-85`）拦不住「同一类注册进两个不同的 `ClassRegistry`」这一形态（`ReflectRegistrar_test.cj:454-464` 正是这么用的）。
- **描述**：每多注册一次同类，全局表就多一组访问器（`find` 线性扫变长、内存常驻），且先命中的那组生效——若两次注册的绑定来源不同（一次带 `@JitBind`、一次纯反射），行为取决于注册顺序。`retainClass` 在 `into.register` 之前执行，注册被拒时 `retainedNames/retained` 仍多一条，`retainedCount()` 与「已注册类数」不再等价。
- **建议**：`pending` 里登记前先查一次「同 index + 同类」是否已存在（或让 `HostFieldTable.register` 支持幂等键）；把 `retainClass(cls)` 移到 `into.register(descObj)` 成功之后；`retained` 增删与注册表生命周期对齐，或至少提供 `release(name)`。

## 优化可行性方案

### [CPU] `HostFieldTable.register` 每字段整表重建，注册 k 个访问器是 O(k²) 拷贝

- **现状**：`pending` 里每个字段调一次 `HostFieldTable.register`；该函数在 `writeMtx` 内把**整个** bucket 映射复制进新 `HashMap`，再把该 index 的数组整体复制一遍后追加（`f_jit/src/runtime/HostField.cj:96-113`）。注册 N 个访问器 ⇒ N 次全量复制，累计 O(N²) 元素拷贝 + N 个 `HashMap`/`ArrayList`/`Array` 的分配。量级：一个 20 类 × 10 字段的宿主约 N≈200 ⇒ 约 2 万次元素拷贝 + 200 次全表重建，全部发生在 `Compiler.mtx` 内。
- **方案**：`registerType` 内先收集本类的 `Array<HostFieldAccessor>`，注册完一次性提交（新增 `HostFieldTable.registerBatch(items)`，在锁内只重建一次快照）；或把内部表示改成 持久化追加（每 index 一个不可变链表头 + 原子发布）。
- **预期**：注册期全表重建次数从 N 降到 1（或按类降到 C），元素拷贝从 O(N²) 降到 O(N)。未测，不给百分比。
- **代价**：新增一个 `internal` API；`register` 单条调用的现有语义（立即可见）需要保留给手工注册路径。
- **验证**：对「100 类 × 20 字段」的宿主跑 `cjpm bench -O2`，量 `Compiler.registerType` 总耗时（改前/改后，中位数 10 轮）；同时用 `getAllocatedHeapSize()` 对照注册期分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 注册期在 `Compiler.mtx` 内做完整反射枚举

- **现状**：`Compiler.registerType` 在 `this.mtx` 内调用整个 `ReflectRegistrar.registerType`（`f_jit/src/Compiler.cj:137-142`），其中包含 `cls.instanceVariables/instanceProperties/instanceFunctions/staticVariables/staticProperties/staticFunctions/constructors` 全量枚举、每成员一次 `mapType`（`TypeInfo.name` 反射调用）、每字段一次 `HostFieldTable.register`（见上条）、每类一次 `ancestryOf`。临界区长度属毫秒级（未测）。
- **方案**：把「不可变产物」的计算（枚举 + 描述符 + 访问器数组）移到锁外，锁内只做「冲突检查 + 三处登记 + `snapCache` 失效」；或对同一 `Compiler` 的批量注册提供 `registerTypes(list)`，一次持锁。
- **预期**：启动期注册不再是串行尖峰；并发注册不同类的宿主线程不再互相等反射枚举。收益取决于宿主类数量，未测。
- **代价**：锁外计算会读到「注册前」的 `ClassRegistry` 状态，`claimName` 的冲突判定必须留在锁内重做一次（重试/回滚逻辑），复杂度上升。
- **验证**：4 线程各注册 20 个类的启动脚本，量注册总墙钟与 `this.mtx` 等待时间（线程状态证据，CPU profile 看不出锁等待）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `retained` 保活表与重复访问器都没有上限/淘汰

- **现状**：`retained`/`retainedNames` 每注册一个类名追加一条 `ClassTypeInfo` 强引用，进程生命周期内不释放（`f_jit/src/ReflectRegistrar.cj:62-78`）；重复注册（不同 `ClassRegistry`）会追加重复的字段访问器（见发现最后一节）。二者都以「宿主注册的类数」为上界，正常规模下很小（反射元数据每条数百字节到数 KB）。
- **方案**：`retained` 与注册表同生命周期管理（`release(name)` 对称注销）；访问器登记幂等化。不建议加 LRU——保活本身就是防 GC 的正确性要求，淘汰会重现 GAP-13 的 SIGSEGV。
- **预期**：只有「重复注册同一类」的宿主能观测到收益（访问器数从 k·n 降到 n）。稳态内存收益通常 < 1 MB，属于「防泄漏」而非「省内存」。
- **代价**：需要定义「类何时可释放」——目前没有类注销 API，新增会牵动 `ClassRegistry`/`Compiler` 的契约。
- **验证**：反复注册/注销同一批类 1000 轮，`getAllocatedHeapSize()` 与 `HostFieldTable` 条目数是否停在常数（`mem §1.2` 的有界稳态口径）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HostFieldTable.find` 的线性 `accepts` 扫描在字段访问热路径上占比可观（登记类越多，单次字段读越慢） | `f_jit/src/runtime/HostField.cj:121-133`（范围外文件，由本部分 `pending` 的登记密度驱动） | 自耗时占比、bucket 长度分布 | 注册 20/50/100 个类后，各跑 1e6 次 H64，`cjprof record` 看 `hostGetField`/`accepts` 自耗时；同时打印各 index 的 bucket 长度 |
| 2 | `Compiler.registerType` 的锁内反射枚举是启动期串行尖峰 | `f_jit/src/Compiler.cj:137-142` + `f_jit/src/ReflectRegistrar.cj:96-392` | 单类注册耗时、锁等待时长 | 对「100 类 × 20 字段」宿主分段计时（`MonoTime` 包住 registerType），4 线程并发注册，采集线程 BLOCKED 时长 |
| 3 | `PerfOverride_test` 的 800/1000 门禁在 CI 上假红频率偏高 | `f_jit/src/PerfOverride_test.cj:110-155` | 历史失败率、失败时的三轮原始比值 | 在 CI 里保留每次 `PERF-OVERRIDE round*` 打印，统计 100 次运行的 `medianRatioX1000` 分布（P50/P95/min） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/PerfM2_test.cj` | .cj | ✅ | 性能门禁用例，见发现「性能门禁」+ 重复逻辑 `median3` |
| 2 | `f_jit/src/PerfOverride_test.cj` | .cj | ✅ | 同上；`rc`/`oc` 钳 1 造成假失败 |
| 3 | `f_jit/src/PowSciA64_test.cj` | .cj | ✅ | A64 机器码承载断言，与实现一致；`compiled()` 与其它文件的 `reset+compile` 同构（测试准备代码，不判重复） |
| 4 | `f_jit/src/Pow_test.cj` | .cj | ✅ | 幂运算/科学计数法取值与错误码断言，与 `ErrCode` 一致；`compiler()` 为单行包装 |
| 5 | `f_jit/src/Q6Acceptance_test.cj` | .cj | ✅ | 见死代码、注释矛盾两节；`t60ConcurrentFailuresAreIsolated` 的 spawn→统一 get 属正确模式 |
| 6 | `f_jit/src/Q6DiffCoverage_test.cj` | .cj | ✅ | 差分用例；每个用例首尾都 `resetForTest`，隔离正确 |
| 7 | `f_jit/src/ReflectMap_test.cj` | .cj | ✅ | 见重复逻辑 `code<T>`/`codeOf` |
| 8 | `f_jit/src/ReflectRegistrar.cj` | .cj | ✅ | 本部分唯一产品代码，主要发现集中于此（mapType 前缀、继承字段、深度上限、同步跳过、访问器累积） |
| 9 | `f_jit/src/ReflectRegistrar_test.cj` | .cj | ✅ | 见 `onlySkipped()` 名不符实；`reflectGetValueRejectsSubclassInstance` 是继承字段问题的自证 |
| 10 | `f_jit/src/Root.cj` | .cj | ✅ | 用户面再导出；已核对 `CompileCache`/`CompilePipeline`/`AdapterRegistry` 均为 `protected`，与注释「不进用户面」一致 |
| 11 | `f_jit/src/RunUnit_test.cj` | .cj | ✅ | `.fbc` 装载/去重/坏 magic，与 `CompilePipeline.runUnit` 契约一致 |
| 12 | `f_jit/src/RuntimeStateIsolation_test.cj` | .cj | ✅ | TLS 隔离断言正确；两处死局部 `i`；`spin()` 忙等 20ms×4（测试耗时，非缺陷） |
| 13 | `f_jit/src/SignatureTableConcurrency_test.cj` | .cj | ✅ | 签名表并发/幂等/开关恢复（`finally`），断言只依赖相对关系，设计合理 |
| 14 | `f_jit/src/Skeleton_test.cj` | .cj | ✅ | 见「恒真护栏」 |
| 15 | `f_jit/src/Slot14_test.cj` | .cj | ✅ | 槽 14 全通道用例；部分 `@Assert` 与紧随的 `TCase.hit` 重复调用同一表达式（多一次 `call`），仅耗时 |
| 16 | `f_jit/src/StrictFp_test.cj` | .cj | ✅ | `defaultIsStrict` 与 `strictDivisionByZeroFails` 同语义（重复逻辑，已并入总条）；缓存键断言有效 |
| 17 | `f_jit/src/T40Deopt_test.cj` | .cj | ✅ | 见裸 helper id / 恒真标签 / 全局配置不复位 |
| 18 | `f_jit/src/TwoForms_test.cj` | .cj | ✅ | 机器码 vs 字节码同结果；`jc/bcc` 断言用字面量 `1` 而非 `ErrCode.DIV_ZERO`（与 `T40` 同类的字面量复制，未单列） |

合计：`.cj` 18 个 / `.md` 0 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（mapType 误映射、继承字段 21）；可读性/契约 2（注释矛盾、`onlySkipped` 名不符实）。安全检查了外部输入面：本部分无网络/文件输入，反射输入来自宿主类型声明，未发现注入或敏感数据落日志 |
| §1 死代码 | 1 | 逐 private 符号全仓搜索（`sceneOk` 仅命中定义）；逐文件核 import（`TypeInfo` 未用）；逐局部变量核「赋值后是否读取」（`kind`/`base`/`rowName`/`i`）；`ReflectRegistrar` 为 `protected class`，其 `public` 成员按「全项目使用」核过——`retainedCount`/`resetRetainedForTest`/`mapType`/`mapTypeRef`/`buildCtor`/`isInstanceOfHost` 均有用例或内部调用，只有 `sceneOk` 无引用；`public` 顶层测试类由 `@Test` 框架调用，不判 |
| §2 重复逻辑 | 3 | 已把本部分 30 个函数体压成「输入→输出→副作用」两两比对：`median3` 三份逐字相同、`code<T>`/`codeOf` 同义、`append*`/`copy*` 与 `JitBindings.replace*` 同义、`isRefCode` 与 `LocalType.isHandle` 同源不同界、父类/自有成员注册路径近似但少一条诊断；`*_test` 里 `CompileCache.reset()+Compiler().compile()` 属测试准备代码（误报边界），不判 |
| §3 空实现 | 2 | `registerInterface` 父接口缺失走 `case None => ()`；`Skeleton_test` 恒真断言。本部分无 `TODO`/`FIXME`/`UnsupportedException`（已 grep）；`ReflectRegistrar.cj:102`/`:115` 的 `catch (_: Exception)` 是文档化的降级与再抛，不判 |
| §4 栈溢出 | 0 | 本部分无递归：`ancestryOf`/`isInstanceOfClass`/`mergeAncestor*` 均为显式循环且带深度上限；`indexOfText` 为双指针迭代。已核对两处上限不同（记入 §11），但不构成无界递归 |
| §5 OOM | 1 | `retained`/访问器表只增不减、无去重（上界=宿主类数，非请求驱动，故记轻微）；其余容器均为用例内局部 `ArrayList` |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 输出（`doc/perf-m2.md` 有 36×/9797→270ns 的既测数据，但属另一部分文件）；三条疑似热点写入「待验证假设」并注明采集方式，未计入发现 |
| §6.2 大粒度锁 | 1 | `Compiler.mtx` 内做完整反射枚举 + 逐字段建表（`Compiler.cj:137-142`）。注册期一次性路径，不在请求主路径；已改写进「优化可行性方案」，不作为缺陷 |
| §6.3 并发串行 | 0 | `spawn` 后都先收齐 `Future` 再统一 `get`（`Q6Acceptance_test.cj:630-663`、`RuntimeStateIsolation_test.cj:48-59`、`SignatureTableConcurrency_test.cj:112-147`），无 `spawn().get()` 串行化 |
| §6.4 低效算法 | 2 | `HostFieldTable.register` 每次全表重建（O(N²)，写入优化方案）；`indexOfText` 为测试内的 O(n·m) 子串查找（本可用 `String.contains/indexOf`，测试代码，仅记录） |
| §7 降堆内存方案 | 1 | `retained` + 重复访问器的生命周期对齐（无基线） |
| §8 降 CPU 方案 | 2 | 批量登记字段访问器（O(N²)→O(N)）；锁外计算 + 锁内短临界区 |
| §9 local mode 可行性 | 0 | 注册期产物（`ClassDescriptor`/访问器闭包/`TypeInfo`）按设计**必须**逃逸并长期存活（`retained` 就是为防 GC 回收），local region 会在函数返回时整块释放，语义直接冲突；用例内临时 `ArrayList` 峰值极小，无可证明收益，故不提案 |
| §11 现有代码的 BUG（存量） | 7 | 已核对：`mapType` 前缀（1）、继承字段执行层（2）、深度上限不一致（3）、父类成员无诊断（4）、`registerInterface` 静默（5）、保活表/访问器累积（6）、`T40Deopt` 全局配置泄漏（7）。`Q6Acceptance_test` 的 20 余处错误码断言已逐条对照 `ErrCode`，除注释外无误 |
| §12 并发安全与锁粒度 | 0 | 已列共享点与同步手段：`retained*` 三字段全部在 `retainedMtx` 内读写（`:66-93`）；`ClassRegistry` 每方法 `synchronized(this.mtx)`；`HostFieldTable` 用 `writeMtx` + `AtomicReference` 快照发布，`accepts` 在锁外求值（注释声明支持重入注册）；`Compiler.registerType/registerInterface` 整段持 `this.mtx`，锁序 `this.mtx → ClassRegistry.mtx → HostFieldTable.writeMtx` 与 `registerClass` 一致，未发现反向获取。用例内的共享可变状态（`Q6Acceptance_test.created`、`T40Deopt_test.boxId`、`SignatureTable.enabled`）已单列为测试隔离问题 |
| §14 功能完备性与 README 覆盖 | 0 | README/`doc/**` 不在本部分清单内，§13/§14 的文档对照留给含 `.md` 的部分；本部分只核对了 `Root.cj` 再导出清单与其注释声明（`JitContext`/`Engine`/`JitValue`/`CompileCache`/`AdapterRegistry`/`CompilePipeline` 确为 `protected`，未泄漏到用户面），一致 |
| 文件覆盖（§13 等） | 18/18 | 清单 18 个文件全部读完，无 `.md` 可对照 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

（本部分存量缺陷 14 条，是否纳入修复待用户决定。）

## 总评

本部分是「反射自动注册 + 用户面再导出」，除 `ReflectRegistrar.cj`（1003 行）与 `Root.cj`（46 行）外全是测试。产品代码的整体质量不错：注册是全量构建后再一次性登记（拒绝时不留半成品）、字段 `index` 让父类先占号、GAP-13 的引用型签名默认拒绝都有明确注释与用例锚点，`retained` 保活表也确实锁得对、`Compiler` 层用单个临界区保证了「类可见 ⇒ 函数可见」的 H5 不变量。

真正的风险集中在三处，都不阻塞发布但值得排期：
1. **typecode 判定的隐式约定**：`mapType` 用简单名前缀认容器，任何 `Range*`/`ArrayList*`/`HashMap*` 类名的宿主类会被静默判成句柄码，字段访问恒 99。这是「注册成功但永远用不了」的最难排查形态。
2. **继承字段的承诺与执行层不匹配**：`mergeAncestorFields` 让子类描述符包含父类字段，但纯反射访问器在子类实例上必抛 `IllegalTypeException` → 21；只有 `@JitBind` 才真能用。用例本身已经固化了这个限制（`reflectGetValueRejectsSubclassInstance`），说明是已知但未在注册期收口的问题。
3. **性能门禁放在单元测试里**：`PerfOverride_test` 的注释自带一次假失败记录，`rc` 被钳到 `1` 会让噪声直接变成红。对 CI 稳定性是长期消耗。

轻微项以「注册期诊断不对称」（父类成员跳过不报、父接口缺失不报、深度截断不报）和「测试自身不严谨」（死局部、恒真 `TCase.hit`、裸 helper id、全局静态配置不复原）为主——前者影响可诊断性，后者会让护栏名存实亡。`Skeleton_test.sixPackagesAreReachable` 是最典型的一个：注释说它在守包结构，实际断言的是一个本地数组长度。

`doc/perf-m2.md` 记录的端到端 1.1–1.6×（`call<T>` 固定开销 8–17 µs 吃掉 36× 差额）与本次读到的 `PerfOverride_test` 门禁口径一致，本部分不重复提性能结论；本部分给的 CPU/内存方案均标 `无基线（待验证）`，不进 `tasks.md`。
