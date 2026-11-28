# f_aspect 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_aspect`（22 个文件：20 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_aspect.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] 非空切面链固化首次调用的 `callee`：同一类型第二个实例上执行的是**第一个实例**的函数体

- **位置**：`f_aspect/src/Aspects.cj:74`（`var f: (Array<Any>) -> Any = {args => fn(args)}`）、`:91-98`（逐层包装后整体存入静态表）、`:101-108`（命中缓存后直接调 `entry[1]`）
- **来源**：存量 —— 快照模式无基线；`git log -S "{args => fn(args)}" -- f_aspect/src/Aspects.cj` 溯到 `c0c8426d1`（2025-04-19「增加aop」）引入，`fc9d62fab`（2025-11-10）只是简化写法；`git blame -L 74,74` 显示当前行属 `2c285e93b7`（2026-10-05），`3161fdeb3`（2026-10-08）只改了 `aspectGetter` 的作用域分支，捕获 `fn` 的部分一直未动
- **判据**：review-checklist §11（契约与实现不符、语义与命名不符）；§5（长期持有 / 闭包捕获大对象）
- **证据**：静态确定 ——
  1. 宏为每个被织入函数生成一个**局部**闭包 `func callee(args: Array<Any>)`（`src/macros/PointCut.cj:97-107`），它捕获的是**本次调用**的 `this`；`Aspects.proceed(info, callee)` 把该闭包传进来（`:104`）。
  2. `doProceed` 首次调用时把 `fn`（即本次 `callee`）包成链尾 `{args => fn(args)}` 并整体放进 `private static let aspects`（`:51`），键只有 `(TypeInfo, InstanceFunctionInfo)`（`:60-61`），**不含实例**。
  3. 之后同类型任意实例的第 N 次调用命中缓存（`:105`），链尾调用的是**首次那个 `callee`**，即首次调用的接收者。`fn` 参数在后续调用里被完全忽略。
  4. 工程内已用用例确认这条路径的存在与影响范围：`src/test/empty_chain_fastpath_test.cj:25-27` 明确写「修复前链被包装成 `{args => fn(args)}`，固化了首次调用的 `callee` ⇒ 第二个实例上执行的是第一个实例的函数体……**有切面命中的链保持「固化首次 callee」的设计不变**」——即只修了空链，非空链的同一缺陷被保留。
- **描述**：只要该 `(类型, 函数)` **命中至少一个切面**，链就属于「类型」而不属于「实例」：
  - `BeanScope.prototype` 的 bean（或测试/工具代码里 `new` 出来的第二个实例）调用同一方法时，方法体在**第一个实例**上执行：读的是第一个实例的字段，写也写到第一个实例；请求级状态（当前用户、事务上下文、临时缓冲）会在实例之间串。
  - 静态表同时**永久强引用首个实例**：`aspects`（static）→ 链闭包 → `aspected` 闭包 → `callee` → `this`，被引用对象无法回收，prototype 场景下等于把「每请求一个实例」退化成「一个常驻实例 + 每请求一个泄漏对象」。
  - 仓库里存在真实触发面：`fdemo/user/src/controller/CurrentUserController.cj:30-32` 用 `@WeavedController` + `@BeanMeta[scope: BeanScope.prototype]`（`@WeavedController` 展开为 `@Bean @Pointcut`，见 `f_mvc/src/macros/Controller.cj:40-44`），而 `fdemo/boot/src/ControllerAspect.cj:23-25` 的 `ControllerAspect` 用 `ConfigExecutionRouteRule('controllerPointcut')` 按配置匹配控制器方法——配置一旦命中，第 2 个请求起的控制器方法会在**第 1 个请求的控制器实例**上跑。
  - 空链（无切面命中）已由 `:101-103` 快路径修正为「用本次 `fn`」，所以该缺陷只影响「有切面」的场景——恰恰是 AOP 的主用途。
- **建议**：把缓存粒度从「整条可执行链」改成「切面实例获取器列表」，`callee` 逐调用传入。最小改法：`aspects` 存 `Array<() -> Aspect>`（singleton 用 `{=> x}`、prototype 用 `{=> …bean}` 的 getter 数组），`doProceed` 每次调用按数组顺序迭代执行（或用一个 `func invoke(layer: Int64, fn: (Array<Any>) -> Any, args: Array<Any>): Any` 递归），不再把 `fn` 存进 static 表。这样保持「规则匹配只做一次」的既有设计（`README.md:106-112`），只牺牲「每次调用 N 次闭包/循环」的极小开销。若确认要保留「按类型固化接收者」，必须在 README 写明「被织入类只能是 singleton 且不得手工 new」，并把 `BeanScope.prototype` + 织入的组合在启动期直接报错——当前代码两者都没有。

### [严重][存量] `TargetAnnotationRouteRule` 读的是**函数**注解，行为与 `FuncAnnotationRouteRule` 完全相同

- **位置**：`f_aspect/src/AspectRoute.cj:228-231`（`TargetAnnotationRouteRule.matches` 调 `contains(funcInfo.funcInfo.annotations, …)`）；对照 `:243-246`（`FuncAnnotationRouteRule.matches` 逐字相同）
- **来源**：存量（快照模式无基线；`git blame -L 228,231` = `4be871f2fd`（2026-10-02），该提交同时写下了 `FuncAnnotationRouteRule` 的同一段；文件最近一次提交 `f08af6b70` 只改了 `ArgAnnotationsRouteRule`）
- **判据**：review-checklist §11（契约与实现不符）；§2（只改类型名的重复逻辑 / 近似重复）；§14（承诺的能力没实现）
- **证据**：静态确定 ——
  1. 契约（README `:324-338`、源码注释 `:219-222`）写明「如果**目标类型**有指定类型的注解则**目标类型的全部公共实例函数**将被织入」，「本规则不适用通配符」；`FuncAnnotationRouteRule` 才是「**目标函数**有指定注解」。
  2. 实现里两条规则都取 `funcInfo.funcInfo.annotations`（`InstanceFunctionInfo` = 函数自身的注解，std 文档 `reflect/reflect_package_api/reflect_package_classes.md:4612-4637`）；`InvocationFuncInfo.typeInfo` 才是所在类型。
  3. std 文档 `reflect_package_classes.md:13020-13034` 明确 `TypeInfo.annotations` 就是「作用于该类型的自定义注解」——修复只需换数据源，无需新 API。
  4. 后果：把 `@TargetAnnotationRouteRule("x.Transactional")` 用在类上时，只有**方法自己也标了**该注解的方法才会被织入；「类上标一次、全类方法生效」这一主要卖点完全失效，且**静默**（不报错、不告警）。依赖它的库存代码会以为事务/日志切面已生效。
- **建议**：`TargetAnnotationRouteRule.matches` 改为 `contains(funcInfo.typeInfo.annotations, annotationNames, sub: sub)`；补一条区分性用例（类型有注解、方法无注解 → `TargetAnnotationRouteRule` true、`FuncAnnotationRouteRule` false），两种规则各一条，放进 `src/test/*_route_test.cj`。

### [一般][存量] 织入规则串解析对「空片段 / 空白 / 通配符」没有兜底，按 README 写法即抛 `InfoNotFoundException`

