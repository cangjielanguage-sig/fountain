# f_aspect 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_aspect`（20 个源文件；本部分 `src/` 10 个 + `src/test/` 5 个，共 15 个）
- **基线**：工作区快照（`scope.md` 记录：当前检出 `sts/1.3.x`、未对照远端目标分支、工作区干净）
- **审查重点**：AOP 路由 / 织入正确性、递归保护、并发安全、宏展开、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（第 1/2 部分，待与 part2 合并为 `docs/review/f_aspect_review_20261128.md`）

> 范围声明：本部分只审任务列出的 15 个文件。文中出现的 `f_aspect/README.md`、`f_bean`、`f_config`、`f_orm`、`f_base` 路径仅作为契约 / 调用方取证上下文，不展开审查（README 与其余 5 个测试文件归第 2 部分）。
> 已知背景：模块历史问题在 `.autocode/bugs/bug-aspect-archived-20261006.md` 有判定记录（ASP-1/6/7/8/9 等），本报告对"已被判为设计"的条目只在与当前代码事实冲突时重新提出，并注明冲突点。

## 发现

### 1. [严重][存量] `TargetAnnotationRouteRule` 匹配的是"函数注解"而不是"目标类型注解"，与自身契约相反且与 `FuncAnnotationRouteRule` 完全重复

- **位置**：`src/AspectRoute.cj:228-231`（类注释 `223-227`；README 契约 `f_aspect/README.md:324-338`）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）、§13（文档与实现相反）、§2（重复逻辑）
- **证据**：静态确定 ——
  1. 类注释与 README 都写"如果**目标类型**有指定类型的注解则目标类型的全部公共实例函数将被织入"；
  2. 实现 `contains(funcInfo.funcInfo.annotations, ...)` 取的是 `InstanceFunctionInfo`（函数）的注解，`funcInfo.funcInfo` 即 `_funcInfo.funcInfo`（`QualifiedFuncInfo.cj:48-52`）；
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

### 4. [严重][存量] 非空切面链固化首次调用的 `callee`（含接收者）：多实例场景执行错误实例的方法体

- **位置**：`src/Aspects.cj:74`（`var f: (Array<Any>) -> Any = {args => fn(args)}`，配合 `91-96`、`101-109`）；`src/macros/PointCut.cj:99-104`（生成 `func callee(...)` 捕获 `this`）
- **来源**：存量（`git blame` 2026-10-05 `2c285e93b7`，ASP-L7 空链修复同批；`fn` 捕获本身属 ASP-1 判定的设计）
- **判据**：review-checklist §11（逻辑错误）、§12.1（跨实例共享可变状态语义）、§13（`Aspects.cj:48` 注释与 README 声明支持 prototype）
- **证据**：静态确定 ——
  1. 链缓存的键是 `QualifiedFuncInfo`（类型 + 函数），与实例无关（`Aspects.cj:60-61`）；
  2. 有切面命中时链尾 `{args => fn(args)}` 直接捕获**首次调用**传入的 `fn`，而宏生成的 `fn` 是方法体内的嵌套函数 `callee`，隐式捕获该次调用的 `this`（`PointCut.cj:99-104` 把原函数体整体搬进 `callee`，函数体里的字段/方法访问都落到该 `this`）；
  3. 空链路径已在 ASP-L7 改为"在本次调用的接收者上执行"（`Aspects.cj:101-103`；存量记录见 `.autocode/bugs/bug-aspect-archived-20261006.md:190`：`empty_chain_fastpath_test.cj` 修前 `b.who()` 读到 1，修后读到 2）；**非空链一字未改**，因此同样的两实例场景只要有一个切面命中，`b.m()` 仍执行 `a` 的函数体；
  4. `Aspects.cj:48` 注释明写"被织入的对象必须是 IoC 管理的 bean（**singleton 或 prototype 均可**）"，README 亦写"同一类型的多个实例共享同一条切面链"（`README.md:61`）——即已承认链共享，但未说明接收者也被固化。
