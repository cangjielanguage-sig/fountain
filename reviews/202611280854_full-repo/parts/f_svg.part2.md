# f_svg 模块审查报告

> **模块第 2/26 部分**（分报告）。本部分只覆盖 `f_svg/doc/**` 下 17 个 `.md` 文件（3 个在用设计/基准文档 + M2 变更归档 + 9 份 spec）；
> 同模块其余 425 个文件见 `parts/f_svg.part1..part26.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 17 个 `.md`；全模块 301 个 `.cj` + 141 个 `.md`）
- **基线**：工作区快照（无 diff）；`git status` 仅 `docs/review/`、`reviews/` 未跟踪，源码与文档均无改动，全部按「存量」计
- **审查重点**：SVG 解析/序列化正确性与 XML 边界、注入与转义、OOM、递归与栈溢出、死代码、重复逻辑、存量 BUG（本部分为文档侧，落点为 review-checklist §13/§14：文档承诺与实现是否一致、安全边界与上限是否真被兑现）
- **报告版本**：v1

## 发现

### [一般][存量] `cjpm.toml` 摘录与依赖声明整体过期：版本号、local-mode 编译开关、stdx 依赖三项均与仓库现状相反

- **位置**：`f_svg/doc/f_svg模块设计.md:92-105`（toml 摘录）、`:102`（`version = "1.3.17"`）、`:109`（「不依赖 `stdx`」）、`:1161`（「当前 `1.3.17`」）；对照 `f_svg/cjpm.toml:16`、`:7`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§9 约束 1「local mode 需 `--experimental --enable-local-mode`，`cjpm.toml` 无单独开关」
- **证据**：静态确定 —— ①`cjpm.toml:16` 实际 `version = "1.3.2021"`（与根 `cjpm.toml` 版本一致），文档写 `1.3.17`；②`cjpm.toml:7` 实际 `compile-option = "--dy-std -O2 --experimental --enable-local-mode"`，文档摘录只有 `--dy-std -O2`；③源码 `SvgAnalyticRasterizer.cj:201`、`:241`、`:462` 无条件使用 `@ local!` / `@ local?`，按文档摘录的编译选项无法编译；④`SvgGzip.cj:19`、`SvgImageResource.cj:19` 直接 `import stdx.compress.zlib` / `stdx.encoding.base64`，与「不依赖 `stdx`」相反（`cjpm.toml` 各 target 还依赖 `${CANGJIE_STDX_DYNAMIC_PATH}`）；⑤`perf-baseline.md:163` 声明本模块在 `aarch64-linux-ohos` / `x86_64-linux-ohos` 上「不构建」，而 `cjpm.toml` 为这两个 target 显式写了编译选项段
- **描述**：这一节是使用方复制配置的来源。按它配置会得到「没有 local-mode 开关 → `@ local!` 语法报错」的构建失败；把它当作依赖清单会漏掉 stdx 运行期依赖（缺 `CANGJIE_STDX_DYNAMIC_PATH` 时加载失败）；版本号也与发布流程不符。文档与配置的矛盾不是笔误，而是 M1 之后 local mode、SVGZ/PNG 解码、ohos 目标三批改动都没回写这一节
- **建议**：把 `:92-105` 的 toml 段改为从 `f_svg/cjpm.toml` 直接摘录（含 local-mode 开关与 stdx `path-option`），删掉「不依赖 `stdx`」或在 §1.3 明确列出 `stdx.compress.zlib` / `stdx.encoding.base64` 两项；`version` 与 `:1161` 改为「跟随根 `cjpm.toml`，当前 `1.3.2021`」；ohos 目标要么补上 local-mode 降级方案，要么在 `cjpm.toml` 删除这两个 target 段，使文档与配置同口径

### [一般][存量] 性能基线的输入样本已被重新生成：文档写 246,456 字节，仓库实际 289,347 字节，M1 的 53.8 / 24.8 ms 不可复现也不可比

- **位置**：`f_svg/doc/perf-baseline.md:8`（`246,456 字节`）、`:14-20`（M1 实测表）；`f_svg/doc/f_svg模块设计.md:1091`（「约 246 KB」）
- **来源**：存量 —— `git log -- .assets/README/module-dependencies.svg` 最新提交 `c0abb1a78`（2026-11-24）「按最新 API 引用计数重生成依赖图与矩阵图」
- **判据**：review-checklist §13「文档过期」；铁律「性能结论必须有可复核的测量输入」
- **证据**：静态确定 —— `ls -l .assets/README/module-dependencies.svg` = 289,347 B（差 +17.4%），文档两处仍写 246,456 B / 约 246 KB；基准用例 `SvgRoundTrip_test.cj:65` 的 `largeSampleSmoke` 直接读这个路径，因此每次跑的都是新样本，而表中的 53.8 ms / 24.8 ms 是旧样本上的单次值
- **描述**：该文件的用途是「回归对比」（`perf-baseline.md:1-4` 自述）。输入变了而基线数字没重测，任何「比基线快/慢」的结论都不成立；读者也无法判断 53.8 ms 与设计目标 25 ms 的差距里有多少来自样本变大。同类风险见 `:29-33`（见 #10）
- **建议**：重跑 `largeSampleSmoke`（`-O2`、3 轮取中位数与极差）并把输入字节数、提交号写进表头；或把样本固定在测试数据目录（`f_svg/testdata/`）而不是跟随 `.assets/` 重生成，避免基线随文档图更新漂移

### [一般][存量] M7 文档承诺 `save()` 失败抛 `SvgException(kind: Io)`，但 `SvgErrorKind` 没有 `Io` 分支，实现抛 `InvalidValue`

- **位置**：`f_svg/doc/f_svg-M7设计.md:159`（「使用 `std.fs.File.create` 打开后交给 `SvgWriter`；失败抛 `SvgException(kind: Io)`」）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「错误码与文档不一致」、§11「契约与实现不符」
- **证据**：静态确定 —— `SvgException.cj:21-31` 的枚举只有 `Syntax | InvalidValue | Unsupported | Security | Limit`，全仓搜 `Io` 无该枚举值；`SvgAuthoringBuilder.cj:66-71` 实际是 `File.writeTo(...)` + `catch (_: FSException) { throw invalidValue(...) }`，`save(file)` 同理（`:82-87`）
- **描述**：按文档写 `catch (e: SvgException) { if (e.kind == Io) ... }` 的调用方永远命中不到分支——写入失败会被当成普通参数错误处理，而 `File.create` 这个实现细节也不存在。这属于对外错误契约写错，不是措辞问题
- **建议**：文档改为「失败抛 `SvgException(kind: InvalidValue)`，消息含目标路径」，并删除 `File.create` 描述；若确实需要区分 I/O 失败，就补 `SvgErrorKind.Io`（属于公开枚举变更，需同步 README 与 `:253` 的验收条目）

### [一般][存量] 安全边界与能力表停留在 M1：SVGZ 已实现、gzip 解压上限未记录、`foreignObject` 仍写「不解释 / 可配置 —」

- **位置**：`f_svg/doc/f_svg模块设计.md:1171`（SVGZ「M1 明确不支持」）、`:829-837`（`SvgSecurityOptions` 字段表）、`:1006-1019`（安全边界表，`foreignObject` 行在 `:1019`）；同文件 `:24`、`:27` 已把 SVGZ 与 foreignObject 注入列为 M3 / M6 范围
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档过期：写着『暂不支持』其实已支持」、§14.1「能力未接入文档 / 配置项未进文档」；§5「必须给出拒绝路径」
- **证据**：静态确定 —— ①`SvgGzip.cj:28` 公开 `SvgGzip`，`SvgParser.cj:71-92` 提供 `parseAuto`（按 `1F 8B` 魔数自动解压）与 `parseGzip`，`SvgParser.cj:89` 把上限接到 `options.security.maxDecompressedBytes`；②`SvgOptions.cj:56-57` 的 `maxDecompressedBytes`（默认 64 MiB）是 public 字段，但 `:829-837` 的字段清单与 §7 安全表都没有它——解压炸弹的唯一拒绝路径在文档里不可见；③`SvgBitmap.cj:219`、`SvgForeignObject.cj:23` 提供注入式 `SvgForeignObjectRenderer`，`:1019` 仍写「可配置：—」；④`parseAuto` / `parseGzip` 两个公开入口未进 §5.1 入口清单
- **描述**：§7 是本文档对外的安全承诺表，读者据此评估「上传 SVG 会不会被解压炸弹打爆」。当前实现有 64 MiB 上限且可配，文档却既不写能力也不写上限，还明确说 SVGZ 不支持——安全审查会得出相反结论（以为没有解压路径）。同理 §7 说 `foreignObject` 只是保留原文，实际 M6 已允许注入渲染器
- **建议**：§12.2 删除 SVGZ 行或改为「已支持：`SvgParser.parseAuto` / `parseGzip` + `SvgGzip`」；§5.1 补 `parseAuto` / `parseGzip` 签名与 `maxDecompressedBytes` 字段；§7 增一行「gzip 解压输出 ≤ `maxDecompressedBytes`（默认 64 MiB，超限抛 `Limit`）」；`:1019` 改为「默认透明占位；可注入 `SvgForeignObjectRenderer`」

### [一般][存量] 解析层仍把四类 SMIL 动画元素当未知标签：宽松模式每个动画元素都记 warning，严格模式直接拒绝，与「系统 SHALL 识别动画元素」及 M7 往返验收冲突

- **位置**：`f_svg/doc/f_svg模块设计.md:782`（「未知标签（如 M3 才支持的 `animate`）」）；实现 `SvgTag.cj:23-69`（48 个 `case`，无 `animate` / `animateTransform` / `animateMotion` / `set` / `mpath`）、`SvgBuilder.cj:157-168`（严格模式抛 `Unsupported`、宽松模式 `warnings.add("未知标签 ...")`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」；对照 `doc/spec/add-f-svg-m2/specs/svg-animation/spec.md:7`、`doc/f_svg-M7设计.md:250`
- **证据**：静态确定 —— `SvgTag.create` 的 `case` 表里没有四类动画标签；`SvgTimeline.cj:22` 另有一份 `SVG_ANIMATION_TAGS` 按标签字符串识别，说明动画能力走的是「解析成 `SvgUnknownElement` 后按 tag 名匹配」这条旁路；`SvgBuilder.cj:158-165` 在 `strict` 下对未知 SVG 标签抛 `Unsupported`
- **描述**：三个后果叠在一起：①默认模式解析任何动画 SVG，每个 `<animate>` 都产生一条「未知标签」warning，把真实告警淹掉；②严格模式（`SvgParseOptions(strict: true)`）下，含 SMIL 动画的合法文档直接抛 `Unsupported`；③`f_svg-M7设计.md:250` 的验收「生成的 `rect + animate` … 均能被 `SvgParser` 重新解析」在严格模式下不成立，而 `svg-animation/spec.md:7` 明写「系统 SHALL 识别四类动画元素」。`:782` 的「M3 才支持的 `animate`」举例在 M2 已实现 SMIL 之后就是过期依据
- **建议**：二选一并写进文档——(a) 在 `SvgTag.create` 注册四类动画标签（对应 `SvgAnimate` / `SvgAnimateTransform` / `SvgAnimateMotion` / `SvgSet`，解析侧不要求已存在的类型则仍用通用元素但登记为「已知」以免告警与严格拒绝）；(b) 保持通用元素，但 §4.7 改为「动画元素在解析侧保留为通用元素，不产生未知标签告警；严格模式下同样允许」，并把 M7 验收条目限定为宽松模式

### [轻微][存量] §3.1 单位换算表把 `dpi` 写丢（`pc` 写成常数 16、`in` 写成自相矛盾的 `96 * dpi / 96`），与实现的 `value * dpi / k` 不一致

- **位置**：`f_svg/doc/f_svg模块设计.md:240-252`（`in` 在 `:243`、`pc` 在 `:247`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档写的默认值 / 公式在源码里不一致」
- **证据**：静态确定 —— `SvgLength.cj:208-212` 全部按 `context.dpi` 换算（`In → value*dpi`、`Cm → value*dpi/2.54`、`Pt → value*dpi/72`、`Pc → value*dpi/6`）；文档表里只有 `in` 行带 `dpi`，且写成 `96 * dpi / 96`（恒等于 `dpi`，自身矛盾），其余行写成固定 `96 / 2.54` 等
- **描述**：默认 `dpi = 96` 时两套说法数值相同，所以用例不会失败；但 `SvgLengthContext(dpi: 72)` 之类的自定义场景下，文档给出的换算值全部错误（`pc` 会被算成 16 而不是 12）。这是最容易把使用者带偏的一类"看起来自洽的公式"
- **建议**：表内统一写成 `value * dpi / k`（`in` 为 `value * dpi`，`cm` 为 `/2.54`，`mm` `/25.4`，`pt` `/72`，`pc` `/6`），并在表头注明「默认 `dpi = 96`」

### [轻微][存量] §3.5 引用 `SvgNumber.format`，仓内不存在该类型/方法

- **位置**：`f_svg/doc/f_svg模块设计.md:461`（「数字用 `SvgNumber.format`（见 §3.7）」）；§3.7 在 `:510`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「示例引用了不存在的 API」
- **证据**：静态确定 —— 全仓搜 `SvgNumber.` 零命中，只有内部 `SvgNumberToken`（`SvgNumber.cj:52`）；真正的公开函数是 `formatSvgNumber`（`SvgNumber.cj:32`），§3.7 自己也用的这个名字
- **描述**：同一文档两节对同一 API 用了两个名字，其中一个不存在。按 §3.5 找代码的读者会一无所获，也说明 §3.7 改名时没有回改前文
- **建议**：`:461` 改为 `formatSvgNumber`（或统一改成 `SvgNumber` 类型并在 §3.7 定义），全文档搜一遍旧名

### [轻微][存量] M7 §2 的文件职责表把链式构建器指到 `SvgBuilder.cj`，实际该类在 `SvgAuthoringBuilder.cj`

- **位置**：`f_svg/doc/f_svg-M7设计.md:45`（「`SvgBuilder.cj` | 链式文档构建器」）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档与代码位置不符」
- **证据**：静态确定 —— `SvgBuilder.cj:34` 是解析侧 `internal func buildSvgDocument`（配合 `SvgBuildContext`），`public class SvgBuilder` 在 `SvgAuthoringBuilder.cj:31`；`SvgBuilder.cj:23-681` 全文无 `public class SvgBuilder`
- **描述**：两个文件的角色正好相反（一个把 XML 构造成模型，一个链式生成 XML）。按表找实现会打开错文件，评审/维护时容易把解析侧改动误当成生成侧
- **建议**：表里改为 `SvgAuthoringBuilder.cj`（并可加一行说明 `SvgBuilder.cj` 是解析侧构建器），或把类挪到同名文件

### [轻微][存量] `p0 == p1` 的退化线性渐变在同一变更集里有两套验收口径：spec 允许「第一个或最后一个」，修复计划只允许最后一个

- **位置**：`f_svg/doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md:9`；对照 `doc/spec/add-f-svg-m2/fix-plan.md:16`（C8）、`fix-plan-2.md:58-62`（N8）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2「同一口径在两处维护导致漂移」、§13「存档 spec 自身不自洽」
- **证据**：静态确定 —— spec 原文「`p0 == p1` 时 SHALL 取最后一个 stop 的颜色（或第一个，二者一致的退化处理不得崩溃）」；C8 要求「取**最后一个 stop**；修改现有相反断言」，N8 进一步要求退化分支不再经 `spreadMethod`。括号里的「或第一个」使「取第一个」也能声称符合 spec
- **描述**：验收源允许两种实现，修复计划只允许一种。若后续按 spec 复核，会把 N8 修好的行为判成"未按 spec"，或反过来放过回退。这不是历史免责范围（§13 只免除"与当前实现一致"的要求，不免除自洽性）
- **建议**：删除括号里的「或第一个」，与 C8/N8 统一为「SHALL 取最后一个 stop，且不再应用 `spreadMethod`」

### [轻微][存量] `perf-baseline.md` 的 CSS 匹配口径与 spec 的度量定义不同：实测包含级联与快照构建，无法判定「匹配阶段 ≤ 20 ms」

- **位置**：`f_svg/doc/perf-baseline.md:29-33`；对照 `doc/spec/add-f-svg-m2/specs/svg-css/spec.md:181-183`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移（度量口径）」；§6.1「热点结论需可复核的分段数据」
- **证据**：静态确定（文档自述）—— spec 要求「样式**匹配阶段** ≤ 20 ms（单次、`-O2`、不含解析与渲染）」；baseline 自述口径是「只统计 `SvgStyleResolver.compute(root)`」，并在 `:32` 承认「把级联取值与样式快照构建一并计入，因此是匹配阶段的**上界**」。同一段既说 81 ms「未达成」，又说这是上界
- **描述**：用上界判「未达标」在逻辑上不成立——真实匹配阶段可能已达标。这条指标目前既不能证明达标，也不能证明不达标，只能作为下一轮补数据的线索（已列入待验证假设 #2）
- **建议**：在 `SvgStyleResolver` 的匹配循环处加分段计时（或单独暴露匹配耗时计数），重测后把「匹配阶段」与「compute 全量」两行分开记录；在那之前把 `:31-32` 的「未达成」改为「待隔离度量」

### [轻微][存量] 嵌套 `<svg>` 视口矩阵的乘法顺序在同批文档里相反，实现与 `design.md` 一致

- **位置**：`f_svg/doc/spec/add-f-svg-m2/specs/svg-geometry/spec.md:167`；对照 `doc/spec/add-f-svg-m2/design.md:146`、实现 `SvgViewport.cj:116`、`:131`
- **来源**：存量（快照模式）
- **判据**：review-checklist §2「同一规则两处写法不同」、§13「存档 spec 自洽性」
- **证据**：静态确定 —— spec 写「嵌套 `<svg>` 的视口 SHALL 按 父视口矩阵 × 自身 viewBox 矩阵 × x/y 平移 累乘」；`design.md` D8 与 `SvgViewport.cj:131` 实际是 `parent.multiply(translate(x, y)).multiply(local)`，即「父 × 平移 × viewBox」。两者只在 `viewBox` 缩放为 1 时等价，一般情形下设备坐标不同（spec 的顺序会把 `x/y` 一起缩放）
- **描述**：spec 自带的两个 Scenario 都落在缩放为 1 或未给数值的情形（`:184-187`），所以矛盾不会在归档验收里暴露；后续若照 spec 顺序写第二套实现或写断言，会与主实现产生系统性偏差
- **建议**：`svg-geometry:167` 改为「父视口矩阵 × translate(x, y) × 自身 viewBox 矩阵」，与 `design.md` D8 及 `SvgViewport` 注释统一；或直接引用实现而不复写公式

### [轻微][存量] `maxPixels` 判定公式两份 spec 不一致（缺 `ceil`），非整数 DPR 下结论不同

- **位置**：`f_svg/doc/spec/add-f-svg-m2/specs/svg-security/spec.md:7`；对照 `specs/svg-rasterization/spec.md:53-55`、`fix-plan.md:26`（W6）
- **来源**：存量（快照模式）
- **判据**：review-checklist §5「OOM 上限必须有明确拒绝路径」、§13「同口径两处维护导致漂移」
- **证据**：静态确定 —— security spec 写「检查 `width × height × devicePixelRatio²`」；rasterization spec 与 W6 写「最终像素尺寸为 `ceil(width × dpr) × ceil(height × dpr)`，乘积超 `maxPixels` 抛 `Limit`」。`dpr = 1.1`、`width = height = 100000` 时前式 1.21e10、后式 1.21e10 略大，边界附近（`maxPixels` 取 1.21e10）会给出相反的拒绝结论
- **描述**：这条上限是「分配像素缓冲前」唯一的拒绝闸门，两份验收源各写一个公式，等于同一安全承诺有两个判定口径；整数 DPR（默认 1.0、常见 2.0）下恰好相同，所以归档验收不会失败
- **建议**：security spec 改为「`ceil(width × dpr) × ceil(height × dpr)` 超过 `maxPixels`」，与 rasterization spec、W6 及实现口径一致，并把这行写进 §7 安全表

## 优化可行性方案

> 本部分 17 个文件全为文档，没有可执行的代码优化方案；文档侧的性能观察都属于"补数据"范畴，已放入下节「待验证假设」，不计入优化统计。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 换成 289 KB 样本后，M1 解析/序列化是否仍为 53.8 / 24.8 ms | `f_svg/doc/perf-baseline.md:14-20` | 新样本上的耗时分布 | 跑 `SvgRoundTrip_test.cj:65` `largeSampleSmoke`，`-O2`，3 轮取中位数与极差，记录 `MonoTime` 分段（parse / write） |
| 2 | CSS 匹配阶段是否真的 > 20 ms（当前只有 compute 全量上界） | `f_svg/doc/perf-baseline.md:29-33` | 匹配阶段自耗时 | 在 `SvgStyleResolver` 匹配循环内埋点，1000 规则 × 1000 元素场景，`-O2`，记录匹配 / 级联 / 快照三段 |
| 3 | 1024²「渐变 + 裁剪」7569 ms 是否集中在整幅裁剪蒙版重绘 | `f_svg/doc/perf-baseline.md:47` | 各阶段自耗时占比 | `cjprof record` 跑该基准，看 mask/clip 覆盖率生成 vs 渐变采样 vs 合成占比 |
| 4 | 单次 `getBBox()` 约 51 ms 是否属于主路径热点 | `f_svg/doc/perf-baseline.md:126` | 调用频次与端到端占比 | 1000 元素文档上 profile 一次 `querySelectorAll` + 逐元素 `getBBox`，统计样式树重算次数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_svg.part2.txt` 一一对应（本部分清单共 17 个文件，均为 `.md`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/f_svg-M7设计.md` | .md | ✅ | 与实现对照：`SvgBuilder` 全部方法已存在（`SvgAuthoringBuilder.cj:31-395`）；`begin` 序列化表与 `SvgBegin.cj` 一致；`mpath` 裸 `href` 的说法成立（`SvgWriter.cj:190-202` 的 xlink 折叠清单不含 `mpath`）；问题见 #3、#8 |
| 2 | `f_svg/doc/f_svg模块设计.md` | .md | ✅ | 问题见 #1、#2、#4、#5、#6、#7；其余核对通过：`SvgWriteOptions` 六个默认值与 `SvgWriter.cj:32-38` 一致，安全表「script / on* / 外部引用」与 `SvgBuilder.cj:332-481` 一致，实体上限 64 KB/8 MB/2 GB 与 `f_xml/XmlOptions.cj:102-107` 一致，属性值 1 MiB 与 `f_xml/Lexer.cj:167` 一致 |
| 3 | `f_svg/doc/perf-baseline.md` | .md | ✅ | M5 快照 SHA-256 表 17 张 `.rgba` 逐文件 `sha256sum` 全部一致（0 处偏差）；问题见 #2、#10 |
| 4 | `f_svg/doc/spec/add-f-svg-m2/design.md` | .md | ✅ | 与实现口径自洽：D10 覆盖率分母 `ss²` 与 `svg-rasterization/spec.md:66` 一致；D15 zlib/CRC 与 `svg-png/spec.md:32-36`、`SvgGzip.cj:19` 一致；无独立问题 |
| 5 | `f_svg/doc/spec/add-f-svg-m2/fix-plan-2.md` | .md | ✅ | N8 与 spec 冲突（#9）；N1–N9 描述与现实现一致（`SvgTimeline.cj:22` 按标签识别、`SvgAnimationSpec` 路径兜底） |
| 6 | `f_svg/doc/spec/add-f-svg-m2/fix-plan-3.md` | .md | ✅ | W1/W2 与 `svg-text/spec.md:58-69`、`svg-geometry/spec.md:129-131` 口径一致，无独立问题 |
| 7 | `f_svg/doc/spec/add-f-svg-m2/fix-plan.md` | .md | ✅ | C8 与 spec 冲突（#9）；C2 的「循环 64 终止 / 非循环 >64 抛 Limit」与 `svg-security/spec.md:44-48` 一致 |
| 8 | `f_svg/doc/spec/add-f-svg-m2/proposal.md` | .md | ✅ | 交付清单与源码现状一致（CSS/几何/渲染/文本/PNG/动画文件均在 `src/`）；「M1 216 条」与 `design.md:17` 同口径；无独立问题 |
| 9 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-animation/spec.md` | .md | ✅ | 与 #5 相关（「识别四类动画」vs `SvgTag` 未注册）；其余 Requirement（时间模型、keyTimes 回退、values ≤ 10000、mpath 深度 64）与 `SvgTimeline.cj` 一致 |
| 10 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-css/spec.md` | .md | ✅ | 度量口径问题见 #10；级联五级来源 / 特异性 / `currentColor` 与实际 `SvgComputedStyle.cj`、`SvgStyleResolver` 一致 |
| 11 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-geometry/spec.md` | .md | ✅ | 退化盒 / `inflate` 负值 / 弧端点极值等口径与 fix-plan C6 一致；性能 1 ms 已在 baseline 记录为达标；嵌套视口矩阵顺序见 #11 |
| 12 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md` | .md | ✅ | 退化渐变口径见 #9；`mask` luminance 权重、`clipPathUnits` 默认值与 `design.md:203-205` 一致 |
| 13 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-png/spec.md` | .md | ✅ | IHDR/CRC/Adler-32/确定性四条与 `SvgPngEncoder.cj`、`fix-plan.md` W13 一致；95 ms 已记录达标；无独立问题 |
| 14 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-rasterization/spec.md` | .md | ✅ | 覆盖率分母、SSAA 档位、`maxPixels`、预乘合成与 `design.md` D10/D13 一致；与 `perf-baseline.md:46` 的 2×2 档位差异已被 baseline 明确标注；无独立问题 |
| 15 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-render-pipeline/spec.md` | .md | ✅ | `use` / 嵌套 svg / image 占位 / 确定性四条与 `SvgRenderTree.cj`、`SvgForeignObject.cj` 一致；无独立问题 |
| 16 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-security/spec.md` | .md | ✅ | 渲染上限 `64 × 1024 × 1024`、递归 64、values 10000 与 `SvgOptions.cj`、`design.md:270-271` 一致；`maxPixels` 判定公式见 #12 |
| 17 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-text/spec.md` | .md | ✅ | 空格字形返回空路径、x/y 短列表复用末值、缺字 `bounds=None` 与 fix-plan C7/C9、N6/N7、fix-plan-3 W1/W2 一致；无独立问题 |

