# f_data 模块审查报告

> **模块第 8/8 部分**：只覆盖 `files/f_data.part8.txt` 列出的 2 个文件（`src/validation/Validator.cj`、`src/validation/Validator_test.cj`）。同模块其余文件由第 1~7 部分产出，本报告不对其下结论；模块 README / `doc/**` 的文档一致性由其他部分负责，本报告只在「范围外提示」里点到为止。

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 2 个源文件：2 个 `.cj`、0 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 8/8 部分）

## 发现

### [一般][存量] `IsIntegerRange(range:)` 把左闭右开区间当成左闭右闭：`1..10` 会放行 10

- **位置**：`f_data/src/validation/Validator.cj:171-173`（`maxInclusive: range.isClosed || range.hasEnd`）、判定在 `f_data/src/validation/Validator.cj:176-184`（`x <= max`）
- **来源**：存量（`git blame -L 160,195`：整段来自 `4be871f2f`，仅文件迁移，无后续改动；工作区快照无 diff）
- **判据**：review-checklist §11「边界差一 / 越界」、§10 正确性（`Option`/区间语义是否被正确理解）
- **证据**：静态确定 —— `Range` 的 `hasEnd` 表示「区间有结束边界」，不是「结束值可取」。std 文档 `stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:5658-5750` 用 `Range<Int32>(1, 10, 1, true, true, false)` 演示「有结束值」，并注明 `isClosed=false` 表示左闭右开；`1..10` 与 `1..=10` 的 `hasEnd` 都是 `true`，只有 `isClosed` 不同。因此 `isClosed || hasEnd` 对任何有界区间恒为 `true`，`1..10` 被判成 `x <= 10`。
- **描述**：`IsIntegerRange(range: 1..10)` 期望排除 10，实际 `validate('10')` 返回 `true`，边界恰好差一。`1..=10` 恰好正确，所以用例只测闭区间时发现不了。同一行的 `minInclusive: range.hasStart` 也有语义混用：`hasStart=false`（无起点区间）会退化成 `x > start`，即把「没有下界」实现成「下界不可取」——此点记 `待确认`（缺无起点区间作为普通 `Range<Int64>` 值的实际用法）。
- **建议**：`maxInclusive: range.isClosed`（`!range.hasEnd` 时用「无上界」语义，例如 `max` 取 `Int64.Max` 且 `maxInclusive: true`）；`!range.hasStart` 时用 `min: Int64.Min` 且 `minInclusive: true`。同时把 176-184 行两个内联 `if` 表达式提成 `let okMin = ...` / `let okMax = ...` 再 `&&`，现在的 `} && if (` 写法虽然合法（分支必须是代码块，`&&` 只能落在整个 if 表达式之外），但极易被误读成 `else` 分支内的续写。

### [一般][存量] `IsIntegerRange` 默认值组合让 `Int64.Max` 永远不通过、负数默认被拒

- **位置**：`f_data/src/validation/Validator.cj:162-168`（`min: Int64 = 0`、`max: Int64 = 0x7FFF_FFFF_FFFF_FFFF`、`minInclusive: Bool = true`、`maxInclusive: Bool = false`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名/注释不符」「边界差一」
- **证据**：静态确定 —— 默认 `max` 是 `Int64.Max` 而默认 `maxInclusive=false`，判定式是 `x < max`，于是 `@IsIntegerRange[min: 1]` 拒绝 `9223372036854775807`；默认 `min=0` 且 `minInclusive=true`，于是只写 `max` 的 `@IsIntegerRange[max: 100]` 静默拒绝所有负整数，使用者无法表达「只约束上界」。
- **描述**：两个默认值各自都「看起来保守」，组合起来却同时砍掉值域两端：上端少一个合法值（`Int64.Max`），下端少了整个负数半轴，且字段描述 `${min} < value < ${max}`（`:188-192`）会打印出一个几乎无意义的巨大上界，用户从错误消息看不出默认值在起作用。
- **建议**：`maxInclusive` 默认改 `true`（与 `minInclusive` 对称），或把 `max` 改成可选（`?Int64`，`None` 表示无上界）避免「哨兵值 + 排他」的组合；`description` 在 `min == 0 && max == Int64.Max` 时输出「必须为整数」而不是打印满屏数字；README 的 `@IsIntegerRange[min max minInclusive maxInclusive]` 段落需同步默认值说明。

