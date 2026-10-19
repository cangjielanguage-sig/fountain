# Design

## Context

M1 已按 `jit-bytecode-m1.md` v0.18.36 落地：`.fbc` verMajor 1、解释器语义基准、AArch64/x86_64 两后端、H01–H72 helper、句柄表/窗口/逃逸区、Marshal/解包、编译去重、卸载状态机与差分 harness。M1 的冻结面（ctx 64 B 布局、帧布局、I1–I8、错误槽 fail-fast、W^X/IBT、决策 ④ 的「宿主对象只以整数 ID 进入世界」）在 M2 **逐条保持**。

M2 的权威依据已经冻结：

- `f_jit/doc/jit-bytecode-m2.md` **v0.8.32**：六篇增量规格（§0–§10 CALL_HOST、§11 HostObject、§12 成员访问、§14 逃逸闭包回桥、§15 字节码侧构造、§16 宿主对象实参）。
- `f_jit/doc/design-m2.md`：包级/声明级增量与 12 项设计裁定（M2-1–M2-9 已结案）。
- `f_jit/doc/plan-m2.md`：Q0–Q6 的 TDD 步骤表（名义 52 步；实际清单含 Q3.9/Q3.10，共 54 个 Q 编号）。

本设计只回答「M2 增量怎么做」，不重复规格条文；冲突以规格为准。M2 的产物边界是 **`.fbc` verMajor 2 / verMinor 0**，M1 产物与语义完全不变。

**塑造本设计的硬约束：**

1. **不引入新执行机制**：CALL_HOST = 「目标运行期确定的 helper 调用」；H63 复用 M1 helper 的 ABI、错误转码、窗口登记、自动 `CHECK_ERR`、GC/重入边界。机器码层不出现新模式。
2. **静态性下沉到类型层**：调用点按声明类型静态发射 `CALL_HOST`；运行期只做一次句柄表取值，没有运行期回调注册表。
3. **宿主对象零解引用**：13/14 型 cell 与既有句柄型零差异；机器码永远不接触宿主对象指针，deopt 重放安全。
4. **单一错误通道**：宿主侧异常统一 21 + cause（完整仓颉栈）；引擎侧兜底 99；两者严格区分。
5. **注册期拒绝与运行期错误分离**：`RegistrationException` 只在宿主侧注册调用栈抛出，不占 `ErrCode`、不入 `.fbc`、不进三引擎差分。
6. **严格 TDD + M1 零回归**：每步先写失败用例；每步提交前跑 M1 全量（含差分），任何 M1 差异按阻塞缺陷处理。

## Goals / Non-Goals

**Goals：**

- 以 verMajor 2 为边界，交付六篇增量的**规划与验收面**：CALL_HOST 宿主闭包、HostObject 通道、成员访问、逃逸闭包回桥、字节码侧构造、宿主对象实参。
- 保证 M1 加载器/产物/语义零变化；M2 加载器按 `verMajor` 分派规则集，v1 与 v2 共存。
- 把宿主侧异常、注册期拒绝、验签失败、型别不符、卸载后调用等失败面全部映射到确定的码/站点/消息。
- 让 13/14 型值在报告、窗口账目、提升组、GC 保活与并发纪律上与既有句柄型同构。
- 用 T30–T36、T49、T54、T55、T57–T60 把 M2 行为接入单次运行差分 harness；M1 全量作为每步硬门槛。

**Non-Goals：**

- M3 的 Any / JSON（LocalType 15–19、token 12、错误码 22、JSON 预定义成员通道）——本次只在合法集与版本常量上登记边界，不实现语义。
- 高阶闭包（T/R 为函数类型）与异常对象回译——规格 M2 已冻结（M2-5），不排期。
- 跨进程回调注册协议——永久排除（M2-6）。
- `static var` / `static mut prop` 的访问——永久排除（附 B）；`==` 不开放。
- 容器内部级联提升——已裁定为宿主对象、槽级提升、免级联（M2-2）；不实现图遍历。
- 性能特化（per-signature 特化 trampoline）——属 M3 §13；M2 只做解释性 marshal。
- 修改 M1 公开 API 或根 `cjpm.toml` 登记方式。

## Decisions

### D1 CALL_HOST 复用 helper 基础设施，而不是新增调用机制

