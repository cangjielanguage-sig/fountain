# f_bean 模块审查报告

> **模块第 2/2 部分**：只覆盖 `files/f_bean.part2.txt` 列出的 19 个文件（`lookup.cj`、`src/macros/**` 6 个、`src/test/**` 12 个）。容器主干（`BeanFactory` / `BeanManager` / 条件族 / 两份 README）由第 1 部分产出（`parts/f_bean.part1.md`），本报告不重复其结论，仅在需要判定本部分语义时引用其代码作为上下文。

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（本部分 19 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（HEAD `97507061b`，无 diff 可比 ⇒ 全部记「存量」；`git blame` 显示宏与测试文件来自 `4be871f2fd`(2026-10-02)，`Constructor.cj:40` 来自 `7e08b4b2e8`(2026-10-05)）
- **审查重点**：Bean 容器生命周期与线程安全、注册/查找冲突语义（重名必须报错）、惰性初始化与发布逸出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 2/2 部分；与 `parts/f_bean.part1.md` 合并为 `docs/review/2026-11-28/f_bean.md`）

## 发现

### [严重][存量] `@Configuration` / `@BeanInit` 把配置类自身当 bean 类型，文档示例与常规工厂方法一律编译失败

- **位置**：`f_bean/src/macros/Configuration.cj:27-31`（`registerByInstanceFunction<$identifier>` / `registerByStaticFunction<$identifier>`）、`f_bean/src/macros/Configuration.cj:41-44`、`f_bean/src/macros/Configuration.cj:53-57`
- **来源**：存量（快照模式，无基线可比；blame `4be871f2fd`）
- **判据**：review-checklist §14.1「承诺了但没实现」、§11「契约与实现不符」
- **承诺源**：`f_bean/README.md:474-475`「`@Configuration`修饰的类的所有被`@BeanInit`注解修饰的公共成员函数都是bean初始化函数，包括静态函数和实例函数」；`docs/speech/speech.md:1147-1152` 的示例就是 `public func initSomething(): Unit`
- **证据**：静态确定 —— `BeanFactory.cj:146-153` 两个注册入口的签名是 `registerByXxxFunction<T>(fnName: String, creator: () -> T)`，宏把 `T` 写死成配置类 `$identifier`，而生成的闭包体是 `$fnPrefix.<fnName>()`，其类型是该函数的**返回类型**。只要返回类型不是配置类本身（Service、接口、`Unit`），`() -> X` 就无法匹配 `() -> Config` ⇒ 编译失败。
- **描述**：`@Configuration` 唯一能编译的写法是「`@BeanInit` 方法返回配置类自身」，而这是无意义的自注册；任何按文档写的工厂方法（返回被打包对象的实例，或 `Unit` 做初始化）都在宏展开后类型不匹配。文档还承诺「被 `@Configuration` 修饰的类不会被 IOC 框架管理」，但宏注册的 bean 类型**就是**这个配置类，语义自相矛盾。全仓 `@Configuration` / `@BeanInit` 零使用、零用例，所以这个「完全不可用」的状态一直没被暴露。
- **建议**：把注册入口的类型实参改为该函数的**返回类型节点**（`FuncDecl` 的返回类型属性，属性名以 `std.ast` 文档为准）；返回 `Unit` 时 `diagReport(ERROR, …, '@BeanInit function must return the bean type')`。bean 名建议用方法名（需要给生成的注册补 `@BeanMeta[name:]` 或让 `BeanManager` 接受显式名），与「配置类不被管理」的表述一致。若短期不修，README 与 `docs/speech` 必须删掉这项能力，避免用户照抄即报错。

### [一般][存量] `@Constructor` 的静态工厂分支条件写反：普通静态工厂被拒、泛型静态工厂被接受后生成不可编译代码

- **位置**：`f_bean/src/macros/Constructor.cj:44-46`（`x.isGenericDecl` 守卫）、`f_bean/src/macros/Constructor.cj:56-60`（错误文案）、`f_bean/src/macros/Bean.cj:89-99`（生成的静态调用）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§1「恒真恒假分支」
- **承诺源**：`f_bean/README.md:455`「`@Constructor`修饰的构造函数或静态函数是bean的初始化函数」
- **证据**：静态确定 —— 守卫要求 `x.isGenericDecl`（**是**泛型）为真，而同一条 `case` 的错误文案写的是 `public static func without generic parameter`，两者相反。(a) 普通 `public static func create(): Foo` ⇒ `isGenericDecl == false` ⇒ 落到 `case _` 报 "must be a public constructor or public static func without generic parameter"；(b) 泛型静态函数 `public static func of<T>(): Foo` ⇒ 通过守卫，随后 `Bean.cj:95-98` 生成 `Foo.of($actualArgs)`，不带类型实参 ⇒ 无法推导 `T`，编译失败。
- **描述**：README 承诺的「静态工厂」两种形态都不可用，且方向相反：正常的被拒绝、异常的通过后再炸。全仓没有 `@Constructor` + 静态函数的用例（`grep @Constructor` 只命中 `constructor_param_test.cj`、`obj_test.cj` 的构造函数），问题长期潜伏。
- **建议**：守卫改为 `!x.isGenericDecl`；同时校验返回类型与 `beanType` 一致（`Bean.cj:100-102` 生成的是 `register<$beanType>{…}`，返回 `Other` 时同样是类型不匹配，应给 `diagReport` 而不是让编译器在展开产物上报错）。

### [一般][存量] `@BeanParam` 三个属性分支全部不可用：字符串分支产出类型不匹配代码、白名单大小写错、简写分支恒假且越界

