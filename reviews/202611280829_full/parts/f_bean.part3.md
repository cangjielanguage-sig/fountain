# f_bean 模块审查报告（第 3/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（37 个源文件；本部分覆盖其中 7 个，全部位于 `src/test`：`bean_lookup_test` / `bean_scope_test` / `bean_string_cond_test` / `bean_test` / `constructor_param_test` / `generic_bean_test` / `obj_test`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git log` 顶部 `8c0ce643a`，工作区干净，仅有 `reviews/` 过程目录）⇒ 全部发现统一记「存量（无基线可比）」
- **审查重点**：测试覆盖反向验证（漏断言 / 空断言 / 用例名与实测路径不符）、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1（本文件为第 3/3 部分，最终由主 Agent 合并为 `docs/review/f_bean_review_20261128.md`）

## 发现

### [一般][存量] `bean_test.cj` 唯一的用例零断言，`@Constructor` 非集合形参注入链路没有任何守护

- **位置**：`f_bean/src/test/bean_test.cj:23-27`（`test()`）；被守护的夹具 `f_bean/src/test/obj_test.cj:21-35`（`A` / `B`）；生成侧 `f_bean/src/macros/Constructor.cj`（非集合形参 → `lookup<A>()`）
- **来源**：存量（`git blame -L 23,27 -- f_bean/src/test/bean_test.cj` → `4be871f2fd` 2026-10-02，仅换行符统一）
- **判据**：review-checklist §3（空实现：契约承诺有行为、断言为空）/ §10（可测试性）/ §11（契约未验证）
- **证据**：静态确定 —— `getFirst<B>()` 返回 `?B`，用例只 `println(b)`，既不断言 `isSome()`，也不读 `b.getOrThrow().a`，更不校验 `toString()` 文本。把 `B` 的 `@Bean` 注解删掉（b 变 `None`）、把 `@Constructor` 换到另一个形参、或让 `a` 注入成别的 `A` 实例，本用例都照样绿（删注解时输出 `None`，构造失败时才抛异常）。全仓 `B` 只在此处被查询一次（`grep -rn "getFirst<B>" f_bean/src` 仅 `bean_test.cj:25`），没有任何第二道防线。
- **描述**：`obj_test.cj` 是仓内唯一覆盖「`@Constructor` + 单个非集合形参」的夹具（集合/Option 形态由 `constructor_param_test` 覆盖，静态工厂分支见第 2/3 部分），而它唯一的消费者是一条只打印的用例。`@Constructor` 的 `lookup<A>()` 生成路径因此处于「能编译即视为通过」的状态：注入的是不是**那一个** `A`、`B.a` 是否可空，都没有断言。
- **建议**：补三条断言 —— `@Assert(b.isSome(), true)`、`@Assert(b.getOrThrow().a is A, true)`（或与 `lookup<A>()` 的返回值 `refEq`）、`@Assert(b.getOrThrow().toString(), 'B(A)')`；用例名改成 `testConstructorInjection`，避免与模块名同名却什么也不验。

### [一般][存量] `testEagerBeanCreatedAtMostOnce` 从未走到"启动期预初始化"路径，实质与 `testSingletonScopeSemantics` 重复

