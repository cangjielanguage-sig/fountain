# f_aspect 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 17 条**：严重 5（§1.3 `ASP-1`、§1.4 `ASP-2`、§1.6 `ASP-4`、§1.7 `ASP-5`、§1.14 `ASP-3`）、中 4（§2.4 `ASP-9`、§2.9 `ASP-8`、§2.22 `ASP-6`、§2.23 `ASP-7`）、低危+待验证 8（§3）。
- **状态（截至 2026-10-05）**：`ASP-1` ❌误判（§1.3，设计目的）、`ASP-2` ✅已修复（§1.4）、`ASP-4` ✅已修复（§1.6）、`ASP-5` ✅已修复（§1.7）、`ASP-3` ✅已修复（§1.14）、`ASP-9` ❌误判（§2.4，设计目的，README 已说明）、`ASP-L8` ❌不成立（§3.2，概率性假设已实测排除）；**待修** §2 的 3 条中危（`ASP-8`/`ASP-6`/`ASP-7`）、§3 的 7 条低危。

## 1. 严重（本模块 5 条）

### 1.3 [误判｜非缺陷] `ASP-1` 拦截器链把「首次调用的 `fn`」永久烧进静态缓存（f_aspect）✓已复核 → ❌误判（2026-10-04：设计目的，非缺陷）

**❌ 误判标记（2026-10-04）**：判定为**误判**，非缺陷（理由见下方判定）。分支 `docs/asp-1-design-note`（worktree `.worktrees/asp-1-design-note`，基线 `8be67951`），**代码注释与本标记在同一提交**：`31c023bf docs(f_aspect): 补切面链缓存的设计说明注释；bug.md §1.3 ASP-1 判定为误判`；该分支已并入 `sts/1.3.x`（合并提交 `b1a706ad`）。代码侧设计说明见 `f_aspect/src/Aspects.cj:25-33`（`aspects` 声明处）与 `f_aspect/src/Aspects.cj:44`（链尾 `{args => fn(args)}` 处）。收尾时 worktree 与分支已按约定删除（分支 was `31c023bf`）。

**判定（2026-10-04）：误判，非缺陷。** 链按「(类型, 函数)」**只在切点函数首次被调用时构建一次、之后一直复用**，以及由此产生的「链尾固化首次调用传入的 `callee`（含该次调用的接收者）」，两者都是**刻意的设计**：

- 为什么只建一次：建链要遍历 IoC 中全部 `Aspect` bean 并逐条做织入规则匹配（`Aspects.cj:36-56`），成本高，而匹配结果只取决于切点函数的签名（类型 + 函数），与实例无关 ⇒ 只算一次；
- 织入的粒度是「**类型**」而不是「实例」：同一类型的多个实例共享同一条链，不按实例建链（`f_aspect/README.md`：「织入逻辑会在这些函数首次调用时执行」）；
- 使用前提：被织入的对象必须是 **IoC 管理的 bean**（`singleton` 或 `prototype` 均可），手工 `new` 出来的实例不在支持范围内。

本条目不再进入修复队列（§0 建议修复顺序第 3 条已同步去列）。

**以下为审查时的原始判断与证据（已作废，留档对照）**：

位置：`src/Aspects.cj:25-46`（配合 `macros/PointCut.cj:109-118`）

```cangjie
// Aspects.cj:25   private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Array<Any>) -> Any>()
// Aspects.cj:35   var f: (Array<Any>) -> Any = {args => fn(args)}     // 捕获 doProceed 的形参 fn
// Aspects.cj:39-43 f = { args => funcInfo.setArgs(args); BeanFactory.instance.get<Aspect>(aspectName)... }
// PointCut.cj:111-113  func callee(args: Array<Any>){ $argVars; $(decl.block.nodes) }   // 在被织入函数体内 ⇒ 捕获 this
```

影响：链按 (TypeInfo, InstanceFunctionInfo) 只建一次，链尾永远是最早那次调用的 `callee`；`callee` 定义在原方法体内（宏展开见 `PointCut.cj:109-118`）⇒ 捕获首个接收者 `this` ⇒ **prototype / 手工 `new` 的实例上会在错误对象上执行方法体**；同时该实例被静态 map 永久引用（无法回收）。修法：链里只保存切面名列表，把 `fn`（与 args）作为参数逐次传入。（原始提案，已作废——见上方判定：按类型建链、固化首次 `callee` 即为设计目的。）