- **位置**：`f_aspect/src/AspectRoute.cj:109-123`（`ArgsRouteRule` 的 `check`，`:118` `TypeInfos.get(t)`）、`:136-141`（`ReturnTypeRouteRule`，`:139` 通配符不命中后仍走 `TypeInfos.get(returnType)`）；同源复制品 `f_aspect/src/ConfigAspectRouteRule.cj:112-114`（`ConfigFuncTypeRouteRule` 不 trim）、`:143-145`（`ConfigFuncRouteRule` 不 trim）
- **来源**：存量（快照模式无基线；`ArgsRouteRule` 的 `check` 与 `ReturnTypeRouteRule` 的 `||` 链 blame 分别为 `4be871f2fd`（2026-10-02）与 `3570d18100`（2026-10-04）；`Config` 两处不 trim 同属 `4be871f2fd`）
- **判据**：review-checklist §11（边界未处理、错误处理缺失）；§13（文档与实现不符）
- **证据**：静态确定 ——
  1. README `:251-255` 明确写「`*,` 表示忽略第一个参数，`,*,` 表示忽略中间某个参数，`,*` 表示忽略最后一个参数」。`String.split(str, removeEmpty!: Bool = false)` 默认**保留空串**（std 文档 `core/core_package_api/core_package_structs.md:8024-8084`，示例 `"one,two,,three"` 保留 `''`），因此 `",*"` → `["", "*"]`、`"a,,b"` → `["a", "", "b"]`。
  2. `check` 只识别 `"*"`，空串既不等于 `*`、也不以 `<:`/`<:` 结尾，直接落到 `:118` 的 `TypeInfos.get("")`；`f_base/src/TypeInfos.cj:45-47` 的注释与 `f_base/src/TypeInfos_test.cj:37` 都表明未注册名字抛 `InfoNotFoundException`。
  3. `ReturnTypeRouteRule:137-139` 的 `||` 链：`returnType` 含 `*`/`?` 但正则不匹配时，**继续**求值 `TypeInfos.get(returnType)`，此时传入的是含通配符的字符串（同样不是注册类型）→ 抛异常而不是返回 `false`。
  4. `ConfigFuncTypeRouteRule:112-114` / `ConfigFuncRouteRule:143-145` 取 `:` 之后**不 trim**（`ConfigExecutionRouteRule:52-54` 是 trim 的），配置里写成 `f(Int64): Unit`（冒号后带空格）就会把 `" Unit"` 交给 `ReturnTypeRouteRule` → 同上抛 `InfoNotFoundException`。
- **描述**：README 教用户写的两种语法（忽略中间/末尾参数、带空格的可读配置）都会在**建链时抛异常**；由于建链发生在切点函数首次调用（`Aspects.doProceed` 内 `computeIfAbsent`），异常直接从业务方法的第一次调用抛出，且堆栈指向 `TypeInfos.get`，与用户写的规则串无关，排查成本高。README 另称「配置式路由规则的字符串不合法 → 抛 `AspectException`」（`:119-121`），实际这类情况抛的是 `InfoNotFoundException`，与文档的异常契约不一致。
- **建议**：① `ArgsRouteRule.check` 与 `matches(asc:…)` 先 `trim`，空片段等价于 `*`（即「忽略该位」），只有非空的普通限定名才走 `TypeInfos.get`；② `ReturnTypeRouteRule` 拆成三个独立分支：`"*"` → true；含 `*`/`?` → 只做 `Regex.wildcard` 判断，不匹配就 `return false`；否则才 `TypeInfos.get`；③ `ConfigFuncTypeRouteRule` / `ConfigFuncRouteRule` 补 `trimAscii()`（与 `ConfigExecutionRouteRule` 对齐）；④ 把「规则串非法 → `AspectException`」做成统一入口（catch `InfoNotFoundException` 后包 `AspectException(message, caused)`），让文档承诺成立。用例：`",*"`、`"a,,b"`、`"f(Int64): Unit"`、`"x.*"` 四条各一个。

### [一般][存量] `AnyArgAnnotationsRouteRule` 用 `|` 分割，README / 注释写的是 `,`：按文档写永远匹配不到

- **位置**：`f_aspect/src/AspectRoute.cj:287`（`annotationTypes.split('|')`）；文档 `README.md:371-380`、`README_en.md:398-408`、源码注释 `:281`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（API / 参数与源码不符）；§11（契约与实现不符）
- **证据**：静态确定 —— 三处文档一致写「多个注解用`,`分割」，实现只认 `'|'`。传 `"a.A,b.B"` 时会去比对字面量 `"a.A,b.B"` 这一个注解名，`ClassTypeInfo.of(annotation).qualifiedName == "a.A,b.B"` 恒不成立 → `matches` 恒 `false`（无异常、无日志）。
- **描述**：与同族规则的分隔符约定也不一致：`ArgPrefix/Suffix` 用 `,`、`ArgAnnotations` 用 `&`、`TargetAnnotation`/`FuncAnnotation` 用 `&`，本规则偏偏用 `|`。用户按 README 写就是「切面静默不生效」。`ConfigAnyArgAnnotationsRouteRule`（`ConfigAspectRouteRule.cj:207-211`）直接把配置串传下来，同样受影响。
- **建议**：统一改为 `split(',')` 并同步 README/注释；若确实需要 `|`（与 `ConfigExecutionRouteRule` 的多条分隔符一致），必须同时改三处文档并说明为什么这一族用 `|`。补一条 `AnyArgAnnotationsRouteRule("A,B")` 的正/负用例。

### [一般][存量][待确认] `@WeavedBean` 的织入循环没有排除 `init`，`@Pointcut` 类级路径明确排除了

- **位置**：`f_aspect/src/macros/WeavedBean.cj:55`（`case f: FuncDecl where f.isPublic() && !f.isStatic()`）、`:71`（宏展开声明同条件）；对照 `src/macros/PointCut.cj:118`（`… && d.identifier.value != 'init'`）与 `PointCut.cj:204`（`metaTokens` 对 `init` 返回 `None`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（近似重复导致的行为漂移）；§2（同一判断两处不一致）
- **证据**：待确认 —— 缺的是「`public init(...)` 在 `std.ast` 里是 `FuncDecl` 还是 `PrimaryCtorDecl`」这一条。条件若成立，后果是静态确定的：`@WeavedBean` 会把构造函数包成 `callee` + `Aspects.proceed(TypeInfo.of(this), 'init', …)`，而 `QualifiedFuncInfo.init` 走 `typeInfo.getInstanceFunction('init', argTypes)`（`QualifiedFuncInfo.cj:73`），构造函数不是实例成员函数；即便能解析，构造函数也被纳入「按类型固化 callee」的范围（见 #1），第二个实例的构造会在第一个实例上重放初始化。`PointCut.cj:118` 与 `:204` 两处显式排除 `init` 说明作者已经意识到这一点，`WeavedBean` 只是漏了。
- **描述**：`@WeavedBean` 与 `@Pointcut`（类级）是同一件事的两个入口（README `:64-93` 把它们并列），却对「哪些成员该织入」给了两个不同的答案。工程内 `@WeavedBean` 现有用例（`src/test/empty_chain_fastpath_test.cj:29`、`pointcut_meta_cost_test.cj:29`、`pointcut_meta_reuse_test.cj:27`、`recursion_guard_test.cj:27`）都没有显式构造函数，所以现有测试拦不住。
- **建议**：`WeavedBean.weave` 的 `where` 条件补 `&& f.identifier.value != 'init'`（与 `PointCut.cj:118` 对齐）；若用户确实需要织入构造，必须先解决 #1 的接收者问题并单独设计。补一条 `@WeavedBean public class X { public init() {} }` 的用例钉住行为。

### [一般][存量] 类级织入循环在两处宏里重复实现，且已漂移出实际差异（§2）

