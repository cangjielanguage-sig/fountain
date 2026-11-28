# f_macros 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_macros`（全模块 22 个 `.cj` + 2 个 `.md`；**本报告为模块第 1/2 部分**，覆盖 18 个 `.cj` + 2 个 `.md`；`hasAnnotation.cj`、`imports.cj`、`isModifier.cj`、`topMacroAnonymousClosure.cj` 属第 2 部分，未纳入本报告统计，仅在需要时作为上下文引用）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：宏展开正确性、带注解成员的处理、空实现、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [严重][存量] `extract(param, macroName)` / `extractIfOneOf(param, …)` 的循环条件读的是循环不变量 `param`，命中即死循环

- **位置**：`f_macros/src/extract_macro_expand.cj:107`（`extract(param: MacroExpandParam, macroName: String)` 的 `while`）、`f_macros/src/extract_macro_expand.cj:122`（`extractIfOneOf(param: MacroExpandParam, macroNames: Set<String>)` 的 `while`）
- **来源**：存量（`git blame -w -L 104,117 -- f_macros/src/extract_macro_expand.cj` → `8c8fe861ab` 2025-06-06；`-L 119,132` → `f5140a0421` 2025-06-07）
- **判据**：review-checklist §11（逻辑错误 / 无出口循环）；§10（正确性）
- **证据**：静态确定 ——
  1. 两处 `while` 的判定都写作 `let m: MacroExpandParam <- param && let pin: FuncParam <- m.macroInputDecl`，循环体只给 `p` 赋值（`:111`、`:126`），`param` 在整个函数里从未被赋值，因此两个子条件都是循环不变量。
  2. `MacroExpandParam <: FuncParam`（std `ast/decls.cj:2382`），形参的静态类型就是 `MacroExpandParam`，第一个模式匹配恒真；`macroInputDecl` 每轮取到同一节点（getter 见 `ast/decls.cj:2492-2503`），第二个条件也是常量。
  3. 参数宏的输入本来就是 `FuncParam`（`func foo(@M a: Int64)` 的宏输入是 `a: Int64`，std 文档 `ast_package_classes.md:9701-9715` 给的正是这个形态），因此第二个条件恒真 → 循环永不退出。
- **描述**：函数只有两种结局：`param.macroInputDecl` 不是 `FuncParam` 时零次迭代返回 `None`；是 `FuncParam` 时永久循环。**不可能返回 `Some`**。后果是编译器在宏展开阶段静默挂死，没有任何诊断输出，排查成本极高。同文件 96-102 行的无名版本用的是 `p` 作条件（能正常解包），可判定这是复制骨架时漏改变量所致（见下一条）。
- **建议**：条件改成 `let m: MacroExpandParam <- p && …`；更好的做法是把三个 `extract*` 的解包逻辑抽成一份共用辅助（见下一条），从结构上消除这类复制错误。
- **备注**：仓内无 2 参 `extract` 调用点（`grep -rnE "extract\([A-Za-z_]+, *[\"']" --include=*.cj .`（排除 `.worktrees`/`target`）零命中），影响面在下游使用者。

### [一般][存量] 六个 `extract` / `extractIfOneOf` 逐行重复，语义已漂移（首/末次匹配不一致、返回层级不一致）

- **位置**：`f_macros/src/extract_macro_expand.cj:28-41`、`:43-56`、`:66-79`、`:81-94`、`:104-117`、`:119-132`
- **来源**：存量（`git blame -w -L 28,28` → `8c8fe861ab` 2025-06-06；`-L 47,47` → `f5140a0421` 2025-06-07）
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 行为漂移）
- **证据**：静态确定 —— 六份函数体骨架逐行对应：`var x = 入参` → `while (let m <- x) { if (匹配) result = (m, x); x = 下一层 }` → `if (let Some((m, _)) <- result) { result = (m, 最终 x) }` → `result`。差异只有三处，且三处都是语义差异：
  1. **匹配策略**：`extract(decl,name)`（`:33`）、`extract(expr,name)`（`:71`）、`extract(param,name)`（`:109`）用裸赋值，后匹配覆盖前匹配 → 取**最内层**；`extractIfOneOf`（`:47`、`:85`、`:123`）用 `result.isNone()` 守卫 → 取**最外层**。同一个 `@A @B decl` 输入，两个函数返回不同的宏节点。
  2. **返回的第二元**：post-loop 的 `result = (m, 最终 x)`（`:38`、`:53`、`:76`、`:91`、`:114`、`:129`）把 tuple 第二元统一替换为"完全解包后的最内层 decl"。匹配到的不是最内层宏时（`extract(d, "A")` 作用于 `@A @B decl`），返回的 decl 越过了 `@B`；调用方若拿它回写宏输入，中间那层宏会静默消失。
  3. 上一条的死循环就是复制这套骨架时把 `p` 写成 `param` 造成的，属同一根因的直接后果。
