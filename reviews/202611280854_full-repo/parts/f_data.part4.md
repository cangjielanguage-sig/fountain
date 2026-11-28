# f_data 模块审查报告

> **模块第 4/8 部分**（本报告只覆盖 `files/f_data.part4.txt` 列出的 20 个文件，全部为 `.cj`：`src/json/DataJson.cj` → `src/path/CountFilterResult.cj`。`README.md` / `README_en.md` / `doc/**` 与其余 107 个 `.cj` 由同模块其他部分产出；本部分编号独立，合并时以主 Agent 为准。README 只作为取证判据被引用，不计入本部分「文件覆盖」。同模块第 3 部分已报的 `CompiledSchema` 共享 `pattern` 表写入问题（`parts/f_data.part3.md` #4）不再重复计数，只在描述里交叉引用。）

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 20 个 `.cj`，0 个 `.md`；模块共 127 `.cj` + 15 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 只有 `docs/review/` 与 `reviews/` 未跟踪，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：JSON / 数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 4/8 部分）

## 发现

### [严重][存量] #1 深嵌套 JSON 解析无深度上限：`fromJson` 逐层递归，网络入参可直接把进程栈打爆

- **位置**：`f_data/src/json/JsonValue.cj:165-212`（`fromJson` 的 `BeginArray` 分支 `180-187`、`BeginObject` 分支 `192-204` 各自递归调用 `fromJson(reader)`）；同源递归下游：`JsonValue.cj:127-152`（`toJson` 写数组/对象逐层递归）、`JsonSchemaValidator.cj:743-780`（`jsonEquals` 递归）
- **来源**：存量（`git blame -L 165,175` → `6ba7695863 2026-07-03 runningW`）
- **判据**：review-checklist §4（无界递归、深度由输入决定、无环检测/无深度上限）
- **证据**：静态确定 —— ①`fromJson` 每遇到一层 `BeginArray`/`BeginObject` 就多一帧，递归深度 = JSON 嵌套层数，代码里没有任何 depth 参数或常量上限（对比同模块请求期校验有 `ValidationOptions.maxDepth = 64`，`JsonSchemaValidator.cj:61`）；②输入完全外部可控：`JsonRpcServer.cj:108` 用 `JsonValue.fromBytes(body)` 解析 HTTP 报文，`f_http/src/TextMediaType.cj:112` / `121`、`f_mcp/src/client/McpClient.cj:234` 同样；③上游只有**字节数**限制（`JsonRpcServer.cj:95-101` 的 `maxBodyBytes`），没有嵌套层数限制，1 MB 全 `[` 即 100 万层。
- **描述**：构造 `[[[[…` （几千层即可，无需 1 MB）就让 `fromJson` 递归到栈耗尽，进程直接崩溃且不可被 `catch (_: Exception)` 拦住——`JsonRpcServer.cj:104-108` 的 try 包不住栈溢出。同一份数据只要被打印（`toString` → `toJson` 递归）或在 `enum`/`uniqueItems` 里比较（`jsonEquals` 递归）也会二次踩踏，因为解析阶段没有拒绝路径。这是本部分唯一"外部输入 → 进程崩溃"的路径。
- **建议**：给 `fromJson` 加 `depth: Int64 = 0` 与上限（与 `ValidationOptions.maxDepth` 对齐，默认 64/128），超限抛 `JsonException('nesting too deep at depth N')`；`toJson`/`jsonEquals` 复用同一上限（值来自已解析树时可断言已受限）。补两条用例：`'['.repeat(1000)`、`'{"a":'.repeat(1000)` 都必须抛 `JsonException` 而不是崩溃。

### [严重][存量] #2 解析路径永远产出 `JsonDecimal`，任何 `"type":"integer"` 的 schema 校验必然失败

- **位置**：`f_data/src/json/JsonValue.cj:173-174`（`case JsonNumber => JsonDecimal(reader.readValue<Decimal>())`，全文没有 `JsonInt` 的产生点）；判定侧 `f_data/src/json/JsonSchemaValidator.cj:714`（`case 'integer' => value is JsonInt`）；schema 生成侧 `f_data/src/json/JsonSchema.cj:49`（`Int8..UInt64` 一律生成 `"type":"integer"`）
- **来源**：存量（`JsonValue.cj:174` → `6ba7695863 2026-07-03`；`JsonSchemaValidator.cj:714` → `e153677c93 2026-10-24`）
- **判据**：review-checklist §11（契约与实现不符、同一语义两处不一致）、§10（正确性）
- **证据**：静态确定 —— ①`JsonValue` 的生产路径只有两条：`fromJson`（`JsonValue.cj:156-212`）与 `JsonValue.from(Data, flag)`（`ExtendJson.cj:70-156`）。`fromJson` 的 `JsonNumber` 分支无条件包成 `JsonDecimal`，一条 `JsonInt` 都不产生；只有 `ExtendJson.cj:122-126` 的 `DataReal` 分支（`data.isInteger()`）会造 `JsonInt`。②`matchesType('integer')` 只认 `JsonInt`，而 `matchesType('number')` 认两者——同一函数内部对"整数属于数字"的判断是不对称的；`jsonEquals` 反而专门写了 `(JsonInt, JsonDecimal)` 交叉比较分支（`743-751`），说明作者知道两者可表示同一数值。
- **描述**：任何"值来自 JSON 文本、schema 来自 `@JsonIntSchema`/`toJsonSchema`"的组合都会得到 `expected type [integer], got number`。仓内这条路是接通的：`f_mcp/src/server/McpTool.cj:69` 与 `McpRegistry.cj:91` 用 `JsonObject.toJsonSchema<T>()` 生成工具入参 schema（`JsonSchema.cj:49` 对 Int 字段写 `"integer"`），`f_mcp/src/server/McpServer.cj:630` 用 `JsonSchemaValidator.validate(tool.inputSchema, arguments)` 校验客户端传来的 `arguments`（来自 JSON-RPC 报文解析）。即：只要某个工具参数类里出现 `Int64`/`Int32` 字段，该工具的所有调用都会被判 `-32602 Invalid params`。当前仓内工具参数类普遍把数量写成 `String`（如 `f_llm/src/loom/ToolFunctions.cj:78-85` 的 `topK: String`），所以线上是否已触发需核对调用方，**缺陷本身是静态确定的**。
- **建议**：二选一并补用例——①`matchesType` 里 `'integer'` 改成 `value is JsonInt || (value is JsonDecimal && value.asDecimal().value.isInteger())`（与 `jsonEquals` 的交叉比较对齐）；②或在 `fromJson` 解析数字时按"无小数点/指数"判成 `JsonInt(BigInt)`。无论哪种，都要加一条"`JsonValue.fromStr("5")` 校验 `{"type":"integer"}` 通过"的回归用例。

### [一般][存量] #3 `ExtendJsonValue.fromReader` 把整条流按行累积进 `ByteBuffer` 再整块解析：无上限 OOM，且两份实现逐行同构

- **位置**：`f_data/src/json/ExtendJson.cj:28-36`（`fromReader<I>`）与 `37-45`（`fromReader(TextReader)`，函数体逐行相同，仅参数类型不同）
- **来源**：存量（`git blame -L 28,45` → `6ba7695863 2026-07-03`）
- **判据**：review-checklist §5（一次性物化、无拒绝路径）、§2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 循环 `while (let Some(line) <- reader.readln()) { writer.writeln(line) }` 把**全部**行写进同一个 `ByteBuffer`，随后 `buffer.bytes()` 再取一份完整字节数组（`Std` 的 `ByteBuffer.bytes()` 返回拷贝），最后 `JsonValue.fromBytes` 建整棵树。峰值 ≈ 输入 N 字节 × 2（缓冲 + 拷贝）+ 解析树；`ExtendJsonValue.fromInput`（`25-27`）也走这条路径。入口没有任何大小上限或分块，`JsonValue.fromInput`（`JsonValue.cj:162-164`）本来是流式入口，这里却先退化成全量读。
- **描述**：`JsonValue.fromInput(inputStream)` 被当成"流式解析"使用时，实际先把整个流读进内存再解析；对不可信长度的输入（HTTP body、文件、socket）没有拒绝路径，只有到 OOM 才知道。`readln`/`writeln` 还会把行分隔符规范化：JSON 字符串里若含裸换行（非法 JSON，但常见于手写配置文件），内容会被改写。
- **建议**：`fromInput` 直接 `fromJson(JsonReader(input))`（`JsonValue.cj:162-164` 已经这么写），删掉 `fromReader` 的全量物化；若必须保留 `TextReader` 入口，改成把 `TextReader` 包成 `InputStream` 交给 `JsonReader` 增量读，或至少加 `maxBytes` 参数 + 超限抛 `JsonException`。两份 `fromReader` 合并成一份泛型实现（或一份委托另一份）。

