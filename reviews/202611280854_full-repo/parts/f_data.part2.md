# f_data 模块审查报告（第 2/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（全模块 127 个 `.cj` + 15 个 `.md`；**本报告为模块第 2/8 部分**，覆盖 `f_data.part2.txt` 的 20 个 `.cj`、0 个 `.md`；其余 `.cj` 属第 1、3~8 部分，未纳入本报告统计）
- **基线**：工作区快照（`sts/1.3.x` 工作区，未对照远端目标分支；快照模式无 diff 可比，所有问题来源一律记「存量」，blame 只作提交依据）
- **审查重点**：JSON/数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 2/8 部分）

## 发现

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

## 优化可行性方案

> 本部分**未提出带基线的优化方案**。`docs/LocalMode.md` / `docs/LocalMode-O2-Plan.md` 与 `doc/spec/optimize-f-data-json-escape/design.md` 的取数只覆盖 JSON 转义，不覆盖标量解析、反射字段访问与登记表拉取。按 reviewer 规则，候选只进「待验证假设」，不写成收益结论、不进 `todo.md` / `tasks.md`。

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DataReal.tryParse` 每次调用都重建一个 `Regex`（`Regex.REAL_NUMBER` 的 getter 体是 `#"…"#.regex(solid: true)`），标量文本解析的固定开销可能远大于 `Decimal.parse` 本身 | `DataReal.cj:229`；getter 在 `f_regex/src/ExtendRegex.cj:52-56` | 单次 `tryParse` 的自耗时占比与分配量 | `cjprof record` 跑 1e6 次 `DataReal.tryParse("123.45")`（`-O2`，3 轮取中位）；与 `try { Decimal.parse }` 版本对照 |
| 2 | `DataObject` 的 `iterator/toString/populate` 每字段一次反射调用（`ReadableField.get` → 反射 getter），大对象批量转换时是主要成本 | `DataObject.cj:98-101`、`:153`、`:199-201` | 反射调用占比、每字段耗时 | `cjprof` 跑 1e4 次 `@DataAssist` 对象 `populate`（20 字段），对比手工赋值的 `-O2` 基准 |
| 3 | `DataToString` 的 20 个标量重载每次 `append` 生成一个临时插值串，`toString` 再整串复制一次，大集合/宽对象峰值约 2× | `DataToString.cj:31-90`（`:25` 整体复制） | 分配量、峰值 RSS | 20 字段对象循环 `toString` 1e5 次，读 `getAllocatedHeapSize()` 与 RSS，和 `StringBuilder` 直拼版本对照 |
| 4 | `DataTypeRegistry.snapshot()` 每次全表复制为 `Array`，类型注册量大时启动期有一次 O(N) 分配尖峰 | `DataTypeRegistry.cj:70-76`（调用方 `f_codec/src/default/DefaultCodec.cj:103-112`） | 注册 1e3/1e4 类型时的耗时与分配峰值 | 压测脚本注册 N 个类型后触发一次 `pullRegisteredTypes`，记录耗时与 `getAllocatedHeapSize()` 差值 |

## 文件覆盖