- **位置**：`f_bean/src/test/bean_scope_test.cj:86-95`；被依赖的实现 `f_bean/src/BeanManager.cj:69-76`（`initIfNeed`）、`f_bean/src/BeanFactory.cj:154-163`（`afterRegistered`）、`:195-203`（`initBeansIfNeed`）
- **来源**：存量（`git blame -L 86,95` → `04559fc2c` 2026-10-05，`BEAN-5` 补用例时新增）
- **判据**：review-checklist §2（语义相同的重复用例）/ §10（可测试性）/ §11（语义与命名不符）
- **证据**：静态确定 —— 全仓 `afterRegistered()` 的调用点只有 `f_bean/src/BeanInitializer.cj:29`（`initialize()` 里），而测试进程没有任何代码调用 `InitializerCollection.initialize()` 或 `afterRegistered()`（`grep -rn "afterRegistered\|InitializerCollection.initialize" f_bean/src/test` 零命中）；同包 `bean_def_condition_test.cj:45,110` 的注释已把这一点写成前提：「测试进程**从不调用** `BeanFactory.afterRegistered()`」。因此 `initBeansIfNeed()` 不执行，`@BeanMeta[lazy: false]` 对 `ScopeEagerBean` 在本进程内不产生任何效果，实例是 `getFirst` 时按单例懒建的。
- **描述**：用例名声明验证「eager bean 最多创建一次」，实际验证的是「单例缓存命中」——后半段 `@Assert(refEq(p1, p2), true)` 与 `testSingletonScopeSemantics`（`:48-52`）判定同一件事；`@Assert(afterFirst >= 1, true)` 也无法区分 1 次与 N 次构造（若 `initIfNeed` 在别处被多调一次，`created` 变 2 仍通过）。`lazy: false` 与 `afterRegistered → initBeansIfNeed → initIfNeed` 这条链路在整包测试里只有 `testInitIfNeedJudgement` 直接调 `initIfNeed` 覆盖了一段，`afterRegistered` 本身零覆盖。
- **建议**：把断言换成确定值 `@Assert(afterFirst, 1)`；若要真验启动期路径，放一个独立用例（或 `cjpm test --filter` 单跑）显式 `BeanFactory.instance.afterRegistered()` 后再断言 `created.load() == 1` —— 注意 `afterRegistered` 会执行 `check()` 并丢弃条件 bean，必须与其它用例隔离进程。否则把用例改名为 `testSingletonCacheReuse`，避免给出"eager 已验证"的错觉。

### [一般][存量] `initIfNeed()` 无幂等保护：只要条件成立就覆盖已有单例，重复调用会丢实例且不销毁

- **位置**：`f_bean/src/BeanManager.cj:69-76`；可重复触发的入口 `f_bean/src/BeanFactory.cj:154-163`（`afterRegistered` 是 `public` 且每次都无守卫地调 `check()` + `initBeansIfNeed()`）
- **来源**：存量（`git blame -L 69,76` 早于本轮全部提交；`afterRegistered` 同）
- **判据**：review-checklist §11（资源释放不对称 / 缺幂等）/ §12.1（检查-然后-写入：`_bean.load()` 未参与判定）
- **证据**：静态确定（机制）—— `if (shouldInitBean && !meta.lazy && _singleton) { _bean.store(new()); true }`，判断条件里没有「`_bean` 已存在则跳过」；`_bean` 是 `AtomicOptionReference`，`store` 直接覆盖。销毁只在进程退出时由 `doDestroy` 对**当前** `_bean` 执行一次，被覆盖的旧实例既不 `destroy` 也不 `close`。待确认（触发路径）—— 正常启动只调一次 `afterRegistered()`，需确认是否有下游（fboot 引导、测试、热重启）重复调用。
- **描述**：`bean_scope_test.cj:81` 就在同一进程里对同一个 `eagerMgr` 调了两次 `initIfNeed()`，第二次把第一次存的实例换掉——用例因为只比较返回值而没有察觉。真实后果有两条：① 重复 `afterRegistered()` 会把**所有**非 lazy 单例重建一遍，`PostConstruct` 已初始化的状态丢失、`Resource` 句柄泄漏；② 若某个 eager 单例在 `afterRegistered()` 之前已被 `lookup` 取走并注入到别的 bean，之后 `initIfNeed` 覆盖容器内的引用，同一类型在进程里出现两个活实例，注入方持有旧的那个。
- **建议**：`initIfNeed` 加存在性判断 —— `if (let Some(_) <- _bean.load()) { false } else { _bean.store(new()); true }`；`afterRegistered` 头部用 `if (!registered.compareAndSwap(false, true)) { return }` 做一次性守卫（现在是无条件 `registered.store(true)`，没有「已初始化」判定）。注意本条与第 1/3 部分「销毁路径三缺」③ 不是同一条：那条针对 `doDestroy` 的幂等，本条针对 `initIfNeed` 的重复构造。

### [轻微][存量] `bean_scope_test` 的「重复调用结果稳定」断言含自证分支，配置一变即恒真

