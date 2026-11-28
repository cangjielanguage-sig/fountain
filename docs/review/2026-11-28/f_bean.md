# f_bean 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（39 个文件：37 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_bean.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] `BeanManager.initIfNeed()` 没有「已初始化」判断 ⇒ 非 lazy 单例被二次创建并覆盖

- **位置**：`f_bean/src/BeanManager.cj:69-76`（`initIfNeed` 无条件 `_bean.store(new())`）、`f_bean/src/BeanManager.cj:98-118`（`bean` getter 的 DCL 把同一实例写进 `_bean`）、`f_bean/src/BeanFactory.cj:195-203`（`initBeansIfNeed` 对**每个** manager 调 `initIfNeed`）、`f_bean/src/BeanFactory.cj:154-163`（`afterRegistered` 无重入保护）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「检查-然后-写入」「共享可变状态无保护」
- **证据**：静态确定 —— `initIfNeed` 的条件只有 `shouldInitBean && !meta.lazy && _singleton`，**不检查 `_bean.load()` 是否已有值**，直接 `new()` 后 `store` 覆盖；而 `bean` getter（`:104-111`）已经把「按需创建的单例」存进同一个 `_bean`。两条写入路径共用一份存储，后者无条件覆盖前者。
- **描述**：触发路径有两条，都不需要并发：
  1. **启动期跨 bean 依赖（主路径）**：`initBeansIfNeed` 按 `HashMap` 迭代顺序逐个 `initIfNeed`。若 `A` 排在 `B` 之前，`A` 的 creator 里 `lookup<B>()`（README.md:29 就是这个写法）会让 `B` 通过 `bean` getter 创建并写入 `_bean`；随后循环走到 `B`，`initIfNeed()` 再 `new()` 一个 `B` 并覆盖 ⇒ 进程内出现**两个 B 实例**，`B.postConstruct()` 执行两次，被 `A` 持有的旧实例脱离容器、退出时不会被 `doDestroy` 销毁（`BeanFactory.cj:49-53` 只销毁 `_bean` 里那一个）。结果还依赖 `HashMap` 迭代顺序 ⇒ 同代码不同构建/不同 bean 数表现不同。
  2. **`afterRegistered()` 重入**：`registered.store(true)` 只用来拦 `doRegister`（且该判断在锁外，`BeanFactory.cj:58-60`），`afterRegistered` 本身可被再次调用（它是 `public`，测试里就显式调用过，见 `src/test/bean_def_condition_test.cj:31` 注释）。第二次调用会重跑 `check()` + `initBeansIfNeed()` ⇒ 全部非 lazy 单例再创建一遍并覆盖。此时若已有工作线程在读 `beans`/`beanTypeMap`（读路径完全无锁，见下条），还会叠加 `HashMap` 的并发读写。
- **建议**：`initIfNeed` 改成「CAS 式抢占」——`if (_bean.load().isNone() && _bean.compareAndSwap(None, new()))`，或先 `synchronized(mutex)` 按 `bean` getter 的双检写；`afterRegistered` 加一次性闸门（`if (registered.swap(true)) { return }`，并把 `doRegister` 的 `registered.load()` 挪进同一把 `mutex` 内），保证「注册 → 筛选 → 预初始化」整体只执行一次。

### [严重][存量] bean 循环依赖无任何检测：构造期 `lookup` 环 ⇒ 同线程无限递归（StackOverflow）/ 跨线程锁序死锁

- **位置**：`f_bean/src/BeanManager.cj:104-112`（`synchronized(mutex)` 内 `new()`）、`f_bean/src/BeanManager.cj:77-86`（`new()` 直接调 `creator()`）、`f_bean/src/BeanFactory.cj:236-258`（`getFirstByType` 取 `m.bean`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「间接递归 / 无环检测」、§12.1「死锁：多锁顺序不一致 / 锁内调用外部回调」
- **证据**：静态确定 —— 代码里没有「正在创建」标记（对比 Spring 的 `BeanCurrentlyInCreationException`），也没有任何环检测；`Mutex` 文档明确是**可重入**锁（`stdlib/doc/libs/std/sync/sync_package_api/sync_package_classes.md:8927-8930`）。
- **描述**：`A` 的 creator 里 `lookup<B>()`、`B` 的 creator 里 `lookup<A>()`（README 推荐的构造期注入写法）时：
  - 同线程：构造 `A` → 持有 `A.mutex` → `B.bean` → 持有 `B.mutex` → 回到 `A.bean`，此时 `A._bean` 仍是 `None`，`synchronized(A.mutex)` 因可重入直接放行 → 再次 `new()` ⇒ 无限递归，最终 `StackOverflowError`，栈里没有任何「循环依赖」信息。
  - 两线程分别首次取 `A`、`B`：T1 持 `A.mutex` 等 `B.mutex`，T2 持 `B.mutex` 等 `A.mutex` ⇒ 永久死锁（启动期会表现为进程挂住、无日志）。
  自引用（`A` 的 creator 里 `lookup<A>()`）走同一条递归路径。
- **建议**：`BeanManager` 增加 `creating` 状态（`AtomicBool` 或 `mutex` 保护的标志），在 `new()` 前置位、`finally` 复位；重入时抛 `BeanException('circular dependency: A -> B -> A')` 并带上已访问链。若要支持合法环，需改为「先暴露未完成实例再注入」（Spring 的三级缓存语义），成本高，建议先做检测+报错。

### [一般][存量] `BeanDefType.CurrentOrSuperOf` 实际等价于 `Current`：祖先类型永远查不到

