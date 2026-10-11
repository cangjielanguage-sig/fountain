# f_jit 详细设计 · M2 增量（verMajor 2：宿主互操作）

> 依据：`jit-bytecode-m2.md` v0.8.27（同目录）。本文只写 **M2 的增量与受影响面**；未提及的包、声明、成员一律沿用 `design-m1.md`。
> 版本口径：`.fbc` **verMajor 2**（verMinor 0）；M1（verMajor 1）产物语义与加载路径**完全不变**；M2 包含六篇增量（§0–§10 CALL_HOST 宿主闭包、§11 HostObject 通道、§12 成员访问、§14 逃逸闭包回桥、§15 字节码侧构造、§16 宿主对象实参）。

---

## §0 M2 定位与增量总览

**需求**：字节码世界与宿主仓颉的**双向互操作**——
① **接收并调用**：字节码执行期接收宿主仓颉闭包做实参并调用（CALL_HOST）；
② **返回并承接**：字节码世界内产生的内部闭包值**跨桥返回**宿主（逃逸闭包回桥，仅返回方向）；
③ **class 实例通道**：宿主类实例以不透明载荷进出（含实参注入、成员访问、构造）；
④ **成员访问增量**：包装模式 + 实例字段读写 + 成员访问语法糖（+ 反射自动注册）.

**核心支点**：**CALL_HOST = 「目标运行期确定的 helper 调用」**——H63 是普通 `@C` helper，复用 M1 helper 全套基础设施（ABI、错误转码、窗口登记、自动 CHECK_ERR、GC/重入边界）；**不引入任何新执行机制**，新写的只有 H63/H64/H65 的实现体、验签逻辑与前端语法面。

**新增概念一览（对 M1 的对应）**：

| 概念 | M1 状态 | M2 增量 |
|---|---|---|
| HostClosure | 内部闭包值 token 9 / LocalType 12 | token 10 / LocalType 13（宿主闭包句柄；B pin 进入、`CALL_FUNC` 链内可传） |
| HostObject | 宿主自定义类一律 19 | token 11 / LocalType 14（不透明引用；持有/转发/返回/字段读写/构造） |
| 验签 | 无（M1 闭包不跨桥） | Marshal 运行期签名核对（一次性、缓存于条目） |
| CALL_HOST（0x79） | 汇编期 `ERR_NOT_IMPL` | 激活，操作数重定义为 `u8 argc`；栈 `[h_fn, a1..an]` |
| 错误码 21 | 99 = 实现缺陷兜底 | 21 `ERR_HOST_EXCEPTION`（**全部宿主侧调用面**；cause 含完整仓颉栈） |
| 成员访问 | 不透明（零字段访问） | H64/H65 字段读写 + 包装调用 + `u.f/u.f=v/u.m()` 语法糖 |
| 逃逸闭包回桥 | 内部闭包 12 禁跨桥 | 仅「跨桥返回」开放：提升组 + `JitClosureId` + 包装器 close |
| 字节码侧构造 | 无路径 | `C(args…)` → 注册构造器（user helper 通道，零新指令/helper/格式） |
| 反射自动注册 | 手工逐成员注册 | `Compiler.registerType<T>()` 经 `std.reflect` 批量生成注册项 |

---

## §1 包与声明增量总览

| 包 | 新增声明 | 受影响的既有声明 | 不变面 |
|---|---|---|---|
| `base` | `ClassDescriptor`、`PublicField`、`PublicMethod`、`PublicCtor` | `LocalType`（+2 常量）、`TypeToken`（+2）、`ErrCode`（+21 与描述）、`Version`（+M2 版本常量） | 全部值/异常类型（JitException 构造语义不变） |
| `bytecode` | — | `OPCODE_TABLE`（0x79 行）、`FbcReader`（verMajor 分派）、`LocalTypes.validate`（按 verMajor 合法集） | 容器头字段、段模型、crc32、kind 1–10 |
| `compiler` | `TypeRef`、`ClassRegistryView` | `NameResolver`（解析顺序 + 冲突拒绝）、`Lowerer`（CALL_HOST/成员访问/构造/14 槽）、`AstExpr`（+4 构造器）、`DefiniteAssignment`（14/13 槽规则同型） | 词法、语法基座、既有降低模式 |
| `runtime` | `HostCallback`、`SignatureDescriptor`、`SignatureVerifier`、`PromotionGroup`、H63/H64/H65（顶层 @C func） | `HandleTable`（条目标签 10/11）、`IterTable`（不变）、`DbgDump`（报告值型扩展：14 记 `<类名>#idx`） | ctx、迭代器、既有 helper 语义 |
| `fountain::f_jit`（根） | `ClassRegistry`、`JitClosureId`、`JitClosure`、`ReflectRegistrar` | `Compiler`（+2 成员）、`CallMarshal`（+行）、`JitFunction`（+`callWith<Fn>` 退化变体） | 执行六步、卸载状态机、去重缓存 |

