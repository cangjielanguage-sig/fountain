# fountain实现思想与应用第十八弹

##### ——仓颉方言编译器与 JIT

项目链接：https://gitcode.com/Cangjie-TPC/fountain

把「让用户写一段脚本，在进程里跑起来」做到底，迟早要回答一个问题：

> 这段脚本和宿主语言是什么关系？

如果脚本是另一门语言，就要维护两套类型系统、两套错误模型；如果脚本就是宿主语言的子集，用户可以复用已有的类、函数和思维习惯，但编译器要承担「子集」带来的所有边界。f_jit 选择后者：它编译的是**仓颉方言**，不是一门新语言。

```
源码（仓颉方言）
  → 词法/语法 → AST → 类型检查 → 栈式字节码（.fbc，与架构无关）
      → 解释器（语义唯一权威）
      → x86_64 机器码（Linux）
      → aarch64 机器码（Linux）
```

三条设计原则贯穿全文：

1. **解释器是语义权威**，机器码只是加速层；拿不准就退回解释器，结果必须逐位一致。
2. **方言是仓颉的子集**，类型全部映射到标准库，不自定义类型。
3. **宿主与脚本的边界只有一条**：`Compiler` 注册宿主能力，`JitFunction.call<T>` 进出。

---

## 一、API：编译、注册、调用、释放

### 1.1 最小可用

```cj
import fountain::f_jit.*

main() {
    let c = Compiler()                       // 等价于 Compiler(CompileOptions(DummyDiagnosticsSink()))
    c.registerType<User>()                   // User 已标 @JitBind，暴露宿主类给方言
    let f = c.compile("{ u: User => u.name }")
    let name = f.call<String>([User("bob", 1)])
    println(name)
}
```

`Compiler` 只做两件事：维护注册表、把源码编译成 `JitFunction`：

| 成员 | 说明 |
| --- | --- |
| `Compiler()` / `Compiler(opts)` / `Compiler(name, opts, maxPredefined)` | 默认诊断 sink 是 `DummyDiagnosticsSink`；预定义函数上限默认 256 |
| `compile(source: String): JitFunction` | 唯一编译入口；结果进编译缓存 |
| `registerType<T>() where T <: Object` | 注册类，自动取 `@JitBind` 的登记 |
| `registerInterface<I>()` | 注册接口（**无** `T <: Object` 约束），接口必须 `@JitBind` |
| `registerClass(desc: ClassDescriptor)` | 完全手工，不走反射 |
| `registerFunction(f: PredefinedFunction)` | 注册宿主函数；重名抛 `DuplicateRegistration` |
| `unregisterFunction(name)` / `hasFunction(name)` / `hasClass(name)` | 注册表查询 |

`CompileOptions` 的公开字段只有四个：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `jit: JitMode` | `Auto` | `Auto` / `Force` / `Off`；**`Auto` 与 `Force` 行为相同**，只有 `Off` 强制解释器 |
| `strictFp: Bool` | `true` | 严格浮点：`Float64` 除以 0 报 `1 DIV_ZERO`，关闭才走 IEEE ±Inf |
| `verMajor: UInt16` | `3` | 字节码版本，参与缓存键 |
| `cpuFeatures: UInt64` | 0 | 预留字段，当前未消费 |

### 1.2 调用与返回

`JitFunction` 是唯一编译产物，也是唯一可调用对象：

```cj
public class JitFunction <: Resource {
    public func call<T>(args: Array<Any>): T
    public func call<T>(args: Array<Any>, options: CallContext): T
    public func callForFn<Fn>(args: Array<Any>): JitFunction   // 返回闭包包装器
    public func close(): Unit                                  // 不等待在飞调用
    public func close(timeoutMs: Int64): Bool                  // 排空，超时返回 false
    public func isClosed(): Bool
    public func isJitBacked(): Bool
}
```

带截止时间：

```cj
import fountain::f_jit.base.CallContext      // 注意：CallContext 未在根包再导出

let ctx = CallContext(deadline: Some(DateTime.now() + Duration.second))
let v = f.call<Int64>([Int64(100_000_000)], ctx)   // 到期抛 InterruptedException
```

