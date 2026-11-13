# Design

## Decisions

### D1. 常量与函数放在同一个 `RetrievalScoring`

```cangjie
public class RetrievalScoring {
    public static let MEMORY_DENSE_WEIGHT = 0.7f64
    public static let MEMORY_SPARSE_WEIGHT = 0.3f64
    public static let RERANK_TITLE_WEIGHT = 0.4f64
    public static let RERANK_CONTENT_WEIGHT = 0.6f64
    public static let LEXICAL_WEIGHT = 0.1f64
    public static let LEXICAL_CAP = 5.0f64

    public static func fuseMemory(dense: Float64, sparse: Float64): Float64
    public static func rerank(title: Float64, content: Float64): Float64
    public static func fuseKnowledge(dense: Float64, lexical: Float64): Float64
}
```

**替代**：只抽常量、保留各处表达式。否决——表达式（尤其是 `min(lexical, cap)`）才是容易写歪的地方。

### D2. 保持包内可见性最小

类本身 `public`（`KnowledgeStore` 在子包 `store.postgres` / `store.mysql`，需要跨包），函数与常量 `public` 但类名带 `Scoring` 表明不是业务 API。
不加 `internal`，因为 Cangjie 的子包跨包访问需要 `public`。

### D3. 不动候选集上限（200/5 页）

那是「取多少候选」的策略，与打分口径是两件事；R6 已单列 PG 5 页候选的问题，避免一批里混两件事。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 重构改变数值 | 三个函数只做原表达式的等价搬运；用 5 条用例钉住关键点（含 cap 截断） |
| 子包导入遗漏 | 编译期即报错，不是运行期风险 |

## 迁移

无（无数据/配置变化）。
