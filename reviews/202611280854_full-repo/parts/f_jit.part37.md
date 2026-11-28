# f_jit 模块审查报告（第 37/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/runtime`（19 个 `.cj`）+ `f_jit/src/surface`（1 个 `.cj`）+ `f_jit/src/test`（1 个 `.cj`），本部分 20 个源文件
- **基线**：工作区快照（快照模式无 diff ⇒ 本部分所有问题来源记「存量」；`git blame` 抽样：`PromotionGroup.cj:117` 注释 2026-10-19 `bb87fa03`、`TextFormat.cj:363` 2026-10-17 `8d1b1900`）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、死代码、重复逻辑
- **报告版本**：v1（本部分分报告，由主 Agent 合并为 `f_jit_v2.md`）

## 发现

### [一般][存量] 提升组引用计数仅实例内有效，跨包装共享的闭包槽会被先关闭的一方提前释放

- **位置**：`f_jit/src/runtime/PromotionGroup.cj:37`（`refs` 是实例字段）、`:92-93`（计数归零即 `HandleTable.releaseEscaped`）、`:118-127`（`releaseAll` 逐条减到 0）；组创建点 `f_jit/src/CallMarshal.cj:261`（每次返回闭包新建一个组）；释放点 `f_jit/src/JitFunction.cj:331`（单个包装 `close` 只 `releaseAll` 自己那一组）
- **来源**：存量（`git blame`：`refs` 字段 2026-10-19 `bb87fa03`；组创建/关闭路径同批）
- **判据**：review-checklist §11（资源生命周期 / 契约与实现不符）+ §12.1（跨线程共享状态）
- **证据**：待确认 —— 代码层面确定：计数表是**每实例**的 `HashMap`，两个 `PromotionGroup` 各自对同一 `id` 计 1；任一实例 `releaseAll` 会走到 `releaseEscaped`（gen+1 释放槽）。缺的是「同一闭包槽被两个包装同时持有」的可达路径确认（需要一次 `callForFn` 两次返回同一 12 号捕获闭包，然后 `close()` 其中一个包装再调用另一个）
- **描述**：类注释（`:23-34`）称「重复 `add`（**多闭包共享捕获**）只提升一次、计数 +1」，但计数与清单都在实例内。若同一 `JitClosure` 槽（或同一句柄型捕获槽）被两个包装的组同时登记，先 `close()` 的包装会把计数降到 0 并 `releaseEscaped` 释放该槽；另一个包装的闭包仍持有同一个 `cell`，后续 `HandleTable.getAs(cell, CLOSURE)` 或捕获读取得 `NULL_HANDLE`/`HANDLE_TYPE`（表现为 `CALL_CONTRACT` 19），即「关掉一个包装，另一个包装的调用开始失败」。另：生产路径只有 `releaseAll`（`JitFunction.cj:280`、`:331`），单条 `release` 仅测试调用，因此注释承诺的「共享捕获计数保护」在生产路径上从未生效
- **建议**：二选一并在注释里写清语义——① 把清单/计数上移到单元级（`JitFunction.escaped` 维度，键 `id`，跨组共享），组只做「本次返回涉及的 id 集合」；② 保持实例内计数，但在 `releaseAll` 前判定该 `id` 是否仍被其他存活组登记（需要单元级引用表）。同时补一条「两包装共享同一捕获槽，先关一个再调另一个」的用例，把结论从「待确认」钉成「静态确定」

