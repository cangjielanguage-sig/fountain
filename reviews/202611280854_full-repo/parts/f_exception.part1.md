# f_exception 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_exception`（全模块 21 个 `.cj` + 2 个 `.md`；**本报告为模块第 1/2 部分**，覆盖 18 个 `.cj` + 2 个 `.md`；`imports.cj`、`UnsupportedOperatorException.cj`、`UnwritableException.cj` 属第 2 部分，本报告未纳入统计）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：异常体系契约、静默吞异常、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [一般][存量] `IllegalStateException` 与自动导入的 `std.core.IllegalStateException` 同名，语义异常在调用方被静默替换

- **位置**：`f_exception/src/IllegalStateException.cj:18`（类声明）；文档侧 `f_exception/README.md:27`、`f_exception/README.md:64`、`f_exception/README_en.md:27`、`f_exception/README_en.md:64`
- **来源**：存量（`git blame -w -L 18,19 -- f_exception/src/IllegalStateException.cj` → `^8b9ad4a7f` 2024-11-03；`4be871f2f` 仅换行符归一化）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §13（文档与事实不一致）
- **证据**：静态确定 ——
  1. 标准库确实存在同名类型：`grep -alw IllegalStateException $CANGJIE_HOME/modules/windows_x86_64_cjnative/std/*.cjo` → `std.core.cjo`、`std.unittest.cjo`；对 18 个类名逐个做精确同名扫描，**只有 `IllegalStateException` 命中**（`IllegalArgException`、`OutOfBoundsException`、`NumberFormatException` 均无同名符号）。
  2. 仓内 28 个 `.cj` 以未限定名使用 `IllegalStateException`，全部落在**没有引用 f_exception** 的包里，例如 `f_cache/src/HeapCache.cj:232`（该模块只在 `f_cache/cjpm.toml:4` 依赖 f_exception，`f_cache/src/` 中 f_exception 引用数为 0）、`fmq/src/queue/QueueManager.cj:100`（`fmq` 全模块无 f_exception 依赖）。这些名字只能绑定 `std.core` 的同名类型。
  3. 本模块的 `IllegalStateException` 在 `f_exception/` 之外**零引用**：`grep -rl IllegalStateException` 与 `grep -rl "import fountain::f_exception"` 两个文件集合的交集为空（仓内 71 个 `.cj` 出现 `fountain::f_exception`（含本模块与再导出文件），无一使用该类）。
- **描述**：模块承诺「统一挂在 `f_base.BaseException` 下，供各模块抛出/捕获」（`f_exception/README.md:3`），但该类名与每个文件都自动可见的 `std.core` 类型重名。调用方漏写 `import fountain::f_exception.IllegalStateException` 时编译不报错，静默绑定 std 类型；`std.core.IllegalStateException <: std.core.Exception`，与 `f_base.BaseException` 没有继承关系，因此仓内按 `BaseException` 统一兜底的捕获（6 处，例如 `f_orm/src/base/SqlExecutor.cj:368`、`f_jit/src/base/RegistrationException_test.cj:102`）都捕不到这类异常，会穿透到更外层（框架兜底 / 进程顶层）；f_jit 甚至在注释里把这条口径写成设计约定（`f_jit/src/base/JitException.cj:29`：「宿主可 `catch (e: BaseException)` 与其它 fountain 模块统一处理」）。后果不是崩溃，而是「异常体系被悄悄拆成两套」——正是本模块存在的意义所在。补充：若下游文件写 `import fountain::f_exception.*` 后再用未限定名，是否报歧义或静默取胜，取决于仓颉「显式导入 vs core 自动导入」的优先级，仓内没有这种组合可供取证，此点标 `待确认`（需一次最小编译验证）。
- **建议**：任选其一并写进 README——(a) 改名（如 `IllegalStatusException`），旧名保留一版做过渡；(b) 保留类名，但在 README 与类注释明确「必须全限定 `fountain::f_exception.IllegalStateException`」，并逐个修正当前误绑 std 的调用方；(c) 增加一条命名检查（新增类名不得与 std 已导出符号同名），避免同类问题再发生。本类型仓内零引用，改名主要影响仓外下游，需用户决定。

### [轻微][存量] README 的「与 std 同名」清单三个例子都不是同名，真正同名的 `IllegalStateException` 反而未提