- **描述**：prototype 目标（或多例 singleton）调用被织入方法时，**方法体在首个实例上执行**：字段读写落到错误对象、`this` 相关逻辑（事务/日志/审计切面里传递的业务对象）全部错位，且不报错。`@WeavedBean` 默认 singleton 掩蔽了该问题，prototype bean 才会暴露。ASP-1 的"设计"判定理由是"匹配结果只取决于签名、与实例无关"——该理由不覆盖"链尾捕获的是接收者绑定的 callee"，因此本条不是对同一判定的重复。
- **建议**（按代价从低到高）：①链只缓存 `ArrayList<BeanManager>`（切面列表），每次调用现场按本次 `fn` 组装（每调用 1 个闭包/层，可接受）；②缓存"链构造器"并在调用时传入 `fn`；③若坚持固化，则在 `Aspects.proceed` 入口按目标实例判等（`refEq`）拒绝非首次实例，并在 README 明确"prototype 目标不支持织入"。无论哪种，都应补一条"有切面命中 + 两实例各调一次"的用例（现有 `empty_chain_fastpath_test` 只覆盖空链）。

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
- **建议**：三个配置类统一走一个 `parseFuncDecl`（见 #12）并在其中统一 `trimAscii`；解析失败抛带原串的 `AspectException` 而不是裸 `InfoNotFoundException`；补"签名里带空格"的用例。

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

- **位置**：`f_aspect/README.md:100`（`README_en.md:106` 同）对 `src/Aspects.cj:32-34`、`112-122`
- **来源**：存量（`git blame`：README 该段 2026-10-05 `c8c6c532de` 写入，代码 `Aspects.cj:32-34` 为 2026-10-05 `ba4288006d`；两者同日但内容不一致）
- **判据**：review-checklist §13（文档过期：描述的功能已改名 / 实现已替换）
- **证据**：静态确定 —— README 写"实现位于 `recursiveInvocationFlag`（`private static let ... = ThreadLocal<Bool>`）… `finally { remove() }`"；代码里 `recursiveInvocationFlag` 与 `ThreadLocal<Bool>` 均已不存在，实际是 `private class RecursionState { var state = false }` + `ThreadLocal<RecursionState>` + `getOrCompute`，`finally` 里是 `st.state = false`。
- **建议**：把 README/README_en 该段改为 `recursion`（`ThreadLocal<RecursionState>`）与 `state` 字段，删掉 `remove()` 表述。README 全文归第 2 部分，本条仅记录与本节代码的冲突。

### 11. [一般][存量] `Config*RouteRule` 全家（基类 + 15 个子类）与 `matchIfNone` 在 README 中无任何小节

- **位置**：`src/ConfigAspectRouteRule.cj:21-36`（基类 + `matchIfNone`）与 `37-245`（15 个子类）；README 仅 `f_aspect/README.md:111`、`120` 提到 `Config*RouteRule` 的名字
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 关键配置无文档 → 一般）
- **证据**：静态确定 —— 全仓检索 README：`ConfigExecutionRouteRule`、`ConfigWithinRouteRule`、`ConfigBeanNameRouteRule` 等类名与参数名 `matchIfNone` 均**零命中**（只有第 111 行的 `ConfigAspectRouteRule` 作为示例名出现）。基类 + 15 个子类都是对外可达的 public API（`ConfigRouteRule` 为 `public abstract`），且只有一个生产消费者（`f_orm/.../TransactionAspect.cj:26` 用 `ConfigExecutionRouteRule`）。
- **描述**：使用者拿不到这些类的信息：配置键怎么给、`config` 字符串格式（`ExecutionRouteRule` 的 `qualifiedName.funcName(argTypes):returnType`，`|` 分隔多条）、`matchIfNone=false` 表示"配置缺失即不匹配"、解析失败抛 `AspectException`。README 只在 §异常 提了一句"配置字符串不合法抛 `AspectException`"。按文档无法使用配置式切点。
- **建议**：新增"配置式路由规则"小节：基类签名 + `matchIfNone` 语义 + 各子类的配置格式表（至少 `ConfigExecutionRouteRule` / `ConfigFuncTypeRouteRule` / `ConfigArgAnnotationsRouteRule` 三类给格式说明与示例）。

### 12. [轻微][存量] 重复逻辑：注解判定与配置签名解析各有两份同语义实现

