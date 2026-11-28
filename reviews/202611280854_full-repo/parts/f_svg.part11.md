# f_svg 模块审查报告

> **模块第 11/26 部分**（本报告只覆盖 `files/f_svg.part11.txt` 列出的 20 个文件：`SvgAttribute` → `SvgBounds`，含 10 个 `*.cj` 与 10 个 `*_test.cj`；本部分不含 `.md`。其余 25 部分由主 Agent 顺序调度，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个源文件）
- **基线**：工作区快照（`HEAD f309f0b`，源码无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：SVG 序列化 / 转义边界、OOM（按不可信长度预分配）、栈溢出与递归、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 11/26 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SvgBitmap.blend` 在超采样渲染中占显著自耗时 | `f_svg/src/SvgBitmap.cj:143-161` | self time 占比、每像素调用次数 | `cjprof record` 跑 1024×1024 / 50 形状 / `samplesPerPixel=4`，看 `blend` 与 `quantizeSvgChannel` 的 self time |
| 2 | `SvgClipMask.composite` 的逐像素 `pixel()` + `setPixel()` 双份坐标校验构成混合模式热点 | `f_svg/src/SvgClipMask.cj:187-207`（依赖本部分 `blendSvgRgba`） | 该循环占整文档渲染的耗时比例 | 同一 profile 看 `composite` 累计时间；或分段计时跑 `multiplyAppliesOnce` 场景放大到 1024×1024 |
| 3 | `SvgBitmap.fill` 逐字节写比批量填充慢 | `f_svg/src/SvgBitmap.cj:127-140` | 大图 fill 单次耗时 | 1024×1024 / 4096×4096 各 1000 次 `fill` 的 `cjpm bench -O2` 对照 |
| 4 | `svgBidiVisualOrder` 的「按层级多趟扫描」在长文本上放大 | `f_svg/src/SvgBidi.cj:318-356` | 文本长度分布与单次耗时 | 10k/100k 字符 RTL 混合串跑 `cjprof`，对照 `TextRenderer` 整体耗时 |
| 5 | `SvgBuilder.save(path)` 的 `String + Array<Byte>` 双副本是文档保存的峰值来源 | `f_svg/src/SvgAuthoringBuilder.cj:66-72` | 峰值 heapUsed / RSS 与输出体积之比 | 50 MB 级文档连续保存 10 次，采样 `getAllocatedHeapSize()` 峰值 |
| 6 | auto 尺寸场景下 `svgBBoxOf` 是热点（整树遍历 + 样式查询） | `f_svg/src/SvgAutoSize.cj:46-51` | 自耗时占比、文档元素数 | `cjprof record` 渲染 5k 元素 `width="auto"` 文档，看 bbox 相关函数占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgAttribute.cj` | .cj | ✅ | 见 #5（未转义 `toString`） |
| 2 | `f_svg/src/SvgAuthoringBuilder.cj` | .cj | ✅ | 见 #7；`save(file:)` 的 `catch (FSException)` 已核实正确（`stdlib/libs/std/fs/file.cj:284-294` 明确 `@throws FSException`），不计问题 |
| 3 | `f_svg/src/SvgAuthoringTypes.cj` | .cj | ✅ | 4 个枚举的 `==` / `toString` 与 SVG 拼写一致（`whenNotActive` / `auto-reverse` 正确） |
| 4 | `f_svg/src/SvgAuthoringTypesM7_test.cj` | .cj | ✅ | 覆盖 4 枚举拼写与带载荷相等性，无遗漏取值 |
| 5 | `f_svg/src/SvgAutoSize.cj` | .cj | ✅ | 见 #1 / #3 / #13 / #14；`fallbackAutoSize` 有调用者 |
| 6 | `f_svg/src/SvgAutoSizeM6_test.cj` | .cj | ✅ | 双轴/单轴/缺省/嵌套/显式五条路径有断言，但缺「auto + 显式另一轴 + 空内容」（#1） |
| 7 | `f_svg/src/SvgBBoxM5_test.cj` | .cj | ✅ | 9 个用例覆盖 clipped、hidden、use 环、use→symbol、transform-origin、mediaWidth、CTM、absoluteBounds |
| 8 | `f_svg/src/SvgBegin.cj` | .cj | ✅ | `after` 的零偏移/负偏移符号处理正确；`-0.0` 由 `formatSvgNumber` 归零 |
| 9 | `f_svg/src/SvgBeginM7_test.cj` | .cj | ✅ | 覆盖 join 不可变性（`69-75` 是关键断言） |
| 10 | `f_svg/src/SvgBenchmarkM4_test.cj` | .cj | ✅ | 见 #12（基准混入 `@Test`） |
| 11 | `f_svg/src/SvgBenchmark_test.cj` | .cj | ✅ | 见 #12；另含 3 个 M3 基准类 |
| 12 | `f_svg/src/SvgBidi.cj` | .cj | ✅ | 见 #2 / #8；`strongBidiClass` / `reverseBidiRange` 有调用者 |
| 13 | `f_svg/src/SvgBidiM5_test.cj` | .cj | ✅ | 缺 `0xFB50` / `0xFE70` / `0x0750` 分类用例（见 #2 建议） |
| 14 | `f_svg/src/SvgBitmap.cj` | .cj | ✅ | 见 #4 / #6 / #9 / #11；`quantizeSvgChannel` 有 6 处调用（含 `toColor` 内 3 处） |
| 15 | `f_svg/src/SvgBitmap_test.cj` | .cj | ✅ | 覆盖尺寸/初值/越界/填充/预乘合成/选项校验 |
| 16 | `f_svg/src/SvgBlend.cj` | .cj | ✅ | 12 种可分离混合公式与 CSS Compositing 一致；见 #8 / #10 |
| 17 | `f_svg/src/SvgBlendLayerM5_test.cj` | .cj | ✅ | 覆盖分层、multiply、isolation、滤镜+裁剪+混合顺序与逐字节稳定性 |
| 18 | `f_svg/src/SvgBlendM5_test.cj` | .cj | ✅ | 12 值往返 + 旧 `SvgBlendMode` 不变 |
| 19 | `f_svg/src/SvgBlendPixelsM5_test.cj` | .cj | ✅ | 覆盖 normal/over 等价、各模式关键点、透明两侧、钳制 |
| 20 | `f_svg/src/SvgBounds.cj` | .cj | ✅ | 空哨兵负尺寸、并集/交集/四角变换/inflate 语义自洽，无越界 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_svg.part11.txt` 的 20 行一一对应）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分 20 个文件没有阻塞项：没有栈溢出路径，没有并发共享，没有吞异常的空实现，序列化的值侧转义链路（`SvgBuilder` → `SvgElement.toXmlElement` → `f_xml Escaper`）完整且严格。

需要排期的是三条**一般**级问题，全部集中在 auto 尺寸与字符分类两个对外能力上：(1) `SvgAutoSize` 的回退分支把已确定的另一轴覆盖成 300/150，`<svg width="auto" height="40">` 会得到 150 的高度，且 warning 文案与事实不符（可稳定复现，现有用例未覆盖该组合）；(2) `svgBidiClass` 里那段恒不可达的 AL 分支掩盖了阿拉伯补充区（`0x0750-0x077F`、`0x08A0-0x08FF` 落到默认 `L`）与表现形式区（`0xFB50-0xFDFF`、`0xFE70-0xFEFF` 落到 `R`）的误分类，且测试只断言了 `0x627`；(3) 内容包围盒用 fallback 视口而非已解析视口（需先确认百分比解析口径，若确认则同属尺寸错误）。

质量偏好的是数值与合成核心：`SvgBlend` 的 12 种可分离模式与 CSS Compositing 逐条对得上，`SvgBounds` 的空盒哨兵/并交/四角变换语义自洽，`SvgBitmap.blend` 的预乘-反预乘闭环正确，`SvgBegin.after` 也处理了 `-0.0`。技术债主要在**重复表达**：四个 `fromName`、三处 `/255.0 * alpha` 预乘换算、两套「读像素→混合→写回」流程、散落 6 处的 300×150 默认视口——目前一致，但任何单点修改都会造成难查的偏色或视口漂移。

测试侧的问题是结构性的：`SvgBenchmark*.cj` 用 `println` 计时却挂在常规 `@Test` 里，`cjpm test` 每次跑 20 万次字形解析与多次 1024² 渲染，产出的数字因 `-O0` 又不能用。本部分性能结论一律未成立，疑似热点放在「待验证假设」，等 `cjprof` / `cjpm bench -O2` 数据再定。

存量缺陷 14 条（3 一般 + 11 轻微），是否纳入修复待用户决定；其中 #1 与 #2 建议优先，#3 需先补一次规格确认。
