# f_jit —— 仓颉方言的字节码编译器与 JIT

`f_jit` 把一段**仓颉方言**源码编译成与架构无关的字节码（`.fbc`），再由三套引擎执行：
**解释器**、**x86_64 机器码后端**、**aarch64 机器码后端**。移植到宿主应用后，宿主可以像调用普通
函数一样调用这段代码（`JitFunction.call<T>`），并用宿主侧的类/函数/闭包与之互通。

- 语义唯一权威是**解释器**；JIT 是纯加速层：任何拿不准的形态一律退回解释器（见 §5）。
- 三引擎对同一单元要求**结果 / 错误码 / site / 报告文本逐位一致**（I7）。
- 机器码**只**支持 Linux x86_64 与 Linux aarch64；其余平台自动走解释器（见 §4）。

---

## 1. 快速开始

```cangjie
import fountain::f_jit.*

main() {
    let c = Compiler()                                   // 等价于 Compiler(CompileOptions(DummyDiagnosticsSink()))
    // 需要收集诊断时：Compiler(CompileOptions(MySink()))
    c.registerType<User>()                              // 暴露一个宿主类给方言
    let f = c.compile('{ u: User => u.name }')          // 编译（结果进 CompileCache）
    let name = f.call<String>([User('bob', 1)])         // 调用
    println(name)                                       // bob
}
```

带截止时间的中断式调用：

```cangjie
let ctx = CallContext(deadline: Some(DateTime.now() + Duration.second * 1))   // 超时抛 InterruptedException
let v = f.call<Int64>([Int64(100_000_000)], ctx)
```

返回闭包（逃逸闭包，用后必须 `close()`）：

```cangjie
let f = c.compile('{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }')
let g = f.callForFn<(Int64) -> Int64>([Int64(7)])
println(g.call<Int64>([Int64(1)]))    // 8
g.close()                          // 释放该闭包捕获的提升槽（单元仍可用）
```

单元本身用完后 `close()`：先级联释放它产出的逃逸闭包，再进入终态、释放代码内存并从编译缓存逐出（同源再编译得到新单元）：

```cangjie
f.close()                            // 单元级卸载；此后调用 f 抛 JitException(ErrCode.CALL_CONTRACT)
```
`close()`（`Resource` 契约）**不等待**在飞调用，丢弃排空结果；要排空并拿到结果用 `close(timeoutMs)`——未排空时返回 `false` 并恢复可用。`isClosed()` 对入口实例表示「单元已卸载」，对包装实例表示「本闭包已释放」。

---

## 2. API

| 类型 | 用途 | 关键成员 |
|---|---|---|
| `Compiler` | 门面：注册宿主能力 + 编译 | `registerType<T>()`、**`registerInterface<I>()`**、`registerClass(desc)`、`registerFunction(f)`、`compile(src)` |
| `CompileOptions` | 编译选项 | `jit: JitMode`（`Auto`/`Force`/`Off`）、`strictFp`（缺省 `true`）、`verMajor`、`cpuFeatures`、`diagnostics` |
| `JitFunction` | 编译产物 / 可调用对象（实现 `std.core.Resource`） | `call<T>(args)`、`call<T>(args, ctx)`、`callForFn<Fn>(args)`、`close()` / `close(timeoutMs): Bool`（入口 = 单元卸载；包装 = 释放本闭包）、`isClosed()` |
| `JitException` | 运行期错误（`base` 包） | `code`（`ErrCode`）、`site`（源码行:列 / 字节偏移）、`report` |
| `CompileCache` | 编译缓存（键含 `strictFp`/`verMajor` 等标记） | `lookup`、`reset`、`runs` |
| `CallContext` | 调用上下文 | `deadline`（到期在安全点中断 → `InterruptedException`） |
| `PredefinedFunction` / `ClassDescriptor` / `PublicCtor` / `PublicField` | 宿主侧注册面 | 供方言调用的函数、类、构造器与字段 |
| `DbgDump` | 失败时的变量转储（名字/值/类型） | 由诊断 sink 触发 |
| `JitReport` | 执行报告（含 `-1` DEOPT 语义） | 由桥在 `call` 内消费 |

包结构（`fountain::f_jit.*`）：`base`（契约与错误码）、`bytecode`（`.fbc` 编解码/加载）、
`compiler`（前端 + 降低）、`runtime`（解释器 + 句柄表 + helper）、`backend`（两套机器码后端）、
`test.diff`（三引擎差分，只放对照不放单层断言）。

---

### 2.1 宿主侧宏：`@JitBind`、`@IgnoreJitBinding` 与 `@JitSignatures`