### [一般][存量] `IsChineseCellPhone` 正则缺尾锚且不限定号段：`13800138000abc` 与 `10000000000` 都通过

- **位置**：`f_data/src/validation/Validator.cj:142-152`（`:151` `'^${rege}1\\d{10}'.regex(solid: true).matches(value ?? '')`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」「契约与实现不符」、§10 正确性
- **证据**：静态确定 —— std 文档 `stdlib/doc/libs/std/regex/regex_package_api/regex_package_classes.md:1144-1158` 明确 `matches` 的语义是「判断入参 input 与正则表达式**是否存在匹配**」（子串匹配，示例 `r.matches("2024-10-24&2025-01-01")` 命中前一段即可）。这里只有 `^` 没有 `$`，所以 `13800138000abc`、`13800138000 任意后缀` 全部返回 `true`；`1\d{10}` 只要求 11 位、首位为 1，`10000000000`（号段 10 不是有效移动号段）同样通过。
- **描述**：字段校验对「尾部带垃圾」和「格式对但号段非法」两类输入放行，脏数据进入后续流程；正则匹配的宽松性由 `matches` 语义决定，不是猜测。
- **建议**：改为 `'^${rege}1[3-9]\\d{9}$'`（号段约束按业务确认，至少补 `$`）；若要保留宽松号段，至少在类注释与 README 写明「只校验长度与前缀」。补一条 `v.validate('13800138000abc') == false` 的用例。

### [一般][存量] `StringSize` 用 UTF-8 字节长度，与「字符串长度」的契约不符

- **位置**：`f_data/src/validation/Validator.cj:69-83`（`:76` `v.size >= min && v.size <= max`，`:80` 描述「字符串长度必须在${min}到${max}之间」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名/注释不符」、§13 文档与实现一致性（本文件内的公开描述即契约）
- **证据**：静态确定 —— std 文档 `stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:6181-6202`：「功能：获取字符串 UTF-8 编码后的**字节长度**」。一个汉字 3 字节，`'张三'` 的 `size == 6`。
- **描述**：`@CombinedValidator[IsNotBlank(...) & StringSize(min: 6, max: 50)]`（仓库内真实用法，见 `fdemo/user/src/model/mvc/UserReqResp.cj:25`）对纯中文姓名实际只允许 2~16 个汉字，用户输入「张三」（2 字）通过、输入 1 个汉字因 3 字节被拒；反过来 17 个汉字的 51 字节被拒。长度语义与 `description`、README（`f_data/README.md:182-190`「min 字符串长度最小值」）都不一致，且随字符集漂移。
- **建议**：长度按字符（rune）计：`value.runes().count()`（或先 `toRuneArray().size`，注意额外分配）；若坚持字节语义，则把类名/描述/README 改成「字节长度」并给出中英文混排示例。二者必须与 README 同时改，这属于契约变更，需要用户拍板。

### [一般][存量] `IsNotBlank` 只去 ASCII 空白：全角空格 / NBSP 能通过「非空白」校验

- **位置**：`f_data/src/validation/Validator.cj:59-61`（`(value ?? '').trimAsciiBlanks().size > 0`）、实现 `f_base/src/ExtendString.cj:45-58`（`while (start < this.size && this[start] <= b' ')`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 空值未处理」、§10 正确性
- **证据**：静态确定 —— `trimAsciiBlanks` 只剥 `<= 0x20` 的字节，`'\u{3000}'`（全角空格，3 字节，首字节 0xE3）、`'\u{A0}'`（NBSP）、`'\u{200B}'` 都不满足条件，被原样保留，`size > 0` 成立。
- **描述**：类描述是「必须是非空字符串，且不能全部都是空白符」，中文表单里全角空格是最常见的「看起来为空」的输入，`IsNotBlank` 对其返回 `true`，等于校验失效。`trimAsciiBlanks` 的名字本身没错，错在校验器把它当成了完整的空白判定。
- **建议**：改用 Unicode 空白判定（按 rune 判 `\u{9}-\u{D}`、`\u{20}`、`\u{A0}`、`\u{1680}`、`\u{2000}-\u{200A}`、`\u{2028}`、`\u{2029}`、`\u{202F}`、`\u{205F}`、`\u{3000}`，或 std 里等价的 `isWhitespace` 实现）；若「只认 ASCII 空白」是刻意约定，则把类描述与 README 改成「不能全部是 ASCII 空白字符」。