### [轻微][存量] `signatureToken` 的 9/12/13 分支在宿主闭包路径上不可达

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:99-112`（`case 9u16 / 12u16 / 13u16`）
- **来源**：存量
- **判据**：review-checklist §1（恒不可达分支 / 两套合法集口径）
- **证据**：静态确定 —— 进入 `cellToHostValue` 的两条路径都以 `SignatureDescriptor.validate()` 为前提：`HostCall.cj:53` 每次 `host_call_trampoline` 都校验，`CallMarshal.cj:177` 在注册期用 `verifyReflective` 校验（其首行 `Signature.cj:113` 同样 `validate()`）；而 `Signature.cj:80-83` 的 `isLegalCode` 只放行 `0–8/10/11/14/16–19`，9/12/13 必被拒 ⇒ 这三个 case 永不命中
- **描述**：`signatureToken` 与 `isLegalCode` 是两套合法集表述：前者覆盖 4–13，后者拒 9/12/13，形成「映射表支持、校验表禁止」的双口径。改动任一侧（例如后续放开 Regex 作宿主回调形参）时只改一处就会静默出现「注册通过、调用 99」
- **建议**：把 `signatureToken` 的合法域收敛到 `isLegalCode` 放行的集合（删 9/12/13，或改为显式注释「防御性保留，`validate` 已拒」并与之共用同一常量表）

### [轻微][存量] `pos1/pos2a/pos2b` 的 `case 14u16` 分支不可达

- **位置**：`f_jit/src/runtime/Signature.cj:241`、`:259`、`:277`（`case 14u16 => true`）；提前返回点在 `:202-205`
- **来源**：存量
- **判据**：review-checklist §1（被前面分支完全覆盖的 case）
- **证据**：静态确定 —— `paramMatches` 首句 `if (code == LocalType.HOST_OBJECT) { return true }`，14 号码永远到不了 `pos1/pos2a/pos2b`
- **描述**：三张逐位判定表里各留一个死 case；同时它掩盖了口径差异——参数位 14 是「无条件通过」，返回位 14 是 `value is () -> Object`（`ret0/ret1/ret2`），读代码的人容易以为两侧同源
- **建议**：删掉参数表里的 14 分支，或把「14 形参不校验具体类」的理由集中写在 `paramMatches` 一处

### [轻微][存量] `cellToHostValue` 注释写的失败码与实现不一致

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:74-76`（注释「这里 `CALL_CONTRACT`」）vs `:92`（实际 `failWith(ErrCode.HELPER_PANIC)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— `ErrCode.CALL_CONTRACT = 19`（`base/ErrCode.cj:69`），本函数未引用
- **描述**：注释承诺 `CALL_CONTRACT`，实现抛 `HELPER_PANIC`（99）。`hostSetField` 侧同为 99，因此「差异只在失败码」这句反而是错的（两侧码相同）。排障时按注释找 19 会扑空
- **建议**：注释改为「与 `hostSetField` 同码（99），差异只在调用方转码」，或确实需要 19 时改实现（但会改变 `host_call` 的错误码契约，需与对拍用例同步）

### [轻微][存量] `releaseAll` 注释「每个条目各减 1」与实现「减到 0」不符

- **位置**：`f_jit/src/runtime/PromotionGroup.cj:117`（注释）vs `:122-124`（`while (countOf(id) > 0) releaseLocked(id)`）
- **来源**：存量（注释 2026-10-19 `bb87fa03`，方法体 2026-11-26 `187f86c289` 改成循环减到 0，注释未同步）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定
- **描述**：实现是「释放整组、逐条清到 0」，不是「各减 1」。这个差别正是上一条（跨包装共享）判断的关键：若真按「各减 1」，计数 2 的槽在组死亡后仍留 1 份永久泄漏；按现在的实现则是「组死即全释」，对共享槽会提前释放。两种语义必须择一并写清
- **建议**：注释改成「组销毁 ⇒ 逐条释放到 0（不做跨组共享保护）」，并与 F1 的修法保持一致

### [轻微][存量] `verify()` 返回的新描述符丢弃 `paramNames/retName`

- **位置**：`f_jit/src/runtime/Signature.cj:187`（`SignatureDescriptor(declared.params, declared.ret)`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 该构造函数 `paramNames!`/`retName!` 默认空（`:50-51`），故 14 位置的类名被清空
- **描述**：函数注释（`:168`）写「通过 ⇒ 新描述符（由调用方写入句柄条目）」，但新描述符丢了类名；一旦调用方按注释把它写进条目，后续 14 位置就退化成「只比大类」，跨类误配重新变得可能
- **建议**：改为 `SignatureDescriptor(declared.params, declared.ret, paramNames: declared.paramNames, retName: declared.retName)`；若 `verify` 本就是测试专用（见下条），则在注释里明确「不用于写入条目」

### [轻微][存量] 两条验签口径松紧相反，且与「等价于一次 `is`」的注释不符

- **位置**：`f_jit/src/runtime/Signature.cj:92-97`（注释承诺等价）、`:154-166`（`componentMatches` 逆变位按码/名**精确**相等）、`:202-205`（`verify` 对 14 形参**无条件**放行）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §10 语言特性（函数类型逆变）
- **证据**：静态确定 —— 按 `(U1..Un)->S <: (T1..Tn)->R ⇔ ∀i. Ti <: Ui`，`(Object)->Int64`、`(JsonValue)->Int64` 都应是 `(ReflectUser)->Int64`、`(JsonObject)->Int64` 的合法实现；`componentMatches` 走 `TypeNames.codeOf(actualName) != code` 精确比对（`base/TypeNames.cj:28-58` 把 `Any/Object` 一律归 14），配了类名时还要求逐字相等 ⇒ 更宽的合法实现被拒
- **描述**：口径一（生产：`verifyReflective`，`CallMarshal.cj:177`）偏严：更宽形参（`Object`/`Any`/JSON 父类）声明的实参注册即被拒（err 19），但语义上合法；口径二（`verify`，仅测试调用）偏松：14 形参直接返回 true，`(String)->Int64` 也能通过 `(HostObject)->Int64` 的验签，错误被推迟到调用期变成 21。两条路径都自称「与一次 `is` 等价」，实际都不等价
- **建议**：把「14 位置必须精确类名」的理由写成显式策略（安全优先、拒绝父类型），并在 `verify` 的 14 分支改为可判定的检查（`value is (Object) -> Any` 之类）或直接标注 `verify` 为遗留仅供对拍；`componentMatches` 至少放行 `Any`/`Object`（逆变上界）

### [轻微][存量] `SignatureDescriptor` 声明「构造后不变」，但 `params` 暴露可变 `Array`

- **位置**：`f_jit/src/runtime/Signature.cj:30-36`（`public let params: Array<UInt16>`）、`:45`（`paramNames`）
- **来源**：存量
- **判据**：review-checklist §10（值/引用语义、封装）+ §11（契约与实现不符）
- **证据**：静态确定 —— `let` 只固定字段引用，`Array` 元素仍可被任何持有者改写；构造时的防御性拷贝（`:52-58`）只挡住「构造后外部改传入数组」
- **描述**：`SignatureTable.getOrBuild` 用 `sig.params` 现场比对形状（`SignaturePlan.cj:148`），`SignaturePlan` 自己另存 `clone()`；一旦有调用方改了描述符的 `params`，表的键与 `validate` 结果就与已建计划不一致（计划按旧形状建），命中错误计划后 `marshalArgs` 按旧转换器装配 ⇒ 值错误或 99
- **建议**：改成不可变视图：保留内部 `Array`，对外提供 `func param(i: Int64): UInt16` / `size` 访问器，或直接用 `Array` 的只读包装（`finalizer` 语境的 `readonly` 语义按语言能力选择）

### [轻微][存量] `pad4` 对负年份输出畸形串

- **位置**：`f_jit/src/runtime/TextFormat.cj:363-380`
- **来源**：存量（2026-10-17 `8d1b1900`）
- **判据**：review-checklist §11（边界 / 语义与注释不符）
- **证据**：待确认 —— 代码确定：`v < 1000` 分支按「非负数补零」写，`v = -5` 得 `'0' + "00" + "-5"` = `"000-5"`；缺的是 `DateTime.year` 是否允许负值（`doc/jit-bytecode-m1.md §11.9` 与 std `DateTime` 值域）
- **描述**：注释只说「仅值域两端折算后可发生」的 >9999 情形（走 `+` 分支），未处理负年份。若 `inLocal()` 折算后 year < 0，`dateTime()` 会产出 `000-5-03-...` 这类不可解析、不可往返的文本
- **建议**：负值走 ISO 8601 扩展：`'-' + abs(v)` 并按需补零到 4 位；补一条 `DateTime` 负年用例（或明确在注释里写「year 恒 ≥ 1，故不处理」）

### [轻微][存量] `Int64.Min` 期限哨兵被 `deadlineExpired` 当成「无期限」

- **位置**：`f_jit/src/runtime/RuntimeEnv.cj:71-81`（极端过去 ⇒ `Int64.Min`）vs `:89-95`（`deadlineNanos < 0` ⇒ 恒 false）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与实现不符）
- **证据**：静态确定 —— 两个函数对 `<0` 的解释相反：写侧说「已过期（极端过去）」，读侧说「无期限」
- **描述**：`CallContext.deadline` 落在纳秒可表示范围之外（约 1678 年之前）时，`deadlineNanosOf` 返回 `Int64.Min`（注释：退化为哨兵而不是抛异常），但 `deadlineExpired` 把它当「无期限」⇒ 本该「立刻中断」的调用变成**永不中断**（`interrupt_poll` 恒返回 0，死循环只能靠外部手段终止）。虽然只影响异常输入，但方向与注释相反
- **建议**：`deadlineExpired` 先判 `deadlineNanos == Int64.Min => true`；或写侧改用 `Int64.Min + 1` 之外的「已过期」表示（如统一用 `0` 表示 epoch 前即过期，`-1` 保留为无期限）

### [轻微][存量] `shortestDigits` 三元组的首分量恒 `false` 且无任何调用方读取

- **位置**：`f_jit/src/runtime/TextFormat.cj:69`（返回类型 `(Bool, String, Int64)`）、`:79`、`:100`、`:104`（三处均返回 `false`）；调用方 `:60`（`r[1], r[2]`）、`f_jit/src/runtime/Helpers.cj:402`（`r[2], r[1]`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死返回值）
- **证据**：静态确定 —— 全仓仅两处调用，均未取 `r[0]`
- **描述**：疑似早期用来区分「零值 / 负零」或「是否精确」的标记，现在恒 `false`，属残留契约；保留会让调用方误以为有第三态需要处理
- **建议**：返回类型收成 `(String, Int64)`（或命名 struct），或在注释里说明该位的保留用途

### [轻微][存量] `runtime/Runtime.cj` 是只有一行注释的空文件

- **位置**：`f_jit/src/runtime/Runtime.cj:18`
- **来源**：存量
- **判据**：review-checklist §3（空实现 / 占位残留）
- **证据**：静态确定 —— 全文 18 行，除许可证与 `package` 外无任何声明
- **描述**：`// P0 骨架占位：运行时——ctx/句柄表/helper 实现集/解释器（语义基准）（见 doc/plan-m1.md §0.4）`。真正的运行时已拆分到 `RuntimeEnv/RuntimeState/HandleTable/Helpers`，此文件只剩「看起来有个 Runtime 类」的误导作用
- **建议**：删除该文件（同包无引用），或改成 `doc/` 里的架构说明引用

