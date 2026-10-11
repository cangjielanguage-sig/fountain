# f_jit 详细设计 · M1（字节码 · 解释器 · JIT 后端 · 桥）

> 依据：`jit-bytecode-m1.md` v0.18.35（同目录）。
> 本文把 M1 规格落到 `f_jit` 模块的**包级 / 顶级声明 / 公共成员**三级设计；M2、M3 增量见 `design-m2.md`、`design-m3.md`。
> 粒度约定：
> - 包 = `fountain::f_jit` 模块下的一个 Cangjie 包；
> - 顶级声明 = 包内顶层声明（class / interface / struct / enum / const / let / func）；
> - 公共成员 = 该声明的 public / protected 成员（字段、属性、构造函数、函数、静态成员、枚举构造器、常量）；
> - 签名以**草图**给出（个别类型随后续设计微调），语义以规格文档为准，每条附规格锚点。
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
| 编译器门面 | `Compiler` 实例（class） | 一个实例 = 一个编译上下文（配置 + 注册表 + 缓存视图，§8.4 快照语义） |
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
| `fountain::f_jit.base` | 共享契约：类型编码、错误码、公共值类型与异常、诊断接口 | 无（叶子包） | std.core、std.time | §3.2、§8、§9.16 |
| `fountain::f_jit.bytecode` | 字节码静态模型与 `.fbc` 编解码/加载校验 | base | std.collection、std.math.numeric、std.time、std.regex、f_regex（Regex 常量构造链） | §10、§11、§13.3 |
| `fountain::f_jit.compiler` | 源入口前端与汇编（源码 → `.fbc`），编译期诊断 | base、bytecode | std.core、f_regex（String.regex 扩展的静态检查） | §8.0、§8.5、§8.8、§11.7、§11.9 |
| `fountain::f_jit.runtime` | ctx/句柄表/迭代器表/helper 集/诊断转储/解释器 | base、bytecode | std.collection、std.math.numeric、std.time、std.regex | §1、§4、§6、§9.6、§9.16、§12.6 |
| `fountain::f_jit.backend` | JIT 后端（x86_64 / AArch64）与代码内存 | base、bytecode | std.core、std.env（OS/Arch 判定经 f_base） | §12 |
| `fountain::f_jit` | 用户 API 与桥：Compile 门面、JitFunction、Marshal、去重、卸载 | base、bytecode、compiler、runtime、backend | f_base（OS/Arch）、f_log（可选诊断） | §8、§8.1–§8.7 |

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
| `JitException` | class <: Exception | 运行期错误载体（错误码 + site + 报告文本） | SourcePos、ErrCode | §2、§8 |
| `SourceCompileException` | class <: Exception | 编译期错误载体（不占运行期错误码） | DiagKind | §8.4、§9.16 |
| `SourcePos` | struct | 源位置（站点表条目值） | — | §9.16 |
| `CallContext` | struct | 桥侧调用参数（含 strictFp/deadline/literalCopy） | — | §8 |
| `SourceUnit` | struct | 分发入口输入（`.fbc` 字节 + 入口函数号） | — | §8、§11.6 |
| `JitMode` | enum | 引擎选择开关 | — | §12.1 |
| `Engine` | enum | 实际引擎（解释器/JIT） | — | §12.1 |
| `JitValue` | enum | 桥内部执行结果（invoke 路径） | — | §8 |
| `JitContext`（类型契约） | 见 runtime | ctx 的规范布局以常量/访问器暴露 | — | §1 |
| `DiagnosticsSink` | interface | 降级/告警接收器 | DiagnosticLevel | §8.4、§12.1 |
| `DiagnosticLevel` | enum | 诊断级别 | — | §12.1（规格从略处细化） |
| `LocalType` | class（常量命名空间） | LocalType 编码 0–12（M1） | — | §11.7 |
| `TypeToken` | class（常量命名空间） | 句柄类型 token 1–9（M1） | LocalType | §6 |
| `ErrCode` | class（常量命名空间） | 错误码 0/±/1–20/23/99 与描述 | — | §2 |
| `Version` | class（常量命名空间） | 本模块实现的字节码版本（verMajor=1、verMinor=14） | — | §11.6 |

### 2.3 各声明的公共成员

#### 2.3.1 `JitException`