- **位置**：`f_aspect/src/macros/PointCut.cj:110-152`（`pointcut(decl: ClassDecl)`）与 `f_aspect/src/macros/WeavedBean.cj:43-90`（`weave`）——`allowMeta` / `metas` / `usedNames` / `ord` / `weaveOne` / 尾部 `decls.add(parseDecl(m))` 逐段对齐，唯一实质差别是 `init` 过滤（见 #5）与改写方式（前者 `let decls = decl.body.decls; decls[i] = …`，后者 `decls[i] = match …`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流的重复逻辑 / 近似重复导致行为漂移）
- **证据**：静态确定 —— 两段代码把同一组本地状态（`ArrayList<Tokens> metas`、`HashSet<String> usedNames`、`HashMap<String,Int64> ord`）按同一顺序初始化，循环体调用同一个 `weaveOne(f, classIdent, metaName)`，末尾同样 `for (m in metas) { decls.add(parseDecl(m)) }`。`PointCut.cj:118` 有 `!= 'init'`，`WeavedBean.cj:55` 没有——这正是 #5 的成因。
- **描述**：同一根因（「哪些成员要织入 + 静态元信息怎么生成」）有两份实现，改一处不会同步另一处，已经产生了实际行为分叉。此外 `TargetAnnotationRouteRule` / `FuncAnnotationRouteRule`（`AspectRoute.cj:228-246`）与 `Config` 家族三处声明串解析（`ConfigAspectRouteRule.cj:44-55`、`:105-113`、`:136-146`）也是同型复制：后者三份只差「是否 trim」与「是否有 funcName 段」，`ConfigExecutionRouteRule` 独有 trim 已经造成 #3 的 `" Unit"` 崩溃。
- **建议**：把类级织入循环收进 `PointCut.cj` 的一个 `func weaveClass(decl: ClassDecl, excludeInit: Bool): Tokens`，`WeavedBean` 只负责生成 `@Bean` 包裹；声明串解析抽 `private func parseFuncDecl(qualified: String): (String, String, String, String)`（qualifiedName / funcName / argTypes / returnType，内部统一 `trimAscii`），`ConfigExecutionRouteRule` / `ConfigFuncTypeRouteRule` / `ConfigFuncRouteRule` 共用。合并后再补 #5 的用例。

### [一般][存量] README 承诺「切点函数没有匹配到任何切面 → 抛 `AspectException`」，实现已改成空链快路径（§13）

- **位置**：`f_aspect/README.md:119-121`、`README_en.md:127-129`；实现 `f_aspect/src/Aspects.cj:69-71`（空链记 `(true, emptyChain)`）、`:101-103`（`entry[0]` 为 true 时直接 `fn(funcInfo.args)`）
- **来源**：存量（快照模式无基线；README 该段由 `8fc74320c` 补齐）
- **判据**：review-checklist §13（文档承诺与实现相反）
- **证据**：静态确定 —— 唯一会抛 `'no aspect matches this pointcut'` 的是 `emptyChain`（`:56-58`），而空链分支在 `:101` 就直接返回，`entry[1]` 根本不会被调用；仓内搜索 `no aspect matches` 只有这一处定义、无调用点。也就是说「无切面命中」现在**不抛异常**，行为是「按原函数执行」。
- **描述**：这条契约有三重影响：① 使用者会按 README 写 `catch (e: AspectException)` 来兜「切面没生效」，实际永远进不去；② 真正的风险（规则写错、切面注册晚于首次调用）表现为**静默不织入**，比抛异常更难发现；③ `emptyChain` 的 lambda 体成为不可达代码（见 #10）。
- **建议**：二选一并同步中英文 README —— ① 保留快路径，把该条从「`AspectException` 抛出场景」删掉，另加一段「无切面命中时静默执行原函数，请用日志/断点确认规则命中」；② 若希望「未命中即失败」（例如 `f_orm` 依赖切面保证事务），在 `computeIfAbsent` 里按配置决定是否抛 `AspectException`，默认关闭以兼容现状。

### [一般][存量] README 指向的 `recursiveInvocationFlag` / `ThreadLocal<Bool>` 已不存在（§13）

- **位置**：`f_aspect/README.md:100-101`、`README_en.md:106-107`；实现 `f_aspect/src/Aspects.cj:32-34`（`private class RecursionState { var state = false }`）、`:112`（`private static let recursion = ThreadLocal<RecursionState>()`）、`:115-128`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档指向已删除 / 改名的符号）
- **证据**：静态确定 —— 全仓 `grep -rn "recursiveInvocationFlag"`（排除 `.worktrees`）零命中；README 说「`private static let … = ThreadLocal<Bool>`」，实际是 `ThreadLocal<RecursionState>` + `getOrCompute`（`f_base/src/ExtendThreadLocal.cj:24-32`）+ `st.state = true/false`。README 同段描述的 `try { … } finally { remove() }` 也与实现不符（现在是 `finally { st.state = false }`，不再 `remove()`）。
- **描述**：「嵌套调用不再织入」这条语义本身是正确的（第 2 部分 `recursion_guard_test.cj` 钉住了它），但 README 让读者去 `src/Aspects.cj` 找一个不存在的东西，属于「按文档查代码查不到」。同段还保留了「旧写法每次最外层调用都会把 `true` 装箱进 ThreadLocal」这类已过期的实现叙述。
- **建议**：README 改为「`Aspects` 内 `private class RecursionState` + `ThreadLocal<RecursionState>`（`src/Aspects.cj:32-34,112`），最外层置 `state = true`、`finally` 复位」；删掉 `remove()` / 装箱的描述，或把这段实现的来龙去脉移到代码注释里（`Aspects.cj:25-31` 已有等价内容），README 只保留语义与入口。

### [一般][存量] `Config*RouteRule` 全族 15 个 public 类零文档，README 还引用了不存在的 `ConfigAspectRouteRule`（§14.2）

- **位置**：`f_aspect/src/ConfigAspectRouteRule.cj:21-245`（`ConfigRouteRule` + 15 个 `Config*RouteRule`）；`README.md:111` / `README_en.md:119`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 索引未登记）；§13（引用不存在的类型）
- **证据**：静态确定 ——
  1. README 只有一句「`Config*RouteRule`（如 `ConfigAspectRouteRule`）匹配时才读配置」；`grep -rn "class ConfigAspectRouteRule" f_aspect/src` 零命中，只有同名文件里定义的 `ConfigRouteRule`。真正存在的 15 个类（`ConfigExecutionRouteRule` / `ConfigWithinRouteRule` / `ConfigArgsRouteRule` / … / `ConfigBeanNameRouteRule`）README 一个都没提。
  2. 这些类**不是内部实现**：`fdemo/boot/src/ControllerAspect.cj:24` 与 `f_orm/src/base/TransactionAspect.cj:26` 都在用 `ConfigExecutionRouteRule`，说明它是下游接入切面的正规入口。
  3. 缺失的关键信息全在代码里：配置键怎么命名（`Config.getString(config)`，`ConfigAspectRouteRule.cj:27`）、`ConfigExecutionRouteRule` 的串格式 `a.b.C.f(Int64):Unit|a.b.D.g():Unit`（`:43-56`）、`<:` 前缀表示 `sub`（`:168-172`、`:183-187`）、`matchIfNone!` 缺配置时的默认值（`:22-24`、`:29-35`）。按 README 用不起来。
  4. 同类遗漏：`Aspects.proceed` 是 `public`（`Aspects.cj:113-114`），README 只在「并发」段落提到 `Aspects` 这个名字，没有说明它是宏生成代码的调用入口、也不建议直接使用（代码注释 `:113` 已写明「不是给开发者用的」——这条约束没有进 README）。
- **描述**：切面规则是本模块最复杂的对外能力（通配符、子类型方向、注解分组、配置式覆盖），README 却只覆盖了注解式的一半；配置式的字符串语法只能靠读源码反推，且唯一的示例类名是错的。
- **建议**：README 新增「配置式路由规则」一节：① 配置键约定与 `matchIfNone` 语义表；② `ConfigExecutionRouteRule` 的串格式示例（含 `|` 多规则、`:` 后返回类型、`(` 内参数表）；③ `Config*Annotation*` 的 `<:` 前缀含义；④ 与注解式规则「首次调用才读配置、之后不生效」的差别（`README.md:110-112` 已有，指过来即可）；⑤ 把 `ConfigAspectRouteRule` 改成真实类名 `ConfigRouteRule`；⑥ 补一句 `Aspects.proceed` 只供宏生成代码调用。

### [轻微][存量] `emptyChain` 占位 lambda 的函数体不可达（§1）

