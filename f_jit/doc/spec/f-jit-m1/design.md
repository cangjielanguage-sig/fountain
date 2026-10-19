# Design

## Context

**当前状态**：`f_jit` 仅停留在 P0 占位——六个包各一个只含 `package` 声明的 `.cj` 文件，未登记进根 `cjpm.toml`，没有任何可执行能力；`f_util` 已有 `UInt128` 与 `Crc32`，但没有 FNV 家族（本次新增 32/64/128/256/1024 五宽 × fnv1/fnv1a 与统一 API）。M1 的三份权威文档已经冻结：`f_jit/doc/jit-bytecode-m1.md`（v0.18.36）、`f_jit/doc/design-m1.md`（包级/顶级声明/公共成员三级设计）、`f_jit/doc/plan-m1.md`（P0–P7 / S0.1–S7.8 的 TDD 步骤表）。本次变更就是把这三份文档落成代码。

**塑造本设计的硬约束**：

1. **仓颉禁止包间循环依赖** ⇒ 模块内包依赖必须是 DAG；`internal` 只到「本包及子包」，跨兄弟包共享只能用 `protected`（module 级），用户面 API 由根包 `public import` 再导出。
2. **仓颉 GC 为 region 式搬移收集** ⇒ 托管对象地址不稳定，句柄槽不能存裸指针，只能取 **ID 形态**（规格冻结决策 ④，§9 附则 14）。
3. **仓颉 `struct` 不承诺逐字节布局** ⇒ 机器码 ABI 要求的 64 B 固定 ctx 只能落在非托管内存，并用访问器类读写（不得移动）。
4. **机器码不抛异常、不做栈展开、永不落盘** ⇒ 错误只能经 ctx 错误槽单向传递，异常只存在于宿主边界（helper 内部转码 + 桥的 errCode→异常转换）。
5. **本机为 Linux aarch64、仓颉 1.3.0** ⇒ 机器码的原生证据只可能来自 AArch64；x86_64 只能写成条件跳过用例，其证据由 CI 矩阵补齐；差分最小集为 `Interp × AArch64`。
6. **严格 TDD**：每个最小步先写会失败的用例，再写最小实现，全绿后才勾掉；一步一提交。

动机见 `proposal.md - Why`；需求与验收场景见 `specs/*/spec.md`；本设计只回答「怎么做」。

## Goals / Non-Goals

**Goals：**

- 产出**唯一分发物** `.fbc`：显式小端、与平台/端序/字长/ABI 无关，配一个覆盖 11 类非法情形的加载期拒绝面与明确的版本兼容矩阵。
- 在 `f_util` 交付**完整 FNV 家族**（32/64/128/256/1024 × fnv1/fnv1a）与统一 API（`Fnv.hash` / `FnvHasher`），让 f_jit 的指纹与去重键只依赖一份经过黄金值验证的实现。
- 建立**语义基准与等价加速器**：`runtime.Interp` 是规范，两个 JIT 后端只加速；同一字节码 + 同一输入，**结果 / 错误码 / 站点 / 报告文本**四元组逐位一致，且在**单次运行内**对拍完成（I7）。
- 建立**封闭的宿主边界**：参数封送与返回解包（pin / 逃逸 / 自动回收）、三态收尾（0 / -1 / -2 / >0）、编译去重（只编译一次）、适配器注册表、卸载状态机。
- 让**失败点可断言**：每个失败点用例同时断言 `code` 与 `site`（契约类错误显式断言 `site = -1`）。
- 让**用户面一次导入可用**：`import fountain::f_jit.*` 后能做「编译 → 调用 → 卸载」；`JitContext` / `Engine` / `JitValue` / `CompileCache` / `AdapterRegistry` / `CompilePipeline` 等执行期内部类型不出现在用户面。
- 全部结论**实测留档**：`cjpm build` / `cjpm test` 在融合开发环境（Linux aarch64，仓颉 1.3.0）跑出数字，容量与性能基线记录实测值而非估计。

**Non-Goals：**

- M2 / M3 范围：宿主闭包与宿主对象（LocalType 13/14）、Any 与 JSON（15–19）、H63–H68 / H73–H75、错误码 22、verMajor 2/3 的规则集——本次只**预留登记位与分派点**，不实现语义。
- `CALL_HOST` 通道、字节码级 try-catch / handler 表、宏系统。
- 磁盘缓存与跨机共享（机器码永不落盘、缓存键仅驻内存）、32 位宿主、非 Linux 平台的 JIT。
- 性能调优与优化门禁：本次只取基线数字，不设提速目标。
- 改动既有模块公开 API；`f_util` 侧只允许纯增量（新增 `Fnv` 与其测试）。

