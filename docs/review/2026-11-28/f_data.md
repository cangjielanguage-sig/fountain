# f_data 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（142 个文件：127 个 .cj + 15 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 8 个分部分报告合并：`parts/f_data.part1..8.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

本部分覆盖 `Data` 家族的**标量包装与对象反射桥**（`DataAny / DataBool / DataReal / DataString / DataDateTime / DataDuration / DataNone / DataUnit / DataDict / DataList / DataTuples`）、转换骨架（`DataFields / DataConverter / DataParsable`）、反射对象层（`DataObject`）与登记表（`DataTypeRegistry`）。结构是对的：`DataAny` 解包统一在 `tryFromData` 首分支、`Duration` 解析器有完整用例、`DataTypeRegistry` 用并发容器 + 只增不减的版本号、`DataObject` 的字段访问全部收敛到 `ObjectFields`。

问题集中在三处：**失败语义被吞**（不可转换源变成默认对象、`SILENCE` 下仍抛异常、`tryParse` 抛异常）、**分支顺序把可转换路径挡在兜底之后**，以及**大量"只改类型名"的复制**（其中两处已发生漂移）。

### [严重][存量] `DataObject.populate` 把「不可转换源」变成「默认构造对象」，嵌套字段被静默写成空对象

- **位置**：`f_data/src/base/DataObject.cj:194-213`（兜底在 `:203-205`）；放大点 `f_data/src/base/DataFields.cj:59-66`
- **来源**：存量（`4be871f2f` 2026-10-02「统一换行符为 LF」迁入该段，逻辑早于该提交；快照无基线可比）
- **判据**：review-checklist §11（契约与实现不符 / 静默错误数据）、§3（`case _` 兜底把错误吃掉）
- **证据**：静态确定（行为链）—— `populate(src, target, flag)` 的 match 只有三种命中：`DataAny` 递归、`Iterable<(String, Data)>` 逐字段 set、`_ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0` 抛。`DEFAULT_DATA_FLAG = SILENCE` 含该位（`global_objects.cj:42-51`），于是**任意其它 Data**（`DataList`、`DataTuples`、`DataReal`、`DataString`、`DataUnit`、`DataInputStream`…）落到 `:205 case _ => target`。`populate(src, flag)`（`:208-213`）在 `DEEP` 未置位且源不是 `DataObject<T>` 时，先用 `create()` 造一个**全默认**实例再交给上面这个重载，于是返回 `Some(默认对象)`；`f_data_tryFromData`（`DataFields.cj:59-66`）把它原样当成功返回（`case Some(o: O) => o`）。
- **描述**：调用链是标准路径，不是理论路径：`@DataAssist` 生成 `tryFromData → f_data_tryFromData`（`macros/DataAssist.cj:634`）→ 字段写入 `MutableField` 先走 `convert<F>(data, flag)`（`MutableField.cj:60`）。因此 JSON 里把对象字段写成数组 `{"user":[1,2]}`（解出 `DataList`）、元组（`DataTuples`）、标量（`DataReal`/`DataString`）时，得到的是 `User()` 这个**字段全默认的对象**，而不是 `None` 或异常——随后按正常值写库。这与 README:791-793 与 `global_objects.cj:46-51` 的承诺（"越界/不可转换一律落 `None`，不回绕、不饱和、不抛异常"）相反。`populate(src, target)` 的"尽力填、填不了就原样返回"对 partial-update 是合理语义，但**新建实例重载**复用它就把"什么都没填"伪装成"转换成功"。
- **建议**：`populate(src, target, flag)` 的兜底改成返回 `None`（`?T` 本来就是 `None` 语义），只有真正走过 `Iterable` 分支才返回 `target`；或在 `populate(src, flag)` 里判断"源既非 `DataAny`、又非 `Iterable<(String,Data)>`"时直接 `None<T>`。同时补用例：`DataObject<User>.tryFromData(DataList())`、`DataObject<User>.tryFromData(DataReal(1))` 期望 `None`（或按 flag 抛），不得返回默认对象。若维护者确认"故意 best-effort"，则需在 README 的 flag 段改写承诺，否则文档与实现必须择一。

### [一般][存量] 类型不匹配兜底写在可转换分支之前：严格 flag 下字符串/时长转换不可达