合计：`.cj` 0 个 / `.md` 17 个 / 共 17 个，全部读完（同模块其余 425 个文件由其他 25 个部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 安全性：#4（解压上限未进安全表）、#5（严格模式拒绝动画文档）；正确性/契约：#3（错误码不存在）、#1（配置照抄即构建失败）；可读性/可维护性：#6/#7（公式与 API 名过期）。语言特性维度本部分无代码，只在 #1 核对了 local-mode 语法对编译开关的依赖 |
| §1 死代码 | 0 | 本部分无 `.cj`。文档对符号的引用有效性已逐个核对：`SvgBuilder` / `SvgBegin` / `SvgAnimate*` / `SvgSet` / `SvgNumberList` / `SvgGzip` 等均存在；唯一「指向不存在的符号」是 `SvgNumber.format`，按 §13 记入 #7，不在死代码重复计数 |
| §2 重复逻辑 | 2 | 同一验收口径在多份文档重复维护并已漂移：#9（`p0 == p1` 在 spec 与两份修复计划里三种说法）。另核对了 `模块设计` §3 与 `specs/**` 的阈值表（25/20/50/200/100 ms），这些是各自文档的独立定义，不属重复实现；#11：嵌套视口矩阵顺序在 spec 与 design / 实现里相反 |
| §3 空实现 | 0 | 本部分无代码；文档承诺的每条 Requirement 都有对应实现或实现计划，未发现「承诺但只写占位」的段落（`fix-plan` 三项均为已闭环的修复记录，`design.md` 的「假设与待确认」显式标注为待定） |
| §4 栈溢出 | 0 | 文档侧的深度承诺已与实现核对：`SvgSecurityOptions.maxDepth` 默认 512（`SvgOptions.cj:66`）与 §7 表一致，且 `SvgBuilder.cj:630-677` 用迭代队列做元素计数/深度检查；渲染侧 64 层上限（`svg-security/spec.md:44-46`）与 `design.md:270-271` 同口径 |
| §5 OOM | 2 | #4：文档安全表缺少 gzip 解压上限（`maxDecompressedBytes` 默认 64 MiB），而 `SvgParser.parseAuto` 会自动解压 SVGZ——读者无法从文档得知解压炸弹的拒绝路径；#12：`maxPixels` 判定公式在 security / rasterization 两份 spec 里缺 `ceil`，非整数 DPR 下拒绝结论不同 |
| §6.1 热点瓶颈 | 0 | 本部分只有单次实测值（无 profile、无输入规模对照的中位数/离散度），不构成热点结论；4 条线索全部进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关代码或文档承诺 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` 描述；`design.md` 的「文档不可变即可缓存样式树」属调用方约定，不涉及串行段 |
| §6.4 低效算法 | 0 | 文档提到的复杂度只有 CSS 匹配 O(规则×元素)（`design.md:281`）与 `maxPixels` 上限，均无「已知规模下的实测耗时」，无法判定为低效实现 |
| §7 降堆内存方案 | 0 | 无基线（峰值内存「未度量」，`perf-baseline.md:19`），按规则只能写待验证假设；本部分无代码可改 |
| §8 降 CPU 方案 | 0 | 同上：`perf-baseline.md` 的 53.8/24.8/81/51 ms 都是单次值，未给改前改后对照，不作为优化方案 |
| §9 local mode 可行性 | 1 | #1：文档摘录的编译选项缺 `--experimental --enable-local-mode`，而源码无条件使用 `@ local!`；可行性结论本身（1024² 走 local、2048²/4K 走堆、门限 8 MiB）在 `perf-baseline.md:151-162` 有实测峰值，属已有基线，不另列方案 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`，不做代码缺陷判定；文档与实现不符统一记在 §13 维度（#1–#10），避免同一问题双重统计。核对过的实现侧边界：`countXmlElements`/`checkDepth` 为迭代实现（`SvgBuilder.cj:630-677`），`maxDepth` 默认值与 f_xml 的 `maxElementDepth=4096`（`f_xml/XmlOptions.cj:146`）不冲突 |
| §12 并发安全与锁粒度 | 0 | 本部分无并发代码；`design.md` D1/D16 的「渲染不修改文档 / 采样返回深拷贝」是模型层契约，线程安全责任在调用方，文档已写明 |
| §14 功能完备性与 README 覆盖 | 2 | #4（`maxDecompressedBytes`、`parseAuto`/`parseGzip`、foreignObject 注入渲染器未进设计文档）、#5（动画元素未进解析映射表，`§4.7` 示例过期）。README 中英同步属第 1 部分范围，本部分未展开 |
| 文件覆盖（§13 等） | 17/17 | 清单 17 个文件全部读完，覆盖表逐行对应；`.md` 与实现的对照均给了两边行号 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 17 份文档的整体质量高于同类模块：可验证的部分几乎都经得起核对——17 张渲染快照的 SHA-256 与表内记录逐字节一致，实体上限（64 KB / 8 MB / 2 GB）、属性值 1 MiB、元素数 100 万、深度 512 这些数字在代码里都能找到对应常量，转义确实完全交给 `f_xml::XmlWriter`（`SvgWriter.cj:73-89` 只组装 `XmlDocument`），安全表里 script / `on*` / 外部引用三条与 `SvgBuilder.cj:332-481` 的移除逻辑一一对应，M7 文档的 API 清单也与 `SvgAuthoringBuilder.cj` 逐项对得上。这些都是"文档承诺 = 实现"的部分，没有发现虚构能力。

