# f_jit 模块审查报告（第 33/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/compiler`（本部分 16 个源文件：`Parser.cj` / `Ops.cj` / `SourceCompiler.cj` / `PredefinedSnapshot.cj` + 12 个 `*_test.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题记「存量」
- **审查重点**：动态调用/桥接正确性（opcode 分支表与 hid 码表）、递归与栈溢出、并发安全、死代码、重复逻辑
- **报告版本**：v1-part33（模块被拆 38 部分，本文件只覆盖第 33 部分；模块合并报告由主 Agent 产出，不在本文件）

## 发现

### [一般][存量] 插值内表达式用裸 `Parser` 子解析：丢类注册表、且不校验尾随 token

- **位置**：`f_jit/src/compiler/Parser.cj:1285`（`let sub = Parser(innerSrc)`，尾随 `sub.parseExpr()` 在 1286）
- **来源**：存量（快照模式无基线可比；该行属 M1 期实现的插值切分）
- **判据**：review-checklist §11（契约与实现不符 / 静默丢弃）、§10（`Option`/结果被静默丢弃的同类）
- **证据**：静态确定 —— `Parser.init` 的 `registered` 参数默认 `{ _ => false }`（`Parser.cj:50`），子解析器未传入父解析器的回调；`parsePostfix` 的构造调用分支依赖 `this.registered(callee)`（`Parser.cj:1017`），`parseTypeRef` 的已注册类名判定依赖 `this.registered(nameTok.text)`（`Parser.cj:317`）
- **描述**：两个可复现后果。①`'{ => "v=${User()}" }'`（或插值内出现 `x as User`）在顶层形式上合法，但子解析器认为 `User` 未注册 ⇒ `parsePostfix` 只能产出普通 `Call`，`NameResolver.resolve` 于是报 `UnregisteredFunction`；`as User` 更直接报 `BadParameterList`「未注册的类名」。同一表达式写在插值外可以编译。②`parseExpr()` 之后没有 `EOF` 校验（对比 `parseLambda` 在 169 行的检查），所以 `'{ => "${1; 2}" }'` 只取 `1`、`; 2` 被静默丢弃，不报错。此外子解析器的诊断以 `innerSrc` 为源串，`lineText` 取到的是片段而非原源码行（`diagFail` 的 `src` 参数），插值内的语法错误定位也随之失真。
- **建议**：`Parser(innerSrc, registered: this.registered)`；子解析后检查 `this.atKind(TokenKind.EOF)`，非 EOF 即 `diagFail(SYNTAX_ERROR, …, '插值内只允许单个表达式')`；诊断位置需要把片段坐标平移回父串（`buildStringExpr` 已算 `lastLine/lastCol`，可复用）。

### [一般][存量] 普通赋值右值以 `(` 开头被当作多重赋值，括号开头的算术表达式无法编译

- **位置**：`f_jit/src/compiler/Parser.cj:671`（`if (grouped || this.atKind(TokenKind.LParen))`）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 文法误判导致合法源码被拒）
- **证据**：静态确定 —— 只有分组 LHS（`(a, b) = …`）才应进多重赋值分支，`grouped` 已能为该形态定性；`||` 右侧把「RHS 恰好以 `(` 开头」也推进了同一分支
- **描述**：`'{ => var x = 0\n x = (1 + 2) * 3\n x }'`：`parseMaybeMultiAssign` 在 `=` 后看到 `(` 即 `expect(LParen)` → 解析 `1 + 2` → `expect(RParen)` → 返回 `MultiAssign([x], [1+2])`，剩余的 `* 3` 留给 `parseBlockBody` 当新语句 ⇒ `parsePrimary` 报「表达式位置遇到无法起头的词法单元「*」」。即**任何** `lhs = (…) …` 形态的赋值都编不过（`x = (a) && b`、`x = (f(y)) + 1` 同理）；`x = (1)` 虽能过但被降成 1:1 多重赋值，语义承载与 `Assign` 不同。测试面完全没覆盖这种写法（`Parser_test.cj:125-131` 只测 `(a, b) = (b, a)`）。
- **建议**：删掉 `|| this.atKind(TokenKind.LParen)`，只在 `grouped` 为真时走元组 RHS；顺带为 `x = (1 + 2) * 3` 与 `x = (a)` 各加一条用例。

### [一般][存量] 三等分除法链 `a / b / c` 被判为正则替换段

- **位置**：`f_jit/src/compiler/Parser.cj:949`（乘法级尝试替换段）、`:1089-1115`（无修饰符 ⇒ `n = Some(0)`）、`:1044`（后缀位置同款尝试）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/规格不符）、§6.4（语法层歧义导致合法表达式不可用）
- **证据**：静态确定 —— `tryParseReplace` 在拿到 `s`、`r` 后，若没有第三段修饰符就按「省略 g 等价第 0 个」直接判成功（`Parser.cj:1113-1116`）；`/s/r` 与「除以 b 再除以 c」在 token 流上同形，唯一区分手段（能否完整解析出替换段）对两段除法同样成立
- **描述**：`'{ n: Int64 => n / 2 / 3 }'` 解析为 `RegexOp(Slash, n, 2, 3, n=0)`，降低期 `lowerRegexOp`（`Lowerer.cj:3061-3064`）对 `s` 走 `lowerExprAs(s, STRING)` ⇒ `Int64` 字面量报 `TypeMismatch`，合法算术被拒；若两侧恰好是字符串（`"a" / "b" / "c"`）则通过类型检查并真的发 `REGEX_REPLACE_*`，语义完全走偏。四段 `a / b / c / d` 也会把后两段吞成替换段。注释里「唯一可靠的区分是能否完整解析出替换段形」（`Parser.cj:1069-1071`）对 `a/b/c` 不成立。
- **建议**：把「是否替换段」绑定到**静态可定的正则来源**——左值必须是 `RegexLit` 字面量或静态 `Regex` 槽（`AstExpr.Lit` 的 `RegexLit` 分支、或降低期回填的类型）；否则一律按除法。若设计坚持「省略修饰符 = /0」，需在语法层要求至少一个修饰符（`g` 或数字），并把该形态写进 §11.9 与 README。

