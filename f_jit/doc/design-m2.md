# f_jit 详细设计 · M2 增量（verMajor 2：宿主互操作）

> 依据：`jit-bytecode-m2.md` v0.8.28（同目录）。本文只写 **M2 的增量与受影响面**；未提及的包、声明、成员一律沿用 `design-m1.md`。
> 版本口径：`.fbc` **verMajor 2**（verMinor 0）；M1（verMajor 1）产物语义与加载路径**完全不变**；M2 包含六篇增量（§0–§10 CALL_HOST 宿主闭包、§11 HostObject 通道、§12 成员访问、§14 逃逸闭包回桥、§15 字节码侧构造、§16 宿主对象实参）。
> 附录（文末）：**M2 增量三表**（附 A 语法 → 字节码 · 附 B 指令定义增量 · 附 C 字节码 ↔ 机器码增量）；M1 全量三表见 `design-m1.md` 附录。

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
| HostObject | 宿主自定义类一律 19 | token 11 / LocalType 14（不透明引用；持有/转发/返回/字段读写/构造）；**JSON 谱系（M3 §11，v0.8.30）：内建码 16–19、零注册、不适用本节** |
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
| `base` | `ClassDescriptor`、`PublicField`、`PublicMethod`、`PublicCtor`、**`RegistrationException` + `RegistrationRejectKind`（v0.8.32）** | `LocalType`（+2 常量）、`TypeToken`（+2）、`ErrCode`（+21 与描述）、`Version`（+M2 版本常量） | 全部值/异常类型（JitException 构造语义不变）；**注册期拒绝异常不占 ErrCode**（宿主侧，见 m2 §12.5） |
| `bytecode` | — | `OPCODE_TABLE`（0x79 行）、`FbcReader`（verMajor 分派）、`LocalTypes.validate`（按 verMajor 合法集） | 容器头字段、段模型、crc32、kind 1–10 |
| `compiler` | `TypeRef`、`ClassRegistryView` | `NameResolver`（解析顺序 + 冲突拒绝）、`Lowerer`（CALL_HOST/成员访问/构造/14 槽）、`AstExpr`（+4 构造器）、`DefiniteAssignment`（14/13 槽规则同型） | 词法、语法基座、既有降低模式 |
| `runtime` | `HostCallback`、`SignatureDescriptor`、`SignatureVerifier`、`PromotionGroup`、H63/H64/H65（顶层 @C func） | `HandleTable`（条目标签 10/11）、`IterTable`（不变）、`DbgDump`（**大类名呈现**：13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`——2026-10-11 裁定） | ctx、迭代器、既有 helper 语义 |
| `fountain::f_jit`（根） | `ClassRegistry`、`JitClosureId`、`ReflectRegistrar` | `Compiler`（+2 成员）、`CallMarshal`（+行）、**`JitFunction`（+`callForFn<Fn>`、闭包包装的 `unloadFn`/`isClosed`——M2-8 裁定：不另设包装类）** | 执行六步、卸载状态机、去重缓存 |

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
| `let type: UInt16` | LocalType 编码 0–14（v0.8.20：9=Regex 并入）；**M3 起扩至 0–19**（15=Any、16–19=JSON——见 design-m3 附 B） | — |
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
| `FbcReader` 加载规则集分派 | ① `verMajor=1` → M1 规则集（LocalType 0–12、无 CALL_HOST）；② `verMajor=2` → LocalType 0–14、CALL_HOST 合法；③ M1 加载器遇 verMajor 2 → 18；**M3（verMajor 3）：合法集 0–19**（15=Any、16–19=JSON——见 design-m3 附 B） | m2 §9.2 |
| `LocalTypes.validate` | 合法集按该单元的 verMajor 取（1：0–12；2：0–14；**3（M3）：0–19——15=Any、16–19=JSON**；**20–255 恒拒绝**） | m2 §2 |
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
| `func registerType<T>(into: ClassRegistry, diag: DiagnosticsSink): Unit where T <: Object` | 经 `std.reflect` 枚举 public 成员（`let/var`、`prop/mut prop`、`func`、`static let/prop/func`、**constructors**）批量生成 `ClassDescriptor`；逐成员尽力注册（`static var`/`static mut prop` 跳过（附 B）、支撑面外类型跳过、命名冲突跳过），跳过项记 diagnostics；**反射仅在注册期——字节码/JIT 路径零反射**；关闭反射的构建 → 明确报错；**JSON 谱系类（`JsonValue`/`JsonObject`/`JsonArray`/`JsonNull`）拒绝注册** → **明确报错**（v0.8.29；成员面经 m3 §11 预定义函数通道，避免「成员 vs 键」二义）；**v0.8.30 补**：JSON 为 M3 **内建码 16–19**（零注册、可作形参/返回/局部），注册条目对其**永不匹配**（哑火） | m2 §12.5 |
| `func mapType(info: TypeInfo): ?UInt16` | 反射类型 → LocalType（值型 0–3 直映；std 句柄类型按 §3.2 名映射 4–11；其余类 → 14 + typeRef（**JSON 谱系类除外：不映射 14，且 `registerType` 明确报错**——v0.8.30）；不可映射 → 跳过） | m2 §12.5 |
| `func buildCtor(info: ConstructorInfo): ?PublicCtor` | 构造器自动适配器（`ConstructorInfo.apply` 为后盾；参数不可映射 → 跳过 + 诊断；泛型类按具体实例化） | m2 §12.5/§15 |
| （生成物命名约定） | 实例 prop getter 名 = 成员名；`mut prop` setter 名 = `set` + 首字母大写；静态包装名 = 成员名；方法 bind 内部名含 `.`（源不可直呼）；命名冲突 → 跳过 + 诊断 | m2 §12.5 |

**注册期拒绝（v0.8.32，M2-4 结案）**：`public class RegistrationException <: fountain::f_base.BaseException`——`init(kind: RegistrationRejectKind, name: String, occupiedBy: ?String)`、字段 `kind` / `name` / `occupiedBy`、`super(message)` 转发三段消息（kind 说明 + occupiedBy + 固定 hint）；`public enum RegistrationRejectKind { | DuplicateClass | FunctionNameClash | BuiltinTypeName | Keyword | JsonFamily | ReflectionUnavailable }`。**只在宿主侧**：在注册调用栈内抛出（不经字节码 / JIT / 解释器、**不占 `ErrCode`**、不入 `.fbc`、不进三引擎差分）；抛出点 = `ClassRegistry.register` / `Compiler.registerClass` / `ReflectRegistrar.registerType`；**不登记**（注册表不变、快照语义不受影响）。体例见 m2 §12.5。

#### 6.1.3 `JitClosureId`（public struct，逃逸闭包 ID 的宿主值类型）

**更名（2026-10-11）**：本类型原名 `CFunc`——与仓颉**内建**的 C 函数指针类型 `CFunc<F>`（FFI：`foreign func` / `@C` / `CPointer` 互转、调用需 `unsafe`）**同名**，在本模块满是 `@C` helper 的语境下极易误读。现名 **`JitClosureId`** 直述语义：承接逃逸闭包句柄 ID 的宿主值类型，与闭包包装（`JitFunction.callForFn` / `close`，M2-8）成对。

| 成员 | 意义 | 锚点 |
|---|---|---|
| `let id: Int64` | 承接逃逸闭包句柄 ID（已提升出窗口；ID 稳定至 `close`） | m2 §14.3 |
| `static const INVALID: Int64 = 0` | 无效值（防御） | — |

#### 6.1.4 `JitFunction` 的**闭包包装**增量（M2-8 裁定：不另设包装类）

**裁定（2026-10-11）**：逃逸闭包的宿主承接**统一用 `JitFunction` 包装**——桥从 JIT **取回**的闭包与 JIT **产出**的闭包是**同一种东西、同一个表示**（`JitClosureId` 承载，见 §6.1.3），因此**一个类型足够**，**原 `JitClosure` 定义撤销**。包装实例由**桥内部构造**（宿主不直接构造），内部持「单元 + `JitClosureId`」（**单元弱语义**：不阻止卸载，§14.4）。

| 成员（`JitFunction` 增量） | 意义 | 调用关系 |
|---|---|---|
| （桥内部）包装构造 | 绑定单元 + 闭包 ID | `CallMarshal` 解包 `retType=12` 与 `callForFn<Fn>` 两条路径产出——**产物类型一致** |
| `func call<T>(args: Array<Any>): T` | **闭包包装实例上**：新桥调用（新 ctx + `locals[0]` = 闭包句柄 → **闭包帧格式**）；结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=-1）；**新 ctx 的分配/释放沿用 M1 选型 `std.core.LibC.malloc<T>` / `LibC.free<T>`**（design-m1 §5.3.1）。**入口实例上语义不变**（M1 §8.2 六步，M1 零回归）——**帧格式由实例的绑定内容决定** | m2 §14.3/§14.4 |
| `func close(timeoutMs): Bool` | **包装实例**：释放该函数值的提升组（计数 −1、归零释放、幂等），单元与编译缓存不受影响；先排空**本闭包**在飞调用，超时回退为可用并返回 `false`。`unloadFn(timeoutMs)` 为**私有**实现，不对外暴露。**单元进入终态时级联释放登记在册的全部逃逸闭包（含未承接的组）** | m2 §14.2/§14.3 |
| `prop isClosed: Bool` | 闭包包装：是否已 `unloadFn`（属性名保留旧称，描述状态而非操作）；**非闭包包装实例恒 `false`** | — |
| `close` / `isClosed` | **`Resource` 契约**（`std.core.Resource`）：入口实例 `close(timeoutMs)` 卸载**单元**（闭包逃逸**不阻止**卸载，§14.4）；包装实例 `close(timeoutMs)` 释放本闭包；`close()` 为不等待版本（Unit） | m1 §8.7 |

#### 6.1.5 `JitFunction.callForFn<Fn>`（返回闭包的强类型入口，条件启用）

**更名（2026-10-12）**：原名 `callWith`。语义是「**调用单元、取回它返回的闭包**」（返回方向、retType=12；*不是*「调用闭包取值」）——`callForFn` 直述「调用以取回」，全文档（含规格与计划）同步。

**语义（2026-10-11 澄清）**：**调用 JIT 单元 → 取回它返回的闭包 → 交给宿主**（返回方向，§14 / retType=12）；**不是**"调用一个闭包并取值"。宿主拿到的是**可继续调用的 `JitFunction`**，而不是原生函数值——因此不需要 `Any → Fn` 这类**运行期函数类型判定**，这才是它在 P1 不可用时的兜底价值。

| 成员 | 意义 | 锚点 |
|---|---|---|
| `func callForFn<Fn>(args: Array<Any>): JitFunction` | `Fn` = **返回闭包的函数类型**（编译期已知）；调用单元并返回承接该闭包的 `JitFunction`（其 `call<T>` 路径照旧）；签名/解包零运行期判定；与 `call<T>` 并存 | m2 §9.1/§14 |

**释放协议**：返回闭包属逃逸提升组，其计数释放走 **`JitFunction.close()`**（M1 §8.1 规则 6②、§14.2；M2-8 裁定：包装统一为 `JitFunction`，不另设包装类）。

**实参面与 `call<T>` 一致（2026-10-11 补充）**：`args` 的元素按 §4 Marshal 表处理——值型 / 句柄型（含 §11 注册类实例）/ **宿主闭包**（声明为 HostClosure 形参 → §4 验签 → 回调表登记 tag=10 → ID）**均允许**。本入口只改"**返回闭包的承接形态**"（交宿主 `JitFunction` 而非原生函数值），**不改实参面**。

**推论（诚实登记）**：P1 不可用的环境里，`args` 中的闭包实参与主线一样不可用——该限制属 §9.1 面，不因 `callForFn` 而改变；此时 `callForFn` 的价值仅落在"**返回方向**免运行期判定"。

**包装值不作实参（2026-10-11 裁定）**：`callForFn` / §6.1.4 包装产出的 `JitFunction` 是**桥侧包装（类实例）**，**不能直接作实参**——§4 参数 Marshal 行只接受**仓颉函数值**，直接传入 → 不是函数值 → **19**；**不为此新增 Marshal 行**（新增等于给包装开一条绕过验签的旁路，并把签名归属与生命周期复杂度引进来）。

**回传的正确写法**：宿主在**自己一侧包一层闭包**（捕获该 `JitFunction`）再作为实参传给另一个 JIT 单元——该闭包是**原生函数值** ⇒ 走 §4 验签（tag=10）⇒ ID；其体内对 JIT 产物的调用属 **§5 已冻结的重入语义**（合法：新 `ctx`、独立事务、内层 fail-fast 不影响外层）。三处须留意：① 包装闭包的**签名**必须与声明形参相容（按 §4 单次 `is` 判定）；② 被捕获的单元**卸载后**调用 → **19（site=-1）**（弱语义同 §14.4）；③ 包装闭包**返回值不得为闭包**（禁高阶：R ∈ 0–8/10–11/14）——即往返只打通**实参方向**，"经闭包把闭包带回来"仍无路径。

### 6.2 既有声明的新增/变更成员

| 声明 | 增量 | 锚点 |
|---|---|---|
| `Compiler` | `func registerClass(desc: ClassDescriptor): Unit`；`func registerType<T>(): Unit where T <: Object`（内部转 `ReflectRegistrar`） | m2 §12.4/§12.5 |
| `CallMarshal` | ① **参数 Marshal 表** + 行：声明类型 = 注册类 C → `is C`（含子类、opaque 视图）→ `pin`（tag=11）；null → 19；HostClosure 声明 → 验签（**单次 `is (T1..Tn) -> R`**，§4）→ 回调表登记（tag=10）；② **解包表** + 行：`retType=12 → JitClosureId`、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 宿主类实例引用`；③ Closure 行**仅返回方向**（参数方向不加行） | m2 §4/§14.3/§16.2 |
| `JitFunction` | 内部状态扩展：`ClassRegistry` 快照、`PromotionGroup` 表（per-call 逃逸闭包）、`JitClosureId` 登记；`callForFn<Fn>` 公开变体；**`unloadFn`/`isClosed`（闭包包装，M2-8 裁定并入）** | m2 §9.1/§14 |
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

