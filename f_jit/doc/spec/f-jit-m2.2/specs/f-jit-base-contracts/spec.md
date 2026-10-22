# Spec Mirror — f-jit-base-contracts（M2.2 增量）

> 只收录 `f-jit-m2.2` 改动的 requirement；其余 capability 的验收仍由
> `check_scenarios.sh m2` / `m1` 承担。与主规范的差异仅限本变更的改动本身。

### Requirement: 类描述符与字段项

`base` SHALL 提供 `ClassDescriptor`（`name`、`fields`、`methods`、`ctors`、`parents`）与 `PublicField`（`name`、`type`、`index`、`mutable`、`typeRef`），供 `Compiler`、`ClassRegistry` 与 `ReflectRegistrar` 共用。`PublicField.type` SHALL 为 LocalType 0–14（M3 才扩至 0–19），`index` 为 H64/H65 的 index 实参，`mutable` 表示 `var`/`let`，`typeRef` 仅在 14 型字段上携带目标类名。

M2.2 SHALL 增 `ClassDescriptor.parents: Array<String>`：**直接父类在前、逐级到 `Object`、不含自身**，由 `ReflectRegistrar` 从反射父链填充（同类 `ancestry` 去首项），默认空数组。它**只**用于静态子类型判定（`ClassRegistryView.isSameOrSubclass`），SHALL NOT 被成员解析消费——前端仍只查本类条目。手工注册的类不填即只与自身同型。

#### Scenario: 字段项构造保真

- **WHEN** 构造 `PublicField(name: "age", type: 0, index: 3, mutable: true, typeRef: None)` 并读回
- **THEN** 五个字段与入参逐项一致；`mutable=false` 的字段在后续前端校验中被视为只读

#### Scenario: 14 型字段携带 typeRef

- **WHEN** 构造一个 `type=14` 且 `typeRef=Some("Address")` 的字段
- **THEN** 链式成员解析可读取 `typeRef`；非 14 型字段的 `typeRef` 不被消费

#### Scenario: 父链用于静态子类型判定

- **WHEN** 注册一个 `Admin <: User` 的类后，用 `Admin` 的类描述符查 `parents`
- **THEN** 链中含 `User`；`isSameOrSubclass("Admin", "User")` 为真，反方向为假

### Requirement: 方法与构造器项

`base` SHALL 提供 `PublicMethod`（`name`、`bind`）与 `PublicCtor`（`params`、`adapter`）。`PublicMethod.bind` SHALL 为首参固定为该类的预定义函数，签名 `(C, T...) -> R`；`R == 14` 时 SHALL 在 `PredefinedFunction.retName` 记录**具体返回类名**（未知则空串，SHALL NOT 猜测）。`PublicCtor.params` 为形参类型序列；`adapter` 接收已解包的仓颉值数组并返回该类实例，适配器异常按 21 处理、防御性失败按 99 处理。

#### Scenario: 构造器重载与适配器

- **WHEN** 为一个类登记参数序列不同的两个 `PublicCtor`
- **THEN** 两条条目均保真保留，`adapter` 可被调用并返回该类实例；重载解析由前端 `ctorsOf` 承担

#### Scenario: 返回类名驱动静态解析

- **WHEN** 一个方法声明返回 14 且 `retName` 非空
- **THEN** `u.m().f` 的链式成员按该返回类解析；`retName` 为空时链式访问与 `as` 收窄一律编译期报「类名未跟踪」