> 与 `{workdir}/files/f_data.part2.txt` 一一对应（20 行，全部 `.cj`，本部分无 `.md`）。问题编号为「发现」中按出现顺序的序号（严重 #1；一般 #1~#6；轻微 #1~#7）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/base/DataAny.cj` | .cj | ✅ | `DataAny` 包装、`DataAnyMap/DataAnyList` 接口与 5 个 std 容器的 extend；一般 #6（`convertForMap`/`getData` 解包协议不一致）；`DataAnyMap/DataAnyList` 全仓零引用，属对外 API 不判死代码 |
| 2 | `f_data/src/base/DataBool.cj` | .cj | ✅ | 一般 #1（`DataString` 分支排在 `TYPE_NOT_MATCH` 兜底之后）；`TRUE/FALSE` 单例、`toBool/tryToBool` 均被引用或对外可达 |
| 3 | `f_data/src/base/DataConverter.cj` | .cj | ✅ | `DataConverter/AbstractDateTimeConverter/DateTimeConverter` 三个类型；`doConvert` 是 `public abstract` 非 sealed 类的 `protected` 成员（外部子类扩展点，按规则不判死代码），`f_config/src/DateTimeConfConverter.cj:21` 为其子类 |
| 4 | `f_data/src/base/DataDateTime.cj` | .cj | ✅ | 一般 #1（`DataDuration` 分支顺序）、#2（溢出抛 `ArithmeticException`）；轻微 #5（格式设置一次性 + ThreadLocal 无清除）；`setDefaultDateFormat/setCurrentThreadDateFormat` 全仓无调用（对外 API） |
| 5 | `f_data/src/base/DataDict.cj` | .cj | ✅ | `parse` 抛无消息异常（轻微 #1）；`toString` 的 `s.size > 1` 哨兵因 `(` 包裹而侥幸安全（轻微 #3 同源）；`tryParse` 返 `None` 有注释说明 |
| 6 | `f_data/src/base/DataDuration.cj` | .cj | ✅ | 一般 #1（`DataDateTime`/`DataString` 分支顺序）；轻微 #1（文案乱码）；`Duration.tryParse` 复用 `DataParsable` 的实现，无独立逻辑 |
| 7 | `f_data/src/base/DataFields.cj` | .cj | ✅ | 转换骨架；一般 #6 的三处解包实现（`fromData/convert/internal_f_data_tryFromData`）；`internal_f_data_tryFromData` 被 6 个集合 extend 使用 |
| 8 | `f_data/src/base/DataInputStream.cj` | .cj | ✅ | 一般 #5（9 份同构 `tryFromData` + 文案漂移）；轻微 #1（`parse` 无消息）；`toString` 恒 `'_'`，不可诊断 |
| 9 | `f_data/src/base/DataList.cj` | .cj | ✅ | 轻微 #3（空串元素丢逗号）；`parse` 无消息（轻微 #1） |
| 10 | `f_data/src/base/DataNone.cj` | .cj | ✅ | `INSTANCE` 单例 + `tryParse` 长度前置判断，无问题 |
| 11 | `f_data/src/base/DataObject.cj` | .cj | ✅ | 本部分问题最集中：严重 #1（`populate` 兜底）、一般 #4（`toString` 递归）、#6（`get<V>` 用错 flag）；轻微 #1（`connot` 文案）、#6（`tryParse` 反射） |
| 12 | `f_data/src/base/DataParsable.cj` | .cj | ✅ | `Duration` 解析器逐分支核对（符号只允许首位、单位严格递减、溢出经 `tryParse` 收敛），与 `DataParsable_test.cj` 的 13 个用例逐条对得上，未发现缺陷；轻微 #6（与 std `Parsable` 双协议） |
| 13 | `f_data/src/base/DataParsable_test.cj` | .cj | ✅ | 13 个 `@TestCase` 覆盖单/多段、单位顺序、ToString 往返、符号与空白拒绝、Int64/Duration 边界、溢出；断言方式（`match` 取值再 `@Assert`）与注释一致；未覆盖 `DataReal.tryParse`（一般 #3 的缺口） |
| 14 | `f_data/src/base/DataReal.cj` | .cj | ✅ | 一般 #3（`tryParse` 抛异常）、#5（10 组 `tryTo*` 复制，`:208-211` 记录了历史漂移 bug）；`integer` 字段被 `f_dbd/src/common/types.cj:490` 使用 |
| 15 | `f_data/src/base/DataString.cj` | .cj | ✅ | 轻微 #2（私有 `init()` 死代码）；`tryFromData` 的 `case x => x.toString()` 排在兜底之后（与一般 #1 同族，但这里是"任意类型转字符串"的刻意回退，未单列） |
| 16 | `f_data/src/base/DataToString.cj` | .cj | ✅ | 一般 #5（20 个同构 `append`、map 两套且结尾分隔符不同、`?T` 分支缺空格）；`toString` 的非幂等旧 bug 已修（`:21-26` 注释） |
| 17 | `f_data/src/base/DataTuples.cj` | .cj | ✅ | `Collection<(Data, Data)>` 形态使 `populate` 落到"默认对象"分支（严重 #1 的实例）；`parse` 无消息（轻微 #1） |
| 18 | `f_data/src/base/DataTypeRegistry.cj` | .cj | ✅ | 轻微 #7（同名 `addIfAbsent` 静默忽略）；并发结构正确（`ConcurrentHashMap` + 只增 `size`），无竞争缺陷 |
| 19 | `f_data/src/base/DataUnit.cj` | .cj | ✅ | 一般 #1（`DataString` 分支顺序 + 不剥引号）、轻微 #1（报错说成 `DataBool.parse`）；`==` 恒 `true` 对单例 Unit 成立 |
| 20 | `f_data/src/base/DummyDataFields.cj` | .cj | ✅ | 轻微 #4（`UnsupportedException` 无注释）；两个 stdx import（`stdx.net.http` / `stdx.encoding.url`）均被使用 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