- **位置**：`f_bean/src/BeanDefCondition.cj:127`（`case (CurrentOrSuperOf(t), _) => on(factory, TypeInfos.get(t))`）配合 `f_bean/src/BeanDefCondition.cj:96-100`（判定式 `ti == beanType || ti.isSubtypeOf(beanType)`）、`f_bean/src/BeanFactory.cj:76-100`（桶的构建方式）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名/注释不符」「契约与实现不符」；§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— `doRegister` 把每个 bean 写入「其类型的**超类型闭包**」为键的桶（`:76-100`），因此 `beanTypeMap.get(t)` = `{b | b.beanType ⊑ t}`（t 的子类型集）。`CurrentOrSuperOf(t)` 要求 `{b | b.beanType == t || t ⊑ b.beanType}`（t 的祖先集），两组集合的交集只有 `{t}`：桶内元素满足 `b.beanType ⊑ t`，再要求 `t ⊑ b.beanType` ⇒ 只能相等。祖先类型（`Any`/`Object`/父类）不在 `t` 的桶里，永远扫不到。
- **描述**：`BeanDefType.CurrentOrSuperOf` 的注释与 README（`README.md:374-377`、`README_en.md:377-380`）都写「指定类型或指定类型的祖先类型」，实现却只命中「恰好等于指定类型」的 bean ⇒ 与 `Current` 完全同义，注释承诺的「祖先」分支从不成立。`SuperOfOnly` 反而因为落到 `_` 分支（`:130` → 扫 `Object` 桶）能得到正确结果，于是同一枚举里两个「Super」语义的实现路径不一致。仓库用例把错误行为钉住了：`src/test/bean_def_condition_test.cj:95` 断言 `CurrentOrSuperOf(接口)` 为 `false`，而该进程里确实存在 `Object` 类型的 bean（同文件 `:96` 注释承认），按文档应为 `true`。
- **建议**：`CurrentOrSuperOf` / `SuperOfOnly` 统一扫 `Object` 桶（全量 bean）后按 `beanType.on(m.beanType)` 过滤，与 `SuperOfOnly` 共用一条路径；若在意 `BeanDef` 求值的 O(n)，可另建「反向桶」（键 = 子类型，值 = 祖先 bean），但启动期一次性求值，先保正确性。同时修正 `bean_def_condition_test.cj:95` 的断言。

### [一般][存量] `check()` 只做单趟淘汰、不做不动点：依赖被淘汰 bean 的条件 bean 仍会保留，且结果依赖 `HashMap` 迭代顺序

- **位置**：`f_bean/src/BeanFactory.cj:164-194`（`:167-170` 只收集 `discarded`，`:173-186` 才真正删除）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 边界」、§13（`BeanDef` 语义）
- **证据**：静态确定 —— 淘汰分两段：第一段遍历 `beans` 求 `m.on(this)`，此时**没有任何 bean 被移除**；第二段才按 `discarded` 删表。因此求值阶段看到的容器快照包含「本轮注定被删」的 bean。
- **描述**：设 `X` 的条件恒假、`Y` 的条件是 `BeanDef(beanType: Current('...X'))`。单趟求值时 `X` 还在 `beans` 里 ⇒ `Y` 判真并保留；随后 `X` 被删除、`Y` 留下。之后 `Y` 被初始化时构造期 `lookup<X>()` 会抛 `BeanException`——错误信息指向「找不到 X」，而真实原因是「Y 的条件已不成立」。若 `X`/`Y` 的迭代顺序相反（`HashMap` 顺序不保证），`Y` 会不会被淘汰也不确定 ⇒ 同配置不同构建可能表现不同。`BeanDef(count: Zero)` 这类「否定型」条件在删除后也没有机会重新变真。
- **建议**：把「求值 → 删除」放进 `do { ... } while (removed)` 循环直到不动点（每轮只删、不复活；`BeanDef` 只支持否定单调性即可收敛），或在删除后对所有 bean 重新求一次条件并把新命中的一并删除。收敛上限可记为 `beans.size()` 轮并加日志。

### [一般][存量] 自定义 `BeanScope` 实际退化为 `prototype`：既无法缓存实例，也没有销毁入口

- **位置**：`f_bean/src/BeanScope.cj:18-21`（类注释承诺「可以在其它模块定义新的作用范围……受自定义作用范围影响的 bean 生命周期由范围定义模块维持」）、`f_bean/src/BeanManager.cj:30/36`（`_singleton = meta.scope.isSingleton`，二值判定）、`f_bean/src/BeanManager.cj:114-116`（非 singleton 一律 `new()`）、`f_bean/src/BeanManager.cj:57-65`（`generateDestroy` 是 `internal`）、`f_bean/src/BeanManager.cj:77-86`（`new()` 是 `private`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14「承诺了但没实现」、§11「契约与实现不符」
- **证据**：静态确定 —— `bean` getter 只有两条分支：`_singleton` 走缓存，其余**每次** `new()`。`_bean`、`new()`、`generateDestroy` 全部对包外不可见，scope 模块拿不到「创建一次并放进自己的作用域」的句柄，也拿不到销毁函数。
- **描述**：`BeanScope` 是 `public abstract class`，注释明确鼓励外部实现新作用域并「由范围定义模块维持生命周期」。但任何自定义 scope 的 `isSingleton` 都为 `false` ⇒ 每次 `lookup` 都新建实例（与 `prototype` 无差别），scope 模块既不能把实例存进自己的 `HashMap`（没有创建入口），也不能在作用域结束时销毁（`generateDestroy` 不可见）。仓库内确实没有自定义 scope 的用例（全仓 `<: BeanScope` 只有 `PrototypeBeanScope` / `SingletonBeanScope`），但这是文档承诺的能力缺口。
- **建议**：二选一：① 收窄文档——删掉「可以在其它模块定义新的作用范围……由范围定义模块维持」，说明当前只支持 singleton/prototype；② 补最小扩展点——`public func create(): Object`、`public func destroyOf(o: Object): () -> Unit`（或 `public func take(): ?Object`），并提供 `registerScoped`，让 scope 模块自己持有实例。

