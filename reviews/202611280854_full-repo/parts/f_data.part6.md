# f_data 模块审查报告

> **模块第 6/8 部分**（分报告）。本部分只覆盖 `files/f_data.part6.txt` 列出的 20 个文件（全部为 `.cj`，`src/path/MatchFilter.cj` → `src/path/SolidDataPath.cj`）。
> 模块其余 107 个 `.cj` 与 15 个 `.md` 由同模块其他部分产出；本部分编号独立，合并时以主 Agent 为准。
> README / `doc/**` 只作为取证判据被引用，不计入本部分「文件覆盖」。
> 同源问题交叉引用：`parts/f_data.part5.md` #8（`dataEquals` 不识别 `DataDateTime`/`DataDuration`，本部分 `ObjectEqFilter.dataEquals` 同源）、#2（结构比较递归无深度上限，本部分 #6 同一根因）；`StructEqFilter.cj`、`SubPathNode.cj` 属第 7 部分，本部分仅作重复来源引用。

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 20 个 `.cj`，0 个 `.md`；模块共 127 `.cj` + 15 `.md`）
- **基线**：工作区快照（`git blame` 显示本部分各行均落在 `4be871f2f`（换行符统一）及其之前，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 6/8 部分）

> 取证说明：`#1`、`#2`、`#3`、`#11` 的语言/标准库语义用本机 SDK（`cangjie-win-bin/sdk/1.3.0`）在 `/tmp` 下编译**独立最小片段**验证（未构建被审项目、未改动仓库），片段与结论见各条「证据」。

## 发现

### [严重][存量] #1 `max()` / `min()` 的比较分支恒不匹配：两个函数永远返回数组首元素

- **位置**：`f_data/src/path/MaxPathNode.cj:30-36`（`case (x: DataDateTime, y: DataDateTime) where x > y => x` … `case _ => continue`）、`f_data/src/path/MinPathNode.cj:30-36`（同一结构，比较符换成 `<`）
- **来源**：存量（`git blame -L 30,36`：全部来自 `4be871f2f`；该文件上一次功能改动是 `f3248fa9f "fix: max function case _ => return -> continue"`，修的是 `_` 分支，比较分支没被触碰）
- **判据**：review-checklist §1「恒真恒假分支」、§11「逻辑错误」、§14「README 承诺的能力未实现」
- **证据**：静态确定 —— `r` 的静态类型是 `Option<Data>`（`:24` `var r = None<Data>`），而 `match ((v, r))` 的元组第二个元素是 `Option<Data>`；`y: DataDateTime` 是**类型模式**，只能匹配运行时类型为 `DataDateTime` 子类型的值，`Option<Data>.Some(...)` 永远不是。用 SDK 1.3.0 编译同形片段，编译器直接给出 `warning: unreachable pattern`，运行输出 `10`（首元素）而不是 `20`（最大值）。现有测试只断言结果条数：`recursive_test.cj:103-123`（`@Assert(1, results.size)`），没有任何一条断言最大值/最小值，因此整段失配被测试掩盖
- **描述**：`$.max()` 对 `[10, 5, 20]` 返回 `10`，`$.min()` 同样返回 `10`；对字符串数组、`DataDateTime` 数组也一样。README 第 450-451 行明确承诺「数组最小值 / 数组最大值」，`doc/RFC9535_COVERAGE.md:120` 也把 `testFunctionMin/Max` 当作覆盖证据，但实际功能等于「取首元素」。更糟的是两个函数都只有「类型相同才比较」的语义，即使修好匹配也无法处理 `DataList` 里混合 `DataString` 与 `DataReal` 的情况（当前 `case _ => continue` 静默跳过）
- **建议**：先把 `r` 解成 `Data` 再比较——`if (let Some(y) <- r)` 或 `match ((v, r)) { case (x: DataReal, Some(y: DataReal)) => … }`；比较统一走 `f_data/src/base/data_cmp.cj` 的 `Comparable` 口径，避免四份 `x > y` 各写一遍。补 `min()/max()` 的**值**断言（数值、字符串、datetime 各一组）

### [严重][存量] #2 `match()` 的「全串匹配」用 `Regex.matches` 实现，实际是子串匹配，与 `search()` 同义

- **位置**：`f_data/src/path/MatchFilter.cj:41`（`case x: DataString => regex.matches(x.data)`）；对照 `SearchFilter.cj:41`（`regex.find(x.data, group: true).isSome()`）
- **来源**：存量（`git blame -L 40,44`：`4be871f2f`）
- **判据**：review-checklist §11「契约与实现不符」、§14（承诺源 `README.md:505`「全串正则匹配」+ 类注释 `MatchFilter.cj:19-21`「Returns true if the entirety of the input matches」）
- **证据**：静态确定 —— 仓颉 `Regex.matches` 的语义是「判断入参 input 与正则表达式**是否存在**匹配」（`cangjie_runtime/stdlib/doc/libs/std/regex/regex_package_api/regex_package_classes.md:1144-1161`，其自带示例用非全串锚定的 pattern 匹配 `"2024-10-24&2025-01-01"` 并返回 `true`）；SDK 1.3.0 实测 `Regex("lic").matches("Alice") == true`、`Regex("^lic$").matches("Alice") == false`
- **描述**：`$[?(match(@.name, 'lic'))]` 对 `"Alice"` 返回 `true`，按契约应为 `false`；`match` 与 `search` 在本模块里完全等价（区别只在 `matches` 与 `find` 两个同样是子串语义的 API）。RFC 9535 §2.4.6 的 `match()` 是全串语义，`doc/RFC9535_COVERAGE.md` 也按 RFC 自称已覆盖。测试用 `match(@.name, 'Alice')`（`filter_test.cj:336`）这种**恰好全串等于输入**的 pattern，无法区分两种语义
- **建议**：取 `find` 的 `MatchData` 并校验匹配区间覆盖整个字符串（`md.matchString().size == x.data.size`，或比较起始/结束位置），或统一 `Regex("^(?:" + pattern + ")$")`（需处理 pattern 内已有锚点与 `(?i)` 前缀）；补一条「短 pattern 命中长字符串」的反向用例