- **建议**：把"沿宏链遍历 + 名字谓词 + 返回 (matched, 匹配处的下一层)"抽成一份共用骨架（decl/expr/param 三份做成薄包装），并把"首匹配 / 末匹配""返回匹配处还是最内层"改成显式参数 + 注释；现存差异要么统一，要么写进 README。
- **备注**：2 参版本仓内零调用，漂移目前只影响下游；单层宏（`@Foo var x`）下两种语义结果相同，所以问题只在嵌套宏上暴露。

### [一般][存量] 空输入 / 空参数列表一律直接下标，抛 `IndexOutOfBoundsException` 或 std 的裸 `ASTException`，没有可定位的宏诊断

- **位置**：`f_macros/src/extract_first_token.cj:30`（`tokens[0]`）、`f_macros/src/global_funcs.cj:21`（`funcParams[0]`）、`f_macros/src/extract_macro_expand.cj:139`（`macroTokens[0]`）、`f_macros/src/extract_bool.cj:19`（`tokens[idx]`）、`f_macros/src/extractFirstDecl.cj:19`（`parseDeclFragment(input)`）、`f_macros/src/extract_macro_expand.cj:61`/`:73`/`:88`（`parseExpr(m.macroInputs)`）
- **来源**：存量（`extract_first_token.cj`/`extract_bool.cj` → `8a6dac0df3` 2024-11-17；`global_funcs.cj` → `72eab2d85c`；`extractFirstDecl.cj` → `c96cf2998a` 2026-09-12；`extract_macro_expand.cj:139` → `844845bacb`）
- **判据**：review-checklist §11（空集合未处理、错误处理信息缺失）；§10（边界）
- **证据**：静态确定 ——
  1. `Tokens[index]` 越界抛 `IndexOutOfBoundsException`（std `ast/tokens.cj:149-154`），调用方拿不到"是哪个注解、哪个位置的输入为空"的信息。
  2. `primaryCtorParam` 构造 `Ctor(input){}` 后直接取 `funcParams[0]`；空输入时 `funcParams` 为空 → 越界。std 内部同语义实现 `parseFuncParam`（`ast/parse_decl.cj:75-89`）在 `params.size == 0` 时抛的是 `ASTException("Cannot construct the 'FuncParam' node.")`——本函数是它的复制品但漏了这道检查。
  3. `extractFirstDecl` 对空 `Tokens` 调 `parseDeclFragment`，后者统一转成 `ParseASTException("Failed to parse decl fragment.")`（`ast/parse_decl.cj:52-70`），同样没有位置信息；7 个调用点（`f_bean/src/macros/Bean.cj:32`、`f_aspect/src/macros/PointCut.cj:44` 等）都不判空，`@Bean` 这类无输入调用会走到这里。
  4. 同族函数里只有 `extractFirstTokenToStringLiteral`（`extract_first_token.cj:19-21`）做了 `size == 0` 兜底并给了 `default!`，其余均无——同一份代码里两套口径。
- **描述**：这些都是"宏作者写错注解"时唯一能得到的反馈通道，现在返回的是下标越界或无语境的解析异常。另：`primaryCtorParam` 在多参主构造时静默只取第一个参数（名字是单数，但没有校验，见 README `f_macros/README.md:116` 的"取主构造函数的参数"）。
- **建议**：统一抛已有的 `MacroFragmentException`（`f_macros/src/exception/MacroFragmentException.cj:20`）并带上原始 `Tokens`/下标；需要"可空"语义的返回 `Option`（如 `primaryCtorParam` 返回 `?FuncParam`）。`extractFirstTokenToIdentifier` 增加与 `extractFirstTokenToStringLiteral` 同款的 `size == 0` 分支即可对齐。

### [一般][存量] `extract` 解包会丢掉挂在宏节点上的 annotations（带注解成员的处理）

