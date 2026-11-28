# f_bean 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（37 个 `.cj` 源文件 + `README.md` / `README_en.md`，共 39 个文件）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git log` 顶部 `8c0ce643a`，工作区干净，仅有 `reviews/` 过程目录）⇒ 全部发现统一记「存量（无基线可比）」
- **审查重点**：Bean 容器生命周期与并发、条件求值、宏展开正确性、测试覆盖反向验证、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（由 `reviews/202611280829_full/parts/f_bean.part1~3.md` 合并；同根因跨部分条目已合并为一条并列全位置，未发现合并后严重程度冲突）

## 发现

### [严重][存量] `setShouldInitBean()` 对容器行为没有任何影响，公开契约实为空操作

- **位置**：`f_bean/src/imports.cj:40-44`（定义）；读点 `f_bean/src/BeanFactory.cj:196`、`f_bean/src/BeanManager.cj:70`
- **来源**：存量（`git blame -L 36,44 -- f_bean/src/imports.cj` 早于本轮全部提交）
- **判据**：review-checklist §3（公开契约承诺行为但实现不生效）/ §11（契约与实现不符）
- **证据**：静态确定 —— `shouldInitBean` 是**模块级 `let`**（`imports.cj:40`），在 f_bean 这个动态库被加载、模块全局初始化时求值一次并把结果固化；`setShouldInitBean(value)`（`:42-44`）只调用 `Config.set<Bool>([(SHOULD_INIT_BEAN_CONF_KEY, value)])`。`f_config/src/Config.cj:107-129` 的 `Config.set` 只写 `ARGS` 并向 `REFRESHER` 注册表派发回调，而全仓没有任何代码为 `shouldInitBean` 前缀调用 `Config.refresher(...)`（`grep -rn "refresher(" f_*/src` 无与本键相关注册）。应用侧也没有 `main`（见 `fountain-baseline.md` §1），所有业务代码都在模块加载、即 `let` 求值之后才执行，因此 `setShouldInitBean(false)` 永远改不到已经被固化的那个 `let`。
- **描述**：调用方按 README 的公开 API 列表（`f_bean/README.md:491`）在启动早期调用 `setShouldInitBean(false)` 期望「不做急切实例化」，实际 `initBeansIfNeed()`（`BeanFactory.cj:195-203`）与 `initIfNeed()`（`BeanManager.cj:70`）读的仍是模块加载时拿到的旧值 ⇒ 所有非 `lazy` 单例照旧被创建。反过来，命令行 `--shouldInitBean=false` 是有效的（`Config` 的 `static init` 先于 f_bean 模块初始化执行），这使故障表现为「配置能关、代码关不掉」，排查时极易误判为「配置没生效」。
- **建议**：二选一 —— ① 把 `shouldInitBean` 改成每次现读 `Config.getValue<Bool>(SHOULD_INIT_BEAN_CONF_KEY) ?? true` 的 `func shouldInitBean(): Bool`（配置冷冻在启动期，读开销可忽略，且与 `fountain-baseline.md` §5「配置只在启动读」一致），`setShouldInitBean` 自然生效；② 若确认该 API 无用，则删掉 `setShouldInitBean` 并在 README 去掉，只保留命令行开关（本项目允许破坏性变更，但删公开 API 需用户拍板）。

### [一般][存量] 自定义 `BeanScope` 的生命周期维持路径不可达：实例不缓存、`generateDestroy` 为 `internal`

- **位置**：`f_bean/src/BeanManager.cj:30`（`_singleton` 字段）、`:36`（`_singleton = meta.scope.isSingleton`）、`:57-65`（`generateDestroy` 的 `internal` 可见性）、`:98-118`（`bean` getter 的 `_singleton` 分支）；`f_bean/src/BeanScope.cj:18-21`（注释承诺）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）/ §10（设计合理性）
- **证据**：静态确定 —— `BeanScope.isSingleton`（`BeanScope.cj:38-42`）等价于 `this == BeanScope.singleton`，实现为 `typeInfo` 相等；自定义 scope 的 `typeInfo` 与 `SingletonBeanScope` 不等 ⇒ `_singleton = false` ⇒ `bean` getter 走 `:114-116` 的 `new()`，**每次取值都新建实例、从不写入 `_bean`**。因此自定义 scope 的运行期行为与 `prototype` 完全一致，`BeanScope.cj:19-20`「可以在其它模块定义新的作用范围……受自定义作用范围影响的 bean 生命周期由范围定义模块维持」所描述的扩展点在实现里不存在：外部模块既拿不到被缓存的实例，也无法调用 `generateDestroy`（`:57` 声明为 `internal`，即 `fountain::f_bean` 包内可见，`grep -rn "generateDestroy" --include=*.cj` 显示全部 4 处调用都在 f_bean 包内）。仓内已有调用方按「非 singleton 即 prototype」处理：`f_llm/src/tool/FunctionMediator.cj:109,137` 直接用 `bm.meta.scope.isPrototype` 决定是否 `close`，这也印证了当前实现下自定义 scope 只能落进 prototype 语义。
- **描述**：`@BeanMeta[scope: MyScope]` 目前唯一的可观察效果是「不当作 singleton」，既不会按 scope 缓存，也没有销毁钩子可挂。下游若照着注释实现自定义 scope（例如「每请求一个实例、请求结束统一销毁」），会得到一个每次 `lookup` 都是新对象、且无法登记销毁的容器，属于静默失效。
- **建议**：要么把 `BeanManager` 的实例缓存与销毁入口真正开放给 scope（`bean` 改成委托 `meta.scope` 的 `get(manager)`/`destroy` 两个方法，`BeanScope` 提供默认实现＝现行为），要么把 `BeanScope.cj:18-21` 的注释与 README 改成「仅支持 singleton / prototype，其它 scope 等同 prototype」。前者要改 `BeanScope` 抽象类契约，属设计变更，需用户拍板。

### [一般][存量] Windows 平台上 `ExitCallbacks.atExit` 是空实现 ⇒ bean 的 `destroy`/`close` 永不执行

- **位置**：`f_bean/src/BeanFactory.cj:47`（唯一销毁注册点）；`f_base/src/signal.cj:70-76`（Windows 分支，范围外提示）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §3（空实现）/ §11（资源释放不对称）
- **证据**：静态确定 —— `f_base/src/signal.cj:68-76` 在 `@When[os == "Windows"]` 下把 `atExit` 实现为 `public static func atExit(_: UInt16, _: () -> Unit): Unit {}`，而 f_bean 的 `shutdown` 只通过 `ExitCallbacks.atExit(253, this.shutdown)` 注册，没有第二条销毁路径（全包搜 `doDestroy` 仅 `BeanFactory.cj:51` 一处调用）。fountain 模块本身跨平台（`BeanInitializer`、`BeanFactory` 均无 `@When` 限制）。
- **描述**：Windows 上进程退出时单例 bean 的 `Destroy.destroy()` / `Resource.close()` 从不被调用。表现是文件句柄、socket、连接池不释放（进程退出通常被 OS 兜底，但在「`exit()` 后仍要跑清理逻辑」「测试进程复用」等场景下可观察），且与 Linux/macOS 行为不一致，属平台相关的静默差异。
- **建议**：在 Windows 分支补一个等价机制（`std.env.atExit` 或 fboot 退出前显式调用 `BeanFactory.instance.close()`），或在 `BeanFactory` 构造时按 `@When` 选注册点；至少要在 README 里写明该平台差异。

### [一般][存量] 销毁路径三缺：无顺序保证、无异常隔离、无幂等

- **位置**：`f_bean/src/BeanFactory.cj:49-53`（`shutdown` 遍历 `beans`）；`f_bean/src/BeanManager.cj:48-52`（`doDestroy`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（错误处理缺失、资源不对称）/ §12.1（并发：`beans` 无锁读）
- **证据**：静态确定 —— ① 顺序：`for ((_, m) in beans)` 是 `HashMap` 迭代序，与注册顺序、依赖方向均无关，`BeanManager` 也没有记录「谁依赖谁」，因此 `Resource` 之间不存在「先关被依赖者」的保证；② 异常隔离：`doDestroy` 直接 `generateDestroy(b)()`，未包 `try`，任一 bean 的 `destroy`/`close` 抛异常即中断整轮遍历，后续 bean 全部不销毁（异常还会穿透到 `ExitCallbacks.onExit` 的信号处理路径）；③ 幂等：`doDestroy` 只在 `_bean` 有值时才销毁但**不清空 `_bean`、也不置 destroyed 标记**，若 `shutdown` 与自定义 scope 的销毁（`generateDestroy` 注释所述用法）同时发生，或在信号处理里被调用两次，同一实例会被 `close()` 两次；`shutdown` 本身也不持 `mutex`，与注册/查询路径无同步。
- **描述**：三个问题同源（销毁路径没有契约），合并为一条。后果按顺序：依赖倒序错误 → 关闭已失效依赖时抛异常 → 因无异常隔离，剩下所有 bean 的资源泄漏。
- **建议**：`doDestroy` 改成 `if (let Some(b) <- _bean.load() && _bean.compareAndSwap(Some(b), None))` 保证只销毁一次（`AtomicOptionReference.compareAndSwap` 已可用，见 std.sync 文档）；销毁循环里逐个 `try { ... } catch (e) { log.error(...) }`；`shutdown` 先 `synchronized(mutex)` 取一份 `beans` 快照再遍历（不持锁调用户代码）。顺序问题若要根治需记录注册序（`index` 已有）并按 `index` 逆序销毁，可先做逆序（近似依赖倒序），依赖图另议。
- **备注**：`.autocode/bugs/bug-bean-archived-20261006.md` 里 `BEAN-L2`（`doDestroy` 不清 `_bean`）当时按「设计」判为不成立；本条不是重复报它，而是指出它与「无幂等」叠加后会产生**双重 `close()`**，属后果层面的缺陷。

### [一般][存量] `BeanFactory` 读路径全部无锁，与 `check()` / `doRegister()` 的写路径共用同一批 `HashMap`

