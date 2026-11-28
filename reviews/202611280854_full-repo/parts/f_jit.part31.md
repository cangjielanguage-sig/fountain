# f_jit 模块审查报告（第 31/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/compiler`（本部分 17 个源文件，全部 `.cj`，无 `.md`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 本部分所有问题来源均为「存量」
- **审查重点**：模块专项（typecode/桥接正确性、句柄生命周期、并发、递归与栈溢出、死代码、重复逻辑）+ 通用维度。本部分实际覆盖：词法（`Lexer`）、明确赋值/空安全数据流（`DefiniteAssignment`）、编译会话与产物结构（`CompileSession`）、类注册只读视图（`ClassRegistryView`）、字节码文本转储（`CodeDump`）、诊断出口（`Diag`）、空骨架（`Compiler.cj`）与 9 个测试文件
- **报告版本**：分部分报告 v1（由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

## 发现

### [严重] `DefiniteAssignment.walkExpr` 对 AST 深度无上限递归 → 编译期栈溢出

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:197`（`walkExpr`）、`:219-221`（`Binary` 递归左右子树）、`:241-243`（`Closure` → `analyzeClosureAt` → `walkBlockWithOuter` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 深度上界推导：`Parser.parseAdditive` 等二元层是 `while` 循环（`f_jit/src/compiler/Parser.cj:907-911`），所以 `a + a + a + …` 形成**左深链** `Binary(Binary(…), r)`，节点数 = 运算符个数，而 `walkExpr` 每层递归只下探一个子节点。链条长度由源码长度直接决定，`SourceCompiler.compile` 与 `Lexer`/`Parser` 全链路**没有任何源码长度或 AST 深度上限**（`grep "MAX_\|maxSource" src/Compiler.cj src/CompilePipeline.cj` 无命中）。DA 在管线中先于降低执行（`f_jit/src/compiler/SourceCompiler.cj:124` vs `:128`），因此它是「Parser 成功后第一个全 AST 递归遍历」，溢出点落在本文件而不是 Lowerer
- **描述**：宿主把一段含数万个 `+` 项（或数万层嵌套闭包 / 列表字面量）的源码交给 JIT 时，`walkExpr` 递归深度与项数同阶；按常见 8MB 线程栈与 `walkExpr` 每帧数十~上百字节估算，量级在数万层即可能触顶（**具体阈值未实测**）。后果是栈溢出导致编译进程崩溃，而设计文档要求编译期错误只有一个出口（`SourceCompileException`，`Diag.cj:22-30`），栈溢出绕过了该出口
- **建议**：给 `walkExpr`/`walkStmt` 加显式深度计数（如 `depth: Int64` 形参，超过常量上限抛 `SourceCompileException(CODE_GEN)`）；或改为显式工作栈迭代。同类问题在 `Lowerer` 也存在，建议作为一条统一的「AST 遍历深度上限」改造，而不是只在 DA 打补丁

### [一般] DA 用平铺名字表，和 Lowerer 的块作用域不一致 → 同名遮蔽时既漏拒也误拒

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:83-87`（`walkBlock` 全程共用同一个 `state`）、`:167`（`AstStmt.Block` 直接复用外层 `state`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §10 正确性；对照实现 `f_jit/src/compiler/Lowerer.cj:94-113`（`pushScope`/`popScope` + 只在**同一层**查重名）、`:517-521`（块语句 push/pop 作用域）
- **证据**：静态确定 —— 降低期把 `{ … }` 当独立作用域（同名可遮蔽，仅同层重复定义报错，`Parser.cj:483-486` 允许 `{ … }` 作为独立语句），而 DA 的 `state` 是「名字 → 是否已赋值」的**单层**表，块内声明直接改写外层同名条目
- **描述**：两处偏差方向相反，都可由合法源码触发（`Lowerer` 接受这两种写法）：
  - 漏拒（读到 0 填充）：`{ => var x: Int64\n { let x: Int64 = 1 }\n x }` —— 内层遮蔽声明把 `state[x]` 置 `true`，外层 `x` 的读取被放行；降低期外层 `x` 是另一个槽且从未赋值，读到 prologue 的 0，违反 §3.1「零值填充不可观察」（`doc/jit-bytecode-m1.md:145`）
  - 误拒（合法程序被拒）：`{ => let x: Int64 = 1\n { var x: Int64 }\n x }` —— 内层 `var x` 把 `state[x]` 置 `false`，外层 `x` 的读取报 `NOT_ASSIGNED`