- **位置**：`f_data/src/base/DataBool.cj:65-73`、`f_data/src/base/DataDuration.cj:58-70`、`f_data/src/base/DataDateTime.cj:64-88`、`f_data/src/base/DataUnit.cj:59-65`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §11（契约与实现不符）、§1（部分分支在给定 flag 下恒不可达）
- **证据**：静态确定 —— 四个 `match` 里 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw` 用了**通配模式 `_`** 且排在 `case x: DataString` / `case x: DataDuration` 之前。执行到后者的前提是 `IGNORE_FIELD_TYPE_NOT_MATCH` 已置位，因此该位未置位时（`flag: 0`、只带 `IGNORE_FIELD_NOT_CONVERTABLE`、只带 `IGNORE_NONE` 等）任何字符串都不会进入转换分支，而是先被判"类型不匹配"。
- **描述**：`convert<Bool>("true", flag: IGNORE_FIELD_NOT_CONVERTABLE)` 抛 `(${data}) does not match Bool`；同一调用在 `DEFAULT_DATA_FLAG` 下正常得到 `true`。`DataUnit` 还多一层：`DataString` 分支用 `DataUnit.tryParse(x.toString())`（`:61`），既不剥引号也不 trim，与 `DataBool/DataReal/DataDateTime` 走 `extractPureString` 的家族约定不一致；同样因为排在兜底之后，`convert<Unit>("()", flag: 0)` 直接抛"does not match"。`DataDuration` 的 `DataDateTime → Duration`（`:60-65`）同病：显式传"只忽略不可转换"时，一个本可换算的时间戳被当成类型错误。
- **建议**：把这四处 `case _ where …` 兜底移到所有具体类型分支之后（只保留一个最终兜底）；`DataUnit` 的字符串分支统一先 `extractPureString` 再判。补用例：每个类型用 `flag: IGNORE_FIELD_NOT_CONVERTABLE` 跑一遍正常值，断言仍能转换成功。

### [一般][存量] `DataDateTime` 的 `Duration → DateTime` 分支溢出时抛 `ArithmeticException`，逃出 `SILENCE`

- **位置**：`f_data/src/base/DataDateTime.cj:66-69`（`DateTime.UnixEpoch + x`）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §11（错误处理缺失 / 契约与实现不符）
- **证据**：静态确定 —— 官方文档明确 `DateTime operator +(Duration)` 在超出表示范围时抛 `ArithmeticException`（`time/time_package_api/time_package_structs.md:2541-2559`）。此处 `match (x.tryToDuration())` 只处理 `Some/None`，`+` 的溢出异常未捕获；`SILENCE` 的两个 IGNORE 位都拦不住异常（`global_objects.cj:46-51` 承诺"不抛异常"）。
- **描述**：`convert<DateTime>(DataDuration(Duration.second * Int64.Max), flag: SILENCE)` 直接抛 `ArithmeticException` 给调用方，而不是 `None`。这与同函数 `DataString` 分支（`:70-84`，catch 后按 flag 返回 `None`）、`DataBool`/`DataString` 等同类换算的处理方式不一致；`DataDuration.cj:60-65` 的 `x - DateTime.UnixEpoch` 是同一换算的反向，溢出面相同（DateTime 差值落在 Duration 秒域内，风险低，但同样未包 try）。
- **建议**：把换算包进 `try { … } catch (e: ArithmeticException) { if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) throw DataException(...) else None<DateTime> }`，保证 `tryFromData` 不向外抛非 `DataException`；补边界用例（`Duration.Max`、`Duration.Min`）。

### [一般][存量] `DataReal.tryParse` 会抛异常并拒绝 `Decimal` 合法输入：正则与 `Decimal.parse` 文法不一致

- **位置**：`f_data/src/base/DataReal.cj:227-234`（正则定义在范围外的 `f_regex/src/ExtendRegex.cj:52-56`）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §11（契约与实现不符：名为 `try` 却抛）
- **证据**：静态确定 —— `Regex.REAL_NUMBER` 是 `^[\+-]?\d+(\.\d*)?$`，`\.\d*` 允许**空小数位**；`Decimal.parse` 的文法是 `ValueString: IntegerPart.(FractionPart)? | .FractionPart | IntegerPart`，`FractionPart: Digits` 至少一位（`math_numeric/math_numeric_package_api/math_numeric_package_structs.md:5358-5382`）。因此 `"1."`、`"+1."` 通过正则后被 `DataReal(extractPureString(data))`（`:224-226`）交给 `Decimal.parse` 抛异常，`tryParse` 直接把异常抛给调用方。反方向：`"1e5"` 被正则拒绝（返回 `None`），而 `Decimal.parse` 支持指数形式。
- **描述**：`Data: DataParsable<Data>` 要求 `tryParse` 返回 `?Data`（`Data.cj:18`），同模块另外 9 个 `tryParse` 均不抛（`DataBool/DataDateTime/DataDuration/DataNone/DataUnit/DataString/DataAny` 已逐个核对）。仓内没有 `DataReal.tryParse` 调用点，影响面是 public API 的使用者（配置/文本导入这类入口）。当前 `DataParsable_test.cj` 只覆盖 `Duration`，这一类缺陷没有用例兜底。
- **建议**：正则改成 `^[\+-]?\d+(\.\d+)?([eE][+-]?\d+)?$`，或直接 `try { DataReal(Decimal.parse(d)) } catch (_: Exception) { None<Data> }`；补 `"1."`、`"1e5"`、`"-0.0"` 三个用例。

### [一般][存量] `toString` 递归遍历嵌套 `Data`，无深度上限（栈溢出面）

- **位置**：`f_data/src/base/DataObject.cj:147-162`（`:153` 的 `for + ${v}`）、`f_data/src/base/DataList.cj:41-50`、`f_data/src/base/DataDict.cj:41-54`、`f_data/src/base/DataTuples.cj:41-54`、`f_data/src/base/DataAny.cj:20-22`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定（无深度计数、无 visited 集合、无迭代化）+ 需实测（实际溢出深度）—— 五个 `toString` 互相递归：`DataList.toString` → `Data.toString` → 元素若仍是 `DataList/DataDict/DataObject` 则继续下钻（`:47`）；`DataObject.toString` 的 `case x: ToString ⇒ x.toString()`（`:149`）只在**最外层**可能换道，一旦数据结构本身由 `DataList/DataDict` 组成（JSON 解码产物），递归仍然发生。
- **描述**：嵌套深度完全由数据决定，代码侧没有任何上限（对比 `JsonSchemaValidator` 有 `maxDepth`）。深层 JSON 解成 `DataList` 嵌套后，任何 `"${data}"`、日志、`DataAny.toString`（`:20-22` 直接转发）都会走这条链；深度几千层即可吃掉线程栈（具体阈值需实测，取决于帧大小）。`f_data` 是库，调用方（`f_codec` 编解码错误信息、`f_mvc` 日志）到处插值 `Data`，触发点不止一处。
- **建议**：给 `toString` 加显式深度预算（例如 32 层后输出 `…`），或用显式栈迭代；至少给 `DataList/DataDict/DataObject` 三者加同一个深度参数。补用例：手工构造 1e4 层嵌套 `DataList`，断言 `toString` 不崩（输出截断）。

### [一般][存量] "只改类型名"的样板复制三处，其中两处已发生漂移

- **位置**：`f_data/src/base/DataInputStream.cj:37-160`（9 份 `tryFromData`）、`f_data/src/base/DataReal.cj:112-218`（10 组 `to*/tryTo*`）、`f_data/src/base/DataToString.cj:31-90`（20 个 `append`）与 `:162-224`（map 两套）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §2（只改类型名 / 近似重复且差异处即缺陷）
- **证据**：静态确定 —— 逐行比对：`DataInputStream` 的 `File/TcpSocket/UnixSocket/ByteBuffer/f_io.ByteBuffer/f_io.SyncByteBuffer/ChainedInputStream/BufferedInputStream` 八个 extend 的函数体完全同构，差异只有目标类型与错误文案；`DataReal` 10 个 `tryTo*` 都是 `if (data >= xxxRange[0] && data <= xxxRange[1]) { data.toXxx() } else { None }`；`DataToString` 20 个标量 `append` 的函数体逐字相同（`builder.append('${name}: ${value}; ')`）。
- **描述**：漂移已经发生，不是"以后可能"：① `DataReal.cj:208-211` 的注释自己记录了"曾误用 `int64Range` 判定 `UIntNative`"——这正是 10 份复制里改漏一份的后果；② `DataInputStream` 的文案是 `'current data does not match to X'`，与其它类型统一的 `'(${data}) does not match ${TypeInfo.of<X>()}'` 不一致，排障时拿不到源值；③ `DataToString` 的 `append<K,V,M>(Map)` 以 `builder.append('}')` 结尾（`:185`），`append(ConcurrentHashMap)` 以 `'}; '` 结尾（`:223`），同一族重载输出分隔符不同；④ `append<T>(name, value: ?T)` 的 `ToData` 分支 `';'` 后缺空格（`:95`），与相邻分支不一致。
- **建议**：`DataReal` 抽 `private func tryToInt<T>(range: Array<Decimal>, conv: (Decimal) -> T): ?T` 与 `toInt<T>(strategy, conv)`，10 组收敛成 10 行调用；`DataInputStream` 抽 `private func tryFromInput<T>(data, flag, name: String): Any`（八处只传类型名与错误文案）；`DataToString` 合并成一个 `append<T>(name: String, value: T): Unit where T <: ToString` 加 `?T/Object/Collection/Map` 四个分派，再单独修 map 的结尾分隔符。合并前先固化差异（错误文案、是否 trim、`?T` 的空值显示），按 §2 要求逐条显式参数化。

### [一般][存量] 「把 `Any` 解包成 `T`」的协议复制 7 份，flag 判定与异常类型各不相同

- **位置**：`f_data/src/base/DataFields.cj:37-43`、`:46-54`、`:68-78`；`f_data/src/base/DataAny.cj:55-64`、`:85-91`；`f_data/src/base/DataObject.cj:133-146`、`:231-242`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §2（近似重复导致行为漂移）+ §11（flag 语义不一致）
- **证据**：静态确定 —— 七处都是同一个形状：`match (T.tryFromData(...))` → `case x: ?T` → `case x: T` → 兜底。差异点：`DataFields.fromData` 用 `x ?? throw DataException`；`convert<T>` 兜底看 `IGNORE_FIELD_NOT_CONVERTABLE`；`internal_f_data_tryFromData` 同 flag 但**错误文案不同**（"cannot convert data to T" vs "data … cannot be converted to T"）；`DataAny.convertForMap` **无条件** `None`（不看 flag）；`DataAnyList.getData` 走 `x.getOrThrow()`（抛 `NoneValueException` 而非 `DataException`），且 `case x: ?T`/`case x =>` 两条在 `DataFields.fromData` 已抛异常的前提下不可达；`DataObject.get<V>` 的兜底查的是 `IGNORE_FIELD_NOT_FOUND`；`DataObject.populate<M,V>` 的兜底是 `continue`。
- **描述**：同一语义（"转换失败该怎么办"）有五种回答：抛 `DataException`、抛 `NoneValueException`、按 `NOT_CONVERTABLE` 抛、按 `NOT_FOUND` 抛、静默 `None`/跳过。`DataObject.get<V>(name, flag)`（`:133-146`）是最明显的一处：字段存在但类型不匹配时，`NOT_FOUND` 未置位就报 `field X is not found in T`（字段明明存在），`NOT_FOUND` 置位而 `NOT_CONVERTABLE` 未置位则静默返回 `None`——调用方拿不到"是缺字段还是转不了"。这也是第 7 条复制体上才出现的错误。
- **建议**：抽 `func unwrap<T>(raw: Any, flag: DataConversionFlag, ctx: () -> String): ?T`，把"`?T`/`T`/兜底"三支与 flag 判定收敛到一处，各调用点只传上下文文案；`DataObject.get` 的兜底改用 `IGNORE_FIELD_NOT_CONVERTABLE` 并把文案改成"cannot be converted"。合并后 `DataAnyList.getData` 的 `getOrThrow` 与 `DataAny.convertForMap` 的无条件 `None` 会被统一掉。

### [轻微][存量] 错误文案错误、以及 4 处 `parse` 抛无消息 `DataException()`

- **位置**：`f_data/src/base/DataUnit.cj:31-35`（`DataUnit.parse` 的报错写的是 "DataBool.parse receives …"）、`f_data/src/base/DataDuration.cj:29-33`（"mdnhimjskns" 乱码、单位表也不对）、`f_data/src/base/DataObject.cj:122-123`（"connot be converted"、"source field" 措辞）、`f_data/src/base/DataDict.cj:34-36` / `DataList.cj:34-36` / `DataTuples.cj:34-36` / `DataInputStream.cj:23-25`（`throw DataException()`，无 message）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §11（语义与命名/注释不符）、§3（静默/无信息失败）
- **证据**：静态确定 —— 逐行读到的文案与实现不符：`DataUnit.parse` 只接受 `"()"` 却提示 Bool 的取值；`DataDuration.parse` 的提示串是键盘乱码且提到的单位集（`m n i j k`）与实际 `d/h/m/s/ms/us/n s` 无关；`DataObject.set` 的兜底在"字段不存在"与"非可变字段"两种情况共用 `connot`（拼写错误）文案。
- **描述**：`DataDict/DataList/DataTuples/DataInputStream` 的 `parse` 抛无 message 的 `DataException`（`tryParse` 返 `None` 是正确的，注释也写了），调用方只能看到异常类型；再叠加上一条（字段/类型上下文缺失），线上排障基本靠猜。
- **建议**：四处 `parse` 改成 `DataParsableException('${TypeInfo.of<X>()} does not support string parsing')`；`DataUnit`/`DataDuration` 文案按实际语法重写；`DataObject.set` 区分"字段不存在"与"字段只读"（后者提示"field X is readonly"）。

### [轻微][存量] `DataString` 的私有无参 `init()` 无任何调用者

- **位置**：`f_data/src/base/DataString.cj:23-25`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §1（`private` 符号全仓无调用）
- **证据**：静态确定 —— `private init() { this("") }` 是 `struct DataString` 的私有构造，全仓搜索 `DataString()` 命中 0（同文件另两个构造 `DataString(String)` / `DataString(ToString)` 都有调用者）；Cangjie 不会隐式调用构造器。
- **描述**：死代码，且容易被误读成"存在空串单例"。
- **建议**：删除；如需空串，用 `DataString("")`。

### [轻微][存量] `DataList.toString()` 用「缓冲区字节数 > 1」当分隔哨兵，空串元素会吞掉逗号

- **位置**：`f_data/src/base/DataList.cj:41-50`（判断在 `:44`）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §11（空串未处理 / 边界）
- **证据**：静态确定 —— `StringGenerator.size` 是 UTF-8 字节数，初值 `'['` 恰为 1 字节，`s.size > 1` 实际等价于"已追加过非空内容"；`DataString.toString()` 原样返回 `data`（`DataString.cj:26-28`），空串渲染 0 字节。
- **描述**：`DataList` 里 `["", "a"]` 渲染成 `[a]`（两个元素挤成一个）、`["", ""]` 渲染成 `[]`（与空列表不可区分）。与第 1 部分 `DataCollection.toString` 同一写法、同一缺陷（`DataDict/DataTuples` 因为元素外层有 `()` 包裹而侥幸安全，但同样是脆弱写法）。
- **建议**：改成 `var first = true`（或下标计数）决定逗号；`DataDict/DataTuples/DataObject.toString` 的同款哨兵一并改掉。

### [轻微][存量] `DummyDataFields` 让 5 个 HTTP 类型"可当字段但序列化即崩"，且无注释说明

- **位置**：`f_data/src/base/DummyDataFields.cj:21-33`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §3（接口默认实现直接抛 `UnsupportedException`；有意 no-op 必须有注释说明）
- **证据**：静态确定 —— `toData()` 与 `tryFromData` 都无条件 `throw UnsupportedException()`，随后 `extend HttpContext/HttpRequest/HttpHeaders/HttpResponseBuilder/Form <: DummyDataFields<…>`。这些 extend 让上述类型满足 `DataFields` 约束，于是带这类字段的 `@DataAssist` 类**能编译**，但 `toData`/`toJsonString`/`toString` 一跑到该字段就抛。
- **描述**：这是典型的"编译期放行、运行期爆炸"接口；文件里没有一句注释解释为什么可以空（§3 要求有注释）。仓内当前没有这类字段，所以只是埋雷。
- **建议**：在接口上补 `/** 这些类型不支持 Data 表示，仅用于满足 @DataAssist 的字段类型约束；序列化时会抛。*/`；或改成编译期就能拒绝的约束（把 `DummyDataFields` 从 `DataFields` 里摘出来）。

### [轻微][存量] 日期格式设置是"一次性"的，但接口叫 setter、`ThreadLocal` 也没有清除入口

- **位置**：`f_data/src/base/DataDateTime.cj:90-109`（`setDefaultDateFormat`）、`:110-112`（`setCurrentThreadDateFormat`）、`:47-48`；文档 `f_data/README.md:826`
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §12.1（ThreadLocal 残留）、§13（文档未写限制）、§11（语义与命名不符）
- **证据**：静态确定 —— `setDefaultDateFormat` 在 `defaultDateFormat.value != ""` 时抛 `DataException("default date format has bean specified: …")`（"bean" 也是拼写错误），**同值重复调用同样抛**；并发下两个线程都传同一格式，CAS 失败的一方重新 load 后同样抛。`currentThreadDateFormat` 是文件级 `ThreadLocal<String>`，公开入口只接受 `String`，没有任何"恢复默认/清除"的方法（std `ThreadLocal.set` 支持传 `None`，`core/core_package_api/core_package_classes.md:4134-4144`），线程池复用时该线程后续请求会继承上一个请求设置的格式。README:826 只列了两个函数名，没写"只能设置一次"。
- **描述**：名字是 setter、行为是"只允许初始化一次"，调用方（尤其是配置化或测试里 reset）会拿到运行时异常；线程局部格式无法复位，属于"配置漂在池化线程上"的隐患。仓内当前无调用点（`setDefaultDateFormat`/`setCurrentThreadDateFormat` 全仓 0 引用），影响面是对外 API 使用者。
- **建议**：`if (fmt.value == format) return` 让同值幂等；不同值时抛带当前值的明确异常；补 `resetCurrentThreadDateFormat()`（`ThreadLocal.set(None)`）与 `resetDefaultDateFormat()`；README 补一行"进程内只能设置一次"。

### [轻微][存量] `DataParsable` 与 std `Parsable` 双协议并存，反射路径只认后者；`DataObject.tryParse` 反射未命中时抛 `NoneValueException`

- **位置**：`f_data/src/base/DataParsable.cj:21-24`（对照 std `std.convert.Parsable`）；`f_data/src/base/DataObject.cj:163-180`（`:166-169` 的 `staticFunction(...)?…getOrThrow()`）
- **来源**：存量（`4be871f2f` 迁入；快照无基线）
- **判据**：review-checklist §2（同一能力两份声明）、§11（错误类型不符契约）
- **证据**：静态确定 —— `DataParsable<T>` 的 `parse(s): T` / `tryParse(s): ?T` 与 std `Parsable<T>` 签名同形；`DataParsable` 被 `Data` 继承、被 `Int64/Duration/String…` 的 extend 与 `f_config.Config.getData<T>` 使用（`f_config/src/Config.cj:238-241`）；而 `DataObject.tryParse` 判的是 `typeInfo.isSubtypeOf(TypeInfo.of<Parsable<T>>())`，随后用 `TypeMemberInfos.staticFunction(typeInfo, 'tryParse', [String])` 反射取**声明成员**（`f_base/src/TypeMemberInfos.cj:132-134` 遍历 `typeInfo.staticFunctions`），扩展里提供的 `tryParse` 不在其中；取不到就 `getOrThrow()` 抛 `NoneValueException`，而 `tryParse` 的契约是"不抛、返回 `None`"。
- **描述**：使用者按 `f_data` 自己的文档/`f_config` 的用法实现 `DataParsable` 时，这条路不生效；实现 std `Parsable` 时，若用 `extend` 提供 `tryParse`，反射可能取不到并抛 `NoneValueException`（反射是否覆盖扩展成员属 `待确认`，取决于 SDK 版本）。两条协议并存本身就是让"该实现哪个"无法回答。
- **建议**：只保留一处——把 `DataObject.tryParse` 的判定改成 `DataParsable<T>`（`f_data` 内部协议），或让 `DataParsable <: Parsable` 合并；反射取不到时返回 `None<Data>` 而不是 `getOrThrow()`。

### [轻微][存量] `DataTypeRegistry.register` 用 `addIfAbsent` 静默忽略同名登记，与「同名注册启动直接失败」的约定不符

- **位置**：`f_data/src/base/DataTypeRegistry.cj:64-67`（`creators.addIfAbsent(qualifiedName, creator)`）
- **来源**：存量（`4be871f2f` 迁入；该文件头年份 2026，`@DataAssist` 自登记逻辑较早；快照无基线）
- **判据**：`fountain-baseline.md` §4（同名注册必须启动失败，不允许"先注册先赢/静默忽略"）
- **证据**：静态确定 —— 登记键是 `ClassTypeInfo.of<T>().qualifiedName`，冲突时返回已有的 creator，没有比较、没有日志、没有异常；注释只写"同名只登记一次（幂等）"。并发侧是安全的（`ConcurrentHashMap` + `addIfAbsent`，`size` 作版本号最多导致一次多余的全表拉取，`f_codec/src/default/DefaultCodec.cj:103-112` 的读序不会漏项）。
- **描述**：真发生同名（两个不同模块导出了同限定名的类型）时，`f_codec` 会拿到先登记者的创建者，解码出错误类型且无任何提示。概率低但后果是"静默用错类型"。
- **建议**：`addIfAbsent` 返回 `Some(existing)` 时比较 creator 来源（或在 debug 构建下断言/打日志），无法判定同一类型时抛 `DataException('duplicate data type ${qualifiedName}')`。

<!-- 第 3 部分 -->

### [严重][存量] #1 非空字段的 `@DataConverter` / `@DateTimeConverter` 永远不会生效：字段值被静默丢弃

- **位置**：`f_data/src/base/MutableField.cj:73-99`（`new<O, F>(name, getter: (O) -> F, setter: (O, F) -> Unit)` 的转换链里没有 converter 分支）；对照实现 `f_data/src/base/MutableField.cj:63-65`（另一个重载才有 `tryGetAnnotation<DataConverter<F>>`）
- **来源**：存量（`git blame -L 60,70` → `4be871f2fd 2026-10-02 runningW`）
- **判据**：review-checklist §2（近似重复导致行为漂移）、§11（契约与实现不符 / 静默失败）、§14.1（承诺了但只实现一半）
- **证据**：静态确定 —— ①`MutableField` 的两个 `new` 重载是逐行同构的两份转换链，唯一实质差异就是 nullable 版本多一段 `@DataConverter` 回退（`63-65`）与 `DataNone` 策略；②`@DataAssist[fields]` 生成字段表时先把类型 token 里的 `?` 剥掉（`f_data/src/macros/DataAssist.cj:549-553`），再生成 `MutableField.new<K, Inner>(name, {o => o.field}, {o, v => o.field = v})`：字段声明为 `?T` 时 setter 形参是 `?T` ⇒ 只能匹配 `73` 之前的 nullable 重载；字段声明为 `T`（非空）时 setter 形参是 `T` ⇒ 只能匹配 `73-99` 这个**没有 converter**的重载（lambda 参数类型使重载不含歧义）；③`DataConverter.cj:20` 的 `convert` 只被 `MutableField.cj:63-64` 这一处消费，全仓 `f_data/src` 没有第二处读取该注解。
- **描述**：`@DateTimeConverter(format)` 这类注解只在"字段类型可空"时才有机会被使用。业务里最常见的是非空 `DateTime` 字段（`fdemo/user/src/model/mvc/UserReqResp.cj` 一类 POPO 的常规写法），此时 converter 分支不存在 ⇒ 走 `DateTime.tryFromData` 的**全局默认格式**（`DataDateTime.cj:70-77`）。默认格式解析失败时：`DataDateTime.cj:78-83` 因 `SILENCE` 含 `IGNORE_FIELD_TYPE_NOT_MATCH` 而返回 `None` → `convert<F>` 返回 `None` → 落到 `MutableField.cj:93-97`，`SILENCE` 含 `IGNORE_FIELD_NOT_CONVERTABLE`，于是**返回 `true` 且不写字段**。整条链路不抛异常、不打日志，字段保持构造时的默认值——自定义日期格式的请求数据被静默丢掉。
- **建议**：把两个重载收敛成一份实现（见「优化可行性方案」），或至少把 `63-65` 的 converter 回退复制到 `83-92` 的分支之前；`DataConverter` 分支之后统一走"抛 `DataException` / 返回 `false`"，不要用 `true` 表示"没写进去"。

### [一般][存量] #2 数值类型的 `DataString` 分支排在全类型兜底 `throw` 之后：非 `SILENCE` flag 下字符串转换不可达且报「类型不匹配」

- **位置**：`f_data/src/base/NumberData.cj:30-47`（`Int8`）；同构位置：`67-84`（UInt8）、`104-121`（Int16）、`141-158`（UInt16）、`178-195`（Int32）、`215-232`（UInt32）、`252-269`（Int64）、`289-306`（UInt64）、`326-343`（IntNative）、`363-380`（UIntNative）、`397-401`（Float64）、`418-422`（Float32）、`439-443`（Float16），共 13 处
- **来源**：存量（`git blame -L 28,33` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（被前面 case 完全覆盖的分支）、§11（契约与实现不符）
- **证据**：静态确定 —— `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw …`（`30-31`）是**无类型约束的通配 case**，`DataString` 同样命中它；只有该条件为假（即 `flag` 含 `IGNORE_FIELD_TYPE_NOT_MATCH`）时才会继续往下走到 4 个 `case x: DataString where …` 分支。`DEFAULT_DATA_FLAG = SILENCE`（`global_objects.cj:42-51`）含该位，所以默认路径正常；但任何"严格"调用（`flag = 0`，或只带 `IGNORE_FIELD_NOT_CONVERTABLE` 而不带 `IGNORE_FIELD_TYPE_NOT_MATCH`）都会让 13 处字符串解析分支不可达。
- **描述**：`DataConversionFlag` 是 `UInt64` 位掩码（`global_objects.cj:18`），`flag = 0` 的语义是"不忽略任何问题"，最容易被外部使用者当作严格模式。此时 `Int64.tryFromData(DataString('123'), 0)` 抛的是 `'(${data}) does not match Int64'`——数据本身完全可转换，错误信息却指向类型不匹配，排查会往错误方向走。同一段代码在"只带 `IGNORE_FIELD_TYPE_NOT_MATCH`"的组合下又会抛 `'cannot be converted'`（`48-49`），两个 flag 的分工与命名承诺不一致。现有测试（`NumberData_test.cj:62-68`、`78-82`）全部用 `DEFAULT_DATA_FLAG` 覆盖字符串路径，没有一条覆盖严格 flag，因此该问题从未被回归测试触达。
- **建议**：把 4 个 `DataString` 分支整体移到 `case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0` 之前（`DataNone` 之后即可）；同时补一条 `NumberData_test`：`Int64.tryFromData(DataString('123'), 0)` 应得 `Some(123)`。13 处同构代码建议一并按 `DataReal` 分支的写法参数化（见「优化可行性方案」[CPU] #2）。

### [一般][存量] #3 `MapData` 把 `DataNone` 与「类型不匹配」都转换成**空 map**：空集合与「没有提供」无法区分

- **位置**：`f_data/src/base/MapData.cj:116-118`（`case _ where … => throw` 之后直接 `case _ => creator()`）
- **来源**：存量（`git blame -L 114,120` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（空值 / 边界未处理、与同类类型契约不一致）、§3（兜底 case 把语义吃掉）
- **证据**：静态确定 —— `tryFromDataToMap` 的 `match` 分支只有 `DataAny`、`DataMap`、`Iterable<(Data,Data)>`、`Iterable<(String,Data)>` 与兜底两档，**没有 `case _: DataNone`**；`DataNone` 与 `DataString`/`DataBool` 等不匹配输入一样落到 `118` 行 `creator()`。同文件其他路径的对照：`NumberData.cj:29`、`DataString.cj:51`、`OptionData.cj:28` 对 `DataNone` 一律返回 `None`。
- **描述**：`convert<HashMap<K,V>>(DataNone)` 得到空 map，`convert<HashMap<K,V>>(DataString('x'))` 在 `SILENCE` 下也得到空 map。调用方无法用返回值区分「源数据是 null」「源数据是标量（本该报错）」「源数据确实是空对象」三种情况；把 JSON `null` 反序列化进一个 `HashMap` 字段，会得到"存在但为空"的集合，而序列化回去时又变成 `{}`——数据形状被悄悄改写。旧 flag 语义下（不含 `IGNORE_FIELD_TYPE_NOT_MATCH`）此处会抛错，属"同一函数在不同 flag 下语义跳变"。
- **建议**：在 `Iterable` 分支之前补 `case _: DataNone => None<M>`（与 `Option<Map>` 的 `OptionData.cj:25-31` 组合即可得到 `None`）；兜底的 `case _ => creator()` 改成"`IGNORE_FIELD_NOT_CONVERTABLE` 时才返回空 map，否则抛"，与数值类型的分层保持一致。

### [一般][存量] #4 `CompiledSchema` 把调用方的可变 `JsonObject` 与可写 `HashMap` 一起交给请求路径：编译期校验可被后续修改绕过，未命中 pattern 会在请求线程写共享表

- **位置**：`f_data/src/json/CompiledSchema.cj:41-45`（`compile` 只保存引用）、`47-51`（`prop schema` 把同一个可变对象交回调用方）、`60-62`（每次 `validate` 把 `patterns` 传下去）；写入路径在 `f_data/src/json/JsonSchemaValidator.cj:88-98`（`regexFor` 未命中时 `table.add(pattern, re)`）
- **来源**：存量（`git blame -L 64,72` → `fac464dc9a 2026-10-25`；`compile`/`schema` 同批）
- **判据**：review-checklist §12.1（共享可变状态、检查-然后-写入）、§11（契约与实现不符）
- **证据**：待确认 —— 静态部分已确定：`CompiledSchema` 不复制 `schema`（`35-38` 直接赋值），`schema` prop（`47-51`）把该对象公开；`validate` 把 `private let patterns`（`33`）原样传给 `validateWithPatterns`，而后者在 miss 时会 `table.add(...)`（`JsonSchemaValidator.cj:94`），`std.collection.HashMap` 非并发容器（`stdlib/doc/libs/std/collection/collection_package_exception.md:14`："collection 包提供的容器类都不支持并发修改"）。缺的信息：仓内是否存在"compile 之后还改 schema"的调用方（`f_jsonrpc/src/server/JsonRpcMethodMeta.cj:48` 只编译一次并从 `paramsSchema` 取入参，未见二次修改）。
- **描述**：`compile` 的价值是"注册期把脏 schema 挡掉、请求期只查表"。但快照并不成立：只要调用方保留 `paramsSchema` 并再往里 `add` 一个 `pattern`（`JsonObject` 是可变类），编译期结论立刻过期，第一个请求走到该节点时 `regexFor` 未命中 ⇒ 在 N 个请求线程里同时对同一个 `HashMap` 调 `add` ⇒ 未定义行为（丢条目 / 结构损坏 / 抛 `ConcurrentModificationException`）。同一个缺口也让"注册期校验"变成"只校验了当时那一版文档"。
- **建议**：`compile` 里做一次深拷贝（或在文档中把 `compile` 定义为"接管入参所有权、之后不得修改"，并在 `schema` prop 上返回副本）；更稳妥的是让请求路径只读：`regexFor` 未命中时**就地编译并只用本次结果**（不写共享表），把"表里没有"当异常配置上报一次。两处任一改动都能消除请求线程写表。

### [一般][存量] #5 `ObjectFields.getObjectFields` 在 `computeIfAbsent` 回调里再次调用 `getObjectFields`（父类），落在 std `entryView` 明确警示的用法之外

- **位置**：`f_data/src/base/ObjectFields.cj:26-73`（`computeIfAbsent` 从 `26` 行开始，`66-70` 在回调内部通过父类静态 `dataFields()` 再次进入本函数）
- **来源**：存量（`git blame -L 26,26` / `35,38` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（死锁 / 重入）、§6.2（锁内调用外部回调）
- **证据**：待确认 —— `computeIfAbsent` 不是 std API，而是 fountain 自己的扩展（`f_collection/src/ExtendCollection.cj:61-69`），实现为 `entryView(key){ … }.getOrThrow()`；std 文档对 `entryView` 写明「注意参数 fn 中不能并发调用函数 entryView、remove、replace」（`collection_concurrent_class.md:1227-1233`，示例是 fn 里 spawn 后 `get()` 自锁），并说明"该操作具有原子性"。`66-70` 是在 fn 内部（同线程）再次调用 `entryView(otherKey)`，文档没有为同线程重入给出保证。缺的信息：std `entryView` 是否用"非重入的 bin 锁"实现（若子类与父类的 key 落到同一 bin，同线程重入即自锁）。
- **描述**：首次为某类型建字段表时，会在 `computeIfAbsent` 的临界区内触发父类的字段表构建。当前生产上能跑通，说明实现大概率是"每 key 独立锁 + 快照后统一提交"；但这段代码的任何重构（父类字段表改为懒加载、字段类型里嵌套同族类型）都可能把它变成启动期 hang，且没有任何限深/超时保护。该类问题在 CPU profile 里看不到，只会表现为"进程启动卡住"。
- **建议**：改成"先算后放"：`if (let Some(v) = allFields.get(t)) { return v }`；缺失时在**锁外**完整构建（含父类递归），最后 `allFields.addIfAbsent(t, built)` 并按返回值决定用谁的实例（与 `f_base/src/TypeMemberInfos.cj:79`/`159` 的"填完再发布"写法一致）。父类字段表也按同样顺序构建，天然消除嵌套 `entryView`。

### [一般][存量] #6 `CompiledSchema.checkDoc` 递归无深度上限：深嵌套 schema 在注册期爆栈（校验侧有 `maxDepth=64`，编译侧没有）

- **位置**：`f_data/src/json/CompiledSchema.cj:64-79`（`checkDoc` 对 `JsonObject`/`JsonArray` 逐层递归，无深度参数、无环检测）
- **来源**：存量（`git blame -L 64,72` → `fac464dc9a 2026-10-25`）
- **判据**：review-checklist §4（无界递归、深度由输入决定）
- **证据**：静态确定 —— 递归入口 `compile`（`41-45`）不接受任何深度参数；同一模块的请求期校验有 `ValidationOptions.maxDepth` 默认 64（`JsonSchemaValidator.cj:61`），编译期没有对应上限。递归深度 = schema 文档嵌套层数 × 1 帧，可达深度完全由 schema 作者（或生成器）决定，代码里没有任何常量上界。
- **描述**：`compile` 是注册/启动期调用（`JsonRpcMethodMeta.cj:48` 在构造期），schema 通常来自代码常量或配置文件。机器生成的深层 schema（例如 `oneOf` 套 `items` 的递归展开）会让 `checkDoc` 递归到栈耗尽，进程直接崩溃且没有可读错误。这类崩溃发生在启动期，回滚成本高。
- **建议**：给 `checkDoc` 加 `depth: Int64` 参数，超过常量上限（与 `ValidationOptions.maxDepth` 对齐，如 64/128）抛 `IllegalArgumentException('schema nesting too deep at ${path}')`；同时把 `path` 改成"报错时才拼"（见「优化可行性方案」[CPU] #3）。

### [一般][存量] #7 结构校验只覆盖一半关键字：`items` / `properties` / `additionalProperties` 等取值类型错误仍要等第一个请求才暴露，`items: "x"` 会让校验静默失效

- **位置**：`f_data/src/json/CompiledSchema.cj:81-141`（`checkObject` 只校验 `pattern` / `required` / `type` / `enum` / `min*` / `max*` / `nullable`），承诺在 `f_data/src/json/CompiledSchema.cj:24-26`（"关键字取值类型不对（`pattern: 1`、`required: "x"`）在注册期就报错"）
- **来源**：存量（`fac464dc9a 2026-10-25`）
- **判据**：review-checklist §14.1（半成品：只处理部分输入）、§13（注释承诺与实现不一致）
- **证据**：静态确定 —— 承诺源：`24-26` 的类注释；缺失证据：`checkObject` 全文没有 `properties` / `items` / `additionalProperties` / `allOf` / `anyOf` / `oneOf` / `not` / `false` 等关键字的分支，全仓 `CompiledSchema.cj` 搜这些字面量零命中。请求期才做这些检查：`JsonSchemaValidator.cj:333-339`（`properties must be an object`）、`321-327`（`items` 直接 `validateDoc(items, …)`，不判类型）。
- **描述**：`{"type":"object","properties":1}` 能通过 `compile`，之后每个请求都在 `JsonSchemaValidator.cj:337` 报 `$schema` 错误；`{"items":"x"}` 更糟：`validateDoc` 把字符串当 schema 用，所有元素都被判通过——数组元素的约束**静默消失**，而注册期一声不响。这与"脏 schema 在启动时就报错"的设计目标相反，也让 `CompiledSchema` 的文档结论不成立。
- **建议**：`checkObject` 补齐结构型关键字：`properties` / `patternProperties` / `definitions` / `$defs` 必须是 `JsonObject`，`items` / `additionalProperties` / `not` 必须是 `JsonObject` 或 `JsonBool`，`allOf` / `anyOf` / `oneOf` 必须是 `JsonArray` 且元素为对象；同时补两条 `CompiledSchema_test` 用例（`properties: 1`、`items: "x"` 都应在 `compile` 抛错）。

### [一般][存量] #8 `ReadableField` 是 internal `sealed` 类，却被 README 当成对外扩展点，`ObjectFields.readableField` 还在 public 签名里返回它

- **位置**：`f_data/src/base/ReadableField.cj:32`（`abstract sealed class ReadableField`）；`f_data/src/base/ObjectFields.cj:95-97`（`public func readableField(name: String): ?ReadableField`）；文档侧 `f_data/README.md:797`、`f_data/README.md:832`
- **来源**：存量（`git blame -L 32,32` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §13（文档与实现不一致）、§14.2（扩展点未真正开放）
- **证据**：静态确定 —— `ReadableField.cj:32` 没有 `public` 修饰（包内可见），且 `sealed` 限定只能在本包内继承；`MutableField.cj:18` / `ReadonlyField.cj:18` 是 `public` 子类。README `797` 行把 `ObjectData<T>` / `DataFields<T>` / `ObjectFields` / `MutableField` / `ReadonlyField` 一并列为"数据对象扩展点"，`832` 行把 `readableField(name): ?ReadableField` 记为公开 API。
- **描述**：下游模块既不能声明 `let f: ReadableField`，也不能继承它（`sealed`），只能拿到 `MutableField`/`ReadonlyField` 的具体类型（可用，但拿不到基类的 `protected static newGetter` 等）。文档把"内部基类"和"对外扩展点"混为一谈，使用者按 README 写 `ReadableField` 类型标注会编译失败。
- **建议**：二选一并同步 README——① 若确实是对外扩展点：`public abstract class ReadableField`（去掉 `sealed`，同时把 `protected static newGetter` 作为对外钩子写进 README）；② 若只是内部基类：README 改为"`MutableField` / `ReadonlyField` 是扩展点，`ReadableField` 为内部基类（`name` / `get` / `validator` 可读）"，并考虑把 `readableField` 的返回类型收窄为二者之一（或用内部包装类型）。

### [一般][存量] #9 `NumberData` 13 份逐行同构的实现已经产生漂移：`BigInt` / `Decimal` 缺 `IGNORE_FIELD_NOT_CONVERTABLE` 抛错分支

- **位置**：`f_data/src/base/NumberData.cj:451-468`（BigInt）、`470-487`（Decimal）；对照 `240-275`（Int64）的 `270-272` 分支；字面量复制点在 `32-47` / `69-84` / `106-121` / `143-158` / `180-195` / `217-232` / `254-269` / `291-306` / `328-343` / `365-380` 共 40 处同一正则
- **来源**：存量（`4be871f2fd 2026-10-02`；漂移的历史证据见 `NumberData_test.cj:22-26`、`78-81`——IntNative 曾因漏写 `-?` 使 `-5` 转换失败）
- **判据**：review-checklist §2（只改类型名的重复逻辑、近似重复导致行为漂移）、§11（错误处理不一致）
- **证据**：静态确定 —— 10 个整数 + 3 个浮点类型的 `tryFromData` 结构完全一致（`DataAny` → `DataReal`×4 策略 → `DataNone` → 类型不匹配 → 4 个 `DataString` 正则分支 → `IGNORE_FIELD_NOT_CONVERTABLE` 抛错 → `None`）；`BigInt`（`462-465`）与 `Decimal`（`481-484`）在字符串分支之后**直接** `case _ => None<BigInt>`，没有 `case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw`。
- **描述**：同一组 flag 下行为按类型分叉：`flag = IGNORE_FIELD_TYPE_NOT_MATCH`（不含 `IGNORE_FIELD_NOT_CONVERTABLE`）时，`Int64.tryFromData(DataBool(true), flag)` 抛 `cannot be converted`，而 `BigInt.tryFromData(DataBool(true), flag)` 静默返回 `None`。调用方若靠异常区分"数据脏"与"字段可空"，在 `BigInt` 字段上会当成"没有值"。这类漂移的根因是 13 份复制粘贴：过去 IntNative 漏 `-?` 已经因此出过一次数据转换缺陷。
- **建议**：把"策略选择 + 字符串解析 + 错误分级"抽成三个共用 helper（例如 `parseIntText(text, flag, strategy)` 与 `applyReal(data, flag, toReal)`），各类型只保留 `TypeInfo`/转换函数；顺手补齐 BigInt/Decimal 的 `IGNORE_FIELD_NOT_CONVERTABLE` 分支，并加一张表驱动测试（13 类型 × {DataNone, DataReal 越界, 合法串, 非法串, DataBool} × {SILENCE, 0, WRAPPING}）。

### [轻微][存量] #10 `ObjectFields` 的反引号剥离分支恒不成立，且与 `ReadableField` 构造函数重复实现；`name[1..size-1]` 对单字符名越界

- **位置**：`f_data/src/base/ObjectFields.cj:35-38`；对照 `f_data/src/base/ReadableField.cj:41-45`
- **来源**：存量（`git blame -L 35,38` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（恒假分支）、§2（同一换算在两处各写一遍）、§11（边界）
- **证据**：静态确定 —— `ReadableField` 构造函数已经把 `` `name` `` 剥成 `name`（`41-45`），`populateField` 收到的 `f.name` 必然不以反引号开头（`ReadableField.name` 是 `public let`，只在构造时赋值，无 setter）；因此 `35` 行的 `name.startsWith('`')` 对正常字段名恒为假。两处剥离逻辑还不一致：构造函数只判首字节（不校验尾部反引号），`ObjectFields` 无条件切掉首尾各一字节。
- **描述**：死分支增加了"字段名到底剥没剥"的歧义；若真出现名字为 `` ` ``（单字节）的输入，`name[1 .. 0]` 是非法区间会抛异常而非明确报错。当前从源码标识符无法构造出这种名字，故只记轻微。
- **建议**：删掉 `ObjectFields.cj:35-38`（剥离统一由 `ReadableField` 构造函数负责），并把 `41-45` 改成 `if (name.size >= 2 && name[0] == b'`' && name[name.size - 1] == b'`')`，避免"只有半边反引号"时静默截断。

