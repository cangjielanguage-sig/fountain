# f_svg 模块审查报告（第 10/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个文件，全部 `.cj`；模块整体 301 个 `.cj` + 141 个 `.md` = 442 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比）⇒ 所有问题来源记「存量」
- **审查重点**：CSS 解析/序列化的边界与栈深度、解析覆盖率光栅化（含 local mode 的 OOM 面）、动画属性与时间契约、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块第 10/26 部分，只覆盖 `files/f_svg.part10.txt` 的 20 个 `.cj`；与同模块其它部分同源问题请在合并时按根因归并）

> 本部分 8 个生产文件（`CssStyleSheet.cj` / `CssVariables.cj` / `SvgAnalyticRasterizer.cj` / `SvgAnchor.cj` / `SvgAnimate.cj` / `SvgAnimateMotion.cj` / `SvgAnimateTransform.cj` / `SvgAnimation.cj`）+ 12 个测试文件。追调用链读到的范围外文件有 `SvgRasterizer.cj`、`SvgBitmap.cj`、`SvgTimeline.cj`、`SvgBegin.cj`、`SvgElement.cj`、`docs/LocalMode.md`、`f_svg/doc/spec/local-mode-f-svg-analytic-coverage/design.md`，只作取证，不计入本部分覆盖。

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 行内两两求交（O(A²)）与逐子区间重建 `hits` 是解析档的主要 CPU 面 | `f_svg/src/SvgAnalyticRasterizer.cj:252-267`、`291-300` | 该循环自耗时占比 | `cjprof record` 跑 1000×1000 圆与 1000 段折线各 200 次，看 `accumulateAnalyticRow` 自耗时占比 |
| 2 | 逐列 `ArrayList` 分配主导解析档的 GC 压力 | `f_svg/src/SvgAnalyticRasterizer.cj:377`、`351-352` | 每次 fill 的分配量与 GC 次数 | 同几何对比 `getAllocatedHeapSize()` 与 `cjprof heap` 分配热点 |
| 3 | ≤8 MiB 的 local 档对峰值 RSS 的实际收益（1024² 恰好走 local、1025² 走堆） | `f_svg/src/SvgAnalyticRasterizer.cj:93-97`、`200-204` | 两档峰值 RSS / `getUsedHeapSize()` 对照 | 同图两档各渲染 50 次取峰值；`docs/LocalMode.md` 只有 2048² 的回退数据 |
| 4 | 样式表全量 token 物化在大 CSS 上成为峰值主因 | `f_svg/src/CssStyleSheet.cj:170`（`CssLexer(text).tokenize()`） | token 数与字节比、峰值 RSS | 10k / 100k 条规则的 CSS 各跑一次，记 token 数与 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/CssSelectorSiblingM5_test.cj` | .cj | ✅ | 相邻/一般兄弟组合符、文本节点穿插、跨父不匹配；`m5GroupOf` 定义在结构伪类测试文件，引用正常 |
| 2 | `f_svg/src/CssSelectorSpecificityM5_test.cj` | .cj | ✅ | 特异性基准值、属性运算符、`@`否定、分组取最高值；断言与 `CssRule.specificity`（`CssStyleSheet.cj:68-76`）一致 |
| 3 | `f_svg/src/CssSelectorStructuralM5_test.cj` | .cj | ✅ | `:first/last/only-child` / `:root` / `:empty`；`m5GroupOf` 定义处 |
| 4 | `f_svg/src/CssSelector_test.cj` | .cj | ✅ | 基本选择器、组合符、倒排索引候选；`selectorMatches` / `classedShape` 两个 internal helper 仅本文件使用，无外泄 |
| 5 | `f_svg/src/CssStyleSheet.cj` | .cj | ✅ | 见发现 1（`@media` 互递归）、发现 3（序列化丢 at-rule）；`@import` 跳过与 `!important` 拆分核对无误 |
| 6 | `f_svg/src/CssStyleSheet_test.cj` | .cj | ✅ | 容错解析六组用例；未覆盖 `@font-face` / `@color-profile` 往返（发现 3） |
| 7 | `f_svg/src/CssVariables.cj` | .cj | ✅ | `var()` 展开：`depth >= 8` 截断 + `visited` 环检测，两条独立上界，递归有界；`unsafeBytes` 来自 `f_base`（`ExtendString`/`UnsafeBytes`），import 必要 |
| 8 | `f_svg/src/CssVariablesM5_test.cj` | .cj | ✅ | 替换/继承/fallback/大小写；用例覆盖与实现一致 |
| 9 | `f_svg/src/CssVariablesNegativeM5_test.cj` | .cj | ✅ | 环、8/9 层边界、非法名、展开器直接调用；`m5VariableChain(8)` 正好 8 层，与 `CSS_VAR_MAX_DEPTH` 边界一致 |
| 10 | `f_svg/src/SvgAnalyticLocalMode_test.cj` | .cj | ✅ | 门限常量与边界、local/heap 逐元素等价、0/负尺寸；`localModeCirclePath` 与 `polygonCirclePath` 重复但注释已说明意图（测试隔离），不判 |
| 11 | `f_svg/src/SvgAnalyticRasterizer.cj` | .cj | ✅ | 见发现 4（16 B/px 整幅）、发现 5（事件无上限 + 无回退）、发现 6/8（重复实现）；覆盖率积分（分段梯形）逐段核对为精确 |
| 12 | `f_svg/src/SvgAnalyticRasterizer_test.cj` | .cj | ✅ | 守恒、64× 参考图、细条、自交；见发现 7（6 份比较循环） |
| 13 | `f_svg/src/SvgAnchor.cj` | .cj | ✅ | 33 行只读 DTO（`SvgDocument.cj:142-151` 消费），`internal init`，无缺陷 |
| 14 | `f_svg/src/SvgAnimate.cj` | .cj | ✅ | 15 组属性访问器 + 4 个枚举拼写 helper；getter 走 `attr`、setter 走 `writeOptionalAttribute`，未知值原样保留，与注释一致 |
| 15 | `f_svg/src/SvgAnimateM7_test.cj` | .cj | ✅ | 属性映射、往返、`mpath` 替换、`set` 属性原位替换；`SvgBegin` 的列表形态在此固化（发现 2 的证据源） |
| 16 | `f_svg/src/SvgAnimateMotion.cj` | .cj | ✅ | `rotate` getter 兜底 `Auto` 与注释一致；`mpath` 先收集后删除，无迭代中修改 |
| 17 | `f_svg/src/SvgAnimateTransform.cj` | .cj | ✅ | 53 行；`type` 未知值回退 `Translate` 已在注释说明 |
| 18 | `f_svg/src/SvgAnimation.cj` | .cj | ✅ | 见发现 2（时间列表/offset 读不回）、发现 10（过期注释）；`ms`/`s` 单位识别的大小写与长度边界已核对 |
| 19 | `f_svg/src/SvgAnimationControlM6_test.cj` | .cj | ✅ | 时间源、pause/unpause、事件触发、min/max、discard；用例与 `SvgTimeline` 行为一致 |
| 20 | `f_svg/src/SvgAnimation_test.cj` | .cj | ✅ | 四类动画、时间解析、repeat/fill、五种 transform、paced、keyPoints、深拷贝、limits；10001 values / 64 层 mpath 硬上限在 `SvgTimeline` 侧（本部分外，未展开） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分覆盖 `f_svg` 的「CSS 解析 + 解析覆盖率光栅化 + 类型化动画元素」三条线，8 个生产文件。整体质量偏上：解析器普遍采用「容错 + 告警」而不是抛异常，`var()` 展开有深度与环双重上界并有用例固化，local mode 改造把门限判断写成除法形式避免 `width*height` 溢出，还用 `analyticCoverageImpl(useLocal)` 给 local/堆两条路径做了逐元素等价断言——这些说明作者对边界有明确意识。解析覆盖率的积分算法（按顶点/交点分段 → 每段内边次序不变 → `∫clamp` 梯形）逐段核对正确，没有发现数值错误。

需要排期的：

- **阻塞项**：发现 1，嵌套 `@media` 的互递归没有任何深度约束。它不依赖业务输入，一段刻意嵌套的 CSS 就能把栈打穿，而入口正对不可信的 `<style>` 文本与内联 `style`。修法很小（加 `depth` 形参 + 复用现有 `skipCssAtRuleWithin`），但必须连测试一起补。
- **契约面两条**：发现 2（`SvgBegin` 写出的 `0s; a.end+1s` / `a.repeat(2)` 读不回来，链式 `begin` 被当成 0）与发现 3（`toString` 丢 `@font-face`/`@color-profile`）都是「库自己产出的东西自己消费不了」，对把 `f_svg` 当无损 DOM 或做 SMIL 播放的下游最痛，建议一起修并补往返用例。
- **资源面两条**：发现 4（整幅 16 B/px，默认 `maxPixels` 下单次 fill ≈1.0 GiB）与发现 5（`events` 按边数平方增长、强制 local、无回退）。前者有 `maxPixels` 兜底，属于「默认配置下的峰值过高」；后者的最坏输入不在 `maxPixels` 的管辖范围内，建议按「先给上界（`SvgErrorKind.Limit`）、再谈回退」的顺序处理。
- **可维护性**：发现 6～8 是重复实现。三份插入排序里 `@ local!` 那份无法泛型化必须留，其余两份可用 `std.sort`；测试里 6 份比较循环可抽一个断言 helper。发现 9、10 是两条「静默」：单参 `parse` 丢诊断、过期注释误导读者，改起来都是一行。

性能与内存方面本部分**没有任何测量数据**（无 `cjprof` / `cjpm bench` 基线），因此三条优化方案与四条待验证假设都不进修复清单。最值得先补数据的是「行内全点对求交」与「逐列 `ArrayList` 分配」——两者同时影响 CPU 与 GC，且替代算法明确（扫描线、内联分段），基线一成就是纯收益。

已确认**没有**的问题：数据竞争与死锁（本部分无锁、无线程间共享可变状态）、XML 注入（属性经 `escapeSvgAttribute`，CSS 文本未接进 XML 写入路径）、`var()` 无界递归（深度 + 环双重限制）、对外可达 `public` 的死代码（一律按契约保留）。

存量缺陷共 10 条（严重 1 / 一般 4 / 轻微 5），全部为存量，是否纳入修复待用户决定；本报告只读代码，未做任何修改，未跑构建。

> 范围外提示（不计入统计）：`SvgBitmap` 的 `maxPixels` 默认 64 Mi px（`f_svg/src/SvgBitmap.cj:230`）、`SvgTimeline` 的 `values` 10001 / mpath 64 层硬上限、`SvgBegin` 的工厂方法集合，均属其它部分；`docs/LocalMode.md`、`f_svg/doc/spec/**` 只用于取证，未按 §13 审查。