### [轻微][存量] `SignatureTable.enabled` 是可写全局，读写不同步

- **位置**：`f_jit/src/runtime/SignaturePlan.cj:135`（`public static var enabled = true`）、`:142`（读）、`:198`（`resetForTest` 在锁外写）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态 / 可见性）
- **证据**：待确认 —— 代码确定读写无锁、无 `Atomic`；缺的是「宿主是否会在运行期切换该开关」（注释写「测试与宿主可关」）
- **描述**：`getOrBuild` 在任意调用线程读该字段；`resetForTest`（以及 `SpecializationFmt_test` 之类）在另一线程写。`Bool` 不会撕裂，但无 happens-before ⇒ 打开后可能长时间仍走冷路径（表现为「特化没生效」），且与「`buildCount` 只建一次」的断言类用例存在互扰
- **建议**：改为 `AtomicBool`（或 `static var` + 只允许在初始化期设置，测试用 `@Test` 串行约束），并在注释里写清「仅进程启动期可改」

### [轻微][存量] 冗余薄包装：同一能力两个入口

- **位置**：`f_jit/src/runtime/HandleTable.cj:1139`（`promote(id)` = `moveOutGroup([id])`，全仓零调用，注释自称「M2 提升组占位」）、`f_jit/src/runtime/Signature.cj:341-343`（`cached(entry)` = `entry.sig`，仅测试调用）、`f_jit/src/runtime/UserHelper.cj:88-90`（`push(base, entries)`「兼容入口」，仅测试调用）、`f_jit/src/runtime/RuntimeEnv.cj:56-63` 与 `:46-53`（`setDeadline`/`clearDeadline` 与 prop setter 重复）、`f_jit/src/runtime/RuntimeEnv.cj:120-126`（`setFnTableBase`/`reset` 与 prop setter 重复）
- **来源**：存量
- **判据**：review-checklist §2（同语义两个实现）
- **证据**：静态确定 —— 上述 `promote`/`cached`/`push` 的全仓调用点均为测试或零（`promote` 零调用、`cached` 仅 `Q6Acceptance_test`/`HostCallback_test`、`push` 仅测试）
- **描述**：均为「对外可达的 public」⇒ 按硬原则一不进死代码统计；但同一语义留两条入口会让「谁是权威路径」不明确（`setDeadline` 与 `deadlineNanos` setter 行为完全一致）。`HandleTable.promote` 更是零调用的占位 API，语义与 `moveOutGroup([id])` 完全重复
- **建议**：`promote` 删除或改为 `moveOutGroup` 的别名注释；`push`/`cached` 在注释里标注「测试辅助」并考虑收窄可见性（需用户确认无下游）；`setDeadline` 系列保留一个（prop setter 或函数入口）