## Decisions

### D1 包按「正确性论证方式」切分，而不是按对象切分

六个包：`base`（契约）· `bytecode`（模型与格式）· `compiler`（前端）· `runtime`（执行期与解释器）· `backend`（机器码）· 根包 `fountain::f_jit`（门面与桥）。

- **备选 ①** 单包：文件规模与导入面失控，且格式校验 / 编译期诊断 / 解释语义 / 差分等价四类正确性论证混在一起，回归边界模糊。
- **备选 ②** 按对象分包（loader / assembler / interp / jit / marshal 各一包）：共享契约会散落，跨兄弟包引用必然成环。
- **选择理由**：四层有**不同的正确性论证方式**（格式 = 校验；前端 = 编译期诊断；运行时 = 解释语义；后端 = I7 差分），分包使测试落点与回归边界清晰；同时天然满足仓颉 DAG 约束。

### D2 共享契约下沉 + 可见性三档

`base` 不 import 模块内任何包；`bytecode` 只 import `base`；`compiler` / `runtime` / `backend` 彼此不 import；根包 import 全部。跨包共享声明一律 `protected`（module 级），仅用户面声明为 `public` 并由根包 `public import` 再导出。

- **备选 ①** 用 `internal`：只到「本包及子包」，跨兄弟包不可见，直接不可行。
- **备选 ②** 全部 `public`：ctx 布局、引擎枚举等 ABI 契约外泄，用户写坏即破坏不变量。
- **选择理由**：`JitContext` / `Engine` / `JitValue` 是机器码 ABI 与桥内约定，用户面无消费路径（`protected`）；`HandleTable` 是用户面（宿主需 pin/release 逃逸句柄）——**用户能管句柄 ≠ 能碰 ctx**。

### D3 「线上码族」用命名空间类 + `static const`

`LocalType` / `ErrCode` / `TypeToken` / `HelperId` / `Version` / `ConstKind` / `FbcFlags` / `OpInfo.CAT_*` 全部是**要编码进 `.fbc` 或要参与序列化分派的数值**，用类 + `static const` 承载，并挂 `name()` / `isHandle()` / `describe()` 查询函数。

- **备选 ①** 顶层常量：250+ 个常量污染导入空间。
- **备选 ②** `enum`：构造器不携带数值，序列化与分派需要确定数值码，不可行。
- **配套**：`OpInfo` 用 `struct`（5 字段，只读元信息、无身份）+ `static let OPCODE_TABLE`（256 项连续、缓存友好），类别码用 `static const` 保持编译期可用。

### D4 解释器是唯一语义基准；JIT 只加速；失败一律静默降级

`runtime.Interp` 实现全部指令语义，两个后端以它为基准做逐位对拍；代码内存分配 / 权限切换 / 平台不支持时一律退回解释器——**不写错误槽、不改结果**，只记一条 `JitFallback` 诊断。

- **备选 ①** 以 JIT 为基准：跨平台不可行、可测试性差，直接排除。
- **备选 ②** 三引擎各自实现一套 helper：结构性破坏 I7 ⇒ **决定 helper 只有一份仓颉实现，三引擎共用**（I7 结构性成立）。
- **配套**：DEOPT(-1) 不是错误，由桥透明重跑解释器；含变更型调用的函数在汇编期禁止 deopt 源（`FuncFlags.bit0` + 校验 11），保证容器变更不会被重放执行两遍。

### D5 错误通道单一：ctx 错误槽 + fail-fast + 自动 `CHECK_ERR`

错误只经 64 B ctx 的错误槽传递（I4）；汇编器在每个可失败点后自动插入 `CHECK_ERR`（I3）；helper 内部 try/catch 把异常转码为错误码，**绝不把异常抛给字节码或机器码**；异常只出现在宿主边界（桥的 errCode→异常）。多层嵌套写码遵循「内层已写码时外层仅在新异常时覆盖」，末尾 catch-all 兜 99。

- **备选** 让 helper 直接抛异常：机器码没有栈展开能力，异常穿过机器码帧即崩溃；且破坏 I4。
- **选择理由**：fail-fast + 单一错误槽是「三引擎逐位一致」能被静态论证的前提。