两个容易踩的点：

- **`call` 是进程级串行的**。`JitFunction` 内部有一把静态 `callMtx`，包住 `enter → callLocked → exit`；原因是 `HandleTable` 只有一个活动窗口，并发调用会互相清窗。同一线程的宿主闭包重入不受这把锁约束（重入靠窗口栈）。
- **`CallContext` 在 `fountain::f_jit.base`**，`import fountain::f_jit.*` 拿不到它。

### 1.3 关闭：单元级与闭包级是两件事

| 对象 | `close()` 的语义 |
| --- | --- |
| 入口 `JitFunction`（`compile` 的返回值） | **卸载单元**：级联释放它产出的逃逸闭包 → 进入终态 → 释放代码内存 → 从编译缓存逐出 |
| `callForFn` 返回的包装器 | **只释放本闭包**捕获的提升槽；单元继续可用 |

`close()` 不等待在飞调用，直接丢弃排空结果；`close(timeoutMs)` 会忙等自旋直到在飞调用结束，超时返回 `false` 并把单元恢复为可用状态。单元卸载后，旧句柄再调用抛 `JitException(19 CALL_CONTRACT)`；同源再编译会得到**新**单元。

### 1.4 宿主侧宏：把反射调用换成静态绑定

三个宏都只在**宿主编译期**生效，方言源码里不出现宏：

| 宏 | 作用 |
| --- | --- |
| `@JitBind` | 把类/接口的公共成员展开成类型化绑定；生成包级 `jitBindEnroll_<类名>` 登记，不修改类本身 |
| `@IgnoreJitBinding` | 让单个成员退出注册表（宿主仍可调用，方言看不到）；同名重载整组跳过 |
| `@JitSignatures` | 登记闭包形参签名，避免运行期 `FunctionTypeInfo.apply` |

覆盖规则：实例方法 → `PublicMethod`；实例字段 → getter（`var` 带 setter）；实例属性 → getter + `set<Name>`；`init` → 每条一个 `PublicCtor`；静态函数/只读静态字段/只读静态属性 → `PredefinedFunction`。私有成员、泛型方法、`static var`、`static mut prop` 不展开。

**接口必须标 `@JitBind`**：反射无法 `apply` 抽象方法，未标注的接口在 `registerInterface<I>()` 处抛 `RegistrationException`。父接口方法在注册期并入，子接口变量可以直接访问父接口成员。

`registerType<T>()` 不传 `bindings` 时自动取宏的登记；传了则与宏登记**合并**（同名以显式为准），不是整体覆盖。没标 `@JitBind` 的类会退回反射路径：更慢，且引用型成员受「默认拒绝」策略约束。

手工注册只在无法用宏/反射时使用：

```cj
let desc = ClassDescriptor(
    name: "LegacyUser",
    fields: [PublicField(name: "name", type: LocalType.STRING, index: 0, mutable: true, typeRef: None)],
    methods: [PublicMethod(name: "greet", bind: greetFn)],
    ctors: [PublicCtor(params: [LocalType.STRING], adapter: { a => LegacyUser(a[0] as String) })],
    parents: [])
c.registerClass(desc)
```

手工注册不做任何反射：字段下标、方法绑定、构造适配器全由调用方保证；`parents` 只影响静态子类型判定，不参与成员解析。

---

## 二、支持的数据类型：白名单，不是「仓颉全类型」

方言的类型集合是硬编码白名单（`Parser.builtinTypeOf`）：

| 方言类型 | 承载 | 说明 |
| --- | --- | --- |
| `Int64` | 标量 | 唯一整数类型 |
| `Float64` | 标量 | 唯一浮点类型 |
| `Bool` / `Unit` | 标量 | `Unit` 可作返回 |
| `String` | `std.core.String` | 单行/多行/原始串、插值 |
| `Decimal` | `std.math.numeric.Decimal` | 无后缀小数默认是 Decimal |
| `DateTime` / `Duration` | `std.time` / `std.core` | 无字面量，只能宿主传入或运算产生 |
| `Range` | `std.core.Range` | `a..b`、`a..=b`、`: step` |
| `Regex` | `std.regex.Regex` | `/pat/flags` 字面量 |
| `List` | `std.collection.ArrayList` | 非空字面量是只读常量 |
| `Map` | `std.collection.HashMap` | 非空字面量是只读常量 |
| `Closure` | 句柄 12 | lambda |
| `JsonValue` / `JsonObject` / `JsonArray` / `JsonNull` | JSON 谱系 | 反引号字面量 |
| `Any` | 装箱 | 宿主传入或 `Any` 标注 |
| 已注册类名 | 宿主对象 | 经 `registerType`/`registerInterface`/`registerClass` |
| `(T…) -> R` | 宿主闭包 | 需 `@JitSignatures` 或运行期签名登记 |

