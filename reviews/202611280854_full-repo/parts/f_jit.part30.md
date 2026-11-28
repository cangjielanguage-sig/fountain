# f_jit 模块审查报告（第 30/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/compiler`（本部分 17 个源文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源均为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：分部分报告 v1（本文件只统计第 30 部分；模块合并报告由主 Agent 产出）

## 发现

### [一般] 终结语（RET/RET_VOID/ABORT）之后的簿记不重置，且汇编期对栈下溢只钳位不拒绝

- **位置**：`f_jit/src/compiler/BytecodeBuilder.cj:332`（`ret`）、`:337`（`retVoid`）、`:349`（`bail`）、`:241`（`place` 置 `reachable = true`）；`f_jit/src/compiler/Assembler.cj:255`（`depth` 钳位）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（语义与注释不符 / 缺少边界校验）+ §7 校验 3 的落地声明
- **证据**：静态确定 —— ① `BytecodeBuilder` 字段注释（`BytecodeBuilder.cj:52`）明写「无条件跳转 / 终结语之后…为伪 dead code」，但 `emitRel`（`:182`）只对 `JMP`/`LOOP_BACK` 置 `reachable = false`，`ret`/`retVoid`/`bail` 三个终结语一个都没置，也未清 `slots`/`depth`（`ret` 只是 `this.depth = 0`，`slots` 保留跨 RET 的陈旧槽号）；② `StackEffect.isTerminator`（`f_jit/src/compiler/Ops.cj:501`）本就存在却零调用（全仓 grep 仅定义处命中），构建器没有用它；③ 汇编期 `Assembler.validateFunc` 的 `if (pop >= 0)` 分支里 `depth = if (depth >= pop) { depth - pop + push } else { push }`，下溢被静默改写而非 `codeFail`，`slots` 的弹出循环也有 `!slots.isEmpty()` 兜底；④ `Ops.cj:303` 注释声称「终结语的 `pop` 只用于 validator」，实际 validator 从不因下溢拒绝。
- **描述**：`RET` 在 `OpInfo` 里是 `(pop=1, push=0)`。如果降低器（或任何调用方）在栈上没有返回值时发 `RET`，`BytecodeBuilder` 因为绕开 `account()` 不会报错，`Assembler` 也只会把深度钳回 0，于是「sink 前回到帧基线」这条校验在**唯一的出口指令上不成立**；同理，终结语之后若再发指令（目前 Lowerer 不这么做），`place()` 会以 RET 留下的 `depth=0` 与跳转点深度比对，可能报出误导性的「分支汇合栈深不等」，而 `Assembler` 的 `CALL_HOST` 判据会读到跨 RET 的陈旧 `slots` 槽号，校验结论不可信。
- **建议**：`ret`/`retVoid`/`bail` 统一走 `account()`（或显式调用 `StackEffect.isTerminator`），在其中置 `reachable = false` 并清空 `slots`；`Assembler.validateFunc` 把 `depth < pop` 改成 `codeFail`（与 `BytecodeBuilder.account` 同一口径），不要钳位。

### [轻微] 生产代码里的死成员与不可达辅助函数