### [一般][存量] 退出销毁路径不可靠：Windows 上完全不执行；POSIX 下单个 `destroy` 抛异常会中断其余 bean，顺序还是 `HashMap` 序

- **位置**：`f_bean/src/BeanFactory.cj:49-53`（`shutdown` 无 try/catch、直接遍历 `beans`）、`f_bean/src/BeanFactory.cj:47`（`ExitCallbacks.atExit(253, this.shutdown)`）、根因在 `f_base/src/signal.cj:70-74`（`@When[os == "Windows"]` 的 `atExit` 是空实现）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源释放不对称」「错误处理缺失」、§3「静默吞掉」（Windows 版是反向：静默不执行）
- **证据**：静态确定 —— Windows 分档的 `ExitCallbacks.atExit` 是 `{}`，`shutdown` 永远不会被调用；POSIX 分档 `onExit`（`signal.cj:60-68`）在同一把锁里顺序执行回调，任一 `destroy` 抛异常会跳出循环，后续 bean 不再销毁；`shutdown` 自身对 `HashMap` 直接迭代，销毁顺序与依赖顺序无关。
- **描述**：README.md:433 承诺「singleton bean 由 IOC 框架调用 destroy」。实际：Windows 部署时 `Destroy`/`Resource.close` 一次都不会被调用（连接、文件、线程不释放）；POSIX 上只要某个 bean 的 `destroy` 抛异常，它后面的 bean 全部漏销（含数据库连接池、日志刷盘这类对顺序敏感的资源）；顺序不可控也意味着「被依赖者」可能先于「依赖者」销毁。以上都不影响正常业务请求，只在关停/退出窗口暴露。
- **建议**：`shutdown` 内逐个 `try { m.doDestroy() } catch (e: Exception) { log.error(...) }` 保证互不影响；顺序改为按 `index` 逆序（BeanManager 已有自增 `index`，与注册顺序一致 ⇒ 逆序≈依赖逆序）；Windows 侧不要依赖信号，改为 `fboot` 在 `stop()` 阶段显式调用 `BeanFactory.instance.afterStop()`（新增 `public func close()`），或让 `ExitCallbacks` 在 Windows 上注册到进程退出钩子（若 `std.runtime` 提供）。

### [轻微][存量] 未使用 / 重复的 import（`std.env.*`、`std.process.Process`、`std.convert.*`）

- **位置**：`f_bean/src/imports.cj:21`（`internal import std.env.*`）、`:22`（`internal import std.process.Process`）、`:20` 与 `:30`（`std.convert.*` 同时 `internal` 与 `public` 导入）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全包搜 `env.` / `getVariables` / `Process` / `parse(` / `tryParse` / `toInt64`，`f_bean/src/**`（含 `macros/`，它有独立 `imports.cj`）与 `src/test/**`（独立包 `fountain::f_bean.test`）均零命中；因此前两条是彻底的死 import。`std.convert.*` 在包内也无使用，只剩「对外再导出」这一可能意图（`:30` 是 `public import`），而 `:20` 的 `internal` 版本被 `:30` 完全覆盖。
- **建议**：删除 `:21`、`:22`、`:20`；`:30` 的 `public import std.convert.*` 若确为下游再导出（`f_bean` 的 API 签名里没有 `Parsable` 类型），建议一并删除；若要保留再导出，在文件里加一行注释说明理由。

### [轻微][存量] §2 重复逻辑：同一条「按条件从桶里取 bean」的逻辑有四份实现

- **位置**：`f_bean/src/BeanFactory.cj:236-258`（`getFirstByType`：`Exactly` / 非 `Exactly` 双分支）、`:458-476`（`iteratorByType`：同样的双分支 + `cond.ignored` 快路径）、`:415-425`（`getFirstTuple` 的非 `Exactly` 分支）、`:324-331` / `:342-352` / `:363-373`（三个 `*ByAnnotation` 循环，仅收集方式不同）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 只改类型名」；§2 判据「合并前先列差异点」
- **证据**：静态确定 —— 四处的输入（`cond`、`beanType`/`annotation`）、判定（`cond.on(m.name)` + 子类型）、副作用（`beanLog` + `m.bean` 实例化）完全一致，差异只在「返回第一个 / 全部 / 带销毁函数的元组」和收集容器。历史成本可验证：`BEAN-2`/`BEAN-3`/`BEAN-10`（`.autocode/bugs/bug-bean-archived-20261006.md` §2.15/§2.16/§3.1）每次优化都要同时改 3 处，注释里也写明「同族」。
- **描述**：`getFirstByType` 完全可以由 `iteratorByType(...).next()` 实现（`iteratorByType` 已有 `cond.ignored` 快路径和 `Exactly` 快路径），`getFirstTuple` 亦同；三个 `*ByAnnotation` 可以先取一次 `annotationManagers` 再共用「过滤 + 收集」。当前四份实现的行为细节已经开始漂移：`getFirstByType` 没有 `cond.ignored` 快路径（每元素仍建闭包），`getAllTuples` 用 `iteratorByType`，而 `getFirstTuple` 不用。
- **建议**：统一到 `iteratorByType` / 「注解桶迭代器」两个唯一入口，`getFirst*` 用 `next()`、`getList*`/`getMap*` 用 `for` 收集；`getFirstTuple` 与 `getAllTuples` 共用同一个 `iteratorByType`。合并属等价重构，需附「元素集合、顺序、`beanLog` 次数、prototype 实例化次数不变」的用例（现有 `bean_getfirst_test.cj` / `bean_iterator_test.cj` 可扩）。

