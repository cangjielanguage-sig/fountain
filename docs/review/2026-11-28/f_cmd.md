# f_cmd 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_cmd`（2 个源文件，另有 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端分支；`git blame` 显示两文件当前行均来自 `4be871f2f` 2026-10-02，全部记为存量）
- **审查重点**：正确性、死代码、重复逻辑、空实现、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

> 编号索引：#1 `getArg` 恒返回 `None` ／ #2 位置参数抛 `NoneValueException` ／ #3 `commandPath` 未处理异常 ／ #4 `getArgs` 泄漏内部容器 ／ #5 两套 argv 解析 ／ #6 `CmdException` 从不抛出 ／ #7 重复项语义不一致 ／ #8 字段与访问器风格 ／ #9 README 命名实参示例。

### [严重][存量] #1 `getArg` 丢弃 `Option` 结果，恒返回 `None`；`getArgValue` 连带恒为 `None`

- **位置**：`f_cmd/src/CmdArgs.cj:74`（`if` 分支 75–77，落到 78 的 `None<String>`）；连带 `f_cmd/src/CmdArgs.cj:93`
- **来源**：存量（`git blame -L 74,79` → `4be871f2f`，2026-10-02；快照模式无 diff 基线）
- **判据**：review-checklist §11（契约与实现不符）+ §10（`Option` 被静默丢弃）
- **证据**：静态确定 —— 语言文档明确"`if` 无 `else` 时类型始终为 `Unit`"（`language.basic_concepts.3-表达式.3-2-if-条件判断`），因此 `list.get(0)` 的 `Option<String>` 作为语句值被丢弃，函数体最后一个表达式是 `None<String>`，任何输入都返回 `None`。`getArgs` 与 `ArrayList.get` 均不抛异常（`get` 返回 `?T`），不存在崩溃路径，属纯静默失效。
- **描述**：模块唯一的"取单个参数值"入口完全失效：README.md:47-48（及 README_en.md:47-48）示例 `getArg('db.host') // Some("127.0.0.1")`、`getArgValue<Int64>('db.port') // Some(5432)` 不可能成立；`getArgValue` 内部经 `getArg` 取不到值，也永远返回 `None`。调用方拿到 `None` 时会当作"参数没传"走默认值，配置被静默忽略，无任何日志或异常提示。全仓检索 `getArg` / `getArgValue` 仅命中 README 与定义处，仓内没有调用点，因此缺陷长期未暴露（模块也无任何测试文件）。
- **建议**：改为不回落到 `None` 的显式返回，例如 `getArgs(name).flatMap { l => l.get(0) }`，或 `match (getArgs(name)) { case Some(l) => l.get(0); case None => None<String> }`；`getArgValue` 用 `getArg(name).flatMap { v => T.tryParse(v) }`。补一条 `CmdArgs` 单元测试覆盖 `--k=v` 单值、重复、缺失三种输入。

### [严重][存量] #2 位置参数无归属键时抛 `NoneValueException`：`myapp a.txt` / `myapp --verbose a.txt` 在类初始化阶段崩溃

