# f_base 模块审查报告（第 3/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（52 个源文件，本部分覆盖 15 个）
- **本部分范围**：`OverSizeException.cj`、`OverSizePolicy.cj`、`Peekable.cj`、`Result.cj`、`SingleIterable.cj`、`StringGenerator.cj`、`StringGeneratorRune_test.cj`、`TypeInfos.cj`、`TypeInfos_test.cj`、`TypeMemberInfos.cj`、`UnsafeBytes.cj`、`UnsafeData.cj`、`WorkerStrategy.cj`、`hex.cj`、`macros/nameof.cj`
- **基线**：工作区快照（当前检出 `sts/1.3.x` 的合并提交 `8c0ce643a`，工作区仅多出 `reviews/` 目录，无源码改动）
- **审查重点**：超限策略、Result、类型信息、unsafe 字节/数据、死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG、并发安全与锁粒度
- **报告版本**：v1（本文件是 `f_base` 模块 4 个子轮中的第 3 部分，待主 Agent 合并为 `docs/review/f_base_review_20261128.md`）

## 发现

### [严重][存量] `StringGenerator.remove` / `replace` 传入空搜索串时进入死循环（`remove` 还伴随无界内存增长）

- **位置**：`f_base/src/StringGenerator.cj:156`（`remove` 的 while 循环）、`f_base/src/StringGenerator.cj:158`（`torm.add`）、`f_base/src/StringGenerator.cj:177`（`replace` 的 while 循环）
- **来源**：存量（`git blame` → `4be871f2f`，2026-10-02 统一换行符提交之前的既有实现，非本次改动）
- **判据**：review-checklist §5（无界容器/拒绝路径缺失）、§11（边界/空值未处理）、§6.4（低效算法）
- **证据**：静态确定 —— 已核 `std` 源码 `/storage/.../stdlib/libs/std/core/array_common.cj:207`：`indexOf(elements, fromIndex)` 在 `elements.size == 0` 且 `fromIndex < this.size` 时，循环首轮 `this[i..i] == []` 恒真，返回 `Some(fromIndex)`。
- **描述**：
  - `remove` 的循环体 `let range = idx .. idx + search.size`（`StringGenerator.cj:157`）在 `search` 为空时是 `idx..idx`，`fromIdx = range.end`（`:159`）恒等于 `idx`，且下一轮 `indexOf` 仍返回同一个 `idx` ⇒ **while 永不退出**；同时 `torm.add(range)`（`:158`）每轮都追加一个空区间 ⇒ `ArrayList<Range<Int64>>` 无界增长，最终 OOM。
  - `replace` 在 `oldBytes.size == newBytes.size == 0` 时走 `utf8.unsafeData()[idx..idx] = []` 的无操作分支（`:179`），`fromIdx = idx + 0`（`:189`）同样不前进 ⇒ **纯 CPU 死循环**（无分配，进程直接挂住）。
  - 触发条件只是"待删除/待替换内容为空串"，而 `content` 是 `T <: ToString` 的调用方入参（可能来自配置、模板占位符），不是非法输入。
- **建议**：方法入口显式拒绝空搜索串（`if (search.isEmpty()) { return this }` 或抛 `IllegalArgumentException`），并在循环里加"位置必须前进"的自检（`fromIdx = range.end > fromIdx ? range.end : fromIdx + 1`）。两个方法都要改，不能只改一处。

### [严重][存量] `TypeMemberInfos` 缓存"先发布、后填充"，`HashMap` 被并发读写

- **位置**：`f_base/src/TypeMemberInfos.cj:28`（`staticPropertyMap[typeInfo] = map` 在填充前发布）、`f_base/src/TypeMemberInfos.cj:102`（`staticFunctionMap[typeInfo] = map` 同样先发布）、填充动作在 `:30-33` / `:104-109`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §12.1（发布逸出 / 迭代与修改并发）、§6.2（锁内/缓存一致性）
- **证据**：静态确定 —— 只读代码即可判定：`map` 是普通 `HashMap`，在 `case _ =>` 分支里先写进 `ConcurrentHashMap` 让其它线程可见，之后才在局部函数里逐个 `map[p.name] = p`。
- **描述**：`getStaticPropertyMap` / `getStaticFunctionMap` 是静态方法、缓存是静态字段，任何线程都会走同一条路径。线程 A 首次未命中时先把**空 map** 发布到 `ConcurrentHashMap`，再逐条写入；线程 B 此时 `get(typeInfo)` 命中同一个空 map，随即 `get(name)` 或 `values()` 读取 —— 一边 `put` 一边读普通 `HashMap`，属于数据竞争（可能读到半成品、丢条目，扩容期还可能读到错乱桶链）。另外 `staticProperty(typeInfo, name)` 对外返回的 `Collection`（`:50`）就是这个可变缓存本身，调用方遍历时被另一线程填充同样是并发修改。与另外 4 个同类 getter（`:79`、`:159`、`:197`、`:237` 都是"填完再发布"）不一致，属于典型漂移。
- **建议**：统一改成"局部建好 → 填满 → 再 `put`"，并改用 `putIfAbsent` 让并发首次构建的赢家唯一（`ConcurrentHashMap.addIfAbsent`），输家丢弃自己那份直接返回缓存值；若必须在填完前发布，则把内层容器换成不可变结构或用锁保护整个构建段。

### [一般][存量] `TypeMemberInfos` 三个 getter 的闭包捕获了外层变量，继承来的成员查不到

