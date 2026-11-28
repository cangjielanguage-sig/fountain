# f_bean 模块审查报告（第 1/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（37 个源文件；本部分覆盖其中 15 个：`BeanCondition` / `BeanConfCondition` / `BeanDefCondition` / `BeanFactory` / `BeanInit` / `BeanInitializer` / `BeanLabel` / `BeanManager` / `BeanMeta` / `BeanRelationCondition` / `BeanScope` / `BeanStringCondition` / `BeanWeight` / `Destroy` / `FactoryBean`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，工作区干净，`git status` 仅有 `reviews/` 过程目录）⇒ 全部发现统一记「存量（无基线可比）」
- **审查重点**：Bean 容器生命周期与并发、条件求值、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本文件为第 1/3 部分，最终由主 Agent 合并为 `docs/review/f_bean_review_20261128.md`）

## 发现

### [严重][存量] `setShouldInitBean()` 对容器行为没有任何影响，公开契约实为空操作

- **位置**：`f_bean/src/imports.cj:40-44`（定义）；读点 `f_bean/src/BeanFactory.cj:196`、`f_bean/src/BeanManager.cj:70`
- **来源**：存量（`git blame -L 36,44 -- f_bean/src/imports.cj` 早于本轮全部提交）
- **判据**：review-checklist §3（公开契约承诺行为但实现不生效）/ §11（契约与实现不符）
- **证据**：静态确定 —— `shouldInitBean` 是**模块级 `let`**（`imports.cj:40`），在 f_bean 这个动态库被加载、模块全局初始化时求值一次并把结果固化；`setShouldInitBean(value)`（`:42-44`）只调用 `Config.set<Bool>([(SHOULD_INIT_BEAN_CONF_KEY, value)])`。`f_config/src/Config.cj:107-129` 的 `Config.set` 只写 `ARGS` 并向 `REFRESHER` 注册表派发回调，而全仓没有任何代码为 `shouldInitBean` 前缀调用 `Config.refresher(...)`（`/usr/bin/grep -rn "refresher(" f_*/src` 无与本键相关注册）。应用侧也没有 `main`（见 `fountain-baseline.md` §1），所有业务代码都在模块加载、即 `let` 求值之后才执行，因此 `setShouldInitBean(false)` 永远改不到已经被固化的那个 `let`。
- **描述**：调用方按 README 的公开 API 列表（`f_bean/README.md:491`）在启动早期调用 `setShouldInitBean(false)` 期望「不做急切实例化」，实际 `initBeansIfNeed()`（`BeanFactory.cj:195-203`）与 `initIfNeed()`（`BeanManager.cj:70`）读的仍是模块加载时拿到的旧值 ⇒ 所有非 `lazy` 单例照旧被创建。反过来，命令行 `--shouldInitBean=false` 是有效的（`Config` 的 `static init` 先于 f_bean 模块初始化执行），这使故障表现为「配置能关、代码关不掉」，排查时极易误判为「配置没生效」。
- **建议**：二选一 —— ① 把 `shouldInitBean` 改成每次现读 `Config.getValue<Bool>(SHOULD_INIT_BEAN_CONF_KEY) ?? true` 的 `func shouldInitBean(): Bool`（配置冷冻在启动期，读开销可忽略，且与 `fountain-baseline.md` §5「配置只在启动读」一致），`setShouldInitBean` 自然生效；② 若确认该 API 无用，则删掉 `setShouldInitBean` 并在 README 去掉，只保留命令行开关（本项目允许破坏性变更，但删公开 API 需用户拍板）。

### [一般][存量] 自定义 `BeanScope` 的生命周期维持路径不可达：实例不缓存、`generateDestroy` 为 `internal`

