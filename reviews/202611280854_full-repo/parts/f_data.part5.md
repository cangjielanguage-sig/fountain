# f_data 模块审查报告

> **模块第 5/8 部分**（分报告）。本部分只覆盖 `files/f_data.part5.txt` 列出的 20 个文件（全部为 `.cj`，`src/path/CountPathNode.cj` → `src/path/LengthPathNode.cj`）。
> 模块其余 107 个 `.cj` 与 15 个 `.md` 由同模块其他部分产出；本部分编号独立，合并时以主 Agent 为准。
> README / `doc/**` 只作为取证判据被引用，不计入本部分「文件覆盖」。
> 同源问题交叉引用：`parts/f_data.part4.md` #10（`CmpFilter` 每行 `Decimal.parse`）、#1（JSON 深嵌套递归）、#16（缺 `Iterable<(Data,Data)>` 分支）——本部分在 `src/path/` 的同类实现上复现同一模式，合并时可按根因归一。

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 20 个 `.cj`，0 个 `.md`；模块共 127 `.cj` + 15 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 仅有 `docs/review/` 与 `reviews/` 未跟踪，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 5/8 部分）

## 发现

### [严重][存量] #1 `value(...) != x` 被编译成 `value(...) == x`；比较又走 `toString()` 字面量，数值形态不同即判不等

- **位置**：`f_data/src/path/DataPath.cj:367-379`（`emitCmpFilter` 的 `value` 分支，378 行 `quote(ValueCmpFilter($(path), $(valueStr), "false"))`，运算符只做了合法性检查、没有进入生成结果）；`f_data/src/path/ValueCmpFilter.cj:22-36`（35 行 `d.toString() == rightLiteral`，类内没有 `isEq` 字段）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 正确性、§11「契约与实现不符」；RFC 9535 §2.4 `value()` + 比较语义
- **证据**：静态确定 —— 同一函数上方 8 行的 `value_filter` 分支（`DataPath.cj:371-373`）会把 `isEq` 传给 `ValueFilterResult`，而 `value` 分支把第三参硬写成 `"false"`（该参数是 `solid` 而非取反标志），`ValueCmpFilter` 也没有取反位，因此 `==` 与 `!=` 生成完全相同的比较器
- **描述**：`$[?(value(@.status) != 'deleted')]` 实际执行的是 `== 'deleted'`，命中集合正好相反，且不报任何错。即使运算符是 `==`，比较也是 `d.toString() == rightLiteral`：`1` 与字面量 `1.0`、`1e2` 与 `100` 判不等；`rightLiteral` 由 `arg()` 只剥外层引号、不做反转义（`DataPath.cj:794-806`），带转义的字符串同样对不上。这里没有测试兜底（`complex_fn_test.cj` 只覆盖 `count(match(...))` 与 `value` 之外的形态）
- **建议**：`ValueCmpFilter` 增加 `isEq` 字段并在 `check` 末尾取反（与 `ValueFilterResult.cj:39-44` 同一写法）；比较改为按 `Data` 具体类型做（`DataReal` 用 `Decimal`、`DataString` 用 `data`、`DataBool` 用 `Bool.parse`），不要用 `toString()` 当序列化口径

### [严重][存量] #2 路径比较 `EqPathFilter` 递归无深度上限：深嵌套输入直接打爆栈

- **位置**：`f_data/src/path/EqPathFilter.cj:50-60`（`dataEquals`）、`:62-74`（`listEq` 第 69 行回递归）、`:76-90`（`dictEq` 第 82 行回递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定 / 无环检测 / 无深度计数）
- **证据**：静态确定 —— `dataEquals → listEq|dictEq → dataEquals` 形成环，每层嵌套数组/对象各加一帧，代码里既没有 `depth` 参数也没有上限常量；输入侧无兜底：`f_data/src/json` 只有 schema 校验带 `maxDepth = 64`（`JsonSchemaValidator.cj:61`），JSON 解析本身不限制嵌套层数（见 `parts/f_data.part4.md` #1）。崩溃所需的具体层数需实测
- **描述**：`$[?(@.a == @.b)]` 两侧都是深层嵌套结构时递归深度 = 数据嵌套层数。外部数据（HTTP 报文 → `JsonValue.fromBytes` → `toData`）可控，构造几千层即可耗尽线程栈；栈溢出在仓颉里不是 `Exception`，`JsonRpcServer.cj:104-108` 那种 `try` 包不住，进程直接崩溃。同文件 `dictEq` 的递归同样吃深度
- **建议**：改为显式栈迭代（`ArrayList<(Data, Data)>` 待比较对），或给 `dataEquals/listEq/dictEq` 加 `depth` 上限（与 `ValidationOptions.maxDepth` 对齐），超限返回 `false` 并记录；补一条 2000 层嵌套的用例断言不崩溃