- **位置**：`f_bean/src/test/bean_scope_test.cj:80-81`
- **来源**：存量（`git blame -L 80,81` → `04559fc2c` 2026-10-05）
- **判据**：review-checklist §3（空断言）/ §11（判据与断言不符）
- **证据**：静态确定 —— `@Assert(inited == eagerMgr.initIfNeed() || !inited, true)`：当 `inited == false` 时左项为 `false == 第二次返回值`，右项 `!inited` 恒 `true`，整个表达式恒真。`inited` 取 `false` 只需要 `shouldInitBean` 为假（`f_bean/src/imports.cj:40` 从 `Config` 读，默认 `true`，命令行可改），此时该用例对 `initIfNeed` 的重复调用**不做任何校验**。
- **描述**：同一用例的核心语义（「非 lazy 单例的 `initIfNeed` 返回 true 且可重复调用」）被一个 `||` 兜底成了"要么真校验、要么静默通过"。而它本来要守的正是上一条的 `initIfNeed` 行为，两者叠加使这个风险点完全无守护。另外 `:82-83` 的 `refEq(x, eagerMgr.bean)` 对单例恒真，也不构成对第二次 `initIfNeed` 的检查。
- **建议**：改成 `@Assert(inited, true)`（测试进程默认 `shouldInitBean == true`，成立；若担心配置，用例开头显式断言 `shouldInitBean` 的前提而不是把它降级成恒真）；再补一句 `let first = eagerMgr.bean` 后 `@Assert(refEq(first, eagerMgr.bean), true)`，把"第二次调用不替换实例"写成真断言（配合上一条修复）。

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
- **描述**：`bean_string_cond_test` 自己只声明了 2 个 bean（都在 `bean_getfirst_test.cj`），却断言整个包内 `BeanTestAnimal` 的实现恰好 2 个。往任何新测试文件里加一个 `BeanTestAnimal` 实现，这条断言就红，而失败点看起来像 `StringCond` 坏了。三个文件各自重复同一套模式字面量，改包名或改夹具名要同步改 4 处。
- **建议**：把 `BeanTestAnimal/Dog/Cat` 与模式常量集中到 `f_bean/src/test/fixtures.cj`（同包即可，不需要新模块），数量断言改成由夹具常量推导（如 `DOG.name`/`CAT.name` 组成集合后比对），或在 `bean_string_cond_test` 里改成断言"命中集合包含 dogName 且不含 catName"，去掉对全包规模的依赖。

### [轻微][存量] `StringCond` 8 个 case 只测了 3 个，`toString` / `ignored` / 两种 `==` 零断言

- **位置**：被测实现 `f_bean/src/BeanStringCondition.cj:75-110`；用例 `f_bean/src/test/bean_string_cond_test.cj:40-60`
- **来源**：存量
- **判据**：review-checklist §10（可测试性）/ §11（契约未验证）
- **证据**：静态确定 —— 全 `f_bean/src/test` 搜 `Prefix(` / `Suffix(` / `Contains(` / `In(`（`StringCond` 语境）零命中；`IgnoreCond` 只作为 `BeanDef(beanName: IgnoreCond)` 的参数出现（`bean_def_condition_test.cj:64-71`），它的 `on()` 恒 `true` 从未被断言；`ignored`（`:87-94`）、`toString()`（`:62-73`）、`operator func ==`（`:95-110`）没有任何用例。已覆盖的只有 `Wildcard` / `Regexp` / `Exactly`（且 `Exactly` 是在 `bean_getfirst_test` 里顺带覆盖）。
- **描述**：`Contains(v)` 是 `s.contains(v)`、`In(v)` 是 `v.contains(s)`（方向相反），是本枚举里最容易写反的一对，恰恰两条都没有用例；`==(StringCond)` 被 `BeanDefCondition` 等按值比较的地方依赖，写错也不会被发现。
- **建议**：给 8 个 case 各一条表驱动断言（输入串 / 期望布尔），加上 `@Assert(Exactly('a') == 'a', true)`、`@Assert(IgnoreCond.ignored, true)`、`@Assert(Wildcard('a*').toString(), 'Wildcard(a*)')`。总量约 10 行。

### [轻微][存量] 基准代码继续留在单元测试（本部分新增一处，与第 2/3 部分同根因合并）