- **位置**：`f_bean/src/BeanManager.cj:30`（`_singleton` 字段）、`:36`（`_singleton = meta.scope.isSingleton`）、`:57-65`（`generateDestroy` 的 `internal` 可见性）、`:98-118`（`bean` getter 的 `_singleton` 分支）；`f_bean/src/BeanScope.cj:18-21`（注释承诺）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §10（设计合理性）
- **证据**：静态确定 —— `BeanScope.isSingleton`（`BeanScope.cj:38-42`）等价于 `this == BeanScope.singleton`，实现为 `typeInfo` 相等；自定义 scope 的 `typeInfo` 与 `SingletonBeanScope` 不等 ⇒ `_singleton = false` ⇒ `bean` getter 走 `:114-116` 的 `new()`，**每次取值都新建实例、从不写入 `_bean`**。因此自定义 scope 的运行期行为与 `prototype` 完全一致，`BeanScope.cj:19-20`「可以在其它模块定义新的作用范围……受自定义作用范围影响的 bean 生命周期由范围定义模块维持」所描述的扩展点在实现里不存在：外部模块既拿不到被缓存的实例，也无法调用 `generateDestroy`（`:57` 声明为 `internal`，即 `fountain::f_bean` 包内可见，`/usr/bin/grep -rn "generateDestroy" --include=*.cj` 显示全部 4 处调用都在 f_bean 包内）。仓内已有调用方按「非 singleton 即 prototype」处理：`f_llm/src/tool/FunctionMediator.cj:109,137` 直接用 `bm.meta.scope.isPrototype` 决定是否 `close`，这也印证了当前实现下自定义 scope 只能落进 prototype 语义。
- **描述**：`@BeanMeta[scope: MyScope]` 目前唯一的可观察效果是「不当作 singleton」，既不会按 scope 缓存，也没有销毁钩子可挂。下游若照着注释实现自定义 scope（例如「每请求一个实例、请求结束统一销毁」），会得到一个每次 `lookup` 都是新对象、且无法登记销毁的容器，属于静默失效。
- **建议**：要么把 `BeanManager` 的实例缓存与销毁入口真正开放给 scope（`bean` 改成委托 `meta.scope` 的 `get(manager)`/`destroy` 两个方法，`BeanScope` 提供默认实现＝现行为），要么把 `BeanScope.cj:18-21` 的注释与 README 改成「仅支持 singleton / prototype，其它 scope 等同 prototype」。前者要改 `BeanScope` 抽象类契约，属设计变更，需用户拍板。

### [一般][存量] Windows 平台上 `ExitCallbacks.atExit` 是空实现 ⇒ bean 的 `destroy`/`close` 永不执行

- **位置**：`f_bean/src/BeanFactory.cj:47`（唯一销毁注册点）；`f_base/src/signal.cj:70-76`（Windows 分支，范围外提示）
- **来源**：存量
- **判据**：review-checklist §3（空实现）/ §11（资源释放不对称）
- **证据**：静态确定 —— `f_base/src/signal.cj:68-76` 在 `@When[os == "Windows"]` 下把 `atExit` 实现为 `public static func atExit(_: UInt16, _: () -> Unit): Unit {}`，而 f_bean 的 `shutdown` 只通过 `ExitCallbacks.atExit(253, this.shutdown)` 注册，没有第二条销毁路径（全包搜 `doDestroy` 仅 `BeanFactory.cj:51` 一处调用）。fountain 模块本身跨平台（`BeanInitializer`、`BeanFactory` 均无 `@When` 限制）。
- **描述**：Windows 上进程退出时单例 bean 的 `Destroy.destroy()` / `Resource.close()` 从不被调用。表现是文件句柄、socket、连接池不释放（进程退出通常被 OS 兜底，但在「`exit()` 后仍要跑清理逻辑」「测试进程复用」等场景下可观察），且与 Linux/macOS 行为不一致，属平台相关的静默差异。
- **建议**：在 Windows 分支补一个等价机制（`std.env.atExit` 或 fboot 退出前显式调用 `BeanFactory.instance.close()`），或在 `BeanFactory` 构造时按 `@When` 选注册点；至少要在 README 里写明该平台差异。

### [一般][存量] 销毁路径三缺：无顺序保证、无异常隔离、无幂等