**边界（2026-10-12；v0.3.18 裁定）**：接收者静态类型为 **JSON 谱系**时，点号**不查本表**——由 m3 §11 接管，**成员优先 → 键兜底**（成员表 = 宿主库**预定义函数通道**〔首参 = **JSON 码 16–19**〕，**非**本注册表）：命中成员 ⇒ M2 §12.4 糖；未命中 ⇒ JSON 键访问（`o.k` ≡ `o['k']`）。**`Any`(15) 盒**上点号 = 成员命中（按成员所属类插 `as`）否则键访问（自动 `as JsonObject`，失败 **22**）；`JsonValue`/`JsonArray`/`JsonNull`/标量上取键 → **编译错误**。**已裁定**：`registerType<T>()` 对 JSON 谱系类 **明确报错**（m2 §12.5 v0.8.29/30；v0.8.30 起 JSON = **M3 内建码 16–19**——与 14 面结构性无关、零注册）——`o.size` 无二义（点号取成员、`o['size']` 取键）。同一 `MemberAccess` 节点、**按静态类型分派**，互不重叠。

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
宿主: 闭包包装实例（`JitFunction`）.call<T>(args) → 新桥调用（新 ctx；locals[0]=闭包句柄 → 闭包帧）
      卸载后调用 → 19（site=-1）；close() → 计数 −1、归零释放
