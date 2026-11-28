# f_macros 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_macros`（模块共 22 个 `.cj` + 2 个 `.md`；本部分 4 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 可比；本部分所有问题来源均为「存量」）
- **审查重点**：宏展开正确性、带注解成员的处理、空实现、死代码、重复逻辑、存量 BUG（本部分专门针对 §1 死代码 / §2 重复逻辑做了机械排查）
- **报告版本**：v1（模块第 2/2 部分，与 `reviews/202611280854_full-repo/parts/f_macros.part1.md` 由主 Agent 合并；本文件只统计本部分文件）

## 发现

### [严重][存量] `withAnnotation<T>` 比对对象错位，对任何声明恒返回 `false`（README 承诺失效）

- **位置**：`f_macros/src/hasAnnotation.cj:20-29`（核心判据在 `:23`）
- **来源**：存量 —— 快照模式无基线；`git log -S` 溯源到回归提交 `ae07b888d`（2025-05-28，提交信息是「fix Bean postConstruct destroy函数的闭包实现」，与注解判定无关）：它把 `66d39a161`（2025-05-09）的正确实现 `TypeInfos.get<T>().qualifiedName.endsWith('.${d.fullIdentifier.value}')`（拿 **T 自己的全限定名** 与声明的宏名比）替换成遍历 `T` 自身的 annotations；其后的 `f5140a042` / `4ad58a8b0` / `3b28d242d` 只改类型引用与 import，错误判据一直保留至今
- **判据**：review-checklist §11（契约与实现不符、语义与命名不符）；§3（公开契约承诺有行为、实际不产生有效行为）
- **证据**：静态确定 ——
  1. std 文档 `reflect/reflect_package_api/reflect_package_classes.md:13020-13034`：`TypeInfo.annotations` 的语义是「获取所有作用于**该 TypeInfo 对应的类型**的自定义注解」，示例为 `TypeInfo.of<TestClass>().annotations` 取到 `@MyAnnotation`。因此 `TypeInfo.of<T>().annotations` 拿到的是「**注解类 T 自己被谁标注**」，与入参 `decl` 无关。
  2. 循环条件 `ClassTypeInfo.of(a).name == d.fullIdentifier.value` 里，左边是「标注在 T 上的注解的类名」，右边是「decl 的宏名文本」。`T` 是 `Annotation` 子类，正常只会被 `@Annotation` 标注，故只有 `decl` 恰好叫 `Annotation` 时才可能为 `true`。
  3. 反证：正确语义（README `f_macros/README.md:115`「判断声明是否带指定注解/宏」）应以 `TypeInfo.of<T>().name` / `qualifiedName` 与 `d.fullIdentifier.value` 比对，这是 `66d39a161` 的写法。
- **描述**：函数承诺「`decl` 是否带注解 `T`」，实际回答「注解类 `T` 身上是否有一个类名等于 `decl` 宏名的注解」。任何 `withAnnotation<PostConstruct>(quote(@PostConstruct func f()))` 都会返回 `false`，且是静默 `false`（没有异常、没有日志），调用方会安静地跳过本该生成的代码。仓内当前**没有**调用者（`grep -rn "withAnnotation(" --include=*.cj` 除定义外 0 命中；最后一批调用点在 `6f4692f87`「简化ioc的实现」迁到 `f_base` 的 `TypeInfos.withAnnotation`，见 `f_base/src/TypeInfos.cj:73-75`），所以今天不产生线上影响，但它是 `public` 契约且被 README 列出，下游按文档调用即中招。
- **建议**：二选一，并同步 README：① 修复为 `TypeInfo.of<T>().qualifiedName.endsWith('.${d.fullIdentifier.value}')`（兼容源码里写非限定名与 `pkg.Anno` 两种写法），同时只处理 `d: MacroExpandDecl`；② 若确认该 API 已被 `f_base.TypeInfos.withAnnotation` 取代，删除 `withAnnotation` 并去掉 `README.md:115` / `README_en.md` 对应条目（对外可达的 `public` 删除属契约变更，需用户拍板）。无论哪种，都应补用例：`@A func`、`@pkg.A func`、`@A @B func` 三种输入。

### [一般][存量] `isModifier` 系列不解包 `MacroExpandDecl`，带自定义注解的声明一律判 `false`

