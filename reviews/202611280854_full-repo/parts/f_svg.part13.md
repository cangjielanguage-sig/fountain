# f_svg 模块审查报告

> **模块第 13/26 部分**。本报告只覆盖 `files/f_svg.part13.txt` 列出的 20 个文件（`SvgComputedStyleM5_test.cj` → `SvgDomApiM6_test.cj`，5 个实现文件 + 15 个 `*_test.cj`，无 `.md`）。其余 25 部分由主 Agent 顺序调度，合并以主 Agent 为准。

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（整模块 301 个 `.cj` + 141 个 `.md`；本部分 20 个 `.cj`，3167 行）
- **基线**：工作区快照（`git status --porcelain f_svg` 为空，源码零改动、无 diff 可比 ⇒ 全部问题记「存量」；引用的 blame 提交为 `3ec7f9f27c`（11-05）、`a95da61cb7`（11-05）、`ec10433cb9`（11-05）、`66229da437`（11-05）、`420059ecf0`（11-06）、`519d83c68b`（11-06）、`70736a7e89`（11-06）、`9858013907`（11-07）、`d12d1a47a6`（11-07）、`f8b4c49bd3`（11-07）、`a061fe1ef5`（11-07））
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 13/26 部分分报告）

## 发现

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

## 范围外提示

