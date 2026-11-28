# f_svg 模块审查报告（第 7/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/doc/spec/**`（本部分 14 个文件，全部为 `.md`；模块整体 301 个 `.cj` + 141 个 `.md`）
- **部分**：模块第 **7/26** 部分（本文件只是分报告，最终模块报告由主 Agent 合并）
- **基线**：工作区快照（`120fd2542`，本部分无 diff，全部问题记「存量」）
- **审查重点**：SVG 解析 / 序列化正确性与 XML 边界、注入与转义、OOM、递归与栈溢出、死代码、重复逻辑。本部分只含规格与校验记录，专项落在「规格承诺 ↔ 实现 ↔ 自验记录」三者一致性，并核对被规格约束的安全上限、缓存与递归面。
- **报告版本**：v1（分报告）

## 发现

### [一般][存量] svg-security 的「外部文档不安全内容一律 Remove」与实现、自验记录相互矛盾

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md:20`（连带 `:9`）；实现 `f_svg/src/SvgRenderTree.cj:1871-1888`、`f_svg/src/SvgBuilder.cj:135-143`、`:375-382`
- **来源**：存量（工作区快照，无基线）
- **判据**：review-checklist §13（规格与实现漂移）/ §11（契约与实现不符）
- **证据**：静态确定 —— 规格写「外部文档……其内部的不安全内容（含外部 `href`）SHALL 一律按 `Remove` 处理并 warning，不随调用方的 `Reject` / `Keep` 改变」。`svgExternalParseOptions`（`SvgRenderTree.cj:1871-1888`）只强制了 `unsafePolicy: Remove`（`:1874`）与 `allowExternalReferences: false`（`:1877`），`allowScript`（`:1875`）、`allowEventAttributes`（`:1876`）、`strict`（`:1884`）仍从主文档原样继承；`SvgBuilder.cj:135-143` 的 `<script>` 分支仅在 `allowScript == false` 时才走 `unsafePolicy`，`allowScript=true` 时脚本会作为未知元素保留。`strict=true` 时外部文档的 `url(...)` / `@import` 仍在 `SvgBuilder.cj:375-382` 直接抛 `Security`，不到 `applyUnsafePolicy`（`:472-481`）。
- **描述**：`externalDocumentMode` 只给 `href` 开了 strict 旁路（`SvgBuilder.cj:459` 的 `strict && !externalDocumentMode`），其余不安全内容没有统一到 Remove。于是「调用方 `allowScript=true` + 外部文档含 `<script>`」会保留脚本，「`strict=true` + 外部文档含 `fill="url(https://…)"`」会抛 `Security` 而非绘制占位 + warning；`spec.md:9` 的「外部 `url(...)` SHALL 按无画笔处理并记 warning」在这两种配置下同样不成立。同一变更的自验记录 `verification.md:598`（W-3-3）已承认「外部文档仅对外部 `href` 强制 `Remove`；样式中的 `url()` / `@import` 仍受 `strict` / 安全策略约束」，与 spec `:20` 的绝对措辞直接冲突；`SvgRenderTree.cj:1864-1870` 的实现注释也重复了这句绝对承诺。
- **建议**：二选一并同步 spec、`SvgRenderTree.cj:1864-1870` 注释与 verification——①把 spec 的「一律 Remove」收窄为「外部 `href` 一律 Remove，其余内容按主文档 security / `strict` 处理」，并给 `:9` 补「`Reject` / `strict` 下抛 `Security`」分支；②在 `svgExternalParseOptions` 同时强制 `allowScript=false`、`allowEventAttributes=false`，并让 `:375` 的 strict 分支受 `externalDocumentMode` 约束，外部文档统一 Remove + warning。任选其一后补 `strict=true` + `allowScript=true` 的负向用例。

### [一般][存量] 安全上限清单只覆盖「单份 16 MiB」，外部文档缓存无聚合预算

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md:63-70`（上限清单）；实现 `f_svg/src/SvgRenderTree.cj:255-256`、`:900-924`
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 缓存键无界 / 长期持有）、§14（上限清单不完备）
- **证据**：静态确定（无聚合计数器）；峰值需实测
- **描述**：`externalDocuments: HashMap<String, SvgDocument>`（`SvgRenderTree.cj:255`）与 `missingExternalDocuments`（`:256`）按 `href` 缓存解析结果，生命周期到本次渲染结束，既无聚合字节预算也无条目上限。可加载的不同 `href` 数量只受文档元素数约束（`SvgSecurityOptions.maxElements` 默认 1,000,000，`f_svg/src/SvgOptions.cj:65`）；单份源字节 ≤ 16 MiB（`SvgExternalDocument.cj:24`、`SvgRenderTree.cj:914-919`），但解析后的元素树通常大于源字节，且全部同时驻留。含 N 个互不相同外部 `href` 的文档，峰值约为 Σ(N × 单份解析后占用)，而规格的上限清单看不到这一维。图像侧有整轮预算作对照：`SvgDecodeBudget`（`f_svg/src/SvgPngDecoder.cj:30-52`，超限抛 `Limit`），外部文档没有同构机制。
- **建议**：在渲染期增加与 `SvgDecodeBudget` 同构的「外部文档预算」（累计源字节 + 解析元素数），超限抛 `Limit`；或把「聚合字节 / 条目上限由调用方 provider 负责」写进 `svg-security` 的上限清单并给出量化口径，避免读者按单份 16 MiB 推断总内存上界。补一条 100+ 个不同 `href` 的负向用例。