### [一般][存量] 替换段序号解析无范围校验，超长字面量抛非诊断异常或得到负序号

- **位置**：`f_jit/src/compiler/Parser.cj:1135`（`parseDigits`），调用点 `:1104`、`:1108`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 错误处理缺失破坏对外契约）
- **证据**：静态确定（无任何长度或范围校验）；具体异常类型待确认 —— 仓颉 `Int64` 的 `*`/`+` 在检查语义下抛 `OverflowException`（旁证：`f_jit/src/bytecode/CanonKey.cj:56-60` 明确写「`Int64(bits)` 是检查型转换，`-0.0` 常量就足以让编译器崩」，`HandleTable` 亦为规避此点手写补码折返），回绕语义下则得到负数
- **描述**：`'{ => re/s/r/99999999999999999999 }'` 的 `n` 被 `parseDigits` 逐位累乘，20 位十进制必然越过 `Int64.Max`。若按检查语义，抛出的 `OverflowException` 不是 `SourceCompileException`，违背 `SourceCompiler.cj:113` 注释承诺的「编译期错误一律抛 `SourceCompileException`」，调用方（`CompilePipeline.runSource` 只 `catch Exception` 后原样重抛）拿到的是无法归类到源码位置的宿主异常；若按回绕语义，`n` 变成负数并被烘进 `REGEX_REPLACE_NTH`。正常源码不该触发任何一种。
- **建议**：`parseDigits` 用受检累加（先判 `v > (Int64.Max - d) / 10`）并在越界时 `diagFail(SYNTAX_ERROR, …, '替换序号超出 Int64 范围')`；`m < n` 也一并拒。

### [一般][存量] 表达式解析递归深度无上限，深嵌套源会让宿主栈溢出

- **位置**：`f_jit/src/compiler/Parser.cj:767`（`parseExpr` 入口）→ `:1181-1195`（`(` 递归回 `parseExpr`）、`:972-980`（`**` 右递归）、`:983-991`（一元递归）、`:1310-1326`（`if` 值形态递归）、`:1337`（嵌套闭包递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归：深度由输入决定）
- **证据**：静态确定（无深度计数、无长度上限：`f_jit/src/Compiler.cj` 与 `f_jit/src/CompilePipeline.cj` 都不校验源码长度，`Lexer` 也没有层数限制）；崩溃阈值需实测
- **描述**：每层括号经 `parseExpr → parseCastOr → parseOr → parseAnd → parseCompare → parseBitOr → parseBitXor → parseBitAnd → parseShift → parseRange → parseAdditive → parseRegexOp → parseMultiplicative → parsePower → parseUnary → parsePostfix → parsePrimary` 约 17 个栈帧。源码由 `Compiler.compile(source)` 直接接收，`'{ => ' + '('×N + '1' + ')'×N + ' }'` 的 4·N+8 字节输入即可把深度线性推到 N；栈溢出在仓颉侧不可捕获，宿主进程直接终止。当前严重度按「源码由开发者自写、非远端不可信输入」定一般；若调用方把它接到配置中心 / 远端下发的表达式串，应按严重处理。
- **建议**：`Parser` 增 `depth: Int64` 与上限常量（如 256），在 `parseExpr` / `parseUnary` / `parsePrimary` 的递归入口 in/out 增减并在超限时 `diagFail(SYNTAX_ERROR, …, '表达式嵌套过深')`；同一上限复用到 `tailValueOf` / `scanExpr` 侧的 AST 递归。

### [一般][存量] 测试直接改全局 `SignatureTable.enabled` 且不恢复，造成数据竞争与顺序相关

- **位置**：`f_jit/src/compiler/SpecializationFmt_test.cj:39`、`:41`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无同步）、§11（测试隔离）
- **证据**：静态确定 —— `SignatureTable.enabled` 是 `public static var`（`f_jit/src/runtime/SignaturePlan.cj:135`），运行时在每次特化判定处无同步读取（`SignaturePlan.cj:142` `if (!enabled)`，命中路径靠 `AtomicReference` 但开关本身是裸 `var`）；本用例置 `false` → 编译 → 置 `true`，无 `finally`、无原值恢复
- **描述**：①若测试进程内其他用例（或宿主）依赖 `enabled = false`，本用例跑完后状态被改成 `true`，结果依赖执行顺序；②多线程并发跑测试时，一边写 `var` 一边在别的线程读，是未定义可见性 + 数据竞争（`SignatureTableConcurrency_test.cj` 恰好在验证该类的并发读）。本用例想证明的「开关不影响产物」其实不需要真的翻转全局开关之外的状态，代价却外溢到了整个进程。
- **建议**：`let old = SignatureTable.enabled` + `try { … } finally { SignatureTable.enabled = old }`；更彻底的做法是把开关做成构造期参数或 `AtomicBool`（`SignaturePlan.cj` 侧），避免运行期裸 `var` 跨线程读写。

