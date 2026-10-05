# f_bean 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 14 条**：严重 1（§1.8 `BEAN-1`）、中 4（§2.15 `BEAN-2`、§2.16 `BEAN-3`、§2.17 `BEAN-4`、§2.18 `BEAN-5`）、低危+待验证 9（§3）。
- **状态（截至 2026-10-05）**：`BEAN-1` ✅已修复（§1.8）；**待修** §2.15–§2.18（性能中危，其中 `BEAN-5` 待验证）、§3 的 9 条低危/待验证。

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

### 2.15 [中｜性能] `BEAN-2` 每请求 `getFirst<T>()` 重复 2 次 `TypeInfo.of<T>()` + 2 次 `isSubtypeOf` + 1 次 `as T`（f_bean）

`BeanFactory.cj:201, 203-206, 226, 228`；调用方 `f_mvc/src/RequestMeta.cj:191` 每请求一次。修法：`T` 的 `TypeInfo` 提到调用方缓存，并去掉「表 key 已保证类型」后的 `matches` 复检。

### 2.16 [中｜性能] `BEAN-3` `iterator<T>` 每次调用新建 filter 闭包并逐元素重跑判断（f_bean）

`BeanFactory.cj:328`（`getList/getMap/lookupHashSet/lookupTreeSet` 全走它）。`IgnoreCond` 恒真时应直接返回 `tree.iterator()`。

### 2.17 [中｜性能] `BEAN-4` 条件求值里每次现场构造通配/正则（f_bean）

`BeanStringCondition.cj:74-75`（`Regex.wildcard(v).matches(s)` / `v.regex().matches(s)`；前者是 6 次 `replace` + 缓存查表，见 `f_regex/src/ExtendRegex.cj:76-85`、`RegexFromString.cj:40-64`）。它又被 `BEAN-3` 逐元素调用 ⇒ 每元素 ~7 次字符串分配。修法：`StringCond` 内缓存编译好的 `Regex`。

### 2.18 [中｜性能｜待验证] `BEAN-5` 每次取 bean 都算 `scope.isSingleton`，其中 `==` 会求 `TypeInfo.of<SingletonBeanScope>()`（f_bean）

`BeanScope.cj:31, 38-42, 59-63` + `BeanManager.cj:90`。**待验证** `TypeInfo.of` 是否有运行时缓存（`f_base/src/TypeInfos.cj:32-36` 注释显示作者也想用静态 `INSTANCE`）。修法：`BeanManager` 构造时预存 `Bool` 字段。

## 3. 低危 / 待验证（本模块 9 条）

### 3.1 低危（8 条）

**健壮性 / 正确性**

- `BEAN-L9` `BeanFactory.cj:287-300`：`getFirstTuple<T>` 缺 `beanTypeIs<T>` 前置校验（`getFirst`/`iterator` 都有）⇒ 装配错误被静默吞成 `None`。

**内存 / 清理**

- `BEAN-L2` `BeanManager.cj:40-44, 88-107` + `BeanFactory.cj:36-40`：容器与单例引用只增不减（`doDestroy()` 只调 `destroy()` 不清 `_bean`；三张表与 `registered` 无 reset/unregister）⇒ 已 destroy 的 bean 仍被强引用。修法：`doDestroy` 后 `_bean.store(None)`，补 `reset()/unregister()`。
- `BEAN-L3` `BeanFactory.cj:34` + `BeanInitializer.cj:19-21`：`ExitCallbacks.atExit` 与 `InitializerCollection.register` 只注册不注销（进程级单例，构建次数 1，不构成重复泄漏）。

**性能微项**

- `BEAN-L1` `BeanFactory.cj:148-175` + `BeanDefCondition.cj:128-140`：启动期条件筛选近似 O(n²)（逐 bean 求条件、条件内再遍历该类型全部 manager；清理阶段对每个被丢弃 bean 全量遍历两张表，`161/165` 还无条件 `typeRemoved.add(t)`）。仅 `afterRegistered()` 一次。
- `BEAN-L4` `lookup.cj:104-109`（同 `80-86`）：按 label 查单个 bean 却先全量物化 `ArrayList` 再线性扫描；改用 `iterator<T>(cond)` 惰性遍历，首个命中即返回。
- `BEAN-L5` `lookup.cj:56-58, 64-66`：`lookupHashSet/lookupTreeSet` 双重物化（先 `ArrayList` 再目标集合，均从 0 容量扩容）。
- `BEAN-L6` `BeanFactory.cj:63-121`：类型表 `Any`/`Object` 键使每个 bean 都入表；std 过滤只作用于 `isClass` 分支，注解分支仍展开 `superInterfaces/superClass`（注册期内存与遍历量放大）。
- `BEAN-L7` `BeanFactory.cj:109-115`：注册循环体内定义局部函数并捕获 `isClass`（每类型节点一次闭包分配，注册期）。

### 3.2 待验证（1 条）

- `BEAN-L8` `BeanManager.cj:59-66` vs `:88-107`：`initIfNeed()` 无条件 `_bean.store(new())` 而 `bean` getter 用双检 ⇒ 若启动初始化与首次请求并发，非 lazy 单例可能被二次创建覆盖。**验证**：部署方是否保证请求晚于 initializer（正常启动流程下不触发）。

## 4. 逐模块覆盖面（原 §4.3）

### 4.3 f_bean

**结构**：「启动期注册 + 运行期查找」容器：`BeanFactory`（单例；`HashMap<String,BeanManager>` 名称表 + `HashMap<TypeInfo,TreeSet<BeanManager>>` 类型/注解表）在注册期把每个 bean 的本类、`Any`、`Object`、全部 `superInterfaces/superClass`/注解递归展开入表，`afterRegistered()` 冻结注册并跑一次条件筛选。`BeanManager` 管生命周期（单例走 `AtomicOptionReference` 双检锁缓存，prototype 每次 `new()`）。元数据**没有**每请求重建。

**无实例的维度**：模块内**没有**属性拷贝/深拷贝代码（`as T`/`<-` 仅 4 处，都在查找返回路径）；无每请求重建类型元信息（注册期构建 + `registered` 冻结）；无 `ThreadLocal`；无自建缓存（唯一正则缓存来自 `f_regex`，已有界 `maxLife/maxSize`）；无异常当控制流（无 `catch NoneValueException`、无捕越界/转换失败；`getOrThrow` 只在「bean 不存在」错误路径）；无线性 `contains`（容器查找走 `HashMap.get`/`TreeSet.contains`，仅 label 类语义查找是 O(n)，见 `BEAN-L4`）；无循环内字符串拼接热点。