### [轻微][存量] 三张 `LocalType → TypeToken` 映射表口径不一致

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:99-112`（`signatureToken`：4–13，无 16–19）、`f_jit/src/runtime/UserHelper.cj:165-183`（`userHelperToken`：4–13 + 16–19）、`f_jit/src/runtime/HostCall.cj:135-153`（`HostCall.mapToken`：4–11/14 + 16–19，**12/13 落 RESERVED**）
- **来源**：存量
- **判据**：review-checklist §2（同一张码表散落多处，差异未显式参数化）
- **证据**：静态确定 —— 4–11 三段逐行同值；差异只在 12/13 与 16–19 的取舍
- **描述**：三处各写一遍 `case 4u16 => STRING …`。差异本身有业务理由（宿主闭包路径禁高阶、JSON 只在 helper 与返回侧出现），但差异只体现在「漏了几个 case」，没有一句注释说明「为什么这里不映射」，任何一处补码都会造成三路行为漂移（例如给 `signatureToken` 补 16–19 会让 `cellToHostValue` 的默认分支与显式分支重复判断）
- **建议**：抽成一个 `LocalTypeTokenTable.of(code, allowHighOrder: Bool, allowJson: Bool)`（留在 `f_jit.runtime` 内部），三处传不同开关；或至少在三处各加一句「口径来源：`LocalType.isLegal` / `isConvertible`」

### [轻微][存量] `cellToHostValue` 与 `userHelperArg` 是同一套逐参转换的两份实现

- **位置**：`f_jit/src/runtime/ReflectiveCall.cj:77-96` vs `f_jit/src/runtime/UserHelper.cj:148-163`
- **来源**：存量
- **判据**：review-checklist §2（只差一个分支的近似重复）
- **证据**：静态确定 —— 0/1/2/3 分支逐行相同；14 都是 `fetchHostObject`；差异只有 13（helper 取 `fetchHostCallback(cell).fn`，宿主闭包路径不允许 13 形参）与 16–19 的写法（前者显式 `fetchHostObject`，后者走 token 表 → `fetchAny`）
- **描述**：两份实现已出现细节漂移：14/JSON 码在两处走的是不同校验（`fetchHostObject` 校验**槽 tag**，`fetchAny` 校验**对象运行时类**，见 `HandleTable.cj:810-828` 与 `:911-929`）。对 JSON 节点两者恰好都通过（`tokenOf(JsonValue)` 也返回 `HOST_OBJECT`），但错误码与失败条件不同（`NULL_HANDLE` vs `HANDLE_TYPE` 的判定顺序不同）
- **建议**：合并为 `cellToValue(code, cell, allowHostClosure: Bool)`；把「13 只在 helper 路径可用」做成参数而不是复制函数体

## 优化可行性方案

### [堆内存] 提升组每次 `add` 的 1 元数组 + 每次返回闭包的 `snapshot()` 数组

- **现状**：`PromotionGroup.addLocked` 每提升一个槽就新建 `Array<Int64>`（`PromotionGroup.cj:69` 的 `moveOutGroup([id])`）；返回逃逸闭包时 `CallMarshal.unboxClosure` 再取一份全量快照数组（`CallMarshal.cj:265` 的 `group.snapshot()`，长度 = 闭包捕获数）。按「N 个捕获的闭包每次返回」估算：N+1 个短命数组 + 一次全量拷贝，生命周期仅一次调用
- **方案**：给 `PromotionGroup` 加 `addAll(ids: Array<Int64>)`（一次 `moveOutGroup(ids)`）与 `forEachId(f: (Int64) -> Unit)`（免快照，锁内回调只做 `removeFrom` 这种 O(1) 动作，或改为返回持久索引）；`CallMarshal.promoteClosureGraph` 先收集 ids 再批量提升
- **预期**：每次返回少 N 次 `Array` 分配与 N 次全局 `HandleTable.mtx` 进出；快照数组归零。数量级是「每次闭包返回 N+1 个对象」，收益随捕获数线性增长（N 通常 1–8）
- **代价**：`addAll` 需要保证与逐条 `add` 相同的幂等语义（`ids` 内重复 id 只能计数一次，去重逻辑上移到调用方或 `moveOutGroup` 内部）；锁内回调要避免重入 `PromotionGroup`（`removeFrom` 只碰 `CallMarshal` 的本地列表，安全）
- **验证**：`cjpm bench` 跑「返回含 1/4/8 捕获的闭包 × 100k 次」，对照 `getAllocatedHeapSize()` 与本轮新增的分配计数；同时断言 `windowUsed`、`size()`、`contains()` 与旧路径一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TextFormat` 最短往返：`pow5/pow2` 逐次乘法 + 每轮重解析 `BigInt` 常量