- **位置**：`f_exception/README.md:25`（IllegalArgException）、`:32`（NumberFormatException）、`:33`（OutOfBoundsException）、`:64`；`f_exception/README_en.md:25`、`:32`、`:33`、`:64`
- **来源**：存量（`git blame -w -L 24,28 -- f_exception/README.md` → `2623bbfff2` 2026-10-06）
- **判据**：review-checklist §13（文档与代码/事实不符）
- **证据**：静态确定 —— std 中是 `IllegalArgumentException`（非 `IllegalArgException`）、`IndexOutOfBoundsException`（非 `OutOfBoundsException`），且**没有** `NumberFormatException`（对 18 个名字做 `grep -alw` 扫描全部 `std/*.cjo` 的结论）。
- **描述**：README 写「`IllegalArgException`/`OutOfBoundsException`/`NumberFormatException` 等与 std 同名异常不是同一类型，按 std 异常名 `catch` 捕获不到」，三个例子其实都不同名（`IllegalArgException` 本来就是为避免撞名才改的写法），而唯一真正同名、真正会让 `catch` 抓错类型的 `IllegalStateException`（见上一条）没有出现。使用者按这段做排查会漏掉唯一的高风险项。
- **建议**：拆成两栏——「名字不同但语义相近的 std 异常」（IllegalArgException / OutOfBoundsException / NumberFormatException）与「与 std 完全同名、必须全限定」（IllegalStateException），中英同步。

### [轻微][存量] README 建议「自行继承添加字段」，但本模块异常类均非 `open`，实际无法继承

- **位置**：`f_exception/README.md:63`、`f_exception/README_en.md:63`；反证 `f_exception/src/IllegalStateException.cj:18`（`public class`，无 `open`）
- **来源**：存量
- **判据**：review-checklist §13 / §14（文档承诺与实现不一致）
- **证据**：静态确定 —— 本部分 18 个类（全模块 20 个）声明均为 `public class X <: BaseException`，未加 `open`；仓颉类型默认不可继承，`class MyEx <: IllegalArgException` 无法通过编译。README 同段引用的 `f_pool/src/exception/UnknownKeyException.cj:53` 实际是**直接继承 `BaseException`**，不是继承本模块的某个类。
- **描述**：「需要带上下文（索引、键名）时只能写进 `message`，或自行继承添加字段」中的「自行继承」指向不明：读者合理地会理解为继承上表里的异常类，而这在本模块行不通。
- **建议**：改写为「需要额外字段时直接定义 `public class XxxException <: BaseException`（参见 f_pool 的 `UnknownKeyException`）」。无需改代码。

### [轻微][存量] 18 个类体逐字相同（仅类名不同），构造器集合靠人工复制同步，模块内无任何测试守护

- **位置**：`f_exception/src/DuplicateInstanceException.cj:18`–`:30` 等本部分全部 18 个文件（均为 30 行、4 个构造器）
- **来源**：存量
- **判据**：review-checklist §10（可维护性）；§2 的两两比对结论见「覆盖自检」（判定为刻意设计，不计为重复缺陷）
- **证据**：静态确定 —— `diff <(sed 's/DuplicateInstanceException/XXX/g' …) <(sed 's/UnreachableException/XXX/g' …)` 输出为空；每个文件 `grep -c 'public init'` 均为 4；`files/f_exception.part1.txt` 内无 `*_test.cj`，全仓唯一引用 f_exception 的测试 `f_pool/src/KeyPool_test.cj` 不覆盖本模块构造器的 message/cause 转发。
- **描述**：当前 20 个类无漂移，但「4 个构造器 + 逐个 `super(...)` 转发」完全靠手工复制：以后补一个构造器、或统一加默认消息，要改 20 个文件，漏改不会被任何测试发现（`BaseException` 的 4 个构造器与本模板一一对应，漂移会直接表现为某类异常丢 message / 丢 cause）。
- **建议**：优先加一个表驱动测试（把 20 个类放进数组，逐个断言 4 个构造器的 `message`/`causedBy`），成本低、能锁住转发语义；若要彻底消除复制，可用 `f_macros` 生成这些类（仍保持每个类独立的 nominal 类型，`catch` 语义不变）。属优化项，不进修复清单。

## 优化可行性方案

本部分为空。该部分只有类声明与构造器转发，没有循环、容器、锁、序列化或字符串拼接，不存在可量化的 CPU / 堆内存优化面；唯一相关的分配行为（每个异常实例预分配一个 `ArrayList` 作 `suppressed_`）位于 `f_base/src/BaseException.cj:45`，属 f_base 模块评审范围，见「范围外提示」。

