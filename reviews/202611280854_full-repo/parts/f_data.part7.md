# f_data 模块审查报告

> **模块第 7/8 部分**（分报告）。本部分只覆盖 `files/f_data.part7.txt` 列出的 20 个文件（全部为 `.cj`，`src/path/StructEqFilter.cj` → `src/test/data_test.cj`）。
> 模块其余 107 个 `.cj` 与 15 个 `.md` 由同模块其他部分产出；本部分编号独立，合并时以主 Agent 为准。
> README / `doc/**` 只作为取证判据被引用，不计入本部分「文件覆盖」。
> 同源问题交叉引用（不重复计数）：`parts/f_data.part5.md` #1（`ValueCmpFilter` 丢失 `!=`，本部分 #4 是同一条 `toString()` 比较线的类型面）、#6（`ValueFilterResult` 缺 `Iterable<(Data,Data)>` 分支）、#8（`dataEquals` 不识别 datetime/duration）；`parts/f_data.part6.md` #3（字面量 token 值不含引号，本部分 #1 的前提）、#13（`ObjectEqFilter`/`StructEqFilter` 的 `splitByComma`、`dataEquals` 重复）。

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 20 个 `.cj`，0 个 `.md`；模块共 127 `.cj` + 15 `.md`）
- **基线**：工作区快照（`git blame` 显示 `src/path/*` 落在 `4be871f2f`，`src/test/DataAssist_test.cj` 为 2026-11-27 新增 `f_data` local-mode 用例，`src/test/JsonSchema_test.cj` 为 2026-11-07；无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 7/8 部分）

## 发现

### [严重][存量] #1 数组结构相等遇到字符串元素必抛格式异常：`parseRaw` 按「元素带引号」解析，而 token 值已被词法器去引号

- **位置**：`f_data/src/path/StructEqFilter.cj:32-60`（`parseRaw`）；关键分支 `:45-47`（只有元素首字节是 `0x27`/`0x22` 才构造 `DataString`）、`:53-57`（其余一律按 `Float64.parse` / `Int64.parse`）；触发点 `f_data/src/path/DataPath.cj:455-467`（`EQUAL`/`NOTEQ` + `LSQUARE` → `StructEqFilter(..., $(Token(STRING_LITERAL, arrContent)), ...)`）、`:910-916`（`concatTokenValues` 只拼 `t.value`）
- **来源**：存量（`git blame -L 32,60`：全部来自 `4be871f2f`；`DataPath.cj:459/465` 同一提交）
- **判据**：review-checklist §11「契约与实现不符」「错误处理缺失」、§10 正确性；承诺源 `StructEqFilter.cj:20-23` 类注释（array/object 结构比较）、`f_data/doc/RFC9535_COVERAGE.md:126-127`（`@.* == [1, 2, 3]` 由 `StructEqFilter` 支持）
- **证据**：静态确定 —— ①`std.ast` 的 `STRING_LITERAL.value` / `SINGLE_QUOTED_STRING_LITERAL.value` **不含外层引号**（`ObjectEqFilter.cj:70` 的作者注释明确写了这一点，`parts/f_data.part6.md` #3 亦以 `cangjieLex` 实测确认）；②`DataPath` 把整段数组字面量用 `concatTokenValues` 拼成文本，引号在拼接前就不存在，`arg(args, 1)` 也不加引号（`DataPath.cj:794-806` 只在首字节是引号时**去**引号）；③于是 `parseRaw` 收到的 `['a', 'b']` 已是 `[a,b]`，`p[0]` 不是引号 → 跳过 `:45` → `p.contains(".")`/`contains("e")` 为假 → `Int64.parse("a")` 抛 `NumberFormatException`。`parseRaw` 里的引号剥离分支在当前调用路径上**不可达**（死分支），这正是作者对输入形态的错误假设
- **描述**：`$[?(@.tags == ['a', 'b'])]`、`$[?(@.tags != ['a'])]` 这类完全合法的写法在建路径时就抛 `NumberFormatException`（不是契约里的 `DataException`）。若调用方只 `catch (e: DataException)`（`DataPath` 全仓都以 `DataException` 为错误契约，见 `compile_error_test.cj:24-58`），异常直接逃逸到业务栈上，等价于该请求崩溃。嵌套数组同理：`@.x == [[1,2],[3]]` 的元素 `[1,2]` 首字节是 `[`，落进 `:56` `Int64.parse("[1,2]")` 再次抛出；`[[...]]` 的 depth 跟踪（`splitByComma`）看起来是为嵌套准备的，但元素解析器并不支持嵌套。现有覆盖只测了整数数组（`filter_test.cj:401-427` `@.* == [1, 2, 3]`），字符串/布尔数组、嵌套数组、含逗号字符串全部无用例，所以长期未被发现
- **建议**：与 `ObjectEqFilter` 的修法一致——不要从文本二次解析，直接让 `DataPath` 按 token 类型构造 `ArrayList<Data>` 传给 `StructEqFilter`（`STRING_LITERAL → DataString(value)`、`INTEGER_LITERAL → DataReal(Int64.parse)`、`FLOAT_LITERAL → DataReal(Float64.parse)`、`BOOL_LITERAL → DataBool`、`IDENTIFIER("null") → DataNone`、`LSQUARE → 递归`）；最低成本的热修是在 `parseRaw` 里改走 `DataFilter.parseArrayList<...>`/`cangjieLex`，但要先解决 `T` 的运行期分派。补 `['a','b']`、`[true, null]`、`[[1],[2]]`、`['a,b']` 四组用例

