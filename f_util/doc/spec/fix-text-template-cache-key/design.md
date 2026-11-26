# Design

## Context

`TextTemplate.compile` 目前用一个静态 `ConcurrentHashMap<String, TextTemplate>` 缓存编译结果，key 只有模板字符串本身（`f_util/src/TextTemplate.cj:54,69`）。两个重载都把 `prefix`/`suffix` 传进 `doCompile`，但没参与 key。缓存命中后分隔符参数被丢弃，这是 proposal 描述的正确性缺陷。

约束：

- `compile` 是公开静态方法，签名不能变。
- 缓存被所有模块共享，包括 `f_log`（`prefix: "{", suffix: "}"`）和默认 `${`/`}` 的调用方。
- 缓存是进程级、跨线程的，必须继续线程安全。
- 编译产物 `TextTemplate` 内部是 `ArrayList<Value2String>`，不可变，可安全共享。

## Goals / Non-Goals

**Goals:**

- 缓存键同时包含 `template`、`prefix`、`suffix`，且编码无歧义。
- 不改变两个 `compile` 重载的签名与默认值。
- 保持无锁并发语义（`computeIfAbsent`）。
- 同一模板串在不同分隔符下各自得到正确结果。

**Non-Goals:**

- 不给缓存加容量上限或淘汰策略（既有问题，另开变更）。
- 不改 `format` 系列重载。
- 不改 `doCompile` 的解析逻辑。

## Decisions

### D1：用长度前缀编码复合键

```
"${prefix.size}:${prefix}${suffix.size}:${suffix}${template}"
```

理由：

- 长度前缀让前缀/后缀里出现任意字符（包括 `:`、`${`、空串）都不会与模板串产生歧义。
- 只多一次字符串拼接，相对 `doCompile` 的扫描成本可忽略。
- 不需要新增类型。

备选：

- 嵌套 map `Map<prefix, Map<suffix, Map<template, TextTemplate>>>`：三次查找、三层并发容器，代码与内存都更重。
- 自定义 key 类实现 `Hashable`/`Equatable`：每次查找要构造对象，且要自己保证 hash 一致，收益不明显。
- 直接用 `prefix + suffix + template`：`prefix="a", suffix="bc"` 与 `prefix="ab", suffix="c"` 会碰撞，不可取。

### D2：保持 `computeIfAbsent`，不加 `Mutex`

`computeIfAbsent` 已保证同一 key 只构造一次。原来 `Mutex` 字段用于其它路径，不参与 compile；本次不改变。

### D3：缓存实例仍按「模板 + 分隔符组合」共享

同一组合重复编译复用同一实例，符合现有行为；不同组合各自一条。

## Risks / Trade-offs

- [缓存条目数增加] 从「每个模板串一条」变成「每个（模板, 前缀, 后缀）一条」→ 缓解：实际组合只有默认 `${`/`}`、`f_log` 的 `{`/`}`、`placeholder` 重载的同串前后缀，条目数仍与模板种类同阶。
- [每次 compile 多拼一个字符串] → 缓解：拼接是 O(模板长度)，只在 `compile` 调用点发生，不在 `format` 热路径；相对 `doCompile` 的首轮扫描成本小一个量级。
- [缓存无上限（既有）] → 不在本次范围；Risk 记录在案，若后续出现模板串动态生成再单独处理。
- [行为修正可能暴露依赖旧行为的调用方] → 缓解：修复方向是「各自按自己的分隔符解释」，任何依赖串味结果的代码本身就是错的；全量回归覆盖。

## Migration Plan

无迁移。公开 API 与默认值不变，重新编译即可。

## Open Questions

无。