---

## §2 `base` 增量

### 2.1 既有声明的新增成员

| 声明 | 新增成员 | 值/意义 | 锚点 |
|---|---|---|---|
| `LocalType` | `static const HOST_CLOSURE = 13` | 宿主闭包（句柄型；空安全同 M1） | m2 §1 |
| | `static const HOST_OBJECT = 14` | 不透明宿主对象（句柄型） | m2 §11 |
| | `static func isHandle(code)`（语义扩展） | 13/14 亦为句柄型 | m2 §2 |
| `TypeToken` | `static const HOST_CLOSURE = 10` / `HOST_OBJECT = 11` | 句柄槽 tag、`IS_TYPE/GUARD_TYPE/H19` 编码 | m2 §2 |
| `ErrCode` | `static const HOST_EXCEPTION = 21` | 宿主（仓颉侧）异常专用码：CALL_HOST 闭包 / 预定义与包装 / 构造适配器 / 成员访问器；cause 附完整仓颉栈、桥打印 | m2 §2、§13-6 |
| | `static func isHostSide(code)`（实现落地） | 21 判定（M1 占位返回 false） | m2 §2 |
| `Version` | `static const M2_MAJOR: UInt16 = 2` / `static const M2_MINOR: UInt16 = 0` | M2 产物版本 | m2 §2 |

### 2.2 新增声明：注册协议值类型

#### 2.2.1 `ClassDescriptor`（class）

| 成员（草图） | 意义 | 调用关系 |
|---|---|---|
| `init(name!: String, fields!: Array<PublicField>, methods!: Array<PublicMethod>, ctors!: Array<PublicCtor>)` | 类注册描述符（§12.4 最小注册表 + §15 构造器扩展） | `Compiler.registerClass` / `ReflectRegistrar` |
| `let name: String` | 注册类名（源语言可作类型注解；未注册 → 编译错误） | 前端 `ClassRegistryView` 解析 |
| `let fields: Array<PublicField>` | 实例字段表（name → index/type/mutable/typeRef） | 成员访问糖解析 + H64/H65 |
| `let methods: Array<PublicMethod>` | 方法绑定表（`u.m(a…)` → 预定义调用） | 糖降级 |
| `let ctors: Array<PublicCtor>` | 构造器表（`C(args…)` 重载解析） | 构造降低 |

#### 2.2.2 `PublicField`（struct）

| 成员 | 意义 | 锚点 |
|---|---|---|
| `init(name!, type!, index!, mutable!, typeRef!)` | 字段项构造 | m2 §12.2 |
| `let name: String` | 字段名（前端解析用） | — |
| `let type: UInt16` | LocalType 编码 0–14（v0.8.20：9=Regex 并入） | — |
| `let index: UInt16` | H64/H65 的 index 实参（字节码只见 index 与类型码） | — |
| `let mutable: Bool` | `var`/`let` 标志（`let` 写 → 编译错误；裸 H65 防御 → 19） | 双防线 |
| `let typeRef: ?String` | 14 型字段的目标类名（链式解析 `u.a.b`） | — |

#### 2.2.3 `PublicMethod`（class）

| 成员 | 意义 |
|---|---|
| `init(name!: String, bind!: PredefinedFunction)` | 方法项（`bind` 即 §12.1 包装模式的显式登记；首参固定为该类：签名 `(C, T…) -> R`） |
| `let name: String` / `let bind: PredefinedFunction` | `u.m(a…)` 解析与降级目标 |

#### 2.2.4 `PublicCtor`（class）

| 成员 | 意义 |
|---|---|
| `init(params!: Array<UInt16>, adapter!: (Array<Any>) -> Any)` | 构造器项（对外签名 = `(T1,…,Tn) -> C`；实现按 `(Array<Any>) -> Any` 承载——实参以已解包的仓颉值装箱传入、返回值须为 C 实例（装箱约定同 `PredefinedFunction.impl`）；失败面：适配器异常 → 21、防御 99） |
| `let params: Array<UInt16>` | 形参类型序列（重载解析；含 14 → 嵌套构造） |
| `let adapter: (Array<Any>) -> Any` | 构造执行体（宿主侧；反射自动生成或手工注册，语义等价） |

---

## §3 `bytecode` 增量