### 1.4 [严重｜正确性] `ASP-2` 缓存的 `InvocationFuncInfo` 每调用被改写参数，并发下互相覆盖（f_aspect）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/asp-2`（worktree `.worktrees/asp-2`，基线 `859e3759`），代码、用例、README、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-2 实参逐调用传递，切面链不再共享可变参数槽（§1.4）`）。**落地方式与原「修法」不同**：不需要改成 `proceed(funcInfo, args, fn)`，而是在层闭包内用本次调用的 `args` 新建 `InvocationFuncInfo`——`Aspect.proceed(funcInfo, point)` 签名与 `point(args)` 语义都不变。（原条目引用的 `Aspects.cj:41/47/64` 在 §1.3 补注释后为 `51/57/74`，均已改掉。）

- 改动：`f_aspect/src/Aspects.cj` doProceed —— 链只捕获不可变的 `qualifiedFuncInfo`；层闭包把 `funcInfo.setArgs(args)` 换成 `InvocationFuncInfo(qualifiedFuncInfo, args)` 后交给切面（实参逐调用、逐层传递）。链仍按 `(类型, 函数)` 只在首次调用构建、链尾仍固化首次 `callee`（§1.3 判定的设计不动）。`f_aspect/src/QualifiedFuncInfo.cj`：`_args` 改 `private let`、删 `setArgs`（全仓唯一调用点已移除）；`f_aspect/README.md` 的 `InvocationFuncInfo` 片段同步（`var`→`let`）。
- 用例（f_aspect 原先没有测试目录，本提交新建）：`aspect_args_race_test.cj`（并发串台回归：切面无状态、不加锁、不读 args，用 `AtomicBool` 制造确定性交错）、`aspect_chain_capture_test.cj`（每次调用各自的 info、实参与元数据正确；切面经 `point()` 改造实参的语义保留）。
- 测量证据：**修前** `T1 传入实参 1，业务方法实收 2；T2 传入实参 2，业务方法实收 2`，`Assert Failed: (r1 == 1)`，`FAILED: 1`（EXIT=1）；**修后** `T1 传入实参 1，业务方法实收 1；T2 传入实参 2，业务方法实收 2`，三条用例 `PASSED: 3, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。机制用例的实测行：`切面拿到的 info 与本次入参是同一实例（第1/2次）：false/false`、`两次拿到的 info 是同一实例：false`、`切面在两次调用里看到的实参：1/2`、`切面把实参 7 改成 100，业务方法实收 100`。
- 后续（2026-10-04，同一分支 `fix/asp-2`）：按用户要求把 `InvocationFuncInfo` 从 `class` 改为 `struct`（值类型、不可变、按值传递）——「跨调用共享参数槽」在语言层面不再可能；用例改为值语义断言（struct 下对象身份断言无意义）；三条用例仍 `PASSED: 3, FAILED: 0`；`f_aspect/README.md` 的 `InvocationFuncInfo` 片段与说明同步为 `struct`。
- 未覆盖：`f_orm`/`f_rpc` 未重跑构建——本次不改公开 API（两模块只是实现 `Aspect`、读 `funcInfo.args`），如需可单独 `cjpm build`。

位置：`src/Aspects.cj:41`（配合 `:47`）

```cangjie
// Aspects.cj:41    funcInfo.setArgs(args)      // funcInfo 是 ASP-1 缓存里的同一个对象
// Aspects.cj:47    match (f(funcInfo.args)) { case x: T => x ... }
// Aspects.cj:64    case Some(_) => fn(funcInfo.args)
```

影响：两个线程调用同一织入函数时，A 的参数可能被 B 覆盖；切面在 `around` 里读 `funcInfo.args` 会拿到别人的参数（`f_orm` 的 `TransactionAspect.proceed` 正是基于 `funcInfo` 判断）。修法：去掉可变共享槽，`proceed(funcInfo, args, fn)` 显式传参。

### 1.6 [严重｜正确性] `ASP-4` 前缀/后缀参数注解规则用 `params.size` 索引注解数组 ⇒ 越界崩溃（f_aspect）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `51030f8c`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-4 前缀/后缀参数注解规则按下标对齐，越界/恒 true → false（§1.6）`）。

