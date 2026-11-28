# f_jit 模块审查报告（第 32/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/compiler/Lowerer.cj`（本部分 1 个源文件，3923 行）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 本部分所有问题来源均为**存量**
- **审查重点**：动态调用 / 桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

## 发现

### [严重][存量] 无初始化的局部声明发射 `STOREL` 但求值栈上没有任何值

- **位置**：`f_jit/src/compiler/Lowerer.cj:406-411`（`initE == None` 分支只做类型检查）+ `:444-445`（无条件 `allocSlot` + `emitU16(Op.STOREL, …)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺省路径未处理 / 崩溃）；§3（分支缺实现）
- **证据**：静态确定 —— `Parser.cj:499-510` 允许 `let/var x: T` 不带 `=`（只要求带类型注解）；`DefiniteAssignment.cj:98-100` 明确支持并登记为「声明 ≠ 赋值」；`SourceCompiler.cj:117-129` 管线为 Parser → DefiniteAssignment → Lowerer → Assembler，中间**没有**补默认值的 pass。`initE == None` 时 Lowerer 既不 `PUSH_*` 也不写默认 cell，直接 `STOREL`。
- **描述**：`var x: Int64`（合法语法）降低为「空栈 + `STOREL slot`」。`Ops.cj:364` 声明 `STOREL` 的栈效应是 `(1, 0)`，但 `Assembler.cj:255-272` 对下溢只做 `depth = push` 的钳位（注释写明"分支造成的偏差不在此拒绝"），不会拒绝该函数；于是字节码进入运行期：`Interp.cj:310` 为 `f.locals[i] = f.pop()`，而 `f.pop()` 是 `stack.remove(at: size - 1)`（`Interp.cj:51-53`），空栈时下标为 -1；原生后端对应 `pop qword [rbp-32-8idx]`（`BackendSelector.cj:345`）读到栈外。后果是该单元第一条无初始化声明即崩溃，或把栈外脏值写进槽位，后续读取静默出错。
- **建议**：`initE == None` 分支按 `declared` 发射类型零值（`PUSH_I64 0` / `PUSH_F64` / `PUSH_BOOL 0` / `PUSH_NULL` 句柄 0），与 §11.7「值型槽存原始 cell、句柄型 0=null」一致；或在 Parser/前置校验直接拒绝此类声明（二选一，必须与 DefiniteAssignment 的口径统一）。同时给 Assembler 增加**严格**栈下溢拒绝（仅对非分支汇合点），避免同类问题再被钳位掩盖。

### [一般][存量] `& | ^ << >> ~` 没有类型校验，对 Float64 / Decimal / String / 句柄型直接发整型指令

- **位置**：`f_jit/src/compiler/Lowerer.cj:1426-1452`（`Amp` / `Pipe` / `Caret` / `Shl` / `Shr`）、`:1741-1743`（`Tilde`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与类型不符，静默产出错值）；§10 语言特性（类型分派不全）
- **证据**：静态确定 —— `promote`（`:1458-1475`）只在 `lt == rt` 时原样返回，因此 `1.5 & 2.5` 得到 `t == F64`、`"a" & "b"` 得到 `t == STRING`、`d1 & d2`（Decimal）得到 `DECIMAL`；随后 `Amp` 分支只有 `t == BOOL ? AND_B : BAND_I`（`:1426-1432`），`Shl`/`Shr` 完全无条件发 `SHL_I`/`SHR_I`（`:1447-1452`），`Tilde` 无条件 `BNOT_I`（`:1741-1743`）。
- **描述**：`F64`/`Decimal`/`String`/`DateTime`/`List` 等槽内是位模式或句柄 id，按整型做位运算后**类型码不变**：值型得到无意义的浮点/十进制位模式；句柄型得到越界或指向其它对象的句柄 id，后续 `STR_*`/`DEC_*` helper 按该 id 取句柄。编译期不报错，运行期静默错值或抛无关错误码。对照 `rejectStringArithmetic`（`:1289-1316`）只覆盖 `- * / %`，`rejectAnyOperand`（`:1275-1280`）只覆盖 15 型，二者都拦不住这条路径。
- **建议**：在 `lowerBinary` 的 `Amp|Pipe|Caret|Shl|Shr` 与 `lowerUnary` 的 `Tilde` 前置校验：`& | ^` 只允许 `(I64,I64)` 与 `(Bool,Bool)`（后者已实现），`<< >> ~` 只允许 `I64`；其余走 `diagFail(TYPE_MISMATCH)`。校验放在 `lowerExpr(l)`/`lowerExpr(r)` **之前**用 `staticTypeFull` 判定，避免先发指令再报错。

### [一般][存量] `if` 表达式用单一 `last*` 旁路传类型知识，多分支时取最后一支

- **位置**：`f_jit/src/compiler/Lowerer.cj:1013-1016`（每次 `lowerExpr` 入口重置 `lastObjectName` / `lastHostRet`）、`:1027-1041`（`IfExpr` 依次降低两分支后直接返回 `t1`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（类型跟踪与实际不符）；§10 设计合理性（隐式单槽旁路）
- **证据**：静态确定 —— `let v = if (c) { a } else { b }`：两分支类型都为 `CLOSURE`（`t1 == t2` 校验通过）或都为 `HOST_OBJECT`，但 `lastClosureFnId`（`:156`）/`lastObjectName`（`:152`）只保留**后降低的那一支**（`else`），`Decl` 分支 `:403-405`、`:412-423` 用它写 `VarSym`。
- **描述**：`let f = if (c) { { => 1 } } else { { => "s" } }` 之后 `f(0)` 的静态返回类型取 else 分支的签名（String），而运行期可能走 then 分支返回 Int64；`let u = if (c) { user } else { addr }` 之后 `u.field` 按 `addr` 的字段表解析，命中即静默取错字段索引，未命中则误报「未注册字段」。`lastHostRet` 同理（13 型两个不同签名的宿主闭包）。这是「靠 `lowerExpr` 副作用回传」这一设计的必然缺陷，不是个别分支漏写。
- **建议**：把类型知识改为**返回值**（例如 `Lowered(evalType, objectName, hostRet, closureFnId)` 结构随 `lowerExpr` 一起返回），或在 `IfExpr`/分支结构里显式做「同类名取公共类、不同类名降级为 None」的合并；最省事的临时修法是 `IfExpr` 出口把 `lastObjectName` / `lastHostRet` / `lastClosureFnId` 全部清空（宁可丢知识也不要错知识）。

### [一般][存量] `lowerHostMethodCall` 把 HostObject 返回值一律记成**接收者类**，与 `hostObjectClassOf` 的 `retName` 口径矛盾

- **位置**：`f_jit/src/compiler/Lowerer.cj:2240-2245`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 类型混淆）；§2（同一语义两套口径）
- **证据**：静态确定 —— 同文件 `hostObjectClassOf(MethodCall)` 已按注册期 `m.bind.retName` 取类名，并在注释里明确「旧实现返回**接收者**的类名……那是猜的，会让 `u.getAddr() as User` 通过静态检查（类型混淆）」（`:2298-2314`）；但 `lowerHostMethodCall` 仍写 `this.lastObjectName = if (m.bind.retType == HOST_OBJECT) { Some(className) } else { None }`。
- **描述**：`let v = u.getAddr()` 经 `Decl` 分支把 `v` 的 `objectName` 记成 `u` 的类。之后 `v.street` 走 `hostObjectClassOf(Var)` → `sym.objectName` → 用**错的类**查字段表：字段名恰好在两个类里都有时静默读错索引（数据错误），否则误报「未注册字段」（合法代码编译不过）。`retName` 为空（注册期未记返回类）时同样硬安接收者类，比「不知道」更危险。
- **建议**：与 `hostObjectClassOf` 对齐——`m.bind.retType == HOST_OBJECT && m.bind.retName != ''` 才写 `Some(m.bind.retName)`，否则 `None`（并让 `VarSym.objectName` 为 `None` 时下游按「类名未知」保守处理）。

### [一般][存量] 自递归/尾递归调用不校验实参个数，尾递归路径静默写错槽位

- **位置**：`f_jit/src/compiler/Lowerer.cj:805-842`（`tryLowerTailRecursive`，判据只有 `:812-814` 的 `args.size + base > slotCount()`）、`:2511-2520` / `:2569-2572`（非尾路径 `callFunc(entryFn, args.size)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界校验，静默破坏状态）；§4（递归）
- **证据**：静态确定 —— `DefiniteAssignment.cj:286` 对 `RecursiveValue` 不做任何检查，`Parser.cj:1170` 只产出节点；Lowerer 中 `topParamTypes` / `closureParamsOf(fnId)` 已有真实形参个数可用，但两条路径都没比对。
- **描述**：`func f(a, b) { … f(x) }` 尾位置：`args.size=1`、`base=0`，只写 slot0，`b` 保留上一轮旧值，`LOOP_BACK` 后语义错乱且无任何诊断；多传时 `STOREL (i+base)` 覆盖到非形参槽（循环计数器、临时槽），破坏同帧状态。非尾位置则由 `Assembler.cj:228-231` 的 `codeFail('CALL_FUNC argc 不符…')` 兜住——那是**内部错误**文案，用户看到的是 codeFail 而不是源位置诊断。
- **建议**：`tryLowerTailRecursive` 与 `lowerCall` 的 `RecursiveValue` 分支共用一处 `requireArity(expected, args.size, pos)`：`expected = ctx.isClosure ? closureParamsOf(ctx.fnId).size : topParamTypes.size`，不等即 `diagFail(SYNTAX_ERROR, '自调用实参个数不符: 需要 n，实际 m')`；`slotCount` 启发式可随之删除。

