# f_data 模块审查报告（第 1/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（全模块 127 个 `.cj` + 15 个 `.md`；**本报告为模块第 1/8 部分**，覆盖 `f_data.part1.txt` 的 5 个 `.cj` + 15 个 `.md`；其余 122 个 `.cj` 属第 2~8 部分，未纳入本报告统计）
- **基线**：工作区快照（`sts/1.3.x` 工作区，未对照远端目标分支；快照模式无 diff 可比，所有问题来源一律记「存量」，blame 只作提交依据）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 1/8 部分）

## 发现

本部分无「严重」级发现，最高为「一般」。`Data` 根接口、`BreakingCommand` 与集合/并发映射的适配层结构清晰，`DEEP` 快路径、`tryParse` 不抛（`DataCollection`/`DataConcurrentMap`）也都对；问题集中在**转换契约的静默降级**（元素级丢弃、单引号越界）、**`DataIterable` 的占位实现**，以及**README 中英双版与实现的三处漂移**。

### [一般][存量] `extractPureString` 遇「单个引号字符」抛 `IndexOutOfBoundsException`，逃出 `tryParse`/`tryFromData`

- **位置**：`f_data/src/base/Data.cj:30-36`
- **来源**：存量（内容随 `d345e86c8` 2026-02-12「模块根目录代码移到 base 包」迁入；最后一次触碰 `4be871f2f` 2026-10-02 仅为换行符统一，非逻辑改动）
- **判据**：review-checklist §11（边界越界 / 契约与实现不符）；§10 正确性
- **证据**：静态确定 —— 函数体是 `if ((startsWith('"') && endsWith('"')) || (startsWith("'") && endsWith("'"))) { data[1..data.size - 1] } else { data }`，返回值类型由函数体推导为 `String`（官方文档 `function/define_functions.md:99-111`、`:181-191`：未显式声明时按「函数体最后一'项'的类型」推导）。仓颉 `String` 的下标是 **UTF-8 字节下标**、`size` 是 **字节长度**（`core_package_structs.md:6187`、`:9331-9349`、`:9377-9402`）；单个 `"` 的 `size == 1`，切片退化为 `1..0`。std 实现在 `start < 0 || end < start || end > size` 时抛异常（`stdlib/libs/std/core/string.cj:2531-2533`）。
- **描述**：`extractPureString` 是 `Bool / DateTime / Duration / Decimal / DataNone` 五类转换的公共前置（`DataBool.cj:28`、`DataDateTime.cj:31`、`DataDuration.cj:24`、`DataReal.cj:225/228`、`DataNone.cj:25`）。业务把字符串 `"`（或 `'`）写进 Bool/时间/数值字段时，`X.tryFromData` 不再返回 `None`，而是抛 `IndexOutOfBoundsException`；`DEFAULT_DATA_FLAG`（= `SILENCE`）也拦不住，`internal_f_data_tryFromData`（`DataFields.cj:68-78`）「不可转换 ⇒ `None`」的承诺随之失效。JSON→PO 场景下一次坏数据就是一次异常上抛，而不是字段被跳过。严重度按「单次转换抛异常、可被请求边界 catch」定为一般；若确认上游不做 catch，应升为严重。
- **建议**：先判长度再剥引号（`if (s.size >= 2 && ...) { s[1..s.size - 1] } else { s }`），并给 `extractPureString` 显式标注 `: String` 返回类型。补用例：`DataBool.tryFromData(DataString("\""))`、`DataNone.tryParse("'")` 必须返回 `None`。

### [一般][存量] 集合转换把「元素不可转换」降级为「丢元素」：`Array<Int64>` 字段会静默变短

- **位置**：`f_data/src/base/CollectionData.cj:83-96`（`Array`）、`:109-116`（`ArrayList`）、`:137-143`（`LinkedList`）、`:165-171`（`HashSet`）、`:193-199`（`TreeSet`）、`:221-227`（`LinkedHashSet`）；同类形态见 `f_data/src/base/ConcurrentMapData.cj:86-94` 与 `f_data/src/base/MapData.cj:85-92`（后者属第 2 部分，仅作对照）
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §11（错误处理静默 / `Option` 被丢弃 / 与文档冲突）；§10 正确性
- **证据**：静态确定（机制）+ 待确认（是否为有意语义）—— 六处都是 `if (let Some(x) <- internal_f_data_tryFromData<T>(d, flag)) { list.add(x) }`，**没有 else**。而 `internal_f_data_tryFromData`（`DataFields.cj:68-78`）只有在 `(flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0` 时才返回 `None`，否则直接抛；`DEFAULT_DATA_FLAG = SILENCE` 含该位（`global_objects.cj:42-51`）。README:791-793 对这一族 flag 的承诺是「越界/不可转换一律落 `None`」。
- **描述**：`["1","x","3"]` → `Array<Int64>` 得 `[1,3]`：长度 3→2，中间元素被丢弃，无异常、无 `None`。对照字段级语义（`DataObject.cj:119-128`，`case Some(_) => ()` 表示「整个字段跳过」），元素级却是「部分保留」，两者不一致；下游按下标取值会静默错位，且没有任何日志能发现。显式去掉 `IGNORE_FIELD_NOT_CONVERTABLE` 位才会抛 `DataException` —— 但默认值里恰好带着它。附带一点：`case _` 的标量回退会把「单个不可转换的标量」变成空数组（`:91-96`），语义上既不是 `None` 也不是错误。
- **建议**：容器转换改成 all-or-nothing：任一元素返回 `None` 时，未置 IGNORE 则抛带元素下标的 `DataException`，置位则让整个字段返回 `None`（而不是短数组）。把「逐元素跳过」做成显式 flag 而不是默认行为，并在 README 的 flag 说明里写清容器语义。补用例：`Array<Int64>.tryFromData(DataCollection(["1","x"]))` 期望 `None`/抛，而非 `[1]`。