- **位置**：`f_macros/src/extract_macro_expand.cj:22-24`、`:31-36`、`:60-63`、`:69-74`、`:98-101`、`:107-112`、`:135-137`、`:154-156`（全部走 `m.macroInputDecl` 往下走）
- **来源**：存量（`8c8fe861ab` 2025-06-06）
- **判据**：review-checklist §11（语义与命名 / 契约不符）；本轮重点"带注解成员的处理"
- **证据**：待确认 —— 需一次 AST 实测：`parseDecl(quote(@Anno @Foo var x))` 后打印外层节点的 `annotations.size`，确认注解挂在外层 `MacroExpandDecl` 还是内层 `VarDecl`
- **描述**：`MacroExpandDecl.toTokens()` 会先输出 `annotations` 再输出 `@宏名`（std `ast/decls.cj:2331-2335`），说明"写在宏调用前面的其它注解"是挂在**宏节点自身**上的。`extract` 只用 `macroInputDecl` 逐层下钻，直接丢弃这个节点，因此这些注解不会出现在返回的 decl 上。受影响的是所有"解包后重新输出/重新生成代码"的调用点，例如 `f_data/src/macros/DataAssist.cj:296`（`let mp = extract(x)`）与 `:306`（`var md = extract(d)`）；一旦成立，`@Anno @Foo var x` 展开后 `@Anno` 静默消失。反向证据（说明可能不是问题）：仓内没有"宏前还写注解"的用例被测试覆盖，现有测试未暴露。
- **建议**：若实测成立，`extract*` 返回前把被跳过节点的 `annotations` 前置到结果 decl（`result.annotations` 追加），或提供 `extractWithAnnotations`；至少在 README 明确写"解包丢弃宏节点上的注解"。

### [一般][存量] README 缺用途/快速开始段落，且整批 public API 未文档化

- **位置**：`f_macros/README.md:1-122`、`f_macros/README_en.md:1-121`
- **来源**：存量（`git blame -w -L 38,38 -- f_macros/README.md` → `73bff9dcf2` 2026-09-04；`-L 102,102` → `2623bbfff2` 2026-10-06）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 缺关键段落）
- **证据**：静态确定 —— README 从 `# f_macros` 直接进入 `## Decl扩展`，没有"这个模块干什么、依赖什么、怎么用"的任何一段（无用途、无依赖/安装、无快速开始、无限制条件），全篇只有接口签名片段，没有一段完整可运行的宏示例。以 `src/` 的 public 声明为基准比对，README 中检索不到的符号有：
  - `CompositeDecl`（`f_macros/src/CompositeDecl.cj:18`，`public interface`，被 `f_jit/src/macros/JitBind.cj:49` 直接使用）
  - `ExtendClassDecl`（`f_macros/src/CompositeDecl.cj:38`，`public interface`）
  - `extractBoolAttr`（`f_macros/src/extract_bool.cj:18`）
  - `global_tokens.cj:18-172` 的 130+ 个 token 常量（`dot`/`comma`/`lparen`/…/`empty_tokens`/`empty_string`），README 全文无一处提及（`grep -n "global_tokens\|dot\|comma" f_macros/README.md` 无命中）
  - `ExtendToken` 只在 `README.md:121` 的"其他"里点了名字，没有说明 `==(value: String)` 的语义（按 token 文本比较、不比较 kind）
- **描述**：使用者按 README 只能看到 5 个 `Extend*` 接口的签名，看不到最常用的 token 常量表，也不知道 `CompositeDecl` 这层抽象存在（它是 `JitBind` 里唯一能用统一类型接收 Class/Struct/Interface 的手段）。
- **建议**：补三段——模块定位（宏编写辅助库，编译期使用）、依赖与安装（`fountain::f_base`、`fountain::f_exception`）、一个最小宏示例（含 `extractFirstDecl` + `extractFuncs` + `` `comma` `` 拼接）；再补 `CompositeDecl`/`ExtendClassDecl`/`extractBoolAttr` 与 token 常量表的说明（常量表可按 `TokenKind` 分组，不必逐条解释）。中英同步。

### [轻微][存量] `extract_props.cj` / `extract_vars.cj` 的 `import fountain::f_base.*` 未使用