- **位置**：`f_bean/src/macros/BeanParam.cj:23`（字符串字面量分支）、`f_bean/src/macros/BeanParam.cj:24-32` 与 `:37-42`（条件名白名单）、`f_bean/src/macros/BeanParam.cj:42`（`attr[3]` 越界）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」「契约与实现不符」、§2「字面量复制（同一张白名单写两遍且写错）」
- **承诺源**：`f_bean/README.md:458-460`「本宏的属性是表示StringCond枚举实例的Tokens」
- **证据**：静态确定，三处独立：
  1. `case (STRING_LITERAL, _) => attr` 直接把 cond 设成字符串字面量，而 `Constructor.cj:87-96` 生成的调用形参是 `cond: StringCond`（`lookupList` / `lookup<X>` 等）⇒ `@BeanParam['beanName']` 展开后是 `lookupList<T>('beanName')`，`String` 与 `StringCond` 不匹配，编译失败；
  2. 白名单写的是小写 `'prefix'` / `'wildcard'`（`:27`、`:38`），而 `StringCond` 的 case 是 `Prefix` / `Wildcard`（`BeanStringCondition.cj:40,48`）⇒ `@BeanParam[StringCond.Prefix("x")]`、`@BeanParam[StringCond.Wildcard("x")]` 被 `diagReport` 拒绝；`Contains` / `In`（`BeanStringCondition.cj:56,60`）根本没进白名单；
  3. 简写分支条件是 `attr.size == 3`，而 `Exactly('x')` 是 4 个 token（`Exactly` `(` `'x'` `)`）⇒ 该分支**恒假**；若真以 3 个 token 进入，末尾的 `attr[3].kind == RPAREN` 直接越界（宏展开期抛异常）。结果 `@BeanParam[Exactly('x')]` 落到 `case _` 报错，而不带限定的 `IgnoreCond` 简写却是支持的（`:36`），两种简写待遇不一致。
- **描述**：实际只有 `StringCond.Xxx('…')` 与 `StringCond.IgnoreCond` 两种写法能通过；README 说「表示 StringCond 枚举实例的 Tokens」，而仓内既有代码与测试都是无限定写法（`Exactly(...)`、`Wildcard(...)`，见 `bean_getfirst_test.cj:71`、`bean_lookup_test.cj:187`），照此写 `@BeanParam` 必然报错。全仓 `@BeanParam` 零使用、零用例。
- **建议**：白名单收敛为一个 `isCondName(name)` 判定（`Exactly|Prefix|Suffix|Wildcard|Regexp|Contains|In`，两份调用共用一个函数，避免再次漂移）；简写分支改 `attr.size == 4`；字符串分支改为 `quote(StringCond.Exactly($attr))`；每个分支先做 size/kind 校验，不合法一律 `diagReport` + `return`。

### [一般][存量] `@Value` 对非 `Option` 的 `String` 缺省时静默注入空串：必填配置缺失不报错

- **位置**：`f_bean/src/macros/Value.cj:41-46`（`Config.getString($name) ?? ''`）；对照 `:47-63`（`DateTime` / `Duration` 无 default 时生成 `?DateTime`/`?Duration`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失或静默」「与规格不一致」
- **证据**：静态确定 —— `f_config/src/Config.cj:186-198` 的 `getString` 在缺键时返回 `None<String>`；宏对非 Option 的 `String` 形参直接 `?? ''` ⇒ 缺失的必填配置变成空串。同一宏对 `DateTime`/`Duration` 走 `Config.getValue<T>()`（`Config.cj:207-209`，缺键返回 `?T`），与形参类型不匹配 ⇒ 这些类型反而**编译失败**，用户被迫写 `default`。
- **描述**：同一个「缺必填配置」场景行为分成三类：String 静默空串、DateTime/Duration 编译期报错、`Array<T>` 走 `getStringArray` 静默空数组（`Config.cj:210-217`）。空串最危险——DB 地址、密钥路径、必填开关名会一路带到下游才炸，错误现场离配置错误很远。
- **建议**：非 Option 且无 `default` 的 String 改为 `Config.getString($name).getOrThrow { Exception('config item ${name} is required') }`，或统一在宏期 `diagReport` 要求必须给 `default`；README 的 `@Value` 片段（`README.md:466-470`）补一句「必填项也应给 default，否则启动失败/编译失败（按类型不同）」。

### [一般][存量] `lookup*` 门面没有「容器已就绪」检查：启动早期查找会漏 bean / 拿到随后被淘汰的 bean / 提前实例化

