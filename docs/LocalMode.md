# fountain 与 local mode

> 状态：评估文档（2026-11-21）
>
> 依据：仓颉官方开发指南 `dev-guide/source_zh_cn/modal_type/` 下的 `modal_overview.md`、`local_mode_rules.md`、`exclave.md`、`copyable_and_demode.md`，以及 `Appendix/compile_options.md`、`Appendix/runtime_env.md`、`Appendix/keyword.md`。
>
> SDK 前提：`1.3.0-alpha.20261112001016`（std 已合入 local mode，`Equatable`/`Comparable` 等带 `@local!` 重载）。local mode 仍是实验特性，语法、规则、编译选项都可能在后续版本变化。
>
> 说明：本文的 API 支持结论以官方文档为准；`StringBuilder`、`ByteBuffer`、`String.fromUtf8`、`InputStream.read`、`OutputStream.write`、`JsonValue` 等是否提供 local 重载，文档未逐一列出，落地前必须用附录 A 的探针实测。3.4 的 `LocalEquatable`/`LocalComparable` 与 DataAssist 设计已在 Windows cjnative SDK 上用探针编译运行验证（见 3.4「实测结论」）。

---

## 0. 结论摘要

1. local mode 降低的是**峰值内存**，不是吞吐。它把“函数内临时对象”分配在线程的 local region，函数返回时整块释放，不等 GC；分配本身仍要付成本。
2. 模态会沿调用链传播：local 值不能传给普通（`@ ~local`）形参、不能返回、不能进字段/缓存/全局、不能进 spawn。因此它适合“函数内创建、函数内用完”的临时区，以及“只在模块内部调用链传递”的中间对象；不适合“构建结果对象并跨模块返回”的路径。
3. `f_base` / `f_data` 已经启用 local mode（`LocalEquatable` / `LocalComparable`、`@DataAssist` 的 local hook）；其余模块生产代码目前基本没有 `@local!`/`@local?`/`exclave`。历史遗留的 std 模态影响见 `f_data/doc/spec/fix-dataassist-local-mode/`。
4. 本次采用**函数级强制规则**：函数体内创建且不逃逸的实例 → `@local!`；只在模块内部调用链传递的实例 → `@local!`。下游参数受“外部 local! 不能直接转发”限制时写 `@local?`，返回 local 用 `exclave`。公开 API、接口方法、跨线程、FFI、泛型入口仍是边界。
5. 全仓按上述规则逐函数审计；满足条件的函数在 2.5 表中列出并给出声明改法。收益最大的仍是 **f_svg**（`analyticCoverage` 的 `width * height` 累加器）和 **f_llm**（`KnowledgeChunker.split` 的 `ArrayList<Rune>`），但不再局限于这两个模块。
6. fountain 里多数热点用 local mode 收益很小甚至为负；结构性优化的收益更大，例如 `f_security` 每请求解析两次 JWT、`f_email` Base64 三重实体化、`f_log` 每条日志重新编译模板。
7. 面向 local-mode 发版（`1.3.10xx` 是最后一个无 local mode 兼容版本），`f_base` 新增 `LocalEquatable` / `LocalComparable`（继承 std `Equatable` / `Comparable`）：抽象成员是 hook `localEq` / `localCompare`，`@ local?` 的 `==` / `compare` 默认转调 hook，普通与 `@ local!` 重载再转调 `@ local?`；保留 `is Equatable` / `is Comparable`。`@DataAssist` 的 `equal` / `compare` 已生成普通实现与 local hook，并在 WSL 测试通过（见 3.4「落地状态」）。

---

## 1. local mode 详解

### 1.1 机制

仓颉对象默认分配在 GC 堆，由 GC 在不确定时间回收。local mode 用类型描述“这个对象不会离开当前函数”：

- 编译期检查对象确实没有逃逸；
- 运行期把这类对象分配在当前函数专属的 **local region**（与 GC 堆内部的 region 不是同一个概念）；
- 函数返回时整块 local region 一次性释放，不需要等待垃圾回收。

官方文档明确：local mode 的收益体现在**峰值内存**，而不是吞吐量。适合“函数内创建、函数内用完、体积较大或数量较多”的临时对象。

### 1.2 开启方式

命令行：

```shell
cjc --experimental --enable-local-mode main.cj -o main
```

cjpm 按模块开启（`compile-option` 只对当前模块生效）：

```toml
[package]
compile-option = "--dy-std --experimental --enable-local-mode"
```

要点：

- 必须同时给 `--experimental` 和 `--enable-local-mode`；cjpm 没有单独的 local mode 配置项。
- 依赖模块要用 local mode，需要在各自的 `cjpm.toml` 中开启。
- 入口模块可以用 `override-compile-option` 统一开启，但这样**所有依赖模块中的 `exclave`、`demode` 都会成为关键字**。本仓库约定**不修改 `override-compile-option`**，只在各模块的 `compile-option` 里开启 local mode。
- 未开启时：
  - `exclave`、`demode` 是普通标识符；
  - 使用 `@ local!`、`@ local?`、`@ ~local` 会报 `local mode is disabled`；
  - 调用参数/返回值带模态的函数、调用 `this @ local!` 的成员函数、访问 `@ local!` 属性，都需要开启；
  - **导入**含模态声明的包不受影响，包里不涉及 local mode 的函数和变量可以照常使用。
- local mode 的编译产物不保证跨 SDK 版本兼容；用了 local mode 的包及其依赖方要用同一版本 SDK 重新编译。
- cjfmt、cjlint、LSP、cjdb 不保证识别或完整支持 local mode。

### 1.3 三种 mode 与子类型

| 写法 | 含义 |
| --- | --- |
| `T @ ~local` | 非 local。可以自由保存、返回、传递，与普通对象完全相同 |
| `T @ local!` | 一定是 local。生命周期限定在当前函数（或调用者）的 local region 内，不能逃逸 |
| `T @ local?` | 可能是 local。按 local 的要求限制使用 |

- 不写 mode 等价于 `@ ~local`，所以开启 local mode 后已有代码的类型含义不变。
- `@ ~local` 和 `@ local!` 都是 `@ local?` 的子类型。
- `@ ~local` 与 `@ local!` 之间没有子类型关系；对未实现 `Copyable` 的类型，两者不能互相赋值。
- `local` 不是关键字，只有出现在 `@` 之后才表示 mode。

mode 可以写在：局部变量类型、函数参数/返回类型、函数类型、构造调用之后（`C() @ local!`）、实例成员属性类型、嵌套函数的 `func` 之前。不能写在：class/struct 的实例成员变量声明处（成员的 mode 由实例决定）、泛型实参内部（`Array<String @ local!>` 非法）、元组元素或 `?T` 的 `T` 内部（mode 标在整个类型上）。

### 1.4 逃逸与赋值规则

`@ local!` 的值分两类：

- **外部 local!**：函数的 `@ local!` 参数，以及通过它访问到的成员、元组元素、`VArray` 元素。由调用者创建，属于调用者的 local region。
- **内部 local!**：在当前函数中创建的 `@ local!` 值。属于当前函数的 local region，函数返回时释放。

赋值规则（针对非 `Copyable` 类型）：

| 目标变量 | 可以赋入的值 |
| --- | --- |
| `@ ~local` | 只能是 `@ ~local` |
| `@ local!` | 只能是 `@ local!`，且目标和值同为内部或同为外部 |
| `@ local?`，在定义它的函数/lambda 内赋值 | `@ ~local`、`@ local!`、`@ local?` 均可 |
| `@ local?`，在被捕获的 lambda/嵌套函数内赋值 | 只能是 `@ ~local` |

其他关键限制：

- 非 `Copyable` 的 local 值不能存进全局变量/静态成员（它们只能是 `@ ~local`），也不能作为 `@ ~local` 返回值。
- `@ local?` 的值不能作为 `@ ~local` 返回；但 `@ local?` 参数本身及其成员可以作为 `@ local?` 返回（数组元素、局部变量不行）。
- 在 exclave 之外，非 `Copyable` 的**外部 local!** 不能直接作为实参传给其他函数，也不能用来调用 `this @ local!` 的成员函数；需要先赋给 `@ local?` 局部变量再传 `@ local?` 形参，或进 exclave。
- `@ local!` 参数做模式匹配时，绑定变量是 `@ local?`。
- 实例成员变量声明时不写 mode：通过 `@ local!` 实例访问到的成员是 local，通过 `@ local?` 实例访问到的是 `@ local?`。
- 不能给 `@ local?` 实例/数组的非 `Copyable` 成员/元素赋值；`Copyable` 成员/元素（如 `Int64`、`Float64`）可以。
- 元组的 mode 由元素共同决定：同时含 local 和非 local 元素时是 `@ local?`。

### 1.5 构造与 this mode

- 非 `Copyable` 类型的实例 mode 由构造函数决定：`init(this @ local!, ...)` / `init(this @ local?, ...)`；不写等价于 `this @ ~local`。主构造函数总是构造 `@ ~local` 实例。
- `this @ local!` / `this @ local?` 的构造函数，函数体必须以 exclave 表达式开头，通常直接写 `exclave init`。
- 构造时可以在调用后写 mode：`Order("pen", 2) @ local!`；省略时按上下文推断，无法唯一推断则默认 `@ ~local`。
- `this @ local?` 构造函数用于参数 mode 不确定的场景（参数可声明 `@ local?`），但它不能代替 `this @ local!` 或 `this @ ~local` 构造函数。
- 如果类型能构造出不同 mode 的实例，它的非 `Copyable` 成员变量**不能在声明处写初始值**（`demode` 成员除外）。这是改造 `f_base.StringGenerator`、`f_io.ByteBuffer` 这类“字段在声明处 `new`”的类型时首先要处理的。
- 成员函数默认 `this @ ~local`；通过实例调用时，实例 mode 必须是 this mode 的子类型：

| 实例的 mode | 可以调用的成员函数 |
| --- | --- |
| `@ ~local` | `this @ ~local`、`this @ local?` |
| `@ local!` | `this @ local!`、`this @ local?` |
| `@ local?` | 只能 `this @ local?` |

- 实现接口函数或覆盖父类函数时，`this` mode 必须与被实现/被覆盖的函数**完全相同**。这是本项目最大的硬阻塞来源：`IOStream.read/write`、`ToString.toString`、std `QueryResult`、std `Datasource` 等都无法单方面加 local。
- 同一个成员函数可以只按 this mode 重载；选择时 this mode 的匹配优先于参数类型。
- 函数也可以只按参数 mode 重载：实参 `@ ~local` 优先选 `@ ~local` 版本，没有则选 `@ local?`；实参 `@ local!` 优先选 `@ local!`，没有则选 `@ local?`；实参 `@ local?` 只能选 `@ local?`。