- **位置**：`f_macros/src/extract_props.cj:18`、`f_macros/src/extract_vars.cj:18`
- **来源**：存量（`8a6dac0df3` 2024-11-17）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 两个文件用到 `isPublic`、`isStatic`、`isMut`、`isVar()`，前者全部定义在本包 `f_macros/src/isModifier.cj:54`/`:22`/`:79`，`isVar()` 是本包 `f_macros/src/ExtendVarDecl.cj:24` 的扩展方法；`grep -rn "func isPublic\|func isStatic\|func isMut\|func isVar" --include=*.cj f_base/src` 零命中，f_base 不提供这些名字。同族 `extract_funcs.cj:18` 的同一行 import 是**有用**的（`unsafeData()` 是 `f_base/src/UnsafeData.cj:24-29` 的 `ArrayList` 扩展），所以这三行看起来是照抄过来的。
- **描述**：多余的包依赖声明，会让读者以为这两个函数依赖 f_base；不影响功能。
- **建议**：删掉这两行；若想保留"本模块统一依赖 f_base"，就统一在 `imports.cj` 里声明。

### [轻微][存量] `extractFuncs` 的入参/返回集合类型与同族其余提取函数不一致

- **位置**：`f_macros/src/extract_funcs.cj:20-26`（`Array<Decl>` → `Array<FuncDecl>`，用 `list.unsafeData()`）；对照 `f_macros/src/extract_props.cj:20`/`:28`/`:38`、`f_macros/src/extract_vars.cj:20`/`:28`（`ArrayList<Decl>` → `ArrayList<...>`）
- **来源**：存量（`:25` → `23f52b4a9e`）
- **判据**：review-checklist §10（可维护性）/ §2（差异是否必要）
- **证据**：静态确定 —— 五个提取函数的签名分两类：只有 `extractFuncs` 收 `Array` 返 `Array`，其余收 `ArrayList` 返 `ArrayList`。宏里拿到的 `classDecl.body.decls` 是 `ArrayList<Decl>`，取出函数要用 `extractFuncs(x.toArray())`，而紧跟其后取变量又直接写 `extractVars(x)`，同一段调用里两种写法并存。`unsafeData()` 返回的是底层数组的 `[0..size]` 切片（`f_base/src/UnsafeData.cj:25-29`），零拷贝、语义等价于 `toArray()`，风险本身不大。
- **描述**：纯粹的一致性/可读性问题；`extractFuncs` 仓内零调用（`f_rpc/src/macros/RPCSkeleton.cj:73` 那个是 f_rpc 自己的 `private func extractFuncs`，与之无关）。
- **建议**：统一成 `ArrayList`（或两种入参各给一个重载，返回统一 `ArrayList`）。属接口变更，需用户决定。

### [轻微][存量] `replaceMacroInputDecl` 第 149 行注释与当前 std 实现相反，会误导后续维护

- **位置**：`f_macros/src/extract_macro_expand.cj:149`（`//经过测试macroInputDecl macroInput互不影响，两个都要修改`）
- **来源**：存量（`git blame -w -L 149,149` → `844845bacb`）
- **判据**：review-checklist §11（注释与实现不符）/ §10（可读性）
- **证据**：静态确定 —— std 里 `macroInputDecl` 的 setter 会同步 `macroInputs`：`macroInputDecl_ = Some(v); macroInputs_ = v.toTokens()`（`ast/decls.cj:2326-2329`；`MacroExpandParam` 同一实现见 `ast/decls.cj:2492-2503`）。因此只写 `macroInputDecl` 就足以让 `toTokens()` 输出新输入（`toTokens` 在有括号时读 `macroInputs`、无括号时读 `macroInputDecl`，两者已被 setter 对齐，见 `ast/decls.cj:2163-2175`）。同一文件 152-159 行的第二个重载只写 `macroInputDecl`，在仓内被 `f_orm/src/macros/ORMField.cj:91`、`:96`、`f_orm/src/macros/QueryMappersGenerator.cj:77` 使用且工作正常，与注释的说法矛盾。
- **描述**：注释是当时（可能更早的 SDK）的排障结论，现在已失效；后来者会照它去"两处都改"，或反过来怀疑第二个重载有缺陷。
- **建议**：删掉或改写为"`macroInputDecl` setter 会同步 `macroInputs`（SDK 1.x），只需改 decl"。

### [轻微][存量] `global_tokens.cj` 的注释与常量命名有错

