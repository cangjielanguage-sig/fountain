## Why

`docs/LocalMode.md` 把 `f_svg` 的解析覆盖率列为全仓最合适的首个 local mode 试点（§3.1、§4.3）。

现状（`f_svg/src/SvgAnalyticRasterizer.cj`）：

- `analyticCoverage` 每次调用创建 `Array<Float64>(width * height)` 作为浮点累加器（`:166`）。1000×1000 约 8 MiB，2048×2048 约 32 MiB，4K（3840×2160）约 63 MiB。该数组在函数内创建、函数内用完，不逃逸。
- `accumulateAnalyticRow` 每行再创建 `events: ArrayList<Float64>`（`:201`）。单行容量与活跃边数相关，画布越大、边越多，重复分配的累计开销越高。
- `active` 按 `docs/LocalMode.md` §3.1 的结论保持普通分配：`SvgAnalyticEdge` 是非 `Copyable` class，从 local 容器读出的元素是 `@ local?`，塞回普通容器会违反赋值规则。`coverage` 是返回值，必须普通分配。

local mode 降低的是峰值内存：把累加器与每行事件列表放到线程 local region，函数返回整块释放，不等 GC。全仓 `f_base` / `f_data` 已开启 local mode 并有可用先例（`f_base/cjpm.toml:3-4`），`f_svg` 还没有。

风险是 **256 MB 全线程合计上限**（`docs/LocalMode.md` §1.9、§5）。4K 累加器约 63 MiB，并发多个解析覆盖率渲染就会顶到上限。因此本次试点必须带尺寸门限：单次累加器超过 8 MiB 就退回普通堆分配，语义不变。

## What Changes

- **local 化累加器**：`analyticCoverage` 内部的 `accumulated` 在像素数不超过门限时用 `@ local!` 分配；`@ local?` 视图沿私有 helper 传递，末尾写回普通 `coverage`。
- **local 化每行事件列表**：`accumulateAnalyticRow` 的 `events` 固定用 `@ local!` 分配（SDK 未给 `ArrayList<T> @ local?` 提供变更重载，无法随档位切换）；新增 `exclave` 排序 helper，堆版 `sortAnalyticValues` 继续服务 `analyticEdgeColumnIntegral.values`。
- **8 MiB 尺寸门限**：`width × height × 8 ≤ 8 MiB`（像素数 ≤ 1,048,576）走 local，超过走堆。判定用除法形式，避免 `width × height` 溢出；`width` / `height` 非正时走堆。门限由首轮的 32 MiB 复审下调：2048² 在 32 MiB 档位实测 peak RSS 反而高约 40 MB，1024² 档位则下降约 10 MB（见 `perf-baseline.md`）。
- **可测试的分档开关**：新增包内 `analyticCoverageImpl(..., useLocal)`，`analyticCoverage` 按门限选择档位后调用它；测试可直接对同一几何跑 local / 堆两条路径做逐元素等价断言。`analyticCoverage` 的签名与调用点（`SvgRasterizer.cj:285`）不变。
- **按模块开启 local mode**：只改 `f_svg/cjpm.toml` 的 `[package].compile-option`，追加 `--experimental --enable-local-mode`；`override-compile-option` 与各 `[target.*]` 段保持不动，遵循 `docs/LocalMode.md` §1.2 / §2.2 与 `f_base` 先例。
- **测试**：新增 `SvgAnalyticLocalMode_test.cj`，覆盖门限判定边界、local / 堆等价性（nonzero / evenodd、单轮廓 / 多轮廓 / 自交）、非法尺寸；既有渲染快照逐字节回归。

**公开 API 不变**：`SvgRenderer` / `SvgRenderOptions` / `SvgBitmap` 等模块公开签名与行为不变，调用方无需开启 local mode。

## Capabilities

### New Capabilities

无。本次只改变既有能力的内部实现与内存策略，输出语义不变。

### Modified Capabilities

- `svg-rasterization`：新增解析覆盖率累加缓冲的分档要求（local / 堆、8 MiB 门限、边界与溢出安全），并固定「分档不改变逐像素输出」的等价性要求。

## Impact

- **Affected code**：
  - `f_svg/src/SvgAnalyticRasterizer.cj`：新增门限常量与判定、`analyticCoverageImpl`、local 分配与 `@ local?` 形参；
  - `f_svg/src/SvgAnalyticLocalMode_test.cj`（新增）：门限边界、1024² 与多几何 local/堆等价、0/负尺寸行为用例；
  - `f_svg/cjpm.toml`：`[package].compile-option` 追加 local mode 开关；
  - `f_svg/doc/perf-baseline.md`：记录试点前后峰值内存口径与实测（参考值，非门禁）。
- **依赖**：不新增模块、子包或第三方依赖；依赖 `f_base` 已开启 local mode，`f_xml` 无需改动。
- **兼容性**：门限以下走 local、以上走堆，两条路径输出逐元素一致；未使用解析覆盖率的文档完全不受影响；local 产物不保证跨 SDK 兼容，`f_svg` 需与同一 SDK 重新编译（与 `f_base` / `f_data` 一致）。
- **验收锚点**：`cd f_svg && cjpm build` 0 自身 warning；`cjpm test` 全绿（含既有 12 条解析覆盖率用例与 34 张渲染快照）；门限判定与等价性用例可独立运行；1024² 及以下走 local，2048² 与 4K 走堆。基线：变更前 `cjpm test` 1230/1230（融合引擎 Linux aarch64，SDK `1.3.0-alpha.20261118001016`）。

## Non-goals

- 不 local 化 `edges` / `active` / `SvgAnalyticEdge` / `SvgAnalyticHit` / `coverage`；不把 `SvgAnalyticEdge` 改成 `Copyable` struct。
- 不做 tile 分块、不改变 `SvgBitmap.maxPixels` 与渲染尺寸上限。
- 不在本次落地 `LocalRegionOutOfMemoryError` 的运行时 try/catch 回退；本轮只通过 8 MiB 门限 + `useLocal` 档位开关为后续回退预留接口（见 design D5）。
- 不调整 `f_svg` 的 `override-compile-option`、根 `cjpm.toml`、`.modules`。
- 不以吞吐量作为验收指标；local mode 只按峰值内存衡量。