### [轻微][存量] 终验用例数 1187 与文首 / CHANGELOG 的 1186 未统一，W-3-4 声称的 CHANGELOG 修复未落地

- **位置**：`f_svg/doc/spec/add-f-svg-m6/verification.md:4`、`:543`（1186）对照 `:580`、`:590`、`:602`（1187）、`:599`（W-3-4）；`CHANGELOG:146`
- **来源**：存量
- **判据**：review-checklist §13（文档数据与事实不符）
- **证据**：静态确定 —— 终验后总数为 1187：`verification.md:602` 写「终验后复跑 `1187 / 1187 PASSED`」，`:580` / `:590` 也写 1187；`verify-report.md` 的 W-3-2 记录终验新增 `externalDocumentDataHrefIsNotExternal`，`src/SvgExternalDocumentM6_test.cj:320` 确有该用例。M7 侧可交叉验证：`doc/spec/add-f-svg-m7/design.md:11` 以 **1187** 为 M6 结束基线，`add-f-svg-m7-output-overloads/tasks.md:8` 的 1226 = 1187 + 39（M7 前四个测试文件的 39 条用例）。
- **描述**：`verification.md:4` 仍写「第三轮修复后为 1186」，第三轮块 `:543` 写「本轮结束 1186 条（新增 8 条）」；这两处停留在 W-3 终验新增用例之前，而同一文件的 §4/§5/§6 已用 1187。`:599` 的 W-3-4 写「已修复：`CHANGELOG` 用例数更新为 1187」，但 `CHANGELOG:146` 实际仍是「1186 条用例全绿」。门禁记录因此同时存在 1186 与 1187 两套总数。
- **建议**：把 `verification.md:4`、`:543` 统一为 1187（或注明「第三轮 1186，终验 W-3-2 后 1187」），并把 `CHANGELOG:146` 更新为 1187；否则 W-3-4 应改为「未更新」而不是「已修复」。

### [轻微][存量] tasks.md 9.5 已勾选「openspec validate 通过」，verification.md 仍记「无 CLI 未执行」

- **位置**：`f_svg/doc/spec/add-f-svg-m6/tasks.md:119` 对照 `f_svg/doc/spec/add-f-svg-m6/verification.md:348`；旁证 `f_svg/doc/spec/add-f-svg-m6/verify-report.md:474`、`verification.md:600`
- **来源**：存量
- **判据**：review-checklist §13（同一变更的两份记录结论相反）
- **证据**：静态确定 —— `tasks.md:119` 写 `[x] 9.5 运行 openspec validate add-f-svg-m6 --strict（通过，无 warning / error）`；`verification.md:348`（W5 行）写「9.5 因环境无 `openspec` CLI 保持未勾选，9.8 等待用户确认」；`verification.md:600` 的 W-3-5 又声称「已修复：`verification.md` 的 9.5 表述改为『已补跑并勾选』」，但 `:348` 并未改动；`verify-report.md:474` 记录 `command not found`。
- **描述**：同一门禁同时存在「已通过」「未执行」「已改为已通过」三种说法。当前仓库也没有 openspec 侧的 M6 目录（见下一条），因此 `--strict` 通过没有可复核证据。
- **建议**：若确实补跑过，在 `verification.md` 记录命令与输出摘要并删除 `:348` 的过期表述；若没跑过，取消 `tasks.md:119` 的勾选并注明未执行原因，同时把 W-3-5 改为「未复核」。

### [轻微][存量] 安全覆盖矩阵前 5 行指向不含对应断言的测试类，动画 14–21 行共用同一组落点