### [轻微][存量] #11 README 列出的 flag 名 `DEFAULT` / `WRAPPING` / `THROWING` 在源码中不存在

- **位置**：文档 `f_data/README.md:788-790`；源码 `f_data/src/base/global_objects.cj:30-32`、`51`
- **来源**：存量（README 与 `global_objects.cj` 均为 `4be871f2fd 2026-10-02`；本部分只读源码侧，README 属其他子轮文件）
- **判据**：review-checklist §13（API / 配置名与源码不符）
- **证据**：静态确定 —— README `788-789` 写 `` `DEFAULT`、…、`DEEP`、`WRAPPING`、`THROWING`、`SATURATING_ON_INT_OVERFLOW` ``，`790` 行的优先级说明又写成 `WRAPPING > THROWING > SATURATING`；源码里只有 `DEFAULT_DATA_FLAG`（`51`）、`WRAPPING_ON_INT_OVERFLOW`（`30`）、`THROWING_ON_INT_OVERFLOW`（`31`）、`SATURATING_ON_INT_OVERFLOW`（`32`），全仓 `f_data/src` 搜 `DEFAULT\b` / `const WRAPPING` / `const THROWING` 只命中测试注释（`NumberData_test.cj:26`、`94`），没有同名声明的常量。同一段 README 的 `792-793` 行用的又是正确名字。
- **描述**：按 `788-789` 行写 `flag: WRAPPING` 会编译失败（未声明标识符）；同一段落前后自相矛盾，读者无法判断哪个名字可用。
- **建议**：`788-789` 行改为 `DEFAULT_DATA_FLAG`、`WRAPPING_ON_INT_OVERFLOW`、`THROWING_ON_INT_OVERFLOW`，与 `792-793` 行统一。