### 1.6 exclave

`exclave { ... }` 的执行过程：

1. 进入块之前，当前函数的 local region 结束，其中的 local 对象释放；
2. 块内新创建的 local 对象改为分配在**调用者的 local region**；
3. 块执行完，像 `return` 一样把块的值交给调用者。

因此 exclave 表达式本身的类型是 `Nothing`，块中最后一个表达式要符合函数返回类型。`exclave func f() { ... }` 等价于把整个函数体包在 `exclave { ... }` 中；`exclave init` 同理。

使用条件（只能用于以下函数，包括 lambda 和构造函数）：

- 有非 `Copyable` 类型的 `@ local!` 参数（含 `this @ local!`）；
- 返回类型是非 `Copyable` 的 `@ local!` 或 `@ local?`；
- `this @ local!` / `this @ local?` 的构造函数。

限制：

- 同一个函数中的 exclave 不能嵌套；
- 块内不能访问块外声明的、非 `Copyable` 的 `@ local!`/`@ local?` 局部变量（`Copyable` 不受限）；
- 不能在 spawn 块、`main`、终结器、静态初始化器中直接使用；
- 不能在 try/catch 块中用 exclave 结束包含该块的函数；
- `abstract` 函数不能用 `exclave` 修饰。

典型用途：把函数内新建的 local 对象返回给同样处于 local 链路的调用者；或把外部 local! 参数与块内新建对象放进同一个容器后返回。

### 1.7 Copyable 与 demode

`Copyable` 定义在 `std.core`，是空接口，标识“按值复制、可在不同 mode 间转换”的类型。自动实现的有：

- 所有数值类型，`Rune`、`Bool`、`Unit`、`Nothing`；
- `CType`（`CPointer<T>`、`@C` struct）；
- 元素全 `Copyable` 的元组；
- 元素 `T` 为 `Copyable` 的 `VArray<T, $N>`。

此外，**所有成员都 `Copyable` 的 struct 可以显式声明 `<: Copyable`**；class 和 enum 不能实现 `Copyable`。`Copyable` 只能出现在父接口列表或泛型上界，不能作为变量/参数类型。

`demode` 成员变量：

- mode 永远是 `@ ~local`，与实例 mode 无关；
- 可以持有普通对象引用，读出也是 `@ ~local`，可自由保存/返回；
- 不能把非 `Copyable` 的 local 值赋给它（`Copyable` 值可以按值复制）。

标准包装：

```cangjie
struct Demode<T> {
    demode var value: T
    init(v: T) { this.value = v }
    exclave init(this @ local!, v: T) { this.value = v }
}
```

用 `ArrayList<Demode<T>> @ local!` 可以构造“随函数释放、但元素引用普通对象”的临时容器。

### 1.8 闭包、spawn、泛型、FFI、异常、宏

- **闭包/嵌套函数**：不能捕获非 `Copyable` 的 `@ local!` 变量；捕获非 `Copyable` `@ local?` 的 lambda 自身变成 `@ local?`，不能逃逸；不能创建 `@ local!` 函数对象；嵌套函数默认 `@ ~local`，要捕获 `@ local?` 需写 `@ local? func`。
- **spawn**：块内不能用块外声明的非 `Copyable` `@ local!`/`@ local?` 变量；块结果只能是 `@ ~local`；块内可以创建自己的 local 对象；块内不能用 exclave。
- **异常**：`throw` 的操作数只能是 `@ ~local`；catch 绑定的异常变量是 `@ ~local`。
- **泛型**：泛型实参不能带 mode；传入 `String @ local!` 时 `T` 推断为 `String`，形参 `x: T` 仍是 `@ ~local`，要接收 local 必须写 `x: T @ local?`；从 `Array<T> @ local?` 读出的元素是 `T @ local?`，要作为 `T` 返回需 `where T <: Copyable`。
- **C 互操作**：`@C` 函数的参数和返回类型只能是 `@ ~local`。
- **宏**：宏的参数和返回值只能 `@ ~local`，但展开结果可以包含模态声明（如 `@DataAssist` 生成的 `@ local?` 实现）；生成代码能否编译，取决于使用方是否开启 local mode。
- **效应**：`perform` 的操作数只能是 `@ ~local`。
- **可选参数默认值**：不能引用其他参数，也不能捕获非 `Copyable` 的 `@ local!` 变量。

### 1.9 运行期与工具链

- 所有线程当前活跃的 local region（含嵌套调用各层）**合计**有上限，默认 **256 MB**，由环境变量 `cjLocalRegionMaxSize` 配置（支持 KB/MB/GB，必须带单位），超出抛 `LocalRegionOutOfMemoryError`。
- `std.runtime.getAllocatedLocalObjectSize()` 返回当前活跃 local region 占用的内存；local 对象不计入 `getAllocatedHeapSize()`。
- 该函数会暂停所有仓颉线程，不宜在性能敏感路径频繁调用，只适合基准/诊断。
- local 对象在**函数返回时**才整块释放；如果函数很长、临时对象很早就用完，local 可能推迟回收，峰值不降反升。
- local mode 是实验特性；编译产物不保证跨 SDK 兼容；工具链默认关闭 local 特性，cjfmt/cjlint/LSP/cjdb 不保证完整支持。

### 1.10 适用判据

| 适合 | 不适合 |
| --- | --- |
| 函数内创建、函数内用完的大块临时区 | 要作为返回值、字段、缓存、全局变量 |
| 元素是 `Copyable`（数值、字节、Rune）的数组/列表 | 跨线程、交给 spawn/Future/异步日志/任务队列 |
| 纯计算：求和、积分、匹配、聚合、像素处理 | 接口成员实现（this mode 被接口锁死） |
| 内部 helper 可自由加 `@ local?` 形参 | 泛型入口（`publish<T>`、`decode<T>`、`extract<T>`） |
| 临时区规模远大于函数其它开销 | 小对象高频分配（local 记账成本可能吃掉收益） |
| 长度可控、不会顶到 256 MB | FFI/native 堆（zlib、crypto、encoding） |
| | 已经池化复用（如 f_pool、ByteBuffer 复用） |

最容易被忽略的一条：local 值不能作为实参传给 `@ ~local` 形参。把临时对象改成 local，往往要求整条调用链都补 `@ local?` 重载；对公开 API 来说这是兼容性代价。可行的做法是**只在模块内部、只在 `Copyable` 元素容器上 local 化，公开签名保持 `@ ~local`**。

---

## 2. fountain 现状与总策略

### 2.1 现状

- 生产代码没有 local mode 使用；全仓只有 3 处注释提到兼容约束：
  - `f_ticktock/src/TicktockUnit.cj:21`
  - `f_mvc/src/RequestMethod.cj:20`
  - `f_data/src/macros/DataAssist.cj:158`
- 项目已经被动踩过 local mode：SDK 1.3.0 nightly 的 std 给 `Equatable`/`Comparable` 等加了模态重载，类型声明里同时出现“祖先 + 后代”父接口（如 `Comparable<X> & Equatable<X>`）会报 `must be implemented ... @local!`。`f_data` 的 `@DataAssist` 宏因此做了父接口归一化，详见 `f_data/doc/spec/fix-dataassist-local-mode/`。
- 各模块 `cjpm.toml` 目前 `cjc-version = "1.2.0"`、`compile-option = "--dy-std"`；local mode 需要按模块追加 `--experimental --enable-local-mode`。
- 发布模型是“模块随 SDK 版本发”（当前 1.3.1020），而 local 产物不保证跨 SDK 兼容；公开 API 一旦带模态，调用方必须开启 local mode 且用同版本 SDK 编译。

### 2.2 总策略

1. **先结构性优化，再 local mode**。去重复解析、去多余拷贝、复用缓冲的收益通常更大，且没有兼容性代价。
2. **函数级规则优先于“只做内部细节”**：函数体内创建且不逃逸的实例，声明 `@local!`；只在模块内部调用链传递的实例，声明 `@local!`（下游参数按语言规则用 `@local?`）。公开 API 仍保持 `@ ~local`，接口方法、跨线程、FFI、泛型入口不强行 local 化。
3. **不再限定 `Copyable` 容器**：非 `Copyable` 的临时对象只要满足“函数内创建且不逃逸”或有 `exclave init`，同样按规则 A 声明 `@local!`；但小对象、负收益点仍不改。
4. **每个模块独立开启** `compile-option`，不修改 `override-compile-option`；后者会把整棵依赖树拖下水，让所有依赖里的 `exclave`/`demode` 变成关键字。local-mode 发版也沿用这个约定。
5. **先探针、后改造**。文档只确认 `String`、`Array`、`ArrayList`、`HashMap` 有 local 写法；其余 API 必须实测。
6. **按峰值内存验收**：`-O2` 构建、同输入同负载，比较 peak RSS、`getAllocatedHeapSize()`、`getAllocatedLocalObjectSize()`。不要用吞吐量证明 local 的收益。
7. **DataAssist / Local\* 面向 local-mode 发版**：`1.3.10xx` 是最后一个兼容无 local mode SDK 的版本；新版本所有使用方按 local mode 基线编译，不做 opt-in，也不保留旧展开。

### 2.3 为什么不是“到处加 `@local`”

- 结果对象要返回/进缓存/进字段时，local 值不能逃逸，只能放弃 local，或在边界复制一份，收益被抵消。
- 大多数热点落在接口方法上（`IOStream`、`ToString`、`QueryResult`、`Datasource`、`Chart`、`RowSink`），这些方法的 this mode 不能单方面改。
- 很多入口是泛型（`publish<T>`、`decode<T>`、`extract<T>`、`BarrierTask<G>`），local mode 不支持在泛型参数上带 mode。
- 压缩、加密、字符集编码的大头在 stdx/native 堆，local region 管不到。
- 小对象高频分配时，local 的记账成本可能超过收益；官方文档也提示“常见类型并非每个 API 都支持所有 mode”。

2.4 已把这些限制编码成逐函数判定；“不是到处加”指的是在逃逸/接口/线程/FFI/负收益这些边界处不加，而不是只允许 f_svg、f_llm 两个模块用。

### 2.4 函数级规则（全仓每个函数适用）

#### 规则 A：函数体内创建、且不逃逸的实例，声明 `@local!`

```cangjie
let accumulated = Array<Float64>(width * height, repeat: 0.0) @ local!
let events = ArrayList<Float64>() @ local!
let tmpMap = HashMap<String, Int64>() @ local!
```

判定“不逃逸”：

- 不作为 `@ ~local` 返回值；
- 不写入字段、缓存、全局、注册表；
- 不被 `spawn` / `Future` / 异步回调捕获；
- 不通过 `@ ~local` 的接口方法传出；
- 不被闭包捕获后逃逸。

