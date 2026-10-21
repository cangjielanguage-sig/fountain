# Tasks

> 步骤号严格沿用 `f_jit/doc/plan-m2.md` 的 Q0–Q6 编号；每个任务按 TDD 执行：**先写会失败的用例（红）→ 写最小实现（绿）→ 重构**，全绿后才勾掉。
> **步数说明**：`plan-m2.md` §1 总览把 Q3 记为 8 步、名义合计 52 步；§2 步骤清单实际含 Q3.9/Q3.10（逃逸闭包两阶段交付），有效 Q 编号为 **54 个**。本表按有效编号全量展开，避免漏掉白名单与放开拒绝面两个关键步骤。
> **前置**：M1 全绿基线（plan-m1 §7）已完成；开工前先跑一遍 M1 全量，数字留档为 M2 对照。
> **每步验收**：对应目录 `cjpm build` 通过、`cjpm test` 新增用例由红转绿、M1 全量零回归；用例数单调增长、失败数为 0。允许分支内多次提交，但不得出现「任务已勾选但没有对应用例」的进度。
> **构建口径**：沿用 M1，不登记根 `cjpm.toml`；在 `f_jit` 模块内独立 `cjpm build` / `cjpm test`。

## Q0 兼容基建

- [x] Q0.1 `Version` 多版本常量：先写失败用例——`M1_MAJOR=1`、`M2_MAJOR=2`、`M2_MINOR=0`、`supportedMajors()` 含 1/2、M3=3 登记位；再写常量与集合；验收：常量断言全绿，M1 现有 `MAJOR/MINOR/HDR_SIZE/MAGIC` 读取路径不变
- [x] Q0.2 版本分派夹具：先写失败用例——用同一份 M1 产物与 v2 产物各跑加载，断言 v1 取 v1 规则集、v2 取 v2 规则集（mock 规则集记录取用）；再写 `FbcReader` 规则集注册表；验收：分派记录可断言，M1 全量回归不变
- [x] Q0.3 M1 回归基线：跑 plan-m1 §7 全量（含差分），记录用例数/通过数/失败数/耗时；验收：基线数字留档，作为后续每步对照

## Q1 `base` 增量

- [x] Q1.1 `LocalType.HOST_CLOSURE=13` / `HOST_OBJECT=14` 与 `isHandle` 扩展：先写失败用例——值断言、`isHandle(13/14)=true`、0–3 仍 false、按 verMajor 的合法集边界（v1 拒 13+；v2 放行 13/14、拒 15+；v3 放行 15–19、拒 20）；再写常量与判定；验收：与 m2 规格 §2 表一致
- [x] Q1.2 `TypeToken.HOST_CLOSURE=10` / `HOST_OBJECT=11`：先写失败用例——值/`name` 断言、token 11 为「不透明宿主对象引用」大类、M3 JSON 复用 tag 11 不另开；再写常量；验收：与 LocalType 映射集中且一致
- [x] Q1.3 `ErrCode.HOST_EXCEPTION=21` 与 `isHostSide` 落地：先写失败用例——值/`describe(21)` 含宿主语义、`isHostSide(21)=true` 且其余 false、21 与 99 描述不混；再写常量/映射/占位实现落地；验收：与 m2 §2 错误码表一致
- [x] Q1.4 `PublicField`（5 字段）+ `PublicMethod` + `PublicCtor`：先写失败用例——构造保真、`type` 合法集 0–14、`mutable=false` 语义、`adapter` 可调用、方法 bind 首参为该类、构造器 params 序列；再写 struct/class；验收：与 m2 §12.2/§12.4/§15 一致
- [x] Q1.5 `ClassDescriptor`（name/fields/methods/ctors）：先写失败用例——构造保真、空表、多构造器重载、字段/方法/构造器数组不被意外共享；再写 class；验收：注册协议四类型可组合成完整描述符
- [x] Q1.6 `RegistrationException` + `RegistrationRejectKind`（v0.8.32）：先写失败用例——六值逐值断言、`(kind, name, occupiedBy)` 与 `occupiedBy=None` 分支、`super(message)` 三段消息 + 按 kind 固定 hint、`is fountain::f_base.BaseException`、**不占 ErrCode**；再写 class <: `f_base.BaseException` + enum 六值；验收：宿主可 `catch (e: RegistrationException)` 读回 `kind/name/occupiedBy`