- **位置**：`f_bean/src/lookup.cj:26-30`、`:40-42`、`:157-162`（全部 `lookup*` 直接转 `BeanFactory.instance`，无任何前置校验）；生成端 `f_bean/src/macros/Bean.cj:80-102`（注册代码在模块静态初始化里执行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 错误处理缺失」、§12.1「可见性与生命周期」
- **证据**：静态确定 —— `BeanFactory` 的就绪标志是 `private let registered`（`BeanFactory.cj:44`），下游无法查询；`getFirst`/`getList`/`iterator` 全都不检查它。`afterRegistered()`（`BeanFactory.cj:154-163`）才执行 `check()`（按条件淘汰）与 `initBeansIfNeed()`。注册端经 `topMacroAnonymousClosure`（`f_macros/src/topMacroAnonymousClosure.cj:20-30`）展开为模块级 `private let _ = {=> … }()`，早于 `InitializerCollection.initialize()` → `BeanInitializer.initialize()` → `afterRegistered()`。测试文件自己把这条当成「现状」钉住了：`src/test/bean_def_condition_test.cj:44-51` 与 `:108-114` 断言「条件恒假的 bean 在 `afterRegistered()` 之前 `lookupList` 仍可见」。
- **描述**：在别的模块的静态初始化、或 `@Bean` 类的字段初始化器里（README:29 就是这种写法）调用 `lookup`，会出现三种后果：① 看不到尚未加载模块注册的 bean ⇒ `BeanException('bean type X … does not exist')`，信息指向「没有这个 bean」而不是「容器还没初始化」，启动期极难定位；② 拿到随后被 `check()` 淘汰的 bean（条件不成立），实例既不受容器管理、也不会被 `shutdown` 销毁（`BeanFactory.cj:49-53` 只遍历 `beans`）；③ 提前实例化本应 lazy 的 singleton、或多造 prototype 实例，打乱 `@PostConstruct` 与 `initBeansIfNeed` 的顺序。
- **建议**：`BeanFactory` 暴露 `public func isReady(): Bool`（或 `ensureReady()`），`lookup*` 在未就绪时抛 `BeanException('BeanFactory is not initialized: call afterRegistered() before lookup')`；若确实要支持启动期查找，需要「延迟解析占位符」，成本高，不建议。README:29 的字段初始化器示例应改为构造器注入或 `@PostConstruct`。

### [一般][存量] `lookupLabelOption` / `lookupLabel` 用「全量物化 + 线性扫描」实现「取一个」：会实例化该类型全部 bean

- **位置**：`f_bean/src/lookup.cj:119-124`（`lookupLabelOption`）、`:108-112`（`lookupLabel`）、`:95-101`（`lookupLabels`，同族但语义上确实需要全部）
- **来源**：存量（快照模式，无基线可比；历史记录 `.autocode/bugs/bug-bean-archived-20261006.md:142-150` 曾以 `BEAN-L4` 冻结此项）
- **判据**：review-checklist §11「语义与实现不符 / 副作用超出契约」、§6.4「只判存在却全量扫描」
- **证据**：静态确定 —— 走 `lookupList<T>(cond)` → `BeanFactory.getList` → `getListByType`（`BeanFactory.cj:274-283`），对桶内**每个** manager 取 `m.bean`；`BeanManager.bean` 对 prototype 每次 `new()`（`BeanManager.cj:114-116`），并调用 `@PostConstruct`（`:77-86`）。而「取一个」的 `lookup<T>` 走 `getFirstByType`（`:236-258`），只对第一个命中的 manager 取实例。
- **描述**：按 label 查**一个** bean 的代价是「实例化该类型全部 bean」：prototype 每次多造 N-1 个实例（构造副作用、`@PostConstruct` 全部执行、返回后无人销毁），只要其中任意一个构造抛异常，即便目标 label 的 bean 完全正常，整个 `lookupLabel` 也会失败。`lookupLabel` 的签名（找不到才抛）会让人误以为它是轻量调用。与同库 `lookup<T>` 的惰性口径直接冲突。
- **建议**：把 label 条件下推到迭代器：`for (m in BeanFactory.instance.iterator<T>(cond: cond) where … )`，先比 `label` 再取 `m.bean`，命中即返回；`lookupLabels` 保留全量（语义需要），但可去掉中间 `ArrayList`（见「优化可行性方案」）。若维持现状，至少在函数注释与 README 写明「会实例化该类型全部 bean」。

### [一般][存量] `lookupLabels` / `lookupWeights` 的 Map 键冲突静默覆盖，与 README「全部 bean」不符

- **位置**：`f_bean/src/lookup.cj:95-101`（`map[bean.label] = bean`）、`:130-144`（`map[w] = bean`，`w` 为累计权重）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「数据丢失 / 静默」、§13「承诺与实现不符」
- **承诺源**：`f_bean/README.md:110,113`（`lookupLabels`「获取……全部bean」）、`README.md:124,127`（`lookupWeights` 同）
- **证据**：待确认 —— 需要两个 bean 的 `label` 相等，或某个 bean 的 `weight` 是加法零元（0）导致累计键重复；仓内没有 `BeanLabel` / `BeanWeight` 的实现（全仓 grep 只命中接口定义 `BeanLabel.cj:18` / `BeanWeight.cj:18` 与 README），无法用现有用例证伪。
- **描述**：两个 API 都用「Map 赋值」收集，键冲突时后者静默覆盖前者：返回值里少 bean，无日志、无异常。`lookupWeights` 更隐蔽——键是**累计和**，只有 0 权重或负权重才冲突，而「0 权重 = 临时禁用某策略」是很自然的写法，一旦出现就丢一个 bean。README 明确写「全部 bean」，属契约不符。
- **建议**：`lookupLabels` 冲突时抛 `BeanException('duplicate bean label …')`（与 `BeanFactory.doRegister` 的重名策略一致），或返回 `HashMap<L, ArrayList<T>>`；`lookupWeights` 改为 `TreeMap<W, ArrayList<T>>`，或在累计值重复时抛异常。至少在 README 写明「label 必须唯一、weight 必须为正」。

### [轻微][存量] 公开 API 名拼写错误 `lookupOptionLable`，同族缺 `lookupLabelOption(name:,label:)`，异常文案不含 label

