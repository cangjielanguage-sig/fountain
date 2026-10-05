# f_bean 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 14 条**：严重 1（§1.8 `BEAN-1`）、中 4（§2.15 `BEAN-2`、§2.16 `BEAN-3`、§2.17 `BEAN-4`、§2.18 `BEAN-5`）、低危+待验证 9（§3）。
- **状态（截至 2026-10-05）**：`BEAN-1` ✅已修复（§1.8）、`BEAN-2` ✅已修复（§2.15）、`BEAN-3` ✅已修复（§2.16，含同族的 `getFirstTuple`）、`BEAN-4` ✅已修复（§2.17）、`BEAN-5` ✅已修复（§2.18）⇒ **本模块中危清零**；§3 的 9 条里 `BEAN-L9` ❌判为**不成立**、`BEAN-L2` ❌判为**不成立（设计）**、`BEAN-L3` ⏸保持现状、`BEAN-L6` ⏸保持现状（注解是**面向应用项目**的特性，不删）；**待修 2 条**：`BEAN-L1`（启动期 `check()` 近似 O(n²)）与待验证的 `BEAN-L8`（`BEAN-L7`/`BEAN-L5` 已修复；`BEAN-L4` 按作者决定保持现状）。另：§3.1 `BEAN-L6` 记录了一条**新发现待作者确认** —— `annotationMap` 只写不读，README:5 的「按（父）类型注解获取 bean」当前没有可用查询入口。

## 1. 严重（本模块 1 条）

### 1.8 [严重｜正确性] `BEAN-1` 宏生成不存在的 `lookupSet`（f_bean）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/asp-4`（worktree `.worktrees/asp-4`，基线 `ba6fc979`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_bean): BEAN-1 @Constructor 集合形参改用 lookupHashSet/lookupHashMap，Map 键必须 String（§1.8）`）。

- 改动：`f_bean/src/macros/Constructor.cj` —— `lookupSet` → `lookupHashSet`（`:80`、`:92`）、`lookupMap` → `lookupHashMap`（`:83`、`:103`）；并按用户要求对 `HashMap`/`Map` 形参加**编译期检查**：键类型不是 `String` 时 `diagReport(ERROR, ...)` 报「the key type of the HashMap parameter X must be String」，附建议 `declare it as HashMap<String, T>`。
- **实测补充（报告只写了 `lookupSet`）**：`lookupMap` 同样缺失。名字集合对照：宏生成 `lookup`/`lookupList`/`lookupSet`/`lookupMap`/`lookupOption`；库只定义 `lookupHashSet`（`lookup.cj:52-58`）与 `lookupHashMap`（`:68-74`）（`lookupList`/`lookupOption`/`lookup` 有 ✓）。
- 用例：`f_bean/src/test/constructor_param_test.cj` —— `@Bean` + `@Constructor` 覆盖 `ArrayList`/`Array`/`HashSet`/`Set`/`HashMap<String,_>`/`Map<String,_>`/`Option` 七种形态，并在运行时断言各集合/可选形参都注入了注册的元素 bean（`list`/`arr`/`hashSet`/`set`/`hashMap`/`map` 各 `size == 1`、`opt.isSome()`）。
- 测量证据：**修前** `cjpm test` **编译失败**：`error: the error originates in the macro \`Bean\`` + `note: undeclared identifier 'lookupSet'`（`let hashSet = lookupSet < CtorParamItem >()`、`let set = lookupSet < CtorParamItem >()`）与 `note: undeclared identifier 'lookupMap'`（`hashMap`/`map` 两处），`EXIT=1`。**修后** `PASSED: 3, FAILED: 0, ERROR: 0`、`cjpm test success`（EXIT=0），含 `testCollectionParamsInjected`。**键检查探针**（临时文件，验证后已删）：`HashMap<Int64, CtorParamItem>` 形参报 `error: the key type of the HashMap parameter bad must be String`（附建议行），`EXIT=1`。
- 未覆盖：`Set`/`Map` 靠 `HashSet`/`HashMap` 隐式转换（已含在用例里）；`HashMap<K,V>`（K≠String）现在由编译期错误拦住，不再生成类型不符的代码。

位置：`src/macros/Constructor.cj:80, 92`；`src/lookup.cj`（只有 `lookupHashSet`、`lookupTreeSet`）

