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
import fountain::f_jit.base.DummyDiagnosticsSink

main() {
    let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
    c.registerType<User>()                              // 暴露一个宿主类给方言
    let f = c.compile('{ u: User => u.name }')          // 编译（结果进 CompileCache）
    let name = f.call<String>([User('bob', 1)])         // 调用
    println(name)                                       // bob
}
```

带截止时间的中断式调用：

```cangjie
var ctx = CallContext()
ctx.deadline = Some(DateTime.now() + Duration.second * 1)   // 超时抛 InterruptedException
let v = f.invoke<Int64>([Int64(100_000_000)], ctx)
```

返回闭包（逃逸闭包，用后必须 `close()`）：

```cangjie
let f = c.compile('{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }')
let g = f.callForFn<(Int64) -> Int64>([Int64(7)])
println(g.call<Int64>([Int64(1)]))    // 8
g.close()                             // 释放提升组（唯一释放路径）
```

---

## 2. API

| 类型 | 用途 | 关键成员 |
|---|---|---|
| `Compiler` | 门面：注册宿主能力 + 编译 | `registerType<T>()`、`registerClass(desc)`、`registerFunction(f)`、`compile(src)` |
| `CompileOptions` | 编译选项 | `jit: JitMode`（`Auto`/`Force`/`Off`）、`strictFp`（缺省 `true`）、`verMajor`、`cpuFeatures`、`diagnostics` |
| `JitFunction` | 编译产物 / 可调用对象 | `call<T>(args)`、`invoke<T>(args, ctx)`、`callForFn<Fn>(args)`、`close()`、`isClosed` |
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
`PromotionGroup` 持有，唯一释放路径是 `JitFunction.close()`。

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

## 6. FAQ

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
| 逃逸闭包 / 其捕获 | `PromotionGroup` 持有；**`JitFunction.close()` 是唯一释放路径** | 宿主不 `close` 就一直驻留（契约，非 bug） |

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

---

## 7. 已知限制

- 机器码仅 Linux x86_64 / aarch64（其余平台解释执行）；
- x86_64 需 SSE4.1（缺则不 JIT 含取整指令的单元）；
- 回边每轮一次 H22 `interrupt_poll`；紧循环上该调用（内部含一次分配）成本显著，已记入
  `doc/spec/f-jit-m1/verify.md` 待优化；
- 逃逸闭包必须 `close()`，否则提升组常驻；
- 细节规格见 `doc/jit-bytecode-m1.md` / `doc/design-m1.md` / `doc/plan-m1.md`，验收见
  `doc/spec/f-jit-m1/verify.md`，性能见 `doc/perf-m1.md`。