- **位置**：`f_bean/src/lookup.cj:116-118`（`lookupOptionLable`）、`:105-107`（`lookupLabel(name:,label:)` 没有对应的 `?T` 变体）、`:109-111`（`BeanException` 文案）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可读性 / 命名」、§11「语义与命名不符」
- **证据**：静态确定 —— 全仓 grep `Lable` 只此一处，零调用者；同族已有 `lookupLabelOption(label:)`（`:113`）与 `lookupLabelOption(cond:,label:)`（`:119`），唯一缺的就是 `(name:,label:)`，而它被错拼成 `lookupOptionLable`（词序也反了）。`lookupLabel<L,T>(label:)` 走 `IgnoreCond`，抛出的文案是「bean type X with bean name condition IgnoreCond does not exist」，完全看不到要找的 label。
- **描述**：用户按同族命名写 `lookupLabelOption(name:, label:)` 会找不到符号，只能去翻源码发现 `lookupOptionLable`；异常信息也无法定位是哪个 label 缺失，尤其在 label 是枚举、一次查多个的场景。
- **建议**：新增 `lookupLabelOption(name: String, label: L)`，旧名保留转发（本项目允许破坏性变更，也可直接改名并在 README 标注）；文案补 `${label}`，并区分「按名字查不到」与「名字命中但 label 不匹配」。

### [轻微][存量] §2 重复逻辑：集合填充、容器注入分支、DateTime/Duration 解析各写多份

- **位置**：`f_bean/src/lookup.cj:52-66` 与 `:68-81`（`lookupHashSet` / `lookupTreeSet` 仅集合类型不同）；`f_bean/src/macros/Constructor.cj:87-121`（6 个容器 case 在「有 cond」与「无 cond」两支里各写一遍）；`f_bean/src/macros/Value.cj:47-63` / `:70-80` / `:98-108`（DateTime）与 `:58-63` / `:81-85` / `:109-113`（Duration）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」「跨分支复制」「字面量复制」
- **证据**：静态确定 —— 逐行比对：两个 `lookup*Set` 的输入（`cond`）、过滤（`iterator<T>(cond:)` + `if (let bean: T <- m.bean)`）、输出（集合）完全一致，差异只有 `HashSet`/`TreeSet`；`argTokens` 两支的唯一差异是 cond 的来源；`Value` 的三份 DateTime 处理逐 token 相同（含 `dateFormat` 分支），Duration 同理。
- **描述**：重复本身已经造成漂移：`lookupHashSet` / `lookupTreeSet` 的注释各自粘贴了同一段 `BEAN-L5` 说明；`Value` 里 `Option<DateTime>` 与 `?DateTime` 两段必须同步改三次，后续加类型（如 `LocalDate`）会漏改其中一处。
- **建议**：`lookup*Set` 抽一个 `private func fillSet<T, S>(set: S, cond: StringCond)`（两个集合的约束不同，泛型参数需同时带 `Hashable & Equatable<T>` 与 `Comparable<T>`，或保留两份并注明「刻意重复以维持 where 约束」）；`argTokens` 先算出 `cond: Tokens`（`beanCond` 命中 → 该 cond；否则按名回退），再统一走一次容器分支；`Value` 把「按形参类型选解析器」提成一个局部函数，三处只负责拆 `Option` / `?`。

### [轻微][存量] 3 个公开重载未进 README，label / weight 两族 API 全仓零测试

- **位置**：`f_bean/src/lookup.cj:105-107`、`:108-112`、`:119-124` ↔ `f_bean/README.md:491`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「公开 API 未文档化」「示例覆盖不足」
- **证据**：静态确定 —— README:491 只列了 `lookupLabel(label:)`、`lookupLabelOption(label:)`、`lookupOptionLable(name:,label:)` 三个；`lookupLabel(name:,label:)`、`lookupLabel(cond:,label:)`、`lookupLabelOption(cond:,label:)` 在 README 全文检索不到（`grep lookupLabel` 仅命中该行）。同时 `grep -rl` 覆盖 `f_bean/src/test/**`：`lookupLabels`、`lookupLabel`、`lookupLabelOption`、`lookupOptionLable`、`lookupWeights` **零命中**。
- **描述**：6 个 label 重载里 3 个不可发现；label 三件套与 `lookupWeights` 没有任何回归网，本报告 #6/#7 的语义问题因此长期存在且无人察觉（历史 `BEAN-L4` 也是先冻结、后遗忘）。
- **建议**：README 合并成一节「按 label / 权重查询」列出 6 个重载 + 2 个 Map 语义说明；为 `BeanLabel` / `BeanWeight` 各补一个最小用例，至少覆盖「重复 label」「0 权重」「cond 过滤」「空结果」四个边界。

### [轻微][存量] 测试注释描述的是「修前」行为，与同文件断言和现实现矛盾

- **位置**：`f_bean/src/test/bean_def_condition_test.cj:23-32`（称 `case (IgnoreType, IgnoreName)` 仍是 catch-all、名条件/count/scope 全被忽略）、`:96-97`（把 `SuperOfOnly` 判真解释成「存在类型为 Any/Object 的 bean」）、`f_bean/src/test/bean_iterator_test.cj:24-31`（称 `iterator` 每次建 filter 闭包并逐元素 `matches`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— `BeanDefCondition.cj:121-126` 已改成 `case (IgnoreType, IgnoreCond) => return true`（`BEAN-L12` 已修），同文件 `:73-85` 的断言正是「名条件生效」，与头部注释相反；`BeanFactory.cj:466-473` 已加 `cond.ignored` 快路径并去掉逐元素子类型复检；`SuperOfOnly` 分支扫的是 `Object` 桶（`BeanDefCondition.cj:130`），而每个 bean 都入 `Object` 桶（`BeanFactory.cj:78-81`），所以判真的原因是「`BeanDefSampleA` 自身在桶里」，与「Any/Object 类型的 bean」无关。
- **描述**：三处注释把「优化前/修复前」写成了「现状」。维护者按注释理解会误判当前语义（尤其第一处，读者会以为名条件、count、scope 全部失效），也会误判 `SuperOfOnly` 的适用条件。
- **建议**：注释改为「历史缺陷已修（`BEAN-L12`），本文件钉住修复后行为」；`SuperOfOnly` 的解释改成「样本自身也在 Object 桶内」；`bean_iterator_test` 头部改成「修前热点（逐元素 matches + 每次建闭包），现已被 `cond.ignored` 快路径与桶内子类型保证取代」。

