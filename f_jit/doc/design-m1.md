# f_jit 详细设计 · M1（字节码 · 解释器 · JIT 后端 · 桥）

> 依据：`jit-bytecode-m1.md` v0.18.36（同目录）。
> 本文把 M1 规格落到 `f_jit` 模块的**包级 / 顶级声明 / 公共成员**三级设计；M2、M3 增量见 `design-m2.md`、`design-m3.md`。
> 附录（文末）：**附 A** 语法元素 → 字节码 · **附 B** 字节码指令定义（M1 ISA 全表）· **附 C** 字节码 ↔ 机器码（JIT 后端）——同源摘录自规格 §5/§10/§12，冲突以规格为准；M2/M3 增量三表见各增量设计附录。
> 粒度约定：
> - 包 = `fountain::f_jit` 模块下的一个 Cangjie 包；
> - 顶级声明 = 包内顶层声明（class / interface / struct / enum / const / let / func）；
> - 公共成员 = 该声明的 public / protected 成员（字段、属性、构造函数、函数、静态成员、枚举构造器、常量）；
> - 签名以**草图**给出（个别类型随后续设计微调），语义以规格文档为准，每条附规格锚点。
> - **记法约定**：可选类型一律**前缀** `?T`（仓颉没有 `T?` / `x?` 写法）；数组与容器一律 `Array<T>` / `ArrayList<T>`（描述性文字里的 `x[]` 仅表示「逐个元素」）；**enum 构造器只写参数类型、不写参数名**（仓颉语法：`Red(UInt8)` 合法、`Red(v: UInt8)` 不合法——参数含义另以「参数序」说明）。
> 语言事实前提：仓颉禁止包间循环依赖 ⇒ 包依赖必须是 DAG；`internal` 只到「本包及子包」，**跨兄弟包共享一律用 `protected`**（module 级），用户面 API 由根包 `public import` 再导出（仓库既有惯例，见 `f_data`）。

---

## §0 架构级设计（职责 · 抽象 · 协作）

**设计目标**：把「一份字节码、四平台运行、Linux 加速」的规格实现为一个仓颉模块——语义正确的解释器 + 两个 JIT 后端 + 封闭的宿主边界（桥）。

**分层（自底向上）**：

| 层 | 包 | 职责一句话 |
|---|---|---|
| 契约层 | `fountain::f_jit.base` | 全模块共享的常量命名空间与公共值/异常类型（LocalType、token、错误码、JitException、CallContext…） |
| 模型层 | `fountain::f_jit.bytecode` | 字节码静态模型与 `.fbc` 编解码/加载校验（opcode 表、函数目录、常量表、站点/名字表、容器头） |
| 生产/消费层 | `fountain::f_jit.compiler` | 源入口前端：源码 → 字节码 → `.fbc`（词法/语法/降低/明确赋值/汇编校验） |
| 生产/消费层 | `fountain::f_jit.runtime` | 运行时：ctx、句柄表/窗口/逃逸区、迭代器表、helper 实现集、诊断转储、**解释器（语义基准）** |
| 生产/消费层 | `fountain::f_jit.backend` | JIT 后端：字节码 → 机器码（x86_64 / AArch64）、代码内存 W^X、fnTable、常量句柄镜像 |
| 门面/桥层 | `fountain::f_jit` | 用户 API 与桥：Compiler、JitFunction、Marshal（pin/逃逸/解包）、编译去重、适配器注册表、卸载编排 |

**核心抽象与形态选择**：

| 抽象 | 形态 | 理由 |
|---|---|---|
| 字节码（唯一分发产物） | `bytecode` 包的静态模型 + 编解码器 | 规范地位（P1）；跨平台 ⇒ 必须显式 LE 解码、无宿主信息 |
| 解释器（语义基准） | `runtime.Interp` | I7：结果/errCode/site/报告文本三引擎逐位一致，解释器是黄金基准 |
| JIT 后端（等价加速器） | `backend.Backend` 接口 + 两实现类 | 后续扩架构 = 「新增一张 lowering 表 + 一个 ABI 映射」（§13.3 演进约束） |
| 句柄表（宿主对象 ↔ 整数 ID） | `runtime.HandleTable`（class + 静态入口） | 冻结决策 ④：ID 形态；桥独占职责；仓颉 GC region 式搬移 ⇒ 裸指针不可行 |
| 错误通道 | ctx 错误槽 + `ErrCode` + `JitException` | fail-fast（I3/I4）；异常只存在于宿主边界 |
| 编译器门面 | `Compiler` 实例（class） | **每次编译新建实例**（配置 + 注册表快照，§8.4 快照语义）；编译缓存为**进程级**（根包 `CompileCache`，键 = 源码指纹）——D4 结案 |
| 源编译单元 | `JitFunction`（class） | 生命周期/卸载/并发调用的载体；`call<T>` 是唯一对外执行成员 |

**关键协作场景**（详见 §8）：compile 管线（§8.1/8.2）、call\<T\> 六步（§8.3）、三态收尾（§8.4）、错误报告（§8.5）、卸载（§8.6）。

**设计决策（模块级）**：

1. **包按「规范地位」而不是「对象」切分**：字节码模型/前端/运行时/后端各自独立成包——它们有不同的正确性论证方式（模型=格式校验；前端=编译期诊断；运行时=解释器语义；后端=I7 差分），分包使差分测试与回归边界清晰。
2. **共享契约沉到 `base`**：避免根包与子包之间的循环依赖（仓颉禁止）——所有被 ≥2 个包引用的类型放 `base`/`bytecode`，上层包只向下依赖。
3. **根包只做门面与桥**：`fountain::f_jit` 不承载执行逻辑，仅编排（管线/缓存/Marshal/卸载）并 `public import` 再导出用户面声明。
4. **`LocalType` / `ErrCode` / `TypeToken` 用「命名空间类 + static const」**：规格示例即 `LocalType.I64`（§8.4）；同时提供 `name()`/`isHandle()`/`describe()` 查询函数，避免散落魔法数字。
5. **ctx 用非托管内存承载、以访问器类包装**：ctx 必须 64 B 且不得移动（§4），Cangjie struct 布局不承诺逐字节映射 ⇒ `JitContext` 内部持 `CPointer<Int64>`，按规范偏移读写。非托管内存的分配/释放选型与理由（`std.core.LibC.malloc<T>` / `LibC.free<T>`；`acquireArrayRawData` 钉住方案不适用于跨整个调用的 ctx）见 §5.3.1 与 §9。
6. **helper 一律「`@C` 薄入口 + 普通 Cangjie 实现」**：三引擎共用同一实现（I7 结构性成立），失败一律写错误码、绝不抛异常（I4）。

---

## §1 包级定义与依赖关系

### 1.1 包清单

| 包 | 意义（职责边界） | 依赖（模块内） | 外部依赖（模块级） | 规格锚点 |
|---|---|---|---|---|
| `fountain::f_jit.base` | 共享契约：类型编码、错误码、公共值类型与异常、诊断接口 | 无（叶子包） | std.core、std.time、**f_base**（`BaseException` 基类） | §3.2、§8、§9.16 |
| `fountain::f_jit.bytecode` | 字节码静态模型与 `.fbc` 编解码/加载校验 | base | std.collection、std.math.numeric、std.time、std.regex、f_regex（Regex 常量构造链）、f_util（`Crc32.isoHdlc`；常量表指纹 `constFingerprint` 经 `Fnv64`） | §10、§11、§13.3 |
| `fountain::f_jit.compiler` | 源入口前端与汇编（源码 → `.fbc`），编译期诊断 | base、bytecode | std.core、f_regex（String.regex 扩展的静态检查） | §8.0、§8.5、§8.8、§11.7、§11.9 |
| `fountain::f_jit.runtime` | ctx/句柄表/迭代器表/helper 集/诊断转储/解释器 | base、bytecode | std.collection、std.math.numeric、std.time、std.regex | §1、§4、§6、§9.6、§9.16、§12.6 |
| `fountain::f_jit.backend` | JIT 后端（x86_64 / AArch64）与代码内存 | base、bytecode | std.core、std.env（OS/Arch 判定经 f_base） | §12 |
| `fountain::f_jit` | 用户 API 与桥：Compile 门面、JitFunction、Marshal、去重、卸载 | base、bytecode、compiler、runtime、backend | f_base（OS/Arch）、**f_util（FNV-1a-128 指纹：`Fnv128.fnv1a`）**、f_log（可选诊断） | §8、§8.1–§8.7 |

### 1.2 依赖图（DAG，禁止反向与跨层环）

```
                        fountain::f_jit  (门面/桥)
                 ┌──────────┬───────────┬────────────┐
                 ▼          ▼           ▼            ▼
        compiler      runtime      backend        （再导出 base/bytecode）
                 │          │           │
                 ├──────────┴───────────┤
                 ▼                      ▼
          fountain::f_jit.bytecode  ←────┘
                 │
                 ▼
          fountain::f_jit.base
```

规则：
- 依赖只能向下；`base` 不 import 模块内任何包；`bytecode` 只 import base；三个「生产/消费」包互不 import（共享物一律经 base/bytecode）；根包 import 全部。
- 跨包共享声明可见性用 `protected`；仅用户面 API 声明为 `public`。
- 根包对用户面声明做 `public import` 再导出（如 `public import fountain::f_jit.base.*`、`...runtime.HandleTable` 等，见 §7.6）。

### 1.3 规格 → 包映射总览

| 规格章节 | 落点 |
|---|---|
| §1 ctx / §2 错误码 / §3.1–3.2 帧与 cell / §8 JitFunction 骨架 | base（类型）+ runtime（ctx/句柄）+ 根包（JitFunction） |
| §3.3、§11.5 常量表 / §10 opcode 表 / §11.6–11.7 容器与目录 | bytecode |
| §4 入口 ABI / §6 helper ABI / §12.2–12.3 入口出口序列 | backend（机器层）+ runtime（ctx 布局） |
| §5 ISA / §7 伪指令与汇编校验 / §11.9 降低 | compiler（发射与校验）/ runtime（解释语义）/ backend（lowering） |
| §8.0–8.8 桥 / §9 附则 | 根包（桥）+ 各包按其义承接 |
| §11.1–11.9 跨平台格式 | bytecode（格式）+ compiler（前端规则） |
| §12.5–12.7 后端 | backend |
| §13 测试矩阵 | 无独立包；用例分落各层（见 plan-m1.md） |

---

## §2 包 `fountain::f_jit.base`

### 2.1 包意义

全模块的共享底层：**(a)** 类型/错误码常量命名空间（保证字节码编码与仓颉侧命名一一对应）；**(b)** 公共值类型（SourcePos/CallContext/SourceUnit/JitValue/JitMode/Engine）；**(c)** 公共异常（JitException/SourceCompileException）；**(d)** 诊断接口。不持有任何执行状态。

### 2.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `JitException` | class <: `f_base.BaseException` | 运行期错误载体（错误码 + site + 报告文本） | SourcePos、ErrCode、f_base | §2、§8 |
| `SourceCompileException` | class <: `f_base.BaseException` | 编译期错误载体（不占运行期错误码） | DiagKind、f_base | §8.4、§9.16 |
| `SourcePos` | struct | 源位置（站点表条目值） | — | §9.16 |
| `CallContext` | struct | 桥侧调用参数（`args` + `deadline`；编译期选项见 `CompileOptions`） | — | §8 |
| `SourceUnit` | struct | 分发入口输入（`.fbc` 字节 + 入口函数号） | — | §8、§11.6 |
| `JitMode` | enum | 引擎选择开关 | — | §12.1 |
| `Engine` | enum（protected） | 实际引擎（解释器/JIT） | — | §12.1 |
| `JitValue` | enum（protected） | 桥内部执行结果（invoke 路径） | — | §8 |
| `JitContext`（类型契约） | 见 runtime | ctx 的规范布局以常量/访问器暴露 | — | §1 |
| `DiagnosticsSink` / `DiagCode` / `DummyDiagnosticsSink` | interface / enum / class | 降级/告警接收器（(b)+(c) 双入口）、稳定事件码、空实现 | DiagnosticLevel | §8.4、§12.1（D1 结案） |
| `DiagnosticLevel` | enum | 诊断级别 | — | §12.1（规格从略处细化） |
| `LocalType` | class（常量命名空间） | LocalType 编码 0–12（M1） | — | §11.7 |
| `TypeToken` | class（常量命名空间） | 句柄类型 token 1–9（M1） | LocalType | §6 |
| `ErrCode` | class（常量命名空间） | 错误码 0/±/1–20/23/99 与描述 | — | §2 |
| `Version` | class（常量命名空间） | 本模块实现的字节码版本（verMajor=1、verMinor=14） | — | §11.6 |

### 2.3 各声明的公共成员

#### 2.3.1 `JitException`

| 成员（草图） | 意义 | 调用关系 |
|---|---|---|
| `init(code: Int64, site: Int64, fnId: Int64, sourcePos: ?SourcePos, message: String, cause: ?String = None)` | 由桥在报告组装完成后构造（报告文本经 `super(message)` 转发给基类） | 被根包 `Report.throwJit` 调用 |
| `let code: Int64` | §2 错误码 | 宿主处置分派；T6/T15 断言 |
| `let site: Int64` | code 段绝对字节偏移；-1 未知 | 与 sourcePos 互证（§9.16） |
| `let fnId: Int64` | 出错函数 id | 深帧归因（最深失败帧获胜） |
| `let sourcePos: ?SourcePos` | 站点表查得的源位置；不可得 → None | 报告文本；分发入口无文本路径 |
| `let message: String` | 按 code + site 静态表组装 + 源码行与变量（名/值/类型）报告 | 三类异常文本（① 无行号 ② 有行号 ③ 完整报告） |
| `let cause: ?String` | code=99 时 helper 原始描述（M2 起 21 含完整仓颉栈） | 诊断打印 |

**继承**：`JitException <: fountain::f_base.BaseException`（`public open class BaseException <: Exception`，定义见 `f_base/src/BaseException.cj`）——① 宿主可 `catch (e: BaseException)` 与其它 fountain 模块统一处理（`fountain::f_exception` 对该基类有 `public import` 再导出，两种 import 路径等价；本模块统一用 `f_base`）；② 报告文本即基类 `message` 语义（构造时 `super(message)` 转发），`code/site/fnId/sourcePos/cause` 为本类自有字段；③ 基类另提供 `init(caused: Exception)` / `init(message: String, caused: Exception)` 变体，本期不需要（M2 若要挂接原始仓颉异常再取用）。

#### 2.3.2 `SourceCompileException`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(kind: String, position: Int64, line: Int64, column: Int64, lineText: String, hint: String)` | 编译期失败统一抛出类型（组装后的文本经 `super(message)` 转发） | 前端/汇编各检查点抛 |
| `let kind: String` | 错误分类（`DiagKind` 常量，**清单见 §4.3.9**：词法族 `IllegalCharacter`/`UnterminatedString`/`BadEscape`/`BadNumber`/`UnterminatedRegex`/`UnterminatedComment`/`MultilineHeadContent`/`UnterminatedMultilineString`/`UnterminatedRawString` + 解析/名字/校验族 `UnregisteredFunction`/`UndefinedIdentifier`/`BadParameterList`/`MissingArrow`/`DuplicateRegistration`/`NotImpl`） | 测试断言 kind；消息含名字/位置/已注册清单（§8.4 需求 4） |
| `let position: Int64` | 源码字节位置 | 定位 |
| `let line: Int64` / `let column: Int64` | 行/列（1 起，列按 Unicode 码点） | 报告 |
| `let lineText: String` | 错误所在源码行原文（不含换行） | 「错误信息包含源码行文本」的兑现 |
| `let hint: String` | 修复提示（含已注册函数清单） | 用户可读性（T50） |

**继承**：`SourceCompileException <: fountain::f_base.BaseException`——编译期错误的统一类型；`message` 由 `kind/position/line/column/lineText/hint` 组装后经 `super(message)` 转发，宿主可 `catch (e: BaseException)` 统一处理。

#### 2.3.3 `SourcePos`（struct）

| 成员 | 意义 |
|---|---|
| `let line: Int64` | 1 起 |
| `let column: Int64` | 1 起（Unicode 码点） |
| `const init(line: Int64, column: Int64)` | 站点表条目构造 |

#### 2.3.4 `CallContext`（struct）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `var args: Array<Int64>` | 入参 cell 数组（Marshal 结果） | 三态收尾第 2 步 `rawEntry(ctx, &args[0], nargs)` |
| `var deadline: ?DateTime` | 配合 `interrupt_poll`（-2 取消） | LOOP_BACK 安全点查询 |

**只装调用级选项（X3 订正）**：`literalCopy` 与 `strictFp` 已从 `CallContext` 移除。前者从无消费语义（字面量是编译期常量，桥层没有「深拷贝字面量」的时机）；后者是**产物属性**，归 `CompileOptions.strictFp`——**缺省 `true`**（`Float64` 的 `/` 发射 `FDIV_CHK`，÷0 → 1）；显式置 `false` 才走 IEEE（`FDIV`，÷0 → ±Inf）。`ctx.flags` bit0 保留为历史位，运行期不读。

#### 2.3.5 `SourceUnit`（struct）

| 成员 | 意义 |
|---|---|
| `let raw: Array<UInt8>` | 已加载 `.fbc` 容器字节（v0.18.25 起四段：code/const/site/name；§8.2 注释里的「三段」为旧版遗留，以 §11.6 为准） |
| `let entryFn: UInt32` | 期望入口函数 id（须与容器头 `entryFn` 一致，否则加载期拒绝） |

#### 2.3.6 `JitMode`（enum） / `Engine`（enum，protected） / `JitValue`（enum，protected）

三者合并成节：都是**纯值枚举**（无方法、无模块内依赖，随 base 包被三个引擎共享），且串成同一条链路——**用户意图（`JitMode`）→ 实际事实（`Engine`）→ 桥内执行结果（`JitValue`）**；这是 I7（三引擎语义一致）在类型层的落点。

| 类型 | 构造器 | 意义 | 锚点 |
|---|---|---|---|
| `JitMode` | `Off` \| `Auto` \| `Force` | 引擎选择开关（`CompileOptions.jit`，默认 `Auto`） | §12.1 |
| `Engine` | `Interp` \| `Jit` | 实际引擎（diagnostics 记录；测试可断言） | §12.1 |
| `JitValue` | `Int(Int64)` \| `Float(Float64)` \| `Handle(Int64)` \| `Unit` | 桥内部 `invoke` 结果；`Handle` = 已按 §8.1 逃逸的句柄 ID | §8、§8.1 |

**`JitMode`（输入侧「用户意图」）**

- 三档：`Off` → 不产生机器码，直接走解释器；`Auto` → 平台可用则 JIT（另以字节码指纹为缓存键）；`Force` → 期望 JIT。
- **不可用一律静默降级**：非 Linux 平台（Windows/macOS/HarmonyOS）与 SDK 未支持指令集下，`Force` 亦降级为解释器——**接口与语义完全一致，只记 diagnostics，不报错、不改语义**（§12.1 冻结决策、§9 附则 10；判定链见 §12.1 引擎选择伪码）。
- **边界（不可混同的两种处置）**：**32 位宿主不是降级，而是构建期/装载期明确拒绝**（cell 64 位、ctx 64 字节是硬前提，§12.1 表、§9 附则 9）。

**`Engine`（输出侧「实际事实」）**

- **与 `JitMode` 的分离是刻意的**：`Force` 成功时二者同为 JIT；失败时 `Engine = Interp` 而用户传入的 `JitMode` 不被改写——「配置」与「事实」是两条信息，缺后者就无法断言降级是否真的发生。
- **产出者**：`BackendSelector.select(mode, diag): (Engine, ?Backend)`（§6.3.4），由桥管线第 3 步调用（§8.1）。
- **消费者**：`diagnostics` 记录（§2.3.7）、测试断言（T7/T9）、`JitFunction` 内部状态（§7.3.3）。
- 可见性：**`protected`**（模块内共享，不对用户开放；选择结果经 diagnostics 记录、模块内测试（`src/test/...`）可直接断言——**D6 结案**，见 §8.7）。

**`JitValue`（桥内执行结果）**

- **产生点唯一**：`invoke`/`tryInvoke`（private，§7.3.3）三态收尾第 3 步的 `errCode == 0` 分支（§8.4）；`-1`（DEOPT 重跑，对调用方透明）/`-2`（中断）/`>0`（报告）三条路径**不产生** `JitValue`，`tryInvoke` 把其中的 `throw` 收进 `Result.Err`。
- **构造器 ↔ cell 载荷一一对应**（§3.2）：`Int` = i64 直值、`Float` = f64 位型、`Handle` = 句柄 ID（**已按 §8.1 逃逸**，宿主经 `HandleTable.get(id)` 取回对象）、`Unit` = 无返回值（同样是 errCode = 0）。
- **选 enum 而非 `Any`**：① 与 cell 1:1、零装箱——该入口定位是热路径/批量调用；② **显式区分值型与句柄型**，因为两者回收规则不同：`call<T>` 路径解包后**自动回收**窗口逃逸槽，而 `invoke` 路径的 `Handle` **只能显式 `release`**（§8.1 规则 6②③：ID 是可复制的普通整数、无引用计数回调、GC 不通知桥、`JitValue` 为值类型；错误 16 亦不做批量清理，否则会作废宿主仍在使用的 ID）。
- **分派提醒**：`Handle` 与 `Int` 的载荷同型（Int64）——**按构造器标签分派，不得按载荷类型判断**。
- 可见性：**`protected`**（唯一消费者 `invoke`/`tryInvoke` 为 private，无用户面路径；规格 §8 行 827 的 `public` 已同步为 `protected`——**D3 结案**，见 §8.7）。

#### 2.3.7 `DiagnosticsSink`（interface） / `DiagnosticLevel`（enum） / `DiagCode`（enum） / `DummyDiagnosticsSink`（class）

| 成员 | 意义 |
|---|---|
| `func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit` | **结构化入口（主签名）**：降级/告警 + **稳定事件码** |
| `func diag(level: DiagnosticLevel, message: String): Unit` | 便捷入口（默认实现：`code = Unspecified` 转发主签名） |
| `DiagnosticLevel` | `Info \| Warn`——**只有两档**（D1 结案）：错误一律走**异常**（`SourceCompileException` / `JitException`），**走不到 diag** |
| `DiagCode` | 稳定事件码（可断言、可 `match`）：`JitFallback`（引擎降级：非 Linux / 架构不支持）· `MmapFailed`（§12.5 分配失败降级）· `RegistrationSkipped`（M2/M3 注册跳过）· `PredefinedLimit`（注册上限）· `PlanFallback`（M3 特化冷路径）· `Unspecified` |
| `DummyDiagnosticsSink` | **空实现**（两个入口皆空操作）：`CompileOptions` 未显式传入时的默认值，兼测试用 |

**契约（D1 结案，2026-10-11）**：

1. **不承担错误通道**：`diag` 只收降级/告警；编译/调用失败一律异常（与 §4.3.1「编译期错误只有一个出口」一致）。
2. **不承诺串行化**：`diag` 可能在并发 `compile` 的不同线程上被调用；**线程安全由实现方（仓颉侧）负责**——本模块不加锁、不排队。
3. **sink 异常由引擎吞掉、挂 Suppressed（2026-10-11 裁定，D1）**：引擎在 `diag` 调用处 `catch (e: Exception)` 吞掉 sink 抛出的异常，**绝不因诊断失败改变可观察语义**：

   **术语**：**sink 异常** = `DiagnosticsSink` 实现（宿主写的 `diag` 回调）**自身抛出**的异常——不是引擎的失败，而是"诊断接收端"出错（写日志失败、格式化出错、实现 bug…）；**在途异常** = 调用 `diag` 那一刻**已处于异常路径、正要向上传播**的那个异常（如 `SourceCompileException` / `JitException`；代码形态上就是 `catch` 块里正在处理的 `e`）——**正常路径**（降级通知等）调用 `diag` 时**没有**在途异常。两者互相独立：在途异常是"真正的失败"（照常传播），sink 异常是"诊断回调自身的错误"（被吞/被挂）。

   - **有在途异常**（错误路径 / 编译失败）：把 sink 异常挂到**在途异常**上（`在途.addSuppressed(sinkEx)`）——**在途的那个才是要传播的**。**方向说明**：`addSuppressed` 挂在**接收者**身上（`A.addSuppressed(B)` ⇒ B 进 A 的 `suppressed` 列表）；本情形接收者是「在途异常」，与「**新异常**必须传播、原异常挂它」（包装场景：`新.addSuppressed(原)`）**方向相反**——两者的共同不变量是「**信息不丢 + 不让次要异常遮盖真正要传播的那个**」。（API 由 `fountain::f_base.BaseException` 提供：`suppressed` 属性 + `printStackTrace` 的 `Suppressed:` 段；仓库既有先例：`f_pool`/`f_mvc`/`f_aspect` 的收尾合并。）
   - **无在途异常**（降级通知等正常路径）：**仅吞掉**，不抛出、不降级失败（T7「`Force` 在非 Linux 上不报错」据此成立）；
   - **`Error`（灾难性，如 OOM/栈溢出）不捕、不吞**；
   - **不重入 diag**：sink 自身的失败不得再触发诊断（避免递归）。

   sink 抛出的异常**建议**为 `fountain::f_base.BaseException` 的子类（便于宿主统一 `catch`）；**挂载只要求参数是 `Exception`**（`addSuppressed(suppressed: Exception)`），而**接收者**（在途的 `JitException`/`SourceCompileException`）均为 `BaseException` 子类、自带 `suppressed` 设施 ⇒ 类型不是引擎正确性的前提（引擎按 `Exception` 兜捕）。

