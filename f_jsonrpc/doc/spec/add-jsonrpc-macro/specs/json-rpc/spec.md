# Spec Delta

## Purpose

为既有 `json-rpc` 能力增加注解驱动的注册方式：一个类对应一个命名空间，公共实例方法对应 JSON-RPC 方法。

## ADDED Requirements

### Requirement: `@jsonrpc` 类级注册

`@jsonrpc[topic: <name>]`（`topic` 可省）MUST 只能修饰 `class`，展开后 MUST：

1. 给类加上 `@Bean`
2. 为每个 public 实例方法生成加载期注册代码，方法名为 `<topic>.<fnName>` 或 `<fnName>`
3. 跳过非 public 方法、静态方法与构造函数

#### Scenario: 带 topic

- **WHEN** `@jsonrpc[topic: kb]` 修饰含 `public func search(...)` 的类
- **THEN** 注册名为 `kb.search`；`/rpc/kb` 可调用，`/rpc` 也可调用

#### Scenario: 无 topic

- **WHEN** 省略 `topic`
- **THEN** 方法名为 `search`

#### Scenario: private 方法

- **WHEN** 类中有 `private func hidden()`
- **THEN** 不注册 `kb.hidden`，调用返回 `-32601`

#### Scenario: 修饰非 class

- **WHEN** 宏用在 struct 或函数上
- **THEN** 编译期报错（`only class decl is allowed`）

### Requirement: `JsonRpcMeta` 描述与超时

`@JsonRpcMeta[description, timeout]` MUST 可标注在方法上；两个参数都是字符串。`timeout` MUST 在注册时用 `f_data` 的 `Duration.parse` 解析；缺少注解时描述为空、无超时；解析失败 MUST 在加载期抛异常（不静默降级）。

#### Scenario: 正常解析

- **WHEN** `@JsonRpcMeta['知识库检索', '5s']`
- **THEN** `methods()` 中该方法 `description = "知识库检索"`、`timeout = Duration.parse("5s")`

#### Scenario: 缺省

- **WHEN** 方法没有 `JsonRpcMeta`
- **THEN** `description` 为空串，`timeout` 为 `None`

#### Scenario: 非法 Duration

- **WHEN** `@JsonRpcMeta['x', 'not-a-duration']`
- **THEN** 模块加载时抛异常，错误信息包含该方法名

### Requirement: 参数与返回值转换

生成的 handler MUST 按方法真实类型转换：

- 单参数：直接使用整个 `params`
- 多参数：`params` 必须是对象，按参数名取
- 参数类型 MUST 是 `f_data.DataFields<T>` 子类型；转换失败或缺失 MUST 返回 `-32602`
- 返回值是 `DataFields<T>` 子类型时 MUST 转成对应 JSON；返回 `Unit` MUST 输出 `null`

#### Scenario: 单参数

- **WHEN** `public func search(param: String): String` 收到 `"hello"`
- **THEN** 返回 `"hello"`（或方法自身的处理结果）

#### Scenario: 多参数

- **WHEN** `public func add(a: Int64, b: Int64): Int64` 收到 `{"a":1,"b":2}`
- **THEN** 返回 `3`

#### Scenario: 缺参数

- **WHEN** 多参数方法收到 `{"a":1}`
- **THEN** 返回 `-32602`，handler 未被调用

#### Scenario: 类型不符

- **WHEN** `String` 参数收到数字
- **THEN** 返回 `-32602`

#### Scenario: Unit 返回

- **WHEN** 方法返回 `Unit`
- **THEN** 响应的 `result` 为 `null`

#### Scenario: 对象类型

- **WHEN** 参数或返回值是 `@DataAssist` 生成的对象类型
- **THEN** 能正常双向转换

### Requirement: 加载期注册与冲突

注册 MUST 发生在模块加载期；方法名冲突 MUST 在加载期抛异常（沿用 `JsonRpcServer.addMethod` 的重复检查），不允许静默覆盖。

#### Scenario: 同名方法

- **WHEN** 两个 `@jsonrpc` 类注册出同一个方法名
- **THEN** 加载期抛 `JsonRpcException`
