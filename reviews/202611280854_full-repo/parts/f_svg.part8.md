# f_svg 模块审查报告（第 8/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 18 个文件：1 个 `.cj` + 17 个 `.md`；模块整体 301 个 `.cj` + 141 个 `.md`）
- **部分**：模块第 **8/26** 部分（本文件只是分报告，最终模块报告由主 Agent 合并）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；本部分无 diff，全部问题记「存量」）
- **审查重点**：SVG 解析 / 序列化正确性与 XML 边界、注入与转义、OOM、递归与栈溢出、死代码、重复逻辑、存量 BUG。本部分只有 `CssCalc.cj` 一份源码（`calc()` 求值器，服务于 M5 计算样式），其余 17 份是 M7 生成侧、M1 模型/安全/值类型、local mode 解析覆盖率的规格与校验记录，因此专项落在「`calc()` 递归与数值边界」以及「规格承诺 ↔ 实现 ↔ 自验记录」三方一致性。
- **报告版本**：v1

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `calc()` 求值在「样式表含大量 `calc()`」的文档里占计算样式耗时的显著比例（>10%） | `f_svg/src/CssCalc.cj:55-65`（入口）、`f_svg/src/SvgStyleResolver.cj:536` | 自耗时占比、调用次数、输入规模 | `cjprof record` 跑一份 1 万个 `calc()` 声明的文档，`cjprof report` 看 `evaluateCssCalc` / `parsePrimary` self time |
| 2 | `CssCalcValue` 的短命对象是 `SvgStyleResolver.compute` 的主要分配来源之一 | `f_svg/src/CssCalc.cj:39-47` | 分配字节占比、GC 次数 | 基准进程内 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，同一输入改 `struct` 前后对照 |
| 3 | 一元符号递归的崩溃阈值在 5 万～20 万层之间（决定该缺陷在真实上传场景的触发成本） | `f_svg/src/CssCalc.cj:163-177` | 默认线程栈大小与实际崩溃层数 | 单独可执行程序二分 `K`（`calc(` + K 个 `-` + `1px)`），记录首次崩溃的 K 与线程栈配置；平台栈大小以官方文档为准 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/spec/add-f-svg-m7/proposal.md` | .md | ✅ | 见「轻微」发现：`:13` 的 `kind: Io` 与实现/spec 相反 |
| 2 | `f_svg/doc/spec/add-f-svg-m7/specs/svg-authoring/spec.md` | .md | ✅ | 11 条 Requirement；`SvgTag` 五个动画标签未注册（`f_svg/src/SvgTag.cj:79-93` 表内无 animate 系列）、`save` 失败 `InvalidValue`（`SvgAuthoringBuilder.cj:66-70`）均与代码一致；`:32` 游标措辞与实现不符（见发现） |
| 3 | `f_svg/doc/spec/add-f-svg-m7/tasks.md` | .md | ✅ | 全部 `[x]`；已裁决偏差（D1 文件名、D9 错误 kind）与实现一致；`:4` 分支名与 `:10` 互斥（见发现） |
| 4 | `f_svg/doc/spec/add-f-svg-m7/verification.md` | .md | ✅ | 终态记录（1226 / W-5 已修，且 `SvgBuilderM7_test.cj:592-605` 断言与之一致）；与 `verify-report.md` 口径冲突见发现 |
| 5 | `f_svg/doc/spec/add-f-svg-m7/verify-report.md` | .md | ✅ | 修复前快照（1225 / W-5 开放），缺「已过期」标注 |
| 6 | `f_svg/doc/spec/add-f-svg-module/design.md` | .md | ✅ | M1 设计；D2 缓存、D5 上限、D6 数值规范与当前实现一致（`formatSvgNumber` 规则见 `f_svg/src/SvgNumber.cj:24-49`）；D11 是文件布局表而非代码行号，属归档设计，不作问题 |
| 7 | `f_svg/doc/spec/add-f-svg-module/fix-plan.md` | .md | ✅ | 修复计划；C-1/C-2/W-3.x 各条均能在 `verification.md:413-441` 找到对应「已修复」结论，闭环 |
| 8 | `f_svg/doc/spec/add-f-svg-module/proposal.md` | .md | ✅ | 安全策略、五个解析入口、错误 kind 五种与实现一致 |
| 9 | `f_svg/doc/spec/add-f-svg-module/specs/svg-document-model/spec.md` | .md | ✅ | `elementsByTag` 只返回后代、属性原位替换、`elementPath` 形态与 `SvgElement` / `SvgDocument` 现状一致 |
| 10 | `f_svg/doc/spec/add-f-svg-module/specs/svg-security/spec.md` | .md | ✅ | `maxElements=1_000_000` / `maxDepth=512` 与 `SvgOptions.cj:65-66` 一致；放行开关作用域与 `SvgBuilder` 现状一致（外部引用细节由 part7 覆盖） |
| 11 | `f_svg/doc/spec/add-f-svg-module/specs/svg-value-types/spec.md` | .md | ✅ | `formatSvgNumber` 规则（`:182`）与 `SvgNumber.cj:32-49` 逐条一致；往返契约已按 C-2 收窄为「规范形式可表示」 |
| 12 | `f_svg/doc/spec/add-f-svg-module/tasks.md` | .md | ✅ | 全 `[x]`；17.8 性能目标已标注「参考值、非门禁」，与 `verification.md:430` 一致 |
| 13 | `f_svg/doc/spec/add-f-svg-module/verification.md` | .md | ✅ | 实为 M1 校验报告（189→216 passed）、修复结果表逐条可回溯；`:447` 自述 `openspec validate` 未执行，属留白未虚报，记信息不记问题 |
| 14 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/design.md` | .md | ✅ | 门限常量、`@ local?` / `exclave` 设计与 `SvgAnalyticRasterizer.cj:82-97` 逐字一致；`:5-8` 行号偏移见发现 |
| 15 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/proposal.md` | .md | ✅ | 8 MiB 门限、除法判定、`events` 固定 local 的设计动机与实现一致 |
| 16 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/specs/svg-rasterization/spec.md` | .md | ✅ | 六条 Scenario 均能在 `SvgAnalyticLocalMode_test` / 既有快照用例找到对应断言（tasks 5.1-5.5 记录） |
| 17 | `f_svg/doc/spec/local-mode-f-svg-analytic-coverage/tasks.md` | .md | ✅ | 0.1 探针结论（`ArrayList<T> @ local?` 无变更重载）与 D3 一致；7.3 记录 1242/1242 |
| 18 | `f_svg/src/CssCalc.cj` | .cj | ✅ | 267 行；死代码 2 处、重复逻辑 2 组、栈溢出 1 处、有限性守卫缺失 1 处，均见「发现」 |