### [一般][存量] #3 `match(@.a, search(...))` / `search(@.a, search(...))` 的文档示例恒为 `false`

- **位置**：`f_data/src/path/FnDeferredMatchFilter.cj:32-47`、`f_data/src/path/FnDeferredSearchFilter.cj:32-47`（第 37 行 `filterToFirstValue(regexFilter, data)`，第 38-41 行要求结果是 `DataString`）；依赖：`f_data/src/path/FilterUtils.cj:25-45`、`f_data/src/path/SubPathNode.cj:20-24`
- **来源**：存量
- **判据**：review-checklist §14 功能完备性（承诺源 = 两个类注释 `:18-24`「Enables nesting like `match(@.name, search(@.regexField, 'pat'))`」；缺失证据 = 语义推导对该形态恒 `false`）
- **证据**：静态确定（针对注释给出的形态）—— `filterToFirstValue` 返回的是「第一个满足内层过滤器的**子节点本身**」，随后 `case s: DataString` 又要求这个子节点是字符串；而内层 `search(@.regexField, ...)` 作用在字符串子节点上时，`SubPathNode` 只对 `NamedData` 命中（`:22`），字符串恒空 ⇒ 没有任何子节点能同时满足两条。唯一能通过的组合是内层过滤器以 `@` 为路径（如 `match(@, 'x')`），此时「正则」其实取自某个子串，属偶然可用
- **描述**：文档承诺的嵌套写法永远返回 `false`（过滤器静默不匹配任何行、无异常、无日志），且本部分范围内无测试覆盖（`complex_fn_test.cj:51/65` 只覆盖第二参为**路径**的 `Deferred*` 形态）
- **建议**：先定语义——内层函数表达式的「值」应取内层路径的求值结果，而不是「第一个命中的子节点」；按此重写 `FnDeferred*` 的取值方式，或在 `DataPath.parseFilterTokens` 编译期直接拒绝该写法并抛 `DataException`，避免静默 `false`

### [一般][存量] #4 数值比较分支对右值无条件 `Decimal.parse`：非数值字面量抛异常，字符串字面量反而与数值相等

- **位置**：`f_data/src/path/EqFilter.cj:37`（`case x: DataReal => x.data == Decimal.parse(right.toString())`）；`f_data/src/path/InFilter.cj:40-46`（第 42 行逐个 `Decimal.parse(v.toString())`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 类型边界）、§10 正确性
- **证据**：静态确定 —— `Decimal.parse` 入参不满足数值文法时抛 `IllegalArgumentException`（`math_numeric_package_structs.md:5358-5382`）；`EqFilter` 的 `T` 由调用点决定（`DataPath.cj:831-838` 生成 `String/Int64/Float64/Bool` 四种），`case x: DataReal` 只按数据侧类型匹配，不看 `T`
- **描述**：`$[?(@.n == 'abc')]`（`n` 是数值）在 `check` 内抛 `IllegalArgumentException` 穿出过滤器，调用方按 `DataException` 处理会漏接；`$[?(@.n == '5')]` 又会 `true`（RFC 要求类型不一致即 `false`）。`InFilter` 同一问题，且把解析放进集合遍历里，每个元素 parse 一次。同源：`parts/f_data.part4.md` #10（`CmpFilter`），合并时按一条根因处理
- **建议**：仅当 `T` 为数值类型时才走 `Decimal` 分支，否则直接 `false`；`Decimal` 在构造期算好存字段（见「优化可行性方案」[CPU]）

### [一般][存量] #5 `parseFilterTokens` 比较运算符位于表达式末尾时下标越界