### [轻微][存量] `doRegister` 的 `visited` 不区分 `ClassType` / `AnnotationType`，同一类型以两种身份出现时只展开一次

- **位置**：`f_bean/src/BeanFactory.cj:84`（单一 `HashSet<TypeInfo>`）、`:90-93`（命中即 `continue`，`BeanType` 身份被丢弃）、`:85-89`（两个身份走不同分支）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 等价性」、§12.1（注册期构建的类型闭包不完整 ⇒ 后续查找漏命中）
- **证据**：待确认 —— 需要一个类型同时作为「bean 的类型节点（类/父类）」与「注解节点」出现在同一轮注册里的用例；仓内没有这种 bean（注解类不作为 bean 的父类使用），所以当前不会触发。
- **描述**：队列里同一个 `TypeInfo` 可能先以 `AnnotationType` 入队（某个类上的注解），后以 `ClassType` 入队（另一个 bean 的父类/接口）。由于 `visited` 只按 `TypeInfo` 去重，后到的那次会被 `continue` 跳过 ⇒ 它的 `superInterfaces` / `superClass` / `annotations` 不再展开，该 bean 在「父类的父类」「父类上的注解」这些桶里缺失 ⇒ `getFirst<父父类>()` / `getByAnnotation` 漏命中。反之亦然。
- **建议**：`visited` 的键改为 `(isClass, TypeInfo)`（例如 `HashSet<(Bool, TypeInfo)>`，或两个独立 `HashSet`），保持「同一身份只展开一次、两种身份各自展开」。

### [轻微][存量] `StringCond` 的通配/正则编译缓存无容量上限

- **位置**：`f_bean/src/BeanStringCondition.cj:22-23`（`WILDCARD_REGEX` / `REGEX_CACHE` 两个 `ConcurrentHashMap<String, Regex>`）、`:81-82`（`computeIfAbsent`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「缓存键无界」（无量化 ⇒ 只能定轻微）、§7「有界化」
- **证据**：待确认 —— 注释（`:18-21`）声明「键空间 = 代码里声明的条件模式数（有界）」，但 `StringCond` 是 `public enum`、`on` 是 `public func`，任何下游都能用运行期字符串构造 `Regexp`/`Wildcard`（例如从配置项、租户配置、路由规则拼出来）。仓内是否有这种动态构造点，本部分无法确认（`lookup.cj` 在第 2 部分）。
- **描述**：只要存在一个「按外部输入构造 `Regexp`/`Wildcard`」的调用点，两个 map 就随不同模式串单调增长且**永不淘汰**（`ConcurrentHashMap` 无 LRU），正则对象本身还持有编译后的状态机 ⇒ 长跑进程 RSS 单调上升。这与「键空间有界」的假设强绑定，但没有代码强制。
- **建议**：给缓存加上限（复用 `f_cache` 的 `HeapCache`，或自带 `maxSize` + 简单淘汰）；或在 `WILDCARD_REGEX`/`REGEX_CACHE` 上写明「仅用于编译期常量模式」的契约并在 `Regexp` 构造侧（宏）保证。

### [轻微][存量] `setShouldInitBean` 的生效窗口没有定义，仓内零调用；配套配置键未进 README

- **位置**：`f_bean/src/imports.cj:36-44`（`SHOULD_INIT_BEAN_CONF_KEY` / `internal let shouldInitBean = Config.getValue<Bool>(...) ?? true` / `public func setShouldInitBean`）、`f_bean/src/BeanFactory.cj:196`、`f_bean/src/BeanManager.cj:70`（两个读取点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与命名不符」、§14.2「公开配置项未文档化」
- **证据**：待确认 —— 缺「模块级 `let` 初始化时机」的权威说明。可确定的是：`shouldInitBean` 是模块级 `let`，`Config.getValue` 只在它的初始化表达式里读一次；`setShouldInitBean` 只写 `Config`，全仓没有任何代码重新读取该键（`grep shouldInitBean` 仅命中定义处、两个读取点与测试注释）。若全局 `let` 在库加载期求值（仓颉全局变量必须带初值，`program_structure.md:97`），setter 永远无效；若是懒求值，则必须在 `BeanInitializer` 之前调用才有效，而这个「必须早于 topo 序」的约束没有任何文档。
- **描述**：名字承诺「设置 shouldInitBean」，实际要么完全无效、要么生效窗口极窄且不可见；仓内零调用者，`README`/`README_en` 也没有 `SHOULD_INIT_BEAN_CONF_KEY` 与这个开关的任何说明（只在「其他公开 API」里列了 `setShouldInitBean` 一个名字）。使用者按名调用会得到静默无效的结果。
- **建议**：改为 `internal var shouldInitBean`（读取时读 `var`），`setShouldInitBean` 同步更新该 `var`；或在 README 里写清「必须在 `fboot` 初始化前通过 `--shouldInitBean=false` 传入，`setShouldInitBean` 仅供同包测试使用」。若确认无人使用，直接删掉 setter 与 `public const`，只留内部读配置。

### [一般][存量] README 的声明片段与源码不一致（`BeanDef` 构造参数顺序、`BeanInit` 缺 `const init`）