- **位置**：`f_svg/doc/spec/add-f-svg-m6/verification.md:240-244`（`svg-security` 第 1–5 行）、`:40-47`（`svg-animation` 第 14–21 行）；实现侧 `f_svg/src/SvgForeignObjectM6_test.cj`、`f_svg/src/SvgExternalDocumentM6_test.cj:54-346`
- **来源**：存量
- **判据**：review-checklist §14（覆盖证据失真）/ §13（矩阵与取证口径不一致）
- **证据**：静态确定 —— 安全矩阵第 1–5 行（外部 CSS 引用、外部图片、未注入图片资源、注入 `mem://` provider、动画不执行脚本）统一写「`SvgExternalDocumentM6_test.externalDocumentForcesRemovePolicy/externalDocumentCannotChain/noRecursion`、`SvgForeignObjectM6_test`」。`SvgExternalDocumentM6_test` 的 14 个用例全部围绕 `use` / provider / 字节上限 / 循环引用；`SvgForeignObjectM6_test` 只测注入渲染器与像素预算，grep `image|href|passwd` 无命中。这两个类都不含上述 5 个场景的断言（真实覆盖散在 `SvgSecurity_test.cj:288-290`、`SvgPaint_test.cj:77`、`SvgRenderer_test.cj`）。动画 14–21 行则 8 个场景共用同一串 5 个用例名。
- **描述**：矩阵文首（`:19-21`）声明「每个 Scenario 单列一行……落点为直接断言或该 Requirement 的专用测试入口」，`:329` 据此得出「全部有可执行落点」。前 5 行把场景挂到不相关测试上，属于映射失真；动画段虽然落在同一 Requirement 的用例集内，但无法证明「这一行 Scenario」有对应断言。矩阵是「256 Scenario 全覆盖」的唯一证据，失真会让结论不可审计。
- **建议**：安全第 1–5 行改指向真实用例（`SvgSecurity_test` 的外部 URL 断言、`SvgRenderer_test` 的 `<image>` 占位、`SvgFilterNoiseM4_test` 的 `mem://` provider、`SvgAnimationControlM6_test` 的未触发事件用例）；动画 14–21 行填具体方法名（如 `indefiniteBegin` / `explicitEnd` / `fireEvent`），或把矩阵降级为 Requirement 级并注明「场景级未逐条取证」。

### [轻微][存量] 校验对象指向的 `openspec/changes/add-f-svg-m6` 与 `openspec/specs/svg-*` 在当前仓库不存在，证据不可复核

- **位置**：`f_svg/doc/spec/add-f-svg-m6/verification.md:3`、`:546`；`f_svg/doc/spec/add-f-svg-m6/verify-report-3.md:82`；`f_svg/doc/spec/add-f-svg-m6/tasks.md:156`
- **来源**：存量
- **判据**：review-checklist §13（链接 / 路径失效）
- **证据**：静态确定 —— `openspec/changes/` 只有 `add-f-a2a/` 与 `archive/`（归档末 5 条均为 2026-11-20 的非 f_svg 变更）；`openspec/specs/` 只有 `data-assist-compare` / `data-assist-supertypes` / `jwt-signature` / `orm-result-type-mapping` / `uring-async-io`，没有 `svg-*`。而 `verify-report-3.md:82` 声称「`f_svg/doc/spec/add-f-svg-m6/specs` 与 `openspec/changes/add-f-svg-m6/specs` 逐文件一致（`diff -rq` 无差异）」，该命令现在必然失败；`verification.md:546` 也写「两份副本保持一致」。
- **描述**：M6 的规格与验证材料现在只存在于模块 `doc/spec/` 下，报告却仍以 openspec 变更目录为主校验对象，`tasks.md:156` 还要求归档后核对 `openspec/specs/` 的 10 个能力域。读者按报告路径无法复现任何结论。
- **建议**：在 `verification.md` 开头注明「openspec 侧内容已并入 `f_svg/doc/spec/add-f-svg-m6`，校验对象以本目录为准」，并删除或改写 `verify-report-3.md:82` 的 `diff -rq` 结论；若确需保留 openspec 副本，应补回 `openspec/changes/add-f-svg-m6` 与对应的 `openspec/specs/svg-*`。

## 优化可行性方案

### [堆内存] `save(path:)` 改为流式落盘，去掉 String + 字节数组双份驻留