合计：`.cj` 1 个 / `.md` 17 个 / 共 18 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 1 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分 17 个 `.md` 是 M1（模块骨架与值类型）、M7（生成侧 API）、local-mode 三份归档变更的规格与验收记录，整体质量偏高：Requirement 与实现能逐条对上，两处设计偏差（D1 文件名冲突、D9 错误 kind）都被规格吸收并留了书面裁决，local-mode 的门限常量与除法谓词和文档给的代码片段逐字一致。文档层面的问题集中在记录卫生：M7 的 `verify-report.md` 停在修复前（1225/38、W-5 开放），与 `verification.md`（1226/39、W-5 已修）差一条用例，`tasks.md` 还自带两个互斥分支名，且 proposal 的 `kind: Io` 与 spec/tasks 相反——都属于「读者按哪份文件办事会走错」的偏差，改动量都在一两行。

代码只有一份 `CssCalc.cj`（267 行），结构清楚（表达式/项/一元/原子四层下降，单位与百分比在叶子归一），除零、单位混用、括号深度、尾随垃圾这些常见边界都处理了，也有对应用例。阻塞项只有一处：**括号深度被限制为 16，一元 `+`/`-` 递归却完全没有上限**，而入口正是不可信文档的 `style`/`<style>` 文本——几十 KB 的连写符号即可把解析器推到栈溢出，这类崩溃不可捕获，属「一个属性值打掉进程」的量级，建议优先修（改成循环或复用 `depth` 计数都只要几行）。其次是 `em` / `%` 换算与乘除漏了加法分支已有的有限性校验，溢出时抛 `SvgException` 而不是返回 `None`，绕过了样式层联为 `None` 准备的「记 warning 并回退初始值」路径；它的结构性原因是 `parseExpression` 与 `parseTerm` 两份同构循环，修的时候把有限性/单位一致性收敛到一个出口更稳。

其余（不可达语句、单位序列化重复、spec 措辞与行号）属可读性与维护性，可随上述修复一起处理。性能方向的两条建议（`CssCalcValue` 改值类型、数字叶子复用单遍扫描器）都没有改前基线，只作为待验证假设留给下一轮补数据。存量缺陷 9 条，是否纳入修复待用户决定。