- **现状**：`pow5(k)` / `pow2(k)` 用 `while` 循环逐次乘（`TextFormat.cj:243-261`），`k` 最大 1074（denormal）⇒ 单次格式化最多 1074 次「逐渐变大」的 BigInt 乘法；`roundToSignificant`（`:264-292`）每轮又 `BigInt.parse('10'/'2'/'1')` 4 次，外层 `while (p < ds.size)` 最多 17 轮。这是每次 Float64→文本化的固定开销路径（`Helpers.cj:449` 的 `to_str` 与 `:400-406` 的 `decFromF64` 都走它）
- **方案**：① `pow2/pow5` 改二进制幂并缓存 `5^1,5^2,5^4,…`（到 5^1024）为 `static let` 静态表，组合即可；② `roundToSignificant` 的 `ten/two/one` 提成 `static let`；③ 把 `bitsOf(exp, frac)` 提到循环外
- **预期**：单次 f64 文本化减少约 10^3 次 BigInt 乘法与约 70 次 `parse`；端到端收益取决于 f64→string 在负载中的占比（需 profile）
- **代价**：静态表常驻（约 11 个 BigInt，几 KB）；`pow5` 目前是纯函数，改造需保证任意 `k` 仍可取（组合式实现天然支持）
- **验证**：`cjpm bench -O2` 同机对照「10 万次 f64 文本化」中位数与离散度；`TextFormat` 已有 diff 对拍用例（`test/diff/RealRunners.cj:406`）保证逐字节不变
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 提升组 `add` 在锁内取全局 `HandleTable.mtx`（`moveOutGroup`），4 线程并发返回闭包时成为串行段 | `f_jit/src/runtime/PromotionGroup.cj:69`、`f_jit/src/runtime/HandleTable.cj:1107-1112` | 锁等待时长、实际并行度 | 4 线程各 10k 次「返回含 4 捕获的闭包」压测，采线程状态（BLOCKED/WAITING 占比）与吞吐；锁竞争在 CPU profile 里看不到 |
| 2 | `interrupt_poll` 每次轮询读两次 TLS（`deadlineNanos` getter 各一次） | `f_jit/src/runtime/RuntimeEnv.cj:89-95` | 每次 poll 的耗时与调用频次 | 在 `LOOP_BACK` 密集循环上跑 `cjpm bench`，对比「读一次到局部变量」的改后版本；同时给 TLS 访问次数埋点 |
| 3 | f64 文本化（BigInt 展开 + 逐位缩短）在「大量数值插值」负载里占比可观 | `f_jit/src/runtime/TextFormat.cj:69-105` | 自耗时占比 | `cjprof record` 跑 10 万次 `to_str(f64)`，取 `shortestDigits`/`roundToSignificant` 的 self time |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/runtime/PowHelper.cj` | .cj | ✅ | 快速幂与溢出判定正确；`exp<0`→14、溢出→3 与注释一致 |
| 2 | `src/runtime/PromotionGroup.cj` | .cj | ✅ | 见 F1/F5 与两条优化方案 |
| 3 | `src/runtime/PromotionGroupConcurrency_test.cj` | .cj | ✅ | 计数竞态用例；未覆盖「跨包装共享槽」 |
| 4 | `src/runtime/PromotionGroup_test.cj` | .cj | ✅ | 计数/常量/窗口迁出用例，与实现一致 |
| 5 | `src/runtime/ReflectiveCall.cj` | .cj | ✅ | 见 F2/F4/F16 |
| 6 | `src/runtime/Runtime.cj` | .cj | ✅ | 见 F12（空占位） |
| 7 | `src/runtime/RuntimeEnv.cj` | .cj | ✅ | 见 F10、F14；TLS 单载荷设计合理 |
| 8 | `src/runtime/RuntimeState.cj` | .cj | ✅ | 5 份 TLS 合并 + 32 条类型码缓存，字段均有使用方 |
| 9 | `src/runtime/Signature.cj` | .cj | ✅ | 见 F3/F6/F7/F8/F14 |
| 10 | `src/runtime/SignatureDescriptor_test.cj` | .cj | ✅ | 合法集/反射验签用例，与实现一致 |
| 11 | `src/runtime/SignaturePlan.cj` | .cj | ✅ | 见 F13；双检 + 不可变快照发布正确 |
| 12 | `src/runtime/SignaturePlan_test.cj` | .cj | ✅ | 双路径对拍与上界用例，覆盖 argc 0–5 与 255 |
| 13 | `src/runtime/SignatureVerifier_test.cj` | .cj | ✅ | 覆盖 0/1/2 元与 14；未覆盖比声明更宽的形参 |
| 14 | `src/runtime/T40Account_test.cj` | .cj | ✅ | 窗口记账/跨线程只读盒用例，断言与实现一致 |
| 15 | `src/runtime/TextFormat.cj` | .cj | ✅ | 见 F9/F11 与 CPU 优化方案 |
| 16 | `src/runtime/ThreadLocalEnv_test.cj` | .cj | ✅ | 三项线程私有验收，断言可红可绿 |
| 17 | `src/runtime/UserHelper.cj` | .cj | ✅ | 见 F14/F16；helper 栈线程私有、弹出由 `finally` 保证 |
| 18 | `src/runtime/WindowIsolation_test.cj` | .cj | ✅ | 两线程窗口隔离 + 复用不误杀用例；忙等仅测试内使用 |
| 19 | `src/surface/FacadeSurface_test.cj` | .cj | ✅ | 只经根包导入完成注册，与再导出面对齐 |
| 20 | `src/test/ReflectFixtures.cj` | .cj | ✅ | 反射夹具；`static var`/`Int32`/`Any` 用于「跳过 + 诊断」 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | F1（生命周期）、F7（函数类型逆变口径）、F8（`let` 数组可变）、F10（哨兵语义反向）；无外部输入解析，无注入面 |
| §1 死代码 | 3 | F2、F3、F11。已逐个 `private`/`internal` 符号全仓搜引用（`powMulChecked`/`addLocked`/`releaseLocked`/`countOf`/`dropId`/`signatureToken`/`probeType`/`componentMatches`/`arityMatches`/`paramMatches`/`returnMatches`/`pos1`/`pos2a`/`pos2b`/`ret0-2`/`shortestDigits`/`plainOf`/`plainOrSci`/`signedExp`/`bitsOf`/`intToStr`/`pow2`/`pow5`/`roundToSignificant`/`userHelperArg`/`userHelperToken`/`reflectiveInvoke*`/`convertArgs`/`cellToHostValue`/`buildTable`/`stack` 均有调用者）；`internal` 字段 `wins/freeWins/iters/faults/freeHint/typeCodes` 均有使用方；对外可达的 `public`（`PromotionGroup.contains/size/release`、`SignatureVerifier.cached/verify`、`HostCallback.init(fn)`、`UserHelperTable.push`、`TextFormat.pad2/pad4/pad9/offsetText`、`SignatureTable.buildCount/entryCount`）仓内仅测试或零引用，按硬原则一**不判死代码**，已在 F14 记为冗余入口/可见性建议 |
| §2 重复逻辑 | 3 | F14（薄包装双入口）、F15（三张码表）、F16（逐参转换两份）。已把本部分 60+ 个函数体压成「输入→输出→副作用」两两比对：`pos*/ret*` 六张表的重复是语言所限（`is` 需静态类型）不判；`add/addLocked`、`release/releaseLocked` 是锁壳惯用法不判 |
| §3 空实现 | 1 | F12（`Runtime.cj` 全文只有注释）。其余无空函数体、无 `TODO`、无 `catch {}`（`ipow` 的 `catch` 有明确转码） |
| §4 栈溢出 | 0 | 本部分无递归函数；`ipow` 是迭代快速幂（O(log exp)）。递归风险在 `CallMarshal.promoteClosureGraph`（范围外，见总评） |
| §5 OOM | 0 | `convertArgs`/`marshalArgs` 按 `sig.params.size` 分配，该值来自注册期（宿主可信），且 `SignatureTable` 有 128 条上限；`typeCodes` 上限 32；helper 栈由 `finally` 成对弹出。未发现按不可信长度预分配或无界容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据；F2 相关的 f64/提升组开销已列入「待验证假设」1–3 与优化方案，不作为缺陷 |
| §6.2 大粒度锁 | 0 | 提升组锁内只做清单/HashMap 操作，但会取全局 `HandleTable.mtx`；无持有时长数据，按规则记为假设 #1 而非缺陷 |
| §6.3 并发串行 | 0 | `PromotionGroupConcurrency_test` 用 4 线程真并发释放，无 `spawn` 后立即 `get()` 的形态（测试里统一汇合属正常用法） |
| §6.4 低效算法 | 0 | `pow5` 逐次乘法、`getOrBuild` 线性扫（≤128）、`dropId`/`contains` 线性（组小）均为线索；缺复杂度占比数据，只写进优化方案（TextFormat）与假设 |
| §7 降堆内存方案 | 1 | 提升组 1 元数组 + snapshot 数组（无基线） |
| §8 降 CPU 方案 | 1 | `TextFormat` BigInt 展开与常量重解析（无基线） |
| §9 local mode 可行性 | 0 | 临时对象是 std `BigInt` 与 `ArrayList<Rune>`，std 无对应 mode 重载；且收益只能靠峰值内存对照，当前无数据 |
| §11 现有代码的 BUG（存量） | 7 | F4、F5、F6、F7、F8、F9、F10（含 2 条待确认：负年份值域、`enabled` 运行期切换） |
| §12 并发安全与锁粒度 | 1 | F13（`enabled` 无同步）。`PromotionGroup` 锁序 `group.mtx → HandleTable` 单向，无反向回调；`RuntimeState` 全部字段线程私有，`ThreadLocal` 懒建在同线程内无竞态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md` 文件，无配置项/README 契约；`Runtime.cj` 的「承诺未实现」已按 §3 记 F12 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完（0 个 `.md`，§13 文档一致性在本部分无适用对象） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 15 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分的代码质量整体良好：TLS 单载荷化（`RuntimeState`）、`SignatureTable` 的不可变快照 + 双检发布、`ipow` 的迭代快速幂与逐次溢出判定、`TextFormat` 把「最短往返」自己实现而拒绝依赖平台 `printf`，都是有明确设计取舍且注释到位的实现；测试覆盖也扎实（双路径逐位对拍、4 线程计数竞态、窗口隔离、线程私有环境）。

