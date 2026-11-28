# f_svg 模块审查报告（第 25/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 20 个文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 下列全部问题来源为「存量」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑
- **报告版本**：v1（分部分报告；主 Agent 合并为 `f_svg_v2.md`，本文件不写 `docs/review/`）

> 本部分不含 `.md` 文件，XML 解析/序列化路径也不在本部分（`tspan` / `unknown` / `use` / `view` 只做属性读写，字体部分处理 TTF 二进制），因此「注入与转义」在本部分无命中面；OOM、递归、死代码、重复逻辑是本部分的实际重点。

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 复合字形放大是实际可达的 OOM 路径（对应「严重」条目的量化） | `f_svg/src/SvgTrueTypeFont.cj:651` | 构造 16 MiB glyf（约 27 万组件 × 10000 点）后的峰值 RSS 与 `glyphPath` 耗时 | 生成恶意 TTF，单次 `glyphPath` 前后取 `getUsedHeapSize()` + RSS；同时记录命令数 |
| 2 | 装载期 GSUB 四次解析是装载耗时主要项 | `f_svg/src/SvgTrueTypeFont.cj:272` | 装载自耗时占比 | `cjprof record` 加载 100 个真实字体（含大 GSUB 的 CJK 字体），对比注释掉三次多余解析的耗时 |
| 3 | `SvgComputedStyle.vectorEffects()` 每次调用重建数组是渲染热点 | `f_svg/src/SvgComputedStyle.cj:387` + `SvgRenderTree.cj:1217` / `:1897` | 每命令调用次数与自耗时 | 渲染 10k 个带 `vector-effect` 的元素，`cjprof` 看分配量与自耗时；或加计数器统计调用次数 |
| 4 | `ligatureAt` 每次重映射整段码点是长 run 的 O(n²) 热点 | `f_svg/src/SvgTrueTypeFont.cj:413` + `SvgTextRenderer.cj:1836` | 单 run 4000 字符的排版耗时曲线（n / 2n 对比） | 单 `<text>` 放 1000/2000/4000 字符拉丁文本，计时 `SvgRenderTreeBuilder.build`，看是否随 n² 增长 |
| 5 | `SvgVectorEffect` 静态属性每次访问都新建对象带来可观分配 | `f_svg/src/SvgVectorEffect.cj:33` | 访问次数与分配量 | `cjprof heap` 或 `getAllocatedHeapSize()` 对照「静态常量缓存」改前改后（同文档渲染 100 次） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgTransformPathM5_test.cj` | .cj | ✅ | 测试；覆盖 clip/mask/marker/getCTM 与 `transform-origin` 一致性，未发现断言与实现契约冲突 |
| 2 | `f_svg/src/SvgTransform_test.cj` | .cj | ✅ | 测试；解析/序列化/非法输入用例完整 |
| 3 | `f_svg/src/SvgTrueTypeFont.cj` | .cj | ✅ | 主要缺陷与重复逻辑来源，见发现 1–9、11、15 |
| 4 | `f_svg/src/SvgTrueTypeM4_test.cj` | .cj | ✅ | 测试 + TTF 构造工具（`M4ByteWriter` / `m4BuildTtf`），断言与实现一致 |
| 5 | `f_svg/src/SvgTrueTypeTables.cj` | .cj | ✅ | 表目录与读取器，越界校验完整；无死代码 |
| 6 | `f_svg/src/SvgTrueTypeTables_test.cj` | .cj | ✅ | 测试；截断/上限/非 ASCII tag 覆盖到位 |
| 7 | `f_svg/src/SvgTspan.cj` | .cj | ✅ | 23 行，仅构造器；`SvgTag.cj:32` 与多处测试引用 |
| 8 | `f_svg/src/SvgUnknownElement.cj` | .cj | ✅ | `rawName` 与基类 `rawQName` 存同一值（信息冗余，未单列问题） |
| 9 | `f_svg/src/SvgUse.cj` | .cj | ✅ | 与 `SvgImage` 逐行重复，见发现 7 |
| 10 | `f_svg/src/SvgUse_test.cj` | .cj | ✅ | 含 `SvgImage_test`，文件归属错位见发现 13 |
| 11 | `f_svg/src/SvgValueTypesM3_test.cj` | .cj | ✅ | 测试；枚举/选项默认值断言 |
| 12 | `f_svg/src/SvgValueTypesM4_test.cj` | .cj | ✅ | 测试；文本与滤镜枚举解析/回退 |
| 13 | `f_svg/src/SvgVectorEffect.cj` | .cj | ✅ | 值类型 + `strokeScale`；发现 9、12 |
| 14 | `f_svg/src/SvgVectorEffect2.cj` | .cj | ✅ | 矩阵修正；发现 6、10 |
| 15 | `f_svg/src/SvgVectorEffectM4_test.cj` | .cj | ✅ | 测试；`non-scaling-stroke` 与奇异 CTM 回退覆盖 |
| 16 | `f_svg/src/SvgVectorEffectMultiM6_test.cj` | .cj | ✅ | 测试；多值顺序无关性与渲染树接线 |
| 17 | `f_svg/src/SvgView.cj` | .cj | ✅ | `viewBox` / `preserveAspectRatio` 样板复制见发现 7 |
| 18 | `f_svg/src/SvgViewBox.cj` | .cj | ✅ | 发现 11 |
| 19 | `f_svg/src/SvgViewBox_test.cj` | .cj | ✅ | 测试；非法输入与往返序列化 |
| 20 | `f_svg/src/SvgViewState2.cj` | .cj | ✅ | 32 行；缩放/平移矩阵，文件名错位见发现 13 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分风险集中在 `SvgTrueTypeFont` 这条「不可信二进制 → 路径命令」的链路上：结构校验（表长、偏移、`loca` 单调、`endPts` 递增、深度上限）做得相当扎实，测试也覆盖了截断、非单调、超限与自引用字形；缺口在**资源总量**和**语义校验**两层——复合字形可以按数量级放大命令数（唯一严重项，建议优先修），`load` 缺文件级上限，cmap 的值域、`0 = 缺失`、platform 选择、`endCode` 单调都没校验，坏字体因此会在渲染期抛异常或静默画错字形。`SvgVectorEffect2` 的矩阵分解在镜像/切变组合下会给出近似甚至错误结果，属可排期的正确性修复。

另一半问题是重复：`SvgUse` 与 `SvgImage`、`viewBox` / `preserveAspectRatio` 在四个元素类里逐字复制，`advance` / `glyphPath` / `scaleTtfCommand` / `loca` 解码各有第二份实现，`vector-effect` 名称表散落四处且靠 `toString()` 分派。这些不改变当前行为，但任何一处修复都会漂移，建议与下一次功能改动合并收敛，不必单独排期。

存量缺陷共 14 条（严重 1 / 一般 7 / 轻微 6），是否纳入修复待用户决定。性能与内存方面的两条方案均无基线，只能作为下一轮补数据的候选。