## 待验证假设

本部分不涉及运行期计算与内存热点，无待验证项。唯一需要实测的是「`import fountain::f_exception.*` 与 `std.core.IllegalStateException` 同时可见时，未限定名是报歧义还是静默取胜」——这属于语言语义确认（一次最小编译即可），已并入发现 1 的 `待确认` 说明，不作为性能假设。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_exception/README.md` | .md | ✅ | 20 个类全部在表中；见发现 1/2/3（第 64 行同名说明、第 63 行继承说明） |
| 2 | `f_exception/README_en.md` | .md | ✅ | 与中文版逐段对应（64 行，结构一致），见发现 2/3 |
| 3 | `f_exception/src/DuplicateInstanceException.cj` | .cj | ✅ | 4 构造器，仅类名不同；仓内零引用（对外 public，不判死代码） |
| 4 | `f_exception/src/IllegalAccessException.cj` | .cj | ✅ | 同上模板；仓内 8 个文件引用 |
| 5 | `f_exception/src/IllegalArgException.cj` | .cj | ✅ | 同上模板；仓内 2 个文件引用 |
| 6 | `f_exception/src/IllegalSizeException.cj` | .cj | ✅ | 同上模板；仓内 3 个文件引用 |
| 7 | `f_exception/src/IllegalStateException.cj` | .cj | ✅ | 见发现 1（与 std.core 同名，仓内零真实引用） |
| 8 | `f_exception/src/NoSuchElementException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 9 | `f_exception/src/NotConsideredException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 10 | `f_exception/src/NotInstantiatedException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 11 | `f_exception/src/NotSupportedTypeException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 12 | `f_exception/src/NumberFormatException.cj` | .cj | ✅ | 同上模板；仓内零引用；std 无同名类型（见发现 2） |
| 13 | `f_exception/src/OutOfBoundsException.cj` | .cj | ✅ | 同上模板；仓内 11 个文件引用；std 对应物是 `IndexOutOfBoundsException` |
| 14 | `f_exception/src/StatusException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 15 | `f_exception/src/TypeCastException.cj` | .cj | ✅ | 同上模板；仓内 3 个文件引用 |
| 16 | `f_exception/src/TypeNotMatchException.cj` | .cj | ✅ | 同上模板；仓内 3 个文件引用 |
| 17 | `f_exception/src/UnexpectedTokenException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |
| 18 | `f_exception/src/UnreachableException.cj` | .cj | ✅ | 同上模板；仓内 18 个文件引用（最常用的一类） |
| 19 | `f_exception/src/UnreadableException.cj` | .cj | ✅ | 同上模板；仓内 3 个文件引用 |
| 20 | `f_exception/src/UnsupportedAccessException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码） |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完（与 `files/f_exception.part1.txt` 的 20 行一一对应）。

