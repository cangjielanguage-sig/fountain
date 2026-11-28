# f_aspect 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_aspect`（20 个源文件：`src/` 10 个 + `src/test/` 10 个）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，未对照远端目标分支；被审源码无改动）
- **审查重点**：AOP 路由 / 织入正确性、递归保护、并发安全、宏展开、测试覆盖反向验证（空断言 / 漏断言 / 竞态测试有效性）、死代码、重复逻辑、空实现、OOM、文档一致性、存量 BUG
- **报告版本**：v1（由 `reviews/202611280829_full/parts/f_aspect.part1.md`（15 个文件）与 `f_aspect.part2.md`（5 个测试文件）合并；同一根因跨部分重复的已合并，严重程度取更严格者并注明）

> 合并口径：part1 的 `#N` 与 part2 的 `P2-N` 统一重排为本报告的 `#N`。跨部分同根因 3 组已合并：`part1 #4 + P2-6`（非空链固化接收者 + `new` 与 IoC 契约冲突）、`part1 #14 + P2-2`（测试全局状态不隔离 + 数据竞争）、`part1 #15 + P2-7`（未使用 import）。part1 的「优化可行性方案 [CPU]」与 P2-1 同源，已在合并后降级该方案引用的数据。
> 证据等级变更：part1「优化可行性方案」引用的 1867–2443 ns/次来自 `pointcut_meta_cost_test` 的 `-O0` 单轮 `println`（见 #12），合并后统一标注为「不可引用为基线」。

## 发现

### 1. [严重][存量] `TargetAnnotationRouteRule` 匹配的是"函数注解"而不是"目标类型注解"，与自身契约相反且与 `FuncAnnotationRouteRule` 完全重复

- **位置**：`src/AspectRoute.cj:228-231`（类注释 `223-227`；README 契约 `README.md:324-338`）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）、§13（文档与实现相反）、§2（重复逻辑）
- **证据**：静态确定 ——
  1. 类注释与 README 都写"如果**目标类型**有指定类型的注解则目标类型的全部公共实例函数将被织入"；
  2. 实现 `contains(funcInfo.funcInfo.annotations, ...)` 取的是 `InstanceFunctionInfo`（函数）的注解，`funcInfo.funcInfo` 即 `_funcInfo.funcInfo`（`src/QualifiedFuncInfo.cj:48-52`）；
  3. 同文件其余"作用于类型"的规则都用 `funcInfo.typeInfo`（`AspectRoute.cj:85`、`182`），`Aspects.cj:65` 也证明类型级注解可通过 `beanType.findAnnotation<AspectRoute>()` 取得；
  4. 该方法体与 `FuncAnnotationRouteRule.matches`（`243-246`）逐行相同——两处唯一差异是类名，属于复制后未改语义。
- **描述**：`TargetAnnotationRouteRule("a.B")` 实际只匹配"函数上带 `a.B`"的函数，类型上带 `a.B` 而函数不带时**不匹配**；反之函数带注解而类型不带时会误匹配。路由规则决定切面是否织入（`f_orm/src/base/TransactionAspect.cj:26` 即用 `FuncAnnotationRouteRule` 做事务织入），误判会静默漏织入或误织入。全仓检索 `TargetAnnotationRouteRule`：除本文件定义、README 契约片段与 `ConfigTargetAnnotationRouteRule` 包装（`ConfigAspectRouteRule.cj:169/171`）外无任何使用，模块测试目录也无用例，因此该缺陷一直未被发现。
- **建议**：改为读取目标类型注解（`funcInfo.typeInfo` 的注解集合，或现成的 `findAnnotation` 系列 API）；若类型级注解集合的获取方式与 `Collection<Annotation>` 不同，则给 `contains` 增加一个按 `TypeInfo` 取注解的重载。同时补一条用例：类型带注解、函数不带 → 必须匹配。

### 2. [严重][存量] `ArgsRouteRule` 的 `**` 尾随通配符：文档承诺的写法要么抛 `InfoNotFoundException`，要么误判 `false`

- **位置**：`src/AspectRoute.cj:109-127`（关键：`111-122` 的 `check`、`106-108` 的长度校验）；文档承诺 `AspectRoute.cj:29`、`92` 与 `README.md:251-252`
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§13（文档承诺的写法不可用）
- **证据**：静态确定 ——
  1. 文档写明"`**` 表示任意数量任意类型的参数，可以 `**` 在本规则结尾"；
  2. `check(i)` 只有在 `i >= types.size` 时才把 `types[last] == '**'` 当作通配（`120-122`）；当 `i < types.size` 时 `t == "**"` 既不等于 `'*'`、也不以 `<:` 开头/结尾，直接落到 `TypeInfos.get("**")`（`118`）；
  3. `TypeInfos.get` 未注册类型抛 `InfoNotFoundException`（`f_base/src/TypeInfos.cj:45-47`）；
  4. 以 `"java.lang.String,**"` 匹配 2 参函数为例：`params.size(2) == types.size(2)` → `i=1` 走 `TypeInfos.get("**")` → 抛异常；匹配 1 参函数时 `params.size(1) < types.size(2)` 在 `106` 直接 `return false`，而按文档 `**` 可匹配 0 个参数，应为 `true`。即除规则恰为 `"**"`（`101-103` 特判）外，`**` 结尾形态不可用。
- **描述**：异常从 `Aspects.doProceed` 的建链闭包里冒泡到业务调用方；由于异常发生在 `computeIfAbsent` 的映射函数内，链不会写入缓存，因此该切点函数**每次调用都会重复抛异常**（不是只在首次）。`ConfigExecutionRouteRule`（`f_orm` 事务切面的生产入口）会把用户配置直接送进 `ArgsRouteRule`。空段同理：文档示例 `,*`（忽略最后一个参数）会被 `split(',')` 拆出空串，`TypeInfos.get("")` 同样抛异常。
- **建议**：在 `check` 里先判 `t == "**"`（仅允许出现在末项）→ 视为匹配成功；长度校验改为"末项为 `**` 时 `params.size >= types.size - 1`，否则必须相等"；对空段/未知类型返回 `false`（或抛带规则串的 `AspectException`），不要让裸 `InfoNotFoundException` 穿透。补 `"T,**"`（1/2/3 参）、`,*` 两类用例。

### 3. [严重][存量] `ReturnTypeRouteRule` 通配符不命中时把模式串当类型名查表，抛 `InfoNotFoundException`

- **位置**：`src/AspectRoute.cj:136-141`（关键 `137-139`）
- **来源**：存量（`git blame` 2026-10-04 `3570d18100`，`136/140/141` 为 `4be871f2fd`）
- **判据**：review-checklist §11（错误处理缺失：正常"不匹配"被当成异常）、§13（`RouteRule` 基类文档 `141` 承诺 returnType 支持 `*` 通配符）
- **证据**：静态确定 —— 表达式为 `A || (B && C) || D`：
  - `A = returnType == '*'`；
  - `B = returnType.contains('*') || returnType.contains('?')`；
  - `C = Regex.wildcard(returnType).matches(...)`；
  - `D = TypeInfos.get(returnType).isSubtypeOf(...)`。
  当规则含 `*`/`?` 但 `C` 为 `false`（这是**正常的"不匹配"**）时，`||` 继续求值 `D`，`TypeInfos.get("x.*")` 未注册类型 → `InfoNotFoundException`（`f_base/src/TypeInfos.cj:45-47`）。`TargetRouteRule`（`182`）与 `ArgsRouteRule`（`114/116/118`）对非法/未知类型同样无兜底，属同一类问题。
