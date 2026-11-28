# f_bean 模块审查报告（第 2/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_bean`（37 个源文件；本部分覆盖其中 15 个：`PostConstructor` / `exception/BeanException` / `imports` / `lookup` / `macros/Bean` / `macros/BeanParam` / `macros/Configuration` / `macros/Constructor` / `macros/Value` / `macros/imports` / `test/bean_annotation_lookup_test` / `test/bean_annotation_meta_test` / `test/bean_def_condition_test` / `test/bean_getfirst_test` / `test/bean_iterator_test`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git log` 顶部为 `8c0ce643a`，工作区干净，仅有 `reviews/` 过程目录）⇒ 全部发现统一记「存量（无基线可比）」
- **审查重点**：Bean 宏、注解查找、生命周期与并发、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本文件为第 2/3 部分，最终由主 Agent 合并为 `docs/review/f_bean_review_20261128.md`）

## 发现

### [一般][存量] `@BeanParam` 的短写形式不可用，构造器白名单与 `StringCond` 实际 case 名不符

- **位置**：`f_bean/src/macros/BeanParam.cj:37-42`（`attr.size == 3` 却访问 `attr[3]`）；`:27` 与 `:38`（`'prefix'` / `'wildcard'` 小写）；`:36-42`（白名单缺 `Contains` / `In`）
- **来源**：存量（`git blame -L 22,47 -- f_bean/src/macros/BeanParam.cj` 全部落在 2026-10-02 `4be871f2fd`）
- **判据**：review-checklist §11（边界差一 / 契约与实现不符）/ §2（同一白名单字面量在两处复制）
- **证据**：静态确定 —— ① `StringCond` 的构造器为 `Exactly | Prefix | Suffix | Wildcard | Regexp | Contains | In`（`f_bean/src/BeanStringCondition.cj:36-60`）；② `Exactly('x')` 的 token 序列是 `IDENTIFIER, LPAREN, STRING_LITERAL, RPAREN` 共 **4** 个，因此 `:37` 的 `attr.size == 3` 永不成立；③ 若它真的成立，紧随其后的 `attr[3].kind` 就越界。两条路都走不通：`case _` 分支必然执行，`diagReport(ERROR, '… must be a String or constructor of fountain.bean.StringCond')` 打断编译。
- **描述**：文档里的写法 `@BeanParam(Exactly('x'))`（`README` 称"本宏的属性是表示 StringCond 枚举实例的 Tokens"）一律报错。带限定名的 `StringCond.Prefix(...)` / `StringCond.Wildcard(...)` 也被拒——`:27` 处白名单写的是小写 `'prefix'` / `'wildcard'`，与枚举 case 名大小写不符；`StringCond.Contains(...)` / `StringCond.In(...)` 两个合法 case 完全不在白名单里。仓内对 `@BeanParam` 零使用（见下条），所以这条路径从未被编译过。
- **建议**：`:37` 的 `attr.size == 3` 改为 `4`；把 `:27` 与 `:38` 的两份白名单抽成一个 `const` 数组，值改为 `'Exactly'|'Prefix'|'Suffix'|'Wildcard'|'Regexp'|'Contains'|'In'`；`let first = attr[0]` 之前补 `attr.isEmpty()` 判断（`@BeanParam` 不带属性时现在直接越界，宏崩溃而不是 `diagReport`）。

### [一般][存量] `@Constructor` 的静态工厂分支条件写反：`isGenericDecl` 应为 `!isGenericDecl`

- **位置**：`f_bean/src/macros/Constructor.cj:44`
- **来源**：存量（`git blame -L 44,44` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `Decl.isGenericDecl` 的语义是"是否是一个泛型节点"（`std/ast/ast_package_api/ast_package_classes.md:2686-2692`），即"带类型形参"。而同一个 `match` 的兜底分支错误文案是 `'… must be a public constructor or public static func without generic parameter'`（`:58-60`），意图明确是**排除**泛型。两条互斥证据足以判定条件方向相反。
- **描述**：`README:454-455` 声明"`@Constructor` 修饰的构造函数或静态函数是bean的初始化函数"。实际上：`public static func create(): Foo`（无类型形参）落进 `case _` → 编译期报"必须是公共构造函数或无泛型参数的公共静态函数"；反过来，带 `<T>` 的静态函数被接受，随后 `argTokens` 生成 `$beanType.create(args)`（不补类型实参），必然类型检查失败。仓内 `@Constructor` 只有 `f_bean/src/test/obj_test.cj:30`、`constructor_param_test.cj:43` 两处，都是 `init`，该分支零覆盖。
- **建议**：改为 `x.isStatic() && !x.isGenericDecl`，并补一个"公共静态工厂 + 无泛型"的最小用例（顺带覆盖 `setItem('constructor', name)` 分支）。另外 `:28-34` 的 `try { parseDecl(input) } catch (_: ParseASTException) { … } catch (e: Exception) { throw e }` 里最后一个 `catch` 只是原样重抛，无任何效果，可删（§1）。