### [轻微][存量] 测试里存在永真断言、从不执行的 bean、赋值后不读的字段

- **位置**：`f_bean/src/test/bean_test.cj:21-27`（`println(b)`，无任何断言）、`f_bean/src/test/bean_scope_test.cj:80-81`（`inited == eagerMgr.initIfNeed() || !inited`）、`f_bean/src/test/generic_bean_test.cj:31-35`（`TestBean` 的两个私有字段）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」「仅测试使用」、§11「语义与断言不符」
- **证据**：静态确定 —— `BeanTest.test` 只打印 `?B`，除了抛异常不可能失败；`inited == f() || !inited` 在 `inited == false` 时恒真，等于没断言（且按第 1 部分「严重 二次创建」的现状，`initIfNeed` 第二次仍返回 `true`，这个断言恰好掩盖了它）；`TestBean` 是 lazy 单例，全仓没有任何 `lookup<TestBean>()` ⇒ 字段初始化器里的 `lookup<TestGenericBean<String>>()` / `lookupList<AbstractBean>()` 从未执行，两个字段也从未被读。
- **描述**：三处用例给人「已覆盖」的错觉：`bean_test` 覆盖零行为；`bean_scope_test:81` 掩盖了单例二次创建；`generic_bean_test` 既没验证泛型 bean 的注入，也没验证 `@Bean[String|Int64]` 的第二组实参。
- **建议**：`bean_test` 改 `@Assert(b.isSome(), true)` 或直接删除；`bean_scope_test:81` 改成精确断言（第二次 `initIfNeed()` 应为 `false`，并配合计数器断言「只构造一次」——当前实现会失败，正是第 1 部分那条严重缺陷的表现）；`generic_bean_test` 补 `lookup<TestBean>()` 并断言 `list.size == 2`、`lookupOption<TestGenericBean<Int64>>().isSome()`。

### [轻微][存量] `@Bean` 宏的两条静默路径：`@Bean[|]` 不注册任何 bean；泛型类漏写属性时生成缺类型实参的代码