### [一般][存量] `DataIterable` 的 `tryParse`/`parse`/`toString` 全部直抛无消息 `DataException()`

- **位置**：`f_data/src/base/CollectionData.cj:240-254`（`tryParse` `:245-247`、`parse` `:248-250`、`toString` `:251-253`）
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §3（公开契约承诺有行为，实现直接抛）；§11（契约与实现不符）
- **证据**：静态确定 —— `Data <: FromToData & ToString & DataParsable<Data>`（`src/base/Data.cj:18`），`toString` 必须返回字符串；`DataIterable` 三个方法无条件 `throw DataException()`（连 message 都没有）。同模块 `DataDict.tryParse` 已按「try 返 `None`、`parse` 才抛」修正并留注释（`DataDict.cj:37-40`），`doc/REVIEW_2026-10-15.md:78` 也把「`DataList/DataDict/DataTuples` 的 `tryParse` 直接抛异常」列为已修 —— `DataIterable` 是同一批修复的漏项。
- **描述**：`DataIterable` 不是死类型：`f_http/src/MultipartFormDataParser.cj:238`（重名表单字段）、`:292`/`:297`（多值字段）在生产路径构造它。任何 `"${data}"`、日志、`DataAny.toString`（`DataAny.cj:20-22` 直接转发）都会抛 `DataException()`；更糟的是 f_data 自己的错误消息也靠插值（`DataFields.cj:39/50`、`NumberData.cj` 各分支），当 `data` 是 `DataIterable` 时**构造错误消息本身会再抛一个无消息异常**，字段名与目标类型全部丢失。
- **建议**：`toString()` 返回 `[...]` 形态（与一般 #4 的集合渲染收敛成一份）；`tryParse` 返回 `None`；`parse` 抛带 message 的 `DataParsableException`（对齐 `DataCollection`/`DataConcurrentMap`）。当前 `DataIterable` 零用例，建议补三个方法的最小用例。

### [一般][存量] 同一套「Data 包装集合 + tryFromData」复制 8 份，而模块内已有 `tryFromDataToMap` 抽取先例

- **位置**：`f_data/src/base/CollectionData.cj:79-98 / 105-126 / 133-154 / 161-182 / 189-210 / 217-238`（6 份逐行同构，仅容器类型与 `add`/`addLast` 不同）；`f_data/src/base/ConcurrentMapData.cj:80-122` 对 `f_data/src/base/MapData.cj:78-120`（整段 40 行同构，仅 `map.add(k,v)` vs `map[k] = v`、`TypeInfo.of<M>()` vs `TypeInfo.of<ConcurrentHashMap<K,V>>()`）；`ConcurrentMapData.cj:20-29` vs `MapData.cj:20-28`（迭代器包装，仅类型名不同）；`ConcurrentMapData.cj:45-55` vs `MapData.cj:44-54`（`toString` 逐字相同）
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §2（只改类型名 / 跨文件复制）
- **证据**：静态确定 —— 六份 `tryFromData` 的 match 分支顺序、错误文案、`DEEP` 判定完全一致；同模块 `MapData.cj:78-120` 已经把同样的三分支抽成 `private func tryFromDataToMap(..., creator: () -> M)` 并被 `HashMap/LinkedHashMap/TreeMap` 三个 extend 复用，证明「参数化插入动作」在本模块可行。
- **描述**：新增一种集合类型就要再抄 22 行；`Array` 支用 `list.unsafeData()`、其余直接返回 list，`Array` 支用 `Array<T>(1, repeat: x)`、其余先建容器再 add —— 这些差异没有注释说明。一般 #2 就是「每支各写一遍」的直接后果：改一处漏五处。`toString` 与两个迭代器包装的复制则是纯冗余。
- **建议**：抽 `private func tryFromDataToSeq<E, C>(data, flag, creator: () -> C, add: (C, E) -> Unit): Any`，六个 extend 收敛成 6 行；`ConcurrentMapData` 复用 `tryFromDataToMap` 的泛型版本（把 `map[k] = v` 换成 `insert: (M, K, V) -> Unit`）；两个 `toString` 与两个 `Iterator` 各收敛成一份。合并前先固化差异（错误文案、`DEEP` 语义、单元素回退），按 §2 要求逐条显式参数化。

### [一般][存量] README 首个示例只 `import fountain::f_data.*` 却使用 `@DataAssist`，示例无法编译