- **位置**：`f_bean/src/test/bean_string_cond_test.cj:62-88`（30 万 × 2 次 `on`）；同根因的既有位置 `bean_getfirst_test.cj:94-114`、`bean_iterator_test.cj:83-154`（已由第 2/3 部分单列）
- **来源**：存量（`git blame -L 62,88` → `e9ed1e9cb` 2026-10-05）
- **判据**：review-checklist §10（可维护性）/ `fountain-baseline.md` §8（基准必须 `-O2`）
- **证据**：静态确定 —— 计时结果只 `println`，断言的是命中次数 `ok == n * 2`，与耗时无关；`cjpm test` 默认 `-O0`，打印的 ns/op 无跨版本对照价值。`ms1` 为 0 时 `ns/op` 打印 0，说明该数字本身也不做自检。
- **建议**：与第 2/3 部分的建议一致 —— 计时段移到 `bench/`、`cjpm bench -O2`；单测保留 `testMatchingAndRegistryIntegration` 的行为断言即可。

### [轻微][存量] `@Assert(false, true)` 被当作"强制失败"使用，语义不直观

- **位置**：`f_bean/src/test/bean_lookup_test.cj:227-231`
- **来源**：存量（`git blame -L 227,231` → `9981e6e40` 2026-10-05）
- **判据**：review-checklist §10（可读性）
- **证据**：静态确定 —— `@Assert(left, right)` 在本仓统一用作等值断言（同文件 `@Assert(list.size, 12)`、`@Assert(seen, 78)`），`false == true` 必然失败，读者需要先反推"这是故意的失败分支"。
- **建议**：改成 `@Fail('bean ${name} 查不回来')`（unittest 提供），或直接用 `@Assert(found.isSome(), true)` 消掉 else 分支。

### [轻微][存量] `generic_bean_test` 的夹具从未被取用，多组泛型只验证了第一组，且存在未读取的局部变量

- **位置**：`f_bean/src/test/generic_bean_test.cj:26-35`（`AbstractBean` / `TestBean1` / `TestBean2` / `TestBean`）、`:41`（`let bean` 赋值后不读）
- **来源**：存量（`git blame -L 26,35` 与 `-L 41` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §1（局部变量赋值后未读取；无使用符号）/ §10（可测试性）
- **证据**：静态确定 —— 全仓 `grep "TestBean1|TestBean2|AbstractBean"` 只命中 `generic_bean_test.cj` 的定义处；`TestBean` 从未被 `getFirst`/`lookup` 取过，因此它那两个 `private let` 字段的初始化器（`lookup<TestGenericBean<String>>()`、`lookupList<AbstractBean>()`）在本进程内从未执行；`@Bean[String|Int64]` 只查过 `TestGenericBean<String>`，`Int64` 组注册后无人查询。`let bean` 是 §1 的"读了不用"（编译器只会给告警）。
- **描述**：这 4 个类型是 `@Bean` 泛型注册、父类桶（`AbstractBean` 桶）的现成夹具，但没有任何断言用到它们；`test1` 里唯一有效的信息是"`lookup<TestGenericBean<String>>()` 不抛异常"（缺注册时抛 `BeanException` 会让用例变 ERROR），属于隐式断言。
- **建议**：把夹具用起来 —— `@Assert(lookup<TestGenericBean<Int64>>() is TestGenericBean<Int64>, true)` 覆盖第二组实参、`@Assert(BeanFactory.instance.getList<AbstractBean>().size, 2)` 覆盖父类桶、取一次 `TestBean` 验证字段注入不递归；`let bean` 要么加断言要么删掉。按硬原则一，这些 `public` 类型不判死代码，此处只作"未使用夹具"记录。

## 优化可行性方案

本部分 7 个文件全部是测试代码，没有运行期产品代码进入优化面。唯一可执行项是"基准段移出单测"（已作为缺陷计入上面第 8 条，属测试工程化，不计入 CPU / 堆内存方案）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 4 处基准用例（30 万 / 30 万×2 / 6 万×29）显著拉长 `cjpm test`，且 `-O0` 下的 ns/op 无对照价值 | `test/bean_getfirst_test.cj:94-114`、`test/bean_iterator_test.cj:83-154`、`test/bean_string_cond_test.cj:62-88` | 各 `@TestCase` 的耗时与整套测试占比 | `cjpm test --filter <用例名>` 单独跑，与整套耗时对比；再用 `cjpm bench -O2` 同输入复测 ns/op |

## 覆盖自检

### 文件逐条结论（本部分 7 个文件）