主要风险集中在**句柄生命周期**与**码表双口径**两处：

1. 唯一的一般项（F1）是提升组引用计数的作用域问题——计数在实例内、生产路径只有「整组释放」，注释承诺的「共享捕获保护」实际上不存在。后果是跨包装共享的闭包槽可能被先关闭的一方释放，属数据/契约级问题，但需要一条「两包装共享同一捕获槽」的用例才能从「待确认」落成「静态确定」，建议优先补这个用例而不是先改实现。
2. 码表口径分散（F2/F3/F15/F16）：`isLegalCode`、`signatureToken`、`userHelperToken`、`HostCall.mapToken` 四张表各自表述同一套 `LocalType → token` 关系，已经出现「映射支持但校验禁止」的死分支与两处不同的 14/JSON 取值校验。这类漂移不会立刻报错，但会随着后续放开 Regex/JSON 变成难查的 19/99。
3. 存量轻微项多为注释与实现脱节（F4/F5/F6/F7），其中 F5 的「各减 1 vs 减到 0」与 F1 是同一根因的两面，改注释时必须与 F1 的结论一起定。

存量缺陷共 16 条（1 一般 + 15 轻微），按规则只报不修，是否纳入修复清单待用户决定；两条优化方案均无改前基线，不进 `tasks.md`。

范围外提示（不占用本部分统计）：`f_jit/src/CallMarshal.cj:288-309` 的 `promoteClosureGraph` 递归深度由闭包嵌套层数决定，仅有 `visited` 防环、无深度上限，深层嵌套闭包存在栈溢出面；另 `HostCall.cj:251` 用 `HashMap.add` 覆盖同一 `ctx` 地址的旧异常记录，若某条失败路径没走 `takeCause` 而 `ctx` 地址恰好被复用，旧 cause 会在新调用里被读到。