- **位置**：
  1. `src/AspectRoute.cj:228-231` ≡ `243-246`（`TargetAnnotationRouteRule` / `FuncAnnotationRouteRule`，逐行相同，差异只有类名）；
  2. `src/ConfigAspectRouteRule.cj:104-114` ≡ `135-146`（`ConfigFuncTypeRouteRule` / `ConfigFuncRouteRule` 的 `colon/rparen/lparen/returnType/argTypes` 解析完全相同，后者只多取 `funcName`）；
  3. `src/AspectRoute.cj:269-272` ≈ `311-314` ≈ `196-205`（"某参数是否拥有某注解"的三份循环，前两处为精确全限定名比较，第三处按 `sub` 走子类型比较）。
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §2（跨方法/跨文件复制；差异点只有"取哪个对象/是否比较子类型"）
- **证据**：静态确定（函数体逐行对齐；差异已在上方列出：错误文案、`funcName` 提取、`sub` 分支）
- **描述**：第 1 处已导致实际缺陷（见 #1）；第 2 处意味着修 `ConfigFuncTypeRouteRule` 的 trim 时容易漏改另一处（本次即两处都缺少 trim，见 #6）；第 3 处三份实现的"拥有"语义若有一处改动就会漂移。
- **建议**：第 1 处按首条严重修复后自然合并；第 2 处抽 `private func parseFuncDecl(s: String): (String, String, String)`（返回 `(qualifiedName/name, argTypes, returnType)`）供两个配置类共用；第 3 处抽 `private func paramHasAnnotation(param, name: String, sub: Bool): Bool`。

### 13. [轻微][存量] `ConfigRouteRule.doMatches` 的 `funcInfo` 形参从未使用

- **位置**：`src/ConfigAspectRouteRule.cj:29`（15 个调用点全部传了 `funcInfo`，如 `42`、`71`、`82`…）
- **来源**：存量（`git blame` 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §1（读了不用 / 无用形参）
- **证据**：静态确定 —— 函数体 `29-35` 只读 `getConfig(config)`、`matchFn`、`matchIfNone`，`funcInfo` 无任何出现；15 个子类的 `matches` 仍逐个传参。
- **建议**：删掉该形参与调用点实参（`protected`，仅本模块子类使用）；若为后续"按函数缓存解析结果"预留，则加注释说明并给出使用它的 TODO 计划。

### 14. [轻微][存量] 三个测试文件向全局 `BeanFactory` 注册 bean 后不注销，且切面链缓存不可清理

- **位置**：`src/test/aspect_args_race_test.cj:75`、`src/test/aspect_chain_capture_test.cj:83`、`113`、`src/test/aspect_template_suppress_test.cj:78`、`97`；对照 `src/Aspects.cj:51`（静态 map 无 `clear/refresh`）
- **来源**：存量（测试与 `Aspects` 缓存均为快照现状；ASP-8 已判定"缓存不失效"为设计）
- **判据**：review-checklist §1（注册了不注销）、§11（测试隔离）
- **证据**：静态确定 —— 五处 `BeanFactory.instance.register<X>(...)` 均无对应注销（`f_bean` 侧也未提供测试用清理入口，检索 `unregister`/`func remove` 均零命中）；`Aspects.aspects` 一旦为某 `(类型, 函数)` 建链就永久复用，因此"先注册切面再跑用例"的顺序一旦被 shard/重排打破，用例会静默走空链（断言失败且原因难定位）。
- **描述**：不影响产品代码，但用例对执行顺序敏感：同进程内先跑过某个 `(类型, 函数)`（例如将来新增一个同名函数用例）后，再注册匹配切面不会生效。当前各用例的 `(类型, 函数)` 互不重叠，所以暂时绿。
- **建议**：给 `Aspects` 加 `internal static func resetCacheForTest()`（或 `@TestOnly` 等价物）供 `tearDown` 调用；测试里用 unique 类型名隔离（现做法），并在用例注释写明"必须先注册再首调用"的约束。

### 15. [轻微][存量] 未使用的 import

- **位置**：`src/test/aspect_template_suppress_test.cj:20`（`import std.collection.*`）
- **来源**：存量
- **判据**：review-checklist §1（未使用 import）
- **证据**：静态确定 —— 该文件只用到 `BaseException`、`InvocationFuncInfo`、`Aspects`、`BeanFactory`，未出现 `ArrayList/HashMap/HashSet` 等任何 `std.collection` 符号。
- **建议**：删除该 import。

## 优化可行性方案

> 本节不是缺陷。没有改前/改后对照数据的一律标"待验证"，不进 `todo.md` / `tasks.md`。

### [CPU] 空链路径仍为每次调用构造 `Array<Any>` 实参 + `InvocationFuncInfo`