| 项 | 内容 | 锚点 |
|---|---|---|
| `OPCODE_TABLE[0x79]` 行更新 | `OP_CALL_HOST`：`fmt="u8"`、`len=2`、`cat=CAT_CALL`（M1 预留的 `u16 fid` 编码废弃；M1 从未产出该 opcode，重定义不破坏任何 M1 产物） | m2 §2 |
| `Version.MAJOR` 扩展 | `M1=1 / M2=2`（M3=3）；`FbcReader.load` 按 `verMajor` 分派校验规则集 | m2 §2、§9.2 |
| `FbcReader` 加载规则集分派 | ① `verMajor=1` → M1 规则集（LocalType 0–12、无 CALL_HOST）；② `verMajor=2` → LocalType 0–14、CALL_HOST 合法；③ M1 加载器遇 verMajor 2 → 18 | m2 §9.2 |
| `LocalTypes.validate` | 合法集按该单元的 verMajor 取（1：0–12；2：0–14；15–255 恒拒绝） | m2 §2 |
| `CALL_HOST` 汇编语义 | 栈 `[h_fn, a1..an]`；自动尾随 CHECK_ERR | m2 §2 |
| 常量段 | **无新增 kind**：HostClosure 不可常量化（不可序列化）；kind 11 由 M3 JSON 使用 | m2 §1、m3 §11 |

---

## §4 `compiler` 增量

### 4.1 新增声明

#### 4.1.1 `TypeRef`（enum，前端类型记法解析产物）

| 构造器 | 意义 | 锚点 |
|---|---|---|
| `Builtin(UInt16)` | 参数序 = code：内建类型（LocalType 0–11） | m2 §3 |
| `HostClosureT(Array<UInt16>, UInt16)` | 参数序 = params, ret：函数类型记法 `name: (T1, T2) -> R`（T/R ∈ 0–8、10–11、14；**禁高阶**：T/R 不得为 12/13） | m2 §3 |
| `HostObjectT(String)` | 参数序 = className：注册类名（opaque 形参/局部/返回） | m2 §16.1 |

注：**enum 构造器只写参数类型、不带参数名**（仓颉语法），参数含义如上以「参数序」标注。

#### 4.1.2 `ClassRegistryView`（class，编译期只读快照）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(snapshot: ClassRegistrySnapshot)` | 快照绑定（注册变更不影响已编译单元） | `SourceCompiler` |
| `func classOf(name: String): ?ClassDescriptor` | 类名解析（未注册 → 编译错误） | `NameResolver`/`Lowerer` |
| `func fieldOf(className: String, field: String): ?PublicField` | 字段解析（name → index/type/mutable/typeRef） | 成员访问糖 |
| `func methodOf(className: String, method: String): ?PublicMethod` | 方法解析（→ user helper hid） | 糖降级 |
| `func ctorsOf(className: String): Array<PublicCtor>` | 构造器集（重载解析：静态匹配；无匹配/歧义 → 编译错误） | `C(args…)` |
| `func isRegistered(name: String): Bool` | 类型注解合法性（内建 → 注册类名 → 未知=编译错误） | `TypeRef` 解析 |

### 4.2 既有声明的新增/变更成员

| 声明 | 增量 | 说明 | 锚点 |
|---|---|---|---|
| `AstExpr` | `+ FieldGet(obj: AstExpr, field: String)`、`FieldSet(obj, field, value)`、`MethodCall(obj, method, args)`、`CtorCall(className: String, args)` | 语法糖与构造的 AST 形态（携带静态类知识由前端跟踪） | m2 §12.4、§15 |
| `NameResolver.resolve` | 解析顺序扩展为 `recursive → user helper → HostClosure 形参/局部（声明类型 13，静态判定 → CALL_HOST）→ 未定义`；**同名冲突**（HostClosure 形参/局部 vs 已注册 user helper）→ 编译错误 | 无运行期查找 | m2 §3 |
| `ResolvedCall` | `+ HostClosureCall`（发射 CALL_HOST） | — | m2 §3 |
| `DefiniteAssignment` | 槽类型集扩展（13/14 同句柄型规则；14 恒非空） | 空安全与 M1 同型 | m2 §16.3 |
| `Lowerer` | ① **CALL_HOST 降低**：`fn(a1..an)` = 实参左→右入栈 → `LOADL fn`（句柄压栈底）→ `CALL_HOST u8 argc` + 自动 CHECK_ERR；② **成员访问降级表**：`u.f`→ H64、`u.f=v`→ H65（`let` 字段 → 编译错误）、`u.m(a…)`→ 包装 user helper 调用（hid 由方法表解析；**方法签名实参不匹配 → 编译错误**——静态签名已知）；③ **构造降低**：`C(args…)` → `CALL_HELPER <ctor-hid>`（构造器物化为单元私有 user helper）；④ 14 型实参/返回/链内传参按签名静态校验；⑤ 静态成员不参与语法糖（经 §12.1 包装直呼） | 全部复用既有机制 | m2 §3/§12.4/§15 |
| `Assembler` | 校验 ⑦ 扩展：`CALL_HOST` 的 argc 展开与栈布局校验（`[h_fn, a1..an]`）；8 修订：`CALL_HOST` 在 M2 规则集下合法（M1 规则集仍 → NotImpl） | — | m2 §2 |

---

## §5 `runtime` 增量

### 5.1 新增声明

#### 5.1.1 `HostCallback`（class，句柄条目载荷）