- **位置**：`f_cmd/src/CmdArgs.cj:54`（`prev` 初值 `f_cmd/src/CmdArgs.cj:32`；`--` 分支把 `prev` 重置为空串 `f_cmd/src/CmdArgs.cj:35`）
- **来源**：存量（`git blame -L 32,57` → `4be871f2f`）
- **判据**：review-checklist §11（空集合 / 键不存在未处理）+ §13（README 解析规则与实现不符）
- **证据**：静态确定 —— `HashMap.[](key)` 在键不存在时抛 `NoneValueException`（std 文档 `std.collection.class.hashmap.operator-indexer`）。`--k=v` 与 `--flag` 两个分支都把 `prev` 置为 `''`，此后任何不以 `-` 开头的参数都会执行 `this.args[prev].add(arg)`，即 `this.args['']`。
- **描述**：触发面覆盖最常见写法：① `app a.txt`（无选项、直接位置参数）；② `app --verbose a.txt`（长选项后跟位置参数）；③ `app --k=v a.txt`。三者都在构造期抛异常，而构造发生在 `public static let instance = CmdArgs()`（`CmdArgs.cj:59`）的类初始化里，异常从首次访问 `CmdArgs` 处向上抛（包装形式文档未说明，待确认），CLI 启动即失败。README.md:37 声称"位置参数 → 最近一个 `-x`/`--x` 的键"，README.md:59 只说"出现在任何选项之前的位置参数没有归属键，不要依赖"——实际不是"没有归属"而是抛异常。反例更暴露不一致：`app -- a.txt` 不抛，因为 `"--"` 会经 `arg[2..]` 生成空键 `''`，位置参数被静默塞进空键，与 `--` 的"终止符"直觉相反。
- **建议**：把归属键建模成 `Option<String>`（`var prev: ?String = None`），无归属时显式忽略或抛 `CmdException` 并附用法提示；落值处改为 `if (let Some(k) <- prev) { if (let Some(l) <- args.get(k)) { l.add(arg) } }`。`--flag` 分支应把 `prev` 设为该 flag 的键（而不是清空），才能与 README:37 的表格一致；`--` 与 `--=v` 这类空键需显式拒绝。

### [一般][存量] #3 `commandPath` 每次访问都 `canonicalize(env.getCommand())`，路径不可规范化时抛 `FSException`，且无错误契约

- **位置**：`f_cmd/src/CmdArgs.cj:83`（getter 84–86）
- **来源**：存量（`git blame -L 83,87` → `4be871f2f`）
- **判据**：review-checklist §11（错误处理缺失 / 资源与系统调用）+ §10（契约）
- **证据**：静态确定（`canonicalize` 对"路径不存在或无法规范化"抛 `FSException`，`env.getCommand()` 对"进程不存在 / 僵尸进程"抛 `EnvException`，均为 std 文档明示）+ 待确认（`env.getCommand()` 在 Linux/Windows 返回绝对路径还是裸命令名，未在文档中说明）
- **描述**：若进程以 `PATH` 中的裸名启动（`myapp`），`canonicalize` 会相对当前工作目录解析，路径不存在即抛 `FSException`；`env.getCommand()` 自身也可能抛 `EnvException`。README.md:20/56 只写"得到进程文件所在路径""每次访问现算"，没有说明异常，调用方无法预判。此外该属性不在构造期缓存，每次读都做一次字符串规范化 + 文件系统解析（syscall），与 `currentWorkingDirectory` 的"构造期快照"策略相反。
- **建议**：构造期用 `env.getCommandLine()[0]`（进程自身路径，`[0]` 语义见 `f_config/README.md:49`）做一次 `canonicalize` 并缓存，失败时回退到未规范化的 `Path`；把"可能抛 `FSException` / 回退策略"写进 README。

### [一般][存量] #4 `getArgs` 原样返回内部 `ArrayList`，单例状态可被外部改写

- **位置**：`f_cmd/src/CmdArgs.cj:71`（内部字段 `f_cmd/src/CmdArgs.cj:25`，单例 `f_cmd/src/CmdArgs.cj:59`）
- **来源**：存量（`git blame -L 71,73` → `4be871f2f`）
- **判据**：review-checklist §12.1（共享可变状态无保护）+ §10（封装）
- **证据**：静态确定（`args.get(name)` 返回 map 中同一个 `ArrayList` 实例，非副本；`ArrayList` 是引用类型）+ 待确认（仓内无调用点，无法确认下游是否会 `add`/`clear`）
- **描述**：`instance` 是进程级单例，`getArgs` 把内部容器的引用直接交给调用方：任一调用方执行 `list.add(...)` / `list.clear()` 都会改写全局解析结果；与另一线程的 `getArg` / `getAllKeys`（遍历 `args.keys()`）构成无同步的并发读写（`HashMap` 非并发容器，`f_config` 同类场景用的是 `ConcurrentHashMap`，见 `f_config/src/Config.cj:48`）。另一个易误判点：`Option` 只表示"键存在"，不表示"有值"——`--flag` / `-x` 的列表为空，`getArgs(name).getOrThrow().size == 0`。
- **建议**：返回快照或只读视图，例如 `args.get(name).map { l => l.clone() }`；README 明确"返回值只读，修改不影响解析结果"；如需多线程安全，至少不要在文档中暗示可变。