豁免：调用 try/finally 清理不释放提升槽（唯一释放路径 = close）；路径 A 常量不入组
捕获描述符：前端静态给出（不入 .fbc、无格式变更）；**级联：无**（容器内部表示 = 宿主对象 ⇒ 槽级提升，m2 §14.6 已裁定）
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

- LocalType 合法集按 verMajor 分派：M1=0–12；M2=0–14；**M3=0–19**（15=Any、16–19=JSON）；**20–255 恒拒**。
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
| 桥侧包装（`JitFunction`）**不作实参**——闭包往返由**宿主侧包一层闭包**表达 | 包装是类实例、非函数值（§4 只接受仓颉函数值 ⇒ 直接传 → 19）；为此新增 Marshal 行等于绕开验签并引入签名归属/生命周期复杂度；宿主一层 lambda 已能表达，其体内调用 JIT 产物属 §5 已冻结的重入语义（2026-10-11 裁定） |
| 逃逸闭包 ID 的宿主值类型命名 **`JitClosureId`**（原名 `CFunc`） | 避免与仓颉**内建** C 函数指针类型 `CFunc<F>`（FFI）同名遮蔽；`JitClosureId` 直述语义（承接逃逸闭包句柄 ID），与闭包包装（`JitFunction`，§6.1.4）成对 |
| 逃逸闭包的宿主承接**统一用 `JitFunction` 包装**（撤销 `JitClosure`） | 桥从 JIT **取回**的闭包与 JIT **产出**的闭包是同一表示（`JitClosureId` 承载）⇒ **一个类型足够**；`close`/`isClosed` 作为 `JitFunction` 的 M2 增量（非闭包实例：`close` → 19、`isClosed` = false）；`unload` 保持**单元级**不变（M1 零回归）；避免「两个包装类型 + 语义重叠」（2026-10-11 裁定，M2-8 结案） |