- **描述**：任何"含通配符的返回类型规则"只要遇到一个不匹配的函数就抛异常，而 `Aspects.doProceed` 的建链闭包不捕获它 → 该函数首调用直接失败。`ConfigExecutionRouteRule` 解析出的 returnType 会原样进入本规则，因此配置式切点（`orm_transactionalFuncExecution`）也受影响。模块测试目录无 `ReturnTypeRouteRule` 用例。
- **建议**：先判 `B`：含通配符时只返回 `C` 的结果，不再落到 `D`；无通配符时再做类型查表，并对 `TypeInfos.get` 的失败给出带规则串的 `AspectException` 或返回 `false`。

### 4. [严重][存量] 非空切面链固化首次调用的 `callee`（含接收者）：多实例场景执行错误实例的方法体；该限制未文档化且与测试写法冲突

- **位置**：`src/Aspects.cj:74`（`var f: (Array<Any>) -> Any = {args => fn(args)}`，配合 `91-96`、`101-109`）；`src/macros/PointCut.cj:99-104`（生成 `func callee(...)` 捕获 `this`）；契约 `src/Aspects.cj:48`、`README.md:61`；测试手工 `new` 处 `src/test/empty_chain_fastpath_test.cj:42`、`44`、`src/test/pointcut_meta_cost_test.cj:50`、`src/test/pointcut_meta_reuse_test.cj:54`、`src/test/recursion_guard_test.cj:58`
- **来源**：存量（`git blame` 2026-10-05 `2c285e93b7`，ASP-L7 空链修复同批；`fn` 捕获本身属 ASP-1 判定的设计）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）、§12.1（跨实例共享可变状态语义）、§13（注释与 README 声明支持 prototype）、§14.1（限制未文档化）
- **证据**：静态确定 ——
  1. 链缓存的键是 `QualifiedFuncInfo`（类型 + 函数），与实例无关（`Aspects.cj:60-61`）；
  2. 有切面命中时链尾 `{args => fn(args)}` 直接捕获**首次调用**传入的 `fn`，而宏生成的 `fn` 是方法体内的嵌套函数 `callee`，隐式捕获该次调用的 `this`（`PointCut.cj:99-104` 把原函数体整体搬进 `callee`，函数体里的字段/方法访问都落到该 `this`）；
  3. 空链路径已在 ASP-L7 改为"在本次调用的接收者上执行"（`Aspects.cj:101-103`；存量记录见 `.autocode/bugs/bug-aspect-archived-20261006.md:190`：`empty_chain_fastpath_test.cj` 修前 `b.who()` 读到 1，修后读到 2）；**非空链一字未改**，因此同样的两实例场景只要有一个切面命中，`b.m()` 仍执行 `a` 的函数体；
  4. `Aspects.cj:48` 注释明写"被织入的对象必须是 IoC 管理的 bean（**singleton 或 prototype 均可**）"，README 亦写"同一类型的多个实例共享同一条切面链"（`README.md:61`）——即已承认链共享，但未说明接收者也被固化；
  5. 与契约相反的是，5 个测试文件中 4 个直接 `new` `@WeavedBean` 目标（上列 4 处），而 `Aspects.cj:48` 又声明"手工 new 出来的实例不在支持范围内"；README 全文检索"手工 / 手动 / 支持范围"零命中（唯一的"不支持"在 `README.md:142`，讲的是反射不支持的类型）。空链修复恰恰让手工实例的多实例语义变正确，说明该限制实际只对"非空链固化首实例"成立。
- **描述**：prototype 目标（或多例 singleton）调用被织入方法时，**方法体在首个实例上执行**：字段读写落到错误对象、`this` 相关逻辑（事务/日志/审计切面里传递的业务对象）全部错位，且不报错。`@WeavedBean` 默认 singleton 掩蔽了该问题，prototype bean 才会暴露。ASP-1 的"设计"判定理由是"匹配结果只取决于签名、与实例无关"——该理由不覆盖"链尾捕获的是接收者绑定的 callee"，因此本条不是对同一判定的重复。同时"支持范围"只存在于代码注释、未进 README，使用方无法得知手工实例与非空链的组合行为未定义。
- **建议**（按代价从低到高）：①链只缓存 `ArrayList<BeanManager>`（切面列表），每次调用现场按本次 `fn` 组装（每调用 1 个闭包/层，可接受）；②缓存"链构造器"并在调用时传入 `fn`；③若坚持固化，则在 `Aspects.proceed` 入口按目标实例判等（`refEq`）拒绝非首次实例，并在 README 明确"prototype 目标不支持织入"。无论哪种，都应补一条"有切面命中 + 两实例各调一次"的用例（现有 `empty_chain_fastpath_test` 只覆盖空链）。文档侧把 `Aspects.cj:48` 收窄为"非空链的链尾固化首次调用的接收者，因此手工 new 的多实例行为未定义；空链路径按本次接收者执行"，并补进 README「并发与线程安全 / 多实例」小节。
- **严重程度合并**：本条第 5 点并入原 part2 `P2-6`（原判轻微、待确认）。取更严格的**严重**，理由：`P2-6` 只描述文档口径冲突，而其所指的行为就是本条第 1–3 点的"执行错实例"，文档缺口随行为修复一并解决，不能按轻微单列。

### 5. [一般][存量] `AnyArgAnnotationsRouteRule` 用 `|` 分割，注释与 README 都写 `,`

- **位置**：`src/AspectRoute.cj:281`（注释）与 `287`（`annotationTypes.split('|')`）；契约 `README.md:374`
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §13（文档与实现不一致）、§11（契约与实现不符）
- **证据**：静态确定 —— 注释"多个注解用,分割"、README 同文；代码按 `|` 拆分，且 `contains` 要求**全部**名称命中（AND）。按文档写 `a.X,b.Y` 会被当成一个名字 `"a.X,b.Y"`，与任何注解全限定名都不相等 → 静默 `false`（不报错、不织入）。`ConfigAnyArgAnnotationsRouteRule`（`ConfigAspectRouteRule.cj:203-212`）直接把配置串传入，同样中招。
- **建议**：二选一并统一：把 `split('|')` 改成 `split(',')`（与文档、与 `ArgsRouteRule` 的 `,` 一致），或改文档为 `|`（但要说明与同族规则分隔符不同）。补一条 `"a.X,b.Y"` 的用例。

### 6. [一般][存量] `ConfigFuncTypeRouteRule` / `ConfigFuncRouteRule` 解析后不 trim，与 `ConfigExecutionRouteRule` 不一致

- **位置**：`src/ConfigAspectRouteRule.cj:104-114`（`112-113` 取 `returnType`/`argTypes`）与 `134-146`（`143-145`，`funcName` 在 `145`）；对照 `42-56`（`ConfigExecutionRouteRule` 的 `52-54` 全部 `trimAscii`）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（边界 / 同族实现行为漂移）、§2（近似重复但少了边界处理）
- **证据**：静态确定 —— `ConfigExecutionRouteRule` 对 `returnType`、`argTypes`、`funcName` 都做了 `trimAscii`（`52-54`）；`ConfigFuncTypeRouteRule` 直接 `funcType[colon + 1..]` / `[lparen + 1..rparen]`（`112-113`），`ConfigFuncRouteRule` 直接 `funcDecl[0..lparen]`（`145`），均不 trim。`getConfig`（`26-28`）只 trim 整串首尾，内部空格保留。
- **描述**：配置 `"pkg.Cls.f(a: String) : Int64"` → `returnType = " Int64"` → 不含通配符 → `TypeInfos.get(" Int64")` 抛 `InfoNotFoundException`（`f_base/src/TypeInfos.cj:45-47`），该函数每次调用都失败；配置 `"pkg.Cls.f (a: Int64): Int64"` → `funcName = "f "` → `Regex.wildcard("f ")` 永不命中，静默 `false`。同一族配置规则对空格容忍度不同，且模块测试目录无任何 `Config*` 用例。
- **建议**：三个配置类统一走一个 `parseFuncDecl`（见 #15）并在其中统一 `trimAscii`；解析失败抛带原串的 `AspectException` 而不是裸 `InfoNotFoundException`；补"签名里带空格"的用例。