三个宏都在**宿主编译期**把"运行期反射调用"换成"静态强类型调用"：`@JitBind` 展开**类/接口成员**、
`@IgnoreJitBinding` 让单个成员**退出**注册、`@JitSignatures` 登记**闭包形参**签名。语义不变，只影响注册表里绑定体的实现方式（性能）。

#### `@JitBind`：把类/接口的公共成员展开成类型化绑定

```cangjie
import fountain::f_jit.*
import fountain::f_jit.macros.*

@JitBind
public class User {
    public var name: String
    public init(name: String) { this.name = name }
    public func greet(s: String): String { "hi ${s}" }
}

main() {
    let c = Compiler()
    c.registerType<User>()                    // 不必再手写 bindings：宏已在包初始化期登记
    let f = c.compile('{ u: User => u.greet(u.name) }')
    println(f.call<String>([User('bob')]))    // hi bob
}
```

| 面 | 规则 |
|---|---|
| 展开物 | 原类**不变**，另生成包级 `let jitBindEnroll_<类名> = enrollOf<类名>(JitBindings(...))`——不往类里插声明、不生成中间函数 |
| 覆盖 | 实例方法 → `PublicMethod`；实例字段（`var`/`let`）→ getter（`var` 另带 setter）；实例属性（`prop`/`mut prop`）→ getter + `set<Name>`；`init` → 每条一个 `PublicCtor`；**静态函数 / 只读静态字段 / 只读静态属性** → `PredefinedFunction` |
| 不展开 | 私有成员、泛型方法（WARNING）、`static var` 与 `static mut prop`（永久排除，WARNING）、`@IgnoreJitBinding` 标注的成员 |
| 注册 | `Compiler.registerType<T>()` / `registerInterface<I>()` 不传 `bindings` 时自动取用宏的登记 |

**接口必须标** `@JitBind`：反射无法 `apply` 抽象方法，未标注的接口在 `registerInterface<I>()` 处报
`RegistrationException`。父接口方法在注册期并入，**子接口变量可直接访问父接口成员**：

```cangjie
@JitBind public interface Named { func name(): String }
@JitBind public interface Greeter <: Named { func greet(): String }

@JitBind
public class Impl <: Greeter {
    public func name(): String { "n" }
    public func greet(): String { "g" }
}

let c = Compiler()
c.registerInterface<Named>()
c.registerInterface<Greeter>()
c.registerType<Impl>()
c.compile('{ g: Greeter => g.name() }')      // 父接口成员，经机器码直调
```

**成员级退出**：`@IgnoreJitBinding`。被标注的成员**原样保留**在类体里（宿主照常调用），但不进注册表——
方言侧看不到它；按名字忽略 ⇒ **同名重载整组跳过**：

```cangjie
@JitBind
public class User {
    public var name: String
    @IgnoreJitBinding public var secret: String         // 宿主可用，脚本不可见
    @IgnoreJitBinding public func hostOnly(): Unit {}   // 同上
}
```

只允许出现在 `@JitBind` 直接修饰的类/接口体内；写在别处由 `assertParentContext` 给出编译错误。

#### `@JitSignatures`：登记闭包形参的签名

```cangjie
import fountain::f_jit.JitHost              // 生成代码用短名 JitHost，标注文件必须导入
import fountain::f_jit.macros.*

@JitSignatures[(Int64) -> Int64, (String) -> Bool]
public func jitSignatures(): Unit {}        // 宏不改动该函数，只在包初始化期登记签名
```

- 生成物 = 每个签名一个包级 `let __jitSig_<函数名>_<序号>`；运行期按签名查表，**不穿**
  `FunctionTypeInfo.apply`；
- **边界**：只支持扁平签名（形参/返回是单个类型名，允许 `()`）；14 位置必须写**注册类名**；
  未登记的签名仍走反射路径（行为不变，只是慢）。

> 三个宏都只在**宿主侧**生效；方言源码（jit lambda）里不出现宏。

### 2.2 三个注册入口：`registerType` / `registerInterface` / `registerClass`

| 入口 | 适用对象 | 约束 | 绑定来源 | 建议 |
|---|---|---|---|---|
| `registerType<T>()` | **类** | `where T <: Object` | `@JitBind` 的包初始化登记（可再用 `bindings` **合并覆盖**个别成员）；未标注则退回反射收集 | **首选**：类上标 `@JitBind`，注册时不传参 |
| `registerInterface<I>()` | **接口** | **无** `T <: Object` 约束 | **必须** `@JitBind`（反射无法 `apply` 抽象方法） | 接口一律标 `@JitBind`；父接口方法注册期并入 |
| `registerClass(desc)` | 任意类（含无法标注宏的） | 需手工给全 `ClassDescriptor` | 手工 `PublicField` / `PublicMethod` / `PublicCtor` | 仅在无法用宏/反射时使用 |