---

## §10 待裁定 / 开放钉子

| # | 项 | 状态 |
|---|---|---|
| M2-1 | P1（`is` 对函数类型的运行期判定）落地确认 | **已实测确认（2026-10-11）**：WSL Ubuntu-24.04 + SDK 1.3.0-alpha，`is` 支持函数类型（入参逆变/返回协变成立、捕获闭包命中、非函数值不命中），动态调用经类型模式绑定；**结案**——主线验签成立，§6.1.5 强类型入口降为备用 |
| M2-2 | 逃逸闭包回桥的**容器内部表示**（句柄型 cell ⇒ 提升需级联图遍历；对象引用 ⇒ 免级联） | **已结案（2026-10-11）**：容器内部表示 = **宿主对象**、元素 = **原生值/对象引用**（非世界 ID；12/13 禁存容器已移除"容器内驻留世界 ID"这一前提）⇒ 提升组是**槽级**动作、**免级联**；**与 M1 v0.18 元素寿命表述的捆绑已解除**（m1 §3.3/§8.1 随动句已补）。级联的再触发条件见 m2 §14.6 |
| M2-3 | 逃逸闭包回桥渐进交付：第 0 步（值型捕获 + 路径 A 常量捕获，免提升）→ 第 1 步（句柄型捕获 = 提升组） | **已定稿（2026-10-11，设计结案）**；实施按 §14.7 两步走（**第 0 步先行**）。两步的边界 / 交付面 / 逐步验收见 m2 §14.7（捕获项按 §8.1 路径分为"恒有效"（值型 / 路径 A）与"窗口失效"（路径 B / C）两类；第 0 步 = 免**提升组**而非免"迁出"，`close` 协议与白名单拒绝面均属第 0 步；第 1 步增量 = 整组提升 + `PromotionGroup` + 唯一释放路径 = `close`；级联已结案 ⇒ 无额外成本）。**实施清单映射**：第 0 步 → plan-m2 `Q3.9`（前端捕获描述符 + 白名单拒绝）/`Q5.5`–`Q5.7`（`JitClosureId`、包装器 `call`/`close`）/`Q5.9`（解包行 `retType=12`）/`Q6.6`（T49 第 0 步面）；第 1 步 → `Q4.9`（`PromotionGroup`）/`Q4.10`（`moveOutGroup` 协作）/`Q3.10`（放开拒绝面） |
| M2-4 | 类注册表的「注册期冲突」边界（类名 vs 内建类型名/关键字/已注册函数名/类名） | **已结案（2026-10-13，规格升 v0.8.32）**：**载体 = 宿主侧独立异常 `RegistrationException <: f_base.BaseException`（public）**——理由：① **只在宿主侧**（注册调用栈内抛出，不经字节码 / JIT / 解释器、不跨桥、世界内无注册面）⇒ 天然不进 `.fbc` / 三引擎差分；② **不占运行期 `ErrCode`**（0–23 是「世界内执行」的码，注册期不属该路径）；③ diag 不承担错误通道（D1）⇒ 硬失败必须走异常。**体例**：`kind`（`DuplicateClass`/`FunctionNameClash`/`BuiltinTypeName`/`Keyword`/`JsonFamily`/`ReflectionUnavailable`）+ `name` + `occupiedBy`；消息三段 + 按 kind 固定 hint；**编译期可判优先**、否则注册期抛且**不登记**；**拒绝 ≠ 跳过**（成员名冲突仍走「跳过 + `RegistrationSkipped`」）。落点：m2 §12.4（指针）/§12.5（体例段）/§15/§16、本文 §2/§6.1.2、`plan-m2` Q5.2/Q5.4 |
| M2-5 | 第三档（高阶 + 异常对象回译） | **冻结**（实现时机无限期推迟；重议条件见 m2 §13-2） |
| M2-6 | 跨进程回调注册协议 | **永久排除**（m2 §13-3） |
| M2-7 | **规格内部张力对账**：m2 §12.4「继承成员不解析（仅本类声明成员）」vs §12.5/§13-5②「继承成员访问器经反射按继承关系逐级向上解析（v0.8.25，已定位）」 | **已结案（2026-10-13，规格升 v0.8.31）**：设计口径不变——**前端**按**注册表内容**解析（不按继承谱系上溯、不维护类继承图）；**宿主侧**访问器/反射**可**按继承关系逐级向上（v0.8.25）——**解析点不同，不矛盾**。**规格已落**：§12.4 行 386 补「继承成员（限定说明）」+ §12.5 继承行加前端回指；用例把关见 plan-m2 Q3.3/Q3.6/Q6.5。**口径要点**：入表（含反射覆盖面）→ 糖可绑定；未入表 → **编译错误** |
| M2-8 | **`callForFn<Fn>` 返回的 `JitFunction` 与 §6.1.4 `JitClosure` 的关系** | **已结案（2026-10-11）**：**统一用 `JitFunction` 包装，撤销 `JitClosure` 定义**——从 JIT 取回的闭包与 JIT 产出的闭包是**同一表示**（`JitClosureId`），一个类型足够；`close`/`isClosed` 并入 `JitFunction`（非闭包实例：`close` → 19、`isClosed` = false）；`unload` 保持单元级（M1 零回归）；两条产出路径（`CallMarshal` 解包 / `callForFn`）产物类型一致。落点：§1 / §6.1.4 / §6.1.5 / §6.2 / §7.4 / §9 / §10；规格 §14.3；plan-m2 Q5.6/Q5.7/Q5.11 |
| M2-9 | **JSON 谱系类拒绝 `registerType<T>()`（2026-10-12，跨篇裁定，用户要求）** | **已实施**（m2 规格升 **v0.8.29**）：`registerType<JsonValue`/`JsonObject`/`JsonArray`/`JsonNull>()` → **明确报错**（沿 §12.5「关闭反射的构建 → 明确报错」同型形态：宿主侧编译期可判优先、运行期路径则注册期报错且**不登记**）。理由：① JSON 成员面唯一来源 = 宿主库**预定义函数通道**（首参 = 接收类 ⇒ 成员归属，m3 §11）；② 反射注册会与之形成 `o.size` 的「成员 vs 键」二义；③ JSON 类无公有字段 / 构造器可注册（连带：`JsonObject(…)` 类构造写法 → 编译错误）。落点：m2 §12.4/§12.5、本文 §2/§7.2、plan-m2 Q5.2/Q5.4；配套点号分派见 design-m3 §10 **M3-10**。**更新（v0.8.30，跨篇 m3 §11 用户裁定）**：JSON 谱系已升格为 **M3 内建句柄码 16–19**——零注册（可作参数 / 返回 / 局部 / 签名），不经注册表、**不触发**无注册表分发拒绝面（该面限定 14）⇒ 本条理由升级为「结构性无关 + 防哑火」 |