- **位置**：
  - `f_jit/src/compiler/BytecodeBuilder.cj:245` `fixupRel`、`:389` `constsOf`、`:394` `fnIdOf`、`:365` `setSlotType`
  - `f_jit/src/compiler/Capture.cj:114` `CaptureDescriptor.describe`、`:89` `invalidEntries`、`:47` `CaptureOrigin.isInvalidIfEscapes`
  - `f_jit/src/compiler/Capture_test.cj:187` `err`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（无调用者 / 恒假分支 / 兼容残留）
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）grep：`fixupRel`、`constsOf`、`fnIdOf`、`setSlotType`、`.describe()` 均只命中定义处；`BytecodeBuilder`/`CaptureOrigin` 都是 `internal`/`protected` 顶层类型，其 `public` 成员对外不可达，按硬原则二应判死代码。`Capture_test.err` 是 `private static`，本文件内与被引处均无调用（Q3.10 放开捕获白名单后，拒绝面用例已被删除，此辅助函数是残留）。`invalidEntries`/`isInvalidIfEscapes` 的唯一调用点是 `Lowerer.cj:3248` 的 `if (desc.escaping && !Lowerer.ALLOW_ESCAPING_HANDLES)`，而 `ALLOW_ESCAPING_HANDLES` 是 `private static const ... = true`（`Lowerer.cj:162`）⇒ 该分支恒假（Lowerer 属范围外，此处只作为可达性证据引用）。
- **描述**：`fixupRel` 的文档注释写「保留该成员是为了让「回填时机」可被用例观察」，但仓内没有任何用例调用它；它的函数体与 `patchAll`（`BytecodeBuilder.cj:522`）逐行同语义（同为「按 label 过滤 fixups 并 patch」），属「文档声明保留 + 实际无用」的双重残留。`describe()` 生成的 `name:来源` 文本与 `Lowerer.cj:3253` 内联拼装的错误文案重复，但没有任何调用方。
- **建议**：删除 `fixupRel`/`constsOf`/`fnIdOf`/`setSlotType`/`describe`；`invalidEntries`+`isInvalidIfEscapes` 与 `ALLOW_ESCAPING_HANDLES` 一起清掉或改成显式开关（保留则补注释说明为何留着恒假路径）；删 `Capture_test.err`。

### [轻微] `AstExpr.MemberName` 无任何构造点，14 处 `match` 分支为死分支

- **位置**：`f_jit/src/compiler/Ast.cj:244`（构造器声明）、`:302`（`pos()` 分支）；死分支另见 `AstShape.cj:106`、`DefiniteAssignment.cj:293`、`:424`、`Lowerer.cj:578`、`:1132`、`:2265`、`:2329`、`:2584`、`:3369`、`:3433`、`:3492`、`:3801`、`Parser.cj:607`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（兼容残留 / 恒假 case）
- **证据**：静态确定 —— `grep -rn "AstExpr.MemberName("`（排除 `.worktrees`）共 14 处，**全部**是 `case AstExpr.MemberName(...)` 模式匹配，没有一处是 `AstExpr.MemberName(...)` 构造；`Parser.cj` 只产出 `FieldGet`/`FieldSet`/`MethodCall`/`CtorCall`（`Parser.cj:605-606`、`:1014-1018`、`:1034`），仅剩 `:607` 的 `case AstExpr.MemberName(...) => Assign` 一条依赖该节点。
- **描述**：`Ast.cj:244` 的注释写「M1 成员访问的预留位（M2 解析器改为产出 `FieldGet`；保留供旧路径/诊断）」，但「旧路径」已不存在，14 处分支永远不可达，占用四个文件的 `match` 篇幅，且 `Lowerer` 里 9 处分支会误导读者以为还有一条成员访问路径。
- **建议**：删除该构造器及其 14 处分支（含 `Parser.cj:607` 的改写规则），若确需保留则加 `@Deprecated` 语义的注释并补一个「不可达」用例说明。

### [轻微] `Assembler.cj` 两个 import 未使用

- **位置**：`f_jit/src/compiler/Assembler.cj:21`（`DecodedInsn`）、`:27`（`InsnDecoder`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `DecodedInsn`/`InsnDecoder` 只在注释 `:181`「不再调用 `InsnDecoder.decode`」出现，代码无引用；`effectArgc`/`loadedSlotOf` 已改为直读字节（`:294`、`:306`）。
- **描述**：`optimize-compile-hotpath` 改造把 `InsnDecoder.decode` 换成了下标直读，但 import 没跟着删，属改造残留。
- **建议**：删这两行 import。

### [轻微] `BytecodeBuilder.place` 中 `!labelIsSink[label]` 恒真，且若成立会留下未回填 fixup