`CALL_HOST` 的字节码语义就是 `CALL_HELPER H63`：栈 `[h_fn, a1..an]`、`u8 argc`、自动 `CHECK_ERR`；机器码 lowering 复用模板 A（`call H63` + `CHECK_ERR`）。H63 是普通 `@C` helper，三引擎共用同一仓颉实现。

- **备选**：新增一种「间接宿主调用」机器码模式。否决：破坏 I8 的「无新模式」，并需要新的 ABI/栈展开/错误转码。
- **取舍**：每次调用多一次句柄 fetch 与描述符遍历（解释性 marshal），换来确定性与三引擎结构性一致。

### D2 静态性下沉：HostClosure 是声明类型 13，不是运行期值分类

名字解析在编译期按声明类型命中 HostClosure 分支，发射 `CALL_HOST`；运行期不查询「这个值是不是函数」。因此：
- 无运行期回调注册表——句柄表本身就是回调表；
- 无「静态性丧失」的额外机制；
- 与内部闭包调用（`LOADL 0` + `CALL_CLOSURE`）完全平行。

**边界**：HostClosure 只能来自桥 Marshal 或 `CALL_FUNC` 链内传递；字节码内没有构造指令（纯消费者）。

### D3 验签 = 单次 `is (T1..Tn) -> R`，缓存落在句柄条目

仓颉 `is` 对函数类型按子类型语义判定（入参逆变、返回协变，P1 已实测）。一次判定同时覆盖参数个数、逐参类型与返回类型；运行期取不出函数类型分量，分步核对既冗余又不可实现。失败 → 19（site=-1）；成功产出 `SignatureDescriptor` 存入 `HostCallback.sig`。`SignatureVerifier` 是纯静态工具类（无实例、无构造、无状态），`cached(entry)` 只收条目、不做「对象 → 条目」定位。

**禁高阶**由类型本身承接：R 取具体非函数类型（0–8、10–11、14）⇒ 返回函数的值不可能匹配；前端同时拒绝 T/R 为 12/13，构成双重强制。

### D4 句柄条目扩展 tag 10/11，不新设表

- tag 10：`HostCallback{fn: Any, sig: SignatureDescriptor}`，条目强引用宿主闭包，调用期间不可能死亡；B pin 路径，per-call 清理。
- tag 11：不透明宿主对象引用（宿主类实例），与 List/Map 同款引用保活；pin 同对象同 ID。
- tag 11 是「不透明宿主对象引用」**大类**；M3 JSON 内建码复用同 tag，不新开标签。
- 无 token 的其他对象仍 19。

### D5 HostObject 只做不透明通道；成员访问分三步走

§11 基线只允许持有/转发/返回/实参注入；§12 在其上开放：
1. **第 0 步（零机制变更）**：方法/属性/静态成员经宿主包装为预定义函数。
2. **第 1 步**：H64/H65 实例字段读写；H65 走 §9.15 变更型路由（`flags.bit0` + deopt 禁令 + 防御 99）。
3. **第 2 步**：`u.f` / `u.f=v` / `u.m()` 语法糖，降级到前两步；语义零新增。

**继承成员**：前端只查注册快照条目，不做继承谱系上溯；宿主侧反射访问器可按继承关系逐级向上。两个解析点不同，不矛盾（M2-7）。

### D6 逃逸闭包回桥 = 原地提升 + 提升组 + 显式 close

- 交付边界在「执行完成之后、窗口重置之前」，对「闭包自身槽 + 全部句柄型捕获槽」做 D 路径式原地提升：迁出窗口记账、表项保留、ID/gen 不变、不参与后续分配重用。
- 不复制、不改址 ⇒ 已分发副本自动续命、无同对象两编号、`LOAD_CAP` 语义零变化。
- 提升组三规则：清单幂等计数、`close` 归零释放（gen+1）、路径 A 常量不入组。
- 唯一释放路径 = `JitFunction.close()`；调用 try/finally 清理豁免提升槽。
- 单元弱语义：包装器不阻止卸载；卸载后调用 → 19（site=-1）。
- 容器内部表示 = 宿主对象 ⇒ 槽级提升、免级联。