| 成员 | 意义 | 锚点 |
|---|---|---|
| `init(fn: Any, sig: SignatureDescriptor)` | 宿主闭包对象 + 签名描述符（验签一次性产出并缓存于条目） | m2 §1 |
| `let fn: Any` | 宿主仓颉闭包对象本身（GC 托管；条目持强引用 ⇒ 调用期间不可能死亡） | — |
| `let sig: SignatureDescriptor` | 参数类型序列 + 返回类型（CALL_HOST 执行期零验签） | — |
| （M3 增）`var plan: ?SignaturePlan` | 特化 marshal 计划（见 design-m3.md §5.3） | m3 §13 |

#### 5.1.2 `SignatureDescriptor`（class）与 `SignatureVerifier`（class）

| 成员 | 意义 | 锚点 |
|---|---|---|
| `SignatureDescriptor(params: Array<UInt16>, ret: UInt16)` / `params` / `ret` | 签名编码（参数 LocalType 序列 + 返回；禁高阶 ⇒ 深度恒 1） | m2 §1/§4 |
| `SignatureDescriptor.validate(): Bool` | 合法性（T/R ∈ 0–8、10–11、14；12/13 拒） | — |
| `static func SignatureVerifier.verify(value: Any, declared: SignatureDescriptor): ?SignatureDescriptor` | 验签 = **单次 `is (T1..Tn) -> R`**（声明签名取自前端/桥静态知识；语言**子类型语义** ⇒ 一并覆盖参数个数/逐参/返回，**不另设分步核对**；P1）；失败 None（→ 19）；成功产出描述符（由调用方存入句柄条目）。**禁高阶**由 `R` 取具体非函数类型承接（2026-10-11 裁定：方案 a） | m2 §4 |
| `static func SignatureVerifier.cached(entry: HostCallback): ?SignatureDescriptor` | 复用既有验签结果：**条目已验签 → 返回 `entry.sig`；否则 `None`**（由调用方走 `verify` 并把结果写回条目）。**缓存 = 条目字段的存在性**，不做「对象 → 条目」定位 | m2 §4 |

**归属**：`SignatureVerifier` 是**纯静态工具类**——只有静态函数、**无实例、无构造**（因此也不持任何状态，缓存一律落在条目上）；`SignatureDescriptor` 是**值语义的签名编码**（构造 + 两个只读字段 + `validate()`），两者不要混读。

**`cached` 的定位方式（2026-10-11 裁定：收条目）**：缓存落在句柄条目（`HostCallback.sig`），`cached` 因此**直接收条目**、不再收对象——① 省掉一次「对象 → ID」定位：调用点（Marshal / H63 转发器）本已持有条目，而句柄表操作需宿主侧锁保护（§8.1），多一次查找就是热路径上一次多余的加锁；② 规避「对象身份」语义（`pin` 的"同对象复用同 ID"需要身份级哈希/比较，对任意 `Any` 不天然精确）；③ 失败面唯一——只剩"未验签"一种情况（`None`），不再有"对象找不到条目"的新错误态；④ 与 M3 的条目级特化缓存（`HostCallback.plan`，m3 §13）同向。**备选（① 经 `HandleTable.pin` 反查条目）：已否决。**

#### 5.1.3 `PromotionGroup`（class，逃逸闭包回桥的提升组）

| 成员 | 意义 | 锚点 |
|---|---|---|
| `init()` | per-逃逸闭包清单 | m2 §14.2 |
| `func add(id: Int64): Unit` | 提升（D 路径式原地提升：迁出窗口记账、表项保留、ID/gen 不变、不参与后续分配重用）；重复提升幂等、计数 +1 | m2 §14.1/14.2 |
| `func contains(id: Int64): Bool` | 是否在组内（`close` 与 try/finally 豁免判定） | — |
| `func release(id: Int64): Unit` | 计数 −1、归零释放（gen+1 可复用） | m2 §14.2 |
| `func size(): Int64` | 组规模（诊断/容量对账） | — |

#### 5.1.4 H63 / H64 / H65（顶层 `@C` helper）

| hid | 函数（签名模板同 M1） | 语义 | 失败码 | 锚点 |
|---|---|---|---|---|
| H63 | `host_call_trampoline` | ① fetch 栈底句柄 → `HostCallback{fn,sig}`；② 按 sig 逐参 cell→仓颉值；③ 调用 `fn`；④ 返回 cell（R 为引用型 → 窗口登记 1 槽）；异常 → 21 + cause（含完整栈、桥打印）。**含 CALL_HOST 的函数 → `FuncEntry.flags.bit0` + deopt 源汇编期禁令 + 防御性 -1 → 99**（黑盒判定，与预定义 helper/CALL_CLOSURE 同模式） | 8, 16, 21, 99（19 属 Marshal 验签、非本 helper 内） | m2 §5、§6 |
| H64 | `host_get_field(obj, index) → cell` | 读字段：值型直取；句柄型 marshal 为句柄（条件分配型：登记 1 槽） | 8, 99 | m2 §12.2 |
| H65 | `host_set_field(obj, index, cell) → 0` | 写字段（**变更型**）：值型直存；句柄型 fetch 后存引用；**防御性 `mutable` 校验 → 19** | 8, 19, 99 | m2 §12.2 |

