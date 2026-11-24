# 记录 f_mvc 路径参数提取的两条阻断

## Why

`docs/LocalMode.md` 2.5 把 `PathPattern.extract` 列为 `@ local!` 候选。实测与代码审查确认两条路都走不通，本次只把结论固化到审计表，避免后续重复尝试。

**阻断 1：local 映射**
`PathPattern.extractVariablesInPath` 的中转容器是 `HashMap<Int64, Any>`（值为占位符名 `String` 或 `ComplexPathNode`）。探针验证：

- `HashMap<Int64, Any>() @ local!` 的下标赋值报 `cannot assign to this subscript expression`；
- 把映射作为 `@ local?` 参数传入后，`add` / `remove` / `size` 均报 `no matching function declaration`；
- 具体类型 `HashMap<Int64, Any> @ local?` 同样无法调用 `add`。

与 f_orm 同源：`Any` 值在 local 语境下不被 std 集合的方法签名接受。

**阻断 2：每变量一次全量解析**
`HttpRequestPathPatterns.extract(path, name)`（抽象成员）每个路径变量调用一次 `PathPattern.extractVariableInPath`，后者每次都 `split("/")` 并构建完整的 `HashMap<String, String>`，只取一个键。要改成「每请求解析一次」，必须让抽象接口携带一个已解析容器，但该接口是 `abstract sealed class` 的公开成员，this mode 下不能改。

## What Changes

- **只更新 `docs/LocalMode.md`**：f_mvc 行与模块说明记录两条阻断及其证据。
- **不修改生产代码与测试**：`PathPattern_test` 已有 3 条 `extractVariablesInPath` 用例（共 22 条），覆盖足够。

## Capabilities

无（纯文档，`.openspec.yaml` 设置 `skip_specs: true`）。

## Impact

- 文档：`docs/LocalMode.md` 两处。
- 代码/测试：无变化。
