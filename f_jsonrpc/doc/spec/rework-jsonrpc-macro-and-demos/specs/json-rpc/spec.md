# Spec Delta

## Purpose

收敛 `@JsonRpc` 宏与 `@JsonRpcMeta` 的 API，并修复 HTTP 客户端的 keep-alive 复用。

## REMOVED Requirements

### Requirement: `@jsonrpc` 类级注册

由 `@JsonRpc` 取代，旧宏名删除。

### Requirement: `JsonRpcMeta` 描述与超时

由 `JsonRpcMeta` 与 `getMeta` 新规格取代。

## ADDED Requirements

### Requirement: `@JsonRpc` 类级注册

类宏 MUST 只叫 `JsonRpc`，支持 `@JsonRpc` 与 `@JsonRpc[namespace: <name>]`；MUST NOT 再提供 `jsonrpc` / `jsonrpcmeta` 小写别名。展开后 MUST：

1. 给类加上 `@Bean`
2. 为每个 public 实例方法生成加载期注册代码，方法名为 `<namespace>.<fnName>` 或 `<fnName>`
3. 跳过非 public 方法、静态方法与构造函数
4. 生成的 handler 通过 `lookup<T>()` 取实例并调用方法
5. 描述与超时从 `JsonRpcRegistry.getMeta<T>(fnName, argTypes)` 读取

#### Scenario: 带 namespace

- **WHEN** `@JsonRpc[namespace: knowledge]` 修饰含 `public func search(...)` 的类
- **THEN** 注册名为 `knowledge.search`；`/rpc/knowledge` 与 `/rpc` 都可调用

#### Scenario: 旧写法

- **WHEN** 用户写 `@jsonrpc` 或 `@jsonrpcmeta`
- **THEN** 编译期报未知宏，不再存在兼容别名

### Requirement: `JsonRpcMeta` 与 `getMeta`

`JsonRpcMeta` MUST 作为成员方法注解提供 `description`、`timeout`（字符串）与 `timeoutDuration: Duration`。`timeoutDuration` MUST 用 `f_data` 的 `Duration.parse`。`JsonRpcRegistry.getMeta<T>(funcName: String, argTypes: Array<TypeInfo>): JsonRpcMeta` MUST 返回参数类型匹配的重载上的注解实例；没有注解时 MUST 返回 `JsonRpcMeta('', '500ms')`。MUST NOT 再提供 `paramCount` 参数、`parseTimeout` 或 `JsonRpcRegisteredMeta`。

#### Scenario: 正常解析

- **WHEN** 方法标注 `@JsonRpcMeta['知识库检索', '5s']`
- **THEN** `getMeta<T>('search', [TypeInfo.of<String>()])` 返回描述 `知识库检索`，`timeoutDuration == Duration.parse('5s')`

#### Scenario: 无注解

- **WHEN** 方法没有 `@JsonRpcMeta`
- **THEN** `getMeta` 返回描述为空串、`timeout = "500ms"` 的实例

### Requirement: HTTP 客户端 keep-alive

`JsonRpcClient` MUST 在读尽响应 body 后允许 stdx http client 复用连接；只有异常 / body 未读完时才关闭响应。

#### Scenario: 连续两次调用

- **WHEN** 同一个 `JsonRpcClient` 对同一 endpoint 连续调用两次
- **THEN** 第二次调用成功，不出现 `Socket is already closed`