- **位置**：`f_base/src/TypeMemberInfos.cj:30`（`addProp(ti)` 内遍历的是 `typeInfo.staticProperties`）、`f_base/src/TypeMemberInfos.cj:104`（`addFunc(ti)` 内遍历的是 `typeInfo.staticFunctions`）、`f_base/src/TypeMemberInfos.cj:232`（`for (v in x.instanceVariables)`，循环变量是 `c`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（语义与实现不符）、§2（近似重复导致行为漂移）
- **证据**：静态确定 —— 形参 `ti` / `c` 在函数体内完全没被读取；把这三处与正确实现 `addProps(ti)`（`:66`）、`addFunc(ti)`（`:143`）、`staticVariables` 的 `for (v in c.staticVariables)`（`:192`）对照即可确认。
- **描述**：三个方法都按"沿 `superClass` 链向上遍历"的意图写成 `while` 循环，但取成员时用了循环外的 `typeInfo`（或初始的 `x`），于是：静态属性/静态函数每轮重复添加**最派生类自己**的那份，父类的静态成员永远进不了缓存；实例字段每轮重复添加 `x` 自己的字段，父类字段永远缺失。后果是 `staticProperty` / `staticFunction` / `instanceVariable` 对继承成员返回 `None` —— `f_data/src/base/DataObject.cj:78-90` 这类按名反射读写属性的调用方会静默走错分支。
- **建议**：三处闭包改读形参（`for (p in ti.staticProperties)`、`for (f in ti.staticFunctions)`、`for (v in c.instanceVariables)`），并补一条"子类实例能查到父类字段/父类静态方法"的回归用例（当前 `f_base` 无 `TypeMemberInfos` 测试）。

### [一般][存量] `StringGenerator.remove` 倒序删除漏掉下标 0，单匹配时完全不删

- **位置**：`f_base/src/StringGenerator.cj:161`（`for(i in torm.size - 1 .. 0: -1)`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（边界差一）、§6.4
- **证据**：静态确定 —— 已核 `std` 的 `Range` 源码 `/storage/.../stdlib/libs/std/core/range.cj:65-93`：非闭区间 `a..b` 配 `step = -1` 时 `last() = end.next(1)`，迭代序列是 `a, a-1, …, b+1`，**不含 `b`**。`std` 自身在 `array_common.cj:240` 用的是 `size - 1..=0 : -1`（闭区间）。
- **描述**：`torm` 按下标升序收集命中区间，倒序删除方向正确，但区间末端写成 `0`（半开）⇒ 只删到下标 1。`torm.size == 1` 时 `0 .. 0 : -1` 是空区间，**一个都不删**；`torm.size > 1` 时首个命中残留。表现为 `gen.remove("{x}")` 返回后文本里仍留一处/全部占位符，属静默产出错误字符串。
- **建议**：改成 `for (i in torm.size - 1 ..= 0 : -1)`（或 `torm.size - 1 .. -1 : -1`），并补用例覆盖 0 处 / 1 处 / 多处命中。

### [一般][存量] `StringGenerator.checkIndex` 边界过严：合法位置被拒、空生成器上的无操作调用直接抛异常

- **位置**：`f_base/src/StringGenerator.cj:41`（`fromIndex >= size` 判定），影响 `remove`（`:152`）、`replace`（`:173/194`）、`replaceFirst`（`:211`）、`replaceLast`（`:231`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（边界差一）、§10（边界校验）
- **证据**：静态确定 —— `size` 是字节长度（`std` 文档：`String.size` 为 UTF-8 字节长度，且本类 `utf8` 存字节），判定式只允许 `fromIndex < size`。
- **描述**：两类合法调用被误判：① `fromIndex == size`（在末尾追加式替换/删除，例如把尾部占位符换成另一段）被判越界；② 对空生成器（`size == 0`）调用 `remove` / `replace` / `replaceFirst`（默认 `fromIndex = 0, toIndex = size = 0`）必抛 `IndexOutOfBoundsException`，而语义上应是"无匹配、原样返回"。当前下游多在非空串上使用，因此长期没暴露。
- **建议**：`fromIndex > size` 才算越界（保留 `fromIndex < 0` 与 `toIndex < fromIndex || toIndex > size`），并允许 `size == 0 && fromIndex == 0 && toIndex == 0` 通过。

### [一般][存量] `StringGenerator.substring` 不做索引与 UTF-8 边界校验，可产出非法 `String`

- **位置**：`f_base/src/StringGenerator.cj:128-132`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（契约/边界）、§10（正确性）
- **证据**：静态确定 —— 已核 `std`：`Array[a..b]` 越界抛 `IndexOutOfBoundsException`，`String.fromUtf8Unchecked` 只做 `clone`、**不做** UTF-8 合法性检查（`stdlib/libs/std/core/string.cj:271-273`）。
- **描述**：与同类方法不同，`substring` 既不调 `checkIndex`，也不校验 `start/end` 是否落在字符边界。对中文等多字节内容，`substring(0, 1)` 会构造出半个字符的 `String`，违反 `String` 的 UTF-8 不变量（此后 `runes()`、比较、`rawData` 消费方行为不可预期）。注意 `Array` 切片会抛越界异常，所以"越界崩溃"这一路是安全的，风险集中在**非法 UTF-8 静默通过**。
- **建议**：补 `checkIndex(start, end)`，并（若 API 语义允许）把 `start/end` 定义成字符边界或提供按 Rune 的子串方法；若刻意保留字节语义，需在注释里写明"调用方保证落在字符边界"。

### [一般][存量] `hex.fromHex` 只校验长度上限，空串/单字符/非十六进制字符走越界或未文档化异常