| 成员（草图） | 意义 | 调用关系 |
|---|---|---|
| `init(code: Int64, site: Int64, fnId: Int64, sourcePos: ?SourcePos, message: String, cause: ?String = None)` | 由桥在报告组装完成后构造 | 被根包 `Report.throwJit` 调用 |
| `let code: Int64` | §2 错误码 | 宿主处置分派；T6/T15 断言 |
| `let site: Int64` | code 段绝对字节偏移；-1 未知 | 与 sourcePos 互证（§9.16） |
| `let fnId: Int64` | 出错函数 id | 深帧归因（最深失败帧获胜） |
| `let sourcePos: ?SourcePos` | 站点表查得的源位置；不可得 → None | 报告文本；分发入口无文本路径 |
| `let message: String` | 按 code + site 静态表组装 + 源码行与变量（名/值/类型）报告 | 三类异常文本（① 无行号 ② 有行号 ③ 完整报告） |
| `let cause: ?String` | code=99 时 helper 原始描述（M2 起 21 含完整仓颉栈） | 诊断打印 |

#### 2.3.2 `SourceCompileException`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(kind: String, position: Int64, line: Int64, column: Int64, lineText: String, hint: String)` | 编译期失败统一抛出类型 | 前端/汇编各检查点抛 |
| `let kind: String` | 错误分类（`DiagKind` 常量：UnregisteredFunction / UndefinedIdentifier / BadParameterList / MissingArrow / DuplicateRegistration / NotImpl / UnterminatedComment / MultilineHeadContent / UnterminatedMultilineString / UnterminatedRawString …） | 测试断言 kind；消息含名字/位置/已注册清单（§8.4 需求 4） |
| `let position: Int64` | 源码字节位置 | 定位 |
| `let line: Int64` / `let column: Int64` | 行/列（1 起，列按 Unicode 码点） | 报告 |
| `let lineText: String` | 错误所在源码行原文（不含换行） | 「错误信息包含源码行文本」的兑现 |
| `let hint: String` | 修复提示（含已注册函数清单） | 用户可读性（T50） |

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
| `var literalCopy: Bool = false` | M2：字面量深拷贝开关 | M2 消费 |
| `var strictFp: Bool = false` | bit0 → ctx.flags（FDIV_CHK 语义） | `invoke(ctx)` 写 flags |
| `var deadline: ?DateTime` | 配合 `interrupt_poll`（-2 取消） | LOOP_BACK 安全点查询 |

#### 2.3.5 `SourceUnit`（struct）

| 成员 | 意义 |
|---|---|
| `let raw: Array<UInt8>` | 已加载 `.fbc` 容器字节（v0.18.25 起四段：code/const/site/name；§8.2 注释里的「三段」为旧版遗留，以 §11.6 为准） |
| `let entryFn: UInt32` | 期望入口函数 id（须与容器头 `entryFn` 一致，否则加载期拒绝） |

#### 2.3.6 `JitMode`（enum） / `Engine`（enum） / `JitValue`（enum）

| 类型 | 构造器 | 意义 |
|---|---|---|
| `JitMode` | `Off | Auto | Force` | 引擎选择开关；非 Linux / SDK 未支持指令集一律静默降级解释器（§12.1） |
| `Engine` | `Interp | Jit` | 实际引擎（diagnostics 记录；测试可断言） |
| `JitValue` | `Int(Int64) | Float(Float64) | Handle(Int64) | Unit` | 桥内部 `invoke` 结果；`Handle`=已按 §8.1 逃逸的句柄 ID |

#### 2.3.7 `DiagnosticsSink`（interface） / `DiagnosticLevel`（enum）