项目自有类型要能 local 构造，必须有 `exclave init(this @ local!, ...)`；否则先用 std 的 `Array`/`ArrayList`/`HashMap`/`StringBuilder` 等 local 构造替代，或先补 `exclave init`。

#### 规则 B：只在模块内部函数调用链传递的实例，声明 `@local!`

“模块内部”指 `private` / `internal` 的具体函数，不经过：

- `public` 导出 API、跨模块调用；
- 接口方法（`this` mode 被接口锁死）；
- `spawn` / `Future` / 异步回调；
- `@C` / FFI；
- 泛型入口（`publish<T>`、`decode<T>` 等，类型参数不能带 mode）。

编码方式（受“外部 `@ local!` 不能直接转发”限制）：

```cangjie
func outer(): Unit {
    let buf = ArrayList<Int64>() @ local!   // 规则 A：创建点 @local!
    consume(buf)                            // 沿内部链传递
}

private func consume(buf: ArrayList<Int64> @ local?): Unit {
    // 下游参数写 @local?，才能接收外部 local!
    // 若 consume 不再继续转发，也可以写 @ local!，但调用方必须是本函数创建的 local 实例
}
```

- 创建点：`@ local!`；
- 下游参数：默认 `@ local?`；确认不再转发且只接收本函数创建的 local 实例时，可写 `@ local!`；
- 内部函数返回 local：`@ local!` + `exclave`，或由调用方 region 承接的 `@ local?`；
- 一旦遇到 public/接口/线程/FFI/泛型边界，停止传播，转普通值或复制。

#### 逐函数判定流程

1. 函数内是否创建了实例？否 → 不改。
2. 实例是否逃逸出函数？是 → 不改，或在边界复制。
3. 是否经过 public / 接口 / 跨模块 / spawn / FFI / 泛型入口？是 → 不改。
4. 类型是否支持 local 构造？否 → 先补 `exclave init` 或改用 std 容器。
5. 创建点标 `@ local!`；内部参数按上表选 `@ local?` / `@ local!`；返回按 `exclave` 规则。
6. 编译探针 + 模块测试 + 峰值内存基准；小对象/负收益点回退。

### 2.5 全仓函数审计结果

按模块逐个函数过一遍，只列需要改或需要说明的点；未列出的函数不满足规则 A/B（逃逸、public API、接口、泛型、spawn、FFI、无大临时对象或负收益）。

| 模块 | 函数/位置 | 实例 | 结论 |
| --- | --- | --- | --- |
| f_svg | `SvgAnalyticRasterizer.analyticCoverage`（124-180） | `accumulated: Array<Float64>`、每行 `events` | `@ local!`；`accumulateAnalyticRow(accumulated: ... @ local?)` |
| f_llm | `KnowledgeChunker.split`（33-68） | 全文 `ArrayList<Rune>` | `@ local!`；内部 helper 参数 `@ local?` |
| f_excel | `PackageWriter`（125-218） | `ByteBuffer(256 * 1024)` | 先给 `ByteBuffer` 加 `exclave init`；中间缓冲 `@ local!` |
| f_excel | `SheetXmlWriter.writeCell`（112-160） | 单元格属性列表/小字符串 | 不改（小对象负收益） |
| f_jsonrpc | `JsonRpcClient.batch`（107-152） | `ids`、`byId`、请求临时集合 | `@ local!`；请求体 String 仍普通 |
| f_jsonrpc | `JsonRpcClient.readCapped`（308-332） | 8 KB 读缓冲 | 优先字段复用；每次新建则 `@ local!` |
| f_mcp | `McpServer.truncateUtf8`（1140-1164） | `toRuneArray()` 结果 | `@ local!`；更优是改 UTF-8 字节切片 |
| f_http | `MultipartFormDataParser.parse` | header 块、1 KB 缓冲 | `@ local!` |
| f_http | `ContentDisposition.parse`（280-358） | 1~7 元素 `ArrayList<String>` | 不改（小对象） |
| f_httpclient | `SseReader.readLine`（145-175） | `ArrayList<Byte>` + `toArray()` | `@ local!`，或复用字段缓冲 |
| f_xml | `XmlWriter` flush | 16 KB 编码数组 | 不改：实测 `unsafeBytes()` 为数组视图（313 B/次） |
| f_xml | `Escaper` 非 ASCII 追加 | `StringGenerator.append(r)` 每字符新建 4 B 暂存（68 B/rune） | 已改：复用 `ByteScratch.putCp` 暂存（7 B/rune） |
| f_xml | `EntityExpander.checkReplacement` | 每次新建 `Lexer`/`LineWindow` | 优先复用单个 Lexer；不改 |
| f_data | `DataJson.toJsonString`（92-110） | 每字段中间 `valStr`（逃逸，不可 local）；叶子转义 840 B/次 | 已改：`escapeJsonString` 无转义快路径（64 B/次）；sink 暂不做 |
| f_orm | `SqlPartial.UPDATE`（123-143） | `HashMap<String, Any>` 中转 | `@ local!`（不再逃逸时） |
| f_orm | `RootDAO.arg`（323-389） | `Any` 装箱进 executor | 不改（逃逸） |
| f_dbd | `DbdStatement.sqlPayload`（158-175） | `DataAny` 两层临时包装 | `@ local!` |
| f_mq | `candidateNodes` | `ArrayList<Int64>` | `@ local!` |
| f_rule | `AlphaMemory.range/select`（147-188） | `ArrayList<FactHandle>` + `toArray()` | 结果逃逸，不改；改调用方 buffer |
| f_egraph | `takeBatchLocked`（218-248） | 整队列快照 | 逃逸，不改 |
| f_cache | `HeapCache.checkOverSize`（179-224） | `segmentIterators`/`tops` | 字段复用，不改 |
| f_ticktock | `Ticktock.emit`（236-268） | `batch` 被 `spawn` 捕获 | 不改（跨线程） |
| f_log | 格式化链路 | 闭包/异步/接口 | 不改 |
| f_mvc | `PathPattern.extract` | `split("/")` + `HashMap` | 内部 helper 可 `@ local!`；接口 `extract` 不改 |
| f_security / f_email | JWT 两次解析 / Base64 三重实体化 | 中间 String/数组 | 先做结构性优化，不改 local |
| f_jwt / f_crypto / f_zip | Base64/HMAC/zlib 中间对象 | stdx/FFI | 不改（native 堆） |
| f_base / f_io | `StringGenerator` / `ByteBuffer` | 接口方法锁死 | 不改；`RotatableBuffer` 可先加 `exclave init` |
| f_collection / f_concurrent / f_net / f_pool / f_dbpool / f_dbm | 接口/线程/池化 | — | 不改 |
| f_store / f_hydra / f_jit / f_tui / f_protocol / f_time / f_regex | 待采样 | — | 按 2.4 流程逐函数判定，当前不改 |
| 其余模块 | 启动期/纯接口/无大临时对象 | — | 不改 |

说明：

- 表中“`@ local!`”是审计结论/目标声明；落地前必须确认该类型有 local 构造（`exclave init` 或 std 的 local API），没有则先补构造或降级为结构性优化。
- 表中“`@ local!`”指创建点/内部链的实例声明；下游参数默认写 `@ local?`，原因见 2.4 的外部 local! 转发限制。
- 这张表是**函数级审计的汇总**，不是“每个函数都改”。未列出的函数按 2.4 流程判定为不改；新增热点时继续往表里补。
- 规则 B 只覆盖模块内部具体函数；`public` API 仍保持 `@ ~local`，避免调用方被迫开启 local mode。

---

## 3. 逐模块建议

> 本节的结构优化建议仍然有效；local 化部分以 2.4 的函数级规则为准：满足“函数内创建且不逃逸”或“仅模块内部链传递”的实例标 `@local!`，其余不改。早期“只做内部、只 Copyable”的保守结论已被 2.4 取代。

### 3.1 首批试点

#### f_svg：全仓最合适的点

```124:129:d:\docs\work\cangjie\projects\fountain\f_svg\src\SvgAnalyticRasterizer.cj
internal func analyticCoverage(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule
): Array<Int64> {
```
（函数体从下一行开始，完整实现见 `SvgAnalyticRasterizer.cj:124-180`。）

- `SvgAnalyticRasterizer.cj:166` 每次调用创建 `Array<Float64>(width * height, repeat: 0.0)`：1000×1000 约 8 MB，4K（3840×2160）约 66 MB。这份累加器**不逃逸**。
- `accumulateAnalyticRow`（同文件 `183` 起）每行还创建 `active: ArrayList<SvgAnalyticEdge>` 与 `events: ArrayList<Float64>`。
- `coverage`（`Array<Int64>`）作为返回值逃逸，保持普通分配；`accumulated[index]` 读出 `Float64` 是 `Copyable`，写入普通数组合法。

可行的最小改造：

```cangjie
let accumulated = Array<Float64>(width * height, repeat: 0.0) @ local!
var row = firstRow
while (row <= lastRow) {
    accumulateAnalyticRow(edges, accumulated, width, row, fillRule)
    row++
}
```

```cangjie
private func accumulateAnalyticRow(
    edges: ArrayList<SvgAnalyticEdge>,
    accumulated: Array<Float64> @ local?,
    width: Int64,
    row: Int64,
    fillRule: SvgFillRule
): Unit
```

对 `@ local?` 数组，`Copyable` 元素的读写是允许的（规则明确允许给 `@ local?` 数组的 `Int64` 元素赋值，非 `Copyable` 元素不行）。

注意事项：

- 不要把 `edges`/`active` 直接 local 化。`SvgAnalyticEdge` 是 class（`85-103`），非 `Copyable`；从 local 列表读出的元素是 `@ local?`，再塞进 `@ local!` 列表违反非 `Copyable` 赋值规则。要么把边改成 `struct SvgAnalyticEdge <: Copyable`（字段全是 `Float64`/`Int64`，可行），要么 local 列表里只放下标/数值。
- 256 MB 是**全线程合计**上限：一张 4K 图约 66 MB，并发多个渲染就会顶到上限。必须做尺寸门限或 tile 分块，并准备 `LocalRegionOutOfMemoryError` 的回退（普通分配或分块）。

#### f_llm：只 local 化 rune 缓冲

`f_llm/src/store/KnowledgeChunker.cj:33-68` 的 `split` 把整篇文档展开成 `ArrayList<Rune>`（约 4 倍文本字节），每个窗口再建 `StringBuilder`：

