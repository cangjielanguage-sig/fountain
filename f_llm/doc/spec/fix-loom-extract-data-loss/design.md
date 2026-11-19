# Design

## Context

R4 的两个严重缺陷（`reviews/202611061157_f_llm_module_review/review_v4.md`）与 R4 提到的同类隐患：

- `LoomMemoryPolicy.cj:223-228` `truncate` 用 `text[0..limit]`（字节区间，要求字符边界），中文 3 字节/字 → 约 2/3 概率抛异常；
- `LoomMemoryPolicy.cj:106-114` 与 `:194-210`：`parse` 失败返回 `['','']`，`extract` 无条件覆盖 → 两条都不写；
- `KnowledgeChunker.cj:46-58` 同样按字节滑窗。

可复用写法：`src/tool/WebFetchFunction.cj:83-92` 已有 rune 安全的按字节截断（但它是字节口径）。

## Goals / Non-Goals

**Goals**：让「中文正文」与「模型乱答」都不再丢数据；切块与截断口径统一为**字符**。

**Non-Goals**：改截断上限的具体数值（保持 300/400/600）；重写提炼提示词；给 `catch` 加日志（另开变更，见 R4 一般项）。

## Decisions

### D1. 新增 `util/TextClip.clip(text, maxChars)`

按 rune 累加计数，达到上限即停，其余丢弃；超过上限时补 `…`。**不**做按字节兜底——上限本来就是字符语义（文档写的是「前 N 个字符」）。

**替代**：在 `LoomMemoryPolicy` 内联。否决——`KnowledgeChunker` 也要用，重复两份正是这次要消灭的。

### D2. 截断口径统一为「字符」，与文档对齐

文档 `doc/f_llm-memory-design.md` 写的是「保留前 `limit` 字符」，代码是字节。以文档为准改代码，不动文档数值。

**替代**：改文档为字节。否决——「300 字节」对中文只有 100 字，可读性极差且与 `KnowledgeChunker` 的 `maxChars` 命名冲突。

### D3. `parse` 回落改成按字段独立

```cangjie
let parsed = parse(text)            // 仍是 2 元素，缺失即 ''
let memory = if(parsed[0].trimAscii().isEmpty()){ ruleMemory }else{ parsed[0] }
let experience = if(parsed[1].trimAscii().isEmpty()){ ruleExperience }else{ parsed[1] }
```

这样模型只给一半也有价值，另一半不丢。

**替代**：整体回落（一坏全坏）。否决——模型给 memory 但经验写崩的情况很常见，整体回退会丢掉有效总结。

### D4. `KnowledgeChunker` 改 rune 滑窗，参数含义不变

`maxChars` / `overlap` 一直按字符定义（类注释就写着「按字符数滑窗」），只是实现按字节。改为先 `runes()` 取数组，再按下标切，`start/step` 都是 rune 下标。

**替代**：保留字节 + 只在边界处回退到字符边界。否决——块大小仍会随语言漂移（中文 400 字节 = 133 字），做不到「每块不超过 400 字符」。

### D5. 切块变化不触发迁移，只提示重建索引

同一文档块数会变（中文变多），旧块仍可用但粒度不一致。`doc/known-limitations.md` §5 已写「换 Embedder 需重建」，这里在文档里补一句「升级后建议重建」。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 中文文档块数增加 → 存储与检索成本上升 | 每块仍是 400 字符，总量与文本长度成正比，不放大数量级 |
| 截断改字符后，同一条件下写入的正文比之前短（中文从 ~133 字变 300 字）——实际是变长 | 说明见上：旧实现多数情况直接抛异常，没有可比基线 |
| `TextClip` 每次 `runes()` 生成数组 | 正文最大几百字符，开销可忽略；不做流式优化 |

## Migration Plan

无需迁移。已有知识文档的切块粒度是旧的，如需一致：按 `known-limitations.md` §5 重建索引。

## Open Questions

- emoji（代理对/组合序列）是否按 grapheme 计？本期按 rune，`👨‍👩‍👧` 会算 3 个；不影响正确性，只影响长度口径。
