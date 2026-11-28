# f_data 模块审查报告

> **模块第 3/8 部分**（本报告只覆盖 `files/f_data.part3.txt` 列出的 20 个文件，全部为 `.cj`：`src/base/FieldAlias.cj` → `src/json/CompiledSchema_test.cj`。`README.md` / `README_en.md` / `doc/**` 与其余 107 个 `.cj` 由同模块其他部分产出；本部分编号独立，合并时以主 Agent 为准。README 只作为取证判据被引用，不计入本部分「文件覆盖」。）

- **审查日期**：2026-11-28
- **模块路径**：`f_data`（本部分 20 个 `.cj`，0 个 `.md`；模块共 127 `.cj` + 15 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 仅 `docs/review/` 与 `reviews/` 未跟踪，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：JSON / 数据结构正确性与边界、OOM、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 3/8 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字符串→数值转换是 JSON→PO 的热点，重复 `trimAscii` + 正则匹配占其自耗时大头 | `f_data/src/base/NumberData.cj:32-47` | 该函数自耗时占比、分配次数 | `cjprof record` 跑 10k 行 JSON→POPO（含字符串数值字段），看 `NumberData`/`trimAscii`/`Regex.matches` self time |
| 2 | 每次 `MutableField.set` 都构造 `AnnotationTag` 是 `set` 路径的固定开销 | `f_data/src/base/ReadableField.cj:47-50` | 调用次数 × 单次耗时、命中率 | 加计数器埋点（命中/未命中）+ `cjprof` 跑 1e5 次 `populate` |
| 3 | `checkDoc` 的 `path` 拼接在启动期占 `compile` 的可观比例 | `f_data/src/json/CompiledSchema.cj:64-79` | 分段计时（`MonoTime` 包 `checkDoc` 与 `compile`） | 对 500 节点 schema 重复 compile 1e4 次，记录前后耗时 |
| 4 | 大 map 的 `DataMap.toString` 会整串物化，峰值内存随条目数线性放大 | `f_data/src/base/MapData.cj:44-54` | 峰值 heapUsed / 单次分配量 | 100 万条目 map 调 `toString`，前后 `getAllocatedHeapSize()` + RSS |
| 5 | `ObjectFields` 的嵌套 `computeIfAbsent` 在同 bin 下是否真的不自锁 | `f_data/src/base/ObjectFields.cj:66-70` | std `entryView` 的锁实现细节；并发首访压测结果 | 多线程并发首访 200 个"子类+父类"类型组合（含 hash 冲突构造），观察 hang；或读 `ConcurrentHashMap` 源码 bin 锁粒度 |
| 6 | `DataString` 严格模式的转换失败在实际业务里有调用面 | `f_data/src/base/NumberData.cj:30-47` | 外部调用方传入的 flag 分布 | 在 `tryFromData` 入口埋点统计 `flag` 取值分布，跑一周生产/压测 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_data/src/base/FieldAlias.cj` | .cj | ✅ | 注解定义，与 `ObjectFields.cj:52-56` 的消费方式核对 |
| 2 | `f_data/src/base/MapData.cj` | .cj | ✅ | 见 #3；容器解析返回空 map 的问题 |
| 3 | `f_data/src/base/MutableField.cj` | .cj | ✅ | 见 #1；两重载的转换链漂移 |
| 4 | `f_data/src/base/NamedData.cj` | .cj | ✅ | 两个 extend 同构，语义无差异，未计重复 |
| 5 | `f_data/src/base/NumberData.cj` | .cj | ✅ | 见 #2 / #9 / #13，13 处同构实现逐一核对 |
| 6 | `f_data/src/base/NumberData_test.cj` | .cj | ✅ | 覆盖 2026-10-15 修复项；缺严格 flag 与 BigInt/Decimal 用例 |
| 7 | `f_data/src/base/ObjectFields.cj` | .cj | ✅ | 见 #5 / #10 / #12 / #14 |
| 8 | `f_data/src/base/OptionData.cj` | .cj | ✅ | 见 #13（`tryFromData` 直接转发 `Any`） |
| 9 | `f_data/src/base/ReadableField.cj` | .cj | ✅ | 见 #8 / #10；注解缓存与 `newGetter` 双载荷 |
| 10 | `f_data/src/base/ReadonlyField.cj` | .cj | ✅ | 与 `MutableField` 同构，转换链无旁路，无额外问题 |
| 11 | `f_data/src/base/Validator.cj` | .cj | ✅ | `And/Or/Not/Dummy/Combined` 组合语义与 README 一致；`DummyValidator` 是显式 Null Object |
| 12 | `f_data/src/base/data_cmp.cj` | .cj | ✅ | fail-open 已在 2026-10-15 修复并有注释；local 载荷 `f_data_eq_copy`/`f_data_cmp_copy` 与 `DataAssist` 生成代码对得上 |
| 13 | `f_data/src/base/global_objects.cj` | .cj | ✅ | flag 定义与优先级注释自洽；见 #11（README 名字不符） |
| 14 | `f_data/src/base/imported.cj` | .cj | ✅ | 包级 `public import` 汇总；`MonoTime`/`UnixSocket` 等重导出属对外表面扩张，见覆盖自检 §1 行 |
| 15 | `f_data/src/exception/DataException.cj` | .cj | ✅ | 四个异常类逐行同构（仅类型名不同），因 `catch` 需独立类型，不计重复缺陷 |
| 16 | `f_data/src/exception/DataParsableException.cj` | .cj | ✅ | 同上 |
| 17 | `f_data/src/exception/JsonException.cj` | .cj | ✅ | 同上（版权年 2026，与创建年一致） |
| 18 | `f_data/src/exception/ValidationException.cj` | .cj | ✅ | 同上 |
| 19 | `f_data/src/json/CompiledSchema.cj` | .cj | ✅ | 见 #4 / #6 / #7 |
| 20 | `f_data/src/json/CompiledSchema_test.cj` | .cj | ✅ | 5 条用例；缺深嵌套、重复 pattern、`properties: 1` 类型错误用例 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量缺陷 14 条（严重 1 / 一般 8 / 轻微 5），是否纳入修复待用户决定；本部分无「本次改动」来源。

## 总评

本部分的骨架是稳的：`Data`/`DataFields` 的转换契约、flag 优先级（`global_objects.cj` 的注释与实现自洽）、`Validator` 组合模型、`data_cmp` 的 fail-open 修复都做得比一般内部库严谨，`CompiledSchema` 也把"注册期编译、请求期查表"这条主线接上了。

风险集中在两处。**第一处是"13 份复制粘贴的数值转换"**：`NumberData` 用同一套模板铺了 13 个类型 × 5 类输入，任何一次改动都要改 13 遍，历史上已经因此出过 IntNative 漏负号的缺陷，现在还留着 BigInt/Decimal 缺分支（#9）和字符串分支被兜底 `throw` 盖住（#2）。这是本模块最值得投一次重构的地方，收益是"以后不用改 13 遍"。**第二处是"承诺与实现的缝隙"**：非空字段的 `@DataConverter` 静默失效（#1，唯一一条严重）、结构校验只做了一半（#7）、`ReadableField` 被文档当成扩展点却不可见不可继承（#8）、README 的 flag 名字根本不存在（#11）——这些都是"文档说可以、代码里没有"，比性能问题更容易在前端联调时浪费时间。

并发面上没有发现既成事实的数据竞争：两个全局缓存的读路径都是只读共享，`ConcurrentHashMap` + `addIfAbsent` 的意图正确。真正需要确认的只有 #4（schema 编译后被改）与 #5（`computeIfAbsent` 回调内重入 `entryView`）两个"灰区用法"，前者建议直接把请求路径改成只读表，后者建议按 `f_base` 的"填完再发布"模式重写，两处改动都小且不改变对外语义。

性能与内存方面本部分没有 profile/bench 数据，所有结论都是"待验证假设"，不进修复清单；其中 `NumberData` 的重复裁剪/匹配（假设 #1）最值得先采数据。