### [一般][存量] `for-in` 对非 Range/Map/String/List 的可迭代表达式不报错，按 List 发 `LEN`/`GET_IDX`

- **位置**：`f_jit/src/compiler/Lowerer.cj:744-786`（`else` 分支：`isStr = itTy == STRING`，其余一律当 `LIST`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界/类型校验 → 运行期崩溃或脏值）
- **证据**：静态确定 —— 该分支只区分 `isStr`，`hSlot` 类型写死为 `LIST`（`:750`），随后无条件 `Op.LEN`（`:755`）与 `Op.GET_IDX`（`:774`）；`itTy` 为 `F64`/`BOOL`/`DATETIME`/`HOST_OBJECT`/`NONE` 时不进入任何 `diagFail`。
- **描述**：`for (x in 3)`、`for (x in someHostObj)` 编译通过，运行期对非容器句柄/位模式执行 `LEN` → 句柄越界或返回无意义长度，再按该长度循环 `GET_IDX`。用户拿到的是运行期错误码而不是源位置诊断，且 `NONE`（类型推不出）时会静默按 List 走。
- **建议**：在分支入口加白名单校验：`itTy ∈ {LIST, STRING}` 才走该分支，`NONE` 给出「无法推导可迭代表达式类型」的 `diagFail`，其余类型明确报「不支持 for-in 的类型：`${LocalType.name(itTy)}`」。`containerInfoOf` 对 `Index`/成员链返回 `NONE`，因此 `NONE` 分支必须报错而不是降级。