### [一般][存量] #4 `avg()` 对空数组除零：`IllegalArgumentException` 穿透过滤器

- **位置**：`f_data/src/path/AvgPathNode.cj:24-34`（`var c = 0` → 循环累加 → `r / Decimal(BigInt(c))`）
- **来源**：存量（`git blame -L 24,34` → `4be871f2fd 2026-10-02 runningW`）
- **判据**：review-checklist §11（空集合未处理、除零）、§10（边界）
- **证据**：静态确定 —— 分支进入条件是 `case x: Iterable<Data>`，空集合也是 `Iterable<Data>`；此时循环一次都不执行，`c == 0`，`Decimal / Decimal` 在除数为 0 时抛 `IllegalArgumentException`（`stdlib/doc/libs/std/math_numeric/math_numeric_package_api/math_numeric_package_structs.md:5237-5261`，异常说明在 `5259`）。同一文件对"元素不是 `DataReal`"的处理是 `return OptionIterator<Data>()`（`31`），说明本意是"算不出来就返回空迭代器"，空集合这条路径漏了。
- **描述**：`$..avg(@.items)` 一类表达式在 `items` 为空数组时抛异常，而不是返回"无结果"。异常会一路穿到 `DataPath.get` 的调用方（`DataFilter.check` / 业务查询），把"空数组"变成 500。空数组是常态数据，不是脏数据。
- **建议**：`if (c == 0) { return OptionIterator<Data>() }` 放在除法之前；同时把 `c` 的类型统一成 `Int64` 并用 `Decimal(c)`（当前 `Decimal(BigInt(c))` 多一次 `BigInt` 装箱）。补测试：`avg` 对 `[]`、对含非数字元素的数组都返回空迭代器。

### [一般][存量] #5 `DataObject`/`DataCollection`/`DataMap` 的 `toJsonString` 用 `case _ => continue` 静默丢成员：`JsonValue.toData()` 的产物一旦嵌套就会被整条抹掉

- **位置**：`f_data/src/json/DataJson.cj:110-113`（对象字段）、`130-133`（数组元素）、`149-152` 与 `174-177`（map 键值对）
- **来源**：存量（`git blame -L 106,124` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（静默失败 / 数据丢失）、§3（`case _` 兜底把错误吃掉）
- **证据**：静态确定 —— `ToJsonString` 的实现只出现在 `DataJson.cj`：`DataBool`（70）、`DataDateTime`（76）、`DataDuration`（82）、`DataNone`（88）、`DataString`（94）、`DataReal`（100）、`DataObject`（106）、`DataCollection`（126）、`DataMap`（144）、`DataConcurrentMap`（169）。全仓 `grep ToJsonString` 除这些之外只命中测试注释，即 **`DataAny`、`DataJsonArray`、`DataJsonObject`、`DataInputStream`、`DataTuples`、`DataUnit` 都没有实现**（后三者存在性见 `f_data/README.md:803-804`）。而 `DataJsonArray`/`DataJsonObject` 正是 `JsonValue.toData()` 的产物（`ExtendJson.cj:65-66`）。
- **描述**：`JsonValue.fromStr(body).toData()` 得到一个 `DataJsonObject`（`fdemo/boot/src/LogMediaType.cj:66`、`fprobe/src/collect/JsonData.cj:30` 都这么用）。把它放进 `DataObject` 的某个 `Data` 字段或 `DataMap<String, Data>` 的值里再序列化时，`case x: ToJsonString` 不匹配 → `continue` → 这个成员/这条键值对**整条消失**，JSON 仍然合法、不报错。数据被静默裁剪比抛异常更难排查。
- **建议**：`case _ => throw JsonException('type ${TypeInfo.of(value)} is not JSON serializable')`，或给 `DataJsonArray`/`DataJsonObject`/`DataAny` 补 `ToJsonString` 实现（前两者可直接复用 `json.toString()`）。若确实想"跳过不可序列化成员"，必须打日志并在 README 写明。

### [一般][存量] #6 `DataJsonArray.parse` / `DataJsonObject.parse` 不校验 JSON 类型，错误消息却承诺"解析成该类型"

- **位置**：`f_data/src/json/ExtendJson.cj:182-187`（`DataJsonArray.tryParse/parse`）、`216-221`（`DataJsonObject`，两段逐行相同，仅 `TypeInfo` 不同）
- **来源**：存量（`git blame -L 182,188` → `6ba7695863 2026-07-03`）
- **判据**：review-checklist §11（语义与命名/注释不符、契约与实现不符）、§2（重复逻辑导致漂移）
- **证据**：静态确定 —— `tryParse` 的实现是 `JsonValue.fromStr(s).toData()`，返回类型写的是 `?Data`（不是 `?DataJsonArray`），里面没有任何 `case x: DataJsonArray` 判断；`parse` 的 `getOrThrow` 只在 `tryParse` 返回 `None` 时触发，而 `toData()` 对任何合法 JSON 都返回非 `None`（`ExtendJson.cj:58-69` 的 `match` 覆盖全部 7 个 `JsonValue` 子类，`case _` 只在新增子类时抛 `UnreachableException`）。
- **描述**：`DataJsonObject.parse('[1,2]')` 成功返回一个 `DataJsonArray`，静态类型却是 `Data`，调用方 `as DataJsonObject` 会在运行期失败；`DataJsonArray.parse('{"a":1}')` 同理。错误消息 `'${s} cannot be parsed to ${TypeInfo.of<DataJsonArray>()}'` 永远不会出现——承诺的校验不存在。同一对函数在 `DataJson` 里还有两份完全相同的实例，属同一根因。
- **建议**：`tryParse` 返回 `?DataJsonArray`：`match (JsonValue.fromStr(s)) { case a: JsonArray => Some(DataJsonArray(a)); case _ => None }`，`parse` 沿用 `getOrThrow`；`DataJsonObject` 一份同样改。顺带把两处 `tryParse/parse` 抽成一个泛型 helper（`TypeInfo` + 构造器两参数），消除字面量复制。

### [一般][存量] #7 宏生成的 `==` 先比缓存哈希：`__hAsh__` 首次计算后不随字段变更失效，字段相同的两个实例会判不等；写入也无同步

