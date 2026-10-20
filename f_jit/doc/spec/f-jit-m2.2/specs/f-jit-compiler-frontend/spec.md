# Spec Mirror — f-jit-compiler-frontend（M2.2 增量）

> 只收录 `f-jit-m2.2` 改动的 requirement；其余 capability 的验收仍由
> `check_scenarios.sh m2` / `m1` 承担。与主规范的差异仅限本变更的改动本身。

### Requirement: 静态收窄表达式 `E as T ?? F`

源语言 SHALL 支持 `E as T ?? F`。`??` SHALL 位于最低结合层（低于 `||`）且右结合；`T` 的取值域与类型注解一致（内建类型 / 已注册类名 / 函数类型记法）。判定 SHALL 全部在编译期完成：`E` 的静态类型为 `T` 或 `T` 的子类 ⇒ 表达式类型为 `T`、结果为 `E`（运行期零动作）；`T` 在 `E` 的父类方向（下转型）、与 `T` 不相容、或无法取得 `E` 的静态类名 ⇒ SHALL 编译期拒绝并给出区分性消息；`T` 为函数类型 ⇒ SHALL 编译期拒绝。`F` 的静态类型 SHALL 为 `T` 或其子类。`F` SHALL NOT 在运行期求值，但 SHALL 被完整降级（类型检查、名字解析、明确赋值、捕获分析）。裸 `as`（缺 `??`）与裸 `??` SHALL 以语法错误拒绝。

#### Scenario: 同类与子类放行

- **WHEN** `u: User` 写 `u as User ?? u`，或 `a: Admin`（`Admin <: User`）写 `a as User ?? a`
- **THEN** 编译通过，表达式类型为 `User`，运行期取 `E` 原值

#### Scenario: 下转型拒绝

- **WHEN** `u: User` 写 `u as Admin ?? u`
- **THEN** 编译期拒绝，消息说明需要运行期类判定

#### Scenario: 不相容拒绝

- **WHEN** `x: Int64` 写 `x as String ?? "d"`
- **THEN** 编译期拒绝，消息含两侧类型

#### Scenario: 无法静态判定拒绝

- **WHEN** 左面是 `null`、容器元素、`if` 两分支不同类、或返回类名未登记的方法调用
- **THEN** 编译期拒绝，消息说明「类名/类型未跟踪」

#### Scenario: 兜底不求值但受检

- **WHEN** 写 `x as Int64 ?? (x / 0)` 与 `x as Int64 ?? nope`
- **THEN** 前者运行期返回 `x`（兜底未执行），后者编译期报未定义名字（兜底仍被降级）

#### Scenario: 语法拒绝面

- **WHEN** 写 `x as Int64`（无 `??`）或 `x ?? 0`
- **THEN** 均以语法错误拒绝