### [轻微][存量] #12 `@FieldAlias` 按 `,` 拆分后不 trim：`@FieldAlias("a, b")` 静默注册带空格的别名

- **位置**：`f_data/src/base/ObjectFields.cj:52-56`（`for (n in x.name.split(','))`）
- **来源**：存量（`git blame -L 53,53` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界 / 输入未规范化）
- **证据**：静态确定 —— `split(',')` 的结果直接传给 `populateField(n, f)`，没有 `trimAscii()`、也没有空串校验；别名注册后按精确字符串查找（`readables.get(name)`，`95-97`）。
- **描述**：`@FieldAlias("name, nickName")` 会注册别名 `" nickName"`（带前导空格），而 `set("nickName", …)` 找不到字段、走 `IGNORE_FIELD_NOT_FOUND` 后静默无操作；`@FieldAlias("")` 会注册一个空名条目。两者都不报错，排查成本高。
- **建议**：`for (raw in x.name.split(',')) { let n = raw.trimAscii(); if (n.isEmpty()) { throw DataException('empty field alias for ${f.name}') }; populateField(n, f) }`。

### [轻微][存量] #13 `DataFields.tryFromData` 返回 `Any`：同一类型内既返回裸 `T` 又返回 `?T`，`Option<T>` 在裸值分支会退化成「无法转换」

- **位置**：`f_data/src/base/NumberData.cj:25-26`（`x.tryToInt8()` 返回 `?Int8`，`x.toInt8(strategy: Wrapping)` 返回裸 `Int8`）；`f_data/src/base/OptionData.cj:25-31`（直接转发 `T.tryFromData` 的结果）
- **来源**：存量（`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）、§10（类型使用）
- **证据**：静态确定（后果需实测）—— `tryFromData` 的签名是 `Any`（`DataFields`），`NumberData` 内 4 个策略分支返回裸值、其余返回 `?T`；`convert<T>`（`DataFields.cj:46-54`）与 `internal_f_data_tryFromData`（`68-79`）都用 `case x: ?T` + `case x: T` 双分支兜住，`DataObject.get`（`DataObject.cj:135-141`）同样双分支；`Option<T>.tryFromData` 不加包装直接转发，因此对 `Option<Int8>` 来说：`SILENCE` 下 `?Int8` 恰好就是 `T`（匹配），但显式 `WRAPPING_ON_INT_OVERFLOW` 下返回裸 `Int8`，既不是 `?Option<Int8>` 也不是 `Option<Int8>`，会被判为转换失败。
- **描述**：现有调用点都靠"双分支"这个约定活下来，任何一个新调用点写 `if (let Some(v: T) <- F.tryFromData(...))` 都会把策略分支的裸值结果当成失败。`Option<T>` 是唯一在行为上已经不对的组合（显式溢出策略 + 可空数值字段）。
- **建议**：把 `tryFromData` 的返回类型统一成 `?T`（裸值分支 `Some(v)`），`Option<T>` 的转发改为 `T.tryFromData(...)` 后显式 `Some(...)`；这是一次跨 20+ 个 extend 的机械改动，可先用 `DataFields.cj` 的 `convert` 做归一化入口，逐步收窄类型。

### [轻微][存量] #14 父类字段合并依赖"字符串拼出来的泛型类型名"与父类静态 `dataFields`，任一不满足即静默跳过父类字段

- **位置**：`f_data/src/base/ObjectFields.cj:66-71`
- **来源**：存量（`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（静默失败 / 契约与实现不符）
- **证据**：待确认 —— 代码用 `TypeInfo.get('fountain::f_data.base.ObjectData<${superClass.qualifiedName}>')` 判断父类是否实现 `ObjectData`，并用 `superClass.getStaticFunction('dataFields', [])` 反射取值；两条任一返回 `None` 时整个 `if` 短路，父类字段**不合并、不报错**。缺的信息：是否存在"父类来自其他包 / 泛型父类 / 父类由 `@Bean` 生成"的实战组合（`@Bean` 生成的类型是否都带静态 `dataFields` 未在本部分取证）。
- **描述**：继承式 POPO 是最常见的建模方式；一旦父类字段没被合并，`set("parentField", …)` 会走 `IGNORE_FIELD_NOT_FOUND`（`DataObject.cj:125-127`，`SILENCE` 下）静默忽略，或抛"field not found"——都指向子类，而不是"父类字段表没合并"。当前无测试覆盖继承合并路径（本部分 4 个测试文件均无多级继承用例）。
- **建议**：把两条 `None` 分支区分开：`getStaticFunction` 取不到就直接抛 `DataException`（类型声称实现 `ObjectData` 却没有 `dataFields` 属硬错误）；`TypeInfo.get` 失败时降级为"直接调用父类 `dataFields`"（不做子类型判断），并补一条"父类 + 子类各带字段"的单元测试。

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

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

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 本部分**未提出带基线的优化方案**：`f_data` 在 `docs/LocalMode.md` / `docs/LocalMode-O2-Plan.md` 里只有 `toJsonString` 转义相关的取数（见 `doc/spec/optimize-f-data-json-escape/design.md`），集合转换与 `toString` 没有任何测量数据。按 reviewer 规则，这些候选只进「待验证假设」，不写成收益结论、不进 `todo.md` / `tasks.md`。

<!-- 第 2 部分 -->

> 本部分**未提出带基线的优化方案**。`docs/LocalMode.md` / `docs/LocalMode-O2-Plan.md` 与 `doc/spec/optimize-f-data-json-escape/design.md` 的取数只覆盖 JSON 转义，不覆盖标量解析、反射字段访问与登记表拉取。按 reviewer 规则，候选只进「待验证假设」，不写成收益结论、不进 `todo.md` / `tasks.md`。

<!-- 第 3 部分 -->

### [堆内存] #1 `ObjectFields` 每类型长期持有两份 `HashMap` + 注解缓存三份键

- **现状**：`ObjectFields` 为每个 `ObjectData` 类型缓存 `readables`（全部字段，`ObjectFields.cj:21`）与 `mutables`（可变字段子集，`22`），`mutables` 恒为 `readables` 的子集；`ReadableField.annotations` 另按 `(注解类型, 类, 字段名)` 再存一份（`ReadableField.cj:33`）。稳态常驻 ≈ 类型数 × 字段数 × (2 条目 + 命中注解条目)，全部活到进程结束（`static let`，`19`）。
- **方案**：`mutables` 改为"`HashSet<String>` 名字集合 + 从 `readables` 取值"，或干脆不缓存、`mutableField(name)` 时 `readables.get(name)` 后 `match (f) { case x: MutableField => … }`；注解缓存改为按 `ClassTypeInfo` 分桶（`HashMap<String, ?Annotation>`），去掉 `AnnotationTag` 的 `HashBuilder` 与 `TypeInfo` 重复键。
- **预期**：字段条目数减半；`set` 路径少一次 `AnnotationTag` 构造 + 3 次 hash 合并（数量级：10 个类 × 30 字段 × 2 条目 ≈ 600 条目 → 300，绝对量不大，收益主要在 `set` 路径的 CPU 而非常驻堆）。
- **代价**：`mutableField` 从"直接命中"变成"命中 + 一次 `is` 判断"，`mutableFields()` 从 `values()` 变成"过滤迭代"，都是 O(n) 级别的小成本；需要回归 `@DataAssist[fields]` 生成的全部字段表用例。
- **验证**：`getAllocatedHeapSize()` + RSS 在"加载 N=200 个 POPO 类型"后对照；`cjpm bench -O2` 对照 `set` 吞吐。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #2 `NumberData` 字符串→数值转换：一次转换最多 4 次 `trimAscii` + 4 次相同正则匹配

- **现状**：`NumberData.cj:32-47` 等 13 处，每个 `DataString` 分支的 `where` 条件都会重新执行 `x.toString().trimAscii()` 与 `#'…'#.regex(solid: true).matches(...)`；只有最后一个分支的 flag 条件命中时才真正取值。`solid: true` 走进程级正则表（`JsonSchemaValidator.cj:65-66` 注释），所以**没有**重复编译正则的开销，但同一次转换会重复做 1–4 次裁剪 + 匹配（`trimAscii` 每次分配一个新 `String`）。
- **方案**：在 `match` 之前 `let text = match (data) { case s: DataString => s.toString().trimAscii(); case _ => '' }`，用一个绑定变量 + 单一 `where (regex.matches(text))` 分支，内部再按 flag 选策略（`ignoreNotConvertable` / `Wrapping` / `Throwing` / `Saturating`）；13 处同构代码合并为一个按 `(TypeInfo, toReal)` 参数化的 helper。
- **预期**：字符串转换路径的临时串分配与正则匹配次数降到 1 次；具体降幅需 `cjpm bench` 对照（同 SDK、`-O2`、同输入）。
- **代价**：`match` 结构改为"先归一化再分派"，与现有 13 份结构差异较大，必须配表驱动等价性用例（越界、`0x`/`0o`/`0b` 前缀、正负号、空白）。
- **验证**：`cjpm bench -O2` 跑 `String→Int/Float` 的 1e6 次转换（改前/改后中位数 + 离散程度）；`cjprof record` 看 `trimAscii`/`Regex.matches` 自耗时占比是否下降。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #3 `CompiledSchema.checkDoc` 每个节点都拼一次 `path` 字符串

