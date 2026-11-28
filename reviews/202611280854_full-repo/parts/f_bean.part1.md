# f_bean 模块审查报告

> **模块第 1/2 部分**：只覆盖 `files/f_bean.part1.txt` 列出的 20 个文件（`BeanFactory.cj` / `BeanManager.cj` / 条件族 / 注解与接口 / `imports.cj` / `exception/` / 两份 README）。`lookup.cj`、`src/macros/**`、`src/test/**` 由第 2 部分产出，本报告不对其下结论。

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（本部分 18 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）
- **审查重点**：Bean 容器生命周期与线程安全、注册/查找冲突语义（重名必须报错）、惰性初始化与发布逸出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 启动期 `check()` 的淘汰成本接近 O(被淘汰数 × 桶数 × log n)，是启动耗时的一小段 | `f_bean/src/BeanFactory.cj:173-186` | 淘汰数与桶数的真实分布、该段占启动总耗时比例 | fdemo 启动分段计时（`afterRegistered` 前后打点）+ `cjprof record` 过滤 `check` |
| 2 | `BeanDef.on` 对每个候选 bean 调 `TypeInfos.get(t)`（`ConcurrentHashMap` 查找 + `TypeInfo ==`），`SuperOfOnly` 还要扫全量 `Object` 桶 | `f_bean/src/BeanDefCondition.cj:88-101`、`:133-145` | 条件求值次数、每次自耗时 | 在 `on(factory, typeInfo)` 加计数埋点，跑真实应用启动，统计「bean 数 × 条件数」 |
| 3 | `getListByType`/`getMapByType` 的 `ArrayList`/`HashMap` 从 0 容量扩容是查询路径的主要分配来源 | `f_bean/src/BeanFactory.cj:274-304` | 每次调用的扩容次数与分配字节数 | `cjprof heap` 对比「带容量提示」版本；需先确认 `Collection.size` 可作为容量提示 |
| 4 | 注解桶的条目数（bean × 注解 × 元注解链）显著大于类型桶，是注册期内存主体 | `f_bean/src/BeanFactory.cj:104-137` | 两张表的实际条目数与占用 | 启动后打印 `beanTypeMap`/`annotationMap` 的 `size` 之和与各值 `size` 均值，配合 `cjprof heap` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_bean/README.md` | .md | ✅ | 与实现基本一致；见「一般 README 声明不一致」 |
| 2 | `f_bean/README_en.md` | .md | ✅ | 与中文版同步，含同样的两处声明漂移 |
| 3 | `f_bean/src/BeanCondition.cj` | .cj | ✅ | 接口 + `NoneBeanCondition`，与 README 一致；无问题 |
| 4 | `f_bean/src/BeanConfCondition.cj` | .cj | ✅ | `ConfCond` 4 个 case 与 README 一致；`Config.getString` 每次求值，启动期一次，无问题 |
| 5 | `f_bean/src/BeanDefCondition.cj` | .cj | ✅ | 见「一般 `CurrentOrSuperOf`」 |
| 6 | `f_bean/src/BeanFactory.cj` | .cj | ✅ | 见「严重 二次创建」「一般 `check` 单趟」「轻微 重复查询」「轻微 `visited`」「轻微 逐元素日志（优化）」 |
| 7 | `f_bean/src/BeanInit.cj` | .cj | ✅ | 与 README 片段不一致（缺 `const`），见「一般 README 声明不一致」 |
| 8 | `f_bean/src/BeanInitializer.cj` | .cj | ✅ | `static init` 注册 + `initialize()` 调 `afterRegistered`；与 f_app 的 Initializer 约定一致 |
| 9 | `f_bean/src/BeanLabel.cj` | .cj | ✅ | 纯接口，README 已收录，无问题 |
| 10 | `f_bean/src/BeanManager.cj` | .cj | ✅ | 见「严重 二次创建」「严重 循环依赖」「一般 自定义 scope」 |
| 11 | `f_bean/src/BeanMeta.cj` | .cj | ✅ | 默认值与 README:13-19 一致；`compare` 的并列兜底由 `BeanManager.compare` 补名字，总序成立 |
| 12 | `f_bean/src/BeanRelationCondition.cj` | .cj | ✅ | `And`/`Or`/`Not` 与 `&`/`|`/`!` 对应，无问题 |
| 13 | `f_bean/src/BeanScope.cj` | .cj | ✅ | 见「一般 自定义 scope」 |
| 14 | `f_bean/src/BeanStringCondition.cj` | .cj | ✅ | 8 个 case 与 README:205-250 一致；见「轻微 缓存无上限」 |
| 15 | `f_bean/src/BeanWeight.cj` | .cj | ✅ | 纯接口，README 已收录，无问题 |
| 16 | `f_bean/src/Destroy.cj` | .cj | ✅ | 与 README:431-439 一致；销毁调用面的问题见「一般 退出销毁路径」 |
| 17 | `f_bean/src/FactoryBean.cj` | .cj | ✅ | `typeInfo` 静态属性被 `doRegister:62-65` 使用，一致 |
| 18 | `f_bean/src/PostConstructor.cj` | .cj | ✅ | 被 `BeanManager.new():79-81` 调用，一致 |
| 19 | `f_bean/src/exception/BeanException.cj` | .cj | ✅ | 4 个构造函数齐全，`BaseException` 用法正确 |
| 20 | `f_bean/src/imports.cj` | .cj | ✅ | 见「轻微 未使用 import」「轻微 `setShouldInitBean`」 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷合计 12 条（严重 2 / 一般 5 / 轻微 5），是否纳入修复待用户决定。

## 总评

容器主干（注册 → 条件筛选 → 预初始化 → 查询）职责清楚，`doRegister` 的类型闭包展开、`HashMap.addIfAbsent` 的重名检测、`AtomicOptionReference + Mutex` 的每 bean 双检都属于正确实现，`BEAN-2/3/4/5/10/11/12` 这批历史优化也确实落到了代码里，注释与实现基本对得上。

阻塞项有两处，都在「生命周期」而不是「查找」上：`initIfNeed` 缺已初始化判断，会让非 lazy 单例在「启动期跨 bean 依赖」这种常规写法下被创建两次并覆盖（`postConstruct` 也执行两次）；循环依赖没有任何检测，表现为无提示的栈溢出或跨线程死锁。这两条一旦在真实应用里发生，症状（单例状态不一致、启动卡死）都很难定位，建议优先修。`check()` 的单趟淘汰、`CurrentOrSuperOf` 的语义漂移属于「功能按文档用不对」的级别，可排期；自定义 `BeanScope` 与退出销毁两条更像文档/平台契约需要收口——要么补实现，要么把承诺改成现状。

线程安全方面没有发现可以判定的数据竞争：请求路径确实零锁，前提是「启动完成后只读」，而这个前提目前只存在于代码意图里，建议在 `BeanFactory` 类注释与 README 里写成明确契约，并给 `afterRegistered` 加幂等闸门，否则这个前提不可执行。
