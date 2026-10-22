# Spec Delta

## MODIFIED Requirements

### Requirement: LocalType 编码与查询

`LocalType` SHALL 以常量命名空间形式给出 0–19 二十个类型码（`I64`/`F64`/`BOOL`/`UNIT`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`LIST`/`MAP`/`CLOSURE`/`HOST_CLOSURE`/`HOST_OBJECT`，M3 增 `ANY`(15)/`JSON_VALUE`(16)/`JSON_OBJECT`(17)/`JSON_ARRAY`(18)/`JSON_NULL`(19)），并提供 `name`、`isHandle`（4–19 为真、0–3 为假）与 `fromToken` 查询；合法码集 SHALL 按字节码 `verMajor` 分派：verMajor 1 允许 0–12，verMajor 2 允许 0–14，verMajor 3 允许 0–19，**20–255 恒拒绝**。`HOST_CLOSURE`（13）为宿主闭包句柄型，空安全同 M1 句柄型；`HOST_OBJECT`（14）为不透明宿主对象引用，恒非空。`ANY`（15）为**装箱搬运类型**（句柄型、恒非空，不可再装箱）；`JSON_VALUE`/`JSON_OBJECT`/`JSON_ARRAY`/`JSON_NULL`（16–19）为**内建句柄类型**，零注册、与 14 结构性无关，并携带**码级继承** `17/18/19 <: 16`。

#### Scenario: 码值与查询一致

- **WHEN** 读取 `LocalType.HOST_CLOSURE` / `HOST_OBJECT` / `ANY` 与 16–19 五个 JSON 码并调用 `name` / `isHandle`
- **THEN** 值分别为 13/14/15/16/17/18/19，`name` 非空，13–19 的 `isHandle` 均为真，0–3 仍为假

#### Scenario: 版本分派合法集

- **WHEN** 分别以 verMajor 1、2、3 校验类型码 13、14、15–19、20
- **THEN** verMajor 1 拒绝 13 及以上；verMajor 2 放行 13/14 并拒绝 15 及以上；verMajor 3 放行 15–19 并拒绝 20；20–255 在任何版本均拒绝

#### Scenario: 码级继承

- **WHEN** 以 JSON 码为静态类型做子类判定（`17 <: 16`、`18 <: 16`、`19 <: 16`）
- **THEN** 三者均成立；`17` 与 `18` 之间、`19` 与 `18` 之间互不构成子类关系

### Requirement: TypeToken 编码

`TypeToken` SHALL 给出句柄类型 token 0–12（`RESERVED`/`LIST`/`MAP`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`CLOSURE`/`HOST_CLOSURE`/`HOST_OBJECT`/`ANY`）与 `name`，且与 `LocalType` 的映射集中在同一处。token 11 表示「不透明宿主对象引用」大类，与句柄条目标签同源编码；M3 的 JSON 内建码 SHALL 复用 tag 11，不得为 JSON 另开 token/tag。`ANY`（12）SHALL 只表示装箱句柄，不复用任何既有 token。

#### Scenario: token 与类型码对应

- **WHEN** 逐项读取 0–12 的 token 常量并调用 `name`
- **THEN** 与规格类型 token 表逐项一致，`name` 非空，token 10/11/12 分别对应 13/14/15

#### Scenario: token 11 的大类归属

- **WHEN** 以 token 11 描述一个宿主对象句柄或 JSON 节点句柄
- **THEN** 语义为「不透明宿主对象引用」大类，不因具体注册类名或 JSON 具体码而分叉

#### Scenario: 零格式新增

- **WHEN** 对比 M2 与 M3 的类型 token 编码表与句柄 tag 编码
- **THEN** 仅新增 token 12，token 0–11 与 tag 编码逐位不变

### Requirement: 错误码表与描述

`ErrCode` SHALL 给出 `OK`/`DEOPT`/`INTERRUPT` 与 1–22、`CONCURRENT_MOD`(23)、`HELPER_PANIC`(99) 全量错误码，并提供 `describe` 与 `isHostSide` 查询；未知码 SHALL 返回非空兜底描述。`HOST_EXCEPTION`（21）为仓颉侧异常专用码，覆盖 CALL_HOST 闭包、预定义与包装调用、构造适配器、成员访问器全部宿主侧调用面；`ANY_CAST`（22）为 **Any 盒上的动态转型失败**（`as` 未命中，site = `any_as` 调用点），与 `BAD_CAST`（7，`CAST` 的静态值转型）**分列**；`99` 仍为引擎侧实现缺陷兜底，三者 SHALL 严格区分。

#### Scenario: 描述可断言

- **WHEN** 调用 `describe(21)`、`describe(22)`、`describe(23)` 与 `describe(7)`
- **THEN** 四者均非空；22 的描述含「动态转型」语义，7 的描述含「值转型」语义，21 的描述含宿主异常语义

#### Scenario: 22 与 7 不串号

- **WHEN** 构造 `as` 未命中的盒子与 `CAST` 值转换失败两条路径
- **THEN** 前者错误码恒为 22、后者恒为 7；任一路径均不产生对方码值

#### Scenario: 映射范围

- **WHEN** 遍历桥的错误码映射静态表
- **THEN** 覆盖 1–22 与 23、99、-1、-2，且 22 行独立存在

## ADDED Requirements

### Requirement: 可转集与装箱合法域

`base` SHALL 提供**可转集**的冻结定义：`LocalType` `0–8`、`9–11`、`14`、`16–19` 为合法装箱/转型目标；`3`（Unit）SHALL NOT 有装箱发射点；`12`（Closure）SHALL NOT 开放转型；`13`（HostClosure）SHALL NOT 在 M3 开放；`15`（Any）SHALL NOT 在集合内（禁止二次装箱）。该集合 SHALL 同时作为 `any_box` / `any_is` / `any_as` 的 `typecode` 合法域与前端 `is`/`as` 目标检查的依据，且 SHALL 由单一常量表导出，不得在多处重复枚举。

#### Scenario: 集合边界

- **WHEN** 以 0–8、9–11、14、16–19 逐码查询可转集，再查询 12、13、15
- **THEN** 前者全部为真；12、13、15 为假；3 标记为「无装箱发射点」

#### Scenario: 二次装箱拒绝

- **WHEN** 编译器尝试发射 `any_box(15, …)`，或运行期传入 `typecode=15`
- **THEN** 编译器拒绝发射；运行期以 8（契约类错误）失败，不得静默构造套盒

#### Scenario: 单一来源

- **WHEN** 检查 `base`、编译器与三个 helper 对可转集的使用
- **THEN** 均引用同一张常量表/判定函数，无第二份枚举