- **位置**：`README.md:341-346` 与 `README_en.md:344-349`（`BeanDef` 写成 `beanType, beanName, scope, count`）↔ `f_bean/src/BeanDefCondition.cj:108-113`（实际是 `beanType, beanName, count, scope`）；`README.md:478-483` 与 `README_en.md:483-487`（`public class BeanInit{ public init(){} }`）↔ `f_bean/src/BeanInit.cj:18-20`（`public const init(){}`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 参数与源码不符」「示例代码不能用」
- **证据**：静态确定 —— 两处逐字比对；`@Annotation` 类**必须**提供 `const init`，否则编译报错（官方文档 `docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:238`）。
- **描述**：① `BeanDef` 四个参数都是命名形参，顺序错不影响调用，但 `toString()`（`BeanDefCondition.cj:116`）打印顺序是 `type/name/count/scope`，与 README 的 `type/name/scope/count` 也不一致，读者按文档理解 `toString` 输出会错位。② `BeanInit` 片段写成普通 `init`，用户照抄定义自己的注解类会直接编译失败（应为 `public const init(){}`）。
- **建议**：README 两版同步把 `BeanDef` 的形参顺序改成 `count` 在 `scope` 前（或说明「均为命名形参，顺序无关」）；`BeanInit` 片段补 `const`。

<!-- 第 2 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [CPU] 去掉查询循环里的逐元素 `beanLog`

- **现状**：`getListByType`（`BeanFactory.cj:277`）、`getMapByType`（`:298`）、`getListByAnnotation`（`:346`）、`getMapByAnnotation`（`:367`）、`getAllTuples`（`:436`）在**每个元素**上调用 `beanLog`，而 `beanLog`（`:224-228`）是 `log.debug { ... }`，闭包捕获 4 个变量 ⇒ 每元素一次闭包分配 + 一次 `Logger.append` 级别判定。输入规模 = 返回 bean 数 × 调用次数（`lookupList`/`lookupHashMap` 在 f_mvc 等模块的启动装配与每请求路径都可能调用）。
- **方案**：用 `f_log` 已有的级别查询（`Logger.debugEnabled`）在循环外判断一次，或把逐元素日志合并成「一次调用 + 元素计数」；`getFirst*` 的命中日志保留（每次调用一条）。
- **预期**：仓库内历史测量（n = 5 万、12 个同类型 bean、min-of-4、debug 关闭且 0 行日志输出）：逐元素日志约 **325~349 ns/元素**，`lookupList` **+3903 ns/次（+42%）**、`lookupHashMap` **+4183 ns/次（+32%）**。改后应回落到与「无日志直循环」同量级。
- **代价**：日志从「每个 bean 一行」变成「每次查询一行 + 计数」；排障时看不到具体命中的 bean 名（可保留 `getFirst` 单条日志作为补充）。无 API 变化。
- **验证**：同机同 SDK `cjpm bench -O2` 对照 `lookupList`/`lookupHashMap`（中位数 + 离散程度），并统计日志行数确认语义变化符合预期。
- **证据状态**：`已有基线（.autocode/bugs/bug-bean-archived-20261006.md §3.1 BEAN-L11，2026-10-05 测量；本轮未复测）`

### [堆内存] `beanTypeMap` / `annotationMap` 的桶改用「注册期 ArrayList + 冻结后排序」

- **现状**：每个 bean 在其类型闭包的**每个节点**（`Any`/`Object` + 全部父类/接口 + 全部注解 + 元注解链）各插一个 `TreeSet<BeanManager>` 节点；`TreeSet` 每个元素约 3 个引用 + 平衡树维护开销，且注册期每次插入 `O(log n)`。启动后两张表只读（`register` 在 `registered` 后即抛异常）。
- **方案**：注册期按 `HashMap<TypeInfo, ArrayList<BeanManager>>` 追加，`afterRegistered()`（`check()` 之后）一次性 `sort()` 并把空键删掉；查询侧把 `tree.iterator()` 换成 `list.iterator()`，`TreeSet` 只用于 `discarded` 这类临时集合。
- **预期**：省掉每个（类型, bean）条目的树节点开销与插入期比较；具体字节量取决于 bean 数与闭包节点数（fdemo 规模下为千级条目），未测。
- **代价**：`beanTypeMap` 从「随时可增量插入」变成「冻结后只读」——与现有 `registered` 语义一致，但需删掉 `doRegister` 里「已注册仍可插入」的隐含能力；`BeanManager.compare`/`Comparable` 仍需保留（`discarded` 用到）。
- **验证**：fdemo 启动完成后 `getUsedHeapSize()` / `cjprof heap` 对照；同时断言查询结果集合与顺序完全一致（`TreeSet` → 排序后 `ArrayList` 必须同序）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

> 不是缺陷，是"还能更好"。每条都必须可执行、可验证。

### [堆内存] `lookupLabels` / `lookupWeights` 直接填充目标 Map，去掉中间 `ArrayList`

