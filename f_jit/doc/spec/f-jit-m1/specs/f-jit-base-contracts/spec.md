# Spec Delta

## Purpose

`base` 包承载全模块共享的契约：类型与错误码常量命名空间、公共值类型、两个异常类型与诊断接口，不持有任何执行状态。

## ADDED Requirements

### Requirement: LocalType 编码与查询

`LocalType` SHALL 以常量命名空间形式给出 0–12 十三个类型码（`I64`/`F64`/`BOOL`/`UNIT`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`LIST`/`MAP`/`CLOSURE`），并提供 `name`、`isHandle`（4–12 为真、0–3 为假）、`fromToken` 查询；合法码集 SHALL 按字节码 `verMajor` 分派。

#### Scenario: 码值与查询一致

- **WHEN** 逐个读取 0–12 的 `LocalType` 常量并调用 `name`/`isHandle`
- **THEN** 值与规格表逐项一致，`isHandle` 在 4–12 为真、0–3 为假

#### Scenario: 版本分派合法集

- **WHEN** 以 verMajor=1 校验类型码 13
- **THEN** 校验拒绝；同一实现为 verMajor=2（0–14）与 verMajor=3（0–19）预留登记位

### Requirement: TypeToken 编码

`TypeToken` SHALL 给出句柄类型 token 0–9（`RESERVED`/`LIST`/`MAP`/`STRING`/`DECIMAL`/`DATETIME`/`DURATION`/`RANGE`/`REGEX`/`CLOSURE`）与 `name`，且与 `LocalType` 的映射集中在同一处。

#### Scenario: token 与类型码对应

- **WHEN** 逐项读取 0–9 的 token 常量并调用 `name`
- **THEN** 与规格类型 token 表逐项一致，`name` 非空

### Requirement: 错误码表与描述

`ErrCode` SHALL 给出 `OK`/`DEOPT`/`INTERRUPT` 与 1–20、`CONCURRENT_MOD`(23)、`HELPER_PANIC`(99) 全量错误码，并提供 `describe` 与 `isHostSide` 查询；未知码 SHALL 返回非空兜底描述。

#### Scenario: 描述可断言

- **WHEN** 对 `-2` 到 `99` 的每个已定义码调用 `describe`
- **THEN** 返回非空文本且含该码语义关键词

#### Scenario: 宿主侧判定

- **WHEN** 对宿主契约类错误码调用 `isHostSide`
- **THEN** 判定结果与规格归类一致

### Requirement: 版本常量

`Version` SHALL 给出 `MAJOR=1`、`MINOR=14`、容器头 `HDR_SIZE=36`、`MAGIC="FBC1"`，且与 `.fbc` 读写两侧共用同一份定义。

#### Scenario: 常量自洽

- **WHEN** 读取 `Version` 四个常量并用它们构造最小容器头
- **THEN** 写出的头可被同一版本的读取侧识别，magic 与长度字段匹配

### Requirement: 公共值类型

`SourcePos`、`JitMode`、`Engine`、`JitValue`、`CallContext`、`SourceUnit` SHALL 以值语义提供，其中 `CallContext` 的 `literalCopy=false`、`strictFp=false`、`deadline=None` 为默认值；`Engine` 与 `JitValue` SHALL 对用户面不可见。

#### Scenario: 默认值契约

- **WHEN** 以默认方式构造 `CallContext`
- **THEN** `literalCopy` 为假、`strictFp` 为假、`deadline` 为 None

#### Scenario: 内部枚举不外泄

- **WHEN** 用户代码 `import fountain::f_jit.*` 后引用 `Engine`/`JitValue`
- **THEN** 编译期不可见（仅模块内 `protected` 可见）

### Requirement: 运行期异常

`JitException` SHALL 携带 `code`、`site`、`fnId`、`sourcePos`、`message`、`cause`，并 SHALL 继承自 `fountain::f_base.BaseException`，使宿主可统一 catch。

#### Scenario: 字段保真

- **WHEN** 构造 `JitException` 并捕获
- **THEN** 六个字段读回值与构造入参一致，`sourcePos`/`cause` 为 None 的分支可用

#### Scenario: 统一基类

- **WHEN** 以 `catch (e: fountain::f_base.BaseException)` 捕获一个 `JitException`
- **THEN** 捕获成功且报告文本经基类可读

### Requirement: 编译期异常

`SourceCompileException` SHALL 携带 `kind`、`position`、`line`、`column`、`lineText`、`hint`，其中 `lineText` SHALL 等于对应源码行原文；它 SHALL 同样继承 `fountain::f_base.BaseException`，且不占用运行期错误码。

#### Scenario: 源码行原文

- **WHEN** 在含多行的源码上触发一个编译期错误
- **THEN** 异常的 `line`/`column` 指向出错位置，`lineText` 与该行源码逐字节相同

#### Scenario: 与运行期错误分离

- **WHEN** 编译期错误发生
- **THEN** 抛出的是 `SourceCompileException`，不写入任何运行期错误码、不涉及错误槽

### Requirement: 诊断接口与空实现

诊断 SHALL 提供 `DiagnosticsSink`（主签名 `(level, code, message)` 与便捷重载 `(level, message)`）、`DiagnosticLevel`（仅 `Info`/`Warn`）、稳定事件码 `DiagCode`（含 `JitFallback`/`MmapFailed`/`RegistrationSkipped`/`PredefinedLimit`/`PlanFallback`/`Unspecified`）与空实现 `DummyDiagnosticsSink`；sink 抛出的异常 SHALL 被引擎吞掉而不改变语义。

#### Scenario: 便捷重载转发

- **WHEN** 调用 `diag(level, message)` 便捷重载
- **THEN** 事件以 `Unspecified` 码转发到主签名，桩实现可记录到 level 与 message

#### Scenario: sink 异常不改语义

- **WHEN** 一个 sink 在记录时抛异常
- **THEN** 引擎吞掉该异常（有在途异常时挂为 suppressed），调用结果、错误码与 site 与不接 sink 时逐位一致