### [一般][存量] `DoesMatchRegex` 不做整串匹配、不带 `Unicode` flag，非法正则还会把异常抛到校验主路径

- **位置**：`f_data/src/validation/Validator.cj:265-272`（`:271` `this.regex.regex(solid: true).matches(value ?? '')`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10 正确性（错误处理）
- **证据**：静态确定 —— `matches` 是子串匹配（`stdlib/doc/libs/std/regex/regex_package_api/regex_package_classes.md:1144-1158`），同文件其他校验器（`IsIntegers:256`、`IsChineseCellPhone:151`）都显式写 `^...$`，唯独用户自定义正则原样透传：`@DoesMatchRegex[regex: '[0-9]+']` 对 `'abc123'` 返回 `true`。另：`String.regex()` 直接 `Regex(this, flags)`（`f_regex/src/RegexFromString.cj:57`），构造失败抛 `RegexException`（`regex_package_classes.md:817-819`「当初始化失败时，抛出异常」），`MutableField.set`（`f_data/src/base/MutableField.cj:25-26`）不捕获 ⇒ 请求期 500，而不是「校验不通过」。第三点：本调用未传 `Unicode` flag，而 std 文档明确「处理非 ASCII 字符时必须使用 Unicode 匹配模式」（`regex_package_classes.md:808-810`），含中文字面量的用户正则会静默失配。
- **描述**：三个问题同一根因——把用户正则当「完整规则」透传，既没做整串锚定、也没做构造期校验与 flag 约定。前者造成校验宽松（`[0-9]+` 这类常见写法形同 `.*` 的一部分），第二个把配置错误变成运行时异常，第三个让中文正则「写了但不生效」。
- **建议**：`validate` 用 `'^(${regex})$'` 包裹；构造期（或首次 `validate` 前）用 `try { this.regex.regex(flags: [Unicode], solid: true) } catch (e: RegexException) { throw IllegalArgumentException(...) }` 提前暴露，让配置错误在启动/注解解析阶段失败，并统一补 `Unicode` flag；README 写明「整串匹配 + 非 ASCII 需 Unicode 模式」。

### [一般][存量] `IsDateTime` 的 `catch (_)` 把「format 配错」与「值不合法」混成一个 `false`

- **位置**：`f_data/src/validation/Validator.cj:212-231`（`:218-225` `try { DateTime.parse(value ?? '', format); true } catch (_) { false }`）
- **来源**：存量（快照模式，无基线可比；`f_data/doc/REVIEW_2026-10-15.md:56` 已把它记为「仅记录」）
- **判据**：review-checklist §3「`catch (_)` 静默吞掉异常（至少一般）」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— std 文档 `stdlib/doc/libs/std/time/time_package_api/time_package_structs.md:1389-1392` 把两类异常分开：`TimeParseException`（无法解析）与 `IllegalArgumentException`（`format` 格式不正确）。`catch (_)` 把两者都收敛成 `false`。
- **描述**：注解写错格式（如 `'yyyy-MM-DD'`）时，所有请求都会被判「不是日期时间」，错误消息仍是「必须为日期时间」，排查方向被引到数据侧；该类错误在整个进程生命周期内 100% 复现却没有任何日志。
- **建议**：只 `catch (e: TimeParseException)` 返回 `false`，`IllegalArgumentException` 上抛（让它以配置错误形态暴露），或在构造/首次使用时校验 `format` 并抛带 `format` 原文的 `IllegalArgumentException`。

### [轻微][存量] 三个正则型校验器与构造样板重复