- **位置**：`f_data/src/path/DataPath.cj:407-605` 的 `AT` 扫描分支，`sub[e + 1]` / `sub[e + 2]` 共 20 余处无界访问（代表：`:413`、`:417`、`:422`、`:496`、`:548` 的 `case ASSIGN where sub[e + 1].kind == BITNOT && sub[e + 2].kind == DIV`）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 越界）
- **证据**：静态确定 —— `for (e in i + 1..sub.size)` 的 `e` 能取到 `sub.size - 1`，紧随其后的 `sub[e + 1]` 必然越界；对照同文件 `emitCmpFilter:312` 有 `if (valueIdx >= sub.size) { throw DataException('missing value after comparison operator') }`，说明缺的正是同一处保护
- **描述**：`$[?(@.a ==)]`、`$[?(@.a >)]`、`$[?(@.a =)]` 这类畸形路径在**编译期**抛下标越界异常而不是 `DataException`。路径若来自配置/规则表，上层按 `DataException` 写的降级逻辑接不住，错误信息也指不到位置
- **建议**：在 `AT` 分支循环体入口统一加 `e + 1 < sub.size`（需要时 `e + 2 < sub.size`）守卫，越界抛 `DataException('missing value after comparison operator')`；补 `compile_error_test.cj` 用例

### [一般][存量] #6 「遍历子节点」在 5 个类里各写一遍，其中 2 处缺 `Iterable<(Data, Data)>`：`DataMap` 上的过滤器行为不一致

- **位置**：`f_data/src/path/DataFilterPathNode.cj:20-29`（只有 `Iterable<Data>` / `Iterable<(String, Data)>`，其余落到 `case _` 对整个 map 判断）、`f_data/src/path/ValueFilterResult.cj:33-62`（同样缺）；对照实现完整的：`f_data/src/path/FilterUtils.cj:25-45`、`FnMatchFilter.cj:33-72`、`FnSearchFilter.cj:33-72`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑只改类型名 / 换控制流）、§11（行为漂移）
- **证据**：静态确定 —— `DataMap` 声明为 `Collection<(Data, Data)>`（`f_data/src/base/MapData.cj:29`），`$[?(...)]` 作用其上时两个实现都进 `case _`，把过滤器当成「对 map 自身求值」；其余三处实现遍历 value。同类缺分支已由 `parts/f_data.part4.md` #16 在 `CountFilterResult` 报出
- **描述**：同一语义（对容器子元素逐个 `check`）五份实现，已漂移：键为 `Data` 的 map 上过滤静默不生效（结果为空或整表误判），而 `length()`/`count()`/`match()` 对同一容器却按成员数工作
- **建议**：在 `FilterUtils.cj` 抽 `forEachChild(data, f: (Data) -> Bool): Bool` 与 `firstChild(...)`，五处统一调用；抽完顺手补 `DataMap` 用例

### [一般][存量] #7 `length()` 在路径级按 UTF-8 字节计数、在 filter 级按 rune 计数：同一个函数两套口径

- **位置**：`f_data/src/path/LengthPathNode.cj:26`（`case x: DataString => SingleIterator<Data>(x.data.size.toData())`）vs `f_data/src/path/LengthCmpFilter.cj:38-41`（`for (_ in x.data.runes()) { len++ }`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」「契约与实现不符」；RFC 9535 §2.4 `length()`（字符串取 Unicode scalar 数量）
- **证据**：静态确定 —— 仓颉 `String.size` 是 UTF-8 **字节**数（stdlib `core_package_structs.md:6138-6141` 明确「`size`、下标、切片均基于 UTF-8 编码后的字节」），而 `LengthCmpFilter` 用 `runes()` 数标量
- **描述**：`$.name.length()` 对 `"张三"` 返回 `6`，同一数据用 `$[?(length(@.name) > 2)]` 判断时按 `2` 算。分页、长度校验等按路径取值的业务会与过滤器结论矛盾；ASCII 数据上两者一致，所以很难在测试里发现
- **建议**：把 `computeLen` 提到 `FilterUtils` 供两处共用（`Collection` 三形 + `DataString` 走 rune），并补 `"张三"`、emoji 用例

### [一般][存量] #8 `dataEquals` 不识别 `DataDateTime` / `DataDuration`：同值节点比较恒 `false`