### [一般][存量] `@Value` 在 `Array` / `DateTime` / `Duration` 形参上生成不合法或不类型检查的代码

- **位置**：`f_bean/src/macros/Value.cj:20`（`delim` 默认值是 `` `comma` `` token）、`:47-63`（DateTime / Duration 无 `default` 时不补 `??`）、`:120-130`（Array 分支完全不引用 `default`）、`:22-38`（未知属性名静默忽略，`attr[i+2]` 无边界检查）
- **来源**：存量（`git blame -L 18,46 -- f_bean/src/macros/Value.cj` → 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）/ §3（静默忽略）
- **证据**：静态确定 —— 对照 `f_config/src/Config.cj` 的实际签名：`getString(key): ?String`（`:186`）、`getDateTime(key, format!): ?DateTime`（`:232`）、`getDuration(key): ?Duration`（`:244`）、`getStringArray(key, delim!: String = ',')`（`:210`）。由此三条独立后果都可静态判定：
  1. `:20` 把 `delim` 初始化为 `` `comma` ``，最终拼成 `Config.getStringArray($name, delim: $delim)`（`:121`）。无论 `` `comma` `` 展开成逗号标点 token（生成 `delim: ,`，语法错）还是标识符 token（生成 `delim: comma`，未定义标识符），都不是 `String` 字面量 `','` ⇒ **任何 `Array<T>` 形参不显式写 `delim:` 都无法编译**。
  2. `:47-57` / `:58-63`：`default.size == 0` 时直接产出 `Config.getDateTime(...)` / `Config.getDuration(...)`，类型是 `?DateTime` / `?Duration`，却被 `let x = ` 赋给非 Option 形参 ⇒ **`DateTime` / `Duration` 形参必须给 `default` 才能编译**，而 `README` 把 `default` 写成可选。
  3. `:120-130` 的 `Array` 四个 case 都不引用 `default` ⇒ 数组形参上的 `default:` **被静默忽略**，配置缺失时得到空数组而不是默认值。
  另外 `:22-38` 的解析循环对无法识别的键只做 `i++`（`case _ => i++`），把 `deafult:` 这类拼写错误静默吞掉；`@Value[name]`（漏写值）时 `attr[i + 2]` 越界，宏抛越界异常而非 `diagReport`。
- **描述**：`@Value` 是 README 明确文档化的公开宏，四种属性（`name` / `default` / `dateFormat` / `delim`）与三类形参（标量 / 数组 / Option）交叉后，只有"标量 + String + 给全属性"这一格可用。仓内对 `@Value` 零使用、零测试，缺陷长期不可见。
- **建议**：`delim` 默认值改 `quote(',')`；非 Option 的 `DateTime` / `Duration` 在 `default.size == 0` 时 `diagReport(ERROR, '… requires a default value')`（不许静默生成 `?T`）；`Array` 分支要么支持 `default`（`getStringArray(...)` 后判空回退），要么显式报"数组形参不支持 default"；属性解析改成"匹配键 → 校验 `:` 与值存在 → 取 `attr[i+2]`"，未知键 `diagReport`。
- **待确认（次要）**：`:47-57` 的 `if (dateFormat.size > 0) { A } else { B } + if (...) { … }` 中，`+` 与前面的 if 表达式如何结合，取决于 `if` 表达式能否作二元运算的左操作数。若按"`+` 只接到 else 分支"解析，则 `dateFormat` 与 `default` 同时给出时 `default` 会被丢掉（generated code 又是 `?DateTime`）。用 `cjc --debug-macro`（或一个 `@Value[dateFormat:…, default:…] x: DateTime` 的最小用例）确认即可定论。

### [一般][存量] `@Configuration` 对不满足条件的 `@BeanInit` 成员静默跳过，无任何编译期提示

- **位置**：`f_bean/src/macros/Configuration.cj:41-48`（两个 `case f: FuncDecl where …` 之后是 `case _ => break`）；`:22`（`ClassDecl(input)` 直接构造）
- **来源**：存量（`git blame -L 33,52` → 2026-10-02）
- **判据**：review-checklist §3（空实现 / 静默失效）/ §11（错误处理缺失）
- **证据**：静态确定 —— 循环只在 `isBeanInit && isStatic/isPublic/参数为空` 全成立时追加注册 token，其余情形走 `case _ => break`，既不 `diagReport` 也不生成任何东西。宏的返回 token 里没有该函数，编译完全通过。
- **描述**：`@BeanInit private func init1()`、`@BeanInit public func init1(x: Int64)`、`@BeanInit` 打在属性上，三种都会"编译通过但 bean 不存在"。README 只说"公共成员函数"，用户写错可见性或漏加无参约束时，得到的现象是启动后 `lookup<X>()` 抛 `BeanException`，回溯不到宏。
- **建议**：把 `case _ => break` 拆成"`isBeanInit` 为真但类型/可见性/形参不满足 → `diagReport(ERROR, '… must be a public member function without parameter')`"，`isBeanInit` 为假才静默跳过。`ClassDecl(input)` 外层包 `try`/`catch (e: ASTException)` 转 `diagReport`，与 `Bean.cj:45-51` 的处理方式一致（现在非类输入直接抛解析异常，栈里看不到是哪个 `@Configuration`）。