| 成员 | 意义 |
|---|---|
| `func diag(level: DiagnosticLevel, message: String): Unit` | 降级/告警接收（Auto 降级、后端不可用、注册跳过等） |
| `DiagnosticLevel` | `Info | Warn | Error`（规格「接口从略」处的细化） |

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
| `CAT_*`（12 个） | const | opcode 类别码 | — | §10.3 |
| `OpInfo` | struct | 单条 opcode 元信息（code/name/fmt/len/cat） | — | §10.2–10.3 |
| `OPCODE_TABLE` | let Array\<OpInfo\>（256 项） | 全量 opcode 表（反汇编/汇编校验/调试器共用） | OpInfo、CAT_* | §10.3 |
| `ByteReader` / `ByteWriter` | class | 显式 LE 编解码原语（禁 memcpy） | — | §11.2 |
| `DecodedInsn` / `InsnDecoder` | struct / class | 单指令解码（按 fmt/len）与操作数读取 | OpInfo、ByteReader | §10.2、§11.2 |
| `FuncEntry` | struct | 函数目录条目（26 B） | — | §11.7 |
| `FuncFlags` | class（常量） | `MUTATION = bit0`（含变更型调用） | — | §9.15、§11.7 |
| `FuncDir` | class | 函数目录（增/查/校验） | FuncEntry | §11.7 |
| `LocalTypes` | class | 每函数局部类型表（每槽 1 B） | LocalType | §11.7 |
| `ConstKind` | class（常量） | 常量 kind 1–10（M1） | — | §11.5 |
| `ConstPayload` | enum | 常量载荷（与 kind 一一对应） | — | §11.5 |
| `ConstRegistry` | class | 常量表：拼装期注册 + 加载期实例化 + freeze | ConstPayload | §3.3、§6、§11.5 |
| `SiteEntry` / `SiteTable` | struct / class | 站点表（off→line/column；升序唯一） | SourcePos | §11.6、§9.16 |
| `NameEntry` / `NameTable` | struct / class | 变量名表（稀疏，仅源码级命名槽） | — | §11.6 |
| `FbcFlags` | class（常量） | bit0 UTF-8 / bit1 NEED_JIT（恒 0）/ bit2 值运算类 | — | §11.6 |
| `FbcHeader` | struct | 容器头（40 B payload 起点；旧布局分支） | Version | §11.6 |
| `FbcWriter` | class | 组装容器（含 crc32 计算） | FbcHeader、各表 | §11.6 |
| `FbcReader` | class | 加载校验 + verMajor/verMinor 分派 + 段解析 | 各表、ConstRegistry | §11.6、§11.7、§13.3 |
| `LoadedUnit` | class | 加载产物（header/code/consts/site/name/dir/localTypes） | 各表 | §11.6–11.7 |

### 3.3 各声明的公共成员

#### 3.3.1 `OpInfo`（struct） / `CAT_*` / `OPCODE_TABLE`

| 成员 | 意义 |
|---|---|
| `let code: UInt8` / `let name: String` / `let fmt: String` / `let len: Int64` / `let cat: UInt8` | 元信息五元组（len 平台无关） |
| `const init(code, name, fmt, len, cat)` | 表项构造 |
| `CAT_MISC/CONST/LOCAL/I64/F64/CMP/CTRL/CALL/TYPE/BOX/FORBID/RSVD`（0–11） | 类别码 |
| `let OPCODE_TABLE: Array<OpInfo>` | 256 项全量（未分配槽 = OP_RSVD；0xA9–AA = CAT_FORBID；0xC0–FF = RSVD 预留 M2） |

#### 3.3.2 `ByteReader` / `ByteWriter`

| 成员 | 意义 |
|---|---|
| `init(data: Array<UInt8>, off: Int64 = 0)` / `init()` | 读游标 / 写缓冲 |
| `func u8(): UInt8` / `u16(): UInt16` / `u32(): UInt32` / `i32(): Int32` / `i64(): Int64` / `f64bits(): UInt64` | 显式小端解码（跨端序主机一致） |
| `func bytes(n: Int64): Array<UInt8>` / `func remaining(): Int64` | 段读取/长度 |
| `func wU8(v: UInt8)` / `wU16` / `wU32` / `wI32` / `wI64` / `wBytes(Array<UInt8>)` | 显式小端写出 |
| `func take(): Array<UInt8>` | 取出产物 |

#### 3.3.3 `InsnDecoder`（class） / `DecodedInsn`（struct）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `static func decode(code: Array<UInt8>, off: Int64): DecodedInsn` | 按 OPCODE_TABLE 解出 op 与操作数 | 解释器取指、汇编校验、反汇编 |
| `DecodedInsn.op: UInt8` / `.size: Int64` / `.operands: Array<UInt8>` | 解码产物 | — |
| `static func u16(insn, i)` / `i32` / `i64` / `rel32(insn, insnOff)` | 操作数读取（rel32 相对下一条指令） | §5 编码约定 |