- **现状**：宏在每次调用处生成 `[p1, p2, …]`（`PointCut.cj:62-77`）并构造 `InvocationFuncInfo`（`PointCut.cj:93-103`），即使该 `(类型, 函数)` 已知是空链（`Aspects.cj:101-103` 只需要 `funcInfo.args`）。存量测量：`pointcut_meta_cost_test` 1e6 次调用，被织入 ≈1867–2443 ns/次、未织入同体静态方法 ≈2 ns（`.autocode/bugs/bug-aspect-archived-20261006.md:110-113`、`191`）；同批 ASP-L7 去掉一层闭包 + 值类型装箱的实测差值"落在噪声内"，说明固定开销主要不在这两处，但分段占比未测。
- **方案**：把"实参数组的构造"推迟到确认非空链之后——例如 `Aspects.proceed` 增加一个重载，接收 `() -> Array<Any>`（或宏侧生成 `if (Aspects.isEmptyChain(key)) body() else proceed(...)` 的守卫）；零参/空链函数可完全省掉数组与 `InvocationFuncInfo`。链缓存键仍是静态 `QualifiedFuncInfo`（类级织入已有 `__pOIntcUt_*`），不增加查找次数。
- **预期**：只能给方向（每调用少 1 个数组 + 1 个 struct），**不给百分比**——`Array<Any>` 分配是否为主要项尚未测。
- **代价**：宏生成代码变复杂（多一个分支与一次静态键查询）；`Aspects.proceed` 公共签名新增重载（对外 API 面扩大）；切面重构实参的能力不变（非空链路径不变）。
- **验证**：同机 `-O2`，`pointcut_meta_cost_test` 与空链基线各 1e6 次、≥5 轮取中位数与离散；先用 `cjprof record/report` 给出 `Aspects.proceed` / 数组分配的自耗时占比，再决定是否实施。
- **证据状态**：`无基线（待验证）`——只有总开销的存量数据（1867–2443 ns/次 vs 2 ns），缺分段占比。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Aspects.proceed` 的每次调用 ~1.9 µs 里，`ConcurrentHashMap.get` 与 `Array<Any>`/`InvocationFuncInfo` 构造各占多少 | `src/Aspects.cj:59-109`、`src/macros/PointCut.cj:62-77` | 各段自耗时占比 | 在 `pointcut_meta_cost_test` 里分段计时（构造 args / map 命中 / 空链分支），或 `cjprof record` 跑 1e6 次 |
| 2 | 建链首调用存在明显延迟尖峰（遍历全部 Aspect bean + 注解 + 正则 + 可能触发 bean 实例化） | `src/Aspects.cj:61-100` | 首调用 vs 后续调用的 P50/P99 | 对同一 `(类型, 函数)` 打点：首次 `proceed` 与第 2 次起的耗时对比，10 个不同函数各 1000 次 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_aspect/src/Aspect.cj` | .cj | ✅ | 默认模板异常语义已逐分支核对（含 final/throwing 抛异常的 suppressed 合并），未发现缺陷 |
| 2 | `f_aspect/src/AspectRoute.cj` | .cj | ✅ | 见发现 #1/#2/#3/#5/#12 |
| 3 | `f_aspect/src/Aspects.cj` | .cj | ✅ | 见发现 #4/#14；递归守卫、并发发布已核对 |
| 4 | `f_aspect/src/ConfigAspectRouteRule.cj` | .cj | ✅ | 见发现 #6（trim 不一致）、#11（无文档）、#13（无用形参） |
| 5 | `f_aspect/src/QualifiedFuncInfo.cj` | .cj | ✅ | 值语义 / 哈希与相等一致性已核对，无缺陷（键稳定性另有 part2 用例） |
| 6 | `f_aspect/src/exception/AspectBeforeException.cj` | .cj | ✅ | 4 个构造与父类一致；框架内不主动抛出，README 已声明 |
| 7 | `f_aspect/src/exception/AspectException.cj` | .cj | ✅ | 同上，无缺陷 |
| 8 | `f_aspect/src/imports.cj` | .cj | ✅ | 逐个核对 import 均有使用（`TypeCastException`、`Config`、`HashBuilder`、`BeanFactory` 等） |
| 9 | `f_aspect/src/macros/PointCut.cj` | .cj | ✅ | 见发现 #7/#8；静态元信息路径与回退路径已核对 |
| 10 | `f_aspect/src/macros/WeavedBean.cj` | .cj | ✅ | 见发现 #9（待确认） |
| 11 | `f_aspect/src/test/arg_annotations_route_test.cj` | .cj | ✅ | 断言与当前 `ArgAnnotationsRouteRule` 行为一致（等长校验、`*` 占位、"拥有"语义） |
| 12 | `f_aspect/src/test/arg_prefix_suffix_route_test.cj` | .cj | ✅ | 断言与 `matches(asc)` 的 `offset` 实现一致，无缺陷 |
| 13 | `f_aspect/src/test/aspect_args_race_test.cj` | .cj | ✅ | 并发交错用例；见发现 #14（全局注册） |
| 14 | `f_aspect/src/test/aspect_chain_capture_test.cj` | .cj | ✅ | 用例覆盖"逐调用实参"与"around 改参"；未覆盖多实例非空链（见发现 #4） |
| 15 | `f_aspect/src/test/aspect_template_suppress_test.cj` | .cj | ✅ | 断言与 `Aspect.proceed` 的 suppressed 语义一致；见发现 #15（未用 import） |