| 文件 | 结论 |
| --- | --- |
| `test/bean_lookup_test.cj` | 覆盖 `lookupList`/`lookupHashSet`/`lookupTreeSet`/`lookupHashMap` 的元素集合、`TreeSet` 升序、`cond` 透传、空结果、`getMap` 名称键往返、连续两次调用顺序稳定；12 个 `LookupItem` 夹具的 `code == order` 与 `compare`/`hashCode` 自洽，断言值（12 / 78）与夹具一致。问题：`@Assert(false, true)`（轻微）；`lookupLabels`/`lookupWeights`/`lookupLabelOption` 零覆盖（第 2/3 部分的键冲突缺陷仍无回归防线，属该条已列缺口的补充说明） |
| `test/bean_scope_test.cj` | `testSingletonScopeSemantics` / `testPrototypeScopeSemantics` / `testCustomScopeInstanceTreatedAsSingleton` / `testInitIfNeedJudgement` 的判定逻辑与 `BeanManager._singleton`、`initIfNeed` 实现一致。问题：`testEagerBeanCreatedAtMostOnce` 走不到 eager 路径（一般）、`:81` 自证断言（轻微）。附注：本文件用 `AtomicInt64` 与 `SingletonBeanScope()` 都未显式 import，只因子包能见到父包 `imports.cj:24` 的 `internal import` 与 `internal const init` —— 把测试移出 `fountain::f_bean` 子包即编译失败 |
| `test/bean_string_cond_test.cj` | `Wildcard`/`Regexp` 命中、不命中、重复求值一致、与注册表联用（`getList`/`getFirst`）都有断言，能真正抓住 memo 缓存的键错配（键忽略 pattern 时 `wildMiss` 会变 true）。问题：5/8 枚举 case 与 `toString`/`ignored`/`==` 零覆盖（轻微）、夹具跨文件耦合 + 字面量重复（轻微）、基准段留在单测（轻微） |
| `test/bean_test.cj` | 唯一用例零断言（一般）。文件本身只剩"B 能被构造出来"的信号，且该信号还是会抛异常才触发 |
| `test/constructor_param_test.cj` | 6 种集合/可选形态（`ArrayList`/`Array`/`HashSet`/`Set`/`HashMap`/`Map`/`?T`）都编译通过并有 `size` 断言，能挡住第 2/3 部分记录的 `lookupSet`/`lookupMap` 回归（回退即编译失败）。问题：只断言 size，键契约与元素身份未验证，`List` 形态未覆盖（轻微） |
| `test/generic_bean_test.cj` | 通过 `lookup<TestGenericBean<String>>()` 隐式验证了 `@Bean[String\|Int64]` 的第一组实参注册；`TestBean1`/`TestBean2`/`AbstractBean`/`TestBean` 四个夹具从未被取用，`Int64` 组未被查询，`let bean` 未读取（轻微） |
| `test/obj_test.cj` | 无 `@Test`，纯夹具文件（`A`/`B` + `@Constructor` 单形参），被 `bean_test.cj` 使用。`A`/`B` 的 `toString` 返回类型为推断的 `String`，满足 `ToString`；`B` 的 `@Constructor` 由宏生成 `lookup<A>()`。问题见 `bean_test.cj` 那条（用例侧无断言） |