- **位置**：`f_base/src/hex.cj:29-34`（判定在 `:30`，取值在 `:33`）
- **来源**：存量（`git blame` → 早于 `4be871f2f` 的实现）
- **判据**：review-checklist §11（空串/边界未处理、错误处理缺失）
- **证据**：静态确定 —— 代码只判 `s.size > 2`；`s[0]`/`s[1]` 在 `size` 为 0/1 时必然越界；`hexmap` 只装了 `'0'-'9'`、`'a'-'f'` 16 个键，`Map.[]` 缺键是抛异常而非返回 `None`。
- **描述**：`fromHex("")`、`fromHex("a")` 抛 `IndexOutOfBoundsException`；`fromHex("zz")`、`fromHex("0A")`（大写）抛哈希表缺键异常。方法签名承诺"String → Byte"，实际没有任何输入校验，错误类型也不是 `IllegalArgumentException`，调用方无法区分"输入非法"与"内部 bug"。`toHex` 侧无问题。
- **建议**：入口判 `s.size != 2` 抛 `IllegalArgumentException(s)`；取值改为 `hexmap.get(...)` + `?? throw IllegalArgumentException(s)`；如要支持大写，建表时把 `'A'-'F'` 一并写入（或先 `toAsciiLower`）。

### [一般][存量] `OverSizePolicy` 契约没有"是否接受"的反馈，`DiscardOverSizePolicy` 静默丢元素

- **位置**：`f_base/src/OverSizePolicy.cj:25`（`func reject(o: T, fn: () -> Unit): Unit`）、`f_base/src/OverSizePolicy.cj:36`（`DiscardOverSizePolicy.reject` 空实现）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §3（公开契约声称有行为但实现为空 / 静默吞掉）、§11（契约与实现不符）
- **证据**：静态确定 —— `reject` 返回 `Unit`，`fn` 是否被执行是唯一信号，但策略实现不回报执行结果；实际调用方 `f_collection/src/PriorityQueue.cj:101`（范围外，仅作契约核对）里 `add(x): Unit` 直接丢弃了这个信号。
- **描述**：容器满时 `DiscardOverSizePolicy` 丢弃新元素、`BlockingOverSizePolicy` 超时也可能丢弃，但 `add` 的调用方拿到的是 `Unit`，无法得知"元素没进队列"。对队列类 API 这是静默数据丢失，且没有任何日志/计数钩子。
- **建议**：`reject` 增加返回值（如 `Bool` 表示"已处理/已接收"），或让 `add` 返回 `Bool`/抛 `OverSizeException`；至少在 `DiscardOverSizePolicy` 里留 `// 有意丢弃：策略即"满则丢新值"，调用方需自行保证可丢` 之类的注释（见下一条）。

### [一般][存量] `BlockingOverSizePolicy.reject` 超时后静默丢弃，且条件等待不重查谓词

- **位置**：`f_base/src/OverSizePolicy.cj:63-70`（`condition.wait` 在 `:65`，`recovered(o)` 分支在 `:67-69`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §12.1（条件等待虚假唤醒未在循环里重查条件）、§11（错误处理缺失）
- **证据**：静态确定 —— `std.sync.Condition.wait(timeout)` 返回 `Unit`（`sync_package_classes.md:8295`），因此无法区分"被通知"与"超时"；`recovered(o)` 为 `false` 时函数直接返回，既不 `throw` 也不走 `policy`。
- **描述**：语义上它是"等空间 → 有空间就按内层策略重试 / 没空间就……"，但"没空间"这一支是空的分支：新元素被丢掉而调用方无感（叠加 `add` 返回 `Unit`，见上一条）。另外默认 `timeout = Duration.Max`（`:60`），在没人调用 `notify/notifyAll` 的场景下 `reject` 会永久阻塞调用线程；`wait` 也没有放在 `while (!recovered(o))` 循环里，被无关的 `notify` 唤醒后会直接走向丢弃分支。
- **建议**：`wait` 包进 `while` 重查 `recovered(o)`，并记录是否超时（`wait` 前后取 `DateTime.now()` 或改用 `Mutex` 的 `tryLock`+`sleep` 组合）；超时后要么抛 `OverSizeException`，要么显式交给 `policy.reject`，不要留空分支。默认超时建议改成有限值（如 30s）并在文档里写明。

### [一般][存量] `TypeInfos.getGenericTypes(qualifiedName:)` 调用了仓内不存在的 `parseParameterTypes`

- **位置**：`f_base/src/TypeInfos.cj:64`
- **来源**：存量（`git blame` → 该行自初始提交 `45aeab749` 起就存在；`git log -S 'parseParameterTypes'` 全历史只命中调用点）
- **判据**：review-checklist §11（契约与实现不符）、§1（无定义符号）
- **证据**：待确认 —— ① 全仓 `grep -rn 'parseParameterTypes'`（含大小写不敏感、含非 `.cj`）只有这一处调用，`f_base/src` 及其它模块均无定义、`f_base` 也无 `extend TypeInfos`；② 但 `f_base/target/release/f_base@fountain/libf_base@fountain.so` 里存在同名符号，说明构建机（`/mnt/linux_share/...`）的源码与当前工作区不一致 —— 需确认是否存在未入库文件或生成代码。
- **描述**：按当前工作区源码，`getGenericTypes(qualifiedName:)` 无法解析 `parseParameterTypes`，该文件应编译失败；即使能编过，`qualifiedName[i + 1 .. qualifiedName.size - 1]` 在没有结尾 `>` 时会静默截断最后一个字符，嵌套泛型 `Foo<Bar<Int64>>` 里的 `,`/`<` 也无从切分。该方法在仓内零调用（属对外 public API）。
- **建议**：补上 `parseParameterTypes` 的实现（按 `<>` 深度切分参数，逐个走 `TypeInfos.get(qualifiedName:)`），或把该方法降级/删除；先在本机 `cjpm build` 确认是否真的编不过，再决定是"补实现"还是"删 API"。