- `f_svg/src/SvgMutation.cj:95-106`：`notify` 用 `for (listener in this.listeners)` 直接遍历，回调里调 `document.removeMutationListener(self)` / `addMutationListener`（`SvgDomApiM6_test.removeListenerByReference` 证明按引用移除是受支持用法）即构成"遍历中结构性修改"——仓颉文档明确该情形抛 `ConcurrentModificationException`（`/d/docs/work/cangjie/cangjie-doc/md/doc/cjapi/collection.md:351`），而 `try` 只包住 `listener.onMutation(event)`，异常会从 `setAttr` / `appendChild` 冒出来（此时变更已生效）。同一处还没有重入保护：监听器在回调里改 DOM 会递归 `svgNotifyMutation → notify → 回调`，深度无上限。收尾建议：`notify` 前 `toArray()` 快照 + 重入标志（重入时排队或丢弃）。缺陷主体在本部分清单外，故不计入本部分统计。
- `f_svg/src/SvgTag.cj:21-77` / `79-93`：`create` 与 `isKnown` 各维护一份完整标签名单，`69-70` 的容器名与 `SvgContainerKind.fromTag` 重复（与 #7 同源）。
- `f_svg/src/SvgElement.cj:386-409`：`toXmlElement` 递归复制整棵子树，递归深度同 #2；`SvgWriter` 的序列化递归未在本部分核实。
- `f_xml/src/XmlWriter.cj:412-419`：`CommentNode` / `PiNode` 原样写出、不校验 `--` 与 `xml` target，是 #3（`svgNodeToXml` 直通）能产出不可解析 XML 的直接成因。
- `f_svg/README.md:588`：`SvgDocument` 的成员清单只列 `declaration` / `doctype` / `epilog` / `parseOptions` / `prolog`，未列同一 `public` 面的 `root` 与 `warnings`（功能段 `294` / `468` / `543` 有提及）。归含 README 的子轮处理。

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | cursor 关键字线性扫描在样式计算里的自耗时占比可忽略（预期 < 2%） | `f_svg/src/SvgCursor.cj:71-77` | 自耗时占比、单次调用耗时 | `cjprof record` 跑 1000 规则 × 1000 元素 + `cursor` 规则，`-O2` |
| 2 | 逐元素 warning 在内嵌 1 MB `url()` 值时的峰值 RSS 是否线性于元素数 | `f_svg/src/SvgCursor.cj:56`、`f_svg/src/SvgStyleResolver.cj:744` | 峰值 RSS / heapUsed 与元素数的比值 | 1e3 / 1e4 / 1e5 元素各跑一遍，采样 `getUsedHeapSize()` 与 RSS |
| 3 | `elementById` 的全量前序 + 每节点 `attr("id")` 比较在 1e6 元素上占显著自耗时 | `f_svg/src/SvgDocument.cj:172-187` | self time 占比、单次耗时随 n 的变化 | `cjprof record`，命中末节点 / 未命中两种输入，n = 1e5 / 1e6 |
| 4 | `toXmlDocument()` 的整树复制把峰值内存抬到约 2× 节点量 | `f_svg/src/SvgDocument.cj:153-165` | 峰值占元素数之比、副本存活时长 | 10 万元素文档连续 10 轮 `toXmlDocument()`，采样分配量与 RSS |
| 5 | `views()` 两趟比单趟多出的分配/耗时低于噪声（5%） | `f_svg/src/SvgDocument.cj:116-127` | 两趟与单趟的差值与分布 | `cjpm bench -O2` 对照，1e4 `view` + 1e5 其它元素，取中位数与 P95 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgComputedStyleM5_test.cj` | .cj | ✅ | 8 个新属性的初值/继承/CSS 全局关键字/transform-origin 归一/非法回退/`paint-order` 规范化；`styleOf`/`selfStyleOf`/`parentStyleOf` 均有调用者；未使用 `std.collection` 导入（#8）、夹具重复（#9） |
| 2 | `f_svg/src/SvgComputedStyleM6_test.cj` | .cj | ✅ | pointer-events / cursor 初值、继承、`inherit/initial/unset`、非法值告警、`url()` 告警、大小写归一；`selfStyleOf`/`childStyleOf` 与 M5 同构（#9）；未使用导入（#8） |
| 3 | `f_svg/src/SvgComputedStyle_test.cj` | .cj | ✅ | 元数据/六级级联/继承与关键字/currentColor/非法降级/`<style>` 合并/`computeElement`；含 `SvgComputedStyleM3_test`；`styleOf`/`computeTree`/`computedFill` 被多文件复用；基准用例见 #12，未使用导入见 #8 |
| 4 | `f_svg/src/SvgContainer.cj` | .cj | ✅ | 10 种容器的 `==`/`toString`/`tagName`/`fromTag` 四张表当前一致；`internal` `tagName`（`:99` 自用）与 `fromTag`（`SvgTag.cj:71`、测试）均有引用；见 #7 |
| 5 | `f_svg/src/SvgContainer_test.cj` | .cj | ✅ | 正向映射 10/10、逆向仅 4 正例 + 1 反例（#7）、嵌套 `elementPath`；每个用例都有真实断言 |
| 6 | `f_svg/src/SvgContentCycleM3_test.cj` | .cj | ✅ | pattern/marker 自引用、深度上限、guard 复用恢复、警告带元素路径；`contentDepthLimit` 重复构造见 #11；`patternChainSvg`/`markerChainSvg` 有调用者 |
| 7 | `f_svg/src/SvgContextPaint.cj` | .cj | ✅ | `useContextFrame`/`resolveContextPaintOf` 均被 `SvgRenderTree.cj:1092/1093/1168/1195` 调用；帧过滤见 #4，文案重复与不可达分支见 #5 |
| 8 | `f_svg/src/SvgContextPaintM5_test.cj` | .cj | ✅ | `context-*` 解析往返、既有取值不变、计算样式保留原值；无集合导入，无遗留 |
| 9 | `f_svg/src/SvgContextPaintRenderM5_test.cj` | .cj | ✅ | 6 个渲染用例（实例内/最近帧/无上下文/自引用/优先于 currentColor）；`m5RenderWithWarnings`、`m5HasWarning` 仅本文件使用（`internal` 可收窄，未单列）；缩进见 #13 |
| 10 | `f_svg/src/SvgCrc32.cj` | .cj | ✅ | 查表 CRC-32；`buildCrc32Table`/`SVG_CRC32_TABLE`/`updateState` 均有引用；`checksum` 与 `update(0, …)` 等价，双入口语义已由用例钉住 |
| 11 | `f_svg/src/SvgCrc32_test.cj` | .cj | ✅ | 标准向量 `0xCBF43926` / `0x414FA339`、空数据、分块续算；`fountain::f_base.*` 被 `unsafeBytes()` 使用，非死导入 |
| 12 | `f_svg/src/SvgCursor.cj` | .cj | ✅ | 37 项白名单 + `url()` / 空值 / 未知值三条回退；`SVG_CURSOR_KEYWORDS`、`isSvgCursorKeyword` 有引用；warning 内嵌全文见 #3，类型设计见 #14，扫描成本见待验证 #1 |
| 13 | `f_svg/src/SvgCursorM6_test.cj` | .cj | ✅ | 白名单全量往返、`url()`（含 data URI）、未知值、默认静默；期望表与生产白名单同值是"规格期望表"，不判重复 |
| 14 | `f_svg/src/SvgDecorationM6_test.cj` | .cj | ✅ | 厚度/双线/独立颜色/子级 none/简写颜色/百分比/wavy 描边与线宽/下划线位置；`runsOf`/`bitmapOf`/`inkAt` 均有调用者，断言均落在像素或命令上 |
| 15 | `f_svg/src/SvgDirectionM5_test.cj` | .cj | ✅ | 继承、枚举解析、RTL 反转、括号镜像、竖排、tspan/embed、段落分段、rotate 绑定、几何不变、默认与 M4 对齐；死辅助函数见 #10，未使用导入见 #8 |
| 16 | `f_svg/src/SvgDiscardM6_test.cj` | .cj | ✅ | 标签注册/属性往返、不产绘制指令、缺 `begin` 告警；未使用导入见 #8 |
| 17 | `f_svg/src/SvgDocument.cj` | .cj | ✅ | 见 #1 / #2 / #3（`zoomAndPan` 去重）/ #6 / #15；`findSvgElementById`、`collectSvgElementsByTag`、`collectSvgAnchors`、`svgNodeToXml` 均有引用；`elementById` 含根、`elementsByTag` 不含根，与注释一致 |
| 18 | `f_svg/src/SvgDocumentApiM4_test.cj` | .cj | ✅ | `SvgViewM4_test`（view 往返/可变字段/文档序/`forView`/不参与渲染）、`SvgSwitchM4_test`（语言匹配/优先级/空条件/扩展）、`SvgAnchorM4_test`（嵌套/无 href/外部 href 移除）；断言与注释一致 |
| 19 | `f_svg/src/SvgDocument_test.cj` | .cj | ✅ | 未知元素命名空间保留 + `SvgDocument` 查询/`toString` 与 writer 一致/warnings 只增/`toXmlDocument` 往返；`toStringMatchesWriter` 依赖 writer 约定（弱断言，不单列） |
| 20 | `f_svg/src/SvgDomApiM6_test.cj` | .cj | ✅ | 工厂/`viewState`/`insertBefore`-`removeChild`/监听器（异常隔离、上限 32、按引用移除）/命中查询/只读性/大文档耗时；`M6MutationRecorder.onMutation` 是接口实现（死代码豁免）；墙钟断言见 #12 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_svg.part13.txt` 的 20 行一一对应）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分 20 个文件（5 个实现 + 15 个测试）没有阻塞项：无并发共享、无锁、无空实现、无吞异常；`SvgDocument` 的查询语义（`elementById` 含根、`elementsByTag` 不含根、`views` 文档序、`anchors` 空 href 兜底）与注释逐条对得上；`SvgCrc32` 的查表实现与标准向量一致；`SvgContextPaint` 的两级上下文帧解析在 6 个渲染用例下行为正确；15 个测试文件基本都是"有真实断言"的用例（像素颜色、命令数、包围盒、警告关键字、异常 kind），不是跑通即过。