**不支持**：`Int8/Int16/Int32`、`UInt*`、`IntNative`、`Float16/32`、`Rune`、`Option`、`Set`/`HashSet`、`HashMap`（语言层写 `Map`）、`ArrayList`（语言层写 `List`）、元组类型、泛型声明。

未注册的类名会报：`未注册的类名「X」（M3 类型集：内建类型 / Any / JSON 谱系 / 已注册类名 / (T…) -> R）`。

### 2.1 `call<T>` 的 `T` 是另一张白名单

`call<T>` 按 `TypeInfo.of<T>()` 的简单名映射到类型码：

| `T` | 类型码 |
| --- | --- |
| `Int64`/`Float64`/`Bool`/`Unit`/`String`/`Decimal`/`DateTime`/`Duration`/`Regex` | 0/1/2/3/4/5/6/7/9 |
| 名字以 `Range` 开头 | 8 |
| 名字以 `ArrayList` 开头 | 10 |
| 名字以 `HashMap` 开头 | 11 |
| `JitClosureId` | 12 |
| `Any` | 15 |
| `JsonValue`/`JsonObject`/`JsonArray`/`JsonNull` | 16/17/18/19 |
| 已注册类（`ClassTypeInfo`/`InterfaceTypeInfo`） | 14 |

不允许的类型统一 `JitException(19 CALL_CONTRACT)`，消息分三种：

- `实参个数不符：期望 N，实际 M`
- `T 与返回类型不符（§8.2 第 5 步）`
- `T 不是可解包类型`

`Option`、`Int32` 等都会落到第三条；容器要按 `ArrayList`/`HashMap` 的名字匹配（方言源码里写 `List`/`Map`，返回值类型要写 `ArrayList`/`HashMap`）。**没有隐式宽化、不接受 `null`**。

宿主对象（14）的规则更严：实参必须是声明类型的实例，且不能是 `null`；失败消息是 `实参不是声明类型「C」的实例` 或 `null/非对象不可作 14 型实参`。

### 2.2 谁持有对象

机器码不持有对象指针，只持 `Int64` 句柄：

```
句柄 = idx:u32 | tag:u16 | gen:u16
```

对象本体在仓颉堆的 `HandleTable.objs: ArrayList<Any>` 里，由 GC 管理；GC 搬运对象时更新 `objs[i]`，机器码里的 Int64 不变，每次访问都经 helper 现取。

每次 `call` 开一个句柄窗口，返回时 `resetWindow` 释放**未逃逸**槽（`gen+1`，旧 ID 失效）。返回值句柄在解包后立刻归还；逃逸闭包及其捕获走「原地提升」，ID/gen 不变，由 `PromotionGroup` 持有，直到包装器或单元 `close()`。

---

## 三、语法：单一 lambda 入口的仓颉子集

### 3.1 入口形态是硬约束

源码**必须且只能是一个 lambda 字面量**：

```text
{ u: User => u.name }
{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }
```

- 形参必须是 `name: Type`，**不支持具名参数与默认值**，`=>` 不可省略；
- 语句集只有：`let/var` 声明、赋值、多重赋值、`if`、`while`、`for-in`、`return`、表达式语句、块、`break`、`continue`；
- **没有** `match`、`do-while`、`try/catch/throw`、`func/class/struct/interface/enum` 声明、`import`、泛型声明；
- 表达式集包括：字面量、变量、二元/一元、`if` 表达式、调用、闭包、IIFE、字符串插值、正则运算、Range、List/Map 字面量、多重赋值右侧的元组、`recursive`、下标、字段/方法访问、构造、`as`/`is`、JSON 字面量。