- **位置**：`f_bean/src/BeanFactory.cj:49-53`（`shutdown` 遍历 `beans`）；`f_bean/src/BeanManager.cj:48-52`（`doDestroy`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失、资源不对称）/ §12.1（并发：`beans` 无锁读）
- **证据**：静态确定 —— ① 顺序：`for ((_, m) in beans)` 是 `HashMap` 迭代序，与注册顺序、依赖方向均无关，`BeanManager` 也没有记录「谁依赖谁」，因此 `Resource` 之间不存在「先关被依赖者」的保证；② 异常隔离：`doDestroy` 直接 `generateDestroy(b)()`，未包 `try`，任一 bean 的 `destroy`/`close` 抛异常即中断整轮遍历，后续 bean 全部不销毁（异常还会穿透到 `ExitCallbacks.onExit` 的信号处理路径）；③ 幂等：`doDestroy` 只在 `_bean` 有值时才销毁但**不清空 `_bean`、也不置 destroyed 标记**，若 `shutdown` 与自定义 scope 的销毁（`generateDestroy` 注释所述用法）同时发生，或在信号处理里被调用两次，同一实例会被 `close()` 两次；`shutdown` 本身也不持 `mutex`，与注册/查询路径无同步。
- **描述**：三个问题同源（销毁路径没有契约），合并为一条。后果按顺序：依赖倒序错误 → 关闭已失效依赖时抛异常 → 因无异常隔离，剩下所有 bean 的资源泄漏。
- **建议**：`doDestroy` 改成 `if (let Some(b) <- _bean.load() && _bean.compareAndSwap(Some(b), None))` 保证只销毁一次（`AtomicOptionReference.compareAndSwap` 已可用，见 std.sync 文档）；销毁循环里逐个 `try { ... } catch (e) { log.error(...) }`；`shutdown` 先 `synchronized(mutex)` 取一份 `beans` 快照再遍历（不持锁调用户代码）。顺序问题若要根治需记录注册序（`index` 已有）并按 `index` 逆序销毁，可先做逆序（近似依赖倒序），依赖图另议。
- **备注**：`.autocode/bugs/bug-bean-archived-20261006.md` 里 `BEAN-L2`（`doDestroy` 不清 `_bean`）当时按「设计」判为不成立；本条不是重复报它，而是指出它与「无幂等」叠加后会产生**双重 `close()`**，属后果层面的缺陷。

### [一般][存量] `BeanFactory` 读路径全部无锁，与 `check()` / `doRegister()` 的写路径共用同一批 `HashMap`

- **位置**：读 `f_bean/src/BeanFactory.cj:204-206`（`beanManagers`）、`:236-258`（`getFirstByType`）、`:458-476`（`iteratorByType`）、`:310-312`（`annotationManagers`）；写 `:71-139`（`doRegister`，持 `mutex`）、`:165-193`（`check`，持 `mutex`，会 `beans.remove` 与两张表 `remove`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：待确认 —— 共享路径是确定的：`BeanFactory.instance` 是进程级单例（`:39`），`beans` / `beanTypeMap` / `annotationMap` 是普通 `HashMap`；写全部在 `synchronized(mutex)` 内，读**一处都没有加锁**，也没有「写完成后发布不可变快照」的动作。真正成立需要「写发生时存在并发读者」：`afterRegistered()`（`:154-163`）先把 `registered` 置 true，**再**执行 `check()`，所以 `check()` 修改三张表的整个窗口里，注册虽已关闭、读却已对任意线程开放；`InitializerCollection.doInit`（`f_app/src/Initializer.cj:79-96`）是单线程顺序执行 `initialize()`，但只要某个模块在自己的 `initialize()` 里 `spawn` 一个会 `lookup` 的线程（定时器、消费者、预热任务都属此类），就与该窗口重叠。缺少的证据是：是否存在这样的模块（需读各模块 `initialize()`，超出本部分范围）。
- **描述**：稳态（`afterRegistered` 返回后）三张表事实上只读，所以这不是常态故障；它是一段「启动期读写竞争 + 无同步」的窗口，且代码里没有任何注释或断言把这个前提固定下来，后续任何人给 `BeanFactory` 加「运行期注销/热注册」能力都会立刻踩到 `HashMap` 并发读写（`check()` 的 `beans.remove` 与读者 `tree.iterator()` 并发还会抛迭代器并发修改）。
- **建议**：① 在 `afterRegistered()` 里把三张表**原子替换成不可变快照**（`beans`/`beanTypeMap`/`annotationMap` 声明为 `AtomicOptionReference` 或加 `volatile` 语义的不可变持有者），写路径「建新表 → 整体替换 → 弃旧表」，读路径完全无锁且不再看到中间态；② 或退一步，在 `check()` 期间持 `mutex` 的同时让读路径也走 `synchronized`（会把锁带进每请求路径，不推荐）；③ 至少补一行注释 + 一个「`afterRegistered` 期间不允许 lookup」的断言/文档约束。

### [一般][存量] `BeanDef` 在「两个 Ignore」时短路 `true`，`count` / `scope` 被静默忽略（`BeanDef(count: Zero)` 恒真）