### [一般][存量] #5 同一份 argv 有两套解析实现（`f_cmd` 与 `f_config`），语义互不一致

- **位置**：`f_cmd/src/CmdArgs.cj:34`–`56` 与 `f_config/src/Config.cj:66`–`97`
- **来源**：存量（两处均为 `4be871f2f` 前后的既有代码；`f_config` 侧只作对照，不展开审查）
- **判据**：review-checklist §2（近似重复 → 行为漂移）
- **证据**：静态确定（两边同样的字面量 `--` / `-` / `=` / `trimAscii` / `env.getCommandLine()[1..]`，但分支动作不同）
- **描述**：差异点逐条列出——① `--flag`：`f_config` 记为 `'true'`，`f_cmd` 记为空列表；② `-p 8080`：`f_config` 键为 `p`（去掉 `-`）且只取紧随的一个值，`f_cmd` 键为 `-p`（保留 `-`）且把后面所有位置参数都收进列表；③ 重复 `--k`：`f_config` 后者覆盖，`f_cmd` 追加成多值；④ 无归属位置参数：`f_config` 忽略，`f_cmd` 抛异常（见上一条）。同一进程里两个模块对同一命令行给出不同结论，排障时极易互相误导。
- **建议**：两者用途不同（`f_config` 是 `-D` 风格单值配置，`f_cmd` 是多值列表），**不建议强行合并**；但应在两份 README 用同一张对照表写明差异，或把 tokenizer（切分 `--k` / `--k=v` / `-x` 的归属规则）抽到 `f_util` 由两边复用，避免第三套实现再出现。

### [一般][存量] #6 `CmdException` 从未被抛出，README 却把它列为模块异常契约

- **位置**：`f_cmd/src/exception/CmdException.cj:20`（四个构造器 21–31）；契约源 `f_cmd/README.md:28`、`f_cmd/README_en.md:28`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §14（承诺了但没接线）+ §13（文档与实现不符）
- **证据**：静态确定 —— 全仓检索 `throw CmdException` / `CmdException(` 除定义处零命中（`f_cmd` 内也没有 `import fountain::f_cmd.exception.*`），失败路径实际抛的是 `NoneValueException`（解析）与 `FSException` / `EnvException`（`commandPath`）。
- **描述**：调用方按 README 写 `catch (e: CmdException)` 永远捕不到本模块的任何失败，异常处理形同不存在；而真正失败会以 std 异常穿透到上层。
- **建议**：解析失败（无归属位置参数、空键、空 argv）统一包成 `CmdException` 并保留 `cause`；若决定不再使用该类型，则删除 README:28 的异常段落，避免对外承诺空契约。

### [轻微][存量] #7 三种"重复出现"语义各不相同（`-x` 重置、`--k=v` 追加、`--flag` 不重置）

- **位置**：`f_cmd/src/CmdArgs.cj:35`、`:47`–`49`、`:51`
- **来源**：存量（`git blame -L 34,56` → `4be871f2f`）
- **判据**：review-checklist §10（一致性 / 可维护性）+ §11（语义与文档）
- **证据**：静态确定（`-x` 分支无条件 `this.args[arg] = ArrayList()`，重复即清空；`--k=v` 走 `l.add(val)` 追加；`--flag` 有 `!contains` 保护，重复不重置）
- **描述**：`-p 1 -p 2` 会静默丢弃 `1`，而 `--k=1 --k=2` 保留两个值，`--flag --flag` 保持单键。README.md:34-37 把三种行为都写进了表格，但没有提示"`-x` 重复会丢值"，使用方按 `--` 的直觉迁移到 `-` 就会丢数据。
- **建议**：统一为"追加"或"最后覆盖"二选一；若保留现状，在 README 表格下补一行"`-x` 重复会清空先前的值，可能丢数据"。