- **位置**：`f_macros/src/isModifier.cj:18-107`（11 个 `Tokens` 重载全部经 `parseDecl(tokens)` 直取修饰符）、`f_macros/src/isModifier.cj:22-24`、`:40-45`、`:54-65`、`:79-107`（`Decl` 重载同样只看 `decl.modifiers`）
- **来源**：存量（快照模式无基线；文件最近一次实质变更为 `6c6b133a1`）
- **判据**：review-checklist §11（语义与命名不符、边界未处理）；本轮重点「带注解成员的处理」
- **证据**：静态确定 —— std 文档 `ast/ast_package_api/ast_package_classes.md:9154-9174` 明确 `MacroExpandDecl` 节点就是 `@M class A {}`，`fullIdentifier` 为宏名；因此 `parseDecl(quote(@Foo static func f()))` 得到的是 `MacroExpandDecl`（`modifiers` 为空），`isStatic(tokens)` 返回 `false`，而不是 `true`。同一份 `Tokens` 先 `extract()` 再判定就正确，说明差异只来自是否解包。
- **描述**：`Tokens` 重载的语义是「我手上有一段声明源码，它是不是 static/public」，而 f_macros 自己的 `extract`（`extract_macro_expand.cj:20-26`）证明「带注解的声明外层一定套了一层 `MacroExpandDecl`」。两者组合使用时，带注解成员会被静默判成「无修饰符」。仓内已有这种误判的真实形态：`f_data/src/macros/DataAssist.cj:460-461` / `:471-472` 用 `field is VarDecl && !(isStatic(field) || …)` 过滤字段，`field is VarDecl` 会先把 `@DataExclude var x` 这类带注解字段整体排除掉（范围外提示，f_data 的问题另计）。另：同一函数族对 `Tokens` 输入不做空串检查，`parseDecl` 在空 `Tokens` 上抛 `ParseASTException`（`ast/ast_package_api/ast_package_funcs.md:444-446`），即「谓词函数会抛异常」。
- **建议**：给 `Tokens` 重载加一层解包：`let d = parseDecl(tokens)`，若 `d is MacroExpandDecl` 则 `extract(d as MacroExpandDecl)` 后再取 `modifiers`；README `:100-102` 明确写「会穿透注解宏」。若坚持「不解包、由调用方 `extract`」，至少把这条前提写进 README，并把 `Tokens` 重载的空输入改为返回 `false` 而不是抛 `ParseASTException`。

### [一般][存量] `withMacro` 与 `extract(decl, macroName)` / `extractIfOneOf` 重复，且嵌套语义不一致

- **位置**：`f_macros/src/hasAnnotation.cj:31-36`；对照实现 `f_macros/src/extract_macro_expand.cj:28-41`、`:43-56`
- **来源**：存量（快照模式；`withMacro` 自 `66d39a161` 起未变，调用方已在 `6f4692f87` 迁走）
- **判据**：review-checklist §2（重复逻辑 / 只改入口形状）；严重度表「重复逻辑导致的行为漂移」
- **证据**：静态确定 —— `withMacro` 的判定式 `d.fullIdentifier.value == macroName` 与 `extract(decl, macroName)` 的 `m.fullIdentifier.value == macroName`（`:32`）逐字相同；差别只在遍历范围：`extract` 用 `while (let m: MacroExpandDecl <- d) { … d = m.macroInputDecl }` 走完整条宏链，`withMacro` 只看最外层。
- **描述**：`@A @B var x` 这种多重注解（外层 `@A`、内层 `@B`，即两层 `MacroExpandDecl`）下，`withMacro(decl, "B")` 返回 `false`，而 `extract(decl, "B").isSome()` 返回 `true`。同一问题在模块内有两个答案，使用户无法判断该信哪个；README `:115` 的措辞「判断声明是否带指定注解/宏」偏向「任意一层都算」，与 `withMacro` 行为相反。另外两处都只做**标识符文本比对**，不处理限定名（源码写 `@f_bean.Bean` 时 `fullIdentifier.value` 是 `f_bean.Bean`，传 `"Bean"` 匹配失败），这个前提同样没有文档。
- **建议**：删除 `withMacro`，调用方改用 `extract(decl, macroName)?.isSome() ?? false`（或 `extractIfOneOf`）；确实需要「仅最外层」语义时把函数改名为 `withOuterMacro` 并写明。限定名匹配统一走一个 `matchMacroName(full: String, name: String): Bool`（`full == name || full.endsWith(".${name}")`），避免 `extract` / `withMacro` / `withAnnotation` 三处各写一份。