### [一般][存量] `Result.mapError` / `flatten` / `transpose` 在类型不匹配时静默丢弃 Ok 值

- **位置**：`f_base/src/Result.cj:98-99`（`case Ok(v: U) => Ok(v)` + `case Ok(_) => Ok`）、`f_base/src/Result.cj:162-163`（`flatten`）、`f_base/src/Result.cj:170-181`（`transpose`，`Ok(None)` 落到 `NoResult`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（错误处理/数据丢失）、§10（`Result` 是否被静默丢弃）
- **证据**：静态确定 —— 三个方法都用"运行时类型测试 + 兜底空值"的写法，兜底分支不保留原值也不报错。
- **描述**：`mapError` 只该改写 `Err`，但 `T` 不是 `U` 时 `Ok(v)` 被替换成裸 `Ok`（值丢失）；`flatten` 对"`Ok` 里不是 `Result<U,E>`"同样降级为裸 `Ok`；`transpose` 把 `Ok(None)` 映射成 `NoResult` 并被外层 `?` 自动包成 `Some(NoResult)`，而标准 transpose 语义应是 `None`（`Ok(Some(x)) → Some(Ok(x))`、`Err(e) → Some(Err(e))`、`Ok(None) → None`）。这些都没有文档说明，调用方很容易把"值被吞掉"当成正常。
- **建议**：给 `mapError` 加 `T <: U` 约束（或用 `Result<U, E>` 的转换函数显式承担丢失语义并在注释写明）；`transpose` 的 `Ok(None)` 分支返回 `None`；`flatten` 的兜底改为 `Err`/抛异常，不要静默 `Ok`。

### [轻微][存量] `OverSizePolicy` 接口注释与实际调用方式相反

- **位置**：`f_base/src/OverSizePolicy.cj:21-24`（接口注释）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 注释写"`o` 是待添加的新值"，而实际调用方 `f_collection/src/PriorityQueue.cj:101` 传的是 `this`（队列本身），新元素在 `fn` 闭包里（范围外仅作契约核对）。
- **描述**：实现 `RemoveSomeOnePolicy` 的 `remove(o)` 语义是"从容器里腾一个位置"，与注释描述的"新值"完全不同；照注释去写实现会得到"删除尚未入队的新值"的错误策略。
- **建议**：重写注释：`o` 是**已满的容器**，`fn` 是"腾出空间后重新提交"的动作；并补一句各实现的预期作用对象。

### [轻微][存量] `DiscardOverSizePolicy` 空实现没有"有意 no-op"说明

- **位置**：`f_base/src/OverSizePolicy.cj:36`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §3（有意的 Null Object 必须有注释说明为什么可以空）
- **证据**：静态确定 —— 方法体为 `{}`，`fn` 与 `o` 都被丢弃，类上无注释。
- **描述**：与 `AbortOverSizePolicy`、`CallerRunsOverSizePolicy` 并列时，读者无法判断空实现是"刻意丢弃"还是"忘了写"。
- **建议**：补 `// 有意丢弃：满则丢新值（fn 不执行），与 Java ThreadPoolExecutor.DiscardPolicy 同义`。

### [轻微][存量] `StringGenerator` 内部重复逻辑（`reset`/`clear`、三处 replace、removeFirst/removeLast）

- **位置**：`f_base/src/StringGenerator.cj:35-38` 与 `:133-136`（完全相同）；`:178-188` / `:215-225` / `:235-245`（11 行拼接体逐行相同）；`:137-143` 与 `:144-150`（只差取下标调用）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— 逐行比对函数体的"输入-输出-副作用"摘要一致。
- **描述**：`replace` 的三份拼接体已经是"改一处必须改三处"的状态（本次审查已在其中发现空串死循环与边界问题，需要三处同改）；`reset` 与 `clear` 是同一语义的两个名字。
- **建议**：抽 `private func spliceAt(idx: Int64, oldSize: Int64, newBytes: Array<Byte>)`；`reset` 保留为 `clear` 的别名并在注释说明（或直接删 `reset`，若确认无外部依赖）。

### [轻微][存量] `Result` 的 5 个 prop 与 4 个 filter 方法同构，`ResultFilter` 又重写一遍

- **位置**：`f_base/src/Result.cj:25-66`（`isOk`/`isErr`/`isNoResult`/`withE`/`withValue`）、`:129-156`（4 个 `filterXxx()`）、`:238-286`（`ResultFilter.filter` 的等价判定）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2
- **证据**：静态确定 —— 每个成员都是"对 `this` 做一次变体归属判断 → Bool/自身/`NoResult`"。
- **描述**：`filterOk()` 与 `filterOk(predicate)` 的语义分散在两个类型里（`Result` 与 `ResultFilter`），新增变体时要改 9 处以上；`ResultFilter.filter` 的 `Ok`/`Err` 两个分支也是同一段逻辑复制。
- **建议**：用 `isOk` 等 prop 实现 4 个 `filterXxx()`；`ResultFilter.filter` 抽一个 `keep(origin, flag, fn?)` 辅助函数，`Ok`/`Err` 各调一次。

### [轻微][存量] `@nameof` 缺空输入校验，与 `@nameValueOf` 不一致