#### `registerType<T>()` —— 反射自动注册（推荐配 `@JitBind`）

```cangjie
@JitBind
public class User {
    public var name: String
    public init(n: String) { this.name = n }
}

let c = Compiler()
c.registerType<User>()          // 自动取用 @JitBind 的登记
```

- 反射会收集**父类链**（`ancestry`）并据此做静态子类型判定（`as` 的合法性检查）；
- 可传 `bindings:` 覆盖个别成员——它与宏登记是**合并**关系（同名以显式为准），不会整体取代；
- **未标 `@JitBind`** 时成员退回反射路径：更慢，且引用型成员受"默认拒绝"策略约束 ⇒ 生产建议标注。

#### `registerInterface<I>()` —— 接口注册（无 `Object` 约束）

```cangjie
@JitBind public interface Named { func name(): String }
@JitBind public interface Greeter <: Named { func greet(): String }

let c = Compiler()
c.registerInterface<Named>()
c.registerInterface<Greeter>()          // 父接口方法一并可用：{ g: Greeter => g.name() }
```

- **接口不标 `@JitBind` ⇒ `RegistrationException`**（抽象方法无法反射调用）；
- 接口没有实例字段/构造器，前端据此给诊断。

#### `registerClass(desc)` —— 完全手工（不走反射）

```cangjie
import fountain::f_jit.base.{
    ClassDescriptor, LocalType, PredefinedFunction, PublicCtor, PublicField, PublicMethod
}

let greetFn = PredefinedFunction(
    name: 'greet',
    paramTypes: [LocalType.HOST_OBJECT],       // 首参必须是本类（14）
    retType: LocalType.STRING,
    impl: { a => 'hi' })

let desc = ClassDescriptor(
    name: 'LegacyUser',
    fields: [PublicField(name: 'name', `type`: LocalType.STRING, index: 0, mutable: true,
                         typeRef: None)],
    methods: [PublicMethod(name: 'greet', bind: greetFn)],
    ctors: [PublicCtor(params: [LocalType.STRING],
                       adapter: { a => LegacyUser(a[0] as String) })],
    parents: [])                                       // 不填 ⇒ 只与自身同型
c.registerClass(desc)
```

- 方法表的 `bind` 会**同时进入预定义函数面**（`u.m()` 的 hid 来源），同名已存在则复用；
- 手工注册**不做任何反射**：字段下标、方法绑定、构造适配器全由你保证（下标/类型码用错在构造期就抛 `JitCallContract`）；
- `parents` 只影响**静态子类型判定**，前端不据此解析成员；不填则该类只与自身同型；
- 类名冲突（已注册类 / 函数名 / 内建 / 关键字）⇒ `RegistrationException` 且**不登记**。

## 3. 核心原理

**① 编译**：词法/语法 → AST → 类型检查 → 降低为**栈式字节码**（157 条指令，见
`doc/jit-bytecode-m1.md` §5）。产物是 `.fbc`：容器头（`magic/verMajor/verMinor/crc32` 等）+ 代码段 +
常量段 + 类型表 + 站点表 + 函数目录 + 变量名段。字节码**与架构无关**。

**② 执行（三引擎）**：

| 引擎 | 实现 | 说明 |
|---|---|---|
| `Interp` | 纯仓颉解释器 | 参考实现；所有平台的兜底 |
| `BackendX86_64` | `X86Lower` → 机器码 | Linux x86_64；两遍降低（探针 → CFG 深度 → 发射） |
| `BackendAArch64` | `A64Lower` → 机器码 | Linux aarch64；操作数栈用独立指针 `x20` |

**③ 对象模型（句柄）**：机器码不持有对象指针，只持 **Int64 句柄** =
`idx:u32 | tag:u16 | gen:u16`（`runtime/HandleTable.cj`）。对象本体存放在仓颉堆的
`ArrayList<Any>` 里，由 GC 管理；机器码每次访问都经 helper 现取。

**④ helper 与 ABI**：机器码只能调用**封闭白名单**里的 helper（H01–H83，`runtime/HelperId.cj`），
入口是 `@C` 函数 `h_dispatch(hid, ctx, args, argc)`；`ctx` 是 8×Int64 的非托管块
（`errCode/site/hwBase/hwCap/hwTop/fnId/flags/dbgBase`）。机器码没有任何直接调用仓颉 API 的通道。

**⑤ 窗口与逃逸**：每次 `call` 开一个句柄窗口（`openWindow`），返回时 `resetWindow` 释放**未逃逸**槽；
逃逸对象（返回的句柄、逃逸闭包及其捕获）走"原地提升"（`moveOutGroup`，ID/gen 不变）并由
`PromotionGroup` 持有，闭包包装的唯一释放路径是 `JitFunction.close()`；单元级 `close()` 进入终态时还会把自己从编译缓存逐出。