### [严重][存量] #3 对象字面量比较丢失字面量类型：token 拼成无引号文本再手写解析，`"123"`/`"true"`/含逗号的字符串全部判错

- **位置**：`f_data/src/path/ObjectEqFilter.cj:35-55`（`parseRaw`，`:41` `splitByComma(inner)`、`:46-47` 取 key/value）、`:71-105`（`parseValue`：`:73` `null`、`:76-77` `true/false`、`:97-102` 数值分支、`:104` 兜底字符串）、`:108-119`（`parseArrayLiteral`）、`:122-134`（`splitByComma`）
- **来源**：存量（`git blame -L 95,104`：`4be871f2f`）
- **判据**：review-checklist §11「契约与实现不符」「语义与命名不符」、§10 正确性；承诺源 `README.md:595`（`@ == {"name": "Alice", "age": 30}`）、`object_eq_test.cj:35-118`
- **证据**：静态确定 —— 上游 `DataPath.cj:471` 用 `concatTokenValues(sub[e + 1 .. objEnd + 1])` 把**整段 token 的 `value` 直接拼成文本**再交给 `ObjectEqFilter`，而 `std.ast` 的 `STRING_LITERAL.value` 不含引号（SDK 1.3.0 实测 `cangjieLex("{\"name\": \"123\"}")` 输出 `STRING_LITERAL |name|`、`STRING_LITERAL |123|`）。于是 `{"code": "123"}` 到达 `parseRaw` 时已经是 `{code:123}`，`parseValue` 按首字符判定为数值 → `DataReal(123)`；`"true"` → `DataBool.TRUE`；`"null"` → `DataNone`；`{"msg": "a,b"}` 在 `splitByComma` 的 `depth == 0` 处被切开，`a` 成为值、`b` 因无冒号被 `:43`/`:45` 静默丢弃
- **描述**：`@ == {"code": "123"}`、`@ == {"flag": "true"}`、`@ == {"msg": "a,b"}`、`@ == {"v": "[1,2]"}` 这些合法（且已在 README 中示例化）的写法恒为 `false`，且没有任何异常或日志——查询静默少命中。`!=` 方向则恒为 `true`（`:142-144`）。同类根因还导致畸形字面量被吞掉：`@ == {name}` 解析成空 map，与真实的 `{}` 比较会**判等**。`ObjectEqFilter` 的 `parseValue` 保留的「去 key 引号」分支（`:49-51`）在当前输入下恒不成立，说明作者误以为 token 值带引号
- **建议**：不要在字符串上重建字面量。`DataPath` 手里已有 token 流（`LCURL`/`STRING_LITERAL`/`COLON`/…），直接按 token 类型构造 `DataDict`：`STRING_LITERAL → DataString(value)`、`INTEGER_LITERAL → DataReal(Int64.parse)`、`IDENTIFIER("null") → DataNone`，并把 `ObjectEqFilter` 的入参改成结构化数据；退一步也必须给每个 value 记住「原始 token kind」，不能只看首字符。补 `"123"`、`"true"`、含逗号/括号字符串三组用例

### [一般][存量] #4 `NullFilter`：路径无值时 `!= null` 也返回 `false`，与自身注释和 RFC 9535 相反

- **位置**：`f_data/src/path/NullFilter.cj:29-36`（`:29-32` 取不到节点直接 `return false`，`:34-35` 才按 `isNull` 分流）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；RFC 9535 §2.3.5.2.2 + Table 11（`$.absent != 'g'` → `true`，因 `==` 在任一侧为 `Nothing` 时为 `false`，`!=` 取其反）
- **证据**：静态确定 —— 类注释 `:20-21` 写「`?(@.name != null)` returns true if the field value is NOT DataNone」，而实现把「字段不存在」与「字段为 null」合并成同一个 `false`；`!=` 与 `==` 只在 `:34-35` 才分叉
- **描述**：`$[?(@.name != null)]` 会漏掉「没有 `name` 字段」的对象。现有测试 `filter_test.cj:312-325` 的三条数据都带 `name`（其中一条显式置 `DataNone`），因此覆盖不到缺失字段的形态。相同语义下 `NotEqFilter`/`NinFilter`/`NotFilter` 走的是「取反」路径（缺失即 `true`），本文件是唯一的例外，口径不一致
- **建议**：缺失分支改成 `return !isNull`（`== null` → `false`，`!= null` → `true`），并把注释补一句「字段不存在时 `== null` 为 false、`!= null` 为 true」；补「对象缺该字段」的用例

### [一般][存量] #5 `RecursiveDescentIterator` 无环检测/深度上限：自引用 `Data` 图上 `$..` 永不结束