`{` 有三种含义，靠语法消歧：含 `=>` 是闭包；空或顶层有 `:` 是 Map 字面量；否则是块。

### 3.2 运算符与优先级

从低到高：

```
as / as…??…  →  ||  →  &&  →  is / == != / < <= > >=  →  |  →  ^  →  &  →  << >>  →  ..
  →  + -  →  ~ !~  →  * / %  →  **  →  一元 - ! ~  →  后缀
```

`**` 右结合且优先级高于 `*`：`2 ** 3 ** 2 = 512`，`-2 ** 2 = 4`。`~`/`!~` 夹在加法与乘法之间（`a + b ~ c` 是 `a + (b ~ c)`）；Range 的 `..` 低于加减、高于移位。

`??` 只有一种合法组合：`x as T ?? fallback`；裸 `x ?? 0` 是语法错误，单个 `?` 是词法错误。

### 3.3 `as` 的三种形态

| 写法 | 语义 | 失败行为 |
| --- | --- | --- |
| `x as T` | 向下转型，`T` 与 `x` 静态类型必须相容 | 不相容编译期拒绝；运行期不匹配 `7 BAD_CAST` |
| `x as T ?? fb` | 成功取原对象，否则取 `fb`；**兜底惰性** | 不报错；`fb` 必须是 `T` 或 `T` 子类 |
| `x is T` | 类型判定，返回 `Bool` | 不抛错 |

`as` 到函数类型（闭包）**不支持**：编译期直接报 `as 暂不支持函数类型：形参码不在符号表里，无法静态比对签名`。

### 3.4 字面值：几处与仓颉不同

| 字面值 | 方言语义 |
| --- | --- |
| `42` / `-7` | `Int64` |
| `1.5` / `1.23` / `1e-3` | **Decimal**（无后缀小数） |
| `1.5f64` / `.123e2f64` | `Float64`；没有 `f32` 后缀 |
| `"v${x}"` / `'''…'''` | String；多行串支持 `>\|` 行首锚定 |
| `/pat/im` | Regex 字面量；flags 只有 `i`/`m`/`u` |
| `` `{"k":1}` `` | JSON 字面量；唯一形态，加载期解析一次 |
| `[1, 2]` / `{ "a": 1 }` | 非空容器：**跨调用共享的只读常量**，写入 `20 READONLY` |
| `[]` / `{}` | 每次求值新建的可变容器，必须有上下文类型 |
| `1..=5` | Range |
| `2 ** 10` | 仅 `(Int64, Int64) → Int64` |

`>|` 只作用于多行串：行首首个非空白位置的 `>|` 连同缩进被吞掉，其后才是内容；非标记行整行保留。它不是 dedent，也不作用于单行串与原始串。

正则字面量在加载期编译一次，同 `(pattern, flags)` 去重；空 pattern 与非法 pattern 在加载期报 14。运行期由字符串构造用 `s.regex()`，恒无 flags。

---

## 四、自递归：`recursive` 是关键字，不是函数名

方言里没有命名函数声明，lambda 也没有名字，所以自引用必须有一个显式通道——这就是 `recursive`：

```cj
let fact = c.compile("{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }")
fact.call<Int64>([Int64(5)])      // 120
```

### 4.1 调用位置与尾位置

| 位置 | 降低 |
| --- | --- |
| 顶层 lambda | `CALL_FUNC <entryFn>`（经函数入口表） |
| 闭包内 | `LOADL 0`（闭包自身句柄）+ `CALL_CLOSURE` |
| **尾位置** | 实参逆序写形参槽 + `LOOP_BACK <入口>`，帧复用、不发 `RET` |

尾递归不增长栈；非尾递归在解释器里靠 `CALL_FUNC` 再入 `run`，吃宿主栈，机器码侧只在回边处发栈守卫（溢出则 deopt 回解释器）。

### 4.2 `recursive` 也可以当右值

把「自己」当成一个闭包值用：