### [一般][存量] `isInternal` 有两套语义不同的实现（显式修饰符 vs 取反推断）

- **位置**：`f_macros/src/isModifier.cj:63-65`（`isModifier(decl.modifiers, INTERNAL)`）；`f_macros/src/CompositeDecl.cj:33-35`（接口默认实现 `!(isPublic() || isProtected() || isPrivate())`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同名不同语义 / 实现漂移）；§11（契约不符）
- **证据**：静态确定 —— 仓颉里「不写可见性修饰符」等价于 `internal`；`isModifier.cj:63` 只匹配显式的 `internal` 关键字，`CompositeDecl.cj:33` 走取反。对 `var x: Int64`（无修饰符）两者结论相反：自由函数 `false`，接口方法 `true`。`grep -rn "isInternal(" --include=*.cj` 显示仓内无 `isInternal(decl)` 调用者，接口方法也只有定义。
- **描述**：两个同名 API 对同一个声明给出相反答案，且都没有文档说明差别。`isPublic`/`isPrivate`/`isProtected` 的取反式实现是「缺省即 internal」的正确表达，显式匹配式则是「必须有 internal 关键字」，前者符合语言语义。
- **建议**：`isModifier.cj:63-65` 改为 `!isPublic(decl) && !isProtected(decl) && !isPrivate(decl)`（与 `CompositeDecl.cj:33` 一致），或删掉自由函数只保留接口方法。第 1 部分已从 README 角度记录同一根因（`f_macros.part1.md` 的「README 两处与实现不符」），合并时二者取一即可，本条给出代码侧修法。

### [轻微][存量] `topMacroAnonymousClosure` 生成代码依赖未限定的 `Exception`，存在宏卫生问题

- **位置**：`f_macros/src/topMacroAnonymousClosure.cj:26`（`Exception($(tokens.toString()), e).printStackTrace()`）
- **来源**：存量（快照模式无基线；该行由 `091b6d466`「优化异常处理日志记录」引入）
- **判据**：review-checklist §10（语言特性 / 宏展开正确性：生成代码在用户作用域里做名称解析）
- **证据**：待确认 —— 缺的是「用户包内是否存在同名 `Exception` 遮蔽」这一信息；条件成立时后果是静态确定的：宏生成的是原样 token，`Exception` 与 `printStackTrace` 都在**调用方文件**的作用域里解析；仓颉会按「本包声明优先于导入」解析名字（`docs/dev-guide/source_zh_cn/package/import.md:291` 明确存在「被遮盖导致本包不可用」的情形），用户包内若有同名 `Exception`，`Exception(...)` 会解析到用户类型，`(String, Exception)` 构造或 `printStackTrace()` 不存在 → 展开后的代码编译失败，报错位置落在用户文件而非宏，很难定位。
- **描述**：同文件其余部分都不依赖用户作用域（`private let _`、`{=>}`、`try/catch` 都是关键字），只有 `Exception(...)` 与 `.printStackTrace()` 两个名字是外来符号。当前 5 个调用点（`f_bean/src/macros/Configuration.cj:53`、`f_bean/src/macros/Bean.cj:80`/`:100`、`f_mvc/src/macros/Controller.cj:78`、`f_jsonrpc/src/macros/JsonRpc.cj:182`）所在包都没有遮蔽 `Exception`，所以暂未触发。
- **建议**：把包装逻辑收进 f_macros 的普通函数并在生成代码里调用限定名，例如生成 `fountain::f_macros.reportMacroFailure($(tokens.toString()), {=> $tokens})`，由该函数统一做 catch / 打印 / 重抛；这样用户作用域只需要能解析 f_macros 一个包名。

### [轻微][存量] `imports.cj` 的包级 `public import` 造成隐式依赖，且重导出行为未进 README