- **位置**：`f_macros/src/global_tokens.cj:151`（`` `synchronized` `` 的注释 `/**  "synchronized */` 引号未闭合）、`:158`（`float_literal` 注释 `e.g. "'1.0'"` 多一层引号，其余条目是 `e.g. "1"`）、`:165`（`unit_literal` 注释 `"()))"`，看不出对应哪个字面量）、`:167`（常量名 `` `macros` `` 实为 `ANNOTATION` 类型 token，注释 `@when`）
- **来源**：存量（`8a6dac0df3` 2024-11-17）
- **判据**：review-checklist §10（可读性 / 命名）
- **证据**：静态确定 —— 逐行比对 18-172 的注释格式，只有上述 4 条与整体格式不一致；其余条目均为 `/** "符号" */` 或 `/** e.g. "样例" */`。另：`:71-72` 的 `lt`/`gt` 用 `Token(TokenKind.LT)` 而同一文件其余全部用裸 `Token(DOT)` 写法，属同批不一致但不影响语义。
- **描述**：`` `macros` `` 这个名字尤其容易误用——按名字会以为它代表 `macro` 关键字（那是 `` `macro` ``，`:106`），实际是 `@` 注解 token。
- **建议**：修正 4 处注释；`` `macros` `` 改名（如 `` `annotation` ``），旧名保留 `@Deprecated` 一版做过渡（需用户确认下游是否在用）。

### [轻微][存量] README 两处与实现不符：重复列举 `FuncDecl`；把 `isInternal` 列入"两个重载"清单但只有 `Decl` 重载

- **位置**：`f_macros/README.md:38`（`VarDecl FuncDecl PrimaryCtorDecl PropDecl FuncDecl都实现此接口扩展`）、`f_macros/README.md:102`（把 `isInternal` 与其余 11 个名字并列写在"多数同时提供两个重载"之后）
- **来源**：存量（`:38` → `73bff9dcf2` 2026-09-04；`:102` → `2623bbfff2` 2026-10-06）
- **判据**：review-checklist §13（文档与代码不一致）
- **证据**：静态确定 —— `f_macros/src/isModifier.cj` 中 `isStatic`/`isAbstract`/`isSealed`/`isPublic`/`isPrivate`/`isProtected`/`isMut`/`isOpen`/`isOverride`/`isRedef` 各有 `Tokens` 与 `Decl` 两个重载，`isInternal` 只有 `isInternal(decl: Decl)`（`:63-65`），`grep -n "isInternal(tokens" f_macros/src/` 零命中；`Extend*` 接口里对应的是 `isInternal()`（无参，`ExtendMember.cj:22`），语义也不同（那条是"不是 public/protected/private"，`:63` 那条是"带 `internal` 修饰符"）。`README_en.md:38` 没有重复列举，但 `:102` 同样暗示两个重载。
- **描述**：`isInternal` 恰好是两个 API 名字相同、语义不同的一对，README 的并列写法会让人以为它们等价。
- **建议**：`:38` 去掉重复的 `FuncDecl`；`:102` 单独标一句"`isInternal` 只有 `Decl` 重载，且与 `ExtendMember.isInternal()`（取反判定）语义不同"，中英同步。

### [轻微][存量] 130+ 个 `public let` token 常量是共享可变对象，被原地修改会污染后续所有宏展开

- **位置**：`f_macros/src/global_tokens.cj:18-172`（全部 `public let xxx = quote(...)`）
- **来源**：存量（`8a6dac0df3` 2024-11-17）
- **判据**：review-checklist §12.1（共享可变状态）/ §10（设计）
- **证据**：静态确定（机制成立）/ 待确认（是否有实际误用、编译器是否并行展开不同文件）—— `Tokens` 是可变的：`append` 直接 `tokens.add(token)` 并返回 `this`（std `ast/tokens.cj:201-208`），`remove` 同理（`:211-217`）。这些常量是模块级的单个实例，被本模块与所有下游宏共用，任何一处 `` `comma`.append(x) `` 都会永久改变后续所有展开看到的"逗号"。仓内当前没有这种写法（对 `global_tokens` 常量的引用都是 `+`/插值，返回新对象）。
- **描述**：现在的用法是安全的，但作为对外公开的工具常量，没有任何机制阻止下游原地修改；这类污染表现为"编译结果与源码不符且随机"，很难定位。
- **建议**：常量改为 `public func comma(): Tokens { quote(…) }`（每次返回新实例），或至少在每个常量上注明"只读，禁止原地修改"；若保持 `let`，README 要写清这条约束。