- **位置**：`f_bean/src/macros/Bean.cj:68-78`（`removeIf` 清空后循环不执行）、`:74-78`（`g.size == 0` 时 `quote($identifier)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「空实现 / 开关打开后走进空分支」、§11「错误处理缺失」
- **证据**：静态确定 —— `@Bean[|]` 的 attr 只有 `BITOR`：`list` 初始 `[empty]`，循环首次 `add(quote())` 变 `[empty, empty]`，`size > 1` 触发 `removeIf` 全部删除 ⇒ `list.size == 0`，`for (g in list)` 一次都不执行，一条注册代码都不生成，也没有 `diagReport`。`@Bean public class Foo<T>` 时 `g.size == 0` ⇒ `beanType` 只有 `Foo`，生成的 `Foo()` / `register<Foo>` 缺类型实参。
- **描述**：前者表现为「编译通过但运行时 BeanException does not exist」，排查成本高；后者报的是与 `@Bean` 无关的泛型实参错误。README:23-30 要求泛型必须给属性，但没有强制。
- **建议**：`list.isEmpty()` 时 `diagReport(ERROR, attr, '@Bean requires at least one type argument group')`；`klass` 带泛型参数且 attr 为空时同样 `diagReport('@Bean on generic class requires type arguments, e.g. @Bean[String]')`。

### [轻微][存量] `@Value` 属性解析没有边界校验：缺值越界、未知 key 静默跳过

- **位置**：`f_bean/src/macros/Value.cj:22-38`（`attr[i + 2]` 无长度校验、`case _ => i++`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」「错误处理缺失」
- **证据**：静态确定 —— `@Value[name]` 时 attr 只有 1 个 token，`attr[i + 2]` 越界，宏展开期抛索引异常（用户看到编译器内部堆栈，而非「配置宏写法错误」）；`@Value[name 'x']`（漏冒号）走 `case _ => i++`，`name` 保持空 ⇒ 生成 `Config.getString()`（缺参数）后在类型检查阶段报错；`delim` / `dateFormat` 同理。
- **建议**：解析循环改为「读到 key 后校验 `i + 2 < attr.size` 且 `attr[i + 1].kind == COLON`，否则 `diagReport`」；未知 token 直接 `diagReport`，错误信息里列出合法 key（`name` / `default` / `dateFormat` / `delim`）。

### [轻微][存量] `@Configuration` 无条件构造配置类；带参/非 public 的 `@BeanInit` 静默跳过；类注释写成 `@Constructor`

- **位置**：`f_bean/src/macros/Configuration.cj:19`（注释）、`:53-57`（无条件 `let configuration = <Class>()`）、`:41-46`（`f.funcParams.isEmpty()` 不满足时 `break`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」、§3「静默跳过」、§11「语义与注释不符」
- **证据**：静态确定 —— 宏对每个被修饰类都生成 `let configuration = Class()`，只有存在实例 `@BeanInit` 才会用到；只写静态方法或没有 `@BeanInit` 时它是死变量（unused 警告 + 一次无意义构造，配置类构造若有副作用会被提前触发）。带参或 package-private 的 `@BeanInit` 走 `case _ => break`，既不注册也不报错。类注释（`:19`）写的是「被 `@Constructor` 修饰的函数」，实际处理的是 `@BeanInit`。
- **描述**：配置类被无故实例化；用户把 `@BeanInit` 写成带参或非 public 时「看着编译通过」，实际没有任何 bean 注册，运行期才以「bean 不存在」暴露。
- **建议**：仅在 `instanceTokens` 非空时生成 `configuration`；`@BeanInit` 命中但签名不符时 `diagReport('@BeanInit function must be public, non-generic and take no parameters')`；注释改为 `@BeanInit`。

> **范围外提示**（第 1 部分文件，不计入本轮统计）：`BeanFactory.getFirstByType`（`BeanFactory.cj:242`）与 `getFirstByAnnotation`（`:328`）用 `return m.bean as T`，一旦运行时实例类型与注册的 `beanType` 不一致（`FactoryBean` 声明与实际产出不符时可能发生），会直接返回 `None` 而不是继续看下一个候选，最终表现为「bean 存在却报 does not exist」。

## 优化可行性方案

> 不是缺陷，是"还能更好"。每条都必须可执行、可验证。

### [堆内存] `lookupLabels` / `lookupWeights` 直接填充目标 Map，去掉中间 `ArrayList`

- **现状**：两个函数都先 `lookupList<T>(cond)` 物化 `ArrayList<T>`（N = 同类型 bean 数，`ArrayList` 从 0 容量多次扩容），再遍历它建 `HashMap` / `TreeMap`；单次调用峰值同时持有 2N 个引用（list + map），调用结束即释放。同族的 `lookupHashSet` / `lookupTreeSet` 在 `BEAN-L5` 里已经改成「直接向目标集合填充」（`lookup.cj:57-58,73`），这两个仍是旧形状。
- **方案**：与 `lookupHashSet`（`lookup.cj:59-65`）同形：`for (m in BeanFactory.instance.iterator<T>(cond: cond)) { if (let bean: T <- m.bean) { map[bean.label] = bean } }`，`lookupWeights` 在其上维护累计权重。
- **预期**：每次调用少一次 `ArrayList` 分配与 N 次 `add`/扩容，峰值引用数从 2N 降到约 N（map 本身）。收益量级待测，不写成百分比。
- **代价**：与 `lookupList` 的「元素集合、顺序、实例化次数」必须逐字一致（`iterator` 与 `getList` 共用 `iteratorByType`，现有 `bean_lookup_test` 的等价性断言可复用）；`lookupWeights` 的累计顺序依赖迭代顺序，需保证与 `getList` 同序。
- **验证**：`cjprof heap` / `getAllocatedHeapSize()` 对 10k 次调用改前改后对照，同时断言两个 Map 的键值集合与旧实现完全相同（含空结果、cond 过滤）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注解查询每次全桶线性扫描 + `isSubtypeOf`，注解桶大时成为查询热点 | `f_bean/src/lookup.cj:150-205`、`BeanFactory.cj:324-373` | 自耗时占比、单桶平均大小 | `cjprof record` 跑 fdemo 启动 + 每请求一次的 `lookupByAnnotation`，输入取真实 bean 数 |
| 2 | `lookupLabelOption` 的全量物化带来的构造与分配开销显著（尤其原型 bean） | `f_bean/src/lookup.cj:119-124` | 每次调用实例化个数、分配字节、ns/op | 12 个 prototype bean 场景，1 万次调用分段计时，改前/改后对照 |
| 3 | `lookupHashMap` / `lookupLabels` 的 Map 从 0 扩容是查询路径的主要分配来源 | `f_bean/src/lookup.cj:87-101` | 扩容次数与分配字节 | 对比「先用 `lookupList.size` 建容量」的版本，`cjprof heap` |
| 4 | `@Constructor` 展开的注入在启动期是「每形参一次线性扫描 + 容器重建」，bean 多时占比可观 | `f_bean/src/macros/Constructor.cj:87-121` | 启动总耗时占比 | fdemo 启动分段计时（`afterRegistered` 前后打点）+ `cjprof` 过滤 `getListByType` |

## 文件覆盖

> 与 `{workdir}/files/f_bean.part2.txt` 一一对应，**一行都不能少**。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_bean/src/lookup.cj` | .cj | ✅ | 见「一般 `lookupLabelOption` 全量物化」「一般 Map 键冲突」「轻微 拼写/重载/文案」「轻微 §2 重复」「轻微 README 未收录」 |
| 2 | `f_bean/src/macros/Bean.cj` | .cj | ✅ | 见「轻微 `@Bean[|]` 静默 / 泛型漏属性」；`Constructor` 消息分支与 `Constructor.cj` 一致 |
| 3 | `f_bean/src/macros/BeanParam.cj` | .cj | ✅ | 见「一般 三个分支全部不可用」 |
| 4 | `f_bean/src/macros/Configuration.cj` | .cj | ✅ | 见「严重 bean 类型写死」「轻微 无条件构造/静默跳过/注释错」 |
| 5 | `f_bean/src/macros/Constructor.cj` | .cj | ✅ | 见「一般 静态工厂守卫写反」「轻微 §2 重复」 |
| 6 | `f_bean/src/macros/Value.cj` | .cj | ✅ | 见「一般 String 静默空串」「轻微 无边界校验」「轻微 §2 重复」 |
| 7 | `f_bean/src/macros/imports.cj` | .cj | ✅ | `std.ast` / `ArrayList` / `HashMap` / `f_macros` / `exception` 均被同包文件使用，无死 import |
| 8 | `f_bean/src/test/bean_annotation_lookup_test.cj` | .cj | ✅ | 覆盖自身/父类/接口/元注解位置、`T` 过滤、原型不误实例化；断言与实现一致，无问题 |
| 9 | `f_bean/src/test/bean_annotation_meta_test.cj` | .cj | ✅ | 元注解链用例，与 `doRegister` 的注解节点展开一致，无问题 |
| 10 | `f_bean/src/test/bean_def_condition_test.cj` | .cj | ✅ | 见「轻微 注释描述修前行为」；`:44-51`/`:108-114` 是 #5（无就绪检查）的现状证据 |
| 11 | `f_bean/src/test/bean_getfirst_test.cj` | .cj | ✅ | 类/接口/父类/Any/Object 键与 `Exactly` 语义钉住，含 bench 打印；无断言缺陷 |
| 12 | `f_bean/src/test/bean_iterator_test.cj` | .cj | ✅ | 见「轻微 注释描述修前行为」；`seen == 29n` 与三段循环计数吻合 |
| 13 | `f_bean/src/test/bean_lookup_test.cj` | .cj | ✅ | 集合/Map 等价性覆盖完整；12 个同构 bean 属测试夹具，不计重复 |
| 14 | `f_bean/src/test/bean_scope_test.cj` | .cj | ✅ | 见「轻微 近似恒真断言」 |
| 15 | `f_bean/src/test/bean_string_cond_test.cj` | .cj | ✅ | `on` 语义 + 注册表联用覆盖到位；bench 打印无畸形 |
| 16 | `f_bean/src/test/bean_test.cj` | .cj | ✅ | 见「轻微 只打印无断言」 |
| 17 | `f_bean/src/test/constructor_param_test.cj` | .cj | ✅ | `ArrayList`/`Array`/`HashSet`/`Set`/`HashMap`/`Map`/`?T` 七种注入形态覆盖，与 `Constructor.cj` 生成逻辑一致 |
| 18 | `f_bean/src/test/generic_bean_test.cj` | .cj | ✅ | 见「轻微 死字段 / 从不实例化的 bean」 |
| 19 | `f_bean/src/test/obj_test.cj` | .cj | ✅ | `A`/`B` + `@Constructor` 构造注入，被 `bean_test` 使用；无问题 |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完。