- **位置**：`f_macros/src/imports.cj:18-20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可维护性：依赖不可见）；§14（公开 API 未文档化）
- **证据**：静态确定 —— 语言文档 `docs/dev-guide/source_zh_cn/package/import.md:291-296`：`internal import` 使导入内容「在当前包及其子包均可访问」，`public import` 使「外部都可访问」。因此 `hasAnnotation.cj` 能直接用 `Decl` / `MacroExpandDecl` / `Annotation` 而**没有任何 import**（`hasAnnotation.cj:18` 只导入了 `std.reflect.{ClassTypeInfo, TypeInfo}`），`extract_first_token.cj:25` 能直接用 `MacroFragmentException` 也是靠 `:20` 那行 `internal import`。`grep -n "std.ast" f_macros/README.md f_macros/README_en.md` 零命中，即「f_macros 公开重导出了整个 std.ast」这件事没有任何文档。
- **描述**：① 阅读任一文件时看不到它依赖 std.ast，删改 `imports.cj` 会引发其它文件的编译错误，而报错点与被改文件无关；② 下游 `import fountain::f_macros.*` 会连带拿到 `std.ast` 全部符号，与用户自己 `import std.ast.*` 叠加时可能产生「同一符号多重导入」的告警/歧义，而 README 对此零说明。
- **建议**：`imports.cj` 保留但加文件级注释说明「本文件是包级重导出入口，勿删」；README 补一段「`f_macros` 重导出 `std.ast`，宏包使用者只需 `import fountain::f_macros.*`」，中英同步。

### [轻微][存量] 文件名 `hasAnnotation.cj` 与内容不符，且 `isAbstract(Decl)` 与 `isSealed(Decl)` 同语义两套写法

- **位置**：`f_macros/src/hasAnnotation.cj:1-36`（文件内无 `hasAnnotation` 符号）；`f_macros/src/isModifier.cj:30-32` 与 `:40-45`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性 / 命名）；§2（近似重复）
- **证据**：静态确定 —— `hasAnnotation.cj` 只定义 `withAnnotation` / `withMacro`；`isAbstract(decl: Decl)` 写 `decl is ClassDecl && isAbstract((decl as ClassDecl).getOrThrow())`，`isSealed(decl: Decl)` 写 `match(decl) { case x: ClassDecl => … }`，两者语义等价（非类声明都返回 `false`）。前者把 `is` 与 `as … getOrThrow()` 拆成两次运行时判定，正确性依赖两者一致，而 `getOrThrow()` 在 `None` 时抛 `NoneValueException`。
- **描述**：文件名会让人以为存在 `hasAnnotation` 函数（`grep -rn "hasAnnotation" --include=*.cj` 全仓零命中，该名字只出现在文件名里）；两个 `Decl` 重载同语义不同写法，属可合并的近似重复。注意 `f_aspect` / `f_bean` 等宏包历史上就是按文件名找这两个工具的，改名成本低但需同步文档。
- **建议**：文件改名 `withAnnotation.cj`（或把两个函数并进 `isModifier.cj` 旁的 `annotation.cj`）；`isAbstract(decl: Decl)` 统一成 `match` 写法（可抽 `private func asClassDecl(decl: Decl): ?ClassDecl` 给 `isAbstract` / `isSealed` 共用），去掉 `getOrThrow()`。

## 优化可行性方案

### [堆内存] `topMacroAnonymousClosure` 把整段宏输出源码作为字符串常量嵌入产物

- **现状**：每个包装块生成一条 `Exception("…整段源码…", e)`，字符串内容 = `tokens.toString()` 的全文。调用点 5 处（`f_bean/src/macros/Bean.cj` 2 处、`f_bean/src/macros/Configuration.cj` 1 处、`f_mvc/src/macros/Controller.cj` 1 处、`f_jsonrpc/src/macros/JsonRpc.cj` 1 处），单块源码量级几十到几百字节；每个被宏展开的文件都会在只读数据段多出一份与源码等长的常量，且**仅在异常路径才会被用到**。
- **方案**：把消息换成「宏名 + 首行/前 N 字符」或「`tokens` 的起止行列号」，完整源码只在调试构建（`@When[debug]` 或编译期开关）下嵌入；或改为在 catch 里调用 f_macros 的辅助函数，由辅助函数按编译期常量决定详细程度。
- **预期**：被包装代码的字符串常量体积降到 O(1)（每条几十字节），产物中该部分常量池占用与源码长度解耦。
- **代价**：异常信息从「完整源码」降级为「定位片段」，排障时需要回到源文件；需改 5 个调用点之外的生成模板，属对外可见的诊断信息变化。
- **验证**：`cjpm build --release` 后对比 `f_bean` / `f_mvc` / `f_jsonrpc` 产物中字符串常量数量与 `.so` 体积（`strings`/`size` 或 cjo 反查）；同时跑一次故意抛异常的宏用例，确认报错仍能定位到文件行号。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个 `topMacroAnonymousClosure` 包装块都会把整段源码作为常量嵌入，产物体积随宏使用次数线性增长 | `f_macros/src/topMacroAnonymousClosure.cj:26` | 每块常量的实际字节数、`f_bean`/`f_mvc`/`f_jsonrpc` 产物中该类常量总占比 | 同一 SDK 下对目标模块 `cjpm build --release`，对比字符串常量条目数与 `.so` 大小；再套用上面的改造做一次对照 |
| 2 | `$(tokens.toString())` 在宏展开期对每个包装块做一次 `Tokens`→`String` 全量拷贝，构成编译期热点 | `f_macros/src/topMacroAnonymousClosure.cj:26` | 宏展开阶段自耗时占比（该函数在 `cjprof` 中的 self time） | `cjprof record` 跑一次全仓 `cjpm build`，按函数过滤 `topMacroAnonymousClosure` / `Tokens.toString`，输入为 fountain 全量模块 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_macros/src/hasAnnotation.cj` | .cj | ✅ | 见发现 #1、#3、#7 |
| 2 | `f_macros/src/imports.cj` | .cj | ✅ | 见发现 #6；`public import std.ast.*` + `internal import MacroFragmentException` 均为包级重导出，后者被 `extract_first_token.cj:25` 实际使用 |
| 3 | `f_macros/src/isModifier.cj` | .cj | ✅ | 见发现 #2、#4、#7 |
| 4 | `f_macros/src/topMacroAnonymousClosure.cj` | .cj | ✅ | 见发现 #5；`quote` 插值 `$(String)` 走 `String <: ToTokens` → 生成转义后的字符串字面量（`ast/ast_package_api/ast_package_interfaces.md:616-647`），**不存在**把源码当 token 拼回的注入面，此项已排除 |

