# f_jit TDD 开发计划 · M2 增量（verMajor 2：宿主互操作）

> 依据：`design-m2.md`（本目录）与 `jit-bytecode-m2.md` v0.8.27。
> 粒度：**每个新增/变更的公共成员一份 TDD 单元**；步骤前缀 `Q`，与 M1 计划（S 前缀）不复用编号。
> 前置：plan-m1.md 的 P0–P6 已完成（M1 全绿基线）；M2 开工前先跑一遍 M1 全量回归作为对照基线。

---

## §0 计划总则（M2 附加）

1. **增量不破坏**：每步提交前跑 M1 全量（含差分）——M1 产物与语义必须零变化（差分回归是 M2 的硬门槛）。
2. **verMajor 两态（v1/v2）**：M2 加载器对 v1/v2 产物分别按规则集校验；M1 加载器对 v2 的拒绝由「兼容性用例」钉住（负向用例在 M2 分支上跑 mock 的 M1 校验器或直接断言拒绝码）。
3. 主线支点回归：CALL_HOST = helper 调用 ⇒ H63 的每个断言都应能在「用户 helper」既有用例上找到同构对照（差分口径：转发语义逐位一致）。
4. 其余总则（红→绿→重构、证据口径、测试落点）同 plan-m1.md §0。

---

## §1 阶段总览

| 阶段 | 内容 | 步骤数 | 依赖 |
|---|---|---|---|
| Q0 | 兼容基建（版本分派、v1 回归夹具） | 3 | M1 完成 |
| Q1 | `base` 增量（常量 13/14/10/11/21 + 注册协议类型） | 5 | Q0 |
| Q2 | `bytecode` 增量（0x79 行、规则集分派、合法集） | 4 | Q1 |
| Q3 | `compiler` 增量（类型记法/解析/降低） | 8 | Q2 |
| Q4 | `runtime` 增量（验签/H63–H65/提升组/报告） | 12 | Q2 |
| Q5 | 根包增量（注册表/反射/构造/包装器/Marshal 行） | 12 | Q3、Q4 |
| Q6 | 验收（T30–T36、T49、T54、T55、T57–T60） | 7 | 全部 |

---

## §2 步骤清单

### Q0 兼容基建

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q0.1 | `Version` 多版本常量（`M1_MAJOR/M2_MAJOR/M3_MAJOR`） | 常量断言；`supportedMajors()` 含 1/2 | 常量 + 集合 | — |
| Q0.2 | 版本分派夹具 | 用 M1 产物 + M2 产物各一份跑加载：v1 走 v1 规则集、v2 走 v2 规则集（mock 断言取用的规则集） | `FbcReader` 内规则集注册表 | M1 全量回归不变 |
| Q0.3 | M1 回归基线 | 跑 plan-m1 §7 全量，记录数字（作为 M2 对照） | — | 基线留档 |

### Q1 `base` 增量

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q1.1 | `LocalType.HOST_CLOSURE=13` / `HOST_OBJECT=14`、`isHandle` 语义扩展 | 值断言；`isHandle(13/14)=true` | 常量 + 判定更新 | §2 表一致 |
| Q1.2 | `TypeToken.HOST_CLOSURE=10` / `HOST_OBJECT=11` | 值断言；`name` 输出 | 常量 | — |
| Q1.3 | `ErrCode.HOST_EXCEPTION=21`、`isHostSide` | 值断言；`isHostSide(21)=true`、其余 false；`describe(21)` 含「宿主」语义 | 常量 + 映射表 + 占位实现落地 | §2 映射表（1–21、23） |
| Q1.4 | `PublicField`（5 字段）+ `PublicMethod` + `PublicCtor` | 构造保真；`type` 合法集（0–14）；`adapter` 可调用；`mutable=false` 语义（`let`） | struct/class | m2 §12.2/§12.4/§15 |
| Q1.5 | `ClassDescriptor`（name/fields/methods/ctors） | 构造保真；空表/多构造器/重载（同 name 多 ctor）用例 | class | — |

