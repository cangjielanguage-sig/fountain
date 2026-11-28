# f_util 模块审查报告（第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（48 个源文件；本部分覆盖 15 个：`PathPattern` / `PathPattern_test` / `ResposibilityChain` / `StatePattern` / `StrategyPattern` / `TextTemplate` / `TextTemplateCacheKey_test` / `TreeTransformer` / `UInt128` / `Utils` / `code_buffer` / `crc16` / `crc32` / `crc32_codegen_test` / `crc32_hw_kind`）
- **基线**：工作区快照（`8c0ce643a`，`sts/1.3.x`，除 `docs/review/`、`reviews/` 两个未跟踪目录外工作区干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：路径匹配 / 文本模板 / 树变换 / UInt128 / 缓冲区的正确性与性能，死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part2`，最终由主 Agent 合并为 `docs/review/f_util_review_20261128.md`）

## 发现

### [严重][存量] PathPattern：回溯分支不推进状态，同深度路径多一级不匹配即无限循环

- **位置**：`f_util/src/PathPattern.cj:363-426`（`match (node.prev)` 的三个回退分支各做 `i -= 2`），根因在 `f_util/src/PathPattern.cj:259`（子节点命中时无条件 `prevPlaceholder = NonePathNode.INSTANCE`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（逻辑错误 / 循环不终止）+ §6.4（死循环等价于无穷复杂度）
- **证据**：静态确定 —— 设 pattern=`/{a}/x/y`、path=`/p/x/z`（两者 parts 长度都是 4）：`i=1` 占位符 `{a}` 匹配 `p`；`i=2` `getSub("x")` 命中并把 `prevPlaceholder` 重置为 `NonePathNode`（`:259`）；`i=3` 在 `x` 节点的全部候选（sub/regex/placeholder/star/**）都失败后进入 `case Some(n) where n is PlaceholderPathNode`（`:364`），执行 `i -= 2` ⇒ `i=1`，`node = a.prev`，随后 `:425 i++` ⇒ `i=2`；`i=2` 再次 `getSub("x")` 命中、再次重置 `prevPlaceholder`，`i=3` 再次进入同一分支。整条回路里没有任何变量单调变化（`prevPlaceholder` 的"已经试过该占位符"标记被 `:259` 清掉），因此**每轮都是同一状态，永久循环**。
- **描述**：只要路由存在"占位符后面跟两个及以上字面段"的形态（如 `/{id}/detail/info`），任何同深度但尾部不匹配的请求（例如 `/18/detail/other`，即最普通的 404 请求）就会让该请求线程 100% CPU 卡死、永不返回。该函数在 `data(path)`（`:466-468`，逐请求调用）与 `matches(path)` 的主路径上，`PathPattern` 又被 `f_mvc` 的 `HttpRequestDistributorImpl.getHandler` 每请求调用一次。
- **建议**：加"进展"守卫——记录 `(node, i)` 或"本层已尝试过的候选"，回溯若回到已访问过的 `(node, i)` 直接 `return None<T>`；或不要把 `prevPlaceholder` 的标记在 `getSub` 分支清空（只在实际前进一步时清），并补两条用例：`/{a}/x/y` vs `/p/x/z`（应 false）、`/{a}/x/y` vs `/p/x/y`（应 true）。

### [严重][存量] PathPattern：请求路径会写共享 `patterns`，读侧完全无锁 —— 数据竞争 + 按请求深度永久增长

- **位置**：`f_util/src/PathPattern.cj:242`（`get` 里 `getPathNode(len)`）、`:68-99`（`getPathNode` → `populateNode` → `synchronized(mutex)` 内 `patterns.add` / `patterns[len] = node`）、`:90`（`patterns.get(len)` 在锁外）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）+ §5（无界容器）
- **证据**：静态确定 —— `patterns` 是 `ArrayList<PathNode>`（`:49`），只有 `populateNode`（`:70-87`）与 `doCompile`（`:130-151`）在持有 `mutex` 时写它；而**匹配路径**上的 `get`（`:242`）→ `getPathNode`（`:90` 的 `patterns.get(len)`、`:142` 的 `node is NonePathNode`）全部在锁外读。当请求段数大于当前 `patterns.size`（比最长注册路由更深，任何深层 404 都满足）时，`:95-98` 会新建节点交给 `populateNode`，于是在**请求线程里**执行 `patterns.add(NonePathNode.INSTANCE)`。
- **描述**：两个并发访问者是"任意两个处理请求的线程"：A 线程在 `:90/:254-357` 遍历 `patterns[len]` 及其子节点 HashMap，B 线程在 `:72` 扩容 `patterns`（`std.collection.ArrayList` 非线程安全），二者之间没有任何同步手段。后果是读到旧/新数组的不同步状态、`get` 返回 `None` 后误判路由、以及两个线程同时为同一深度创建节点互相覆盖（`:77` 的 `patterns[len] = node` 会覆盖别人已 `compile` 好数据的节点例外——该分支只在 `size > len` 时走）。附带问题：`patterns` 随"见过的最大路径深度"永久增长（`NonePathNode` 每层一个），虽然上界受 URL 长度限制、非累积无界，但这是在读路径上泄漏常驻内存。
- **建议**：`patterns` 在"最后一次 `compile`"之后应冻结为只读快照（构造期生成完整数组，`getPathNode` 越界时不再扩容而是直接返回 `None`/一个共享的空节点）；若必须运行期扩容，读写都走同一把锁，或改为"不可变数组 + 原子替换引用"。补一条并发用例：1 线程注册 + N 线程同时请求不同深度路径。

### [严重][存量] computeBytes：`groupCount() >= 2` 恒真，纯数字与 `10b` 一律抛 "not supported byte unit"

- **位置**：`f_util/src/Utils.cj:29-33`（`if (matched.groupCount() >= 2) { ... return computeBytes(num, unit) } return num`）、`:36-57`（单位分支）
- **来源**：存量
- **判据**：review-checklist §11（恒真分支 / 读到的函数不可用）+ §1（不可达语句）
- **证据**：静态确定 —— std 文档 `regex_package_structs.html`（`MatchData.groupCount`：「获取捕获组的个数」，示例 `(?<year>)(?<month>)(?<day>)` → 3）表明 `groupCount` 数的是**捕获组个数**，与是否参与匹配无关；本正则 `^(\d+)([kmgtpezyKMGTPEZY]?)[bB]?$` 恒有 2 个捕获组，故 `:29` 条件恒真、`:33` 的 `return num` 永不执行。第二个捕获组可为空串，于是 `computeBytes("123")` → `computeBytes(123, "")` → 落到 `:57 throw IllegalArgumentException("not supported byte unit: ")`。同理 `"10b"`/`"10B"`：`b` 只能被 `[bB]?` 吃掉，unit 仍是 `""` ⇒ 同样抛异常。仓库内已有旁证：`fmq/src/config/MQConfig.cj:183-186` 注释写着"不用 `f_util.computeBytes`：该实现对单位分组的取值在本 SDK 上不稳定"，并另写了一份 `parseByteSize`。
- **描述**：一个 `Option<Int64>` 返回值的公开工具函数，对最常见的两种写法（无单位、`b` 单位）直接抛异常；对不匹配的输入（如 `"abc"`）在 `:27 find(...).getOrThrow()` 抛 `NoneValueException` 而不是 `None`；`n * 1024^7/^8`（`z`/`y` 单位）按 std 文档「默认情况下，出现溢出时会抛出异常」也会抛异常。调用方无法用 `Option` 判空，只能 try/catch。
- **建议**：改成 `let unit = matched.matchString(2)` 直接判空（空即无单位，`return num`）；把 `b/kb/mb…` 的多字单位分支删掉（正则永远不会产出多字单位）或改成 `([kmgtpezyKMGTPEZY]?)[bB]?` 语义下的单字母分支 + 溢出用 `CheckedOp` 返回 `None`；`find` 改 `Option` 直接返回 `None`。

### [一般][存量] PathPattern：`{id:\d{4}}` 的正则不补尾部锚点，5 位数字也会命中

- **位置**：`f_util/src/PathPattern.cj:826-833`（`if (!name.startsWith("^")) { prefix = "^" } else if (!name.endsWith("$")) { suffix = "$" }`）、`:860-862`（`reg.matches(name)`)
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性
- **证据**：静态确定 —— `else if` 使"补 `^`"与"补 `$`"互斥：`name` 不以 `^` 开头时只加 `^`，永不加 `$`，得到 `^(\d{4})`。std 文档 `Regex.matches` 的语义是「判断入参 input 与正则表达式**是否存在匹配**」（示例 `\d{4}-\d{2}-\d{2}` 对 `"2024-10-24&2025-01-01"` 返回 true），不是全串匹配。因此 `{id:\d{4}}` 对 `12345`、`1234abc` 均命中。
- **描述**：路径参数的正则约束被放宽成"前缀匹配"，`/{id:\d{4}}/detail` 会接受 `/{任意长度数字...}/detail`，进而把越界值交给 `extractParsableVariableInPath<Int64>` 之外的逻辑；`{#regex:\d+}` 同类问题（`testRegex` 只验证了 prefix 模式，掩盖了 exact 模式的过度匹配）。
- **建议**：`if/else if` 拆成两个独立判断（缺 `^` 补 `^`、缺 `$` 补 `$`），或在拼接时统一 `"^(${name})$"` 并用 `fullMatch` 语义；补负向用例 `matches("/12345")` → false。

### [一般][存量] ComplexPathNode：占位符后的字面后缀被丢弃，`{id}.json` 会匹配 `/x.txt`

- **位置**：`f_util/src/PathPattern.cj:890-897`（正则 `(.*?)\{(.+?)\}(.*?)` 只 `add` 了 `matchString(1)` 与 `matchString(2)`，第三个捕获组整段丢弃）、`:899-914`（`matches` 只校验首段 `startsWith` 与中间段的 `indexOf`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）+ §2（近似重复：`matches` 与 `extract` 各写了一遍分段遍历，两边都少一段）
- **证据**：静态确定 —— `{id}.json` 的 `parts = ["", "id"]`（group3 `.json` 未入表）；`matches("foo.txt")`：`i=0` 的 `staticPart` 是空串 ⇒ `startsWith("")` 为真、`pos=0`，循环结束即 `return true`。`extract("foo.txt")` 在 `:916-945` 用同样的 `parts`，`i+2 < parts.size` 为假 ⇒ `end = value.size`，返回 `{"id": "foo.txt"}`。
- **描述**：形如 `/{id}.json`、`/report/{date}.csv` 的路由会把任意扩展名（甚至任意内容）都匹配进来，并把整段（含后缀）当成变量值；`withExtName=false` 的调用还会先把 `.txt` 裁掉，使"后缀约束"看起来生效而实际不生效。`f_mvc` 的 `meta.path` 直接来自注解，写带后缀的路由是很自然的用法。
- **建议**：把 `matchString(3)` 也 `add` 进 `parts`（保持"静态段/变量段"交替），`matches` 末尾校验 `value.endsWith(最后一个静态段)`；`extract` 与 `matches` 合并成一次扫描，避免两套分段逻辑再次漂移。

### [一般][存量] TextTemplate：number 占位符的空值分支把 `noneConverter` 丢弃，空串继续走 `Decimal.parse` 抛异常

- **位置**：`f_util/src/TextTemplate.cj:406-410`（`if (value.isEmpty()) { noneConverter }`）
- **来源**：存量
- **判据**：review-checklist §11（读取了不用的值 / 错误路径缺失）+ §3（静默分支）
- **证据**：静态确定 —— `noneConverter` 是 `?String`，该 `if` 无 `return`，表达式值被丢弃；下一行 `Decimal.parse(value)` 对空串必然失败（`Decimal.parse` 的入参要求合法数字串）。同文件 `:302-308`（`Value2TimeString`）用的是 `extractNoneConverter()`，说明这里是漏写。
- **描述**：`formatString`/`formatNumber` 里字段值为空串时，本应输出 `noneConverter`（如 `"-"`），实际抛 `IllegalArgumentException`（或 Decimal 的解析异常），把"可空字段"变成运行时崩溃；`f_log` 的 `{}` 日志格式化正好会碰到空值字段。
- **建议**：改成 `if (value.isEmpty()) { return noneConverter.getOrThrow() }`（或 `noneConverter ?? "0"`，但要与 `Value2TimeString` 保持同一口径），并把 `.getOrThrow()` 的异常换成 `TextTemplateException` 以保持错误族一致。

### [一般][存量] TextTemplate：o/O/x/X 进制分支三处错 —— 丢负号、宽度补齐差、大写不生效

- **位置**：`f_util/src/TextTemplate.cj:443-448`（`BigInt(true, number.reScale(0, …).toBigInt().toBytes())`、`"${prefix}${0 * (integer - 1)}${string}"`）、`:344-347`（`prefix = "0" + formatter[0..1]` 后判断 `prefix[0] == b'X'`）
- **来源**：存量
- **判据**：review-checklist §11（数据错误）+ §2（十进制分支有 `upperCase`/`prefixPlus`/括号处理，进制分支整段缺失）
- **证据**：静态确定 —— ① std 文档 `BigInt(sign:magnitude:)`：「`sign` 为 true 表示非负数…`magnitude` 是真值**绝对值的二进制原码**」，而 `BigInt.toBytes()` 返回「大端**补码**」；`BigInt(true, (-1).toBytes())` = `BigInt(true, [255])` = **+255**，符号与真值都错；② 补齐用 `integer - 1` 而十进制分支用 `integer - l`，值 `255` 配 `x####` 会补成 5 位；③ `prefix` 恒为 `"0"+char`，`prefix[0]` 恒为 `'0'`，`upperCase` 永不置位，且进制分支 `:442-449` 直接 `return`，即使置位也不会 `toAsciiUpper()`。
- **描述**：`{n:x###}`、`{n:O##}` 这类占位符对负数输出错误的正数（金额/哈希/掩码格式化会静默给出错值），大写 `X`/`O` 与宽度约束都不生效。该分支没有任何测试（模块内只有 `TextTemplateCacheKey_test.cj`）。
- **建议**：改用 `number.reScale(0, mode).toBigInt()` 直接 `toString(radix:)` 并在外层处理符号；补齐用 `integer - l`；`upperCase` 判定改成 `formatter[0] == b'X' || formatter[0] == b'O'`，进制分支末尾同样走 `:433-441` 的 `upperCase`/`prefixPlus`/括号逻辑。

### [一般][存量] TextTemplate：格式串转义识别用 `template` 的下标去索引 `placeholder` 子串

- **位置**：`f_util/src/TextTemplate.cj:151-153`（number：`template[formatEnd - 1] == b'\\'` 与 `template.indexOf("`", …)`）、`:172-174`（time 同构）
- **来源**：存量
- **判据**：review-checklist §11（索引对象错位）+ §2（两段同构代码一起错）
- **证据**：静态确定 —— `formatEnd` 是相对 `placeholder`（`template[start..end]`）的下标，却拿去索引 `template`：`template[formatEnd-1]` 取的是模板开头附近的字符，`template.indexOf("`", formatEnd+1)` 也是从模板绝对位置继续找。只要 `start != 0`（几乎总是），反引号转义判定就落在错误位置。
- **描述**：`{n:number:`##,##\``}` 这类含转义反引号的格式串会被截断/误判——要么提前结束格式，要么把后半段当成变量名，最终报"time format must be followed…"（错误文案也是从 time 分支复制过来的，`:157`）。当前无任何测试覆盖。
- **建议**：两处都改成 `placeholder[...]` / `placeholder.indexOf(...)`，并与 time 分支合并成一个 `parseBacktickFormat(source, tag)` 帮助函数（消除重复）；错误文案按 tag 区分。

### [一般][存量] TextTemplate：`noneConverter` 契约只在 time/number 生效，plain 变量缺失直接抛异常（与 README 承诺相反）

- **位置**：`f_util/src/TextTemplate.cj:290-296`（`Value2PlainString.doFormat` 完全忽略 `noneConverter`）、`:241-253`（`ValueGetter.get` 缺字段时抛 `TextTemplateException`），契约在 `f_util/README.md:461-462`（"如果不存在相应的模板变量则使用noneConverter"）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现）+ §13（文档与实现不符）
- **证据**：静态确定 —— 三个 `doFormat` 里只有 `Value2TimeString`（`:302-316`）与 `Value2NumberString`（`:407`，且本身有缺陷）读了 `noneConverter`；`Value2PlainString` 只做 `getter.get(...).toString()`，字段不存在时由 `:249` 抛异常。
- **描述**：README 是 `f_log`/下游使用者的唯一契约说明，"缺失用 `noneConverter`"是最常被依赖的行为；实际只有带 `time:`/`number:` 的占位符才会降级，普通 `{field}` 缺字段直接抛异常，把日志格式化变成异常源。
- **建议**：`Value2PlainString` 也用 `noneConverter` 兜底（`data` 里取不到 key 时返回 `noneConverter`，为 `None` 再抛），或把 README 改成"仅 time/number 支持 noneConverter"并说明 plain 缺字段抛异常。

### [一般][存量] UInt128.fromBytes：构造了 HashException 却没 throw，长度 ≠ 16 静默产出错误值

- **位置**：`f_util/src/UInt128.cj:59-62`（`if (bytes.size != 16) { HashException(...) }`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 静默错误值）+ §3（构造即丢弃）
- **证据**：静态确定 —— 该语句只是构造对象后丢弃，没有 `throw`；随后 `for (i in 0..bytes.size)` 照常拼装。`bytes.size < 16` 时高位左移（`UInt64(bytes[i]) << ((7-i)*8)`）把 1 字节当成最高字节，例如 `tryParse("abcd")` 由 `fromHexString` 得到 2 字节，`fromBytes` 返回 `0xabcd0000…0000` 而**不是** `None`；`bytes.size > 16` 时 `(15 - i) * 8` 变负，`UInt64(负数)`/移位属于非法操作（std 文档：移位位数超位宽抛 `OvershiftException`）。
- **描述**：`UInt128 <: Parsable & DataParsable`，这是从 JSON/字符串反序列化 128 位哈希（`murmur`、类型指纹）的唯一入口；长度非法的输入不会报错，而是得到一个"看着像哈希"的错误值，后续 `typeMurmurCreators.get(murmur)` 查不到才报"类型未注册"，把输入错误伪装成注册缺失。`f_codec` 的二进制路径（`DefaultCodec.cj:960`）固定读 16 字节，暂不受影响。
- **建议**：`throw HashException(...)`；并把循环改为只处理前 16 字节（或先判长度再进循环），补 `tryParse("abcd") == None` 的用例（当前 `UInt128` 无任何测试）。

### [一般][存量] TreeTransformer：父节点缺失时抛 `NoneValueException`，不是领域异常

- **位置**：`f_util/src/TreeTransformer.cj:58`（`map[parentId].addChild(t)`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 契约与实现不符）
- **证据**：静态确定 —— `map[parentId]` 是 `HashMap` 的下标取值，key 不存在时抛 `NoneValueException`（同文件前面两处失败路径都用了带说明的 `IllegalArgumentException`：`:44-46`、`:49-51`）。
- **描述**：`parentId` 指向不存在的节点（脏数据、跨页查询只取到子节点）时报 `NoneValueException`，无 `id`、无消息，调用方无法区分"数据不完整"与"内部错误"；同一个函数的三条失败路径用了两种异常族。
- **建议**：改 `match (map.get(parentId)) { case Some(p) => p.addChild(t); case _ => throw IllegalArgumentException("parent ${parentId} of node ${t.id} is not in the transformed set") }`，或在文档里声明"孤儿节点被丢弃"。

### [一般][存量] State：`continues` 默认 true 且无深度/环检测，自引用状态直接栈溢出

- **位置**：`f_util/src/StatePattern.cj:27-31`（`prop continues` 默认 `true`）、`:43-52`（`startup<D>()` 内 `this.exec().startup()` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归）+ §11（默认值导致契约反转）
- **证据**：静态确定 —— `startup` 的唯一出口是 `continues == false`；`continues` 默认 true，实现类只要忘记覆盖（或 `exec` 链成环、返回自身）就无限递归，直到栈耗尽。递归深度由实现类的状态链长度决定，代码里没有计数、没有 visited 集合。另外 `startup<D>(): D` 用方法级泛型 `D` **遮蔽**了接口的 `State<D>` 数据参数，`startup<Int64>()` 可以在 `State<String>` 上编译通过、运行期才在 `:49` 抛 `IllegalStateException`。
- **描述**：这是一个纯约定式的状态机骨架，两个"默认值/泛型"问题都会在实现方犯小错时变成崩溃而非编译错误；仓内目前没有任何 `State` 实现（`grep ': State'` 仅命中 JDBC `Statement`）。
- **建议**：`continues` 默认改为 `false`（默认不继续更安全）；`startup` 加 `depth` 上限或 `HashSet<State>` 环检测并在超限时抛 `IllegalStateException`；`startup` 的泛型参数改名为 `R` 并加 `where R <: D` 之类的约束（或直接返回 `D`、去掉方法级泛型）。

### [一般][存量] TextTemplate：静态模板缓存无容量上限，`f_log` 每次带参日志都以消息串为 key 查一次

- **位置**：`f_util/src/TextTemplate.cj:54`（`private static let templates = ConcurrentHashMap<String, TextTemplate>()`）、`:65-75`（`compile` 只 `computeIfAbsent`，无淘汰）、`:80-82`（key = `前缀长度:前缀后缀长度:后缀模板`）
- **来源**：存量
- **判据**：review-checklist §5（缓存键无界：没有容量、TTL、淘汰）+ §7
- **证据**：静态确定（无上限、无淘汰）；触发面待确认 —— 生产消费点 `f_log/src/base/Logger.cj:51/72/95/114/133/152` 每次 `append(level, message, args)` 都无条件 `TextTemplate.compile(message, prefix:"{", suffix:"}")`（不像 `f_llm` 那样先判 `contains`），`f_llm/src/agents/AgentTask.cj:232` 也以整段 prompt 为 key。只要调用方传入的消息串/模板串里含有运行时数据（含 `{}` 的 JSON 片段、拼进去的路径），key 就逐条唯一。
- **描述**：缓存项包含 key 串（模板原文）+ `compiled` 里若干切段字符串（又一份原文）+ 对象头，单条约 2×模板长度；条目永不回收，容量与"历史上出现过的不同模板串"同阶，属于长期只增不减的全局容器（`mem §4.1`）。
- **建议**：加容量上限 + LRU（或按 `f_cache` 的策略），超限退化为"不缓存直接编译"；`f_log` 侧对不含 `{` 的消息直接跳过 `compile`（省一次 key 构造 + 哈希），并在 README 写明"模板应是静态字面量"。

### [轻微][存量] 死代码集合：未使用的构造重载 / 成员 / import

- **位置**：`f_util/src/PathPattern.cj:522-536`（`PathNode` 的 `init(name,prev,star,doubleStar)`、`(…,end)`、`(…,data)`、`(name,prev,end)`、`(name,prev,data)` 五个重载全无调用者）、`:731`（`PathNode.data(data: Any): Unit` 无调用者）；`f_util/src/TextTemplate.cj:55`（`private static let mutex` 零引用）、`:237-239`（`ValueGetter.init(indexText:)` 零引用）、`:18`（`Map` 未使用）；`f_util/src/StatePattern.cj:19`（`TypeInfos` 未使用）；`f_util/src/StrategyPattern.cj:18`（`ArrayList` 未使用）
- **来源**：存量
- **判据**：review-checklist §1（非 public 符号 / 未使用 import）
- **证据**：静态确定 —— 全 `f_util` 包内 `PathNode(` 只出现在 `:92/:96/:143` 的三处零参构造与子类的 `super(...)`；`PathNode.data(` / `mutex` / `indexText:` / `TypeInfos` / 单独 `ArrayList` 在包内零命中（`PathNode` 是内部 `open class`，成员 `public`/默认可见性也只到包内，按硬原则二判死代码）。`PathNode` 的 `data<T>()`（`:740`）有使用者，不要一起删。
- **描述**：五个构造重载是"预留扩展点"的残留（`starNode`/`doubleStarNode`/`data` 其实都由 `createXxxIfAbsent` 与 `setDataIfNone` 完成），读代码时会误以为存在另一种构造路径。
- **建议**：删除五个未用重载与 `PathNode.data(Any)`、`TextTemplate.mutex`、`ValueGetter.init(indexText:)`、三处未用 import。

### [轻微][存量] `PathNode.!=` 与 `PathNode.==` 语义不一致，违反 `Equatable` 契约

- **位置**：`f_util/src/PathPattern.cj:761-766`（`==` 为 `refEq || name ==`；`!=` 为 `name != node.name`），覆盖实现见 `:746-760`、`:793-802`、`:809-818`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符 / 接口契约）
- **证据**：静态确定 —— `StarPathNode.==(Any)` 对任意 `PathNode` 返回 true（`:797` 的 `o is PathNode`），而 `!=` 只比 `name`；因此"星号节点 vs 普通节点"会出现 `a == b` 与 `a != b` **同时为 true**。`getComplexNode`（`:570`）与 `getRegexPlaceholderNode`（`:597`）正是用 `current != node` 决定"跳过已试过的候选"，语义矛盾会直接改变候选推进顺序。
- **建议**：`!=` 改为 `!(this == node)`；`==(Any)` 的通配语义移到具名方法（如 `accepts(o)`），不要借用 `==`。

### [轻微][存量] code_buffer：`rawPointer()` 两个分支完全相同，且与 `f_jit` 的 `CodeBuffer` 是同一实现的第二份

- **位置**：`f_util/src/code_buffer.cj:61-67`（`if (sealed) { ptr } else { ptr }`）、`:18-24`（注释自述"与 f_jit 的 `CodeBuffer` 同一模式"）
- **来源**：存量
- **判据**：review-checklist §1（恒等分支）+ §2（重复逻辑：跨模块复制）
- **证据**：静态确定 —— 两个分支返回值逐字相同；`f_jit/src/backend/CodeBuffer.cj:68` 存在同名 `rawPointer()` 与同一套 `mmap` → `mprotect` → `__clear_cache` 流程（`f_jit` 版本为 `public class`，`f_util` 版本为包内 `class`）。
- **描述**：`sealed` 判断在 `rawPointer` 里没有任何作用，读者会以为密封后指针语义不同；两份 W^X 可执行页实现意味着 `mprotect`/`__clear_cache` 的平台细节要改两处（`f_jit` 版本超出本部分范围，仅作提示）。
- **建议**：`rawPointer()` 直接 `return ptr`；把可执行页分配收敛到 `f_util`（依赖方向正确：`f_jit` → `f_util`）或至少在两个文件里互相引用说明"改动需同步"。

### [轻微][存量] crc32_hw_kind：手写 `==`/`!=` 与枚举默认结构相等重复

- **位置**：`f_util/src/crc32_hw_kind.cj:24-43`
- **来源**：存量
- **判据**：review-checklist §2（只改语法的重复实现）
- **证据**：静态确定 —— 三个 case 的嵌套 `match` 等价于枚举按值比较，且 `!=` 又写成 `!(this == other)`；同文件 `Crc32.classifyHw`（`crc32.cj:80-92`）已经在做同样的三值分类。
- **描述**：这段代码唯一作用是满足 `Equatable<CrcHwKind>`，但 `::` 枚举本身已具备值相等；手写版本在新增 case（如将来的 `Crc32cArm`）时会静默落到 `_ => false`。
- **建议**：删除两个手写运算符（依赖枚举默认相等），或改成 `match ((this, other))` 的单层写法。

### [轻微][存量] ResponsibilityChain / Strategies：注册表为非并发容器且未声明线程约束

- **位置**：`f_util/src/ResposibilityChain.cj:45`（`ArrayList`）、`:56-64`（`register` 写入）、`:70-82`（`execute`/`executeAll` 遍历）；`f_util/src/StrategyPattern.cj:42`（`HashMap`）、`:46-54`、`:59-64`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）+ §10（契约声明缺失）
- **证据**：待确认 —— 代码无锁、无 `Concurrent*`、类注释也未声明"仅启动期注册"；仓内除定义外零引用（`grep 'Strategies<'`、`': Responsibility<'` 均只命中 `f_util`），实际并发使用点无法确认。同模块 `Factory`/`Mediator` 的同类问题已在 part1 报过（同一根因）。
- **描述**：`Strategies.execute` 遍历 `HashMap` 时若另一线程 `register`，`std.collection.HashMap` 无同步保证，可能读到扩容中的桶数组。
- **建议**：类注释明确"注册只在启动期，之后只读"，并在 `register` 时用一个 `frozen` 标志拒绝运行期写入；或换 `ConcurrentHashMap` / 不可变快照原子替换。

### [轻微][存量] TextTemplate：`time:` 与 `number:` 两段格式串解析逐行同构（同一条错误文案）

- **位置**：`f_util/src/TextTemplate.cj:143-186`（`:145-167` 与 `:168-186` 两段）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 字面量复制的重复逻辑）
- **证据**：静态确定 —— 两段都是"定位 `` ` `` → 跳过首个反引号 → 找闭合反引号 → 处理 `\`` 转义 → 校验 → trim → 切掉格式部分"，差异只有前缀常量和 `Value2TimeString`/`Value2NumberString` 两种产出；`:157` 的 number 分支直接复用了 time 的错误文案 "time format must be followed 'time:'"。
- **描述**：两段代码已经出现行为漂移（time 分支对 `format` 做了 `.regex().replaceAll("`", "\\`")`，number 分支没有），且同一条转义 bug 被复制了两份（见上文"索引对象错位"）。
- **建议**：抽 `parseTaggedFormat(placeholder, tag): ?(String, String)` 返回 `(变量名, 格式串)`，两个分支只保留"构造哪个 converter"的差异。

### [轻微][存量] crc32_codegen_test：软件路径抛异常时不恢复全局 `setNativeEnabled`

- **位置**：`f_util/src/crc32_codegen_test.cj:64-69`、`:149-156`（`setNativeEnabled(false)` → `compute` → `setNativeEnabled(true)`，中间无 `try/finally`）
- **来源**：存量
- **判据**：review-checklist §11（资源/状态不对称释放）
- **证据**：静态确定 —— 若 `Crc32.xxx.compute` 在软件路径上抛异常，`:68`/`:154` 的恢复语句被跳过，后续用例（`:73`、`:110`、`:189`）会在"硬件已禁用"的状态下运行并误报 SKIP/失败。同文件 `:207-212` 的写法是正确的（`try { … } finally { … }`），说明这是遗漏。
- **建议**：两处都改成 `try { … } finally { Crc32Hw.setNativeEnabled(true) }`。

### [轻微][存量] ValidationResponsibility：接口给了空 `execute` 默认实现，且没有一行注释说明

- **位置**：`f_util/src/ResposibilityChain.cj:40-42`
- **来源**：存量
- **判据**：review-checklist §3（接口默认空实现 / 有意的 no-op 必须有注释）
- **证据**：静态确定 —— `ValidationResponsibility<C, A> <: Responsibility<C, A, Unit>` 里 `func execute(arg: A): Unit {}` 是空实现；仓内零实现者（`grep 'ValidationResponsibility'` 只命中定义处），无法从调用方推断语义。
- **描述**：若实现类只写了 `check` 而忘记 `execute`，`ResponsibilityChain.executeAll` 会"检查通过但什么也不做"——校验链静默失效，属于最难定位的一类缺陷；如果这是刻意的 Null Object（校验器只在 `check` 里做判断），按清单也必须写明"为什么可以空"。
- **建议**：补注释"校验责任链只用 `check` 判定，`execute` 允许空"；或干脆去掉这个默认实现，让实现类显式写 `execute`（编译期强制表态）。

### [轻微][存量] TreeTransformer：两个 `transform` 重载把算出的根节点列表直接丢弃

- **位置**：`f_util/src/TreeTransformer.cj:66-71`（`transform<S>(iterable, emptyId)` 与 `transform<S>(iterable, emptyId, ignoreDuplicate)` 返回 `Unit`）
- **来源**：存量
- **判据**：review-checklist §11（读了不用 / 返回值丢弃）
- **证据**：静态确定 —— 两个重载都在末尾调用另一个返回 `ArrayList<T>` 的重载，表达式值未被使用，调用方拿不到根集合；父子关系已经写进各节点的 `children`，但根节点只能靠"自己再扫一遍 `parentId == emptyId`"找回。
- **描述**：三个同名重载里两个丢结果、一个返回结果，选择重载就等于无声地改变可用信息；且这两个重载的返回值类型是 `Unit`，将来想改成 `ArrayList<T>` 是破坏性变更。
- **建议**：统一返回 `ArrayList<T>`（丢弃调用方忽略返回值即可），或删掉这两个重载只留显式版本。

### [轻微][存量] PathPattern：`matches()` 与 `data()` 的 `withExtName` 默认值相反，且与注释"不包含扩展名"矛盾

- **位置**：`f_util/src/PathPattern.cj:434-441`（`matches(path)` 转调 `matches(path, true)`）、`:457-468`（`data<T>(path)` 转调 `data(path, false)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符 / 两个同族 API 口径相反）
- **证据**：静态确定 —— 两处 KDoc 都写着"不包含路径中的扩展名"，但 `matches` 默认**保留**扩展名（`withExtName=true`）、`data` 默认**裁掉**扩展名；对同一 pattern 与 path，`matches("/api/user.json")` 与 `data<HttpRequestHandler>("/api/user.json").isSome()` 可能给出相反结论。
- **描述**：`f_mvc` 的 `getHandler` 走 `data()`（裁扩展名），`extractVariableInPath` 也裁扩展名，只有 `matches()`/`matchesPrefix()`（仓内零生产引用）保留；使用者按注释理解会得到反直觉结果，且"同一路径能否命中"取决于调的是哪个 API。
- **建议**：统一默认值（建议都按注释"不包含扩展名"取 `false`），或把参数改成必填并在 KDoc 里写清两种口径的差异；删掉 `matches*` 或与 `data` 合并为一个返回 `Option` 的入口。

### [轻微][存量] PathPattern：三个编译入口对路径规整与 `{*var}` 预处理不一致

- **位置**：`f_util/src/PathPattern.cj:101-103`（`compile(pattern)`）、`:124-127`（`compile(pattern, data)`）、`:153-156`（`compileIfAbsent` 走 `pretreat`）；`pretreat` 见 `:114-122`
- **来源**：存量
- **判据**：review-checklist §14.1（同一能力两个入口行为不一致）+ §10（可维护性）
- **证据**：静态确定 —— 只有 `compileIfAbsent` 调 `pretreat`（合并 `///`、把 `/{*name}` 改写成 `/**/{name}`）；`compile(pattern)` / `compile<T>(pattern, data)` 直接用原始串 `parts(pattern, true)`。而查询侧 `get`（`:478`）对**请求路径**无条件 `trimRedundantSlash`，注册侧不规整 ⇒ 用 `compile` 注册 `"//a"` 的 pattern 永远匹配不到。
- **描述**：类注释把 `{*...}`、连续 `/` 合并列为路径语法的正式特性（文档第 (g) 条与"多个连续的/合并成一个"），但只有生产并不使用的入口实现了它；`f_mvc` 只用 `compileIfAbsent`，所以线上暂时只暴露"注册侧不规整"的风险。
- **建议**：`pretreat` + `trimRedundantSlash` 移到 `doCompile` 入口统一做（只做一次），三个公开入口共享同一套规整逻辑。

## 优化可行性方案

> 以下均无改前基线，只作为"待验证"方案，不进 `tasks.md`。

### [堆内存] TextTemplate 静态缓存加容量上限与淘汰

- **现状**：`templates` 保存 `key(模板原文) → TextTemplate(compiled: ArrayList<Value2String>)`，一条缓存项≈2×模板长度 + 切段对象（每段一个 `OriginValue2String` + 一个 `ValueGetter`），生命周期 = 进程生命周期；条目数与"出现过的不同模板串"同阶。
- **方案**：改为有界 LRU（如 4096 条 / 8 MiB 估算上限），超限按最久未用淘汰；或对超长模板（>4 KiB）不缓存。
- **预期**：把"只增不减"变成有界稳态（`getAllocatedHeapSize()` 在长跑后回落）；定性收益，无量化数据。
- **代价**：淘汰后重复编译（一次模板解析 + 若干正则/Escape 处理），需要在缓存命中率上取平衡；`f_log` 热路径会更多走"未命中→编译"。
- **验证**：`cjpm test -O2` 跑 f_util 全部用例；另做 30 分钟稳态日志压测，采 `getAllocatedHeapSize()` 与 `templates.size` 埋点。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] f_log 每行日志都对模板串做一次 cacheKey 拼接 + 一次 HashMap 查找