### [一般][存量] #2 `ValueFilterResult` 对文档给出的用法恒为 `false`：比较的是「命中的父节点」而不是字段值，且只认 `DataString`

- **位置**：`f_data/src/path/ValueFilterResult.cj:32-63`（`:34-44` `Iterable<Data>` 分支、`:45-54` `Iterable<(String, Data)>` 分支、`:55-62` 标量分支）；三处 `case _ => !isEq`（`:40`、`:50`、`:59`）是丢弃比较的兜底
- **来源**：存量（快照模式无基线；`git blame -L 32,63` 全部落在 `4be871f2f`）
- **判据**：review-checklist §3「契约承诺有行为、实现只覆盖一种类型」、§11「契约与实现不符」、§14（承诺源：`README.md:511`「`value(search(...))` 嵌套取值 `value(search(...)) == "X"`」、`ValueFilterResult.cj:18-23` 类注释示例 `value(search(@.name, 'lice')) == 'Alice'`；`RFC9535_COVERAGE.md:104` 与 `README.md:722` 均把它列为 `value()` filter 比较的实现）
- **证据**：静态确定 —— 内层过滤器（`SearchFilter(@.name, ...)`）作用在**子节点**上，命中时返回 `true`，但随后 `match (d)` 里的 `d` 是那个子节点本身（对象/`DataDict`），不是 `@.name` 解析出的字符串；对象落进 `case _ => !isEq`，于是 `==` 恒 `false`、`!=` 恒 `true`。即使子节点恰好是 `DataString`，也只有 `s.data == literal` 一条比较路径（`:39`/`:49`/`:58`），数字/布尔/null 一律走 `case _`
- **描述**：按类注释写的 `$[?(value(search(@.name, 'lice')) == 'Alice')]` 永远筛不出任何元素（`!=` 则全通过），且无异常、无日志。该形态与 `parts/f_data.part5.md` 报出的 `FnDeferredMatchFilter`/`FnDeferredSearchFilter`「取到的是子节点本身、却要求它是 `DataString`」是同一设计缺陷，只是换了个包装类。`RFC9535_COVERAGE.md:104` 声称覆盖来自 `testFilterValueEq`，但该用例的 `value(@.name)` 没有函数参数，走的是 `ValueCmpFilter`（`DataPath.cj:684-693`），**`ValueFilterResult` 在整个仓库没有任何测试**
- **建议**：内层过滤器命中后，应再按「内层表达式求出的值」比较——让内层过滤器返回命中的 `Data`（如 `FilterUtils.filterToFirstValue`，`FilterUtils.cj:25-45`）而不是 `Bool`，或者把 `value(innerFilter)` 编译成「内层路径 + 内层过滤」后再取首节点；比较统一走 `EqFilter` 的类型化口径。补 `value(search(@.name,'lice')) == 'Alice'`、数字、`!=` 三组用例，并修正 `RFC9535_COVERAGE.md` 的覆盖归属

### [一般][存量] #3 `subsetof` 的成员判定把右值铸成 `HashSet<String>`：`null` 元素被静默丢弃，数值/字符串跨类型互相当作相等

- **位置**：`f_data/src/path/Subset.cj:21-26`（构造期 `this.right.add(v.toData().toString())`）、`:27-49`（`subset` 用 `right.contains(v.toString())` / `contains(k)`）；`SubSetOfFilter.cj:25-37`（`subset(data) == size`）；依赖 `DataFilter.cj:54-67`（`parseArrayList` 对 `IDENTIFIER("null")` 直接 `()`）
- **来源**：存量（快照模式无基线；`git blame -L 21,49` 落在 `4be871f2f`）
- **判据**：review-checklist §11「契约与实现不符」「边界/空值未处理」、§10 正确性；对照实现 `InFilter.cj:19-31`（`hasNull` 单独记录，`DataNone` 命中时返回 `hasNull`）、`:40-46`（`DataReal` 按 `Decimal` 数值比较）
- **证据**：静态确定 —— ①`parseArrayList<T>` 在遇到 `null` 时**不往列表里放任何东西**（注释写明「null is handled specially in InFilter.check()」），而 `Subset` 的构造器没有对应的 `hasNull` 位，`right` 里永远不会出现 null 的表示，`DataNone.toString()` 又是 `"None"`（`base/DataNone.cj:21-23`）≠ `"null"`；②成员判定全部是 `toString()` 文本相等（`:34`/`:37`/`:40`/`:44`），而 `InFilter` 对 `DataReal` 走 `Decimal.parse(v.toString())` 数值比较
- **描述**：`$[?(@.tags subsetof [null, 'a'])]` 中右集合实际只有 `{'a'}`，元素 `DataNone` 永远不命中（`size=1`、`subset=0` ⇒ `false`），而同一写法换成 `in [null, 'a']` 是 `true`——`in`/`nin` 与 `subsetof`/`anyof`/`nooneof`（`AnyOfFilter`/`NoOneOfFilter` 同样继承 `Subset`，属其他部分）口径分裂。数值面同样漂移：`DataReal("30.0")` 的 `toString()` 保留 scale（`"30.0"`），而右值 `30` 铸成 `"30"`，`subsetof [30]` 判 `false`、`in [30]` 判 `true`；`DataString("30")` 又会与 `subsetof [30]` 互相命中（`SubSetOfFilter<T>` 的 `T` 在编译期由字面量决定，运行时并不校验 `Data` 的实际类型）
- **建议**：把 `Subset.right` 换成与 `InFilter` 同构的表示——`T` 的强类型集合 + `hasNull: Bool`（`DataFilter.containsNull(right)` 已现成，`DataFilter.cj:80-92`），`subset` 按 `data` 的实际类型分派：`DataNone → hasNull`、`DataReal → Decimal` 比较、`DataString/DataBool → contains`；`SubSetOfFilter.check` 的 `size` 与命中数在同一次遍历里算（见「优化可行性方案」[CPU]#1）。补 `subsetof [null]`、`subsetof [30]` 对 `DataReal("30.0")`、字符串 `"30"` 三组用例

