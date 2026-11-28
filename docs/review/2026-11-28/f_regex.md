# f_regex 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_regex`（6 个 .cj 源文件共 816 行 + 2 个 .md 共 187 行）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git blame` 全部落在 `4be871f2f chore: 统一换行符为 LF`（2026-10-02）与 `2623bbfff docs(README)`（2026-10-06），本报告全部问题来源记为「存量」）
- **审查重点**：正则语义正确性、栈溢出（回溯）、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [严重][存量] `RegexBuilder` 的“不可变”契约不成立：多数成员原地改写并返回 `this`，`oneOf` / `group` 却返回全新实例

- **位置**：`f_regex/src/RegexBuilder.cj:44-61`（`start`/`end`/`any`，代表 40+ 个同类 prop）、`:62-296`（全部字符类与量词 prop）、`:205-234`（`group_` / `group` 三个重载）、`:352-371`（`operator[]` / `oneOf` / `notOneOf`）、`:414-417`（`append`）；契约来源：`f_regex/README.md:52`、`:85`、`f_regex/README_en.md:53`、`:86`；过期注释：`f_regex/src/RegexBuilder.cj:20-29`
- **来源**：存量（`git blame -L 44,61`、`-L 205,234`、`-L 366,371` 均为 `4be871f2f`；README 两句为 `2623bbff`）
- **判据**：review-checklist §11（契约与实现不符）、§12.1（共享可变状态 / 发布逸出）、§2（同族 API 两套语义并存）、§13（注释与实现相反）
- **证据**：静态确定 —— 三类证据互不依赖：
  1. `start` 的 getter 是 `pattern.append(r'^'); return this`（`:46-48`），`pattern` 是 `private var pattern = StringGenerator()`（`:31`）这一**可变**对象。`let a = b.digit` 之后 `b` 也随之变成 `\d`：字符串在 `a` / `b` 之间按引用共享，任何“分叉复用”都会互相污染。
  2. `oneOf` / `notOneOf` / `group` 走另一套语义：`return RegexBuilder()[false, parts...]`（`:367`）、`return RegexBuilder().group_(false, part)`（`:221`）、`RegexBuilder().group_(dir, part)`（`:233`）——**新建 builder，丢弃已累积的 pattern**。而 `operator ()(part)`（`:217-219`）调用的是 `group_(false, part)`，改的是 `this`。同一个动作 `b.group("x")` 与 `b("x")` 结果不同。
  3. 用 README 自己的示例（`README.md:72-78`）演算：`RegexBuilder().start` → `^`；`.oneOf(['a','b'])` → 丢弃 `^`，得到 `[ab]`；再 `.digit.oneOrMore.end` → **`[ab]\d+$`**，不是期望的 `^[ab]\d+$`。`re.matches('a123')` 仍为 `true`，示例“看着对”，但 `re.matches('xa123')` 也是 `true`，锚定已失效。
- **描述**：README 明确写“不可变，每次调用返回新的 builder”“每个 prop/func 都返回新实例，可以安全地分叉复用”，实现是“绝大多数成员原地改 + 三个成员换新实例”。后果分三层：
  - **正确性**：混用两种写法时前缀静默丢失（上面的 `^` 就是被 `oneOf` 吃掉的）；把 builder 当值传给别的函数再继续链式调用，会改掉调用方的 pattern。
  - **并发**：类内无任何同步，`pattern.append` 是“读长度 → 扩容 → 写字节”的多步可变操作；按 README 的“可安全分叉复用”把它当值对象跨线程共享，就是数据竞争（`StringGenerator` 的 `ArrayList<Byte>` 会被两个线程同时 `add`）。
  - **注释反向**：`:25-27` 写“`_` 结尾的属性会创建新的 RegexBuilder，同名没有 `_` 结尾的属性不会创建”，实现里带 `_` 的只有 private 的 `group_` / `mORn`，公有 prop 一个都没有；`:21-23` 的 `Regex.builder{b=> b.start(b.digit_.oneOrMore.greedy).end }` 既引用了不存在的 `digit_`，`{b=>}` 也不是仓颉语法。
- **建议**：二选一，不要混用：
  - **改不可变**（推荐，与 README 和现有链式示例一致）：`private init(pattern: String)`，每个 prop 返回 `RegexBuilder(pattern + token)`，`oneOf` / `group` 在 `this` 的 pattern 后追加而不是新建；`build()` 后不可再改。
  - **改可变**：保留 `return this`，把 `oneOf` / `group` 也改成原地追加（`this[false, parts]`），同时把 README 的“不可变 / 可安全分叉”删掉，改写为“单线程内链式构造，构造完成后视为只读”。
  - 顺手把 `private var pattern`（`:31`，从未重新赋值）改成 `let`，并重写 `:20-29` 那段与实现无关的头注释。

### [严重][存量] `range()` 的 min/max 校验条件写反：合法区间抛异常，非法区间生成坏正则