### [一般][存量] `parseInt64` 的上界检查把 `Int64.Min` 判成越界

- **位置**：`f_jit/src/compiler/Lowerer.cj:3904`（`if (v > 922337203685477580 || (v == 922337203685477580 && d > 7))`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一）
- **证据**：静态确定 —— 逐位累加不区分符号，`-9223372036854775808` 的数值部分正好是 `9223372036854775808`，`v == 922337203685477580 && d == 8` 命中 `d > 7` ⇒ 返回 `None`。
- **描述**：`-9223372036854775808` 是合法 `Int64`，但 `parseInt64` 返回 `None`，`lowerLiteral`（`:1222-1231`）与 `constIndexOf`（`:3168-3173`）都退化为 Decimal 常量。于是 `let x: Int64 = -9223372036854775808` 报类型不匹配，整数边界值只能写 `Int64.Min` 之外的等价形式；同一字面量在常量表里与在表达式中形态还可能不同（Decimal vs I64）。
- **建议**：负数分支允许 `v == 922337203685477580 && d == 8`（`neg` 为真时），即按有符号范围判定；或在解析前特判 `-9223372036854775808` 字面量返回 `Some(Int64.Min)`。

### [轻微][存量] `ALLOW_ESCAPING_HANDLES` 恒 `true`，逃逸闭包校验块是恒假分支