- **位置**：`f_base/src/macros/nameof.cj:23-25`（对比 `:31-34`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（近似重复导致行为漂移）、§3（错误提示缺失）
- **证据**：静态确定 —— `nameValueOf` 有 `input.size == 0` 的 `diagReport` + 抛异常，`nameof` 直接 `quote(@nameValue($input)[0])`。
- **描述**：`@nameof()` 会展开成 `@nameValue()[0]`，报错点落在使用处而不是宏参数，且错误文案与 `nameValueOf` 不一致。两个宏共享"取最后一个 IDENTIFIER"的判定逻辑，却只有一份做了校验。
- **建议**：把"空输入/末 token 必须是 IDENTIFIER（或 `x.y` 形式）"抽成一个私有宏辅助函数，两个宏都调用。

### [轻微][存量] `PeekableIterator.isClosed()` 对非 `Resource` 迭代器恒为 `true`，`close()` 后仍可 `next()`

- **位置**：`f_base/src/Peekable.cj:46-51`（`case _ => true`）、`:22-30`（`next` 不看关闭状态）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `Resource` 的 `isClosed` 语义是"资源是否已关闭"，这里被当成"底层不是 `Resource` 就视为无需关闭"。
- **描述**：包装一个普通 `Iterator` 时，`isClosed()` 在从未 `close()` 的情况下就返回 `true`，而迭代仍能继续；按 `Resource` 契约判断"已关闭就不要再读"的调用方会被误导。
- **建议**：加一个 `private var closed = false`，`close()` 置位并转发；`isClosed()` 返回 `closed || (itr is Resource && itr.isClosed())`，同时让 `next()` 在 `closed` 时返回 `None`。

### [轻微][存量] `TypeInfos.withAnnotation` 的 `?? None` 是恒等无用表达式

- **位置**：`f_base/src/TypeInfos.cj:74`
- **来源**：存量（`git blame` → `aba9a64f8` 之前即为该写法）
- **判据**：review-checklist §1（无意义表达式/可读性）、§10
- **证据**：静态确定 —— `findAnnotation<A>()` 已返回 `Option<A>`，`?? None` 不改变结果。
- **描述**：容易被误读成"把 `null` 归一化"，实际是空操作；也掩盖了"`instanceFunction` 为 `None` 时等价于无注解"这一判断。
- **建议**：删掉 `?? None`，直接 `.isSome()`。

### [轻微][存量] `UnsafeData` / `UnsafeBytes` 缺"视图 vs 副本""零拷贝"契约注释

- **位置**：`f_base/src/UnsafeData.cj:24-29`（返回 `getRawArray()[0..size]` 视图）、`f_base/src/UnsafeBytes.cj:23-33`（`rawData()` 视图、`withRawData` 零拷贝）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §7（副本假象）、§11（契约未文档化）
- **证据**：静态确定 —— 已核 `std` 文档/源码：`Array[Range]` 返回**共享底层存储的切片**（`core_package_structs.md:1544` 示例：改原数组后切片内容随之变化），`String.rawData` 明示"不要修改返回数组"，`String.withRawData` 不做拷贝。
- **描述**：两个接口都没有任何注释，而它们的语义恰恰是"调用方拿到的是活视图"：① 对 `ArrayList` 做 `add`/`remove` 之后，先前拿到的 `unsafeData()` 可能指向已被替换的旧数组，或与当前 `size` 脱节；② `unsafeUtf8(bytes)` 之后若复用/清空该数组（例如 `ByteBuffer.clear()`），字符串内容会被后续写入改写 —— 这正是 `String` 不可变性的破口。仓内现有调用方（`f_codec/src/default/DefaultCodec.cj:808`、`f_data/src/json/JsonValue.cj:114`）传的都是本次调用新建的数组，暂未触发（范围外提示，不占本轮统计）。
- **建议**：在接口上补注释写明"返回共享视图，生命周期内不得对底层容器扩缩容/复用该缓冲区；调用方需保证数组在字符串存活期间不被修改"，并在 `unsafeUtf8` 的文档里点名这个前提。

### [轻微][存量] 测试用 `@Assert(true, cond)`，失败时没有任何可用信息

- **位置**：`f_base/src/StringGeneratorRune_test.cj:46`、`f_base/src/StringGeneratorRune_test.cj:68`
- **来源**：存量（`git blame` → `4f1a463c7`）
- **判据**：review-checklist §10（可维护性/可测试性）
- **证据**：静态确定 —— `Array<Byte>` 已实现 `Equatable<Array<Byte>>`（`core_package_structs.md:2014` 元素级相等），无需绕过断言。
- **描述**：`@Assert(true, a == b)` 的断言期望值恒为 `true`，失败时报出的是 "expected true, actual false"，看不出是哪段字节不匹配。
- **建议**：改成 `@Assert(expected.unsafeBytes(), gen.unsafeBytes())`；若要更细的定位信息，失败时打印两串的十六进制（`toHex`）差异下标。

### [轻微][存量] `ResultFilter` / `ResultMapper` 未配置规则时静默把有值分支降级

- **位置**：`f_base/src/Result.cj:238-286`（`ResultFilter.filter` 空配置 ⇒ 全部 `NoResult`）、`f_base/src/Result.cj:291-295` + `:316-324`（`ResultMapper` 默认 `resultMap` 丢弃 `T` 只返回 `Ok`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（契约不清导致数据丢失）、§3
- **证据**：待确认 —— 属"设计意图不明"：没有文档说明"不设规则 = 全部过滤掉 / 全部映射为空壳"是否为预期。
- **描述**：`r.filter()` 不设任何条件时，`Ok(v)`/`Err(e)` 都变 `NoResult`（值被丢）；`r.mapper().map()` 不设 `result(f)` 时，`Ok(v)` 变裸 `Ok`（值被丢）。两处都是"少写一步就静默丢数据"，且没有任何断言或日志。
- **建议**：默认行为改为"原样返回"（无规则即恒等），或在方法注释中明确写出默认语义；`ResultMapper` 的 `resultMap` 默认实现建议直接抛 `UnsupportedException`（漏配置是编程错误，不该静默降级）。