### [轻微][存量] `lookupLabels` / `lookupWeights` 用容器键去重，键冲突时静默丢 bean

- **位置**：`f_bean/src/lookup.cj:98`（`map[bean.label] = bean`）、`:141`（`map[w] = bean`，`w` 是**累计**权重）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定（机制）—— README `:110` / `:124` 都写"获取类型是指定泛型实参的**全部** bean"，实现是逐条 `put`，键相同即覆盖；`lookupWeights` 的键是累加值（`:132-141`），任一 bean 权重为 0（或负）就与前一元素撞键，返回条数 < bean 数。触发是否发生取决于实际权重/标签取值（待确认），但"会覆盖"这一点无需实验。
- **建议**：`lookupWeights` 改为 `TreeMap<W, ArrayList<T>>`，或在 `contains` 命中时给 `diagReport`/日志告警；`lookupLabels` 至少在 README 注明"label 必须唯一，重复时后者覆盖"。若坚持一 bean 一键，则把返回值语义写成"按 label 索引的视图"，不要写"全部 bean"。

### [轻微][存量] `lookupLabelOption(cond, label)` 为取第一个而全量物化并线性扫描

- **位置**：`f_bean/src/lookup.cj:119-124`
- **来源**：存量
- **判据**：review-checklist §6.4（只判存在却全量扫描）
- **证据**：静态确定（复杂度）—— `lookupList<T>(cond)` 会构造完整 `ArrayList<T>`（并实例化全部命中的 prototype bean），随后 `for (bean in …) { return bean }` 只取第一个；`bean.label` 在 `where` 与循环体各求值一次。同文件 `lookupHashSet`（`:57-66`）与 `lookupTreeSet`（`:73-81`）已按 `BEAN-L5` 注释"直接向目标集合填充、不再物化中间 ArrayList"，此处未跟进。
- **建议**：改走 `BeanFactory.instance.iterator<T>(cond)`，循环内 `if (let b: T <- m.bean) { if (b.label == label) { return b } }`，命中即返回、`label` 只取一次。是否值得改取决于该入口的调用频次（未测量，见「待验证假设」）。

### [轻微][存量] 公开 API 表面不一致：`lookupOptionLable` 拼写错误、缺 `lookupLabelOption(name:, label:)` 重载

- **位置**：`f_bean/src/lookup.cj:116`（`lookupOptionLable`）；对照 `:102-124` 的 overload 家族
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）/ §10（可维护性）
- **证据**：静态确定 —— 全仓 `grep -rn "lookupOptionLable"` 只命中定义处，无任何调用者；`README:491` 已把这个错名当作公开 API 收录。`lookupLabel`（`:105`）与 `lookupLabelOption`（`:113`/`:119`）都有 `(name, …)` 形态，唯独"按名字 + label 取 Option"必须用错名才写得出。
- **建议**：新增正确名 `lookupLabelOption<L, T>(name: String, label: L)`，旧名保留为 `@Deprecated` 转发（一个函数体即可）；README 同步。属破坏性变更，需用户拍板后再删旧名。

### [轻微][存量] `Value.cj` / `Constructor.cj` 有大段"只改索引"的重复分支

- **位置**：`f_bean/src/macros/Value.cj:64-91`（`Option<T>`）与 `:92-119`（`?T`）—— 两块逐行相同，只有 `x[2]` vs `x[1]`；`:47-57` / `:70-80` / `:98-108` —— DateTime 拼装逻辑出现 3 次（加 `:120-130` 的 Array-DateTime 共 4 处）；`f_bean/src/macros/Constructor.cj:87-121` —— 有 `cond` / 无 `cond` 两个分支里 `ArrayList|List`、`Array`、`HashSet|Set`、`HashMap|Map`、`_` 五种形态各写一遍
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换控制流的重复）
- **证据**：静态确定 —— 把 8 条分支压成"输入→输出"摘要，差异只有（a）类型实参 token 区间（`?T` 从 `[1..]`、`Option<T>` 从 `[2..size-1]`）、（b）是否追加 `?? default`。无业务语义差异。
- **描述**：这是"缺陷放大器"：上一条 `@Value` 的三个问题分别落在 3~4 份副本里，修一处必须同时改另一份，且现在已经出现同类分支行为不一致（DateTime 的 `+` 位置与 Duration 不同，见上条「待确认」）。
- **建议**：先算 `elem: Tokens` 与 `getter: String`（一处 switch），再统一拼 `getter(...)` + 可选 `?? default`；`Constructor.cj` 把 cond/no-cond 改成 `cond: ?Tokens` 后只走一条 `match (typeName)`。注意别把 `Option<String>`（`?? ''` 强制非空）的边界差异抹掉——那一条要显式保留。