变更型路由（H65）：① 常量禁写（HostObject 不可常量化 ⇒ 自然满足）；② deopt 禁令（含 H65 的函数 → `flags.bit0` + 汇编期拒绝 deopt 源）；③ 防御兜底（-1 → 99）。

### 5.2 既有声明的新增/变更成员

| 声明 | 增量 | 说明 | 锚点 |
|---|---|---|---|
| `HandleTable` | 条目载荷类型扩展：`HostCallback`（tag=10）、宿主类实例引用（tag=11）；`pin` 对函数值/注册类实例开放（无 token 的其他对象仍 19） | pin 复用同表同 ID 语义 | m2 §1/§11/§16.2 |
| `HandleTable` | `func promoteOut(id)` / 与 `PromotionGroup` 协作的 `moveOutGroup(ids)` | 提升组按需**迁出窗口**（不复制、不改址、ID/gen 不变） | m2 §14.1 |
| `DbgDump.report` | 句柄型值呈现扩展：13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`（**大类名呈现**——不取对象、不解析注册类名） | 报告模板不变（M1 §9.16 逐条沿用）；2026-10-11 裁定见下，已回填 m2 规格 §5.1 | m1 §9.16 + m2 规格 §5.1 |

| `Interp` | `CALL_HOST` 指令语义（fetch → 逐参 → 调用 → 返回封装；21 语义）；M2 规则集下加载的单元可含 0x79 | 三引擎共用 H63 | m2 §5/§7 |
| helper 集 | hid 63/64/65 登记（63–68 为 M2/M3 保留区） | `HelperId` 常量补齐 | m2 §2 |

**`DbgDump.report` 行的三点澄清（2026-10-11 补注）**：① **“报告模板不变”**＝ M1 §9.16 的冻结面**逐条沿用**——三行模板（`（code=N，site=OFF）` ⏎ `  源码行 L:C · fnId=F` ⏎ `  变量: [i] 名字: 类型 = 值; …`）、条目格式（有名字 → `名字: 类型…`；无名字 → 直接类型）、以**槽位序号**为键、「`site=-1` → 无行号无变量」、「`dbgBase=0` → 仅行号」、「`-1`/`-2` 不转储」「最深失败帧获胜」——M2 既不新增行也不改格式；② **“本扩展”只是值呈现表的一行延伸**——§9.16 已冻结「句柄型（4–12）记 `<类型名>#idx`」，M2 新增两类句柄（13 `HostClosure`、14 `HostObject`）同样会出现在变量清单里，故呈现规则外延到 13/14；③ 该扩展原为**设计自定面**（规格未成文）——**现已回填 m2 规格 §5.1**，T60 的断言自此有规格依据。

**裁定（2026-10-11）：14 退化为大类名呈现（方案 ①；②③ 否决）**：14 的类型名没有载体——`LocalTypes` 每槽仅 1 B 大类、name 段只记变量名，而 §9.16 已冻结「**不取对象**（避免错误路径二次失败）」。故 13/14 一律呈现**大类名**（`<HostClosure>#idx` / `<HostObject>#idx`）。**② 新增 per-slot 注册类名段**（连带 verMinor / 加载校验 / crc32）与 **③ 修订冻结条文、允许防御式 `HandleTable.get(idx)` 取类名**（动 M1 冻结面、需重跑 §13.2）均否决；报告的首要用途是定位「哪个槽、哪类句柄、哪个 ID」，类名可由宿主侧自查。

---

## §6 根包（门面/桥）增量

### 6.1 新增声明

#### 6.1.1 `ClassRegistry`（protected class，宿主侧类注册表）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `func register(desc: ClassDescriptor): Unit` | 注册类（同名类重复注册 → 注册期拒绝；与 user helper 名冲突 → 注册期拒绝）；**快照语义**（注册变更不影响已编译单元；与手工注册可混用） | `Compiler.registerClass` / `ReflectRegistrar` |
| `func snapshot(): ClassRegistry snapshot` | 生成编译期只读视图 | `SourceCompiler` 构造时捕获 |
| `func resolve(name: String): ?ClassDescriptor` | 类名解析 | 前端视图 / 桥边界校验 |
| `func classOfField(...)` / `classOfMethod(...)` / `classOfCtors(...)` | 解析辅助（与 `ClassRegistryView` 同数据的宿主侧副本） | 桥 |

#### 6.1.2 `ReflectRegistrar`（protected class，反射自动注册）