### D6 ctx 与转储缓冲用非托管内存 + 访问器；释放走桥 `finally`

ctx = `LibC.malloc<Int64>(count: 8)`（64 B、≥16 B 对齐），转储缓冲 = `LibC.malloc<Int64>(count: 2 + maxNLocals)`；`JitContext` 是 `protected` 访问器类，机器码按同一固定偏移直接读写；释放一律在桥 `call<T>` 第 6 步的 `finally`，与「窗口重置 / 转储缓冲清零 / 迭代器表 `clearAll`」排在同一条显式时间线上。

- **备选 ①** 自声明 `foreign func malloc/free`：std.core 已有原生 API，无必要。
- **备选 ②** `acquireArrayRawData` 钉住 `Array<UInt8>`：std 文档要求「获取与释放之间不得构造仓颉对象」，而 ctx 跨**整个调用事务**、helper 必然分配并触发 GC，直接违反窗口约束；仓库既有用法也全是「短窗口 + 立即释放」。
- **备选 ③** `CPointerResource`（`try (r = …)`）：只能表达「释放」这一件事，无法与同一次收尾的其他动作绑定，且引入第二套收尾机制。
- **选择理由**：malloc 满足对齐要求、免 FFI；单一 `finally` 收尾机制便于用 malloc/free **计数断言**（T27）证明全路径配对、无泄漏。

### D7 句柄 = ID 形态 + 窗口只增不减 + 逃逸区

槽内为 `idx:u32 + tag:u16 + gen:u16`，指向桥持有的托管对象表；只有白名单**分配型** helper 可登记新槽（每次调用至多 1 个），**变更型** helper（H43–H48）不登记；`hwTop == hwCap` 就地倍增扩容，触及 `capacityLimit` 才以 16 失败；逃逸槽在窗口重置后保持可用且 ID 不变。

- **备选** objref 裸指针：仓颉 GC 为 region 式搬移，对象地址不稳定 ⇒ 在仓颉宿主上不可实现（规格冻结决策 ④）。
- **选择理由**：ID 形态让机器码永不接触对象指针，无需写屏障，也让「释放后旧 ID 失效」能用世代号做确定性校验。

### D8 三类摘要分工明确，且一律复用 `f_util`，不自实现

| 用途 | 算法 | 口径 |
|---|---|---|
| `.fbc` 四段校验和（落盘） | CRC-32/ISO-HDLC | `f_util.Crc32.isoHdlc`（与 f_protocol / f_store 同款），基准 `crc32(空)=0`、`crc32("123456789")=0xCBF43926` |
| 常量指纹 | FNV-1a-64 | `f_util.Fnv64.fnv1a` |
| 源码 / 字节码去重键 | FNV-1a-128 | `f_util.Fnv128.fnv1a`（源码取规范化文本，字节码取整份 raw） |

三者**不得混用**；去重键命中后必须**二次校验原字节**（碰撞是语义错误，不靠概率兜底）。

- **备选** f_jit 自实现哈希：重复造轮子且口径易漂；规格与用户裁定都要求经 `f_util`。
- **备选** 去重用 CRC-32：碰撞语义不可接受。

### D8.1 `f_util.Fnv`：全宽族 + 统一 API（含 `Fnv1024`）

`Fnv` 提供 **32/64/128/256/1024** 五个宽度 × **fnv1/fnv1a** 两个变体，并给出统一入口：

| 层 | API | 返回 |
|---|---|---|
| 统一入口 | `Fnv.hash(width, variant, data)` / `Fnv.fnv1(width, data)` / `Fnv.fnv1a(width, data)` | `Array<UInt64>`（长度 = `width.words`，最高有效字在前） |
| 增量入口 | `FnvHasher(width, variant).update(...)` / `finish()` / `reset()` | 同上；`finish` 可重复调用、不改变状态 |
| 类型化入口 | `Fnv32`/`Fnv64`/`Fnv128`/`Fnv256`/`Fnv1024` 的 `fnv1`/`fnv1a` | `UInt32` / `UInt64` / `UInt128` / 4 字 / 16 字数组 |

