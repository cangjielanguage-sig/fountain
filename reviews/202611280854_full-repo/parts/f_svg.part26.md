# f_svg 模块审查报告

> **模块第 26/26 部分**（分报告）。本部分只覆盖 `SvgViewport.cj` / `SvgViewport_test.cj` / `SvgWriter.cj` /
> `SvgWriter_test.cj` / `f_svg.cj` 与 15 个 `testdata/**/README.md`；其余部分文件见 `parts/f_svg.part{1..25}.md`，
> 最终模块报告由主 Agent 合并。本部分不写 `docs/review/` 下的模块报告。

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 5 个 `.cj` + 15 个 `.md`；全模块 301 个 `.cj` 量级）
- **基线**：工作区快照（无 diff）。本部分被审行 `git blame` 分别落在 `283f2b49bb`（2026-11-05，`SvgWriter.cj`）、
  `62956aab42`（2026-11-06，`SvgViewport.cj`）、`a3a06540fa`（2026-11-05，`SvgViewport.cj:148-154`），工作区无改动 ⇒ 全部按「存量」计
- **审查重点**：SVG/XML 序列化边界与转义、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG、文档一致性
- **报告版本**：v1（分报告）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `writeSvgString` 的峰值内存约为输出大小的 3 倍（缓冲区 + `bytes()` + 字符串） | `f_svg/src/SvgWriter.cj:223-227` | 峰值 RSS / `getAllocatedHeapSize()` 与输出字节数的比值；`ByteBuffer.bytes()` 是否拷贝 | 1 MB / 10 MB SVG 各 20 轮，写入前后采样 heap 与 RSS，同时打印 `buffer.bytes().size` |
| 2 | `normalizeElementHrefs` 在写入总耗时中占比可忽略（<5%） | `f_svg/src/SvgWriter.cj:139-168` | 自耗时占比 | `cjprof record` 跑 20 轮 `writeSvgString`（10 MB 文档，属性密集），看 `normalizeElementHrefs` 与 `Escaper.escapeAttribute` 的 self time |
| 3 | 写入路径的一次深拷贝是峰值内存主因，而非转义缓冲 | `f_svg/src/SvgWriter.cj:74`、`f_svg/src/SvgElement.cj:386-409` | 两棵树的存活对象数与字节量 | 写入前后各做一次 heap dump / 对象计数对比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgViewport.cj` | .cj | ✅ | 见发现 #3、#4、#5、#6、#7、#9、#11 |
| 2 | `f_svg/src/SvgViewport_test.cj` | .cj | ✅ | 覆盖 viewBox 九种对齐 / 尺寸解析 / 嵌套视口；缺 `options.width/height` 覆盖与 `viewState` 用例（见 #3） |
| 3 | `f_svg/src/SvgWriter.cj` | .cj | ✅ | 见发现 #1、#2；转义全部委托 `f_xml::Escaper`，本文件无裸拼接 |
| 4 | `f_svg/src/SvgWriter_test.cj` | .cj | ✅ | 见发现 #8、#10；xlink 只测 `use`（#1 的用例缺口） |
| 5 | `f_svg/src/f_svg.cj` | .cj | ✅ | 纯模块文档；抽查 `CssStyleSheet`/`SvgStyleResolver`/`SvgRasterizer`/`SvgPatternSampler`/`SvgTimeline`/`SvgSwitch`/`SvgPathData.totalLength`/`SvgGeometry.screenCTM` 均存在，无过期陈述 |
| 6 | `f_svg/testdata/fonts/README.md` | .md | ✅ | `SvgTrueTypeM4_test.cj:181` 的 `m4BuildTtf()`、`SvgTrueTypeFont.load(Path)`（`SvgTrueTypeFont.cj:330`）均存在，一致 |
| 7 | `f_svg/testdata/fonts/m5-bidi/README.md` | .md | ✅ | 占位口径过期，见 #12 |
| 8 | `f_svg/testdata/fonts/m5-gpos/README.md` | .md | ✅ | 同上 |
| 9 | `f_svg/testdata/fonts/m5-gsub/README.md` | .md | ✅ | 同上 |
| 10 | `f_svg/testdata/fonts/m5-kern/README.md` | .md | ✅ | 同上 |
| 11 | `f_svg/testdata/render/m3-negative/README.md` | .md | ✅ | 负向素材以内存构造为主，与空目录现状一致 |
| 12 | `f_svg/testdata/render/m3/README.md` | .md | ✅ | 素材位置过期，见 #12 |
| 13 | `f_svg/testdata/render/m5-bidi/README.md` | .md | ✅ | 见 #12 |
| 14 | `f_svg/testdata/render/m5-blend/README.md` | .md | ✅ | 见 #12 |
| 15 | `f_svg/testdata/render/m5-drop-shadow/README.md` | .md | ✅ | 见 #12 |
| 16 | `f_svg/testdata/render/m5-element-api/README.md` | .md | ✅ | 见 #12 |
| 17 | `f_svg/testdata/render/m5-media/README.md` | .md | ✅ | 见 #12 |
| 18 | `f_svg/testdata/render/m5-selector/README.md` | .md | ✅ | 见 #12 |
| 19 | `f_svg/testdata/render/m5-shaping/README.md` | .md | ✅ | 见 #12 |
| 20 | `f_svg/testdata/render/m5-transform-origin/README.md` | .md | ✅ | 见 #12 |

合计：`.cj` 5 个 / `.md` 15 个 / 共 20 个，全部读完（与 `files/f_svg.part26.txt` 一一对应）。

## 覆盖自检

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
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

## 总评

本部分代码是 f_svg 的「写回」与「视口」两条最靠近外部契约的路径，整体质量偏上：转义完全外包给 `f_xml::Escaper`（没有任何手写转义或裸拼接，注入面为零），`SvgWriteOptions` / `SvgViewport` 都是不可变值类型（无并发风险），`SvgViewport` 复用 `SvgPreserveAspectRatio.toMatrix` 而没有第二套 meet/slice，结构分层清晰。

真正的风险集中在两处「契约宽度」不一致上：一是 `SvgWriter` 的 `xlink` 归一化只覆盖 5 种元素，`pattern`/`filter`/`mpath` 等 SVG 1.1 引用会静默写成裸 `href`（一般，会让下游 SVG 1.1 消费方丢引用）；二是 `SvgViewportTransform.from` 收下了整个 `SvgRenderOptions` 却只消费 3 个字段，`viewState`/`initialView` 打开后 `screenCTM`/命中测试与渲染输出不对齐（一般，坐标错位但无报错）。这两条都不阻塞构建，但都属于「不报错地给出错误结果」，建议排进修复清单并在合并版里补两条用例。

栈溢出（`normalizeElementHrefs` 等三趟递归）在默认 `maxDepth=512` 下不会触发，只有把上限调大或程序化搭深树才成立，故按一般而非严重处理，修法是迭代化 + 显式深度上限，需要与 `f_xml::XmlWriter` 同批改。其余 10 条轻微项以死代码/重复逻辑/文档过期为主（含 13 个 testdata README 的口径过期），可批量清理。性能与内存只有优化方向（深拷贝、三重副本、多一趟遍历），全部没有基线数据，因此只进「优化可行性方案 / 待验证假设」，不进修复清单。