- **现状**：两个函数都先 `lookupList<T>(cond)` 物化 `ArrayList<T>`（N = 同类型 bean 数，`ArrayList` 从 0 容量多次扩容），再遍历它建 `HashMap` / `TreeMap`；单次调用峰值同时持有 2N 个引用（list + map），调用结束即释放。同族的 `lookupHashSet` / `lookupTreeSet` 在 `BEAN-L5` 里已经改成「直接向目标集合填充」（`lookup.cj:57-58,73`），这两个仍是旧形状。
- **方案**：与 `lookupHashSet`（`lookup.cj:59-65`）同形：`for (m in BeanFactory.instance.iterator<T>(cond: cond)) { if (let bean: T <- m.bean) { map[bean.label] = bean } }`，`lookupWeights` 在其上维护累计权重。
- **预期**：每次调用少一次 `ArrayList` 分配与 N 次 `add`/扩容，峰值引用数从 2N 降到约 N（map 本身）。收益量级待测，不写成百分比。
- **代价**：与 `lookupList` 的「元素集合、顺序、实例化次数」必须逐字一致（`iterator` 与 `getList` 共用 `iteratorByType`，现有 `bean_lookup_test` 的等价性断言可复用）；`lookupWeights` 的累计顺序依赖迭代顺序，需保证与 `getList` 同序。
- **验证**：`cjprof heap` / `getAllocatedHeapSize()` 对 10k 次调用改前改后对照，同时断言两个 Map 的键值集合与旧实现完全相同（含空结果、cond 过滤）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 启动期 `check()` 的淘汰成本接近 O(被淘汰数 × 桶数 × log n)，是启动耗时的一小段 | `f_bean/src/BeanFactory.cj:173-186` | 淘汰数与桶数的真实分布、该段占启动总耗时比例 | fdemo 启动分段计时（`afterRegistered` 前后打点）+ `cjprof record` 过滤 `check` |
| 2 | `BeanDef.on` 对每个候选 bean 调 `TypeInfos.get(t)`（`ConcurrentHashMap` 查找 + `TypeInfo ==`），`SuperOfOnly` 还要扫全量 `Object` 桶 | `f_bean/src/BeanDefCondition.cj:88-101`、`:133-145` | 条件求值次数、每次自耗时 | 在 `on(factory, typeInfo)` 加计数埋点，跑真实应用启动，统计「bean 数 × 条件数」 |
| 3 | `getListByType`/`getMapByType` 的 `ArrayList`/`HashMap` 从 0 容量扩容是查询路径的主要分配来源 | `f_bean/src/BeanFactory.cj:274-304` | 每次调用的扩容次数与分配字节数 | `cjprof heap` 对比「带容量提示」版本；需先确认 `Collection.size` 可作为容量提示 |
| 4 | 注解桶的条目数（bean × 注解 × 元注解链）显著大于类型桶，是注册期内存主体 | `f_bean/src/BeanFactory.cj:104-137` | 两张表的实际条目数与占用 | 启动后打印 `beanTypeMap`/`annotationMap` 的 `size` 之和与各值 `size` 均值，配合 `cjprof heap` |

<!-- 第 2 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 注解查询每次全桶线性扫描 + `isSubtypeOf`，注解桶大时成为查询热点 | `f_bean/src/lookup.cj:150-205`、`BeanFactory.cj:324-373` | 自耗时占比、单桶平均大小 | `cjprof record` 跑 fdemo 启动 + 每请求一次的 `lookupByAnnotation`，输入取真实 bean 数 |
| 2 | `lookupLabelOption` 的全量物化带来的构造与分配开销显著（尤其原型 bean） | `f_bean/src/lookup.cj:119-124` | 每次调用实例化个数、分配字节、ns/op | 12 个 prototype bean 场景，1 万次调用分段计时，改前/改后对照 |
| 3 | `lookupHashMap` / `lookupLabels` 的 Map 从 0 扩容是查询路径的主要分配来源 | `f_bean/src/lookup.cj:87-101` | 扩容次数与分配字节 | 对比「先用 `lookupList.size` 建容量」的版本，`cjprof heap` |
| 4 | `@Constructor` 展开的注入在启动期是「每形参一次线性扫描 + 容器重建」，bean 多时占比可观 | `f_bean/src/macros/Constructor.cj:87-121` | 启动总耗时占比 | fdemo 启动分段计时（`afterRegistered` 前后打点）+ `cjprof` 过滤 `getListByType` |

## 文件覆盖

> 与 `files/f_bean.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_bean/README.md` | .md | ✅ | — |
| 2 | `f_bean/README_en.md` | .md | ✅ | — |
| 3 | `f_bean/src/BeanCondition.cj` | .cj | ✅ | — |
| 4 | `f_bean/src/BeanConfCondition.cj` | .cj | ✅ | — |
| 5 | `f_bean/src/BeanDefCondition.cj` | .cj | ✅ | — |
| 6 | `f_bean/src/BeanFactory.cj` | .cj | ✅ | — |
| 7 | `f_bean/src/BeanInit.cj` | .cj | ✅ | — |
| 8 | `f_bean/src/BeanInitializer.cj` | .cj | ✅ | — |
| 9 | `f_bean/src/BeanLabel.cj` | .cj | ✅ | — |
| 10 | `f_bean/src/BeanManager.cj` | .cj | ✅ | — |
| 11 | `f_bean/src/BeanMeta.cj` | .cj | ✅ | — |
| 12 | `f_bean/src/BeanRelationCondition.cj` | .cj | ✅ | — |
| 13 | `f_bean/src/BeanScope.cj` | .cj | ✅ | — |
| 14 | `f_bean/src/BeanStringCondition.cj` | .cj | ✅ | — |
| 15 | `f_bean/src/BeanWeight.cj` | .cj | ✅ | — |
| 16 | `f_bean/src/Destroy.cj` | .cj | ✅ | — |
| 17 | `f_bean/src/FactoryBean.cj` | .cj | ✅ | — |
| 18 | `f_bean/src/PostConstructor.cj` | .cj | ✅ | — |
| 19 | `f_bean/src/exception/BeanException.cj` | .cj | ✅ | — |
| 20 | `f_bean/src/imports.cj` | .cj | ✅ | — |
| 21 | `f_bean/src/lookup.cj` | .cj | ✅ | — |
| 22 | `f_bean/src/macros/Bean.cj` | .cj | ✅ | — |
| 23 | `f_bean/src/macros/BeanParam.cj` | .cj | ✅ | — |
| 24 | `f_bean/src/macros/Configuration.cj` | .cj | ✅ | — |
| 25 | `f_bean/src/macros/Constructor.cj` | .cj | ✅ | — |
| 26 | `f_bean/src/macros/Value.cj` | .cj | ✅ | — |
| 27 | `f_bean/src/macros/imports.cj` | .cj | ✅ | — |
| 28 | `f_bean/src/test/bean_annotation_lookup_test.cj` | .cj | ✅ | — |
| 29 | `f_bean/src/test/bean_annotation_meta_test.cj` | .cj | ✅ | — |
| 30 | `f_bean/src/test/bean_def_condition_test.cj` | .cj | ✅ | — |
| 31 | `f_bean/src/test/bean_getfirst_test.cj` | .cj | ✅ | — |
| 32 | `f_bean/src/test/bean_iterator_test.cj` | .cj | ✅ | — |
| 33 | `f_bean/src/test/bean_lookup_test.cj` | .cj | ✅ | — |
| 34 | `f_bean/src/test/bean_scope_test.cj` | .cj | ✅ | — |
| 35 | `f_bean/src/test/bean_string_cond_test.cj` | .cj | ✅ | — |
| 36 | `f_bean/src/test/bean_test.cj` | .cj | ✅ | — |
| 37 | `f_bean/src/test/constructor_param_test.cj` | .cj | ✅ | — |
| 38 | `f_bean/src/test/generic_bean_test.cj` | .cj | ✅ | — |
| 39 | `f_bean/src/test/obj_test.cj` | .cj | ✅ | — |