- `FnvWidth` 用命名空间类 + `static const`（`W32`…`W1024`）并提供 `name()/bits()/words()`；该类型不进 `.fbc`，不采用线上码枚举。
- 类型化入口只是统一引擎的薄包装：**算法只写一份**，禁止复制或分叉实现。
- **`Fnv1024` 的实现**：仓颉没有原生 1024 位标量 ⇒ 用 **16 个 `UInt64` 字（大端序）**承载；素数为 `2^680 + 2^8 + 0x8D`（稀疏），乘法用「移位 + 加法」按字处理并保留进位，按 `2^1024` 取模；偏移基值与素数逐字抄自官方 FNV 参考实现（IETF `draft-eastlake-fnv-31` / `fnv.rs`），实现文件头注明来源。
- **黄金值来源**：32–256 用已公布的标准向量；1024 用独立参考实现（Python 大整数按同一公式）生成空串与 `123456789` 两组值，并与官方常量交叉校验——测试先于实现写入这些常量。
- **字序说明**：统一 API 返回的是数值的字序列（最高有效字在前），**不是** IETF 规定的 little-endian 持久化字节序；若需落盘或跨实现交换，再按 IETF「FNV Endianism」转成小端字节流。
- **用途边界**：f_jit 只用 64（常量指纹）与 128（去重键）；32/256/1024 是 `f_util` 的通用能力，f_jit 不依赖。


### D9 编译缓存进程级；一份源码只出一份产物

`CompileCache` 是根包静态单例（进程级），状态机 `Idle → Compiling → Ready/Failed`；键 = FNV-1a-128（源码规范化文本 / 整份 raw 字节）；**每次编译新建 `Compiler` 实例**（实例只是「一次编译的配置载体 + 注册表快照」），但**一份源码只出一份字节码与 JIT 产物**（跨实例复用是目标）。

- **备选 ①** 缓存按实例隔离：违背「只编译一次」的验收项 T16。
- **备选 ②** 键附加注册表快照身份：会让「同一源码不同实例」各编译一份，同样违背目标。
- **已确认的推论（预期语义，非缺陷）**：A 实例编译过源码 S 后，未注册 S 中所用函数的 B 实例再 `compile(S)` 会**命中缓存并成功**——「一份源码只出一份产物」优先于「未注册即报错」；本设计用一条用例把它固化下来。

### D10 两形态产物同一接口

机器码形态与纯字节码形态**同为 `JitFunction`**、同一 `call<T>(args: Array<Any>): T` 签名、行为逐位一致；差异只在内部 `?JitArtifacts`。

- **备选** 拆「JIT 版 / 字节码版」两个子类或第二用户面类型：调用方被迫感知引擎，且卸载/诊断/测试要按两套句柄处理。

### D11 加载期拒绝面集中实现 + 版本兼容矩阵显式

11 类非法情形（魔数、主版本、未知标志位 / 要求 JIT、段长不符、常量图成环、坏载荷、目录越界、类型表非法、站点表问题、名字表坏键、校验和不符）集中在一个 `validate` 里逐条拒绝，**每条一条独立用例、互不掩盖**。本加载器只到 `verMajor=1`；v2 / v3 以 18 语义拒绝并给出「最小可接受 verMinor」；`verMinor ≤ 13` 的旧布局头（无 `nameLen`、payload 36）按分支兼容读取。

- **备选** 校验散落在各解析器里：拒绝面无法逐条枚举、也无法证明互不掩盖。

### D12 后端：W^X 代码内存、两遍布局、镜像烘焙、IBT/BTI

`CodeBuffer`：`mmap(PROT_READ|PROT_WRITE)` 布局 → `mprotect(PROT_READ|PROT_EXEC)` 封存 → I-cache 清理（AArch64 必需）→ `munmap`（幂等）。`JitCompiler` 两遍布局：条件分支超出架构范围时改写为「取反条件 + 无条件跳转」跳板；`ConstMirror` 连续 8 B、基址烘焙进机器码立即数；`FnTable` 走非 GC 内存；入口与间接调用着陆点全程发射 `endbr64` / `bti c`；缓存键 `(arch, cpuFeatures, bytecodeFingerprint)` 仅驻内存。

- **备选** 一遍布局 + 跳板兜底全用绝对跳转：aarch64 条件分支 ±1 MB 边界会被静态撞到，必须预留两遍。
- **备选** 机器码落盘复用：违反冻结决策（I6），直接排除。

### D13 差分 harness：单次运行内对拍四元组

