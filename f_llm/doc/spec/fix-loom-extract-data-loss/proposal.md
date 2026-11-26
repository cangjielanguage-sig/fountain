# Proposal

## Why

代码审查（R4）发现流程结束的「记忆 / 经验」提现有两处会**静默丢数据**，且都被三层 `catch` 盖住，现有 7 条用例一条都没抓到：

- `LoomMemoryPolicy.truncate` 用 `text[0..limit]` 做**字节**切片。仓颉的 `String[Range]` 要求落在字符边界，中文 3 字节/字，`limit=400` 有约 2/3 概率切在字中间 → 抛 `IllegalArgumentException` → 整次提炼中断，note 与 experience 一条都不写；
- `summarize=true` 时模型返回非法/残缺 JSON，`parse` 返回 `['', '']` 后又**无条件覆盖**规则提炼结果 → 两条都不写。文档三处承诺「非法 JSON 回落规则提炼」，实际不生效。

同类问题还在 `KnowledgeChunker`：它按字节滑窗，中文长文本同样会切在字符中间抛异常，`knowledge.upsert` 的写入被吞掉。

## What Changes

- 新增 `src/util/TextClip.cj`：按**字符数**裁剪，rune 安全，两处共用。
- `LoomMemoryPolicy.truncate` 改用 `TextClip`，截断语义统一为「前 N 个字符 + `…`」。
- `LoomMemoryPolicy.parse` 的回落改成**按字段独立**：模型只给 memory 就只覆盖 memory，另一字段仍用规则提炼结果。
- `KnowledgeChunker.split` 改为按字符滑窗（窗口与 overlap 都按 rune 计），保持 `DEFAULT_MAX_CHARS=400` / `DEFAULT_OVERLAP=50` 的含义与文档一致。
- 补 6 条用例：TextClip 四种输入、中文长正文提炼、中文长知识切块、三种 summarize 回落。

## Capabilities

### Modified Capabilities
- `loom-flow`：流程结束提炼的截断与回落语义从「隐含」变为「显式且按字符」。

## Impact

- 代码：`src/util/TextClip.cj`（新增）、`src/loom/LoomMemoryPolicy.cj`、`src/store/KnowledgeChunker.cj`。
- 数据：切块粒度由「字节」变「字符」，同一中文文档的块数会变多（400 字符 ≈ 1200 字节），检索结果更完整；无需迁移，重建索引即可。
- 文档：`doc/f_llm-memory-design.md` 的截断值与切块参数说明对齐。