### [轻微][存量] `Ops.cj` 三个判定函数无调用者，语义在 `BytecodeBuilder` 内联重写

- **位置**：`f_jit/src/compiler/Ops.cj:501`（`StackEffect.isTerminator`）、`:506`（`StackEffect.isUncondJump`）、`:276`（`HelperCodec.needsAutoCheck`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 顶级类型里的 `public` 成员全项目无使用）、§2（同一判定两处实现）
- **证据**：静态确定 —— 三者均只在 `Ops.cj` 定义处出现（`grep -rn "\b(isTerminator|isUncondJump|needsAutoCheck)\b" --include=*.cj` 仅命中定义行）；`isUncondJump` 的语义被内联在 `BytecodeBuilder.cj:182`（`if (op == Op.JMP || op == Op.LOOP_BACK) { this.reachable = false }`），`needsAutoCheck` 的语义由调用方选 `callHelper` / `callHelperNoCheck` / `callHelperVoid` 决定（`BytecodeBuilder.cj:288-305`）
- **描述**：`Op` / `StackEffect` / `HelperCodec` 都是 `internal class`，其 `public` 成员在本模块外不可达，仓内零引用即为死代码。三处注释（`Ops.cj:500`、`:505`、`:275`）仍在描述"这两处必须同源"的契约，实际只有一个消费者。
- **建议**：删除三者，或反过来让 `BytecodeBuilder.cj:182` 与 `callHelper*` 调用它们（保留单一判定源，符合注释原意）。

### [轻微][存量] `StackEffect.TABLE` 中 `CALL_HOST` 的条目不可达，且与 `of()` 的返回值相反

- **位置**：`f_jit/src/compiler/Ops.cj:433`（`t[Int64(Op.CALL_HOST)] = (0, 0)`）对 `Ops.cj:326-328`（`of()` 对 `CALL_HOST` 返回 `(arg + 1, 1)`）
- **来源**：存量
- **判据**：review-checklist §1（恒不生效的分支 / 读不到的表项）
- **证据**：静态确定 —— `of()` 在 `TABLE` 查表前就 `return` 了 `CALL_CLOSURE || CALL_HOST` 分支，唯一读者是 `of()`（`Assembler.cj:254`、`BytecodeBuilder.cj:459`）
- **描述**：表中这一格永远读不到；注释（`Ops.cj:307`）说"未登记者保持 `(-1,-1)`，由调用方转为拒绝"，而这里登记的是合法但错误的 `(0,0)`。若将来有人把 `CALL_HOST` 从 `of()` 的特判里移走，校验会静默放行一个弹参错误的指令（`argc` 不为 0 时下越界或深度漂移）。同类"看似登记、实则走特判"的还有 `CALL_CLOSURE`（表里没有，反而安全）。
- **建议**：删掉该行，改为与 `CALL_CLOSURE` 一致的"不登记 + `of()` 特判"，并在 `of()` 上加一行注释说明 `CALL_*` 家族一律不进表。

### [轻微][存量] 两份码表靠人工同步；注释声称的自检函数不存在，两个 opcode 常量是惰性残留

- **位置**：`f_jit/src/compiler/Ops.cj:21-25`（注释）、`:180-181`（`DT_NEW` / `DUR_NEW`）、`:213-219`（`HelperCodec` 注释）
- **来源**：存量
- **判据**：review-checklist §1（未使用常量 / 兼容残留）、§13（注释与代码不符）
- **证据**：静态确定 —— `grep -rn "agreeWithOpInfo"` 全仓零命中，该函数不存在；`OpInfo.selfCheckOk()`（`f_jit/src/bytecode/OpInfo.cj:100`）只校验表自身（长度、`code == i`、`len`），不比对 `compiler/Ops.cj` 的常量；`HelperId.isFixed`（`f_jit/src/runtime/HelperId.cj:223-226`）只判名字不是 `reserved(`/`unknown(`，同样不比对 `HelperCodec` 的取值
- **描述**：注释「数值口径仍只有一处权威……`Ops.agreeWithOpInfo()` 再比助记符」描述了一道并不存在的防线。我按机械比对核过当前数据：`Op` 的 157 条常量与 `OpInfo.OPCODE_TABLE` 的 `code`/名字**逐条一致**，`HelperCodec` 的 13 个 hid 与 `runtime/HelperId` 也一致，因此当前没有实际漂移；风险在于下一次单边修改不会被任何用例拦住。另外 `DT_NEW`(0xA9) / `DUR_NEW`(0xAA) 全仓无发射点、也不在 `StackEffect.TABLE`（发射即 `codeFail`），属 `OpInfo` 标为 `CAT_FORBID` 的保留码（`f_jit/README.md:276`），保留尚可，但两个常量在 `compiler` 侧没有任何读者。
- **建议**：补一条 `@TestCase` 做 `Op` 常量 ↔ `OpInfo.OPCODE_TABLE`（名字后缀 + 数值）与 `HelperCodec` ↔ `HelperId` 的双向比对（断言形式是遍历而非逐条写死）；把注释里的 `Ops.agreeWithOpInfo()` 改成该用例名，或删掉 `DT_NEW`/`DUR_NEW` 常量。