`src/test/diff` 是独立测试层，只承载跨引擎一致性断言；在同一进程、同一份用例与同一输入上跑完全部可用引擎，对**结果 / 错误码 / 站点 / 报告文本**四元组逐位对拍。本机最小集 = `Interp × AArch64`；针对 x86_64 的机器码断言写成**条件跳过**并计入「非原生跳过」统计（不判失败），证据由 CI 矩阵补齐。

- **备选 ①** 跨运行比对（各引擎各跑一次再比文本）：只能作旁证，进程间状态差异会让判据失真。
- **备选 ②** 让非原生架构用例失败：污染回归信号，且本机根本无法修复。

### D14 TDD 循环与测试落点按「语义所属层」

| 用例语义 | 落点 |
|---|---|
| 格式 / 校验（`.fbc` 合法性、常量序列化） | `bytecode` 层 |
| 编译期诊断（词法 / 名字解析 / 明确赋值） | `compiler` 层 |
| 指令语义 / 错误码 / 迭代快照 / 文本化格式 | `runtime` 层 |
| 降低（指令序列与栈平衡） | `compiler` 层（产物断言）+ 差分层 |
| 三引擎逐位一致 | 差分层（不放单层语义断言） |
| 桥契约（Marshal / T 校验 / 去重 / 卸载） | 根包层 |

每步红（先写会失败的用例）→ 绿（最小实现）→ 重构（抽公共 helper / 编码原语 / 检查块），一步一提交；**不允许出现「任务已勾选但没有对应用例」的进度**。

### D15 依赖与平台边界

`f_jit` 依赖 `fountain::f_base`（`BaseException` 基类、OS/Arch 判定）、`fountain::f_regex`（Regex 常量构造链与 `String.regex()` 扩展）、`fountain::f_util`（`Crc32.isoHdlc` 与新增 `Fnv`）；M3 才追加 `fountain::f_data`。**两个异常统一继承 `fountain::f_base.BaseException`**，使宿主可跨模块统一 `catch (e: BaseException)`。JIT 仅 Linux 且指令集跟随仓颉 SDK for Linux（当前 x86_64 / aarch64）；其余平台恒解释器并静默降级。

### D16 生命周期：卸载状态机 + 固定释放顺序

`Ready →(CAS) Unloading`（拒绝新调用、活跃调用照常完成、超时恢复 `Ready`）`→ Unloaded`（终态，重复卸载幂等）。资产释放顺序固定：**适配器注册表与缓存条目 → 常量与句柄槽（gen+1）→ 目录 / 字节码 / 类型表 → code buffer + fnTable（最后，可能仍有活跃调用在执行）**。

## Risks / Trade-offs

- **[helper 集体量（H01–H72）大且零散]** →  mitigation：按族推进（容器读 / 比较判定 / 错误控制 / Decimal / 字符串 / 时间 / 区间 / 变更 / 正则 / 闭包 / Map 迭代），**每族完成即接一次差分**，避免尾部积压。
- **[`Fnv1024` 常量抄错或 16 字乘法丢进位]** → mitigation：偏移基值/素数逐字抄官方参考并在文件头注明来源；用 Python 大整数参考实现生成空串与 `123456789` 黄金值先写进测试；长输入与 4 字节码点用例覆盖高位进位；统一 API 与类型化入口的等价用例兜住包装层。
- **[x86_64 机器码证据本机拿不到]** → mitigation：条件跳过 + 计入「非原生跳过」统计，不判失败；本机最小集 `Interp × AArch64` 仍构成 I7 的有效证据；x86_64 证据由 CI 矩阵补齐。
- **[DEOPT 重放与容器变更冲突（变更被执行两遍）]** → mitigation：汇编期校验 11 禁止含变更型 / 预定义 / `CALL_CLOSURE` 调用的函数发射 deopt 模式，并以 `FuncFlags.bit0` 标记供桥做防御性检查。
- **[浮点 NaN 位模式跨引擎漂移]** → mitigation：后端在浮点运算后追加 `CANON` 规范化尾，解释器与机器码共用同一规范位模式，并由差分用例逐位断言。
- **[句柄窗口触顶（16）与容量上限难以自然复现]** → mitigation：容量用例显式调小 `HandleTable.initialCapacity` 复现扩容与触顶路径，不靠概率；数字留档。
- **[非托管内存泄漏 / 全路径未配对]** → mitigation：malloc/free 计数断言（T27），释放点统一在桥 `finally`，覆盖正常返回 / 各错误码 / 中断 / DEOPT 重放 / Marshal 失败 / GC 并发搬移全路径。
- **[诊断 sink 抛异常改变语义]** → mitigation：引擎吞掉并挂为 suppressed（有在途异常时），`Error` 不捕、不重入 diag；降级路径绝不因诊断失败而报错。
- **[编译缓存跨实例复用使「未注册即报错」失效]** → mitigation：已裁定为预期语义，写进 D9 并用用例固化其可观察行为。
- **[仓颉语法 / std API 猜测风险]** → mitigation：语法与 std API 一律查 `cangjie_docs` 确认后再写，不猜 API 与语法；编译报错先查文档再改。
- **[文档与实现漂移]** → mitigation：S7.8 做偏差回写（`design-m1.md` / `plan-m1.md` 修订记录）+ 附 A / 附 B / 附 C 各抽 3 行与规格 §5 / §10 / §12 同源比对。