- **位置**：`f_data/src/macros/DataAssist.cj:344`（生成 `private var __hAsh__ = 0`）、`348-356`（`if(__hAsh__ == 0){ … __hAsh__ = hasher.build() }`）、`392`（`var eq = quote(f_data_hash_eq(this, other))`）、`433-435`（生成的 `operator ==` = `refEq(this, other) || (f_data_hash_eq(...) && 逐字段 eq)`）
- **来源**：存量（`git blame -L 344,356` / `-L 392,392` / `-L 433,435` 全部 → `4be871f2fd 2026-10-02 runningW`；`localEq` 段由 `37ba87e5f5 2026-11-21` 追加，不改变本条的 `==` 路径）
- **判据**：review-checklist §11（契约违反：`==` 与逐字段比较不等价）、§12.1（惰性初始化/可见性、共享可变状态无保护）
- **证据**：静态确定（触发需要"先比较过、后改字段"的时序）—— ①`f_data_hash_eq` 就是 `a.hashCode() == b.hashCode()`（`f_data/src/base/data_cmp.cj:38-49`），注释自称"哈希快筛"，只有当哈希是字段的纯函数时才成立；②`hashCode()` 把结果永久缓存进 `__hAsh__`，`@DataAssist` 生成的字段都是 `var`（`generateProps` 还专门给可变字段生成 setter，`DataAssist.cj:231-240`），字段变更后缓存不失效；③因此 `a == b` 会在 `hashCode(a) != hashCode(b)` 时**直接返回 false**，即使逐字段比较全相等。④同一字段还被多线程无同步地读写（`if(__hAsh__ == 0)` 是典型检查-然后-写入，`Int64` 非原子保证）。
- **描述**：任何"先当 map key / 先比较过、之后修改字段"的对象，后续判等会得到与字段内容矛盾的结论（`==` 假、`compare` 真、`toJson` 相同），把它放进 `HashSet`/`HashMap` 后表现为"查不到自己"。并发下最坏情况是重复计算（两个线程都算一遍），极小概率读到撕裂值。
- **建议**：去掉 `==` 里的 `f_data_hash_eq` 快筛（逐字段比较才是语义），或去掉 `__hAsh__` 缓存（`hashCode` 每次现算）；若必须保留缓存，至少在 `==` 里改成"哈希不等 ⇒ 仍然走逐字段比较"。并发面用 `AtomicInt64` 或 `synchronized` 包裹惰性初始化，并把哨兵值从 `0` 换成"未初始化标志"（当前若真实哈希为 0 会每次重算）。

### [一般][存量] #8 `JsonObject.toJsonSchema` 的容器分支：`items` 传的是容器类型自身，Map/Deque 等容器没有分支

- **位置**：`f_data/src/json/JsonSchema.cj:176-184`（`else if(fieldType is ClassTypeInfo){ property.add('items', toJsonSchema(fieldType)) }`）；容器类型白名单 `153-159`；兜底 `186-187`
- **来源**：存量（`git blame -L 176,188` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §14.1（只做了一半的分支）、§11（生成结果与类型不符）
- **证据**：静态确定（`Array<T>` 是否为 `ClassTypeInfo` 需确认，见下）—— ①`toJsonSchema(fieldType)` 命中的是 `197-244` 的对象重载，第一件事就是 `schema.add("type", JsonString("object"))`（`199`），因此 `Array<Int64>` 的 `items` 会变成 `{"type":"object", "properties":{}}`，而不是整型 schema；②白名单只有 `Array`/`ArrayList`/`List`/`Set`/`HashSet`/`TreeSet`（`153-159`），`HashMap`/`Map`/`Deque`/`ArrayDeque`/`Queue` 全部落到 `186-187` 的 `return toJsonSchema(fieldType)`，同样得到一个 `{"type":"object","properties":{}}` 的"对象" schema。缺的信息：`Array<Int64>` 的 `TypeInfo` 在仓颉里是否 `is ClassTypeInfo`（若不是，则只表现为"没有 items"，不会产出错误 items）。
- **描述**：带 `@JsonArraySchema[...]`（未写 `items`）的数值/字符串数组字段，生成 `items: {"type":"object"}` ⇒ 每个元素都判 `type` 不符，**合法数据被拒**；`HashMap<String,Int64>` 字段被当成对象 ⇒ 任意内容都通过（约束消失）。`toJsonSchema` 是 `f_mcp` 工具 schema 的唯一来源（`McpTool.cj:69`），生成的错 schema 会直接变成客户端看到的 tool 定义。
- **建议**：`items` 分支改用 `genericType`（`180` 已经算出来了）而不是 `fieldType`；容器白名单改成"按 `TypeInfo` 的泛型实参数量分派"，并补 `Map`/`HashMap`/`TreeMap` → `{"type":"object","additionalProperties": <value schema>}`、`Deque`/`ArrayDeque` → `{"type":"array"}`。补 `JsonSchema_test`：`Array<Int64>`、`HashMap<String,Int64>` 两个字段生成的 schema 断言 `items.type == "integer"` / `additionalProperties.type == "integer"`。

### [一般][存量] #9 `hasDuplicates` 是 O(n²) 且随元素结构放大：1000 项上限内可直接打出 10⁸ 级比较

- **位置**：`f_data/src/json/JsonSchemaValidator.cj:731-741`（双层循环 + `jsonEquals`）；调用点 `314-319`（文档版）与 `536-541`（注解版），两处都用 `value.size > 1000` 作为"跳过"阈值
- **来源**：存量（`git blame -L 731,741` 属 `e153677c93 2026-10-24`）
- **判据**：review-checklist §6.4（双层循环做去重、复杂度代价）、§5（按不可信长度做平方级工作）
- **证据**：静态确定 —— 阈值 1000 意味着最大允许 n=1000，比较次数 1000×999/2 ≈ 4.99×10⁵ 次 `jsonEquals`；`jsonEquals` 对数组/对象是递归逐元素比较（`743-780`），因此元素本身是 m 项数组且内容相同时，单次比较 O(m)，总量 ≈ 5×10⁵ × m。嵌套 1000×1000 的请求体在 1 MB 量级即可构造（`maxBodyBytes` 拦不住）。
- **描述**：`uniqueItems: true` 的 schema 由服务端作者写入，但**被校验的数据**来自客户端；数组元素是对象/数组时，一次 `/tools/call` 就能让单个请求占满一个核上百毫秒到数秒，且这是"合法请求"。当前实现没有时间预算，也没有"结构型元素直接跳过"的判断。
- **建议**：先给 `JsonValue` 加 `hashCode`（按 `kind` + 内容）或提供 `canonicalString()`，用 `HashSet<String>`/`HashSet<Int64>` 去重把复杂度降到 O(n)；退一步至少对"元素是 `JsonArray`/`JsonObject`"的集合直接 `ctx.skip(path, 'uniqueItems')`（与现有 >1000 跳过的策略一致）。

### [一般][存量] #10 `CmpFilter` 对数值每次 `check` 都重新 `Decimal.parse(right.toString())`，解析失败直接抛异常

- **位置**：`f_data/src/path/CmpFilter.cj:48-51`
- **来源**：存量（`git blame -L 48,51` → `4be871f2fd 2026-10-02 runningW`）
- **判据**：review-checklist §11（错误处理缺失、异常穿透过滤器）、§6.4（同一输入重复解析）
- **证据**：静态确定 —— `case x: DataReal => let dRight = Decimal.parse(right.toString())`：`right` 在编译期就是字面量（`DataPath.cj:497-545` 生成的 `CmpFilter<String|Int64|Float64>`），但解析被放在 `check` 里，即每个数据行解析一次；同时这一分支不像其他三个分支那样用 `case x: T` 兜住类型，`right` 是 `String` 且内容非数值时（`@.price < 'abc'`）`Decimal.parse` 抛 `IllegalArgumentException`，异常穿出 `DataFilter.check`。
- **描述**：①异常语义不一致：同一个过滤器，字符串左值类型不符返回 `false`（`52-57`），数值左值字面量非法则抛异常；②每行重复解析字面量，属纯浪费（量级需实测，见待验证假设 #3）。
- **建议**：`CmpFilter` 增加一个"预解析"构造参数（在 `DataPath` 编译期把 `right` 解析成 `Decimal`/`T` 各一份，失败则在编译期抛 `DataException`），`check` 里只做比较；`DataReal` 分支补 `case x: T => … case _ => false` 的类型判定，保持与另外三个分支一致。

### [一般][存量] #11 `toJsonSchema(TypeInfo)` 两级回退都失败时静默返回空 `properties`：吞掉 `InfoNotFoundException` 后 schema 变成"什么都通过"