**⑥ 失败即回退（deopt）**：`errCode = -1` 表示"这次没算完，请用解释器重放"，桥透明重跑，调用方
无感；其余错误码（1/2/3/6/7/8/16/18/19/21/22…）按 `JitException` 抛出。

---

## 4. 支持矩阵（字节码 vs 机器码）

| 层 | 支持范围 | 依据 |
|---|---|---|
| **字节码**（编译 / 解释执行 / `call`） | **任何能运行仓颉 1.3.x 的平台**（Linux / Windows / macOS，x86_64 / aarch64），与架构无关 | `.fbc` 是纯数据；`Interp` 是纯仓颉 |
| **机器码（JIT）** | **仅 Linux x86_64**、**仅 Linux aarch64** | `backend/JitExecutor.cj`：`OS.current.isLinux` 且 `Arch.current ∈ {X86_64, AArch64}`，否则整单元退解释器 |
| x86_64 额外前提 | **SSE4.1**（`roundsd` 等取整指令）；缺该特性时**含取整指令的单元**整体退解释器 | `X86Lower.floatRoundChecked` / `CpuFeatures.hasSse41` |
| aarch64 额外前提 | 无（无 CPUID 分支） | — |

> 结论：**同一份 `.fbc` 在四个平台上都能跑**；其中 **Linux x86_64 / Linux aarch64 走机器码**，
> Windows / macOS 走解释器（性能不同、语义相同）。

---

## 5. 何时不 JIT（设计使然）

JIT 是加速层，遇到以下情况**整单元退解释器**（`ok = false`），语义不变、只是慢：

| 类别 | 例子 |
|---|---|
| 汇编期禁发 | `DT_NEW`(0xA9)、`DUR_NEW`(0xAA) |
| 运行期设施缺失 | 单元需要常量镜像却 `constBase == 0`；需要入口表却 `fnTableBase == 0` |
| 平台能力 | x86 缺 SSE4.1 且单元含取整指令 |
| 静态不可证明 | 分支汇合处栈深度不一致；发射审计发现内存基址越界（只允许栈/帧/ctx） |
| 未实现 | 未知 opcode（新增指令在补齐 lowering 前一律回退） |

---

## 6. 数据类型与语法

方言是**仓颉的一个子集**：类型全部映射到仓颉标准库（不自定义类型），运算符与字面值如下。

| 类型 | 承载（std） | 字面值 / 构造 | 主要操作 |
|---|---|---|---|
| **Int64** | 标量 | `42`、`-7` | `+ - * / % **`、`< <= > >= == !=`；`/`、`%` 零除 → 3；`Int64(x)` 窄化（`**` 见 §6.6） |
| **Float64** | 标量 | `1.5`、`1.0f64`、`1.5e3f64`、`.123e2f64` | `+ - * /`、比较；`strictFp` 缺省 `true` ⇒ ÷0 报 1，关闭则 IEEE ±Inf |
| **String** | `std.core.String` | `'abc'` / `"abc"`、多行 `'''…'''` / `"""…"""`、`#`×n 原始定界；插值 `"v${x}"` | `+` 拼接、`* 3` 重复、`s[a..=b]`（**码点**索引半开区间） |
| **Range** | `std.core.Range` | `a..b`、`a..=b`，可带 `: step` | `for x in a..b { … }`、端点/步长 |
| **List** | `std.collection.ArrayList` | `[1, 2, 3]`（**常量、共享只读**）、`[]`（运行时新建**可变**空表，需上下文类型） | `xs[i]`、`xs[i] = v`、`for x in xs`；追加/删除为变更型 helper（`LIST_APPEND`/`LIST_REMOVE`，写常量 → 20） |
| **Map** | `std.collection.HashMap` | `{k: v}`（常量只读）、`{}`（可变空表，需上下文类型） | `m[k]` 取、`m[k] = v` 置、`for (k, v) in m` |
| **JSON** | 句柄 16–19（`JsonValue` 谱系） | **反引号字面量**：`` `{"k": 1}` ``（唯一形态，加载期解析一次） | `j["k"]` 读、`j["k"] = v` 写（世界内可变）、成员糖 `j.k`、`is`/`as` 判定；`JsonObject(...)` 构造写法 → 编译错误 |
| **Regex** | `std.regex.Regex` | `/pat/flags`（flags ∈ `i m u`，**顺序无关、可重复**）；`s.regex()` 运行期构造（无 flags） | `re ~ s`（匹配）、`re !~ s`、`re/s/r/g`（全部替换）、`re/s/r/n`（替换 n 次） |
| **Decimal** | `std.math.numeric.Decimal` | **无后缀小数即 Decimal**：`1.23`、`1.5e3`、`1e-3`；`Decimal(...)` | `+ - * /`、比较 |
| **Duration** | `std.core.Duration` | 无字面量（宿主传入或 `DateTime` 差） | `Duration ± Duration`、比较；溢出 → 12 |
| **DateTime** | `std.time.DateTime` | 无字面量（宿主传入） | `DateTime ± Duration`、`DateTime − DateTime → Duration`；越界 → 11 |
| **Closure** | 句柄 12（`JitClosure`） | `{ x => e }`，自动捕获外层局部 | 调用 `f(a)`；逃逸返回用 `callForFn<Fn>`，用完 `close()` |
| **Any** | 句柄 12（`JitAnyBox`） | 由宿主传入，或 `Any` 标注的局部/参数 | 装箱/拆箱（H78/H79）、`is` 判定、作为 `Any` 返回 |