- **位置**：`f_regex/src/RegexBuilder.cj:337`（`range`），入口 `:330-335`（`startRange` / `endRange`）
- **来源**：存量（`git blame -L 336,340` → `4be871f2f`）
- **判据**：review-checklist §11（边界判断反向 / 逻辑错误）、§10（正确性）
- **证据**：静态确定 —— 条件为 `(min < 0 && max < 0) || (min > 0 && max > 0 && min < max)`，第二段用的是 `min < max`（应为 `min > max`）。异常文案（`:339`）自己写着“min must less or equals to max”，与代码判据相反。
- **描述**：逐项推演：
  - `range(2, 5)`（正常用法）→ `2 > 0 && 5 > 0 && 2 < 5` 成立 → 抛 `RegexBuilderException`，合法调用被拒。
  - `range(5, 2)`（非法）→ 条件不成立 → 拼出 `{5,2}`，`build()` 时由 `std.regex` 抛语法异常（或按引擎差异变成字面量匹配），错误在离现场很远的地方才暴露。
  - `range(5, 0)` / `range(3, -1)`（一端为 0 / 负数）同样漏检，产出 `{5,0}` / `{3,-1}`。
  - `range(0, 0)` 产出 `{0,0}`，语义上是“恰好 0 次”，属可用但无文档。
  - `endRange(max)` 走 `range(-1, max)`，产出 `{,max}`：省略下界的写法并非所有引擎都接受（PCRE 系到较新版本才支持），std.regex 是否接受未在文档中写明（见待验证假设 #3），建议直接产出 `{0,max}`。
- **建议**：条件改为 `if ((min < 0 && max < 0) || (max >= 0 && min > max)) { throw ... }`；`endRange` 改成 `range(0, max)` 以产出 `{0,max}`；补三个用例：`range(2,5).build().string() == "\d{2,5}"` 形态、`range(5,2)` 必须抛、`endRange(3)` 必须能 `build()`。

### [严重][存量] `RegexReplacement` 的 `$n` 模板解析错误：末尾组引用退化成字面量，占位符后面的字符被吞掉

- **位置**：`f_regex/src/ExtendRegex.cj:146-175`（`init`），消费点 `:99-101`（`doReplace`）、`:109-117`（`doReplaceAll`）、`:176-186`（`format`）
- **来源**：存量（`git blame -L 146,186` → `4be871f2f`）
- **判据**：review-checklist §11（逻辑错误 / 数据错误）、§13（README 承诺 `$n` 模板）
- **证据**：静态确定 —— 循环 `:149-169` 只有在“`$` 之后遇到**非数字**字符”时才把 `placeholder` 段转成组索引（`:158-166`），且该分支**不把当前字符追加回 `part`**；循环结束后 `:170-174` 只处理“模板以 `$` 结尾”，其余情况一律 `parts.add(part.toString())`，即把数字当**字符串**。逐条推演：
  - `"$1"`（最常见写法）：`$` 只置 `placeholder`，`1` 进 `part`，循环结束走 `:172-173` → parts 里是 String `"1"` → `format` 输出字面 `1`，**组 1 永远取不到**。
  - `"a$1b"`：`b` 命中 `:158` 分支，组索引 1 被 add（正确），但 `b` 没有被 append → 输出只剩 `a` + 组 1 的内容，**`b` 丢失**。
  - `"a$x"`：`x` 命中同一分支但 `part` 为空 → 只 `parts.add("$")`（`:164`），`x` 丢失 → 输出 `a$`。
  - 只有 `"$"`（模板以 `$` 结尾，`:170-171`）和“`$` 后紧跟数字且数字串后还有字符”的组合能勉强工作，后者还会吞字符。
  - 叠加：`Int64.parse(part.toString())`（`:160`）对超长数字串会抛 `NumberFormatException`；`format` 里 `data.matchString(x)`（`:181`）对越界组号直接抛 `IndexOutOfBoundsException`，`$9` 这种笔误不是“替换为空”而是抛异常。
- **描述**：`doReplace` / `doReplaceAll` 是模块的两个核心替换 API，README.md:67 明确把 `RegexReplacement` 描述为“`$n` 形式的替换模板”，`README.md:30-34` 的接口注释也把 `replacement!` 指向它。**最典型的用法 `replacement: "<$1>"` 实测推演输出是 `"<" + 组1`，结尾的 `>` 被吞掉**（`$1` 后的第一个字符永远不进结果），得到静默错误的文本，不报错、不告警。仓内没有调用方（全仓 grep `doReplace` 只命中定义处），所以现有测试与业务都碰不到，缺陷完全留给下游用户。
- **建议**：改成一次扫描 + 显式 token 化：遇到 `$` 时向后读连续数字，读完即 flush 成 `Group(idx)`（**到字符串结尾也要 flush**）；`$$` 约定为字面 `$`；`$` 后不是数字时 `$` 与后一字符都按字面输出（不吞字符）；`parse` 失败按字面量降级。`format` 里组号越界改为输出空串或 `Option`，并在 README 写明组号规则（0 = 整个匹配、越界行为）。

### [一般][存量] `wildcard()` 只转义 `.`，`*` / `?` / `..` 的语义与 glob 不符，未转义元字符会让 `Regex()` 直接抛异常