### [轻微][存量] `imports.cj` 有 3 个未使用的 `internal import` 与 2 组重复导入

- **位置**：`f_bean/src/imports.cj:20`（`internal import std.convert.*`，与 `:30` 的 `public import` 同一包重复）、`:21`（`std.env.*`）、`:22`（`std.process.Process`）、`:27` 与 `:34`（`fountain::f_data.*` 重复）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `internal import` 的作用域是"当前包及子包"（`cangjie_docs/.../package/import.md:293-294`），因此在 `f_bean/src` 全包搜索：`Process` 无命中、`getVariable|getCommandLine|std.env` 无命中、`.parse(|toInt|toFloat|Parsable` 仅命中 `macros/Value.cj` 引号内的 token 文本（那属于另一个包 `fountain::f_bean.macros`，不受本文件影响）。`std.convert.*` / `f_data.*` 各被导入两次，`public` 已覆盖 `internal`，前者无额外语义。
- **建议**：删 `:20`、`:21`、`:22`；`f_data.*` 只留 `:34` 的 `public` 一行。`shouldInitBean` / `setShouldInitBean` 的语义问题已在第 1/3 部分单列，不在此重复。

### [轻微][存量] `PostConstruct` 对 `FactoryBean` 的语义错位：回调打在工厂对象上，真正的 bean 不会被回调

- **位置**：`f_bean/src/PostConstructor.cj:18-20`（契约）+ 调用点 `f_bean/src/BeanManager.cj:77-86`（`new()` 里先 `postConstruct()` 再 `FactoryBean.get()`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `new()` 的顺序是 `let o = creator()` → `if (let x: PostConstruct <- o) { x.postConstruct() }` → `match (o) { case x: FactoryBean => x.get() }`。README 的 `FactoryBean` 段写明"调用本接口的 get 函数返回的对象才是真正的 bean"，因此对 `FactoryBean` 实现类而言：`postConstruct` 跑在**工厂**上（工厂本身不是注册的 bean），而 `get()` 返回的真实 bean 即使实现了 `PostConstruct` 也永远不会被调用。
- **描述**：`@Bean` + `FactoryBean` + 需要后置初始化的产物是常见组合（连接池、代理对象）。当前实现让"后置初始化"落在错误的对象上：工厂可能根本没有初始化逻辑，真正需要在依赖注入完成后执行初始化的产物则被跳过。非 singleton 路径（`:115`）同样走 `new()`，问题一致。
- **建议**：把回调收到最终产物上——`let bean = match (o) { case x: FactoryBean => x.get(); case _ => o }`，再对 `bean` 判 `PostConstruct`/`Destroy`；工厂自身若也需要回调，单列 `postConstruct` 于 `creator()` 之后、`get()` 之前。若确认"回调工厂"是有意设计，请在 README 显式写明这条差异。

### [轻微][存量] 测试把已知缺陷固化成期望值，形成"修复即红"的陷阱

- **位置**：`f_bean/src/test/bean_def_condition_test.cj:64-71`（`@Assert(BeanDef(count: BeanDefCount.Zero).on(factory), true)` 等 5 条）
- **来源**：存量
- **判据**：review-checklist §11（与规格冲突）/ §10（可测试性）
- **证据**：静态确定 —— 文件头注释（`:24-31`）明确写"现实现一律判真 … 本文件按**现状**钉住，不美化"，而 `BeanDef(count: Zero)` 的文档语义是"没有 bean 定义时为真"（`README:387-405`），测试进程里存在大量 bean，正确期望应为 `false`。
- **描述**：第 1/3 部分已把 `BeanDefCondition.cj:126` 的短路判为缺陷。一旦按建议收紧条件，这两条（`BeanDef(count: Zero)` 与 `BeanDef(…, count: Zero)`）立即失败，而失败信息看起来像"新代码破坏了既有契约"。这类"按现状钉住"的断言应在测试名/门禁里显式标记。
- **建议**：改成正确期望并加 `@Ignore`（或框架的禁用属性）+ 注释指向缺陷编号；或把这些断言移进独立的 `bean_def_condition_knownbug_test.cj`，修完即删。

### [轻微][存量] 基准代码放进单元测试，且断言与耗时无关