- `Rune` 是 `Copyable`，`ArrayList<Rune> @ local!` 是干净候选；`chunks` 是返回值（`ArrayList<String>`），保持普通。
- `StringBuilder` 的 local 支持未在文档确认；chunk 字符串本来要逃逸，不要把 builder 变 local。
- 更彻底的结构优化是不建 rune 数组、直接按 UTF-8 字节边界扫描，这比 local 化更省。

#### f_excel：第二批，先复用缓冲

- `f_excel/src/SheetXmlWriter.cj:112-160` 的 `writeCell` 每个单元格创建 `ArrayList<XmlAttribute>` + 多个拼接 String：小对象高频，local 化很可能负收益。优先复用属性数组/直接写出。
- `f_excel/src/PackageWriter.cj:125-218` 等 6 处 `ByteBuffer(256 * 1024)`：一个工作簿固定 1.5 MB 起步，且返回的 `Array<Byte>` 逃逸给 `zip.add`。要 local 化得先给 `f_io.ByteBuffer` 加 `exclave init`，但中间缓冲仍可复用，收益中等。
- 结论：先做“按实际大小分配 + 复用”，local 放第二批。

#### f_rule：复用 out 缓冲比 local 更划算

- `f_rule/src/rete/AlphaMemory.cj:147-158` 的 `range` 每次探测创建 `ArrayList<FactHandle>` + `toArray()` 双份；`select`（`166-188`）同理。结果作为返回值逃逸，local mode **不能消除这次分配**。
- 同文件 `probeList` 已是“调用方传 buffer / 零分配”的写法，把 `range`/`select` 改成同型即可，比 local 更彻底。
- local 只适合临时的数值/键数组（`RangeKey` 之类），且要确认 `ConcurrentSkipListMap` 遍历 API 是否有 local 重载。

#### f_egraph：先消除整队列快照

- `f_egraph/src/base/QueuedClosureTask.cj:218-248` 的 `takeBatchLocked` 每次 `queue.toArray()` 复制整个队列，再 `matched.toArray()`；`batch` 在 size > 1 时进 `MultiEvent` 逃逸。
- 先改成迭代/复用，不要把整队列快照 local 化；`matched` 的元素是普通对象，local 化需要 `Demode` 包装或只存下标。

#### f_cache：淘汰扫描优先字段复用

- `f_cache/src/HeapCache.cj:179-224` 每轮淘汰创建 `Array<Iterator>`（并发段数）+ `HashMap<Int64, Iterator>` + `tops`，运行在 `Timer.after` 回调里。
- 并发段数是固定配置，`segmentIterators` 的数组和 map 完全可以做成字段复用；local 化的收益被“泛型容器 + 普通对象元素”抵消。
- 结论：优先复用，不做 local。

### 3.2 需要先补前置条件

| 模块 | 职能 | 判断与具体点 |
| --- | --- | --- |
| **f_jsonrpc** | JSON-RPC 客户端/服务端 | `JsonRpcClient.batch`（`107-152`）的 `ids`/`requests`/`byId` 不逃逸，但请求体 String 逃逸；要 local 化必须先让 `f_data` 的 `JsonObject`/`JsonArray`/`JsonValue` 支持 local。`readCapped`（`308-332`）的 8 KB 读缓冲可直接复用，不需要 local。`processOne` 受 `spawn` 限制。 |
| **f_mcp** | MCP 服务端/客户端 | `McpServer.cj:1140-1164` 的 `truncateUtf8` 用 `text.toRuneArray()` 把 1 MB 文本放大成上百万个 Rune（约 4 倍）。先改成 UTF-8 字节边界切片（结构性，收益确定）；local 只是次选。`McpClient.classify` 每行 `JsonValue.fromStr` 后即弃，需 `f_data` local 才成立。 |
| **f_codec** | 二进制序列化 | `decodeSizeOfEncoded`（`675-712`）每次分配 ≤8 字节小数组，local 化小对象通常更慢，应改复用 `VArray`/直接读字节。`decodeData` 的载荷会进返回的 `Data`，不能 local。`decode<T>` 是泛型接口，不碰。 |
| **f_http** | HTTP 报文/Multipart | `ContentDisposition.parse`（`280-358`）每 part 一个 1~7 元素 `ArrayList<String>`，规模小、local 收益低；改成原地解析/复用更划算。`MultipartFormDataParser.parse` 的 header 块/1 KB 缓冲可复用；payload 进 `Data` 逃逸。`toData` 是 `open` 虚方法，覆写链 this mode 要一致。 |
| **f_httpclient** | HTTP 客户端/SSE | `SseReader.readLine`（`145-175`）每行 `ArrayList<Byte>` + `toArray()` 双份，行上限 1 MB；`SseReader` 本身就是可复用对象，改成“字段缓冲 + `String.fromUtf8(buf, 0, n)`”即可，不需要 local。`ExtendHttpResponse.readToEnd` 是 `extend HttpResponse <: ExtendHttpResponse` 的接口成员，this mode 锁死。 |
| **f_xml** | XML 解析/写出 | `XmlWriter` 每 16 KB flush 一次 `encoder.encode(text)` 数组，可复用；`EntityExpander.checkReplacement` 每个实体值新建 `Lexer`/`LineWindow`/`Utf8RuneSource`，复用单个 Lexer 更划算。`EntityExpander` 的 `Lexer` 状态在字段，local 化成本高。 |
| **f_chart** | SVG 图表渲染 | 整棵 `SvgBuilder` DOM → `toSvgString` 是最大临时区，但要 local 化必须先把 `f_svg.SvgBuilder`/`SvgElement` 和 `f_xml.XmlWriter` 全链 local 化；`Chart.draw` 还是接口实现（this mode 锁死）。当前不做。 |
| **f_data** | 数据对象/JSON | `f_data/src/json/DataJson.cj:92-110` 的 `toJsonString` 每字段先生成中间 `valStr`，再拼进父 builder，峰值约为最终 JSON 的 2 倍。收益最大的是改成写入式 sink（父 builder 直接接收子节点），不是 local；`DataObject<T>` 是泛型 + `ToJsonString` 接口实现，模态改不动。`@DataAssist` 面向 local-mode 发版：`equal` / `compare` 实现 `f_base.LocalEquatable` / `LocalComparable`，同时生成普通 `==` / `compare` 与 `localEq` / `localCompare` hook；local 路径由接口默认转调，普通路径保持非模态；详见 3.4。 |
| **f_orm** | ORM/SQL DSL | `RootDAO.arg`（`323-389`）的 `Any` 装箱会逃逸进 executor 参数表，local 无效；`SqlPartial.UPDATE`（`123-143`）的 `HashMap<String, Any>` 纯中转，直接删掉/直接调另一重载即可。`RootDAO` 是 40+ 默认成员的接口，加 `this @ local?` 会牵连整棵 DAO 体系，不做。 |
| **f_dbd** | 数据库驱动 | `DbdStatement.sqlPayload`（`158-175`）每参数两层 `DataAny` 包装，是结构性浪费；`QueryResultImpl.get<T>` 实现 std `QueryResult`，this mode 锁死。 |
| **f_mq** | 消息队列客户端 | `publish<T>`、`MQProtocol.encodePayload<T>` 都是泛型，local 不支持类型参数；`candidateNodes` 的 `ArrayList<Int64>` 可以 local，但规模小、收益低。 |
| **f_ticktock** | 定时任务调度 | `Ticktock.emit`（`236-268`）每 tick 一个 `ArrayList<TicktockEntry> batch`，但 `spawn { executeOne(entry) }` 不允许捕获外层 local；`TicktockEntry` 是普通类型。建议字段复用 buffer，不做 local。 |
| **f_zip** | zip 读写 | 峰值主因是 `stdx.compress.zlib` 的 native 堆（deflate/inflate 状态），local mode 碰不到；`memoryEntryThreshold`/spill 策略才是杠杆。`ByteBuffer` 中间缓冲可 local，但收益有限。 |
| **f_store** | LSM-Tree KV | 待采样。优先看 key/value 编码缓冲、WAL/SSTable 写路径的临时字节数组；如果最终写入文件/字段，逃逸后 local 无收益。 |
| **f_hydra** | 进程内向量存储 | 待采样。向量距离计算的 `Array<Float64>`/临时数组可能是候选，但要确认结果是否进 `VectorHit`/索引结构（逃逸）。 |
| **f_jit** | 字节码编译器/JIT | 待采样。诊断文本、字节码/常量池构建多为启动期或跨调用持有；解释器热路径的小对象更适合复用。 |
| **f_tui** | 终端 ANSI 渲染 | 待采样。每帧缓冲/差分是候选，但最终要写 `TerminalWriter`（接口），且帧缓冲通常跨帧复用。 |
| **f_protocol** | 应用协议帧编解码 | 待采样。帧缓冲多在 `ByteBuffer`/`Message` 之间流转，逃逸面大；先复用。 |
| **f_rpc** | RPC 框架 | 复用 `f_net`/`f_protocol`，无独立热点；不做。 |
| **f_a2a** | Agent-to-Agent 协议 | 复用 `f_jsonrpc`/`f_mvc`；不做。 |

### 3.3 明确不做

