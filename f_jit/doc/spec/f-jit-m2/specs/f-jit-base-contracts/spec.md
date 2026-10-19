# Spec Delta

## Purpose

`base` 包承载全模块共享的契约：类型与错误码常量命名空间、公共值类型、两个异常类型与诊断接口，不持有任何执行状态。M2 在此基础上增加宿主互操作所需的类型码、注册协议值与注册期拒绝异常。

## MODIFIED Requirements

### Requirement: LocalType 编码与查询

`LocalType` SHALL 以常量命名空间形式给出 0–14 十五个类型码（`I64`/`F64`/`BOOL`/`UNIT`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`LIST`/`MAP`/`CLOSURE`/`HOST_CLOSURE`/`HOST_OBJECT`），并提供 `name`、`isHandle`（4–14 为真、0–3 为假）与 `fromToken` 查询；合法码集 SHALL 按字节码 `verMajor` 分派：verMajor 1 允许 0–12，verMajor 2 允许 0–14，verMajor 3 允许 0–19（15=Any、16–19=JSON，仅供 M3 登记），**20–255 恒拒绝**。`HOST_CLOSURE`（13）为宿主闭包句柄型，空安全同 M1 句柄型；`HOST_OBJECT`（14）为不透明宿主对象引用，恒非空。

#### Scenario: 码值与查询一致

- **WHEN** 读取 `LocalType.HOST_CLOSURE`、`LocalType.HOST_OBJECT` 并调用 `name` / `isHandle`
- **THEN** 值分别为 13、14，`name` 非空，二者 `isHandle` 均为真，且 0–3 仍为假

#### Scenario: 版本分派合法集

- **WHEN** 分别以 verMajor 1、2、3 校验类型码 13、14、15–19、20
- **THEN** verMajor 1 拒绝 13 及以上；verMajor 2 放行 13/14 并拒绝 15 及以上；verMajor 3 放行 15–19 并拒绝 20；20–255 在任何版本均拒绝

### Requirement: TypeToken 编码

`TypeToken` SHALL 给出句柄类型 token 0–11（`RESERVED`/`LIST`/`MAP`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`CLOSURE`/`HOST_CLOSURE`/`HOST_OBJECT`）与 `name`，且与 `LocalType` 的映射集中在同一处。token 11 表示「不透明宿主对象引用」大类，与句柄条目标签同源编码；M3 的 JSON 内建码 SHALL 复用 tag 11，不得为 JSON 另开 token/tag。

#### Scenario: token 与类型码对应

- **WHEN** 逐项读取 0–11 的 token 常量并调用 `name`
- **THEN** 与规格类型 token 表逐项一致，`name` 非空，token 10/11 分别对应 13/14

#### Scenario: token 11 的大类归属

- **WHEN** 以 token 11 描述一个宿主对象句柄
- **THEN** 语义为「不透明宿主对象引用」大类，不因具体注册类名而分叉；M3 的 JSON 句柄继续复用该 tag

### Requirement: 错误码表与描述

`ErrCode` SHALL 给出 `OK`/`DEOPT`/`INTERRUPT` 与 1–21、`CONCURRENT_MOD`(23)、`HELPER_PANIC`(99) 全量错误码，并提供 `describe` 与 `isHostSide` 查询；未知码 SHALL 返回非空兜底描述。`HOST_EXCEPTION`（21）为仓颉侧异常专用码，覆盖 CALL_HOST 闭包、预定义与包装调用、构造适配器、成员访问器全部宿主侧调用面；`99` 仍为引擎侧实现缺陷兜底，二者 SHALL 严格区分。

#### Scenario: 描述可断言

- **WHEN** 读取 `ErrCode.HOST_EXCEPTION` 并调用 `describe` / `isHostSide`
- **THEN** 值为 21，描述含「宿主异常」语义，`isHostSide(21)` 为真，其余非宿主侧码为假

#### Scenario: 21 与 99 不混用

- **WHEN** 分别以宿主闭包抛异常与引擎内部缺陷触发失败
- **THEN** 前者得到 21、后者得到 99；`describe(99)` 不宣称宿主语义

#### Scenario: 宿主侧判定

- **WHEN** 对宿主侧错误码（21）与引擎侧兜底码（99）分别调用 `isHostSide`
- **THEN** 仅 21 判定为宿主侧，99 与其余码均为假

### Requirement: 版本常量

`Version` SHALL 保留 M1 的 `MAJOR=1` / `MINOR=14` 常量不变（M1 写入/读取路径与既有断言零回归），并新增 `M1_MAJOR=1`、`M2_MAJOR=2`、`M2_MINOR=0`、`M3_MAJOR=3`、容器头 `HDR_SIZE=36`、`MAGIC="FBC1"` 与 `supportedMajors()`（至少含 1、2）。M2 源编译 SHALL 通过显式编译目标/版本参数选择 `M2_MAJOR/M2_MINOR`（verMajor 2 / verMinor 0），SHALL NOT 通过改写 legacy `MAJOR`/`MINOR` 来表达 M2；常量 SHALL 与 `.fbc` 读写两侧共用同一份定义。