## Migration Plan

本变更是**纯增量**（新模块 + `f_util` 新增一个哈希族），没有数据迁移，也没有对外 API 的破坏面。落地顺序：

1. **沿用工作树**：使用现有 `.worktrees/f_jit`（分支 `feature/f_jit`），不另开分支；基线保持 `be69fdd0`，**暂不合并 `sts/1.3.x`**（用户裁定）。
2. **`f_util` 增量**：新增 `Fnv`（32/64/128/256/1024 × fnv1/fnv1a）与统一 API（`Fnv.hash` / `FnvHasher`）及 `Fnv_test`，`cjpm test` 全绿后再进入 f_jit——它是 S2.16 指纹接入的前置。
3. **骨架与基线**：补全 `f_jit/cjpm.toml`、六个包与 `src/test/diff`，先拿到「`cjpm build` 通过、`cjpm test` 可执行且 0 失败」的**基线数字**并留档（后续每步对照「用例数单调增长、失败数为 0」）。
4. **按硬顺序推进**：`base` → `bytecode` →（`compiler` ∥ `runtime` ∥ `backend`）→ 门面/桥；解释器必须先于后端对拍启用（它是基准）。每步一提交，提交信息注明步骤号。
5. **不登记根工程**：**不改根 `cjpm.toml`**（用户裁定）；`f_jit` 以模块自身 `cjpm build` / `cjpm test` 为验收入口，完整回归在模块目录执行。
6. **差分与验收**：T 映射脚本校验、容量与性能基线实测留档、文档偏差回写。
7. **回滚策略**：`f_jit` 是新增模块、`f_util` 是纯增量 ⇒ 回滚 = revert 本分支提交；无数据迁移、无旧版本兼容负担。

## Open Questions

以下两项**不影响**本变更的规格、实现路径与任务拆分，可安全留到实现后期再定：

- x86_64 机器码证据由哪条 CI 流水线补齐（本机以「条件跳过 + 非原生跳过统计」处理，判据不变）。
- 性能基线是否设提速门禁（本次只记录实测数字与比值，不设阈值，不作为完成判据）。

## 实施注意（2026-10-17 实测，apply 阶段必读）

1. **仓颉 codegen 已知缺陷（已在代码层规避，勿再踩）**：`lib` 与 `$test` 两个编译单元对「递归枚举 + 中间 `Option` 载荷」的布局不一致——`AstStmt.Decl(String, ?TypeRef, ?AstExpr, SourcePos)` 在 `*_test.cj` 里 `match` 会把 `Some` 读成 `None`（枚举自身方法与普通文件读取正常；最小复现不重现）。**规则：`*_test.cj` 中不要直接 `match` `AstExpr` / `AstStmt` / 其它递归 AST 枚举**；形状断言一律调用 `src/compiler/AstShape.cj`（lib 编译单元）暴露的 `shapeE/shapeS/exprOf/retShapeOf/retPosOf/...`，断言字符串。新增需要读取 AST 的测试辅助函数也必须放在非 `_test.cj` 文件中。
2. **构建与测试入口（融合开发环境）**：`source /tmp/cjenv.sh` 后 `cd f_jit && cjpm build && cjpm test`；全绿才算通过。基线与每批结果（用例数、失败数）写进提交信息。
3. **TDD 落点**：每个 S 任务先写失败用例并确认失败原因正确（功能缺失 / 断言不满足），再写最小实现；跑绿后才勾 `tasks.md` 并同步 `f_jit/doc/spec/f-jit-m1/tasks.md`。