- **位置**：`f_bean/src/test/bean_getfirst_test.cj:94-114`（30 万次 `getFirst`）、`f_bean/src/test/bean_iterator_test.cj:83-154`（6 万次 × 29 轮，`@Assert(seen, n * 29)`）
- **来源**：存量
- **判据**：review-checklist §10（可维护性）/ `fountain-baseline.md` §8（基准必须 `-O2`）
- **证据**：静态确定（迭代次数与断言内容）；对 CI 时长的实际影响需实测
- **描述**：`testBenchmark*` 只 `println` 耗时、断言的是命中次数，所以既不守护性能也不守护行为；`cjpm test` 默认 `-O0`，打印出的 ns/op 不能当作跨版本对照基线。`bean_iterator_test.cj:153` 还把总次数硬编码成 `n * 29`，调整轮数就得同步改魔数（当前 29 = 2+8+2+8+1+8，与代码一致，但极脆）。
- **建议**：计时部分移到 `bench/`（`cjpm bench -O2`）或整段 `@Ignore`；单测里保留行为断言（`hits == n + warmup` 之类），把 `n` 降到千级。

## 优化可行性方案

> 不是缺陷，是"还能更好"。以下方案的收益都未测量，只作为下一轮补数据的候选。

### [堆内存] `lookupLabels` / `lookupWeights` 仍先物化中间 `ArrayList` 再重建容器

- **现状**：`lookup.cj:97`（`for (bean in lookupList<T>(cond))`）与 `:134`（同）都先构造一份完整的 `ArrayList<T>`（每条都触发 `m.bean`，prototype 会被实例化），随后逐条塞进目标 `HashMap` / `TreeMap` 后被丢弃。两份容器同时存活，峰值 = n 个引用 × 2。同文件 `lookupHashSet` / `lookupTreeSet`（`:57-66`、`:73-81`）已经按 `BEAN-L5` 改成"直接向目标集合填充"，这两处遗漏。
- **方案**：改成 `for (m in BeanFactory.instance.iterator<T>(cond)) { if (let b: T <- m.bean) { map[b.label] = b } }`（`lookupWeights` 同理，把累计权重留在循环内）。与 `getList` 的差别只在"顺手判类型 + 收集"，不引入新语义。
- **预期**：每次调用少一次 n 元素 `ArrayList` 的分配与一次遍历（n = bean 数），GC 压力与峰值内存同步下降；量级在 KiB 且与 bean 数成正比，未测。
- **代价**：与 `getList` 的两处实现再次分叉（可接受，`lookupHashSet` 已是同一取舍）；`getList` 未来若加容量提示，这里不会自动受益。
- **验证**：`getAllocatedHeapSize()` 前后对照 + `lookupLabels` 的 ns/op（`cjpm bench -O2`，bean 数 10/100/1000 三档）；同时断言返回值与现有实现逐项相等。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `lookupLabelOption(cond, label)` 在请求主路径上被调用，全量物化是实际开销 | `f_bean/src/lookup.cj:119-124` | 调用频次 + 单次自耗时 | 全仓搜 `lookupLabel`/`lookupOptionLable` 的调用点（当前为 0），若有下游使用则 `cjprof record` 跑稳态负载，看该方法自耗时占比 |
| 2 | `@Bean` 宏展开时 `tokens += …` 逐组拼接对多泛型组的类呈二次增长 | `f_bean/src/macros/Bean.cj:73-104` | 展开期耗时随 `attr` 组数/参数个数的曲线 | 用 1/4/16 组泛型实参的最小模块测 `cjpm build` 的宏展开耗时（编译期指标，不是运行时） |
| 3 | 单测里的宏基准（30 万 / 6 万×29 次）显著拉长 `cjpm test` 时长 | `test/bean_getfirst_test.cj:94-114`、`test/bean_iterator_test.cj:83-154` | 该两个 `@TestCase` 的耗时与整套测试占比 | `cjpm test --filter` 单独跑这两条，与整套耗时对比 |

## 覆盖自检

### 文件逐条结论（本部分 15 个文件）