| 成员 | 意义 | 锚点 |
|---|---|---|
| `func registerType<T>(into: ClassRegistry, diag: DiagnosticsSink): Unit where T <: Object` | 经 `std.reflect` 枚举 public 成员（`let/var`、`prop/mut prop`、`func`、`static let/prop/func`、**constructors**）批量生成 `ClassDescriptor`；逐成员尽力注册（`static var`/`static mut prop` 跳过（附 B）、支撑面外类型跳过、命名冲突跳过），跳过项记 diagnostics；**反射仅在注册期——字节码/JIT 路径零反射**；关闭反射的构建 → 明确报错 | m2 §12.5 |
| `func mapType(info: TypeInfo): ?UInt16` | 反射类型 → LocalType（值型 0–3 直映；std 句柄类型按 §3.2 名映射 4–11；其余类 → 14 + typeRef；不可映射 → 跳过） | m2 §12.5 |
| `func buildCtor(info: ConstructorInfo): ?PublicCtor` | 构造器自动适配器（`ConstructorInfo.apply` 为后盾；参数不可映射 → 跳过 + 诊断；泛型类按具体实例化） | m2 §12.5/§15 |
| （生成物命名约定） | 实例 prop getter 名 = 成员名；`mut prop` setter 名 = `set` + 首字母大写；静态包装名 = 成员名；方法 bind 内部名含 `.`（源不可直呼）；命名冲突 → 跳过 + 诊断 | m2 §12.5 |

#### 6.1.3 `JitClosureId`（public struct，逃逸闭包 ID 的宿主值类型）

**更名（2026-10-11）**：本类型原名 `CFunc`——与仓颉**内建**的 C 函数指针类型 `CFunc<F>`（FFI：`foreign func` / `@C` / `CPointer` 互转、调用需 `unsafe`）**同名**，在本模块满是 `@C` helper 的语境下极易误读。现名 **`JitClosureId`** 直述语义：承接逃逸闭包句柄 ID 的宿主值类型，与包装器 `JitClosure` 成对。

| 成员 | 意义 | 锚点 |
|---|---|---|
| `let id: Int64` | 承接逃逸闭包句柄 ID（已提升出窗口；ID 稳定至 `close`） | m2 §14.3 |
| `static const INVALID: Int64 = 0` | 无效值（防御） | — |

#### 6.1.4 `JitClosure`（public class，闭包包装器 = partial application）

| 成员 | 意义 | 调用关系 |
|---|---|---|
| `init(f: JitFunction, cid: JitClosureId)` | 绑定单元 + 闭包 ID（单元弱语义：不阻止卸载） | `CallMarshal` 解包 retType=12 时产出 |
| `func call<T>(args: Array<Any>): T` | 调用 = 新桥调用（新 ctx + `locals[0]` = 闭包句柄 → 闭包帧格式）；结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=-1）；**新 ctx 的分配/释放沿用 M1 选型 `std.core.LibC.malloc<T>` / `LibC.free<T>`**（design-m1 §5.3.1） | m2 §14.3/§14.4 |
| `func close(): Unit` | **必须显式调用**：提升组计数 −1、归零释放（gen+1 可复用）；幂等 | m2 §14.2/§14.3 |
| `prop isClosed: Bool` | 状态（close 后调用 → 19） | — |

#### 6.1.5 `JitFunction.callWith<Fn>`（返回闭包的强类型入口，条件启用）

**语义（2026-10-11 澄清）**：**调用 JIT 单元 → 取回它返回的闭包 → 交给宿主**（返回方向，§14 / retType=12）；**不是**"调用一个闭包并取值"。宿主拿到的是**可继续调用的 `JitFunction`**，而不是原生函数值——因此不需要 `Any → Fn` 这类**运行期函数类型判定**，这才是它在 P1 不可用时的兜底价值。

| 成员 | 意义 | 锚点 |
|---|---|---|
| `func callWith<Fn>(args: Array<Any>): JitFunction` | `Fn` = **返回闭包的函数类型**（编译期已知）；调用单元并返回承接该闭包的 `JitFunction`（其 `call<T>` 路径照旧）；签名/解包零运行期判定；与 `call<T>` 并存 | m2 §9.1/§14 |

**释放协议不变**：返回闭包属逃逸提升组，其计数释放仍走 `close`（M1 §8.1 规则 6②、§14.2）——无论包装载体取何形态。

### 6.2 既有声明的新增/变更成员

