# Spec Mirror — f-jit-facade-bridge（M2.1 增量）

> 本镜像**只收录 `f-jit-m2.1` 实际改动的 3 条 requirement**（2 条 MODIFIED + 1 条 ADDED）。
> 其余 capability、以及本 capability 中未被本变更触碰的 requirement，其验收仍由
> `check_scenarios.sh m2`（`doc/spec/f-jit-m2/`）承担；两份矩阵互补，不重复。
>
> 与主规范 `openspec/specs/f-jit-facade-bridge/spec.md` 的差异仅限「收口」时的两处措辞更正，
> 原因见 `doc/spec/f-jit-m2.1/verify.md` §3。

## Purpose

根包 `fountain::f_jit` 是用户唯一入口。M2.1 把类注册的**成员绑定层**从「一律反射」换成
「类型化绑定优先、反射兜底」：新增 `JitBindings` 四表载体、反射默认拒绝引用型实例方法、
`@JitBind` 宏自动生成绑定。

### Requirement: 编译门面与注册表快照

门面 SHALL 支持注册/注销/查询预定义函数并给出已注册清单，重名与超过上限 SHALL 在编译时刻失败；注册表的快照语义 SHALL 保证「注册变更不影响已编译产物」。M2 SHALL 增加 `Compiler.registerClass(desc)` 与 `Compiler.registerType<T>()`：类名与已注册类、已注册函数名、内建类型名或关键字冲突 SHALL 以 `RegistrationException` 拒绝（对应 kind，`occupiedBy` 给出占用者），且**不登记**；注册成功后快照语义与预定义函数一致；手工注册与反射注册 SHALL 可混用。

M2.1 SHALL 把 `registerType<T>()` 的第二个具名参数定为 `bindings: JitBindings`（取代 `overrides: Array<PublicMethod>`）。`JitBindings` SHALL 携带四张表：`methods: Array<PublicMethod>`、`fields: Array<JitFieldBinding>`、`ctors: Array<PublicCtor>`、`statics: Array<PredefinedFunction>`。注册 SHALL 先按 `TypeInfo.of<T>().name` 取 `@JitBind` 在包初始化期登记的绑定，再把显式 `bindings` **合并**其上：同一成员（方法按名、字段按名、构造器按形参码、静态成员按名）以显式项为准，其余自动登记项 SHALL 继续生效，SHALL NOT 因显式传参而整体丢弃。

#### Scenario: 重名与超限

- **WHEN** 注册重名函数、或注册数超过上限
- **THEN** 在编译时刻以编译期错误失败，并给出含名字与清单的诊断

#### Scenario: 类名冲突拒绝

- **WHEN** 注册一个与已注册类/函数/内建类型/关键字同名的类
- **THEN** 抛出 `RegistrationException`，`kind` 与 `occupiedBy` 正确，注册表不变

#### Scenario: 快照语义

- **WHEN** 某源码编译成功后修改注册表（注销、新增函数或类）
- **THEN** 已编译产物行为不变，再次编译才反映新注册表

#### Scenario: 类型化绑定优先于反射

- **WHEN** 以 `bindings:` 传入某方法的类型化绑定后注册
- **THEN** 该方法的槽位指向类型化实现（调用不经过 `InstanceFunctionInfo.apply`），其余成员仍走反射

#### Scenario: 自动登记与显式覆盖

- **WHEN** 类已用 `@JitBind` 标注并已完成包初始化，注册时显式传入**部分**成员的绑定
- **THEN** 同名成员以显式项为准；未被显式覆盖的成员仍取自动登记，不回退反射

### Requirement: 反射注册的映射与拒绝

类型映射 SHALL 为：值型 0–3 直映；std 句柄类型按名称映射 4–11；其余类 → 14 + `typeRef`；不可映射成员 SHALL 跳过并记 `RegistrationSkipped` 诊断。`static var` / `static mut prop` SHALL 跳过；成员命名冲突 SHALL 跳过 + 诊断（类名冲突仍为拒绝）。JSON 谱系类（`JsonValue` / `JsonObject` / `JsonArray` / `JsonNull`）SHALL 以 `RegistrationException(kind=JsonFamily)` 拒绝且不登记；关闭反射的构建 SHALL 以 `kind=ReflectionUnavailable` 拒绝。