需要排期的是 4 条**一般**问题，它们指向两处"隐式契约"：(a) `SvgDocument` 把 `root` 声明成 `public var`，却只在 `init` 里挂 `mutationHub` / `warnings`（#1），换根即静默失聪——改一行就能变正确、不改就一直是坑；(b) 遍历与序列化是裸递归（#2），默认 `maxDepth=512` 兜住常规路径，但 `maxDepth` 可配、程序化建树无上限，与模块内"超限抛 `Limit`"的既有约定不一致；(c) warning 把外部输入全文按元素复制（#3），这是本部分唯一"输入可控 + 无上限"的内存放大面，给 warning 加截断与去重即可收敛；(d) `context-fill` 遇 `currentColor` 时按实例颜色落地（#4），与 M5 规格措辞不符，属需要产品/规格拍板的语义选择，建议先补一条用例把语义钉死再改实现。

11 条轻微问题分两类：一类是**测试侧结构债**（#8 未使用导入、#9 夹具复制、#10 死辅助函数、#11 复制构造与注释不符、#12 计时口径与基准混入单测、#13 缩进），不影响产品行为但持续放大回归成本；另一类是**接口面冗余与契约缺口**（#5 不可达分支 + 文案重复、#6 两份 `findSvgElementById`、#7 tag 表 4 份且逆向只测 4/10、#14 `SvgCursor` 只当字符串用、#15 可变 DOM 未声明线程模型）。

性能结论本部分一律未成立：只有两处自测耗时、口径还不一致（#12），2 条方案与 5 条候选全部标 `无基线（待验证）`，等 `cjprof` / `cjpm bench -O2` 数据再定。

存量缺陷 15 条（4 一般 + 11 轻微），是否纳入修复待用户决定。