### [轻微][存量] `CompiledSourceUnit.fingerprint` / `funcCount` 无读者，且每次 compile 白算一次整源哈希

- **位置**：`f_jit/src/compiler/SourceCompiler.cj:53`（`funcCount`）、`:55`（`fingerprint`）、`:130-132`（计算）、`:148`（填充）
- **来源**：存量
- **判据**：review-checklist §1（死字段：赋值后无人读）
- **证据**：静态确定 —— 全 `f_jit/src` 搜 `.fingerprint` 只命中 `backend/CompileCacheKey.cj` 自己的同名字段；`cu.funcCount` / `cu.fingerprint` 零命中（`FbcReader.load` 从 `.fbc` 头取函数数，缓存键由 `CompilePipeline.cj:60` 另算 `Fingerprint.fnv1a128(source)`）
- **描述**：`fingerprint` 每次编译都整串跑一遍 `Fnv128.fnv1a128(src)` 再取低 64 位（`:130-132`），结果无人使用；同一份源码在 `CompilePipeline.runSource` 里又被 `Fingerprint.fnv1a128` 算了一遍（另一套实现）。`funcCount` 同理只是把 `sess.funcCount` 抄进产物结构体。属于"读了不用"的死字段 + 每编译一次多一次全源哈希。
- **建议**：删两个字段；若保留 `fingerprint` 供外部去重，则让 `CompilePipeline` 复用它，避免同源两次哈希。

### [轻微][存量] 换行规范化在同一条编译链上做 4 次，且有两份独立实现

- **位置**：`f_jit/src/compiler/SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`（`init`）、`PredefinedSnapshot.cj:141`（`NameResolver` 构造）；实现 `Lexer.cj:123-140` 与 `f_jit/src/bytecode/Fingerprint.cj:90`
- **来源**：存量
- **判据**：review-checklist §2（换算/规范化复制）
- **证据**：静态确定 —— `Lexer.normalizeNewlines` 无条件 `ArrayList` 累积 + `toArray()` + `String.fromUtf8`（即使源码里没有 `\r` 也整串复制两份）；`bytecode/Fingerprint.normalizeSource` 是第二份同语义实现（逐字节 CRLF/CR→LF）
- **描述**：一次 `compile` 里 `normalizeNewlines` 被调 4 次（`SourceCompiler` 一次 → `Parser` 一次 → `Lexer` 构造一次 → `NameResolver` 一次），每次 2 份整串副本，源码 10 KB 时约 80 KB 纯瞬态垃圾，且 4 次结果完全相同。两份实现还带来"改一处漏一处"的风险（`Fingerprint` 那份被 `Fingerprint.sourceKey` 使用，`Lexer` 那份被编译链使用）。
- **建议**：在 `SourceCompiler.compile` 入口规范化一次，`Lexer` / `Parser` / `NameResolver` 接收已规范化的串（构造参数或 `internal init` 重载）；实现上让 `compiler` 复用 `Fingerprint.normalizeSource`（`compiler` 已依赖 `bytecode` 包）。

### [轻微][存量] `NameResolver.snapshotOf()` 无调用者

- **位置**：`f_jit/src/compiler/PredefinedSnapshot.cj:185`
- **来源**：存量
- **判据**：review-checklist §1（`internal` 类里的 `public` 成员全项目无使用）
- **证据**：静态确定 —— 全仓 `grep -rn "snapshotOf" --include=*.cj` 只命中定义行；`NameResolver` 的消费者（`Lowerer`）直接用 `this.sess.registry`
- **描述**：`NameResolver` 是 `internal class`，该 `public` 方法对外不可达，仓内零引用。注释「注册表快照（降低阶段取签名用）」描述的角色实际由 `CompileSession.registry` 承担。
- **建议**：删除；若确有外部取快照需求，应在 `CompileSession` 上暴露而不是绕 `NameResolver`。

### [轻微][存量] `assignFrom` 的 `MemberName` 分支不可达

- **位置**：`f_jit/src/compiler/Parser.cj:607`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 全仓 `MemberName(` 只出现在声明（`Ast.cj:245`）与 `match` 模式中（`AstShape.cj:106`、`DefiniteAssignment.cj:293/424`、`Lowerer.cj` 8 处、`Parser.cj:607`），**没有任何构造点**；`Parser` 产出成员访问一律是 `AstExpr.FieldGet`（`:1034`）
- **描述**：该分支把 `MemberName` 原样放进 `Assign`，看起来是"属性赋值"的兼容路径，实际永远走不到；`assignFrom` 的 `_ =>` 兜底（`:608-611`）才是真实行为。范围外提示：`AstExpr.MemberName` 整个变体（含 `Lowerer` / `DefiniteAssignment` / `AstShape` 的 9 处匹配）都因缺构造点而失效，`Ast.cj:36` 注释写的是"保留 M2 的 MemberName"——若不再计划引入，应整体删除；若计划引入，需要在这里补构造。
- **建议**：删除 `Parser.cj:607` 分支（让 `MemberName` 落到显式报错），并在 `Ast.cj` 上标注该变体当前不可达。

### [轻微][存量] 四段"配对扫描"近似重复；两处文档注释整段复制

