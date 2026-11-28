# f_base 模块审查报告

> **模块第 3/3 部分**（本报告只覆盖 `files/f_base.part3.txt` 列出的 14 个文件，全部为 `src/` 下的 `.cj`：`TypeInfos_test` → `zero_timer`。`README.md` / `README_en.md` 与其余 38 个 `.cj` 由第 1、2 部分产出；本部分编号独立，合并时以主 Agent 为准。README 只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（本部分 14 个 `.cj`，0 个 `.md`；模块共 52 `.cj` + 2 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：基础并发原语（`FutureTask` / 锁 / 原子量）的正确性与可见性、栈溢出、OOM、死代码、重复逻辑、存量 BUG（本部分实际内容为反射元数据缓存、信号/退出钩子、hex、零值哨兵等周边基础件；并发结论集中在 `TypeMemberInfos` 的静态缓存与 `ExitCallbacks` 的锁）
- **报告版本**：v1（第 3/3 部分）

## 发现

### [严重][存量] #1 `TypeMemberInfos` 把**尚未填充**的 `HashMap` 先发布进 `ConcurrentHashMap`：并发首次查表静默返回 `None`

- **位置**：`f_base/src/TypeMemberInfos.cj:28`（`staticPropertyMap[typeInfo] = map` 在第 `29-42` 行的填充**之前**）、`f_base/src/TypeMemberInfos.cj:102`（`staticFunctionMap[typeInfo] = map` 在第 `103-119` 行填充之前）；同文件对照：`79`、`159` 是"填完再发布"的正确顺序
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 发布逸出」、§11「并发正确性」
- **证据**：静态确定 —— `ConcurrentHashMap` 只保证单次操作线程安全、`get` 非阻塞（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:828`），被当作**值**存进去的 `HashMap` 本身不是并发容器（`collection_package_exception.md:14`："collection 包提供的容器类都不支持并发修改"）。执行顺序确定：线程 A 在 `28` 行 `put` 一个空 `HashMap` → 线程 B 在 `24` 行 `get` 命中同一个实例 → B 在 `56` 行 `map.get(name)` 得到 `None`（此时 A 还没执行 `29-42`），而 B 不会再去填充（`case Some(map) => map` 直接返回）。`getStaticFunctionMap`（`98-102`）同理。
- **描述**：反射元数据缓存是"首次查谁就谁填"的结构，填充窗口里任何并发调用方都会拿到**不完整视图**：`staticProperty` / `staticFunction` 对存在的成员返回 `None`，调用方据此走"没有该成员"分支（`f_bean/src/BeanFactory.cj:63` 判定 bean 是否有静态 `typeInfo`、`f_data` 的 `TypeInfos.functionHasAnnotation` 判定函数注解都在这个入口上）。另外 `staticProperties()` / `staticFunctions()`（`46-51`、`123-128`）把 `var` 表当前的 `values()` 直接交给调用方，若另一线程仍在 `29-42` 里 `map[p.name] = p`，就是"for-in 遍历容器途中被修改"（文档明确会抛 `ConcurrentModificationException`，`collection_package_exception.md:18`），属未定义行为而非"偶尔少一条"。
- **建议**：六处缓存统一改成"**局部填完再 `putIfAbsent` 发布**"（`79` / `159` 已是该写法，直接对齐）：`let map = HashMap...; fill(map); if (staticPropertyMap.addIfAbsent(typeInfo, map).isSome()) { 用已有值 } else { map }`；`addIfAbsent` 的返回值取"谁赢"，避免两个线程各自填充后互相覆盖。同时把 `values()` 的返回改成不可变快照（或文档写明"返回视图、不得并发读"，但更稳妥是发布后不再可变）。

### [严重][存量] #2 `@nameof` 展开引用了**不存在的宏** `@nameValue`：任何调用点都编译失败

- **位置**：`f_base/src/macros/nameof.cj:23-25`（`24` 行 `quote(@nameValue($input)[0])`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §14.1「承诺了但没实现 / 半成品」、§3「公开契约承诺有行为，实现不可用」
- **证据**：静态确定 —— 承诺源两处：本文件 `19-22` 的宏注释（"`@nameof(name)` 展开是 `'name'`"）与 `README.md:724`（把 `@nameof` 列为公开宏）；缺失证据：全仓 `*.cj`（`f_*` / `fdbm` / `fmq` / `fprobe` / `fleet` / `f_app`，排除 `.worktrees`）搜 `nameValue` 只有本文件这 3 处（`24` 的引用、`27-28` 的注释、`30` 的 `nameValueOf` 定义），宏包里没有任何名为 `nameValue` 的宏；语言文档（`cangjie_docs/**`）也搜不到该名字，不是编译器内置宏。此外即便存在这样一个宏，`[0]` 的下标形式对元组不成立，说明这是旧版实现的残留引用。
- **描述**：`@nameof` 是 `README.md` 承诺的公开能力（"宏包：`@nameof` / `@nameValueOf`"），但仓内**零使用**（全仓搜 `@nameof` 无命中），所以从未被编译器验证过；下游按 README 写 `@nameof(obj.field)` 会直接报"未声明的宏"，属"文档承诺、实现不可用"。同文件 `nameValueOf` 是可用的，说明只需把 `nameof` 展开式对齐即可。
- **建议**：`public macro nameof(input: Tokens): Tokens { quote($input) }` 不行（那会展开成表达式本身），应按注释语义取最后一个标识符：复用 `nameValueOf` 的 `last.kind == IDENTIFIER` 校验，然后 `quote('${identifier}')`（或 `quote(@nameValueOf($input)[0])`，前提是宏调用结果允许取下标）；同时补一条 `@Test` 用例，把"宏能展开"纳入编译期回归。

### [一般][存量] #3 `TypeMemberInfos` 父类遍历里循环变量写错：继承来的静态属性 / 实例变量永远查不到

- **位置**：`f_base/src/TypeMemberInfos.cj:29-33`（`30` 行 `for (p in typeInfo.staticProperties)`，应遍历参数 `ti`）、`f_base/src/TypeMemberInfos.cj:231-236`（`232` 行 `for (v in x.instanceVariables)`，应遍历 `c`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，两处同一提交）
- **判据**：review-checklist §11「逻辑错误 / 语义与命名不符」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 两处的同级实现都写对了，正好可以对照：
  - `getStaticPropertyMap` 的 `addProp(ti: TypeInfo)` 形参 `ti` 完全没用，循环体读的是外层 `typeInfo`（叶子类型）⇒ `addProp` 对每个祖先都做同一件事，**父类的 static property 一条也进不了表**；
  - `getInstancePropertyMap`（`65-69`）、`getStaticFunctionMap`（`103-110`）、`getInstanceFunctionMap`（`142-149`）都正确使用形参/`c`；
  - `getInstanceVariableMap`（`231-236`）外层已经在把 `cti` 沿 `c.superClass` 往上走，循环体却仍读 `x.instanceVariables` ⇒ 只有叶子类的实例变量进表，且被重复写入 `深度` 次。
- **描述**：`staticProperty(typeInfo, name)` 与 `instanceVariable(typeInfo, name)` 对**继承成员**恒返回 `None`。真实调用链有两条：`f_data/src/base/DataObject.cj:80/89`（`annotations` / `annotation` 在属性查不到时回退到 `instanceVariable`）与 `f_data/src/base/ReadableField.cj:52-60`（`tryGetAnnotation` → `MutableField.cj:25` 的 `@Validator`、`MutableField.cj:63` 的 `@DataConverter`）。也就是说**声明在父类上的 `var` 字段上的校验/转换注解会被静默丢弃**，数据校验与类型转换不执行，且没有日志。`ReadableField` 的查询结果还会进 `annotations.computeIfAbsent` 缓存，一旦按错误结果缓存，后续调用也不会自愈。
- **建议**：把 `30` 行改成 `for (p in ti.staticProperties)`、`232` 行改成 `for (v in c.instanceVariables)`；再补单测：`class Base { public var x: Int64 = 0 }`、`class Sub <: Base {}`，断言 `TypeMemberInfos.instanceVariable<Sub>("x").isSome()`、`staticProperty<Sub>("...").isSome()`（当前仓内**没有任何 `TypeMemberInfos_test.cj`**，见 #14，所以这类错误无从暴露）。

### [一般][存量] #4 `fromHex` 只校验上界：长度 0/1 抛越界，非十六进制字符抛 `NoneValueException`

- **位置**：`f_base/src/hex.cj:29-34`（`30` 行只判 `s.size > 2`，`33` 行直接取 `s[0]` / `s[1]` 并查 `hexmap`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「边界差一 / 空串未处理 / 错误处理缺失」
- **证据**：静态确定，依赖两条已现场核对的 std 语义：
  1. `String` 的 `[]` 是按下标取字节且有边界检查，`""` / `"a"` 取 `s[0]`、`s[1]` 直接抛 `IndexOutOfBoundsException`；
  2. `HashMap[]` 在键不存在时抛 `NoneValueException`（`collection_package_class.md:6160-6162`），而 `hexmap`（`19-25`）只装了 `'0'..'9'`、`'a'..'f'` 共 16 个键 ⇒ `"AB"` / `"g0"` / 多字节字符（`s.size` 是**字节数**，`'é'` 也被判成 2）全部走 `NoneValueException`，异常里没有任何"哪个字符非法"的信息。
- **描述**：函数契约只有一句"`s.size > 2` 抛 `IllegalArgumentException`"，实际还隐含"必须恰好 2 个字符且为小写十六进制"。仓内调用点只有 `fdbm/src/idmaker/IdMakers_test.cj:25`（固定 2 字符），所以是潜伏缺陷；一旦有人把它当通用 hex 解码器（`toHex` 的逆运算）用，空串/单字符/大写输入会得到与入参无关的异常类型。
- **建议**：入口统一为 `if (s.size != 2) throw IllegalArgumentException(s)`；字符校验用 `hexmap.contains`，非法字符抛带上下文的异常（如 `IllegalArgumentException("'${s}' is not a hex pair")`）；若需支持大写，初始化时把 `'A'..'F'` 也写进 `hexmap`。

### [一般][存量] #5 `ExitCallbacks.onExit` 在锁内 `for-in` 遍历回调表并执行回调：回调里再注册 `atExit` 直接抛 `ConcurrentModificationException`

- **位置**：`f_base/src/signal.cj:60-68`（`61` 行 `synchronized(mutex)`、`62-66` 双层 `for-in`），注册口 `48-59`
- **来源**：存量（`git blame`：`91978212cc 2026-09-01`，随 `f_app/src/signal.cj` 迁入）
- **判据**：review-checklist §12.1「迭代与修改并发 / 锁内调用外部回调」、§12.2「临界区内做不可控动作」
- **证据**：静态确定 —— `Mutex` 是可重入锁（`sync_package_classes.md:8927-8930`），所以回调里调 `atExit` **不会**被锁挡住，而是顺利进入 `49-58` 对 `callbacks`（`TreeMap`）/ 目标 `ArrayList` 做结构修改；而 `62-66` 正在 `for-in` 这两个容器，文档对该形态的结论是"遍历过程中修改容器时抛 `ConcurrentModificationException`"（`collection_package_exception.md:18`）。异常从信号处理函数里抛出 ⇒ 本轮剩余回调全部跳过，且 `exit(0)`（`44`）之前的状态已不可恢复。
- **描述**：`atExit` 是公开注册口（`README.md:731/742`，"回调按权重升序执行"），回调体是任意用户代码；"清理时顺手再注册一个收尾动作"是很自然的写法（例如关闭连接池后为新打开的临时文件注册删除）。当前实现把"遍历 + 执行"整体放在锁里，既拦不住同线程重入，又让其它线程的注册者一直阻塞到所有清理跑完（清理里有 join/close 时持锁时间不可控）。
- **建议**：快照后锁外执行：`let snapshot = synchronized(mutex) { callbacks.values().toArray() }`（或逐条 `removeFirst` 边取边执行），再在锁外依次 `atexit()`；这样既不会自修改遍历，也把外部回调移出临界区。补一条用例：两个回调，第一个在体内 `atExit(...)`，断言三个回调都执行且不抛异常。

### [一般][存量] #6 `toExitGracefully` 清掉别的模块注册的 SIGTERM/SIGINT，并在 handler 里 `exit(0)` 使后注册的 handler 永不执行

- **位置**：`f_base/src/signal.cj:39-47`（`41` 行 `resetSignalHandler(signals)`、`42-46` 注册处理器、`44` 行 `exit(0)`）
- **来源**：存量（`git blame`：`562abf068b 2026-09-01`）
- **判据**：review-checklist §12.1「死锁 / 异步语义」、§11「契约与实现不符」
- **证据**：静态确定（清空行为）+ 待确认（用户可见后果）—— 本文件 `23` 行 `public import` 的是 **std** 的同名函数，std 文档写明 `resetSignalHandler` 的功能是"清空注册的信号处理函数"（`runtime_package_funcs.md:587`），且 `registerSignalHandler` 的回调返回值 `false` 语义是"继续执行后续函数"（同文件 `507`）。于是两个方向都被切断：
  - 先于本函数注册的处理器被 `41` 行整体清空（`f_tui/src/render/Terminal.cj:57-58` 正是给 `SIGINT`/`SIGTERM` 各注册一个终端恢复处理器，`fprobe` 同时依赖 `f_tui` 与 `ExitCallbacks`，`fprobe/src/tui/SupervisorApp.cj:34` 走的就是本函数）；
  - 后于本函数注册的处理器即使存在，也永远轮不到：`44` 行 `exit(0)` 立即终止进程，FIFO 链上的下一个处理器没有机会执行——`46` 行 `false`（"继续后续"）在 `exit` 之后成为空话。
  `exit(0)` 是否触发 `std.env.atExit` 回调文档未明说（`env_package_funcs.md:53` 只说"立即终止当前进程"），所以"终端是否真被留在 raw 模式"记为待确认。
- **描述**：`README.md:728/736` 把"清除之前注册的这两个信号的处理函数"写成既有行为，但同一份文档在 `746-758` 又宣传 `registerSignalHandler` "不清空相同信号的其它处理函数"——同一个模块对外提供两套互斥语义，使用者无法既用 `ExitCallbacks` 又保留自己的信号处理。退出码固定 `0` 还会让上层（`fprobe` 这类监督进程）把"被 SIGTERM 杀掉"看成正常退出。
- **建议**：`toExitGracefully` 只注册自己的 handler、不再 `resetSignalHandler`（或在 README 明确"调用后 SIGTERM/SIGINT 归本模块独占，需自行在 `atExit` 里挂清理"）；`exit(0)` 改为 `exit(128 + signo)`（handler 已拿到 `Int32` 信号号，`registerSignalHandler(signals, handler: (Int32) -> Bool)` 重载现成），或用 `std.env.exit` 前显式 `atExit` 兜底并验证。

### [一般][存量] #7 `TypeMemberInfos` 六段缓存填充逻辑高度重复，已经漂移出三种不一致（含父类覆盖子类）

- **位置**：`f_base/src/TypeMemberInfos.cj:23-45`、`60-82`、`97-122`、`137-162`、`177-202`、`217-242`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 近似重复导致的行为漂移」
- **证据**：静态确定 —— 六段逐一比对"输入 → 输出 → 副作用"后，骨架相同（查 `ConcurrentHashMap` → 缺则建 `HashMap` → `ClassTypeInfo` 沿 `superClass` 走到 `Object` → 逐个成员写入 → 返回），差异只剩取值字段与三个**非语义必需**的漂移：
  1. 发布时机：`28` / `102` 先发布后填充，`79` / `159` / `186` / `197` / `226` / `237` 填充后发布（即 #1 的缺陷面）；
  2. 同名冲突策略：函数表用 `map.addIfAbsent(FuncMeta(...), f)`（`106`、`145`，子类先写入于是子类赢），属性/变量表用 `map[p.name] = p`（`31`、`67`、`184`、`193`、`224`、`233`，父类后写入于是**父类赢**）——同名属性被子类覆盖时，`instanceProperty` 会返回父类的 `PropertyInfo`；
  3. 结构分支：`177-202` / `217-242` 额外区分 `StructTypeInfo` 并对 `_` 返回 `EmptyMap`，前四段把 `_` 直接当非类处理（`40-42`、`76-78`、`117-119`、`156-158`），接口类型的静态/实例成员因此走 `addProp(typeInfo)` 而不是空表，语义不同却没有注释。
- **描述**：第 2 条与第 3 条是"重复实现各自演进"的典型后果：函数表与属性表对同名成员的取舍相反，调用方无法从 API 看出差异；接口类型在两族 API 上的行为也不一致。第 1 条已经造成 #1 的并发缺陷。
- **建议**：抽一个私有 `private func cachedIndex<K, V>(...)`（或 `private static func indexOfMembers(typeInfo, kind)`）统一"填充 → 发布 → 冲突策略"，冲突策略显式参数化（`childWins: Bool`），并在注释里写清为什么函数表要求子类优先、属性表也应当子类优先（同名 `prop` 被子类覆盖时显然应返回子类声明）。抽取不跨模块，落在本文件即可；改完用 #3 的单测覆盖"父类/子类同名成员"。

### [一般][存量] #8 `FuncMeta` 的 hash 由 `HashBuilder().append(param: Array<TypeInfo>)` 算出，而 `==` 按元素比较：可能整体破坏 `HashMap` 查找

- **位置**：`f_base/src/TypeMemberInfos.cj:257-268`（`260` 行算 hash、`263` 行 `param == other.param`）；`f_base/src/HashBuilder.cj:47-49`、`90-99`、`50-52` 的注释
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「哈希与相等契约」、`Hashable` 的 `hashCode` 必须与 `==` 一致
- **证据**：待确认（缺一条 SDK 语义证据）—— `HashBuilder` 对集合参数有运行时分支：`if (let x: Hashable <- args) { append(x.hashCode()); return this }`（`91-94`），即"数组实例若满足 `Hashable` 就按**身份**哈希"；`50-52` 的注释明确写了"`Array<T>`/`ArrayList<T>` 自身满足 `Hashable`，于是 `append<T>(arg: T) where T <: Hashable`（身份哈希）比 `append<T>(arg: Array<T>)` 更容易被选中"。而本文件 `263` 行的 `param == other.param` 走 `Array<T>` 的 `Equatable`（**按元素**比较，`core_package_structs.md:2014`）。若身份哈希成立，两条 `FuncMeta` 可以"相等但 hash 不同"⇒ `getStaticFunctionMap(...).get(FuncMeta(name, params))`（`133`、`173`）用调用方**新构造的数组**去查，哈希对不上，`staticFunction` / `instanceFunction` 恒返回 `None`。缺的证据是当前 SDK（1.3.0-alpha.20261112001016）里 `Array<T>` 是否真的实现 `Hashable`：本地 std 文档只列了 `Collection` / `Equatable` / `ToString`（`core_package_structs.md:1634-2852`），与 `HashBuilder.cj:50` 的注释矛盾，二者必有一个过期。
- **描述**：这是"哈希/相等契约"的潜在全面失效点，影响面很大：`TypeInfos.cj:74` 的 `instanceFunction(...)` 与 `f_data/src/base/DataObject.cj:166-168` 的 `staticFunction('tryParse', [TypeInfo.of<String>()])` 都靠这个查找，一旦 miss，前者让"函数注解"恒判定为无注解，后者让 `DataObject.tryParse` 直接 `getOrThrow()` 抛异常。若 Array 不满足 `Hashable`，则代码是对的（走 `append<T, I>(Iterable)` 的内容哈希），只剩注释过期。
- **建议**：先取证——写一个 5 行的 `@Test`：`let a = [TypeInfo.of<Int64>()]; let b = [TypeInfo.of<Int64>()]; @Assert(a.hashCode() == b.hashCode())`（或直接 `FuncMeta("f", a) == FuncMeta("f", b)` 且两者 `hashCode()` 相等）；若不等，把 `FuncMeta` 的 hash 改成显式内容哈希：`HashBuilder().append(name)` + `for (t in param) { hb.append(t.hashCode()) }`（顺序敏感，与 `==` 的数组逐元素比较一致），并订正 `HashBuilder.cj:50-52` 的注释。

### [轻微][存量] #9 `nextPowerOf2` 无上界：`n` 超过 2^62 时在 `x + 1` 溢出

- **位置**：`f_base/src/nextPowerOf2.cj:18-33`（`32` 行 `return x + 1`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「边界未校验」
- **证据**：静态确定 —— `n ∈ (2^62, 2^63)` 时 `26-31` 的或运算把 `x` 抬到 `0x7FFF_FFFF_FFFF_FFFF`，`+1` 越过 `Int64.Max`；仓颉整数运算默认检查溢出并抛 `OverflowException`（`core_package_exceptions.md:1096`），所以结果是"抛一个与入参无关的异常"而不是返回上界。`n <= 0` 分支把 `default!` 当**输入**再递归一次（`20`），若调用方传 `default: 0`，会再落到默认值 `128` 上，行为与"用我给的默认值"不一致。
- **描述**：仓内唯一调用点 `f_cache/src/ConcHashMap.cj` 传的是容量，实际不会接近 2^62，故只是边界缺陷；但函数是 `public` 且没有文档说明上界。
- **建议**：入口加 `if (n > (1 << 62)) { throw IllegalArgumentException("n too large: ${n}") }`（或返回 `Int64.Max` 并在注释写清）；`n <= 0` 分支显式用 `nextPowerOf2(default, default: 128)` 或直接 `if (default <= 0) { 128 } else { nextPowerOf2(default) }`。

### [轻微][存量] #10 `ResourceManager.call` 重复实现 `resource()`，且不校验 `isClosed()`：第二次 `call` 静默使用已关闭资源

- **位置**：`f_base/src/resource.cj:31-38`（`try/finally` + `res.close()`）对照 `18-24`（同名语义的顶级函数）；`26` 的 `resource` 字段在 `call` 后不清空
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「跨函数复制」、§11「资源释放不对称 / 契约」
- **证据**：静态确定 —— `call` 的函数体 = `resource(res, fn)` 的函数体（`try { fn(res) } finally { res.close() }`）多一层 `getOrThrow()`；`Resource` 接口自带 `isClosed()`（`core_package_interfaces.md:1343-1350`）但这里没用。`README.md:388-390` 已经把这个行为写成契约（"第二次 `call` 会拿到已关闭的资源"），等于把缺陷文档化。仓内两处调用（`f_llm/src/tool/FileReadingFunction.cj:152`、`f_llm/src/tool/FileReplacingFunction.cj:77`）都是"就地新建、只 `call` 一次"，没有触发。
- **描述**：结构体对外宣称"管理资源生命周期"，却在第二次调用时把已关闭对象再交给 `fn`；`fn` 内部对已关闭 `File` 的操作行为取决于 std 实现，属静默错误而非显式失败。
- **建议**：`call` 开头 `if (res.isClosed()) { throw IllegalStateException("resource already closed") }`（或首次 `call` 后 `resource = None`，让 `getOrThrow()` 抛 `NoneValueException`）；实现上直接委托 `resource(res, fn)` 消除重复，再在 README 删掉"已知缺陷"式说明。

### [轻微][存量] #11 `WorkerStrategy` 三处注释是复制粘贴的错文案，且 `New` 的语义在其唯一消费方未实现

- **位置**：`f_base/src/WorkerStrategy.cj:42-49`（`DiscardCurrentAfter` / `DiscardOldestDuring` 的注释都写"等待 Duration，然后抛出 JobQueueFullException"）、`50-58`（`New`："创建新实例…如果是任务队列就创建新线程"）；消费方 `f_concurrent/src/eventbus/EventBus.cj:94-105`（`103` 行 `case CurrentThread | New => currentThreadStrategy`）、`193-195`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「字面量复制（同一段文案散落多处）」、§14.1「枚举新 case 没有分支 / 只做了一半的分支」
- **证据**：静态确定 —— 前两条只是注释错：消费方 `EventBus.cj:100-101` 分别调 `discardCurrentAfterStrategy` / `discardOldestDuringStrategy`，即"等待后丢弃"，与名字一致、与注释相反。`New` 则是承诺与实现不符：注释承诺"创建新实例 / 新线程"，`EventBus.cj:103` 把它和 `CurrentThread` 归到同一分支，`currentThreadStrategy`（`193-195`）就是 `arrange(id, e, true)` 在当前线程投递。
- **描述**：`WorkerStrategy` 是 `public enum`，被 `EventBus` 的 `fullJobQueueStrategy!` 参数直接暴露给使用者（默认 `Block`）；调用方按注释选 `New` 会得到"在调用线程执行"，直接违背"不阻塞调用线程"的预期。
- **建议**：改正 42-48 的两段注释（"等待 Duration，超时后丢弃"）；`New` 要么在 `EventBus` 里实现真正的"新建工作者/线程"分支，要么从枚举里删掉（对外 API 变更需拍板），退一步至少在枚举注释标注"当前 EventBus 实现等同 CurrentThread"。

### [轻微][存量] #12 `signal.cj` 三个注册函数各自重写一遍"遍历 signals"循环

- **位置**：`f_base/src/signal.cj:77-79` / `81-85`（`82-84` 的循环）、`91-95` / `97-102`（`99-101` 又写一遍同样的循环）
- **来源**：存量（`git blame`：`562abf068b 2026-09-01`）
- **判据**：review-checklist §2「换控制流 / 逐行对齐」
- **证据**：静态确定 —— `resetAndRegisterSignalHandler(signals, handler: (Int32) -> Bool)` 的 `97-102` = `resetSignalHandler(signals)` + `registerSignalHandler` 的 `81-85`；`(signals, () -> Bool)` 版与 `(signal, () -> Bool)` 版也只是把 `{_ => handler()}` 包一层。三对重载共 4 处相同循环/包装。
- **描述**：重复本身成本低，但"重置后注册"的口径以后要调整（例如只重置自己注册过的信号，见 #6）就要改两处，容易只改一处。
- **建议**：`resetAndRegisterSignalHandler(signals, handler: (Int32) -> Bool)` 改为 `resetSignalHandler(signals); registerSignalHandler(signals, handler)`；`(signals, () -> Bool)` 版同理委托 `(signal, ...)` 版。

### [轻微][存量] #13 `@nameValueOf` 的错误文案写成 `nameof`，`@nameof` 自身没有空入参校验

- **位置**：`f_base/src/macros/nameof.cj:32`、`39`（"macro nameof do not accept empty input" 等文案与所在宏 `nameValueOf` 不符）；`23-25`（`nameof` 无 `input.size == 0` 检查，直接 `$input` + `[0]`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10「可读性 / 错误信息准确」、§11「语义与命名不符」
- **证据**：静态确定 —— 两条 `diagReport` 的文案都以 `macro nameof` 自称，实际所在宏是 `nameValueOf`（`30`）；`nameof` 展开路径上没有空 `Tokens` 检查。
- **描述**：宏报错是使用者唯一能看到的诊断信息，指向错误的宏名会把排查方向带偏；`@nameof()` 这种空入参在 `nameof` 里没有前置校验（对比 `nameValueOf` 的 `31-34`）。
- **建议**：文案改为 `macro nameValueOf ...`；`nameof` 补同样的空入参检查（顺便按 #2 一起修）。

### [轻微][存量] #14 `TypeMemberInfos` 没有任何单测，两个循环变量 bug 因此长期潜伏

- **位置**：`f_base/src/TypeMemberInfos.cj`（全文件）；对照 `f_base/src/TypeInfos_test.cj:27-38`（本模块唯一的反射测试，只覆盖 `TypeInfos.get(qualifiedName)` 的两条路径）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」、§11（缺陷可发现性）
- **证据**：静态确定 —— `f_base/src` 下不存在 `TypeMemberInfos_test.cj`（目录列举/全仓搜 `TypeMemberInfos_test` 均无），而 `TypeMemberInfos` 有 12 个 `public static` 入口、6 张缓存，被 `f_bean` / `f_data` 依赖。
- **描述**：#3 的两处 copy-paste 错误、#1 的发布顺序错误都属于"写一个 10 行用例就能发现"的类型，缺少用例是它们能长期存在的直接原因。
- **建议**：新增 `TypeMemberInfos_test.cj`，至少覆盖：父类 `var` 字段的 `instanceVariable` 查询（#3）、父类静态属性（#3）、同名成员父子优先级（#7）、`FuncMeta` 的 hash/相等一致（#8）。

## 优化可行性方案

> 本部分没有 `cjprof` / `cjpm bench` 基线，三条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [CPU] `toHex` 每个字节做一次双 `Rune` 字符串插值

- **现状**：`f_base/src/hex.cj:26-28` 每调用一次分配 1 个 `String` 并做 2 次 `hex[...]` 数组下标 + 2 次 `Rune` 转字符串；调用方把字节渲染成文本时是**逐字节**调用（`fdbm/src/sql/SqlRenderer.cj:19`、`f_dbd/src/driver/DbdUrl.cj:20` 都 `import fountain::f_base.toHex`）。
- **方案**：静态初始化一张 `Array<String>(256) { i => ... }` 的两位小写表，`toHex(b)` 直接 `HEX_TABLE[Int64(b)]` 返回（返回的 `String` 不可变、可安全共享）；`fromHex` 同步用 256 项 `Array<Byte>`（非法位置填 0xFF）替掉 `HashMap` 查表。
- **预期**：单次调用从"1 次分配 + 2 次 boxed 下标 + 插值"降到"1 次数组读、0 分配"；端到端收益取决于 `toHex` 在 SQL 渲染里的调用次数（**未测**）。
- **代价**：多 256×2 个常驻对象（约几 KB）；`fromHex` 的非法字符判断从"抛 `NoneValueException`"变成显式分支（与 #4 的修法合并做最省事）。
- **验证**：`cjpm bench -O2` 对比 1e6 次 `toHex(Byte)` 的中位耗时与 `getAllocatedHeapSize()` 增量；再在 `fdbm` 的 SQL 渲染路径上跑分段计时，确认 `toHex` 是否进入前 10。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TypeMemberInfos` 每次父类遍历都重新取一次 `ClassTypeInfo.of<Object>()`

- **现状**：`f_base/src/TypeMemberInfos.cj:36`、`72`、`113`、`152`、`191`、`231` 六处 `while` 条件里各调用一次 `ClassTypeInfo.of<Object>()`；每次反射查表 + 比较在"每个类型首次填充"时执行一次，深度为类继承层数。
- **方案**：提取 `private static let OBJECT_CLASS_INFO = ClassTypeInfo.of<Object>()`（或 `TypeInfo.of<Object>()`）到类级常量，循环条件改用它。
- **预期**：把每次填充的反射调用从 `O(深度)` 降到 1；绝对收益是微秒级，只有类型数很多（数百个 `@DataAssist` 类型）且填充集中在启动期时才可能可见（**未测**）。
- **代价**：一个常驻引用（`TypeInfo` 本身就常驻，无额外内存）；无行为变化。
- **验证**：`cjpm test` 跑 `f_data` / `f_orm` 冷启动，分段计时"反射元数据首次填充"总耗时；`cjprof` 看 `ClassTypeInfo.of` 的调用次数与自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `TypeMemberInfos` 为每个类型常驻 6 张 `HashMap`

- **现状**：`f_base/src/TypeMemberInfos.cj:22`、`59`、`96`、`136`、`176`、`216` 各一张 `ConcurrentHashMap<TypeInfo, HashMap<...>>`；一个被反射过的类型最多产生 6 个内层 `HashMap` + 6 个外层条目（外加键的 `TypeInfo` 引用）。条目数 = 该类型的静态/实例属性、函数、变量数量之和。
- **方案**：合并为 `HashMap<TypeInfo, MemberIndex>`，`MemberIndex` 内放 6 张（或 4 张，函数/变量/属性按需延迟建）表；或把 6 张顶层表换成一张 `ConcurrentHashMap<(TypeInfo, MemberKind), ...>`。关键是"每个类型一个索引对象"，与 #7 的抽取一起做。
- **预期**：每类型常驻对象数从 6 降到 1–2，外层表条目从 6 降到 1；收益与"被反射类型数 × 成员数"成正比（**未测**，类型数在 `f_orm` / `f_data` 全量启动时可能上百）。
- **代价**：需要一次结构性重构（6 组 API 共用索引），并发发布策略必须同时按 #1 修正；`MemberIndex` 变大后单类型的内存占用不变，只是少了容器壳。
- **验证**：对 `f_orm` + `f_data` 全量类型跑一次初始化，输出 `getAllocatedHeapSize()` 前后差与 `TypeMemberInfos` 内层 `HashMap` 计数（临时加计数埋点）；RSS 对照 `mem §1.2` 的有界稳态判定。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `toHex` 在 SQL / URL 渲染热路径上逐字节调用，字符串插值成为可观开销 | `f_base/src/hex.cj:26-28`（调用方 `fdbm/src/sql/SqlRenderer.cj`、`f_dbd/src/driver/DbdUrl.cj`） | 调用次数、单次耗时、占总渲染时间比例 | 在 `toHex` 入口加 `AtomicInt64` 计数，跑一次带大 `WHERE IN` 的查询；`cjprof record` 看 `hex.toHex` 自耗时占比是否 >5% |
| 2 | `TypeMemberInfos` 的首次填充在启动期被多线程同时触发（#1 的窗口是否真的被踩到） | `f_base/src/TypeMemberInfos.cj:28`、`102` | 并发填充次数、命中半填表的次数 | 在 `28`/`102` 后与 `43`/`120` 后各加计数，`fboot` 启动跑 100 次，统计"发布后仍有并发读"的比例；或直接构造 8 线程同时查同一类型做压力用例 |
| 3 | 六张反射缓存的总常驻内存占 `f_base` 堆的显著比例 | `f_base/src/TypeMemberInfos.cj:22-242` | 类型数、每张表条目数、字节量 | 加计数导出"类型数 × (属性+函数+变量) 条数"，配合 `cjprof heap` 看 `HashMap` 实例数与占用 |
| 4 | `onExit` 的清理回调持锁时间较长，导致退出时 `atExit` 注册线程长时间阻塞 | `f_base/src/signal.cj:61-67`（回调体如 `fdbm/src/server/FdbmServer.cj:167` 的 `stop()`） | 单个回调耗时、退出阶段阻塞线程数 | 在 `62-66` 前后打点计时，记录每个回调耗时；杀进程时采样线程状态（BLOCKED 占比） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/src/TypeInfos_test.cj` | .cj | ✅ | `@Test` 类两条用例（按限定名查 `TypeInfos`、未注册类型抛 `InfoNotFoundException`）与 `TypeInfos.cj` 注释里的 X-1 回归对应；无缺陷，另见 #14（反射面测试覆盖不足） |
| 2 | `f_base/src/TypeMemberInfos.cj` | .cj | ✅ | 见 #1（先发布后填充）、#3（两处循环变量）、#7（六段重复 + 漂移）、#8（`FuncMeta` 哈希）、#14（无单测）；优化方案 2、3 |
| 3 | `f_base/src/UnsafeBytes.cj` | .cj | ✅ | `String.rawData()` / `withRawData()` 的 unsafe 封装，属刻意零拷贝的对外 API（`StringGenerator.unsafeBytes`、`FleetStore`、`MultipartFormDataParser` 在用）；契约未文档化已在覆盖面记录，不计缺陷 |
| 4 | `f_base/src/UnsafeData.cj` | .cj | ✅ | `ArrayList.getRawArray()[0..size]` 切片；`StringGenerator`（19 处）、`f_orm/TableMeta` 在用；无边界问题（空表得到空数组） |
| 5 | `f_base/src/WorkerStrategy.cj` | .cj | ✅ | 见 #11（注释复制错误 + `New` 未实现）；其余 8 个变体在 `EventBus` 均有分支（`CurrentThread` 与 `New` 合并到同一策略函数） |
| 6 | `f_base/src/hex.cj` | .cj | ✅ | 见 #4（`fromHex` 边界与字符校验）；`hex` / `hexmap` 两个 private 全局均为初始化后只读，无并发写；优化方案 1 |
| 7 | `f_base/src/macros/nameof.cj` | .cj | ✅ | 见 #2（`@nameof` 引用不存在的 `@nameValue`）、#13（文案与空入参校验）；`@nameValueOf` 的 `DOT`/`IDENTIFIER` 判定与 `quote(($identifier, $input))` 组合正确 |
| 8 | `f_base/src/native.cj` | .cj | ✅ | `memcpy` / `getpagesize` 按平台条件声明，`MEM_PAGE_SIZE` / `nullptr` / `mcopy` 均有仓内使用（`f_io/MMapFile`、`f_io/SegmentedLog`、`f_uring/IOUringStream`）；无缺陷（`mcopy` 不处理重叠区间与 `memcpy` 语义一致，调用方均不重叠） |
| 9 | `f_base/src/nextPowerOf2.cj` | .cj | ✅ | 见 #9（`n > 2^62` 溢出）；`n <= 0` 回退默认值的主路径正确 |
| 10 | `f_base/src/public_std_imports.cj` | .cj | ✅ | 5 个 `public import`，是 `f_base` 对外重导出契约（`README.md:706`）；同包 `hex.cj` / `resource.cj` 依赖它取 `HashMap` / 依赖 core 的 `Resource`，属既有工程约定 |
| 11 | `f_base/src/resource.cj` | .cj | ✅ | 见 #10（`ResourceManager` 与顶级 `resource` 重复 + 不校验 `isClosed`）；`resource()` 的 `try/finally` 正确，`f_llm` 多处复用 |
| 12 | `f_base/src/signal.cj` | .cj | ✅ | 见 #5（锁内遍历回调）、#6（清空他人 handler + `exit(0)`）、#12（注册循环重复）；Windows 空实现为条件编译所需（`@When` 分支穷尽：3 类 `registerSignalHandler` + 3 类 `resetAndRegisterSignalHandler` + `resetSignalHandler` + `Signal` + `SignalHandlerFunc`），`SIGIOT` / `SIGSEGV` 与 `f_pool/PoolDiagnostics.cj:45` 配合使用，`MapEntryView.value` 对缺失键会自动插入（`collection_package_interface.md:468-470`，`atExit` 的 `entryView` 用法正确） |
| 13 | `f_base/src/unsafeZeroValue.cj` | .cj | ✅ | `unsafe { zeroValue<T>() }` 直通，无逻辑；对外 API 被 `f_rpc` / `fmq` / `zero_timer.cj` 使用 |
| 14 | `f_base/src/zero_timer.cj` | .cj | ✅ | 见「范围外提示」：`ZERO_TIMER` 是零值（无 native handle）`Timer` 哨兵，`README.md:501-507` 只给签名不给约束；无并发/边界逻辑 |

合计：`.cj` 14 个 / `.md` 0 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #3 / #4 / #8 / #9；设计 #1（缓存发布顺序）/ #7（重复实现漂移）/ #10（职责与契约）/ #11（枚举语义）；可读性 #13；语言特性：#8（`Hashable` 与 `==` 的契约）、#3（`@OverflowWrapping` 未用于 hex/位移无关）。安全性：本部分无 SQL / HTML / 路径拼接、无凭据、无外部输入进缓冲区（`fromHex` 的非法输入只会抛异常，已在 #4 报），未命中 |
| §1 死代码 | 0 | 逐个 `private`（全仓搜）/ 默认 `internal`（本包及子包搜）/ `protected`（本 module 内搜）过一遍，全部有引用：`TypeMemberInfos` 的 12 个私有成员与 6 张表都被本文件的 12 个 `public static` 用到；`hex.hex`/`hexmap` 被 `toHex`/`fromHex` 用；`native.memcpy`/`getpagesize` 被 `mcopy`/`MEM_PAGE_SIZE` 用；`ResourceManager.resource` 被 `call` 用。`class FuncMeta`（包内可见）及其 `==`/`hashCode` 是接口实现，按误报边界不判。对外可达的 `public`（`TypeMemberInfos` 全部静态入口、`UnsafeBytes`/`UnsafeData` 及其 extend、`WorkerStrategy`、`toHex`/`fromHex`、`@nameof`/`@nameValueOf`、`MEM_PAGE_SIZE`/`nullptr`/`mcopy`、`nextPowerOf2`、`resource`/`ResourceManager`、`ExitCallbacks`/`registerSignalHandler` 族/`SIGIOT`/`SIGSEGV`、`unsafeZeroValue`、`ZERO_TIMER`、5 个 `public import`）一律不判；仓内零引用者已在覆盖面逐条记为"对外 API"（`resetAndRegisterSignalHandler` 的 6 个重载、`@nameof`/`@nameValueOf` 在仓内零使用，但都是对外契约）。无不可达语句、无恒真恒假分支、无未使用 import（`TypeInfos_test` 的 3 个 import、`signal.cj` 的 4 个 import、`UnsafeData` 的 `ArrayList` 均有用） |
| §2 重复逻辑 | 3 | 同文件两两比对：`TypeMemberInfos` 六段缓存填充（#7，已漂移出 3 种不一致）、`signal.cj` 的注册循环（#12）、`resource.cj` 的 `call` vs `resource`（#10）。另核对了 `WorkerStrategy` 三段复制文档注释（并入 #11）、`toHex`/`fromHex`（互逆运算，不是重复）、`TypeMemberInfos` 的 12 对 `xxx<T>()` / `xxx(typeInfo)` 重载（只是转调，属预期 API 形态，不判） |
| §3 空实现 | 2 | 命中的是"公开契约无实现"：#2（`@nameof` 展开成不存在的宏，等于不可用）、#11 的 `New` 分支（注释承诺新线程，实现是当前线程）。`signal.cj` 的 Windows 空实现（`70-74`、`109-137`）是条件编译桩、`README.md:747` 已声明"仅 Windows 空实现"，不判；`UnsafeBytes`/`UnsafeData` 接口无默认空体 |
| §4 栈溢出 | 0 | 递归只有 `nextPowerOf2` 的一层自递归（`20`，`default!` 固定 128 时深度恒为 1，异常输入已在 #9 报）；`TypeMemberInfos` 的父类遍历是 `while` 不是递归；`@nameof`/`@nameValueOf` 是编译期宏、无递归展开；无自引用结构打印、无深度拷贝 |
| §5 OOM | 0 | 逐项核对：`TypeMemberInfos` 6 张缓存以 `TypeInfo` 为键，进程内类型集合有界（无按请求 ID 建键）；`hexmap` 固定 16 项；`ExitCallbacks.callbacks` 只随启动期 `atExit` 注册增长（无按请求注册的调用点，`f_app`/`fdbm`/`fmq`/`fprobe` 各 1 处）；`fromHex`/`toHex` 无物化；无"按不可信长度预分配"（未出现 `Array(n, repeat:)`） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，4 条疑似热点全部进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 1 | #5（`onExit` 在 `mutex` 内执行全部用户回调，含 `stop()` / `close()` 这类可能 join 的动作）——但退出路径上不影响吞吐，故只按"锁内跑外部回调"记一般，收益/耗时数据进假设 4 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 Future/线程池、无"逐条 get"；`ExitCallbacks` 的回调本就是串行退出语义 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains` 热点、无 `remove(at: 0)`、无循环内字符串 `+`（`toHex` 的插值是单次两字符，已进优化方案 1）；`TypeMemberInfos` 的 `while` 是 O(继承深度)，深度由类层次决定且只在首次填充 |
| §7 降堆内存方案 | 1 | 优化方案 3（6 张表合并为每类型一个索引），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 1（`toHex` 256 项表）、2（`ClassTypeInfo.of<Object>()` 提出循环），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无合格候选：`TypeMemberInfos` 构造的 `HashMap` 是**缓存值**，必须逃逸出函数（存进静态表），逃逸检查直接不通过；`toHex`/`fromHex` 的临时对象是 1 个 `String` / 2 次查表，峰值内存可忽略；`resource`/`signal`/`nextPowerOf2` 无函数内大临时对象。也没有 `getAllocatedLocalObjectSize()` 前后的峰值对照数据 |
| §11 现有代码的 BUG（存量） | 14 | 全部 14 条均为存量（快照无 diff，`git blame` 落在 `4be871f2fd 2026-10-02` / `562abf068b 2026-09-01` / `91978212cc 2026-09-01`）。另逐项核对了本轮读到的边界与空值：`TypeMemberInfos` 的 `xxx(typeInfo)` 重载不校验 `typeInfo` 合法性但签名要求非空；`ExitCallbacks.atExit` 的 `entryView` 对缺失键写入会新增（文档 `collection_package_interface.md:468-470` 已核）；`MapEntryView` 在容器被改后会失效（`collection_package_exception.md:19`）——本文件只在锁内立即使用，成立；`native.mcopy` 的 `n` 由调用方保证；`unsafeZeroValue` 直通 |
| §12 并发安全与锁粒度 | 3 | 并发安全 #1（发布半填容器 + 非线程安全 `HashMap` 跨线程读写）、#5（锁内用户回调 + 自修改遍历）、#6（`resetSignalHandler` 清空他人注册 + `exit(0)` 抢占）。已核对的同步手段：`hex`/`hexmap` 是"初始化后只读"的全局 `let`（无写路径）；`ExitCallbacks.callbacks` 的全部读写都在 `mutex` 内（`49-58`、`61-67`）；`TypeMemberInfos` 的 6 张表本身是 `ConcurrentHashMap`、单次 `get`/`put` 原子（`collection_concurrent_class.md:828`）——缺口只在"值对象发布时机"。锁粒度：#5 的临界区含全部回调执行，建议快照后锁外跑 |
| §14 功能完备性与 README 覆盖 | 3 | #2（README `724` 承诺的 `@nameof` 不可用）、#11（`New` 变体语义未实现）、#10（`ResourceManager` 的行为缺陷被写进 README `388-390` 当契约）。其余本部分 `public` 符号已在 README 登记：`TypeMemberInfos`（`789`）、`UnsafeBytes`/`UnsafeData`（`474-491`）、`unsafeZeroValue`/`ZERO_TIMER`（`497`/`506`）、`resource`/`ResourceManager`（`376-395`）、`ExitCallbacks`（`727-744`）、`registerSignalHandler` 族（`746-758`）、`SIGIOT`/`SIGSEGV`/`nextPowerOf2`/`toHex`/`fromHex`/`MEM_PAGE_SIZE`/`nullptr`/`mcopy`/`WorkerStrategy`/`@nameof`/`@nameValueOf`（`721-724`）；`resetAndRegisterSignalHandler` 仓内零调用但已在 README 声明，属对外 API |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；本部分无 `.md`（README 仅作取证判据引用，其正文审查属第 1 部分）。§13 文档一致性按"README 与源码的交叉引用"抽查了 8 处（`376-395`、`474-507`、`704-724`、`727-758`），除 #10 的"把缺陷写成契约"外均一致 |

**范围外提示**（不计入统计）：`zero_timer.cj` 提供的 `ZERO_TIMER` 是零值 `Timer`（无 native handle），`README.md:501-507` 只给签名、未说明"不可对其调用任何方法"；已有调用方按哨兵写法踩到——`f_ticktock/src/Chrono.cj:22` 以 `ZERO_TIMER` 初始化、`47` 行 `shutdown()` 直接 `timer.cancel()`，若 `shutdown` 早于 `start` 就是对零值对象调方法。建议在 `f_base` 侧把该约束写进 README（或改成 `?Timer` 让编译器强制判空）。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分是 `f_base` 的"周边基础件"层：反射成员缓存（`TypeMemberInfos`）、信号/退出钩子（`signal`）、hex 转换、零值哨兵、资源管理糖、平台原生封装。单个文件都很短（最长 268 行），没有 Future/锁/原子量的自研实现，所以并发面很小——但正因为小，两处**会咬人**的地方格外突出：

- 阻塞项：#1 `TypeMemberInfos` 先把空 `HashMap` 挂进 `ConcurrentHashMap` 再填充，同一类型首次被并发查询时，另一个线程会拿到"成员不全"的映射并据此判定"没有这个成员"，且没有任何日志；`values()` 视图还会把"遍历中被修改"这个未定义行为暴露给调用方。修法只是把 `28`/`102` 的发布挪到填充之后（`79`/`159` 已是正确写法），成本极低。
- 阻塞项（契约面）：#2 `@nameof` 的展开引用了并不存在的 `@nameValue`，README 把它当公开能力宣传，实际任何调用点都编译不过。这条之所以零发现，是因为仓内零调用——与 #14「反射面没有单测」是同一个根因：**没有用例的对外承诺会腐烂**。
- 语义陷阱：#3 两处父类遍历写错循环变量（`30` 用 `typeInfo`、`232` 用 `x`），让"继承来的静态属性 / 实例变量"永远查不到，进而让 `f_data` 的校验/转换注解在父类字段上静默失效；#4 `fromHex` 只挡上界，空串/单字符/大写直接抛 `IndexOutOfBoundsException` / `NoneValueException`；#6 退出钩子会清掉别人的 SIGTERM/SIGINT 并用 `exit(0)` 抢在后续 handler 之前终止进程（`f_tui` 的终端恢复正好是这类注册方）；#8 `FuncMeta` 的哈希与相等可能不一致（`HashBuilder` 对集合走身份哈希），一旦成立，`staticFunction` / `instanceFunction` 全部 miss——这条必须先用一条 3 行用例定死。
- 可维护性：#7 六段几乎一样的缓存填充已经漂移出"发布顺序、同名冲突策略、结构分支"三种不一致，其中"父类覆盖子类"与函数表的 `addIfAbsent`（子类优先）正好相反；#10 / #11 / #12 / #13 是"缺陷被写进文档"与"复制粘贴文案"这两类典型债务，修起来都很轻。
- 性能与内存：本部分没有任何改前/改后数据，3 条优化方案与 4 条假设都不进修复清单。下一轮最值得补的是"`toHex` 在 SQL 渲染里的占比"（假设 1）与"反射缓存常驻内存"（假设 3），它们决定要不要动 `hex` 的查表与 `TypeMemberInfos` 的表结构。
- 已确认**没有**的问题：`hex`/`hexmap` 两个全局表的只读性、`signal.cj` 的 `@When` 分支穷尽（非 Windows 三对重载 + Windows 六桩 + `Signal`/`SignalHandlerFunc` 兜底）、`atExit` 的 `MapEntryView` 写入语义（文档已核会自动插入）、`UnsafeBytes`/`UnsafeData`/`unsafeZeroValue`/`native` 的封装正确性、`resource()` 的 `try/finally` 对称性。