### 7. [一般][存量] `Pointcut` 宏生成的 `info` / `args` 标识符与用户形参冲突，合法函数直接编译失败

- **位置**：`src/macros/PointCut.cj:67-69`（`let $paramName = (args[$(i)] as ...)`）、`97-105`（`func callee(args: Array<Any>)` + `let info = ...`）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`；`info` 行 `ad8cc477c9` 2026-10-05）
- **判据**：review-checklist §11（宏生成代码与用户代码命名冲突）、§10（可维护性）
- **证据**：静态确定（按生成代码逐行推演）——
  1. 形参名为 `info`：外层函数体已是 `let info = $infoExpr`（`103`）与形参 `info` 同作用域 → 重复定义，编译失败；
  2. 形参名为 `args` 且函数有 ≥2 个参数：`callee` 体里第一行 `let args = (args[0] as T).getOrThrow()`（`68`）遮蔽了 `callee` 的 `Array<Any>` 形参，下一行 `args[1]` 变成对元素取下标 → 类型错误。
- **描述**：被 `@Pointcut` / `@WeavedBean` 修饰的类里，只要有一个公共方法用了 `info` 或（多参数时）`args` 作参数名就编译不过；多参数函数用 `args` 作参数名是常见写法（转发/日志）。宏没有任何转义或唯一化处理。
- **建议**：生成名加不可能冲突的前缀（如 `__pc_args`、`__pc_info`），或在宏里先用 `HashSet` 收集形参名并对生成名做去重（`nextMetaName` 已有类似机制，可复用）。

### 8. [一般][存量] `Pointcut` 宏按第一个 `{` 截断签名：默认参数里出现 lambda 字面量时生成非法代码

- **位置**：`src/macros/PointCut.cj:54-59`
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（宏健壮性 / 边界）、§14.1（半成品：只处理部分输入）
- **证据**：静态确定 —— 循环 `for (t in tokens) { if (t.kind == TokenKind.LCURL) break; funcDecl += t }` 以"第一个左花括号"定位函数体的开始。函数**签名**里也可以出现 `{`：`public func f(cb: () -> Unit = {=> })`、`= { _ => () }`。此时 `funcDecl` 在默认值中间被截断，随后 `quote($funcDecl { ... })` 产出非法声明。
- **建议**：按 AST 结构取签名（`decl.identifier` + `decl.funcParams` + `decl.declType` 重新拼 `quote`），不要用"扫描 token 找 `{`"的方式；或至少用括号/尖括号深度 + `=` 之后的 lambda 检测来跳过默认值。补一条带默认 lambda 参数的方法用例。

### 9. [一般][待确认] `@WeavedBean` 与 `@Pointcut` 同时覆盖同一方法时没有去重守卫，可能二次织入

- **位置**：`src/macros/WeavedBean.cj:66-83`（`MacroExpandDecl` 分支无条件 `weaveOne` 后返回 `me`）；对照 `PointCut.cj:25-27` 的 `insideParentContext('Pointcut')` 守卫
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（重复织入 = 切面执行两次）、§14.1（接线缺失）
- **证据**：待确认 —— 代码事实：`Pointcut` 用 `insideParentContext('Pointcut')` 防"类级 @Pointcut + 方法级 @Pointcut"重复；`WeavedBean.weave` 对 `MacroExpandDecl` 分支**只**检查 `isPublic/isStatic`，没有"该方法已被 @Pointcut 处理"的判据，处理完仍返回原始 `me` 交给内层宏继续展开。缺的信息：仓颉宏展开顺序下，`@Pointcut` 是否会先展开成 `FuncDecl`（若先展开，`WeavedBean` 看到的就是已含 `Aspects.proceed` 的函数体，二次包裹后 `before` 会进两次）。
- **建议**：构造一个"类上 `@WeavedBean` + 方法上 `@Pointcut`"的用例，断言切面 `before` 只进一次；若确实二次织入，在 `WeavedBean` 里复用 `insideParentContext('Pointcut')` 或给生成的 `callee` 打标记跳过。

### 10. [一般][存量] README 的递归保护实现描述已过期（`ThreadLocal<Bool>` / `remove()` vs `RecursionState`）

- **位置**：`README.md:100`（`README_en.md:106` 同）对 `src/Aspects.cj:32-34`、`112-122`
- **来源**：存量（`git blame`：README 该段 2026-10-05 `c8c6c532de` 写入，代码 `Aspects.cj:32-34` 为 2026-10-05 `ba4288006d`；两者同日但内容不一致）
- **判据**：review-checklist §13（文档过期：描述的功能已改名 / 实现已替换）
- **证据**：静态确定 —— README 写"实现位于 `recursiveInvocationFlag`（`private static let ... = ThreadLocal<Bool>`）… `finally { remove() }`"；代码里 `recursiveInvocationFlag` 与 `ThreadLocal<Bool>` 均已不存在，实际是 `private class RecursionState { var state = false }` + `ThreadLocal<RecursionState>` + `getOrCompute`，`finally` 里是 `st.state = false`。
- **建议**：把 README/README_en 该段改为 `recursion`（`ThreadLocal<RecursionState>`）与 `state` 字段，删掉 `remove()` 表述。

### 11. [一般][存量] `Config*RouteRule` 全家（基类 + 15 个子类）与 `matchIfNone` 在 README 中无任何小节

- **位置**：`src/ConfigAspectRouteRule.cj:21-36`（基类 + `matchIfNone`）与 `37-245`（15 个子类）；README 仅 `README.md:111`、`120` 提到 `Config*RouteRule` 的名字
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 关键配置无文档 → 一般）
- **证据**：静态确定 —— 全仓检索 README：`ConfigExecutionRouteRule`、`ConfigWithinRouteRule`、`ConfigBeanNameRouteRule` 等类名与参数名 `matchIfNone` 均**零命中**（只有第 111 行的 `ConfigAspectRouteRule` 作为示例名出现）。基类 + 15 个子类都是对外可达的 public API（`ConfigRouteRule` 为 `public abstract`），且只有一个生产消费者（`f_orm/.../TransactionAspect.cj:26` 用 `ConfigExecutionRouteRule`）。
- **描述**：使用者拿不到这些类的信息：配置键怎么给、`config` 字符串格式（`ExecutionRouteRule` 的 `qualifiedName.funcName(argTypes):returnType`，`|` 分隔多条）、`matchIfNone=false` 表示"配置缺失即不匹配"、解析失败抛 `AspectException`。README 只在 §异常 提了一句"配置字符串不合法抛 `AspectException`"。按文档无法使用配置式切点。
- **建议**：新增"配置式路由规则"小节：基类签名 + `matchIfNone` 语义 + 各子类的配置格式表（至少 `ConfigExecutionRouteRule` / `ConfigFuncTypeRouteRule` / `ConfigArgAnnotationsRouteRule` 三类给格式说明与示例）。

### 12. [一般][存量] `pointcut_meta_cost_test` 是「永远绿」的伪基准：唯一断言与所测行为无关，且时钟、优化级别、对照组三处都不满足性能取证要求

- **位置**：`src/test/pointcut_meta_cost_test.cj:48-70`（关键 `55-59` / `61-65` / `67-68` / `69`）；构建配置 `f_aspect/cjpm.toml:11-12`、`29-30`
- **来源**：存量（`git blame` 2026-10-05 `ad8cc477c`「perf(f_aspect): ASP-3 类级织入改用静态元信息」）
- **判据**：review-checklist §11（测试有效性）、§6.1（热点/开销结论的证据要求：函数级定位 + 输入规模 + 对照 + 排除法）；`fountain-baseline.md` §8（基准必须 `-O2`，要绝对值 / 中位数 / 离散程度）；§13（注释与实现不符）
- **证据**：静态确定 ——
  1. 全用例只有一条真实断言 `@Assert(bean.c(7), 7)`（`69`），与耗时无关；`woven` / `plain` 只被 `println` 打印（`67-68`），没有断言、没有阈值、没有失败路径；无论织入开销是 2 ns 还是 2 µs，用例都通过。
  2. 计时用 `DateTime.now()`（`55`、`61`），是墙钟：std 文档明确 `MonoTime` 是单调时间且「常用于性能测试」（`std/time/time_package_api/time_package_structs.md:3101`），`DateTime` 会受系统校时/时区调整影响，且 `toNanoseconds()` 的分辨率不保证。
  3. `cjpm.toml:11-12` 的 `compile-option` 只有 `--dy-std`，`[profile.build]` 只有 `incremental`（`29-30`），测试默认 `-O0` 运行；基准文档要求 `-O2` 前后对照。
  4. 对照组不同构：`bean.c(i)` 是实例方法且经 `Aspects.proceed`（`ThreadLocal.getOrCompute` + `ConcurrentHashMap` 命中 + 空链分支，`Aspects.cj:114-128`、`101-103`），`MetaCostTarget.cStatic(i)` 是静态直调；差值里混着分派方式与三次容器/线程本地访问，无法归因到某一项。
  5. 只跑一轮（无重复、无中位数、无 P95），1e6 次的中途 GC 与预热（仅各 1 次冷调用，`52-53`）都未处理。
  6. 注释声称该用例把「`getInstanceFunction` 与分配成本」量化（`39-44`），但 ASP-3 之后类级织入已在编译期生成 `private static let __pOIntcUt_*`（`PointCut.cj:93-96`、`203-222`），每次调用**不再**经过 `getInstanceFunction`、也不再构造 `QualifiedFuncInfo`；这条测量在生产代码里已无对应路径，注释停留在改造前。
- **描述**：这是本模块唯一自称量化 ASP-3 收益的用例，但产出的是与构建配置、机器、GC 时序强耦合的裸数字，且永远不会失败。它产出的 1867–2443 ns/次（`-O0` 单轮打印）已被历史性能结论引用，会把解释执行开销当成 AOP 织入开销；本报告「优化可行性方案 [CPU]」引用的同一数据也据此降级为不可引用。
- **建议**：①改用 `MonoTime.now()`；②固定 `-O2` 的独立 bench 入口（`@Bench`/`@Measure` 或单独 `cjpm bench` 目标），或至少在注释里写明「本用例数值不可用于结论」；③对照组换成「同一实例方法但不织入」（同类型加一个 `@Pointcut` 排除/静态元信息关闭的同体方法），消除分派方式差异；④≥5 轮取中位数 + P95，先 `cjprof record/report` 再谈占比；⑤删除或改写 `39-44` 的注释，使其与实际测量对象（空链入口固定开销）一致。

### 13. [一般][存量] 测试向全局 `BeanFactory` 注册后不注销、静态容器不清空、并把无同步的 `ArrayList` 用在并发路径上：断言会漂移到别的函数，且存在未承认的数据竞争

- **位置**：注册不注销 —— `src/test/aspect_args_race_test.cj:75`、`src/test/aspect_chain_capture_test.cj:83`、`113`、`src/test/aspect_template_suppress_test.cj:78`、`97`；静态容器 —— `src/test/pointcut_meta_reuse_test.cj:37`（`public static let metas = ArrayList<QualifiedFuncInfo>()`）、`40`（`metas.add`）、`53`（`register`）、`59-60`（断言）；并发面 —— `aspect_args_race_test.cj:38`（同样匹配函数名 `m`）、`81-93`（两线程并发 `Aspects.proceed`）；缓存不可清理 —— `src/Aspects.cj:51`
- **来源**：存量（`git blame` 2026-10-05 `ad8cc477c`；注册与缓存部分为快照现状，ASP-8 已判定"缓存不失效"为设计）
- **判据**：review-checklist §1（注册了不注销）、§11（测试隔离 / 断言与目标不符）、§12.1（共享可变状态无保护）
- **证据**：静态确定（结构）+ 需实测（是否真的重叠）——
  1. 五处 `BeanFactory.instance.register<X>(...)` 均无对应注销（`f_bean` 侧也未提供测试用清理入口，检索 `unregister`/`func remove` 均零命中）；`Aspects.aspects` 一旦为某 `(类型, 函数)` 建链就永久复用。
  2. `metas` 是 `public static let`，用例内不清空、`tearDown` 不清理；`MetaIdentityAspect` 的规则是 `FuncNameRouteRule("m")`，`ArgsRaceAspect` 也是 `m`，同进程内 `RaceTarget.m` 的调用同样进入 `MetaIdentityAspect.before` 并写入 `metas`，且写入的 `qualifiedFuncInfo` 是**链缓存里同一个对象**（`Aspects.cj:60-61`、`95`），因此 `refEq(metas[0], metas[1])` 即使取自 `RaceTarget.m` 也成立。
  3. 于是若 `aspect_args_race_test` 先执行，本用例的 `metas[0]/metas[1]` 是 `RaceTarget.m` 的元数据，断言仍绿，却没有验证 `MetaReuseTarget.m` 的静态元复用；`size >= 2`（`59`）还允许一条调用写两次（重复织入）通过。
  4. 并发面：若两个切面同时在 `m` 的链上（层序由 `BeanFactory` 迭代顺序决定），`ArgsRaceAspect.before` 会在 T1 上阻塞至多 5 s（`aspect_args_race_test.cj:50-53`），T2 在另一线程继续；`metas` 是 `ArrayList`，`add` 无同步 —— 只有 `MetaIdentityAspect` 位于外层时两个 `add` 才可能重叠（`Aspects.cj:63-96`），故重叠概率标 `需实测`。
- **描述**：不影响产品代码，但用例对执行顺序敏感，且断言可能通过在与它声称验证的行为无关的理由上；同时测试进程内存在一个未被承认的数据竞争（最坏后果是 `ArrayList` 内部数组损坏、条目丢失、偶发失败，且失败点与真实原因相距很远）。此外同进程内先跑过某个 `(类型, 函数)` 后再注册匹配切面不会生效。
- **建议**：①每个用例 `beforeEach`/`tearDown` 清空静态容器，或改用局部收集器（切面实例持有）；②断言收紧为 `metas.size == 2` + `metas[i].typeInfo == TypeInfo.of<MetaReuseTarget>()` + `metas[i].funcInfo.name == 'm'`；③测试用切面里不要用裸 `ArrayList` 收集跨线程数据，改用 `AtomicInt64` 计数或加锁；④给 `Aspects` 加 `internal static func resetCacheForTest()`（或 `@TestOnly` 等价物）供 `tearDown` 调用，并在用例注释写明"必须先注册再首调用"的约束。
- **严重程度合并**：本条第 1 点并入原 part1 `#14`（原判轻微），第 2–4 点来自原 part2 `P2-2`（原判一般）。取更严格的**一般**，理由：`P2-2` 证明同一根因已产生两个超出"测试卫生"的后果——断言对象漂移（测试失去验证能力）与 `ArrayList` 并发写（数据竞争），不是可读性/维护性问题。

### 14. [一般][存量] `recursion_guard_test` 只覆盖「单线程、只调一次最外层」：守卫不复位、退化为全局标志、切面重入这三种失效都能通过

- **位置**：`src/test/recursion_guard_test.cj:56-63`（断言 `61-62`）；被测逻辑 `src/Aspects.cj:112-129`
- **来源**：存量（`git blame` 2026-10-05 `ba4288006`「perf(f_aspect): ASP-L4 织入状态改按线程对象」+「ASP-L5 默认模板不丢异常」）
- **判据**：review-checklist §11（漏断言）、§12.1（线程封闭只被声明、未被用例验证）
- **证据**：静态确定 ——
  1. 用例只有一次顶层调用 `bean.r(3)`（`59`），断言 `entries.size == 1`、`entries[0] == 3`（`61-62`）。若把 `finally { st.state = false }`（`Aspects.cj:120-122`）删掉，`state` 永久为 `true`：第二次顶层调用仍不织入，本用例照样通过 —— 而这正是"守卫卡死、之后所有调用都跳过切面"的严重退化。
  2. 若把 `ThreadLocal<RecursionState>`（`Aspects.cj:112`）换成 `private static var state = false`：单线程下行为完全相同，本用例仍通过；多线程下会互相屏蔽切面。用例没有任何并发断言，这个改动无法被发现。
  3. 守卫的真实防护目标是「切面里再调用被织入函数 / 递归调用」导致的无限递归（`README.md:96-99` 的设计说明），但用例只覆盖自递归 `n + r(n-1)`，未覆盖「切面 `around` 里回调同一 bean」这一无限递归入口；`r(3)` 的深度是 4，也不构成对深递归的验证。
- **描述**：`RecursionState` 是「正确性 + 线程安全」双重关键点（§12 的线程封闭结论依赖它成立），但唯一用例对「复位」「线程隔离」「重入」三个失效模式全部不敏感，属于典型的「正向路径通过、反向语义未验证」。
- **建议**：①连续两次顶层调用（`bean.r(1)` 再 `bean.r(1)`），断言 `entries.size == 2`，锁死 `finally` 复位；②`spawn` 两个线程各调一次，断言每个线程各进入一次切面（`entries` 总数 2），锁死线程封闭；③新增一个 `around` 内回调目标 bean 的切面，断言不无限递归且内层不织入；④`entries` 每次用例前清空，避免与其它用例的顺序耦合。

### 15. [轻微][存量] 重复逻辑：注解判定与配置签名解析各有两份同语义实现

- **位置**：
  1. `src/AspectRoute.cj:228-231` ≡ `243-246`（`TargetAnnotationRouteRule` / `FuncAnnotationRouteRule`，逐行相同，差异只有类名）；
  2. `src/ConfigAspectRouteRule.cj:104-114` ≡ `135-146`（`ConfigFuncTypeRouteRule` / `ConfigFuncRouteRule` 的 `colon/rparen/lparen/returnType/argTypes` 解析完全相同，后者只多取 `funcName`）；
  3. `src/AspectRoute.cj:269-272` ≈ `311-314` ≈ `196-205`（"某参数是否拥有某注解"的三份循环，前两处为精确全限定名比较，第三处按 `sub` 走子类型比较）。
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §2（跨方法/跨文件复制；差异点只有"取哪个对象/是否比较子类型"）
- **证据**：静态确定（函数体逐行对齐；差异已在上方列出：错误文案、`funcName` 提取、`sub` 分支）
- **描述**：第 1 处已导致实际缺陷（见 #1）；第 2 处意味着修 `ConfigFuncTypeRouteRule` 的 trim 时容易漏改另一处（本次即两处都缺少 trim，见 #6）；第 3 处三份实现的"拥有"语义若有一处改动就会漂移。
- **建议**：第 1 处按 #1 修复后自然合并；第 2 处抽 `private func parseFuncDecl(s: String): (String, String, String)`（返回 `(qualifiedName/name, argTypes, returnType)`）供两个配置类共用；第 3 处抽 `private func paramHasAnnotation(param, name: String, sub: Bool): Bool`。

### 16. [轻微][存量] `ConfigRouteRule.doMatches` 的 `funcInfo` 形参从未使用

- **位置**：`src/ConfigAspectRouteRule.cj:29`（15 个调用点全部传了 `funcInfo`，如 `42`、`71`、`82`…）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §1（读了不用 / 无用形参）
- **证据**：静态确定 —— 函数体 `29-35` 只读 `getConfig(config)`、`matchFn`、`matchIfNone`，`funcInfo` 无任何出现；15 个子类的 `matches` 仍逐个传参。
- **建议**：删掉该形参与调用点实参（`protected`，仅本模块子类使用）；若为后续"按函数缓存解析结果"预留，则加注释说明并给出使用它的 TODO 计划。

### 17. [轻微][存量] `qualified_func_info_key_test` 全为正例，缺「不同键必须不相等 / 不命中」的负例；`HashMap` 用例只断言 `isSome`

- **位置**：`src/test/qualified_func_info_key_test.cj:41-75`（关键 `59-65`、`68-75`）
- **来源**：存量（`git blame` 2026-10-05 `d69d2ce83`「test(f_aspect): ASP-L8 前提不成立（键按值稳定）」）
- **判据**：review-checklist §11（断言不完整：只有 `==`，没有 `!=`）
- **证据**：静态确定 —— 4 个用例全部断言「相等」（`t1 == t2`、`f1 == f2`、`k1 == k2`、`hash` 相等、`m.get(...).isSome()`）。若 `QualifiedFuncInfo.==` 恒返回 `true`（`src/QualifiedFuncInfo.cj:78-80` 的 `refEq || 结构比较` 退化为无条件 `true`），或 `hashCode()` 返回常量（`66` 的 `hash` 计算失效），本文件全部通过；而 `==` 过度宽松会让所有切点函数塌缩到同一条链（不同函数共用一个 `aspects` 条目），是比 ASP-L8 更严重的问题。另外 `m.get(...)` 只断言 `isSome()`（`73`），若返回了别的值（哈希/相等实现错位）也通过。
- **建议**：补 3 条负例 —— 不同 `funcName`、不同 `argTypes`、不同 `typeInfo` 的键分别 `!=` 且 `m.get(...).isNone()`；`testKeyUsedAsMapKeyHitsAcrossCalls` 增加 `@Assert(hit.getOrThrow(), 1)`。不要断言「哈希必不相等」（碰撞合法）。

### 18. [轻微][存量] `empty_chain_fastpath_test` 的判据依赖「没有切面匹配 `who`」这一未断言的隐性前提，且注释里的规则集已经过期

- **位置**：`src/test/empty_chain_fastpath_test.cj:32`（注释「现有规则只匹配函数名 n/p/m」）、`41-48`（用例）
- **来源**：存量（`git blame` 2026-10-05 `2c285e93b`「perf(f_aspect): ASP-L7 空链快路径」）
- **判据**：review-checklist §13（注释与实现不符）、§11（测试前提未固定）
- **证据**：静态确定 —— 同包测试注册的规则至少还有 `t`、`u`（`aspect_template_suppress_test.cj:49`、`61`）与 `r`（`recursion_guard_test.cj:39`），注释只列 `n/p/m`；用例本身没有任何「链为空」的观测或守卫。一旦有人新增一条宽匹配规则（如 `FuncTypeRouteRule("**", "*")`）或把某个切面改成匹配全部函数，`b.who()` 会因「链尾固化首实例」返回 1（#4），用例失败，但失败原因与它想验证的「空链在当前接收者上执行」无关，排查成本高。
- **描述**：这是本模块唯一覆盖「空链 + 多实例」的用例，其断言本身是有效的（修前 `b.who()==1` 会失败），但前提靠「恰好没有匹配规则」维持，注释又已经不准，属于可维护性隐患。
- **建议**：①注释改为「本模块测试注册的规则函数名为 n/p/m/t/u/r，均不匹配 `who`」，或在用例开头显式断言 `Aspects` 里该键为空链（需内部可见性入口）；②补一句注释说明「空链按当前接收者、非空链固化首实例」是有意差异（非空链的行为见 #4），避免后来者把它当 bug 修掉或误判。

### 19. [轻微][存量] 复制粘贴的 import 头里有未使用项（`std.collection` / `std.reflect` / 5 处 `fountain::f_base.*`）

- **位置**：`src/test/aspect_template_suppress_test.cj:20`（`import std.collection.*`）；`src/test/qualified_func_info_key_test.cj:21`（`import std.reflect.*`）；`src/test/empty_chain_fastpath_test.cj:20`、`src/test/pointcut_meta_cost_test.cj:21`、`src/test/pointcut_meta_reuse_test.cj:21`、`src/test/qualified_func_info_key_test.cj:22`、`src/test/recursion_guard_test.cj:21`（`import fountain::f_base.*`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定（第 1 处）+ 待确认（其余 6 处，未编译验证）——
  1. `aspect_template_suppress_test.cj` 只用到 `BaseException`、`InvocationFuncInfo`、`Aspects`、`BeanFactory`，未出现 `ArrayList/HashMap/HashSet` 等任何 `std.collection` 符号；
  2. 其余 5 个文件按符号逐个核对，只用到 `@Test`/`@TestCase`/`@Assert`（`std.unittest`）、`InvocationFuncInfo`/`QualifiedFuncInfo`/`Aspects`（`f_aspect`）、`BeanFactory`（`f_bean`）、`@WeavedBean`（`f_aspect.macros`）与 `ArrayList`/`HashMap`（`std.collection`），没有 `f_base` 的符号；`TypeInfo` 已由 `f_aspect` 的 `public import std.reflect.*`（`src/AspectRoute.cj:18`）转出——同包 `aspect_args_race_test.cj:22-23` 在无 `std.reflect` import 的情况下就使用了 `TypeInfo.of`，可作旁证；`qualified_func_info_key_test.cj` 亦无 `std.reflect` 直接符号。未编译验证，故标待确认。
- **建议**：删除后编译确认；若 `f_base` 是为宏展开隐式需要，则在 import 行加注释说明用途，避免下一轮重复误报。
- **严重程度合并**：本条并入原 part1 `#15`（轻微、静态确定）与 part2 `P2-7`（轻微、待确认），严重程度一致取**轻微**；证据等级按较弱者保守记为「待确认（6/7 处）」。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本节只有 1 条（CPU），无堆内存方案。**无改前/改后对照数据，不进 `todo.md` / `tasks.md`。**

### [CPU] 空链路径仍为每次调用构造 `Array<Any>` 实参 + `InvocationFuncInfo`

- **现状**：宏在每次调用处生成 `[p1, p2, …]`（`src/macros/PointCut.cj:62-77`）并构造 `InvocationFuncInfo`（`PointCut.cj:93-103`），即使该 `(类型, 函数)` 已知是空链（`src/Aspects.cj:101-103` 只需要 `funcInfo.args`）。存量"测量"仅来自 `pointcut_meta_cost_test` 的 `-O0` 单轮打印（被织入 ≈1867–2443 ns/次、未织入静态方法 ≈2 ns），该数据同时混有分派方式差异、墙钟计时与无预热/无重复的问题（判定见 #12），**不能作为基线**；同批 ASP-L7 去掉一层闭包 + 值类型装箱的实测差值"落在噪声内"，说明固定开销主要不在这两处，但分段占比未测。
- **方案**：把"实参数组的构造"推迟到确认非空链之后——例如 `Aspects.proceed` 增加一个重载，接收 `() -> Array<Any>`（或宏侧生成 `if (Aspects.isEmptyChain(key)) body() else proceed(...)` 的守卫）；零参/空链函数可完全省掉数组与 `InvocationFuncInfo`。链缓存键仍是静态 `QualifiedFuncInfo`（类级织入已有 `__pOIntcUt_*`），不增加查找次数。
- **预期**：只能给方向（每调用少 1 个数组 + 1 个 struct），**不给百分比**——`Array<Any>` 分配是否为主要项尚未测。
- **代价**：宏生成代码变复杂（多一个分支与一次静态键查询）；`Aspects.proceed` 公共签名新增重载（对外 API 面扩大）；切面重构实参的能力不变（非空链路径不变）。
- **验证**：同机 `-O2`，`pointcut_meta_cost_test` 与空链基线各 1e6 次、≥5 轮取中位数与离散；先用 `cjprof record/report` 给出 `Aspects.proceed` / 数组分配的自耗时占比，再决定是否实施。前提是先按 #12 修好基准（`MonoTime`、`-O2`、同构对照、多轮），否则改前改后都不可比。
- **证据状态**：`无基线（待验证，不进 tasks）`——原有 1867–2443 ns/次为 `-O0` 单轮打印值，经 #12 判定不可引用。

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。共 3 条（原 part1 2 条 + part2 2 条，其中两条"`proceed` 开销分段"同源已合并）。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Aspects.proceed` 每次调用 ~1.9 µs 里，`ConcurrentHashMap` 命中、`ThreadLocal.getOrCompute`、`Array<Any>`/`InvocationFuncInfo` 构造、空链闭包调用各占多少；`-O0` 与 `-O2` 下该差值差几个量级 | `src/Aspects.cj:59-109`、`src/macros/PointCut.cj:62-77`、`src/test/pointcut_meta_cost_test.cj:55-65` | 分段自耗时占比；两种优化级别的中位数 | 用例内改用 `MonoTime` 分段计时（进入 `proceed` 前 / map 命中后 / 返回前），`-O0` 与 `-O2` 各 5 轮取中位数与离散；或 `cjprof record` 跑 1e6 次 |
| 2 | 建链首调用存在明显延迟尖峰（遍历全部 Aspect bean + 注解 + 正则 + 可能触发 bean 实例化） | `src/Aspects.cj:61-100` | 首调用 vs 后续调用的 P50/P99 | 对同一 `(类型, 函数)` 打点：首次 `proceed` 与第 2 次起的耗时对比，10 个不同函数各 1000 次 |
| 3 | 用例执行顺序（`aspect_args_race_test` 先于 `pointcut_meta_reuse_test`）是否真的让 `metas` 的 `add` 在两线程重叠 | `src/test/pointcut_meta_reuse_test.cj:37/40/53`、`src/test/aspect_args_race_test.cj:81-93`、`src/Aspects.cj:61-96` | 实际用例顺序、链层序、`add` 的并发重叠 | 在 `MetaIdentityAspect.before` 里记录线程 id + 时间戳，`cjpm test` 全量跑 20 次；再用 `--filter` 固定「先 race 后 meta」单独复跑，看是否出现条目丢失/断言漂移 |

## 文件覆盖

> 与 `modules.md` 的 f_aspect 20 个源文件一一对应。合并后按模块顺序重排，两部分同一文件只保留一行。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/Aspect.cj` | .cj | ✅ | 默认模板异常语义已逐分支核对（含 final/throwing 抛异常的 suppressed 合并），未发现缺陷 |
| 2 | `src/AspectRoute.cj` | .cj | ✅ | 见发现 #1/#2/#3/#5/#15 |
| 3 | `src/Aspects.cj` | .cj | ✅ | 见发现 #4/#13；递归守卫、并发发布已核对 |
| 4 | `src/ConfigAspectRouteRule.cj` | .cj | ✅ | 见发现 #6（trim 不一致）、#11（无文档）、#16（无用形参） |
| 5 | `src/QualifiedFuncInfo.cj` | .cj | ✅ | 值语义 / 哈希与相等一致性已核对，无缺陷（键稳定性用例见 #17） |
| 6 | `src/exception/AspectBeforeException.cj` | .cj | ✅ | 4 个构造与父类一致；框架内不主动抛出，README 已声明 |
| 7 | `src/exception/AspectException.cj` | .cj | ✅ | 同上，无缺陷 |
| 8 | `src/imports.cj` | .cj | ✅ | 逐个核对 import 均有使用（`TypeCastException`、`Config`、`HashBuilder`、`BeanFactory` 等） |
| 9 | `src/macros/PointCut.cj` | .cj | ✅ | 见发现 #7/#8；静态元信息路径与回退路径已核对 |
| 10 | `src/macros/WeavedBean.cj` | .cj | ✅ | 见发现 #9（待确认） |
| 11 | `src/test/arg_annotations_route_test.cj` | .cj | ✅ | 断言与当前 `ArgAnnotationsRouteRule` 行为一致（等长校验、`*` 占位、"拥有"语义） |
| 12 | `src/test/arg_prefix_suffix_route_test.cj` | .cj | ✅ | 断言与 `matches(asc)` 的 `offset` 实现一致，无缺陷 |
| 13 | `src/test/aspect_args_race_test.cj` | .cj | ✅ | 并发交错用例；见发现 #13（全局注册、与 `m` 规则交叉） |
| 14 | `src/test/aspect_chain_capture_test.cj` | .cj | ✅ | 用例覆盖"逐调用实参"与"around 改参"；未覆盖多实例非空链（见 #4），注册不注销见 #13 |
| 15 | `src/test/aspect_template_suppress_test.cj` | .cj | ✅ | 断言与 `Aspect.proceed` 的 suppressed 语义一致；未用 import 见 #19，注册不注销见 #13 |
| 16 | `src/test/empty_chain_fastpath_test.cj` | .cj | ✅ | 断言对修前缺陷有效；前提与注释问题见 #18，`new` 与契约冲突并入 #4，未用 import 见 #19 |
| 17 | `src/test/pointcut_meta_cost_test.cj` | .cj | ✅ | 伪基准，见 #12；`-O2` 缺失依据 `cjpm.toml:11-12` |
| 18 | `src/test/pointcut_meta_reuse_test.cj` | .cj | ✅ | 元信息复用断言本身有效；全局状态导致断言漂移与数据竞争，见 #13 |
| 19 | `src/test/qualified_func_info_key_test.cj` | .cj | ✅ | 4 个正例与 `QualifiedFuncInfo` 实现一致；缺负例见 #17，未用 import 见 #19 |
| 20 | `src/test/recursion_guard_test.cj` | .cj | ✅ | 单次最外层语义正确；复位/线程隔离/重入未覆盖，见 #14 |
| — | `README.md` | .md | 部分 | **未全文审计**：仅作契约对照（`:61`、`:96-99`、`:100`、`:111`、`:120`、`:142`、`:251-252`、`:324-338`、`:374`）。`modules.md` 的 20 个计数不含 `.md`，两个部分均未按 §13 全文核对 |
| — | `README_en.md` | .md | 部分 | 同上，仅对照 `:106`。未全文审计 |

合计：`.cj` 20 个 / `.md` 0 个（清单内）/ 共 20 个，全部读完。

> **合并缺口（需补审）**：`README.md` 与 `README_en.md` 不在 `modules.md` 的 20 个源文件计数内，part1 声明「README 归第 2 部分」而 part2 清单只含 5 个 `.cj`，导致两份 README 均未做 §13 全文核对。本报告对 README 的结论（#10、#11 与各契约引用）只来自行号对照，不能视为已覆盖；建议另派一轮 README 审查，或在下一版报告补行。

## 覆盖自检

> 全部维度都已出现，命中 0 条也写了排除依据。命中数为 part1 + part2 去重后之和；同一发现可命中多个维度（如 #13 同时计 §11 与 §12.1），跨行不重复清零。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 16 | 去重后：part1 11 条 + part2 5 条（`P2-2`/`P2-6`/`P2-7` 已在别行合并，本行按各自原计数不重复）。分布：路由误判 5（#1/#2/#3/#5/#6）、宏生成代码 2（#7/#8）、多实例织入 1（#4）、重复织入待确认 1（#9）、文档 2（#10/#11）、测试有效性 3（#12/#13/#14）、断言完整性与前提 2（#17/#18）。测试代码无外部输入与凭据，安全性 0 |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` 符号搜引用（part1 覆盖 15 个文件，part2 覆盖 5 个测试文件）：`contains`、`matches(asc)`、`getConfig`、`doMatches`、`doProceed`、`emptyChain`、`recursion`、`RecursionState.state`、宏辅助 10 个函数、测试 `info`/`cStatic`（刻意未织入基线）均有调用者；`doMatches` 的 `funcInfo` 形参未用（#16）、未使用 import（#19，原 part1 #15 与 P2-7 合并）。`isAspect`（`AspectRoute.cj:52`）除定义外仓内零引用、`AspectBeforeException` 仅被 `public import`（`Aspect.cj:18`）导出且框架内不抛出——两者都对外可达（public 类成员 / public 导出），只记"对外 API，仓内无引用"，不判死代码 |
| §2 重复逻辑 | 1 | 已把 20 个文件的函数体压成"输入→输出→副作用"两两比对：part1 命中 3 组（注解判定、配置签名解析、"参数拥有注解"循环），合并为 #15；`Config*` 15 个包装类形状相似但属"每类一个配置键"的刻意适配，不计重复。part2 比对 5 个测试文件：`MetaIdentityAspect.before` 与 `RecursionCountAspect.before` 形状相近但分属两套准备代码（checklist §2 明列的测试准备代码误报边界），不计 |
| §3 空实现 | 0 | `Aspect.before`/`final` 是文档化的 no-op 扩展点；`RouteRule.init() {}` 是抽象类空构造；`Arg1/Arg2.init(){}` 为测试注解类；测试切面 `public init() {}` 是 `$register` 闭包所需；`before` 均有实际写入。无 `TODO`/`FIXME`/`UnsupportedException`/空 `catch`（`catch (_)` 仅 `PointCut.cj:82` 的 `decl.declType` 探空，属有意回退） |
| §4 栈溢出 | 0 | 唯一递归点是 `Aspects.proceed`→`Aspects.doProceed`→切面→原函数体；同线程重入被 `RecursionState` 守卫截断（`Aspects.cj:115-128`，用例见 #14）。`And/Or/NotRouteRule` 的匹配递归深度 = 开发者书写的规则表达式嵌套（编译期常量），无用户输入驱动。测试自身递归深度 4（`r(3)`），无输入驱动 |
| §5 OOM | 0 | `aspects` 静态 map 的键上界 = 织入函数数（ASP-8 已判设计）；值为定长闭包链；`doProceed` 每调用只分配 `Array<Any>`（长度 = 函数形参数）与一个 struct；路由规则对配置串 `split` 的长度由配置决定；测试静态容器增长量 = 调用次数（个位数）。无全量物化、无按不可信长度预分配、无只增不减的请求级容器 |
| §6.1 热点瓶颈 | 1 | #12（伪基准本身是本维度命中：只有 `-O0` 墙钟单轮数据，缺函数级自耗时占比与同构对照，结论不成立）。part1 原判 0 的依据是"未提供本轮 profile / bench 数据"，合并后依 part2 的证据改判为 1，缺的分段数据另列「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 唯一临界区是 `computeIfAbsent` 内的建链（遍历 Aspect bean + 正则匹配）；只在切点函数首次调用执行一次，ASP-6 已判定"一线程建链、其余等待"为性价比取舍，未发现锁内 I/O / 回调 / 嵌套取锁；测试代码无锁 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get`、无单消费者队列、无固定并发度 1 的任务批处理；`aspect_args_race_test` 的两线程握手是刻意并发，不是串行化 |
| §6.4 低效算法 | 0 | `Regex.wildcard` / 临时 `HashSet/ArrayList` / `BeanFactory.iterator` 全部只在建链时执行（ASP-L1/L2/L3 已判定不改）；热路径只有一次 map 查表与闭包链调用，无嵌套循环、无 `remove(at:0)`、无循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 无可量化的常驻对象（链条目上界 = 织入函数数；每调用对象均为短命小对象；测试容器上界 = 调用数）；无基线，不写方案 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 [CPU]」（空链路径的 args 数组延迟构造），证据状态为「无基线（待验证）」；part2 只有基准设施问题，已按缺陷记 #12，不重复计方案 |
| §9 local mode 可行性 | 0 | 函数内无大临时对象；每调用的 `Array<Any>` 与 `InvocationFuncInfo` 会逃逸到切面（`InvocationFuncInfo` 被切面保存/跨层传递），逃逸检查不通过，收益也无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 14 | 去重后：part1 9 条（#1–#9 对应原 #1–#9）+ part2 6 条（#12/#13/#14/#17/#18 对应 P2-1/P2-2/P2-3/P2-4/P2-5，P2-6 并入 #4 故 −1）= 14。即 #1–#9、#12、#13、#14、#17、#18。全部为存量（快照模式无 diff 基线），已用 `git blame` 标注提交（主要为 2026-10-02 `4be871f2fd`、2026-10-04 `3570d18100`、2026-10-05 `2c285e93b7`/`ad8cc477c`/`ba4288006`/`d69d2ce83`）；#9 为待确认 |
| §12 并发安全与锁粒度 | 1 | #13（测试切面跨线程写无同步 `ArrayList`，结构静态确定、重叠需实测）同时计入 §11。生产侧共享点与同步手段已列：`aspects` 为 `ConcurrentHashMap`（发布即不可变，`(Bool, 闭包)` 元组无后续写入）；递归状态为 `ThreadLocal<RecursionState>`（线程封闭，`finally` 复位）；切面实例的并发安全由切面实现负责（README §并发与线程安全 已声明）。未发现检查-然后-写入、双重检查锁、发布逸出或锁序问题；#14 指出该线程封闭结论目前无用例兜底 |
| §14 功能完备性与 README 覆盖 | 2 | 逐个对照 `src/` 公开声明与 README：`Aspect`、`@Pointcut`、`@WeavedBean`、`RouteRule`+运算符、`AspectRoute`、`InvocationFuncInfo`、`QualifiedFuncInfo` 与 19 个规则类均有小节；缺 `Config*RouteRule` 全家（基类 + 15 子类）与 `matchIfNone`（#11）；README 递归实现描述过期（#10）。#4 的「限制未文档化（`Aspects.cj:48`）」与 #8 的 §14.1 面按主维度计在 §11/§13，不在此行重复计数；测试侧 P2-6 的 §14.1 面已随 #4 合并 |
| 文件覆盖（§13 等） | 20/20（README 2 项未全文审计） | `modules.md` 的 20 个 `.cj` 全部读完（两部分各自声明 15/15 与 5/5）。`README.md`、`README_en.md` 不在该 20 计数内，只做行号契约对照，未按 §13 全文核对——见「文件覆盖」末尾的合并缺口说明 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 10 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

- 合并前：part1 严重 4 / 一般 7 / 轻微 4（15 条），part2 严重 0 / 一般 3 / 轻微 4（7 条），合计 22 条。
- 合并后 19 条：3 组同根因合并（#4←P2-6、#13←#14+P2-2、#19←#15+P2-7），并按更严格级别上调 2 条（#13 轻微→一般、#4 已为严重）。
- **存量 19 条**（全部为存量，本轮无本次改动）；是否纳入修复待用户决定。
- 待验证假设 3 条、README 覆盖缺口 1 项，均**不计入**上表。

## 总评

模块主体设计是清晰的：编译期宏织入（无动态代理）、切点匹配按 `(类型, 函数)` 只建一次链、实参逐调用传递（ASP-2）、默认 `proceed` 模板不丢异常（ASP-L5）、递归守卫线程封闭（ASP-L4）、空链快路径（ASP-L7）；`Aspect.cj` 的 try/catch/finally 合并逻辑逐分支核对无缺陷。测试侧的正向证据也在：`empty_chain_fastpath_test` 对 ASP-L7 修前缺陷确实敏感，`qualified_func_info_key_test` 的正例与 `QualifiedFuncInfo` 的 `refEq || 结构相等` + 结构哈希一致，`pointcut_meta_reuse_test` 用 `refEq` 观测"元信息只建一次"是合理黑盒观测。

**先裁决的 4 条严重项**：三条集中在**路由规则**（`TargetAnnotationRouteRule` 取错注解源、`ArgsRouteRule` 的 `**`、`ReturnTypeRouteRule` 的通配符 fallthrough），共同后果是"声明为合法的规则"每次调用都抛 `InfoNotFoundException` 或静默误判；其中后两条正是 `f_orm` 事务切面（`ConfigExecutionRouteRule`）会走到的路径，属于会在生产配置上复现的阻塞项。第四条是**非空链固化首次接收者**：对 prototype / 多例目标是执行错对象的方法体，与 `Aspects.cj:48`、`README.md:61` 声明的 prototype 支持冲突，且"手工 new 不支持"的限定只藏在注释里；合并入的 `P2-6` 说明现有 4 个测试本身就用手工实例，文档口径与测试写法已经互相矛盾。

**一般项 10 条**分三组：①规则侧输入校验缺失（`|`/`,` 不一致、配置解析不 trim），与三条严重项同源，建议与路由修复一并做，否则同一族规则还会继续出现"合法写法静默不匹配"；②宏健壮性 3 条（生成标识符冲突、按首个 `{` 截断签名、`@WeavedBean`+`@Pointcut` 未去重），不影响 f_orm/f_mvc 既有用法，但会让使用者在合法写法上踩编译失败或二次织入，属低成本可修；③测试可信度 3 条（伪基准 #12、全局状态与数据竞争 #13、递归守卫用例不敏感 #14）。第 ③ 组是本轮最值得注意的"隐性风险"：模块唯一的量化手段产出的是 `-O0` 单轮墙钟数字，唯一防无限递归的机制没有反向用例，唯一涉及多线程的用例自身带未承认的数据竞争——即当前"绿"的测试并不能支撑已有的性能与并发结论。

**轻微项 5 条**（重复逻辑、无用形参、缺负例、空链用例隐性前提与过期注释、未用 import）与 3 条待验证假设可排期。

**覆盖缺口**：`README.md` / `README_en.md` 未做 §13 全文核对（不在 20 个源文件计数内，两部分互相推诿），涉及 README 的结论（#10/#11 及契约引用）只基于行号对照，建议补一轮 README 审查后再定稿文档类结论。
