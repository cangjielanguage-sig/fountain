> 前置：SDK 与 `f_base` / `f_data` 使用同一 local mode 基线（`docs/LocalMode.md` §1.2）。每步 Red → Green；每完成一组独立提交。
> 规划阶段不写代码，以下任务在 `/opsx:apply` 后执行。

## 0. 探针与前置确认

- [x] 0.1 探针：`var x: ArrayList<Float64> @ local? = ArrayList<Float64>()` + `add` + `size` + 下标读写能否编译运行；`if` 表达式两支分别为 `@ local!` 与 `@ ~local` 时能否归一到 `@ local?`（用于单次分配 `accumulated` / `events`）
  - 结论：`Array<Float64> @ local?` 读写与 `+=` 可用，`if` 归一可用；`ArrayList<Float64> @ local?` 的 `add` / 下标赋值均无重载（只有 `this @ local!` 版本），`events` 无法按档位切换 → 执行 0.4
- [x] 0.2 已确认（2026-11-21）：`[package].compile-option` 会作用于 ohos 目标；鸿蒙侧 SDK 对 `aarch64-linux-ohos` 报 `invalid option: '--enable-local-mode'`，且本分支 `f_base` 已无法在 ohos 构建。ohos 排除在试点外，无需再探
- [x] 0.3 基线已记录：融合引擎 Linux aarch64 / SDK `1.3.0-alpha.20261118001016`，`cjpm test` 1230/1230（含构建约 5m15s）、12 条解析覆盖率用例、34 张快照；apply 时补 peak RSS 与耗时（`-O2`）——已补，见 `f_svg/doc/perf-baseline.md`；复审后将门限由 32 MiB 下调到 8 MiB（2048² RSS 回退）
- [x] 0.4 若 0.1 失败：把 `events` 档位方案改为「始终 `@ local!`」，同步更新 `design.md` D3 后再继续

## 1. 开启 local mode（配置）

- [x] 1.1 `f_svg/cjpm.toml` 的 `[package].compile-option` 追加 `--experimental --enable-local-mode`，保留 `--dy-std -O2`
- [x] 1.2 确认 `override-compile-option` 与所有 `[target.*]` 段未改动
- [x] 1.3 `cd f_svg && cjpm build` 通过，且 `f_svg` 自身 0 warning（依赖模块既有 warning 不计）

## 2. 门限判定（RED → GREEN）

- [x] 2.1 RED：新建 `f_svg/src/SvgAnalyticLocalMode_test.cj`，写 `analyticUsesLocalAccumulator` 用例，编译失败
  - 512×512 / 1024×1024 / 2048×512 / 1×1048576 → true
  - 1024×1025 / 2048×2048 / 4096×1024 / 3840×2160 / 1048576×2 → false
  - 0×n / n×0 / 负数 → false
  - `Int64.Max` × 2 → false 且不抛异常
- [x] 2.2 GREEN：在 `SvgAnalyticRasterizer.cj` 增加 `ANALYTIC_LOCAL_ACCUMULATOR_BYTES` / `ANALYTIC_LOCAL_ACCUMULATOR_ELEMENTS` / `analyticUsesLocalAccumulator`，用除法形式比较
- [x] 2.3 断言常量换算：`ANALYTIC_LOCAL_ACCUMULATOR_BYTES == 8 * 1024 * 1024`，元素数 == 1,048,576

## 3. local 化累加器（RED → GREEN）

- [x] 3.1 RED：写等价性用例，调用尚不存在的 `analyticCoverageImpl(contours, w, h, rule, useLocal)`，编译失败
- [x] 3.2 GREEN：拆出 `internal func analyticCoverageImpl(..., useLocal: Bool)`；`analyticCoverage` 按门限选择档位后委托
- [x] 3.3 `accumulated` 改为 `@ local?` 变量：默认堆分配，`useLocal` 时赋 `Array<Float64>(...) @ local!`
- [x] 3.4 `accumulateAnalyticRow` / `accumulateAnalyticBand` / `accumulateAnalyticEdges` 的 `accumulated` 形参改为 `@ local?`（`events` 固定 local，row 不再需要 `useLocal` 透传，见 0.4）
- [x] 3.5 保持 `coverage` 普通分配、末尾 `accumulated[index]` 读出的 `Float64` 写回 `coverage`；早退分支（空轮廓、无边、无行）不变

## 4. local 化每行事件列表（RED → GREEN）

- [x] 4.1 RED：等价性用例覆盖到含顶点事件与边交点的几何（三角形、甜甜圈、自交五角星），确认 `useLocal` 两档结果一致（此时应仍失败）
- [x] 4.2 GREEN：`events` 固定为 `ArrayList<Float64>() @ local!`（0.4 结论：`@ local?` 无变更重载，无法随档位切换）
- [x] 4.3 新增 `private exclave func sortAnalyticLocalValues(values: ArrayList<Float64> @ local!)` 给 `events` 排序；`sortAnalyticValues` 保留堆版本给 `analyticEdgeColumnIntegral.values`
- [x] 4.4 确认 `active` / `hits` / `edges` 未改动

## 5. 等价性与回归（GREEN 验收）

- [x] 5.1 逐元素等价：三角形（nonzero）、甜甜圈（evenodd）、自交五角星（nonzero / evenodd）、多分离轮廓、空轮廓、单点轮廓
- [x] 5.2 既有 12 条解析覆盖率用例全部通过，64× 参考图误差界限不变
- [x] 5.3 34 张渲染快照逐字节一致；`antiAlias = Analytic` 连续渲染两次输出相同
- [x] 5.4 `cd f_svg && cjpm test` 全绿；`cjpm test --filter SvgAnalyticLocalMode_test` 单独通过
- [x] 5.5 1024×1024（local 边界）与 1024×1025（刚超门限，堆）冒烟，输出正常；1024² 另做 local/堆逐元素等价（`megapixelTiersAgree`）；2048² / 4K 由门限谓词用例覆盖（4K 整幅覆盖数组 63 MiB，不在单测中实际分配，避免全量并行时 OOM）

## 6. 性能与文档

- [x] 6.1 `-O2`、固定输入记录 1024×1024、2048×2048、3840×2160 的 peak RSS、耗时；基准进程内调用 `getAllocatedLocalObjectSize()` 记录 local 占用
- [x] 6.2 把前后对比与口径写入 `f_svg/doc/perf-baseline.md`（参考值、非门禁），并注明 `cjLocalRegionMaxSize` 与 8 MiB 门限的关系
- [x] 6.3 在 `CHANGELOG` 记录 `f_svg` 开启 local mode 与尺寸门限
- [x] 6.4 ohos 已在 0.2 排除：在 README / perf 文档注明 ohos 不支持 local mode（与 `f_base` / `f_data` 基线一致），无需 `@When` 隔离

## 7. 收尾

- [x] 7.1 复核 `design.md` D3 / D5 与最终实现一致（尤其 `events` 档位与是否落地 OOM 回退）
- [x] 7.2 确认公开 API 无变化：`git diff` 中 `public` 声明为 0 处新增/修改
- [x] 7.3 `openspec validate --strict` 在鸿蒙侧通过；融合侧 `cjpm build` 成功、`cjpm test` 1242/1242 通过
- [x] 7.4 verify 复审：门限由 32 MiB 下调到 8 MiB；补 1024² local/堆等价、0 尺寸空覆盖率、负尺寸异常用例；同步 proposal / design / spec / README / perf / CHANGELOG
