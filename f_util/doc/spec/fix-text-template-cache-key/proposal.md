# Proposal

## Why

`TextTemplate.compile` 的静态缓存只用 `template` 字符串作 key，忽略 `prefix` / `suffix` 两个分隔符参数。同一个模板字符串先后用两种分隔符编译时，第二次会命中第一次的缓存实例，按错误的分隔符规则解析，输出与调用方期望不一致。这是正确性缺陷，不是性能问题。

## What Changes

- 缓存 key 从 `template` 改为同时包含 `template`、`prefix`、`suffix`，且编码无歧义（长度前缀，避免分隔符本身造成碰撞）。
- 公开 API 不变：`compile(template, placeholder!)` 与 `compile(template, prefix!, suffix!)` 签名保持原样。
- 新增回归用例：同一模板串先用 `{}` 再用默认 `${}`（以及反向顺序）编译，输出必须各自符合对应分隔符语义。
- 缓存生命周期与线程安全策略不变（仍为 `ConcurrentHashMap` + `computeIfAbsent`）。

## Capabilities

### New Capabilities

- `text-template`: 文本模板的编译、缓存与格式化语义，包括分隔符参数参与缓存键、同一模板串在不同分隔符下互不串味。

### Modified Capabilities

（无）

## Impact

- 代码：`f_util/src/TextTemplate.cj` 的 `templates` 缓存与 `compile` 两个重载；新增测试文件。
- 调用方：`f_log` 用 `prefix: "{", suffix: "}"`，其他模块多用默认 `${`/`}`；修复后各自拿到正确的编译结果，属于行为修正，不需要调用方改代码。
- 公开 API：无变化，无 BREAKING。
- 依赖：不新增依赖；仍是 `std.collection.concurrent.ConcurrentHashMap`。