> 表中「仓内 N 个文件引用」为 `.cj` 中出现该类名的文件数（含注释提及，已排除 `.worktrees/` 与本模块 `src/`）；「零引用」表示全仓 `.cj` 无任何文本提及。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性命中 1 条（`IllegalStateException` 绑定歧义，与 §11 同一根因，不重复计数）；设计上「一类一文件、只有 4 个构造器、无额外字段」与 README 一致；无外部输入、无拼接、无凭据，安全性无命中；可读性无命中（30 行模板，命名清楚） |
| §1 死代码 | 0 | 已逐个检查 18 个 `public` 顶层类及其 4 个 `public` 构造器：全部对外可达（顶层 `public`、无嵌套链），按硬原则一不判死代码；无 `private` / `internal` / `protected` 符号；无 `return` 后的同层语句、无常量、无 import（本部分文件不含 import）。附信息：9 个类（DuplicateInstance、NoSuchElement、NotConsidered、NotInstantiated、NotSupportedType、NumberFormat、Status、UnexpectedToken、UnsupportedAccess）仓内零文本引用，`IllegalStateException` 零真实引用，均属对外契约，只作信息 |
| §2 重复逻辑 | 0 | 已把 18 个类体压成摘要两两比对：全部为「4 个 `super(...)` 转发，无字段、无副作用」，`diff` 忽略类名后完全一致。差异只有类名，而类名正是本模块唯一的产品（nominal 类型决定 `catch` 语义），合并成一个类会摧毁契约，故判定为刻意设计、不是重复缺陷；维护成本另见发现 4 |
| §3 空实现 | 0 | 18 处 `public init() {}` 是「不传 message/cause 的默认构造器」，隐式调用 `BaseException.init()`（`f_base/src/BaseException.cj:47`），不是空契约；无 `TODO` / `FIXME`；无 `catch` 块（本部分无函数体逻辑） |
| §4 栈溢出 | 0 | 本部分无函数体、无递归、无自引用结构、无深度遍历/深拷贝；`printStackTrace` 的递归在 f_base，不在本部分 |
| §5 OOM | 0 | 无容器、无按输入预分配、无全量物化、无缓存；异常实例由调用方按需创建，模块自身不持有状态 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；模块只有类声明，没有可测量的自耗时函数，热点不成立 |
| §6.2 大粒度锁 | 0 | 无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`、无 Future、无线程池 |
| §6.4 低效算法 | 0 | 无循环、无查找、无字符串拼接 |
| §7 降堆内存方案 | 0 | 模块不持有对象；`BaseException` 每实例一个 `ArrayList` 的分配属 f_base，见「范围外提示」 |
| §8 降 CPU 方案 | 0 | 无运行期计算，构造器只做字段转发（父类字段） |
| §9 local mode 可行性 | 0 | 无函数内临时大对象；异常对象必须逃逸到 `throw` 点与 `catch` 点，逃逸检查直接不成立 |
| §11 现有代码的 BUG（存量） | 1 | 已核对 18 个类的继承目标、构造器参数顺序、`super` 调用形式（与 `f_base/src/BaseException.cj:47-57` 逐项对齐），无参数错位、无空值分支；唯一缺陷是发现 1 的命名/绑定问题（含静默错误类型） |
| §12 并发安全与锁粒度 | 0 | 18 个类无字段、无静态可变状态、无单例，实例在 `throw` 前由单线程构造，无线程共享可变状态可审；`addSuppressed` 的并发语义在 f_base |
| §14 功能完备性与 README 覆盖 | 0 | README 表（`:23-42`）覆盖本部分全部 18 个类，无「有类无文档」也无「有文档无类」；`fountain::fountain.exception` 再导出的承诺为真（`src/exception/exception.cj:18` + 根 `cjpm.toml:17` 依赖）；`public import BaseException` 已在 `f_exception/src/imports.cj` 落地（第 2 部分文件，仅作核对） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`imports.cj` / `UnsupportedOperatorException.cj` / `UnwritableException.cj` 不在本部分清单内 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 4 条（1 一般 + 3 轻微），是否纳入修复待用户决定。

## 总评

本部分代码是 18 个逐字相同的异常类模板，逻辑上几乎没有出错空间：继承目标、构造器签名与 `BaseException` 完全对齐，无死代码、无重复缺陷、无递归 / OOM / 并发面，整体质量良好。真正的风险不在类体，而在**命名契约**：`IllegalStateException` 与每个文件自动可见的 `std.core.IllegalStateException` 同名，仓内已有 28 处未限定引用全部绑定到 std 版本（`f_cache`、`fmq` 等未引用 f_exception 的包内），而本模块的版本零下游使用——这会让「统一按 BaseException 抛/捕」的承诺在这一个类上静默失效，属于需要用户拍板的存量问题（改名或明确强制全限定）。其余三条为文档精度（同名清单写错、继承措辞歧义）与模板维护（无测试守护），可排期处理。阻塞项：无；建议把发现 1 与发现 2 一起决策，因为它们指向同一个名字。

## 范围外提示（不计入统计）

- `f_base/src/BaseException.cj:69` 的 `TypeInfo.of(this)` 是否返回运行时类型 `待确认`：若取静态类型，所有子类异常的 `toString()` 都会打印 `BaseException`，语义类名只在 `catch` 时有用；该判断属 f_base 报告范围。
- `f_base/src/BaseException.cj:45` 每个异常实例都预分配一个 `ArrayList<Exception>`（多数异常从不 `addSuppressed`），异常密集路径存在可省分配；属 f_base 报告范围。
- `f_cache/src/HeapCache.cj:232`、`fmq/src/queue/QueueManager.cj:100` 以未限定名抛 `IllegalStateException` 且所在包未引用 f_exception（实际绑定 std 类型），是发现 1 的现场证据，不再单独展开。