合计：`.cj` 15 个 / `.md` 0 个（本部分）/ 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 路由误判（#1/#2/#3/#5/#6）、宏生成代码（#7/#8）、多实例织入（#4）、重复织入待确认（#9）、文档（#10/#11） |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` 符号搜引用：`contains`、`matches(asc)`、`getConfig`、`doMatches`、`doProceed`、`emptyChain`、`recursion`、`RecursionState.state`、宏辅助 10 个函数、测试 `info` 均有调用者；`doMatches` 的 `funcInfo` 形参未用（#13）、测试一个未用 import（#15）。`isAspect`（`AspectRoute.cj:52`）除定义外仓内零引用、`AspectBeforeException` 仅被 `public import`（`Aspect.cj:18`）导出且框架内不抛出——两者都对外可达（public 类成员 / public 导出），只记"对外 API，仓内无引用"，不判死代码 |
| §2 重复逻辑 | 1 | 已把 15 个文件的函数体压成"输入→输出→副作用"两两比对：命中 3 组（注解判定、配置签名解析、"参数拥有注解"循环），合并为 #12；`Config*` 15 个包装类的构造/`matches` 形状相似但属"每类一个配置键"的刻意适配，差异是类语义，不计重复 |
| §3 空实现 | 0 | `Aspect.before`/`final` 是文档化的 no-op 扩展点；`RouteRule.init() {}` 是抽象类空构造（子类 `super()` 用）；`Arg1/Arg2.init(){}` 为测试注解类；无 `TODO`/`FIXME`/`UnsupportedException`/空 `catch`（`catch (_)` 仅 `PointCut.cj:82` 的 `decl.declType` 探空，属有意回退） |
| §4 栈溢出 | 0 | 唯一递归点是 `Aspects.proceed`→`Aspects.doProceed`→切面→原函数体；同线程重入被 `RecursionState` 守卫截断（`Aspects.cj:115-128`，用例 `recursion_guard_test` 在 part2）。`And/Or/NotRouteRule` 的 `matches` 递归深度 = 开发者书写的规则表达式嵌套（编译期常量），无用户输入驱动，不构成无界递归 |
| §5 OOM | 0 | `aspects` 静态 map 的键上界 = 织入函数数（ASP-8 已判设计）；值为定长闭包链；`doProceed` 每调用只分配 `Array<Any>`（长度 = 函数形参数）与一个 struct；路由规则对配置串 `split` 的长度由配置决定；无全量物化、无按报文长度预分配、无只增不减的请求级容器 |
| §6.1 热点瓶颈 | 0 | 未提供本轮 profile / bench 数据；只有存量总开销（1867–2443 ns/次 vs 2 ns，引用于"优化可行性方案"），缺分段占比与自耗时占比，按要求只进"待验证假设"#1/#2 |
| §6.2 大粒度锁 | 0 | 唯一临界区是 `computeIfAbsent` 内的建链（遍历 Aspect bean + 正则匹配）；只在切点函数首次调用执行一次，ASP-6 已判定"一线程建链、其余等待"为性价比取舍，本轮未发现新的锁内 I/O / 回调 / 嵌套取锁 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get`、无单消费者队列、无固定并发度 1 的任务批处理 |
| §6.4 低效算法 | 0 | `Regex.wildcard` / 临时 `HashSet/ArrayList` / `BeanFactory.iterator` 全部只在建链时执行（ASP-L1/L2/L3 已判定不改）；热路径只有一次 map 查表与闭包链调用，无嵌套循环、无 `remove(at:0)`、无循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 无可量化的常驻对象（链条目上界 = 织入函数数；每调用对象均为短命小对象）；无基线，不写方案 |
| §8 降 CPU 方案 | 1 | 见"优化可行性方案 [CPU]"（空链路径的 args 数组延迟构造），证据状态为"无基线（待验证）" |
| §9 local mode 可行性 | 0 | 函数内无大临时对象；每调用的 `Array<Any>` 与 `InvocationFuncInfo` 会逃逸到切面（`InvocationFuncInfo` 被切面保存/跨层传递），逃逸检查不通过，收益也无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 9 | 发现 #1–#9（#9 为待确认）；#10/#11 属文档维度（§13/§14）。全部为存量（快照模式，无 diff 基线），已用 `git blame` 标注提交（主要为 2026-10-02 `4be871f2fd`、2026-10-04 `3570d18100`、2026-10-05 `2c285e93b7`） |
| §12 并发安全与锁粒度 | 0 | 已列出共享点与同步手段：`aspects` 为 `ConcurrentHashMap`（发布即不可变，`(Bool, 闭包)` 元组无后续写入）；递归状态为 `ThreadLocal<RecursionState>`（线程封闭，`finally` 复位）；切面实例的并发安全由切面实现负责（README §并发与线程安全 已声明，singleton 复用 / prototype 每次取）；未发现检查-然后-写入、双重检查锁、发布逸出或锁序问题。`RecursionState` 每线程一份、随线程存活，不构成泄漏（上界 = 线程数） |
| §14 功能完备性与 README 覆盖 | 2 | 已逐个对照 `src/` 公开声明与 README：`Aspect`、`@Pointcut`、`@WeavedBean`、`RouteRule`+运算符、`AspectRoute`、`InvocationFuncInfo`、`QualifiedFuncInfo` 与 19 个规则类均有小节；缺 `Config*RouteRule` 全家（基类 + 15 子类）与 `matchIfNone`（#11）。README 递归实现描述过期（#10） |
| 文件覆盖（§13 等） | 15/15 | 任务列出的 15 个文件全部读完；README 归第 2 部分，未计入本部分覆盖表（仅作契约对照） |

## 模块统计

> 仅统计本部分（15 个文件）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量缺陷 15 条（本部分全部为存量，无本次改动）；是否纳入修复待用户决定。

## 总评

本部分代码的主体设计是清晰的：编译期宏织入（无动态代理）、切点匹配按 `(类型, 函数)` 只建一次链、实参逐调用传递（ASP-2）、默认 `proceed` 模板不丢异常（ASP-L5）、递归守卫线程封闭（ASP-L4）、空链快路径（ASP-L7）——这几处此前的修复是到位的，`Aspect.cj` 的 try/catch/finally 合并逻辑逐分支核对无缺陷。

真正需要先裁决的是 4 条严重项：三条集中在**路由规则**（`TargetAnnotationRouteRule` 取错注解源、`ArgsRouteRule` 的 `**`、`ReturnTypeRouteRule` 的通配符 fallthrough），它们会让"声明为合法的规则"每次调用都抛异常或静默误判；其中 `ArgsRouteRule` / `ReturnTypeRouteRule` 两条恰好是 `f_orm` 事务切面（`ConfigExecutionRouteRule`）会走到的路径。另一条是**非空链固化首次接收者**，对 prototype / 多例目标是执行错对象的方法体，与 `Aspects.cj:48` 与 README 声明的 prototype 支持冲突（ASP-1 的"设计"判定未覆盖接收者，建议重新裁决或明确写进限制）。

宏侧 3 条一般项（生成标识符冲突、按首个 `{` 截断签名、`@WeavedBean` 与 `@Pointcut` 叠加未去重）不影响当前 f_orm/f_mvc 的既有用法，但会让使用者在合法写法上踩到编译失败或二次织入，属于"低成本可修"的健壮性问题。另有两条规则侧一般项（#5 `AnyArgAnnotationsRouteRule` 的 `|`/`,` 不一致、#6 配置签名解析不 trim），共同特征是"合法写法静默不匹配"，与三条严重项同源（缺输入校验），建议与路由规则修复一并处理。其余为文档（README 递归实现过期、`Config*RouteRule` 无文档）与测试隔离 / 重复逻辑类轻微项，可排期。