- **位置**：`f_bean/src/BeanDefCondition.cj:126`
- **来源**：存量（`BEAN-L12` 修复后留下的语义，2026-10-06）
- **判据**：review-checklist §11（契约与实现不符）/ §10
- **证据**：静态确定 —— 该 case 为 `case (IgnoreType, IgnoreCond) => return true`，在进入 `on(factory, typeInfo)` 之前直接返回，因此 `count`、`scope` 两个具名参数在默认 `beanType` / `beanName` 下**永不参与判定**。`f_bean/src/test/bean_def_condition_test.cj:65-71` 已按现状钉住：`BeanDef(count: BeanDefCount.Zero).on(factory)` 断言为 `true`。
- **描述**：`BeanDef(count: Zero)` 的语义承诺是「没有任何 bean 定义时为真」，用于「缺省兜底 bean 只在没有其它实现时注册」这一经典场景。当前实现里它恒为 `true`，兜底 bean 在任何情况下都会被注册，与业务实现同时存在（例如两个 `@Bean` 都实现同一接口，`lookupList` 里多出一个默认实现）。同理 `scope` 过滤在默认参数下失效。
- **建议**：把 `:126` 的短路条件收紧为「两个 Ignore **且** `count == AtLeastOne`（默认值）**且** `scope.isNone()`」，即只有「完全没指定任何条件」才短路；其余组合走 `_` 分支的真实筛选（`TypeInfo.of<Object>()` 桶已被证明可用）。若作者确认「`count`/`scope` 在 Ignore 类型下本就无意义」，则在 README 中显式写明，并让 `BeanDef(count: Zero)` 在构造处就报错或加 `@Deprecated`，不要让它静默恒真。

### [轻微][存量] `doRegister` 的 `visited` 未区分类节点与注解节点，极端组合下会少注册一张表

- **位置**：`f_bean/src/BeanFactory.cj:84`（`let visited = HashSet<TypeInfo>()`）、`:90-93`（去重判断）
- **来源**：存量
- **判据**：review-checklist §11（边界）/ §12.1（不是并发，是同一 `TypeInfo` 承担两种语义）
- **证据**：待确认 —— `visited` 的键是裸 `TypeInfo`，而队列里同一个 `TypeInfo` 可能是 `ClassType`（进 `beanTypeMap`）也可能是 `AnnotationType`（进 `annotationMap`）。只有当「某个类既被注册为 bean、又被别的 bean 当作注解使用」时两者才会撞车，届时后入队的节点被 `continue` 跳过，对应表缺一条。仓库内当前没有「`@Bean` + `@Annotation` 同类」的用法（`/usr/bin/grep -rn "BeanInit\|@Annotation"` 结果里无此类组合），故不定级为缺陷。
- **建议**：把去重键改成 `(isClass, klass)` 二元组（`HashSet<(Bool, TypeInfo)>`），或在 `visited` 里存两个集合分别判，代价是每节点一次元组哈希，注册期开销可忽略。

### [轻微][存量] `BeanMeta.compare` 在「仅一方 name 为空」时返回 `EQ`

- **位置**：`f_bean/src/BeanMeta.cj:41-42`
- **来源**：存量
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
- **来源**：存量
- **判据**：review-checklist §12.2（锁内调用外部回调 / 锁内日志）
- **证据**：静态确定 —— 临界区包含：遍历全部 bean、对每个 bean 调用 `BeanCondition.on(factory)`（`BeanCondition` 是 public 接口，下游可实现任意逻辑，包括再次 `lookup` 或 `Config` 访问）、以及每次丢弃的 `log.debug`。当前只在 `afterRegistered()` 里跑一次，`BeanDef`/`ConfCond` 的实现也不阻塞，因此只是「结构上把用户代码放进了锁里」。
- **建议**：`check()` 第一阶段在锁内只做「取一份 `beans` 快照」并释放锁，第二阶段在锁外求值条件、算出 `discarded`，第三阶段再进锁做三张表的删除；这样既缩短持锁时间，也避免自定义条件在锁内重入。

### [轻微][存量] `BeanDefType` 的类型名写错时抛 `InfoNotFoundException`，启动期错误定位困难