## Q2 `bytecode` 增量

- [x] Q2.1 `OPCODE_TABLE[0x79]` 行：先写失败用例——`table[0x79].fmt=="u8"`、`len==2`、`cat==CAT_CALL`、名称 `CALL_HOST`；`0x7A/0x7B` 保持 `CAT_CALL` 但汇编期 `ERR_NOT_IMPL`；再写表更新；验收：除 0x79 外 M1 行逐位不变
- [x] Q2.2 `FbcReader` 规则集分派：先写失败用例——v2 产物（13/14、CALL_HOST）在 v2 规则集通过；v1 规则集下 13/14/CALL_HOST 拒；M1 加载器遇 verMajor 2 → 18；v3 规则集 0–19 通过、20–255 拒；v2 规则集 15–19 拒；含 14/成员访问/构造的单元经无注册表分发入口 → 加载期拒绝；JSON 零注册不触发；再写规则集对象；验收：兼容矩阵 §8 全覆盖
- [x] Q2.3 `LocalTypes.validate` 按 verMajor：先写失败用例——v1 拒 13–255；v2 放行 13/14、拒 15–255；v3 放行 15–19、拒 20–255；再写参数化校验；验收：与 Q2.2 取用同一规则集
- [x] Q2.4 `Assembler` 校验增补：先写失败用例——`CALL_HOST argc` 展开与 `[h_fn, a1..an]` 栈布局、argc 与实参数不符拒绝、栈底非句柄拒绝、v2 合法/v1 NotImpl；再写校验参数化；验收：与 m2 §2 一致

## Q3 `compiler` 增量

- [x] Q3.1 `TypeRef`（Builtin/HostClosureT/HostObjectT）：先写失败用例——内建/函数类型/注册类名解析；T/R ∈ 0–8、10–11、14；9/12/13 拒；禁高阶；未注册类名编译错误；再写解析器；验收：与 m2 §3/§16.1 一致
- [x] Q3.2 `ClassRegistryView.classOf/isRegistered`：先写失败用例——命中/未命中、快照语义（注册后变更不影响已编译单元）；再写只读视图；验收：T55 前置可用
- [x] Q3.3 `ClassRegistryView.fieldOf/methodOf/ctorsOf`：先写失败用例——字段 name→index/type/mutable/typeRef、方法→bind、构造器重载列表、未注册类/未知成员错误含类名/成员名、继承成员仅按注册表条目（不在表 → 编译错误）；再写查询；验收：T35/T36/T54 前置
- [x] Q3.4 `NameResolver` 解析顺序扩展：先写失败用例——recursive 优先、user helper、HostClosure 形参/局部（静态 13 → HostClosureCall）、未定义；形参/局部与 user helper 同名 → 编译错误；再写顺序与冲突拒绝；验收：无运行期查找
- [x] Q3.5 `Lowerer` CALL_HOST 降低：先写失败用例——`fn(a1,a2)` 的 `a1→a2→LOADL fn→CALL_HOST 2→CHECK_ERR` 栈序；再写发射序列；验收：T31 前置，产物逐指令可断言
- [x] Q3.6 `Lowerer` 成员访问降级表：先写失败用例——`u.f`→H64（值型/句柄型/14/13 各一）、`u.f=v`→H65、`let` 字段写编译错误、`u.m(a…)`→包装调用、求值顺序（u 先于 v/实参）、链式 `u.a.b`/`u.m().f`、非 HostObject 用点号/未注册类/未知成员编译错误、继承成员按表；再写降级；验收：T36 前置
- [x] Q3.7 `Lowerer` 构造降低 `C(args…)`：先写失败用例——降级为 `CALL_HELPER <ctor-hid>`、实参左→右、重载静态匹配/无匹配/歧义、嵌套构造 `User(Addr(…))`、结果类型可进成员链、JSON 谱系构造写法编译错误；再写 user helper 物化；验收：T54 前置
- [x] Q3.8 `AstExpr` +4 构造器 + `DefiniteAssignment` 扩展：先写失败用例——`FieldGet/FieldSet/MethodCall/CtorCall` 解析；13/14 槽明确赋值与空安全（同句柄型；14 恒非空；`PUSH_NULL` 直存 14 拒绝）；再写 AST + 分析；验收：13/14 槽规则与 M1 句柄型同型
- [x] Q3.9 前端捕获描述符 + 白名单拒绝（第 0 步）：先写失败用例——捕获逐项分类（值型/路径 A 常量/路径 B 参数/路径 C 窗口分配）；含路径 B/C 捕获的闭包逃逸 → 编译错误（消息含捕获名与来源）；描述符不入 `.fbc`；再写前端分析 + 拒绝面；验收：T49 第 0 步面，值型/路径 A 可逃逸
- [x] Q3.10 第 1 步放开拒绝面 + `LOAD_CAP` 配合：先写失败用例——句柄型捕获（路径 B/C）不再编译错误；提升组内容 = 描述符给出的句柄型捕获集；`LOAD_CAP` 读到提升后有效槽（语义零变化回归）；再写判定放开；验收：T49 第 1 步面