#### 3.3.4 `FuncEntry`（struct） / `FuncFlags` / `FuncDir`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `let fnId/codeOff/codeLen/localTypesOff: UInt32`、`let nargs/nLocals/maxStack/retType/flags: UInt16` | 目录字段（恒 26 B） | 加载校验；`CALL_FUNC` 解析；帧计算 |
| `static const SIZE: Int64 = 26` | 定长 | 编解码 |
| `FuncFlags.MUTATION: UInt16 = 1` | 含变更型调用（H43–H48 / user helper / CALL_CLOSURE）→ deopt 禁令 + 防御兜底依据 | §9.15、§7 校验 11 |
| `FuncDir.add(e: FuncEntry)` / `get(fnId: UInt32): FuncEntry` / `find(fnId): ?FuncEntry` / `size: Int64` | 目录维护与解析 | 汇编器建目录；`CALL_FUNC` 校验（§7 校验 7） |
| `FuncDir.validate(codeLen: UInt32, entryFn: UInt32)` | 加载期校验（off/len 落在 code 段、entryFn 命中） | `FbcReader` |

#### 3.3.5 `LocalTypes`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(nLocals: Int64)` | 申请 nLocals 槽 | 汇编器/加载器 |
| `get(slot: Int64): UInt8` / `set(slot: Int64, t: UInt8)` | 槽类型读写（载荷=LocalType 码） | 前端写；解释器/转储/报告读 |
| `size: Int64` | 槽数（= FuncEntry.nLocals） | 校验 |
| `validate(dir: FuncDir, fnId: UInt32)` | 长度恰为 nLocals、类型值合法（加载器拒绝 13–255） | `FbcReader` |
| `isHandleSlot(slot: Int64): Bool` | 空安全/写保护共用判定 | 前端明确赋值、PUSH_NULL 校验 |

#### 3.3.6 `ConstKind` / `ConstPayload` / `ConstRegistry`

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

#### 3.3.7 `SiteTable` / `NameTable`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `SiteEntry.off/line/column: UInt32`（恒 12 B） | 站点条目 | 序列化 |
| `SiteTable.add(off: UInt32, pos: SourcePos)` / `freeze()` / `lookup(site: Int64): ?SourcePos` | 维护与查询（取 off ≤ site 的最大条目） | 前端写；桥报告读；加载器校验覆盖/升序 |
| `NameEntry.fnId/slot/strOff/strLen: UInt32`（恒 16 B） | 名字条目 | 序列化 |
| `NameTable.add(fnId: UInt32, slot: UInt32, name: String)` / `freeze()` / `lookup(fnId: UInt32, slot: UInt32): ?String` | 稀疏名字查询（未命中 → 报告省略名字） | 前端登记源码级命名槽；桥报告读 |
| `validate(dir, types)` | 键命中目录、slot < nLocals、升序唯一、UTF-8、`strLen ≥ 1`、范围合法 | `FbcReader` |

#### 3.3.8 `FbcHeader` / `FbcWriter` / `FbcReader` / `LoadedUnit`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `FbcHeader.magic/verMajor/verMinor/flags/hdrSize/codeLen/constLen/siteLen/entryFn/nameLen/crc32` | 容器头字段（偏移 0/4/6/8/12/16/20/24/28/32/36） | 读写 |
| `FbcHeader.read(r: ByteReader): FbcHeader` / `write(w: ByteWriter)` | 编解码（含 verMinor ≤13 旧布局分支：无 nameLen、payload=36、hdrSize=32） | 加载/写出 |
| `FbcWriter` 设置器系列：`setEntryFn(fnId)` / `setCode(bytes)` / `setConst(bytes)` / `setSite(bytes)` / `setName(bytes)` / `setFlags(flags)` / `build(): Array<UInt8>` | 组装容器（crc32 覆盖 code+const+site+name） | 汇编器产出 |
| `FbcReader.load(raw: Array<UInt8>): LoadedUnit` | 加载校验全流程（magic/版本分派/未知 flags 拒绝/段长/nameLen 布局/常量 DAG 环检测与载荷合法性/kind10 Regex 实例化/kind 3–9 实例化/FuncDir/LocalTypes/site 覆盖与升序/name 键合法/crc32） | 根包 `compile(unit)`、测试 T1/T50 |
| `FbcReader.supportedMajor` / `minVerMinorOf(major)` | 兼容矩阵（M1 加载器仅接受 verMajor 1；M2/M3 加载器按 major 分派规则集） | 版本演进（§13.3） |
| `LoadedUnit.header: FbcHeader` / `.code: Array<UInt8>` / `.consts: ConstRegistry` / `.site: SiteTable` / `.name: NameTable` / `.dir: FuncDir` / `.types: Array<LocalTypes>` | 加载产物 | runtime/backend/桥共用 |

