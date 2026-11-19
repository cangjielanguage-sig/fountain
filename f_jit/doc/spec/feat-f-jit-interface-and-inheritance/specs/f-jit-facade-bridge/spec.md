## ADDED Requirements

### Requirement: 接口注册与父成员继承

`registerInterface<I>()` SHALL 接受接口类型（SHALL NOT 要求 `I <: Object`），并把接口登记为与类同表的描述符（`isInterface = true`，无字段、无构造器）。

接口方法绑定 SHALL 来自 `@JitBind` 生成的强类型闭包（首参 14 → 强转到接口 → 直调）；SHALL NOT 依赖反射 `apply`（接口方法是抽象声明，调用必失败）。未标注 `@JitBind` 的接口 SHALL 在注册期被拒绝并给出诊断。

注册类或接口时，**父类型的公共成员 SHALL 一并登记**：类沿 `superClass` 链、接口沿 `superTypes` 链；同名成员以子类型声明为准。父类字段 SHALL 在子描述符内重新编号（字段表按 `accepts` 区分同 index 的访问器）。

类型码 14 的实例判定 SHALL 覆盖「类祖先 ∪ 接口实现」：`CallMarshal` 的形参校验与 `E as I` 共用同一判定。

#### Scenario: 接口形参调用成员

- **WHEN** 注册 `@JitBind interface Greeter { func greet(): String }` 与实现类，编译 `{ g: Greeter => g.greet() }` 并以实现类实例调用
- **THEN** 返回实现类的字符串，且单元由机器码执行（`isJitBacked`）

#### Scenario: 父接口成员可见

- **WHEN** `interface Greeter <: Named`，只注册子接口，调用 `{ g: Greeter => g.name() }`
- **THEN** 父接口 `Named` 的方法可用（前提：`Named` 已注册）

#### Scenario: 接口作为返回类型

- **WHEN** 单元返回实现类实例，宿主 `call<Greeter>([])`
- **THEN** 取回的对象可调用接口成员，不报「T 不是可解包类型」

#### Scenario: 未绑定接口被拒绝

- **WHEN** 注册一个没有 `@JitBind` 的接口
- **THEN** 注册期抛 `RegistrationException`，消息要求使用 `@JitBind`