**两阶段交付**：第 0 步白名单（值型/路径 A 常量，免提升组但闭包槽仍按 M1 规则迁出，close 协议已实现）；第 1 步放开句柄型捕获（提升组 + `moveOutGroup` + 唯一释放路径）。

### D7 字节码侧构造复用 user helper 通道

`C(args...)` 不新增指令/helper/格式：每条 `PublicCtor` 物化为单元私有 user helper，降级为 `CALL_HELPER <ctor-user-hid>`，自动 `CHECK_ERR`。适配器在宿主侧执行，接收已解包值数组、返回类实例；每次求值新实例、登记 1 槽；异常 21，防御 99；含构造的函数 `flags.bit0` + deopt 禁令。

- **来源**：`registerType<T>()` 反射自动生成（`ConstructorInfo.apply`）或手工注册；两者语义等价。
- **边界**：无匹配/歧义/未注册类 → 编译错误；JSON 谱系构造写法 → 编译错误。

### D8 反射只在注册期

`ReflectRegistrar.registerType<T>()` 在宿主侧、编译前一次性枚举 public 成员，生成静态描述符与访问器快照；字节码/JIT 执行路径零反射。`static var` / `static mut prop` 跳过（附 B）；不可映射成员跳过 + `RegistrationSkipped`；命名冲突跳过 + 诊断；类名冲突/JSON 谱系/关闭反射 → `RegistrationException` 硬拒绝。

### D9 注册期拒绝用独立异常，不占 ErrCode

`RegistrationException <: f_base.BaseException`，六值 `RegistrationRejectKind`，字段 `kind/name/occupiedBy`，三段消息 + 按 kind 固定 hint。只在宿主侧注册调用栈抛出；不登记；不入 `.fbc`；不进差分。理由：0–23 是「世界内执行」的码，注册期不属该路径；diag 不承担错误通道（D1）。

### D10 21 统一全部宿主侧调用面，99 收窄为引擎兜底

CALL_HOST 闭包、预定义/包装、构造适配器、成员访问器未捕获异常一律 21；cause 为原始异常全文（完整仓颉栈），桥打印完整栈；site 为调用指令偏移；fail-fast。99 只留给引擎实现缺陷。

### D11 报告中的 13/14 退化为大类名

`DbgDump` 对 13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`；不取对象、不解析注册类名。理由：14 的类型名没有字节码载体（每槽 1 B 大类、name 段只记变量名），且 M1 §9.16 已冻结「不取对象（避免错误路径二次失败）」。报告模板逐条不变。

### D12 版本规则集对象化，按 verMajor 分派

`FbcReader` 不写死单一合法集，而以规则集对象参数化：合法 LocalType 集合、合法指令集、14 槽注册表依赖校验、类型表/站点/名字校验参数。v1 → M1 规则集；v2 → M2 规则集；v3 → M3 规则集（本次仅登记 0–19，不实现语义）。M2 加载器同时兼容 v1/v2；M1 加载器遇 v2 → 18。版本常量面保留 legacy `MAJOR=1` / `MINOR=14`（M1 零回归），新增 `M1_MAJOR` / `M2_MAJOR` / `M2_MINOR` / `M3_MAJOR`；M2 写入通过显式编译目标/版本参数选择 2/0，不改写 legacy 常量。

### D13 `JitClosureId` 命名与 `JitFunction` 统一包装

逃逸闭包 ID 的宿主值类型命名为 `JitClosureId`（原名 `CFunc` 与仓颉内建 `CFunc<F>` 冲突）。M2-8 裁定：不另设包装类，统一用 `JitFunction` 包装；从 JIT 取回的闭包与 JIT 产出的闭包是同一表示。`callFor<Fn>` 是「调用单元、取回它返回的闭包」的强类型入口，不是「调用闭包取值」；包装值不得直接作实参（19）。

## Architecture

### 包与依赖增量

```
base ──► bytecode ──► compiler
  │           │           │
  └───────────┴──────────► runtime ──► Root(fountain::f_jit)
                          ▲
                compiler ─┘