- **位置**：`f_data/src/validation/Validator.cj:86-131`（`IsInteger` / `IsDecimal` / `IsEmail` 的 `validate` 体完全同构，只差 `Regex.INTEGER|DECIMAL|EMAIL`）、以及 7 处逐字相同的构造转发（`:41-43,56-58,87-89,103-105,119-121,197-199,234-236`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定 —— 三个函数体压成摘要均为「`?String` → `Regex.X.matches(v)` → 无副作用」，`v = value ?? ''` 一行在 `:74,:91,:107,:123` 重复四遍；构造转发在 7 个类里逐字相同，另 6 个类（`StringSize`/`IsChineseCellPhone`/`IsIntegerRange`/`IsDateTime`/`IsIntegers`/`DoesMatchRegex`）也只是在同一句 `super(messageIfNotMatch: messageIfNotMatch)` 上加几个字段。
- **描述**：同一语义的两份/多份实现，后续要加「空串是否直接判 false」「是否 trim 后再匹配」这类规则时容易只改一处。差异点目前只有正则常量与 description 文案，属可参数化范围。
- **建议**：抽一个包内 `class RegexValidator <: Validator`（字段 `regex: Regex`、`desc: String`），三个类退化为薄子类；`Validator` 基类已有带默认值的构造，子类可省掉 `init` 转发。注意这是包内重构，`@Annotation` 类名与注解参数名不能改。

### [轻微][存量] `IsIntegers` 与 `IsInteger` 对「整数」的定义不一致

- **位置**：`f_data/src/validation/Validator.cj:251-263`（`:256` `^\\d+(...\\d+)*$`）对比 `:86-99`（`Regex.INTEGER` = `^[\+-]?\d+$`，见 `f_regex/src/ExtendRegex.cj:43`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「近似重复导致的行为漂移」、§11「语义与命名不符」
- **证据**：静态确定 —— `IsInteger.validate('-5') == true`，`IsIntegers(separator: ',').validate('-5,6') == false`；同一份数据用两个校验器结论相反。
- **描述**：`IsIntegers` 的描述是「必须为${separator}分隔的整数列表」，但它不接受符号，也不接受分隔符两侧空白。列表场景（如批量 ID）通常不需要负数，所以这是「定义漂移」而非必然缺陷，但两处必须显式约定同一套整数定义。
- **建议**：若列表也允许负数，正则改 `^[\+-]?\d+(${sep}[\+-]?\d+)*$`；若刻意只允许非负，把类描述写成「非负整数列表」，并在 README 与 `IsInteger` 段落并列说明差异。

### [轻微][存量] 测试只覆盖 4 个已修缺陷，本文件风险最高的两处无用例

- **位置**：`f_data/src/validation/Validator_test.cj:26-64`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11（回归防护）、§10 可测试性
- **证据**：静态确定 —— 全仓 `grep -rn "IsIntegerRange\|DoesMatchRegex" --include=*_test.cj` 无命中；`Validator_test.cj` 只有 `StringSize` / `IsDuration` / `IsIntegers` / `IsChineseCellPhone` 四个用例，且 `IsChineseCellPhone` 只测了「带/不带国家码」两个正反例，没有尾随垃圾与号段用例。
- **描述**：本文件现存两个可静态判定的边界缺陷（`range:` 构造的 `1..10`、`maxInclusive` 默认排他）都落在无测试的 `IsIntegerRange` 上，说明「修完即忘」的模式仍在延续。
- **建议**：补 `testIntegerRangeFromRangeLiteral`（`IsIntegerRange(range: 1..10)` 必须拒绝 10、`1..=10` 接受 10）、`testIntegerRangeDefaultMax`（`@IsIntegerRange[min: 1]` 接受 `Int64.Max`）、`testChineseCellPhoneRejectsTrailingGarbage`、`testDoesMatchRegexIsWholeMatch`。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分无 bench / profile 数据，以下全部标记为无基线。

### [CPU] 把校验用正则提升为文件级常量，消掉每次 `validate` 的 key 构造与并发查表