---

## §4 包 `fountain::f_jit.compiler`

### 4.1 包意义

源入口前端（§8.0 lambda 源格式）与汇编：**词法 → 语法 → 名字解析 → 明确赋值分析 → 降低（含规范控制流模式）→ 字节码构建 → 汇编期校验（§7 校验 1–11）→ `.fbc` 组装**。产出 `SourceCompileException`（编译期）而非运行期错误。

### 4.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `TokenKind` / `Token` | enum / struct | 词法单元 | — | §8.0、§8.5、§8.8 |
| `Lexer` | class | 词法分析（三形态字符串、嵌套注释、正则字面量、词法保护顺序） | Token | §8.5、§8.8 |
| `AstExpr` / `AstStmt` / `LambdaAst` | enum / enum / class | 语法树 | Token | §8.0 |
| `Parser` | class | lambda 源入口语法 | Ast* | §8.0 |
| `NameResolver` | class | 调用点解析（recursive → user helper → 未注册错误） | Token、注册表快照 | §8.4 |
| `DefiniteAssignment` | class | 明确赋值与空安全数据流（回边不动点） | Ast*、LocalTypes | §7 校验 10、§5 |
| `Lowerer` | class | AST → 字节码（全部规范降低模式） | BytecodeBuilder、ConstRegistry、NameResolver | §5、§8.5–8.6、§11.9 |
| `BytecodeBuilder` | class | 单函数发射器（label/fixup、site 记录、自动 CHECK_ERR） | ByteWriter、OpInfo | §7、§5 |
| `Assembler` | class | 汇编期校验 1–11 + 组装 `.fbc`（目录/类型表/site/name） | BytecodeBuilder、各表、FbcWriter | §7、§11.6–11.7 |
| `SourceCompiler` | class | 管线编排：compile(source) → 单元产物（或抛 SourceCompileException） | Lexer→Parser→…→Assembler | §8、§8.4 |
| `DiagKind` | class（常量） | 编译期错误分类常量 | — | §8.4、§8.8、§9.16 |

### 4.3 各声明的公共成员

#### 4.3.1 `Lexer`（class）与 `Token`/`TokenKind`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(source: String, diagnostics: DiagnosticsSink)` | 绑定源码与诊断 | `SourceCompiler` |
| `func next(): Token` | 取下一 token（EOF 终止） | `Parser` |
| `func position(): Int64` / `line(): Int64` / `column(): Int64` | 当前位置（诊断用） | `Parser`/错误构造 |
| `Token.kind: TokenKind` / `.text: String` / `.pos: Int64` / `.line: Int64` / `.column: Int64` | 词法单元 | 全前端 |
| `TokenKind` 关键构造器 | `Ident / IntLit / DecLit / F64Lit / StrLit(三形态归一) / RegexLit / Char? / KwRecursive / KwLet / KwVar / KwIf / KwElse / KwWhile / KwFor / KwIn / KwWhere / KwBreak / KwContinue / KwReturn / KwTrue / KwFalse / KwNull / Punct(…) / Operator(…) / EOF` 等 | 解析 |
| 词法职责（实现约束） | ① 字符串保护（三形态全跨度）→ ② 注释剥离（`/* */` 嵌套配平）→ ③ 解析；换行规范化 CRLF/CR→LF；`>|` 锚定（多行串） | §8.5 冻结顺序、§8.8 |

#### 4.3.2 `AstExpr` / `AstStmt` / `LambdaAst`

| 成员 | 意义 |
|---|---|
| `LambdaAst.params: Array<ParamAst>`（name + 类型注解 + 槽位）、`body: Array<AstStmt>`、`retExpr: ?AstExpr` | 源入口顶层 lambda（隐式返回 = 尾表达式） |
| `AstExpr` 构造器（设计归并） | `Lit(常量或字面值形状) / Var(name) / Binary(op,l,r) / Unary(op,x) / IfExpr(c,t,e) / Call(target,args) / Closure(lambda) / IIFE(closure,args) / Interp(parts) / StrAdd(l,r) / RegexOp(kind,re,s,r?,n?,m?) / RangeLit(start,end,step?,isClosed) / ListLit(elems, isEmpty) / MapLit(pairs, isEmpty) / TupleLit(elems) / RecursiveValue / MemberName?（M2 糖预留）` |
| `AstStmt` 构造器 | `Decl(name, type?, init) / Assign(lhs, rhs) / MultiAssign(lhs[], rhs[]) / If(stmt 用法) / While(c,t) / ForIn(pattern, iterable, where?, body) / Return(e?) / ExprStmt(e) / Block(stmts)` |