合计：`.cj` 4 个 / `.md` 0 个 / 共 4 个，全部读完（本部分文件清单 4 行，逐行对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #1 正确性（判据错位）、#5 语言特性（宏卫生）、#6 #7 可读性/可维护性；无外部输入、无注入面（`$(String)` 已核实为转义字面量），`quote` 拼接不接收用户可控的 token 流，安全性未命中 |
| §1 死代码 | 0 | 逐个符号搜过：`private/internal` 只有 `isModifier.cj:109` 的 `isModifier(...)`（本文件 11 处调用）；`public` 顶层符号 `withAnnotation`/`withMacro`/`isOverride`/`isRedef` 仓内 0 引用（全仓 `grep -rn`，排除 `.worktrees`），但都是对外可达的 public 契约，按硬原则一不判死代码，仅记录；无 `return/throw` 后死语句、无未使用 import（`hasAnnotation.cj:18` 两个类型都用、`topMacroAnonymousClosure.cj:18` 的 `Tokens` 用于签名） |
| §2 重复逻辑 | 3 | #3（`withMacro` vs `extract*`）、#4（`isInternal` 两套实现）、#7（`isAbstract(Decl)` vs `isSealed(Decl)`）；同文件内 11 个修饰符谓词逐个比对后确认只是常量不同，属同族展开而非重复 |
| §3 空实现 | 0 | 4 个文件无空函数体、无 `TODO`/`FIXME`、无 `catch {}`（`topMacroAnonymousClosure.cj:25-28` 的 catch 会打印并重抛，不是静默吞异常） |
| §4 栈溢出 | 0 | 本部分无自定义递归（`isModifier` 是线性 for、`withAnnotation` 单层 for）；`parseDecl` 的深层嵌套限制是 std 行为，已在 `ast_package_funcs.md:427-431` 说明，不计本模块缺陷 |
| §5 OOM | 0 | 无全量物化、无按不可信长度预分配、无全局容器增长；`tokens.toString()` 的量级与单次宏输出等长，不构成 OOM 面（其产物膨胀已列优化方案） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点不成立；宏展开期开销列入「待验证假设」#2 |
| §6.2 大粒度锁 | 0 | 4 个文件无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 0 | 修饰符判定是 `ArrayList` 线性扫（修饰符数量 < 10），未达可判定为低效的规模；无嵌套循环、无字符串循环拼接 |
| §7 降堆内存方案 | 1 | 见优化方案（生成代码常量膨胀，`无基线（待验证）`） |
| §8 降 CPU 方案 | 0 | 本部分无可用基线支撑的 CPU 改造；`tokens.toString()` 的展开期开销列待验证假设 #2 |
| §9 local mode 可行性 | 0 | 4 个函数均为宏展开期小对象（`Tokens`/`Bool`），无函数内大临时对象，峰值内存收益无法证成，不列为方案 |
| §11 现有代码的 BUG（存量） | 4 | #1（判据错位恒 false）、#2（不解包注解宏）、#3（嵌套语义漂移）、#4（`isInternal` 语义分叉）；另核对了 `Decl.modifiers`、`Token.value`、`ClassTypeInfo.of(Any)`、`Exception(String, causedBy)` 四处签名语义，均与文档一致 |
| §12 并发安全与锁粒度 | 0 | 4 个函数都是编译器内单次宏展开调用的纯函数，无全局/静态可变状态、无惰性初始化、无跨线程共享；`TypeInfo.of<T>()` 每次调用自建，无线程共享路径 |
| §14 功能完备性与 README 覆盖 | 1 | #6（`public import std.ast.*` 未进 README）；其余符号 README 均有条目：`isModifier` 家族 `README.md:98-102`、`withAnnotation`/`withMacro` `:115`、`topMacroAnonymousClosure` `:120`。`isInternal` 缺 `Tokens` 重载已被第 1 部分 README 条目记录，本条不重复计数 |
| 文件覆盖（§13 等） | 4/4 | 本部分无 `.md`，`§13` 在本部分无适用对象；`README.md` / `README_en.md` 由第 1 部分审阅 |