```cangjie
// 各类字面值一览（作为 jit lambda 的返回/局部）
c.compile('{ => 42 }')                       // Int64
c.compile('{ => 1.5 }')                      // Float64
c.compile('{ => 1.23 }')                     // Decimal（无后缀小数）
c.compile('{ x: Int64 => "v${x}" }')         // String（插值）
c.compile('{ => /^[a-z]+$/i }')              // Regex
c.compile('{ => [1, 2, 3] }')                // List（常量只读）
c.compile('{ => { "a": 1 } }')               // Map（常量只读）
c.compile('{ => 1..=5 }')                    // Range
```

**只读常量 vs 可变容器**：非空字面值在**拼装期**构造一次、跨调用共享，写入 → `ERR_READONLY(20)`；
`[]`/`{}` 每次求值新建可变容器（不进常量表），必须有上下文类型（局部标注或实参签名）。

### 6.0 正则字面量与 flags `i` / `m` / `u`

字面量形态 `/pattern/flags`：两个 `/` 之间是 pattern（UTF-8），紧跟的 `i`/`m`/`u` 是 flag。

| flag | 意义 | 具体影响 | 例子（结果） |
|---|---|---|---|
| `i` | **忽略大小写**（`RegexFlag.IgnoreCase`，以 `std.regex` 为准） | 字面量字符与字符类的匹配做大小写折叠；不影响转义序列本身 | `/AbC/i ~ "abc"` → `1`；`/AbC/ ~ "abc"` → `0` |
| `m` | **多行模式** | `^` 除串首外还匹配**每个换行之后**；`$` 除串尾外还匹配**每个换行之前**。**不改变** `.` 是否跨行（无 DOTALL/`s` flag） | `/^b/m ~ "a\nb"` → `1`；`/^b/ ~ "a\nb"` → `0`；`/c$/m ~ "c\nd"` → `1` |
| `u` | **Unicode 模式** | 字符类/`\p{…}` 按**码点**语义匹配（一个元素 = 一个码点，而非一个字节），`\w`/`\d` 等取 Unicode 范围（以 `std.regex` 为准） | `/^\p{L}+$/u ~ "中文"` → `1` |
| 组合 | `i m u` **任意顺序、可重复** | 加载期归一为位域（bit0=i bit1=m bit2=u）；顺序与重复**不进入**去重键、文本化与匹配行为（`/pat/im` ≡ `/pat/mi` ≡ `/pat/ii`） | — |
| 非法 | `i m u` 之外的任何字符 | **加载期拒绝**（`JitException(14)`，`site=-1`，不进入执行期） | `/pat/x` → 14 |

补充：

- **非法/空 pattern 同样加载期 14**（空 pattern 会导致零宽匹配死循环，§11.9）；
- 字面量在**加载期编译一次**并跨调用复用（常量 kind 10，同 `(pattern, flags)` 去重、同 ID）；
- 运行期由字符串构造用 `s.regex()`（`fountain::f_regex` 扩展）：**恒无 flags**；需要 flags 时用字面量形态；
- 正则操作符：`re ~ s`（匹配）、`re !~ s`（取反）、`re/s/r/g`（全部替换）、`re/s/r/n`（替换 n 次）。

### 6.1 多行字符串与行首锚定标记 `>|`

多行串定界为 `'''…'''` / `"""…"""`（另有 `#`×n 原始串）。当**源码缩进**与**内容缩进**
冲突时（典型：串里写 JSON），用行首锚定标记 `>|`：标记连同其前缩进被吞掉，`>|` 之后才是该行内容。

```text
"""{
>|  "k": 1,
>|  "n": [2, 3]
>|}"""
```