`message` 是**自由文本、不冻结**（改文案不算破坏兼容）；供断言/匹配的是 **`level` + `code`**（T7 断言 = 存在 `(Warn, JitFallback)`，**不匹配 message 文本**）。

#### 2.3.8 `LocalType`（常量命名空间类）

| 成员 | 值 | 意义 |
|---|---|---|
| `static const I64 / F64 / BOOL / UNIT` | 0–3 | 值型槽 |
| `static const STRING / DECIMAL / DATETIME / DURATION / RANGE / REGEX` | 4–9 | 句柄型槽（不可变值） |
| `static const LIST / MAP` | 10–11 | 容器（M1：参数槽 + v0.18 起全槽位） |
| `static const CLOSURE` | 12 | 内部闭包值（M1 链内） |
| `static func name(code: UInt16): String` | — | 调试/报告用 |
| `static func isHandle(code: UInt16): Bool` | — | 4–12 判定（空安全/写保护检查共用） |
| `static func fromToken(tok: UInt16): UInt16` | — | token ↔ LocalType 桥接（§11.7 一一对应表） |

#### 2.3.9 `TypeToken`（常量命名空间类）

| 成员 | 值 | 意义 |
|---|---|---|
| `static const LIST / MAP / STRING / DECIMAL / DATETIME / DURATION / RANGE / REGEX / CLOSURE` | 1–9 | 句柄槽 tag / IS_TYPE / GUARD_TYPE / H17–H19 编码 |
| `static const RESERVED` | 0 | 保留（加载器遇 0 拒绝） |
| `static func name(tok: UInt16): String` | — | 诊断 |

#### 2.3.10 `ErrCode`（常量命名空间类）

| 成员 | 值 | 意义 |
|---|---|---|
| `static const OK / DEOPT / INTERRUPT` | 0 / -1 / -2 | 非错误态（OK 走值路径、DEOPT 回解释器、INTERRUPT 抛 InterruptedException） |
| `static const DIV_ZERO … READONLY` | 1–20 | §2 错误码（含 15 STACK_GUARD、16 HANDLE_WINDOW_FULL、17 EXPLICIT、18 NOT_IMPL、19 CALL_CONTRACT、20 READONLY） |
| `static const CONCURRENT_MOD` | 23 | Map 迭代中修改（fail-fast） |
| `static const HELPER_PANIC` | 99 | 引擎侧兜底（msg 前缀 internal helper failure） |
| `static func describe(code: Int64): String` | — | 桥静态表（无宏）：code → 文本（§2 映射表；21/22 的 M2/M3 行后续版本追加） |
| `static func isHostSide(code: Int64): Bool` | — | M2 起 21 判定占位（M1 恒 false） |

#### 2.3.11 `Version`（常量命名空间类）

| 成员 | 值 | 意义 |
|---|---|---|
| `static const MAJOR: UInt16 = 1` | — | M1 产物 verMajor |
| `static const MINOR: UInt16 = 14` | — | 本实现写出的 verMinor（v0.18.25） |
| `static const HDR_SIZE: UInt32 = 36` | — | 新布局头长度（旧单元 32 走兼容分支） |
| `static const MAGIC: UInt32` | "FBC1" | 容器 magic |

---

## §3 包 `fountain::f_jit.bytecode`

### 3.1 包意义

字节码的**静态模型与格式实现**：opcode 表（§10）、指令解码（§11.2 显式 LE）、函数目录与局部类型表（§11.7）、常量段模型与拼装期注册 API（§3.3/§11.5）、站点表/名字表（§11.6）、容器头与读写（§11.6）、加载期校验（§11.6/§11.7/§13.3）。不做执行、不做降低。

### 3.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `OpInfo` | struct（含 static 成员：`static const CAT_*` 12 个、`static let OPCODE_TABLE`） | 单条 opcode 元信息（code/name/fmt/len/cat）+ 类别码常量 + 全量 256 项表（反汇编/汇编校验/调试器共用） | — | §10.2–10.3 |
| `ByteReader` / `ByteWriter` | class | 显式 LE 编解码原语（禁 memcpy） | — | §11.2 |
| `DecodedInsn` / `InsnDecoder` | struct / class | 单指令解码（按 fmt/len）与操作数读取 | OpInfo、ByteReader | §10.2、§11.2 |
| `FuncEntry` | struct | 函数目录条目（26 B） | — | §11.7 |
| `FuncFlags` | class（常量命名空间） | `static const MUTATION = bit0`（含变更型调用） | — | §9.15、§11.7 |
| `FuncDir` | class | 函数目录（增/查/校验） | FuncEntry | §11.7 |
| `LocalTypes` | class | 每函数局部类型表（每槽 1 B） | LocalType | §11.7 |
| `ConstKind` | class（常量命名空间） | `static const` 线上 kind 码 1–10（M1；M3 +11=Json） | — | §11.5 |
| `ConstPayload` | enum（带载荷构造器） | 常量载荷（与 kind 一一对应；实例化/编解码 `match` 分派） | — | §11.5 |
| `ConstRegistry` | class | 常量表：拼装期注册 + 加载期实例化 + freeze | ConstPayload | §3.3、§6、§11.5 |
| `SiteEntry` / `SiteTable` | struct / class | 站点表（off→line/column；升序唯一） | SourcePos | §11.6、§9.16 |
| `NameEntry` / `NameTable` | struct / class | 变量名表（稀疏，仅源码级命名槽） | — | §11.6 |
| `FbcFlags` | class（常量命名空间） | `static const` bit0 UTF-8 / bit1 NEED_JIT（恒 0）/ bit2 值运算类 | — | §11.6 |
| `FbcHeader` | struct | 容器头（40 B payload 起点；旧布局分支） | Version | §11.6 |
| `FbcWriter` | class | 组装容器（含 crc32 计算——`f_util.Crc32.isoHdlc`） | FbcHeader、各表 | §11.6 |
| `FbcReader` | class | 加载校验 + verMajor/verMinor 分派 + 段解析 | 各表、ConstRegistry | §11.6、§11.7、§13.3 |
| `LoadedUnit` | class | 加载产物（header/code/consts/site/name/dir/localTypes） | 各表 | §11.6–11.7 |

### 3.3 各声明的公共成员

#### 3.3.1 `OpInfo`（struct；static 成员 `CAT_*` / `OPCODE_TABLE`）

| 成员 | 意义 |
|---|---|
| `let code: UInt8` / `let name: String` / `let fmt: String` / `let len: Int64` / `let cat: UInt8` | 元信息五元组（len 平台无关） |
| `const init(code, name, fmt, len, cat)` | 表项构造 |
| `static const CAT_MISC/CONST/LOCAL/I64/F64/CMP/CTRL/CALL/TYPE/BOX/FORBID/RSVD: UInt8`（0–11） | 类别码（访问形式 `OpInfo.CAT_CALL`；编译期常量，可用于 `const` 上下文） |
| `static let OPCODE_TABLE: Array<OpInfo>` | 256 项全量（未分配槽 = `OP_RSVD`/`CAT_RSVD`；0xA9–AA = `CAT_FORBID`；0xC0–FF = RSVD 预留 M2） |

**为何 `OpInfo` 是 struct 而非 class**：它是**只读元信息**（5 字段全 `let`、无身份、无行为），访问模式是「按下标取一条 → 读字段」——值语义复制是**浅拷贝约 5 个字**（`String` 字段只复制引用，不复制字符数据），全程无堆分配、无 GC 扫描、无指针追逐；`Array<OpInfo>` 对 struct 元素**内联连续存储**（256 项紧排、缓存友好），而 `Array<class>` 是引用数组（指针追逐 + 静态期 256 次堆分配 + 别名风险）。`DecodedInsn` 持有 `OpInfo` 副本也不会与表项共享可变状态。

#### 3.3.2 `ByteReader`（class） / `ByteWriter`（class）

| 成员 | 意义 |
|---|---|
| `ByteReader.init(data: Array<UInt8>, off: Int64 = 0)` | 读游标（起点 `off`） |
| `ByteReader.u8(): UInt8` / `u16(): UInt16` / `u32(): UInt32` / `i32(): Int32` / `i64(): Int64` / `f64bits(): UInt64` | 显式小端解码（跨端序主机一致） |
| `ByteReader.bytes(n: Int64): Array<UInt8>` / `remaining(): Int64` | 段读取 / 剩余长度 |
| `ByteWriter.init()` | 空写缓冲 |
| `ByteWriter.wU8(v: UInt8)` / `wU16` / `wU32` / `wI32` / `wI64` / `wBytes(Array<UInt8>)` | 显式小端写出 |
| `ByteWriter.take(): Array<UInt8>` | 取出产物 |

**归属**：**读侧全部在 `ByteReader`、写侧全部在 `ByteWriter`**（两者都是**有状态游标**——读位置 / 写缓冲——故用 class）。`FbcHeader.read(r)/write(w)`、`FbcReader`、`BytecodeBuilder` 都直接复用这一对类型；除它们之外不再有第二套字节读写原语。

#### 3.3.3 `InsnDecoder`（class） / `DecodedInsn`（struct）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `InsnDecoder.decode(code: Array<UInt8>, off: Int64): DecodedInsn`（`static`） | 按 `OpInfo.OPCODE_TABLE` 解出 op 与操作数 | 解释器取指、汇编校验、反汇编 |
| `InsnDecoder.u16(insn, i): UInt16` / `i32(insn, i): Int32` / `i64(insn, i): Int64` / `rel32(insn, insnOff): Int64`（`static`） | 操作数读取（rel32 目标 = 下一条指令 + offset） | §5 编码约定 |
| `DecodedInsn.op: UInt8` / `.size: Int64` / `.operands: Array<UInt8>` | 解码产物（**纯数据 struct**，不带行为） | — |

**归属**：**解码与操作数读取全在 `InsnDecoder`**（该类只放 `static` 函数、无实例状态；操作数读取的首参即解码产物 `insn`）；**`DecodedInsn` 只持数据**（struct：值语义、按值传递，不与产物表或调用方共享可变状态）。

#### 3.3.4 `FuncEntry`（struct） / `FuncFlags`（class，常量命名空间） / `FuncDir`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `FuncEntry.fnId/codeOff/codeLen/localTypesOff: UInt32`、`.nargs/nLocals/maxStack/retType/flags: UInt16` | 目录字段（恒 26 B） | 加载校验；`CALL_FUNC` 解析；帧计算 |
| `FuncEntry.SIZE: Int64 = 26`（`static const`） | 定长 | 编解码 |
| `FuncFlags.MUTATION: UInt16 = 1`（`static const`） | 含变更型调用（H43–H48 / user helper / CALL_CLOSURE）→ deopt 禁令 + 防御兜底依据 | §9.15、§7 校验 11 |
| `FuncDir.add(e: FuncEntry)` / `get(fnId: UInt32): FuncEntry` / `find(fnId): ?FuncEntry` / `size: Int64` | 目录维护与解析 | 汇编器建目录；`CALL_FUNC` 校验（§7 校验 7） |
| `FuncDir.validate(codeLen: UInt32, entryFn: UInt32)` | 加载期校验（off/len 落在 code 段、entryFn 命中） | `FbcReader` |

**归属**：`FuncEntry` = **定长只读目录项**（struct：值语义、无身份，目录内连续存储）；`FuncFlags` = 只放**常量**（`static const MUTATION` = bit0，即 `FuncEntry.flags` 的取值域）；`FuncDir` = **可变目录容器**（class：`add/get/find/size/validate`）。

#### 3.3.5 `LocalTypes`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(nLocals: Int64)` | 申请 nLocals 槽 | 汇编器/加载器 |
| `get(slot: Int64): UInt8` / `set(slot: Int64, t: UInt8)` | 槽类型读写（载荷=LocalType 码） | 前端写；解释器/转储/报告读 |
| `size: Int64` | 槽数（= FuncEntry.nLocals） | 校验 |
| `validate(dir: FuncDir, fnId: UInt32)` | 长度恰为 nLocals、类型值合法（加载器拒绝 13–255） | `FbcReader` |
| `isHandleSlot(slot: Int64): Bool` | 空安全/写保护共用判定 | 前端明确赋值、PUSH_NULL 校验 |

#### 3.3.6 `ConstKind`（class，常量命名空间） / `ConstPayload`（enum） / `ConstRegistry`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `ConstKind.I64=1 / F64=2 / STRING=3 / LIST=4 / MAP=5 / DECIMAL=6 / DATETIME=7 / DURATION=8 / RANGE=9 / REGEX=10` | 常量 kind（M3 追加 11=Json） | 序列化分派 |
| `ConstPayload` 构造器：`PI64(Int64) / PF64(UInt64) / PStr(String) / PList(Array<UInt32>) / PMap(Array<(UInt32,UInt32)>) / PDec(UInt8,Int32,String) / PDateTime(Int64) / PDuration(Int64) / PRange(Int64,Int64,Int64,Bool) / PRegex(String,UInt8)` | 载荷（DAG：list/map 引用子索引；环检测在加载期） | 编解码 |
| `ConstRegistry.addList<T>(ArrayList<T>): Int64` | 注册列表常量 → hid（拼装期） | `Lowerer`（非空字面值） |
| `ConstRegistry.addMap<K,V>(HashMap<K,V>): Int64` | 注册映射常量 → hid | `Lowerer` |
| `ConstRegistry.addStr(String): Int64` | 字符串常量 → hid | `Lowerer`（三形态字符串 + 插值片段） |
| `ConstRegistry.addValue(Decimal 或 DateTime 或 Duration): Int64` | 值常量 → hid | `Lowerer` |
| `ConstRegistry.addRange(start,end,step,isClosed): Int64` | 区间常量 → hid | `Lowerer`（`a..b` / `a..=b` 字面值） |
| `ConstRegistry.addRegex(pattern: String, flags: UInt8): Int64` | 正则常量 → hid（同 (pattern,flags) 去重；flags 归一为位域） | `Lowerer`（kind 10；加载期同 API 复用） |
| `ConstRegistry.freeze(): Unit` | 冻结（之后只读；`PUSH_KH` 校验依赖） | `Assembler` |
| `ConstRegistry.size: Int64` / `get(i: Int64): ConstPayload` | 查询 | 序列化/加载 |
| `ConstRegistry.isFrozen: Bool` | 状态 | 校验 |

**归属**：`ConstKind` = **常量命名空间类**（`static const I64…REGEX`；不用 enum 的原因：枚举构造器**不携带数值**，而 kind 是 §11.5 的**线上码**，序列化与分派都要确定数值）；`ConstPayload` = **enum**（闭合变体集，与 kind 一一对应，实例化/编解码一律 `match` 分派）；`ConstRegistry` = **可变容器**（class：注册/去重/冻结/查询；持有状态且必须共享同一实例——若用 struct，赋值处会被静默浅拷贝成两份表）。

#### 3.3.7 `SiteEntry`（struct） / `SiteTable`（class） / `NameEntry`（struct） / `NameTable`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `SiteEntry.off/line/column: UInt32`（恒 12 B） | 站点条目 | 序列化 |
| `SiteTable.add(off: UInt32, pos: SourcePos)` / `freeze()` / `lookup(site: Int64): ?SourcePos` | 维护与查询（取 off ≤ site 的最大条目） | 前端写；桥报告读；加载器校验覆盖/升序 |
| `NameEntry.fnId/slot/strOff/strLen: UInt32`（恒 16 B） | 名字条目 | 序列化 |
| `NameTable.add(fnId: UInt32, slot: UInt32, name: String)` / `freeze()` / `lookup(fnId: UInt32, slot: UInt32): ?String` | 稀疏名字查询（未命中 → 报告省略名字） | 前端登记源码级命名槽；桥报告读 |
| `NameTable.validate(dir, types)` | 键命中目录、slot < nLocals、升序唯一、UTF-8、`strLen ≥ 1`、范围合法 | `FbcReader` |

#### 3.3.8 `FbcHeader`（struct） / `FbcWriter`（class） / `FbcReader`（class） / `LoadedUnit`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `FbcHeader.magic/verMajor/verMinor/flags/hdrSize/codeLen/constLen/siteLen/entryFn/nameLen/crc32` | 容器头字段（偏移 0/4/6/8/12/16/20/24/28/32/36） | 读写 |
| `FbcHeader.read(r: ByteReader): FbcHeader` / `write(w: ByteWriter)` | 编解码（含 verMinor ≤13 旧布局分支：无 nameLen、payload=36、hdrSize=32） | 加载/写出 |
| `FbcWriter` 设置器系列：`setEntryFn(fnId)` / `setCode(bytes)` / `setConst(bytes)` / `setSite(bytes)` / `setName(bytes)` / `setFlags(flags)` / `build(): Array<UInt8>` | 组装容器（crc32 覆盖 code+const+site+name） | 汇编器产出 |
| `FbcReader.load(raw: Array<UInt8>): LoadedUnit` | 加载校验全流程（magic/版本分派/未知 flags 拒绝/段长/nameLen 布局/常量 DAG 环检测与载荷合法性/kind10 Regex 实例化/kind 3–9 实例化/FuncDir/LocalTypes/site 覆盖与升序/name 键合法/crc32） | 根包 `compile(unit)`、测试 T1/T50 |
| `FbcReader.supportedMajor` / `minVerMinorOf(major)` | 兼容矩阵（M1 加载器仅接受 verMajor 1；M2/M3 加载器按 major 分派规则集） | 版本演进（§13.3） |
| `LoadedUnit.header: FbcHeader` / `.code: Array<UInt8>` / `.consts: ConstRegistry` / `.site: SiteTable` / `.name: NameTable` / `.dir: FuncDir` / `.types: Array<LocalTypes>` | 加载产物 | runtime/backend/桥共用 |

**指纹口径（D5 结案，2026-10-11；实现一律经 `fountain::f_util` 的 FNV 实现——`f_jit` 不自实现哈希）**：

| 指纹 | 算法 / 输入 | 用途 | 落盘 |
|---|---|---|---|
| 源码指纹 | **FNV-1a-128**（**换行规范化之后**的源码 UTF-8 字节） | `compile(source)` 去重键（§7.3.5、§8.1） | 不进 `.fbc` |
| 字节码指纹 | **FNV-1a-128**（**整份** raw `.fbc`：头 + 目录 + 类型表 + 四段） | `compile(unit)` 去重键（§8.2）+ JIT 产物缓存键 `(arch, cpuFeatures, 字节码指纹)`（§12.5） | 不进 `.fbc` |
| `constFingerprint` | FNV-1a-**64**（常量表内容） | 缓存键辅助 / 诊断 | **落盘**（§11.5） |

- **碰撞 = 语义错误**（去重键撞车 ⇒ 返回**别的** `JitFunction`）⇒ 缓存条目**保存原始输入字节**，命中后做**长度 + 字节二次校验**（不符按 Miss 重编）。
- **不得用 `crc32` 代替**：它只覆盖 code+const+site+name 四段（头/目录/类型表不在内），且仅 32 位。
- 三者**互不混用**（D5 已点明「分开」）；调用点：`Fnv128.fnv1a`（去重键）、`Fnv64.fnv1a`（`constFingerprint`）、`Crc32.isoHdlc`（`crc32` 字段）。

**`crc32` 口径（冻结）**：CRC-32/ISO-HDLC（反射、poly=0x04C11DB7、init/xorout 全 1——zlib/gzip/PNG/以太网同款），覆盖 code + const + site + name 四段字节；**实现直接用 `fountain::f_util.Crc32.isoHdlc`（不自实现）**——与 f_protocol 帧校验、f_store WAL 校验同款（仓库一致）。基准向量：`crc32(空) = 0`、`crc32("123456789") = 0xCBF43926`。写方（汇编器 `FbcWriter`）与读方（M1/M2/M3 加载器、分发入口）必须同一口径。

---

## §4 包 `fountain::f_jit.compiler`

### 4.1 包意义

源入口前端（§8.0 lambda 源格式）与汇编：**词法 → 语法 → 名字解析 → 明确赋值分析 → 降低（含规范控制流模式）→ 字节码构建 → 汇编期校验（§7 校验 1–11）→ `.fbc` 组装**。产出 `SourceCompileException`（编译期）而非运行期错误。

### 4.2 顶级声明清单

| 声明 | 形态 | 可见性 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|---|
| `TokenKind` / `Token` | enum / struct | internal | 词法单元 | — | §8.0、§8.5、§8.8 |
| `Lexer` | class | internal | 词法分析（三形态字符串、嵌套注释、正则字面量、词法保护顺序） | Token | §8.5、§8.8 |
| `AstExpr` / `AstStmt` | enum / enum | internal | 语法树（表达式 / 语句节点；载荷可递归） | Token | §8.0 |
| `LambdaAst` / `ParamAst` | struct / struct | internal | lambda 与形参骨架（记录型纯数据、值语义） | Token、TypeRef | §8.0 |
| `TypeRef` | enum（M1 仅 `Builtin`） | internal | 类型注解节点（M1 内建/容器类型名；M2 追加 `HostClosureT`/`HostObjectT`、M3 追加 `AnyT`） | — | §11.7、m2 §3、m3 §3 |
| `Parser` | class | internal | lambda 源入口语法 | Ast* | §8.0 |
| `NameResolver` | class | internal | 调用点解析（recursive → user helper → 未注册错误） | Token、注册表快照 | §8.4 |
| `ResolvedCall` | enum | internal | 调用点解析结果：`Recursive`（自递归）/ `UserHelper(UInt16)`（槽号） | — | §8.0、§8.4、§8.5 |
| `DefiniteAssignment` | class | internal | 明确赋值与空安全数据流（回边不动点） | Ast*、LocalTypes | §7 校验 10、§5 |
| `Lowerer` | class | internal | AST → 字节码（全部规范降低模式） | BytecodeBuilder、ConstRegistry、NameResolver | §5、§8.5–8.6、§11.9 |
| `BytecodeBuilder` | class | internal | 单函数发射器（label/fixup、site 记录、自动 CHECK_ERR） | ByteWriter、OpInfo | §7、§5 |
| `Assembler` | class | internal | 汇编期校验 1–11 + 组装 `.fbc`（目录/类型表/site/name） | BytecodeBuilder、各表、FbcWriter | §7、§11.6–11.7 |
| `CompileSession` / `FuncBody` | class / struct | internal | 一次 `compile` 的**单元级累加器**（fnId 分配 + 常量/站点/名字/目录/类型表/函数体）/ 单函数体（code 片段 + maxStack + flags） | — | §4.3.10、§8.4 |
| `DiagKind` | class（常量命名空间） | internal | 编译期错误分类常量（**词法族 + 解析/名字/校验族**，清单与策略见 §4.3.1/§4.3.9） | — | §8.4、§8.8、§9.16 |
| `SourceCompiler` | class | **protected** | 管线编排：compile(source) → 单元产物（或抛 SourceCompileException） | Lexer→Parser→…→Assembler | §8、§8.4 |
| `CompiledSourceUnit` | struct | **protected** | 源编译产物：`.fbc` 字节 + funcCount + entryFn + 单元指纹（源码指纹） | — | §8.4、§8.7 |