合计：`.cj` 37 个 / `.md` 2 个 / 共 39 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 5（二次创建、循环依赖、`CurrentOrSuperOf`、`check` 单趟、退出销毁）；设计 1（自定义 scope 缺扩展点）；语言特性 1（`as` 返回 `Option`、`Mutex` 可重入已按文档核对后用于判定）；可读性 1（四份同构查询）；安全性 0（本部分无外部输入、无 SQL/HTML/路径拼接，`StringCond` 的正则来自调用方常量） |
| §1 死代码 | 1 | 逐个 `private`（`wrapType`/`BeanType`/`matches`/`beanLog`/`beanTypeIs`/`getFirstByType`/`getListByType`/`getMapByType`/`annotationManagers`/`generateTuple`×2）与 `internal`（`beanManagers`/`doDestroy`/`generateDestroy`/`on`/`initIfNeed`）全仓搜引用，均有调用者；`protected` 本部分为零；对外可达 `public`（`BeanManager.getBean`、`BeanScope.isPrototype`、`BeanFactory.*`）仓内无引用但不判，仅记：`getBean<T>`/`isPrototype` 全仓零调用（信息项）。唯一命中是 3 条未使用/重复 import |
| §2 重复逻辑 | 1 | 同文件内把 20 个函数体压成「输入→输出→副作用」两两比对，命中「四份同构查询」；另核对 `toString` 系列（各枚举/类各自实现，属必要样板，不算重复）、`generateTuple` 两个重载（一个有 `Option` 包装，不构成重复） |
| §3 空实现 | 0 | 唯一空函数体是 `generateDestroy` 的 `else {=>}`（`BeanManager.cj:63`）与 `Destroy`/`Resource` 都不实现时的合法 no-op，有注释语义支撑；无 `TODO`/`FIXME`/`UnsupportedException`；无 `catch {}`（本部分无 `catch`） |
| §4 栈溢出 | 1 | 命中循环依赖间接递归（见「严重 循环依赖」）；其余无递归（`BeanMeta.compare`、`StringCond.on` 均为单层） |
| §5 OOM | 1 | 命中正则缓存无界（无量化 ⇒ 轻微）；注册表只增不减已在 `bug-bean` §3.1 `BEAN-L2` 判为设计、不重复报 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据；唯一有历史测量的逐元素日志已放「优化可行性方案（CPU）」并标注数据来源，其余（`check` 淘汰、`TypeInfos.get`、容器扩容）进「待验证假设」 |
| §6.2 大粒度锁 | 0 | `BeanFactory.mutex` 只保护注册/筛选，全部发生在启动期（请求路径零锁）；`BeanManager.mutex` 是每 bean 一把，临界区内是「创建该 bean 自身」，不存在「一把锁保护多个无关资源」；锁内没有 I/O/日志/正则 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/批处理逻辑 |
| §6.4 低效算法 | 0 | 请求路径查找走 `HashMap.get` + `TreeSet` 迭代（O(1)/O(n) 且 n = 同类型 bean 数，量级极小）；`check()` 的 O(d×桶数) 与 `SuperOfOnly` 的全量扫只在启动期，已列「待验证假设」；无循环内字符串拼接、无 `remove(at:0)` 队列、无重复正则编译（已缓存） |
| §7 降堆内存方案 | 1 | 桶结构改造（无基线，标注待验证） |
| §8 降 CPU 方案 | 1 | 逐元素日志（有历史基线）；其余降 CPU 候选进「待验证假设」 |
| §9 local mode 可行性 | 0 | 不适用：`BeanFactory`/`BeanManager` 的全部对象都要长期持有并跨线程发布（逃逸明确），查询路径的临时 `ArrayList`/`HashMap` 会作为返回值逃逸；收益只能靠峰值内存证明，本部分无数据 |
| §11 现有代码的 BUG（存量） | 6 | 本轮读到 20 个文件的边界/空值/错误处理/并发/契约均过了一遍，命中：二次创建、循环依赖、`CurrentOrSuperOf`、`check` 单趟、退出销毁、`setShouldInitBean`；核对后判为非缺陷：空集合（`getList` 返回空 `ArrayList`）、`None` 处理（`?? []`/`?? BeanMeta()`/`?: None` 均为显式降级）、`addIfAbsent` 返回值语义（已查 std 文档，`Some(旧值)` 即重名 ⇒ 抛异常，符合「重名必须报错」）、`as T` 静默 `None`（前面都有类型守卫） |
| §12 并发安全与锁粒度 | 2 | 命中：①`initIfNeed`/`bean` 双写同一 `_bean`（检查-然后-写入，即「严重 二次创建」条）；②读路径（`beans`/`beanTypeMap`/`annotationMap`）完全无锁，只靠「启动后只读」的隐式契约，而 `afterRegistered` 是 `public` 且无幂等保护 ⇒ 运行期重入即与读线程竞争同一个 `HashMap`。已核对：`AtomicOptionReference.load()/store()` 均写「采用默认内存排序方式」，默认值是 `SeqCst`（std 文档 `sync/sync_package_api/sync_package_classes.md:3772` 起的 class 小节 + `sync_package_constants_vars.md` 的 `defaultMemoryOrder`）⇒ DCL 的发布语义成立，无「未构造完发布」缺陷；`Mutex` 可重入 ⇒ 自环表现为递归而非自锁 |
| §14 功能完备性与 README 覆盖 | 2 | 命中：自定义 scope 无扩展点（承诺 vs 缺失双证）、`SHOULD_INIT_BEAN_CONF_KEY` 未文档化。逐项对照公开声明后，README 未点名但已收在「其他公开 API」清单里的有 `BeanManager`（构造函数、`index`、`meta`）、`BeanFactory.register*`、`SHOULD_INIT_BEAN_CONF_KEY`；`BeanMeta` 类本身未单列（其属性在 README:13-19 的示例里完整出现），记为信息项不另报 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 逐节与 `src/` 对照，除已报的两处声明漂移外，章节/参数/默认值均一致 |