| 模块 | 职能 | 原因 |
| --- | --- | --- |
| **f_base** | 基础工具（StringGenerator、HashBuilder…） | `StringGenerator` 是全仓 86 处引用的公共瓶颈，但 `toString()` 是 `ToString` 接口实现，local 实例不能调用 `this @ ~local` 的接口方法；要做得另开非接口方法（如 `toLocalString`）。更省事的是热点处直接用局部 `ArrayList<Byte>`，末尾 `String.fromUtf8` 拷出。 |
| **f_io** | ByteBuffer/RotatableBuffer/流 | `ByteBuffer` 实现 `IOStream`，read/write/seek/close 的 this mode 锁死；只有 `RotatableBuffer`（无接口）适合做 local 构造样板。`QueueInputStream` 线程绑定。 |
| **f_collection** | PriorityQueue/HashDict | `PriorityQueue` 被 std `Queue<T>` 锁死；`Growable` 是自家接口可以加 mode，但整体不划算。 |
| **f_concurrent** | 并发集合/EventBus | 字段是 `Mutex`/`Condition`/`BlockingQueue`/`ConcurrentHashMap`，本身不能 local，语义上也不该 local。 |
| **f_net** | Socket/网络 | `SocketBuffer`/`MessageFuture` 线程绑定、构造里直接 spawn；不做。 |
| **f_util** | PathPattern/TextTemplate/Fnv | `PathPattern` 是注册期只读结构（多处声明初始化），`TextTemplate` 有静态模板缓存，都不是热 new；不做。 |
| **f_log** | 日志 | 格式化链路是“`()->String` 闭包 + 泛型 + 虚方法 + 异步队列 + `OutputStream` 接口”，local 收益吃不到；但每条日志重新 `TextTemplate.compile`（`f_log/src/base/Logger.cj:47-51`）、每个片段 `toArray()` 是明确的结构性浪费，先修这个。 |
| **f_mvc** | MVC/路由 | `PathPattern.extract` 每个路径变量一次全量 `split("/")` + 建 `HashMap<String,String>` 只取一个键；改成每请求解析一次/复用容器。`HttpRequestPathPatterns.extract` 是抽象成员，this mode 锁死。 |
| **f_security** | 鉴权/JWT 上下文 | `JWTSecurityContext.checkAndGet`（`f_security/src/JWTSecurityContext.cj:67`）每请求把同一个 JWT 解析两次（`check` 一次、`getPricinpal` 又一次）；把 verifier 传下去即可，结构收益远大于 local。 |
| **f_email** | 邮件/MIME | `f_email/src/mime/MimeWriter.cj:181-184` 把正文 Base64 编码成 String 再 `toArray()`，峰值约 3~4 倍原文；改走已有的流式 `Base64Encoder`/`QuotedPrintable.encoder` 即可。 |
| **f_jwt** | JWT | Base64/HMAC/JSON 大头在 stdx；`sign()` 的中间对象全不逃逸但被 FFI 和返回值夹住；不做。 |
| **f_crypto** | 加密抽象 | 只有接口 + `DefaultCryptoKit`，实现在 stdx；不做。 |
| **f_regex** | 正则扩展 | `doReplaceAll` 一次性 `findAll` 持有全部匹配；但 `ExtendRegex` 是 `extend Regex <: ExtendRegex` 的接口成员，this mode 锁死，需接口级改造；暂不做。 |
| **f_pool** | 缓冲池 | 模块本身就是池化复用；`BytesCopyTo.copy` 是接口成员，this mode 锁死；不做。 |
| **f_dbpool** | 连接池 | `getConnection`/`connect` 是 std `Datasource` 接口成员；池化连接必然跨调用存活；不做。 |
| **f_dbm** | 分库分表契约 | 纯接口 + `PartitionAlgorithm.partition<K>` 泛型接口方法；不做。 |
| **f_mockdb** | 测试替身/内存 DB | 测试用途，无生产峰值诉求；不做。 |
| **f_config** | 配置 | 启动期加载；不做。 |
| **f_bean** | DI 容器 | 启动期；不做。 |
| **f_aspect** | AOP | 宏/代理生成；不做。 |
| **f_macros** | 宏工具 | 编译期；不做。 |
| **f_exception** | 异常类型 | 无大临时对象；不做。 |
| **f_version** | 版本比较 | 小对象；不做。 |
| **f_process** | 进程管理 | 启动期；不做。 |
| **f_cmd** | 命令行 | 启动期；不做。 |
| **f_random** | 随机数 | 无分配热点；不做。 |
| **f_time** | 时间/时区 | 格式化产生小字符串，量小；待采样，暂不做。 |
| **f_rx** | 响应式流 | 流式小对象；不做。 |
| **f_health** | 健康检查 | 低频；不做。 |
| **f_bloom** | 布隆过滤器 | 位运算，无大临时对象；不做。 |
| **f_uring** | io_uring FFI | `@C` 函数参数/返回值只能 `@ ~local`；不做。 |
| **f_probe** | 监控契约 | 纯接口；不做。 |
| **fboot / fdemo / fdbm / fmq / fleet / fprobe / 各 demo** | 启动器/服务/示例 | 启动期或应用层；按需采样，不进首批。 |

### 3.4 专项：`@DataAssist` 的 equal / compare local 重载

#### 目标版本与兼容性前提

本节设计面向**未来启用 local mode 的 fountain 版本**，不考虑与无 local mode SDK 的向后兼容：

- `1.3.10xx` 是最后一个兼容“无 local mode SDK”的版本；
- 新版本基线要求 SDK 支持 local mode，使用 `@DataAssist[equal]` / `[compare]` 的模块都在 `cjpm.toml` 中开启 `--experimental --enable-local-mode`；只使用 `fields` / `hash` / `toString` 的模块不涉及 Local*，不受影响；
- 因此 `@DataAssist` 可以直接默认生成 local 重载，不需要 `local` 修饰符，也不需要为未开启 local mode 的使用方保留旧展开。

#### 现状与问题

`@DataAssist` 的 `equal` / `compare` 目前只生成普通版本（下列代码为节选）：

```349:373:d:\docs\work\cangjie\projects\fountain\f_data\src\macros\DataAssist.cj
func generateEqual(d: ClassDecl, exclusion: HashSet<String>) {
    ...
    d.body.decls.add(
            all: [FuncDecl(
                quote(
        public $(openTokens(d)) operator func ==(other: $typeName): Bool {
            refEq(this, other) || ($eq)
        }
    )),
                FuncDecl(
                quote(
        public $(openTokens(d)) operator func !=(other: $typeName): Bool {
            !(this == other)
        }
    ))])
}
```

```375:401:d:\docs\work\cangjie\projects\fountain\f_data\src\macros\DataAssist.cj
func generateCompare(d: ClassDecl, exclusion: HashSet<String>) {
    ...
    d.body.decls.add(
            FuncDecl(
                quote(
        public $(openTokens(d)) func compare(other: $typeName): Ordering {
            var result = Ordering.EQ
            $cmp
            result
        }
    )))
}
```

两个函数的 `this` 和参数默认都是 `@ ~local`，因此：

- `@ local!` / `@ local?` 实例不能调用 `this @ ~local` 的 `==` / `compare`（本文件 1.5 的调用表）；
- local 实参不能传给 `other: T`（`@ ~local` 形参）。

结果就是：`@DataAssist` 类一旦被放进 local 计算（本地临时对象、local 容器、local 解析中间结果），就无法比较，成为 local 化的断点。

#### 设计：抽象 hook + `@ local?` 默认转调（方案 B）

选择方案 B：`LocalEquatable` / `LocalComparable` **继续继承 std 的 `Equatable` / `Comparable`**，保留 `is Equatable` / `is Comparable` 兼容性。

不能把 std 的 `@ local?` 重载直接重新声明为抽象成员：

- 官方文档规定，子接口继承了父接口带默认实现的成员后，不允许只写声明，必须给出新的默认实现（`dev-guide/source_zh_cn/class_and_interface/interface.md:397`）；
- 编译器实测报错：`cannot override implemented interface function '==' with abstract function`（见下文实测记录）。

因此方案 B 把**抽象成员放在新命名的 hook 上**：

- `func localEq(this @ local?, other: T @ local?): Bool`；
- `func localCompare(this @ local?, other: T @ local?): Ordering`。

`@ local?` 与 `@ local!` 的 `==` / `compare` 由接口默认实现转调 hook；**普通重载不转调 hook**：

- 普通实例没有 local region，把它当 `@ local?` 去调 hook，访问非 Copyable 字段时会报 `alloc native local object without local object region`（Linux/WSL 实测）；
- 普通 `==` / `!=`（equal）与普通 `compare`（compare）仍由 `@DataAssist` 生成，普通运算符基于它们。

这样：

- hook 只服务 local 实例；
- local 的 `==` / `!=` / `compare` / `<` / `>` / `<=` / `>=` 都有实际比较的默认实现；
- 类仍是 std `Equatable` / `Comparable`，泛型 helper（`where T <: Equatable<T>` / `Comparable<T>`）继续可用。

`LocalEquatable`：

```cangjie
package fountain::f_base

public interface LocalEquatable<T> <: Equatable<T> {
    // 唯一抽象成员：实现类提供真正的相等比较（只对 local 实例调用）
    func localEq(this @ local?, other: T @ local?): Bool

    // 覆写 std 的 local? ==（std 默认抛异常），转调 hook
    operator func ==(this @ local?, other: T @ local?): Bool {
        this.localEq(other)
    }

    // @ local! 实例：外部 local! 不能直接转发，先转成 @ local? 视图
    operator func ==(this @ local!, other: T @ local!): Bool {
        let lhs: LocalEquatable<T> @ local? = this
        let rhs: T @ local? = other
        lhs == rhs
    }

    // std 的 local! != 默认体抛异常，必须覆盖
    operator func !=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalEquatable<T> @ local? = this
        let rhs: T @ local? = other
        !(lhs == rhs)
    }

    // 普通 ==(other: T) 不在这里给默认实现：由 DataAssist 生成非模态版本。
    // 普通实例没有 local region，把它当 @ local? 去调用 localEq 会报
    // `alloc native local object without local object region`。
}
```

`LocalComparable`（继承 `LocalEquatable` 与 std `Comparable`）：

```cangjie
public interface LocalComparable<T> <: LocalEquatable<T> & Comparable<T> {
    // 唯一抽象成员：实现类提供真正的排序比较（只对 local 实例调用）
    func localCompare(this @ local?, other: T @ local?): Ordering

    // 默认相等语义：compare == EQ；equal + compare 同时存在时由实现类覆写
    func localEq(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) == EQ
    }

    // ---- local 路径 ----
    operator func ==(this @ local?, other: T @ local?): Bool {
        this.localEq(other)
    }
    operator func !=(this @ local?, other: T @ local?): Bool {
        !this.localEq(other)
    }
    operator func ==(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localEq(rhs)
    }
    operator func !=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        !lhs.localEq(rhs)
    }

    func compare(this @ local?, other: T @ local?): Ordering {
        this.localCompare(other)
    }
    func compare(this @ local!, other: T @ local!): Ordering {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs)
    }

    operator func <(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) == LT
    }
    operator func <(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs) == LT
    }
    // > / <= / >= 的 local? / local! 版本与 < 同构

    // ---- 普通路径 ----
    // 普通 compare(other: T) 不在这里给默认实现：由 DataAssist 生成非模态版本。
    // 普通实例没有 local region，不能把它当 @ local? 去调用 localCompare。
    operator func ==(other: T): Bool {
        this.compare(other) == EQ
    }
    // 双路径必须显式实现普通 !=
    operator func !=(other: T): Bool {
        !(this == other)
    }
    operator func <(other: T): Bool {
        this.compare(other) == LT
    }
    // > / <= / >= 的普通版本同样基于普通 compare
}
```

要点：