- **位置**：`f_data/src/json/JsonSchema.cj:216-238`（`try { … } catch (_: InfoNotFoundException) { ArrayList<ReadableField>() }` ×2，末尾 `case _ => ()`）
- **来源**：存量（`git blame -L 216,238` → 部分行 `4be871f2fd 2026-10-02`，`try/catch` 结构同批）
- **判据**：review-checklist §3（静默吞异常、`case _ => ()` 把错误吃掉）、§11（错误处理缺失）
- **证据**：静态确定 —— ①第一级 `getStaticFunction('dataFields')` 取不到就换成空 `ArrayList<ReadableField>()`；②第二级 `getStaticFunction('mutableFields')` 同样处理；③两级都拿不到时落到 `232-238` 的 `case fields: Iterator<MutableField>` 不匹配 → `case _ => ()`，`properties` 保持空对象；④公开重载 `toJsonSchema(typeInfo: TypeInfo)`（`197`）没有 `T <: ObjectData<T>` 约束，任何 `TypeInfo` 都能进来。
- **描述**：对没有字段表的类型（普通 `class`、容器、`@Bean` 未生成字段表的情况），返回 `{"type":"object","properties":{}}`——用它当校验 schema 等于"放行所有成员"，而且调用方拿到的是一份看起来正常的 schema，没有任何错误信号。这正是 `CompiledSchema` 注册期"脏 schema 启动即失败"想避免的形态，只是换到了生成侧。
- **建议**：两级都取不到时抛 `DataException('type ${typeInfo.qualifiedName} has no dataFields/mutableFields; cannot build schema')`；`catch` 只捕获 `InfoNotFoundException` 是合理的，但要在两个 `case _` 上区分"没有字段"与"字段表类型不对"。

### [一般][存量] #12 `generateToFields` 的主构造宏展开分支：`isPublic` 判定指向错误的声明，循环末尾还会给每个参数重复追加一次字段

