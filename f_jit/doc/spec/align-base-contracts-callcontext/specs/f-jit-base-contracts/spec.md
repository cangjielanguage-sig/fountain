## MODIFIED Requirements

### Requirement: 公共值类型

`SourcePos`、`JitMode`、`Engine`、`JitValue`、`CallContext`、`SourceUnit` SHALL 以值语义提供。`CallContext` SHALL 只含**调用级**选项：唯一字段为 `deadline: ?DateTime`（缺省 `None`，构造后只读）；`literalCopy` / `strictFp` / `args` SHALL NOT 出现在其中（前两者已移除，实参由 `call<T>(args)` 形参承载）。`Engine` 与 `JitValue` SHALL 对用户面不可见。

#### Scenario: 默认值契约

- **WHEN** 以默认方式构造 `CallContext`
- **THEN** `deadline` 为 None，且类型上不存在 `literalCopy` / `strictFp` / `args` 字段

#### Scenario: 内部枚举不外泄

- **WHEN** 用户代码 `import fountain::f_jit.*` 后引用 `Engine`/`JitValue`
- **THEN** 编译期不可见（仅模块内 `protected` 可见）
