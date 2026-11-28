# f_exception 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_exception`（全模块 21 个 `.cj` + 2 个 `.md`；**本报告为模块第 2/2 部分**，覆盖 `src/UnsupportedOperatorException.cj`、`src/UnwritableException.cj`、`src/imports.cj` 共 3 个 `.cj`；20 个 `.cj` 与 2 个 `.md` 见第 1/2 部分报告）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：异常体系契约、静默吞异常、栈溢出、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 2/2 部分）

## 发现

### [轻微][存量] `imports.cj` 是本模块 20 个文件与仓内 24 个下游文件的唯一编译依赖来源，文件内无任何注释说明

- **位置**：`f_exception/src/imports.cj:18`（`public import fountain::f_base.BaseException`，文件除版权头与 `package` 外只有这一行）
- **来源**：存量（`git blame -w -L 16,18 -- f_exception/src/imports.cj` → 第 18 行由 `a9667b06a1` 2026-01-23 引入；`package` 行在 `a9667b06a1` 中被重排，版权头在 `^8b9ad4a7f` 2024-11-03）
- **判据**：review-checklist §1（判「未使用 import」时的排除依据）/ §10（可维护性）
- **证据**：静态确定 ——
  1. 本模块其余 20 个 `.cj` **不含任何 `import`**：`grep -rn "import" f_exception/src/*.cj` 只命中 `imports.cj:18` 一行，但 20 个异常类全部以未限定名写 `public class X <: BaseException`（例：`UnsupportedOperatorException.cj:18`、`UnwritableException.cj:18`）。
  2. 仓颉的 `import` 默认是 `private`、**仅当前文件内可访问**（`D:/docs/work/cangjie/cangjie-doc/cangjie_docs/docs/dev-guide/source_zh_cn/package/import.md:293`：「`private import` 表示导入的内容仅当前文件内可访问，`private` 是 `import` 的默认修饰符」）；`public import` 才会把成员重导出成包级可见（同文件 `:291`、`:296`）。因此这 20 个文件之所以能编译，唯一原因就是本行把 `BaseException` 重导出到了包作用域。
  3. 对外同样是硬依赖：仓内 **24 个** `.cj` 以 `import fountain::f_exception.BaseException`（或 `{BaseException, …}`）取该类型，例如 `f_aspect/src/exception/AspectException.cj:18`、`f_concurrent/src/exception/TimeoutException.cj:18`、`f_orm/src/base/ORM.cj:28`（`public import fountain::f_exception.{BaseException, UnreachableException}`）。`fountain::f_exception.BaseException` 这个路径能成立，同样只因为本行。
  4. 编译产物佐证：`f_exception/target/release/f_exception@fountain/f_exception@fountain.cjo`（2026-10-23 构建）中包含 `BaseException` 符号，说明该重导出已进入包的导出表。
- **描述**：一个只有一行 `public import`、无注释的独立文件，看起来像"可删的死文件"，实际是**整个模块的编译前提 + 24 处下游 import 的契约来源**。任何人做"清理未使用代码"或把该行挪进某个异常类文件时，会一次性打断 20 个本模块文件与 24 个仓内下游文件，而编译器报错点会分散在 44 个文件上，定位成本高。这属于可维护性风险，不是功能缺陷。
- **建议**：在 `imports.cj:18` 上方加 1–2 行注释，写明"本文件负责把 `f_base.BaseException` 重导出为 `fountain::f_exception.BaseException`；本模块其余 20 个类与 24 处下游 `import` 依赖此行，删除会导致整包无法编译"。保持独立文件不变（并入某个异常类文件会让该文件的语义从"一个异常类型"变成"包级基础设施"，更糟）。

> 与第 1/2 部分的衔接（不重复计数）：`UnsupportedOperatorException.cj`、`UnwritableException.cj` 与第 1 部分 18 个类逐字相同（仅类名不同），该维护成本根因已在第 1 部分「发现 4（18 个类体逐字相同…）」报告，本部分只补两个位置，不另立条目。`UnsupportedOperatorException` / `UnwritableException` 在全仓 `.cj` 中零引用（仅 `README.md:41`、`:42` 与 `README_en.md:41`、`:42` 提及），但均为对外可达的 `public` 顶层类，按硬原则一不判死代码，属对外契约。

## 优化可行性方案

本部分为空。三个文件只有类声明、构造器转发和一条 `import`：无循环、无容器、无锁、无字符串拼接、无序列化，不存在可量化的 CPU / 堆内存优化面。唯一的分配行为（`BaseException` 每实例预分配 `ArrayList` 作 `suppressed_`，`f_base/src/BaseException.cj:45`）属 f_base 报告范围，已在第 1 部分「范围外提示」记录。

## 待验证假设