- **位置**：`f_data/src/path/EqPathFilter.cj:50-59`（`case _ => false`）；对照 `f_data/src/path/EqFilter.cj:29-36` 明确支持这两个类型
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：同名比较能力在两个类里不一致）
- **证据**：静态确定 —— `DataDateTime` / `DataDuration` 都是 `Data` 的具体实现（`base/DataDateTime.cj:20`、`base/DataDuration.cj:20`），`dataEquals` 的 match 没有对应分支，落到 `_ => false`
- **描述**：`@.t1 == @.t2` 两边都是同值时间时返回 `false`，`!=` 返回 `true`；`EqFilter` 对同样的数据却能正确比较，使用者无法从 API 看出差别
- **建议**：补 `(x: DataDateTime, y: DataDateTime) => x.data == y.data`、Duration 同理；更彻底的做法是把「按类型比较 Data 值」抽成 `base/data_cmp.cj` 里已有能力的复用，两个过滤器共用

### [轻微][存量] #9 `hasColon` 无调用者（死代码）

- **位置**：`f_data/src/path/DataPath.cj:902-909`
- **来源**：存量
- **判据**：review-checklist §1（`private` 方法全仓无调用；`compileIndexesInSquares:144-148` 自己又写了一遍同样的 COLON 扫描）
- **证据**：静态确定 —— 全仓搜索 `hasColon` 仅定义处命中
- **描述**：切片判定逻辑存在两份，一份是死代码，读代码时会误以为切片走 `hasColon`
- **建议**：删除，或让 `compileIndexesInSquares` 改调它（二选一，别留两份）

### [轻微][存量] #10 `EqPathFilter(String, String, String)` 三参构造无调用者，且把 `isEq` 硬编码为 `true`

- **位置**：`f_data/src/path/EqPathFilter.cj:27-29`
- **来源**：存量
- **判据**：review-checklist §1（`internal` 类的成员全项目无使用即死代码）
- **证据**：静态确定 —— 全仓 `EqPathFilter(` 只有 4 参调用（`DataPath.cj:486`、`:493`、`:872`）
- **描述**：这个构造只能产生 `==` 语义，注释又写着「compares ... for equality」，后来者若图省事用它实现 `!=` 会得到相反结果
- **建议**：删除三参构造，只保留带 `isEqStr` 的四参版本

### [轻微][存量] #11 `DOT DOT` 分支恒不成立，且与 `RANGEOP` 分支逐行重复

- **位置**：`f_data/src/path/DataPath.cj:961-969` vs `:970-979`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）、§2（重复逻辑）
- **证据**：静态确定 —— `cangjieLex` 把 `..` 词法成单个 `RANGEOP`（`ast_package_enums.md:208` `RANGEOP /* ".." */`；模块自述 `doc/RFC9535_COVERAGE.md:45` 也写「IDENTIFIER + RANGEOP」），`path[i]==DOT && path[i+1]==DOT` 永不成立；即使成立，该分支在 `..*` 上还会漏消费 `MUL`（`:965` 只 `i++` 一次，循环末尾再 `i++` 后仍停在 `MUL` 上，会落进 `:995` 的 `throw`）
- **描述**：多出一段与 `RANGEOP` 分支字面同构的死分支，两处「`..` 后必须跟 selector」的校验也要同步维护
- **建议**：删掉 `DOT DOT` 分支，只保留 `RANGEOP`

### [轻微][存量] #12 未使用的 `import`：`FilterUtils` 的 `ArrayList`、`DataPath` 的 `LinkedList` / `HashSet` / `Parsable` / `std.reflect.*`

- **位置**：`f_data/src/path/FilterUtils.cj:18`；`f_data/src/path/DataPath.cj:19-21`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 两个文件内这些符号出现次数均为 1（仅 import 行）；`TypeInfo` 在 `DataPath.cj` 出现 0 次（在 `DataFilter.cj` 才用），`f_base.*` 的 `StringGenerator` 确有使用（`:911`），不在此列
- **建议**：删除无引用的 import，减少误导性依赖

### [轻微][存量] #13 `parseArrayList` / `parseHashSet` 逐行同构；`containsNull` 对同一字符串做第二次词法解析

