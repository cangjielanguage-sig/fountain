# Design

## Context

- `Memory.cj:119-130`：`MemoryStoreAdapter().add(MemoryWrite(userId, 'global', session, summary, 'session'))`，绕过网关、命名空间与 loom 默认值不一致。
- `MemoryKinds.cj:47-54` 只有 7 个常量；`predefined()` 不含经验；`weightOf` 的 `else` 分支恰好给 0.8。
- `experience` 字面量散落在 `LoomMemoryPolicy` / `LoomStoreGateway` / `SkillEvolutionJob`。

## Decisions

### D1. `remember` 增加两个带默认值的参数，而不是改签名位置

```cangjie
public static func remember(session: String, summary: String,
    namespace!: String = 'loom', kind!: String = MemoryKinds.SESSION): Unit
```

默认值改 `loom` 是**修正**：旧值 `global` 写进去后 loom 的默认检索（namespace=loom）读不到。

**替代**：保持 `global` 并在 loom 检索里也查 global。否决——两个命名空间混用会让“按租户隔离”失效。

### D2. 优先网关、回落适配器

```cangjie
try { LoomHostApi.callStore('memory', 'add', payload) }
catch (e: LoomException) { MemoryStoreAdapter().add(...) }
```

理由：网关是唯一写入口径（批次 4 已保证它是单实例）；未装配场景（脚本、单测）仍需可用。

### D3. `experience*` 加进预定义集合，权重显式 0.8

现状 `weightOf` 走 `else → 0.8`、`validate` 走 `false`（自定义 kind 语义）。纳入预定义后行为不变，但语义变正确：它们不再被当成“用户自定义 kind”，`MemoryKinds.all(userId)` 的列表也不会缺它们。

### D4. 只替换三个 loom 文件里的字面量

`KnowledgeKind.cj` 与 `Memory.cj:42` 的 `'experience'` 属于别的语义（知识种类 / 会话角色），不在本轮替换，避免误改。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `remember` 默认命名空间变化影响既有数据 | 旧数据本就读不到（写在 global），不存在回归；新数据写 loom |
| 纳入预定义后，用户自定义同名的 kind 会被拒绝 | 这正是预期：这两个 kind 是系统语义 |

## Migration Plan

无需迁移；如需把历史 `global` 摘要捞回，调用 `remember(..., namespace: 'global')` 或按 `global` 检索一次即可。