---

## 附录：M2 增量三表（语法 → 字节码 · 指令定义 · 机器码对照）

**口径**：与 `design-m1.md` 附录相同——**权威文本是规格 `jit-bytecode-m2.md`**（`§` 均指该规格章节），本附录为同源整理，冲突以规格为准。**本附录只列 M2 增量**；M1 全量三表见 `design-m1.md` 附 A/附 B/附 C，M3 增量见 `design-m3.md` 附录。

## 附 A M2 语法元素 → 字节码（增量）

| 语法元素 | 源形式（示例） | 降低产物（要点） | 关键指令 | 锚点 |
|---|---|---|---|---|
| 宿主闭包形参 / 局部 | `fn: (T1..Tn) -> R` | 声明即**静态类型 13** ⇒ 调用点按声明类型静态判定、**无运行期查找**；参数/局部槽 = 1 cell 句柄 | — | §3 |
| 宿主闭包调用 | `fn(a1, a2)` | 实参**从左到右**入栈 → `LOADL fn`（句柄压栈底）→ `CALL_HOST 2` + 汇编器自动尾随 `CHECK_ERR`（I3）——与内部闭包调用（`LOADL 0` + `CALL_CLOSURE`）**完全平行** | `0x79` | §3 |
| 名字解析顺序（扩展） | — | `recursive → user helper → HostClosure 形参/局部（静态类型驱动）→ 未定义异常`；**与已注册 user helper 同名 → 编译错误**（禁止静默择一） | — | §3 |
| HostClosure 实参来源 | — | 只能来自**桥 Marshal**（宿主传入）或 `CALL_FUNC` 链内传递——**字节码内不可构造**（纯消费者） | — | §3 |
| 成员读（值型字段） | `u.f` | `get_field(u, idx)`（H64）——纯读、**零登记** | H64 | §12.2/§12.4 |
| 成员读（句柄型 / 14 / 13 字段） | `u.f` | 同上（H64）——**条件分配型**（句柄型字段登记 1 槽） | H64 | §12.2 |
| 成员写 | `u.f = v`（`var` 字段） | `set_field(u, idx, v)`（H65）——**变更型**（§9.15 全路由 + 含它函数 `flags.bit0`）；`let` 字段写 = **编译错误**（裸 H65 防御 → 19） | H65 | §12.2/§12.4 |
| 成员调用 | `u.m(a…)` | 降级为**预定义调用** `m(u, a…)`（§12.1 包装模式；hid 由方法表解析）——同一路径、黑盒判定不变 | `CALL_HELPER <hid>` | §12.4 |
| 链式成员访问 | `u.a.b`、`u.m().f` | 每层类型由注册表/签名提供（14 型字段的 `typeRef` 支撑链式解析）；13 型字段读后按既有闭包调用语法使用 | — | §12.4 |
| 字节码侧构造 | `C(args…)` | **物化为单元私有预定义函数**（user helper；可经 `registerType<T>()` 反射自动生成）⇒ `CALL_HELPER <ctor-user-hid>` + 自动 `CHECK_ERR`；结果 = **新** HostObject 句柄（分配型，每次求值 = 一个新对象）；**零新指令 / 零新 helper / 零格式变更** | `0x75`（hid ∈ `[0x0100,0xFFFF]`） | §15 |
| 源入口实参含宿主类 | `call<User>(u)` | call 入口 Marshal 增行：`is C` → pin → cell（失败 19）；`null` → 19 | —（桥） | §11、§16 |
| 源入口形参（opaque）与槽 14 链内传递 | `fn(u: User)` | 参数槽 14 沿 `CALL_FUNC` 链传递（同 12/13 规则）；转发给预定义函数时桥核对 `obj is <声明类>`（不符 19） | — | §16、§11 |
| 返回宿主对象 | `retType=14` | 解包表：`get` → 宿主类实例引用（引用原样返回、零拷贝）；`T` 校验由 `call<T>` 单态化适配器承担 | —（桥） | §11 |
| HostClosure 签名含 14 | `(T1..Tn) -> R`（T/R 含 14） | 同上宿主闭包调用；H63 逐参 `get`、`R=14` 时**窗口登记 1 槽** | `0x79` + H63 | §5、§16 |
| 逃逸闭包回桥 | 返回 `(T1..Tn) -> R` 值 | 解包表开放 Closure 行 → **`JitClosureId` + `JitFunction` 包装**（M2-8：不另设包装类）；**第 0 步** = 免提升组（闭包槽 1 个仍按 M1 §8.1 规则 1 迁出）、**第 1 步** = 整组提升（`PromotionGroup`）；**唯一释放路径 = `close`**；卸载后调用 → 19（site=-1） | —（桥 + H54/H55/H57） | §14 |
| 反射自动注册 | `Compiler.registerType<T>()` | **编译期动作、不产生字节码**：经 `std.reflect` 枚举 public 成员 → 自动生成字段表 / 方法绑定 / 构造器条目（快照语义同 §8.4） | — | §12.5 |
| M3 增量 | `Any` / JSON / 转发特化 | 见 `design-m3.md` 附 A | — | — |

