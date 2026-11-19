## ADDED Requirements

### Requirement: 父类型成员的解析

方法的静态解析 SHALL 覆盖父类型成员：接收者静态类型为子类时，父类声明的公共方法/属性可见；接收者为子接口时，父接口声明的方法可见。同名成员 SHALL 解析到子类型的声明（覆盖）。

父类字段 SHALL 以子描述符内的独立编号出现，读写走与自有字段相同的 helper 路径。

#### Scenario: 子类访问父类成员

- **WHEN** `class Child <: Parent`，两者均注册，编译 `{ c: Child => c.parentMethod() + c.parentField }`
- **THEN** 编译通过并按父类实现求值

#### Scenario: 覆盖优先

- **WHEN** 子类重写了父类同名方法
- **THEN** 解析到子类实现