#### 4.3.3 `NameResolver`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(snapshot: PredefinedSnapshot)` | 持注册表快照（快照语义 §8.4） | `SourceCompiler` |
| `func resolve(name: String, pos: Token): ResolvedCall` | 顺序：`recursive` → 注册表（user helper）→ 未命中 `SourceCompileException(UnregisteredFunction)`；非调用未定义标识符 → `UndefinedIdentifier` | `Lowerer` |
| `ResolvedCall` = `Recursive | UserHelper(slot: UInt16)` | 解析结果 | `Lowerer` 发射 `CALL_HELPER`（hid = slot + 0x0100） |

#### 4.3.4 `DefiniteAssignment`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func analyze(lambda: LambdaAst, types: LocalTypes): Boolean` | 数据流不动点：非参数局部在所有可达路径先写后读；循环出口不视为已赋值；`PUSH_NULL` 不得直存句柄型槽 | `SourceCompiler`（违规 → 编译错误）；T13 |

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

#### 4.3.8 `SourceCompiler`（class）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(opts: CompileOptions, registry: PredefinedSnapshot, diagnostics: DiagnosticsSink)` | 会话绑定（配置 + 注册表快照） | 根包 `Compiler.compile(source)` |
| `func compile(source: String): CompiledSourceUnit` | 全管线：lex→parse→resolve→DA→lower→assemble→（build FbcWriter 字节） | 根包管线第 1 步 |
| `CompiledSourceUnit`（产物） | `.fbc 字节 + funcCount + entryFn + 单元指纹（源码指纹）` | 加载校验与缓存键 |
| `DiagKind` 常量清单 | `UnregisteredFunction / UndefinedIdentifier / BadParameterList / MissingArrow / DuplicateRegistration / NotImpl / UnterminatedComment / MultilineHeadContent / UnterminatedMultilineString / UnterminatedRawString / …` | 测试断言（T42/T50） |

---

## §5 包 `fountain::f_jit.runtime`

### 5.1 包意义

执行期全部设施：**ctx（64 B 非托管）**、**句柄表 + 窗口 + 逃逸区**、**调用级迭代器表**、**helper 实现集（H01–H72，@C 薄入口）**、**诊断转储与报告组装**、**解释器（语义基准）**。桥与机器码都只经本包暴露的机制接触运行时状态。

### 5.2 顶级声明清单

| 声明 | 形态 | 意义 | 依赖 | 锚点 |
|---|---|---|---|---|
| `JitContext` | class | ctx 非托管承载 + 字段访问器（偏移固定） | — | §1、§4 |
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

#### 5.3.1 `JitContext`（class，非托管承载）

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
- **释放点不变**：仍在桥的 `finally`（`call<T>` 第 6 步；与 B pin / C 窗口 / D 逃逸槽同一次收尾），正常/错误码/DEOPT/-2/Marshal 失败全路径必须配对（T27 的 malloc/free 计数断言）。std.core 的 `CPointerResource`（`try (r = …)`）可把释放做成块级，语义与 finally 等价，实施时二选一。
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
| `static func open(h: Int64, elementKind: UInt8): Int64` | 建立迭代器（游标 = `(gen<<32)|idx`），返回游标 | H49 `map_iter_begin` |
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
| `static func alloc(size: Int64): ?CodeBuffer` | `mmap(PROT_READ|PROT_WRITE)`；失败 → None（桥降级解释器，不报错） | `JitCompiler` |
| `func write(bytes: Array<UInt8>, off: Int64)` / `func patch(pos: Int64, bytes: Array<UInt8>)` | 写入/重定位补丁（布局期） | 后端 |
| `func seal(): Bool` | `mprotect(PROT_READ|PROT_EXEC)`（W^X）+ I-cache 清理（aarch64 必需；x86 同接口） | `JitCompiler` |
| `func flushICache()` / `func free()` | 缓存一致性 / `munmap`（T27/T4） | 卸载 |
| `prop base: Int64` / `prop size: Int64` | 基址/长度 | 镜像烘焙、thunk |