- **位置**：`f_data/src/path/RecursiveDescentIterator.cj:26-28`（`append` 无条件 `addFirst(AnySubPathNode.instance.get(data))`）、`:29-47`（`while (true)` 只有「容器取空」一条出口）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「自引用结构」、§11 正确性
- **证据**：静态确定 —— 遍历状态里只有 `LinkedList<Iterator<Data>>` 与当前 `itr`，没有 `visited` 集合也没有深度计数；`DataList` 的 `add<T>(item) where T <: ToData`（`DataList.cj:28`）而 `DataList <: Data <: FromToData <: ToData`（`Data.cj:18`、`DataFields.cj:31`），因此 `list.add(list)` 可以通过类型检查并构造出自引用图，此后 `$..*`（`RecursiveDescentPathNode`）每次迭代都重新把同一个容器压栈，永不返回 `None`
- **描述**：触发条件是**调用方代码**构造了环（JSON 解析产物不会成环），一旦成环，`$..anything` 的 `for` 循环挂死该线程、CPU 打满，不会有异常也不会有日志。库对「输入的 `Data` 是树」这一前提没有任何校验或文档声明
- **建议**：给 `RecursiveDescentIterator` 加一个「当前路径上的容器身份集合」做环检测（`HashSet<Int64>` 存 `hashCode`/引用地址，出栈时移除），或加 `maxDepth` 上限并在超限时抛 `DataException`；同时在 `DataPath` 文档里写明「`Data` 必须是无环树」

### [一般][存量] #6 `ObjectEqFilter` 的两条递归都无深度上限：深嵌套字面量/深嵌套数据都会打爆栈

- **位置**：`f_data/src/path/ObjectEqFilter.cj:71-119`（`parseValue → parseRaw → parseValue` / `parseValue → parseArrayLiteral → parseValue`）、`:163-203`（`dataEquals → dictEq|listEq → dataEquals`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「无界递归 / 深度由输入决定 / 无深度计数」、§11
- **证据**：静态确定 —— 两个递归环都没有 `depth` 参数或上限常量；解析侧的深度 = 路径字面量的嵌套层数（来自配置/规则字符串），比较侧的深度 = 被查数据的嵌套层数（来自外部报文）。崩溃所需的具体层数未实测（属 §4 允许的「按层估算」范围，报告不写具体字节数）
- **描述**：`$[?(@ == {"a":{"a":{"a": … }}})]` 或把同样形状的字面量换成深层嵌套的入参数据，都会在 `check`/构造期栈溢出；栈溢出不是 `Exception`，上层 `try` 接不住，进程直接崩。与 `parts/f_data.part5.md` #2（`EqPathFilter` 同形递归）是同一根因，合并时可归一
- **建议**：字面量解析改成显式栈（`ArrayList<(Tokens, 目标容器)>`）；`dataEquals` 改成用 `(Data, Data)` 待比较队列迭代；两侧都补一条 2000 层的「不崩溃」用例

### [一般][存量] #7 `SolidDataPath` 在 `ConcurrentHashMap` 的回调里递归调用 `DataPath.solid`：同一张表嵌套 `entryView`，可能自锁

- **位置**：`f_data/src/path/SolidDataPath.cj:26-30`（`SOLID.computeIfAbsent(path){ SolidDataPath().doCompile(path, true) }`）；递归落点 `f_data/src/path/DataFilter.cj:32-38`（`compilePath` 在 `solid == "true"` 时调 `DataPath.solid(path)`）→ `DataPath.cj:70-72`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「锁内调用外部回调 / 自锁等待」、§6.2「锁内做解析」；std 文档 `collection_concurrent_class.md:1225-1247`（`entryView` 的 `fn` 执行期间处于原子操作内，并明确禁止在 `fn` 内并发再调 `entryView`/`remove`/`replace`）
- **证据**：待确认 —— 确定性事实是「嵌套调用成立」：编译 `$.a[?(@.b == 1)]` 且 `solid == "true"` 时，`doCompile` 会在 `computeIfAbsent` 的 `fn` 里执行 `quote(EqFilter<String>("@.b", "1", "true"))`（`DataPath.cj:414`），该构造器立刻 `compilePath("@.b", "true")` → `SOLID.computeIfAbsent("@.b")`，即同一线程在外层 `entryView` 未返回时再次进入同一张表。缺的信息是 std `ConcurrentHashMap.entryView` 的锁粒度与可重入性（是整表锁还是分段锁；`Mutex` 非重入）
- **描述**：若内层 key 与外层 key 落在同一把锁/同一段上，这里会单线程自锁——表现为「第一次编译带过滤器的 solid 路径就挂死」，无异常、无日志。现有用例只覆盖无过滤器的 `DataPath.solid("$.name")`（`basic_test.cj:286`），`fprobe` 的 `DataPath.solid(rule.path)`（`fprobe/src/alarm/AlarmEngine.cj:193`）一旦配置里带 `?()` 就会踩到。即便不死锁，把 lex/parse 放在表锁内也是持锁做 O(路径长度) 的工作
- **建议**：先按「单线程编译 `DataPath.solid("$.a[?(@.b == 1)]")` 是否返回」验证；无论结论如何，都应改成「先 `SOLID.get`，未命中时在锁外编译好再 `putIfAbsent`（或 `computeIfAbsent` 只做纯插入）」，把嵌套调用移出回调

### [轻微][存量] #8 两个未使用字段：`SolidDataPath.lock`、`RecursiveDescentIterator.rootData`

- **位置**：`f_data/src/path/SolidDataPath.cj:24`（`private static let lock = Mutex()`，全文件无引用，`std.sync.Mutex` 仅为此 import）、`f_data/src/path/RecursiveDescentIterator.cj:21,23`（`rootData` 只在 `init` 里赋值，`next` 从不读）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用 / 死字段」
- **证据**：静态确定 —— 全仓 `grep -rn "rootData" f_data f_*` 只命中定义与赋值两行；`lock` 在 `SolidDataPath.cj` 内无第二处出现（互斥实际由 `ConcurrentHashMap.computeIfAbsent` 提供）
- **描述**：`lock` 会让人误以为同步靠它，`rootData` 则是旧实现的残留；两者都增加阅读成本，删除不影响行为。`lock` 删除后 `import std.sync.Mutex` 也应一并去掉
- **建议**：删除两个字段与随之无用的 import

