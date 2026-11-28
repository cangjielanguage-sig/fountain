# f_util 模块审查报告

> **模块第 3/4 部分**（本报告只覆盖 `files/f_util.part3.txt` 列出的 20 个文件，全部是 `f_util/src/` 下的 `.cj`：`TextTemplate` → `exception/HashException`。本部分没有 `.md`；`README.md` / `README_en.md` / `doc/**` 由第 1 部分覆盖，本报告用于核对的文档引用只作证据。本部分编号独立，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（本部分 20 个 `.cj`，0 个 `.md`；模块共 48 `.cj` + 19 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 只有未跟踪的 `docs/review/`、`reviews/` 两个过程目录 ⇒ 本部分所有问题来源记「存量」）
- **审查重点**：工具类正确性与边界、死代码、重复逻辑、空实现、栈溢出、OOM、并发安全、存量 BUG
- **报告版本**：v1（第 3/4 部分）
- **验证方式**：只读审查；未跑 `cjpm build` / `cjpm test`；未做性能测量。所有运行时后果均由代码路径 + 仓库内既有用法（`Regex.replaceAll` / `BigInt` / `HashMap` 下标语义）推导

## 发现

### [严重][存量] #1 `time:` 占位符的格式模板恒为单个反引号：`Regex.replaceAll` 把格式串当正则、把反引号当输入