### [轻微][存量] #8 字段全用 `var` 但构造后不再赋值；命名与访问器风格不统一

- **位置**：`f_cmd/src/CmdArgs.cj:25`–`27`（`args` / `appName` / `_currentWorkingDir`）、`:80`–`92`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §10（可读性 / 仓颉语言特性：不可变性）
- **证据**：静态确定（三个字段仅在声明处与构造函数内赋值，之后无写入；`getAppName()` 是方法而 `commandPath` / `currentWorkingDirectory` 是属性；`_currentWorkingDir` 带下划线前缀，与 `args` / `appName` 风格不一致；`appName` 与 `commandPath` 各调用一次 `env.getCommand()`）
- **描述**：可变字段削弱了"解析结果不可变"这一实际语义，也让人误以为运行期可改；访问器三种风格混用，对外 API 显得随意。
- **建议**：改为 `private let args` / `private let appName` / `private let currentWorkingDir`（属性同名可直接返回字段）；`getAppName()` 保留为兼容方法的同时补一个 `appName` 属性；`commandPath` 复用同一个 `env.getCommand()` 结果。

### [轻微][存量] #9 README 示例 `getAllKeys(prefix: 'db')` 无法编译（对非命名参数用了名称标签）

- **位置**：`f_cmd/README.md:50`、`f_cmd/README_en.md:50`；实现 `f_cmd/src/CmdArgs.cj:61`
- **来源**：存量（`git blame` README 同批提交）
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— 语言文档"只有定义中写成 `paramName!: T` 的形参才能使用 `paramName: value` 调用；普通的 `paramName: T` 是位置参数"（`language.function.2-函数调用.2-3-命名参数调用`），而 `getAllKeys(prefix: String)` 的形参没有 `!`
- **描述**：示例照抄会编译失败，而这是 README 里唯一演示 `getAllKeys` 的片段。
- **建议**：改为 `args.getAllKeys('db')`，或把形参声明成 `prefix!: String` 后同步修改调用点（会破坏对外的位置调用兼容性，推荐改文档）。

> 范围外提示（不占本轮统计）：根 `README.md:166` / `README_en.md:157` 声称"也可以使用 `fountain::fountain.cmd` 包使用本模块的同名API"，但 `src/` 下没有 `cmd/` 聚合包（`src/` 只有 app/aspect/base/bean/... 等 30 个目录，无 cmd，全仓无 `package fountain::fountain.cmd`）；`f_cmd/cjpm.toml:4` 声明了 `fountain::f_regex` 依赖但源文件未使用。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本模块为启动期一次性解析 + 低频查询，收益受调用次数限制。

### [CPU] `commandPath` 每次访问都做一次 `canonicalize`（文件系统解析）

- **现状**：每次读属性执行 `env.getCommand()` + `canonicalize(...)` + `Path.parent`（`CmdArgs.cj:83-87`），`canonicalize` 需要解析路径中间引用与软链接，属 syscall 级开销；进程生命周期内该值恒定。
- **方案**：构造期解析一次并缓存到 `private let _commandPath: Path`，getter 直接返回；解析失败时缓存回退值（未规范化的 argv[0]）。
- **预期**：单次访问从 syscall 级降到字段读取；收益取决于调用频次，本模块查询为低频，端到端影响预计很小。
- **代价**：语义变化——运行期更换二进制/软链接后不再反映最新路径（与 `currentWorkingDirectory` 的快照语义反而一致）；需定义失败回退值。
- **验证**：`cjpm bench -O2`，同机器对照"访问 1e6 次 `commandPath`"的耗时中位数与离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `getAllKeys` 先建 `ArrayList` 再 `unsafeData()`，多一次整表拷贝

