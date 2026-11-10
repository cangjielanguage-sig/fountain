# Tasks

## 1. memoryCall

- [x] 1.1 add → remove → 再 remove 全链路，断言精确 id 与幂等 `false`；验证：`testMemoryCallRemoveUsesExactId`。

## 2. 附件落盘失败

- [x] 2.1 目标路径是文件 → `save` 返回空路径 + 错误；验证：`testSaveFailsWhenTargetIsAFile`。
- [x] 2.2 远端绝对路径 `/etc/passwd` → 落在 `<dir>/passwd`；验证：`testAbsoluteRemoteNameIsNeutralized`。

## 3. 提炼边界

- [x] 3.1 空 `turns` → 返回 0 且不写库；验证：`testExtractWithNoTurnsWritesNothing`。
- [x] 3.2 knowledge 抛错 → 仍写 2 条；验证：`testWriteKnowledgeFailureDoesNotBreakExtract`。

## 4. 不补项

- [x] 4.1 Supervisor 自动新建的并发竞态：不补自动化（理由见 design D4），风险留在 `todo.md`。

## 5. 集成

- [x] 5.1 全量回归 `cd f_llm && cjpm test` 全绿：634 → **639**。