风险集中在**三处过期**，都是文档没跟上代码演进，而不是设计缺陷：

1. 构建配置与依赖（#1）——照抄 §1.3 的 toml 会因缺 local-mode 开关编译失败，且漏掉 stdx 依赖；这是最容易被使用者踩到的一条，建议优先修。
2. 安全与能力表（#4、#5）——SVGZ 已实现且带 64 MiB 解压上限，文档却写"不支持"、安全表里也没有这个上限；同时解析层把四类动画标签当未知标签，严格模式下会拒绝含 SMIL 的合法文档，与 spec 的"SHALL 识别"和 M7 的往返验收都对不上。前者影响安全评估结论，后者影响严格模式的可用性，都值得排期。
3. 基线与度量口径（#2、#10）——基准样本被重生成（246 KB → 289 KB）后数字没重测，CSS 匹配指标又拿"compute 全量上界"去判"匹配阶段未达标"，两条都会让后续的回归对比失去意义。

M7 的错误码写错（#3）单独看是文字问题，但它让"按文档 catch `Io`"的调用方静默失效，级别按后果定为一般。其余 7 条（#6–#12）是公式/API 名/文件归属/验收口径类问题，属可读性与自洽性，可随文档整理一并处理。

本部分存量问题 12 条（一般 5 / 轻微 7），是否纳入修复待用户决定。