- **位置**：`f_bean/src/BeanDefCondition.cj:88-101`（`TypeInfos.get(t)` 共 5 处）
- **来源**：存量
- **判据**：review-checklist §11（错误处理/可诊断性）
- **证据**：静态确定 —— `TypeInfos.get(qualifiedName)` 未命中抛 `InfoNotFoundException`（见 `f_base/src/TypeInfos_test.cj:37` 的 `@ExpectThrows[InfoNotFoundException]`），而 `BeanDef` 的 `beanType`/`beanName` 来自注解字面量，拼错类型名是常见手误；异常在 `check()` 里抛出，栈里只有 `BeanDefType.on`，看不到「是哪个 bean 的 `@BeanMeta` 配错了」。
- **建议**：在 `BeanDef.on` 入口预解析一次类型名并包一层 `try`，转抛 `BeanException('bean condition type "${t}" not found, declared on ...')`；顺带把 `TypeInfos.get(t)` 从「每元素一次」提到 `on(factory)` 里只求一次（见待验证假设 #3）。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下两条都需先确认是否与作者的既定口径冲突（`bug-bean-archived-20261006.md` 中 `BEAN-L11` 已被作者判为「保持现状」）。

### [CPU] 去掉查询路径的逐元素 `beanLog` 闭包（有条件基线）

- **现状**：`BeanFactory.beanLog`（`f_bean/src/BeanFactory.cj:224-228`）在 `getListByType`（`:277`）、`getMapByType`（`:298`）、`getAllTuples`（`:436`）、`getFirstByType`（`:241`）里**每个元素**调用一次，每次构造一个捕获 4 个变量的 `log.debug { ... }` 闭包。已归档测量（2026-10-05，同进程同结构，n = 5 万、min-of-4、12 个同类型 bean，日志文件 `/tmp/bean_l10_mech.log`）：`lookupList` 因这笔开销 **+3903 ns/次（+42%）**、`lookupHashMap` **+4183 ns/次（+32%）**，折算 **≈325~349 ns/元素**，且该环境 debug 关闭、`BeanFactory.getAll:` 实际输出 0 行 —— 开销与「是否真的打日志」无关。
- **方案**：二选一 —— ① 用 `f_log` 的级别查询把调用点包起来（`Logger.debugEnabled`，见 `f_log/src/base/Logger.cj`），关闭时连闭包都不构造；② 逐元素日志降级为「本次查询命中 N 条」的单条汇总日志（`getFirst` 命中点只保留 1 条）。
- **预期**：按上述基线，`lookupList` / `lookupHashMap` 端到端约 -30%~-42%（该路径即全部耗时，Amdahl 上限＝该占比）。
- **代价**：日志粒度变粗（排障时看不到逐 bean 命中）；方案 ① 依赖 `f_log` 暴露级别查询 API，需确认该 API 的语义与线程安全。
- **验证**：`cjpm bench -O2`，同进程同结构、n = 5 万、min-of-4 中位数对照，grep 日志确认输出行数不变。
- **证据状态**：`已有基线（2026-10-05 归档测量：lookupList +3903 ns/次、lookupHashMap +4183 ns/次，≈325~349 ns/元素，n=5 万）`；**注意**作者已在 `BEAN-L11` 判「保持现状」，本条需重新拍板后才进 `tasks.md`。

### [堆内存] `getList` / `getMap` 结果容器预留容量、`check()` 去重集合按需分配（无基线）