## 附 B M2 字节码增量定义

| 项 | M1 | M2 增量 | 锚点 |
|---|---|---|---|
| `CALL_HOST`（0x79） | 汇编期 `ERR_NOT_IMPL`（M1 从未产出该 opcode） | **启用**：操作数 = **`u8 argc`**（M1 预留的 `u16 fid` 编码**废弃**）；栈布局 `[h_fn, a1..an]`；类别 `CAT_CALL`；汇编器自动尾随 `CHECK_ERR` | §2、§5 |
| LocalType | 0–12 | **+13 = HostClosure、+14 = HostObject**（均句柄型；15–255 仍拒绝）；**（M3 续：+15=Any、+16–19=JSON——见 design-m3 附 B）** | §2 |
| 类型 token | 1–9 | **+10 = HostClosure、+11 = HostObject**（`IS_TYPE`/`GUARD_TYPE`/H19 与句柄槽 `tag` 可用） | §2 |
| 错误码 | 0–20、23 / -1 / -2 / 99 | **+21 `ERR_HOST_EXCEPTION`**：宿主侧调用面执行期异常且未回译（闭包 §5 / 预定义与包装 §8.4、§12.1 / 构造适配器 §15 / 成员访问器 §12.2、§12.5）；`cause` = 原始异常全文（含完整仓颉栈，桥打印）；`site` = 调用指令偏移；`99` 收窄为**引擎侧**兜底 | §2 |
| 19 语义 | 参数长度 / 元素类型 / 返回 T 不符 / 调用已卸载单元 | **+验签失败**（site=-1） | §2、§4 |
| 常量 kind | 1–10 | **不新增**（HostClosure / HostObject 均**不可常量化**） | §2、§11 |
| 句柄条目 tag | 1–9（既有） | **+10（HostCallback：`{fn, sig, ti?}`——`ti` = 反射签名元数据缓存）、+11（HostObject：`{obj}`）** | §1、§5、§11 |
| helper | H01–H62、H69–H72 | **+H63** `host_call_trampoline`、**+H64** `host_get_field`、**+H65** `host_set_field`（编号接 H63；**63–68 为 M2/M3 保留区**） | §5、§12.2 |
| 分配型清单 | 既有 | **+H64**（句柄型字段读）、**+H63**（R 为引用型时登记 1 槽） | §5、§12.2 |
| 变更型清单 | H43–H48 | **+H65**（§9.15 全路由：常量禁写自然满足 / deopt 禁令 `flags.bit0` / 防御兜底 → 99） | §12.2 |
| user helper 通道 | 源入口预定义函数 | **复用**：`C(args…)` 的构造适配器物化为**单元私有预定义函数**（hid ∈ `[0x0100,0xFFFF]`，注册期确定 trampoline）；无注册表的 `.fbc` **加载期拒绝** | §15、m1 §5（0x75 行） |
| 版本 | verMajor 1 | `.fbc` 头 **verMajor 2**：M1 加载器遇 2 → 加载期拒绝（18）；M2 加载器兼容 1（按 verMajor 分派校验规则集） | §2 |