- **现状**：`CmdArgs.cj:61-67` 逐个 `list.add(key)` 后 `list.unsafeData()`；`unsafeData()` 的实现是 `getRawArray()[0 .. size]` 切片（`f_base/src/UnsafeData.cj:25-29`），即再复制一份数组，单次调用产生 ArrayList 扩容 + 数组切片两次分配。
- **方案**：预分配 `ArrayList<String>(args.size)`（容量上界已知，省掉扩容），或改用标准库顶层函数 `collectArray(args.keys().filter { k => k.startsWith(prefix) })` 一次生成 `Array`。
- **预期**：单次调用减少 1 次数组分配与若干次扩容；键数量级为 argv 长度（一般 < 50），绝对收益微小。
- **代价**：`unsafeData()` 是 `f_base` 的扩展，改写后不再依赖该扩展；行为不变。
- **验证**：`cjpm bench -O2` 对照 1e5 次调用，输入 50 个键；观察分配字节数（`getAllocatedHeapSize()`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `commandPath` 的 `canonicalize` 是调用方可见的延迟点 | `f_cmd/src/CmdArgs.cj:83` | 单次调用耗时、调用频次 | `cjprof record` 跑一个高频读 `commandPath` 的 CLI 场景（1e6 次），看 `canonicalize` 自耗时占比 |
| 2 | `getAllKeys` 的两次分配在批量查询下可测 | `f_cmd/src/CmdArgs.cj:61` | 分配字节数、单次耗时 | `cjpm bench -O2` 对照预分配版本，1e5 次调用、50 键输入，取中位数与离散度 |
| 3 | 静态单例首次访问的并发初始化是否只执行一次 | `f_cmd/src/CmdArgs.cj:59` | 仓颉静态初始化器的并发语义（文档未明确写"多线程首访问"） | 多线程同时首次访问 `CmdArgs.instance`，统计构造次数（加临时计数埋点），确认是否重复构造/重复读 argv |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_cmd/README.md` | .md | ✅ | 与实现有 4 处不一致：示例返回值（:47-48）、位置参数归属（:37/:59）、异常契约（:28）、命名实参示例（:50）；见 #1/#2/#6/#9 |
| 2 | `f_cmd/README_en.md` | .md | ✅ | 与 `README.md` 逐行同步（59 行对 59 行），问题同上，无独立缺陷 |
| 3 | `f_cmd/src/CmdArgs.cj` | .cj | ✅ | 100 行全文读完；#1–#5、#7–#9 位置 |
| 4 | `f_cmd/src/exception/CmdException.cj` | .cj | ✅ | 32 行全文读完；仅异常类型样板，#6 位置（全仓无抛出点） |

合计：`.cj` 2 个 / `.md` 2 个 / 共 4 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 2 严重 + 4 一般 + 3 轻微；安全性无外部输入拼接、无凭据，未命中 |
| §1 死代码 | 0 | 逐个符号核过：`private init()` / `private init(args:)` 被 `instance` 初始化调用；字段 `args`/`appName`/`_currentWorkingDir` 均被读；4 个 import（`HashMap,ArrayList`/`Parsable`/`Path,canonicalize`/`env`）全部使用；无 `return`/`throw` 后的同层语句，无恒假分支。`CmdException` 及四个构造器为对外可达 `public` 顶层类，按硬原则一不判死代码，仅记"仓内零引用" |
| §2 重复逻辑 | 1 | 同文件 8 个函数体两两比对无同语义实现；跨文件按字面量 `--`/`=`/`[1..]`/`trimAscii` 搜索命中 `f_config/src/Config.cj:66-97`，已列 #5（行为漂移，不建议合并） |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/空函数体业务逻辑；`CmdException` 四个构造器是 `super(...)` 转发的异常类型样板，非空实现；无 `catch {}` 吞异常 |
| §4 栈溢出 | 0 | 无递归、无自引用结构；唯一循环 `for (arg in args)` 深度由 argv 长度决定（有界） |
| §5 OOM | 0 | 仅持有 `env.getCommandLine()[1..]` 切片与按 argv 规模建立的 map，无无界容器/缓存/按报文长度预分配 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 bench / `cjprof` 数据；`commandPath`、`getAllKeys` 两条疑点已降级为待验证假设 #1/#2，不作缺陷 |
| §6.2 大粒度锁 | 0 | 模块内无 `synchronized` / `Mutex` / 锁对象 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池 / 队列 |
| §6.4 低效算法 | 0 | 无嵌套循环、`remove(at:0)`、重复正则；`getAllKeys` 的 O(#keys) 线性过滤键数 ≤ argv 长度，不构成低效 |
| §7 降堆内存方案 | 0 | 无长期持有的大对象、无中间副本链（`unsafeData` 的切片拷贝已并入 §8 方案），无缓存可瘦身 |
| §8 降 CPU 方案 | 2 | `commandPath` 缓存 canonicalize、`getAllKeys` 去掉一次数组拷贝；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 函数内无大临时对象；`docs/LocalMode.md:485` 已判定 f_cmd"启动期；不做"，`docs/LocalMode-O2-Plan.md:127` 亦把 f_cmd 列入"跨调用持有"不适用；无峰值内存数据，不构成方案 |
| §11 现有代码的 BUG（存量） | 3 | #1（`getArg` 恒 None）、#2（位置参数抛 `NoneValueException`）、#3（`commandPath` 未处理 `FSException`）；构造函数三个分支的边界、空 argv 切片 `[1..]` 与 `getArgs`/`getArgValue` 的 `None` 路径均已逐一核对 |
| §12 并发安全与锁粒度 | 1 | #4：`getArgs` 泄漏内部 `ArrayList` 引用 + 进程级单例 `instance`，构成无同步的共享可变状态；另记录"静态单例首访问并发初始化"为待确认（假设 #3），未定为缺陷 |
| §14 功能完备性与 README 覆盖 | 1 | 9 个 public 成员（`instance`、`getAllKeys`、`contains`、`getArgs`、`getArg`、`getAppName`、`commandPath`、`currentWorkingDirectory`、`getArgValue`）在 README 中均有条目；命中 1 条承诺未接线（#6 `CmdException`）；根 README 的 `fountain::fountain.cmd` 承诺见"范围外提示" |
| 文件覆盖（§13 等） | 4/4 | 4 个文件全部读完；§13 文档一致性命中并入 #1（:47-48）、#2（:37/:59）、#6（:28）、#9（:50），另 README 与 README_en 已逐行对照，措辞同步 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

## 总评

模块只有 100 行实现，但两个核心入口都不可用：`getArg`/`getArgValue` 因 `if` 无 `else` 恒返回 `None`（静默失效，调用方只会看到"参数没传"），构造函数在位置参数无归属时用空串做键而抛 `NoneValueException`（`myapp a.txt`、`myapp --verbose a.txt` 都会在类初始化期崩溃）。这两条是阻塞项，必须先修并补测试——模块当前没有任何测试文件，仓内也没有任何调用点（`f_cmd` 仅被 `f_bean`、根 `cjpm.toml` 声明为依赖），这正是它们长期未被发现的原因。

其次是契约层面的问题：`CmdException` 从未被抛出却写进 README，`commandPath` 可能抛 `FSException`/`EnvException` 但文档未提，README 的解析规则表与实现的参数归属规则不符，示例代码本身还不能编译。`getArgs` 泄漏内部 `ArrayList` 使单例状态可被外部改写，是并发/封装上的隐患（仓内暂无调用点，风险取决于下游用法）。

其余为一致性与整洁度：三种"重复出现"语义各异、字段全 `var`、访问器风格混用、`getAllKeys` 多一次拷贝。性能与内存方面本模块是启动期一次性解析，无测量数据支持任何优化收益，两条方案与三条假设都只是"待验证"，不建议排期。

存量缺陷共 9 条（严重 2 / 一般 4 / 轻微 3），默认只报不修，是否纳入修复待用户决定。