## 模块统计

> 仅统计本部分 4 个文件；模块级统计由主 Agent 合并两部分后得出。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

> 存量 8 条（含 #1 严重），是否纳入修复待用户决定；#4 与第 1 部分 README 条目同根因，合并时二者取一。

## 总评

本部分 4 个文件都属于「宏作者的工具层」，体量小、无并发、无 I/O，代码本身干净；问题集中在**语义正确性**而不是实现复杂度：三个工具（`withAnnotation`、`withMacro`、`isModifier` 家族）都在「怎么识别一个带注解的声明」这件核心事情上各有一套不成立的假设，彼此还不一致。

- **阻塞项**：`withAnnotation` 的判据错位（#1）。它被 README 当公开契约列出，但当前实现对任何输入都返回 `false`；仓内已无调用者（`6f4692f87` 迁到 `f_base.TypeInfos.withAnnotation`），所以不阻塞构建，但下游一旦按文档使用就是静默失效。建议在下一版发布前要么修好、要么删掉并同步 README。
- **可排期**：#2（`isModifier` 不解包 `MacroExpandDecl`）与 #3（`withMacro` 与 `extract*` 的嵌套语义分叉）是同一类「带注解成员」问题，影响的是宏作者写新宏时的正确性，仓内现有宏靠人工 `extract` 规避，短期不炸、长期会持续制造同类 bug（`f_data` 的注解字段被过滤就是现成例子）。#4 的两套 `isInternal` 建议一并收敛。
- **可延后**：#5～#7 属宏卫生/可维护性；`topMacroAnonymousClosure` 的字符串常量膨胀只有产物数据才谈得上收益，本轮仅记为待验证假设。

值得肯定的是：`quote` 插值处对 `$(String)` 的用法是安全的（`String <: ToTokens` 生成转义字面量，不会把源码当 token 注入），`private let _` 用的是通配符模式（`let _` 不绑定名字，多次展开不会撞名，`docs/dev-guide/source_zh_cn/enum_and_pattern_match/other.md:5-20`），这两处最容易出错的宏技巧都写对了；缺的是「一个函数只回答一个问题」的边界和相应的用例覆盖——本模块全无 `*_test.cj`，上述 8 条没有一条会被现有测试拦住。