- **位置**：`f_data/src/path/DataFilter.cj:54-67` 与 `:68-79`（只差容器类型）；`:84-92`（`containsNull`）；调用点 `InFilter.cj:21`、`NinFilter.cj:24` 都同时调用两个函数
- **来源**：存量
- **判据**：review-checklist §2（只改类型名）、§8（同一输入重复解析）
- **证据**：静态确定 —— 两个函数体除 `list.add` / `set.add` 外逐行一致；`InFilter.init` 对同一个 `right` 字符串先 `parseHashSet` 再 `containsNull`，两次 `cangjieLex`
- **描述**：解析规则（允许哪些 token、`null` 怎么处理）写在两处，日后放宽字面量类型容易只改一边；每次构造过滤器多做一遍词法
- **建议**：抽 `parseCollection<T, C>(value, add: (C, T) -> Unit): C`，并让解析同时返回 `hasNull`（一趟词法），`InFilter`/`NinFilter` 各少一次 lex

### [轻微][存量] #14 `filterToFirstValue` 注释承诺返回 `None`，实现返回 `DataNone` 哨兵

- **位置**：`f_data/src/path/FilterUtils.cj:20-24`（「Returns None if no child matches」）vs `:31`、`:36`、`:41`、`:43`（`DataNone.INSTANCE`）
- **来源**：存量
- **判据**：review-checklist §10（注释与实现不符）
- **证据**：静态确定 —— 返回类型是 `Data`，未命中走 `DataNone.INSTANCE`；调用方 `FnDeferredMatchFilter.cj:38-41` 正是按「非 `DataString` 即失败」处理，说明哨兵是设计，注释写错
- **建议**：注释改成 `DataNone`；若想表达「可能没有」，把签名改成 `?Data` 更符合调用方写法

## 优化可行性方案

> 下面都不是缺陷。没有改前基线的一律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] #1 `EqPathFilter.check` 把两侧 nodelist 全量物化成两个 `ArrayList`

- **现状**：`EqPathFilter.cj:35-38` 每次 `check` 为左右各建一个 `ArrayList<Data>`，把 `left.get(data)` / `right.get(data)` 全部抽干；元素数与两侧选择规模同阶（对 `@.*`、`$..*` 可达整棵子树节点数），生命周期仅一次 `check`
- **方案**：改流式比较——两个迭代器同步 `next()`，长度不一致即返回（`listEq` 已经是这种写法，见 `:62-74`），只有 `dictEq` 需要额外结构
- **预期**：单次 `check` 的临时对象从 `O(nL+nR)` 降到 `O(1)`（`dictEq` 除外），GC 次数随之下降；具体降幅待测
- **代价**：`dictEq` 需保持 `O(n·m)` 或改哈希，语义不变
- **验证**：对 10 万节点文档跑 `$[?(@.a == @.b)]`，`cjprof heap` 看分配量与 GC 次数，改前/改后同输入对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #2 `FnMatchFilter` / `FnSearchFilter` 对非字符串子节点做 `d.toString()` 全量序列化

- **现状**：`FnMatchFilter.cj:40`、`:50`、`:60`、`:69` 与 `FnSearchFilter.cj` 同位置，命中子节点不是 `DataString` 时整棵子树转字符串再正则匹配；对「对象数组」做 `match(search(...), ...)` 时每个元素生成一份完整 JSON 文本
- **方案**：只取一层标量（`DataReal/DataBool` 用各自 `toString`，容器直接判 `false`），或在构造期限定只接受 `DataString` 并显式报错
- **预期**：单次 `check` 的分配从「子树大小」降到「标量长度」；峰值内存与耗时均下降，幅度待测
- **代价**：对容器节点不再做「序列化后匹配」这一非标准行为，属于语义收紧，需要确认无下游依赖
- **验证**：1e4 条含嵌套对象的数组，`cjprof` 看 `toString`/序列化自耗时与分配
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #1 `DeferredMatchFilter` / `DeferredSearchFilter` 每次 `check` 重新编译正则