backend（不变，仅消费 0x79 的既有模板 A）
```

- `base`：常量扩展 + 注册协议值类型 + 注册异常。
- `bytecode`：opcode 行 + 规则集 + 类型表校验。
- `compiler`：TypeRef / ClassRegistryView / NameResolver / Lowerer / AstExpr / DefiniteAssignment。
- `runtime`：HostCallback / SignatureDescriptor / SignatureVerifier / PromotionGroup / H63–H65 / HandleTable / Interp / DbgDump。
- 根包：ClassRegistry / ReflectRegistrar / JitClosureId / Compiler / CallMarshal / JitFunction。
- `backend`：不新增 lowering 模式；`CALL_HOST` 走模板 A，回桥包装调用走模板 C。

### 关键数据流

**CALL_HOST（H63）**

```
字节码: [h_fn, a1..an] ──CALL_HOST argc──► H63
  1 fetch(h_fn) → HostCallback{fn,sig}        // tag≠10 → 8
  2 按 sig 逐参 cell → 仓颉值                  // 值型原值 / 句柄型 get / 14 实例引用
  3 调用 fn                                   // 可 GC / 抛异常 / 重入 JIT
      └ 异常 → catch-all → 21 + cause（完整栈）→ fail-fast
  4 返回值 → cell                             // R 引用型 → 登记 1 槽；值型 → 原值
  5 自动 CHECK_ERR
```

**成员访问糖**

```
u.f       → H64(u, idx)                 // 值型零登记；句柄型登记 1 槽
u.f = v   → H65(u, idx, v)              // 变更型；let 字段编译期拒绝
u.m(a…)   → m(u, a…)                    // 方法表 bind 的预定义调用
```

**字节码侧构造**

```
C(args…) → 实参左→右 → CALL_HELPER <ctor-hid> → CHECK_ERR
         每次求值新 HostObject（登记 1 槽）；适配器异常 → 21
```

**逃逸闭包回桥**

```
unbox（执行后、窗口重置前）
  retType=12 → 提升「闭包槽 + 句柄型捕获槽」= 原地迁出（ID/gen 不变）
             → JitClosureId → JitFunction 包装
宿主 call<T> → 新 ctx；locals[0]=闭包句柄 → 闭包帧
卸载后调用 → 19（site=-1）；close → 计数−1、归零释放
```

**反射注册**

```
Compiler.registerType<T>() → ReflectRegistrar
  枚举 public 成员 → 生成 PublicField/PublicMethod/PublicCtor + 访问器
  → 注入 ClassRegistry 快照 → 前端解析 u.f/u.m()/C(...)
  执行路径零反射
