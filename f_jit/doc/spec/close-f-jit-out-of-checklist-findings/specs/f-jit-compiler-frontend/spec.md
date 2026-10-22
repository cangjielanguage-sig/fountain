## MODIFIED Requirements

### Requirement: `else if` 链的语法

`if` 的 `else` 分支 SHALL 接受两种后继：`{...}` 块，或另一个 `if`（`else if`）。该规则 SHALL 同时适用于语句用法与值用法（`x = if … else if … else …`）。`else if` 链 SHALL 与等价的嵌套 `if` 逐位同义。

解析器 SHALL 先判后继是否为 `if` 关键字、再决定是否取块；SHALL NOT 保留「先无条件解析块、再回头判 `if`」的顺序——该顺序会让后续判断成为不可达代码。

#### Scenario: 三臂 else if

- **WHEN** 编译并执行 `if (a) {...} else if (b) {...} else {...}`
- **THEN** 三个分支各自可达，结果与嵌套写法相同

#### Scenario: 值用法三臂

- **WHEN** 编译并执行 `let x = if (a) { 1 } else if (b) { 2 } else { 3 }`
- **THEN** `x` 取得对应分支的值，与嵌套写法相同

#### Scenario: else 后接非块表达式

- **WHEN** 写 `else x + 1`（无块、非 if）
- **THEN** 报语法错误，不静默接受