```cangjie
// Constructor.cj:80   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>($cond))
// Constructor.cj:92   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>())
```

已核实：全仓 `grep 'func lookupSet'` **无任何定义**，`lookupSet<` 仅出现在这两处宏输出里。影响：任何 `@Bean` + `@Constructor` 类只要有一个 `HashSet<T>`/`Set<T>` 形参，生成代码就引用未定义符号 ⇒ **编译失败**（不是运行时问题，所以只有用到该形参形态的类才暴露）。修法：改为 `lookupHashSet`（或补 `lookupSet` 别名）。建议同时给 `@Constructor` 加一条形参形态的编译期用例（`ArrayList/Array/HashSet/Option/HashMap` 各一）。

## 2. 中（本模块 4 条）

### 2.15 [中｜性能] `BEAN-2` 每请求 `getFirst<T>()` 重复 2 次 `TypeInfo.of<T>()` + 2 次 `isSubtypeOf` + 1 次 `as T`（f_bean）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/bean`（worktree `.worktrees/bean`，基线 `7be7225d`），代码、用例、本标记在**同一提交**。

- 改动（`f_bean/src/BeanFactory.cj`）：① 抽出私有 `getFirstByType<T>(beanType, cond)` 作为唯一实现；`getFirst<T>()`（单参重载）直接走它 —— 原先它把 `TypeInfo.of<T>()` 交给 `getFirst<T>(beanType:, cond:)`，后者再调 `beanTypeIs<T>` 做 `beanType.isSubtypeOf(TypeInfo.of<T>())`，而此处 `beanType` 就是 `T` 自己 ⇒ 该校验**恒真**（每次白付 1 次 `TypeInfo.of<T>()` + 1 次 `isSubtypeOf`）；② `case _` 分支的循环条件由 `matches(beanType, cond, m)`（子类型复检 + `cond.on(name)`）换成 `cond.on(m.name)` —— `beanTypeMap[beanType]` 的桶由注册期按「beanType 的超类型闭包」填充（`doRegister`），桶内每个 manager 的 `beanType` 必是该 key 的子类型 ⇒ 复检**恒真**；③ `beanType:` 重载仍走 `beanTypeIs`（非法 `beanType` 依旧抛 `BeanException`），`Exactly` 分支仍做类型复检（`beans` 是名字表，必须校验）。
- 用例：`f_bean/src/test/bean_getfirst_test.cj`（新增）—— 类键 / 接口键 / 父类键 / `Any`·`Object` 桶 / `Exactly(名字)`（同类名字命中、**异类名字必须 `None`**）/ `beanType:` 重载 / 非法 `beanType` 抛 `BeanException` / 重复查询结果一致；另有基准用例打印 `getFirst<T>()` × N 的 ns/op。
- 测量证据（同机、同一套用例）：**修前** `TOTAL 7 / PASSED 7 / ERROR 0 / FAILED 0`、`BENCH getFirst<BeanTestDog> x300000: total=1185.505060ms, ns/op=3951.68`；**修后** `TOTAL 7 / PASSED 7 / ERROR 0 / FAILED 0`、`BENCH ... total=675.955489ms, ns/op=2253.18` ⇒ **快 1.75×（-43%）**；`cjpm build` 两次都 **exit 0**（9 条既有警告，未新增）。
- 行为不变的理由（不只靠用例）：去掉的两处分别是「自反子类型校验」与「按注册不变量恒真的桶内复检」，都不涉及可见语义；用例特意覆盖接口 / 父类 / `Any` / `Object` / `Exactly` 这些最可能暴露差异的路径。
- 未覆盖：`f_mvc` 侧调用方（`RequestMeta.cj:191`）未改 —— 「调用方缓存 `TypeInfo`」属跨模块优化，本次不做；`getAll`/`iterator` 的同类复检留给 §2.16 `BEAN-3`。
- 注：未跑 `cjfmt` —— `BeanFactory.cj` 全文都不是 cjfmt 风格，整文件格式化会产生大量与本次修复无关的 diff；本次只按周边风格对齐了改动行。

**以下为审查时的原始描述**：