| 文件 | 结论 |
| --- | --- |
| `PostConstructor.cj` | 仅一个 `public interface PostConstruct`（`:18-20`）。调用点齐全（`BeanManager.cj:79-81`），但 `FactoryBean` 场景语义错位，见上面「PostConstruct 对 FactoryBean 的语义错位」。文件名 `PostConstructor` 与接口名 `PostConstruct` 不一致（README 小节也叫 PostConstructor），属可读性瑕疵，不单列 |
| `exception/BeanException.cj` | 4 个 `public init` 直接转 `BaseException`，无逻辑；`init() {}` 是"无消息异常"的正常构造，不是空实现。公开类的构造器不判死代码 |
| `imports.cj` | 包级共享 import 前置文件（`internal import` 作用域为整包，不是死文件）。发现：3 个未使用 + 2 组重复导入；`shouldInitBean` / `setShouldInitBean` 已由第 1/3 部分单列 |
| `lookup.cj` | 全部为 `public` 顶层函数，不判死代码；无自有共享可变状态（全部依赖 `BeanFactory.instance` 的只读路径）。发现：标签/累计权重键冲突覆盖、`lookupLabelOption` 全量扫描、`lookupOptionLable` 拼写与重载缺失。`lookup`/`lookupLabel` 的 `getOrThrow` 消息文案相同属重载样板，不按重复计 |
| `macros/Bean.cj` | `expand` / `extractClassDecl` / `expandBean` 三个 private 全在文件内被引用。逻辑基本正确：按 `BITOR` 切分泛型实参组、`removeIf` 清理空组、`@Constructor` 消息为空时退化为 `$beanType()`。风险一行：`@Bean[|]` 这类只有分隔符的属性会让 `list` 清空后**一个 bean 都不注册**且不报错（`:58-70`），建议对 `list.isEmpty()` 补 `diagReport` |
| `macros/BeanParam.cj` | 发现：短写形式因 `attr.size == 3` + `attr[3]` 不可用、白名单大小写错误且缺 `Contains`/`In`、空属性越界。字符串简写（`:23-24`）还与 `Constructor.cj` 的容器分支不匹配（见下） |
| `macros/Configuration.cj` | 发现：不满足条件的 `@BeanInit` 静默跳过（`case _ => break`）、`ClassDecl(input)` 无诊断。`staticTokens` 在 `context` 之前发射、`instanceTokens` 用 `configuration` 前缀，顺序正确；`expandFuncTokens` 已参数化，不构成重复 |
| `macros/Constructor.cj` | 发现：静态工厂分支 `isGenericDecl` 取反、`:28-34` 无效果的 catch-rethrow。`argTokens` 的容器映射本身正确（`ArrayList`→`lookupList`、`Array`→`.toArray()`、`HashMap` 键类型校验），但 `@BeanParam` 的字符串简写在这里只对 `lookup`/`lookupOption` 有 `String` 重载，落到 `lookupList`/`lookupHashSet`/`lookupHashMap` 会生成不存在的重载（`lookup.cj:44-89` 只有 `(StringCond)` 版本）⇒ 集合/Map 形参用字符串简写必编译失败，属上条同一根因，并入「`@BeanParam` 短写不可用」 |
| `macros/Value.cj` | 发现：`delim` 默认值不是字符串、非 Option 的 DateTime/Duration 无 default 时类型不匹配、Array 忽略 default、未知属性静默忽略、`attr[i+2]` 无边界。重复逻辑见 `Constructor.cj` 合条 |
| `macros/imports.cj` | 4 行 import 全部被本宏包使用（`ArrayList`→`Bean.cj:56`、`HashMap`→`Constructor.cj:20`、`std.ast.*`、`f_macros.*`、`BeanException`→`Bean.cj:47`），无死导入 |
| `test/bean_annotation_lookup_test.cj` | 覆盖自身类型/父类/接口三种注解位置、`T` 过滤、`cond` 过滤、order 顺序、map 键、空结果、抛异常、"未命中类型的 prototype 不实例化"（`AtomicInt64` 计数对照）。断言与文件内声明的 bean 自洽（`T=Object` 时 7 个），无死代码、无并发问题 |
| `test/bean_annotation_meta_test.cj` | 元注解链用例，`AnnComposed` 被 `@AnnMeta` 修饰、bean 只标 `@AnnComposed`，与 `doRegister` 的注解节点展开对应；无问题 |
| `test/bean_def_condition_test.cj` | 覆盖两条路径（两个 Ignore / 类型条件）；发现：`BeanDef(count: Zero)` 的现存缺陷被写成期望值。文件头已说明"不跑 `afterRegistered`"，`BeanDefDiscarded` 的可见性断言因此成立 |
| `test/bean_getfirst_test.cj` | 类型键/接口键/父类键/`Any`-`Object` 桶/`beanType:` 重载/非法类型抛异常，覆盖到位；基准段见「基准代码放进单元测试」 |
| `test/bean_iterator_test.cj` | `collectNames` 私有辅助被两个用例使用；迭代器与 `getList`/`getMap`/`getAllTuples` 口径一致性覆盖到位；`n * 29` 魔数与基准段见同一发现 |