### [轻微][存量] #9 `RangePathNode` 三个构造器无调用者，`step` 的实际取值也只有一个

- **位置**：`f_data/src/path/RangePathNode.cj:23-25`（`init(start:end:)`）、`:26-28`（`init(end:)`）、`:29-31`（`init()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者」（internal 类 + 包级构造，按「全项目无引用」判）
- **证据**：静态确定 —— 全仓 `grep "RangePathNode"` 只有 `DataPath.cj:169`（返回类型）与 `:201`（`RangePathNode(start, end, step)`，即三参主构造）；三个便捷构造零引用。三者都是 `step = 1` 的包装，而唯一调用点显式传 `step`
- **描述**：死构造会诱导后来者以为存在「一参/两参切片」的编译入口；同时它们把 `step` 默认值写死在三个地方，与 `DataPath.compileSliceInSquares` 的 `step = 1i64`（`DataPath.cj:173`）重复
- **建议**：删除三个未使用构造（若确实想保留 API 形状，则下沉为 `private` 并加注释说明用途）

### [轻微][存量] #10 `RecursiveDescentIterator.next()` 末尾的 `None<Data>` 不可达

- **位置**：`f_data/src/path/RecursiveDescentIterator.cj:46`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「不可达语句」
- **证据**：静态确定 —— `:30` `while (true)` 内三条分支全部 `return`（`:39` 返回元素、`:43` 返回 `None`），循环没有 `break`，`:46` 永远执行不到
- **描述**：纯冗余，但会让读者以为存在「循环正常结束」的路径
- **建议**：删除该行；若编译器要求显式返回，把 `while (true)` 改成带条件的循环

### [轻微][存量] #11 `SizeFilter` 的反射兜底是恒假分支：`qualifiedName` 前缀写错，且前置 `Collection` 分支已覆盖 `DataObject`

- **位置**：`f_data/src/path/SizeFilter.cj:40-50`（`:43` `info.qualifiedName.startsWith('f_data.DataObject')`）；同一写法也出现在 `AnySubPathNode.cj:26-33`（属第 7 部分，范围外提示）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「恒真恒假分支」、§6.4（每次 `check` 走反射）
- **证据**：静态确定 —— ① `DataObject<T>` 声明为 `Collection<(String, Data)>`（`base/DataObject.cj:67`），`:30-33` 的三个 `Collection` 分支必然先命中，`:40` 的 `case _` 到不了；② 即便能到，`TypeInfo.qualifiedName` 的形式是「包名.类型名」，SDK 1.3.0 实测 `TypeInfo.of<Box<Int64>>().qualifiedName == "default.Box<Int64>"`，本包是 `fountain::f_data.base`，不可能以 `f_data.DataObject` 开头，`startsWith` 恒 `false`
- **描述**：整段反射（`TypeInfo.of` + `TypeMemberInfos.instanceFunction` + `apply`）是死代码，却让 `SizeFilter` 背上 `std.reflect` 依赖，也让人误判「`size` 支持任意对象类型」。实际 `size` 对非 `Collection`/非 `DataString` 恒为 `-1`，与 `LengthCmpFilter.computeLen`（`:42` 直接 `-1`）口径一致——说明反射分支从来不是必需
- **建议**：删除 `:40-50` 的反射兜底，`case _ => -1`；去掉 `import std.reflect.*`。若确实要给 `SimpleDataObject` 兜底，判据应用 `case x: SimpleDataObject =>`（接口匹配）而不是字符串前缀

### [轻微][存量] #12 `MatchFilter` 与 `SearchFilter` 的正则解析辅助函数逐行相同

- **位置**：`f_data/src/path/MatchFilter.cj:32-34` 与 `f_data/src/path/SearchFilter.cj:32-34`（均为 `private static func parseRegex(regex: String): Regex { regex.regex() }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定 —— 两个函数体完全一致（输入 `String` → 输出 `Regex` → 副作用：走 `f_regex` 的 `String.regex()` 缓存）；差异点为零
- **描述**：两份相同实现意味着后续要加 flags、要改 `solid!` 参数（`f_regex/src/RegexFromString.cj:32` 支持 `solid!`，此处都没传）时必须改两处，容易漂移。同包内还有第三套口径：`RegexFilter.parseRegex`（`:28-39`）额外要求 `/…/` 包装
- **建议**：抽到 `FilterUtils.cj` 一个 `compilePlainRegex(pattern: String): Regex`（顺带显式传 `solid! = true` 以命中永久缓存），两处调用

### [轻微][存量] #13 `ObjectEqFilter` 与 `StructEqFilter` 各有一份 `splitByComma` / `dataEquals`

- **位置**：`f_data/src/path/ObjectEqFilter.cj:122-134`（`splitByComma`）与 `StructEqFilter.cj:61-73`（逐行相同）；`ObjectEqFilter.cj:163-173`（`dataEquals`）与 `StructEqFilter.cj:89-97`（同名同签名，覆盖范围不同）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「跨层复制 / 近似重复（一块少了分支）」
- **证据**：静态确定 —— `splitByComma` 两处字符级完全一致；`dataEquals` 两处前四个 `case` 一致，`ObjectEqFilter` 多了 `DataDict`/`DataList` 递归，`StructEqFilter` 缺（因此 `@.* == [{"a":1}]` 这类嵌套数组元素比较恒 `false`）
- **描述**：同一包内两套「字面量文本 → `Data`」的手写解析器，已经漂移出「嵌套容器支持不一致」的行为差异；再叠加 #3 的丢类型问题，两处都要各修一遍
- **建议**：把 `dataEquals`（含容器递归）抽成 `FilterUtils` 的 `dataEquals(a: Data, b: Data)` 供两者共用；解析侧按 #3 的建议整体改为按 token 构造，`splitByComma` 随之消失