- **现状**：`f_svg/src/SvgAuthoringBuilder.cj:66-72` 的 `save(path: Path)` 先 `toSvgString()` 物化整份 `String`，再 `.toArray()` 复制成整份 `Array<Byte>` 交给 `File.writeTo`；同一份输出在峰值同时存在两份完整表示（String + 字节数组），写盘结束才释放。调用 `save(path: String)`（`:61-63`）同样走这条路径。
- **方案**：用 `File.create(path)` 打开后调用已存在的 `write(output: OutputStream)`（`SvgAuthoringBuilder.cj:75-79`），在 `try` 中关闭文件；异常仍按 D9 包 `invalidValue`。不新增 API，不改 `toSvgString`。
- **预期**：峰值从约 2× 输出大小降到约 1×；对 50 MB 级生成物可省约 50 MB 级峰值（按 UTF-8 字节估算，中文按实际编码）。
- **代价**：`save(path)` 由库负责打开/关闭句柄（现由 `File.writeTo` 承担，对外语义不变）；错误信息需保留路径。
- **验证**：生成 50 MB 级文档，改前/改后各跑 10 轮，记 `getAllocatedHeapSize()` 峰值与 RSS 峰值，并断言落盘字节与 `toSvgString()` 逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 多个不同 href 的外部文档在单次渲染中聚合占用远高于单份 16 MiB 上限 | `src/SvgRenderTree.cj:255,914-924` | 峰值 RSS / heapUsed 与条目数的关系 | 构造 200 个 `use` 指向 200 份各 8 MiB 的 provider 文档，跑单次渲染，记 `getAllocatedHeapSize()` 与 RSS 峰值 |
| 2 | 同一文档重复渲染会重复解析外部文档（缓存只存活于单次渲染），parse + 样式计算占比可观 | `src/SvgRenderTree.cj:255,900-927` | `cjprof` 中 parse 自耗时占比 | 对含 20 个外部文档的文档连续 render 100 次，`cjprof record` 取 `SvgParser.parse` 与 `SvgStyleResolver.compute` 自耗时占比 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_svg.part7.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md` | .md | ✅ | 见发现 #1（`:20`、`:9`）、#2（`:63-70`） |
| 2 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-text/spec.md` | .md | ✅ | 9 Requirement / 48 Scenario，与 verification 矩阵计数一致；字距、连字、GSUB 深度 8 与 `CSS_GSUB_MAX_DEPTH`（`src/SvgOpenTypeLayout.cj:23`）一致 |
| 3 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-value-types/spec.md` | .md | ✅ | 5 Requirement / 18 Scenario；枚举、工厂、`SvgViewState` 均有实现符号 |
| 4 | `f_svg/doc/spec/add-f-svg-m6/tasks.md` | .md | ✅ | 见发现 #4（`:119`）、#6（`:156`） |
| 5 | `f_svg/doc/spec/add-f-svg-m6/verification.md` | .md | ✅ | 见发现 #1（`:598`）、#3（`:4`/`:543` vs `:580`）、#4（`:348`）、#5（`:240-244`、`:40-47`）、#6（`:3`/`:546`） |
| 6 | `f_svg/doc/spec/add-f-svg-m6/verify-report-2.md` | .md | ✅ | 第二轮复验记录，C8 判定为 CRITICAL 后被第三轮关闭，记录自洽 |
| 7 | `f_svg/doc/spec/add-f-svg-m6/verify-report-3.md` | .md | ✅ | 实测 1186（终验前）；W-3-1～W-3-5 与 verification 的对应关系见 #3、#4、#6 |
| 8 | `f_svg/doc/spec/add-f-svg-m6/verify-report.md` | .md | ✅ | 第一轮 54 Requirement / 255 Scenario 与后续 55/256 的差异在 `verification.md:364` 有说明，属历史口径 |
| 9 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/design.md` | .md | ✅ | D1–D4 与 `SvgAuthoringBuilder.cj:56-88` 逐条一致（构造 `SvgWriter` + `write` + `flush`、不关闭流/文件、`save(file:)` 委托 `write`） |
| 10 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/proposal.md` | .md | ✅ | 与 design/spec 一致；1226 + 2 = 1228 与 tasks/verification 自洽 |
| 11 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/specs/svg-authoring/spec.md` | .md | ✅ | 「`write` 只 flush 不关闭」「`save(file:)` 不关闭」「失败按 InvalidValue」三条与实现一致（`SvgAuthoringBuilder.cj:75-88`） |
| 12 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/tasks.md` | .md | ✅ | 4.1 的 1228 条与 verification 一致（M7 时点口径）；20 条定向用例与 `SvgBuilderM7_test.cj` 相符 |
| 13 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/verification.md` | .md | ✅ | 「定向 20 / 20」与 `src/SvgBuilderM7_test.cj` 的 20 个 `@TestCase` 相符 |
| 14 | `f_svg/doc/spec/add-f-svg-m7/design.md` | .md | ✅ | D1–D10 逐条对照实现成立；引用行号 `SvgWriter.cj:216`、`SvgBuilder.cj:34`、`SvgTag.cj:79`、`SvgException.cj:21`、`SvgBitmap.cj:173`、`SvgNumber.cj:32` 全部核对通过 |

