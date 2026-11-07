# Design

## Decisions

### D1. 用一个通用工具，而不是给每个 kind 造一个

`loomStoreCall(kind, op, payload)` 与网关一一对应。备选是新增 `knowledgeCall` / `skillCall` / `experienceCall` 三个工具：
否决——每加一类数据就要加一个工具，工具清单会随数据种类线性膨胀，且与 `loomStore` 形成 N 份语义拷贝。

`memoryCall` / `knowledgeIngest` 保留为便捷入口（文档已写、有用例），内部改走同一个 `StoreInvoker`。

### D2. `payload` 只做「像不像对象」的浅校验

深度校验交给网关（它已经 `parse` 并抛可读错误）。工具层只挡「明显不是对象」的输入，避免把 `oops` 送进 JSON 解析器后
由异常文本充当错误信息。

### D3. skills 的优先级：调用方 > 计划 > 请求 > 自动检索

```cangjie
executeNow(..., skills): 非空则用它，否则 plan.skills
runner.run(..., skills): 非空则按标题解析，解析为空再回落 SkillCatalog（批次 9 已实现）
```

**替代**：只加 `FlowPlan.skills`，不加 `executeNow` 参数。否决——宿主偶尔要临时指定，重写计划太重。

### D4. `toJson` 输出 skills

计划落库后要能回放；不输出的话 `confirmFlow` 再执行时技能就丢了。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 模型滥用 `loomStoreCall`（例如 kind=character 改人格） | 网关按 op 白名单执行；后续可按需在工具层加只读限制 |
| `skills` 写错名导致零注入 | 批次 9 的回落逻辑覆盖：解析为空即自动检索 |
| 计划 JSON 里 skills 类型不对（对象而非数组） | `DataObject` populate 失败 → 按既有逻辑抛「planner returned invalid JSON」 |

## 迁移

`FlowPlan` 新增字段有默认值，旧计划 JSON 仍可解析。