- **现状**：`CompiledSchema.cj:69`、`74` 对每个子节点做 `'${path}/${key}'` 插值，深度 d 的节点要复制 O(d) 个字符，整棵树 O(节点数 × 平均深度) 次分配；而 `path` 只在校验失败时才有用。
- **方案**：递归只带 `(parent, segment)` 或索引数组，报错时再拼完整路径（`invalid(path, …)` 是唯一消费点，`143-145`）。
- **预期**：大 schema（数百节点）编译期分配量下降；具体幅度需测。
- **代价**：报错路径拼装逻辑要改到 `invalid` 内部；错误信息格式保持不变。
- **验证**：对同一份 500 节点 schema 反复 `compile` 1e4 次，比较耗时与 `getAllocatedHeapSize()`。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] #4 `ReadableField.tryGetAnnotation` 每次调用都构造 `AnnotationTag` 并算一次 3 段 hash

- **现状**：`ReadableField.cj:47-50` 每次 `MutableField.set`（`MutableField.cj:25`）都会走一次：`TypeInfo.of<A>()` + `HashBuilder().append(annotationType).append(typeInfo).append(name).build()`（`ReadableField.cj:22-24`），然后查 `ConcurrentHashMap`。命中率高（同一字段反复 set），但每次都要付构造成本。
- **方案**：把 `AnnotationTag` 换成 `(ClassTypeInfo, String)` 两级缓存（外层类型 → 内层字段名 → 注解），或用 `classTypeInfo` + 字段名拼成一次性 key 常量（`ReadableField` 构造时就生成，字段级只算一次）。
- **预期**：`set` 路径省一次 `HashBuilder` 与一次字符串拼接；需 profile 才能说占比。
- **代价**：缓存结构变化，需回归注解查找（含 `` `name` `` 反引号回退路径，`60-64`）。
- **验证**：`cjprof record` 跑 JSON→PO（1e5 字段写入）看 `tryGetAnnotation` 自耗时占比；加计数埋点统计命中率。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

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

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

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

<!-- 第 1 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DataCollection<Array<Byte>, Byte>` 的逐元素路径把每个 `Byte` 装箱成 `DataReal(Decimal)`，大 blob 的 `toString` / `DEEP` 转换放大 CPU 与分配 | `CollectionData.cj:41-51`（`toString`）、`:83-96`（逐元素转换）；装箱源 `NumberData.cj:55-58`（`UInt8.toData → DataReal`） | 分配量与自耗时占比 | `cjprof record` 跑 1 MB `Array<Byte>` 的 `toData().toString()` 与 `Array<Byte>.tryFromData(data, DEEP)`，与 `Array<Byte>.toString()` 对照；同 SDK、`-O2`、3 轮取中位 |
| 2 | `Array<T>.tryFromData` 的 `list.unsafeData()` 若返回切片副本，会让转换峰值约 2×（ArrayList 缓冲 + Array） | `CollectionData.cj:90`；`f_base/src/UnsafeData.cj:24-29` | 转换前后分配量 / 峰值 RSS | 1e6 个 `Int64` 的 `DataCollection→Array` 转换，读 `getAllocatedHeapSize()` 前后差与 RSS；确认 `Array` 切片是否复制（同一用例看分配量是否≈2×元素体积） |
| 3 | `DataConcurrentMap.toString()`/迭代在并发写下的开销与一致性（std 未文档化 `ConcurrentHashMap` 迭代器的快照语义） | `ConcurrentMapData.cj:34-55` | 并发写下的迭代异常率、耗时、元素数偏差 | 10 线程持续 `data.add/remove`，另一线程循环 `toString()`，记录单次耗时 P50/P99 与元素数偏差 |
| 4 | `DataCollection.toString` 的 `StringGenerator` 按倍增扩容，大集合（10 万元素）产生多次整块复制 | `CollectionData.cj:42-50` | 扩容次数、复制字节数、耗时占比 | 10 万元素 `Array<Int64>` 跑 `toData().toString()`，`cjprof` 看分配热点；或用 `getAllocatedHeapSize()` 估算复制放大 |

<!-- 第 2 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DataReal.tryParse` 每次调用都重建一个 `Regex`（`Regex.REAL_NUMBER` 的 getter 体是 `#"…"#.regex(solid: true)`），标量文本解析的固定开销可能远大于 `Decimal.parse` 本身 | `DataReal.cj:229`；getter 在 `f_regex/src/ExtendRegex.cj:52-56` | 单次 `tryParse` 的自耗时占比与分配量 | `cjprof record` 跑 1e6 次 `DataReal.tryParse("123.45")`（`-O2`，3 轮取中位）；与 `try { Decimal.parse }` 版本对照 |
| 2 | `DataObject` 的 `iterator/toString/populate` 每字段一次反射调用（`ReadableField.get` → 反射 getter），大对象批量转换时是主要成本 | `DataObject.cj:98-101`、`:153`、`:199-201` | 反射调用占比、每字段耗时 | `cjprof` 跑 1e4 次 `@DataAssist` 对象 `populate`（20 字段），对比手工赋值的 `-O2` 基准 |
| 3 | `DataToString` 的 20 个标量重载每次 `append` 生成一个临时插值串，`toString` 再整串复制一次，大集合/宽对象峰值约 2× | `DataToString.cj:31-90`（`:25` 整体复制） | 分配量、峰值 RSS | 20 字段对象循环 `toString` 1e5 次，读 `getAllocatedHeapSize()` 与 RSS，和 `StringBuilder` 直拼版本对照 |
| 4 | `DataTypeRegistry.snapshot()` 每次全表复制为 `Array`，类型注册量大时启动期有一次 O(N) 分配尖峰 | `DataTypeRegistry.cj:70-76`（调用方 `f_codec/src/default/DefaultCodec.cj:103-112`） | 注册 1e3/1e4 类型时的耗时与分配峰值 | 压测脚本注册 N 个类型后触发一次 `pullRegisteredTypes`，记录耗时与 `getAllocatedHeapSize()` 差值 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字符串→数值转换是 JSON→PO 的热点，重复 `trimAscii` + 正则匹配占其自耗时大头 | `f_data/src/base/NumberData.cj:32-47` | 该函数自耗时占比、分配次数 | `cjprof record` 跑 10k 行 JSON→POPO（含字符串数值字段），看 `NumberData`/`trimAscii`/`Regex.matches` self time |
| 2 | 每次 `MutableField.set` 都构造 `AnnotationTag` 是 `set` 路径的固定开销 | `f_data/src/base/ReadableField.cj:47-50` | 调用次数 × 单次耗时、命中率 | 加计数器埋点（命中/未命中）+ `cjprof` 跑 1e5 次 `populate` |
| 3 | `checkDoc` 的 `path` 拼接在启动期占 `compile` 的可观比例 | `f_data/src/json/CompiledSchema.cj:64-79` | 分段计时（`MonoTime` 包 `checkDoc` 与 `compile`） | 对 500 节点 schema 重复 compile 1e4 次，记录前后耗时 |
| 4 | 大 map 的 `DataMap.toString` 会整串物化，峰值内存随条目数线性放大 | `f_data/src/base/MapData.cj:44-54` | 峰值 heapUsed / 单次分配量 | 100 万条目 map 调 `toString`，前后 `getAllocatedHeapSize()` + RSS |
| 5 | `ObjectFields` 的嵌套 `computeIfAbsent` 在同 bin 下是否真的不自锁 | `f_data/src/base/ObjectFields.cj:66-70` | std `entryView` 的锁实现细节；并发首访压测结果 | 多线程并发首访 200 个"子类+父类"类型组合（含 hash 冲突构造），观察 hang；或读 `ConcurrentHashMap` 源码 bin 锁粒度 |
| 6 | `DataString` 严格模式的转换失败在实际业务里有调用面 | `f_data/src/base/NumberData.cj:30-47` | 外部调用方传入的 flag 分布 | 在 `tryFromData` 入口埋点统计 `flag` 取值分布，跑一周生产/压测 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `fromJson` 的递归在真实栈大小下能撑多少层（定 maxDepth 的依据） | `f_data/src/json/JsonValue.cj:165-212` | 崩溃临界深度、默认线程栈大小 | 写 1k/2k/5k/10k 层 `[` 的输入跑 `JsonValue.fromStr`，记录崩溃点；同时查 SDK 文档的线程栈默认值 |
| 2 | `toRuneArray()` 在 JSON→PO 校验里占可观分配 | `f_data/src/json/JsonSchemaValidator.cj:243,434` | 分配量、自耗时占比 | `cjprof heap` + `getAllocatedHeapSize()` 跑 1e4 次含 1 KB 字符串字段的校验 |
| 3 | `CmpFilter` 的每行 `Decimal.parse` 是数据路径过滤的热点 | `f_data/src/path/CmpFilter.cj:49` | 单次 parse 耗时 × 行数、占比 | `cjpm bench -O2` 对 1e6 行跑 `@.price < 10`，改前/改后中位数；`cjprof` 看 `Decimal.parse` |
| 4 | `hasDuplicates` 在 1000 项上限内的最坏耗时（决定阈值是否合理） | `f_data/src/json/JsonSchemaValidator.cj:731-741` | 最坏输入的实际耗时 | 构造 999 个相同嵌套数组，计时 `uniqueItems` 校验 P99 |
| 5 | 宏生成的 `__hAsh__` 惰性缓存在真实负载里省下的哈希计算量 vs 失效代价 | `f_data/src/macros/DataAssist.cj:344-356` | `hashCode` 调用次数、缓存命中率 | 在生成代码上加计数埋点，跑一次典型业务压测 |
| 6 | `JsonValue.toData()` 产物嵌套后在 `toJsonString` 里被丢弃的频次（评估 #5 的实际影响面） | `f_data/src/json/DataJson.cj:110-113` | 生产里 `DataJsonObject`/`DataJsonArray` 作为字段值的比例 | 在 `case _ => continue` 处加计数埋点（不改行为），跑一周 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `dictEq` 用双层循环按键查找，复杂度 `O(n·m)` | `f_data/src/path/EqPathFilter.cj:76-90` | 两侧键数 n/m 与单次 `check` 耗时占比 | `cjpm bench -O2`，两侧各 1e3/1e4 键的 `DataDict` 比较 |
| 2 | `DataPath.get` 的闭包链重建在短路径高频调用下不可忽略 | `f_data/src/path/DataPath.cj:1002-1008` | 单次 `get` 的自耗时与分配量 | 1e6 次 `$.a.b.get(d)`，`cjprof record` 看 `flatMap` 相关帧 |
| 3 | `Deferred*` 正则重复编译是过滤器的主要自耗时 | `DeferredMatchFilter.cj:47`、`DeferredSearchFilter.cj:47` | pattern 基数、单次编译耗时、占比 | 1e6 行、distinct pattern 10/1e5 两组 `cjprof` |
| 4 | 非字符串节点的 `toString()` 在对象数组上放大分配 | `FnMatchFilter.cj:40/50/60/69` | 单次序列化字节数 × 行数 | 1e4 条嵌套对象，`cjprof heap` 看分配与 RSS |
| 5 | `LengthCmpFilter` 逐 rune 循环在长文本上比 `size` 贵一个量级 | `f_data/src/path/LengthCmpFilter.cj:38-41` | 1KB/1MB 字符串的单次 `computeLen` 耗时 | 微基准 1e5 次，对照 `size` 版本 |

<!-- 第 6 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 切片 `$[*]` 是 `Θ(n²)`：每个索引一次 `skip(idx)` | `f_data/src/path/RangePathNode.cj:51-53` + `IndexPathNode.cj:31` | `skip` 是否被 `ArrayList` 迭代器特化；单次 `get` 自耗时占比 | n=1e3/1e4/1e5 的 `DataList` 跑 `$[*]`，`cjc -O2` 计时对照 `$[0]` |
| 2 | `SizeFilter` 反射兜底（若被下游类型命中）是单次 `check` 的主要成本 | `f_data/src/path/SizeFilter.cj:40-50` | `TypeInfo.of` + `instanceFunction` 的单次耗时与调用次数 | 对 1e4 条数据跑 `$[?(@.x size 3)]`，`cjprof record` 看反射帧占比 |
| 3 | `SolidDataPath` 把 lex/parse 放在 `entryView` 内，持锁时间与路径长度同阶 | `f_data/src/path/SolidDataPath.cj:26-30` | 单次 `doCompile` 耗时、并发首编译时的 `BLOCKED` 线程数 | 200 条不同 solid 路径 × 8 线程首次编译，线程状态采样 + 分段计时 |
| 4 | `ObjectEqFilter.check` 的物化分配在宽选择器下占比明显 | `f_data/src/path/ObjectEqFilter.cj:137-140` | 单次 `check` 分配字节数与 GC 次数 | 10 万节点文档 + `@.*` 左侧，`cjprof heap` |
| 5 | `match()` 若按 #2 改成全串校验，`find` + 区间比较的成本高于 `matches` | `f_data/src/path/MatchFilter.cj:41` | 两种实现的单次耗时与命中分布 | 1e6 行字符串（长短各一组）`cjpm bench -O2` 对照 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `StructEqFilter.check` 的全量物化在宽选择器下是 filter 段的主要分配源 | `f_data/src/path/StructEqFilter.cj:76-79` | 单次 `check` 的分配字节数、GC 次数占比 | 10 万节点文档 + `@.* == [1,2,3]`，`cjprof heap` 对该帧采样 |
| 2 | `SubSetOfFilter` 的二次路径求值占 `subsetof` 判定耗时的比例接近 50% | `f_data/src/path/SubSetOfFilter.cj:26-36` | 路径段与遍历段的耗时拆分 | `$[?(@..tags subsetof ['a'])]` 分段计时（进入 `check` 前/后打点），1e5 条 |
| 3 | `Subset` 的 `toString()` 哈希在大集合右值（k ≥ 100）时占判定耗时显著 | `f_data/src/path/Subset.cj:34-44` | 字符串生成与哈希的 self time | `subsetof [100 个字符串]` 跑 1e6 次判定，`cjprof record` 看 `Decimal.toString`/`String.hashCode` 帧占比 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 校验器里的正则获取（`String.regex(solid:true)` 的 key 构造 + 并发查表）在表单校验场景里占 `validate` 自耗时的可观比例 | `f_data/src/validation/Validator.cj:92,108,124,151,256,271` → `f_regex/src/RegexFromString.cj:32-64` | `RegexFromString.regex` 的 self time 占比、单次耗时 | `cjprof record` 跑「10 万次 `validate`（混合 6 种校验器）」，对照「正则提为常量」版本 |
| 2 | `escapeRegexLiteral` 的 rune 遍历 + `c.toString()` 对 `IsIntegers` / `IsChineseCellPhone` 是可观测热点 | `f_data/src/validation/Validator.cj:27-37,148,256` | 该函数自耗时占比 | 同上，按函数级 self time 过滤 |
| 3 | `SOLID` 无缓存上限（`f_regex/src/RegexFromString.cj:29`）在本模块 `solid: true` 调用下是否会随「动态构造的 pattern」增长 | 本文件全部 `.regex(solid: true)` 调用点 | 进程内不同 pattern 数量上界 | 若 validator 只由注解常量构造则上界=注解数量，可先做一次「运行 24h 后 `SOLID` size」埋点确认 |