`BeanFactory.cj:201, 203-206, 226, 228`；调用方 `f_mvc/src/RequestMeta.cj:191` 每请求一次。修法：`T` 的 `TypeInfo` 提到调用方缓存，并去掉「表 key 已保证类型」后的 `matches` 复检。

### 2.16 [中｜性能] `BEAN-3` `iterator<T>` 每次调用新建 filter 闭包并逐元素重跑判断（f_bean）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/bean`（worktree `.worktrees/bean`，基线 `7be7225d`），代码、用例、本标记在**同一提交**（含用户指示「一并修复 `getFirstTuple`」）。

- 改动（`f_bean/src/BeanFactory.cj`）：
  1. `iterator<T>(beanType:, cond:)` 的 `case _` 分支：`cond.ignored`（`IgnoreCond`，也正是 `getList`/`getMap`/`getAllTuples`/`lookup*` 的默认形态）时**直接 `tree.iterator()`** —— 不建闭包、不做逐元素判定；有名字条件时也只留 `cond.on(m.name)`（原先 `matches` 里的子类型复检按「桶由注册期超类型闭包填充」恒真，见 §2.15）。
  2. 同族（与 §2.15 同一处理，§2.15 记录里承诺留给本条）：`iterator<T>()` 单参重载不再走 `beanTypeIs`（`beanType` 就是 `T` 自己的 `TypeInfo`，校验恒真）⇒ 新增私有 `iteratorByType<T>` 作唯一实现，`beanType:` 重载仍保留校验。
  3. 同族（用户指示一并修）：`getFirstTuple<T>` 的循环 `where matches<T>(cond, m)` → `where cond.on(m.name)` —— 桶 key 就是 `TypeInfo.of<T>()`，子类型复检恒真，原先每元素还要重算 `TypeInfo.of<T>()` + `isSubtypeOf`。
  4. 顺带删除因此失去调用方的 `matches<T>(cond, m)` / `matches(beanType, cond, m)` 两个私有重载（不留死代码）。
- 用例：`f_bean/src/test/bean_iterator_test.cj`（新增）—— `iterator<T>()`（IgnoreCond）取到的名字集合 = {狗, 猫}、带条件只取狗、`getList`/`getMap`/`getAllTuples` 口径一致；`getFirstTuple` 重复取一致 / 条件命中（`T=Cat` + 猫模式 ⇒ 猫，狗模式 ⇒ `None`）/ `Exactly` 同类命中、异类 `None`；另有分相位基准（**进程内多轮取最快**）。
- 测量证据（这台机器上有并行会话，单次数字会被调度干扰 ⇒ 过滤单类 + after/before 交替取样 + 进程内 min-of-N）：
  - `iterator<BeanTestAnimal>()`（IgnoreCond，本条目标）：**3262.36 → 2349.22 ns/op（1.39×）**，第二轮 **3174.12 → 2586.30 ns/op（1.23×）**；
  - `iterator<BeanTestAnimal>(cond: Regexp('.*'))`：6980.23 → 7069.29、7591.24 → 8889.05 ⇒ **无可靠变化**（该路径成本由正则匹配本身主导，被去掉的逐元素子类型复检只占小头，符合预期）；
  - `getFirstTuple<BeanTestDog>()`（同族改动）：1467.32 → 1457.03、1664.46 → 1412.70 ⇒ 一致偏低但幅度弱（约 1.04–1.18×）。**原因已定位**：被去掉的 `m.beanType.isSubtypeOf(beanType)` 对**接口键**（`iterator<Animal>`）要遍历接口层级、对**叶子类键**（`getFirstTuple<Dog>`）几乎是最便宜路径 ⇒ 同一处代码在两条路径上收益不同；且 `getFirstTuple` 单次成本被 `generateDestroy` 闭包 + 元组分配主导。
  - 全套：**TOTAL 12 / PASSED 12 / ERROR 0 / FAILED 0**（修前同一套用例也是 12/12）；`cjpm build` **exit 0**（9 条既有警告，未新增）。
- 未覆盖：`iterator<T>(beanType:, cond:)` 的非 IgnoreCond 路径仍在用 `Iterator.filter`（不改公开签名就避不开那个闭包，除非自建迭代器类）；`getFirstTuple` 的 `generateDestroy` 闭包/元组分配属另一话题，本次不动。

**以下为审查时的原始描述**：