**H63 `host_call_trampoline` 执行流（§5）**：fetch 栈底句柄 → `HostCallback{fn, sig}`（tag≠10 → 8）→ 按 `sig` **逐参 cell → 仓颉值**（解释性 marshal；句柄型 `get` / 值型原值）→ 调用 `fn`（① 可能触发 GC——与 M1 helper 同一边界；② 可能抛仓颉异常 → `catch-all` → **21 + cause**，fail-fast 写槽返回；③ **可能重入 JIT**——合法，开新 ctx、独立事务）→ 返回值 → cell（R 为引用型 → 窗口登记 1 槽；值型 → 原值返回、不登记）。

**验签（Marshal 时一次性；产物缓存）**：**`FunctionTypeInfo.of(value)` 取真实签名后逐位比对**（v0.8.33 实施订正——原「单次 `is (T1..Tn) -> R`」语言上不可实现：`T`/`R` 是运行期数据、`is` 右侧须静态类型，物化路径为 11^(n+1) 分支）→ 元数、逐参、返回一次覆盖；**14 位置按具体类名逐字相等**；**`Nothing` 仅在整体返回类型时放行**（全部分支抛异常）；失败 → 19；**禁高阶**由类型码承接（R 取具体非函数类型 ⇒ 返回函数的值码不符）。返回方向按**同一逐位比对**解包。调用侧同源：H63 走 **`FunctionTypeInfo.apply(fn, args)`**，元数不限、零类型分派（原 11^(n+1) 分支表已整体删除）。

**不变项（§2）**：ctx 布局（64 B 整数标量）、帧布局、全部 M1 指令语义、fail-fast（I3/I4）、窗口与逃逸机制、W^X 与 IBT——**全部不变**。

## 附 C M2 字节码 ↔ 机器码（增量）

| 字节码 / 机制 | x86_64 / AArch64 | 备注 | 锚点 |
|---|---|---|---|
| `CALL_HOST argc` | **= `CALL_HELPER` 模板 A 同款：`call H63`** + 自动尾随 `CHECK_ERR` | 机器码**无任何新模式**（I8 自动满足）；argc 为**编译期立即数** | §5、m1 §12.4 模板 A |
| H63 / H64 / H65 | 均为**固定 helper** ⇒ 模板 A 中「引擎符号」直接寻址 | helper 实现体 = 普通 Cangjie（`@C` 薄入口）；**三引擎共用同一实现**（I7 结构性成立） | m1 §6、m1 §12.4 |
| user helper（含构造器条目） | 模板 A 中「**注册期确定的 trampoline**」寻址 | hid ∈ `[0x0100,0xFFFF]`；静态 trampoline ⇒ **零间址**；无注册表 → 加载期拒绝 | §15、m1 §5 / §12.4 |
| 回桥包装器 `call<T>` | **模板 C**（`call H55` → `call H57` → 间接 `call [fnTable+8*fnId]`） | 回桥**不新增机器码路径**——包装器调用走既有闭包调用模板 | §14、m1 §12.4 模板 C |
| 13 / 14 型 cell | 与既有句柄型**零差异**（1 cell = 8 B、不解引用） | 机器码层无新增：零解引用 ⇒ 无值语义映射、无逃逸耦合 | m1 §3.2、§12.4 |
| `flags.bit0`（deopt 禁令） | 既有机制（`CALL_CLOSURE` / 变更型 helper 触发） | M2 触发清单 **+H65**（`host_set_field`）；含此调用的函数禁全部 deopt 源 | §12.2、m1 §7 校验 11 |