本部分无待验证项。三个文件不含运行期计算、循环或热路径，无法也无必要给出热点假设；`public import` 的可见性语义已按官方文档取证（`package/import.md:291-296`），不属性能猜测。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_exception/src/UnsupportedOperatorException.cj` | .cj | ✅ | 30 行、4 个构造器，与 `BaseException` 签名逐项对齐；仓内零引用（对外 public，不判死代码）；README `:41` 有登记；见 §2 衔接说明 |
| 2 | `f_exception/src/UnwritableException.cj` | .cj | ✅ | 同上模板；仓内零引用（对外 public，不判死代码）；README `:42` 有登记 |
| 3 | `f_exception/src/imports.cj` | .cj | ✅ | 仅一行 `public import`，见发现 1（20 个本模块文件 + 24 个下游文件的编译前提） |

合计：`.cj` 3 个 / `.md` 0 个 / 共 3 个，全部读完（与 `files/f_exception.part2.txt` 的 3 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 正确性：两个类的 4 个构造器均正确转发（`super(message)` / `super(caused)` / `super(message, caused)`），与 `f_base/src/BaseException.cj:47-57` 的参数顺序、类型完全一致，无错位、无空值分支；设计：一类一文件、无额外字段，与 README `:8-14` 的「同一个模子」一致；语言特性：`public import` 的重导出用法与官方文档一致（`package/import.md:287-296`）；可读性：命名清晰，无深层控制流；安全性：无外部输入、无拼接、无凭据、无日志 |
| §1 死代码 | 0 | 已逐符号核对：两个类与其 4 个 `public init` 均为对外可达的 `public` 顶层声明（顶层 `public`、无嵌套链），按硬原则一不判；`imports.cj` 的 `public import` 经 24 个下游文件与编译产物证明是活契约，不是死 import；三个文件无 `private` / `internal` / `protected` 符号、无局部变量、无 `return` 后的同层语句、无恒真恒假分支。附信息：`UnsupportedOperatorException` / `UnwritableException` 仓内零文本引用（仅 README 提及） |
| §2 重复逻辑 | 0 | 已把 `UnsupportedOperatorException.cj` 与 `UnwritableException.cj` 压成摘要与第 1 部分 18 个类两两比对：全部是「4 个 `super(...)` 转发、无字段、无副作用」，忽略类名后一致。差异只有类名，而类名本身是 nominal 类型、决定 `catch` 语义，合并会摧毁契约，故判定刻意设计、不计为重复缺陷；维护成本见第 1 部分发现 4 |
| §3 空实现 | 0 | 2 处 `public init() {}` 是「不传 message/cause 的默认构造器」，隐式调用 `BaseException.init()`（`f_base/src/BaseException.cj:47`），非空契约；无 `TODO` / `FIXME`；无 `catch` 块，不存在静默吞异常 |
| §4 栈溢出 | 0 | 三个文件均无函数体逻辑：无递归、无自引用结构、无深度遍历 / 深拷贝、无每帧大对象 |
| §5 OOM | 0 | 无容器、无按输入预分配、无全量物化、无缓存；异常实例由调用方按需创建，模块自身不持有状态 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；三个文件没有可测量的自耗时函数，热点不成立 |
| §6.2 大粒度锁 | 0 | 无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池 |
| §6.4 低效算法 | 0 | 无循环、无查找、无字符串拼接；`public import` 是编译期符号解析，无运行期开销 |
| §7 降堆内存方案 | 0 | 模块不持对象；`BaseException` 每实例一个 `ArrayList` 属 f_base，见第 1 部分「范围外提示」 |
| §8 降 CPU 方案 | 0 | 无运行期计算，构造器只做父类字段转发 |
| §9 local mode 可行性 | 0 | 无函数内临时大对象；异常对象必须逃逸到 `throw` / `catch` 点，逃逸检查不成立 |
| §11 现有代码的 BUG（存量） | 0 | 已核对：两个类的继承目标（`BaseException`，`public open class`，`f_base/src/BaseException.cj:44`）、4 个构造器参数类型与顺序、`super` 调用形式，逐项与父类对齐，无参数错位、无 `Option` 丢弃、无边界 / 空集合问题；`imports.cj` 无逻辑。另一项已确认无风险：`std` 的 `modules/windows_x86_64_cjnative/std/*.cjo` 中不存在 `UnsupportedOperatorException` / `UnwritableException` 同名符号（`grep -alw` 零命中；std 只有 `UnsupportedException`），不会重演第 1 部分 `IllegalStateException` 的静默绑定问题 |
| §12 并发安全与锁粒度 | 0 | 两个类无字段、无静态可变状态、无单例；`imports.cj` 是编译期声明；实例在 `throw` 前由单线程构造，无线程共享可变状态可审（`suppressed_` 的并发语义在 f_base） |
| §14 功能完备性与 README 覆盖 | 0 | README 表 `README.md:23-42` 共 20 行覆盖全部 20 个类，本部分两个类在 `:41`、`:42`，文案「不支持的运算符」/「不可写」与类名语义一致；`README_en.md:41`、`:42` 同步；无「有类无文档」；README `:6` 的示例代码块 `public import fountain::f_base.BaseException` 与 `imports.cj:18` 的实现一致 |
| 文件覆盖（§13 等） | 3/3 | 无缺文件；本部分清单不含 `.md`，README / README_en 的文档一致性归第 1 部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 0 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 1 条（轻微），是否纳入修复待用户决定。

## 总评

本部分三个文件是模块里最"没有逻辑"的部分：两个异常类是 30 行模板（4 个构造器转发，签名与 `BaseException` 逐项对齐），一个 `imports.cj` 只有一条 `public import`。没有死代码、没有重复缺陷、没有空实现、没有递归 / OOM / 并发面，异常契约本身正确，类名也不与 std 冲突（已对 std 全部 `.cjo` 做同名扫描）。

唯一的实质风险是**可见性基础设施的隐蔽性**：`imports.cj:18` 这一行同时支撑本模块 20 个类的编译和仓内 24 个下游文件的 `import fountain::f_exception.BaseException`，但文件里没有一句注释，从形态上看最像"可删的死文件"，误删的爆炸半径是 44 个文件。加两行注释即可消除，成本极低。另需说明：`UnsupportedOperatorException` / `UnwritableException` 在仓内零使用，仅作为对外契约存在（README 已登记），属于典型的下游 API，不应因为"仓内没人用"而删除。阻塞项：无。