- **位置**：`f_regex/src/ExtendRegex.cj:76-85`
- **来源**：存量（`git blame -L 76,85` → `4be871f2f`）
- **判据**：review-checklist §11（契约与实现不符 / 输入未校验）、§13（README.md:27 承诺“把带通配符的字符串转换为正则表达式”）
- **证据**：静态确定 —— 六条 `String.replace` 可逐条推演（`String.replace(old, new)` 为字面替换，已核对 std 文档 `core_package_structs.html`）：
  - `wildcard("a?")`：`?` → `\w?`（`:82`），`\w?` 允许**零个**字符，`"a"` 也匹配；glob 的 `?` 是“恰好一个字符”。
  - `wildcard("*.txt")`：`*` → `\w*`（`:81`），`\w` 在无 `Unicode` flag 时是 `[A-Za-z0-9_]`，匹配不到 `a-b.txt`、`中文.txt`；仓内真实调用点 `f_aspect/src/AspectRoute.cj:85`、`:138`、`:161` 正是拿它匹配限定名（含 `::`）与 bean 名。
  - 只转义 `.`（`:78`），`+ ( ) [ ] { } | ^ $ \` 原样进入正则：`wildcard("a+b")` → `^a+b$`（匹配 `"aab"`，不是 `"a+b"`）；`wildcard("a(b")` / `wildcard("a[1")` → 直接让 `Regex()` 抛语法异常，把“匹配不上”变成“调用点崩溃”。
  - `..` 被当成通配段而不是两个字面点：`wildcard("../a")` 依次变成 `^\.\./a$` → `^(\.\w+)#\./a$`（`:79`）→ `^(\.\w+)*\./a$`（`:83`），**匹配不到 `../a`**。`:80` 那条 `\.*\.` → `\.\w+\.` 把 `.*.` 两端的点也变成**字面**点，与 glob 语义相反。整条链依赖“上一条 replace 的产物”做字面匹配，任一环调整都会连带破坏。
