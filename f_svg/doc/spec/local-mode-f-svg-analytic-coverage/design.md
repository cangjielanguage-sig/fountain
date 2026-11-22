## Context

`f_svg` 是单包仓颉模块。解析覆盖率是 `antiAlias = Analytic` 时的唯一覆盖率来源：

- 入口 `analyticCoverage(contours, width, height, fillRule)`（`f_svg/src/SvgAnalyticRasterizer.cj:124-180`，`internal`），由 `SvgRasterizer.computeCoverage` 调用（`f_svg/src/SvgRasterizer.cj:285`）；
- 每次调用先建返回值 `coverage: Array<Int64>(width * height)`（`:130`），再建浮点累加器 `accumulated: Array<Float64>(width * height)`（`:166`）；
- 逐行调用 `accumulateAnalyticRow`（`:183-238`），行内建 `active: ArrayList<SvgAnalyticEdge>`（`:192`）与 `events: ArrayList<Float64>`（`:201`），事件去重排序后按子区间调用 `accumulateAnalyticBand`（`:241-290`）→ `accumulateAnalyticEdges`（`:293-319`）写回 `accumulated`；
- `sortAnalyticValues`（`:402-414`）同时服务 `events` 与 `analyticEdgeColumnIntegral` 的逐列分段点 `values`（`:337`）。

约束与依据：

- `docs/LocalMode.md` §3.1 指定 `f_svg` 为最合适的首个试点，并给出最小改造：`accumulated` 用 `@ local!`、私有 helper 形参用 `@ local?`、`coverage` 保持普通数组、加尺寸门限；§4.3 要求同图同尺寸输出逐像素一致；
- `docs/LocalMode.md` §1.9：所有线程活跃 local region 合计默认上限 256 MB，超限抛 `LocalRegionOutOfMemoryError`；
- `docs/LocalMode.md` §2.2 / §4.5：只改各模块 `[package].compile-option`，不修改 `override-compile-option`；`f_base` / `f_data` 已按此先例开启并通过 WSL 全量测试（`f_base/cjpm.toml:3-4`）；
- `SvgBitmap` 已对输出尺寸做上界校验（`SvgBitmap.cj:93-103`、`validatePixels` `:273-283`，默认 `maxPixels = 64M`），因此这里的门限只需处理分配策略，不需要新增尺寸拒绝；
- `SvgAnalyticEdge` 是非 `Copyable` class（`:85-103`），按 §3.1 明确不 local 化。
- 本次基线（2026-11-21，融合引擎 Linux aarch64，SDK `1.3.0-alpha.20261118001016`）：`cd f_svg && cjpm test` 全量 **1230/1230 通过**（含构建约 5m15s）；解析覆盖率用例 12 条，`testdata/render/*.rgba` 34 张。

已核对的契约：

- `analyticCoverage` 是 `internal`，唯一生产调用点是 `SvgRasterizer.cj:285`。因此「公开 API 不变」指模块 `public` 面不变；`internal` 签名可扩展。
- 现有测试直接调用 `analyticCoverage`（`SvgAnalyticRasterizer_test.cj:31`），说明同包测试可访问包内符号，新增测试沿用该模式。
- 既有「解析档」场景（`add-f-svg-m6/specs/svg-rasterization`）只约束可见覆盖率误差，不约束分配方式；本次新增要求不与之冲突。

## Goals / Non-Goals

**Goals:**

- 把 `accumulated` 与每行 `events` 从 GC 堆移到 local region，降低解析覆盖率渲染的峰值堆占用，函数返回即整体释放。
- 用 8 MiB 尺寸门限把单次 local 占用限制在 256 MB 合计上限的 1/32，给并发留余量；2048² 的 32 MiB 档位实测 RSS 回退（见 D1），因此只让 1024² 及以下走 local。
- 保持输出逐元素一致、公开 API 与调用点不变、`f_svg` 自身 0 warning。
- 留下可测试的档位开关，使 local / 堆两条路径都能被单测直接覆盖。

**Non-Goals:**