### 维度自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：宏生成的目标代码在 3 类形参上不成立（已单列）；设计：`lookup*`（位置形参）与 `BeanFactory.get*`（命名形参）两套约定并存，README 不得不专列一节解释（并入 `lookupOptionLable` 那条的"API 表面不一致"），属可维护性成本而非缺陷；语言特性：本部分 `Option` 全部用 `if (let Some(x) <- …)` / `??` 展开，无静默丢弃，宏侧 `Tokens`/`quote` 用法与 std 语义一致；可读性：`PostConstructor.cj` 文件名与接口名不一致、`lookupOptionLable` 拼写错；安全性：本部分无 SQL、无凭据、无日志泄露（`lookup` 的异常消息只带类型名与条件） |
| §1 死代码 | 1 | 已逐个机械核对：`macros/Bean.cj` 的 `expand`/`extractClassDecl`/`expandBean`、`BeanParam.cj`/`Value.cj` 的嵌套 `setItem`、`Constructor.cj` 的 `constructor`/`argTokens`、`Configuration.cj` 的 `expandFuncTokens` 均有引用；`test/bean_iterator_test.cj:32` 的 `private collectNames` 被两个用例使用；`test/*` 的断言类与注解类全部被引用；无 `return`/`break` 之后的同层语句（`Configuration.cj:45-48` 的 `continue`/`break` 在 `while` 内，语义正确）；`macros/imports.cj` 无死导入。命中 1 条：`imports.cj` 的 3 个未使用 + 2 组重复 import（已单列）。`postConstruct`/`PostConstruct` 有调用点（`BeanManager.cj:79-81`），不判死代码；`lookup.cj` 全部 `public` 且对外可达，按硬原则一不判，仓内引用情况只作信息（`lookupOptionLable` 仓内 0 引用 → 只报拼写与重载缺失，不报死代码） |
| §2 重复逻辑 | 1 | 已把 15 个文件的函数体压成「输入→输出→副作用」两两比对。命中 1 条：`Value.cj` 的 `Option<T>`/`?T` 双份 + DateTime 4 处、`Constructor.cj` 的 cond/no-cond 五形态双份（已单列，含修复落点）。排除项：`lookup.cj` 的 `lookupHashSet`/`lookupTreeSet` 只差容器类型、`HashSet` 与 `TreeSet` 无共同 `add` 接口，抽通用函数只会加一层间接（按 §2「泛型不能乱上」排除）；`lookup`/`lookupOption`/`lookupList`… 的 3 行转发是重载样板；`BeanStringCondition` 的 `toString`/`==` case 表属枚举展开（第 1/3 部分已说明） |
| §3 空实现 | 2 | 命中：`@Configuration` 的 `case _ => break` 静默跳过（已单列）、`@Value` 对 `Array` 的 `default` 与未知属性静默忽略（已并入 `@Value` 条）。其余空体均有正当理由：`BeanException.init() {}` 是"无消息异常"；`Configuration.cj:50` 的 `case _ => ()` 是"类体里非宏声明不处理"；`macros/imports.cj` 只有 import 不是空实现 |
| §4 栈溢出 | 0 | 15 个文件内无递归：`Configuration.cj` / `BeanParam.cj` / `Value.cj` / `Constructor.cj` 的 `while (let md: MacroExpandDecl <- d)` 都是"沿 `macroInputDecl` 逐层解包"，深度 = 注解嵌套层数（代码内常量）；`Bean.cj` 的 `extractClassDecl` 只解一层。`BeanFactory.doRegister` 的显式队列 + `visited`（第 1/3 部分）已阻断类型图环。本部分无"输入长度决定深度"的路径 |
| §5 OOM | 0 | 无界面已核：`lookupList`/`lookupHashSet`/`lookupTreeSet`/`lookupHashMap`/`lookupLabels`/`lookupWeights` 物化的是"某类型的 bean 列表"，规模 = 注册期 bean 数（代码声明，有界）；`lookupLabelOption` 的中间列表同样有界（只浪费，不增长）；宏侧 `Tokens` 拼接只在编译期、规模 = 注解 token 数；测试的基准循环不累积容器。无按不可信长度预分配、无全局缓存（`WILDCARD_REGEX` 的无界问题在第 1/3 部分） |
| §6.1 热点瓶颈 | 0 | `scope.md` 明确"未提供性能资料"，本轮也没有 profile / bench 数据。宏相关开销全在编译期，运行期入口（`lookup*`）只有结构性复杂度可判；`lookupLabelOption`、宏展开耗时、单测基准时长都写进「待验证假设」，不当结论 |
| §6.2 大粒度锁 | 0 | 本部分文件里没有 `synchronized`/`Mutex`：`lookup.cj` 是纯转发，宏是编译期单线程，测试用 `AtomicInt64`。锁相关结论全部属于 `BeanFactory` / `BeanManager`（第 1/3 部分） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无批处理、无单消费者队列 |
| §6.4 低效算法 | 1 | 命中（轻微）：`lookupLabelOption` 为取第一个而全量物化 + 线性扫描（已单列）。其余为 Map/Set 直接查找，无嵌套循环、无 `remove(at: 0)`、无循环内字符串拼接（宏侧 `tokens +=` 只在编译期、组数 ≤ 注解里写的组数） |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 [堆内存]」（`lookupLabels`/`lookupWeights` 的中间 `ArrayList`，无基线）。`clear()`/`gc()` 类假象不涉及 |
| §8 降 CPU 方案 | 0 | 无可给出改前基线的 CPU 方案：`lookupLabelOption` 的早退已作为缺陷（§6.4）单列，不重复计入优化方案；宏展开耗时属编译期，列入待验证假设 |
| §9 local mode 可行性 | 0 | 无"函数内创建、函数内销毁"的大临时对象：`lookup*` 的容器全部作为返回值逃逸（不满足不逃逸前提）；宏侧对象生命周期在编译期，与 local region 无关。收益无法用峰值内存证明 ⇒ 不成立 |
| §11 现有代码的 BUG（存量） | 8 | 已逐条核对并单列 8 条：`@BeanParam` 短写/白名单、`@Constructor` 静态工厂条件取反、`@Value` 三类形参生成非法代码、`@Configuration` 静默跳过、标签/累计权重键冲突、`lookupLabelOption` 全量扫描、`lookupOptionLable` 拼写、`PostConstruct` 对 `FactoryBean` 错位；另 1 条测试侧"缺陷钉死"计入可维护性。`BeanException` 四个构造器、`lookup` 家族转发、测试断言值（`7`/`2`/`29n`）均已复核与文件内声明自洽 |
| §12 并发安全与锁粒度 | 0 | 本部分无自有共享可变状态：`lookup.cj` 的局部容器线程封闭；宏在编译期单线程展开（`Configuration.cj`/`Bean.cj`/`Value.cj` 的 `var` 都是局部）；测试里唯一的跨用例共享量是 `AnnPrototypeBean.created`，用 `AtomicInt64` 且只做"前后差值"断言。运行期共享状态（`BeanFactory` 三张表、`BeanManager._bean`）的同步问题已在第 1/3 部分审计，不在此重复计 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