- **描述**：`wildcard` 是 `f_aspect` 做切面匹配的唯一入口（`Regex.wildcard(qualifiedName).matches(...)`），也是 `f_bean` 的 `Wildcard` 条件实现基础（`f_bean/src/BeanStringCondition.cj:81`）。当前实现下 `*` 不跨非词字符、`?` 可以为空、元字符泄漏，属于“静默错配 + 偶发抛异常”的组合，且被错配的是路由/切面选择这种“选错了就执行错逻辑”的场景。
- **建议**：改成单遍扫描：`*` → `.*`（或按需 `[^/]*`）、`?` → `.`，其余字符逐个转义（`\` + 字符，或用 `\Q...\E`），不要再做多次 `replace`；README 明确“`*` 是否跨 `.` / `/`、`?` 是否含换行”，并给出 3 个示例（`*.txt`、`a?b`、`a.b`）。同时补 `wildcard("../a")`、`wildcard("a(b")` 两个用例。

### [一般][存量] `solid: true` 的缓存 `SOLID` 无上限、无 TTL，键来自调用方 pattern

- **位置**：`f_regex/src/RegexFromString.cj:29`（`private let SOLID = ConcurrentHashMap<String, Regex>()`）、`:52-59`（`computeIfAbsent` 只写不删）
- **来源**：存量（`git blame -L 28,29`、`-L 52,59` → `4be871f2f`）
- **判据**：review-checklist §5（缓存键无界 / 长期持有）、§7.4（有界化）
- **证据**：静态确定 —— 全文件搜 `remove` / `clear` / 容量判断：`RegexFromString.cj` 66 行内对 `SOLID` 只有 `get` 与 `computeIfAbsent`，没有任何淘汰路径；对比同文件 `CACHE`（`:28`）显式给了 `maxLife: Duration.day, maxSize: 10000`。
- **描述**：`solid` 的设计意图是“进程级常量正则”，实现却把**任何**传 `solid: true` 的 pattern 永久钉住，值还是编译后的 `Regex`（引擎字节码 + 元数据，量级远大于源串）。仓内多数调用点是字面量（`f_util/src/Utils.cj:26`、`f_data/src/base/NumberData.cj:33-400` 数十处），本身无风险；但 `f_data/src/validation/Validator.cj:271`（`this.regex.regex(solid: true)`）与 `:151`（模板拼出 pattern 后 solid）吃的是**校验规则配置**，下游把用户提交的 pattern 接进来即可无界增长。`maxSize: 10000` 给了非 solid 路径一个上界，solid 路径没有，等于“为防止重复编译而付出无界内存”。
- **建议**：给 `SOLID` 也加容量上限（复用 `HeapCache` 或自己计数），满时降级到 `CACHE`；在 `README.md:83` 与接口注释把 `solid: true` 限定为“只用于编译期字面量 / 进程常量”，并说明“运行期拼接的 pattern 请用 `solid: false`”。若要严格，可只允许 `regex(solid: true)` 在首次调用时生效、之后同 key 直接返回，不做容量治理（前提是文档写清不可用于外部输入）。

### [一般][存量] `doReplaceAll` 用 `findAll` 全量物化匹配结果

- **位置**：`f_regex/src/ExtendRegex.cj:107`、`:126`（`let mds = this.findAll(sub, group: true)`）
- **来源**：存量（`git blame -L 105,141` → `4be871f2f`）
- **判据**：review-checklist §5（一次性物化）、§7.3（流式化）
- **证据**：静态确定 —— std 文档 `regex_package_classes.html` 明确 `findAll(input: String, group!: Bool = false): Array<MatchData>`，返回**数组**；`group: true` 使每个 `MatchData` 还带捕获组位置数组。
- **描述**：替换只需顺序消费，实现先把全部匹配物化再拼接：峰值 ≈ `匹配数 × (MatchData + 组位置)` 个对象 + `StringGenerator` 的 O(输出)。量化：100 MB 文本、模式 `\d`（每 10 字节一个匹配 → 10^7 个匹配），单个 `MatchData` 保守按 64 B 计即 ~640 MB 额外峰值，超出多数容器 limit；模块内无调用方，但这是公开 API，且 README 没有任何“输入规模”限制说明。
- **建议**：改成流式：`var start = 0; while (let Some(md) <- this.find(sub[start..])) { ... start += pos.end }`（`Regex.find(index: Int64)` 已存在，可避免每轮切片），边匹配边 `append`；确需预分配时先 `count` 再一次性开 `StringGenerator`。同时在 README 注明“单次替换的输入上限由调用方保证”。

### [轻微][存量] `doReplaceAll` 两个重载的拼接循环逐行重复，`greedy` / `notGreedy` 逐行重复且异常文案抄错

- **位置**：`f_regex/src/ExtendRegex.cj:105-123` 与 `:124-141`（仅 `rr.format(md)` 与 `replacement(md) ?? md.matchString()` 一行不同）；`f_regex/src/RegexBuilder.cj:298-313` 与 `:314-329`（仅追加字符与异常文案不同，且 `:325` 的文案仍写 “greedy mode must be following with + or *”）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §2（换字面量的复制 / 近似重复导致行为漂移）
- **证据**：静态确定 —— 两处函数体压成摘要后完全一致：`(input, index, 替换源) → 逐匹配拼接 → String`；`(this) → 追加 + / ? → this`。
- **描述**：`doReplaceAll` 的两份实现已经出现“一处改了另一处没改”的苗头（`prevEnd` 推进逻辑重复维护）；`greedy` / `notGreedy` 的复制导致 `notGreedy` 的错误消息指向 greedy，排查时会被误导。差异点（一个有模板对象、一个走回调）是业务要求，可以合并成 `private func replaceAll(input: String, index: Int64, replacer: (MatchData) -> String): String`，由两个公开重载各传一个闭包。
- **建议**：按上面签名抽一个私有实现（`rr.format` / `replacement(md) ?? md.matchString()` 变成 `replacer`）；`greedy` / `notGreedy` 抽 `private func quantifier(cmd: Rune, name: String)`，文案用 `${name} mode must ...`。合并后必须补等价性用例（含零长匹配、连续匹配）。

### [轻微][存量] README 与 `ExtendRegex` 声明不同步：缺 `Regex.builder()` 两个入口，`notIn` / `operator|` 未列入公开 API

- **位置**：`f_regex/README.md:12-36`（interface 代码块）vs `f_regex/src/ExtendRegex.cj:33-34`；`f_regex/README.md:93`（其他公开 API 清单）vs `f_regex/src/RegexBuilder.cj:384-389`（`prop notIn`）、`:390-392`（`operator |`）；`README_en.md:12-36`、`:94` 同构缺
- **来源**：存量（README `2623bbff`，源码 `4be871f2f`）
- **判据**：review-checklist §13（文档与代码不一致）、§14.2（公开 API 未文档化）
- **证据**：静态确定 —— README 的 interface 块是“照抄声明”式契约，逐条比对只剩 `INTEGER`…`BASE64`、`wildcard`、三个 `doReplace*`，缺 `static func builder(): RegexBuilder` 与 `static func builder(callback: (RegexBuilder) -> Unit): Regex`；全文搜 `builder`（`README.md:52`、`:60`）只出现 `RegexBuilder` 类名与 `builder[parts]` 这种操作符写法，**`Regex.builder()` 这个 DSL 唯一入口在 README 中完全没有出现**。`notIn` 只在 `builder[notIn: true, parts]` 里作为具名参数出现，`prop notIn` 与 `operator |` 都不在公开 API 清单里。
- **描述**：`Regex.builder()` / `Regex.builder{...}` 是 `f_regex` 的两条主入口（测试 `Regex_test.cj:27`、`:30` 就用它），README 不给签名也没有示例，使用者只能去翻源码；`prop notIn` 是把裸 `^` 追加到 pattern 的低层片段（单独使用会产出非法正则），既不文档化也不标注“仅在 `[` 之后使用”。
- **建议**：README 的 interface 块补两行 `builder` 签名 + 一个 `Regex.builder{b => ...}` 示例；`RegexBuilder` 清单补 `notIn`、`operator |` 与 `operator[]` 的两种形态；`notIn` 加上“必须紧跟 `lsquare` 使用”的注释，或改成 `notIn(parts)` 这类不会误用的形态。

### [轻微][存量] README 对 `solid` 的说明与实现相反

- **位置**：`f_regex/README.md:83` / `f_regex/README_en.md:84` vs `f_regex/src/RegexFromString.cj:52-59`
- **来源**：存量（README `2623bbff`，源码 `4be871f2f`）
- **判据**：review-checklist §13（文档过期 / 与实现不符）
- **证据**：静态确定 —— README 写“实例常驻进程（**每次访问静态prop都会编译**）”；实现是 `SOLID.computeIfAbsent(key){...}`，命中后直接返回同一实例，不重新编译。`Regex_test.cj:36-45` 的 `test2` 就是拿两次 `regex(solid: true)` 的耗时差做对照，恰好证明第二次不编译。
- **描述**：这句括号让读者以为 `solid: true` 只是“语义上常驻”，性能上仍每次编译，从而误判该不该用；实际是“首次编译 + 永久复用”。另外“`Regex` 对象被回收后缓存可能失效”（同段）描述的是 `HeapCache` 的内部行为，没有说明它对本模块可见的影响（`CACHE` 持有强引用，条目未淘汰前不会失效），表述含糊。
- **建议**：改成“首次调用编译并存入进程级表 `SOLID`，之后同 pattern + flags 直接复用；`solid: false` 走 `HeapCache`（上限 10000 条、寿命一天，条目淘汰后会重新编译）”。

### [轻微][存量] `greedy` 的名字与语义不符（实际生成占有量词），`notGreedy` 不支持 `?` 与 `{n,m}`

- **位置**：`f_regex/src/RegexBuilder.cj:298-313`（`greedy` 追加 `+`，得 `++` / `*+`）、`:314-329`（`notGreedy` 只接受末尾是 `+` / `*`）
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §10（语义与命名不符）、§14.1（能力只做了一半）
- **证据**：静态确定 —— `p[p.size - 1]` 是 `+` 或 `*` 时 `pattern.append(r'+')`；`X++` / `X*+` 是**占有量词**写法（吃掉后不回溯），而“贪婪”本来就是默认行为，`greedy` 这个名字会让人以为它是 no-op。反方向 `notGreedy` 追加 `?`，但对 `?`、`}` 结尾的 pattern 直接抛异常（`:321`），因此 `zeroOrOne.notGreedy`、`range(1,3).notGreedy` 都不可用。
- **描述**：类头注释 `:23` 的 `b.start(b.digit_.oneOrMore.greedy).end == ^(\d++)$` 说明作者本意就是占有量词；命名与注释不一致，且 lazy 只覆盖 `+` / `*` 两种量词，是“能力做到一半”。
- **建议**：`greedy` 改名为 `possessive`（或 `atomic`），保留旧名做 `@Deprecated` 转发；`notGreedy` 的判定改为“末尾是 `+` / `*` → 追加 `?`；末尾是 `?` → 追加 `?`；末尾是 `}` → 在 `}` 前插入 `?`”，并把两段的异常文案分别写清。

### [轻微][存量] 测试只有 2 个用例有断言，`$n` 替换 / `wildcard` / `range` / `doReplace` 零覆盖

- **位置**：`f_regex/src/Regex_test.cj:34-45`（`test2`）、`:46-88`（`test3`）无 `@Assert`，仅 `println` 耗时
- **来源**：存量（`4be871f2f`）
- **判据**：review-checklist §10（可测试性）、§6.1（无对照的计时不构成度量）
- **证据**：静态确定 —— 三个 `@TestCase` 中只有 `test`（`:25-33`）有 2 个 `@Assert`（都是 `reg.string()` 对比），`test2` 打印两次 solid 编译耗时与一次直接构造耗时，`test3` 20 线程 × 1000 次循环打印累计纳秒；两者无断言、无阈值、无对照基线。
- **描述**：本报告 3 条严重缺陷全部落在零覆盖区域：`RegexReplacement`（`$n`）、`range` 边界、`oneOf` / `group` 的“新实例”分支（测试用的是 `lsquare...rsquare`，绕开了 `oneOf`）。`test3` 反而会放大问题：它以“计时”为目的在 CI 里起 20 个线程跑 2 万次编译，既不稳定也不产生结论。
- **建议**：把 `test2` / `test3` 的计时搬去 `cjpm bench`；补断言型用例：`"abc123".regex().doReplace("abc123", replacement: "<$1>", index: 0)`、`doReplaceAll` 回调返回 `None`、`wildcard("a?")` / `wildcard("../a")`、`range(2,5).build().string()`、`RegexBuilder().start.oneOf(['a','b']).build().string() == "^[ab]"`。

## 优化可行性方案

> 不是缺陷，是“还能更好”。以下两条均无改前基线，按规则只作待验证项，不进 `todo.md` / `tasks.md`。

### [堆内存] `RegexReplacement` 用 `ArrayList<Any>` 混装 `String` / `Int64`

- **现状**：`ExtendRegex.cj:145` `private let parts = ArrayList<Any>()`；每个 `$n` 触发一次 `Int64` 装箱（`:161`），每段字面量触发一次 `String`（`:153`、`:173`），`format`（`:176-186`）再按类型 `match` 分派。一个含 5 个占位符的模板约 10 个元素 + 5 次装箱，生命周期与 `RegexReplacement` 实例同长；`doReplaceAll` 里每次调用只 `new` 一次，量级不大。
- **方案**：改为 `enum Part { Literal(String) | Group(Int64) }` + `Array<Part>`（或两个平行数组：`Array<String>` 字面量 + `Array<Int64>` 组号），消除 `Any` 装箱与运行期类型分派。
- **预期**：每条模板少 `k` 次装箱（`k` = 占位符数）、`format` 少 `2k` 次类型判断；对单次替换可忽略，对“大文本 + 多占位符 + 高频替换”场景才有意义，收益未量化。
- **代价**：多一个包内 enum；`format` 需重写，必须补 `$1` / `$$` / 越界组号的等价性用例。
- **验证**：`getAllocatedHeapSize()` 前后对照 + `cjpm bench -O2`，10 万次 `doReplaceAll`（1 KB 文本、3 个占位符）取中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `regex()` 每次调用都重建缓存键（HashSet + StringGenerator + 字符串插值）

- **现状**：`RegexFromString.cj:40-51`，每次 `regex()`（含缓存命中）都执行：`HashSet<String>` 构造 + 每个 flag 一次 `add` + `StringGenerator` 拼接 + 3 次字符串插值（`"/${this}/${flagsstr()}"`）。即使 `flags` 为空也有 2 个容器 + 1 个结果串的分配。旁证：`f_bean/src/BeanStringCondition.cj:19-20` 与 `f_bean/src/test/bean_string_cond_test.cj:26-27` 已在**调用侧**为此加了一层 `REGEX_CACHE` / `WILDCARD_REGEX`，说明这个成本在别的模块被实际感知到。
- **方案**：`flags` 编码成位掩码（3 个 flag → 1 个 `Int64`），key 用 `(pattern: String, flagBits: Int64)` 的二元键放进 `HeapCache` 的另一层映射，或用 `"${flagBits}:${pattern}"` 单串；`flags` 为空时走 `CACHE.getOrCompute(pattern)` 直通，不再拼 key。
- **预期**：缓存命中路径从 3 次分配 + 3 次拼接降到 0-1 次分配；具体降幅需 profile 确认，按 Amdahl 估对端到端影响大概率低于噪声（5%），无数据前不给百分比。
- **代价**：`CACHE` 的 key 语义变化，已缓存的条目会重建一次；`HeapCache` 是单 string key 设计，改成二元键需要包一层字符串或换容器。
- **验证**：`cjpm bench -O2`，1e6 次 `regex()`（pattern 固定、flags 空）对照中位数与离散度；`cjprof record` 看 `regex` 的 self time 占比。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `std.regex` 若是回溯引擎，`RegexBuilder` 可拼出灾难性回溯 / 爆栈模式（如 `(a+)+$`），`group().oneOrMore`、`text()` 都不设防 | `f_regex/src/RegexBuilder.cj:201-234`、`:282-296`；`f_regex/src/ExtendRegex.cj:61-75`（`DURATION` 的嵌套量词） | 引擎实现（回溯 / DFA）与该模式的耗时曲线、栈深 | `cjpm bench -O2` 跑 `"(a+)+$".regex().matches("a" × n + "b")`，n = 20/25/30/35 记耗时；再把栈上限调低（`ulimit -s`）观察是否栈溢出；确认运行时是否链接 libpcre2（回溯）还是自研 DFA |
| 2 | `regex()` 的键构造占缓存命中路径的主要开销 | `f_regex/src/RegexFromString.cj:40-51` | 命中路径的耗时占比与分配次数 | `cjprof record` 跑 1e6 次固定 pattern 的 `regex()`，看 `regex` / `HashSet` / `StringGenerator` 的 self time；另记 `getAllocatedHeapSize()` 差值 |
| 3 | `endRange(max)` 产出的 `{,max}` 是否被 `std.regex` 接受 | `f_regex/src/RegexBuilder.cj:333-335`、`:345-349` | 该简写在目标引擎上的语法支持 | 单测 `let re = RegexBuilder().endRange(3).build(); re.matches("aaa")`，看 `build()` 是否抛 `SyntaxException`；查 1.3.0 版 std.regex 的语法说明 |
| 4 | `CACHE`（10000 条）+ `SOLID`（无界）的峰值内存量级，决定是否该给 `SOLID` 设上限 | `f_regex/src/RegexFromString.cj:28-29` | 单个 `Regex` 实例的深堆大小 | 编译 1 万个典型 pattern（长度 20-80）后测 `getUsedHeapSize()` 差值，除以条目数得单条均摊；再乘 10 万估算 `SOLID` 失控时的量级 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_regex.txt` 一一对应，8 行全覆盖。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_regex/README.md` | .md | ✅ | 93 行全读；interface 块缺 `builder`×2（发现「README 与声明不同步」）、`solid` 说明与实现相反（见轻微「README 对 `solid` 的说明与实现相反」）、`不可变 / 可安全分叉`与实现矛盾（严重 #1）；DSL 示例本身因 `oneOf` 丢 `^`；根 `README.md:347-352` 已登记本模块 |
| 2 | `f_regex/README_en.md` | .md | ✅ | 94 行全读；与中文版逐节同构（4 个章节 + 其他公开 API 清单一一对应），上述缺陷同样存在（`:53`、`:84`、`:86`），无整节缺失 |
| 3 | `f_regex/src/ExtendRegex.cj` | .cj | ✅ | 187 行全读；7 个预置正则 + `wildcard` + 2 个 builder 入口 + 3 个替换方法 + `RegexReplacement`；缺陷集中在 `wildcard`（一般）、`RegexReplacement`（严重）、`findAll` 物化（一般）；`doReplaceAll` 两重载重复（轻微） |
| 4 | `f_regex/src/RegexBuilder.cj` | .cj | ✅ | 418 行全读；40+ 个 prop 与 10 个 func/operator；`range` 条件反向（严重）、可变 / 不可变两套语义混用（严重）、`greedy` 命名（轻微）；`private` 成员 `group_`×2、`mORn`、`append` 均有引用 |
| 5 | `f_regex/src/RegexFromString.cj` | .cj | ✅ | 66 行全读；`CACHE` 有界（10000 / 一天）、`SOLID` 无界（一般）；`flagsstr()` 虽未标返回类型，但按其末表达式推断为 `String`（对照 `cj_syntax.md:11`、`:28` 的推断规则），因此 key **确实**带 flags，此项经核对非缺陷；`computeIfAbsent` 走 `f_collection/src/ExtendCollection.cj:61` 的 `entryView` 实现，单 key 原子 |
| 6 | `f_regex/src/Regex_test.cj` | .cj | ✅ | 89 行全读；3 个用例，仅 `test` 有 2 个断言；`test2` / `test3` 只打印耗时（轻微），20 线程 × 1000 次循环在 CI 中无结论 |
| 7 | `f_regex/src/SearchDirection.cj` | .cj | ✅ | 24 行全读；两值枚举，注释与 `(?=X)` / `(?<=X)` 一致；被 `RegexBuilder.cj:224-227` 的 `match` 穷尽覆盖 |
| 8 | `f_regex/src/exception/RegexBuilderException.cj` | .cj | ✅ | 32 行全读；4 个构造器全部委托 `BaseException`，`init() {}` 是合法空构造（无状态异常），非空实现缺陷；被 `RegexBuilder.cj:302`、`:308`、`:318`、`:324`、`:338` 使用 |

合计：`.cj` 6 个 / `.md` 2 个 / 共 8 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 6（严重 #1-#3 + 一般 `wildcard`、`findAll` 物化、`SOLID` 无界）；设计 1（builder 两套语义，已并入 #1）；可读性 3（`greedy` 命名、测试无断言、重复逻辑）；安全性 0（无凭据、无 SQL、无日志泄漏；`wildcard` 的输入未转义按“输入校验”计入正确性）。语言特性面（`StringGenerator` 引用共享、`Any` 装箱）已分别并入 #1 与优化方案，不另计，故合计 10 |
| §1 死代码 | 0 | 逐个 `private` 全仓搜：`pattern`（40+ 处）、`group_`（`:215`、`:221`、`:233`）、`mORn`（`:284`、`:289`、`:294`）、`append`（`:414`）、`CACHE` / `SOLID`、`flagstr`（`:43`）、`flagsstr`（`:51`）、`parts`、`RegexReplacement.format`（internal，被 `:101`、`:116` 使用）均有引用；`return` / `throw` 之后无同层语句；`import` 全部被用到（`std.convert.Parsable` → `Int64.parse`，`f_collection.*` → `ConcurrentHashMap.computeIfAbsent`）。`public` 且对外可达（`RegexBuilder` 及其全部成员、`ExtendRegex`、`RegexFromString`、`SearchDirection`、`RegexReplacement`、`RegexBuilderException`）一律不判；仓内零引用的 `prop notIn`、`Regex.builder(callback)`、三个 `doReplace*` 属对外契约，记为“文档未覆盖”（见 §14 行），不算死代码 |
| §2 重复逻辑 | 2 | 同文件两两比对：`RegexBuilder` 的 40+ 个 prop 视为刻意展开的 DSL token 表（仅字面量不同，合并会破坏 API 名称），不判重复；跨文件检索相同错误文案 / 正则 / 字面量：`greedy` / `notGreedy` 两段逐行相同且文案抄错（1 条）、`doReplaceAll` 两重载拼接循环逐行相同（1 条）；`INTEGER`/`DECIMAL`/`REAL_NUMBER` 等 7 个预置正则是不同语言，不是重复 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`、无 `throw UnsupportedException`；`RegexBuilderException.init() {}` 是无状态异常的合法空构造；`case _ => throw UnreachableException()`（`ExtendRegex.cj:182`）是显式兜底而非吞异常；`doReplace` / `doReplaceAll` 的无匹配分支返回原串，是契约行为 |
| §4 栈溢出 | 0 | 模块内无递归（无自调用、无相互调用，`group_` → `lparan` / `text` 都是平铺调用）；深度风险全部来自 `std.regex` 引擎的回溯，属运行时行为，已列待验证假设 #1，未作为发现 |
| §5 OOM | 2 | `SOLID` 无上限无 TTL（一般）；`doReplaceAll` 全量物化 `findAll`（一般）；无 `readToEnd`、无按报文字段预分配、无“循环内 `result = result + part`”（拼接都走 `StringGenerator`） |
| §6.1 热点瓶颈 | 0 | 本轮未提供该模块的 profile / bench 数据（`test2` / `test3` 只有 `println`，无对照、无中位数）；“键构造每次调用都做”“缓存条目量级”只是线索，已按格式写入待验证假设 #2 / #4 与优化方案，不参与统计（`findAll` 物化有确定的分配语义，已按 §5 报为缺陷，不在此列） |
| §6.2 大粒度锁 | 0 | 模块内无 `synchronized`、无 `Mutex`、无显式锁；`CACHE` 走 `HeapCache`（分段 `ConcHashMap`），`SOLID` 走 `ConcurrentHashMap.entryView`，无临界区内 I/O / 解析 |
| §6.3 并发串行 | 0 | 生产代码无 `spawn`、无 `Future.get`、无批处理队列；`test3` 的 20 线程仅用于计时，属测试代码 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`；`range` / `greedy` 是 O(1) 字符串追加；`wildcard` 的 6 次 `replace` 是 O(6n) 常数级，不构成算法问题（正确性另有发现） |
| §7 降堆内存方案 | 1 | `RegexReplacement` 的 `ArrayList<Any>` 装箱改 enum（无基线，待验证）；`doReplaceAll` 的全量物化因同时是缺陷（§5）不重复计方案 |
| §8 降 CPU 方案 | 1 | `regex()` 键构造（无基线，待验证）；`findAll` → 流式属缺陷修复，不重复计方案 |
| §9 local mode 可行性 | 0 | 模块内无函数内大临时对象：`RegexBuilder` 的 `StringGenerator` 逃逸为成员、`wildcard` 的中间串全部返回、`RegexReplacement` 逃逸为 struct 字段；真正的分配热点在 `std.regex` 的 C 侧，local mode 无法作用于 CFFI 分配，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 6 个源文件逐条核对边界 / 空值 / 错误处理 / 契约：逻辑反向 1、模板解析 1、契约与实现不符 3、输入未校验 1、缓存无界 1、全量物化 1、重复导致的行为漂移 1、测试缺口 1、命名与语义不符 1；已确认无缺陷的点：`flagsstr()` 的返回类型推断（key 确实带 flags）、`INTEGER`/`BASE64`/`DURATION` 等 7 个预置正则与注释一致、`doReplace` 的 `index` 偏移换算在 `[0, size]` 内正确、`equals` 的 `refEq` 短路正确 |
| §12 并发安全与锁粒度 | 1 | 共享路径逐条排查：`CACHE` / `SOLID` 均为线程安全容器（`HeapCache` 分段 + `computeIfAbsent` 单 key 原子，回调内只访问另一张表，无嵌套同表加锁 → 无死锁）；`RegexReplacement` 构造后只读。命中项是 `RegexBuilder`：内部 `StringGenerator` 可变且无同步，README 却承诺“可安全分叉复用”，按“会被多线程调用”判为共享可变状态无保护（并入严重 #1）；锁粒度维度无锁可谈 |
| §14 功能完备性与 README 覆盖 | 2 | 以 `src/` 公开声明逐项对照 README：`Regex.builder()` / `Regex.builder(callback)` 完全未文档化、`prop notIn` 与 `operator \|` 未列入清单（合并为同一条轻微 #8）；`fountain::fountain.regex` 别名包经核实存在（`src/regex/regex.cj:16` `public import fountain::f_regex.*`），README 该说法属实；根 README 已登记本模块；`cjpm.toml` 4 个依赖（`f_base` / `f_cache` / `f_collection` / `f_exception`）与源码 import 一致，版本 `1.3.2021` 与根工程及其他模块一致 |
| 文件覆盖（§13 等） | 8/8 | 无缺失文件；§13 命中 3 条（README 缺 `builder`、`solid` 说明相反、`RegexBuilder.cj:20-29` 头注释过期——最后一条并入严重 #1 作为证据） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷合计 11 条（严重 3 / 一般 3 / 轻微 5），全部为存量（快照模式无 diff 可比）；是否纳入修复待用户决定。

## 总评

模块很小（6 个源文件、816 行），但它是 `f_aspect`（切面匹配）、`f_bean`（`Wildcard` 条件）、`f_data`（校验、路径过滤）共用的正则基础设施，缺陷会直接表现为“路由选错”“校验放行/误拒”，不是纯工具层的瑕疵。

三条严重问题各自独立、都不需要运行就能确认：

1. **`range()` 的 min/max 条件写反**，一行代码、两个方向的错误（合法输入抛异常、非法输入产出坏正则），修起来最便宜，应立刻进修复清单。
2. **`RegexReplacement` 的 `$n` 模板解析不完整**，`replacement: "$1"` 直接输出字面 `1`，`"a$1b"` 还会吞掉 `b`。这是 `doReplace` / `doReplaceAll` 的默认替换语义，属于“公开契约承诺但实际不工作”，且失败是静默的（不抛异常、输出看起来像正常文本）。
3. **`RegexBuilder` 的可变 / 不可变语义混用**，README 承诺“每个调用返回新实例、可安全分叉”，实现是“大部分原地改、三个换新实例”，连 README 自己的 DSL 示例都因为 `oneOf` 丢掉了 `^`。这一条同时是正确性问题（前缀静默丢失）与并发问题（跨线程共享 builder 无同步），修法必须在“全不可变”和“全可变 + 改文档”之间选一个，不能再混。

一般项里，`wildcard` 是风险最外露的一条：`*` 只映射到 `\w*`、`?` 允许零字符、除 `.` 外的元字符全部泄漏，`wildcard("a(b")` 这种输入会让 `Regex()` 抛异常；而它的真实调用点是 `AspectRoute` 的切面选择。`SOLID` 无上限与 `findAll` 全量物化是两条内存面无界路径，前者影响面取决于下游是否把外部 pattern 传给 `solid: true`（仓内 `Validator.cj:271` 已有这种形态）。

代码质量上值得肯定的是：没有递归、没有锁、没有全局可变业务状态（两个缓存都是并发容器）、没有空实现与吞异常；`RegexFromString` 的双层缓存（进程级 + 一日 TTL）设计方向正确，只是缺一条容量约束。

文档层面是“承诺高于实现”：README 的 interface 代码块漏了 DSL 的唯一入口 `Regex.builder()`，却把 `RegexBuilder` 写成不可变值对象；`solid` 的说明与实现相反；源码头注释描述的是另一套 API（`digit_` / `{b=>}`）。建议随修复一起重写这几段——文档在这里不是补充材料，而是使用者判断“能不能分叉、能不能跨线程、能不能传外部 pattern”的唯一依据。

测试是最大空白：3 个用例里只有 1 个有断言，`$n` 替换、`wildcard`、`range`、`doReplace`、`oneOf` 全无覆盖，本报告 3 条严重缺陷因此全部漏网。补齐断言型用例的优先级应高于任何性能优化；两条优化方案（`RegexReplacement` 去装箱、`regex()` 键构造）均无改前基线，按规则只作待验证假设，不进修复清单。