- **位置**：`f_jit/src/compiler/Parser.cj:515`（`indexFollowedByAssign`）、`:542`（`looksLikeMapLiteral`）、`:615`（`groupFollowedByAssign`）、`:1359`（`looksLikeClosure`）；文档 `:1066-1082`、`:371-377`
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 近似重复）
- **证据**：静态确定 —— 四个函数都是"从 `from` 起按 `depth` 扫到配平，再回答一个是非问题"，差异仅在开括号集合（`[` / `{(` / `({[` / `{([`）、提前返回条件（`:` at depth 1 / `=>`）与 EOF 处理
- **描述**：目前四份判据各自正确（我逐条核了深度增减与 `depth <= 0` 语义，未发现行为漂移），但改词法（例如新增 `TokenKind` 分组符）时必须同改四处，这是典型的近似重复升级为缺陷的路径。文档侧：`tryParseReplace` 的 doc 注释在 `:1066-1071` 与 `:1073-1082` 连续写了两遍（第二遍补了"禁止嵌套"），`parseTypeComponent` 在 `:371` 与 `:372-377` 也是两段。
- **建议**：抽一个 `scanGroupEnd(ts, from, opens: Array<TokenKind>, stops: Array<TokenKind>): Int64` 返回配平位置与停止原因，四个判定改为在其上做一层谓词；重复的文档注释删旧留新。

### [轻微][存量] AST 位置取值不准：赋值语句取右值之后的 token，插值片段按字节且不累计换行

- **位置**：`f_jit/src/compiler/Parser.cj:591`、`:593`（`SourcePos(this.peek().line, this.peek().column)` 在 RHS 解析之后取）、`:609`（同）、`:1287-1288`（`lastCol = t.column + j + 2`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 值错）、§11（注释承诺"AST 节点携带位置"与实际不符）
- **证据**：静态确定 —— 三处 `pos` 都是 RHS 解析完、`peek()` 已指向下一条语句首 token 时才取值；`j` 是插值串内的**字节**偏移，`+ 2` 按定界符宽度硬编码，且 `lastLine` 在循环里从不更新（多行插值串所有后续片段都落在首行）
- **描述**：当前是"错值未被读"：`AstStmt.ExprStmt` 的位置在 `Lowerer.cj:510`、`DefiniteAssignment.cj:166` 都被 `_` 丢弃，所以现在没人受害；但 `Parser_test.cj:233-241` 的用例名就是"AST 节点携带位置"，一旦有人按语句位置报诊断，行号会指到下一条语句。插值侧同理：`'''a${x}b${y}'''` 里 `b`、`y` 的 column/line 都会偏（非 ASCII 前缀还会按字节多算）。
- **建议**：在 `parseAssignOrExprStmt` 入口就用 `t = this.peek()` 存一份位置（`:572` 已有 `save`，顺手存 `SourcePos`）；`buildStringExpr` 里改为按码点推进并遇到 `0x0A` 时 `lastLine += 1, lastCol = 1`。

### [轻微][存量] 测试断言强度不足：恒真断言、不校验错误码、未使用的辅助函数

- **位置**：`f_jit/src/compiler/Semantics_test.cj:103`、`:130`、`:150`、`:156`（`daOf(...)` 断言）；`Pipeline_test.cj:131-137` 与 `Lowerer_test.cj:215-222`（`runInt` 忽略 `ctx.errCode`）；`LowererM2_test.cj:389`（`compileKindV2` 无调用者）
- **来源**：存量
- **判据**：review-checklist §1（无调用者）、§11（失败路径被当成功）
- **证据**：静态确定 —— `DefiniteAssignment.analyze` 的每个 `diagFail` 都是 `Nothing`（抛异常），末尾无条件 `true`（`DefiniteAssignment.cj:66-77`，其唯一调用点 `SourceCompiler.cj:124` 也用 `let _ =` 丢弃返回值）⇒ `@Assert(daOf(...), true)` 这 4 条**不可能失败**，正向用例实际上什么都没验；`compileKindV2` 全仓零引用
- **描述**：正向路径退化成"不抛异常即通过"，与同文件 `expectDaError`（`Semantics_test.cj:187`）的强度不对等。`runInt` 不看 `errCode` 的后果是：`Pipeline_test.cj:76` 期望 `0` 的尾递归用例，若运行期报错、`interp.run` 恰好返回 `0`，断言照样通过，"1e6 次不爆栈"的结论无法与"提前错误退出"区分。
- **建议**：`analyze` 改成返回 `Unit`（或删除布尔返回）；`runInt` 统一断言 `ctx.errCode == 0`（需要错误码的用例显式取 `errCode`）；删除 `compileKindV2`。

### [轻微][存量] `PerfCompare_test` 的基线数字不可复核

- **位置**：`f_jit/src/compiler/PerfCompare_test.cj:46-108`（`rounds = 5`、单次计时、只 `println` 一次汇总）
- **来源**：存量
- **判据**：`references/fountain-baseline.md` §8（基准必须给绝对值、单位、中位数、离散程度与构建配置）、review-checklist §6.1
- **证据**：静态确定 —— 每组只测一轮（5 次累加后取总时长），无预热轮次统计、无中位数/离散度、无 `-O2` 记录；`@When[os == 'Linux']`（`:33`）
- **描述**：该用例产出的是"体系结构与副作用一致"的回归证据（结果逐位相等，这部分是有价值的），但打印的 `jit_vs_interp` / `jit_vs_native` 百分比无法当作性能基线引用——单次采样、无离散度，机器噪声与 JIT 预热都可能主导。报告里任何基于它的"JIT 比解释器快 N 倍"都缺证据等级。
- **建议**：每组重复 R 轮（≥5）并打印中位数 + 极值，或改成 `cjpm bench` 用例；在输出里带上 `-O2` 与轮数，便于留档对照。