`BeanFactory.cj:328`（`getList/getMap/lookupHashSet/lookupTreeSet` 全走它）。`IgnoreCond` 恒真时应直接返回 `tree.iterator()`。

### 2.17 [中｜性能] `BEAN-4` 条件求值里每次现场构造通配/正则（f_bean）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/bean`（worktree `.worktrees/bean`，基线 `7be7225d`），代码、用例、本标记在**同一提交**。

- 改动（`f_bean/src/BeanStringCondition.cj`）：① 顶部加两个模块私有 memo `WILDCARD_REGEX` / `REGEX_CACHE`（`ConcurrentHashMap<String, Regex>`，键 = 模式串）；② `StringCond.on` 的两个分支改为 `WILDCARD_REGEX.computeIfAbsent(v){Regex.wildcard(v)}.matches(s)` 与 `REGEX_CACHE.computeIfAbsent(v){v.regex()}.matches(s)`。公开 API（`Wildcard(String)`/`Regexp(String)` 构造器、`on`/`==`/`ignored` 语义）不变；`Regex` 不可变、可安全共享；键空间 = 代码里声明的条件模式数（有界）。
- **现状核对（修正报告里一处含糊）**：`String.regex()` **本身已有缓存**（`f_regex/src/RegexFromString.cj:28-65`：`SOLID` map + `HeapCache<Regex>(maxLife: 1 day, maxSize: 10000)`）⇒ `Regexp` 路径的浪费不是「每次编译正则」，而是**每次现构造键串** `"/${this}/${flagsstr()}"`（`flagsstr()` 建 `HashSet` + `StringGenerator`）；`Wildcard` 路径才是每次真的 6 次 `String.replace`（`f_regex/src/ExtendRegex.cj:76-85`，库侧无缓存）。两条本次一并消掉。
- 用例：`f_bean/src/test/bean_string_cond_test.cj`（新增）—— `Wildcard('fountain::f_bean.test.*')` / `Regexp('.*BeanTestDog.*')` 的命中与不命中、重复求值一致、接口键 + 条件的 `getList`（= 2 个）与 `getFirst`（命中 / 不命中）结果；另有基准用例打印两种条件各 N 次 `on` 的 ns/op。
- 测量证据（同机连续两轮、同一套用例；`getFirst` 基准作**对照组**）：**修前** `TOTAL 9 / PASSED 9 / ERROR 0 / FAILED 0`、`Wildcard 4342.47 ns/op`、`Regexp 3886.54 ns/op`（对照组 `getFirst` 1796.75 ns/op）；**修后** `TOTAL 9 / PASSED 9 / ERROR 0 / FAILED 0`、`Wildcard **1508.23** ns/op`（**2.88×**）、`Regexp **1747.54** ns/op`（**2.22×**）、对照组 1759.38 ns/op（几乎不动 ⇒ 不是机器变快）；`cjpm build` **exit 0**（9 条既有警告，未新增）。
- 未覆盖：`f_regex` 未改 —— `Regex.wildcard` 的展开在库侧仍无缓存，别的模块调它还是付 6 次 `replace`（本次只解决 f_bean 自己的条件求值路径）；`BEAN-3`（§2.16）的「逐元素调用」结构见该条。

**以下为审查时的原始描述**：

`BeanStringCondition.cj:74-75`（`Regex.wildcard(v).matches(s)` / `v.regex().matches(s)`；前者是 6 次 `replace` + 缓存查表，见 `f_regex/src/ExtendRegex.cj:76-85`、`RegexFromString.cj:40-64`）。它又被 `BEAN-3` 逐元素调用 ⇒ 每元素 ~7 次字符串分配。修法：`StringCond` 内缓存编译好的 `Regex`。

### 2.18 [中｜性能｜待验证] `BEAN-5` 每次取 bean 都算 `scope.isSingleton`，其中 `==` 会求 `TypeInfo.of<SingletonBeanScope>()`（f_bean）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/bean`（worktree `.worktrees/bean`，基线 `7be7225d`），代码、用例、本标记在**同一提交**。