| 声明 | 增量 | 锚点 |
|---|---|---|
| `Compiler` | `func registerClass(desc: ClassDescriptor): Unit`；`func registerType<T>(): Unit where T <: Object`（内部转 `ReflectRegistrar`） | m2 §12.4/§12.5 |
| `CallMarshal` | ① **参数 Marshal 表** + 行：声明类型 = 注册类 C → `is C`（含子类、opaque 视图）→ `pin`（tag=11）；null → 19；HostClosure 声明 → 验签（**单次 `is (T1..Tn) -> R`**，§4）→ 回调表登记（tag=10）；② **解包表** + 行：`retType=12 → JitClosureId`、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 宿主类实例引用`；③ Closure 行**仅返回方向**（参数方向不加行） | m2 §4/§14.3/§16.2 |
| `JitFunction` | 内部状态扩展：`ClassRegistry` 快照、`PromotionGroup` 表（per-call 逃逸闭包）、`JitClosureId` 登记；`callWith<Fn>` 公开变体 | m2 §9.1/§14 |
| `CompileOptions` | `cpuFeatures` 启用（显式 ISA 开关：如 SSE4.1/4.2 优化；默认 0） | m1 §12.1（`CompileOptions.cpuFeatures` 定义处）+ m2 §2 |

---

## §7 关键调用链（M2 增量）

### 7.1 `CALL_HOST` 执行流（H63）

```
字节码: [h_fn, a1..an]  ──CALL_HOST argc──▶ H63 host_call_trampoline
  1. fetch(h_fn) → HostCallback{fn, sig}            // tag≠10 → 8
  2. 按 sig 逐参 cell → 仓颉值                       // 解释性 marshal（值型原值 / 句柄型 get / 14 实例引用）
  3. 调用 fn（普通仓颉调用；可能 GC / 抛异常 / 重入 JIT）
       └ 异常 → catch-all → 21 + cause（完整栈）→ 写槽返回（fail-fast）
  4. 返回值 → cell：R 引用型 → 窗口登记 1 槽；R 值型 → 原值
  5. 汇编器自动尾随 CHECK_ERR
```

### 7.2 成员访问糖降级（`u.f` / `u.f = v` / `u.m(a…)`）

```
u.f        → get_field(u, idx)        [H64；值型零登记 / 句柄型登记 1 槽]
u.f = v    → set_field(u, idx, v)     [H65；变更型 → flags.bit0 + deopt 禁令；let 字段编译期拒绝]
u.m(a…)    → 预定义调用 m(u, a…)       [方法表 bind；与手写包装路径逐位一致]
```

### 7.3 字节码侧构造 `C(args…)`

```
C(args…) → 实参左→右入栈 → CALL_HELPER <ctor-hid>（构造器 = 单元私有 user helper；对宿主注册表快照）
          + 自动 CHECK_ERR；每次求值 = 新 HostObject 实例（分配型：登记 1 槽）
          适配器异常 → 21 + cause；含构造的函数 → flags.bit0 + deopt 禁令
```

### 7.4 逃逸闭包回桥（提升组）

```
桥 unbox（执行完成之后、窗口重置之前）：
  retType=12 → 提升「闭包自身槽 + 全部句柄型捕获」= 原地迁出（ID/gen 不变、不重用）
             → 解包为 JitClosureId（宿主值）
宿主: JitClosure(f, cid).call<T>(args) → 新桥调用（新 ctx；locals[0]=闭包句柄 → 闭包帧）
      卸载后调用 → 19（site=-1）；close() → 计数 −1、归零释放
豁免：调用 try/finally 清理不释放提升槽（唯一释放路径 = close）；路径 A 常量不入组
捕获描述符：前端静态给出（不入 .fbc、无格式变更）
```

### 7.5 宿主对象实参（三方向）

```
② 源入口实参：call 入口 Marshal「注册类 C 行」→ is C（含子类）→ pin(tag=11) → cell；null → 19
③ 槽 14 链内：CALL_FUNC 逐参签名静态校验；被调帧窗口存活；出口 retType=14 交付
④ HostClosure 签名含 14：验签覆盖具体类；H63 逐参 fetch→实例引用；R=14 → 窗口登记 1 槽
```

### 7.6 反射注册流

```
Compiler.registerType<User>() → ReflectRegistrar：枚举 public 成员（字段/属性/方法/静态/构造器）
  → 生成 PublicField/PublicMethod/PublicCtor + 反射访问器（H64/H65 的宿主实现据此解析）
  → 注入 ClassRegistry（快照）→ 之后 compile 的前端据此解析 `u.f`/`u.m()`/`User(…)`
  → 字节码/JIT 路径零反射（I2 / 决策 ④ 不变）