- **建议**：给 DA 引入与 `Lowerer` 对齐的作用域栈（`Array<HashMap<String,Bool>>`，进出块 push/pop；未命中再向外层查），`walkStmt(Binary)` 的 `ForIn`/`While` 体克隆语义保持现状

### [一般] 闭包体遍历与主遍历是两份平行实现且已漂移，闭包内 `for-in` / 多重赋值 / 下标目标 不校验外层捕获

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:350-448`（`walkExprWithOuter`，兜底 `case _ => this.walkExpr(e, state)` 在 `:447`）、`:451-485`（`walkStmtWithOuter`，兜底 `case _ => this.walkStmt(s, state)` 在 `:483`）
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑导致的行为漂移，同一判据必须两处同步）+ §11（契约不符）
- **证据**：静态确定 —— 两处 `match` 的差异点逐个比对：① `AstStmt.ForIn` / `AstStmt.MultiAssign` 无外层版本分支 → 落兜底，用**内层** `state` 走 `walkStmt`，外层名字查不到即 `return`（`:212-218` 的「未声明就放行」）；② `AstExpr.IndexTarget` 同样落兜底；③ `AstExpr.Interp` 两版口径不同（外层版 `:387-390` 遍历全部 parts，主版 `:249-255` 只走奇数下标）
- **描述**：契约要求「捕获未赋值变量 → 编译错误」（`doc/jit-bytecode-m1.md:1152`、T24），且捕获确实由降级期从父作用域解析（`Lowerer.cj:250` `findIn(parent, …)`、`:3324`），说明**读外层名不报错就是被捕获**。于是 `{ => var t: Int64\n let f = { => for (i in [1]) { let _ = t } }\n 0 }` 这类源码不会被 DA 拒绝，闭包捕获到的是未赋值槽的 0 值 —— 正是 §3.1 声明「不可观察」的那个值。差异点的存在意味着两版遍历必须人工同步，后续新增 AST 形态必然继续漏
- **建议**：把两版遍历合并为一版，用「内层/外层两层查找函数」参数化（`lookup: (String) -> ?Bool`），彻底消除平行实现；或至少把兜底分支改成「上报未处理形态」的 `codeFail`，避免静默降级

### [一般] 空安全规则 3 在「赋值语句」路径上恒放行（`typeOf` 被接成常量 `NONE`）

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:495-521`（`checkNullStore`，`:514` 取 `this.typeOf(name)`）、`:102-109`（`Assign` 走 `checkNullStore(n, None, …)`）；接线点 `f_jit/src/compiler/SourceCompiler.cj:120`（`{ _ => LocalType.NONE }`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §14.1（接线缺失）；契约源：本文件 `:32-33`「空安全：句柄型局部恒为有效句柄 ⇒ `PUSH_NULL` 不得作为其赋值源直存」+ `doc/jit-bytecode-m1.md:683`（校验 10）
- **证据**：静态确定 —— `SourceCompiler` 传入的 `typeOf` 是恒返回 `LocalType.NONE` 的闭包（源码注释自认「保守放行」），所以 `Assign` 分支的 `code` 恒为 `NONE`、`LocalType.isHandle(code)` 恒假，该分支**永不报错**；只有 `Decl` 带显式类型注解（`ty: Some`）时才真正生效。Lowerer 侧也不补这道检查（`emit(Op.PUSH_NULL)` 在 `Lowerer.cj:1261-1262`，无目标槽类型校验）
- **描述**：``{ => var o: JsonArray = `[]`\n o = null\n 0 }`` 通过编译并把 0 写进句柄型槽，违反「句柄型局部恒为有效句柄（≠0）」；后续使用该槽只能落到 helper 边界的 0 句柄防御码（6），把编译期错误降级成运行期错误。规则 3 只在「声明即初始化且带注解」这一条窄路径成立
- **建议**：`Assign` 分支同样需要变量的静态类型：把 `typeOf` 接到 Lowerer 已有的槽类型表（`FnCtx.scopes` 的 `VarSym` 带 `LocalType`），或至少在 `Assign` 目标类型未知时改为「查不到就拒」的显式策略，并把 `NONE` 兜底写进注释与规格，避免块注释继续承诺已实现

### [一般] `\u{…}` 码点转义无上界校验，可生成非法 UTF-8，绕过「编译错误唯一出口」