- **待验证项的结论**（用户提供 + 实测）：std.reflect 每次返回的都是**同一个单例**（不需要在 f_bean 里缓存），但**获取它不免费** —— 实测 `TypeInfo.of<SingletonBeanScope>()` ≈ **76–94 ns/次**；而 `BeanScope.==`（`BeanScope.cj:30-32`）对「非 `BeanScope.singleton` 常量」的 scope 会退到 `this.typeInfo == other.typeInfo` ⇒ 每次取 bean 都要两次获取 + 一次比较。
- 改动（`f_bean/src/BeanManager.cj`）：新增 `private let _singleton: Bool`，构造期 `_singleton = meta.scope.isSingleton` 算一次（`:36`）；`initIfNeed`（`:68`，原 `:60`）与 `bean` getter（`:98`，原 `:90`）改读该字段。**用普通 `let` 成员、不用原子类型**：值构造后不变，与既有 `meta`/`beanType`/`_name` 同一发布路径。
- **最小对照用例**（用户要求先出数据；三份结构等价的假 manager：现行 / 预存普通 `Bool` / 预存 `AtomicBool`，同一进程内 min-of-4，n = 100 万）：

  | 形态 | ns/op |
  |---|---|
  | ① 现行：每次读 `meta.scope.isSingleton`（默认 scope 常量） | 59.82 |
  | ② 预存**普通 `Bool`**（默认 scope） | **48.33** |
  | ③ 预存 `AtomicBool`（默认 scope） | 51.78 ⇒ 原子版每次多付 **3.5 ns**，没必要 |
  | ④ 现行：自定义 scope 实例 | 209.74 |
  | ⑤ 预存普通 `Bool`（自定义 scope 实例） | **48.94** |
  | ⑥ 算一次该 Bool：默认 scope 常量 | 19.69（**每 bean 一次**） |
  | ⑦ 算一次该 Bool：自定义 scope 实例 | 157.95（**每 bean 一次**） |

- **真实代码 A/B**（只跑探针类、after/before 交替两轮、进程内 min-of-4；同轮未改动的 scope 表达式波动 ±15% 作负载对照）：默认 scope 的 `manager.bean` **72.50 → 57.09 ns（-21%）**、第二轮 **97.39 → 57.48**；自定义 scope 实例的 `manager.bean` **329.33 → 60.62（-82%）**、第二轮 **247.13 → 66.87** ⇒ 与最小对照的预期（默认 -19%、自定义 -77%）一致。
- 用例：`f_bean/src/test/bean_scope_test.cj`（新增）—— 单例 bean 重复取到同一实例（`getFirst` 与直接 `manager.bean` 两路）、prototype 每次 `new`（`refEq` 为 false）、**非常量 `SingletonBeanScope()` 实例仍按单例缓存**、`initIfNeed` 三种判定（lazy ⇒ false；非单例 ⇒ false，这条才区分得出 `_singleton=false`；非 lazy 单例 ⇒ 结果稳定）、非 lazy bean 取多次不再构造（`AtomicInt64` 计数）。
- 全套：**TOTAL 17 / PASSED 17 / ERROR 0 / FAILED 0**；`cjpm build` exit 0（9 条既有警告，未新增）。探针文件已删除、未入库；日志 `/tmp/bean5_before.log`、`/tmp/bean5_after2.log`、`/tmp/bean5_ab.log`。
- 未覆盖：`bean` getter 剩下的 ~48 ns = `AtomicOptionReference.load()`（std 文档确认是默认内存序的**原子读**，lock-free）+ `Option` 解包 + prop 调用，**不可省**；prototype 路径的 `new()` 同理。

**以下为审查时的原始描述**：

`BeanScope.cj:31, 38-42, 59-63` + `BeanManager.cj:90`。**待验证** `TypeInfo.of` 是否有运行时缓存（`f_base/src/TypeInfos.cj:32-36` 注释显示作者也想用静态 `INSTANCE`）。修法：`BeanManager` 构造时预存 `Bool` 字段。

## 3. 低危 / 待验证（本模块 9 条）

### 3.1 低危（8 条；其中 `BEAN-L9` 判为**不成立**）

**健壮性 / 正确性**