- 新增的 `.cj` 文件按仓库规范在 `package` 之前加 Apache 2.0 版权头（年份取新建年）。
- `LocalComparable<T> <: LocalEquatable<T> & Comparable<T>`：`Equatable` 会经过两条路径（`LocalEquatable` 与 `Comparable`），编译器会要求 `LocalComparable` 显式实现普通与 `@ local?` 的 `!=`；接口里已补上，否则报 `interface function '!=(...) must be implemented`。
- `LocalComparable` 自带一份 `localEq` 默认实现（`compare == EQ`），因此只实现 `localCompare` 的类也能获得完整相等语义；同时它自然也是 `LocalEquatable`。
- `equal` + `compare` 同时存在时，`@DataAssist` 只把 `LocalComparable<T>` 加进父接口，并同时生成 `localEq` / `localCompare`（local 路径）与普通 `==` / `!=` / `compare`（普通路径）；此时类既是 `LocalEquatable` 也是 `LocalComparable`，同时仍是 std `Equatable` / `Comparable`。
- `@ local!` 的 `==` / `!=` / `compare` / `<` 默认实现都必须先把 `this` / `other` 转成 `@ local?` 视图。直接写 `this == other` 会报 `cannot pass argument of external @local! to @local! parameter`（实测踩过）。
- **普通路径必须保持非模态**：不要为了“统一”把普通 `==` / `compare` 也转调 hook；普通实例没有 local region，访问非 Copyable 字段会报 `alloc native local object without local object region`。
- std 的普通 / `@ local?` `!=` 会转调 `==`；覆盖 `==` 后它们自动生效。只有 std 的 `@ local!` `!=` 默认体抛异常，需要显式覆盖。

#### DataAssist 生成规则

- `equal`：
  - 父接口加 `LocalEquatable<T>`；
  - 生成普通 `operator func ==(other: T)` / `!=`（沿用原 `f_data_hash_eq` + `f_data_eq` 逻辑）；
  - 生成 local hook `func localEq(this @ local?, other: T @ local?)`（字段比较按具体类型走 `_copy` / 内联 match）。
- `compare`：
  - 父接口加 `LocalComparable<T>`；
  - 生成普通 `func compare(other: T)`（沿用原 `f_data_cmp` 逻辑）；
  - 生成 local hook `func localCompare(this @ local?, other: T @ local?)`。
- `equal` + `compare` 同时存在：
  - 父接口只加 `LocalComparable<T>`；
  - 生成普通 `==` / `!=`（equal）、普通 `compare`（compare），以及 `localEq(local?)` / `localCompare(local?)`；`localEq` 显式覆盖 `LocalComparable` 的默认相等。
- 普通路径与 local 路径的字段比较分别走：
  - 普通：`f_data_hash_eq` / `f_data_eq` / `f_data_cmp`（非模态）；
  - local：Copyable 字段 `f_data_eq_copy` / `f_data_cmp_copy`；非 Copyable 字段按具体类型内联 `match`，不可比时 `refEq` / `EQ`。
- `normalizeSuperTypes` 扩展：
  - 保留现有规则：存在 `Comparable<X>` 时删掉 `Equatable<X>`；
  - 存在 `LocalEquatable<X>` 时删掉 `Equatable<X>`；存在 `LocalComparable<X>` 时删掉 `Comparable<X>`、`Equatable<X>`、`LocalEquatable<X>`（Local* 已隐含 std 接口）；
  - 若同时存在 `LocalEquatable<X>` 与 std `Comparable<X>`（没有 `LocalComparable`），宏直接报错：`Equatable` 会有两条路径，要求改用 `compare` / `LocalComparable`。
- `@DataExclude[equal]` / `[compare]` 的排除集合原样作用于两个 hook。
- 没有参与比较的字段时：`localEq` 只生成 `refEq(this, other)`，`localCompare` 只生成 `Ordering.EQ`；不要拼出空的 `&&` 链或空的比较序列。
- localEq 保留 `refEq(this, other)` 引用快路（std 有 `refEq(Object @local?, Object @local?)`，见 `std/core/object.cj:42`）。
- 不做哈希快筛：相等结果由 `refEq` + 逐字段比较决定；`Hashable` 的 local 实例暂不支持。

#### 字段比较 helper（`f_data/src/base/data_cmp.cj`）

方案 B 下 DataAssist 类仍是 std `Equatable` / `Comparable`，helper 可以继续用 std 约束，不需要运行时匹配 Local*：

```cangjie
// 已知 Copyable 字段（数值、Bool、Rune 等）：先 demode，再走非模态 helper
public func f_data_eq_copy<T>(a: T @ local?, b: T @ local?): Bool where T <: Copyable {
    let x: T = a
    let y: T = b
    f_data_eq(x, y)
}
public func f_data_cmp_copy<T>(a: T @ local?, b: T @ local?): Ordering where T <: Copyable {
    let x: T = a
    let y: T = b
    f_data_cmp(x, y)
}

// 非 Copyable 字段不走泛型 helper；宏按字段具体类型内联：
// match (this.f) {
//     case x: Equatable<FieldType> => x == other.f
//     case _ => ... refEq / false
// }
```

说明：

- 普通路径继续用 `f_data_eq` / `f_data_cmp`，不涉及 local。
- local 路径中，Copyable 字段用 `_copy`（demode 后普通比较）；非 Copyable 字段按**具体类型**内联 `match`：
  - `Equatable<FieldType>` / `Comparable<FieldType>` 命中时调用接口的 `@ local?` 成员；
  - 不命中时退回 `refEq` / `EQ`，与非模态兜底语义一致。
- `Bool` 走 `_copy`（std 没有模态 `==`）；`String` 走 `Equatable<String>` 内联匹配；非 Equatable 的 class（如测试里的 `TT`）走 `refEq`。
- 集合、`JsonValue` 走内联匹配；如果其类型没有实现模态 `==` / `compare`，运行时会命中 std 的抛异常默认体，需在测试矩阵中确认并写入限制。
- 不要恢复成泛型 `f_data_eq_local<T>(a: T @ local?, ...)`：普通实例没有 local region 时会被错误路由，且泛型模态 helper 在 SDK 上出现过 `OutOfMemoryError`；按具体类型内联是已验证可用的方案。

#### 生成示例

```cangjie
@DataAssist[equal compare]
class Item {
    var id: Int64
    var name: String
    init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
    exclave init(this @ local!, id: Int64, name: String @ local!) {
        this.id = id
        this.name = name
    }

    // 另外还会生成普通 == / != / compare（沿用原非模态逻辑，此处省略）
    // local 路径只生成这两个 hook；local/local! 的运算符由 Local* 默认实现转调
    public func localEq(this @ local?, other: Item @ local?): Bool {
        refEq(this, other) ||
            (f_data_eq_copy(this.id, other.id) && f_data_eq_local(this.name, other.name))
    }
    public func localCompare(this @ local?, other: Item @ local?): Ordering {
        var result = Ordering.EQ
        result = f_data_cmp_copy(this.id, other.id)
        if (result != EQ) {
            return result
        }
        result = f_data_cmp_local(this.name, other.name)
        if (result != EQ) {
            return result
        }
        result
    }
}
```

调用链：

- 普通实例 `c1 == c2` → `LocalEquatable.==(other: T)` 默认 → `@ local?` `==` 默认 → `localEq`；
- local 实例 `a == b` → 同一 `localEq`；
- `a == c` / `c == a` → 普通或 local? 重载，最终都落到 `localEq`；
- `a < b` → `LocalComparable.<` 默认 → `compare(local?)` 默认 → `localCompare`；
- `a.compare(b)` → `compare(local?)` 默认 → `localCompare`。

#### 测试（严格 RED）

先写用例，实现前必须编译失败（local 实例无法调用没有 local 重载的 `==` / `compare`），再实现接口与宏：

- 两个 local 实例：`a == b`、`a.compare(b) == EQ`、`!(a != b)`；
- local 与普通混合：`a == c`、`c == a`；
- 比较运算符：`a < b`、`a <= b`、`a > b`、`a >= b` 的 GT/LT/EQ 三组；
- `@DataExclude[equal]` / `[compare]` 字段在两个 hook 都生效；
- 普通路径回归：`c1 == c2`、`c1.compare(c2)`；
- 字段类型矩阵：`Int64`、`Bool`、`String`、集合、嵌套 `@DataAssist` 类；
- 接口断言：equal-only 类 `is Equatable` **且** `is LocalEquatable`；equal + compare 类 `is Equatable` / `is Comparable` / `is LocalEquatable` / `is LocalComparable`（LocalComparable 继承 LocalEquatable）；
- 既有 `DataAssist_test.cj` 里对 `is Equatable` / `is Comparable` 的断言保持不变（方案 B 保留 std 接口）。

构造 local 实例需要 local 构造，且非 `Copyable` 参数要传 local 值：

```cangjie
@DataAssist[equal compare]
class LocalItem {
    var id: Int64
    var name: String
    init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
    exclave init(this @ local!, id: Int64, name: String @ local!) {
        this.id = id
        this.name = name
    }
}

main() {
    let n1 = String("x") @ local!
    let n2 = String("x") @ local!
    let a = LocalItem(1, n1) @ local!
    let b = LocalItem(1, n2) @ local!
    @Assert(a == b)
    @Assert(a.compare(b) == EQ)
    @Assert(!(a != b))

    let c = LocalItem(1, "x")
    @Assert(a == c)
    @Assert(c == a)
}
```

命令（`f_base` / `f_data` 的 `cjpm.toml` 已开启 local mode）：

```shell
cd f_base && cjpm build
cd ../f_data && cjpm build && cjpm test
```

额外加一条“契约测试”：普通实例的 `==` 必须走到 `localEq`。如果接口默认实现没有正确转调，普通路径会编译失败或行为不一致，这条断言能覆盖。

#### 发布与兼容

- `1.3.10xx` 是最后一个兼容无 local mode SDK 的版本；本设计用于后续 local-mode 版本。`f_base` 与使用 `@DataAssist[equal]` / `[compare]` 的模块默认开启 local mode，不再提供 opt-in 或旧展开。
- 方案 B 保留 std `Equatable` / `Comparable` 兼容：DataAssist 类仍可用在 `where T <: Equatable<T>` / `Comparable<T>` 的泛型代码中；`is Equatable` / `is Comparable` 不受影响。
- 新增的 hook `localEq` / `localCompare` 是公开 API 名称。`LocalComparable` 只有 `localCompare` 是必须实现的；`localEq` 默认由 `compare == EQ` 提供。
- `f_base` 新增两个含模态声明的接口，必须开启 local mode 编译；依赖 `f_base` 且使用 Local* 的模块也要开启。按仓库约定，只改各模块的 `compile-option`，**不修改 `override-compile-option`**。
- WSL 实测：只给 `f_base` / `f_data` 的 `compile-option` 加 `--experimental --enable-local-mode`，`f_base` 构建成功、`f_data` 依赖构建与全量测试通过；`override-compile-option` 保持 `--dy-std` 不变。
- ohos：std 的模态成员都带 `@When[env != "ohos"]`，local mode 在 ohos 不可用；Local* 接口含模态声明，ohos 构建需要条件编译排除，或保留独立非 local 路径。