- **位置**：`f_jit/src/compiler/BytecodeBuilder.cj:214`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §1（恒真恒假分支）
- **证据**：静态确定 —— `labelIsSink.add(false)` 在 `newLabel`（`:194`）对每个标签写 `false`，唯一把它置 `true` 的是 `placeBail`（`:428`）对 `bailLabel`（0）；`bailLabel` 由构造函数私有持有（`:67`、`:82`），从不传给 `place`，因此 `place` 执行时该位恒为 `false`。
- **描述**：这个守卫永远不生效；更糟的是它**反向**保护了一片危险逻辑——一旦 `place` 遇到 sink 标签，`if` 体内的回填+过滤整段被跳过，`fixups` 会残留到 `finish()` 并报「存在未回填的跳转目标」，即该分支若被触发是错误行为而不是安全兜底。
- **建议**：删掉条件（直接执行回填）或改成 `if (this.labelIsSink[label]) { codeFail(...) }`，让不可达路径显式失败。

### [轻微] 栈账的 `argc` 口径两份逐字相同的实现

- **位置**：`f_jit/src/compiler/Assembler.cj:293`（`effectArgc`）与 `f_jit/src/compiler/BytecodeBuilder.cj:484`（`argcOfInsn`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2（只改类型名/位置的重复）
- **证据**：静态确定 —— 两函数体语义完全一致：`CALL_HELPER|CALL_HELPER_NC|CALL_HELPER_V|CALL_FUNC → code[off+3]`，`CALL_CLOSURE|CALL_HOST → code[off+1]`，其余 `0`；差异只有「读 `this.code` 还是参数传入的 `code`」。
- **描述**：`Ops.cj:299` 明确要求「`BytecodeBuilder` 与 `Assembler` 的栈账必须同源，否则会出现永假分支」，而 `argc` 的取法恰恰是同源的**唯一例外**——新增一个 `CALL_*` 家族指令时，只改一处就会让构建期 `maxStack` 与汇编期校验口径漂移（前者按 argc 弹栈，后者按 0 弹栈）。
- **建议**：把 `argc` 提取抽成包内一个函数（如 `StackEffect.argcOf(op, code, at)`），两处共用。

### [轻微] 同包/跨包已有原语却又各写一份：hex 格式化 3 套、LE-u16 读 2 套、补码转换 2 套

- **位置**：
  - `f_jit/src/compiler/Assembler.cj:334`（`hex`）、`:340`（`hexDigit`）、`:317`（`u16At`）、`:496`（`toU32`）、`:505`（`toU64`）
  - `f_jit/src/compiler/CodeDump.cj:144`（`hex2`）、`:150`（`digit`）、`:165`（`u16At`）
  - `f_jit/src/compiler/Lexer.cj:906`（`hex2`）、`:910`（`hexDigit`）
  - `f_jit/src/bytecode/ByteCodec.cj:50`（`i32ToU32`）、`:68`（`i64ToU64`）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2（字面量/换算复制）+ §11（注释与实现不符）
- **证据**：静态确定 —— `Assembler.hexDigit` 与 `Lexer.hexDigit` 都是同一个 16 分支 `match`（前者大小写 A–F，后者 `case 0..13` + `case _`）；`CodeDump.hex2` 是同一算法的第三份（小写 a–f，`v < 10` 走 `toString()`）；`Assembler.u16At` 与 `CodeDump.u16At` 同在小端 u16 读取上重复；`BytecodeBuilder.toU32/toU64` 与 `ByteCodec.i32ToU32/i64ToU64` 表达式逐字相同（`UInt32(v + 2147483647 + 1) + 0x80000000u32` 等）。
- **描述**：① 诊断文本的 hex 大小写已经漂移：`Assembler` 的错误消息是大写（`0x${Assembler.hex(...)}`），`CodeDump` 的 dump 文本是小写（`Builder_test.cj:65` 断言 `11feffffff`），同一次编译的两类输出风格不一致；② `BytecodeBuilder.cj:495` 的注释理由「与 bytecode 包同款，不引入跨包依赖」不成立——本文件已 import 该包三个类型（`:20-22`），真实原因是 `ByteCodec` 的转换函数是 `internal`（包内可见）无法跨包复用；③ 重复的直接后果在范围外文件上已经显现：`Lexer.hexDigit` 的分支写成了 `case 0..13` + `case _ => 'F'`，**14（0xE）会输出 `F`**（`Lexer.cj:910-930`，范围外提示，不计入本部分统计）。
- **建议**：包内收敛到一份 `hex2`/`hexDigit`/`u16At`（`CodeDump` 已在小写口径上被多处断言，建议以它为准并让 `Assembler` 复用）；把 `ByteCodec` 的 `i32ToU32`/`i64ToU64` 提为 `public` 后删掉 `BytecodeBuilder.toU32/toU64`，同时修正那条不成立的注释。