- 改动：`f_aspect/src/AspectRoute.cj:290` 的公共实现 `matches(asc:...)` —— `range` 改为按 `annotations.size` 收敛、下标基准换成「规则项下标」（前缀 `offset = 0`、后缀 `offset = params.size - annotations.size`，规则项**正序**对应最后 N 个参数）；`params.size < annotations.size` 时返回 `false`；规则项补 `trimAscii()`；判定维持"参数**拥有**该注解即通过"（同文件 `contains :197-206` 的写法）。两个规则类本体不变，其文档示例（`:311-317`、`:324-330`）现在成立。
- **实测修正（与审查原文不同）**：原后缀分支 `params.size - 1..=0` **缺 `: -1`** ⇒ 按语言语义是**空循环**（最小实验：`for (i in 3..=0)` 迭代 0 次，`3..=0 : -1` 才是 `3 2 1 0`；仓库其它降序循环都写 `: -1`）⇒ 后缀规则的真实症状是**不校验任何参数、恒 `true`（过织入）**，不是越界；越界崩溃只发生在前缀分支（`0..params.size` + 规则项更少时）。两者同根：都用**参数下标**去索引规则项。
- 用例：`f_aspect/src/test/arg_prefix_suffix_route_test.cj` —— 规则项数 == / < / > 参数数 × 前缀/后缀、参数无注解（必须 `false`，防"空集合真空通过"）、参数多注解（"拥有"即可，`true`），共 2 个 `@TestCase`。
- 测量证据：**修前** `testPrefixRule` = `[ ERROR ] IndexOutOfBoundsException: Index out of bounds: index is '2', but array size is '2'`；`testSuffixRule` = `[ FAILED ] Assert Failed: (rule.matches(info('test3', 3)) == false)`（空循环误判 `true`）；合计 `PASSED: 3, ERROR: 1, FAILED: 1`（EXIT=1）。**修后** `PASSED: 5, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。
- 未覆盖：`ArgAnnotationsRouteRule` 的"恒 `false`"属 §1.7 `ASP-5`，本次未动。

位置：`src/AspectRoute.cj:290-309, 318-336`

```cangjie
// AspectRoute.cj:291  let annotations = annotationTypes.split(',')
// AspectRoute.cj:293-297  let range = if (asc) { 0..params.size } else { params.size - 1..=0 }
// AspectRoute.cj:298-299  for (i in range) { let current = annotations[i]      // ← 用 params 的长度索引 annotations
```

影响：规则项少于参数个数时抛 `IndexOutOfBoundsException`（无人捕获，直接从 `Aspects.doProceed` 冒泡到业务调用方 ⇒ 该函数**每次调用都失败**）。而 `AspectRoute.cj:311-317` 的文档示例恰好就是这个形状：`a.Annotation1,b.Annotation2` 匹配 `test2(@Annotation1 a, @Annotation2 b, c)`（3 参数 2 规则项）。修法：`range` 按 `annotations.size` 收敛（suffix 反向同理），并在长度不匹配时明确返回 `false`。

### 1.7 [严重｜正确性] `ASP-5` `ArgAnnotationsRouteRule` 恒返回 false（静默不织入）（f_aspect）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `7cd7863e`），代码、用例、README、本标记在**同一提交**（提交信息 `fix(f_aspect): ASP-5 ArgAnnotationsRouteRule 命中判定修正 + 长度必须逐参数一致（§1.7）`）。

- 改动：`f_aspect/src/AspectRoute.cj:255` —— ①内层命中改为置 `matched` 标志、循环后 `if (!matched) { return false }`（原来 `continue` 只结束内层循环，随后必然走到 `return false` ⇒ 恒 false）；②`params.size != annotationNames.size` 时返回 `false`（原来 `for (i in 0..params.size)` 配 `annotationNames[i]`，首项为 `*` 且规则项更少时越界崩溃）；③判定维持"参数**拥有**该注解即通过"（多注解也算命中、无注解不得命中）。**分隔符保持 `&`**（2026-10-05 决定），类注释与 `f_aspect/README.md` 的示例由 `,` 改成 `&`，并写明"个数必须与参数个数一致"。
- 用例：`f_aspect/src/test/arg_annotations_route_test.cj` —— 逐位命中、`*` 占位跳过、位置/顺序不符、参数无注解、参数多注解、规则项多于参数、规则项少于参数（首项 `*`，修前越界）。
- 测量证据：**修前** `testPositionalMatch` = `[ FAILED ] Assert Failed: (ArgAnnotationsRouteRule('${ARG1}&${ARG2}').matches(info('both', 2)) == true)`；`testRuleLengthMustEqualParamCount` = `[ ERROR ] IndexOutOfBoundsException: Index out of bounds: index is '1', but array size is '1'`；合计 `PASSED: 5, ERROR: 1, FAILED: 1`（EXIT=1）。**修后** `PASSED: 7, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0）。
- 兼容性：改前该规则只有"全部项为 `*`"才可能返回 `true`，没有可依赖的旧行为；分隔符维持 `&` 不变。

