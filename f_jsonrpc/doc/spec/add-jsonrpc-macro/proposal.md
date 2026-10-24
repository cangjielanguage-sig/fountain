# Proposal

## Why

`f_jsonrpc` 目前每加一个方法都要手写一段 `JsonRpcMethodMeta` + 参数转换 + 返回转换，样板代码多且容易把参数名、类型、超时写错。业务侧的类明明已经是 `@Bean`，却还要再写一遍注册逻辑。

把「一个类 = 一个命名空间、一个公共实例方法 = 一个方法」固化成宏，可以让注解成为唯一事实来源，参数/返回值转换由编译器展开时按真实类型生成，不再手写。

## What Changes

- 新增注解 `JsonRpcMeta`：方法级，`[description, timeout]`；`timeout` 是 `Duration` 字符串（走 `f_data` 的 `Duration.parse`），缺省无超时。
- 新增宏 `@jsonrpc[topic: <name>]`（`topic` 可省）：修饰类，展开为
  - 给类加 `@Bean`
  - 为每个 **public 实例方法** 生成一段 `private let _ = {=> ... }()`，在加载期把方法注册到 `JsonRpcRegistry`
  - 方法名 = `topic + "." + fnName`（无 topic 时就是 `fnName`）
  - handler 按方法真实参数类型做 `Data` → `T` 转换，按返回类型做 `T` → `JsonValue` 转换；`Unit` 返回 `null`
- 新增 `JsonRpcRegister.getMeta<T>(fnName, paramCount!)`：运行期反射读取 `@JsonRpcMeta`，返回描述与已解析的 `Duration`。
- 宏在展开期从 `ClassDecl.toTokens()` 提取注解（加载期反射看不到方法注解），生成描述与超时字面量。
- 新增 `JsonRpcArgs.extract/toJson`：参数与返回值的统一转换入口，失败抛 `-32602`。
- 新增宏 `@jsonrpcmeta[...]` 作为 `@JsonRpcMeta[...]` 的语法糖（用户示例里的写法）。
- 依赖补充：`f_jsonrpc` 增加 `f_macros`（宏工具）与 `f_bean`（`lookup` 与 `@Bean`）；两者都已在 `f_mvc` 的依赖链里，不引入新的外部依赖。

## Capabilities

### New Capabilities

无（属于既有 `json-rpc` 能力的注册方式扩展）

### Modified Capabilities

- `json-rpc`: 增加「注解驱动的类级注册」需求——`@jsonrpc` / `JsonRpcMeta` 的展开语义、参数与返回值转换、加载期注册与失败行为

## Impact

- **新增代码**：`f_jsonrpc/src/macros/**`、`JsonRpcMeta.cj`、`JsonRpcRegister.cj`、`JsonRpcArgs.cj`、`exports.cj`
- **依赖**：`f_jsonrpc` 的 `cjpm.toml` 增加 `f_macros` / `f_bean` 路径依赖
- **兼容性**：纯新增，不改既有 `JsonRpcServer` / `JsonRpcClient` 行为；手写注册仍可用
- **约束**：被修饰的类必须是 `class`；只注册 public 实例方法；同名 + 同参数个数的重载在 `getMeta` 视角下无法区分（宏按参数个数匹配，仍歧义时取第一个）