### [轻微] `boxesAtAnyReturn` 名不副实：声称覆盖 ③「Any 返回装箱」，实际只断言 0 装箱

- **位置**：`f_jit/src/compiler/AnyFrontend_test.cj:128`（文档注释）与 `:130`（断言）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §14（承诺与实现不符：测试承诺的覆盖面不存在）
- **证据**：静态确定 —— 用例体只有两条 `countOf(..., 'CALL_HELPER 78,2') == 0` 的断言（`:133`、`:136`），一处是「无 Any 目标」对照、一处是「形参已是 Any 同型直传」；全文件 `grep 'CALL_HELPER 78,2'` 的正向断言只覆盖 ①初始化/赋值、②实参、④容器元素，没有任何用例断言「闭包尾表达式需要装箱到 Any」这一插入点。
- **描述**：`AnyFrontend_test.cj:31-36` 头注释把「四类装箱插入点」列为断言口径，③ 这一类实际只做了负向对照，测试名与注释会让人误判 M3 §3 第 ③ 类插入点已被验证。
- **建议**：补一条正向用例（形如 `{ f: (Int64) -> Any => ... }` 的宿主闭包签名 + 返回值装箱，或在 `Any` 形参调用后取回），或把用例名/注释改成「③ 无装箱对照」。

### [轻微] 恒真断言：`TCase.hit(..., true)` 7 处 + `t1GoldenUnitLoad` 的尺寸自比

- **位置**：`AnyCast_test.cj:171`、`:184`；`AnyContainer_test.cj:53`、`:65`；`AnyFrontend_test.cj:209`、`:219`、`:270`；`Acceptance_test.cj:62`（`let id = raw.size == copy.size`，`:63` 断言）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（弱断言）+ §14（覆盖率虚报）
- **证据**：静态确定 —— `TCase.hit` 的实现是 `public static func hit(id: String, ok: Bool): Bool { if (id.isEmpty()) { return false }; ok }`（`f_jit/src/test/TCase.cj:32-37`），不登记任何全局状态；上述 7 处第二个实参直接写字面量 `true`，因此 `@Assert(..., true)` 恒成立，`id` 字符串不产生任何可核查的覆盖记录。`Acceptance_test.t1GoldenUnitLoad` 的 `copy` 由 `Array<UInt8>(raw.size, ...)` 构造，`raw.size == copy.size` 恒真。
- **描述**：这些行只产出「测试通过」的噪声：它们既不校验行为，也不登记 T 矩阵，与本模块自己在 `Acceptance_test.cj:305-308` 批评的「矩阵虚报」是同一种形态。
- **建议**：把第二个实参换成该用例真正的判据（多为上方已有断言），或让 `TCase.hit` 真正登记 id 并在结束时校验；`t1` 的尺寸自比删掉或改成对内容逐字节相等（`raw == copy`）。

### [轻微] `A64Exec_test.runUnit` 失败路径资源不对称

- **位置**：`f_jit/src/compiler/A64Exec_test.cj:276`（`CodeBuffer.alloc` 失败即 `return`）、`:319`（`compileUnitWith` 返回 `None` 即 `@Fail`，`table` 未释放）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（资源不对称：成功路径 `table.free()`/`mirror.free()` 在 `:312-316`，失败路径没有）
- **证据**：静态确定 —— `FnTable.alloc`（`:270`）与 `ownMirror`（`:265-267`）在 `:276-279` 与 `:319` 两个早退/失败分支上都没有对应 `free()`，只有 `:312-316` 的 `case Some(art)` 尾部释放。
- **描述**：单次运行泄漏一个原生 FnTable 与一个常量镜像；测试进程内重复跑失败用例会累积（`A64Exec_test` 只在小架构下跑，影响有限，但形态与生产代码的资源治理一致，应修）。
- **建议**：用 `try/finally` 或在两个失败分支补 `table.free()` / `ownMirror` 的 `free()`。