- **现状**：`DeferredMatchFilter.cj:47`、`DeferredSearchFilter.cj:47` 都是 `regexStr.regex()`，即每个候选行编译一次正则；类注释（`:22-25`）说明这是为「pattern 逐行不同」有意为之
- **方案**：加一层按 pattern 的小容量 LRU（命中率高的场景收益明显），或在 `DataPath` 编译期识别「pattern 来自常量路径」时预编译
- **预期**：pattern 基数远小于行数时，正则编译次数从 `O(行数)` 降到 `O(distinct pattern)`；具体比例取决于数据基数
- **代价**：多一份缓存与淘汰逻辑；pattern 全不同时反而多一次查表
- **验证**：1e6 行、pattern 基数 10 / 1e5 两组，`cjpm bench -O2` 对照中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #2 `DataPath.get` 每次求值重建 `flatMap` 闭包链

- **现状**：`DataPath.cj:1002-1008` 每次 `get` 都按 `nodes.size` 现搭一条 `flatMap` 链，每个节点一个闭包对象；`nodes` 在编译后不再变化
- **方案**：编译期把节点序列折成一个组合器（`nodes` 直接持有 `Iterator<Data> -> Iterator<Data>` 的函数数组，或预建 `IndexedAccess`），`get` 时只做一次组装
- **预期**：单次求值的闭包分配从 `O(nodes)` 降到 `O(1)`；节点数少（3~6）时绝对收益有限，需数据判断是否值得
- **代价**：多一层间接调用；可读性略降
- **验证**：对短路径（`$.a.b`）与长路径（8 节点）各跑 1e6 次 `get`，`cjprof` 看分配与自耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `dictEq` 用双层循环按键查找，复杂度 `O(n·m)` | `f_data/src/path/EqPathFilter.cj:76-90` | 两侧键数 n/m 与单次 `check` 耗时占比 | `cjpm bench -O2`，两侧各 1e3/1e4 键的 `DataDict` 比较 |
| 2 | `DataPath.get` 的闭包链重建在短路径高频调用下不可忽略 | `f_data/src/path/DataPath.cj:1002-1008` | 单次 `get` 的自耗时与分配量 | 1e6 次 `$.a.b.get(d)`，`cjprof record` 看 `flatMap` 相关帧 |
| 3 | `Deferred*` 正则重复编译是过滤器的主要自耗时 | `DeferredMatchFilter.cj:47`、`DeferredSearchFilter.cj:47` | pattern 基数、单次编译耗时、占比 | 1e6 行、distinct pattern 10/1e5 两组 `cjprof` |
| 4 | 非字符串节点的 `toString()` 在对象数组上放大分配 | `FnMatchFilter.cj:40/50/60/69` | 单次序列化字节数 × 行数 | 1e4 条嵌套对象，`cjprof heap` 看分配与 RSS |
| 5 | `LengthCmpFilter` 逐 rune 循环在长文本上比 `size` 贵一个量级 | `f_data/src/path/LengthCmpFilter.cj:38-41` | 1KB/1MB 字符串的单次 `computeLen` 耗时 | 微基准 1e5 次，对照 `size` 版本 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/path/CountPathNode.cj` | .cj | ✅ | 与 `LengthPathNode` 结构近似（#6 重复来源之一） |
| 2 | `f_data/src/path/CurrentPathNode.cj` | .cj | ✅ | `@` 恒等节点，无问题 |
| 3 | `f_data/src/path/DataFilter.cj` | .cj | ✅ | 见 #13（`parseArrayList`/`parseHashSet` 同构、`containsNull` 二次词法） |
| 4 | `f_data/src/path/DataFilterPathNode.cj` | .cj | ✅ | 见 #6（缺 `Iterable<(Data,Data)>`） |
| 5 | `f_data/src/path/DataPath.cj` | .cj | ✅ | 见 #1 #5 #9 #11 #12；解析器主体 |
| 6 | `f_data/src/path/DataPathNode.cj` | .cj | ✅ | 单方法接口，无问题 |
| 7 | `f_data/src/path/DeferredMatchFilter.cj` | .cj | ✅ | 正则每次编译，见「优化可行性方案」[CPU]#1 |
| 8 | `f_data/src/path/DeferredSearchFilter.cj` | .cj | ✅ | 同上 |
| 9 | `f_data/src/path/EqFilter.cj` | .cj | ✅ | 见 #4（`Decimal.parse` 右值） |
| 10 | `f_data/src/path/EqPathFilter.cj` | .cj | ✅ | 见 #2 #8 #10 |
| 11 | `f_data/src/path/ExistsFilter.cj` | .cj | ✅ | 无问题 |
| 12 | `f_data/src/path/FilterUtils.cj` | .cj | ✅ | 见 #6 #12 #14 |
| 13 | `f_data/src/path/FnDeferredMatchFilter.cj` | .cj | ✅ | 见 #3 |
| 14 | `f_data/src/path/FnDeferredSearchFilter.cj` | .cj | ✅ | 见 #3 |
| 15 | `f_data/src/path/FnMatchFilter.cj` | .cj | ✅ | 见 #6、「优化可行性方案」[堆内存]#2 |
| 16 | `f_data/src/path/FnSearchFilter.cj` | .cj | ✅ | 同上 |
| 17 | `f_data/src/path/InFilter.cj` | .cj | ✅ | 见 #4、#13 |
| 18 | `f_data/src/path/IndexPathNode.cj` | .cj | ✅ | 负索引分支由切片构造（`RangePathNode.cj:52`）可达，非死代码 |
| 19 | `f_data/src/path/LengthCmpFilter.cj` | .cj | ✅ | 见 #7；逐 rune 计数见待验证假设 #5 |
| 20 | `f_data/src/path/LengthPathNode.cj` | .cj | ✅ | 见 #7（字节计数） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（#1 `value()!=`、#7 `length()` 双口径）；可读性 2（#9 #14 注释/死代码干扰阅读）；设计与语言特性：节点/过滤器均「编译期构造、运行期只读」，`Data` 用 struct（`DataString`）无装箱隐患，未发现问题；安全性：本部分只消费内存中的 `Data`，无字符串拼 SQL/命令、无凭据、无外部 IO，未见注入面 |
| §1 死代码 | 3 | 逐个 `private`/`internal` 符号全仓搜引用：`hasColon`（#9）、`EqPathFilter` 三参构造（#10）为唯一「仅定义处命中」；`DOT DOT` 分支恒不成立（#11）；未使用 import 4 条（#12）。其余 `private`（`extractSubPathInSquares`/`compileSubsInSquares`/`parseSetOp` 等）均有调用；对外可达的 `public`（`DataPath.solid/cache/get`）不判死代码，仓内确有引用（`fprobe/src/alarm/AlarmEngine.cj:193`、`f_data/.../DataFilter.cj:34`） |
| §2 重复逻辑 | 3 | 已对 20 个文件两两比对函数体摘要：三分支子节点遍历 5 份（#6）、`parseArrayList`/`parseHashSet` 同构（#13）、运算符×字面量映射在 `parseFilterTokens` 与 `emitCmpFilter` 两处各写一份（#1 的根因，另见 `parts/f_data.part4.md` #15）；`CountPathNode`/`LengthPathNode` 结构近似但语义不同（一个计数、一个长度），未并条 |
| §3 空实现 | 0 | 逐个 `catch`/空分支核对：本部分无 `catch {}`、无 `TODO`/`FIXME`、无 `UnsupportedException`；`case _ => OptionIterator()`、`case _ => false` 都是「该类型不选中」的正常语义，不是空实现 |
| §4 栈溢出 | 1 | #2：`dataEquals/listEq/dictEq` 无深度上限；另核 `parseFilterTokens`（`:405`）与 `compileFilter`（`:895-899`）按括号/AST 递归，深度由路径长度决定——路径通常是开发期常量，未单列，并入 #2 的建议 |
| §5 OOM | 0 | 已按「最坏输入 × 单元素内存」核对：本部分无「整文件读入」「按报文头预分配」「全局只增容器」；`subFilters`/`nodes` 只在编译期增长且随缓存条目有界（`CacheDataPath` 上限 10000）。`EqPathFilter` 的临时物化是「放大分配」而非无界增长，已放「优化可行性方案」[堆内存]#1 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，本部分没有任何「函数 + 自耗时占比 + 输入规模」的证据，故不成立；已把 5 条疑似热点写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`；`DataPath` 的编译期字段（`nodes`、`subFilters`）在实例发布后只读 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用，无本模块内的串行段 |
| §6.4 低效算法 | 1 | `dictEq` 双层循环 `O(n·m)`（待验证假设 #1，缺输入规模与耗时占比，未升级为发现）；`IndexPathNode` 的 `skip(n).take(1)` 是 `O(n)`，但索引选择本就如此，未计 |
| §7 降堆内存方案 | 2 | [堆内存]#1（`EqPathFilter` 两侧物化）、#2（`toString()` 序列化放大）；其余节点均为惰性迭代器，无中间副本可省 |
| §8 降 CPU 方案 | 2 | [CPU]#1（正则重复编译）、#2（`flatMap` 链重建）；`Decimal` 预算化与 `parts/f_data.part4.md` 优化 #1 同源，本部分不重复计 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完的大对象」：唯一 O(选择规模) 的临时结构是 `EqPathFilter` 的两个 `ArrayList`，但它们参与跨函数比较后即释放、收益只能靠峰值内存证明，而当前无峰值基线；不建议改造 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的 20 个文件的边界/空值/错误处理/契约已逐函数核对：#1 #3 #4 #5 #6 #7 #8（+ #2 的递归）均为存量缺陷；`EqFilter`/`InFilter`/`IndexPathNode` 的空集合与 `None` 路径已核对无越界；`parseIndexToken` 的负索引拒绝与 `RangePathNode` 的负切片配合正确 |
| §12 并发安全与锁粒度 | 0 | 逐个共享点核对：`nodes`/`subFilters` 只在 `doCompile` 期间写入，实例经 `ConcurrentHashMap.computeIfAbsent`（`SolidDataPath.cj:27`）/`HeapCache.getOrCompute`（`CacheDataPath.cj:24`）发布后才被 `get` 读取，发布后无写入；各 `DataFilter.check` 只用局部变量（正则、`ArrayList` 都在方法内创建），无共享可变状态、无惰性初始化、无跨线程句柄。故判线程安全，锁粒度不适用 |
| §14 功能完备性与 README 覆盖 | 1 | #3（`FnDeferred*` 承诺的嵌套形态恒 `false`）。README 层面：`DataPath.cache/solid/get` 均在 `README.md:389-395` 有对应段落，本部分 public 能力无遗漏；`DataPath` 头注释列出的 `stddev()` 仍未实现（`:41` 自注「未实现」），属已知标注，不另计 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无缺读；`.md` 为 0 个，故 §13 不适用（模块 README 一致性由其他部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量缺陷 14 条（严重 2、一般 6、轻微 6），是否纳入修复待用户决定。