位置：`src/AspectRoute.cj:258-273`

```cangjie
// AspectRoute.cj:261-271
for (i in 0..params.size) {
    ...
    for (annotation in param.annotations where ...qualifiedName == annotationName) {
        continue        // ← 命中后只是 continue，循环正常结束后继续往下走
    }
    return false        // ← 因此任何非 '*' 项都会走到这里
}
```

影响：内层 `for ... where` 无论命中与否都正常结束，随后必然执行 `return false` ⇒ 只要规则里写了非 `*` 的注解，该规则**永不匹配**（静默失效、无任何提示）；全部写成 `*` 才会返回 `true`（`272`）。修法：命中置标志，循环结束后 `if (matched) { continue }` 再继续外层。

### 1.14 [严重｜性能] `ASP-3` 每次调用都重建函数元信息（反射解析 + 2 个数组 + 参数装箱）（f_aspect）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/aspect`（worktree `.worktrees/aspect`，基线 `7be7225d`），代码、用例、本标记在**同一提交**（提交信息 `perf(f_aspect): ASP-3 类级织入改用静态元信息，不再每次调用重建 QualifiedFuncInfo（§1.14）`）。

- 改动（**路线 1**：宏生成静态元信息，命名按用户指定 `__pOIntcUt_<函数>`）：
  - `f_aspect/src/macros/PointCut.cj`：`pointcut(decl: FuncDecl, metaName!: ?Token = None)` —— 有 `metaName` 时生成 `let info = InvocationFuncInfo(__pOIntcUt_x, $args)`（走现成的 `InvocationFuncInfo(qualifiedFuncInfo, args)` 构造），否则维持原 `InvocationFuncInfo(TypeInfo.of(this), name, argTypes, args)`；类级 `pointcut(decl: ClassDecl)` 为每个被织入函数在类体追加 `private static let __pOIntcUt_x = QualifiedFuncInfo(TypeInfo.of<类>(), '函数', [TypeInfo.of<参数类型>…])`。辅助函数：`weaveOne`（两个类级入口共用）、`metaTokens`、`nextMetaName`（首个 `__pOIntcUt_<名>`，同名重载依次 `_2/_3`，名字被占则放弃静态化）、`isSimpleName`（AST `IDENTIFIER`，运算符名不做）、`hasTypeParams`（`func f<T>` 不做）、`isGenericClass`（`class Foo<T>` 整体不做）。
  - `f_aspect/src/macros/WeavedBean.cj`：类级织入循环改为共用 `weaveOne`/`nextMetaName` 并收集静态元信息追加到类体。
  - **回退面**（保持原行为，不退化为错误）：函数级 `@Pointcut`、运算符名、函数自身带泛型参数、形参是宏展开声明、泛型类、生成名冲突。
- 用例（`f_aspect/src/test/`，新建）：
  - `pointcut_meta_reuse_test.cj`：`@WeavedBean` 目标 + 记录 `qualifiedFuncInfo` 的切面，断言两次调用切面拿到的元数据是**同一对象**（`refEq`）。注意这条只验证「链里捕获的元数据复用」（切面看到的就是链上首次那份）；**每次调用是否重建**对切面不可见，故另加计时用例。
  - `pointcut_meta_cost_test.cj`：无规则命中的 `@WeavedBean` 目标 + 同体 `static` 方法作未织入基线，1e6 次调用打印每调用耗时（量化报告里标注的「倍数待验证」）。
