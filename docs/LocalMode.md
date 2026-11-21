# fountain 与 local mode

> 状态：评估文档（2026-11-21）
>
> 依据：仓颉官方开发指南 `dev-guide/source_zh_cn/modal_type/` 下的 `modal_overview.md`、`local_mode_rules.md`、`exclave.md`、`copyable_and_demode.md`，以及 `Appendix/compile_options.md`、`Appendix/runtime_env.md`、`Appendix/keyword.md`。
>
> SDK 前提：`1.3.0-alpha` nightly（std 已合入 local mode，`Equatable`/`Comparable` 等带 `@local!` 重载）。local mode 仍是实验特性，语法、规则、编译选项都可能在后续版本变化。
>
> 说明：本文的 API 支持结论以官方文档为准；`StringBuilder`、`ByteBuffer`、`String.fromUtf8`、`InputStream.read`、`OutputStream.write`、`JsonValue` 等是否提供 local 重载，文档未逐一列出，落地前必须用附录 A 的探针实测。

---

## 0. 结论摘要

1. local mode 降低的是**峰值内存**，不是吞吐。它把“函数内临时对象”分配在线程的 local region，函数返回时整块释放，不等 GC；分配本身仍要付成本。
2. 模态会沿调用链传播：local 值不能传给普通（`@ ~local`）形参、不能返回、不能进字段/缓存/全局、不能进 spawn。因此它**不适合“构建结果对象”的路径**，只适合“函数内创建、函数内用完”的计算型临时区。
3. fountain 全仓生产代码目前**没有**任何 `@local!`/`@local?`/`exclave`；但已经被动受过 std 模态影响（`f_data` 的 `@DataAssist` 父接口归一化，见 `f_data/doc/spec/fix-dataassist-local-mode/`）。
4. 本项目最合适的策略是：**只在模块内部、只在元素为 `Copyable` 的容器上 local 化，公开 API 一律保持 `@ ~local`**。这样调用方无需开启 local mode，也不破坏已发布模块的 ABI。
5. 真正适合先试点的只有 **f_svg**（`analyticCoverage` 的 `width * height` 浮点累加器）和 **f_llm**（`KnowledgeChunker.split` 的全文 `ArrayList<Rune>`）。其余模块要么先做“去拷贝/去重复/复用缓冲”的结构优化，要么被接口 this-mode、泛型、FFI、跨线程锁死。
6. fountain 里多数热点用 local mode 收益很小甚至为负；结构性优化的收益更大，例如 `f_security` 每请求解析两次 JWT、`f_email` Base64 三重实体化、`f_log` 每条日志重新编译模板。

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
- 入口模块可以用 `override-compile-option` 统一开启，但这样**所有依赖模块中的 `exclave`、`demode` 都会成为关键字**。本仓库 `cjpm.toml` 的 `[package]` 和各 `[target.*]` 都写了 `compile-option`/`override-compile-option`，不要随手改成全局开启。
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
- **宏**：宏的参数和返回值只能 `@ ~local`。`@DataAssist` 这类宏生成的代码不能直接接 local 值。
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
2. **local mode 只做模块内部实现细节**：不新增、不修改公开模态签名；调用方无需开启 local mode。
3. **只改“分配规模大 + 元素 `Copyable` + 纯计算”的点**；小对象、接口方法、泛型方法不动。
4. **每个模块独立开启** `compile-option`，不要用 `override-compile-option` 把整棵依赖树拖下水。
5. **先探针、后改造**。文档只确认 `String`、`Array`、`ArrayList`、`HashMap` 有 local 写法；其余 API 必须实测。
6. **按峰值内存验收**：`-O2` 构建、同输入同负载，比较 peak RSS、`getAllocatedHeapSize()`、`getAllocatedLocalObjectSize()`。不要用吞吐量证明 local 的收益。

### 2.3 为什么不是“到处加 `@local`”

- 结果对象要返回/进缓存/进字段时，local 值不能逃逸，只能放弃 local，或在边界复制一份，收益被抵消。
- 大多数热点落在接口方法上（`IOStream`、`ToString`、`QueryResult`、`Datasource`、`Chart`、`RowSink`），这些方法的 this mode 不能单方面改。
- 很多入口是泛型（`publish<T>`、`decode<T>`、`extract<T>`、`BarrierTask<G>`），local mode 不支持在泛型参数上带 mode。
- 压缩、加密、字符集编码的大头在 stdx/native 堆，local region 管不到。
- 小对象高频分配时，local 的记账成本可能超过收益；官方文档也提示“常见类型并非每个 API 都支持所有 mode”。

---

## 3. 逐模块建议

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
| **f_data** | 数据对象/JSON | `f_data/src/json/DataJson.cj:92-110` 的 `toJsonString` 每字段先生成中间 `valStr`，再拼进父 builder，峰值约为最终 JSON 的 2 倍。收益最大的是改成写入式 sink（父 builder 直接接收子节点），不是 local；`DataObject<T>` 是泛型 + `ToJsonString` 接口实现，模态改不动。`@DataAssist` 宏的参数/返回值只能 `@ ~local`（宏限制），这是硬边界。 |
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

### 3.4 一眼判断

| 分类 | 模块 |
| --- | --- |
| 首批试点 | f_svg、f_llm（仅 rune 缓冲） |
| 第二批（先结构优化） | f_excel、f_rule、f_egraph、f_cache、f_jsonrpc、f_mcp、f_httpclient、f_xml |
| 需前置设施（f_data/f_io 的 local 能力） | f_jsonrpc、f_mcp、f_data、f_codec、f_http、f_chart、f_orm、f_dbd、f_mq、f_ticktock、f_zip |
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

- 只给真正写了 local 代码的模块加 `--experimental --enable-local-mode`；
- 每次只改一个模块，`cjpm build` + `cjpm test` + 基准三件套；
- 公开 API 保持 `@ ~local`，不新增模态签名；
- 不使用 `override-compile-option`。

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
8. **ABI/发布**：local 产物不保证跨 SDK 兼容；公开模态签名会迫使调用方开启 local mode 并同 SDK 编译。这是“只在模块内部用”的根本原因。
9. **工具链**：实验特性，cjfmt/cjlint/LSP/cjdb 不保证支持。
10. **宏边界**：宏参数/返回值只能 `@ ~local`；`@DataAssist` 生成的序列化/比较路径无法接 local 值。
11. **继承/接口重复路径**：std 的 `Equatable`/`Comparable` 已带模态重载，类型声明里重复列出祖先接口会报 `must be implemented ... @local!`；不要通过补 `@ local!` 解决，去掉重复父接口即可。详见 `f_data/doc/spec/fix-dataassist-local-mode/`。

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
| `f_orm/src/base/SqlPartial.cj:123-143` | `UPDATE` 的 `HashMap<String, Any>` 中转 |
| `f_orm/src/base/RootDAO.cj:323-389` | `arg`；`Any` 装箱进 executor |
| `f_log/src/base/Logger.cj:47-51` | 每条日志 `TextTemplate.compile` |
| `f_security/src/JWTSecurityContext.cj:36,57,67` | 每请求两次 `JWT.verifier` |
| `f_email/src/mime/MimeWriter.cj:181-184` | Base64 String → `toArray()` 三重实体化 |