## 文件覆盖

> 与 `files/f_data.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/README.md` | .md | ✅ | — |
| 2 | `f_data/README_en.md` | .md | ✅ | — |
| 3 | `f_data/doc/REVIEW_2026-10-15.md` | .md | ✅ | — |
| 4 | `f_data/doc/RFC9535_COVERAGE.md` | .md | ✅ | — |
| 5 | `f_data/doc/RFC9535_GAPS.md` | .md | ✅ | — |
| 6 | `f_data/doc/spec/add-f-jsonrpc/specs/json-schema-validation/spec.md` | .md | ✅ | — |
| 7 | `f_data/doc/spec/fix-dataassist-local-mode/design.md` | .md | ✅ | — |
| 8 | `f_data/doc/spec/fix-dataassist-local-mode/proposal.md` | .md | ✅ | — |
| 9 | `f_data/doc/spec/fix-dataassist-local-mode/specs/data-assist-compare/spec.md` | .md | ✅ | — |
| 10 | `f_data/doc/spec/fix-dataassist-local-mode/specs/data-assist-supertypes/spec.md` | .md | ✅ | — |
| 11 | `f_data/doc/spec/fix-dataassist-local-mode/tasks.md` | .md | ✅ | — |
| 12 | `f_data/doc/spec/optimize-f-data-json-escape/design.md` | .md | ✅ | — |
| 13 | `f_data/doc/spec/optimize-f-data-json-escape/proposal.md` | .md | ✅ | — |
| 14 | `f_data/doc/spec/optimize-f-data-json-escape/specs/data-json-serialization/spec.md` | .md | ✅ | — |
| 15 | `f_data/doc/spec/optimize-f-data-json-escape/tasks.md` | .md | ✅ | — |
| 16 | `f_data/src/Data.cj` | .cj | ✅ | — |
| 17 | `f_data/src/base/BreakingCommand.cj` | .cj | ✅ | — |
| 18 | `f_data/src/base/CollectionData.cj` | .cj | ✅ | — |
| 19 | `f_data/src/base/ConcurrentMapData.cj` | .cj | ✅ | — |
| 20 | `f_data/src/base/Data.cj` | .cj | ✅ | — |
| 21 | `f_data/src/base/DataAny.cj` | .cj | ✅ | — |
| 22 | `f_data/src/base/DataBool.cj` | .cj | ✅ | — |
| 23 | `f_data/src/base/DataConverter.cj` | .cj | ✅ | — |
| 24 | `f_data/src/base/DataDateTime.cj` | .cj | ✅ | — |
| 25 | `f_data/src/base/DataDict.cj` | .cj | ✅ | — |
| 26 | `f_data/src/base/DataDuration.cj` | .cj | ✅ | — |
| 27 | `f_data/src/base/DataFields.cj` | .cj | ✅ | — |
| 28 | `f_data/src/base/DataInputStream.cj` | .cj | ✅ | — |
| 29 | `f_data/src/base/DataList.cj` | .cj | ✅ | — |
| 30 | `f_data/src/base/DataNone.cj` | .cj | ✅ | — |
| 31 | `f_data/src/base/DataObject.cj` | .cj | ✅ | — |
| 32 | `f_data/src/base/DataParsable.cj` | .cj | ✅ | — |
| 33 | `f_data/src/base/DataParsable_test.cj` | .cj | ✅ | — |
| 34 | `f_data/src/base/DataReal.cj` | .cj | ✅ | — |
| 35 | `f_data/src/base/DataString.cj` | .cj | ✅ | — |
| 36 | `f_data/src/base/DataToString.cj` | .cj | ✅ | — |
| 37 | `f_data/src/base/DataTuples.cj` | .cj | ✅ | — |
| 38 | `f_data/src/base/DataTypeRegistry.cj` | .cj | ✅ | — |
| 39 | `f_data/src/base/DataUnit.cj` | .cj | ✅ | — |
| 40 | `f_data/src/base/DummyDataFields.cj` | .cj | ✅ | — |
| 41 | `f_data/src/base/FieldAlias.cj` | .cj | ✅ | — |
| 42 | `f_data/src/base/MapData.cj` | .cj | ✅ | — |
| 43 | `f_data/src/base/MutableField.cj` | .cj | ✅ | — |
| 44 | `f_data/src/base/NamedData.cj` | .cj | ✅ | — |
| 45 | `f_data/src/base/NumberData.cj` | .cj | ✅ | — |
| 46 | `f_data/src/base/NumberData_test.cj` | .cj | ✅ | — |
| 47 | `f_data/src/base/ObjectFields.cj` | .cj | ✅ | — |
| 48 | `f_data/src/base/OptionData.cj` | .cj | ✅ | — |
| 49 | `f_data/src/base/ReadableField.cj` | .cj | ✅ | — |
| 50 | `f_data/src/base/ReadonlyField.cj` | .cj | ✅ | — |
| 51 | `f_data/src/base/Validator.cj` | .cj | ✅ | — |
| 52 | `f_data/src/base/data_cmp.cj` | .cj | ✅ | — |
| 53 | `f_data/src/base/global_objects.cj` | .cj | ✅ | — |
| 54 | `f_data/src/base/imported.cj` | .cj | ✅ | — |
| 55 | `f_data/src/exception/DataException.cj` | .cj | ✅ | — |
| 56 | `f_data/src/exception/DataParsableException.cj` | .cj | ✅ | — |
| 57 | `f_data/src/exception/JsonException.cj` | .cj | ✅ | — |
| 58 | `f_data/src/exception/ValidationException.cj` | .cj | ✅ | — |
| 59 | `f_data/src/json/CompiledSchema.cj` | .cj | ✅ | — |
| 60 | `f_data/src/json/CompiledSchema_test.cj` | .cj | ✅ | — |
| 61 | `f_data/src/json/DataJson.cj` | .cj | ✅ | — |
| 62 | `f_data/src/json/DataJson_test.cj` | .cj | ✅ | — |
| 63 | `f_data/src/json/ExtendJson.cj` | .cj | ✅ | — |
| 64 | `f_data/src/json/JsonConverter.cj` | .cj | ✅ | — |
| 65 | `f_data/src/json/JsonEscapeFastPath_test.cj` | .cj | ✅ | — |
| 66 | `f_data/src/json/JsonSchema.cj` | .cj | ✅ | — |
| 67 | `f_data/src/json/JsonSchemaValidator.cj` | .cj | ✅ | — |
| 68 | `f_data/src/json/JsonSchemaValidator_test.cj` | .cj | ✅ | — |
| 69 | `f_data/src/json/JsonValue.cj` | .cj | ✅ | — |
| 70 | `f_data/src/json/imported.cj` | .cj | ✅ | — |
| 71 | `f_data/src/macros/DataAssist.cj` | .cj | ✅ | — |
| 72 | `f_data/src/macros/DataExclude.cj` | .cj | ✅ | — |
| 73 | `f_data/src/path/AndFilter.cj` | .cj | ✅ | — |
| 74 | `f_data/src/path/AnyOfFilter.cj` | .cj | ✅ | — |
| 75 | `f_data/src/path/AnySubPathNode.cj` | .cj | ✅ | — |
| 76 | `f_data/src/path/AvgPathNode.cj` | .cj | ✅ | — |
| 77 | `f_data/src/path/CacheDataPath.cj` | .cj | ✅ | — |
| 78 | `f_data/src/path/CmpFilter.cj` | .cj | ✅ | — |
| 79 | `f_data/src/path/CountCmpFilter.cj` | .cj | ✅ | — |
| 80 | `f_data/src/path/CountFilterResult.cj` | .cj | ✅ | — |
| 81 | `f_data/src/path/CountPathNode.cj` | .cj | ✅ | — |
| 82 | `f_data/src/path/CurrentPathNode.cj` | .cj | ✅ | — |
| 83 | `f_data/src/path/DataFilter.cj` | .cj | ✅ | — |
| 84 | `f_data/src/path/DataFilterPathNode.cj` | .cj | ✅ | — |
| 85 | `f_data/src/path/DataPath.cj` | .cj | ✅ | — |
| 86 | `f_data/src/path/DataPathNode.cj` | .cj | ✅ | — |
| 87 | `f_data/src/path/DeferredMatchFilter.cj` | .cj | ✅ | — |
| 88 | `f_data/src/path/DeferredSearchFilter.cj` | .cj | ✅ | — |
| 89 | `f_data/src/path/EqFilter.cj` | .cj | ✅ | — |
| 90 | `f_data/src/path/EqPathFilter.cj` | .cj | ✅ | — |
| 91 | `f_data/src/path/ExistsFilter.cj` | .cj | ✅ | — |
| 92 | `f_data/src/path/FilterUtils.cj` | .cj | ✅ | — |
| 93 | `f_data/src/path/FnDeferredMatchFilter.cj` | .cj | ✅ | — |
| 94 | `f_data/src/path/FnDeferredSearchFilter.cj` | .cj | ✅ | — |
| 95 | `f_data/src/path/FnMatchFilter.cj` | .cj | ✅ | — |
| 96 | `f_data/src/path/FnSearchFilter.cj` | .cj | ✅ | — |
| 97 | `f_data/src/path/InFilter.cj` | .cj | ✅ | — |
| 98 | `f_data/src/path/IndexPathNode.cj` | .cj | ✅ | — |
| 99 | `f_data/src/path/LengthCmpFilter.cj` | .cj | ✅ | — |
| 100 | `f_data/src/path/LengthPathNode.cj` | .cj | ✅ | — |
| 101 | `f_data/src/path/MatchFilter.cj` | .cj | ✅ | — |
| 102 | `f_data/src/path/MaxPathNode.cj` | .cj | ✅ | — |
| 103 | `f_data/src/path/MinPathNode.cj` | .cj | ✅ | — |
| 104 | `f_data/src/path/MultiIndexPathNode.cj` | .cj | ✅ | — |
| 105 | `f_data/src/path/MultiSubPathNode.cj` | .cj | ✅ | — |
| 106 | `f_data/src/path/NinFilter.cj` | .cj | ✅ | — |
| 107 | `f_data/src/path/NoOneOfFilter.cj` | .cj | ✅ | — |
| 108 | `f_data/src/path/NotEqFilter.cj` | .cj | ✅ | — |
| 109 | `f_data/src/path/NotFilter.cj` | .cj | ✅ | — |
| 110 | `f_data/src/path/NullFilter.cj` | .cj | ✅ | — |
| 111 | `f_data/src/path/ObjectEqFilter.cj` | .cj | ✅ | — |
| 112 | `f_data/src/path/OrFilter.cj` | .cj | ✅ | — |
| 113 | `f_data/src/path/RangePathNode.cj` | .cj | ✅ | — |
| 114 | `f_data/src/path/RecursiveDescentIterator.cj` | .cj | ✅ | — |
| 115 | `f_data/src/path/RecursiveDescentPathNode.cj` | .cj | ✅ | — |
| 116 | `f_data/src/path/RegexFilter.cj` | .cj | ✅ | — |
| 117 | `f_data/src/path/RootPathNode.cj` | .cj | ✅ | — |
| 118 | `f_data/src/path/SearchFilter.cj` | .cj | ✅ | — |
| 119 | `f_data/src/path/SizeFilter.cj` | .cj | ✅ | — |
| 120 | `f_data/src/path/SolidDataPath.cj` | .cj | ✅ | — |
| 121 | `f_data/src/path/StructEqFilter.cj` | .cj | ✅ | — |
| 122 | `f_data/src/path/SubPathNode.cj` | .cj | ✅ | — |
| 123 | `f_data/src/path/SubSetOfFilter.cj` | .cj | ✅ | — |
| 124 | `f_data/src/path/Subset.cj` | .cj | ✅ | — |
| 125 | `f_data/src/path/TestObj.cj` | .cj | ✅ | — |
| 126 | `f_data/src/path/ValueCmpFilter.cj` | .cj | ✅ | — |
| 127 | `f_data/src/path/ValueFilterResult.cj` | .cj | ✅ | — |
| 128 | `f_data/src/path/ValuePathNode.cj` | .cj | ✅ | — |
| 129 | `f_data/src/path/basic_test.cj` | .cj | ✅ | — |
| 130 | `f_data/src/path/compile_error_test.cj` | .cj | ✅ | — |
| 131 | `f_data/src/path/complex_fn_test.cj` | .cj | ✅ | — |
| 132 | `f_data/src/path/filter_test.cj` | .cj | ✅ | — |
| 133 | `f_data/src/path/integration_test.cj` | .cj | ✅ | — |
| 134 | `f_data/src/path/object_eq_test.cj` | .cj | ✅ | — |
| 135 | `f_data/src/path/p1_gaps_test.cj` | .cj | ✅ | — |
| 136 | `f_data/src/path/recursive_test.cj` | .cj | ✅ | — |
| 137 | `f_data/src/path/rfc9535_slice_test.cj` | .cj | ✅ | — |
| 138 | `f_data/src/test/DataAssist_test.cj` | .cj | ✅ | — |
| 139 | `f_data/src/test/JsonSchema_test.cj` | .cj | ✅ | — |
| 140 | `f_data/src/test/data_test.cj` | .cj | ✅ | — |
| 141 | `f_data/src/validation/Validator.cj` | .cj | ✅ | — |
| 142 | `f_data/src/validation/Validator_test.cj` | .cj | ✅ | — |

