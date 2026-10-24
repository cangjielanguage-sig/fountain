# Design

## Context

`f_jsonrpc` 现有手工注册方式（`JsonRpcRegistry.register(JsonRpcMethodMeta(...))`）需要为每个方法写参数/返回值转换。`@jsonrpc` 把「一个类 = 一个命名空间、一个 public 实例方法 = 一个方法」固化下来。

约束：

- 类必须先被 `@Bean` 接管，handler 通过 `lookup<T>()` 取实例。
- 参数与返回值的真实类型只有编译器知道，转换必须按方法签名生成。
- 注解值（描述、超时）在**加载期反射**里取不到：实测包初始化时 `InstanceFunctionInfo.findAnnotation` 还看不到注解，要到类首次使用后才可见。因此宏在展开期从 `ClassDecl.toTokens()` 的源码 token 流里提取注解。

## Goals / Non-Goals

**Goals:**

- `@jsonrpc[topic: kb]` 修饰类，自动加 `@Bean` 并为全部 public 实例方法生成注册代码。
- `@JsonRpcMeta['描述','5s']` 与 `@jsonrpcmeta['描述','5s']` 两种写法等价。
- 单参数 / 多参数、`Unit` 返回、`DataAssist` 对象都能正确转换。
- 失败路径统一 `-32602`。

**Non-Goals:**

- 方法级鉴权、参数默认值、可变参数（不生成额外语义）。
- 同名 + 同参数个数的重载无法区分（`getMeta` 取第一个；宏生成的注册仍按完整方法签名调用，不受影响）。
- 运行时动态增删注解（注解是编译期事实）。

## Decisions

### D1. 宏包位置与依赖

`f_jsonrpc/src/macros/`（`macro package fountain::f_jsonrpc.macros`）。`cjpm.toml` 增加 `f_macros`（`extractFirstDecl` / `isPublic` / `isStatic` / `topMacroAnonymousClosure`）与 `f_bean`（`@Bean`、`lookup`）。两者原本就在 `f_mvc` 的依赖链里，不新增外部依赖。

`f_jsonrpc` 再导出 `BeanFactory`（`exports.cj`），因为 `@Bean` 展开出的代码引用它，而用户文件通常只 import `fountain::f_jsonrpc.*`。

### D2. 展开结构

```cangjie
@Bean
<原类>
private let _ = {=> <每个方法一段 JsonRpcRegistry.register(...)> }()
```

- 跳过 `init`、静态方法、非 public 方法。
- 每个方法独立一个 `private let _`（`topMacroAnonymousClosure` 生成，含异常兜底），互不影响。
- handler 在注册期取一次 bean 实例并捕获（bean 是单例），避免每请求 lookup。
- 参数转换：`JsonRpcArgs.extract<T>(params, name, named:)`
  - 多参数：`params` 必须是对象，按名字取
  - 单参数：接受裸值、单元素数组、或含该参数名的对象
- 返回值：`JsonRpcArgs.toJson(result)`；`Unit` 走专门重载返回 `null`。

### D3. 注解提取在编译期完成

`metaMap(klass)` 扫描 `ClassDecl.toTokens()`：

- 匹配 `JsonRpcMeta` / `jsonrpcmeta` 后跟 `[ '描述' , '超时' ]`
- 把结果挂到**紧随其后的** `func <name>` 上
- 生成 `description: '描述'` 与 `timeout: JsonRpcRegister.parseTimeout('5s')`

`Duration.parse` 在加载期执行（纯函数），非法超时会在加载期抛异常并带方法名。

`JsonRpcRegister.getMeta<T>` 仍然保留为公开 API（运行期反射），供业务在请求期读取；宏不依赖它，避免加载期元数据未就绪。

### D4. 错误语义

- 参数缺失 / 类型不符：`JsonRpcArgs` 抛 `JsonRpcException(-32602, ...)`，`data` 为参数名。
- 方法体抛异常：由 `JsonRpcServer` 统一映射（`JsonRpcException` 原样，其余 `-32603`）。
- 重复方法名：加载期 `JsonRpcServer.addMethod` 抛异常。

## Risks / Trade-offs

| 风险 | 处置 |
|---|---|
| 注解 token 扫描依赖 `ClassDecl.toTokens()` 的格式 | 只匹配 identifier + 两个字符串，允许换行/空白；格式变化时编译期报错 |
| 单参数接受三种形态，语义略宽 | 文档写明优先级：数组 > 对象成员 > 对象本身 > 裸值 |
| 重载同名同参数个数 | `getMeta` 取第一个；宏注册的 handler 仍按签名区分 |
| 类必须有无参可注入的构造 | 由 `@Bean` 约束，注册期失败会直接抛异常 |