## 覆盖自检

> 全部维度都必须出现，命中 0 条也要写理由。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 5（静态工厂守卫写反、`@BeanParam` 三分支、`@Value` 静默空串、`lookupLabelOption` 全量物化、Map 键冲突）；设计 2（`@Configuration` 类型实参写死、`lookup*` 无就绪检查）；可读性 1（`lookupOptionLable` 拼写 + 文案缺 label）；安全性 0（本部分无外部输入、无 SQL/HTML/路径拼接，宏只处理编译期常量 token） |
| §1 死代码 | 2 | 逐个 `private` / 局部符号搜引用：`Bean.cj` 的 `expand`/`expandClassDecl`/`expandBean`、`Constructor.cj` 的 `constructor`/`argTokens`、`Configuration.cj` 的局部 `expandFuncTokens`、`Value.cj`/`BeanParam.cj` 的局部 `setItem`、测试里的 `collectNames`/`WILD_PATTERN` 等均有调用者；`protected` 本部分为零。命中 2 条：`BeanParam.cj:37-42` 恒假分支（并入「一般 @BeanParam」）、`generic_bean_test.cj:31-35` 赋值后不读的字段 + 从不实例化的 `TestBean`（并入「轻微 弱测试」）。对外可达 `public`（`lookupLabels`/`lookupLabel*`/`lookupOptionLable`/`lookupWeights`/全部 `lookup*ByAnnotation*`、`@BeanParam`/`@Value`/`@Configuration` 宏）仓内零引用**不判**，仅记信息；无未使用 import |
| §2 重复逻辑 | 3 | 同文件与跨文件两两比对函数体「输入→输出→副作用」+ 搜重复字面量：命中 `lookupHashSet`/`lookupTreeSet`（仅类型名不同）、`argTokens` 的 6 路容器分支两份、`Value` 的 DateTime/Duration 三段；另 `BeanParam` 白名单字面量重复两次已并入其缺陷条。判为非重复：`lookupLabels` vs `lookupWeights`（label vs 累计权重，语义不同）、`lookupHashMap` vs `lookupMapByAnnotation`（键来源不同）、测试里 12 个同构 `LookupItem`（测试夹具，checklist 豁免） |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/`UnsupportedException`；`quote()` 空 token 是宏构造器不是空函数；`topMacroAnonymousClosure` 捕获异常后 `printStackTrace` 并重新抛出，不是静默吞异常；“签名不符静默跳过”归到 §1/§14 的 `@Configuration` 条 |
| §4 栈溢出 | 0 | 本部分无运行期递归：`lookup*` 全是单层委托；宏侧 `constructor`（`Constructor.cj:39-62`）对 `MacroExpandDecl` 链自递归，深度 = 源码里注解嵌套层数（编译期常量、无环）；`BeanParam`/`Value` 用 `while` 解链，不是递归 |
| §5 OOM | 0 | 全部集合按注册表 bean 数建（N）并立即返回，无按不可信长度预分配、无只增不减容器、无闭包长期持有；`lookupLabelOption` 的重复实例化归到 #6（副作用/分配，不是无界增长） |
| §6.1 热点瓶颈 | 0 | 本部分没有 profile / bench 结果；测试文件里的 `BENCH` 打印本轮未运行、无基线数值，因此 4 条候选全部进「待验证假设」，未作为发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`lookup*` 是无状态委托，宏在编译期执行 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理；测试里的循环都是单线程基准 |
| §6.4 低效算法 | 0 | `lookupLabelOption` 的 O(n) 全扫已按「语义不符 + 多余实例化」报在 #6，未按性能结论计；其余查询都是 `HashMap.get` + 桶迭代，n = 同类型 bean 数，量级极小，无数据支撑热点判定 |
| §7 降堆内存方案 | 1 | `lookupLabels` / `lookupWeights` 去掉中间 `ArrayList`（无基线，标注待验证） |
| §8 降 CPU 方案 | 0 | 唯一有形状的候选（注解查询全桶扫描）缺自耗时占比，进「待验证假设」#1；无数据前不写方案 |
| §9 local mode 可行性 | 0 | 不适用：`lookup*` 的返回值都是逃逸的集合/bean，宏在编译期运行，本部分没有「函数内创建、函数内释放」的大对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 7 | 本轮读到的 19 个文件边界/空值/错误处理/契约均过了一遍，命中：静态工厂守卫写反、`@BeanParam` 三分支、`@Value` 静默空串、`lookup*` 无就绪检查、`lookupLabelOption` 全量物化、Map 键冲突、`@Value` 属性越界。核对后判为非缺陷：`lookup*` 空结果（`ArrayList`/`HashMap`/`None` 均显式返回）、`lookup<T>` 的 `getOrThrow` 文案（类型与 cond 都在）、`Constructor.cj` 的 `not.kind` 分支（命名实参 `x: x` 生成正确）、`Bean.cj` 的 `$identifier<$g>`（分组非空时实参个数由用户保证） |
| §12 并发安全与锁粒度 | 0 | 本部分没有共享可变状态：`lookup*` 无成员、无缓存；宏与测试夹具的 `AtomicInt64`（`bean_scope_test.cj:30`、`bean_annotation_lookup_test.cj:109`）用原子 API。读路径无锁依赖「启动后只读」契约，其竞争面与 `afterRegistered` 幂等性属 `BeanFactory`（第 1 部分已报），本条只在门面侧报「无就绪检查」（#5） |
| §14 功能完备性与 README 覆盖 | 2 | 命中：`@Configuration`/`@BeanInit` 承诺 vs 实现完全不可用（#1）；3 个公开重载未进 README + 4 个 API 族零测试（#10）。逐项对照公开声明后，`lookupByAnnotation*` 全族、`lookupHashSet`/`lookupTreeSet`/`lookupHashMap`、`lookupList` 均已在 README 有独立小节且签名一致；`@BeanParam`/`@Value` 有文档但无任何用例（已在 #3/#4 记录） |
| 文件覆盖（§13 等） | 19/19 | 无缺文件；本部分不含 `.md`，文档一致性由第 1 部分覆盖（本报告只引用 README 作为承诺源，并已核对行号） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量缺陷合计 15 条（严重 1 / 一般 6 / 轻微 8），是否纳入修复待用户决定。