### [轻微][存量] `TypeInfos.get(name)` 在锁内做反射注册表查找，且不缓存失败

- **位置**：`f_base/src/TypeInfos.cj:41-51`
- **来源**：存量（`git blame` → `aba9a64f8`）
- **判据**：review-checklist §6.2（锁内做耗时操作）、§12.2（临界区内容）
- **证据**：需实测 —— 临界区是一次 `TypeInfo.get(qualifiedName)`（全局注册表查找，量级取决于注册类型数）+ 一次 `ConcurrentHashMap` 写入；冷路径，但未注册的名字每次都会重新进锁并抛 `InfoNotFoundException`（无负缓存）。
- **描述**：若调用方按请求驱动地探测类型名（配置/注解/路由名），未命中路径会串行化所有线程，且每轮都要抛一次异常。是否成为实际热点取决于探测频次。
- **建议**：把 `TypeInfo.get` 的调用挪到锁外（先构建再 `putIfAbsent`），并对确定不存在的结果做有界负缓存（`Map<String, Bool>` + 容量上限），或在文档里约定"只用于已注册类型"。

### [轻微][存量] `TypeInfos` 残留注释掉的 `Types<T>` 缓存与"待支持"TODO

- **位置**：`f_base/src/TypeInfos.cj:24-27`（整段注释）、`:33-34`（`// Types<T>.INSTANCE` + `//待支持静态成员再改回使用Types`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §1（兼容残留/注释死代码）、§3（TODO 占位）
- **证据**：静态确定 —— 注释块内无有效代码，`Types<T>` 在本文件中不存在。
- **描述**：注释掉的类与"待支持静态成员"的 TODO 长期留在主路径文件里，读者难以判断"静态成员是否已支持"。`get<T>()` 当前每次调用都重新 `TypeInfo.of<T>()`（无缓存），与注释描述的意图相反。
- **建议**：删除注释块；若"给 `get<T>()` 加缓存"仍是待办，转成 issue 或在方法上留一行明确的 TODO（含原因与前置条件）。

## 优化可行性方案

> 以下均无改前/改后对照数据，只能作为下一轮补数据的目标，不进 `todo.md`/`tasks.md`。

### [堆内存] `StringGenerator.reverse()` 整串副本 + 每个 Rune 一个临时 String

- **现状**：`reverse()`（`StringGenerator.cj:250-259`）先 `toString()` 复制整段字节（`fromUtf8Unchecked` 内部 `clone`，已核 std 源码），再对每个 Rune 调 `rune.toString().unsafeBytes()` 分配一个 1–4 字节的临时 `String` + `Array`。缓冲区大小 n 字节、Rune 数 m 时，一次 reverse 的额外分配约为 `n + m×(16~40) B`（String 头 + 数组头为估算，需实测）。
- **方案**：不做 `toString()` 副本，直接在 `utf8` 缓冲区上从尾部向前扫描 UTF-8 首字节定位字符边界（`(b & 0xC0) != 0x80`），用固定的 4 字节栈上数组做中转倒排；等价于"原地按 Rune 反转"。
- **预期**：额外堆分配从 `O(n + m)` 降到 `O(1)`（不含结果缓冲本身）；峰值内存少一份与缓冲区同大的副本。
- **代价**：需要手写 UTF-8 边界判定（约 20 行），非法 UTF-8（由 `substring` 产生）时的行为需定义；实现复杂度上升。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 对 10KB/1MB 中文串跑 `cjpm bench -O2`，给中位数与 P95；并补 "ASCII/2/3/4 字节混合串 reverse 后再 reverse == 原串" 用例。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `TypeMemberInfos` 六个缓存各自遍历类链，可并为一次扫描

- **现状**：6 个 getter（`:23/:60/:97/:137/:177/:217`）在首次未命中时各自沿 `superClass` 链遍历一次、各建一个 `HashMap`、各建一个闭包；一个类型首次被反射时最多 6 次类链遍历 + 6 个容器 + 6 个闭包对象。缓存常驻（键为 `TypeInfo`，数量与进程内类型数同阶）。
- **方案**：用一个 `ConcurrentHashMap<TypeInfo, TypeMembers>`，`TypeMembers` 里放 6 个不可变视图（`HashMap` 建成后不再改），一次类链遍历同时填充 6 类成员；顺带修掉上面的并发发布与闭包捕获问题。
- **预期**：首次反射的类链遍历次数 6→1，闭包与中间对象减少 5/6；稳态内存不变（6 份 map 变 1 个 record 里的 6 份 map，条目数相同）。
- **代价**：`TypeInfo` 冷路径改造，需回归 `f_bean`/`f_data` 的属性查找行为；record 一次性构建变重（首 miss 延迟略升）。
- **验证**：`cjprof record` 跑 `f_bean` 启动 + `f_data` 序列化场景，看 `getStaticPropertyMap` 系自耗时；`getAllocatedHeapSize()` 对照。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 合并 `StringGenerator` 三处 replace 拼接体与 `remove` 的多次搬移