**生命周期与失效**：HostClosure 条目属 **B pin 路径**（per-call，随 try/finally 释放；`CALL_FUNC` 链内由被调帧窗口存活）；逃逸回桥第 1 步 = **槽级提升**（`PromotionGroup`，**唯一释放路径 = `close`**，调用 `try/finally` 清理豁免提升槽）；HostObject 走 **B/C/D** 句柄路径——**机器码层全部零新增**，deopt 重放安全（字节码零解引用、零副作用）。

---

## §11 实施偏差回写（M2 交付后补记，2026-10-20）

本节只记「设计稿与落地实现不一致」之处，**权威语义以 `jit-bytecode-m2.md` v0.8.33 为准**。
每条都注明了原因与影响面，避免后来者按设计稿的旧措辞理解现状。

| # | 设计稿原样 | 落地实现 | 原因 / 影响 |
|---|---|---|---|
| 1 | 验签 = **单次 `is (T1..Tn) -> R`**（§5.1 验签段） | `FunctionTypeInfo.of(value)` 取真实签名**逐位比对**（`SignatureVerifier.verifyReflective`） | **原方案语言上不可实现**：`T`/`R` 是运行期数据，`is` 右侧须静态类型；物化路径为 11^(n+1) 分支（2 元 1331、3 元 14641、4 元 16 万）。改后**元数不限**、14 按**具体类名**精确 |
| 2 | 调用 = 按 `sig` 枚举 `invokeN<P..,R>`（§5 H63 第 3 步） | `FunctionTypeInfo.apply(fn, args)` | JIT 运行期无法为宿主函数值单态化 `invokeN`；`HostCallDispatch.cj` 的 **1887 行分派表整体删除** |
| 3 | 执行路径**零反射**（§12.5 性质） | 成员快照面仍零反射；**H63 对宿主函数值的调用是唯一执行期反射点** | 语言限制（见 #1/#2）。I2 不受影响（机器码仍不解引用句柄） |
| 4 | 14 槽「只作不透明大类」 | `HostClosureT` 与 `SignatureDescriptor` **携带每个位置的具体类名**；`PublicField` 增可选 `sigParams/sigParamNames/sigRet/sigRetName` | 只带码时 `(User)->R` 与 `(Order)->R` 撞成同一签名；类名是「预先注册 User/Order 才能验签」的落点 |
| 5 | 反射访问器「可沿继承逐级向上」（M2-7） | 类型判定按 `superClass` 链（**接受子类实例**）；但**执行层** `InstanceVariableInfo.getValue(子类实例)` 抛 `IllegalTypeException`（实测） | 自动注册的字段访问器只对**精确类**有效；有继承的类需手工访问器（`o is C`）或宏。已固化为 `T36/reflect-getvalue-exact-class-only` |
| 6 | 宿主闭包开销「估算 1.5–3×」（m2 §8） | **实测 4.6–5.8×** user helper（release，同构一元） | 成本在 `apply` 的参数打包与间接分派；用户裁定**接受现状**，规格已按实测修订 |
| 7 | `FbcHeader` 旧布局按 `verMinor ≤ 13` 判 | 判据改为 **`verMajor == 1`** | M2 的 `verMinor` 从 0 起算，旧判据会把 v2 产物误判成旧布局 |
| 8 | `FuncDir` 的 `retType` 合法集写死 0–12 | 按 **`verMajor` 参数化**（v2 放行 14） | 否则 M2 产物无法加载 |
| 9 | `CALL_HOST` 栈布局在 §3 与 §5 自相矛盾 | 定案 **`[h_fn, a1..an]`，`h_fn` 先压（栈底）** | 依据既有 `CALL_HELPER` ABI（`args[0]` = 最先压入；`CALL_CLOSURE` 同样先压闭包句柄）；`Lowerer`/`Assembler` 已按此固化 |
| 10 | 反射注册的方法绑定视为「注册期产物、执行期纯调用」 | **String 参数/返回上必现 SIGSEGV**（`ApplyCJMethod`/MCC 路径，300 次循环必崩） | `std.reflect` 实现缺陷；已规避（值型方法 + 手工 String 方法）并登记 **GAP-13**；根治 = M2.1 类型化包装闭包（快 36×） |

**未列入本表的项**：`CALL_HOST` 操作数仍为 `u8 argc`（`u16 sigId` 的迁移因「字段形态无签名」而分步推进）、
`DbgDump` 的 13/14 尖括号（属**实现漏做**，非设计偏差，已在 GAP-06 修正）。