**可见性（本包落地）**：本包**没有任何 `public` 声明**——用户面 API 一律由根包再导出。规则按 §1.2 逐条落地：

- **`protected`（仅两个）**：`SourceCompiler` 与 `CompiledSourceUnit`——根包管线（`CompilePipeline.runSource`）调用前者、消费后者（§8.7 清单）；
- **`internal`（其余全部）**：词法 / 语法 / 名字解析 / 数据流 / 降低 / 发射 / 汇编 / 诊断常量，以及 `CompileSession`、`FuncBody`——它们只在本包（及子包）内使用，外部不需要、也不应看见（最小暴露）；
- **测试可及性**：包内单元测试放本包（或子包）的 `*_test.cj` 中——`internal` 对本包及子包可见；跨包测试（如 `src/test/diff` 差分层）只经 `protected`/`public` 面测试，不依赖本包内部声明。

### 4.3 各声明的公共成员

#### 4.3.1 `Lexer`（class）与 `Token`（struct）/ `TokenKind`（enum）

| 成员 | 归属 | 意义 | 调用关系 |
|---|---|---|---|
| `init(source: String, diagnostics: DiagnosticsSink)` | `Lexer` | 绑定源码与诊断；**构造时对整串做一次换行规范化** | `SourceCompiler` |
| `next(): Token` | `Lexer` | 取下一 token（EOF 终止） | `Parser` |
| `position(): Int64` / `line(): Int64` / `column(): Int64` | `Lexer` | 当前位置（诊断用；基于**规范化后**的源码） | `Parser`/错误构造 |
| `kind: TokenKind` / `text: String` / `pos: Int64` / `line: Int64` / `column: Int64` / `nlBefore: Bool` | `Token`（struct） | 词法单元（只读、按值传递；`text` = 归一化后的字面文本/原文拼写；`nlBefore` = **本 token 之前（跳过空白与注释时）跨过了换行**） | 全前端 |
| 构造器全表见下 | `TokenKind`（enum） | 无载荷枚举（拼写差异由 `Token.text` 承载）；解析器按 kind 穷尽 `match` | `Parser` |
| 词法职责（实现约束） | `Lexer` | ① 字符串保护（三形态全跨度）→ ② 注释剥离（`/* */` 嵌套配平）→ ③ 解析；**换行规范化**（`CRLF`/`CR` → `\n`，先于保护阶段对整串一次——多行/原始串常量字节与 `line`/`column` 计数跨平台一致）；**行首锚定标记**（多行串，§8.8；实现细节见 §4.4） | §8.5 冻结顺序、§8.8 |

**`TokenKind` 构造器全表（58 个）**：

| 类别 | 构造器 |
|---|---|
| 字面量（5） | `IntLit`、`DecLit`、`F64Lit`、`StrLit`（三形态归一）、`RegexLit` |
| 标识符/关键字（16） | `Ident`、`KwRecursive`、`KwLet`、`KwVar`、`KwIf`、`KwElse`、`KwWhile`、`KwFor`、`KwIn`、`KwWhere`、`KwBreak`、`KwContinue`、`KwReturn`、`KwTrue`、`KwFalse`、`KwNull` |
| 标点（12） | `LParen`(`(`)、`RParen`(`)`)、`LBrace`(`{`)、`RBrace`(`}`)、`LBracket`(`[`)、`RBracket`(`]`)、`Comma`(`,`)、`Colon`(`:`)、`Arrow`(`=>`)、`Dot`(`.`)、`Underscore`(`_`)、`Semi`(`;`) |
| 运算符（24） | `Plus`(`+`)、`Minus`(`-`)、`Star`(`*`)、`Slash`(`/`)、`Percent`(`%`)、`Assign`(`=`)、`EqEq`(`==`)、`NotEq`(`!=`)、`Lt`(`<`)、`Le`(`<=`)、`Gt`(`>`)、`Ge`(`>=`)、`AndAnd`(`&&`)、`OrOr`(`\|\|`)、`Bang`(`!`)、`Amp`(`&`)、`Pipe`(`\|`)、`Caret`(`^`)、`Shl`(`<<`)、`Shr`(`>>`)、`Tilde`(`~`)、`BangTilde`(`!~`)、`DotDot`(`..`)、`DotDotEq`(`..=`) |
| 终止（1） | `EOF` |

**归属与约定**：

- `Lexer` 的全部成员 = **构造 + `next` + `position`/`line`/`column`**（有状态扫描器 → class）；`Token` = **只读 struct**（**6 字段**：kind/text/pos/line/column/nlBefore，值语义）；`TokenKind` = **无载荷 enum**（做穷尽 `match`）。
- **无 `Char`/Rune**：M1 类型集（§11.7）不含 Char——`'…'` 是**单行字符串的第二种定界符**（异种引号 = 内容，§8.8/T42），不是独立 token 类别。
- **插值不引入独立 kind**：`StrLit.text` 保留 `${…}` 原文，切分与降低在前端糖阶段完成（S3.12）。
- **语句终结 = `;` 或换行**（两者等价、均可省略）：仓颉规则为「一条语句独占一行时可省略 `;`，一行存在多条语句必须用 `;` 分隔」（语言文档 `basic_programming_concepts/expression.md`）——因此**换行必须可判定**，否则 `a = 1` ⏎ `-2` 会被并成 `1 - 2`、`f` ⏎ `(1)` 会被并成调用、`x` ⏎ `[0]` 会被并成下标。
- **为什么不设 `NewLine` kind**：换行不是词法单元而是**语句终结信号**，且它替代不了解析器自身的「表达式是否已自然结束」判定——`1 +` ⏎ `2` 这类**跨行续写**必须忽略换行；多行/原始串内部的换行是**字面内容**，更不该产 token。故改为由 `Token.nlBefore` 承载（见下条）。
- **用 `nlBefore` 而不是比较 `line`**：`"""…"""` 这类**跨行 token** 结束之后同行紧跟 `-` 时，两个 token 的 `line` 不同却并无换行——只有词法阶段记录「本 token 之前是否跨过换行」才可靠（同法支撑 `>|` 的行首判定）。
- **`KwNull`（`null` 字面值）**：语法层可用（降低为 `PUSH_NULL`，0x15），但 **M1 没有任何合法落点**——句柄型局部恒非空（§3.1 空安全），`PUSH_NULL` 直存句柄型局部被 §7 校验 10 拒绝，值型槽/实参/返回值处则类型不符。保留该关键字的收益：① 报**准确诊断**（「保留关键字；M1 空安全下句柄型局部无空值」）而不是误报 `UndefinedIdentifier`；② 为未来语言级 null 语义预留——**M2/M3 都不需要它**：M3 的 JSON null 由 `JsonNull` **单例**（`fountain::f_data.json.JsonNull.instance`）承载，M2 宿主对象通道明确 **null 拒绝**（m2 §11）。
- **类型名不作独立 kind**：`Int64`/`String`/`List<Int64>` 等一律按 `Ident` 走，类型解析在解析期（与仓颉一致）。
- **词法错误策略：没有 error token，非法输入一律抛 `SourceCompileException`**——`TokenKind` 只描述**合法**词法单元，`Lexer.next()` 的契约是「返回已判定合法的 token 或 `EOF`」；遇到非法输入即抛（fail-fast、**不续跑、不做错误恢复/多错报告**），kind 取词法族：① `IllegalCharacter`（不属于任何合法词法单元的字符——`@`、插值外的 `$`、反引号等）；② `UnterminatedString`（单行串或 `${…}` 未闭合）；③ `BadEscape`（非法转义；多行串中单独 `\`）；④ `BadNumber`（数字字形畸形，如 `1.2.3`/`3e`——**超 Int64 域是合法输入**，落 Decimal）；⑤ `UnterminatedRegex`（正则段缺闭合 `/`）；⑥ 既定成员 `UnterminatedComment`/`MultilineHeadContent`/`UnterminatedMultilineString`/`UnterminatedRawString`（§8.8）。**为什么不做 error token**：本模块是单次编译（非 IDE/LSP），一个错误即终止——若返回 `Error` token，**每条语法规则**都得处理它（要么向上扩散、要么在 parser 里重做恢复），成本远大于收益；同时保持「编译期错误只有一个出口」：`DiagnosticsSink` 只收降级/告警，**不承担错误通道**。**边界**：正则的非法 pattern/flags 不算词法错误（前端仅切分，非法性在加载期 → `JitException(14)`）。

#### 4.3.2 `AstExpr`（enum） / `AstStmt`（enum） / `LambdaAst`（struct） / `ParamAst`（struct）

| 成员 | 意义 |
|---|---|
| `LambdaAst.params: Array<ParamAst>`（name + 类型注解 + 槽位 + `pos`）、`body: Array<AstStmt>`、`retExpr: ?AstExpr` | 源入口顶层 lambda（隐式返回 = 尾表达式） |
| `AstExpr.pos` / `AstStmt.pos` / `ParamAst.pos: SourcePos` | **行信息不丢**：节点位置取自**首 Token**（解析器填），驱动 `BytecodeBuilder.setSite`/`bail(code, pos)` 与编译期诊断（`SourceCompileException.line/column/lineText`） |
| 位置链（贯穿到运行期） | `Token.pos/line/column` → `Ast*.pos` → `setSite` 发射 `SET_SITE` → `SiteTable`（随 `.fbc` 与 JIT 产物走）→ 运行期报告按 `ctx.site` 反查行号 + `NameTable` 补变量名（§9.16、T50） |
| `ParamAst`（struct） | 形参：`name: String`、`typeAnn: TypeRef`、`slot: Int64`（参数槽序，`locals[slot]`）、`pos: SourcePos` |
| `TypeRef`（enum；M1 仅 `Builtin(UInt16)`——参数序 = code，即 `LocalType` 码 0–11） | 类型注解节点（`Decl.typeAnn` 与形参的载体）：M1 只解析内建类型名与容器名（`Int64` / `String` / `List<Int64>`…——**容器元素类型是前端的并行静态知识**，不进入本节点，§11.7）；M2 追加 `HostClosureT(Array<UInt16>, UInt16)`（= params, ret）与 `HostObjectT(String)`（= className）、M3 追加 `AnyT`（m2 §3、m3 §3/R3.1） |
| `AstExpr` 构造器（enum；**载荷递归合法**——语言文档 `enum.md` 明确 enum 支持递归定义；**参数只写类型、不带参数名**——仓颉语法如此） | `Lit(Token)` / `Var(String)` / `Binary(TokenKind, AstExpr, AstExpr)` / `Unary(TokenKind, AstExpr)` / `IfExpr(AstExpr, AstExpr, AstExpr)` / `Call(AstExpr, Array<AstExpr>)` / `Closure(LambdaAst)` / `IIFE(AstExpr, Array<AstExpr>)` / `Interp(Array<AstExpr>)` / `StrAdd(AstExpr, AstExpr)` / `RegexOp(TokenKind, AstExpr, AstExpr, ?AstExpr, ?Int64, ?Int64)` / `RangeLit(AstExpr, AstExpr, ?AstExpr, Bool)` / `ListLit(Array<AstExpr>, Bool)` / `MapLit(Array<(AstExpr, AstExpr)>, Bool)` / `TupleLit(Array<AstExpr>)` / `RecursiveValue` / `MemberName`（M2 糖预留——M1 解析器不生成该构造器） |
| `AstStmt` 构造器（enum；同上，参数只写类型） | `Decl(String, ?TypeRef, AstExpr)` / `Assign(AstExpr, AstExpr)` / `MultiAssign(Array<AstExpr>, Array<AstExpr>)` / `If(AstExpr, AstStmt, ?AstStmt)` / `While(AstExpr, AstStmt)` / `ForIn(Array<String>, AstExpr, ?AstExpr, AstStmt)`（绑定名 1 个；Map 双绑定 2 个） / `Return(?AstExpr)` / `ExprStmt(AstExpr)` / `Block(Array<AstStmt>)` |
| **参数序**（说明性，**不是语法**） | `Binary`=op,l,r；`Unary`=op,x；`IfExpr`=cond,thenE,elseE；`Call`=target,args；`Closure`=lambda；`IIFE`=closure,args；`Interp`=parts；`StrAdd`=l,r；`RegexOp`=kind,re,s,r,n,m；`RangeLit`=start,end,step,isClosed；`ListLit`=elems,isEmpty；`MapLit`=pairs,isEmpty；`TupleLit`=elems；`Decl`=name,typeAnn,init；`Assign`=lhs,rhs；`MultiAssign`=lhs,rhs；`If`=cond,thenS,elseS；`While`=cond,body；`ForIn`=binding,iterable,where,body；`Return`=value；`ExprStmt`=e；`Block`=stmts；`Lit`=tok；`Var`=name；`Builtin`=code |
| **形态与记法**（设计约定） | ① AST 是**纯数据**：`AstExpr`/`AstStmt` 用 **enum**（只带载荷构造器、做穷尽 `match`，可递归定义）、`LambdaAst`/`ParamAst` 用 **struct**（记录型骨架、值语义、无身份）；② **可选类型一律前缀 `?T`**（`?AstExpr`、`?Int64`、`?TypeRef`）——仓颉**没有** `T?` 后缀写法、也没有 `标识符?`（表示「可缺省」）的记法，原稿的 `step?`/`where?`/`e?`/`type?`/`r?`/`n?`/`m?`/`MemberName?` 属简写，已按合法写法改写；③ 数组一律写 `Array<T>`（原稿 `lhs[]` = `Array<AstExpr>`）；④ 构造器**参数按位置**书写（仓颉 enum 构造器**不支持参数名**）——参数含义见上「参数序」行；`pos` 见上表。 |

#### 4.3.3 `NameResolver`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(snapshot: PredefinedSnapshot)` | 持注册表快照（快照语义 §8.4） | `SourceCompiler` |
| `func resolve(name: String, pos: Token): ResolvedCall` | 顺序：`recursive` → 注册表（user helper）→ 未命中 `SourceCompileException(UnregisteredFunction)`；非调用未定义标识符 → `UndefinedIdentifier` | `Lowerer` |
| `ResolvedCall`（**enum**） | 两个构造器：**`Recursive`**（无载荷——命中 `recursive` 关键字，自递归）与 **`UserHelper(UInt16)`**（参数序 = slot：注册表 user helper 的槽号） | `Lowerer` 按构造器**穷尽分派**：`Recursive` → 顶层 `CALL_FUNC <自身>` / 闭包层 `LOADL 0` + `CALL_CLOSURE`（§8.0、§8.5）；`UserHelper(slot)` → `CALL_HELPER`（hid = slot + 0x0100） |

#### 4.3.4 `DefiniteAssignment`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func analyze(lambda: LambdaAst, types: LocalTypes): Bool` | 数据流不动点：非参数局部在所有可达路径先写后读；循环出口不视为已赋值；`PUSH_NULL` 不得直存句柄型槽 | `SourceCompiler`（违规 → 编译错误）；T13 |

#### 4.3.5 `Lowerer`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(sess: CompileSession, resolver: NameResolver, consts: ConstRegistry, names: NameTable)` | 绑定会话与共享表 | `SourceCompiler` |
| `func lowerTop(lambda: LambdaAst): Array<FuncEntry + body>` | 顶层 + 每个嵌套闭包 + 按需适配器各一个 FuncEntry | `Assembler` |
| 规范降低职责（实现约束，逐条对应规格） | `if` 双用法/多分支汇合（值用法类型逐位一致、语句用法 `POP`）；`while` + `LOOP_BACK`；`for-in`（Range/List/Map 惰性单遍 + `MAP_ITER_BEGIN/STEP`、String 码点序、`where`）；`break/continue`；多重赋值（隐藏局部 + 先读后写）；插值与 String 混合加法（`TO_STR`+`STR_CAT`）；`%` 仅 (Int64,Int64)（`IMOD`）；n 位置窄化；String 重复/日期差；正则操作符（helper 直呼 H58/H59/H72）；闭包（`closure_new`/`CALL_CLOSURE`/`LOAD_CAP`/`locals[0]` 帧约定）；`recursive`（顶层 `CALL_FUNC` 自身 / 闭包层 `LOADL 0`+`CALL_CLOSURE` / 值化适配器 / **尾位置帧复用回边**）；空容器构造（`MAKE_LIST/MAKE_MAP`）；`PUSH_KH` + 常量注册 | §5、§8.0、§8.5–8.6、§11.9、§3.3 |

#### 4.3.6 `BytecodeBuilder`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(fnId: UInt32, localTypes: LocalTypes, consts: ConstRegistry, sites: SiteTable, names: NameTable)` | 单函数构建上下文 | `Lowerer` |
| `func emit(op: UInt8)` / `emitU8/emitU16/emitI32/emitI64/emitRel(op, label)` | 发射指令与操作数（LE） | 降低 |
| `func newLabel(): Int64` / `place(label: Int64)` / `fixupRel(label)` | 标签与相对偏移回填 | 降低 |
| `func setSite(pos: SourcePos)` | 记 `SET_SITE` 位置（仅在可能失败指令前发射） | 降低 |
| `func callHelper(hid: UInt16, argc: UInt8)` / `callHelperNoCheck(…)` / `callHelperVoid(…)` | helper 调用发射（自动尾随 `CHECK_ERR`，`_NC` 除外） | I3 |
| `func callFunc(fid: UInt16, argc: UInt8)` / `callClosure(argc: UInt8)` / `ret()` / `retVoid()` / `bail(code: Int64, pos: SourcePos)` | 调用/返回/失败块 | §5、§7 |
| `func finish(): FuncBody` | 产出函数体（code 段片段 + maxStack + flags 推断） | `Assembler` |

#### 4.3.7 `Assembler`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(dir: FuncDir, consts: ConstRegistry, sites: SiteTable, names: NameTable)` | 汇总上下文 | `SourceCompiler` |
| `func assemble(bodies: Array<FuncBody>): Array<UInt8>` | 拼接 code 段（目录 + 各函数体）、定长偏移、产出 `.fbc`（FbcWriter） | `SourceCompiler` → 根包管线 |
| 校验职责（§7 校验 1–11，逐条） | ① 每条 `CALL_HELPER` 后有可达 CHECK_ERR（除 `_NC`）；② 0xA9–AA 与 0xC0–FF 发射即 `ERR_NOT_IMPL`；③ 每个 sink 前 rsp 回帧基线（栈平衡）；④ `PUSH_KH` idx < 常量表长度且已 freeze；⑤ `LOADL/STOREL i < nLocals`；⑥ 有 `LOOP_BACK` 的函数不得跨回边优化掉错误检查；⑦ `CALL_FUNC fid` 在目录内且 argc == nargs（`closure_new` fnId 同规则）；⑧ M2 专属指令（CALL_HOST/HW_OPEN/HW_CLOSE）M1 一律 `ERR_NOT_IMPL`；⑨ 每函数带类型表（长度= nLocals、值合法；前端保证槽类型一致）；⑩ 明确赋值与空安全（数据流）；⑪ 变更型函数的 deopt 源禁令（H43–H48/user helper/CALL_CLOSURE → 禁 `DEC_TO_I64 mode=1` 与 `TO_I64` deopt 模式） | 违规 → `SourceCompileException`（kind=NotImpl 等） |

#### 4.3.8 `SourceCompiler`（class，protected）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(opts: CompileOptions, registry: PredefinedSnapshot, diagnostics: DiagnosticsSink)` | 依赖注入（配置 + 注册表快照 + 诊断） | 根包 `Compiler.compile(source)` |
| `func compile(source: String): CompiledSourceUnit` | 全管线：lex → parse → resolve → DA → lower → assemble →（FbcWriter 字节） | 根包管线第 1 步 |
| 内部状态（设计） | 只需构造注入的三项；**每次 `compile` 自建 `CompileSession`**（词法/语法/降低的中间态都在会话里）——实例本身无跨调用可变状态 | 并发去重由根包 `CompileCache` 承担（§8.1、§12.6） |

**归属**：`SourceCompiler` 的成员就是**一个构造 + 一个方法**（状态仅注入三项）；下面 §4.3.9 的 `CompiledSourceUnit`（它返回的**产物类型**）与 `DiagKind`（包内**常量命名空间**）**不是**它的成员。

#### 4.3.9 `CompiledSourceUnit`（struct，protected） / `DiagKind`（class，常量命名空间，internal）

| 成员 | 归属 | 意义 | 调用关系 |
|---|---|---|---|
| 字段：`raw: Array<UInt8>`（`.fbc` 字节）/ `funcCount: UInt32` / `entryFn: UInt32` / `fingerprint: UInt64`（源码指纹） | `CompiledSourceUnit`（只读 struct） | 源编译产物（值语义、不可变） | 根包：`FbcReader.load(raw)` 加载校验 + 缓存键（§8.1） |
| `DiagKind` 常量清单 | `DiagKind`（`static const` 家族） | **词法族**（fail-fast，见 §4.3.1）：`IllegalCharacter / UnterminatedString / BadEscape / BadNumber / UnterminatedRegex / UnterminatedComment / MultilineHeadContent / UnterminatedMultilineString / UnterminatedRawString`；**解析 / 名字 / 校验族**：`UnregisteredFunction / UndefinedIdentifier / BadParameterList / MissingArrow / DuplicateRegistration / NotImpl`；M2/M3 增量追加（如 m3 的 JSON 段错误） | 测试断言（T42/T50）；**词法族逐 kind 一条用例** |

#### 4.3.10 `CompileSession`（class，internal） / `FuncBody`（struct，internal）

`CompileSession` = **一次 `compile` 的单元级累加器**（由 `SourceCompiler.compile` 自建、随调用销毁——因此实例天然无跨调用共享，并发去重交给根包 `CompileCache`，§8.1/§12.6）：

| 成员 | 归属 | 意义 | 消费方 |
|---|---|---|---|
| `func newFnId(): UInt32` / `entryFn: UInt32` | `CompileSession` | fnId 分配器：顶层 lambda = `entryFn`，其后是每个嵌套闭包，按需再给 `recursive` 值化适配器（§8.0 单元形态） | `Lowerer` |
| `consts: ConstRegistry` | 同上 | 常量注册（拼装期）→ 汇编期 `freeze` | `Lowerer` 写、`Assembler` 冻结 |
| `sites: SiteTable` | 同上 | 站点表（code 偏移 → 源位置） | 前端写；随产物走 |
| `names: NameTable` | 同上 | 名字表（稀疏，仅源码级命名槽） | 前端写；随产物走 |
| `dir: FuncDir` | 同上 | 函数目录（`FuncEntry` 逐个加入） | `Assembler` 校验 |
| `types: ArrayList<LocalTypes>`（按 fnId 序） | 同上 | 每函数的局部类型表 | `Assembler` → 产物 |
| `bodies: ArrayList<FuncBody>` | 同上 | 待汇编函数体（`BytecodeBuilder.finish()` 逐个产出） | `Assembler.assemble(bodies)` |
| `source: String`（**规范化后**）/ `fingerprint: UInt64` | 同上 | 源码与源码指纹（产物字段、缓存键） | `CompiledSourceUnit`、根包 `CompileCache` |
| `opts: CompileOptions` / `diagnostics: DiagnosticsSink` / `registry: PredefinedSnapshot` | 同上 | 由 `SourceCompiler` 注入转交（`NameResolver` 从 `registry` 取快照） | 各阶段 |
| `code: Array<UInt8>` / `maxStack: Int64` / `flags: UInt16` | `FuncBody` | 单函数的 code 段片段 + 栈上界 + flags（§7 校验 3/9；`flags.bit0` → `FuncEntry.flags` 依据） | `Assembler` |

**归属**：`CompileSession` 是**可变累加器**（class：多阶段共享同一实例、边跑边填）；`FuncBody` 是**只读结果**（struct：`finish()` 产出、`Assembler` 消费；按 fnId 序入列，目录与 code 偏移据此定位）。`types` / `bodies` 与 `dir` 的项数必须一致（汇编期校验的隐含前提）。M2/M3 增量（类注册表快照、Any 相关表）在 `CompileSession` 上追加即可。

### 4.4 多行串「行首锚定标记」`>|`（规格 §8.8 扩展；特性与实现细节）