- `BEAN-L9` ❌**不成立（2026-10-05）** — ~~`BeanFactory.cj:287-300`：`getFirstTuple<T>` 缺 `beanTypeIs<T>` 前置校验（`getFirst`/`iterator` 都有）⇒ 装配错误被静默吞成 `None`。~~
  **判定（2026-10-05）**：非缺陷。`beanTypeMap.get(TypeInfo.of<T>())` 返回的桶**只含 `T` 的子类型**（注册期 `doRegister` 按 `beanType` 的超类型闭包入桶，见 `BeanFactory.cj:63-124`）⇒ 「缺前置校验」没有对象：`T` 未注册时 `beanTypeMap.get` 本身就返回 `None`；有注册时桶内每个 manager 的 `beanType` 必是 `T` 的子类型 ⇒ `if (let bean: T <- m.bean)` 恒成立。同理，`getFirst`/`iterator` 单参重载里的 `beanTypeIs<T>(TypeInfo.of<T>())` 也是**恒真**的（§2.15 已证并去掉）。语义已被用例钉住：`BeanGetFirst_test.testBeanTypeOverloadAndExactly`（`Exactly(异类型名字)` ⇒ `None`）与 `BeanIterator_test.testFirstTupleEquivalence`（`Regexp(异类型模式)` ⇒ `None`）。

**内存 / 清理**

- `BEAN-L2` ❌**不成立（2026-10-05，设计）** — ~~`BeanManager.cj:40-44, 88-107` + `BeanFactory.cj:36-40`：容器与单例引用只增不减（`doDestroy()` 只调 `destroy()` 不清 `_bean`；三张表与 `registered` 无 reset/unregister）⇒ 已 destroy 的 bean 仍被强引用。修法：`doDestroy` 后 `_bean.store(None)`，补 `reset()/unregister()`。~~
  **判定（2026-10-05，用户拍板）**：两条都是**设计**——① 只有 **singleton** 的 bean 全生命周期由 `BeanFactory` 管理，因此也只有它由 `BeanFactory` 调 `destroy`（`shutdown` → `doDestroy`，只在进程退出路径）；prototype / 自定义 scope 的销毁时机由开发者或应用层决定（经 `generateDestroy` 拿到闭包自行调用），销毁之后 `BeanManager._bean` 是否还持有、还能不能再访问 `bean`，不在框架职责内；② **永不清理 `BeanFactory` 的集合**（`beans`/`beanTypeMap`/`annotationMap`/`registered`）同样是设计 ⇒ 不加 `reset()`/`unregister()`。
- `BEAN-L3` ⏸**保持现状（2026-10-05，记录不改）** — `BeanFactory.cj:34` + `BeanInitializer.cj:20`：`ExitCallbacks.atExit` 与 `InitializerCollection.register` 只注册不注销。进程级单例、注册次数 1（原文即判「不构成重复泄漏」），与上条同属「注册表只增不减」的设计 ⇒ 留档，不动代码。

**性能微项**

- `BEAN-L1` `BeanFactory.cj:148-175` + `BeanDefCondition.cj:128-140`：启动期条件筛选近似 O(n²)（逐 bean 求条件、条件内再遍历该类型全部 manager；清理阶段对每个被丢弃 bean 全量遍历两张表，`161/165` 还无条件 `typeRemoved.add(t)`）。仅 `afterRegistered()` 一次。
- `BEAN-L4` ⏸**保持现状（2026-10-05，作者决定）** — `lookup.cj:104-109`（6 个公开入口 `lookupLabel(label:)`/`lookupLabel(name:,label:)`/`lookupLabel(cond:,label:)`/`lookupLabelOption(label:)`/`lookupOptionLable(name:,label:)`/`lookupLabelOption(cond:,label:)` 全汇于此）：按 label 查**一个** bean 却先 `lookupList<T>(cond)`（`:48-50` → `getList`）全量物化 `ArrayList<T>`，再 `for … where` 扫描。
  **权衡记录（供再评估）**：改为惰性（`for (m in BeanFactory.instance.iterator<T>(cond: cond))` + `if (let bean: T <- m.bean && bean.label == label) { return bean }`）可省掉「N 元 `ArrayList` 的分配 + N 次 `add`（含扩容）+ 命中之后那些 bean 的访问」，**但会减少 prototype scope bean 的实例化次数** —— 现状会对该类型下**所有** prototype bean 各调一次 `new()`（连带 `PostConstruct`/`FactoryBean` 判定），改后只到「第一个 label 命中」为止 ⇒ 属**可见行为差异**。作者按「行为不变优先」决定保持现状。
  **附带留档（不改）**：同库「取一个」的接口 `lookup<T>`/`lookupOption<T>`（→ `getFirst`）本就是惰性、只实例化命中的那个 bean，与本条路径口径不一致；`:101` 的公开函数名 `lookupOptionLable` 拼写有误（`Lable`→`Label`），改名属破坏性 API 变更。
