# Spec Delta

## Purpose

为 `f_data.json.JsonSchema` 增加运行时校验能力：既能校验单个 schema 注解实例，也能按 `toJsonSchema<T>()` 生成的 schema 文档校验值，并以结构化错误回报失败位置，供 RPC / MCP 等上层直接放进错误 `data`。

## ADDED Requirements

### Requirement: 实例版校验

`JsonSchema` 实例 MUST 提供 `validate(value, options!)`，按注解自带的约束校验单个值；`type` / `nullable` / `enum` / `minLength` / `maxLength` / `pattern` / `format` / `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` / `multipleOf` / `minItems` / `maxItems` / `items` / `uniqueItems` / `required` MUST 按设计 4.7.3 的关键字矩阵生效。

#### Scenario: 字符串长度

- **WHEN** `JsonStringSchema(minLength: 2)` 校验 `"a"`
- **THEN** `isValid` 为 `false`，`errors` 含 `keyword = "minLength"`、`path = ""`

#### Scenario: 枚举

- **WHEN** `JsonStringSchema(enumeration: '["a","b"]')` 校验 `"c"`
- **THEN** 校验失败，`keyword = "enum"`

#### Scenario: 类型

- **WHEN** `JsonIntSchema()` 校验 `JsonString("1")`
- **THEN** 校验失败，`keyword = "type"`

#### Scenario: 数组元素递归

- **WHEN** `JsonArraySchema(items: JsonStringSchema(minLength: 2))` 校验 `["ok","a"]`
- **THEN** 失败错误路径为 `/1`

#### Scenario: nullable

- **WHEN** 字段声明为 `Option<T>`（schema 带 `nullable: true`）且值为 `null`
- **THEN** 校验通过

### Requirement: 文档版校验

`JsonSchemaValidator` MUST 提供文档版入口 `validate(schema: JsonObject, value: JsonValue, options!)`，按 schema 文档校验值；MUST 支持 `type` / `properties` / `required` / `additionalProperties` / `items` / `enum` 与设计 4.7.3 中标注为「两者」的关键字。

> 语言限制：仓颉不允许静态方法与实例方法同名重载（`overloaded functions 'validate' cannot mix static and non-static`），因此文档版入口落在 `JsonSchemaValidator` 上，实例版保留在 `JsonSchema.validate(value)`。

#### Scenario: 对象成员

- **WHEN** schema 文档声明 `properties.query` 为 `string` 且 `required: ["query"]`，值缺少 `query`
- **THEN** 校验失败，`keyword = "required"`，`path = ""`

#### Scenario: 成员约束

- **WHEN** 值包含 `query: "a"`，schema 中 `query` 的 `minLength` 为 2
- **THEN** 校验失败，`path = "/query"`

#### Scenario: additionalProperties

- **WHEN** schema 声明 `additionalProperties: false`，值含未声明字段
- **THEN** 校验失败，`keyword = "additionalProperties"`

### Requirement: fail-closed

校验器 MUST 在以下三种情况判失败：schema 本身不合法（`keyword = "$schema"`）、遇到未支持关键字（`$ref` / `$defs` / `allOf` / `anyOf` / `oneOf` / `not`，默认拒绝）、值不满足约束。使用 `ValidationOptions.unknownKeyword = UnknownKeyword.Skip` 时 MUST 跳过未支持关键字并记入 `skipped`。

#### Scenario: $ref

- **WHEN** schema 文档里出现 `$ref`
- **THEN** 校验失败，`keyword = "$schema"`，不返回「通过」

#### Scenario: 坏 schema

- **WHEN** `required` 不是 JSON 数组
- **THEN** 校验失败，`keyword = "$schema"`

#### Scenario: 显式降级

- **WHEN** 传 `unknownKeyword: Skip` 且 schema 含 `allOf`
- **THEN** 校验继续，`skipped` 含该关键字路径

### Requirement: 错误上限与深度上限

校验器 MUST 遵守 `ValidationOptions.maxErrors`（默认 32）与 `maxDepth`（默认 64）：达到 `maxErrors` 后 MUST 提前返回，不得继续遍历；深度超过 `maxDepth` MUST 判失败。

#### Scenario: 错误封顶

- **WHEN** 一个 1000 元素数组每个元素都不合法，`maxErrors = 8`
- **THEN** `errors.size <= 8`

#### Scenario: 深度超限

- **WHEN** 嵌套深度超过 `maxDepth`
- **THEN** 校验失败，并给出可定位的 `path`

### Requirement: 结构化错误结果

`ValidationResult` MUST 提供 `isValid`、`errors`、`skipped`，且 `toJson()` MUST 返回可放入 JSON-RPC `error.data` 的 `JsonArray`，每项含 `path` / `keyword` / `message`。

#### Scenario: 序列化

- **WHEN** 校验产生 2 条错误
- **THEN** `toJson()` 是长度 2 的数组，每项为对象且含 `path`、`keyword`、`message`

#### Scenario: 全部通过

- **WHEN** 值满足全部约束
- **THEN** `isValid` 为 `true`，`errors` 为空，`toJson()` 为空数组