- **位置**：读 `f_bean/src/BeanFactory.cj:204-206`（`beanManagers`）、`:236-258`（`getFirstByType`）、`:458-476`（`iteratorByType`）、`:310-312`（`annotationManagers`）；写 `:71-139`（`doRegister`，持 `mutex`）、`:165-193`（`check`，持 `mutex`，会 `beans.remove` 与两张表 `remove`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：待确认 —— 共享路径是确定的：`BeanFactory.instance` 是进程级单例（`:39`），`beans` / `beanTypeMap` / `annotationMap` 是普通 `HashMap`；写全部在 `synchronized(mutex)` 内，读**一处都没有加锁**，也没有「写完成后发布不可变快照」的动作。真正成立需要「写发生时存在并发读者」：`afterRegistered()`（`:154-163`）先把 `registered` 置 true，**再**执行 `check()`，所以 `check()` 修改三张表的整个窗口里，注册虽已关闭、读却已对任意线程开放；`InitializerCollection.doInit`（`f_app/src/Initializer.cj:79-96`）是单线程顺序执行 `initialize()`，但只要某个模块在自己的 `initialize()` 里 `spawn` 一个会 `lookup` 的线程（定时器、消费者、预热任务都属此类），就与该窗口重叠。缺少的证据是：是否存在这样的模块（需读各模块 `initialize()`，超出本模块范围）。按「需实测/待确认」不升为严重。
- **描述**：稳态（`afterRegistered` 返回后）三张表事实上只读，所以这不是常态故障；它是一段「启动期读写竞争 + 无同步」的窗口，且代码里没有任何注释或断言把这个前提固定下来，后续任何人给 `BeanFactory` 加「运行期注销/热注册」能力都会立刻踩到 `HashMap` 并发读写（`check()` 的 `beans.remove` 与读者 `tree.iterator()` 并发还会抛迭代器并发修改）。
- **建议**：① 在 `afterRegistered()` 里把三张表**原子替换成不可变快照**（`beans`/`beanTypeMap`/`annotationMap` 声明为 `AtomicOptionReference` 或加 `volatile` 语义的不可变持有者），写路径「建新表 → 整体替换 → 弃旧表」，读路径完全无锁且不再看到中间态；② 或退一步，在 `check()` 期间持 `mutex` 的同时让读路径也走 `synchronized`（会把锁带进每请求路径，不推荐）；③ 至少补一行注释 + 一个「`afterRegistered` 期间不允许 lookup」的断言/文档约束。

### [一般][存量] `BeanDef` 在「两个 Ignore」时短路 `true`，`count` / `scope` 被静默忽略（`BeanDef(count: Zero)` 恒真）

- **位置**：`f_bean/src/BeanDefCondition.cj:126`
- **来源**：存量（`BEAN-L12` 修复后留下的语义，2026-10-06）
- **判据**：review-checklist §11（契约与实现不符）/ §10
- **证据**：静态确定 —— 该 case 为 `case (IgnoreType, IgnoreCond) => return true`，在进入 `on(factory, typeInfo)` 之前直接返回，因此 `count`、`scope` 两个具名参数在默认 `beanType` / `beanName` 下**永不参与判定**。`f_bean/src/test/bean_def_condition_test.cj:65-71` 已按现状钉住：`BeanDef(count: BeanDefCount.Zero).on(factory)` 断言为 `true`。
- **描述**：`BeanDef(count: Zero)` 的语义承诺是「没有任何 bean 定义时为真」，用于「缺省兜底 bean 只在没有其它实现时注册」这一经典场景。当前实现里它恒为 `true`，兜底 bean 在任何情况下都会被注册，与业务实现同时存在（例如两个 `@Bean` 都实现同一接口，`lookupList` 里多出一个默认实现）。同理 `scope` 过滤在默认参数下失效。
- **建议**：把 `:126` 的短路条件收紧为「两个 Ignore **且** `count == AtLeastOne`（默认值）**且** `scope.isNone()`」，即只有「完全没指定任何条件」才短路；其余组合走 `_` 分支的真实筛选（`TypeInfo.of<Object>()` 桶已被证明可用）。若作者确认「`count`/`scope` 在 Ignore 类型下本就无意义」，则在 README 中显式写明，并让 `BeanDef(count: Zero)` 在构造处就报错或加 `@Deprecated`，不要让它静默恒真。

### [一般][存量] `@BeanParam` 的短写形式不可用，构造器白名单与 `StringCond` 实际 case 名不符

- **位置**：`f_bean/src/macros/BeanParam.cj:37-42`（`attr.size == 3` 却访问 `attr[3]`）；`:27` 与 `:38`（`'prefix'` / `'wildcard'` 小写）；`:36-42`（白名单缺 `Contains` / `In`）；字符串简写与集合形参的冲突见 `f_bean/src/macros/Constructor.cj` 容器分支（`f_bean/src/lookup.cj:44-89` 只提供 `(StringCond)` 版本）
- **来源**：存量（`git blame -L 22,47 -- f_bean/src/macros/BeanParam.cj` 全部落在 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（边界差一 / 契约与实现不符）/ §2（同一白名单字面量在两处复制）
- **证据**：静态确定 —— ① `StringCond` 的构造器为 `Exactly | Prefix | Suffix | Wildcard | Regexp | Contains | In`（`f_bean/src/BeanStringCondition.cj:36-60`）；② `Exactly('x')` 的 token 序列是 `IDENTIFIER, LPAREN, STRING_LITERAL, RPAREN` 共 **4** 个，因此 `:37` 的 `attr.size == 3` 永不成立；③ 若它真的成立，紧随其后的 `attr[3].kind` 就越界。两条路都走不通：`case _` 分支必然执行，`diagReport(ERROR, '… must be a String or constructor of fountain.bean.StringCond')` 打断编译。
- **描述**：文档里的写法 `@BeanParam(Exactly('x'))`（`README` 称「本宏的属性是表示 StringCond 枚举实例的 Tokens」）一律报错。带限定名的 `StringCond.Prefix(...)` / `StringCond.Wildcard(...)` 也被拒——`:27` 处白名单写的是小写 `'prefix'` / `'wildcard'`，与枚举 case 名大小写不符；`StringCond.Contains(...)` / `StringCond.In(...)` 两个合法 case 完全不在白名单里。另外 `Constructor.cj` 的容器映射（`ArrayList`→`lookupList`、`HashSet`→`lookupHashSet`、`HashMap`→`lookupHashMap`）只有 `(StringCond)` 重载，字符串简写落到集合/Map 形参必生成不存在的重载 ⇒ 集合/Map 形参用字符串简写必编译失败，属同一根因。仓内对 `@BeanParam` 零使用，所以这条路径从未被编译过。
- **建议**：`:37` 的 `attr.size == 3` 改为 `4`；把 `:27` 与 `:38` 的两份白名单抽成一个 `const` 数组，值改为 `'Exactly'|'Prefix'|'Suffix'|'Wildcard'|'Regexp'|'Contains'|'In'`；`let first = attr[0]` 之前补 `attr.isEmpty()` 判断（`@BeanParam` 不带属性时现在直接越界，宏崩溃而不是 `diagReport`）；字符串简写要么补 `lookupList/lookupHashSet/lookupHashMap` 的 `String` 重载，要么在宏里对集合/Map 形参显式 `diagReport`。

### [一般][存量] `@Constructor` 的静态工厂分支条件写反：`isGenericDecl` 应为 `!isGenericDecl`

- **位置**：`f_bean/src/macros/Constructor.cj:44`
- **来源**：存量（`git blame -L 44,44` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `Decl.isGenericDecl` 的语义是「是否是一个泛型节点」（`std/ast/ast_package_api/ast_package_classes.md:2686-2692`），即「带类型形参」。而同一个 `match` 的兜底分支错误文案是 `'… must be a public constructor or public static func without generic parameter'`（`:58-60`），意图明确是**排除**泛型。两条互斥证据足以判定条件方向相反。
- **描述**：`README:454-455` 声明「`@Constructor` 修饰的构造函数或静态函数是 bean 的初始化函数」。实际上：`public static func create(): Foo`（无类型形参）落进 `case _` → 编译期报「必须是公共构造函数或无泛型参数的公共静态函数」；反过来，带 `<T>` 的静态函数被接受，随后 `argTokens` 生成 `$beanType.create(args)`（不补类型实参），必然类型检查失败。仓内 `@Constructor` 只有 `f_bean/src/test/obj_test.cj:30`、`constructor_param_test.cj:43` 两处，都是 `init`，该分支零覆盖。
- **建议**：改为 `x.isStatic() && !x.isGenericDecl`，并补一个「公共静态工厂 + 无泛型」的最小用例（顺带覆盖 `setItem('constructor', name)` 分支）。另外 `:28-34` 的 `try { parseDecl(input) } catch (_: ParseASTException) { … } catch (e: Exception) { throw e }` 里最后一个 `catch` 只是原样重抛，无任何效果，可删（§1）。

### [一般][存量] `@Value` 在 `Array` / `DateTime` / `Duration` 形参上生成不合法或不类型检查的代码

- **位置**：`f_bean/src/macros/Value.cj:20`（`delim` 默认值是 `` `comma` `` token）、`:47-63`（DateTime / Duration 无 `default` 时不补 `??`）、`:120-130`（Array 分支完全不引用 `default`）、`:22-38`（未知属性名静默忽略，`attr[i+2]` 无边界检查）
- **来源**：存量（`git blame -L 18,46 -- f_bean/src/macros/Value.cj` → 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）/ §3（静默忽略）
- **证据**：静态确定 —— 对照 `f_config/src/Config.cj` 的实际签名：`getString(key): ?String`（`:186`）、`getDateTime(key, format!): ?DateTime`（`:232`）、`getDuration(key): ?Duration`（`:244`）、`getStringArray(key, delim!: String = ',')`（`:210`）。由此三条独立后果都可静态判定：
  1. `:20` 把 `delim` 初始化为 `` `comma` ``，最终拼成 `Config.getStringArray($name, delim: $delim)`（`:121`）。无论 `` `comma` `` 展开成逗号标点 token（生成 `delim: ,`，语法错）还是标识符 token（生成 `delim: comma`，未定义标识符），都不是 `String` 字面量 `','` ⇒ **任何 `Array<T>` 形参不显式写 `delim:` 都无法编译**。
  2. `:47-57` / `:58-63`：`default.size == 0` 时直接产出 `Config.getDateTime(...)` / `Config.getDuration(...)`，类型是 `?DateTime` / `?Duration`，却被 `let x = ` 赋给非 Option 形参 ⇒ **`DateTime` / `Duration` 形参必须给 `default` 才能编译**，而 `README` 把 `default` 写成可选。
  3. `:120-130` 的 `Array` 四个 case 都不引用 `default` ⇒ 数组形参上的 `default:` **被静默忽略**，配置缺失时得到空数组而不是默认值。
  另外 `:22-38` 的解析循环对无法识别的键只做 `i++`（`case _ => i++`），把 `deafult:` 这类拼写错误静默吞掉；`@Value[name]`（漏写值）时 `attr[i + 2]` 越界，宏抛越界异常而非 `diagReport`。
- **描述**：`@Value` 是 README 明确文档化的公开宏，四种属性（`name` / `default` / `dateFormat` / `delim`）与三类形参（标量 / 数组 / Option）交叉后，只有「标量 + String + 给全属性」这一格可用。仓内对 `@Value` 零使用、零测试，缺陷长期不可见。
- **建议**：`delim` 默认值改 `quote(',')`；非 Option 的 `DateTime` / `Duration` 在 `default.size == 0` 时 `diagReport(ERROR, '… requires a default value')`（不许静默生成 `?T`）；`Array` 分支要么支持 `default`（`getStringArray(...)` 后判空回退），要么显式报「数组形参不支持 default」；属性解析改成「匹配键 → 校验 `:` 与值存在 → 取 `attr[i+2]`」，未知键 `diagReport`。
- **待确认（次要）**：`:47-57` 的 `if (dateFormat.size > 0) { A } else { B } + if (...) { … }` 中，`+` 与前面的 if 表达式如何结合，取决于 `if` 表达式能否作二元运算的左操作数。若按「`+` 只接到 else 分支」解析，则 `dateFormat` 与 `default` 同时给出时 `default` 会被丢掉（generated code 又是 `?DateTime`）。用 `cjc --debug-macro`（或一个 `@Value[dateFormat:…, default:…] x: DateTime` 的最小用例）确认即可定论。