- **位置**：`f_jit/src/compiler/Lexer.cj:550-566`（`escapeLen` 允许 1–6 位十六进制，最大 `0xFFFFFF`）、`:668-685`（`decodeEscapes` 的 `\u` 分支）、`:699-715`（`appendUtf8` 无 `U+10FFFF` / 代理区校验）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验、错误处理不一致）；契约源：`Diag.cj:22-26`「全部失败统一走 `SourceCompileException`」
- **证据**：静态确定 —— `digits > 6` 是唯一上界（`:563`），`appendUtf8` 对 `cp ≥ 0x10000` 直接按 4 字节编码（`:709-714`），对 `0xD800–0xDFFF` 按 3 字节编码，两者都不是合法 UTF-8；`0xFFFFFF` 会编出 `0xFF…` 首字节
- **描述**：`"\u{110000}"` / `"\u{FFFFFF}"` 在词法层被判为合法转义，随后 `String.fromUtf8(out.toArray())`（`:695`）收到非法字节序列，行为取决于标准库（抛非 `SourceCompileException` 异常或替换字符），与「非法转义 → `BAD_ESCAPE`」的既有策略和「唯一出口」契约都不一致；同一段非法字节还会进入常量表
- **建议**：在 `escapeLen` 的 `\u{…}` 分支补 `cp <= 0x10FFFF && !(0xD800..=0xDFFF)` 校验并抛 `DiagKind.BAD_ESCAPE`（与 `digits == 0` 同级），`appendUtf8` 保留为「调用点已保证合法」的内部函数

### [轻微] `ClassRegistryView` 三个成员全模块零引用（对外不可达的 `public`）

- **位置**：`f_jit/src/compiler/ClassRegistryView.cj:185`（`registeredList`）、`:201`（`isHostObjectCode`）、`:206`（`isValueCode`）
- **来源**：存量
- **判据**：review-checklist §1 硬原则二（顶层声明是 `protected class`，其 `public` 成员对外不可达 → 全项目无使用即死代码）
- **证据**：静态确定 —— `grep -rn "isHostObjectCode\|isValueCode\|registeredList" f_jit/src` 只命中定义处本身（`registeredList` 的另外 3 处命中属 `PredefinedSnapshot.cj:101/162/181` 的同名方法，与视图无关）
- **描述**：三者均为诊断/分析辅助，实现完成后没有接线。`registeredList` 与 `PredefinedSnapshot.registeredList` 同名同形，容易被误认为已在错误消息里使用（实际错误消息用的是 `PredefinedSnapshot` 那份）
- **建议**：删除三者；若 `isHostObjectCode` / `isValueCode` 是给 Lowerer 预留的类型码判定，改为在 Lowerer 内直接比较 `LocalType` 常量并补用例，不要留悬空 API

### [轻微] `Lexer` 两处不可达分支（恒定不成立）

- **位置**：`f_jit/src/compiler/Lexer.cj:466-468`（`scanRawString` 的 `if (hashes < 1)`）、`:515-519`（`findBodyEnd` 三引号分支里的 `oddBackslashesBefore` 判定）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支 / 不可达语句）
- **证据**：静态确定 —— ① `scanRawString` 只由 `scanOne` 在 `bs[cur] == '#'` 时分派（`:260-262`），进入时 `hashes ≥ 1`；② `findBodyEnd` 每遇到 `\` 就用 `escapeLen` 连吃 ≥2 字节（`:507-509`，返回值恒 ≥2），所以游标 `p` 不可能停在一个「前一个字节是反斜杠」的引号上，`oddBackslashesBefore` 恒为 `false`
- **描述**：两处都是防御性写法但当前扫描路径下不可达，会让读者误以为存在「转义后不终止」的路径；`oddBackslashesBefore` 还引入了一次不必要的反向扫描
- **建议**：删除 `hashes < 1` 与 `oddBackslashesBefore` 调用；若担心未来扫描路径变化，改为注释说明「当前不可达，保留原因」

### [轻微] `f_jit/src/compiler/Compiler.cj` 是只剩 `package` 与占位注释的空骨架文件

- **位置**：`f_jit/src/compiler/Compiler.cj:16-18`
- **来源**：存量
- **判据**：review-checklist §1（兼容残留）/ §3（空实现）
- **证据**：静态确定 —— 文件仅 `package fountain::f_jit.compiler` 与一行「P0 骨架占位」注释，无任何声明；真正的门面是 `f_jit/src/Compiler.cj:34`（`public class Compiler`），`grep "compiler.Compiler" f_jit/src` 无命中
- **描述**：同一模块内存在同名文件（`src/Compiler.cj` 与 `src/compiler/Compiler.cj`），且后者内容为空，检索/阅读时极易走错；对构建也没有任何贡献
- **建议**：删除该文件（或改成真正的包级文档注释文件并明确它是文档而非骨架）

### [轻微] `checkNullStore` 的 `TypeRef → LocalType` 映射与 `TypeRef.code()` 完全重复，且用裸字面量

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:504-513`；既有实现 `f_jit/src/compiler/Ast.cj:90-102`（`TypeRef.code()`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑 / 字面量复制）
- **证据**：静态确定 —— 两段 `match` 分支一一对应（`Builtin(c)`、`AnyT`、`ListOf`、`MapOf`、`HostClosureT(_,_,_,_)`、`HostObjectT(_)`），返回码也相同；DA 侧还把 `15/10/11/13/14` 写成裸字面量，而 `LocalType.ANY/LIST/MAP/HOST_CLOSURE/HOST_OBJECT`（`f_jit/src/base/LocalType.cj:50-63`）已有同名常量
- **描述**：同一映射两处维护；`TypeRef` 增删变体时两处都必须改（编译器会因 `match` 非穷尽报错，不会静默漂移，但改动成本与误读成本翻倍）
- **建议**：`checkNullStore` 改为 `case Some(v) => code = v.code()`，删掉本地 `match`