### 第 2 部分

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
| 严重 | 3 |
| 一般 | 11 |
| 轻微 | 13 |
| 其中存量 | 27 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：容器主干（注册 → 条件筛选 → 预初始化 → 查询）职责清楚，`doRegister` 的类型闭包展开、`HashMap.addIfAbsent` 的重名检测、`AtomicOptionReference + Mutex` 的每 bean 双检都属于正确实现，`BEAN-2/3/4/5/10/11/12` 这批历史优化也确实落到了代码里，注释与实现基本对得上。

阻塞项有两处，都在「生命周期」而不是「查找」上：`initIfNeed` 缺已初始化判断，会让非 lazy 单例在「启动期跨 bean 依赖」这种常规写法下被创建两次并覆盖（`postConstruct` 也执行两次）；循环依赖没有任何检测，表现为无提示的栈溢出或跨线程死锁。这两条一旦在真实应用里发生，症状（单例状态不一致、启动卡死）都很难定位，建议优先修。`check()` 的单趟淘汰、`CurrentOrSuperOf` 的语义漂移属于「功能按文档用不对」的级别，可排期；自定义 `BeanScope` 与退出销毁两条更像文档/平台契约需要收口——要么补实现，要么把承诺改成现状。

线程安全方面没有发现可以判定的数据竞争：请求路径确实零锁，前提是「启动完成后只读」，而这个前提目前只存在于代码意图里，建议在 `BeanFactory` 类注释与 README 里写成明确契约，并给 `afterRegistered` 加幂等闸门，否则这个前提不可执行。

**第 2 部分**：本部分由「查询门面 + 4 个宏 + 12 个测试文件」组成。查询门面的主体是机械转发，接口形状与 README 基本对得上；容器主干的生命周期/线程安全风险已在第 1 部分报出，这里只剩两个语义层面的问题：`lookupLabel*` 用全量物化实现「取一个」（会实例化该类型全部 bean，副作用与 `lookup<T>` 的惰性口径冲突），以及 `lookup*` 没有任何「容器已就绪」闸门（启动早期的查找会漏 bean、拿到随后被淘汰的实例，报错还指向「bean 不存在」）。这两条在真实应用里能被观察到，建议排期修。

真正薄弱的是宏。四个宏里只有一个（`@Bean`）在主路径上可用：`@Configuration`/`@BeanInit` 把配置类自身写死成 bean 类型，按文档写就编译失败；`@Constructor` 的静态工厂守卫写反，普通静态工厂被拒、泛型静态工厂放行后再生出缺类型实参的代码；`@BeanParam` 的三个属性分支分别产出类型不匹配代码、拒绝合法条件名、或恒假加越界；`@Value` 对必填 String 静默注入空串。共同原因是这批宏**全仓零使用、零用例**——`@Configuration`、`@BeanParam`、`@Value` 在仓库里找不到任何调用点，`lookupLabels`/`lookupLabel*`/`lookupWeights` 也没有任何测试，于是它们从写下那天起就没人跑通过，注释与测试注释也停在「修前」状态。修复顺序建议：先定 `@Configuration` 的取舍（补实现或删文档），再修 `@Constructor`/`@BeanParam` 的守卫与白名单（这两处是「照文档写就报错」，用户第一时间会撞上），最后补 label/weight 两族的最小用例，把 #6/#7 的语义固定下来。

测试方面，集合/Map/注解三族的行为钉得不错（含顺序、空结果、原型不误实例化），但存在永真断言、从不实例化的 bean 与描述旧行为的注释，会让后续改动误以为有覆盖。