#### 6.3.3 `JitCompiler`（class） / `JitArtifacts`

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(backend: Backend, diagnostics: DiagnosticsSink)` | 绑定后端 | 桥管线第 3 步 |
| `func compileUnit(unit: LoadedUnit, handleIds: Array<Int64>): ?JitArtifacts` | 编排：常量镜像 → 两遍布局（aarch64 条件分支 ±1 MB 需跳板） → 降低全函数 → seal；失败 → None（降级） | 桥 |
| `JitArtifacts.code: CodeBuffer` / `.fnTable: FnTable` / `.mirror: ConstMirror` / `.rawEntry(fnId): Int64` | 执行入口（桥 `rdi/x0 = ctx`） | 三态收尾第 2 步 |
| `func free()` | 资产释放（最后释放，§8.7） | 卸载 |
| `FnTable.alloc(n)` / `set(fid, entry)` / `entry(fid): Int64` / `free()` | 入口表维护（`CALL_FUNC`/`CALL_CLOSURE` 间接调用目标） | 模板 B/C |
| `ConstMirror.build(ids: Array<Int64>): ConstMirror` / `base(): Int64` / `free()` | 常量句柄镜像（`PUSH_KH`） | 单元生命周期（与 JitFunction 同生共死） |

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
| `func call<T>(args: Array<Any>): T` | **唯一对外执行成员**：参数长度/元素类型 → Marshal → 三态收尾执行 → 解包 → T 校验（编译期/运行期）→ 返回；执行异常原样转换抛出 | 宿主；T15 |
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
| `CompileCache.lookupOrClaim(fingerprint): CacheEntry` / `awaitReady(entry)` / `finish(entry, ok: JitFunction?)` / `remove(fingerprint)` | 状态机 Idle→Compiling→Ready/Failed；命中 Ready 复用、Compiling 阻塞等待、失败共享异常 | `Compiler.compile`；T16 |
| `AdapterRegistry.register(key, adapters)` / `lookup(key): ?Adapters` / `removeUnit(fingerprint)` | 单态化适配器注册表（宿主侧锁保护） | call 第 5 步；卸载 |
| `CompilePipeline.runSource(source): JitFunction` / `runUnit(unit): JitFunction` | 四步管线编排（编译/装载 → 去重 → 引擎选择 → 产物） | `Compiler.compile` |
| `Report.throwJit(code, site, fnId, dump, tables)` | 组装并经内部统一抛出 JitException（19 的桥层契约错误 site=-1 走此路） | 三态收尾第 3 步 |

#### 7.3.6 再导出清单（根包 `public import`）

| 再导出 | 内容 |
|---|---|
| `public import fountain::f_jit.base.*` | JitException、SourceCompileException、SourcePos、CallContext、SourceUnit、JitMode、Engine、JitValue、LocalType、TypeToken、ErrCode、DiagnosticsSink、DiagnosticLevel、Version |
| `public import fountain::f_jit.bytecode.*` | OPCODE_TABLE/OpInfo/CAT_*、FuncDir/FuncEntry/LocalTypes、ConstRegistry/ConstKind/ConstPayload、SiteTable/NameTable、FbcReader/FbcWriter/FbcHeader/LoadedUnit |
| `public import fountain::f_jit.runtime.*`（仅用户面） | HandleTable、（@C helper 符号不导出到用户面） |
| 自定义声明 | Compiler、CompileOptions、PredefinedFunction、JitFunction |

---

## §8 关键调用链（跨包协作）

### 8.1 `Compiler.compile(source: String)`（管线四步）

```
Compiler.compile(source)
 └─ CompilePipeline.runSource
     ├─ ① SourceCompiler.compile(source)
     │    Lexer → Parser → NameResolver → DefiniteAssignment → Lowerer → BytecodeBuilder → Assembler
     │    （预定义函数调用编译为 user helper：hid = slot+0x0100）
     ├─ ② CompileCache.lookupOrClaim(源码指纹)
     │    Ready → 复用同一 JitFunction；Compiling → 等待（成功共享/失败共享异常）；Miss → CAS 占位
     ├─ ③ BackendSelector.select(opts.jit, diagnostics)
     │    Linux + SDK 指令集 → JitCompiler.compileUnit(LoadedUnit, handleIds) → JitArtifacts
     │    否则 → 仅解释器（diagnostics 记录；不报错）
     └─ ④ new JitFunction(fnId=entryFn, 单元资产…) → 返回