#### Scenario: 常量自洽

- **WHEN** 读取 `M1_MAJOR` / `M2_MAJOR` / `M2_MINOR` / `supportedMajors()` 并构造最小容器头
- **THEN** 值分别为 1 / 2 / 0，集合含 1 与 2；写出的头可被同版本读取侧识别

#### Scenario: legacy 常量与 M1 路径不变

- **WHEN** 读取 `MAJOR` / `MINOR` 并以它们构造 verMajor 1 容器
- **THEN** 值仍为 1 / 14，头字段、magic 与长度解释与 M1 完全一致；M2 新增常量不改变既有语义

#### Scenario: M2 目标版本显式选择

- **WHEN** 以 M2 编译目标编译源单元
- **THEN** 写出的头为 verMajor 2 / verMinor 0；legacy `MAJOR`/`MINOR` 仍为 1/14，M1 写入路径不受影响

## ADDED Requirements

### Requirement: 类描述符与字段项

`base` SHALL 提供 `ClassDescriptor`（`name`、`fields`、`methods`、`ctors`）与 `PublicField`（`name`、`type`、`index`、`mutable`、`typeRef`），供 `Compiler`、`ClassRegistry` 与 `ReflectRegistrar` 共用。`PublicField.type` SHALL 为 LocalType 0–14（M3 才扩至 0–19），`index` 为 H64/H65 的 index 实参，`mutable` 表示 `var`/`let`，`typeRef` 仅在 14 型字段上携带目标类名。

#### Scenario: 字段项构造保真

- **WHEN** 构造 `PublicField(name: "age", type: 0, index: 3, mutable: true, typeRef: None)` 并读回
- **THEN** 五个字段与入参逐项一致；`mutable=false` 的字段在后续前端校验中被视为只读

#### Scenario: 14 型字段携带 typeRef

- **WHEN** 构造一个 `type=14` 且 `typeRef=Some("Address")` 的字段
- **THEN** 链式成员解析可读取 `typeRef`；非 14 型字段的 `typeRef` 不被消费

### Requirement: 方法与构造器项

`base` SHALL 提供 `PublicMethod`（`name`、`bind`）与 `PublicCtor`（`params`、`adapter`）。`PublicMethod.bind` SHALL 为首参固定为该类的预定义函数，签名 `(C, T...) -> R`。`PublicCtor.params` 为形参类型序列；`adapter` 接收已解包的仓颉值数组并返回该类实例，适配器异常按 21 处理、防御性失败按 99 处理。

#### Scenario: 构造器重载与适配器

- **WHEN** 为一个类登记参数序列不同的两个 `PublicCtor`
- **THEN** 两条条目均保真保留，`adapter` 可被调用并返回该类实例；重载解析由前端 `ctorsOf` 承担

### Requirement: 注册期拒绝异常

`base` SHALL 提供 `public class RegistrationException <: fountain::f_base.BaseException`，构造签名 `init(kind: RegistrationRejectKind, name: String, occupiedBy: ?String)`，并暴露 `kind` / `name` / `occupiedBy` 三个只读字段。`RegistrationRejectKind` SHALL 为六值枚举：`DuplicateClass`、`FunctionNameClash`、`BuiltinTypeName`、`Keyword`、`JsonFamily`、`ReflectionUnavailable`。异常消息 SHALL 为三段式（kind 说明 + `occupiedBy` + 按 kind 固定的 hint），并通过 `super(message)` 转发给 `BaseException`。

#### Scenario: 六类 kind 逐值可断言

- **WHEN** 分别以六个 `RegistrationRejectKind` 构造异常并捕获
- **THEN** 每次 `kind` / `name` / `occupiedBy` 与入参一致；`occupiedBy=None` 分支可用

#### Scenario: 三段消息与固定 hint

- **WHEN** 构造 `FunctionNameClash` 且 `occupiedBy=Some("func:size")`
- **THEN** 消息含类名、冲突对象与按 kind 固定的改名 hint；以 `catch (e: fountain::f_base.BaseException)` 可捕获

### Requirement: 注册期拒绝的宿主侧边界

注册期拒绝 SHALL 只在宿主侧注册调用栈内抛出：不经字节码、JIT 或解释器，**不占 `ErrCode`**、不入 `.fbc`、不进三引擎差分。抛出时 SHALL 不登记——注册表保持原状、快照语义不受影响。

#### Scenario: 不占运行期错误码

- **WHEN** 触发任意注册期拒绝
- **THEN** 不写入任何 `ErrCode`、不涉及错误槽、不产生 `.fbc` 内容；注册表保持原状