- **位置**：`f_data/src/macros/DataAssist.cj:584`（`case x: PrimaryCtorDecl where isPublic(d)`——`d` 是外层循环的 `MacroExpandDecl`）、`595`（`case x: FuncParam where x.isMemberParam() && isPublic(p)`——`p` 是参数自身）、`598`（`appendExpr(p.paramType.toTokens(), isVar(p))` 在 `match` 之后、`for` 之内，对每个参数无条件再追加一次）
- **来源**：存量（`git blame` 该段属 `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（变量用错导致语义与命名不符）、§1（不可达/恒真假分支）、§2（同一件事做两遍）
- **证据**：待确认 —— 静态部分已确定：`598` 行位于 `for (p in x.funcParams)` 循环体内且在 `match` 之外，任何走到 `584`/`595` 分支的参数都会被执行两次 `appendExpr`（一次带正确类型与名字，一次用外层 `d` 的标识符与 `p.paramType`）；`584` 的 `isPublic(d)` 检查的是被宏修饰的那个声明（可能是 `VarDecl`/`PropDecl`），不是主构造；`595` 的 `isPublic(p)` 检查的是参数自身而非构造器。缺的信息：仓内是否存在"主构造本身由别的宏展开"的 `@DataAssist[fields]` 类（当前 `grep` 未找到用例，此分支可能从未被执行，因此生成的重复字段项未被暴露）。
- **描述**：一旦触发，`dataFields()` 的字段数组里会出现重名条目（`ObjectFields` 用 `HashMap` 落表，后者覆盖前者，`f_data/src/base/ObjectFields.cj:26-73`）或指向外层声明名的错误条目；若外层声明不是字段，生成的 `o.<name>` 访问器会直接编译失败——表现为"给主构造加一个注解后 `@DataAssist[fields]` 报莫名其妙的错"。
- **建议**：`584` 改 `isPublic(x)`（构造器自身的可见性），`595` 改 `isPublic(x)`（`match` 外层拿到的 `FuncParam`）；删掉 `598` 行（`584`/`595` 两个分支都已经追加过），或把它移进 `case _ =>` 里且改用 `p` 而非外层 `d`。补一条"主构造带 `@MyMacro` + `@DataAssist[fields]`"的编译期用例。

### [轻微][存量] #13 `AnySubPathNode` 的反射兜底分支不可达：`DataObject<T>` 已经实现 `Collection<(String, Data)>`

- **位置**：`f_data/src/path/AnySubPathNode.cj:26-34`（`case _ =>` 里的 `TypeInfo`/`instanceFunction` 反射路径）
- **来源**：存量（`git blame -L 18,34` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（被前面 case 完全覆盖的分支 / 不可达语句）
- **证据**：静态确定 —— `public class DataObject<T> <: SimpleDataObject & Collection<(String, Data)> & NamedData`（`f_data/src/base/DataObject.cj:67`）；`Collection<T> <: Iterable<T>`（`stdlib/doc/libs/std/core/core_package_api/core_package_interfaces.md:531`）。因此 `DataObject` 实例必然命中第一个分支 `case x: Iterable<(String, Data)>`（`AnySubPathNode.cj:23`），永远进不到 `26` 行；而能进到 `case _` 的值又不是 `DataObject`，`info.qualifiedName.startsWith('f_data.DataObject')` 只会为假。附加疑点：即使可达，该前缀也缺少包路径（同文件其它代码用 `'std.core.Option<'` 这类带包名的写法，见 `JsonSchema.cj:146`）。
- **描述**：这段反射兜底是历史包袱（早期 `DataObject` 未实现 `Iterable`），现在既不可达又会误导读者以为"`DataObject` 走反射"。每次节点访问前还要 `TypeInfo.of(data)`，对不可达分支是纯浪费。
- **建议**：整段删除，`case _ => SingleIterator<Data>(data)`；若确实要保留"未知对象按成员展开"的能力，改成 `case x: Collection<(String, Data)>` 之外的显式类型判断，并把前缀换成 `TypeInfo.get` 构造的完整限定名。

### [轻微][存量] #14 `fromJson` 不校验尾部、空输入返回 `JsonNull`：非法 JSON 静默降级

- **位置**：`f_data/src/json/JsonValue.cj:165-212`（根标量解析后直接返回、对象/数组在 `EndArray`/`EndObject` 处 `return`，之后从不检查 `reader.peek()` 是否已到流尾）、`209-211`（`peek()` 为 `None` 时返回 `JsonNull.instance`）
- **来源**：存量（`git blame -L 165,212` → `6ba7695863 2026-07-03`）
- **判据**：review-checklist §11（错误处理缺失、契约与实现不符）、§3（兜底把错误吃掉）
- **证据**：静态确定 —— `fromStr('1 2')` 返回 `JsonInt/JsonDecimal(1)`，尾部 `2` 被丢弃；`fromStr('{"a":1}garbage')` 返回该对象；`fromStr('')` 返回 `JsonNull`。仓内已有代码知道这一点并自行兜底：`f_jsonrpc/src/client/JsonRpcSseClient.cj:140` 的注释写明"`JsonValue.fromStr` 对 `not json` 这类输入**不抛异常**，会退化成 `JsonNull`"。而 `JsonException` 在同文件里到处用于表达解析失败（`188/201/205-207`），`JsonConverter.fromJson`（`JsonConverter.cj:22`）与 `DataJsonObject.parse`（`ExtendJson.cj:220`）都假定解析失败会抛。
- **描述**：①协议层（JSON-RPC / MCP）拿到被截断或被追加垃圾的报文时，会把"半个对象"当成功解析继续处理，错误在更远处才暴露且指向错误的位置；②`fromStr('')` 得到 `JsonNull` 与"空输入"语义混淆（`JsonValue.fromBytes` 对空 body 同样返回 null）。
- **建议**：根值解析完成后检查 `reader.peek()` 必须为 `None`，否则抛 `JsonException('unexpected trailing content')`；空输入（首 token 为 `None`）抛 `JsonException('unexpected end of input')`。这两条会改变 `JsonRpcSseClient` 等既有调用方的行为，需同步检查其 `case _: JsonNull` 兜底（`JsonRpcSseClient.cj:145` 附近）。

### [轻微][存量] #15 六组「换类型名 / 换名字」的重复实现（含一处已漂移）

- **位置**：①`DataJson.cj:144-167` 与 `169-191`（`DataMap` / `DataConcurrentMap` 两个 extend 逐行相同，只有 `Map`↔`ConcurrentMap` 不同）；②`ExtendJson.cj:28-36` 与 `37-45`（两个 `fromReader`，见 #3）；③`JsonSchemaValidator.cj:620-638` 与 `640-654`（`typeNames` 与 `stringArray` 函数体逐行相同，返回类型也一样）；④`JsonSchemaValidator.cj:568-618`（`intKeyword`/`boolKeyword`/`stringKeyword`/`numberKeyword` 四份同构）；⑤`JsonSchema.cj:40-80` / `81-116` / `117-145`（int/float/string 三段 case 逐个关键字复制）；⑥`JsonSchemaValidator.cj:26-60` 与 `CountFilterResult.cj:52-57`、`CountCmpFilter.cj:40-46`（同一段"ordering + eq"比较尾巴三处复制，其中 `CmpFilter.cj:39/45/51/55` 缺 `ordering == EQ && !eq` 的 NOTEQ 分支）
- **来源**：存量（①②`6ba7695863 2026-07-03`；③④⑤`e153677c93 2026-10-24`；⑥`4be871f2fd 2026-10-02` 与后续 path 改动）
- **判据**：review-checklist §2（只改类型名 / 换名字的重复、近似重复导致行为漂移）
- **证据**：静态确定 —— 上述每一对/组都已逐行比对：①②③是逐行相同（①只有类型约束差异，③连函数名外的标识符都相同）；④⑤结构相同、只有关键字名与类型不同；⑥三处的 `cmp == ordering || (eq && cmp == EQ)` 完全一致，但 `CountCmpFilter`/`CountFilterResult` 多了 `if (ordering == Ordering.EQ && !eq) { cmp != Ordering.EQ }`（`CountCmpFilter.cj:42-46`、`CountFilterResult.cj:53-57`），`CmpFilter` 没有。当前 `DataPath.cj:497-545` 只生成 `LT/GT × eq` 组合，`!=` 走 `NotEqFilter`，所以 `CmpFilter` 的缺分支现在不可达——是"复制时少抄一段"的潜在漂移。
- **描述**：这类复制的代价已经出现过一次：`DataAssist.cj:474` 的注释记录了"`compare` 只求值不赋值导致恒返回 EQ"的同源缺陷。`DataMap`/`DataConcurrentMap` 两份 40 行实现任何一处改动都要同步两遍（当前两者完全一致，属"还没漂"）。`typeNames` 与 `stringArray` 语义完全相同，读代码时要多花时间确认它们不是两种不同规则。
- **建议**：①合并成一个 `extend<M, K, V> DataMap<...> <: ToJsonString`（`ConcurrentMap` 已是 `Map` 的子接口则天然覆盖）；③删掉 `typeNames`，统一用 `stringArray`；④抽 `keyword<T>(obj, key, path, ctx, expected: (JsonValue) -> ?T)`；⑥抽 `compareResult(cmp: Ordering, ordering: Ordering, eq: Bool): Bool` 放进 `FilterUtils.cj`，三个过滤器都调它，顺便消除 `CmpFilter` 的缺分支。

### [轻微][存量] #16 `CountFilterResult` 少一种输入形状：`Iterable<(Data, Data)>` 落到"整体当一项"

- **位置**：`f_data/src/path/CountFilterResult.cj:40-51`（只处理 `Iterable<Data>` 与 `Iterable<(String, Data)>`，其余 `case _ => if (inner.check(data)) count = 1`）
- **来源**：存量（`git blame -L 38,51` → `4be871f2fd 2026-10-02 runningW`）
- **判据**：review-checklist §2（同族实现漂移）、§11（语义与命名不符）
- **证据**：静态确定 —— 同一模块的 `AnySubPathNode.cj:22-25` 明确列出三种可迭代形状（`(String,Data)`、`(Data,Data)`、`Data`），`CountFilterResult` 少了 `(Data,Data)` 这一种；命中兜底时 `count` 被置为 1（`50`），而 `right` 通常是 0 或更大整数，`count(...)` 的结果会退化成"这个 map 里恰好有 0/1 个匹配"。
- **描述**：`count(match(...))` 作用在以 `Data` 为键的 map（`DataMap` 的 `Iterable<(Data, Data)>` 形态）上时，语义与"逐成员计数"不同，且不会报错。
- **建议**：补 `case x: Iterable<(Data, Data)> => for ((_, d) in x) { if (inner.check(d)) { count++ } }`；把三种形状的展开抽成 `FilterUtils.iterateValues(data)` 供 `AnySubPathNode` 与三个 count 过滤器共用。

### [轻微][存量] #17 `JsonObject.add` 重复键静默覆盖，`getItems()`/`getFields()` 把内部可变容器直接交给调用方

- **位置**：`f_data/src/json/JsonValue.cj:491-493`（`map.add(name, value)`）、`383-385`（`JsonArray.getItems(): ArrayList<JsonValue>`）、`476-478`（`JsonObject.getFields(): HashMap<String, JsonValue>`）；解析侧调用点 `197`
- **来源**：存量（`git blame -L 383,385` / `476,478` / `491,493` → `6ba7695863 2026-07-03 runningW`）
- **判据**：review-checklist §11（静默覆盖）、§12.1（发布逸出：把可变内部状态交给外部）
- **证据**：静态确定 —— `HashMap.add` 对已存在的键"值被新值替换并返回旧值"（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:4861-4866`），`JsonObject.add` 丢掉返回值 ⇒ `{"a":1,"a":2}` 静默取 2，`fromJson` 的 `object.add(name, value)`（`197`）同理；`getItems`/`getFields` 返回的就是内部 `list`/`map` 本体（`374-385`、`467-478`），调用方增删会绕过 `JsonValue` 自己的 API，且在 `iterator()` 期间修改会让迭代行为未定义。
- **描述**：重复键是客户端常见的手写错误 / 攻击面（`{"role":"user","role":"admin"}`），静默取最后一个会让服务端与客户端的"字段语义"不一致；`getItems()` 被 `DataJsonArray.iterator()`（`ExtendJson.cj:177`）与 `DataJsonObject.iterator()`（`ExtendJson.cj:211`）依赖，是既有公开契约，不能直接删。
- **建议**：`JsonObject.add` 检查返回值，重复键按 RFC 8259 允许的策略**显式**处理（抛 `JsonException` 或保留首个并打日志），并把这个策略写进 README；`getItems`/`getFields` 改为返回副本或只读视图（`Array`/`Iterable`），内部 `iterator()` 改用私有访问器。

### [轻微][存量] #18 `toJsonSchema` 的注释说"优先 `mutableFields`"，实现先取 `dataFields`

- **位置**：`f_data/src/json/JsonSchema.cj:191-196`（注释）对照 `216-231`（实现）
- **来源**：存量（`git blame -L 191,196` / `216,231` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §13（注释/文档与实现不一致）
- **证据**：静态确定 —— 注释写"优先使用静态 `mutableFields()`（手写或 `@Bean` 生成），没有时回退到 `@DataAssist[fields]` 生成的静态 `dataFields()`"；代码先 `getStaticFunction('dataFields')` 并在 `case x: ObjectFields` 里直接消费，只有它抛 `InfoNotFoundException` 时才去看 `mutableFields`。`f_data/src/test/JsonSchema_test.cj:34-41` 的注释也按"反射查找的是 mutableFields"来写，两处描述互相矛盾。
- **描述**：对同时具备两份字段表的类型（`@Bean` + `@DataAssist[fields]`），实际以 `dataFields` 为准；`@DataExclude`/注解解析两条链路的字段集合可能不同，读注释的人会得出错误结论。
- **建议**：把注释改成与实现一致（"优先 `dataFields`"），或按注释把顺序调过来并说明理由；两种字段表的差异需要一条对比用例固定下来。