### [一般][存量] `@Configuration` 对不满足条件的 `@BeanInit` 成员静默跳过，无任何编译期提示

- **位置**：`f_bean/src/macros/Configuration.cj:41-48`（两个 `case f: FuncDecl where …` 之后是 `case _ => break`）；`:22`（`ClassDecl(input)` 直接构造）
- **来源**：存量（`git blame -L 33,52` → 2026-10-02）
- **判据**：review-checklist §3（空实现 / 静默失效）/ §11（错误处理缺失）
- **证据**：静态确定 —— 循环只在 `isBeanInit && isStatic/isPublic/参数为空` 全成立时追加注册 token，其余情形走 `case _ => break`，既不 `diagReport` 也不生成任何东西。宏的返回 token 里没有该函数，编译完全通过。
- **描述**：`@BeanInit private func init1()`、`@BeanInit public func init1(x: Int64)`、`@BeanInit` 打在属性上，三种都会「编译通过但 bean 不存在」。README 只说「公共成员函数」，用户写错可见性或漏加无参约束时，得到的现象是启动后 `lookup<X>()` 抛 `BeanException`，回溯不到宏。
- **建议**：把 `case _ => break` 拆成「`isBeanInit` 为真但类型/可见性/形参不满足 → `diagReport(ERROR, '… must be a public member function without parameter')`」，`isBeanInit` 为假才静默跳过。`ClassDecl(input)` 外层包 `try`/`catch (e: ASTException)` 转 `diagReport`，与 `Bean.cj:45-51` 的处理方式一致（现在非类输入直接抛解析异常，栈里看不到是哪个 `@Configuration`）。

### [一般][存量] `bean_test.cj` 唯一的用例零断言，`@Constructor` 非集合形参注入链路没有任何守护

- **位置**：`f_bean/src/test/bean_test.cj:23-27`（`test()`）；被守护的夹具 `f_bean/src/test/obj_test.cj:21-35`（`A` / `B`）；生成侧 `f_bean/src/macros/Constructor.cj`（非集合形参 → `lookup<A>()`）
- **来源**：存量（`git blame -L 23,27 -- f_bean/src/test/bean_test.cj` → `4be871f2fd` 2026-10-02，仅换行符统一）
- **判据**：review-checklist §3（空实现：契约承诺有行为、断言为空）/ §10（可测试性）/ §11（契约未验证）
- **证据**：静态确定 —— `getFirst<B>()` 返回 `?B`，用例只 `println(b)`，既不断言 `isSome()`，也不读 `b.getOrThrow().a`，更不校验 `toString()` 文本。把 `B` 的 `@Bean` 注解删掉（b 变 `None`）、把 `@Constructor` 换到另一个形参、或让 `a` 注入成别的 `A` 实例，本用例都照样绿（删注解时输出 `None`，构造失败时才抛异常）。全仓 `B` 只在此处被查询一次（`grep -rn "getFirst<B>" f_bean/src` 仅 `bean_test.cj:25`），没有任何第二道防线。
- **描述**：`obj_test.cj` 是仓内唯一覆盖「`@Constructor` + 单个非集合形参」的夹具（集合/Option 形态由 `constructor_param_test` 覆盖，静态工厂分支见上文 `@Constructor` 条），而它唯一的消费者是一条只打印的用例。`@Constructor` 的 `lookup<A>()` 生成路径因此处于「能编译即视为通过」的状态：注入的是不是**那一个** `A`、`B.a` 是否可空，都没有断言。
- **建议**：补三条断言 —— `@Assert(b.isSome(), true)`、`@Assert(b.getOrThrow().a is A, true)`（或与 `lookup<A>()` 的返回值 `refEq`）、`@Assert(b.getOrThrow().toString(), 'B(A)')`；用例名改成 `testConstructorInjection`，避免与模块名同名却什么也不验。

### [一般][存量] `testEagerBeanCreatedAtMostOnce` 从未走到「启动期预初始化」路径，实质与 `testSingletonScopeSemantics` 重复

- **位置**：`f_bean/src/test/bean_scope_test.cj:86-95`；被依赖的实现 `f_bean/src/BeanManager.cj:69-76`（`initIfNeed`）、`f_bean/src/BeanFactory.cj:154-163`（`afterRegistered`）、`:195-203`（`initBeansIfNeed`）
- **来源**：存量（`git blame -L 86,95` → `04559fc2c` 2026-10-05，`BEAN-5` 补用例时新增）
- **判据**：review-checklist §2（语义相同的重复用例）/ §10（可测试性）/ §11（语义与命名不符）
- **证据**：静态确定 —— 全仓 `afterRegistered()` 的调用点只有 `f_bean/src/BeanInitializer.cj:29`（`initialize()` 里），而测试进程没有任何代码调用 `InitializerCollection.initialize()` 或 `afterRegistered()`（`grep -rn "afterRegistered\|InitializerCollection.initialize" f_bean/src/test` 零命中）；同包 `bean_def_condition_test.cj:45,110` 的注释已把这一点写成前提：「测试进程**从不调用** `BeanFactory.afterRegistered()`」。因此 `initBeansIfNeed()` 不执行，`@BeanMeta[lazy: false]` 对 `ScopeEagerBean` 在本进程内不产生任何效果，实例是 `getFirst` 时按单例懒建的。
- **描述**：用例名声明验证「eager bean 最多创建一次」，实际验证的是「单例缓存命中」——后半段 `@Assert(refEq(p1, p2), true)` 与 `testSingletonScopeSemantics`（`:48-52`）判定同一件事；`@Assert(afterFirst >= 1, true)` 也无法区分 1 次与 N 次构造（若 `initIfNeed` 在别处被多调一次，`created` 变 2 仍通过）。`lazy: false` 与 `afterRegistered → initBeansIfNeed → initIfNeed` 这条链路在整包测试里只有 `testInitIfNeedJudgement` 直接调 `initIfNeed` 覆盖了一段，`afterRegistered` 本身零覆盖。
- **建议**：把断言换成确定值 `@Assert(afterFirst, 1)`；若要真验启动期路径，放一个独立用例（或 `cjpm test --filter` 单跑）显式 `BeanFactory.instance.afterRegistered()` 后再断言 `created.load() == 1` —— 注意 `afterRegistered` 会执行 `check()` 并丢弃条件 bean，必须与其它用例隔离进程。否则把用例改名为 `testSingletonCacheReuse`，避免给出「eager 已验证」的错觉。

### [一般][存量] `initIfNeed()` 无幂等保护：只要条件成立就覆盖已有单例，重复调用会丢实例且不销毁

- **位置**：`f_bean/src/BeanManager.cj:69-76`；可重复触发的入口 `f_bean/src/BeanFactory.cj:154-163`（`afterRegistered` 是 `public` 且每次都无守卫地调 `check()` + `initBeansIfNeed()`）
- **来源**：存量（`git blame -L 69,76` 早于本轮全部提交；`afterRegistered` 同）
- **判据**：review-checklist §11（资源释放不对称 / 缺幂等）/ §12.1（检查-然后-写入：`_bean.load()` 未参与判定）
- **证据**：静态确定（机制）—— `if (shouldInitBean && !meta.lazy && _singleton) { _bean.store(new()); true }`，判断条件里没有「`_bean` 已存在则跳过」；`_bean` 是 `AtomicOptionReference`，`store` 直接覆盖。销毁只在进程退出时由 `doDestroy` 对**当前** `_bean` 执行一次，被覆盖的旧实例既不 `destroy` 也不 `close`。待确认（触发路径）—— 正常启动只调一次 `afterRegistered()`，需确认是否有下游（fboot 引导、测试、热重启）重复调用。
- **描述**：`bean_scope_test.cj:81` 就在同一进程里对同一个 `eagerMgr` 调了两次 `initIfNeed()`，第二次把第一次存的实例换掉——用例因为只比较返回值而没有察觉。真实后果有两条：① 重复 `afterRegistered()` 会把**所有**非 lazy 单例重建一遍，`PostConstruct` 已初始化的状态丢失、`Resource` 句柄泄漏；② 若某个 eager 单例在 `afterRegistered()` 之前已被 `lookup` 取走并注入到别的 bean，之后 `initIfNeed` 覆盖容器内的引用，同一类型在进程里出现两个活实例，注入方持有旧的那个。
- **建议**：`initIfNeed` 加存在性判断 —— `if (let Some(_) <- _bean.load()) { false } else { _bean.store(new()); true }`；`afterRegistered` 头部用 `if (!registered.compareAndSwap(false, true)) { return }` 做一次性守卫（现在是无条件 `registered.store(true)`，没有「已初始化」判定）。注意本条与「销毁路径三缺」③ 不是同一条：那条针对 `doDestroy` 的幂等，本条针对 `initIfNeed` 的重复构造。

### [轻微][存量] `doRegister` 的 `visited` 未区分类节点与注解节点，极端组合下会少注册一张表

- **位置**：`f_bean/src/BeanFactory.cj:84`（`let visited = HashSet<TypeInfo>()`）、`:90-93`（去重判断）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界）/ §12.1（不是并发，是同一 `TypeInfo` 承担两种语义）
- **证据**：待确认 —— `visited` 的键是裸 `TypeInfo`，而队列里同一个 `TypeInfo` 可能是 `ClassType`（进 `beanTypeMap`）也可能是 `AnnotationType`（进 `annotationMap`）。只有当「某个类既被注册为 bean、又被别的 bean 当作注解使用」时两者才会撞车，届时后入队的节点被 `continue` 跳过，对应表缺一条。仓库内当前没有「`@Bean` + `@Annotation` 同类」的用法（`grep -rn "BeanInit\|@Annotation"` 结果里无此类组合），故不定级为缺陷。
- **建议**：把去重键改成 `(isClass, klass)` 二元组（`HashSet<(Bool, TypeInfo)>`），或在 `visited` 里存两个集合分别判，代价是每节点一次元组哈希，注册期开销可忽略。

### [轻微][存量] `BeanMeta.compare` 在「仅一方 name 为空」时返回 `EQ`

- **位置**：`f_bean/src/BeanMeta.cj:41-42`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界差一/语义与命名不符）
- **证据**：静态确定 —— `case EQ where !(this.name.isEmpty() || meta.name.isEmpty()) => this.name.compare(meta.name)`：订单相等时，**只要有一方 name 为空**就落到 `case x => x`，返回 `EQ`。即 `BeanMeta(order: 5, name: '')` 与 `BeanMeta(order: 5, name: 'abc')` 判为相等。`BeanManager.compare`（`BeanManager.cj:92-97`）在 `EQ` 时会再比 `_name`，而 `_name` 由 `beanType_${index}` 兜底、恒非空，所以容器内部不受影响；受影响的是直接使用 `TreeSet<BeanMeta>` / `BeanMeta.compare` 的调用方（`BeanMeta` 是 public 且 `Comparable`）。
- **建议**：把条件去掉，直接 `this.name.compare(meta.name)`（空串自然排在前面），或改成 `if (this.name.isEmpty() != meta.name.isEmpty()) { 空者为 LT } else { this.name.compare(meta.name) }`。