合计：`.cj` 127 个 / `.md` 15 个 / 共 142 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 4（严重 #1、一般 #1/#2/#3）；设计 2（一般 #6 的协议复制、轻微 #6 的双协议）；语言特性 1（一般 #3 的 `tryParse` 命名契约 + `as`/`?T` 与 `Decimal` 文法交互；`as` 返回 `Option` 的语义已按官方文档 `class_and_interface/typecast.md:54` 核对）；可读性 1（轻微 #1 文案）+ 一般 #4 的递归可维护性；安全性 0（本部分不拼 SQL/命令、不写日志凭据；`DataInputStream` 虽包装 socket，但只做类型转换，不产生 I/O） |
| §1 死代码 | 1 | 机械过了一遍：`convertForMap`（DataAny.cj:55，同文件 2 处调用）、`FieldIterator`（DataObject.cj:34，:100 调用）、`doTryParse`（DataParsable.cj:52，:36/:42 调用）、`register`（DataTypeRegistry.cj:65，:55 调用）、`int8Range`…`uintNativeRange` 10 个私有静态（各自 `tryTo*` 使用）均有引用；`protected doConvert` 属「`public abstract` 非 sealed 类」豁免；`public` 顶层类型/成员（含 `DataAnyMap/DataAnyList`、`toBool/toUnit/toDecimal` 等仓内零引用者）按硬原则一不判；未使用 import 0（`DataBool/DataObject` 的 `std.convert.Parsable` 用于扩展方法解析，`DummyDataFields` 两个 stdx import 分别用到 `Http*` 与 `Form`）。命中 1：`DataString` 私有 `init()`（轻微 #2）。不可达语句 0；恒假分支另计在一般 #1（那四条按 flag 组合恒不可达，是逻辑缺陷不是纯死代码） |
| §2 重复逻辑 | 3 | 同文件两两比对了 20 个文件的全部函数体摘要；跨文件比对了 `DataDict↔DataTuples↔DataList` 的 `toString`（哨兵与括号差异已在轻微 #3 记录）、`DataBool/DataDuration/DataDateTime/DataUnit` 的 `tryFromData`（类型分支确属不同语义，不判重复）。命中：一般 #5（类型特化样板 3 族）、一般 #6（解包协议 7 份）、轻微 #6（`DataParsable` vs std `Parsable`） |
| §3 空实现 | 2 | 轻微 #4（`DummyDataFields` 默认实现直抛）、轻微 #1（4 处 `parse` 抛无消息异常）。其余：`DataNone/DataDict/DataList/DataTuples/DataInputStream.tryParse` 恒 `None` 是有意设计（有注释、`parse` 抛异常配套），不判；`Data.fromData/tryFromData` 的恒等默认实现是根接口语义；无 `TODO/FIXME`、无 `catch {}` |
| §4 栈溢出 | 1 | 一般 #4（`toString` 递归，深度由数据决定）。其余无递归：`DataAny` 是 `struct` + `let`，构不出自引用环；`populate/tryFromData` 的递归只经 `DataAny` 与集合元素，深度由编译期类型嵌套决定 |
| §5 OOM | 0 | 未命中「按不可信长度预分配」：`DataReal` 的区间数组是编译期常量；`StringGenerator` 无预分配参数；`DataToString` 的单串缓冲与数据规模同阶（1:1 渲染，非平方级）。唯一非线性面是递归深度（已归 §4）。`DataTypeRegistry` 的类型表只增不减，但条目数由编译期类型数决定、无外部输入放大，且 `mem §6.2` 的"注册表不注销"在此不成立（进程级类型注册本就常驻） |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`docs/LocalMode*.md` 与 `doc/spec/optimize-f-data-json-escape/design.md` 的取数都不覆盖标量解析、反射访问、登记表）。四个候选全部进「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`DataTypeRegistry` 全走 `ConcurrentHashMap`；`DataDateTime` 的 CAS 循环临界区只有一次比较交换，不含 I/O / 解析 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/批处理，无"提交后立刻 get"形态 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`、无循环内字符串 `+`（`toString` 都走 `StringGenerator`）；`DataReal.tryParse` 的"每次重建正则"是固定开销放大而非复杂度问题，见待验证假设 #1 |
| §7 降堆内存方案 | 0 | 无基线：`DataToString` 的整串复制与 `DataTypeRegistry.snapshot()` 的 `Array` 复制都未测量；按规则只进待验证假设 #3/#4 |
| §8 降 CPU 方案 | 0 | 无基线（同上）；`DataReal` 区间数组与反射缓存都不具备可量化收益证据 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：本部分的产物（`DataAny/DataReal/DataObject`）全部作为返回值或字段逃逸，`populate`/`tryFromData` 的输出就是调用方要的对象；`cjpm.toml` 已带 `--experimental --enable-local-mode`，但"函数内创建、函数内用完"的大对象在这里不存在（单个 `Decimal`/`String` 包装），收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 12 | 严重 #1、一般 #1~#4 与 #6、轻微 #1~#7 中除归属 §2/§3/§12/§13 的条目外全部为存量 BUG。逐条核对过的边界：空集合/空串/单元素、`DataNone↔?T`、`DataAny` 解包、`DEEP` 分支、`DataDict`（`String` 键）与 `DataTuples`（`Data` 键）的 `Iterable` 分支不可重叠、`Duration` 的首位符号/单位递减/Int64 与 Duration 双边界（与 13 个用例对齐）、`DataUnit` 单例相等性——除上述条目外行为正确 |
| §12 并发安全与锁粒度 | 1 | `DataTypeRegistry.creators` 与 `size` 版本号的并发读写已推演：读序（先 size 后 snapshot）只会导致一次多余的全表拉取，`addIfAbsent` 保证幂等，无漏项、无检查-然后-写入缺陷；`DataDateTime.defaultDateFormat` 的 CAS 循环无死循环（另一线程置非空后本线程必然抛）。命中 1：`ThreadLocal` 无线程池清除入口（轻微 #5，按其 §12.1「ThreadLocal 残留」计）。`DataDict/DataList/DataTuples/DataObject` 是可变异步包装，但仓内均为请求内新建、无共享单例，未发现共享路径，不判 |
| §14 功能完备性与 README 覆盖 | 1 | 以本部分 public 声明对照 `README.md`：`ToData`、`FromToData`、`ToDataFields`、`DataAnyMap`、`DataAnyList`、`DataToString` 六个符号全文命中 0（`README.md:823` 自称"以下声明未在上文展开…列出"）。属公开契约缺文档，与第 1 部分的"漏 5 个类型"同源、符号集不同，合并时按一条处理。功能完备性：本部分无"承诺未实现"（`parse` 抛异常的四个类型均有 `tryParse` 返 `None` 配套与注释） |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_data.part2.txt` 一一对应，无缺失；本部分无 `.md`，§13 不适用（README 交叉核对见上一条，正文位置 `README.md:791-793/823-826`） |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#1 #2 #3 #7；设计：#8（可见性契约）、#4（快照语义）；语言特性：#13（`Any` 返回 + Option 嵌套）；可读性：#10 #11；安全性：本部分无外部输入直接拼 SQL / 无凭据，唯一外部输入面是 schema `pattern`（预编译 + 捕获异常，未发现 ReDoS 逃逸，`json` 校验器本体不在本部分） |
| §1 死代码 | 1 | `ObjectFields.cj:35-38` 反引号分支恒假（#10）。其余逐个核对：`private`（`tryFromDataToMap`、`AnnotationTag`、`invalid`、`checkDoc`、`checkObject`）均有调用者；`internal`（`ignoreNotConvertable`、`DataConversionFlag`）在本包被 `NumberData.cj`/`MutableField.cj` 使用；`protected`（`newGetter`×2）被 `ReadonlyField`/`MutableField` 使用；`public` 且对外可达（`DataMap`/`MapData`/`Validator`/`CompiledSchema`/`FieldAlias`/四个异常类）不判，`imported.cj` 的 `public import` 属对外表面（`MonoTime`、`UnixSocket`、`base64` 等仓内无使用，但重导出即对外契约，不判死代码，仅记录） |
| §2 重复逻辑 | 3 | #1（`MutableField` 两重载 60 行同构且已漂移）、#9（`NumberData` 13 份同构 + 40 处同一正则字面量）、#10（反引号剥离写两遍）；另核：`NamedData.cj` 两个 extend 仅容器类型不同（`ConcurrentMap`/`Map`），无法合并；4 个异常类必须独立类型（`catch` 语义），不计；`OptionData`/`DataMap` 无同语义重复 |
| §3 空实现 | 0 | 容器类的 `tryParse` 一律 `None`（`DataMap.cj:55-57`）与 `DataDict`/`DataList`/`DataTuples`/`DataInputStream` 同约定，属"容器不可从字符串解析"，不算空实现；`DummyValidator` 是显式 Null Object（`ReadableField.cj:74-78` 有用例消费）；未发现 `TODO`/`FIXME`/`catch {}` 空吞（`CompiledSchema.cj:90` 的 `catch` 会转成 `IllegalArgumentException`，但会吞掉真实原因，已并入 #4/#7 描述） |
| §4 栈溢出 | 1 | #6（`checkDoc` 无深度上限）；另核 `ObjectFields.cj:35-38` 的自递归（每次削 2 字节，深度受名字长度限制，且已判死分支）、`f_data_eq`/`f_data_cmp` 无自递归 |
| §5 OOM | 0 | 本部分无按不可信长度预分配、无 per-request 增长容器；`allFields`/`annotations`/`patterns` 三个静态缓存的上界都是"类型数 / 字段数 / schema 节点数"，属有界；`DataMap.toString` 的全量拼串未定量，列入待验证假设 #4 |
| §6.1 热点瓶颈 | 0 | `scope.md` 只给了 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`（local mode 方案，非本模块 profile），无 `cjprof`/`cjpm bench` 数据，热点结论不成立，全部转入待验证假设 #1–#4 |
| §6.2 大粒度锁 | 0 | 本部分只有两处并发容器使用（`allFields`、`annotations`），没有 `synchronized` 临界区、锁内 I/O / 解析 / 日志；`computeIfAbsent` 的"锁内回调"已按 §12.1 记入 #5 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 1 | #9 描述中的"同一字符串重复 4 次正则匹配 + 裁剪"（方案见 [CPU] #2）；无嵌套循环、无 `remove(at: 0)` 队列、无循环内字符串 `+` |
| §7 降堆内存方案 | 1 | [堆内存] #1（`ObjectFields` 双表 + 注解缓存三份键） |
| §8 降 CPU 方案 | 3 | [CPU] #2（字符串转换归一化）、#3（`path` 延迟拼接）、#4（`AnnotationTag` 构造） |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象都是单个小对象（`DataReal` 包装、`trimAscii` 结果、`AnnotationTag`），无"函数内创建、函数内用完的大中间结构"，没有可量化的峰值内存收益；`data_cmp.cj:77-88` 的 `local` 重载是给宏生成代码用的最小桥接，`demode` 后即普通值，不存在进一步 local 化空间 |
| §11 现有代码的 BUG（存量） | 7 | #1 #2 #3 #7 #10 #12 #14（+ #13 契约类）；本轮读到的其余函数（`Validator.validate`、`data_cmp` 三个入口、`NamedData` 两个 extend、`OptionData.toData`、`DataMap.toString/size/isEmpty`）边界与空值均已逐条核过（空集、`None`、±0、单字符名），未再发现确定性缺陷 |
| §12 并发安全与锁粒度 | 2 | #4（请求线程写共享 `HashMap`，前置条件待确认）、#5（`computeIfAbsent` 回调内重入 `entryView`）；线程封闭说明：`CompiledSchema` 的 `patterns` 在无 schema 变更时是只读共享（`std` 容器不可并发写，读安全），`ObjectFields` 的 `readables`/`mutables` 在 `computeIfAbsent` 内填充完毕后只读 |
| §14 功能完备性与 README 覆盖 | 2 | #7（结构校验半成品）、#8（扩展点未真正对外开放）；README 已覆盖 `CompiledSchema`/`patternCount`/`schema`、`ObjectFields` 全部方法、flag 语义，本部分新增 public 声明（`MapRawType`、`DataMapIterator`、`AnnotationTag` 除外）均能在 README 找到对应条目 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 不在本部分清单内，README 仅作判据引用（#8、#11） |

### 第 4 部分

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

### 第 5 部分

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

### 第 6 部分

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

### 第 7 部分

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

### 第 8 部分

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
| 严重 | 10 |
| 一般 | 50 |
| 轻微 | 51 |
| 其中存量 | 111 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：**这一部分是 `f_data` 的类型地基：`Data` 根接口、集合/并发映射的 `Data` 包装、以及 `BreakingCommand`。**骨架是对的：`DEEP` 快路径只在「同类型且不要求深拷贝」时返回底层容器，其余一律走逐元素转换；`DataCollection`/`DataConcurrentMap` 的 `tryParse` 按项目约定返回 `None`、`parse` 才抛（`DataDict` 的注释把这条约定写清了）；`DataConcurrentMap` 没有引入任何自己的锁，把线程安全完全交给 `ConcurrentHashMap`；`BreakingCommand` 无状态、构造链与 f_mvc/f_rpc 的 `handle` 分支一致。本部分没有严重问题，也没有可证明的 OOM/栈溢出/并发缺陷。

**风险集中在「转换失败」这一条路径上，共 3 条。**
1. **元素级静默丢弃**（一般 #2）是最值得先处理的一条：默认 `DEFAULT_DATA_FLAG = SILENCE` 下，`Array<Int64>` 字段会因一个坏元素而**静默变短**，既不报错也不返回 `None`，下游按下标取值直接错位。它和「字段级整字段跳过」的既有语义不对称，属于会写进数据库的错误数据。
2. **`DataIterable` 的占位实现**（一般 #3）：`toString` 违背 `Data <: ToString`，且 f_data 自己的错误消息会因插值 `${data}` 二次抛异常，把原始诊断吞掉。`f_http` 的重名表单字段会生产这种值，不是理论路径。
3. **`extractPureString` 的单引号越界**（一般 #1）：一行判空就能修，但现状是 `tryFromData` 会抛 `IndexOutOfBoundsException`，破坏 `SILENCE` 的「不可转换 ⇒ `None`」承诺。

**维护性**：`ConcurrentMapData` 基本是 `MapData` 的复制，`CollectionData` 里 6 份 `tryFromData` 逐行同构，而 `MapData.cj:78-120` 已经证明「`creator` + 插入动作」的参数化在本模块可行。这组复制不是「看起来丑」——一般 #2 与轻微 #1 都出在复制体上，属于该收敛的信号。

**文档**是本部分第二大类问题，且都不是措辞层面的：README 主示例缺宏 import（照抄编译不过）、英文版的 `@` 语义与实现相反、自称列全的公开 API 漏了 5 个类型、`props` 展开示例的 setter 语法非法且与正文矛盾、`RFC9535_COVERAGE.md` 的文件清单指向不存在的文件。README 是这套库唯一的对外契约，建议与代码修复同批处理。

**没有测量数据支撑的性能结论一条都没写**：字节集合的逐元素 `Decimal` 装箱、`unsafeData` 切片的二次拷贝、`StringGenerator` 扩容、并发 map 迭代开销四个候选全部放在「待验证假设」里，等下一轮补 `cjprof`/分配量基线。本部分 12 条发现全部为存量，是否纳入修复待用户决定；本轮只读代码，未改源码、未跑构建。

**第 2 部分**：**本部分是 `f_data` 的标量层与反射对象层：`DataXxx` 包装、`DataFields/DataConverter/DataParsable` 三件套、`DataObject` 与 `DataTypeRegistry`。** 代码的整体骨架是清楚的：`DataAny` 统一解包、`DataNone` 单例、`Duration` 解析器把"符号只允许首位/单位严格递减/溢出收敛为 None"写全了并有 13 个用例兜底，`DataTypeRegistry` 用并发容器 + 只增版本号避免了每次未命中全表遍历，`DataObject` 的字段访问全部收敛到 `ObjectFields`，`DummyDataFields` 之外没有"看起来能编译但什么都没做"的接口。

**唯一的阻塞项在失败语义，共三条，互相独立。**
1. **`populate` 把不可转换源变成默认对象**（严重 #1）：这是本部分最该先修的一条。JSON 里"对象字段收到数组/标量"会得到一个字段全默认的对象，被当成功值写库；它同时违反 README 的 flag 承诺，且触发点就在 `@DataAssist` 的常规字段写入路径上（`MutableField` → `convert` → `f_data_tryFromData`）。
2. **可转换分支排在类型兜底之后**（一般 #1）：`flag: 0` 或只带 `IGNORE_FIELD_NOT_CONVERTABLE` 时，String→Bool/Unit、DateTime↔Duration 这些"正路"直接报"does not match"；默认 flag 把问题盖住了，显式 flag 的调用方必踩。
3. **`SILENCE` 仍会抛异常**（一般 #2 的 `ArithmeticException`、一般 #3 的 `tryParse` 抛 `Decimal.parse` 异常）：flag 文档承诺"不抛"，异常却从 `try` 系列逃出；两处都只有一两行判空/包 try 的量，建议与 #1 同批修。

**维护性**：本部分的复制密度明显偏高——9 份 `DataInputStream.tryFromData`、10 组 `DataReal.tryTo*`、20 个 `DataToString.append`、7 份"解包 `Any`"协议。这些不是"看起来丑"：`DataReal.cj:208-211` 的注释记着一次因复制漂移写错区间数组的历史缺陷，`DataObject.get<V>` 的 flag 错用也长在第 7 份复制体上。收敛顺序建议先做解包协议（7 份 → 1 份，可同时消掉两处 flag/异常类型不一致），再做三族样板。

**风险提示**：`toString` 的递归（一般 #4）是全模块级的——`f_codec`/`f_mvc` 到处插值 `Data`，深层嵌套数据只要进日志就可能崩线程；深度阈值需要实测，但"无上限"这一点是静态确定的。`DummyDataFields`（轻微 #4）目前只是埋雷，等有人把 `HttpRequest` 当字段写进 `@DataAssist` 类就会在序列化时炸。

本部分 14 条发现全部为存量（快照无基线），是否纳入修复待用户决定；性能类结论一条都没有（4 个候选在「待验证假设」里等数据）。本轮只读代码，未改源码、未跑构建。

**第 3 部分**：本部分的骨架是稳的：`Data`/`DataFields` 的转换契约、flag 优先级（`global_objects.cj` 的注释与实现自洽）、`Validator` 组合模型、`data_cmp` 的 fail-open 修复都做得比一般内部库严谨，`CompiledSchema` 也把"注册期编译、请求期查表"这条主线接上了。

风险集中在两处。**第一处是"13 份复制粘贴的数值转换"**：`NumberData` 用同一套模板铺了 13 个类型 × 5 类输入，任何一次改动都要改 13 遍，历史上已经因此出过 IntNative 漏负号的缺陷，现在还留着 BigInt/Decimal 缺分支（#9）和字符串分支被兜底 `throw` 盖住（#2）。这是本模块最值得投一次重构的地方，收益是"以后不用改 13 遍"。**第二处是"承诺与实现的缝隙"**：非空字段的 `@DataConverter` 静默失效（#1，唯一一条严重）、结构校验只做了一半（#7）、`ReadableField` 被文档当成扩展点却不可见不可继承（#8）、README 的 flag 名字根本不存在（#11）——这些都是"文档说可以、代码里没有"，比性能问题更容易在前端联调时浪费时间。

并发面上没有发现既成事实的数据竞争：两个全局缓存的读路径都是只读共享，`ConcurrentHashMap` + `addIfAbsent` 的意图正确。真正需要确认的只有 #4（schema 编译后被改）与 #5（`computeIfAbsent` 回调内重入 `entryView`）两个"灰区用法"，前者建议直接把请求路径改成只读表，后者建议按 `f_base` 的"填完再发布"模式重写，两处改动都小且不改变对外语义。

性能与内存方面本部分没有 profile/bench 数据，所有结论都是"待验证假设"，不进修复清单；其中 `NumberData` 的重复裁剪/匹配（假设 #1）最值得先采数据。

**第 4 部分**：本部分的骨架是清楚的：`JsonValue` 的 7 个子类 + `asX`/`kind` 分派、`ValidationCtx` 的 `maxErrors`/`maxDepth`/`skipped` 三件套、`JsonSchemaValidator.validateDoc` 与 `validateInstanceAt` 的双入口分工、`DataPath` 那一套"编译期生成过滤器"的设计，都比一般内部库严谨；`escapeJsonString` 的双扫描快路径还有专门的一致性用例（`legacyEscape`），这类"改动配对照"的做法值得保持。

**两个阻塞项都在"解析与类型"的交界上。** 一是 `fromJson` 无深度上限（#1）：JSON-RPC / MCP 的请求体直接进这个递归，几千层就崩进程，而 1 MB 的 body 限制对层数毫无约束——这是外部输入直通崩溃，属于必须在下一版修掉的项。二是"解析只产 `JsonDecimal`、校验只认 `JsonInt`"（#2）：两个文件各自都自洽，接起来就是"任何 `integer` schema 永远失败"；它现在还没在业务里大规模触发，纯粹因为工具参数类把数量写成了 `String`，属于运气而非设计。

**中间一档集中在"静默"上。** `toJsonString` 的 `case _ => continue` 会整条抹掉成员（#5）、`parse` 承诺校验却不校验（#6）、`toJsonSchema` 两处回退失败后返回空 properties（#11）、容器 `items` 生成成对象（#8）、宏生成的 `==` 用不失效的缓存哈希做前置否定（#7）——共同点是**没有异常、没有日志，结果却与契约不符**，排查成本远高于直接报错。这几条建议统一按"要么做对、要么显式失败"的口径收一遍，工作量都不大。

**并发与性能不是本部分的主要风险。** 除了宏生成的 `__hAsh__`（#7）这一处惰性写入，其余共享结构要么线程封闭、要么走 `HeapCache`/`ConcurrentHashMap`；`CompiledSchema` 的 pattern 表写入问题归第 3 部分。性能侧只有 `hasDuplicates` 的 O(n²)（#9）与 `CmpFilter` 的重复解析（#10）值得排期，其余全部缺 profile/bench 数据，按纪律只留在「待验证假设」里，等下一轮取数。

**第 5 部分**：本部分（`src/path/` 的节点与过滤器全家桶）整体结构是清楚的：节点与过滤器在编译期构造、运行期只读，`Data` 遍历走惰性迭代器，并发面干净——没有共享可变状态、没有锁、没有全局只增容器，`§12` 可以判安全。

真正的风险集中在两处。**一是语义口径不一致**：`value()` 的 `!=` 被 `emitCmpFilter` 丢掉（#1），`length()` 在路径级按字节、在 filter 级按 rune（#7），`dataEquals` 少了 datetime/duration（#8），`DataFilterPathNode`/`ValueFilterResult` 少了 `Iterable<(Data,Data)>`（#6）——它们都不会报错，只会安静地给出相反或缺失的结果，这是本部分最该先修的类别。**二是异常路径不受控**：数值比较对非数值字面量抛 `IllegalArgumentException`（#4），畸形路径在编译期抛下标越界（#5），`EqPathFilter` 的递归无深度上限可直接打爆栈（#2）；对以 `DataException` 为契约的调用方，前两者会漏接，后者是进程级崩溃，应作为阻塞项。

修复顺序建议：#1 / #2 先做（结论错误与崩溃），#4 / #5 / #6 / #7 / #8 同批（都是小改、可加用例锁住），#3 需要先定语义再动代码。`§1`/`§2` 的六条轻微项都是「删一段或并一处」，适合跟随上述改动顺手清掉——尤其 #6 的抽取，能把 #6 与 #1 的漂移根因一起消掉。性能与内存的四条方案全部无基线，留待下一轮补 `cjprof` / `cjpm bench -O2` 数据后再决定是否立项。

**第 6 部分**：本部分是 `src/path/` 的「字面量/正则/切片/递归下降」一族，代码量小、结构一致，但**语义失真**比性能问题严重得多，三条严重项都属于「不报错、只给错答案」：

- `min()`/`max()` 的比较分支挂在 `Option<Data>` 上永远匹配不到，两个函数退化成「取首元素」（#1）——编译期就有 `unreachable pattern` 告警，只是没人看，测试又只断言条数；
- `match()` 用 `Regex.matches`（存在匹配）实现「全串匹配」，与 `search()` 等价（#2）；
- 对象字面量比较把 token 拼成无引号文本再手写解析，字符串 `"123"` 被还原成数值 `123`、`"a,b"` 被逗号切开（#3）。

这三条都建议作为阻塞项：修复量都不大（#1 换成 `Some(y)` 绑定、#2 换成 `find` + 区间校验、#3 改为按 token 构造 `Data`），但都需要补「值断言」级用例才能锁住——现有 `testFunctionMin/Max`、`testFilterMatch`、`testFilterObjectEq` 全都是「只数条数」或「pattern 恰好等于输入」，正是它们让上述缺陷长期存活。

一般项集中在「边界与递归」：#4 缺失字段的 `!= null` 与自身注释相反；#5/#6 的两条递归/遍历缺少环检测与深度上限，前者靠调用方构环触发，后者靠深嵌套输入触发，都是「不抛 `DataException`、直接挂死或崩栈」的形态；#7 是唯一涉及并发的项——`SolidDataPath` 在 `ConcurrentHashMap` 回调里递归回到同一张表，是否自锁取决于 std 内部锁粒度，需一次单线程验证即可定论，建议优先排除。

轻微项里 §1 占了四条（未使用字段、未使用构造、不可达语句、恒假反射分支），删除风险极低；§2 的三条重复（`parseRegex`、`splitByComma`/`dataEquals`、尺寸计算）已经漂移出行为差异，建议随 #3/#11 的改动一并收敛到 `FilterUtils`。性能与内存的三条方案全部无基线，留待下一轮补 `cjprof` / `cjpm bench -O2` 数据后再决定是否立项，其中切片的 `Θ(k·n)` 最值得先测。

**第 7 部分**：本部分是 `src/path/` 的「结构相等 / 集合关系 / `value()` 取值」一族，加 12 个测试文件。代码量不大，但**「右侧字面量被降级成文本再解析」这一条主线**在三个类里各错了一次，且错误方向一致：把 `cangjieLex` 已经去引号的 token 值当成带引号的字面量，或反过来用 `toString()` 当比较口径。

- 阻塞项是 #1：数组字面量只要含字符串或嵌套数组就抛 `NumberFormatException`，这不是「结果不对」而是「异常类型不对 + 请求级崩溃」，且 `StructEqFilter.parseRaw` 里那段引号剥离逻辑在当前调用链上根本不可达，说明作者对输入形态的判断是错的。修法明确（按 token 构造 `Data`），但必须补字符串/布尔/嵌套/含逗号四组用例，否则还会复发。
- #2 是「契约写了但没实现」：`value(innerFilter)` 的文档示例恒 `false`，且 `RFC9535_COVERAGE.md` 把它的覆盖错记到 `testFilterValueEq` 名下，等于连「没有测试」这件事都被文档掩盖了。建议与 `part5` 的 `FnDeferred*` 同批修，否则两处会各自修出不同语义。
- #3 是口径分裂：`subsetof`/`anyof`/`nooneof` 把右值铸成 `HashSet<String>`，`null` 直接消失、`30.0` 与 `30` 互不相等、`"30"` 又能命中 `[30]`；而 `in`/`nin` 有 `hasNull` + `Decimal` 比较。这一族应该共用一套「右值类型化表示」，`Subset` 是天然的落点。

测试侧的问题集中且廉价：两个完全相同的集成用例、三条只差字面量的负索引用例、八份 `collect()` 拷贝、一个从未被调用的 helper、五处未使用的 import——都不影响行为，删改风险极低，建议顺手清理。`TestObj` 作为测试替身长期住在 `src/path/` 是唯一的组织性问题，移到 `*_test.cj` 即可，不必改可见性。

性能与内存方面本部分没有热点证据：四条方案（`StructEqFilter` 物化、`Subset` 文本比较、`subsetof` 二次求值、`ValueFilterResult` 三分支）都只给出机制与验证方式，全部标 `无基线（待验证）`，等下一轮补齐 `cjprof` / `cjpm bench -O2` 数据再决定是否立项。并发面本部分干净——所有过滤器都是构造期赋值、运行期只读，`check` 只用局部变量，看不到共享可变状态。

**第 8 部分**：本文件是纯函数式校验器集合，没有共享状态、没有递归、没有 I/O，并发安全与 OOM / 栈溢出三个维度都是干净的；主要风险集中在**校验语义的边界**而不是工程质量：

1. `IsIntegerRange(range:)` 对 `hasEnd`/`isClosed` 的误用让左闭右开区间放行上界（`1..10` 收 10），这是本部分唯一「静默放行非法数据」的确定性缺陷，建议优先修并补用例；
2. `maxInclusive` 默认 `false` 搭配 `max = Int64.Max`、`min` 默认 `0`，使默认配置同时砍掉 `Int64.Max` 和全部负数，属于难排查的「默认值陷阱」；
3. `IsChineseCellPhone` 缺 `$` 锚（`matches` 是子串匹配，已查 std 文档确认）与 `StringSize` 用字节长度，是两处会放过脏数据 / 误拒合法数据的契约偏差，前者改动最小收益最直接；
4. `DoesMatchRegex`、`IsDateTime` 把配置错误和值不合法混为一谈，建议在注解解析期就把配置错误暴露出来。

`doc/REVIEW_2026-10-15.md` 已修的 4 项（`StringSize.min`、`IsDuration` 对齐解析器、分隔符转义、国家码括号）在本文件中实现无误，注释与实现一致；但修复没有配套 `IsIntegerRange` / `DoesMatchRegex` 的用例，同类问题仍可能复发。存量 10 条（7 一般 + 3 轻微），是否纳入修复待用户决定；两条优化方案均无基线，只作下一轮补数据的清单。