**定位**：`>|` 是**本规格对多行字符串的扩展**（仓颉没有，§8.8）。它只解决一件事——多行串在**源码缩进**与**内容缩进**冲突时（典型：串里写 JSON / 嵌套结构），可以让源码缩进照写，由标记显式给出**内容**缩进；被吞掉的只是标记前的那段缩进。**注意**：它不是整段去缩进（dedent）机制——只有**含有效标记的行**被截取，其余行一律原样保留；把 `>|` 逐行写在开头时效果上等价于逐行去缩进，但机制本身只做逐行截取。

**特性（与规格逐条对齐）**：

| 面 | 规则 |
|---|---|
| 适用范围 | **仅多行形态**（`'''` / `"""`）；单行串与原始串（`#`×n）**不适用**——原始串里 `>|` 就是两个普通字符 |
| 有效标记 | 行内**首个非空白位置**的 `>|`（其前只可有缩进空白） |
| 进入判定 | 串体内**任一行**存在有效标记 → 整个串进入**锚定模式**；否则普通模式（**非空白符之后的 `>|` 不触发**） |
| 标记行处理 | 标记**连同其前缩进被消耗**（不进入内容）；`>|` **之后**的全部字符 = 该行内容（其中再出现的 `>|` 一律是字面文本） |
| 非标记行处理 | **整行原样保留**（不截取、不归一）——空白行、含内容的行、含非首位 `>|` 的行都一样 |
| 非标记情形 | `>>|`、`a>|b`、`|>|` ⇒ 其中的 `>|` 全是**字面内容**（整行保留） |
| 单独标记行 | 只有 `>|`（可含前导空白）的行 → 该行内容 = **空串** |
| 首现语义 | `>|>|abc` → 内容 `>|abc`；`>|    >|` → 内容 `    >|`（**只消耗首个**非空白位置的那一个标记） |
| 行连接 | 各行内容以 `\n` 连接（换行规范化之后） |

**处理顺序（实现契约，§8.8 冻结）**：

```
构造 Lexer：整串换行规范化（CRLF / CR → \n，对整串一次）
→ ① 字符串保护（取三形态完整跨度，含多行串的跨行）
→ ② 定界扫描取出「原始串体」（未转义、未插值切分）
→ ③ 锚定判定与逐行截取          ← 本特性的唯一落点
→ ④ 转义解码（\n / \t / \uXXXX…；多行串内单独 \ → 编译错误）
→ ⑤ 插值切分（若含 ${…}）——前端糖阶段（S3.12）
```

**四条不可换序的理由**：① 锚定必须在**转义之前**——否则 `\n` 等先变成真实字符，逐行切分将失去"行"的概念；② 锚定必须在**插值之前**——被消耗的标记与前导缩进**不得参与插值**（`>|${x}` 的 `${x}` 正常插值，`>|` 不进文本）；③ 换行规范化必须在**构造时整串一次**（§8.5 冻结顺序）——否则 CRLF 平台下行边界不一致、常量字节跨平台漂移；④ **词法保护与 `>|` 无关**——它只出现在串体内部，绝不会被当作注释/配对符号（§8.5 保护清单里的 `>|` 意思是"穿过保护阶段不变形"）。

**实现细节（design 级）**：

| # | 要点 |
|---|---|
| 1 | **逐行无状态等价（可省「模式」变量）**：规范用"整串进入锚定模式"表述，但两模式下**非标记行的处理完全相同**（都整行保留），标记行处理只取决于本行 ⇒ 实现可**逐行独立判定**：对每行做"跳前导空白后是否以 `>|` 开头"的前缀测试——命中则丢弃「前导空白 + `>|`」，未命中则整行保留。**无需先扫全文决定模式**。（等价性以 T42 黄金值对拍为准。） |
| 2 | **纯编译期、零运行期**：不产生任何 opcode / helper / 错误码 / LocalType，`.fbc` 格式**零变更**——产物只是 `kind 3`（String）常量的**字节不同**；⇒ **三引擎结构性无关**（I7 不受影响），差分口径只落在"常量字节逐字节与黄金值一致"。 |
| 3 | **不做成一般化 token 规则**：`>`、`|` 在 M1 里是既有运算符（`Gt` / `Pipe`）——`>|` 的特殊语义**只在多行串体内**成立；串外/注释内按各自规则处理（`a >| b` = `Gt` + `Pipe`，与语法层无关）。 |
| 4 | **诊断列号**：锚定**消耗**前缀（前导缩进 + 2 字符）⇒ 行内容与源码列号**不再线性对应**。M1 的诊断粒度 = 「字面量 token 的 `pos/line/column` + 出错 kind」（§4.3.1 词法错误策略：单错即止），故取最小口径：**指向字面量 token 起点**；如后续需要精确到锚定行内，再补 per-line 源码列起点表（当前不做）。 |
| 5 | **与 `nlBefore` 无耦合**：多行串内部换行是**内容**、不产 token（§4.3.1）；锚定只改变"内容里有哪些换行"，不改变 token 边界。 |
| 6 | **失败面为零**：标记写错位置（非首位 / 单行串 / 原始串）**都不是错误**，只是"没触发 / 成了字面文本"；本特性**没有专属编译错误**（既有 `MultilineHeadContent` / `UnterminatedMultilineString` / `UnterminatedRawString` 与之无关）。 |

**实现落点（包 / 声明 / 工作项）**：

| 面 | 内容 |
|---|---|
| 包 | `fountain::f_jit.compiler`（`Lexer` 的多行串扫描分支） |
| 形态 | 纯函数式后处理：`dedentAnchored(body: String): String`（输入 = 原始串体（已规范化），输出 = 锚定后串体）；**无状态、可单测**（黄金值表驱动） |
| 工作项 | `plan-m1` **S3.4**（锚定：进入判定 / 单独标记 / 非标记情形 / 处理顺序）+ **S3.5**（注释与词法保护：串跨度内 `>|` 不参与） |
| 验收 | **T42 锚定组**（进入判定、有效标记识别、非标记情形、整行保留、标记不进产物、标记行与保留行混排、截取后正常转义与插值）+ **逐字节黄金值**；跨平台一致（换行规范化） |

**关联**：M3 的 JSON 段词法保护（**反引号形态**，唯一）沿用同一保护口径（m3 §11、`plan-m3` R3.6）。

**易错点（实现期自检）**：

| 陷阱 | 正确 |
|---|---|
| 先转义 / 插值再锚定 | ✗ 顺序：锚定 → 转义 → 插值（§8.8 冻结） |
| 非标记行被截取 / 归一 | ✗ **整行原样保留**（含空白行） |
| 消耗标记之后的 `>|` | ✗ 只消耗**首个非空白位置**的那一个（首现语义） |
| 单行串 / 原始串也处理 | ✗ 不适用（原始串里是普通文本） |
| 必须先扫全文判「模式」 | △ 可实现为逐行无状态（等价；以 T42 对拍） |
| 需要运行期 / 三引擎支持 | ✗ 纯编译期；`.fbc` 零变更 |
| 找专属错误码 | ✗ 无——不触发即成字面文本 |

---

## §5 包 `fountain::f_jit.runtime`

### 5.1 包意义

执行期全部设施：**ctx（64 B 非托管）**、**句柄表 + 窗口 + 逃逸区**、**调用级迭代器表**、**helper 实现集（H01–H72，@C 薄入口）**、**诊断转储与报告组装**、**解释器（语义基准）**。桥与机器码都只经本包暴露的机制接触运行时状态。

### 5.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `JitContext` | class（**protected**） | ctx 非托管承载 + 字段访问器（偏移固定）；仅桥/测试可见（D2 结案） | — | §1、§4 |
| `CtxFlags` | class（常量） | ctx.flags 位定义（strictFp/trace/hasLoop…） | — | §1 |
| `HandleTable` | class | 句柄表：pin/get/release + 窗口/逃逸/世代 + 全局上限 | LocalType/TypeToken | §8.1、§9.6 |
| `EscapeArea` | class（内部） | 逃逸槽登记（per-call 逃逸区/宿主持有） | HandleTable | §8.1 规则 6 |
| `IterTable` | class | 调用级 Map 迭代器表（游标 gen\|idx；工厂四件套；close 幂等；调用结束与 DEOPT 清空） | — | §11.9 v0.18.35 |
| `HelperId` | class（常量） | 固定 helper hid 1–62、69–72 与名字 | — | §6、§8.4 |
| `Helper` 系列（H01–H72） | 顶层 @C func ×N | 固定 helper 实现（模板见 §3.3.1） | 各表/ctx | §6 |
| `ctxWriteCode` | 顶层 func | helper 写错误槽（多层嵌套写码规则） | JitContext | §9.5 |
| `DbgDump` | class | 单次转储 + 报告组装（§9.16 模板，三引擎逐位一致） | JitContext、SiteTable、NameTable、LocalTypes | §9.16 |
| `Interp` | class | 解释器：逐指令语义（I7 基准） | Opcode 表、各表、Helper 集 | §0、§5、§11.9 |
| `InterpFrame` | class（内部） | 解释器帧（locals/操作数栈） | — | §3.1 |
| `RuntimeError` | interface（内部） | 解释器内部错误收敛（写槽 + bail 语义） | — | §0 |

### 5.3 各声明的公共成员

#### 5.3.1 `JitContext`（class，非托管承载；**protected**）

**可见性（D2 结案，2026-10-11）**：**`protected`**（模块级）——① ctx 布局是**机器码 ABI 契约**（§1/§4）：公开即成半公开 API，用户写坏 `errCode`/`hwTop` 会破坏不变量（桥按 `errCode` 判失败、按 `hwTop` 记账）；② 用户面**无消费路径**：预定义函数 `impl` 收到的是**已解包的仓颉值**，helper 只见裸 `CPointer<Unit>`；③ `cp()` 只经 artifact ABI 交给 backend；④ 与 `Engine`/`JitValue` 先例一致；⑤ **不随 §7.6 再导出**。注意：`HandleTable` 是用户面（宿主需 pin/release 逃逸句柄）——用户能管句柄 ≠ 能碰 ctx。

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func create(hwBase: Int64, hwCap: Int64, fnId: Int64, dbgBase: Int64): JitContext` | 分配 64 B 非托管内存（`LibC.malloc<Int64>(count: 8)`；实现选型与理由见下注）并初始化 | 桥三态收尾第 1 步 |
| `static func free(ctx: JitContext): Unit` | 配对释放（`LibC.free<Int64>`；finally 义务，T27） | 桥 finally |
| `var errCode: Int64`（off 0）/`site`（8）/`hwBase`（16）/`hwCap`（24）/`hwTop`（32）/`fnId`（40）/`flags`（48）/`dbgBase`（56） | 规范偏移访问器（机器码按同一偏移直接读写） | 全运行时 |
| `func resetForCall()` / `func hwTop()` / `func dbgDumpOnce(fnId, locals)` | 复位 / 记账 / 单次转储触发 | 桥、BAIL 块降级实现 |
| `func cp(): CPointer<Int64>` | 传给机器码的裸指针（rdi / x0） | 桥入口 |

**实现选型与理由（ctx 与转储缓冲是全过程仅有的两块 GC 管辖外内存）**：

- **用 `std.core.LibC.malloc<T>` / `LibC.free<T>`**（`public static func malloc<T>(count!: Int64 = 1): CPointer<T> where T <: CType`，std.core 隐式可用）：ctx = `LibC.malloc<Int64>(count: 8)`（8 × 8 B = 64 B，与 `cp(): CPointer<Int64>` 同型；等价写法 `LibC.malloc<UInt8>(count: 64)`）；转储缓冲 = `LibC.malloc<Int64>(count: 2 + maxNLocals)`。**免自声明 `foreign func malloc/free`**；malloc 返回块满足 ≥ 16 B 对齐（满足 §1 对 ctx 的对齐要求）。
- **不采用 `acquireArrayRawData` / `releaseArrayRawData` 钉住 `Array<UInt8>`**：std.core 文档明确「指针的获取和释放之间**仅可包含简单的 foreign C 函数调用等逻辑，不构造例如 `CString` 等的仓颉对象**，否则可能造成不可预期现象」——ctx/转储缓冲的生命周期跨**整个调用事务**，其间全部 helper 都是普通仓颉实现、必然构造对象并触发 GC，直接违反该窗口约束。仓库内 `acquireArrayRawData` 的既有用法也都是「短窗口 + 立即释放」（如 `f_io` 的 `BytePointerStream.access` 用 try/finally 包住一次指针操作），与本场景不匹配。
- **释放点不变**：仍在桥的 `finally`（`call<T>` 第 6 步；与 B pin / C 窗口 / D 逃逸槽同一次收尾），正常/错误码/DEOPT/-2/Marshal 失败全路径必须配对（T27 的 malloc/free 计数断言）。**释放机制裁定（2026-10-11）：一律用 `finally`，不使用 `std.core.CPointerResource`（`try (r = …)`）**——① 释放常与**同一次收尾里的其他动作**绑定（重置窗口 `hwTop=hwBase`、清 `DbgDump` 缓冲、迭代器表 `clearAll`），顺序写在 `finally` 里最直接，资源块只能表达"释放"这一件事；② 全链路只保留**一种**收尾机制（规格 §8.1 已把 call 清理冻结为 `try/finally` 化），避免两套等价语义并存；③ 少一层 `Resource` 接口/泛型包装及其**隐式**释放时机的认知负担——释放点必须能与 pin/窗口/逃逸槽收尾排在同一条**显式**时间线上。
- **失败面**：入参为负 → `IllegalArgumentException`（本设计为编译期常量，不会触发）；其余以 std 文档为准（实施时补一条诊断测试）。

#### 5.3.2 `HandleTable`（class，用户可见）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func pin<T>(obj: T): Int64` | 路径 B：对象 → ID（同表同对象复用同 ID；tag 按类型 token 写）；失败：无 token 类型 → 19（M2 起宿主类例外）、null → 19/6 | `CallMarshal`、M2 helper |
| `static func get<T>(id: Int64): ?T` | 路径 D 读回（宿主侧，Option；typeid 不符 → None） | `retUnboxer`、M2 M3 |
| `static func release(id: Int64): Unit` | 逃逸句柄显式释放（invoke 路径） | 宿主/桥 |
| `static var initialCapacity: Int64 = 128` | 窗口初始容量（调用前可调；有分配单元写 ctx.hwCap） | 桥 `create` |
| `static var capacityLimit: Int64 = 1048576` | 全局槽上限（触顶 → 16；运行中调大即时生效、调小不追溯） | 全路径 |
| （内部/protected）`fetch<T>(id): T` | helper 边界取对象（null → 6、类型不符 → 8） | 全部 helper |
| （内部/protected）`append(obj, tok): Int64` | 路径 C：窗口登记（`hwTop`++；`hwTop == hwCap` → 倍增扩容，以 capacityLimit 封顶） | 分配型 helper |
| （内部/protected）`escape(id): Unit` / `resetWindow(hwBase): Unit` / `promote(id)` | 路径 D 迁出窗口 / 调用结束重置 / 提升组（M2） | 桥、M2 |
| （内部/protected）`genOf(id)/idxOf(id)/tagOf(id)` | 槽位三元组解析（防御校验共用） | helper 防御、M2 失效门禁 |

#### 5.3.3 `IterTable`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func open(h: Int64, elementKind: UInt8): Int64` | 建立迭代器（游标 = `(gen<<32)\|idx`），返回游标 | H49 `map_iter_begin` |
| `static func next(cur: Int64): Bool` | 推进（0/1 为终止唯一判定来源） | H62 mode=0 |
| `static func key(cur: Int64): Int64` / `value(cur: Int64): Int64` | 已推进后取键/值（相位校验：未推进取件 → 99） | H62 mode=1/2 |
| `static func close(cur: Int64): Unit` | 关闭（幂等；出口发射） | H62 mode=3 |
| `static func clearAll(): Unit` | 调用结束与 DEOPT 交接两点清空 | 桥 finally / DEOPT |

#### 5.3.4 `HelperId`（常量命名空间类）与 helper 函数集

| 成员 | 意义 |
|---|---|
| `static const H_LEN=1 … H_MAP_ITER_STEP=62`（H01–H62 对应 1–62） | 固定 helper 编号（63–68 保留给 M2/M3） |
| `static const H_STR_TO_REGEX=69 / H_LIST_NEW=70 / H_MAP_NEW=71 / H_REGEX_REPLACE_RANGE=72` | v0.17/v0.18 增量 |
| `static func name(hid: UInt16): String` | 诊断 |

顶层 helper 函数（`@C` 薄入口，签名一律 `func hXxx(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`，实现体为普通 Cangjie + try/catch 转码）——按 §6 表分族列出：

| 族 | hid | 关键成员（函数） | 语义要点 |
|---|---|---|---|
| 容器/字符串读 | H01–H08, H49/H62 对偶 | `hl_len/hl_get/hm_len/hm_get/hm_get_or/hm_has/hs_len/hs_at` | 不登记槽；fetch 失败 6/8；越界 4、缺键 5 |
| 比较/判定 | H09–H20 | `hs_cmp/hd_cmp/hd_is_int/hdur_cmp/hdur_ticks/ht_cmp/ht_field/h_ref_eq/h_is_type/h_tag_of/h_guard/h_nonnull` | `h_ref_eq` 恒不失败；`h_guard` null→6、类型→8 |
| 错误/控制 | H21–H23 | `err_raise/interrupt_poll/hw_check` | -2 仅安全点；16 由 hw_check |
| Decimal | H24–H31 | `dec_add/dec_sub/dec_mul/dec_div/dec_from_i64/dec_from_f64/dec_to_i64/dec_to_f64` | std Decimal IEEE-754-2019 decimal128 默认上下文；÷0 → 10；越界 9 |
| 字符串/文本化 | H32/H33/H50/H51/H60 | `str_cat/to_str/str_sub/str_replace/str_repeat` | TO_STR 逐字节格式冻结（§11.9）；码点索引 |
| 时间 | H34–H40/H61 | `dt_add/dt_sub/dur_add/dur_sub/dur_mul/dur_div/dur_neg/dt_diff` | 值恒 UTC；本地时区仅在 TO_STR |
| 区间 | H41/H42 | `range_new/range_contains` | step=0 → 14；空区间合法 |
| 容器变更 | H43–H48 | `list_add/map_put/list_insert/list_set/list_remove/map_remove` | 唯一容器副作用；常量禁写 20；fetch 6/8 |
| 正则/构造 | H52/H53/H58/H59/H69/H72 | `regex_is_match/regex_find/regex_replace_all/regex_replace_nth/str_to_regex/regex_replace_range` | 空 pattern 加载期/构造期拒绝 |
| 分配型 | H24–H29/H32–H41/H50/H51/H53/H54/H58–H61/H69/H70/H71/H72 | 每组恰好登记 1 槽 | 窗口满 → 扩容；全局触顶 → 16 |
| 闭包 | H54–H57 | `closure_new/closure_fnid/closure_cap/fn_table` | 闭包对象 `{fnId, captured}`；fn_table 返回机器入口表基址 |
| Map 迭代 | H49/H62 | `map_iter_begin/map_iter_step` | 不登记槽；迭代中修改同一 map → 23 |

实现约束：全部 helper 内部把所有异常转成错误码（I4）；多层嵌套写码时内层已写则外层只在新异常时覆盖，末尾 catch-all 兜 99（§9.5）。

#### 5.3.5 `DbgDump`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func writeOnce(ctx: JitContext, fnId: Int64, nLocals: Int64, locals: CPointer<Int64>): Unit` | fail-fast 收敛点单次转储（首格哨兵；最深失败帧获胜；DEOPT 不转储；`dbgBase=0` 跳过） | `BAIL`/`CHECK_ERR` 降级块（backend 生成） |
| `static func report(code: Int64, site: Int64, fnId: Int64, dir: FuncDir, types: LocalTypes, siteTable: SiteTable, nameTable: NameTable, dump: CPointer<Int64>): String` | 组装报告：源码行 + 变量清单（名/类型/值：值型按 §11.9 文本化、句柄型 `<类型名>#idx`、无名槽省略名字） | 桥抛出前 |
| `static func allocateDump(maxNLocals: Int64): CPointer<Int64>` / `freeDump(p)` | `(2+maxNLocals)×8` 非托管缓冲（首格清零）；分配/释放同 §5.3.1 选型（`LibC.malloc<Int64>` / `LibC.free<Int64>`） | 桥三态收尾第 1 步 / finally |

#### 5.3.6 `Interp`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(unit: LoadedUnit, helpers: …)` | 绑定加载产物 | 根包 `JitFunction` 解释器形态 |
| `func run(fnId: UInt32, ctx: JitContext): Unit` | 语义基准：逐指令执行（含 §5 全部语义、§11.9 迭代/替换/格式、`LOOP_BACK` 安全点 `H22`、fail-fast 写槽退出）；抛出的是宿主侧异常（InterruptedException 等） | 桥三态收尾第 3 步 DEOPT 分支 / `JitMode.Off` 直接路径 |
| `func frameInfo(fnId: UInt32): (nLocals, maxStack)` | 帧尺寸（由 §3.1 公式） | 帧分配 |
| 实现约束 | 与 JIT 后端结果/errCode/site/报告文本逐位一致（I7）；常量/目录/类型表只读；不引入跨调用可见可变态 | T2/T6/T50 |

---

## §6 包 `fountain::f_jit.backend`

### 6.1 包意义

把字节码**降低**为机器码：两套后端（B1 x86_64 / B2 AArch64）、代码内存（W^X）、函数入口表、常量句柄镜像、两遍布局（跳转范围）、NaN 规范化尾、失败收敛块、IBT/BTI。**只加速、不改语义**（I7）。

### 6.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `Backend` | interface | 后端契约（编译入口 + ABI 摘要） | LoadedUnit、CodeBuffer | §12.2 |
| `BackendX86_64` | class <: Backend | B1 实现（SysV） | — | §12.2–12.4 |
| `BackendAArch64` | class <: Backend | B2 实现（AAPCS64） | — | §12.2–12.4 |
| `CodeBuffer` | class | 代码内存（mmap RW→mprotect RX、I-cache 清理、munmap） | — | §12.5 |
| `FnTable` | class | 函数入口表（非 GC 内存，桥填充） | — | §12.4 模板 B |
| `ConstMirror` | class | 常量句柄镜像（连续 8 B 数组，基址烘焙进机器码） | — | §12.4 |
| `JitCompiler` | class | 单元编译编排（两遍布局、检查块、重定位、产物装配） | Backend*、CodeBuffer、FnTable、ConstMirror | §12.3–12.5 |
| `JitArtifacts` | class | JIT 产物（code/fnTable/mirror/入口 thunk） | — | §12.3 |
| `BackendSelector` | class | 引擎选择（Off/Auto/Force × OS × Arch） | Engine | §12.1 |

### 6.3 各声明的公共成员

#### 6.3.1 `Backend`（interface）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func compile(unit: LoadedUnit, sink: CodeBuffer, labels: …): Unit` | 降低整单元（函数目录级）到代码缓冲 | `JitCompiler` |
| `func entryThunkBase(): Int64` / `func entryThunkFor(fnId: UInt32): Int64` | 桥用 5 行 thunk（第 1 参数位置差异：rdi/x0） | 桥、FnTable |
| `func abiSummary(): String` | 诊断/测试（CTX/FP/SP/RETV/TMP 映射） | diagnostics |
| `prop name: String` | "x86_64" / "aarch64" | 缓存键 |

#### 6.3.2 `CodeBuffer`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func alloc(size: Int64): ?CodeBuffer` | `mmap(PROT_READ\|PROT_WRITE)`；失败 → None（桥降级解释器，不报错） | `JitCompiler` |
| `func write(bytes: Array<UInt8>, off: Int64)` / `func patch(pos: Int64, bytes: Array<UInt8>)` | 写入/重定位补丁（布局期） | 后端 |
| `func seal(): Bool` | `mprotect(PROT_READ\|PROT_EXEC)`（W^X）+ I-cache 清理（aarch64 必需；x86 同接口） | `JitCompiler` |
| `func flushICache()` / `func free()` | 缓存一致性 / `munmap`（T27/T4） | 卸载 |
| `prop base: Int64` / `prop size: Int64` | 基址/长度 | 镜像烘焙、thunk |

#### 6.3.3 `JitCompiler`（class） / `JitArtifacts`（class） / `FnTable`（class） / `ConstMirror`（class）