```cj
let f = c.compile("{ n: Int64 =>
    let outer = recursive
    let inner = { m: Int64 => if (m <= 0) { 0 } else { outer(m - 1) } }
    if (n <= 0) { 0 } else { inner(n - 1) }
}")
f.call<Int64>([Int64(3)])        // 0
```

- 闭包内：`LOADL 0` → `CLOSURE`，**不新建**闭包对象，与外层是同一个句柄；
- 顶层（非闭包）：合成一个 adapter 闭包转调 `entryFn`；
- 该值可存局部、作实参、被内层闭包捕获；逃逸时随提升组一起提升。

注意：`outer` 与当前闭包是同一个闭包，`{ => outer() }` 一旦调用就是无终止条件的自递归。

### 4.3 解析优先级与限制

名字解析顺序被冻结为：`recursive` → 宿主函数注册表 → HostClosure 形参/局部 → 未定义。**即使宿主注册了名为 `recursive` 的函数，也仍然是关键字**。

方言里没有第二种自引用方式；不能用函数名、不能把 lambda 赋给变量后按名字调用自己。

---

## 五、嵌套闭包：捕获是创建时刻的快照

### 5.1 捕获规则

```cj
let f = c.compile("{ n: Int64 =>
    let inner = { k: Int64 => if (k <= 1) { 1 } else { k * recursive(k - 1) } }
    inner(n)
}")
f.call<Int64>([Int64(4)])        // 24
```

- 内层 `recursive` 指**该闭包自身**（`LOADL 0` + `CALL_CLOSURE`），不是外层 `entryFn`；
- 内层可以继续嵌套，捕获链逐层 `LOAD_CAP`，运行时每层一个闭包对象；
- **捕获是创建时刻的值快照，不是引用绑定**：闭包创建后外层再改变量，内层看不到；闭包内对捕获变量的赋值也不会写回外层；
- 捕获分类为 `VALUE`/`CONSTANT`/`PARAMETER`/`WINDOW`，句柄型且非常量的捕获在逃逸时需要提升。

### 5.2 逃逸闭包

闭包作为返回值时，用 `callForFn<Fn>` 拿包装器：

```cj
let f = c.compile("{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }")
let g = f.callForFn<(Int64) -> Int64>([Int64(7)])
println(g.call<Int64>([Int64(1)]))   // 8
g.close()                            // 释放捕获的提升槽，单元仍可用
```

- 跨桥返回 `JitClosureId`（值类型，拷贝只复制 ID）；要调用必须用 `callForFn` 包装；
- 逃逸时 `promoteClosureGraph` 递归提升闭包槽与全部句柄型捕获，ID/gen 不变，`resetWindow` 跳过；
- 容器捕获是**槽级、不级联**：容器元素的句柄在写入时已转成宿主引用，随容器存活；
- 包装器 `close()` 只释放本闭包；漏调时单元 `close()` 会级联兜底，但单元长期存活时提升组会一直驻留。

### 5.3 闭包不能作为 `JitFunction` 传递

`JitFunction` 是桥侧执行体，不是方言值类型，**不能出现在 lambda 的形参/返回值里**。要把 JIT 函数传进脚本，用它包一层宿主闭包：

```cj
let inc = c.compile("{ x: Int64 => x + 1 }")
let bridge: (Int64) -> Int64 = { n => inc.call<Int64>([n]) }
// 脚本侧把形参声明为宿主闭包类型，调用 f(n)
```

---

## 六、方言对仓颉的扩展与改写

这一节回答「哪些语法是 f_jit 加的、哪些是改了语义的」。

### 6.1 新增的语法

| 扩展 | 形态 | 为什么需要 |
| --- | --- | --- |
| `recursive` | 调用 `recursive(args)` / 右值 `recursive` | 匿名 lambda 没有名字，自递归必须有通道 |
| `as T ?? fallback` | 转型失败取兜底 | 脚本里「取不到就用默认值」太常见，避免写 `if (x is T)` |
| 正则字面量 | `/pat/flags` | 脚本里正则密度高，字符串 + `Regex(...)` 太啰嗦 |
| 多行串锚定 | `>\|` | 源码缩进与 JSON 内容缩进冲突时，保住内容 |
| JSON 字面量 | `` `{"k":1}` `` | 脚本里构造 JSON 的高频需求，避免一堆 `JsonObject` 调用 |