### 维度自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`testEagerBeanCreatedAtMostOnce` 校验的不是它声称的路径（一般，已单列）、`initIfNeed` 无幂等（一般，已单列）；可读性：`@Assert(false, true)`、脚本式命名 `test1`（轻微，已单列）；设计：跨文件夹具耦合 + 模式字面量重复（轻微，已单列）。语言特性 0：7 个文件里 `?T` 全部用 `isSome()/isNone()/getOrThrow()` 显式处理，`Option` 无静默丢弃；`AtomicInt64` 只做计数，无可见性问题。安全性 0：无外部输入、无凭据、无敏感日志（`println` 只打 bean / Option / 耗时） |
| §1 死代码 | 1 | 已逐个机械核对：4 个 `private let` 模式常量全部在本文件被引用；`generic_bean_test.cj:41` 的 `let bean` 赋值后未读取（命中，已单列）；`bean_test.cj:25` 的 `b` 被 `println` 读取（不算）；`TestBean1`/`TestBean2`/`AbstractBean`/`TestBean` 是 `public` 顶层且位于测试包，按硬原则一**不判死代码**，只作"未使用夹具"信息记录；`bean_lookup_test` 的 12 个 `LookupItem`、`CtorParamItem`、`ScopeEagerBean` 等均被注册/被断言取用；无 `return`/`break` 后同层语句；4 个文件的 `import`（`std.unittest` / `testmacro` / `std.time` / `std.collection` / `f_bean.*` / `f_bean.macros.*`）逐个对照用法均有命中 |
| §2 重复逻辑 | 1 | 已把 7 个文件的用例压成「触发 → 断言 → 副作用」两两比对。命中 1 条：`bean_string_cond_test` 与 `bean_iterator_test`/`bean_getfirst_test` 的模式字面量与等价断言重复（已单列）。排除项：`LookupItem01..12` 是「测试准备代码」且类无法用循环生成（§2 误报边界）；`testCondAndEmptySemantics` 与 `testCollectCondAndEmptySemantics` 断言形状相同但分别钉 `lookupHashSet`/`lookupTreeSet` 与 `lookupList`/`lookupHashMap` 四套入口，属刻意平行覆盖；`testHashSetAndTreeSetEquivalence` 与 `testListElementsAndOrder` 一个查集合等价、一个查顺序，语义不同 |
| §3 空实现 | 2 | 命中：`bean_test.cj:23-27`（用例体只有 `println`，零断言，一般，已单列）、`generic_bean_test.cj:40-42`（`let` 后无断言、无读取，轻微，已并入夹具那条）。其余用例的最小断言均非空转（逐个核对期望值与夹具自洽：12 / 78 / 2 / 1 / `n * 2`）；`obj_test.cj` 无 `@Test` 不是空实现，是夹具文件 |
| §4 栈溢出 | 0 | 7 个文件无递归：`@Bean` 夹具的依赖图是 `B→A`、`CtorParamShapes→CtorParamItem`、`TestBean→{TestGenericBean,AbstractBean}` 三层且无环；`TestBean` 的字段注入在构造期查注册表，但目标类型与自身不同，不构成自引用递归。`sort`/`TreeSet` 排序用的是 `compare` 比较器，非递归实现 |
| §5 OOM | 0 | 无按不可信长度预分配、无全局累积容器：`LookupItem` 组固定 12 个；基准循环只累加 `Int64`，不建容器；`bean_lookup_test` 的 map/list 规模 = 该接口的 bean 数（代码声明，有界）。唯一与"无界"相关的是 `StringCond` 触发的 `WILDCARD_REGEX`/`REGEX_CACHE`，已在第 1/3 部分单列，本部分 4 个模式都是常量、键空间固定 |
| §6.1 热点瓶颈 | 0 | `scope.md` 声明未提供性能资料，本部分也没有 profile / bench 输出；单测里的 ns/op 属 `-O0` 打印值，不足以定位热点，只写成「待验证假设 #1」 |
| §6.2 大粒度锁 | 0 | 7 个文件无 `synchronized`/`Mutex`；`BeanFactory.instance` 的锁在实现侧，已在第 1/3 部分审 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无批处理、无单消费者队列 |
| §6.4 低效算法 | 0 | 循环都是线性遍历夹具或基准计数：`testMapNamesToBeans` 的 12 次 `lookupOption` 是 O(1) 哈希查找；`for (i in 0..list.size)` 无嵌套；无 `remove(at: 0)`、无循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 测试侧无长期持有的大对象；`bean_lookup_test` 的 list/set/map 都是局部临时值，用例结束即失效。没有可量化的"现状多大 / 能省多少"，不成立 |
| §8 降 CPU 方案 | 0 | 唯一有 CPU 含义的是单测基准本身的时长（属测试工程问题，已作为缺陷 + 待验证假设），不是产品路径优化 |
| §9 local mode 可行性 | 0 | 临时对象只有测试夹具的 bean 实例（需要逃逸到注册表）与 `ArrayList`/`HashMap`（作为返回值被断言），均不满足"函数内创建、函数内销毁"前提；且测试代码不在产品构建的优化面内 |
| §11 现有代码的 BUG（存量） | 3 | 已逐条核对：`initIfNeed` 非幂等（一般）、`testEagerBeanCreatedAtMostOnce` 用例名与实测路径不符（一般）、`bean_test` 零断言使注入契约无守护（一般）。另核对无缺陷的点：`LookupItem` 的 `hashCode`/`compare` 与 `HashSet`/`TreeSet` 契约一致（`Comparable` 提供默认 `==`，见 `f_util/src/UInt128.cj:24-52` 同类写法）；`getFirst<BeanTestDog>(cond: Exactly(catName))` 走 `beans.get` + 子类型复检，返回 `None` 与实现一致（`BeanFactory.cj:236-258`）；`bean_scope_test` 的 `BeanMeta(lazy:false, scope:prototype)` 与 `initIfNeed` 的三条件判定逐项对应 |
| §12 并发安全与锁粒度 | 0 | 7 个文件不含线程创建与同步原语；跨用例共享状态只有 `ScopeEagerBean.created`（`AtomicInt64`，只做前后差值断言）与 `BeanFactory.instance` 的只读查询，即便 unittest 并行执行也不引入新的竞态面。测试内的 `@Bean` 注册发生在模块初始化期，先于任何 `@TestCase` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 存量 10 条（严重 0、一般 3、轻微 7），本部分全部为存量，无「本次改动」引入项；是否纳入修复待用户决定。