**`JitCompiler`**（单元编译编排器）：

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(backend: Backend, diagnostics: DiagnosticsSink)` | 绑定后端（双后端由 `BackendSelector` 选定，§6.3.4）与诊断 | 桥管线第 3 步 |
| `func compileUnit(unit: LoadedUnit, handleIds: Array<Int64>): ?JitArtifacts` | 编排：常量镜像 → 两遍布局（aarch64 条件分支 ±1 MB 需跳板） → 降低全函数 → `seal`；失败 → None（**降级解释器，不报错**） | 桥管线第 3 步 |

**`JitArtifacts`**（JIT 产物束；仅 JIT 路径存在——解释器路径不构造本对象）：

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `code: CodeBuffer` / `fnTable: FnTable` / `mirror: ConstMirror` | 三件资产：机器码 / 函数入口表 / 常量句柄镜像 | 桥、卸载 |
| `func rawEntry(fnId: UInt32): Int64` | 执行入口地址（桥按 `rdi/x0 = ctx` 调用；入口 thunk 出自 `Backend.entryThunkFor`） | 三态收尾第 2 步 |
| `func free()` | **资产释放**（§8.7 收尾顺序的**最末一步**；幂等） | 卸载（§8.7） |

**`FnTable`**（函数入口表：**非 GC 内存**，桥填充；`CALL_FUNC`/`CALL_CLOSURE` 的间接调用目标）：

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `alloc(n)` / `set(fid, entry)` / `entry(fid): Int64` / `free()` | 入口表维护（模板 B/C：转移器入表 → 机器码按 fid 间接跳转） | 后端、桥 |

**`ConstMirror`**（常量句柄镜像：连续 8 B 数组，**基址烘焙进机器码**）：

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func build(ids: Array<Int64>): ConstMirror` | 单元编译期按 `handleIds` 建镜像（`PUSH_KH` 的取数处） | `JitCompiler.compileUnit` |
| `base(): Int64` / `free()` | 镜像基址（烘焙用） / 释放 | 后端、卸载 |

**归属**：`JitCompiler` = **编排器**（有状态，注入某一后端）；`JitArtifacts` = **产物束**（JIT 路径的可空内部状态——`JitFunction` 持有 `?JitArtifacts`，§7.3.3）；`FnTable` / `ConstMirror` = 产物束内的**两块非 GC 内存资产**（与 `CodeBuffer` 并列）——三者生命周期与 `JitFunction` 同生共死，释放顺序见 §8.7（`code buffer`+`fnTable` 最后释放，可能有活跃调用在执行）。

#### 6.3.4 `BackendSelector`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func select(mode: JitMode, diag: DiagnosticsSink): (Engine, ?Backend)` | Linux + SDK 指令集 → (Jit, 对应后端)；否则 (Interp, None) 并记 diagnostics；**绝不报错、不改语义** | 桥管线第 3 步；T7/T9 |

---

## §7 包 `fountain::f_jit`（门面 / 桥）

### 7.1 包意义

用户 API 与桥层：**Compiler 门面**（配置/注册表/两入口）、**JitFunction**（唯一执行成员 `call<T>` + 生命周期）、**Marshal**（pin/逃逸/解包/适配器注册表）、**编译去重缓存**（只编译一次）、**编译管线编排**、**卸载编排**，并以 `public import` 再导出 base/bytecode/runtime 的用户面声明。

### 7.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `Compiler` | class | 编译上下文实例（配置 + 注册表 + 缓存视图） | 管线、注册表、缓存 | §8.4 |
| `CompileOptions` | class | 引擎选择/CPU 特性/诊断接收器 | JitMode、DiagnosticsSink | §8、§12.1 |
| `PredefinedFunction` | class | 预定义函数（user helper）注册项 | LocalType | §8.4 |
| `JitFunction` | class | 编译产物句柄（执行 + 卸载 + 状态） | runtime、backend、bytecode | §8、§8.2、§8.7 |
| `CompileCache` | class（protected） | 进程级编译去重（指纹 → 条目状态机） | — | §12.6、§8.7 |
| `AdapterRegistry` | class（protected） | `(单元指纹, fnId, T)` → 单态化适配器 | — | §8.2 |
| `CallMarshal` | class（protected） | 参数 Marshal + 返回解包（含路径 B/D 与自动回收） | HandleTable | §8.2.1/8.2.2 |
| `CompilePipeline` | class（protected） | 编排：源/装载 → 校验 → 引擎 → 产物 | compiler、backend、runtime | §8 管线四步 |
| `Report` | class（protected） | 错误报告组装与异常抛出（三态收尾第 3 步） | DbgDump、ErrCode | §8、§9.16 |
| 再导出（public import） | — | base/bytecode/runtime 用户面声明 | — | §7.6 |

### 7.3 各声明的公共成员

#### 7.3.1 `Compiler`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(name!: String = "compiler", opts!: CompileOptions, maxPredefined!: Int64 = 256)` | 建立编译上下文（诊断、注册上限） | 宿主 |
| `func registerFunction(fn: PredefinedFunction): Unit` | 注册预定义函数（重名 → SourceCompileException(DuplicateRegistration)；超限 → 编译期错误） | 宿主；快照语义 |
| `func unregisterFunction(name: String): Unit` | 注销（未注册 → 编译期错误） | 宿主 |
| `func hasFunction(name: String): Bool` | 查询 | 宿主/测试 |
| `func registeredNames(): Array<String>` | 清单（错误提示用） | 前端 hint |
| `func compile(source: String): JitFunction` | 源入口：lambda 源码 → `.fbc` →（Linux 立即 JIT）→ JitFunction；失败抛 SourceCompileException；同源码只编译一次（缓存） | 宿主；T16 |
| `func compile(unit: SourceUnit): JitFunction` | 分发入口：装载 `.fbc`（加载期拒绝含 user hid 的单元）；去重键 = 字节码指纹 | 宿主；T1 |

#### 7.3.2 `CompileOptions`（class） / `PredefinedFunction`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `CompileOptions.jit: JitMode = Auto` / `.cpuFeatures: UInt64 = 0`（M2）/ `.diagnostics: DiagnosticsSink` / `init(diagnostics: DiagnosticsSink)` | 引擎与诊断配置 | 桥管线 |
| `PredefinedFunction.name: String` / `.paramTypes: Array<UInt16>`（LocalType 编码 0–8、10–11）/ `.retType: UInt16` / `.impl: (Array<Any>) -> Any` / `init(name!, paramTypes!, retType!, impl!)` | 注册契约：impl 收已解包仓颉值、返回须与 retType 匹配 | `Compiler.registerFunction`；trampoline 调用 |

#### 7.3.3 `JitFunction`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func call<T>(args: Array<Any>): T` | **唯一对外执行成员**（**两形态同接口**：JIT 产物与纯字节码/解释器产物**同为 `JitFunction`**、同签名、行为逐位一致——D4/D5 结案）：参数长度/元素类型 → Marshal → 三态收尾执行 → 解包 → T 校验（编译期/运行期）→ 返回；执行异常原样转换抛出 | 宿主；T15 |
| `func unload(timeout!: ?Duration = None): Bool` | 卸载单元：CAS Ready→Unloading→排空活跃调用→Unloaded；超时恢复 Ready 可重试；幂等返回 true | 宿主；T29 |
| `prop isUnloaded: Bool` | 状态查询 | 宿主 |
| （私有）`invoke(ctx: CallContext): JitValue` | 桥内部执行入口（三态收尾；errCode → 异常/DEOPT 重放） | `call<T>` |
| （私有）`tryInvoke(ctx): Result<JitValue, JitException>` | 不抛变体（热路径/批量） | 桥内部 |
| 内部状态（设计） | `fnId/entryFn、FuncDir、ConstTable、SiteTable、NameTable、LocalTypes、Engine、?JitArtifacts、activeCalls、unloadState、单元指纹` | 各成员协作 |

#### 7.3.4 `CallMarshal`（protected class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func makeArgMarshalers(sig): Array<(Any) -> Int64>` | 生成逐参转换器（含 HandleTable.pin） | call 六步第 2 步；单态化时按 (签名,T) 缓存 |
| `func marshalArg(a: Any, lt: UInt16): Int64` | 单参 Marshal（§8.2.1 表；不符 → 19） | argMarshalers |
| `func makeRetUnboxer(retType: UInt16, tTag): (Int64) -> Any` | 生成返回值解包器（句柄型先逃逸） | call 六步第 4 步 |
| `func escapeAndGet(id: Int64): Any` | 路径 D 逃逸 + `get` + 窗口逃逸槽自动回收（规则 6①） | call 六步第 4 步 |
| `func cleanup(callState)` | try/finally 清理（B pin/C 窗口/D 逃逸/ctx/dump 缓冲） | call 全路径（含异常） |

#### 7.3.5 `CompileCache` / `AdapterRegistry` / `CompilePipeline` / `Report`（protected）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `CompileCache.lookupOrClaim(sourceCode: String): CacheEntry` / `awaitReady(entry)` / `finish(entry, ok: ?JitFunction)` / `remove(fingerprint)` | **进程级**缓存（根包 static；**D4 结案**）：**内部以 `FNV-1a-128(规范化源码)` 为键**；占位后在 **claim 内**先编译为字节码、Linux + x86_64/aarch64 再 JIT；状态机 Idle→Compiling→Ready/Failed；命中 Ready 复用（**一份源码只出一份字节码与 JIT 产物**）、Compiling 阻塞等待、失败共享异常；分发入口以**字节码指纹**（`FNV-1a-128(整份 raw)`）走同一状态机；命中后**二次校验原字节**；**键不含注册表快照**（推论见 §9：未注册实例命中缓存即成功，属预期语义） | `Compiler.compile`；T16 |
| `AdapterRegistry.register(key, adapters)` / `lookup(key): ?Adapters` / `removeUnit(fingerprint)` | 单态化适配器注册表（宿主侧锁保护） | call 第 5 步；卸载 |
| `CompilePipeline.runSource(source): JitFunction` / `runUnit(unit): JitFunction` | 四步管线编排（编译/装载 → 去重 → 引擎选择 → 产物） | `Compiler.compile` |
| `Report.throwJit(code, site, fnId, dump, tables)` | 组装并经内部统一抛出 JitException（19 的桥层契约错误 site=-1 走此路） | 三态收尾第 3 步 |

#### 7.3.6 再导出清单（根包 `public import`）

| 再导出 | 内容 |
|---|---|
| `public import fountain::f_jit.base.*` | JitException、SourceCompileException、SourcePos、CallContext、SourceUnit、JitMode、LocalType、TypeToken、ErrCode、DiagnosticsSink、DiagnosticLevel、Version（`Engine`/`JitValue` 为 `protected`，不随再导出对外可见） |
| `public import fountain::f_jit.bytecode.*` | OpInfo（含 static 成员 `CAT_*`/`OPCODE_TABLE`）、FuncDir/FuncEntry/LocalTypes、ConstRegistry/ConstKind/ConstPayload、SiteTable/NameTable、FbcReader/FbcWriter/FbcHeader/LoadedUnit |
| `public import fountain::f_jit.runtime.*`（仅用户面） | HandleTable、（@C helper 符号不导出到用户面） |
| 自定义声明 | Compiler、CompileOptions、PredefinedFunction、JitFunction |

---

## §8 关键调用链（跨包协作）

### 8.1 `Compiler.compile(source: String)`（管线四步）

```
Compiler.compile(source)                    // 每次编译新建 Compiler 实例（D4 结案）
 └─ CompilePipeline.runSource
     ├─ ① CompileCache.lookupOrClaim(source)  // 键 = FNV-1a-128(规范化源码)
     │    命中 Ready → 复用同一 JitFunction（零重编译：源码 → 字节码 → JIT 全不重跑）
     │    Miss → CAS 占位（Idle → Compiling）后继续：
     ├─ ② SourceCompiler.compile(source)
     │    Lexer → Parser → NameResolver → DefiniteAssignment → Lowerer → BytecodeBuilder → Assembler
     │    （预定义函数调用编译为 user helper：hid = slot+0x0100）
     ├─ ③ BackendSelector.select(opts.jit, diagnostics)
     │    Linux + SDK 指令集 → JitCompiler.compileUnit(LoadedUnit, handleIds) → JitArtifacts
     │    否则 → 纯字节码/解释器形态（diagnostics 记 (Warn, JitFallback)；不报错）
     └─ ④ new JitFunction(fnId=entryFn, 单元资产…, ?JitArtifacts) → 写回 Ready → 返回
          （两形态同为 JitFunction、同一 call<T> —— D4/D5 结案）
```

### 8.2 `Compiler.compile(unit: SourceUnit)`（分发入口）

同上，替换 ② 为 `FbcReader.load(raw)`（加载期校验；含 user hid 的 `.fbc` → 拒绝，JitException(18) 语义）；去重键换为**字节码指纹 = FNV-1a-128（整份 raw，含头/目录/类型表）**。该入口**无注册表上下文** ⇒ 键天然进程级共享（D4 结案）；命中后同样**二次校验** raw 字节。

### 8.3 `JitFunction.call<T>(args)`（固定六步）

```
1. args.size != nargs → JitException(19)
2. 逐参 Marshal（§8.2.1 表）→ CallContext.args（含 pin）；失败 → 19
3. 三态收尾（§8.4）：执行并转换异常
4. retUnboxer 解包（句柄型先走路径 D 逃逸 + 自动回收）
5. T 一致性：单元内调用点编译期校验；跨模块/动态 → AdapterRegistry 运行期校验 → 19
6. 返回 T；finally：释放本次登记非常量槽 + ctx/dump 配对释放
```

### 8.4 三态收尾（`invoke` 固定流程）

```
0. 入口断言：Ready（未卸载）否则 JitException(19)（site=-1）
1. ctx 复位：errCode=0/site=-1/hwTop=hwBase/fnId=f.id/dbgBase=转储区（首格清零）
2. rax = rawEntry(ctx, &args[0], nargs)      // JIT；无机器码则 Interp.run
3. 按 errCode 分派：0 → unbox；-1 → Interp.run 重跑；-2 → InterruptedException；>0 → Report.throwJit
4. tryInvoke 把 3 的异常收进 Result.Err
```

### 8.5 错误通道与报告

`helper 写槽（ctxWriteCode）` → 自动 `CHECK_ERR`（编译期插入）→ `BAIL` 块（k>0 时单次转储：`dbgBase≠0` 且首格 0 → 写 fnId/nLocals/拷贝 locals；首个收敛点获胜）→ `.epilogue`（唯一返回路径）→ 桥读槽 → `DbgDump.report` 组装源码行 + 变量清单（名查 NameTable、类型查 LocalTypes、值型按 §11.9 文本化、句柄型 `#idx`）→ `JitException`。

### 8.6 卸载（`unload`）

```
Ready --CAS--> Unloading（拒绝新调用；活跃调用照常完成）--activeCalls==0--> Unloaded（终态）
   ▲                    │ timeout 到期（恢复 Ready，可重试）
   └────────────────────┘
资产释放顺序：适配器注册表条目/编译缓存条目 → ConstTable+A 槽（gen+1）→ 目录/字节码/类型表 → code buffer+fnTable（最后，可能仍有活跃调用在执行）
```

### 8.7 跨包共享声明（protected 清单，设计约束）

| 声明 | 定义包 | 消费包 |
|---|---|---|
| `LoadedUnit/FuncDir/LocalTypes/ConstRegistry/SiteTable/NameTable` | bytecode | runtime、backend、根包 |
| `FuncEntry/FuncFlags/OpInfo`（含静态成员 `CAT_*`/`OPCODE_TABLE`） | bytecode | compiler、runtime、backend |
| `JitContext/HandleTable/IterTable/DbgDump/HelperId` | runtime | 根包（+backend 仅经 artifact ABI） |
| `SourceCompiler` / `CompiledSourceUnit` | compiler | 根包 |
| `JitArtifacts/FnTable/ConstMirror/CodeBuffer` | backend | 根包 |
| `Engine`（引擎选择结果）/`JitValue`（桥内执行结果） | base | backend、根包 |

---

## §9 设计决策与理由（补充 §0）

| 决策 | 备选 | 选择理由 |
|---|---|---|
| 6 个包（base/bytecode/compiler/runtime/backend/根） | 单包 / 按对象分（loader/assembler/interp/jit/marshal 各一包） | 按「正确性论证方式」分包：格式（bytecode）、编译期诊断（compiler）、解释语义（runtime）、差分（backend）——测试与回归边界清晰；再细则共享契约会散落 |
| `LocalType/ErrCode/TypeToken/HelperId/Version` 用类+`static const`（同族：`ConstKind`/`FuncFlags`/`FbcFlags`、`OpInfo.CAT_*`） | 顶层常量 / enum | 规格示例 `LocalType.I64` 与 §10.3 的 `OpInfo.CAT_*`（static const 成员）并存：命名空间类给出可点号访问的常量，且可挂 `name()/isHandle()` 查询；避免 250+ 顶层常量污染导入；**线上码族**（编码进 `.fbc` 的数值）必须用 `static const`——枚举构造器不携带数值，序列化与分派需要确定数值码 |
| `OpInfo` 用 **struct**（+ `static const CAT_*` / `static let OPCODE_TABLE`） | 用 class / 顶层常量 | 只读元信息、无身份无行为；值语义浅拷贝约 5 字，无堆分配/GC/指针追逐；`Array<OpInfo>` 内联连续（256 项缓存友好）；类别码用 `static const` 保持编译期可用（可进 `const` 上下文），表用 `static let`（同类静态成员互引，见 `f_util.Crc32.all` 先例） |
| ctx 用 `CPointer<Int64>` 访问器承载 | `struct` 直映射 | 机器码要求 64 B 且不得移动（§4）；Cangjie 布局不承诺逐字节 ⇒ 显式访问器 + 非托管分配 |
| ctx/转储缓冲的非托管内存用 `std.core.LibC.malloc<T>` / `LibC.free<T>` | ① `foreign func malloc/free`；② `acquireArrayRawData` 钉住 `Array<UInt8>` | ① std.core 原生 API、免自声明 FFI；② 钉住方案被 std 文档窗口约束排除（获取与释放之间不得构造仓颉对象，而 ctx 跨整个调用、helper 必分配并触发 GC）；③ malloc 满足 16 B 对齐；**释放一律走桥 `finally`、不使用 `std.core.CPointerResource`**（2026-10-11 裁定，理由见 §5.3.1；T27 计数断言）——详见 §5.3.1 |
| helper 以顶层 `@C` 函数实现 | 集中在一个 class | 与机器码 trampoline 静态链接（符号可见性简单）；三引擎共用同一实现（I7） |
| 异常基类用 `fountain::f_base.BaseException` | 直承 `std.core.Exception` | 仓库统一基类——宿主可跨模块统一 `catch (e: BaseException)`，并复用 f_base 的 `printStackTrace`/抑制异常等能力；报告文本经 `super(message)` 转发，本类自有字段（`code/site/fnId/sourcePos`、`kind/position/…`）不变 |
| `JitFunction` 不拆「Interp 版 / JIT 版」子类 | 两个子类 | 引擎是运行时状态（卸载/诊断/测试都按同一句柄）；单类 + 可选 artifacts 最简 |
| 编译缓存/适配器注册表放根包 | 放 runtime | 它们是「桥的进程级资产」（宿主侧锁、与卸载/缓存语义耦合），非执行期机制 |
| 编译缓存 = **进程级**、键 = 源码指纹（**FNV-1a-128**）；**每次编译新建 `Compiler` 实例**（D4 结案） | ① 缓存按实例隔离（「视图」读法）；② 键附加注册表快照身份 | 用户裁定：**一份源码只出一份字节码与 JIT 产物**（跨实例复用是目标）；`Compiler` 实例只作「一次编译的配置载体」；`compile(unit)` 无注册表 ⇒ 键天然进程级共享。**推论（已确认，是预期语义不是缺陷）**：A 实例编译过源码 S 后，**未注册 S 中所用函数**的 B 实例再 `compile(S)` 会**命中缓存并成功**（不再报 `UnregisteredFunction`）——「一份源码只出一份产物」优先于「未注册即报错」 |
| 两形态产物**同一接口**（`JitFunction.call<T>(args: Array<Any>): T`，D4/D5 结案） | 拆「JIT 版 / 字节码版」两个子类或第二用户面类型 | 调用方无需感知引擎（§0「单类 + 可选 artifacts」的强化）；差异只在内部 `?JitArtifacts`，行为逐位一致 |
| 诊断接口 = `(level, code, message)` + 便捷 `(level, message)`；等级仅 `Info\|Warn`；提供 `DummyDiagnosticsSink`（D1 结案） | ① 极简 `diag(String)`；② 保留 `Error` 档；③ sink 异常向上传播 | 结构化 `code` 可断言（T7 不依赖文案）；`Error` 情形一律异常、走不到 diag；空实现免去用户样板；**sink 异常由引擎吞掉并挂 Suppressed**——降级路径**绝不因诊断失败而报错**（`Error` 不捕、不重入 diag） |
| `JitContext` 为 `protected`（D2 结案） | `public` | ctx 是机器码 ABI 契约（用户写坏即破坏不变量）；用户面无消费路径（`impl` 收已解包值、helper 只见裸指针）；与 `Engine`/`JitValue` 先例一致 |

---

## §10 与规格文档的差异/待裁定项

| # | 项 | 说明 |
|---|---|---|
| D1 | `DiagnosticsSink` 细化（**已结案**） | 2026-10-11 裁定：**结构化 + 便捷双入口**——主签名 `diag(level, code, message)` + 便捷重载 `diag(level, message)`（默认实现转发，`code = Unspecified`）；等级**仅 `Info\|Warn`**（错误直接抛异常，走不到 diag）；事件码 `DiagCode`；空实现 **`DummyDiagnosticsSink`**；三条契约：不承担错误通道 / 不承诺串行化（线程安全由仓颉侧负责）/ **sink 异常由引擎吞掉并挂 Suppressed**（有在途异常 → `在途.addSuppressed(sinkEx)`；无在途 → 仅吞掉、不改语义；`Error` 不捕；不重入 diag；类型建议 `BaseException` 子类但非前提）。落点：§2.3.7、§9 |
| D2 | `JitContext` 公开粒度（**已结案**） | 2026-10-11 裁定：**`protected`**——ctx 布局是机器码 ABI 契约、用户面无消费路径（详见 §5.3.1 可见性段）；`cp()` 仅经 artifact ABI；不随 §7.6 再导出 |
| D3 | `JitValue` 可见性（已结案） | 2026-10-11 裁定：**`protected`**——唯一消费者 `invoke`/`tryInvoke` 为 private，无用户面路径；规格 §8 行 827 已同步 `protected`，§8.7 清单同步 |
| D4 | `CompileCache` 的进程级宿主（**已结案**） | 2026-10-11 裁定：**根包 static 单例（进程级，§9 既有决策）**；`lookupOrClaim(sourceCode)` **内部以源码指纹作键**；状态机 Idle→Compiling→Ready/Failed 不变；**claim 内先编译为字节码、Linux + x86_64/aarch64 再 JIT**；**每次编译新建 `Compiler` 实例**，但**一份源码只出一份字节码与 JIT 产物**（跨实例复用）；**字节码产物与 JIT 产物实现同一接口、对外开放同一 `call<T>(args: Array<Any>): T`**；分发入口键 = 字节码指纹。落点：§0、§7.3.3、§7.3.5、§8.1、§8.2、§9；规格 §8.4/§12.6 同步 |
| D5 | 指纹算法（**已结案**） | 2026-10-11 裁定：**去重键指纹 = FNV-1a-128**（源码指纹 = 规范化源码；字节码指纹 = 整份 raw）；`constFingerprint` 保持 **FNV-1a-64** 落盘；实现**经 `fountain::f_util`**（`Fnv`，32/64/128/256 全宽；f_jit 不自实现）；**命中后二次校验原字节**（碰撞 = 语义错误，不靠概率兜底）。落点：§3.3.8、§7.3.5、§8.1、§8.2；规格 §11.5/§12.5/§12.6 同步 |
| D6 | `Engine` 公开性（已结案） | 2026-10-11 裁定：**`protected`**（原「为测试/诊断设为 public」作废）——诊断与测试均在本模块内（`src/test/...`，protected 可见）；规格 §8 支撑类型已补 `protected enum Engine`，§8.7 清单同步 |
| D7 | **异常基类（已结案）**：规格 §8 原声明 `<: Exception`（行 792/1075），2026-10-11 裁定统一改用仓库基类 `fountain::f_base.BaseException`——**规格已同步落笔**（`<: BaseException` + 支撑类型段说明），设计与计划同步 | 无需再裁定；`base` 包外部依赖补 f_base；`fountain::f_exception` 对该基类有 `public import` 再导出，两种 import 路径等价 |