### [轻微] `DefiniteAssignment.analyze` 返回恒为 `true` 的 `Bool`，三处调用全部丢弃

- **位置**：`f_jit/src/compiler/DefiniteAssignment.cj:66-77`（`:76` 直接 `true`）；调用点 `f_jit/src/compiler/SourceCompiler.cj:124`、`f_jit/src/compiler/Semantics_test.cj:184`、`f_jit/src/compiler/AstM2_test.cj:72`（后两处忽略返回值，前者写 `let _ =`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 返回类型无意义）
- **证据**：静态确定 —— 函数体唯一出口是 `true`，失败一律抛异常；三个调用点没有一个使用返回值
- **描述**：`Bool` 返回类型暗示「通过/不通过」，实际语义是「不抛即通过」，容易诱导调用方写 `if (analyze(...))`
- **建议**：改为 `Unit`，并同步三处调用点（`SourceCompiler.cj:124` 的 `let _ =` 可一并去掉）

### [轻微] `DiffExec_test.cj` 存在未使用的 import

- **位置**：`f_jit/src/compiler/DiffExec_test.cj:21`（`import fountain::f_jit.test.diff.AArch64Runner`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `DiffSession([InterpRunner(), NativeRunner()])`（`:67`、`:134`、`:144`），全文无 `AArch64Runner` 标识符
- **描述**：AArch64 差分由 `NativeRunner` 内部按平台选择，这个 import 是旧写法的残留；注释（`:28-31`）仍在描述 `AArch64Runner` 的「跳过」语义
- **建议**：删除该 import，并把注释改成指向 `NativeRunner`/`DiffSession` 的跳过口径

### [轻微] `CodeDump` 的逐行转储对截断字节流没有边界检查

- **位置**：`f_jit/src/compiler/CodeDump.cj:98-110`（`operandsOf`）、`:165-187`（`u16At`/`i32At`/`i64At` 直接读 `bs[off + k]`）、`:40-48`（`p = p + info.len` 不做 `p + info.len <= code.size` 校验）
- **来源**：存量
- **判据**：review-checklist §11（边界越界）
- **证据**：静态确定 —— `dump`/`ops` 只按 `info.len` 前移，`operandsOf` 对 `i64` 读 `code[p+1..p+8]`、对 `u16 u8` 读 `code[p+3]`，均未比较 `code.size`；`OpInfo` 表内没有 `len = 0` 项（`grep "len: 0" src/bytecode/OpInfo.cj` 无命中），因此不会死循环，但会越界
- **描述**：`CodeDump` 是「字节码断言/诊断」工具（`:22-32`），恰好在产物异常（被截断）时要使用；此时它会抛索引越界异常，把「产物不合法」伪装成工具崩溃。生产侧只有 `CodeDump.hex([op])` 被调用（`BytecodeBuilder.cj:457/461`），不受影响
- **建议**：`dump`/`ops` 在 `p + info.len > code.size` 时输出 `<truncated @p>` 并中断；`operandsOf` 先判 `code.size - p >= info.len`