- 不 local 化 `edges` / `active` / `SvgAnalyticEdge` / `SvgAnalyticHit` / `coverage` / `analyticEdgeColumnIntegral.values`。
- 不做 tile 分块、不改 `SvgBitmap.maxPixels` 或渲染尺寸上限。
- 不在本次实现 `LocalRegionOutOfMemoryError` 的运行时回退（见 D5）。
- 不以吞吐量作为验收；不优化 `analyticEdgeColumnIntegral` 的逐列分配。

## Decisions

### D1 门限以字节计、按像素数比较、除法防溢出

```cangjie
/** 单次解析覆盖率累加器允许进入 local 分配的上限（字节）。 */
internal let ANALYTIC_LOCAL_ACCUMULATOR_BYTES: Int64 = 8 * 1024 * 1024
/** 对应的 `Float64` 元素个数（8 MiB / 8）。 */
internal let ANALYTIC_LOCAL_ACCUMULATOR_ELEMENTS: Int64 =
    ANALYTIC_LOCAL_ACCUMULATOR_BYTES / 8

internal func analyticUsesLocalAccumulator(width: Int64, height: Int64): Bool {
    width > 0 && height > 0 &&
        height <= ANALYTIC_LOCAL_ACCUMULATOR_ELEMENTS &&
        width <= ANALYTIC_LOCAL_ACCUMULATOR_ELEMENTS / height
}
```

- 8 MiB = 8,388,608 字节，对应 1,048,576 个 `Float64`；1024×1024 与 2048×512 恰好落在门限上。
- 2026-11-21 复审：32 MiB 档位在 2048×2048 实测 peak RSS 277 MB，反而比堆对照的 238 MB 高约 40 MB（local region 与 GC 堆峰值叠加）；1024² 档位堆峰值降约 20 MB、RSS 降约 10 MB。因此门限从 32 MiB 下调到 8 MiB：1024² 及以下走 local，2048² 与 4K 走堆。
- `width <= limit / height` 与 `width * height <= limit` 在正整数域等价（整除向下取整不会产生假阳性），且不会像乘法那样溢出；`SvgBitmap.validatePixels` 已经使用同型写法。
- 非正宽高直接判否：`analyticCoverage` 对 0 尺寸返回空数组，对负尺寸维持既有的 `Array` 构造异常，分档不改变这些行为。
- 为什么不按「宽 × 高」写死 1,048,576：门限语义是内存，写成字节常量后若将来 `accumulated` 换成更宽的元素类型，只需改元素宽度换算，不必重新推导。

### D2 单一实现 + `@ local?` 形参 + `useLocal` 档位开关

只保留一份累加逻辑，通过档位开关决定分配位置：

```cangjie
internal func analyticCoverage(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule
): Array<Int64> {
    analyticCoverageImpl(contours, width, height, fillRule,
        analyticUsesLocalAccumulator(width, height))
}

internal func analyticCoverageImpl(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule,
    useLocal: Bool
): Array<Int64>
```

`analyticCoverageImpl` 内：

```cangjie
let accumulated: Array<Float64> @ local? =
    if (useLocal) {
        Array<Float64>(width * height, repeat: 0.0) @ local!
    } else {
        Array<Float64>(width * height, repeat: 0.0)
    }
```

已用探针确认（tasks 0.1，SDK `1.3.0-alpha.20261118001016`）：`if` 表达式两支分别为 `@ local!` 与 `@ ~local` 时可归一到 `@ local?`；`Array<Float64> @ local?` 的元素读写与 `+=` 均可用。**不得先分配堆数组再覆盖为 local 数组**——那样峰值内存目标直接失效。

理由：

- `@ ~local` 是 `@ local?` 的子类型，同一个 `@ local?` 变量既能装堆数组也能装 local 数组；下游 helper 统一声明 `accumulated: Array<Float64> @ local?`，无需两套函数。
- 对 `@ local?` 数组的 `Float64` 元素读写是规则明确允许的（`docs/LocalMode.md` §1.4），末尾 `accumulated[index]` 读出后写进普通 `coverage`。
- `useLocal` 只服务测试与未来回退：生产路径由门限决定，测试直接调用 `analyticCoverageImpl(..., true/false)` 做 A/B 等价断言。
- 备选「两个完整函数（local 版 / 堆版）」会让 180 行累加逻辑分叉，任何算法修复都要改两处，否决。
- 备选「用 `exclave func` 返回 local 数组」不成立：`exclave` 只能把 local 值交给同样处于 local 链路的调用者，而 `analyticCoverage` 的调用方是普通 `@ ~local` 代码。