| 规则 | 说明 |
|---|---|
| 适用范围 | **仅多行串**（`'''` / `"""`）；单行串与 `#`×n 原始串**不适用**（`>\|` 就是两个普通字符） |
| 有效标记 | 行内**首个非空白位置**的 `>\|`（其前只允许缩进空白） |
| 进入判定 | 串体内**任一行**有有效标记 ⇒ **整串**进入锚定模式；否则普通模式（`a>\|b` 不触发） |
| 标记行 | 标记与其前缩进被消耗；`>\|` **之后**的全部字符 = 该行内容（其中再出现的 `>\|` 是字面文本；只有 `>\|` 的行 = 空串） |
| 非标记行 | **整行原样保留**（不截取、不归一） |
| 首现语义 | `>\|>\|abc` → `>\|abc`；`>\|    >\|` → `    >\|`（只消耗首个非空白位置的那一个标记） |
| 行连接 | 各行内容以 `\n` 连接（`CRLF`/`CR` 先整串归一为 `\n`） |
| 与转义/插值顺序 | 锚定在**转义之前、插值切分之前**：`>\|${x}` 的 `${x}` 正常插值，`>\|` 不进文本 |
| 非标记情形 | `>>\|`、`a>\|b`、`\|>\|` ⇒ 其中的 `>\|` 全是**字面内容**（整行保留） |

> 注意：`>|` **不是整段去缩进（dedent）**——只有含有效标记的行被截取，其余行原样保留。

### 6.2 递归（`recursive`）

自递归用关键字 `recursive(...)`（不是函数名）：

```cangjie
let fact = c.compile('{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }')
fact.call<Int64>([Int64(5)])      // 120
```

降低形态（三个位置各不相同）：

| 位置 | 降低 |
|---|---|
| 顶层 lambda | `CALL_FUNC <entryFn>`（经**函数入口表**，宿主绝对地址） |
| 闭包内 | `LOADL 0`（`locals[0]` 是闭包自身句柄）+ `CALL_CLOSURE` |
| **尾位置** | 实参**逆序 `STOREL`** + `LOOP_BACK <函数入口>`（帧复用，不发 `RET`；尾递归不增长栈） |

### 6.3 嵌套闭包与嵌套闭包递归

```cangjie
// 嵌套闭包：捕获外层局部；内层用 recursive 指代"自己"
let f = c.compile('{ n: Int64 =>
    let inner = { k: Int64 => if (k <= 1) { 1 } else { k * recursive(k - 1) } }
    inner(n)
}')
f.call<Int64>([Int64(4)])         // 24
```

- 捕获按**值/窗口**分类（`CaptureOrigin`），句柄型捕获在逃逸时随闭包一起**原地提升**；
- 内层 `recursive` = 该闭包自身（`LOADL 0` + `CALL_CLOSURE`），不是外层 `entryFn`；
- 内层可继续嵌套（捕获链逐层 `LOAD_CAP`），运行时每层一个闭包对象；
- 闭包**逃逸返回**：`callForFn<Fn>` 拿包装器，调用完 `close()` 释放提升组（否则常驻）。

### 6.4 `as` 语法（转型 / 兜底 / 判定）

| 写法 | 语义 | 失败行为 |
|---|---|---|
| `x as T` | 向下转型；`T` 与 `x` 的静态类型必须相容 | 不相容 → **编译期拒绝**（消息含两侧类型）；运行期不匹配 → **7 `BAD_CAST`**（不记宿主异常 21） |
| `x as T ?? fb` | "转型成功取原对象，否则取 `fb`"；**兜底惰性**（命中时完全不求值） | 不匹配不报错；`fb` 的类型必须是 `T` 或 `T` 的子类 |
| `x is T` | 类型判定，返回 `Bool`（不转型、不抛错） | — |

```cangjie
let pick = c.compile('{ u: User => u as Admin ?? Admin("fallback") }')
// 传 Admin 实例 → 原对象；传 User 实例 → 兜底值
```

补充规则：

- **类名未被跟踪**（例如返回 14 但无 `retName` 的调用）⇒ 编译通过，**运行期**按 `$as$<T>` 判定；
- `??` 只有 `as T ??` 这一种合法组合；`x ?? 0`、`x ? 0` 均为语法/词法错误；
- 兜底表达式仍会被**降级**（其中出现未定义名字 → 编译错误；`x as Int64 ?? (x / 0)` 命中时返回 `x`，兜底不执行）；
- `Any` 的 `as`/`is` 走 Any 通道（装箱 12 → 命中返回对象句柄；未命中按 `as` 语义 22 / 裸 `as` 7）。

### 6.5 ⚠ `JitFunction` 不能作为 jit lambda 的形参

