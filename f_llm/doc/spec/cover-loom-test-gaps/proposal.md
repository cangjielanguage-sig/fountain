# Proposal

## Why

R5 指出五处「用例覆盖缺口」，它们的共同风险是：**行为已经写了，但没有用例钉住，重构时改坏了没人发现**。

- `memoryCall` 只有 `search`/`add` 的弱断言（"不含 failed"），`remove` 分支零覆盖；
- 附件落盘的失败分支只测过「目录不存在」，`InboundAttachment.error` 非空、绝对路径/穿越名的端到端落盘没有断言；
- `writeKnowledge` 的「写知识失败被吞掉」这条 catch 零覆盖；
- `LoomMemoryExtractor.extract` 的「空输入提前返回」零覆盖；
- Supervisor 自动新建的**并发**竞态只有单线程顺序用例。

## What Changes

- 补 4 条用例（第 5 条并发见下）：
  - `memoryCall` 的 add → remove → 再 remove 全链路，断言精确 id；
  - 落盘目标其实是文件 → 失败并给原因；远端绝对路径 `/etc/passwd` → 落在下载目录内的 `passwd`；
  - 空 `turns` → `extract` 返回 0 且不写库；
  - `knowledge` 分支抛错 → `extract` 仍写 note + experience（返回 2）。
- **不补**并发竞态用例：`auto-*` 命名的 check-then-act 已在批次 8 用固定时钟覆盖了「撞名顺延」，真正的并发覆盖需要可控调度器；强行用线程压测会变成 flaky 测试，收益低于噪声。已在 design 里记录理由，并把该风险留在 `todo.md`。

## Capabilities

### Modified Capabilities
- 无（纯测试补齐，不改行为）。

## Impact

- 代码：4 个测试文件，新增 5 条用例；产品代码零改动。
- 门禁：全量从 634 → 639。
