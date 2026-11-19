# Tasks

## 1. 水位线

- [x] 1.1 推进到「本轮处理过的最大 at」，只前进不后退；无时间戳时回落 now。
- [x] 1.2 用例：`at=10/20/30`、`now=5000` → `lastRunAt()==30`。
- [x] 1.3 既有用例 `testMarksRunWatermark` 保持通过（`at=0` 时仍按 now 推进）。

## 2. 集成

- [x] 2.1 全量回归 `cd f_llm && cjpm test` 全绿：655 → **656**。
- [x] 2.2 `doc/loom.md` 补一句「水位线按已处理素材的最大 at 推进，单轮 limit 是批大小」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-evolution-watermark/`。