#### 边界与风险

- **hook 必须是抽象成员**：`localEq` / `localCompare` 无默认实现；`@ local?` 的 `==` / `compare` 是有默认实现的转调层。这样既绕开“不能把默认成员重新声明为抽象”的限制，又保证真正比较逻辑由实现类提供。
- **`LocalComparable` 继承 `LocalEquatable`**：因此 `is LocalEquatable` 为 true，`localEq` 有默认实现（`compare == EQ`）。代价是 `Equatable` 会经过 `LocalEquatable` 与 `Comparable` 两条路径，`LocalComparable` 必须显式实现普通与 `@ local?` 的 `!=`，否则报 `interface function '!=(...) must be implemented`。
- **多默认实现冲突**：`LocalComparable` 已继承 `LocalEquatable`，不要再把 `LocalEquatable` 显式加进同一个类的父接口列表；宏通过 normalize 只保留 `LocalComparable`，手写类也必须遵守。
- **递归风险**：`localEq` 的实现不能调用普通 `==`（会绕回 hook），只能逐字段比较或调用字段的比较函数。
- **`@ local!` 转发**：所有 `@ local!` 默认实现都必须先转 `@ local?` 视图；直接转发外部 local! 会报 `cannot pass argument of external @local! to @local! parameter`。
- **字段支持**：Copyable 字段走 `_copy`；非 Copyable 字段按具体类型匹配 `Equatable<FieldType>` / `Comparable<FieldType>`，不可比时退回 `refEq` / `EQ`；集合 / `JsonValue` 需测试；没有模态成员的字段会在 local 比较时命中 std 默认体抛 `UnimplementedException`。
- **普通路径必须非模态**：普通 `==` / `compare` 由 DataAssist 生成，不能转调 local hook；普通实例没有 local region，会报 `alloc native local object without local object region`。这是本次实现踩过并修正的关键点。
- **性能**：普通比较保持原路径；local 比较多一层接口派发，不产生堆分配，需用基准确认。
- **哈希**：本设计不生成 `hashCode(this @ local?)`；local 实例作为 `HashSet` / `HashMap` 键仍不可用，后续可新增 `LocalHashable` 或给 `generateHash` 生成模态版本。
- **`refEq` 快路**：local `localEq` 与普通生成的 `==` 都保留 `refEq` 快路。

#### 实测记录（2026-11-21，SDK 1.3.0-alpha.20261112001016）

在 **WSL Ubuntu 24.04 + Linux SDK 1.3.0-alpha.20261112001016 + stdx 1.3.0** 上编译并运行了探针（Windows 只用于早期初步探针，最终结论以 WSL 为准）：

| 探针 | 内容 | 结果 |
| --- | --- | --- |
| p1 | 子接口把父接口的默认函数重新声明为抽象 | 失败：`cannot override implemented interface function 'f' with abstract function` |
| p2 | `interface LE<T> <: Equatable<T>` 声明抽象 `==(local?)` | 失败：`cannot override implemented interface function '==' with abstract function` |
| p5 | 继承 std + 抽象 hook `localEq(local?)`，局部 `==(local?)` 默认转调 hook | 通过；`a is Equatable<P>` 为 true |
| p6 | 方案 B 完整版：`LocalEquatable` / `LocalComparable` + 普通/local/混合比较 + 泛型 `where T <: Equatable<T>` / `Comparable<T>` helper | 通过；`is Equatable` / `is Comparable` 均为 true，`eq(local, local)`、`cmp(local, local)` 正常 |

p3/p4 也验证过“独立接口 + 抽象 local? 重载”的方案 A，但该方案会失去 std `Equatable` / `Comparable` 兼容性，已放弃。

p5/p6 验证的是接口形态；其中“普通 `==` 也转调 local?”在后续 DataAssist 实测中暴露了无 local region 问题，最终实现已改为普通路径非模态（见落地状态）。

p6 第一次编译还发现一个坑：`!=(this @ local!, other: T @ local!)` 的默认实现如果直接写 `!(this == other)`，会报 `cannot pass argument of external @local! to @local! parameter`；必须先转成 `@ local?` 视图再比较（本文代码已按此修正）。

##### 落地状态（2026-11-21，WSL Ubuntu 24.04）

已完成并通过测试：

- `f_base/src/LocalEquatable.cj`、`f_base/src/LocalComparable.cj` 按方案 B 实现：`localEq` / `localCompare` 为抽象 hook；`@ local?` / `@ local!` 的运算符默认转调 hook；普通路径保持非模态。
- `f_data` 的 `@DataAssist` 已接线：
  - `equal` 生成普通 `==` / `!=` 与 `localEq(local?)`；
  - `compare` 生成普通 `compare` 与 `localCompare(local?)`；
  - 字段比较：普通路径用 `f_data_eq` / `f_data_cmp`；local 路径 Copyable 字段用 `_copy`，非 Copyable 字段按具体类型内联 `match`；
  - `normalizeSuperTypes` 处理 `LocalComparable` → `LocalEquatable` / `Comparable` / `Equatable` 的冗余。
- 在 **WSL Ubuntu 24.04 + Linux SDK 1.3.0-alpha.20261112001016 + stdx 1.3.0** 上：
  - `f_base`：`cjpm build` 成功，`cjpm test` **35/35 通过**；
  - `f_data`：`cjpm test` **166/166 通过**，包含新增的 `LocalDataAssistTest`（local/local、local/普通、普通/local、`==` / `!=` / `compare` / `<` 全部覆盖）。

关于之前的 `OutOfMemoryError`：

- 根因不是 SDK 的 Windows 缺陷，而是**普通实例被路由进了 local hook**。普通实例没有 local region，把 `this` / `other` 当 `@ local?` 视图去调 `localEq` / `localCompare`，访问非 Copyable 字段时就会报：
  `alloc native local object without local object region`
- 修正方式：普通 `==` / `compare` 不经过 local 视图，由 DataAssist 生成非模态实现；只有 `@ local!` / `@ local?` 才转调 hook。修正后 Linux/WSL 全量测试通过。
- 因此后续不要为了“统一”把普通重载改写成转调 hook；普通路径必须保持非模态。

### 3.5 一眼判断

| 分类 | 模块 |
| --- | --- |
| 首批试点（函数级规则） | f_svg、f_llm（创建点 `@ local!`，helper 参数 `@ local?`） |
| 第二批（先结构优化） | f_excel、f_rule、f_egraph、f_cache、f_jsonrpc、f_mcp、f_httpclient、f_xml |
| 基础能力改造 | f_base（LocalEquatable / LocalComparable）、f_data（DataAssist + 字段 helper）、f_io（ByteBuffer / RotatableBuffer） |
| 需前置设施的下游模块 | f_jsonrpc、f_mcp、f_codec、f_http、f_chart、f_orm、f_dbd、f_mq、f_ticktock、f_zip |
| 宏能力（local-mode 版本默认） | f_base.LocalEquatable / LocalComparable 与 f_data.macros.DataAssist 均已落地，WSL 测试通过，见 3.4 |
| 待采样 | f_store、f_hydra、f_jit、f_tui、f_protocol、f_time |
| 明确不做 | 其余模块（见 3.3） |

---

## 4. 落地路线

### 4.1 第 0 步：基线

- 用 `-O2` 构建（`cjpm test` 默认 `-O0`，同代码性能可差数十倍；测量完回退，不提交优化选项）。
- 固定输入和并发，记录 peak RSS、`getAllocatedHeapSize()`、P99 延迟。
- 只在基准进程里调 `getAllocatedLocalObjectSize()`：它会暂停所有仓颉线程。

### 4.2 第 1 步：探针矩阵

文档只明确给了 `String`、`Array`、`ArrayList`、`HashMap` 的 local 写法，其余必须先编最小样例确认。见附录 A。

需要逐个确认：

- `StringBuilder` 的 local 构造与 `toString` 返回 mode；
- `String.fromUtf8`、`String.toRuneArray`、`String.split`；
- `InputStream.read`、`OutputStream.write` 是否有 `@ local?` 形参；
- `f_io.ByteBuffer`、`f_base.StringGenerator` 加 local 构造后的可用性；
- `f_data.JsonObject`/`JsonArray`/`JsonValue` 是否支持 local；
- `f_base.LocalEquatable` / `LocalComparable` 的 `@ local?` `==` / `compare` 是否确实转调到 `localEq` / `localCompare`（而非抛异常），普通路径是否保持非模态；`@DataAssist[equal compare]` 是否同时生成普通 `==` / `compare` 与 `localEq` / `localCompare`；
- `ArrayList.toArray()`、`HashMap` 迭代器的返回 mode；
- `Regex.find/findAll`。

没有 `@ local?` 重载的 API，就是这条改造路线的终点。

### 4.3 第 2 步：f_svg 试点

- `accumulated` 与每行数值 `events` 改 local；
- 私有 helper 形参加 `@ local?`；
- `coverage` 保持普通数组；
- 加尺寸门限（宽高乘积超过阈值时走普通分配或分块）；
- 验收：同图同尺寸，peak RSS 下降，输出逐像素一致。

### 4.4 第 3 步：提炼三种可复用模式

1. **local 数值 scratch**：`Array<Float64>`/`ArrayList<Int64>` + `@ local?` 私有 helper + 末尾写回普通输出。
2. **Demode 包装**：`ArrayList<Demode<T>> @ local!` 装普通对象，读取 `.value` 拿普通引用，逐个拷进普通输出数组。
3. **exclave 返回**：只在“调用方也是 local”的链路里用：

```cangjie
func makeSquares(n: Int64): Array<Int64> @ local! {
    exclave {
        Array<Int64>(n, {i => i * i}) @ local!
    }
}
```

### 4.5 第 4 步：按模块推进

- 增量阶段只给真正写了 local 代码的模块加 `--experimental --enable-local-mode`；
- 每次只改一个模块，按 2.4 逐函数判定：创建点 `@ local!`，内部链下游 `@ local?`，public API 保持 `@ ~local`；
- 每次 `cjpm build` + `cjpm test` + 基准三件套；
- `LocalEquatable`/`LocalComparable` 与 `@DataAssist` 按 3.4 的接口设计新增模态签名；
- 不修改 `override-compile-option`（仓库约定）；local-mode 发版也只加各模块的 `compile-option`。

### 4.6 第 5 步：前置设施（可选）