- **现状**：`IsInteger/IsDecimal/IsEmail` 每次 `validate` 都走 `Regex.INTEGER` 之类的静态属性（`f_regex/src/ExtendRegex.cj:41-59`，属性体内 `'...'.regex(solid: true)`），而 `String.regex` 每次都要：新建 `HashSet<String>` 去重 flags、新建 `StringGenerator` 拼 flags 串、拼 `"/${this}/${flagsstr()}"` key、再做一次 `ConcurrentHashMap.computeIfAbsent`（`f_regex/src/RegexFromString.cj:32-64`）。`IsChineseCellPhone`（`:151`）、`IsIntegers`（`:256`）还要额外做字符串插值和 `escapeRegexLiteral` 的 rune 遍历。调用路径：`MutableField.set` → `validator.validate`（`f_data/src/base/MutableField.cj:25-26`），**每次字段赋值一次**，在请求主路径上按「字段数 × 请求数」放大。
- **方案**：把不依赖实例字段的正则提成文件级 `private let INTEGER_REGEX = ...`（`IsInteger/IsDecimal/IsEmail`），`Regex` 是引用类型且只读，可安全共享；`IsChineseCellPhone` / `IsIntegers` / `DoesMatchRegex` 把「拼 pattern + regex()」移到构造期，`validate` 只保留 `matches`。
- **预期**：每次校验省 1 个 `HashSet` + 1 个 `StringGenerator` + 1 个 key `String` + 1 次并发 map 查找；对 `IsChineseCellPhone`/`IsIntegers` 再省 pattern 串与转义遍历。具体占比**无数据**，需实测。
- **代价**：无语义变化（正则只读、线程安全）；`DoesMatchRegex` 的非法正则会从「首次请求抛」提前到「注解解析抛」，属改进但会影响错误时机。
- **验证**：`cjpm bench -O2` 对 `validate` 跑 10 万次对照（同机、同 SDK、取中位数与离散度），并用 `cjprof record` 看 `RegexFromString.regex`/`flagsstr` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 校验器内的中间字符串可缩短生命周期