---

## 附录：语法 → 字节码 · 指令定义 · 机器码对照（实现用）

**三张表**：**附 A** 语法元素 → 字节码（降低对照）；**附 B** 字节码指令定义（ISA 明细）；**附 C** 字节码 ↔ 机器码（JIT 后端发射）。

**口径**：三表的**权威文本是规格 `jit-bytecode-m1.md`**（逐条附锚点）；本附录为同源摘录/整理（附 B、附 C 的表格由规格 §5 / §12.4 抽取），**冲突以规格为准**，规格改动须同步本附录。锚点列的 `§x.y` 均指规格章节（design 内部章节写作 `design §x.y`）。

**范围**：M1 全量；**M2 / M3 增量**（宿主闭包 / 宿主对象 / Any / JSON 等）在各自增量设计中给出同类三表——见 `design-m2.md`、`design-m3.md` 附录。

## 附 A 语法元素 → 字节码（M1）

**读法**：「降低产物」列给**指令序列要点**（栈效应/操作数逐条见附 B）；「关键指令」列的十六进制为该组首编号。一个源结构对应多条指令时按**从左到右求值**展开（§5 各降低模式）。

### A.1 字面量与常量

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 整数字面量（含窄化） | `42`、`70000` | 按值选**最短形式**：i8 域 → `PUSH_I8`、i32 域 → `PUSH_I32`、其余 → `PUSH_I64`；**超 Int64 域不报错**——编译为 Decimal 常量（scale 0，精确构造） | `0x10`–`0x12` | §5、§11.9 |
| 小数字面量 | `1.5`、`3e2`、`1e-3` | **自动编译为 Decimal 常量**（kind 6；按字面文本精确构造，`3e2` → scale=-3，**不经 Float64**）；显式 `1.5f64`（语法形式由前端定义）→ Float64 常量 | `PUSH_KH` | §11.9、§11.5 |
| 布尔字面量 | `true` / `false` | `PUSH_BOOL` | `0x14` | §5 |
| `null` 字面值 | `null` | `PUSH_NULL`——**M1 无合法落点**（句柄型局部恒非空、直存被校验 10 拒绝）；保留关键字仅为准确诊断 | `0x15` | §7 校验 10 |
| 字符串字面量（三形态） | `'…'` / `"…"` / `'''…'''` / `#…#` | 常量注册（kind 3）→ `PUSH_KH idx`；**定界扫描取串体 → 锚定截取 → 转义解码 → 插值切分**（顺序冻结） | `0x16` | §8.8、design §4.4 |
| 字符串插值 | `"a${e}b"` | 各片段：非 String 片段 → `TO_STR t`（Value 标签见 §11.9），String 片段原样；片段间 `STR_CAT` 左折叠；`${}` 为空 → 编译错误 | `0xB7`/`0xA4` | §11.9、S3.12 |
| 正则字面量 | `/[a-z]/iu` | 常量注册（kind 10）→ `PUSH_KH idx`；**空 pattern 加载期拒绝** | `0x16` | §3.3、§11.9 |
| 空 List / 空 Map 字面量 | `[]` / `{}` | `MAKE_LIST` / `MAKE_MAP`（分配型；v0.18 起**运行期构造**、非常量） | `0xA0`/`0xA2` | §3.3 |
| Range 字面量 | `a..b : s`、`a..=b` | `RANGE_NEW`（isClosed 由 `..`/`..=` 决定；**step=0 → 14**，常量 step=0 前端即拒） | `0x9A` | §11.9 |
| JSON 字面量 | `` `{…}` ``（**唯一形态**） | **M3 起**：常量 kind 11（非空）+ **JSON 内建句柄码 16–19**（v0.3.20）；M1 无此形态 | — | m3 §11 → design-m3 附 A |

### A.2 变量与赋值

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 变量引用 | `x` | 普通局部：`LOADL i`（i<4 可用压缩形式 `LOADL0`–`LOADL3`）；**闭包捕获**：`LOAD_CAP idx`（H56，读闭包句柄捕获第 idx 项） | `0x20`–`0x26` | §8.0、§8.6 |
| 声明 / 赋值 | `let x = e`、`var x`、`x = e` | 求值 `e` → `STOREL i`；**声明即首写**（明确赋值起点；声明后未写即读 = 编译错误） | `0x21` | §7 校验 10 |
| 多重赋值 / 交换 | `(a, b) = (b, a)` | 每个 RHS → **隐藏局部**（类型 = 各 RHS 静态类型，声明即首写）→ 依序 `STOREL` 回 LHS（**先读后写**，交换天然正确）；`_` 槽对应 RHS **仍求值**、结果 `POP`；RHS 仅一维元组字面量、从左到右求值 | `0x21`/`0x19` | §5 降低模式 |

### A.3 运算与转换

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 整型算术 | `+` `-` `*` `/` `%` | `IADD`/`ISUB`/`IMUL`/`IDIV`/`IMOD`（溢出 → 3、÷0 → 1、`%` 除以 0 → 2）；**`%` 仅 (Int64, Int64)**，不参与提升 | `0x30`–`0x34` | §5、§11.9 |
| 整型一元 / 位运算 | `-x`、`&`、`\|`、`^`、`~`、`<<`、`>>`、`>>>` | `INEG`/`IABS`/`IMIN`/`IMAX`/`BAND_I`/`BOR_I`/`BXOR_I`/`BNOT_I`/`SHL_I`/`SHR_I`/`USHR_I`；位计数 `ICLZ`/`IPOPCNT`；显式无检查加 `IADD_WRAP` | `0x35`–`0x3B`、`0x62`–`0x68` | §5 |
| 浮点算术 | `+` `-` `*` `/`（F64 域） | `FADD`/`FSUB`/`FMUL`/`FDIV`（IEEE，除零得 ±Inf **不报错**）；**缺省严格** → `FDIV_CHK`（÷0 → 1；`CompileOptions.strictFp = false` 才用 `FDIV`）；**全程 NaN 规范化** | `0x40`–`0x44` | §5、§11.3 |
| 浮点一元 / 取整 | `-x`、`abs`、`min`/`max`、开方、取整族 | `FNEG`/`FABS`/`FMIN`/`FMAX`/`FSQRT`/`FFLOOR`/`FCEIL`/`FTRUNC`/`FROUND`（NaN → canonical NaN） | `0x45`–`0x4D` | §5、§11.3 |
| 数值比较 | `==` `!=` `<` `<=` `>` `>=` | 整型 → `EQ_I`–`GE_I`；浮点 → `EQ_F`–`GE_F`（NaN 语义冻结）；文本/时间 → `CMP_STR`/`CMP_DEC`/`CMP_DT`/`CMP_DUR`（helper；6/8/11/12） | `0x52`–`0x5D`、`0x6B`–`0x6E` | §5、§11.3 |
| 句柄等值 | `h == h2`、`h == null` | `EQ_H`/`NE_H`——**同一性比较、不解引用** | `0x69`/`0x6A` | §5 |
| 逻辑（短路） | `a && b`、`a \|\| b` | `JZ`/`JNZ` **短路链**；`AND_B`/`OR_B`/`XOR_B` 仅用于两侧均已求值的场景（无短路） | `0x71`/`0x72`、`0x5F`–`0x61` | §5 降低模式 |
| 逻辑非 | `!x` | `NOT_B` | `0x5E` | §5 |
| 隐式提升（混合运算/比较） | `i64 op f64`、`i64 op dec`、`f64 op dec`（含反序） | 窄侧自动插 `TO_F64` / `TO_DEC(src=0/1)`；宽度序 **Decimal > Float64 > Int64**；字节码层无隐式行为（I6） | `0x82`/`0x9C` | §11.9 |
| 显式数值转换 | 形式由前端定义（如 `x as Int64`） | 6 方向互转指令；**窄化方向（F64→I64、DEC→I64、DEC→F64）仅经显式形式可达**；失败按 mode 选报错（13/9）或 DEOPT | `0x81`/`0x82`/`0x9C`–`0x9E` | §11.9 |
| n 位置自动窄化 | `s * n`、`d * n`、`d / n` 的 n 位置 | n 为非 Int64 时前端插 `TO_I64(mode=0)` / `DEC_TO_I64(mode=0)`；**仅限这三处** | `0x81`/`0x9D` | §11.9 |

### A.4 控制流

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| `if`（**语句形式**） | `if (c) { … }` | 条件 → `JZ else`；各分支栈净深 0（末值 `POP`）；**分支类型不受限**；裸 `if`（无 else 收尾）允许 | `0x71`/`0x19` | §5 降低模式 |
| `if`（**表达式形式**） | `let x = if (c) { a } else { b }` | 各分支恰留 1 cell、**类型逐位一致**（同一 LocalType，否则编译错误）；`JZ`/`JMP` 汇合；**必须有最终 else** | `0x71`/`0x70` | §5 降低模式 |
| `if-else if-else` | 逐级 | `else if` = else 分支内嵌套 if，每级各自 `JMP end` 汇合 | `0x71`/`0x70` | §5 降低模式 |
| `while` | `while (c) { … }` | `header:` 条件 → `JZ end`；体；回边 `LOOP_BACK header`（= `STACK_GUARD` + `interrupt_poll` H22 安全点 + `jmp`） | `0x74` | §5、§12.6 |
| `while (true)` | 无限循环 | 省略头部 `JZ`，**回边安全点必须保留**（deadline → -2 可中断） | `0x74` | §12.6 |
| `for-in`（Range） | `for (i in a..b : s) { … }` | 隐藏计数局部（Int64，计入 nLocals）：初始化起点 → 按 s 符号与端点比较 → 体 → `i = i ± s` → 回边；空区间首轮即假 | `0x71`/`0x74` | §5 降低模式、§11.9 |
| `for-in`（List） | `for (x in list) { … }` | **长度快照** `n = LEN(h)` + 索引循环 + `GET_IDX`（迭代中越界 → 4） | `0x90`/`0x91` | §11.9 |
| `for-in`（Map） | `for ((k, v) in map) { … }` | `cur = MAP_ITER_BEGIN(m)` → `has = MAP_ITER_STEP(cur, 0)`（**0 → 跳出口**）→ `STEP(cur, 1)` / `STEP(cur, 2)` 取键值 → 体 → 回跳；**出口标签处发一次 `STEP(cur, 3)`（close，幂等，覆盖条件出口与 break）**；**不登记窗口槽**；迭代中修改同一 map → 23 | `0xAF`/`0xBE` | §11.9（v0.16.1） |
| `for-in`（String） | `for (ch in s) { … }` | 索引 + `STR_AT`（**码点序**） | `0x95` | §11.9 |
| `where` 谓词 | `for (i in it where c) { … }` | 体内首条：条件不满足 → **跳至 continue 点** | `0x71` | §5 降低模式 |
| `break` / `continue` | | `break` = `JMP end`；`continue` = `JMP` 至**回边指令之前**（保证每轮都过安全点）；**无专用指令** | `0x70` | §5 降低模式 |
| `return e` / `return` | | `RET` / `RET_VOID`（引用位返回另用 `RET_NULL`）——全部 `jmp .epilogue`，**唯一返回路径** | `0x7C`–`0x7E` | §5、§12.3 |
| 明确赋值与回边 | 循环内赋值 | 数据流**不动点迭代**；循环不保证执行一轮 ⇒ **仅在循环体内 STOREL 的局部，出口后不视为已赋值**（读 = 编译错误） | —（前端分析） | §7 校验 10 |
| `recursive(…)` 调用 | 自递归 | 顶层：`CALL_FUNC <entryFn>`（fid=自身）；闭包层：`LOADL 0` + `CALL_CLOSURE`；**尾位置 → 实参逆序 `STOREL` + `LOOP_BACK <函数入口>`（帧复用，v0.17，不发射 RET）** | `0x78`/`0x7F`/`0x74` | §8.0、§5 降低模式 |
| `recursive` 作右值 | `let f = recursive` | 闭包层 = `LOADL 0`（零成本自引用）；顶层 = `closure_new <adapterFn>`（0 捕获隐藏适配器，体 = 转发 `CALL_FUNC entryFn`） | `CALL_HELPER` H54 | §8.0、§8.6 |

### A.5 闭包与调用

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 闭包声明 | `{x => …}`、`let f = {…}` | 独立 FuncEntry（**帧 locals[0] = 闭包句柄、locals[1..] = 形参**）+ 捕获快照打包 `closure_new`（H54，分配型） | `CALL_HELPER` H54 | §8.5、§8.6 |
| 闭包体内捕获读取 | 捕获变量引用 | `LOAD_CAP idx`（H56；仅闭包函数体） | `0x26` | §8.6 |
| 闭包调用 | `f(a1, a2)` | 实参**从左到右**入栈 → `LOADL f`（句柄压栈底）→ `CALL_CLOSURE 2`；fnId 由前端烘焙并经 `closure_new` 双重校验 | `0x7F` | §8.6 |
| IIFE | `{…}(a)` | 同闭包调用（匿名 FuncEntry 立即调用） | `0x7F` | §8.5 |
| first-class 闭包值（12 型） | 传参 / 返回 / 存局部 | 句柄型 cell；**逃逸 = M1 编译错误**（M2 起经提升组回桥：design-m2 附 A） | — | §8.6、m2 §14 |

### A.6 容器 / 字符串 / 时间 / 正则

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 容器索引读 | `list[i]`、`map[k]`（含缺省、存在性） | `GET_IDX`（越界 4）/ `GET_KEY`（缺键 5）/ `GET_KEY_OR`（缺键取默认）/ `HAS_KEY` | `0x91`–`0x94` | §5 |
| 容器变更 | `add` / `[i] = v` / `insert` / `remove` / `map[k] = v` / `map.remove(k)` | `LIST_APPEND`/`LIST_SET`/`LIST_INSERT`/`LIST_REMOVE`/`MAP_PUT`/`MAP_REMOVE`——**变更型**（§9.15 全规则：常量禁写 20、deopt 禁令、兜底） | `0xA1`/`0xA3`/`0xAB`–`0xAE` | §9.15 |
| 容器 / 字符串长度 | `len(x)` | `LEN`（按**静态类型**分派 helper H01/H03/H07） | `0x90` | §5 |
| 字符串切片 | `s[a..b]`、`s[a..=b]` | `STR_SUB`（**码点索引半开区间**；`..=` 由前端折算；越界/逆序 → 4） | `0xB8` | §11.4、§11.9 |
| 字符串重复 | `s * n`（反序前端换序） | `STR_REPEAT`（`n ≤ 0` → 空串；`n × len_utf8` 溢出 → 3；分配型） | `0xBC` | §11.9（v0.15） |
| 字符串替换 | `s.replace(old, new)` | `STR_REPLACE`（old 为空串 → 14；分配型） | `0xB9` | §5 |
| 字符串混合加法 | `s + x`、`x + s` | 非 String 侧 `TO_STR(t_x)` → `STR_CAT`；可文本化类型 = TO_STR 标签集（**Closure / List / Map / Unit → 编译错误**）；`x` 恰好求值一次 | `0xB7`/`0xA4` | §11.9（v0.18.15） |
| 正则匹配操作符 | `re ~ s`、`re !~ s` | `REGEX_IS_MATCH`（`!~` 追加 `NOT_B`）；优先级：高于加法、低于乘除 | `0xBA` | §11.9（v0.11） |
| 正则替换操作符 | `re/s/r/g`、`re/s/r/n`、`re/s/r/n,m` | **helper 直呼**（无专用 opcode）：`CALL_HELPER` H58 / H59 / H72 | `0x75` | §11.9（v0.18.19） |
| 正则查找 | `re.find(s)` | `REGEX_FIND`（首个匹配；无匹配 → 0；分配型） | `0xBB` | §5 |
| Regex 构造 | `s.regex()` | `STR_TO_REGEX`（H69；非法/空 pattern → 14；分配型） | `0xBF` | §3.3 |
| 时间 / 时长算术 | `dt ± dur`、`dur ± dur`、`dur * n`、`dur / n`、`-dur`、`dt1 - dt2` | `DT_ADD`/`DT_SUB`/`DUR_ADD`/`DUR_SUB`/`DUR_MUL`/`DUR_DIV`/`DUR_NEG`/`DT_DIFF`（`×`/`÷` 的 n 位置可按 n 位置规则自动窄化；量纲面封闭） | `0xB0`–`0xB6`/`0xBD` | §11.9 |
| 时间字段读取 | 源形式由前端定义 | `DT_FIELD f`（f 编号见 §6 H14 行） | `0x96` | §5、§6 |
| 时长取纳秒 | 源形式由前端定义 | `DUR_TICKS` | `0x97` | §5 |
| Decimal ↔ 整型问答 | 源形式由前端定义 | `DEC_IS_INT` | `0x98` | §5 |
| 区间包含判定 | 源形式由前端定义 | `RANGE_CONTAINS`（`..=` 含 end；空区间恒 false） | `0x9B` | §11.9 |

### A.7 守卫 / 错误 / 调试（前端发射点）

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 句柄空安全守卫 | 隐式（句柄型解引用前） | `GUARD_NNZ mode`（null → 6 / DEOPT）；静态可证非空则省略 | `0x88` | §5、§3.2 |
| 类型断言/守卫 | 类型注解驱动的边界检查 | `GUARD_TYPE tok mode`（8 / DEOPT）、`IS_TYPE`（纯判定，永不失败）、`CAST tok mode`（7 / DEOPT） | `0x80`/`0x83`/`0x84` | §5 |
| 显式抛出 / 断言 | 前端语法面提供时 | `THROW code`（写 17 + 站点附加表记源语言码）/ `ASSERT code` / `ABORT code` | `0x85`–`0x87` | §5 |
| 调试陷阱 | 调试模式 | `TRAP`（发布版不发射） | `0x01` | §5 |
| 站点与错误检查 | 隐式（可能失败的指令前） | `SET_SITE i32`（伪指令展开）+ 各 `CALL_HELPER` **自动尾随 `CHECK_ERR`** | `0x03`/`0x04` | §7、I3 |
| 栈防守与安全点 | 隐式（回边/进入） | `STACK_GUARD need`（不足 → DEOPT）、`LOOP_BACK` 内 `call H22`（-2 仅此产生） | `0x07`/`0x74` | §5、§12.6 |
| **M2 / M3 增量** | 成员访问糖、`C(args…)`、宿主闭包调用、Any 装箱/转型、JSON 字面量与 `j[i]` | 见 `design-m2.md` 附 A、`design-m3.md` 附 A | — | — |

## 附 B 字节码指令定义（M1 ISA）

**编码与命名（§10.1）**：

- 常量名 `OP_<助记符>`（大写下划线，如 `OP_PUSH_I8`、`OP_CALL_HELPER`）。
- 指令编码 `[op:u8][operands…]`，**小端**；`rel` 为相对**下一条指令**的有符号 32 位偏移；**M1 指令全部定长**。
- 保留区（未分配槽 + 0xC0–0xFF）与禁用区（0xA9–0xAA 时间构造）在 M1 **发射即 `ERR_NOT_IMPL`**。
- 实现侧以 `OpInfo.OPCODE_TABLE`（256 项、`table[i].code == i`）为唯一索引源，供**反汇编 / 汇编期校验 / 调试器共用**（§10.3）。

**操作数编码种类（§10.2）**：

| 记法 | 长度（B） | 含义 |
|---|---|---|
| `-` | 0 | 无操作数 |
| `u8` / `i8` | 1 | 无符号 / 有符号 8 位 |
| `u16` | 2 | 无符号 16 位（局部索引、常量索引、helper id、类型 token） |
| `i32` | 4 | 有符号 32 位（site 值、立即数） |
| `rel32` | 4 | 相对偏移（跳转目标） |
| `i64` | 8 | 64 位立即数（整数值或 Float64 位模式） |
| `u16 u8` | 3 | 双操作数（如 helper id + argc） |

**类别码（`OpInfo.CAT_*`，§10.3）**：

| 码 | 类别 | 说明 |
|---|---|---|
| 0 | `CAT_MISC` | 控制 / 杂项 |
| 1 | `CAT_CONST` | 常量 / 栈 |
| 2 | `CAT_LOCAL` | 局部变量 |
| 3 | `CAT_I64` | 整型算术 |
| 4 | `CAT_F64` | 浮点算术 |
| 5 | `CAT_CMP` | 比较 / 逻辑 / 位 |
| 6 | `CAT_CTRL` | 控制流 |
| 7 | `CAT_CALL` | 调用 |
| 8 | `CAT_TYPE` | 类型 / 转换 / 错误 |
| 9 | `CAT_BOX` | 容器 / 值运算 / 转换（helper 路由，含分配型） |
| 10 | `CAT_FORBID` | 禁用（容器 / 时间构造，M2 启用） |
| 11 | `CAT_RSVD` | 保留 |

**全表**（按 opcode 分组；栈作用列 `… a b → c` 表示**先弹 b 再弹 a**；逐条同源摘录自规格 §5）：

#### B.1 0x00–0x0F 控制 / 杂项

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 00 | `NOP` | — | 无操作 | — |
| 01 | `TRAP` | u8 | 调试陷阱 | — |
| 02 | `BREAKPOINT` | — | 保留，发布版空操作 | — |
| 03 | `SET_SITE` | i32 | 写 `ctx.site`；伪指令展开目标 | — |
| 04 | `CHECK_ERR` | rel32 | `errCode != 0` → 跳 bail | — |
| 05 | `BAIL` | i8 k | 写错误槽=k，`eax=0`，跳 epilogue | — |
| 06 | `CHECK_ERR_NC` | — | 仅断言（发布版空操作），调试期校验 | — |
| 07 | `STACK_GUARD` | u16 need | 剩余栈 < need → `BAIL -1`（DEOPT） | DEOPT |
| 08–0F | 保留 | | | |

#### B.2 0x10–0x1F 常量 / 栈

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 10 | `PUSH_I8` | i8 | `→ sext(v)` | — |
| 11 | `PUSH_I32` | i32 | `→ sext(v)` | — |
| 12 | `PUSH_I64` | i64 | `→ v` | — |
| 13 | `PUSH_F64` | i64(bits) | `→ v`（位模式原样） | — |
| 14 | `PUSH_BOOL` | u8 | `→ 0/1` | — |
| 15 | `PUSH_NULL` | — | `→ 0`（不得直存句柄型局部，§7 校验 10） | — |
| 16 | `PUSH_KH` | u16 idx | 压常量句柄 | — |
| 17 | `DUP` | — | `a → a a` | — |
| 18 | `DUP2` | — | `a b → a b a b` | — |
| 19 | `POP` | — | `a →` | — |
| 1A | `POP2` | — | `a b →` | — |
| 1B | `SWAP` | — | `a b → b a` | — |
| 1C | `PICK` | u8 n | `… v → … v v`（n=0 等价 DUP） | — |
| 1D–1F | 保留 | | | |

#### B.3 0x20–0x2F 局部变量

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 20 | `LOADL` | u16 i | `→ locals[i]` | 越界=编译错误 |
| 21 | `STOREL` | u16 i | `v → locals[i]=v` | 越界=编译错误 |
| 22 | `LOADL0` | — | `→ locals[0]`（压缩形式，可选） | — |
| 23 | `LOADL1` | — | `→ locals[1]` | — |
| 24 | `LOADL2` | — | `→ locals[2]` | — |
| 25 | `LOADL3` | — | `→ locals[3]` | — |
| 26 | `LOAD_CAP` | u16 idx | 闭包句柄（locals[0]）→ 捕获第 idx 个 cell（H56；仅闭包函数 prologue/体内使用，§8.6） | 6, 8 |
| 27–2F | 保留 | | | |