> 仅统计本部分（20 `.cj` + 0 `.md`）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

**本部分是 `f_data` 的标量层与反射对象层：`DataXxx` 包装、`DataFields/DataConverter/DataParsable` 三件套、`DataObject` 与 `DataTypeRegistry`。** 代码的整体骨架是清楚的：`DataAny` 统一解包、`DataNone` 单例、`Duration` 解析器把"符号只允许首位/单位严格递减/溢出收敛为 None"写全了并有 13 个用例兜底，`DataTypeRegistry` 用并发容器 + 只增版本号避免了每次未命中全表遍历，`DataObject` 的字段访问全部收敛到 `ObjectFields`，`DummyDataFields` 之外没有"看起来能编译但什么都没做"的接口。

**唯一的阻塞项在失败语义，共三条，互相独立。**
1. **`populate` 把不可转换源变成默认对象**（严重 #1）：这是本部分最该先修的一条。JSON 里"对象字段收到数组/标量"会得到一个字段全默认的对象，被当成功值写库；它同时违反 README 的 flag 承诺，且触发点就在 `@DataAssist` 的常规字段写入路径上（`MutableField` → `convert` → `f_data_tryFromData`）。
2. **可转换分支排在类型兜底之后**（一般 #1）：`flag: 0` 或只带 `IGNORE_FIELD_NOT_CONVERTABLE` 时，String→Bool/Unit、DateTime↔Duration 这些"正路"直接报"does not match"；默认 flag 把问题盖住了，显式 flag 的调用方必踩。
3. **`SILENCE` 仍会抛异常**（一般 #2 的 `ArithmeticException`、一般 #3 的 `tryParse` 抛 `Decimal.parse` 异常）：flag 文档承诺"不抛"，异常却从 `try` 系列逃出；两处都只有一两行判空/包 try 的量，建议与 #1 同批修。

**维护性**：本部分的复制密度明显偏高——9 份 `DataInputStream.tryFromData`、10 组 `DataReal.tryTo*`、20 个 `DataToString.append`、7 份"解包 `Any`"协议。这些不是"看起来丑"：`DataReal.cj:208-211` 的注释记着一次因复制漂移写错区间数组的历史缺陷，`DataObject.get<V>` 的 flag 错用也长在第 7 份复制体上。收敛顺序建议先做解包协议（7 份 → 1 份，可同时消掉两处 flag/异常类型不一致），再做三族样板。

**风险提示**：`toString` 的递归（一般 #4）是全模块级的——`f_codec`/`f_mvc` 到处插值 `Data`，深层嵌套数据只要进日志就可能崩线程；深度阈值需要实测，但"无上限"这一点是静态确定的。`DummyDataFields`（轻微 #4）目前只是埋雷，等有人把 `HttpRequest` 当字段写进 `@DataAssist` 类就会在序列化时炸。

本部分 14 条发现全部为存量（快照无基线），是否纳入修复待用户决定；性能类结论一条都没有（4 个候选在「待验证假设」里等数据）。本轮只读代码，未改源码、未跑构建。