## 总评

本部分由「查询门面 + 4 个宏 + 12 个测试文件」组成。查询门面的主体是机械转发，接口形状与 README 基本对得上；容器主干的生命周期/线程安全风险已在第 1 部分报出，这里只剩两个语义层面的问题：`lookupLabel*` 用全量物化实现「取一个」（会实例化该类型全部 bean，副作用与 `lookup<T>` 的惰性口径冲突），以及 `lookup*` 没有任何「容器已就绪」闸门（启动早期的查找会漏 bean、拿到随后被淘汰的实例，报错还指向「bean 不存在」）。这两条在真实应用里能被观察到，建议排期修。

真正薄弱的是宏。四个宏里只有一个（`@Bean`）在主路径上可用：`@Configuration`/`@BeanInit` 把配置类自身写死成 bean 类型，按文档写就编译失败；`@Constructor` 的静态工厂守卫写反，普通静态工厂被拒、泛型静态工厂放行后再生出缺类型实参的代码；`@BeanParam` 的三个属性分支分别产出类型不匹配代码、拒绝合法条件名、或恒假加越界；`@Value` 对必填 String 静默注入空串。共同原因是这批宏**全仓零使用、零用例**——`@Configuration`、`@BeanParam`、`@Value` 在仓库里找不到任何调用点，`lookupLabels`/`lookupLabel*`/`lookupWeights` 也没有任何测试，于是它们从写下那天起就没人跑通过，注释与测试注释也停在「修前」状态。修复顺序建议：先定 `@Configuration` 的取舍（补实现或删文档），再修 `@Constructor`/`@BeanParam` 的守卫与白名单（这两处是「照文档写就报错」，用户第一时间会撞上），最后补 label/weight 两族的最小用例，把 #6/#7 的语义固定下来。

测试方面，集合/Map/注解三族的行为钉得不错（含顺序、空结果、原型不误实例化），但存在永真断言、从不实例化的 bean 与描述旧行为的注释，会让后续改动误以为有覆盖。