- **位置**：`f_aspect/src/Aspects.cj:56-58`（`_ => throw AspectException('no aspect matches this pointcut')`）、`:69-71`、`:51`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（注册了但永不触发的回调 / 恒不成立的分支）
- **证据**：静态确定 —— `emptyChain` 只作为「空链」元组的占位值写入（`:71`），而所有读取点（`:101-108`）在 `entry[0] == true` 时走 `fn(funcInfo.args)`、不再调用 `entry[1]`；仓内没有其它读取 `aspects` 的位置（`private static let`，全仓仅本文件引用）。因此 `:57` 的 `throw` 永远不会执行。
- **描述**：占位值是必要的（元组第二项类型不能为 `None`），但**带抛异常的 lambda 体**没有必要：它让读者误以为「无切面 = 抛异常」（README 正是这么写的，见 #7），并掩盖了「空链是正常路径」的设计。属于「死代码 + 误导」双重问题。
- **建议**：占位值本身可以保留（元组第二项类型不能为 `None`），但**带抛异常的 lambda 体**没必要；更彻底的做法是把缓存值类型改成 `Array<() -> Aspect>`，空数组即空链，元组第一项 `Bool` 与 `emptyChain` 一起消失——与 #1 的修法同源。

### [轻微][存量] `ConfigRouteRule.doMatches` 的 `funcInfo` 参数从未使用（§1 读了不用）

- **位置**：`f_aspect/src/ConfigAspectRouteRule.cj:29-35`；全部 15 个调用点（`:42`、`:71`、`:82`、`:93`、`:104`、`:124`、`:135`、`:156`、`:167`、`:182`、`:197`、`:208`、`:219`、`:230`、`:241`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用 / 无用参数）
- **证据**：静态确定 —— `doMatches` 形参 `funcInfo: InvocationFuncInfo` 在函数体内零引用（只用到 `config` / `matchFn` / `matchIfNone`）；15 处调用都老老实实把 `funcInfo` 传进来。`ConfigRouteRule` 是 `public abstract`（非 `sealed`），其 `protected doMatches` 属扩展点，不判死代码，但**无用的形参**仍是噪音。
- **描述**：读者会以为匹配逻辑依赖 `funcInfo`（例如将来要做「函数级缓存」），实际只依赖配置串；若下游有人继承 `ConfigRouteRule` 覆写 `doMatches`，也会被这个形参误导。属于接口设计残留。
- **建议**：删掉该形参（同步 15 个调用点）；若保留是为将来扩展预留，加一行注释说明「当前不参与匹配，仅为子类覆写保留」——但按仓颉惯例更建议删掉，需要时再加。

### [轻微][存量] README 的 `Aspect` 示例只标了 `@Bean`，照抄的切面永远不会生效（§13/§14）

- **位置**：`f_aspect/README.md:3`（「切面是实现了 `Aspect` 接口有被 `@Bean` 修饰的类」）、`:71-75`（`@Bean public class AspectClass <: Aspect { … }`）；`README_en.md:3`、`:77-81`；正确契约见 `README.md:13`（`Aspect` 接口注释「必须被 `@AspectRoute` 修饰」）与 `Aspects.cj:63-68`（只有带 `AspectRoute` 注解的 bean 才参与匹配）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（示例不能用）；§14.2（示例覆盖不足 / 误导）
- **证据**：静态确定 —— `doProceed` 的过滤条件是 `beanType.findAnnotation<AspectRoute>()?.matches(funcInfo) ?? false`（`Aspects.cj:63-66`），没有 `@AspectRoute` 的 `Aspect` bean 永远进不了 `list`；README 的首段定义和示例都漏了这一层，只有接口注释里提了一句。
- **描述**：使用者按「开头三条 + 第一个示例」写出来的切面能编译、能注册，但**不织入任何函数**，且没有任何报错（正好撞上 #7 的静默语义）。这是文档最容易把人带沟里的形态：错误不在语法，在缺失的必要注解。
- **建议**：`:3` 改成「切面是实现了 `Aspect` 接口、被 `@Bean` 注册且被 `@AspectRoute` 声明织入规则的类」；`:71-75` 的示例补 `@AspectRoute[FuncNameRouteRule("…")]`（或直接指向 `:152-167` 的规则章节）。

### [轻微][存量] `pointcut_meta_cost_test` 用 100 万次循环计时但不校验任何数值，基线还选了 `static` 方法

- **位置**：`f_aspect/src/test/pointcut_meta_cost_test.cj:48-70`（`:59` `toNanoseconds() / rounds`、`:69` 唯一断言 `@Assert(bean.c(7), 7)`）
- **来源**：存量（快照模式无基线；`git blame -L 48,50` = `ad8cc477c`（2026-10-05「perf(f_aspect): ASP-3 类级织入改用静态元信息」），该提交以此用例度量织入开销）
- **判据**：review-checklist §11（语义与命名不符：名为 `test…` 却只打印）；§6.1（无对照/无中断的计时不构成热点证据）
- **证据**：静态确定 —— 测得的 `woven` / `plain` 只被 `println`（`:67-68`），没有任何 `@Assert` 引用；基线是**静态方法** `MetaCostTarget.cStatic`，与实例方法调用相比多算了接收者分派差异（并非「织入开销」的纯净对照），且单轮 `1e6` 次调用会让 `cjpm test`（默认 `-O0`）多花数秒。
- **描述**：这条用例的真实作用是「手工观测工具」，放在 `@Test` 里既不能失败也不能回归；一旦有人按它的输出写性能结论，还会把静态/实例分派差异算进 AOP 开销。
- **建议**：改成 `cjpm bench` 基准（同 SDK、`-O2`、多轮取中位数）或移到 `bench/` 目录；若要留在单测里，至少把基线换成「同类的未织入实例方法」（`@Pointcut` 只改写 public 实例方法，可用一个不带 `@WeavedBean` 的同体类），并对「织入开销 < 某个上限」加断言（上限取宽，避免抖动）。

<!-- 第 2 部分 -->