- `BEAN-L5` ✅**已修复（2026-10-05）** — ~~`lookup.cj:56-58, 64-66`：`lookupHashSet/lookupTreeSet` 双重物化（先 `ArrayList` 再目标集合，均从 0 容量扩容）。~~
  **修复记录**：两处改为**直接向目标集合填充** —— `for (m in BeanFactory.instance.iterator<T>(cond: cond)) { if (let bean: T <- m.bean) { set.add(bean) } }`（TreeSet 同款），中间 `ArrayList` 不复存在 ⇒ 插入次数 **2N → N**、峰值容器 **2 → 1**。语义与 `getList` 同源（同一个 `iterator<T>(cond:)`、同一个 `if (let bean: T <- m.bean)` 类型判定）⇒ 元素集合、`TreeSet` 的 `Comparable` 有序性、`cond` 透传、空结果、**实例化次数（含 prototype）**全部不变。唯一差异：原路径经 `getAll` 会逐 bean 打 `BeanFactory.getAll:…`（`log.debug`），新路径不经 `getAll` ⇒ **debug 级别下这两条 API 少 N 行日志**（非 debug 级别无差别；测试环境实测未开 debug，日志 0 行）。
  **测量证据**（同进程三段对照：`lookupList<T>()` 作**负载对照组** + 两个目标集合；n = 5 万、min-of-4；样本为 12 个同类型 bean）：**修前** `lookupList` 14283.84 ns/op（对照）、`lookupHashSet` 16946.33（**比值 1.1864**）、`lookupTreeSet` 24876.51（**比值 1.7416**）；**修后** `lookupList` 17742.61（本轮机器慢 ~24%）、`lookupHashSet` 17187.11（**比值 0.9687**）、`lookupTreeSet` 22487.39（**比值 1.2674**）⇒ 按对照组归一：**`lookupHashSet` -18.3%、`lookupTreeSet` -27.2%**（treeSet 余下的 1.27 是树插入本身，属目标结构的固有成本）。
  **用例**：`f_bean/src/test/bean_lookup_test.cj`（新增，永久）—— 自带 12 个实现同一接口（`Hashable & Comparable`）的 `@Bean`；断言 `lookupHashSet`/`lookupTreeSet` 与 `lookupList` 的元素集合一致、`TreeSet` 按 `Comparable` 严格升序、`cond` 全匹配 / 无匹配、无匹配 ⇒ 空集合。
  **回归**：`f_bean` 全套 **TOTAL 19 / PASSED 19 / ERROR 0 / FAILED 0**；`cjpm build` exit 0（9 条既有警告，未新增）。探针已删、未入库；日志 `/tmp/bean_l5_before3.log`、`/tmp/bean_l5_after.log`。
  **未覆盖（按决定保持现状）**：`lookupLabels`/`lookupWeights`（同族中间 `ArrayList`）随 `BEAN-L4` 冻结；`lookupList` 自身的 `ArrayList` 从 0 容量扩容未动（需容量提示、会引入内部 API 依赖）。
- `BEAN-L6` `BeanFactory.cj:63-121`：类型表 `Any`/`Object` 键使每个 bean 都入表；std 过滤只作用于 `isClass` 分支，注解分支仍展开 `superInterfaces/superClass`（注册期内存与遍历量放大）。
  **判定（2026-10-05 更正）**：**不删** —— `annotationMap` 与注解展开是**面向应用项目**的特性（`f_bean/README.md:5`：「使用修饰bean的类型的注解，以及父类型的注解获取bean」）；fountain 是工具库，**本仓（fountain 自身）没有调用方不等于死代码**。（我先前据「全仓零读方」提出的「整条注解分支删除」方案已撤回。）本条的成本事实保留作记录：注册期每个类型节点做一次 `klass.annotations` 反射展开 + 15 项 std 前缀/名字比较 + `annotationMap` 的 TreeSet 维护 —— **只在注册期一次**。
  **⚠️ 核实中发现的另一件事（比本条原文更值得跟进）**：`annotationMap` 全仓**只写不读** —— 写入 `:72`、`check()` 维护 `:163/:171/:172`，而 `beanManagers`/`getFirst`/`getList`/`getMap`/`iterator`/`getFirstTuple`/`getAll` **全部只查 `beanTypeMap`** ⇒ 按 README:5 的描述，「用（父）类型注解获取 bean」目前**没有可用的查询入口**（拿注解类型当 `T` 去查会落到 `beanTypeMap.get` 而得到 `None`）。**待作者确认**：读入口是待实现、在别处，还是文档超前。
