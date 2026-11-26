# Tasks

## 1. 模板替换

- [x] 1.1 锁内拷贝快照、锁外替换；验证：全量回归不退化。
- [x] 1.2 单遍扫描替换（保留未知占位符与 JSON 嵌套）；验证：3 条用例（多步、未命中、JSON 嵌套）。
- [x] 1.3 `{start.output}` 空数据保持原样；验证：1 条用例。

## 2. 执行期快照

- [x] 2.1 `LoomContextLog.MAX_TURNS = 200`，超出保留最近；验证：230 轮 → 快照 200 且最后一条正确。

## 3. 集成

- [x] 3.1 全量回归 `cd f_llm && cjpm test` 全绿：650 → **654**。
- [x] 3.2 `doc/loom.md` 补「渲染是单遍扫描、锁外执行」与「快照上限 200 轮」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/perf-loom-render-context/`。