- **现状**：`replace`/`replaceFirst`/`replaceLast` 各写一遍 11 行的三分支拼接（`:178-188`、`:215-225`、`:235-245`）；`remove` 对每个命中区间调一次 `ArrayList.remove(range)`，m 个命中时搬移量为 `O(n·m)`，另外先收集 `ArrayList<Range>` 再做第二趟。
- **方案**：抽出私有 `spliceAt(idx: Int64, oldSize: Int64, newBytes: Array<Byte>)`；`remove` 改成单趟"读指针/写指针压紧"（O(n) 一趟完成，免去 `torm` 与 m 次搬移）。
- **预期**：`remove` 从 `O(n·m)` 降到 `O(n)`；三处拼接体合掉约 20 行重复代码，消除漂移风险（当前三处已经只差"取哪个下标"）。
- **代价**：需保证 `spliceAt` 对三分支（等长/变长/变短）逐字节等价，补等价性用例；压紧实现要处理 UTF-8 字节不变式（按字节压紧天然保持）。
- **验证**：`cjpm bench -O2`，输入为 10KB 文本 + 100 个命中位置，记录 remove 前后耗时中位数；同时跑现有 51 个使用方的 `cjpm test` 回归。
- **证据状态**：无基线（待验证，不进 tasks）；复杂度 O(n·m) 是静态事实，收益幅度待测

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `StringGenerator.append`/`indexOf` 在 SQL 拼接主路径占比高 | `f_base/src/StringGenerator.cj:45-52,104-110` | 自耗时占比、调用次数 | `cjprof record` 跑 f_orm 批量查询（1k/10k 条），看 `unsafeData`/`add(all:)` 的 self time |
| 2 | `remove` 的 `O(n·m)` 在真实文本上已可见 | `f_base/src/StringGenerator.cj:151-166` | 命中最多个数 m 的分布 | 埋点统计 m 与 n，或构造 100 命中用例跑 bench |
| 3 | `TypeInfos.get(name)` 冷 miss 时持锁做反射查找会串行化 | `f_base/src/TypeInfos.cj:41-51` | 锁等待时长、miss 频次 | 多线程（8 线程）反复查未注册名，`cjprof` + 线程状态（BLOCKED）采样 |
| 4 | `StringGenerator.reverse` 的分配对 GC 有可见影响 | `f_base/src/StringGenerator.cj:250-259` | `getAllocatedHeapSize()` 前后差、GC 次数 | 1MB 中文串 reverse 1e4 次，读分配量 + GC 统计 |

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性：`remove` 漏删、空串死循环、`checkIndex` 过严、`fromHex` 未校验、`transpose` 语义错、`TypeMemberInfos` 继承成员缺失；设计：`OverSizePolicy` 无反馈通道、`Result` 三个方法静默丢值、`PeekableIterator.isClosed` 契约不符；语言特性：`Result` 用运行时类型测试代替泛型约束、`Range` 负步长半开区间误用；安全性：`substring`/`unsafeUtf8` 的 unsafe 不变量未在注释中约束（均已在「发现」中列出，未涉及注入/凭据） |
| §1 死代码 | 0 | 逐个过了一遍：`private` 符号 `utf8`/`checkIndex`/`indexOf(Array)`/`lastIndexOf(Array)`/`INFOS`/`MUTEX`/`hex`/`hexmap`/`ResultFilter` 6 个字段/`ResultMapper` 5 个字段/TypeMemberInfos 6 个静态 map 与 6 个 getter，均在本文件内有调用者；`internal` 顶层 `FuncMeta`（`TypeMemberInfos.cj:257`）仅在本文件被 `staticFunction/instanceFunction` 使用，有调用者，且其 `public` 成员是 `Hashable`/`Equatable` 接口实现（豁免）；本部分无 `protected` 声明。对外可达的 public（`OverSize*`、`Result*`、`Peekable*`、`SingleIterable*`、`TypeInfos.*`、`TypeMemberInfos.*`、`@nameof`/`@nameValueOf`、`toHex/fromHex`、`WorkerStrategy`）一律不判死代码；其中 `ResultFilter`/`ResultMapper`/`TypeInfos.getGenericTypes|isInstanceOf|withAnnotation`/`SubTypeOf`/`@nameof`/`@nameValueOf` 在仓内零引用，仅作为"对外 API，仓内无引用"的信息记录 |
| §2 重复逻辑 | 3 | ① `TypeMemberInfos` 6 个 getter 逐行同构（只有成员种类与容器类型不同），已导致 3 处漂移（见「一般」第 1 条）；② `StringGenerator`：`reset`/`clear` 完全相同（`:35-38`/`:133-136`）、`replace`/`replaceFirst`/`replaceLast` 的 11 行拼接体逐行相同、`removeFirst`/`removeLast` 只差取下标调用；③ `Result`：`filterOk/filterErr/filterWithE/filterWithValue`（`:129-156`）同构，`isOk/isErr/isNoResult/withE/withValue`（`:25-66`）同构，`ResultFilter.filter`（`:238-286`）又把同一套判定重写一遍。`hex` 两函数、`Peekable.close/isClosed`、`OverSizePolicy` 各策略语义不同，不合并 |
| §3 空实现 | 2 | `DiscardOverSizePolicy.reject`（`:36`）与 `BlockingOverSizePolicy.reject` 的"未恢复"分支（`:67-69`）都是空行为：前者是有意的 Null Object 但没有任何注释说明"为什么可以空"（已列「轻微」），后者是静默丢弃（已列「一般」）。`Peekable.close` 的 `case _ => ()`、`TypeInfos.get<T>` 均非空实现，属正常分支 |
| §4 栈溢出 | 0 | 本部分 15 个文件无递归：`TypeMemberInfos` 的类链遍历是 `while` + `superClass`，深度由继承层数决定（不可自引用、无环）；`StringGenerator` 全部按下标/循环实现；`Result` 只有一层 `match`；`@nameof` 宏无递归展开。`TypeInfos` 历史上那处"自调用导致持锁无限递归"已在 `aba9a64f8` 修复，现状无递归 |
| §5 OOM | 1 | `remove` 空搜索串时 `torm` 无界增长（见「严重」第 1 条）。其余：`StringGenerator.utf8` 是无界缓冲区但属构建器语义（调用方决定上限）；`TypeInfos.INFOS` 与 `TypeMemberInfos` 6 个缓存无淘汰，但键集是"进程内已注册/已加载类型"，规模有界（`INFOS` 只在查找成功时写入），不构成 OOM 路径 |
| §6.1 热点瓶颈 | 0 | 本轮未提供 profile/bench 数据，任何"热点"结论都不成立；4 条疑似点已全部降级到「待验证假设」并注明采法 |
| §6.2 大粒度锁 | 1 | `TypeInfos.get(name)` 在 `Mutex` 内做 `TypeInfo.get(qualifiedName)`（全局反射注册表查找），且未命中不缓存 ⇒ 每次探测未注册名都要串行持锁一次（已列「轻微」）。`BlockingOverSizePolicy` 的锁只包 `condition.wait`，临界区很小，不算大粒度 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `get()`、无任务提交；`StringGenerator`/`ResultFilter`/`ResultMapper` 都是单线程构建器。唯一跨线程共享态是 `TypeInfos`/`TypeMemberInfos` 的静态缓存（已在 §12 处理） |
| §6.4 低效算法 | 1 | `StringGenerator.remove` 的 `O(n·m)`（m 次 `ArrayList.remove` + 先收集区间列表），已连同 `replace×3` 合并进「CPU」优化方案；另 `appendFromBytes` 每次新建 `Charset` 解码器（`StringGenerator.cj:101-103`），调用频次未知，未列为发现 |
| §7 降堆内存方案 | 2 | `reverse` 的整串副本 + 每 Rune 临时串；`TypeMemberInfos` 六套容器/闭包合并为一个 record（同时减少分配，与下一条 CPU 方案同源）。均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | ① `TypeMemberInfos` 类链遍历 6 次→1 次（与上一条同源）；② `remove` 降复杂度 + 三处 `replace` 拼接体合并（与 §6.4 同一方案，不重复计数） |
| §9 local mode 可行性 | 0 | `f_base/cjpm.toml` 已开 `--experimental --enable-local-mode`，但本部分函数里没有"函数内创建、函数内销毁的大对象"：`reverse`/`substring`/`toString` 的结果都会逃逸（返回值），`append` 的临时数组只有 4 字节。无峰值内存对照数据，不做改造建议 |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 15 个文件全部按快照记为存量：2 条「严重」+ 9 条「一般」（`remove` 漏删、`checkIndex`、`substring`、`fromHex`、`OverSizePolicy` 反馈缺失、`BlockingOverSizePolicy` 静默丢弃、`parseParameterTypes` 缺失、`Result` 三方法丢值、`TypeMemberInfos` 三处捕获），边界/空值/错误处理/契约均已逐方法核对（`Result` 12 个方法、`ResultFilter` 7 个、`ResultMapper` 6 个、`StringGenerator` 22 个、`TypeInfos` 5 个、`TypeMemberInfos` 12 个） |
| §12 并发安全与锁粒度 | 2 | ① `TypeMemberInfos` 先发布后填充 ⇒ 普通 `HashMap` 并发读写（「严重」，共享路径：静态 `ConcurrentHashMap` + 静态方法，任何线程可达）；② `BlockingOverSizePolicy` 的 `Condition.wait` 未在循环里重查谓词（「一般」）。`TypeInfos` 的双检锁（`ConcurrentHashMap` + `Mutex`）写法正确，未发现重复初始化或可见性问题；`StringGenerator`/`Result*`/`PeekableIterator` 为单线程构建器/迭代器，但均未在注释中声明非线程安全（并入「轻微」的契约说明缺失） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 9 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

