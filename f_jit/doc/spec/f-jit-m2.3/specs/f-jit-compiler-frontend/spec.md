# Spec Mirror — f-jit-compiler-frontend（M2.3 增量）

> 只收录 `f-jit-m2.3` 改动的 requirement；其余仍由 `check_scenarios.sh m2` 等承担。

### Requirement: 收窄转型 `E as T` / `E as T ?? V`

源语言 SHALL 支持 `E as T` 与 `E as T ?? V`。`as` 与 `??` SHALL 位于最低结合层（低于 `||`），`??` 右结合；`T` 的取值域与类型注解一致（内建类型 / 已注册类名 / 函数类型记法）。判定 SHALL **优先在编译期完成**，编译期判不了的 SHALL 落到运行期：

- `E` 的静态类型已是 `T` 或其子类 ⇒ 表达式类型为 `T`、结果为 `E`（**零运行期动作**，`V` 不求值）；
- `E` 与 `T` 都是 14、且 `T` 在 `E` 的父类方向（**下转型**）⇒ 运行期按对象实际类判定；
- `E` 是 14 但**类名未跟踪**（方法返回值无 `retName`、`if` 合流、容器元素等）⇒ 运行期判定；
- 与 `T` 不相容（如 `Int64` 对 `String`）、或 `T` 为函数类型 ⇒ SHALL 编译期拒绝；
- `V` 的静态类型 SHALL 为 `T` 或其子类，且 SHALL 只在转型**失败**时求值。

运行期判定 SHALL 由注册期为每个已注册类合成的 `$as$<类名>` 自动函数承担（`(14) -> Bool`，按反射父链判定，子类实例算命中）。转型失败时：`E as T` SHALL 以 **7 `BAD_CAST`** 失败；`E as T ?? V` SHALL 取 `V`。裸 `??`（无 `as`）与单 `?` SHALL 仍为语法错误。

#### Scenario: 同类与子类放行

- **WHEN** `u: User` 写 `u as User ?? u`，或 `a: Admin`（`Admin <: User`）写 `a as User ?? a`
- **THEN** 编译通过、运行期零动作，取 `E` 原值

#### Scenario: 下转型按运行期判定

- **WHEN** `u: User` 写 `u as Admin ?? Admin("fallback")`，分别传入 `Admin` 实例与 `User` 实例
- **THEN** 前者取原对象；后者取兜底值

#### Scenario: 裸 `as` 失败报 7

- **WHEN** `u: User` 写 `u as Admin` 且运行期对象不是 `Admin`
- **THEN** 以 `BAD_CAST`（7）失败，SHALL NOT 记为宿主异常 21

#### Scenario: 类名未跟踪走运行期

- **WHEN** 左面是返回 14 但无 `retName` 的调用（如静态包装函数）
- **THEN** 编译通过，运行期按 `$as$<T>` 判定

#### Scenario: 不相容拒绝

- **WHEN** `x: Int64` 写 `x as String ?? "d"`
- **THEN** 编译期拒绝，消息含两侧类型

#### Scenario: 兜底的类型与惰性

- **WHEN** 写 `x as Int64 ?? (x / 0)`、`x as Int64 ?? nope`、`u as User ?? 0`
- **THEN** 分别为：返回 `x`（兜底未执行）、编译期报未定义名字（兜底仍被降级）、编译期报「右面必须是 User 或其子类」

#### Scenario: 语法面

- **WHEN** 写 `x as Int64`（合法）、`x ?? 0`、`x ? 0`
- **THEN** 裸 `as` 解析为 `castor(var(x) as Int64)`；后两者以语法/词法错误拒绝