### [轻微] 可读性：重复的 doc 注释块与错位缩进

- **位置**：`f_jit/src/compiler/A64Exec_test.cj:213`（孤立注释）+ `:214`（真正的用例注释）；`f_jit/src/compiler/BytecodeBuilder.cj:315`（孤立注释）+ `:320`（真正的成员注释）；错位缩进 `A64Exec_test.cj:301-307`、`:332-344`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §10（可读性 / 必要注释）
- **证据**：静态确定 —— 两处都是两个相邻的 `/** ... */` 块：前者（`A64Exec_test.cj:213`「编译整单元 → 单块 CodeBuffer → …」、`BytecodeBuilder.cj:315`「`CALL_HOST argc`：栈 `[h_fn, a1..an]`…」）后面紧跟另一条注释，被孤立；`A64Exec_test` 的 `let argv = if (...)` 与 `result = unsafe { f(...) }` 段缩进比所属代码块浅 4 格，视觉上像是跳出了 `if`/`match` 块（仓颉按花括号定界，语义不受影响）。
- **描述**：孤立注释会被误读为「该函数/该用例的说明」，错位缩进会让读者误判作用域，属维护成本。
- **建议**：删除被孤立的注释块（内容已被后一条覆盖），修正 `A64Exec_test.cj:301-307`、`:332-344` 的缩进。

### [轻微] `Ast.cj` 的构造器清单注释缺 8 个构造器

- **位置**：`f_jit/src/compiler/Ast.cj:195`（「参数序（与设计稿一致，末位为位置）」清单）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— 注释列了 18 个构造器（`Lit`…`Index`、`MemberName`），`AstExpr` 实际有 26 个；缺 `IndexTarget`、`FieldGet`、`FieldSet`、`MethodCall`、`CtorCall`、`CastOr`、`IsType`、`JsonLit`（各自在 `:243`、`:247`、`:249`、`:251`、`:253`、`:262`、`:270`、`:279` 有独立文档行，但总清单没跟上）。
- **描述**：读者按头部清单核对参数序时会漏掉 M2/M3 新增的 8 个节点。
- **建议**：把清单补全（或改成指针「见各构造器文档行」，避免二次维护）。

### [轻微] `Assembler` 类注释声称 `FbcReader` 复核「数据流」，与实现和自身函数注释矛盾

- **位置**：`f_jit/src/compiler/Assembler.cj:45`（「数据流与类型表合法性由 `FbcReader` 加载期复核（同一口径的双保险）」）
- **来源**：存量（快照无基线）
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— `FbcReader` 侧只有结构/目录/类型表/常量/站点覆盖校验（`FbcReader.cj:32-45` 的 11 类拒绝清单），全文件没有 `StackEffect`、没有栈深或分支汇合分析（grep `StackEffect|depth` 零命中）；同一文件 `:150` 又写「3 由 `BytecodeBuilder` 构建期即时拒绝」——两句对「校验 3 落点」的说法互相冲突，而实际落点只有 `BytecodeBuilder`。
- **描述**：这条注释会让人以为「手写/异常字节流在加载期还有第二道栈平衡防线」，实际上加载期不做数据流校验（与「发现 #1」叠加后，`RET` 的栈不平衡没有任何环节拒绝）。
- **建议**：把「数据流」改为「目录/类型表/站点覆盖」，或在 `FbcReader` 侧补栈平衡校验后再保留该表述。

## 优化可行性方案

### [堆内存] `assemble()` 期 code 段的两份副本