- 测量证据（同机、同用例，用 `git stash push -- <宏文件>` 得到修前版本做 A/B）：
  - **修前**：`每调用耗时：被织入 3931 ns，未织入(static 同体) 2 ns，差 3929 ns（1000000 次）`；
  - **修后**：`被织入 1867 ns，差 1865 ns`（复跑 2209 ns / 2207 ns，含运行间噪声）⇒ 每调用 **≈1.8–2.1×**，即省掉「`TypeInfo.of(this)` + `[TypeInfo.of<T>()…]` 数组 + `getInstanceFunction` 反射解析 + `HashBuilder` + 一次 `QualifiedFuncInfo` 分配」的实测收益。
  - 结构性佐证：修后日志里 `warning: function 'of' is deprecated` 计数 **0**（修前每个被织入类一条），即每调用的 `TypeInfo.of(this)` 确已消失。
  - 行为回归：`cjpm test`（f_aspect）`PASSED: 13, FAILED: 0, ERROR: 0`、`cjpm test success`（含 §1.4 并发/链捕获、§1.6/§1.7 路由规则、§3.2 键稳定性、本次两条新用例）；`cjfmt` 后复跑仍 13/13 绿。
  - 宏消费方构建：`f_orm` `cjpm build success`（EXIT=0）、`f_mvc` `cjpm build success`（EXIT=0，其 `macros/Controller.cj` 会生成 `@Pointcut`）。
- 未覆盖：真实 `@TransactionalService` 消费方（`fcoder` 5 个 impl、`fdemo/user` 2 个 impl）未构建（依赖重）；同类级路径由测试里的 `@WeavedBean` 目标覆盖（与 `@TransactionalService` 走同一 `weave` 实现）。`ASP-6`/`ASP-7` 与本次同处 `Aspects.doProceed`，按用户指示单独处理、未含在本次。

位置：`src/macros/PointCut.cj:115`、`QualifiedFuncInfo.cj:70`、`PointCut.cj:87-94`

```cangjie
// PointCut.cj:115  let info = InvocationFuncInfo(TypeInfo.of(this), $funcName, $argTypes, $args)   // 在被织入函数体开头
// PointCut.cj:87   let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
// QualifiedFuncInfo.cj:70  this(typeInfo, typeInfo.getInstanceFunction(funcName, argTypes))
```

影响：每次调用 = `Array<Any>` + `Array<TypeInfo>` + `InvocationFuncInfo` + `QualifiedFuncInfo` 分配、每个值类型参数**装箱/解箱**（`as T` + `getOrThrow`）、一次 std.reflect 成员解析（`getInstanceFunction` 的实现不在仓库内，倍数**待验证**）。`@TransactionalService` 就是 `WeavedBean` 的别名（`f_orm/src/macros/TransactionalService.cj:19-20`），所以 ORM 的事务方法每次都付这份钱。修法：宏为每个函数生成静态元信息常量（或静态缓存 map），`args` 每调用单独传。

## 2. 中（本模块 4 条）

### 2.4 [中｜正确性] `ASP-9` 嵌套的织入方法调用整体跳过切面（f_aspect）→ ❌误判（2026-10-05：设计目的，非缺陷）

**❌ 误判标记（2026-10-05）**：用户判定为**设计**，非缺陷 —— 同一次织入调用链内不再织入（A 的织入方法调 B 的织入方法时，整个内层调用直接执行原函数体、不执行切面），目的就是 `src/Aspects.cj:73` 注释所写的「避免递归调用切点函数时切面也被重复执行」。分支 `fix/aspect`（worktree `.worktrees/aspect`，基线 `7be7225d`），README 说明与本标记在**同一提交**（提交信息 `docs(f_aspect): ASP-9 嵌套织入跳过为设计，README 说明；bug-aspect.md §2.4 判为设计`）。

- 语义澄清（用户）：**如果希望 A 调 B 时 A、B 都织入切面，`recursiveInvocationFlag` 就应该指定为 false** —— 该标志当前是 `Aspects` 的私有 `ThreadLocal<Bool>`（最外层织入期间被置 `true`、`finally` 里 `remove()`），没有公开开关。
- 文档：`f_aspect/README.md` 新增「嵌套调用与递归（设计）」一节（行为、实现位置与「想要另一种语义」的说明）。
- 本条目不再进入修复队列。