> 存量缺陷 17 条（一般 6 / 轻微 11），是否纳入修复待用户决定。

## 优化可行性方案

### [堆内存] 去掉重复的整源规范化副本

- **现状**：一次 `compile` 对源码串做 4 次 `normalizeNewlines`（`SourceCompiler.cj:115`、`Parser.cj:51`、`Lexer.cj:57`、`PredefinedSnapshot.cj:141`），每次 `ArrayList<UInt8>` + `toArray()` + `String.fromUtf8` 共 3 个对象、约 2 份字节副本；10 KB 源码 ⇒ 约 80 KB 瞬态分配，源码越大线性放大。生命周期仅限一次 `compile`，无跨调用持有。
- **方案**：`SourceCompiler.compile` 规范化一次并向下传递（`Lexer` 增 `init(normalized:)` 或让 `Lexer`/`Parser`/`NameResolver` 接受"已规范化"标记）；实现统一到 `Fingerprint.normalizeSource`。
- **预期**：每次编译少 3 次整串复制（约 -75% 该环节分配），源码 10 KB 时省 ≈60 KB 瞬态；对总分配占比待测。
- **代价**：`Lexer` / `Parser` / `NameResolver` 的构造契约要写明"入参必须已规范化"，否则会出现"两套 CRLF 口径"的回归；改动面 4 个文件但都是内部构造。
- **验证**：同一份 10 KB 源码跑 10k 次 `compile`，对比 `getAllocatedHeapSize()` 峰值与总分配量（`mem §1.2`），同时断言产物 `.fbc` 字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 解析器的语句数组与 token 数组各留一份

- **现状**：`Lexer.tokenize()` 把整源物化成 `Array<Token>`（`Parser.cj:52`），`splitTailExpr` 又把 `body[0..n-1]` 复制进新 `ArrayList` 再 `toArray()`（`Parser.cj:219-223`）——每条语句被数组头与元素各引用一次，尾部一条额外复制。源码 n 条语句 ⇒ 约 n 个 `AstStmt` 引用槽的冗余（Token 数组本身是解析必需，不在此列）。
- **方案**：`splitTailExpr` 直接用 `body.slice(0, n)`（若 `Array` 有零拷贝视图则用之），或在 `parseBlockBody` 里就地"最后一条留作尾表达式"。
- **预期**：省一份 n 元素的引用数组（每条语句 8 B 量级），对语法树总占用影响小。
- **代价**：`LambdaAst.body` 与 `retExpr` 的构造点要同步改；几乎无语义风险。
- **验证**：`parseLambda` 前后 `getAllocatedHeapSize()` 差值对照，AST 形状用例（`Parser_test`）全绿。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 预定义函数名查找是线性扫描，且每个调用点查 2–3 次

- **现状**：`PredefinedSnapshot.slotOf`（`PredefinedSnapshot.cj:65-74`）逐项字符串比较；`has` / `paramTypesOf` / `retTypeOf` 各自再调一次 `slotOf`（`:60`、`:76`、`:84`），`Lowerer` 对一个调用点会分别取形参与返回类型（如 `Lowerer.cj:1988/2029/2046`、`:2574-2578`）⇒ 每个调用点 2–3 次 O(n) 扫描、每次 n 次字符串比较。
- **方案**：`PredefinedSnapshot` 内部建一次 `HashMap<String, Int64>` 索引（构造期构建，快照不可变），`slotOf` 走哈希；`paramTypesOf`/`retTypeOf` 合并成一次 `slotOf` + 两次下标。
- **预期**：注册数 n 较大（≥32）时调用点解析从 O(n) 降到 O(1)；n 很小（典型 3–10 个）时收益大概在噪声内。
- **代价**：快照多一个不可变 map（n 个条目，可忽略）；`HashMap` 迭代顺序无关，不影响 slot 语义。
- **验证**：`cjprof record` 跑"单文件 5k 次 compile + 200 个注册函数"的脚本，对比 `slotOf` 自耗时占比与编译总时长中位数；n=10 时同测一次，确认没有变慢。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 删除死字段顺带去掉一次整源哈希