### Q2 `bytecode` 增量

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q2.1 | `OPCODE_TABLE[0x79]` 行 | `table[0x79].fmt=="u8"`、`len==2`、`cat==CAT_CALL`；0x7A/0x7B（HW_OPEN/CLOSE，类别 CAT_CALL、非 RSVD 槽）在 M1/M2 汇编期一律 `ERR_NOT_IMPL`（后档专项） | 表更新 | §10.3 行对照 |
| Q2.2 | `FbcReader` 规则集分派 | v2 产物（LocalType 13/14、CALL_HOST）在 v2 规则集下通过；v1 规则集下 LocalType 13 → 拒；v1 加载器遇 verMajor 2 → 18 | 规则集对象（合法集/指令集/校验项参数化） | 兼容矩阵 §8 |
| Q2.3 | `LocalTypes.validate` 按 verMajor | v1：13 拒；v2：13/14 通过、15 拒 | 同上 | — |
| Q2.4 | `Assembler` 校验增补 | `CALL_HOST argc` 栈布局校验（`[h_fn, a1..an]`）；v2 规则集下合法、v1 下 NotImpl | 校验参数化 | m2 §2 |

### Q3 `compiler` 增量

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q3.1 | `TypeRef`（`Builtin/HostClosureT/HostObjectT`） | 类型记法解析：内建/函数类型 `(T1,T2)->R`/注册类名；禁高阶（T/R 为 12/13 → 编译错误）；未注册类名 → 编译错误 | 类型解析器 | m2 §3/§16.1 |
| Q3.2 | `ClassRegistryView.classOf/isRegistered` | 命中/未命中；快照语义（注册后变更不影响已编译单元） | 只读视图 | T55 前置 |
| Q3.3 | `ClassRegistryView.fieldOf/methodOf/ctorsOf` | 字段解析（name→index/type/mutable/typeRef）；方法解析（→bind）；构造器集（重载列表）；未注册类/未知成员 → 编译错误（消息含类名/成员名） | 视图查询 | T35/T36/T54 前置 |
| Q3.4 | `NameResolver` 解析顺序扩展 | ① `recursive` 优先；② user helper；③ HostClosure 形参/局部（静态 13 → `HostClosureCall`）；④ 未定义；⑤ 同名冲突（形参 vs user helper）→ 编译错误 | 顺序实现 | m2 §3 |
| Q3.5 | `Lowerer` CALL_HOST 降低 | `fn(a1,a2)` → 实参左→右入栈 → `LOADL fn` → `CALL_HOST 2` → 自动 CHECK_ERR；产物断言（栈序 `[h_fn, a1, a2]`） | 发射序列 | T31 前置 |
| Q3.6 | `Lowerer` 成员访问降级表 | `u.f`→H64（值型/句柄型/14/13 各一）；`u.f=v`→H65；`let` 字段写 → 编译错误；`u.m(a…)`→包装调用（hid 解析）；求值顺序（u 先于 v/实参）；链式 `u.a.b`/`u.m().f`；非 HostObject 用点号/未注册类/未知成员 → 编译错误 | 降级表 | T36 |
| Q3.7 | `Lowerer` 构造降低 `C(args…)` | 降级为 `CALL_HELPER <ctor-hid>`；实参左→右；重载静态匹配（无匹配/歧义 → 编译错误）；嵌套构造 `User(Addr(…))`（14 实参）；结果类型 = 该类（可进成员链 `C(…).m()`） | user helper 物化 | T54 |
| Q3.8 | `AstExpr` +4 构造器 + `DefiniteAssignment` 扩展 | `FieldGet/FieldSet/MethodCall/CtorCall` 解析；13/14 槽明确赋值与空安全（同句柄型；14 恒非空） | AST + 分析 | — |