### 6.2 改变的语义

| 点 | 仓颉 | 方言 |
| --- | --- | --- |
| 无后缀小数 | `Float64` | **`Decimal`**；要 `Float64` 必须写 `f64` |
| `**` | Int64 / Float64 | **仅 Int64 × Int64** |
| `??` | 空值合并 | **只能跟在 `as T` 后面**，语义完全不同 |
| 非空容器字面量 | 每次求值新建 | **跨调用共享的只读常量**，写入报 20 |
| 闭包捕获 | 引用语义 | **创建时刻的值快照** |
| 命名/默认参数 | 支持 | **不支持**，`=>` 不可省 |
| `Option` / `null` | 支持 | **不支持**，宿主也不能传 `null` |
| `match` / `try` / `func` / `class` | 支持 | **不支持**（子集收窄） |

最后一条经常被误解为「还没实现」；实际上它是设计选择：方言入口只有一个 lambda，复杂控制流应该留在宿主侧，脚本只做表达式级别的编排。

---

## 七、JIT 的执行边界

| 层 | 支持范围 |
| --- | --- |
| 字节码 / 解释器 | 任何能跑仓颉 1.3.x 的平台（Linux / Windows / macOS，x86_64 / aarch64） |
| 机器码 | **仅 Linux x86_64**、**仅 Linux aarch64** |
| x86_64 额外前提 | SSE4.1（缺该特性时，含取整指令的单元整体退解释器） |

`JitMode.Auto` 与 `Force` 在代码上等价，只有 `Off` 强制解释器；平台不满足、常量镜像缺失、入口表缺失、未知 opcode、分支汇合栈深不一致、发射审计失败等，都会让**整个单元**静默退回解释器。

运行期还有一种「退化」：机器码执行中 `errCode = -1` 表示 deopt，桥用同一个 `ctx` 透明重跑解释器，调用方无感；其余错误码按 `JitException` 抛出。

---

## 八、设计取舍与已知限制

1. **`call` 全局串行**。单窗口 `HandleTable` 决定了并发调用必须排队；宿主闭包重入不受影响（同一线程、窗口栈）。要并行执行多个脚本，只能多进程或多个 `HandleTable`（当前未提供）。
2. **语义权威是解释器**。机器码只做加速；任何不一致都以解释器为准，三引擎要求结果/错误码/site/报告逐位一致。
3. **没有 `Option`/`null`**。`call<T>` 也不接受 `Option`，脚本里的「空」只能靠 `JsonNull`、空串、哨兵值表达。
4. **没有 `match`/`try`**。错误通过 `JitException` 抛出，脚本内没有捕获手段；需要容错就在宿主侧包一层。
5. **闭包捕获是快照**。不要用「闭包内改外层变量」做状态传递；状态应该放容器或宿主对象里。
6. **非空容器字面量只读**。需修改就用 `[]`/`{}` 新建，或从宿主传入可变容器；对常量写入报 `20 READONLY`。
7. **`close()` 是忙等自旋**。`close(timeoutMs)` 没有 sleep，超时精度依赖自旋次数；长流程里不要用超大 timeout。
8. **`JitMode.Force` 不是「强制 JIT 失败就报错」**，它与 `Auto` 行为相同；平台不支持时仍然静默退解释器。
9. **`JitFunction` 不能过桥**。要传给脚本就包成宿主闭包；否则编译期就会被拒。
10. **手工注册没有反射兜底**。字段下标/类型码写错在构造期抛 `JitCallContract`；能标 `@JitBind` 就不要手工写 `ClassDescriptor`。
11. **正则 flags 的源码级校验与 API 级不同**。`/pat/x` 不会在加载期报 14（`x` 被当作后续标识符），只有 `ConstRegistry.addRegex(pattern, flags: String)` 这条 API 才会因非法字符报 14。
12. **深递归吃宿主栈**。解释器把栈守卫当 no-op，非尾递归过深会栈溢出；尾递归走 `LOOP_BACK`，不增长栈。