```

### 类型与生命周期矩阵

| 值 | LocalType | 句柄 tag | 进入方式 | 释放 |
|---|---|---|---|---|
| 宿主闭包 | 13 | 10 | Marshal 验签 → B pin | per-call try/finally |
| 宿主对象 | 14 | 11 | 实参 pin / 返回值 wrap | B pin / 窗口 / 逃逸 |
| 逃逸闭包 | 12 | 9（条目） | 回桥原地提升 | 显式 `close` |
| 成员字段句柄 | 4–14 | 对应 | H64 条件分配 | 窗口/逃逸 |
| 构造结果 | 14 | 11 | user helper 分配型 | 窗口/逃逸 |

## Compatibility and Migration

- **M1 零回归**：ctx/帧布局、全部 M1 指令语义、fail-fast、窗口/逃逸、W^X/IBT、卸载状态机不变；M1 产物由 M2 加载器按 v1 规则集加载。
- **版本矩阵**：v1 产物 × M1/M2 加载器 = 通过；v2 产物 × M1 加载器 = 18；v2 产物 × M2 加载器 = 通过；v3 本次以 18 拒绝。
- **格式零增量**：捕获描述符不入 `.fbc`；构造不新增指令/helper；宿主对象实参不新增指令/helper；注册项属宿主侧资产；常量 kind 1–10 不变。
- **分发边界**：含 14 形参/成员访问/构造的单元经无注册表分发入口 → 加载期拒绝；JSON 内建码零注册，不触发该面。
- **迁移**：无数据库/持久化迁移；已有 M1 编译缓存与适配器键不受影响；M2 只在 verMajor 2 路径启用新语义。

## Security and Lifecycle

- **封闭白名单**：只新增 H63/H64/H65 与 `CALL_HOST` 激活；其他 helper 编号保持保留。
- **deopt**：含 `CALL_HOST` / H65 / 构造/成员访问的函数按黑盒判定置 `flags.bit0`，拒绝全部 deopt 源；运行期防御 -1 → 99。
- **GC**：句柄条目强引用宿主闭包/对象；H63 内部可分配、可触发 GC，属 M1 已文档化的 helper 边界；13/14 型 cell 零解引用。
- **重入**：宿主闭包内调用 JIT 合法，新 ctx、独立事务；内层失败不覆盖外层错误槽。
- **取消**：宿主闭包执行期间不可中断；`CALL_HOST` 点不设安全点；取消感知延迟上界 = 闭包剩余执行时长。
- **并发**：句柄表操作有锁；宿主不得并发修改被传递的共享对象；静态可变状态永久排除。
- **失败面**：验签/型别/null/包装值作实参 → 19（site=-1）；宿主异常 → 21；引擎缺陷 → 99；注册期拒绝 → `RegistrationException`（不占码）。

## Testing and Acceptance

- **TDD**：每个 Q 步骤先写失败用例，再写最小实现；用例数单调增长、失败数为 0。
- **M1 基线**：Q0.3 跑 M1 全量并留档数字；每步提交前重跑，零差异。
- **M2 验收**：T30–T36、T49、T54、T55、T57–T60 接入差分；四元组（结果/错误码/site/报告）逐位一致。
- **失败点**：每个用例同时断言 code 与 site；21/99 分类、site=-1 契约错误显式断言。
- **容量**：H63/H64/构造/R=14 的窗口账目；提升组与逃逸区占用；16 中途边界。
- **无泄漏**：T27 模式的 malloc/free 与句柄计数断言，覆盖正常/错误/中断/重入/卸载路径。
- **文档**：Q6 回写 `design-m2.md` / `plan-m2.md` / `jit-bytecode-m2.md` 偏差；同源三表抽样比对。

## Risks and Trade-offs

| 风险 | 影响 | 缓解 |
|---|---|---|
| 提升组计数与 try/finally 交互错误 | 泄漏或提前释放 | 双闭包共享捕获 + 幂等计数 + 归零释放构造性用例；close 为唯一释放路径 |
| 21 与 99 混用 | 业务异常被误判为实现缺陷 | 三面异常用例 + `isHostSide` 断言 + 21/99 分类用例 |
| 验签依赖 P1 | 环境不支持函数类型 `is` | P1 已实测（SDK 1.3.0-alpha）；`callFor<Fn>` 作为返回方向兜底 |
| verMajor 分派遗漏 | M1 产物被 M2 规则集误判 | 规则集对象 + 兼容矩阵用例 + M1 全量回归 |
| 反射注册与手工注册不一致 | 糖/构造行为漂移 | 逐项对拍（字段/方法/类型码）；自动 ≡ 手工 |
| 14 槽链内无校验 | 型别错配 | 入口 `is C` 与各返回面校验归纳担保；前端静态校验 |
| 报告取对象失败 | 二次异常 | 13/14 只呈现大类名，不取对象 |
| 构造/成员访问 deopt 重放 | 副作用重复 | `flags.bit0` + 汇编期禁令 + 防御 99 |

## Open Questions

M2-1–M2-9 均已结案（P1 实测、容器免级联、两阶段交付、注册期拒绝体例、第三档冻结、跨进程永久排除、继承解析点、`JitFunction` 统一包装、JSON 拒绝注册）。本次 planning 不引入新的开放问题；实施中若出现规格未覆盖的偏差，按 Q6 回写流程处理，不在代码中静默决定。

## Reference Map

| 本设计主题 | 权威锚点 |
|---|---|
| CALL_HOST / H63 | 规格 §5；design-m2 §5、§7.1 |
| 验签 / Marshal | 规格 §4；design-m2 §5.1.2 |
| HostObject 通道 | 规格 §11；design-m2 §7.5 |
| 成员访问 / 反射注册 | 规格 §12；design-m2 §5、§7.2、§7.6 |
| 逃逸闭包回桥 | 规格 §14；design-m2 §6.1.3–§6.1.5、§7.4 |
| 字节码侧构造 | 规格 §15；design-m2 §7.3 |
| 宿主对象实参 | 规格 §16；design-m2 §7.5 |
| 版本规则集 | 规格 §2、§9.2；design-m2 §8 |
| 测试矩阵 | 规格 §10；plan-m2 Q0–Q6 |