> 存量缺陷共 23 条（含轻微），是否纳入修复待用户决定，本报告不代为拍板。

## 总评

本部分代码量不大（约 1.2k 行），风险集中在两个"老工具类"上：

1. **`StringGenerator`（268 行，51 个使用方）是影响面最大的严重风险点**：空搜索串导致的死循环 + 无界增长、倒序删除漏掉下标 0 的差一错误，都是"输入稍变就中招"的类型，且都以静默产出错误字符串或有去无回的形式表现。它同时是全仓 SQL 拼接的热路径工具，建议优先修这两条并补单元测试（目前只有一个 `append(Rune)` 的等价性用例）。
2. **`TypeMemberInfos` 的 6 个缓存是"复制粘贴 + 漂移"的典型样本**：3 个 getter 捕获错变量导致继承成员查不到，2 个 getter 先发布后填充造成数据竞争，根因都是同一段结构被抄了 6 遍。一次重构（单 record + 填完再发布）能同时消掉 1 条严重、1 条一般和 1 条重复逻辑。

`OverSizePolicy` 的可用性缺陷在于"没有反馈通道"：`reject` 返回 `Unit` + `add` 返回 `Unit`，丢弃元素时上层无从感知，这在队列类 API 上是隐患，建议连同接口签名一起演进（本项目允许破坏性变更）。

`Result`、`Peekable`、`SingleIterable`、`UnsafeBytes`/`UnsafeData`、`hex`、`WorkerStrategy`、`@nameof` 的质量总体可接受，问题多是契约未文档化（unsafe 的零拷贝/视图语义、`filter*` 的降级语义、`isClosed` 的自相矛盾）与 `mapError/flatten/transpose` 的静默丢值，属可排期项。`TypeInfos.getGenericTypes` 依赖一个仓内不存在的符号，需要先用一次构建确认到底是"缺实现"还是"缺文件"，这条可能是阻塞项。
