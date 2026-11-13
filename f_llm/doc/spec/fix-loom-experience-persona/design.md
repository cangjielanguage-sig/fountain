# Design

## Context

- `LoomStoreGateway.cj:129-138`：`list` 用 `strOf(args,'kind')`，未走 `kindOf(args, defaultKind)`；`add`（`:73`）与 `search`（`:150-181`）都走了。
- `LoomRunner.cj:171-175`：`custom` 特例只覆盖 `custom`；`default` 落到 `resolvePersona` → `bodyOf('default')` 返回 `''` → 第 3 级把 `default` 当字面。
- `LoomRunner.cj:378-386`：提示词命中但 `content` 为空时 `return ''`，直接终止三级解析。

## Decisions

### D1. `list` 复用 `kindOf`

一行改动：`let kindFilter = kindOf(args, defaultKind)`。`experience` 分支的 `defaultKind` 已经是 `'experience'`（与 `add`/`search` 同源），不需要新参数。

**替代**：在 experience 分支硬编码 `if(kindFilter.isEmpty()){ 'experience' }`。否决——又多一处「只在这个 op 生效」的特例。

### D2. 人格「无正文」用统一判据，而不是枚举关键字

```cangjie
let key = personaKey.trimAscii()
let lower = key.toAsciiLower()
var persona = if(lower == 'custom' || lower == 'default'){ '' } else { resolvePersona(key) }
```

`resolvePersona` 内部同步收紧：

| 级 | 现状 | 改为 |
|---|---|---|
| 1 提示词库 | 命中即 `return item.value`（可能空） | 命中且非空才返回，空则继续下沉 |
| 2 内置正文 | `bodyOf` 非空才返回 | 不变 |
| 3 字面 | 一律返回 `value` | `isKnown(value)` 为真时返回 `''`（该角色就是无正文），否则返回字面 |

**替代**：把 `default` 加进 `PredefinedCharacters.keys()` 给一段正文。否决——`default` 的语义是「不注入」，给它正文等于改变语义。

### D3. 不做 trim 之外的规范化

`key` 只 `trimAscii()`，不做大小写折叠后再查库（库里的名字是用户数据，大小写可能有意区分）；大小写折叠只用于 `custom`/`default` 两个关键字判定。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 有人把内置角色正文清空、期望仍注入关键字 | 属于误用；本轮用 `isKnown` 明确「无正文即不注入」 |
| `experience.list` 行为变化影响既有调用 | 全仓仅 gateway 测试与 E2E 使用；用例会锁定新语义 |

## Migration Plan

无需迁移。