- **位置**：`f_data/README.md:70`（import）与 `:73`/`:80`/`:95`（`@DataAssist[...]`）；`f_data/README_en.md:71` 同
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用）；§14.2（示例覆盖）
- **证据**：静态确定 —— `f_data/src/Data.cj:18-21` 只 `public import` base/json/path/validation 四个子包；宏在独立包 `macro package fountain::f_data.macros`（`src/macros/DataAssist.cj:16`）。官方文档明确「非 macro package 中无法重导出 macro package 的符号」（`Macro/defining_and_importing_macro_package.md:49-56`），所以 `import fountain::f_data.*` 拿不到 `@DataAssist`；仓内所有使用者都显式导入宏包（`f_data/src/test/data_test.cj:20`、`f_rpc/src/base/RPCMessage.cj:18`）。
- **描述**：照 README 第一段写会得到「未声明的宏 `DataAssist`」。这是 README 的主示例，也是唯一完整演示「实例复制 + JSON 往返」的例子，直接影响按文档上手。
- **建议**：示例首行补 `import fountain::f_data.macros.*`（中英同步）；或在 `@DataAssist` 章节显式写明「必须单独 import 宏包，`fountain::f_data` 无法重导出」。

### [一般][存量] `README_en.md` 与中文版多处不同步，其中「顶层 `@`」一条与实现相反

- **位置**：`f_data/README_en.md:768`（「`@` only valid inside a filter」）vs `f_data/README.md:758`、`:816-817`（顶层 `@`/`@.`/`@[` 被接受）与实现 `f_data/src/path/DataPath.cj`；另 `README_en.md:798-800` 缺 `README.md:791-793` 的 flag 优先级与 `DEFAULT_DATA_FLAG = SILENCE` 说明；`README_en.md:816`「8 test files」vs `README.md:809`「9 个」；`README_en.md` 缺 `README.md:812-815`（判等语义）、`:229`（`IsDuration` 解析细则）、`:235`（`IsIntegers` 分隔符转义）三段
- **来源**：存量
- **判据**：review-checklist §13（README_en 与 README 不同步、文档与实现相反）
- **证据**：静态确定 —— 中文版「边界行为」写「`@` filter 内为当前节点；顶层 `@`/`@.`/`@[` 也被接受（内部子 filter 编译用）」，英文版同一行写「`@` only valid inside a filter」；`f_data/src/path/` 下实有 9 个 `*_test.cj`（`basic / filter / recursive / compile_error / object_eq / complex_fn / integration / p1_gaps / rfc9535_slice`）。
- **描述**：英文读者会得到与实现相反的路径语义（顶层 `@` 实际是可用的，内部子 filter 编译依赖它），并按旧的 8 个测试文件理解覆盖面；flag 优先级段落缺失会让英文读者误以为 `IGNORE_FIELD_NOT_CONVERTABLE` 优先于显式溢出策略。
- **建议**：以中文版为准逐节同步；`@` 一行按 `README.md:758` 改写；测试文件数改 9 并点名 `rfc9535_slice_test.cj`；建议在 README 顶部加一句「中文版为权威，英文版滞后时以中文为准」降低再次漂移的成本。

### [一般][存量] README 自称列全公开 API，但漏掉本部分 5 个公开类型

- **位置**：`f_data/README.md:823`（「以下声明未在上文展开…」）与 `:825`；代码 `f_data/src/base/CollectionData.cj:20/27/240`、`f_data/src/base/ConcurrentMapData.cj:20/31`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— 全文检索 `README.md` / `README_en.md`，`DataCollection`、`DataCollectionIterator`、`DataConcurrentMap`、`DataConcurrentMapIterator`、`DataIterable` 命中数均为 **0**。这 5 个都是顶层 `public class`，经 `src/Data.cj:18` 的 `public import base.*` 对外可达，且是 `Array/ArrayList/HashSet/ConcurrentHashMap…toData()` 的实际返回类型：`f_orm/src/base/TableClause.cj:508`、`f_orm/src/base/SqlDSL.cj:110`、`f_mq/src/base/payload/MQBlob.cj:63/71`、`f_codec/src/default/DefaultCodec.cj:159-160` 都按 `DataCollection<Array<Byte>, Byte>` 匹配。README 只在 `:804` 提到文件名 `CollectionData / MapData / ConcurrentMapData`，没有类型名。
- **描述**：按 README 无法知道 `x.toData()` 得到什么类型，也不知道要匹配 `DataCollection<Array<Byte>, Byte>` 才能取回字节数组（f_orm / f_mq 都依赖这一形态）；`DataIterable` 更只在 f_http 内部出现、行为异常（一般 #3）却完全无文档。
- **建议**：「数据类型」表补 `DataCollection` / `DataConcurrentMap` / `DataIterable` 三行（含公开字段 `data` 与 `toString` 形态），「其他公开 API」补两个 `Iterator` 类型；中英同步。

### [轻微][存量] `ConcurrentMapData.tryFromData` 里 4 处 `else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) throw` 不可达