#### B.4 0x30–0x3F 整型算术（IADD–IMOD 检查溢出 / 除零；IADD_WRAP 显式无检查）

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 30 | `IADD` | a+b | 3 |
| 31 | `ISUB` | a-b | 3 |
| 32 | `IMUL` | a*b | 3 |
| 33 | `IDIV` | a/b（向零截断） | 1, 3（INT_MIN/-1） |
| 34 | `IMOD` | a%b（余数符号随被除数；`INT_MIN % -1 → 0`，不报溢出）；源语言 `%` 仅 `(Int64, Int64)` 定义（§11.9） | 2 |
| 35 | `INEG` | -a | 3 |
| 36 | `IABS` | \|a\| | 3 |
| 37 | `IMIN` | min(a,b) | — |
| 38 | `IMAX` | max(a,b) | — |
| 39 | `IADD_WRAP` | a+b 无检查（显式选择） | — |
| 3A | `ICLZ` | 前导零计数 | — |
| 3B | `IPOPCNT` | 位中 1 的个数 | — |
| 3C–3F | 保留 | | |

#### B.5 0x40–0x4F 浮点运算

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 40 | `FADD` | a+b（IEEE） | — |
| 41 | `FSUB` | a-b | — |
| 42 | `FMUL` | a*b | — |
| 43 | `FDIV` | a/b，IEEE（得 ±Inf/NaN，**不报错**） | — |
| 44 | `FDIV_CHK` | a/b，÷0 报错（strictFp） | 1 |
| 45 | `FNEG` | -a | — |
| 46 | `FABS` | \|a\| | — |
| 47 | `FMIN` | min（任一操作数为 NaN → canonical NaN，§11.3） | — |
| 48 | `FMAX` | max（同上） | — |
| 49 | `FSQRT` | √a（负数 → NaN） | — |
| 4A | `FFLOOR` | 向下取整（保留 NaN/±Inf） | — |
| 4B | `FCEIL` | 向上取整 | — |
| 4C | `FTRUNC` | 向零取整 | — |
| 4D | `FROUND` | 四舍六入五成双 | — |
| 4E–4F | 保留 | | |

#### B.6 0x50–0x6F 比较 / 逻辑 / 位运算

| Hex | 名称 | 语义（`a b → r`） | 备注 |
|---|---|---|---|
| 50 | `CMP_I` | -1/0/1 | 整型三路比较 |
| 51 | `CMP_F` | -1/0/1 | **NaN → 结果未定义**，汇编器禁止对其发射 |
| 52 | `EQ_I` | 0/1 | |
| 53 | `NE_I` | 0/1 | |
| 54 | `LT_I` | 0/1 | |
| 55 | `LE_I` | 0/1 | |
| 56 | `GT_I` | 0/1 | |
| 57 | `GE_I` | 0/1 | |
| 58 | `EQ_F` | 0/1 | NaN 比较恒 false |
| 59 | `NE_F` | 0/1 | NaN ≠ 任意 → true |
| 5A | `LT_F` | 0/1 | |
| 5B | `LE_F` | 0/1 | |
| 5C | `GT_F` | 0/1 | |
| 5D | `GE_F` | 0/1 | |
| 5E | `NOT_B` | `a → !a` | |
| 5F | `AND_B` | a&&b（0/1） | 无短路；短路用跳转 |
| 60 | `OR_B` | a\|\|b | |
| 61 | `XOR_B` | a^b（bool） | |
| 62 | `BAND_I` | a&b | |
| 63 | `BOR_I` | a\|b | |
| 64 | `BXOR_I` | a^b | |
| 65 | `BNOT_I` | ~a | |
| 66 | `SHL_I` | a<<b（b 取低 6 位） | 与硬件一致 |
| 67 | `SHR_I` | a>>b 算术 | |
| 68 | `USHR_I` | a>>>b 逻辑 | |
| 69 | `EQ_H` | 句柄同一性（== null 亦用此） | 不解引用 |
| 6A | `NE_H` | 句柄不同一 | |
| 6B | `CMP_STR` | 字符串序（helper H09） | 6 |
| 6C | `CMP_DEC` | Decimal 序（helper H11） | 6, 8 |
| 6D | `CMP_DT` | DateTime 序（helper H13） | 6, 11 |
| 6E | `CMP_DUR` | Duration 序（helper H15） | 6, 12 |
| 6F | 保留 | | |

#### B.7 0x70–0x7F 控制流与调用

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 70 | `JMP` | rel32 | 无条件跳 | — |
| 71 | `JZ` | rel32 | `c==0` 跳（弹 c） | — |
| 72 | `JNZ` | rel32 | `c!=0` 跳 | — |
| 73 | 保留 | | | |
| 74 | `LOOP_BACK` | rel32 | 回边：`STACK_GUARD` + 安全点 → 跳 | DEOPT / -2 |
| 75 | `CALL_HELPER` | u16 hid, u8 argc | 调 helper，压结果；**汇编器自动尾随 CHECK_ERR**（hid：1–62、69–72 = 固定 helper §6；[0x0100,0xFFFF] = 单元私有预定义 helper §8.4，仅源入口产物） | helper 码 |
| 76 | `CALL_HELPER_NC` | u16 hid, u8 argc | 同上但不做错误检查（仅永不失败的纯函数允许） | — |
| 77 | `CALL_HELPER_V` | u16 hid, u8 argc | 返回 Unit，不压栈；**自动尾随 CHECK_ERR**（与 CALL_HELPER 同） | helper 码 |
| 78 | `CALL_FUNC` | u16 fid, u8 argc | 内部 JIT 函数调用（共窗口） | 传播 + 14 |
| 79 | `CALL_HOST` | u16 fid, u8 argc | 经薄 @C 包装调宿主回调（**M1 汇编期报 `ERR_NOT_IMPL`**，M2 启用；八项困难与三档演进路径见 §6 议题清单） | 传播 |
| 7A | `HW_OPEN` | u16 cap | 打开分配区块（M1 汇编期报 `ERR_NOT_IMPL`） | 16 |
| 7B | `HW_CLOSE` | — | 关闭区块 | — |
| 7C | `RET` | — | `t=[rsp]`；`rax=t`；跳 epilogue | — |
| 7D | `RET_VOID` | — | `rax=0`；跳 epilogue | — |
| 7E | `RET_NULL` | — | `rax=0`（引用返回位） | — |
| 7F | `CALL_CLOSURE` | u8 argc | 栈 [闭包句柄, a1…argc] → 间接调用闭包（§8.6；被调帧 locals[0]=句柄） | 传播 + 6, 8, 19 |

#### B.8 0x80–0x8F 类型 / 转换 / 显式错误

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 80 | `CAST` | u16 tok, u8 mode | 值/句柄转型；mode 0=报错 1=deopt | 7 / DEOPT |
| 81 | `TO_I64` | u8 mode | F64→I64（NaN/越界按 mode） | 13 / DEOPT |
| 82 | `TO_F64` | — | I64→F64（可能丢精度，不报错） | — |
| 83 | `IS_TYPE` | u16 tok | 句柄类型判定 `→ 0/1`（null→false） | — |
| 84 | `GUARD_TYPE` | u16 tok, u8 mode | 类型不符按 mode 处理 | 8 / DEOPT |
| 85 | `THROW` | u8 code | 写错误槽=17，site 附加表记源语言码 | — |
| 86 | `ASSERT` | u8 code | 弹 bool，false → BAIL(code) | code |
| 87 | `ABORT` | u8 code | 无条件 BAIL(code) | code |
| 88 | `GUARD_NNZ` | u8 mode | 栈顶句柄为 0 时按 mode 处理 | 6 / DEOPT |
| 89 | `TYPE_OF` | — | 句柄 → 类型 token（调试用） | 6 |
| 8A–8F | 保留 | | | |

#### B.9 0x90–0x9F 容器 / 值提取 / 数值转换（走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 90 | `LEN` | — | 句柄 → 元素数（List/Map/String 通用） | 6, 8 |
| 91 | `GET_IDX` | — | `h i → 元素` | 4, 6 |
| 92 | `GET_KEY` | — | `h k → 值`（缺键报错） | 5, 6 |
| 93 | `GET_KEY_OR` | — | `h k d → 值`（缺键取 d） | 6 |
| 94 | `HAS_KEY` | — | `h k → 0/1` | 6 |
| 95 | `STR_AT` | — | `h i → Rune(Int64)` | 4, 6 |
| 96 | `DT_FIELD` | u8 f | `h → 字段值`（f 见 §6 H14） | 6, 11 |
| 97 | `DUR_TICKS` | — | `h → 纳秒 Int64` | 6, 12 |
| 98 | `DEC_IS_INT` | — | `h → 0/1` | 6, 8 |
| 99 | `HANDLE_TAG` | — | 调试：取 tag | 6 |
| 9A | `RANGE_NEW` | — | `start end step isClosed → h`（H41；isClosed 对应仓颉 `..` / `..=`；step=0 或 isClosed∉{0,1} → 14；空区间规则见 §11.9） | 14, 16 |
| 9B | `RANGE_CONTAINS` | — | `h v → 0/1`（H42；语义见 §11.9） | 6, 8 |
| 9C | `TO_DEC` | u8 src | src=0：Int64→Decimal（精确，scale 0，H28）；src=1：Float64→Decimal（最短往返，H29） | 13, 16 |
| 9D | `DEC_TO_I64` | u8 mode | mode=0：向零截断、越界 → 9（H30）；mode=1：越界 → DEOPT | 9 / DEOPT |
| 9E | `DEC_TO_F64` | — | IEEE 最近偶数，溢出 → ±Inf 不报错（H31） | 6, 8 |
| 9F | 保留 | | | |

#### B.10 0xA0–0xAF 分配/变更区（v0.5 起大部分启用；分配 = 登记新槽，变更 = 修改容器，§9.15）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| A0 | `MAKE_LIST` | — | `→ h` 新建空 List（H70，v0.18；分配型；对应源语言空字面值 `[]`，§3.3） | 16 |
| A1 | `LIST_APPEND` | — | `list cell → 0` 追加尾部（H43；ArrayList.add） | 6, 8, 20 |
| A2 | `MAKE_MAP` | — | `→ h` 新建空 Map（H71，v0.18；分配型；对应源语言空字面值 `{}`，§3.3） | 16 |
| A3 | `MAP_PUT` | — | `h k v → 0` 写键（H44；`map[k] = v` 语义） | 6, 8, 20 |
| A4 | `STR_CAT` | — | `h1 h2 → h` 字符串拼接（H32；插值串与混合 String 加法原语，不可变结果） | 6, 16 |
| A5 | `DEC_ADD` | — | `h1 h2 → h`（H24；decimal128 语义，§9.12/§11.9） | 9, 16 |
| A6 | `DEC_SUB` | — | `h1 h2 → h`（H25） | 9, 16 |
| A7 | `DEC_MUL` | — | `h1 h2 → h`（H26） | 9, 16 |
| A8 | `DEC_DIV` | — | `h1 h2 → h`（H27；÷0 → 10） | 9, 10, 16 |
| A9 | `DT_NEW` | — | 禁用（M2；M1 的 DateTime 来自常量/桥/DT±DUR） | — |
| AA | `DUR_NEW` | — | 禁用（M2） | — |
| AB | `LIST_INSERT` | — | `h i cell → 0` 定点插入（H45；add(T, at!)；i 越界 → 4） | 4, 6, 8, 20 |
| AC | `LIST_SET` | — | `h i cell → 0` 下标写（H46；`list[i] = v`；越界 → 4） | 4, 6, 8, 20 |
| AD | `LIST_REMOVE` | — | `h i → cell` 下标删除并返回被删元素（H47；remove(at!)；越界 → 4） | 4, 6, 8, 20 |
| AE | `MAP_REMOVE` | — | `h k → 0/1` 删键（H48；1=已删 0=本无此键，不报 5） | 6, 8, 20 |
| AF | `MAP_ITER_BEGIN` | — | `h → i64` 建立宿主侧 Map 迭代器并返回**游标**（H49，v0.16.1 重定义；**不登记窗口槽**——状态在宿主侧调用级迭代器表，随调用销毁；for-in 降级专用，§11.9） | 6, 8 |
| BE | `MAP_ITER_STEP` | u8 mode | `cur → cell` 迭代推进/取件/关闭（H62，v0.16.1 重定义；mode：**0=推进→0/1**、1=键、2=值、**3=close**（出口发射、幂等）；坏游标/未推进取件 → 99（防御）；**迭代中修改同一 map → 23**） | 23, 99 |

#### B.11 0xB0–0xBF 时间运算 / 文本化 / 字符串切片替换 / 正则 / 字符串建 Regex（v0.4–v0.17，走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| B0 | `DT_ADD` | — | `dt dur → dt`（H34） | 11, 16 |
| B1 | `DT_SUB` | — | `dt dur → dt`（H35） | 11, 16 |
| B2 | `DUR_ADD` | — | `d1 d2 → d`（H36） | 12, 16 |
| B3 | `DUR_SUB` | — | `d1 d2 → d`（H37） | 12, 16 |
| B4 | `DUR_MUL` | — | `d i64 → d`（H38；Int64×Duration 由前端换序） | 12, 16 |
| B5 | `DUR_DIV` | — | `d i64 → d`（H39；i64=0 → 1） | 1, 12, 16 |
| B6 | `DUR_NEG` | — | `d → d`（H40） | 12, 16 |
| B7 | `TO_STR` | u8 t | 值 → 字符串（H33；t=静态类型标签，格式冻结于 §11.9；插值/混合加法共用） | 6, 8, 16 |
| B8 | `STR_SUB` | — | `h a b → h` 子串（H50；**码点索引**半开区间 `[a, b)`，与 `STR_AT` 同一索引域（§11.4）；`a<0 / b>码点数 / a>b` → 4，`a==b` → 空串；源语言 `s[a..=b]` 由前端折算为半开形式） | 4, 6, 8, 16 |
| B9 | `STR_REPLACE` | — | `h old new → h` 全部子串替换（H51；old 为空串 → 14） | 6, 8, 14, 16 |
| BA | `REGEX_IS_MATCH` | — | `h_re h_s → 0/1`（H52；h_re 为任意 Regex 句柄——常量/局部/构造结果） | 6, 8 |
| BB | `REGEX_FIND` | — | `h_re h_s → h` 首个匹配子串（H53；返回整个匹配 group-0 的新 String，无匹配 → 0；捕获组提取属 M2） | 6, 8, 16 |
| BC | `STR_REPEAT` | — | `h i64 → h` 字符串重复（H60，v0.15；n ≤ 0 → 空串；`n × len_utf8` 溢出 → 3；见 §11.9） | 3, 6, 8, 16 |
| BD | `DT_DIFF` | — | `dt1 dt2 → h` 日期差 `dt1 − dt2 → Duration`（H61，v0.15；可为负；差分溢出 Duration 值域 → 12；见 §11.9） | 6, 8, 12, 16 |
| BF | `STR_TO_REGEX` | — | `h_s → h_re` 字符串构造 Regex（H69，v0.17；非法/空 pattern → 14；分配型；见 §3.3） | 6, 8, 14, 16 |

### B.12 0xC0–0xFF 预留区

`0xC0–0xFF` 为 **M2 规划预留**（`HW_OPEN` 区块内批量分配、`CALL_HOST` 等）；**M1 发射即 `ERR_NOT_IMPL`**（§5、§7 校验 2/8）。M2 对 `0x79 CALL_HOST` 的启用与操作数重定义见 `design-m2.md` 附 B。

## 附 C 字节码 ↔ 机器码对照（JIT 后端 · x86_64 / AArch64）

**口径**：机器码**只加速、不改语义**（I7）——解释器与两个 JIT 后端对同一 `.fbc` 必须给出逐位一致的（结果、`errCode`、`site`）。本附 C 的对照表**同源摘录自规格 §12.4**（`§` 均为规格章节号；冲突以规格为准）。

**通用栈机映射（§12.4 约定）**：`push v` = `sub rsp,8; mov [rsp],v`（a64 `str v,[sp,#-8]!`）；`pop r` = `mov r,[rsp]; add rsp,8`（a64 `ldr r,[sp],#8`）；二元 `a b → r` 中 `b`@`[rsp]`、`a`@`[rsp+8]`，结果写回 `[rsp+8]` 后收栈；`locals[i]` = `[rbp-32-8i]`（a64 `[x29,#-40-8i]`——`-32` 留作 `CALL_CLOSURE` 的 fnId 暂存槽；实现口径，见 E.5）。

### C.1 后端抽象与 ABI 映射（§12.2）

| 抽象名 | x86_64（SysV） | AArch64（AAPCS64） | 角色 |
|---|---|---|---|
| `CTX` | `r15` | `x19` | **callee-saved**，全程持 ctx；helper 调用不失效 |
| `FP` | `rbp` | `x29` | 帧基址 |
| `SP` | `rsp` | `sp` | 操作数栈 + 局部槽 |
| `RETV` | `rax` | `x0` | 返回值 cell |
| `TMP` | `r10`、`r11` | `x9`、`x10` | 立即数/中间结果（caller-saved，**跨 helper 调用不可存活**） |
| helper 入参 | `rdi=ctx, rsi=&args, rdx=n` | `x0=ctx, x1=&args, x2=n` | §6 helper ABI 的抽象签名 `(ctx, &args, nargs)` |
| helper 返回 | `rax` | `x0` | cell |
| 返回地址 | `call` 压栈 | `x30`(lr) | a64 必须由 prologue 保存 `x29/x30` |

**对齐**：两平台栈均**16 字节对齐**，`frameSize` 按 16 取整、两后端共用同一计算式（§3.1、§12.2）。

### C.2 入口 / 出口序列（§12.3）

- **入口**：`endbr64` / `bti c`（"可用即发射"）→ 保存帧与 callee-saved `CTX` 寄存器 → `sub rsp/sp, FRAME` → 逐条展开「拷 args 进 locals + 内存卫生填充（`0` 填充不可观察）」（§4 prologue）。
- **thunk**：入口第一参数位置不同（`rdi` vs `x0`），**桥为每个后端各生成一个 5 行 thunk**，其后是同一份序言模式（§12.3）。
- **出口唯一**（`.epilogue`）：`RET`/`RET_VOID`/`BAIL` 全部 `jmp .epilogue`（`BAIL` 前置 `eax/x0 = 0` 哑值）；`errCode > 0` 的错误收敛另按 §9.16 做**单次转储**（两后端同规则）。
- **错误归因**：prologue 写 `ctx.fnId = 自身`；`CALL_FUNC` 返回后调用方**立即重写自身 fnId**（一条 mov，§4）。

### C.3 通用约定（§12.4）

**通用约定（全表共用）**：

- 栈机模型：`push v` = `sub rsp,8; mov [rsp],v`（a64 `str v,[sp,#-8]!`）；`pop r` = `mov r,[rsp]; add rsp,8`（a64 `ldr r,[sp],#8`）。二元 `a b → r`：`b`@`[rsp]`、`a`@`[rsp+8]`，结果写回 `[rsp+8]` 后 `add rsp,8`（a64：先弹 `b` 至 `x10`，结果写回 `[sp]`）。`locals[i]` = `[rbp-32-8i]`（a64 `[x29,#-40-8i]`——`-32` 留作 `CALL_CLOSURE` 的 fnId 暂存槽；实现口径，见 E.5）。`FRAME`/`nLocals`/`need` 均为编译期立即数。
- **失败收敛块**：`<bail:k>` = 写槽 k（`mov qword [r15],k`／`movz x11,k; str x11,[x19]`）→ `k>0` 时**单次转储序**（§9.16：`dbgBase≠0` 且首格 0 → 写 fnId/nLocals、拷贝 `locals[0..nLocals)`——按 nLocals 展开；首个收敛点获胜）→ `RETV=0` → `jmp/b .epilogue`；`<deopt>` = 写 `-1` → `RETV=0` → 跳 epilogue（**不转储**，§9.16）。
- `CHECK_ERR`：`cmp qword [r15],0; jne <最近 bail>`（a64 `ldr x11,[x19]; cbnz x11,<bail>`）。
- **NaN 规范化尾**（§11.3 的机器层兑现；`CANON=0x7FF8000000000000`）：x86 对一切可产 NaN 的浮点指令尾接 `ucomisd xmm0,xmm0; jnp .n; movabs rax,CANON; movq xmm0,rax; .n:`；a64 依赖 **FPCR.DN=1**（引擎初始化显式置位）天然产出 canonical NaN——**不尾接**（DN=0 的宿主必须补尾）。FMIN/FMAX 行内强制（见行）。
- 保留槽（08–0F、1D–1F、27–2F、3C–3F、4E–4F、6F、73、8A–8F、9F、A9–AA）与 0xC0–0xFF：不发射，出现即 `ERR_NOT_IMPL`（§7 校验 2）。

### C.4 分组对照表（§12.4）

**0x00–0x0F 控制 / 杂项**

| 字节码 | x86_64 | AArch64 | 备注 |
|---|---|---|---|
| `NOP` | `nop` | `nop` | |
| `TRAP` | `int3` | `brk #0` | 调试面（前端仅调试模式发射） |
| `BREAKPOINT` | `nop` | `nop` | 保留，发布版空操作 |
| `SET_SITE` | `mov qword [r15+8],imm32` | `movz/movk x11,imm32; str x11,[x19,#8]` | 仅在可能失败指令前发射（§7） |
| `CHECK_ERR` | 通用模板 | 同 | 自动尾随/显式 |
| `BAIL k` | `<bail:k>` 块 | 同 | 每函数 ≥1 块（§7） |
| `CHECK_ERR_NC` | 空（发布）/调试断言 | 同 | 发布版空操作 |
| `STACK_GUARD need` | `mov rax,rbp; sub rax,FRAME; sub rax,rsp; cmp rax,need; jb <deopt>` | `sub x11,x29,#FRAME; sub x11,x11,sp; cmp x11,#need; b.lo <deopt>` | 剩余栈 = `(rbp−FRAME)−rsp`（**帧内操作数栈余量**——防御：静态栈深恒满足；触发即上界低估，回解释器重跑，解释器余量亦不足 → 桥写 15） |

**0x10–0x1F 常量 / 栈**

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `PUSH_I8`/`PUSH_I32` | `push imm`（x86 自动符号扩展） | `mov x11,#imm; str x11,[sp,#-8]!` |
| `PUSH_I64` | `movabs rax,imm64; push rax`（或常量池） | `movz/movk ×4; str x11,[sp,#-8]!`（或文字池 `ldr`） |
| `PUSH_F64` | 同 I64（位模式原样；或 `movsd` 常量池） | 同 I64 |
| `PUSH_BOOL` | `push 0/1` | `mov x11,#0/1; str x11,[sp,#-8]!` |
| `PUSH_NULL` | `xor eax,eax; push rax` | `str xzr,[sp,#-8]!` |
| `PUSH_KH n` | `mov rax,[<常量句柄镜像+8n>]; push rax` | 文字池载镜像基址 → `ldr x11,[…]; str x11,[sp,#-8]!` |
| `DUP` | `mov rax,[rsp]; push rax` | `ldr x11,[sp]; str x11,[sp,#-8]!` |
| `DUP2` | `mov rax,[rsp]; mov rcx,[rsp+8]; push rcx; push rax` | `ldr x9,[sp]; ldr x10,[sp,#8]; stp x10,x9,[sp,#-16]!` |
| `POP` / `POP2` | `add rsp,8` / `add rsp,16` | `add sp,sp,#8` / `#16` |
| `SWAP` | `mov rax,[rsp]; mov rcx,[rsp+8]; mov [rsp],rcx; mov [rsp+8],rax` | `ldr x9,[sp]; ldr x10,[sp,#8]; str x10,[sp]; str x9,[sp,#8]` |
| `PICK n` | `mov rax,[rsp+8n]; push rax` | `ldr x11,[sp,#8n]; str x11,[sp,#-8]!` |

**常量句柄镜像（v0.18.33 明确）**：桥在装载后把该单元 k 个常量句柄（路径 A）写成**连续 8 字节数组**（非托管、单元生命周期）——`PUSH_KH n` 的机器码在 JIT 编译期把镜像基址**烘焙为立即数**；镜像与 `JitFunction`/编译缓存条目同生命周期（单元卸载一并回收，§8.7）。

**0x20–0x2F 局部变量**

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `LOADL i` / `LOADL0–3` | `mov rax,[rbp-32-8i]; push rax` | `ldr x11,[x29,#-40-8i]; str x11,[sp,#-8]!` |
| `STOREL i` | `pop rax; mov [rbp-32-8i],rax` | `ldr x11,[sp],#8; str x11,[x29,#-40-8i]` |
| `LOAD_CAP idx` | `CALL_HELPER H56`（argc=2——句柄+idx） | 同 |