### [轻微][存量] 通配/正则 memo 表无容量上限，键来自公开 API 入参

- **位置**：`f_bean/src/BeanStringCondition.cj:22-23`（两个 `ConcurrentHashMap`）、`:81-82`（`computeIfAbsent`）
- **来源**：存量（`BEAN-4` 修复时引入）
- **判据**：review-checklist §5（缓存键无界）
- **证据**：静态确定（无容量/TTL/淘汰）；待确认（是否存在按请求构造 `Wildcard`/`Regexp` 的下游）—— 仓内 `StringCond.Wildcard(...)` / `StringCond.Regexp(...)` 零命中，实际键空间只是注解里声明的条件数（有界）。
- **描述**：`StringCond` 是 public 枚举，`lookup<T>(cond: Regexp(x))` 允许把任意字符串当键写入全局 `REGEX_CACHE`。只要有一个下游按用户输入构造条件（例如「按 URL 模式匹配 bean」），该表就是无界增长且永不清理，GC 后条目仍在。
- **建议**：给两张表加上限（超过 N 条时 `clear()` 或按 LRU 淘汰），或把缓存改成「按 `StringCond` 实例持有编译结果」（枚举值本身在代码里声明，生命周期天然有界）；至少在 README 注明「`cond` 的 pattern 必须是代码内常量」。

### [轻微][存量] 注解查询三件套的过滤谓词与遍历结构完全重复

- **位置**：`f_bean/src/BeanFactory.cj:326`（`getFirstByAnnotation`）、`:345`（`getListByAnnotation`）、`:366`（`getMapByAnnotation`）
- **来源**：存量（`BEAN-L6` 补充查询入口时复制而来）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— 三处的 `for (m in annotationManagers(annotation) where m.beanType.isSubtypeOf(requiredType) && cond.on(m.name))`、`TypeInfo.of<T>()` 求值、`beanLog('…ByAnnotation', …)` 一字不差，差异只有末尾收集动作（`return m.bean as T` / `list.add` / `map[m.name] = b`）。三处都没有 `BEAN-L10` 那种「反抽象换性能」的注释依据。
- **建议**：抽一个 `private func annotationIterator<T>(annotation: TypeInfo, cond: StringCond): Iterator<BeanManager>` 承载谓词（顺带把 `requiredType` 求值提到循环外），三个入口各自只写收集；若担心闭包开销，可返回 `Iterator` 后由调用方循环、谓词内联在迭代器构造函数里（与 `iteratorByType` 的写法一致）。

### [轻微][存量] `check()` 在持有 `mutex` 期间求值用户自定义条件并打 debug 日志

- **位置**：`f_bean/src/BeanFactory.cj:165`（`synchronized(mutex)`）、`:167`（`m.on(this)`）、`:169`（`log.debug`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.2（锁内调用外部回调 / 锁内日志）
- **证据**：静态确定 —— 临界区包含：遍历全部 bean、对每个 bean 调用 `BeanCondition.on(factory)`（`BeanCondition` 是 public 接口，下游可实现任意逻辑，包括再次 `lookup` 或 `Config` 访问）、以及每次丢弃的 `log.debug`。当前只在 `afterRegistered()` 里跑一次，`BeanDef`/`CondCond` 的实现也不阻塞，因此只是「结构上把用户代码放进了锁里」。
- **建议**：`check()` 第一阶段在锁内只做「取一份 `beans` 快照」并释放锁，第二阶段在锁外求值条件、算出 `discarded`，第三阶段再进锁做三张表的删除；这样既缩短持锁时间，也避免自定义条件在锁内重入。

### [轻微][存量] `BeanDefType` 的类型名写错时抛 `InfoNotFoundException`，启动期错误定位困难

- **位置**：`f_bean/src/BeanDefCondition.cj:88-101`（`TypeInfos.get(t)` 共 5 处）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（错误处理/可诊断性）
- **证据**：静态确定 —— `TypeInfos.get(qualifiedName)` 未命中抛 `InfoNotFoundException`（见 `f_base/src/TypeInfos_test.cj:37` 的 `@ExpectThrows[InfoNotFoundException]`），而 `BeanDef` 的 `beanType`/`beanName` 来自注解字面量，拼错类型名是常见手误；异常在 `check()` 里抛出，栈里只有 `BeanDefType.on`，看不到「是哪个 bean 的 `@BeanMeta` 配错了」。
- **建议**：在 `BeanDef.on` 入口预解析一次类型名并包一层 `try`，转抛 `BeanException('bean condition type "${t}" not found, declared on ...')`；顺带把 `TypeInfos.get(t)` 从「每元素一次」提到 `on(factory)` 里只求一次（见待验证假设 #3）。

### [轻微][存量] `lookupLabels` / `lookupWeights` 用容器键去重，键冲突时静默丢 bean

- **位置**：`f_bean/src/lookup.cj:98`（`map[bean.label] = bean`）、`:141`（`map[w] = bean`，`w` 是**累计**权重）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定（机制）—— README `:110` / `:124` 都写「获取类型是指定泛型实参的**全部** bean」，实现是逐条 `put`，键相同即覆盖；`lookupWeights` 的键是累加值（`:132-141`），任一 bean 权重为 0（或负）就与前一元素撞键，返回条数 < bean 数。触发是否发生取决于实际权重/标签取值（待确认），但「会覆盖」这一点无需实验。
- **建议**：`lookupWeights` 改为 `TreeMap<W, ArrayList<T>>`，或在 `contains` 命中时给 `diagReport`/日志告警；`lookupLabels` 至少在 README 注明「label 必须唯一，重复时后者覆盖」。若坚持一 bean 一键，则把返回值语义写成「按 label 索引的视图」，不要写「全部 bean」。

### [轻微][存量] `lookupLabelOption(cond, label)` 为取第一个而全量物化并线性扫描

- **位置**：`f_bean/src/lookup.cj:119-124`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §6.4（只判存在却全量扫描）
- **证据**：静态确定（复杂度）—— `lookupList<T>(cond)` 会构造完整 `ArrayList<T>`（并实例化全部命中的 prototype bean），随后 `for (bean in …) { return bean }` 只取第一个；`bean.label` 在 `where` 与循环体各求值一次。同文件 `lookupHashSet`（`:57-66`）与 `lookupTreeSet`（`:73-81`）已按 `BEAN-L5` 注释「直接向目标集合填充、不再物化中间 ArrayList」，此处未跟进。
- **建议**：改走 `BeanFactory.instance.iterator<T>(cond)`，循环内 `if (let b: T <- m.bean) { if (b.label == label) { return b } }`，命中即返回、`label` 只取一次。是否值得改取决于该入口的调用频次（未测量，见「待验证假设」）。

### [轻微][存量] 公开 API 表面不一致：`lookupOptionLable` 拼写错误、缺 `lookupLabelOption(name:, label:)` 重载

- **位置**：`f_bean/src/lookup.cj:116`（`lookupOptionLable`）；对照 `:102-124` 的 overload 家族
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与命名不符）/ §10（可维护性）
- **证据**：静态确定 —— 全仓 `grep -rn "lookupOptionLable"` 只命中定义处，无任何调用者；`README:491` 已把这个错名当作公开 API 收录。`lookupLabel`（`:105`）与 `lookupLabelOption`（`:113`/`:119`）都有 `(name, …)` 形态，唯独「按名字 + label 取 Option」必须用错名才写得出。
- **建议**：新增正确名 `lookupLabelOption<L, T>(name: String, label: L)`，旧名保留为 `@Deprecated` 转发（一个函数体即可）；README 同步。属破坏性变更，需用户拍板后再删旧名。

### [轻微][存量] `Value.cj` / `Constructor.cj` 有大段「只改索引」的重复分支

- **位置**：`f_bean/src/macros/Value.cj:64-91`（`Option<T>`）与 `:92-119`（`?T`）—— 两块逐行相同，只有 `x[2]` vs `x[1]`；`:47-57` / `:70-80` / `:98-108` —— DateTime 拼装逻辑出现 3 次（加 `:120-130` 的 Array-DateTime 共 4 处）；`f_bean/src/macros/Constructor.cj:87-121` —— 有 `cond` / 无 `cond` 两个分支里 `ArrayList|List`、`Array`、`HashSet|Set`、`HashMap|Map`、`_` 五种形态各写一遍
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §2（只改类型名 / 换控制流的重复）
- **证据**：静态确定 —— 把 8 条分支压成「输入→输出」摘要，差异只有（a）类型实参 token 区间（`?T` 从 `[1..]`、`Option<T>` 从 `[2..size-1]`）、（b）是否追加 `?? default`。无业务语义差异。
- **描述**：这是「缺陷放大器」：`@Value` 的三个问题分别落在 3~4 份副本里，修一处必须同时改另一份，且现在已经出现同类分支行为不一致（DateTime 的 `+` 位置与 Duration 不同，见 `@Value` 条「待确认」）。
- **建议**：先算 `elem: Tokens` 与 `getter: String`（一处 switch），再统一拼 `getter(...)` + 可选 `?? default`；`Constructor.cj` 把 cond/no-cond 改成 `cond: ?Tokens` 后只走一条 `match (typeName)`。注意别把 `Option<String>`（`?? ''` 强制非空）的边界差异抹掉——那一条要显式保留。

### [轻微][存量] `imports.cj` 有 3 个未使用的 `internal import` 与 2 组重复导入

- **位置**：`f_bean/src/imports.cj:20`（`internal import std.convert.*`，与 `:30` 的 `public import` 同一包重复）、`:21`（`std.env.*`）、`:22`（`std.process.Process`）、`:27` 与 `:34`（`fountain::f_data.*` 重复）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `internal import` 的作用域是「当前包及子包」（`cangjie_docs/.../package/import.md:293-294`），因此在 `f_bean/src` 全包搜索：`Process` 无命中、`getVariable|getCommandLine|std.env` 无命中、`.parse(|toInt|toFloat|Parsable` 仅命中 `macros/Value.cj` 引号内的 token 文本（那属于另一个包 `fountain::f_bean.macros`，不受本文件影响）。`std.convert.*` / `f_data.*` 各被导入两次，`public` 已覆盖 `internal`，前者无额外语义。
- **建议**：删 `:20`、`:21`、`:22`；`f_data.*` 只留 `:34` 的 `public` 一行。`shouldInitBean` / `setShouldInitBean` 的语义问题已单列，不在此重复。

### [轻微][存量] `PostConstruct` 对 `FactoryBean` 的语义错位：回调打在工厂对象上，真正的 bean 不会被回调

