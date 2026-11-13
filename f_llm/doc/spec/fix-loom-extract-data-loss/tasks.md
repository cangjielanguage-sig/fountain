# Tasks

> 每个任务按 Red-Green-Refactor：先写用例并确认因「行为不符合预期」失败，再改实现，`cjpm test` 跑绿才勾选。

## 1. TextClip

- [x] 1.1 新增 `src/util/TextClip.cj` 的 `clip(text, maxChars)`：不足原样返回、超过取前 N 字符 + `…`；验证：ASCII 恰好等于、超一个字符、中文超长、空串四条（先失败）。
- [x] 1.2 emoji 与组合字符：按 rune 计数，断言不抛异常且长度符合预期。

## 2. 提炼截断

- [x] 2.1 `LoomMemoryPolicy.truncate` 改用 `TextClip.clip`；验证：中文 800 字正文提炼后 `note` 与 `experience` 都写入，且 system 行长度 ≤ 300 字符 + `…`。
- [x] 2.2 回归：既有 `LoomContextMemory_test` 5 条仍通过。

## 3. summarize 路由回落

- [x] 3.1 `parse` 后的覆盖改为按字段独立回落；验证：模型返回非 JSON 时两条都用规则提炼（断言标题与正文含规则文案）。
- [x] 3.2 模型只给 `memory` 时：memory 用模型结果、experience 用规则结果（断言两条内容不同源）。
- [x] 3.3 模型返回 `{"memory":"","experience":"..."}` 时：memory 回落、experience 用模型。

## 4. 知识切块

- [x] 4.1 `KnowledgeChunker.split` 改 rune 滑窗；验证：1000 汉字切块不抛异常、每块 ≤ 400 字符、相邻块重叠 50 字符。
- [x] 4.2 回归：ASCII 用例与「恰好等于 maxChars 只有一块」不变。

## 5. 文档与集成

- [x] 5.1 `doc/f_llm-memory-design.md` 的截断/切块说明补「按字符」，并加一句「升级后建议重建索引」。
- [x] 5.2 全量回归 `cd f_llm && cjpm test` 全绿（基线 585）。
- [x] 5.3 端到端冒烟：中文流程走完 → `note`/`experience` 落库 → `loomStore("experience","search")` 读回。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 用最终版覆盖 `f_llm/doc/spec/fix-loom-extract-data-loss/`；提交信息写清「截断改字符、按字段回落、切块改字符」。