- **现状**：`escapeRegexLiteral`（`:27-37`）每次调用都建一个 `StringGenerator` 并对每个 rune 做 `c.toString()`（一次小对象分配 + 一次 `meta.contains(String)` 子串搜索）；`IsChineseCellPhone` 每次都 `'^${rege}1\\d{10}'` 新建 pattern 串。对象都很小（几十字节），但生命周期与本可省略的分配次数在本就不需要重建的场景下被放大到每次校验。
- **方案**：`escapeRegexLiteral` 用 `Rune` 直接与元字符集合比较（`Array<Rune>` 或 `match`），避免 `c.toString()`；pattern 在构造期固化成一个 `private let pattern: Regex` 字段。
- **预期**：单次校验少 1~2 次小对象分配与 1 次字符串拼接；对 10k QPS × 每请求 10 字段量级才有可见意义，当前无数据。
- **代价**：`StringGenerator` 去掉后需要手工处理多字节 rune 追加，代码略增；构造期建 `Regex` 会持有一个常驻对象（可忽略）。
- **验证**：`getAllocatedHeapSize()` 前后对照 + `cjprof heap` 看 `String`/`StringGenerator` 分配次数；同输入 10 分钟稳态负载下 RSS 是否变化。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 校验器里的正则获取（`String.regex(solid:true)` 的 key 构造 + 并发查表）在表单校验场景里占 `validate` 自耗时的可观比例 | `f_data/src/validation/Validator.cj:92,108,124,151,256,271` → `f_regex/src/RegexFromString.cj:32-64` | `RegexFromString.regex` 的 self time 占比、单次耗时 | `cjprof record` 跑「10 万次 `validate`（混合 6 种校验器）」，对照「正则提为常量」版本 |
| 2 | `escapeRegexLiteral` 的 rune 遍历 + `c.toString()` 对 `IsIntegers` / `IsChineseCellPhone` 是可观测热点 | `f_data/src/validation/Validator.cj:27-37,148,256` | 该函数自耗时占比 | 同上，按函数级 self time 过滤 |
| 3 | `SOLID` 无缓存上限（`f_regex/src/RegexFromString.cj:29`）在本模块 `solid: true` 调用下是否会随「动态构造的 pattern」增长 | 本文件全部 `.regex(solid: true)` 调用点 | 进程内不同 pattern 数量上界 | 若 validator 只由注解常量构造则上界=注解数量，可先做一次「运行 24h 后 `SOLID` size」埋点确认 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/validation/Validator.cj` | .cj | ✅ | 全文件 278 行逐行读完；发现 9 条（含 `escapeRegexLiteral` 及 13 个校验器） |
| 2 | `f_data/src/validation/Validator_test.cj` | .cj | ✅ | 全文件 64 行读完；见 §覆盖缺口（轻微 #10） |

合计：`.cj` 2 个 / `.md` 0 个 / 共 2 个，全部读完（与 `files/f_data.part8.txt` 的 2 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4（`range:` 边界恒真、默认值排他、手机号缺尾锚、字节长度）、错误处理 1（`IsDateTime` 吞异常）、可读性 1（`} && if (` 写法，并入 #1 建议）；无外部输入拼接 SQL/路径，安全性无命中；设计上 13 个校验器各自独立、无分层问题 |
| §1 死代码 | 0 | 逐个检查：`private escapeRegexLiteral` 在 `:148,:256` 两处被调用；13 个校验器类均为顶层 `public`（对外可达，按硬原则一不判），且经 `@Annotation` 由 `MutableField.set` 的 `tryGetAnnotation<Validator>`（`f_data/src/base/MutableField.cj:25`）反射取用；`import std.convert.*` 用于 `Int64.tryParse`，`import fountain::f_base.*` 用于 `StringGenerator`/`Duration`/`DateTime`（f_base `public_std_imports.cj:22` 再导出 std.time），`fountain::f_regex.*` 用于 `Regex` 扩展，`fountain::f_data.base.*` 用于 `Validator`，无未使用 import；`return`/`throw` 后无同层语句；无恒真恒假分支（`:176-184` 的两个 `if` 都可取两值） |
| §2 重复逻辑 | 2 | `IsInteger/IsDecimal/IsEmail` 三份同构 `validate` + 7 处逐字相同的构造转发（轻微 #8）；`IsIntegers` 与 `IsInteger` 的整数定义漂移（轻微 #9）。同文件其余函数按「输入→输出→副作用」两两比对，无第三处同语义实现 |
| §3 空实现 | 1 | `IsDateTime` 的 `catch (_)`（#7）；其余 `validate` 均有真实判定，`description` 均有内容，无 `TODO`/空函数/`return None` 占位 |
| §4 栈溢出 | 0 | 本文件无递归调用（`escapeRegexLiteral` 是单层 rune 循环）；组合校验器的 `description` 递归在 `base/Validator.cj`，不属本部分；无自引用结构、无每帧大对象 |
| §5 OOM | 0 | 无全量物化、无按输入长度预分配、无全局容器；`escapeRegexLiteral` 的输出长度 ≤ 输入长度 × 2（线性上界）；`Regex` 缓存增长属 `f_regex` 范围（见待验证假设 #3） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点不成立；正则获取与转义已列为待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 本文件无锁；`String.regex` 内部的 `ConcurrentHashMap.computeIfAbsent` 在 f_regex，且临界区只有一次 `Regex` 构造 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理；校验是同步纯函数 |
| §6.4 低效算法 | 0 | `escapeRegexLiteral` 是 O(n) 单遍；`meta.contains(c.toString())` 常数很小；无嵌套循环、无 `remove(at:0)`、无循环拼接 |
| §7 降堆内存方案 | 1 | 见「[堆内存] 校验器内的中间字符串可缩短生命周期」（无基线，待验证） |
| §8 降 CPU 方案 | 1 | 见「[CPU] 把校验用正则提升为文件级常量」（无基线，待验证） |
| §9 local mode 可行性 | 0 | 本文件临时对象只有 pattern 串与转义用的 `StringGenerator`，单次几十字节、无峰值内存意义；引入 `--enable-local-mode` 的收益无法用峰值内存证明，且 `Regex` 必须逃逸到缓存，改造不成立 |
| §11 现有代码的 BUG（存量） | 7 | 已核对本部分 13 个 `validate` 与 1 个辅助函数 `escapeRegexLiteral` 的边界与空值：`?String` 均以 `?? ''` 兜底（`None` 判空符合语义）；命中 #1~#7（区间上界恒真、默认值排他、手机号尾锚、字节长度、ASCII 空白、`DoesMatchRegex` 语义、`IsDateTime` 吞异常） |
| §12 并发安全与锁粒度 | 0 | 13 个校验器字段全为 `private let`（不可变），无共享可变状态；实例由注解解析产生、可被多线程同时调用而无写操作；依赖的 `Regex` 缓存是 `ConcurrentHashMap`（`f_regex/src/RegexFromString.cj:29`）；无检查-然后-写入、无惰性初始化 |
| §14 功能完备性与 README 覆盖 | 0 | README 列出的 13 个校验器（`f_data/README.md:176-246`）在本文件全部有实现，无「承诺但空实现」；`IsIntegerRange(range:)` 构造与 `IsChineseCellPhone` 的 `withCountryCode`/`countryCodeSeparator` 未进 README，属 README 侧缺口，已交由文档部分（见范围外提示） |
| 文件覆盖（§13 等） | 2/2 | 本部分文件清单只有 2 个 `.cj`，无 `.md`；`.md` 一致性（README / `doc/**`）由其他部分负责，本报告仅做范围外提示 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本文件是纯函数式校验器集合，没有共享状态、没有递归、没有 I/O，并发安全与 OOM / 栈溢出三个维度都是干净的；主要风险集中在**校验语义的边界**而不是工程质量：

1. `IsIntegerRange(range:)` 对 `hasEnd`/`isClosed` 的误用让左闭右开区间放行上界（`1..10` 收 10），这是本部分唯一「静默放行非法数据」的确定性缺陷，建议优先修并补用例；
2. `maxInclusive` 默认 `false` 搭配 `max = Int64.Max`、`min` 默认 `0`，使默认配置同时砍掉 `Int64.Max` 和全部负数，属于难排查的「默认值陷阱」；
3. `IsChineseCellPhone` 缺 `$` 锚（`matches` 是子串匹配，已查 std 文档确认）与 `StringSize` 用字节长度，是两处会放过脏数据 / 误拒合法数据的契约偏差，前者改动最小收益最直接；
4. `DoesMatchRegex`、`IsDateTime` 把配置错误和值不合法混为一谈，建议在注解解析期就把配置错误暴露出来。

`doc/REVIEW_2026-10-15.md` 已修的 4 项（`StringSize.min`、`IsDuration` 对齐解析器、分隔符转义、国家码括号）在本文件中实现无误，注释与实现一致；但修复没有配套 `IsIntegerRange` / `DoesMatchRegex` 的用例，同类问题仍可能复发。存量 10 条（7 一般 + 3 轻微），是否纳入修复待用户决定；两条优化方案均无基线，只作下一轮补数据的清单。

## 范围外提示

- `f_data/README.md:195-196` 写 `@IsDecimal`「数据必须是实数，包括整数和小数」，而实现 `f_data/src/validation/Validator.cj:106-109` 用的 `Regex.DECIMAL`（`f_regex/src/ExtendRegex.cj:48` = `^[\+-]?\d+\.\d+$`）要求必须带小数点，`'3'` 会被拒——若 README 为准则应改实现为 `REAL_NUMBER`，实现为准则应改 README；README 由文档部分覆盖。
- `f_data/README.md:204-215` 只记录了 `@IsIntegerRange[min max minInclusive maxInclusive]`，未记录本文件的 `public const init(range: Range<Int64>)`（`Validator.cj:171`）；`README.md:201-202` 也未记录 `IsChineseCellPhone` 的 `withCountryCode` / `countryCodeSeparator`。同属 README 侧缺口。
- `f_regex/src/RegexFromString.cj:29` 的 `SOLID` 是无容量上限的 `ConcurrentHashMap`，本文件以 `solid: true` 驱动它；pattern 若来自运行期拼接（目前没有）会无界增长——`f_regex` 范围，仅提示。