### [一般][存量] 两个测试文件的版权头年份 2025 与文件新建年 2026 不符

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:2`、`f_aspect/src/test/recursion_guard_test.cj:2`
- **来源**：存量 —— 快照模式无基线；`git blame -L 1,3` 显示两份文件各自只有一个提交（`d69d2ce832` / `ba4288006d`，2026-10-05），版权行由该提交同年写入、此后未改
- **判据**：fountain-baseline §3「缺头、头在 `package` 之后、年份与新建年不符，都按『一般』报」
- **证据**：静态确定 —— `git log --diff-filter=A --format=%ad --date=short -- <file>` 得 `2026-10-05`；对照仓内同为 2026 年新增的文件（`f_a2a/src/A2a.cj`、`f_a2a/src/model/A2aJson.cj` 等，新增于 2026-11-10）头写 `Copyright (c) 2026`，说明约定是「版权年 = 文件创建年」
- **描述**：两份文件的头都是 `Copyright (c) 2025`，而内容是 2026-10 的 ASP-L4 / ASP-L8 修复配套用例。同模块另外 8 个测试文件（`arg_prefix_suffix_route_test.cj`、`aspect_args_race_test.cj`、…）也全部是「2026 新建 + 2025 头」，属模块级漂移，本部分只统计这 2 个。
- **建议**：改成 `Copyright (c) 2026`。若团队约定「版权年份固定写项目起始年 2025」，请把该约定写进 `fountain-baseline.md` §3，避免每轮审查重复报同一件事。

### [轻微][存量] `recursion_guard_test` 只验证「切面进入一次」，不验证状态复位，也未覆盖 README 的「A 调 B 不织入」

- **位置**：`f_aspect/src/test/recursion_guard_test.cj:56-63`（`:59` 只调一次 `bean.r(3)`，`:61` 只断言 `entries.size == 1`）；实现 `f_aspect/src/Aspects.cj:112-128`（复位在 `:120-122` 的 `finally { st.state = false }`）；承诺源 `f_aspect/README.md:98-102`、`README_en.md:104-106`
- **来源**：存量（`ba4288006d`，2026-10-05，文件唯一提交）
- **判据**：review-checklist §11（语义与用例注释不符：注释说「改动前后都必须成立」，断言覆盖不到复位路径）；§14.1（README 承诺的两条语义只钉住一条）
- **证据**：静态确定 ——
  1. **复位路径无断言**：若 `finally` 里的 `st.state = false` 被删掉或写错，`r(3)` 的返回值仍是 6、`entries` 里仍只有 1 条 3，本用例照样全绿；而该线程上此后所有切面会永久失效（`Aspects.cj:124-125` 直接 `fn(funcInfo.args)`）。
  2. **A→B 语义无用例**：README `:98-101` 明确写「切点函数 A 的织入方法内部再调用切点函数 B … 内层调用直接执行原函数体，不再执行切面 … 因此 A 调 B 时 B 的切面**不会**执行」。本用例只覆盖自递归：`RecursionTarget` 是 `f_aspect/src/test/*.cj` 里唯一被 `@WeavedBean` 修饰的类（`grep -rn "@WeavedBean" f_aspect/src/test` 共 4 处命中，分属 4 个互不调用的目标类），没有任何用例让一个被织入类去调用另一个被织入类。
- **描述**：这条守卫同时承担两件事——避免递归重复执行切面、避免「切面里再调织入函数」无限递归。前者被钉住了一半（只钉「不重复」，没钉「结束后恢复」），后者完全没被钉住。跨 bean 抑制是最容易被后续改动（例如「让嵌套调用也织入」这种看似合理的调整）破坏的语义，也是最难从失败现象反推的语义：一旦被破坏，切面会在同一请求里重复执行，事务/日志类切面会静默重复提交。
- **建议**：① 在 `:63` 之后补第二次顶层调用：`@Assert(bean.r(1), 1)`、`@Assert(RecursionCountAspect.entries.size, 2)`、`@Assert(RecursionCountAspect.entries[1], 1)`，把 `finally` 复位钉死；② 新增第二个 `@WeavedBean` 目标类（如 `class SecondaryTarget { public func s(): Int64 { 1 } }`）与配套的 `FuncNameRouteRule("s")` 计数切面，在 `RecursionTarget.r` 的 `n <= 0` 分支里调一次 `s()`：断言最外层 `r(3)` 返回后 `s` 的计数为 0，再单独调 `s()` 后计数为 1。

### [轻微][存量] `recursion_guard_test` 的静态可变状态与全局注册没有清理，用例默认「本进程尚未启动 BeanFactory、每条只跑一次」

- **位置**：`f_aspect/src/test/recursion_guard_test.cj:41`（`public static let entries = ArrayList<Int64>()`）、`:44`（`entries.add`）、`:57`（`BeanFactory.instance.register`）、`:38`（注释「不读 args 做判断，无状态、不加锁」）
- **来源**：存量（`ba4288006d`）
- **判据**：review-checklist §12.1（共享可变状态无保护、未声明线程封闭）；§11（注释与实现不符）
- **证据**：静态确定（注册语义）+ 待确认（是否会出现同进程二次执行/启动）——
  1. `entries` 永不 `clear()`，`:61` 的 `size == 1` 依赖「本进程内这条用例只执行一次且没有别的调用者」。`before` 里的 `ArrayList.add` 无任何同步，注释却写「无状态」——实际是跨调用共享的可变静态状态；一旦按 `@Test[parallel]` 并行跑、或有人在同进程里再调一次 `r`，`size` 断言会直接失败且 `ArrayList` 本身不保证安全。
  2. `BeanFactory.instance.register`（`f_bean/src/BeanFactory.cj:142`）→ `doRegister`：`registered.load()` 为真时抛 `BeanException('To register bean to a registered BeanFactory is forbidden')`（`:58-59`），同名重复注册抛 `duplicate bean name`（`:73-74`）。当前 `f_aspect/src/test/*.cj` 里无一处调用 `afterRegistered()`，所以能过；只要后续有人在同包用例里补一次「模拟框架启动」，这条用例就会随执行顺序偶发失败，而失败信息指向 `BeanFactory` 而非本条用例。
- **描述**：测试的可重复性建立在两个未写明的进程级前提上；`entries` 既是对外 `public` 的静态容器（同包其他用例可写），又是唯一断言来源，任何一处污染都会变成「随机红」。
- **建议**：把计数改成 `AtomicInt64`（`enterCount.fetchAdd(1)`）或保留 `entries` 但在用例开头 `entries.clear()`、结尾清理；注释改成「静态计数、单线程使用」；若同包还要加启动模拟，用 `@BeforeAll/@AfterAll` 或把该用例放到独立测试类并注明顺序依赖。

### [轻微][存量] `qualified_func_info_key_test.cj` 注释里的两处引用已失效（文档改名、行号漂移）

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:33`（`bug-aspect.md` §3.2）、`:60`（`PointCut.cj:115`）
- **来源**：存量（`d69d2ce832`，2026-10-05）
- **判据**：review-checklist §11（注释与实现不符）；§13（引用不存在的文档 / 失效路径）
- **证据**：静态确定 ——
  1. 全仓 `grep -rn "bug-aspect.md"`（排除 `.worktrees`）只有这一处命中；`.autocode/bugs/` 下只有 `bug-aspect-archived-20261006.md`。该文件 `:210`「ASP-L8 从本模块待修清单移除」、`:214`「ASP-L8 前提…建议加一条『同一函数多次调用命中同一链』的测试把该假设钉死」，正是本用例的依据。
  2. `f_aspect/src/macros/PointCut.cj:115` 是 `var ord = HashMap<String, Int64>()`（静态元信息命名的序号表），与键构造无关；真正生成 `InvocationFuncInfo` 的是 `:94-95`（静态元信息分支 / 每调用构造分支），生成 `QualifiedFuncInfo` 静态元信息的是 `:220`（`metaTokens`）。
- **描述**：`recursion_guard_test.cj:49-51` 同样引用了「README『嵌套调用与递归（设计）』」，该章节存在但实现描述已过期（`recursiveInvocationFlag` 已不存在，见第 1 部分 #8）——两处引用叠起来的效果是：读者沿着注释去核对时，既找不到 bug 文档，也会被 README 里不存在的符号带偏。
- **建议**：`:33` 改为 `.autocode/bugs/bug-aspect-archived-20261006.md §3.2`；`:60` 改为 `PointCut.cj:94-95,220`；`recursion_guard_test.cj:49-51` 的 README 引用等第 1 部分 #8 修完后再保留（或直接指向 `src/Aspects.cj:112-128`）。

### [轻微][存量] 两个文件都 `import fountain::f_base.*`，但没有任何 f_base 符号被使用

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:22`、`f_aspect/src/test/recursion_guard_test.cj:21`
- **来源**：存量（两份文件均为单次提交，`d69d2ce832` / `ba4288006d`）
- **判据**：review-checklist §1（机制动作 7：未使用的 `import`）
- **证据**：静态确定 —— 两个文件用到的外部符号只有 `TypeInfo`、`QualifiedFuncInfo`、`HashMap`、`ArrayList`、`Int64`、`Aspect`、`InvocationFuncInfo`、`AspectRoute`、`FuncNameRouteRule`、`Aspects`、`@WeavedBean`、`BeanFactory`、`@Test/@TestCase/@Assert`；其中 `TypeInfo` 由 `std.reflect`（qualified `:21`）与 `f_aspect` 的 `public import std.reflect.TypeInfo`（`src/imports.cj:27`）提供，其余分别来自 `fountain::f_aspect.*`、`fountain::f_aspect.macros.*`、`fountain::f_bean.BeanFactory`、`std.collection`。宏展开产物（`PointCut.cj:94-95`、`:220`）只用到 `TypeInfo` / `QualifiedFuncInfo` / `Aspects` / `InvocationFuncInfo`，同样不来自 `f_base`。
- **建议**：删除这两行 import（顺带删掉 `qualified_func_info_key_test.cj:21` 的 `std.reflect.*` 也可——`TypeInfo` 已由 `f_aspect` 的 public import 透出；保留则至少删 `f_base`）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [CPU] 织入调用每次都构造 `Array<Any>` 实参数组与 `InvocationFuncInfo`，空链也要付这份成本

- **现状**：宏为每个被织入函数生成 `let info = InvocationFuncInfo($meta, $args)`（`src/macros/PointCut.cj:93-104`），`$args` 是 `[a, b, …]` 数组字面量并逐参做 `as` 转换（`:64-76`），即**每次调用**分配 1 个 `Array<Any>`、并对每个值类型参数（`Int64` / `Bool` / 小 `struct`）装箱一次；函数体本身也必须从 `args[i]` 解箱后才能执行（`callee` 的唯一入口就是 `Array<Any>`，`:99-102`）。空链时（`Aspects.cj:101-103`）这些分配与装箱全是为「可能存在的切面」付的，而实际上没有任何切面。
- **方案**：让宏额外生成一份**强类型入口**，把「空链快路径」从 `Array<Any>` 里解耦：
  ```cangjie
  func body(a: A, b: B): T { /* 原函数体 */ }
  func callee(args: Array<Any>) { body((args[0] as A).getOrThrow(), …) }
  let info = InvocationFuncInfo(__pOIntcUt_x, [a, b])
  Aspects.proceed(info, body, callee)   // 新增重载：proceed(info, fast: () -> T, callee)
  ```
  `doProceed` 命中空链时走 `fast()`（不建 `Array<Any>`、不装箱），非空链仍用 `callee`（切面可以改参数）。`InvocationFuncInfo` 的构造也要一并延后到「非空链」分支才知道需要——可以把 `info` 改成 `() -> InvocationFuncInfo` thunk，或在宏里只在 `aspects` 命中后构造（需要 `Aspects` 暴露一个 `hasAspect(key)` 查询）。
- **预期**：空链场景每次调用少 1 个 `Array<Any>` 分配 + N 次装箱/解箱；对 `Int64` 参数的小方法，这部分通常就是织入开销的主体（具体量级待测，见待验证假设 #2/#3）。
- **代价**：① `Aspects.proceed` 增加重载（宏生成代码与 3 个测试直接调用它：`src/test/aspect_args_race_test.cj:82`、`aspect_chain_capture_test.cj:88`、`aspect_template_suppress_test.cj:82`）；② 宏产物体积增加一份 `body` 函数（每被织入函数多一个方法）；③ 与原函数体同名的 `body` 需要防撞名（可复用 `__pOIntcUt_` 前缀；`nextMetaName` 只防生成名互撞，不防用户同名，需一并处理）。
- **验证**：`cjpm bench -O2`，同一「无切面命中的 `@WeavedBean` 方法」在改造前后各 5 轮取中位数与离散度；并加分配计数确认单次调用分配量从「1 数组 + N 箱」降到 0。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

> 本部分只有测试代码，没有长期驻留的堆结构、没有可测量的热点路径。无「堆内存」「CPU」方案。

## 待验证假设

<!-- 第 1 部分 -->

> 本部分没有 profile / bench 数据，以下只是下一轮补数据的清单，均**不进** `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 织入调用主路径（`ThreadLocal.getOrCompute` + `computeIfAbsent` + 闭包链）自耗时占比显著 | `f_aspect/src/Aspects.cj:114-128`、`:101-108` | 自耗时占比、与未织入同体方法的绝对差 | `cjprof record` 跑 `pointcut_meta_cost_test` 的 1e6 次场景（改 `-O2`），按函数过滤 `Aspects.proceed` / `doProceed` / `computeIfAbsent` |
| 2 | 每次调用构造 `Array<Any>` 的分配是空链场景的主要 GC 压力 | `f_aspect/src/macros/PointCut.cj:64-76`、`:93-104` | 单次调用分配字节数、GC 次数 | 同场景加分配计数（或 `cjprof heap`），对比 0 参 / 3 参 / 5 参三种方法 |
| 3 | 非空链每调用一次的 `Any` 装箱/解箱（`entry[1](args)` → `case x: T`）是值类型返回方法的固定开销 | `f_aspect/src/Aspects.cj:105-108` | 装箱/解箱的 CPU 占比 | 对 `Int64` / `String` / 大 `struct` 三种返回值各跑 1e6 次，`cjprof` 对比 |
| 4 | 建链期反复编译 `Regex`（每条规则每次 `matches` 都新建）占建链耗时的主要部分 | `f_aspect/src/AspectRoute.cj:80`、`:85`、`:161`、`:138`、`:354` | 建链总耗时、Regex 编译占比 | 只用「首次调用」的冷启动路径计时（预热前后各一次），输入为 20 条规则 × 200 个切点；收益上限低（每 (类型,函数) 一次），先测再决定 |
| 5 | 没有切面命中的函数依然要付 `computeIfAbsent` 的哈希与桶锁成本 | `f_aspect/src/Aspects.cj:61` | 空链调用与「完全未织入」的差 | 同 #1 对照，单独统计 `entry[0] == true` 分支的调用次数与耗时 |