**以下为审查时的原始判断（留档对照）**：

`src/Aspects.cj:63-65`：`recursiveInvocationFlag` 一旦为真就直接 `fn(funcInfo.args)`，A 的织入方法调 B 的织入方法时 B 的事务/日志切面完全不生效（静默语义缺失）。修法：按 `QualifiedFuncInfo` 记调用深度，只对同一函数判定递归。

### 2.9 [中｜内存] `ASP-8` 切面链缓存只增不减、无失效接口（f_aspect）

`src/Aspects.cj:25`（全文无 `remove/clear`）：若某织入函数在切面 bean 注册完成前被调用过一次，**空链会被永久固化**（切面静默失效）；条目上界是织入函数数，但每条会持有首次调用传入的原函数体（`ASP-1` 的设计如此，非缺陷）。修法：暴露 `clear()/refresh()`，并在 bean 注册变更时清理。

### 2.22 [中｜性能] `ASP-6` 切点匹配在 `ConcurrentHashMap.computeIfAbsent` 的桶锁内执行（f_aspect）

`src/Aspects.cj:27-34`：锁内做「遍历全部切面 bean + 注解 + 正则匹配 + 建链」，同桶其它函数首次调用会被阻塞。修法：锁外算好链，再 `putIfAbsent` 写入。

### 2.23 [中｜性能] `ASP-7` 链里存切面**名字字符串**，每次调用重做查找（f_aspect）

`src/Aspects.cj:42`（`f_bean/src/BeanFactory.cj:208-234, 314-316`：`beans.get` + `isSubtypeOf` + 日志闭包）。修法：建链时解析成 `Aspect` 实例并缓存。

## 3. 低危 / 待验证（本模块 8 条）

### 3.1 低危（7 条）

**内存 / 清理**

- `ASP-L4` `Aspects.cj:52-66`：每次调用两次 ThreadLocal 访问（`get` + `set/remove`）并伴随 `?Bool` 装箱；`remove()` 实为 `set(None)`（`f_base/src/ExtendThreadLocal.cj:33-35`）。

**性能微项**

- `ASP-L1` `AspectRoute.cj:85, 139, 162, 344`：每次匹配现构造正则（`Regex.wildcard` = 6 次 `replace` + 键串 + TTL 缓存查找；`Regex('^.+::')` 每次新建）；规则实例无状态，可缓存编译结果。
- `ASP-L2` `ConfigAspectRouteRule.cj:56, 72-242`（多处）：每次匹配重新 `Config.getString` + `split` + 构造新规则对象 + 传闭包；规则内可惰性解析一次并 memo。
- `ASP-L3` `AspectRoute.cj:189-213, 230, 245, 260, 282, 291`：匹配辅助函数每次分配临时 `HashSet`/`ArrayList` 并对每个注解做 `ClassTypeInfo.of`（集合选型本身是哈希，没问题）。
- `ASP-L5` `Aspect.cj:55-64`：每次回调包一层 try/catch/finally；`catch (e: Exception)` 包住全部步骤，默认 `throwing` 新建异常链，`finally` 里 `final()` 抛异常会覆盖原异常。
- `ASP-L6` `macros/PointCut.cj:52-56, 86-94`：宏展开期用 `+=` 在循环里累积 Tokens（编译期平方级拼接，大函数/多参数时明显）。
- `ASP-L7` `Aspects.cj:47-50`：结果统一走 `Any` 链，值类型返回值每次调用装箱（架构取舍，优先级最低）。

### 3.2 待验证（1 条）→ ❌不成立（2026-10-05）

**❌ 不成立标记（2026-10-05）**：分支 `fix/aspect`（worktree `.worktrees/aspect`，基线 `7be7225d`），用例与本标记在**同一提交**（提交信息 `test(f_aspect): ASP-L8 前提不成立（键按值稳定），新增键稳定性用例；bug-aspect.md §3.2 判不成立`）。