### [轻微][存量] #19 `generateProps` 里对已被替换掉的 `FuncParam` 赋值 `modifiers`/`keyword`，无任何效果

- **位置**：`f_data/src/macros/DataAssist.cj:281-291`（先 `funcParams[i] = FuncParam(paramTokens[c .. end])`，随后 `p.modifiers = ArrayList<Modifier>()`、`p.keyword = Token(ILLEGAL)`）
- **来源**：存量（`git blame -L 281,291` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（赋值后不再被读取 / 死代码）
- **证据**：静态确定 —— `p` 是替换前从 `funcParams[i]` 取出的旧对象；`FuncParam(paramTokens[c..end])` 用词法单元重新构造了一个新对象写回数组，之后对新对象再做任何修改都不会回到 AST。`p` 的 `modifiers`/`keyword` 此后在本函数内不再被读取（`gen(member, …)` 用的是 `member` 的副本，`assigns` 用的是 `p.identifier`）。
- **描述**：这两行看起来在"从构造参数上剥掉 `let`/`mut`"，实际剥除已经由 `paramTokens[c .. end]` 完成；留着会让读者以为还需要额外清理，也掩盖了"`p` 已被丢弃"这一事实。
- **建议**：删掉 `289-290` 两行；若意图是修改原 AST 节点，应改为在替换之前赋值。

## 优化可行性方案

> 均为"还能更好"，非缺陷。全部无改前/改后对照数据，只作下一轮取数清单，不进 `tasks.md`。

### [堆内存] #1 `fromReader` 的全量缓冲与二次拷贝可以整段省掉

- **现状**：`ExtendJson.cj:29-35` 把整条流写进一个 `ByteBuffer`，再 `bytes()` 拷一份交给 `fromBytes`；峰值 ≈ 输入字节 × 2 + 解析树。`JsonValue.fromStr`（`JsonValue.cj:156-158`）同样是 `str.unsafeBytes()` → `ByteBuffer` 的整块持有。
- **方案**：`fromInput` 直接 `fromJson(JsonReader(input))`；`fromReader(TextReader)` 用 `TextReader` 适配成 `InputStream` 后同样直连 `JsonReader`，删掉 `ByteBuffer` 中转。
- **预期**：解析期峰值从 2N + 树 降到 N（流式读缓冲）+ 树；具体降幅需按真实报文大小采。
- **代价**：`JsonReader` 是否接受"非 seekable 流"要现场核对；`readln` 会规范化换行，直连后行为会变（对非法 JSON 更严格，属改进）。
- **验证**：10 MB 报文解析前后 `getAllocatedHeapSize()` 峰值 + RSS；`cjpm bench -O2` 对照 `fromInput` 吞吐。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] #2 校验时只为求长度就 `toRuneArray()` 物化整串

- **现状**：`JsonSchemaValidator.cj:243`、`434` 用 `s.toRuneArray().size` 求字符数，每个被校验的字符串字段都分配一个 `Array<Rune>`（长度 = 字符数，`Rune` 4 字节）。
- **方案**：改用一次遍历计数（或 `String` 自带的字符数属性/`count()`，需先核对 `String.size` 的口径是字节还是字符），只在 `minLength`/`maxLength` 存在时才计数。
- **预期**：大字符串（如 1 KB 以上的 `description`/`prompt` 字段）每次校验少一次 O(n) 分配；峰值收益随字段大小线性。
- **代价**：需确认 `String.size` 语义（按 `std` 文档核对，避免把字节数当字符数）。
- **验证**：`cjprof heap` 看 `toRuneArray` 分配量；`getAllocatedHeapSize()` 跑 1e4 次含长字符串的校验。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #3 `uniqueItems` 去重从 O(n²) 降到 O(n)

- **现状**：`JsonSchemaValidator.cj:731-741` 双层循环 + `jsonEquals`，n=1000 时 4.99×10⁵ 次比较，元素为容器时再乘元素规模（见发现 #9）。
- **方案**：给 `JsonValue` 增加"内容哈希"或 `canonicalString()`，用 `HashSet` 去重；也可先按 `kind` 分桶再比较，减小常数。
- **预期**：复杂度从 O(n²) 降到 O(n·k)（k 为单元素哈希代价）；1000 项场景理论降两个数量级，需实测。
- **代价**：`JsonValue` 新增公开方法或内部 helper；浮点/整数等价（`jsonEquals` 的 `JsonInt`/`JsonDecimal` 交叉比较）要在哈希里保持一致，否则会漏判重复。
- **验证**：`cjpm bench -O2`，输入 1000 项（标量 / 嵌套对象各一组），比较改前后中位数与 P99。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #4 过滤器字面量在编译期预解析

- **现状**：`CmpFilter.cj:49` 每个数据行 `Decimal.parse(right.toString())`；`CountCmpFilter`/`LengthCmpFilter`/`CountFilterResult` 的 `ordering` 字符串也在运行期 `match`（`CountCmpFilter.cj:26-31`）。
- **方案**：`DataPath` 编译期（`DataPath.cj:497-545` 生成 `CmpFilter<...>` 处）就把字面量解析成目标类型并作为附加参数传入，运行期只做比较；非法字面量在编译期抛 `DataException`。
- **预期**：每次 `check` 去掉一次字符串→`Decimal` 解析；行数越大收益越大。
- **代价**：`CmpFilter` 构造函数签名变化（internal class，影响面限于 `path` 包与 `DataPath` 反序列化分支 `839-843`）。
- **验证**：`cjpm bench -O2` 对 1e6 行数据跑 `@.price < 10`；`cjprof` 看 `Decimal.parse` 自耗时占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #5 schema 生成/校验里的反射与字符串前缀判定可缓存