合计：`.cj` 0 个 / `.md` 14 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 安全性 1 条（发现 #1）；本部分无函数实现，逻辑 / 语言特性维度不适用 |
| §1 死代码 | 0 | 本部分 0 个 `.cj`，无符号可判；已核对 14 个 `.md` 的交叉引用（`specs/svg-*/spec.md`、`doc/f_svg-M6设计.md`、`doc/f_svg-M7设计.md`、`doc/perf-baseline.md`）全部存在；文档引用的 6 处源码行号与 11 个测试方法名均命中 |
| §2 重复逻辑 | 0 | 已比对三份 `spec.md`：按能力域拆分，无同语义重复段落；`tasks.md` / `verification.md` / `verify-report*.md` 之间的重复属记录性复述，其漂移已作为 #3/#4 的根因合并，不另计 |
| §3 空实现 | 0 | 抽查各 Requirement 的实现符号：`SvgPointerEvents` / `SvgShapeRendering` 等枚举、`SvgViewState`、`SvgHitTest.elementsAt`、`SvgExternalDocumentProvider`、`SvgForeignObjectRenderer`、`fireEvent` 均存在且非空；spec 中无 TODO 占位 |
| §4 栈溢出 | 0 | 文档声明的递归面（`use` 展开 64、GSUB 8、`maxDepth` 512）与常量一致；外部文档深度 4 仅防御且正常路径不可达（`SvgExternalDocument.cj:26-37`）；本部分无独立递归代码可判 |
| §5 OOM | 1 | 发现 #2（外部文档聚合无上限）；单份 16 MiB、`maxElements` 1e6、图像 64 Mi 像素预算已核对落地 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，重复渲染的外部文档解析列入「待验证假设」#2，不当作发现 |
| §6.2 大粒度锁 | 0 | 本部分为文档，无锁实现可判 |
| §6.3 并发串行 | 0 | 同上，无 `spawn` / 批处理代码 |
| §6.4 低效算法 | 0 | 同上；规格未承诺复杂度指标 |
| §7 降堆内存方案 | 1 | 优化方案 1 条（`save(path:)` 流式落盘），证据状态为无基线 |
| §8 降 CPU 方案 | 0 | 无基线数据，不给结论 |
| §9 local mode 可行性 | 0 | 本部分为文档，无函数级临时对象；不适用 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`；发现 #1/#2 的代码侧证据分别计入安全性 / §5，不重复统计 |
| §12 并发安全与锁粒度 | 0 | 文档未描述新的共享可变状态；`write` / `save(file)` 只操作调用方传入的流与文件 |
| §14 功能完备性与 README 覆盖 | 1 | 发现 #5（覆盖矩阵取证失真）；另核对 M7 新增 `write(OutputStream)` / `save(File)` 已登记于 `README.md:95,405` 与 `README_en.md:98,412`（README 属其他部分，仅作交叉确认） |
| 文件覆盖（§13 等） | 14/14 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量 6 条（全部落在本部分文件内），是否纳入修复待用户决定。

## 总评

本部分 14 个文件是 M6 / M7 两个变更的规格与校验记录，闭环质量较高：规格—任务—验证三段可追溯，安全上限（16 MiB 外部文档、64 条特性、32 个监听器、discard 深度 1、`maxElements`、8 层 GSUB、32 MiB base64）逐条能在代码里找到对应常量与负向用例；M7 的 `write(OutputStream)` / `save(File)` 与 design、spec、README、20 条测试四方对得上，没有 XML 拼接或转义责任错位。

主要风险有两处。一是 `svg-security` 用绝对措辞承诺「外部文档不安全内容一律 Remove」，而实现仍继承 `allowScript` / `allowEventAttributes` / `strict`，同一变更的自验记录（W-3-3）也承认了这个边界，属于规格与实现、规格与自验记录的双重矛盾，按现文本引用该规格会得到错误的保证。二是外部文档缓存只有「单份 16 MiB」而没有聚合预算，`use` 数量受 `maxElements` 约束时可累积到远超单份上限的驻留内存，而图像侧已有像素预算兜底，两者不对称。

其余 4 条是校验记录自身的小口径问题（1187/1186、9.5 是否执行、矩阵落点失真、openspec 路径失效），不影响功能，但会削弱归档记录作为审计证据的可信度。本部分不含源码，无阻塞项；建议在归档 M6 前一次性收敛计数与矩阵，并给外部文档预算一个明确结论。