### D3 `events` 固定走 local，`accumulated` 按档位切换

tasks 0.1 探针结论推翻了原计划的「`events` 与 `accumulated` 同档位」：

```cangjie
// 编译通过：Array<Float64> @ local? 的读写
let accumulated: Array<Float64> @ local? = ...
accumulated[row * width + column] += contribution

// 编译失败：ArrayList<Float64> @ local? 没有变更重载
var x: ArrayList<Float64> @ local? = ArrayList<Float64>()
x.add(1.5)        // error: no matching function declaration for function call 'add'
x[0] = 3.5        // error: cannot assign to this subscript expression
```

SDK 只给 `ArrayList<T>` 提供了 `this @ local!` 的 `add` 与下标赋值；`@ local?` 变量无法调用任何变更方法。因此 `events` 不能声明为 `@ local?` 随档位切换，按 tasks 0.4 的预案固定为 local：

```cangjie
let events = ArrayList<Float64>() @ local!   // 行内创建、行内用完
```

- `events` 在 `accumulateAnalyticRow` 内创建，排序与子区间遍历后即不再引用，行返回时随 local region 释放。
- 排序拆成两个版本，避免把 local 值降级为堆值：
  - `sortAnalyticValues(values: ArrayList<Float64>)`：保留给 `analyticEdgeColumnIntegral.values`（每次至多 4 个元素，堆分配，local 记账成本大于收益）；
  - `private exclave func sortAnalyticLocalValues(values: ArrayList<Float64> @ local!)`：服务 `events`。`@ local!` 形参在普通函数里无法调用 `this @ local!` 的变更方法（external local! 限制），`exclave` 让排序在调用者的 local region 内完成，探针已验证可编译运行。
- 代价：堆档位（`useLocal = false`）仍会为每行 `events` 申请 local 内存。累加器（≤ 8 MiB）仍完全按档位切换，`useLocal = false` 的主要作用是提供逐元素等价基准；D5 的 OOM 回退若将来落地，需要同时把 `events` 换回堆分配，这一点已记入 D5。
- `accumulateAnalyticBand` / `accumulateAnalyticEdges` 的 `accumulated` 形参同步改为 `@ local?`，其余参数与逻辑不动。

### D4 只改 `[package].compile-option`，公开面与调用点不动

`f_svg/cjpm.toml` 只改：

```toml
compile-option = "--dy-std -O2 --experimental --enable-local-mode"
```

- `override-compile-option = "--dy-std -O2"` 与所有 `[target.*]` 段保持原样，和 `f_base` / `f_data` 的已验证形态一致（`f_base/cjpm.toml:3-4`）。
- `SvgRasterizer.computeCoverage` 的调用（`SvgRasterizer.cj:285`）不变；`SvgRenderOptions` / `SvgRenderer` / `SvgBitmap` 无改动，调用方不需要开启 local mode。
- 不新增文件到 `f_svg/src` 的生产代码（除本文件改动），不新增依赖。

### D5 OOM 回退留接口、不在本次落地

- 8 MiB 门限保证单次调用最多占用 8 MiB local；32 个并发解析覆盖率渲染才会顶到默认 256 MB 合计上限。
- 本次不写 `try { ... } catch (e: LocalRegionOutOfMemoryError) { ... }`：错误类型能否在 local region 耗尽后安全捕获、回退重试是否污染当前 local region，都还没有实测结论，贸然加入会引入未验证的异常路径。
- 预留的落点就是 D2 的 `useLocal` 开关：后续若探针确认可捕获，只需在 `analyticCoverage` 的门限分支外包一层 try/catch，catch 内以 `useLocal = false` 重跑 `analyticCoverageImpl`，无需改动累加逻辑。注意 D3 的 `events` 固定 local，真正做 OOM 回退时还需把 `events` 改为堆分配，否则回退路径仍会申请 local。
- 运行期可通过 `cjLocalRegionMaxSize` 调整合计上限；该配置与门限的关系写入 README / perf 记录。

### D6 不 local 化边与命中对象

