## Why

`docs/LocalMode.md` 把 `f_llm` 的 `KnowledgeChunker.split` 列为首批 local mode 试点（§2.5、§3.1）。

现状（`f_llm/src/store/KnowledgeChunker.cj:33-68`）：

- `split` 先把整篇文档展开成全文 `ArrayList<Rune>`（`:45-48`），再按 `maxChars` / `overlap` 滑窗，每个窗口用 `StringBuilder` 拼出 `String`，最后放进返回的 `chunks`。
- `Rune` 是 4 字节 `Copyable` 值，rune 缓冲约为文本 UTF-8 字节的 4 倍（中文约 4/3 倍）。2 MiB ASCII 文档对应约 8 MiB rune 缓冲；8 MiB 文档对应约 32 MiB。该缓冲在 `split` 内创建、函数返回后不再引用，不逃逸。
- `chunks` 是返回值，每个 chunk 的 `String` 与 `StringBuilder` 都要跨函数边界，必须留在普通堆；本次只动全文 rune 缓冲。

local mode 降低的是峰值内存：把 rune 缓冲放进当前线程的 local region，`split` 返回时整块释放，不等 GC。风险是 **256 MB 全线程合计上限**（`docs/LocalMode.md` §1.9），因此必须带门限：单次 rune 缓冲不超过 8 MiB 时走 local，超过走堆，语义不变。

## What Changes

- **local 化全文 rune 缓冲**：`split` 内部的 `ArrayList<Rune>` 在内容 UTF-8 字节数不超过门限时用 `@ local!` 构造与填充；超过门限时用普通堆分配。缓冲不逃逸，`chunks` / `StringBuilder` / chunk `String` 保持堆分配。
- **8 MiB local 预算 / 2 MiB 内容字节门限**：`Rune` 按 4 字节计，最坏情况 ASCII 为 1 rune/字节，因此 `8 MiB ÷ 4 = 2 MiB` 内容字节。`content.size in (0, 2 MiB]` 走 local，`> 2 MiB` 走堆；空内容保持早退。判定只读 `content.size`，不做乘法，不先展开 rune。
- **精确容量**：先用不分配的 `countRunes` 数一遍 rune 数，再以该数量构造 `ArrayList<Rune>`，避免 `ArrayList` 扩容把局部占用推过 8 MiB；顺带用同一个 `total` 驱动滑窗。
- **可测试的档位开关**：新增 `internal static func splitImpl(content, maxChars, overlap, useLocal)`；公开 `split` 完成参数校验与空内容早退后，按门限选择档位并委托。测试可对同一内容跑 local / 堆两条路径做逐元素等价断言。
- **按模块开启 local mode**：只改 `f_llm/cjpm.toml` 的 `[package].compile-option`，追加 `--experimental --enable-local-mode`；`override-compile-option` 与各 `[target.*]` 段保持不动，遵循 `docs/LocalMode.md` §2.2 与 `f_base` / `f_data` / `f_svg` 先例。
- **测试**：新增 `KnowledgeChunkerLocalMode_test.cj`，覆盖门限常量与边界、ASCII / 中文 / emoji / 混合内容的 local / 堆等价、窗口与 overlap 矩阵、公开 `split` 与堆基线一致；既有 `KnowledgeChunkerTest` 全部回归。
- **峰值内存记录**：新增 `f_llm/doc/perf-baseline.md`，按 `docs/LocalMode.md` §4.1 记录门限边界 local / 堆两档的 `getAllocatedLocalObjectSize()`、`getAllocatedHeapSize()` 与 peak RSS（参考值，非 CI 门禁）。

**公开 API 不变**：`KnowledgeChunker.split(content, maxChars!, overlap!)` 的签名、默认值、异常语义与返回的 `ArrayList<String>` 都不变；`splitImpl` 与门限 predicate 都是 `internal`。

## Capabilities

### New Capabilities

- `llm-knowledge-chunking`: 知识文档按字符滑窗切块的契约，以及全文 rune 缓冲在 local mode / 堆之间的分档规则与输出等价性。

### Modified Capabilities

无。本次只改变既有能力的内部实现与内存策略，输出语义不变。

## Impact

- **Affected code**：
  - `f_llm/src/store/KnowledgeChunker.cj`：新增门限常量与 predicate、`splitImpl`、rune 缓冲的 local / 堆分支、`countRunes`；
  - `f_llm/src/store/KnowledgeChunkerLocalMode_test.cj`（新增）：门限与等价性用例；
  - `f_llm/cjpm.toml`：`[package].compile-option` 追加 local mode 开关；
  - `f_llm/doc/perf-baseline.md`（新增）：记录试点前后峰值内存口径与实测；
  - `f_llm/doc/f_llm.md`、`f_llm/README.md`、根 `CHANGELOG`：同步内部实现说明与编译期要求。
- **依赖**：不新增模块、子包或第三方依赖；依赖 `f_base` 已有的 local mode 基线。
- **兼容性**：门限以下走 local、以上走堆，两条路径输出逐元素一致；公开 API 不变，调用方不需要开启 local mode；local 产物不保证跨 SDK 兼容，`f_llm` 需与同一 SDK 重新编译。ohos 目标不支持 `--enable-local-mode`；本分支 `f_base` 已因同一开关无法在 ohos 构建，故 f_llm 的 ohos 构建与 `f_base` / `f_data` / `f_svg` 基线一致，本次不额外处理。
- **验收锚点**：`cd f_llm && cjpm build` 0 自身 warning；`cd f_llm && cjpm test` 无新增错误（2026-11-21 基线：668 条，659 通过、9 条外部 BgeM3 服务连接错误，属环境问题）；`cjpm test --filter KnowledgeChunkerLocalModeTest` 单独通过；门限边界 2 MiB 走 local、2 MiB+1 走堆；local / 堆输出逐元素相等；峰值内存写入 `f_llm/doc/perf-baseline.md`。

## Non-goals

- 不 local 化 `chunks`、`StringBuilder`、chunk `String` 或任何返回 / 跨函数值。
- 不改公开 `split` 的签名、默认值、参数校验与异常类型；不改切块算法（窗口、重叠、字符单位）。
- 不做「按 UTF-8 字节边界直接扫描、不建 rune 数组」的结构性重写；那比 local mode 更省，但属于另一个变更。
- 不在本次落地 `LocalRegionOutOfMemoryError` 的运行时 try/catch 回退；本轮只通过门限 + `useLocal` 档位开关为后续回退预留接口。
- 不优化堆路径的分配次数，不以吞吐量作为验收指标；不改变既有 `start + maxChars` 的极端溢出行为。
- 不解决 ohos 对 local mode 的不支持；与 `f_base` / `f_data` / `f_svg` 基线一致。