- **现状**：每个函数体在 `assemble()` 里被 `clone()` 一份（`Assembler.cj:79`），汇总进 `bodies`，再整体写进 `ByteWriter`（`:94`、`:111`）后 `take()`（`:114`）；峰值约等于 **2× code 段 + 常量/站点/名字段**，活到 `assemble()` 返回。
- **方案**：站点回填改为原地下标写入（`f.body.code` 已是本次编译独占的可变数组），省掉 `bodies: ArrayList<Array<UInt8>>`，直接向 `ByteWriter` 顺序写出。
- **预期**：code 段峰值内存减半；对典型单元（几 KB）无感，对 >1 MB 的 code 段才有意义（量级收益，未测）。
- **代价**：`assemble()` 失去幂等性（原地打补丁后二次调用会把 `codeOff` 叠加两次、站点表重复登记）——需在类注释里显式声明「只能调用一次」，或加一个 `assembled` 标志。
- **验证**：同一份源码分别用两种实现编译，`getUsedHeapSize()`/RSS 峰值 + 产物逐字节相等（`fjit` 的 `raw` 对比）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Assembler.nargsOf` 的线性查表

- **现状**：`validateFunc` 每遇一条 `CALL_FUNC` 就调 `nargsOf(fid)`（`Assembler.cj:224`、`:322`），后者线性扫全部函数（`while (i < this.sess.funcCount)`）⇒ 校验阶段复杂度 O(函数数 × `CALL_FUNC` 数)。
- **方案**：`validateAll` 入口先建一次 `fnId → nargs` 的 `HashMap`（或按 fnId 序的稠密数组，fnId 由 `CompileSession` 单调分配），`nargsOf` 改查表。
- **预期**：校验阶段从 O(n·m) 降到 O(n+m)；只在函数数达千级、`CALL_FUNC` 密集时可见。
- **代价**：多一张临时表（n 项）；fnId 稀疏时需要先判上界。
- **验证**：`cjpm bench -O2`，同一份「1000 个闭包 + 递归调用」单元，编译耗时中位数对照；同时断言产物逐字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `nargsOf` 的二次复杂度在真实单元上是否可测（函数数多大才显现） | `Assembler.cj:322` | 编译耗时占比、函数数分布 | 对 10 / 100 / 1000 函数的单元各跑 30 轮 `cjpm bench -O2`，取中位数 |
| 2 | `assemble()` 期 2× code 副本是否构成峰值内存可观项 | `Assembler.cj:79`、`:114` | 峰值 `getUsedHeapSize`/RSS、code 段占比 | 用 1 MB code 段单元做单次编译，分段记录分配量 |
| 3 | 终结语之后若出现死代码，`place()` 是否会误报「分支汇合栈深不等」 | `BytecodeBuilder.cj:241` | 是否存在触发输入（需逐个 Lowerer 分支排查） | 构造 `if (c) { return x }` 变体并检查产物，或在 `place` 加临时计数埋点跑全量用例 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/compiler/A64Exec_test.cj` | .cj | ✅ | 资源不对称、恒真断言、孤儿注释/缩进（见发现 #9/#10/#11） |
| 2 | `f_jit/src/compiler/A7JsonSet_test.cj` | .cj | ✅ | 三处辅助与同包其他测试重复（测试准备代码，按 §2 误报边界不计）；无缺陷 |
| 3 | `f_jit/src/compiler/Acceptance_test.cj` | .cj | ✅ | `t1` 尺寸自比恒真（见 #9）；`HandleTable.initialCapacity` 全局改写与仓内既有范式一致，不计 |
| 4 | `f_jit/src/compiler/AnyCastAux_test.cj` | .cj | ✅ | `errKind`/`errText` 与同包重复（测试准备代码）；断言有效 |
| 5 | `f_jit/src/compiler/AnyCast_test.cj` | .cj | ✅ | 2 处 `TCase.hit(..., true)`（见 #9） |
| 6 | `f_jit/src/compiler/AnyContainer_test.cj` | .cj | ✅ | 2 处 `TCase.hit(..., true)`（见 #9）；aux 编码断言有效 |
| 7 | `f_jit/src/compiler/AnyFrontend_test.cj` | .cj | ✅ | ③ 装箱插入点覆盖名不副实（#8）；3 处恒真 `TCase.hit`（#9）；`countOf` 手写子串扫描仅测试用，不计 |
| 8 | `f_jit/src/compiler/Assembler.cj` | .cj | ✅ | 死 import（#4）、栈下溢钳位（#1）、`effectArgc` 重复（#6）、hex/u16 原语重复（#7）、注释与 FbcReader 不符（#12） |
| 9 | `f_jit/src/compiler/Assembler_test.cj` | .cj | ✅ | 12 条校验拒绝面逐条核对，与 `Assembler` 实际拒绝点一一对应；无缺陷 |
| 10 | `f_jit/src/compiler/Ast.cj` | .cj | ✅ | `MemberName` 死枚举值（#3）、构造器清单缺 8 项（#11）；`pos()` 26/26 穷尽 |
| 11 | `f_jit/src/compiler/AstM2_test.cj` | .cj | ✅ | 13/14 槽空安全用例与 `DefiniteAssignment` 契约一致；无缺陷 |
| 12 | `f_jit/src/compiler/AstShape.cj` | .cj | ✅ | 递归仅走诊断路径（§4 未命中）；`MemberName` 死分支（#3）；字符串拼接 O(n²) 仅测试可见，不计 |
| 13 | `f_jit/src/compiler/Builder_test.cj` | .cj | ✅ | 覆盖 ①–⑤ 五条判据，含 `CHECK_ERR` 目标 = 函数体末尾的口径；无缺陷 |
| 14 | `f_jit/src/compiler/BytecodeBuilder.cj` | .cj | ✅ | 终结语簿记（#1）、死成员（#2）、`place` 恒真分支（#5）、`argcOfInsn` 重复（#6）、`toU32` 重复（#7）、孤儿注释（#11） |
| 15 | `f_jit/src/compiler/Capture.cj` | .cj | ✅ | `describe`/`invalidEntries`/`isInvalidIfEscapes` 死或不可达（#2） |
| 16 | `f_jit/src/compiler/Capture_test.cj` | .cj | ✅ | `err` 辅助无调用（#2）；Q3.10 放开后的分类断言与描述符一致 |
| 17 | `f_jit/src/compiler/CastOrParse_test.cj` | .cj | ✅ | `??` 结合性/拒绝面断言有效；无缺陷 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#1（终结语栈约束）；可读性：#10/#11；设计：无分层问题（编译器内部管线职责清晰）；语言特性：`internal` 类型的 `public` 成员按硬原则二判死代码（#2/#3）；安全性：无外部输入拼接、无注入面（编译产物只写出字节） |
| §1 死代码 | 5 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用（排除 `.worktrees`）：`BytecodeBuilder` 4 个成员 + `CaptureDescriptor.describe` 零命中（#2）；`Capture_test.err` 零命中（#2）；`AstExpr.MemberName` 14 处全为 `case`、无构造（#3）；`Assembler` 2 个死 import（#4）；`place` 恒真分支（#5）。`TypeRef.hostParamNames/hostRetName` 仅 `TypeRef_test` 使用，按「仅测试引用 = 可见性建议」处理，未计入 |
| §2 重复逻辑 | 3 | 已把 `Assembler`（14 个函数体）与 `BytecodeBuilder`（30 个函数体）逐个压成「输入-输出-副作用」比对：`effectArgc`≡`argcOfInsn`（#6）、`fixupRel`≡`patchAll`（并入 #2）、hex/u16/补码三组原语（#7）。测试文件的 `errKind/errText/compile` 8 份同形辅助属「测试准备代码」误报边界，未计入 |
| §3 空实现 | 0 | 全 17 文件无 `TODO`/`FIXME`；15 处 `catch` 全部把 `kind`/`message` 取出用于断言，无静默吞异常；无空函数体 |
| §4 栈溢出 | 0 | 生产文件（`Assembler`/`BytecodeBuilder`/`Ast`/`Capture`）无递归；`AstShape.shapeE/shapeS` 按 AST 深度递归（深度由源码嵌套决定、无环），但只被测试与诊断调用，不在生产降低/汇编路径上，记入说明不计为缺陷 |
| §5 OOM | 0 | 无全局只增容器（`CompileSession` 每次 `compile()` 新建，`SourceCompiler.cj:125`）；`Assembler` 的 `bodies/entries/slots` 全部按函数数/栈深线性、随编译结束释放；`Array` 预分配均来自自产常量而非不可信报文 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 profile / bench 数据，无法成立热点结论，已列「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`Assembler`/`BytecodeBuilder` 是单次编译内的可变对象，无 `Mutex`/`synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/批处理，编译器全同步单线程执行 |
| §6.4 低效算法 | 2 | `nargsOf` 线性查表（进「优化可行性方案」[CPU]，无基线不计缺陷）；`AstShape` 循环字符串拼接 O(n²) 仅测试诊断路径，不计 |
| §7 降堆内存方案 | 1 | 见「[堆内存] assemble() 期 code 段的两份副本」（无基线） |
| §8 降 CPU 方案 | 1 | 见「[CPU] Assembler.nargsOf 的线性查表」（无基线） |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建并在函数内用完的大对象」：`Assembler.assemble` 的产物必须逃逸为返回值，`BytecodeBuilder` 的 `code`/`slots` 存进成员并跨调用存活，逃逸检查不通过 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的全部函数边界/空值路径已逐个核对：#1（终结语校验缺口）；#3（不可达 `match` 分支）；#5（恒真守卫）；#7（hex 大小写漂移 + 注释理由不成立）；#8（测试覆盖名不副实）；#9（恒真断言）；#10（失败路径资源不对称）；#12（注释与 `FbcReader` 实际校验不符） |
| §12 并发安全与锁粒度 | 0 | 已确认线程封闭：`SourceCompiler.compile` 每次新建 `CompileSession`/`Lowerer`/`Assembler`（`SourceCompiler.cj:125-129`），本部分类无静态可变状态、无共享注册表写入；`FbcRuleRegistry.get` 只读 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md`（README 覆盖留给含 README 的部分）；#8 的「承诺覆盖但未覆盖」按 §14 的「承诺源 + 缺失证据」口径记一条 |
| 文件覆盖（§13 等） | 17/17 | 与 `files/f_jit.part30.txt` 逐行一致，无未读文件；本部分无 `.md`，§13 不在本部分适用 |