- **现状**：`f_log/src/base/Logger.cj:51/72/95/114/133/152` 每次带参数的日志都会调用 `TextTemplate.compile(message, prefix:"{", suffix:"}")`；`compile`（`TextTemplate.cj:69-70`）先 `cacheKey` 做 4 次字符串拼接 + 2 次 `Int64.toString`（`:81`），再按整串 key 做哈希与比较。输入规模 = 每日日志行数。
- **方案**：① `f_log` 侧先用 `message.contains("{")` 快速短路（不含占位符直接输出原文），省掉 key 构造与哈希；② `cacheKey` 在 `prefix/suffix` 为默认值时退化为直接以 `template` 为 key（另一个 map 或加前缀标记），避免每次分配新串；③ 若仍偏贵，把"模板 → TextTemplate"的解析结果挂到调用点的静态变量（宏/`lazy`）而不是查全局表。
- **预期**：每行日志减少 2 次小串分配 + 1 次整串哈希（待实测占比，未测）。
- **代价**：`f_log` 与 `f_util` 各改一处；② 需要保证两种 key 不互相碰撞（当前实现已用长度前缀，改造时要保持）。
- **验证**：`cjpm bench -O2` 对同一模板 1e6 次 `compile+format`，对照中位数与 `getAllocatedHeapSize()`；再用 10 万行/秒的日志压测看 CPU 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] PathPattern 每请求两次 `trimRedundantSlash` + 一次 `split` + 多次子串分配