- `f_io.RotatableBuffer` 加 `exclave init`：无接口、字段简单，是验证“项目类型 local 化”的最低成本样板。
- `f_io.ByteBuffer`、`f_base.StringGenerator` 如果要 local 化，必须先接受：`IOStream`/`ToString` 的接口方法在 local 实例上不可调用，需要另开非接口方法；通常不划算，优先继续用“局部 std 容器 + 末尾拷出”。

---

## 5. 风险清单

1. **256 MB 全线程上限**：大图/大报文并发会抛 `LocalRegionOutOfMemoryError`；必须按尺寸门限、分块，并配置 `cjLocalRegionMaxSize`。
2. **local 释放时机是函数返回**：函数很长时可能推迟回收，峰值不降反升；要用真实负载验证。
3. **小对象负收益**：local 分配仍有记账成本；`decodeSizeOfEncoded` 这类 ≤8 字节的高频分配，复用缓冲比 local 好。
4. **接口 this-mode 锁死**：`OutputStream`、`IOStream`、`ToString`、`Hashable`、`Chart`、`RowSink`、std `QueryResult`/`Datasource` 等，改实现会编译失败；只能改非接口 helper。
5. **泛型入口不可 local**：`publish<T>`、`decode<T>`、`extract<T>`、`BarrierTask<G>`、`ConcHashMapIterator<V>`；只能在内部非泛型段做。
6. **跨线程**：spawn/Future/异步日志不能捕获外层 local；f_mvc、f_log、f_ticktock、f_cache 都撞这条。
7. **FFI/native 堆**：zlib、crypto、encoding 的内存不在 local region，local 无法降低这部分峰值。
8. **ABI/发布**：local 产物不保证跨 SDK 兼容；`@DataAssist` 默认生成的公开模态签名要求使用方开启 local mode 并同 SDK 编译。local-mode 发版按此基线统一处理，`1.3.10xx` 之后不再保留无 local mode 的展开。
9. **工具链**：实验特性，cjfmt/cjlint/LSP/cjdb 不保证支持。
10. **宏边界**：宏参数/返回值只能 `@ ~local`；`@DataAssist` 默认生成的 hook 实现要求使用方按 local-mode 基线编译，序列化、字段复制、`toString` 仍无 local 版本。
11. **继承/接口重复路径**：std 的 `Equatable`/`Comparable` 已带模态重载，类型声明里重复列出祖先接口会报 `must be implemented ... @local!`；不要通过补 `@ local!` 解决，去掉重复父接口即可。`@DataAssist` 的 `normalizeSuperTypes` 同时处理 `LocalEquatable` / `LocalComparable` 与 std 祖先的冗余（保留 `LocalComparable` 时删掉 `LocalEquatable`、`Comparable`、`Equatable`）。详见 `f_data/doc/spec/fix-dataassist-local-mode/`。
12. **ohos**：std 的 local 模态成员都带 `@When[env != "ohos"]`（`equatable.cj`、`comparable.cj`、`hashable.cj`、`object.cj` 均如此），ohos 构建没有这些重载；跨平台模块不能把 local 重载作为唯一实现路径，需要用条件编译或保留普通路径。
13. **std 接口兼容性**：方案 B 保留 `is Equatable` / `is Comparable`，泛型 `T <: Equatable<T>` / `Comparable<T>` 继续可用；`LocalComparable` 继承 `LocalEquatable`，因此 equal + compare 类同时 `is LocalEquatable` / `is LocalComparable`。代价是 `Equatable` 双路径要求 `LocalComparable` 显式实现普通与 local? 的 `!=`；不要再手动把 `LocalEquatable` 加进同一个类。
14. **外部 local! 不能直接转发**：规则 B 的下游参数默认写 `@ local?`；`@ local!` 形参只用于“不继续转发”的直接消费。内部链要返回 local 时用 `exclave`，否则只能返回普通值。
15. **规则 B 的边界**：`public` API、接口方法、跨模块调用、`spawn`/`Future`、`@C` FFI、泛型入口都会截断内部链；这些位置保持普通类型，不要为了“统一”硬加 `@ local!`。
16. **函数级审计 ≠ 每个分配都 local**：小对象、高频短生命周期、无 local 构造、负收益点仍不改；满足规则 A/B 只是“可以 local”，最终还要过基准。

---

## 附录 A：探针模板

```cangjie
import std.collection.*

func probe(s: String) {
    let t = String(s) @ local!
    let parts: Array<String> @ local! = t.split(",")
    let bytes = Array<Byte>(8, repeat: 0) @ local!
    let list = ArrayList<Int64>() @ local!
    list.add(1)
    let map = HashMap<String, Int64>() @ local!
    map.add("a", 1)
    println(parts.size + bytes.size + list.size + map.size)
}

main() {
    probe("a,b")
}
```

```shell
cjc --experimental --enable-local-mode probe.cj -o probe && ./probe
```

探针矩阵建议逐项单独编译，避免一个失败掩盖其他结论：

| 探针 | 验证内容 |
| --- | --- |
| P1 | `String(text) @ local!` + local `split` |
| P2 | `Array<Byte>(n, repeat: 0) @ local!` + 读写 |
| P3 | `ArrayList<Int64> @ local!` + `add` + `toArray` |
| P4 | `HashMap<String, Int64> @ local!` + `add` + 迭代 |
| P5 | `StringBuilder() @ local!` + `append` + `toString` 的返回 mode |
| P6 | `input.read(localBytes)` / `output.write(localBytes)` |
| P7 | `String.fromUtf8(localBytes)` |
| P8 | `JsonObject() @ local!` / `JsonValue.fromStr`（f_data） |
| P9 | 自有 class 加 `exclave init` 后，能否构造 `@ local!` 实例并调用非接口方法 |
| P10 | 接口方法加 `this @ local?` 后，实现类是否必须同步改 |
| P11 | `LocalEquatable` 的 `@ local?` `==` 是否转调 `localEq`（不递归、不抛异常）；普通 / `@ local!` 是否再转调 local? |
| P12 | `LocalComparable` 的 `@ local?` `compare` 是否转调 `localCompare`；普通 / `@ local!` 与 `<`/`>`/`<=`/`>=` 是否都转调到 local? 版本 |
| P13 | `@DataAssist[equal compare]` 是否只生成 `localEq(local?)` / `localCompare(local?)`；普通 `==` / `compare` / `!=` 是否走接口默认实现 |
| P14 | `refEq` 的 `@ local?` 重载（`Object @local?`）能否接收 `T @ local?`（类实例） |
| P15 | `f_data_eq_copy<Bool>` / `f_data_cmp_copy<Bool>`（demode 后非模态 helper）是否正常；`Bool` 的 `compare` 是否按旧语义返回 `EQ` |
| P16 | `f_data_eq_local<T> where T <: Equatable<T>` / `f_data_cmp_local<T> where T <: Comparable<T>` 对 DataAssist 字段是否命中 Local* 的默认转调 |

P11~P16 已在 2026-11-21 的 p5/p6 探针中验证通过（见 3.4「实测记录」）；保留为后续回归检查项。p3/p4 验证过已放弃的方案 A（独立接口）。

## 附录 B：关键代码位置

| 位置 | 内容 |
| --- | --- |
| `f_svg/src/SvgAnalyticRasterizer.cj:124-180` | `analyticCoverage`；`166` 行 `Array<Float64>(width * height)` |
| `f_svg/src/SvgAnalyticRasterizer.cj:183-...` | `accumulateAnalyticRow`；每行 `active`/`events` |
| `f_llm/src/store/KnowledgeChunker.cj:33-68` | `split`；全文 `ArrayList<Rune>` |
| `f_excel/src/SheetXmlWriter.cj:112-160` | `writeCell`；每格属性列表与字符串 |
| `f_excel/src/PackageWriter.cj:125-218` | `ByteBuffer(256 * 1024)` 一次性 XML 部件 |
| `f_rule/src/rete/AlphaMemory.cj:147-188` | `range`/`select`；`ArrayList<FactHandle>` + `toArray()` |
| `f_egraph/src/base/QueuedClosureTask.cj:218-248` | `takeBatchLocked`；整队列 `toArray()` 快照 |
| `f_cache/src/HeapCache.cj:179-224` | `checkOverSize`；每轮迭代器数组与 map |
| `f_jsonrpc/src/client/JsonRpcClient.cj:107-152` | `batch`；`ids`/`requests`/`byId` |
| `f_jsonrpc/src/client/JsonRpcClient.cj:308-332` | `readCapped`；8 KB 读缓冲 |
| `f_mcp/src/server/McpServer.cj:1140-1164` | `truncateUtf8`；`toRuneArray()` 放大 |
| `f_httpclient/src/sse/SseReader.cj:145-175` | `readLine`；`ArrayList<Byte>` + `toArray()` 双份 |
| `f_data/src/json/DataJson.cj:92-110` | `toJsonString`；每字段中间 `valStr` |
| `f_base/src/LocalEquatable.cj`（新增） | `LocalEquatable <: Equatable`：`localEq(local?)` 抽象；`==(local?)` 默认转调 hook |
| `f_base/src/LocalComparable.cj`（新增） | `LocalComparable <: Comparable`：`localCompare(local?)` 抽象；`compare(local?)` 与运算符默认转调；自带 `localEq` 默认 |
| `f_data/src/macros/DataAssist.cj:88-139` | `assist`；attr 解析与 `equal`/`compare` 生成入口 |
| `f_data/src/macros/DataAssist.cj:349-401` | `generateEqual` / `generateCompare`；改为只生成 `localEq` / `localCompare` |
| `f_data/src/base/data_cmp.cj:18-65` | `f_data_eq` / `f_data_cmp`；新增 `_copy` / `_local` 模态 helper |
| `dev-guide/source_zh_cn/class_and_interface/interface.md:397` | 子接口不能把父接口的默认成员重新声明为抽象（方案 B 用 hook 的原因） |
| `std/core/equatable.cj:11-48` | `Equal` / `NotEqual` / `Equatable` 的 `@ local?` 成员与默认实现 |
| `std/core/comparable.cj:229-310` | `Comparable` 的 `compare(this @ local?, ...)` 与派生运算符 |
| `std/core/hashable.cj:11-21` | `Hashable.hashCode(this @ local?)`（后续扩展哈希时用） |
| `f_orm/src/base/SqlPartial.cj:123-143` | `UPDATE` 的 `HashMap<String, Any>` 中转 |
| `f_orm/src/base/RootDAO.cj:323-389` | `arg`；`Any` 装箱进 executor |
| `f_log/src/base/Logger.cj:47-51` | 每条日志 `TextTemplate.compile` |
| `f_security/src/JWTSecurityContext.cj:36,57,67` | 每请求两次 `JWT.verifier` |
| `f_email/src/mime/MimeWriter.cj:181-184` | Base64 String → `toArray()` 三重实体化 |