### [轻微] `Lexer.tokenize` 的注释与生产调用不符（「生产路径只用 `next()`」）

- **位置**：`f_jit/src/compiler/Lexer.cj:100-111`
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 生产路径 `f_jit/src/compiler/Parser.cj:52` 就是 `this.ts = Lexer(this.src).tokenize()`，即 Parser 一次性物化全量 token（前瞻需要，`looksLikeClosure`/`looksLikeMapLiteral` 都基于 `this.ts`）
- **描述**：注释会让读者以为 `tokenize` 可以随时删除或改签名，实际上它是 Parser 的唯一入口；也掩盖了「每次编译物化全量 `Token` 数组」这一内存特征（见「优化可行性方案 · 堆内存」）
- **建议**：改写为「Parser 批量取词（前瞻需要）；`next()` 供流式/单测使用」

### [轻微] 可见性建议：`Lexer` 的 4 个访问器仅被测试引用

- **位置**：`f_jit/src/compiler/Lexer.cj:62`（`position`）、`:67`（`line`）、`:72`（`column`）、`:77`（`lastRegexFlags`）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用 → 可提可见性建议，不判死代码」
- **证据**：静态确定 —— `grep "\.position()\|\.line()\|\.column()" f_jit/src` 只命中 `Lexer_test.cj:304-306`；`lastRegexFlags` 只命中 `Lexer_test.cj:506/510/514/518`（`Lexer.cj:771-772` 的注释已说明 flags 改为随 `Token.flags` 送出）
- **描述**：`Lexer` 是 `internal class`，这 4 个 `public` 成员实际上只服务测试；`lastRegexFlags` 更是被 `Token.flags` 取代后的兼容面
- **建议**：`lastRegexFlags` 直接删除（并改测试断言 `ta.flags`）；`position/line/column` 若要保留为诊断辅助，建议加注释说明「仅测试/诊断」——**不建议**在不确认下游的情况下改可见性

## 优化可行性方案

### [CPU] 源码换行规范化在一次编译里被执行 4 次

- **现状**：`Lexer.normalizeNewlines`（`f_jit/src/compiler/Lexer.cj:123-140`）每次调用都重扫全串并按字节 `ArrayList<UInt8>` 追加，再 `toArray()` + `String.fromUtf8`（≈ 1 份新串 + 1 份临时数组）。一次 `SourceCompiler.compile` 里被调用 4 次：`SourceCompiler.cj:115` → `Parser.cj:51` → `Lexer.cj:57` → `PredefinedSnapshot.cj:141`（`NameResolver`）→ `DefiniteAssignment.cj:51`，入参都已经是同一份已规范化串
- **方案**：规范化只在 `SourceCompiler.compile` 入口做一次，后续构造改为接收「保证已规范化」的串（新增 `normalized: Bool = true` 形参或独立 `Lexer.normalized(src)` 工厂），保留 `Lexer(source)` 的兜底规范化以免破坏现有调用方
- **预期**：每次编译少 3 次全串复制（≈ 6n 字节的临时分配 + 3 次逐字节分支扫描）；对 100KB 源码量级约为每编译 0.6MB 冗余分配。**端到端收益未测**
- **代价**：多一个「调用方必须保证已规范化」的隐式契约，需要在 4 个构造点注释说明；语义零变化（规范化幂等）
- **验证**：`cjpm bench -O2`（同 SDK/同机）对 10KB / 100KB / 1MB 源码各跑 20 轮取中位数，对照编译耗时与 `getAllocatedHeapSize()` 增量；同时跑 `Lexer_test.newlinesAreNormalizedInEveryForm` 等既有用例确认字节不变
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 全量 `Token` 物化 + 每 token 一份 `String` 拷贝