- **位置**：`f_bean/src/PostConstructor.cj:18-20`（契约）+ 调用点 `f_bean/src/BeanManager.cj:77-86`（`new()` 里先 `postConstruct()` 再 `FactoryBean.get()`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `new()` 的顺序是 `let o = creator()` → `if (let x: PostConstruct <- o) { x.postConstruct() }` → `match (o) { case x: FactoryBean => x.get() }`。README 的 `FactoryBean` 段写明「调用本接口的 get 函数返回的对象才是真正的 bean」，因此对 `FactoryBean` 实现类而言：`postConstruct` 跑在**工厂**上（工厂本身不是注册的 bean），而 `get()` 返回的真实 bean 即使实现了 `PostConstruct` 也永远不会被调用。
- **描述**：`@Bean` + `FactoryBean` + 需要后置初始化的产物是常见组合（连接池、代理对象）。当前实现让「后置初始化」落在错误的对象上：工厂可能根本没有初始化逻辑，真正需要在依赖注入完成后执行初始化的产物则被跳过。非 singleton 路径（`:115`）同样走 `new()`，问题一致。
- **建议**：把回调收到最终产物上——`let bean = match (o) { case x: FactoryBean => x.get(); case _ => o }`，再对 `bean` 判 `PostConstruct`/`Destroy`；工厂自身若也需要回调，单列 `postConstruct` 于 `creator()` 之后、`get()` 之前。若确认「回调工厂」是有意设计，请在 README 显式写明这条差异。

### [轻微][存量] 测试把已知缺陷固化成期望值，形成「修复即红」的陷阱

- **位置**：`f_bean/src/test/bean_def_condition_test.cj:64-71`（`@Assert(BeanDef(count: BeanDefCount.Zero).on(factory), true)` 等 5 条）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（与规格冲突）/ §10（可测试性）
- **证据**：静态确定 —— 文件头注释（`:24-31`）明确写「现实现一律判真 … 本文件按**现状**钉住，不美化」，而 `BeanDef(count: Zero)` 的文档语义是「没有 bean 定义时为真」（`README:387-405`），测试进程里存在大量 bean，正确期望应为 `false`。
- **描述**：`BeanDefCondition.cj:126` 的短路已被判为缺陷。一旦按建议收紧条件，这两条（`BeanDef(count: Zero)` 与 `BeanDef(…, count: Zero)`）立即失败，而失败信息看起来像「新代码破坏了既有契约」。这类「按现状钉住」的断言应在测试名/门禁里显式标记。
- **建议**：改成正确期望并加 `@Ignore`（或框架的禁用属性）+ 注释指向缺陷编号；或把这些断言移进独立的 `bean_def_condition_knownbug_test.cj`，修完即删。

### [轻微][存量] 基准代码放进单元测试（三处同根因合并），且断言与耗时无关

- **位置**：`f_bean/src/test/bean_getfirst_test.cj:94-114`（30 万次 `getFirst`）；`f_bean/src/test/bean_iterator_test.cj:83-154`（6 万次 × 29 轮，`@Assert(seen, n * 29)`）；`f_bean/src/test/bean_string_cond_test.cj:62-88`（30 万 × 2 次 `on`）
- **来源**：存量（`bean_getfirst_test`/`bean_iterator_test` 见 `7e08b4b2e` 前后；`bean_string_cond_test` `git blame -L 62,88` → `e9ed1e9cb` 2026-10-05）
- **判据**：review-checklist §10（可维护性）/ `fountain-baseline.md` §8（基准必须 `-O2`）
- **证据**：静态确定（迭代次数与断言内容）；对 CI 时长的实际影响需实测。
- **描述**：三个文件的 `testBenchmark*` 只 `println` 耗时、断言的是命中次数（`ok == n` / `n * 29` / `n * 2`），所以既不守护性能也不守护行为；`cjpm test` 默认 `-O0`，打印出的 ns/op 不能当作跨版本对照基线。`bean_iterator_test.cj:153` 还把总次数硬编码成 `n * 29`，调整轮数就得同步改魔数（当前 29 = 2+8+2+8+1+8，与代码一致，但极脆）；`bean_string_cond_test` 的 `ms1` 为 0 时 `ns/op` 打印 0，说明该数字本身也不做自检。三处为同一根因（基准混进单测），合并为一条并列全位置。
- **建议**：计时部分整体移到 `bench/`（`cjpm bench -O2`）或整段 `@Ignore`；单测里保留行为断言（`hits == n + warmup` 之类），把 `n` 降到千级，`n * 29` 这类总次数改由轮数常量推导。

### [轻微][存量] `bean_scope_test` 的「重复调用结果稳定」断言含自证分支，配置一变即恒真

- **位置**：`f_bean/src/test/bean_scope_test.cj:80-81`
- **来源**：存量（`git blame -L 80,81` → `04559fc2c` 2026-10-05）
- **判据**：review-checklist §3（空断言）/ §11（判据与断言不符）
- **证据**：静态确定 —— `@Assert(inited == eagerMgr.initIfNeed() || !inited, true)`：当 `inited == false` 时左项为 `false == 第二次返回值`，右项 `!inited` 恒 `true`，整个表达式恒真。`inited` 取 `false` 只需要 `shouldInitBean` 为假（`f_bean/src/imports.cj:40` 从 `Config` 读，默认 `true`，命令行可改），此时该用例对 `initIfNeed` 的重复调用**不做任何校验**。
- **描述**：同一用例的核心语义（「非 lazy 单例的 `initIfNeed` 返回 true 且可重复调用」）被一个 `||` 兜底成了「要么真校验、要么静默通过」。而它本来要守的正是 `initIfNeed` 的行为，两者叠加使该风险点完全无守护。另外 `:82-83` 的 `refEq(x, eagerMgr.bean)` 对单例恒真，也不构成对第二次 `initIfNeed` 的检查。
- **建议**：改成 `@Assert(inited, true)`（测试进程默认 `shouldInitBean == true`，成立；若担心配置，用例开头显式断言 `shouldInitBean` 的前提而不是把它降级成恒真）；再补一句 `let first = eagerMgr.bean` 后 `@Assert(refEq(first, eagerMgr.bean), true)`，把「第二次调用不替换实例」写成真断言（配合 `initIfNeed` 幂等修复）。

### [轻微][存量] `constructor_param_test` 只断言各形态的 `size`，Map 的键契约与元素身份均未验证

- **位置**：`f_bean/src/test/constructor_param_test.cj:58-70`；键的写入侧 `f_bean/src/BeanFactory.cj:295-304`（`map[m.name] = b`）
- **来源**：存量（`git blame -L 55,71` → `7e08b4b2e` 2026-10-05）
- **判据**：review-checklist §10（可测试性）/ §11（契约未验证）
- **证据**：静态确定 —— 全部断言形如 `@Assert(shapes.hashMap.size, 1)`。`lookupHashMap` 的契约是「bean 名 → bean」（`BeanFactory.cj:300`、`README`），而把键换成常量、或让六个形态注入**不同**的 `CtorParamItem` 实例，`size` 仍然全是 1。宏侧的 `List` 形态（`Constructor.cj` 的 `ArrayList|List` 共用分支）在仓内无任何形参覆盖。
- **建议**：对 `hashMap` 做一次 `for ((k, v) in shapes.hashMap)`，断言 `k` 等于 `BeanFactory.instance.iterator<CtorParamItem>().next().getOrThrow().name`；用 `refEq` 断言 `list[0]`、`arr[0]`、`hashSet` 元素、`map` 值、`opt` 是同一实例；再加一个 `public let lst: List<CtorParamItem>` 形参把 `List` 分支纳入编译与运行覆盖。

### [轻微][存量] 条件夹具定义在别的测试文件里，模式字面量在 3 个文件重复，数量断言写死 2

- **位置**：`f_bean/src/test/bean_string_cond_test.cj:32-35`（4 个模式常量）、`:56-59`（断言）；`f_bean/src/test/bean_iterator_test.cj:45-46,61`；`f_bean/src/test/bean_lookup_test.cj:187,240`；夹具 `f_bean/src/test/bean_getfirst_test.cj:32-38`（`BeanTestAnimal` / `BeanTestDog` / `BeanTestCat`）
- **来源**：存量（三个文件的 blame 分别落在 `e9ed1e9cb` / `9981e6e40` / `7e08b4b2e` 同一天）
- **判据**：review-checklist §2（字面量复制：同一正则 / 同一包名前缀散落多处）/ §10（可读性、可维护性）
- **证据**：静态确定 —— `'fountain::f_bean.test.*'` 出现在 `bean_lookup_test.cj:187,240`、`bean_iterator_test.cj:45`、`bean_string_cond_test.cj:32`（后两者再各派生一次）；`'.*BeanTestDog.*'` 出现在 3 个文件；`getList<BeanTestAnimal>(cond: Wildcard(...)).size == 2` 在 `bean_iterator_test.cj:61` 与 `bean_string_cond_test.cj:56` 语义完全相同（连期望值都是同一个 2）。
- **描述**：`bean_string_cond_test` 自己没有声明任何 bean（都在 `bean_getfirst_test.cj`），却断言整个包内 `BeanTestAnimal` 的实现恰好 2 个。往任何新测试文件里加一个 `BeanTestAnimal` 实现，这条断言就红，而失败点看起来像 `StringCond` 坏了。三个文件各自重复同一套模式字面量，改包名或改夹具名要同步改 4 处。
- **建议**：把 `BeanTestAnimal/Dog/Cat` 与模式常量集中到 `f_bean/src/test/fixtures.cj`（同包即可，不需要新模块），数量断言改成由夹具常量推导（如 `DOG.name`/`CAT.name` 组成集合后比对），或在 `bean_string_cond_test` 里改成断言「命中集合包含 dogName 且不含 catName」，去掉对全包规模的依赖。

### [轻微][存量] `StringCond` 8 个 case 只测了 3 个，`toString` / `ignored` / 两种 `==` 零断言

- **位置**：被测实现 `f_bean/src/BeanStringCondition.cj:75-110`；用例 `f_bean/src/test/bean_string_cond_test.cj:40-60`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §10（可测试性）/ §11（契约未验证）
- **证据**：静态确定 —— 全 `f_bean/src/test` 搜 `Prefix(` / `Suffix(` / `Contains(` / `In(`（`StringCond` 语境）零命中；`IgnoreCond` 只作为 `BeanDef(beanName: IgnoreCond)` 的参数出现（`bean_def_condition_test.cj:64-71`），它的 `on()` 恒 `true` 从未被断言；`ignored`（`:87-94`）、`toString()`（`:62-73`）、`operator func ==`（`:95-110`）没有任何用例。已覆盖的只有 `Wildcard` / `Regexp` / `Exactly`（且 `Exactly` 是在 `bean_getfirst_test` 里顺带覆盖）。
- **描述**：`Contains(v)` 是 `s.contains(v)`、`In(v)` 是 `v.contains(s)`（方向相反），是本枚举里最容易写反的一对，恰恰两条都没有用例；`==(StringCond)` 被 `BeanDefCondition` 等按值比较的地方依赖，写错也不会被发现。
- **建议**：给 8 个 case 各一条表驱动断言（输入串 / 期望布尔），加上 `@Assert(Exactly('a') == 'a', true)`、`@Assert(IgnoreCond.ignored, true)`、`@Assert(Wildcard('a*').toString(), 'Wildcard(a*)')`。总量约 10 行。

### [轻微][存量] `@Assert(false, true)` 被当作「强制失败」使用，语义不直观