### [轻微][存量] #14 `SizeFilter` 与 `LengthCmpFilter` 各写一遍「容器/字符串尺寸」

- **位置**：`f_data/src/path/SizeFilter.cj:30-51` 与 `f_data/src/path/LengthCmpFilter.cj:33-44`（`computeLen`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定 —— 两者对 `Collection<Data>`/`Collection<(String,Data)>`/`Collection<(Data,Data)>` 都取 `size`，对 `DataString` 都逐 `runes()` 计数；差异只在 `SizeFilter` 多一段恒假的反射兜底（#11）与 `==` 比较
- **描述**：`size N` 与 `length(...)` 是两种语法、同一度量；重复实现导致 #11 的反射分支只存在于其中一份，`LengthCmpFilter` 明确 `len < 0 → false`（`:51`）而 `SizeFilter` 让 `-1` 直接进 `==` 比较，边界处理已经不同
- **建议**：抽 `dataSize(data: Data): Int64`（返回 `-1` 表示不支持）到 `FilterUtils`，两处共用；顺带让 `SizeFilter` 也显式处理 `-1`

### [轻微][存量] #15 `RegexFilter.parseRegex` 缺最小长度校验，`/` 与 `/i` 会抛非 `DataException` 的反向切片异常

- **位置**：`f_data/src/path/RegexFilter.cj:28-39`（`:32-33` `regex[1..regex.size - 2]`、`:34-35` `regex[1..regex.size - 1]`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界差一 / 错误处理缺失」
- **证据**：静态确定 —— 入参 `"/"`（`size == 1`）走 `endsWith('/')` 分支得到 `1..0`，`"/i"`（`size == 2`）走 `endsWith("/i")` 得到 `1..0`，均为起点大于终点的切片；同函数没有 `size >= 3` 守卫，也没有 `DataException` 包装。可达性说明：`DataPath.parseFilterTokens` 的 `=~` 分支（`DataPath.cj:548-564`）会先校验闭合 `/`，正常路径挡得住，因此本条属「防御缺失」而非线上可触发
- **描述**：一旦有人绕过 `DataPath` 直接构造 `RegexFilter`（或后续放宽解析器），非法正则抛的是运行时切片异常而不是 `DataException`，上层按 `DataException` 写的降级接不住
- **建议**：入口加 `if (regex.size < 3) throw DataException(...)`，把 `/`、`/i`、`//` 三种形态显式拒绝并给出可读消息

### [轻微][存量] #16 `SolidDataPath.SOLID` 无容量上限，与 `CacheDataPath` 的有界缓存形成两套口径