## 优化可行性方案

本部分为空。该部分的运行期工作全部发生在编译期宏展开，输入是源码 token，量级由注解数量决定，没有循环嵌套、容器增长、锁或 I/O；唯一可谈的分配行为（每次 `parseExpr` / `parseDecl` 重新解析、130+ 个常量对象常驻）都缺少改前基线，按铁律只能进「待验证假设」，不写成优化结论。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `extract(expr)` 每解一层宏就 `parseExpr(m.macroInputs)` 重新解析 token，深层嵌套宏（`@A @B @C x`）下这部分解析开销可能可观 | `f_macros/src/extract_macro_expand.cj:61`/`:73`/`:88` | 自耗时占比、调用次数 | 对一个含 100+ 嵌套宏调用的模块跑 `cjprof record`（`-O2`），看 `parseExpr`/`ParseAST` 的 self time 占比；对照：改为复用 `macroInputDecl` 的版本 |
| 2 | `primaryCtorParam` 每次调用都构造并解析一个 `Ctor(input){}`，在 bean/ORM 类宏里（每个字段一次）可能累积成可观开销 | `f_macros/src/global_funcs.cj:19-21` | 单次耗时、每模块调用次数 | 在 `f_bean`/`f_orm` 编译期加计数器 + 分段计时，取中位数；对照：直接 `parseFuncParam` 风格实现 |
| 3 | 130+ 个 `public let` token 常量在编译进程里常驻（每个 `quote(...)` 一个 `Tokens`），对大工程的编译期内存有稳定但未知的占用 | `f_macros/src/global_tokens.cj:18-172` | 编译进程 heapUsed / RSS 基线 | 同一工程改前改后各跑 3 次完整构建，记录 `cjpm` 进程峰值 RSS 中位数；单文件宏库体量小，预期收益可能低于噪声 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_macros/README.md` | .md | ✅ | 覆盖缺口见发现 5；细节错误见发现 10；其余与实现一致 |
| 2 | `f_macros/README_en.md` | .md | ✅ | 与中文版结构一致（均缺用途/快速开始），`:102` 同问题 |
| 3 | `f_macros/src/CompositeDecl.cj` | .cj | ✅ | 接口成员由 `Decl` 原生提供（`getAttrs`/`hasAttr` 见 `ast_package_classes.md:2778`/`:2811`），无空实现 |
| 4 | `f_macros/src/ExtendDecl.cj` | .cj | ✅ | `genericParamTokens` 被 f_data 4 处使用；实现与 `Decl.isGenericDecl`/`genericParam` 语义一致 |
| 5 | `f_macros/src/ExtendFuncDecl.cj` | .cj | ✅ | 6 个转发实现，无逻辑 |
| 6 | `f_macros/src/ExtendMember.cj` | .cj | ✅ | `isInternal()` 默认实现与 `isModifier.isInternal` 语义不同，见发现 10 |
| 7 | `f_macros/src/ExtendPrimaryCtorDecl.cj` | .cj | ✅ | 3 个转发实现，无逻辑 |
| 8 | `f_macros/src/ExtendPropDecl.cj` | .cj | ✅ | 6 个转发实现，无逻辑 |
| 9 | `f_macros/src/ExtendToken.cj` | .cj | ✅ | `==(String)` 只比 value 不比 kind；仓内零调用（对外 API） |
| 10 | `f_macros/src/ExtendVarDecl.cj` | .cj | ✅ | `isVar()` 用 `keyword.kind` 判定，未被 `isModifier` 覆盖，无重复 |
| 11 | `f_macros/src/exception/MacroFragmentException.cj` | .cj | ✅ | 4 个构造器转发 `BaseException`，`init() {}` 为有意空体（默认构造） |
| 12 | `f_macros/src/extractFirstDecl.cj` | .cj | ✅ | 空输入无兜底，见发现 3；7 个跨模块调用点 |
| 13 | `f_macros/src/extract_bool.cj` | .cj | ✅ | 返回类型由函数体推导为 `Bool`（`function/define_functions.md:86-99` 允许省略）；`idx` 无校验见发现 3；仓内零调用 |
| 14 | `f_macros/src/extract_first_token.cj` | .cj | ✅ | 同文件两个函数判空口径不一致，见发现 3 |
| 15 | `f_macros/src/extract_funcs.cj` | .cj | ✅ | 集合类型不一致见发现 7；`f_base` import 有实际用途 |
| 16 | `f_macros/src/extract_macro_expand.cj` | .cj | ✅ | 本部分主要问题集中地：发现 1/2/3/4/8 |
| 17 | `f_macros/src/extract_props.cj` | .cj | ✅ | 未使用 import 见发现 6；三个函数逻辑互不重复（只读/可变/全部） |
| 18 | `f_macros/src/extract_vars.cj` | .cj | ✅ | 未使用 import 见发现 6 |
| 19 | `f_macros/src/global_funcs.cj` | .cj | ✅ | `primaryCtorParam` 空参数越界见发现 3 |
| 20 | `f_macros/src/global_tokens.cj` | .cj | ✅ | 注释/命名问题见发现 9；共享可变常量见发现 11 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 3（发现 1/3/4）；设计/重复 3（发现 2/7/11）；可读性 2（发现 8/9）；语言特性：`Option` 全部显式解构、未发现静默丢弃，`match` 均带兜底分支；安全性：宏只处理源码 token，无外部输入、无注入面 |
| §1 死代码 | 1 | 逐个核对了本部分全部顶层声明：只有发现 6 两处未使用 import。其余全为顶层 `public`（含 130+ token 常量、8 个 interface、22 个函数、1 个 public 类），按硬原则一对外可达不判；`private`/`internal` 符号只在第 2 部分 `isModifier.cj:109`，不属本部分。记信息（不计问题）：`extractBoolAttr`、`primaryCtorParam`、`extractFirstTokenToIdentifier`、`extractFirstTokenToStringLiteral`、`extractProps`、`extractReadOnlyProps`、`extractAllVars`、`extractFuncs` 全仓零引用；`ExtendMember.isInternal()`、`ExtendClassDecl.isSealed()`、`ExtendToken.==(String)` 零调用。无 `return`/`throw` 后的同层语句（`extract_bool.cj` 的 `match` 是函数体末项，属返回值）。 |
| §2 重复逻辑 | 1 | 已把本部分 18 个 `.cj` 的函数体逐个压成"输入 → 输出 → 副作用"摘要两两比对：发现 2（6 份解包实现）、发现 7（集合类型）、发现 10（`isInternal` 两套语义）。其余逐行相同的转发实现（`Extend*` 里 `isPublic(){ isPublic(this) }` 这类共 32 个）判定为刻意展开：仓颉扩展无法跨类型共享实现，抽不出公共骨架，不按重复报。 |
| §3 空实现 | 0 | 空函数体只有 `MacroFragmentException.init() {}`（`MacroFragmentException.cj:21`），是"默认构造 + 隐式 `super()`"，非占位；接口默认实现只有 `ExtendMember.isInternal()`/`CompositeDecl.isInternal()` 两条有语义的取反实现；无 `TODO`/`FIXME`/`UnsupportedException`；无 `catch {}`。 |
| §4 栈溢出 | 0 | 11 个 `while` 解包循环与 7 个 `for` 过滤循环都是迭代，无递归调用（`extract` 之间的调用是同级转调，不构成环）；不存在深度由输入决定的递归。 |
| §5 OOM | 0 | 全部容器都是"按传入 decl 数量一次遍历"的局部 `ArrayList`，无全局累积、无按不可信长度预分配、无 `spawn`；编译期输入是源码 token，规模由注解数决定。 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点未成立；3 条疑点（重复 `parseExpr`、`primaryCtorParam` 每次重建 Ctor、常量常驻）已列入待验证假设。 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无线程池。 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/队列。 |
| §6.4 低效算法 | 0 | 只有线性遍历与 `Set.contains`（`extract_macro_expand.cj:47/85/123`，O(1) 均摊），无嵌套循环、无 `remove(at: 0)`、无循环内字符串拼接。 |
| §7 降堆内存方案 | 0 | 宏工具件，生命周期随一次编译结束；常量常驻与临时对象两处都缺改前基线，只能进待验证假设。 |
| §8 降 CPU 方案 | 0 | 同上，无基线数据，未写成方案。 |
| §9 local mode 可行性 | 0 | 无函数内大临时对象：单次调用只处理一条 decl 链，逃逸明显（返回值即结果），不满足 local mode 前提，无收益可测。 |
| §11 现有代码的 BUG（存量） | 4 | 核对了本部分 18 个 `.cj` 的全部边界与空值：发现 1（死循环）、发现 3（空输入无兜底）、发现 4（注解丢失，待确认）、发现 8（注释与实现不符）。另外核对了 `extractFirstDecl` 的 `index < size` 分支（`:20-24`，无差一）、`extract_props`/`extract_vars` 的过滤条件（`extractStatic` 仅在为 true 时生效，语义自洽）、`ExtendVarDecl.isVar` 的 `match` 全覆盖。 |
| §12 并发安全与锁粒度 | 1 | 发现 11（`public let` token 常量是共享可变对象）。除此之外本部分无共享状态：所有函数只用参数与局部变量，无单例、无注册表、无线程本地存储；宏展开是否跨文件并行属编译器行为，标待确认。 |
| §13 文档一致性（.md） | 1 | 发现 10（README `:38` 重复列举、`:102` `isInternal` 重载表述与 `isModifier.cj:63` 不符）；另核对了 README 中 5 个 `Extend*` 接口的签名片段与源码逐行一致、`:108-116` 的函数签名表与源码一致（`extractFuncs` 的 `Array` 返回、`extractVars` 的默认参数均正确）。 |
| §14 功能完备性与 README 覆盖 | 1 | 发现 5（缺用途/快速开始段落 + `CompositeDecl`/`ExtendClassDecl`/`extractBoolAttr`/token 常量表/`ExtendToken` 语义未文档化）。功能侧：README 提到的函数都能在 `src/` 找到实现，无"承诺但未实现"；模块无 `*_test.cj`，全部能力靠下游宏间接验证。 |
| 文件覆盖（§13 等） | 20/20 | 无缺失，逐文件读完（见上表） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这套代码是"宏作者的工具箱"：一层 `Extend*` 接口把 `Decl` 子类型的修饰符判定统一成方法，一批 token 常量省掉手写 `quote`，一组 `extract*` 负责剥宏壳。规模不大（18 个文件 1300 行，其中 155 行是纯常量表），接口设计对下游是有用的——`extractFirstDecl`、`extractVars`、`genericParamTokens`、`CompositeDecl` 都在 f_aspect/f_bean/f_data/f_orm/f_jit 里被真实使用。

主要风险集中在 `extract_macro_expand.cj` 一个文件：六个函数是同一骨架的六次复制，复制过程已经造成两处后果——参数版两个函数（`extract(param, macroName)`、`extractIfOneOf(param, …)`）的循环条件写成了循环不变量，**命中即死循环**，这是本模块唯一的阻塞项；另外首/末次匹配与"返回哪一层 decl"在两族函数之间不一致，嵌套宏下会静默丢掉中间那层宏。这两个函数仓内零调用，所以问题目前只埋在下游，但只要有人按 README 的"可按宏名过滤"去用就会撞上，建议优先修（改一个变量名 + 抽一份骨架即可）。

第二档是空输入兜底：`extractFirstTokenToIdentifier`、`primaryCtorParam`、`replaceMacroInputDecl`、`extractFirstDecl` 都是"直接下标 / 直接解析"，宏作者写错注解时拿到的是 `IndexOutOfBoundsException` 或无语境的 `ParseASTException`，而同文件的 `extractFirstTokenToStringLiteral` 明明做了判空——统一到 `MacroFragmentException` 成本很低。

文档是第三档：README 没有一句"这个模块干什么、怎么用"，还漏掉了 `CompositeDecl` 和整张 token 常量表，这是本模块对外可用性最大的短板（一般）；两处细节表述与实现不符（轻微）。`Extend*` 接口与 `global_tokens` 常量本身质量良好，只有注释/命名的小瑕疵。

存量问题共 11 条（严重 1 / 一般 4 / 轻微 6），是否纳入修复、以及 `extract*` 接口是否顺带统一签名，待用户决定。另记范围外提示一条：`f_data/src/macros/DataAssist.cj:296` 留有 `//TODO: x.macroInputDecl x.toTokens()有BUG，无法完成，等待修复`，与发现 1 是同一条"参数宏解包"链路上的已知问题，属 f_data 模块评审范围。