- **现状**：`data(path)`（`:466`）→ `get`（`:477-479`）先 `trimRedundantSlash`（内部 `replace("//","/")` 再判首尾），再 `parts()` → `trimExt` + `split("/")`，随后逐段在若干 `HashMap` 与线性集合里查找（`:553-640`，`getComplexNode`/`getRegexNode`/`getPlaceholderNode` 都是 O(候选数) 顺序扫描）。每个请求至少 3 个新字符串 + 1 个 `Array<String>`。
- **方案**：请求侧改为"按 `/` 单趟扫描 + 记录区间下标"，在 `get` 内直接对原串切片比较，不再物化 `Array<String>`；对同一 `len` 把 `getComplexNode` 的候选预先编译成有序列表，避免每段遍历 `HashMap.values()`。
- **预期**：每请求分配从 O(段数) 个串降到 1 个；匹配耗时随段数线性但常数更小（未测）。
- **代价**：`parts` 被 `extractVariablesInPath`、`compile` 复用，改造要保留"按下标取变量值"的能力；需要现有 33 个 `PathPattern_test` 用例全绿做等价性门槛。
- **验证**：`cjpm bench -O2`，注册 200 条路由、请求 10 万次（命中/未命中各半），对照 P50/P99 与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `data()` 的路由匹配是 HTTP 请求主路径上的可观开销（段数 5~8、路由 200+） | `f_util/src/PathPattern.cj:242-432` | 自耗时占比 | 对 f_mvc 压测接口跑 `cjprof record`，看 `PathPattern.get*` 的 self time 与样本数 |
| 2 | 日志路径上 `cacheKey` 的字符串拼接 + 哈希占 `append` 的可观比例 | `f_util/src/TextTemplate.cj:80-82` | 每行日志的分配字节与 CPU 占比 | 10 万行/秒压测 + `cjprof`，对照"含 `{` / 不含 `{`"两种消息 |
| 3 | `TextTemplate.templates` 在真实负载下条目数持续增长（而非收敛到静态模板数） | `f_util/src/TextTemplate.cj:54` | 条目数随时间的曲线 | 加 `templates.size` 埋点，跑 30 分钟稳态业务流量 |
| 4 | `UInt128.toString()`（`toBytes` 每次分配 16 B 数组 + `toHexString`）在类型注册表键计算里是热点 | `f_util/src/UInt128.cj:29-31`、`f_codec/src/default/DefaultCodec.cj:46` | 调用次数与占比 | 对 f_codec 编解码基准跑 `cjprof`，统计 `UInt128.toBytes` 样本占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/PathPattern.cj` | .cj | ✅ | 见「发现」严重×2、一般×2、轻微×3；`get` 回溯死循环与读路径写共享状态是本部分最高风险 |
| 2 | `f_util/src/PathPattern_test.cj` | .cj | ✅ | 33 个用例覆盖面好（通配/双星/占位符/正则/复杂段），但缺负向用例：`{id:\d{4}}` 的过度匹配、同深度多余一段的回溯死循环、带后缀复杂段 |
| 3 | `f_util/src/ResposibilityChain.cj` | .cj | ✅ | 见 §3 轻微（`ValidationResponsibility.execute` 默认空实现无注释）、§12 轻微（注册表非并发） |
| 4 | `f_util/src/StatePattern.cj` | .cj | ✅ | 见 §4 一般（默认 `continues=true` + 递归无守卫 + 泛型遮蔽）；仓内零实现者 |
| 5 | `f_util/src/StrategyPattern.cj` | .cj | ✅ | 见 §12 轻微；`ArrayList` 未使用 import |
| 6 | `f_util/src/TextTemplate.cj` | .cj | ✅ | 见「发现」一般×5、轻微×1（time/number 解析重复）；`time:`/`number:` 两段解析无任何测试 |
| 7 | `f_util/src/TextTemplateCacheKey_test.cj` | .cj | ✅ | 5 个用例只覆盖缓存键隔离，覆盖到 `{`/`${`/`#` 三种分隔符；未覆盖注释里提到的"长度前缀防碰撞"边界（`a`+`bc` vs `ab`+`c`） |
| 8 | `f_util/src/TreeTransformer.cj` | .cj | ✅ | 见 §11 一般（孤儿抛 `NoneValueException`）、轻微（`transform` 两个重载丢弃根） |
| 9 | `f_util/src/UInt128.cj` | .cj | ✅ | 见 §11 一般（长度不校验）；无测试文件 |
| 10 | `f_util/src/Utils.cj` | .cj | ✅ | 见「发现」严重（`computeBytes` 恒真分支）；无测试文件 |
| 11 | `f_util/src/code_buffer.cj` | .cj | ✅ | 见「发现」轻微（`rawPointer` 恒等分支）、§2 轻微（与 f_jit 重复）；`mmap/mprotect/__clear_cache` 的失败路径都返回 `None/false`，回退契约清楚 |
| 12 | `f_util/src/crc16.cj` | .cj | ✅ | 24 个变体参数与 RevEng 检查值自洽（检查值由 `crc_check_test.cj` 兜底，不在本部分）；无死代码 |
| 13 | `f_util/src/crc32.cj` | .cj | ✅ | 11 个变体齐全；`update` 的硬件/软件分层与 16 字节对齐注释一致；无死代码 |
| 14 | `f_util/src/crc32_codegen_test.cj` | .cj | ✅ | 见 §11 轻微（两处全局开关未用 try/finally）；用例设计好（对拍软件路径、覆盖非对齐长度、并发 4×1000） |
| 15 | `f_util/src/crc32_hw_kind.cj` | .cj | ✅ | 见 §2 轻微（手写枚举相等） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分未分配 `.md`；README 仅作契约取证，正式审查归其它部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 16 | 正确性 10（PathPattern 死循环/正则未锚定/复杂段丢后缀/扩展名默认值、computeBytes、UInt128、TextTemplate 空值/进制/索引错位、TreeTransformer 孤儿）；设计 3（三个编译入口不统一、Pattern 类 Equatable 契约、noneConverter 契约面）；语言特性 2（`match(node.prev)` 用 `!=` 推进、`var` 可改 `let`：`RegexPathNode.reg`）；可读性 1（`get` 209 行单函数 + 航天飞机模式注释自认难读）；安全性 0（无凭据、无注入面；路径匹配的过度匹配归正确性） |
| §1 死代码 | 4 | 已逐个 `private` 全仓搜、`internal`/包内成员在 `f_util` 包内搜：① 5 个未用 `PathNode` 构造重载；② `PathNode.data(Any)`；③ `TextTemplate.mutex`、`ValueGetter.init(indexText:)`；④ 未用 import `Map`(TextTemplate) / `TypeInfos`(StatePattern) / `ArrayList`(StrategyPattern)。`public` 成员（`PathPattern` 的 `matches*`/`dataByPrefix`/`extract*`、`Strategies`/`ResponsibilityChain`/`State`/`TreeTransformer`）对外可达，仓内零引用不判死代码；`extend Option<PathNode>.matches` 被 `getComplexNode` 使用，不是死代码 |
| §2 重复逻辑 | 4 | ① `TextTemplate` 的 `time:`/`number:` 两段解析同构（含同一条错误文案）；② `code_buffer.cj` 与 `f_jit/src/backend/CodeBuffer.cj` 同一套 W^X 页管理；③ `CrcHwKind` 手写相等 vs 枚举默认相等；④ `Utils.computeBytes` 与 `fmq/src/config/MQConfig.cj:183+` 的 `parseByteSize`（下游因缺陷自建）。`crc16/crc32` 的变体表是数据不是逻辑，不判 |
| §3 空实现 | 1 | `ValidationResponsibility.execute(arg): Unit {}`（`ResposibilityChain.cj:41`）是"校验者只实现 check"的 Null Object，但没有一行注释说明，按"有意的 no-op 需注释"报轻微；其余空函数体只有 `public init() {}`（无状态，正常） |
| §4 栈溢出 | 1 | `State.startup` 递归无深度/环检测且 `continues` 默认 true；`PathPattern` 全部是迭代（死循环另计严重）；`TreeTransformer`/`UInt128`/`CRC` 无递归 |
| §5 OOM | 3 | TextTemplate 静态缓存无界；`doCompile` 在 `prefix`/`suffix` 为空串时 `start` 恒为 0、`compiled` 无界增长（死循环式 OOM，`TextTemplate.cj:83-98`）；PathPattern 的 `patterns` 按请求深度永久增长（并入并发项） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；4 条候选已进「待验证假设」，2 条进优化方案（均标 `无基线`） |
| §6.2 大粒度锁 | 0 | 本部分唯一锁是 `PathPattern.mutex`，临界区内含 `compile`（含 `Regex` 构造）与用户 `supplier()` 调用，属"锁内做解析/回调"——但其规模只在启动期注册，不构成热点，故并入 §12 观察，不单列 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future` 生产用法；`crc32_codegen_test.cj:117-129` 是 4 个独立 `spawn` 后统一 `get`，形态正确 |
| §6.4 低效算法 | 2 | `PathPattern` 每段对 `HashMap.values()` 全量顺序扫描（`getRegexNode`/`getComplexNode`/`getPlaceholderNode`）；每请求 2 次 `replace("//","/")` + `split`。均为常数级线索，无占比数据，进优化方案/待验证假设，不作缺陷 |
| §7 降堆内存方案 | 1 | TextTemplate 缓存有界化（另 1 条 CPU 方案兼有内存收益） |
| §8 降 CPU 方案 | 2 | f_log 日志路径的 key 构造与查找；PathPattern 请求侧去物化 |
| §9 local mode 可行性 | 0 | 待改造路径的产物全部逃逸：`format` 返回 `String`、`get` 返回 `PathNode`/`Map` 并写入成员、`UInt128.toBytes` 返回数组；且无改前/改后峰值内存数据，不满足立项条件 |
| §11 现有代码的 BUG（存量） | 15 | 本轮 15 个文件的边界/空值/错误处理/状态对称逐条核对：PathPattern（死循环、竞态、正则未锚定、复杂段丢后缀、`!=` 矛盾、扩展名默认相反）、computeBytes、UInt128、TreeTransformer、State、TextTemplate（空值、进制、索引错位、契约）、crc32_codegen_test 开关恢复；全部存量 |
| §12 并发安全与锁粒度 | 2 | `PathPattern.patterns` 读无锁/写加锁（严重）；`Strategies`/`ResponsibilityChain` 注册表非并发且无契约声明（轻微）。其余：`UInt128` 是不可变 struct、CRC 变体是 `static let` 只读、`TextTemplate` 实例编译后只读且缓存是 `ConcurrentHashMap` ⇒ 判安全；`CodeBuffer` 无线程共享证据（由 `crc32_native_*` 在静态初始化/锁内使用，超出本部分） |
| §13 文档一致性（.md） | 0 | 本部分未分配 `.md`（README 与 `doc/**` 归其它部分）；仅就代码-文档契约取证时发现 `f_util/README.md:461-462`（noneConverter）与实现不符，已在 §11/§14 计，不重复计数 |
| §14 功能完备性与 README 覆盖 | 1 | README 承诺的 `noneConverter` 降级未对 plain 占位符实现；另：`TextTemplate`/`UInt128`/`computeBytes`/`TreeTransformer`/`State`/`Strategy`/`ResponsibilityChain` 七组公开能力**均无测试**（模块内只有 `PathPattern_test`、`TextTemplateCacheKey_test`、`crc32_codegen_test`），这是本部分缺陷能长期存在的直接原因；README 对上述类型的章节存在，无"公开 API 完全无文档"项 |
| 文件覆盖（§13 等） | 15/15 | 15 个文件全部读完，本部分无 `.md` 分配 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 10 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷共 24 条，是否纳入修复待用户在门禁决定。

## 总评

本部分的代码可以分成两档。`crc16` / `crc32` / `crc32_hw_kind` / `code_buffer` + `crc32_codegen_test` 是质量最高的一组：变体参数与 RevEng 检查值自洽、硬件路径与软件路径对拍、非对齐长度与并发都写了用例，`code_buffer` 的失败一律返回 `None`/`false` 交给调用方回退，边界清楚；除了 `rawPointer` 的恒等分支和手写枚举相等这类收尾问题，没有实质缺陷。

另一档是"从 Java 移植后没有补齐收尾"的三个结构件：

1. `PathPattern` 是全模块风险最高的文件。`get()` 是一个 200 行的回溯状态机，其中"占位符 + 两个字面段"的形态会**无限循环**（同深度不匹配的请求直接挂死线程），而它同时还在**读路径上写共享 `ArrayList`**——两个普通请求就能构成对 `std.collection.ArrayList` 的无同步并发读写。再叠加 `{id:\d{4}}` 因 `else if` 缺尾部锚点导致的过度匹配、`ComplexPathNode` 丢掉占位符后的字面后缀，这套路由匹配在"能跑通测试"和"线上行为正确"之间有明显差距。建议优先级：死循环 → 读路径竞态 → 两个过度匹配。
2. `TextTemplate` 的骨架（缓存键、切段、按段格式化）设计得不错，`TextTemplateCacheKey_test` 也补上了"同一模板串换分隔符不串味"这个真实缺陷。但 `time:`/`number:` 占位符的实现（约 150 行）几乎全错：空值丢弃 `noneConverter`、进制分支丢负号且宽度补齐差、转义识别拿模板串的下标索引子串、两段代码互相复制且共用一条错误文案。这些路径**一行测试都没有**，所以只能靠读代码发现。此外 README 承诺的 `noneConverter` 降级只对 time/number 生效，普通占位符缺字段直接抛异常。
3. `computeBytes` / `UInt128` / `StatePattern` / `TreeTransformer` 是零测试的小件，缺陷形态也一致：本该失败的输入静默成功（`computeBytes` 的 `groupCount` 恒真、`UInt128` 不抛长度异常、`State` 默认 `continues=true` 变成无限递归）。

阻塞项（建议本部分先修）：PathPattern 的回溯死循环与读路径竞态、`computeBytes` 的恒真分支、`UInt128.fromBytes` 漏 `throw`。这四条都只影响对外 API 的正确性、修复范围局部，但第一条足以让任意 404 请求打死一个线程。其余"一般"项（TextTemplate 的四处格式化缺陷、noneConverter 契约、TreeTransformer 孤儿、State 递归）建议同批处理，因为它们的共同前提是"没有测试"——补用例的成本比改代码更高，收益也更持久。

范围外提示（不占本轮统计）：① `fmq/src/config/MQConfig.cj:183-186` 已写明 `f_util.computeBytes` 在本 SDK 上不可用并自建了 `parseByteSize`，修好本文件的 `computeBytes` 后可以回收那份重复实现；② `f_jit/src/backend/CodeBuffer.cj` 与 `f_util/src/code_buffer.cj` 是同一套 W^X 页管理的两份实现；③ `f_log/src/base/Logger.cj` 六处 `append` 都在热路径上无条件调用 `TextTemplate.compile`，是本部分优化方案（堆内存 1 条 / CPU 2 条）的主要落点。