- **位置**：`f_bean/src/test/bean_lookup_test.cj:227-231`
- **来源**：存量（`git blame -L 227,231` → `9981e6e40` 2026-10-05）
- **判据**：review-checklist §10（可读性）
- **证据**：静态确定 —— `@Assert(left, right)` 在本仓统一用作等值断言（同文件 `@Assert(list.size, 12)`、`@Assert(seen, 78)`），`false == true` 必然失败，读者需要先反推「这是故意的失败分支」。
- **建议**：改成 `@Fail('bean ${name} 查不回来')`（unittest 提供），或直接用 `@Assert(found.isSome(), true)` 消掉 else 分支。

### [轻微][存量] `generic_bean_test` 的夹具从未被取用，多组泛型只验证了第一组，且存在未读取的局部变量

- **位置**：`f_bean/src/test/generic_bean_test.cj:26-35`（`AbstractBean` / `TestBean1` / `TestBean2` / `TestBean`）、`:41`（`let bean` 赋值后不读）
- **来源**：存量（`git blame -L 26,35` 与 `-L 41` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §1（局部变量赋值后未读取；无使用符号）/ §10（可测试性）
- **证据**：静态确定 —— 全仓 `grep "TestBean1|TestBean2|AbstractBean"` 只命中 `generic_bean_test.cj` 的定义处；`TestBean` 从未被 `getFirst`/`lookup` 取过，因此它那两个 `private let` 字段的初始化器（`lookup<TestGenericBean<String>>()`、`lookupList<AbstractBean>()`）在本进程内从未执行；`@Bean[String|Int64]` 只查过 `TestGenericBean<String>`，`Int64` 组注册后无人查询。`let bean` 是 §1 的「读了不用」（编译器只会给告警）。
- **描述**：这 4 个类型是 `@Bean` 泛型注册、父类桶（`AbstractBean` 桶）的现成夹具，但没有任何断言用到它们；`test1` 里唯一有效的信息是「`lookup<TestGenericBean<String>>()` 不抛异常」（缺注册时抛 `BeanException` 会让用例变 ERROR），属于隐式断言。
- **建议**：把夹具用起来 —— `@Assert(lookup<TestGenericBean<Int64>>() is TestGenericBean<Int64>, true)` 覆盖第二组实参、`@Assert(BeanFactory.instance.getList<AbstractBean>().size, 2)` 覆盖父类桶、取一次 `TestBean` 验证字段注入不递归；`let bean` 要么加断言要么删掉。按硬原则一，这些 `public` 类型不判死代码，此处只作「未使用夹具」记录。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下三条的基线状态各不相同，`无基线` 者不得写成「能降 X%」，也不进 `tasks.md`。

### [CPU] 去掉查询路径的逐元素 `beanLog` 闭包（有条件基线）

- **现状**：`BeanFactory.beanLog`（`f_bean/src/BeanFactory.cj:224-228`）在 `getListByType`（`:277`）、`getMapByType`（`:298`）、`getAllTuples`（`:436`）、`getFirstByType`（`:241`）里**每个元素**调用一次，每次构造一个捕获 4 个变量的 `log.debug { ... }` 闭包。已归档测量（2026-10-05，同进程同结构，n = 5 万、min-of-4、12 个同类型 bean，日志文件 `/tmp/bean_l10_mech.log`）：`lookupList` 因这笔开销 **+3903 ns/次（+42%）**、`lookupHashMap` **+4183 ns/次（+32%）**，折算 **≈325~349 ns/元素**，且该环境 debug 关闭、`BeanFactory.getAll:` 实际输出 0 行 —— 开销与「是否真的打日志」无关。
- **方案**：二选一 —— ① 用 `f_log` 的级别查询把调用点包起来（`Logger.debugEnabled`，见 `f_log/src/base/Logger.cj`），关闭时连闭包都不构造；② 逐元素日志降级为「本次查询命中 N 条」的单条汇总日志（`getFirst` 命中点只保留 1 条）。
- **预期**：按上述基线，`lookupList` / `lookupHashMap` 端到端约 -30%~-42%（该路径即全部耗时，Amdahl 上限＝该占比）。
- **代价**：日志粒度变粗（排障时看不到逐 bean 命中）；方案 ① 依赖 `f_log` 暴露级别查询 API，需确认该 API 的语义与线程安全。
- **验证**：`cjpm bench -O2`，同进程同结构、n = 5 万、min-of-4 中位数对照，grep 日志确认输出行数不变。
- **证据状态**：`已有基线（2026-10-05 归档测量：lookupList +3903 ns/次、lookupHashMap +4183 ns/次，≈325~349 ns/元素，n=5 万）`；**注意**作者已在 `BEAN-L11` 判「保持现状」，本条需重新拍板后才进 `tasks.md`。

### [堆内存] `lookupLabels` / `lookupWeights` 仍先物化中间 `ArrayList` 再重建容器

- **现状**：`f_bean/src/lookup.cj:97`（`for (bean in lookupList<T>(cond))`）与 `:134`（同）都先构造一份完整的 `ArrayList<T>`（每条都触发 `m.bean`，prototype 会被实例化），随后逐条塞进目标 `HashMap` / `TreeMap` 后被丢弃。两份容器同时存活，峰值 = n 个引用 × 2。同文件 `lookupHashSet` / `lookupTreeSet`（`:57-66`、`:73-81`）已经按 `BEAN-L5` 改成「直接向目标集合填充」，这两处遗漏。
- **方案**：改成 `for (m in BeanFactory.instance.iterator<T>(cond)) { if (let b: T <- m.bean) { map[b.label] = b } }`（`lookupWeights` 同理，把累计权重留在循环内）。与 `getList` 的差别只在「顺手判类型 + 收集」，不引入新语义。
- **预期**：每次调用少一次 n 元素 `ArrayList` 的分配与一次遍历（n = bean 数），GC 压力与峰值内存同步下降；量级在 KiB 且与 bean 数成正比，未测。
- **代价**：与 `getList` 的两处实现再次分叉（可接受，`lookupHashSet` 已是同一取舍）；`getList` 未来若加容量提示，这里不会自动受益。
- **验证**：`getAllocatedHeapSize()` 前后对照 + `lookupLabels` 的 ns/op（`cjpm bench -O2`，bean 数 10/100/1000 三档）；同时断言返回值与现有实现逐项相等。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `getList` / `getMap` 结果容器预留容量、`check()` 去重集合按需分配（无基线）