- **位置**：`f_data/src/path/SolidDataPath.cj:23`（`private static let SOLID = ConcurrentHashMap<String, DataPath>()`）；对照 `CacheDataPath.cj:21`（`HeapCache<DataPath>(maxLife: Duration.day, maxSize: 10000)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「缓存键无界 / 全局集合只增不减」、§11 契约
- **证据**：静态确定 —— 表只有 `computeIfAbsent` 写入、全仓无 `remove`/`clear`；key 是调用方给的路径字符串。README `:392-393` 把语义定为「永久缓存，适合进程中不变的固定路径」，因此「无淘汰」本身是设计，但代码层没有任何护栏
- **描述**：`DataPath.solid()` 被 `fprobe` 以运行期配置值调用（`fprobe/src/alarm/AlarmEngine.cj:193`、`collect/MetricProjection.cj:112`），若路径由参数拼接（例如按维度生成不同 `$.metrics.xxx`），条目数随基数增长、永不释放：每条目 ≈ 路径串 + `DataPath.nodes`（`ArrayList<DataPathNode>`）及其节点对象，1e6 条不同路径即数百 MB 量级常驻。是否真会增长取决于调用方是否传动态串，故只判轻微
- **建议**：二选一——① 在 `solid()` 增加容量上限（超过 N 条打警告并按 `CacheDataPath` 降级）；② 明确只在编译期/常量路径上使用，把 `fprobe` 侧改为 `DataPath.cache`。README 补一句「动态路径请用 `cache`」

## 优化可行性方案

> 下面都不是缺陷。没有改前基线的一律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] #1 `ObjectEqFilter.check` 把整个 nodelist 物化后只用来判「是否恰好 1 个」

- **现状**：`ObjectEqFilter.cj:137-144` 每次 `check` 建 `ArrayList<Data>` 抽干 `left.get(data)`；元素数 = 左侧选择器命中数（对 `@.*`、`$..*` 可达子树节点数），生命周期仅一次 `check`
- **方案**：改流式——只取前两个结果：`next()` 取到第 1 个后，再 `next()` 一次判断是否还有第 2 个，超出即按「非单值」返回，不再收集
- **预期**：单次 `check` 的临时分配从 `O(n)` 降到 `O(1)`，GC 次数随之下降；具体幅度待测
- **代价**：无（`isEq` 的两条分支语义不变）
- **验证**：10 万节点文档上跑 `$[?(@.* == {...})]`，`cjprof heap` 对比分配量与 GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #2 `RangePathNode` 为切片物化全部索引，并为每个索引新建一个 `IndexPathNode`

- **现状**：`RangePathNode.cj:71-87` 的 `buildIndices` 把整个切片区间装进 `ArrayList<Int64>`（8B/元素），`:51-53` 再用 `map {idx => IndexPathNode(idx)}` 为每个索引新建节点对象；`$[*]` 或 `$[:]` 在大数组上等于「n×8B + n 个节点对象 + 3 层迭代器」，全部是纯中间态
- **方案**：改成一个按 `(start, end, step)` 游标推进的 `Iterator<Data>`（`next()` 时直接用 `IndexPathNode` 的等价逻辑取元素），去掉索引数组与 `flatMap` 包装；`step == 1` 时可直接对容器迭代器做一次顺序遍历
- **预期**：单次 `get` 的额外分配从 `O(n)` 降到 `O(1)`（输出本身仍需 n 个元素）；峰值内存与 GC 压力下降，幅度待测
- **代价**：`step < 0` 的逆序游标需额外状态；语义（顺序、越界行为）必须逐条对齐 `rfc9535_slice_test.cj`
- **验证**：10 万元素 `DataList` 上跑 `$[*]`、`$[::2]`、`$[::-1]`，`cjprof heap` 对比分配量，`getUsedHeapSize()` 对比峰值
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #1 切片对每个索引重新 `skip(idx)`：若 `ArrayList` 迭代器未特化 `skip`，整体退化到 `Θ(k·n)`

- **现状**：`RangePathNode.cj:51-53` 对每个索引调用 `IndexPathNode.get(data)`，后者在 `IndexPathNode.cj:31`（`Collection` 分支）/`:35`（`Iterable` 分支）执行 `x.iterator().skip(positiveIdx).take(1)`；`Iterator.skip` 的语义是「从前往后跳过 count 个元素」（`core_package_classes.md:1753-1767`），按实现即 `Θ(count)`。k 个索引、容器长度 n ⇒ `Θ(k·n)`，`$[*]` 时是 `Θ(n²)`
- **方案**：切片走「一次遍历 + 游标」而不是「每个索引一次 `skip`」；确需随机访问时给 `DataList`/`DataDict` 暴露按位读取（`DataList` 内部就是 `ArrayList<Data>`，可直接 `list[i]`）
- **预期**：`$[*]` 的复杂度从 `Θ(n²)` 降到 `Θ(n)`；n=1e4 时理论上差三个数量级，但需实测确认 `skip` 是否已被迭代器特化
- **代价**：`IndexPathNode` 与切片要分两套取数逻辑；需保证 `$[i]` 单索引选择的行为不变
- **验证**：n = 1e3 / 1e4 / 1e5 三档 `DataList` 上跑 `$[*]` 与 `$[0]`，`cjpm bench -O2` 取中位数与离散度，`cjprof` 看 `skip` 相关帧自耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 切片 `$[*]` 是 `Θ(n²)`：每个索引一次 `skip(idx)` | `f_data/src/path/RangePathNode.cj:51-53` + `IndexPathNode.cj:31` | `skip` 是否被 `ArrayList` 迭代器特化；单次 `get` 自耗时占比 | n=1e3/1e4/1e5 的 `DataList` 跑 `$[*]`，`cjc -O2` 计时对照 `$[0]` |
| 2 | `SizeFilter` 反射兜底（若被下游类型命中）是单次 `check` 的主要成本 | `f_data/src/path/SizeFilter.cj:40-50` | `TypeInfo.of` + `instanceFunction` 的单次耗时与调用次数 | 对 1e4 条数据跑 `$[?(@.x size 3)]`，`cjprof record` 看反射帧占比 |
| 3 | `SolidDataPath` 把 lex/parse 放在 `entryView` 内，持锁时间与路径长度同阶 | `f_data/src/path/SolidDataPath.cj:26-30` | 单次 `doCompile` 耗时、并发首编译时的 `BLOCKED` 线程数 | 200 条不同 solid 路径 × 8 线程首次编译，线程状态采样 + 分段计时 |
| 4 | `ObjectEqFilter.check` 的物化分配在宽选择器下占比明显 | `f_data/src/path/ObjectEqFilter.cj:137-140` | 单次 `check` 分配字节数与 GC 次数 | 10 万节点文档 + `@.*` 左侧，`cjprof heap` |
| 5 | `match()` 若按 #2 改成全串校验，`find` + 区间比较的成本高于 `matches` | `f_data/src/path/MatchFilter.cj:41` | 两种实现的单次耗时与命中分布 | 1e6 行字符串（长短各一组）`cjpm bench -O2` 对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/path/MatchFilter.cj` | .cj | ✅ | 见 #2（全串语义缺失）、#12（`parseRegex` 重复） |
| 2 | `f_data/src/path/MaxPathNode.cj` | .cj | ✅ | 见 #1（比较分支恒不匹配） |
| 3 | `f_data/src/path/MinPathNode.cj` | .cj | ✅ | 见 #1（同源，与 Max 仅比较符不同） |
| 4 | `f_data/src/path/MultiIndexPathNode.cj` | .cj | ✅ | 惰性 `map/flatMap`，无中间集合；与 `MultiSubPathNode` 结构同形但节点类型不同，未并条 |
| 5 | `f_data/src/path/MultiSubPathNode.cj` | .cj | ✅ | 同上，无问题 |
| 6 | `f_data/src/path/NinFilter.cj` | .cj | ✅ | `!InFilter` 委托；缺失路径返回 `true`，与 RFC 的 `!=` 口径一致，无问题 |
| 7 | `f_data/src/path/NoOneOfFilter.cj` | .cj | ✅ | `subset == 0`；继承 `Subset` 的 `toString()` 口径比较，属既有设计，未单列 |
| 8 | `f_data/src/path/NotEqFilter.cj` | .cj | ✅ | `!EqFilter`；缺失路径 `true`，与 RFC 一致 |
| 9 | `f_data/src/path/NotFilter.cj` | .cj | ✅ | `!op.check`，语义正确 |
| 10 | `f_data/src/path/NullFilter.cj` | .cj | ✅ | 见 #4（缺失路径 + `!= null`） |
| 11 | `f_data/src/path/ObjectEqFilter.cj` | .cj | ✅ | 见 #3 #6 #13、「优化可行性方案」[堆内存]#1 |
| 12 | `f_data/src/path/OrFilter.cj` | .cj | ✅ | 短路或，无问题 |
| 13 | `f_data/src/path/RangePathNode.cj` | .cj | ✅ | 见 #9；切片复杂度见「优化可行性方案」[CPU]#1、待验证假设 #1 |
| 14 | `f_data/src/path/RecursiveDescentIterator.cj` | .cj | ✅ | 见 #5（无环检测）、#8（`rootData`）、#10（不可达 `None`） |
| 15 | `f_data/src/path/RecursiveDescentPathNode.cj` | .cj | ✅ | 单例包装，无状态，无问题 |
| 16 | `f_data/src/path/RegexFilter.cj` | .cj | ✅ | 见 #15（最小长度校验） |
| 17 | `f_data/src/path/RootPathNode.cj` | .cj | ✅ | `SingleIterable` 包装根节点，无问题 |
| 18 | `f_data/src/path/SearchFilter.cj` | .cj | ✅ | `find(...).isSome()` 子串语义正确；见 #12（`parseRegex` 重复） |
| 19 | `f_data/src/path/SizeFilter.cj` | .cj | ✅ | 见 #11（反射兜底恒假）、#14（与 `LengthCmpFilter` 重复） |
| 20 | `f_data/src/path/SolidDataPath.cj` | .cj | ✅ | 见 #7（嵌套 `entryView`）、#8（`lock`）、#16（无上限缓存） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（#1 恒取首元素、#2 全串被实现成子串、#3 字面量类型丢失）；可读性 1（#8 死字段误导「这里有锁」）。设计：过滤器与节点仍是「编译期构造、运行期只读」的一致模式，未发现职责错位；语言特性：`Option` 与类型模式混用是 #1 的直接原因（`?Data` 上挂 `DataDateTime` 类型模式），`struct`/`class` 语义本身无隐患；安全性：本部分只处理内存 `Data` 与路径字符串，无 SQL/命令拼接、无凭据、无 IO，未见注入面 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号全仓搜引用：#8（`SolidDataPath.lock`、`RecursiveDescentIterator.rootData` 零读取）、#9（`RangePathNode` 三个便捷构造零调用）、#10（`:46` 不可达）、#11（`SizeFilter` 反射分支恒假）。其余 `private`（`parseRegex`/`parseRaw`/`parseValue`/`findColon`/`splitByComma`/`dictEquals`/`dataEquals`/`dictEq`/`listEq`/`buildIndices`/`normalize`/`append`）均有调用；`public func check` 是 `DataFilter` 接口实现，按硬原则豁免；`static let instance`（`Max/Min/RecursiveDescent/Root/AnySubPath`）均有 `DataPath.cj` 引用 |
| §2 重复逻辑 | 3 | 已对 20 个文件两两比对函数体摘要（输入→输出→副作用）：#12（`parseRegex` 两份逐行相同）、#13（`splitByComma` 两份逐行相同 + `dataEquals` 覆盖漂移）、#14（`SizeFilter` 与 `LengthCmpFilter` 同一度量两份实现）。`NinFilter`/`NotEqFilter` 看似可用 `NotFilter` 合成，但 `DataPath` 的 quote 重建要求「可按字符串构造的具体类」，属实质差异，不作为重复上报；`MultiIndexPathNode`/`MultiSubPathNode` 仅节点类型不同且各 3 行，未并条（避免过度抽象） |
| §3 空实现 | 0 | 逐函数核对：无 `catch {}`、无 `TODO`/`FIXME`、无 `UnsupportedException`；`case _ => OptionIterator()`、`case _ => false`、`case _ => ()`（`RecursiveDescentIterator.cj:37`）都是「该类型不选中」的合法短路。`ObjectEqFilter.parseRaw` 的 `continue`（`:43`/`:45`）确实静默丢弃畸形键值对，但它与 #3 同根因（文本重建丢信息），已在 #3 内描述，不另计 |
| §4 栈溢出 | 2 | #5（`RecursiveDescentIterator` 无环检测，自引用图永不终止）、#6（`ObjectEqFilter` 解析递归与比较递归均无深度上限）。其余无递归：所有 `get`/`check` 都是迭代器组合；`DataPath` 的 `get` 只拼 `flatMap` 链，不进栈 |
| §5 OOM | 1 | #16（`SOLID` 无容量上限、无 `remove`，key 为调用方路径串）。其余按「最坏输入 × 单元素」核对：`RangePathNode` 的索引数组与 `ObjectEqFilter` 的结果数组都与输入规模同阶（属放大分配，已放「优化可行性方案」）；`RecursiveDescentIterator` 的栈只按容器数增长（成环问题归 #5）；本部分无整文件读入、无按报文头预分配 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof` / `cjpm bench` 数据，无法给出「函数 + 自耗时占比 + 调用路径 + 输入规模」四要素，故热点结论不成立；5 条疑似热点已写入「待验证假设」 |
| §6.2 大粒度锁 | 1 | #7 的「锁内做 lex/parse」部分：`SolidDataPath` 在 `entryView` 回调里整段编译路径（`doCompile` → `parseFilterTokens` → `compileFilter`），临界区内容与时长已知但竞争线程数与持有时长未测，故只作机制层记录，不计入性能缺陷 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池/队列消费，无串行段 |
| §6.4 低效算法 | 1 | `RangePathNode` 每索引一次 `skip(idx)` ⇒ `Θ(k·n)`（见「优化可行性方案」[CPU]#1）。缺「实际耗时占比」，未升级为发现；`ObjectEqFilter.dictEq` 的双层循环（`:175-189`）已由 `parts/f_data.part5.md` 在 `EqPathFilter` 侧报出同源问题，本部分不重复计 |
| §7 降堆内存方案 | 2 | [堆内存]#1（`ObjectEqFilter.check` 物化）、#2（`RangePathNode` 索引数组 + 每元素节点）；其余节点/过滤器都是惰性迭代器，无中间副本可省 |
| §8 降 CPU 方案 | 1 | [CPU]#1（切片二次扫描）；`SizeFilter` 的反射分支已按 §1 死代码处理（删除即最优），不另立优化项 |
| §9 local mode 可行性 | 0 | `f_data/cjpm.toml` 已在模块级开启 `--experimental --enable-local-mode`，本部分无需「再改造」；且本部分没有「函数内创建、函数内用完的大对象」——`RangePathNode`/`ObjectEqFilter` 的临时集合虽与输入同阶，但收益只能用峰值内存证明，当前无峰值基线，按规则不列方案 |
| §11 现有代码的 BUG（存量） | 6 | 逐函数核对了 20 个文件的边界/空值/错误路径：#1（逻辑错误）、#2（契约不符）、#3（数据错误）、#4（空值分支）、#6（递归深度）、#15（切片边界）。已核对无问题的边界：`RangePathNode.normalize`（负值折算与夹取正确，`[-7:]` 形态有 `rfc9535_slice_test.cj` 覆盖）、`IndexPathNode` 越界返回空、`InFilter`/`EqFilter` 的 `None` 路径返回 `false`、`Subset.subset` 缺失路径返回 `0`、`SizeFilter` 对 `-1` 的 `==` 比较（`right >= 0` 时恒 `false`，无副作用） |
| §12 并发安全与锁粒度 | 1 | #7（同一线程在 `ConcurrentHashMap` 回调内再次进入同一张表，锁粒度/可重入性待确认）。其余共享点逐个核对：`SOLID` 是唯一的跨线程状态，写入只经 `computeIfAbsent`（原子，std 文档 `collection_concurrent_class.md:1243-1247`），发布后 `DataPath.nodes` 只读；`MatchFilter.regex`、`NullFilter.left`、`ObjectEqFilter.right` 等都是构造期赋值后不变的字段；`Max/Min/RecursiveDescent/Root` 的单例无状态；`check`/`get` 只用局部变量。故其余判线程安全 |
| §14 功能完备性与 README 覆盖 | 2 | #1（`README.md:450-451` 承诺 `min()/max()` 未实现，`doc/RFC9535_COVERAGE.md:120` 还把 `testFunctionMin/Max` 当覆盖证据）、#2（`README.md:505` 承诺 `match()` 全串匹配）。README 对照：本部分涉及的 `=~`、`in/nin/anyof/subsetof/nooneof`、`size N`、`@ == {...}`、`@.* == [...]`、`min/max`、`match/search` 均有对应段落（`README.md:446-596`），无「public 能力未文档化」；`ObjectEqFilter` 的 `!=` 形态（`@ != {...}`）未在 README 出现，属次要参数遗漏，不单列 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无缺读；`.md` 为 0 个，§13 不适用（模块 README / `doc/**` 一致性由其他部分覆盖，本报告只在 #1/#2/#3/#16 中作为承诺源引用） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量缺陷 16 条（严重 3、一般 4、轻微 9），是否纳入修复待用户决定。