```

---

## §8 兼容矩阵与版本规则

| 产物 \ 加载器 | M1（verMajor 1） | M2（verMajor 2） |
|---|---|---|
| verMajor 1 产物 | ✓ 全语义 | ✓（按 M1 规则集校验；CALL_HOST 未启用 ⇒ 不可能出现） |
| verMajor 2 产物 | ✗ 加载期拒绝（18） | ✓ |

- LocalType 合法集按 verMajor 分派：M1=0–12；M2=0–14；15–255 恒拒。
- 不变项：ctx 布局、帧布局、全部 M1 指令语义、fail-fast、窗口/逃逸机制、W^X/IBT、卸载状态机。
- M2 零格式变更面：§14 捕获描述符不入 `.fbc`、§15 构造不新增指令/helper、§16 不新增指令/helper、§12.5 注册项不入 `.fbc`（注册快照属宿主侧资产；含 14 形参/成员访问/构造的单元经**无注册表分发入口** → 加载期拒绝）。

---

## §9 设计决策

| 决策 | 理由 |
|---|---|
| HostClosure/HostObject 走**句柄条目标签扩展**（10/11），不新设机制 | 决策 ④ 复利：句柄表天然能存函数值与对象引用；生命周期（B pin/try-finally）零新逻辑 |
| **静态性下沉到类型层**：CALL_HOST 调用点按声明类型静态发射；运行期只有一次表取值 | 消解「静态性丧失」困难（无需运行期回调注册表——句柄表即回调表） |
| 验签一次性 + 缓存于条目；禁高阶双重强制（前端 + 验签复检） | CALL_HOST 执行期零验签；签名描述符深度恒 1 |
| H65 变更型路由复用 §9.15 三条规则 | 一致性；`host_set_field` 进汇编期触发清单 + flags.bit0 + 兜底 99 |
| 逃逸闭包回桥选**原地提升**（不复制不改址） | 与 M1 机制最同构；编号不变 ⇒ 已分发副本自动续命、无同对象两编号 |
| 包装器**必须显式 `close`** | ID 无引用计数、GC 不通知桥（M1 §8.1 规则 6② 同理） |
| 构造经**预定义函数通道**（user helper） | 零新指令/helper/格式；构造执行体恒在宿主侧（I2 不变） |
| 反射仅在注册期 | 字节码/JIT 路径零反射；访问器是宿主黑盒（`flags.bit0` 保守判定） |
| `static var` / `static mut prop` **永久排除** | 隐藏全局态破坏可重复性/差分/并发纪律（附 B 四条论证） |
| **验签口径 = 单次 `is (T1..Tn) -> R`**（语言子类型语义） | 运行期取不出函数类型的分量（`is` 只给 bool），"参数个数/逐参/返回"分步核对既冗余又**不可实现**；单次判定与仓颉语义（入参逆变/返回协变）一致，且**禁高阶**由 `R` 取具体非函数类型自然承接（2026-10-11 裁定方案 a，已实测） |
| 逃逸闭包 ID 的宿主值类型命名 **`JitClosureId`**（原名 `CFunc`） | 避免与仓颉**内建** C 函数指针类型 `CFunc<F>`（FFI）同名遮蔽；`JitClosureId` 直述语义（承接逃逸闭包句柄 ID），与 `JitClosure`（包装器）成对 |

---

## §10 待裁定 / 开放钉子

| # | 项 | 状态 |
|---|---|---|
| M2-1 | P1（`is` 对函数类型的运行期判定）落地确认 | **已实测确认（2026-10-11）**：WSL Ubuntu-24.04 + SDK 1.3.0-alpha，`is` 支持函数类型（入参逆变/返回协变成立、捕获闭包命中、非函数值不命中），动态调用经类型模式绑定；**结案**——主线验签成立，§6.1.5 强类型入口降为备用 |
| M2-2 | 逃逸闭包回桥的**容器内部表示**（句柄型 cell ⇒ 提升需级联图遍历；对象引用 ⇒ 免级联） | 与 M1 v0.18「容器构造 + 逃逸返回」元素寿命表述一并裁定（m2 §14.6） |
| M2-3 | 逃逸闭包回桥渐进交付：第 0 步（值型捕获 + 路径 A 常量捕获，免提升）→ 第 1 步（句柄型捕获 = 提升组） | 按 §14.7 两步走 |
| M2-4 | 类注册表的「注册期冲突」边界（类名 vs 内建类型名/关键字/已注册函数名/类名） | 规格已定「拒绝」；拒绝消息体例实施时定 |
| M2-5 | 第三档（高阶 + 异常对象回译） | **冻结**（实现时机无限期推迟；重议条件见 m2 §13-2） |
| M2-6 | 跨进程回调注册协议 | **永久排除**（m2 §13-3） |
| M2-8 | **`callWith<Fn>` 返回的 `JitFunction` 与 §6.1.4 `JitClosure` 的关系** | 待澄清：① 同一载体（`JitClosure` 并入/更名 `JitFunction` 的闭包视图，含 `close`）；② `JitFunction` 为载体、`JitClosure` 持之（`close` 归属需定）；③ 两者并存（语义重叠，不建议）。**无论取何形态，释放协议不变**（提升组计数 −1 = close）；实施前定 |
| M2-7 | **规格内部张力对账**：m2 §12.4「继承成员不解析（仅本类声明成员）」vs §12.5/§13-5②「继承成员访问器经反射按继承关系逐级向上解析（v0.8.25，已定位）」 | 设计口径：**糖按本类声明解析**（前端只认注册的字段/方法表）；宿主侧访问器（反射生成）可覆盖继承成员——两者不矛盾（**解析点不同**：前端 vs 宿主反射）；建议规格在 §12.4 行 369 补限定说明 |