- **现状**：`getListByType`（`f_bean/src/BeanFactory.cj:274-283`）与 `getMapByType`（`:295-304`）都从容量 0 的 `ArrayList` / `HashMap` 开始，逐元素扩容复制；`check()`（`:166-172`）为每次启动新建两个 `HashSet<TypeInfo>` 与一个 `TreeSet<BeanManager>`。
- **方案**：遍历前用桶的 `size` 预分配（`TreeSet.size` 为 O(1)），`ArrayList<T>(n)` / `HashMap<String, T>(n)`；`check()` 的 `typeRemoved` / `annotationRemoved` 改成「移除后立即判空删除」，省掉两个集合。
- **预期**：每 1000 条结果省 1~2 次扩容复制（≈数 KB 临时堆 + 一次数组拷贝），对启动期的 `check()` 省两次哈希集合。收益量级在 KiB，**未测量**。
- **代价**：需读桶的 `size`（`iteratorByType` 目前直接返回 `Iterator`，要拆成「先取桶再遍历」两条路），代码复杂度略升；与 `BEAN-L10` 的既有取舍（作者明确「`getList` 的扩容未动，需容量提示、会引入内部 API 依赖」）冲突。
- **验证**：`getAllocatedHeapSize()` + 分配次数埋点，n = 1 万~10 万对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。本表不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getFirst<T>()` 命中路径每次请求付 1 次 `beanLog` 闭包分配（`f_mvc` 每请求调用一次） | `f_bean/src/BeanFactory.cj:236-258`、`:224-228` | 单次 `getFirst` 的自耗时与闭包分配占比 | `cjprof record` 跑 10k 次 `lookup<T>()`，对比「有 `beanLog` / 注释掉 `beanLog`」两版；同时看 `getAllocatedHeapSize()` 增量 |
| 2 | `check()` 的清理是 O(被丢弃数 × 两张表条目数)，启动期 bean 多时成启动瓶颈 | `f_bean/src/BeanFactory.cj:176-186` | 启动期该函数自耗时占比（需 bean 数量级数据） | 在有 500+ bean 的应用（fdemo）里对 `afterRegistered()` 分段计时，拆出 `check()` 耗时 |
| 3 | `BeanDefType.on` 每个元素都调一次 `TypeInfos.get(全限定名)`（字符串→`TypeInfo`） | `f_bean/src/BeanDefCondition.cj:88-101` | 单次 `TypeInfos.get` 耗时与调用次数（每条件 × 每 bean） | 启动期埋点计数 + `cjprof` 看 `TypeInfos.get` 自耗时 |
| 4 | `WILDCARD_REGEX` / `REGEX_CACHE` 的命中率接近 100%（键空间＝代码声明条件数） | `f_bean/src/BeanStringCondition.cj:81-82` | 实际键数量与命中率 | 加计数埋点，跑 10 分钟稳态负载后打印两个 map 的 `size` |
| 5 | `lookupLabelOption(cond, label)` 在请求主路径上被调用，全量物化是实际开销 | `f_bean/src/lookup.cj:119-124` | 调用频次 + 单次自耗时 | 全仓搜 `lookupLabel`/`lookupOptionLable` 的调用点（当前为 0），若有下游使用则 `cjprof record` 跑稳态负载，看该方法自耗时占比 |
| 6 | `@Bean` 宏展开时 `tokens += …` 逐组拼接对多泛型组的类呈二次增长 | `f_bean/src/macros/Bean.cj:73-104` | 展开期耗时随 `attr` 组数/参数个数的曲线 | 用 1/4/16 组泛型实参的最小模块测 `cjpm build` 的宏展开耗时（编译期指标，不是运行时） |
| 7 | 4 处基准用例（30 万 / 30 万×2 / 6 万×29）显著拉长 `cjpm test`，且 `-O0` 下的 ns/op 无对照价值 | `test/bean_getfirst_test.cj:94-114`、`test/bean_iterator_test.cj:83-154`、`test/bean_string_cond_test.cj:62-88` | 各 `@TestCase` 的耗时与整套测试占比 | `cjpm test --filter <用例名>` 单独跑，与整套耗时对比；再用 `cjpm bench -O2` 同输入复测 ns/op |

## 文件覆盖

> 与模块文件清单一一对应。本模块共 39 个文件（37 `.cj` + 2 `.md`），下表中「已读」以各部分报告的实际取证为准。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/BeanCondition.cj` | .cj | ✅ | 接口 + `NoneBeanCondition`（有意的 Null Object）；`&`/`\|`/`!` 为对外扩展点 |
| 2 | `src/BeanConfCondition.cj` | .cj | ✅ | `ConfCond` 四 case 全分支；`on` 读 `Config` 仅在启动期 |
| 3 | `src/BeanDefCondition.cj` | .cj | ✅ | 见发现：双 Ignore 短路、`InfoNotFoundException`；count 各分支判定正确 |
| 4 | `src/BeanFactory.cj` | .cj | ✅ | 核心容器：读/写路径无同步、销毁三缺、`visited` 跨节点类型去重、注解查询重复、锁内求值 |
| 5 | `src/BeanInit.cj` | .cj | ✅ | 纯标记注解，无逻辑 |
| 6 | `src/BeanInitializer.cj` | .cj | ✅ | `static init` 注册自身，`initialize()` 调 `afterRegistered()`，无重复注册 |
| 7 | `src/BeanLabel.cj` | .cj | ✅ | 纯接口，无问题 |
| 8 | `src/BeanManager.cj` | .cj | ✅ | 见发现：自定义 scope 无落点、`generateDestroy` 可见性、`doDestroy` 无幂等、`initIfNeed` 无幂等；双检锁本身正确 |
| 9 | `src/BeanMeta.cj` | .cj | ✅ | `compare` 在「仅一方 name 为空」时返回 `EQ` |
| 10 | `src/BeanRelationCondition.cj` | .cj | ✅ | `And/Or/Not` 短路语义正确，无重复 |
| 11 | `src/BeanScope.cj` | .cj | ✅ | `isSingleton`/`isPrototype` 按 `typeInfo` 相等；自定义 scope 无落点见 #8 |
| 12 | `src/BeanStringCondition.cj` | .cj | ✅ | 两个正则 memo 表无容量上限；`toString`/`==` case 表属枚举展开；8 case 仅 3 个有用例 |
| 13 | `src/BeanWeight.cj` | .cj | ✅ | 纯接口，无问题 |
| 14 | `src/Destroy.cj` | .cj | ✅ | 纯接口，无问题 |
| 15 | `src/FactoryBean.cj` | .cj | ✅ | `static prop typeInfo` + `doRegister` 经 `TypeMemberInfos.staticProperty` 取真实类型，逻辑正确 |
| 16 | `src/PostConstructor.cj` | .cj | ✅ | 接口契约清楚；对 `FactoryBean` 的调用时序错位（见发现）；文件名与接口名不一致 |
| 17 | `src/exception/BeanException.cj` | .cj | ✅ | 4 个 `public init` 直转 `BaseException`；`init() {}` 为无消息异常的正当构造 |
| 18 | `src/imports.cj` | .cj | ✅ | 包级共享导入前置文件；3 个未使用 + 2 组重复 import；`setShouldInitBean` 无效已单列 |
| 19 | `src/lookup.cj` | .cj | ✅ | 全 `public` 顶层转发，无自有共享可变状态；键冲突丢 bean、`lookupLabelOption` 全量扫描、错名 API |
| 20 | `src/macros/Bean.cj` | .cj | ✅ | 三个 private 均有引用；泛型组切分正确；`@Bean[\|]` 会让注册列表为空且不报错（建议补 `diagReport`，未定级） |
| 21 | `src/macros/BeanParam.cj` | .cj | ✅ | 见发现：`attr.size == 3` + `attr[3]`、白名单大小写/缺项、空属性越界 |
| 22 | `src/macros/Configuration.cj` | .cj | ✅ | 见发现：`case _ => break` 静默跳过、`ClassDecl(input)` 无诊断；token 发射顺序正确 |
| 23 | `src/macros/Constructor.cj` | .cj | ✅ | 见发现：`isGenericDecl` 取反、无效果的 catch-rethrow；容器映射本身正确 |
| 24 | `src/macros/Value.cj` | .cj | ✅ | 见发现：`delim` 默认值、非 Option DateTime/Duration、Array 忽略 default、未知键静默、越界 |
| 25 | `src/macros/imports.cj` | .cj | ✅ | 4 行 import 全部被宏包使用，无死导入 |
| 26 | `src/test/bean_annotation_lookup_test.cj` | .cj | ✅ | 三种注解位置 + 过滤 + 顺序 + 空结果 + prototype 不实例化，断言自洽 |
| 27 | `src/test/bean_annotation_meta_test.cj` | .cj | ✅ | 元注解链用例，与 `doRegister` 注解节点展开对应，无问题 |
| 28 | `src/test/bean_def_condition_test.cj` | .cj | ✅ | 两条路径覆盖到位；问题：把 `BeanDef(count: Zero)` 缺陷钉成期望 |
| 29 | `src/test/bean_getfirst_test.cj` | .cj | ✅ | 类型/接口/父类/`Object` 桶/`beanType:` 重载/非法类型覆盖到位；基准段见合并条 |
| 30 | `src/test/bean_iterator_test.cj` | .cj | ✅ | 迭代器与 `getList`/`getMap`/`getAllTuples` 口径一致；`n * 29` 魔数与基准段 |
| 31 | `src/test/bean_lookup_test.cj` | .cj | ✅ | 12 个夹具、集合与顺序、`cond` 透传、空结果、两次调用稳定；`@Assert(false, true)`；`lookupLabels/Weights/LabelOption` 零覆盖 |
| 32 | `src/test/bean_scope_test.cj` | .cj | ✅ | 单例/prototype/自定义 scope 判定与实现一致；eager 用例未走 eager 路径、`:81` 自证断言 |
| 33 | `src/test/bean_string_cond_test.cj` | .cj | ✅ | `Wildcard`/`Regexp` 命中与 memo 键错配能抓住；仅覆盖 3/8 case、夹具跨文件、基准段 |
| 34 | `src/test/bean_test.cj` | .cj | ✅ | 唯一用例零断言（一般） |
| 35 | `src/test/constructor_param_test.cj` | .cj | ✅ | 6 种形态可编译并有 `size` 断言；键契约/元素身份未验、`List` 形态未覆盖 |
| 36 | `src/test/generic_bean_test.cj` | .cj | ✅ | 首组实参隐式验证；4 个夹具未取用、`Int64` 组未查询、`let bean` 未读 |
| 37 | `src/test/obj_test.cj` | .cj | ✅ | 纯夹具（`A`/`B` + 单形参 `@Constructor`），`toString` 满足契约；问题在消费者用例 |
| 38 | `README.md` | .md | ✅ | 各分部分以其行号作承诺源（`:29` 示例自递归、`:110/:124` 「全部 bean」、`:387-405` `BeanDef` 语义、`:454-455` `@Constructor`、`:491` 公开 API 列表含错名）；§13 结论：与实现存在 4 处不一致（并入对应发现） |
| 39 | `README_en.md` | .md | ⚠️ 未读 | 第 1–3 部分均未引用该文件，合并轮未复核；`README.md` 的差异（示例自递归、错名 API、`@Value`/`@BeanParam` 写法）是否同样存在于英文版待下一轮确认 |

合计：`.cj` 37 个 / `.md` 2 个 / 共 39 个；其中 38 个已读，1 个（`README_en.md`）未取证。

## 覆盖自检