- 判定理由：链缓存的键由 (类型, 函数) 唯一确定，且 `QualifiedFuncInfo` 的哈希/相等是**按值**的：`hash = HashBuilder().append(typeInfo).append(funcInfo).build()` 在构造时算一次并存下（`QualifiedFuncInfo.cj:60-84`），`==` 为 `refEq(this, other) || (typeInfo == other.typeInfo && funcInfo == other.funcInfo)`；`TypeInfo` 与 `InstanceFunctionInfo` 都实现 `Equatable`/`Hashable`（`reflect_package_classes.md:1244-1247` 明确 `InstanceFunctionInfo <: Equatable<InstanceFunctionInfo> & Hashable & ToString`，含 `hashCode(): Int64`），不是语言默认的对象身份哈希。报告担心的失效需**同时**满足「每次 `getInstanceFunction` 返回新对象」+「哈希按对象身份」两条，实测两条都不成立。
- 用例：`f_aspect/src/test/qualified_func_info_key_test.cj` —— `testTypeInfoStableAcrossLookups`（两次 `TypeInfo.of<T>()` 值/哈希相等）、`testMemberInfoStableAcrossResolutions`（两次 `getInstanceFunction('probe', [TypeInfo.of<Int64>()])` 结果值/哈希相等）、`testQualifiedFuncInfoKeyHashStable`（两次分别构造的 `QualifiedFuncInfo` 相等且哈希相同）、`testKeyUsedAsMapKeyHitsAcrossCalls`（分别构造的键命中同一 map 条目、`size == 1`，即 `aspects` 的用法）。
- 测量证据：`cjpm test`（f_aspect）→ `PASSED: 11, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0），四条新用例 `[ PASSED ]`（29.8µs / 29.8µs / 16.5µs / 34.0µs；`cjfmt` 后复跑 46.6µs / 34.4µs / 36.3µs / 40.7µs，仍 11/11 绿）；同轮既有用例（§1.4 的并发/链捕获、§1.6/§1.7 的路由规则）全绿。
- 结论：`ASP-L8` 从本模块待修清单移除；`§1.14 ASP-3` 的修法**不需要**为「缓存永不命中 / `aspects` 无界增长」加保底（但 ASP-3 自身「每调用重建元信息」的成本不受此结论影响）。

**以下为审查时的原始判断（留档对照）**：

- `ASP-L8` `Aspects.cj:27`：链缓存命中依赖 `QualifiedFuncInfo.hashCode`（`QualifiedFuncInfo.cj:63, 72-80`，由 `typeInfo.hashCode()` + `funcInfo.hashCode()` 预处理）。**验证（关键假设）**：若 std.reflect 在不同调用间返回不同/非结构化哈希的 `InstanceFunctionInfo`，则缓存**永不命中** ⇒ 切点匹配、正则、建链每次调用重做，且 `aspects` 会**以每次调用一个 key 的速度无界增长**。建议加一条「同一函数多次调用命中同一链」的测试把该假设钉死。

## 4. 逐模块覆盖面（原 §4.4）

### 4.4 f_aspect

**结构**：织入是**编译期宏**（`macros/PointCut.cj` 把每个公共实例函数体包进嵌套函数 `callee`，再调 `Aspects.proceed(info, callee)`），没有动态代理、没有运行时代码生成。运行期只有两个入口：`Aspects.proceed`（递归标志 → `doProceed` → `computeIfAbsent` 取/建拦截器链）与 `Aspect.proceed` 默认模板。**切点匹配已按函数缓存**（`Aspects.cj:27`），匹配不在每次调用的热路径上 —— 这点是对的。

**无实例的维度**：无每次调用新建代理对象/动态生成代理类（编译期宏改写 AST）；无每次调用重建拦截器列表（`computeIfAbsent` 已缓存）；无热点循环内创建 Lambda（建链循环每函数只走一次）；无线性 `contains`（注解名匹配用 `HashSet`）；无「已知规模不预分配」（`AspectRoute.cj:189-190` 反而有预分配）；生成代码里无循环拼接字符串，但**每调用生成 2 个临时集合**（见 `ASP-3`）；无 `catch` 吞异常式控制流（但存在真实越界，见 `ASP-4`）；ThreadLocal 有 `finally { remove() }`（只是 `remove` 非真清除，见 `ASP-L4`）。