M2.1 SHALL 追加一条拒绝：**实例方法**的签名若含引用型（`LocalType.STRING`–`HOST_OBJECT`）形参或返回，反射注册 SHALL **不生成绑定**，改为 `RegistrationSkipped` + Warn 诊断（GAP-13：该形态经 `ApplyCJMethod` 的 MCC `ArgValue` 转换必现 SIGSEGV）。该判据 SHALL 只作用于实例方法；`bindings` 中同名方法已提供类型化绑定时 SHALL 不跳过。

#### Scenario: 过滤与诊断

- **WHEN** 类含 `static var`、不可映射类型成员或命名冲突成员
- **THEN** 这些成员被跳过，诊断中逐项可见；其余成员正常注册

#### Scenario: JSON 谱系拒绝

- **WHEN** `registerType<JsonObject>()`
- **THEN** 抛出 `RegistrationException`（`kind=JsonFamily`），不登记；注册表不变

#### Scenario: 引用型实例方法默认拒绝

- **WHEN** 类含 `func greet(s: String): String`，未提供类型化绑定就注册
- **THEN** 该方法不进入方法表，编译 `u.greet("z")` 报「未注册方法」；同类值型方法（如 `bump(Int64)`）不受影响

#### Scenario: 提供绑定后放行

- **WHEN** 同一类以 `bindings:` 提供 `greet` 的类型化绑定后注册
- **THEN** 该方法正常入表，连续调用 300 次无崩溃

### Requirement: 类型化绑定与 `@JitBind` 宏

宿主 SHALL 能用类型化绑定替换反射访问，绑定体是「逐参 `as` 成声明类型后静态调用」的闭包。
覆盖面 SHALL 包含：实例方法（`PublicMethod`）、实例字段（`JitFieldBinding`，`let` 无 setter）、
实例属性（get/set 各一条 `PublicMethod`，setter 名 `set<Name>`）、构造器（按形参码匹配 `PublicCtor`，
重载各自成条）、静态函数 / 静态只读字段 / 只读静态属性（按名替换 `auto` 表）。

`@JitBind` 宏 SHALL 修饰**类**，展开为「原类 + 包级登记语句」，SHALL NOT 向类内插入声明，
SHALL NOT 要求注册处传入中间产物。宏 SHALL NOT 展开：私有成员、泛型方法（WARNING）、
`static var` 与 `static mut prop`（属注册面永久排除，WARNING）。

#### Scenario: 类级展开

- **WHEN** 对一个含公共方法、字段、属性、构造器、静态成员的类标注 `@JitBind`
- **THEN** 生成四张表；私有成员不入表；注册处 `registerType<T>()` 后全部成员可经 JIT 调用

#### Scenario: 属性按两次绑定计

- **WHEN** 类含 `mut prop tag: String`
- **THEN** 生成 getter（名 `tag`）与 setter（名 `setTag`）两条绑定，签名分别为 `(C) -> String` 与 `(C, String) -> Unit`

#### Scenario: 构造器重载

- **WHEN** 类含 `init(name: String)` 与 `init(name: String, id: Int64)`
- **THEN** 生成两条 `PublicCtor`，形参码分别为 `[4]` 与 `[4,0]`，调用按实参解析到对应一条

#### Scenario: 静态成员

- **WHEN** 类含 `static let version`、`static prop label`、`static func parse`
- **THEN** 三者各生成一条 `PredefinedFunction` 并替换 `auto` 表中的反射版本；`static var` 不生成

#### Scenario: 类型码在编译期确定

- **WHEN** 宏展开任一成员
- **THEN** 生成的签名码是整数字面量（宏按源码类型名映射），签名码的求值不调用 `TypeInfo`；初始化期仍有 `TypeInfo` 调用，但只用于取全限定名（登记键与 slot 名），不参与类型码