- **现状**：`getListByType`（`BeanFactory.cj:274-283`）与 `getMapByType`（`:295-304`）都从容量 0 的 `ArrayList` / `HashMap` 开始，逐元素扩容复制；`check()`（`:166-172`）为每次启动新建两个 `HashSet<TypeInfo>` 与一个 `TreeSet<BeanManager>`。
- **方案**：遍历前用桶的 `size` 预分配（`TreeSet.size` 为 O(1)），`ArrayList<T>(n)` / `HashMap<String, T>(n)`；`check()` 的 `typeRemoved` / `annotationRemoved` 改成「移除后立即判空删除」，省掉两个集合。
- **预期**：每 1000 条结果省 1~2 次扩容复制（≈数 KB 临时堆 + 一次数组拷贝），对启动期的 `check()` 省两次哈希集合。收益量级在 KiB，**未测量**。
- **代价**：需读桶的 `size`（`iteratorByType` 目前直接返回 `Iterator`，要拆成「先取桶再遍历」两条路），代码复杂度略升；与 `BEAN-L10` 的既有取舍（作者明确「`getList` 的扩容未动，需容量提示、会引入内部 API 依赖」）冲突。
- **验证**：`getAllocatedHeapSize()` + 分配次数埋点，n = 1 万~10 万对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getFirst<T>()` 命中路径每次请求付 1 次 `beanLog` 闭包分配（`f_mvc` 每请求调用一次） | `f_bean/src/BeanFactory.cj:236-258`、`:224-228` | 单次 `getFirst` 的自耗时与闭包分配占比 | `cjprof record` 跑 10k 次 `lookup<T>()`，对比「有 `beanLog` / 注释掉 `beanLog`」两版；同时看 `getAllocatedHeapSize()` 增量 |
| 2 | `check()` 的清理是 O(被丢弃数 × 两张表条目数)，启动期 bean 多时成启动瓶颈 | `f_bean/src/BeanFactory.cj:176-186` | 启动期该函数自耗时占比（需 bean 数量级数据） | 在有 500+ bean 的应用（fdemo）里对 `afterRegistered()` 分段计时，拆出 `check()` 耗时 |
| 3 | `BeanDefType.on` 每个元素都调一次 `TypeInfos.get(全限定名)`（字符串→`TypeInfo`） | `f_bean/src/BeanDefCondition.cj:88-101` | 单次 `TypeInfos.get` 耗时与调用次数（每条件 × 每 bean） | 启动期埋点计数 + `cjprof` 看 `TypeInfos.get` 自耗时 |
| 4 | `WILDCARD_REGEX` / `REGEX_CACHE` 的命中率接近 100%（键空间＝代码声明条件数） | `f_bean/src/BeanStringCondition.cj:81-82` | 实际键数量与命中率 | 加计数埋点，跑 10 分钟稳态负载后打印两个 map 的 `size` |

## 覆盖自检

### 文件逐条结论（本部分 15 个文件）

| 文件 | 结论 |
| --- | --- |
| `BeanFactory.cj` | 核心容器。发现：读/写路径无同步（§12.1）、销毁路径三缺、`visited` 跨节点类型去重、注解/类型查询族重复、锁内求值外部条件；并发正确性在稳态依赖「注册后只读」的隐含前提 |
| `BeanManager.cj` | 发现：自定义 scope 无缓存路径、`generateDestroy` 可见性与注释不符、`doDestroy` 无幂等。双检锁（`_bean` + `mutex`）本身正确（`AtomicOptionReference` 提供原子读写） |
| `BeanScope.cj` | `isSingleton`/`isPrototype` 基于 `typeInfo` 相等，语义清晰；问题见上条（自定义 scope 无落点）。无死代码、无并发写 |
| `BeanCondition.cj` | 接口 + `NoneBeanCondition`（有意的 Null Object，已注释）；`&` / `\|` / `!` 三个算符为对外扩展点 |
| `BeanConfCondition.cj` | `ConfCond` 四个 case 全分支实现，无空实现；每次 `on` 读 `Config`（启动期一次，非热路径） |
| `BeanDefCondition.cj` | 发现：两个 Ignore 时忽略 `count`/`scope`；`TypeInfos.get` 未命中抛 `InfoNotFoundException` 而非 `BeanException`（错误信息不友好）。`on(factory, typeInfo)` 的 count 判定分支无逻辑错（`Zero`/`OnlyOne`/`MoreThanOne` 的提前返回均正确） |
| `BeanInit.cj` | 纯标记注解，无逻辑；`@BeanInit` 由 `f_bean/src/macros` 消费（第 2/3 部分） |
| `BeanInitializer.cj` | 结构正确：`static init` 注册自身，`initialize()` 调 `afterRegistered()`；无重复注册路径 |
| `BeanLabel.cj` | 纯接口，无问题 |
| `BeanMeta.cj` | 发现：`compare` 在「仅一方 name 为空」时返回 `EQ`；其余字段无逻辑 |
| `BeanRelationCondition.cj` | `AndCond`/`OrCond`/`NotCond` 三件套实现正确（`&&` / `\|\|` 短路语义符合注释）；与 `BeanCondition` 的算符默认实现配套，无重复 |
| `BeanStringCondition.cj` | 发现：两个正则 memo 表无容量上限；`==` 与 `toString` 的 case 表重复但属枚举展开，可读性可接受 |
| `BeanWeight.cj` | 纯接口，无问题 |
| `Destroy.cj` | 纯接口，无问题 |
| `FactoryBean.cj` | 接口 + `static prop typeInfo`；`doRegister` 里通过 `TypeMemberInfos.staticProperty` 取真实类型（`:61-69`），逻辑正确 |

### 维度自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：`setShouldInitBean` 无效、销毁三缺、`BeanDef` 忽略 count（3 条已单列）；设计：自定义 scope 落点缺失（已单列）；语言特性 0：`let`/`mut`/`Option` 用法规范，`Option` 均用 `if (let Some(x) <- ...)` 展开，无静默丢弃；可读性：15 个文件命名与注释（含 §3.1 性能注释）清楚，无超深控制流；安全性：本部分无外部输入解析、无 SQL、无凭据、无日志泄露敏感字段（`beanLog` 只打类型名/条件/bean 名） |
| §1 死代码 | 0 | 已逐个机械核对：`BeanFactory` 的 `BeanType`/`wrapType`/`shutdown`/`doRegister`/`check`/`initBeansIfNeed`/两个 `matches`/`beanTypeIs`/`beanLog`/`getFirstByType`/`getListByType`/`getMapByType`/`iteratorByType`/`annotationManagers`/三个注解查询私有重载/两个 `generateTuple` 均在文件内或包内有引用；`internal` 的 `beanManagers`（`BeanFactory.cj:204`）被 `BeanDefCondition.cj:135` 调用，`doDestroy`/`generateDestroy`/`on`/`initIfNeed` 均被 `BeanFactory` 调用；无 `protected` 声明；无「`return` 后同层语句」；局部变量 `requiredType`/`list`/`map`/`tree` 均被读取。`public` 且对外可达的声明（`BeanFactory.instance`、`getFirstTuple`、`getAllTuples`、`getBean<T>`、`register*`、`lookupByAnnotationOnly` 族、`BeanScope.isPrototype` 等）按硬原则一不判死代码；`isPrototype` 确有仓内引用（`f_llm/src/tool/FunctionMediator.cj:109,137`），仅作信息 |
| §2 重复逻辑 | 1 | 已把 15 个文件的函数体压成「输入→输出→副作用」两两比对。命中 1 条：注解查询三件套（`getFirstByAnnotation` `:326` / `getListByAnnotation` `:345` / `getMapByAnnotation` `:366`）的过滤谓词与遍历结构完全相同，只有收集方式不同（返回值 / `add` / `put`），可抽成「返回 `Iterator<BeanManager>` 的私有过滤函数」；`getFirstByType`/`getListByType`/`getMapByType`/`iteratorByType`（`:236`/`:274`/`:295`/`:458`）同构但**已在注释里明确是 `BEAN-L10` 的反抽象性能取舍**，且各自路径的校验次数不同，不按重复计；`BeanScope` 的 `PrototypeBeanScope`/`SingletonBeanScope` 与 `BeanStringCondition` 的 `toString`/`==` case 表属「只改类型名/枚举展开」，为可读性刻意展开，不算重复 |
| §3 空实现 | 2 | 命中：`setShouldInitBean`（无效 API，已单列）、Windows 的 `ExitCallbacks.atExit`（已单列）。其余空体均属有意：`NoneBeanCondition.on` 恒 `true` 且注释说明是占位 Null Object；`BeanManager.generateDestroy` 的 `{=>}` 是「bean 无销毁契约」的正常分支；`BeanInit`/`Destroy`/`FactoryBean`/`BeanLabel`/`BeanWeight` 是纯标记/纯接口 |
| §4 栈溢出 | 0 | 15 个文件内无递归：`doRegister` 用显式 `LinkedList` 队列 + `visited` 环检测（`BeanFactory.cj:76-138`），`check`/`shutdown` 都是单层遍历；`BeanDefType.on` 的正则/类型比较不递归。潜在递归只在 `TypeInfos.get`（`f_base`，范围外） |
| §5 OOM | 1 | 命中：`WILDCARD_REGEX`/`REGEX_CACHE` 无容量上限（已单列，定为轻微）。其余无界面已核：`beans`/`beanTypeMap`/`annotationMap` 的键空间＝代码声明的 bean 与类型数（有界、注册后冻结）；`visited` 是每次注册的局部集合；无「按报文长度预分配」、无全量物化（`getList` 物化的是 bean 列表，规模由 bean 数决定） |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile / bench 数据；唯一有数据的是逐元素 `beanLog`（来自归档实测），已写成「优化可行性方案」并标注作者曾判「保持现状」；`getFirst` 的 `beanLog`、`check()` 的清理复杂度进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 唯一的 `synchronized` 在 `doRegister`/`check`，均在启动期一次性执行，`check` 内求值条件与打日志见「轻微」条（§12.2）；运行期热路径（`bean` getter 的 `mutex`）临界区仅「新建实例 + 存原子引用」，无 I/O、无日志、无回调，属于必要的最小临界区（`new()` 必须只跑一次） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无批处理、无单消费者队列；`initBeansIfNeed` 顺序初始化 bean，属启动期串行且有明确语义（依赖顺序） |
| §6.4 低效算法 | 1 | 命中（轻微）：`check()` 对每个被丢弃 bean 全量遍历两张表再 `set.remove`，复杂度 O(丢弃数 × 表条目数)；启动期一次性、bean 量级有限，未达「缺陷」门槛，见「待验证假设 #2」。其余查找走 `HashMap`/`TreeSet`，无循环内 `contains`、无 `remove(at: 0)` |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 [堆内存]」；`clear()`/`gc()` 类假象不涉及 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 [CPU]」（逐元素 `beanLog`，有既有基线） |
| §9 local mode 可行性 | 0 | 无函数内大临时对象：`doRegister` 的临时集合规模 = 类型闭包（几十个元素），`getList`/`getMap` 的返回值要逃逸给调用方（不满足不逃逸前提），`beanLog` 的闭包被 `log.debug` 捕获后逃逸。收益无法用峰值内存证明 ⇒ 不成立 |
| §11 现有代码的 BUG（存量） | 8 | 本部分读到的 8 处边界/契约问题已逐条核对并单列：`setShouldInitBean` 无效、自定义 scope 落点缺失、Windows 销毁缺失、销毁三缺、`BeanDef` 忽略 count、`BeanMeta.compare` 空名判 EQ、`doRegister` 的 `visited` 跨节点类型去重、`BeanDefType` 抛 `InfoNotFoundException`。`getFirstByType` 的「桶内子类型复检恒真」推理已复核成立（`beanTypeIs` 保证 `beanType ⊆ T`），不是缺陷 |
| §12 并发安全与锁粒度 | 2 | 命中：读路径无锁 vs 启动期写（一般，待确认是否存在并发读者）、`check()` 锁内求值外部条件 + 打日志（轻微）。已核的安全点：`BeanManager.bean` 的双检锁正确（`AtomicOptionReference` 原子读写 + `mutex` 保护 `new()` 单次执行）；`_name`/`_singleton`/`meta`/`beanType` 构造后不可变、随构造发布；`registered` 用 `AtomicBool`；`TreeSet`/`HashMap` 在稳态只读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

> 存量 12 条（严重 1、一般 5、轻微 6），本轮全部为存量，无「本次改动」引入项；是否纳入修复待用户决定。

## 总评

这 15 个文件是 f_bean 的容器骨架，整体实现是清醒的：注册期用显式队列 + `visited` 做类型闭包展开（避免递归与环），查询期用「注册期预建超类型桶 + 运行期只做名字过滤」把每请求查找压到一次 `HashMap.get` + 一次遍历，双检锁、原子引用、条件组合算符都用对了；`Option` 没有一处被静默丢弃，也没有空 `catch`。

主要风险集中在**生命周期契约**而不是查找逻辑：`setShouldInitBean()` 是彻底无效的公开 API（严重，容易让运维以为「配置已生效」）；自定义 `BeanScope` 的实例缓存与销毁入口在实现上不存在（注释承诺了能力却没给出落点）；Windows 上 `ExitCallbacks.atExit` 为空使 `destroy`/`close` 永不执行；销毁路径同时缺顺序、异常隔离与幂等——这三条叠加后，一个 bean 的 `close()` 抛异常就会让其余资源全部不释放。这些都不在每请求热路径上，属于「启动/退出时暴露、排查成本高」的类型，建议优先修 `setShouldInitBean` 与销毁三缺（改动小、语义明确），`BeanScope` 扩展点需要设计拍板后再动。

并发方面：稳态是安全的（注册后三张表只读、实例发布走原子引用），但「读无锁、写持锁」的正确性依赖「`afterRegistered` 期间没有并发读者」这一未写入代码的前提，且 `check()` 在锁内求值用户自定义条件；建议至少把它变成不可变快照发布，而不是留一个隐式的时序假设。性能上本轮没有新热点结论；唯一有数据的是逐元素 `beanLog`（≈325~349 ns/元素，`lookupList` +42%），已在归档里被作者判「保持现状」，这里只作为待拍板的优化项保留，不进修复清单。