- **现状**：`JsonSchema.cj:146-187` 用 `fieldType.qualifiedName.startsWith('Option<')`/`'std.collection.ArrayList<'` 等字符串前缀判定容器种类，每次生成 schema 都要拼 `qualifiedName` 并做多次 `startsWith`；`TypeInfo.get(generic)` 还要把泛型实参的字符串重新解析成 `TypeInfo`。
- **方案**：改为按 `TypeInfo` 的泛型实参（`typeArguments` 一类 API，需核对 `std.reflect` 文档）判断，避免字符串往返；生成结果按 `TypeInfo` 做一次进程级缓存（`toJsonSchema` 的输入是类型，天然适合缓存）。
- **预期**：启动期/注册期成本下降，`f_mcp` 注册大量工具时最明显。
- **代价**：反射 API 能力需现场核对（是否有 `typeArguments`）；缓存需考虑 `HashMap` 的无界增长（按类型数增长，天然有界）。
- **验证**：`MonoTime` 包住 `toJsonSchema` 注册 500 个类型，比较改前后总耗时。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `fromJson` 的递归在真实栈大小下能撑多少层（定 maxDepth 的依据） | `f_data/src/json/JsonValue.cj:165-212` | 崩溃临界深度、默认线程栈大小 | 写 1k/2k/5k/10k 层 `[` 的输入跑 `JsonValue.fromStr`，记录崩溃点；同时查 SDK 文档的线程栈默认值 |
| 2 | `toRuneArray()` 在 JSON→PO 校验里占可观分配 | `f_data/src/json/JsonSchemaValidator.cj:243,434` | 分配量、自耗时占比 | `cjprof heap` + `getAllocatedHeapSize()` 跑 1e4 次含 1 KB 字符串字段的校验 |
| 3 | `CmpFilter` 的每行 `Decimal.parse` 是数据路径过滤的热点 | `f_data/src/path/CmpFilter.cj:49` | 单次 parse 耗时 × 行数、占比 | `cjpm bench -O2` 对 1e6 行跑 `@.price < 10`，改前/改后中位数；`cjprof` 看 `Decimal.parse` |
| 4 | `hasDuplicates` 在 1000 项上限内的最坏耗时（决定阈值是否合理） | `f_data/src/json/JsonSchemaValidator.cj:731-741` | 最坏输入的实际耗时 | 构造 999 个相同嵌套数组，计时 `uniqueItems` 校验 P99 |
| 5 | 宏生成的 `__hAsh__` 惰性缓存在真实负载里省下的哈希计算量 vs 失效代价 | `f_data/src/macros/DataAssist.cj:344-356` | `hashCode` 调用次数、缓存命中率 | 在生成代码上加计数埋点，跑一次典型业务压测 |
| 6 | `JsonValue.toData()` 产物嵌套后在 `toJsonString` 里被丢弃的频次（评估 #5 的实际影响面） | `f_data/src/json/DataJson.cj:110-113` | 生产里 `DataJsonObject`/`DataJsonArray` 作为字段值的比例 | 在 `case _ => continue` 处加计数埋点（不改行为），跑一周 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/json/DataJson.cj` | .cj | ✅ | 见 #5（`case _ => continue` 丢成员）、#15①（两个 map extend 同构）；`escapeJsonString` 的双扫描快路径与 `legacyEscape` 对照一致，未计问题 |
| 2 | `f_data/src/json/DataJson_test.cj` | .cj | ✅ | 1 个用例 / 4 条转义断言；缺 `toJsonString` 丢成员、`\u00XX` 控制字符、`DataJsonObject` 嵌套用例 |
| 3 | `f_data/src/json/ExtendJson.cj` | .cj | ✅ | 见 #3 / #6 / #15②；`tryFromData` 的 7 分支解包与 `DataAny` 透传已逐条核对 |
| 4 | `f_data/src/json/JsonConverter.cj` | .cj | ✅ | `toJson`/`fromJson` 两行封装；`fromJson` 的 `case _ => throw` 与 `IGNORE_FIELD_NOT_CONVERTABLE` 分支语义自洽，未发现问题（但受 #14 的解析宽容度影响） |
| 5 | `f_data/src/json/JsonEscapeFastPath_test.cj` | .cj | ✅ | 基准受 `F_DATA_JSON_BENCH=1` 门控；`legacyEscape` 仅测试用；`fastPerCall <= 128`、`legacyAlloc > fastAlloc * 8` 两条断言强依赖分配口径，只作对照不作门槛 |
| 6 | `f_data/src/json/JsonSchema.cj` | .cj | ✅ | 见 #8 / #11 / #15⑤ / #18 |
| 7 | `f_data/src/json/JsonSchemaValidator.cj` | .cj | ✅ | 见 #2 / #9 / #15③④⑥；`regexFor` 写共享 `HashMap` 的问题已在第 3 部分 #4 报过，本部分不重复计数 |
| 8 | `f_data/src/json/JsonSchemaValidator_test.cj` | .cj | ✅ | 19 条用例覆盖 min/max/enum/pattern/format/uniqueItems/required/additionalProperties/nullable/maxErrors/toJson；缺整数类型互认、空数组 `avg`、深嵌套 schema 用例 |
| 9 | `f_data/src/json/JsonValue.cj` | .cj | ✅ | 见 #1 / #2 / #14 / #15⑥ / #17；`kind`/`asX` 的 7 个分支逐一核对，无遗漏 |
| 10 | `f_data/src/json/imported.cj` | .cj | ✅ | 包级 `internal import` + 两个 `public import`；`JsonWriter`/`JsonReader`/`UnreadableException` 均在本包被使用 |
| 11 | `f_data/src/macros/DataAssist.cj` | .cj | ✅ | 见 #7 / #12 / #19；`normalizeSuperTypes`/`superTypeText`/`openTokens`/`isCopyableFieldType` 均有调用者 |
| 12 | `f_data/src/macros/DataExclude.cj` | .cj | ✅ | `extractDeclSignature` 有调用；未知 tag 静默 `setItem`（拼错 `tostrng` 不报错）属轻微输入校验缺失，未单列 |
| 13 | `f_data/src/path/AndFilter.cj` | .cj | ✅ | 被 `DataFilter.cj:24` 的 `&&` 组合使用；`check` 短路求值正确 |
| 14 | `f_data/src/path/AnyOfFilter.cj` | .cj | ✅ | `DataPath.cj:852-854` 生成；`subset(data) > 0` 语义与 RFC 9535 的 `anyof` 一致 |
| 15 | `f_data/src/path/AnySubPathNode.cj` | .cj | ✅ | 见 #13；`instance` 被 `DataPath.cj:923/960`、`RecursiveDescentIterator.cj:27` 使用 |
| 16 | `f_data/src/path/AvgPathNode.cj` | .cj | ✅ | 见 #4 |
| 17 | `f_data/src/path/CacheDataPath.cj` | .cj | ✅ | `HeapCache(maxLife: 1 day, maxSize: 10000)` 有界；`HeapCache` 内部 `ConcHashMap` 分片 + `AtomicBool`，线程安全（`f_cache/src/HeapCache.cj:26-66`），未计并发问题 |
| 18 | `f_data/src/path/CmpFilter.cj` | .cj | ✅ | 见 #10 / #15⑥ |
| 19 | `f_data/src/path/CountCmpFilter.cj` | .cj | ✅ | `NOTEQ` 分支写法（`42-46`）与 `CountFilterResult` 一致；计数用 `for (_ in itr)` 全量迭代，语义正确 |
| 20 | `f_data/src/path/CountFilterResult.cj` | .cj | ✅ | 见 #16 / #15⑥ |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性：#1 #2 #3 #4 #5 #6 #8 #9 #10 #14；设计：#11（生成侧吞错）、#12（宏变量误用）；语言特性：#5（`Any`+`is` 分派导致漏实现）、#7（惰性缓存 + 值语义假设）已并入；可读性：#15 #18 #19；安全性：本部分无 SQL/凭据/日志敏感字段；外部输入面是 JSON 文本（#1 #2 #9 #14 均为"外部输入未设上限/未校验"类，不走注入）|
| §1 死代码 | 2 | #13（`AnySubPathNode` 反射兜底不可达）、#19（`p` 被替换后的赋值）。机械核对结论：本部分 `private` 符号（`JSON_HEX_DIGITS`、`jsonNeedsEscape`、`toJsonSchema(fieldType:schema:)`、`normalizeSuperTypes`、`superTypeText`、`isCopyableFieldType`、`fieldTypeTokens`、`openTokens`、`EMAIL_RE`/`DATE_RE`/`DATETIME_RE`/`UUID_RE`、`ValidationCtx`、`hasDuplicates`、`joinPath`、`typeNames`、`stringArray`、`asEnumValues`、`checkEnumText`、`legacyEscape`、`jsonMeasure`、`jsonSettle`、`jsonBenchEnabled`）全部有调用者；`internal`（`escapeJsonString`、`AndFilter`、`AnyOfFilter`、`AnySubPathNode`、`AvgPathNode`、`CacheDataPath`、`CmpFilter`、`CountCmpFilter`、`CountFilterResult`、`validateWithPatterns`、`validateInstance`、`jsonEquals`、`ValidationCtx`、`DataJsonArray`/`DataJsonObject` 未声明的成员）在本包及子包内均有引用；本部分无 `protected` 声明；`public` 顶层声明（`ToJsonString`、`ToJsonSchema`、`JsonValue` 全家族、`JsonSchema` 全家族、`JsonSchemaValidator`、`ValidationResult`/`ValidationError`/`ValidationOptions`、`UnknownKeyword`、`ExtendJsonValue`、`JSON_NULL`、`DataJsonArray`/`DataJsonObject` 及其 Iterator、`DataAssist`/`DataExclude` 宏、`toJson`/`fromJson`）对外可达，一律不判；`JsonValue.kind` 的 `case _ => throw UnreadableException()`（`87`）在 `sealed` 类上属编译器兜底，按"防御性 default"不判 |
| §2 重复逻辑 | 6 | #15 的六组（map×2、fromReader×2、typeNames/stringArray、4 个 keyword reader、schema 三段、比较尾巴×3）；#6（两个 `tryParse/parse` 对）与 #3（fromReader）在设计层面同源，已分别计入对应发现。已两两比对 20 个文件里 60+ 个函数体的"输入-输出-副作用"：`JsonInt`/`JsonDecimal` 的 12 个 `toXxx()` 一行转换因返回类型不同无法合并，不计；`JsonValue.asX` 7 个方法结构相同但 `asInt`/`asDecimal` 带跨类型转换，属"语义有差异"，不计 |
| §3 空实现 | 1 | #11（`catch` 后回 `case _ => ()` 的静默空实现）。另核：`DataJsonArray/DataJsonObject.tryParse` 不为空（返回 `toData()` 结果，只是没校验类型，见 #6）；`ValidationCtx.skip` 有实际写入；无 `TODO`/`FIXME` 落在主路径（`DataAssist.cj:295` 的 `//TODO` 是宏参数展开的已知限制，注释已说明并保留了可用回退，未计入）|
| §4 栈溢出 | 1 | #1（`fromJson`/`toJson`/`jsonEquals` 递归深度由输入决定）。另核：`DataAssist.normalizeSuperTypes` 无递归；`superTypeText` 是线性遍历；`JsonSchemaValidator.validateDoc/validateInstanceAt` 有 `maxDepth`（默认 64）保护，`hasDuplicates` 不递归 |
| §5 OOM | 1 | #3（`fromReader` 全量缓冲 + 二次拷贝，无上限）。另核：`CacheDataPath.CACHE` 上限 10000 条（`CacheDataPath.cj:21`）；`JsonArray`/`JsonObject` 的生命周期跟随调用方，无静态无界容器；`hasDuplicates` 的平方级**计算**不是内存增长，已归 §6.4 |
| §6.1 热点瓶颈 | 0 | `scope.md` 的「已有性能资料」只有 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`（local mode 方案，非本模块 profile），本部分无 `cjprof`/`cjpm bench` 输出，热点结论不成立，全部转入待验证假设 #1–#6 |
| §6.2 大粒度锁 | 0 | 本部分没有 `synchronized`/`Mutex`/锁内 I/O；唯一共享可变结构是 `ValidationCtx.patterns` 指向的 `HashMap`（写点在 `JsonSchemaValidator.cj:94`），其并发问题已在第 3 部分 #4 报过 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/批处理 |
| §6.4 低效算法 | 2 | #9（`hasDuplicates` 双层循环）、#10（每行重复 `Decimal.parse`）；无 `remove(at: 0)` 当队列、无循环内字符串 `+`（`DataJson`/`JsonSchema` 的字符串拼接都在非热路径） |
| §7 降堆内存方案 | 2 | [堆内存] #1（`fromReader` 全量缓冲）、#2（`toRuneArray` 求长度）|
| §8 降 CPU 方案 | 3 | [CPU] #3（`uniqueItems` 降复杂度）、#4（字面量预解析）、#5（反射/字符串前缀判定缓存）|
| §9 local mode 可行性 | 0 | 本部分函数内的临时对象要么极小（`Decimal`、`Rune`），要么**逃逸**（`JsonValue` 解析树作为返回值、`JsonArray`/`JsonObject` 被调用方长期持有），不满足"函数内创建、函数内用完"；`escapeJsonString` 的 `StringGenerator` 结果直接返回。因此没有可量化的峰值内存收益，改造只会在 `JsonReader` 缓冲上引入 `LocalRegionOutOfMemoryError` 新面 |
| §11 现有代码的 BUG（存量） | 13 | #1–#12 中的 #2/#4/#5/#6/#8/#9/#10/#11/#14 与 #7 的时间序缺陷、#12 的宏变量误用均属存量 BUG；其余函数（`DataJson.escapeJsonString`/`jsonNeedsEscape`、`ExtendJson.tryFromData` 的 10 个 case、`JsonConverter` 两个函数、`JsonValue` 的 `asX`/`kind`/`write`/`toJsonString`/`fromStr`/`fromBytes`、`JsonSchema` 6 个注解类、`JsonSchemaValidator` 的 `intKeyword`～`numberKeyword`/`requireType`/`typeName`/`joinPath`/`checkFormat`、path 下 8 个类的 `check`/`get`）已逐条核对空集合、`None`、越界、类型不符，除已列条目外未再发现确定性缺陷 |
| §12 并发安全与锁粒度 | 1 | #7（宏生成的 `__hAsh__` 无同步惰性写入，最坏重复计算）。线程封闭说明：`JsonValue`/`JsonArray`/`JsonObject` 是可变类且无同步，所有权归调用方（`f_mcp`/`f_jsonrpc` 每请求解析出独立实例，不跨线程共享）；`CacheDataPath` 走 `HeapCache`（`ConcHashMap` 分片 + 原子关闭标志，`f_cache/src/HeapCache.cj:26-66`）安全；`ValidationCtx` 是每次校验的局部对象，`patterns` 的跨线程共享问题见第 3 部分 #4 |
| §14 功能完备性与 README 覆盖 | 2 | #8（容器 schema 只做了一半：`items` 错、Map 缺分支）、#11（字段表缺失时静默生成空 schema）；README/md 不在本部分清单，故不做 README 逐符号对照；本部分 public 声明（`ToJsonString`、`JsonValue` 家族、`JsonSchema*` 注解、`Validation*`、`ExtendJsonValue`、`DataJsonArray/Object`、`DataPath` 节点与过滤器）在 README `825-836` 均有对应条目，未见"公开 API 完全无文档" |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 不在本部分清单内，README 仅作判据引用（#5、#8、#11、#17、#18） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量缺陷 19 条（严重 2 / 一般 10 / 轻微 7），是否纳入修复待用户决定；本部分无「本次改动」来源。待验证假设 6 条不计入统计。

## 总评

本部分的骨架是清楚的：`JsonValue` 的 7 个子类 + `asX`/`kind` 分派、`ValidationCtx` 的 `maxErrors`/`maxDepth`/`skipped` 三件套、`JsonSchemaValidator.validateDoc` 与 `validateInstanceAt` 的双入口分工、`DataPath` 那一套"编译期生成过滤器"的设计，都比一般内部库严谨；`escapeJsonString` 的双扫描快路径还有专门的一致性用例（`legacyEscape`），这类"改动配对照"的做法值得保持。

**两个阻塞项都在"解析与类型"的交界上。** 一是 `fromJson` 无深度上限（#1）：JSON-RPC / MCP 的请求体直接进这个递归，几千层就崩进程，而 1 MB 的 body 限制对层数毫无约束——这是外部输入直通崩溃，属于必须在下一版修掉的项。二是"解析只产 `JsonDecimal`、校验只认 `JsonInt`"（#2）：两个文件各自都自洽，接起来就是"任何 `integer` schema 永远失败"；它现在还没在业务里大规模触发，纯粹因为工具参数类把数量写成了 `String`，属于运气而非设计。

**中间一档集中在"静默"上。** `toJsonString` 的 `case _ => continue` 会整条抹掉成员（#5）、`parse` 承诺校验却不校验（#6）、`toJsonSchema` 两处回退失败后返回空 properties（#11）、容器 `items` 生成成对象（#8）、宏生成的 `==` 用不失效的缓存哈希做前置否定（#7）——共同点是**没有异常、没有日志，结果却与契约不符**，排查成本远高于直接报错。这几条建议统一按"要么做对、要么显式失败"的口径收一遍，工作量都不大。

**并发与性能不是本部分的主要风险。** 除了宏生成的 `__hAsh__`（#7）这一处惰性写入，其余共享结构要么线程封闭、要么走 `HeapCache`/`ConcurrentHashMap`；`CompiledSchema` 的 pattern 表写入问题归第 3 部分。性能侧只有 `hasDuplicates` 的 O(n²)（#9）与 `CmpFilter` 的重复解析（#10）值得排期，其余全部缺 profile/bench 数据，按纪律只留在「待验证假设」里，等下一轮取数。