### Q4 `runtime` 增量

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q4.1 | `SignatureDescriptor`（params/ret/validate） | 编码断言；`validate`：12/13 在 T/R → false；14 合法 | class | m2 §1 |
| Q4.2 | `SignatureVerifier.verify`（static；类无实例） | 五步逐条：非函数值 → None；参数个数不符 → None；逐参类型不符 → None；返回类型不符 → None；高阶复检 → None；合法 → 描述符产出 | P1 `is` 判定 + 核对 | T30 |
| Q4.3 | `SignatureVerifier.cached(entry: HostCallback)`（static） | 幂等复用（幂等计数断言）：条目已验签 → 返回 `entry.sig`；未验签 → `None` | 条目缓存（`HostCallback.sig`）；**收条目**、不做「对象 → 条目」定位（design-m2 §5.1.2 裁定，2026-10-11） | T30 |
| Q4.4 | `HostCallback`（fn/sig） | 条目构造/字段保真；pin 同对象同 ID | class | T30 |
| Q4.5 | H63 `host_call_trampoline`（基础） | 栈底 fetch（tag≠10 → 8）；逐参转换（值型/句柄型/14）；调用 fn；值型返回原值、引用型登记 1 槽（hwTop 断言）；**含 CALL_HOST → `flags.bit0` + deopt 源汇编期禁令（拒绝用例）+ 防御 -1 → 99 联测** | helper 实现 | T31 |
| Q4.6 | H63 异常与重入 | fn 抛异常 → 21 + cause（完整栈、桥打印）+ site=CALL_HOST 偏移；重入（闭包内再调 JIT，深度 ≥3）：独立事务（独立 errCode/site/窗口），内层错误不影响外层；**新 ctx 的分配/释放沿用 design-m1 §5.3.1 选型（`LibC.malloc/free`）** | catch-all + 新 ctx | T31/T60 |
| Q4.7 | H64 `host_get_field` | 值型直取零登记、句柄型登记 1 槽；obj tag≠11 → 8；index 防御 → 99 | 字段表访问 | T35 |
| Q4.8 | H65 `host_set_field` | 值型/句柄型写；宿主侧可见（同一对象）；`mutable=false` → 19；obj tag≠11 → 8；**不登记槽**；变更型标记（含其函数 flags.bit0 联测） | 变更型 helper | T35 |
| Q4.9 | `PromotionGroup` | `add` 幂等计数（双闭包共享捕获 → 计数 2）；`release` 归零释放（gen+1）；`contains`；常量不入组；try/finally 豁免（清单判定） | 组清单 | T49 |
| Q4.10 | `HandleTable` 条目标签扩展 + 提升协作 | HostCallback(tag=10)/宿主类实例(tag=11) 的 pin/fetch/get 往返；`moveOutGroup` 原地提升（ID/gen 不变、不重用） | 条目类型扩展 | T49/T57 |
| Q4.11 | `Interp` CALL_HOST 语义 | 解释器路径与 H63 转发逐位一致（同用例对拍）；v2 单元含 0x79 可执行 | 解释循环扩展 | T33 |
| Q4.12 | `DbgDump` 报告扩展 | 13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`（**大类名呈现**，不取对象 / 不解析类名）；其余**逐条沿用** M1 §9.16（三行模板、条目格式、槽位序号为键、`site=-1`/`dbgBase=0` 边界、`-1`/`-2` 不转储、最深帧获胜） | 呈现更新 | T60 |

### Q5 根包增量

| 步骤 | 目标成员 | 先写测试（红） | 实现要点（绿） | 验收（回归） |
|---|---|---|---|---|
| Q5.1 | `ClassRegistry.register/snapshot/resolve` | 注册/查询；同名类重复注册 → 注册期拒绝；类名与已注册函数名冲突 → 拒绝；快照（注册后变更不影响已编译单元） | 注册表 + 锁 | T55 |
| Q5.2 | `ReflectRegistrar.registerType<T>` | 全成员枚举（`let/var/prop/mut prop/func/static let/static prop/static func/constructors`）；`static var`/`static mut prop` 跳过（附 B）；支撑面外类型跳过；命名冲突跳过——逐项 diagnostics 断言；**自动 ≡ 手工**逐项对拍（字段表/方法表/类型码） | std.reflect | T55 |
| Q5.3 | `ReflectRegistrar.mapType/buildCtor` | 值型直映；std 句柄类型名映射（4–11）；其余类 → 14 + typeRef；不可映射 → 跳过 + 诊断；构造器 `apply` 适配；泛型类按具体实例化 | 映射表 | T55/T54 |
| Q5.4 | `Compiler.registerClass` / `registerType<T>` | 端到端：注册后 `u.f`/`u.m()`/`User(…)` 可用；快照语义；关闭反射构建 → 明确报错 | 门面转发 | T54/T55 |
| Q5.5 | `JitClosureId`（值类型） | 构造/`INVALID`；值语义（拷贝后 ID 相同） | struct | T49 |
| Q5.6 | `JitClosure.init/call<T>` | 调用 = 新桥调用（闭包帧 `locals[0]`）；结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；重入 ≥3；卸载后调用 → 19（site=-1） | 包装器 | T49 |
| Q5.7 | `JitClosure.close/isClosed` | close 幂等；计数 −1/归零释放；close 后调用 → 19；旧 ID 校验拦截 | close 协议 | T49 |
| Q5.8 | `CallMarshal` 参数 Marshal + 行 | 源入口实参：`is C`（含**子类**实例）→ pin（tag=11）；null → 19；多参混排（值型/句柄型/14）；同一对象身份（实参 ≡ 闭包内引用 ≡ 返回值带回） | Marshal 扩展 | T57 |
| Q5.9 | `CallMarshal` 解包表 + 行 | `retType=12→JitClosureId`（提升组已登记）；`retType=13→原样带回宿主闭包引用`；`retType=14→get 实例引用`；T 校验 | 解包扩展 | T49/T57 |
| Q5.10 | `CallMarshal` 验签 + HostClosure 参数行 | 声明 HostClosure 参数 → 验签 → pin(tag=10)；失败 → 19（site=-1）；⑤ 禁高阶复检 | 参数行 | T30 |
| Q5.11 | `JitFunction` 状态扩展 + `callWith<Fn>` | 单元持有 ClassRegistry 快照/提升组表；`callWith<Fn>` 强类型变体（P1 可用时与 `call<T>` 等价；不可用时编译期验签） | 状态 + API | M2-1 裁定后启用 |
| Q5.12 | 槽 14 链内传参与 HostClosure 签名含 14 | 14 形参/局部/返回声明；跨 CALL_FUNC 传递 × 深度 ≥3；链内返回；嵌套闭包捕获 14（快照 = ID 拷贝）；HostClosure 签名含 14 的验签/执行（R=14 → 登记 1 槽） | 前端 + H63 扩展 | T58/T59 |

### Q6 验收（T 系列）

| 步骤 | 覆盖 | 断言 |
|---|---|---|
| Q6.1 | T30 验签与 Marshal | 失败面全 19（site=-1）；验签一次缓存；禁高阶双重拒绝；同名冲突编译错误 |
| Q6.2 | T31/T60 CALL_HOST 与异常 | 21 与 99 严格区分；cause 完整栈（帧数/顺序）；并发失败互不串扰；终止语义（错误点后续不执行） |
| Q6.3 | T32/T33 交互与差分 | flags.bit0 + deopt 禁令 + 防御 -1 → 99；GC 并发；取消边界；**单元卸载与 HostClosure 无交互（per-call 排空）**；确定性宿主闭包 × 三引擎逐位一致 |
| Q6.4 | T34 HostObject | 同一对象身份往返；null/型别不符 → 19；无泄漏（T27 模式） |
| Q6.5 | T35/T36 成员访问 | 糖 ≡ 手写逐位一致；拒绝集全部编译错误；注册表快照；`mutable` 双防线 |
| Q6.6 | T49 逃逸闭包回桥 | 白名单/提升/共享计数/close/常量不入组；包装器调用 ≡ 直接 CALL_CLOSURE；卸载 → 19；M1 产物差分回归零变化 |
| Q6.7 | T54/T55/T57/T58/T59 构造与注册 | 每次求值新实例（身份独立）；自动 ≡ 手工；重载解析/歧义；实参注入全通道；窗口账目（每次构造/ R=14 登记 1 槽） |

---

## §3 顺序约束与风险

1. **H63 先行**：Q4.5/Q4.6 是 M2 的地基（T31 通过前不做成员访问/构造）；`ReflectRegistrar`（Q5.2）最后做——它只批量生成手工条目。
2. **提升组与 close 配对**（Q4.9/Q5.7）是逃逸回桥的最大风险点——用「双闭包共享捕获 + 幂等计数 + 归零释放」构造性用例钉住；容器内部表示裁定（M2-2）前，只交付白名单版（值型 + 路径 A 常量捕获）。
3. **M1 零回归**：每步跑 plan-m1 §7 全量；任何 M1 产物差异按阻塞缺陷处理。
4. **P1 依赖**（M2-1）：Q4.2 先以最小用例确认环境行为；不可用则 Q5.11 的 `callWith<Fn>` 转为必选通道。
5. **编号说明**：T59 在 m2（HostClosure 签名含 14）与 m3（JSON 世界内可变 API + Any↔14）曾重号——**已裁定（2026-10-11）：m3 侧改 T61，m2 侧保持 T59**；本计划按 m2 语义使用 T59。