## 总评

这 7 个文件是 f_bean 的测试面，质量分布很不均匀：**新补的用例（`bean_lookup_test` / `bean_scope_test` / `bean_string_cond_test` / `constructor_param_test`）断言扎实**，都能在对应实现被改坏时真正变红——`bean_string_cond_test` 甚至能抓住"memo 缓存键只算 flags 不算 pattern"这种隐蔽错误，`bean_lookup_test` 用 12 个同接口 bean 把 `HashSet`/`TreeSet`/`HashMap` 三套入口的集合与顺序都钉住了。**老用例（`bean_test` / `generic_bean_test` / `obj_test`）则基本是脚手架**：一个只打印，一个只取值不读，一个纯夹具，合并起来对 `@Constructor` 非集合形参注入这条公开能力没有任何断言。

真正值得排期的有三类：

1. **断言为空**：`bean_test.cj` 是模块同名文件，却是 7 个文件里唯一"删掉被保护功能也能过"的用例；`generic_bean_test.cj` 多组泛型的第二组、父类桶、`TestBean` 字段注入全部零覆盖。这两处补断言成本很低（各 3~5 行），收益是把 `@Constructor` 与 `@Bean[T1|T2]` 从"能编译"提升到"有回归防线"。
2. **用例名与实测路径不符**：`testEagerBeanCreatedAtMostOnce` 因测试进程从不调 `afterRegistered()` 而根本没碰到 eager 路径，实际只重复了单例缓存断言；`testInitIfNeedJudgement` 又用 `|| !inited` 给自己留了恒真出口。两者叠加，使"启动期预初始化"这个第 1/3 部分认定的生命周期风险点完全没有防线。建议把 eager 路径拆成独立 `--filter` 用例（`afterRegistered()` 会跑 `check()`，必须隔离进程），并顺手修 `initIfNeed` 的幂等（`_bean` 已存在则跳过、`afterRegistered` 用 CAS 守卫），否则重复初始化会静默丢掉单例且不销毁。
3. **覆盖缺口**：`StringCond` 的 8 个 case 测了 3 个，方向相反且最容易写反的 `Contains`/`In` 恰好在缺口里；`constructor_param_test` 只数了 size，Map 的"bean 名作键"契约没人验。这些都属于"补一条用例就能防住"的低成本项。

测试工程上有两处应清理：基准段继续留在 `cjpm test`（本部分新增的 30 万×2 与第 2/3 部分的两处同根因），以及 `@Assert(false, true)` 这种反直觉写法。另外 `bean_string_cond_test` 依赖 `bean_getfirst_test` 里声明的夹具并把数量写死为 2，任一新增 `BeanTestAnimal` 实现都会让它变红且失败信息误导——建议把夹具与模式常量集中到同包的 `fixtures.cj`。

**范围外提示**（不占用本部分统计）：`bean_def_condition_test.cj:45,110`、`bean_getfirst_test.cj`、`bean_iterator_test.cj` 属第 2/3 部分，本部分只引用其注释与夹具作为证据，不重复统计其缺陷；`BeanFactory.afterRegistered` 的执行时机由 `f_app/src/Initializer.cj` 决定，属模块外交互，未展开。