`JitFunction` 是**桥侧执行体**（含 code/常量镜像/入口表/提升组），不是方言值类型：
`Compiler.registerType()` 只接受能映射到 `LocalType` 的宿主类型，`JitFunction` **没有对应码**，
因此不能出现在 lambda 的形参/返回值里（编译期就会被拒）。

要"把 JIT 函数传进 lambda"，用**闭包包一层**，传的是宿主闭包（`HOST_CLOSURE`，码 13）：

```cangjie
let inc = c.compile('{ x: Int64 => x + 1 }')

// ✓ 把 JitFunction 捕获进宿主闭包；跨桥的是"闭包"，不是 JitFunction 本身
let bridge: (Int64) -> Int64 = { n => inc.call<Int64>([n]) }

// lambda 侧把形参声明为宿主闭包类型；下面一行是**示意**（形参类型名以 Compiler 的
// host-closure 签名注册为准），之后按普通调用语法使用
let apply = c.compile('{ f: Fn, n: Int64 => f(n) }')
apply.call<Int64>([bridge, Int64(41)])     // 42
```

要点：`JitFunction` 留在**宿主侧**，只把闭包值送过桥；闭包一旦逃逸出该次调用，
其捕获的 `JitFunction` 由宿主保证存活（建议让 `JitFunction` 的生命周期长于闭包）。

### 6.6 幂运算 `**` 与科学计数法

| 项 | 规则 |
|---|---|
| `**` 类型 | 仅 `(Int64, Int64) → Int64`；其他组合（`1.5 ** 2`、`2 ** 1.5`、`"a" ** 2`）编译期 `TYPE_MISMATCH` |
| 优先级 / 结合 | **4**（高于 `*`/`/`/`%`，低于一元 `-`）、**右结合**：`2 ** 3 ** 2` = 512；`-2 ** 2` = 4 |
| 指数取值 | 必须**非负**（仓颉侧为 `UInt64`，负值类型上不可表达）：运行期负值 → `ERR_ARG_MISMATCH(14)` |
| 溢出 | `ERR_OVERFLOW_I64(3)`（`2 ** 63` 失败）；`x ** 0` = `1`、`0 ** 0` = `1`、`0 ** n` = `0` |
| 实现 | 共享 helper **H84 `ipow`**（快速幂 O(log n)）；三引擎同实现 ⇒ 结果/错误码逐位一致，两后端零改动 |
| 科学计数法（Decimal） | `1.5e3`（=1500）、`3e2`（=300）、`1e-3`（=0.001）、`2.4E-1` |
| 科学计数法（Float64） | `1.5e3f64`、`2e3f64`、`2.4e-1f64`、`.123e2f64`（= 12.3） |
| 前导点 | `.5`、`.5e2`（Decimal）、`.5e2f64`（Float64）均合法 |
| 非法 | `1e`、`1e+`、数字后紧跟标识符、`1.5f32`（方言无 `f32`）→ 词法错误 |

```cangjie
c.compile('{ => 2 ** 10 }')                 // 1024
c.compile('{ => 2 ** 3 ** 2 }')             // 512（右结合）
c.compile('{ => 2 * 3 ** 2 }')              // 18（** 更紧）
c.compile('{ x: Int64 => 2 ** x }')         // x 为负 → 14；溢出 → 3
c.compile('{ => 1.5e3 }')                   // Decimal 1500
c.compile('{ => .123e2f64 }')               // Float64 12.3
```

## 7. FAQ

### Q1 对象由谁维持：JIT 侧还是仓颉侧？

**仓颉侧。** 机器码只持 `Int64` 句柄；对象本体在 `HandleTable.objs: ArrayList<Any>`（仓颉堆，
GC 管理）。创建一律走 `allocValue` → `HandleTable.append`（`runtime/HelperCore.cj:77-83`）：

```cangjie
public static func append(ctx: JitContext, obj: Any, tok: UInt16): Int64   // runtime/HandleTable.cj:486
```

自定义类实例（tag 14）、`String`(4)、`Decimal`(6)、`Range`(7)、`Duration`(8)、`JitRegex`(9)、
`List`(10)、`Map`(11)、`JitAnyBox`(12)、`JitClosure`(12/13)、JSON 节点（16–19）都在同一张表里。

### Q2 GC 会搬运对象，机器码怎么还能正确访问？

**机器码从不解引用对象指针。** 句柄是索引，每次访问都经 helper 在仓颉侧现取当前引用
（`runtime/HandleTable.cj:567`）：

```cangjie
public static func getAny(id: Int64): ?Any {
    ...
    } else if (!alive[i] || gens[i] != genOf(id)) { None }
    else { Some(objs[i]) }
```