<!-- 第 2 部分 -->

> 本部分没有性能测量需求，也没有热点/瓶颈猜测。以下仅登记一个「用例可重复性」的待确认项，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 是否存在「同进程二次执行同一条 `@TestCase`」或「同包用例里有人调用 `BeanFactory.instance.afterRegistered()`」的路径（前者会让 `entries.size == 1` 必然失败，后者会让 `register` 抛 `BeanException`） | `f_aspect/src/test/recursion_guard_test.cj:41,57,61` | CI / IDE 测试运行器的调度方式（是否复用进程、是否并发） | 在 `cjpm test` 与 IDE 单测运行器下各跑一次整包，观察是否重复执行；`grep -rn "afterRegistered" f_aspect/src/test` 定期复查 |

## 文件覆盖

> 与 `files/f_aspect.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_aspect/README.md` | .md | ✅ | — |
| 2 | `f_aspect/README_en.md` | .md | ✅ | — |
| 3 | `f_aspect/src/Aspect.cj` | .cj | ✅ | — |
| 4 | `f_aspect/src/AspectRoute.cj` | .cj | ✅ | — |
| 5 | `f_aspect/src/Aspects.cj` | .cj | ✅ | — |
| 6 | `f_aspect/src/ConfigAspectRouteRule.cj` | .cj | ✅ | — |
| 7 | `f_aspect/src/QualifiedFuncInfo.cj` | .cj | ✅ | — |
| 8 | `f_aspect/src/exception/AspectBeforeException.cj` | .cj | ✅ | — |
| 9 | `f_aspect/src/exception/AspectException.cj` | .cj | ✅ | — |
| 10 | `f_aspect/src/imports.cj` | .cj | ✅ | — |
| 11 | `f_aspect/src/macros/PointCut.cj` | .cj | ✅ | — |
| 12 | `f_aspect/src/macros/WeavedBean.cj` | .cj | ✅ | — |
| 13 | `f_aspect/src/test/arg_annotations_route_test.cj` | .cj | ✅ | — |
| 14 | `f_aspect/src/test/arg_prefix_suffix_route_test.cj` | .cj | ✅ | — |
| 15 | `f_aspect/src/test/aspect_args_race_test.cj` | .cj | ✅ | — |
| 16 | `f_aspect/src/test/aspect_chain_capture_test.cj` | .cj | ✅ | — |
| 17 | `f_aspect/src/test/aspect_template_suppress_test.cj` | .cj | ✅ | — |
| 18 | `f_aspect/src/test/empty_chain_fastpath_test.cj` | .cj | ✅ | — |
| 19 | `f_aspect/src/test/pointcut_meta_cost_test.cj` | .cj | ✅ | — |
| 20 | `f_aspect/src/test/pointcut_meta_reuse_test.cj` | .cj | ✅ | — |
| 21 | `f_aspect/src/test/qualified_func_info_key_test.cj` | .cj | ✅ | — |
| 22 | `f_aspect/src/test/recursion_guard_test.cj` | .cj | ✅ | — |