```

### 8.2 `Compiler.compile(unit: SourceUnit)`（分发入口）

同上，替换 ① 为 `FbcReader.load(raw)`（加载期校验；含 user hid 的 `.fbc` → 拒绝，JitException(18) 语义），② 去重键换为字节码指纹。

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
| `FuncEntry/FuncFlags/OpInfo/OPCODE_TABLE` | bytecode | compiler、runtime、backend |
| `JitContext/HandleTable/IterTable/DbgDump/HelperId` | runtime | 根包（+backend 仅经 artifact ABI） |
| `CompileSession/CompiledSourceUnit/FuncBody` | compiler | 根包 |
| `JitArtifacts/FnTable/ConstMirror/CodeBuffer` | backend | 根包 |

---

## §9 设计决策与理由（补充 §0）

| 决策 | 备选 | 选择理由 |
|---|---|---|
| 6 个包（base/bytecode/compiler/runtime/backend/根） | 单包 / 按对象分（loader/assembler/interp/jit/marshal 各一包） | 按「正确性论证方式」分包：格式（bytecode）、编译期诊断（compiler）、解释语义（runtime）、差分（backend）——测试与回归边界清晰；再细则共享契约会散落 |
| `LocalType/ErrCode/TypeToken/HelperId/Version` 用类+`static const` | 顶层常量 / enum | 规格示例 `LocalType.I64` 与 §10.3 顶层 `CAT_*` 并存：命名空间类给出可点号访问的常量，且可挂 `name()/isHandle()` 查询；避免 250+ 顶层常量污染导入 |
| ctx 用 `CPointer<Int64>` 访问器承载 | `struct` 直映射 | 机器码要求 64 B 且不得移动（§4）；Cangjie 布局不承诺逐字节 ⇒ 显式访问器 + 非托管分配 |
| ctx/转储缓冲的非托管内存用 `std.core.LibC.malloc<T>` / `LibC.free<T>` | ① `foreign func malloc/free`；② `acquireArrayRawData` 钉住 `Array<UInt8>` | ① std.core 原生 API、免自声明 FFI；② 钉住方案被 std 文档窗口约束排除（获取与释放之间不得构造仓颉对象，而 ctx 跨整个调用、helper 必分配并触发 GC）；③ malloc 满足 16 B 对齐；释放仍走桥 finally（T27 计数断言）——详见 §5.3.1 |
| helper 以顶层 `@C` 函数实现 | 集中在一个 class | 与机器码 trampoline 静态链接（符号可见性简单）；三引擎共用同一实现（I7） |
| `JitFunction` 不拆「Interp 版 / JIT 版」子类 | 两个子类 | 引擎是运行时状态（卸载/诊断/测试都按同一句柄）；单类 + 可选 artifacts 最简 |
| 编译缓存/适配器注册表放根包 | 放 runtime | 它们是「桥的进程级资产」（宿主侧锁、与卸载/缓存语义耦合），非执行期机制 |

---

## §10 与规格文档的差异/待裁定项

| # | 项 | 说明 |
|---|---|---|
| D1 | `DiagnosticsSink` 细化 | 规格「接口从略」；本文细化为 `diag(level, message)`（含 Info/Warn/Error）——如需极简可退化为 `diag(String)` |
| D2 | `JitContext` 公开粒度 | ctx 布局是内部契约；`JitContext` 建议 `protected`（用户不见），仅测试与桥使用 |
| D3 | `JitValue` 可见性 | 规格列为 public；但唯一消费者 `invoke/tryInvoke` 为 private——建议随 §8 保持 public（便于未来开放 invoke 路径），或按最小暴露降为 protected；**待用户裁定** |
| D4 | `CompileCache` 的进程级宿主 | 规格为「进程级编译缓存」；设计放根包（static 单例），卸载与去重协议同一处维护 |
| D5 | 指纹算法 | 源码指纹/字节码指纹算法与常量 `constFingerprint`（FNV-1a）分开：前者用于去重键，规格未固化算法——建议 FNV-1a 同款，实施时裁定 |
| D6 | `Engine` 公开性 | 规格未列；为测试/诊断需要（T7/T9 断言）设为 public |