> 存量 12 条（严重 0、一般 4、轻微 8），本部分全部为存量，无「本次改动」引入项；是否纳入修复待用户决定。

## 总评

这 15 个文件分三类：查找入口（`lookup.cj`）、宏（`macros/*`）、用例（`test/*`），另加一个纯接口（`PostConstruct`）。

**运行期代码是健康的**：`lookup.cj` 只做转发，每条 `lookup*` 都能在 `BeanFactory` 找到唯一下层（`lookupHashSet`/`lookupTreeSet` 还按 `BEAN-L5` 走了 `iterator` 免掉中间列表），`Option` 没有一处被静默丢弃，异常文案统一带类型与条件；`PostConstruct` 的调用点确实存在（`BeanManager.new()`），不是空契约。真正的问题只有两处：`lookupLabels`/`lookupWeights` 的键冲突会静默丢 bean（覆盖语义与 README 的"全部 bean"冲突，权重为 0 时必然触发），以及 `lookupOptionLable` 这个错名被写进了公开 API 与 README。

**宏是本部分的全部风险所在，而且风险高度集中在一个事实：`@Value`、`@BeanParam`、`@Configuration`、`@BeanInit` 在整个仓库里零使用、零测试**（`grep` 全仓无命中，只有 `Configuration.cj` 的注释提到自己）。失去编译覆盖后，静态可判的缺陷全部留了下来：`@BeanParam` 的短写形式因 `attr.size == 3` + `attr[3]` 根本走不到、白名单把 `Prefix`/`Wildcard` 写成小写还漏了 `Contains`/`In`；`@Constructor` 的静态工厂分支把 `isGenericDecl` 用反，导致 README 承诺的"静态函数作为初始化函数"整条不可用；`@Value` 给 `Array` 的 `delim` 默认值塞了一个标点 token、给非 Option 的 `DateTime`/`Duration` 生成 `?T` 赋给 `T`、并把数组的 `default` 静默忽略。这四条都属于"按文档写就编译不过或静默不生效"，但因为无人使用，一直没暴露。

**建议的处理顺序**：① 先给这四个宏补最小用例（每个宏 1~2 条，`@Bean` 泛型组、`@Constructor` 静态工厂、`@BeanParam` 四种构造器写法、`@Value` 标量/数组/Option 各一条）——没有覆盖，修完也无法验证；② 再按用例暴露的顺序修 `BeanParam`（size 与白名单）、`Constructor`（取反）、`Value`（delim/nullable/default 三处）；③ `@Configuration` 的静默跳过改成 `diagReport`，把"编译能过但 bean 不存在"变成编译错误；④ 运行期两条（键冲突、错名 API）改动小、语义明确，可随时做，其中改名属破坏性变更需拍板。

测试侧的评价是正面的：注解查询（自身/父类/接口/元注解）、条件判定、首次查询的类型键覆盖都比较扎实，且 `bean_annotation_lookup_test` 用 `AtomicInt64` 主动验证了"类型不匹配的 prototype 不被实例化"这一容易被忽略的点。唯一要清理的是两类写法：把已知缺陷写成期望值（`BeanDef(count: Zero)` 那 5 条），以及把基准塞进 `cjpm test`（30 万 / 6 万×29 次，且 `-O0` 下的耗时没有对照价值）。

**范围外提示**（不占用本部分统计）：`f_bean/README.md:29` 的示例在 `@Bean` 类内部写 `private let bean = lookup<ClassName>()`，对该类自身 `lookup` 会在单例缓存写入前递归构造，实测会栈溢出；建议 README 换成"查另一个类型"的例子。`BeanFactory`/`BeanManager` 的生命周期与同步问题（`setShouldInitBean` 无效、自定义 `BeanScope` 落点缺失、销毁三缺、读路径无锁）见第 1/3 部分。