合计：`.cj` 20 个 / `.md` 2 个 / 共 22 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #1 #2 正确性、#5 语言特性（构造函数的 AST 形态）、#6 设计（重复实现）；无外部输入、无 SQL/注入面、无凭据与敏感日志，安全性 0 |
| §1 死代码 | 2 | #10（`emptyChain` 的 lambda 体不可达）、#11（`doMatches` 的无用形参）。机械核对：`private` 符号 `RecursionState` / `aspects` / `emptyChain` / `doProceed` / `recursion`（均在 `Aspects.cj` 内被引用）、`contains`（`AspectRoute.cj:230/245/288`）/ `matches(asc:…)`（`:331/344`）、`getConfig`（`ConfigAspectRouteRule.cj:30`）、`doHash` / `hash`（`QualifiedFuncInfo.cj:66/76/82`）、`doPointcut` / `pointcut(ClassDecl)` / `weave` 全部有调用者；宏包内 `unwrapParam` / `weaveOne` / `metaTokens` / `nextMetaName` / `isSimpleName` / `hasTypeParams` / `isGenericClass` 均被两个宏文件互相引用；`protected` 只有 `ConfigRouteRule.doMatches`，所属类是 `public abstract`（非 `sealed`）→ 按扩展点豁免；`public` 中 `AspectRoute.isAspect`、`ExecutionRouteRule`、15 个 `Config*RouteRule`（其中 14 个仓内零引用，`ConfigExecutionRouteRule` 有 2 处：`fdemo/boot/src/ControllerAspect.cj:24`、`f_orm/src/base/TransactionAspect.cj:26`）仓内基本无引用（`grep -rn`，排除 `.worktrees`），但都对外可达，按硬原则一不判死代码，仅记录 |
| §2 重复逻辑 | 1 | #6 合并了三簇：类级织入循环（`PointCut.cj:110-152` vs `WeavedBean.cj:43-90`）、`Config` 三处声明串解析（`ConfigAspectRouteRule.cj:44-55/105-113/136-146`）、参数「拥有注解」判定（`AspectRoute.cj:198-201/269-272/311-314`）；`TargetAnnotationRouteRule` ≡ `FuncAnnotationRouteRule` 的逐字复制计入 #2。同文件 `ArgPrefix/Suffix` 两个 `matches` 只是参数不同，属同族展开，不算重复 |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/`catch {}`；`Aspect` 的 6 个默认实现（`before`/`after`/`around`/`throwing`/`final` + `proceed`）是契约本身（README `:16-43` 逐条写明），`AspectBeforeException` 无抛出点已由 README `:122-123` 明示为「框架内部不主动抛」，不属于「承诺有行为却为空」 |
| §4 栈溢出 | 0 | 无自定义递归：`doProceed` 是固定深度的 for 循环（深度 = 切面 bean 数，受 IoC 注册量约束）；递归调用切点函数由 `recursion` 标志短路（`Aspects.cj:124-128`，第 2 部分用例钉住）；宏内的 `while (let … <- macroInputDecl)` 是编译期 AST 链，深度受源码嵌套限制 |
| §5 OOM | 0 | `aspects` 键为 `(类型, 函数)`，上界 = 被织入函数总数；`list` 上界 = `Aspect` bean 数；`ArrayList<TypeInfo>(annotations.size)` 的 size 来自规则串长度。唯一无界面是 #1 的「静态表强引用首个实例」（已按缺陷报，不重复计） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点结论不成立；`pointcut_meta_cost_test` 的计时既不 `-O2` 也无多轮统计（见 #13），不能当证据；相关猜测进「待验证假设」#1-#5 |
| §6.2 大粒度锁 | 0 | 主路径无显式锁；`ConcurrentHashMap.computeIfAbsent` 的桶锁内只做「遍历 bean + 建闭包」，不含 I/O / 日志 / 解析（`Aspects.cj:61-100`）；`BeanManager.bean` 的 `synchronized` 在 `f_bean`，不在本部分统计 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future`（仅测试里用过 `spawn` 制造交错） |
| §6.4 低效算法 | 0 | 建链期是 O(规则数 × bean 数)，每 (类型,函数) 一次；`WithinRouteRule` / `BeanNameRouteRule` 每次 `matches` 重建 `Regex`（`AspectRoute.cj:80/85/354`）只在建链期发生，收益上限低，列入待验证假设 #4 |
| §7 降堆内存方案 | 0 | 除 #1 的实例强引用（缺陷）外，本部分没有可量化的堆常驻项；链闭包数 = 切面数 × 被织入函数数，属必要结构，不构成方案 |
| §8 降 CPU 方案 | 1 | 见优化方案「实参数组与 `InvocationFuncInfo` 每次调用都构造」；`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 织入路径上的临时对象（`Array<Any>` / `InvocationFuncInfo` / 链闭包）都要**逃逸**给切面与静态缓存（`mem §7.1`），没有「函数内创建、函数内释放」的大对象；改造收益无法用峰值内存证明，不列为方案 |
| §11 现有代码的 BUG（存量） | 6 | #1（接收者错位）、#2（注解数据源错）、#3（规则串解析抛 `InfoNotFoundException`）、#4（分隔符不符）、#5（`init` 未排除）、#13（计时用例无断言）；另核对了 `String.split` 默认保留空串、`TypeInfos.get` 未命中抛 `InfoNotFoundException`、`TypeInfo.annotations` 语义、`ThreadLocal.getOrCompute` 非原子但线程封闭，四处 API 语义均以文档 + 源码为依据 |
| §12 并发安全与锁粒度 | 0 | 逐点核对：链上**不保存每调用可变状态**（实参逐调用新建 `InvocationFuncInfo`，`Aspects.cj:91-98`），`recursion` 是线程本地（`f_base/src/ExtendThreadLocal.cj:24-32` + `ThreadLocal` 文档），单例切面的并发安全由切面实现负责且 README `:54-62` 已声明。唯一跨线程共享的可变面是「链缓存 + 链尾接收者」，与 #1 同源，不重复计数；未发现新的数据竞争或死锁路径（`computeIfAbsent` 内的 `m.bean` 可能触发 bean 初始化，但递归标志已在 `:118` 置真，嵌套织入不进 map） |
| §14 功能完备性与 README 覆盖 | 2 | #9（`Config*RouteRule` 全族 + `Aspects.proceed` 未文档化、引用了不存在的 `ConfigAspectRouteRule`）、#12（`Aspect` 示例缺 `@AspectRoute`）。按 `src/` 的 public 声明逐项对照：`Aspect`/`InvocationFuncInfo`/`QualifiedFuncInfo`/`RouteRule`、`AspectRoute` + 18 个规则类、两个异常、两个宏 均有 README 条目（规则类逐个核过，含 `NotRouteRule`）；`Pointcut`/`WeavedBean` 的语义与 `src/macros/*` 一致（`@WeavedBean` = `@Bean` + 全量织入，已核对） |
| 文件覆盖（§13 等） | 20/20 | 20 行全部读完；§13 的文档问题记在 #3、#4、#7、#8、#12，`README_en.md` 与中文版同源同错，未单独重复计数 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | #2（断言覆盖不足，属正确性保障缺口）、#3（共享状态与注释不符）。两文件均为单线程测试代码、无外部输入、无 SQL/注入面、无凭据与敏感日志，安全性 0 |
| §1 死代码 | 1 | #5（两处未用 import）。机械核对：`KeyProbeBean` / `RecursionTarget` / `RecursionCountAspect` 均在用例内被构造或注册；`@Test` / `@TestCase` 成员由框架反射发现，按误报边界不判；无 `return`/`throw`/`break`/`continue` 后续语句；局部量 `t1`/`t2`/`f1`/`f2`/`k1`/`k2`/`m`/`hit`/`r`/`bean` 全部被读取；`entries` 被 `before` 写入、被断言读取 |
| §2 重复逻辑 | 0 | 两文件共 5 个 `@TestCase` 函数体两两比对：`qualified…` 的 4 条分别是「`TypeInfo` 值稳定」「成员值稳定」「键值稳定」「容器查找命中」，后两条是前两条在 `hashCode` + `==` 上的推论，属刻意分层断言（checklist §2 误报边界：测试准备/分层断言）；与 `recursion…` 的用例无同语义实现 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；每条用例至少 1 个有效 `@Assert`；`RecursionCountAspect.before` 有真实副作用（写 `entries`） |
| §4 栈溢出 | 0 | 只有 `RecursionTarget.r` 一处递归，深度由入参决定，用例固定 `n = 3`（`recursion_guard_test.cj:59`），可达深度 4；测试内无自引用结构遍历、无深拷贝 |
| §5 OOM | 0 | `entries` 只增不减，但每次运行仅 1 条 `Int64`；无用例按输入规模物化数组、无 `spawn` 全量提交 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据；`recursion_guard_test` 不测时间，`qualified…` 只做常量次数的反射调用，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 两文件无锁、无 `synchronized`；相关锁面（`BeanFactory.mutex`）不在本部分 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / `get()`（并发用例 `aspect_args_race_test.cj` 属第 1 部分） |
| §6.4 低效算法 | 0 | 无循环嵌套、无 `contains` 热路径、无重复编译正则；命名字面量无跨文件重复 |
| §7 降堆内存方案 | 0 | 仅 `entries` 与两个探针类，生命周期为整个测试进程、体量可忽略；无可量化收益 |
| §8 降 CPU 方案 | 0 | 无被测热路径（反射调用次数为个位数），优化无意义 |
| §9 local mode 可行性 | 0 | 用例内无「函数内创建、函数内释放」的大临时对象；峰值内存无可测差异 |
| §11 现有代码的 BUG（存量） | 5 | #1 头年份、#2 断言缺口、#3 静态状态与注册、#4 失效引用、#5 未用 import。另以文档核对了 5 处 API 语义（`@Assert` 两种形式、`InstanceFunctionInfo`/`TypeInfo` 的 `Equatable & Hashable`、`TypeInfo.hashCode` 实现、`getInstanceFunction` 抛 `InfoNotFoundException`、`BeanFactory.doRegister` 的两条抛异常路径），未发现断言与实现冲突，也未发现会误报的 `@Assert` 用法 |
| §12 并发安全与锁粒度 | 1 | #3：`entries` 是无同步的静态 `ArrayList`，`before` 在切面线程写、用例线程读；当前单线程不构成竞争，但注释宣称「无状态」、且无 `clear()`，属未声明的共享可变状态。`RecursionTarget` 只被本用例单线程调用，其余无共享路径 |
| §14 功能完备性与 README 覆盖 | 1 | #2：README `:98-101` 承诺的「A 调 B 不织入」无用例；README 与 `src/` 的 public 声明对照属第 1 部分（本部分不含 `.md`，也未新增 public API） |
| 文件覆盖（§13 等） | 2/2 | 2 行全部读完；§13 只涉及测试注释里的引用（#4），未发现示例代码不可用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 8 |
| 其中存量 | 18 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：`f_aspect` 是本轮少见的「设计文档写得很细、实现却在一个关键假设上走偏」的模块：README 有三节专门讲并发、建链时机、嵌套语义，`Aspects.cj` 的注释也把「链属于类型、实参逐调用传递」讲清楚了——但「链属于类型」这半句同时把**接收者**也固化成了类型级别，这在本模块自己的用例注释里被写成「设计」（`empty_chain_fastpath_test.cj:25-27`），实际是「prototype bean / 手工实例上执行错对象」的数据错误，是本模块最危险的阻塞项（另一条阻塞项是 #2 的注解数据源错位）。`bug.md §1.4`（实参互串）修掉之后，同一个静态缓存的另一半（接收者）没有再修。

