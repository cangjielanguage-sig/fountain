# Spec Delta

## Purpose

根包 `fountain::f_jit` 是用户唯一入口：编译门面与预定义函数注册表、参数封送与返回解包、统一调用包装、编译去重缓存、适配器注册表与单元卸载编排，并再导出全部用户面声明。M2 增量增加类注册表、反射自动注册、构造器物化、宿主闭包与宿主对象通道、逃逸闭包包装。

## MODIFIED Requirements

### Requirement: 编译门面与注册表快照

门面 SHALL 支持注册/注销/查询预定义函数并给出已注册清单，重名与超过上限 SHALL 在编译时刻失败；注册表的快照语义 SHALL 保证「注册变更不影响已编译产物」。M2 SHALL 增加 `Compiler.registerClass(desc)` 与 `Compiler.registerType<T>()`：类名与已注册类、已注册函数名、内建类型名或关键字冲突 SHALL 以 `RegistrationException` 拒绝（对应 kind，`occupiedBy` 给出占用者），且**不登记**；注册成功后快照语义与预定义函数一致；手工注册与反射注册 SHALL 可混用。

#### Scenario: 重名与超限

- **WHEN** 注册重名函数、或注册数超过上限
- **THEN** 在编译时刻以编译期错误失败，并给出含名字与清单的诊断

#### Scenario: 类名冲突拒绝

- **WHEN** 注册一个与已注册类/函数/内建类型/关键字同名的类
- **THEN** 抛出 `RegistrationException`，`kind` 与 `occupiedBy` 正确，注册表不变

#### Scenario: 快照语义

- **WHEN** 某源码编译成功后修改注册表（注销、新增函数或类）
- **THEN** 已编译产物行为不变，再次编译才反映新注册表

### Requirement: 参数封送与返回解包表