- **现状**：`CompiledSourceUnit.fingerprint` 每次编译整串跑 `Fnv128.fnv1a128`（`SourceCompiler.cj:130-132`）后无人读；`CompilePipeline` 另算一次 `Fingerprint.fnv1a128(source)`（`CompilePipeline.cj:60`）。
- **方案**：删除该字段（或让 `CompilePipeline` 复用），只保留缓存键那一份哈希。
- **预期**：每次编译少一次 O(len) 哈希 + `UInt128` 装箱；10 KB 源码下约省两次整串遍历（另一份仍要算），端到端占比预计 <2%。
- **代价**：`CompiledSourceUnit` 的 `init` 签名变化，`Capture_test` 等构造点需跟着改。
- **验证**：`cjpm bench -O2` 同输入 1k 次 compile 的中位数对照；顺带断言 `.fbc` 字节不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词法/语法解析在端到端编译中的耗时占比可能是最大单项 | `f_jit/src/compiler/Parser.cj:157`、`Lexer.cj:101` | 自耗时占比 + 调用路径 | `cjprof record` 跑 5k 次 `Compiler.compile`（同一 10 KB 源码），看 `tokenize`/`parseLambda` 的 self time |
| 2 | `parseDigits` 溢出在仓颉侧是抛 `OverflowException` 还是回绕 | `f_jit/src/compiler/Parser.cj:1139` | 实际异常类型 | 单测里编译 `'{ => re/s/r/99999999999999999999 }'`，捕获后打印异常类型（不修源码，仅在临时用例里观察） |
| 3 | 深嵌套括号的栈溢出阈值（决定 #5 的实际风险） | `f_jit/src/compiler/Parser.cj:1181` | 不同 N 下是否 abort + 崩溃层数 | 二分 N（1k/4k/16k 层括号）逐次 `compile`，观察进程退出码与栈深 |
| 4 | 4 次 `normalizeNewlines` 在编译总分配中的占比 | `SourceCompiler.cj:115` 等 4 处 | 分配量拆分 | 用 10 KB / 100 KB 两档源码各跑 1k 次 `compile`，对比 `getAllocatedHeapSize()` 增量与重复次数 |
| 5 | `PredefinedSnapshot.slotOf` 线性扫描在注册数大时会成为编译热点 | `f_jit/src/compiler/PredefinedSnapshot.cj:65` | 注册数 n 与编译耗时的关系曲线 | 参数化 n ∈ {10, 100, 1000}，每档编译同一含 500 个调用点的源码，取中位数 |

