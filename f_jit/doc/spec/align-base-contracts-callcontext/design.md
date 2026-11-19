# Design

## Context

`CallContext` 在两天内经历两次收窄：X3 删 `literalCopy` / `strictFp`（调用级 vs 产物级归位），2026-10-22 的 `refactor(f_jit)!` 删 `args` 并把 `deadline` 改成构造期只读。每次代码都改了，但 base-contracts 的这条需求没跟上。

## 决策

### D1 规格只描述「现在有什么」

写「唯一字段是 `deadline`」，并显式列出 `SHALL NOT` 出现的三个字段。后者不是冗余：读者最容易被旧文档误导，把 `SHALL NOT` 写进规格等于给未来改动立一块「别再放回来」的牌子。

### D2 保留 Scenario 名 `默认值契约`

OpenSpec 的 MODIFIED 要求保留既有 Scenario，改名会被判为删除。名字保留，内容改成只断言 `deadline` + 三字段不存在。

## 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 下游仍按旧文档构造 `CallContext(literalCopy: …)` | 编译错误（显式） | 破坏性已在两次代码变更中标注；规格本次补齐 |