- **位置**：`f_jit/src/compiler/Lowerer.cj:162`（`private static const … : Bool = true`）、`:3248-3256`（`if (desc.escaping && !ALLOW_ESCAPING_HANDLES) { … invalidEntries() … }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒假分支 / 死配置）
- **证据**：静态确定 —— 常量 `true` ⇒ `!true == false`，块内 `diagFail` 永不可达；`CaptureDescriptor.invalidEntries()`（`Capture.cj:89`）全仓仅此一处调用。
- **描述**：m2 §14.7 的「逃逸闭包不得捕获句柄型」目前在降低期**完全没有校验**，只留下一个看起来在把关的 `if`。与第 30 部分对 `Capture.cj` 的结论同源（`invalidEntries` / `isInvalidIfEscapes` 死代码）。
- **建议**：要么把开关改为可配置（构造参数 / 编译选项）并保留校验，要么整块删除并把「不校验逃逸捕获」写进注释与 README 的限制段；不要保留恒假分支。

### [轻微][存量] `fnRetType` 无任何调用者

- **位置**：`f_jit/src/compiler/Lowerer.cj:312-317`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`private` 方法全仓搜引用仅定义处）
- **证据**：静态确定 —— 全仓 `fnRetType` 仅 `:312` 一处（`captureDescriptors` :308、`closureRetType` :319 是另两个不同符号，均有调用）。
- **描述**：死方法，且其语义（`parent == None ? topRetType : closureRetType(fnId)`）与 `lowerLambda` 收尾处的实际登记逻辑（`:285-290` 按实际产物覆盖）已不一致，留着会误导后续维护者。
- **建议**：删除。

### [轻微][存量] `AstExpr.MemberName` 全仓无构造点，Lowerer 里 8 处分支不可达

- **位置**：`f_jit/src/compiler/Lowerer.cj:578`、`:1132`、`:2265`、`:2329`、`:2584`、`:3369`、`:3492`、`:3801`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（不可达分支 / 兼容残留）
- **证据**：静态确定 —— 全仓 `MemberName(` 只有 `Ast.cj:245` 的定义；`Parser.cj:1034` 点号一律产出 `FieldGet`，`Parser.cj:1014-1015` 再由 `FieldGet` 产出 `MethodCall`；其余命中全是模式匹配（`AstShape.cj:106`、`DefiniteAssignment.cj:293/424`、`Parser.cj:607`）。
- **描述**：AST 双形态（`FieldGet` / `MemberName`）只保留了 `FieldGet` 一形态，`MemberName` 的整套分派（字段读写、成员调用、类名跟踪、静态类型、捕获来源、自由变量扫描）都是死代码。维护风险在于两套分支已开始漂移：`hostObjectClassOf` 的 `Call(MemberName)` 分支（`:2329-2342`）仍返回**接收者类**，而 `MethodCall` 分支已改用 `retName`——若将来真的启用 `MemberName`，会立刻复现上面第 4 条的缺陷。
- **建议**：删除 `MemberName` 构造器及全部匹配分支（`FieldGet` 已覆盖同一语义），或在 Ast.cj 注释里写明「保留形态 + 未接线」，并把 `:2329-2342` 的 `Some(cls)` 先改成 `retName` 口径。

### [轻微][存量] `emitArith` 的 `STRING → STR_CAT` 分支不可达

- **位置**：`f_jit/src/compiler/Lowerer.cj:1649-1651`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒不成立分支）
- **证据**：静态确定 —— `emitArith` 的三个调用点：`Plus` 在 `t == STRING` 时已走独立拼接路径（`:1357-1367`，含 `SWAP` 与逐侧 `TO_STR`），只在非 String 时调 `emitArith`（`:1369-1370`）；`Minus`/`Star`/`Slash` 的 String 组合分别被 `rejectStringArithmetic`（`:1289-1316`）与 `STR_REPEAT` 分支（`:1377-1387`）截断；`Percent` 单独实现。
- **描述**：该分支本身也是错的（没有 `TO_STR`，栈序也不对），一旦将来被走到会静默拼出错误内容。留着等于埋雷。
- **建议**：删掉 `t == STRING` 分支，`emitArith` 尾部直接 `diagFail`（类型集合收窄为 I64/F64/Decimal）。

### [轻微][存量] 重复逻辑：`MemberName`/`FieldGet` 与「装箱列表/映射字面量」两组实现逐行重复

- **位置**：
  - `f_jit/src/compiler/Lowerer.cj:2265-2278` 与 `:2279-2292`（`hostObjectClassOf` 两分支逐行相同）
  - `f_jit/src/compiler/Lowerer.cj:3369-3383` 与 `:3384-3398`（`staticTypeFull` 两分支逐行相同）
  - `f_jit/src/compiler/Lowerer.cj:578-590` 与 `:591-603`（`lowerAssign` 的字段写分派，仅错误文案与 `name`/`field` 变量名不同）
  - `f_jit/src/compiler/Lowerer.cj:873-889` 与 `:3108-3119`（`lowerListLitBoxed` 与 `lowerListLit` 非 const 路径：`MAKE_LIST` → 落槽 → 逐元素 `LOADL/lower/LIST_APPEND/POP` → 回取）
  - `f_jit/src/compiler/Lowerer.cj:892-916` 与 `:3149-3159`（`lowerMapLitBoxed` 与 `lowerMapLit` 非 const 路径，同上）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流 / 只改类型名的重复）
- **证据**：静态确定 —— 逐行比对函数体的「输入-输出-副作用」后摘要一致；唯一差异是 `lowerListLitBoxed`/`lowerMapLitBoxed` 在元素位置调 `lowerBox` 而非 `lowerExpr`，`lowerAssign` 两分支的错误消息不同。
- **描述**：`MemberName`/`FieldGet` 的 4 组重复可随上一条（删 `MemberName`）一并消掉；列表/映射的 2 组重复会随「装箱插入点」规则演进漂移（例如 §3 再加一类装箱点时容易只改一处）。
- **建议**：列表/映射合成一个 `lowerListLit(elems, isEmpty, boxElems: Bool)` / `lowerMapLit(pairs, isEmpty, keyTy, valTy, box: Bool)`；`lowerAssign` 的字段写分支抽 `lowerFieldWrite(tg, field, rhs, pos, what: String)`，错误文案作为参数保留（文案差异是业务要求，不应抹平）。

### [轻微][存量] 闭包值调用在 `fnId` 未知时静默按 `I64`，与 IIFE 的「未登记即报错」口径不一致

- **位置**：`f_jit/src/compiler/Lowerer.cj:2548-2552`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（静默降级）；§2（同一语义两套口径）
- **证据**：静态确定 —— IIFE 在 `closureRetOf(fnId) == None` 时 `diagFail('IIFE 的闭包返回类型未登记…')`（`:1059-1065`），注释明确「报错而不是静默当 I64（A4/P1-5）」；而 `Var` 形态的闭包值在 `sym.closureFnId == UInt32.Max` 时直接返回 `LocalType.I64`，既不报错也不告警。
- **描述**：`let f = <某无法追踪 fnId 的闭包来源>; let s = f(1)` 之后 `s` 被当成 Int64——若闭包实际返回 String，后续 `.size`/`+` 按 Int64 分派，静默错值。
- **建议**：与 IIFE 对齐：`sym.closureFnId == UInt32.Max` 时 `diagFail(TYPE_MISMATCH, '闭包值的返回类型未登记（fnId 未知）——请显式标注或避免该形态')`；若确有必须有 I64 兜底的场景，在注释与 README 里写明调用面限制。

### [轻微][存量] `==` / `!=` 对 List / Map / JSON 节点落到 `EQ_H`（句柄相等）

- **位置**：`f_jit/src/compiler/Lowerer.cj:1681-1689`（`emitCompare` 的 `else` 分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与预期不符）；§10 契约
- **证据**：待确认 —— 代码路径静态确定（`t == LIST/MAP/JSON_*` 没有专门分支，落到 `EQ_H`/`NE_H`）；缺的是规格口径：`doc/design-m3` §11 只承诺 JSON 的 `is`/`as` 与访问糖，未见「节点相等」定义，因此无法判定这是有意（引用相等）还是漏实现（结构相等）。
- **描述**：`j1 == j2`（两个内容相同的 `JsonObject`）为 `false`，`l1 == l2` 亦为引用比较；对 HOST_OBJECT 引用相等是合理的，对 JSON/容器则与仓颉侧 `==` 的结构语义不符，用户极易误用。
- **建议**：先定规格：若只支持引用相等，在 §11 与 README 写明并在诊断里保持现状；若要结构相等，新增 helper 分支（`JSON_EQ` / `LIST_EQ`），并在 `emitCompare` 里按 `t` 分派。规格未定前不要动实现。

## 优化可行性方案

> 非缺陷。以下均**无改前基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [堆内存] `flushNames` 先全量复制 `pendingNames` 再排序

- **现状**：`pendingNames`（`:150`）按「每条声明/形参/for 绑定一条」增长，`flushNames`（`:186-211`）先逐条 `add` 到新 `ArrayList`，再在新表上做插入排序，最后逐条写入 `sess.names`。峰值同时持有两份 `(UInt32, Int64, String)` 元组 + 排序期的临时位移。
- **方案**：`pendingNames` 改为在 `add` 处二分插入（声明顺序天然接近有序，插入代价接近 O(1) 摊还），`flushNames` 直接遍历写 `sess.names`，去掉副本。
- **预期**：元组数组峰值减半；排序比较次数从最坏 O(n²) 降到 O(n log n)（n = 本单元声明数）。
- **代价**：`FnCtx.declare` 与 `lowerForIn` 等 6 个 `add` 点改为走统一的 `addName(fnId, slot, name)`；插入排序换成二分需要多一次比较函数。
- **验证**：单测覆盖「形参 + 循环内声明 + 嵌套闭包」三类混排（校验 `(fnId, slot)` 严格升序不变）+ 大单元（≥5k 声明）下 `getAllocatedHeapSize()` 与编译耗时中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 名字查找与静态类型推算的重复线性扫描

- **现状**：`FnCtx.find`（`:116-127`）每次按名查找都从最内层作用域线性扫描；`FnCtx.declare`（`:105-114`）对同层每次声明做一次线性查重；`staticTypeFull` / `hostObjectClassOf` / `containerInfoOf` 对同一子表达式会重复递归（`lowerAssign` 里 `containerInfoOf(target)` + `staticTypeFull(index)` + 再 `lowerExpr(target)` 各算一遍）。
- **方案**：`FnCtx` 维护 `HashMap<String, VarSym>` 栈（与 `scopes` 同步 push/pop），`find`/`declare` 降为 O(1)；`lowerExpr` 返回结构化结果，让调用方复用已算出的静态类型（与上面「`last*` 旁路改造」是同一处改动）。
- **预期**：与声明数 n、表达式数 m 相关的作用域扫描从 O(n·m) 降到 O(m)；深嵌套闭包（每层 `outerNames` 全量扁平化，`:3229-3234`）受益更明显。
- **代价**：`VarSym` 的可见性语义要保留「同层查重 + 遮蔽」两件事；`HashMap` 每次 push/pop 需要 1 次分配，可用 `Array<HashMap>` 复用。
- **验证**：`cjpm bench -O2` 同输入（生成的 10k 行 DSL 源，含 200 个嵌套闭包）对照编译耗时中位数与 P95；`cjprof record` 看 `FnCtx.find` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `flushNames` 的复制 + 插入排序在大单元上是编译耗时热点 | `Lowerer.cj:186-211` | 该函数自耗时占比、n（声明数）分布 | 生成 5k/20k 声明源，`cjprof record` 后看 `flushNames` self time；同时统计 `pendingNames.size` |
| 2 | 深嵌套表达式（≥1k 层括号/成员链）会让 `scanExpr` / `staticTypeFull` / `hostObjectClassOf` 递归爆栈 | `Lowerer.cj:3355-3446`、`:3646-3820` | 触发深度与栈大小 | 用脚本生成 `((((1))))` 与 `a.b.c.…` 两种深链各 500/2000/5000 层，跑 `SourceCompiler.compile` 记录首次崩溃深度；同时确认 `Parser` 的崩溃深度（决定上限归属） |
| 3 | `lowerExpr` 每个节点都重置 `last*` 三字段，深层链上反复覆盖有可观开销 | `Lowerer.cj:1013-1016` | 该赋值的自耗时 | `cjprof` 跑 10k 表达式单元，看 `lowerExpr` 头部占比（预计 < 1%，若成立则不做） |
| 4 | 常量/键去重路径（`consts.addStr` 在每次 JSON 点号读写都调用）存在重复登记 | `Lowerer.cj:1913`、`:1977` | `ConstRegistry` 条目数 vs 源内唯一字面量数 | 编译一个含 500 次 `j.k` 的单元，dump 常量表统计重复项 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jit.part32.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/compiler/Lowerer.cj` | .cj | ✅ | 3923 行全量读完；缺陷见 #1–#12，优化方案 2 条 |

合计：`.cj` 1 个 / `.md` 0 个 / 共 1 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1–#6；设计 #3（`last*` 单槽旁路）、#4（类名口径两套）。安全性：无外部输入拼接、无凭据、无注入面（编译器只消费 DSL 源码） |
| §1 死代码 | 4 | `fnRetType` 无引用（#9）；`ALLOW_ESCAPING_HANDLES` 恒真使 #8 块不可达；`AstExpr.MemberName` 无构造点致 8 处分支不可达（#10）；`emitArith` 的 STRING 分支不可达（#11）。已逐个 private 符号全仓搜引用、逐条 `return/throw` 后语句检查；`internal`（`toStrTag`）有同文件调用者；`Lowerer`/`VarSym`/`FnCtx` 为 `internal` 类型，其 `public` 成员均有仓内使用（`captureDescriptors` 见 `SourceCompiler.cj:149`），不判 |
| §2 重复逻辑 | 1 | 合并为 #12，列出 5 组逐行/近逐行重复；函数体两两比对覆盖 `lowerExpr` 全部分支与 45 个 private 方法 |
| §3 空实现 | 1 | #1 的 `initE == None` 分支只校验不产码，等价于「声明无实现」。其余无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`ResolvedCall.HostClosureCall → notImplFail`（`:2580-2581`）是显式未实现错误而非静默空实现 |
| §4 栈溢出 | 0 | 递归仅出现在 AST 遍历（`scanExpr`/`scanStmt`/`originOfExpr`/`staticTypeFull`/`hostObjectClassOf`），深度 = 源嵌套深度，`Parser` 先递归同一结构、Lowerer 不放大；无自引用数据结构、无每帧大对象；尾递归已改回边（`:805-842`）。深嵌套上限未实测，列入待验证假设 #2 |
| §5 OOM | 0 | 所有容器按本单元声明/表达式数增长（`pendingNames`/`closureRets`/`closureParams`/`captureDescs`），无按报文长度预分配、无全局只增不减集合；`constIndexOf` 的常量登记由 `ConstRegistry` 去重。量级评估见优化方案 1（堆内存） |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据，未成立热点；候选写入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | 全文件无锁、无 `synchronized`、无 `Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池 |
| §6.4 低效算法 | 0 | 已定位两处复杂度问题（`flushNames` 插入排序、作用域线性查找），但无输入规模/耗时数据，按铁律只进优化方案 1/2 与待验证假设，不计发现 |
| §7 降堆内存方案 | 1 | 优化方案 1（`flushNames` 副本 + 排序）。`clear()`/`gc()` 假象不适用（无 `clear` 调用） |
| §8 降 CPU 方案 | 1 | 优化方案 2（作用域 `HashMap` + 复用静态类型结果） |
| §9 local mode 可行性 | 0 | Lowerer 是编译期单线程前端，收益口径是编译期峰值内存，`docs/LocalMode*.md` 的基线针对运行期；无前后峰值对照 ⇒ 按 §9 只能判「不评估」，不写成建议 |
| §11 现有代码的 BUG（存量） | 7 | 即 #1–#7；另逐条核对了 `lowerStmt`/`lowerExpr` 全部 30+ 分支的边界（空集合、`None`、越界索引、算术除零）与句柄/常量登记生命周期（`allocCtorHelper` 按 `(className, ctorIndex)` 去重，`CompileSession.cj:190-202`） |
| §12 并发安全与锁粒度 | 0 | `Lowerer` 由 `SourceCompiler.compile` 每次新建（`SourceCompiler.cj:127`），`ctx`/`last*` 是可变的实例状态但**线程封闭**；`sess.consts`/`sess.names` 亦随会话新建。无线程共享路径，无锁可谈 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分只含 `.cj`，README 覆盖由其他部分负责；代码内承诺与实现的一致性已查（`ResolvedCall.HostClosureCall` 是显式 Q3.5 未接入，实现与注释一致） |
| 文件覆盖（§13 等） | 1/1 | 清单 1 个文件全部读完，无缺项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

`Lowerer.cj` 是整个 JIT 前端的核心（AST → 字节码，3923 行、100+ 方法），类型分派密度极高。本部分的**阻塞项只有一条**：无初始化声明（`var x: T`）直接发 `STOREL` 而没有压值，这是合法语法 + 明确的上游支持（Parser 与 DefiniteAssignment 都放行）+ 宽松的汇编期栈校验三者叠加出的崩溃路径，属于必修。

次一级是四条「静态类型跟踪不闭合」的问题（位运算缺类型门、`if` 分支只留最后一支的 `last*` 旁路、HostObject 返回值硬安接收者类、尾递归不校验元数），它们共同的特点是**编译期不报错、运行期按错的类型码解释**——对 typecode 分支表这种设计最容易积累隐性错值，建议与「把 `last*` 旁路改成结构化返回值」一并排期，否则每加一类新类型都要在 8 个位置同步补分支。

死代码与重复逻辑各有明确结论：`MemberName` 整条已死的 AST 形态是最值得清理的一项（8 处分支 + 4 组逐行重复都挂在它上面，且已出现口径漂移）；`fnRetType`、`emitArith` 的 STRING 分支、恒真的 `ALLOW_ESCAPING_HANDLES` 是可直接删除的残留。

质量好的方面：JSON 谱系（15–19）的收窄/上行/装箱/写入值域四张表逐条对齐 `LocalType` 常量与 m3 口径，`SWAP` 栈序处理、`tryLowerTailRecursive` 的「先求值到临时槽再统一写形参」等易错点都有注释与正确实现；无锁、无线程共享、无原生资源，并发面干净。

存量 14 条（严重 1 / 一般 6 / 轻微 7），是否纳入修复待用户决定。