**0x30–0x3F 整型算术**

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `IADD`/`ISUB` | `mov rax,[rsp+8]; add/sub rax,[rsp]; jo <bail:3>; mov [rsp+8],rax; add rsp,8` | `ldr x10,[sp],#8; ldr x9,[sp]; adds/subs x9,x9,x10; b.vs <bail:3>; str x9,[sp]` |
| `IMUL` | `mov rax,[rsp+8]; imul rax,[rsp]; jo <bail:3>; …写回` | `ldr x10,[sp],#8; ldr x9,[sp]; smulh x11,x9,x10; mul x9,x9,x10; cmp x11,x9,asr #63; b.ne <bail:3>; str x9,[sp]` |
| `IDIV` | 除数判定 `test r10,r10; jz <bail:1>`；`INT64_MIN/-1 → <bail:3>`；`cqo; idiv`（商写回） | `cbz x10,<bail:1>`；INT64_MIN 与 −1 预判 `→ <bail:3>`；`sdiv`（a64 不陷入——**必须预判**） |
| `IMOD` | 除数判定（÷0 →`<bail:2>`）；除数为 −1 → 直接 0（硬件 `idiv` 对 `INT64_MIN/-1` 会 `#DE`；数学余数恒 0，**不报溢出**）；否则 `cqo; idiv` 取 `rdx` | `cbz x10,<bail:2>`；`sdiv`+`msub` 天然正确（含 `INT64_MIN/-1` → 0） |
| `INEG` | `mov rax,[rsp]; neg rax; jo <bail:3>; mov [rsp],rax` | `ldr x9,[sp]; negs x9,x9; b.vs <bail:3>; str x9,[sp]` |
| `IABS` | `pop rax; test rax,rax; jns .ok; neg rax; jo <bail:3>; .ok: push rax` | `ldr x9,[sp],#8; cmp x9,#0; b.ge .ok; negs x9,x9; b.vs <bail:3>; .ok: str x9,[sp,#-8]!` |
| `IMIN`/`IMAX` | `mov rcx,[rsp]; mov rax,[rsp+8]; add rsp,8; cmp rax,rcx; cmovge/cmovl rax,rcx; mov [rsp],rax` | `ldr x10,[sp],#8; ldr x9,[sp]; cmp x9,x10; csel x9,x9,x10,lt/gt; str x9,[sp]` |
| `IADD_WRAP` | 同 IADD（不发射 `jo`） | 同（不发射 `b.vs`） |
| `ICLZ` | `mov rcx,[rsp]; mov rax,64; test rcx,rcx; jz .st; bsr rax,rcx; xor rax,63; .st: mov [rsp],rax`（SSE2 基线无 `lzcnt`） | `ldr x9,[sp]; clz x9,x9; str x9,[sp]`（0 → 64 天然正确） |
| `IPOPCNT` | SWAR 序列（移位/掩码/`imul` 归并；掩码经 `movabs` 或常量池；SSE4.2 显式开启时 `popcnt`） | `ldr x9,[sp]; fmov d0,x9; cnt v0.8b,v0.8b; addv b0,v0.8b; umov w11,v0.b[0]; str x11,[sp]` |

**0x40–0x4F 浮点**（`xmm0/xmm1` ↔ `d0/d1`；NaN 尾按通用约定）

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `FADD`/`FMUL` | `movsd xmm0,[rsp]; addsd/mulsd xmm0,[rsp+8]; <NaN 尾>; movsd [rsp+8],xmm0; add rsp,8` | `ldr d0,[sp],#8; ldr d1,[sp]; fadd/fmul d0,d0,d1; str d0,[sp]` |
| `FSUB`/`FDIV` | `movsd xmm0,[rsp+8]; subsd/divsd xmm0,[rsp]; <NaN 尾>; …写回` | `ldr d1,[sp],#8; ldr d0,[sp]; fsub/fdiv d0,d0,d1; str d0,[sp]` |
| `FDIV_CHK` | 前置除数判定：`xorpd xmm1,xmm1; ucomisd 除数,xmm1（jp 继续；je <bail:1>）`；后接 FDIV | `ldr d1,[sp]; fcmp d1,#0.0; b.eq <bail:1>;` 后接 FDIV |
| `FNEG`/`FABS` | 符号域：`xorpd/andpd`（掩码 `0x8000…`/`0x7FFF…`，`movq` 装填或常量池）；`<NaN 尾>` | `fneg d0,d0` / `fabs d0,d0` |
| `FMIN`/`FMAX` | 先自检：任一操作数 NaN（`ucomisd x,x; jp`）→ 直接产 `CANON`；否则 `minsd/maxsd`（x86 的 NaN 取第二操作数语义已由前置分支规避） | `fmin/fmax d0,d1,d0`（FPCR.DN=1 → NaN 即 canonical） |
| `FSQRT` | `sqrtsd xmm0,[rsp]; <NaN 尾>; movsd [rsp],xmm0` | `ldr d0,[sp]; fsqrt d0,d0; str d0,[sp]` |
| `FFLOOR`/`FCEIL`/`FTRUNC`/`FROUND` | 基线（SSE2）软件序列：`cvttsd2si`（截断）+ `cvtsi2sd` 回装 + `ucomisd` 比较修正 ±1；`\|x\|≥2^63` 直通、NaN 走 `<NaN 尾>`；SSE4.1 显式开启时 `roundsd imm=1/2/3/0` | `frintm`/`frintp`/`frintz`/`frintn`（原生；含直通与 NaN 语义） |

**0x50–0x6F 比较 / 逻辑 / 位**

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `CMP_I` | `cmp` + `setg/setl` 组合 `sub` 出 -1/0/1 | `cmp x9,x10; cset x11,lt; cset x12,gt; sub x11,x12` |
| `EQ_I`–`GE_I` | `cmp` + `sete/ne/l/le/g/ge` + `movzx` | `cmp` + `cset eq/ne/lt/le/gt/ge` |
| `EQ_F`–`GE_F` | `cmpsd` 谓词：EQ=0、LT=1、LE=2、NE=4；GT/GE = **交换操作数**后 1/2（无序 → 0，§11.3）；结果取低位 `& 1` | `fcmp d0,d1; cset eq/ne/mi/ls/gt/ge`（无序语义同 §11.3——`gt/ge/mi/ls` 对 NaN 恒 false、`ne` 恒 true） |
| `CMP_F` | ——**汇编器禁发**（§11.3） | 同 |
| `NOT_B` | `xor qword [rsp],1` | `ldr x9,[x20]; eor x9,x9,#1; str x9,[x20]`（机器字由 `A64Emitter.eorImm1` 构造） |
| `AND_B`/`OR_B`/`XOR_B` | `mov rax,[rsp]; add rsp,8; and/or/xor [rsp],rax` | `ldr x10,[sp],#8; ldr x9,[sp]; and/orr/eor x9,x9,x10; str x9,[sp]` |
| `BAND_I`/`BOR_I`/`BXOR_I` | 同上 | 同上（`and/orr/eor`） |
| `BNOT_I` | `not qword [rsp]` | `ldr x9,[sp]; mvn x9,x9; str x9,[sp]` |
| `SHL_I`/`SHR_I`/`USHR_I` | `mov rcx,[rsp]; add rsp,8; shl/sar/shr qword [rsp],cl`（x86 自动掩码 63） | `ldr x10,[sp],#8; ldr x9,[sp]; lsl/asr/lsr x9,x9,x10; str x9,[sp]`（a64 自动取低 6 位——语义天然一致） |
| `EQ_H`/`NE_H` | 整数 `cmp` + `sete/setne`（句柄即整数；`== null` 亦此） | `cmp` + `cset eq/ne` |
| `CMP_STR`/`CMP_DEC`/`CMP_DT`/`CMP_DUR` | `CALL_HELPER` H09/H11/H13/H15 | 同 |

**0x70–0x7F 控制流与调用**

| 字节码 | x86_64 | AArch64 | 备注 |
|---|---|---|---|
| `JMP` | `jmp rel32` | `b` | 范围差异见下 |
| `JZ`/`JNZ` | `pop rax; test rax,rax; je/jne target` | `ldr x9,[sp],#8; cbz/cbnz x9,target` | |
| `LOOP_BACK` | `STACK_GUARD <回边 need>` + `call H22` + `jmp target` | 同（`bl H22`） | 安全点 + 栈防守（§7） |
| `CALL_HELPER`/`_NC`/`_V` | 模板（下） | 同 | 自动尾随 CHECK_ERR（_NC 除外） |
| `CALL_FUNC fid` | 模板（下） | 同 | 共窗口；返回后重写 fnId |
| `CALL_HOST` | ——M1 汇编期 `ERR_NOT_IMPL`；**M2 起 = `call H63` 转发器**（CALL_HELPER 同款） | 同 | §6 议题清单 |
| `HW_OPEN`/`HW_CLOSE` | ——M1 `ERR_NOT_IMPL`；**后档专项**（批量分配） | 同 | §7 校验 2/8 |
| `RET` | `mov rax,[rsp]; jmp .epilogue` | `ldr x0,[sp]; b .epilogue` | 唯一返回路径 |
| `RET_VOID`/`RET_NULL` | `xor eax,eax; jmp .epilogue` | `mov x0,#0; b .epilogue` | |
| `CALL_CLOSURE argc` | 模板（下） | 同 | §8.6 |

**0x80–0x8F 类型 / 转换 / 显式错误**

| 字节码 | x86_64 | AArch64 | 备注 |
|---|---|---|---|
| `CAST tok mode` | `call H17; test eax,eax; jz .m;` 命中继续；`.m:` mode0 → `<bail:7>` / mode1 → `<deopt>` | `bl H17; cbz x0,.m;` 同 | 值型恒等/静态相容 = 空操作 |
| `TO_I64 mode` | `ucomisd` 自检 NaN（jp → 失败块）→ `cvttsd2si`；结果 = INT64_MIN 时与 `−2^63` 双精度比较区分（合法 −2^63 vs 越界哨兵）→ 否则 mode0 `<bail:13>` / mode1 `<deopt>` | **`fcvtzs` 饱和不代表错误**——须前置 `fcmp` 判 NaN 与 ±2^63 界外（界常量经 `movz` 装 double 位型）→ `fcvtzs` | |
| `TO_F64` | `cvtsi2sd xmm0,[rsp]; movsd [rsp],xmm0` | `ldr x9,[sp]; scvtf d0,x9; str d0,[sp]` | 可能丢精度、不报错 |
| `IS_TYPE` | `call H17`（0/1，**永不失败**） | 同 | null → false |
| `GUARD_TYPE mode` | mode0 → `call H19` + `CHECK_ERR`（失败 8）；mode1 → `call H17` + 分支 → `<deopt>` | 同 | |
| `THROW code` | `<bail:17>` 块（源语言码经站点附加表在桥侧解析） | 同 | |
| `ASSERT code` | `pop rax; test rax,rax; jnz .ok; <bail:code>; .ok:` | `ldr x9,[sp],#8; cbnz x9,.ok; <bail:code>; .ok:` | |
| `ABORT code` | 无条件 `<bail:code>` | 同 | |
| `GUARD_NNZ mode` | `mov rax,[rsp]; test rax,rax; jnz .ok;`（mode0 → `<bail:6>` / mode1 → `<deopt>`）；`.ok:` | `ldr x9,[sp]; cbnz x9,.ok;` 同 | |
| `TYPE_OF` | `call H18` + `CHECK_ERR` | 同 | 调试用 |

**分支可达范围差异（必须处理）**：

| 后端 | 条件分支范围 | 无条件分支范围 | 处理 |
|---|---|---|---|
| x86_64 | `jcc rel32` ≈ ±2 GB | `jmp rel32` ≈ ±2 GB | 通常无需 trampoline |
| aarch64 | `b.cond` ≈ **±1 MB** | `b` ≈ ±128 MB | 越界时插入跳板（trampoline）或跳板表 |

由于 aarch64 条件分支范围小，汇编器/后端需做**两遍布局**：先按短分支编码，越界则升级为"取反条件 + 无条件 `b`"跳板。此逻辑必须在两个后端共享的布局阶段实现，而非各自硬编码。

**0x90–0xBF：全量 `CALL_HELPER` 路由表**（模板见本区末；一律自动尾随 `CHECK_ERR`；"登记" = 分配型 +1 槽）

| 字节码 | helper | 登记 |
|---|---|---|
| `LEN` | H01/H03/H07（按静态类型分派 List/Map/String） | — |
| `GET_IDX` H02 · `GET_KEY` H04 · `GET_KEY_OR` H05 · `HAS_KEY` H06 · `STR_AT` H08 · `DT_FIELD` H14 · `DUR_TICKS` H16 · `DEC_IS_INT` H12 · `HANDLE_TAG` H18 · `RANGE_CONTAINS` H42 · `REGEX_IS_MATCH` H52 · `DEC_TO_I64` H30 | 见左 | 不登记 |
| `RANGE_NEW` H41 · `TO_DEC` H28/H29 · `DEC_TO_F64` H31 · `STR_CAT` H32 · `TO_STR` H33 · `DT_ADD` H34 · `DT_SUB` H35 · `DUR_ADD` H36 · `DUR_SUB` H37 · `DUR_MUL` H38 · `DUR_DIV` H39 · `DUR_NEG` H40 · `STR_SUB` H50 · `STR_REPLACE` H51 · `REGEX_FIND` H53 · `STR_REPEAT` H60 · `DT_DIFF` H61 · `STR_TO_REGEX` H69 · `MAKE_LIST` H70 · `MAKE_MAP` H71 | 见左 | **分配型**（+1 槽） |
| `LIST_APPEND` H43 · `MAP_PUT` H44 · `LIST_INSERT` H45 · `LIST_SET` H46 · `LIST_REMOVE` H47 · `MAP_REMOVE` H48 | 见左 | **变更型**（§9.15 全规则：常量禁写 20 / deopt 禁令 / 兜底） |
| `MAP_ITER_BEGIN` H49 · `MAP_ITER_STEP` H62 | — | 不登记（游标在宿主侧调用级迭代器表） |

### C.5 调用模板（§12.4）

**模板 A：`CALL_HELPER hid argc`**（`_V` 变体不回压结果；`_NC` 不尾随 `CHECK_ERR`）

- x86：`lea rsi,[rsp+8*(argc-1)]`（`args[0]` 最深——§6 ABI）；`mov rdi,r15; mov rdx,argc; call <helper 入口>`（固定 helper = 引擎符号；user helper = 注册期确定的 trampoline）；结果写回 `args[0]` 槽后收参：`mov [rsp+8*(argc-1)],rax; add rsp,8*(argc-1)`；自动尾随 `CHECK_ERR`。`argc=0` → `rsi` 可用 0。
- a64：`add x1,sp,#8*(argc-1); mov x0,x19; mov x2,#argc; bl <入口>; str x0,[sp,#8*(argc-1)]; add sp,sp,#8*(argc-1)`。

**模板 B：`CALL_FUNC fid argc`**（内部调用，共窗口）

- x86：`mov rdi,r15; lea rsi,[rsp+8*(argc-1)]; mov rdx,argc; call [<fnTable 基址+8*fid>]`（单元函数机器入口表——桥执行前填充，非 GC 内存）；返回后：`CHECK_ERR`（错误仅传播）、`mov qword [r15+40],<自身 fnId>`（重写归因，§4）、结果压栈、`add rsp,8*argc` 收参。
- a64：`add x1,sp,#8*(argc-1); mov x0,x19; mov x2,#argc; ldr x10,[<fnTable+8*fid>]; blr x10` 同构。

**模板 C：`CALL_CLOSURE argc`**（§8.6）

- 栈 `[闭包句柄, a1…a(argc)]`（句柄最深）；被调帧 `locals[0]`=句柄、`locals[1..]`=实参（同 §8.0 隐藏适配器帧约定）：
  1. `call H55`（句柄 → fnId；`rsi=&句柄槽, rdx=1`）→ **溢出保存**（TMP 跨 helper 调用不可存活）；
  2. `call H57`（→ fnTable 基址）；
  3. 间接调用 `call [fnTable + 8*fnId]`（x86 直接 `[r10+r11*8]` 寻址；a64 `add x10,x10,x11,lsl #3; blr x10`——各入口带 `endbr64`/`bti c`，IBT 安全，§12.3）；
  4. 返回后：`CHECK_ERR` + 结果压栈 + 收参（含句柄槽）；fnId 由前端烘焙并经 §7 校验 7 + `closure_new` 双重校验。

**通用注记**：各类机器码均无新增模式，I8 自动满足；分配型在宿主 helper 内分配并登记窗口槽（结果 = 新句柄 ID）；变更型的重放安全性由 §9.15② 的静态禁令保证。`hwCap` 初值取自宿主参数 `initialCapacity`（默认 128，§9.6），JIT 与解释器共用同一窗口机制。

**闭包值指令（v0.10，§8.6）**：`closure_new`（前端直接发射 CALL_HELPER H54——无独立 opcode）/`LOAD_CAP`（H56）与 helper 调用同款（+ 自动 `CHECK_ERR`）；`CALL_CLOSURE` 全序列见**模板 C**。含 `CALL_CLOSURE` 的函数按 §7 校验 11 标记 `flags.bit0`（黑盒，deopt 禁令）。

### C.6 与解释器的关系（I7）

- **解释器**（`Interp.run`，design §5.3.6）逐指令执行**同一** `.fbc` 字节码，是**语义基准**；两个 JIT 后端由本附 C 的对照表发射机器码，**唯一可观察差异是性能**。
- **差分测试**（规格 §13.2 T2）断言 `interp(args) == jit_x86_64(args) == jit_aarch64(args)`：结果、`errCode`、`site` 三者全等——I7 的可测定义。
- 分配型/变更型语义（窗口登记、§9.15 规则、`frozen`）全在 **helper 内**实现，机器码侧无新增模式（I8 自动满足）。

---

### D. M1 实现扩展：源语言 DateTime / Duration 构造（2026-10-18）

原规格 §11.9 只定义时间算术；为使**被编译的 lambda 源码**能自行构造时间值，实现增加以下形式（不改 `.fbc` 格式，仅新增固定 helper 槽与复用常量表）：

| 源形式 | 降低 | 说明 |
|---|---|---|
| `DateTime.now()` | `CALL_HELPER 73, 0` | 宿主当前时间（`DateTime.now()`，本地时区） |
| `DateTime.parse(s)` | `CALL_HELPER 74, 1` | RFC3339 `date-time`；非法 → 14 |
| `DateTime.of(y, m, d[, h, mi, s[, ns]])` | `CALL_HELPER 75, argc` | 3–7 个整数位置参数；缺省段为 0；非法日期 → 14 |
| `Duration.<unit>` | `PUSH_KH addDuration(nanos)` | `Zero` / `nanosecond` / `microsecond` / `millisecond` / `second` / `minute` / `hour` / `day` |
| `Duration.parse(s)` | `CALL_HELPER 76, 1` | 与 `fountain::f_data` 的 `Duration.parse` 同形；非法 → 14 |

- 解析器为此新增 `.` 成员后缀（仅识别 `Ident`），降低阶段只放行上述 `DateTime.*` / `Duration.*` 组合；其余成员访问仍报 `NotImpl`（M2）。
- `DefiniteAssignment` 把 `DateTime` / `Duration` 视为内建命名空间，不作为局部变量读取。
- 与宿主侧构造（`HandleTable.pin` 传参）等价；两者在解释器路径结果一致。

---

### E. 实施偏差与修正记录（2026-10-18，`opsx:apply` S6.12/S7）

以下四处是**实现缺陷修正**而非设计变更；共同点是「字节码/规格口径与实现不一致」，修正后以规格为准。

1. **`TO_STR` 的 `t` 是 §6 文本化标签，不是 `LocalType`**
   - 规格：`0=I64 1=F64 2=Bool 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex`；
   - `LocalType` 的 3 是 Unit、4 才是 String，原实现直接透传，导致 String 被当 Decimal、Decimal 被当 DateTime；
   - 修正：`Lowerer.toStrTag` 做一次性映射；非标签类型（Unit/List/Map/Closure）编译期 `TYPE_MISMATCH`（§9 附则 13）。

2. **JIT 帧多留一格「转瞬实参槽」**
   - 模板 A 需要把标签/立即数压到操作数栈顶再调 helper，峰值比字节码 `maxStack` 多一格；
   - 原 `FRAME` 恰好用满，该格落在 `sp` 之下，被 helper 自己的栈帧覆盖（实测插值串 `TO_STR` 标签读回垃圾 ⇒ 14）；
   - 修正：`A64Compiler.frameSize` / `BackendX86_64.frameSize` 各加 8 B 再 16 对齐（`40`/`32` 基址不变）。
   - **该偏差只影响 JIT 帧大小**，不改 `.fbc` 的 `maxStack` 字段与解释器帧。

3. **`JMP/JZ/JNZ/LOOP_BACK` 的 `rel32` 是有符号偏移**
   - 原 AArch64 lowering 按 `u32` 读，回边（负偏移）被解释成巨大正偏移 ⇒ 重定位越界、函数降级解释器（`while`/`for-in` 首当其冲）；
   - 修正：按 `i32` 读，目标 = 下一条指令 + offset（与 `InsnDecoder.rel32` 同口径）。

4. **函数返回类型以降低结果为准**
   - `staticTypeOfTop` 只认识字面量/比较，`"ab" * 3`、`1 + 0.5`、`dt1 - dt2` 都被预判成 Int64；
   - 修正：`lowerLambda` 取 `lowerExprAs` 的实际返回类型写入 `FuncEntry.retType`，闭包表同法覆盖登记。
   - 影响宿主 Marshal/解包与差分文本化；`1 + 0.5` 现在正确标为 Decimal。

5. **AArch64 `locals` 基址 = `[x29, #-40]`（x86 仍为 `[rbp, #-32]`）**
   - 规格 §12.4 写的是 `[x29,#-32-8i]`；实现把 `-32` 留作 `CALL_CLOSURE` 的 fnId 暂存槽
     （跨 H55/H57 两个 helper 调用存活，不能放寄存器），`locals[0]` 顺移到 `-40`；
   - 该偏移只影响 AArch64 机器层；解释器与 `.fbc` 均不感知。附 C 的对照表已按实现更新。

6. **转储首格编码 `fnId + 1`（0 保留为「未填」哨兵）**
   - 规格 §9.16 写「首格为 0（未填）→ 写 `[dbgBase]=fnId`」；但入口函数号合法值就是 **0**，
     直接写 fnId 会让 `fnId=0` 的失败帧被当成「未填」，报告丢失变量清单（T50 实测）；
   - 修正：首格写 `fnId+1`，0 专用于哨兵；报告侧读回首格减 1。缓冲区大小 / `[1]=nLocals` /
     locals 起始位置均不变，解释器与机器码共用同一编码。

7. **机器码转储入口不构造 `JitContext` 托管对象**
   - AArch64 BAIL 块经新增 `@C func jit_dump(dump, errCode, fnId, nLocals, locals)` 回到
     `DbgDump.writeOnceStackRaw`；机器码从 ctx 直接读 `dbgBase`（off 56）与 `errCode`（off 0）传参；
   - 原因：在 C2N 边界上调用 `JitContext.wrap`（托管对象分配）会触发无法 root 的引用，
     实测段错误；纯原生入参路径无托管对象，解释器路径仍走 `writeOnce(JitContext, …)`；
   - 两份实现共用同一套「哨兵编码 → fnId/nLocals → locals」约定与同一个报告组装器，
     解释器与 JIT 的报告文本因此逐位一致。

**新增源语言能力**：`regexStr.regex()`（v0.17 规格已定义、前端此前缺失）→ `CALL_HELPER 69, 1`，返回 Regex、非法/空 pattern 运行期 14（T46）。

**仍待补齐（不属本次修正）**：x86_64 的整单元 lowering（P5.8）。`BackendX86_64.compile` 保持「降级解释器」，因为现有 x86 片段内多处 `rel32` 仍是 P5.8 回填占位（`emitCast`/`emitAssert`/浮点收尾等），在缺少 x86_64 原生证据时不应假装可执行。