### [轻微][存量] #4 `value()` 比较用 `toString()` 做文本等价，跨类型与浮点表示都会误判

- **位置**：`f_data/src/path/ValueCmpFilter.cj:27-36`（`:35` `d.toString() == rightLiteral`）；右值来源 `DataPath.cj:314`（`valueStr = valueToken.value`，即去引号后的原文）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与实现不符」、§10 正确性
- **证据**：静态确定 —— `DataString.toString()` 返回裸串（`base/DataString.cj:26-28`），`DataReal.toString()` 返回 `Decimal.toString()`（`base/DataReal.cj:220-222`），两者同为 `"30"` 时文本相等，比较层不再区分类型；`DataBool.toString()` 为 `"true"/"false"`（`base/DataBool.cj:24-26`），`DataNone.toString()` 为 `"None"`
- **描述**：`value(@.code) == 30` 对 `DataString("30")` 判 `true`；`value(@.x) == 'true'` 对 `DataBool.TRUE` 判 `true`；`value(@.x) == null` 永远 `false`（`DataNone` 的文本是 `"None"`）。浮点面取决于 `Decimal` 是否保留 scale（`DataReal("30.0")` vs 字面量 `30`），这一点未实测，标 `待确认`。与 `parts/f_data.part5.md` #1（`!=` 被 `emitCmpFilter` 丢成 `==`）是同一行的两个独立缺陷：这条管「怎么比」，part5 管「取不取反」
- **建议**：`ValueCmpFilter` 增加 `isEq` 并把右值按 `Data` 类型解析（数字用 `Decimal`、字符串用 `data`、布尔用 `Bool.parse`），比较复用 `EqFilter`；`null` 交给 `NullFilter` 语义。补跨类型反向用例（数字 `30` 不应命中字符串 `"30"`）

### [轻微][存量] #5 `StructEqFilter` 类注释的示例写法不成立：比较的是 nodelist 条数，单个数组节点恒不匹配

- **位置**：`f_data/src/path/StructEqFilter.cj:20-23`（注释示例 `@.items == [1, 2, 3]`）与 `:74-88`（`results.size != right.size → false`，元素逐个比）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与注释不符」、§13 文档一致性（代码内契约注释）
- **证据**：静态确定 —— `@.items` 经 `SubPathNode` 只产出 1 个节点（`SubPathNode.cj:20-25`），即使该节点是 `DataList(1,2,3)`，`results.size == 1` 与 `right.size == 3` 不等，直接 `allMatch = false`；实际可命中的写法是 `@.* == [1,2,3]`（3 个节点），这也正是 `RFC9535_COVERAGE.md:126` 与 `filter_test.cj:410` 采用的形态
- **描述**：按注释写 `@.items == [1, 2, 3]` 的调用方会得到「永远不匹配」且没有任何提示；同时 `@.*`（多节点）按 RFC 9535 §2.3.5.2.2 应当为 `false`（非单节点 nodelist 不参与比较），当前实现返回 `true`。两种语义都被「条数比较」实现反过来了，但仓库文档只承诺 `@.*` 一种形态，故只作轻微记录
- **建议**：注释改成 `@.* == [1, 2, 3]`（与 coverage 文档一致），或把实现改成「单节点且该节点是 `Collection` 时逐元素比较」。若要贴 RFC，需先确认 `@.*` 的多节点比较是否应该为 `false`（`待确认`：取决于本项目是否刻意扩展 RFC）

### [轻微][存量] #6 `StructEqFilter` 的三参构造器全仓无调用者