- **位置**：`f_util/src/TextTemplate.cj:169-185`，关键行 `176`（`placeholder[formatStart..formatEnd].trimAscii().regex().replaceAll(...)`，两个实参分别是「一个反引号」和「反斜杠 + 反引号」）；产物消费点 `Value2TimeString.doFormat`（`:311-313`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§10「正确性」
- **证据**：静态确定 ——
  1. `replaceAll` 的接收者是先由**格式串**构造出来的 `Regex`，形参却是 `(input, replacement)`：仓内三处同 API 调用都传「被替换的文本 + 替换值」（`f_app/src/App.cj:400`、`f_orm/src/base/Condition.cj:81`、`f_util/src/PathPattern.cj:66`），`f_regex` 也没有给 `Regex` 加过两参重载（`f_regex/src/ExtendRegex.cj:35-37` 是 `doReplace*`）。所以这里的实际语义是「在字符串 `` ` `` 中把匹配 `format` 的部分换成 `\`` 」。
  2. 当 `format` 不匹配单个反引号（`yyyy-MM-dd`、`HH:mm:ss` 等全部如此），`replaceAll` 原样返回 input，即 **`format` 的值变成 `` ` ``**。随后 `DateTime.format("`")` 只会输出一个反引号（或按模式字面量输出），日期永远不会被格式化。
  3. 反向也坏：`format` 被当成正则编译（`.regex()`），含 `(`, `)`, `*`, `[` 等元字符的日期模板会在这里抛 `RegexException`。
  4. 不带反引号的写法更早失败：README 的写法是 `` time:`FORMAT` ``，而仓库里的演讲材料 `docs/speech/speech.md:3287`（`.worktrees/dbware/` 下同一份）给的示例是 `{time:yyyy/MM/dd}`（无反引号）⇒ 反引号找不到时 `formatStart` 被算成 0、`formatEnd` 为 -1 ⇒ 落到 `:178` 抛 `IllegalArgumentException`。
- **描述**：`time:` 是 README 明确承诺的三类格式化能力之一（`f_util/README.md:437`、类注释 `TextTemplate.cj:39`），当前实现下**任何** `time:` 占位符都不可能输出正确时间：带反引号输出 `` ` ``，不带反引号直接抛异常。同一文件里 `number:` 分支的格式解析是正常的，说明这是 `time:` 分支独有的写法错误（把「转义格式串里的反引号」写成了对正则做替换）。
- **建议**：删掉 `.regex().replaceAll(...)`，改为对 `format` 做纯字符串级转义（把「反斜杠 + 反引号」还原成「反引号」），或直接不做转义、把转义的解释放到 `DateTime.format` 层；同时把 `time:` 分支的 `template[formatEnd - 1]`（见 #15）改回 `placeholder[formatEnd - 1]`。补用例：格式串为 `yyyy-MM-dd`（反引号包裹）时对固定 `DateTime` 断言输出、格式串为 `(yyyy)` 时不抛异常、不写反引号的 `{time:yyyy/MM/dd}` 明确报「必须用反引号包含」而不是落到通用错误。

### [严重][存量] #2 README 与类注释承诺的 `regex:` 占位符在实现里完全不存在

- **位置**：承诺源 `f_util/src/TextTemplate.cj:38-39`、`f_util/README.md:436`；缺失面 `f_util/src/TextTemplate.cj:136-188`（`addPlaceholder` 只识别 `time:` / `number:`）、`:266-277`（`Value2String` 的 4 个实现里没有正则版）、`:115`（只遍历 `[TIME_FORMAT_PREFIX, NUMBER_FORMAT_PREFIX]`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现」、§14.2「README 承诺的功能不存在」、§3「公开契约承诺有行为」
- **证据**：静态确定 —— 全文件搜 `regex:` 只命中两行注释（`:38`、`:51`），`addPlaceholder` 里没有任何以 `regex:` 分支构造的占位符对象；`Value2String` 的封闭子类集合是 `OriginValue2String` / `Value2PlainString` / `Value2TimeString` / `Value2NumberString`（`:270-273` 的 match 也已穷举），不存在「map 中第一个匹配该正则的 key」这条取值路径。
- **描述**：文档写的是「占位符用 `regex:` 开头的表示这是一个正则表达式……用 map 中找到的第一个匹配这个正则表达式的 key 所对应的值替换」。实际行为是把这个串当普通 key 去精确查表：`{regex:user_\d+}` 会走 `Value2PlainString` → `HashMap["regex:user_\\d+"]` → `NoneValueException`（map）或 `TextTemplateException`（对象）。使用者按文档写就是运行期异常，且异常信息指向「字段不存在」，与真实原因（该能力没实现）无关。
- **建议**：二选一，不要留中间态。要能力：给 `Value2String` 加 `Value2RegexString`，在 `addPlaceholder` 里识别 `regex:` 并保存正则，`doFormat` 里遍历 map 的 key 找首个 `matches` 的项（文档已明确「只接收 map」，可以在类型上限定并给出清晰异常）。要下线：删掉 README（中英两版）和类注释里的这两段，并在 CHANGELOG 标注移除。

### [严重][存量] #3 `UInt128.fromBytes` 的长度校验只构造了异常对象、没有 `throw`：任何非 16 字节输入都静默产出错值

- **位置**：`f_util/src/UInt128.cj:59-73`，关键行 `60-62`（`if (bytes.size != 16) { HashException("Invalid bytes length, expected 16 bytes, but it is ...") }`，无 `throw`）；受影响入口 `:32-40`（`tryParse` / `parse`）、`:24`（`DataParsable<UInt128>` 实现）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「错误处理缺失或静默 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 ——
  1. 花括号里是一个「构造 `HashException` 实例」的表达式语句，结果被丢弃，函数继续往下执行；`HashException` 在仓内**唯一**的使用点就是这一行（全仓 `grep HashException` 只有定义、这行、以及 `MurmurHash3X128.cj:23` 的未使用 import），也不存在「构造即抛」的语法。
  2. 长度 < 16 时循环只填 `bytes.size` 个字节，其余位保持 0：`tryParse("4142")`（2 字节）得到 `0x41420000…0000`，而 `toString()` 给出 32 位十六进制串，看起来完全合法。长度 > 16 时 `:69` 的 `(15 - i) * 8` 变负，被 `UInt64(...)` 包成巨大的移位量，结果取决于移位运算符对超宽移位的定义（`待确认`），但无论哪种都不是「报错」。
  3. 契约侧：`DataParsable.tryParse` 的语义在仓内有明文约定——「不能解析、或数值超出表示范围 → None，与其他类型 `tryParse` 一致」（`f_data/src/base/DataParsable.cj:39-51`）。`UInt128.tryParse` 对非 32 位十六进制输入返回 `Some(错值)`，直接违反该契约。
- **描述**：这是「写好了校验、忘了 throw」的典型形态：`parse("abc")` 不抛、不返回 `None`，而是返回一个永远对不上的 128 位值。`UInt128` 是 `f_codec` 的类型指纹键（`f_codec/src/default/DefaultCodec.cj:45-46,960`）与 `f_jit` 的编译去重键（`f_jit/src/bytecode/Fingerprint.cj:51-81`）；一旦有人用 `Config.getData<UInt128>`（`f_config/src/Config.cj:238` 只要求 `T <: DataParsable<T>`）或手工 `parse` 读一个 8/24 位十六进制串，就会得到静默错键——查不到缓存、误命中都必须靠现象反推。
- **建议**：`HashException(...)` 前补 `throw`；同时把 `fromBytes` 改成只接受 `Array<Byte>` 长度严格等于 16（`tryParse` 里先判 `x.size == 16` 再 `fromBytes`，让「串长不对」走 `None` 而不是异常）。补用例：`tryParse("")`、`tryParse("41")`、`tryParse("41" * 15)`、`tryParse("41" * 17)`、32 位串往返。

### [一般][存量] #4 非十进制数字格式三处错：负数符号丢失、宽度多补 1 位、`X` 的转大写分支永远不执行

- **位置**：`f_util/src/TextTemplate.cj:442-449`（`radix != 10` 分支）；`443`（`BigInt(true, number.reScale(0, …).toBigInt().toBytes())`）、`446`（`"${prefix}${0 * (integer - 1)}${string}"`）；`342-348`（`x`/`X` 分支）、`345`（`if (prefix[0] == b'X')`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§1「恒真恒假分支」；判据依据 README 承诺（`f_util/README.md:443-445`：「`x X` 表示转化成 16 进制」「`+` 对正数前置 +，`(` 对负数用括号包含」）
- **证据**：静态确定 ——
  1. **符号**：`BigInt(sign: Bool, magnitude: Array<Byte>)` 的 `sign=true` 表示非负（第 2 部分 #4 已按 `math_numeric_package_structs.md:160-178` 核实过同一 API）。这里恒传 `true`，且整个 `radix != 10` 分支**完全没有用到 `symbol`**、也没有处理 `prefixPlus` / `enclosedInParentheses`。所以 `-255` 走 `x###` 得到 `0xff` 这类正值输出。
  2. **宽度**：`prefix = "0" + formatter[0..1]` ⇒ `prefix[0]` 恒为 `'0'`，`upperCase` 永远保持 `false`，`X###` 输出小写；同时 `prefix` 是 `"0X"`（大写前缀 + 小写数字），自相矛盾。
  3. **补位**：十进制分支用 `integer - l`（`:423-430`），十六/八进制分支写成 `integer - 1`。`x###`（`integer = 3`）格式化 `255`（`l = 2`）会补 2 个 `0` 得 `0x00ff`（4 位数字），正确值应是 `0x0ff`；只有 `l == 1` 时巧合正确。另外八进制的 `prefix` 是裸 `o`/`O`（`:340`），与 `0x` 的口径也不一致。
- **描述**：三个缺陷同源（该分支是后来补的、没有和十进制分支对齐），会同时影响「负数走十六进制」「定宽十六进制列对齐」「`X` 大写风格」三类输出。定宽输出的典型用法（报文/日志里的定宽十六进制列）会整体右移并在左侧多出 `0`，属于「看起来格式化成功了，但列宽和符号都错」。
- **建议**：符号统一在分支外处理——先按 `symbol` 判断正负，`radix != 10` 时对绝对值取 `toBytes()` 并显式带负号（或按 `enclosedInParentheses` 加括号）；补位改成 `integer - l`；`X` 判定改成 `formatter[0] == b'X'` 并让 `prefix` 与 `upperCase` 共用一个变量。补用例：`x###`/`X###` × `{0, 1, 15, 255, -255}` 十组黄金串。

### [一般][存量] #5 `Value2NumberString` 的空值兜底被写成丢弃的表达式：空串仍会走 `Decimal.parse("")`

- **位置**：`f_util/src/TextTemplate.cj:406-410`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「读了不用 / 不可达语句」、§3「`case None => ()` 当兜底把错误吃掉」的反向形态（兜底写了但没生效）、§11「错误处理缺失」
- **证据**：静态确定 —— 函数返回类型是 `String`，`noneConverter` 是 `?String`，所以 `if (value.isEmpty()) { noneConverter }` 只能是**丢弃取值的表达式语句**（也无法作为隐式返回）；控制流无条件继续到 `:410` 的 `Decimal.parse(value)`。空串进 `Decimal.parse` 必抛解析异常，`noneConverter` 在这条路径上永远不生效。
- **描述**：调用方传 `noneConverter: "-"` 期望「字段为空时输出 `-`」，实际得到一条从 `Decimal.parse` 冒出来的解析异常，且异常信息里没有字段名，排查会指向数字格式而不是空值。
- **建议**：改成 `if (value.isEmpty()) { return noneConverter ?? "" }`（返回类型若要保留 `String`，就用 `??` 给默认值）；顺带给 `Decimal.parse` 包一层 `try`，把非法数字统一转成 `TextTemplateException("field ${getter.placeholder()} is not a number: ${value}")`。

### [一般][存量] #6 进程级模板缓存无容量上限，且 `f_log` / `f_llm` 的真实调用点可能喂运行期拼接的模板串

- **位置**：`f_util/src/TextTemplate.cj:54`（`private static let templates = ConcurrentHashMap<String, TextTemplate>()`）、`:68-75`（`compile` 无条件 `computeIfAbsent`）、`:80-82`（键含模板原文）
- **来源**：存量（快照模式无基线可比；设计文档已把它记为「已知问题」）
- **判据**：review-checklist §5「缓存键无界 / 无界容器」、§7 候选 4「有界化」
- **证据**：静态确定（结构）+ 待确认（增长率）——
  1. 缓存没有容量、TTL、淘汰；每条 value 是 `TextTemplate`，内含 `ArrayList<Value2String>`，其中 `OriginValue2String` 保存 `template[start..end]` 的**副本**（`:94/96`），所以每个条目常驻「模板长度的若干倍」。
  2. 两个真实调用点：`f_log/src/base/Logger.cj:51/62/72/87/95/106/114/125/133/144/152` 每条带参日志都 `TextTemplate.compile(message, prefix: "{", suffix: "}")`；`f_llm/src/agents/AgentTask.cj:232` 用 `promptsTemplate`（来自 agent 配置）编译。日志 message 由调用方拼串（`"req ${id} failed"`）时，模板基数 = 实际日志种类数，随进程运行单调增长且永不回收。
  3. 设计文档已把这条列为「不在本次范围；若后续出现模板串动态生成再单独处理」（`f_util/doc/spec/fix-text-template-cache-key/design.md:61`，Non-Goals 与 Risks 各一处）。也就是说风险成立的前提（动态模板）在 `f_log` 上已经具备，只是没人量过规模。
- **描述**：这是「缓存把不可信基数变成常驻内存」的形态：失控时表现为 RSS 随运行时间上升、GC 后不回落，且没有任何拒绝路径（没有上限判断、没有告警）。第 1 部分已把它放进待验证假设 #4，本部分确认代码位置与增长机制，作为缺陷记录（不是性能猜测）。
- **建议**：给缓存加有界化：容量上限 + LRU（`f_cache.HeapCache` 已在 `f_regex/src/RegexFromString.cj:20` 用于正则缓存，同一套设施可复用），或改用「弱引用键 + 定时清理」；同时给 `compile` 加一条长度上限（超长模板不进缓存，直接编译一次用完即弃）。验收口径：跑 24h 日志压测，断言条目数与 RSS 达稳态。

### [一般][存量] #7 空 `prefix` / `suffix` 让 `doCompile` 进入死循环并向 `compiled` 无限累加

- **位置**：`f_util/src/TextTemplate.cj:83-127`（循环体 `92-126`），入口 `:65-67`（`compile(template, placeholder: "")` 会把空串同时当 prefix/suffix）、`:68-75`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「无界增长导致 OOM」、§11「无界循环 / 外部输入未校验」
- **证据**：静态确定 —— 取 `prefix = suffix = ""`、`template` 非空（`templateLength = n > 0`）：`prefixLength = suffixLength = 0`；`end = indexOf("") = 0`、`tmp = indexOf("", 0) = 0`。循环里分支一要求 `end > 0`（不成立），分支二要求 `end < 0 || tmp < 0 || end >= n || tmp >= n`（全不成立）⇒ 既不 `break` 也不 `add` 原文；随后 `start = end + 0 = 0`、`end = 0`，`addPlaceholder(template, 0, 0, i)` 拿到空 placeholder，走 `:139-142` 添加一个 `Value2PlainString` 后返回；`start = 0`、`end = indexOf("", 0) = 0` ⇒ **下一轮状态完全相同**。每轮向 `compiled` 追加一个对象，没有任何出口。
- **描述**：`compile` 是公开 API，分隔符完全由调用方给；传空串看似"不解析占位符"，实际是请求线程 100% CPU 空转 + `ArrayList` 无限增长 ⇒ 卡死或 OOM。仓内现有调用点都传非空分隔符，所以这是潜伏缺陷，不是当前线上问题。
- **建议**：`compile` 入口做参数校验：`prefix.isEmpty() || suffix.isEmpty()` 直接 `throw IllegalArgumentException`（或按「整串作为原文」返回，但必须显式写清）；`doCompile` 里再加一条兜底——若一轮循环没有推进（`start` 与 `end` 与上一轮相同）就抛异常，避免以后别的边界再触发同类死循环。

### [一般][存量] #8 `computeBytes` 对合法输入抛异常、乘法溢出静默回绕，且声明返回 `Option` 却从不返回 `None`

- **位置**：`f_util/src/Utils.cj:25-34`（关键行 `29` 的 `matched.groupCount() >= 2`）、`:36-57`（关键行 `57` 的 `throw`、`41-55` 的连乘）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「边界 / 契约与实现不符」、§10「错误处理」
- **证据**：静态确定 ——
  1. 正则 `^(\d+)([kmgtpezyKMGTPEZY]?)[bB]?$` 固定有 2 个捕获组，`groupCount() >= 2` 恒成立，所以**总会**进入 `computeBytes(num, unit)`。对 `"123"`（无单位）和 `"10b"` / `"10B"`（`[bB]?` 吃掉字母、组 2 为空）而言 `unit == ""`，`computeBytes(n, "")` 落不进任何 `if`，直接执行到 `:57` 抛 `IllegalArgumentException("not supported byte unit: ")`。
  2. 仓内已有旁证：`fmq/src/config/MQConfig.cj:183-186` 的注释明确写「不用 `f_util.computeBytes`：该实现对单位分组的取值在本 SDK 上不稳定（大写单位会落到『not supported byte unit』），这里用显式字节扫描」——即下游已经踩过并绕开了它。
  3. `n * 1024 * … ` 全用 `Int64` 连乘，`Y`/`Z`/`E` 档必然溢出（`"9Y"` 回绕成负数），没有任何上界检查。
  4. 返回类型声明为 `Option<Int64>`，但两个重载的所有路径要么返回值、要么抛异常，`None` 从未出现；`find(...).getOrThrow()`（`:27`）对不匹配的串也直接抛 `NoneValueException`，而不是返回 `None`。
- **描述**：一个「解析 123KB / 24M」的小工具，对三种最自然的写法（纯数字、`10b`、非法串）分别给出「异常」「异常」「无上下文 `NoneValueException`」，且溢出时给出错误的正/负值。使用者按 `Option` 契约写 `match` 兜底会全部落空。
- **建议**：`unit` 为空时按字节返回 `n`；`b/B` 归一化后再分派（或干脆用 `match (uniteq) { case "" | "b" => n; case "k" | "kb" => checked(n, 1024); … }`）；所有乘法用 `try { n * k } catch (_: ArithmeticException) { None }` 收敛为 `None`；不匹配的串返回 `None` 而不是 `getOrThrow()`。补用例：`"123"` / `"10b"` / `"10KB"` / `"9Y"`（溢出）/ `"abc"`。

### [一般][存量] #9 `TreeNode.transform` 对「父节点不在集合内」的节点直接 `map[parentId]`，抛无上下文的 `NoneValueException`

- **位置**：`f_util/src/TreeTransformer.cj:53-60`，关键行 `58`（`map[parentId].addChild(t)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「空集合 / 缺失键未处理、错误处理缺失」、§10「错误处理」
- **证据**：静态确定 —— `HashMap` 的 `operator [](key)` 在键不存在时抛 `NoneValueException`（第 2 部分 #13 已按 std 文档 `collection_package_class.md:6147-6165` 核实同一语义）。`transform` 只把 `parentId == emptyId` 的节点归入 `root`，其余一律 `map[parentId]`；当调用方传进来的集合被过滤过（分页查询只取了一部分行）或存在脏 `parentId` 时，父节点不在 `map` 里，整批转换在第一个孤儿节点处中断，异常里既没有 `parentId` 也没有该节点的 `id`。
- **描述**：树装配是「数据本身可能不完整」的典型场景（按条件筛选、软删除、权限过滤都会造成孤儿）。当前实现把「数据不完整」呈现为 `NoneValueException`，与「map 里存的值是 None」无法区分，调用方只能靠堆栈位置猜。`TreeNode` 是 `public interface`（对外扩展点），仓内暂时零引用（全仓 `grep TreeNode` 只命中定义处），属对外 API 的潜伏缺陷。
- **建议**：`match (map.get(parentId)) { case Some(p) => p.addChild(t); case None => throw IllegalArgumentException("node ${t.id} references missing parent ${parentId}") }`；若要支持「容忍孤儿」，就加一个 `orphanToRoot: Bool = false` 参数把策略显式化，而不是靠异常表达。补用例：父缺失、自引用（`id == parentId`）、重复 id + `ignoreDuplicate=false`。

### [一般][存量] #10 `F_UTIL_CRC_HW` 的语义在三份实现里不一致，且 CRC-64 的 `on` 与 `auto` 完全等价（配置项无效果）

- **位置**：`f_util/src/crc32_native_x86.cj:194-199`、`f_util/src/crc32_native_arm.cj:159-164`（只把 `"0"` 视为关闭）；`f_util/src/crc64_native_x86.cj:283-307`、`f_util/src/crc64_native_arm.cj:275-299`（三态解析）；`f_util/src/crc64_native_x86.cj:276-281` + `:238-257`（`On` 从未被使用）；承诺源 `f_util/src/CrcGf.cj:24`（`enum CrcHwMode` 注释「`on` 强制尝试」）
- **来源**：存量（快照模式无基线可比；第 1 部分「范围外提示 #2」已提出 CRC-32 侧不一致，本部分落实为发现并补上 `On` 无效这一半）
- **判据**：review-checklist §14.1「接线缺失（配置项被读取却从未使用）」、§1「死配置字段 / 恒不成立的开关分支」、§13「规格与实现漂移」
- **证据**：静态确定 ——
  1. **两套语义**：CRC-32 的 `envEnabled()` 是 `v != "0"`，于是 `F_UTIL_CRC_HW=off`、`auto`、`garbage` 全部**开启**硬件；CRC-64 的 `parseMode()` 是 `off/0` → Off、`on/1` → On、其它 → Auto。同一环境变量在两族 CRC 上含义不同，运维按文档设 `off` 时 CRC-32 依然会走机器码（`crc32_native_x86.cj:165` 是 `ensureReady` 里唯一的开关判断，其定义在 `:194-199`）。
  2. **`On` 是死值**：全文件只有 `isOff()`（`crc64_native_x86.cj:276-281`）和 `modeNameForTest()`（`:207-213`）会 `match (mode())`；`On` 与 `Auto` 在 `isOff()` 里同走 `_ => false`，`ensureReady()` 的能力判断（`hasPclmul()` / `make()` 失败回退）对两者一视同仁。也就是说「`on` 强制尝试」从未实现：CPU 不支持或代码页分配失败时，`on` 一样静默回退表路径，没有任何告警。
  3. **测试没兜住**：`CrcEngine_test.cj:477-529` 的三态用例只断言「值一致 + `off` 不进机器码 + `auto`/`on` 进机器码」，在有能力且分配成功的机器上三者同时成立，因此 `On` 的无效性不会被测出来。
- **描述**：这是「配置写了、分支也写了、但语义没接上」：`On` 只影响 `modeNameForTest()` 的输出。运维想强制关闭（CRC-32 侧设 `off`）或想确认是否真的进了硬件，都得不到预期行为。
- **建议**：把模式解析收敛到 `CrcGf`（或新增平台无关的 `CrcHwSwitch`）供 CRC-32/CRC-64 共用，统一接受 `off/0`、`on/1`、其它=`auto`；`On` 要么实现成「忽略 CPU 能力探测、强制 `make()` 失败即抛/告警」，要么删掉该枚举值并同步改注释与测试。补用例：`F_UTIL_CRC_HW=off` 时两族 CRC 都必须 `available == false`。

### [一般][存量] #11 CRC 硬件开关的共享静态状态存在无同步读写：`mode()` 是热路径上的惰性初始化，`resetForTest` 与注释语义相反

- **位置**：`f_util/src/crc64_native_x86.cj:284-293`（`mode()` 在锁外写 `modeState` / `modeResolved`）、`:150`（`update` 第一行 `isOff()` 就在锁外调用它）、`:43`/`:149`/`:193`（`lastNative` 无同步写）、`:197-199`（`setNativeEnabled` 写 `forcedOff` 无同步）；`f_util/src/crc64_native_arm.cj:276-285`、`:109`、`:174-176` 同构；`f_util/src/crc32_native_x86.cj:146-148`（`nativeEnabled` 无同步写）与 `:113`（`update` 无同步读）、`:145`（注释「重新打开需要 `resetForTest()`」）对 `:150-157`（`resetForTest` 不重置 `nativeEnabled`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.1「惰性初始化（`if (x == None) { x = ... }` 的首次赋值竞态）」「发布逸出 / 可见性」、§11「语义与注释不符」
- **证据**：静态确定（存在并发读写）+ 待确认（危害形态）——
  1. **并发路径成立**：`Crc64.update` → `CrcEngine.update` → `Crc64Hw.update`（`f_util/src/CrcEngine.cj:205-215`）是每个 CRC-64 计算的必经之路，多个请求线程会同时进入 `update`（`crc32_codegen_test.cj:110-130` 的 `crc32cConcurrentMatches` 已经按 4 线程并发跑过同族 API，说明并发是预期用法）。`update` 的第一句 `isOff()` → `mode()` 在 `synchronized(lock)` **之外**执行，首次调用会写 `modeState` / `modeResolved`；而 `ensureReady()` 在锁内也会走 `isOff()` → `mode()`，两条路径对同一对字段一读一写、无同步。
  2. **后果有限但不为零**：`parseMode()` 是纯函数、两次写的是同一个值，所以最坏是「两个线程各读一次环境变量」，不会产生错误模式；但 `lastNative` 被 `call()` 无条件写、被 `lastUsedNativeForTest()` 读，并发下断言结果不可信（这正是 `CrcEngine_test` 三态用例的判据来源）。`forcedOff` 由测试钩子写、`isOff()` 读，同样无同步。
  3. **注释与实现相反**：`crc32_native_x86.cj:145` 写「测试/诊断钩子：关闭后立刻回退软件；**重新打开需要 `resetForTest()`**」，而 `resetForTest()`（`:150-157`）只清 `ready` / 函数指针 / `codes`，`nativeEnabled` 保持 `false`——关掉后调 `resetForTest()` 并不会重新打开，必须显式 `setNativeEnabled(true)`（`crc32_codegen_test.cj:102` 就是这么写的，说明作者也知道，但注释没改）。
- **描述**：并发面本身危害低（幂等写），所以不按「数据竞争 ⇒ 严重」定级；真正需要改的是「热路径上做惰性初始化」这个结构：每个 `update` 都要读一次可能触发写入的 `mode()`，在首次调用与 `resetForTest` 并发时行为不可预测，而 `resetForTest` 还会与正在执行机器码的线程竞争（代码页不 `munmap`，所以不会崩，但 `codes.clear()` 之后已经没有对象持有它，见 #13 的注）。
- **建议**：模式解析做成「构造期一次性解析 + `let` 字段」（或在 `CrcHwMode` 的静态初始化里解析），`isOff()` 只读不可变值；`lastNative` / `failAlloc` 这类测试钩子用 `AtomicBool` 或全部收进 `synchronized(lock)`；`resetForTest()` 里同时把 `nativeEnabled` 置回 `true`，与注释对齐。

### [轻微][存量] #12 死代码清单（TextTemplate / code_buffer / Crc32Hw）

- **位置**：
  - `f_util/src/TextTemplate.cj:55`（`private static let mutex = Mutex()` 全文件零引用）、`:24`（`import std.sync.Mutex` 只为它存在）、`:18` 的 `Map` 未使用（其余 `ArrayList/TreeMap/HashMap/ConcurrentHashMap/LinkedHashMap` 都有使用）、`:237-239`（`init(indexText: String)` 无调用点，`ValueGetter` 只走 `:228` 的两参 `init`）
  - `f_util/src/code_buffer.cj:61-67`（`rawPointer()` 的两个分支返回同一个 `ptr`，`if (sealed)` 是恒假/恒真装饰）、`:27`（`private var ptr` 只写一次，可 `let`）
  - `f_util/src/crc32_native_x86.cj:86-92`、`f_util/src/crc32_native_arm.cj:68-74`、`f_util/src/crc32_native_stub.cj:25-27`（`Crc32Hw.available()` 全仓零调用；调用方用的是 `availableFor(kind)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「无调用者 / 未使用的 import / 恒真恒假分支」；机械动作：`private` 全仓搜、`internal` 本包及子包搜
- **证据**：静态确定 —— 四个符号都做了全仓搜索：`mutex` 只命中声明与 import；`Map` 在文件内只命中 import 行；`ValueGetter(` 只命中构造点 `:138`（两参）；`Crc32Hw.available()` 用 `grep -rn "Crc32Hw.available()"` 零命中（`Crc64Hw.available()` 反而被 `CrcEngine_test.cj:482/561/…` 使用，属「仅测试使用」的可见性信息，不判死代码）。
- **描述**：`TextTemplate.mutex` 是缓存键那次变更的残留，而且设计文档还替它编了一个不存在的用途——`f_util/doc/spec/fix-text-template-cache-key/design.md:51` 写「原来 `Mutex` 字段**用于其它路径**，不参与 compile」，实际上它一次都没被用过。`rawPointer` 的双分支是 W^X 改造时留下的占位判断。
- **建议**：删 `mutex` / `Mutex` import / `Map` import / `ValueGetter.init(indexText:)` / 三份 `Crc32Hw.available()`；`rawPointer()` 直接 `return ptr`；`ptr` 改 `let`。`available()` 若确实要给诊断用，就在 `fprobe` 或其他模块接一个真实调用点，否则按死代码删。

### [轻微][存量] #13 重复逻辑：CRC 硬件开关/状态管理在 x86 与 arm 两份实现里逐行复制，`crc16/32/64` 三个包装类同构

- **位置**：
  - `f_util/src/crc64_native_x86.cj:276-307`（`isOff` / `mode` / `parseMode`）与 `f_util/src/crc64_native_arm.cj:268-299` **逐行相同**（仅 `hasPclmul` vs `hasPmull` 不同）；`resetForTest`（`crc64_native_x86.cj:220-236` vs `crc64_native_arm.cj:197-212`）、`setNativeEnabled`（`:197-199` vs `:174-176`）、`lastUsedNativeForTest` / `modeNameForTest` / `forceAllocFailureForTest` 亦同构
  - `f_util/src/crc32_native_x86.cj:194-212`（`envEnabled` + `cpuFlags`）与 `f_util/src/crc32_native_arm.cj:159-186`（`envEnabled` + `cpuFlags`）**逐行相同**；`available` / `availableFor` / `update` / `call` / `setNativeEnabled` / `resetForTest`（`:86-157` vs `:68-127`）骨架一致
  - `f_util/src/crc16.cj:107-124`、`f_util/src/crc32.cj:93-126`、`f_util/src/crc64.cj:62-79`：同一个 `CrcEngine` 上的 `initRegister/update/finish/compute×3` 五件套，只有位宽与包装类型不同
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 跨文件复制」；判据要求点名语义差异
- **证据**：静态确定 —— 逐行比对后差异只有三处：`@When` 目标、CPU 能力探测函数（`pclmulqdq+ssse3` / `crc32` / `pmull`）、以及 CRC-64 的 `constsXz/Iso/Redis` 分组数量（x86 多一组 `constsNorm`）。其余（模式解析、开关、状态复位、错误回退）没有任何差异，属纯复制。
- **描述**：`@When` 让同一时刻只编译一份，所以这不是「编译两遍」的浪费，而是**漂移风险**已经发生：`ensureReady` 的返回值口径在 arm 版只认反射核（见 #14）、`envEnabled` 与 `parseMode` 两族语义不同（#10）、`resetForTest` 在三份里做的事都不一样（#11）。每次改开关语义都要记得改 4 个文件，而其中一个必然漏。`crc16/32/64` 的同构包装类风险较低（`crc32` 多了 `hwKind` 分派、`crc64` 没有），但同样属于「加一个 `crc8` 就再抄一遍」。
- **建议**：把与平台无关的部分（模式解析、`envEnabled`、开关/复位状态机、`lastNative`）抽到 `CrcGf.cj` 同级的平台无关类型（如 `CrcHwSwitch`），x86/arm 只保留 `hasXxx()` 与两份机器码数组；`Crc16/32/64` 的 `compute/update/finish` 可以用一个 `Crc<W>` 泛型包装消掉三份胶水（`Crc32.update` 的硬件分派作为特化）。抽取前先补 #10 的语义统一，否则会把错误口径复制到新类型里。

### [轻微][存量] #14 `crc64_native_arm.ensureReady` 只以反射核为准：normal 核分配失败/未就绪时被连坐，`available()` 与 `updateNormal()` 口径相反

- **位置**：`f_util/src/crc64_native_arm.cj:214-232`（`ensureReady` 返回 `fn.isSome()`）、`:144-151`（`updateNormal` 先 `if (!ensureReady()) return None`）、`:96-102`（`available` 返回 `fn.isSome() || fnNorm.isSome()`）；对照 `f_util/src/crc64_native_x86.cj:238-257`（返回 `fn.isSome() || fnNorm.isSome()`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致的行为漂移」（x86 与 arm 同一函数的返回口径不同）
- **证据**：静态确定 —— arm 版 `ensureReady` 先 `fn = make()`、`fnNorm = makeNormal()`，最后只返回 `fn.isSome()`。若 `REF_CODE` 的代码页分配/密封失败而 `NORM_CODE` 成功（`failAlloc` 会同时置两者失败，但 `mmap`/`mprotect` 失败可以是单次的），`available()` 返回 `true`（因为 `fnNorm.isSome()`），而 `updateNormal()` 因 `ensureReady()` 为 `false` 永远返回 `None` ⇒ 正常域核（`ecma182`/`we`）永远用不上，且外部无法从 `available()` 判断出来。x86 版没有这个问题。
- **描述**：结果不会算错（都回退表路径），但「`available()` 说有硬件、实际一次都没进」会让诊断与性能回归排查方向跑偏；两平台同一 API 行为不一致本身也是维护陷阱。
- **建议**：`ensureReady` 返回 `fn.isSome() || fnNorm.isSome()`，并把「反射核是否就绪」与「正常域核是否就绪」拆成两个判断（`update` 用前者、`updateNormal` 用后者），与 x86 版对齐；若按 #13 抽出公共开关类型，这条会自然消失。

### [轻微][存量] #15 `time:` / `number:` 分支的转义判断用 `template` 下标去查 `placeholder`，且错误文案是 copy-paste

- **位置**：`f_util/src/TextTemplate.cj:151`（number 分支 `template[formatEnd - 1]` 与「反斜杠字符」比较）、`:172`（time 分支同一行）、`:157`（number 分支抛的消息写成 `time format must be followed ...`，把「数字格式」写成了 time）、`:178`（time 分支同一消息，属正常）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「边界 / 语义与注释不符」、§2「近似重复（一块少了边界判断）」
- **证据**：静态确定 —— `formatEnd` 是相对 `placeholder` 的下标（`placeholder = template[start..end].trimAscii()`，`:137`），而这一行却在 `template` 上取 `formatEnd - 1`；只有 `start == 0` 且没有被 `trimAscii` 削掉前缀字符时两者才指向同一字符。占位符前有任何文本（如 `前缀 {number:...}`）时，读到的就是模板里另一个字符，「反斜杠 + 反引号」的转义判断随机成立/不成立 ⇒ 带转义反引号的格式串时而抛 `IllegalArgumentException`、时而把转义反引号留给 `Decimal` / `DateTime` 解析。`:157` 的文案则把数字格式的报错写成了 time。
- **描述**：`time:` 分支当前因 #1 已经全坏，这条在修 #1 时容易被一起带过，但它是独立的基址错误，修完 `replaceAll` 仍会留坑。
- **建议**：两处都改成 `placeholder[formatEnd - 1]`；`while` 条件里的 `placeholder.size` 保持不变（不要混用 `template.size`）；`:157` 的消息改成以 `number format must be followed ...` 开头。补用例：格式串本身含「反斜杠 + 反引号」的写法，以及占位符前后带空格、带前缀文本两种位置。

## 优化可行性方案

> 不是缺陷，是"还能更好"。全部**无性能基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `Crc32.update` 的 ISO 路径把整段前缀拷一份再交给机器码，改成传 `(data, aligned)` 与 CRC-64 对齐

- **现状**：`f_util/src/crc32.cj:97-104` 对 `hwKind == Iso` 先算 `aligned = data.size - data.size % 16`，然后 `Crc32Hw.update(CrcHwKind.Iso, crc, data[0..aligned])`。`data[0..aligned]` 是 `Array` 切片 ⇒ **新建并复制** `aligned` 字节；4 KiB 帧（`aligned = 4096`）就是每次 `update` 多分配并拷一份 4 KiB，随后机器码再读一遍。CRC-64 侧已经是「传整段 + 传处理长度」的形态（`crc64_native_x86.cj:148`、`:175-195` 用 `aligned` 参数 + `acquireArrayRawData`，零拷贝），说明这个改法在本仓库已被验证可行。
- **方案**：把 `Crc32Hw.update(kind, crc, data)` 改成 `update(kind, crc, data, aligned)`（x86/arm/stub 三份签名同步），x86 侧用 `aligned` 做 16 对齐检查，arm 侧忽略（其循环自带尾字节处理）；`Crc32.update` 传 `data` 与 `aligned` 原值，不再切片。测试里的直接调用点（`crc32_codegen_test.cj:202/206/224`）同步改签名。
- **预期**：每次 ISO-HDLC `update` 少 1 次 `Array` 分配与 `aligned` 字节 `memcpy`；4 KiB 帧上等于把「拷 4 KiB + 算 4 KiB」降为「算 4 KiB」，收益上限取决于 `memcpy` 在单次 4 KiB CRC（README 记的 475 ns 量级）中的占比。
- **代价**：内部签名变更（`Crc32Hw` 是 `internal` 类，不破坏对外 API）；需保证 `aligned <= data.size` 的校验从 `Crc32.update` 移到被调方。
- **验证**：同一机器、同 SDK、`-O2`，4 KiB × 10^5 次 `Crc32.isoHdlc.compute`，改前改后各 10 轮取中位数与 IQR；`cjprof heap` 对照分配字节数（应减少 ≈ 4 KiB × 次数）。等价性用 `Crc32.isoHdlc` 的全长度对拍（`crc32_codegen_test.cj:143-157` 已覆盖 0/1/3/15/16/17/…/65536）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ISO-HDLC 硬件路径每次 `update` 的 `data[0..aligned]` 整段拷贝可能吃掉相当一部分硬件收益（第 1 部分待验证 #1 已提出，本部分确认位置与机制，见 O1） | `f_util/src/crc32.cj:99-103` | 4 KiB 下单次拷贝耗时占 `compute` 的比例 | `cjpm bench -O2`：`compute(data)` vs 去掉切片版（`Crc32Hw.update(data, aligned)`），4 KiB × 10^5 次，中位数 + IQR |
| 2 | `Crc32Hw.ensureReady` 每次 `update` 都进一次 `Mutex`，多线程小包场景可能成为串行点（第 1 部分待验证 #2） | `f_util/src/crc32_native_x86.cj:159-179`、`f_util/src/crc32_native_arm.cj:129-144` | 8/16 线程下锁等待时长与吞吐曲线 | 多线程 4 KiB bench，对比 `F_UTIL_CRC_HW=0` 与 `=1` 两态；线程状态采样看 BLOCKED/WAITING 占比（CPU profile 看不出来） |
| 3 | `TextTemplate.compile` 在每条带参日志上都要拼一次缓存键（3 段字符串拼接 + 2 次 `size` 转十进制）再查 `ConcurrentHashMap`，可能是 `f_log` 的单次固定开销 | `f_util/src/TextTemplate.cj:69,80-82`；调用点 `f_log/src/base/Logger.cj:51` | 单次 `compile` 命中路径耗时占一条日志总耗时的比例 | `cjprof record` 跑日志压测（10 万条模板固定的日志，8 线程），看 `cacheKey` / `compile` 自耗时；与「调用方缓存编译结果」版本对照 |
| 4 | `TextTemplate` 静态缓存的条目增长率在真实 `f_log` 用法下可能远超「模板种类数」 | `f_util/src/TextTemplate.cj:54,68-75`；见 #6 | 24h 稳态负载下的条目数曲线与 RSS | 在 `compile` 命中/未命中处加计数埋点，跑 24h 观察条目数是否收敛；同时记 `getAllocatedHeapSize()` 与 RSS |
| 5 | `Crc64Hw.mode()` 无同步惰性初始化在首次并发 `update` 时的可见性问题（#11）在 x86 与 arm 上是否表现为重复 `getenv` 之外的行为（如 `modeState` 读到中间值） | `f_util/src/crc64_native_x86.cj:284-293`、`crc64_native_arm.cj:276-285` | 并发首次调用的实际行为 | 8 线程同时首次调用 `Crc64.xz.compute`，统计 `modeState` 观测值；或在 `mode()` 里加临时计数看 `parseMode` 被调次数是否 > 1 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/src/TextTemplate.cj` | .cj | ✅ | 见 #1（`time:` 格式恒为 `` ` ``）、#2（`regex:` 未实现）、#4（非十进制格式）、#5（空值兜底失效）、#6（缓存无界）、#7（空分隔符死循环）、#12（`mutex`/`Map`/`init(indexText:)` 死代码）、#15（转义基址错）；`cacheKey` 的长度前缀编码本身自洽 |
| 2 | `f_util/src/TextTemplateCacheKey_test.cj` | .cj | ✅ | 5 个用例覆盖「同模板串两种分隔符不串味」「重复编译同实例」「`placeholder` 重载」；断言与实现一致。**未覆盖** `time:` / `number:` / `regex:` 三条主干（#1/#2/#4/#5 因此无测试兜底） |
| 3 | `f_util/src/TreeTransformer.cj` | .cj | ✅ | 见 #9（孤儿 `parentId`）；`ignoreDuplicate` 分支、`map.add` 返回值判定（`isNone()` = 新插入）均正确；`transform` 的 4 个重载委托链无环 |
| 4 | `f_util/src/UInt128.cj` | .cj | ✅ | 见 #3（`fromBytes` 校验未抛）；`toBytes`/`fromBytes` 的大端布局自洽、`compare` 先高位后低位正确、`toString` 与 `tryParse` 对 16 字节输入可往返 |
| 5 | `f_util/src/Utils.cj` | .cj | ✅ | 见 #8（`computeBytes` 两处契约问题）；`41-55` 的单位分支是 9 段同构 if-else，可表驱动（未单列，属可读性） |
| 6 | `f_util/src/code_buffer.cj` | .cj | ✅ | 见 #12（`rawPointer` 恒等分支、`ptr` 可 `let`）；W^X 时序（RW → 写 → `mprotect` RX → `__clear_cache`）正确，`mmap` 失败判 `null` 与 `(void*)-1` 两种形态都覆盖，`write` 有边界检查；页常驻不 `munmap` 是文件头明示意图 |
| 7 | `f_util/src/crc16.cj` | .cj | ✅ | 24 个变体的参数与 RevEng 名字一致，`checkValue` 有 `crc_check_test` 兜底；三个 `compute` 重载委托正确，无缺陷 |
| 8 | `f_util/src/crc32.cj` | .cj | ✅ | 见 O1（ISO 路径整段切片）；`classifyHw` 与 `update`/`compute` 的分派正确、`compute` 走 `finish(update(init))` 与 `engine.compute` 等价；`jamcrc` 不加速属文档问题（第 1 部分 #4） |
| 9 | `f_util/src/crc32_codegen_test.cj` | .cj | ✅ | 覆盖 `CodeBuffer` 分配/密封、CRC32C 与 ISO 的黄金值/多长度/增量/回退/并发；`crc32HardwareRawMatchesSoftwareForUnalignedLengths` 用「探测 3 字节是否返回 None」区分 x86 与 arm 的对齐契约，做法正确。`setNativeEnabled` 的关闭/恢复都有配对 |
| 10 | `f_util/src/crc32_hw_kind.cj` | .cj | ✅ | 3 个无载荷枚举 + 手写 `==`/`!=`；与仓内其它枚举（如 `fprobe/src/collect/MetricProjection.cj:21-30`）写法一致，不判重复 |
| 11 | `f_util/src/crc32_native_arm.cj` | .cj | ✅ | 见 #10/#11/#12/#13；`getauxval(16) & (1<<7)` 判 `HWCAP_CRC32` 正确，`hasCrc32` 有 `/proc/cpuinfo` 回退，`update` 不要求 16 对齐（与 x86 契约不同，测试已区分） |
| 12 | `f_util/src/crc32_native_stub.cj` | .cj | ✅ | 空实现语义正确（`available`/`availableFor` 全 false、`update` 返 `None`）；**`@When` 覆盖缺口（缺 Linux 非 x86/arm）已在第 1 部分 #1 报告，本部分不重复**；其 `available()` 零调用见 #12 |
| 13 | `f_util/src/crc32_native_x86.cj` | .cj | ✅ | 见 #10（`envEnabled` 语义）、#11（`nativeEnabled` 无同步 + 注释与 `resetForTest` 不符）、#12（`available` 死代码）、#13（与 arm 版重复）；`acquireArrayRawData` / `releaseArrayRawData` 在 `try/finally` 内配对，机器码只处理 16 倍数且调用方已切好前缀 |
| 14 | `f_util/src/crc64.cj` | .cj | ✅ | 6 个变体参数与 RevEng 一致；`initRegister/update/finish/compute` 四件套是 `CrcEngine` 的薄包装（同构问题见 #13），无缺陷 |
| 15 | `f_util/src/crc64_native_arm.cj` | .cj | ✅ | 见 #14（`ensureReady` 只认反射核）、#10/#11/#13；指令字节与 `NORM_CODE` 长度关系、`constsXz` 兼作 normal 核常量（`:154`）与 x86 的 `constsNorm` 分组不同，但 `supportsNormal` 只认 `0x42F0…`，语义等价 |
| 16 | `f_util/src/crc64_native_stub.cj` | .cj | ✅ | `@When[os != "Linux" || (arch != "aarch64" && arch != "x86_64")]` 覆盖完整，是与 `crc32_native_stub.cj` 对比的正确范本；8 个静态入口与真实实现签名一致 |
| 17 | `f_util/src/crc64_native_x86.cj` | .cj | ✅ | 见 #10（`On` 无效果）、#11（`mode()` 锁外惰性初始化）、#13（与 arm 版重复）；`supports` / `constsXz/Iso/Redis` 与 `CrcEngine.update` 的 `refin && supports(poly)` 调用条件匹配（`:205`），四参数 ABI 与 `chandle` 获取/释放正确 |
| 18 | `f_util/src/crc_check_test.cj` | .cj | ✅ | 顶层 API 与变体一致性、24+11+6 个变体的检查值、增量 vs 一次算完、空输入 = `finish(init)`；`hex()` 的 nibble→ASCII 映射正确，无缺陷 |
| 19 | `f_util/src/exception/GeoHashException.cj` | .cj | ✅ | 4 个 `init` 委托 `BaseException`，`public` 类对外可达；`geohash.cj:126` 有真实使用。无缺陷 |
| 20 | `f_util/src/exception/HashException.cj` | .cj | ✅ | 同上；但仓内**唯一**使用点就是 `UInt128.cj:61` 那个被丢弃的构造（#3）——修 #3 补 `throw` 后它才真正被用上 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7（#1、#2、#3、#4、#5、#8、#9） | 正确性：#1–#5、#8、#9；设计：#6（缓存策略）、#13（平台无关逻辑与机器码混在一个文件）；语言特性：核对了 `Option` 解构（`if (let Some(x) <- …)`）、`match` 类型模式、`BigInt(sign, magnitude)`、`Array` 切片语义、`?String` 的 `isEmpty` 用法；安全：#1/#2 的 `replaceAll`/`regex()` 误用会接受运行期格式串（`Regex` 由外部模板构造，存在正则回溯面，但未发现可构造的灾难性回溯，`待确认`，未单列） |
| §1 死代码 | 1（#12） | 已逐个符号搜：`private` 的 `mutex`、`ValueGetter.init(indexText:)`、`CodeBuffer.ptr`（`sealed` 有真实使用，不判）、`Crc64Hw` 的静态入口（均被 `CrcEngine` 或测试使用）、`Crc32Hw.available()`（零命中）；`internal` 的 `CodeBuffer` 全部方法（`alloc/write/seal/rawPointer/pageSize`）都有调用；`public` 顶层 API 一律不判（`UInt128`、`Crc16/32/64`、`TreeNode`、两个异常类、`computeBytes` 仓内零引用只作信息）；`Value2String` 是 `sealed` 类，其 `protected format` 被 `:193` 调用、4 个子类的 `doFormat` 被 `:270-273` 调用，无死代码 |
| §2 重复逻辑 | 1（#13） | 同文件内两两比对了 `TextTemplate` 的 40+ 个函数体（`Value2*String.doFormat` 三份结构相似但格式化逻辑不同，非重复）、`crc16/32/64` 的 15 个方法（同构，#13）、CRC 四份 native 实现（#13）；跨文件比对了 `envEnabled`、`cpuFlags`、`mode/parseMode/isOff`、`resetForTest` 四组（逐行相同）；`Number`/`Time` 两个分支的格式解析结构相似但格式化目标不同，已在 #15 记录「近似重复导致一处少了边界判断」 |
| §3 空实现 | 0 | 逐文件核对：`Crc32Hw`/`Crc64Hw` 的 stub 是**条件编译**下的平台空实现（有明确注释与 `@When`，非「忘记覆盖」）；`CodeBuffer`、`TextTemplate` 无空函数体；本部分无 `TODO`/`FIXME`；无 `catch (_: Exception) {}` 吞异常（`cpuFlags`/`hasPclmul` 的 `catch` 返回 `""`/`false` 是探测降级，有语义）。#5 的「兜底写了但被丢弃」按 §3 的反向形态记在「发现」而不是本节 |
| §4 栈溢出 | 0 | 本部分无递归：`TextTemplate.doCompile` 是 `while` + 闭包（闭包不递归），`Value2String.format` 是单层类型分派，CRC 全为循环，`TreeNode` 无递归遍历（只做一层父子装配）。`computeBytes` 的两个重载是委托不是递归 |
| §5 OOM | 2（#6、#7） | #6 缓存无容量/无淘汰（键含模板原文）；#7 空分隔符导致 `compiled` 无限增长。其余：`CodeBuffer.alloc` 按页向上取整、`size <= 0` 返回 `None`；CRC 的临时对象是常量大小；`UInt128.toBytes` 固定 16 字节。`TextTemplate` 的 `ArrayList` 无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`f_util/doc/perf/crc32-codegen.md` 与 README 的 ns/MB·s 数字是变更当时的测量，无法归因到本部分代码行，全部转「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | 唯一的锁是 CRC 四份 native 实现的 `ensureReady` 静态 `Mutex`（临界区只做 CPU 探测 + `mmap` + 改静态字段，无 I/O 阻塞、无日志、无回调），竞争频率无数据，见待验证 #2；`TextTemplate` 的 `Mutex` 字段已无使用（#12） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列（`crc32_codegen_test` 的 4 线程用例是测试自身）；未发现「提交后立即 get」 |
| §6.4 低效算法 | 0 | 未发现 `remove(at:0)` 当队列、热点 `contains`、循环拼串。`TextTemplate.doCompile` 每轮 `indexOf` 从当前位置续扫，整体 O(n)；`ValueGetter.get` 的 `TypeInfo.of(data).qualifiedName` 每次取值算一次（`TextTemplate.cj:245-248`），属常数开销，无数据不列为低效 |
| §7 降堆内存方案 | 0 | 本部分可降的对象是 O1 的整段切片（记为 CPU 方案，机制同时减少一次分配）；`TextTemplate` 缓存条目属 #6 的有界化建议，不是「还能更省」；其余临时对象都是标量/常量大小 |
| §8 降 CPU 方案 | 1（O1） | 无基线，只列方案 |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内销毁的大对象图」：`TextTemplate.format` 的 `StringGenerator` 与结果 `String` 都逃逸；`Value2NumberString` 的 `Decimal`/`BigInt` 是 std 类型且无 mode 重载（checklist §9 约束 3）；CRC 的 `acquireArrayRawData` 拿的是调用方数组的裸指针，改成 local region 反而破坏「输入不复制」的前提。收益只能用峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 9（#1–#5、#8、#9、#10、#11） | 逐函数过了边界/空值/错误处理/资源/并发/契约六项：#1–#5（TextTemplate）、#8（Utils）、#9（TreeTransformer）、#10/#11（CRC 开关）。CRC 计算路径（`crc16/32/64` + 四份 native + `crc_check_test`）边界（0/1/15/16/17/4095/4096/65536）已由测试覆盖且我逐条核对了分派与尾部处理，未发现缺陷；`UInt128` 的 `hashCode` 用 `(left ^ right).toInt()` 只保留低位，属容器性能与碰撞率问题（无数据，不单列） |
| §12 并发安全与锁粒度 | 1（#11） | 逐项核对：`TextTemplate` 的 `templates` 是 `ConcurrentHashMap` + `computeIfAbsent`（同一 key 只构造一次，`compiled` 在发布前写完，实例发布后只读）；`CodeBuffer` 实例构造后 `sealed` 只按 false→true 单向变化，且只在初始化线程上写；`Crc32Hw`/`Crc64Hw` 的 `ready`/函数指针/`codes` 都在 `Mutex` 内写，读在 `ensureReady()` 之后（有 mutex 的释放-获取建立可见性）；**例外**是 #11 列的 `mode()/lastNative/forcedOff/nativeEnabled`，已单列 |
| §14 功能完备性与 README 覆盖 | 2（#2、#10） | #2：README/类注释承诺的 `regex:` 占位符没有入口；#10：`F_UTIL_CRC_HW=on` 这个「已接线」的配置项实际无效果（`On` 只在 `modeNameForTest()` 出现）。`Crc16/32/64` 的 `name`/`checkValue` 未进 README 属次要参数（第 1 部分已记录）；本部分其余 `public` 符号（`UInt128` 全套、`computeBytes`、`TreeNode`、`CrcHwKind` 枚举）在 README 中是否逐项覆盖由第 1 部分负责核对 |
| §13 文档一致性 | 0（本部分无 `.md`） | 本部分 0 个 `.md`；引用到的三份文档只作证据：`fix-text-template-cache-key/design.md:51`（称 `Mutex` 用于其它路径，实际未用 → 并入 #12）、`design.md:61`（缓存无上限属已知问题 → #6）、`CrcGf.cj:24`（`on` 强制尝试 → #10）。文档与实现的系统性对照见第 1 部分 |
| 文件覆盖 | 20/20 | 与 `files/f_util.part3.txt` 逐行对应，无缺失（见上表） |

### 范围外提示（不计入本部分统计，供对应部分复核）

1. `f_util/src/crc32_native_stub.cj:23` 的 `@When` 缺 `Linux && arch ∉ {x86_64, aarch64}`，与 `crc64_native_stub.cj:24` 不一致——已由第 1 部分 #1 报告，本部分不重复。
2. `f_util/src/TextTemplate.cj:35-36` 的类注释仍宣称依赖 `ThreadLocalStringBuilder`（该依赖已不存在）——已由第 1 部分 #7 报告（README 侧）；类注释这一处是同源残留，建议与文档一并删。
3. `f_util/src/MurmurHash3X128.cj:23` 的 `HashException` 是未使用 import——已由第 2 部分 #17 报告；修本部分 #3（`UInt128.fromBytes` 补 `throw`）不会影响它。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 8 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量缺陷 15 条（严重 3 / 一般 8 / 轻微 4），按规则只报不修，是否纳入修复待用户决定。本部分未改动任何源码。

## 总评

本部分的风险分布很不均匀，可以分成三块看：

- **`TextTemplate`（495 行）是本轮 f_util 最需要优先处理的文件**：三条主干能力里，`time:` 输出错值（#1）、`regex:` 根本没实现（#2），`number:` 的非十进制分支符号/宽度/大小写三处都错（#4），空值兜底是死语句（#5），再加上缓存无界（#6）与空分隔符死循环（#7）。`TextTemplateCacheKey_test` 的 5 个用例全部围绕「缓存键是否串味」，一条都没有覆盖占位符语义——这正是上述缺陷能长期存活的原因。建议按「补语义用例 → 修 #1/#2/#4/#5 → 加有界缓存」的顺序做，#6/#7 可以并行。
- **CRC 子系统的算法实现是可靠的，问题在开关与平台胶水**：`crc16/32/64` 的变体参数、硬件分派、尾部补齐都正确，`crc_check_test` 用 RevEng 检查值把 41 个变体钉死了，`crc32_codegen_test` 连「非对齐长度」都按平台契约分开断言，质量高于本模块平均水平。真正的债是把「模式解析 / 开关状态」抄了四份（#13），抄的过程中出现了语义分叉（#10）与口径分叉（#14），并且热路径上的 `mode()` 是无同步惰性初始化（#11）。这些都不会算错 CRC，但会让「关掉硬件 / 确认是否走了硬件」这类运维动作失效。
- **`UInt128` / `Utils` / `TreeTransformer` 三个小工具各有一处「契约写好了、实现没接上」**：`fromBytes` 的校验没有 `throw`（#3，最严重，会让 128 位键静默错值）、`computeBytes` 对三种合法输入抛异常且从不返回 `None`（#8）、`transform` 把数据不完整表现成 `NoneValueException`（#9）。三者都是 `public` 且都被下游当基础件使用，修复成本很低，建议随 #1 一起做。

阻塞项只有 #1–#3：`time:` 全坏、`regex:` 缺失、`UInt128` 静默错值，都属于「按文档用就出错 / 出了错看不出来」。其余一般项（#6–#11）是稳定性与可运维性问题，可排期；#12–#15 是清理与对齐。性能方面本部分没有任何可复核的测量，唯一的具体机制收益是 O1（ISO 路径整段拷贝），已按「待验证假设」处理，未写成结论。