- `BEAN-L7` ✅**已修复（2026-10-05）** — ~~`BeanFactory.cj:109-115`：注册循环体内定义局部函数并捕获 `isClass`（每类型节点一次闭包分配，注册期）。~~
  **修复记录**：新增**无捕获**的私有静态函数 `wrapType(isClass, typeInfo)`（`BeanFactory.cj:25-36`）；`doRegister` 里删掉循环体内的局部函数，两处调用点（`superInterfaces` 循环、`superClass` 链）改走它 ⇒ **每个类型节点的闭包分配次数 = 0**（原先 = 类型闭包大小 − 2：`Any`/`Object` 两个节点在被 pop 后就 `continue` 了，不建闭包）。入队的 `ClassType`/`AnnotationType` 与顺序一字不差，**不触碰 `annotationMap` 与注解展开能力**（见 `BEAN-L6` 更正）。
  **测量证据**（最小对照探针：同一循环骨架两形态、每节点包装 2 次、min-of-6、n = 30 万；生产里的 `BeanType`/`ClassType`/`AnnotationType` 是文件私有类型，测试包拿不到 ⇒ 载荷换成探针自有 enum）：**闭包版 51.97 ns/节点 → 静态函数版 37.12 ns/节点，每节点省 14.85 ns（-28.6%）**；折算：一个 bean 的类型闭包通常 3~6 个可展开节点 ⇒ **每 bean 省 ~45~90 ns**（注册期一次性）。探针已删、未入库；日志 `/tmp/bean_l7_probe.log`。
  **回归**：`f_bean` 全套 **TOTAL 17 / PASSED 17 / ERROR 0 / FAILED 0**；`cjpm build` exit 0（9 条既有警告，未新增）。
  **未实测**：端到端启动时间（需要真实应用的启动度量，如 fdemo），同 `BEAN-L6`。

### 3.2 待验证（1 条）

- `BEAN-L8` `BeanManager.cj:59-66` vs `:88-107`：`initIfNeed()` 无条件 `_bean.store(new())` 而 `bean` getter 用双检 ⇒ 若启动初始化与首次请求并发，非 lazy 单例可能被二次创建覆盖。**验证**：部署方是否保证请求晚于 initializer（正常启动流程下不触发）。

## 4. 逐模块覆盖面（原 §4.3）

### 4.3 f_bean

**结构**：「启动期注册 + 运行期查找」容器：`BeanFactory`（单例；`HashMap<String,BeanManager>` 名称表 + `HashMap<TypeInfo,TreeSet<BeanManager>>` 类型/注解表）在注册期把每个 bean 的本类、`Any`、`Object`、全部 `superInterfaces/superClass`/注解递归展开入表，`afterRegistered()` 冻结注册并跑一次条件筛选。`BeanManager` 管生命周期（单例走 `AtomicOptionReference` 双检锁缓存，prototype 每次 `new()`）。元数据**没有**每请求重建。

**无实例的维度**：模块内**没有**属性拷贝/深拷贝代码（`as T`/`<-` 仅 4 处，都在查找返回路径）；无每请求重建类型元信息（注册期构建 + `registered` 冻结）；无 `ThreadLocal`；无自建缓存（唯一正则缓存来自 `f_regex`，已有界 `maxLife/maxSize`）；无异常当控制流（无 `catch NoneValueException`、无捕越界/转换失败；`getOrThrow` 只在「bean 不存在」错误路径）；无线性 `contains`（容器查找走 `HashMap.get`/`TreeSet.contains`，仅 label 类语义查找是 O(n)，见 `BEAN-L4`）；无循环内字符串拼接热点。