封送 SHALL 按类型表逐行把宿主值转为字节码侧表示（不接受可选/空值、不做隐式宽化），解包 SHALL 按对应表把结果转回宿主值；句柄型返回 SHALL 走逃逸登记并在调用收尾自动回收；清理 SHALL 覆盖正常与异常全路径。M2 SHALL 增加参数行：声明类型为注册类 `C` 时接受 `C` 实例（`is C`，含子类，opaque 视图）→ `pin`（tag=11）→ cell，null → 19；声明为 HostClosure `(T1..Tn) -> R` 时接受仓颉函数值 → 单次 `is` 验签 → pin（tag=10）→ cell，失败 → 19（site=-1）。解包 SHALL 增加行：`retType=12 → JitClosureId`（提升组已登记）、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 宿主类实例引用`。包装值（`JitFunction`）SHALL NOT 直接作实参（→19），回传须由宿主包一层闭包。

#### Scenario: 注册类实参

- **WHEN** 以 `User` 实例（含其子类实例）调用声明为 `User` 形参的单元
- **THEN** 实参以 tag=11 pin 进入；同一对象在闭包内引用与返回值带回时身份相同；null 或非 `User` 实例 → 19

#### Scenario: HostClosure 实参

- **WHEN** 以合法仓颉闭包调用声明为 `(Int64) -> Bool` 的形参
- **THEN** 单次 `is` 验签通过，pin 为 tag=10；非函数值/签名不符 → 19（site=-1）

#### Scenario: 解包三行

- **WHEN** 单元分别返回 12/13/14 型值
- **THEN** 12 解包为 `JitClosureId`（已提升）、13 原样返回宿主闭包引用、14 返回宿主类实例引用；三者均零拷贝

#### Scenario: 包装值不作实参

- **WHEN** 把 `callFor` 或包装 `JitFunction` 直接放入 `args`
- **THEN** 以 19 失败；宿主改包一层闭包后可正常传入

#### Scenario: 全类型行可断言

- **WHEN** 以各类型（整型、浮点、布尔、字符串、十进制、日期时间、时长、区间、正则、列表、映射，以及 M2 新增的宿主闭包、宿主对象引用与闭包返回值）传参与返回
- **THEN** 往返值逐位一致；类型不符时以契约类错误失败（验签失败为 19）

#### Scenario: 全路径清理

- **WHEN** 在某次调用的任一环节（含封送失败、验签失败、执行错误、中断）抛出异常
- **THEN** 本次登记的非逃逸句柄全部回收、上下文与转储缓冲配对释放，无残留

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。M2 SHALL 让 `JitFunction` 同时承载两种绑定的调用语义：入口实例按 M1 六步不变；**闭包包装实例**（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄 → 闭包帧格式），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=-1）。`close()` SHALL 为唯一释放路径（提升组计数 −1、归零释放、幂等）；非闭包包装实例 `close` → 19（site=-1）、`isClosed` 恒 false。`callFor<Fn>(args)` SHALL 调用单元并返回承接其返回闭包的 `JitFunction`（`Fn` 为返回闭包的函数类型，零运行期判定），实参面与 `call<T>` 一致。

#### Scenario: 契约错误统一码

- **WHEN** 参数个数不符、元素类型不符、或请求类型与返回类型不符
- **THEN** 一律抛契约类错误，站点为 -1，源位置为空

#### Scenario: 两形态同接口同行为

- **WHEN** 同源同参分别调用机器码形态与纯字节码形态产物
- **THEN** 结果、错误码、站点与报告文本逐位一致

#### Scenario: 闭包包装调用

- **WHEN** 在 `callFor` 返回的 `JitFunction` 上调用 `call<T>`（重入 ≥3）
- **THEN** 新 ctx、闭包帧、结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致

#### Scenario: close 协议

- **WHEN** 对闭包包装实例重复 `close`，或对入口实例调用 `close`
- **THEN** 前者幂等且归零释放、`isClosed` 转真；后者 19（site=-1）且 `isClosed=false`

#### Scenario: 卸载弱语义

- **WHEN** 闭包逃逸后卸载其单元，再调用包装实例
- **THEN** 以 19 失败（site=-1）；闭包不阻止卸载

### Requirement: 两入口管线与分发校验

源入口 SHALL 走「词法到容器再到引擎」的四步管线；分发入口 SHALL 装载既有容器并按整份字节指纹去重；含预定义函数句柄的容器 SHALL 在加载期被拒绝；入口函数号 SHALL 与容器目录校验。M2 SHALL 让含 14 形参、成员访问或构造的单元经**无注册表分发入口**加载时在加载期拒绝；仅含 M3 JSON 内建码（16–19）的单元不触发该拒绝面（零注册）。

#### Scenario: 含宿主句柄的容器被拒

- **WHEN** 装载一个含预定义函数调用句柄的容器
- **THEN** 加载期以「不支持的内容」语义拒绝，不进入执行

#### Scenario: 注册表依赖面拒绝

- **WHEN** 经分发入口装载含 14 形参/成员访问/构造的单元
- **THEN** 加载期拒绝；同一单元经源入口（带注册快照）可正常编译执行

#### Scenario: 入口校验

- **WHEN** 指定的入口函数号不在容器目录中
- **THEN** 加载期拒绝

### Requirement: 用户面再导出与冒烟

用户 SHALL 能通过一次导入见到全部用户面声明（门面、产物句柄、封送、句柄表、类型与错误码常量、异常、开关、选项、注册项、源单元、调用上下文、源位置、诊断接口）；执行期内部类型 SHALL NOT 出现在用户面。M2 SHALL 再导出 `ClassDescriptor` / `PublicField` / `PublicMethod` / `PublicCtor` / `RegistrationException` / `RegistrationRejectKind` / `JitClosureId`，以及 `Compiler.registerClass` / `Compiler.registerType<T>` / `JitFunction.callFor<Fn>` / `JitFunction.close` / `JitFunction.isClosed`；`ClassRegistry` / `ReflectRegistrar` SHALL 保持 `protected`。

#### Scenario: 一次导入可用

- **WHEN** 用户代码执行 `import fountain::f_jit.*` 后编译并调用一个最小 M2 示例（注册类 → 编译 → 传宿主闭包/对象 → close）
- **THEN** 全程可用且行为与预期一致

#### Scenario: 内部类型不外泄

- **WHEN** 用户代码引用 `ClassRegistry`、`ReflectRegistrar`、上下文、引擎枚举等内部类型
- **THEN** 编译期不可见（仅模块内 `protected` 可见）

## ADDED Requirements

### Requirement: 类注册表

根包 SHALL 提供 `protected class ClassRegistry`（宿主侧类注册表）：`register(desc)` 注册类、`snapshot()` 生成编译期只读视图、`resolve(name)` 查询类、`classOfField` / `classOfMethod` / `classOfCtors` 解析辅助。同名类重复注册、类名与已注册函数名/内建类型名/关键字冲突 SHALL 以 `RegistrationException` 拒绝且不登记；注册变更不影响已编译单元的快照语义与手工注册混用规则 SHALL 与预定义函数一致。

#### Scenario: 注册与查询

- **WHEN** 注册一个含字段/方法/构造器的类并查询
- **THEN** `resolve` 返回同一描述符；字段/方法/构造器辅助查询命中且数据保真

#### Scenario: 拒绝后不登记

- **WHEN** 注册同名类或与函数名冲突的类
- **THEN** 抛出对应 `RegistrationException`；`resolve` 仍返回原类或 None，注册表不变

#### Scenario: 快照隔离

- **WHEN** 取得快照后修改注册表
- **THEN** 快照内容不变；新快照才反映修改

### Requirement: 反射自动注册的覆盖面

根包 SHALL 提供 `protected class ReflectRegistrar`，经 `std.reflect` 在**注册期**枚举 `T` 的 public 成员，批量生成 `ClassDescriptor` 条目。覆盖面 SHALL 为：`public let` / `public var`（字段）、`public prop` / `public mut prop`（属性包装）、`public func`（方法绑定）、`public static let` / `public static prop`（静态只读包装）、`public static func`（静态方法）与 public 构造函数。自动注册结果 SHALL 与手工注册逐项等价；字节码/JIT 执行路径 SHALL 零反射。

#### Scenario: 全覆盖与逐项等价

- **WHEN** `registerType<User>()` 后与同一类的手工注册描述符对拍
- **THEN** 字段表、方法表、属性包装、静态包装、构造器条目与类型码逐项相等

#### Scenario: 反射仅在注册期

- **WHEN** 检查字节码/JIT 执行路径
- **THEN** 无任何 `std.reflect` 调用；访问器为注册期生成的宿主闭包

### Requirement: 反射注册的映射与拒绝

类型映射 SHALL 为：值型 0–3 直映；std 句柄类型按名称映射 4–11；其余类 → 14 + `typeRef`；不可映射成员 SHALL 跳过并记 `RegistrationSkipped` 诊断。`static var` / `static mut prop` SHALL 跳过；成员命名冲突 SHALL 跳过 + 诊断（类名冲突仍为拒绝）。JSON 谱系类（`JsonValue` / `JsonObject` / `JsonArray` / `JsonNull`）SHALL 以 `RegistrationException(kind=JsonFamily)` 拒绝且不登记；关闭反射的构建 SHALL 以 `kind=ReflectionUnavailable` 拒绝。

#### Scenario: 过滤与诊断

- **WHEN** 类含 `static var`、不可映射类型成员或命名冲突成员
- **THEN** 这些成员被跳过，诊断中逐项可见；其余成员正常注册

#### Scenario: JSON 谱系拒绝

- **WHEN** `registerType<JsonObject>()`
- **THEN** 抛出 `RegistrationException`（`kind=JsonFamily`），不登记；注册表不变

### Requirement: 构造器物化与执行

根包 SHALL 把每条已注册 `PublicCtor` 物化为**单元私有预定义函数（user helper）**，`C(args...)` 降低为 `CALL_HELPER <ctor-user-hid>`；hid 位于 user helper 值域 `[0x0100,0xFFFF]`，注册期确定 trampoline，零间址。构造执行体 SHALL 始终在宿主侧；适配器接收已解包值数组并返回该类实例；每次求值 SHALL 产生新实例（无缓存/去重），结果登记 1 槽（分配型）。适配器未捕获异常 → 21 + cause；防御性失败 → 99；含构造的函数 SHALL 置 `flags.bit0` 并拒绝 deopt 源；构造结果可进入成员链、CALL_FUNC 转发与 `retType=14` 带回。

#### Scenario: 每次求值新实例

- **WHEN** 同一调用内连续构造两次
- **THEN** 得到两个独立实例、不同句柄 ID；字段修改互不影响

#### Scenario: 嵌套构造

- **WHEN** 以 `User(Addr(...))` 构造且 `Address` 已注册
- **THEN** 内层构造先执行并作为 14 实参传入外层；结果为 `User` 实例

#### Scenario: 适配器异常

- **WHEN** 构造适配器抛出仓颉异常
- **THEN** 写入 21 + 完整栈，site 为构造调用偏移；不写成 99

### Requirement: 宿主对象实参通道

根包 SHALL 在三个方向支持宿主对象：① 源入口实参——`call<T>` 的注册类形参按 `is C`（含子类）pin 为 tag=11，null → 19（site=-1）；② 槽 14 链内传参——14 形参/局部/返回沿 `CALL_FUNC` 传递（与 12/13 同款），传递期间由被调帧窗口存活，链内零校验，可被嵌套闭包捕获（快照 = ID 拷贝）；③ HostClosure 签名含 14——验签覆盖具体类，H63 逐参 `get` 实例引用，R=14 时窗口登记 1 槽。三方向 SHALL 零新指令、零新 helper、零格式变更；同一对象在实参、闭包内引用与返回值带回时 SHALL 保持身份。

#### Scenario: 源入口实参身份

- **WHEN** 以 `User` 实例调用单元并经 `retType=14` 返回
- **THEN** 返回对象与实参对象为同一引用；子类实例可作为父类声明实参

#### Scenario: 槽 14 链内传递

- **WHEN** 14 形参跨 `CALL_FUNC` 传递深度 ≥3 并链内返回
- **THEN** 每层均持有同一 ID，语义与 12/13 全等；无额外窗口登记

#### Scenario: HostClosure 签名含 14

- **WHEN** 宿主闭包声明为 `(User) -> Order` 并接收/返回注册类实例
- **THEN** 验签通过后 H63 传入/返回实例引用；R=14 每次登记 1 槽