## Q4 `runtime` 增量

- [x] Q4.1 `SignatureDescriptor`（params/ret/validate）：先写失败用例——编码断言；12/13 在 T/R → false；14 合法；再写 class；验收：与 m2 §1 一致
- [x] Q4.2 `SignatureVerifier.verify`（纯静态）：先写失败用例——**单次 `is (T1..Tn) -> R`**：非函数值/参数个数/逐参/返回任一不符 → None；合法 → 描述符；禁高阶由 R 取具体非函数类型承接；再写一次 `is` 判定；验收：T30 前置，类无实例/无构造
- [x] Q4.3 `SignatureVerifier.cached(entry: HostCallback)`：先写失败用例——已验签 → 返回 `entry.sig`；未验签 → None；幂等复用计数；再写条目缓存；验收：不做「对象 → 条目」定位
- [x] Q4.4 `HostCallback`（fn/sig）：先写失败用例——条目构造/字段保真、pin 同对象同 ID、条目强引用保活；再写 class；验收：T30 前置
- [x] Q4.5 H63 `host_call_trampoline`（基础）：先写失败用例——栈底 fetch（tag≠10 → 8）、逐参转换（值型/句柄型/14）、调用 fn、值型原值/引用型登记 1 槽（hwTop 断言）、含 CALL_HOST → `flags.bit0` + deopt 源汇编期禁令、防御 -1 → 99；再写 helper；验收：T31 基础、与 user helper 转发语义逐位一致
- [x] Q4.6 H63 异常与重入：先写失败用例——fn 抛异常 → 21 + cause（完整栈、桥打印）+ site=CALL_HOST 偏移；重入（闭包内再调 JIT，深度 ≥3）独立事务、内层错误不影响外层；新 ctx 分配/释放沿用 `LibC.malloc/free`；再写 catch-all + 新 ctx；验收：T31/T60
- [x] Q4.7 H64 `host_get_field`：先写失败用例——值型直取零登记、句柄型（4–14）登记 1 槽、obj tag≠11 → 8、index 防御 → 99；再写字段表访问；验收：T35
- [x] Q4.8 H65 `host_set_field`：先写失败用例——值型/句柄型写、宿主可见（同一对象）、`mutable=false` → 19、obj tag≠11 → 8、不登记槽、变更型标记 + 含其函数 `flags.bit0`；再写变更型 helper；验收：T35
- [x] Q4.9 `PromotionGroup`：先写失败用例——`add` 幂等计数（双闭包共享捕获 → 计数 2）、`release` 归零释放（gen+1）、`contains`、常量不入组、try/finally 豁免；再写组清单；验收：T49 第 1 步
- [x] Q4.10 `HandleTable` 条目标签扩展 + 提升协作：先写失败用例——HostCallback(tag=10)/宿主类实例(tag=11) 的 pin/fetch/get 往返；`moveOutGroup` 原地提升（ID/gen 不变、不重用）；槽级免级联（捕获容器只迁出容器 1 槽）；再写条目扩展；验收：T49/T57
- [x] Q4.11 `Interp` CALL_HOST 语义：先写失败用例——解释器路径与 H63 转发逐位一致（同用例对拍）；v2 单元含 0x79 可执行；失败后不执行后续指令；再写解释循环扩展；验收：T33
- [x] Q4.12 `DbgDump` 报告扩展：先写失败用例——13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`（大类名，不取对象/不解析类名）；其余 M1 §9.16 规则逐条沿用（三行模板、条目格式、槽位序号为键、`site=-1`/`dbgBase=0`、`-1`/`-2` 不转储、最深帧获胜）；再写呈现更新；验收：T60

## Q5 根包增量

- [x] Q5.1 `ClassRegistry.register/snapshot/resolve`：先写失败用例——注册/查询；同名类重复 → `RegistrationException(kind=DuplicateClass)`；类名与函数名冲突 → `FunctionNameClash`；拒绝后不登记；快照隔离；再写注册表 + 锁；验收：T55 前置
- [x] Q5.2 `ReflectRegistrar.registerType<T>`：先写失败用例——全成员枚举（字段/prop/mut prop/func/static let/static prop/static func/constructors）；`static var`/`static mut prop` 跳过；支撑面外类型跳过；命名冲突跳过——逐项 diagnostics 断言；自动 ≡ 手工逐项对拍；JSON 谱系拒绝（`JsonFamily`）、关闭反射拒绝（`ReflectionUnavailable`）；哑火对拍（注册条目对 16–19 永不匹配）；再写 std.reflect；验收：T55
- [x] Q5.3 `ReflectRegistrar.mapType/buildCtor`：先写失败用例——值型直映；std 句柄类型名映射 4–11；其余类 → 14 + typeRef（JSON 除外）；不可映射跳过 + 诊断；构造器 `apply` 适配；泛型类按具体实例化；再写映射表；验收：T55/T54
- [x] Q5.4 `Compiler.registerClass` / `registerType<T>`：先写失败用例——端到端注册后 `u.f`/`u.m()`/`User(...)` 可用；快照语义；关闭反射/JSON 谱系明确报错且不登记；四类类名冲突（已注册类/函数名/内建类型名/关键字）→ `RegistrationException`（kind/name/occupiedBy）；编译期可判优先；拒绝 ≠ 跳过（成员冲突仍走跳过 + `RegistrationSkipped`）；消息三段 + hint 逐 kind；再写门面转发；验收：T54/T55
- [x] Q5.5 `JitClosureId` 值类型：先写失败用例——构造/`INVALID=0`、值语义（拷贝后 ID 相同）；再写 struct；验收：T49 前置
- [x] Q5.6 `JitFunction` 闭包包装实例的 `call<T>`：先写失败用例——桥内部构造（单元 + `JitClosureId`）；调用 = 新桥调用（闭包帧 `locals[0]`）；结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；重入 ≥3；卸载后调用 → 19（site=-1）；入口实例帧格式不变；再写包装；验收：T49
- [x] Q5.7 `JitFunction.close/isClosed`（闭包包装）：先写失败用例——close 幂等、计数 −1/归零释放、close 后调用 → 19、旧 ID 校验拦截、非闭包包装 `close` → 19（site=-1）且 `isClosed=false`；再写 close 协议；验收：T49
- [x] Q5.8 `CallMarshal` 参数 Marshal + 行：先写失败用例——注册类实参 `is C`（含子类）→ pin（tag=11）；null → 19（site=-1）；多参混排（值型/句柄型/14）；同一对象身份（实参 ≡ 闭包内引用 ≡ 返回值带回）；再写 Marshal 扩展；验收：T57
- [x] Q5.9 `CallMarshal` 解包表 + 行：先写失败用例——`retType=12 → JitClosureId`（提升组已登记）、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 实例引用`；T 校验；再写解包；验收：T49/T57
- [x] Q5.10 `CallMarshal` 验签 + HostClosure 参数行：先写失败用例——声明 HostClosure 参数 → 单次 `is` 验签 → pin(tag=10)；失败 → 19（site=-1）；禁高阶复检；再写参数行；验收：T30
- [x] Q5.11 `JitFunction` 状态扩展 + `callFor<Fn>`：先写失败用例——单元持有 ClassRegistry 快照/提升组表；`callFor<Fn>(args): JitFunction`（返回闭包入口，零运行期判定）；实参面与 `call<T>` 一致（允许宿主闭包）；包装值直接作实参 → 19；再写状态 + API；验收：T30 并入验签组
- [x] Q5.12 槽 14 链内传参与 HostClosure 签名含 14：先写失败用例——14 形参/局部/返回声明；跨 CALL_FUNC 传递 × 深度 ≥3；链内返回；嵌套闭包捕获 14（快照 = ID 拷贝）；HostClosure 签名含 14 的验签/执行（R=14 → 登记 1 槽）；再写前端 + H63 扩展；验收：T58/T59

