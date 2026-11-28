# f_svg 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（442 个文件：301 个 .cj + 141 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 26 个分部分报告合并：`parts/f_svg.part1..26.md`）

## 发现

<!-- 第 1 部分 -->

> 条目按出现顺序编号 #1–#14（#1–#5 一般，#6–#14 轻微），供「文件覆盖」「覆盖自检」引用。

### [一般] README 的异常处理示例把 `SvgException.elementPath` 字段当方法调用，示例无法编译

- **位置**：`f_svg/README.md:463`、`:469`；`f_svg/README_en.md:471`、`:477`；实现 `f_svg/src/SvgException.cj:65`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例代码不能用」、§13「API / 配置与默认值与源码不符」
- **证据**：静态确定 —— `SvgException` 上是 `public let elementPath: ?String`（`SvgException.cj:65`），全仓 `grep "func elementPath"` 只命中 `SvgElement.elementPath(): String`（`SvgElement.cj:377`），`SvgException` 没有任何同名方法，也没有 `extend SvgException`
- **描述**：「错误与告警」是本模块唯一的异常处理示例，照抄会得到编译错误（`Option<String>` 不能当函数调用）。即使改成字段访问，`?String` 直接插值会输出 `Some(/svg[1]/g[2]/rect[1])`，与 `:469` 承诺的 `/svg[1]/g[2]/rect[1]` 不同。中英两版同源同错，`:469` / `:477` 的「`elementPath()` 形如 …」进一步强化了「这是方法」的误读
- **建议**：示例改为 `println("${error.kind}: ${error.message} @ ${error.elementPath ?? ""}")`；`:469` / `:477` 改为「`SvgException.elementPath` 字段（`Option<String>`）形如 …；元素自身用 `SvgElement.elementPath()`」

### [一般] 安全表只在 `<script>` / `file:` 两行提到 `unsafePolicy`，实际 `unsafePolicy=Keep` 会同时保留 `on*`、外部 `href`、`url()`

- **位置**：`f_svg/README.md:444-452`（表；`on*` 在 447、`http(s)`/`//` 在 448）、`f_svg/README.md:454`；`f_svg/README_en.md:451-459`、`:461-462`；实现 `f_svg/src/SvgBuilder.cj:367-374`、`:445-463`、`:472-481`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」、§10 安全性（注入面描述不完整）
- **证据**：静态确定 —— `on*` 属性在 `allowEventAttributes=false` 时不直接删除，而是落到 `applyUnsafePolicy`，`Keep` 分支返回 `false` = 保留；`href` 在 `allowExternalReferences` 判定失败后同样落到 `applyUnsafePolicy`；即 `Keep` 让三个 `allow*` 开关同时失效。表内 `<script>` 行写了「`allowScript` / `unsafePolicy`」、`file:` 行写了「仅 `unsafePolicy`」，唯独 `on*` 与 `http(s)` 两行只写 `allow*`——同表内部就不一致
- **描述**：安全示例（`README.md:429-441`）把 `unsafePolicy` 放在首位，说明它是常规配置。调用方若为保留未知元素/自定义属性而配 `Keep`，同时保留 `allowEventAttributes: false`，会以为 `on*` 已被移除，实际全部保留；产物交给浏览器即等于放开注入面。默认 `Remove` 下行为正确
- **建议**：表格「开关」列统一写成「`allowEventAttributes`；`unsafePolicy=Keep` 时一律保留」，补一句「`Keep` 优先于所有 `allow*` 开关」；若认为优先级不合理，则改代码让 `allow*` 优先（行为变更，需用户拍板，并在 `SvgSecurity_test` 补例）。另可补 `xml:base`（`SvgBuilder.cj:355-356` 已按 `unsafePolicy` 处理，README 未列）

### [一般] README 首段「不读字体/图片文件」与公开 API `SvgTrueTypeFont.load(path)` 及本模块 M4 设计冲突

- **位置**：`f_svg/README.md:13`、`:509`；`f_svg/README_en.md:13`、`:517`；实现 `f_svg/src/SvgTrueTypeFont.cj:330-337`、`:29-34`；本模块设计 `f_svg/doc/f_svg-M4设计.md:189-190`
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§10 安全边界描述
- **证据**：静态确定 —— `SvgTrueTypeFont.load(path)` 调 `SvgFontFileAccess.read(path)`，后者是 `File.readFrom(path)`；M4 设计原文写「`load(path)` 是库内唯一文件入口；`parse(bytes)` 与渲染链都不访问文件系统」；而 README 的「不支持与安全边界」表把「网络与文件读取」整列列为不实现
- **描述**：README 把「不读字体/图片文件」与「不联网」「不执行脚本」并列，读者会据此得出「库内无任何文件读路径」的合规/沙箱结论；而 `README.md:647` 自己就把 `SvgTrueTypeFont.load` 列为公开 API。该路径只能由调用方显式调用、无法由 SVG 内容触发，因此不构成可利用漏洞，但上述结论是错的
- **建议**：首段改为「解析与渲染链不读写文件；唯一文件入口是 `SvgTrueTypeFont.load(path)`，由调用方显式调用并自行承担路径安全」；不支持表改为「渲染期文件读取」，与 M4 设计措辞对齐

### [一般] 「先写 `defs` 再交给 `SvgBuilder` 输出」没有对应入口，建议不可执行

- **位置**：`f_svg/README.md:274`、`f_svg/README_en.md:278`；实现 `f_svg/src/SvgAuthoringBuilder.cj:37`（唯一构造）、`:51-88`（全部输出方法）
- **来源**：存量
- **判据**：review-checklist §13「示例 / 建议不可执行」、§14.1「接线缺失」
- **证据**：静态确定 —— `SvgBuilder` 只有一个 `init(width: Float64, height: Float64, viewBox!: ?SvgViewBox = None)`；公开方法中没有接受 `SvgDocument` / `SvgElement` 的入口，`document()` 是取内部 root 的 getter（方向相反），`toSvgString` / `save` / `write` 只序列化内部 root
- **描述**：README 在「渐变 / `defs` 构建 | 不支持」一行给出「用 DOM API 或先写 `defs` 再交给 `SvgBuilder` 输出」。前半可行，后半在当前 API 下无法完成：既不能把外部文档交给 builder，也没有 `append(element:)`。而 gradient/defs 恰恰是 `SvgBuilder` 无法重建的部分，读者会卡在找不到 API
- **建议**：改为「用 DOM API 写 `defs` 后 `writeSvgString(document)`；`SvgBuilder` 只用于从零新建文档」；若要支持混用，补 `SvgBuilder(document: SvgDocument)` 或 `append(element: SvgElement): SvgBuilder`

### [一般] `SvgHitTest.hitTest` 被写成类级调用，实际是实例方法

- **位置**：`f_svg/README.md:245`、`f_svg/README_en.md:249`；实现 `f_svg/src/SvgHitTest.cj:145`、`:159`，对照 `:203`、`:240`
- **来源**：存量
- **判据**：review-checklist §13「示例引用不存在的 API 形式」、§14.2 README 覆盖准确性
- **证据**：静态确定 —— 两个 `hitTest` 重载都是 `public func`（无 `static`），不能写成 `SvgHitTest.hitTest(...)`；模块测试的实际写法是 `SvgHitTest().hitTest(root, SvgPoint(...))`（`f_svg/src/SvgHitTestM6_test.cj:50/63/74`）。`README.md:542` 又专门说明「`elementsAt` / `elementAt` 为 `public static`」，对比之下 `hitTest` 更像同类静态入口
- **描述**：照抄会编译失败；`SvgHitTest` 还需要保留实例以读取 `warnings`（`:143`），构造方式不能省
- **建议**：改成 `SvgHitTest().hitTest(document, point, options: SvgRenderOptions(...))`，并注明返回「自上而下（后绘制者在前）」以及 `hitTest().warnings` 的用途

### [轻微] 「生成 / 写回」行中文版多出「未知内容…可配置」，且「`href` 读写形式可配置」只对写成立；英文版无此句

- **位置**：`f_svg/README.md:111`、`f_svg/README_en.md:115`；实现 `f_svg/src/SvgWriter.cj:22-46`
- **来源**：存量
- **判据**：review-checklist §13「API / 配置与源码不符」、§13「`README_en.md` 与 `README.md` 不同步」
- **证据**：静态确定 —— `SvgWriteOptions` 只有 `indent` / `xmlDeclaration` / `charset` / `cdata` / `xlink` / `trailingNewline`，没有任何「未知内容」开关；未知元素/属性一律保留（`SvgUnknownElement`），不可配置。`href` 的读取固定同时接受 `href` 与 `xlink:href`（`README.md:501` 自己也是这么写的），只有写入形式由 `xlink` 决定
- **描述**：中文版暗示存在「未知内容」写入配置，使用者会去找不存在的选项；英文版没有这句，说明两版不是同步维护的。同段其余描述与实现一致
- **建议**：中文改为「未知内容一律保留；`href` 写入形式由 `SvgWriteOptions.xlink` 决定」，与英文对齐

### [轻微] 「OpenSpec 主规格」指向不存在的 `openspec/specs/svg-*`

- **位置**：`f_svg/README.md:550`、`f_svg/README_en.md:561`
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— `find openspec -maxdepth 3 -iname "*svg*"` 无结果；`openspec/specs/` 只有 `data-assist-compare`、`data-assist-supertype`、`jwt-signature`、`orm-result-type-mapping`、`uring-async-io`；`openspec/changes/archive/` 也无 svg 条目。f_svg 的规格实际归档在 `f_svg/doc/spec/add-f-svg-m1…m7` 与 `local-mode-f-svg-analytic-coverage`
- **描述**：读者按 README 去 `openspec/specs/` 找不到任何规范；`doc/spec/` 是归档变更的验收记录，不等于「主规格」。这也是发现 #13 的漂移能长期存在的原因之一
- **建议**：删掉该行，或改为 `f_svg/doc/spec/add-f-svg-m*/specs/` 并注明「归档变更、非当前主规格」

### [轻微] 自动生成的「其他公开 API」清单混入 `internal` 类型成员与 `@When[test]` 钩子，且有截断条目与 `static` 标注不一致

- **位置**：`f_svg/README.md:559`（`public static func count(): Int64`、`public static func reset(): Unit`、`table`（func））、`:576`、`:615`；`f_svg/README_en.md:570`、`:587`、`:626`；源码 `f_svg/src/SvgTrueTypeFont.cj:29`、`:37-45`、`f_svg/src/SvgTrueTypeTables.cj:150`、`:165`、`f_svg/src/SvgAutoSize.cj:33-39`、`f_svg/src/SvgNamespaces.cj:25-27`、`f_svg/src/SvgFilterPrimitives2.cj:142-144`
- **来源**：存量
- **判据**：review-checklist §14.2（文档列了非公开 API）、§13「文档质量：条目不可用」
- **证据**：静态确定 —— `count()` / `reset()` 是 `internal class SvgFontFileAccess` 的成员且带 `@When[test]`，只在测试构建存在；`table(tag:)` 属 `internal class SvgTtfTableDirectory`，对外不可达；按硬原则二它们都不是公开契约。另 `SvgAutoSize`：`static func rootSize(`（参数表截断，实际 5 参）、`SvgNamespaces`：`static let SVG: String =`（值截断，实际三个 URL 常量）；`SvgEdgeMode` 行把 `Duplicate` 标成 `(let)`、`NoEdge` / `Wrap` 标成 `static let`，三者其实都是 `public static let`
- **描述**：清单对外呈现「模块级 API」，却把测试钩子和内部类型成员列为公开入口；截断条目等于没有信息（`rootSize` 少了 4 个参数与返回类型）
- **建议**：生成器按「顶层声明 + 对外可达嵌套链」过滤，并统一 `static let` / `let` 标注、截断处改用 `…`；手工删除 `count` / `reset` / `table` 三项并补齐两条签名

### [轻微] README 说 Hershey 字体「无小写」，实现是 ASCII 32–126 全覆盖、小写复用大写字形

- **位置**：`f_svg/README.md:177`、`f_svg/README_en.md:181`；实现 `f_svg/src/SvgHersheyFont.cj:27`、`:234-243`；本模块设计 `f_svg/doc/f_svg-M2设计.md:371`
- **来源**：存量
- **判据**：review-checklist §13「文档过期：写着暂不支持其实已支持」
- **证据**：静态确定 —— 类注释写「覆盖 ASCII 32–126」；`:234-237` 把 `97..=122` 逐码位映射到 `codePoint - 32` 的大写字形，`:239-243` 再给 33–126 的缺项补占位方框
- **描述**：`text="abc"` 不会缺字，而是渲染成 `ABC` 的字形。README 的「覆盖 ASCII 大写、数字与标点；无小写」容易被读成「小写不渲染」，与 M2 设计的「ASCII 32–126」也不一致；真正缺的是独立小写字形设计与 CJK
- **建议**：改为「Hershey 单线字体：ASCII 32–126；小写复用大写字形（无独立小写设计），无 CJK」

### [轻微] 安全表把 `data:` 限定为「图片」，实现按任意 `data:` 前缀放行

- **位置**：`f_svg/README.md:450`、`f_svg/README_en.md:457`；实现 `f_svg/src/SvgBuilder.cj:445-455`、对照 `:466-470`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」、§10 安全边界描述
- **证据**：静态确定 —— `handleHrefValue` 只判断前 5 字节是否为 `data:` 与 `allowDataImages`，不校验 MIME，`data:text/html,…` / `data:image/svg+xml,…` 同样保留；只有非 `data:` 的外部引用才走 `isPermittedExternalReference` 的 http/https/`//` 白名单
- **描述**：库内不解码 SVG/HTML、也不激活链接，因此不构成直接漏洞；但下游若把 `href` 直接交给浏览器或 WebView，`data:text/html` 的语义与文档预期不同。是否构成实际风险取决于下游用法（待确认）
- **建议**：表格改为「`data:` 引用（任意 MIME）| 保留 | `allowDataImages`」，或把实现收紧为只放行 `data:image/png`（与「只解码 PNG」一致），二者取一后中英同步

### [轻微] `doc/f_svg-M6设计.md` 的模块布局列出 3 个不存在的源文件

- **位置**：`f_svg/doc/f_svg-M6设计.md:321`（`SvgColorProfile.cj`）、`:326`（`SvgAnimationControl.cj`）、`:330`（`SvgLineJoin2.cj`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」「文档与实现漂移」
- **证据**：静态确定 —— `f_svg/src/` 无这三个文件；对应能力分别落在 `SvgComputedStyle.cj`（`colorProfile()`）+ `SvgRenderer.cj`、`SvgTimeline.cj:333-366`（`begin` / `end` / `fireEvent` / `pause`）、`SvgStrokeOutliner.cj`（`MiterClip` / arcs）。M2–M5 的同类文件表逐项核对均存在
- **描述**：M6 是最后一版里程碑设计，§9 的文件表会被当作改动落点；三个虚拟文件会让后续维护者在错误位置找实现
- **建议**：改为实际落点文件，或在表头注明「计划布局，最终实现可能合并进既有文件」

### [轻微] `doc/f_svg-M5设计.md` 用加权和描述选择器特异性，实现是三元组字典序

- **位置**：`f_svg/doc/f_svg-M5设计.md:91`；实现 `f_svg/src/CssSelector.cj:99-128`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `CssSpecificity` 保存 `(ids, classes, types)`，`compareTo` 按 ids → classes → types 逐级比较，没有 100/10/1 加权；M2 设计 `:97` 写的正是「`(id, class, type)` 三元组比较」
- **描述**：两种口径在常规选择器上等价，极端输入会分歧：10 个类（加权 100）与 1 个 id（加权 100）在加权口径下打平、靠源顺序决胜，实现里 id 恒胜。若后续按 M5 文字扩展计数规则，会得到与运行时不同的排序
- **建议**：改为「(id, class, type) 三元组逐级比较」，或注明「加权仅为说明性近似，实现以三元组为准」

### [轻微] M2–M6 里程碑设计文档未标注「已被后续里程碑取代」，仍以现在时写「不支持」

- **位置**：`f_svg/doc/f_svg-M2设计.md:32`、`:87`、`f_svg/doc/f_svg-M4设计.md:191`、`f_svg/doc/f_svg-M3设计.md:332-336`；对照 `f_svg/README.md:135-144`、`:179-180` 与实现 `f_svg/src/CssMedia.cj`、`f_svg/src/CssSelector2.cj`、`f_svg/src/SvgOpenTypeLayout.cj`、`f_svg/src/SvgBitmap.cj:209`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」；§13 误报边界「明确标注历史 / 已废弃」的豁免**不成立**——这 5 份文件均无归档声明，README「更多文档」也未索引它们（只索引 `f_svg模块设计.md` 与 `f_svg-M7设计.md`）
- **证据**：静态确定 —— M2 写「`@media`、`@import`、伪类、属性选择器：**不支持**」「完整 CSS3（伪类、媒体查询、`@font-face`）不做」，M5 已实现且 README 标「支持」；M4 写「不解析 hinting、`GSUB` / `GPOS` / `kern`（字距为 0）」，M5 已实现；M3 把 `antiAlias` 写成 `public var`，实际是 `public let`
- **描述**：同一份能力矩阵在 README(zh)、README(en)、M2–M6 共 6 处各写一遍，已出现三类漂移：能力状态（本条）、字段可变性（本条）、具体落点与口径（#11、#12）。读者从 `doc/` 目录直接进入时没有任何时效提示
- **建议**：5 份文件文首各加一行「历史里程碑设计，能力与默认值以 README / `src/` 为准」；README「更多文档」补齐 M2–M6 索引并注明性质；后续只维护 README 一份能力矩阵（见「优化可行性方案」第 1 条）

### [轻微] README「当前 1230 条用例全绿」与当前源码的 1242 条 `@TestCase` 不一致

- **位置**：`f_svg/README.md:533`、`f_svg/README_en.md:543`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」
- **证据**：静态确定 —— `src/*.cj` 现为 215 处 `@Test`（分布在 169 个 `*_test.cj`）与 1242 条 `@TestCase`；`1230` 无法从当前源码复现（差值 12 条，可能来自 M7 后的新增/改写）。「构建 0 warning」本轮未跑构建，未复核
- **描述**：对外文档给出无法复现的计数会让使用者误判测试规模；这类数字每次加用例都会过期
- **建议**：改为「`cjpm test` 全绿」并去掉具体条数，或按最近一次实测更新并注明 SDK 版本

### 范围外提示（不计入本部分统计，属其他部分文件）

- `f_svg/src/SvgGzip.cj:96` 末尾 `// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。` 已过期：两个入口在 `SvgParser.cj:71` / `:83` 均已实现并有测试，属残留注释（§1 兼容残留）。
- `f_svg/src/SvgTimeline.cj:232` 每次 `sample()` 都对 `discard` 嵌套超限追加同一条 warning（调用点 `:224`）；README:369 承诺「同一时间点重复采样结果一致」，DOM 一致但 `warnings` 随采样次数线性增长，逐帧渲染时是无界增长点（§5 / §12）。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [一般][存量] `svg-png` 的 Paeth Scenario 期望值算错（预测器取左，不是取上）

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md:73-76`（`#### Scenario: Paeth 行`）；实现对照 `f_svg/src/SvgPngDecoder.cj:454-476`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例不能用 / 文档承诺与实现相反」+ §11「契约与实现不符」
- **证据**：静态确定 —— Paeth 预测器 `p = a + b - c`，取 `|p-a|`、`|p-b|`、`|p-c|` 最小者。代入 Scenario 的 `left=10, up=20, upLeft=30`：`p = 0`，`pa=10 < pb=20 < pc=30` → 选 **左**，重建值应为 `原始值 + 10`。实现 `SvgPngDecoder.cj:454-476` 正是标准写法（`estimate = left + up - upLeft`，先比 `distanceLeft`）
- **描述**：Scenario 写「重建值等于 `原始值 + 20`（Paeth 选择上方）」，与算法和本仓实现都相反。这是 `svg-png` 里唯一一条逐字节的预测器验收口径：照它补用例必然失败，反过来也可能把错误实现验收通过
- **建议**：改为「选左，重建值 = 原始值 + 10」；若要覆盖「选上 / 选左上」分支，另给两组数值（如 `left=20, up=10, upLeft=30` 选上；`left=30, up=20, upLeft=10` 选左上），并注明 `a / b / c` 的对应关系

### [一般][存量] `svg-png` 把「解压字节数 = height × (1 + rowBytes)」写成全局校验，与同文件 Adam7 要求冲突

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md:92`（校验清单第 6 条）；冲突条款 `:69-71`；实现 `f_svg/src/SvgPngDecoder.cj:143-144`（非交错）与 `:183-184`（Adam7 逐 pass 求和）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」+ 规格内部自相矛盾
- **证据**：静态确定 —— 交错图像的解压流是 7 个 pass 各自 `passHeight × (1 + passRowBytes)` 之和，不等于整幅 `height × (1 + rowBytes)`；实现明确分两条路径计算 `expected`，与 Adam7 条款一致、与第 6 条不一致
- **描述**：按 `:92` 逐字验收会把**所有合法交错 PNG** 判为结构错误（`Syntax`），直接与 `:69-71`、`:78-82` 的 Scenario 对立
- **建议**：`:92` 拆成两条——非交错用 `height × (1 + rowBytes)`；Adam7 用「各 pass `passHeight × (1 + passRowBytes)` 之和」，并说明两式都在解压上限内比较

### [一般][存量] `svg-marker` 缺省值 Scenario 与自身 `?SvgLength` 类型、C7 决策及实现三方相反

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-marker/spec.md:18-21`（`Scenario: 缺省值`）；类型声明 `:9-11`；决策 `f_svg/doc/spec/add-f-svg-m3/fix-plan.md:81-87`（C7）；实现 `f_svg/src/SvgMarker.cj:151-185` 与 `f_svg/src/SvgMarkerExpander.cj:347-353`（`?? SvgLength(3.0)` / `?? SvgLength(0.0)`）
- **来源**：存量（快照模式无基线；`verification-2.md:70-73` 已记录该冲突的处理方式）
- **判据**：review-checklist §13「API / 默认值与源码不符」+ §11「契约与实现不符」
- **证据**：静态确定 —— Requirement 把四个属性定为 `?SvgLength`，「缺省 0 / 3」只能是使用处语义；Scenario 却断言解析后 `markerWidth == 3`、`refX == 0`。C7 明确要求「既有测试改为断言『缺失为 None、读取默认值走使用处』」，`verification-2.md:73` 记录 `SvgMarker_test.typeAndDefaults` 正是按 `None` 断言
- **描述**：同一份规格里「可为空」与「缺省 3/0」并列，Scenario 又用属性相等表达有效缺省值。照 Scenario 写用例必失败；照 Scenario 改实现则要破坏 C7 定下的公开契约（无法区分「缺失」与「显式 0」）
- **建议**：Scenario 拆两段——「属性读取为 `None`」+「渲染时按 `refX=0`、`refY=0`、`markerWidth=3`、`markerHeight=3` 生效」；Requirement `:9-11` 补一句「缺省值指使用处兜底值，属性本身保持 `None`」

### [一般][存量] `svg-filter` 平铺 Scenario 的「四角像素」断言在 2×2 tile / 6×6 区域下数学不成立

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-filter/spec.md:149-152`；周期定义 `:142`
- **来源**：存量
- **判据**：review-checklist §13「验收口径不成立」
- **证据**：静态确定 —— 周期 2 平铺到 6×6 时，四角坐标 `(0,0)`、`(5,0)`、`(0,5)`、`(5,5)` 对应 tile 相位 `(0,0)`、`(1,0)`、`(0,1)`、`(1,1)`，只有左上角与输入 `(0,0)` 同相位（`5 mod 2 = 1`）
- **描述**：断言只有输入四像素同色时才成立，而四像素同色的 tile 又无法区分「正确平铺」与「整块常量填充」，该 Scenario 既写错期望值又失去判别力。`fix-plan-2.md:57-62`（N3：4×4 输入、仅左上 2×2 不透明、断言周期为 4）才是能证伪的写法
- **建议**：改为「2×2 四色 tile，断言 `pixel(x,y) == pixel(x mod 2, y mod 2)` 对全部 36 像素成立」，或把区域改为 4×4 后逐点比对四相位

### [轻微][存量] `svg-security` 的「每条 warning SHALL 含可定位信息」未被滤镜链满足

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md:102`；反例 `f_svg/src/SvgFilterRenderer.cj:312`（`feGaussianBlur 的 stdDeviation 含负值，按 0 处理`）、`f_svg/src/SvgFilterRenderer.cj:345`（`feTile 的输入为空，输出透明`）、`f_svg/src/SvgFilterPrimitives.cj:352,357,364,369`（`feColorMatrix … 按直通处理`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现不一致」，属可审计性契约
- **证据**：静态确定 —— 上述 warning 只有原语名或数值，没有元素路径（`/svg[1]/...`）、`id` 或属性名；同文件 `:121` 的区域告警带 `元素「${filter.tag}」`，说明渲染器并非一律无定位信息，是原语分支漏加
- **描述**：条款写成对全部 warning 的绝对要求，而滤镜原语分支是 M3 新代码；调用方拿到 `SvgRenderer.warnings` 后无法定位到具体元素
- **建议**：要么把 `:102` 收窄为「按告警清单逐项要求定位信息」并列出例外，要么在 `runChain` / `apply` 统一给 warning 加 `filter` 元素路径前缀

### [轻微][存量] `stdDeviation` 负值条款在一个 SHALL 里给了两种互斥行为

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-value-types/spec.md:50`；消歧 Scenario `:70-73`；实现 `f_svg/src/SvgFilterRenderer.cj:311-314`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `:50` 写「负数 SHALL 取绝对值**或**回退为 0，并记 warning」，两种行为对 `stdDeviation="-1"` 给出不同像素结果（模糊半径 1 vs 不模糊）；`:72` 的 Scenario 定为「按 0 处理」，实现与 Scenario 一致（`max(0.0, sigma)`）
- **描述**：带「或」的 SHALL 等于没有约束；只读 Requirement 的实现者可能实现取绝对值，与 Scenario、实现、快照断言全部冲突
- **建议**：删除「取绝对值或」，直接写「负数 SHALL 按 0 处理并记 warning」

### [轻微][存量] 三份 fix-plan 引用的 `verify-report*.md` 均不存在，复验结论之间也没有前向指针

- **位置**：`f_svg/doc/spec/add-f-svg-m3/fix-plan.md:3`、`fix-plan-2.md:3`、`fix-plan-3.md:3`；对照 `verification-2.md:139-145`（结论 `CRITICAL=2`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— `find f_svg -iname "verify-report*"` 只命中 `add-f-svg-m6/verify-report{,-2,-3}.md` 与 `add-f-svg-m7/verify-report.md`；m3 目录下实际为 `verification.md`、`verification-2.md`、`verification-3.md`。`verification-2.md` 文首文末都未指向 `verification-3.md`，而 `fix-plan-3.md:3` 已按「CRITICAL=0」继续
- **描述**：修复计划的输入（CRITICAL 7 / WARNING 22、CRITICAL 2 / WARNING 5 等分级）无对应报告可查，第二轮与第三轮结论之间没有链接，第三方复核只能猜「哪份是最终裁定」
- **建议**：三处引用改成实际文件名；`verification-2.md` 顶部加一行「已被 `verification-3.md` 取代（CRITICAL=0）」

### [轻微][存量] `tasks.md` 对开发分支的约定自相矛盾

- **位置**：`f_svg/doc/spec/add-f-svg-m3/tasks.md:4`（「全部工作位于 `feature/f-svg-m3` 分支」）vs `:9`（「从当前 `f_svg` 工作分支切出」）vs `:183`（15.9「在 `feature/f_svg` 上分阶段提交（M3 与 M1/M2 同分支，无需额外合并）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「结论相反」
- **证据**：静态确定 —— 同一文件给出两种不兼容的执行方式（独立特性分支 vs 直接在 `feature/f_svg` 提交），首段规则与实际交付路径相反
- **描述**：M2 的 `tasks.md:4` 是同一模板，M3 复制后未改首段；按 `:4` 复核提交记录会误判「未按规范分支开发」
- **建议**：`:4` 改为 `feature/f_svg`，或删掉分支条款只保留「每阶段独立提交」

### [轻微][存量] M3 规格没有单一事实源：归档未完成、复核对象路径已消失，且同名 Requirement 在 m3 / m6 两份副本中已给出相反结论

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m3/tasks.md:184`（`- [ ] 15.10 归档本变更`，全文件唯一未勾选项）
  - `f_svg/doc/spec/add-f-svg-m3/verification-2.md:3`（复核对象写作 `openspec/changes/add-f-svg-m3/specs/*`、`openspec/specs/svg-*`）
  - `f_svg/doc/spec/add-f-svg-m3/fix-plan-2.md:80`（引用 `openspec/changes/add-f-svg-m3/specs/svg-render-pipeline/spec.md`）
  - 冲突面：`f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md:40-43`（`begin="click"` 动画「被忽略并记 warning」）vs `f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md:46-47`（「动画不活动，`fireEvent` 才触发」）
  - `f_svg/doc/spec/add-f-svg-m3/verification-2.md:90`（称 `svg-render-pipeline/spec.md:19`/`:34` 仍只写「透明占位」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 路径失效」+ §2「跨文件同语义规格副本」+ §14.1「规格未合并、索引未登记」
- **证据**：静态确定 ——
  1. `openspec/changes/` 只有 `add-f-a2a`；`openspec/changes/archive/` 只有 5 个 `2026-11-20-fix-*`；`openspec/specs/` 只有 5 个非 svg capability，**没有任何 `svg-*`**，上述两条复核对象路径全部不存在；
  2. 实现已按 m6 语义落地：`f_svg/src/SvgTimeline.cj:366` 提供 `public func fireEvent(animationId, event)`，`SvgAnimationControlM6_test.cj:93-115` 直接调用；m3 副本的「忽略并 warning」与当前行为不符；
  3. 两份 `svg-security/spec.md` 是同一 Requirement 集合的两个演进版本（m6 在 m3 文本上追加 provider 段落并改写事件语义），仓内无任何「以哪份为准」的声明；
  4. `verification-2.md:90` 的 W14 结论与本目录副本不符：`svg-render-pipeline/spec.md:19`/`:34` **已含**「设置 `SvgRenderOptions.background` 时按 M2 用背景色填充占位」，说明双副本在复核时已漂移；
  5. 同一副本的闭集清单也已过期：`svg-document-model/spec.md:33` 的「8 种 `fe*`」不含实现里已有的 `SvgFeDropShadow`（`f_svg/src/SvgFilterPrimitive.cj:300`、`f_svg/src/SvgTag.cj:43`）；
  6. 同类问题在 M2 已被记录且未收口：`add-f-svg-m2/verification.md:247-251`（W16 重复规格目录）、`:262`（SUGGESTION 6 要求统一单一事实源）。
- **描述**：每个里程碑各自维护一份「全量 Requirement 文本」，增量从未合并到主规格，归档任务也未执行。后果：(a) 同一 Requirement 有两套冲突验收口径，结论取决于读哪份；(b) 复核报告的输入不可达，`verification-2.md` 声明的对照范围无法复现；(c) `tasks.md:13.1`/`15.7` 把「按 `verification.md` §2.2 判定列记录」当作收口依据，而该判定列本身是在无主规格的前提下产生的
- **建议**：选定唯一事实源（建议 `openspec/specs/svg-*`，把 m3 的 ADDED/MODIFIED 合并进去），其余副本顶部加一句 supersede 指向；把 `verification-2.md:3`、`fix-plan-2.md:80` 的路径改为实际存在的位置；`tasks.md:15.10` 要么执行归档，要么改成显式「不归档，规格已合并到 X」

### [轻微][存量] `add-f-svg-m2/verification.md` 开头的「当前状态」与正文结论矛盾且已过期

- **位置**：`f_svg/doc/spec/add-f-svg-m2/verification.md:6`（`cjpm test 341/341`、`CRITICAL = 0`）vs `:9`（`330 / 330`）vs `:328`（`341 / 341`）vs `:334`（第二轮又新增 `N1–N3（CRITICAL）`）vs `:348,363`（最终 `346`、`348 / 348`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 结论相反」
- **证据**：静态确定 —— 同一 §0 内 341 与 330 并存；§0 宣称 `CRITICAL = 0`，而 §7 记录第一轮之后又发现 3 个 CRITICAL；最终数字 348 只出现在文末
- **描述**：这份 366 行报告是「归档后校验」入口，读者通常只读 §0，会误判 M2 的最终质量门
- **建议**：§0 改为「最终状态：348/348，CRITICAL=0（含第二轮 N1–N3、第三轮 W1–W2 的修复）」，历史数字移入对应小节

### [轻微][存量] 「圆 vs 4× 超采样差 ≤ 2/255」旧判据仍留在任务表与设计文档

- **位置**：`f_svg/doc/spec/add-f-svg-m3/tasks.md:146`（12.2，已勾选）、`f_svg/doc/spec/add-f-svg-m3/design.md:206`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `specs/svg-rasterization/spec.md:53` 明确「4× 点采样自身的量化误差可达约 `15/255`，不得作为 `2/255` 的判据」，`fix-plan-2.md:32-33` 也要求基准改为 64×；两处旧表述未随 spec 同步
- **描述**：任务记录声称的验收标准比现行规格松 7 倍以上，按任务表复核会得出「已达标」的错误结论
- **建议**：`tasks.md:12.2` 改为「圆对 64× 参考图逐像素 ≤ 2/255」，`design.md:206` 同步；若要保留历史，标注「已被 fix-plan-2 C6 取代」

<!-- 第 4 部分 -->

### [一般][存量] #1 `screenCTM` 的矩阵顺序在 delta spec 与 design 里都写反了，且唯一 Scenario 用均匀缩放，天然发现不了顺序错误

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md:68`（"SHALL 等于 `ctm(element) × viewport.matrix × scale(devicePixelRatio)`"）
  - 同文件 `:70-73`（Scenario：100×100 文档、`viewBox="0 0 50 50"`、`dpr=2`、用户坐标 `(10,10)` → `(40,40)`）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:170`（同一公式）
  - 修正要求：`f_svg/doc/spec/add-f-svg-m4/fix-plan.md:20-26`（C2："当前 `ctm × viewport × scale(dpr)`；渲染器顺序为 `scale(dpr) × viewport × ctm` … 同步修正 design D9 公式"）
  - 对照实现：`f_svg/src/SvgGeometry.cj:243-257`（注释与代码均为 `scale(dpr) → viewport.matrix → ctm`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「规格与实现漂移」；§11「契约与实现不符」
- **证据**：静态确定 —— 实现 `SvgMatrix.scale(dpr,dpr).multiply(viewport.matrix).multiply(ctm(...))`，`:243` 的注释明写"与渲染器的设备矩阵顺序一致"；`fix-plan.md` C2 已判定旧顺序错误并要求改设计，`tasks.md:143`（18.4）也只声称同步了 `doc/f_svg-M4设计.md`，`design.md:170` 与本 delta spec `:68` 都还留着旧公式。
- **描述**：按文档实现，`<g transform="translate(10,10)">` + `viewBox` 缩放 + `dpr=2` 会把 `(0,0)` 映射到 `(10,10)`，渲染器实际画在 `(40,40)`；调用方用 `screenCTM` 做命中测试或坐标换算会整体错位。错误能存活，是因为 Scenario（`:70-73`）里三个因子都是均匀缩放、彼此可交换，两种顺序同为 `(40,40)`，测试与文档"互相印证"了错误的公式。
- **建议**：`spec.md:68` 与 `design.md:170` 统一改为 `scale(devicePixelRatio) × viewport.matrix × ctm(element)`；Scenario 增加带平移的非均匀用例（C2 的 `translate(10,10)` + meet + `dpr=2` → `(40,40)`，并断言无 transform 时等于 `ctm`），使顺序错误可被用例直接打死。

### [一般][存量] #2 兼容性契约声称"唯一会改变既有输出的点是 marker 裁剪"，漏掉 `switch` 由"渲染全部子元素"改为"只选第一个满足者"

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/design.md:90`（"这是 M4 唯一会改变既有输出的点：只有内容越出 marker 视口的文档受影响"）
  - 同文件 `:205`（"唯一条件性差异是越出 marker 视口的内容按 SVG 1.1 被裁剪"）
  - `f_svg/doc/spec/add-f-svg-m4/proposal.md:74-75`（兼容性段同样只写 `overflow`）
  - 对照：`f_svg/doc/spec/add-f-svg-m4/tasks.md:141`（18.2 要求 README 写入"`switch` 的条件性输出差异"）、`fix-plan-2.md:58-60`（W9-2 要求"补上『`switch` 由遍历全部子元素改为选第一个满足条件者』"）
  - 实现：`f_svg/src/SvgRenderTree.cj:771`（`SvgSwitch.select` 只分派一个子元素）；`f_svg/src/SvgTag.cj:69`（`switch` 与 `g` / `symbol` 等一起映射为 `SvgContainer`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与实现/README 不一致」；§14.1「只做了一半的分支」；§11「契约与实现不符」
- **证据**：静态确定 —— `switch` 在 M4 之前已是已知容器（`git log -S '"switch"' -- f_svg/src/SvgTag.cj` 指向初始解析器提交 `2ead235b0`，当前 `:69` 仍把它归入容器分支），子树按普通容器全量遍历；M4 改为 `SvgSwitch.select` 只保留第一个满足条件的子元素。含多个合法分支的 `<switch>` 文档输出必然改变，与"唯一差异"直接冲突；`tasks.md:141` 与 `fix-plan-2.md` 都把这条列为需披露的输出差异。（`design.md:7` 的"新增标签前落入 `SvgUnknownElement`"只针对 `view` 与 15 个 `fe*`，不能用来解释 `switch`。）
- **描述**：兼容性声明少列一条真实的行为变化，会让依赖"M4 只影响越界 marker"的下游放心升级，实际却丢掉 `<switch>` 的其余分支（典型用法正是语言/特性回退列表）。
- **建议**：`design.md:90` / `:205` 与 `proposal.md:74-75` 改为两条差异：①越出 marker 视口的内容被裁剪；②`switch` 由"全部子元素参与渲染"改为"只选第一个满足条件者"。README 侧同时把 `README.md:107` 的能力描述标注为与 M3 的输出差异。

### [一般][存量] #3 三个文本基线属性被写成"可继承、按 spec"，但 SVG 1.1 属性索引三者 Inherited 均为 no；`overflow` 初始值偏离也只在 design 承认、spec 未标注

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/design.md:68`（"继承性按 spec：`dominant-baseline` / `alignment-baseline` / `baseline-shift` / `writing-mode` 可继承"）
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-css/spec.md:12-13`（`dominant-baseline` / `alignment-baseline` 可继承、初始 `auto`；`baseline-shift` 可继承、初始 `baseline`）
  - 同文件 `:10`（`overflow` 初始 `hidden`）；`design.md:69`（承认这是对 SVG 1.1 UA 样式表的简化）
  - 实现：`f_svg/src/SvgComputedStyle.cj:119-121`（三者 `SvgPropertySpec(name, true, …)`，`true` = 可继承）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「关键段落缺失」；§11「契约与实现不符」；外部判据：W3C SVG 1.1 (2nd ed.) Appendix N Property Index——`dominant-baseline`、`alignment-baseline`、`baseline-shift` 的 Inherited 列均为 **no**，`writing-mode` 为 **yes**
- **证据**：静态确定 —— 官方属性索引与 `design.md:68` 的"按 spec"相反；实现与文档一致（都按可继承），因此这是**把偏差说成合规**的文档问题，而非实现漏改。`overflow`：SVG 1.1 初始值为 `visible`（viewport 元素由 UA 样式表给 `hidden`），`design.md:69` 已承认模块把初值定为 `hidden`，但 `svg-css/spec.md:10` 直接以规范口吻写"初始 `hidden`"，未标注偏离。
- **描述**：`<g dominant-baseline="middle">` 下所有后代文本都会继承中线，`<text baseline-shift="sub">` 内的 `<tspan>` 也会继承下移；浏览器与 SVG 1.1 只对显式声明该属性的元素生效，同一文档在本模块与其他渲染器上会出现整段文本上下错位。`overflow` 的取舍本身合理（`design.md:69` 给了理由），问题只在 spec 没把它写成"本模块偏离"。
- **建议**：二选一并同步三处：①贴合 SVG 1.1：`SvgComputedStyle.cj:119-121` 改 `false`，`svg-css/spec.md:12-13` 与 `design.md:68` 改为"不可继承，初始 `auto` / `baseline`"，补"嵌套 tspan 不继承基线"用例；②保留可继承：把 `design.md:68` 的"按 spec"改为"本模块选择可继承（偏离 SVG 1.1）"，并在 `svg-css/spec.md` 增"与 SVG 1.1 的差异"段。`overflow` 同样在 `:10` 补一句"模块初值 `hidden`，`initial` 亦得 `hidden`，与 SVG 1.1 的 `visible` 不同（理由见 design D1）"。

### [一般][存量] #4 `mathematical` 基线被 spec 定义为"x-height 中线"，设计与实现取 `-0.5 × ascent`，按 spec 字面无法验收

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md:7`（"`mathematical` 为 x-height 中线"）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:143`（基线表 `mathematical | -0.5A`）；同文件 `:220`（"基线表无 x-height 度量 … `mathematical` 取 `-0.5A`，在文档中写明近似"）
  - 实现：`f_svg/src/SvgTextBaseline.cj:235`（`case Mathematical => -0.5 * ascent`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「条款不能用」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— M4 设计自述 `SvgFont` 只有 `ascent` / `descent`（`design.md:13`），实现取 `-0.5A`；当前 `SvgTrueTypeFont` 已有 `OS/2.sxHeight`（`SvgTrueTypeFont.cj:116-117` 的 `xHeightValue`），但 `SvgTextBaseline.offset` 的签名只收 `ascent` / `descent` / `fontSize`（`:224-238`），x-height 至今没有进入基线表。`svg-text/spec.md:16-19` 的"无字体度量的回退"Scenario 也不覆盖 `mathematical`，没有用例能暴露该差异。
- **描述**：验收方按 spec 写"取 x-height 中线"的期望值必然失败；按实现写又无法从 spec 推出 `-0.5A`。这是"规格给了当前没有落地路径的口径"，会让后续对齐 SVG 2 的改造缺少依据。
- **建议**：把 `spec.md:7` 改为可执行口径（"取 ascent 中线，即 `-0.5 × ascent`；无 x-height 度量时的确定性近似"），并在 Scenario 增加 `mathematical` 的 y 值断言与相对 `middle` 的次序；若要真按 x-height，`SvgTrueTypeFont.xHeightValue` 已可用，需把它接进 `SvgTextBaseline.offset` 的参数并给 Hershey 回退值。

### [一般][存量] #5 路径长度 API 没有点数/段数预算，小体积 `d` 可放大出大段表，且每次调用整体重建

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md:7-11`（只规定"按容差离散为折线"，无点数/段数/内存上限）
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:7-13`（M4 上限表不含路径测量）
  - 实现：`f_svg/src/SvgPathMeasure.cj:66-103`（`buildSegments` 全量物化 `SvgMeasuredSegment`）、`:105-112`（`totalLength` 每次重建整表）、`:145`（`pointAt` 同样依赖段表）；`f_svg/src/SvgRasterizer.cj:692-706`（`subdivideCubic` 出口 `depth >= 16 || 平坦度 ≤ 容差`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「一次性物化 / 递归 + 每层分配 / 无界容器」；§11「缺少边界校验」
- **证据**：静态确定（结构）+ 需实测（峰值内存）—— 单条三次曲线最多 2^16 = 65536 个点（`depth` 封顶 16），每点 2 个 `Float64`，段表每段 6 个 `Float64`（48 B）；`buildSegments` 在 `refine=true` 时把容差再乘 0.05，进一步加深细分。命令数只受 `d` 文本长度限制，`SvgSecurityOptions.maxElements` 不约束单条 `d` 的命令数，`textPath` 渲染与公开 `totalLength` / `pointAtLength` 共用这条路径。
- **描述**：最坏情况下一条三次曲线可产出 65536 段、段表约 3 MiB（另有约 1 MiB 折线点）；1 KiB 的 `d`（数十条曲线）可达上百 MiB，16 KiB 级 `d` 可到 GB 级。公开 API 每次调用都重建整表，重复调用还会放大分配与 CPU；当前没有任何拒绝路径，只在 OOM 时暴露。
- **建议**：给 `buildSegments` 增加"最大点数/最大段数"预算常量，累计后超限抛 `SvgException(kind: Limit)`（在分配前判定）；把该上限登记到 `svg-security` 的 M4 上限表并补负向 Scenario（`d` 含大量高阶曲线 + 小容差 → `Limit`）。同时可让 `totalLength` 与 `pointAtLength` 复用一次段表（接口层缓存或调用方持有），避免每次重建。

### [一般][存量] #6 `feTurbulence` 的 `stitchTiles` 只有模型读写，渲染完全忽略，规格也未声明该限制

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md:92`（"SHALL 提供 … `stitchTiles`（`noStitch` 缺省 / `stitch`）"）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:106-117`（D5 湍流算法全篇未提 `stitchTiles`）
  - 实现：`f_svg/src/SvgFilterPrimitives2.cj:689-703`（只做属性字符串互转）、`:1172-1180`（`turbulenceFilterBuffer` 签名不含 stitch）、`f_svg/src/SvgFilterRenderer.cj:357`（唯一调用点同样不传）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.1「配置项被读取却从未使用（接线缺失）」；§11「语义与命名不符」；§3「承诺有行为、实现为空」
- **证据**：静态确定 —— 全仓 `stitchTiles` 只出现在 getter/setter、`SvgBuilder.cj:577` 的值白名单与模型/往返测试中；`turbulenceFilterBuffer` 只消费 `seed` / `numOctaves` / `baseFrequency` / type，没有任何平铺拼接分支；spec 也没有为它写 Scenario，`tasks.md:50` 的湍流用例只覆盖两类噪声、seed、`baseFrequency`、`numOctaves`。
- **描述**：`stitchTiles="stitch"` 被解析、保存、写回，但对渲染没有任何影响，也没有 warning，属"静默无效的公开属性"。默认 `noStitch` 与实现一致，默认输出不受影响；但对需要无缝平铺的素材，调用方会误以为库已支持拼接。
- **建议**：二选一——(a) 在 `svg-filter` 明确"`stitchTiles` 仅为模型属性，渲染按 `noStitch` 处理"，并在渲染入口对 `stitch` 追加一次性 warning；(b) 实现周期化噪声（按滤镜区域取整频率，使相邻 tile 连续），补"同 seed、`stitch` 下左右 tile 边界连续"的像素用例，并在 `svg-security` 记录成本。

### [一般][存量] #7 `tasks.md` 把 `openspec validate --strict` 记为"已运行并通过"，同一处备注又说本机无 CLI，`fix-plan-3.md` 也称通过

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/tasks.md:145`（"`[x]` 运行 `openspec validate add-f-svg-m4 --strict`（通过）"）、`:146`（"本机无 `openspec` CLI，CLI 校验在具备环境的归档流程中补跑"）
  - `f_svg/doc/spec/add-f-svg-m4/fix-plan-3.md:11`（"`openspec validate add-f-svg-m4 --strict` 通过"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论相反」；§11「错误处理缺失或静默」（验收证据失真）
- **证据**：静态确定 —— 同一门禁同时存在"已通过"与"无法执行"两种状态；`fix-plan-3.md` 声明通过，`tasks.md:146` 声明 CLI 不存在。`openspec` 目前只剩 `add-f-a2a` 与 5 个 `2026-11-20-fix-*` 归档，无法补跑 `add-f-svg-m4`（变更目录已不在）。
- **描述**：归档复核无法判断 `--strict` 到底有没有跑过；"通过"作为验收证据不成立，另一处又称"人工逐条核对通过"，两者不可互相替代（人工核对不能证明 schema/格式合规）。
- **建议**：`tasks.md:145` 改为"主流程人工逐条核对 Requirement/Scenario（通过）；`openspec validate --strict` 因本机无 CLI 未执行，标记为待补"，并删除 `:146` 与 `fix-plan-3.md:11` 的"通过"表述；若确有执行记录，补上时间与命令输出。

### [轻微][存量] #8 `SvgTrueTypeFont.load(path)` 整文件物化，规格未给字体文件字节上限

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:44`（上限为表数 64、单表 16 MiB、点数 10000、复合深度 8，均为"读取表数据前"检查）、`:74`（"`load` 只读取传入路径 … 安全责任由调用方承担"）
  - 实现：`f_svg/src/SvgTrueTypeFont.cj:330-337`（`load` → `SvgFontFileAccess.read` → `parse(bytes)`）、`:29-34`（`File.readFrom(path)` 直接整文件读入）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「一次性物化 / 按不可信长度物化」；§14「承诺与实现不符」
- **证据**：静态确定 —— `File.readFrom` 在表级上限执行之前就把整个文件读成 `Array<Byte>`，规格与实现都没有文件字节上限；M3 的 `SvgPngDecoder.decode(stream)` 有 64 MiB 流上限，字体路径没有对应项。
- **描述**：调用方把数 GiB 的"字体"传给公开入口时，进程先按文件大小整体物化，再进入表校验；表级上限无法防住这一层。由于 `svg-security:74` 明确把责任划给调用方、渲染链路也从不调用 `load`，本项按健壮性缺口处理，不定为安全漏洞。
- **建议**：在 `svg-security` 的 TTF 上限表补"字体文件字节数 ≤ N（建议与 base64 上限 32 MiB 对齐）"，在 `SvgFontFileAccess.read` 读取前按文件长度判定、超限抛 `SvgException(kind: Limit)`；`parse(bytes)` 入口做同一校验以覆盖内存来源。

### [轻微][存量] #9 `tasks.md` 点名的 12 个测试文件不存在：8 个实际带 `M4` 后缀，4 个没有任何同名文件

- **位置**（均为 `f_svg/doc/spec/add-f-svg-m4/tasks.md`）：
  - `:26` `SvgClipProperty_test.cj`、`:30` `SvgVectorEffect_test.cj`、`:42` `SvgFilterPrimitives2_test.cj`、`:57` `SvgFilterLighting_test.cj`、`:71` `SvgTextBaseline_test.cj`、`:78` `SvgTextDecoration_test.cj`、`:84` `SvgTextWritingMode_test.cj`、`:98` `SvgTrueTypeFont_test.cj` —— 实际为 `src/{SvgClipProperty,SvgVectorEffect,SvgFilterPrimitives2,SvgFilterLighting,SvgTextBaseline,SvgTextDecoration,SvgTextWritingMode,TrueType}M4_test.cj`
  - `:107` `SvgView_test.cj`、`:110` `SvgSwitch_test.cj`、`:112` `SvgAnchor_test.cj`、`:117` `SvgPathMeasure_test.cj` —— 仓内没有任何同名文件
- **来源**：存量（`git log --all -- f_svg/src/<name>` 对这 12 个名字均为 0 条提交；`SvgDocumentApiM4_test.cj` 等有 M4 期提交，说明查询方式有效）
- **判据**：review-checklist §13「链接 / 路径失效」；§14.1「任务勾选与证据不符」
- **证据**：静态确定 —— 逐个 `ls` 均 MISSING；`grep -o "[A-Za-z0-9]*_test\.cj" tasks.md` 共 15 个名字，只有 `SvgScene_test.cj`、`SvgTrueTypeTables_test.cj`、`SvgValueTypesM4_test.cj` 对得上。`SvgView` / `SvgSwitch` / `SvgAnchor` 的覆盖在 `SvgDocumentApiM4_test.cj`（含 `SvgSwitchM4_test` 类、`views()` / `anchors()` 断言），`SvgPathMeasure` 在 `SvgGeometryApiM4_test.cj` 与 `SvgBenchmarkM4_test.cj`；功能未缺失，只是落点不可核对。
- **描述**：18 节任务除 18.8 全部勾 `[x]`，勾选依据是"先写 `X_test.cj`"；按文档复核会找不到文件，无法判断 Red 阶段是否真的存在。`fix-plan.md:73` 的 W1 正是"复核 tasks 勾选：无证据的项改为 `[ ]` 或补用例后勾选"，tasks 里没有留下复核痕迹。
- **建议**：把 12 处名字改成实际文件（8 个补 `M4` 后缀），4 个改成真实落点；或在每节备注写"用例落在 X 文件 Y 方法"，让勾选可机械复核。

### [轻微][存量] #10 交叉引用失效：`verify-report*.md` 共 4 处、`design.md` 引用自身不存在的"§8"、归档后的 `openspec/changes|specs` 路径不可达

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/fix-plan.md:3`（`verify-report.md`）、`fix-plan-2.md:3`（`verify-report-2.md`）、`fix-plan-3.md:3`（`verify-report-3.md`）
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:9`（"见 `verification-2.md`、`verify-report-3.md`"，实际是 `verification-3.md`）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:226`（"实施顺序按设计文档 §8"；本文件无编号章节）
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:3`、`verification-3.md:3`（"校验对象"整段指向 `openspec/changes/add-f-svg-m3/**` 与 `openspec/specs/svg-*`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「链接 / 路径失效」「关键段落缺失」
- **证据**：静态确定 —— `find openspec f_svg/doc -name "*verify-report*"` 为空，`add-f-svg-m4/` 下实际是 `verification.md` / `-2` / `-3` / `-4`；`openspec/changes` 只有 `add-f-a2a` 与 5 个 `2026-11-20-fix-*`，`openspec/specs` 无任何 `svg-*`。`design.md` 标题为 Context / Goals / 架构 / Decisions / 关键契约 / Risks / Migration Plan / 假设，没有 §8；`tasks.md:12` 用的是完整文件名 `f_svg/doc/f_svg-M4设计.md`。
- **描述**：每份修复计划第一行的"依据"都指向不存在的文件，复验链断在第一跳；M3 报告的"规格来源"与"主规格对照"两栏也不可达。归档变更引用原件在历史上可理解，但当前读者无法据此复核，且同一问题在 M3/M4 两个目录重复出现。
- **建议**：4 处统一改为 `verification*.md`；`design.md:226` 写全路径与真实小节号（或改为"按 `f_svg/doc/f_svg-M4设计.md` §8"）；两份 M3 报告把"校验对象"改为 `f_svg/doc/spec/**` 相对路径，并在顶部标注"归档副本，openspec 原件已迁出"。

### [轻微][存量] #11 `verification.md` 有两个 `## 6`、3 个 `CRITICAL=0` 标记，§0 还自引用本文件

- **位置**：`f_svg/doc/spec/add-f-svg-m3/verification.md:515`（`## 6. 首轮校验说明（历史…）`）、`:523`（`## 6. 修复结果（本轮）`）、`:521`（`CRITICAL=7（首轮结论…）`）、`:569` / `:604` / `:632`（`CRITICAL=0`）、`:11`（"与 `verification.md` 的 466 一致"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「关键段落缺失 / 结构失效」；§10 可读性
- **证据**：静态确定 —— 同一文件出现两个编号 6，`§0:9` 又写"见 §6、§7"，指代不明；`CRITICAL=` 是流水线 grep 标记，取第一条会得到与结论相反的 `CRITICAL=7`；`:11` 在 `verification.md` 内引用"`verification.md`"，属自引用笔误。
- **描述**：多轮修复记录叠加在同一文件，结构与机器标记未收敛，归档复核容易误读为"结论反复"。最后一段结论（533 全绿、CRITICAL=0）本身正确。
- **建议**：第二个 `## 6` 改为 `## 7. 修复结果（第一轮）` 并顺延后续编号，同步"见 §6、§7"的引用；机器标记只保留文件末尾一条，历史结论改为表格行；`:11` 改为"与首轮基线（本文件 §0）一致"。

### [轻微][存量] #12 W15 标题写"21 个 Scenario 仅部分覆盖"，与 §2.1/§2.2 的 14 不一致

- **位置**：`f_svg/doc/spec/add-f-svg-m3/verification.md:403`（W15 标题"21 个 Scenario"）；同文件 `:51`（§2.1 合计"部分 14"）、`:57-171`（§2.2 判定列，14 行"部分"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论相反」
- **证据**：静态确定 —— §2.2 的"部分"行逐个数为 14（`:68,69,76,77,89,95,104,125,128,131,134,141,155,168`），与 §2.1 的 14 一致；W15 正文列 10 组、按条目数为 20，与标题 21 和 §2.1 的 14 三者互不相同。文档没有说明统计粒度（Scenario 数 vs 缺口方面数），21 是首轮结论（§0:15 已标为历史）。同类的还有 §0:15 的"失败 2 个"与 §2.1 的"失败 0"，也只靠 `§0:9` 一句"历史结论"区分。
- **描述**：W15 作为"剩余缺口"的汇总入口给出第三个数，复核者无法判断 21 个缺口是否都已处置，也无法用计数反推哪些 Scenario 仍只部分覆盖。
- **建议**：统一粒度并写明口径，例如"14 个 Scenario 仅部分覆盖（与 §2.2 判定列一致），共 20 个缺口方面（见下列 10 组）"，删除与 §2.2 重复的罗列；§0 的 21 保留但明确标注"首轮数字"。

### [轻微][存量] #13 W17 的最终状态在两份 M3 报告里相反：`verification.md` 记"已修复"，`verification-3.md` 记"部分落地"

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:586`（`| W17 | 已修复 | …`）
  - `f_svg/doc/spec/add-f-svg-m3/verification-3.md:17`（"W17 | **部分落地** … `openspec/changes` 副本仍是旧文本，见 NEW-W2"）、`:157-162`（NEW-W2 具体说明）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」；§11「与规格冲突」
- **证据**：静态确定 —— 同一变更的两份终验文档对同一条目给出相反状态；`verification.md` §7 的修复表没有记录"openspec 副本"这一半，`verification-3.md` §1 把它列为未落地并给出具体行号。`openspec/changes/add-f-svg-m3/` 现已不存在，残留既无法复核也无法修复。
- **描述**：归档结论同时存在"已修复"与"部分落地"，读者无法判断 W17 是否闭环；结合 #11 的重复编号，`verification.md` §7 看起来像最终结论，实际被 `verification-3.md` 推翻。
- **建议**：以 `verification-3.md` 为准，把 `verification.md:586` 改为"已修复（`f_svg/doc` 副本）；`openspec/changes` 副本随归档删除，不再适用"，并在 §7 表下注明"最终状态以 `verification-3.md` §1 为准"。

### [轻微][存量] #14 `design.md` 对新增滤镜原语给出三种计数口径（15 标签 / 11 类+光照 / 7 个分派），实际分派为 8 个

- **位置**：`f_svg/doc/spec/add-f-svg-m4/design.md:7`（"15 个新 `fe*` 标签"）、`:56`（架构图"11 类原语+光照"）、`:110`（"`runPrimitive` 增加 7 个分派"）、`:108-109`（列出 6 + 2 = 8 个原语）；对照 `proposal.md:7`（"7 类滤镜原语"）与实现 `f_svg/src/SvgFilterRenderer.cj:350-366`（8 个 case）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论不一致」；§2「同一口径两处不一致」
- **证据**：静态确定 —— 8 个原语 case 分别为 `SvgFeComponentTransfer` / `Morphology` / `ConvolveMatrix` / `Turbulence` / `DisplacementMap` / `Image` / `DiffuseLighting` / `SpecularLighting`；"7 个分派"把两种光照合为一类但未说明；"11 类原语+光照"与 M3 的 8 个原语 + M4 的 8 个也对不上。
- **描述**：三处计数无法互推，按设计核对"新原语是否全部接线"时得不到唯一清单（实际 8 个均已注册）。这不是行为缺陷，但会削弱自检。
- **建议**：统一为"新增 8 个原语元素 / 15 个新标签 / 7 个原语类别（两种光照合为一类）"，`:56` 的架构图改为"滤镜原语（M3 8 + M4 8）"。

### [轻微][存量] #15 `textPath side="left"` 的"左移"与同一规格 Scenario 的"向下偏移 10"方向矛盾，实现与测试都取 +y（向下）

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md:112`（"`side="left"` SHALL 让字形沿路径法线**左移** `0.5 × fontSize`"）与 `:118-121`（Scenario 复述"沿路径法线左移 10"）
  - 同文件 `:221-224`（MODIFIED Scenario：同一输入"水平路径、`side="left"`、字号 20" → "字形中心相对路径**向下**偏移 10"）
  - 实现：`f_svg/src/SvgTextPathLayout.cj:147-156`（`Left` 取 `+sideOffset`，法线 `(-sin θ, cos θ)`；θ=0 时为 `(0,+1)`）；测试 `f_svg/src/SvgTextPathExtensionM4_test.cj:63-72`（断言 `left[0].originY == 10`、`right[0].originY == -10`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「条款不能用」；§10 可读性
- **证据**：静态确定 —— 同一 ADDED Requirement 的正文与 Scenario 给出"左移"，MODIFIED Scenario 与实现/测试给出"向下"；在 y 向下的用户坐标系里，沿 +x 前进的"左"是 `-y`，两组描述至少有一组是笔误。偏移量（10）两侧一致，只有方向冲突。
- **描述**：验收方按正文写"上方偏移"会失败，按 MODIFIED Scenario 写"下方偏移"会通过；后续若与 SVG 2 的 `side` 语义对齐，现有测试会挡住改动。当前像素结果由实现与测试共同锁定，属契约精度问题而非行为缺陷。
- **建议**：明确写出法线方向而不使用"左/右"这种相对词，例如"按实现取 `n = (-sin θ, cos θ)`，`side="left"` 为 `+n`、`right` 为 `-n`，水平路径即向下/向上"，并让 `:112`、`:121`、`:224` 用同一句话；若目标是与 SVG 2 一致（水平路径的 `left` 在上方），需同时改实现与测试，并在兼容性说明中标注。

<!-- 第 5 部分 -->

### [一般][存量] `calc()` 的「百分比与绝对长度混用无效」条款与本变更的 fix-plan、实现三方冲突

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md:268`（「混合百分比与绝对长度 SHALL 使表达式无效」）、`:292-295`（Scenario「混合单位无效」期望回退初始值 1）；`f_svg/doc/spec/add-f-svg-m5/design.md:64`；对照 `f_svg/doc/spec/add-f-svg-m5/fix-plan.md:39`、`fix-plan-2.md:31`
- **来源**：存量（快照模式无基线；`git blame` 不可用于历史结论）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `SvgStyleResolver.cj:503-512` 为 `x` / `width` / `cx` / `rx`（宽度）与 `y` / `height` / `cy` / `ry`（高度）、`r`（宽高均值）提供百分比参考值；`CssCalc.cj:232-236` 在有参考值时把 `%` 直接换算为绝对长度，`combineCssCalcAdd` 因此接受 `10% + 5px`。`fix-plan.md:39` 的用例 `x: calc(10% + 5px)`、200 宽视口 → 25，正是要求混用可用。
- **描述**：规格把「混合无效」写成无条件 SHALL，但实现按属性分两类：几何长度属性（9 个）把 `%` 解析为视口比例后允许与 `px` 相加；`stroke-width` / `letter-spacing` / `word-spacing` / `stroke-dashoffset` 没有参考值，仍按「混用无效」处理。照规格实现会拒掉 fix-plan 明确要求支持的 `x` / `width` 写法；照实现写用例又与 Requirement 冲突。Scenario `:292-295` 只在非几何属性上成立，规格却未限定范围。
- **建议**：把 `:268` 改为「同一表达式中的 `%` 与绝对长度 SHALL 先按参考盒换算（几何长度属性用视口宽高，其余属性视为无效）」，并把 `:292-295` 的 Scenario 限定为 `stroke-width`；`design.md:64` 同步。

### [一般][存量] `svg-geometry` 的元素级 API 签名少了 `mediaWidth` / `mediaHeight`，且未说明缺省 300×150 的语义

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md:7`（`getBBox(options!: SvgBBoxOptions = SvgBBoxOptions()): ?SvgBounds`）、`:66-68`（`getCTM(): SvgMatrix`、`getScreenCTM(viewport!: ?SvgViewportTransform = None)`）；实现 `f_svg/src/SvgElement.cj:452-456`、`:477-480`、`:485-491`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」、§14「公开 API 未文档化」
- **证据**：静态确定 —— 三个公开方法都带 `mediaWidth!: ?Float64 = None` 与 `mediaHeight!: ?Float64 = None`；`getBBox` 在两者为 `None` 时固定按 `300 × 150` 计算样式与百分比几何（`SvgElement.cj:457-461`），`SvgElementApi.cj:304-343` 同构。
- **描述**：`@media` 与百分比几何都依赖媒体宽度，而规格正文只给无参签名。调用方按规格文档调用时，样式按 300×150 求值，与 `render(options.width: 800)` 的结果不一致；这正是 `fix-plan-2.md:35`（N10）要求补进文档的签名差异，但只落到 README，delta spec 未更新。
- **建议**：在 `:7` / `:66` 补可选具名参数，并新增一条「未提供媒体宽度时 SHALL 按 300×150 求值，与渲染入口可能不同」的 Scenario。

### [一般][存量] `svg-text` 的字体别名「区分 font-weight / font-style」条款无对应实现

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md:189`、Scenario `:196-199`；实现 `f_svg/src/SvgFont.cj:96-131`；`f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md:41`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」
- **证据**：静态确定 —— `SvgFontRegistry.derived` 只建立 `family → family` 的 `aliases` 映射，`rule.weight` / `rule.style` 在 `SvgFont.cj:96-131` 内没有任何读取；`CssFontFaceRule` 虽保留这两个字段（`CssStyleSheet.cj:103-104`），全仓无消费点。`fix-plan-2.md:41` 已把「`@font-face` 的 weight/style 限定」记为「M6 处理」。
- **描述**：Requirement 写「别名 SHALL 区分 `font-weight` / `font-style`」，但实现里别名与字重、字形无关。Scenario「权重回退」之所以能过，是因为 `resolveDetailed` 在 family 内自带 `normal/normal` 回退（`SvgFont.cj:198-206`），与别名是否区分无关——用例通过不能证明条款成立。按规格验收会得出「已实现」的错误结论。
- **建议**：要么把该句降级为「别名按 family 映射；字重 / 字形回退沿用既有 family 内回退」，并删除 `:196-199` 的 Scenario 或改成「别名目标只有 normal 时按 family 内回退取 normal」；要么在 M6 实现 face 级别名并保留条款。

### [一般][存量] `@font-face` 的 `src` 在同一条 Requirement 里既「决定别名目标」又「被忽略并告警」，实现告警文案与行为相反

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md:212`（目标取自 `src: local(<family>)`）与 `:214`（`src` 被忽略、追加 warning 且不加载文件）；实现 `f_svg/src/CssStyleSheet.cj:348`；`design.md:70`、`:76`；`proposal.md:23`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与命名 / 注释不符」
- **证据**：静态确定 —— 实现把 `src` 原文保留在 `CssFontFaceRule.src`（`CssStyleSheet.cj:107`），`SvgFont.cj:106-117` 用其中的 `local()` 选目标 family；同时解析阶段固定追加「已忽略 @font-face 的 src（不加载字体文件）：<原文>」（`CssStyleSheet.cj:348`）。`design.md:70` 的 `CssFontFaceRule(family, weight, style, srcPresent)` 字段表仍无 `src`，`:76` 与 `proposal.md:23` 仍写「src 忽略并记 warning」。
- **描述**：`src: local(Brand)` 实际生效时，日志仍声称「已忽略」，使用者会误判别名没生效而反复排查；规格同一 Requirement 的两段互相否定，实现只能同时满足字面（告警）与语义（使用）中的一半。这是 `fix-plan-2.md:13-16`（N1）引入 `local()` 后未回收旧文案与旧设计决策的残留。
- **建议**：`src` 有 `local()` 命中时不告警；仅对 `url(...)` 或无法解析的 `src` 记「不加载文件」。规格 `:214` 改为「`url(...)` 与其余声明 SHALL 被忽略并记 warning」，`design.md:70,76` 与 `proposal.md:23` 同步 `src` 字段与 `local()` 语义。

### [轻微][存量] `svg-value-types` 把 `paint-order` 的两条 Scenario 混进「混合模式枚举」Requirement 并原样重复

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-value-types/spec.md:16-24`（`M5 混合模式枚举` 下的「绘制顺序解析」「重复项去重」）与 `:42-50`（`M5 绘制顺序值类型` 下同名同文）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「重复逻辑（字面量复制）」、§13「规格与实现漂移」
- **证据**：静态确定 —— 两处 Scenario 的 WHEN/THEN 文本逐字相同（`paint-order="stroke fill"`、`paint-order="fill stroke fill"`），前者挂在只讨论 `SvgMixBlendMode` 的 Requirement 下，后者才属于 `SvgPaintOrder`。
- **描述**：`paint-order` 行为被记在混合模式 Requirement 名下，Requirement → Scenario 的对应关系错位；同时 Scenario 计数被虚增 2 条，而该计数是本变更「每个 Requirement 至少 1 个可执行 Scenario」验收口径的一部分。
- **建议**：删除 `:16-24` 的两条 Scenario，保留 `:42-50`；若需强调与混合模式无耦合，在混合模式 Requirement 里加一句非 Scenario 说明。

### [轻微][存量] m4 `verification.md` 的 C5 修复行仍记录已被同文件否决的 4096 上限

- **位置**：`f_svg/doc/spec/add-f-svg-m4/verification.md:339`（C5「已修复」，上限 `min(4096, max(区域宽, 区域高))`）与 `:374`（C5-2，固定 16 + 64 Mi 采样预算）；实现 `f_svg/src/SvgFilterPrimitives2.cj:22-24`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 自相矛盾」
- **证据**：静态确定 —— 实现常量为 `SVG_FE_MORPHOLOGY_MAX_RADIUS = 16.0` 与 `SVG_FE_MORPHOLOGY_SAMPLE_BUDGET = 64 * 1024 * 1024`；`verification-2.md:25`、`:89-92` 已判定 4096 版本仍可造成小时级 DoS 并推翻该行结论，但 `verification.md:339` 未加前向指针或修订标记。
- **描述**：同一文件第 7 节把被否决的上限写成「已修复」，第 8 节才给出真正的 16 + 预算。按第 7 节抽查实现或按该行归档，会把一个已被安全复验否决的阈值当成现行契约。
- **建议**：在 `:339` 行首标注「已被 §8 C5-2 取代：4096 → 16 + 采样预算」，或直接改写该行的修复内容。

### [轻微][存量] m5 两份 fix-plan 的「依据」文件 `verify-report*.md` 不存在

- **位置**：`f_svg/doc/spec/add-f-svg-m5/fix-plan.md:3`（依据 `verify-report.md`，CRITICAL 10 / WARNING 14 / SUGGESTION 6）、`f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md:3`（依据 `verify-report-2.md`，CRITICAL 1 + WARNING 12）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— `add-f-svg-m5/` 目录只有 `design.md`、`proposal.md`、`tasks.md`、`fix-plan.md`、`fix-plan-2.md`、`verification.md`、`verification-2.md`、`specs/`；全目录 `find -name "verify-report*"` 无命中（同类文件只存在于 `add-f-svg-m6` / `add-f-svg-m7`）。
- **描述**：修复计划的编号体系（C1–C10 / N1–N12）全部指向不存在的报告，读者无法核对每条 CRITICAL 的原始判据与证据；`verification-2.md` 也不含这些编号的完整原表。
- **建议**：把两份 `verify-report*.md` 补入目录，或在 `fix-plan*.md` 头部改为引用 `verification-2.md` 的对应小节。注：m4 的同类死引用已由本模块 part4 报告记录，本条只记 m5 实例，不重复计数。

### [轻微][存量] `svg-render-pipeline` 的媒体宽度来源未覆盖 `width="auto"` 分支

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md:89`（`options.width > 0` → 根绝对宽度 → 300）；实现 `f_svg/src/SvgRenderTree.cj:294-311`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「只做了一半的分支 / 规格未覆盖实现行为」
- **证据**：静态确定 —— 当根元素 `width` 或 `height` 为 `auto` 且 `options.width <= 0 && options.height <= 0` 时，实现先用 `SvgAutoSize.rootSize` 求内容尺寸、重算一次样式，再用该尺寸作为媒体宽度；规格只描述「根元素绝对宽度」，`auto` 既不是绝对值也不在 300 的回退口径内。
- **描述**：`width="auto"` + `@media` 的文档，其媒体宽度由内容自适应结果决定，规格无法推导；这条分支还会额外做一次全量样式计算（`SvgRenderTree.cj:289-292`、`:305-311`、`:315-320` 共三次 `compute`），文档未提示该成本。
- **建议**：在 `:89` 补一句「根 `width` / `height` 为 `auto` 且未给选项宽高时，媒体宽度取内容自适应结果」；若要控制成本，注明该分支会多算一次样式。

### [轻微][存量] `design.md` D10 描述的整形接口与实现完全不同，四个符号在仓内从未存在

- **位置**：`f_svg/doc/spec/add-f-svg-m5/design.md:117-120`（`SvgShapingFont` 接口、`shape(glyphIds, fontSize, features): SvgShapedRun`、`glyphId(codePoint)`、`glyphPathById(gid, fontSize)`）；实际实现 `f_svg/src/SvgGsubContext.cj:515`（`shapeGlyphs`）、`f_svg/src/SvgTrueTypeFont.cj:383`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「死代码（声明无定义 / 无消费）」、§13「文档过期」
- **证据**：静态确定 —— `grep -rn "SvgShapingFont\|SvgShapedRun\|glyphId\|glyphPathById" f_svg/src` 无命中；`git log -S "SvgShapingFont" -- f_svg/src`、`git log -S "SvgShapedRun" -- f_svg/src` 均为空，说明该接口从未落地（不是后续里程碑删除）。实现走内部 `SvgTrueTypeFont.shapeGlyphs` + `SvgGsubContext`，`SvgFont` 仍只有 5 个码点方法（`SvgFont.cj:26`），这一点与 D10 的结论一致。
- **描述**：D10 是本变更「文本整形」的对外扩展点设计：它向第三方字体实现承诺了 `SvgShapingFont` 这一旁路接口。按设计文档实现自定义字体时，编译器会报类型不存在；而实际整形能力只对内置 `SvgTrueTypeFont` 生效，第三方 `SvgFont` 实现无法接入 `liga` / `kern`。设计文档与实现相差的不是行号，而是整个接口形状。
- **建议**：把 D10 改写为实际方案（内部 `shapeGlyphs` + 字形 id 级接口），或在 `f_svg-M5设计.md` / README 明确「M5 的整形只覆盖内置 TrueType 字体，未提供 `SvgShapingFont` 扩展点」；若确需该扩展点，另开变更实现并保留 D10 作为目标设计。

### [轻微][存量] `svg-text` 只承诺「无 `GPOS` 时回退 `kern`」，实现还会在「有 `GPOS` 但无 `kern` 特性」时回退

- **位置**：`f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md:82`；实现 `f_svg/src/SvgOpenTypeLayout.cj:315-354`（`cssLayoutLookupRefs` 未找到 `kern` 特性引用或无 Type 2 子表时返回 `None`）、`f_svg/src/SvgTrueTypeFont.cj:345-352`（`gposPairs == None` 时改用 `kernPairs`）；决策 `f_svg/doc/spec/add-f-svg-m5/fix-plan.md:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `SvgGposPairs.parse` 在 `parsed == false` 时返回 `Option<SvgGposPairs>.None`（`SvgOpenTypeLayout.cj:347-349`），即便字体有 `GPOS` 表；`kerningAdjustByIds` 只按 `gposPairs` 是否为 `Some` 选择数据源。`fix-plan.md:21` 的 C2 明确要求「无 `kern` 特性时回退 `kern` 表」，规格未同步这一更宽的回退条件。
- **描述**：规格把回退条件限定为「字体无 `GPOS`」，实现的实际条件是「`GPOS` 中没有可用的 `kern` 特性 Type 2 lookup」。对同时含 `GPOS`（无 `kern` feature）与 `kern` 表的字体，实现会应用 `kern` 字距，而按规格应视为「有 GPOS，不读 kern」。这会让「GPOS 优先」的验收用例边界含糊：测试只需造一个 `GPOS` 表就能验证不回退，但真实字体常是「有 GPOS 表、无 kern feature」。
- **建议**：把 `:82` 改为「优先读取 `GPOS` 的 `kern` 特性 Pair Adjustment；`GPOS` 不存在或其中没有可用的 `kern` 特性 Type 2 lookup 时读取 `kern` 表 format 0」，并补一条「`GPOS` 存在但无 `kern` feature → 使用 `kern` 表」的 Scenario。

<!-- 第 6 部分 -->

### [一般][存量] `text-decoration-color` 缺省值：规格承诺 `currentColor`，实现取文本 `fill`；同一属性在计算样式里还有「初始串 currentColor / 类型化 getter 返回 None」两套答案

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-css/spec.md:254-257`（Scenario「缺省颜色」）、`f_svg/doc/spec/add-f-svg-m6/design.md:162`（D13「颜色缺省取字形 `fill`」）、`f_svg/src/SvgComputedStyle.cj:148`（`SvgPropertySpec("text-decoration-color", false, "currentColor")`）、`f_svg/src/SvgComputedStyle.cj:503-514`（`textDecorationColor()` 缺省返回 `None`）、`f_svg/src/SvgRenderer.cj:335-338`、`:352-370`（`None` 时回落到 `style.fill()`）、`f_svg/src/SvgTextRenderer.cj:71`（注释「`None` 沿用文本填充」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符 / 语义与注释不符」
- **证据**：静态确定 —— 规格场景写「未声明 `-color` → 颜色取 `currentColor`」；`SvgComputedStyle.textDecorationColor()` 在 `sourceOf == Default` 时直接返回 `Option.None`，`SvgRenderer` 对 `None` 的 run 用 `style.fill()` 作 paintOverride（`SvgRenderer.cj:337`、`:357-359` 的 `None` 分支最终走 `drawFill` 的 fill），缺省路径没有任何地方读 `color` 属性
- **描述**：`currentColor` 在 CSS 里解析为 `color` 属性值，而实现解析为 `fill`。当文本 `color` 与 `fill` 不同（例如 `color="blue" fill="red"`，或 `fill` 为渐变/`url()`）时，缺省装饰线的颜色与规格、与浏览器都不一致；`text-decoration-color: currentColor` 显式声明时又会按 `color` 解析（`SvgComputedStyle.cj:505`），于是「显式写 currentColor」与「不写」在同一文档里得到两种颜色。规格与设计本身也互相矛盾（spec 说 currentColor，design D13 说 fill），属 M6 收口时留下的契约分叉
- **建议**：二选一并写进规格：①按 CSS 语义把缺省值解析为 `style.color()`（`SvgComputedStyle.color()` 已存在），并补「`fill` 为 paint server 时装饰线仍是纯色」的用例；②若确定沿用 `fill`，则把 `svg-css` 场景与 `SvgPropertySpec` 的初始串一并改为「缺省取 `fill`」，去掉 `currentColor` 字样，避免使用者按 CSS 语义预期

### [一般][存量] `SvgTimeline.duration()` 未随 M6 `max` 钳制更新：条款承诺「最晚结束时间」，实现返回未截断的 `begin + dur`

- **位置**：`f_svg/doc/spec/add-f-svg-m6/specs/svg-animation/spec.md:58`（`duration()` SHALL 返回所有动画的最晚结束时间）、同文件 `:170`（`min` / `max` 生效活动时长钳制）、`f_svg/src/SvgTimeline.cj:179-186`（构造期 `spec.end = begin + max(total, minValue)`，**未套 `maxValue`**）、`f_svg/src/SvgTimeline.cj:191-199`（`duration()` 直接取 `spec.end` 最大值）、`f_svg/src/SvgTimeline.cj:769-773`（采样时 `effectiveEnd` 才用 `begin + maxValue` 截断）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格两条要求互相冲突」、§11「契约与实现不符」
- **证据**：静态确定 —— `dur="10s" max="3s"` 时 `spec.end = begin + 10`，`duration()` 返回 10；而 `animationStateAt` 收到的 `effectiveEnd` 被钳到 `begin + 3`，动画在 3 秒结束。两个数在同一个类里来自两条不同计算路径
- **描述**：`max` 是 M6 新增能力，`duration()` 条款没有同步。调用方按 `duration()` 决定时间轴长度、循环采样或导出帧序列时，会在 3 秒后拿到整段「已结束、值不再变化」的空白时间；反过来若把 `duration()` 当动画真实终点判断「是否播完」，永远等不到。同一文档里 `animations()` 返回的 `end` 也是未截断值（`SvgTimeline.cj:201-209`），存在同样偏差
- **建议**：`spec.end` 计算时把 `maxValue` 一并纳入（`min(max, max(min, total))`），或在 `duration()` / `animations()` 里统一走 `effectiveEnd`；若「duration 表示未钳制的名义时长」是有意设计，则改规格措辞并新增「钳制后实际终点由 `sample` 决定」的说明与用例（`dur=10s max=3s` 时 `duration()` 期望值需明确）

### [轻微][存量] `design.md` / `proposal.md` 的代码规模、文件清单、行号锚点与结构描述未随 M6 实现回流

- **位置**：`f_svg/doc/spec/add-f-svg-m6/design.md:5`（「288 个源文件，其中 163 个测试文件」）、`:11`（`SvgElement.cj:333` 指 `getBBox`）、`:12`（`SvgRenderTree.cj:534` 指 `foreignObject`）、`:13`（`SvgRenderTree.cj:700` 指 `use`）、`:17`（`SvgRasterizer.cj:118` 指固定容差 0.25）、`:149`（D12 的 `SvgGsubFeatureSet`）、`:211`（D18「15 个新文件」）、`:218`（「新文件只放内部实现与公开枚举 / 结构体」）、`f_svg/doc/spec/add-f-svg-m6/proposal.md:87`（列 18 个新增文件）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 链接失效」、§14.1「接线缺失（文件地图与实现不符）」
- **证据**：静态确定 ——
  - `ls f_svg/src/*.cj | wc -l` = **301**、`*_test.cj` = **169**（文档写 288 / 163）。
  - `proposal.md:87` 的 `SvgColorProfile.cj`、`SvgAnimationControl.cj`、`SvgLineJoin2.cj` 三个文件在 `f_svg/src` 不存在（`design.md:211` 已说明并入 `SvgRenderingHints.cj` / `SvgTimeline.cj` / `SvgShape.cj`，但 proposal 未同步）。
  - 行号锚点全部漂移：`SvgElement.cj:333` 实际是 `false`（`getBBox` 在 `:452`），`SvgRenderTree.cj:534` 实际是 `expandUse` 分支（`foreignObject` 分支在 `:646`/`:651`），`SvgRasterizer.cj:118` 是空行（`0.25` 容差在 `:103`）。
  - `design.md:211` 称 15 个新文件，实际 M6 新增 16 个：`f_svg/src/SvgViewState2.cj:19`（`public class SvgViewState`）由 M6 P7 提交 `a061fe1ef` 引入，不在清单内。
  - `design.md:218` 称新文件只放内部实现与公开枚举 / 结构体，实际新文件声明了公开类并带 public 方法：`SvgHitTest.cj:142`（`public class SvgHitTest`）、`:203`/`:240`（`public static func elementsAt`/`elementAt`）、`SvgAutoSize.cj:32`、`SvgMutation.cj:42`、`SvgHitTest.cj:26`（`SvgInteractionState`）。
  - `design.md:149` 要求的 `SvgGsubFeatureSet` 全仓无定义；实现是单一 `SvgGsubLigatures`（`SvgOpenTypeLayout.cj:535`）加 `ligatureAt(..., feature:)`（`SvgTextRenderer.cj:1851`）。
- **描述**：design 是后续维护者读 M6 的第一入口，规模、文件清单、行号锚点与 D12/D18 的结构描述同时漂移会让「按文档找实现」失效：按 proposal 找 `SvgColorProfile.cj` 会扑空，按 design 的 `SvgElement.cj:333` 找不到 `getBBox`，按 D18 会认为新文件里没有公开 API，按 D12 会去找不存在的 `SvgGsubFeatureSet`
- **建议**：规模数字改为「以 `f_svg/src` 为准，不写死」或每次收口用脚本刷新；proposal 的 Affected code 列表加一句「最终文件清单见 design D18」；行号锚点改为「函数名 + 文件」而非裸行号；D18 补 `SvgViewState2.cj` 并把「新文件只放内部实现与公开枚举 / 结构体」改为「新文件可声明公开类型，新增到既有类型的方法仍写在原类体内」；D12 改为实际的「单一 `SvgGsubLigatures` + feature 参数按名查询」

### [轻微][存量] 过程文档引用的 `openspec/changes/add-f-svg-m5|m6/...` 路径在仓库中不存在；m5/m6 delta 规格声明为 `MODIFIED Requirements`，但 `openspec/specs` 里没有对应 `svg-*` 主规格

- **位置**：`f_svg/doc/spec/add-f-svg-m6/fix-plan-2.md:3`、`f_svg/doc/spec/add-f-svg-m6/fix-plan-3.md:3`、`f_svg/doc/spec/add-f-svg-m5/verification.md:3`、`f_svg/doc/spec/add-f-svg-m5/verification-2.md:35`、`:69`；`f_svg/doc/spec/add-f-svg-m6/specs/*/spec.md`（7 份 delta 均以 `## MODIFIED Requirements` 开头）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」、§14.1「能力未接入 / 版本与索引漂移」
- **证据**：静态确定 —— `ls openspec/changes` 只有 `add-f-a2a/` 与 `archive/`，没有 `add-f-svg-m5` / `add-f-svg-m6`；`ls openspec/specs` 只有 `data-assist-compare` / `data-assist-supertypes` / `jwt-signature` / `orm-result-type-mapping` / `uring-async-io`，无 `svg-css` / `svg-text` 等能力域。文档内容实际存放在 `f_svg/doc/spec/add-f-svg-m*`（`m5/verification.md:393` 自述「`openspec/` 被 `.gitignore` 忽略，仅工作树生效」）
- **描述**：fix-plan-2 把 `openspec/changes/add-f-svg-m6/verify-report.md` 写成依据，fix-plan-3 把 `verify-report-2.md` 写成依据，这两条路径今天都打不开（同名文件在 `f_svg/doc/spec/add-f-svg-m6/verify-report*.md`）；m5 的验收报告把校验对象写成 `openspec/changes/add-f-svg-m5`。同时 7 份 delta 规格声明的 `MODIFIED Requirements` 没有可对照的主规格，「改写了哪条既有要求」无法验证，归档动作（m5 tasks 13.7 / m6 tasks 9.8）也失去前置条件
- **建议**：把过程文档里的 `openspec/changes/...` 统一改为 `f_svg/doc/spec/...` 的实际路径，或补回被忽略的目录；delta 规格若要继续保留 `MODIFIED` 语义，应同时提交 `openspec/specs/svg-*` 主规格（或改为 `ADDED Requirements` 并在归档时再合并）

### [轻微][存量] M5 同目录两份复验报告结论相反，且未标注取代关系

- **位置**：`f_svg/doc/spec/add-f-svg-m5/verification-2.md:144-147`；`f_svg/doc/spec/add-f-svg-m5/verification.md:411`、`:423`、`:456`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 文档结论与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— `verification-2.md:144-147` 的最终结论为「C4 部分清除（`Body → Brand` 别名主场景仍未实现）」「在该 CRITICAL 解决前，不应把本变更归档为 M5 完成」，`:147` 明写 `CRITICAL=1`；`verification.md:411` 的 §9 标题为「第二轮复验修复（fix-plan-2 / verify-report-2）」，`:423` 的 N1 行结论为「已清除」，`:456` 为「CRITICAL=0」，即 §9 是晚于 verify-report-2 的修复记录。当前实现支持 §9：`SvgFont.cj:91-104` 已按 `src: local(<family>)` 建立目标别名，`CssFontAliasM5_test.cj:59` 的 `localSourceAliasesRegisteredFamily` 用例存在
- **描述**：同一变更目录里两份文档对「能否归档」给出相反答案，而 `verification-2.md` 既没有指向 §9 的前向说明，文件名（`verification-2.md`）与正文标题（`add-f-svg-m5 修复后复验报告（verify-report-2）`）也不一致。按目录顺序阅读会先看到「CRITICAL=1、不应归档」，据此做归档门禁判断会得到错误结论
- **建议**：在 `verification-2.md` 顶部加一行状态说明「本报告结论已被 `verification.md` §9 取代：N1 已清除，CRITICAL=0」；文件名改为 `verify-report-2.md`，与 `add-f-svg-m6` 目录的 `verify-report*.md` 命名保持一致

> 存量缺陷共 5 条，是否纳入修复待用户决定。

**范围外提示**（证据所在的文件属于第 7 部分，不计入本部分统计）：

- `f_svg/doc/spec/add-f-svg-m6/verification.md` 的最终门禁数字自相矛盾（`:4`、`:543-544` 为 1186，`:580`、`:590`、`:599-600` 为 1187），且 `:178-182` 把「抗锯齿」5 个场景的落点标成 `SvgRasterizer_test`（该类无 `antiAlias` 断言），建议由第 7 部分复核。
- `f_svg/src/SvgHitQueries.cj:28`、`:46`、`:82-83` 把样式与 bbox 的视口固定成 `300 × 150`，含 `@media` 或百分比几何的文档按 `width=800` 渲染时查询结果会与渲染不一致（该文件不在本部分清单内，仅记一句）。

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

### [严重][存量] `calc()` 一元 `+` / `-` 递归无深度上限，深度由属性文本决定，可压穿线程栈

- **位置**：`f_svg/src/CssCalc.cj:163-177`（`parseUnary`，递归点 `:167`、`:174`）；对照 `:184-200` 的括号深度守卫
- **来源**：存量（工作区快照；本部分无 diff）
- **判据**：review-checklist §4（无界递归 / 深度由输入决定 / 无环检测）
- **证据**：静态确定 —— 递归深度 = 输入中连续 `+` / `-` 的个数，代码里没有任何计数器；崩溃层数需实测
- **描述**：
  - `parsePrimary` 对括号嵌套做了 `CSS_CALC_MAX_DEPTH = 16` 的显式守卫（`:185-188`），但同一表达式里的一元符号走的是另一条递归：`parseUnary` 遇到 `-` 后 `i++` 再 `return match (this.parseUnary())`（`:165-171`），遇到 `+` 直接 `return this.parseUnary()`（`:172-175`）。
  - 这条路径完全不看 `this.depth`，也不看已扫描长度。深度上界只由属性值长度决定：`width="calc(-----…-----1px)"` 里 K 个符号就是 K 层栈帧。
  - 输入规模不受任何前置限制：`SvgStyleResolver.normalizeValue` 只检查 `text.size > 5`、末字符为 `)`、前 5 字符为 `calc(`（`f_svg/src/SvgStyleResolver.cj:524`），CSS 声明侧也没有值长度上限（`Css*.cj` 中没有长度/上限常量，只有语法容错截断），`f_xml` 也只限元素数、深度与实体展开。即 50 KB 的 `style="width: calc(-----…)"` 就能生成五万层递归。
  - 后果是栈溢出直接终止进程（不是可捕获的 `SvgException`），对「解析用户上传 SVG」这一模块默认场景是可用性缺陷；同文件对括号已经加了上限，说明作者本意是有界的，一元分支属于漏加。
- **建议**：在 `parseUnary` 入口复用同一计数器（例如进入前 `if (this.depth >= CSS_CALC_MAX_DEPTH) return None` / 出栈递减，或单独加 `unaryDepth`），或把一元符号收敛为「先消费连续符号、统计个数与奇偶，再解析一次 primary」的循环写法（顺带把 `+` 变成 no-op）。补用例：K 个 `-` 前缀（K=17，与 `nestingLimit` 并列）期望 `None`。另建议在 `SvgStyleResolver` 侧给声明值加统一长度上限（如 4 KB），让所有样式解析共享同一条输入上界。

### [一般][存量] `calc()` 的 `em` / `%` 换算与乘除不校验有限性，`formatSvgNumber` 抛异常击穿「失败返回 `None`」契约

- **位置**：`f_svg/src/CssCalc.cj:226`（`em` 乘法）、`:234`（`%` 换算）、`:253-266`（`combineCssCalcMul`）；对照 `:242-251`（`combineCssCalcAdd` 有 `isFiniteSvgNumber` 检查）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（契约与实现不符 / 错误处理缺失）、§10（`Option` 契约）
- **证据**：静态确定
- **描述**：
  - `evaluateCssCalc` 的注释写明「失败返回 `None`」（`CssCalc.cj:49-59`），调用方 `normalizeValue` 也只按 `Some` / `None` 分支处理，未包 `try`（`f_svg/src/SvgStyleResolver.cj:536-545`）。
  - 但四条产生浮点结果的路径没有 `isFiniteSvgNumber` 检查：`value * this.fontSizePx`（`:226`）、`value / 100.0 * reference`（`:234`）、`left.value * right.value`（`:256`、`:259`）、`left.value / right.value`（`:266`）。只有加法分支检查了（`:247-249`），同族运算的守卫已经漂移。
  - 单个字面量本身有保证：`tryParseSvgFloat` 拒绝 `NaN`/`Inf`（`f_svg/src/SvgShape.cj:397-411`），所以只能由运算溢出产生。最小触发：`calc(<1 后 308 个 0>px * 10)`、`calc(1px / <次正规数>)`、`calc(<≈1e308>em)`（`fontSizePx` 本身极大时）。
  - 溢出后 `CssCalcValue` 仍带原单位返回，`formatCssCalcValue`（`:67-73`）把它交给 `formatSvgNumber`，后者对 `NaN` / `Inf` 直接 `throw SvgException(kind: InvalidValue)`（`f_svg/src/SvgNumber.cj:32-35`）。
  - 后果：`SvgException` 从 `evaluateCssCalc` 抛出，穿过 `normalizeValue` → `SvgStyleResolver.compute` / `computeElement`（公开 API，`SvgStyleResolver.cj:90-105`、`:118`，均未捕获），整篇文档的计算样式求值中断；`SvgRenderTree` / `SvgElementApi` / `SvgHitTest` 的调用点同样没有 `try`。正常路径应当是「该属性回退初始值 + warning」（`SvgStyleResolver.cj:354-372` 的既有回退逻辑），现在变成整份文档不能渲染。
- **建议**：在 `combineCssCalcMul` 与两处单位换算后统一加 `isFiniteSvgNumber` 判定（与 `combineCssCalcAdd:247` 对齐，或抽 `finiteOrNone(value, unit)`），让溢出走 `None`；`formatCssCalcValue` 再做一次兜底。补三条负向用例：`calc(<≈1e308>px * 10)`、`calc(1px / <次正规数>)`、`calc(<≈1e308>em)`，期望 `None` 且 `resolver.warnings` 有一条，而不是抛异常。

### [轻微][存量] `parseExpression` / `parseTerm` 末尾的 `Some(left)` 不可达

- **位置**：`f_svg/src/CssCalc.cj:133`、`:160`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1（`return` 之后的同层语句、恒不执行分支）
- **证据**：静态确定
- **描述**：两个函数体都是 `while (true) { … }`，循环内四个出口分别是 `:117` / `:121`（`return Some(left)`）与 `:126` / `:130`（`return None`），循环不存在正常退出路径，因此循环之后的 `Some(left)` 永不被执行。仓颉编译器不报「不可达代码」warning（模块声称 0 warning），所以它一直留在文件里，读者会误以为存在「循环结束返回」的语义。保留它可能只是为了让类型检查器接受「函数末尾有返回值」，不能直接删。
- **建议**：把 `while (true)` 改成带显式条件的循环并让尾部 `Some(left)` 成为真实出口，或把循环体抽成返回 `?CssCalcValue` 的辅助函数，只保留一种形态。

### [轻微][存量] `parseExpression` 与 `parseTerm` 是同一套二元循环的复制，守卫已经漂移

- **位置**：`f_svg/src/CssCalc.cj:109-134`（加法层）与 `:136-161`（乘法层）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（只改运算符的重复逻辑 / 近似重复导致行为漂移）
- **证据**：静态确定
- **描述**：两个函数逐行对齐——`skipSpaces` → 取 `marker` → 判断是否属本级运算符集 → `i++` → 解析右侧 → 合并 → 循环；差异只有三处：运算符集（`+`/`-` 对 `*`/`/`）、右操作数解析函数（`parseTerm` 对 `parseUnary`）、合并函数（`combineCssCalcAdd` 对 `combineCssCalcMul`）。这三处是语法优先级要求，属必要差异，但**复制已经引发实质漂移**：加法层在合并后检查 `isFiniteSvgNumber`（`:247`），乘法层完全没有（见上一条「一般」发现）。这正是 checklist §2「近似重复，其中一块少了边界判断」的形态。
- **建议**：抽一个 `parseBinaryLevel(next, isOp, combine)` 的单一实现，两个层级各传一组函数；有限性检查统一放在 `combine` 之后。若认为函数值抽象在热路径上不划算，至少把 `isFiniteSvgNumber` 断言提成公共收尾，避免再次漂移。

### [轻微][存量] `formatCssCalcValue` 重写了 `SvgLength` 的「数值 + 单位后缀」序列化

- **位置**：`f_svg/src/CssCalc.cj:67-73`（`Number → ""`、`Absolute → "px"`、`Percent → "%"`）、`f_svg/src/SvgLength.cj:127-129`（`formatSvgNumber(value) + unit.suffix()`）、`f_svg/src/SvgLength.cj:66-75`（同一张后缀表）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 两处输出语义完全相同（同一 `formatSvgNumber`，后缀 `""`/`"px"`/`"%"` 逐字相同），差异只有 `CssCalcUnit.Absolute` ↔ `SvgLengthUnit.Px` 这层命名换算；而 `evaluateCssCalc` 的返回值本来就要交给 `SvgLength.tryParse` 消费（`SvgStyleResolver.cj:593`）
- **描述**：`SvgLength.suffix()` 是单位拼写的唯一事实源，`calc` 侧另抄一份后，将来调整单位集合或拼写必须记得改两处，且没有用例同时覆盖二者。合并成本极低：`CssCalcUnit` 三个 case 直接映射 `SvgLengthUnit.Number/Px/Percent`，`formatCssCalcValue` 变成 `SvgLength(value, unit).toString()`
- **建议**：删除 `formatCssCalcValue` 的单位映射，改由 `SvgLength` 序列化（也可反过来让 `combineCssCalc*` 直接运算 `SvgLength`，把单位一致性检查交给同一层）

### [轻微][存量] M7 proposal 把 `save` 失败写成 `SvgException(kind: Io)`，与实现、spec、tasks 相反

- **位置**：`f_svg/doc/spec/add-f-svg-m7/proposal.md:13`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（文档承诺与实现相反）
- **证据**：静态确定 —— 代码 `catch (_: FSException) { throw invalidValue(...) }`（`f_svg/src/SvgAuthoringBuilder.cj:66-71`）；`SvgErrorKind` 只有 `Syntax` / `InvalidValue` / `Unsupported` / `Security` / `Limit`（`f_svg/src/SvgException.cj:21-31`），根本没有 `Io`；同变更的 `specs/svg-authoring/spec.md:200` 与 `tasks.md:75-77` 都记的是 `InvalidValue`
- **描述**：proposal 的 What Changes 第 5 条写「新增 `.save(path)` 落盘：…失败统一包装为 `SvgException(kind: Io)`」。这条既是过期描述（D9 偏差已裁决为 `InvalidValue`），也与同目录 spec/tasks 直接冲突。读者若只看 proposal 会去写 `if (e.kind == Io)`，编译不过（枚举无该构造器）。
- **建议**：把 `proposal.md:13` 改为 `SvgException(kind: InvalidValue)`，并补一句「`SvgErrorKind` 无 `Io`，沿用 `SvgBitmap.savePng` 口径」。

### [轻微][存量] M7 的校验记录口径不一致：1225/1226、W-5 未修/已修、两个互斥分支名

- **位置**：`f_svg/doc/spec/add-f-svg-m7/verify-report.md:32`、`:42-43`、`:305-310` 对照 `verification.md:25`、`:143`；`tasks.md:4` 对照 `tasks.md:10`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（同一变更内文档数据互相矛盾 / 缺版本标注）
- **证据**：静态确定
- **描述**：
  - 用例总数：`verify-report.md:32` 与 `:42` 记 `TOTAL: 1225`、新增 38 条；`verification.md:25` 记 `TOTAL: 1226`、新增 39 条。两条推算路径都得 1187 条基线，所以这个 1 条差异不会被任何断言暴露。
  - 修复状态：`verify-report.md:305-310` 的 W-5（`SvgAnimateMotion.mpath` 直接 `children.remove` 留下过期 `parent`）仍是「建议改用 `removeChild`」的开放项；`verification.md:143` 的同一 W-5 记「已修复 … 断言旧引用 `parent.isNone()`」，且 `SvgBuilderM7_test.cj` 已按修复后口径断言。
  - 分支名：`tasks.md:4` 写「全部工作位于 `feature/f-svg-m7` 分支」，`:10` 的 1.1 与 `verification.md:14` 都写 `feature/f_svg`。
  - 两份校验文件都没有「被取代 / 时间戳」标注，读者无法判断哪份是终态。同类偏差已由 `verify-report.md:352-357`（S-8）指出但未修复。
- **建议**：在 `verify-report.md` 顶部加一行「本文件为修复前快照，终态见同目录 `verification.md`」（或删掉过期条目并在结论里指向它）；`tasks.md:4` 改为 `feature/f_svg`，或删除分支名统一指向 1.1。

### [轻微][存量] `svg-authoring` 规格写「追加到当前游标元素」，实现是「追加到当前容器、游标另设」

- **位置**：`f_svg/doc/spec/add-f-svg-m7/specs/svg-authoring/spec.md:32`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— `SvgAuthoringBuilder` 同时持有 `container`（挂载点）与 `cursor`（样式/动画作用点）（`f_svg/src/SvgAuthoringBuilder.cj:31-33`）；`adopt` 只把新元素挂到 `container` 并把 `cursor` 指向新元素（`:399-403`）；`group()` 压的是 `container`（`:91-101`）
- **描述**：规格第 2 条要求「每个方法 SHALL 创建既有模型类型…追加到**当前游标元素**，并把游标指向新元素」。按字面，`rect().rect()` 的第二个 `rect` 应嵌进第一个 `rect`；实现是兄弟（挂到 `container`），这是正确的 SVG 行为，也是 `shapeGeometry` 用例的断言口径。同变更的 `verify-report.md:316-320`（S-1）已把这条列为规格措辞问题，但 spec 未回改，读者仍会按错误语义理解链式 API（`rect(...).group().end().fill(...)` 的 `fill` 会落到根而不是 `rect`）。
- **建议**：把「当前游标元素」改为「当前容器（当前父元素）」，并补一句「形状方法不改变容器，因此连续形状调用互为兄弟；`cursor` 只决定样式与动画落点」。

### [轻微][存量] local mode 设计文档引用的行号是插入常量前的版本，逐条偏移 17-40 行

- **位置**：`f_svg/doc/spec/local-mode-f-svg-analytic-coverage/design.md:5-8`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（引用位置失效，读者按行号定位不到目标）
- **证据**：静态确定 —— 文档写 `analyticCoverage`（`:124-180`）、`accumulated` 分配（`:166`）、`accumulateAnalyticRow`（`:183-238`）、`sortAnalyticValues`（`:402-414`）；实际为 `f_svg/src/SvgAnalyticRasterizer.cj:141-155`、`:200`、`:221-279`、`:442-453`（本次变更在文件头插入了 `ANALYTIC_LOCAL_ACCUMULATOR_*` 与 `analyticUsesLocalAccumulator`，`:82-97`）
- **描述**：同一文档的 `SvgRasterizer.cj:285`（调用点）与 `f_base/cjpm.toml:3-4` 是正确的，说明作者只更新了一部分引用；其余行号仍停留在插入常量之前。照文档核对实现的人会读到无关代码。注意这与 M1 设计 D11 的「文件布局表」不同——后者不是代码行号引用。
- **建议**：把这些行号更新为终态位置，或改成「函数名 + 文件」而不写行号（跨版本更稳）。

<!-- 第 9 部分 -->

### [严重][存量] 选择器索引只用分组的第一条选择器，`rect, circle` 这类分组的后续选择器永不生效

- **位置**：`f_svg/src/CssSelector.cj:402-419`（`CssSelectorIndex.init`，`:404` 取 `rules[index].selectors[0]`）；`f_svg/src/CssSelector.cj:422-459`（`candidates` 只从这些桶取候选）；消费方 `f_svg/src/SvgStyleResolver.cj:425-437`（只遍历 `index.candidates(element)`，循环体内才遍历 `rule.selectors`）
- **来源**：存量（工作区快照；`git blame` 指向 `71190070ec` 2026-11-05「M2 CSS 级联」）
- **判据**：review-checklist §10（正确性 / 契约与实现不符）、§2（近似实现导致的行为漂移——「索引只取样例」与「匹配遍历全部选择器」两处口径不一致）
- **证据**：静态确定 —— 建索引处只读 `selectors[0]`，候选集之外没有任何「全量规则回退」分支（`considerSheet` 唯一的数据源就是 `candidates`）
- **描述**：
  - `CssStyleSheet` 把 `rect, circle { … }` 解析成**一条** `CssRule`，`selectors` 长度为 2（`f_svg/src/CssStyleSheet.cj:257-269`，并由 `CssStyleSheet_test.cj:129`、`CssSelector_test.cj:111-113` 固定）。
  - `CssSelectorIndex.init` 只拿 `selectors[0]` 的右端复合选择器决定入哪个桶：`rect, circle` 只进 `byType["rect"]`。于是 `<circle>` 元素取候选时 `byType["circle"]` 为空、`universal` 也为空 ⇒ 这条规则根本不在候选集里，`considerSheet` 后面那句 `for (selector in rule.selectors)` 永远没机会看到 `circle`。
  - 同源影响：`.a, .b { … }` 对只有 `class="b"` 的元素失效；`#x, rect { … }` 对非 `#x` 的 `rect` 失效。凡「不是第一条选择器命中」的组合全部丢声明。
  - 现象是**静默**的：不抛异常、不写 warning，只是样式少了一条，渲染结果错但不报错。
  - `doc/f_svg-M2设计.md:84` 明确承诺「分组 `rect, circle`」；`f_svg/src/CssSelectorSpecificityM5_test.cj:63` 只验证了分组的选择器文本与特异性，没有一条用例把分组规则送进解析器再断言第二个选择器命中——这就是缺陷能长期存活的原因。
- **建议**：建桶时遍历 `rule.selectors` 的**每一条**，把 `index` 同时登记到各自的桶（同一 `index` 可进多个桶，`candidates` 已有的 `seen` 去重会处理重复）；或把 `CssRule` 在 `prepare` 阶段按选择器展开成多条规则（顺序号沿用原 `order`，特异性取各自选择器）。补一条级联用例：`rect, circle { fill: red }` 断言 `<circle>` 取到 `#ff0000`。

### [严重][存量] 属性选择器带引号的值逐字节切 `String`，非 ASCII 值抛 `IllegalArgumentException`，穿透只捕 `SvgException` 的样式表解析

- **位置**：`f_svg/src/CssSelector2.cj:373-400`（`parseCssAttributeValue`；`:383` 转义分支 `text[i + 1..i + 2]`、`:386` 普通分支 `text[i..i + 1]`）；穿透点在 `f_svg/src/CssStyleSheet.cj:262-266`（`catch (error: SvgException)` 是唯一捕获）
- **来源**：存量（工作区快照；`git blame` 指向 `6296495ffd` 2026-11-06「M5 P1 CSS 扩展」）
- **判据**：review-checklist §11（边界 / 崩溃路径）、§10（错误处理：公开解析入口只承诺 `SvgException`）
- **证据**：静态确定 —— `std.core` 的 `String` 区间下标文档写明「起止点必须位于字符边界上……不是字符边界，抛出 `IllegalArgumentException`」（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md`，`### operator func [](Range<Int64>)` 的「异常」段）
- **描述**：
  - 带引号的比较值是**按字节**拼出来的：`out.append(text[i..i + 1])` 每次前进一个字节。值里一旦出现多字节 UTF-8 字符（`[data-x="中文"]`、`[title="café"]`），`i` 落在某个字符的中间字节，`text[i..i+1]` 直接抛 `IllegalArgumentException`（不是 `SvgException`）。
  - `CssStyleSheet.parse` 只 `catch (error: SvgException)`，于是异常穿过 `CssStyleSheet.parse` → `SvgStyleResolver.prepare` → `compute` → `SvgRenderer.render`，整份文档的样式解析与渲染中断。同类输入的其它失败路径（缺名、缺值、缺右括号）都只是「跳过该选择器 + warning」，唯独这一条是硬崩，属于「同族错误处理漂移」。
  - 转义分支同样按字节切（`:383`）：`[data-x="a\中"]` 也会在 `\` 之后切到字符中间而抛异常。
  - 触发门槛极低：只要样式表里出现一个非 ASCII 的属性比较值。本部分 15 个测试文件里没有任何一条非 ASCII 的 CSS 属性比较值（`quoteStyles` / `caseInsensitiveFlag` 全用 ASCII），所以回归测试留了空档。
- **建议**：不要按字节切——要么复用同文件的 `decodeCssIdent`（它已按 `utf8Length` 走边界并解码转义，`CssLexer.cj:409-445`），要么改为 `StringBuilder.append(Rune.fromUtf8(...))` / 按 `utf8Length(lead)` 步进后整段 `append(text[i..next])`。补两条用例：`[data-x="中文"]`、`[data-x="a\中文"]` 期望「正常解析或不匹配 + warning」，断言不抛非 `SvgException`。

### [严重][存量] 后代组合符匹配无记忆化，最坏组合数随「段数 × 祖先深度」爆炸

- **位置**：`f_svg/src/CssSelector.cj:266-317`（`matchPartAt`，后代分支 `:285-297` 对每个祖先各自递归一次 `index-1`）；段数上限 `CssSelector2.cj:221`（`CSS_MAX_SIMPLE_SELECTORS = 256`）；文档深度上限 `f_svg/src/SvgOptions.cj:55`、`:66`（`maxDepth` 默认 512）
- **来源**：存量（工作区快照；`git blame` 指向 `71190070ec` 2026-11-05）
- **判据**：review-checklist §6.4（低效算法 / 回溯型写法）、§4 的邻域（深度由输入决定，但这里是时间而非栈）
- **证据**：静态确定（复杂度推导；具体耗时未测，但组合数上界已远超可执行规模）
- **描述**：
  - 匹配是「右端对齐 + 逐级回溯祖先」的经典算法，但没有保存中间结果（无 `(partIndex, element)` 记忆表）。对单个元素，`T(i) = Σ_{祖先 a} T(i-1, a)`，在一条深度 `d` 的祖先链上收敛为组合数 `C(d, i)`。
  - 两个上限都不是防护：`CSS_MAX_SIMPLE_SELECTORS = 256` 允许 256 段选择器（`CssSelectorLimitM5_test.cj:80-90` 明确把「256 段 `rect` 后代链」当成合法输入），`maxDepth = 512` 允许 512 层嵌套。二者相乘：`C(512,256) ≈ 10^152`；即便降到 64 段 / 128 层，`C(128,64) ≈ 10^37`。
  - 触发用的是「每段都能匹配」的选择器，最省事的是全通配：`* * * … *`（256 段，`grep` 级的文本只有 512 字节）。通配段在索引里落 `universal` 桶，任何元素都是候选，于是深层元素一开始就进入这棵指数树。
  - 而且不是「一个元素慢一次」：`considerSheet` 对**每个元素**都调用 `selector.matches`（`SvgStyleResolver.cj:437`），文档里任何深层元素都会各自再爆一次。
  - 与同文件已做的守卫形成对照：段数（256）与深度（512）都设了上限，说明作者本意是「有界」，但两条独立上限并不约束二者乘积，属漏算。
- **建议**：给 `matchPartAt` 加一层「本次 `matches` 调用内」的备忘（`HashMap<(Int64, Int64), Bool>` 或按元素 `identity` + `partIndex` 的二维表，随调用结束丢弃），复杂度降到 `O(段数 × 祖先深度)`；同时把「含后代组合符的段数」单独设更小上限（例如 32），或在解析期拒绝「连续通配后代」这类无意义选择器。补用例：256 段 `*` + 128 层嵌套文档，断言单次 `matches` 在毫秒级完成（现在是不可完成）。

### [一般][存量] `parseCssInteger` 整数溢出抛异常，击穿 `parseCssAnB` 的「非法返回 `None`」契约

- **位置**：`f_svg/src/CssSelector2.cj:588-615`（累加在 `:607` `value = value * 10 + …`）；调用方 `:433-440`（`parseCssAnB` 只按 `Some` / `None` 分支，未包 `try`）
- **来源**：存量（工作区快照，`6296495ffd` 2026-11-06）
- **判据**：review-checklist §10（错误处理 / `Option` 契约）、§11（契约与实现不符）
- **证据**：静态确定 —— 仓颉固定精度整数默认溢出策略是 `throwing`（`cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/compile_options.md:233-237`：「默认为 `throwing`……整数运算溢出时会抛出异常」）
- **描述**：
  - `parseCssAnB` 的注释写「非法返回 `None`」，`parseCssInteger` 的注释写「严格整数：可选符号 + 至少一位数字」，实现里却对位数不设限：`:nth-child(99999999999999999999)` 走到第 20 位时 `value * 10` 溢出，抛出的不是 `SvgException`。
  - 后果与上一条同构：`CssStyleSheet.parse` 的 `catch (error: SvgException)` 接不住，整份样式表解析中断；正常路径应当是「该规则被跳过 + warning」（`CssStyleSheet.cj:262-266` 已实现）。
  - 现有负向用例（`CssSelectorNthM5_test.cj:98`）只覆盖 `"2n+"` / `"++2"` / `"2m+1"` 之类的语法错误，没有数值越界样本。
- **建议**：在累加前判位数（例如 `i - digitStart > 9` 直接 `None`）或改用 `Int64` 溢出安全的逐步判据（`value > (Int64.Max - digit) / 10` → `None`）。补用例：`:nth-child(99999999999999999999)` 期望解析失败 + 一条 warning、`rules.size` 不受影响。

### [一般][存量] 十六进制转义未排除 UTF-16 代理区，`Rune(UInt32)` 在运行期抛异常

- **位置**：`f_svg/src/CssLexer.cj:447-459`（`parseCssHexCodePoint`；`:455` 只判 `value <= 0 || value > 0x10FFFF`）；消费点 `:425-428`（`decodeCssIdent` 的 `out.append(rune)`）
- **来源**：存量（工作区快照；`git blame` 指向 `fe68a45df` 2026-11-05「实现 CSS 词法与规则解析」）
- **判据**：review-checklist §11（边界 / 错误处理）
- **证据**：静态确定 —— `Rune` 取值范围是 Unicode scalar value，排除 `D800`–`DFFF`；整数到 `Rune` 的转换「仅当 `num` 落在 `[0x0000,0xD7FF]` 或 `[0xE000,0x10FFFF]` 中时……否则……运行时抛异常」（`cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md:139-143`）
- **描述**：CSS 允许 6 位十六进制转义，`\d800` 这种代理码点会通过 `:455` 的范围检查（`0xD800 < 0x10FFFF`），随后 `Rune(UInt32(value))` 抛异常。异常发生在 `decodeCssIdent` 内部，再往上同样只被 `catch (error: SvgException)` 拦（`CssStyleSheet.cj:264`），于是「一个畸形转义」= 整份样式表解析中断。CSS 规范对此的规定是替换成 U+FFFD，本文件已经为 `\0` 实现了 U+FFFD 回退（`:427`），唯独漏了代理区。
- **建议**：`:455` 改为 `if (value <= 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) { return None }`，让既有 `case None => out.append("\u{FFFD}")` 兜住。补用例：`cssTokenTexts("a\\d800")` 与 `CssSelector.parse(".a\\d800")` 断言不抛异常。

### [一般][存量] 属性比较值不解码 CSS 转义，选择器 ident 也不认转义，两处都与词法层口径不一致

- **位置**：`f_svg/src/CssSelector2.cj:378-393`（引号分支只把 `\x` 原样 `append`，既不还原十六进制也不还原被转义字符）；`f_svg/src/CssSelector2.cj:233-241`、`:244-252`（类型 / `.class` / `#id` 的扫描只用 `isCssIdentByte`，遇 `\` 立即停）
- **来源**：存量（工作区快照，`6296495ffd` 2026-11-06）
- **判据**：review-checklist §10（正确性）、§2（同一语义两套实现、口径漂移）
- **证据**：静态确定 —— 词法层 `scanCssIdent` 明确把 `\` 交给 `consumeCssEscape`（`CssLexer.cj:344-356`）并由 `decodeCssIdent` 解码；选择器层却绕开词法器直接按 `isCssIdentByte` 重扫
- **描述**：
  - 属性值：`[data-x="a\62 c"]` 按 CSS 应等于 `abc`，实现得到字面量 `a62 c`（`:383` 只 `append` 了 `\` 后那一个字节），于是**静默不匹配**——既没有 warning，也不报错，只是该元素的样式少一条。
  - 选择器 ident：`.fo\6f` / `#\31 23` 这类带转义的类名 / id，在 `:246-249` 扫到 `\` 就停，`i == nameStart` 时抛「选择器限定符缺少名称」（被兜住，记 warning）；类型名则表现为「解析到一半停下 → 缺少组合符」（`:209-211`），整条选择器被丢弃。也就是说词法器认得转义、`decodeCssIdent` 也会解码，但选择器解析路径根本走不到它。
  - 与词法测试的口径直接冲突：`CssLexer_test.cj:68-74` 断言 `a\31 23` 是一个 Ident、`.x\ y` 的 `x\ y` 保留整体，说明「转义属于受支持的输入」；而选择器层对同样的输入直接判非法。
- **建议**：把选择器 ident 的扫描抽成「与 `scanCssIdent` 共用 + `decodeCssIdent` 收尾」的单一入口（`parseCssSimpleSequence` 与 `parseCssNotArgument` 各两处），属性值则复用 `decodeCssIdent` 的转义逻辑；若确定不支持，应在 README「选择器」表里写明「标识符与属性值不支持 CSS 转义」，并把 `CssLexer_test.cj:68-74` 的断言收窄到词法层。

### [一般][存量] `CssParser.cj` 只有 3 行，缺 Apache 版权头，且解析职责早已迁到 `CssStyleSheet`

- **位置**：`f_svg/src/CssParser.cj:1-3`（`package fountain::f_svg` + `// TODO(M2): CSS 规则解析器。`）
- **来源**：存量（工作区快照；`git blame` 指向 `d96f999be` 2026-11-05「建立 M2 空实现骨架」，M2 骨架创建）
- **判据**：`fountain-baseline.md` §3（每个 `.cj` 必须有位于 `package` 之前的 Apache 2.0 头，缺头按「一般」报）；review-checklist §1（兼容 / 骨架残留）、§3（`TODO` 占位）
- **证据**：静态确定 —— 全文仅 3 行，无任何声明；全仓 `grep CssParser` 只命中设计文档与规格（`f_svg/doc/f_svg-M2设计.md:162`、`:512`）与 `f_svg/doc/spec/add-f-svg-m2/verification.md:257`、`fix-plan.md:39` 两条「建议清理」记录，没有任何代码引用
- **描述**：
  - 该文件不含实现，真正的规则 / 声明块解析在 `CssStyleSheet.cj`（`parseCssRuleBlock` / `parseCssDeclarations`）。文件头缺少本项目统一要求的 Apache 注释，是本部分 20 个文件里唯一的例外（其余 19 个都带头）。
  - M2 的验证记录已经点过这个问题（`verification.md:257`「建议删除或补充职责说明，避免被误认为未完成实现」、`fix-plan.md:39`），但至今未处理，属「已知未闭环」。
  - 影响面：`README.md` 与 `doc/f_svg-M2设计.md:512` 把 `CssParser.cj` 列为解析层文件，读者按目录找解析入口会落在空文件上（设计文档属其它部分，此处只作提示）。
- **建议**：按 `fix-plan.md:39` 删掉该文件；若要保留作为分层占位，至少补版权头与一句「解析实现见 `CssStyleSheet.cj`，本文件无代码」的职责注释。

### [轻微][存量] 两套选择器表示并存，遗留分支全部不可达（`cssPartMatches` 等 3 处）

- **位置**：`f_svg/src/CssSelector.cj:345-370`（`cssPartMatches`，唯一调用点在 `:271` 的 `else` 分支）、`:71-95`（`CssSelectorPart.toString` 的 legacy 分支）、`:152-168`（`CssSelector` 特异性计算的 legacy 分支）、`:48-55`（`typeName` / `id` / `classes` / `combinator` 与 `simples` 重复表达同一信息）
- **来源**：存量（工作区快照，`71190070ec` 2026-11-05）
- **判据**：review-checklist §1（不可达分支 / 无调用者）、§2（同一语义的两种表示）
- **证据**：静态确定 —— `CssSelectorPart.simples` 恒非空：`CssSelectorPart` 只有 `:225` 一个构造点（`grep "CssSelectorPart("` 全仓仅此一处，`init` 为包内可见），传入的 `sequence.simples` 在 `CssSelector2.cj:269-271` 为空时直接抛异常；因此 `part.simples.size > 0` 恒真，`else` 分支与 `cssPartMatches` 永不执行
- **描述**：M5 引入 `simples` 有序简单选择器后，旧的 `typeName` / `id` / `classes` 三个字段被保留作「新模型与原模型并存」（`CssSelector2.cj:198` 注释自述）。并存的结果是：同一份信息存两份、三处 `if (simples.size > 0) … else …` 的旧分支成为不可达代码，读者会以为还存在「只填旧字段」的构造路径。`combinator` 字段还与 `CssSelector.combinators` 重复（前者仅测试 `CssSelector_test.cj:80-85` 读取）。
- **建议**：删 `cssPartMatches` 与三处 legacy 分支，让 `toString` / 特异性 / 匹配只走 `simples`；`typeName` / `id` / `classes` 若要保留给索引使用（`CssSelectorIndex` 依赖 `rightmost.id` / `classes[0]` / `typeName`），改为 `CssSelectorPart` 上的只读派生方法（遍历 `simples` 取第一个 Id / Class / Type），避免两份状态漂移。

### [轻微][存量] `while (true)` 循环之后的 `false` 不可达（两处）

- **位置**：`f_svg/src/CssSelector.cj:297`（`Descendant` 分支）、`:315`（`GeneralSibling` 分支）
- **来源**：存量（工作区快照，`71190070ec` 2026-11-05）
- **判据**：review-checklist §1（`return` 之后的同层语句 / 恒不执行分支）
- **证据**：静态确定 —— 两个 `while (true) { match (current) { … } }` 内部的 `Some` 分支要么 `return true`、要么回写 `current` 继续循环，`None` 分支 `return false`，没有 `break`，循环不存在正常出口
- **描述**：与 part8 在 `CssCalc.cj:133` / `:160` 记录的是同一形态：编译器不报「不可达代码」warning，代码留在文件里会让人误以为存在「循环结束后返回 false」的语义。仓颉要求函数所有路径返回值，这两个 `false` 可能是为满足返回检查而写——若是，则应改成「`while` 带显式条件 + 尾部统一 `return false`」，让控制流与阅读一致。
- **建议**：把循环改为 `while (current.isSome())` 形式（内部用 `match` 解包），或直接删掉这两行；不要保留「不可达但为编译而写」的语句。

### [轻微][存量] `cssAttributeMatches` 的第二个 `case Exists` 分支不可达

- **位置**：`f_svg/src/CssSelector2.cj:860-887`（`:865-868` 已对 `Exists` 提前 `return true`；`:872-874` 的 `case Exists => true` 永远收不到）
- **来源**：存量（工作区快照；`git blame` 指向 `6296495ffd` 2026-11-06）
- **判据**：review-checklist §1（被前面 case 完全覆盖的分支）、§2（同一判定写了两遍）
- **证据**：静态确定 —— 第一个 `match (selector.op)` 里 `case Exists => return true` 直接返回，控制流不会再到第二个 `match (selector.op)` 的 `Exists` 分支；`CssAttributeOperator` 只有 7 个 case，无别名路径
- **描述**：两个 `match` 对同一个判别值开关两次，第二个保留 `Exists` 只为枚举穷尽，编译器不会告警；读者会误以为存在性判定有两种走法，而 `:870-871` 的 `toAsciiLower` 也只对非 `Exists` 生效。
- **建议**：删掉 `:872-874` 的 `case Exists => true`，或把两个 `match` 合并成一个（`case Exists => true` 只留一处，`expected` / `left` / `right` 的求值下沉到需要值比较的分支）。现有用例 `CssSelectorAttributeM5_test.cj:40`（`[fill]`）即可覆盖。

### [轻微][存量] 兄弟 / 同类型序号的 5 个遍历函数同构，`LastChild` 还扫了两遍父容器

- **位置**：`f_svg/src/CssSelector2.cj:651-668`（`cssElementSiblingIndex`）、`:670-683`（`cssElementSiblingCount`）、`:686-705`（`cssOfTypeIndex`）、`:707-722`（`cssOfTypeCount`）、`:725-742`（`cssPreviousElementSibling`）；双扫点 `:779`、`:783`
- **来源**：存量（工作区快照，`6296495ffd` 2026-11-06）
- **判据**：review-checklist §2（换控制流 / 只改判定条件的重复逻辑）
- **证据**：静态确定 —— 五个函数体逐行对齐：取 `element.parent` → `for (node in parent.children)` → `match ElementNode` → 各自维护计数 / 前驱
- **描述**：差异只有三处（是否按 `child.tag` 过滤、是否提前 `return`、是否保留 `previous`），属**可参数化**的差异而非业务差异。重复已经带来实际代价：`:779` / `:783` 的 `LastChild` / `LastOfType` 先算 index 再算 count，对同一个父容器扫两遍；`:781` / `:785` 的 `NthChild` / `NthOfType` 只算 index 但仍要线性扫到目标为止。这些都在每个元素 × 每条候选规则的匹配路径上。
- **建议**：合并为一次遍历的收集函数，例如 `private func cssSiblingStats(element: SvgElement, sameType: Bool): (Int64, Int64, ?SvgElement)`（index、count、前一个兄弟），伪类求值时按需取字段；`LastChild` 从两次 O(n) 降为一次。注意保留现有语义：忽略文本 / 注释 / PI 节点、根元素返回 `(1, 1, None)`。

### [轻微][存量] `cssClassListContains` 与 `splitCssWhitespaceWords` 是同一套「空白分词」的两份实现

- **位置**：`f_svg/src/CssSelector.cj:373-389`（逐词比较、命中即返回）与 `f_svg/src/CssSelector2.cj:889-906`（切出 `Array<String>`）
- **来源**：存量（工作区快照；两处分属 `71190070ec` 与 `6296495ffd`）
- **判据**：review-checklist §2（同语义、不同控制流）
- **证据**：静态确定 —— 两者的分词规则完全相同（`isCssSpace` 分隔、跳过连续空白、丢掉空词），只是一处「边切边比」、一处「先物化再比较」
- **描述**：`cssAttributeMatches` 的 `Includes`（`CssSelector2.cj:875-881`）为了做一次 `word == right` 判定，先 `splitCssWhitespaceWords(left)` 分配一个 `Array<String>`（每个词一个 `String` 切片），再线性比较；而 `cssClassListContains` 已经是同语义的零分配版本。类选择器每元素每次匹配走后者、属性 `~=` 走前者，两条路径的成本差一个数量级（在属性值很长、`~=` 选择器很多的样式表里）。差异点只有「是否需要全部词」——两处都不需要。
- **建议**：把 `cssClassListContains` 提升为通用谓词（如 `cssWordListContains(text, word)`），`Includes` 直接调用。注意 `splitCssWhitespaceWords` 本身**不能删**：它是 `internal` 且另有 10 处调用（`SvgComputedStyle.cj:390`、`:646`、`:691`、`:705`，`SvgPaintOrder.cj:63`、`:118`，`SvgStyleResolver.cj:667`、`:1031`，`SvgTransformOrigin.cj:28`、`:119`），需要「全部词」的场景保留数组版本；重复点只在 `Includes` 这一处「拿数组只为做一次包含判定」。

### [轻微][存量] `CssMediaQueryItem.toString` 在循环内反复 `StringBuilder.toString()` 判空

- **位置**：`f_svg/src/CssMedia.cj:69-86`（`:75` `if (out.toString().size > 0)`、`:82` 再判一次）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §6.4（循环内重复物化）、§10（可读性）
- **证据**：静态确定 —— 每次迭代都把已累积内容整体复制一遍，复杂度 O(k²)；`k` 为特征数（现实中 1–3），绝对值很小
- **描述**：判空意图只是「是不是第一个特征」，用布尔变量即可；现在的写法既多分配又把「分隔符逻辑」藏进字符串长度判断里，读者需要反推。同类写法在 `CssMedia.cj:82` 又重复一次（`out.toString().size == 0`）。
- **建议**：用 `var first = true`（或先拼接媒体类型、`features.size` 直接判断）控制 `" and "` 的插入，末尾按 `mediaType` / `features` 是否为空返回 `"all"`。

<!-- 第 10 部分 -->

### [严重][存量] 嵌套 `@media` 互递归没有深度上限：一段刻意嵌套的 CSS 即可打穿栈

- **位置**：`f_svg/src/CssStyleSheet.cj:205-273`（`parseCssRuleBlock`）、`f_svg/src/CssStyleSheet.cj:276-307`（`parseCssMediaBlock`）；递归边是 `222-226`（遇到 `@media` 无条件转出）与 `301-304`（内层块再调回 `parseCssRuleBlock`）
- **来源**：存量（快照模式无基线；`git blame` 无 diff 可比）
- **判据**：review-checklist §4（无界递归：深度由输入决定，非不可变常量限定）
- **证据**：静态确定 —— `parseCssRuleBlock` 在 `223` 判断 `tokens[i].text.toAsciiLower() == "@media"` 后于 `224` 调 `parseCssMediaBlock`，后者在 `303` 用 `[i + 1, blockEnd)` 再调 `parseCssRuleBlock`；整条链上没有 `depth` 形参、没有层数上限、也没有对 `text.size` 的上限（`parse` 只做 `CssLexer(text).tokenize()`，`170`）。函数注释 `203` 自己写着「`media` 为外层 `@media` 条件（嵌套时由内层覆盖）」，说明嵌套是设计内行为，递归一定可达，与规范是否允许嵌套无关
- **描述**：`@media a{@media a{…}}` 每层产生 2 个栈帧，深度等于输入里 `@media {` 的层数，完全由外部控制。入口是 `SvgStyleResolver.cj:216`（`<style>` 元素文本）与 `SvgStyleResolver.cj:226`（内联 `style` 属性，外面再包一层 `*{…}`），即任意被解析的 SVG 文档。后果是栈溢出（`StackOverflowError` 级别的 fatal error，不是 `SvgException` 可捕获的业务异常），调用方没有降级手段
- **建议**：给 `parseCssRuleBlock` 加 `depth: Int64`（初值 0，`parseCssMediaBlock` 透传 `depth + 1`），超过常量（建议 16，量级对齐 `CSS_CALC_MAX_DEPTH`，`CssCalc.cj:21`）时写 warning 并用已有的 `skipCssAtRuleWithin`（`427-444`）整块跳过；同时在 `CssStyleSheet.parse` 入口对 `text.size` 设上限并复用 `SvgErrorKind.Limit`。补两条用例：16 层正常、17 层告警且不再递归

### [一般][存量] `begin` / `end` 时间：写入侧能产出列表、`id.end+offset`、`id.repeat(n)`，读取侧只认单值

- **位置**：`f_svg/src/SvgAnimation.cj:83-104`（`parseSvgTimeValue`）、`106-115`（`parseSvgTimeReference`）；写入侧 `f_svg/src/SvgBegin.cj:59-70`（`after(id, offset)` 产出 `a.end+1s`）、`72-76`（`repeatOf` 产出 `a.repeat(2)`）、`92-105`（`join` + `toString` 用 `"; "` 拼列表）；消费侧 `f_svg/src/SvgTimeline.cj:709-752`（`resolveAnimationTime`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：库产出的形式库自己解析不了）
- **证据**：静态确定 —— `SvgAnimateM7_test.cj:98` 直接断言 `SvgBegin.offset(0.0).join(SvgBegin.after("a", 1.0))` 落盘为 `"0s; a.end+1s"`；而 `resolveAnimationTime` 在 `716` 取整串 `spec.beginRaw` 后，依次只调 `parseSvgTimeReference`（`720`，只接受整串 `endsWith(".begin")` / `endsWith(".end")`，`108-113`）、`isSvgEventTime`（`740`，按 `;` 拆分但只用于判事件名）、`parseSvgTimeValue`（`744`，交给 `tryParseSvgFloat`，含 `;`/`+` 必失败），中间没有拆分点。`"a.end+1s"`、`"0s; a.end+1s"`、`"a.repeat(2)"` 三种形式都落到 `747-748` 的 warning + `0.0`
- **描述**：三个可观测后果：①SMIL 合法的多值 `begin`（`begin="0s; 5s"`、链式触发）被当成无法解析 → 按 0 处理，后续触发时机整体丢失；②`synchronize` 语义（`id.end+1s`）读不回来，`SvgBegin.after` 写出去的值自己消费不了；③`SvgBegin.repeatOf` 的 `id.repeat(n)` 同样读不回。三者都不报错、只写一条 warning，最终表现为动画在错误时刻开始
- **建议**：新增 `parseSvgTimeList(text)`：先 `splitSvgSemicolon` 拆分，再对每项匹配 `id.(begin|end|repeat)\(?…\)?([+-]<clock>)?` 与纯 clock-value，返回列表；`resolveAnimationTime` 取「已触发且最小」的项。短期至少让 `id.begin±offset` 可解析，并让写入侧不再产出读取侧不支持的形式（或在这些 `SvgBegin` 工厂方法的文档注释里标明「播放侧仅支持单值」）。补往返用例：写→读→同一时间点出同一属性值

### [一般][存量] `CssStyleSheet.toString()` 丢弃 `@font-face` / `@color-profile`，两个 at-rule 的 `toString` 各自丢字段

- **位置**：`f_svg/src/CssStyleSheet.cj:180-186`（只遍历 `this.rules`）、`117-119`（`CssFontFaceRule.toString` 只拼 `font-family`）、`133-135`（`CssColorProfileRule.toString` 在 `src` 为 `None` 时输出 `src:  `）
- **来源**：存量
- **判据**：review-checklist §11（数据丢失 / 契约与实现不符）+ §2（同一份信息的两种不一致表示）
- **证据**：静态确定 —— `parse` 把两类 at-rule 收进独立数组（`146-148`、`352-356`、`390-394`），`toString` 的循环体只有 `for (rule in this.rules)`（`182`），`fontFaces` / `colorProfiles` 从未被读出。`CssFontFaceRule` 持有 `weight` / `style` / `src`（`102-107`）但 `toString` 一个都不输出；`CssColorProfileRule.toString` 的 `src ?? ""` 在缺失时生成两条空格 + 空值的非法声明。附带一条：`srcPresent`（`105`）与 `src.isSome()` 恒等（唯一构造点 `354` 两者同步设置），是同一事实的两份表示，外部调用方无从判断该信哪个
- **描述**：`parse → toString → parse` 一轮就静默丢掉全部 `@font-face` 与 `@color-profile`，无告警；`@media` 因为挂在 `CssRule.media` 上反而能保住。把 `f_svg` 当无损 DOM 用的下游（先解析、改几处、再输出）会丢字体别名与色彩配置
- **建议**：`CssStyleSheet.toString` 按源顺序输出三类规则（要么给两个 at-rule 补 `order`，要么固定 `rules → fontFaces → colorProfiles` 并在注释写明顺序不保真）；`CssFontFaceRule.toString` 输出已有的 `weight` / `style` / `src`；`CssColorProfileRule.toString` 在 `src` 为 `None` 时省略该声明；`srcPresent` 改为 `src.isSome()` 派生属性或直接删掉。补一条三类规则混排的往返用例（现有 `CssStyleSheet_test.cj:124-131` 只测简单规则）

### [一般][存量] 解析覆盖率按整幅画布固定分配两份 8 B/px 数组，小图形也付全额

- **位置**：`f_svg/src/SvgAnalyticRasterizer.cj:164`（`coverage: Array<Int64>`）、`f_svg/src/SvgAnalyticRasterizer.cj:200-204`（`accumulated: Array<Float64>`）；调用点 `f_svg/src/SvgRasterizer.cj:280-286`（每个填充形状一次，传的是 `this.bitmap.width/height` 而不是形状包围盒）
- **来源**：存量
- **判据**：review-checklist §5（按不可信像素数一次性物化、无分块/拒绝路径）
- **证据**：静态确定 —— 两份数组都是 `width * height` 个 8 字节元素 ⇒ 16 B/px，且同时在生命周期内（`164` 创建、`217` 返回，中间 `accumulated` 一直存活）。量化：1000² = 16 MB；3840×2160（4K）= 133 MB；默认 `maxPixels` = 64 Mi px（`SvgBitmap.cj:230`，校验在 `281-282`）打满时两份数组约 1.0 GiB，再加位图本身 256 MiB。local 分档只在 ≤ 1,048,576 px（8 MiB）时生效（`93-97`），所以 1024×1024 以上一律走堆
- **描述**：成本与实际绘制面积无关：4K 画布上一个 10×10 的矩形也要为整幅画布付 133 MB，且每个填充形状重复一次（GC 压力随形状数线性叠加）。上限由 `maxPixels` 兜住，所以不是无界 OOM，但默认上限下单次渲染的峰值已到 GiB 量级，容器内存 limit 常见的 1～2 GiB 会直接触发 OOM Killer。这一条与「优化方案 1」同源：修法是按形状包围盒裁剪，而不是调大/调小 `maxPixels`
- **建议**：把 `computeCoverage` 已有的轮廓 bbox（`SvgRasterizer.cj:291-310`）提前算好，只把 bbox 交给 `analyticCoverage` 并返回 `(coverage, offsetX, offsetY)`；`width` / `height` / `row` 全改局部坐标。短期若不做，至少在 `analyticCoverage` 入口对 `width * height` 设一个显式的「解析档专用」上限并抛 `SvgErrorKind.Limit`，让拒绝发生在分配之前

### [一般][存量] 行内事件数按活跃边数平方增长且强制落 local，local region 耗尽后直接抛 Error

- **位置**：`f_svg/src/SvgAnalyticRasterizer.cj:239-241`（`events` 固定 `@ local!`，注释自述无法随档位切换）、`244-251`（每边 2 个端点事件）、`252-267`（活跃边两两求交，双层循环）、`141-149`（`analyticCoverage` 直接委托，无 try/catch）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 + 无拒绝路径）、§9 约束 4（local region 有全线程上限）、§12.1（共享资源预算无同步手段）、§14（回退只写进设计文档）
- **证据**：静态确定（规模无上限、落点固定、无 catch）+ 需实测（多大几何会真顶穿）
- **描述**：一行的 `events` 元素数上界 = `2 + 2A + A(A−1)/2`（`A` = 该行活跃边数），由路径段数决定，**不经过 `maxPixels`**（那条只限输出像素数）。`A = 2,000` 时约 200 万事件（16 MB）、`A = 10,000` 时约 5,000 万事件（400 MB+），而 `events` 是 `@ local!`，8 MiB 门限（`93-97`）只管 `accumulated`、管不住它；默认 local region 是**全线程合计 256 MB**（`docs/LocalMode.md:193`），单次调用即可吃满。抛出的 `LocalRegionOutOfMemoryError` 在全仓 `.cj` 里零 catch（只有 `f_llm/src/store/KnowledgeChunker.cj:95` 的注释提到），`analyticCoverage` 也没有回退分支 —— `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/design.md:150-154` 明确记录「本次不落地回退」，所以这是**已知并接受的缺口**，不是隐瞒，但对调用方而言仍然是「合法输入 → 不可捕获的 Error」
- **建议**：①先给上界：按 `A` 预估容量并在超过常量时抛 `SvgErrorKind.Limit`（拒绝发生在分配前），同时给 `events` 一个固定容量上限；②`events` 改为按档位分配（堆档位用堆），否则任何回退路径仍会申请 local；③长期改扫描线 + 活跃边表，行内不再枚举全部点对（见优化方案 3）

### [轻微][存量] 三份逐行相同的插入排序

- **位置**：`f_svg/src/SvgAnalyticRasterizer.cj:428-440`（`sortAnalyticHits`）、`442-454`（`sortAnalyticValues`）、`462-474`（`sortAnalyticLocalValues`）；测试内另有一份 `f_svg/src/SvgAnalyticRasterizer_test.cj:327-339`（`sortDenseCrossings`）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 四段函数体的控制流、比较方向（`>`）、下标写法逐行一致，差异只有元素类型（`SvgAnalyticHit` / `Float64` / `SvgDenseCrossing`）与 `exclave` / mode 标注
- **描述**：同一份「按 x 升序稳定插入排序」写了四遍。`sortAnalyticLocalValues` 的形参是 `ArrayList<Float64> @ local!`，泛型实参不能带 mode，必须保留（注释已说明）；其余三份只是「排 `ArrayList`」，`std.sort.sort` 已覆盖
- **建议**：`sortAnalyticHits` / `sortAnalyticValues` 改用 `std.sort.sort`（注意它是原地且默认不稳定，若「同 x 保持插入顺序」影响 winding 结果需显式 `stable: true` 并补同 x 用例）；测试侧那份同理。`sortAnalyticLocalValues` 保留并保留现有注释

### [轻微][存量] 测试里 6 份逐像素最大通道差比较循环，且每份都写 `@Fail` + `@Assert` 双保险

- **位置**：`f_svg/src/SvgAnalyticRasterizer_test.cj:58-72`、`358-372`、`395-411`、`430-445`、`499-514`、`535-549`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」+ §1「恒真分支/冗余断言」
- **证据**：静态确定 —— 六段都是「遍历参考图 → 取 `Int64(round(x * 255))` → 与 `pixels[i*4+3]` 求绝对差 → 记录 worst/worstIndex → `if (worst > 2) { @Fail(...) }` → `@Assert(worst <= 2)`」，只有画布尺寸、参考图来源与失败文案不同（`407-409` 的文案格式还与其余五处不一致）
- **描述**：`@Assert(worst <= 2)` 与前一行的 `@Fail` 判定同义，是同一条件的第二遍断言，失败信息反而更弱；六份复制让「改容差 / 改比较通道」时有五处需要同步。测试代码重复的直接影响面是维护成本，不影响产品行为
- **建议**：抽 `assertMaxChannelDiff(bitmap, reference, tolerance: Int64, label: String)` 覆盖六处，只保留一条断言；`polygonCirclePath` / `localModeCirclePath` 两份重复是有意的测试隔离（后者注释已声明），不在此列

### [轻微][存量] 四个手写 max/min 与 `std.math` 在同一文件混用，`NaN` 语义没有用例固定

- **位置**：`f_svg/src/SvgAnalyticRasterizer.cj:45-75`（`analyticMax` / `analyticMin` / `analyticMaxReal` / `analyticMinReal`），对照同文件 `179-180`（已直接用 `min` / `max` 处理 `Float64`）
- **来源**：存量
- **判据**：review-checklist §2「同语义两套实现」+ §11「语义与命名不符（读者无法判断差异是否有意）」
- **证据**：静态确定（重复关系）；待确认（`std.math.max/min` 是否有 `Int64` 重载、`NaN` 传播语义是否与手写版一致）
- **描述**：`analyticMinReal` 等实现用 `if (left < right)` 比较，`NaN` 参与时恒取 `right`，与 `std.math` 的 `fmax` 语义不同；现有用例没有 `NaN` 坐标。混用会让读者以为四个 helper 有特殊语义，实际只是历史遗留
- **建议**：确认 `std.math` 的重载后统一替换并删除四个 helper；若刻意保留「不传播 NaN」，就改成一个带注释的具名函数并补 `NaN` 用例把行为固定下来

### [轻微][存量] `CssStyleSheet.parse(text)` 单参重载把解析告警整包丢弃

- **位置**：`f_svg/src/CssStyleSheet.cj:164-167`
- **来源**：存量
- **判据**：review-checklist §3「静默」（失败不可观测）
- **证据**：静态确定 —— 单参重载内部 `let warnings = ArrayList<String>()` 后调双参重载，`warnings` 再无使用
- **描述**：对整表语法错误（不支持的 at-rule、无法解析的选择器、缺右花括号）的输入，调用方拿到的是空/残缺样式表，返回值与异常都不带任何提示，「样式没生效但没人知道为什么」。双参重载可用，但对不传 warnings 的多数调用点等于没有诊断
- **建议**：至少在该重载的文档注释里写明「告警被丢弃，需要诊断请用双参重载」；更好的是把告警挂成 `CssStyleSheet` 的只读字段（`let warnings: Array<String>`），解析后随时可取

### [轻微][存量] `isSvgEventTime` 的注释停留在 M2，与现行语义相反

- **位置**：`f_svg/src/SvgAnimation.cj:117`（注释「事件型 begin（click 等）在 M2 不支持」）
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 事件触发已实现：`SvgTimeline.cj:377-382`（`fireEvent` 按 `;` 列表匹配）、`SvgTimeline.cj:740-742`（把事件型时间记为「等待显式触发」并返回 `Float64.Inf`），用例 `SvgAnimationControlM6_test.cj:93-117` 覆盖 `CLICK` / `mouseout` / `accessKey(k)`
- **描述**：函数现在的真实语义是「这是需要显式触发的事件型时间」，注释却说「不支持」，后来的维护者容易据此删掉或绕开这条分支
- **建议**：改为「事件型时间（`click`、`accessKey(...)`、`wallclock(...)` 等）解析为 `Float64.Inf`，等待 `SvgTimeline.fireEvent` 显式触发」，去掉阶段号

<!-- 第 11 部分 -->

### [一般][存量] #1 `SvgAutoSize` 的回退分支覆盖已确定的另一轴，auto 尺寸被改成 300×150

- **位置**：`f_svg/src/SvgAutoSize.cj:84`、`f_svg/src/SvgAutoSize.cj:95-98`、`f_svg/src/SvgAutoSize.cj:108-111`，落点 `f_svg/src/SvgAutoSize.cj:116-129`
- **来源**：存量（`git blame -L 95,98` → `37a851a592` 2026-11-07）
- **判据**：review-checklist §11「契约与实现不符」；契约源 `f_svg/doc/f_svg-M6设计.md:75`（`width`/`height: auto` 按内容包围盒确定尺寸）与 `:307`（根 `svg`：auto 时按内容包围盒 + `viewBox` 比例确定）
- **证据**：静态确定 —— `SvgViewport.from`（`SvgAutoSize.cj:42`）已经把显式轴的数值解析出来（`SvgViewport.cj:145-155` 对绝对值直接返回，`<svg height="40">` ⇒ `viewport.height == 40`），但单轴 auto 在「无内容 + 无 viewBox」时直接 `return fallbackAutoSize(fallbackWidth, fallbackHeight, warnings)`，返回两个 fallback，显式轴被丢弃
- **描述**：`<svg width="auto" height="40"></svg>` ⇒ `contentWidth == 0`、无 viewBox ⇒ 返回 `(300, 150)`，高度从 40 变成 150，并输出 warning「无法确定（无 viewBox 且无可渲染内容）」——实际高度是确定的，文案也与事实不符。对称路径 `height="auto" width="40"` 会把宽度改成 300（`:108-111`）。同一根因还覆盖：双轴 auto 但内容只有一维（如水平线 `height == 0`、`width == 100`）时整体回退 300×150（`:61-85`）。后果是画布尺寸错误（下游按返回尺寸建位图，宽高比随之错误），不是崩溃
- **建议**：回退只填「未知轴」——`fallbackAutoSize` 增加「已知轴值 + 是否已知」参数，或调用处写成 `SvgAutoSizeSize(if (contentWidth > 0.0) contentWidth else viewport.width, height)` 这类形式；warning 只描述真正无法确定的轴。`SvgAutoSizeM6_test.cj` 补「auto + 显式另一轴 + 空内容」用例

### [一般][存量] #2 `svgBidiClass` 的 AL 判定分支恒不可达，阿拉伯补充区 / 表现形式区分类错误

- **位置**：`f_svg/src/SvgBidi.cj:172-174`（外层条件 `169-171`），兜底 `177-179`、`198-202`
- **来源**：存量（`git blame -L 170,176` → `420059ecf0` 2026-11-06）
- **判据**：review-checklist §1「恒真恒假分支」、§11「契约与实现不符」
- **证据**：静态确定 —— 外层区间是 `[0x0590,0x05FF] ∪ [0xFB1D,0xFB4F] ∪ [0x07C0,0x089F] ∪ [0xFB50,0xFDFF] ∪ [0xFE70,0xFEFF] ∪ [0x10800,0x10FFF]`，内层 `0x0600-0x06FF` 与之交集为空（`0x05FF < 0x0600`），`return SvgBidiClass.AL`（`173`）永不执行；阿拉伯主区间的 AL 由 `177-179` 兜住，所以内层是纯死分支
- **描述**：死分支掩盖了两处真实分类错误——(a) `0xFB50-0xFDFF`（Arabic Presentation Forms-A）与 `0xFE70-0xFEFF`（Forms-B）落进 `175` 的 `return R`，按 UAX#9 应为 AL；(b) `0x0750-0x077F`（Arabic Supplement）、`0x08A0-0x08FF`（Arabic Extended-A）不在任何区间，落到 `201` 的默认 `L`（比 R 更离谱）。函数注释只说「UAX#9 子集」，`SvgBidiM5_test.cj:34-44` 也只断言了 `0x627`；由于 `svgBidiLevels` 的 W3 会把 AL 归一成 R（`241-243`），渲染结果不因此改变，受影响的是**公开 API** `svgBidiClass`（README `559` 行已列入公开清单）的下游调用者
- **建议**：把 `172-174` 改为对 `0xFB50-0xFDFF` / `0xFE70-0xFEFF` 的显式 AL 判定，并在区间表里补 `0x0750-0x077F` / `0x08A0-0x08FF`；更好的做法是拆成「R 区间表 / AL 区间表」两张独立判定，避免用嵌套 `if` 表达归属。`SvgBidiM5_test.cj` 补 `0xFB50` / `0xFE70` / `0x0750` 三个断言，否则这类恒假分支永远不会被测试发现

### [一般][存量] #3 内容包围盒用 fallback 视口，而非同函数已解析的视口

- **位置**：`f_svg/src/SvgAutoSize.cj:46-51`（对照 `:42` 的 `viewport`）
- **来源**：存量（`git blame` → `37a851a592` 2026-11-07）
- **判据**：review-checklist §11「契约与实现不符」+ §10 正确性（同一函数内两套视口口径）
- **证据**：待确认 —— 缺「auto 尺寸下百分比内容相对哪个视口解析」的规格；代码层面静态确认 `viewport`（`:42`，按 `width`/`height` 属性解析，百分比相对 fallback）与传给 `SvgBBoxRequest` 的 `viewportWidth: fallbackWidth, viewportHeight: fallbackHeight`（`:49-50`）不是同一个值
- **描述**：`<svg width="50%" height="auto"><rect width="10" height="100%"/></svg>`：`viewport.width == 150`，bbox 却按 300 计算 `rect` 的 `height="100%"`，`contentHeight` 被放大一倍，最终 `height` 推导成 150 而不是 75。触发组合是「auto 轴 + 另一轴为百分比 + 内容使用百分比长度」；若产品语义规定百分比一律相对 fallback（现有文档未写），则不是缺陷
- **建议**：把 `viewport.width` / `viewport.height` 传给 `SvgBBoxRequest`；或在 `doc/f_svg-M6设计.md` §8.3 明确百分比解析基准，并在代码注释里引用该口径

### [轻微][存量] #4 `SvgBitmap` 的尺寸守卫只防 `Int64` 溢出，等于没有内存上限

- **位置**：`f_svg/src/SvgBitmap.cj:93-104`（守卫 `97-100`，分配 `103`）
- **来源**：存量（`git blame -L 93,96` → `207c0b7adb` 2026-11-05）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— 三个条件（`> 0x7FFFFFFF` 与 `width > (2^61-1) / height`）合起来只保证 `width*height*4` 不溢出 `Int64`，不约束可用内存；异常文案却写「位图像素数超出可分配上限」（`99`）。`SvgBitmap(30000, 30000)` 三道守卫全部通过，随后物化 9e8 像素 × 4 B = 3.6 GB；失败形态是分配失败，而不是同族接口 `SvgRenderOptions.validatePixels`（`274-284`）承诺的 `Limit`
- **描述**：仓内现有分配点各有独立上限——渲染默认 64 M 像素（`SvgRenderOptions.maxPixels`，`SvgBitmap.cj:230`）、PNG 解码 16 M（`SvgPngDecoder.cj:23,92-104`）、pattern tile 4 M（`SvgPatternSampler.cj:22,230-243`）——因此**当前渲染链路不会被这份守卫坑到**；风险留给直接使用公开构造的下游，以及后续新增的分配点（三套上限各写一遍，新点容易漏）
- **建议**：`SvgBitmap.init` 增加 `maxPixels!: Int64 = 64 * 1024 * 1024`（与 `SvgRenderOptions` 对齐），超限抛 `SvgException(kind: Limit)`，保留溢出守卫作为第二道防线

### [轻微][存量] #5 `SvgAttribute.toString()` 输出未转义的 `name="value"`

- **位置**：`f_svg/src/SvgAttribute.cj:30-32`
- **来源**：存量（`git blame -L 30,32` → `18a60454f0` 2026-11-05）
- **判据**：review-checklist §11「语义与命名不符」、§10 安全性（转义）
- **证据**：静态确定 —— `toString` 直接拼 `'${this.name}="${this.value}"'`，未调用任何转义函数；正式写路径是转义过的：`SvgElement.cj:424` 用 `escapeSvgAttribute`（`718-730`，转 `& < > "`），`f_xml` 侧另有 `Escaper`。仓内 `SvgAttribute.toString()` 无生产调用者（`grep` 仅 `SvgElement_test.cj:243` 断言其输出）
- **描述**：`SvgAttribute` 是公开 struct 且实现 `ToString`，输出形状就是一段可拼进标签的属性文本，最容易被下游当成序列化入口。值里出现 `"` 会提前闭合引号、出现 `&` 会破坏实体，最终产出畸形 XML 或把调用方数据注入成额外属性。当前不是现网缺陷（无人调用），但它是本模块唯一一条绕过 `Escaper` 的输出旁路
- **建议**：`toString` 复用 `escapeSvgAttribute(this.value)`（`internal`，同包可用，一行改动），或在文档注释明确「仅供调试，序列化必须走 `SvgWriter`」

### [轻微][存量] #6 `SvgRgba.toString()` 把预乘通道伪装成 CSS `rgba()`

- **位置**：`f_svg/src/SvgBitmap.cj:76-78`
- **来源**：存量（`git blame` → `a061fe1ef` 2026-11-07）
- **判据**：review-checklist §11「语义与命名不符」
- **证据**：静态确定 —— 类型注释（`22`）与 `fromColor` / `over` 都表明字段是**预乘**分量；`toString` 却输出 `rgba(r,g,b,a)`，而 CSS `rgba()` 的三个分量是**非预乘**，两者只在 `alpha == 1` 时相等
- **描述**：`SvgRgba(1.0, 0.0, 0.0, 0.5)`（半透明纯红，预乘）会被打成 `rgba(1,0,0,0.5)`，按 CSS 解析是「通道值 1/255 的近黑红」，与「纯红半透明」相差极大。仓内除测试外无调用者，属潜在误用
- **建议**：输出改成明确标记的调试格式（如 `SvgRgba(premul: r,g,b,a)`），或先 `toColor()` 反预乘再输出 CSS `rgba()`

### [轻微][存量] #7 `animateTransform` / `animateMotion` 未暴露父类已有的动画属性，且追加后链式落点是宿主元素

- **位置**：`f_svg/src/SvgAuthoringBuilder.cj:317-347`（`animateTransform`）、`350-381`（`animateMotion`）
- **来源**：存量（`git blame` → `481ce3dcee` 2026-11-08）
- **判据**：review-checklist §14.1「只做了一半的分支」、§11「契约与实现不符」
- **证据**：静态确定 —— `SvgAnimateTransform <: SvgAnimate`（`SvgAnimateTransform.cj:31`），父类提供 `end` / `repeatDur` / `calcMode` / `keyTimes` / `keySplines` / `additive` / `accumulate`（`SvgAnimate.cj:157/181/202/214/223/232/241`）；同文件 `animate`（`272-314`）把它们全部接了出来，`animateTransform` 一个都没接，`animateMotion` 只接了 `keyTimes`。两个方法都以 `this.cursor.appendElement(element)` 结尾（`345`/`379`），`cursor` 仍指向宿主元素，而 `attr` / `id` / `transform`（`256-269`）都作用于 `cursor`——`builder.animateTransform(...).attr("calcMode", "spline")` 会把属性写到宿主图形上
- **描述**：要给 `animateTransform` 设 `calcMode="spline"` + `keySplines`（缓动曲线）时链式 API 无处落脚，只能遍历 DOM 找最后一个动画子节点补设。README `270` 行「含样式、分组、动画、输出与 `save`」与 `388-396` / `423` 的示例都没有说明这层限制
- **建议**：`animateTransform` 补齐 7 个属性（与 `animate` 对齐），`animateMotion` 至少补 `end` / `repeatDur` / `keySplines` / `additive`；或让这三个方法返回新建的动画元素而不是 `SvgBuilder`，把「继续配置」与「继续建图」分开

### [轻微][存量] #8 四个枚举的 `fromName` 是同一套 `trim` + `toAsciiLower` + `match` + 缺省

- **位置**：`f_svg/src/SvgBidi.cj:40-46`（`SvgDirection`）、`72-79`（`SvgUnicodeBidi`）、`105-112`（`SvgFontKerning`）、`f_svg/src/SvgBlend.cj:76-92`（`SvgMixBlendMode`）
- **来源**：存量（`git blame` → `420059ecf0` / `a061fe1ef`，2026-11-05 ~ 11-06）
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 四段函数体的「输入 → 输出 → 副作用」完全一致：`name.trimAscii().toAsciiLower()` → 字符串 `match` → `Some(case)` / `None`，纯函数、无副作用；差异只有 case 表、`None` 写法（`None` / `Option<SvgFontKerning>.None`）与 `SvgMixBlendMode` 多一个 `fromNameOrDefault`（`95-100`）
- **描述**：新增一个关键字枚举就要再抄一遍这 20 行；抄漏 `trim` 或 `toAsciiLower` 会让同一属性在不同枚举上大小写/空白容忍度不同（`SvgBlendM5_test.cj:59` 的 `"normal "` 用例正是在测这一点，而 `SvgBidiM5_test` 没有任何大小写/空白用例）
- **建议**：抽包内工具 `internal func svgKeywordValue<T>(table: Array<(String, T)>, name: ?String): ?T`（表规模 ≤ 12，线性查表即可），四个 `fromName` 各退化成一行表 + 一行调用；缺省语义用参数显式化

### [轻微][存量] #9 「8 位像素 → 预乘 `SvgRgba`」的换算在三处各写一遍

- **位置**：`f_svg/src/SvgBitmap.cj:149-155`（`blend` 内部）、`f_svg/src/SvgClipMask.cj:196-201`（`composite`）、`f_svg/src/SvgRenderer.cj:1151-1156`（图像采样合成）
- **来源**：存量（`SvgBitmap.blend` → `a061fe1ef` 2026-11-07；`SvgClipMask` → `3a1e78a015` 2026-11-06）
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— 三处都是 `Float64(通道) / 255.0 * alpha` 的三通道展开 + `alpha` 直传，语义与 `SvgRgba.fromColor(color, alpha)`（`SvgBitmap.cj:39-47`，本身也是 `/255 * effective`）逐项等价；`SvgClipMask` 与 `SvgRenderer` 两处都可直接写成 `SvgRgba.fromColor(...)`
- **描述**：三份实现目前一致，但这是「改一处忘两处」的典型位置——例如将来给预乘加 `clampSvgUnit` 或改定点运算，漏改一处就会出现「同一张图里普通合成与混合模式合成亮度不一致」这种极难定位的偏色。`SvgBitmap.blend`（`143-161`）与 `SvgClipMask.composite`（`193-204`）还存在「读像素 → 预乘 → 混合 → 反预乘 → 写回」整套流程的两份拷贝，差别仅后者多一个 `mode`
- **建议**：给 `SvgBitmap` 加 `blend(x:y:source:mode:)`（`Normal` 走 `over`，其余走 `blendSvgRgba`），`SvgClipMask` 内层循环退化成一次调用；换算本身收敛到 `SvgRgba.fromColor`。`SvgClipMask` / `SvgRenderer` 的改动归其所属部分评估

### [轻微][存量] #10 `SvgBlend.cj` 的 `import fountain::f_base.*` 未被使用

- **位置**：`f_svg/src/SvgBlend.cj:19`
- **来源**：存量（`git blame` → `a061fe1ef` 2026-11-07）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定（按符号名核对）—— 文件内每个符号都能定位到本包或 `std.math`：`SvgMixBlendMode` / `SvgRgba` / `SvgComputedStyle` / `clampSvgUnit` 在 `f_svg`，`min` / `max` / `sqrt` / `abs` 来自 `std.math`（`:18`）；`trimAscii` / `toAsciiLower` 是 `std.core.String` 的成员（`stdlib/libs/std/core/string.cj:1535`），不是 `f_base` 扩展（`f_base/src/ExtendString.cj:45` 提供的是 `trimAsciiBlanks`，本文件未使用）。同目录 `SvgBitmap.cj` / `SvgBidi.cj` / `SvgBounds.cj` 都没有这个 import
- **描述**：通配 import 让读者误以为本文件依赖 `f_base` 的扩展或异常类型；本文件实际只用到本包与 `std.math`
- **建议**：删除该行；若确需 `f_base` 的某个符号，改具名 import

### [轻微][存量] #11 `clampSvgUnit` 放行 NaN，`quantizeSvgChannel` 的整型转换会抛非 `SvgException`

- **位置**：`f_svg/src/SvgBitmap.cj:81-83`（`quantizeSvgChannel`）；放行点 `f_svg/src/SvgStop.cj:92-100`（`clampSvgUnit`）；入口 `f_svg/src/SvgBitmap.cj:29-34`（`SvgRgba.init` 不校验）
- **来源**：存量（`git blame` → `207c0b7adb` / `a061fe1ef`，2026-11-05 ~ 11-07）
- **判据**：review-checklist §11「边界 / 空值未处理」
- **证据**：需实测 —— `clampSvgUnit` 只有 `< 0` / `> 1` 两分支，NaN 两侧比较均为 `false`，原值返回（静态确定）；随后 `UInt8(Int64(round(NaN)))` 的转换结果需实测，按语言文档「类型转换溢出……根据默认的溢出策略将抛出异常」（`cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md:137-139`）判断会抛运行时异常，但具体异常类型未验证
- **描述**：入口是公开的 `SvgRgba` 构造与 `SvgBitmap.setPixel` / `fill`；`SvgColor` 的 alpha 已由 `clampAlpha`（`SvgColor.cj:360-365`）拒绝 NaN，但 `SvgRgba` 四个分量完全不校验。仓内正常路径进不来 NaN，属「公开 API 输入健壮性」缺口而非现网缺陷
- **建议**：`clampSvgUnit` 把 NaN 归一到 0，与 `formatSvgNumber` 对 NaN/Inf 抛 `InvalidValue`（`SvgNumber.cj:33-35`）的策略统一；`SvgRgba.init` 若要更严格，构造时做一次 `isFiniteSvgNumber` 校验

### [轻微][存量] #12 基准测试混在常规 `@Test` 套件里，`cjpm test` 每次跑重负载

- **位置**：`f_svg/src/SvgBenchmarkM4_test.cj:27-79`（20 万次 TTF 字形解析、512×512 卷积/湍流）、`f_svg/src/SvgBenchmark_test.cj:26-63`（1024×1024 渲染 + PNG 编码）、`:87-139`（三个 512²/1024² 渲染）
- **来源**：存量（`SvgBenchmark_test.cj` → `a39db4490` 2026-11-05；`SvgBenchmarkM4_test.cj` → `ddd5076d1` 2026-11-06）
- **判据**：review-checklist §14.1「半成品 / 测试组织」、`fountain-baseline.md` §8（基准必须 `-O2`）
- **证据**：静态确定 —— 5 个 `@TestCase` 全部只做 `println(...ms)`，唯一断言是尺寸/非空（`SvgBenchmarkM4_test.cj:45/54/78/101`、`SvgBenchmark_test.cj:43/56/62/82/99/118/136`），没有耗时阈值；注释自称「参考，非门禁」
- **描述**：它们与功能用例在同一个 `@Test` 体系里，`cjpm test`（默认 `-O0`）会一并执行这些循环：既得不到有意义的数据（`-O0` 数字不能当基线），又拖慢门禁。具体拉长多少需一次计时（未测，不作性能结论）
- **建议**：改用 `@Benchmark` / 独立 `bench` 包走 `cjpm bench -O2`，并在 `cjpm.toml` 把这类用例排除出默认 `test`；若必须留作冒烟，删掉计时与 `println`，只保留尺寸断言

### [轻微][存量] #13 `SvgAutoSize.rootSize` 对非正 fallback 的两条路径行为不一致

- **位置**：`f_svg/src/SvgAutoSize.cj:42`（无条件调 `SvgViewport.from`）；对照 `116-129`；抛出点 `f_svg/src/SvgViewport.cj:69-72`
- **来源**：存量（`git blame` → `37a851a592` 2026-11-07）
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：静态确定 —— `SvgViewport.from` 在 `fallbackWidth <= 0 && fallbackHeight <= 0` 时抛 `invalidValue("视口 fallback 宽高不能同时为非正数")`；`rootSize` 在 `42` 行先调用它，`43-45` 才判断是否需要 auto。同一 `(0.0, 0.0)` 入参：根元素写具体 `width`/`height` ⇒ 抛异常；根元素写 `auto` ⇒ 走 `fallbackAutoSize`（`121-122`）得到 300×150。`resolveViewportLength`（`SvgViewport.cj:135-142`）本身也把非正 fallback 替换成 300/150，说明「非正值视为缺省」是本模块既有约定
- **描述**：仓内唯一调用方固定传 `300.0, 150.0`（`SvgRenderTree.cj:298-303`），现网不受影响；但 `rootSize` 是公开 API（README `576`），下游按「缺省值语义」传 0 会拿到异常而不是 300×150
- **建议**：`rootSize` 里先归一化 fallback（非正 → 300/150）再调 `SvgViewport.from`，或去掉 `SvgViewport.from` 的「同时非正就抛」守卫，统一交给 `resolveViewportLength` 兜底

### [轻微][存量] #14 默认视口 300×150 字面量散落多处

- **位置**：`f_svg/src/SvgAutoSize.cj:121-122`（本部分）；同类字面量另见 `f_svg/src/SvgViewport.cj:37,139,141`、`f_svg/src/SvgRenderTree.cj:282`、`f_svg/src/SvgHitTest.cj:308-309`、`f_svg/src/SvgPatternSampler.cj:106-109`、`f_svg/src/SvgElementApi.cj:338`
- **来源**：存量（`SvgAutoSize` → `37a851a592` 2026-11-07；其余为各文件既有实现）
- **判据**：review-checklist §2「字面量复制」（同一组默认值散落多处，改一处即漂移）
- **证据**：静态确定 —— 均为 `300.0` / `150.0` 成对出现，语义都是「缺省 SVG 视口」
- **描述**：默认视口是跨功能约定（渲染、命中测试、pattern 采样、auto 尺寸共用），目前靠重复字面量维持一致；改缺省值需要同时改 6 个文件，漏改会让同一文档在不同入口得到不同视口
- **建议**：在 `SvgViewport.cj` 增加 `internal let SVG_DEFAULT_VIEWPORT_WIDTH/HEIGHT`（或 `SvgViewport.default()`）并全量替换

<!-- 第 12 部分 -->

### [严重][存量] #1 clipPath / mask 引用每层都分配整幅画布位图，循环引用要走到深度 64 才识别 —— 1080p 下约 1 GiB 峰值

- **位置**：`f_svg/src/SvgClipMask.cj:230`（`renderClipCoverage` 的 `SvgBitmap(width, height)`）、`275`（`renderMaskCoverage` 同）、`393` 与 `531`（每个带 clip/mask 的子元素再分配一个 `layer`）、`638-644` 与 `689-695`（`if (depth >= 64)` 才做环检测）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器 / 递归 + 每层分配」、§4「间接递归」、§6.4「同一输入重复整幅计算」
- **证据**：静态确定（分配次数与字节数可直接从代码推出；实际 RSS 未实测）—— 调用链是 `applyClipReference → renderClipCoverage → renderClipChildren → applyClipReference`。在递归到最深处时，每一层同时存活：`renderClipCoverage` 的 `bitmap`（4 B/像素）+ `renderClipChildren` 的 `layer`（4 B/像素），即 **8 B/像素/层**；另有 `coverage`（1 B/像素）在回程分配。深度上限是 64，且环检测放在 `depth >= 64` 分支里（`639`、`690`），不是进入时检测 —— 一个 `a → b → a` 的两节点环会完整跑满 64 层。
  - 1000×1000 画布：8 MB/层 × 64 ≈ **512 MB**；
  - 1920×1080 画布：约 16.6 MB/层 × 64 ≈ **1.06 GiB**；
  - 默认 `SvgRenderOptions.maxPixels = 64 * 1024 * 1024`（`f_svg/src/SvgBitmap.cj:230`）只限制**单张**位图，不限制"层数 × 单张"的累计峰值。
- **描述**：一份仅含两个互相 `clip-path` 引用的小 SVG，在默认选项下渲染 1080p 目标即可触发约 1 GiB 分配与 64 次整幅光栅化；即使不是环，10 层嵌套 clip 也有约 166 MB 的无谓峰值。这是典型的"小输入、大分配"放大面，属 OOM / 拒绝服务风险；同时环的告警只有一条（`640`），用户看不到 64 次重复光栅化的代价。
- **建议**：① 进入 `applyClipReference` / `applyMaskReference` 时先用 `containsSvgStackId` 判环（命中立即 warning + return），把深度上限降到能覆盖真实文档的量级（如 16），而不是"跑满 64 层再判断"；② 计算子元素的设备空间包围盒（含抗锯齿/描边余量），按包围盒分配小 `layer` 与覆盖率蒙版，只合成该区域；③ 若短期不改结构，至少在 `renderClipCoverage`/`renderMaskCoverage` 入口按 `SvgRenderOptions.maxPixels / (depth + 1)` 做总量校验，超限抛 `Limit`。

### [严重][存量] #2 mask 内容只按"元素自身 fill 属性的纯色"渲染：渐变/继承填充/文本/图像/evenodd 全部产生错误覆盖率，元素会整体消失

- **位置**：`f_svg/src/SvgClipMask.cj:592-622`（`drawMaskPath` 只看 `shape.fill` / `shape.fillOpacity` / `shape.opacity`，`paint.kind != Color` 直接不画，`fillRule` 硬编码 `Nonzero`）、`511-514`（`childStyle` 算了却没传给 `drawMaskPath`）、`613`；`drawMaskPath` 在 `531-533` 被调用
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 错误结果」、§14「承诺了但没实现」、§3「静默失效」
- **证据**：静态确定 —— `drawMaskPath` 的签名只有 `(child, path, matrix, bitmap, samplesPerPixel)`，没有 `SvgComputedStyle`；`shape.fill` 的实现是 `readPaint(this, "fill")`（`f_svg/src/SvgShape.cj:164-171`），只读元素自身属性，不读继承/样式表。于是：
  1. `<mask><g fill="white"><rect .../></g></mask>`：`rect` 自身无 `fill` → 走 `?? SvgPaint.of(SvgColor.Black)`（`601`）→ 蒙版位图是**黑色不透明**，亮度 0（`306-307`）→ 覆盖率 0 → 目标元素被判为完全透明而消失；
  2. `<mask><rect fill="url(#grad)" .../></mask>`：`paint.kind == Gradient` → `602` 条件不成立 → 一个像素都不画 → 覆盖率 0 → 元素整体消失（渐变蒙版是最常见的淡出写法）；
  3. `<mask><text>…</text></mask>` / `<image>` / `<use>`：`elementPathData` 对它们返回 `None`（`779-852` 只覆盖 rect/circle/ellipse/polygon/polyline/path/line），`renderMaskChildren` 走 `None` 分支继续递归（`515-527`），文本/图像子节点没有可画内容 → 覆盖率 0；
  4. `fill-rule="evenodd"` 的路径在蒙版里按 `Nonzero` 填充（`613`），孔洞被填实 → 蒙版多出本不该有的不透明区域；
  5. `display:none` / `visibility:hidden` 的子元素照常参与蒙版（clip 侧同样如此，`364-391`）。
- **描述**：README（`f_svg/README.md:218`）把 `mask` 列为"支持，亮度与 alpha 两种模式"，但实际只支持"元素自带纯色 fill 的七种形状"。上面 1/2/3 三种写法都会让被蒙版元素**静默消失**，没有任何 warning；这与"蒙版不生效"是两种完全不同的错误方向，排查成本很高。clip 侧因为覆盖率只取 alpha，纯色/黑色不是问题，但 `text`/`image`/`use` 内容同样被忽略。
- **建议**：让 `drawMaskPath` 接收 `SvgComputedStyle`（`renderMaskChildren` 已经算好 `childStyle`），用 `style.fill()` / `style.fillOpacity()` / `style.fillRule()` 代替元素属性直读；非纯色画笔走与主渲染器相同的 gradient/pattern 采样路径（`SvgRasterizer.fillGradient` 已存在）；`elementPathData` 增加文本轮廓/图像边界分支，或至少对不支持的子元素记 warning（"mask 内容类型不支持，已忽略"），避免静默全透明；同时补"组继承 fill""渐变蒙版""evenodd 蒙版""文本蒙版"四条用例。

### [一般][存量] #3 clip/mask 的元素树遍历递归没有深度计数，深 DOM 或父子环会栈溢出

- **位置**：`f_svg/src/SvgClipMask.cj:376-389`、`405-418`（`renderClipChildren` 递归传原 `depth`）、`515-527`、`534-546`（`renderMaskChildren` 同）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归 / 自引用结构」
- **证据**：静态确定 —— 四处递归调用都把 `depth` 原样传下去（`depth` 只在 `applyClipReference`/`applyMaskReference` 里 `depth + 1`，见 `667`、`722`），所以"容器套容器"这条路完全没有计数；`SvgElement.appendElement` 也不做环检测（父指针 + children 双向链，可被调用方构造成环）。`SvgClipPathMasker.render` / `SvgMasker.render` 是公开 API，参数就是调用方给的 `SvgElement` 树。
- **描述**：解析路径被 `SvgSecurityOptions.maxDepth = 512`（`f_svg/src/SvgOptions.cj:66`）兜住，正常文档不会触发；但直接构造 DOM（`SvgRoot` + `SvgContainer` 循环 `appendElement`，或把某个容器 append 到自己的后代里）后调用公开渲染 API 会无限递归直至栈溢出，进程崩溃。栈溢出按后果属崩溃类，这里因可达性依赖程序化构造，定为一般。
- **建议**：给两处遍历加显式深度参数（与引用深度分开，例如 `treeDepth`，上限取 `maxDepth` 或更小），超限抛 `SvgException(kind: Limit)`；`appendElement` 做"祖先链包含自身"检查，直接拒绝成环。

### [一般][存量] #4 嵌套 clip/mask 对非形状子元素用 `SvgBounds.empty()` 当目标盒，objectBoundingBox 单位把覆盖率缩放成负值 —— 内容被裁光或只剩 1 像素

- **位置**：`f_svg/src/SvgClipMask.cj:420-423`、`548-551`（`case None => SvgBounds.empty()`）、`210-212`（`bboxMatrix` 直接 `translate(box.x, box.y) * scale(box.width, box.height)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空值未处理 / 边界」、§10「正确性」
- **证据**：静态确定 —— `SvgBounds.empty()` 是 `(0, 0, -1, -1)`（`f_svg/src/SvgBounds.cj:36-38`）。当 clip/mask 里的子元素是 `<g>` / `<text>` / `<image>` / `<use>`（`elementPathData` 返回 `None`）且它自己带 `clip-path` / `mask` 引用时，`box=(-1,-1)` 会被传给两条路径：① `clipPathUnits="objectBoundingBox"` / `maskContentUnits="objectBoundingBox"` → `matrix = childMatrix * scale(-1,-1)`（`232-234`、`277-279`），子内容镜像到负象限，覆盖率恒为 0；② mask 默认 `maskUnits=objectBoundingBox` 时 `maskRegion` 由 `box` 推出 `x=0.1`、`width=-1.2` 的退化区域（`899-917`），最终 `firstX/firstY=0`、`lastX/lastY=1`（`924-928`），覆盖率只剩左上角 1×1 像素 —— 元素几乎被整段抹掉。
- **描述**：只有"容器/文本/图像/use 自带 clip 或 mask，且引用目标是 objectBoundingBox 单位"这一组合会触发，但这是图标库里常见写法（`<g clip-path="url(#round)">`）。当前没有任何 warning，表现为"组内容凭空消失"或"只显示左上角一个像素"。
- **建议**：`box` 改成按元素类型取真实包围盒：容器取子元素并集（`svgBBoxOf` 已有），文本取布局包围盒，图像取 `x/y/width/height`；确实无法计算时不要回退 `empty()`，而是退回 `UserSpaceOnUse` 语义并记 warning。

### [一般][存量] #5 `font-variant-ligatures` 用 `contains` 匹配，`no-common-ligatures` / `no-contextual` 被解析成"启用"，与 CSS 语义相反

- **位置**：`f_svg/src/SvgComputedStyle.cj:445-453`（`for (value in ["none", "common-ligatures", ...]) if (lower.contains(value)) return value`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 逻辑错误」、§2「近似重复导致的判定漂移」
- **证据**：静态确定 —— `font-variant-ligatures: no-common-ligatures` 经 `SvgStyleResolver` 校验后原样存入（`f_svg/src/SvgStyleResolver.cj:837-843` 接受 `contains("common-ligatures")` 并返回原串），`fontVariantLigatures()` 里 `"no-common-ligatures".contains("none") == false`、`contains("common-ligatures") == true` → 返回 `"common-ligatures"`。下游 `SvgFontFeatures.fromStyle` 的 `case "common-ligatures"` 会把 `liga` / `clig` 置为 **true**（`f_svg/src/SvgFontVariant.cj:191-193`），即"显式关闭连字"反而打开连字。`no-contextual` 同理返回 `"contextual"` 并打开 `calt`。
- **描述**：文本整形结果与作者声明相反，且没有任何 warning；`no-discretionary-ligatures` / `no-historical-ligatures` 同样反向。现有测试只覆盖 `small-caps` 与 `font-feature-settings`（`SvgFontDetailsM6_test.cj:241-244`），没有 `no-*` 用例。
- **建议**：按 `splitCssWhitespaceWords` 逐词精确匹配，先处理 `no-` 前缀（`none`/关闭对应特性），再匹配正值；或直接返回 `SvgFontFeatures` 而不是字符串。补 `no-common-ligatures` / `no-contextual` 两条断言。

### [一般][存量] #6 `SvgManualClock.stop()` / `start()` 对 `now()` 完全没有影响，`enabled` 是只写不读的死字段

- **位置**：`f_svg/src/SvgClock.cj:26`（`private var enabled = true`）、`32-34`（`now()` 直接返回 `time`）、`36-42`（`stop` / `start` 只改 `enabled`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」、§3「公开契约承诺有行为，实际为空」、§11「契约与命名不符」
- **证据**：静态确定 —— 全仓搜索 `enabled` 在 `SvgClock.cj` 内只有 `26`、`37`、`41` 三处（两处写、零处读）；`SvgManualClock` 的 `stop` / `start` 在仓内无任何调用点，`SvgClock_test.cj` 也只测 `now()` 与 timeline 采样。README（`f_svg/README.md:609`）把 `stop` 列为公开方法。
- **描述**：调用 `stop()` 后 `now()` 仍返回 `time`，`SvgTimeline.sampleCurrent()` 继续推进动画；`start()` 无任何可观察效果。`stop` 是文档承诺的行为，实际是空操作，属于"读代码看不出来、运行时也不报错"的契约缺陷。
- **建议**：二选一——① `stop()` 时记录冻结时间（如 `frozenAt = time`），`now()` 在停止状态返回 `frozenAt`，`start()` 恢复（并明确是否需要累计暂停时长）；② 删除 `enabled` / `stop` / `start` 并同步删掉 README 条目。无论哪种都补一条 `stop()` 后 `now()` 不变的用例。

### [一般][存量] #7 外部引用/危险内容判定是字面量子串匹配：CSS 转义漏报，空 href、`mailto:`、注释里的 `@import` 误报

- **位置**：`f_svg/src/SvgBuilder.cj:396-407`（`externalCssUrlTarget`）、`410-443`（`externalUrlTarget` 只找字面 `url(`）、`445-463`（`handleHrefValue`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：外部输入未校验」、§11「错误处理缺失 / 误判」、§13（安全承诺）
- **证据**：静态确定 ——
  - **漏报**：`externalUrlTarget` 逐字节匹配 `u r l (`（`414-416`），CSS 允许标识符转义，`u\72l(http://evil)`、`@im\70 ort url(...)` 都合法且会被浏览器 CSS 解析器还原成 `url(` / `@import`，本扫描器全部放行；`<style>` 内容与 `style` 属性走同一函数（`173-190`、`367-372`）。若调用方把清洗后的 DOM 再序列化交给浏览器，这是可绕过 `allowExternalReferences=false` 的路径。
  - **误报**：`href=""`（合法的"无引用"）在 strict 模式下进入 `handleHrefValue` 后 `allowed` 为 false，直接抛 `Security`（`459-461`）；`href="mailto:a@b"`（`<a>` 的正常链接）同样被当作外部资源拒绝/移除；CSS 注释或字符串里出现 `@import` 字样（如 `/* @import unsupported */`）会让整个 `<style>` 被移除（`403-405` + `185-187`），strict 模式下直接抛错。
- **描述**：同一处用"文本包含"代替 CSS/URL 词法分析，同时存在安全漏报与合法输入误报。误报的后果是 strict 模式拒绝合法文档、宽松模式丢样式/丢链接且只留一条 warning。
- **建议**：`href` 先判空串 / 只含空白 → 视为无引用直接放行；按 scheme 白名单处理（`mailto:` / `tel:` 单独放行或明确文档化为不支持）。CSS 侧至少做一次转义反转义（`\XX` 与 `\c`）后再生效，或直接复用 `CssLexer`（`CssStyleSheet.parse` 已在用）拿 token，再判 `url` / `@import`，避免注释与字符串误判。

### [一般][存量] #8 安全过滤对非 SVG 命名空间的元素整体短路，`foreignObject` 内的 XHTML 事件属性与 `javascript:` 引用被原样保留

- **位置**：`f_svg/src/SvgBuilder.cj:340-342`（`if (elementNamespace != SvgNamespaces.SVG) { return false }`）、`358-360`（属性不在 SVG 命名空间也直接放行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：注入」、§11「契约与实现不符」
- **证据**：静态确定 —— `shouldRemoveAttribute` 一进入就按元素的命名空间短路；`buildSvgChildren` 会把这些元素完整保留为 `SvgUnknownElement`（`169-171`），`SvgWriter` 再按原 QName 序列化。于是 `<foreignObject><div xmlns="http://www.w3.org/1999/xhtml" onclick="…" href="javascript:…">` 里的 `onclick` / `javascript:` 不会被 `unsafePolicy` / `allowEventAttributes` 处理（`<script>` 元素因为按 local name 判断仍会被移除，见 `134-149`）。`xml:onclick` 这类带命名空间的属性同样绕过 `on` 前缀检查（`361-366` 只在 `uri.isNone()` 时生效）。
- **描述**：`SvgSecurityOptions` 的语义是"不安全内容的处理策略"，但只覆盖 SVG 命名空间。渲染器本身不执行脚本，所以直接危害有限；一旦调用方把清洗后的文档再交给浏览器/HTML 引擎（上传 SVG 的典型链路），就是存储型 XSS 面。属"安全承诺的边界未写清 + 实现遗漏"。
- **建议**：把事件属性检查提到命名空间判断之前（对 `local` 以 `on` 开头、`href` / `src` / `style` 统一过滤，不看命名空间）；或在 README / 选项注释里明确"只清洗 SVG 命名空间内容，foreignObject 内容由调用方负责"，并给出剥离 foreignObject 的选项。

### [一般][存量] #9 `warnings` 无上限、无去重，路径字符串随深度线性放大 —— 病态文档可用警告洪泛把输入放大数倍

- **位置**：`f_svg/src/SvgBuilder.cj:25`（`SvgBuildContext.warnings`）、`140`、`167`、`203`、`215`、`224`、`232`、`477`、`503`、`522`（各 warning 追加点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器」「按不可信规模分配」、§6.4（重复字符串拼接）
- **证据**：静态确定 —— `warnings` 是普通 `ArrayList<String>`，只在 `buildSvgDocument:77-79` 整体复制到 `document`，没有任何条数上限或同类合并。每条 warning 都拼接 `elementPath`（`100` 行按层累加 `tag[index]`），单个元素的路径长度 = O(深度)。`maxElements` 默认 1,000,000，且单元素可有任意多个非法属性 —— 1M 元素 × 每条 30–200 B 的警告 ≈ 30–200 MB，深度 100 的深层文档还会把每条路径放大到约 1 KB。
- **描述**：输入大小与警告内存不成比例（path 重复构造是主要放大项），且 `document.warnings` 会把条目再存一份引用。对上传/第三方 SVG 是低成本的内存放大面；warning 数量也失去可读性（同一元素的同类错误不合并）。
- **建议**：给 `SvgBuildContext` 加 `warningLimit`（例如 1000 条），超限后只保留一条"已省略 N 条警告"；同类 warning 按 `(kind, path)` 去重；路径用共享前缀或只在需要时拼接，不要在热路径上为每条 warning 重建整条路径。

### [一般][存量] #10 `SvgCoverageMask` / `SvgClipCoverage.render` 不校验 maxPixels，公开 API 可直接分配任意 `w×h`

- **位置**：`f_svg/src/SvgClipMask.cj:27-34`（`Array<Byte>(width * height, repeat: 0)`）、`36-43`；`f_svg/src/SvgClipProperty.cj:121-129`（只判 `> 0` 就 `SvgCoverageMask` + `SvgBitmap`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— 同模块的 `SvgGroupCompositor.createLayer` 明确"按 `maxPixels` 校验后创建离屏层"（`SvgClipMask.cj:154-158`），但 `SvgCoverageMask` 的两个公开构造函数、`SvgClipCoverage.render` 都没有对应校验：`SvgClipCoverage.render(rect, matrix, 100_000, 100_000)` 会先分配 10^10 B 的覆盖率数组，再分配 4×10^10 B 的 scratch 位图（`129`），直接 OOM；`width * height` 也没有溢出保护（对比 `SvgBitmap.cj:97-100` 有 `width > Int64.MAX / height` 检查）。
- **描述**：渲染器主路径传入的是已校验的位图尺寸，所以目前不炸；但这两个类型是公开 API（`SvgCoverageMask` 可直接构造、`SvgClipCoverage` 供外部复用），调用方按默认语义传入画布尺寸时没有任何拒绝路径，"到 OOM 才知道"。
- **建议**：`SvgCoverageMask` 构造函数接收/复用 `SvgRenderOptions.maxPixels`（或新增 `limit` 参数，默认 64M 像素）并在分配前 `width > maxPixels / height` 抛 `SvgException(kind: Limit)`；`SvgClipCoverage.render` 增加 `options!: SvgRenderOptions` 或至少把 `maxPixels` 透传；同时补 `width * height` 的溢出检查。

### [一般][存量] #11 `SvgClipProperty.parse` 丢弃 `SvgLength.unit`：`rect(2em, ...)`、`rect(1cm, ...)` 被当成 2 / 1 用户单位

- **位置**：`f_svg/src/SvgClipProperty.cj:73-79`（`values.add(Some(length.value))`）、`100-108`（`toBounds` 直接用这些裸值）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与数据错误」、§10「语言特性：类型信息被丢弃」
- **证据**：静态确定 —— `parse` 只取 `length.value`，`unit` 被丢弃；`toBounds` 也不接收 `SvgLengthContext`。`clip: rect(1cm, 10cm, 10cm, 0)` 会得到 1×10 的裁剪框而不是 37.8×378；`rect(1em, …)` 同样按 1 用户单位处理。`SvgLength.toUserUnits`（`f_svg/src/SvgLength.cj:205`）已经提供了带 `dpi`/`fontSize` 的换算，但这里没用。百分比虽然不符合 CSS 2.1 的 `clip` 语法，当前也会被当作裸值接受（`50%` → 50）。
- **描述**：单位不同的合法 `clip` 值得到静默错误的裁剪区域（差 37 倍以上），且 `normalize()` 会把错误值重新写成无单位的 `rect(1, 10, 10, 0)`，问题在 round-trip 后被"固化"。
- **建议**：`parse` 保留 `SvgLength`（或至少拒绝非 `Number`/`Px` 单位并记 warning），`toBounds` 增加 `SvgLengthContext` / `fontSize` 参数走 `toUserUnits`；百分比按 CSS 2.1 直接判非法。补 `cm` / `em` 两条用例。

### [轻微][存量] #12 `renderClipChildren` 与 `renderMaskChildren` 是约 110 行的逐段复制，已经产生行为漂移

- **位置**：`f_svg/src/SvgClipMask.cj:315-462` 与 `464-590`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 跨函数复制」
- **证据**：静态确定 —— 两段的结构、参数列表、`childStyle` 计算、`childBounds` 计算、`clipId`/`maskId` 解析、`layer` 分配、`applyClipReference`/`applyMaskReference` 调用顺序逐行对齐；唯一语义差异是叶子绘制（clip 用 `SvgRasterizer.fill(..., SvgColor.Black, fillRule)`，mask 用 `drawMaskPath`）和 `fillRule` 是否传递。漂移已经发生：clip 侧会按 `clip-rule` 传 `fillRule`（`367-374`、`396-403`），mask 侧根本不传（`514`、`533`），直接导致 #2 的 evenodd 错误。
- **描述**：两份实现各自演进，任何一边补 display/visibility/文本/图像支持都会漏掉另一边；当前两个函数的差异点没有注释说明。
- **建议**：合并成一个遍历，把"叶子如何画"作为参数（`leaf: (SvgElement, SvgPathData, SvgMatrix, SvgBitmap) -> Unit`，外加 `fillRule` / `style`），clip 与 mask 只提供各自的叶子实现；合并后补一组"同一文档分别走 clip/mask"的对照用例。

### [轻微][存量] #13 属性值校验有两套表：`SvgBuilder.isValidSvgAttribute` 与 `SvgStyleResolver.normalizeValue`，覆盖集合与失败行为都不同

- **位置**：`f_svg/src/SvgBuilder.cj:525-596`（`case _ => true` 在 `594`；`color` / `stop-color` 接受 `"none"` 在 `528-531`；`x`/`y` 用 `parseSvgLengthList` 在 `539`）与 `f_svg/src/SvgStyleResolver.cj:548-561`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「同一组规则散落多处 / 近似重复」、§11「校验不一致」
- **证据**：静态确定 —— 同一属性在两条路径上规则不同：`stop-color="none"` 被属性校验判为合法（`531`），CSS 侧 `normalizeColor` 会判非法并回退黑；`x="1 2"` 被属性校验接受（列表解析），而 `x` 只允许单值；`vector-effect` / `mix-blend-mode` / `paint-order` / `isolation` / `dominant-baseline` / `shape-rendering` 等已在 `SVG_PROPERTY_TABLE` 里的属性在 `isValidSvgAttribute` 中没有分支，走 `_ => true`，strict 模式既不抛也不 warn；失败行为也不同（属性校验 strict 抛 `InvalidValue`，CSS 侧只加 warning）。
- **描述**：strict 模式的"严格"程度取决于属性是写在 XML 属性上还是 `style` 里，同一份文档改个写法行为就变；后续新增属性需要同时改两张表，容易漏。
- **建议**：抽一张 `属性名 → 校验函数` 的单一表，CSS 与属性两条入口共用；失败策略（strict 抛 / 宽松 warn）作为参数传入，而不是各写一套；把 `SVG_PROPERTY_TABLE` 与校验表做成同源生成。

### [轻微][存量] #14 `SvgClipPathMasker.render` / `SvgMasker.render` 的 `units` 默认值与元素自身属性脱节

- **位置**：`f_svg/src/SvgClipMask.cj:78-110`（`units!` 默认 `UserSpaceOnUse`，不读 `clip.attr("clipPathUnits")`）、`115-149`（`maskUnits` / `maskContentUnits` 默认值，不读元素属性）；对照 `652-654`、`703-708`（嵌套引用路径会读属性）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「API 设计」
- **证据**：静态确定 —— 顶层 `render(clip)` 直接调用时完全忽略 `clipPathUnits="objectBoundingBox"` / `maskUnits` 属性；只有 `applyClipReference` / `applyMaskReference` 内部才会读属性。渲染器主路径在 `SvgRenderer.cj:714-717`、`736-741` 手工读取并传入，所以内部自洽；外部调用方按"传元素就能渲染"的直觉使用时，`objectBoundingBox` 会被静默当作 `userSpaceOnUse`。
- **描述**：同一语义在两条入口上有两套行为，且默认参数看起来像"已处理"，实际是"调用方必须自己解析属性"。文档注释没有提示这一点。
- **建议**：`units` / `maskUnits` / `maskContentUnits` 改为 `?SvgCoordinateUnits = None`，为 `None` 时读元素属性（再回退默认值）；或在注释与 README 明确"调用方负责解析单位属性"。

### [轻微][存量] #15 `XmlNode.EntityRefNode` 被静默丢弃，strict 模式也不报错，round-trip 后实体引用消失

- **位置**：`f_svg/src/SvgBuilder.cj:110`（`case XmlNode.EntityRefNode(_) => ()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失」、§13「序列化一致性」
- **证据**：静态确定 —— 该分支既不保留节点也不加 warning。`f_xml` 自己的解析器对未声明实体走"跳过 + 告警"（`f_xml/src/ParserEngine.cj:470-473`），不会产出该节点；但 `XmlEntityRef` 是公开构造函数（`f_xml/src/XmlNode.cj:53-55`），`SvgParser.parse(xmlDocument)` 允许调用方传入含实体引用节点的 DOM，此时 `SvgWriter` 本可原样写回 `&name;`（`f_xml/src/XmlWriter.cj:429`），经过 `buildSvgChildren` 后该节点消失，且 strict 模式不会把它当作语法/安全问题。
- **描述**：从文本解析的路径基本不可达（未声明实体已在 f_xml 侧告警并跳过），主要影响"复用已构造 DOM"的调用方：实体引用在 round-trip 后静默丢失，排查时只能看到文本少了一段。
- **建议**：至少记 warning（含实体名）并按 `unsafePolicy` 决定保留/移除；strict 模式直接抛 `Syntax`/`Security`。

### [轻微][存量] #16 `SvgBuilderM7_test` 依赖当前工作目录下的 `target/` 与固定文件名，测试不可并行且会留脏文件

- **位置**：`f_svg/src/SvgBuilderM7_test.cj:487`（`"target/m7-card.svg"`）、`488`、`494`、`514`、`555`、`626`（`File.createTemp(Path("target"))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可测试性」、§11「资源/环境假设」
- **证据**：静态确定 —— 用例直接写模块相对的 `target/`，没有 `mkdir`；`save` 的失败用例（`514`）又依赖 `target/m7-missing-dir` 不存在。`target/` 不存在时 `File.createTemp` 与 `save` 全部失败；两个测试进程并行跑同一模块会互相覆盖同名文件（`m7-card.svg`、`m7-design-card.svg`）。
- **描述**：在干净检出或沙箱里跑 `cjpm test` 会因目录缺失而失败；并行/重复执行结果不确定，且残留文件没有清理。
- **建议**：用 `std.fs` 的临时目录 API 或 `File.createTemp` 返回的路径做基目录，测试结束删除；失败用例用随机不存在的子目录名。

### [严重][存量] #17 用「字节长度 + 定长字节切片」识别前缀关键字，非 ASCII 输入抛 `IllegalArgumentException` 穿透 `SvgException` 契约

- **位置**：
  - `f_svg/src/SvgBuilder.cj:451`（`lower[0..5] == "data:"`，`handleHrefValue`）
  - `f_svg/src/SvgBuilder.cj:467-469`（`lower[0..5] == "http:"` / `lower[0..6] == "https:"` / `lower[0..2] == "//"`，`isPermittedExternalReference`）
  - `f_svg/src/SvgBuilder.cj:361`（`local.size > 2 && local[0..2].toAsciiLower() == "on"`，`shouldRemoveAttribute`；该处还取决于 `f_xml` 是否接受非 ASCII 名称，其余四处只依赖属性值，必然可达）
  - `f_svg/src/SvgClipMask.cj:734`（`trimmed[0..4].toAsciiLower() != "url("`，`readEffectId`）
  - `f_svg/src/SvgClipProperty.cj:56`（`lower.size <= 5 || lower[0..5] != "rect("`，`SvgClipProperty.parse`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：外部输入未校验」、§11「边界 / 错误处理」；API 语义见标准库文档 `std/core/core_package_api/core_package_structs.md:9380`「operator func \[](Range\<Int64>)」——*「区间为 UTF-8 编码后的字节下标范围，起止点必须位于字符边界上……范围起止点不是字符边界，抛出 `IllegalArgumentException`」*
- **证据**：静态确定 —— 上述 5 处都只用「字节长度 ≥ n」做前置判断，再按固定字节数切片；`toAsciiLower()` 只改 ASCII 字节、不改变 UTF-8 字节长度，因此非 ASCII 前缀一定把切点落在多字节字符中间。最小触发输入：`<image href="中文"/>`（`中` 占 3 字节，`lower[0..5]` 切在 `文` 的第 2、3 字节之间）、`<rect clip-path="中文"/>`（`readEffectId` 的 `[0..4]`）、`<rect clip="中文字"/>`（`SvgClipProperty.parse` 的 `[0..5]`）。`SvgParser.loadXml`（`SvgParser.cj:96-104`）只把 `XmlException` 包装成 `SvgException`，`buildSvgDocument` 内抛出的 `IllegalArgumentException` 直接穿透到调用方。
- **描述**：前缀关键字识别用字节切片比较而不是字符串前缀比较，于是任意中文/emoji 开头的 `href`、`clip-path`、`mask`、`clip`、事件属性名都会让解析抛出错误的异常类型（按文档只捕获 `SvgException` 的调用方会漏捕，进程内未捕获异常）。这是不可信 SVG 输入上的确定性崩溃路径，且与 #7 的「外部引用判定」共用同一批函数——修 #7 时若仍保留 `[0..n]` 写法，漏报修好了、崩溃面还在。
- **建议**：全部改成前缀比较：`lower.startsWith("data:")`、`lower.startsWith("http:")`、`lower.startsWith("https:")`、`lower.startsWith("//")`、`trimmed.startsWith("url(")`、`lower.startsWith("rect(")`、`local.startsWith("on")`（`startsWith` 已是本模块惯用法，见 `SvgComputedStyle.cj:199`）。顺便全仓 grep 一次 `\[0\.\.` / `\[1\.\.` 的定长前缀切片，逐处确认切点落在 ASCII 字节上（`SvgColor.cj` 的 `'#'` / `'('` / `'%'` / `"deg"` 四处已逐个核对，安全）。

### [一般][存量] #18 `maskRegion` 在 `userSpaceOnUse` 下把百分比当绝对长度，蒙版区域整体错位

- **位置**：`f_svg/src/SvgClipMask.cj:913-916`（`maskRegion` 的 userSpace 分支）→ `f_svg/src/SvgClipMask.cj:958-967`（`userSpaceValue`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与规格不符」、§10「正确性：单位换算」
- **证据**：静态确定 —— `userSpaceValue` 只取 `SvgLength.value`，丢弃 `SvgLengthUnit.Percent`；同文件 `objectBoxValue`（`:931-956`）却对 `Percent` 做了 `value / 100.0`。SVG 1.1/2 规定 `mask` 的 `x`/`y`/`width`/`height` 在 `maskUnits="userSpaceOnUse"` 下百分比相对当前 viewport，`x="50%"` 应为 `0.5 × canvasWidth`，现状得到 `50` 用户单位。
- **描述**：同一文件内两种单位语境各写一套换算，其中一套漏了百分比。画布宽 1000 时 `width="50%"` 得 50 而非 500，蒙版被裁到左上角一块；若 `x="50%"` 则整体右移量差 20 倍。现有 `SvgClipMask_test.cj:139-196` 只用无单位数值，未覆盖该组合，因此测试全绿。
- **建议**：`userSpaceValue` 增加 viewport 参数，`Percent` 时返回 `value / 100.0 × viewport`；`maskRegion` 的 x/y 传画布宽高、width/height 同理。补 `maskUnits="userSpaceOnUse"` + `x="50%" width="50%"` 的用例并断言覆盖范围。

### [轻微][存量] #19 `rect` → `SvgPathData` 的五段命令在三处逐字复制

- **位置**：`f_svg/src/SvgClipMask.cj:789-797`（`elementPathData` 的 `SvgRect` 分支）、`f_svg/src/SvgClipProperty.cj:130-140`（`SvgClipCoverage.render`）、`f_svg/src/SvgRenderer.cj:1022-1031`（`rectPathData`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制」
- **证据**：静态确定 —— 三处都是 `MoveTo(x,y) → LineTo(x+w,y) → LineTo(x+w,y+h) → LineTo(x,y+h) → ClosePath(空数组)`，只有变量名不同（`box.x/box.width` vs `x/width`）。
- **描述**：矩形的路径等价表示有三份，改填充方向、是否闭合或命令参数个数时要同步三处，漏一处就会让 `clip` / `clip-path` / 主渲染三条路径的 nonzero 结果不一致（`ClosePath` 缺失直接改变填充）。
- **建议**：在 `SvgPathData` 或 `SvgShape.cj` 提供 `internal func rectPathData(bounds: SvgBounds): SvgPathData`，三处改为调用；删除 `SvgRenderer` 的同名私有函数。

### [轻微][存量] #20 `clampUnit` 与 `clampSvgUnit` 是同语义两份实现，NaN 语义还不一致

- **位置**：`f_svg/src/SvgColor.cj:356-358`（`clampUnit`）、`f_svg/src/SvgStop.cj:92-100`（`clampSvgUnit`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改函数名的重复实现」
- **证据**：静态确定 —— 函数体都是 `value < 0 → 0; value > 1 → 1; else value`，都不处理 NaN；`SvgColor.clampUnit` 等价于 `clampSvg(v, 0.0, 1.0)`。调用方按名字分散选择（`SvgBitmap`/`SvgBlend` 用 `clampSvgUnit`，`SvgColor` 内部用 `clampUnit`）。
- **描述**：同语义两个名字，新增调用点容易选错；`SvgColor.clampAlpha` 单独拒绝 NaN，而 `clampSvgUnit` 放行 NaN，NaN 输入经 `quantizeSvgChannel` 会得到 `Int64(round(NaN))` 的未定义结果。两处归一化不统一是潜在数值缺陷源。
- **建议**：保留引用面更广的 `clampSvgUnit`，删除 `SvgColor.clampUnit` 并内部改调；同时一次性定死 NaN 行为（建议与 `clampAlpha` 一致，显式拒绝或归 0）。

### [轻微][存量] #21 `maxI64` / `minI64` 重复 `std.core` 的泛型 `max` / `min`

- **位置**：`f_svg/src/SvgClipMask.cj:969-975`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「标准库已有能力却自写」
- **证据**：静态确定 —— `std/core/core_package_funcs.md:366 / :433` 提供 `func max<T>(T, T, Array<T>) where T <: Comparable<T>` 与 `min`，`Int64 <: Comparable<Int64>`；同模块其他文件已直接用 `max`/`min`（`SvgFilterRenderer.cj:88-91`、`SvgFilterPrimitives2.cj:1416`）。
- **描述**：模块内并存「用标准库 `max`」与「自写 `maxI64`」两种写法，读者要确认两者在相等时返回哪个参数（自写版返回 `second`），增加无谓认知成本。
- **建议**：删除 `maxI64`/`minI64`，改用 `max`/`min`。

### [轻微][存量] #22 `warnOffsetIfClamped` 复刻了 `tryParseSvgOffset` 的百分比归一化，同一 `offset` 值被解析两遍

- **位置**：`f_svg/src/SvgBuilder.cj:484-507`（`warnOffsetIfClamped`）vs `f_svg/src/SvgStop.cj:102-121`（`tryParseSvgOffset`）；调用点 `f_svg/src/SvgBuilder.cj:289-293`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— 两处都做「去尾 `%` → `value / 100.0` → 与 `0.0 / 1.0` 比较」，区别只是前者产出 warning、后者返回钳制值；`fillSvgAttributes` 先在 `validateSvgAttribute` 里调 `tryParseSvgOffset`，紧接着在 `warnOffsetIfClamped` 里再解析一遍同一字符串。
- **描述**：归一化规则有两份，`tryParseSvgOffset` 若改单位支持或钳制策略，告警判断会与实际取值脱节（出现「告警说不越界、实际被钳制」或反之）。
- **建议**：抽 `internal func normalizeSvgOffset(text: String): ?(Float64, Bool)`（值 + 是否越界），两个调用点共用，顺带消掉重复解析。

### [轻微][存量] #23 `buildSvgChildren` / `collectXmlText` 的递归深度等于可配置的 `maxDepth`，而选项不校验其上限

- **位置**：`f_svg/src/SvgBuilder.cj:84-113`（`buildSvgChildren`）、`:240-251`（`collectXmlText`）、`:52`（前置 `checkDepth`）；选项 `f_svg/src/SvgOptions.cj:59-80`（只校验 `maxDecompressedBytes`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由配置决定」、§11「缺少边界校验」
- **证据**：待确认（深度上限是配置项，实际帧大小与栈容量需实测）—— `checkDepth` 用显式栈迭代、注释写「避免深文档在构建前就爆栈」，但真正的构建与 `<style>` 文本收集仍然是递归，深度恰好等于 `security.maxDepth`；`SvgSecurityOptions.init` 对 `maxDepth` / `maxElements` 没有任何正值或上限校验，调用方可传 `maxDepth = 1_000_000`。
- **描述**：默认 512 层时安全，但只要调用方把 `maxDepth` 调大（或从配置读到异常值），迭代式预检会顺利通过，随后递归构建在同一深度上爆栈。预检与执行采用两套递归模型，安全边界只对默认值成立。
- **建议**：`SvgSecurityOptions.init` 给 `maxDepth` 加合理上限（如 ≤ 1024）并校验 `> 0`；或把 `buildSvgChildren` / `collectXmlText` 改成显式栈迭代，使「预检通过即可安全构建」成为真正的不变量。

### [轻微][存量] #24 `splitClipComponents` 函数体首语句与签名同行，不符合本模块格式

- **位置**：`f_svg/src/SvgClipProperty.cj:155`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可读性」（`cjfmt` 会拆行）
- **证据**：静态确定 —— `private func splitClipComponents(body: String): Array<String> {    let result = ArrayList<String>()`，本模块其余函数均为换行缩进风格。
- **建议**：跑 `cjfmt -w` 或手工换行。

### [轻微][存量] #25 文件名 `SvgBuilder.cj` 与内容不符（内容是 `buildSvgDocument`，公开类 `SvgBuilder` 在 `SvgAuthoringBuilder.cj`）

- **位置**：`f_svg/src/SvgBuilder.cj:34`（`buildSvgDocument`）；公开类 `SvgBuilder` 位于 `f_svg/src/SvgAuthoringBuilder.cj`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可读性 / 可维护性」
- **证据**：静态确定 —— 本文件全部符号为 `internal`/`private`（`SvgBuildContext`、`buildSvgDocument`、`buildSvgChildren`…），无 `SvgBuilder` 类型；`SvgBuilderM7_test.cj` 测的是 `SvgAuthoringBuilder.cj` 的 `SvgBuilder`，与被审文件无关（#16 的落盘用例也属后者）。
- **描述**：按文件名找 `SvgBuilder` 实现会落到 XML→模型 构建器上，改动序列化逻辑时容易改错文件；测试文件与实现文件不成对也源于此。
- **建议**：改名为 `SvgDocumentBuilder.cj`（纯移动，不涉及逻辑），与 `SvgAuthoringBuilder.cj` 区分。

### [轻微][存量] #26 `SvgComputedStyle.cj` 的 `fountain::f_base` 导入疑似未使用

- **位置**：`f_svg/src/SvgComputedStyle.cj:20`（`import fountain::f_base.*`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：待确认 —— 文件内出现的类型/函数（`HashMap`、`ArrayList`、`AtomicInt64`、`StringBuilder`、`SvgLength`、`SvgColor`、`tryParseSvgFloat`、`splitCssWhitespaceWords`、`svgPaintOrderOf`）分别来自 `std.collection` / `std.sync` / 本包，未发现 `f_base` 的 `invalidValue` / `syntaxError` / 日志宏等符号；需 `cjlint` 或构建警告确认（本轮不跑构建）。
- **建议**：跑一次 `cjlint`，报 `unused import` 则删除该行，否则保留。

<!-- 第 13 部分 -->

### [一般][存量] #1 `SvgDocument.root` 是可写字段，换根后变更监听与 warning 收集静默失效

- **位置**：`f_svg/src/SvgDocument.cj:23`（`public var root: SvgRoot`）、`f_svg/src/SvgDocument.cj:35-39`（只在 `init` 里挂 hub）
- **来源**：存量（blame `3ec7f9f27c` / `a061fe1ef5`；快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「检查-然后-写入 / 发布逸出」
- **证据**：静态确定 —— `init` 只做两件事：`root.mutationHub = Some(this.mutationHub)`、`this.mutationHub.warnings = Some(this.warnings)`（`35-39`）。全仓 `mutationHub` 只出现在 `SvgElement.cj:59`（默认 `None`）与 `SvgMutation.cj:110-123`（沿 `parent` 链向上找 hub，找不到就 `return`），没有 setter、没有向下传播。因此 `document.root = anotherRoot` 之后，新根及其子树上的 `mutationHub` 恒为 `None`：`setAttr` / `appendElement` 不再触发监听器，监听器异常也不再写进 `document.warnings`。仓内暂无 `SvgDocument.root =` 的赋值点（`grep "\.root = " f_svg/src` 命中的 `SvgDocument.cj:160` / `SvgSecurity_test.cj:253` / `SvgWriter.cj:85` 都是 `XmlDocument`），但字段是对外契约。
- **描述**：同一根因还有第二个面：同一个 `SvgRoot` 被两个 `SvgDocument` 包住时，后者的 `init` 覆盖 `mutationHub`，前者的监听器静默失聪、warning 也记到"最后构造的文档"上。触发条件是公开字段的常规写操作，后果是**无异常、无警告的静默失效**。
- **建议**：改为 `public let root: SvgRoot`，或 `private var root` + `public func replaceRoot(root: SvgRoot)`（方法内重挂 `mutationHub` / `warnings` 并保留旧根监听契约）；`init` 补一句"同一 root 不应被多个 SvgDocument 持有"的断言/注释。

### [一般][存量] #2 三处深度优先遍历与 `toXmlDocument` 均为裸递归，深度只由树深决定

- **位置**：`f_svg/src/SvgDocument.cj:172-187`（`findSvgElementById`）、`189-199`（`collectSvgElementsByTag`）、`201-224`（`collectSvgAnchors`）；间接同源：`SvgDocument.cj:153-165`（`toXmlDocument` → `SvgElement.toXmlElement`，`f_svg/src/SvgElement.cj:386-409`）
- **来源**：存量（blame `3ec7f9f27c`；快照无 diff）
- **判据**：review-checklist §4「无界递归」
- **证据**：静态确定（递归无深度参数、无访问集合、无显式栈）；崩溃阈值需实测
- **描述**：三个遍历与 `toXmlElement` 每层元素一帧，深度等于树深。两条来路：
  1. **解析路径**：默认安全但口子可开。`SvgSecurityOptions.maxDepth` 默认 `512`（`f_svg/src/SvgOptions.cj:66`），`SvgBuilder` 在建树前拦（`f_svg/src/SvgBuilder.cj:127`、`660-672` 的迭代统计），默认配置下 512 帧可接受；但 `maxDepth` 是公开可配项，为合法深文档调到 5000 / 50000 时上述四个函数立刻变成等深递归。另注意复用入口 `SvgParser.parse(document: XmlDocument)` 只受 `SvgBuilder` 的 `maxDepth` 约束（`f_xml` 侧 `XmlParserOptions.maxElementDepth` 默认 `4096`，`f_xml/src/XmlOptions.cj:146`）。
  2. **程序化路径**：`SvgElement.appendElement` / `insertBefore` 无任何深度校验（`f_svg/src/SvgElement.cj:336-338`、`278-306`），拼出 10 万层容器链后调 `document.elementById(...)` / `toString()` / `toXmlDocument()` 即等深递归。
- **建议**：三个遍历改显式栈（保持"文档序 + 先序"语义），或加 `depth: Int64` 参数与 `maxDepth` 比较、超限抛 `SvgException(kind: Limit)`（与模块内 `SvgContentCycleM3_test` 已确立的 `Limit` 语义一致）；`toXmlElement` 同源，建议一并收敛到 `SvgWriter` 的迭代实现。修完补一条"深链 + elementById / toXmlDocument"用例钉住边界。

### [一般][存量] #3 warning 文案内嵌完整外部输入值、按元素追加，且全链路无截断与去重

- **位置**：`f_svg/src/SvgCursor.cj:56`、`60`（`${trimmed}` 原样进 warning）；逐元素调用点 `f_svg/src/SvgStyleResolver.cj:744`；同形态的逐色块追加点 `f_svg/src/SvgContextPaint.cj:52`、`57`
- **来源**：存量（`SvgCursor` blame `d12d1a47a6`；`SvgContextPaint` blame `9858013907`）
- **判据**：review-checklist §5「OOM / 平方级增长」、§5「按不可信长度预分配 / 无界容器」
- **证据**：静态确定（机制与调用次数）；实际 RSS 需实测
- **描述**：`SvgCursor.parse(text, warnings)` 把 `url(...)` 或未知值的**全文**拼进 warning。这个函数在样式计算里**每个元素调一次**（`SvgStyleResolver.cj:744`），而 `cursor` 来自 `<style>` 规则或呈现属性，长度完全由输入决定。一条 `rect { cursor: url(<1 MB data URI>) }` 规则作用在 N 个元素上，就产生 N 条各约 1 MB 的字符串：`maxElements` 默认 `1_000_000`，量级上可达 TB 级常驻，属于"输入长度 × 元素数"的平方放大而不是线性增长。`warnings` 全链路只增不减、无容量上限；唯一的去重是 `SvgDocument.zoomAndPan()` 里的 `warnings.contains(...)`（`SvgDocument.cj:88-102`，O(n) 线性扫描，且只覆盖单条消息）。`SvgContextPaint` 的两个分支同样是逐色块追加、无去重——`context-fill` 用在 10 万元素上时 warning 数等于元素数。
- **建议**：warning 里对用户值统一截断（如 `take(64)` + 省略号），把"原值全文"留给显式的调试通道；`SvgStyleResolver` 对同一条 (属性, 值) 只记一次（`HashSet` 键，键用截断后的摘要）；`warnings` 加软上限（超限后只计数），或按文档规定"warnings 仅诊断用，长度不保证"。

### [一般][存量] #4 `context-fill` / `context-stroke` 遇 `currentColor` 时按实例元素解析颜色，与 M5 规格"被引用元素的计算 fill"不符

- **位置**：`f_svg/src/SvgContextPaint.cj:21-35`（`useContextFrame` 原样返回 `CurrentColor` 帧）；消费点 `f_svg/src/SvgRenderer.cj:531`（`case CurrentColor => style.color()`）
- **来源**：存量（blame `9858013907`；快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」——对照 `f_svg/doc/spec/add-f-svg-m5/specs/svg-paint-and-clip/spec.md:42`：「解析为被引用元素（`use.href` 目标）的计算 `fill` / `stroke`，而不是实例自身的画笔」
- **证据**：静态确定（机制）＋ 待确认（规格是否要求按**源元素**的 `color` 落地）
- **描述**：`useContextFrame` 只做"是 `context-*` 就视为无帧"的过滤，`fill="currentColor"` 会被当成可用帧返回，随后 `resolveContextPaintOf` 原样作为 `paintOverride` 交给绘制命令；`drawPaint` 落到 `CurrentColor` 分支时用的是**命令所属（实例）元素**的 `style.color()`。即 `<g id="g" fill="currentColor" color="red">` 被 `use` 到 `color="green"` 的实例里时，`context-fill` 得到 green，而规格写的是被引用元素的计算 fill（red）。现有 6 个渲染用例（`SvgContextPaintRenderM5_test.cj`）只覆盖字面颜色与"优先于 currentColor"，没有覆盖这个组合。
- **建议**：在 `useContextFrame` 里就把 `CurrentColor` 解析成源元素 `color()` 的具体颜色（需要拿被引用元素的 `SvgComputedStyle`，`styles.get(target)` 已经有），或反过来在规格里显式写明"`context-*` 的 `currentColor` 按实例颜色解析"并补一条用例；两条路都要选一条，别停在"机制上说得通"。

### [轻微][存量] #5 `resolveContextPaintOf` 同一 warning 文案写两遍，且 `ContextFill|ContextStroke` 帧分支在现有调用链上不可达

- **位置**：`f_svg/src/SvgContextPaint.cj:48-59`（文案在 `52` 与 `57`）；对照 `31-34`（`useContextFrame` 的过滤）
- **来源**：存量（blame `9858013907`）
- **判据**：review-checklist §2「字面量复制」、§1「恒真恒假分支」
- **证据**：静态确定 —— (a) `"${keyword} 没有可用的 use 上下文，按 none 处理"` 出现两次，两分支产物相同（`warnings.add` + `SvgPaint.None`）；(b) `frame` 的唯一来源是 `useContextFrame`（调用点 `f_svg/src/SvgRenderTree.cj:1092-1093`，`contextFill` / `contextStroke` 只在 `765`、`869` 被原样复制传播），而它已经保证不会返回 `ContextFill` / `ContextStroke` 帧，所以 `resolveContextPaintOf` 内层 `case ContextFill | ContextStroke` 分支走不到。
- **描述**：不可达分支可能是"防御性写法"，但它与 `None` 分支重复同一文案，改文案或改告警时机时容易只改一处，产生两种措辞；同时它掩盖了"帧不可能为 context-*"这一不变量，读代码的人会以为存在两条来源。
- **建议**：先算 `let resolved: ?SvgPaint = ...`（把"帧不可用"收敛成 `None`），再统一 `match (resolved)` 只写一次 warning；若确实想留防御分支，就把它写成 `assert` / 注释说明不变量，而不是再发一遍同样的 warning。

### [轻微][存量] #6 `findSvgElementById` 有两份实现，跨文件同语义复制

- **位置**：`f_svg/src/SvgDocument.cj:172-187`（`private`，参数 `SvgElement`）与 `f_svg/src/SvgRenderTree.cj:1517-1536`（`internal`，参数 `?SvgElement`）
- **来源**：存量（`SvgDocument` 侧 blame `3ec7f9f27c`；`SvgRenderTree` 侧同一批 11-05/11-06 提交）
- **判据**：review-checklist §2「只改类型名 / 跨文件复制」
- **证据**：静态确定 —— 两个函数体逐行对齐：`attr("id") == Some(id)` → 命中即返回；否则前序遍历 `children` 里的 `ElementNode` 递归；未命中返回 `None`。差异只有形参是否包 `Option`（`SvgRenderTree` 版多一个 `case None => None` 外壳）。
- **描述**：`SvgDocument` 的 `private` 版完全可以写成 `findSvgElementById(Some(this.root), id)`。现在两份实现分别被 `SvgDocument.cj:74`、`SvgClipMask.cj:645/696`、`SvgElementApi.cj:220`、`SvgHitTest.cj:86`、`SvgMarkerExpander.cj:191/224`、`SvgPatternSampler.cj:363`、`SvgRenderTree.cj:999/1490`、`SvgTextRenderer.cj:1524`、`SvgTimeline.cj:671` 使用，任何一处改语义（例如支持命名空间限定的 `id`、提前剪枝 `defs`）都要同步两份。
- **建议**：删掉 `SvgDocument` 的私有版，改为调用 `internal` 版；若要保留"只搜本树"的语义，就把 `internal` 版作为唯一实现并让 `SvgDocument` 传 `Some(root)`。

### [轻微][存量] #7 `SvgContainerKind` 的正向 / 反向 tag 表靠人工保持一致，`fromTag` 用 `_ => None` 兜底且逆向覆盖只有 4/10

- **位置**：`f_svg/src/SvgContainer.cj:47-60`（`toString`）、`62-75`（`tagName`）、`77-91`（`fromTag`，兜底在 `89`）、`31-45`（`==`）；测试 `f_svg/src/SvgContainer_test.cj:48-54`
- **来源**：存量（blame `a95da61cb7`）
- **判据**：review-checklist §2「字面量复制」、§1「恒真恒假分支」、§14.1「只做了一半的分支」（测试覆盖）
- **证据**：静态确定 —— `toString` / `tagName` 是穷尽 `match`（新增枚举值即编译报错），`fromTag` 以 `case _ => None` 收尾（新增值静默不认）；10 个标签名（含 `clipPath`、`foreignObject` 两个驼峰）在 3 张表里各写一遍。`SvgTag.create` 在 `f_svg/src/SvgTag.cj:69-70` 又手写一遍容器标签名做前置过滤，等于第 4 份。
- **描述**：当前 10 个值与表一致（`kindToTag` 用例逐个断言了正向映射），但 `tagToKind` 只断言 `g` / `clipPath` / `foreignObject` / `a` 四个正例加一个 `rect` 反例，`defs` / `symbol` / `marker` / `pattern` / `mask` / `switch` 的逆向映射没有任何断言。下一次加枚举值或改标签拼写时，`fromTag` 不会编译报错，也没有测试兜住。
- **建议**：把 tag 映射收敛成单表（`match` 于 `kind` 得 tag，`fromTag` 反查同一批常量），或保留 `match` 但补一条表驱动测试：遍历 10 个取值断言 `fromTag(k.tagName()) == Some(k)` 且 `SvgTag.create(k.tagName())` 返回对应 `kind`。

### [轻微][存量] #8 5 个测试文件 `import std.collection.*` 未使用

- **位置**：`f_svg/src/SvgComputedStyle_test.cj:18`、`SvgComputedStyleM5_test.cj:18`、`SvgComputedStyleM6_test.cj:18`、`SvgDirectionM5_test.cj:18`、`SvgDiscardM6_test.cj:18`
- **来源**：存量（`SvgComputedStyleM5_test` blame `70736a7e89`；其余同批 11-05/11-07 提交）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 5 个文件内 `ArrayList` / `HashMap` / `HashSet` / `ArrayDeque` / `LinkedList` 零命中（`grep` 逐个核对）；`SvgComputedStyle_test.cj:364` 的 `StringBuilder` 属 `std.core`（`/d/docs/work/cangjie/cangjie-doc/md/doc/cjapi/core.md:200`），不依赖 collection 包。
- **描述**：纯噪声，但会让读者误以为这些用例在用集合类型（实际用的都是 `m5StyleOf` 等共享辅助返回的具体类型）；与 `SvgCursorM6_test.cj:18`、`SvgContextPaintRenderM5_test.cj:18` 这些**真正**用到 `ArrayList` 的文件混在一起，不好分辨。
- **建议**：删除这 5 行 import；若 `cjlint` 已能报 unused import，把它纳入门禁。

### [轻微][存量] #9 样式测试夹具在 M5 / M6 两份文件里重复

- **位置**：`f_svg/src/SvgComputedStyleM6_test.cj:24-41`（`selfStyleOf` / `childStyleOf`）对 `f_svg/src/SvgComputedStyleM5_test.cj:32-48`（`selfStyleOf` / `parentStyleOf`）
- **来源**：存量（M6 侧 blame `d12d1a47a6`；M5 侧 `70736a7e89`）
- **判据**：review-checklist §2「只改类型名 / 跨文件复制」
- **证据**：静态确定 —— 四个函数体逐行对齐：拼同一段 `<svg xmlns=...><rect id="r" ${attributes}/>`（或 `<g id="p" ...><rect id="r"/></g>`）→ `SvgParser.parse` → `SvgStyleResolver().compute(root)` → `m5StyleOf(...)`；差异只有返回类型（`SvgComputedStyle` 与 `(SvgComputedStyle, SvgStyleResolver)`）与 `_` 丢弃 warnings。
- **描述**：同一"固定骨架 + 计算样式"模板在多个测试文件里复制，骨架字符串（`xmlns`、`id="r"`、`id="p"`）一旦要统一调整（加 `width/height`、换解析选项、换断言路径），要逐个文件改，容易漂移。
- **建议**：在测试侧建一个 `internal func m5StyleFixture(attributes: String, nested: Bool = false): (SvgComputedStyle, SvgStyleResolver)`（本包已有大量 `m5*` 共享辅助，落点一致），M5 / M6 的私有包装改为薄封装。

### [轻微][存量] #10 `SvgDirectionM5_test` 里有一个无调用者的私有辅助函数

- **位置**：`f_svg/src/SvgDirectionM5_test.cj:25-30`（`private func style(attributes: String): SvgComputedStyle`）
- **来源**：存量（blame `420059ecf0`）
- **判据**：review-checklist §1「无调用者」
- **证据**：静态确定 —— 文件内 `grep "style("` 只有定义处（`25`）；13 个用例全部直接 `let style = m5StyleOf(...)` 或 `m5ComputeStyles(...) + m5StyleOf(...)`，无 `style("...")` 调用；`private` 成员也无法被包内其它文件调用。
- **描述**：疑似 M5 早期草稿遗留：它封装"`<text id="t" ...>` + 计算样式"，与后续用例写法等价但没人用；留着会让人以为存在一条统一入口（而实际统一入口是 `m5StyleOf`）。
- **建议**：删除；若想统一写法，就把用例改成调它，二者选一。

### [轻微][存量] #11 `contentDepthLimit` 内联重写 `patternChainSvg`，且注释"65 层"与实参 70 不符

- **位置**：`f_svg/src/SvgContentCycleM3_test.cj:240-261`（内联构造）对 `264-280`（`patternChainSvg`）；注释 `95`、`203`
- **来源**：存量（blame `66229da437`）
- **判据**：review-checklist §2「换控制流 / 近似重复」、§13「注释与实现不一致」
- **证据**：静态确定 —— 两段都生成 `p0 → … → p70`、每层 `<pattern width="4" height="4" patternUnits="userSpaceOnUse"><rect … fill="url(#pN+1)"/></pattern>`、末层实心 `red`、外层 `<rect width="20" height="20" fill="url(#p0)"/>`，字面量完全一致；`patternChainSvg` 已含 `<svg …>` 包装，`contentDepthLimit` 只是把循环体抄了一遍再自己拼外壳。另：`publicSamplerDepthLimit`（`95`）与 `publicBuilderDepthLimit`（`203`）的注释写"65 层合法链"，实际传 `patternChainSvg(70)` / `markerChainSvg(70)`（生成 71 层），与实际深度不符。
- **描述**：同一"深度链"形状出现三份拷贝（`patternChainSvg`、`contentDepthLimit`、`markerChainSvg` 的同构体）；改链宽度、末层颜色或包装标签时要同步三处才能保持"非循环但超深"的语义。注释的 65 与 70 不一致会让人误判上限测得的是 64 还是 70（模块上限是 64，超限才会抛 `Limit`）。
- **建议**：`contentDepthLimit` 直接 `SvgParser.parse(patternChainSvg(70))`；注释改成实际层数（如"71 层链，超 64 层上限"）。

### [轻微][存量] #12 两处自测耗时口径不一致，且 5 s 墙钟硬断言 + 基准用例混入常规 `@Test`

- **位置**：`f_svg/src/SvgDomApiM6_test.cj:262-279`（`DateTime.now()` + `< 5 s`）对 `f_svg/src/SvgComputedStyle_test.cj:361-380`（`MonoTime.now()`，只 `println`）
- **来源**：存量（blame `a061fe1ef5` / `ec10433cb9`）
- **判据**：review-checklist §11「语义与命名不符」、§14.1「半成品」、§6.1（无数据不得当结论）
- **证据**：静态确定 —— 同一模块两处自测耗时：一处用 `MonoTime`（单调，`SvgComputedStyle_test.cj:19` 引入 `std.time`），一处用 `DateTime.now()`（墙钟，受 NTP / 改表影响，回拨时 `elapsed` 可为负）；后者把 5 s 当门禁（`278`），前者只打印。`thousandByThousandBenchmark` 构造 1000 条类选择器 × 1000 个元素，唯一断言是 `tree.size == 1001`（`378`），耗时仅打印，却仍作为常规 `@TestCase` 每轮执行。
- **描述**：口径不统一导致两个数字无法横向比较；5 s 阈值在 CI 高负载时误红、时钟回拨时恒真；基准用例既不能当门禁（`cjpm test` 默认 `-O0`，数字无参考价值），又拖慢回归。
- **建议**：统一改用 `MonoTime.now()`；耗时断言要么去掉只记录、要么放到 30 s 量级并注明"仅防挂死"；基准挪到 `@Benchmark` 或加 `@Ignore` / 独立 tag。

### [轻微][存量] #13 `SvgContextPaintRenderM5_test.cj:47` 断言缩进错位

- **位置**：`f_svg/src/SvgContextPaintRenderM5_test.cj:47`
- **来源**：存量（blame `519d83c68b`）
- **判据**：review-checklist §10 可读性
- **证据**：静态确定 —— 该行缩进 16 空格，同函数后续语句（`48`）与同构用例（`60-61`）都是 8 空格，`@Assert` 与上一行 `let (bitmap, warnings) = ...` 不在同一视觉层级。
- **描述**：纯格式问题，但会让人以为它属于某个不存在的嵌套块（`cjfmt` 未覆盖该文件）。
- **建议**：`cjfmt -w` 该文件或手工对齐到 8 空格。

### [轻微][存量] #14 `SvgCursor` 公开类型只被 `parse(...).toString()` 消费，缺少相等语义，且 `init` 可绕过白名单

- **位置**：`f_svg/src/SvgCursor.cj:35-69`；唯一消费点 `f_svg/src/SvgStyleResolver.cj:744`；`SvgComputedStyle.cursor()` 返回 `String`（`f_svg/src/SvgComputedStyle.cj:320-322`）
- **来源**：存量（blame `d12d1a47a6`）
- **判据**：review-checklist §10 设计合理性 / 语言特性（值类型接口完整性）
- **证据**：静态确定 —— `SvgStyleResolver` 的唯一用法是 `Some(SvgCursor.parse(text, this.warnings).toString())`，`SvgComputedStyle.cursor()` 直接回读 `get("cursor")` 字符串，`SvgCursor.name` 不参与任何判断；`SvgCursor` 只实现 `ToString`，未实现 `Equatable`，而 `public init(name: String = "auto")`（`38-40`）允许 `SvgCursor(name: "hand")` 这类非法值通过。
- **描述**：类型承担的职责只有"白名单校验 + 大小写归一"，却以 `struct` 形式对外暴露：调用方既不能比较两个 `SvgCursor`，也无法从类型上排除非法值，实际全部退回字符串。属"占位 API"：删不掉（public），又没人真的当类型用。
- **建议**：二选一 —— (a) 收窄为 `internal func normalizedSvgCursor(text: String, warnings: ArrayList<String>): String`（公开面只留 `SvgComputedStyle.cursor(): String`，属可见性建议，需确认无下游引用）；(b) 保留类型但补 `Equatable<SvgCursor>`，`init` 收为 `internal`，只留 `parse` 作构造入口（顺带解决 `init` 绕过白名单）。

### [轻微][存量] #15 `SvgDocument` 的可变状态无同步，README / 类注释也未声明线程模型

- **位置**：`f_svg/src/SvgDocument.cj:26-33`（`prolog` / `epilog` / `warnings` / `mutationHub`）、`42-48`（监听器增删）
- **来源**：存量（blame `3ec7f9f27c`；快照无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§14.2「缺关键段落（限制与注意事项）」
- **证据**：静态确定 —— `warnings` 是 `public let ArrayList<String>`，`SvgMutationHub.listeners`（`f_svg/src/SvgMutation.cj:76`）是普通 `ArrayList`，`add` / `remove` / `notify` 无锁、无原子、无线程封闭声明；`grep -rn "线程安全\|并发调用\|thread-safe" f_svg/README.md f_svg/README_en.md f_svg/doc f_svg/src` 零命中（`doc/perf-baseline.md` 只谈 local region 并发数）。
- **描述**：模块内没有跨线程共享同一个 `SvgDocument` 的路径（渲染器每次 `render(document)` 自行遍历、不写回文档），所以目前不是缺陷；但这是一个"可变 DOM 库"，下游把模板文档缓存起来、多请求并发改属性时，`children` / `attributes` / `warnings` / 监听器表都会竞争，而文档没有任何提示。判"不安全"缺少调用方共享路径，故只按**文档缺失**记轻微。
- **建议**：在 `README.md`（或 `doc/` 专章）加一行"`SvgDocument` 与所有 `SvgElement` 均为可变对象、非线程安全；跨线程共享需调用方自行同步，渲染请使用独立文档或加锁"，`SvgDocument` 类注释同样补一句。

<!-- 第 14 部分 -->

### [一般][存量] #1 公共 DOM 编辑 API 不维护「单父 + 无环」不变量：可重复挂载、可成环（成环后 `svgRootOf` / `svgNotifyMutation` 死循环，序列化与包围盒递归爆栈）

- **位置**：`f_svg/src/SvgElement.cj:259-270`（`appendChild`）、`f_svg/src/SvgElement.cj:278-306`（`insertBefore`）、`f_svg/src/SvgElement.cj:336-338`（`appendElement`）
- **来源**：存量（blame `18a60454f0`，快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」+ §4「自引用结构 / 间接递归」
- **证据**：静态确定 —— `appendChild` 只做 `children.add(node)` + `element.parent = this`（`:260-263`），既不从旧父节点摘除，也不检查 `this` 是否已是 `node` 的祖先；`insertBefore` 同样（`:285-289`）
- **描述**：三种可复现的结构破坏，全部来自公开 API 的常规用法（README:255 明确把 `appendChild` / `insertBefore` / `removeChild` 列为「节点编辑 支持」）：
  1. **重复挂载**：`p1.appendElement(x); p2.appendElement(x)` 后 `x` 同时出现在两棵子树的 `children` 里，`x.parent` 指向 `p2`。渲染会画两遍；对 `p1.removeChild(x)` 会把 `x.parent` 置 `None`，而 `p2.children` 仍持有它 —— 此后 `x` 的子节点变更不再通知 `p2` 所在的根（`svgNotifyMutation` 从 `None` 直接 `return`），`x.elementPath()`（`SvgElement.cj:377-384`）也退化成 `/<tag>[<同名计数>]`（`siblingIndex` 未命中时返回累计计数，`:601-619`）。
  2. **成环 → 挂死**：`a.appendElement(b); b.appendElement(a)` 之后，`svgRootOf`（`f_svg/src/SvgElementApi.cj:41-60`）的 `while (true)` 沿 `parent` 永远走不到 `None`；`svgNotifyMutation`（`f_svg/src/SvgMutation.cj:110-127`）同理。二者都是主路径（`getBBox` / `getCTM` / 任意 `setAttr` 都会进）。
  3. **成环 → 栈溢出**：`SvgElement.toString()`（`f_svg/src/SvgElement.cj:412-445`，递归在 `:433`）、`toXmlElement()`（`:386-409`，递归在 `:401`）、`text()` → `collectText`（`:624-633`）、`svgDescendants`（`SvgElementApi.cj:361-370`）、`svgContainerBBox`（`SvgElementApi.cj:165-189`）都是裸递归，环上直接无限递归。
- **建议**：`appendChild` / `insertBefore` 入口加两条廉价守卫：(a) 若 `node` 是元素且 `element.parent.isSome()`，先从其旧父的 `children` 里摘除（DOM 的 adopt 语义）；(b) 沿 `this` 的 `parent` 链上溯，命中 `node` 则抛 `SvgException(kind: InvalidValue)`（上溯深度不超过当前树深，成本可忽略）。两处共用一个私有 `wouldCreateCycle(node)` 辅助函数。补 3 条用例：重复挂载后旧父 `children` 不含该节点、成环抛异常、成环后序列化不再触发递归。

### [一般][存量] #2 滤镜链按原语数线性保留全部中间缓冲：默认 `maxPixels` 下单缓冲 256 MiB，20 个原语的链在最坏区域下峰值可达 GiB 级

- **位置**：`f_svg/src/SvgFilterBuffer.cj:28-35`（`pixels = Array<Byte>(width * height * 4, repeat: 0)`）、`f_svg/src/SvgFilterBuffer.cj:18-22`（类注释「每个原语产生新缓冲」）
- **来源**：存量（blame `ec44b3adcb`，快照无 diff）
- **判据**：review-checklist §5「无界容器 / 一次性物化」+ §7「删除中间副本」
- **证据**：静态确定（单缓冲尺寸的算术）+ 需实测（峰值 RSS 与同时存活缓冲数）
- **描述**：单缓冲字节数 = `width × height × 4`，`width × height` 只受 `SvgRenderOptions.maxPixels`（默认 `64 * 1024 * 1024` 像素，`f_svg/src/SvgBitmap.cj:230`；滤镜区域在分配前做了除法判定，`f_svg/src/SvgFilterRenderer.cj:127`）约束 ⇒ 单个缓冲上限 **64 Mi 像素 × 4 B = 256 MiB**。而执行链把每个原语的结果都存进 `named` 直到 `runChain` 返回（`f_svg/src/SvgFilterRenderer.cj:202-251`，`named[name] = result` 在 `:247`，`previous` 只是别名），`feMerge` 还会按名同时取多个。因此峰值 ≈（原语数 + 源图 + 输出 + 线性化副本）× 区域字节：4000×4000 区域（16 Mi 像素 ⇒ 64 MiB/缓冲）+ 20 个原语 ≈ 1.3 GiB；若区域顶到 `maxPixels`，单缓冲即 256 MiB。滤镜原语数量由文档内容决定（`maxElements` 是元素总数上限，量级远大于 20），区域由元素包围盒 / `filterUnits` 决定。
- **建议**：三层按代价递增：(a) `runChain` 维护每个缓冲的最后一次引用下标，原语消费完即从 `named` 释放（`result` 未被后续 `in`/`in2` 引用时可立刻丢弃）；(b) 无别名风险时原地写回 `previous`（`SvgFilterBuffer` 已提供 `pixels: Array<Byte>`，`blur` / `flood` / `colorMatrix` 这类逐像素原语可原地完成）；(c) 对整条链的累计分配量设上限，超限抛 `SvgException(kind: Limit)`，与现有 `maxPixels` 语义一致。验证：同输入下 `getAllocatedHeapSize()` 峰值 + RSS，改前改后对照。

### [一般][存量] #3 类型化属性缓存是「无同步的惰性写」：同一 `SvgDocument` 被多线程渲染时存在数据竞争（缓存字段无锁、无原子、无 volatile）

- **位置**：`f_svg/src/SvgElement.cj:28-41`（`SvgValueCache.get` 写 `cached` / `version` / `hasCached`）、`f_svg/src/SvgElement.cj:515-523`（`transformCacheOf` 惰性建缓存）；缓存实例遍布 `f_svg/src/SvgFilterPrimitive.cj:206/237-238/265-266/301-305/385/420-424/537-538`、`f_svg/src/SvgFilterLighting.cj:23-24/97/116-117/146-147/174-176/212-219`、`f_svg/src/SvgFilter.cj:27-32`、`f_svg/src/SvgEllipse.cj:20-23`
- **来源**：存量（blame `18a60454f0` / `5e98c82764` / `2cae19b829`，快照无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 惰性初始化」
- **证据**：待确认（缺「是否允许跨线程共享同一文档」的契约；仓内无该声明，`grep -n "线程\|并发\|thread" README.md` 只命中 `README.md:37` 的 local-mode 说明）+ 静态确定（字段写路径无任何同步手段）
- **描述**：共享路径具体是：一个解析好的 `SvgDocument` 被多个 `SvgRenderer` 实例（每请求一个，以便各自持有 `warnings`）在不同线程并发 `render`；渲染读树时会调用 `element.transform`、`*Lighting.*`、`SvgFilter.*` 的 getter，首次访问即写各自元素的 `SvgValueCache`（`hasCached` / `version` / `cached` 三个普通字段，`SvgElement.cj:29-31`）。同一元素被两线程首次取同一属性时是「检查-然后-写入」，`?T` 里若为类实例（`SvgTransform`、`SvgPaint`）还存在非同步发布。`SvgElement.identity` 用了 `AtomicInt64`（`:622`），说明作者对多线程有所考虑，但缓存路径没有。
- **建议**：先定性再定改法。若明确不支持跨线程共享（推荐，代价最低）：在 `README.md` 的「限制」段落与 `SvgElement` 类注释写明「`SvgElement` / `SvgDocument` 非线程安全，跨线程使用需自行串行化或每线程各持一份」——这类声明缺失本身就是契约空白。若要求支持读并发：把类型化取值改为渲染期局部（`SvgComputedStyle` 已是渲染期构建，可扩展同款做法），或在解析完成时一次性预热全部缓存并冻结（`attributesVersion` 只在 mutation 时变，冻结后只读）。

### [轻微][存量] #4 `SvgFilterBuffer` 构造不校验 `width * height * 4` 的量级：不产出统一的 `Limit` 错误

- **位置**：`f_svg/src/SvgFilterBuffer.cj:28-35`
- **来源**：存量（blame `ec44b3adcb`）
- **判据**：review-checklist §11「缺少边界校验 / 错误类型不一致」
- **证据**：静态确定 —— 只有 `width <= 0 || height <= 0` 一个前置检查（`:29-31`），乘积直接进 `Array<Byte>(...)`
- **描述**：`SvgFilterBuffer` 是 `public` 类型，调用方可以传任意尺寸。乘积超过 `Int64` 上限时按仓颉默认溢出策略抛算术异常，而不是模块统一的 `SvgException(kind: Limit)`（对比 `f_svg/src/SvgBitmap.cj:281-282`、`f_svg/src/SvgFilterRenderer.cj:127-131` 都用 `Limit` 表达"太大"）。渲染主路径已有 `maxPixels` 前置检查，因此这是公共 API 的健壮性问题，不是当前渲染路径的缺陷。
- **建议**：构造里按"先除法后乘法"校验（`if (height > 0 && width > SVG_FILTER_BUFFER_MAX_BYTES / 4 / height) throw SvgException(..., kind: Limit)`），上限取一个模块常量并与 `maxPixels` 语义对齐；或在类注释写明"尺寸由调用方保证在 maxPixels 内"。

### [轻微][存量] #5 属性读写的模板逻辑在 4 个函数里逐行重复，已出现行为漂移（`??` 兜底与错误处理不一致）

- **位置**：`f_svg/src/SvgElement.cj:152-172`（`setAttr(name:value:)`）与 `:175-201`（`setAttr(namespace:local:value:)`）；`:204-223`（`removeAttr(namespace:local:)`）与 `:238-257`（`removeAttr(name:)`）；`f_svg/src/SvgFilterPrimitive.cj:272-287` / `:355-370` / `f_svg/src/SvgFilterLighting.cj:42-57`（`lighting-color` 默认值 `White`，另两处 `Black`）
- **来源**：存量（blame `18a60454f0` / `5e98c82764` / `2cae19b829`）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定（两两比对函数体的输入-输出-副作用：定位索引 → 保存旧值 → 替换/删除 → `attributesVersion++` → `svgNotifyMutation(Attribute, oldValue, newValue)`）
- **描述**：`setAttr` 两个重载除索引查找方式（`bareAttributeIndex` / `namespacedAttributeIndex`）和 `attributeName` 上报值外逐行对齐；`removeAttr` 两个重载同理。漂移已经发生：#8 里 `feGaussianBlur.stdDeviation` 的兜底分支不可达而 `feDropShadow.stdDeviation` 可走 `None` 分支，就是同一模板抄两遍导致的。paint 类 getter 三处（`flood-color` ×2、`lighting-color` ×1）也只差默认色常量。
- **建议**：抽两个内部辅助，落点在本文件（不新建 util 包）：`private func replaceAttributeAt(index: Int64, name: SvgAttribute, value: String, reported: String): Unit`（替换 + 版本自增 + 通知）与 `private func removeAttributeAt(index: Int64, reported: String): Bool`；paint 侧加 `internal func readPaintOr(element, name, fallback: SvgColor): SvgPaint`。合并时**保留**差异点并显式参数化：错误文案里上报的是本地名还是裸名、`removeAttr` 未命中返回 `false` 而不抛异常、`setAttr` 返回 `this` 以便链式调用。

### [轻微][存量] #6 `SvgFilterBuffer.fromBitmap` 与 `writeTo` 是同一套双向区域拷贝算法抄了两遍

- **位置**：`f_svg/src/SvgFilterBuffer.cj:37-65`（bitmap → buffer，补透明）与 `:75-95`（buffer → bitmap，裁剪）
- **来源**：存量（blame `ec44b3adcb`）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定 —— 两层 `while` + 同一组边界判断（`:51-52` vs `:82-83`）+ 同一组 4 通道逐字节赋值（`:55-58` vs `:86-89`），只有源/目标角色互换
- **描述**：两段各约 20 行，唯一语义差异是「源侧越界补 0」（目标数组已初始化为 0）与「目标侧越界跳过」，即一份是 `blit(dst=新缓冲, src=bitmap)`、另一份是 `blit(dst=bitmap, src=缓冲)`。当前两份实现一致，但任一处的边界或通道顺序改动都会造成单向漂移（例如只改 `writeTo` 的 alpha 处理，读回与写出就不再互逆）。
- **建议**：抽 `private static func blit4(source: Array<Byte>, sourceWidth: Int64, sourceHeight: Int64, target: Array<Byte>, targetWidth: Int64, targetHeight: Int64, offsetX: Int64, offsetY: Int64)`，两个方法各留 3 行壳。拷贝语义差异（补 0 vs 跳过）在 `blit4` 里天然统一为"越界不写"，因为目标都已清零；`fromBitmap` 的缓冲由构造函数清零，`writeTo` 的目标位图无需补。补一条往返用例（`fromBitmap` → `writeTo` 原地回写后除越界区外逐字节相等）。

### [轻微][存量] #7 `SvgBlendMode.fromNameOrWarn` / `SvgCompositeOperator.fromNameOrWarn` 生产路径零引用，只有测试在用

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:60-75`、`f_svg/src/SvgFilterPrimitive.cj:122-137`
- **来源**：存量（blame `11e6b765cc`）
- **判据**：review-checklist §1「仅测试使用 / 兼容残留」+ §2「只改类型名」
- **证据**：静态确定 —— 全仓 `grep -rn "fromNameOrWarn" f_svg/src` 只命中定义处与 `f_svg/src/SvgValueTypesM3_test.cj:106/113/119`；生产路径的校验与告警在 `f_svg/src/SvgBuilder.cj:557/562`（`fromName(...).isSome()` 判定，warning 由 builder 自己发）与 `SvgFilterPrimitive.cj:406/446`（getter 里直接 `fromName`，非法值静默回退默认）
- **描述**：两个函数体仅类型名与回退值（`Normal` / `Over`）、文案不同，属"只改类型名"的重复；且它们是 `internal`，仓内唯一消费者是测试 ⇒ 实际是上一版"取值即告警"设计的残留。按硬原则一，`public` 枚举本身没问题，问题在这两个 `internal` 辅助函数的去处。
- **建议**：二选一：(a) 删除两个 `fromNameOrWarn` 与对应测试，告警统一留在 `SvgBuilder`（现状就是这条路）；(b) 若希望 getter 侧也告警，把 `SvgBuilder` 的校验逻辑改成调用它们（一次共享实现），并补一个"非法 `mode` 在直接构造元素时也进 warning"的用例。保留现状则是两套告警路径并存，容易再次漂移。

### [轻微][存量] #8 `SvgFeGaussianBlur.stdDeviation` 的 `??` 兜底不可达，且错误处理与 `SvgFeDropShadow.stdDeviation` 不一致

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:212-232`（`?? SvgNumberList(Array<Float64>())` 在 `:227`）对比 `f_svg/src/SvgFilterPrimitive.cj:332-352`（`:347` 的 `?? SvgNumberList([2.0])`）
- **来源**：存量（blame `5e98c82764`）
- **判据**：review-checklist §1「恒真恒假分支」+ §11「语义与注释不符」
- **证据**：静态确定 —— 前一处的 compute 闭包返回 `SvgNumberList`（`:220` / `:224` 两个分支都是非 `Option` 值，被隐式包成 `Some`），`get` 的返回值永远 `Some`，`:227` 的 `??` 永不生效；后一处的闭包显式返回 `None`（`:342` / `:344`）才有意义
- **描述**：两处"解析失败怎么办"的语义已经分叉：`feGaussianBlur` 非法值 → 空列表（渲染层按 σ=0 处理，无 warning，`f_svg/src/SvgFilterRenderer.cj:301-316` 只在负值时报 warning）；`feDropShadow` 非法值 → `None` → 回退 2（符合 `SvgDropShadowRenderM5_test.cj:141` 钉住的行为）。注释「1 或 2 个非负标准差；缺省单个 2」只写了投影那一侧。
- **建议**：把 `feGaussianBlur` 的 getter 改成与投影同构（解析失败 `None`、外层 `??` 给该原语的规范缺省值 0），并删掉不可达的 `?? SvgNumberList(Array<Float64>())`；若坚持"非法即空列表"，请在 getter 注释里写明与投影的差异，避免下一个读者按对称性改错。

### [轻微][存量] #9 序列化不校验 PI 内容与标签名：`toString()` 可产出非良构 XML

- **位置**：`f_svg/src/SvgElement.cj:412-445`（`:437` `out.append("<?${target} ${data}?>")`、`:418-419` / `:440-442` 直接拼 `literalName`）
- **来源**：存量（blame `3ec7f9f27c`）
- **判据**：review-checklist §11「边界 / 语义与注释不符」，安全性维度（转义边界）
- **证据**：静态确定 —— 属性值走 `escapeSvgAttribute`（`:424`）、文本走 `escapeSvgText`（`:434`），CDATA 与注释都做了合法化（`serializeSvgCData` `:665-685`、`serializeSvgComment` `:688-703`），唯独 PI 与标签名是原样输出
- **描述**：`SvgElement(tag: "a><script>")` 或 `SvgNode.PiNode("p", "x?>y")` 序列化后得到 `<>` / `?>` 提前闭合，输出不再是良构 XML；若下游把它当 HTML 插入，标签名注入即可产生标签结构（属性与文本已转义，故不构成完整的 XSS 链，但契约"序列化结果是合法 XML"被破坏）。解析路径不受影响——`f_xml` 词法保证了输入侧的名字与 PI 合法。
- **建议**：`toString` 前对 `literalName` 做一次名字合法性校验（复用 `f_xml` 的 `QName` 校验，失败时抛 `SvgException(kind: InvalidValue)`）；PI 分支按 XML 规范处理 `?>`（拆成 `? >` 或直接拒绝）。若定为"调用方保证"，就在 `SvgElement` 类注释写明。

### [轻微][存量] #10 可读性残留：过期 TODO、结构体定义行格式错乱、注释措辞与行为不符、无用中间变量

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:177`（`// TODO(M3-1/M3-2): 滤镜原语基类与八个 fe* 原语模型。`）、`f_svg/src/SvgFilterLighting.cj:317`（`private struct M4LightVector {    let x: Float64`）、`f_svg/src/SvgFilterLighting.cj:376`、`:387`（`let dz = lz`）、`f_svg/src/SvgElement.cj:498-499`（注释「后代中 `class` 含指定词的第一个集合」）、`f_svg/src/SvgFilterLighting.cj:444-455`（`constant` / `exponent` 先赋默认值再按类型改写，`specularLighting` 形参只在 `case _` 用）
- **来源**：存量（blame `a708c3ee4a` / `2cae19b829` / `18a60454f0`）
- **判据**：review-checklist §3「占位 TODO」+ §10「命名 / 可读性」
- **证据**：静态确定
- **描述**：`:177` 的 TODO 说"待做"，其下方 40 行后即已实现 9 个原语类（`feGaussianBlur`…`feTile`），且数量写的是"八个"；`M4LightVector` 的大括号与首个字段挤在一行（`cjfmt` 会重排）；`dz = lz` 是从点光源代码复制到聚光灯时的残留，后面直接用的是 `dz`；`getElementsByClassName` 注释"第一个集合"读起来像"只返回第一个"，实现返回全部（`SvgElementApi.cj:373-388`，四处测试均按"全部"断言）。
- **建议**：删掉过期 TODO 或改成"设计记录：原语模型见本文件下半部"；`M4LightVector` 按标准缩进重排；`dz` 直接用 `lz`；注释改为「后代中 `class` 含指定词的**全部**元素（文档顺序，不含自身）」；`lightingFilterBuffer` 的 `constant` / `exponent` 改为在 `match` 内一次算出（`(constant, exponent, diffuse)` 三元组），形参 `specularLighting` 可在 `case _` 里保留但在注释说明它只服务于自定义子类。

### [轻微][存量] #11 定义型标签排除表不含 `symbol`：带子元素的 `<symbol>` 会从 `getBBox()` 返回包围盒

- **位置**：`f_svg/src/SvgElementApi.cj:123-128`（`case "defs" | "marker" | ... | "stop" => return None`），`symbol` 被映射为 `SvgContainer`（`f_svg/src/SvgTag.cj:69-71`）从而落到 `:145-146` 的容器分支
- **来源**：存量（blame `2ef62b12e7` / `ca72d35c36`）
- **判据**：review-checklist §11「与规格 / README 冲突」
- **证据**：静态确定（代码路径）；规格解读待确认
- **描述**：`<symbol>` 不会被直接渲染，规格上对它的 `getBBox()` 应得到空矩形；当前实现会把子元素的并集返回。现有用例只覆盖空 `<symbol>`（`f_svg/src/SvgElementApiM5_test.cj:118-125`，空子节点自然得 `None`），所以没暴露。`svgUseBBox` 对 `symbol` 是**显式**调 `svgContainerBBox`（`SvgElementApi.cj:225-229`），因此把 `symbol` 加进排除表不会破坏 `<use>` 展开。
- **建议**：把 `"symbol"` 加入 `:125-126` 的排除列表（`view` 也建议一并核对：`SvgView` 走 `SvgGeometry.bounds` 目前返回 `None`，属巧合而非显式约定）；补一条 `<symbol><rect/></symbol>` 的 `getBBox().isNone()` 用例。

<!-- 第 15 部分 -->

### [严重][存量] `feGaussianBlur` 的 `stdDeviation` 无上界，核半径与卷积量随属性线性/平方放大，没有任何拒绝路径

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:41-59`（`gaussianKernel`，`radius = Int64(ceil(3.0 * sigma))`、`Array<Float64>(size)`）；放大点 `:77-141`（`convolveHorizontal` / `convolveVertical`，内层 `while (offset <= radius)`）；入口 `f_svg/src/SvgFilterRenderer.cj:300-316`（只对负值取 0，不设上限）
- **来源**：存量（`git blame` → `6aabd4eb6a` 2026-11-05）
- **判据**：review-checklist §5「按不可信长度预分配 / 拒绝路径缺失」、§6.4「已知规模却不设上限」
- **证据**：静态确定 —— 同文件其余原语都有硬上限：`feMorphology` 半径 16（`SvgFilterPrimitives2.cj:22,934-941`）、`feConvolveMatrix` order ≤ 9（`:1015-1045`）、`feTurbulence` octaves ≤ 8（`:1179-1185`），唯独高斯模糊的 σ 一路直通 `ceil(3σ)`；属性侧 `SvgNumberList.parse` 只校验有限性（`f_svg/src/SvgNumberList.cj:93` `requireFinite`），不校验量级
- **描述**：`stdDeviation="10000"` 合法通过解析 → 核长 60001（约 480 KB 数组）+ 每像素 `4×60001` 次乘加：512×512 区域约 6.3×10¹⁰ 次运算（分钟级挂死）；σ 再放大到 1e8 则 `Array<Float64>(6e8)` ≈ 4.8 GB，直接分配失败。`feDropShadow` 走同一条路径（`:516`）。文档可完全控制该属性，构成渲染侧 DoS / OOM
- **建议**：在 `blurFilterBuffer` 入口按区域尺寸设预算（与 `SVG_FE_MORPHOLOGY_SAMPLE_BUDGET` 同风格）：`radius ≤ 某常量` 或 `w*h*(2r+1) ≤ 预算`，超限抛 `SvgException(kind: Limit)`；σ 很大时改用箱式模糊近似（三次 box blur 逼近高斯）保持视觉可接受

### [一般][存量] `named` 保留每个原语的结果（含代码自造的 `result${index}`），峰值内存按原语数线性叠加

- **位置**：`f_svg/src/SvgFilterRenderer.cj:202`（`let named = HashMap<String, SvgFilterBuffer>()`）、`:246-247`（`let name = primitive.result ?? "result${index}"` / `named[name] = result`）
- **来源**：存量（`git blame` → `ec44b3adcb` 2026-11-05）
- **判据**：review-checklist §5「无界容器 / 长期持有」、§7「缩短生命周期」
- **证据**：需实测（峰值 RSS），代码路径静态确定
- **描述**：每个原语返回新缓冲（`SvgFilterBuffer` 每次 `Array<Byte>(w*h*4)`），全部塞进 `named` 并活到整条链结束。`maxPixels` 默认 64 Mi（`f_svg/src/SvgBitmap.cj:230`）⇒ 单个满区域缓冲 256 MB，一条 3 原语链的峰值下限约 1 GB（还没算 blur 的 Float64 中间数组）。而 `result${index}` 这种合成名按 SVG 规范不可被引用，纯属白占内存
- **建议**：只在 `primitive.result.isSome()` 时写入 `named`；预扫一遍 `in`/`in2` 引用集合，未被引用的具名结果在下一个原语执行后释放（`named.remove`），把峰值从 O(#primitive) 压到 O(#活跃引用)

### [一般][存量] 高斯模糊边界不补边：越界抽头直接跳过但不重新归一化，区域边缘整体变暗

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:94-97`（水平）、`:127-130`（垂直），核在 `:53-57` 已按全核归一化
- **来源**：存量（`git blame` → `6aabd4eb6a` 2026-11-05）
- **判据**：review-checklist §11「语义与实现不符」、§10 正确性（边界处理）
- **证据**：静态确定 —— 边界像素只累加在界内的 `2r+1-|offset|` 个抽头，权重和严格小于 1，输出必小于输入
- **描述**：SVG 要求滤波输入按「边缘像素向外复制」无限延展（duplicate 语义），同模块 `feConvolveMatrix` 的 `edgeMode=duplicate` 就是这么做的（`SvgFilterPrimitives2.cj:1146-1147` `clampSvgIndex`）。模糊路径却按「透明外延」处理，导致 `filterUnits="userSpaceOnUse"` 且区域等于元素包围盒时，模糊结果四周出现一圈衰减（`feDropShadow` 的阴影边缘同样受影响）。当默认 `objectBoundingBox` 区域外扩 10% 时，内容区离边界较远，问题被掩盖
- **建议**：`convolveHorizontal` / `convolveVertical` 越界时取 `clampSvgIndex(sourceX, width)` 而不是跳过，即与 `convolveSample` 的 duplicate 分支共用同一取址逻辑

### [一般][存量] `feDropShadow` 的区域外扩量没有按 `primitiveUnits` 换算，`objectBoundingBox` 下阴影被区域裁掉

- **位置**：`f_svg/src/SvgFilterRenderer.cj:75-83`（`localX -= shadowMargin` 等）＋ `:419-450`（`dropShadowRegionMargin` 只用 `shadow.dx.value` / `stdDeviation` 原值）；对照 `:516-521`（真正执行时 `dx*scaleX`、`σ*scaleX`）
- **来源**：存量（`git blame` → `359da01ac7` 2026-11-06）
- **判据**：review-checklist §11「契约与实现不符」、正确性（边界）
- **证据**：静态确定 —— `dropShadowRegionMargin(filter)` 签名里没有 `objectBounds` / `scaleX`，无法感知 `primitiveUnits`
- **描述**：`primitiveUnits="objectBoundingBox"` 时 `dx="0.1"` 的实际偏移是 `0.1 × bbox 宽 × CTM`（渲染端已乘 `primitiveScaleX`，`:519`），而区域外扩只加 0.1 用户单位。包围盒 200 px 时阴影外扩少 20 px，右侧/下侧阴影被区域直接裁断。`:75-76` 的注释「objectBoundingBox 与 userSpaceOnUse 的 local 坐标都在用户空间，可共用同一外扩量」是错误前提：坐标空间相同，但**数值单位不同**（一个是 bbox 比例，一个是用户单位）
- **建议**：`dropShadowRegionMargin` 增加 `primitiveObjectUnits` 与 `objectBounds` 参数，把 `dx/dy/σ` 先乘 `objectBounds.width/height`；或让 `region` 直接复用 `apply` 里算好的 `primitiveScaleX/Y`

### [一般][存量] `stdDeviation` 语义在 5 处各写一遍，缺省值与负值处理不一致（0 与 2 两种）

- **位置**：`f_svg/src/SvgFilterRenderer.cj:300-316`（blur 分支：缺省 0、负值取 0）、`:419-445`（区域外扩：缺省 2、负值回退 2）、`f_svg/src/SvgFilterPrimitives.cj:497-515`（dropShadow：缺省 2、负值回退 2）、`f_svg/src/SvgFilterPrimitive.cj:212-232`（`SvgFeGaussianBlur.stdDeviation`：解析失败给空列表）、`:331-348`（`SvgFeDropShadow.stdDeviation`：解析失败给 `[2.0]`）、`f_svg/src/SvgFilterPrimitives2.cj:296-306`（`readSvgNumberList`：解析失败给 `None`）
- **来源**：存量（各 `git blame` 落在 2026-11-05 ~ 11-07 的不同提交）
- **判据**：review-checklist §2「换控制流 / 跨层复制」「近似重复：其中一块少了边界判断」
- **证据**：静态确定 —— 三处渲染端代码逐行同构（`deviations.size==1 / >=2 / 负值` 三段判断），只是缺省值一个 0 一个 2
- **描述**：同一个属性「1 或 2 个非负标准差」被解释 5 次，其中缺省值分两派（0 与 2）。当前靠「blur 缺省 0」「dropShadow 缺省 2」的巧合跟规范对齐（`feGaussianBlur` 缺省 0、`feDropShadow` 缺省 2），但改其中一处极易漂移——例如将来给 blur 支持 `feDropShadow` 式缺省，就会静默改变所有 `stdDeviation` 缺失的文档输出
- **建议**：在 `SvgFilterPrimitives.cj` 提 `internal func gaussianSigmas(deviations: SvgNumberList, defaultSigma: Float64): (Float64, Float64)`，渲染端三处统一调用；模型层统一用 `readSvgNumberList` + 显式缺省参数

### [一般][存量] `feDropShadow` 的 `flood-color` 在渲染层重复解析，绕过类型化属性并与 `feFlood` 行为不一致

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:522-535`（`match (shadow.attr("flood-color")) { ... tryParseSvgPaint(text) ... }`）；对照 `f_svg/src/SvgFilterRenderer.cj:323-328`（`feFlood` 直接用 `flood.floodColor.color`）与 `f_svg/src/SvgFilterPrimitive.cj:354-367`（`SvgFeDropShadow.floodColor` 已实现同一解析 + 黑色缺省）
- **来源**：存量（`git blame` → `9858013907` 2026-11-07）
- **判据**：review-checklist §2「跨层复制」「字面量复制」、§11「契约与实现不符」
- **证据**：静态确定 —— 两处都是 `tryParseSvgPaint` + 黑色兜底，但只有渲染层这版会追加 warning `"feDropShadow 的 flood-color「…」不合法，回退黑色"`，模型属性静默回退
- **描述**：同一属性两套解析。若将来 `SvgPaint` 的解析扩展（如 `currentColor`、`context-fill`），渲染层这份拷贝不会跟着变；反之模型层加了 warning 也不会传到这里。此外 `feDropShadow.floodColor` 是公开 API，用户读到的值与渲染用的值可能不同源
- **建议**：改为 `match (shadow.floodColor.color)`，warning 移到模型层属性 getter（或在渲染端判断 `shadow.attr("flood-color").isSome() && 解析失败`），与 `feFlood` 分支合并

### [一般][存量] `feTurbulence` 的坐标换算既无上界也无零除保护，可产生 NaN / 越界整数转换

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:1210-1218`（`octaveFrequencyX = frequencyX / scaleX`；`Float64(x) * octaveFrequencyX`；`seed + octave * 1013`）、`:1250-1251`（`Int64(floor(x))`）、`:1236`（`UInt8(Int64(round(clampSvgUnit(value) * 255.0)))`）；`scaleX/scaleY` 来源 `f_svg/src/SvgFilterRenderer.cj:145-150`
- **来源**：存量（`git blame` → `2cae19b829` 2026-11-06）
- **判据**：review-checklist §11「边界 / 空值未处理」「除零」、§5「按不可信长度预分配」同类
- **证据**：需实测（`Float64 → Int64` 对 NaN/越界值的具体行为），路径静态确定
- **描述**：三条触发路径都只需文档属性：① `primitiveUnits="objectBoundingBox"` ＋ 零宽或零高包围盒（水平/竖直线、`<rect width="0">`）⇒ `scaleY == 0`，`frequencyY / 0` 得 `Inf`，`0 * Inf` 得 NaN；② `transform="scale(0,…)"` 同理；③ `baseFrequency="1e30"`（有限、通过 `isFiniteSvgNumber`）⇒ `x*1e30` 远超 `Int64` 范围。之后 `Int64(floor(NaN))` / `Int64(floor(1e33))` 按语言默认溢出策略会抛异常，而 `apply` 全程不捕获——整份文档渲染失败，且抛出的不是 `SvgException`，调用方的 `catch (SvgException)` 兜不住。另 `seed` 接近 `Int64` 上界时 `seed + octave*1013` 也会整型溢出
- **建议**：`scaleX/scaleY <= 0` 时直接按 0 频率处理并 warning；`baseFrequency` 上限（如 1e4）与 `seed` 收敛（如取模 2¹⁶）后再进噪声；把 `Int64(浮点)` 转换统一包成 `safeSvgInt(value, fallback)`，避免非 `SvgException` 逃逸

### [一般][存量] 数字列表属性 getter 直接把内部缓存数组交给调用方（引用逸出，缓存不会失效）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:351-361`（`tableValues` 返回 `list.values`）、`:525-535`（`kernelMatrix`）、`:489-497`（`radius` 返回缓存内的 `SvgNumberList`）、`:651-661`（`baseFrequency`）
- **来源**：存量（`git blame` → `e30f1afd13` 2026-11-06）
- **判据**：review-checklist §10「仓颉语言特性：值 / 引用语义」、§11「契约与实现不符」
- **证据**：静态确定 —— `SvgNumberList` 是 `struct`，但字段 `public let values: Array<Float64>`（`f_svg/src/SvgNumberList.cj:47-52`）是引用类型；`SvgValueCache` 只在 `attributesVersion` 变化时重算（`f_svg/src/SvgElement.cj:33-40`），数组内容被外部改写不会触发版本变化
- **描述**：`let kv = matrix.kernelMatrix; kv[0] = 99.0` 会直接改掉缓存里的数组，之后 `kernelMatrix` 读到的已是脏值，而 `attributesVersion`、序列化文本都没变。渲染结果因此依赖「调用方是否手滑改过数组」，且无法通过 `setAttr` 之外的手段复原。同类问题在 `radius`/`baseFrequency` 上是把整个缓存 `SvgNumberList` 交出去（其 `values` 同样可写）
- **建议**：getter 返回 `list.values.clone()`（256 项以内的开销可接受），或把缓存值改成不可变视图；文档层面在 README 声明「返回副本」

### [一般][存量] 字体别名解析丢弃请求的 stretch，`@font-face` 别名 family 的 `font-stretch` 会选错字面

- **位置**：`f_svg/src/SvgFont.cj:158-175`（`delegate.resolveDetailed(targetName, weight, style, stretch: 100.0)`）
- **来源**：存量（`git blame` → `8230d8b455` 2026-11-07）
- **判据**：review-checklist §11「契约与实现不符」、§10 正确性
- **证据**：静态确定 —— 别名分支把调用方传入的 `stretch` 丢掉，硬编码 100.0，并把委托结果的 `stretch` 原样返回
- **描述**：注释写明「别名 family 先映射到目标 family，再委托 base 解析」，但委托时把请求的 stretch 换成 100。目标 family 同时注册 80% 与 120% 两个字面、文档写 `font-stretch: 120%` 时，会拿到 100 的最近邻（80% 字面，`nearestStretch` 平局取先注册者，`:213-233`），再以「请求 120 / 命中 80」合成 1.5 倍缩放——`SvgTextRenderer` 正是用 `resolved.stretch` 决定是否合成（`f_svg/src/SvgTextRenderer.cj:417-424`）。结果既不是 120% 字面，也多做了一次水平缩放，字宽/字重都不对
- **建议**：透传 `stretch: target`；若确实要「别名不参与 stretch 匹配」，则应在 `SvgFontMatch` 里显式区分「未参与匹配」与「命中 100%」，而不是用 100.0 冒充

### [一般][存量] `feTurbulence` 的 `stitchTiles` 已建模但渲染端从不读取（承诺了未实现）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:689-704`（`stitchTiles` 属性，读写齐全）；渲染端 `:1172-1247`（`turbulenceFilterBuffer` 全文无 `stitchTiles` 引用）
- **来源**：存量（`git blame` → `e30f1afd13` 2026-11-06）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」
- **证据**：静态确定 —— 全仓 grep `stitchTiles` 仅命中属性定义、`SvgBuilder.cj:577` 的值映射与 3 个测试断言，`f_svg/src` 内无任何渲染侧读取
- **描述**：**承诺源**：`f_svg/doc/f_svg-M4设计.md:18` 与 `:107`（`feTurbulence` 能力列 `stitchTiles`）、`f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md:92`（"SHALL 提供 … `stitchTiles`"）。**缺失证据**：渲染实现里没有任何 `stitchTiles` 分支，噪声始终按非 stitch 生成。用户按文档写 `stitchTiles="stitch"` 得到与 `noStitch` 完全相同的输出（平铺 seams 依旧存在），且无 warning
- **建议**：要么在 `turbulenceFilterBuffer` 实现 stitch（周期化梯度格点，按 tile 尺寸对齐 baseFrequency），要么在文档与 README 的能力表把 `stitchTiles` 标为「仅建模、不影响渲染」并加 warning，避免"写了不生效"

### [轻微][存量] 四个 `fromNameOrWarn` 在生产路径上零调用，仅被测试引用（接线缺失 + 可见性建议）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:66-81`（`SvgTransferFunctionType`）、`:112-127`（`SvgMorphologyOperator`）、`:167-182`（`SvgEdgeMode`）、`:276-291`（`SvgTurbulenceType`）；同类 `:230-245`（`SvgChannelSelector`）
- **来源**：存量（`git blame` → `e30f1afd13` / 更早的 `6aabd4eb6a`）
- **判据**：review-checklist §1「仅测试使用 → 可见性建议」、§14.1「接线缺失」
- **证据**：静态确定 —— 全仓 grep 五个符号只命中 `f_svg/src/SvgValueTypesM4_test.cj:152,162,166,170,173`；生产 getter 一律走 `fromName(...) ?? 缺省`（如 `:336-344`、`:474-482`、`:587-595`、`:636-644`），非法值静默回退
- **描述**：`fromNameOrWarn` 的设计意图是「非法值 + warning」，但没有任何解析/构建路径调用它，于是 `type="wat"` 静默变 identity、`operator="wat"` 静默变 erode，用户拿不到诊断。`f_svg/doc/spec/add-f-svg-m3/verification.md:479` 已记录同类问题（`SvgBlendMode` / `SvgCompositeOperator` / `SvgMarkerOrient`）
- **建议**：二选一——在 `SvgBuilder` 的属性分派里接上这些 helper（非法值进 `warnings`），或删除并在 README 声明「非法枚举值静默回退」；不要保留只服务测试的分支

### [轻微][存量] 卷积核与颜色矩阵的「非有限值」校验在属性路径上不可达，对应测试实际走的是长度不符分支

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:1053-1057`（`kernel` 有限性循环）、`:355-360`（Matrix 20 值有限性）、`:368-371`（saturate）、`:383-386`（hueRotate）；测试 `f_svg/src/SvgFilterPrimitives2M4_test.cj:319-323`
- **来源**：存量（`git blame` → `e30f1afd13`）
- **判据**：review-checklist §1「恒假分支」、§11「测试覆盖与实现不符」
- **证据**：静态确定 —— 解析侧 `SvgNumberList.parse` 用 `requireFinite` 拒绝 NaN/Inf（`f_svg/src/SvgNumberList.cj:93`，`"1e999"` 亦抛 `InvalidValue`，见 `SvgNumberList_test.cj:112-115`）；写回侧 `writeSvgNumberArray` 经 `SvgNumberList.toString()` → `formatSvgNumber` 对非有限值抛 `InvalidValue`（`f_svg/src/SvgNumber.cj:33-35`）。所以 `kernel.values` 永远有限
- **描述**：`invalid.setAttr("kernelMatrix", "0 0 0 0 nan 0 0 0 0")` 在 `readSvgNumberList` 里就抛 `SvgException` 被吞成 `None`，`kernelMatrix` 得到空数组，命中 `:1047-1051` 的「长度不符」warning——测试只断言 `warnings.size > 0`，所以「非有限值」这条分支从未被覆盖，实际是被测路径与用例名不符
- **建议**：把有限性校验前移到 `readSvgNumberList`（解析即报具体原因），或删除这四处不可达分支；测试改用 `SvgNumberList([Float64.NaN])` 直接调用 `convolveFilterBuffer` 才能真正打到该分支，并断言 warning 文案

### [轻微][存量] 过时注释：文件中部仍写着「原语实现与元素模型在后续任务中补齐」

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:294`
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 维护性」、§11「语义与注释不符」
- **证据**：静态确定 —— 紧随其后的 `:296-1456` 已是完整的元素属性、`feFunc*`、`feMorphology`/`feConvolveMatrix`/`feTurbulence`/`feDisplacementMap`/`feImage` 实现
- **建议**：删除该行，或改成「以下为原语属性模型与实现」的分节注释

### [轻微][存量] 未知原语静默直通且不记 warning

- **位置**：`f_svg/src/SvgFilterRenderer.cj:368`（`case _ => input.copy()`）
- **来源**：存量（`git blame` → `ec44b3adcb` 2026-11-05）
- **判据**：review-checklist §3「case _ 兜底把错误吃掉」、§10 错误处理
- **证据**：静态确定 —— 同一函数里「输入引用不存在」都会 `warnings.add`（`:213-215`），这里唯一不给诊断
- **描述**：`SvgFilterPrimitive` 是 `public abstract class`（`f_svg/src/SvgFilterPrimitive.cj:180`，非 sealed），下游可以定义自己的子类；一旦接入 `SvgFilter`，该原语会被静默当作直通，用户无法知道某段滤镜没生效
- **建议**：`case _ =>` 里 `warnings.add("不支持的滤镜原语「${primitive.tag}」，按直通处理")` 后再 copy

### [轻微][存量] `positiveMod` 与 `positiveSvgMod` 两份同语义实现，守卫条件不同

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:477-487`（有 `modulus <= 0 → 0` 守卫）、`f_svg/src/SvgFilterPrimitives2.cj:1153-1160`（无守卫）
- **来源**：存量
- **判据**：review-checklist §2「换控制流 / 只改名字」
- **证据**：静态确定 —— 逐行比对：两者都是 `value % modulus`，负则 `+ modulus`，唯一差异是前者多一条 `modulus <= 0` 早退
- **描述**：现有调用方都保证 `modulus > 0`（`tileFilterBuffer` 的 tile 尺寸、`convolveSample` 的缓冲宽高），暂无行为差异；但两份实现意味着将来只修一处（例如都改成 `@OverflowWrapping` 或都加零守卫）就会留下不一致
- **建议**：合并到 `SvgFilterPrimitives2.cj` 保留带守卫的一版并改名 `positiveSvgMod`，`tileFilterBuffer` 改调用它

### [轻微][存量] 4 字节像素搬运循环写了 4 份

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:156-159`（`offsetFilterBuffer`）、`:432-435`（`tileFilterBuffer`）、`f_svg/src/SvgFilterPrimitives2.cj:1446-1449`（`feImageFilterBuffer`）、`f_svg/src/SvgFilterRenderer.cj:107-111`（空滤镜链复制整幅位图）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」「只改类型名」
- **证据**：静态确定 —— 四处都是 `target[base]=src[base]; +1; +2; +3` 四行展开；`SvgFilterBuffer.fromBitmap`（`f_svg/src/SvgFilterBuffer.cj:55-58`）与 `writeTo`（`:86-89`）已有第 5、6 份
- **描述**：改一处格式（例如将来引入预乘 alpha 或改字节序）必须同步 6 个位置，漏改就是「同一张图里 tile 与 offset 结果对不上」这类难查的偏色
- **建议**：在 `SvgFilterBuffer` 加 `internal func copyPixel(from: Int64, to: Int64, source: SvgFilterBuffer)` 或直接复用 `Array<Byte>.copyTo`（`pixels[targetBase..targetBase+4] = source.pixels[sourceBase..sourceBase+4]`），四处统一调用

### [轻微][存量] `tileContentBounds` 计算的 x/y/w/h 只有「是否为空」被使用，额外三个值无消费者

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:444-475`（返回 `[minX, minY, w, h]`）；唯一调用方 `f_svg/src/SvgFilterRenderer.cj:344`（`tileContentBounds(input).size == 0`）
- **来源**：存量
- **判据**：review-checklist §1「读了不用」、§6.4「只判存在却全量扫描」
- **证据**：静态确定 —— 全仓只有这一处调用，且只取 `.size`
- **描述**：函数做完整包围盒扫描（4 个 min/max 更新）却只回答「有没有非透明像素」；调用方因此每次 `feTile` 都要扫满整块区域才能开始平铺
- **建议**：改为 `internal func tileHasContent(input): Bool`，命中第一个 alpha > 0 即返回；若将来需要包围盒裁剪 tile 周期，再单独留 `tileContentBounds`

### [轻微][存量] 测试文件命名与内容不符，个别变量名与实际方向相反

- **位置**：`f_svg/src/SvgFilterPrimitive_test.cj`（同文件含 `SvgFilterPrimitive_test` `:62`、`SvgFilterChainM3_test` `:253`、`SvgFilterPrimitiveUnitsM3_test` `:327`、`SvgColorMatrixValidationM3_test` `:397`）；`f_svg/src/SvgFilterRenderer_test.cj`（含 `SvgFilterBuffer_test` `:32`、`SvgFilterRenderer_test` `:65`、`SvgFilterRegionOrderM3_test` `:261`、`SvgFilterAttributeM3_test` `:285`、`SvgFilterPercentRegionM3_test` `:326`）；`SvgFilterPrimitive_test.cj:79-81`（变量 `horizontalOnly` 实际传 `(0.0, 2.0)`，是**垂直**方向）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 维护性」
- **证据**：静态确定 —— 文件名与 `@Test` 类名一一对不上；`:79-81` 断言 `x=6` 处 alpha 为 0、`y=6` 处大于 0，正是垂直模糊的特征
- **建议**：按类名拆分/重命名文件；变量改名 `verticalOnly`（或把参数改成 `(2.0, 0.0)` 与名字对齐）

<!-- 第 16 部分 -->

### [严重][存量] #1 渐变采样器按「像素」累积 warning，渲染路径既不读取也不去重

- **位置**：`f_svg/src/SvgGradient.cj:205`（`public let warnings`）、`:254`、`:256`、`:344`、`:347`、`:466`、`:487`（6 处 `warnings.add`）
- **来源**：存量（`git blame` 均落在 `f0d369c020` 2026-11-07，快照模式无 diff 可比）
- **判据**：review-checklist §5「无界容器 / 全局集合只增不减」+ §3「静默吞异常（诊断丢失）」
- **证据**：静态确定 —— `SvgRasterizer.fillGradient/strokeGradient` 在**逐像素闭包**里调用 `sampler.sample(...)`（`f_svg/src/SvgRasterizer.cj:211-219`、`:269-277`），而 `sample()` 的 4 条路径无条件（无去重、无一次性标记）向实例字段 `this.warnings` 追加字符串：`radialT` 的 `fr`/`FR` 提示与 `r <= 0` 提示（`:343-349`）、`gradientTransform` 解析失败/不可逆（`:254`、`:256`）、`href` 循环与目标缺失（`:466`、`:487`）
- **描述**：
  1. **无界增长**：`warnings` 生命周期 = 一次 fill，但增长量 = 覆盖像素数。以默认 `maxPixels = 64 Mi`（`f_svg/src/SvgBitmap.cj:230`）计，一个 `r="0"` 的径向渐变填充整块画布会生成 6.4e7 条字符串（每条 60–80 B + 槽位），数百 MB 到 GB 级，属于「到 OOM 才知道」的增长面；1000×1000 的常见画布也已是约 1e6 条 / 约 100 MB。
  2. **诊断丢失**：`sampler` 是 `fillGradient`/`strokeGradient` 的局部变量，`sampler.warnings` 在 `SvgRasterizer` 与 `SvgRenderer`（`grep "sampler.warnings"` 在 `f_svg/src/SvgRasterizer.cj` 零命中，`SvgRenderer.cj` 全文无 `catch`）中**从未被读取或合并**，因此渲染期产生的渐变告警（不可逆矩阵、循环 href、r≤0）全部丢弃，而内存照付。
- **建议**：把「解析一次」与「采样每点」拆开——在 `fillGradient` 入口调用一次 `resolveChain` + `resolveStops` + `gradientTransform` 求逆，得到的不可变快照传入逐像素闭包；warning 只在解析阶段写一次，并由 `SvgRasterizer` 暴露 `warnings` 让 `SvgRenderer` 合并进渲染告警。若短期不改结构，至少给 6 处 `warnings.add` 加 `if (this.warnings.size < N)` 上限并让调用方读取。

### [严重][存量] #2 GSUB coverage format 2 按文件声明长度全量展开，可被单个小字体放大成 GB 级内存

- **位置**：`f_svg/src/SvgGsubContext.cj:217-229`（`gsubCoverage` format 2）
- **来源**：存量（同一函数体亦复制于 `f_svg/src/SvgOpenTypeLayout.cj:481-493`，见「重复逻辑」条目）
- **判据**：review-checklist §5「按不可信长度预分配 / 一次性物化」，§4「OOM 面」
- **证据**：静态确定 —— `count = reader.u16(offset + 2)` 与每段的 `start/end = reader.u16(...)` 全部来自字体字节，循环 `while (glyph <= end) result.add(glyph)` 无任何上限、无总量校验；`gsubReadCoverages`（`:233-243`）对每个 coverage 偏移各调用一次，`gsubParseContextSubtable` 的 `inputCount/backtrackCount/lookaheadCount` 均为 u16
- **描述**：单段最多 65536 个字形，单 coverage 最多 65535 段 ⇒ 理论上限约 4.29e9 个 `Int64`（≈34 GB），而驱动这些数字的输入仅需约 393 KB（65535 × 6 B）。字体字节来自 `SvgTrueTypeFont.parse(bytes)`（`@font-face` / data URI，属文档可控输入），因此一个几百 KB 的恶意字体即可在解析期耗尽内存或长时间卡死（外层 `try/catch (SvgException)` 无法拦截 OOM/长时间循环）。同时该展开也发生在 GPOS 侧 `parseGposCoverage` / `parseGposClassDef`。
- **建议**：coverage 内部改用「区间表示」（`Array<(Int64, Int64)>` + 二分查找）代替展开；必须展开时加总量上限（如 `coverage 展开总数 ≤ 4 × CSS_GSUB_MAX_INPUT` 或与 `reader.length` 挂钩的放大比上限），超限 warning + 丢弃子表。查找函数 `arrayContainsSvgGlyph` 改为区间二分。

### [一般][存量] #3 `SvgFontFeatures.fromStyle` 把 parse 结果里的「默认开关」一起复制，静默重置 `font-variant-ligatures`

- **位置**：`f_svg/src/SvgFontVariant.cj:199-205`（合并循环）；根因在 `:116-126`（私有构造预置 6 个默认开关）与 `:160-174`（`parse` 以该构造函数为基底）
- **来源**：存量（`git blame`：`f0d369c020` 2026-11-07）
- **判据**：review-checklist §11「语义与注释/实现不符」、§10 正确性
- **证据**：静态确定 —— `fromStyle` 先用 `fontVariantLigatures()` 写 `result`（`:187-198`），随后 `for ((tag, value) in explicit.switches) result.set(tag, value)`；而 `explicit` 由 `SvgFontFeatures.parse` 构造，其 `switches` 里**始终含默认值** `liga=true, clig=true, dlig=false, hlig=false, calt=false, kern=true`
- **描述**：`font-variant-ligatures="none"` + 任意 `font-feature-settings`（例如只写 `"dlig" 1`）时，默认值 `liga=true / clig=true` 会把前一步的 `none` 覆盖回开启，连字被意外启用。这与 `:176` 注释承诺的「variant-ligatures 先，font-feature-settings 覆盖」相反——覆盖面被扩大成「整张默认表」。现有用例 `SvgFontDetailsM6_test.cj:215-235` 只断言了被显式写入的 `liga`/`kern`，覆盖不到该分支。
- **建议**：`parse` 区分「默认值」与「显式条目」（例如只在 `explicitCount > 0` 的 tag 上合并，或让 `parse` 返回 `ordered` 中的显式 tag 列表再合并），`fromStyle` 只按显式 tag 覆盖；顺带用 `ordered` 而非 `switches` 迭代，恢复 `toString()` 的确定性顺序（HashMap 遍历顺序不稳定，`ordered` 会被打乱）。

### [一般][存量] #4 `font-variant-ligatures` 的 `no-*` 与多关键字值被解析层接受，但合取层无分支，静默不生效

- **位置**：`f_svg/src/SvgFontVariant.cj:187-198`（`match (style.fontVariantLigatures())` 只有 5 个单值 case + `_ => ()`）
- **来源**：存量
- **判据**：review-checklist §14.1「只做了一半的分支 / 开关只在一处判断」、§13「规格与实现漂移」
- **证据**：静态确定 —— `SvgStyleResolver.cj:837-845` 用 `textLower.contains("common-ligatures")` 等条件放行 `no-common-ligatures`、`no-discretionary-ligatures`、`common-ligatures discretionary-ligatures` 等值并原样写入计算样式；`fromStyle` 的 `match` 只有 `"none" / "common-ligatures" / "discretionary-ligatures" / "historical-ligatures" / "contextual"`，其余落到 `case _ => ()`
- **描述**：合法值 `font-variant-ligatures="no-common-ligatures"` 被样式层当作合法值接受（无 warning、不进 `SvgStyleSource` 回退），但整形时 `liga/clig` 保持默认开启，用户看到的是「设置无效且无任何提示」。多关键字组合（`common-ligatures no-discretionary-ligatures`）同样整条失效。
- **建议**：把该属性解析成结构化位集合（`liga/clig/dlig/hlig/calt` 五路，各含 on/off），在 `SvgStyleResolver` 归一化阶段生成规范串（如 `liga=1,clig=0,...`），`fromStyle` 只按该规范串赋值；无法识别的 token 必须 warning。

### [一般][存量] #5 渐变 stop 的 `stop-color` / `stop-opacity` 只读 XML 属性，忽略 CSS 与 `style=`

- **位置**：`f_svg/src/SvgGradient.cj:416-428`（`stop.attr("stop-color")` / `stop.attr("stop-opacity")`）
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失：配置/能力已实现但没人用」
- **证据**：静态确定 —— `stop-color` / `stop-opacity` 已是模块注册的 CSS 属性并有取值函数（`f_svg/src/SvgComputedStyle.cj:109-110`、`:351-358`），样式层也做了归一化（`f_svg/src/SvgStyleResolver.cj:557-562`、`:394`），但采样器完全不接触 `SvgComputedStyleTree`，只读元素属性
- **描述**：`<stop style="stop-color:red"/>`、`<style>stop{stop-color:#0f0}</style>`、`<stop class="c"/>` 三种写法在渲染时全部退化成 `SvgColor.Black`（`:423`），而 `getBBox`/样式 API 侧却报告已解析的颜色，形成「样式层有值、采样层不用」的分裂。测试只覆盖了属性写法（`SvgGradientSampler_test.cj:22-34` 的 `addStop` 走 `setAttr`）。
- **建议**：`SvgGradientSampler` 增加 `styles!: ?SvgComputedStyleTree` 参数（`root` 已具备），`resolveStops` 优先取 `styles.get(stop)?.stopColor()/stopOpacity()`，属性作为回退；同时把 `offset` 也走 `SvgStop.offset` 语义（当前 `tryParseSvgOffset ?? 0.0` 会静默把非法 offset 当 0）。

### [一般][存量] #6 `rect` 的 miter 尖角几何用未套计算样式的属性值，与 `rectBounds` 的取值口径不一致

- **位置**：`f_svg/src/SvgGeometry.cj:766-781`（`collectMiterPolylines` 的 `case rect`）；对照 `:283-298`（`rectBounds` 走 `svgStyledLength`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符 / 同一量两套算法」、§2「近似重复且一块少了边界判断」
- **证据**：静态确定 —— `rectBounds` 用 `svgStyledLength(style, "width", rect.width)`（样式优先、属性回退），而同文件 miter 分支直接用 `rect.width`/`rect.height`/`rect.x`/`rect.y`
- **描述**：`width/height/x/y` 是模块已注册的 CSS 几何属性（`SvgComputedStyle.cj:124-127`）。当作者用 CSS/内联样式改写 rect 几何时，`SvgGeometry.strokeBounds`（公开 API，`SvgElementApi.cj:155` 用于 `getBBox` 含描边口径）先按样式算盒、再按属性算尖角：尖角位置偏离，既可能漏掉真实尖角（裁剪/剔除裁掉描边端点），也可能凭空外扩。`path` 分支（`:782-857`）同样没有 `style` 可用，属同一根因。
- **建议**：`collectMiterPolylines` / `miterTips` 增加 `style: ?SvgComputedStyle` 参数并复用 `svgStyledLength`；无法获得样式时显式说明「按属性口径」。

### [一般][存量] #7 无 `stop` 的渐变按不透明黑填充

- **位置**：`f_svg/src/SvgGradient.cj:234-236`（`if (stops.size == 0) { return SvgColor.Black }`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」
- **证据**：待确认（规范口径）—— SVG 规范规定「渐变未定义任何 stop 时按 `none` 处理（不绘制）」；仓内 `f_svg/doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md:9-32` 未记载该场景，故不能据仓内文档定性
- **描述**：`<linearGradient id="g"/>` 被 `fill="url(#g)"` 引用时，采样器返回 `SvgColor.Black`，渲染器（`SvgRenderer.cj:538-585` 无 stop 数量检查）会画出一整块不透明黑，而正确行为是「该元素不绘制」。同理 `chain.size == 0`（`:226-229`）返回黑色也是不透明兜底。
- **建议**：无 stop 时返回 `SvgColor(0,0,0,alpha: 0.0)`（与 `r<=0` 分支 `:268-270` 的处理一致），或在 `SvgRenderer` 侧遇到 0 stop 直接跳过该 paint；两条路径择一，不要一边透明一边黑。

### [一般][存量] #8 GSUB/GPOS 解析与连字匹配在两条整形路径上各写一份，且已出现告警漂移

- **位置**：`f_svg/src/SvgGsubContext.cj:197-206`（`gsubTag`）≡ `f_svg/src/SvgOpenTypeLayout.cj:34-43`（`cssLayoutTag`）；`:176-195` ≡ `SvgOpenTypeLayout.cj:45-57`；`:156-174` ≡ `:69-90`；`:209-231` ≡ `:473-495`（`parseGposCoverage`，逐行相同）；`:343-385` ≈ `:614-686`（`parseGsubLigatureSubtable`）；`:581-614`（Type 4 最长匹配）≡ `SvgOpenTypeLayout.cj:541-573`（`findLigature`）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 跨层复制的重复逻辑」+「近似重复往往同时是缺陷」
- **证据**：静态确定 —— 函数体逐行对齐，差异仅在函数名与容器类型；两条路径在生产代码中**同时存活**（`f_svg/src/SvgTrueTypeFont.cj:273-296` 先解析 3 份 `SvgGsubLigatures`（liga/hlig/clig），再解析 1 份 `SvgGsubContextTable`，四次都从同一份 GSUB 字节重新走 ScriptList→FeatureList→LookupList）
- **描述**：同一份 OpenType 表被两套实现解析，已产生可观察漂移：① `componentCount < 2` 时 M6 静默 `continue`（`SvgGsubContext.cj:366-368`）而 M5 会 `warnings.add`（`SvgOpenTypeLayout.cj:655-658`）；② M5 逐字段做截断判断并给出「子表/连字集/连字记录/连字组件截断」四种定位信息（`SvgOpenTypeLayout.cj:620-672`），M6 全部依赖 `reader` 抛异常后统一成一条「GSUB 上下文表截断」（`SvgGsubContext.cj:508-511`），可诊断性下降。此外每次加载字体把 GSUB 全表解析 4 遍（见 CPU 优化方案）。
- **建议**：抽出 `f_svg` 内共享的 `SvgOpenTypeTables`（coverage/tag/LangSys/FeatureList/LookupList/Extension 解析 + 区间化 coverage），M5/M6 只保留各自的应用语义（`findLigature` 返回下标 vs `applyLookupAt` 就地改写）；GSUB 表只解析一次，按 tag 建立 `tag → lookup 索引` 视图供三条 ligature 通道复用。

### [轻微][存量] #9 死字段：`SvgGsubContextSubtable.chained` 只写不读

- **位置**：`f_svg/src/SvgGsubContext.cj:53`（声明）、`:66`（赋值）
- **来源**：存量
- **判据**：review-checklist §1「读了不用 / 兼容残留」；`chained` 是 `private class` 字段，全仓搜 `\.chained` 仅命中定义与赋值（`:60`、`:66` 为构造参数）
- **证据**：静态确定 —— `coversInput`（`:73-100`）与两个调用点都不读该字段，链式与非链式的差异完全由 `gsubParseContextSubtable` 的入参 `chained`（`:249`）决定
- **描述**：字段无语义用途，保留会让人误以为 Type 5/6 可共用同一子表实例
- **建议**：删除字段与构造参数，或改为真正的 `isChained()` 并在 `coversInput` 中用于区分回溯段校验

### [轻微][存量] #10 三处恒不可达的兜底分支

- **位置**：`f_svg/src/SvgGeometry.cj:205-207`（`if (chain.size == 0) return SvgMatrix.identity`）、`:539`、`:853`（`case _ => ()`）
- **来源**：存量
- **判据**：review-checklist §1「恒真恒假分支」
- **证据**：静态确定 —— `ctm` 的 `chain` 至少包含 `element` 本身（`:196-204` 先 `add` 再取 `parent`），`size == 0` 不可能；`pathDataBounds`/`collectMiterPolylines` 都先调用 `data.toAbsolute()`，而 `toAbsolute` 已把 `HorizontalLineTo`/`VerticalLineTo` 全部改写为 `LineTo`（`f_svg/src/SvgPathData.cj:181` 起的 H/V 分支），8 个 `SvgPathCommandKind` 值（`SvgPathData.cj:22-32`）中的 H/V 不再出现
- **描述**：三处分支永不会命中，掩盖了「若将来放宽 `toAbsolute` 契约」的真实缺口
- **建议**：删除或改为 `case _ => throw`（或加注释说明依赖 `toAbsolute` 的归一化契约）

### [轻微][存量] #11 `SvgGzip.cj` 末尾的 `TODO(M3-6)` 已过时

- **位置**：`f_svg/src/SvgGzip.cj:96`（`// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。`）
- **来源**：存量
- **判据**：review-checklist §3「TODO 占位仍在主路径」/ §13「文档过期」
- **证据**：静态确定 —— `SvgParser.parseAuto` 已在 `f_svg/src/SvgParser.cj:71` 实现、`parseGzip` 在 `:83` 实现，且 `SvgGzip_test.cj:28-35` 已覆盖两者
- **描述**：注释会让维护者以为入口缺失；同时该文件 doc 注释（`:21-27`）承诺「同输入输出逐字节一致」，实际依赖 zlib 默认 mtime=0，属隐含契约
- **建议**：删除该 TODO，并把「mtime=0」的依赖写进 `compress` 的注释

### [轻微][存量] #12 枚举 `toString()` 返回 CamelCase，与同文件 `attrName()` 的 SVG 关键字不一致

- **位置**：`f_svg/src/SvgGradient.cj:36-41`、`:74-80`（`toString` → `"UserSpaceOnUse"` / `"Pad"`）；对照 `:43-48`、`:82-88`（`attrName` → `"userSpaceOnUse"` / `"pad"`）
- **来源**：存量（`SvgGradient_test.cj:91-92` 已把 CamelCase 固化为断言）
- **判据**：review-checklist §10 可读性 / §13「命名与语义」
- **证据**：静态确定 —— 两个公开枚举同时提供 `toString`（调试名）与 `attrName`（序列化值），取值不同；调用方若用 `toString()` 拼属性会写出非法值
- **描述**：`SvgSpreadMethod.Pad.toString() == "Pad"` 不是合法 SVG 属性值；`SvgCoordinateUnits` 同理。对外 API 上「ToString 不是可回写值」无文档说明
- **建议**：保持 `attrName` 为唯一序列化入口，并在两个 `toString` 上加注释「调试用，写属性请用 attrName」；或在收敛破坏性变更窗口把 `toString` 改成关键字并以 `FromName` 可逆

<!-- 第 17 部分 -->

### [严重][存量] 命中查询系列 API 用元素局部 bbox 直接与根用户空间 rect 比较，忽略元素与祖先的 transform

- **位置**：`f_svg/src/SvgHitQueries.cj:79-94`（`svgHitQueryMatches`）；对照 `f_svg/src/SvgHitTest.cj:378-389`（`svgHitLocalPoint` 才做 CTM 求逆）
- **来源**：存量（`git blame` a061fe1ef5，2026-11-07）
- **判据**：review-checklist §11（契约与实现不符）/ §10 正确性
- **证据**：静态确定 —— `svgBBoxOf` 返回的是元素**自身用户空间**的盒子：`rectBounds` 只读 `x / y / width / height`（`f_svg/src/SvgGeometry.cj:281-299`），容器层才显式对每个子元素调用 `childBox.transform(svgChildTransform(child, …))` 应用**子元素**的变换（`f_svg/src/SvgElementApi.cj:150-170`），说明 bbox 本身不含自身与祖先变换。`svgHitQueryMatches` 把该盒子与 `rect`（规格上位于根用户空间）直接做 `intersect` / 包含比较，全程没有任何 `invert()`；同一模块的 `hitTest` 走 `SvgGeometry.ctm` + `ctm.invert()` 才正确。
- **描述**：任何带 `transform` 的元素（或位于带 `transform` 的 `<g>` / 嵌套 `<svg>` 内）在 `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` 中位置全部错位。典型失败：`<g transform="translate(100,100)"><rect x="0" y="0" width="10" height="10"/></g>` 在 `(100,100,10,10)` 查询不到，反而在 `(0,0,10,10)`（实际什么都没画）报命中。`checkIntersection` 与 `checkEnclosure` 同样错。
- **建议**：查询路径与命中测试共用坐标处理——对每个候选元素求 `SvgGeometry.ctm(element, styles, viewport…)` 的逆，把 `rect` 变换到元素局部空间后再比 bbox（容器则按子元素的 CTM 逐层下推）；同时补 transform / 嵌套 `svg` 的用例，当前 `SvgDomApiM6_test.cj:214-251` 全部是无变换文档，所以这条一直没被覆盖。

### [一般][存量] 命中查询遍历不剪枝：定义容器与 `display:none` 子树内的元素仍被判为命中

- **位置**：`f_svg/src/SvgHitQueries.cj:50-63`（`svgHitQueryCollect`）；对照 `f_svg/src/SvgHitTest.cj:352-362`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §2（重复逻辑导致行为漂移）+ §11
- **证据**：静态确定 —— `svgHitQueryCollect` 对每个子节点无条件递归，只有 `svgBBoxOf` 在**容器自身**上按 tag 排除 `defs / mask / pattern / clipPath / linearGradient / …`（`f_svg/src/SvgElementApi.cj:124-127`），对其**子元素**没有任何祖先约束；`display` 不可继承（`f_svg/src/SvgComputedStyle.cj:98`），`display:none` 容器的子元素计算值仍是 `inline`，`svgBBoxOf` 会正常返回盒子；`computeSubtree` 遍历整棵树（`f_svg/src/SvgStyleResolver.cj:143-151`），所以 `styles.get(element)` 一定命中，不会被 `None` 分支挡掉。
- **描述**：`<defs><rect id="a" …/></defs>` 里的 `a`、`<mask>` / `<pattern>` / `<clipPath>` / `<symbol>` 内的图形、以及 `<g display="none">` 子树内的元素，都会出现在 `getIntersectionList` / `getEnclosureList` 结果里；同一批元素在 `SvgHitTest.hitTest` 中会被正确剪枝（`nonePrunesSubtree` 用例即验证这一点）。两个公开 API 对同一文档给出互斥结论。
- **建议**：把“是否进入子树”的判定抽成共用函数（`display == "none"`、`pointer-events == none`、定义容器 tag 列表），`svgHitQueryCollect` 与 `svgHitWalk` 都调用它；或让查询以回调形式复用 `svgHitWalk` 的遍历。

### [一般][存量] 命中查询以硬编码 300×150 求值样式与 bbox 请求，与文档实际视口无关

- **位置**：`f_svg/src/SvgHitQueries.cj:28`、`f_svg/src/SvgHitQueries.cj:46`（`mediaWidth: 300.0, mediaHeight: 150.0`）、`f_svg/src/SvgHitQueries.cj:79-84`（`viewportWidth: 300.0, viewportHeight: 150.0`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（语义与实现不符/硬编码）
- **证据**：静态确定 —— `SvgHitTest` 同职责代码从根元素解析视口并按渲染选项覆盖（`f_svg/src/SvgHitTest.cj:306-315`，`SvgViewport.from` + `options.width/height`），查询路径则写死字面量。
- **描述**：`@media (min-width: …)` 的判定、嵌套 `<svg>` 的视口尺寸、`<use>` 的宽高基准、根 bbox 的 `(0,0,w,h)` 回退（`f_svg/src/SvgElementApi.cj:293`）全部按 300×150 计算。文档实际为 800×600 时，`getIntersectionList` 可能因媒体查询命中不同的 `display` / `pointer-events` / 填充规则而返回不同集合。
- **建议**：从 `SvgDocument` 侧推导视口（根 `width/height` 或 `viewBox`），或直接复用 `SvgViewportTransform.from(root, options:)`，并允许调用方传入视口；不要在库内部写文档尺寸常量。

### [一般][存量] 命中查询没有元素数上限，且对每个元素重算一次子树 bbox

- **位置**：`f_svg/src/SvgHitQueries.cj:33-35`、`f_svg/src/SvgHitQueries.cj:50-63`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §5 / §6.4（未受信输入无上限 + 复杂度）
- **证据**：静态确定（无计数器、无 `maxElements` 参数）——对照 `SvgHitTest` 有 `visited` 计数并在超限时抛 `SvgErrorKind.Limit`（`f_svg/src/SvgHitTest.cj:340-351`）。单次耗时占比属 `需实测`。
- **描述**：`svgHitQueryMatches` 对每个元素调用 `svgBBoxOf`，而容器 bbox 会递归自身整棵子树，一趟查询最坏是 `O(n×depth)`；`document.parseOptions.security.maxElements`（默认 1e6）只约束**解析**，查询侧完全不看，`display:none` / 定义容器又不剪枝，等于对不可信文档没有任何成本上界。`SvgDomApiM6_test.largeDocumentPerformance` 只用 1000 个扁平 `<rect>`，覆盖不到这条路径。
- **建议**：加 `maxElements!` 参数（默认取 `document.parseOptions.security.maxElements`），遍历计数超限抛 `SvgErrorKind.Limit`；容器 bbox 在同一趟遍历中自底向上累加，避免每个父节点重算子树。

### [一般][存量] 奇异 CTM 时命中测试退回未变换点，不可见元素被报命中

- **位置**：`f_svg/src/SvgHitTest.cj:385-388`（`svgHitLocalPoint` 的 `None` 分支）；同形态 `f_svg/src/SvgHitTest.cj:223-226`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（边界 / 退化输入）
- **证据**：静态确定 —— `SvgMatrix.invert()` 在 `|det| < SVG_INVERT_EPSILON` 时返回 `None`（`f_svg/src/SvgMatrix.cj:106-110`），此时 `svgHitLocalPoint` 直接把根空间点当局部点返回，`svgHitElementMatches` 继续用它做点内判定。
- **描述**：`<rect width="100" height="100" transform="scale(0)">` 实际零面积、不渲染，但 `hitTest(point:(50,50))` 会命中它（局部坐标恰好等于根坐标）。任何使行列式为 0 的 `transform`（`scale(0)`、`scale(0 1)`、`matrix(0 0 0 0 0 0)`）都成立。
- **建议**：`None` 分支直接判定「该元素及其子树无命中」（返回不入结果的信号），而不是回退原点；`elementsAt` 的根矩阵 `None` 分支同理应改为“无命中”。

### [一般][存量] `calcMode` 存在两套拼写映射且大小写行为不一致

- **位置**：`f_svg/src/SvgInterpolator.cj:39-46`（`toString` → `"Linear"`）、`f_svg/src/SvgInterpolator.cj:48-55`（`fromName`，`toAsciiLower` 大小写不敏感）；对照 `f_svg/src/SvgAnimate.cj:19-26`（`svgCalcModeAttrName` → `"linear"`）、`f_svg/src/SvgAnimate.cj:56-68`（`svgCalcModeFromName`，仅 `trimAscii`，大小写敏感）
- **来源**：存量（blame a061fe1ef5 / 同批枚举实现）
- **判据**：review-checklist §2（字面量复制的映射表 + 行为漂移）
- **证据**：静态确定 —— `animate.calcMode` 的 getter 走 `svgCalcModeFromName`，对 `calcMode="Linear"` 返回 `None`；而时间轴 `SvgTimeline.cj:538` 走 `SvgCalcMode.fromName`，同一个值被接受。`"${mode}"` 得到 `"Linear"`，写回属性即非法值（序列化用 `svgCalcModeAttrName`）。
- **描述**：同一个枚举有 2 张“枚举 ↔ 属性拼写”表、2 个解析入口，且对大小写的容忍度相反；除此之外 `SvgZoomAndPan` / `SvgImageRendering` 的 `toString` 都返回属性拼写，`SvgCalcMode.toString` 返回类型名，`SvgLengthUnit.toString` 又返回 `"Number"/"Percent"`（`f_svg/src/SvgLength.cj:50-63`）——三套约定并存。
- **建议**：保留 `svgCalcModeAttrName` / `svgCalcModeFromName` 作为唯一映射，`SvgCalcMode.toString` 改为委托它（或删除 ToString 实现），属性 getter 与时间轴统一用同一入口；`SvgLengthUnit` / `SvgCalcMode` 的 `toString` 语义在 README「已知 API 约定」中写清。

### [轻微][存量] 方形端点帽的角落区域不参与命中

- **位置**：`f_svg/src/SvgHitTest.cj:660-679`（两处 `svgDistanceToPoint(point, contour[…]) <= halfWidth` 附加条件），配合 `f_svg/src/SvgHitTest.cj:686-709`（`Square` 分支）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（与函数注释/几何定义不符）
- **证据**：静态确定 —— 该函数自述“`square` 用沿线延伸的半宽矩形”（`f_svg/src/SvgHitTest.cj:685`），`svgLineCapCoversPoint` 的 `Square` 分支也确实按 `along ∈ [0,hw] × across ∈ [0,hw]` 判定；但调用处额外要求 `distance ≤ halfWidth`，正方形四角距端点 `√2·hw`，被裁掉。
- **描述**：`stroke-linecap="square"` 的笔画末端四角处（占端点帽面积约 21%）判为未命中；`Round` 分支的同一条件恒真、`Butt` 分支返回 `false`，所以只有 `Square` 受影响。
- **建议**：把距离判定移进 `svgLineCapCoversPoint` 的 `Round` 分支，端点调用处只保留 `svgLineCapCoversPoint` 一个条件。

### [轻微][存量] 描边命中不含 join 区域

- **位置**：`f_svg/src/SvgHitTest.cj:638-683`（`svgPointNearContours`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（实现与“描边区域”语义不符）
- **证据**：静态确定 —— 函数只遍历线段（`1..contour.size`）并补端点帽，没有任何 join 处理；同一模块的 `SvgStrokeOutliner.outlineContours` 是显式生成 join 轮廓的，两处对“描边覆盖区”的定义不同。
- **描述**：`stroke-linejoin="miter"` 的尖角（可伸出半宽以外）处点选会判未命中；`round` join 与端点圆盘近似重合，影响小。
- **建议**：若要求与渲染像素一致，可复用 `SvgStrokeOutliner` 的轮廓做点内判定；否则在 `hitTest` 文档注释中声明“join 区域按线段近似”。

### [轻微][存量] `elementsAt` / `elementAt` 静默丢弃命中过程产生的 warning

- **位置**：`f_svg/src/SvgHitTest.cj:227-237`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §3（静默吞掉诊断）/ §11
- **证据**：静态确定 —— 该调用传入临时 `ArrayList<String>()` 作为 `warnings`，`svgHitText` 的 “text 轮廓缺失，该元素不参与命中”（`f_svg/src/SvgHitTest.cj:520-522`）写进这个临时表后随调用返回被丢弃；实例方法 `hitTest` 则把同一批 warning 追加到 `this.warnings`（`f_svg/src/SvgHitTest.cj:181-183`）。
- **描述**：规格 API 与实例 API 的诊断能力不一致：调用方用 `elementsAt` 时无法得知“文本元素因缺字形轮廓被跳过”，只能看到命中数为 0。
- **建议**：给两个静态方法加 `warnings!` 出参（或返回 `(hits, warnings)` 结构），至少在注释中声明不产生诊断。

### [轻微][存量] `SvgLinearGradient` 的类型化坐标属性未参与渲染管线，坐标另有读取路径

- **位置**：`f_svg/src/SvgLinearGradient.cj:39-73`；对照 `f_svg/src/SvgGradient.cj:298-312`（`coordinate(chain, "x1", …)` 直接读 `attr`，并处理 `href` 继承与单位轴）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §2（同语义双实现）/ §1（对外可达 `public` 记信息）
- **证据**：静态确定 —— 全仓搜索 `gradient.x1 / x2 / y1 / y2` 无业务使用，仅构造器赋值；`SvgLinearGradient` 是 public 类、属性对外可达，按硬原则一**不判死代码**。
- **描述**：属性只做“字符串 ↔ `SvgLength`”转换，不解析 `href` 继承；渲染实际用 `SvgGradient.coordinate`。两套读法一旦对默认值/单位处理产生分歧（例如 `x1="50%"`），属性侧读到的是原始 `SvgLength`、渲染侧读的是按轴换算后的值，使用者按属性做校验会得到与渲染不同的结论。
- **建议**：让 `SvgGradient.coordinate` 在无 `href` 继承时复用同名属性，或反之把属性标注为“仅作者侧读写、不参与继承解析”，避免两套语义并存。

### [轻微][存量] `SvgHitTest.warnings` 跨调用只增、无 reset 契约

- **位置**：`f_svg/src/SvgHitTest.cj:143`、`f_svg/src/SvgHitTest.cj:181-183`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §7（生命周期）/ §12.1（`ArrayList` 无同步）
- **证据**：静态确定 —— 每次 `hitTest` 追加、从不清空，也没有 `reset` 方法；`ArrayList` 本身不保证并发写安全。
- **描述**：长生命周期实例（如服务内复用一个 `SvgHitTest`）在反复失败路径上线性增长，且不同次调用的 warning 混在一起难以归因；多线程共用一个实例时是数据竞争。与 `SvgRenderer.warnings` 属同一约定，因此只记为轻微。
- **建议**：提供 `resetWarnings()`，或在类注释中写明“单次使用、调用方负责 `warnings.clear()`”；如需跨线程复用，标注为“非线程安全”。

### [轻微][存量] 未使用的 import

- **位置**：`f_svg/src/SvgInterpolator.cj:20`、`f_svg/src/SvgLength.cj:19`（`import fountain::f_base.*`）；`f_svg/src/SvgInitialViewM6_test.cj:18`、`f_svg/src/SvgLineJoinM6_test.cj:18`、`f_svg/src/SvgLimitsM3_test.cj:18`、`f_svg/src/SvgImageResource_test.cj:18`（`import std.collection.*`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：待确认 —— 编译器不报未使用 import（README 称 0 warning），按符号枚举判定：`SvgInterpolator.cj` / `SvgLength.cj` 内无任何 `f_base` 顶层符号或扩展方法名（`toInt` / `numberOfLeadingZeros` / `stringJoin` / `trimAsciiBlanks` / `replaceFirst` / `isEven` 等）出现；4 个测试文件内无 `ArrayList` / `HashMap` / `HashSet` 使用。
- **描述**：多余的依赖声明会误导“该文件依赖 f_base”，也掩盖真实的模块边界。
- **建议**：删除上述 6 处 import；若不删，请在 `f_svg/README.md` 说明为何统一引入 `f_base`。

### [轻微][存量] `SvgLength` 构造不校验有限性，`toString()` 会抛异常；与 `parse` 的契约不对称

- **位置**：`f_svg/src/SvgLength.cj:93-96`（`init`）、`f_svg/src/SvgLength.cj:127-129`（`toString`）；抛点 `f_svg/src/SvgNumber.cj:32-35`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（契约与注释不符）
- **证据**：静态确定 —— 类注释只承诺“`toString` 输出规范形式”“`parse` 失败抛 `InvalidValue`”；`SvgLength(Float64.NaN)` 可正常构造，`toString()` 经 `formatSvgNumber` 抛 `SvgException(InvalidValue)`，所以 `writeLength`（`f_svg/src/SvgShape.cj:332-334`）会在属性写入时抛错。类型契约（`ToString`）被打破。
- **建议**：`init` 中校验 `isFinite` 并抛 `InvalidValue`（把校验前移到构造），或把“非有限值 `toString` 抛异常”写进类注释。

### [轻微][存量] `SvgInteractionState.hoveredIds` 构造后修改不会同步内部集合

- **位置**：`f_svg/src/SvgHitTest.cj:27-45`、`f_svg/src/SvgHitTest.cj:51-60`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（可变状态契约）
- **证据**：静态确定 —— `hoveredIds` 是 `public let Array<String>`（元素可变），`hoveredSet` 只在 `init` 中一次性构建；`isHovered` 只查 `hoveredSet`。
- **描述**：`state.hoveredIds[0] = "other"` 后 `isHovered("other")` 仍为 `false`，`:hover` 求值（`f_svg/src/CssSelector2.cj:793-798`）与用户可见状态不一致；README 只提醒 `attributes / children / warnings` 不要直接改，未提这里。
- **建议**：`init` 中复制数组为内部私有副本，或在注释与 README「已知 API 约定」中声明这些数组为只读语义。

<!-- 第 18 部分 -->

### [严重][存量] GPOS Coverage / ClassDef format 2 按范围展开，无条数上限也未去重，可被小体积字体放大成 OOM

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:481`（`parseGposCoverage` format 2 的 `while (glyph <= end)`）、`f_svg/src/SvgOpenTypeLayout.cj:506`（`parseGposClassDef` format 2 同一写法）
- **来源**：存量（工作区快照，`git diff` 为空，无基线可比）
- **判据**：review-checklist §5「无界容器 / 按不可信长度预分配」；同文件 `kern`、`PairPos format 1/2` 都有上限，唯独这两处范围展开没有
- **证据**：静态确定 —— `count = reader.u16(offset + 2)`（≤65535 条 RangeRecord），每条 RangeRecord 的 `start..end` 是 u16 闭区间（≤65536 个字形），内层无条件 `result.add(glyph)`，既不去重也不累计计数；`parseGposClassDef` 同构
- **描述**：一个约 384 KB 的 `GPOS` 表（65535 条 RangeRecord × 6 B）即可让 `parseGposCoverage` 向 `ArrayList<Int64>` 追加 65535 × 65536 ≈ 4.29e9 个元素，按 8 B/元素 ≈ 34 GB，必然 OOM；同一份表在 `parseGposClassDef` 里变为 4.29e9 次 HashMap 写入，变成分钟级 CPU 占用。`parseGposCoverage` 还被 GSUB 连字解析复用（`SvgOpenTypeLayout.cj:630`），影响面不止 GPOS。字体字节由调用方 `SvgTrueTypeFont.parse` 传入（`f_svg/src/f_svg.cj:56` 明确「字体只由调用方显式 parse / load」），字体文件是典型不可信输入；`doc/f_svg-M3设计.md:370-381` 的资源上限表也没有为字体表列任何条数上限
- **建议**：三处同时收口——(1) 为 coverage / classDef 设总条数上限（字形总数本就 ≤65536，可用 `maxGlyphId` 或 `CSS_GPOS_MAX_PAIRS` 复用）；(2) 覆盖表改用 `Array<Bool>`/`HashMap` 去重后再落数组；(3) 超出时按现有风格 `warnings.add(...)` 并 `return false`（丢弃该子表），不要静默扩容

### [一般][存量] GPOS PairPos format 1 的 pair 表只有「单 pair set」上限，缺全局累计上限（与 kern 不对称）

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:388`（`if (pairCount > CSS_GPOS_MAX_PAIRS)` 位于内层循环内）；对照 `f_svg/src/SvgOpenTypeLayout.cj:231-236`（`kern` 用 `totalPairs` 累计，超限整表忽略）
- **来源**：存量
- **判据**：review-checklist §5（无界容器）/ §2（同一约束在两处实现不一致）
- **证据**：静态确定 —— `target.pairs` 是跨子表、跨 lookup 共享的 `HashMap`，只在每个 pair set 内比较 `pairCount`，没有 `totalPairs`；`parseGposPairSubtable` 的 `parsed` 只表示「有内容」，不参与限流
- **描述**：`pairSetCount`（≤65535）× 每 set 最多 65536 对 ⇒ 上限仍是 4.29e9 条，只是被文件体积线性约束（每对 6 B）。10 MB 的 GPOS 表约能塞 1.7M 对，落成 HashMap 约 40 B/条 ⇒ 约 70 MB 常驻，且解析期还有 `coverage` 数组副本；同一份字体在 `kern` 路径会整表拒绝，在 GPOS 路径却全部收下
- **建议**：把 `kern` 的 `totalPairs` 计数方式提到 GPOS（函数内累计，超 `CSS_GPOS_MAX_PAIRS` 时告警并停止该 lookup）

### [一般][存量] GPOS 不支持 Extension lookup（Type 9），且静默跳过不留 warning

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:335-338`（`if (lookupType != 2) { continue }`）；对照 `f_svg/src/SvgOpenTypeLayout.cj:165-184`（GSUB 对 Type 7 有递归解包 + 告警）
- **来源**：存量
- **判据**：review-checklist §14.1（只做了一半的分支 / 两表处理不对称）与 §3（静默跳过）
- **证据**：静态确定 —— 代码中不存在 `lookupType == 9` 分支；`continue` 前没有任何 warning；GSUB 侧存在等价解包（`reader.u16(subOffset) != 1` 还会告警）
- **描述**：现代字体在 PairPos 偏移超过 64 KB 时会把真实子表包进 Extension（Type 9），这是 libharfbuzz/FreeType 的常规布局。此处直接 `continue`，结果是「字距悄悄消失」，既不生效也不告警，与本模块「能解析就解析、不能解析就 warning」的既有策略相反；测试 `SvgOpenTypeLayoutM5_test.cj` 也只覆盖了 Type 2，无法暴露
- **建议**：与 `cssCollectGsubLookup` 对齐，加 Type 9 分支（format 1 → `ExtensionOffset` 指向真实 lookup，深度 +1 并受上限约束），无法解包时 `warnings.add("GPOS 扩展 lookup 不受支持")`

### [一般][存量] `cssLayoutTag` 用 `String.fromUtf8` 解析 4 字节 tag，非法 UTF-8 抛 `IllegalArgumentException`，会穿透只捕 `SvgException` 的解析函数

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:34-43`；捕获点 `f_svg/src/SvgOpenTypeLayout.cj:258`、`:351`、`:607`（均只 `catch (_: SvgException)`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失」/ §10 异常类型；语言文档：`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:6384-6386`（`String.fromUtf8` 入参不符合 utf-8 序列规则时抛 `IllegalArgumentException`）
- **证据**：静态确定 —— tag 取自 `reader.u8()` 的 4 个任意字节，`String.fromUtf8` 会校验码点；`SvgException <: BaseException`，`IllegalArgumentException` 不是它的子类，三个 `catch` 都接不住
- **描述**：字体 tag 按规范是 ASCII，但畸形 / 被篡改字体给出 `0xFF 0x00 ...` 时，异常从 `SvgGposPairs.parse` / `SvgGsubLigatures.parse` 直接冒到 `SvgTrueTypeFont` 构造，调用方拿到的是非 `SvgException`，与模块「解析失败统一 `SvgException` + warning」的契约不符（严格模式下更会绕过按 kind 的分类处理）
- **建议**：tag 比较改为直接比 4 个字节（或 `String.fromUtf8Unchecked` + 只做相等比较），或把三处 `catch` 放宽到 `Exception` 并保留 `SvgException` 分支以维持 kind

### [一般][存量] `SvgMatrix.invert` 用绝对行列式阈值，小尺度但可逆的矩阵被判不可逆，调用方静默回退

- **位置**：`f_svg/src/SvgMatrix.cj:106-119`（阈值 `SVG_INVERT_EPSILON = 1e-12`，`f_svg/src/SvgMatrix.cj:21`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 契约与注释不符）：注释写「不可逆（行列式接近 0）时返回 None」，实现是 `abs(det) < 1e-12` 的**绝对**阈值
- **证据**：静态确定 —— `SvgMatrix.scale(1e-7, 1e-7)` 的 `det = 1e-14 < 1e-12`，但逆矩阵存在且元素有限（1e7），`invert()` 返回 `None`。等价地，`viewBox="0 0 1000000000 1000"` 这类合法文档的矩阵（scale≈1e-9）会被判奇异
- **描述**：失败路径在调用侧全部静默：`SvgRasterizer.cj:205`、`:263` 用 `?? SvgMatrix.identity`（把设备坐标当用户坐标，图案/纹理错位），`SvgRenderer.cj:601-604` 同样回退 identity，`SvgPatternSampler.cj:163` 直接跳过该图案。用户看到的是「大面积空白 / 填充跑到别处」，而不是错误。上述调用点在本次审查范围外，仅作影响面证据
- **建议**：改相对判据（如 `abs(det) <= eps * max(|a|,|b|,|c|,|d|)^2`，或按 2×2 的最大元素归一化后再比较），并把「不可逆」从 `?SvgMatrix` 换成可上报的错误，至少让上层能记一条 warning 而不是 identity 兜底

### [一般][存量] 设计承诺「渲染全程只读 `SvgDocument`」，但类型化 getter 在读取时写入缓存，同一文档并发渲染构成数据竞争

- **位置**：`f_svg/src/SvgElement.cj:33-40`（`SvgValueCache.get` 写 `cached` / `version` / `hasCached`，无任何同步）；使用方示例 `f_svg/src/SvgMarker.cj:117-222`（8 个属性全部走该缓存）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）+ §13 类（与设计文档冲突：`doc/f_svg-M3设计.md:73`「渲染全程只读 `SvgDocument`」）
- **证据**：静态确定 —— 缓存字段是普通 `var`，无锁 / 无原子 / 无线程封闭标注；共享路径明确：一个 `SvgDocument` 被两个线程同时 `SvgRenderer.render`，两条线程对同一 `SvgMarker` 调 `markerUnits` 等 getter 即并发写同一 `SvgValueCache`
- **描述**：设计文档把「只读」当作可并发的前提，实现却在读路径上做惰性写。后果是 `version` 与 `cached` 可能不一致（读到上一代缓存值或半写状态），并且首次读取时重复计算。单线程下无影响，所以测试与常规用法都发现不了
- **建议**：二选一并写进文档——(1) 解析完成后冻结文档（`seal()` 后禁止写，getter 走不可变索引），(2) 缓存改为解析期一次性预计算，或按线程持有 side table。若坚持懒缓存，README/类注释必须显式声明「同一文档不可跨线程渲染」

### [一般][存量] 变更 hub 的监听器列表既无并发保护也无遍历快照，重入会无限递归

- **位置**：`f_svg/src/SvgMutation.cj:76`（`private let listeners = ArrayList<...>`）、`:86-93`（`remove` 直接 `remove(at:)`）、`:95-106`（`notify` 直接 `for (listener in this.listeners)`）
- **来源**：存量
- **判据**：review-checklist §12.1（迭代与修改并发、锁对象误用）与 §4（无界递归：同步回调无重入保护）
- **证据**：静态确定 —— 全类无同步原语；`notify` 没有 `notifying` 标志、没有 `listeners.clone()` 快照；监听器里调 `element.setAttr(...)` → `svgNotifyMutation`（`:110-124`）→ 同一 hub `notify` → 同一个监听器，递归无出口
- **描述**：两个具体触发面：(1) 监听器在回调内判断并修正属性（很常见的「归一化」写法）→ 每次修正又触发一次通知，直到栈溢出；(2) 监听器在回调内 `removeMutationListener(this)` 或再 `add` → 遍历中结构修改，`ArrayList` 迭代器语义未定义（文档未声明安全），最坏抛 `ConcurrentModificationException` 并中断后续监听器。共享路径：`SvgDocument.mutationHub` 是单实例，`addMutationListener` / `removeMutationListener` 是 public（`SvgDocument.cj:41-48`）
- **建议**：`notify` 改为「拷贝一份监听器数组 + `notifying` 标志」，重入时把事件入队或直接 `warnings.add("监听器重入被忽略")`；`add/remove` 走同一把锁或写时复制，并在 `SvgMutationListener` 注释里写明「回调内不得修改本文档」

### [一般][存量] `attributes` / `children` 是 public 可变集合，绕过 `setAttr` 直接修改不会递增 `attributesVersion`，`SvgMarker` 的属性缓存永久陈旧

- **位置**：根因 `f_svg/src/SvgElement.cj:51`（`public let attributes = ArrayList<SvgAttribute>()`）、`:56`（`internal var attributesVersion`）；受影响使用方 `f_svg/src/SvgMarker.cj:117-222`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：「`attributes` 是唯一事实源，缓存只在 `attributesVersion` 未变时复用」，但版本只由 `setAttr/removeAttr` 递增）
- **证据**：静态确定 —— `SvgValueCache.get`（`SvgElement.cj:33-40`）只用 `attributesVersion` 做键；`attributes` 的增删改不经过任何版本递增路径
- **描述**：`markerUnits` / `orient` / `refX` / `refY` / `markerWidth` / `markerHeight` / `viewBox` / `preserveAspectRatio` 八个 getter 全部命中此问题：调用方 `element.attributes[0] = SvgAttribute(...)`（public 列表，编译期合法）后，之后每次读都把首次解析结果返回，读写不一致且无告警。`children` 同理会绕过变更事件（监听器收不到通知）
- **建议**：把 `attributes` / `children` 收窄为只读视图（对外暴露 `attr()` 与迭代器，写入只走 `setAttr/removeAttr/appendChild`），或让缓存键改为「属性列表的内容哈希」（代价是每次 getter O(属性数)）；至少在校验期把直接修改列表标为不受支持

### [轻微][存量] `SvgNode` 的 PI 序列化不转义 target / data，与文本、属性、CDATA 的转义策略不对称

- **位置**：`f_svg/src/SvgNode.cj:32`（`case PiNode(target, data) => "<?${target} ${data}?>"`）；同一写法见 `f_svg/src/SvgElement.cj:437`（范围外，同一根因）
- **来源**：存量
- **判据**：review-checklist §10（安全性：序列化注入）/ §13 类（转义一致性）
- **证据**：静态确定 —— 同文件 `serializeSvgCData`（`SvgElement.cj:665`）处理 `]]>`、`serializeSvgComment`（`:688`）处理 `--`、`escapeSvgText`（`:705`）与 `escapeSvgAttribute`（`:718`）都做了转义，唯独 PI 直拼
- **描述**：`SvgNode.PiNode` 是 public 构造入口，程序化构造 `PiNode("xml", "?> <script>alert(1)</script>")` 后 `document.toString()` 会输出可执行的标签；解析得到的 PI 不可能含 `?>`（XML 解析器已截断），所以这是「构造 → 序列化」链上的注入面，而非解析面
- **建议**：序列化前校验 target 符合 XML `Name` 产生式，并把 data 中的 `?>` 替换为 `? >`（与 CDATA 的处理思路一致）；无法安全表达时抛 `SvgException(InvalidValue)`

### [轻微][存量] `SvgKernPairs.horizontalOnly` 只写不读，是死字段

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:194`（字段）、`:196-198`（构造参数）、`:213`（唯一写入点 `SvgKernPairs(true)`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 类型的成员，全仓无读取）
- **证据**：静态确定 —— 全仓 `grep horizontalOnly` 仅命中定义、构造参数与赋值；`adjust()`（`:200-202`）与 `parse()` 都不读它，且构造点恒传 `true`（`parse` 本身就只收 `format == 0 && horizontal` 的子表，`SvgOpenTypeLayout.cj:230`）
- **建议**：删除字段与构造参数，`private init()` 无参；若为将来「垂直字距」保留，需要注释说明并接上读取点

### [轻微][存量] LangSys 的 `requiredFeatureIndex` 从未读取，只在 requiredFeature 里声明 kern/liga 的字体被整体忽略

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:45-57`（`cssLayoutCollectLangSys` 只读 `offset+4` 的 count 与 `offset+6` 起的索引）
- **来源**：存量
- **判据**：review-checklist §14.1（只处理部分输入）/ §13 类（与 OpenType LangSys 表定义不符）
- **证据**：静态确定 —— LangSys 头为 lookupOrderOffset(2) / requiredFeatureIndex(2) / featureIndexCount(2)，代码从 `+4` 开始读，`+2` 从未访问
- **描述**：`requiredFeatureIndex != 0xFFFF` 时该特性是强制的，字体作者可以只把它记在 required 字段。此时 `cssLayoutLookupRefs` 找不到 `kern` / `liga`，`warnings.add("... 缺少 X 特性，已忽略")` 后整表放弃
- **建议**：`cssLayoutCollectLangSys` 先读 `offset+2`，`!= 0xFFFF` 时把该索引加入 `featureIndices`（去重逻辑复用）

### [轻微][存量] `SvgSecurityOptions` 只校验 `maxDecompressedBytes`，`maxElements` / `maxDepth` 允许 0 与负数

- **位置**：`f_svg/src/SvgOptions.cj:69-71`（仅 `maxDecompressedBytes <= 0` 抛错）、`:65-66`（默认 1_000_000 / 512）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验、校验不对称）
- **证据**：静态确定 —— 构造体只对三个字段中的一个做校验；`maxElements = 0` 会让构建器把第一个元素判为超限，`maxDepth = -1` 会让「深度 > maxDepth」在任何深度成立，效果是「静默拒绝一切文档」，与「配置写错」难以区分
- **建议**：三个上限统一 `> 0` 校验并给出参数名；`maxDepth` 再加一个合理下界（如 ≥ 1）

### [轻微][存量] `fromNameOrWarn` 的「解析失败 → warning → 默认值」在同一模块内复制 16 份，其中两处已无生产调用

- **位置**：`f_svg/src/SvgMarker.cj:84-99`、`f_svg/src/SvgOverflow.cj:64-79`（本部分两处）；同构实现另见 `SvgFilterPrimitive.cj:60`、`:122`、`SvgFilterPrimitives2.cj:66`、`:112`、`:167`、`:230`、`:276`、`SvgTextPath.cj:48`、`:94`、`:140`、`SvgTextBaseline.cj:76`、`SvgWritingMode`、`SvgVectorEffect.cj:100`、`SvgTextWritingMode.cj:64`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）/ §1（仅测试使用）
- **证据**：静态确定 —— 16 处函数体逐行同构（match raw → fromName → 失败 `warnings.add("${context} 的值「${text}」不合法，已回退为 …")` + 默认值）；`grep fromNameOrWarn` 显示 `SvgMarkerOrient` / `SvgOverflow` 两个版本的调用者只有 `SvgValueTypesM3_test.cj:126` 与 `SvgValueTypesM4_test.cj:148`，生产路径走的是 `SvgBuilder.cj:555-556` 的解析期校验 + `SvgStyleResolver` / getter 里的 `fromName`
- **建议**：抽 `parseEnumOrWarn<T>(raw: ?String, parse: (String) -> ?T, fallback: T, warnings, context)` 一处实现；两个已无生产调用的版本要么接到 getter 上（让 `setAttr` 路径也产出 warning），要么删除，避免「有告警能力但没人用」的假象

### [轻微][存量] `containsCssFeatureIndex` 线性查重嵌在 Script × LangSys 双层循环里，最坏 O(特性数 × 语言数)

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:53`（调用点）、`:59-66`（线性扫描 `ArrayList<Int64>`）
- **来源**：存量
- **判据**：review-checklist §6.4（热点里反复 `contains`）
- **证据**：静态确定 —— `scriptCount` ≤ 65535，每个 Script 的 `languageCount` ≤ 65535，`featureIndices` 只增不减，每次插入前线性扫描；即 65535 × 65535 次比较的上界来自报文头字段，不来自实际表体积（LangSys 记录 6 B）
- **描述**：正常字体 `featureIndices` 只有几十条，问题不显现；构造字体可让 `featureIndices` 增长到数万后再逐条扫描，形成纯 CPU 放大。与上面 GPOS 范围展开属不同根因（数据量放大 vs 查重算法），故分开列
- **建议**：`featureIndices` 换成 `HashSet<Int64>`（或 `Array<Bool>` 按 65536 上限位图），插入/查询 O(1)；同时给 featureIndices 一个总量上限

<!-- 第 19 部分 -->

### [严重][存量] pattern tile 缓存无会话级上限，峰值内存随「元素数 × 单 tile 上限」增长

- **位置**：`f_svg/src/SvgPatternSampler.cj:93`（`private let cache = HashMap<String, SvgPatternTile>()`）、`f_svg/src/SvgPatternSampler.cj:178`（key = `pattern.identity + objectBounds`）、`f_svg/src/SvgPatternSampler.cj:330`（`this.cache[key] = tile`）
- **来源**：存量（快照模式无基线；`git log -1 -- SvgPatternSampler.cj` = `985801390`，早于本轮快照）
- **判据**：review-checklist §5（无界容器 / 无拒绝路径）
- **证据**：静态确定 —— 缓存只有 `cache.clear()`（`SvgPatternSampler.cj:161`，仅在非会话模式、每次公开 `sample` 入口）与「渲染结束对象被回收」两个出口，**没有任何条目数或总像素上限**；单 tile 上限只限制**一枚** tile（`SvgPatternSampler.cj:229-244`，≤ `SVG_MAX_PATTERN_TILE_PIXELS` = 4 Mi 像素 = 16 MiB RGBA）。而 key 含 `objectBounds`，同一 pattern 被 N 个包围盒不同的图元引用就产生 N 条互不复用的条目。
- **描述**：`SvgRenderer.renderDisplayList` 在整次渲染中复用一个 `SvgPatternSampler`（`f_svg/src/SvgRenderer.cj:138-139`），`sampleTile` 用 `command.bounds`（`SvgRenderer.cj:591-592`）作 key 的一部分。攻击者可控输入：一个 `<pattern width="2000" height="2000">`（4 Mi 像素，正好在上限内）+ 1000 个位置/尺寸各不相同的 `rect` 共用该 pattern ⇒ 1000 枚 16 MiB tile 同时常驻 ≈ 16 GiB，且这些 tile 在对应图元绘制完后已无用途。`SvgRenderOptions.validatePixels` 只约束输出画布，`SvgDecodeBudget` 只约束图片解码，pattern tile 没有任何预算。
- **建议**：给 sampler 增加会话级 tile 预算（复用 `SvgDecodeBudget` 或新增 `SVG_MAX_PATTERN_TILES_TOTAL_PIXELS`），超限时按 LRU 淘汰或直接降级为 `None` + warning；若能证明多数 pattern 的内容映射与 `objectBounds` 无关（`patternContentUnits=userSpaceOnUse` 且无 `viewBox` 时成立），可把 key 收窄为 `pattern.identity`，从根上消除按包围盒生成条目的放大。

### [一般][存量] pattern 子内容出现任何 warning 即整体丢弃，与其他渲染路径的 warning 语义不一致

- **位置**：`f_svg/src/SvgPatternSampler.cj:293-298`、`f_svg/src/SvgPatternSampler.cj:305-310`
- **来源**：存量
- **判据**：review-checklist §11（错误处理不对称 / 语义与注释不符）+ §14.1（只做了一半的分支）
- **证据**：静态确定 —— `buildContent` / `renderDisplayList` 返回后判断 `if (warnings.size > 0) { ...; return None }`，即把「有警告」等同于「渲染失败」；同文件 `SvgRenderTree.cj` 产生的警告包括良性项：`"已跳过不支持的元素「${element.tag}」"`（`SvgRenderTree.cj:647`）、`"<image> 缺少 href，使用占位矩形"`（`SvgRenderTree.cj:1396`）、`"use 引用目标「${targetId}」不存在"`（`SvgRenderTree.cj:1002`）。
- **描述**：pattern 内容里出现一个 `<animate>`、一个缺 `href` 的 `<image>`、或任一 `use` 悬空引用，整块 pattern 填充就变成不绘制（返回 `None`），而同文档主渲染路径对同类警告是「跳过该元素、继续画别的」。结果：图案区域整片消失，且与主画布的降级策略相反，使用者很难从 warning 文本判断「为什么图案没了」。
- **建议**：区分致命与良性 warning（例如 builder/renderer 返回 `errors` 与 `warnings` 两个列表，或只在 `SvgErrorKind` 级失败时返回 `None`）；至少把「已跳过不支持的元素」「占位矩形」这类计入 warning 但不中止 tile。

### [一般][存量] `resolveAxis` / `resolveOrigin` 自实现长度换算，漏掉绝对单位与 `em`/`ex`

- **位置**：`f_svg/src/SvgPatternSampler.cj:390-410`（`resolveAxis`）、`f_svg/src/SvgPatternSampler.cj:412-433`（`resolveOrigin`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §2（重复逻辑导致行为漂移）
- **证据**：静态确定 —— 两个函数只区分 `Percent` 与「其他」，`em`/`ex`/`in`/`cm`/`mm`/`pt`/`pc` 一律按裸数值使用；而模块已有 `public func toUserUnits(length, axis, context)`（`f_svg/src/SvgLength.cj:205-227`）覆盖 `In/Cm/Mm/Pt/Pc/Em/Ex/Percent` 全部单位，且 `toUserUnits` 在本模块被 19 处调用。
- **描述**：`patternUnits="userSpaceOnUse"` 且 `width="1in"` 时，tile 宽度被算成 1 用户单位（按 96dpi 应为 96），`width="2em"` 时为 2 而非 `2 × fontSize`。该偏差同时是「同一换算在两处实现」的直接后果：一处修了单位，另一处不会跟着修。
- **建议**：`resolveAxis` / `resolveOrigin` 改调 `toUserUnits`，`Percent` 的基准按 `objectBoundingBox`/视口分别构造 `SvgLengthContext`；`objectBoundingBox` 语义（数值即 bbox 比例）用单独的 `SvgLengthAxis`/基准表达，避免再次分叉。

### [一般][存量] `SvgPattern` 的 9 个 typed prop 在 `src/` 内零调用，取样器另走一套 attr 字符串解析

- **位置**：`f_svg/src/SvgPattern.cj:38-72`（`x`/`y`/`width`/`height`）、`74-106`（`patternUnits`/`patternContentUnits`）、`108-126`（`patternTransform`）、`138-156`（`viewBox`）、`158-173`（`preserveAspectRatio`）；对应平行实现见 `f_svg/src/SvgPatternSampler.cj:214-221`、`268-271`、`314-317`、`449-488`
- **来源**：存量
- **判据**：review-checklist §2（跨层复制 / 换算复制）
- **证据**：静态确定 —— 全仓 grep：`patternUnits` / `patternContentUnits` / `patternTransform` / `viewBox` / `preserveAspectRatio` 在 `src/` 内除 `SvgPattern.cj` 定义处外**没有任何读取点**（`SvgPatternSampler.cj` 读的是 `effectiveAttr(chain, "patternUnits")`、`attr("patternTransform")` 等原始字符串），仅 `*_test.cj` 使用这些 prop。
- **描述**：同一份属性存在两条解析路径：`SvgPattern` 的 prop（`SvgValueCache` + `SvgCoordinateUnits.fromName` / `tryParseSvgTransform` / `tryParseSvgViewBox`）与 sampler 的链式 attr 解析 + 自建换算。上面第 3 条已发生实质漂移（`em`/绝对单位）。另外 prop 侧有 `attributesVersion` 缓存，sampler 侧每次 `sampleTileUncached` 重新 `tryParse` 一遍（`resolveLength` / `effectiveTransform` / `effectiveViewBox` / `effectiveAspect`），缓存价值被绕过。
- **建议**：把「href 继承链 + 首个可解析值」抽成一个泛型链式查找（见优化方案 O3），链首元素直接复用 `SvgPattern` 的 typed prop；只在需要继承时才回落到 attr 解析，并让两处共用同一换算函数。

### [一般][存量] `findPatternById` 递归遍历 DOM，深度上界 4096，与 `f_xml` 的「不递归」约定相反

- **位置**：`f_svg/src/SvgPatternSampler.cj:499-521`
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 每个 `ElementNode` 递归一次，无深度计数、无显式栈；可达深度上界由 `XmlParserOptions.maxElementDepth` 决定，默认 **4096**（`f_xml/src/XmlOptions.cj:136,146`），`SvgParseOptions` 未覆盖该值。对照 `f_xml` 自己的约定：「深度由解析引擎的 `maxElementDepth` 把关，这里不再递归，不会栈溢出」（`f_xml/src/DomBuilder.cj:27`）——即 4096 层被认为是**不能安全递归**的深度。调用点 `f_svg/src/SvgRenderer.cj:588` 在每次 pattern 填充时都走一遍全树搜索。
- **描述**：一个 4096 层嵌套的合法 SVG（在 `maxElements` 上限内，元素数只需 ~8k）即可让 `findPatternById` 压入 4096 层栈帧；每层还有 `match`/局部变量与两次 `for` 迭代，是否越界取决于平台栈大小与单帧大小（未实测）。同文件另一处 `SvgRenderTreeBuilder` 的引用展开已有 `SVG_MAX_REFERENCE_DEPTH` 与 `SvgRenderGuard` 保护，说明「递归深度必须显式设限」是本模块既有基线，此处是遗漏。
- **建议**：改为显式栈迭代（`ArrayList<SvgElement>` 待访问队列 + `HashSet<Int64>` 去重），或先构建一次 `id → element` 索引供 `findPatternById` / `findSvgElementById` / `resolveChain` 共用（同时消除每次填充 O(元素数) 的全树扫描）。

### [一般][存量] `SvgPath.d` 的 setter 经 `toString()` 回写，6 位小数与 `|v|<1e-6` 归零导致丢精度

- **位置**：`f_svg/src/SvgPath.cj:43-61`（`set` 分支 `SvgPath.cj:57`）；序列化侧 `f_svg/src/SvgPathData.cj:296-305` → `formatSvgNumber`（`f_svg/src/SvgNumber.cj:32-49`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符 / 数据丢失）
- **证据**：静态确定 —— `set` 只做 `this.setAttr("d", data.toString())`，`get` 再 `SvgPathData.tryParse`；`formatSvgNumber` 把非整数裁到 6 位小数、`|v| < 1e-6` 直接输出 `"0"`。本模块测试已把该行为固定为已知边界：`SvgPathData_test.cj:196-204`（`M0.1234567` → `M 0.123457`，且 `parse(toString(x)) != x`）。`SvgLength` 的文档明确声明了这条「已声明的不保真边界」（`f_svg/src/SvgLength.cj:86-87`），而 `SvgPath.d` 的文档（`SvgPath.cj:43` 前后）没有声明。
- **描述**：`SvgPath(d: data)` 与 `path.d = data` 都会把内存中的数据降精度后重新解析，`path.d` 读回的不是传入对象；`d` 中坐标量级 < 1e-6 的部分会被吸成 0（例如把 1e-3 比例的局部坐标图形平移后写回）。解析外部 SVG 不受影响（原本就是文本），受影响的是**程序化构造/编辑**路径，属于静默数据损失而非崩溃。
- **建议**：二选一 —— ①在 `d` prop 文档与 `SvgPath.init(d:)` 注释里显式声明「写回按 6 位小数规范化」；②`SvgPath` 直接缓存传入的 `SvgPathData` 对象（`attributesVersion` 不变时优先用对象，文本仅作序列化视图），把丢精度限制在 `toString()` 这一条明示边界上。同类 setter（`patternTransform`、`viewBox`、`preserveAspectRatio`）应按同一结论统一处理。

### [轻微][存量] `toAbsolute` 对绝对命令直接复用入参 `Array`，产生跨对象别名

- **位置**：`f_svg/src/SvgPathData.cj:235-241`、`244-250`、`253-259`、`262-268`（`else { command.values }` 分支）
- **来源**：存量
- **判据**：review-checklist §11（值/引用语义误用）
- **证据**：静态确定 —— `SvgPathCommand.values` 是 `Array<Float64>`（引用类型），绝对命令分支把同一个数组引用塞进新 `SvgPathCommand`，因此 `data` 与其 `toAbsolute()` 结果共享缓冲区；`SvgPathCommand` 是 struct，复制时数组仍共享。
- **描述**：调用方若原地改 `absolute.commands[i].values[0]`，原始 `data` 的对应命令同时被改（反之亦然）。当前仓内没有原地写入，故未触发；但 `commands` 是 `public let`，属对外可写面。
- **建议**：`toAbsolute` 统一 `command.values.clone()`（或文档声明返回结果与入参共享数组、不得原地修改）；更彻底的做法是把 `values` 暴露为只读视图。

### [轻微][存量] `pointAt` 的空段表回退写成「循环 + 立即 break」，实际只检查第一条命令

- **位置**：`f_svg/src/SvgPathMeasure.cj:153-159`
- **来源**：存量
- **判据**：review-checklist §1（不可达结构）/ §10（可读性）
- **证据**：静态确定 —— `for (command in path.commands) { if (...) { return ... } break }`，`break` 在同层无条件执行，第二圈永不进入；等价于 `if (commands.size > 0 && commands[0].kind == MoveTo && ...)`。
- **描述**：读者会以为在找「第一个 MoveTo」，实际只看第 0 条。当前语义（路径必须以 `M` 开头才有起点）与实现一致，故仅为可读性/误导问题；但若将来放宽「首命令可为 L/C」，此处会静默返回 (0,0)。
- **建议**：改写成显式 `if` 并注明「按规范首命令应为 MoveTo，否则起点视为 (0,0)」。

### [轻微][存量] tile 上限校验与告警文案重复

- **位置**：`f_svg/src/SvgPatternSampler.cj:229-236` 与 `239-244`（同一文案 `"pattern tile 像素数超过上限 ${SVG_MAX_PATTERN_TILE_PIXELS}"` 出现两次，两条 `throw` 结构相同）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 近似重复）
- **证据**：静态确定 —— 两处 `throw SvgException(..., kind: SvgErrorKind.Limit)` 只差触发条件（单轴超限 / 像素积超限），可合并为一次 `if (…|| pixelWidth * pixelHeight > MAX …)` 或抽 `limitError` 辅助。
- **描述**：文案与错误类别是契约的一部分，分散两处后改一处容易漏另一处（本模块其他地方已有 `limitError` 之类的统一入口，`SvgBuilder.cj:50`）。
- **建议**：合并为一个判据表达式 + 单条 `throw`；文案带 `tileWidth × tileHeight` 便于定位。

### [轻微][存量] `sample()` 的 `transform` 参数只做可逆性校验，不参与取样

- **位置**：`f_svg/src/SvgPatternSampler.cj:148-171`（`transform` 只在 `163` 行 `transform.invert().isNone()` 被使用）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：待确认 —— 公开签名 `sample(pattern, objectBounds, transform, options)` 未写文档说明 `transform` 语义；实现中 tile 映射只用 `patternTransform` 的逆矩阵（`SvgPatternSampler.cj:314-321`）。仓内唯一调用方 `SvgRenderer` 走的是 `sampleTile`（不带 `transform`），测试全部传 `SvgMatrix.identity`，因此无法从仓内判断该参数是否应参与设备空间分辨率决策。
- **描述**：传非单位 `transform` 的调用方会得到与原样调用完全相同的 tile（仅多一次可逆性检查），若其期望「按 CTM 决定 tile 光栅分辨率/裁剪」则行为不符。
- **建议**：补文档说明「`transform` 仅用于拒绝不可逆变换，tile 始终在用户空间生成」，或让 `transform` 参与 `pixelWidth/pixelHeight` 的推导。

### [轻微][存量] `normalizeCssPaintOrder` 对同一字符串做两遍分词与大小写归一

- **位置**：`f_svg/src/SvgPaintOrder.cj:117-123`（先 `splitCssWhitespaceWords(text.toAsciiLower())`，再调 `SvgPaintOrder.parse(text, warnings)`，后者又 `text.trimAscii().toAsciiLower()` + 再分词，`SvgPaintOrder.cj:63`）
- **来源**：存量
- **判据**：review-checklist §6.4（同一输入重复解析）
- **证据**：静态确定 —— 每次 computed style 计算 `paint-order` 声明都分词/转小写两次，并在 `paintLayerFromName`（`SvgPaintOrder.cj:95`）中对每个 token 再做一次 `trimAscii().toAsciiLower()`（token 已是小写且无空白）。
- **描述**：纯冗余分配（每次 2 个 `Array<String>` + 每 token 1 个新 `String`），不影响正确性；CJK/ASCII 转小写走 `toAsciiLower`，无 locale 问题。
- **建议**：让 `parse` 接受已分词的 `Array<String>`（或让 `normalizeCssPaintOrder` 直接用 `tokens.size` 判空后调用一个内部 `build(tokens, warnings)`），`paintLayerFromName` 去掉多余的 trim/lower。

<!-- 第 20 部分 -->

### [严重][存量] #1 `antiAlias=Analytic` 与 `shape-rendering:crispEdges` 叠加时，每个被扫到的像素都饱和成不透明

- **位置**：`f_svg/src/SvgRasterizer.cj:284`（`computeCoverage` 的 Analytic 分支）与 `f_svg/src/SvgRasterizer.cj:390`（`coverageTotal` 的 `aaDisabled` 前置分支）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）、§10 正确性
- **证据**：静态确定 —— `computeCoverage` 在 `antiAlias == Analytic` 时**不看** `aaDisabled`，直接 `return analyticCoverage(...)`，其元素是 `0..65535` 的定点覆盖率（`SvgAnalyticRasterizer.cj:78` `ANALYTIC_COVERAGE_SCALE = 65535`，`SvgAnalyticRasterizer.cj:210-212`（`total = 65535`，`coverage[i] = round(clampSvgUnit(accumulated[i]) * total)`））；而 `coverageTotal()` 第一行 `if (this.aaDisabled) { return 1 }`，于是 `coverageRatio = count / 1 = count ≥ 1`，`alpha = ratio × color.alpha × opacity` 被 `clampSvgUnit` 夹到 1.0。
- **描述**：触发路径完全走公开 API：`SvgRenderOptions(antiAlias: SvgAntiAliasMode.Analytic)` + `shape-rendering: crispEdges`（或 `optimizeSpeed`）→ `SvgRenderer.cj:494` `svgShapeAntiAlias` 返回 `Some(false)` → `SvgRenderer.cj:664/674` 传入 `antiAliasOverride` → `prepareHints` 置 `aaDisabled = true`。结果：解析覆盖率仍按 4×4 精度算出（0..65535），但分母被当成 1，凡是覆盖率 ≥ 1/65535 的像素全部变成 `alpha = color.alpha × opacity`，即整条边缘向外扩约 1 像素并完全实心——`crispEdges` 想要的"1× 采样、二值边缘"反而变成"全实心外扩"。grep `antiAliasOverride` 在 `f_svg/src` 只命中 `SvgRasterizer` 自身、`SvgRenderer:664/674` 与 `SvgRenderingHintsM6_test.cj:106/128`，后者未改 `antiAlias`，故仓内无用例覆盖该组合。
- **建议**：在 `computeCoverage` 里把 `aaDisabled` 判断提前：`aaDisabled` 时走 1× 采样路径（`samples = 1` 的 `collectHits` 分支），不要进 `analyticCoverage`；或让 `coverageTotal()` 在 Analytic 下恒定返回 `ANALYTIC_COVERAGE_SCALE`，并在 `analyticCoverage` 之后把 `coverage` 二值化成 `0 / 65535`。前者与 `samplesPerPixel=1` 的语义一致，改动最小。

### [一般][存量] #2 `fillGradient` / `strokeGradient` 不复位 `aaDisabled` / `toleranceScale`，结果依赖调用顺序

- **位置**：`f_svg/src/SvgRasterizer.cj:189`（`fillGradient`）、`f_svg/src/SvgRasterizer.cj:223`（`strokeGradient`）、状态定义 `f_svg/src/SvgRasterizer.cj:72-74`、重置点 `f_svg/src/SvgRasterizer.cj:107`（`prepareHints`，仅被 `fill` / `stroke` 调用）
- **来源**：存量
- **判据**：review-checklist §11（隐藏状态导致行为漂移）、§10 正确性
- **证据**：静态确定 —— 只有 `fill`（102 行）与 `stroke`（138 行）调用 `prepareHints`；`fillGradient` / `strokeGradient` 直接走 `fillContoursShader` → `computeCoverage`，读的是上一次 `fill` / `stroke` 遗留的 `this.aaDisabled`。
- **描述**：同一 `SvgRasterizer` 实例上依次执行 `fill(path, color: c, antiAliasOverride: Some(false))` 再 `fillGradient(...)`，后者会用 1× 采样渲染（甚至叠加前一条问题的覆盖率分母错误），而单独调用 `fillGradient` 时是正常 AA。仓内 `SvgRenderer.cj:552/596/650` 每个 paint 都新建 rasterizer，所以库内流程不触发；一旦外部使用者复用实例（类是 `public`，`fillGradient`/`strokeGradient` 也是 `public`），渲染结果便与元素绘制顺序耦合，且没有任何警告。
- **建议**：把 `aaDisabled` / `toleranceScale` 从字段改为 `fillContours` / `fillContoursShader` 的显式参数（`computeCoverage(contours, fillRule, aaDisabled, samples)`），或在两个 Gradient 入口开头调用 `prepareHints(1.0, None)` 显式归零；前者能同时消除"字段跨调用存活"这一类问题。

### [一般][存量] #3 覆盖率缓冲按整幅画布分配 `Int64`，默认上限下单个元素可达 512 MiB

- **位置**：`f_svg/src/SvgRasterizer.cj:316`（`let coverage = Array<Int64>(this.bitmap.width * this.bitmap.height, repeat: 0)`）
- **来源**：存量
- **判据**：review-checklist §5（按画布规模一次性物化）、§7（中间副本）
- **证据**：静态确定（按公式可算）—— 分配量 = `width × height × 8` 字节；`SvgRenderOptions.maxPixels` 默认 `64 * 1024 * 1024`（`SvgBitmap.cj:230`，`SvgRenderOptionsM4_test.cj:33` 断言），`SvgBitmap` 自身只占 `4` 字节/像素。满配画布下：位图 256 MiB + 覆盖率 512 MiB；且只在 `firstRow..lastRow`（`311-315`）落到画布内时才分配，**与路径 bbox 无关**——一个 10×10 图标画在 4096×4096 画布上同样分配 128 MiB，每个元素一次。
- **描述**：不是"无界增长"（有 `maxPixels` 拒绝路径），但属于按画布规模而非按路径规模放大内存：一次渲染里 N 个元素就有 N 次 8 B/px 的瞬时分配，GC 压力与大画布下的峰值内存都会被放大；并发渲染多张图时叠加明显。
- **建议**：只分配 bbox 行区间 `(lastRow - firstRow + 1) × width`，索引统一加 `(row - firstRow) * width` 偏移；元素类型可降为 `UInt16`（上限 `samples² = 16`，`UInt8` 也够），收益再乘 4。改后需用等价性用例固定输出（现成的 `SvgRasterizer_test.cj` 覆盖率断言可直接复用）。

### [一般][存量] #4 PNG 编码把整幅位图物化 3–4 份，64 Mi 像素时峰值接近 1 GiB

- **位置**：`f_svg/src/SvgPngEncoder.cj:44-53`（`buildRawScanlines` + `idat` 组装）、`f_svg/src/SvgPngEncoder.cj:59-72`（`raw` 全量数组）、`f_svg/src/SvgPngEncoder.cj:92-105`（`writeChunk` 的 `crcInput` 全量拼接）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化）、§7（删除中间副本）
- **证据**：静态确定（按公式可算）—— `raw = (4w+1)h ≈ 256 MiB`（64 Mi 像素）；`idat.write(deflated)` 再持有一份同量级压缩数据；`writeChunk` 里 `crcInput` 又把 `kind + data` 拼成第三份；`encode` 的 `output` ByteBuffer 是第四份。`SvgPngEncoder.encode` / `SvgBitmap.toPngBytes` 没有任何尺寸校验，只受 `SvgBitmap` 分配成功与否约束。
- **描述**：`write` 已经有 `OutputStream` 形态，但实现仍是"先造完整 raw、再造完整 IDAT、再拼 CRC 输入"，因此 `writePng(OutputStream)` 这条名义上的流式入口并没有降低峰值内存。对 4K×4K RGBA（67 MiB raw）尚可接受，对接近 `maxPixels` 的输出则会连续申请数份 256 MiB 级数组。
- **建议**：逐行生成 scanline → 直接 `compressor.write(row)`，同时增量更新 Adler-32（`first/second` 两个累加器即可，无需保留 `raw`）；CRC 用现成的增量接口 `SvgCrc32.update(0, kindBytes)` + `SvgCrc32.update(prev, data)` 两段计算（`SvgPngDecoder.cj:259` 已经这么用），删掉 `crcInput`。改完峰值从 `O(4wh)` 降到 `O(w)`。

### [一般][存量] #5 `SvgPathCommand` 不校验参数个数，光栅化直接下标访问 → 抛 `IndexOutOfBoundsException` 而非 `SvgException`

- **位置**：`f_svg/src/SvgRasterizer.cj:522`（`command.values[0]`，同类 `530` / `536-538` / `552-553` / `586-591`）；根因在 `f_svg/src/SvgPathData.cj:106`（`SvgPathCommand.init` 只赋值、不校验 `values.size == kind.arity()`，`arity()` 已存在于 `SvgPathData.cj:80`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失：非法输入应走模块约定的 `SvgException`/`SvgErrorKind`）、§14（契约未封闭）
- **证据**：静态确定 —— `SvgPathCommand` 的 `init` 是 `public` 且无长度校验，`SvgPathData(commands:)` 同样不校验；`flattenPathData` 对 `MoveTo` 无条件取 `values[0]`/`values[1]`。
- **描述**：`SvgPathData.parse` 产出的命令长度总是正确，所以解析路径安全；但 `SvgPathData(commands: [...])` 与 `SvgPathCommand(kind: .CurveTo, relative: false, values: [])` 都是公开构造入口，外部拼装路径数据后交给 `SvgRasterizer.fill` 会得到越界异常（非 `SvgException`，`SvgErrorKind` 契约被绕过），调用方无法按 `kind` 分流处理。
- **建议**：在 `SvgPathCommand.init` 里按 `kind.arity()` 校验并 `throw invalidValue(...)`（这是唯一能覆盖所有下游的落点）；若不便改构造，则在 `flattenPathData` 入口遍历一次按 `arity()` 校验后抛 `SvgException(kind: InvalidValue)`。

### [轻微][存量] #6 `SvgPngDecoder` 三处恒假分支 + 一处未使用 import

- **位置**：`f_svg/src/SvgPngDecoder.cj:251`（`length < 0`）、`f_svg/src/SvgPngDecoder.cj:99-104`（`pixels > SVG_MAX_IMAGE_PIXELS` 二次判断）、`f_svg/src/SvgPngDecoder.cj:136-140`（`bytesPerPixel < 1` 兜底）、`f_svg/src/SvgPngEncoder.cj:20`（`import fountain::f_base.*`）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支、未使用的 import）
- **证据**：静态确定 —— `readU32BE`（`604-607`）由 4 个 `Byte` 拼成 `Int64`，值域 `0..0xFFFFFFFF`，`length < 0` 恒假；`header.width > SVG_MAX_IMAGE_PIXELS / header.height`（91-92）已保证 `width × height ≤ 上限`（`height > 上限` 时右值为 0，任何 `width ≥ 1` 都会先抛），故 99 行恒假；`bytesPerPixel = (channels × bitDepth + 7) / 8`，而 `bitDepth ≥ 1` 已由 109 行的 `validateColorCombination` 保证，故 `< 1` 恒假。`SvgPngEncoder.cj` 全文件未使用 `f_base` 任何符号（`SvgBitmap`/`SvgCrc32` 均在 `f_svg` 内，`invalidValue` 未被调用）。
- **描述**：四处都是"看起来在防御、实际不会成立"的分支，读代码时会误导人以为还存在溢出/负长度窗口；未使用 import 属残留。
- **建议**：删除 251 行的负值判断、99-104 行的重复上限判断与 136-140 的兜底（或改注释说明由上游保证）；`import fountain::f_base.*` 建议在 WSL 构建确认后移除。

### [轻微][存量] #7 `SvgPngDecoder_test` 内构造后未读取的局部变量

- **位置**：`f_svg/src/SvgPngDecoder_test.cj:296-299`（`encoded` / `scanline`）、`f_svg/src/SvgPngDecoder_test.cj:320` 与 `332`（`pixelIndex`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）
- **证据**：静态确定 —— 第一段 `while`（290-302）的产物只有 `expected` 在 327-330 被断言使用，`encoded` 与 `scanline` 之后再无引用；`pixelIndex` 只做 `pixelIndex++`，从未参与断言。
- **描述**：`filterTypesRoundTrip` 的第一段循环实际只为了填 `expected`，却顺手算了一遍前向 filter 与 scanline 拼装（真正的拼装在 304-316 的第二段），是重复劳动 + 死变量；`pixelIndex` 纯噪声。测试仍然通过，但读者会以为第一段产物参与了校验。
- **建议**：第一段只保留 `expected` 的填充（或直接把它并入第二段循环），删掉 `encoded` / `scanline` 与 `pixelIndex`。

### [轻微][存量] #8 重复逻辑：Adler-32、PNG 签名、`maxInt64` / `maxFloat` 多份实现

- **位置**：`f_svg/src/SvgPngDecoder.cj:609` 与 `f_svg/src/SvgPngEncoder.cj:82`（`adler32` 逐行同构）；PNG 签名 `SvgPngEncoder.cj:22`、`SvgPngDecoder.cj:236`（另在 `SvgPngEncoder_test.cj` / `SvgPngDecoder_test.cj` 各 2 处字面量）；`SvgRasterizer.cj:489` 与 `SvgRenderTree.cj:1722`（`maxInt64`）；`SvgRasterizer.cj:731` 与 `SvgTimeline.cj:1213`（`maxFloat`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— `grep "func adler32"` 在 `f_svg` 内 4 处（2 处生产 + 2 处测试），生产两处函数体逐行一致（65521 取模、`b * 65536 + a`）；签名数组 `[0x89,0x50,0x4E,0x47,...]` 共 5 处；`maxInt64` / `maxFloat` 各两份同实现（仅参数名不同）。
- **描述**：Adler-32 是编解码两侧必须完全一致的校验算法，两份实现任何一处被"顺手优化"（例如加 `%` 的合并技巧）都会让编码/解码互不兼容，属高风险重复；签名常量分 5 处同理。
- **建议**：把 `adler32`（含增量更新形态）与 `PNG_SIGNATURE` 提到 `f_svg/src` 内的共享 util（与 `SvgCrc32` 同级），编码器改用同一份；`maxInt64` / `maxFloat` 收敛为一份内部工具（放 `SvgValueTypes` 之类既有工具文件），或直接用 `std.math.max` 的重载（需先查签名确认）。

### [轻微][存量] #9 重复逻辑：合成循环、渐变描边轮廓化、`polygon` / `polyline` 整文件同构

- **位置**：`f_svg/src/SvgRasterizer.cj:366-387` 与 `399-415`（`compositeCoverageShader` / `compositeCoverage`）；`f_svg/src/SvgRasterizer.cj:139-159` 与 `243-262`（`stroke` / `strokeGradient` 的"扁平化 → 轮廓化 → 逐点变换"）；`f_svg/src/SvgPolygon.cj:19-38` 与 `f_svg/src/SvgPolyline.cj:19-38`
- **来源**：存量
- **判据**：review-checklist §2（换参数/换类型的同语义实现）
- **证据**：静态确定 —— 两个合成函数的循环体逐句一致（`count > 0` → `ratio = count/total` → `alpha > 0` → `bitmap.blend(SvgRgba.fromColor(...))`），唯一差异是颜色来自 `colorAt(x,y)` 还是常量 `color`；`stroke` 与 `strokeGradient` 的 139-150 与 243-254 都是 `matrixScale → userTolerance → flattenPathData(identity) → SvgStrokeStyle → outlineContours`，随后 `151-158` / `255-262` 都是同一段 `matrix.apply` 双循环；`SvgPolygon` / `SvgPolyline` 除构造参数 `"polygon"` / `"polyline"` 外完全相同。
- **描述**：三条都不是"错误"，但都是行为漂移的高发点：合成口径（覆盖率 → alpha → 预乘 over）一旦改动要同时改两处，漏一处就是渐变与纯色着色不一致；描边轮廓化两侧的容差/变换顺序同理；`points` 属性的缓存失效逻辑（`pointsCache` + `attributesVersion`）也是两份。
- **建议**：合成合并为 `compositeCoverage(coverage, opacity, colorAt: (Int64, Int64) -> SvgColor)`，纯色调用方传常量闭包（注意保留现有 `x/y` 计算顺序，验证逐像素等价）；描边前处理抽成 `buildDeviceOutline(path, matrix, strokeWidth, ..., tolerance) -> Array<Array<SvgPoint>>`；`SvgPolygon` / `SvgPolyline` 合并到同一个 `internal` 基类（tag 由 `init` 传入），或至少让 `pub` 属性实现共用一处（差异只有元素名，没有业务语义差异）。

### [轻微][存量] #10 可读性：`deviceContours` 实为用户坐标；预算错误消息硬编码全局上限

- **位置**：`f_svg/src/SvgRasterizer.cj:150`（`let deviceContours = SvgStrokeOutliner.outlineContours(userContours, style)`）、`f_svg/src/SvgPngDecoder.cj:46`（`SvgDecodeBudget.consume` 的消息）
- **来源**：存量
- **判据**：review-checklist §10（命名与实际语义不符）、§11（语义与注释/契约不符）
- **证据**：静态确定 —— 150 行拿到的是 `userContours`（141 行以 `SvgMatrix.identity` 扁平化）的轮廓化结果，真正转到设备坐标发生在 152-158 的循环里，名字与内容相反；`SvgDecodeBudget.init` 接受任意 `total`（测试里用 `1` / `4` / `1024`），但 44-48 行的超限消息固定打印 `SVG_MAX_RENDER_DECODE_PIXELS`（64 Mi），与实际预算不符。
- **描述**：前者容易让后续维护者误以为 156 行的 `matrix.apply` 是重复变换而删掉；后者会让调用方看到"超过上限 67108864"却只申请了 1024 的困惑日志，排查时被带偏。
- **建议**：150 行改名 `userOutlines`（`strokeGradient` 的 254 行 `outlines` 已是正确命名）；`SvgDecodeBudget` 增加 `total` 字段并在消息里打印 `this.total`（或在 `consume` 里打印剩余量），保留全局上限只在 `SvgRenderer` 构造预算处体现。

<!-- 第 21 部分 -->

### [一般][存量] #1 `<use>` 的 `transform` 被丢弃；`opacity` / `clip-path` / `mask` / `filter` 同样不生效

- **位置**：`f_svg/src/SvgRenderTree.cj:533-535`（`case use: SvgUse => this.expandUse(...)`）、`:1006-1008`（只乘 `translate(x, y)`）、`:1067-1075`（只乘**目标**元素的变换）；对照 `:558-566`（text）、`:1118-1125`（shape）、`:1404-1412`（image）、`:736-744`（container）都乘了自身 `elementTransformMatrix`
- **来源**：存量（工作区快照；`git diff` 为空，非本次改动）
- **判据**：review-checklist §11（契约与实现不符）、§14（功能完备性）；承诺源 `f_svg/README.md:127`「`transform` 支持 `translate`/`scale`/`rotate`/…」、`README.md:150`「`display` / `visibility` / `opacity` 支持」
- **证据**：静态确定 —— `expandUse`（`:955-1102`）从入口到结束没有调用 `elementTransformMatrix(use, …)`，也没有任何 `resolveUrlRef(style.get("clip-path"/"mask"/"filter"))` 或 opacity 分层；`walkElement` 取到的 `style`（`:522-528`）只用于 `display:none` 判断，随后 `case use` 直接 `return`，style 再未被消费
- **描述**：`<use transform="translate(10,20) scale(2)"/>`、`<use opacity="0.5"/>`、`<use clip-path="url(#c)"/>` 全部静默无效，与同文档里 `g` / 图形元素的行为不一致。其中 `opacity` / `clip-path` / `mask` / `mix-blend-mode` 一项已在 `f_svg/doc/spec/add-f-svg-m4/verification-2.md:110` 被记录（属"已知限制"），但 **`transform` 既没有被记录，也没进 README 的"部分支持"行**；同时 `SvgElementApi.svgUseBBox`（`f_svg/src/SvgElementApi.cj:207-252`）也不含 use 自身变换，因此渲染与 bbox 两条路径一致地错，缺少互相校验的机会
- **建议**：`expandUse` 开头补一次 `matrix = context.matrix.multiply(elementTransformMatrix(use, style: style, bounds: targetBounds, …))`（几何先于 `translate(x,y)` 还是之后需按 SVG 规范确认，建议补一条像素断言固定顺序）；`opacity` / `clip-path` / `mask` / `filter` 用与 `walkContainer:751-801` 相同的元素组包装（可复用 `appendFilteredGroupBegin:1244`）；若本轮不做，至少在 README 的 `use` 行明确写出不支持项，避免与 `transform` 那一行冲突

### [一般][存量] #2 嵌套 `<svg>` 的 `opacity` / `clip-path` / `mask` / `filter` 不生效

- **位置**：`f_svg/src/SvgRenderTree.cj:530-532`（`case svg: SvgRoot => this.walkNestedSvg(...)`）、`:812-874`（整个 `walkNestedSvg`）
- **来源**：存量
- **判据**：review-checklist §11（同一属性对不同元素行为不一致）、§14；对照 `:745-753`（`walkContainer` 的 `grouped` 判据同时看 opacity / clip-path / mask / filter / clip / blend / isolation）
- **证据**：静态确定 —— `walkNestedSvg` 只做视口计算（`:820-831`）、`overflow` 裁剪与 quad（`:834-857`）、`depth+1`（`:865`），全程没有 `style.opacity()`、没有 `resolveUrlRef(style.get("clip-path"/"mask"/"filter"))`、没有 `blendMode` / `isolated`
- **描述**：`<svg opacity="0.5">`、`<svg clip-path="url(#c)">`、`<svg filter="url(#f)">` 静默无效；`transform` / `display` 则正常（`:823-831`、`:526`），因此是"部分属性可用"的中间态，最容易让使用者误判。仓内无覆盖：`grep "<svg[^>]*opacity"`/`"<svg[^>]*transform"` 在 `*_test.cj` 均无命中（旋转裁剪用例只测 overflow）
- **建议**：把 `walkNestedSvg` 的收尾与 `walkContainer` 对齐——先按 `svg` 自身样式建组（opacity / clip / mask / filter / blend / isolation），再 `walkChildren`；`clip` 与视口裁剪的先后顺序需与 `applyEffects:693-759` 现有次序保持一致

### [一般][存量] #3 外部文档缓存按 `href` 无界累积，单次构建可放大到 N×16 MiB

- **位置**：`f_svg/src/SvgRenderTree.cj:254-257`（`externalDocuments` / `missingExternalDocuments`）、`:900-931`（命中/未命中分支）、`:914-919`（单文档 16 MiB 上限）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 按不可信输入累积）、§7（生命周期与上限）
- **证据**：静态确定 —— 上限只有"单文档字节"（`f_svg/src/SvgExternalDocument.cj:24` `SVG_EXTERNAL_MAX_BYTES = 16 MiB`）与"引用深度 4"（同文件 `:33`、`svgExternalDepthAllows`），代码里没有任何"不同 href 数量"或"累计字节"的计数；解析成功即 `this.externalDocuments[href] = parsed`（`:924`）并保留到 builder 生命周期结束
- **描述**：`href` 来自不可信 SVG，provider 由宿主注入。100 个不同 href 各自 16 MiB 的文档 ⇒ builder 内常驻约 1.6 GiB（每份还含完整 `SvgElement` 树与 `SvgStylesheet`），且 `SvgParser` 的 `maxElements = 1,000,000` 允许单文档本身很大；`missingExternalDocuments`（`:910`）同样只增不减，只是对象很小。这是"有单点上限、无聚合上限"的典型放大面
- **建议**：复用 `SvgDecodeBudget`（`SvgImageResource` 已在用）给外部文档加"累计字节 + 文档数"预算，超限按 `SvgException(kind: Limit)` 抛；或按 `svgExternalDepthAllows` 的风格新增 `SVG_EXTERNAL_MAX_DOCUMENTS`（如 8）并在超限时 warning + 停止解析

### [一般][存量] #4 每个分组一条整画布离屏层，层数 × 画布无聚合上限

- **位置**：`f_svg/src/SvgRenderer.cj:144-160`（`GroupBegin` → `SvgGroupCompositor.createLayer(list.width, list.height, …)`）、`:221-253`（非组指令的 `needsLayer` 分支同样整画布）、层分配实现 `f_svg/src/SvgClipMask.cj:155-158`（`createLayer` → `SvgBitmap(width, height)`）
- **来源**：存量
- **判据**：review-checklist §5（按画布规模物化）、§7（内存上限）
- **证据**：静态确定（按公式可算）—— 单层字节 = `width × height × 4`；`frames` 是后进先出栈（`:146`、`:165`），外层层在子组渲染期间**保持存活**，峰值 ≈ 打开层数 × 单层；`SvgRenderOptions.maxPixels` 默认 `64 * 1024 * 1024`（`f_svg/src/SvgBitmap.cj:230`，`SvgRenderOptionsM4_test.cj:33` 断言）⇒ 满配单层 256 MiB；文档深度上限 512（`f_svg/src/SvgOptions.cj:66`），`<g opacity="0.9">` 只需嵌套 8 层就到 2 GiB 量级
- **描述**：不是"无界增长"（有 `maxPixels` 与 `maxDepth` 两条拒绝路径），但缺"层数 × 画布"的聚合预算：`opacity < 1`、`isolation:isolate`、`mix-blend-mode`、以及**只要有 `clipRect` 的容器**（`walkContainer:751` 的 `context.clipRect.isSome()`）都会触发建层，而 `opacity`/`clip` 是常见写法，文档又由不可信输入控制。深嵌套 + 大画布时先 OOM 而非先触发 `maxPixels`
- **建议**：层尺寸改为"命令包围盒与画布求交"后分配（`GroupBegin` 已带 `bounds`/`clipBounds`，无包围盒时退回整画布），合成时带偏移：`composite(target, layer, opacity, offsetX, offsetY, mode)`；同时加"离屏层累计字节"预算（如 `maxPixels × 2`），超限按 `Limit` 抛，避免用 OOM 当拒绝路径

### [一般][存量] #5 渲染遍历对普通容器嵌套无深度上限，程序化深树可致栈溢出

- **位置**：`f_svg/src/SvgRenderTree.cj:504-521`（`walkChildren` ↔ `walkElement` 互递归）、`:1517-1536`（`findSvgElementById`）、`:1789-1813`（`findSvgElementPath`）、`:1586-1680`（`markerContentFitsIn`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 深度上限只存在于三处：解析期 `SvgBuilder.cj:127-128`（默认 512，`SvgOptions.cj:66`）、`use` 链 `:981`（`SVG_USE_MAX_DEPTH`）、嵌套 svg `:817`（64）。普通 `g` / 容器嵌套**没有任何计数**，而 `SvgElement.appendElement`（`SvgElement.cj`）、`SvgAuthoringBuilder`、`SvgRenderer.render(element:width:height:)`（`SvgRenderer.cj:101`）都接受任意深度的程序化树
- **描述**：解析得到的文档受 `maxDepth = 512` 保护，栈帧数量可控；但 API 拼出的 10⁵ 层 `<g>` 链会让 `walkElement` 每层占一帧（含 3 个引用参数与每层 `ArrayList`），先爆栈（仓颉不保证尾调用优化，`walkContainer` 末尾还有 `for` 循环，本就不是尾位置）；`findSvgElementById` 会在同深度上再走一遍
- **建议**：给渲染遍历加与 `use`/嵌套 svg 同风格的 `depth` 计数（例如 > 256 抛 `SvgException(kind: Limit)`），`findSvgElementById` 传同一计数；或把 `walkChildren`/`walkElement` 改成显式栈迭代（`SvgDisplayCommand` 已是扁平列表，改成"待访问队列 + 帧状态"并不破坏现有结构）

### [一般][存量] #6 `SvgRenderer` / `SvgRenderTreeBuilder` 的会话状态无同步，也未声明单线程使用

- **位置**：`f_svg/src/SvgRenderer.cj:68-72`（`warnings` / `warnedColorProfiles` / `sessionGuard`）、`:280`、`:293-295`、`:131-141`；`f_svg/src/SvgRenderTree.cj:247-259`（`warnings` / `externalDocuments` / `missExternalDocuments` / `textLayouts` / `renderOptions`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）、§11（契约未声明）
- **证据**：待确认 —— `render` 期间对 `ArrayList<String>`（`warnings`）与 `HashMap`（`warnedColorProfiles`、`externalDocuments`）追加写、对 `sessionGuard.stack`（`f_svg/src/SvgRenderGuard.cj:30-54`）增删，全部无锁无原子；类注释（`SvgRenderer.cj:61-65`）只承诺"不读时间/随机数/环境变量"，既没写线程安全也没写单线程。仓内没有并发复用的用例，无法确认外部是否存在该用法
- **描述**：`SvgRenderer(options:)` 的 `options` 天然不可变、看起来就是"建一次、多次 render"的对象；两线程共享同一实例时，`warnings` / `warnedColorProfiles` 会出现丢失写入与并发扩容，`sessionGuard.stack` 的 `enter/leave` 交错会让引用循环检测误判（一个线程 `enter` 的 identity 被另一线程 `leave` 弹掉），表现为随机丢内容而非崩溃，排查成本高
- **建议**：把会话状态（`warnings`、`sessionGuard`、`SvgImageResource`、`warnedColorProfiles`）从实例字段下沉为 `renderDisplayList` 的局部对象（`SvgRenderer` 只保留 `options`），顺带解决"多次 render 后 `warnings` 只增不减"；若保持现状，则在类注释与 README 明确"实例不可跨线程并发使用"

### [轻微][存量] #7 `needsLayer` 中 `filter` / `blendMode` 两个条件对非组指令恒不成立

- **位置**：`f_svg/src/SvgRenderer.cj:217-221`（`command.filter.isSome() || … || command.blendMode != SvgMixBlendMode.Normal`）、`:224-238`（filter 应用块）、`:253`（`mode: command.blendMode`）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 非测试代码共 9 处 `SvgDisplayCommand(...)` 构造点：`SvgRenderTree.cj:600/784/1151/1438/1258` 是 `GroupBegin`（带 `blendMode`），其余 `:614`（Text）、`:1177`/`:1204`（Fill/Stroke）、`:1452`（Image）与 `SvgRenderer.cj:300/339/361/383`（文本轮廓、装饰线）全部显式 `filter: Option<SvgElement>.None` 且不传 `blendMode`（默认 `Normal`）；`renderDisplayList` 的 `GroupBegin` 走独立 `case`（`:144`），不会进入这段
- **描述**：`FillPath/StrokePath/Text/Image` 的 `filter` 恒 `None`、`blendMode` 恒 `Normal`，故 218 行的 filter 子句、224-238 的整段 filter 应用、253 行的 `mode:` 都是死路径；更大的问题是它构成陷阱——将来若给元素指令也填 `blendMode`，就会与树里已有的 elementGroup（`SvgRenderTree.cj:598-611`）叠加成"两次混合"
- **建议**：删掉这两个条件与 224-238 分支（保留一句注释说明组指令已承担），或在 `SvgDisplayCommand` 字段注释里写清"非 `GroupBegin` 指令的 `filter` 必须为 `None`、`blendMode` 必须为 `Normal`"，并加断言

### [轻微][存量] #8 `applyQuadCoverages` 注释写"交集缓冲"，实现是并集，缓冲按外层 quad 走

- **位置**：`f_svg/src/SvgRenderer.cj:863-897`（`:872-888` 的 `left = min(...)` / `right = max(...)`、`:893-896` 注释"交集外不可见；交集内先用 255 初始化"）
- **来源**：存量
- **判据**：review-checklist §11（注释与实现不符）、§7（缓冲按画布规模物化）
- **证据**：静态确定 —— 上界由 `left = min(left, box.x)`、`right = max(right, box.x + box.width)` 得到，是各 quad AABB 的**并集**；注释（`:861-862`、`:895-896`）声明的是"交集缓冲"。当前结果之所以正确，是因为 `applyEffects` 先用同组 AABB 的交集 `clipRect` 清零（`:693-696`，`clipRect` = `childClip` 链式 `intersect`，见 `SvgRenderTree.cj:842-845`），使存活像素必落在每个 quad 的 bbox 内；该前提只写在别处，没有任何断言
- **描述**：并集缓冲最坏等于整画布（`intersectionWidth × intersectionHeight` 字节，默认上限下 64 MiB），多层 quad 时扫描面积与分配都按最外层走；同时"先 clipRect 后 quad"的顺序一旦被调整（例如把 quad 提前到 filter 之前），漏裁剪会静默发生
- **建议**：改成真交集（`left = max(...)`、`right = min(...)`），交集为空直接 `clearBitmapAlpha`，缓冲自然缩小；若保留并集，则把注释改成"并集，交集外由 `clipRect` 先清零"，并在 `applyEffects` 注明两条清理顺序不可交换

### [轻微][存量] #9 `clipRectCoversCommand` 的描边余量未覆盖 miter 上限

- **位置**：`f_svg/src/SvgRenderer.cj:782-791`（`var margin = 1.0; margin += style.strokeWidth().value * max(sx, sy)`）、判定 `:808-810`
- **来源**：存量
- **判据**：review-checklist §11（快速路径判据不完整 → 该裁的没裁）
- **证据**：待确认 —— 描边相对路径的最大外扩是 `max(miterLimit × w / 2, w / 2)`；`stroke-miterlimit` 缺省 4（`f_svg/src/SvgComputedStyle.cj:278-280`），即最坏 `2w`，而 margin 只有 `1 + w × max(sx,sy)`。`max(sx,sy) = 1`、`w = 3` 时 margin = 4 < 6，45° 尖角可越过裁剪矩形。需要构造"裁剪矩形贴着包围盒、路径为锐角折线"的用例才能观测
- **描述**：命中时 `needsLayer` 被判为 false，跳过离屏层，尖角会画到裁剪矩形之外；常规矩形/圆角描边（miter 外扩 ≤ w/2）不受影响，因此长期不会被发现
- **建议**：margin 用 `1 + max(w × scale, miterLimit × w × scale / 2)`（lineCap 的 `w/2` 已包含）；或保守处理：`style.strokeMiterLimit() > 2` 时直接返回 false（多一次离屏层，不改变像素）

### [轻微][存量] #10 文本忽略 `paint-order`，固定 fill → stroke

- **位置**：`f_svg/src/SvgRenderer.cj:310-311`（`this.drawFill(...)` 紧接 `this.drawStroke(...)`，无层序判断）
- **来源**：存量
- **判据**：review-checklist §14（README 承诺与实现不符）；承诺源 `f_svg/README.md:146`「`paint-order` 支持 `fill` / `stroke` / `markers` 任意无重复顺序」
- **证据**：静态确定 —— `svgPaintOrderOf` 全仓仅 `SvgRenderTree.cj:1164`（`addShape`）使用，`paintOrder` 在 text / image 路径无命中；`SvgDisplayCommand` 也没有携带层序的字段
- **描述**：`<text paint-order="stroke">`（先描边后填充，避免细笔画被描边吃掉）无效；文本装饰线的 wavy / 普通 run 也固定按"描边 → 填充"输出（`:331-393`）。图形元素的 markers 层序由 `addShape:1226-1238` 正确实现，因此行为在元素之间不一致
- **建议**：让 `SvgRenderer` 的 Text 分支读 `style.paintOrder()`，按 `layers` 顺序调用 `drawFill` / `drawStroke`（装饰线内部次序不变）；补一条 `paint-order="stroke"` 的像素断言（描边色与填充色不同即可区分）

### [轻微][存量] #11 重复逻辑：四角 AABB ×4、嵌套视口裁剪块 ×3、元素组包装 ×3

- **位置**：四角 AABB —— `f_svg/src/SvgRenderTree.cj:1550-1566`（`transformedRectBounds`）、`:1756-1764`（`unionCommandBounds` 内联）、`f_svg/src/SvgRenderer.cj:792-807`（`clipRectCoversCommand` 内联）、`:1115-1122`（`drawImage` 内联）；嵌套裁剪块 —— `SvgRenderTree.cj:842-857`、`:1040-1052`、`:1334-1361`；元素组包装 —— `SvgRenderTree.cj:582-633`（text）、`:1133-1241`（shape）、`:1420-1471`（image）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 内联化的同语义实现）
- **证据**：静态确定 —— 四段 AABB 都是"对 `(x,y)`/`(x+w,y)`/`(x+w,y+h)`/`(x,y+h)` 四次 `matrix.apply` → 两次 `min` + 两次 `max` → `SvgBounds(minX, minY, maxX-minX, maxY-minY)`"，逐句同构；三处裁剪块都是"`transformedRectBounds` → 与 `context.clipRect` 求交 → `!isAxisAlignedMatrix` 时 `appendSvgQuad(transformedRectQuad(...))`"
- **描述**：已核对差异点：marker 版多 `contentFits` 条件（`:1334`）、text 版组包围盒用 `clipBounds`（含装饰线，`:606`）、image 版 tag 硬编码 `"image"`——都属参数差异，无业务语义差异。风险在于 clip/quad 语义改动要同步改三处，漏一处就是"某个元素不裁剪"
- **建议**：`transformedRectBounds` 改 `internal` 供 `SvgRenderer` 复用（现在两文件各写一份）；嵌套裁剪提为 `nestedViewportClip(context, matrix, w, h, needQuad: Bool) -> (clipRect, clipQuads)`；元素组包装提为 `emitElementGroup(commands, tag, matrix, style, bounds, filtered, clipPath, mask, clip, quads)` 并保证 `GroupEnd` 配对

### [轻微][存量] #12 死存储：`var resolvedStackKey` 从未重新赋值

- **位置**：`f_svg/src/SvgRenderTree.cj:987`（`var resolvedStackKey = stackKey`）、`:1080`（`nextStack.add(resolvedStackKey)`）
- **来源**：存量
- **判据**：review-checklist §1（未使用可变性 / 死存储）
- **证据**：静态确定 —— `grep -n resolvedStackKey` 全仓仅这两处，函数体内无第二次赋值
- **描述**：读代码时会误以为外部 href 会在解析后被规范化（例如去掉 fragment 再入栈），但实际一直用 `stackKey`；而 `resolveExternalUse` 内部用的是 `"ext:" + href`（`:889`），两处对同一 href 的键规则分散在两个函数里
- **建议**：先改 `let`；若原意是要与 `resolveExternalUse` 的 marker 规则保持一致，则把键构造收敛成一个 `externalUseKey(href)` 并在两处共用

### [轻微][存量] #13 两套 `/tag[i]` 路径拼接，索引规则不同源

- **位置**：`f_svg/src/SvgRenderTree.cj:1774-1813`（`svgElementPath` / `findSvgElementPath`）与 `f_svg/src/SvgElement.cj:377-384`（`elementPath` / `siblingIndex`）
- **来源**：存量
- **判据**：review-checklist §2（同语义两份实现，易漂移）
- **证据**：静态确定 —— 两者都产出 `/svg[1]/g[1]` 形态（`SvgRoot_test.cj:107` 断言 `elementPath()`），`svgElementPath` 额外有"root 不匹配就返回 `/${target.tag}[1]`"（`:1785`）与"找不到就回退 base"（`:1781-1783`）两种降级；warning 文案（`:1307`、`SvgTextRenderer.cj:397`）用的是树遍历版，测试断言的是父链版
- **建议**：warning 场景直接用 `target.elementPath()`（目标必然在树上），仅在跨文档（外部 `use` 目标与主 root 不同树）时回退到树遍历；或把"同名兄弟计数"抽成 `svgSiblingIndex(node)` 供两处共用，避免一处按元素计数、一处按 `children` 计数时漂移

### [轻微][存量] #14 同一外部 href 每次 `use` 都重算整棵外部文档样式树并重复追加 warning

- **位置**：`f_svg/src/SvgRenderTree.cj:943-951`（缓存命中后仍 `SvgStyleResolver().compute(document.root, …)` 并 `this.warnings.add(warning)` 全量追加）
- **来源**：存量
- **判据**：review-checklist §6.4（同一输入重复解析）、§11（可观测噪声）
- **证据**：静态确定 —— 文档缓存（`:900-931`）只缓存 `SvgParser.parse` 的结果；`resolver.compute` 在缓存分支之后无条件执行，且 `resolver.warnings` 每次全量 `add`。同一 href 被 N 个 `<use>` 引用 ⇒ N 次全文档样式解析、同一 warning 出现 N 次
- **描述**：`SvgExternalDocumentM6_test.cj:59` 有"同一外部 href 两次 use"的用例，但只断言解析/provider 次数，不校验 warning 去重，因此重复告警不会被测出；对含大量 `<use>` 的外部文档，样式解析会随引用次数线性放大
- **建议**：把 `SvgStyleResolver` 结果与 `SvgDocument` 一起缓存（`HashMap<String, SvgExternalResolution>`，复用 `SvgExternalResolution` 的 `styles` 字段），warning 只在首次 compute 时收集

<!-- 第 22 部分 -->

### [严重][存量] F1 dash 切分的片段数无上限，极小 dash 值可造成长时间占用 CPU 与内存爆炸

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:547`（`dashPieces`，热点循环 `600-623`），配套 `149-159`（`isValidDash`）、`47`（`STROKE_EPSILON = 1e-9`）
- **来源**：存量（`git log -1 -- f_svg/src/SvgStrokeOutliner.cj` = `0a5bc715c`，2026-11-07；工作区无改动）
- **判据**：review-checklist §5（按不可信长度增长的无界容器）/ §6.4（按输入规模放大的循环）/ §11（边界未校验）
- **证据**：静态确定 —— `isValidDash` 只拒绝负数、NaN、Inf，任意正小数（如 `1e-4`）都通过；`dashPieces` 的内层 `while (consumed < length - STROKE_EPSILON)` 每轮只前进 `take = min(length-consumed, remaining)`，每轮新建 `SvgPoint`，每段 dash 结束时 `current.toArray()` 追加到 `result`。片段数 ≈ `路径长度 / (dash 周期)`，两个因子都由文档控制，代码里没有任何片段数上限、最短 dash 长度、总分配量上限。
- **描述**：`stroke-dasharray="0.0001"` 配一条长度 1000 的路径即产生约 5×10⁶ 个片段，每个片段还各自走 `outlineOne`（再产生四边形轮廓）。渲染入口 `SvgRenderer`→`SvgRasterizer.stroke`（`f_svg/src/SvgRasterizer.cj:150`）对这一路输入不做 clamp（`SvgRenderer.cj:509-527` 的 `scaleStrokeDash` 只做等比缩放），而 `pathLength` 属性还能把 dash 进一步等比缩小（`SvgRenderer.cj:517-527` 用 `actualLength / declaredPathLength`），等于给攻击者一个放大系数。后果是渲染不可信 SVG 时 CPU 与堆同时爆掉（OOM / 长时间无响应），本模块其余安全过滤（脚本、外部引用、`maxElements`、`maxDepth`）都拦不住这条路径。
- **建议**：在 `dashPieces` 入口对 dash 周期设下限（例如 `sum < 路径长度 / 最大片段数` 时按上限截断或退化为实线），并把片段总数上限（如 10⁴）作为常量或 `SvgRenderOptions` 字段；`isValidDash` 增加「最小有效 dash 长度」判据，与 `STROKE_EPSILON` 分离（后者目前是 1e-9，远小于 0.25 的几何容差，不能当业务下限用）。

### [一般][存量] F2 `calc()` 百分比对 `r` 用算术平均，规范要求对角线基准

- **位置**：`f_svg/src/SvgStyleResolver.cj:503`（`cssCalcPercentReference`，第 `507` 行）
- **来源**：存量（`git log -1` = `33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（契约与规格不符）+ §2（换算复制）
- **证据**：静态确定 —— 承诺源 `f_svg/doc/spec/add-f-svg-module/specs/svg-value-types/spec.md:34,36`：「`r` 用对角线基准」「对角线基准为 `sqrt(w²+h²)/sqrt(2)`」，`f_svg/doc/f_svg模块设计.md:254` 同述；实现为 `case "r" => Some((this.mediaWidth + this.mediaHeight) / 2.0)`。项目里已有正确实现 `toUserUnits(..., SvgLengthAxis.Diagonal, ...)`（`f_svg/src/SvgLength.cj:205-229`），本函数不复用而另写一份换算。
- **描述**：300×150 视口下 `calc(50%)` 用于 `r` 得到 112.5，规范值 118.6（偏低约 5%）；同一文档里非 `calc` 的 `r="50%"` 走 `toUserUnits` 得到 118.6，两条路径结果不一致。目前影响面限于 `r` + `calc()` + 百分比的组合。
- **建议**：`cssCalcPercentReference` 改为返回 `SvgLengthAxis`（或直接调用 `toUserUnits` 的百分比分支），`r` 映射到 `Diagonal`，删除自算的 `(w+h)/2`。

### [一般][存量] F3 样式缓存无界且跨 `compute` 复用，重复求值时诊断信息被静默丢弃

- **位置**：`f_svg/src/SvgStyleResolver.cj:70`、`71`（`styleCache` / `inlineCache`）、`84`、`85`（`warnedColorProfiles`）、`105`（`warnings.clear()`）、`212-235`（`parseStyleText` / `inlineDeclarations`）
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §5（缓存键无界、无容量/TTL）+ §3（静默失效：诊断不再产生）+ §11
- **证据**：静态确定 —— `styleCache` 以完整 `<style>` 文本为 key，`inlineCache` 以完整 `style="..."` 文本为 key，二者只在 `get`/赋值处出现，`prepare` 与 `compute` 都不清理、不设上限；`warnedColorProfiles` 同样只增不清。`compute` 每次 `warnings.clear()`（105），但 `parseStyleText` 命中缓存时不会再调用 `CssStyleSheet.parse(text, this.warnings)`（216），`normalizeColorProfile` 命中 `warnedColorProfiles` 也不再 `warnings.add`（933-936）。
- **描述**：同一 resolver 实例第二次求值（文档不同但样式文本相同）时，`style` 解析告警与 `color-profile` 告警都不再出现——调用方看到「无告警」却拿到了降级值，属于静默失效；同时三次 map 都以用户文本为 key 永久保留，长期持有 resolver（如服务端常驻）处理多份文档时内存只增不减，`SvgComputedStyle` 里还挂着这些 sheet。
- **建议**：`warnings.clear()` 时同步清 `warnedColorProfiles`；缓存改为「每次 `compute` 一份、`compute` 结束即弃」（`compute` 内部 `local` 容器）或加容量上限 + LRU；若确要跨调用缓存，则把告警与缓存绑定（缓存项里保存首次解析的告警，命中时重放）。

### [一般][存量] F4 `prepare` 只按根元素 identity 命中缓存，文档增删 `<style>` 后仍返回旧规则

- **位置**：`f_svg/src/SvgStyleResolver.cj:158`（`prepare`，早退在 `163-165`，写回在 `208-209`）
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（缓存失效缺失、注释契约不符）/ §12.1（可见性）
- **证据**：静态确定 —— 早退条件只有 `hasPrepared && preparedRoot == key`，`key` 是 `element.identity`；`mergedRules` / `selectorIndex` 一旦生成就不再随文档变化。项目已提供文档级变更通知 `SvgDocument.addMutationListener`（`f_svg/src/SvgDocument.cj:42-44`，`SvgMutationHub` 见 `f_svg/src/SvgMutation.cj:75`），但本类没有任何订阅（全目录 grep `mutationHub|addMutationListener` 在 `SvgStyleResolver.cj` 无命中）。
- **描述**：调用方 `compute(doc.root)` → 追加一个 `<style>`（或删除、改其文本）→ 再次 `compute(doc.root)`，第二次拿到的仍是第一次的规则集，且没有任何告警；类注释（`58-64`）写的是「`compute` 收集文档中的 `<style>`」，与实现的可观察行为不符。
- **建议**：`prepare` 增加失效信号——订阅 `SvgDocument` 的 mutation hub（或在 `prepare` 里比对已收集 `<style>` 文本序列的哈希），也可在类注释中显式声明「同一实例只对首次求值的文档快照有效」，二选一但必须落到文档上。

### [一般][存量] F5 `computeElement` 不清空 `warnings`，重复调用无限累积且无法区分来源

- **位置**：`f_svg/src/SvgStyleResolver.cj:125`（重载体 `132-136`），对照 `compute` 的 `105`
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（两个入口契约不一致、资源无界累积）
- **证据**：静态确定 —— `compute` 在求值前 `this.warnings.clear()`；`computeElement` 两个重载（`120-122`、`125-137`）都不清理，`cascade` 里的 `warnings.add`（`285`、`307`、`344`、`371`、`673`、`905`、`935`）直接追加到同一个 `ArrayList`。
- **描述**：循环里逐元素 `computeElement`（例如批量算样式）时，每个非法值都留一条告警且永不释放，长跑进程内存随调用次数线性增长；调用方也无法判断某条告警属于哪一次调用，与 `compute` 的「本次求值告警」语义不一致。
- **建议**：与 `compute` 对齐，在 `computeElement` 入口 `warnings.clear()`（若需保留历史则改成返回本次告警）；`warnedColorProfiles` 一并复位。

### [一般][存量] F6 `outlineElement` 的「解析快路径」与通用 outliner 语义不一致（忽略 dash、忽略圆角、百分比按裸数值）

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:104`（`outlineElement`）、`444-490`（`rectOutline`）、`502-519`（`circleOutline`）、`521-544`（`ellipseOutline`）
- **来源**：存量（`0a5bc715c`，2026-11-07）
- **判据**：review-checklist §11（同一公开 API 对不同元素类型行为漂移）/ §2（近似重复导致的行为漂移）
- **证据**：静态确定 —— `outlineElement` 对 `SvgRect`/`SvgCircle`/`SvgEllipse` 直接走 `rectOutline` / `circleOutline` / `ellipseOutline`，这三个函数体内 `style.dashArray` 零引用（`grep dashArray` 在本文件命中处仅 `69`、`89`、`549`、`552` 等 dash 分支）；`rectOutline` 内无 `rx`/`ry` 引用（圆角矩形被当成直角矩形）；几何值统一经 `lengthOrZero`（`f_svg/src/SvgGeometry.cj:375-380`）取 `.value`，百分比 `x="10%"` 被当成 10 用户单位。而 `SvgLine`/`SvgPolyline`/`SvgPolygon`/`SvgPath` 分支经 `outlinePolyline`/`outlineContours`，dash 正常生效。
- **描述**：同一个 `outlineElement(element, style)`，传 path 得到虚线，传 rect/circle 得到实线环；带 `rx="4"` 的圆角矩形描边变成直角；百分比几何在描边轮廓里错位。随着 `style.dashArray` 由调用方按元素类型决定是否预切分，行为差异对使用方是隐形的。
- **建议**：`outlineElement` 入口统一判断 `style.dashArray` 有效时改走「几何→点列→`outlinePolyline`/`outlineContours`」通用路径（`rectOutline` 已有该分支，只需把条件从「join 非 miter」改成「dash 有效 或 join 非 miter」）；圆角与百分比要么解析后再轮廓化，要么在注释里写明该入口只接受无单位、无 dash 的样式。

### [一般][存量] F7 `SvgStyleResolver` 全部求值状态是可变字段且无同步，共享实例并发 `compute` 会串扰

- **位置**：`f_svg/src/SvgStyleResolver.cj:69-85`（`sheet`/缓存/`mediaWidth`/`mediaHeight`/`interaction`/`preparedRoot`/`hasPrepared`）、`96-114`（`compute` 写这些字段）、`125-137`
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §12.1（共享可变状态无保护）；判据要求：指出共享路径 + 缺失的同步手段
- **证据**：静态确定 —— 共享路径：`public class SvgStyleResolver` 的实例被两个线程同时调用 `compute`（类未声明线程封闭，无 `Mutex`/`Atomic`，注释亦未声明「非线程安全」）。缺失同步：`mediaWidth`/`mediaHeight`/`interaction` 在 `102-104` 写入后被 `cascade` → `considerSheet`（`429`）/`cssCalcPercentReference`（`505-507`）读取；`prepare` 依据 `preparedRoot` 决定是否重建 `mergedRules`/`selectorIndex`（`163-165`、`205-209`）；`warnings` 在 `105` 被 `clear` 而 `cascade` 同时追加。仓内生产路径每次 `SvgStyleResolver().compute(...)` 新建实例（如 `f_svg/src/SvgElement.cj:461`），风险只落在外部复用实例的调用方。
- **描述**：线程 A 在 `compute` 中把 `mediaWidth` 设为 400 后，线程 B 把它改成 800，A 的 `@media` 求值就用了 B 的视口；A 清空 `warnings` 后 B 追加的告警被吞；两线程各自 `prepare` 不同 root 时 `mergedRules` 与 `selectorIndex` 可能来自不同文档，`considerSheet` 用 `index.candidates` 得到的下标去索引另一份 `mergedRules`（`425-426`），越界或取错规则。
- **建议**：优先做成无状态——`compute` 内部用局部 `SvgCascadeContext`（媒体尺寸、interaction、规则集、告警收集器）串起来，类只保留不可变的 `sheet`；若要保留缓存，把可变字段收进每调用一份的上下文。至少要在类注释写明「非线程安全，需每线程一份」。

### [轻微][存量] F8 `normalizedFontSize` 的 `isNone()` 分支是不可达死代码

- **位置**：`f_svg/src/SvgStyleResolver.cj:383-385`
- **来源**：存量（`33a56f6ba`）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `296-308` 已经保证 `normalizedFontSize` 在该分支之后必为 `Some`：第一次 `normalizeValue` 返回 `None` 时先重试继承值（`303`），仍 `None` 则赋 `Some("16px")`（`304-306`）；`309-382` 之间无任何再赋值。
- **描述**：`if (normalizedFontSize.isNone()) { fontSizeExpression = None }` 永远不会成立，读代码的人会误以为 `font-size` 仍可能缺省。
- **建议**：删除该分支；若本意是「回退后不再记录 var 表达式」，应在 `304-306` 的回退路径里直接 `fontSizeExpression = None`。

### [轻微][存量] F9 `dashPieces` 开头的 dash 有效性判断不可达

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:549-551`
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §1（不可达防御分支）
- **证据**：静态确定 —— `dashPieces` 是 `private`，仅有两处调用：`outlineContours:69-75` 与 `outlinePolyline:89-97`，两处都在调用前用同一条件 `style.dashArray.size == 0 || !isValidDash(style.dashArray)` 做了分流（`69`、`89`）。函数内 `549-551` 的同一判断恒为假。
- **描述**：重复的防御性分支让「dash 为空时是否切分」有两个真值来源，后续改动容易只改一处。
- **建议**：删除函数内的重复判断，或在函数首行注释「调用方已保证 dash 有效」，并在 `outlineContours`/`outlinePolyline` 里保留唯一判断。

### [轻微][存量] F10 轮廓方向反转的两处实现重复，`outlineContours` 与 `outlinePolyline` 的 dash 分支结构重复

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:366-377`（`ensurePositiveOrientation` 内的反转循环）与 `492-500`（`reverseContour`）；`69-75`（`outlineContours` 的 dash 分支）与 `89-97`（`outlinePolyline` 的 dash 分支）
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— `ensurePositiveOrientation` 在面积为负时执行的 `while (index >= 0) { reversed.add(points[index]); index-- }`（`370-376`）与 `reverseContour`（`492-500`）逐行同构，唯一差异是前者多一次 `signedArea` 判定；`outlineContours` 的「dash 无效 → `outlineOne`；否则逐 `dashPieces` → `outlineOne(false)`」与 `outlinePolyline` 的同一段（`89-97`）输入输出一致，仅前者多了 `width <= 0` 之外的首尾闭合检测。
- **描述**：反转逻辑存在两份，`reverseContour` 的语义（无条件反转）与 `ensurePositiveOrientation`（条件反转）名称接近，`487`/`516`/`540` 的 `reverseContour(ensurePositiveOrientation(x))` 组合会让读者误以为可能双重反转。
- **建议**：`ensurePositiveOrientation` 在面积为负时调用 `reverseContour`；`outlineContours` 抽出 `outlineWithDash(points, closed, style)` 供两个入口共用（保留 `outlineContours` 额外的闭合检测与 `outlinePolyline` 的宽度守卫作为调用前条件）。

### [轻微][存量] F11 `SvgTag.create` 与 `SvgTag.isKnown` 维护两份同构标签字面量表

- **位置**：`f_svg/src/SvgTag.cj:21-77`（`create`）与 `79-93`（`isKnown`）
- **来源**：存量（`f8b4c49bd`，2026-11-07）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 逐项比对两地：`create` 分支覆盖 47 个标签（含 `style|title|desc|metadata|discard` 与 8 个容器标签），`isKnown` 的 `match` 列表为同一集合；`SvgBuilder.cj:152-153`、`192` 成对使用 `isKnown` + `create`。
- **描述**：新增/删除标签时必须同时改两处，漏改一处会让 `SvgBuilder` 走进 `SvgUnknownElement`（`154`）或让严格模式的未知标签检查（`163-171`）与实际建模能力相反；当前两份一致，属可维护性风险而非现存错误。
- **建议**：保留 `isKnown` 作为 O(1) 判断（用 `HashSet` 常量或 `Array` + `contains`），`create` 的 `match` 作为唯一定义源；或让 `isKnown` 由 `create` 的标签表派生（避免每次实例化对象可先查表）。

### [轻微][存量] F12 同族枚举的 `toString()` 约定不一致（`SvgLineCap` 返回 PascalCase，`SvgLineJoin` 返回属性名小写）

- **位置**：`f_svg/src/SvgShape.cj:36-42`（`SvgLineCap.toString` → `"Butt"`）、`82-84`（`SvgLineJoin.toString` → `attrName()`，即 `"miter"`）、`121-126`（`SvgFillRule.toString` → `"Nonzero"`）
- **来源**：存量（`519058f67`，2026-11-07）
- **判据**：review-checklist §10（可读性/一致性）/ §11（语义与命名不符）
- **证据**：静态确定 —— 三个枚举的 `toString` 分别返回 PascalCase、小写属性名、PascalCase；而写入属性时用的是 `attrName()`（`215`、`227`、`290`），序列化属性值统一走小写。
- **描述**：`SvgLineJoin.toString()` 的注释自称「与 `attrName()` 一致的规范字符串」，另外两个枚举没有同样处理；把 `SvgLineCap.toString()` 结果直接写进 `stroke-linecap` 属性虽然仍能被 `fromName` 小写化匹配，但与其他枚举的用法不对称，容易在序列化层写出 `Butt` 这类非标准值。
- **建议**：统一为两种风格之一：要么三个枚举 `toString` 全返回属性名（并同步 `SvgLineJoin` 注释），要么全返回类型名并把 `attrName()` 明确为唯一序列化入口；并在文档里写清哪个用于序列化。

### [轻微][存量] F13 `outlineContours` 缺 `width <= 0` 守卫，返回退化轮廓

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:57-78`
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §11（同一 API 系列的边界处理不对称）
- **证据**：静态确定 —— `outlinePolyline:86-88` 与 `outlineElement:105-107` 都有 `style.width <= 0.0` 提前返回空数组；`outlineContours` 没有，`half = style.width / 2.0 = 0` 时 `outlineOne` 生成的四点四边形四个顶点重合，`addContour`（`359-364`）只检查 `size < 3`，仍会把它加入结果。
- **描述**：零宽描边经 `outlineContours` 得到一批零面积轮廓，调用方（`SvgRasterizer.stroke` 之外直接用 `outlineContours` 的外部代码）拿到非空结果却什么也画不出来；`SvgRasterizer` 自己在 `134` 处挡了零宽，所以仓内无可见后果。
- **建议**：与另外两个入口对齐，在 `outlineContours` 入口加 `style.width <= 0.0` 返回空数组。

### [轻微][存量] F14 `outlineElement` 无生产调用点，注释宣称的「解析路径」在渲染管线里从未走通

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:100-104`（注释与签名）
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §14.1（接线缺失）
- **证据**：静态确定 —— 全模块 grep `outlineElement` 只有 `SvgStrokeOutliner_test.cj:170,198,209` 三处调用；`SvgRenderer` 与 `SvgRasterizer` 的描边一律 `flattenPathData` + `SvgStrokeOutliner.outlineContours`（`SvgRasterizer.cj:150`、`254`，`SvgRenderer.cj:618`）。
- **描述**：rect/circle/ellipse/line 的解析轮廓快路径对外的公开能力确实可用（测试覆盖），但注释「rect / circle / ellipse / line 走解析路径」描述的加速在渲染器里并不存在——所有元素都被扁平化后走通用 outliner，读者会误以为渲染已享受该优化。
- **建议**：要么把 `outlineElement` 接进 `SvgRenderer` 的描边分支（先解析几何再决定是否用解析轮廓），要么把注释改成「供调用方自行选用的解析轮廓入口，渲染管线不调用」。

### [轻微][存量] F15 测试用例与阈值：M6 全套复制 M5 用例、快照路径字面量两份、大样本阈值比注释目标宽 200 倍、1M 元素用例复用同一实例

- **位置**：`f_svg/src/SvgSnapshotM6_test.cj:95-137`（复制 `SvgSnapshotM5_test.cj:106-135` 的三个用例与两份场景常量）；`f_svg/src/SvgScene_test.cj:22`（`SCENE_DIR`）与 `f_svg/src/SvgSnapshotM5_test.cj:23`（`M5_SNAPSHOT_DIR`）同值 `"testdata/render"`；`f_svg/src/SvgRoundTrip_test.cj:59-83`（注释目标 25 ms / 20 ms，断言 `< 5_000.0`）；`f_svg/src/SvgSecurity_test.cj:245-256`（同一 `rect` 实例挂 1,000,000 次）
- **来源**：存量（各文件最后提交 2026-11-05 ~ 11-08）
- **判据**：review-checklist §2（测试中的重复复制）/ §11（断言强度不足、测试资源开销）
- **证据**：静态确定 —— `SvgSnapshotM5_test.m1ToM3SnapshotsExact` / `animationSnapshotsExact` / `m4SnapshotsExact` 与 `SvgSnapshotM6_test` 同名同体，同一批快照在一次 `cjpm test` 里被渲染两遍；`M1_TO_M3` 与 `M5_SCENES` 常量在两个类各写一份；`largeSampleSmoke` 注释写「解析 ≤ 25 ms、序列化 ≤ 20 ms」，实际断言 5000 ms；`elementCountAtDefaultLimit` 用同一个 `XmlElement` 反复 `children.add` 凑 1M 节点，而默认上限已由 `defaultLimits`（`260-268`）断言过。
- **描述**：快照套件重复执行使 CI 时长翻倍且两处常量容易只改一处；5 s 阈值等于没有回归门禁；1M 节点用例耗时与内存都不小，却只验证「默认值 1,000,000」这一个可由常量断言的性质，而且复用同一实例使树形不真实。
- **建议**：M6 只保留 M6 新增用例，历史快照回归交给一处；场景清单抽成共享 `internal` 常量；把大样本断言阈值按注释目标收紧或明确标注「仅冒烟」；元素数上限用例改为 `maxElements` 配小阈值（已有同类用例）或直接断言默认常量。

<!-- 第 23 部分 -->

### [严重][存量] `dotted` / `dashed` 装饰线的段数由 `text-decoration-thickness` 与字形 advance 之比决定，没有上界：一个属性值即可让渲染挂死并撑爆堆

- **位置**：`f_svg/src/SvgTextDecoration2.cj:182-189`（`Dotted`：`step = safeThickness * 2.0`，`while (x < width) { … x += step }`）、`f_svg/src/SvgTextDecoration2.cj:190-198`（`Dashed`：`x += dash + gap`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界增长 / 按不可信数值放大的循环」、§6.4「复杂度由外部参数放大」
- **证据**：静态确定 —— `safeThickness`（`:168`）只保证 `> 0`，没有下界；`thickness` 来自 `text-decoration-thickness`（`f_svg/src/SvgTextRenderer.cj:946-967`，同样只校验 `isFiniteSvgNumber(value) && value > 0.0`）；`width` 是该字形的 `advance`（`SvgTextRenderer.cj:851-857`，随 `font-size` 线性）。迭代次数 = `advance / (2 · thickness)`，每轮还追加 5 条 `SvgPathCommand`（`SvgTextDecoration2.cj:219-236`）
- **描述**：`<text font-size="10" text-decoration="underline" style="text-decoration-style:dotted;text-decoration-thickness:0.0000001px">A</text>` 让单个字形的迭代次数达到 `5 / 2e-7 = 2.5e7`，即 1.25 亿条路径命令：先是内存暴涨（每条命令一个 `Array<Float64>`），再是长时间占用 CPU；把厚度再缩小两个数量级就是事实上的挂死。同一份 SVG 里放 10 个这样的元素即可拖垮进程。触发不需要任何越权，只要渲染外部 SVG 就成立（`SvgRenderer.render` 对输入不做厚度下限校验）。`Dotted` 与 `Dashed` 是同源问题，两处都在
- **建议**：在 `appendSvgDecorationSegments` 入口把厚度钳到与字号相关的下界（如 `max(thickness, fontSize / 100)`，需要把 `fontSize` 传进来），并对段数设硬上限（`let maxSegments = 256`，超限退化为 `Solid` 或直接截断并记一次 warning）；`svgDecorationThicknessPx` 侧也补同一条下限，避免两个调用点各写一套

### [一般][存量] 无样式树时 `text-underline-position` 的继承被静默丢弃：既不沿用已继承的计算值，也不像另外四个属性那样向上找最近声明

- **位置**：`f_svg/src/SvgTextDecoration2.cj:255`（`var underlinePosition = style.textUnderlinePosition()`）、`f_svg/src/SvgTextDecoration2.cj:356-362`（`if (first) { underlinePosition = match (node.attr("text-underline-position")) { Some → … ?? Auto; None → Auto } }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与注释不符」「边界 / 空值未处理」；同函数注释 `f_svg/src/SvgTextDecoration2.cj:238-241` 明确写着「`text-underline-position` 直接读取已继承的计算值」
- **证据**：静态确定 —— 进入 `styles.isNone()` 分支且 `first == true` 时，无论元素有没有该属性都会重新赋值：有属性就解析，没有就写死 `Auto`。`:255` 读到的继承值在 `None` 分支被覆盖；循环体在 `first == false` 时不再读该属性，所以祖先元素上的声明同样看不到。属性表本身就把它标成继承属性（`f_svg/src/SvgComputedStyle.cj:150`，`SvgPropertySpec("text-underline-position", true, "auto")` 的第二参 `true`）
- **描述**：`<g text-underline-position="under"><text text-decoration="underline">A</text></g>` 走 `decorationOutline(text, style: …)`（`styles` 默认 `None`，`f_svg/src/SvgTextRenderer.cj:899-904`）时，下划线位置会从 `under` 退化成 `Auto`，线与字形的间距随之改变。同一份规格在渲染器的另一条路径上行为不同：`svgDecorationSpecFromAttributes`（`SvgTextRenderer.cj:1008` 取 `parent.underlinePosition`、`:1040-1044` 仅在子元素显式声明时覆盖），说明这里不是「有意如此」，而是两条实现漂移
- **建议**：`if (first)` 分支只在 `attr` 命中时覆盖（`case None => ()`），保留 `style.textUnderlinePosition()`；若确实要按属性走，就把该属性并入上方的 `have*` 机制，与其他四个属性共用「最近声明祖先」逻辑

### [一般][存量] `text-decoration` 有两套解析实现，public 的严格版与模块实际使用的宽松版语义已漂移

- **位置**：`f_svg/src/SvgTextDecoration.cj:70-117`（`SvgTextDecoration.tryParse`，严格）、`f_svg/src/SvgComputedStyle.cj:635-658`（`parseSvgDecorationLines`，宽松）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「重复逻辑导致的行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— 两者都是「按空白切 token → 映射 underline/overline/line-through」，差异可逐条列出：① 未知 token：严格版 `:104` 直接 `return None`，宽松版 `:651` 忽略；② `none` 与其它值并存：严格版 `:107-112` 返回 `None`，宽松版只认整串等于 `"none"`（`:640`），`"none underline"` 得到 `underline`；③ 分隔符：严格版认空格与逗号（`:83`、`:90` 的 `b','`），宽松版走 `splitCssWhitespaceWords`（`f_svg/src/CssSelector2.cj:889-906`，只按 CSS 空白切，不认逗号）；空白集合本身也不同（严格版用 `isSvgSpace`，`f_svg/src/SvgNumber.cj:68-70`；宽松版用 `isCssSpace`，`f_svg/src/CssLexer.cj:220-222`，多一个 `0x0C`）。模块内部（`:301`、`:310` 的属性回退、`SvgComputedStyle.textDecoration()`）全部走宽松版，严格版只有 `SvgValueTypesM4_test.cj:72-84` 在用
- **描述**：对外导出的 `SvgTextDecoration.tryParse("underline dotted")` 返回 `None`，而同一个库渲染 `text-decoration="underline dotted"` 时按 `underline` 处理；调用方若用 public API 校验属性值，会与渲染结果不一致。两套实现各自维护 token 表，后续加关键字（如 `spelling-error`）必然只改一处
- **建议**：保留宽松版为唯一扫描实现（关键字表提成 `const` 数组），严格版改为「先 `parseSvgDecorationLines`，再校验 token 全部被消费」的薄包装；两处空白集合统一到 `isCssSpace`（CSS 语义更完整），避免 SVG/CSS 两条分词口径分叉

### [一般][存量] `SvgTextPathLayout.place` 不可重入：`warnings` / `pathEmpty` / `stretchScale` 是实例可变状态，既不清理也不加锁

- **位置**：`f_svg/src/SvgTextPathLayout.cj:55`（`public let warnings`）、`:57`（`internal var pathEmpty`）、`:59`（`internal var stretchScale`）、`:74-75`（`place` 只重置自身两个字段，不清 `warnings`）、`:84` / `:168`（`warnings.add`）、`:101`（`stretchScale = factor`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护」「发布逸出」，§5「无界容器」
- **证据**：静态确定 —— `place` 无任何同步，且 `stretchScale` 要在 `place` 返回之后由调用方读取（`SvgTextRenderer.cj:705` `glyphScaleX = scaleX * pathLayout.stretchScale`、`:711` `pathLayout.pathEmpty`），即「先写后读」跨两次访问；`warnings` 从不清空。仓内每次 `layout` 都 `SvgTextPathLayout()` 新建（`SvgTextRenderer.cj:662`），所以本仓不触发；触发条件是外部把同一个实例复用于多次/多线程排版
- **描述**：public 类暴露可变状态却把「正确性」寄托在调用方每次新建实例上：① 复用同一实例排两段文本，第二段的 `warnings` 会带走第一段的告警（重复上报，长生命周期实例上无界增长）；② 两个线程同时 `place` 时，A 读到的 `stretchScale` 可能来自 B 的 `stretch` 计算，字形被错误缩放，`pathEmpty` 也可能被覆盖成另一条路径的状态。证据等级：竞争本身静态确定，是否存在这样的调用方为 `待确认`（本仓无）
- **建议**：把 `warnings` / `pathEmpty` / `stretchScale` 收进 `place` 的返回值（新增 `SvgTextPathLayoutResult { placements, warnings, pathEmpty, stretchScale }`），让类本身无状态；若要保留现有签名，至少在 `place` 入口 `warnings.clear()`，并在类注释里写明「非线程安全，不可多线程复用」

### [轻微][存量] `SvgDecorationStyle.none()` 全仓零引用

- **位置**：`f_svg/src/SvgTextDecoration2.cj:117-119`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal class` 的静态方法，非 public 顶层声明，全项目搜引用）
- **证据**：静态确定 —— 全仓 grep `SvgDecorationStyle` 只命中定义处、`resolveSvgDecorationStyle` 的构造（`:367`）与 `SvgTextRenderer` 的字段/构造，没有任何 `SvgDecorationStyle.none()` 调用；`SvgDecorationStyle` 是 `internal class`（`:96`），成员对外不可达
- **描述**：与 `SvgTextDecoration.none`（struct 静态值，被广泛使用）重名但用途不同的空实现残留，容易让人误以为装饰规格有统一的「none」入口。建议删除，或让 `SvgTextRenderer` 的默认值改用它以消除重复
- **建议**：删除该方法；若保留，把 `SvgTextRenderer.cj:63` / `:179` 的 `SvgDecorationStyle(lines: decoration)` 改为经过它构造

### [轻微][存量] `SvgDecorationStyle` 与 `SvgTextDecorationSpec` 是字段逐项相同的双表示

- **位置**：`f_svg/src/SvgTextDecoration2.cj:96-120`（internal，5 个 `let` + 同一组默认值）与 `f_svg/src/SvgTextDecoration2.cj:123-157`（public，同样 5 个 `let` + 同一组默认值，仅多一个 `toString`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名」的重复表示
- **证据**：静态确定 —— 两个构造函数的 5 个具名参数、默认值、赋值顺序逐行对应；`SvgTextDecorationSpec` 只由 `SvgComputedStyle.textDecorationSpec()`（`f_svg/src/SvgComputedStyle.cj:537-539`）产出，渲染链路实际消费的是 `SvgDecorationStyle`（`SvgTextRenderer.cj:38`、`:200`）
- **描述**：新增一个装饰属性（例如 `text-decoration-skip-ink`）要同时改两个类型、两个构造、两个默认值，漂移几乎必然。目前 public 版本只产出不被内部消费，属于「对外契约与内部模型并行」
- **建议**：让 `SvgTextDecorationSpec` 成为唯一表示（把 `SvgDecorationStyle` 换成 `type` 别名或直接复用），或给 `SvgTextDecorationSpec` 增加 `toStyle()` 并让 `SvgComputedStyle.textDecorationSpec()` 之外只保留一条路径

### [轻微][存量] 「是否声明了装饰属性」判定与属性名清单两处各写一遍，判定口径已不同

- **位置**：`f_svg/src/SvgTextDecoration2.cj:377-385`（`svgDecorationDeclares`，专用名 `text-underline-position` 返回 `false`）与 `f_svg/src/SvgTextRenderer.cj:984-997`（`svgDecorationStyleDeclared`，5 个名字统一判断，含 `text-underline-position`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「字面量复制（同一组属性名散落多处）」
- **证据**：静态确定 —— 两处都硬编码 `text-decoration-line/-style/-color/-thickness`（+ `text-decoration` 简写），第三份同类清单在 `f_svg/src/SvgComputedStyle.cj:146-150` 的属性表；`svgDecorationDeclares` 对 `text-underline-position` 特判返回 `false`，另一份不含该特判
- **描述**：三份清单靠人工同步；`text-underline-position` 的差异已经让两条路径对「是否声明」给出不同答案（配合上面第 2 条，就是继承丢失的另一半原因）
- **建议**：在 `SvgComputedStyle` 侧导出一个 `static let DECORATION_PROPERTIES: Array<String>`（含简写），两处判定改为遍历它；`text-underline-position` 的特殊性用参数表达（`includeUnderlinePosition!: Bool`）

### [轻微][存量] `offset()` 用 `0.0 * fontSize` 表达「无偏移」，`fontSize` 非有限时把 0 变成 NaN

- **位置**：`f_svg/src/SvgTextBaseline.cj:231`（`case Auto | Alphabetic => 0.0 * fontSize`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界 / 浮点」、可读性（无意义的乘法）
- **证据**：静态确定 —— `0.0 * Infinity = NaN`、`0.0 * NaN = NaN`；调用链 `baselineOffsetFor`（`f_svg/src/SvgTextRenderer.cj:1073-1097`）把结果直接加进字形 `y`，没有 `isFinite` 兜底
- **描述**：`font-size="1e400"` 之类的属性值如果被解析成 `Infinity`（`SvgLength.tryParse` 未做上限校验），字形 `y` 变成 `NaN`，整段文本静默消失且无 warning。写成 `0.0` 既不影响正常路径，也避免这条 NaN 通道
- **建议**：直接返回 `0.0`；若想保留「随字号缩放」的表达，改成 `0.0`（这两个基线本就不依赖字号），或在 `SvgLength` 解析层统一拒绝非有限值

### [轻微][存量] 三处测试断言偏弱或直接下标取字形，失败时报越界 panic 而不是断言失败

- **位置**：`f_svg/src/SvgTextLayoutCacheM4_test.cj:103`（`@Assert(decoratedCalls * 2 <= plainCalls * 3)`）、`f_svg/src/SvgTextBaselineM4_test.cj:52`、`:128`、`:142`、`:151`、`:155`（`layout.glyphs[0]`）、`f_svg/src/SvgTextPathLengthM6_test.cj:56`（`document.elementsByTag("text")[0]`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「可测试性」、§11「边界（空集合）」
- **证据**：静态确定 —— `plainCalls` 恒为 1，`2 * decorated ≤ 3` 允许 1.5× 放大，与用例名「不得放大布局次数」的意图不符；`glyphs` 为空时 `[0]` 抛越界，测试报错信息里看不到期望值
- **描述**：布局次数回归到 1.5× 也能通过；字形未生成时（例如 textPath 全部被截断）测试以 panic 中断，定位成本高于 `@Assert(glyphs.size == n)`。这些不影响产品质量，但会削弱本模块最关键的「装饰线不放大布局」与「textPath 落位」回归网
- **建议**：`@Assert(decoratedCalls == plainCalls)`；用 `@Assert(layout.glyphs.size > 0)` 或 `@Expect` 先断言规模再取下标

<!-- 第 24 部分 -->

### [严重][存量] `discard` 无 href 时 `sample()` 直接改源文档，跨帧丢元素

- **位置**：`f_svg/src/SvgTimeline.cj:249-267`（`applyDiscards`，关键行 `:253` `case None => element.parent`、`:259-262` `parent.children.removeIf(...)`、`:263` `element.parent = None`；`discards` 采集自源文档 `:167`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源/状态不对称、契约与实现不符）、§12.1（发布可变状态）；对照类注释 `SvgTimeline.cj:146`「`sample` 深拷贝文档后在副本上求值…原文档不被修改」
- **证据**：静态确定 —— `init` 把 `document.root` 里的 `discard` 元素收进 `this.discards`（`:167`），`applyDiscards` 遍历的仍是这批**源文档**元素；`readSvgHref` 返回 `None` 时分枝取 `element.parent`，得到的 `parent` 属于源文档，随后 `parent.children.removeIf` 与 `element.parent = None` 全部作用在源树上。快照分支（href 存在）才取 `snapshot.elementById`
- **描述**：`<g><discard begin="1s"/><rect/></g>` 这类（合法，`SvgDiscardM6_test.cj:48` 也把「无 href 的 discard」当受支持输入）文档在 `t ≥ 1` 后会被 `sample()` 从**调用方文档**里删掉整棵 `g`，并把该元素的 `parent` 置空。后果：① 违反 `sample` 的「不改原文档」契约；② 第二次 `sample(0.0)` 拿到的快照也缺这个元素（源树已被破坏），时间轴不再可回放；③ 同一实例的 `sample` 变成有副作用的不可重入操作
- **建议**：`case None =>` 分支改用快照侧定位（`snapshot.elementById(spec/元素 id)` 或按 `elementPath()` 在 `snapshot` 上找同名兄弟），删除目标时只操作 `snapshot` 的 `children`；`svgDiscardNestingDepth` 也应在快照树上算。补一条「无 href 的嵌套 discard 连续采样两次」用例

### [一般][存量] `repeatDur` 被 `repeatCount`/`dur` 为 `indefinite` 的早退覆盖，活动时长永不结束

- **位置**：`f_svg/src/SvgTimeline.cj:116-128`（`totalDuration`，`dur` 早退 `:117-119`、`repeatCount` 早退 `:124-126`）；同一逻辑复制在 `:768`（`animationStateAt`）
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）、§2（同一判定两处各写一遍）
- **证据**：静态确定 —— 代码先按 `min(repeatDur, dur*repeatCount)` 算出 `total`（`:120-123`），紧接着 `if (isInfSvg(this.repeatCount)) { return Float64.Inf }` 把刚被 `repeatDur` 截断的结果丢弃；`dur` 为 `indefinite` 时 `:117` 更早返回 `Inf`
- **描述**：`dur="1s" repeatCount="indefinite" repeatDur="10s"` 的 SMIL 语义是活动期 10s，实现返回 `Inf` ⇒ 动画永不结束、`freeze` 永不生效、`duration()`（`:191-199` 跳过 `Inf`）返回 0，播放器无法确定总时长
- **建议**：先判 `repeatDur` 是否有限（有限则 `total = repeatDur` 并直接返回），再判 `repeatCount`/`dur` 是否无限；把 `:768` 的重复计算改为调用 `totalDuration()`

### [一般][存量] 长度单位换算四处各写一遍，`em`/`ex`/`dpi` 基准互相矛盾

- **位置**：`f_svg/src/SvgTextRenderer.cj:946-967`（`svgDecorationThicknessPx`）；`f_svg/src/SvgTransformOrigin.cj:132-151`（`resolveOriginComponent`）；对照既有公共实现 `f_svg/src/SvgLength.cj:205-226`（`toUserUnits` + `SvgLengthContext.dpi/fontSize`）与 `f_svg/src/SvgStyleResolver.cj:958-964`（`resolveFontRelativeLength`）
- **来源**：存量
- **判据**：review-checklist §2（换算复制、只改类型名的重复实现）、§11（语义与规格不符）
- **证据**：静态确定 —— `toUserUnits` 用 `context.dpi`（默认 96，可配）与 `context.fontSize`；`svgDecorationThicknessPx` 把 `In/Cm/Mm/Pt/Pc` 硬编码成 `96.0`、`Ex` 用 `fontSize/2`；`resolveOriginComponent` 却用 `Em → 16.0`、`Ex → 8.0` 固定值
- **描述**：`transform-origin="1em 1em"` 在 `font-size: 40` 的元素上应得到 (40,40)，实现固定得到 (16,16)，旋转中心偏移；同时 `text-decoration-thickness: 1in` 在配置了非 96 dpi 的渲染上下文里与其它长度属性不一致（同一文档两种物理单位口径）
- **建议**：统一走 `toUserUnits`：`effectiveElementTransform` 增补 `fontSize`/`dpi`（可从 `style.fontSize().value` 与渲染选项取），`svgDecorationThicknessPx` 改用 `toUserUnits(length, Horizontal, SvgLengthContext(...))`；两处删掉手写 `match (length.unit)`

### [一般][存量] `x` 与 `dx` 同时出现时 `dx` 被丢弃

- **位置**：`f_svg/src/SvgTextRenderer.cj:561-575`（`match (char.xOverride) { case Some(value) => pen = value … }`）；`dx` 的写入点 `:1250-1261`（tspan）、`:1337-1348`（根 `dx` 列表）
- **来源**：存量
- **判据**：review-checklist §11（边界/语义与 SVG 文本定位规则不符）
- **证据**：静态确定 —— `xOverride` 命中时把 `pen` 直接赋值为 `x`，`char.dx` 完全不参与；而 `dx` 已在 `:1252`/`:1339` 累加进 `char.dx`
- **描述**：SVG 中 `dx` 是在 `x` 建立的当前位置上再偏移（`<text x="10" dx="5">` 应落在 15），实现落在 10。`tspan` 上「x 列表 + dx」的组合同样失效，且无测试覆盖该组合（`SvgTextRenderer_test.cj:60-112` 只测了纯 `x` 与纯 `dx`）
- **建议**：`case Some(value) => pen = value + char.dx`（`x` 为绝对基准，`dx` 叠加），并补 `x`+`dx` 组合用例

### [一般][存量] warning 无去重、无上限：逐帧/逐字符/每次缓存重放都追加

- **位置**：`f_svg/src/SvgTimeline.cj:232`（`applyDiscards` 每次 `sample` 都 `warnings.add`）；`f_svg/src/SvgTextRenderer.cj:2027`（`applyFontSizeAdjust` 在逐字循环内 `add`）、`:444-446`（每个缺字体字符 `add`）、`:329-331`（布局缓存命中时把同一批 warning 再复制一遍）
- **来源**：存量
- **判据**：review-checklist §5（无界容器随请求增长）、§2（同一文案重复产生）
- **证据**：静态确定 —— 均为 `ArrayList<String>` 无容量上限、无 `contains` 去重、无 `clear`；`SvgTimeline.warnings`（`:150`，`public let`）随 `sample()` 调用次数单调增长
- **描述**：60 fps 驱动同一个 `SvgTimeline` 时，每条命中分支的 warning 每帧 +1（约 1 条字符串/帧/规格 ≈ 6 KB/s，一小时约 20 MB，且永不回收）；文本侧每次 `layout` 对同一字符重复 `add`（`hasDecoration` + `decorationOutline` + `outline` 会各走一次 layout，缓存命中还会重放一遍），同一条告警在一次渲染里出现 3–4 次，日志噪声大
- **建议**：warning 收敛为「去重集合」或在 `sample` 起始处清空本帧告警；循环内告警按「元素 + 属性」聚合成一条（带上计数）；`layout` 缓存命中只回放尚未见过的条目

### [一般][存量] `begin`/`end` 引用解析无深度上限，链长由文档决定

- **位置**：`f_svg/src/SvgTimeline.cj:709-752`（`resolveAnimationTime` 自递归 `:733-737`），调用点 `:175-187`
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入决定）
- **证据**：静态确定 —— 递归深度 = `begin="a.end"` 链长度，`visiting` 只做环检测、不做层数限制；同文件的 `mpath` 解析（`:668`）显式 `depth > 64` 抛 `SvgErrorKind.Limit`，此处没有对应保护
- **描述**：一份含 N 个 `animate` 元素、`begin` 互指成链（无环）的文档，构造 `SvgTimeline` 时递归 N 层；N 只受文档元素数限制（解析期 `maxDepth` 限的是树深，不限兄弟数量），足够大时构造期栈溢出
- **建议**：加 `depth` 参数并在超过常量（与 `mpath` 的 64 对齐）时抛 `Limit`；或改显式栈迭代

### [一般][存量] `textPath` 只识别直接子元素，嵌在 `tspan` 内时静默降级为直线排版

- **位置**：`f_svg/src/SvgTextRenderer.cj:1497-1513`（`findTextPathElement`），调用点 `:387`
- **来源**：存量
- **判据**：review-checklist §11（能力与规范不符）、§14.1（只做了一半的分支）
- **证据**：静态确定 —— 只检查 `text` 自身与 `text.children` 一层；`SvgTextPath <: SvgTextElement`（`SvgTextPath.cj:159`）、`SvgTspan <: SvgTextElement`（`SvgTspan.cj:19`），SVG 允许 `textPath` 作为 `tspan` 的内容子元素
- **描述**：`<text><tspan><textPath href="#p">A</textPath></tspan></text>` 中字形仍被 `collectSvgTextChars` 收集（`:1124` 起按 `SvgTextElement` 递归），但路径几何完全被忽略，输出为普通水平文本，且**没有任何 warning**，使用者无从发现
- **建议**：`findTextPathElement` 改为深度优先遍历（带深度上限），命中后统一走 `:649` 的 textPath 分支；或至少在未命中但子树中存在 `textPath` 时给出 warning

### [轻微][存量] `SvgAnimationSpec.target` 写了不读

- **位置**：`f_svg/src/SvgTimeline.cj:29`（字段声明）、`:85`（唯一赋值点）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— `SvgAnimationSpec` 为 `private class`，全仓仅本文件可见；`spec.target` 在 `SvgTimeline.cj` 内除 `:85` 赋值外无读取（`:205/:295/:303` 读的是 `targetId`/`targetPath`）
- **描述**：死字段，保留只会让读者误以为运行期还持有目标元素引用（实际目标每次 `sample` 都重新在快照里解析）
- **建议**：删除字段，构造参数只用于派生 `targetId`/`targetPath`

### [轻微][存量] 字形缓存键缺实际命中的字体面（`font-stretch`）

- **位置**：`f_svg/src/SvgTextRenderer.cj:925-942`（键构造在 `:926`）
- **来源**：存量
- **判据**：review-checklist §11（缓存键与取值来源不匹配）
- **证据**：静态确定（键内容）＋待确认（是否真的命中不同面）——键为 `family|weight|style|fontSize|codePoint`，而字形来自 `registry.resolveDetailed(..., stretch: char.stretch)` 返回的具体 `font`；同一 `family/weight/style` 下不同 `stretch` 会解析到不同面
- **描述**：`<text font-stretch="normal">A<tspan font-stretch="condensed">A</tspan></text>` 在同一 text 内会让第二个 `A` 复用第一个面的轮廓，再被 `applyFontStretchSynthesis`（`:1946-1968`）二次缩放，宽度与形状都对不上；默认字体注册表只有单一面时观察不到
- **建议**：键里加上 `char.matchedStretch`（或 `font` 的稳定标识）；补一条多 `font-stretch` 面的用例

### [轻微][存量] 布局缓存键只含样式树 `version`，不含样式树身份

- **位置**：`f_svg/src/SvgTextRenderer.cj:320-347`（键构造 `:326`）
- **来源**：存量
- **判据**：review-checklist §11（缓存键不足导致的错误命中）
- **证据**：待确认 —— `SvgTextLayoutCache` 由 `SvgDisplayList` 持有并被多次 `SvgGeometry.renderBounds/renderClipBounds` 复用（`SvgGeometry.cj:125`、`:150`）；键 `text.identity|styleTree.version|rootIdentity` 在「同一文本元素、换了一棵样式树但 `version` 相同（新树从 0 开始）」时会命中旧条目。仓内当前调用点都是「一次渲染一棵树」，故未观察到实际错配
- **描述**：键缺少样式树对象身份，属于潜在的跨树误命中面；一旦上游改成「复用 cache + 重建样式树」，排版结果会静默错误
- **建议**：键里加入样式树的对象标识（或 `SvgComputedStyleTree` 全局自增 id），与 `text.identity` 同源生成

### [轻微][存量] 竖排 `direction: rtl` 时列的 `x` 被重排，显式 `x` 不再按绝对坐标生效

- **位置**：`f_svg/src/SvgTextRenderer.cj:617-635`（`visualIndex` / `columnPositions.add(sortedColumns[visualIndex])`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/文档不符）
- **证据**：待确认 —— 代码不用字符自身的 `xOverride`（`key`），而用 `sortedColumns[visualIndex]`；`rtlColumns` 时 `visualIndex = size-1-rank`，于是 `x=20` 的字符被放到 `x=10`。`SvgTextWritingModeM4_test.cj:62-79` 只覆盖默认 `ltr`
- **描述**：若「显式 `x` 是绝对坐标」是契约，则 rtl 竖排会把两列的 x 互换；若「`x` 表示列序」是有意设计，则与 `columnPositions` 命名及 LTR 行为不一致。缺少规格与用例，无法定论
- **建议**：二选一并写进注释：绝对坐标 → 用 `key`；列序 → 明确「rtl 时 `x` 只用于确定列序」，并补两条方向的断言

### [轻微][存量] 只改类型名的重复实现（`permuteBidi*` ×3、`max*` ×2）

- **位置**：`f_svg/src/SvgTextRenderer.cj:1715-1746`（`permuteBidiValues<T>` / `permuteBidiOptionalPaths` / `permuteBidiFonts` 函数体逐行相同，只有 `ArrayList<T>` 元素类型不同）；`f_svg/src/SvgTimeline.cj:921-923`（`maxAnimationNumberSize`）与 `:1213-1215`（`maxFloat`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 三个 `permute` 的输入-输出-副作用完全一致：按 `order` 重建 `ArrayList`；泛型版本 `permuteBidiValues<T>` 已可承载 `?SvgPathData` 与 `Option<SvgFont>`
- **描述**：`:505`/`:508` 完全可以调用泛型版本，两处特化只增加维护面（改一处漏两处）；两个 `max` 同理
- **建议**：删除 `permuteBidiOptionalPaths`/`permuteBidiFonts`，改调 `permuteBidiValues`；`max*` 合并为一个泛型/一个具体类型（等价性由现有 `SvgTextBidi*_test` 与动画测试保证）

### [轻微][存量] 「均匀 keyTimes」同一段算法写了三遍

- **位置**：`f_svg/src/SvgTimeline.cj:947-951`（`effectiveKeyTimes`）、`:976-981`（`pacedKeyTimes` 的 `total <= 0` 回退）、`:1125-1129`（`resolveMotionProgress` 的 `keyPoints` 均匀分布）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/复制同一换算）
- **证据**：静态确定 —— 三处都是 `times[i] = Float64(i) / Float64(count - 1)`，仅容器不同
- **描述**：三份实现都隐含 `count > 1` 的前提，靠调用点各自保证；任一处被改动（例如改成 `count-1 == 0` 的保护）都会漂移
- **建议**：抽 `private func uniformSvgTimes(count: Int64): Array<Float64>`（内部处理 `count <= 1`），三处替换

<!-- 第 25 部分 -->

### [严重][存量] 复合字形展开无总量上限，单个字体可放大成数十亿条路径命令

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:651`（`parseCompositeGlyph`，组件循环 656–698，子字形展开 693–696）；配套上限只有 `SvgTrueTypeFont.cj:49`（单字形 10000 点）与 `:51`（复合深度 8）
- **来源**：存量（快照模式无基线；`git diff` 为空）
- **判据**：review-checklist §5（无界容器 / 按不可信结构放大、无拒绝路径）
- **证据**：静态确定 —— 上限维度只有「单字形点数 ≤ 10000」和「递归深度 ≤ 8」；复合字形本身对**组件数**与**累计命令数**没有任何上限。`while (more)` 只受 glyf 表长度约束（`SvgTrueTypeTables.cj:24` 允许 16 MiB），组件记录最小 6 字节（flags 2 + glyphIndex 2 + 两个 int8 参数 2），即约 2.7×10⁶ 个组件；每个组件都走 `this.parseGlyph(component, depth + 1)`（693）完整重解析子字形，再逐条 `transformTtfCommand` 追加到父级 `commands`（694–696，每条都新建 `ArrayList<Float64>` 与数组）。子字形可以就是那个 10000 点的简单字形，于是命令数 = 组件数 × 子字形命令数，量级 10⁸–10⁹，`SvgPathCommand`（含 `Array<Float64>`）每条数十字节 ⇒ 数十 GB，必然 OOM。`pathById` / `glyphPath` 随后还会用 `scaleTtfCommand` 再整份复制一次（431–439 / 459–471），峰值内存翻倍。
- **描述**：`SvgTrueTypeFont.load` 是面向外部字体文件的公开入口，字体是不可信输入。当前实现把「单字形」的资源上限当成整体上限，复合字形提供了数量级放大的通道；同一子字形被 N 个组件引用时也会被重解析 N 次（CPU 放大同源）。
- **建议**：在 `parseGlyph` 的递归入口按「单次 `glyphPath` 调用累计点数/命令数」计数（例如新增 `SVG_TTF_MAX_TOTAL_POINTS = 4 * SVG_TTF_MAX_POINTS`），超限抛 `SvgException(kind: Limit)`；或先用 glyf 表长度 / 6 估算组件数上限，超过即拒绝。若要保持零拷贝，可在 `parseCompositeGlyph` 内复用已解析子字形的命令缓存（同时消掉重复解析）。

### [一般][存量] `load` 整文件读入，没有文件级大小上限

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:330`（`load`）→ `:32`（`SvgFontFileAccess.read`，`File.readFrom(path)`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化；判据要求「上限写在哪里」）
- **证据**：静态确定 —— `read` 直接 `File.readFrom(path)` 取全量 `Array<Byte>`，`SvgTrueTypeFont.parse` 的校验全部在**读完之后**；唯一的尺寸上限是按表 16 MiB（`SvgTrueTypeTables.cj:24`），总计 7 张必需表 + 可选表可达百余 MiB，而文件本身无上限（几百 MB / GB 的 `.ttf` 会先整份进堆再报错）。峰值是否真的 OOM 需实测，属「拒绝路径缺失」而非推测。
- **建议**：`read` 前先取文件长度（`File` 元信息），超过配置上限（如 64 MiB）抛 `SvgException(kind: Limit)`；上限与 `SVG_TTF_MAX_TABLE_BYTES` 一起声明，避免两处魔数。

### [一般][存量] cmap 查表不守值域与「0 = 缺失」语义，坏字体在最坏时机抛异常

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:484`（`glyphIndex`）、`:500`（`idRangeOffset != 0` 分支）、`:486`（format 12 分支）；异常落点 `:526`（`parseGlyph` 越界抛 Syntax）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 契约与实现不符）、§14（错误处理时机）
- **证据**：静态确定 ——
  1. `idRangeOffset != 0` 时按 `positiveTtfMod(glyph + idDelta, 65536)` 回绕（500–506）。OpenType format 4 的约定是：字形数组取到 0 表示该码位缺失，不再叠加 `idDelta`；当前实现只要 `idDelta != 0` 就会把缺失码位映射到一个真实字形（错画字形）。`idDelta` 为 0 的常见字体不受影响，命中范围需实测。
  2. `parseGlyph` 对 `index >= glyphCount` 抛异常（526–528），但 cmap 产出未与 `glyphCount` 对齐：format 12 的 `startGlyph + codePoint - startChar`（486–491）可越界；越界点不在 `parse` 阶段暴露，而是等到**渲染该字符**时抛出。`SvgRenderer.render`（`SvgRenderer.cj:91`）与 `SvgRenderTree` / `SvgTextRenderer` 全链无 `catch`，一次坏映射会中断整份文档的渲染——而 `parse` 对 `loca` 非单调、表长截断都是加载期 fail-fast，两处策略不一致。
- **描述**：同一份坏字体，只渲染 ASCII 时正常、渲染到特定码位才崩，且崩在渲染而非加载。
- **建议**：`parseCmap` 结束时按 `glyphCount` 校验所有 format 4 段与 format 12 分组的上界（越界即 `Syntax`），或在 `glyphIndexOrZero` 对越界结果回退 0；`idRangeOffset` 分支先判 `glyph == 0` 再回绕。附带同类：`head.unitsPerEm` 只拒绝 0（`SvgTrueTypeFont.cj:214`），未按规范区间 16–16384 校验，`ascent/descent` 会被放大到无意义量级。

### [一般][存量] cmap 子表选择忽略 platform / encoding，`endCode` 未校验单调

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:722`（记录循环，只读 `subtableOffset`，未读 platformID / encodingID）、`:746`（`format 4 && chosenFormat == 0` 先到先得）、`:493`（查表依赖 endCode 升序）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/契约不符）、§13 无关（本部分无 `.md`）
- **证据**：静态确定 —— 循环变量只有 `subtableOffset`、`format`、`declaredLength`，`platformID`（record 起点）与 `encodingID`（record+2）从未读取，因此符号字体常用的 `(3,0)` 子表可能先于 `(3,1)` 被选中；`glyphIndex` 用 `if (codePoint > endCode) continue; if (codePoint < startCode) return None;`（493–499）依赖 endCode 升序，`parseCmap` 未校验该顺序，乱序时提前返回 `None` 或命中错误段。影响字体集合需实测（哪些字体同时含 (3,0)/(3,1) 子表、哪些 endCode 乱序）。
- **描述**：结果不是崩溃而是**静默错映射**（画错字形或缺字形），比抛异常更难发现。
- **建议**：优先级取 `(3,1)`/`(3,10)` 优先、`(0,x)` 次之，其余仅在没有更好候选时使用；解析时校验 `endCode[i] >= endCode[i-1]`，乱序即 `Syntax`。选择策略写进类注释，避免后续再按「第一个 format 4」理解。

### [一般][存量] `SvgVectorEffect2.apply` 的矩阵分解丢失镜像，且 `fixed-position` 覆盖前序修正

- **位置**：`f_svg/src/SvgVectorEffect2.cj:63`（`decomposeScale`，`sx = sqrt(a²+b²)`）、`:44`（non-scaling-size）、`:48`（non-rotation）、`:52`（fixed-position，`result = local`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 数值语义）、§10（正确性）
- **证据**：静态确定（第 1、3 点）+ 待确认（第 2 点：缺 SVG 2 `vector-effect` 组合语义条目）——
  1. `sqrt` 必为非负，`scale(-1, 1)` 这类镜像在 `non-rotation` 分支被还原成 `scale(1, 1)`，镜像丢失（元素被画成未镜像）。分解同时假设矩阵只有 rotate+scale：`skewX` 会把切变折进 `sy`（`sy = sqrt(c²+d²)`），得到近似而非精确结果。
  2. `fixed-position` 直接 `result = local`，把已算好的 non-scaling-size / non-rotation 修正整块丢弃；三项同时出现时只剩元素自身矩阵。是否符合组合语义需对照规格，代码注释只声明了顺序，没有说明覆盖是有意的。
- **建议**：用带符号的比例（`sx = a >= 0 ? len : -len`，或以 `determinant < 0` 判定翻转）保留镜像；QR 分解替代 `sqrt(c²+d²)` 以正确处理切变；`fixed-position` 与前三项的组合方式按规格明确后写进注释，并用一条 `scale(-1,1)` + `non-rotation` 的用例锁定行为。

### [一般][存量] 元素属性样板在 4 个元素类里逐字复制（`SvgUse` 整块 = `SvgImage`）

- **位置**：
  - `f_svg/src/SvgUse.cj:20`–`83`（4 个 `SvgValueCache` + `href` / `x` / `y` / `width` / `height`）与 `f_svg/src/SvgImage.cj:20`–`84` **逐行一致**，仅 `super(...)` 的 tag 不同；
  - `f_svg/src/SvgView.cj:29`–`47`（`viewBox`）与 `SvgPattern.cj:138`–`156`、`SvgMarker.cj:187`–`205` 逐行一致；
  - `f_svg/src/SvgView.cj:49`–`66`（非可选 `preserveAspectRatio`）与 `SvgPattern.cj:158`–`175`、`SvgMarker.cj:207`–`225`、`SvgFilterPrimitives2.cj:788`–`802` 逐行一致。
- **来源**：存量
- **判据**：review-checklist §2（跨文件字面量/结构复制，只改类名）
- **证据**：静态确定 —— 逐段比对函数体（get 的 cache key、`attr` 名、`tryParse*` 调用、`?? SvgPreserveAspectRatio.Default`、set 的 `setAttr`/`removeAttr` 分支）完全对齐，仅有类名与 tag 差异。
- **描述**：`SvgRoot.cj:119`–`157` 与 `SvgImage.cj:86`–`104` 是同一逻辑的**可选**变体，语义确有差异（`writeOptionalAttribute` 删属性 vs `setAttr` 恒写）。也就是说同一属性存在两种语义、五份实现：任一处修复（例如非法值记 warning、`viewBox` 宽高校验）都会漂移。
- **建议**：按仓内既有惯例（`SvgElement.cj:645`–`662` 的 `readSvgHref` / `writeSvgHref`）在 `SvgElement.cj` 增加 `readSvgViewBox` / `readSvgPreserveAspectRatio` / `writeSvgViewBox` / `writeSvgPreserveAspectRatio`（区分「删除」与「恒写」两个变体），四个元素类只保留 cache 字段与 prop 壳。`SvgUse` 与 `SvgImage` 的 4 个长度属性同样抽 `readSvgLengthProps` 一类的辅助或公共基类。

### [一般][存量] 字形 advance / 路径计算各有第二份实现，`scaleTtfCommand` 是 `transformTtfCommand` 的特例

- **位置**：
  - `f_svg/src/SvgTrueTypeFont.cj:424`（`advanceById`）与 `:441`（`advance`）：metricIndex + `hmtxReader.u16(metricIndex * 4)` + `* fontSize / unitsPerEm` 三行逐字相同；
  - `f_svg/src/SvgTrueTypeFont.cj:431`（`pathById`）与 `:459`（`glyphPath`）：`parseGlyph(gid, 0)` → 逐命令 `scaleTtfCommand` → `Some(SvgPathData(...))` 完全一致；
  - `f_svg/src/SvgTrueTypeFont.cj:993`（`scaleTtfCommand`）= `transformTtfCommand`（`:969`）取 `a = s, b = 0, c = 0, d = -s, dx = dy = 0` 的特例（两者都跳过 `ClosePath`、都按成对坐标重建数组）；
  - `f_svg/src/SvgTrueTypeFont.cj:244`–`258`（`parse` 内联的 loca 校验循环）与 `:511`（`locaAt`）重复「longLoca ? u32(i*4) : u16(i*2)*2」。
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/输入来源的重复实现）
- **证据**：静态确定 —— 上述四对函数体逐行比对，语义相同；差异点已逐个确认：`advance` 在 cmap 未命中时返回 `0.0`（444）而 `advanceById` 不做该判断；`glyphPath` 在 cmap 未命中时返回 `None`（460–463）而 `pathById` 恒 `Some`。
- **建议**：`glyphPath` 解析出 gid 后委托 `pathById`、`advance` 委托 `advanceById`（把「未命中返回 0/None」留在公开方法里），删除 `scaleTtfCommand` 改用 `transformTtfCommand(cmd, s, 0, 0, -s, 0, 0)`；`parse` 的 loca 校验循环改调 `locaAt`，让字节解码只有一处。

### [一般][存量] `vector-effect` 名称表在 4 处复制，其中 2 处靠 `toString()` 字符串分派

- **位置**：`f_svg/src/SvgVectorEffect.cj:64`（`toString` 的 5 个 `case`）、`:90`（`fromName` 的 5 个 `case`）、`f_svg/src/SvgVectorEffect2.cj:37`（`match (effect.toString())`）、`f_svg/src/SvgRenderTree.cj:1897`–`1906`（`match (effect.toString())` 过滤 `none` / `non-scaling-stroke`）
- **来源**：存量
- **判据**：review-checklist §2（同一张字面量表散落多处）、§11（语义与实现耦合）
- **证据**：静态确定 —— 五个规范名（`none` / `non-scaling-stroke` / `non-scaling-size` / `non-rotation` / `fixed-position`）在四处各写一遍；`SvgVectorEffect2.apply` 与 `svgApplyM6VectorEffects` 都靠「把值转回字符串再比较」来决定分支。`toString` 或规范名一旦调整（例如允许 `non-scaling-size` 的大小写变体），这两处会**静默失效**（`case _ => ()` 吞掉），编译器不会报错。
- **建议**：`SvgVectorEffect` 暴露 `internal prop ordinalValue: Int64`（或直接 `==` 与五个静态常量比较），`SvgVectorEffect2.apply` / `svgApplyM6VectorEffects` 改为值比较；`fromName` 与 `toString` 保留唯一一张表，可在类内用 `Array<String>` 常量表生成两个方向的映射。

### [轻微][存量] 同构实现可参数化：x/y delta 两段循环、GSUB 三次解析分支、`decompose` 双函数、π 字面量

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:599`–`637`（x delta 循环与 y delta 循环仅位掩码 `0x02/0x10` 与 `0x04/0x20` 不同、目标数组不同）、`:272`–`297`（`GSUB` 被 `table(...)` 查 4 次并各自 `parse` 一次：`liga` / `hlig` / `clig` / context）、`f_svg/src/SvgVectorEffect2.cj:58`/`:63`（`decompose` 与 `decomposeScale` 前两行相同，且 `decomposeScale` 返回的 `rotation` 只有一处调用、调用方用 `_` 丢弃）、`:59`/`:66`（硬编码 `3.141592653589793`，而 `SvgMatrix.cj:130` 用的是 `SVG_PI` 常量）
- **来源**：存量
- **判据**：review-checklist §2（近似重复 / 换算复制）、§1（读了不用）
- **证据**：静态确定 —— 上述四处逐行比对可复核；`decomposeScale` 的唯一调用点 `SvgVectorEffect2.cj:49` 用 `let (_, tx, ty, sx, sy)` 丢弃了首元素。
- **描述**：不构成行为缺陷，但同构代码各自演进会产生偏差（例如只给 x 分支加 `repeat` 校验）。
- **建议**：抽 `readTtfDeltas(flags, flagShort, flagSameOrPositive, count, reader)` 供两段复用；`SvgTrueTypeFont.parse` 里用一个 `parseGsubView(featureTag)` 局部函数收敛四次 `match (directory.table("GSUB"))`；`decomposeScale` 改名为 `decomposeWithScale` 并与 `decompose` 合并；π 用 `SvgMatrix` 暴露的常量或 `std.math` 的 `PI`。

### [轻微][存量] `SvgViewBox` 注释声明「宽高必须为正」，public init 不校验

- **位置**：`f_svg/src/SvgViewBox.cj:19`（注释）、`:26`（`public init`，无校验）、`:38`（`parse` 校验 `<= 0`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `parse` 对 `values[2] <= 0.0 || values[3] <= 0.0` 抛 `InvalidValue`（38–40），而 `SvgViewBox(0, 0, -1, 1)` 可以正常构造；`SvgViewport.forView`（`SvgViewport.cj:101`）会把它当合法 viewBox 生成负缩放矩阵（镜像），既不报错也不 warning。同样 `SvgViewBox(Float64.NaN, ...)` 可构造，`toString()`（44–47）在 `formatSvgNumber` 处才抛。
- **建议**：`init` 内校验宽高为正且四个值有限（用 `requireFinite`），错误文案与 `parse` 共用；若有意允许程序化构造越界视口，则把注释改成「`parse` 要求宽高为正」并说明构造不校验。

### [轻微][存量] `SvgVectorEffect.toString` 的兜底分支不可达

- **位置**：`f_svg/src/SvgVectorEffect.cj:70`（`case _ => "none"`）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支 / 不可达 case）
- **证据**：静态确定 —— `ordinal` 是 `private let`（27），唯一构造器 `private init`（29）只被 5 个静态属性以 0–4 调用（33–57），类内无其它写入点，故 `match (this.ordinal)` 的 0–4 已穷尽。
- **建议**：删除兜底分支（或在 `case _` 内 `throw SvgException(kind: InvalidValue)`），让新增取值时编译期暴露漏改；若保留，注释写明「防御不可达」。

### [轻微][存量] 文件名 / 类名 / 测试文件名不一致

- **位置**：`f_svg/src/SvgViewState2.cj:19`（文件带 `2` 后缀，内含 `SvgViewState`）、`f_svg/src/SvgVectorEffect2.cj:21`（公共类型名带数字后缀）、`f_svg/src/SvgUse_test.cj:50`（`SvgUse_test.cj` 内定义 `SvgImage_test`）
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 可维护性）；与模块内「一文件一主类型、文件与类同名」的既有惯例不符（如 `SvgViewBox.cj`、`SvgUse.cj`）
- **证据**：静态确定 —— `grep -rn "SvgViewState"` 只有 `SvgViewState2.cj` 一处定义，说明 `2` 是重命名残留；`SvgImage_test` 的用例（50–83）与 `SvgUse_test` 无关。
- **建议**：`SvgViewState2.cj` → `SvgViewState.cj`；`SvgVectorEffect2` 若确为「矩阵修正」职责，改名为 `SvgVectorEffectTransform`（README `f_svg/README.md:650` 与 `README_en.md:661` 同步）；`SvgImage_test` 移到 `SvgImage_test.cj` 或 `SvgElementApiM4_test.cj`。

### [轻微][存量] README 符号索引与本部分实现不一致（含测试专用成员）

- **位置**：`f_svg/README.md:559`（模块级清单列出 `public static func count(): Int64`、`public static func reset(): Unit`）、`:647`（`SvgTrueTypeFont` 成员缺 `unitsPerEm`）、`:649`（`SvgVectorEffect` 缺 `NoEffect`）、`:651`（`SvgViewBox` 只列 `minX` / `minY`）；`README_en.md:570` / `:661` 同源
- **来源**：存量
- **判据**：review-checklist §13（文档与代码不符）、§14（公开 API 未覆盖 / 文档写出不存在的 API）
- **证据**：静态确定 ——
  1. `count()` / `reset()` 是 `SvgTrueTypeFont.cj:37`–`45` 上带 `@When[test]` 的成员，且宿主 `SvgFontFileAccess` 是 `internal class`（29）；release 构建里不存在，README 却把它们列进「模块级」公共符号。
  2. 源码可见的公共成员 README 未列：`SvgTrueTypeFont.unitsPerEm`（163）、`SvgVectorEffect.NoEffect`（33）、`SvgViewBox.width`/`height`（23–24）/ `parse`（33）/ `toString`（44）；`SvgView`（`viewBox`/`preserveAspectRatio`/`viewTarget`）、`SvgUse`、`SvgTspan` 在索引里只有第 559 行的类型名，没有任何成员段。
- **描述**：按文档检索 `unitsPerEm` / `NoEffect` 会落空，按文档调用 `count()` 会在 release 构建里链接失败。
- **建议**：符号索引按 `src/` 的 public 声明重新生成并排除 `@When[test]` 成员；若索引是脚本产物，修脚本而不是手改（否则下次再漂移）。

### [轻微][存量] `hlig` / `clig` 的解析 warning 被丢弃，与 `liga` 不对称

- **位置**：`f_svg/src/SvgTrueTypeFont.cj:278`–`282`（`hligatures`）、`:285`–`291`（`cligatures`）传入 `ArrayList<String>()`；对比 `:272`–`275`（`ligatures` 传入 `layoutWarnings`）
- **来源**：存量
- **判据**：review-checklist §3（静默吞掉诊断）、§11（错误处理不对称）
- **证据**：静态确定 —— 三处 `SvgGsubLigatures.parse` 的 `warnings` 实参不同：`layoutWarnings` 会被 `SvgTrueTypeFont` 之外看到（经 `parse` 的调用方），另两处新建空 `ArrayList` 后直接丢弃，`hlig` / `clig` 表里的畸形子表不会产生任何提示。
- **描述**：同一张 GSUB 表按特性解析 3 次，只有其中 1 次可观测。
- **建议**：两处改为复用 `layoutWarnings`（文案由 `featureTag` 区分），或在 `parse` 注释中明确「hlig/clig 诊断有意静默」并说明理由。

<!-- 第 26 部分 -->

### [一般][存量] `xlink` 归一化白名单只覆盖 5 种引用元素，`pattern` / `filter` / `feImage` / `mpath` / `a` 的裸 `href` 不会被写成 `xlink:href`

- **位置**：`f_svg/src/SvgWriter.cj:190-202`（`isSvgReferencingElement` 白名单 `"use" | "image" | "textPath" | "linearGradient" | "radialGradient"`）；判定点 `:140`、转换点 `:151-157`
- **来源**：存量 —— `git blame -L 190,202` 全部为 `283f2b49bb`（2026-11-05）
- **判据**：review-checklist §11「契约与实现不符」、§14.1「只做了一半的分支」；契约源为字段注释 `SvgWriter.cj:28`「`true` 时引用写 `xlink:href`」
- **证据**：静态确定 —— `normalizeElementHrefs` 中把裸 `href` 改写为 `xlink:href` 的唯一闸门是 `referencing`（`:151-157`）；白名单外元素一律走「不改写」分支，输出保持裸 `href`
- **描述**：SVG 1.1 里 `pattern` / `filter` / `feImage` / `mpath` / `a` / `altGlyph` 等同样只认 `xlink:href`，而它们在本模块里都走 `readSvgHref` 读取（`f_svg/src/SvgPattern.cj:130`、`f_svg/src/SvgFilterPrimitives2.cj:781`、`f_svg/src/SvgTimeline.cj:654`），说明读取侧是「任意元素」，写入侧却收窄成 5 个。白名单内部也不自洽：同为「属性继承」用途的 `linearGradient` / `radialGradient` 在名单里，`pattern` 不在。后果是默认选项（`xlink=true`，即 SVG 1.1 形态）下 `<pattern href="#p">` 写出来仍是 `<pattern href="#p">`，SVG 1.1 解析器不认这条引用，渐变/图案继承链与动画路径引用静默失效；调用方拿不到任何提示
- **建议**：把「引用元素」判定收敛为一份常量表并补齐 `pattern` / `filter` / `feImage` / `mpath` / `a` / `altGlyph` / `glyphRef` / `script` / `animate*` / `set` / `mpath`；或改为「只要属性名是 `href` 且元素在 SVG 命名空间，`xlink=true` 时一律写成 `xlink:href`」（`<a>` 等 SVG2 场景由 `xlink=false` 覆盖）。`SvgWriter_test.cj:190-218` 补 `pattern` / `mpath` 两个往返用例

### [一般][存量] 写出一条文档要跑三趟无深度上限的递归遍历，深树直接栈溢出

- **位置**：`f_svg/src/SvgWriter.cj:162-167`（`normalizeElementHrefs` 对 `element.children` 递归）；同一条调用链上还有
  `f_svg/src/SvgElement.cj:399-407`（`toXmlElement` 深拷贝递归，由 `SvgWriter.cj:74` 触发）与
  `f_xml/src/XmlWriter.cj:465`、`:504`（`writeElement` → `writeNodeWithName` 递归，由 `SvgWriter.cj:77` 触发）
- **来源**：存量 —— `SvgWriter.cj:139-168` 为 `283f2b49bb`（2026-11-05）
- **判据**：review-checklist §4「无界递归：深度由输入决定」；严重度表「崩溃（含栈溢出）」
- **证据**：静态确定 —— 三个函数都没有 `depth` 参数、没有深度计数、没有显式栈；递归终止条件只有「没有元素子节点」。可达深度上界：
  解析路径受 `SvgSecurityOptions.maxDepth`（默认 512，`f_svg/src/SvgOptions.cj:66`；把关点在 `f_svg/src/SvgBuilder.cj:52`、`:127`、`:660-673`，本身是迭代实现不会爆栈）
  约束，但该值是对外可配的 `public let`（`SvgOptions.cj:55`）；程序化路径（`SvgElement.children` 是 `public let ArrayList`，`f_svg/src/SvgElement.cj:52`；`SvgAuthoringBuilder` 无深度校验）没有任何上界
- **描述**：默认配置下 512 层尚可承受，所以问题不表现为「打开就崩」。真正的触发面有两条：① 调用方把 `maxDepth` 配大（或传 `Int64` 级上限）解析一个刻意加深的文档，写入阶段三趟递归叠加；② 用 `SvgBuilder` / `SvgAuthoring*` 程序化搭一棵深树再 `write()`。按每帧含局部 `match` 绑定与 `ArrayList` 迭代器状态估算，数千层即可能打穿默认线程栈；崩溃点是 `SIGSEGV` 而非 `SvgException`，调用方无法 `catch`
- **建议**：把 `normalizeElementHrefs` 改成显式栈（`ArrayList<XmlElement>` 待访问队列）；`SvgElement.toXmlElement` 同样迭代化；`SvgWriter` 增加 `maxDepth` 参数（默认沿用 `SvgSecurityOptions.maxDepth`），超限抛 `limitError`，与 `SvgBuilder.checkDepth` 的报错口径统一。`f_xml::XmlWriter` 侧需要同批改（范围外，`f_xml` 模块），否则只改本模块仍然会在最后一趟递归上爆栈

### [一般][存量] `SvgViewportTransform.from` 接受整个 `SvgRenderOptions` 却丢弃 `viewState` / `initialView`，快照与渲染器矩阵不一致

- **位置**：`f_svg/src/SvgViewport.cj:33-50`（只读了 `options.width` / `height` / `devicePixelRatio`）；对照 `f_svg/src/SvgRenderTree.cj:331-354`（`initialView` 替换 `rootMatrix`、`:351-354` 把 `stateMatrix` 乘进去）
- **来源**：存量 —— `git blame -L 33,50` 为 `62956aab42`（2026-11-06）
- **判据**：review-checklist §11「契约与实现不符」、§10「设计合理性：可测试性 / 语义完整」；受影响消费方 `f_svg/src/SvgGeometry.cj:246-256`（`screenCTM` 承诺「与渲染器的设备矩阵顺序一致」）、`f_svg/src/SvgElementApi.cj:325-350`
- **证据**：静态确定 —— 函数体内 `options` 只出现 `width` / `height` / `devicePixelRatio` 三次读取；全仓 `viewState` 的应用点只有 `SvgRenderTree.cj:351`，`initialView` 只有 `SvgRenderTree.cj:331-350`
- **描述**：结构体注释自称「根视口到设备坐标的变换快照」（`:18`），但 `matrix` 只等于 `viewport.transform(root)`（`:47`），既不含 `SvgRenderOptions.viewState`（缩放/平移，语义是「插在根视口矩阵之后」），也不含 `initialView` 指定的 `view` 变换。调用方用同一套 `options` 既渲染又算 `screenCTM`/命中测试时，只要开了 `viewState` 或 `initialView`，坐标就会整体偏移/不缩放，且没有任何警告；现有用例 `SvgGeometryApiM4_test.cj:149-206` 只覆盖 `devicePixelRatio`，覆盖不到这条路径
- **建议**：`from` 里补两步——`initialView` 命中时改用 `SvgViewport.forView(view, logicalWidth, logicalHeight)`（与 `SvgRenderTree.cj:337-344` 同逻辑），并把 `viewState.toMatrix()` 乘进 `matrix`（或在结构体里单独暴露 `viewMatrix` 字段，让 `screenCTM` 显式相乘）；补一条 `viewState + initialView` 下 `screenCTM` 与 `SvgRenderTreeBuilder.build` 逐点对齐的用例

### [轻微][存量] `matrix` 字段注释写「`viewBox` → 逻辑画布」，但宽高被 `options.width/height` 覆盖后矩阵仍按根元素固有尺寸计算

- **位置**：`f_svg/src/SvgViewport.cj:22`（注释）vs `:37`、`:44-49`（`viewport` 固定用根尺寸算矩阵，`width/height` 用 options 覆盖）
- **来源**：存量（`62956aab42`）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§13「文档与代码一致性」的精神（此处是代码注释）
- **证据**：静态确定 —— `viewport` 由 `SvgViewport.from(root, 300.0, 150.0)` 得到，`logicalWidth/Height` 之后再覆盖；`viewport.transform(root)` 用的是前者。行为与渲染器一致（`SvgRenderTree.cj:282`、`:313-314` 同样口径），所以是注释口径错，不是实现错
- **描述**：`width` / `height` 是输出画布，`matrix` 是「viewBox → 根元素固有视口」，两者在覆盖场景下不相等。按注释理解会以为 `matrix` 已把内容缩放到 `width × height`，从而在调用方多乘/少乘一次
- **建议**：注释改为「`viewBox` → 根元素固有视口（`width`/`height` 为输出画布，二者可能不同；设备映射 = `scale(devicePixelRatio) × matrix`）」，并把 `viewState` 的归属一并写清

### [轻微][存量] `resolveViewportLength` 的百分比分支里 `return safeFallback` 恒不可达

- **位置**：`f_svg/src/SvgViewport.cj:148-154`（`:150` 判真后 `:151` 返回，`:153` 是死语句）
- **来源**：存量 —— `git blame -L 148,154` 为 `a3a06540fa`（2026-11-05）
- **判据**：review-checklist §1「不可达语句 / 恒真恒假分支」
- **证据**：静态确定 —— 进入该分支前 `:145` 已排除 `value.value <= 0.0` 与非有限值，`:136-142` 又保证 `safeFallback` 是正的有限数，因此 `resolved = value.value / 100.0 * safeFallback > 0.0` 恒成立，`if (resolved > 0.0)` 的 else 侧永不走
- **描述**：死语句本身无害，但它让读者以为「百分比可能算出非正值」，掩盖了真正的过滤点（`:145`）。同处 `:157` 的 `isFiniteSvgNumber(resolved)` 也因同样的值域推导恒真
- **建议**：删掉 `:150-153` 的内层判断，直接 `return value.value / 100.0 * safeFallback`

### [轻微][存量] 百分比换算在 `resolveViewportLength` 与 `toUserUnits` 各写一遍，结果完全相同

- **位置**：`f_svg/src/SvgViewport.cj:148-154` vs `f_svg/src/SvgLength.cj:215-225`（`toUserUnits` 的 `Percent` 分支）
- **来源**：存量（`a3a06540fa` / `SvgLength.cj` 存量）
- **判据**：review-checklist §2「换算复制：同一换算在多个文件各写一遍」
- **证据**：静态确定 —— `:155` 构造的 `SvgLengthContext(safeFallback, safeFallback)` 令 `toUserUnits` 的 `Horizontal`/`Vertical` 百分比基准恰好等于本函数 `safeFallback`，两处结果恒等；差异只有「是否再过一次有限性校验」，而该值必然有限
- **描述**：一次百分比解析存在两条实现，后续若 `toUserUnits` 的 DPI / 基准语义调整（例如引入 `viewport-unit` 基准），这里的特判不会跟着变，属于典型的行为漂移源
- **建议**：删除 `:148-154` 的特判，统一走 `:155-161` 的 `toUserUnits` 路径（保留 `:157` 的正值与有限性兜底）

### [轻微][存量] 「viewBox + preserveAspectRatio → 矩阵」在同一文件写了三遍

- **位置**：`f_svg/src/SvgViewport.cj:79-86`（`transform`）、`:108-113`（`forView`）、`:125-130`（`nestedTransform` 局部矩阵）
- **来源**：存量（`62956aab42`）
- **判据**：review-checklist §2「只改类型名 / 换控制流：两个函数体逐行对齐」
- **证据**：静态确定 —— `:80-85` 与 `:125-130` 为逐行同构（`match viewBox` → `(preserveAspectRatio ?? Default).toMatrix(viewBox, w, h)` / `identity`），仅变量名与来源类型（`SvgRoot` vs `SvgRoot`）不同；`:108-113` 同构但来源是 `SvgView` 且缺省值不同（`view.preserveAspectRatio` 非可选）
- **描述**：三处缺省语义已经不同（`SvgView` 不吃 `?? Default`），后续若改默认 `preserveAspectRatio` 或加 `viewBox` 合法性校验，极易只改一两处
- **建议**：抽 `private func viewBoxMatrix(viewBox: SvgViewBox, aspect: SvgPreserveAspectRatio, width: Float64, height: Float64): SvgMatrix`，三处共用；`SvgView` 侧在调用点补默认值

### [轻微][存量] 默认视口 300×150 以裸字面量散落在本部分 3 处、全模块 20+ 处

- **位置**：`f_svg/src/SvgViewport.cj:37`、`:139`、`:141`；跨文件同值：`f_svg/src/SvgRenderTree.cj:282`、`:301`、`f_svg/src/SvgHitTest.cj:308-309`、`f_svg/src/SvgPatternSampler.cj:106-109`、`f_svg/src/SvgElementApi.cj:338`、`f_svg/src/SvgHitQueries.cj:28`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制：同一组常量散落多处」
- **证据**：静态确定 —— `grep -rn "300.0" f_svg/src`（排除测试）命中 20 行以上，语义都是「无尺寸声明时的默认 SVG 视口」
- **描述**：默认视口是 SVG 规范里的公共约定（300×150），现在没有单一出处；改默认值或引入配置时必然漏改，且 `SvgViewport.cj:139/141` 还按轴分别写了一次
- **建议**：在 `SvgViewport` 上加 `public static let DefaultWidth: Float64 = 300.0` / `DefaultHeight = 150.0`（或模块级 `internal let`），上述调用点全部改用常量

### [轻微][存量] `SvgWriter_test.cj` 里 `import std.collection.ArrayList` 未使用

- **位置**：`f_svg/src/SvgWriter_test.cj:20`
- **来源**：存量
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 该文件内 `ArrayList` 零出现（`grep -n ArrayList` 只命中 import 行；快照比较用的是 `StringBuilder` 与 `Array<Byte>`）
- **描述**：无用 import，编译期噪声
- **建议**：删除该行

### [轻微][存量] 测试辅助与生产路径重复实现同一套「写字节 / 快照」逻辑

- **位置**：`f_svg/src/SvgWriter_test.cj:41-49` 与 `:53-61`（`SvgNode` 五分支映射写两遍）；`:86-92`（`writerBytes`）与 `:94-100`（`writerElementString`）与 `f_svg/src/SvgWriter.cj:223-227`（`writeSvgString` 的 `ByteBuffer` → `SvgWriter` → `flush` → `String.fromUtf8` 流水线）
- **来源**：存量
- **判据**：review-checklist §2「换控制流 / 跨层复制：语义相同、语法不同」
- **证据**：静态确定 —— `writerSnapshot` 的 `for (node in element.children)` 分支与 `svgNodeSnapshot` 的 `match (node)` 是同一组 `TextNode/CDataNode/CommentNode/PiNode` 字面量映射，只有 `ElementNode` 的递归目标不同；`writerBytes` 与 `writeSvgString` 除返回类型外逐行同构
- **描述**：映射/流水线各存两份，新增 `SvgNode` 变体或改快照格式时要同步改两处，漏改会造成「快照相等但实际写出不同」的假绿
- **建议**：`writerSnapshot` 的元素分支改为 `out.append(svgNodeSnapshot(node))` 复用同一映射；`writerBytes` 直接调 `writeSvgString(...).toArray()` 之外，更彻底的是让 `writeSvgString` 接受 `OutputStream` 或返回 `Array<Byte>` 的重载，测试只保留一个薄封装

### [轻微][存量] `testdata/**/README.md` 有 13 个仍是「占位 / 计划放置」口径，与已实现的特性和已存在的素材不符

- **位置**：`f_svg/testdata/render/m3/README.md:3-9`（称 `m3-*.svg/.rgba` 「计划放置」于本目录，实际在上级 `testdata/render/`，由 `f_svg/src/SvgScene_test.cj:22`（`SCENE_DIR = "testdata/render"`）驱动）；`f_svg/testdata/render/m5-{bidi,blend,drop-shadow,element-api,media,selector,transform-origin}/README.md:3`（称「在实现该特性时补齐」，实际 7 组 `.svg`+`.rgba` 均已存在并被 `f_svg/src/SvgSnapshotM5_test.cj:155-156` 驱动）；`f_svg/testdata/render/m5-shaping/README.md:3-5`（称渲染「`m5-shaping.svg`」，素材实在上级目录）；`f_svg/testdata/fonts/m5-{bidi,gpos,gsub,kern}/README.md:3`（称「最小 TTF 在实现对应特性时生成」，而 `SvgSnapshotM5_test.cj:27` 的 `m5ShapingFonts()` 已在测试代码里构造含 kern/GPOS/GSUB 的 TTF）
- **来源**：存量
- **判据**：review-checklist §13「文档过期：描述的功能已删除 / 改名；写着『暂不支持』其实已支持」、§14.2「示例覆盖不足」
- **证据**：静态确定 —— `find f_svg/testdata -type f` 显示 `m3-filter.svg`、`m3-pattern.svg`、`m5-blend.svg`、`m5-shaping.rgba` 等均在 `testdata/render/` 根下；`SvgScene_test.cj:98`、`SvgSnapshotM5_test.cj:43` 引用同名场景
- **描述**：13 个 README 都在描述「尚未开始」的状态，会让后来者按 README 去 `m3/`、`m5-blend/` 目录找素材、或误以为 M5 未实现。`testdata/fonts/README.md` 与 `m5-shaping/README.md` 是写对的（指向代码内构造），可作为改写模板
- **建议**：`m3/README.md` 与 7 个 `m5-*/README.md` 改为「素材统一放在 `testdata/render/`，本目录仅占位/说明」并给出真实文件名；`fonts/m5-*/README.md` 改为「fixture 由 `SvgSnapshotM5_test.m5ShapingFonts()` 在内存构造，不在本目录存放二进制」；或直接删除这些只剩一句占位的目录

### [轻微][存量] `nestedTransform` 签名缩进异常，说明该文件未过 `cjfmt`

- **位置**：`f_svg/src/SvgViewport.cj:117`（`public static func nestedTransform(        parent: SvgMatrix,`，括号后 8 个空格）
- **来源**：存量（`62956aab42`）
- **判据**：review-checklist §10「可读性 / 可维护性」
- **证据**：静态确定 —— 同文件其余多行签名（`:33-36`、`:101`）均为标准换行缩进，仅此一处异常
- **描述**：单点格式异常，通常是手工改动后漏跑 `cjfmt`，也说明 CI 没有格式门禁
- **建议**：`cjfmt -w f_svg/src/SvgViewport.cj`，并在 CI 加 `cjfmt --verify` 之类检查

### [轻微][存量] `SvgViewportTransform` 的公共构造不校验 `devicePixelRatio` 与宽高，与 `SvgRenderOptions` 的校验口径不一致

- **位置**：`f_svg/src/SvgViewport.cj:26-31`；对照 `f_svg/src/SvgBitmap.cj:243`（宽高非负）、`:252-253`（`devicePixelRatio` 必须为正的有限数）、`f_svg/src/SvgHitTest.cj:215-216`（同口径）
- **来源**：存量（`62956aab42`）
- **判据**：review-checklist §11「缺少边界校验」、§12「契约与实现一致」
- **证据**：静态确定 —— 构造函数直接赋值，无任何判断；`dpr = 0.0` / `NaN` 会被 `SvgGeometry.screenCTM`（`f_svg/src/SvgGeometry.cj:249`）当作 `scale()` 因子，产出全零或 `NaN` 矩阵
- **描述**：经 `SvgRenderOptions` 构造的路径是安全的（options 已在 `SvgBitmap.cj:252` 校验），但 `SvgViewportTransform` 是 `public struct`，测试与外部调用方都直接构造它（如 `SvgElementApiM5_test.cj:149`）。传 `0` 时不会报错，只会得到「所有几何坍缩到原点」的静默错误输出
- **建议**：构造函数补 `if (!isFiniteSvgNumber(devicePixelRatio) || devicePixelRatio <= 0.0) { throw invalidValue(...) }`，宽高允许 `0`（表示未定）但拒绝负值与非有限值，报错文案与 `SvgRenderOptions` 统一

> 存量合计 13 条（一般 3 / 轻微 10），是否纳入修复待用户决定；本部分不含本次改动引入的问题（工作区快照无 diff）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 本部分只有 `.md`，没有堆内存 / CPU 可优化路径，不产出性能方案（0 / 0）。下面两条是文档维护性方案，不计入性能统计。

### [文档] 能力矩阵收敛为单一来源

- **现状**：能力声明分布在 `README.md`（167 行表格）、`README_en.md`（同构）、`doc/f_svg-M2设计.md` ~ `f_svg-M6设计.md`、`doc/spec/*`；已出现三类漂移（#11、#12、#13 已取证）
- **方案**：README（中英）作为唯一能力矩阵；M2–M6 改为纯设计决策记录（删除能力表或加归档头）；加一条校验脚本，从 `src/` 抽取 `public` 顶层类型名与关键常量（`maxDepth` / `maxElements` / `maxPixels` / 各 `MAX_*`），与 README 文本做集合比对，差集非空即失败
- **预期**：消除「文档说不支持而代码已支持」「文档默认值与常量不符」两类漂移；本次已发现 3 处，M7 之后仍会增加
- **代价**：一次性改写 5 个文首 + 维护约 100 行抽取脚本；无运行时语义变化
- **验证**：脚本对 README 与 `src/` 求差集为空；对 M2–M6 断言存在归档声明；CI 跑一次
- **证据状态**：静态确定（漂移点已取证，无需性能基线）

### [文档] 安全开关改写为「判定顺序」而非三列表格

- **现状**：`README.md:444-452` 的「内容 / 默认 / 开关」三列无法表达「`unsafePolicy` 优先于 `allow*`」，已导致 #2；`data:` 的 MIME 范围（#10）与 `xml:base`（`SvgBuilder.cj:355-356`）也未列
- **方案**：改成四列（内容 / 默认 / 放行开关 / 强制保留条件），或给一段伪代码：`片段 → 检查 allow* → 否则按 unsafePolicy`；补 `xml:base` 与 `data:` MIME 两行
- **预期**：配 `Keep` 的调用方能直接看到残留风险面，减少「以为关了其实没关」的误配
- **代价**：纯文档改动；若同时改为 `allow*` 优先，则属行为变更，需用户确认
- **验证**：与 `f_svg/src/SvgSecurity_test.cj` 的每个用例逐条对照，确认表格与断言一一对应
- **证据状态**：静态确定

<!-- 第 2 部分 -->

> 本部分 17 个文件全为文档，没有可执行的代码优化方案；文档侧的性能观察都属于"补数据"范畴，已放入下节「待验证假设」，不计入优化统计。

<!-- 第 3 部分 -->

无。本部分 20 个文件全部是规格 / 任务 / 校验文档，不含可测量的 CPU 或堆内存执行路径，本轮不对任何实现提出性能或内存改造建议（§7 / §8 计 0）。

<!-- 第 4 部分 -->

本部分文件全部为 `.md`，不含可测量的 CPU / 堆内存执行路径，因此**没有**带基线的优化方案（§7 / §8 计 0）。#5 与 #8 是"补上限"的缺陷修复，已计入「发现」而非本节；任何收益估算都缺改前/改后数据，统一放入「待验证假设」。

<!-- 第 5 部分 -->

本部分 18 个文件全部是 `.md`，不含可测量的 CPU / 堆内存执行路径，因此**没有**可执行的性能或内存优化方案（§7 / §8 计 0 / 0）。文档层面的可量化收益只有「减少复核成本」（死引用、重复 Scenario、被否决结论残留），属可维护性，不构成性能方案。

<!-- 第 6 部分 -->

本部分为设计/规格/验收文档，未产出可量化的堆内存或 CPU 方案（性能候选项缺改前/改后对照，已降级到「待验证假设」）。

<!-- 第 7 部分 -->

### [堆内存] `save(path:)` 改为流式落盘，去掉 String + 字节数组双份驻留

- **现状**：`f_svg/src/SvgAuthoringBuilder.cj:66-72` 的 `save(path: Path)` 先 `toSvgString()` 物化整份 `String`，再 `.toArray()` 复制成整份 `Array<Byte>` 交给 `File.writeTo`；同一份输出在峰值同时存在两份完整表示（String + 字节数组），写盘结束才释放。调用 `save(path: String)`（`:61-63`）同样走这条路径。
- **方案**：用 `File.create(path)` 打开后调用已存在的 `write(output: OutputStream)`（`SvgAuthoringBuilder.cj:75-79`），在 `try` 中关闭文件；异常仍按 D9 包 `invalidValue`。不新增 API，不改 `toSvgString`。
- **预期**：峰值从约 2× 输出大小降到约 1×；对 50 MB 级生成物可省约 50 MB 级峰值（按 UTF-8 字节估算，中文按实际编码）。
- **代价**：`save(path)` 由库负责打开/关闭句柄（现由 `File.writeTo` 承担，对外语义不变）；错误信息需保留路径。
- **验证**：生成 50 MB 级文档，改前/改后各跑 10 轮，记 `getAllocatedHeapSize()` 峰值与 RSS 峰值，并断言落盘字节与 `toSvgString()` 逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 8 部分 -->

### [堆内存] `CssCalcValue` 由 `class` 改成 `struct`

- **现状**：每次求值的每个操作数与中间结果都新建一个 `CssCalcValue` 堆对象（`f_svg/src/CssCalc.cj:39-47`，构造点 `:168`、`:225`、`:226`、`:234`、`:235`、`:238`、`:250`、`:256`、`:259`、`:266`）。对象只含一个 `Float64` + 一个枚举，生命周期止于本次求值；一个含 10 个操作数的 `calc()` 约产生 8-10 个短命对象
- **方案**：`private struct CssCalcValue { let value: Float64; let unit: CssCalcUnit }`（`CssCalcUnit` 已是无负载枚举，可作 `struct` 字段），`?CssCalcValue` 改为 `Option<struct>`，无需 mode 重载
- **预期**：单次求值分配次数降到 0（值类型走栈/寄存器）；收益量级取决于 `calc()` 在真实文档里出现的次数，未测
- **代价**：`?CssCalcValue` 语义变为值拷贝；本文件所有使用点都是只读，影响面仅限本文件
- **验证**：`cjpm bench -O2` 对一份含 1 万个 `calc()` 声明的样式表跑前后对照，同时记录 `getAllocatedHeapSize()` 增量与 GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 单遍扫描内直接解析数字，避免每个操作数切一次子串并重扫

- **现状**：`parsePrimary` 先记 `start`，扫到数字结束（`f_svg/src/CssCalc.cj:202-209`），再 `this.text[start..this.i]` 切子串（`:213`）交给 `tryParseSvgFloat`；后者 `trimAscii()` 再切一个串、`scanSvgNumber` 把同一段字节重新扫一遍、`normalizeSvgNumber` 再按需造串。单位同理（`:223`）。即每个数字 2 次冗余扫描 + 2-3 次字符串分配
- **方案**：复用 `scanSvgNumber(this.text, start)`（`f_svg/src/SvgNumber.cj:90-138` 已提供按字节索引的 `SvgNumberToken`），省掉 substring、`trimAscii` 与二次扫描；只有单位需要小写化时才切子串
- **预期**：每个操作数省 2 次分配与 1 次完整重扫；端到端收益 = `calc()` 声明占比 × 单次求值自耗时占比，未测
- **代价**：`scanSvgNumber` 接受前导 `+`/`-` 与指数（`1e3`），而当前 `parsePrimary` 的数字语法不含指数，直接换用会让 `calc(1e3)` 由非法变合法，需显式传参禁止指数；否则语义漂移
- **验证**：`cjpm bench -O2`，同一份 1 万 `calc()` 输入，测 `evaluateCssCalc` 总耗时中位数与分配量；附等价性用例（`CssCalcM5_test` / `CssGeometryCalcM5_test` 全绿）
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 9 部分 -->

> 不是缺陷，是「还能更好」。本部分无任何 profile / bench 数据，以下全部为无基线方案。

### [CPU] `CssSelectorIndex.candidates` 改为按元素自身的 class 词查表，并去掉插入排序

- **现状**：`f_svg/src/CssSelector.cj:434-442` 对每个元素遍历 `byClass` 的**全部键**，逐键 `cssClassListContains(text, key)`（每键 O(类串长度)）；随后 `:447-457` 用插入排序把候选升序（O(k²)，k = 候选数）。调用路径：`SvgStyleResolver.considerSheet`（`SvgStyleResolver.cj:425`）→ 每元素一次。输入规模：元素数 × 类选择器去重数，典型 10^4 元素 × 10^2 类键 = 10^6 次字符串扫描。
- **方案**：先用 `splitCssWhitespaceWords(element.class)` 得到元素自己的词（通常 1–3 个），逐词 `byClass.get(word)` 取桶；重复候选用一个「按规则下标」的 `Array<Bool>`（长度 = 规则数）或版本号数组去重，天然按桶加入顺序即可，最后用 `std.sort.sort(result, key: {i => i})`（`Collection.sort()` / `sortBy()` 均已 `deprecated`，不要用；也可直接放弃排序，候选顺序不影响胜负判定——`CssCandidate.beats` 靠 specificity + order，不靠遍历顺序）。
- **预期**：候选收集从 O(类键数 × 类串长) 降到 O(元素类词数)；去掉每元素一次 O(k²) 排序与一次 `HashMap<Int64, Bool>` 分配。收益量级未测。
- **代价**：需确认「候选顺序不影响结果」——`considerSheet` 只按 `beats` 取最优，顺序无关（`:437-458` 已核对）；`splitCssWhitespaceWords` 会为每个元素分配一个数组，需要改成「回调逐词」或复用缓冲。
- **验证**：`cjpm bench -O2`，一份 1 万元素 + 200 条类选择器的文档，对照 `SvgStyleResolver.compute` 总耗时中位数与 `candidates` 自耗时；附等价性用例（现有 M5/M6 级联用例全绿）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 候选收集的每元素临时容器改为可复用缓冲

- **现状**：`candidates` 每次调用新建 `HashMap<Int64, Bool>`（`:423`）+ `ArrayList<Int64>`（`:424`），二者都不逃逸出本次调用；`SvgStyleResolver.compute` 对 N 个元素调用 N 次，10^4 元素即 2×10^4 个短命容器（外加扩容产生的数组副本）。
- **方案**：把 `seen` 换成「规则数长度的 `Array<Int64>` 版本戳 + 当前代数」（`stamp[ruleIndex] == generation` 即已收集），`result` 换成调用方持有的 `ArrayList` 并 `clear()` 复用；两者随 `CssSelectorIndex` 生命周期存活，`candidates` 只写不 new。
- **预期**：每元素容器分配 2 → 0，减少年轻代分配量与 GC 次数；峰值堆下降幅度未测。
- **代价**：`CssSelectorIndex` 从「不可变只读」变成「持有可变缓冲」，需要重新评估并发（当前 `SvgStyleResolver` 本身已非线程安全，若将来要并行 `compute`，缓冲需按线程拆或保留当前实现）；`clear()` 不归还物理内存（`mem §3.2`），只复用容量。
- **验证**：稳态负载下 `getAllocatedHeapSize()` 增量与 GC 次数前后对照（同 SDK、`-O2`、同输入），RSS 仅作参考。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 兄弟序号与总数合并为单次遍历（与「轻微」发现同源）

- **现状**：`LastChild` / `LastOfType`（`CssSelector2.cj:779`、`:783`）各扫父容器两遍；`NthChild` / `NthOfType`（`:781`、`:785`）扫到目标为止。父容器子节点数 = 兄弟数，在宽扁平文档（几千个兄弟）里单次 O(n) 已经不便宜，双扫直接翻倍。
- **方案**：一次遍历同时得到 `(index, count, previous)`，三个伪类共享（见「发现」中的合并建议）。
- **预期**：结构类伪类的父容器扫描次数减半；实际耗时占比未测（需要先有 profile）。
- **代价**：返回元组比三个单值函数多一次解构；`cssPreviousElementSibling` 与 `cssElementSiblingIndex` 的调用点需同步改。
- **验证**：`cjprof record` 跑一份「1 万元素、每条规则带 `:nth-child` / `:last-child`」的文档，看 `cssElementSiblingIndex` / `cssElementSiblingCount` 的 self time 与调用次数前后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 10 部分 -->

> 本部分无 `cjprof` / `cjpm bench` 基线，以下三条全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] 解析覆盖率只算形状包围盒，不算整幅画布

- **现状**：`SvgRasterizer.computeCoverage` 把 `bitmap.width × bitmap.height` 传给 `analyticCoverage`（`SvgRasterizer.cj:285`）；函数内 `coverage`（`SvgAnalyticRasterizer.cj:164`）与 `accumulated`（`200-204`）合计 16 B/px，每次填充形状各申请一次，峰值两份同时存活
- **方案**：复用超采样档已经算过的轮廓 bbox（`SvgRasterizer.cj:291-310`），只把 `[minX..maxX] × [minY..maxY]` 的裁剪区交给 `analyticCoverage`，返回 `(coverage, offsetX, offsetY)`；`analyticUsesLocalAccumulator` 的门限按局部像素数重新标定
- **预期**：单次 fill 的临时数组从 `16 B × W×H` 降到 `16 B × bboxArea`；小图形（icon、图表元素）降 1～3 个数量级，全屏背景不变
- **代价**：改 4 个函数的坐标约定与复合点索引；要处理 bbox 越界、宽高为 0 的退化情形；local/heap 分档门限需重测
- **验证**：同图同尺寸、`-O2`，记录 `getAllocatedHeapSize()` 峰值 + RSS，并用 `SvgAnalyticLocalMode_test.cj` 的逐元素等价断言保证像素不变
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 去掉逐列 `ArrayList` 分配

- **现状**：`analyticEdgeColumnIntegral`（`SvgAnalyticRasterizer.cj:367-411`）每次调用新建 `ArrayList<Float64>`（`377`）并做插入排序（`390-390`）；`accumulateAnalyticEdges`（`351-352`）对每个像素列调它两次 ⇒ 分配次数约为 `2 × 覆盖列数 × band 数 × 行数`，而每份容器只装 2～4 个 `Float64`
- **方案**：把至多 2 个分段点（`382-389`）写成内联分支 + 局部变量，不建容器；或把 `values` 提到 `accumulateAnalyticEdges` 外层复用
- **预期**：每次 fill 少「像素量级」的容器分配，GC 压力与分配记账成本同步下降（比例待测）
- **代价**：从「排序再遍历」改为「分段判断」，可读性下降；必须保留 `ANALYTIC_EPSILON` 退化处理，`delta ≈ 0` 要单独一支
- **验证**：`cjpm bench -O2`，1000×1000 圆与 200 段折线各 200 轮取中位数，同时记 `getAllocatedHeapSize()`；`cjprof record` 看该函数自耗时占比变化
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 用扫描线 + 活跃边表替代行内全点对枚举

- **现状**：每行先线性扫全部边挑活跃边（`f_svg/src/SvgAnalyticRasterizer.cj:231-235`，O(rows·E)），再对活跃边两两求交（`252-267`，O(A²)），每个子区间又重建 `hits` 并插入排序（`291-300`）
- **方案**：端点事件按 y 排序后逐行推进，维护按 x 排序的活跃边序列；行内只处理相邻边次序交换事件（优先队列），交点不再全点对枚举
- **预期**：行内复杂度从 O(A²) 降到 O(A log A)；`A ≈ 1000` 时每行少约 50 万次求交（静态推算，未测）
- **代价**：行内事件驱动逻辑需重写，等价性完全依赖现有逐元素断言；`events` 的 local 策略要一起重定（见发现 5）
- **验证**：同几何逐元素等价（圆、甜甜圈、自交五角星、200/1000 段折线）+ `cjpm bench -O2` 前后对照 + `cjprof` 行内函数自耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 11 部分 -->

### [堆内存] `SvgBuilder.save(path:)` 的两次全量物化可以去掉一次

- **现状**：`save(path:)`（`SvgAuthoringBuilder.cj:66-72`）先 `toSvgString()` 得到一个完整 `String`（`56-58`，经 `SvgWriter` 写到内存流），再 `.toArray()` 复制成 `Array<Byte>`，两份表示同时存活；同文件 `write(output:)`（`74-79`）已经是流式的
- **方案**：`save(path)` 改为 `File(Path(path), OpenMode.Write)`（`std.fs`：`fs_package_classes.md:557-562`、`fs_package_enums.md:3-12`）后复用 `this.write(file)`，序列化结果边生成边落盘；`String` 版本只保留给 `toSvgString()` 的调用方
- **预期**：峰值下调约 1× 输出体积（不确定项：`SvgWriter` 内部缓冲实现，需实测）
- **代价**：失败语义变化——流式写在异常时可能留下半截文件，需要决定「先写临时文件再 rename」还是「直接失败」；`FSException → InvalidValue` 包装要同步调整
- **验证**：50 MB 级文档（大量 `path` + 文本）改动前后各取多轮 `getAllocatedHeapSize()` 峰值与 RSS 中位数，并比对输出字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgAutoSize.rootSize` 在结果用不到时仍计算内容包围盒

- **现状**：`f_svg/src/SvgAutoSize.cj:46-51` 在任何一轴为 auto 时都调用 `svgBBoxOf`（`SvgElementApi.cj:123` 起，遍历整棵子树 + 样式查找 + 分配），但单轴 auto 且 viewBox 有效时走 `:88-94` / `:101-107`，`contentWidth` / `contentHeight` 根本没用；单轴 auto 且内容为空时结果也未被使用
- **方案**：先判 viewBox 与 auto 组合，只在「双轴 auto」或「单轴 auto 且无可用 viewBox」时计算 bbox
- **预期**：省掉一次全文档 bbox 遍历（O(节点数) + 每节点样式查询），大文档（数千元素）收益最明显；端到端收益取决于 bbox 占比，未测
- **代价**：分支变多，需保持与 `SvgAutoSizeM6_test.cj:33-111` 的组合一致
- **验证**：`cjprof record` 跑 5k 元素 auto 文档，对比 bbox 自耗时占比；改前改后 `cjpm bench -O2` 中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgBitmap.blend` 的每样本量化与除法可改为整数/定点

- **现状**：`blend`（`SvgBitmap.cj:143-161`）每次读 4 字节、做 3 次 `/255.0`、一次 `over`、`toColor()`（3 次除法 + 3 次 `round` + 4 次 `clampSvgUnit`）再写 4 字节；调用方逐样本（`SvgRenderer.cj:1148` 图像合成、`SvgRasterizer` 光栅化，`samplesPerPixel` 默认 4 即 16 样本/像素）。`blendSvgRgba` 另外每像素构造两个三元组并对三个通道各做一次 `match`（`SvgBlend.cj:130-144`、`158-205`）
- **方案**：destination 侧直接读 8 位字节做整数近似；`blendCssChannel` 的三次 `match` 提到循环外（按 mode 分派到专用函数），`Normal` 走无分支整数 over
- **预期**：单像素算术指令数下降，具体比例无数据支撑，不写百分比
- **代价**：8 位定点与浮点会有 ±1 量化差，需 golden 图比对；按 mode 分派会多几份代码
- **验证**：`cjpm bench -O2` 对照（同机、同 SDK、1024×1024 / 50 形状、`samplesPerPixel` 1 与 4），取中位数与 P95；用现有 `m5RenderAndCompare` 快照确认像素差在容差内
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 12 部分 -->

> 以下均为"还能更好"，无改前/改后基线，按 reviewer 约定标 `无基线（待验证）`，不进修复清单。

### [堆内存] 计算样式对每个元素做 75 属性全量快照

- **现状**：每个 `SvgComputedStyle` 持有 `values`（约 75 个条目）、`sources`（约 75 个条目）、`varExpressions`（少量）三张 `HashMap`（`f_svg/src/SvgComputedStyle.cj:169-172`）；样式树按元素建一份（`SvgStyleResolver.cj:111`、`399`）。10 万元素文档约 1500 万条 map 条目；若条目 + 桶开销按 32 B 估，约 480 MB 常驻，文档规模线性放大。
- **方案**：只物化"与 initial 不同"的属性，`get()` 沿父链回退；`sources` 只存非 `Default`/`Presentation` 的项；`varExpressions` 已经是稀疏的，保持。或者把 75 个初始值做成共享不可变表，元素只存覆盖项。
- **预期**：常规文档每元素非默认属性通常 < 10 个，条目数预计降 80% 以上；峰值 RSS 与 GC 压力同步下降。
- **代价**：`get()` 从 O(1) 变成"沿父链 + 默认表"查找，`toString()`/`customProperties()` 需要遍历合并；继承语义（尤其 `currentColor`、`var()` 展开）要逐条回归；`SvgComputedStyle` 是 public 类型，字段布局变化不影响 API，但性能特征变化需写进文档。
- **验证**：同机器、`-O2`，分别用 1k / 10k / 100k 元素的合成文档跑 `SvgParser.parse` + 样式树构建，记录 `getAllocatedHeapSize()` 峰值、RSS、`getUsedHeapSize()` 与构建耗时中位数/离散度；与现状对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 蒙版渲染复用 scratch 位图与覆盖率缓冲，按引用层数做常数上限

- **现状**：每次 `renderClipCoverage` / `renderMaskCoverage` / `SvgClipCoverage.render` 都新建 `SvgBitmap`（`f_svg/src/SvgClipMask.cj:230`、`275`；`f_svg/src/SvgClipProperty.cj:129`）与 `Array<Byte>(width*height)`（`SvgClipMask.cj:251`、`295`；`SvgClipProperty.cj:124`）；循环引用时 64 层各分配一套（见 #1），峰值 ≈ 9 B/px/层。
- **方案**：一次渲染内共享一个 `SvgMaskScratch`（`bitmap` + `coverage` + 复用计数），嵌套层按需清零复用；层数上限设为常数（如 8），超限抛 `Limit`。
- **预期**：循环引用的峰值从「64 × 9 B/px」降到「常数 × 9 B/px」，非循环场景每次少 2 次全画布分配。
- **代价**：复用必须严格清零（漏清会产生上一层残影）；`SvgCoverageMask` 当前直接持有外部 `Array<Byte>`，复用期间要禁止把内部缓冲交给调用方（或改为拷贝出）。
- **验证**：同输入下 `getAllocatedHeapSize()` 峰值与 RSS 对照，加像素级回归（`SvgClipMask_test` / `SvgClipRenderM4_test` 逐字节一致）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 嵌套 clip/mask 按整幅画布光栅化与合成

- **现状**：`renderClipCoverage` / `renderMaskCoverage` 每次分配 `w×h` 位图（`SvgClipMask.cj:230`、`275`），`renderClipChildren` / `renderMaskChildren` 为每个带 clip/mask 的子元素再分配整幅 `layer`（`393`、`531`）并整幅 `composite`（`458`、`586`）；实际被裁剪的内容通常只占画布很小一块。
- **方案**：先算子元素设备空间包围盒（含描边/抗锯齿余量），按包围盒分配小 layer、只在该区域光栅化与合成；引用深度进入时判环（同时解决 #1 的 64 层重复计算）。
- **预期**：典型图标元素占画布 < 10% 时，layer 像素与合成工作量降约一个数量级；#1 的 1080p 峰值随之下降。
- **代价**：需要可靠的 device bbox（描边、滤镜、变换后的包围盒），合成坐标要带偏移；`Normal` 路径必须保持与 M4 逐字节一致，需要全量图像回归；`mask` 的 luminance 仍需整幅背景（可只算 region 内的像素）。
- **验证**：`cjpm bench -O2`，1000×1000 画布、嵌套 1/5/10 层各跑多轮，记录 p50/p95 与 `cjprof` self time；同时对比现有输出的逐像素哈希。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgBuilder` 构建前做两趟全量遍历，且每个元素都新建 path 计数 `HashMap`

- **现状**：`buildSvgDocument` 先 `countXmlElements`（BFS，`ArrayList` 持有全部元素，`SvgBuilder.cj:630-647`），再 `checkDepth`（第二趟 BFS，`660-677`），最后递归构建；`buildSvgChildren` 对每个元素（含叶子）新建 `HashMap<String, Int64>` 做同级索引（`92`）。
- **方案**：构建时单趟完成"元素数 + 深度"检查（提前 fail-fast 可在进入子节点前判断，仍能保持"先检查后构建"的错误语义）；`counters` 只在存在元素子节点时创建，或复用一个按层清空的 map。
- **预期**：DOM 遍历 3 趟 → 1 趟；每元素至少少一次 `HashMap` 分配，10 万元素文档预计减少 10 万次小对象分配与相应 GC。
- **代价**：错误抛出时机从"构建前"变成"构建中"（部分 DOM 已构造，但不会泄漏给调用方）；`maxElements` 的判定需要在新位置保持同样的 `Limit` 异常与消息。
- **验证**：`cjpm bench -O2` 构建 1k/10k/100k 元素文档，记录构建 p50/p95 与 `cjprof` 分配采样；对比 `SvgException` 消息与 kind。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 13 部分 -->

> 本部分没有任何"改前基线 + 改后对照"（两处自测耗时分别是 `println` 与 5 s 墙钟断言，且跑在 `cjpm test` 默认 `-O0`），因此两条方案都标 `无基线`，只可作为下一轮补数据的候选，**不进 `tasks.md`**。

### [CPU] `isSvgCursorKeyword` 的 37 项线性扫描改为静态集合查找

- **现状**：`f_svg/src/SvgCursor.cj:71-77` 对 `SVG_CURSOR_KEYWORDS`（37 个字符串）做 `for + ==` 线性扫描；每个元素计算样式时调用一次（`SvgStyleResolver.cj:744`），大文档下是"元素数 × 37"次字符串比较。
- **方案**：改 `match (name)` 的编译期常量分支，或模块级 `static let HashSet<String>`（初始化一次）。
- **预期**：单次查找从 O(37) 降到 O(1) 且避免 37 次 `String.==`；实际收益取决于样式计算里 cursor 的占比，未测。
- **代价**：多一个全局不可变集合（数百字节）；`match` 方案代码量增加约 40 行。
- **验证**：`cjpm bench -O2`，输入同构于 `SvgComputedStyle_test.cj:363` 的 1000 规则 × 1000 元素并加一条 `cursor` 规则，取中位数与 P95。
- **证据状态**：`无基线（待验证）`

### [堆内存] `views()` / `anchors()` 改为单遍收集，去掉整表中间副本

- **现状**：`views()`（`f_svg/src/SvgDocument.cj:117-127`）先 `elementsByTag("view")` 收集**全部**同名元素（含其它命名空间的同名 local name），再过滤成 `ArrayList<SvgView>`；`anchors()`（`142-151`）另走一条遍历。峰值同时存在两份列表，长度约为匹配元素数。
- **方案**：给遍历加谓词/回调（`collectSvgElementsByTag` 已带谓词 `tag`，扩展成 `predicate: (SvgElement) -> Bool`），`views()` 直接单遍产出 `ArrayList<SvgView>`；`anchors()` 复用同一遍历 + `kind == Anchor` 判断（同时消掉 #6 之外的又一份遍历骨架）。
- **预期**：少一份 N 元素 `ArrayList` 与其扩容过程（N = 同名元素数）；`anchors()` 少一层递归函数。
- **代价**：遍历函数签名变化（`private`，影响面仅本文件）；谓词闭包每次调用多一次间接调用。
- **验证**：`getAllocatedHeapSize()` 峰值对照（1e4 个 `view` + 1e5 其它元素，`-O2`，同机同 SDK），连续 10 轮取峰值中位数。
- **证据状态**：`无基线（待验证）`

<!-- 第 14 部分 -->

> 都不是缺陷，是"还能更好"。以下全部**无改前/改后对照数据**，只能作为待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] `serializeSvgCData` 把整段文本物化成 `ArrayList<Rune>` 只为做三字符前瞻

- **现状**：`f_svg/src/SvgElement.cj:665-685` 先把 `text.runes()` 全量塞进 `ArrayList<Rune>`（每元素 ≥ 4 B + 扩容冗余），再按下标判断 `]]>`。CDATA 长度由调用方文本决定（`SvgElement.toString()` 输出大段 CDATA 时为 O(文本长度) 的额外整份副本）
- **方案**：改成单遍迭代 + 长度 3 的滑动窗口（或 `String.indexOf("]]>")` 直接找分隔点，命中处插 `]]]]><![CDATA[>`，其余原样 append）
- **预期**：序列化期间额外堆占用从 O(n) 降到 O(1)；大 CDATA（如内联 base64 文本）场景峰值明显下降
- **代价**：实现从"按下标"改成"按游标/查找"，逻辑分支略增；输出必须逐字节不变（现有测试 `SvgElement_test.cj:221-235` 已钉住三种边界）
- **验证**：同文档序列化 100 次，对比 `getAllocatedHeapSize()` 峰值与 RSS；输出与现实现逐字节比对
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 滤镜中间缓冲的复用与提前释放

- **现状**：见发现 #2——`named` 持到链结束，单缓冲上限 256 MiB；`SvgFilterBuffer` 类注释（`f_svg/src/SvgFilterBuffer.cj:18-22`）把"每个原语产生新缓冲"定为设计
- **方案**：先做"最后引用计数"释放（改动集中在 `f_svg/src/SvgFilterRenderer.cj:196-252`，本部分文件只需保证 `SvgFilterBuffer` 可被覆盖写）；再评估逐像素原语（`flood` / `colorMatrix` / `blur`）原地写回
- **预期**：N 原语链的峰值从 (N+1)×区域字节降到约 2–3×区域字节
- **代价**：原地写需要别名分析（`in` / `in2` / `SourceGraphic` 可能指向同一缓冲），判断错会静默产生错误像素；`feMerge` 的名引用使"最后引用"要按 `in` / `in2` 名字静态算
- **验证**：固定 20 原语 + 4000×4000 区域的基准，测 `getAllocatedHeapSize()` 峰值、RSS、单帧耗时；像素输出与现实现逐字节相等
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `getBBox` / `getCTM` / `getScreenCTM` 每次调用都重建整棵计算样式树

- **现状**：`f_svg/src/SvgElement.cj:459-464`（`getBBox` 里 `SvgStyleResolver().compute(root, ...)`）与 `f_svg/src/SvgElementApi.cj:313`（`svgElementCtm`）、`:343`（`svgElementScreenCtm`）各自新建样式树；element 数量为 n 时批量测量 m 个元素是 O(m·n)
- **方案**：给 `SvgDocument` / `SvgRoot` 增加可复用的样式树槽位（按 `attributesVersion` 和媒体尺寸做键，命中即复用），或提供批量 API `measureAll(elements)` 只算一次树
- **预期**：批量测量从 O(m·n) 降到 O(n + m)（数量级收益，但当前无实测数据支撑具体降幅）
- **代价**：样式树缓存要处理 DOM 变更失效（`attributesVersion` 只到单元素粒度，子树变更需要冒泡到根）与媒体尺寸变化；缓存生命周期变长，需与 §7 的"缩短生命周期"取向权衡
- **验证**：对 2000 元素文档逐元素 `getBBox()`，`cjprof record` 看 `SvgStyleResolver.compute` 自耗时占比；改后同输入对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `setAttr` 双次扫描属性表；`svgNotifyMutation` 在无监听器时仍逐级上溯

- **现状**：`f_svg/src/SvgElement.cj:153-154` 先 `attr(name)` 再 `bareAttributeIndex(name)`，同一张 `attributes` 扫两遍（属性多时 2×O(k)）；`f_svg/src/SvgMutation.cj:110-127` 每次属性写入都沿 `parent` 链走到根才 `return`，而 `SvgDocument` 的 hub 通常在但 `listeners` 为空（`f_svg/src/SvgMutation.cj:76`，只有显式 `addMutationListener` 才非空）
- **方案**：`setAttr` 用一次查找同时拿到 `index` 与 `oldValue`（新增 `private func locate(name) -> (Int64, ?String)`）；`svgNotifyMutation` 在根上维护 `hasListeners` 计数（`add` / `remove` 时更新），无监听器时 element 侧直接短路（元素缓存一个 `?SvgMutationHub` 引用亦可）
- **预期**：动画逐帧写样式的路径（`SvgTimeline.cj:1341` → `svgSetInlineStyleProperty` → `setAttr`）每帧少一次属性扫描 + 一次到根的上溯；深度大的文档收益更明显
- **代价**：`hasListeners` 需要与 `listeners` 同步维护（单线程 DOM 语义下无额外锁）；缓存 hub 引用要在 `mutationHub` 赋值处一并失效（`SvgDocument.cj:37`）
- **验证**：60 帧动画写 1 万个属性，`cjprof` 看 `svgNotifyMutation` / `bareAttributeIndex` 自耗时；改前改后同输入对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 光照滤镜逐像素经"带版本校验的 getter"取光源参数

- **现状**：`f_svg/src/SvgFilterLighting.cj:474` 每像素调 `m4LightFor`，内部按光源类型每次读 `azimuth` / `elevation`（`:362-363`）或 `x/y/z` + `pointsAt*` + `limitingConeAngle`（`:382-391`），每个属性都是一次 `SvgValueCache.get`（版本比较 + `Option` 匹配）
- **方案**：在 `lightingFilterBuffer` 进入像素循环前把光源参数解构成本地结构（`M4LightSpec`），循环内只读局部变量
- **预期**：每像素从 ~3–8 次 cache 查询降到 0；具体降幅取决于像素规模（无数据）
- **代价**：新增一个内部 struct + 一处 `match`，逻辑重复一次"取值"，但与 `m4LightFor` 合并后可只留一份
- **验证**：4000×4000 缓冲的 `feDiffuseLighting`，`cjprof` 看 `SvgValueCache.get` 与 `m4LightFor` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 15 部分 -->

> 不是缺陷，是「还能更好」。本部分没有做改前/改后对照，所有收益均为预期值。

### [CPU] 线性光 ↔ sRGB 转换用 256 项查表替代逐像素 `pow`

- **现状**：`f_svg/src/SvgFilterRenderer.cj:372-416`。`toLinearRgb` / `toSrgb` 对每个像素的 R/G/B 各调一次 `pow`（`linearChannel` `:398-406`、`srgbChannel` `:408-416`），512×512 区域即 3×262144 次 `pow`；输入域只有 256 个可能值
- **方案**：模块级 `let SVG_LINEAR_LUT / SVG_SRGB_LUT: Array<Byte>`（256 项，编译期或首次使用时构建），转换退化为 `lut[pixels[i]]`
- **预期**：把每像素 3 次超越函数调用换成 3 次数组索引；`linearRGB` 文档的滤镜链入口/出口各一次全图遍历，理论上该段耗时降到「纯内存搬运」量级（具体比例待测）
- **代价**：多 512 B 常驻；`pow` 的舍入需与现实现逐值对齐（256 项可穷举验证，误差 0）
- **验证**：`cjpm bench -O2` 同输入 512×512 `color-interpolation-filters="linearRGB"` + `feOffset dx=0`，改前/改后各 10 轮取中位数；并逐值断言 256 项 LUT 与现行 `pow` 结果相同
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 模糊的中间表示从 Float64 降到 Float32 / 整数，峰值从 68 B/px 降到约 20 B/px

- **现状**：`f_svg/src/SvgFilterPrimitives.cj:61-75`（`bytesToFloat`：每像素 4 个 Float64 = 32 B）＋ `:77-141`（卷积输出又一整份 32 B）＋ 输入缓冲 4 B，峰值约 **68 B/px**。按 `maxPixels` 默认 64 Mi（`f_svg/src/SvgBitmap.cj:230`）计算，单次模糊峰值约 4.3 GB
- **方案**：`Array<Float32>`（34 B/px 峰值）或「水平方向先转 Float、垂直方向边算边累加」的单缓冲实现；亦可改三次 box blur 近似，全程只保留两份 UInt8 缓冲
- **预期**：峰值降到 1/2 ~ 1/17；σ 较大时顺带把 O(w·h·r) 降到 O(w·h)
- **代价**：Float32 累积在 σ 大时有量化误差（需与 Float64 结果逐像素比对，容差 1/255）；box blur 近似改变输出（视觉等价性需人工/黄金图确认）
- **验证**：`getAllocatedHeapSize()` + RSS 峰值，512×512 与 2048×2048 两档，σ=8/32；对照现行实现的逐像素差异分布
- **证据状态**：`已有基线（`doc/perf-baseline.md:62`：512×512 σ=8 约 0.5 s 净耗时、单次运行；`doc/perf-baseline.md:80`：512×512 order=3 卷积约 151 ms）`，无改后对照

### [CPU / 堆] `bilinearSvgSample` 每像素分配 4 个数组

- **现状**：`f_svg/src/SvgFilterPrimitives2.cj:1332-1374`。每次采样 `Array<Byte>(4)`（`:1333`）+ `columns` / `rows` / `weights` 三个 4 元素数组（`:1340-1347`）⇒ 每个输出像素 4 次堆分配；`displacementFilterBuffer`（`:1290-1329`）逐像素调用它，512×512 即 104 万次分配
- **方案**：改标量写法（4 个局部变量 × 4 个抽头内联展开），返回值改成写入调用方缓冲的 `addSample` 或返回 `(Byte, Byte, Byte, Byte)` 元组
- **预期**：去掉每像素 4 次分配与随之而来的 GC 压力；`feDisplacementMap` 的耗时与分配量应同步下降
- **代价**：可读性略降；需保持越界抽头按权重 0 处理的语义不变
- **验证**：`cjprof heap` 看分配量，`cjpm bench -O2` 512×512 `feDisplacementMap scale=10` 改前/改后中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `feTile` 的存在性检查提前返回

- **现状**：`f_svg/src/SvgFilterPrimitives.cj:444-475` 全量扫描计算包围盒，调用方只判空（`f_svg/src/SvgFilterRenderer.cj:344`）
- **方案**：新增 `tileHasContent`，命中首个 `alpha > 0` 即返回（见「发现」同名条目）
- **预期**：无内容区域仍 O(n)，有内容区域从 O(n) 降到 O(1)~O(n/2)；`feTile` 前置检查的耗时基本消失
- **代价**：无（调用方不需要包围盒）
- **验证**：`cjpm bench -O2` 1024×1024 `feTile`，改前/改后中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `named` 只保留被引用或显式命名的结果

- **现状**：同「发现」第 2 条，`f_svg/src/SvgFilterRenderer.cj:202,246-247`，峰值 = 原语数 × 区域 × 4 B
- **方案**：先扫 `filter.primitives` 收集所有 `inSource` / `in2` 引用名，执行时只保留「显式 `result` 且被后续引用」的缓冲，其余用完即丢
- **预期**：典型 3~5 原语链的峰值缓冲数从 N 降到 1~2（`SourceGraphic` + 当前结果）
- **代价**：需要一次 O(N) 预扫；若文档 `in` 引用链是动态拼接（不可能，属性静态）则无风险
- **验证**：`getAllocatedHeapSize()` 峰值 + 512×512/4096×4096 两档、5 原语链；同时跑现有 `chainDeterminism` 用例确认像素不变
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 整缓冲复制改用批量拷贝

- **现状**：`f_svg/src/SvgFilterRenderer.cj:106-112`（空滤镜链逐字节复制整幅位图）、`SvgFilterBuffer.copy`（`f_svg/src/SvgFilterBuffer.cj:67-73`）、`offsetFilterBuffer` / `tileFilterBuffer` / `feImageFilterBuffer` 的逐像素循环
- **方案**：对整幅/整行区间用 `pixels[a..b] = other[a..b]`（底层 `memcpy`），逐像素循环只保留给需要坐标变换的原语
- **预期**：空滤镜链从 4×w×h 次逐字节索引降到一次块拷贝；大画布下该段耗时接近内存带宽
- **代价**：无（语义完全等价）
- **验证**：`cjpm bench -O2` 2048×2048 空滤镜链 + `feOffset dx=0`，改前/改后中位数；逐像素断言输出一致
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 16 部分 -->

### [CPU] 渐变采样每次像素重做「href 链 + stops 解析 + 全文档 id 搜索」

- **现状**：`SvgGradientSampler.sample`（`f_svg/src/SvgGradient.cj:220-290`）在每一次采样里：`resolveChain` 新建 `ArrayList` + `HashMap` 并逐步 `findGradientById`（`:456-494`、`:506-528`，后者是对整棵文档的递归搜索）；`resolveStops` 重新 `childrenOf("stop")`、逐条 `tryParseSvgOffset/stop-color/stop-opacity` 并做插入排序（`:400-454`）；`linearRGB` 分支再建一份 `linearStops`（`:282-287`）。调用次数 = 覆盖像素数（`SvgRasterizer.cj:215-218`）
- **方案**：把 `fillGradient`/`strokeGradient` 改成「每 fill 解析一次」：入口处一次性算出链、stops（已排序、可选预转线性光）、`gradientTransform` 逆矩阵与 `t` 所需的 x1/y1/x2/y2（或 cx/cy/r/fx/fy），封装成不可变 `SvgResolvedGradient`，逐像素只做一次点积/开方；`SvgRenderer` 处建 `id → 元素` 映射，替换 `findGradientById` 的全树递归
- **预期**：每像素从「O(链长 × 文档元素数 + stops log stops) 次读 + 3~5 次分配」降为「常数次算术 + 0 分配」。上限估算：若采样占端到端 30%（待测），该项可吃掉其中大部分
- **代价**：新增一个快照类型；`href` 目标在采样期间被修改的行为从「实时读取」变为「fill 开始时快照」（对渲染无实义）
- **验证**：`cjprof record` 跑含 3 个渐变填充、2000×2000 画布、`samplesPerPixel=1/4` 两组；对照 `sample` 自耗时占比与总渲染时间中位数（≥5 轮）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 字体的 GSUB 表被重复解析 4 次

- **现状**：`SvgTrueTypeFont` 构造时对同一份 GSUB 字节调用 3 次 `SvgGsubLigatures.parse`（liga/hlig/clig，`f_svg/src/SvgTrueTypeFont.cj:272-292`）+ 1 次 `SvgGsubContextTable.parse`（`:294-296`）；每次都要走 ScriptList→LangSys→FeatureList→LookupList，其中 `gsubParseLookup` 会用 `GSUB_CONTEXT_FEATURES.contains` 过滤并丢弃非上下文 lookup 的子表
- **方案**：解析一次 `ScriptList/FeatureList/LookupList` 到共享结构，按 tag 建视图（`tag → Array<SvgGsubLookup>`），3 条 ligature 通道与上下文通道各自只消费自己需要的 lookup
- **预期**：字体加载期的 OpenType 遍历次数由 4 次降为 1 次，并天然消除上一条重复逻辑问题
- **代价**：需要一个中等规模的结构重构（`SvgGsubLigatures` 改为视图）
- **验证**：`cjpm bench -O2` 对「解析 100 个嵌入字体」的冷启动场景计时；对照 `parse` 阶段耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `pathDataBounds` 每次调用都物化一份绝对化路径

- **现状**：`pathDataBounds`（`f_svg/src/SvgGeometry.cj:418-421`）第一行 `let absolute = data.toAbsolute()`，而 `toAbsolute`（`f_svg/src/SvgPathData.cj:181`）为每条命令新建 `SvgPathCommand` + `values` 数组；该函数在 `bounds`、`strokeBounds`、`SvgHersheyFont.glyphBounds`、装饰线包围盒等处被反复调用（全仓 25 处引用），单条长路径（数千命令）会额外产生「1 份命令表 + N 个 values 数组」的瞬时峰值
- **方案**：把「相对→绝对」状态机内联进包围盒遍历（现成变量 `currentX/currentY/startX/startY` 已在维护），或对 `SvgPathData` 缓存绝对化结果（带 `commands` 版本号）
- **预期**：路径包围盒计算的峰值分配从 `O(2n)` 降到 `O(1)`（不含返回的 `?SvgBounds`）；对长路径（n ≥ 1e3）意义明显
- **代价**：`pathDataBounds` 复杂度上升（要处理 H/V/S/T 的相对形式）；缓存需失效钩子
- **验证**：同一文档 1000 路径 × 每帧一次 `getBBox`，对比 `getAllocatedHeapSize()` 与 RSS；跑 10 分钟稳态看是否回落
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SvgHersheyFont` 每次 `glyphPath` 重新切分/解析/浮点转换字形串

- **现状**：`glyphPath`（`f_svg/src/SvgHersheyFont.cj:35-74`）对每个字形每次调用都 `splitHersheyStrokes`（`ArrayList<String>` + 子串）、`parseHersheyPoints`（`ArrayList<SvgPoint>`）、`tryParseSvgFloat`，随后每个点再各建一个 `SvgPathCommand` 与 `values` 数组；文本布局按字形逐字调用（`f_svg/src/SvgTextRenderer.cj:931`、`:1992`），`glyphBounds` 又会再算一遍
- **方案**：模块初始化时把 `HERSHEY_GLYPHS` 预解析成 `HashMap<Int64, Array<Array<SvgPoint>>>`（单位坐标），`glyphPath` 只做缩放 + 组装；`glyphBounds` 直接由预解析轮廓求极值，不再走 `pathDataBounds`
- **预期**：单字形布局分配从「O(笔画数) 个 String + 点数个 SvgPoint + 点数个 SvgPathCommand」降为「点数个 SvgPathCommand」，并省掉全部字符串/浮点解析
- **代价**：启动期常量表内存上升（94 字形，量级 KB）；`glyphPath` 返回值仍要新建（公开 API 返回 `SvgPathData`）
- **验证**：10 万字 ASCII 文本 layout 计时 + `getAllocatedHeapSize()` 对照（`-O2`，5 轮中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] GSUB coverage 用区间表示替代展开

- **现状**：见「[严重] GSUB coverage format 2」条目，单 coverage 最坏 65536 个 `Int64`（512 KB），可被 393 KB 输入放大到数十 GB
- **方案**：`gsubCoverage` 返回 `Array<(Int64, Int64)>` 区间集合（或压缩的 `SvgGlyphSet` 结构），`arrayContainsSvgGlyph` 改为二分；`gsubParseLigatureSubtable`/`applyLookupAt` 只做包含判定，不需要展开
- **预期**：最坏内存从 O(展开总数) 降为 O(区间数)（≤ 65535 个二元组，约 1 MB 上限），同时消除 OOM/卡死面
- **代价**：包含判定从 O(1) 哈希变 O(log n)（n ≤ 区间数，实际个位数）；实现需保证原有语义（重复 glyph、无序 range）
- **验证**：构造「65535 段全区间」的合成 GSUB，断言解析 CPU < 100 ms 且常驻内存不随段数线性膨胀
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 17 部分 -->

### [堆内存] data URI 前缀判定与 payload 切片产生多份整串副本

- **现状**：`SvgImageResource.load` 先 `href.toAsciiLower()` 复制整串（上限 `SVG_MAX_BASE64_LENGTH = 32 MiB`，`f_svg/src/SvgImageResource.cj:70`），再 `text[prefix.size..].trimAscii()` 复制 payload，随后 base64 解码再产生约 3/4 大小的字节数组；单张 24 MiB 图峰值约 `32(原 href) + 32(lower) + 32(payload) + 24(bytes)`。
- **方案**：前缀判定改为只比较前 `SVG_DATA_PNG_PREFIX.size` 个字节的小写化切片；payload 直接从 `text[prefix.size..]` 交给解码（若 `trimAscii` 不承担去空白语义就省掉）；`lower` 不再整体生成。
- **预期**：单次解码峰值少 1–2 份 ≈ 32–64 MiB（按 32 MiB 上限估算），大 data URI 文档的尖峰显著下降。
- **代价**：前缀必须按 ASCII 逐字节比较（不能依赖 `toAsciiLower` 整串），代码略增；语义不变。
- **验证**：同输入（1 张 8/16/24 MiB PNG data URI）改前改后 `getAllocatedHeapSize()` 峰值与 RSS 峰值各 5 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SvgInterpolator.path` / `transform` 的 `ArrayList → toArray()` 双份峰值

- **现状**：`f_svg/src/SvgInterpolator.cj:106-125`、`f_svg/src/SvgInterpolator.cj:161-196` 先向 `ArrayList` 逐项追加，再 `toArray()` 复制；元素数在循环前已知（`from.commands.size` / `from.operations.size`）。
- **方案**：直接 `Array<SvgPathCommand>(count, …)` / `Array<SvgTransformOp>(count, …)` 按下标写入，去掉中间容器。
- **预期**：该次插值的峰值对象数从 2× 降到 1×（动画每帧都会调用，帧数高时可累积成持续 GC 压力）。
- **代价**：提前返回 `None` 时需丢弃已分配数组（或先做一遍结构校验再分配）；实现略长。
- **验证**：`cjprof heap` 对比同一动画采样 1000 帧的分配量与峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `svgDirectChildElements` 每个节点都新建 `ArrayList`

- **现状**：`f_svg/src/SvgHitQueries.cj:97-105` 每次调用都把 `children` 里的元素节点收进新 `ArrayList`，两处调用（`:33`、`:60`）在整棵树上是每节点一次。
- **方案**：调用处直接遍历 `element.children` 并 `match`，或改为把 `result` 作为出参复用（`svgHitQueryCollect` 已有 `result` 形参可复用）。
- **预期**：一趟查询少 O(n) 个临时 `ArrayList`（n = 元素数），GC 压力与分配计数线性下降。
- **代价**：遍历代码从“两行 for”变成“for + match”，可读性略降。
- **验证**：1000 / 10000 元素文档各 100 次查询，对比分配计数与 RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `elementAt` 为取首项仍全量物化命中链

- **现状**：`f_svg/src/SvgHitTest.cj:240-262` 先调 `elementsAt` 遍历完整棵树、把所有命中装进 `ArrayList`，再取 `hits[0]`；命中数可达 1e6（`maxElements` 默认值）。
- **方案**：给 `svgHitCollect` 加 early-exit 变体（命中第一个即返回并停止遍历，`svgHitWalk` 用布尔出参冒泡中断）。
- **预期**：重叠元素多的文档上省掉其余全部元素遍历与结果列表分配；理论上限为“从首个命中到遍历结束”的那段成本。
- **代价**：新增一个遍历变体，或给现有函数加 `firstOnly` 参数；需保证返回顺序（后绘制者优先）不变。
- **验证**：`cjpm bench` 同文档（1 层 1k 重叠 rect / 深 50 层树）改前改后中位数，同时断言首项一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgValueCache.get` 的惰性参数每次读数都构造闭包

- **现状**：`f_svg/src/SvgElement.cj:33-40` 的签名为 `get(version, compute: () -> ?T)`，每个属性 getter 传 `{=> readLength(this, "x")}`（本部分 13 处，全模块 61 处 `SvgValueCache<SvgLength>`）。缓存命中也照样构造一次捕获 `this` 的闭包。
- **方案**：把“命中即返回”与“未命中才解析”拆开（如 `peek(version)` + `put`），或让 `get` 接收 `(element, name)` 参数而非闭包。
- **预期**：bbox / 样式求值路径上的属性读取不再每次分配闭包（命中率越高收益越大）。
- **代价**：`SvgElement` 的通用缓存接口改动，触及 61 个调用点；重复逻辑需一次性迁移。
- **验证**：`cjprof record` 跑 bbox 密集场景（10k 元素 `getBBox` 循环），看分配热点与自耗时是否下移；再用 `cjpm bench` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 18 部分 -->

> 不是缺陷，是「还能更好」。本部分没有改前基线，全部标 `无基线（待验证，不进 tasks）`。

### [CPU] marker 派生无条件构建 mid 列表、无条件离散整条 path

- **现状**：`SvgMarkerExpander.expand`（`f_svg/src/SvgMarkerExpander.cj:65`）对每条 contour 都构建 `midPoints` / `midAngles` 并 `toArray()`（`:92-110`），而 `appendMarkers` 在 `style.get("marker-mid")` 为 `None` 时立刻 `return`（`:145-148`）；`shapeContours` 对 `SvgPath` 一律 `flattenPathData(data, identity, 0.25)`（`:263`）全量离散，即使只设了 `marker-start` / `marker-end`。按 2k 顶点 polyline 只设 `marker-start` 估算：白建 2×1998 个槽位 + 2 次数组复制；按 10k 段曲线 path 估算：白做一次完整 flatten（含容差细分）
- **方案**：`expand` 开头按 `style.get("marker-mid").isSome()` 决定是否收集 mid；对 `SvgPath` 在只有 start/end 时改走「子路径端点枚举」（`SvgPathData` 增加只取端点/切线方向的遍历），保留 `flattenPathData` 给 mid 场景
- **预期**：每元素少 2×(n-2) 个临时槽位与 2 次复制；曲线路径在不需 mid 时省一次 O(细分数) 的离散与分配。具体占比未测
- **代价**：需要新的路径遍历 API，且必须与 flatten 的端点语义一致（`C`/`S`/`Q`/`T`/`A` 终点）；与 `marker-mid` 分支的行为差异要补等价用例
- **验证**：`cjpm bench -O2`，同输入 2k / 20k 顶点 polyline 与 10k 段 path，只设 start/end，取中位数与离散程度；同时看分配量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次属性写入都向上遍历到根找 hub，且 listeners 为空时也不短路

- **现状**：`svgNotifyMutation`（`f_svg/src/SvgMutation.cj:110-124`）从被改元素沿 `parent` 链上溯，直到命中 `mutationHub`（只有根有）；`SvgElement` 的每个 `setAttr` / `setAttr(ns)` / `removeAttr` / `appendChild` / `insert` / `remove` 都调用它（`SvgElement.cj:161` 等 7 处）。深度 d 时单次写入 O(d)，批量构建 n 个元素共 O(n·d)；`SvgMutationHub.notify` 在 `listeners` 为空时仍进入循环
- **方案**：(1) `notify` 前 `if (this.listeners.size == 0) { return }`；(2) 元素在挂载时缓存 hub 指针（或根在 `SvgDocument.init` 时下发），reparent 时刷新——把「每次写入上溯」降为「每次写入一次判空」
- **预期**：无监听器（绝大多数渲染/解析场景）时把每次属性写入从 O(d) 降为 O(1)；具体端到端收益需 profile 证明
- **代价**：新增「hub 指针可能陈旧」的不变量，必须覆盖 `appendChild` / `remove` / `parent` 直改（`parent` 是 public `var`，`SvgElement.cj:53`，外部可直接改写）的所有路径，否则通知会丢
- **验证**：`cjprof record` 跑「解析 1 万元素文档」与「批量 setAttr 10 万次」，对比 `svgNotifyMutation` 自耗时占比与总时长
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 19 部分 -->

### [堆内存] `totalLength` 只累加长度，不物化整张段表

- **现状**：`SvgPathMeasure.totalLength`（`SvgPathMeasure.cj:105-112`）先 `buildSegments` 得到 `ArrayList<SvgMeasuredSegment>`，再只读最后一个元素的 `start + length`。单个 `SvgMeasuredSegment` 是 6 个 `Float64` + 对象头（≥ 64 B），段数约等于 `flattenPathData`（`SvgRasterizer.cj:498`）产出的折线顶点数；默认 `tolerance=0.25` 时 `refine=true` 会把容差压到 0.0125（`SvgPathMeasure.cj:74`），顶点数按「弧长 / 容差」量级增长。`buildSegments` 还先整份 `contours: Array<Array<SvgPoint>>` 再转段表，同一份几何存在两份副本。
- **方案**：为长度新增 `accumulate` 路径：遍历 `contours` 时只累加 `sqrt(dx²+dy²)`，不构造段；`pointAt` 才建段表（并可只保留「累计长度 + 端点」两列，去掉 `x0/y0` 冗余）。
- **预期**：`totalLength` 的临时对象从 O(顶点数) 降到 O(1)（除 flatten 自身的顶点数组外），段表峰值完全消失。
- **代价**：新增一个内部函数，`sample` 仍需完整段表；需保证两条路径的浮点累加顺序一致，否则 `getTotalLength()` 与 `getPointAtLength(total)` 的钳制边界会出现极微小差异。
- **验证**：`cjpm bench -O2` 跑长路径（≥ 10k 顶点）1000 次，对照 `getAllocatedHeapSize()` 峰值与 RSS；再用 `SvgElementApiM5_test.cj:177-183` 的等价性断言回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] pattern 失败结果做负缓存，并复用 builder / renderer

- **现状**：tile 只在成功时写缓存（`SvgPatternSampler.cj:330`）；`sampleTileUncached` 在 `293-298`、`305-310`、`223-228`、`209-211` 等分支返回 `None` 时不写任何记录，于是**每个引用该 pattern 的图元都会重新走一遍** `resolveChain` → `buildContent` → `renderDisplayList`。同时每枚 tile 都 `new SvgRenderTreeBuilder()` + `new SvgRenderer(...)`（`SvgPatternSampler.cj:283-304`）。
- **方案**：缓存 `?SvgPatternTile`（含 `None`），key 不变；把 builder/renderer 提升为 sampler 字段在会话内复用（注意 warning 列表需按次清空或改为 append-only 并记录起点）。
- **预期**：失败 tile 的重复构建次数从 O(N 图元) 降到 O(1)；成功路径省掉每 tile 一次对象图构建。
- **代价**：负缓存会掩盖「同一 pattern 因上下文不同而结果不同」的情形，需确认 tile 结果只依赖 `(pattern, bounds, options)`（当前 key 已如此假设）；复用 renderer 需确认其内部无跨 tile 状态。
- **验证**：构造一个 pattern 内含悬空 `clip-path` 的文档，复制 200 份图元，用 `cjprof record` 对照改前改后的 `buildContent` 自耗时与总时长（中位数 5 轮）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合并 5 处链式属性查找与 2 处长度换算，统一走 `toUserUnits`

- **现状**：`effectiveAttr`（`SvgPatternSampler.cj:380-388`）、`resolveLength`（`435-447`）、`effectiveTransform`（`449-461`）、`effectiveViewBox`（`462-474`）、`effectiveAspect`（`476-488`）是同一形状（按链取首个可解析值），`resolveAxis`/`resolveOrigin`（`390-433`）除最后一步合并方式外逐行相同；换算逻辑又是 `SvgLength.cj:205` `toUserUnits` 的子集。
- **方案**：一个 `firstParsed<T>(chain, name, parse: (String) -> ?T): ?T` 覆盖前 4 个；`resolveAxis`/`resolveOrigin` 合并为 `resolveLengthValue(chain, name, base, extent, objectUnits, axis, context)`，内部调 `toUserUnits`。
- **预期**：`SvgPatternSampler.cj` 减少约 90 行重复实现，源码与行为漂移面从 3 套收敛为 1 套（同时修掉上一个一般级发现的 `em`/绝对单位缺失）。
- **代价**：泛型 + 闭包会多一层间接调用（每 tile 十余次，量级可忽略）；`objectBoundingBox` 的「数值即比例」语义需在 `SvgLengthContext` 之外单独表达，避免误用百分比基准。
- **验证**：`cjpm test` 全量回归（`SvgPatternSampler_test` / `SvgPatternViewBoxM4_test` / `SvgPattern_test`）；性能用 `cjpm bench -O2` 对照 1000 枚 tile 的取样总时长。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 避免 `totalLength` 每次重建绝对命令表

- **现状**：`SvgPathMeasure.buildSegments` → `flattenPathData` → `data.toAbsolute()`（`SvgRasterizer.cj:500`），每次 `getTotalLength()` / `getPointAtLength()` 都为每条命令新建 `Array<Float64>`（`SvgPathData.cj:181-294`：`[x, y]` 字面量、`ArrayList` + `toArray()`），即使原路径全是绝对命令也要整份复制外壳。
- **方案**：`SvgPath` 已有 `dCache`（`SvgPath.cj:20`），再加一层 `absoluteCache`（同 `attributesVersion` 失效）；或 `toAbsolute` 对纯绝对路径直接返回 `this`（结构性共享，配合上一节「不得原地修改」的约定）。
- **预期**：重复量长度/取点时省掉 O(命令数) 的数组分配；对逐帧调用 `getPointAtLength` 的交互场景收益最明显。
- **代价**：`SvgPathData` 增加一份缓存（内存换 CPU，命令数 × 每条 values 大小）；共享 `this` 后若调用方原地改 `values` 会污染缓存，需与别名结论一起定契约。
- **验证**：1 万条命令的路径连续 10k 次 `totalLength()`，`cjprof` 看 `toAbsolute` 自耗时占比与分配量；改前改后中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 20 部分 -->

> 均无改前/改后对照数据，按铁律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] PNG 解码改为逐 chunk 消费，去掉 IDAT 全量拼接与整文件读入

- **现状**：`decode(stream)`（`SvgPngDecoder.cj:69-86`）先把整条流读进 `ByteBuffer`（上限 64 MiB），再 `decode(out.bytes())`；`readHeaderChunks`（`243`）用 `idat` 再攒一份完整 IDAT，末尾 `idat.bytes()` 交给 `inflateZlib`，后者又 `compressed[2..size-4]` 复制一份 payload。16 Mi 像素图的最坏组合约为：流缓冲 64 MiB + IDAT 缓冲 64 MiB + payload 64 MiB + 解压输出 64 MiB + 位图 64 MiB。
- **方案**：给 `readHeaderChunks` 加一个"IDAT 直接喂 `DecompressInputStream`"的路径（边读 chunk 边解压到 `ByteBuffer`），或至少让 `inflateZlib` 接受 `ByteBuffer` + 起止偏移，避免 `payload` 切片复制；`decode(stream)` 侧改为增量喂给 chunk 解析器。
- **预期**：峰值从"4 份输入量级"降到"1 份输入 + 1 份输出"，按 16 Mi 像素上限估算约降 120–190 MiB；具体数值需实测。
- **代价**：chunk 状态机与解压器耦合度上升，需要保留"CRC 先校验后解压"的现有语义（否则会先解压坏数据）；改动面在私有函数，不影响公开签名。
- **验证**：同一组 PNG（1×1 / 8×8 / 2048×2048 / Adam7）跑 `getAllocatedHeapSize()` + RSS 峰值对照，并保持 `SvgPngDecoder_test.cj` 全绿（尤其 `chunkStateMachine` 的 CRC 与截断用例）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `readPixel` 每像素分配 4 字节数组

- **现状**：`SvgPngDecoder.cj:525` 每个像素 `Array<Byte>(4, repeat: 0)`，由 `writeScanline`（`502-512`）逐列调用。16 Mi 像素单图 = 16 Mi 次小数组分配，全部短命，只用于把 4 个通道搬到 `bitmap.pixels`。
- **方案**：改成 `readPixel(row, column, ..., out: Array<Byte>, outOffset: Int64)` 直接写入 `bitmap.pixels` 的 `base..base+4`；或让 `writeScanline` 内联 5 种 colorType 的写入分支（`palette` / `tRNS` 查找保持原样）。
- **预期**：单图少 16 Mi 次分配与 64 MiB 分配量，GC 次数与解码耗时下降；降幅需实测（无 profile 数据）。
- **代价**：`readPixel` 变成带外写参数的私有函数，可读性略降；需逐 colorType 保持现有 tRNS / 调色板越界语义（`558-560` 的 `Syntax`）。
- **验证**：`cjpm bench -O2` 对比 4096×4096 RGBA / 调色板 / 灰度 4-bit 三种输入的解码中位数（≥5 轮），同时比对 `SvgPngDecoder_test` 的逐像素断言。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 覆盖率收集：每子扫描线新建容器 + 全量扫边

- **现状**：`computeCoverage`（`318-334`）对每个 `row × samples` 调 `collectHits`（`441`），后者 `new ArrayList<SvgEdgeHit>()` 并遍历**全部** edges，随后 `nonzeroSpans` / `evenOddSpans` 再各建一个 `ArrayList<SvgSpan>`；`sortHits`（`451`）是插入排序。复杂路径（edges 数百、画布上千行）下是 `O(rows × samples × edges)` 次求交 + 每子扫描线 2 个容器分配。
- **方案**：按行维护活动边表（edges 先按 `yMin` 排序，逐行进出），`hits` / `spans` 用复用的 `ArrayList`（`clear()` 后重用，注意 `clear()` 不还物理内存，但避免了反复扩容）；`sortHits` 在 hits 较少时保留插入排序，超过阈值换 `sort`。
- **预期**：求交次数从 `rows × edges` 降到"活动边数 × rows"；分配次数从 `2 × rows × samples` 降到 2。具体收益需 `cjprof` 自耗时占比支撑。
- **代价**：活动边表需要正确的增删边界（`y >= yMin && y < yMax` 的半开区间语义，`444`），改错会直接改变覆盖率；插入排序换 `sort` 需保证相等 x 的相对顺序不影响 winding 计算（`nonzeroSpans` 依赖同 x 事件的次序）。
- **验证**：`cjprof record` 跑 1000 条边的合成路径（画布 1024×1024、samples=4），看 `collectHits` / `sortHits` 自耗时占比；改后用 `SvgRasterizer_test.cj` 全部覆盖率断言 + 随机路径逐像素 diff。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合成阶段每像素两次整数除法

- **现状**：`compositeCoverage`（`408-409`）与 `compositeCoverageShader`（`376-377`）用 `index % width` / `index / width` 反算 `(x, y)`；`coverage.size = width × height`，满配画布 64 Mi 像素即 128 Mi 次整数除法，而循环本身已是线性扫描。
- **方案**：改成嵌套 `for (y in 0..height) { for (x in 0..width) { index++ } }`，行首计算一次 `rowBase`，`x` 直接是内层变量；`compositeCoverageShader` 里的 `colorAt(x, y)` 顺带省掉取模。
- **预期**：去掉 2 次除法/像素；按 64 Mi 像素估算约 1–3 % 端到端（按典型整数除法 20–40 cycle 粗算），需实测确认是否超过噪声。
- **代价**：几乎为零（循环结构等价，索引顺序不变）；需保持 `count > 0` 提前跳过与 `alpha > 0` 的判断顺序。
- **验证**：`cjpm bench -O2` 同输入对照 `SvgBitmap` 输出逐像素一致；`cjprof` 看除法是否仍在热点。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 21 部分 -->

> 均无改前/改后对照数据，按铁律标 `无基线（待验证，不进 tasks）`。

### [堆内存] 离屏层按命令包围盒分配，而不是整画布

- **现状**：`SvgGroupCompositor.createLayer(list.width, list.height, …)`（`f_svg/src/SvgRenderer.cj:145`、`:222`）每次都分配 `width × height × 4` 字节；默认 `maxPixels = 64 Mi` 下单层 256 MiB，`frames` 栈让外层全部常驻（`#4`）
- **方案**：`GroupBegin` 已带 `bounds`/`clipBounds`（`SvgRenderTree.cj:606/793`），用其设备空间 AABB 与画布求交后再分配；`SvgGroupCompositor.composite` 增加偏移参数，`applyEffects` 内的 clip/mask 覆盖率按偏移后的尺寸渲染
- **预期**：典型场景（小图标画在大画布上、局部 `opacity` 组）层内存从 `O(画布)` 降到 `O(元素包围盒)`；满配深嵌套场景峰值按包围盒面积比例下降。具体倍数需实测
- **代价**：合成与 clip/mask 的坐标系要带上偏移，`clipBitmapToRect`/`applyQuadCoverages` 需接受子矩形；`bounds` 缺失时必须保守退回整画布（现有部分 `GroupBegin` 无包围盒）
- **验证**：同文档（含 8 层嵌套 `opacity` 组、1024²/4096² 两种画布）改前后 `getUsedHeapSize()` 峰值与 RSS 对照，并保持 `SvgRenderer_test` / `SvgOverflowM4_test` 全部像素断言逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `applyQuadCoverages` 用真交集缓冲 + 复用 quad 蒙版位图

- **现状**：缓冲按并集分配（`SvgRenderer.cj:893-896`，最坏整画布 1 B/px），每个 quad 再新建一个 `SvgBitmap(box.width, box.height)`（`:904`，4 B/px）并立即丢弃
- **方案**：缓冲区按 AABB 交集分配（`left=max`、`right=min`）；quad 蒙版位图按最大 quad 尺寸分配一次、逐 quad 清零复用（或直接用覆盖率 `Array<Byte>` 而不建 `SvgBitmap`）
- **预期**：多 quad 场景缓冲从"最外层 quad 面积"降到"交集面积"，每个 quad 少一次 4 B/px 分配；具体收益需实测
- **代价**：交集为空要提前 `clearBitmapAlpha`；复用蒙版需保证清零（`clear()` 不还内存也不置零，必须显式覆写）
- **验证**：`SvgOverflowM4_test.nestedRotatedQuadsIntersect` / `rotatedMarkerClip` 改前后逐像素一致；再加一条"交集为非矩形"的用例
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sampleImage` 每像素 3–4 次小数组分配

- **现状**：`SvgRenderer.cj:1174`（`transparent`）、`:1181`（`result`）每次调用都新建；双线性路径再新建 `weights` / `columns` / `rows` 三个数组（`:1202-1209`）。`drawImage` 的像素循环（`:1136-1164`）对目标矩形内每个像素调用一次，1000×1000 的 `<image>` 即 100 万次调用 × 4 个数组
- **方案**：改为 `sampleImage(source, mapping, u, v, bilinear, out: Array<Byte>)` 写外参数；`transparent` 提为文件级 `let`；双线性权值/行列改为标量局部变量（`x0/x1/y0/y1` 与 4 个 `Float64`），去掉三个数组
- **预期**：单图少 400 万次分配、约 12 MB 分配量（1000×1000 场景），GC 次数与取样耗时下降；降幅需 `cjprof` 实测
- **代价**：`sampleImage` 变私有带外写签名，可读性略降；需保持 `alpha <= 0` 时返回全透明与 `clampImageIndex` 的边界语义
- **验证**：`cjprof record` 跑 1024×1024 源图放大到 2048×2048，看 `sampleImage` 自耗时与 GC 占比；`cjpm bench -O2` 对照 `imageRenderingModes` / `preserveAspectRatioModes` 的像素断言
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `build()` 最多做 3 次全量样式解析

- **现状**：`SvgRenderTree.cj:289-294`（按 viewport 尺寸）、`:306-311`（`width/height: auto` 时按内容尺寸）、`:315-320`（按 `logicalWidth/Height` 无条件再算一次）。`SvgStyleResolver.compute` 是整树遍历 + 选择器匹配，第三次在"非 auto 且未指定 width/height"时与第一次参数完全相同
- **方案**：先判断是否需要 auto 分支（`widthAuto/heightAuto && options.width <= 0 && options.height <= 0`），仅在需要时做第二次；其余路径合并为一次"先按最终 media 尺寸算"——即先确定 `logicalWidth/Height` 再 compute（auto 分支仍保留两次，但把第三次删掉）
- **预期**：常见路径（显式尺寸或根 `viewBox`）样式解析次数 3 → 1，`build` 端到端按样式解析占比下降；需 profile 数据支撑
- **代价**：`auto` 分支依赖"按 300×150 首算"来决定内容尺寸，顺序不能简单合并；需要保证 `resolver.warnings` 不因计算次数变化而重复/丢失
- **验证**：`cjprof record` 跑 10k 元素文档的 `build`，看 `SvgStyleResolver.compute` 占比；改后 `SvgRenderer_test` + `SvgAutoSizeM6_test` 逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `walkContainer` 每个容器复制一遍子指令列表

- **现状**：`SvgRenderTree.cj:769`（每容器 `new ArrayList<SvgDisplayCommand>()`）+ `:802-804`（逐个 `commands.add`）。子指令在每一层祖先都被复制一次 ⇒ 命令数 × 嵌套深度的搬移量
- **方案**：给 `commands` 记录"段起点"，子内容直接追加到父列表，只在需要包裹 `GroupBegin/GroupEnd` 时插入；或改成"先写子、再在起点位置插入组指令"（`ArrayList` 头部插入是 O(n)，需换成双端结构或两段拼接）
- **预期**：深嵌套文档（几百层 `g`）的构树搬移量从 O(n·depth) 降到 O(n)；需 profile 证明构树耗时占比
- **代价**：组指令必须严格包住子段，插错位置会破坏渲染顺序；测试里的"文档顺序保持"（`SvgRenderTree_test.displayNoneAndOrder`）要保留
- **验证**：`cjpm bench -O2` 对比 500 层嵌套 + 10k 图元的 `build` 中位数（≥5 轮），并比对显示列表逐条 `kind/tag/matrix` 一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每个 marker 实例都做一次整树路径遍历

- **现状**：`SvgRenderTree.cj:1304-1308` 在 marker 实例循环内调用 `svgElementPath(Some(context.root), instance.marker)`，实现是 `findSvgElementPath` 从根递归找 identity（`:1789-1813`）⇒ 单条路径上的 K 个 marker 就是 K 次整树遍历，仅用于 warning 标签
- **方案**：标签在 `SvgMarkerExpander.expand` 阶段一次性算好（那里已知 marker 元素），或惰性生成——只有 `sessionGuard.enter` 返回 false / 抛错时才构造 label（`enter` 目前把 label 当必填参数，可改成 `() -> String`）
- **预期**：marker 数量多的文档省掉 O(K·N) 的遍历；需实测占比
- **代价**：`SvgRenderGuard.enter` 签名变化（内部类，影响 `SvgPatternSampler` 一处调用）；惰性标签要在 warning 路径上保证文案一致
- **验证**：`cjprof record` 跑 1000 个 marker 的文档；改后 `SvgOverflowM4_test` 的 marker 裁剪用例与 warning 文案断言不变
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 22 部分 -->

> 以下均为「还能更好」，不是缺陷。**没有改前基线 + 改后对照，一律标 `无基线（待验证）`，不得写成收益结论。**

### [堆内存] `cascade` 每次求值为单元素新建 4-5 个 `HashMap` 与一条元素路径字符串

- **现状**：每个元素一次 `cascade`（`f_svg/src/SvgStyleResolver.cj:237-400`）新建 `best`、`customBest`、`custom`、`values`、`sources`、`varExpressions` 六个容器，并调用 `element.elementPath()`（`240`）拼一条仅用于告警的路径串；`values` 再按 `SVG_PROPERTY_TABLE` 全量填 ~100 项。以 1 万元素文档估算，单次 `compute` 即 6 万个容器对象 + 1 万条路径串。
- **方案**：`elementPath` 改为惰性求值（只在真的要 `warnings.add` 时拼，或传入 `StringBuilder` 前缀）；`best`/`customBest` 用「每层复用 + `clear()`」的 scratch（注意 `clear()` 不归还容量，见 `mem §3.2`，应保留容量而不是反复扩容）；`values`/`sources` 直接构造进 `SvgComputedStyle`，不再先建 map 再拷贝。
- **预期**：每元素容器分配从 6 个降到 2-3 个；元素路径串分配降到 0（无告警时）。具体字节量需实测。
- **代价**：scratch 复用会让 `cascade` 不可重入（需保持每调用一份或线程封闭）；`elementPath` 惰性化会改变告警文本拼装位置。
- **验证**：同一 1 万元素文档 `cjpm bench -O2` 前后对照，取 `getAllocatedHeapSize()` 峰值与 GC 次数中位数（≥5 轮）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 计算样式全量存字符串，`values` 里大量值等于属性初值

- **现状**：`values[name] = normalized ?? spec.initial`（`f_svg/src/SvgStyleResolver.cj:373`）对 `SVG_PROPERTY_TABLE` 每个属性都存一条 `String` 引用，未使用的属性也占位；`custom` 属性还会把父元素全部自定义属性复制进每个后代的 `values`（`390-392`）。
- **方案**：`SvgComputedStyle` 改为「仅存与初值不同的项 + 初值表按属性名共享」，自定义属性改为沿 `parent` 链查找而不是复制。
- **预期**：单元素 `HashMap` 条目数从 ~100 降到实际使用数（典型文档 <20）；自定义属性不再按层数平方复制。
- **代价**：`get` 需要一次父链查找（深度 = DOM 深度），需要缓存或限制链长；`customProperties()` 语义变化需要同步文档。
- **验证**：`SvgComputedStyle` 实例的保留大小（`cjprof heap`）+ 多文档渲染的 RSS 稳态。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `getBBox` 每次调用新建 resolver 做整文档级联

- **现状**：`SvgElement.getBBox`（`f_svg/src/SvgElement.cj:455-471`）每次都 `SvgStyleResolver().compute(root, ...)`，即对整棵树重跑级联（含 `<style>` 收集与选择器匹配）。若调用方对 n 个元素逐个 `getBBox`，复杂度为 O(n²)。
- **方案**：提供 `SvgDocument` 级的样式缓存（或在 `SvgBBoxOptions` 里接受现成 `SvgComputedStyleTree`），`getBBox` 命中缓存时直接复用；`SvgSnapshotM5_test.elementApiSceneAssertions`（`SvgSnapshotM5_test.cj:177-185`）这种逐元素查询场景收益最直接。
- **预期**：n 次 `getBBox` 从 n 次全树级联降为 1 次；端到端收益取决于级联占比（未测）。
- **代价**：缓存需要失效策略（与上文 `prepare` 缺失效同源）；API 增加参数。
- **验证**：构造 5k 元素文档，循环 `getBBox` 5k 次，`cjprof record` 看 `cascade` 自耗时占比，`-O2` 前后中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 圆角连接每顶点最多生成 256 边形，dash 每片段再分配点数组

- **现状**：`addJoin` 对 `Round`/`Arcs` 直接调用 `circlePolygonForStroke(..., 0.25)`（`f_svg/src/SvgStrokeOutliner.cj:318-320`），`circlePolygonForStroke` 的段数上限 256（`404-406`）；`dashPieces` 每片段 `current.toArray()`（`613`、`626`）再各分配一份点数组。
- **方案**：圆角连接的扇形只覆盖外角范围（按 `dot`/`cross` 求夹角，而不是整圆）；dash 片段直接以「点区间」形式传给 `outlineOne`，避免 `toArray` 复制。
- **预期**：折线每顶点点数从 ≤256 降到与夹角成正比（直角连接约 1/4 圆周）；dash 场景减少一次整段复制。
- **代价**：扇形起止角计算与 `sign` 判定共用同一套法线逻辑，回归风险集中在 join 视觉；需要逐元素快照对照（`SvgSceneByteBaseline_test` 容差 0 会直接暴露差异）。
- **验证**：`cjpm bench -O2` 对「多顶点折线 + round join」与「长虚线路径」两组输入，记录轮廓点数、总耗时中位数与峰值内存。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 23 部分 -->

### [堆内存] `SvgTextElement` 的 11 个 `SvgValueCache` 常驻对象改为按需创建

- **现状**：每个 `text` / `tspan` / `textPath` 元素构造时就分配 11 个 `SvgValueCache<T>` 实例（`f_svg/src/SvgTextElement.cj:98-108`），每个实例 3 个字段（`version: Int64` / `cached: ?T` / `hasCached: Bool`，`f_svg/src/SvgElement.cj:28-41`），典型文本只用得到 `x` / `y` / `textAnchor` / `fontSize` 中的少数几个
- **方案**：改成 `private var xCache: ?SvgValueCache<Array<SvgLength>> = None`，`get` 时判空惰性创建（或者用一个 `SvgValueCache` 按 key 分槽），把「11 个对象」压到「实际用到的 2-4 个」
- **预期**：元素对象图从 11N+1 个堆对象降到 ≤5N+1（对象数静态可推），10k 个 tspan 的文档少约 6 万个短命对象；峰值/常驻字节收益需实测
- **代价**：每个 getter 多一次 `Option` 判空与首次赋值（纳秒级）；`?SvgValueCache<T>` 的读写需要 `mut` 语义，代码量略增
- **验证**：同一 10k-tspan 文档，`cjpm` `-O2`，改前/改后各 5 轮取中位数，比较 `getAllocatedHeapSize()` 与 RSS 峰值
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `place()` 去掉多余的一次 advance 复制，并预分配结果容器

- **现状**：`f_svg/src/SvgTextPathLayout.cj:91-94` 先 `Array<Float64>(advances.size, repeat: 0.0)` 再逐元素拷贝；`method != Stretch` 时这次复制纯属浪费（`advances` 全程只读）；`:122` 的 `ArrayList<SvgTextPlacement>()` 未按字形数预分配，n 个字形会触发多次扩容
- **方案**：改为 `let adjusted = if (method == Stretch) { advances.clone() } else { advances }`（`stretch` 分支仍写 `adjusted[index] = …`，需要 `var adjusted` 与克隆）；`ArrayList<SvgTextPlacement>(advances.size)` 预分配
- **预期**：每次 textPath 排版少一次 O(n) 复制与 O(log n) 次扩容复制（n = 字形数）；端到端收益需 bench 证明
- **代价**：`adjusted` 的别名关系要写清（非 stretch 路径不得原地修改），语义无变化
- **验证**：`cjpm bench -O2`，输入 1k / 10k 字形、路径 100/1000 段的 textPath 排版，改前改后各 5 轮取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 24 部分 -->

> 以下均非缺陷；无改前基线的只能作为下一轮补数据的对象。

### [堆内存] `sample()` 每帧深拷贝整棵文档

- **现状**：每次 `sample(time)` 调 `cloneSvgDocument`（`SvgTimeline.cj:212`、`:1261-1307`）复制全部元素、属性、文本节点与 prolog/epilog；60 fps 下每秒 60 份完整文档副本，单帧存活期 = 一次渲染
- **方案**：① 允许调用方传入可复用的目标文档/对象池（`sampleInto(target)`），只重置被动画写过的属性；② 或按「动画覆盖集合」做写时复制：只深拷贝 `specs` 涉及的子树 + 祖先链
- **预期**：单帧分配量从 O(文档节点数) 降到 O(被动画元素数 + 祖先链)，节点数 1 万、动画 10 个的文档可降两个数量级（需实测确认）
- **代价**：`sample` 的「返回独立文档」契约需要保留旧入口；写时复制要维护共享子树与 `parent` 指针的正确性（本模块已有 `cloneSvgElement`，改动面集中在 `SvgTimeline`）
- **验证**：`getAllocatedHeapSize()` 差值 / RSS + 每帧耗时中位数（`-O2`，同文档、同 300 帧序列，取 P50/P95）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sample()` 每帧 O(n²) 排序 + 每个动画重新扁平化路径

- **现状**：`sortedAnimationSpecsByBegin`（`SvgTimeline.cj:1193-1211`）是 O(n²) 选择排序并每次新建 `Array<Bool>` + `ArrayList`，每帧调用一次（`:213`）；`sampleMotion`（`:1145-1184`）每个动画每帧 `flattenPathData(path, …, 0.1)` 全量重算折线
- **方案**：① `init` 里排一次序并缓存（`begin` 只在显式 `begin()/fireEvent` 时才变，可失效重建）；② 把扁平化后的折线按 `spec` 缓存（路径与容差不变即可复用），`sampleMotion` 只在折线上做线性推进
- **预期**：排序从每帧 O(n²) 降为一次 O(n log n)；路径扁平化从每帧 O(段数 × 1/容差) 降为一次（需实测确认占比）
- **代价**：需要失效逻辑（`begin` 触发后重建排序；路径缓存随 `AnimateMotion` 规格生命周期）
- **验证**：`cjprof record` 跑 300 帧、10/100/1000 个动画三档，比较 `sample` 自耗时与帧 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 竖排分列用线性查找 + 选择排序，整体 O(n·k + k²)

- **现状**：`logicalColumns` 去重（`SvgTextRenderer.cj:595-600`，`containsTextColumn` 线性扫描）、列排序（`:601-615` 选择排序）、每字符 `textColumnIndex`（`:620`，再次线性扫描）；n = 字形数，k = 不同 `x` 列数
- **方案**：用 `HashMap<Float64, Int64>` 一次遍历完成去重与「列 → 序号」映射，列序直接 `Array.sort()`；`textColumnIndex` 改为查表
- **预期**：k≈n 时从 O(n²) 降到 O(n log n)；单段竖排文本 5000 字、5000 列的场景比较 layout 耗时中位数
- **代价**：`Float64` 作 `HashMap` 键需与现有 `==` 语义一致（当前就是精确相等比较，语义不变）
- **验证**：`cjpm bench -O2`，输入 100/1000/5000 字三档，对比 layout 中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 25 部分 -->

> 不是缺陷。下列结论均无改前/改后基线，只能作为下一轮补数据的候选，不进 `todo.md` / `tasks.md`。

### [堆内存] 合并「解析后再缩放」的二次复制

- **现状**：`glyphPath` / `pathById` 先由 `parseGlyph` 生成一份未缩放的 `Array<SvgPathCommand>`（`SvgTrueTypeFont.cj:432` / `:464`），再逐条 `scaleTtfCommand` 生成第二份（436–438 / 467–470）。每条 `SvgPathCommand` 含一个 `Array<Float64>`（2–4 个元素），两份同时存活到方法结束；复合字形还要在父级再拼一份（694–696），峰值可达 2–3 倍命令数。
- **方案**：把 `scale`（以及可选 `a,b,c,d,dx,dy`）作为参数传进 `parseGlyph` → `parseSimpleGlyph` → `appendTtfContour`，在生成坐标时一次算到位；删除 `scaleTtfCommand`。
- **预期**：每个字形少 1 份命令数组（约 `命令数 × (24 + 8×坐标数)` 字节）；对 1000 字形的文本渲染，峰值分配量约减一半。具体比例无基线。
- **代价**：`parseGlyph` 签名变长（缩放 + 复合变换要按「先子变换、后整体缩放」顺序组合），实现复杂度上升；`parseCompositeGlyph` 内需把父级变换与缩放预先相乘。
- **验证**：同一文档渲染 1 次 / 100 次的 `getAllocatedHeapSize()` 对照 + RSS 峰值；`cjpm bench -O2` 同输入。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 装载期 GSUB 表解析 4 次改为 1 次

- **现状**：`SvgTrueTypeFont.parse` 对 `GSUB` 调用 `directory.table("GSUB")` 4 次并各跑一遍 `SvgGsubLigatures.parse` / `SvgGsubContextTable.parse`（272–297），每次都要重扫 ScriptList / FeatureList / LookupList；`kern` / `GPOS` / `OS/2` 又各查一次表。
- **方案**：一次扫描 GSUB 的 ScriptList/FeatureList，按 featureTag 收集需要的 Lookup 索引，再产出 `liga` / `hlig` / `clig` / context 四个视图；`table(tag)` 结果缓存在局部 `HashMap` 里。
- **预期**：字体装载时间随 GSUB 大小线性下降（若 GSUB 占装载耗时 30%+，装载可省约 1/4）。占比未测。
- **代价**：`SvgGsubLigatures.parse` 需暴露「按已选 Lookup 构建」的入口，改动跨 3 个类型；风险是四个视图共享只读数据后生命周期被拉长（本来也随字体常驻，影响小）。
- **验证**：对 100 个真实字体计时（中位数 + P95），`cjprof record` 看 `parse` 自耗时占比；`-O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 26 部分 -->

### [堆内存] 写入路径省掉整棵 `XmlElement` 的深拷贝

- **现状**：`SvgWriter.write(document)`（`f_svg/src/SvgWriter.cj:74`）先 `document.toXmlDocument()`，而 `toXmlDocument` → `SvgElement.toXmlElement`（`f_svg/src/SvgElement.cj:386-409`）为每个元素新建 `XmlElement`、为每个属性新建 `XmlAttribute`、为每个子节点新建 `XmlNode.ElementNode` 包装。一份已解析的文档在写入期间同时存在两棵等大的树（原 `SvgElement` 树 + `XmlElement` 树），活到 `write()` 返回
- **方案**：给 `SvgWriter` 加一条直接遍历 `SvgElement` 的输出路径（href 归一化与 `toXmlElement` 合并为一次遍历），或让 `SvgDocument` 缓存上一次 `toXmlElement()` 结果并复用（文档不可变时）；至少让 `normalizeElementHrefs` 在拷贝阶段顺带完成，省掉第二趟
- **预期**：写入峰值减少约一份树（对象数 ≈ 元素数 + 属性数 + 子节点数），大文档下与文档规模同阶；具体比例无数据
- **代价**：`SvgWriter` 需要处理两种树（`SvgElement` / `XmlElement`），接口面变大；缓存方案需明确「文档被修改后失效」的语义
- **验证**：同输入（1 MB / 10 MB SVG 各 20 轮）下 `getAllocatedHeapSize()` 与峰值 RSS 对照，`-O2`，中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `writeSvgString` 少一次输出副本

- **现状**：`f_svg/src/SvgWriter.cj:223-227`：`ByteBuffer` 累积全部字节 → `buffer.bytes()` 取数组 → `String.fromUtf8(...)` 再建一个字符串。峰值同时持有「缓冲区 + 字节数组 + 字符串」三份
- **方案**：`ByteBuffer.bytes()` 是否返回内部数组的拷贝未在本地文档确认（`待确认`），若确为拷贝，改为一次性 `String.fromUtf8` 之前不复制（用 `ByteBuffer` 的可读切片 / `StringBuilder` 直写）；或将 `writeSvgString` 降级为「`OutputStream` 版本的薄封装」，让大文档调用方走流式
- **预期**：峰值从约 3× 输出大小降到约 1×–2×，具体取决于 `bytes()` 语义
- **代价**：若改用 `StringBuilder` 需要 `XmlWriter` 支持 `String` 输出，改动面在 `f_xml`（范围外）
- **验证**：`String.fromUtf8` 前埋点 `buffer.bytes().size`，配合 heap 采样跑 20 轮
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] href 归一化与树拷贝合批，省掉一次全树遍历

- **现状**：`write()` 对同一棵树做了 `toXmlElement` 深拷贝 + `normalizeElementHrefs` 全树遍历（`f_svg/src/SvgWriter.cj:75`、`:128-168`）+ `XmlWriter` 输出遍历。其中 `normalizeElementHrefs` 每层还要对每个元素做一次 `firstHrefIndex` 线性扫描（`:181-188`），属性少时是常数，但整趟遍历与元素数成正比
- **方案**：在 `SvgElement` → `XmlElement` 转换时顺带做 href 归一化（每个元素只扫一次属性），删除独立的第二趟；或把 `firstHrefIndex` + 去重合并成单趟，从「先找第一个再倒序删」改为一次正序过滤
- **预期**：写入路径的元素遍历次数从 3 降到 2；省下的绝对值取决于树规模，无占比数据
- **代价**：`toXmlElement` 增加 `options` 依赖（或新增内部重载），`SvgElement.toXmlElement()` 的公共语义需保持不变
- **验证**：`cjpm bench -O2` 对 1 MB / 10 MB 文档量 `writeSvgString` 耗时，改前改后各 20 轮取中位数与 P95；`cjprof record` 确认 `normalizeElementHrefs` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 解析覆盖率累加器在 8 MiB 门限内走 local region 能显著压低峰值内存（README:37 的承诺） | `f_svg/src/SvgAnalyticRasterizer.cj:81-88`、`:200-201` | 改前 / 改后峰值内存与分配量 | 1024×1024 解析覆盖率场景，`-O2`、同输入、5 轮取中位数，记 `getUsedHeapSize()` / RSS 与 `getAllocatedHeapSize()`（`getAllocatedLocalObjectSize()` 会暂停所有仓颉线程，只在轮间采样） |
| 2 | 512 层深度上限下的递归构建（README:113 / `SvgOptions.cj:66`）在耗时与线程栈占用上已接近边界 | `f_svg/src/SvgBuilder.cj:127`（递归 `buildSvgElement`） | 512 层文档的解析耗时、峰值栈使用 | 生成 512 层嵌套 `<svg>` 文档，与 64 层对照计时；另用受限线程栈复现，确认是否栈溢出 |
| 3 | README 宣称「1230 条用例全绿、构建 0 warning」在当前 M7 代码上仍成立 | `f_svg/README.md:533`、`README_en.md:543` | `cjpm test` 实际通过数与 `cjpm build` 自身 warning 数（本轮只读，未跑构建） | WSL Ubuntu 下 `source cangjie.sh && cd f_svg && cjpm test`、`cjpm build`（`-O2`），记录通过数与 warning 明细 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 换成 289 KB 样本后，M1 解析/序列化是否仍为 53.8 / 24.8 ms | `f_svg/doc/perf-baseline.md:14-20` | 新样本上的耗时分布 | 跑 `SvgRoundTrip_test.cj:65` `largeSampleSmoke`，`-O2`，3 轮取中位数与极差，记录 `MonoTime` 分段（parse / write） |
| 2 | CSS 匹配阶段是否真的 > 20 ms（当前只有 compute 全量上界） | `f_svg/doc/perf-baseline.md:29-33` | 匹配阶段自耗时 | 在 `SvgStyleResolver` 匹配循环内埋点，1000 规则 × 1000 元素场景，`-O2`，记录匹配 / 级联 / 快照三段 |
| 3 | 1024²「渐变 + 裁剪」7569 ms 是否集中在整幅裁剪蒙版重绘 | `f_svg/doc/perf-baseline.md:47` | 各阶段自耗时占比 | `cjprof record` 跑该基准，看 mask/clip 覆盖率生成 vs 渐变采样 vs 合成占比 |
| 4 | 单次 `getBBox()` 约 51 ms 是否属于主路径热点 | `f_svg/doc/perf-baseline.md:126` | 调用频次与端到端占比 | 1000 元素文档上 profile 一次 `querySelectorAll` + 逐元素 `getBBox`，统计样式树重算次数 |

<!-- 第 3 部分 -->

无。本部分没有性能 / 内存对象，也没有需要补测才能成立的猜测；文档侧的 11 条结论均已用「文件行号 + 源码行号 + 全文检索 + 两副本 diff」静态取证，无需补数据。

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 路径长度段表的最坏放大倍数（#5） | `f_svg/src/SvgPathMeasure.cj:66-103`、`SvgRasterizer.cj:692-706` | 单条曲线实际点数分布、段表峰值 RSS | 构造 1 KiB / 16 KiB 的病理 `d`（大坐标 + 小容差），测 `totalLength` 的分配量与峰值 RSS；同时给 `-O2` 下耗时 |
| 2 | `side="left"` 取 +y 是否符合 SVG 2 的 side 语义（#15） | `svg-text/spec.md:112`、`:224`；`SvgTextPathLayout.cj:147-156`；`SvgTextPathExtensionM4_test.cj:63-72` | SVG 2 `textPath side` 的法线定义、参考实现输出 | 查 SVG 2 规范文本；用 resvg / Chrome 渲染同一水平路径 + `side="left"`，比较偏移方向 |
| 3 | 基线属性按可继承实现后与浏览器/其他渲染器的像素差异（#3） | `svg-css/spec.md:12-13`、`SvgComputedStyle.cj:119-121` | 同输入下差异像素数与分布 | `<g dominant-baseline="middle"><text>A<tspan>B</tspan></text></g>` 分别用本模块与 Chrome headless / resvg 渲染，比对差异像素 |
| 4 | 文档声称的测试规模与"全绿"（M3 525/533、M4 710） | `add-f-svg-m3/verification.md:598`、`:626`、`tasks.md:144` | 本轮未跑构建（铁律），无实测 | WSL `source cangjie.sh && cjpm test`，记录 `TOTAL / PASSED / FAILED`，与文档数字对照 |
| 5 | `glyphPath` 每次重新解析 `glyf`、滤镜卷积/湍流在 512×512 的成本 | `SvgTrueTypeFont.cj:459`、`SvgFilterPrimitives2.cj:1006-1041`、`:1172-1200` | 自耗时占比、P95 | `cjprof record` 渲染 10 万字 TTF 文本与 512×512 卷积/湍流（`-O2`），对照缓存/优化版本；给绝对值、中位数、离散度 |

<!-- 第 5 部分 -->

> 无性能数据支撑，**不进 `todo.md` / `tasks.md`**，仅供下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getBBox` 单次约 51 ms（1000 元素文档，含样式树重算）对循环调用方已是热点，`svg-geometry` 规格却无成本提示 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md:11`；基线 `f_svg/doc/perf-baseline.md:126` | 调用频次与端到端占比；缓存版对照 | 1000 元素文档循环 100 次 `getBBox`，对比「每次重算」与「按根缓存样式树」两版中位数（`-O2`，同机） |
| 2 | 含 `@media` 的文档在 `build` 阶段会执行 3 次全量样式计算，占比可能显著 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md:89`；实现 `f_svg/src/SvgRenderTree.cj:289-320` | 单次 `compute` 自耗时占比 | `cjprof record` 渲染 1000 份含 `@media` 文档，统计 `SvgStyleResolver.compute` self time |

<!-- 第 6 部分 -->

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `design.md` D8 承诺「256 项查表缓存避免逐像素 `pow`」未实现，`linearRGB` 渐变每采样点做 3 次 `pow` 反变换，可能是渐变填充热点 | `f_svg/doc/spec/add-f-svg-m6/design.md:118`；`f_svg/src/SvgGradient.cj:287`（每样本 `svgColorFromLinear`）、`:591-609`（`pow`） | 该分支自耗时占比与相对 `sRGB` 的倍数 | `cjpm bench -O2` 同几何分别声明 `sRGB` / `linearRGB`，1000×1000 全屏线性渐变，取中位数；再用 `cjprof record` 看 `svgChannelFromLinear` self time |
| 2 | `getIntersectionList` / `checkEnclosure` 每次调用重算整棵样式树，1000 元素文档下已是 60–120 ms，更大文档（`maxElements` 默认 1e6）可能成为交互查询瓶颈 | `f_svg/doc/perf-baseline.md:131-142`（改前基线）；`f_svg/src/SvgHitQueries.cj:20-48` | 改后对照（缓存 / 复用样式树）与 5000 / 10000 元素的曲线 | 同机 `-O2`，1000 / 5000 / 10000 元素各跑 30 次取中位数与 P95，对照「复用同一 `SvgComputedStyleTree`」的实现 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 多个不同 href 的外部文档在单次渲染中聚合占用远高于单份 16 MiB 上限 | `src/SvgRenderTree.cj:255,914-924` | 峰值 RSS / heapUsed 与条目数的关系 | 构造 200 个 `use` 指向 200 份各 8 MiB 的 provider 文档，跑单次渲染，记 `getAllocatedHeapSize()` 与 RSS 峰值 |
| 2 | 同一文档重复渲染会重复解析外部文档（缓存只存活于单次渲染），parse + 样式计算占比可观 | `src/SvgRenderTree.cj:255,900-927` | `cjprof` 中 parse 自耗时占比 | 对含 20 个外部文档的文档连续 render 100 次，`cjprof record` 取 `SvgParser.parse` 与 `SvgStyleResolver.compute` 自耗时占比 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `calc()` 求值在「样式表含大量 `calc()`」的文档里占计算样式耗时的显著比例（>10%） | `f_svg/src/CssCalc.cj:55-65`（入口）、`f_svg/src/SvgStyleResolver.cj:536` | 自耗时占比、调用次数、输入规模 | `cjprof record` 跑一份 1 万个 `calc()` 声明的文档，`cjprof report` 看 `evaluateCssCalc` / `parsePrimary` self time |
| 2 | `CssCalcValue` 的短命对象是 `SvgStyleResolver.compute` 的主要分配来源之一 | `f_svg/src/CssCalc.cj:39-47` | 分配字节占比、GC 次数 | 基准进程内 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，同一输入改 `struct` 前后对照 |
| 3 | 一元符号递归的崩溃阈值在 5 万～20 万层之间（决定该缺陷在真实上传场景的触发成本） | `f_svg/src/CssCalc.cj:163-177` | 默认线程栈大小与实际崩溃层数 | 单独可执行程序二分 `K`（`calc(` + K 个 `-` + `1px)`），记录首次崩溃的 K 与线程栈配置；平台栈大小以官方文档为准 |

<!-- 第 9 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `byClass` 全键扫描是 `candidates` 的主要成本（类选择器 >100 条、元素 >1 万时） | `f_svg/src/CssSelector.cj:434-442` | `candidates` 自耗时占比、每元素平均类键比较次数 | `cjprof record` 跑 1 万元素 × 200 条类选择器文档，`cjprof report` 看 `candidates` / `cssClassListContains` self time |
| 2 | 候选取集是 `SvgStyleResolver.compute` 的主要分配来源之一 | `f_svg/src/CssSelector.cj:423-424` | 分配字节占比、GC 次数 | 基准进程 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，改复用缓冲前后对照 |
| 3 | 空白 token 合并的字符串拼接在「大量注释分隔空白」的样式表上是 O(k²) 复制 | `f_svg/src/CssLexer.cj:133-142` | k（空白组数）与单次 `tokenize` 耗时曲线 | 构造 `a /*c*/ /*c*/ … b`（k = 1e3 / 1e4 / 1e5）测 `tokenize` 耗时，看是否随 k 超线性 |
| 4 | 256 段通配后代选择器的实际挂死阈值（多少段 × 多少层开始不可接受） | `f_svg/src/CssSelector.cj:285-297` | 实际耗时随 (段数, 深度) 的增长曲线 | 固定 128 层嵌套文档，段数从 8 递增到 32，测单次 `matches` 耗时，找拐点 |

<!-- 第 10 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 行内两两求交（O(A²)）与逐子区间重建 `hits` 是解析档的主要 CPU 面 | `f_svg/src/SvgAnalyticRasterizer.cj:252-267`、`291-300` | 该循环自耗时占比 | `cjprof record` 跑 1000×1000 圆与 1000 段折线各 200 次，看 `accumulateAnalyticRow` 自耗时占比 |
| 2 | 逐列 `ArrayList` 分配主导解析档的 GC 压力 | `f_svg/src/SvgAnalyticRasterizer.cj:377`、`351-352` | 每次 fill 的分配量与 GC 次数 | 同几何对比 `getAllocatedHeapSize()` 与 `cjprof heap` 分配热点 |
| 3 | ≤8 MiB 的 local 档对峰值 RSS 的实际收益（1024² 恰好走 local、1025² 走堆） | `f_svg/src/SvgAnalyticRasterizer.cj:93-97`、`200-204` | 两档峰值 RSS / `getUsedHeapSize()` 对照 | 同图两档各渲染 50 次取峰值；`docs/LocalMode.md` 只有 2048² 的回退数据 |
| 4 | 样式表全量 token 物化在大 CSS 上成为峰值主因 | `f_svg/src/CssStyleSheet.cj:170`（`CssLexer(text).tokenize()`） | token 数与字节比、峰值 RSS | 10k / 100k 条规则的 CSS 各跑一次，记 token 数与 RSS |

<!-- 第 11 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SvgBitmap.blend` 在超采样渲染中占显著自耗时 | `f_svg/src/SvgBitmap.cj:143-161` | self time 占比、每像素调用次数 | `cjprof record` 跑 1024×1024 / 50 形状 / `samplesPerPixel=4`，看 `blend` 与 `quantizeSvgChannel` 的 self time |
| 2 | `SvgClipMask.composite` 的逐像素 `pixel()` + `setPixel()` 双份坐标校验构成混合模式热点 | `f_svg/src/SvgClipMask.cj:187-207`（依赖本部分 `blendSvgRgba`） | 该循环占整文档渲染的耗时比例 | 同一 profile 看 `composite` 累计时间；或分段计时跑 `multiplyAppliesOnce` 场景放大到 1024×1024 |
| 3 | `SvgBitmap.fill` 逐字节写比批量填充慢 | `f_svg/src/SvgBitmap.cj:127-140` | 大图 fill 单次耗时 | 1024×1024 / 4096×4096 各 1000 次 `fill` 的 `cjpm bench -O2` 对照 |
| 4 | `svgBidiVisualOrder` 的「按层级多趟扫描」在长文本上放大 | `f_svg/src/SvgBidi.cj:318-356` | 文本长度分布与单次耗时 | 10k/100k 字符 RTL 混合串跑 `cjprof`，对照 `TextRenderer` 整体耗时 |
| 5 | `SvgBuilder.save(path)` 的 `String + Array<Byte>` 双副本是文档保存的峰值来源 | `f_svg/src/SvgAuthoringBuilder.cj:66-72` | 峰值 heapUsed / RSS 与输出体积之比 | 50 MB 级文档连续保存 10 次，采样 `getAllocatedHeapSize()` 峰值 |
| 6 | auto 尺寸场景下 `svgBBoxOf` 是热点（整树遍历 + 样式查询） | `f_svg/src/SvgAutoSize.cj:46-51` | 自耗时占比、文档元素数 | `cjprof record` 渲染 5k 元素 `width="auto"` 文档，看 bbox 相关函数占比 |

<!-- 第 12 部分 -->

> 无性能测试数据，仅作为下一轮补数据清单，不计入统计、不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SvgColor.parse` 对命名色线性扫描 148 项，且同一属性值会被属性校验、样式解析、画笔解析多次调用，可能占解析时间可观比例 | `f_svg/src/SvgColor.cj:105-115`、`SvgBuilder.cj:527-530` | 该函数 self time 占比、每文档调用次数 | `cjprof record` 解析 1 万条 `fill="颜色名"` 的文档；或加计数器统计调用次数 |
| 2 | `SvgBuilder` 每条 warning 重建整条 `elementPath` 字符串，在非法属性密集的文档中是主要分配源 | `f_svg/src/SvgBuilder.cj:100`、`140`、`503`、`522` | 分配采样、每条 warning 平均长度与条数 | 构造 1 万元素 × 每条 2 个非法属性的文档，`cjprof` 分配采样 + 统计 warning 数与内存 |
| 3 | `SvgClipMask` 的 mask 覆盖率按整幅画布逐像素扫描（`renderMaskCoverage:296-311`），小区域蒙版时浪费明显 | `f_svg/src/SvgClipMask.cj:293-312` | region 面积占比与函数 self time | 1000×1000 画布、mask region 10% 的场景跑 `cjprof`，对比只扫描 region 的临时改造 |
| 4 | `SvgComputedStyle` 的 `findSvgPropertySpec` 线性扫描 75 项，CSS 规则多时是热点 | `f_svg/src/SvgComputedStyle.cj:154-161`、`SvgStyleResolver.cj:461`、`493` | 调用次数与 self time 占比 | 1 万条 CSS 声明的文档跑 `cjprof`，统计 `findSvgPropertySpec` 样本数 |
| 5 | 每元素一个 `SvgComputedStyle` + 三张 HashMap 的构建成本是样式解析的主要开销 | `f_svg/src/SvgStyleResolver.cj:237-399` | 样式构建占端到端解析时间的比例 | 10 万元素文档分段计时（DOM 构建 / 样式 / 渲染），并采样 `getAllocatedHeapSize()` |
| 6 | 蒙版/组合成逐像素 `layer.pixel()` / `destination.pixel()` / `setPixel()`（每像素构造 `SvgColor`/`SvgRgba` 并多次 `clamp`/`round`）是合成阶段主要自耗时 | `f_svg/src/SvgClipMask.cj:185-206`、`:296-311` | `SvgGroupCompositor.composite` 与 `quantizeSvgChannel` 的 self time 占比 | `cjprof record` 渲染 100 张带 mask 的 512×512 图后 `cjprof report` |
| 7 | clip 渲染对每个子元素重建 `SvgPathData`（`elementPathData` 内含 `ArrayList`→`Array` 与命令数组分配）是热点 | `f_svg/src/SvgClipMask.cj:363`、`:511`、`:779-852` | 每图调用次数与自耗时 | 同 #6 的 profile，另加计数器统计 `elementPathData` 调用数 |
| 8 | 属性校验（`isValidSvgAttribute`）与类型化 getter 对同一属性值各解析一次，占解析时间可观 | `f_svg/src/SvgBuilder.cj:289-295`、`:525-596` | 解析阶段耗时占比与重复解析次数 | 10 MB / 10 万元素 SVG 分段计时包住 `buildSvgDocument` 与属性读取 |

<!-- 第 13 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | cursor 关键字线性扫描在样式计算里的自耗时占比可忽略（预期 < 2%） | `f_svg/src/SvgCursor.cj:71-77` | 自耗时占比、单次调用耗时 | `cjprof record` 跑 1000 规则 × 1000 元素 + `cursor` 规则，`-O2` |
| 2 | 逐元素 warning 在内嵌 1 MB `url()` 值时的峰值 RSS 是否线性于元素数 | `f_svg/src/SvgCursor.cj:56`、`f_svg/src/SvgStyleResolver.cj:744` | 峰值 RSS / heapUsed 与元素数的比值 | 1e3 / 1e4 / 1e5 元素各跑一遍，采样 `getUsedHeapSize()` 与 RSS |
| 3 | `elementById` 的全量前序 + 每节点 `attr("id")` 比较在 1e6 元素上占显著自耗时 | `f_svg/src/SvgDocument.cj:172-187` | self time 占比、单次耗时随 n 的变化 | `cjprof record`，命中末节点 / 未命中两种输入，n = 1e5 / 1e6 |
| 4 | `toXmlDocument()` 的整树复制把峰值内存抬到约 2× 节点量 | `f_svg/src/SvgDocument.cj:153-165` | 峰值占元素数之比、副本存活时长 | 10 万元素文档连续 10 轮 `toXmlDocument()`，采样分配量与 RSS |
| 5 | `views()` 两趟比单趟多出的分配/耗时低于噪声（5%） | `f_svg/src/SvgDocument.cj:116-127` | 两趟与单趟的差值与分布 | `cjpm bench -O2` 对照，1e4 `view` + 1e5 其它元素，取中位数与 P95 |

<!-- 第 14 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 批量 `getBBox()` 的耗时主要花在重复构建样式树（O(m·n)） | `f_svg/src/SvgElement.cj:459-464`、`f_svg/src/SvgElementApi.cj:313` | `SvgStyleResolver.compute` 自耗时占比；m、n 的实测值 | 2000 元素文档逐元素 `getBBox()`，`cjprof record` + 分段计时（构建 vs 求值） |
| 2 | 大区域光照滤镜的热点在逐像素 getter 与 `m4LightFor` | `f_svg/src/SvgFilterLighting.cj:460-514` | 每像素成本拆分（getter / 法线 / 光照 / 写回） | 4000×4000 缓冲跑 `feDiffuseLighting`，`-O2`，`cjprof` 看自耗时；同时给 800×800 对照看是否随像素线性 |
| 3 | 动画逐帧路径上 `svgNotifyMutation` 与属性双扫描构成可观开销 | `f_svg/src/SvgMutation.cj:110-127`、`f_svg/src/SvgElement.cj:152-172` | 每帧写入次数、`svgNotifyMutation` 自耗时、`bareAttributeIndex` 调用次数 | 60 帧 × 1 万属性写入，`cjprof` + 计数埋点；开/关监听器各跑一遍 |
| 4 | 多原语滤镜链的峰值内存由"全部中间缓冲"主导（发现 #2） | `f_svg/src/SvgFilterRenderer.cj:202-251`、`f_svg/src/SvgFilterBuffer.cj:34` | 链执行期间同时存活的缓冲数、峰值 RSS | 20 原语 + 4000×4000 区域的渲染，采 `getAllocatedHeapSize()` 峰值、RSS、每缓冲命中日志；同输入改 5 原语对照 |

<!-- 第 15 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 高斯模糊是滤镜链的主要自耗时项（`convolveHorizontal/Vertical`，含 `bytesToFloat`/`floatsToBuffer`） | `f_svg/src/SvgFilterPrimitives.cj:61-141` | 自耗时占比与调用路径 | `cjprof record` 跑 512×512、σ=8、`samplesPerPixel=1`，取 top-N self time |
| 2 | `toLinearRgb`/`toSrgb` 的 `pow` 在该段占 90% 以上 | `f_svg/src/SvgFilterRenderer.cj:372-416` | 分段计时 | 在 `apply` 里对 `toLinearRgb`/`toSrgb` 各打一次计时，512×512 与 2048×2048 |
| 3 | `bilinearSvgSample` 的每像素 4 次分配使 GC 占 `feDisplacementMap` 耗时的可观比例 | `f_svg/src/SvgFilterPrimitives2.cj:1332-1374` | 分配量与 GC 时间 | `cjprof heap` + 512×512 `scale=10`，对照分配次数与 GC 次数 |
| 4 | `named` 保留中间缓冲把峰值推到 maxPixels 量级（默认 64 Mi ⇒ 单缓冲 256 MB） | `f_svg/src/SvgFilterRenderer.cj:202,246-247` | 峰值 RSS | 4096×4096 画布 + 5 原语链，`getAllocatedHeapSize()`/RSS 采样 |
| 5 | 模糊的 Float64 中间数组适合 local mode（`bytesToFloat` 产物与卷积输出都不逃逸出 `blurFilterBuffer`） | `f_svg/src/SvgFilterPrimitives.cj:31-38` | 改前/改后峰值内存 | 开 `--experimental --enable-local-mode`，同输入比对 `getAllocatedLocalObjectSize()` 与 RSS |

<!-- 第 16 部分 -->

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`，只作为下一轮补数据的清单。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 渐变采样是渐变填充渲染的主要自耗时来源（每像素重解析 href 链与 stops） | `f_svg/src/SvgGradient.cj:220-290` | `sample` 自耗时占比、每像素平均分配字节 | `cjprof record` 渲染含 3 个渐变、2000×2000、`samplesPerPixel=1`；输入固定 10 轮取中位数 |
| 2 | `findGradientById` 的全树递归在元素多（>1e4）的文档上成本显著 | `f_svg/src/SvgGradient.cj:506-528` | 单次调用平均遍历节点数、占 `sample` 自耗时的比例 | 埋点统计 `findGradientById` 调用次数与访问节点数；对比建 id 映射后的耗时 |
| 3 | `pathDataBounds` 的 `toAbsolute` 副本在长路径文档上造成峰值内存与 GC 抖动 | `f_svg/src/SvgGeometry.cj:418-421` | 峰值 `getAllocatedHeapSize()`、GC 次数、RSS 曲线 | 100 条路径 × 5000 命令，连续 100 帧 `getBBox`；对照组缓存绝对化结果 |
| 4 | Hershey 字体 `glyphPath` 的字符串解析在长文本布局中占比较高 | `f_svg/src/SvgHersheyFont.cj:35-74` | 自耗时占比、每字形分配字节 | `cjpm bench -O2`：1 万字 layout，对比预解析轮廓实现 |
| 5 | GSUB `applyLookupPass` 的 `ArrayList.remove(at:)` 让长 run（>1e4 字形）的连字整形退化为 O(n²) | `f_svg/src/SvgGsubContext.cj:134-144`、`:540-546` | n 从 1e3 到 1e5 的耗时曲线 | 合成 1 万/10 万字形 run + 每 2 字一个连字，计时并拟合复杂度 |
| 6 | 每次加载字体把 GSUB 解析 4 次在「一次渲染含数百个嵌入字体」的场景里占启动时间 | `f_svg/src/SvgTrueTypeFont.cj:272-296` | 字体解析阶段耗时占比 | 100 个内嵌 @font-face 的文档，对比「解析一次 + 视图」实现 |

<!-- 第 17 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单次 `hitTest` 的成本主要在“整树样式重算 + 每元素 CTM/路径扁平化”，而非几何判定本身 | `f_svg/src/SvgHitTest.cj:174-195`、`f_svg/src/SvgHitTest.cj:453-470` | 自耗时占比与调用路径 | `cjprof record` 跑 1k / 10k 元素文档各 100 次 `hitTest`，看 `flattenPathData` / `cascade` 占比 |
| 2 | `flattenPathData` 每个元素重算一遍（无跨查询缓存），在 `elementAt` 场景是主要浪费 | `f_svg/src/SvgHitTest.cj:457`、`f_svg/src/SvgHitTest.cj:524` | 单次扁平化耗时 × 元素数 | 分段计时插桩，记录每元素 `flattenPathData` 累计耗时 |
| 3 | 文本命中每次都新建 `SvgTextRenderer` 且 `layoutCache: None`，多 text 文档上偏贵 | `f_svg/src/SvgHitTest.cj:516-517` | 布局耗时占比 | 对含 100 个 `<text>` 的文档跑 `hitTest`，`cjprof` 看 `SvgTextRenderer.outline` 自耗时 |
| 4 | data URI 解码峰值的 2/3 来自字符串副本，而非解码结果 | `f_svg/src/SvgImageResource.cj:101-150` | 峰值分配构成 | 单张 16 MiB data URI 渲染时抓 `cjprof heap` 分配分类 |
| 5 | 命中查询的 `O(n×depth)` 在 1000 层以上嵌套文档上会到秒级 | `f_svg/src/SvgHitQueries.cj:50-63` | 端到端耗时 | 生成深度 100/500/1000 的嵌套 `<g>` 文档，测 `getIntersectionList` 耗时曲线 |

<!-- 第 18 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个类型化 getter 都创建捕获 `this` 的闭包（`SvgMarker` 8 个属性最集中），在渲染树逐元素读属性时形成可观分配量 | `f_svg/src/SvgMarker.cj:119-127`、`f_svg/src/SvgElement.cj:33` | 每次读取的分配字节数与占比 | `cjprof heap` / 分配埋点，跑 1 万元素文档一次完整渲染，统计 `getAllocatedHeapSize()` 与 getter 调用次数 |
| 2 | `flattenPathData` 在 marker 派生中的自耗时占比（长曲线 path） | `f_svg/src/SvgMarkerExpander.cj:263` | 自耗时占比与调用路径 | `cjprof record` 渲染含 10k 段 `C` 的 path（仅 marker-end），看 `flattenPathData` self time |
| 3 | `SvgValueCache` 的命中率与「同一属性在渲染树里被重复读取」的比例 | `f_svg/src/SvgElement.cj:33-40` | 命中率、每次未命中耗时 | 在 `get` 里加计数埋点，跑 100 份文档稳态负载 |
| 4 | 大字体（>5 MB）的 GPOS/GSUB/kern 解析耗时与内存峰值 | `f_svg/src/SvgOpenTypeLayout.cj:205` / `:315` / `:575` | 解析耗时、峰值内存 | 用 3 个真实 CJK 字体跑 `SvgTrueTypeFont.parse`，记录 `cjprof` 与峰值 RSS |

<!-- 第 19 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `buildSegments` 的 `contours → segments` 双份物化是 `getTotalLength` 的主要分配来源 | `f_svg/src/SvgPathMeasure.cj:75-102` | 分配量占比、峰值 RSS | 10k 顶点路径跑 1000 次，`getAllocatedHeapSize()` 前后差 + `cjprof heap` |
| 2 | pattern 失败 tile 的重复构建在「多图元共用 pattern」文档上是主要耗时 | `f_svg/src/SvgPatternSampler.cj:193-200, 283-310` | `buildContent` 自耗时占比 | 200 图元 + 1 个含悬空引用的 pattern，`cjprof record` |
| 3 | 每枚 tile 新建 `SvgRenderer`/`SvgRenderTreeBuilder` 带来可观的构造与预热成本 | `f_svg/src/SvgPatternSampler.cj:283-304` | 构造耗时、GC 次数 | 1000 枚 20×20 tile，分段计时 + GC 计数 |
| 4 | `findPatternById` 全树搜索在「pattern 多、元素多」文档上是 O(元素数 × 填充数) 热点 | `f_svg/src/SvgPatternSampler.cj:499-521`、调用点 `f_svg/src/SvgRenderer.cj:588` | 搜索自耗时占比 | 5k 元素 + 500 个 pattern 填充，`cjprof record` |
| 5 | `paint-order` 的双次分词在样式密集文档上占比可忽略（用于关闭该优化项） | `f_svg/src/SvgPaintOrder.cj:63,117-123` | 自耗时占比 | 1 万条声明跑 `SvgStyleResolver`，`cjprof` |

<!-- 第 20 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `computeCoverage` 的 `rows × samples × edges` 全量扫边是渲染热点（自耗时占比未知） | `f_svg/src/SvgRasterizer.cj:318-334` | 自耗时占比、调用路径、输入规模 | `cjprof record` 渲染含 500 / 2000 条边路径的 1024×1024 图，samples=4 |
| 2 | `sortHits` 插入排序在 edges > 500 时成为行内瓶颈 | `f_svg/src/SvgRasterizer.cj:451-463` | 单行 hits 数量分布与排序耗时 | 在 `sortHits` 前后加分段计时，跑复杂路径 1 万次取中位数 |
| 3 | `subdivideCubic` 深度上限 16 在极端缩放下产生 ~65k 点/段，扁平化内存被放大 | `f_svg/src/SvgRasterizer.cj:686-707`（上限 `695`） | 实际深度分布、单条 `C` 命令产出的点数 | 用 `matrix=scale(1e6)` + 高曲率三次曲线压测，统计 `flattenCubicPolyline` 返回点数与耗时 |
| 4 | PNG 编码的 deflate 与 Adler-32 双遍扫描（raw 读两遍 + CRC 再一遍）占编码耗时主要部分 | `f_svg/src/SvgPngEncoder.cj:44-52` | 各阶段耗时占比 | 分段计时 `buildRawScanlines` / `deflateBytes` / `adler32` / `writeChunk`，输入 4096×4096 RGBA，-O2，10 轮中位数 |

<!-- 第 21 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sampleImage` 的每像素小数组分配是 `<image>` 绘制的主要 GC 压力 | `f_svg/src/SvgRenderer.cj:1167-1231` | 分配量、GC 次数、`sampleImage` 自耗时占比 | `cjprof record` 渲染 1024² 源图 → 2048² 目标，samplesPerPixel=1，统计 `alloc` 与 GC 停顿 |
| 2 | 三次 `SvgStyleResolver.compute` 占 `build` 端到端 30% 以上 | `f_svg/src/SvgRenderTree.cj:289-320` | 分段计时占比（10k 元素文档） | 在三次 compute 前后加计时，`-O2` 跑 10 轮取中位数 |
| 3 | 整画布离屏层合成（含空组）是 `opacity < 1` 文档的热点 | `f_svg/src/SvgRenderer.cj:144-160`、`:201-206` | `composite` 自耗时、层数分布 | `cjprof record` 跑 50 个 `opacity="0.9"` 组、1024² 画布；另统计"子内容全被 display:none 的空组"数量 |
| 4 | `walkContainer` 的子指令复制在深嵌套文档里占构树时间的主要部分 | `f_svg/src/SvgRenderTree.cj:769-804` | 复制次数与耗时（depth × 命令数） | 构造 200/500/1000 层 `g` + 每层 10 个矩形，分段计时 `walkChildren` |
| 5 | 长生命周期 `SvgRenderer` 的 `warnings` 只增不减会累积到可观内存 | `f_svg/src/SvgRenderer.cj:68-72`、`:293-295` | 每轮 warning 条数 × 轮数、RSS/堆占用 | 同一实例渲染 10k 个含缺失 `<image>` 的文档，采 `getUsedHeapSize()` 与 `warnings.size` |

<!-- 第 22 部分 -->

> 无性能数据支撑，不进 `todo.md` / `tasks.md`，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `cascade` 的容器分配占渲染总 CPU 的显著比例 | `f_svg/src/SvgStyleResolver.cj:237` | `cascade` 自耗时占比、分配量 | `cjprof record` 渲染 1 万元素文档，看 `cascade`/`normalizeValue` self time 与 `cjprof heap` 分配 |
| 2 | 逐元素 `getBBox` 触发的整树级联是 O(n²) 热点 | `f_svg/src/SvgElement.cj:461` | 端到端耗时随 n 的曲线 | 5k 元素文档循环 `getBBox` 5k 次，分段计时 + `cjprof` |
| 3 | round/arcs 连接的整圆多边形是描边路径主要开销 | `f_svg/src/SvgStrokeOutliner.cj:319` | 轮廓点数与耗时占比 | 生成 1 万顶点 round-join 折线，统计 `outlineContours` 返回点数与耗时 |
| 4 | 计算样式全量字符串使单文档常驻内存偏高 | `f_svg/src/SvgStyleResolver.cj:373` | `SvgComputedStyle` 保留大小 | `cjprof heap` 对比 1 万元素文档 compute 前后的 heapUsed 与对象数 |

<!-- 第 23 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `dotted` / `dashed` 的段生成在正常厚度下也是热点（每字形 5 命令/段） | `f_svg/src/SvgTextDecoration2.cj:182-198` | 自耗时占比 | `cjprof record` 渲染 1k 个 `underline dotted` 的 text（font-size 20），看 `appendSvgDecorationRect` / `SvgPathCommand` 构造占比 |
| 2 | `resolveSvgDecorationStyle` 对每个文本元素走完整祖先链（4 属性 × 2 次 `sourceOf` × 深度），深树 + 大量 tspan 时放大 | `f_svg/src/SvgTextDecoration2.cj:258-366` | 调用次数与自耗时 | 构造 10k tspan、深度 50 的文档，`cjprof record`；对照「四标志全命中即 break」的改动前后耗时 |
| 3 | 11 个缓存对象的首次解析闭包分配是文本布局的主要分配来源 | `f_svg/src/SvgTextElement.cj:98-108` | 分配量与峰值 | `cjprof heap` + `getAllocatedHeapSize()`，1k/10k tspan 两档，按「优化方案 1」改造前后对照 |

<!-- 第 24 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sample()` 的整树克隆是动画播放的主开销 | `f_svg/src/SvgTimeline.cj:212` | 克隆占总耗时比例、每帧分配字节数 | `cjprof record`，300 帧、文档节点数 1k/10k |
| 2 | 竖排多列文本的 O(n²) 列处理在长文本上可观测 | `f_svg/src/SvgTextRenderer.cj:595-635` | 不同 n 下的 layout 耗时曲线与自耗时占比 | 构造 n 列竖排文本，`cjpm bench -O2` 分 100/1000/5000 字三档 |
| 3 | `layout` 内大量逐元素 `ArrayList`（`advances/paths/baselineOffsets/ascentValues/resolvedFonts`）适合 local mode | `f_svg/src/SvgTextRenderer.cj:409-492` | 峰值内存与 local region 容量 | 开 `--experimental --enable-local-mode` 前后对照峰值 `getUsedHeapSize()`/RSS；先按 `mem §1` 排除长期引用 |
| 4 | 字形缓存（按 renderer 实例）在同文本重复字符上命中率足够 | `f_svg/src/SvgTextRenderer.cj:301` | 命中率与单次 miss 代价 | 加计数埋点，跑含重复字符的典型文档 |

<!-- 第 25 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 复合字形放大是实际可达的 OOM 路径（对应「严重」条目的量化） | `f_svg/src/SvgTrueTypeFont.cj:651` | 构造 16 MiB glyf（约 27 万组件 × 10000 点）后的峰值 RSS 与 `glyphPath` 耗时 | 生成恶意 TTF，单次 `glyphPath` 前后取 `getUsedHeapSize()` + RSS；同时记录命令数 |
| 2 | 装载期 GSUB 四次解析是装载耗时主要项 | `f_svg/src/SvgTrueTypeFont.cj:272` | 装载自耗时占比 | `cjprof record` 加载 100 个真实字体（含大 GSUB 的 CJK 字体），对比注释掉三次多余解析的耗时 |
| 3 | `SvgComputedStyle.vectorEffects()` 每次调用重建数组是渲染热点 | `f_svg/src/SvgComputedStyle.cj:387` + `SvgRenderTree.cj:1217` / `:1897` | 每命令调用次数与自耗时 | 渲染 10k 个带 `vector-effect` 的元素，`cjprof` 看分配量与自耗时；或加计数器统计调用次数 |
| 4 | `ligatureAt` 每次重映射整段码点是长 run 的 O(n²) 热点 | `f_svg/src/SvgTrueTypeFont.cj:413` + `SvgTextRenderer.cj:1836` | 单 run 4000 字符的排版耗时曲线（n / 2n 对比） | 单 `<text>` 放 1000/2000/4000 字符拉丁文本，计时 `SvgRenderTreeBuilder.build`，看是否随 n² 增长 |
| 5 | `SvgVectorEffect` 静态属性每次访问都新建对象带来可观分配 | `f_svg/src/SvgVectorEffect.cj:33` | 访问次数与分配量 | `cjprof heap` 或 `getAllocatedHeapSize()` 对照「静态常量缓存」改前改后（同文档渲染 100 次） |

<!-- 第 26 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `writeSvgString` 的峰值内存约为输出大小的 3 倍（缓冲区 + `bytes()` + 字符串） | `f_svg/src/SvgWriter.cj:223-227` | 峰值 RSS / `getAllocatedHeapSize()` 与输出字节数的比值；`ByteBuffer.bytes()` 是否拷贝 | 1 MB / 10 MB SVG 各 20 轮，写入前后采样 heap 与 RSS，同时打印 `buffer.bytes().size` |
| 2 | `normalizeElementHrefs` 在写入总耗时中占比可忽略（<5%） | `f_svg/src/SvgWriter.cj:139-168` | 自耗时占比 | `cjprof record` 跑 20 轮 `writeSvgString`（10 MB 文档，属性密集），看 `normalizeElementHrefs` 与 `Escaper.escapeAttribute` 的 self time |
| 3 | 写入路径的一次深拷贝是峰值内存主因，而非转义缓冲 | `f_svg/src/SvgWriter.cj:74`、`f_svg/src/SvgElement.cj:386-409` | 两棵树的存活对象数与字节量 | 写入前后各做一次 heap dump / 对象计数对比 |

## 文件覆盖

> 与 `files/f_svg.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/README.md` | .md | ✅ | — |
| 2 | `f_svg/README_en.md` | .md | ✅ | — |
| 3 | `f_svg/doc/f_svg-M2设计.md` | .md | ✅ | — |
| 4 | `f_svg/doc/f_svg-M3设计.md` | .md | ✅ | — |
| 5 | `f_svg/doc/f_svg-M4设计.md` | .md | ✅ | — |
| 6 | `f_svg/doc/f_svg-M5设计.md` | .md | ✅ | — |
| 7 | `f_svg/doc/f_svg-M6设计.md` | .md | ✅ | — |
| 8 | `f_svg/doc/f_svg-M7设计.md` | .md | ✅ | — |
| 9 | `f_svg/doc/f_svg模块设计.md` | .md | ✅ | — |
| 10 | `f_svg/doc/perf-baseline.md` | .md | ✅ | — |
| 11 | `f_svg/doc/spec/add-f-svg-m2/design.md` | .md | ✅ | — |
| 12 | `f_svg/doc/spec/add-f-svg-m2/fix-plan-2.md` | .md | ✅ | — |
| 13 | `f_svg/doc/spec/add-f-svg-m2/fix-plan-3.md` | .md | ✅ | — |
| 14 | `f_svg/doc/spec/add-f-svg-m2/fix-plan.md` | .md | ✅ | — |
| 15 | `f_svg/doc/spec/add-f-svg-m2/proposal.md` | .md | ✅ | — |
| 16 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-animation/spec.md` | .md | ✅ | — |
| 17 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-css/spec.md` | .md | ✅ | — |
| 18 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-geometry/spec.md` | .md | ✅ | — |
| 19 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md` | .md | ✅ | — |
| 20 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-png/spec.md` | .md | ✅ | — |
| 21 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 22 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-render-pipeline/spec.md` | .md | ✅ | — |
| 23 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-security/spec.md` | .md | ✅ | — |
| 24 | `f_svg/doc/spec/add-f-svg-m2/specs/svg-text/spec.md` | .md | ✅ | — |
| 25 | `f_svg/doc/spec/add-f-svg-m2/tasks.md` | .md | ✅ | — |
| 26 | `f_svg/doc/spec/add-f-svg-m2/verification.md` | .md | ✅ | — |
| 27 | `f_svg/doc/spec/add-f-svg-m3/design.md` | .md | ✅ | — |
| 28 | `f_svg/doc/spec/add-f-svg-m3/fix-plan-2.md` | .md | ✅ | — |
| 29 | `f_svg/doc/spec/add-f-svg-m3/fix-plan-3.md` | .md | ✅ | — |
| 30 | `f_svg/doc/spec/add-f-svg-m3/fix-plan.md` | .md | ✅ | — |
| 31 | `f_svg/doc/spec/add-f-svg-m3/proposal.md` | .md | ✅ | — |
| 32 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-css/spec.md` | .md | ✅ | — |
| 33 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-document-model/spec.md` | .md | ✅ | — |
| 34 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-filter/spec.md` | .md | ✅ | — |
| 35 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-marker/spec.md` | .md | ✅ | — |
| 36 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-paint-and-clip/spec.md` | .md | ✅ | — |
| 37 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md` | .md | ✅ | — |
| 38 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 39 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-render-pipeline/spec.md` | .md | ✅ | — |
| 40 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md` | .md | ✅ | — |
| 41 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-text/spec.md` | .md | ✅ | — |
| 42 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-value-types/spec.md` | .md | ✅ | — |
| 43 | `f_svg/doc/spec/add-f-svg-m3/tasks.md` | .md | ✅ | — |
| 44 | `f_svg/doc/spec/add-f-svg-m3/verification-2.md` | .md | ✅ | — |
| 45 | `f_svg/doc/spec/add-f-svg-m3/verification-3.md` | .md | ✅ | — |
| 46 | `f_svg/doc/spec/add-f-svg-m3/verification.md` | .md | ✅ | — |
| 47 | `f_svg/doc/spec/add-f-svg-m4/design.md` | .md | ✅ | — |
| 48 | `f_svg/doc/spec/add-f-svg-m4/fix-plan-2.md` | .md | ✅ | — |
| 49 | `f_svg/doc/spec/add-f-svg-m4/fix-plan-3.md` | .md | ✅ | — |
| 50 | `f_svg/doc/spec/add-f-svg-m4/fix-plan.md` | .md | ✅ | — |
| 51 | `f_svg/doc/spec/add-f-svg-m4/proposal.md` | .md | ✅ | — |
| 52 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-css/spec.md` | .md | ✅ | — |
| 53 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-document-model/spec.md` | .md | ✅ | — |
| 54 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md` | .md | ✅ | — |
| 55 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md` | .md | ✅ | — |
| 56 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-paint-and-clip/spec.md` | .md | ✅ | — |
| 57 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 58 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-render-pipeline/spec.md` | .md | ✅ | — |
| 59 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md` | .md | ✅ | — |
| 60 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md` | .md | ✅ | — |
| 61 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-value-types/spec.md` | .md | ✅ | — |
| 62 | `f_svg/doc/spec/add-f-svg-m4/tasks.md` | .md | ✅ | — |
| 63 | `f_svg/doc/spec/add-f-svg-m4/verification-2.md` | .md | ✅ | — |
| 64 | `f_svg/doc/spec/add-f-svg-m4/verification-3.md` | .md | ✅ | — |
| 65 | `f_svg/doc/spec/add-f-svg-m4/verification-4.md` | .md | ✅ | — |
| 66 | `f_svg/doc/spec/add-f-svg-m4/verification.md` | .md | ✅ | — |
| 67 | `f_svg/doc/spec/add-f-svg-m5/design.md` | .md | ✅ | — |
| 68 | `f_svg/doc/spec/add-f-svg-m5/fix-plan-2.md` | .md | ✅ | — |
| 69 | `f_svg/doc/spec/add-f-svg-m5/fix-plan.md` | .md | ✅ | — |
| 70 | `f_svg/doc/spec/add-f-svg-m5/proposal.md` | .md | ✅ | — |
| 71 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-css/spec.md` | .md | ✅ | — |
| 72 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-document-model/spec.md` | .md | ✅ | — |
| 73 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-filter/spec.md` | .md | ✅ | — |
| 74 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-geometry/spec.md` | .md | ✅ | — |
| 75 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-paint-and-clip/spec.md` | .md | ✅ | — |
| 76 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 77 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-render-pipeline/spec.md` | .md | ✅ | — |
| 78 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-security/spec.md` | .md | ✅ | — |
| 79 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-text/spec.md` | .md | ✅ | — |
| 80 | `f_svg/doc/spec/add-f-svg-m5/specs/svg-value-types/spec.md` | .md | ✅ | — |
| 81 | `f_svg/doc/spec/add-f-svg-m5/tasks.md` | .md | ✅ | — |
| 82 | `f_svg/doc/spec/add-f-svg-m5/verification-2.md` | .md | ✅ | — |
| 83 | `f_svg/doc/spec/add-f-svg-m5/verification.md` | .md | ✅ | — |
| 84 | `f_svg/doc/spec/add-f-svg-m6/design.md` | .md | ✅ | — |
| 85 | `f_svg/doc/spec/add-f-svg-m6/fix-plan-2.md` | .md | ✅ | — |
| 86 | `f_svg/doc/spec/add-f-svg-m6/fix-plan-3.md` | .md | ✅ | — |
| 87 | `f_svg/doc/spec/add-f-svg-m6/fix-plan.md` | .md | ✅ | — |
| 88 | `f_svg/doc/spec/add-f-svg-m6/proposal.md` | .md | ✅ | — |
| 89 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-animation/spec.md` | .md | ✅ | — |
| 90 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-css/spec.md` | .md | ✅ | — |
| 91 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-document-model/spec.md` | .md | ✅ | — |
| 92 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-geometry/spec.md` | .md | ✅ | — |
| 93 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-paint-and-clip/spec.md` | .md | ✅ | — |
| 94 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 95 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-render-pipeline/spec.md` | .md | ✅ | — |
| 96 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md` | .md | ✅ | — |
| 97 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-text/spec.md` | .md | ✅ | — |
| 98 | `f_svg/doc/spec/add-f-svg-m6/specs/svg-value-types/spec.md` | .md | ✅ | — |
| 99 | `f_svg/doc/spec/add-f-svg-m6/tasks.md` | .md | ✅ | — |
| 100 | `f_svg/doc/spec/add-f-svg-m6/verification.md` | .md | ✅ | — |
| 101 | `f_svg/doc/spec/add-f-svg-m6/verify-report-2.md` | .md | ✅ | — |
| 102 | `f_svg/doc/spec/add-f-svg-m6/verify-report-3.md` | .md | ✅ | — |
| 103 | `f_svg/doc/spec/add-f-svg-m6/verify-report.md` | .md | ✅ | — |
| 104 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/design.md` | .md | ✅ | — |
| 105 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/proposal.md` | .md | ✅ | — |
| 106 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/specs/svg-authoring/spec.md` | .md | ✅ | — |
| 107 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/tasks.md` | .md | ✅ | — |
| 108 | `f_svg/doc/spec/add-f-svg-m7-output-overloads/verification.md` | .md | ✅ | — |
| 109 | `f_svg/doc/spec/add-f-svg-m7/design.md` | .md | ✅ | — |
| 110 | `f_svg/doc/spec/add-f-svg-m7/proposal.md` | .md | ✅ | — |
| 111 | `f_svg/doc/spec/add-f-svg-m7/specs/svg-authoring/spec.md` | .md | ✅ | — |
| 112 | `f_svg/doc/spec/add-f-svg-m7/tasks.md` | .md | ✅ | — |
| 113 | `f_svg/doc/spec/add-f-svg-m7/verification.md` | .md | ✅ | — |
| 114 | `f_svg/doc/spec/add-f-svg-m7/verify-report.md` | .md | ✅ | — |
| 115 | `f_svg/doc/spec/add-f-svg-module/design.md` | .md | ✅ | — |
| 116 | `f_svg/doc/spec/add-f-svg-module/fix-plan.md` | .md | ✅ | — |
| 117 | `f_svg/doc/spec/add-f-svg-module/proposal.md` | .md | ✅ | — |
| 118 | `f_svg/doc/spec/add-f-svg-module/specs/svg-document-model/spec.md` | .md | ✅ | — |
| 119 | `f_svg/doc/spec/add-f-svg-module/specs/svg-security/spec.md` | .md | ✅ | — |
| 120 | `f_svg/doc/spec/add-f-svg-module/specs/svg-value-types/spec.md` | .md | ✅ | — |
| 121 | `f_svg/doc/spec/add-f-svg-module/tasks.md` | .md | ✅ | — |
| 122 | `f_svg/doc/spec/add-f-svg-module/verification.md` | .md | ✅ | — |
| 123 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/design.md` | .md | ✅ | — |
| 124 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/proposal.md` | .md | ✅ | — |
| 125 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/specs/svg-rasterization/spec.md` | .md | ✅ | — |
| 126 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/tasks.md` | .md | ✅ | — |
| 127 | `f_svg/src/CssCalc.cj` | .cj | ✅ | — |
| 128 | `f_svg/src/CssCalcM5_test.cj` | .cj | ✅ | — |
| 129 | `f_svg/src/CssCalcPropertyM5_test.cj` | .cj | ✅ | — |
| 130 | `f_svg/src/CssComboM5_test.cj` | .cj | ✅ | — |
| 131 | `f_svg/src/CssFontAliasM5_test.cj` | .cj | ✅ | — |
| 132 | `f_svg/src/CssFontFaceM5_test.cj` | .cj | ✅ | — |
| 133 | `f_svg/src/CssGeometryCalcM5_test.cj` | .cj | ✅ | — |
| 134 | `f_svg/src/CssInteractionM6_test.cj` | .cj | ✅ | — |
| 135 | `f_svg/src/CssLexer.cj` | .cj | ✅ | — |
| 136 | `f_svg/src/CssLexer_test.cj` | .cj | ✅ | — |
| 137 | `f_svg/src/CssMedia.cj` | .cj | ✅ | — |
| 138 | `f_svg/src/CssMediaM5_test.cj` | .cj | ✅ | — |
| 139 | `f_svg/src/CssMediaWidthM5_test.cj` | .cj | ✅ | — |
| 140 | `f_svg/src/CssParser.cj` | .cj | ✅ | — |
| 141 | `f_svg/src/CssSelector.cj` | .cj | ✅ | — |
| 142 | `f_svg/src/CssSelector2.cj` | .cj | ✅ | — |
| 143 | `f_svg/src/CssSelectorAttributeM5_test.cj` | .cj | ✅ | — |
| 144 | `f_svg/src/CssSelectorCascadeM5_test.cj` | .cj | ✅ | — |
| 145 | `f_svg/src/CssSelectorLimitM5_test.cj` | .cj | ✅ | — |
| 146 | `f_svg/src/CssSelectorNotM5_test.cj` | .cj | ✅ | — |
| 147 | `f_svg/src/CssSelectorNthM5_test.cj` | .cj | ✅ | — |
| 148 | `f_svg/src/CssSelectorSiblingM5_test.cj` | .cj | ✅ | — |
| 149 | `f_svg/src/CssSelectorSpecificityM5_test.cj` | .cj | ✅ | — |
| 150 | `f_svg/src/CssSelectorStructuralM5_test.cj` | .cj | ✅ | — |
| 151 | `f_svg/src/CssSelector_test.cj` | .cj | ✅ | — |
| 152 | `f_svg/src/CssStyleSheet.cj` | .cj | ✅ | — |
| 153 | `f_svg/src/CssStyleSheet_test.cj` | .cj | ✅ | — |
| 154 | `f_svg/src/CssVariables.cj` | .cj | ✅ | — |
| 155 | `f_svg/src/CssVariablesM5_test.cj` | .cj | ✅ | — |
| 156 | `f_svg/src/CssVariablesNegativeM5_test.cj` | .cj | ✅ | — |
| 157 | `f_svg/src/SvgAnalyticLocalMode_test.cj` | .cj | ✅ | — |
| 158 | `f_svg/src/SvgAnalyticRasterizer.cj` | .cj | ✅ | — |
| 159 | `f_svg/src/SvgAnalyticRasterizer_test.cj` | .cj | ✅ | — |
| 160 | `f_svg/src/SvgAnchor.cj` | .cj | ✅ | — |
| 161 | `f_svg/src/SvgAnimate.cj` | .cj | ✅ | — |
| 162 | `f_svg/src/SvgAnimateM7_test.cj` | .cj | ✅ | — |
| 163 | `f_svg/src/SvgAnimateMotion.cj` | .cj | ✅ | — |
| 164 | `f_svg/src/SvgAnimateTransform.cj` | .cj | ✅ | — |
| 165 | `f_svg/src/SvgAnimation.cj` | .cj | ✅ | — |
| 166 | `f_svg/src/SvgAnimationControlM6_test.cj` | .cj | ✅ | — |
| 167 | `f_svg/src/SvgAnimation_test.cj` | .cj | ✅ | — |
| 168 | `f_svg/src/SvgAttribute.cj` | .cj | ✅ | — |
| 169 | `f_svg/src/SvgAuthoringBuilder.cj` | .cj | ✅ | — |
| 170 | `f_svg/src/SvgAuthoringTypes.cj` | .cj | ✅ | — |
| 171 | `f_svg/src/SvgAuthoringTypesM7_test.cj` | .cj | ✅ | — |
| 172 | `f_svg/src/SvgAutoSize.cj` | .cj | ✅ | — |
| 173 | `f_svg/src/SvgAutoSizeM6_test.cj` | .cj | ✅ | — |
| 174 | `f_svg/src/SvgBBoxM5_test.cj` | .cj | ✅ | — |
| 175 | `f_svg/src/SvgBegin.cj` | .cj | ✅ | — |
| 176 | `f_svg/src/SvgBeginM7_test.cj` | .cj | ✅ | — |
| 177 | `f_svg/src/SvgBenchmarkM4_test.cj` | .cj | ✅ | — |
| 178 | `f_svg/src/SvgBenchmark_test.cj` | .cj | ✅ | — |
| 179 | `f_svg/src/SvgBidi.cj` | .cj | ✅ | — |
| 180 | `f_svg/src/SvgBidiM5_test.cj` | .cj | ✅ | — |
| 181 | `f_svg/src/SvgBitmap.cj` | .cj | ✅ | — |
| 182 | `f_svg/src/SvgBitmap_test.cj` | .cj | ✅ | — |
| 183 | `f_svg/src/SvgBlend.cj` | .cj | ✅ | — |
| 184 | `f_svg/src/SvgBlendLayerM5_test.cj` | .cj | ✅ | — |
| 185 | `f_svg/src/SvgBlendM5_test.cj` | .cj | ✅ | — |
| 186 | `f_svg/src/SvgBlendPixelsM5_test.cj` | .cj | ✅ | — |
| 187 | `f_svg/src/SvgBounds.cj` | .cj | ✅ | — |
| 188 | `f_svg/src/SvgBounds_test.cj` | .cj | ✅ | — |
| 189 | `f_svg/src/SvgBuilder.cj` | .cj | ✅ | — |
| 190 | `f_svg/src/SvgBuilderM7_test.cj` | .cj | ✅ | — |
| 191 | `f_svg/src/SvgCircle.cj` | .cj | ✅ | — |
| 192 | `f_svg/src/SvgClipMask.cj` | .cj | ✅ | — |
| 193 | `f_svg/src/SvgClipMask_test.cj` | .cj | ✅ | — |
| 194 | `f_svg/src/SvgClipProperty.cj` | .cj | ✅ | — |
| 195 | `f_svg/src/SvgClipPropertyM4_test.cj` | .cj | ✅ | — |
| 196 | `f_svg/src/SvgClipRenderM4_test.cj` | .cj | ✅ | — |
| 197 | `f_svg/src/SvgClock.cj` | .cj | ✅ | — |
| 198 | `f_svg/src/SvgClock_test.cj` | .cj | ✅ | — |
| 199 | `f_svg/src/SvgColor.cj` | .cj | ✅ | — |
| 200 | `f_svg/src/SvgColor_test.cj` | .cj | ✅ | — |
| 201 | `f_svg/src/SvgComputedStyle.cj` | .cj | ✅ | — |
| 202 | `f_svg/src/SvgComputedStyleM4_test.cj` | .cj | ✅ | — |
| 203 | `f_svg/src/SvgComputedStyleM5_test.cj` | .cj | ✅ | — |
| 204 | `f_svg/src/SvgComputedStyleM6_test.cj` | .cj | ✅ | — |
| 205 | `f_svg/src/SvgComputedStyle_test.cj` | .cj | ✅ | — |
| 206 | `f_svg/src/SvgContainer.cj` | .cj | ✅ | — |
| 207 | `f_svg/src/SvgContainer_test.cj` | .cj | ✅ | — |
| 208 | `f_svg/src/SvgContentCycleM3_test.cj` | .cj | ✅ | — |
| 209 | `f_svg/src/SvgContextPaint.cj` | .cj | ✅ | — |
| 210 | `f_svg/src/SvgContextPaintM5_test.cj` | .cj | ✅ | — |
| 211 | `f_svg/src/SvgContextPaintRenderM5_test.cj` | .cj | ✅ | — |
| 212 | `f_svg/src/SvgCrc32.cj` | .cj | ✅ | — |
| 213 | `f_svg/src/SvgCrc32_test.cj` | .cj | ✅ | — |
| 214 | `f_svg/src/SvgCursor.cj` | .cj | ✅ | — |
| 215 | `f_svg/src/SvgCursorM6_test.cj` | .cj | ✅ | — |
| 216 | `f_svg/src/SvgDecorationM6_test.cj` | .cj | ✅ | — |
| 217 | `f_svg/src/SvgDirectionM5_test.cj` | .cj | ✅ | — |
| 218 | `f_svg/src/SvgDiscardM6_test.cj` | .cj | ✅ | — |
| 219 | `f_svg/src/SvgDocument.cj` | .cj | ✅ | — |
| 220 | `f_svg/src/SvgDocumentApiM4_test.cj` | .cj | ✅ | — |
| 221 | `f_svg/src/SvgDocument_test.cj` | .cj | ✅ | — |
| 222 | `f_svg/src/SvgDomApiM6_test.cj` | .cj | ✅ | — |
| 223 | `f_svg/src/SvgDropShadowM5_test.cj` | .cj | ✅ | — |
| 224 | `f_svg/src/SvgDropShadowRenderM5_test.cj` | .cj | ✅ | — |
| 225 | `f_svg/src/SvgElement.cj` | .cj | ✅ | — |
| 226 | `f_svg/src/SvgElementApi.cj` | .cj | ✅ | — |
| 227 | `f_svg/src/SvgElementApiM5_test.cj` | .cj | ✅ | — |
| 228 | `f_svg/src/SvgElementBlendM5_test.cj` | .cj | ✅ | — |
| 229 | `f_svg/src/SvgElementFilterM3_test.cj` | .cj | ✅ | — |
| 230 | `f_svg/src/SvgElement_test.cj` | .cj | ✅ | — |
| 231 | `f_svg/src/SvgEllipse.cj` | .cj | ✅ | — |
| 232 | `f_svg/src/SvgException.cj` | .cj | ✅ | — |
| 233 | `f_svg/src/SvgException_test.cj` | .cj | ✅ | — |
| 234 | `f_svg/src/SvgExternalDocument.cj` | .cj | ✅ | — |
| 235 | `f_svg/src/SvgExternalDocumentM6_test.cj` | .cj | ✅ | — |
| 236 | `f_svg/src/SvgFilter.cj` | .cj | ✅ | — |
| 237 | `f_svg/src/SvgFilterBuffer.cj` | .cj | ✅ | — |
| 238 | `f_svg/src/SvgFilterLighting.cj` | .cj | ✅ | — |
| 239 | `f_svg/src/SvgFilterLightingM4_test.cj` | .cj | ✅ | — |
| 240 | `f_svg/src/SvgFilterModelM4_test.cj` | .cj | ✅ | — |
| 241 | `f_svg/src/SvgFilterNoiseM4_test.cj` | .cj | ✅ | — |
| 242 | `f_svg/src/SvgFilterPrimitive.cj` | .cj | ✅ | — |
| 243 | `f_svg/src/SvgFilterPrimitive_test.cj` | .cj | ✅ | — |
| 244 | `f_svg/src/SvgFilterPrimitives.cj` | .cj | ✅ | — |
| 245 | `f_svg/src/SvgFilterPrimitives2.cj` | .cj | ✅ | — |
| 246 | `f_svg/src/SvgFilterPrimitives2M4_test.cj` | .cj | ✅ | — |
| 247 | `f_svg/src/SvgFilterRenderer.cj` | .cj | ✅ | — |
| 248 | `f_svg/src/SvgFilterRenderer_test.cj` | .cj | ✅ | — |
| 249 | `f_svg/src/SvgFilterTileChainM3_test.cj` | .cj | ✅ | — |
| 250 | `f_svg/src/SvgFilter_test.cj` | .cj | ✅ | — |
| 251 | `f_svg/src/SvgFont.cj` | .cj | ✅ | — |
| 252 | `f_svg/src/SvgFontDetailsM6_test.cj` | .cj | ✅ | — |
| 253 | `f_svg/src/SvgFontFeatureApplyM6_test.cj` | .cj | ✅ | — |
| 254 | `f_svg/src/SvgFontStretchMatchM6_test.cj` | .cj | ✅ | — |
| 255 | `f_svg/src/SvgFontVariant.cj` | .cj | ✅ | — |
| 256 | `f_svg/src/SvgFont_test.cj` | .cj | ✅ | — |
| 257 | `f_svg/src/SvgForeignObject.cj` | .cj | ✅ | — |
| 258 | `f_svg/src/SvgForeignObjectM6_test.cj` | .cj | ✅ | — |
| 259 | `f_svg/src/SvgGeometry.cj` | .cj | ✅ | — |
| 260 | `f_svg/src/SvgGeometryApiM4_test.cj` | .cj | ✅ | — |
| 261 | `f_svg/src/SvgGeometry_test.cj` | .cj | ✅ | — |
| 262 | `f_svg/src/SvgGradient.cj` | .cj | ✅ | — |
| 263 | `f_svg/src/SvgGradientColorSpaceM6_test.cj` | .cj | ✅ | — |
| 264 | `f_svg/src/SvgGradientSampler_test.cj` | .cj | ✅ | — |
| 265 | `f_svg/src/SvgGradient_test.cj` | .cj | ✅ | — |
| 266 | `f_svg/src/SvgGroupCompositorM5_test.cj` | .cj | ✅ | — |
| 267 | `f_svg/src/SvgGsubContext.cj` | .cj | ✅ | — |
| 268 | `f_svg/src/SvgGsubContextM6_test.cj` | .cj | ✅ | — |
| 269 | `f_svg/src/SvgGzip.cj` | .cj | ✅ | — |
| 270 | `f_svg/src/SvgGzip_test.cj` | .cj | ✅ | — |
| 271 | `f_svg/src/SvgHersheyFont.cj` | .cj | ✅ | — |
| 272 | `f_svg/src/SvgHitQueries.cj` | .cj | ✅ | — |
| 273 | `f_svg/src/SvgHitTest.cj` | .cj | ✅ | — |
| 274 | `f_svg/src/SvgHitTestM6_test.cj` | .cj | ✅ | — |
| 275 | `f_svg/src/SvgImage.cj` | .cj | ✅ | — |
| 276 | `f_svg/src/SvgImageResource.cj` | .cj | ✅ | — |
| 277 | `f_svg/src/SvgImageResource_test.cj` | .cj | ✅ | — |
| 278 | `f_svg/src/SvgInitialView.cj` | .cj | ✅ | — |
| 279 | `f_svg/src/SvgInitialViewM6_test.cj` | .cj | ✅ | — |
| 280 | `f_svg/src/SvgInterpolator.cj` | .cj | ✅ | — |
| 281 | `f_svg/src/SvgInterpolator_test.cj` | .cj | ✅ | — |
| 282 | `f_svg/src/SvgKernTableM5_test.cj` | .cj | ✅ | — |
| 283 | `f_svg/src/SvgKerningLayoutM5_test.cj` | .cj | ✅ | — |
| 284 | `f_svg/src/SvgLength.cj` | .cj | ✅ | — |
| 285 | `f_svg/src/SvgLengthContext_test.cj` | .cj | ✅ | — |
| 286 | `f_svg/src/SvgLength_test.cj` | .cj | ✅ | — |
| 287 | `f_svg/src/SvgLimitsM3_test.cj` | .cj | ✅ | — |
| 288 | `f_svg/src/SvgLimitsM4_test.cj` | .cj | ✅ | — |
| 289 | `f_svg/src/SvgLine.cj` | .cj | ✅ | — |
| 290 | `f_svg/src/SvgLineJoinM6_test.cj` | .cj | ✅ | — |
| 291 | `f_svg/src/SvgLinearGradient.cj` | .cj | ✅ | — |
| 292 | `f_svg/src/SvgMarker.cj` | .cj | ✅ | — |
| 293 | `f_svg/src/SvgMarkerExpander.cj` | .cj | ✅ | — |
| 294 | `f_svg/src/SvgMarkerExpander_test.cj` | .cj | ✅ | — |
| 295 | `f_svg/src/SvgMarker_test.cj` | .cj | ✅ | — |
| 296 | `f_svg/src/SvgMatrix.cj` | .cj | ✅ | — |
| 297 | `f_svg/src/SvgMatrix_test.cj` | .cj | ✅ | — |
| 298 | `f_svg/src/SvgMutation.cj` | .cj | ✅ | — |
| 299 | `f_svg/src/SvgNamespaces.cj` | .cj | ✅ | — |
| 300 | `f_svg/src/SvgNode.cj` | .cj | ✅ | — |
| 301 | `f_svg/src/SvgNumber.cj` | .cj | ✅ | — |
| 302 | `f_svg/src/SvgNumberList.cj` | .cj | ✅ | — |
| 303 | `f_svg/src/SvgNumberList_test.cj` | .cj | ✅ | — |
| 304 | `f_svg/src/SvgNumber_test.cj` | .cj | ✅ | — |
| 305 | `f_svg/src/SvgOpenTypeLayout.cj` | .cj | ✅ | — |
| 306 | `f_svg/src/SvgOpenTypeLayoutM5_test.cj` | .cj | ✅ | — |
| 307 | `f_svg/src/SvgOptions.cj` | .cj | ✅ | — |
| 308 | `f_svg/src/SvgOverflow.cj` | .cj | ✅ | — |
| 309 | `f_svg/src/SvgOverflowM3_test.cj` | .cj | ✅ | — |
| 310 | `f_svg/src/SvgOverflowM4_test.cj` | .cj | ✅ | — |
| 311 | `f_svg/src/SvgPaint.cj` | .cj | ✅ | — |
| 312 | `f_svg/src/SvgPaintOrder.cj` | .cj | ✅ | — |
| 313 | `f_svg/src/SvgPaintOrderM5_test.cj` | .cj | ✅ | — |
| 314 | `f_svg/src/SvgPaintOrderRenderM5_test.cj` | .cj | ✅ | — |
| 315 | `f_svg/src/SvgPaint_test.cj` | .cj | ✅ | — |
| 316 | `f_svg/src/SvgParser.cj` | .cj | ✅ | — |
| 317 | `f_svg/src/SvgParser_test.cj` | .cj | ✅ | — |
| 318 | `f_svg/src/SvgPath.cj` | .cj | ✅ | — |
| 319 | `f_svg/src/SvgPathBounds_test.cj` | .cj | ✅ | — |
| 320 | `f_svg/src/SvgPathData.cj` | .cj | ✅ | — |
| 321 | `f_svg/src/SvgPathData_test.cj` | .cj | ✅ | — |
| 322 | `f_svg/src/SvgPathLength.cj` | .cj | ✅ | — |
| 323 | `f_svg/src/SvgPathMeasure.cj` | .cj | ✅ | — |
| 324 | `f_svg/src/SvgPattern.cj` | .cj | ✅ | — |
| 325 | `f_svg/src/SvgPatternSampler.cj` | .cj | ✅ | — |
| 326 | `f_svg/src/SvgPatternSampler_test.cj` | .cj | ✅ | — |
| 327 | `f_svg/src/SvgPatternViewBoxM4_test.cj` | .cj | ✅ | — |
| 328 | `f_svg/src/SvgPattern_test.cj` | .cj | ✅ | — |
| 329 | `f_svg/src/SvgPelicanBikeM7_test.cj` | .cj | ✅ | — |
| 330 | `f_svg/src/SvgPerfM5_test.cj` | .cj | ✅ | — |
| 331 | `f_svg/src/SvgPngDecoder.cj` | .cj | ✅ | — |
| 332 | `f_svg/src/SvgPngDecoder_test.cj` | .cj | ✅ | — |
| 333 | `f_svg/src/SvgPngEncoder.cj` | .cj | ✅ | — |
| 334 | `f_svg/src/SvgPngEncoder_test.cj` | .cj | ✅ | — |
| 335 | `f_svg/src/SvgPointList.cj` | .cj | ✅ | — |
| 336 | `f_svg/src/SvgPointerEvents.cj` | .cj | ✅ | — |
| 337 | `f_svg/src/SvgPointerEventsM6_test.cj` | .cj | ✅ | — |
| 338 | `f_svg/src/SvgPolygon.cj` | .cj | ✅ | — |
| 339 | `f_svg/src/SvgPolyline.cj` | .cj | ✅ | — |
| 340 | `f_svg/src/SvgPreserveAspectRatio.cj` | .cj | ✅ | — |
| 341 | `f_svg/src/SvgPreserveAspectRatio_test.cj` | .cj | ✅ | — |
| 342 | `f_svg/src/SvgRadialGradient.cj` | .cj | ✅ | — |
| 343 | `f_svg/src/SvgRasterizer.cj` | .cj | ✅ | — |
| 344 | `f_svg/src/SvgRasterizer_test.cj` | .cj | ✅ | — |
| 345 | `f_svg/src/SvgRect.cj` | .cj | ✅ | — |
| 346 | `f_svg/src/SvgRenderGuard.cj` | .cj | ✅ | — |
| 347 | `f_svg/src/SvgRenderOptionsM4_test.cj` | .cj | ✅ | — |
| 348 | `f_svg/src/SvgRenderTree.cj` | .cj | ✅ | — |
| 349 | `f_svg/src/SvgRenderTree_test.cj` | .cj | ✅ | — |
| 350 | `f_svg/src/SvgRenderer.cj` | .cj | ✅ | — |
| 351 | `f_svg/src/SvgRenderer_test.cj` | .cj | ✅ | — |
| 352 | `f_svg/src/SvgRenderingHints.cj` | .cj | ✅ | — |
| 353 | `f_svg/src/SvgRenderingHintsM6_test.cj` | .cj | ✅ | — |
| 354 | `f_svg/src/SvgRoot.cj` | .cj | ✅ | — |
| 355 | `f_svg/src/SvgRootAttrsM6_test.cj` | .cj | ✅ | — |
| 356 | `f_svg/src/SvgRoot_test.cj` | .cj | ✅ | — |
| 357 | `f_svg/src/SvgRoundTripM4_test.cj` | .cj | ✅ | — |
| 358 | `f_svg/src/SvgRoundTrip_test.cj` | .cj | ✅ | — |
| 359 | `f_svg/src/SvgSceneM4_test.cj` | .cj | ✅ | — |
| 360 | `f_svg/src/SvgScene_test.cj` | .cj | ✅ | — |
| 361 | `f_svg/src/SvgSecurity_test.cj` | .cj | ✅ | — |
| 362 | `f_svg/src/SvgSet.cj` | .cj | ✅ | — |
| 363 | `f_svg/src/SvgShape.cj` | .cj | ✅ | — |
| 364 | `f_svg/src/SvgShape_test.cj` | .cj | ✅ | — |
| 365 | `f_svg/src/SvgSnapshotM5_test.cj` | .cj | ✅ | — |
| 366 | `f_svg/src/SvgSnapshotM6_test.cj` | .cj | ✅ | — |
| 367 | `f_svg/src/SvgStop.cj` | .cj | ✅ | — |
| 368 | `f_svg/src/SvgStrokeOutliner.cj` | .cj | ✅ | — |
| 369 | `f_svg/src/SvgStrokeOutliner_test.cj` | .cj | ✅ | — |
| 370 | `f_svg/src/SvgStyleResolver.cj` | .cj | ✅ | — |
| 371 | `f_svg/src/SvgStyleResolverM4_test.cj` | .cj | ✅ | — |
| 372 | `f_svg/src/SvgStyleResolverM6_test.cj` | .cj | ✅ | — |
| 373 | `f_svg/src/SvgSvg2M6_test.cj` | .cj | ✅ | — |
| 374 | `f_svg/src/SvgSwitch.cj` | .cj | ✅ | — |
| 375 | `f_svg/src/SvgTag.cj` | .cj | ✅ | — |
| 376 | `f_svg/src/SvgText.cj` | .cj | ✅ | — |
| 377 | `f_svg/src/SvgTextBaseline.cj` | .cj | ✅ | — |
| 378 | `f_svg/src/SvgTextBaselineM4_test.cj` | .cj | ✅ | — |
| 379 | `f_svg/src/SvgTextDecoration.cj` | .cj | ✅ | — |
| 380 | `f_svg/src/SvgTextDecoration2.cj` | .cj | ✅ | — |
| 381 | `f_svg/src/SvgTextDecorationM4_test.cj` | .cj | ✅ | — |
| 382 | `f_svg/src/SvgTextElement.cj` | .cj | ✅ | — |
| 383 | `f_svg/src/SvgTextElement_test.cj` | .cj | ✅ | — |
| 384 | `f_svg/src/SvgTextLayoutCacheM4_test.cj` | .cj | ✅ | — |
| 385 | `f_svg/src/SvgTextPath.cj` | .cj | ✅ | — |
| 386 | `f_svg/src/SvgTextPathExtensionM4_test.cj` | .cj | ✅ | — |
| 387 | `f_svg/src/SvgTextPathLayout.cj` | .cj | ✅ | — |
| 388 | `f_svg/src/SvgTextPathLayout_test.cj` | .cj | ✅ | — |
| 389 | `f_svg/src/SvgTextPathLengthM6_test.cj` | .cj | ✅ | — |
| 390 | `f_svg/src/SvgTextPathModel_test.cj` | .cj | ✅ | — |
| 391 | `f_svg/src/SvgTextRenderer.cj` | .cj | ✅ | — |
| 392 | `f_svg/src/SvgTextRenderer_test.cj` | .cj | ✅ | — |
| 393 | `f_svg/src/SvgTextToleranceM6_test.cj` | .cj | ✅ | — |
| 394 | `f_svg/src/SvgTextWritingMode.cj` | .cj | ✅ | — |
| 395 | `f_svg/src/SvgTextWritingModeM4_test.cj` | .cj | ✅ | — |
| 396 | `f_svg/src/SvgTimeline.cj` | .cj | ✅ | — |
| 397 | `f_svg/src/SvgTransform.cj` | .cj | ✅ | — |
| 398 | `f_svg/src/SvgTransformBox.cj` | .cj | ✅ | — |
| 399 | `f_svg/src/SvgTransformBoxM5_test.cj` | .cj | ✅ | — |
| 400 | `f_svg/src/SvgTransformOrigin.cj` | .cj | ✅ | — |
| 401 | `f_svg/src/SvgTransformOriginM5_test.cj` | .cj | ✅ | — |
| 402 | `f_svg/src/SvgTransformOriginRenderM5_test.cj` | .cj | ✅ | — |
| 403 | `f_svg/src/SvgTransformPathM5_test.cj` | .cj | ✅ | — |
| 404 | `f_svg/src/SvgTransform_test.cj` | .cj | ✅ | — |
| 405 | `f_svg/src/SvgTrueTypeFont.cj` | .cj | ✅ | — |
| 406 | `f_svg/src/SvgTrueTypeM4_test.cj` | .cj | ✅ | — |
| 407 | `f_svg/src/SvgTrueTypeTables.cj` | .cj | ✅ | — |
| 408 | `f_svg/src/SvgTrueTypeTables_test.cj` | .cj | ✅ | — |
| 409 | `f_svg/src/SvgTspan.cj` | .cj | ✅ | — |
| 410 | `f_svg/src/SvgUnknownElement.cj` | .cj | ✅ | — |
| 411 | `f_svg/src/SvgUse.cj` | .cj | ✅ | — |
| 412 | `f_svg/src/SvgUse_test.cj` | .cj | ✅ | — |
| 413 | `f_svg/src/SvgValueTypesM3_test.cj` | .cj | ✅ | — |
| 414 | `f_svg/src/SvgValueTypesM4_test.cj` | .cj | ✅ | — |
| 415 | `f_svg/src/SvgVectorEffect.cj` | .cj | ✅ | — |
| 416 | `f_svg/src/SvgVectorEffect2.cj` | .cj | ✅ | — |
| 417 | `f_svg/src/SvgVectorEffectM4_test.cj` | .cj | ✅ | — |
| 418 | `f_svg/src/SvgVectorEffectMultiM6_test.cj` | .cj | ✅ | — |
| 419 | `f_svg/src/SvgView.cj` | .cj | ✅ | — |
| 420 | `f_svg/src/SvgViewBox.cj` | .cj | ✅ | — |
| 421 | `f_svg/src/SvgViewBox_test.cj` | .cj | ✅ | — |
| 422 | `f_svg/src/SvgViewState2.cj` | .cj | ✅ | — |
| 423 | `f_svg/src/SvgViewport.cj` | .cj | ✅ | — |
| 424 | `f_svg/src/SvgViewport_test.cj` | .cj | ✅ | — |
| 425 | `f_svg/src/SvgWriter.cj` | .cj | ✅ | — |
| 426 | `f_svg/src/SvgWriter_test.cj` | .cj | ✅ | — |
| 427 | `f_svg/src/f_svg.cj` | .cj | ✅ | — |
| 428 | `f_svg/testdata/fonts/README.md` | .md | ✅ | — |
| 429 | `f_svg/testdata/fonts/m5-bidi/README.md` | .md | ✅ | — |
| 430 | `f_svg/testdata/fonts/m5-gpos/README.md` | .md | ✅ | — |
| 431 | `f_svg/testdata/fonts/m5-gsub/README.md` | .md | ✅ | — |
| 432 | `f_svg/testdata/fonts/m5-kern/README.md` | .md | ✅ | — |
| 433 | `f_svg/testdata/render/m3-negative/README.md` | .md | ✅ | — |
| 434 | `f_svg/testdata/render/m3/README.md` | .md | ✅ | — |
| 435 | `f_svg/testdata/render/m5-bidi/README.md` | .md | ✅ | — |
| 436 | `f_svg/testdata/render/m5-blend/README.md` | .md | ✅ | — |
| 437 | `f_svg/testdata/render/m5-drop-shadow/README.md` | .md | ✅ | — |
| 438 | `f_svg/testdata/render/m5-element-api/README.md` | .md | ✅ | — |
| 439 | `f_svg/testdata/render/m5-media/README.md` | .md | ✅ | — |
| 440 | `f_svg/testdata/render/m5-selector/README.md` | .md | ✅ | — |
| 441 | `f_svg/testdata/render/m5-shaping/README.md` | .md | ✅ | — |
| 442 | `f_svg/testdata/render/m5-transform-origin/README.md` | .md | ✅ | — |

合计：`.cj` 301 个 / `.md` 141 个 / 共 442 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1（字段当方法，示例编译失败）、#5（实例方法写成类级）；安全性 #2（`Keep` 覆盖 `allow*`）、#3（「无文件访问」与 `load` 冲突）；#10 的 MIME 范围记在 §13 |
| §1 死代码 | 0 | 本部分无声明可判死代码；已做等价机械检查：132 个库文件里的 247 个公开顶层声明逐个 `grep`，全部出现在 README（0 幽灵 API）；README 引用的 18 个符号（`tryParse` / `SvgLengthContext.of` / `toUserUnits` / `referencing` / `NoEffect` / `NoAlign` / `querySelectorAll` / `elementById` / `anchors` / `views` / `getIntersectionList` / `addMutationListener` / `hitTest` / `load` / `rootSize` / `elementPath` / `count` / `reset`）逐个定位到定义，唯二「不存在」是 `SvgBuilder` 接收既有文档（#4）与 `SvgException.elementPath()`（#1）；7 份文档的相对链接除 #7 外均可达 |
| §2 重复逻辑 | 1 | 能力矩阵在 README(zh/en) + M2–M6 共 6 处重复并已漂移三类（#11/#12/#13），合并计 1 条；README 中英互译属必要重复，不判 |
| §3 空实现 | 0 | 逐条核对文档承诺的入口均有实现（`views` / `anchors` / `getIntersectionList` / `hitTest` / `elementById` / `load` / `rootSize`）；7 份文档无空章节、无「暂不实现」占位；README「不支持」表 10 类逐项核对，`mesh` / `hatch` / `@keyframes` / `:has(` / `@supports` / `@layer` / `@container` / `vmtx` / `text-orientation` / `font-variation-settings` / `image-orientation` / `animateColor` / `content-box` / `skip-ink` / `text-emphasis` 在源码中确实零命中 |
| §4 栈溢出 | 0 | 文档声明的深度上限逐条核对存在：XML 深度 512（`SvgOptions.cj:66`）、`use` / 引用 / marker / pattern 深度 64（`SvgExternalDocument.cj:41`、`SvgRenderGuard.cj:21`、`SvgMarkerExpander.cj:25`、`SvgPatternSampler.cj:24`）、TTF 复合 8（`SvgTrueTypeFont.cj:51`）、GSUB 8（`SvgOpenTypeLayout.cj:23`）、`calc` 16（`CssCalc.cj:21`）；递归构建在 512 层前抛 `Limit`，未发现书面承诺缺口（栈占用只进待验证假设 2） |
| §5 OOM | 0 | 文档声明的上限全部与常量一致：元素数 1e6 / 深度 512 / 解压 64 MiB（`SvgOptions.cj:65-67`）、`maxPixels` 64 Mi（`SvgBitmap.cj:230`）、单图 16 Mi 与单次渲染 64 Mi（`SvgPngDecoder.cj:23-27`）、pattern tile 4 Mi（`SvgPatternSampler.cj:22`）、base64 32 MiB（`SvgImageResource.cj:70`）、外部文档 16 MiB（`SvgExternalDocument.cj:24`）、TTF 单表 16 MiB（`SvgTrueTypeTables.cj:24`）；`SvgGzip.decompress` 分块累计超限即抛 `Limit` |
| §6.1 热点瓶颈 | 0 | 本部分无代码，也未提供 profile / bench 数据；README:534 指向 `doc/perf-baseline.md`（不在本部分），未据此下热点结论 |
| §6.2 大粒度锁 | 0 | 文档无锁描述，本部分无临界区可判 |
| §6.3 并发串行 | 0 | 同上；README「不接事件循环 / 只做静态求值」与 `SvgHitTest` / `SvgTimeline` 的显式 API 一致 |
| §6.4 低效算法 | 0 | 本部分无算法实现，文档也未承诺复杂度 |
| §7 降堆内存方案 | 0 | 无代码、无基线，不写方案 |
| §8 降 CPU 方案 | 0 | 无基线数据，未写方案 |
| §9 local mode 可行性 | 0 | README:37 的 8 MiB 门限与 `SvgAnalyticRasterizer.cj:81-88` / `:200-201` 一致；只有该文件内部使用 `@ local!`，公开 API 不含模态类型，README「调用方无需开启 local mode」成立；收益缺峰值数据，只进待验证假设 1 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条发现全部为存量文档缺陷（#1–#14），无一条属本次改动（快照模式 `git diff` 为空）；为验证文档而撞见的代码问题只记「范围外提示」，不占统计 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程安全契约，也无共享状态描述；README「变更监听同步回调」与 `SvgDocument.cj:42-48` 一致 |
| §14 功能完备性与 README 覆盖 | 2 | #4（文档给出的替代路径无实现入口）、#8（把 `internal` 成员与 `@When[test]` 钩子列为公开 API）；反向覆盖无缺口：247 个公开顶层声明全部在 README 出现，`f_svg` 已登记在 `.modules:62`，版本 `1.3.2021` 与 `cjpm.toml:16` 一致 |
| 文件覆盖（§13 等） | 7/7 | 本部分清单 7 个 `.md` 全部读完；`README.md:559` 与 `README_en.md:570` 的超长单行已完整核对 |

### 第 2 部分

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

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性与契约 5 条：Paeth 期望值、Adam7 尺寸、marker 缺省值、feTile 四角、filter warning 定位性；本部分无源码，语言特性与分层不适用，可读性并入各条建议 |
| §1 死代码 | 0 | 无源码；改为对文档引用的文件与公开符号做存在性机械核对：tasks 1.4 的 13 个 `.cj`、14 个测试类、5 组 `testdata/render/m3-*`、`allowDataImages`、`maxDecompressedBytes`、`SvgRenderOptions` 九个 M3 字段、7 个新枚举、8 个 `SvgFe*` + `SvgFeMergeNode` 全部命中；无「引用了不存在的代码符号」（文档文件名偏差已并入单一事实源条目） |
| §2 重复逻辑 | 1 | 对 m3 与 m6 的同名 spec 逐文件 `diff`：`svg-security`、`svg-render-pipeline` 等是同一 Requirement 集合的多份演进副本且语义已分叉，合并为「单一事实源」一条；m3 内部 11 份 spec 按主题比对，无同一契约写两遍 |
| §3 空实现 | 0 | 20 个文件无空章节；「记录不改」的 W6/W8/W15/W16/S1–S6 均写明取舍；`tasks.md:184` 的未勾选项不是空实现，按 §14 计入 |
| §4 栈溢出 | 0 | 文档不执行递归；文中所有深度 64 条款（use / 嵌套 svg / 渐变 / pattern / marker / mpath）都有对应实现与 guard，属源码部分 |
| §5 OOM | 0 | 文档只声明上限表（16 Mi / 64 Mi / 4 Mi / 32 MiB / 64 MiB / maxPixels）；7 项数值与 png / pattern / gzip / image 各处一致，无推导错误 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，`doc/perf-baseline.md` 不在本清单；不产生热点结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁描述 |
| §6.3 并发串行 | 0 | 纯文档，无并发描述 |
| §6.4 低效算法 | 0 | `svg-rasterization/spec.md:76-83` 已把 8×8 / 子扫描线收敛为「有符号面积」，规格侧定义正确；实现落差属源码部分 |
| §7 降堆内存方案 | 0 | 文档不持有对象，无可量化峰值 |
| §8 降 CPU 方案 | 0 | 文档只承载「参考、非门禁」的基准口径，无耗时数据 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时对象；无可证明的峰值收益 |
| §11 现有代码的 BUG（存量） | 4 | 四条与实现冲突（Paeth、Adam7、marker 缺省值、warning 定位性），均给出文档行号 + 代码行号；其余为文档内部或文档之间的不一致（§13） |
| §12 并发安全与锁粒度 | 0 | 纯文档；`SvgRenderGuard` 的可重入与异常安全只在 `verification-2.md:116-118` 记录过，属源码面 |
| §14 功能完备性与 README 覆盖 | 1 | 仅「M3 规格未合并、归档任务未勾选、`openspec` 侧无 `svg-*`」一条；README 覆盖需以 `README.md` 为基准，属本模块 README 部分 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完，无缺 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，值/引用语义、`Option` 惯用法、`mut` 不适用；文档层面的契约不符分别计入 §5（2 条）、§13（12 条）、§14（1 条），不在此重复计数。注入/转义专项已单独核对：元素写回路径在 `SvgElement.cj:424` / `:434` 调用 `escapeSvgAttribute` / `escapeSvgText`（`:705`、`:718`，`& < > "` 全覆盖），本部分未发现转义缺失或外部实体相关承诺 |
| §1 死代码 | 0 | 18 个文件全为 `.md`，无声明可判。改为核对文档声明的公开符号是否都有消费点：`SvgView`/`SvgAnchorInfo`/`SvgViewportTransform`/`SvgTrueTypeFont`/`SvgBaselineShift`/`SvgTextDecoration`/`SvgWritingMode`/`SvgOverflow`/`SvgVectorEffect`/5 组滤镜枚举全部命中定义与使用；唯一"声明了但无效果"的是 `stitchTiles`，按 §14 计入 #6；`tasks.md` 点名的 14 个新源文件全部存在 |
| §2 重复逻辑 | 0 | 已逐对比对 18 份文档：`screenCTM` 公式在 `design.md:170` 与 `svg-geometry/spec.md:68` 重复且同错，已并入 #1（重复导致错误扩散，不单列）；`proposal` / `design` / `tasks` 的 Goals-NonGoals 与任务清单属变更模板，不判重复；三轮 `fix-plan` 是流程演进，非同一实现两份 |
| §3 空实现 | 0 | 未发现空函数或空分支：8 个新原语、基线/装饰/竖排、TTF、view/switch/anchors 都有实现。`stitchTiles` 不是空函数而是无消费点，按 §14.1 计入 #6，本行不重复计；`tasks.md` 18 节均指向存在的文件或已定位的落点（#9 仅文件名不符） |
| §4 栈溢出 | 0 | 文档涉及的递归都有显式上界：TTF 复合字形深度 8（`SvgTrueTypeFont.cj:49-51`）、pattern/marker 引用 64（`SvgRenderGuard.cj:21`）、`maxDepth` 默认 512（`SvgOptions.cj:66`）；`SvgPathMeasure` 为迭代实现，曲线细分深度封顶 16（放大分配，已计入 §5，不是栈溢出） |
| §5 OOM | 2 | #5（路径测量无点数/段数预算，每次调用重建整表）、#8（`load` 整文件物化、无文件字节上限）。两者均给出量化结构或上限建议；具体峰值内存待实测（待验证 1） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；`glyphPath` 重复解析、卷积/湍流、`textPath` 逐段扫描三条线索转「待验证假设」#5，不作结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁路径；`design.md:60` 声明派生数据只存在于本次渲染，无共享可变状态 |
| §6.3 并发串行 | 0 | 文档无 `spawn` / `Future` / 线程池 / 定时任务描述 |
| §6.4 低效算法 | 0 | 结构性线索（`SvgPathMeasure.totalLength` 每次重建、`sample` 线性扫描段表）缺输入规模与耗时数据，只进待验证假设，不写成缺陷 |
| §7 降堆内存方案 | 0 | 文档无持有对象；#5/#8 是补上限的缺陷修复，未包装成优化方案；无基线不做收益断言 |
| §8 降 CPU 方案 | 0 | 同上；`tasks.md:136` 的基准标注"参考、非门禁"，无绝对值与中位数，不足以支撑结论 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时大对象；渲染产物必须作为位图返回（逃逸），"函数返回即释放"前提不成立；且无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 0 | 本轮文件全为 `.md`，仅在取证时读实现：`screenCTM` 实现顺序与 `fix-plan.md:20-26` 的修正一致（错的是文档，#1）；C3 除法防护（`SvgPngDecoder.cj:92`、`SvgBitmap.cj:98`）、`SVG_MAX_REFERENCE_DEPTH = 64`、`SvgSwitch` 特性表、`SvgTrueTypeFont.load` 的 `Syntax` 包装均与文档相符；`stitchTiles` 的"属性无消费"已计入 §14/#6，不重复计 |
| §12 并发安全与锁粒度 | 0 | 纯文档；`SvgRenderOptions` 只加不可变字段 `languages`，渲染器按调用构造；`SvgTrueTypeFont` 字段均为 `private let`（`:93-117`），无跨线程可变缓存 |
| §13 文档一致性（.md） | 12 | #1 公式相反、#2 兼容性漏 `switch`、#3 继承性与 SVG 1.1 相反、#4 `mathematical` 口径、#7 validate 结论矛盾、#9 测试文件路径失效、#10 `verify-report*` / "§8" / `openspec` 死引用、#11 `## 6` 重号与标记重复、#12 21 vs 14、#13 W17 状态相反、#14 原语计数三口径、#15 `side` 方向矛盾。其余条款逐条落到实现行核对：8 个属性注册与初始值、15 个 `fe*` 标签、10 个 delta 能力、7 组枚举字符串、4 项上限、`languages` 默认值均一致 |
| §14 功能完备性与 README 覆盖 | 1 | #6（`stitchTiles` 有属性无行为、无 Scenario）。README 覆盖属其他子轮，未越界判断；`#2` 的 `switch` 差异披露计入 §13 |
| 文件覆盖（§13 等） | 18/18 | 18 个 `.md` 全部逐行读完，无缺 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码。语义不符按 §11/§13 计 10 条；注入与 XML 边界专项：规格只在 `svg-css` 要求「不加载外部资源、不发网络请求」，`src: url` 路径已确认不读文件，未发现转义/实体相关承诺缺失 |
| §1 死代码 | 1 | 无源码可判。改为核对文档声明的符号是否都有定义与消费点：`SvgMixBlendMode`（73 处）、`SvgTransformBox`（24 处）、`SvgPaintOrder`、`SvgContextPaint`、`SvgBidi`、`SvgElementApi` 全部命中；`design.md` D10 的 `SvgShapingFont` / `SvgShapedRun` / `glyphId` / `glyphPathById` 在 `src` 与 git 历史均无命中（发现 #9）。`CssFontFaceRule.weight/style` 有定义无消费，按功能未落地计入 §14（发现 #3），不重复计死代码 |
| §2 重复逻辑 | 1 | 逐份比对 10 份 M5 spec 与 M4 design 的同一契约：`paint-order`（value-types / render-pipeline）、`calc`（css / design D3）、`context-*`（css 注册 / paint 语义）、`feDropShadow`（document-model / filter）均分层描述、无行为漂移；唯一字面重复是 `svg-value-types` 的两条 Scenario（发现 #5） |
| §3 空实现 | 0 | 未发现「承诺但实现为空」：P1–P4 共 24 个子项均能在 `src/` 找到实现与测试；`fix-plan` 记录的「记录不改」两项（weight/style、`<use>` 自身混合）已在发现 #3 单列，其余不属于空实现 |
| §4 栈溢出 | 0 | 规格涉及的递归都有显式上界：GSUB lookup 深度 8（`SvgOpenTypeLayout.cj:140-180` 走 Extension 链才递增）、CSS 变量 8 层、`calc` 16 层、选择器 256 个简单选择器；`bidi` 嵌入栈深度在 `design.md:128` 定为 64/16 并 warning |
| §5 OOM | 0 | 规格的七项上限全部在分配前检查（`CssVariables.cj:62`、`CssCalc.cj:185`、`SvgOpenTypeLayout.cj:233,388,412`），`kern`/`GPOS` 超限整表忽略而非部分加载；本部分未发现新的无界物化承诺 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`getBBox` 51 ms 与 `build` 三次样式计算两条线索转「待验证假设」，不作结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁描述；规格未声明线程安全契约，无可判对象 |
| §6.3 并发串行 | 0 | 纯文档，无 `spawn` / `Future` 路径 |
| §6.4 低效算法 | 0 | 唯一结构性线索是 `getBBox` 每次从根重算样式（`svg-geometry` 规格 `:11` 明确不缓存），缺调用频次数据，转「待验证假设」#1 |
| §7 降堆内存方案 | 0 | 文档无持有对象，不产出内存方案 |
| §8 降 CPU 方案 | 0 | 无基线数据，不做「能降 X%」的断言 |
| §9 local mode 可行性 | 0 | 本部分无函数体；M5 规格未引入 local mode 相关类型或标注 |
| §11 现有代码的 BUG（存量） | 1 | 发现 #4（告警文案陈述与行为相反）；另核对 `:empty` 全空白视为空、`transform-origin` 单值补 `center`、`SvgFeDropShadow` 缺省 2/黑/1 三处易错点，均与实现一致，未计 |
| §12 并发安全与锁粒度 | 0 | 纯文档；规格中的 `SvgFontRegistry.derived` 明确「不写入调用方注册表」，属不可变派生，未引入共享状态 |
| §13 文档一致性（.md） | 8 | 发现 #1/#2/#3/#6/#7/#8/#9/#10；另核对 `openspec/changes/add-f-svg-m4|m5` 与 `openspec/specs/svg-*` 死引用——该根因已由 part3/part4 记录，本部分不重复计数 |
| §14 功能完备性与 README 覆盖 | 2 | 发现 #3（别名区分未实现）、#8（`auto` 分支未入规格）；README 覆盖以 `README.md` 为基准，属本模块 README 部分，本部分不重复计 |
| 文件覆盖（§13 等） | 18/18 | 18 个 `.md` 全部逐行读完，无缺 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 文档承诺与实现语义不符 2 处（发现 #1、#2）；其余规格条款逐条对照实现通过。本部分无 `.cj`，语言特性与安全性（注入/转义）无直接载体；XML 边界与注入仅在 `svg-render-pipeline` / `svg-document-model` 中以外部文档、`foreignObject` 形式出现，其 `unsafePolicy=Remove`、`allowExternalReferences=false`、`maxPixels` 校验均已核对成立 |
| §1 死代码 | 0 | 本部分无代码。按「文档层面的死引用」机械核对：design/proposal 提到的每个新文件、每个公开符号是否可解析——3 个文件不存在、3 处行号锚点失效、`SvgGsubFeatureSet` 无定义，已合并进发现 #3，不重复计入 |
| §2 重复逻辑 | 0 | 已两两比对 15 份文档的功能重叠：`fix-plan` / `fix-plan-2` / `fix-plan-3` 是三轮独立记录，`verification` / `verification-2` 是两轮记录，属历史版本而非重复实现；7 份 delta 规格各自覆盖不同能力域，无同义 Requirement；proposal Impact 与 design D18 的清单差异按 §13 计（#3），不重复计入 |
| §3 空实现 | 0 | 逐份检查 `TBD` / `TODO` / 「待补」：7 份 m6 规格无占位；`tasks.md` 未勾选项仅 13.7（合并分支，流程项）；m5 `verification.md:440-445` 的「记录不改项」逐条点名能力与原因，无无归属的占位承诺 |
| §4 栈溢出 | 0 | 文档中唯一的递归语义是 `use` 展开：`svg-render-pipeline` 要求「环引用在深度 64 终止并 warning」，实现 `SvgRenderTree.cj:976-984` 先查 `useStack` 再判 `useDepth`，环不进入深度抛错分支；`foreignObject`/外部文档不递归，无无界递归承诺 |
| §5 OOM | 0 | 文档承诺的每个上限都核对到实现：外部文档 16 MiB（`SVG_EXTERNAL_MAX_BYTES`）、特性条目 64（`SvgFontVariant.cj:111`）、监听器 32（`SvgMutation.cj:72`）、`foreignObject` 位图 `maxPixels`、命中 `maxElements`；无「全量物化」类承诺 |
| §6.1 热点瓶颈 | 0 | 本部分不含 profile / bench 数据（`perf-baseline.md` 不在本部分清单），唯一性能疑点（`linearRGB` 逐样本 `pow`）无自耗时占比，已列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 15 份文档不涉及锁；`svg-document-model` 的变更监听是同步调用，未承诺线程安全 |
| §6.3 并发串行 | 0 | 无 `spawn` / 批处理相关条款 |
| §6.4 低效算法 | 0 | 文档未规定算法复杂度；`getIntersectionList` 的 60–120 ms/1000 元素已有改前基线，缺改后对照，列入待验证假设 #2 |
| §7 降堆内存方案 | 0 | 本部分无内存持有路径描述；`design.md` 的「不引入跨调用缓存」与实现一致，无「缓存无界」承诺 |
| §8 降 CPU 方案 | 0 | 见待验证假设 #1（无基线，不写成方案） |
| §9 local mode 可行性 | 0 | 本部分文档未提出 local mode 改造；相关数据在 `doc/perf-baseline.md`（不在本部分清单），且已有「8 MiB 门限 / ohos 不支持」结论 |
| §11 现有代码的 BUG（存量） | 2 | 发现 #1（装饰色缺省值）、#2（`duration()` 与 `max`）；两者都是「规格承诺 × 实现行为」双证后判定，非纯文档措辞 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程安全，也未引入共享可变状态；`SvgTimeline` 的 `pause/unpause`/触发状态是实例内字段，与规格「所有状态在实例内」一致，无并发契约可核对 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 7 份 delta 规格共 39 Requirement / 178 Scenario，逐条核对存在性：公开类型/方法（`SvgPointerEvents`、`SvgZoomAndPan`、`SvgViewState`、`SvgHitTest.elementsAt`、`SvgTimeline.fireEvent` 等）全部在 `f_svg/src` 命中；偏差只在文档落点与计数，已归 §13（发现 #3、#5） |
| 文件覆盖（§13 等） | 15/15 | 无缺文件；15 个 `.md` 全部读完，与 `files/f_svg.part6.txt` 行数一致 |

### 第 7 部分

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

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`calc()` 溢出抛异常击穿 `Option` 契约（一般）；语言特性：`private class CssCalcValue` 只承载两个不可变字段，应是值类型（进优化方案）；可读性：不可达 `Some(left)`、两份同构循环。安全性：`calc()` 输入无长度上限，与栈溢出同源，已合并进严重项 |
| §1 死代码 | 1 | 已逐个核对：`CSS_CALC_MAX_DEPTH`（`:21`）在 `:185` 使用；`evaluateCssCalc`（`:55`）被 `SvgStyleResolver.cj:536` 与 3 个测试文件引用；`CssCalcUnit` / `CssCalcValue` / `formatCssCalcValue` / `CssCalcParser` 及其 6 个方法均有调用；`CssCalcUnit.==` 经 `left.unit != right.unit`（`:243`、`:255`、`:258`、`:263`）使用——手写 `==` 是项目统一约定（`f_svg/src` 内 90 处同形），不判冗余；`import fountain::f_base.*` 用于 `String.unsafeBytes()` 扩展（`f_base/src/UnsafeBytes.cj:23-28`），不是死 import。命中为 `:133`、`:160` 两处同源不可达语句（合并 1 条） |
| §2 重复逻辑 | 2 | 同文件 8 个函数体两两比对：`parseExpression` / `parseTerm` 同构且已守卫漂移；`formatCssCalcValue` 与 `SvgLength.toString`/`suffix()` 语义相同；`combineCssCalcAdd` / `combineCssCalcMul` 语义不同（加法要求同单位、乘法要求一侧为数字），不合并；`skipSpaces` 多处调用但是单一实现。跨文件未发现第二份 `calc()` 求值器（`grep '"calc("'` 只有 `SvgStyleResolver.cj:524` 一处前缀判断）；`isCssSpace/isCssDigit/isCssAlpha` 定义在 `CssLexer.cj:220-234`，非本文件重复定义 |
| §3 空实现 | 0 | 无空函数体、无 `TODO` / `FIXME`、无 `catch {}`；`parseAll` / `parsePrimary` 的 `None` 分支都是真实失败路径 |
| §4 栈溢出 | 1 | `parseUnary` 一元符号递归无上限（严重）。括号递归有 16 层守卫（`nestingLimit` 覆盖 16/17 两层），`parseExpression` / `parseTerm` 的递归只经由括号入口；`formatCssCalcValue` 无递归 |
| §5 OOM | 0 | 求值器只用 `String.unsafeBytes()` 视图（不复制，`f_base/src/UnsafeBytes.cj:24-28`）与 O(操作数) 个小对象，无按输入长度预分配的数组、无全局容器；唯一与规模相关的是递归深度，归 §4 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，`calc()` 求值占比未成立，已列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 无锁、无 `synchronized`、无共享可变状态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 队列；`CssCalcParser` 是每次调用新建的局部对象 |
| §6.4 低效算法 | 0 | 单遍扫描 + 递归下降，复杂度 O(输入长度)；无嵌套循环 / 热点 `contains` / `remove(at:0)`；每操作数一次子串 + 一次重扫属常数因子，无计时数据，进优化方案 |
| §7 降堆内存方案 | 1 | `CssCalcValue` 改 `struct`（无基线，待验证） |
| §8 降 CPU 方案 | 1 | 按字节直接解析数字、去子串与重扫（无基线，待验证） |
| §9 local mode 可行性 | 0 | 本文件无「函数内创建、函数内用完的大对象」，最大只是输入字节视图；`CssCalcValue` 对象数随操作数线性且极小，local region 记账成本大于收益；且按 local-mode 设计 D6，非 `Copyable` class 不 local 化，`CssCalcValue` 属同类 |
| §11 现有代码的 BUG（存量） | 2 | 已逐条核对 `parseAll`（尾随空白、残余字符）、`skipSpaces`、`parsePrimary`（空输入、缺 `)`、无数字、未知单位、`%` 两分支、多字节字符边界）、`parseUnary`（`+` / `-` 与空输入）、除零（`right.value == 0.0` 含 `-0.0`）、单位混用、`depth--` 失败路径不回退（失败即整体 `None`，无可观察后果）。命中为栈溢出与有限性守卫缺失。`10px-5px` 这类 CSS 非法的无空格写法会被接受（`:114-132` 不要求运算符两侧空白），属宽松接受、不产生错误值，记一句范围外提示不作问题 |
| §12 并发安全与锁粒度 | 0 | `CssCalcParser` / `CssCalcValue` 都是每次 `evaluateCssCalc` 内新建的局部对象，无字段被跨线程共享；`CSS_CALC_MAX_DEPTH` 是 `let` 常量。线程封闭成立，不需要同步 |
| §14 功能完备性与 README 覆盖 | 0 | 逐条核对本部分承诺源：`save(path: String)` / `save(path: Path)`（`SvgAuthoringBuilder.cj:61/66`）、`SvgBegin` 九个静态工厂（`SvgBegin.cj:35-87`）、四个生成枚举（`SvgAuthoringTypes.cj:19/43/64/94`）、local-mode 门限常量与除法谓词（`SvgAnalyticRasterizer.cj:82-97`）均实存；`SvgTag.isKnown` 对五个动画标签确为 `false`。`SvgBuilder` 另有 `write(output)` / `save(file: File)` 两个公开方法未进 `svg-authoring` 规格，但 `README.md:95`、`README_en.md:98` 已记录，按「API 已文档化」不判缺；README 中英覆盖情况由负责该文件的子轮核 |
| 文件覆盖（§13 等） | 18/18 | 清单 18 个文件全部读完，无缺失；§13 命中 4（proposal `Io`、M7 两份记录、spec 游标措辞、local-mode 行号），其余 13 个 `.md` 按「归档变更只核自洽」逐份比对未发现与实现相反或互相矛盾的陈述 |

### 第 9 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：索引漏分组（严重）、`An+B` 整数溢出（一般）、转义不解码导致静默不匹配（一般）；语言特性：`String` 逐字节切片违反字符边界（严重）、`Rune` 代理区（一般）；可读性：`while(true)` 尾部不可达、`toString` 循环内物化（轻微）；设计：两套选择器表示并存（轻微，计入 §1/§2）；安全性：与「不可信 CSS 文本」同源，已合并进上述各项，无独立的注入面（选择器 / 媒体查询只在本模块内消费，不拼 SQL、不拼 XML） |
| §1 死代码 | 3 | 已逐个核对：`CssLexer` 全部 `private`（`cssPunctuation` / `utf8Length` / `skipCssComment` / `scanCssString` / `consumeCssEscape` / `scanCssIdent` / `scanCssNumber` / `scanCssUrl` / `parseCssHexCodePoint` / `cssHexValue`）均有调用点；`internal`（`isCssSpace` / `isCssDigit` / `isCssHexDigit` / `isCssAlpha` / `isCssIdentByte` / `isCssIdentStart` / `isCssNumberStart` / `decodeCssIdent` / `skipCssSpaces` / `cssClassListContains` / `findCssClosingParen` / `parseCssAnB` / `cssAnBMatches` / `cssElement*` / `cssPseudoMatches` / `cssSequence*` / `cssAttributeMatches` / `splitCssWhitespaceWords` / `formatCssAnB` / `CSS_MAX_SIMPLE_SELECTORS` / `CssSelectorIndex` / `CssSimpleSequence`）在本包内均有引用；`protected` 声明：本部分 0 个；`public` 全部对外可达（顶层 `public` 类型 / 枚举 / 结构体，嵌套链无 `internal`）；`import fountain::f_base.*` 经核实是 `String.unsafeBytes()` 扩展的来源（`f_base/src/UnsafeBytes.cj:23-28`），不是死 import。命中为 `cssPartMatches` 与两处 legacy 分支（`CssSelectorPart.toString` / `CssSelector` 特异性计算）、两处 `while(true)` 之后的 `false`、`cssAttributeMatches` 第二个 `case Exists` |
| §2 重复逻辑 | 2 | 同文件两两比对：`CssLexer` 的 `scanCssString` / `scanCssUrl` / `scanCssIdent` 语义不同（引号 / 括号 / 标识符），不合并；`CssSelector2` 的 `parseCssAnB` 两个 `nth-*` 分支只差枚举构造器，属语法层级必要展开；确认重复的是「五个兄弟遍历函数」与「空白分词两份实现」；跨文件另记「属性值引号扫描 vs `scanCssString`」口径漂移（并入转义一般项） |
| §3 空实现 | 1 | `CssParser.cj` 仅 `TODO` 占位（非主路径、无引用），与缺版权头合并为一条「一般」；其余文件无空函数体、无 `catch {}`、无静默吞异常（`parseCssMediaItem` 的 `None` 都是真实失败分支） |
| §4 栈溢出 | 0 | `matchPartAt` 递归深度 = `parts.size`，受 `CSS_MAX_SIMPLE_SELECTORS = 256` 约束（每段至少 1 个简单选择器，`CssSelector2.cj:269-276` + `CssSelector.cj:244-252` 双重校验）；`:not(...)` 的递归被 `allowNot: false` 截断为 1 层；`findCssClosingParen` / `scanCss*` / `parseCssAnB` 全为迭代；无 `clone` / `deepCopy` 递归。深度有界，不构成 §4（时间爆炸记入 §6.4） |
| §5 OOM | 0 | `CssLexer.tokenize` 的 token 数组与输入长度线性（每 token 一个 `String` 切片），输入规模由调用方决定，`SvgSecurityOptions.maxDecompressedBytes`（默认 64 MiB，`SvgOptions.cj:67`）只约束 gzip 解压路径，纯文本入口无上限——但无「按不可信长度预分配」与「只增不减的全局容器」；`CssSelectorIndex` 的桶随规则数增长且随文档重建。放大倍数与峰值未测，见待验证 #2 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile / bench 数据，`candidates` / 兄弟遍历 / tokenize 的耗时占比均未成立，已列入待验证假设 #1–#4 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无 `Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 队列 / 定时器 |
| §6.4 低效算法 | 3 | 命中：后代组合符无记忆化的组合爆炸（严重）、`candidates` 插入排序 O(k²) + 全类键扫描（进 CPU 方案）、`Includes` 每次匹配物化词数组（并入重复逻辑项） |
| §7 降堆内存方案 | 1 | 候选收集的每元素容器复用（无基线，待验证） |
| §8 降 CPU 方案 | 2 | `candidates` 查表改造、兄弟序号单次遍历（均无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内用完」的大对象：`tokenize` 的 `ArrayList<CssToken>` 作为返回值逃逸，`candidates` 的 `result` 也逃逸回调用方；`seen` 虽不逃逸但只有几十字节，local region 记账成本大于收益。结论：不建议在本部分引入 local mode |
| §11 现有代码的 BUG（存量） | 6 | 逐条核对过的边界：`tokenize` 的各类字节分类 / 注释未闭合 / 字符串与 `url()` 未闭合 / 转义在末字节；`decodeCssIdent` 的空内容与多字节步进；`CssSelector.parse` 的首尾组合符、缺组合符、空选择器、条目数不匹配；`parseCssAttributeOperator` / `parseCssAttributeValue` 的缺名缺值缺括号；`parseCssPseudoClass` 的缺名缺括号与不支持伪类；`parseCssAnB` 的 `odd/even/n/A n±B/纯整数/空串`；`cssAnBMatches` 的 `a=0` / 负系数 / `index<1`；`cssAttributeMatches` 七种运算符。命中 6 条：索引漏分组、属性值多字节崩溃、组合爆炸、`An+B` 整数溢出、转义码点代理区、属性值转义不解码（第 7 条「`CssParser.cj` 空壳 + 缺版权头」属基线 §3 / 遗留文件，不计入本节） |
| §12 并发安全与锁粒度 | 0 | 线程封闭 / 不可变：`CssLexer` 构造后只读（`text` / `bytes` 均 `let`），`tokenize` 只写局部容器；`CssToken` / `CssSelectorPart` / `CssSpecificity` / `CssAttributeSelector` 为值类型；`CssSelector` / `CssMediaQuery` / `CssSelectorIndex` 的字段在构造后不再写入（`candidates` 只读桶、只写局部 `seen` / `result`）。`SvgStyleResolver` 的可变状态（`mediaWidth` / `interaction` / 缓存）在其自身文件中，属其它部分，本部分不重复计 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README / `README_en`；`CssParser.cj` 的空壳不构成「承诺未实现」（无接口、无引用、无调用点，仅设计文档列过文件名，已记入该条「一般」）。公开 API 面（`CssLexer` / `CssToken` / `CssSelector` / `CssMediaQuery` 等）的 README 覆盖情况由含 README 的部分核对 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，文档一致性问题不在本部分产生（引用 `doc/f_svg-M2设计.md:84`、`:91`、`:512` 与 `doc/spec/add-f-svg-m2/verification.md:257` 仅作承诺源 / 已知问题证据） |

### 第 10 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：发现 2（时间契约读不回写入侧格式）、发现 3（序列化丢数据）。可读性：发现 10（注释与实现相反）。设计：本部分无分层问题（`Css*` 纯解析、`Svg*` DOM、`SvgAnalyticRasterizer` 只依赖同包的 `SvgPoint`/`clampSvgUnit`，无反向依赖）。语言特性：`CssDeclaration` 用 `struct + Equatable`、`?CssMediaQuery` 用 `Option` 而非哨兵、`@ local?` 形参与 `exclave` 用法符合 `docs/LocalMode.md:185-196` 的约束，未发现误用。安全性：本部分不向 XML 拼串（`SvgElement.cj:424` 的 `escapeSvgAttribute` 负责属性转义），`CssStyleSheet.toString` 的输出没有接入任何 XML 写入路径（全仓搜 `CssStyleSheet` 只在 `SvgStyleResolver.cj:216/226` 作为解析入口，无序列化消费点），故无 `<style>` 逃逸面；无凭据、无路径拼接 |
| §1 死代码 | 0 | 逐文件机械核对：`private` 符号在本文件内的「定义+调用」计数全部 ≥2 —— `CssSheetParseState` 6、`parseCssRuleBlock` 3、`parseCssMediaBlock` 2、`parseCssFontFace` 2、`parseCssColorProfile` 2、`findCssClosingBrace` 5、`skipCssTriviaWithin` 2、`skipCssAtRuleWithin` 2、`CssDeclarationParseResult` 3、`parseCssDeclarations` 4、`skipToCssDeclarationEnd` 3、`splitCssSelectorList` 2、`tokensToCssText` 6、`CssImportantSplit` 5、`splitCssImportant` 2、`findCssVarCall` 3、`isCssVarLetter` 4、`splitCssVarArguments` 2、`cssVarVisited`/`cssVarPush` 各 2、`analyticMax`/`analyticMin` 各 3、`analyticMaxReal`/`analyticMinReal` 各 5、`SvgAnalyticEdge` 13、`SvgAnalyticHit` 4、`accumulateAnalyticRow`/`Band`/`Edges` 各 2、`analyticEdgeColumnIntegral` 3、`analyticCrossingY` 2、`sortAnalyticHits`/`sortAnalyticValues`/`sortAnalyticLocalValues` 各 2、`ANALYTIC_EPSILON` 11 —— 无死代码。`internal` 符号在 `f_svg` 包内均有引用：`joinCssStrings`（7 个文件：`CssMedia.cj`/`CssStyleSheet.cj`/`SvgAuthoringBuilder.cj`/`SvgBegin.cj`/`SvgElement.cj`/`SvgFontVariant.cj`/`SvgPaintOrder.cj`）、`containsCssVariable`/`expandCssVariables`（`SvgStyleResolver.cj`）、`ANALYTIC_COVERAGE_SCALE`（`SvgRasterizer.cj:394`）、`ANALYTIC_LOCAL_ACCUMULATOR_*`/`analyticUsesLocalAccumulator`/`analyticCoverageImpl`（`analyticCoverage` 与两个测试文件）、`parseSvgTimeValue`/`parseSvgTimeReference`/`isSvgEventTime`（`SvgTimeline.cj:720/740/1314`）、`svgCalcModeAttrName`/`svgAnimationFillFromName`/`svgRestartFromName`/`svgCalcModeFromName`/`svgAnimationTransformTypeFromName`（各自文件 getter/setter，`svgRestartFromName` 另被 `SvgSet.cj` 使用）。`SvgTimeReference` 的字段在 `SvgTimeline.cj:722-737` 读取。`protected init(tag:)`（`SvgAnimate.cj:81`）属 `public open class` 的扩展点且被子类 `super(...)` 调用，按硬原则豁免。对外可达的 `public`（`CssDeclaration`/`CssRule`/`CssFontFaceRule`/`CssColorProfileRule`/`CssStyleSheet`/`SvgAnchorInfo`/`SvgMpath`/`SvgAnimate*`/`SvgAnimationInfo`/`SvgAntiAliasMode`）一律不判。未发现 `return`/`throw`/`break`/`continue` 后的同层残留语句。import 侧：`CssVariables.cj:19` 与 `CssStyleSheet.cj:19` 的 `f_base` 通配 import 分别由 `String.unsafeBytes` 扩展（`f_base/src/UnsafeBytes.cj:19-24`）与 `SvgException` 满足；`SvgAnalyticRasterizer.cj:20` 的同名 import 未定位到使用点，但通配 import 可能带入扩展方法、不编译无法确认，记为待确认，不作发现 |
| §2 重复逻辑 | 3 | 发现 6（3 份逐行相同的插入排序）、发现 7（6 份逐像素比较循环）、发现 8（4 个手写 max/min 与 `std.math` 混用）。已两两比对其余函数体：`SvgAnimate` 的 15 组访问器形状相同但属性名/类型各异，且逻辑已收敛到 `writeOptionalAttribute`/`attr`，属类型化 DOM 的必要样板，不判；`parseCssFontFace`(316-320) / `parseCssColorProfile`(367-371) / `skipCssAtRuleWithin`(428-432) 的 at-rule 前导扫描结构相似，但前者是「解析块」后两者是「跳过」，且告警文案不同，不判；`CssFontFaceRule`/`CssColorProfileRule` 的 `toString` 差异属不同契约，不判；`analyticMax` 与 `analyticMin` 互为对偶，不判 |
| §3 空实现 | 1 | 发现 9（单参 `parse` 丢弃告警，属「失败不可观测」）。其余核对：全部分文件无 `TODO`/`FIXME`/`UnsupportedException`；`CssStyleSheet.empty()` 是有语义的 Null Object（`rules.size == 0`，有用例）；`SvgAnchorInfo`/`SvgAnimationInfo` 是 DTO 不是空实现；`sortAnalyticLocalValues` 是 `exclave` 的 mode 适配层，有实体逻辑 |
| §4 栈溢出 | 1 | 发现 1（`@media` 互递归无上限）。其余递归排查：`expandCssVariables` 有 `depth >= 8` 与 `visited` 环检测双重上界（`CssVariables.cj:62-71`，边界由 `CssVariablesNegativeM5_test.cj:65-84` 固化）；`findCssClosingParen`/`findCssClosingBrace`/`skipCssAtRuleWithin`/`parseCssDeclarations` 全是单层循环；`analyticCoverage*` 全为迭代；`CssRule.toString`/`SvgAnimate.toString` 不遍历自引用结构 |
| §5 OOM | 2 | 发现 4（整幅 16 B/px，默认 `maxPixels` 下单次 fill ≈1.0 GiB，有上限故非无界）、发现 5（`events` 上界 `2+2A+A(A−1)/2`，无上限且强制 local）。已排除：无 `readToEnd`、无「全局集合只增不减」、无「按报文头预分配」（`width/height` 先经 `SvgBitmap` 的 `maxPixels` 校验） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，按铁律不立热点：行内求交与逐列分配降级为优化方案 2/3 与待验证假设 1/2 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/`Atomic`，无临界区（`grep` 零命中） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无任务提交；全部为同步纯计算与字符串处理 |
| §6.4 低效算法 | 1 | 发现 5 的 `252-267` 双层循环（O(A²)）+ `291-300` 每子区间重建 `hits` 再插入排序，与 §5 同一条目、不重复计数。其余核对：`findCssVarCall` 单趟扫描、`splitCssSelectorList` 单趟、循环内无字符串 `+`（`StringBuilder` 已用上）、`cssVarVisited` 线性查找但深度 ≤ 8 |
| §7 降堆内存方案 | 1 | 优化方案 1（解析覆盖率只算 bbox），标 `无基线（待验证）`，给出 16 B/px 与 1000²/4K/maxPixels 三档静态口径 |
| §8 降 CPU 方案 | 2 | 优化方案 2（去掉逐列 `ArrayList`）、优化方案 3（扫描线 + 活跃边表），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 1 | 发现 5：`events` 固定 `@ local!` 使 8 MiB 门限失效，是「已启用 local mode 仍存在的 local region 上限风险」。`accumulated` 的分档本身设计正确（除法形式避免 `width*height` 溢出，`93-97`；`coverage` 作为返回值保持堆分配，无逃逸），`SvgAnalyticLocalMode_test.cj` 对两档做了逐元素等价断言；逃逸检查、mode 重载、容量上限三项均已核对，未发现其它违规 |
| §11 现有代码的 BUG（存量） | 5 | 发现 2、3、4、5、10。另逐条核对未命中：`splitCssImportant` 找「最后一个 `!`」，`content: "a!important"` 的后缀是 `important"` ≠ `important`，不会误拆；`findCssClosingParen` 不跳引号，`var(--x, "a)b")` 会配错括号，但输入极窄且 fallback 会整体失败为 `None`（与发现 2 同属「不支持引号感知」的既有能力边界），不单列；`parseCssDeclarations`（`457-536`）不接收 `end` 上界，缺右花括号时会一直吞到 token 末尾——容错策略下已有 `tolerantParsing` 用例（`CssStyleSheet_test.cj:100-121`）覆盖顶层场景，`@media` 内嵌场景未覆盖，按容忍策略不作为缺陷；`analyticCoverageImpl` 的 `firstRow/lastRow`、`accumulateAnalyticEdges` 的列裁剪（`348-349`）、`analyticEdgeColumnIntegral` 的分段梯形逐段核对均正确；`SvgAnimateMotion.mpath` 先收集后删除，不会漏删或重删 |
| §12 并发安全与锁粒度 | 1 | 发现 5 涉及的共享路径是**全线程共用的 local region 预算**（`docs/LocalMode.md:193`），缺失的不是锁而是「用量上界 + 回退」。其余无共享可变状态：`CssStyleSheet`/`CssVariables`/`SvgAnalyticRasterizer` 都是入参到返回值的纯函数，无静态 `var`、无单例、无缓存；`SvgAnimate*` 的属性读写是实例方法，与 `SvgElement` 既有契约一致（线程封闭由调用方保证），不另判 |
| §14 功能完备性与 README 覆盖 | 1 | 发现 5（设计文档承诺的 OOM 回退未落地，属「已知缺口」而非隐瞒，已在描述里说明）。本部分无 `.md`，README 覆盖核对留给覆盖 `README.md` 的部分；符号侧另核对：`CssStyleSheet` 及其 `rules`/`fontFaces`/`colorProfiles` 已进 `README.md:8/571`，`SvgAnimate`/`SvgAnimateTransform`/`SvgAnimateMotion`/`SvgSet`/`SvgMpath` 在 `README.md:271`，`SvgAntiAliasMode.Analytic` 在 `README.md:353`；`SvgCalcMode`/`SvgAnimationFill`/`SvgRestart`/`SvgAnimationTransformType` 的 `match` 均穷尽，无「枚举新 case 无分支」 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 无适用对象（模块 README / `doc/**` 由其它部分覆盖） |

### 第 11 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | #1 auto 尺寸、#2 分类正确性、#3 视口口径（待确认）、#5 转义旁路、#6 ToString 语义、#7 构建器能力缺口、#11 数值边界。值侧转义链路已核对：`SvgBuilder` 的 `setAttr` 经 `SvgElement.toXmlElement` → `f_xml` `Escaper.escapeAttribute`（`Escaper.cj:43-60`），`text()` 经 `escapeSvgText`，无值注入面 |
| §1 死代码 | 2 | 已逐个搜索：`private` `strongBidiClass` / `reverseBidiRange` / `svgPx` / `svgOptionalPx` / `svgAnimationValues` / `fallbackAutoSize` 全仓均有调用；`internal` `svgBidiLevels` / `svgBidiOverrideLevels` / `svgBidiVisualOrder` / `svgMixBlendModeOf` / `blendSvgRgba` / `blendCssChannel` / `quantizeSvgChannel` 均在本包被调用（`SvgTextRenderer.cj:1647-1707`、`SvgRenderTree.cj:580/749/1131/1418`、`SvgClipMask.cj:202/309`）；`public` 全部对外可达不判；`return`/`throw` 后无同层语句。命中 #2 恒假分支、#10 未使用 import |
| §2 重复逻辑 | 3 | 已把本部分 10 个 `.cj` 的函数体按「输入-输出-副作用」两两比对（同文件内 `SvgBidi` 的 7 个函数、`SvgBitmap`/`SvgRgba` 全部方法、`SvgBuilder` 的 20 余个链式方法），并跨文件搜相同字面量与换算。命中 #8（4 个 `fromName` 同构）、#9（预乘换算 3 处 + blend 流程 2 份）、#14（300×150 字面量）。未合并项：`SvgBounds.union` / `intersect` 边界语义相反；`SvgBlendMode` 与 `SvgMixBlendMode` 是刻意分离（`SvgBlend.cj:24` 有注释）；各枚举手写 `operator func ==` 经 `stdlib/libs/std/fs/file.cj:34-43` 证实为语言必需写法；`colorNear` 与 `m5ColorNear` 为测试辅助且容差/是否比 alpha 不同 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`match ... case None => ()` 共 10 处（`SvgAuthoringBuilder.cj:46/95/298/338/369/377`、`SvgAutoSize.cj:82/93/106/126`）均为可选参数缺省分支，非错误吞没 |
| §4 栈溢出 | 0 | 本部分无自递归或互递归：`SvgBidi` 的层级/视觉序、`SvgBounds` 的四角变换、`SvgBitmap` 的填充/混合全是显式循环；`SvgAutoSize.rootSize` 与 `svgBBoxOf` 无回环（`svgBBoxOf` 不回调 `rootSize`） |
| §5 OOM | 1 | #4（`SvgBitmap` 尺寸守卫只防溢出）。已核对仓内三条分配路径各有上限（渲染 64 M / PNG 16 M / pattern 4 M），故不构成当前可利用的 OOM；`SvgBuilder.toSvgString` 的全量物化记入优化方案 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据；本部分只有「参考、非门禁」的 `println` 计时（且跑在 `-O0`），不能当证据。疑似热点全部进「待验证假设」1-6 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 原子量，无临界区可评 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池提交 |
| §6.4 低效算法 | 0 | 逐字节 `fill`、逐像素 `pixel()`/`setPixel()`、按层级多趟扫描（`SvgBidi.cj:339-354`，层级上界 ≤3）均为 O(n) 常数因子问题，非复杂度问题，统一按待验证假设处理 |
| §7 降堆内存方案 | 1 | `save(path)` 双副本（见优化方案，无基线） |
| §8 降 CPU 方案 | 2 | auto 尺寸跳过无用 bbox、`blend` 定点化 + mode 分派外提（均无基线） |
| §9 local mode 可行性 | 0 | 本部分热点函数里的临时对象都是值类型（`SvgRgba` / `SvgColor` / `SvgBounds` / `SvgPoint` 均为 struct），不产生堆分配；`SvgBidi` 的 `ArrayList<Int64>` 要作为返回值逃逸，不满足逃逸检查。无前后峰值数据，不列为方案 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条发现全部为存量（快照基线无 diff）。已逐函数核对边界/空值/错误处理：`SvgBounds` 负尺寸哨兵与零宽退化盒有注释且自洽；`SvgBegin.after` 的 `-0.0` 归一；`SvgBitmap.blend` 对 `alpha <= 0` 早退、`toColor` 对 `alpha <= 0` 返回 `Transparent`；`SvgBuilder.save(file:)` 的异常捕获已对照 SDK 源码确认正确 |
| §12 并发安全与锁粒度 | 0 | 无可证明的跨线程共享可变状态：`SvgBitmap` / `SvgBuilder` 是可变对象但均在单次构建/渲染内创建并持有（`SvgRenderer.cj:118`），`SvgAutoSize` / `SvgBidi` / `SvgBlend` 的公开函数只读入参、返回新值；无锁，无锁粒度可评 |
| §14 功能完备性与 README 覆盖 | 1 | #7（`animateTransform` / `animateMotion` 缺父类属性）。抽查本部分公开符号在 README 的登记：`SvgBuilder`（`README.md:270`）、`SvgBegin`（`272`）、`SvgAutoSize` / `SvgAutoSizeSize` / `SvgAttribute` / `SvgBitmap` / `SvgMixBlendMode` / `SvgBounds` / `SvgRgba` / `svgBidiClass`（`559`、`576`）均已列出；`README.md:270` 的方法清单与实现一致，`274`「渐变 / defs 构建 不支持」与实现一致。完整 README 对照归含 `.md` 的部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 `.md`，§13 文档一致性留给含 `README.md` / `doc/**` 的部分 |

### 第 12 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 26 | 26 条发现均至少涉及其中一项：`SvgLength.unit` 丢弃、mask 画笔语义、OBB 目标盒、ligatures 反向、单位参数脱节（第一轮）；非 ASCII 字节切片崩溃、`maskRegion` 百分比、clamp/max 双份实现、命名/导入/格式（第二轮） |
| §1 死代码 | 2 | 逐个 private/internal 顶层符号全仓搜引用（全部 ≥2 处：定义 + 使用）；`protected` 本部分无；**#6** `SvgManualClock.enabled` 只写不读；**#26** `SvgComputedStyle.cj:20` 的 `fountain::f_base` 导入疑似未使用（待 `cjlint` 确认）。`SvgClipProperty.normalize` 只被测试引用 → 仅作**可见性建议**，不计死代码；`rootOfSvgElement:758` 尾表达式位于 `while (true)` 之后，可能是编译器发散分析所需，未计（待确认）；对外可达 public 无引用（`has`、`SvgComputedStyleTree.size`、`start`）仅作信息 |
| §2 重复逻辑 | 7 | 同文件两两比对函数体 + 跨文件搜同形字面量：`renderClipChildren` vs `renderMaskChildren`（#12）、属性校验两套表（#13）；第二轮补 `rect→path` 三份（#19）、`clampUnit`/`clampSvgUnit`（#20）、`maxI64`/`minI64` vs 标准库（#21）、`warnOffsetIfClamped` vs `tryParseSvgOffset`（#22）、`countXmlElements`/`checkDepth` 与 `buildSvgOne` 内联校验（两趟全量 BFS 重复同一判定，已并入优化方案「构建前两趟全量遍历」）。`maskRegion`/`objectBoxValue`/`SvgClipCoverage` 之间无同语义实现 |
| §3 空实现 | 1 | `stop` / `start` 无观察效果（#6）；无 `TODO` / 空函数体 / `catch {}` |
| §4 栈溢出 | 2 | clip/mask 元素树递归无深度计数（#3）；`buildSvgChildren` / `collectXmlText` 递归深度 = 可配置 `maxDepth` 且选项不校验上限（#23，默认 512 时安全）；`rootOfSvgElement` 为迭代 |
| §5 OOM | 3 | 嵌套引用逐层整幅位图（#1）、warnings 无上限（#9）、`SvgCoverageMask` 缺 maxPixels（#10）；`SvgBitmap` 有溢出检查 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点结论不成立；候选见「待验证假设」#1–#8 |
| §6.2 大粒度锁 | 0 | 本部分无锁 / `synchronized` / 共享容器 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future.get` / 并发批处理 |
| §6.4 低效算法 | 0 | 线性颜色表、`findSvgPropertySpec` 线性扫描、每元素 path 拼接均为复杂度线索，缺 self time 数据，已列入待验证假设，不作发现 |
| §7 降堆内存方案 | 2 | 计算样式全量快照、蒙版 scratch 复用（见优化方案） |
| §8 降 CPU 方案 | 2 | 嵌套 clip/mask 整幅光栅化、`SvgBuilder` 多趟遍历 + 每元素 HashMap（见优化方案） |
| §9 local mode 可行性 | 0 | 无峰值内存数据；`renderClipCoverage` 的覆盖率数组作为返回值逃逸、位图交给 `SvgRasterizer`，`SvgComputedStyle` 进入样式树，逃逸检查不通过，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 18 | 26 条发现全部为存量，其中 18 条属本节形态（逻辑/边界/契约）；新增 #17（非 ASCII 切片抛错误异常类型）、#18（百分比当绝对长度）；`SvgCoverageMask.multiply` / `applyTo` 的尺寸与索引已核对无越界；`SvgColor.parse` 的四处定长切片切点均在 ASCII 字节上，已逐个排除误报 |
| §12 并发安全与锁粒度 | 0 | 未发现跨线程共享点：`SvgComputedStyleTree` 每次解析新建并在渲染期只读，`SvgValueCache` 属于元素实例，`SvgManualClock` 为手动单线程时钟；`warnings` 由调用方持有，未声明线程安全 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；README 交叉引用仅用于 #2（mask 承诺）与 #6（`stop` 承诺），合并时由含 README 的子轮统一核对 |
| 文件覆盖（§13 等） | 15/15 | 本部分无 `.md`；`.cj` 全部逐行读完，无跳过 |

### 第 13 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | #1 契约不符（可写 root 破坏监听）、#2 递归深度、#4 画笔上下文不符规格、#12 计时口径与墙钟断言、#13 可读性、#14 值类型设计、#15 并发契约缺失。**安全性专项**：本部分不拼 XML 字符串，值侧转义链路在 `SvgWriter` / `f_xml Escaper`（其它子轮）；唯一值直通点是 `svgNodeToXml`，已记范围外提示；无 SQL / 命令 / 路径拼接面；`SvgCursor` 对 `url()` 只告警不加载资源（无 SSRF 面） |
| §1 死代码 | 2 | 逐个搜引用：`private` `buildCrc32Table`（`SvgCrc32.cj:34`）、`SVG_CRC32_TABLE`（`:52`）、`updateState`（`:39/45`）、`isSvgCursorKeyword`（`:59`）、`SVG_CURSOR_KEYWORDS`（`:72`）、`findSvgElementById`（`SvgDocument.cj:74`）、`collectSvgElementsByTag`（`:109`）、`collectSvgAnchors`（`:146`）全有调用者；`internal` `tagName`（`:99`）、`fromTag`（`SvgTag.cj:71` + 测试）、`useContextFrame`（`SvgRenderTree.cj:1092/1093`）、`resolveContextPaintOf`（`:1168/1195`）、`svgNodeToXml`（`SvgDocument.cj:158/162`）均有引用。命中：#8（5 处未使用 import）、#10（`SvgDirectionM5_test.style` 无调用者）。`SvgContainerKind` / `SvgContainer` / `SvgCrc32` / `SvgCursor` / `SvgDocument` 均为对外可达 `public`，不判；`M6MutationRecorder.onMutation` 是接口实现，豁免 |
| §2 重复逻辑 | 5 | 同文件内两两比对：`SvgCrc32.checksum` 与 `update`（共用 `updateState`，仅首尾异或 1 行重复，不报）、`SvgContainerKind` 三个 match（映射目标不同，单列 #7）。跨文件按相同错误文案 / 白名单 / 遍历骨架搜。命中：#5（文案两处）、#6（`findSvgElementById` 两份实现）、#7（tag 表 4 份）、#9（M5/M6 夹具）、#11（`contentDepthLimit` 重写 `patternChainSvg`）。`SvgCursorM6_test` 的 37 关键字期望表与 `SvgContainer_test` 的 10 组映射属规格期望，不判 |
| §3 空实现 | 0 | 20 个文件无空函数体、无 `TODO` / `FIXME`、无 `catch {}`；`case _ => ()` 全部是节点类型分发（`SvgDocument.cj:110/123/147/183/197/216/221`、`SvgElement` 侧同理）或可选值缺省，非错误吞没；`SvgMutationHub.notify` 的 `catch` 会落 warning（范围外，见提示） |
| §4 栈溢出 | 1 | 命中 #2（三个 DFS + `toXmlElement`）。已核间接递归：`collectSvgAnchors` 只递归子节点、`findSvgElementById` 只递归子节点、`svgNodeToXml` 自身不递归（递归在它调用的 `toXmlElement`）；深度上界推导见 #2 |
| §5 OOM | 1 | 命中 #3（warning 内嵌完整输入 + 逐元素追加）。其余物化点 `elementsByTag` / `views` / `toXmlDocument` 都是调用方显式请求，受 `maxElements=1_000_000`、`maxDepth=512` 约束；`toXmlDocument` 的峰值翻倍记入待验证假设 #4，未当缺陷 |
| §6.1 热点瓶颈 | 0 | 无 profile / `cjpm bench -O2` 数据；两处自测耗时均无改前改后对照，不能作热点证据，已下沉为待验证 #1/#3/#5 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / `Atomic`，无临界区可评 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池提交 |
| §6.4 低效算法 | 0 | 三个遍历均为 O(n) 前序，无嵌套循环、无 `remove(at: 0)`、无循环内拼接（`StringBuilder` 已用）；`isSvgCursorKeyword` 37 项线性扫描、`zoomAndPan` 的 `warnings.contains` O(n) 去重都缺规模数据，入待验证 #1 |
| §7 降堆内存方案 | 1 | 一条方案（`views`/`anchors` 单遍收集），`无基线（待验证）`，不进修复清单 |
| §8 降 CPU 方案 | 1 | 一条方案（cursor 关键字静态集合查找），`无基线（待验证）`，不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分函数内中间对象全部逃逸：`elementsByTag`/`views`/`anchors` 返回 `ArrayList`，`toXmlDocument` 返回文档，`svgNodeToXml` 结果存进 `XmlDocument`；且无峰值内存对照，不列方案 |
| §11 现有代码的 BUG（存量） | 15 | 本部分 15 条发现全部为存量（快照无 diff，blame 已逐条核到 11-05/06/07 提交）。逐函数核对边界/空值/错误处理：`elementById` 对空 id、重复 id、缺 id 行为与注释一致；`anchors` 对空/空白 href 做了 `trimAscii` 兜底；`zoomAndPan` 非法值去重告警；`SvgCrc32.update(0, 空数组) == 0`；`SvgCursor.parse` 空值 / `url(` / 未知值三条回退路径都有 warning。存量 15 条是否纳入修复待用户决定 |
| §12 并发安全与锁粒度 | 1 | 命中 #15（无同步且未声明线程模型）。已核：模块内不存在跨线程共享同一 `SvgDocument` 的路径（渲染器不写回文档），不判"不安全"；锁粒度无锁可评；监听回调重入/迭代期修改的实质缺陷在 `SvgMutation.cj`，列入范围外提示 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 逐项对照归含 `README.md` 的子轮；本部分公开符号未见"承诺但未实现"：`SvgDocument` 的查询/监听/序列化入口全部有实现与用例，`SvgContainerKind` 10 个取值全部可达（`SvgTag.create` 或 `SvgPattern`/`SvgMarker` 的 `super(kind)`）。README 成员清单遗漏 `root`/`warnings` 已记范围外提示 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 `.md`，§13 文档一致性留给含文档的子轮 |

### 第 14 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1 #11；可读性：#10；安全性（序列化边界）：#9；语言特性：`as` 返回 `Option` 已查证（`typecast.md:54`），测试里 `(x as T).getOrThrow()` 合法，不是缺陷；设计合理性未命中（元素/原语/缓冲三层职责清晰，滤镜只依赖 `SvgFilterBuffer`） |
| §1 死代码 | 1 | #7（`internal fromNameOrWarn` ×2 仅测试引用）。逐个核过：`private` 的 `transformCacheOf` / `bareAttributeIndex` / `namespacedAttributeIndex` / `prefixFor` / `prefixInUse` / `siblingIndex` / `collectText` / `parseTransformOrNone` / `findSvgStyleColon` / `svgContainerBBox` / `svgChildTransform` / `svgUseBBox` / `applyBBoxClip` / `nestedSvgClipRect` / `collectSvgDescendants` / `readLightingFloat` / `M4LightVector` / `m4Normalize` / `m4HeightAt` / `m4LightFor` / `withPosition` 均有调用者；`internal` 的 `SvgValueCache` / `writeOptionalAttribute` / `appendAttribute` / `attributesVersion` / `mutationHub` / `rawQName` / `identity` / `readSvgHref` / `writeSvgHref` / `serializeSvgCData` / `serializeSvgComment` / `escapeSvgText` / `escapeSvgAttribute` / `svgRootOf` / `svgStyleFor` / `svgBBoxOf` / `lightingFilterBuffer` / `fromBitmap` / `copy` / `writeTo` / `invalidValue` / `syntaxError` / 四个外部文档常量与 `svgExternalDepthAllows` 均在本包内有引用；`public` 且对外可达的 `SvgElement` 成员、`SvgFeMerge.inputs`（仓内仅 `SvgFilter_test.cj:108` 用）、`SvgFeMergeNode` 不判死代码 |
| §2 重复逻辑 | 3 | #5（属性读写 4 函数 + paint 默认值 3 处）、#6（`fromBitmap` / `writeTo`）、#7（`fromNameOrWarn` ×2）。已两两比对同文件 20 个函数体：5 个枚举的 `operator ==` 手写表在语言层没有可用的通用替代（仓颉文档未给枚举自动派生 `Equatable` 的机制，`typecast.md` / `enum.md` 均无相关说明），合并不成立，按"不能乱上泛型"不报；`attr` 两个重载、`insertBefore` 两个重载差异是业务要求（`None` 追加 / 抛错）不报 |
| §3 空实现 | 1 | #10 的过期 `TODO`（`SvgFilterPrimitive.cj:177`）。无空函数体、无 `catch {}`：`parseTransformOrNone` / `tryParseSvgPaint` 的 `catch` 返回 `None` 是"非法值降级"的显式契约（`SvgElement_test.cj:186-192` 有断言） |
| §4 栈溢出 | 1 | #1 的第 3 条（成环）。解析路径有界：`SvgSecurityOptions.maxDepth` 默认 512（`SvgOptions.cj:66`），`SvgBuilder.cj:127` / `:660-672` 双重拦截，故"解析得到的树"递归深度 ≤512，不单列；程序化构造无上限（`appendElement` 无深度参数），与 #1 同根因故合并 |
| §5 OOM | 1 | #2（缓冲按原语数线性增长，单缓冲 256 MiB）。已核对现有拒绝路径：`SvgBitmap.cj:281`（输出像素）、`SvgFilterRenderer.cj:127`（滤镜区域）、`SvgRenderTree.cj:665/683`（foreignObject）、`SVG_EXTERNAL_MAX_BYTES` 16 MiB（`SvgRenderTree.cj:914`） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，未成立；已转「待验证假设」1–4（含函数、输入规模、采集工具） |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `synchronized` / `Mutex` / 锁内 I/O；`SvgMutationHub` 无线程同步要求（见 §12 行） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；光照与滤镜都是单线程循环 |
| §6.4 低效算法 | 1 | 方案 O3（`getBBox`/`getCTM` 每次重建样式树，O(m·n)）。`m4HeightAt` 的边界判断、`blur` 的滑动窗口等均未发现顺序/复杂度缺陷 |
| §7 降堆内存方案 | 2 | O1（CDATA 全量 `ArrayList<Rune>`）、O2（滤镜中间缓冲），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | O3（样式树重建）、O4（属性双扫描 + 通知上溯）、O5（逐像素 getter），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 模块已整体开启 local mode（`README.md:37`），但本部分的临时对象都是 std 容器（`ArrayList<Rune>`、`ArrayList<String>`、`ArrayList<SvgElement>`），std API 无对应 mode 重载 ⇒ 改造需重建容器类型，且收益必须用峰值内存对照证明；当前无数据，不写成建议 |
| §11 现有代码的 BUG（存量） | 3 | #1（DOM 不变量）、#4（缓冲尺寸边界）、#11（`symbol` 包围盒）；另 #8 #9 兼属边界/语义。均核对过调用链与相邻实现，未发现越界、除零、资源不对称（本部分无文件/句柄/原生内存） |
| §12 并发安全与锁粒度 | 1 | #3（类型化缓存无同步惰性写，共享路径=同一文档被多线程渲染，缺同步手段=无锁/无原子）。锁粒度维度未命中：本部分无锁可谈；`AtomicInt64` 只用于 `identity` 自增，用法正确 |
| §14 功能完备性与 README 覆盖 | 0 | 逐个对照：`SvgElement`、`SvgBBoxOptions`（`README.md:577`）、`SvgEllipse`、`SvgException`/`SvgErrorKind`、`SvgExternalDocumentProvider`（`README.md:188`）、`SvgFilter`、`SvgFilterBuffer`（`:595`）、`SvgLightingPrimitive`（`:607`）、9 个 fe*、`svgSetInlineStyleProperty`（`:559`）均已进 README；`fromBitmap`/`copy`/`writeTo` 是 `internal`，不必文档化。未发现"承诺但未实现" |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`，故 §13 文档一致性无适用对象；20 个 `.cj` 全部读完并逐个给结论 |

### 第 15 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：模糊边界、dropShadow 区域外扩、turbulence 坐标、别名 stretch；语言特性：数字列表引用逸出；可读性：过时注释、测试命名。安全性：滤镜区域有 `maxPixels` 预检查、`feImage` 只走 `SvgImageResource`（`data:`/provider），本部分无注入面；未发现凭据/日志泄漏 |
| §1 死代码 | 3 | 已逐个核对本部分全部 `private`（`gaussianKernel`/`bytesToFloat`/`floatsToBuffer`/`convolveHorizontal`/`convolveVertical`/`colorMatrixFor`/`positiveMod`/`filterAxis`/`primitiveSecondInput`/`transparentBuffer`/`applyFilterPrimitive`/`toLinearRgb`/`toSrgb`/`linearChannel`/`srgbChannel`/`dropShadowRegionMargin`/`transferChannel`/`readDisplacementFloat`/`convolveSample`/`positiveSvgMod`/`clampSvgIndex`/`perlinSvgNoise`/`svgGradientDot`/`svgNoiseHash`/`bilinearSvgSample`/`nearestStretch`/`key`/`stretchKey`/`m4ColorLevel`/`joinTestStrings`/`m6*`）与 `internal`（`blurFilterBuffer`/`offsetFilterBuffer`/`floodFilterBuffer`/`blendFilterBuffer`/`compositeFilterBuffer`/`mergeFilterBuffers`/`colorMatrixFilterBuffer`/`tileFilterBuffer`/`tileContentBounds`/`dropShadowFilterBuffer`/`readSvgNumberList`/`writeSvgNumberList`/`writeSvgNumberArray`/`componentTransferFilterBuffer`/`morphologyFilterBuffer`/`convolveFilterBuffer`/`turbulenceFilterBuffer`/`displacementFilterBuffer`/`feImageFilterBuffer`/`SVG_FE_MORPHOLOGY_*`/`attachImages`/`hasFamily`/`resolveDetailed`/`normalizeSvgFontFamily`/`parseCssLocalFontFamilies`/`splitSvgFontFamilies`/`trimAsciiQuotes`/`SvgFontMatch`）符号，全部有仓内调用者；`stitchTiles`/四个 `fromNameOrWarn` 属未接线（#10/#11）；不可达校验见 #12；`tileContentBounds` 的死输出见 #16 |
| §2 重复逻辑 | 3 | 已把本部分 40+ 个函数体压成「输入→输出→副作用」两两比对：`positiveMod`/`positiveSvgMod` 完全同义（#15）；`stdDeviation` 解释 5 份（#5）；`flood-color` 解析 2 份（#6）；像素搬运 4 份（#16）。`linearChannel`/`srgbChannel` 是互逆公式不算重复；`SvgFontRegistry.key`/`stretchKey` 键格式不同不算重复；测试夹具 `solidBuffer`/`m4Buffer`/`m4FillRect` 相似但属测试准备代码，按清单误报边界不计数 |
| §3 空实现 | 1 | `case _ => input.copy()` 静默直通（#14）；其余 `case _ => ()` 均为「非目标子节点忽略」，解析阶段已有 warning（`SvgFilter_test.nonPrimitiveChildWarns`）。无空函数体、无 TODO/FIXME |
| §4 栈溢出 | 0 | 本部分无递归：`resolveDetailed` 只向 `base` 单向委托，`derived` 每次新建实例，链深由调用方构造且无环；滤镜链是 `while` 迭代。无自引用结构遍历 |
| §5 OOM | 2 | σ 无上界（#1，严重）；`named` 线性叠加（#2，一般）。区域本身有 `maxPixels` 预检查且先做除法再分配（`SvgFilterRenderer.cj:127`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile；`doc/perf-baseline.md` 只有单次整轮数据（512² σ=8 约 0.5 s、卷积 151 ms、湍流 96 ms），无自耗时占比 ⇒ 已列入「待验证假设」#1~#3，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变全局状态 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 Future、无任务提交，滤镜链为单线程顺序执行 |
| §6.4 低效算法 | 1 | `tileContentBounds` 只判存在却全量扫描（#16，并给出提前返回方案）；卷积/形态学/湍流均有核尺寸与采样预算上限，复杂度受控 |
| §7 降堆内存方案 | 2 | 模糊 Float64 中间表示（68 B/px）、`named` 生命周期；另见「优化可行性方案」 |
| §8 降 CPU 方案 | 3 | 256 项 gamma LUT、`bilinearSvgSample` 去分配、裁剪/复制批量化 |
| §9 local mode 可行性 | 1 | `blurFilterBuffer` 内两个 Float64 数组不逃逸，是唯一候选；无峰值内存对照 ⇒ 只进「待验证假设」#5，未写成建议 |
| §11 现有代码的 BUG（存量） | 12 | 本轮读到的 4 个实现文件的边界/空值/错误处理/资源已逐函数核对；无文件句柄与 CFFI；存量条目见「发现」全部 17 条（来源均为存量） |
| §12 并发安全与锁粒度 | 0 | 无静态可变全局状态；`SvgFilterRenderer.warnings` 与 `SvgFontRegistry` 的各 `HashMap` 都是实例字段，仓内创建点均在单次渲染内（`SvgRenderer.cj:141` 每渲染 `attachImages`，`SvgFontRegistry.defaultRegistry` 每次新建）⇒ 线程封闭。未声明线程安全：`SvgFontRegistry.register` 必须在发布前完成，属待确认契约（不计数） |
| §14 功能完备性与 README 覆盖 | 2 | `stitchTiles` 承诺未接线（#10）；`fromNameOrWarn` 未接线（#11）。README 本部分无 `.md`，公共 API 覆盖由其他部分核对；另有两点**范围外提示**：①`in="SourceAlpha"` 未支持（全仓 grep 零命中，`named` 只注册 `SourceGraphic`），真实文档里 feDropShadow/形态学常用 SourceAlpha，会退化成透明 + warning；②各原语子区域（`x`/`y`/`width`/`height`）在模型层不存在（`SvgFilterPrimitive` 只有 `in`/`result`），`feImage`/`feTile` 只能铺满滤镜区域 |
| 文件覆盖（§13 等） | 11/11 | 本部分无 `.md`，§13 文档一致性不适用；11 个 `.cj` 全部读完 |

### 第 16 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 命中：fromStyle 默认值覆盖（#3）、ligatures 复合值失效（#4）、stop 样式未接线（#5）、miter 口径不一致（#6）。安全性另核：渐变/字体/几何均不拼 SQL/命令，无凭据硬编码；`SvgGzip` 解压有 `maxBytes` 与 CRC 双校验 |
| §1 死代码 | 2 | 已逐个 `private`/`internal` 符号全仓搜引用（`svgSplitFeatureEntries`、`svgParseFeatureEntry`、`rectBounds…textElementBounds`、`cubicAt`、`tipAt`、`elementMatrix`×2、`ancestorTransform`、`GradientStopData`、`applyGradientSpread`、`sampleStops`、`svgChannel*`、`gsubTag`、`gsubCoverage`、`gsubReadCoverages`、`gsubParse*`、`splitHersheyStrokes`、`parseHersheyPoint(s)`、`buildHersheyGlyphs`、`verifyTrailer`、`readU32LE` 全部 ≥2 处命中，均有调用者）；命中死字段 `chained`（#9）与 3 处恒不可达分支（#10）；`public` 一律按「对外可达不判」处理，仓内零引用的 `SvgGeometry.absoluteBounds`、`writeGzip`、`SvgFontFeatures.size/parse(text)` 仅记为信息 |
| §2 重复逻辑 | 1 | 已把本部分 7 个生产文件（`SvgFontVariant`/`SvgForeignObject`/`SvgGeometry`/`SvgGradient`/`SvgGsubContext`/`SvgGzip`/`SvgHersheyFont`，共 105 个 `func`）的函数体压成「输入→输出→副作用」摘要两两比对，并与 `SvgOpenTypeLayout.cj` 同族函数逐行对齐；命中 M5/M6 OpenType 解析重复（#7，6 组逐行等价）。本部分内另有两处「形似不同但语义不同」不判：`cubicBounds` 的 x/y 根两轮循环（合并等价，仅省两次遍历，归入 CPU 线索不单列）、`ctm` 与 `ancestorTransform` 的祖先链收集（语义不同：前者含嵌套 `svg` 视口变换）。测试夹具重复（`layout`/`layoutFor`、`solid`/`m5SolidBitmap`）按误报边界不计 |
| §3 空实现 | 1 | 命中过时 `TODO(M3-6)`（#11）。其余 `case None => ()` 均为可选属性缺失的正常分支；`SvgForeignObjectRenderer` 的 `None` 返回有文档化的「透明占位」语义，非空实现 |
| §4 栈溢出 | 0 | 唯一的输入驱动递归是 `findGradientById`（深度 = 文档嵌套，解析期受 `SvgSecurityOptions.maxDepth=512` 限制，`f_svg/src/SvgOptions.cj:68`），`gsubParseLookup` 的 Type 7 展开与 `applyLookupAt` 的上下文嵌套分别有 `CSS_GSUB_MAX_DEPTH=8` 显式计数。DOM 手工构建的树不受 `maxDepth` 约束，但无环检测缺省不影响本部分结论，属「DOM API 侧风险」，未作为发现 |
| §5 OOM | 2 | 命中 sampler warning 按像素增长（#1）与 GSUB coverage 放大（#2）。`SvgGzip.decompress` 有 `maxBytes` 流式上限（`:38-53`）；`SvgFontFeatures.parse` 有 64 条上限（`:166-169`）；`pointsBounds`/`pathDataBounds` 规模由输入长度线性决定，无放大 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile/bench 数据，`SvgGradientSampler.sample`、`findGradientById`、`glyphPath` 均只有「调用次数多」线索，已全部降级到「待验证假设」#1–#6 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享缓冲；`SvgGradientSampler` 每次 fill 新建，属线程封闭 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；渲染循环是单线程逐命令 |
| §6.4 低效算法 | 3 | 命中：每像素重解析 href 链/stops（已列 CPU 方案）、`applyLookupPass` + `ArrayList.remove(at:)` 的 O(n²) 风险（待验证假设 #5）、coverage 全量展开（兼作 OOM 与内存方案）。均无实测数据，未计入缺陷 |
| §7 降堆内存方案 | 3 | `pathDataBounds` 绝对化副本、Hershey 字形每次解析、coverage 区间化；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 渐变采样一次解析、GSUB 单次解析；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选只有 `sample()` 内每像素的小对象（`SvgPoint`、`SvgColor`、2 元组），生命周期本就止于函数返回，local region 收益无法用峰值内存证明；且 `SvgColor`/`SvgBounds` 为值类型，无 `exclave` 需求。结论：本部分无可证明收益的改造点 |
| §11 现有代码的 BUG（存量） | 12 | 本部分 18 个文件、105 个生产 `func` 的边界、空值、错误路径逐个核对；12 条发现全部为存量（快照模式，`git blame` 落在 `f0d369c020` 等历史提交） |
| §12 并发安全与锁粒度 | 0 | 已确认无全局可变状态：`HERSHEY_GLYPHS`（`SvgHersheyFont.cj:21`）只在模块初始化写一次、之后只读；`SvgGradientSampler`、`SvgFontFeatures`、`SvgGsubApplyState` 都是调用方局部对象；`SvgGradient` 的 `SvgValueCache` 挂在元素上，与模块「DOM 非线程安全」的既有前提一致。无检查-然后-写入、无惰性初始化竞态 |
| §14 功能完备性与 README 覆盖 | 0 | README 不在本部分文件清单，仅做符号交叉核对，结果见「范围外提示」。`SvgGsub*` 属 `internal`，不必进 README |
| 文件覆盖（§13 等） | 18/18 | 本部分清单全为 `.cj`，无 `.md`；`.md` 一致性（README/`doc/**`）由本模块其他部分覆盖 |

### 第 17 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 坐标空间错配、遍历门禁缺失、硬编码视口、奇异矩阵回退、枚举约定漂移、可变数组失同步；本部分无网络/文件访问，`SvgImageResourceProvider` 把安全责任显式交给调用方，未发现注入面（无字符串拼接进 XML/HTML） |
| §1 死代码 | 1 | 已逐个符号搜引用：`svgDocumentHitQuery*`（SvgDocument）、`svgHitQueryCollect/Matches/DirectChildElements`、`SVG_HIT_TOLERANCE/EPSILON`、`SvgHitContext` 以及 `svgHitWalk/LocalPoint/ElementMatches/Text/BBoxContains/ImageBounds/ImageContains/BoundsContainsPoint/PointInContours/PointNearContours/LineCapCoversPoint/DistanceToSegment/DistanceToPoint/PointOnSegment`、`isHovered/isFocused`、`SVG_DATA_PNG_PREFIX`、`resourceBytes`、`parseUnit`、`interpolateChannel/bezierCoordinate/bezierDerivative`、`fromName` 均有调用者；`SvgLinearGradient` 4 个属性对外可达仅记信息；唯一命中是未使用 import（发现 #12）。无 `return` 后同层语句、无恒真恒假分支（`SvgRoot <: SvgElement` 而非 `SvgContainer`，故 `svgHitElementMatches` 的 container/root 两个 case 不重叠） |
| §2 重复逻辑 | 4 | 已按函数体「输入-输出-副作用」两两比对并跨文件搜同义实现：视口/原点换算 3 份（发现 #3 关联、`SvgViewportTransform.from`）、`calcMode` 双映射（#6）、`svgHitQueryMatches` 与 `svgHitElementMatches` 门禁漂移（#2）、`svgHitImageBounds` 与 `SvgElementApi` image 分支（位置 `SvgHitTest.cj:580-589` vs `SvgElementApi.cj:134-141`，仅重复无漂移，未单列）；13 处长度属性样板属全模块 61 处同一形态，合并记录在 #10 与总评，不按处数计数 |
| §3 空实现 | 1 | `elementsAt` 丢弃 warning（#9）；其余无 `{}` / `TODO` / `return None` 占位；`SvgHitQueryMatches` 的 `None => return false` 是“样式缺失即不命中”的显式降级，非空实现 |
| §4 栈溢出 | 1 | `svgHitQueryCollect` / `svgHitWalk` 按元素深度递归，无自深度上限；解析文档由 `SvgSecurityOptions.maxDepth=512`（`SvgOptions.cj:66`）限定，但 `appendElement` 无深度校验，程序化构造的深树可无限递归（未单列为缺陷，因需调用方主动构造，已在发现 #4 的“无上限”说明中提及） |
| §5 OOM | 2 | 查询无元素上限（#4）、data URI 多份整串副本（优化方案，量化见该条）；`SvgImageResource` 的解码总量受 `SvgDecodeBudget` 约束（`SvgPngDecoder.cj:30-51`），单次渲染 64 Mi 像素上限，不另报 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，未把任何“看起来慢”的点写成发现；5 条线索已全部转入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变容器写入（`SvgHitTest.warnings` 的并发问题归 §12.1） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批量任务提交 |
| §6.4 低效算法 | 2 | 查询每元素重算子树 bbox（#4）、`elementAt` 全量物化（优化方案）；`svgPointInContours` 为单趟扫描，`svgDistanceToSegment` 有零长度保护，未发现二次方级实现 |
| §7 降堆内存方案 | 3 | data URI 副本、`ArrayList → toArray` 双份峰值、`svgDirectChildElements` 临时表；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | `elementAt` early-exit、`SvgValueCache` 闭包分配；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分主体是命中判定与数值插值，临时对象都是小对象且多数会写进返回值（`Array`/`ArrayList` 逃逸），没有可量化的“函数内大临时结构”；按 checklist §9 约束（逃逸 + 峰值数据缺失），结论为不适用 |
| §11 现有代码的 BUG（存量） | 7 | 见 #1/#2/#3/#5/#7/#8/#13；另核对 `svgPointNearContours` 的 `contour.size==0` 分支——`flattenPathData` 仅在 `current.size > 0` 时入栈（`SvgRasterizer.cj:518-520`），不会产生空轮廓，故不判越界 |
| §12 并发安全与锁粒度 | 2 | `SvgHitTest.warnings`（#11）与 `SvgInteractionState` 可变数组（#14）是仅有的可变状态；其余函数为纯计算、无静态状态，`SvgImageResource` 文档声明“实例生命周期即一次 render”，属线程封闭 |
| §14 功能完备性与 README 覆盖 | 1 | README「交互与命中测试」表（`f_svg/README.md:239-247`）承诺 `hitTest` / `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` / `elementsAt` / `elementAt`，均有实现；`SvgInteractionState`、`SvgInterpolator`、`SvgLength*`、`SvgImageResourceProvider`、`SvgLinearGradient`、`SvgZoomAndPan`、`SvgImageRendering` 在 README 与 README_en 都能搜到。问题在“实现了但结果不对/语义漂移”（#1-#3），不在缺失 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.cj`，无 `.md` 需要核对；`doc/**` 与 README 仅作 §14 交叉核对，未计入本部分覆盖 |

### 第 18 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：#1/#2/#5/#11；设计：#8/#9；语言特性：`String.fromUtf8` 异常类型（#4）、`Array ==` 与 `Float64.toString` 已对文档核对；可读性：#13 的重复实现；安全性：#9 序列化注入 |
| §1 死代码 | 2 | 逐个核对本部分全部 private / internal 符号：`sameSvgPoint`、`startAngle`、`endAngle`、`midAngle`、`markerIdOf`、`markerUnitScale`、`markerWidth/Height`、`markerViewportMatrix`、`markerContentMatrix`、`normalizeSvgNumber`、`isSvgDigit/isSvgSpace/isSvgAlpha/skipSvgSpaces/scanSvgNumber/requireFinite`、`cssLayoutTag/cssLayoutCollectLangSys/cssLayoutFeatureIndices/cssLayoutLookupRefs/cssCollectGsubLookup/cssPairKey/parseGposPairSubtable/valueRecordSize/readGposXAdvance/parseGposCoverage/parseGposClassDef/parseGsubLigatureSubtable` 均有调用者；命中 2 条：`SvgKernPairs.horizontalOnly`（#10 字段与构造参数只写不读）、两个 `fromNameOrWarn` 仅测试调用（#13）。`SvgMarkerUnits/Orient/Overflow.fromName`、`SVG_MAX_MARKER*`、`markerViewBoxMatrix`、`svgNotifyMutation` 均有生产引用；public（`SvgNamespaces`、`SvgPoint.create`、`SvgMatrix.create` 等）对外可达，不判 |
| §2 重复逻辑 | 2 | 同文件两两比对：`startAngle`/`endAngle`/`midAngle` 各自语义不同（方向与边界不同）不合并，但四处重复 `180.0 / 3.141592653589793` 字面量、`sameSvgPoint`/`startAngle`/`endAngle` 三处重复 `1e-9` 容差；跨文件命中 `fromNameOrWarn` 16 份同构实现（#13）。`SvgKernPairs.adjust` 与 `SvgGposPairs.adjust` 结构相似但存储与回退不同，属业务差异，不记 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`；`SvgMutationHub.notify` 的 `case None => ()` 是「文档未挂 hub」的合法分支且有注释；`SvgPaintKind.None` 是真实枚举值不是空实现 |
| §4 栈溢出 | 1 | `cssCollectGsubLookup` 有深度上限（8）不构成风险；`SvgElement.toString` → 子节点递归受解析期 `maxDepth`（默认 512）约束；命中唯一一条：变更监听器重入无出口（#7） |
| §5 OOM | 2 | GPOS coverage/classDef 范围展开（#1）、GPOS format 1 pair 表无全局上限（#2）；marker 1024 上限、kern 65536 上限、marker 深度 64 均已闭环，不再报 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，无法成立热点结论；相关猜测进「待验证假设」#1-#4 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`synchronized` 零出现 |
| §6.3 并发串行 | 0 | 无 `spawn`、无任务提交，不适用 |
| §6.4 低效算法 | 1 | `containsCssFeatureIndex` 线性查重（#14）；其余 `ArrayList` 遍历均在一次线性扫描内 |
| §7 降堆内存方案 | 0 | 本部分可降内存点（marker mid 临时数组、GPOS 表结构）需要分配基线才能量化，已并入优化方案与假设，未单列堆方案 |
| §8 降 CPU 方案 | 2 | marker 派生空转（优化方案 1）、属性写入上溯（优化方案 2） |
| §9 local mode 可行性 | 0 | `SvgMarkerExpander.expand` 的临时数组随返回值（`Array<SvgMarkerInstance>`）逃逸到渲染树，`shapeContours` 结果同样逃逸；要拿到收益须给 `flattenPathData` 等整条调用链补 mode 重载，且只能用峰值内存对照证明，缺数据，不成立 |
| §11 现有代码的 BUG（存量） | 4 | 本轮读到的边界/空值/资源/契约均已核对：命中 #4（异常类型）、#5（阈值）、#8（缓存失效）、#12（参数校验）；`scanSvgNumber` 的符号/小数/指数边界、`parseSvgNumberSequence` 的逗号三态、`expand` 的空 contour 与 1/2 点边界、`SvgPaint.parseReference` 的引号与嵌套 `url()` 均已逐分支核对，无缺陷 |
| §12 并发安全与锁粒度 | 2 | 共享点两条：`SvgDocument.mutationHub`（#7）、同一文档的 `SvgValueCache`（#6）；`SvgMarkerExpander` 的 `warnings` 也是可变实例状态，但 `SvgRenderTree.cj:1286` 每次新建、线程封闭，只作提示不计命中。无锁，故 §12.2 无粒度问题 |
| §14 功能完备性与 README 覆盖 | 2 | GPOS Extension 缺分支（#3，承诺源：GSUB 侧同类实现与「不支持会告警」的既有策略）、`requiredFeatureIndex` 未接（#11）；本部分不含 `.md`，README 逐项对照在其它部分完成，本部分 public 声明（`SvgMarker`、`SvgMarkerExpander`、`SvgMatrix`、`SvgPaint`、`SvgMutation*`）均为既有 API，README:164 已列 marker 能力，未见新增未文档化符号 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无缺失 |

### 第 19 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | #3 单位换算漂移、#4 双轨解析、#6 写回丢精度、#7 数组别名、#8 伪循环、#10 `transform` 契约；安全性方面 SVG 外部引用拒绝在 `SvgPaint`/`SvgBuilder`（本部分外）实现，本部分未见注入面（pattern/sampler 只处理已解析元素，不做字符串拼接进输出） |
| §1 死代码 | 0 | 逐个搜过：`paintLayerFromName`/`normalizeCssPaintOrder`/`svgPaintOrderOf`/`containsPaintLayer`/`validateTolerance`/`maxInt64Pattern`/`clampPatternIndex`/`pathKind`/`absolutePairs`/`commandLetter`/`SvgPathScanner`/`findPatternById`/`attachSession`/`sampleTile`/`SVG_MAX_PATTERN_*` 均有调用者；`SvgPathMeasure`/`SvgMeasuredSegment`/`SvgMeasuredPoint` 被 `SvgPathData` 使用；`SvgArcParams` 仅测试构造但为顶层 public（对外可达）⇒ 按硬原则一不判死代码，只记「仓内 `src/` 无构造点」；`SvgPattern` 9 个 prop 同为 public，按硬原则一不判死，其「零 `src/` 读取」已作为 §2 双轨证据（#4）；未见 `return`/`throw` 后同层语句与恒真恒假分支 |
| §2 重复逻辑 | 3 | #3（长度换算重复实现且已漂移）、#4（typed prop vs attr 解析两套）、#9（tile 上限判定与文案复制）；另外逐对比对了 `SvgPaintOrder`/`SvgPathLength`/`SvgPathMeasure`/`SvgPatternSampler` 内 30 余个函数体的「输入-输出-副作用」，`resolveAxis`/`resolveOrigin` 同构已并入 #3 |
| §3 空实现 | 0 | 无空函数体；`SvgParser.loadXml` 只有 try/catch 包装且有返回；无 `TODO`/`FIXME`（grep 17 个文件 0 命中）；`sample` 对失败返回 `None` 均有 warning 或文档说明 |
| §4 栈溢出 | 1 | #5 `findPatternById` 递归深度上界 4096；其余递归均为常量上限（`subdivideCubic` depth ≤ 16、`resolveChain` 循环而非递归、pattern 嵌套受 `SvgRenderGuard`/`SVG_MAX_REFERENCE_DEPTH` 限制） |
| §5 OOM | 1 | #1 tile 缓存无总量上限（单 tile ≤ 16 MiB，条目数随输入增长）；`buildSegments` 段表属可回收临时对象，量化后只列入优化方案 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据，所有热点线索（tile 重复构建、全树搜索、段表）已降级进「待验证假设」，未作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池 |
| §6.4 低效算法 | 1 | #11 `paint-order` 双次分词/解析（每次 computed style）；`resolveChain` 的 `visited` 线性扫描受 `SVG_MAX_PATTERN_DEPTH=64` 限定，不构成问题 |
| §7 降堆内存方案 | 1 | O1（`totalLength` 不物化段表）；结论全部标 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | O2（负缓存 + 复用 builder/renderer）、O3（合并链式查找与换算）、O4（复用绝对命令表） |
| §9 local mode 可行性 | 0 | 本部分临时大对象（段表、tile 位图）都会逃逸或被缓存（tile 进 `cache`、段表跨 `sample` 调用），逃逸检查不通过；且 `f_svg` 未启用 local mode，`SvgBitmap.pixels` 为大块 `Array<Byte>`，收益需峰值内存对照才能证明，本轮无数据 |
| §11 现有代码的 BUG（存量） | 6 | #3/#4/#5/#6/#7/#10 均为存量缺陷（快照模式，`git status` 无 `f_svg` 改动）；本轮读到的 `SvgPathScanner` 词法边界（逗号、`Z` 后数字、弧标志、相对/重复命令、非有限数）逐个对照 `SvgPathData_test.cj` 用例复核，除上述各项外未再发现新缺陷 |
| §12 并发安全与锁粒度 | 0 | `SvgPatternSampler` 有可变状态（`cache`/`warnings`/`guard`/`images`）但类文档明确「实例生命周期为一次 render」（`SvgPatternSampler.cj:85-88`），仓内唯一使用方 `SvgRenderer.renderDisplayList` 每渲染新建一个（`SvgRenderer.cj:138`）⇒ 线程封闭；`SvgPaintOrder`/`SvgPathData` 构造后不可变；`SvgValueCache` 随元素走，元素本身非线程安全是模块既有约定，本部分无新增共享面 |
| §14 功能完备性与 README 覆盖 | 0 | 公开符号逐个对照 README：`SvgPaintOrder`(2)、`SvgPatternSampler`(1)、`SvgPathData`(4)、`SvgPathLength`(2)、`SvgParser`(10)、`parseAuto`(2)、`parseGzip`(1)、`SvgArcParams`(`README.md:574` 有字段说明) 均已登记；`SvgPathMeasure`/`SvgMeasuredSegment` 为 internal，无需文档；未发现「承诺但未实现」——`parseAuto`/`parseGzip` 入口均已接线并有测试 |
| 文件覆盖（§13 等） | 17/17 | 本部分清单 17 个文件全部 `.cj`，已逐个读完；无 `.md`，故 §13 文档一致性无对象，README 覆盖按 §14 抽查 |

### 第 20 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（#1 覆盖率分母、#2 隐藏状态、#5 参数个数未校验）、可读性 1（#10）；安全性 0：本部分无字符串拼 XML、无外部文本进日志（PNG 编解码只处理二进制，`SvgPointList.toString` 只输出数字） |
| §1 死代码 | 2 | 逐符号搜引用：`SvgRasterizer` 的 `maxInt64`/`minInt64`/`maxFloat`/`distance`/`midpoint`/`matrixScale`/`SvgRasterEdge`/`SvgSpan` 均有调用，`flattenCubicPolyline`/`SvgRenderGuard.enter|leave`/`svgRenderGuardLabel` 在 `SvgPatternSampler`、`SvgRenderTree`、测试中有调用，`SvgPreserveAspectRatio.isXMin/isYMax` 等在 `SvgFilterPrimitives2`、`SvgRenderer` 有调用；命中为三处恒假分支 + encoder 未使用 import（#6）与测试死变量（#7），无「非 public 符号零引用」的情形，public 声明按对外可达不判 |
| §2 重复逻辑 | 2 | 生产侧逐函数体比对：`adler32`×2、签名×5、`maxInt64`×2、`maxFloat`×2（#8）；合成循环、描边轮廓化、`polygon`/`polyline` 整文件（#9）。测试侧的 `pngPaeth`/`pngForwardFilter`/`pngAdler32` 与被测实现同构，属刻意的往返校验，不计 |
| §3 空实现 | 0 | 逐个函数体检查：无 `{}`、无 `TODO`/`FIXME`、无 `catch {}`；`decodeAdam7` 的 `continue` 是 pass 跳过而非空实现；`SvgDimension` 类属性 getter 均有实现 |
| §4 栈溢出 | 0 | 唯一递归是 `subdivideCubic`（`686`），出口由 `depth >= 16` 硬限（`695`），最多 16 层帧；`flattenPathData`/`decodeAdam7`/`arcPolyline` 都是迭代；点在 `SvgRasterizer.cj:705-706` 两路递归深度相同，不存在间接递归与环 |
| §5 OOM | 2 | `SvgRasterizer` 覆盖率按画布 8 B/px（#3）、`SvgPngEncoder` 3–4 份 4wh 缓冲（#4）；解码侧有 16/64 Mi 像素与 64 MiB 流上限两条拒绝路径，未单列 |
| §6.1 热点瓶颈 | 0 | 本部分唯一"性能资料"是 `SvgPerfM5_test` 的 `println`（无门禁、无对照），无 `cjprof` / `cjpm bench` 数据；所有热点判断已降级到「待验证假设」1–4 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无并发容器（PNG 编解码为纯静态函数，光栅器为单实例顺序调用） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池，不存在形式并发 |
| §6.4 低效算法 | 1 | `computeCoverage` 全量扫边 + 每子扫描线容器分配（优化方案 3，已按"无基线"处理，未计为缺陷）；`sortHits` 插入排序列入假设 2 |
| §7 降堆内存方案 | 1 | 解码侧流式化（去掉整文件读入 + IDAT 全量拼接）；覆盖率缓冲 bbox 化已作为 #3 的修法写进发现，不在方案节重复计数；编码器流式化同理并入 #4 |
| §8 降 CPU 方案 | 3 | `readPixel` 每像素分配、覆盖率收集容器与扫边、合成阶段整数除法 |
| §9 local mode 可行性 | 1 | `computeCoverage` 的 `Array<Int64>(width*height)` 是函数内创建、随 `compositeCoverage` 用完后即弃的非逃逸对象，与 `SvgAnalyticRasterizer.cj:79-101` 已落地的 `ANALYTIC_LOCAL_ACCUMULATOR_*`（8 MiB 上限、`analyticUsesLocalAccumulator` 阈值判断）同型；本部分未改，收益只能用峰值内存对照证明，故不写成方案，只作可行性记录 |
| §11 现有代码的 BUG（存量） | 5 | 本部分读到的 5 个缺陷（#1–#5）全部为存量；另核对边界：`readSample` 位偏移（1/2/4 bit 的 `shift` 与 `mask` 在 0..7 内成立）、`writeScanline` 的 `base+3` 不越界（`x < width`、`y < height` 由 `passWidth/passHeight` 保证）、`reverseFilter` 的 `previous[index]` 与 `encoded` 等长、`arcPolyline` 的 `lambda>1` 半径缩放与 `segments` 上限 256，均无缺陷 |
| §12 并发安全与锁粒度 | 1 | `SvgRasterizer` 的 `aaDisabled`/`toleranceScale` 是可变字段，仓内 9 处创建点（`SvgRenderer:423/552/596/650/921`、`SvgClipMask:370/399/609`、`SvgClipProperty:141`）全部是每次调用新建、随即丢弃 ⇒ 线程封闭，无共享路径；`SvgPngDecoder`/`SvgPngEncoder` 无静态可变状态；`SvgElement.nextIdentity` 用 `fetchAdd`。字段跨调用存活引发的错误见 #2，属正确性而非数据竞争 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md` 文件，#13/#14 由模块其余部分承担；本部分新增的公开面（`SvgPngDecoder.decode(stream)`、`SvgRasterizer.fillGradient/strokeGradient`、`SvgPointerEvents`）是否进 README，需在合并阶段对照模块 README 统一核对——此处不单独判定 |
| 文件覆盖（§13 等） | 19/19 | 无缺失；本部分不含 `.md`，§13 文档一致性不适用 |

### 第 21 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（#1 use 变换与效果丢失、#2 嵌套 svg 效果丢失）；设计 1（#6 会话状态下沉）；可读性 3（#8 注释与实现不符、#11 三处同构、#12 死存储）；语言特性 0（`Option` 全部显式 `match`，无静默 `getOrThrow`；`SvgValueCache` 版本缓存用法正确）；安全性 0：本部分不做字符串拼 XML、不过滤用户文本，`warnings` 只输出元素 tag/id 与 href，无凭据面；外部文档解析强制 `unsafePolicy: Remove` + `allowExternalReferences: false`（`SvgRenderTree.cj:1871-1889`），未发现注入面 |
| §1 死代码 | 3 | 逐符号搜引用：`SvgRenderTree.cj` 的 24 个 private/internal 顶层函数（`elementTransformMatrix`、`symbolDimension`、`transformedRectBounds`、`markerContentFits*`、`isAxisAlignedMatrix`、`appendSvgQuad`、`maxInt64`、`ceilSvgPixel`、`arrayContainsSvgString`、`unionCommandBounds`、`svgElementPath`、`findSvgElementPath`、`deriveRenderFonts`、`svgStyledLengthOrZero`、`SvgExternalResolution`、`svgHrefFragment`、`svgExternalParseOptions`、`svgApplyM6VectorEffects` 等）均在本文件有调用；`findSvgElementById`（internal）在 `SvgClipMask`/`SvgElementApi`/`SvgHitTest`/`SvgMarkerExpander`/`SvgPatternSampler`/`SvgTextRenderer`/`SvgTimeline` 有调用；`SvgRenderer.cj` 的 14 个 private 符号（`clipRectCoversCommand`、`quadDeviceBounds`、`applyQuadCoverages`、`clearBitmapAlpha`、`clipBitmapToRect`、`strokeDashValues`、`scaleStrokeDash`、`rectPathData`、`SvgImageMapping`、`imageMapping`、`drawImage`、`sampleImage`、`clampImageIndex`、`svgShapeAntiAlias`/`svgShapeTolerance`/`svgGradientColor*`）均有调用；`svgTextTolerance`/`svgWarnColorProfile`（internal）在 `SvgRenderer` 与测试中调用。命中：`needsLayer` 两条恒假分支（#7）、`resolvedStackKey` 死存储（#12）、`import fountain::f_base.*` **不判**（`SvgRenderTree.cj:1855` 的 `String.unsafeBytes()` 来自 `f_base/UnsafeBytes.cj`，`grep` 已确认）。对外可达 public（`SvgDisplayCommand`/`SvgDisplayList`/`SvgRenderTreeBuilder`/`SvgRenderer`/`renderToPng`/`SvgRoot`/四个提示枚举）不判；`SvgDisplayCommand.textTolerance`/`strokeWidthOverride`、`SvgDisplayList.styles/textLayouts/fonts` 为 internal 且都有消费 |
| §2 重复逻辑 | 3 | 同文件逐函数体比对 + 跨文件按字面量/形状搜索：四角 AABB ×4、嵌套视口裁剪块 ×3、元素组包装 ×3（#11）；两套 `/tag[i]` 路径拼接（#13）；同一外部文档样式重算（#14）。另：`maxInt64` 三份（`SvgRenderTree.cj:1722`、`SvgRasterizer.cj:489`、`SvgPatternSampler.cj:491` 的 `maxInt64Pattern`）已由 part20 #8 记录，此处不重复计数；测试侧 `svgDoc` / `fillCommands` 属共享测试夹具，不计 |
| §3 空实现 | 0 | 逐个函数体检查：无 `{}`、无 `TODO`/`FIXME`、无 `catch {}`（`SvgRoot.cj:160-174` 的 `catch (_: SvgException)` 是"非法值 → `None`"的显式降级，返回值被使用）；`walkElement` 的 `case _ => ()`、`applyEffects` 的 `case None => ()` 都是可选属性缺省，不是吞错 |
| §4 栈溢出 | 1 | 命中 #5（`walkChildren`/`walkElement`、`findSvgElementById`、`findSvgElementPath`、`markerContentFitsIn` 对程序化深树无深度上限）。已排除：`use` 链（`SVG_USE_MAX_DEPTH` 64，先查循环再查深度）、嵌套 svg（`:817` 64 层）、`SvgRenderGuard.stack`（`SVG_MAX_REFERENCE_DEPTH`）、解析路径（`SvgBuilder` 的 `maxDepth` 512）。`markerContentFitsIn` 的递归深度受文档深度约束，只有与 #5 同源时才可触发 |
| §5 OOM | 2 | 命中 #3（外部文档缓存 N×16 MiB）、#4（层数 × 整画布）。已量化：单层 = `w×h×4`，默认上限下单层 256 MiB；外部文档单份 ≤16 MiB、无份数上限。拒绝路径：`maxPixels`（单位图）、`SVG_EXTERNAL_MAX_BYTES`（单文档）、`maxDepth`/`maxElements`（单文档结构），缺"聚合"维度 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据（`doc/perf-baseline.md` 只覆盖 M4 滤镜基准，与渲染树/取样无关），所有性能判断均降级为「待验证假设」1–5 与优化方案（均标无基线） |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无读写锁；`SvgRenderGuard` 是普通 `ArrayList`，依赖单线程调用（见 #6） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；`renderDisplayList` 是纯顺序循环，不存在"形式并发实际串行"的结构 |
| §6.4 低效算法 | 2 | 已按"无基线"处理、未计缺陷：`walkContainer` 子指令逐层复制（O(n·depth)，优化方案 4）、每 marker 实例整树路径遍历（优化方案 6）；`build` 三次样式解析（优化方案 3）同属此类。`findSvgElementById` 每次线性扫描（`use`/`resolveUrlRef`/`paint` 引用）在文档元素数大时也偏高，缺调用频次数据，未单列 |
| §7 降堆内存方案 | 2 | 离屏层按包围盒分配、quad 覆盖率缓冲交集化 + 蒙版复用（方案 1、2）。`SvgRenderer.warnings` 只增不减并入 #6 的修法（会话状态下沉），不单列 |
| §8 降 CPU 方案 | 4 | `sampleImage` 每像素分配、`build` 三次样式解析、`walkContainer` 指令复制、marker 路径遍历（方案 3–6） |
| §9 local mode 可行性 | 0 | 本部分的临时大对象都**逃逸**：显示列表（`commands.toArray()` 返回给 `SvgDisplayList`）、离屏层 `SvgBitmap`（跨指令存活）、`coverage` 缓冲（`Array<Byte>`，且 `applyQuadCoverages` 返回后被 `bitmap.pixels` 复用）。`drawImage`/`sampleImage` 的临时数组不逃逸但总量小（4 字节级），收益无法用峰值内存对照证明，故不立项 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条发现全部为存量（快照模式无 diff）。另核对未计入的边界：`SvgDisplayCommand.init` 的 `clipBounds` 回退到 `bounds`（`:129-132`）与字段注释一致；`foreignObject` 的 `maxPixels` 判定（`:665`、`:683`）因 `SvgBitmap` 保证宽高 > 0（`SvgBitmap.cj:93-96`）不会除零；`walkElement` 的 `case` 顺序经继承链核对无遮蔽（`SvgRoot`/`SvgUse`/`SvgImage`/`SvgTextElement`/`SvgShape` 均直接继承 `SvgElement`，`SvgShape` 是 `abstract class`）；`drawImage` 的 `sourceWidth/Height = 0` 会得到 `Inf/NaN` 并被 `sampleImage` 的边界判断吞掉（`SvgBitmap` 构造已禁止 0 尺寸，不可达）；`svgWarnColorProfile` 用原始 `profile` 作 key（`:1327-1330`），大小写不同的同一 profile 会各告警一次，影响仅限噪声，未单列 |
| §12 并发安全与锁粒度 | 1 | 命中 #6（`SvgRenderer`/`SvgRenderTreeBuilder` 实例状态）。线程封闭证据：`SvgRenderTreeBuilder` 在 `SvgRenderer.render`（`:92`、`:102`）与 `SvgPatternSampler.sampleTileUncached`（`SvgPatternSampler.cj:283`）都是每次新建；`SvgElements` 本身可变且无同步（`attributesVersion` 递增、`SvgValueCache`），属于文档模型既定契约（单线程修改），未单列 |
| §14 功能完备性与 README 覆盖 | 3 | 命中 #1（use `transform` 未进 README 例外）、#2（嵌套 svg 效果无文档）、#10（`paint-order` 承诺与实现不符）。本部分所有 public 类型均在 `README.md` 符号清单命中（`SvgDisplayCommand(Kind)`、`SvgDisplayList`、`SvgRenderTreeBuilder`、`SvgRenderer`、`SvgRoot`、`SvgShapeRendering`/`SvgTextRendering`/`SvgColorRendering`/`SvgColorInterpolation`、`renderToPng`），无"公开 API 未文档化" |
| 文件覆盖（§13 等） | 9/9 | 无缺失；本部分不含 `.md`，§13（文档一致性）不适用，仅把 `README.md` 作为承诺源做交叉核对（README 本身归其他部分） |

### 第 22 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 F2（规范偏差）/ F6（同类 API 语义漂移）；诊断静默 F3；缓存失效 F4；告警契约不一致 F5；可读性 F11 / F12；接线 F14。安全性：转义/注入不在本部分文件（解析器与 writer 不在清单内），本部分仅 `normalizePaint` 的外部引用降级（`SvgStyleResolver.cj:900-911`）已核对为安全 |
| §1 死代码 | 2 | 逐个核对了本部分 8 个生产文件的全部 `private` / `internal` 符号（`grep -w` 全仓、排除 `.worktrees`）：`appendAll`/`isValidDash`/`outlineOne`/`removeDuplicatePoints`/`distanceSquared`/`addCap`/`addJoin`/`addContour`/`ensurePositiveOrientation`/`signedArea`/`clampUnitForStroke`/`ellipsePolygonForStroke`/`rectOutline`/`reverseContour`/`circleOutline`/`dashPieces`/`expandCustomValue`/`cssCalcAppliesTo`/`resolveFontRelativeLength`/`considerCssCandidate`/`originSource`/`resolveCssKeyword`/`collectCssStyleTexts`/`normalizeSvgTextDecorationShorthand`/`svgJoinWords`/`clampSvgUnit`/`tryParseSvgOffset`/`isKnownFeature`/`splitSwitchTokens`/`languageMatches`/`read*`/`write*`/`formatSvgLengthList`/`splitSvgListTokens`/`tryParseSvgPointList`/`readPointList` 均有调用点；`protected` 在本部分只有 `SvgShape.cj:160` 一处 `init`（所属 `public abstract class SvgShape`，非 `sealed`）按硬原则豁免；`public` 成员均为对外可达契约，不判死代码。命中 2 处不可达分支（F8 / F9） |
| §2 重复逻辑 | 4 | 同文件两两比对（8 个生产文件内全部函数体压成「输入→输出→副作用」摘要后比对）：F10 两组（`ensurePositiveOrientation`/`reverseContour`、`outlineContours`/`outlinePolyline`）；跨文件字面量：F11（`SvgTag` 双表）、F2（`cssCalcPercentReference` 与 `toUserUnits` 的换算复制）、F15（测试常量与用例复制）。`splitSwitchTokens`（`SvgSwitch.cj:119`）与 `splitSvgListTokens`（`SvgShape.cj:448`）严格度不同（前者容忍双逗号并过滤空项，后者拒绝），属有意差异，未判重复 |
| §3 空实现 | 0 | 本部分 grep `TODO|FIXME|XXX|UnsupportedException` 零命中；无空函数体；`SvgText` 仅包装构造、`SvgValueCache` 之外无「默认空实现」接口；两处 `catch`（`SvgShape.cj:384`、`392`）均为「解析失败 → `None`」的显式降级，非静默吞异常 |
| §4 栈溢出 | 0 | 递归只有两处：`computeSubtree`（`SvgStyleResolver.cj:143-156`）与 `collectCssStyleTexts`（`1016-1026`），深度等于 DOM 深度，由解析期 `maxDepth`（默认 512，`SvgSecurity_test.cj:259-268` 断言）与 `maxElements` 约束；`SvgStrokeOutliner` 的 `dashPieces`/`outlineOne` 均为迭代。未发现可证明的无界递归，故本部分不单列（编程构造的超深树在解析/序列化路径同样先受限） |
| §5 OOM | 2 | dash 片段数无上限（F1）、resolver 三个无界缓存（F3）。`SvgStyleResolver` 的 `mergedRules`/`mergedFontFaces` 每次 `prepare` 覆盖，非只增 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `bench` 数据，任何「此处慢」都没有自耗时占比，已全部降级为「待验证假设」表第 1-4 条 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`，不存在临界区 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get`，无线程池与队列 |
| §6.4 低效算法 | 1 | dash 循环次数由 `路径长度 / dash 周期` 决定（F1）；`SvgSwitch.isKnownFeature`（`109-116`）为 17 项线性扫描，输入是常量表，未达热点门槛 |
| §7 降堆内存方案 | 2 | 见「优化可行性方案」前两条，均 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 见「优化可行性方案」后两条，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `f_svg` 已整体开启 local mode（`f_svg/README.md`「编译期要求」），本部分候选是 `cascade` 的临时 map，但无「改前/改后峰值内存」数据，且 `HashMap` 是否具备 mode 重载未核对 ⇒ 只可能写进待验证假设，本部分未命中 |
| §11 现有代码的 BUG（存量） | 15 | 本部分 15 条发现全部为存量（工作区无改动、无 diff）。边界核对：`removeDuplicatePoints` 空输入、`clean.size == 1`、`signedArea` 空数组、`dashPieces` 全零 dash、`outlineOne` 非闭合路径首尾帽、`tryParseSvgOffset` 空串均已逐条走查；`dashPieces` 的片段数无上限是其中唯一会导致资源耗尽的边界 |
| §12 并发安全与锁粒度 | 1 | `SvgStyleResolver` 可变字段无同步（F7）；`SvgSwitch`（纯静态）、`SvgTag`（纯静态）、`SvgStrokeOutliner`（静态纯函数，`SvgStrokeStyle.dashArray` 只读）线程封闭；`SvgValueCache`（`SvgElement.cj:28-41`）非原子，但所属 DOM 本身是可写结构，按「DOM 非线程安全」处理，未单列 |
| §14 功能完备性与 README 覆盖 | 1 | `outlineElement` 解析路径未接线（F14）；本部分无 `.md`，README 覆盖核对留给含 README 的部分，此处只按 `src/` 公开声明对照调用图 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无遗漏；本部分不含 `.md`，§13 无适用对象 |

### 第 23 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 #2、设计 #4/#6、语言特性 #8（`0.0 * fontSize`）、可读性 #9、安全性 #1（外部输入放大为 DoS）；本部分不拼接 SQL/命令、不写 HTML，无注入面 |
| §1 死代码 | 1 | 逐个 private / internal / protected 符号搜引用：`SvgDecorationStyle.none` 全仓零引用（#5）；`appendSvgDecorationRect`、`svgDecorationDeclares`、`readLengthArray` 等均有调用者；`SvgTextElement` 的 `public mut prop` 属对外可达 public 不判；`SvgTextDecoration.tryParse`、`SvgDominantBaseline.fromNameOrWarn` 仅测试引用，记可见性建议 |
| §2 重复逻辑 | 3 | `tryParse` vs `parseSvgDecorationLines`（#3）、`SvgDecorationStyle` vs `SvgTextDecorationSpec`（#6）、属性名清单与「是否声明」判定（#7）；另把 14 个文件里的函数体两两比对过，`fromNameOrWarn` 有 4 处同构实现（`SvgTextPath.cj:48`、`:94`、`:140` 与 `SvgTextBaseline.cj:76`），确属重复，但泛型化只能靠「解析函数 + 默认值」双参数注入，收益不抵抽象成本，仅记入此格不单列 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`case None => ()` 均为「可选属性缺失」的正常分支（`:294`、`:307-316`），有 `@Assert` 覆盖降级行为 |
| §4 栈溢出 | 0 | 本部分无递归：`resolveSvgDecorationStyle` 是显式 `while` 沿 `parent` 上溯，深度由 DOM 深度决定且为迭代；`appendSvgDecorationSegments` 的 4 个分支都是定步长循环（`Wavy` 固定 32 步）。唯一风险是父指针成环导致死循环，但环只能由程序化 `appendElement` 构造，解析产出的树无环，未定为缺陷 |
| §5 OOM | 1 | #1（`dotted`/`dashed` 段数随 `text-decoration-thickness` 放大，每段 5 条命令 + 数组）；`place()` 的结果数组上界由字形数决定，有界 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，任何「热点」结论不成立，已列待验证假设 1-3 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`；唯一共享可变状态是 #4 的实例字段，按 §12 计 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 线程池 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`；`dotted`/`dashed` 的复杂度放大已在 #1 按 §5 计数，不重复计；`SvgTextDecoration.toString` 的 `text +=` 循环上界为 3，不构成 |
| §7 降堆内存方案 | 1 | 优化方案「11 个 `SvgValueCache` 改按需创建」，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案「`place()` 去多余复制 + 预分配」，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分产生的 `SvgTextPlacement` / `SvgPathCommand` / 结果数组全部逃逸（作为返回值或写入显示列表），`@local` 不成立；只有 `place()` 内的 `adjusted` 数组不逃逸，收益需峰值内存对照，已并入待验证假设，不出改造建议 |
| §11 现有代码的 BUG（存量） | 4 | #2 继承丢失、#3 解析契约漂移、#8 NaN 偏移、#9 测试断言/越界；#1 按 §5 计。`place()` 的锚点负偏移钳制在测试里有明确语义（`startOffsetForms`「负值 / 超长钳制」），按有意设计处理，未报 |
| §12 并发安全与锁粒度 | 1 | #4（`SvgTextPathLayout` 三处实例可变状态无同步）；`SvgTextElement` 的 11 个 `SvgValueCache` 也是无同步的「检查-然后-写入」（实现见 `f_svg/src/SvgElement.cj:33-40`），但只在「并发读 + 同时改属性」下才有害，且属 `SvgElement.cj` 那部分，此处只作提示 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；`SvgTextPath` 的 `path`/`href` 优先级、`side`/`method`/`spacing` 均已接线（`SvgTextRenderer.cj:649-724`），未发现「承诺未实现」或半成品；README 成员清单遗漏见范围外提示 |
| 文件覆盖（§13 等） | 14/14 | 本部分清单 14 个文件全部读完，无缺失；本部分不含 `.md`，§13 的文档一致性由其他部分覆盖 |

### 第 24 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #1（状态泄漏）、#2（时长语义）、#4（`x`+`dx`）、#7（textPath 嵌套）；本部分无 XML 反序列化入口，注入/转义不在本轮范围（`setAttr` 转义由序列化层负责） |
| §1 死代码 | 1 | #8 `SvgAnimationSpec.target`；逐一对本部分 `private`/`internal` 符号做全仓/包内搜索：`parseTransformArgs`、`buildOperation`、`expectArgCount`、`resolveOriginComponent`、`normalizeCssTransformOrigin`（被 `SvgStyleResolver.cj:803` 引用）、`effectiveElementTransform`（`SvgClipMask`/`SvgElementApi`）、`splitSvgSemicolon`（`SvgAnimation.cj:119`）、`resolveTextRotations`（测试）、Timeline 全部私有函数、TextRenderer 全部私有函数均有调用者；`SvgWritingMode.fromNameOrWarn` 仅测试引用 → 按 §1 只记可见性提示，不算死代码；对外可达 `public`（`SvgTimeline`/`SvgTextRenderer`/`SvgTextLayout`/`SvgTextGlyph`/`SvgTransform*`）不判 |
| §2 重复逻辑 | 3 | #3（单位换算 4 处）、#12（`permute`×3、`max`×2）、#13（均匀 keyTimes×3）；另两两比对本部分 40+ 函数体：`addAnimationNumberLists` 与 `accumulateAnimationValue` 语义不同（相加 vs 累加差值），`charFontAscent`/`charFontDescent` 仅两行且分支不同，均不构成重复 |
| §3 空实现 | 0 | 逐个函数体核对：无空体、无 `TODO`/`FIXME`、无 `catch {}`；`case None => ()` 均为可选属性缺省回退（如 `:116`、`:426`、`:529`），有明确降级语义 |
| §4 栈溢出 | 1 | #6 `resolveAnimationTime` 递归深度无上限；`cloneSvgElement`/`collectAnimationSpecs`/`cloneSvgNode` 的递归深度受解析期 `maxDepth`（`SvgBuilder.cj:127`，默认 512）约束，不计；`resolveMotionPath` 已有 64 层上限 |
| §5 OOM | 1 | #5 warning 无界累积（`SvgTimeline.warnings` 随帧增长）；`values` 已有 10000 条上限（`:493`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据，热点结论不成立，已列入待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁内 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无任务提交 |
| §6.4 低效算法 | 2 | 两处 O(n²)（`sortedAnimationSpecsByBegin`、竖排列处理）复杂度静态可判，但缺耗时占比数据，按铁律归入「优化可行性方案（无基线）」而不是缺陷 |
| §7 降堆内存方案 | 1 | 方案「`sample()` 每帧深拷贝」；warnings 的容量问题已在 #5 按缺陷处理，不重复计入 |
| §8 降 CPU 方案 | 2 | 方案「排序 + 路径扁平化缓存」「竖排列处理降复杂度」，均标 `无基线` |
| §9 local mode 可行性 | 0 | `layout` 内临时 `ArrayList` 满足「函数内创建、函数内用完」，但收益必须以峰值内存前后对照证明，暂无数据 → 待验证假设 #3。约束：实验特性、需 `--enable-local-mode`、local region 共享 `cjLocalRegionMaxSize` |
| §11 现有代码的 BUG（存量） | 6 | #1/#2/#3/#4/#7/#9；本部分读到的 60+ 函数边界（空列表、`count-1` 除零、`frames.size==1`、`placed.size` 截断、`parseSvgTimeValue` 的 `None`）均已逐一核对，除上述外无缺陷 |
| §12 并发安全与锁粒度 | 0 | 本部分无可证的多线程共享路径：`SvgTextRenderer`/`SvgTimeline` 均为单次渲染内实例，无可变全局；但 `SvgTimeline.sample` 修改 `this.warnings` 与源文档（#1），使同一实例不可重入/不可并发调用，视为 #1 的次要后果 |
| §14 功能完备性与 README 覆盖 | 1 | #7（textPath 嵌套未接线）；本部分无 `.md`，模块 README 的公开 API 覆盖由含 README 的部分核对 |
| 文件覆盖（§13 等） | 12/12 | 无缺失；本部分无 `.md`，§13 文档一致性不适用 |

### 第 25 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：发现 1/3/4/6；可读性：13；安全性：本部分不接触 XML 序列化与字符串输出，`SvgUnknownElement` 只保存 `QName`、不做转义，无注入面（转义在 `SvgWriter`，非本部分） |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` 符号搜了引用：`SvgCmapSegment`、`SvgCmapGroup`、`positiveTtfMod`、`requireTtfTable`、`appendTtfContour`、`transformTtfCommand`、`scaleTtfCommand`、`readTtfTag`、`glyphIndex`、`locaAt`、`parseGlyph`、`parseSimpleGlyph`、`parseCompositeGlyph`、`parseCmap`、`ligatureTableFor`、`decompose`、`decomposeScale` 均有调用者；`SVG_TTF_*` 四个常量、`SvgCmapParseResult`、`SvgFontFileAccess` 均有引用。命中：不可达 `case`（发现 12）、`decomposeScale` 返回元组首元素被丢弃（并入发现 10）。对外可达的 `public`（`SvgTrueTypeFont.unitsPerEm`、`SvgView.viewTarget` 等）只记录「仓内仅测试引用」，不判死代码 |
| §2 重复逻辑 | 3 | 命中：发现 7（元素属性样板）、8（advance/路径/scale/loca 双实现）、9（vector-effect 名称表），另发现 10 为同构可参数化。已两两比对 `SvgTrueTypeFont.cj` 内 21 个函数体摘要；跨文件按相同错误文案/字面量搜过（`"不支持 CFF / OTF 轮廓"` 在 `SvgTrueTypeFont.cj:187` 与 `SvgTrueTypeTables.cj:175` 各一份，属版本头与表 tag 两处防御，未单列） |
| §3 空实现 | 1 | 无空函数体、无 TODO/FIXME、无 `catch {}`（唯一 `catch` 在 `SvgTrueTypeFont.cj:333` 会把 `FSException` 转成 `SvgException`）。命中：`hlig`/`clig` 的 warning 实参被丢弃（发现 15） |
| §4 栈溢出 | 0 | 唯一递归是 `parseGlyph` → `parseCompositeGlyph` → `parseGlyph`，`SvgTrueTypeFont.cj:520` 在入口判 `depth > SVG_TTF_MAX_COMPOSITE_DEPTH(8)` 并抛 `Limit`，自引用字形（`SvgTrueTypeM4_test.cj:363`）已有用例；其余文件无递归。剩余风险不是栈而是堆（发现 1） |
| §5 OOM | 2 | 命中发现 1（复合字形放大，严重）、2（整文件读入无上限）。已核对：单字形点数上限 10000（`SvgTrueTypeFont.cj:559`）、单表 16 MiB 与表数 64（`SvgTrueTypeTables.cj:22`–`24`）、`loca` 长度按 `glyphCount` 校验、`cmap` 段表/分组长度按子表长度校验 —— 这些路径都有拒绝分支，未重复计入 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`docs/LocalMode*.md` 是 local mode 资料，不含字体或 vector-effect 热点），故不立热点结论；候选全部进「待验证假设」#2–#5 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`SvgFontFileAccess.readCount` 是 `AtomicInt64`，无临界区 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 1 | 静态可判的复杂度问题只有两处：复合字形逐组件重解析同一子字形（并入发现 1，CPU 放大同源）、`ligatureAt` 每次重映射整段码点（`413`–`420`，调用方 1836–1851 循环 ⇒ 长 run 呈 O(n²)，无耗时数据，列入待验证假设 #4） |
| §7 降堆内存方案 | 1 | 见「优化可行性方案」堆内存条目；另一处候选（`SvgTrueTypeFont` 常驻整个字体字节，reader 零拷贝）属有意设计，未列方案 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案」CPU 条目（GSUB 装载期 4 次解析）；`vectorEffects()` 重建数组无基线，放待验证假设 #3 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完的大对象集合」可按值逃逸分析收敛：`parseGlyph` 的中间命令数组会作为返回值逃逸（`pathById`/`glyphPath` 返回 `SvgPathData`），`SvgViewBox` 是 struct。收益需峰值内存对照，无数据不立项 |
| §11 现有代码的 BUG（存量） | 7 | 逐条核对本部分读到的边界/空值/错误处理：`parse` 的 7 处表长与偏移校验、`loca` 单调与 `glyf` 上界、`parseSimpleGlyph` 的 `pointCount` 上限与 `endPts` 递增、`parseCompositeGlyph` 的深度上限、`glyphIndex` 的段查找、`SvgViewBox.parse` 的 4 值/正宽高、`strokeScale` 的奇异矩阵回退 —— 命中：发现 3/4/5/6/11/12/15（其中 11、12 定级轻微）。`SvgTtfTableDirectory.parse` 对重复 tag 静默后者覆盖（`206`）未单列，属畸形字体容错取舍 |
| §12 并发安全与锁粒度 | 0 | 本部分无可变共享状态：`SvgValueCache` 是每元素实例、`SvgTtfTableReader` 只读 `Array<Byte>`（元素不可变引用，构造后不改）、`SvgVectorEffect` 的 `ordinal` 是 `let`。`SvgElement.attributesVersion` 的写入点在 `SvgElement.cj:160/189/211/230/235/245`，均属文档树单线程编辑路径；`SvgValueCache.get` 的读改写无同步，若同元素被多线程并发读且恰好同时失效，会重复计算但结果一致（无数据竞争危害）——按「元素非线程安全」的既有契约不判缺陷，仅记录 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分 9 个公开类型（`SvgTspan` / `SvgUnknownElement` / `SvgUse` / `SvgView` / `SvgViewBox` / `SvgViewState` / `SvgVectorEffect` / `SvgVectorEffect2` / `SvgTrueTypeFont`）在 `README.md:559` 的类型清单里都有；命中：成员级索引遗漏与 `@When[test]` 成员误列（发现 14）。功能接线核对：`SvgView` / `SvgUse` / `SvgTspan` 在 `SvgTag.cj` 注册，`SvgVectorEffect2.apply` 在 `SvgRenderTree.cj:1908` 调用，`SvgTrueTypeFont` 的 internal 字体 API 全部有渲染侧调用点，无「承诺未实现」 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无 `.md`（本部分清单不含文档文件，README 一致性按模块级交叉核对） |

### 第 26 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#3（快照丢 `viewState`/`initialView`）；可读性：#9、#11；安全性 0 条 —— 本部分所有文本/属性输出都经 `f_xml::XmlWriter.writeElement`（`f_xml/src/XmlWriter.cj:474`）→ `Escaper.escapeAttribute`（`f_xml/src/Escaper.cj:43-59`，转义 `& < > " CR` 并拒绝 XML 1.0 非法码位），`SvgWriter` 自身只裸写一个 `"\n"`，不存在注入面 |
| §1 死代码 | 2 | #4（`SvgViewport.cj:150-153` 恒不可达分支）、#8（未使用 import）。机械动作：`SvgWriter.cj` 9 个 private（`finish`/`declarationFor`/`elementDeclaration`/`normalizeHrefs`/`normalizeElementHrefs`/`isHrefSlot`/`firstHrefIndex`/`isSvgReferencingElement`/`isFoldableHref`）全部有调用点；`SvgViewport.cj` 2 个 private（`resolveViewportLength`/`resolveViewportOffset`）均有调用点；`SvgWriter_test.cj` 的 `internal` 快照函数被 `SvgGzip_test.cj:32`、`SvgRoundTrip_test.cj:41`、`SvgRenderer_test.cj:436` 跨文件使用，`private writerBytes/writerElementString` 与 6 个 `WRITER_*` 常量均有使用；`f_svg.cj` 无声明。本部分无 `protected` 声明、无 `internal` 顶级类型里的 public 成员，`public` 均为对外可达（`SvgWriter` 类及其方法、`SvgWriteOptions`、`SvgViewport`、`SvgViewportTransform`、`writeSvgString`），按硬原则一不判 |
| §2 重复逻辑 | 4 | #5（百分比换算）、#6（viewBox→矩阵三处）、#7（300×150 字面量）、#10（测试快照/写字节辅助）。机械动作：把 5 个 `.cj` 中每个函数体压成「输入→输出→副作用」摘要两两比对（`SvgWriter` 10 个函数、`SvgViewport` 8 个函数 + 2 个 private 辅助、测试侧 5 个辅助函数 + 17 个用例），并按 `300.0`/`150.0`/`"href"`/`"xlink"` 字面量跨文件搜索；`isHrefSlot` 与 `firstHrefIndex` 虽同为「判 href 槽位」，但一个返回 Bool 一个返回下标且 `firstHrefIndex` 复用前者，属正常分工 |
| §3 空实现 | 0 | 5 个 `.cj` 内 `TODO`/`FIXME`/空函数体/`catch {}` 零命中（`grep -rn "TODO\|FIXME\|catch ("`）；`resolveViewportOffset` 的 `None => 0.0` 是「无 x 属性 = 不平移」的显式语义，不是吞错 |
| §4 栈溢出 | 1 | #2：`normalizeElementHrefs` 递归，深度由 `SvgSecurityOptions.maxDepth`（可配，默认 512）或程序化构树决定，非代码常量上界；`resolveViewportLength`/`resolveViewportOffset` 无递归；测试快照函数同样递归但只用于内存构造的小样本 |
| §5 OOM | 0 | 本部分唯一全量物化点是 `writeSvgString` 的 `ByteBuffer`+`String`，输入来自已完整驻留内存的 `SvgDocument`，不构成「按不可信长度预分配」或「无界容器」；增量成本已按实测量化不了，移入「优化可行性方案」与「待验证假设」#1 |
| §6.1 热点瓶颈 | 0 | 未提供任何 `cjprof` / `cjpm bench` 数据（`SvgBenchmark*.cj` 里搜 `writeSvgString`/`SvgWriter` 零命中），写路径耗时占比不成立，已列入待验证假设 #2 |
| §6.2 大粒度锁 | 0 | 本部分 5 个 `.cj` 内 `synchronized`/`Mutex`/`Atomic` 零命中，无锁 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用；`SvgWriter` 是单线程流式写入器 |
| §6.4 低效算法 | 0 | 逐项核对：`firstHrefIndex` 线性扫描发生在属性列表（通常 <10 项）上，不构成 O(n·m) 热点；`attributes.remove(at:)` 只删同元素的重复 href（≤2 项）；无 `remove(at: 0)` 队列、无循环内字符串 `+`（`writeSvgString` 用 `ByteBuffer`）、无重复正则编译 |
| §7 降堆内存方案 | 2 | 方案「省掉 `XmlElement` 深拷贝」「`writeSvgString` 少一次副本」，均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 方案「href 归一化与树拷贝合批」，标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 不可行：写入路径的临时对象（`XmlElement` 树、`ByteBuffer`、结果 `String`）全部需要返回或跨函数存活，逃逸检查过不了；`SvgWriteOptions` 已是不可变 `struct`，local region 无受益面。另有 `cjLocalRegionMaxSize` 上限风险（写大文档等于把整份输出押进 local region），不改 |
| §11 现有代码的 BUG（存量） | 3 | #3（`SvgViewportTransform` 丢 `viewState`/`initialView`，契约不符）、#3b（`matrix` 注释与宽高覆盖口径不符）、#12（`SvgViewportTransform` 公共构造缺 `dpr`/宽高校验）。其余已核对：`SvgViewport.from` 对双非正 fallback 抛 `InvalidValue`、`toMatrix` 对退化 `viewBox`/视口抛错（`SvgPreserveAspectRatio.cj:127-129`）均正确；`SvgWriter.write(element:)` 丢弃 prolog/epilog/doctype 的行为与用例注释（`SvgWriter_test.cj:298`）一致 |
| §12 并发安全与锁粒度 | 0 | 共享面已核：`SvgViewport`/`SvgViewportTransform`/`SvgWriteOptions` 都是字段全 `let` 的不可变 `struct`，跨线程只读安全；`SvgWriter` 持有 `XmlWriter`（`ByteScratch` + 命名空间栈）是可变状态，但既有代码从未把它发布到全局/单例/注册表（`grep SvgWriter` 只见局部构造），属可证明的线程封闭；本部分无全局 `var`、无惰性初始化 |
| §14 功能完备性与 README 覆盖 | 0 | `f_svg.cj` 的 M1–M4 能力清单逐项抽查符号均存在（见文件覆盖 #5）；testdata README 的问题是「已实现还说没实现」，归 §13（#12），不是功能缺失。模块级 `README.md` 不在本部分文件清单内，未评 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`files/f_svg.part26.txt` 20 行全部读到并逐行登记 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 19 |
| 一般 | 125 |
| 轻微 | 184 |
| 其中存量 | 314 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只有文档，XML 边界、转义注入、递归、死代码等代码级风险需在 f_svg 其余 25 个部分判定。就文档本身看，质量高于一般模块：README 中英结构完全同步（36 标题、167 行表格、88 支持 / 20 部分 / 7 不支持的计数逐项相同）；132 个库文件里的 247 个公开顶层声明全部被 README 提及；文档写出的每一类上限（元素数、深度、解码像素、pattern tile、base64、TTF 表、GSUB 深度、选择器长度、`calc` 嵌套、监听器数）都能在 `src/` 找到数值一致的常量；CDATA / 注释 / PI 往返、`href` 与 `xlink:href` 归一、`writeSvgString` 仅 UTF-8 等序列化契约也与实现吻合。因此没有「严重」项，也没有功能性缺失。

需要优先修的是三处「按文档做会出错」的地方：唯一能让使用者编译失败的 `elementPath()` 示例（#1）；安全表没说明 `unsafePolicy=Keep` 会覆盖所有 `allow*`（#2）；以及「不读字体/图片文件」与公开的 `SvgTrueTypeFont.load(path)` 相反（#3）。前两条各改一两行，第三条改首段与不支持表各一处。次一级是两条不可执行 / 不可用的 API 说明：`defs` 交给 `SvgBuilder` 无入口（#4）、`SvgHitTest.hitTest` 写成静态调用（#5）——都会让使用者卡住但不会误解安全语义。

其余 9 条是新鲜度与精度问题：中英「生成 / 写回」行不同步且多写了不存在的配置项（#6）、`openspec/specs/svg-*` 死链（#7）、自动生成清单混入内部成员且有截断（#8）、Hershey 小写描述（#9）、`data:` MIME 范围（#10）、M6 三个虚拟文件（#11）、M5 特异性口径（#12）、M2–M6 未标注历史（#13）、用例计数（#14）。它们适合随下一次文档维护批量修订。

结构性建议只有一条：能力矩阵现有 6 份副本、漂移已发生三次，收敛到 README 单一来源并加一条与 `src/` 常量比对的校验脚本，成本远低于继续人工同步。存量 14 条（5 一般 + 9 轻微），是否纳入本轮修复待用户决定。

**第 2 部分**：这 17 份文档的整体质量高于同类模块：可验证的部分几乎都经得起核对——17 张渲染快照的 SHA-256 与表内记录逐字节一致，实体上限（64 KB / 8 MB / 2 GB）、属性值 1 MiB、元素数 100 万、深度 512 这些数字在代码里都能找到对应常量，转义确实完全交给 `f_xml::XmlWriter`（`SvgWriter.cj:73-89` 只组装 `XmlDocument`），安全表里 script / `on*` / 外部引用三条与 `SvgBuilder.cj:332-481` 的移除逻辑一一对应，M7 文档的 API 清单也与 `SvgAuthoringBuilder.cj` 逐项对得上。这些都是"文档承诺 = 实现"的部分，没有发现虚构能力。

风险集中在**三处过期**，都是文档没跟上代码演进，而不是设计缺陷：

1. 构建配置与依赖（#1）——照抄 §1.3 的 toml 会因缺 local-mode 开关编译失败，且漏掉 stdx 依赖；这是最容易被使用者踩到的一条，建议优先修。
2. 安全与能力表（#4、#5）——SVGZ 已实现且带 64 MiB 解压上限，文档却写"不支持"、安全表里也没有这个上限；同时解析层把四类动画标签当未知标签，严格模式下会拒绝含 SMIL 的合法文档，与 spec 的"SHALL 识别"和 M7 的往返验收都对不上。前者影响安全评估结论，后者影响严格模式的可用性，都值得排期。
3. 基线与度量口径（#2、#10）——基准样本被重生成（246 KB → 289 KB）后数字没重测，CSS 匹配指标又拿"compute 全量上界"去判"匹配阶段未达标"，两条都会让后续的回归对比失去意义。

M7 的错误码写错（#3）单独看是文字问题，但它让"按文档 catch `Io`"的调用方静默失效，级别按后果定为一般。其余 7 条（#6–#12）是公式/API 名/文件归属/验收口径类问题，属可读性与自洽性，可随文档整理一并处理。

本部分存量问题 12 条（一般 5 / 轻微 7），是否纳入修复待用户决定。

**第 3 部分**：本部分 20 个文件是 M2/M3 的规格与验收档案，不是运行时代码，因此没有注入、逃逸、OOM 一类执行风险；真正的风险是**验收口径失真**与**事实源分散**。

先说好的部分：M3 的可执行承诺绝大多数与实现一致——7 项资源上限逐项在代码中命中且都在分配前判定，7 个新枚举、`parseAuto` / `parseGzip` / `writeGzip`、`linearRGB` 双次转换、`Analytic` 逐像素列有符号面积、`feMerge` 缺省输入、`image` 的 background 占位语义、8 种原语均在 `src/` 有对应实现且行号可指，`SvgRenderGuard` 也已在公开入口自建。文档的自省程度同样少见：`verification-2.md` 主动记录了自己没修干净的 C4/C6，并把文档一致性单列成一条 WARNING 级别的发现。

问题分两类。第一类是**规格写错而代码是对的**：Paeth Scenario 把预测器算反、Adam7 的行长校验与自身条款互斥、marker 缺省值 Scenario 与 `?SvgLength` 契约相反、feTile 的「四角」断言数学不成立、`filter` 原语 warning 缺定位信息。这五条都是逐字节或可审计级别的验收依据，必须改文档：不改，下一轮按文档补用例就会写出失败断言，或把错误实现验收通过。第二类是**审计链**：`verify-report*.md` 死引用、`tasks.md` 分支约定自相矛盾、M3 归档任务未执行而 `doc/spec` 副本仍以「现行契约」口吻陈述（`feDropShadow` 已扩、`SvgRenderOptions` 已扩、m6 的 `begin="click"` 语义已变），以及 M2 报告开头的过期摘要。

阻塞项：无。四条「一般」不阻塞代码功能，但建议在下一里程碑开始前用一个纯文档 PR 修掉；「M3 规格以哪份为唯一事实源」需要用户拍板，审查方不代为决定。

**第 4 部分**：本部分是 M3 终验与 M4 验收档案，不含运行时代码，因此不存在直接可触发的注入、逃逸或崩溃；风险集中在**"规格与实现不同源"**与**"验收证据不实"**两类。

M4 的十个能力域（滤镜、文本、pattern、clip/overflow、TTF、view/switch/anchors、路径长度、CTM）在代码里都已落地，抽查的签名、缺省值、上限常量与效果顺序基本一致，说明实现完成度不低。但规格正文有四处把行为写反或写成另一种定义：`screenCTM` 矩阵顺序（#1）、兼容性声明漏 `switch`（#2）、三个基线属性"按 spec 可继承"（#3）、`mathematical` 基线口径（#4）；另有一处方向措辞自相矛盾（#15，`side="left"` 的"左移"与"向下"）。这些都是"照文档写用例必失败、照实现写又与文档冲突"的验收级错误；其中 #1 尤其隐蔽——唯一的 Scenario 用可交换的均匀缩放，把错误公式"验证"成了通过。

两条上限缺口是 M4 新能力的直接后果：#5 的路径测量无点数/段数预算（单条曲线最多 65536 点，公开 API 每次重建段表），#8 的字体 `load` 整文件物化且无字节上限。前者可由不受信 SVG 触发（`d` 的命令数不受 `maxElements` 约束），建议优先补预算并登记到 `svg-security`；后者责任已划给调用方，按健壮性补一条上限即可。#6 的 `stitchTiles` 则是"公开属性静默无效"，默认值下不影响输出，但需要按"实现或声明限制"二选一收口。

审计链问题（#7 的 validate 结论矛盾、#9 的 12 个测试文件名、#10 的死引用、#11 的重复章节号、#12/#13 的计数与状态相反、#14 的计数三口径、#15 的 `side` 方向措辞）不影响使用，但会让后续复核对"哪一轮是最终裁定、哪些缺口还开着"产生误判；建议作为一个纯文档 PR 集中清理，合并模块报告时与第 3 部分的同类条目并为 2–3 条。

`严重` 为 0：本部分无运行时代码，未发现崩溃、并发或数据计算错误；文档中的递归与大部分 OOM 上限齐全。性能与内存只有 5 条待验证假设（段表放大、`side` 法线语义、继承偏差像素、测试计数未复跑、字形/滤镜耗时），均无基线，不进修复清单。阻塞项：无。

**范围外提示**（`.cj` 与 `README*` 属其他子轮，只记一句）：`f_svg/README.md:107` 把 `switch` 只选第一个满足条件者写成能力表一行，未标注为与 M3 的输出差异（`tasks.md:141` 与 `fix-plan-2.md:58-60` 均要求标注）；`f_svg/src/SvgFilterPrimitive.cj:177`、`SvgGzip.cj:96` 仍留 M3 骨架期 `TODO`（对应实现已完成）。

**第 5 部分**：本部分是 f_svg 的 M4 验收档案与 M5 变更文档，不含运行时代码，因此没有可直接触发的注入、越界或崩溃路径；真正的风险是**「规格、修复计划、实现」三方不同源**。M5 的十项能力在代码里都已落地，抽查的枚举取值、上限常量、缺省值、合成顺序与规格基本吻合，说明实现完成度较高；但有三处规格级偏差会让「照文档实现 / 照文档验收」出错：`calc()` 混用单位被写成全局无效（实际几何属性支持）、元素级 API 签名漏 `mediaWidth`/`mediaHeight`（默认 300×150 与渲染宽度不一致）、字体别名声称区分字重与字形（实现只做 family 映射）。这三条与 `fix-plan` 的同一编号条目直接冲突，建议在归档前以 fix-plan 为准回收规格，而不是留待下一里程碑。

其余为档案质量问题：m4 `verification.md` 第 7 节残留被第 8 节否决的 4096 上限、m5 两份 fix-plan 的依据报告缺失、`svg-value-types` 两条 Scenario 错位重复、`width="auto"` 分支未入规格、`design.md` D10 承诺了一个从未实现的 `SvgShapingFont` 扩展点、`svg-text` 的 `kern` 回退条件比实现窄。这些不影响运行时行为，但会持续消耗复核成本，可排在规格修订同一批处理。本部分未发现阻塞项，也未发现 OOM / 栈溢出级别的规格缺陷；D10 的扩展点缺失若被下游当作可用能力（自定义 `SvgFont` 接入 `liga` / `kern`），会直接导致编译失败或能力误判，建议与三处规格偏差同批清理。

**第 6 部分**：本部分是 f_svg 的 M5 收尾与 M6 全套过程文档（设计、三轮修复计划、验收报告、7 份 delta 规格），没有源码。文档整体质量高于一般项目：每条规格都带可执行 Scenario，限值（16 MiB / 64 / 32 / 8 层 / `maxPixels`）都能在源码里找到对应常量与前置检查，`use` 环引用先于深度判定、外部文档强制 `Remove`、`foreignObject` 像素预算这类容易漏的点也都落到了实现。

主要风险不在「文档没写」，而在**收口后的回流**：

- 两条契约分叉会直接影响使用者——`text-decoration-color` 缺省值（spec 说 `currentColor`，实现与 design 用 `fill`）和 `SvgTimeline.duration()` 未跟随 `max` 钳制。前者在 `color != fill` 时渲染结果与规格不符，后者会让「按 duration 采样到终点」的调用方多算一段空白时间；建议优先按发现 #1、#2 定口径，再决定改代码还是改规格。
- 验收材料可追溯性偏弱：design/proposal 的规模、文件清单、行号锚点与 D12/D18 结构描述均已过期，M5 两份复验报告结论相反且无取代标注，过程文档引用的 `openspec/changes/...` 路径与主规格在仓库中不存在。这些不影响当前渲染行为，但会让下一轮审计无法只凭文档复现结论。

结论：无阻塞项。建议把发现 #1、#2 作为「规格口径确认」一次性排期（各改一处即可闭合），#3–#5 归入文档治理批量修正；待验证假设 #1/#2 需补 `cjprof` / `cjpm bench` 数据后再决定是否立优化任务。范围外提示的 2 条（`m6/verification.md` 计数矛盾与覆盖矩阵落点、`SvgHitQueries` 固定视口）交由第 7 部分与本模块实现审查处理。

**第 7 部分**：本部分 14 个文件是 M6 / M7 两个变更的规格与校验记录，闭环质量较高：规格—任务—验证三段可追溯，安全上限（16 MiB 外部文档、64 条特性、32 个监听器、discard 深度 1、`maxElements`、8 层 GSUB、32 MiB base64）逐条能在代码里找到对应常量与负向用例；M7 的 `write(OutputStream)` / `save(File)` 与 design、spec、README、20 条测试四方对得上，没有 XML 拼接或转义责任错位。

主要风险有两处。一是 `svg-security` 用绝对措辞承诺「外部文档不安全内容一律 Remove」，而实现仍继承 `allowScript` / `allowEventAttributes` / `strict`，同一变更的自验记录（W-3-3）也承认了这个边界，属于规格与实现、规格与自验记录的双重矛盾，按现文本引用该规格会得到错误的保证。二是外部文档缓存只有「单份 16 MiB」而没有聚合预算，`use` 数量受 `maxElements` 约束时可累积到远超单份上限的驻留内存，而图像侧已有像素预算兜底，两者不对称。

其余 4 条是校验记录自身的小口径问题（1187/1186、9.5 是否执行、矩阵落点失真、openspec 路径失效），不影响功能，但会削弱归档记录作为审计证据的可信度。本部分不含源码，无阻塞项；建议在归档 M6 前一次性收敛计数与矩阵，并给外部文档预算一个明确结论。

**第 8 部分**：本部分 17 个 `.md` 是 M1（模块骨架与值类型）、M7（生成侧 API）、local-mode 三份归档变更的规格与验收记录，整体质量偏高：Requirement 与实现能逐条对上，两处设计偏差（D1 文件名冲突、D9 错误 kind）都被规格吸收并留了书面裁决，local-mode 的门限常量与除法谓词和文档给的代码片段逐字一致。文档层面的问题集中在记录卫生：M7 的 `verify-report.md` 停在修复前（1225/38、W-5 开放），与 `verification.md`（1226/39、W-5 已修）差一条用例，`tasks.md` 还自带两个互斥分支名，且 proposal 的 `kind: Io` 与 spec/tasks 相反——都属于「读者按哪份文件办事会走错」的偏差，改动量都在一两行。

代码只有一份 `CssCalc.cj`（267 行），结构清楚（表达式/项/一元/原子四层下降，单位与百分比在叶子归一），除零、单位混用、括号深度、尾随垃圾这些常见边界都处理了，也有对应用例。阻塞项只有一处：**括号深度被限制为 16，一元 `+`/`-` 递归却完全没有上限**，而入口正是不可信文档的 `style`/`<style>` 文本——几十 KB 的连写符号即可把解析器推到栈溢出，这类崩溃不可捕获，属「一个属性值打掉进程」的量级，建议优先修（改成循环或复用 `depth` 计数都只要几行）。其次是 `em` / `%` 换算与乘除漏了加法分支已有的有限性校验，溢出时抛 `SvgException` 而不是返回 `None`，绕过了样式层联为 `None` 准备的「记 warning 并回退初始值」路径；它的结构性原因是 `parseExpression` 与 `parseTerm` 两份同构循环，修的时候把有限性/单位一致性收敛到一个出口更稳。

其余（不可达语句、单位序列化重复、spec 措辞与行号）属可读性与维护性，可随上述修复一起处理。性能方向的两条建议（`CssCalcValue` 改值类型、数字叶子复用单遍扫描器）都没有改前基线，只作为待验证假设留给下一轮补数据。存量缺陷 9 条，是否纳入修复待用户决定。

**第 9 部分**：本部分是 `f_svg` 的 CSS 前端：词法器本身写得克制（单遍、字节级、非法字符降级而不抛），媒体查询与 `An+B` 的边界也基本打磨过；风险集中在**「解析阶段判定的合法性」与「匹配阶段的数据结构假设」不一致**，三处严重问题都是这一类：

- **必须修（严重）**：① `CssSelectorIndex` 只用分组第一条选择器建桶，`rect, circle` 的第二条永远不生效——设计文档明确承诺过分组（`doc/f_svg-M2设计.md:84`），而现有 15 个测试文件没有一条把分组规则送进级联，属「静默丢样式」；② 属性选择器的引号值按字节切片，非 ASCII 值抛 `IllegalArgumentException`，绕过只捕 `SvgException` 的 `CssStyleSheet.parse`，一句 `[data-x="中文"]` 就能让整份文档不渲染；③ 后代组合符匹配没有记忆化，256 段选择器配 512 层嵌套（两个上限都是代码自己允许的）组合数为 `C(512,256)` 量级，一条 512 字节的通配选择器即可挂死进程。前两条的修法都很局部（遍历全部选择器建桶；用 `decodeCssIdent` 或按 `utf8Length` 步进），第三条需要加一张本次调用内的备忘表并单独收紧「后代段数」。
- **应当修（一般）**：`parseCssInteger` 溢出抛异常击穿「非法返回 `None`」，与 ② 同属「非 `SvgException` 穿透公开解析入口」；十六进制转义未排除代理区（`Rune()` 抛异常）；属性值与选择器 ident 不解码转义，导致 `[data-x="a\62 c"]` 静默不匹配，且与词法层「转义是受支持输入」的口径相反；`CssParser.cj` 的空壳 + 缺版权头（M2 验证记录已提过，未闭环）。
- **可排期（轻微）**：两套选择器表示并存留下的不可达分支、`while(true)` 尾部不可达、`cssAttributeMatches` 重复的 `case Exists`（不可达）、五个兄弟遍历函数同构（`LastChild` 双扫）、空白分词两份实现、`toString` 循环内物化——都是低风险清理。
- 优化侧：候选收集（全类键扫描 + 插入排序 + 每元素两个容器）与兄弟遍历是本部分最值得先 profile 的两处，但没有基线数据，全部按「无基线方案 / 待验证假设」记录，不进 `todo.md` / `tasks.md`。
- 测试侧观察：15 个用例文件组织清晰、负向用例密度高（属性选择器非法形式、`:not()` 嵌套、`An+B` 非法表达式各有整组断言），但**恰好缺三类样本**——分组选择器的级联命中、非 ASCII / 转义输入、超长选择器与深文档的组合；三个严重问题都落在这三块空白里。

存量缺陷共 13 条（3 严重 / 4 一般 / 6 轻微），是否纳入修复待用户决定。性能类结论本部分均无基线数据，全部以「待验证假设 / 无基线优化方案」记录，不进 `todo.md` / `tasks.md`。

**第 10 部分**：本部分覆盖 `f_svg` 的「CSS 解析 + 解析覆盖率光栅化 + 类型化动画元素」三条线，8 个生产文件。整体质量偏上：解析器普遍采用「容错 + 告警」而不是抛异常，`var()` 展开有深度与环双重上界并有用例固化，local mode 改造把门限判断写成除法形式避免 `width*height` 溢出，还用 `analyticCoverageImpl(useLocal)` 给 local/堆两条路径做了逐元素等价断言——这些说明作者对边界有明确意识。解析覆盖率的积分算法（按顶点/交点分段 → 每段内边次序不变 → `∫clamp` 梯形）逐段核对正确，没有发现数值错误。

需要排期的：

- **阻塞项**：发现 1，嵌套 `@media` 的互递归没有任何深度约束。它不依赖业务输入，一段刻意嵌套的 CSS 就能把栈打穿，而入口正对不可信的 `<style>` 文本与内联 `style`。修法很小（加 `depth` 形参 + 复用现有 `skipCssAtRuleWithin`），但必须连测试一起补。
- **契约面两条**：发现 2（`SvgBegin` 写出的 `0s; a.end+1s` / `a.repeat(2)` 读不回来，链式 `begin` 被当成 0）与发现 3（`toString` 丢 `@font-face`/`@color-profile`）都是「库自己产出的东西自己消费不了」，对把 `f_svg` 当无损 DOM 或做 SMIL 播放的下游最痛，建议一起修并补往返用例。
- **资源面两条**：发现 4（整幅 16 B/px，默认 `maxPixels` 下单次 fill ≈1.0 GiB）与发现 5（`events` 按边数平方增长、强制 local、无回退）。前者有 `maxPixels` 兜底，属于「默认配置下的峰值过高」；后者的最坏输入不在 `maxPixels` 的管辖范围内，建议按「先给上界（`SvgErrorKind.Limit`）、再谈回退」的顺序处理。
- **可维护性**：发现 6～8 是重复实现。三份插入排序里 `@ local!` 那份无法泛型化必须留，其余两份可用 `std.sort`；测试里 6 份比较循环可抽一个断言 helper。发现 9、10 是两条「静默」：单参 `parse` 丢诊断、过期注释误导读者，改起来都是一行。

性能与内存方面本部分**没有任何测量数据**（无 `cjprof` / `cjpm bench` 基线），因此三条优化方案与四条待验证假设都不进修复清单。最值得先补数据的是「行内全点对求交」与「逐列 `ArrayList` 分配」——两者同时影响 CPU 与 GC，且替代算法明确（扫描线、内联分段），基线一成就是纯收益。

已确认**没有**的问题：数据竞争与死锁（本部分无锁、无线程间共享可变状态）、XML 注入（属性经 `escapeSvgAttribute`，CSS 文本未接进 XML 写入路径）、`var()` 无界递归（深度 + 环双重限制）、对外可达 `public` 的死代码（一律按契约保留）。

存量缺陷共 10 条（严重 1 / 一般 4 / 轻微 5），全部为存量，是否纳入修复待用户决定；本报告只读代码，未做任何修改，未跑构建。

> 范围外提示（不计入统计）：`SvgBitmap` 的 `maxPixels` 默认 64 Mi px（`f_svg/src/SvgBitmap.cj:230`）、`SvgTimeline` 的 `values` 10001 / mpath 64 层硬上限、`SvgBegin` 的工厂方法集合，均属其它部分；`docs/LocalMode.md`、`f_svg/doc/spec/**` 只用于取证，未按 §13 审查。

**第 11 部分**：本部分 20 个文件没有阻塞项：没有栈溢出路径，没有并发共享，没有吞异常的空实现，序列化的值侧转义链路（`SvgBuilder` → `SvgElement.toXmlElement` → `f_xml Escaper`）完整且严格。

需要排期的是三条**一般**级问题，全部集中在 auto 尺寸与字符分类两个对外能力上：(1) `SvgAutoSize` 的回退分支把已确定的另一轴覆盖成 300/150，`<svg width="auto" height="40">` 会得到 150 的高度，且 warning 文案与事实不符（可稳定复现，现有用例未覆盖该组合）；(2) `svgBidiClass` 里那段恒不可达的 AL 分支掩盖了阿拉伯补充区（`0x0750-0x077F`、`0x08A0-0x08FF` 落到默认 `L`）与表现形式区（`0xFB50-0xFDFF`、`0xFE70-0xFEFF` 落到 `R`）的误分类，且测试只断言了 `0x627`；(3) 内容包围盒用 fallback 视口而非已解析视口（需先确认百分比解析口径，若确认则同属尺寸错误）。

质量偏好的是数值与合成核心：`SvgBlend` 的 12 种可分离模式与 CSS Compositing 逐条对得上，`SvgBounds` 的空盒哨兵/并交/四角变换语义自洽，`SvgBitmap.blend` 的预乘-反预乘闭环正确，`SvgBegin.after` 也处理了 `-0.0`。技术债主要在**重复表达**：四个 `fromName`、三处 `/255.0 * alpha` 预乘换算、两套「读像素→混合→写回」流程、散落 6 处的 300×150 默认视口——目前一致，但任何单点修改都会造成难查的偏色或视口漂移。

测试侧的问题是结构性的：`SvgBenchmark*.cj` 用 `println` 计时却挂在常规 `@Test` 里，`cjpm test` 每次跑 20 万次字形解析与多次 1024² 渲染，产出的数字因 `-O0` 又不能用。本部分性能结论一律未成立，疑似热点放在「待验证假设」，等 `cjprof` / `cjpm bench -O2` 数据再定。

存量缺陷 14 条（3 一般 + 11 轻微），是否纳入修复待用户决定；其中 #1 与 #2 建议优先，#3 需先补一次规格确认。

**第 12 部分**：本部分的核心风险集中在 `SvgClipMask.cj`：嵌套 clip/mask 的"整幅画布一层"实现把"引用深度 64"直接放大成 64 倍画布内存（#1），而 mask 内容的绘制只认元素自身的纯色 `fill`，渐变/继承填充/文本/evenodd 会得到空白或反向覆盖率（#2）；这两个问题叠加，使"支持 mask"在当前实现下只对最简单的手写纯色蒙版成立。`SvgBuilder` 的安全面整体方向正确（元素/深度上限、事件属性、外部引用、`script` 都有处理），但外部引用判定用字面量匹配，既有 CSS 转义漏报也有空 `href` / `mailto:` / 注释误报（#7），且非 SVG 命名空间整体跳过过滤（#8），需要在合并报告里作为安全项单独列出。

`SvgColor`、`SvgCircle`、`SvgBounds_test`、`SvgClipPropertyM4_test` 等文件质量良好：解析/序列化有 round-trip 用例，边界与非法输入覆盖到位；`SvgComputedStyle` 的规范化与继承也有完整测试，唯一实质问题是 `font-variant-ligatures` 的 `no-*` 反向解析（#5）。

第二轮通读又补出一条同级别阻塞项：**#17「前缀关键字用字节长度 + 定长切片识别」**——`href` / `clip-path` / `clip` / 事件属性五个入口，任意中文或 emoji 开头就把切片点落在多字节字符中间，抛出的 `IllegalArgumentException` 不在 `SvgException` 契约内，`<image href="中文"/>` 即可触发。改动量只有 5 行（改 `startsWith`），风险和收益比最高，应和 #1 一起列为第一优先。次一级是 `maskRegion` 的 `userSpaceOnUse` 百分比换算（#18，与 #11 的 `SvgLength.unit` 丢弃同源：单位/百分比信息在值传递中被丢掉）。其余补充项都是可维护性（rect→path 三份、clamp/max 双份、warning 归一化复刻、构建递归深度依赖可配置上限、命名与格式）。

存量 26 条（严重 3 / 一般 10 / 轻微 13），是否纳入修复待用户决定；性能与内存优化 4 条均无基线，只作为下一轮采数清单，不构成结论。

**第 13 部分**：本部分 20 个文件（5 个实现 + 15 个测试）没有阻塞项：无并发共享、无锁、无空实现、无吞异常；`SvgDocument` 的查询语义（`elementById` 含根、`elementsByTag` 不含根、`views` 文档序、`anchors` 空 href 兜底）与注释逐条对得上；`SvgCrc32` 的查表实现与标准向量一致；`SvgContextPaint` 的两级上下文帧解析在 6 个渲染用例下行为正确；15 个测试文件基本都是"有真实断言"的用例（像素颜色、命令数、包围盒、警告关键字、异常 kind），不是跑通即过。

需要排期的是 4 条**一般**问题，它们指向两处"隐式契约"：(a) `SvgDocument` 把 `root` 声明成 `public var`，却只在 `init` 里挂 `mutationHub` / `warnings`（#1），换根即静默失聪——改一行就能变正确、不改就一直是坑；(b) 遍历与序列化是裸递归（#2），默认 `maxDepth=512` 兜住常规路径，但 `maxDepth` 可配、程序化建树无上限，与模块内"超限抛 `Limit`"的既有约定不一致；(c) warning 把外部输入全文按元素复制（#3），这是本部分唯一"输入可控 + 无上限"的内存放大面，给 warning 加截断与去重即可收敛；(d) `context-fill` 遇 `currentColor` 时按实例颜色落地（#4），与 M5 规格措辞不符，属需要产品/规格拍板的语义选择，建议先补一条用例把语义钉死再改实现。

11 条轻微问题分两类：一类是**测试侧结构债**（#8 未使用导入、#9 夹具复制、#10 死辅助函数、#11 复制构造与注释不符、#12 计时口径与基准混入单测、#13 缩进），不影响产品行为但持续放大回归成本；另一类是**接口面冗余与契约缺口**（#5 不可达分支 + 文案重复、#6 两份 `findSvgElementById`、#7 tag 表 4 份且逆向只测 4/10、#14 `SvgCursor` 只当字符串用、#15 可变 DOM 未声明线程模型）。

性能结论本部分一律未成立：只有两处自测耗时、口径还不一致（#12），2 条方案与 5 条候选全部标 `无基线（待验证）`，等 `cjprof` / `cjpm bench -O2` 数据再定。

存量缺陷 15 条（4 一般 + 11 轻微），是否纳入修复待用户决定。

**第 14 部分**：本部分是 f_svg 的「元素模型 + 滤镜模型」核心：`SvgElement` 的"原始属性为唯一事实源 + 按 `attributesVersion` 失效的类型化缓存"设计干净，序列化对文本/属性/CDATA/注释四个注入面都做了处理（只有 PI 与标签名漏了，见 #9），9 个滤镜原语与 3 个光源的取值缺省值与 SVG 规范逐条对得上，10 个测试文件覆盖到了像素级等价、非有限值降级、告警文案和预算上限，质量在本仓属于中上。

主要风险集中在三个地方，都不是单文件笔误而是"契约缺口"：

1. **DOM 结构不变量无人维护**（#1）—— `appendChild`/`insertBefore` 既不接管旧父也不防环，重复挂载静默产生双份渲染，成环则让主路径的 `svgRootOf` 挂死、序列化爆栈。这是本部分唯一能稳定复现"挂死/崩溃"的路径，且触发只需要公开 API 的常规误用，建议优先补两条守卫 + 3 条用例。
2. **滤镜内存随原语数线性放大**（#2）—— 单缓冲上限 256 MiB 是既有 `maxPixels` 设计的结果，但 `runChain` 把每个中间结果都留到最后，20 原语链路在 4000×4000 区域下就是 GiB 级峰值。这一条要有峰值数据才好定级，先作为优化方案（O2）推进。
3. **并发契约空白**（#3）—— 缓存是无同步惰性写，而 README 对线程安全一字未提。最省的修法不是加锁，而是在 README/类注释里明确"非线程安全"。

其余 8 条轻微项（属性模板重复、双向拷贝重复、仅测试的 `fromNameOrWarn`、不可达的 `??`、`symbol` 包围盒、注释与格式残留）可以排期批量清理：#5 + #6 + #7 合并后大约能删掉 70 行重复代码，同时消掉已经发生的两处行为漂移。性能方向（O3–O5）都缺基线，按纪律只进「待验证假设」，不进修复清单。

**第 15 部分**：这部分是 f_svg 滤镜链的「执行内核」：原语实现本身写得相当克制——每个原语都「读入缓冲、返回新缓冲」，不原地改；`feMorphology`/`feConvolveMatrix`/`feTurbulence` 都主动设了核尺寸、采样预算、octaves 上限；区域先做除法判定再分配（`SvgFilterRenderer.cj:126-132`）；非法值普遍回退 + warning；测试覆盖也扎实（颜色矩阵、合成算子、edgeMode、morphology 半径、turbulence 确定性、区域百分比在用户空间求值等都有对应用例）。

主要风险集中在两处：

1. **资源拒绝路径不完整**。高斯模糊是整个模块唯一没有上限的核（严重 #1），σ 直接来自文档，`ceil(3σ)` 同时决定分配与计算量；这条路径与同文件其它原语的防护风格明显不一致，属于该补的一块。再加上 `named` 无差别保留中间缓冲（#2）与 Float64 中间表示 17 倍膨胀（优化方案），大画布 + 多原语时峰值内存会到 GB 级。
2. **同一语义散落多份**。`stdDeviation` 五处、`flood-color` 两处、像素搬运六处、`positiveMod` 两份，其中 `stdDeviation` 已经开始漂移（缺省 0 / 2 两派），是典型的「改一处忘一处」隐患；`feDropShadow` 的区域外扩漏乘 `primitiveUnits`（#4）就是这种分散带来的实际 bug——同一属性在「算区域」和「做偏移」两处用了不同单位假设。

`SvgFont.cj` 的问题更轻：别名解析丢弃 stretch（#9）会让 `@font-face` + `font-stretch` 的组合选错字面并多做一次合成缩放，其余（alias 未注册 warning、`registeredFamilies` 只记 family、`nearestStretch` 平局取先注册者）都与注释自洽。

阻塞项：只建议把 #1 与 #4 作为本轮必修（前者是 DoS/OOM 面，后者是可见的渲染裁切）；#2/#7/#9 可排期；#5/#6/#8/#10/#11 属结构治理与接线，可与后续滤镜增强一起做；其余轻微项（注释、命名、重复实现）随手清理即可。

**第 16 部分**：本部分代码整体结构清晰：几何包围盒走解析极值而非采样（`cubicDerivativeRoots` / `arcBounds` 的中心参数化都对），GSUB Type 5/6 format 3 的偏移布局逐字段正确，gzip 解压的上限与 CRC/ISIZE 双校验、Hershey 字体全覆盖断言、各 M4–M6 测试用例的分层都很扎实；`SvgBounds` 用负尺寸哨兵表示空、零尺寸盒合法的约定也贯彻一致。

主要风险集中在两处「生命周期与入口没对齐」：

1. **渐变采样**把「解析」放进了逐像素路径。同一个根因同时造成严重级的内存无界增长（warning 按像素累积）、诊断静默丢弃（`sampler.warnings` 无人读）以及明显的重复计算。这是本部分唯一建议优先排期的阻塞项——它不是性能优化，而是「一次 fill 的内存随画布面积线性增长」的缺陷。
2. **GSUB coverage 的展开式表示**把字体字节里的长度直接变成堆上的元素个数，放大比可达 10⁵ 量级；`@font-face` 字体属文档可控输入，因此这是一个可被外部触发的 OOM/卡死面，建议与区间化改造一起做。

其余一般级问题（`font-feature-settings` 覆盖默认值、`no-common-ligatures` 无效、stop 的 CSS 颜色未接线、rect miter 未套样式、无 stop 渐变画黑、M5/M6 解析重复且告警漂移）都属于「静默给出错误结果」的类型，不崩溃但会让人误判库的能力，适合排期修复。轻微项（死字段、不可达分支、过时 TODO、枚举 toString 与 attrName 分叉）可随手清理。

另有一处设计取舍需记录，未作为缺陷：`resolveChain` 对 href 循环「warn + 停止继承」，对深度 > 64 却直接抛 `Limit`（`SvgGradient.cj:473-475`），而 `SvgRenderer` 全文无 `catch`，即一个 65 层 href 链会让整幅图渲染失败。测试 `SvgGradientSampler_test.cj:299-307` 已把该行为固化为契约，故按「既定契约」记录；若后续希望与「循环引用降级」保持一致，需要同时改测试与 `doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md:64` 的口径。

**第 17 部分**：本部分代码的可读性与约定一致性好：命中测试的指针事件矩阵（`visiblePainted / painted / fill / stroke / all / bounding-box`）实现完整且有对应用例，长度解析的往返与不保真边界写得清楚，图像资源把“联网/读文件”的安全责任显式交给调用方，插值器的结构校验返回值语义明确。

阻塞项只有一处：**命中查询系列 API 的坐标空间错配**（`getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` 忽略元素与祖先的 `transform`）。这四个 API 在 README 中作为“支持”对外承诺，而现有测试全部使用无变换文档，属于典型的“用例避开 bug”。同一文件的遍历门禁缺失（定义容器与 `display:none` 子树不剪枝）、硬编码 300×150 视口、无元素上限，建议与坐标修复一并处理——它们同属“查询路径另写了一套简化遍历，没有复用 `svgHitWalk`”。

其余为可排期的质量问题：奇异矩阵回退导致误命中、方形端点帽与 join 区域漏判（像素级保真）、`calcMode` 双映射、`SvgLinearGradient` 双读取路径、未使用 import、`SvgLength` 非有限值契约。性能与内存的 5 条线索都只有静态推断，已全部留在「待验证假设」与「优化可行性方案（无基线）」，未写成结论。

**第 18 部分**：本部分的代码质量整体偏中上：数值/列表/画笔的解析器边界处理扎实（符号紧邻、多余逗号、指数截断、非有限值都有明确错误），marker 派生的递归与数量上限按设计文档闭环（1024 截断 + 深度 64 抛 `Limit`），测试对裁剪与快路径的覆盖也到位。真正需要排期的是两类问题：

第一类是字体表解析的资源边界（#1、#2、#14）。`kern` 做了累计上限，`GPOS` 却在两个位置漏了上限，且 Coverage/ClassDef 的范围展开既不去重也不计数——这是同一个「把报文头字段当数组长度」的根因在不同函数里的三种表现，**阻塞项**应优先修 #1（一条 384 KB 的构造表就能打爆内存）。#3（GPOS Extension 不支持）不是内存问题但会静默丢字距，属于「安静的错误结果」，建议同批修掉，因为修法就是复刻 GSUB 已有的 15 行解包逻辑。

第二类是缓存与变更模型（#6、#7、#8）。三者共享一个前提：`SvgElement` 既暴露可变集合，又在读路径上写缓存，而设计文档把渲染描述为「全程只读」。单线程常规用法下不会出错，所以现有测试全绿；但一旦有人按文档假设并发渲染，或直接改 `attributes` 列表，就会出现陈旧值、数据竞争或监听器栈溢出。建议按「先定契约再改实现」处理：要么冻结文档 + 预计算缓存，要么在 README 明确「单线程写、不可并发渲染」。这三条都属于存量、非阻塞，但应在同一次契约整理中一起定掉。

其余（#4 异常类型穿透、#5 求逆阈值、#9 PI 转义、#10-#13 死代码与校验）都是低风险但修起来很便宜的项：`horizontalOnly` 字段、两个仅测试使用的 `fromNameOrWarn`、`requiredFeatureIndex` 都可以顺手清掉或接上；`invert` 的绝对阈值建议改相对判据，因为调用侧全部静默兜底 identity，出错时用户只会看到「画面不对」而无从定位。

**第 19 部分**：本部分风险集中在 `SvgPatternSampler`：它是唯一同时持有跨元素缓存、递归 DOM 搜索与自建几何换算的类型，本轮 1 条严重（tile 缓存无总量上限）+ 3 条一般（warning 即丢弃整块内容、长度换算漏单位、typed prop 与 attr 解析双轨）全部落在这里。`SvgPathData` 的扫描器与 `toAbsolute` 质量较好：词法边界、隐式重复、弧标志、非有限数都有对应用例，未见解析崩溃面；`SvgPaintOrder` 语义符合 CSS `paint-order` 规范（缺省补齐、去重、未知关键字丢弃并告警）。

阻塞项：`pattern tile 缓存无上限`（可被单个恶意/超大文档触发到 GB 级常驻）。其余一般项可按模块排期：`warning 即丢弃` 与 `长度换算漏单位` 都是小改动但影响可见行为，建议与 pattern 相关的 M4/M5 回归一起做；`findPatternById` 递归建议与「建一次 id 索引」的重构合并（顺带解决 O(元素数 × 填充数) 的全树扫描）。

代码质量整体为「结构清楚、文档密度高、边界用例扎实」，主要债务是「同一语义多处实现」——pattern 的 typed prop / sampler 解析 / `toUserUnits` 三套并存，`paint-order` 的双次分词是同一类问题的轻量版。本部分所有性能结论均无基线，已按规则放入「待验证假设」与「优化可行性方案（无基线）」，未写入缺陷统计。

**范围外提示**（不计入本部分统计）：`f_svg/src/SvgGzip.cj:96` 仍留 `// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。`，这两个入口已在 `SvgParser.cj:71-92` 实现并有 `SvgGzip_test.cj` 覆盖，属过期 TODO，建议随该文件所属部分一并清理。`SvgParser_test.cj:113-133` 在 `target/` 下写临时文件且未删除，测试重复运行会残留文件（仅影响测试环境）。

**第 20 部分**：本部分的工程质量在"防御式解析"上做得扎实：PNG chunk 状态机把签名、IHDR 首个且唯一、PLTE/tRNS 位置与长度、IDAT 连续性、CRC、解压长度、Adler-32 全部校验到位，并且有专门的 `SvgPngStructureM3_test` / `SvgPngChunkErrorM3_test` 覆盖；像素上限用"先除后乘"避免溢出，`SvgDecodeBudget` 在分配位图前扣减，`SvgRasterizer` 的 `subdivideCubic` 有显式深度上限——栈溢出与解析注入两条线均未发现缺陷。

主要风险集中在**采样开关的状态语义**与**按画布规模分配缓冲**两处：

1. `aaDisabled` 与 Analytic 模式两条分支互不知情（#1，严重）——`shape-rendering: crispEdges` 是常见样式，只要使用者选了 `antiAlias: Analytic`，边缘就会整体饱和外扩，且现有测试没有任何交叉组合能发现它。这是本部分唯一的阻塞项，建议优先修，并补一条 `Analytic + antiAliasOverride: Some(false)` 的像素断言。
2. `SvgRasterizer` 的 `aaDisabled`/`toleranceScale` 作为跨调用存活的字段（#2）会让 Gradient 入口继承上一次调用的状态；仓内因为"每个 paint 新建实例"而未暴露，但公开类一旦被复用就会出现难查的渲染差异，属于排期内的低风险修复（改成参数传递）。
3. 内存侧：覆盖率按整幅画布 8 B/px（#3）、编码器 3–4 份 4wh 缓冲（#4）都还没有触发 OOM 的证据，但按默认 `maxPixels = 64 Mi` 推导，单次可达 512 MiB / ~1 GiB 量级；两者都有"按行/按 bbox"的成熟修法，适合与渲染性能优化一起排期，并以 RSS 峰值对照验收。
4. 轻微项以死分支、测试死变量、无基线优化为主，可随手清理；`adler32` 与 PNG 签名各有多份副本，虽不影响当前行为，但属于"改动一处另一处不同步就会破坏互操作"的高风险重复，建议收敛到共享 util。

**第 21 部分**：本部分是全模块的"渲染总装线"，工程质量总体扎实：显示列表把 `use`/symbol/嵌套 svg/marker/foreignObject 全部展开成扁平指令，`clip`/quad/marker 的坐标推导有注释且与测试对应；`SvgRenderGuard` 把 pattern/marker/文本引用循环统一成"进入即查、离开必清"的 `try/finally`；外部文档的解析选项被强制收紧（`unsafePolicy: Remove`、`allowExternalReferences: false`），安全策略没有被主文档的宽松配置带跑；`SvgRenderer_test` / `SvgRenderTree_test` / `SvgOverflowM4_test` 对确定性、逐字节一致、深度上限、旋转裁剪都有断言。本部分未发现注入、转义或凭据暴露面。

主要风险集中在**"元素级效果只覆盖了部分元素类"**与**"聚合上限缺失"**两条线：

1. 元素级效果覆盖不全（#1、#2）是本部分最值得优先处理的正确性问题：`g`/图形/文本/图像都走完整的 `opacity + clip + mask + filter + blend` 包装，而 `use` 与嵌套 `<svg>` 只做了变换/视口裁剪。`use` 的 `opacity`/`clip-path`/`mask` 已在 M4 复验里被记录为已知限制，但 **`use` 的 `transform` 连"已知限制"都不是**，README 又泛称 `transform` 支持——这条会直接给出错误画面且无 warning，建议先修或先在 README 的 `use` 行写清。嵌套 `<svg>` 的 `opacity` 同理（`<svg opacity="0.5">` 是常见写法）。
2. 聚合上限缺失（#3、#4）都不会立刻 OOM，但都缺"单点上限之外的聚合预算"：外部文档按 href 无界累积（16 MiB × N）、离屏层按层数 × 整画布累积（默认 256 MiB × 层数）。两者的修法都成熟（预算对象 / 包围盒化），适合与渲染性能优化一起排期，并以 RSS 峰值对照验收。
3. #5（程序化深树无深度上限）只在 API 拼装场景触发，解析路径已被 `maxDepth` 保护；但它是"崩溃级别、且只需要加一个计数"的低成本修复，建议随手补上。
4. #6（会话状态线程安全）目前没有并发使用的证据，属"契约未声明"；最省的修法不是加锁，而是把 `warnings`/`sessionGuard`/图像预算下沉为 `render` 局部对象，顺带消掉"同一实例多次 render 后 `warnings` 只增不减"。
5. 轻微项以死分支（#7）、注释与实现不符（#8）、快速路径判据偏窄（#9）、`paint-order` 未接线（#10）与三处同构代码（#11–#14）为主，可随手清理；其中 #11 的三处同构块（嵌套裁剪、元素组包装）与 #1/#2 的修法同源——先把"元素级效果包装"抽成一处，再补 `use`/嵌套 svg 的两处调用，可以一次解决"重复"和"覆盖不全"两个问题。

**第 22 部分**：本部分覆盖 `f_svg` 的样式级联、描边轮廓化、形状属性与 `switch`/`tag` 分派，整体结构清楚：`SvgStyleResolver` 的级联键 `(important, origin, specificity, order)` 明确，非法值统一「告警 + 回退」而不是抛异常，安全相关的 `normalizePaint` 对 `Security` 类错误按 `none` 降级，`SvgShape` 的 13 个属性全部走 `SvgValueCache` 且与 `attributesVersion` 绑定，测试覆盖了端点/连接/dash/解析路径对照与逐字节快照。

阻塞项只有一个：`dashPieces` 的片段数完全由文档控制且无任何上限，`stroke-dasharray="0.0001"` 或 `pathLength` 放大即可让渲染在 CPU 与内存上失控，这是继脚本/外部引用过滤之后的又一条不可信输入面，建议优先修。

需要排期的是四条契约类问题：`calc()` 百分比对 `r` 用了算术平均（与 spec 与既有 `toUserUnits` 不一致）、`SvgStyleResolver` 三个缓存跨调用无界且会让诊断静默消失、`prepare` 只按根 identity 缓存导致文档变更后返回旧规则、`computeElement` 与 `compute` 的告警语义不一致。`outlineElement` 的解析快路径与通用 outliner 语义漂移（dash/圆角/百分比）目前只影响直接调用该公开 API 的使用方，因为渲染器走的是 `outlineContours`。

死代码与重复逻辑已机械过完：无「无引用的非 public 符号」，命中的是 2 处不可达分支与 4 组同语义实现（反转轮廓、dash 分支、标签双表、换算复制），另有测试套件内的用例与常量复制。性能方面本轮没有任何 profile/bench 数据，所有热点线索（`cascade` 分配、`getBBox` 的 O(n²)、round join 多边形、计算样式全量字符串）都只写进「待验证假设」与「优化可行性方案（无基线）」，未进修复清单。

存量 15 条（含 1 条严重），是否纳入修复待用户决定。

**第 23 部分**：文本栈的模型层（`SvgTextElement` 的属性/缓存、`SvgTextPath` 的枚举与属性、`SvgTextPathLayout` 的弧长映射）结构清楚，默认值与非法值回退都有测试锁定，`place()` 的截断与降级语义也和渲染器接线一致，是本模块里质量较高的一段。阻塞项只有一个但足够重：`dotted` / `dashed` 装饰线的段数完全由用户可控的厚度值放大，单个属性值就能把渲染拖成挂死/内存暴涨，必须在对外渲染前加下限与段数上限。其余需要排期的是三处「同一件事两种实现」造成的漂移：`text-decoration` 的严格/宽松两套解析、装饰规格的两个类型、以及两处「是否声明装饰属性」的判定——它们已经导致 `text-underline-position` 的继承在无样式树路径上丢失。测试侧只需要补强两处断言（布局次数、字形规模）即可，其余覆盖是扎实的。本部分 9 条发现全部为存量，是否纳入修复待用户决定。

**第 24 部分**：本部分代码整体质量偏高：文本排版（`x/y/dx/dy`、`textLength`、竖排分列、bidi 重排、GSUB 连字/上下文整形、装饰线）的分支都有明确降级路径与 warning，`SvgTransform.parse` 的错误消息与边界（多余逗号、参数个数、非有限值）覆盖完整，`SvgTransformOrigin` 的 `0 0 + view-box` 短路也保住了历史输出的逐字节稳定。

阻塞项只有一个：`SvgTimeline.sample()` 在「无 href 的嵌套 `discard`」路径上改写调用方文档（#1），既违反类注释的契约，也让时间轴跨帧不可回放，应优先修。其次是时间语义类问题（#2 `repeatDur` 被覆盖、#4 `x`+`dx` 丢偏移）与一组「同一套换算/缓存键」漂移（#3、#9、#10），它们不会崩溃但会让渲染结果与规范/其它属性口径不一致，建议排期。warning 无界累积（#5）与递归无上限（#6）属于长跑与极端输入下的稳定性问题，成本低、收益明确，可一并处理。

性能侧的两处 O(n²)（每帧排序、竖排列处理）与每帧整树克隆都是结构性开销，但当前没有任何 profile/bench 数据，按铁律只进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。

存量缺陷 13 条（严重 1 / 一般 6 / 轻微 6），是否纳入修复待用户决定。

范围外提示：`SvgAnimation.cj:106-133` 的 `parseSvgTimeReference`/`isSvgEventTime` 只识别整串 `.begin`/`.end`，不支持 `a.end+2s` 偏移与 `0; click` 混合列表，`SvgTimeline` 的 `begin`/`end` 语义因此受限（该文件不在本部分清单内，未展开）。

**第 25 部分**：本部分风险集中在 `SvgTrueTypeFont` 这条「不可信二进制 → 路径命令」的链路上：结构校验（表长、偏移、`loca` 单调、`endPts` 递增、深度上限）做得相当扎实，测试也覆盖了截断、非单调、超限与自引用字形；缺口在**资源总量**和**语义校验**两层——复合字形可以按数量级放大命令数（唯一严重项，建议优先修），`load` 缺文件级上限，cmap 的值域、`0 = 缺失`、platform 选择、`endCode` 单调都没校验，坏字体因此会在渲染期抛异常或静默画错字形。`SvgVectorEffect2` 的矩阵分解在镜像/切变组合下会给出近似甚至错误结果，属可排期的正确性修复。

另一半问题是重复：`SvgUse` 与 `SvgImage`、`viewBox` / `preserveAspectRatio` 在四个元素类里逐字复制，`advance` / `glyphPath` / `scaleTtfCommand` / `loca` 解码各有第二份实现，`vector-effect` 名称表散落四处且靠 `toString()` 分派。这些不改变当前行为，但任何一处修复都会漂移，建议与下一次功能改动合并收敛，不必单独排期。

存量缺陷共 14 条（严重 1 / 一般 7 / 轻微 6），是否纳入修复待用户决定。性能与内存方面的两条方案均无基线，只能作为下一轮补数据的候选。

**第 26 部分**：本部分代码是 f_svg 的「写回」与「视口」两条最靠近外部契约的路径，整体质量偏上：转义完全外包给 `f_xml::Escaper`（没有任何手写转义或裸拼接，注入面为零），`SvgWriteOptions` / `SvgViewport` 都是不可变值类型（无并发风险），`SvgViewport` 复用 `SvgPreserveAspectRatio.toMatrix` 而没有第二套 meet/slice，结构分层清晰。

真正的风险集中在两处「契约宽度」不一致上：一是 `SvgWriter` 的 `xlink` 归一化只覆盖 5 种元素，`pattern`/`filter`/`mpath` 等 SVG 1.1 引用会静默写成裸 `href`（一般，会让下游 SVG 1.1 消费方丢引用）；二是 `SvgViewportTransform.from` 收下了整个 `SvgRenderOptions` 却只消费 3 个字段，`viewState`/`initialView` 打开后 `screenCTM`/命中测试与渲染输出不对齐（一般，坐标错位但无报错）。这两条都不阻塞构建，但都属于「不报错地给出错误结果」，建议排进修复清单并在合并版里补两条用例。

栈溢出（`normalizeElementHrefs` 等三趟递归）在默认 `maxDepth=512` 下不会触发，只有把上限调大或程序化搭深树才成立，故按一般而非严重处理，修法是迭代化 + 显式深度上限，需要与 `f_xml::XmlWriter` 同批改。其余 10 条轻微项以死代码/重复逻辑/文档过期为主（含 13 个 testdata README 的口径过期），可批量清理。性能与内存只有优化方向（深拷贝、三重副本、多一趟遍历），全部没有基线数据，因此只进「优化可行性方案 / 待验证假设」，不进修复清单。