- **现状**：`Parser.cj:52` 用 `tokenize()` 一次性持有全部 token；每个 `Token.text` 由 `Lexer.sliceStr`（`Lexer.cj:894-904`）新建 `Array<UInt8>` 再 `String.fromUtf8`，即每个 token 至少 2 次分配（临时数组 + 字符串）。n 字节源码约 n/4 个 token，峰值堆 ≈ 常数 × n，且全部活到解析结束
- **方案**：`Token` 改为持有 `(start, end)` 字节偏移 + 按需切片的访问器（`text()` 惰性构造，或直接返回 `String` 子串视图），`Lexer` 只对需要解码的形态（字符串字面量 `decodeEscapes` 之后）保留实串；`Parser` 的前瞻只读 `kind`，不受影响
- **预期**：峰值堆下降与「token 平均长度 / 单 token 固定开销」同阶（**估算 30%–50%，无实测**）；短源码（<4KB）收益可忽略
- **代价**：`Token` 结构变更波及 Parser / Lowerer / 测试中所有 `t.text` 读取点；`decodeEscapes` 后的串仍需实串（两种表示并存）；错误消息需要用源码 + 偏移现场切片
- **验证**：对 1MB 源码跑 20 轮编译，记录 `getAllocatedHeapSize()` 峰值与 RSS 峰值，改前改后对照（`-O2`，同机）；同时用 `Lexer_test`/`JsonLit_test` 全量用例守字节等价
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DefiniteAssignment` 的分支整表克隆（`clone`/`intersectInto`/`snapshotKeys`，每次 `if`/循环迭代分配一个 `HashMap` + 数组）是编译期分配热点 | `f_jit/src/compiler/DefiniteAssignment.cj:131-191`、`:527-568` | 该阶段自耗时占比与分配量 | `cjprof record` 编译 100 个含分支/循环的 lambda，看 `DefiniteAssignment.*` 的 self time；同时统计 `getAllocatedHeapSize()` 增量 |
| 2 | 4 次换行规范化的耗时在编译总耗时中占比 <5%（即上条方案收益有限） | `Lexer.cj:123`、`SourceCompiler.cj:115`、`Parser.cj:51`、`PredefinedSnapshot.cj:141`、`DefiniteAssignment.cj:51` | 分段计时 | 在 5 个调用点插桩累计耗时，跑 1MB 源码 20 轮取中位数 |
| 3 | DA 的 `HashMap<String,Bool>` 字符串键哈希/比较是长函数分析的主要成本（可换 `Int64` 槽位索引） | `DefiniteAssignment.cj:67-70`、`:205-218` | 单次 `analyze` 耗时随局部变量数的增长曲线 | 构造 100/1000 个局部变量的 lambda，`cjprof` 看 `state.get`/`hash` 占比 |
| 4 | 上述 DA 临时结构适合 local mode（`state`、分支克隆、`snapshotKeys` 数组均在函数内创建并随 `analyze` 返回销毁，无逃逸） | `DefiniteAssignment.cj:66-77` | 峰值内存对照 + `--enable-local-mode` 可用性 | 先确认 `std.collection.HashMap` 有 local 构造重载；再测 `getAllocatedLocalObjectSize()` 与 RSS 峰值（需 `-O2`、同输入） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/compiler/ClassRegistryView.cj` | .cj | ✅ | 见发现「死代码 3 成员」；`classOf/isRegistered/fieldOf/methodOf/methodsOf/ctorsOf/require*` 均在 `Lowerer.cj` 有调用 |
| 2 | `f_jit/src/compiler/ClassRegistryView_test.cj` | .cj | ✅ | 用例与实现一致（快照隔离、继承仅按表项）；`userDescriptor/addressDescriptor` 为 `internal` 且有调用 |
| 3 | `f_jit/src/compiler/CodeDump.cj` | .cj | ✅ | 见「逐行转储无边界检查」；`dump/ops/hex` 均有真实调用（`hex` 还在生产路径） |
| 4 | `f_jit/src/compiler/CompileCopy_test.cj` | .cj | ✅ | 拼接契约用例完整（长度/偏移/fnId/entry 反查）；无问题 |
| 5 | `f_jit/src/compiler/CompileSession.cj` | .cj | ✅ | `FuncBody/PendingSite/LoweredFunc/CompileSession` 全部成员在 `Assembler`/`Lowerer`/`SourceCompiler` 有使用；无死代码 |
| 6 | `f_jit/src/compiler/Compiler.cj` | .cj | ✅ | 空骨架，见发现 |
| 7 | `f_jit/src/compiler/ConstantReclaim_test.cj` | .cj | ✅ | 句柄账目用例；`resetForTest/initialCapacity/capacityLimit` 均为测试面 API |
| 8 | `f_jit/src/compiler/DefiniteAssignment.cj` | .cj | ✅ | 本部分主要问题集中处（栈溢出 / 作用域 / 平行遍历 / 空安全接线 / 重复映射 / 恒真返回值） |
| 9 | `f_jit/src/compiler/Diag.cj` | .cj | ✅ | `diagFail` 两个重载、`lineTextAt`、`codeFail`、`notImplFail` 均有调用；无问题 |
| 10 | `f_jit/src/compiler/DiffExec_test.cj` | .cj | ✅ | 见「未使用 import」；用例覆盖常量/分支/F64/NaN/错误码 |
| 11 | `f_jit/src/compiler/Golden_test.cj` | .cj | ✅ | 4 条 `.fbc` 指纹金样；`fp`/`DOLLAR` 均被使用，无问题 |
| 12 | `f_jit/src/compiler/JitWire_test.cj` | .cj | ✅ | `release()` 幂等断言；无问题 |
| 13 | `f_jit/src/compiler/JsonAccess_test.cj` | .cj | ✅ | 重载组 `compileM3/run/resultOf/errKind` 各有调用；无死代码。`TCase.hit` 有重复编译（`:55`/`:124` 同一表达式算两遍），仅测试成本，不单列 |
| 14 | `f_jit/src/compiler/JsonCode_test.cj` | .cj | ✅ | 私有工具 `hasType` 有调用；无问题 |
| 15 | `f_jit/src/compiler/JsonLit_test.cj` | .cj | ✅ | 与 `Lexer.scanJson` 口径一致（反引号取界、CRLF 规范化、空体走 H83）；无问题 |
| 16 | `f_jit/src/compiler/Lexer.cj` | .cj | ✅ | 见「不可达分支」「`\u{}` 上界」「`tokenize` 注释」「可见性建议」 |
| 17 | `f_jit/src/compiler/Lexer_test.cj` | .cj | ✅ | 60 项 kind 全表 + 词法错误族逐 kind；`expectLexError` 为文件级 `private` 且有调用 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | DA 作用域不一致、DA 弃用返回值、空安全接线、`\u{}` 上界、`tokenize` 注释；分层（前端/降低/汇编）与依赖方向无违规；本部分无外部输入拼接、无凭据 |
| §1 死代码 | 4 | 已逐个 `private`/`internal`/`protected`/对外不可达 `public` 搜引用：`ClassRegistryView.registeredList/isHostObjectCode/isValueCode` 零引用（对外不可达）；`Lexer` 两处恒假分支；`Compiler.cj` 空文件；`DiffExec_test` 未用 import。另：`Lexer.position/line/column/lastRegexFlags` 仅测试引用 → 记为可见性建议不判死代码；`CodeDump`、`CompileSession` 全部成员、`Diag` 四个出口、`dedentAnchored/emitAnchoredLine/sliceStr/decodeEscapes/hex2/normalizeNewlines` 均有调用 |
| §2 重复逻辑 | 3 | ① `walkExpr`/`walkExprWithOuter`（+`walkStmt`/`walkStmtWithOuter`）两份平行遍历且已漂移；② `checkNullStore` 的 `TypeRef→码` 映射与 `TypeRef.code()` 逐分支重复；③ 同一 `normalizeNewlines` 每次编译被调 4 次（记入 CPU 方案）。测试文件的准备代码（各 `_test.cj` 的 `compileM3/errKind` 模板）属刻意独立，不判重复 |
| §3 空实现 | 2 | `Compiler.cj` 空骨架；DA 空安全规则 3 在赋值路径上等价于空实现（已并入发现）。`DummyDiagnosticsSink` 是设计内的 null object（有文档说明），不判 |
| §4 栈溢出 | 1 | `walkExpr` 无深度上限（严重）。`Lexer.findBodyEnd/skipInterp`、`dedentAnchored`、`escapeLen` 均为迭代实现，无递归；`analyzeClosureAt` 的递归深度并入同一发现 |
| §5 OOM | 0 | 无全量读入、无按不可信长度预分配；唯一无界物化是 Parser 的 `Token` 数组，规模由源码长度线性决定，记入堆内存方案而非 OOM 缺陷 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据；全部性能线索（规范化重复、HashMap 克隆、token 物化）已进「待验证假设」，不作热点结论 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁（`Lexer`/`DefiniteAssignment`/`CompileSession` 均为单次编译内对象） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`；无并发窗口配置 |
| §6.4 低效算法 | 1 | `CodeDump.dump/ops` 的 `out = out + …` 循环拼接与 `DefiniteAssignment.sameKeys` 的 O(n²) 集合比较：仅在测试/极小集合上运行，未列为缺陷；`ClassRegistryView.classOf` 线性扫描在有 `requireField/requireMethod` 里被重复调用一次（同一 `classOf` 跑两遍），量级为类数×成员数，无数据支撑，不列 |
| §7 降堆内存方案 | 1 | Token 物化 + 每 token 两次分配（已给方案，无基线） |
| §8 降 CPU 方案 | 1 | 换行规范化 4 次（已给方案，无基线） |
| §9 local mode 可行性 | 1 | DA 的每分支 `HashMap` 克隆与 `snapshotKeys` 数组是典型「函数内创建、函数内销毁」，但缺峰值内存数据，只进「待验证假设 #4」；未确认 `HashMap` 的 local 构造重载 |
| §11 现有代码的 BUG（存量） | 4 | DA 作用域、DA 空安全接线、`\u{}` 上界、`CodeDump` 越界；另核对 `Diag.lineTextAt`（越界返回空串，正确）、`CompileSession.funcAt`（越界 `diagFail`，正确）、`Lexer.at()`（负/越界返回 0，正确）、`Lexer.scanNumber` 各分支（`1..2`/`1.2.3`/`3e`/`12abc` 均按预期分类） |
| §12 并发安全与锁粒度 | 0 | 线程封闭论证：`Lexer`/`DefiniteAssignment`/`CompileSession`/`ClassRegistryView` 都在 `SourceCompiler.compile` 内构造并只被该调用使用；`ClassRegistrySnapshot` 构造时 `clone()` 入参数组；本部分无 `static var`/单例可变字段。故不判共享可变状态 |
| §14 功能完备性与 README 覆盖 | 1 | 空安全规则 3 的接线缺失（并入发现）；本部分不含 `.md`，无可对照的 README 段落，专项覆盖在模块其余部分 |
| 文件覆盖（§13 等） | 17/17 | 全部读完；本部分无 `.md`，§13 文档一致性不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分（词法 + 明确赋值数据流 + 编译会话 + 类注册视图 + 转储工具 + 9 个测试）代码密度高、注释质量好，测试覆盖是这批文件里最强的部分：`Lexer_test` 对 60 个 `TokenKind` 做穷尽构造、词法错误族逐 kind 一条用例，`CodeDump` 把断言口径统一成字符串，`CompileCopy_test`/`Golden_test` 把产物字节固定成契约。`CompileSession`/`Diag`/`CodeDump` 三个文件基本没有可挑的问题：成员全部有调用方，防御性拷贝与错误出口的注释都能对上实现。

风险集中在 `DefiniteAssignment.cj` 一个文件：它是本轮唯一的**严重**项来源（对 AST 无深度上限递归，长运算符链/深嵌套在数万层量级即可打爆编译栈），也是四条「一般」里两条的来源——`walkExpr` 与 `walkExprWithOuter` 两份平行遍历已经漂移（闭包内 `for-in`/多重赋值/下标目标不查外层，捕获未赋值变量被静默放行），状态表又是平铺名字表，与 `Lowerer` 的块作用域不一致（同名遮蔽时两个方向都能出错：放行读到 0、或误拒合法程序）。这三条建议合并成一次改造：作用域栈 + 单一遍历 + 深度计数，改完再用 T24 的捕获用例补反向断言。

另一条「一般」是空安全规则 3 的接线空洞（`typeOf` 被常量 `NONE` 短路，`o = null` 能写进句柄槽），属于「注释承诺了、实现只在窄路径成立」，应连同 `Lowerer` 的槽类型表一起补齐或明确降级。最后一条「一般」（`\u{…}` 无上界）会产出非法 UTF-8 并绕过唯一错误出口，属易修的小口子，建议与 `escapeLen` 的其它校验一起补。

9 条「轻微」全部是可机械验证的清理项（3 个零引用成员、2 处不可达分支、空骨架文件、重复的 `TypeRef→码` 映射、恒真返回值、未用 import、`CodeDump` 越界、注释与实现不符、4 个仅测试访问器），可以一次性排进治理批次。两条优化方案（规范化重复 4 次、全量 token 物化）都缺改前基线，按规则只作「待验证假设」，不进修复清单。

**存量合计 14 条（1 严重 / 4 一般 / 9 轻微）**，均为工作区快照下的既有问题（`git diff` 为空，无本次改动引入项）；是否纳入修复待用户决定。