## Q6 验收

- [x] Q6.1 T30 验签与 Marshal：先写/补齐用例——失败面全 19（site=-1）；验签一次缓存；禁高阶双重拒绝；同名冲突编译错误；再收敛；验收：T30 全绿
- [x] Q6.2 T31/T60 CALL_HOST 与异常：先写/补齐用例——21 与 99 严格区分；cause 完整栈（帧数/顺序）；并发失败互不串扰；终止语义（错误点后续不执行）；再收敛；验收：T31/T60 全绿
- [x] Q6.3 T32/T33 交互与差分：先写/补齐用例——`flags.bit0` + deopt 禁令 + 防御 -1 → 99；GC 并发；取消边界；单元卸载与 HostClosure 无交互（per-call 排空）；确定性宿主闭包 × 三引擎逐位一致；再收敛；验收：T32/T33 全绿
- [x] Q6.4 T34 HostObject：先写/补齐用例——同一对象身份往返；null/型别不符 → 19；无泄漏（T27 模式）；再收敛；验收：T34 全绿
- [x] Q6.5 T35/T36 成员访问：先写/补齐用例——糖 ≡ 手写逐位一致；拒绝集全部编译错误（含继承成员未入表）；注册表快照；`mutable` 双防线；再收敛；验收：T35/T36 全绿
- [x] Q6.6 T49 逃逸闭包回桥：先写/补齐用例——白名单/提升/共享计数/close/常量不入组；包装器调用 ≡ 直接 CALL_CLOSURE；卸载 → 19；M1 产物差分回归零变化；无级联（容器捕获提升后元素可读、引用身份不变）；再收敛；验收：T49 全绿
- [x] Q6.7 T54/T55/T57/T58/T59 构造与注册：先写/补齐用例——每次求值新实例（身份独立）；自动 ≡ 手工；重载解析/歧义；实参注入全通道；窗口账目（每次构造/R=14 登记 1 槽）；再收敛；验收：五个 T 编号全绿，M1 全量零回归