- **位置**：`f_data/src/path/StructEqFilter.cj:26-28`（`init(left, rightStr, solid)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「非 public 符号无调用者」（`internal class`，按本包及子包判定）
- **证据**：静态确定 —— 全仓 `grep "StructEqFilter("`（排除 `.worktrees`）只有 `DataPath.cj:459/465`（quote 文本，四参）与 `DataPath.cj:870`（四参实例化）；三参版本零引用，`git log -S` 无其它调用痕迹。同类形态 `ObjectEqFilter.cj:28-30` 的三参构造器同样无调用者（属第 6 部分，交叉引用）
- **描述**：为一个不存在的调用形态保留入口，读者会误以为存在「默认 `==`」的编译路径；与四参构造器的 `isEq` 默认值也不一致（三参恒 `true`）
- **建议**：删除该构造器；若为兼容保留，至少在注释里写明保留原因

### [轻微][存量] #7 五个测试文件 import 了未使用的 `DataException`

- **位置**：`f_data/src/path/complex_fn_test.cj:22`、`filter_test.cj:22`、`integration_test.cj:22`、`object_eq_test.cj:22`、`p1_gaps_test.cj:22`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `grep -c DataException` 在这 5 个文件里均为 1（只命中 import 行）；`basic_test.cj`（4）、`compile_error_test.cj`（4）、`recursive_test.cj`（3）确有 `catch (_: DataException)` 使用，`rfc9535_slice_test.cj` 未 import
- **描述**：无用依赖，`cjlint` 的 unused import 规则会报；不影响行为
- **建议**：删除这 5 行 import（或统一由 `std.unittest`/`f_data.base` 通配导入承担）

### [轻微][存量] #8 `basic_test.cj` 的 `assertDataStr` 从未被调用

- **位置**：`f_data/src/path/basic_test.cj:41-44`（`private func assertDataStr(expected, data): Bool`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者」（`private`，全仓搜）
- **证据**：静态确定 —— 全仓 `grep assertDataStr` 只命中定义处与 `basic_test.cj.macrocall:341`（同一定义的展开副本）；所有断言都直接写 `@Assert("42", results[0].toString())`
- **描述**：该 helper 返回 `Bool` 而调用处一律用 `@Assert`，形状也不匹配，属于写了一半的辅助函数
- **建议**：删除；或改成 `func assertDataStr(expected: String, data: Data)` 内部 `@Assert`，再统一替换散落的 `@Assert(x, y.toString())`

### [轻微][存量] #9 `TestObj` 是测试替身，却放在生产目录 `src/path/` 并被库一起编译

- **位置**：`f_data/src/path/TestObj.cj:26-62`（`internal class TestObj <: Data & NamedData`）；`:50-61` 四个 `Data` 接口静态方法分别是 `throw DataException(...not supported)` / `return None`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「仅测试使用 → 可见性/组织建议，不是死代码」、§3（接口占位实现）
- **证据**：静态确定 —— 全仓引用只在 `src/path/*_test.cj`（`basic/filter/integration/complex_fn/p1_gaps/recursive` 六个文件）；`:50-61` 的 `fromData`/`tryFromData`/`parse`/`tryParse` 是 `FromToData`/`DataParsable<Data>` 的接口实现（按硬原则不算死代码），但行为是显式不支持：`tryParse` 返回 `None` 与 `data_test.cj:77-83` 记录的契约一致，`fromData`/`parse` 直接抛
- **描述**：生产包内携带一个 `toString()` 输出非 JSON（`{"name":Alice}`）、`fromData`/`parse` 必抛的 `Data` 实现，任何同包代码 `as Data` 之后调用都可能在运行期炸；同时它让「`src/path` 的 `Data` 实现清单」多出一个不可用项，增加维护与误用面
- **建议**：移到 `src/path/TestObj_test.cj`（Cangjie 的 `*_test.cj` 只在测试构建参与），或在文件头加 `@When[test]` 条件编译；不建议改 `public`（会变成对外契约）

### [轻微][存量] #10 `SubSetOfFilter.check` 与 `Subset.subset` 各写一份类型分派，并对同一路径求值两次

- **位置**：`f_data/src/path/SubSetOfFilter.cj:25-37`（先取首节点算 `size`）与 `f_data/src/path/Subset.cj:27-49`（`subset` 再取一次首节点、再分派一次）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同文件/同族函数语义相同而实现两份」、§6.4「同一输入重复计算」
- **证据**：静态确定 —— 两处都是 `left.get(data).next()` + `match` 三型分派；`check` 用 `Collection<...>`（要 `.size`），`subset` 用 `Iterable<...>`（要遍历），类型集合不一致：若将来出现「`Iterable` 但非 `Collection`」的 `Data`，`size` 会落进 `case _ => 1`，与遍历出的命中数不再同口径
- **描述**：`subsetof` 每次判定都把左路径完整求值两遍（路径可能含 `..`／过滤器，代价与文档树规模同阶），且两份分派表需要同步维护。当前所有 `Data` 容器都同时是 `Collection`（`DataList <: Collection<Data>`、`DataDict <: Collection<(String,Data)>`、`DataTuples <: Collection<(Data,Data)>`），所以还没有可见的行为差异
- **建议**：`Subset` 提供 `subsetSize(data): (Int64, Int64)`（总规模, 命中数），一次求值同时返回两者；`SubSetOfFilter`/`AnyOfFilter`/`NoOneOfFilter` 只读返回对

### [轻微][存量] #11 测试用例重复：`integration_test` 两条用例逐行相同、`basic_test` 三条负索引用例同构、`collect()` 在八个文件各写一份

- **位置**：`f_data/src/path/integration_test.cj:113-126`（`testRecursiveDescentTitle`）与 `:155-168`（`testRecursiveDescentBooks`），函数体完全相同（同样两个 `TestObj` + `"$..title"` + `@Assert(2, ...)`）；`basic_test.cj:96-105`、`:107-116`、`:273-282`（`$[-1]` / `$[-2]` / `$[-100]` 三个只差字面量的拒绝用例）；`collect()` 出现在 `basic_test.cj:26`、`complex_fn_test.cj:26`、`filter_test.cj:26`、`integration_test.cj:26`、`object_eq_test.cj:26`、`p1_gaps_test.cj:26`、`recursive_test.cj:26`、`rfc9535_slice_test.cj:30`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（误报边界：测试准备代码不计重复，故只作轻微记录）
- **证据**：静态确定 —— 上述两段用例除函数名与注释外 token 序列一致；`collect` 八份实现逐行相同（`for (d in itr) { list.add(d) }`）
- **描述**：重复用例不会带来额外覆盖（同名断言、同一数据形状），却让失败时的定位成本翻倍；`collect` 的八份拷贝在需要改签名时要改八处
- **建议**：删掉 `testRecursiveDescentBooks`；三条负索引合并为一个参数化 `@TestCase[...]`；`collect` 收敛到测试包内的一个公共 helper（如 `src/path/TestSupport_test.cj`）

### [轻微][存量] #12 `p1_gaps_test` 的生成器注释与实现不符，并显式断言「解析器没有深度上限」

- **位置**：`f_data/src/path/p1_gaps_test.cj:170-183`（注释称 depth 1 生成 `match(@.name, 'A.*')`）与 `:184-194`（`genNestedMatch` 实际拼的是 `'Alice'`）；`:219-228`（depth 30 的 stress 用例，`catch (_: Exception)` 后 `@Assert("depth=30 failed", "ok")` 故意必败）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与注释不符」、§4（测试自述的递归深度事实）
- **证据**：静态确定 —— `genNestedMatch` 的唯一字面量是 `'Alice'`，`'A.*'` 只出现在注释里；`:180-183` 原文「the parser has no depth counter or recursion limit」
- **描述**：注释误导后来者（以为在测正则前缀），而「无深度上限」这句话本身是真实风险信号：`DataPath.cache` 对 `((((...))))`／`match(match(...))` 的编译是递归下降，深度只由输入字符串长度决定；本条属于**范围外提示**（解析器在 `DataPath.cj`，属其他部分），本部分仅记录测试侧的自述证据，不重复计数
- **建议**：修正注释；把 depth 30 的用例改成「超过 N 层必须抛 `DataException`」的显式上限契约（或在解析器侧加深度计数后断言该异常），使这条 stress 用例具备可判定的期望

## 优化可行性方案

### [堆内存] #1 `StructEqFilter.check` 把整个左 nodelist 物化，可在长度不匹配时提前退出

- **现状**：每次 `check` 都 `new ArrayList<Data>()` 并把 `left.get(data)` 全量收进内存（`StructEqFilter.cj:76-79`），随后只用 `size` 与逐元素比较（`:81-86`）；左路径若是 `@..*`／`$..*`，物化规模 = 子树节点数
- **方案**：先取 `right.size`，边迭代边计数，超过 `right.size` 立即返回 `isEq ? false : true`；比较阶段不再需要 `results` 数组（双迭代器并行 `next`）
- **预期**：单次 `check` 少一次与左结果集同阶的数组分配（对象数 = 命中节点数 + 扩容副本）；对不匹配的宽选择器可直接省掉整轮遍历
- **代价**：需保证「元素顺序」语义不变（当前按序比较，双迭代器同样按序）；`isEq == false` 的短路条件要写对
- **验证**：10 万节点文档 + `@.* == [1,2]`，`cjprof heap` 看该帧分配量与 GC 次数；`cjpm bench -O2` 对照
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] #2 `Subset`/`ValueCmpFilter` 每次判定都生成 `toString()` 临时串

- **现状**：`Subset.subset` 对每个元素调 `v.toString()`（`Subset.cj:34`、`:40`、`:44`），`ValueCmpFilter.check` 对命中值调 `d.toString()`（`ValueCmpFilter.cj:35`）；`DataReal.toString()` 内部走 `Decimal.toString()`（`base/DataReal.cj:220-222`），每次生成一个新 `String`
- **方案**：改为类型化比较（`DataReal` 用 `Decimal`、`DataString` 用 `data`、`DataBool` 用 `Bool`），右值在构造期就存成 `Data`/`Decimal`；`Subset.right` 同时消除 `HashSet<String>` 的字符串驻留
- **预期**：每条数据少 1 次 `Decimal.toString` + 1 次 `String` 分配 + 1 次哈希；集合规模为 k 时右值侧常驻内存从「k 个字符串」变为「k 个 `Decimal`」
- **代价**：`Subset<T>` 的泛型从 `T <: ToString & DataFields<T>` 改为携带 `Data`；需同步 `AnyOfFilter`/`NoOneOfFilter`（其他部分）
- **验证**：`$[?(@.age subsetof [25,30,35])]` 跑 1e6 条，`getAllocatedHeapSize()` 前后对照 + `cjprof heap`
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #1 `SubSetOfFilter` 对同一路径求值两次

- **现状**：`check` 先 `left.get(data).next()` 算 `size`（`SubSetOfFilter.cj:26-35`），`subset(data)` 内部再 `left.get(data).next()` 一次（`Subset.cj:29-32`）；左路径含 `..` 或过滤器时，单次 `check` 的成本 ≈ 2 × 路径成本
- **方案**：合并为一次求值，同时返回「左集合规模」与「命中数」（见 #10 的建议签名）
- **预期**：`subsetof`/`anyof`/`nooneof` 的 filter 段耗时约减半（仅路径部分；元素遍历不变）
- **代价**：改动 `Subset` 的三个子类调用点（含其他部分的两个）
- **验证**：`$[?(@..tags subsetof ['a','b'])]`，1e5 条嵌套文档，`cjpm bench -O2` 前后对照（中位数 + 离散度）
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #2 `ValueFilterResult` 的三段同构分支可合并为一次遍历

- **现状**：`Iterable<Data>`、`Iterable<(String,Data)>`、标量三个分支各自写一遍「遍历 → `inner.check` → 比较」，比较体三份逐行相同（`ValueFilterResult.cj:34-62`）
- **方案**：先用 `FilterUtils` 把 `Data` 归一化成 `Iterator<Data>`（该 helper 已存在，`FilterUtils.cj:25-45`），只保留一份「找首个命中 → 比较」的实现
- **预期**：消除两份重复比较体；顺带补上 `Iterable<(Data,Data)>` 分支（与 `part5` #6 同源）
- **代价**：`FilterUtils` 的归一化多一层函数调用（可内联）；行为需与现有一致
- **验证**：`value(match(@.name,'A'))` 在 `DataList`/`DataDict`/`DataTuples` 三种容器上的等价性用例 + `cjpm bench -O2`
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `StructEqFilter.check` 的全量物化在宽选择器下是 filter 段的主要分配源 | `f_data/src/path/StructEqFilter.cj:76-79` | 单次 `check` 的分配字节数、GC 次数占比 | 10 万节点文档 + `@.* == [1,2,3]`，`cjprof heap` 对该帧采样 |
| 2 | `SubSetOfFilter` 的二次路径求值占 `subsetof` 判定耗时的比例接近 50% | `f_data/src/path/SubSetOfFilter.cj:26-36` | 路径段与遍历段的耗时拆分 | `$[?(@..tags subsetof ['a'])]` 分段计时（进入 `check` 前/后打点），1e5 条 |
| 3 | `Subset` 的 `toString()` 哈希在大集合右值（k ≥ 100）时占判定耗时显著 | `f_data/src/path/Subset.cj:34-44` | 字符串生成与哈希的 self time | `subsetof [100 个字符串]` 跑 1e6 次判定，`cjprof record` 看 `Decimal.toString`/`String.hashCode` 帧占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/path/StructEqFilter.cj` | .cj | ✅ | 见 #1（字符串元素抛格式异常）、#5（注释示例不成立）、#6（三参构造器无调用）、优化[堆内存]#1；`splitByComma`/`dataEquals` 与 `ObjectEqFilter` 重复已在 `part6` #13 计数 |
| 2 | `f_data/src/path/SubPathNode.cj` | .cj | ✅ | 3 行 `match` + `OptionIterator`，被 `DataPath.cj:105/957/980`、`MultiSubPathNode.cj:21` 使用，无问题 |
| 3 | `f_data/src/path/SubSetOfFilter.cj` | .cj | ✅ | 见 #3（`HashSet<String>` 口径）、#10（二次求值） |
| 4 | `f_data/src/path/Subset.cj` | .cj | ✅ | 见 #3（null 丢失 + 文本成员判定）、#10（与子类重复分派）；`left` 为 `protected` 但被子类使用，非死代码 |
| 5 | `f_data/src/path/TestObj.cj` | .cj | ✅ | 见 #9（测试替身位于生产目录）；接口静态方法为占位实现，按接口实现豁免 |
| 6 | `f_data/src/path/ValueCmpFilter.cj` | .cj | ✅ | 见 #4（`toString` 比较）；`!=` 丢失问题见 `part5` #1（不重复计） |
| 7 | `f_data/src/path/ValueFilterResult.cj` | .cj | ✅ | 见 #2（文档用法恒 false）、优化[CPU]#2；缺 `(Data,Data)` 分支见 `part5` #6 |
| 8 | `f_data/src/path/ValuePathNode.cj` | .cj | ✅ | 单例恒等节点，`instance` 被 `DataPath.cj:949` 使用，无问题 |
| 9 | `f_data/src/path/basic_test.cj` | .cj | ✅ | 见 #8（未使用 helper）、#11（三条同构负索引用例）；其余 22 条用例断言值本身，覆盖充分 |
| 10 | `f_data/src/path/compile_error_test.cj` | .cj | ✅ | 3 条非法路径拒绝用例，`catch (_: DataException)` 与契约一致，无问题 |
| 11 | `f_data/src/path/complex_fn_test.cj` | .cj | ✅ | 见 #7（未使用 import）；4 条嵌套函数用例断言条数，`count(match())`/`count(search())` 形态可用 |
| 12 | `f_data/src/path/filter_test.cj` | .cj | ✅ | 见 #7；数组字面量用例只覆盖整数（`:401-427`），是 #1 的覆盖缺口；`value()` 用例实际走 `ValueCmpFilter`（`:384`） |
| 13 | `f_data/src/path/integration_test.cj` | .cj | ✅ | 见 #7、#11（两条用例完全相同） |
| 14 | `f_data/src/path/object_eq_test.cj` | .cj | ✅ | 见 #7；对象字面量比较的正确性归 `part6` #3，本部分不重复 |
| 15 | `f_data/src/path/p1_gaps_test.cj` | .cj | ✅ | 见 #7、#12（注释与实现不符、"无深度上限"自述） |
| 16 | `f_data/src/path/recursive_test.cj` | .cj | ✅ | `$..` 拒绝、`$..*`、`min/max/length/count/value/avg` 路径函数各 1 条；只断言条数（值断言缺失见 `part6` #1） |
| 17 | `f_data/src/path/rfc9535_slice_test.cj` | .cj | ✅ | 覆盖 2026-10-15 修复的切片归一化与 `containsNull` 词法化，共 7 条断言，无问题 |
| 18 | `f_data/src/test/DataAssist_test.cj` | .cj | ✅ | 覆盖宏生成父接口去重、`Comparable`/`Equatable` 冗余、local 构造与 `localEq`；临时类均为测试内声明，无问题 |
| 19 | `f_data/src/test/JsonSchema_test.cj` | .cj | ✅ | `format` 不再丢失、`minLength` 从 `dataFields` 兜底；`mutableFields()` 手写桥接的耦合已在注释中标记（`REVIEW §2`），无新增问题 |
| 20 | `f_data/src/test/data_test.cj` | .cj | ✅ | `fields`/`props` 往返、不可比字段的引用相等语义、`tryParse` 契约、`toString` 幂等，4 条均有值断言，无问题 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3（#1 格式异常逃逸、#2 文档用法恒 false、#3 null/类型口径分裂）；可读性 2（#5 注释示例、#12 注释与实现不符）。设计：8 个生产类仍是「构造期只读、`check` 无副作用」的一致模式，未发现职责错位；`Subset` 抽象被三个过滤器复用属合理抽取，只是右值表示选错（#3）。语言特性：`ValueFilterResult` 用 `case _ => !isEq` 兜底、`StructEqFilter` 依赖「token 带引号」的错误前提，都是值/类型语义误用；`TestObj` 的 `struct`/`class` 混用（`DataReal`/`DataString` 是 struct）无隐患。安全性：本部分只处理内存 `Data` 与路径串，无 SQL/命令拼接、无凭据、无 IO，未见注入面 |
| §1 死代码 | 3 | 逐个符号全仓搜引用：#6（`StructEqFilter` 三参构造器零调用）、#7（5 个文件未使用的 `DataException` import）、#8（`basic_test.assertDataStr` 零调用）。其余核对：`ValuePathNode.instance`（`DataPath.cj:949`）、`SubPathNode`（`DataPath.cj:105/957/980`、`MultiSubPathNode.cj:21`）、`Subset.left`（`SubSetOfFilter.cj:26`，`protected` 但被使用）、`Subset.subset`（三个子类）、`StructEqFilter.parseRaw/splitByComma/dataEquals` 均有调用；`public func check`/`get`/`toString`/`fromData`/`parse`/`tryParse`/`[]` 是接口实现，按硬原则豁免；`TestObj` 仅测试使用按 §1 记为可见性建议（#9），不计死代码；本部分无 `public open`/`public abstract` 类，故无 `protected` 豁免场景 |
| §2 重复逻辑 | 2 | 已对 20 个文件两两比对函数体摘要（输入→输出→副作用）：#10（`SubSetOfFilter.check` 与 `Subset.subset` 同语义分派两份 + 重复求值）、#11（测试用例/helper 重复，按 §2 误报边界只记轻微）。`StructEqFilter` 与 `ObjectEqFilter` 的 `splitByComma`/`dataEquals`、`parseValue` 三份实现已由 `part6` #13、`part5` #8 计数，本部分只作交叉引用不重复计；`ValueFilterResult` 三分支同构已在 #2 描述并单列优化[CPU]#2，未再计入发现数 |
| §3 空实现 | 0 | 逐函数核对：无 `catch {}`、无 `TODO`/`FIXME`、无 `UnsupportedException`。`TestObj.fromData/parse` 抛 `DataException`、`tryParse` 返回 `None` 是 `DataParsable` 契约允许的「不支持解析」形态（`data_test.cj:77-83` 明确记录该契约），且为测试替身，已在 #9 内描述，不另计；`ValueFilterResult` 的 `case _ => !isEq` 是 #2 的丢弃路径，同条计数 |
| §4 栈溢出 | 0 | 本部分无自递归函数：`StructEqFilter.parseRaw/splitByComma/dataEquals` 全是单层循环 + 非递归 `match`；`ValueFilterResult` 只在 `inner.check` 上调一层（深度 = 表达式嵌套深度，由 `DataPath` 编译期决定，属其他部分）。`p1_gaps_test.genNestedMatch` 是递归生成器但深度硬编码 ≤ 30（`:208`、`:220`），受限常量。解析器「无深度上限」的自述见 #12 的范围外提示 |
| §5 OOM | 0 | 无全局容器、无缓存、无 `readToEnd`/全量 `split`、无按报文长度预分配；`StructEqFilter`/`ValueCmpFilter`/`Subset` 的临时容器生命周期都在单次 `check` 内，规模与输入同阶且随调用结束释放（属放大分配，见优化[堆内存]#1/#2）；`TestObj.map` 仅在测试中构造，不跨请求存活 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof` / `cjpm bench` 数据，缺「函数 + 自耗时占比 + 调用路径 + 输入规模」四要素，热点结论不成立；3 条疑似热点已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变状态 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/队列消费 |
| §6.4 低效算法 | 2 | #10 的「同一路径求值两次」（已并入 #10 与优化[CPU]#1）、`StructEqFilter.check` 的「全量物化后才比较」（优化[堆内存]#1）。缺耗时占比，未升级为发现 |
| §7 降堆内存方案 | 2 | [堆内存]#1（`StructEqFilter.check` 物化）、#2（`Subset`/`ValueCmpFilter` 的 `toString` 临时串 + 右值集合表示）；其余路径节点是惰性迭代器，无中间副本可省 |
| §8 降 CPU 方案 | 2 | [CPU]#1（`subsetof` 二次求值）、#2（`ValueFilterResult` 三分支合并）；两者都附了等价性验证方式 |
| §9 local mode 可行性 | 0 | 本部分唯一与 local mode 相关的是 `DataAssist_test.cj:86-125`（验证 `@DataAssist` 生成的 `localEq`/`localCompare` 与 local 构造），属已完成的接入而非待改造点；生产侧 `check` 内的临时 `ArrayList`/`String` 都是单次调用生命周期，收益只能用峰值内存证明，当前无基线，按规则不列方案 |
| §11 现有代码的 BUG（存量） | 3 | 逐函数核对了 8 个生产类与 12 个测试文件的边界/空值/错误路径：#1（格式异常逃逸）、#2（契约不成立）、#3（null 丢失 + 类型串味）。已核对无问题的边界：`SubPathNode` 对非 `NamedData` 返回空迭代器、`Subset.subset` 缺失路径返回 `0`（`SubSetOfFilter` 因此判 `false`，与「空集是子集」一致）、`ValueCmpFilter` 的多节点判定（`itr.next().isSome()` → `false`，符合 RFC §2.4.8）、`StructEqFilter.check` 的 `isEq=false` 取反、`TestObj.toString` 的 `first` 标志、`DataAssist_test` 的 local/普通实例互等断言 |
| §12 并发安全与锁粒度 | 0 | 本部分无跨线程状态：`StructEqFilter`/`ValueCmpFilter`/`ValueFilterResult`/`SubSetOfFilter` 的字段全部在构造期赋值且 `check` 只读（`left`/`right` 是私有只读引用，运行期无 `add`/`clear`），`DataPath` 共享给多线程时只发生读；`ValuePathNode.instance`/`SubPathNode` 无状态；`TestObj.map` 可变但只被单线程测试使用（线程封闭）。故判线程安全；锁粒度不适用 |
| §14 功能完备性与 README 覆盖 | 1 | #2（`README.md:511` 承诺 `value(search(...)) == "X"`，实际语义恒 `false`；`README.md:722` / `RFC9535_COVERAGE.md:104` 把它的覆盖归给 `testFilterValueEq`，而该用例走的是 `ValueCmpFilter`，`ValueFilterResult` 全仓无测试）。README 对照：本部分涉及的 `subsetof/nooneof/anyof`（`:585-587`）、`value()`（`:455`、`:508-511`）、`@.* == [...]` 段落存在，无「public 能力未文档化」——本部分 8 个生产类全部是 `internal`，不构成对外 API；`.md` 文件 0 个，§13 的逐文件一致性由模块其它部分覆盖 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无缺读；`.md` 为 0 个，§13 不适用（模块 README / `doc/**` 只在 #2/#5 中作为承诺源引用） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量缺陷 12 条（严重 1、一般 2、轻微 9），是否纳入修复待用户决定。

## 总评

本部分是 `src/path/` 的「结构相等 / 集合关系 / `value()` 取值」一族，加 12 个测试文件。代码量不大，但**「右侧字面量被降级成文本再解析」这一条主线**在三个类里各错了一次，且错误方向一致：把 `cangjieLex` 已经去引号的 token 值当成带引号的字面量，或反过来用 `toString()` 当比较口径。

- 阻塞项是 #1：数组字面量只要含字符串或嵌套数组就抛 `NumberFormatException`，这不是「结果不对」而是「异常类型不对 + 请求级崩溃」，且 `StructEqFilter.parseRaw` 里那段引号剥离逻辑在当前调用链上根本不可达，说明作者对输入形态的判断是错的。修法明确（按 token 构造 `Data`），但必须补字符串/布尔/嵌套/含逗号四组用例，否则还会复发。
- #2 是「契约写了但没实现」：`value(innerFilter)` 的文档示例恒 `false`，且 `RFC9535_COVERAGE.md` 把它的覆盖错记到 `testFilterValueEq` 名下，等于连「没有测试」这件事都被文档掩盖了。建议与 `part5` 的 `FnDeferred*` 同批修，否则两处会各自修出不同语义。
- #3 是口径分裂：`subsetof`/`anyof`/`nooneof` 把右值铸成 `HashSet<String>`，`null` 直接消失、`30.0` 与 `30` 互不相等、`"30"` 又能命中 `[30]`；而 `in`/`nin` 有 `hasNull` + `Decimal` 比较。这一族应该共用一套「右值类型化表示」，`Subset` 是天然的落点。

测试侧的问题集中且廉价：两个完全相同的集成用例、三条只差字面量的负索引用例、八份 `collect()` 拷贝、一个从未被调用的 helper、五处未使用的 import——都不影响行为，删改风险极低，建议顺手清理。`TestObj` 作为测试替身长期住在 `src/path/` 是唯一的组织性问题，移到 `*_test.cj` 即可，不必改可见性。

性能与内存方面本部分没有热点证据：四条方案（`StructEqFilter` 物化、`Subset` 文本比较、`subsetof` 二次求值、`ValueFilterResult` 三分支）都只给出机制与验证方式，全部标 `无基线（待验证）`，等下一轮补齐 `cjprof` / `cjpm bench -O2` 数据再决定是否立项。并发面本部分干净——所有过滤器都是构造期赋值、运行期只读，`check` 只用局部变量，看不到共享可变状态。
