> 前置：SDK 与 `f_base` / `f_data` / `f_svg` 使用同一 local mode 基线（`docs/LocalMode.md` §1.2）。每步 Red → Green；每完成一组独立提交。
> 规划阶段不写代码，以下任务在 `/opsx:apply` 后执行。

## 0. 探针与前置确认

- [x] 0.1 探针（单个最小样例，逐项编译）：
  - `ArrayList<Rune>(capacity) @ local!` + `add` + 按容量填充能否编译运行；
  - `ArrayList<Rune> @ local?` 的读下标 / `size` / 迭代是否可用（决定 D2 是否需要降级）；
  - `if (useLocal) { ... @ local! ... } else { ... 堆 ... }` 赋值给 `ArrayList<Rune> @ local?` 能否归一；
  - `content.runes().count()` 与 `for (_ in ...)` 是否可用；`Rune` 实际宽度（4 字节）用 `getAllocatedLocalObjectSize()` 校准。
  - 结论写入 `design.md` D1 / D2 / D3；失败则执行 0.4。
- [x] 0.2 基线已记录（2026-11-21）：SDK `1.3.0-alpha.20261118001016`；`cjpm test` 668 条，659 通过、9 条外部 BgeM3 服务连接错误（`SocketException: Connection refused`，环境问题）；既有 `KnowledgeChunkerTest` 8 条（5 切块 + 3 检索）通过。回归门禁：无新增错误。
- [x] 0.3 确认 ohos 排除：与 `f_base` / `f_data` / `f_svg` 一致，不改 `[target.*]`；在 proposal / README 注明。
- [x] 0.4 若 0.1 失败：按 design D2 / D3 的降级方案（`@ local!` 作用域内切块 + 堆分支独立入口；或默认容量 + 1 MiB 门限），先改 design，再继续。（0.1 全部通过，本项未触发）

## 1. 开启 local mode（配置）

- [x] 1.1 `f_llm/cjpm.toml` 的 `[package].compile-option` 改为 `--dy-std --experimental --enable-local-mode`，保留其余字段。
- [x] 1.2 确认 `override-compile-option` 与所有 `[target.*]` 段未改动。
- [x] 1.3 `cd f_llm && cjpm build` 通过，且 `f_llm` 自身 0 warning；若出现既有代码的 local mode 兼容错误，按最小改动修复，需要改公开 API 或大面积业务逻辑时暂停回报。
- [x] 1.4 `git diff` 确认本组只改 `cjpm.toml` 与必要的兼容修复。

## 2. 门限判定（RED → GREEN）

- [x] 2.1 RED：新建 `f_llm/src/store/KnowledgeChunkerLocalMode_test.cj`，写常量与 `knowledgeChunkerUsesLocalBytes` / `knowledgeChunkerUsesLocal` 用例，编译失败。
  - 字节：0 / 1 / 2,097,151 / 2,097,152 / 2,097,153 / `Int64.Max`
  - 字符串：空串 / 短 ASCII / 短中文
  - 常量：8 MiB / 4 / 2,097,152
- [x] 2.2 GREEN：在 `KnowledgeChunker.cj` 增加三个 `internal let` 与两个 predicate；判定只读 `content.size`，不做乘法。
- [x] 2.3 断言常量换算与边界；不构造 2 MiB 字符串。

## 3. `splitImpl` 与 local rune 缓冲（RED → GREEN）

- [x] 3.1 RED：写等价性用例，调用尚不存在的 `splitImpl(content, maxChars, overlap, useLocal)`，编译失败。
- [x] 3.2 GREEN：新增 `internal static func splitImpl(..., useLocal)`；公开 `split` 在参数校验与空内容早退后按门限委托。
- [x] 3.3 新增 `private static func countRunes`；按 `total` 精确容量构造 `ArrayList<Rune>`，local 分支 `@ local!` + `add`，堆分支普通 `ArrayList<Rune>` + `add`，各自进入对应切块 helper（二轮探针后不再汇合到 `@ local?`）。
- [x] 3.4 切块循环按档位拆为 `appendChunksLocal` / `appendChunksHeap`（二轮探针：`-O0` 下 mode 化列表每次读元素占 32 B local，共用一个 `@ local?` 循环会让堆路径耗尽 local）；`chunks` / `StringBuilder` / chunk `String` 不写 mode；空内容早退与参数校验保持原样。
- [x] 3.5 若 0.1 发现 `@ local?` 读下标不可用，按 0.4 降级并同步 design。（探针确认可用，未降级）

## 4. 等价性与回归（GREEN 验收）

- [x] 4.1 ASCII / 中文 / emoji / 混合内容 local / 堆逐元素等价。
- [x] 4.2 `maxChars` 1 / 2 / 4 / 400 与 `overlap` 0 / 1 / 50 的合法组合等价；覆盖单 rune、长度恰好等于 maxChars、overlap=0。
- [x] 4.3 公开 `split` 与 `splitImpl(..., false)` 对门限以下内容一致。
- [x] 4.4 既有 `KnowledgeChunkerTest` 全部通过；`cd f_llm && cjpm test` 无新增错误（9 条外部 BgeM3 服务错误保持基线），无新增 warning（2026-11-21 实测：680 条，671 通过、9 条 BgeM3 连接错误、0 失败）。
- [x] 4.5 `cjpm test --filter '*KnowledgeChunkerLocalModeTest*'` 单独通过（本机 `--filter` 需通配符；11 条用例全过）。

## 5. 峰值内存

- [x] 5.1 `-O2` 基准：门限边界 ASCII（2 MiB local / 2 MiB+1 堆）与中文（699,050 个汉字 local / 699,051 个汉字即 2 MiB+1 堆），另加 8 MiB ASCII 堆路径；记录 `getAllocatedLocalObjectSize()`、`getAllocatedHeapSize()`、peak RSS、耗时（参考值）。确保 f_llm 以 `-O2` 编译（临时在 `compile-option` 加 `-O2` 或用基准工程 `override-compile-option`，不提交临时优化选项）。
- [x] 5.2 新建 `f_llm/doc/perf-baseline.md`，写明方法、输入、`-O2`、采样口径、与 `cjLocalRegionMaxSize` / 8 MiB 预算 / 2 MiB 门限的关系；注明参考值、非 CI 门禁。
- [x] 5.3 若 ASCII 边界 local 峰值明显超过 8 MiB（容量 / 头开销），优先修容量或下调门限；同步 proposal / design / spec / 测试。

## 6. 文档与收尾

- [x] 6.1 `f_llm/doc/f_llm.md` §4.8 补一句：内部 rune 缓冲按内容字节门限分档，公开 API 与 chunk 不变。
- [x] 6.2 根 `CHANGELOG` 增加 `feat(f_llm)` 与 `docs(f_llm)` 条目（2026-11-21）。
- [x] 6.3 `f_llm/README.md` / `README_en.md` 或 `doc/dev-env.md` 注明：f_llm 需要与 local-mode 基线一致的 SDK；local 产物不跨 SDK 兼容；ohos 不支持。
- [x] 6.4 复核 `git diff` 中 `public` 声明为 0 处新增 / 修改；`openspec validate --strict` 通过（本机无 openspec CLI，已按 schema 手工校验 proposal / design / tasks / spec）。
- [x] 6.5 全量 `cd f_llm && cjpm test` 无新增错误；把实际测试数、峰值内存、SDK 版本写进交付说明。