- `SvgAnalyticEdge` 是非 `Copyable` class：local 容器里读出的元素是 `@ local?`，无法放进普通容器，也无法赋给普通字段；把它改成 `struct ... <: Copyable` 是不在本试点范围内的结构改造。
- `active` 由 `edges` 过滤而来，元素同样是非 `Copyable` 引用；local 化收益有限，且会让 `sortAnalyticHits` 等下游全部模态化。
- `SvgAnalyticHit` 是 class，`hits` 每子区间重建，但元素引用 `SvgAnalyticEdge`，同理不动。
- `coverage` 是返回值，local 值不能作为 `@ ~local` 返回；保持不变。

## Risks / Trade-offs

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 256 MB 全线程合计上限 | 并发大图抛 `LocalRegionOutOfMemoryError` | 8 MiB 门限；`useLocal` 预留回退；文档说明 `cjLocalRegionMaxSize` |
| local 释放时机是函数返回 | 累加器贯穿整个函数，峰值下降有限；`events` 每行释放，收益更直接 | 只 local 化真正「函数内用完」的两个对象，不扩大范围 |
| local 记账成本 | 小画布可能负收益 | 小画布本来就是 8 MiB 以下，收益小但也不放大；验收只看峰值内存，不看吞吐 |
| 实验特性 / 工具链 | cjfmt / cjlint / LSP 不保证识别模态 | 改动集中在单个文件；实现后跑 `cjpm build` + `cjpm test`；必要时手工格式化 |
| 产物不跨 SDK 兼容 | `f_svg` 需同 SDK 重编译 | 与 `f_base` / `f_data` 一致，随 SDK 版本发布 |
| ohos 不支持 local mode | ohos 目标无法编译 | 已实测：鸿蒙侧 SDK `1.3.0-alpha.20261118001016` 的 `aarch64-linux-ohos` 目标对 `--enable-local-mode` 报 `invalid option`；且本分支 `f_base` 已因同一开关在 ohos 构建失败。ohos 明确不在本次试点范围，与 `f_base` / `f_data` 的 local-mode 基线一致 |
| `@ local?` ArrayList 的 `add` | 实测无该重载，原计划不可行 | 已按 0.4 预案改为 `events` 固定 `@ local!` + `exclave` 排序（D3） |
| 尺寸门限判断写错 | 大图误入 local 顶爆上限 | 边界用例覆盖 1024×1023（1,047,552）、1024×1024（1,048,576，等号）、1024×1025（1,049,600，超限）与极端宽高 |

## Testing Strategy

- **TDD**：先写 `SvgAnalyticLocalMode_test.cj`（RED：`analyticUsesLocalAccumulator` / `analyticCoverageImpl` 不存在，编译失败），再实现到 GREEN。
- **门限用例**：512×512、1024×1024、2048×512 为 true；1024×1025、2048×2048、3840×2160 为 false；0 / 负数 / `Int64` 上限 × 2 为 false 且不抛异常；断言 `ANALYTIC_LOCAL_ACCUMULATOR_BYTES == 8 * 1024 * 1024` 与元素数换算。
- **等价性用例**：三角形（nonzero）、甜甜圈（evenodd）、自交五角星（nonzero / evenodd）、多分离轮廓、512×512（门限以下）、1024×1024（满门限），分别用 `analyticCoverageImpl(..., true)` 与 `false` 计算，逐元素断言相等；空轮廓与单点轮廓沿用既有早退路径。
- **大画布冒烟**：1024×1024（local 边界）与 1024×1025（刚超门限，堆）；4K 整幅覆盖数组约 63 MiB，只由门限谓词断言，不在全量单测中实际分配，避免并行套件触发 OOM。
- **回归**：`SvgAnalyticRasterizer_test.cj` 既有 12 条解析覆盖率用例全部保持通过；`f_svg` 既有 34 张渲染快照逐字节一致。
- **内存口径**：按 `docs/LocalMode.md` §4.1，用 `-O2`、固定输入记录 peak RSS 与 `getAllocatedLocalObjectSize()`；只在基准进程里调用后者。结果写入 `f_svg/doc/perf-baseline.md`，作为参考值、不作 CI 门禁。
- **命令**：`cd f_svg && cjpm build`、`cd f_svg && cjpm test`、`cjpm test --filter SvgAnalyticLocalMode_test`。
