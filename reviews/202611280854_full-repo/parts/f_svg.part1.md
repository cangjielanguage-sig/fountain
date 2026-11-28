# f_svg 模块审查报告（模块第 1/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 0 个 `.cj` + 7 个 `.md`：`README.md` / `README_en.md` / `doc/f_svg-M2设计.md` ~ `doc/f_svg-M6设计.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源写「存量」
- **审查重点**：文档与实现的边界一致性——SVG/XML 解析与序列化契约、注入与转义、递归深度与 OOM 上限的书面承诺；「死代码 / 重复逻辑」在文档层的对应物（声明了但不存在、能力矩阵重复并已漂移）。代码级判定由本模块其余 25 个部分承担
- **报告版本**：v1（分报告，由主 Agent 合并为 `docs/review/2026-11-28/f_svg.md`）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 解析覆盖率累加器在 8 MiB 门限内走 local region 能显著压低峰值内存（README:37 的承诺） | `f_svg/src/SvgAnalyticRasterizer.cj:81-88`、`:200-201` | 改前 / 改后峰值内存与分配量 | 1024×1024 解析覆盖率场景，`-O2`、同输入、5 轮取中位数，记 `getUsedHeapSize()` / RSS 与 `getAllocatedHeapSize()`（`getAllocatedLocalObjectSize()` 会暂停所有仓颉线程，只在轮间采样） |
| 2 | 512 层深度上限下的递归构建（README:113 / `SvgOptions.cj:66`）在耗时与线程栈占用上已接近边界 | `f_svg/src/SvgBuilder.cj:127`（递归 `buildSvgElement`） | 512 层文档的解析耗时、峰值栈使用 | 生成 512 层嵌套 `<svg>` 文档，与 64 层对照计时；另用受限线程栈复现，确认是否栈溢出 |
| 3 | README 宣称「1230 条用例全绿、构建 0 warning」在当前 M7 代码上仍成立 | `f_svg/README.md:533`、`README_en.md:543` | `cjpm test` 实际通过数与 `cjpm build` 自身 warning 数（本轮只读，未跑构建） | WSL Ubuntu 下 `source cangjie.sh && cd f_svg && cjpm test`、`cjpm build`（`-O2`），记录通过数与 warning 明细 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/README.md` | .md | ✅ | 特性表、值类型、安全表、公开 API 清单逐项对照 `src/`；问题 #1–#10、#13、#14 |
| 2 | `f_svg/README_en.md` | .md | ✅ | 结构完全同步（36 标题 / 167 行表格 / 88–20–7 状态计数一致）；#1/#2/#3/#4/#5/#7/#8/#9/#10/#13/#14 同源同错，#6 为两版差异点 |
| 3 | `f_svg/doc/f_svg-M2设计.md` | .md | ✅ | 里程碑设计；`:32`、`:87` 已被 M5 推翻（#13）；上限表（`use` 64 层、动画 `values` 10000）与实现一致；`:371` 的 ASCII 32–126 与实现一致（#9 的反证） |
| 4 | `f_svg/doc/f_svg-M3设计.md` | .md | ✅ | 里程碑设计；`:332-336` 把 `antiAlias` 写成 `var`（#13）；§9 上限表与 `MAX_*` 常量一致 |
| 5 | `f_svg/doc/f_svg-M4设计.md` | .md | ✅ | 里程碑设计；`:189-190`「`load(path)` 是唯一文件入口」是 #3 的对照证据；`:191` 的 GSUB/GPOS/kern 已被 M5 推翻（#13） |
| 6 | `f_svg/doc/f_svg-M5设计.md` | .md | ✅ | 里程碑设计；`:91` 特异性加权口径（#12）；选择器 256 / `calc` 16 / 变量 8 / GSUB 8 与常量一致 |
| 7 | `f_svg/doc/f_svg-M6设计.md` | .md | ✅ | 里程碑设计；`:321`、`:326`、`:330` 三个虚拟文件（#11）；外部文档 16 MiB、监听器 32、feature-settings 64 与实现一致 |

合计：`.cj` 0 个 / `.md` 7 个 / 共 7 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 另有 2 条文档维护性方案（见「优化可行性方案」），按约定不计入堆 / CPU 统计，也不进修复清单。

## 总评

本部分只有文档，XML 边界、转义注入、递归、死代码等代码级风险需在 f_svg 其余 25 个部分判定。就文档本身看，质量高于一般模块：README 中英结构完全同步（36 标题、167 行表格、88 支持 / 20 部分 / 7 不支持的计数逐项相同）；132 个库文件里的 247 个公开顶层声明全部被 README 提及；文档写出的每一类上限（元素数、深度、解码像素、pattern tile、base64、TTF 表、GSUB 深度、选择器长度、`calc` 嵌套、监听器数）都能在 `src/` 找到数值一致的常量；CDATA / 注释 / PI 往返、`href` 与 `xlink:href` 归一、`writeSvgString` 仅 UTF-8 等序列化契约也与实现吻合。因此没有「严重」项，也没有功能性缺失。

需要优先修的是三处「按文档做会出错」的地方：唯一能让使用者编译失败的 `elementPath()` 示例（#1）；安全表没说明 `unsafePolicy=Keep` 会覆盖所有 `allow*`（#2）；以及「不读字体/图片文件」与公开的 `SvgTrueTypeFont.load(path)` 相反（#3）。前两条各改一两行，第三条改首段与不支持表各一处。次一级是两条不可执行 / 不可用的 API 说明：`defs` 交给 `SvgBuilder` 无入口（#4）、`SvgHitTest.hitTest` 写成静态调用（#5）——都会让使用者卡住但不会误解安全语义。

其余 9 条是新鲜度与精度问题：中英「生成 / 写回」行不同步且多写了不存在的配置项（#6）、`openspec/specs/svg-*` 死链（#7）、自动生成清单混入内部成员且有截断（#8）、Hershey 小写描述（#9）、`data:` MIME 范围（#10）、M6 三个虚拟文件（#11）、M5 特异性口径（#12）、M2–M6 未标注历史（#13）、用例计数（#14）。它们适合随下一次文档维护批量修订。

结构性建议只有一条：能力矩阵现有 6 份副本、漂移已发生三次，收敛到 README 单一来源并加一条与 `src/` 常量比对的校验脚本，成本远低于继续人工同步。存量 14 条（5 一般 + 9 轻微），是否纳入本轮修复待用户决定。