## 总评

本部分（`src/path/` 的节点与过滤器全家桶）整体结构是清楚的：节点与过滤器在编译期构造、运行期只读，`Data` 遍历走惰性迭代器，并发面干净——没有共享可变状态、没有锁、没有全局只增容器，`§12` 可以判安全。

真正的风险集中在两处。**一是语义口径不一致**：`value()` 的 `!=` 被 `emitCmpFilter` 丢掉（#1），`length()` 在路径级按字节、在 filter 级按 rune（#7），`dataEquals` 少了 datetime/duration（#8），`DataFilterPathNode`/`ValueFilterResult` 少了 `Iterable<(Data,Data)>`（#6）——它们都不会报错，只会安静地给出相反或缺失的结果，这是本部分最该先修的类别。**二是异常路径不受控**：数值比较对非数值字面量抛 `IllegalArgumentException`（#4），畸形路径在编译期抛下标越界（#5），`EqPathFilter` 的递归无深度上限可直接打爆栈（#2）；对以 `DataException` 为契约的调用方，前两者会漏接，后者是进程级崩溃，应作为阻塞项。

修复顺序建议：#1 / #2 先做（结论错误与崩溃），#4 / #5 / #6 / #7 / #8 同批（都是小改、可加用例锁住），#3 需要先定语义再动代码。`§1`/`§2` 的六条轻微项都是「删一段或并一处」，适合跟随上述改动顺手清掉——尤其 #6 的抽取，能把 #6 与 #1 的漂移根因一起消掉。性能与内存的四条方案全部无基线，留待下一轮补 `cjprof` / `cjpm bench -O2` 数据后再决定是否立项。