GC 移动对象时更新的是 `objs[i]` 与 helper 栈上的受管局部变量（有栈图），**机器码里的 Int64 不变**。
`pin`/`pinHostObject` 拿到的 `Object` 只在**同一次 helper 调用内**使用，不跨 helper、不写回机器码；
常量镜像/入口表存的是 **cell 与代码地址**，不是对象指针。

### Q3 JIT 返回后对象是否驻留？会不会泄漏？

分三类：

| 情形 | 处理 | 是否驻留 |
|---|---|---|
| 未逃逸（窗口内） | `call` 的 `finally` → `resetWindow(-1)`：`alive=false`、`objs[i]=0`、`gen+1` | 不再被 f_jit 引用 ⇒ 由 GC 回收 |
| 返回值句柄 | `releaseReturnHandle` 在解包后立刻归还（`JitFunction.cj:477-487`） | 否 |
| 逃逸闭包 / 其捕获 | `PromotionGroup` 持有；**包装实例 `close()` 释放，单元 `close()` 终态时级联兜底** | 单元存活期间宿主不释放就一直驻留（契约，非 bug） |

常量槽（`constFlags`）永不释放（单元常量池，数量有界）；`HandleTable` 的底层数组只增不减，
上限 `capacityLimit = 1048576`（`:92`），属容量水位而非泄漏。

### Q4 不逃逸的嵌套闭包及其数据，是否随 `JitFunction` 销毁？

**随"这次调用"销毁，而不是随 `JitFunction`。** 闭包是 H54 创建的 `JitClosure(fnId, captured: Array<Int64>)`
（`runtime/Helpers.cj:1010-1021`），进本次调用窗口；捕获是 **cell（句柄）**，指向的槽也在同一窗口。
调用结束 `resetWindow` 一次性释放 ⇒ 旧 ID 失效（`gen+1`），`JitClosure` 失去引用后被 GC 回收。
`JitFunction` 只持编译产物，`close()` 只释放提升组。

### Q5 每次调用返回时，是否清除本次产生的数据？

**是，四条出口（正常 / 抛错 / 中断 / DEOPT 重放）统一在 `finally` 收尾**（`JitFunction.cj:454-467`）：

```cangjie
} finally {
    if (helpers.size > 0) { UserHelperTable.pop() }
    marshal.cleanup()          // pinned 的非逃逸槽
    IterTable.clearAll()       // 迭代器游标
    HandleTable.resetWindow(-1)
    if (!dump.isNull()) { DbgDump.freeDump(dump) }
    JitContext.free(ctx)
}
```

重入安全：`openWindow` 会压栈保存外层窗口，`resetWindow` 收尾时弹回，宿主闭包回调重入不会清掉外层槽。

### Q6 逃逸闭包如何继续访问它依赖的数据？

**原地提升 + 提升组。** 返回闭包时 `CallMarshal.unboxClosure` 递归提升闭包槽与全部句柄型捕获
（`CallMarshal.cj:216-269`）：

- `group.add(id)` → `HandleTable.moveOutGroup`：`escapeFlags=true`、迁出窗口记账、**ID/gen 不变**
  ⇒ `resetWindow` 跳过、槽不被复用；
- 包装器 `JitFunction` 持 `owner + closureId + group`，调用时经 `owner.invokeClosure` 用
  `closure_cap(h,i)` 逐个取捕获；
- 释放：`close()` → `PromotionGroup.releaseAll()` → `releaseEscaped`。

容器捕获是**槽级、不级联**（§14.6）：容器元素的句柄不需要提升——元素在写入时已经
`cellToAny`（= `getAny`）转成宿主引用，随容器存活。

### Q7 `close()` 之后还能再编译同一份源码吗？

能。`close()` 成功进入终态时会把单元从 `CompileCache` 逐出，同源再编译会重新走管线并返回**新**单元；
旧句柄仍然失效（调用 → 19）。`close()` **不碰缓存**——它只释放闭包捕获，单元继续可用。
若 `close(timeoutMs)` 因排空超时返回 `false`，单元恢复可用、缓存条目保留（不逐出，避免同键两份产物）。

---

## 8. 已知限制

- 机器码仅 Linux x86_64 / aarch64（其余平台解释执行）；
- x86_64 需 SSE4.1（缺则不 JIT 含取整指令的单元）；
- 回边每轮一次 H22 `interrupt_poll`；紧循环上该调用（内部含一次分配）成本显著，已记入
  `doc/spec/f-jit-m1/verify.md` 待优化；
- 逃逸闭包建议显式 `close()`；漏调时单元卸载会级联释放，单元长期存活则提升组一直驻留；
- 细节规格见 `doc/jit-bytecode-m1.md` / `doc/design-m1.md` / `doc/plan-m1.md`，验收见
  `doc/spec/f-jit-m1/verify.md`，性能见 `doc/perf-m1.md`。