> 命中数为三个部分之和（同根因条目合并后按一条计），0 条也给出排除依据。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性：`setShouldInitBean` 无效、销毁三缺、`BeanDef` 忽略 count、宏生成的目标代码在 3 类形参上不成立、`testEagerBeanCreatedAtMostOnce` 校验的不是声称路径、`initIfNeed` 无幂等；设计：自定义 scope 落点缺失、`lookup*`（位置形参）与 `BeanFactory.get*`（命名形参）两套约定并存；可读性：`PostConstructor` 文件名与接口名不一致、`lookupOptionLable` 拼写、`@Assert(false, true)`、跨文件夹具耦合；语言特性 0 命中：三部分全部 `Option` 都用 `if (let Some(x) <- …)` / `isSome()` / `getOrThrow()` 展开，无静默丢弃；安全性 0 命中：无 SQL、无凭据、无敏感日志，`beanLog`/异常消息只带类型名、条件与 bean 名 |
| §1 死代码 | 2 | 已逐个机械核对三部分全部 `private` / `internal` / `protected` 符号并全仓搜引用：`BeanFactory` 的私有族、`macros/*` 的私有辅助、`test/*` 的 `collectNames` 与模式常量、`macros/imports.cj` 的导入均有使用者；`internal` 的 `beanManagers` 被 `BeanDefCondition.cj:135` 调用，`doDestroy`/`generateDestroy`/`on`/`initIfNeed` 均被 `BeanFactory` 调用；无 `protected` 声明；无 `return`/`break` 后同层语句。命中 2 条：`imports.cj` 的 3 个未使用 + 2 组重复 import；`generic_bean_test.cj:41` 的 `let bean` 赋值后未读。对外可达 `public`（`lookup.cj` 全族、`BeanFactory` 查询入口、测试包 `public` 夹具）按硬原则一不判死代码，只作信息记录；`@BeanParam`/`Value.cj`/`Constructor.cj:28-34` 的无效果 `catch` 已作为建议附注 |
| §2 重复逻辑 | 3 | 已把三部分函数体/用例体压成「输入→输出→副作用」两两比对。命中 3 条：注解查询三件套（`:326`/`:345`/`:366`）；`Value.cj` 的 `Option<T>`/`?T` 双份 + DateTime 4 处、`Constructor.cj` 的 cond/no-cond 五形态双份；测试侧模式字面量与等价断言跨 3 文件重复。排除项：`getFirstByType`/`getListByType`/`getMapByType`/`iteratorByType` 是 `BEAN-L10` 的反抽象性能取舍且校验次数不同；`lookupHashSet`/`lookupTreeSet` 无共同 `add` 接口；`lookup*` 的 3 行转发是重载样板；`BeanStringCondition` 的 `toString`/`==` case 表与 `LookupItem01..12` 属枚举展开/测试准备代码；`testHashSetAndTreeSetEquivalence` 与 `testListElementsAndOrder` 语义不同。基准段三处同根因已合并为一条并列全位置 |
| §3 空实现 | 6 | 命中：`setShouldInitBean`（无效 API）、Windows `ExitCallbacks.atExit`（空体）、`@Configuration` 的 `case _ => break`、`@Value` 对 Array `default` 与未知键静默忽略、`bean_test.cj:23-27`（零断言）、`generic_bean_test.cj:40-42`（取而不验）；另有 `bean_scope_test.cj:80-81` 的自证分支归入空断言（计入「综合」行的可读性）。其余空体均为正当：`NoneBeanCondition.on` 恒 true 的 Null Object、`BeanManager.generateDestroy` 的 `{=>}`、`Configuration.cj:50` 的 `case _ => ()`、`BeanException.init() {}`、纯标记注解/纯接口、`obj_test.cj` 无 `@Test` 的夹具文件 |
| §4 栈溢出 | 0 | 三部分均逐文件核对：`doRegister` 用显式 `LinkedList` 队列 + `visited` 环检测（`BeanFactory.cj:76-138`）；宏侧 `while (let md: MacroExpandDecl <- d)` 深度 = 注解嵌套层数（代码常量）；`extractClassDecl` 只解一层；测试夹具依赖图 `B→A`、`CtorParamShapes→CtorParamItem`、`TestBean→{TestGenericBean,AbstractBean}` 三层无环，且 `TestBean` 字段注入目标与自身不同；`check`/`shutdown`/排序均非递归。唯一潜在递归在 `TypeInfos.get`（`f_base`，范围外） |
| §5 OOM | 1 | 命中：`WILDCARD_REGEX`/`REGEX_CACHE` 无容量上限（轻微）。其余已核：`beans`/`beanTypeMap`/`annotationMap` 键空间＝代码声明数、注册后冻结；`visited` 是注册局部集合；`lookup*` 物化的是「某类型的 bean 列表」（规模＝bean 数）；测试的基准循环只累加 `Int64`；无按报文长度预分配、无全量任务提交 |
| §6.1 热点瓶颈 | 0 | 本轮未提供 profile / bench 输出（`scope.md` 声明无性能资料），三部分都没有「函数 + 自耗时占比 + 调用路径 + 输入规模 + 工具」五要素齐全的热点，故不作发现。唯一有归档实测的是逐元素 `beanLog`（≈325~349 ns/元素，n=5 万），已写成「优化可行性方案」并标注作者曾判 `BEAN-L11` 保持现状；`getFirst` 的闭包、`check()` 清理复杂度、宏展开耗时、单测基准时长全部进「待验证假设」（7 条） |
| §6.2 大粒度锁 | 0 | 唯一的 `synchronized` 在 `doRegister`/`check`，均启动期一次性执行；`check` 内的条件求值与日志已单列为 §12.2 轻微条；运行期热路径（`bean` getter 的 `mutex`）临界区仅「新建实例 + 存原子引用」，无 I/O、无日志、无回调，属必要最小临界区（`new()` 必须只跑一次）。测试与宏侧无锁 |
| §6.3 并发串行 | 0 | 全模块无 `spawn`、无 `Future.get`、无批处理、无单消费者队列；`initBeansIfNeed` 顺序初始化 bean 属启动期串行且有明确依赖语义 |
| §6.4 低效算法 | 2 | 命中（均轻微）：`check()` 对每个被丢弃 bean 全量遍历两张表再 `set.remove`，O(丢弃数 × 表条目数)（启动期一次，见待验证假设 #2）；`lookupLabelOption` 为取第一个而全量物化 + 线性扫描。其余查询走 `HashMap`/`TreeSet`，无循环内 `contains`、无 `remove(at: 0)`、无循环内字符串拼接（宏侧 `tokens +=` 只在编译期、组数 ≤ 注解组数） |
| §7 降堆内存方案 | 2 | 见「优化可行性方案 [堆内存]」两条：`lookupLabels`/`lookupWeights` 的中间 `ArrayList`、`getList`/`getMap` 预留容量 + `check()` 集合按需分配。均 `无基线`。测试侧与 `clear()`/`gc()` 类假象不涉及 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 [CPU]」逐元素 `beanLog`（唯一有归档基线的一条）。`lookupLabelOption` 的早退已作缺陷（§6.4）单列，不重复计；宏展开耗时属编译期，仅进待验证假设 |
| §9 local mode 可行性 | 0 | 无「函数内创建、函数内销毁」的大临时对象：`doRegister` 的临时集合规模 = 类型闭包（几十元素）；`getList`/`getMap`/`lookup*` 的容器全部作为返回值逃逸；`beanLog` 的闭包被 `log.debug` 捕获后逃逸；测试容器作为断言对象逃逸，且测试不在产品构建优化面内。收益无法用峰值内存证明 ⇒ 不成立 |
| §11 现有代码的 BUG（存量） | 19 | 逐条核对后单列：严重 1（`setShouldInitBean` 无效）、一般形 10（自定义 scope 落点、Windows 销毁缺失、销毁三缺、读路径无锁、`BeanDef` 忽略 count、`@BeanParam`、`@Constructor`、`@Value`、`@Configuration`、`initIfNeed` 无幂等）、其余为轻微契约/边界问题（`visited`、`BeanMeta.compare`、`BeanDefType` 异常、键冲突、全量扫描、错名 API、`PostConstruct` 错位、测试固化缺陷、自证断言、`StringCond` 覆盖缺口、`@Assert(false,true)`、夹具未取用）。另核对无缺陷的点：`getFirstByType` 的桶内子类型复检恒真（`beanTypeIs` 保证 `beanType ⊆ T`）成立；`LookupItem` 的 `hashCode`/`compare` 与 `HashSet`/`TreeSet` 契约一致；`getFirst<BeanTestDog>(cond: Exactly(catName))` 返回 `None` 与实现一致；`bean_scope_test` 的 `BeanMeta(lazy:false, scope:prototype)` 与 `initIfNeed` 三条件逐项对应 |
| §12 并发安全与锁粒度 | 2 | 命中：读路径无锁 vs 启动期写（一般，`待确认` 是否存在并发读者，未定严重）、`check()` 锁内求值外部条件 + 打日志（轻微）。已核的安全点：`BeanManager.bean` 双检锁正确（`AtomicOptionReference` 原子读写 + `mutex` 保证 `new()` 单次）；`_name`/`_singleton`/`meta`/`beanType` 构造后不可变、随构造发布；`registered` 用 `AtomicBool`；`TreeSet`/`HashMap` 稳态只读；测试侧跨用例共享量仅 `AtomicInt64` 计数；宏在编译期单线程展开。按「先安全、后粒度」，未提出以牺牲正确性换锁的改造 |
| §13 文档一致性（.md） | 2 | `README.md` 与实现对照出 2 类不一致：① `:29` 示例在 `@Bean` 类内 `lookup` 自身会在单例缓存写入前递归构造（范围外提示，README 侧问题）；② 公开能力与实现不符 4 处（`:110`/`:124`「全部 bean」与键覆盖、`:387-405` `BeanDef(count: Zero)`、`:454-455` `@Constructor` 静态工厂、`:491` 收录错名 `lookupOptionLable`），已分别并入对应发现；`README_en.md` 未取证，可能同源 |
| §14 功能完备性与 README 覆盖 | 0 | 三部分均无「承诺但未实现」的独立条目：`BeanScope` 自定义作用范围、`@Value`/`@BeanParam`/`@Configuration`/`@BeanInit` 的承诺缺口已按「契约与实现不符」归入 §11 而非重复计；`public` 声明与 README 的逐项覆盖未发现「API 未进 README」（`README:491` 反而收录了错名）；`BeanFactory.close()` 与注册族均已接线 |
| 文件覆盖（§13 等） | 38/39 | 缺 `README_en.md`：第 1–3 部分均未引用该文件，合并轮按「只读报告」约束未补取证 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 12 |
| 轻微 | 20 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

> 合计发现 33 条，全部为存量（严重 1、一般 12、轻微 20），无「本次改动」引入项；合并前为 34 条（12 + 12 + 10），其中三处「基准代码留在单测」同根因合并为 1 条，故去重后 33 条。存量是否纳入修复待用户决定。待验证假设 7 条不计入本表。

## 总评

f_bean 是整套 fountain 的容器骨架，实现水平分层非常明显：**注册与查找的核心设计是清醒的**——注册期用显式队列 + `visited` 做类型闭包展开（既不递归也能挡环），查询期用「注册期预建超类型桶 + 运行期只做名字过滤」把每请求查找压到一次 `HashMap.get` 加一次遍历，双检锁、`AtomicOptionReference`、条件组合算符都用对了，`Option` 全模块没有一处被静默丢弃，也没有空 `catch`。问题不在热路径。

**阻塞项（建议优先，改动小、语义明确）**：① `setShouldInitBean()` 是彻底无效的公开 API（严重）——代码关不掉、命令行能关掉，这种「配置看起来生效了」的故障最容易被运维误判；② 销毁路径三缺（无顺序、无异常隔离、无幂等）叠加后，一个 bean 的 `close()` 抛异常会让其余资源全部不释放，且可能对同一实例 `close()` 两次；③ `initIfNeed()` 无幂等，重复 `afterRegistered()` 会静默重建全部非 lazy 单例、丢 `PostConstruct` 状态并泄漏句柄。这三条都不在每请求路径上，属「启动/退出时暴露、排查成本高」的类型。

**需要设计拍板的**：自定义 `BeanScope` 的实例缓存与销毁入口在实现上根本不存在（注释承诺了能力却没有落点，下游照文档实现会得到每次 lookup 都新建且无法登记销毁的容器）；Windows 上 `ExitCallbacks.atExit` 为空使 `destroy`/`close` 永不执行（跨平台静默差异）。并发方面，稳态是安全的，但「读无锁、写持锁」的正确性依赖「`afterRegistered` 期间没有并发读者」这一未写进代码的时序前提，同时 `check()` 在锁内求值用户自定义条件——建议把它改成不可变快照发布，而不是留一个隐式假设。

**宏是本模块最大的隐性风险，且风险集中在一个事实：`@Value`、`@BeanParam`、`@Configuration`、`@BeanInit` 在整个仓库里零使用、零测试**。失去编译覆盖后，静态可判的缺陷全部留了下来：`@BeanParam` 的短写形式因 `attr.size == 3` + `attr[3]` 根本走不到，白名单把 `Prefix`/`Wildcard` 写成小写还漏了 `Contains`/`In`；`@Constructor` 把 `isGenericDecl` 用反，导致 README 承诺的「静态函数作为初始化函数」整条不可用；`@Value` 给 `Array` 的 `delim` 塞了一个标点 token、给非 Option 的 `DateTime`/`Duration` 生成 `?T` 赋给 `T`、并把数组的 `default` 静默忽略。这四条都是「按文档写就编译不过或静默不生效」，处理顺序应是先补最小用例、再按用例暴露的顺序修、最后把 `@Configuration` 的静默跳过改成 `diagReport`。

**测试面质量分布不均**：新补的 `bean_lookup_test` / `bean_scope_test` / `bean_string_cond_test` / `constructor_param_test` 断言扎实，能在实现被改坏时真正变红（`bean_string_cond_test` 甚至能抓住 memo 缓存键只算 flags 不算 pattern 这类隐蔽错误）；老用例 `bean_test`（模块同名文件、唯一用例零断言）、`generic_bean_test`（4 个夹具从未被取用、第二组泛型实参零覆盖）、`obj_test`（纯夹具）基本是脚手架，合起来对 `@Constructor` 非集合形参注入这条公开能力没有任何断言。另外 `testEagerBeanCreatedAtMostOnce` 因测试进程从不调 `afterRegistered()` 而根本没碰到 eager 路径，再叠加 `testInitIfNeedJudgement` 的 `|| !inited` 恒真出口，使「启动期预初始化」这个生命周期风险点完全无防线——补一条隔离进程的 `--filter` 用例即可覆盖。

**性能**：本轮没有新的热点结论。唯一有归档数据的是逐元素 `beanLog`（≈325~349 ns/元素，`lookupList` +42%、`lookupHashMap` +32%，n=5 万），作者已在 `BEAN-L11` 判「保持现状」，此处只作为待拍板的优化项保留，不进修复清单；堆内存两条方案（`lookup*` 中间列表、`getList` 预留容量）均无基线，只能作为下一轮补数据的候选。测试工程上有两处应清理：基准段继续留在 `cjpm test`（三处，`-O0` 下 ns/op 无对照价值，且把总次数写成 `n * 29` 这类魔数），以及 `@Assert(false, true)` 这种反直觉写法。

**存量共 33 条（严重 1、一般 12、轻微 20），是否纳入修复待用户决定。**