- **阻塞项**：#1 与 #2。#1 只在「函数命中至少一个切面」且「同类型存在多个实例」时触发，而工程的 `fdemo` 恰好有 `@WeavedController` + `BeanScope.prototype` 的控制器，配合 `ControllerAspect`（`ConfigExecutionRouteRule`）就是一条现成的触发链；修法不复杂（缓存切面 getter 列表、`callee` 逐调用传入），但要改 `doProceed` 的缓存值类型，建议与 #5 的 `init` 过滤一起提交并补用例。#2 只改一行（`funcInfo.funcInfo.annotations` → `funcInfo.typeInfo.annotations`）+ 两个区分性用例，但它会让「类上标一次、全类方法生效」的规则静默失效，依赖它的 `@Transactional` 一类切面会以为已经织入。
- **可排期**：#3 / #4 是「按 README 写就崩 / 就不生效」的规则解析问题，修法明确（trim + 空片段当 `*` + 通配符不回落 `TypeInfos.get` + 分隔符统一），建议同一批改完并补 4 条用例；#6 的重复实现是 #5 的土壤，顺手就能收掉。
- **可延后**：#7 / #8 / #9 / #12 都是文档与契约；#10 / #11 是清理项；#13 是把「手工观测」误放进单测的形态问题，改成 bench 更有价值。
- **做对的地方**（避免误伤）：`Aspect.proceed` 默认模板的异常合并逻辑（`finally` 抛异常时把先前失败挂 `suppressed`，`Aspect.cj:74-86`）与用例 `aspect_template_suppress_test.cj` 对得上；`InvocationFuncInfo` 改成 `struct` + 每层新建，确实消掉了 `bug.md §1.4` 的实参互串；`QualifiedFuncInfo` 的 `refEq ||` 值比较与静态元信息复用（`PointCut.cj:203-222`）也是正确的优化方向。剩下的问题集中在「类型级缓存」的边界与「规则串」的健壮性，不是架构层面的错。

**第 2 部分**：本部分两个文件是「把结论钉死在用例里」的类型：`qualified_func_info_key_test.cj` 用来排除 ASP-L8（链缓存键不稳定 ⇒ 缓存永不命中、静态表无界增长）这条概率性假设，`recursion_guard_test.cj` 用来守住 ASP-L4（按线程状态对象替代 `ThreadLocal<Bool>`）的语义。两份用例的前提都核对得住——`TypeInfo` / `InstanceFunctionInfo` 确实实现了 `Equatable & Hashable`、`TypeInfo.hashCode` 是限定名哈希、`@Assert` 的相等/布尔两种形式用法正确，`@WeavedBean` + 手工 `register` 的组合也是必要条件（`@AspectRoute` 不含 `@Bean`）。**没有缺陷级问题**，这一部分不需要阻塞。

真正值得注意的是覆盖形状：

- `recursion_guard_test` 只钉住了「进入一次」，没钉「结束后恢复」，也没钉 README 明写的「A 调 B 不织入」。前者是「切面永久失效」的静默故障，后者是「切面重复执行」的静默故障，两者都不会被现有断言发现，而它们恰好是这条守卫存在的理由（第 1 部分 #8 已指出 README 对实现的描述过期，注释又把读者指向那段过期描述）。
- 用例的可重复性依赖两个进程级前提（`BeanFactory` 未启动、`entries` 未被污染），而 `entries` 的注释还宣称「无状态」。这在本仓库大量复用全局 `BeanFactory` 的测试风格下迟早会咬人。
- 第 1 部分报的两条严重问题（链尾固化首个接收者、`TargetAnnotationRouteRule` 读错数据源）在本部分两个用例里也覆盖不到：`recursion_guard_test` 只用一个实例、`qualified…` 只碰键。模块级用例缺口已在第 1 部分的文件覆盖表里记录，这里不重复计数。

**范围外提示**：两个用例都依赖 `std.reflect`，而官方文档对 `TypeInfo` / `InstanceFunctionInfo` / `getInstanceFunction` 均标注「不支持平台：macOS、iOS」（`reflect_package_classes.md:12999` 等），`f_aspect/cjpm.toml` 却声明了 `x86_64-apple-darwin` / `aarch64-apple-darwin` 两个 target —— 这是模块级平台约束，`cjpm.toml` 不在本部分文件清单内，只记一句，不计入统计。