- **位置**：`f_data/src/base/ConcurrentMapData.cj:90-93`、`:103-106`、`:111-114`
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `internal_f_data_tryFromData<T>`（`DataFields.cj:68-78`）所有返回 `None` 的路径都要求 `(flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0`，不满足时它自己就抛 `DataException`。因此执行到 `else` 时该位必然已置位，`== 0` 恒假。（`MapData.cj:89-91/101-104/109-112` 为同一形态，属第 2 部分。）
- **描述**：三个「转不了就报错」的兜底永远不会执行，读代码会以为存在双层校验；实际唯一校验在 `internal_f_data_tryFromData` 里，错误消息是没有字段上下文的 `cannot convert data to <T>`。第 4 处（`:118` 的 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0`）可达，不在此列。
- **建议**：删掉三处 else-if（或改成 `UnreachableException` 断言）并把「tuple 上下文」下沉到 `internal_f_data_tryFromData` 的调用点参数；顺带消掉一般 #4 的复制面。

### [轻微][存量] `DataCollection.toString()` 用「缓冲区字节数 > 1」当分隔哨兵，首元素渲染为空串时丢分隔符

- **位置**：`f_data/src/base/CollectionData.cj:41-51`（判断在 `:44`）
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §11（空串未处理 / 边界）
- **证据**：静态确定 —— `StringGenerator.size` 是 **UTF-8 字节数**（`f_base/src/StringGenerator.cj:30-34`），初值 `'['` 恰为 1 字节，故 `b.size > 1` 实际等价于「已追加过非空内容」。`DataString.toString()` 原样返回 `data`（`DataString.cj:26-28`），空字符串渲染为 0 字节。
- **描述**：`["", "a"]` → `[a]`（两个元素渲染成一个）；`["", ""]` → `[]`（与空集合不可区分）。`DataCollection` 是 `Array/ArrayList/HashSet…toData()` 的结果，`"${data}"` 与日志里很常见。JSON 路径不受影响（`json/DataJson.cj:126-142` 的 `toJsonString` 对字符串至少输出 `""` 两字节）。
- **建议**：改用 `var first = true` 或下标计数决定逗号，不要拿输出长度当状态。`DataDict.cj:41-54`、`DataMap.cj:44-54` 有同一写法（当前靠 `(` / 键值逗号偶然安全），建议一起改成显式计数。

### [轻微][存量] `DataConcurrentMap.toString()` 用逗号分隔键值，与同模块其它 map 表示不一致

- **位置**：`f_data/src/base/ConcurrentMapData.cj:45-55`（`:51`）；对照 `f_data/src/base/DataDict.cj:41-54`（`[(k,v)]`）与 `f_data/src/json/DataJson.cj:144-191`（`{k:v}`）
- **来源**：存量（`d345e86c8` 2026-02-12）
- **判据**：review-checklist §10（可读性）；§11（语义与命名不符）
- **证据**：静态确定 —— `b.append('${d[0]},${d[1]}')` 输出 `{k,v,k2,v2}`；同模块 `DataDict` 用 `(k,v)`，JSON 序列化用 `k:v`。
- **描述**：`{a,1,b,2}` 无法区分「两个键值对」和「一个四元素列表」。仓内没有解析器消费该格式（`tryParse` 恒 `None`），所以不是数据损坏，只是调试/日志可读性。
- **建议**：改成 `k:v`（与 `toJsonString` 对齐）；`DataMap.toString`（第 2 部分）同源，建议一起改。

### [轻微][存量] `doc/RFC9535_COVERAGE.md` 的文件清单与源码不符，且「`@` 仅 filter 内」与实现相反

- **位置**：`f_data/doc/RFC9535_COVERAGE.md:196`（`ConfigFilter.cj`）、`:141`（`@` 限制）、`:217-229`（8 个测试文件 / 104 例）；源码 `f_data/src/path/`
- **来源**：存量
- **判据**：review-checklist §13（链接/路径失效、文档过期）
- **证据**：静态确定 —— `src/path/` 下无 `ConfigFilter.cj`；实际存在但清单未列的文件有 `MinPathNode.cj`、`MaxPathNode.cj`、`AvgPathNode.cj`、`CacheDataPath.cj`、`SolidDataPath.cj`；测试文件实为 9 个（多 `rfc9535_slice_test.cj`）。README:778/811 把这份清单当作权威覆盖表引用（「以 `doc/RFC9535_COVERAGE.md` 与源码为准」）。
- **描述**：按清单找 `ConfigFilter` 会扑空，按清单评估覆盖面会漏掉 min/max/avg 路径函数与两种缓存实现。
- **建议**：按 `ls src/path` 重写文件清单与测试表；`@` 一行按 `README.md:758` 的现状改写，或在文首标注「本文档对应 `feature/datapath` 时点」。

### [轻微][存量] README 的 `@DataAssist[props]` 展开示例与同节说明矛盾，且 setter 写法不是合法语法

- **位置**：`f_data/README.md:24`（「`var` 字段才有 setter，`let` 只生成不可变属性」）vs `:44-65` 的展开示例（`:56-63` 给 `private let b` 生成 `public prop b` 且带 setter；`:52` 用 `value(value)`）；`f_data/README_en.md:24` / `:50-63` 同
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用 / 自相矛盾）
- **证据**：静态确定 —— 属性 setter 的语法是 `set(v) { ... }`，且带 setter 的属性必须是 `mut prop`（官方 `class_and_interface/prop.md:59-67`）；示例里 `public prop a` 没有 `mut` 却写 setter，setter 名写成 `value(value)`。
- **描述**：用户照示例写会编译失败，也无法判断 `let` 到底该不该有 setter（正文与示例相反）。
- **建议**：示例改成 `public mut prop a: String { get() { a_ } set(v) { a_ = v } }`，`b` 只保留 `get`；与宏实际展开（`src/macros/DataAssist.cj`）逐行对齐。

> **范围外提示**（不计入本部分统计）：`f_data/src/json/DataJson.cj:126-142` 的 `DataCollection.toJsonString` 对非 `ToJsonString` 元素 `continue` 静默丢元素（`DataDict`/`DataList`/`DataTuples`/`DataUnit` 都未实现 `ToJsonString`，见同目录 `:70-191` 的 extend 列表；`DataObject.toJsonString` `:109-113` 同形态），属 json 部分。

## 优化可行性方案

> 本部分**未提出带基线的优化方案**：`f_data` 在 `docs/LocalMode.md` / `docs/LocalMode-O2-Plan.md` 里只有 `toJsonString` 转义相关的取数（见 `doc/spec/optimize-f-data-json-escape/design.md`），集合转换与 `toString` 没有任何测量数据。按 reviewer 规则，这些候选只进「待验证假设」，不写成收益结论、不进 `todo.md` / `tasks.md`。

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DataCollection<Array<Byte>, Byte>` 的逐元素路径把每个 `Byte` 装箱成 `DataReal(Decimal)`，大 blob 的 `toString` / `DEEP` 转换放大 CPU 与分配 | `CollectionData.cj:41-51`（`toString`）、`:83-96`（逐元素转换）；装箱源 `NumberData.cj:55-58`（`UInt8.toData → DataReal`） | 分配量与自耗时占比 | `cjprof record` 跑 1 MB `Array<Byte>` 的 `toData().toString()` 与 `Array<Byte>.tryFromData(data, DEEP)`，与 `Array<Byte>.toString()` 对照；同 SDK、`-O2`、3 轮取中位 |
| 2 | `Array<T>.tryFromData` 的 `list.unsafeData()` 若返回切片副本，会让转换峰值约 2×（ArrayList 缓冲 + Array） | `CollectionData.cj:90`；`f_base/src/UnsafeData.cj:24-29` | 转换前后分配量 / 峰值 RSS | 1e6 个 `Int64` 的 `DataCollection→Array` 转换，读 `getAllocatedHeapSize()` 前后差与 RSS；确认 `Array` 切片是否复制（同一用例看分配量是否≈2×元素体积） |
| 3 | `DataConcurrentMap.toString()`/迭代在并发写下的开销与一致性（std 未文档化 `ConcurrentHashMap` 迭代器的快照语义） | `ConcurrentMapData.cj:34-55` | 并发写下的迭代异常率、耗时、元素数偏差 | 10 线程持续 `data.add/remove`，另一线程循环 `toString()`，记录单次耗时 P50/P99 与元素数偏差 |
| 4 | `DataCollection.toString` 的 `StringGenerator` 按倍增扩容，大集合（10 万元素）产生多次整块复制 | `CollectionData.cj:42-50` | 扩容次数、复制字节数、耗时占比 | 10 万元素 `Array<Int64>` 跑 `toData().toString()`，`cjprof` 看分配热点；或用 `getAllocatedHeapSize()` 估算复制放大 |

## 文件覆盖

> 与 `{workdir}/files/f_data.part1.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/README.md` | .md | ✅ | 主体与实现一致（类型表、flag、`@DataAssist`、JSONPath 表已逐条抽查）；问题见一般 #5（示例缺宏 import）、#7（漏 5 个公开类型）、#6（与英文版不同步的源头）、轻微 #5（props 示例） |
| 2 | `f_data/README_en.md` | .md | ✅ | 与中文版逐节比对；问题见一般 #6（`@` 语义相反、8 vs 9、缺 flag 优先级/判等语义/IsDuration/IsIntegers 段）、一般 #5、轻微 #5；另 `:287` `package fountain::f_data.json:` 多一个冒号（排版） |
| 3 | `f_data/doc/REVIEW_2026-10-15.md` | .md | ✅ | 历史审查清单，日期与基准提交写明，§3「性能项未做基准」的口径正确；§2 第 78 行的 `tryParse` 修复承诺被 `DataIterable` 漏掉（一般 #3 的证据）；§5 的 flag 影响面分析与本轮一致 |
| 4 | `f_data/doc/RFC9535_COVERAGE.md` | .md | ✅ | 覆盖表主体与实现一致；文件清单/测试数过期，见轻微 #4 |
| 5 | `f_data/doc/RFC9535_GAPS.md` | .md | ✅ | 已过期（`in [null]`、filter 内 count/value、I-JSON 等「Missing」项均已实现），README:810 已明确标注「以 COVERAGE 与源码为准」——按 §13 误报边界不判问题，仅在轻微 #4 中提示与 COVERAGE 的口径差异 |
| 6 | `f_data/doc/spec/add-f-jsonrpc/specs/json-schema-validation/spec.md` | .md | ✅ | 归档变更的 spec delta，验收口径（`validate`、`fail-closed`、`maxErrors/maxDepth`、`toJson()`）与 `src/json/JsonSchemaValidator.cj` 的入口命名自洽；语言限制说明（静态/实例方法不能同名重载）与仓颉规则一致 |
| 7 | `f_data/doc/spec/fix-dataassist-local-mode/design.md` | .md | ✅ | 归档设计；探针结论（`Comparable & Equatable` 双路径报错、重复接口报错）与 proposal/tasks 自洽；`normalizeSuperTypes` 的文本前缀判定限制已显式说明 |
| 8 | `f_data/doc/spec/fix-dataassist-local-mode/proposal.md` | .md | ✅ | 与 design/tasks 一致（Why / What / Impact / 165 用例数）；未声称改公开 API，与实现一致 |
| 9 | `f_data/doc/spec/fix-dataassist-local-mode/specs/data-assist-compare/spec.md` | .md | ✅ | 三个场景（GT/LT、EQ、前置字段相等看后续）与 `generateCompare` 的修法对应，自洽 |
| 10 | `f_data/doc/spec/fix-dataassist-local-mode/specs/data-assist-supertypes/spec.md` | .md | ✅ | 四个场景覆盖宏生成/显式声明/重复声明/无冗余，与 design 的归一化规则一致 |
| 11 | `f_data/doc/spec/fix-dataassist-local-mode/tasks.md` | .md | ✅ | 全 `[x]`；Red→Green→回归链条完整，用例数（165/165）与 proposal 一致 |
| 12 | `f_data/doc/spec/optimize-f-data-json-escape/design.md` | .md | ✅ | 归档设计，含 `-O0` 探针数据（840 B/次 → 64 B/次，13.1×）与「字节下标扫描负收益」的反例；`D1` 的 `jsonNeedsEscape` 与 `src/json/DataJson.cj:27-34` 逐行一致 |
| 13 | `f_data/doc/spec/optimize-f-data-json-escape/proposal.md` | .md | ✅ | 与 design 一致；明确不改 `ToJsonString` 接口、不改容器 `valStr`；调用面（fprobe 两处）与仓内检索一致 |
| 14 | `f_data/doc/spec/optimize-f-data-json-escape/specs/data-json-serialization/spec.md` | .md | ✅ | 快路径/慢路径/基准三条 Requirement 与实现、`JsonEscapeFastPath_test.cj` 对应；`<= 128 B/次` 的门槛有 tasks 记录支撑 |
| 15 | `f_data/doc/spec/optimize-f-data-json-escape/tasks.md` | .md | ✅ | 全 `[x]`；探针数值、`git diff` 校验、两次全绿记录齐全，属自洽的归档 |
| 16 | `f_data/src/Data.cj` | .cj | ✅ | 仅 4 条 `public import`（base/json/path/validation）；未重导出 `f_data.exception` 但经 base 的 `public import` 传递可达；宏包按语言规则不可重导出（一般 #5 的依据） |
| 17 | `f_data/src/base/BreakingCommand.cj` | .cj | ✅ | 两个构造 + `new<T>` 便捷入口，`BaseCommand<Data, Unit>` 语义与 README:782-784、f_mvc/f_rpc 的 `handle (cmd: BreakingCommand)` 一致；无状态、无线程共享问题；`public` 对外可达，不判死代码 |
| 18 | `f_data/src/base/CollectionData.cj` | .cj | ✅ | 本部分主要问题集中地：一般 #2（丢元素）、#3（`DataIterable`）、#4（6 份复制）、轻微 #2（`toString` 哨兵）；`DEEP` 快路径与 `tryParse` 返 `None` 正确 |
| 19 | `f_data/src/base/ConcurrentMapData.cj` | .cj | ✅ | 一般 #4（对 `MapData` 整套复制）、轻微 #1（3 处不可达 throw）、轻微 #3（`toString` 键值逗号）；`DEEP` 快路径、`DataAny` 解包、`IGNORE_FIELD_TYPE_NOT_MATCH` 回退正确 |
| 20 | `f_data/src/base/Data.cj` | .cj | ✅ | `Data` 接口默认 `toData`/`fromData`/`tryFromData`（恒等）与 `DataParsable` 契约自洽；一般 #1（`extractPureString` 单引号越界） |

合计：`.cj` 5 个 / `.md` 15 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 3（一般 #1 单引号越界、#2 元素级静默丢弃、#3 `toString`/`tryParse` 直抛）；设计 1（一般 #4 复制 8 份、抽取先例已存在）；语言特性 2（一般 #1 的「函数体隐式返回值」+ String 字节下标语义、一般 #2 的 `?T` 与 `IGNORE_FIELD_NOT_CONVERTABLE` 交互）；可读性 1（轻微 #3 map 的 `toString` 形态）；安全性 0（本部分无外部输入拼串、无凭据、无越权路径；`DataIterable` 的异常路径不涉及信息泄露） |
| §1 死代码 | 1 | 已逐个搜引用：`extractPureString`（internal，5 个文件调用）、`DataCollection`/`DataCollectionIterator`/`DataIterable`/`DataConcurrentMap`/`DataConcurrentMapIterator`/`CollectionData`/`ConcurrentMapData`/`CollectionRawType`/`Data`/`BreakingCommand` 均为顶层 `public`，对外可达，按硬原则一不判；`protected` 声明在本部分为 0；`rawType` 实现属对外接口成员，仓内零消费只作信息（「对外 API，仓内无引用」）。命中 1：`ConcurrentMapData` 的 3 处恒假 `else if`（轻微 #1）。未命中项：无不可达 `return` 后语句、无 `Option` 被上游保证后的 `None` 分支、无未使用 import（`CollectionData.cj:18` 的 `f_collection.*` 与 `base/imported.cj:28` 重复，但名字确实在用，不判） |
| §2 重复逻辑 | 1 | 同文件两两比对了 `CollectionData.cj` 全部类型与 extend 的函数体（约 27 个）、`ConcurrentMapData.cj` 全部（约 12 个）、`Data.cj` 3 个、`BreakingCommand.cj` 3 个；跨文件比对了与 `MapData.cj` 的同构实现。命中一般 #4（6 份 `tryFromData` + `ConcurrentMapData`↔`MapData` 的四组复制）。未判：`DataIterable`/`DataCollection` 的 `parse` 抛异常文案不同（类型名不同，属必要的类型参数化）；`BreakingCommand.new` 与 `MVCBreakingCommand.new` 语义不同（后者带 status），不是重复 |
| §3 空实现 | 1 | 一般 #3（`DataIterable` 三个方法直接 `throw DataException()`，无 message、无行为）。其余：`DataCollection.tryParse` / `DataConcurrentMap.tryParse` 恒 `None` 是有意设计（`parse` 抛 `DataParsableException`，与 `DataDict` 同口径），不判；`Data.fromData/tryFromData` 的恒等默认实现属根接口语义（返回入参），不判；本部分无 `TODO`/`FIXME`、无 `catch {}` |
| §4 栈溢出 | 0 | 本部分无递归：`DataCollection`/`DataConcurrentMap` 的遍历都是单层 for；`tryFromData` 的递归只经 `DataAny`/集合元素，深度由**静态类型嵌套**决定（`Array<Array<…>>` 的编译期层数），不是输入长度。`DataAny` 是 `struct` + `let data`（`DataAny.cj:18-19`），构造不出自引用环。用户可控深度的递归在 `DataDict`/`DataList`/`JsonValue`（第 2 部分及其他模块），不在本部分 |
| §5 OOM | 0 | 未命中「按不可信长度预分配」：`Array<T>(1, repeat: x)` 长度恒 1；`ArrayList<T>()` 无预分配，容量随实际元素增长。转换是 1:1 物化（输入已在内存，输出同阶），没有拒绝路径的必要性论证；`toString` 的整串缓冲与输入同阶。唯一放大面是 `Byte → DataReal(Decimal)` 的装箱（待验证假设 #1），无测量前不定性 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据（`docs/LocalMode*.md` 与 `doc/spec/optimize-f-data-json-escape/design.md` 的取数都只覆盖 `toJsonString` 转义，不覆盖集合转换）。四个候选（字节装箱、`unsafeData` 切片、并发 map 迭代、`StringGenerator` 扩容）全部进「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`DataConcurrentMap` 不持锁，全部委托 `ConcurrentHashMap`；`DataCollection` 不引入同步，也不声明线程安全 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/批处理，无「提交后立刻 `get`」形态 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`、无循环内字符串 `+`（`toString` 走 `StringGenerator.append`）；`b.size > 1` 是 O(1) 判断。`toString` 的逐元素 `toData().toString()` 有一次中间串拷贝，属常数级，缺测量，见待验证假设 #4 |
| §7 降堆内存方案 | 0 | 无基线：集合转换的峰值（2× 假设）与字节装箱都未测量；按规则只进待验证假设，不写方案 |
| §8 降 CPU 方案 | 0 | 无基线（同上）；`doc/spec/optimize-f-data-json-escape/design.md` 的 840 B/次 → 64 B/次只适用 `escapeJsonString`，不外推到 `DataCollection.toString` |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：`DataCollection`/`DataConcurrentMap` 在 `toData()` 里被返回、被存进 `DataObject` 字段、被跨模块匹配，`data` 字段本身是调用方容器的别名；`tryFromData` 的产物同样是返回值。函数内唯一不逃逸的是 `tryFromDataToMap` 的局部 map（但它在第 2 部分且要返回）。且没有峰值内存对照，收益无法证明；`cjpm.toml` 已启用 `--enable-local-mode`，改造还需同 SDK 重编依赖 |
| §11 现有代码的 BUG（存量） | 5 | 一般 #1（单引号越界）、#2（元素级静默丢弃）、#3（`DataIterable` 契约）；轻微 #2（`toString` 分隔符）、#3（map 键值分隔符）。本轮逐条核对了：空集合/单元素/空串元素、`DEEP` 置位与不置位、`DataAny` 解包、`DataNone` 转集合、`DataDict`/`DataMap` 的 `Iterable<(String,Data)>` 与 `Iterable<(Data,Data)>` 分支不可重叠、`IGNORE_FIELD_TYPE_NOT_MATCH` 回退、`BreakingCommand` 两个构造的默认值——除上述 5 条外行为正确 |
| §12 并发安全与锁粒度 | 0 | 共享点核对：`DataConcurrentMap.data` 是 `public let`，为不可变包装；多线程访问全部走 `ConcurrentHashMap`/`ConcurrentMap` 接口（std 声明「线程安全的哈希表实现，支持高并发的读写操作」，`collection_concurrent_package_overview.md:11`），包装类自身无可变字段、无检查-然后-写入。`DataCollection` 包装任意 `Collection`，本模块不声明其线程安全，也无共享单例。`toString`/`iterator` 在并发写下的快照语义 std 未文档化——记「待确认」（待验证假设 #3），不作为缺陷。锁粒度 0（无锁可缩） |
| §14 功能完备性与 README 覆盖 | 1 | 一般 #7（README 漏 5 个公开类型，且 `:823` 自称列全）；`BreakingCommand`、`Data`、`CollectionRawType`、`CollectionData`、`ConcurrentMapData` 在 README 均有符号级提及。功能完备性：本部分无「承诺未实现」——`DataCollection`/`DataConcurrentMap` 的 `tryParse` 恒 `None` 有 `parse` 抛异常配套，属已声明能力而非缺口；一般 #5 的「示例缺宏 import」归 §13 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_data.part1.txt` 一一对应，无缺失。§13 命中 3：一般 #6（中英不同步）、轻微 #4（COVERAGE 失效条目）、轻微 #5（props 示例语法）；`RFC9535_GAPS.md` 按「README 已标注过期」不计 |

## 模块统计

> 仅统计本部分（5 `.cj` + 15 `.md`）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

**这一部分是 `f_data` 的类型地基：`Data` 根接口、集合/并发映射的 `Data` 包装、以及 `BreakingCommand`。**骨架是对的：`DEEP` 快路径只在「同类型且不要求深拷贝」时返回底层容器，其余一律走逐元素转换；`DataCollection`/`DataConcurrentMap` 的 `tryParse` 按项目约定返回 `None`、`parse` 才抛（`DataDict` 的注释把这条约定写清了）；`DataConcurrentMap` 没有引入任何自己的锁，把线程安全完全交给 `ConcurrentHashMap`；`BreakingCommand` 无状态、构造链与 f_mvc/f_rpc 的 `handle` 分支一致。本部分没有严重问题，也没有可证明的 OOM/栈溢出/并发缺陷。

**风险集中在「转换失败」这一条路径上，共 3 条。**
1. **元素级静默丢弃**（一般 #2）是最值得先处理的一条：默认 `DEFAULT_DATA_FLAG = SILENCE` 下，`Array<Int64>` 字段会因一个坏元素而**静默变短**，既不报错也不返回 `None`，下游按下标取值直接错位。它和「字段级整字段跳过」的既有语义不对称，属于会写进数据库的错误数据。
2. **`DataIterable` 的占位实现**（一般 #3）：`toString` 违背 `Data <: ToString`，且 f_data 自己的错误消息会因插值 `${data}` 二次抛异常，把原始诊断吞掉。`f_http` 的重名表单字段会生产这种值，不是理论路径。
3. **`extractPureString` 的单引号越界**（一般 #1）：一行判空就能修，但现状是 `tryFromData` 会抛 `IndexOutOfBoundsException`，破坏 `SILENCE` 的「不可转换 ⇒ `None`」承诺。

**维护性**：`ConcurrentMapData` 基本是 `MapData` 的复制，`CollectionData` 里 6 份 `tryFromData` 逐行同构，而 `MapData.cj:78-120` 已经证明「`creator` + 插入动作」的参数化在本模块可行。这组复制不是「看起来丑」——一般 #2 与轻微 #1 都出在复制体上，属于该收敛的信号。

**文档**是本部分第二大类问题，且都不是措辞层面的：README 主示例缺宏 import（照抄编译不过）、英文版的 `@` 语义与实现相反、自称列全的公开 API 漏了 5 个类型、`props` 展开示例的 setter 语法非法且与正文矛盾、`RFC9535_COVERAGE.md` 的文件清单指向不存在的文件。README 是这套库唯一的对外契约，建议与代码修复同批处理。

**没有测量数据支撑的性能结论一条都没写**：字节集合的逐元素 `Decimal` 装箱、`unsafeData` 切片的二次拷贝、`StringGenerator` 扩容、并发 map 迭代开销四个候选全部放在「待验证假设」里，等下一轮补 `cjprof`/分配量基线。本部分 12 条发现全部为存量，是否纳入修复待用户决定；本轮只读代码，未改源码、未跑构建。