> 以上均无改前/改后对照数据，不进 `todo.md` / `tasks.md`。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/compiler/LowererM2_test.cj` | .cj | ✅ | 测试；见 #16（`compileKindV2` 零引用） |
| 2 | `f_jit/src/compiler/Lowerer_test.cj` | .cj | ✅ | 测试；见 #16（`runInt` 不查 errCode） |
| 3 | `f_jit/src/compiler/NameResolver_test.cj` | .cj | ✅ | 测试，与 `NameResolver` 行为一致 |
| 4 | `f_jit/src/compiler/Ops.cj` | .cj | ✅ | 见 #7–#9；157 条 opcode 常量与 `OpInfo` 逐条比对一致 |
| 5 | `f_jit/src/compiler/Parser.cj` | .cj | ✅ | 见 #1–#5、#13–#15 |
| 6 | `f_jit/src/compiler/Parser_test.cj` | .cj | ✅ | 测试；缺 `x = (…)` 与 `a/b/c` 用例（见 #2、#3） |
| 7 | `f_jit/src/compiler/PerfCompare_test.cj` | .cj | ✅ | 见 #17 |
| 8 | `f_jit/src/compiler/Pipeline_test.cj` | .cj | ✅ | 测试；见 #16 |
| 9 | `f_jit/src/compiler/PredefinedSnapshot.cj` | .cj | ✅ | 见 #10、#12；快照语义与注释一致 |
| 10 | `f_jit/src/compiler/Q6Compiler_test.cj` | .cj | ✅ | 三引擎差分验收，`HandleTable.resetForTest` 未用 `finally`（断言失败时残留，轻微，不单列） |
| 11 | `f_jit/src/compiler/Semantics_test.cj` | .cj | ✅ | 见 #16 |
| 12 | `f_jit/src/compiler/SourceCompiler.cj` | .cj | ✅ | 见 #10；`compile()` 无跨调用可变状态（注释成立） |
| 13 | `f_jit/src/compiler/SpecializationFmt_test.cj` | .cj | ✅ | 见 #6 |
| 14 | `f_jit/src/compiler/StrictFpCodegen_test.cj` | .cj | ✅ | 断言口径正确（`countOf` 用前后空格避 `FDIV`/`FDIV_CHK` 前缀混淆） |
| 15 | `f_jit/src/compiler/TemporalSurface_test.cj` | .cj | ✅ | 时间构造面，与 `HelperCodec` 的 H73–H76 一致 |
| 16 | `f_jit/src/compiler/Temporal_test.cj` | .cj | ✅ | 时间算术面，句柄 `pin` 未释放（测试进程内，未单列） |

合计：`.cj` 16 个 / `.md` 0 个 / 共 16 个，全部读完（本部分清单无 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 5（#1–#5）、测试隔离 1（#6）、可读性 1（#14）；安全性 0 条：本部分无 IO / SQL / 凭据，唯一不可信输入是 lambda 源串，风险已并入 #5 |
| §1 死代码 | 4 | #7（3 个判定函数）、#10（2 个死字段）、#12（`snapshotOf`）、#13（`MemberName` 分支）；另 #9 的 `DT_NEW`/`DUR_NEW` 与 #16 的 `compileKindV2`。已逐个 private / internal 符号全仓搜引用；`protected` 顶层类型（`CompiledSourceUnit`/`SourceCompiler`/`PredefinedSnapshot`/`HostClosureSigDecl`）均有使用者，无"零引用 protected"；`Op`/`HelperCodec`/`StackEffect` 成员逐个 grep；对外可达的 public 不判 |
| §2 重复逻辑 | 2 | #11（换行规范化两份实现、链上 4 次）、#14（四段配对扫描 + 重复文档）；另 #7 的 `isUncondJump` 被内联重写。本部分函数体已两两比对「输入-输出-副作用」（`Parser.cj` 单文件 71 个函数），跨文件按字面量 / 错误文案 / 正则搜过 |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`buildJsonExpr` 只做形态判定但注释明示"JSON 语法在降低阶段解析"，非空实现 |
| §4 栈溢出 | 1 | #5：`parseExpr` 递归链无深度上限（AST 递归侧 `tailValueOf` 同源）。`parseDigits`/`splitTailExpr` 均为单层循环 |
| §5 OOM | 0 | 唯一全量物化是 `Lexer.tokenize()` 的 token 数组，规模由源码长度线性决定、无按报文长度预分配、无无界容器（`PredefinedSnapshot`/`CompiledSourceUnit` 均随单次编译结束释放）；降分配建议见优化方案 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`PerfCompare_test` 只有单次采样），热点结论未成立，已列入待验证假设 1/5 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`Ops.TABLE` 是 `private static let` 只读表，无锁内工作 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`；`SourceCompiler.compile` 每次自建 `CompileSession`/`Lowerer`，无共享串行点 |
| §6.4 低效算法 | 2 | #3（文法歧义使合法表达式不可用，归类于此）、`slotOf` 线性扫描（无数据，已降为待验证假设 5） |
| §7 降堆内存方案 | 2 | 见优化方案「去掉重复的整源规范化副本」「语句数组各留一份」 |
| §8 降 CPU 方案 | 2 | 见优化方案「预定义函数名查找」「删除死字段顺带去掉一次整源哈希」 |
| §9 local mode 可行性 | 0 | 不可行：`Parser` 的 `Array<Token>`、`Array<AstStmt>`、`AstExpr` 全部经返回值逃逸给 `Lowerer`（`SourceCompiler.cj:117-128`），`@local!` 值不得作为 `@ ~local` 返回；且 `String.fromUtf8` / `Lexer.sliceStr` 无 local 重载，逐点重建的改造成本远超收益 |
| §11 现有代码的 BUG（存量） | 17 | 全部 17 条均标 `[存量]`（快照模式无 diff）；本部分 4 个源文件的函数边界、`Option` 取值（`peekAt` 越界回退 EOF）、空集 / 除零分支均已核对 |
| §12 并发安全与锁粒度 | 1 | #6：测试翻转 `SignatureTable.enabled`（`public static var`，运行时无同步读）造成跨线程写读；本部分其余类型无线程共享路径（`Parser`/`SourceCompiler` 每次编译新建，`PredefinedSnapshot` 构造后只读） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；对照 `f_jit/README.md` 的公开面，`Compiler`/`SourceCompiler` 对外能力均已在 README 描述（`README.md:301/318/370` 覆盖插值、`276` 覆盖 `DT_NEW`/`DUR_NEW` 禁发）。#1 的插值内构造调用属实现缺口而非 README 缺段 |
| 文件覆盖（§13 等） | 16/16 | 本部分清单 16 个文件全部读完，无 `.md`；`f_jit/src/compiler` 目录共 59 个文件，其余 43 个不在本部分清单内 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是 f_jit 的 DSL 前端（词法 / 语法 / 名字解析 / 明确赋值 / 管线编排）加 12 个验收测试，共 4 个源文件 2290 行、12 个测试文件 1991 行。**设计意图清晰、注释密度高**（每条不变量都写了"为什么"），`SourceCompiler.compile` 的无状态编排、`PredefinedSnapshot` 的不可变快照、`FuncFlags`/栈效应表的"单一权威"思路都站得住；opcode 常量与 `OpInfo`、`HelperCodec` 与 `HelperId` 我做了逐条机械比对，当前数值完全一致。

风险集中在同一处：**Parser 的回退式文法消歧判得太宽**。`x = (…)` 被吞成多重赋值（#2）、`a / b / c` 被吞成替换段（#3）、插值走裸子解析丢了类注册表且不查尾随 token（#1），三者都不是"数据算错"，而是**合法源码写不出来 / 写出来被静默改写**，属于使用者会立刻撞上的可用性缺陷，建议作为本部分的第一批修复。其次是 `parseDigits` 无范围校验（#4，会突破"编译期错误一律 `SourceCompileException`"的对外契约）与解析器递归无上限（#5，深嵌套源可让宿主进程栈溢出终止；接外部表达式串时应升级为严重）。

死代码与重复集中在 `Ops.cj` 的工具函数（三个判定函数零引用、`CALL_HOST` 表项不可达）、`CompiledSourceUnit` 的两个死字段，以及"换行规范化 4 次 / 两份实现"——都不影响正确性，但注释里描述的两道自检防线（`Ops.agreeWithOpInfo`、`HelperId.isFixed` 守门）实际不存在，建议补一条遍历式用例，否则下一次单边改码表不会有任何提示。测试面本身覆盖了率先要守的行为（三引擎差分、未注册诊断、DA 边界），但存在恒真断言与不看错误码的弱断言（#16），以及会污染全局开关的用例（#6），使"全绿"的信号弱于表面。

阻塞项判断：无（0 条严重）。#1–#4 建议按"功能缺陷"排期修，#5 视调用方是否接外部输入决定优先级；其余轻微项与 4 条优化方案可延后，优化方案在拿到 `cjprof` / 分配量基线前不进修复清单。
