# 任务：`truncateUtf8` 惰性单遍扫描

> TDD：先写等价性 / 分配用例（Red），再改实现（Green），最后跑门控基准并记录数字。
> 每个任务完成后独立提交；分支 `feature/optimize-mcp-truncate-utf8`。

## T1 前置确认（不改代码）

- [x] 1.1 已确认 `StringBuilder` 容量接口为 `init(capacity: Int64)`（std `string_builder.cj:82`），按 `limit` 预分配；无需 `reserve` 退化
- [x] 1.2 确认 `String.size` 为 UTF-8 字节数、`String.runes()` 为惰性迭代器（文档 + 仓内同型用法
      `f_llm/src/util/TextClip.cj:39`）
- [x] 1.3 记录基线：现实现对 1 MiB ASCII / 中文各截断一次时的分配量与耗时（临时探针，不入库）
      实测（`-O0` 测试构建，5 有效样本中位数）：ASCII `alloc=13,692,960 B / ns=56,607,691`，
      中文 `alloc=5,288,032 B / ns=32,110,489`（`limit = 256 KiB`，已写入 `design.md` §10）

## T2 等价性与行为用例（Red）

- [x] 2.1 新增 `f_mcp/src/server/TruncateUtf8_test.cj`（包 `fountain::f_mcp.server`），
      内含 `referenceTruncate`：与改造前 `truncateUtf8` 同构的旧算法，作为 oracle
- [x] 2.2 Red：`equivalenceAcrossCorpus` —— ASCII / `é` / `中` / `😀` 及其交替串 ×
      `limit ∈ {0,1,2,3,4,5,7,11,size-2,size-1,size,size+1}`，与 oracle 逐字节相同
- [x] 2.3 Red：`equivalenceOnLargeText` —— 1 MiB ASCII / 中文 / emoji 在
      `limit ∈ {3,4,5,size/2,size-1}` 下与 oracle 相同，且 `cut.size <= limit`
- [x] 2.4 Red：`fastPathDoesNotCopy` —— `limit == text.size` / `limit > text.size` 时内容相同，
      且分配量 `< text.size / 16`
- [x] 2.5 Red：`stopsAtFirstNonFittingRune` —— 「可填满 limit 的前缀 + 1 MiB 尾巴」的结果只含前缀
- [x] 2.6 Red：`zeroAndNegativeLimit` —— `limit = 0 / -1` 返回 `''`
- [x] 2.7 Red：`keepsRuneBoundaryForMixedScript` —— 混合串在 `limit` 落在各宽度字符中间 → 结果可按 UTF-8 往返
- [x] 2.8 运行：`cd f_mcp && cjpm test --filter TruncateUtf8`，2.4 先红（现实现返回前就物化全量数组）

## T3 实现（Green）

- [x] 3.1 `limit <= 0` → `''`（保持原样）
- [x] 3.2 新增 `limit >= text.size` 快速路径，直接返回 `text`
- [x] 3.3 `text.toRuneArray()` → `text.runes()`，循环体与宽度判定分支链保持逐字不变
- [x] 3.4 `StringBuilder()` → 按 `limit` 预分配（T1.1 确认的接口）
- [x] 3.5 保持 `used + size > limit` 的 `break` 位置与 append 顺序不变（等价性的关键）
- [x] 3.6 运行：`cd f_mcp && cjpm test --filter TruncateUtf8` 全绿

## T4 1 MiB 基准（`F_MCP_BENCH=1`）

- [x] 4.1 基准用例：ASCII 1 MiB 与 中文 ≈1 MiB，`limit = 256 KiB`；`settleGc` +
      `getAllocatedHeapSize()` 与 `getGCFreedSize()` 增量合计算分配量，5 样本中位数
- [x] 4.2 打印 `TRUNCATE_BENCH case=... bytes=... limit=... newAlloc=... refAlloc=... newNs=... refNs=... samples=...`
- [x] 4.3 断言：`newAlloc <= 2 * limit`；ASCII `newAlloc * 2 < refAlloc`；两条路径结果逐字节相同
- [x] 4.4 未设 `F_MCP_BENCH=1` 时打印 `SKIP:` 并返回，默认 `cjpm test` 不受影响
- [x] 4.5 跑一次把输出写入 `design.md` §10「实测记录」

## T5 回归

- [x] 5.1 `f_mcp/src/server/McpServer_test.cj:823-857` 的 4 条既有截断用例**一字不改**、通过
- [x] 5.2 `cd f_mcp && cjpm test` 全绿
- [x] 5.3 `cd f_mcp && cjpm build` 不新增 WARNING
- [x] 5.4 检查 `git diff f_mcp/src/server/McpServer.cj`：改动只在 `truncateUtf8` 函数体内

## T6 产物与提交

- [x] 6.1 确认 `f_mcp/doc/spec/optimize-mcp-truncate-utf8/` 与
      `openspec/changes/optimize-mcp-truncate-utf8/` 逐文件一致（`diff -ru` 无输出）
- [x] 6.2 分支 `feature/optimize-mcp-truncate-utf8`，按「实现 + 用例」与「基准 + 实测记录」分成
      两次提交（均在有单元测试之后）