## 模块统计

> 仅统计第 30 部分（17 个文件）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量 13 条（全部为存量，快照模式无本次改动），是否纳入修复待用户决定。

## 总评

本部分覆盖 JIT 前端的最后两段（AST 定义/形状化、单函数发射器与汇编器），无 `.md`。核心结论：**汇编/发射的字节级实现是可信的**——目录布局（`4 + 26n` 与 4 个 `u32` + 5 个 `u16` 字段逐项核对一致）、站点相对→绝对偏移回填、`rel32` 口径、`CHECK_ERR` 收敛块（目标 = 函数体末尾，解释器与 A64 后端都不依赖该目标作为 PC）、`CALL_HOST` 的 `[h_fn, a1..an]` 栈底句柄校验，逐条与测试断言一致，未发现数据错误、越界或崩溃路径。

唯一的「一般」项是终结语（`RET`/`RET_VOID`/`ABORT`）的簿记：字段注释承诺「终结语后为伪 dead code」但三个 emit 路径都没清 `reachable`/`slots`，同时汇编期对栈下溢只钳位不拒绝，导致 `Ops.cj:303` 声称「终结语 `pop` 供 validator 使用」的口径在唯一出口指令上实际为空——目前 Lowerer 不会在 RET 后继续发码，所以是**校验缺口而非线上故障**，可排期修。

其余 12 条均为轻微：死代码（`BytecodeBuilder` 4 个公开成员、`CaptureDescriptor.describe`、`AstExpr.MemberName` 及其 14 处死分支、2 个死 import、1 个恒真守卫）、重复原语（`argc` 取法两份、hex/u16/补码三组）、测试质量（③ 装箱插入点名不副实、7 处恒真 `TCase.hit`、失败路径泄漏）与注释漂移。其中「hex 三套实现」已经在范围外的 `Lexer.hexDigit` 上长出一个真 bug（0xE 打成 `F`），建议优先收敛。