## 总评

本部分是 `src/path/` 的「字面量/正则/切片/递归下降」一族，代码量小、结构一致，但**语义失真**比性能问题严重得多，三条严重项都属于「不报错、只给错答案」：

- `min()`/`max()` 的比较分支挂在 `Option<Data>` 上永远匹配不到，两个函数退化成「取首元素」（#1）——编译期就有 `unreachable pattern` 告警，只是没人看，测试又只断言条数；
- `match()` 用 `Regex.matches`（存在匹配）实现「全串匹配」，与 `search()` 等价（#2）；
- 对象字面量比较把 token 拼成无引号文本再手写解析，字符串 `"123"` 被还原成数值 `123`、`"a,b"` 被逗号切开（#3）。

这三条都建议作为阻塞项：修复量都不大（#1 换成 `Some(y)` 绑定、#2 换成 `find` + 区间校验、#3 改为按 token 构造 `Data`），但都需要补「值断言」级用例才能锁住——现有 `testFunctionMin/Max`、`testFilterMatch`、`testFilterObjectEq` 全都是「只数条数」或「pattern 恰好等于输入」，正是它们让上述缺陷长期存活。

一般项集中在「边界与递归」：#4 缺失字段的 `!= null` 与自身注释相反；#5/#6 的两条递归/遍历缺少环检测与深度上限，前者靠调用方构环触发，后者靠深嵌套输入触发，都是「不抛 `DataException`、直接挂死或崩栈」的形态；#7 是唯一涉及并发的项——`SolidDataPath` 在 `ConcurrentHashMap` 回调里递归回到同一张表，是否自锁取决于 std 内部锁粒度，需一次单线程验证即可定论，建议优先排除。

轻微项里 §1 占了四条（未使用字段、未使用构造、不可达语句、恒假反射分支），删除风险极低；§2 的三条重复（`parseRegex`、`splitByComma`/`dataEquals`、尺寸计算）已经漂移出行为差异，建议随 #3/#11 的改动一并收敛到 `FilterUtils`。性能与内存的三条方案全部无基线，留待下一轮补 `cjprof` / `cjpm bench -O2` 数据后再决定是否立项，其中切片的 `Θ(k·n)` 最值得先测。
