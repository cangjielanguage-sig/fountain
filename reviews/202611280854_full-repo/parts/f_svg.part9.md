# f_svg 模块审查报告（第 9/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个文件：20 个 `.cj` + 0 个 `.md`；模块整体 301 个 `.cj` + 141 个 `.md`）
- **部分**：模块第 **9/26** 部分（本文件只是分报告，最终模块报告由主 Agent 合并）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；本部分无 diff，全部问题记「存量」）
- **审查重点**：SVG 解析 / 序列化正确性与 XML 边界、注入与转义、OOM、递归与栈溢出、死代码、重复逻辑、存量 BUG。本部分全部是 CSS 词法（`CssLexer.cj`）、媒体查询（`CssMedia.cj`）、选择器解析与匹配（`CssSelector.cj` / `CssSelector2.cj`）以及 15 个 M5/M6 用例文件，另有 1 个空壳 `CssParser.cj`。因此专项落在「选择器 / 媒体查询解析对不可信文本的边界」与「调用方（`SvgStyleResolver`）只按部分选择器建桶导致的漏匹配」。
- **报告版本**：v1

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `byClass` 全键扫描是 `candidates` 的主要成本（类选择器 >100 条、元素 >1 万时） | `f_svg/src/CssSelector.cj:434-442` | `candidates` 自耗时占比、每元素平均类键比较次数 | `cjprof record` 跑 1 万元素 × 200 条类选择器文档，`cjprof report` 看 `candidates` / `cssClassListContains` self time |
| 2 | 候选取集是 `SvgStyleResolver.compute` 的主要分配来源之一 | `f_svg/src/CssSelector.cj:423-424` | 分配字节占比、GC 次数 | 基准进程 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，改复用缓冲前后对照 |
| 3 | 空白 token 合并的字符串拼接在「大量注释分隔空白」的样式表上是 O(k²) 复制 | `f_svg/src/CssLexer.cj:133-142` | k（空白组数）与单次 `tokenize` 耗时曲线 | 构造 `a /*c*/ /*c*/ … b`（k = 1e3 / 1e4 / 1e5）测 `tokenize` 耗时，看是否随 k 超线性 |
| 4 | 256 段通配后代选择器的实际挂死阈值（多少段 × 多少层开始不可接受） | `f_svg/src/CssSelector.cj:285-297` | 实际耗时随 (段数, 深度) 的增长曲线 | 固定 128 层嵌套文档，段数从 8 递增到 32，测单次 `matches` 耗时，找拐点 |

## 文件覆盖

> 与 `{workdir}/files/f_svg.part9.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/CssCalcM5_test.cj` | .cj | ✅ | 9 个 `calc()` 用例；`:22-28` 定义跨文件复用的 `m5StyleWith`（被 `CssCalcPropertyM5_test.cj` 依赖，测试间耦合，不作问题） |
| 2 | `f_svg/src/CssCalcPropertyM5_test.cj` | .cj | ✅ | 6 个属性级 `calc()` 用例；`font-size` 用父字号换算的断言与实现一致 |
| 3 | `f_svg/src/CssComboM5_test.cj` | .cj | ✅ | 组合特性 + 渲染确定性；`:60-68` 两次渲染逐字节比对 |
| 4 | `f_svg/src/CssFontAliasM5_test.cj` | .cj | ✅ | `@font-face` 别名 9 例；`M5FixedAdvanceFont` 的 `public func` 均为 `SvgFont` 接口实现，按硬原则不算死代码 |
| 5 | `f_svg/src/CssFontFaceM5_test.cj` | .cj | ✅ | 5 例；`sheet.rules.size == 0` 与 warning 计数口径自洽 |
| 6 | `f_svg/src/CssGeometryCalcM5_test.cj` | .cj | ✅ | 5 例；`renderUsesComputedWidth` 用像素 alpha 断言几何宽度，覆盖渲染链路 |
| 7 | `f_svg/src/CssInteractionM6_test.cj` | .cj | ✅ | 6 例；`:44-50` 固定「伪类计入类型列」的特异性口径，与 `doc/f_svg-M5设计.md:91` 一致（与 CSS 规范不同，属文档化取舍，不报） |
| 8 | `f_svg/src/CssLexer.cj` | .cj | ✅ | 469 行；死代码 0、转义/码点边界 1 处（一般）、空白合并的 O(k²) 进待验证 #3 |
| 9 | `f_svg/src/CssLexer_test.cj` | .cj | ✅ | 6 例；`:68-74` 断言转义在词法层保留，与选择器层口径冲突处已并入「一般」发现 |
| 10 | `f_svg/src/CssMedia.cj` | .cj | ✅ | 239 行；`toString` 循环内物化 1 处（轻微），其余边界（空查询、缺右括号、`px` 后缀、负值/`Inf`）均已核对无缺陷 |
| 11 | `f_svg/src/CssMediaM5_test.cj` | .cj | ✅ | 9 例；`m5RuleMatches` 为测试侧复述 `rule.media.matches`，属测试准备代码不作问题 |
| 12 | `f_svg/src/CssMediaWidthM5_test.cj` | .cj | ✅ | 6 例；覆盖「compute 宽度 → 渲染选项宽度 → 根宽度 → 默认 300」四级回退 |
| 13 | `f_svg/src/CssParser.cj` | .cj | ✅ | 3 行空壳、缺版权头（一般，见发现） |
| 14 | `f_svg/src/CssSelector.cj` | .cj | ✅ | 483 行；索引漏分组（严重）、组合回溯（严重）、legacy 分支不可达、`while(true)` 尾部不可达、空白分词重复 |
| 15 | `f_svg/src/CssSelector2.cj` | .cj | ✅ | 926 行；属性值多字节崩溃（严重）、整数溢出（一般）、转义不解码（一般）、兄弟遍历同构、`Includes` 重复分词 |
| 16 | `f_svg/src/CssSelectorAttributeM5_test.cj` | .cj | ✅ | 7 例；`:120-140` 负向用例覆盖缺名/缺值/空值，缺「非 ASCII 值」样本（见严重项 #2 建议） |
| 17 | `f_svg/src/CssSelectorCascadeM5_test.cj` | .cj | ✅ | 8 例；`:116-128` 断言 README 示例选择器可解析可匹配；无分组（`a, b`）级联用例 |
| 18 | `f_svg/src/CssSelectorLimitM5_test.cj` | .cj | ✅ | 3 例；把 256 段后代链当作合法输入，是「组合爆炸」严重项的现实入口 |
| 19 | `f_svg/src/CssSelectorNotM5_test.cj` | .cj | ✅ | 4 例；嵌套 / 复合 / 空参数均被拒绝，与 `allowNot: false` 实现一致 |
| 20 | `f_svg/src/CssSelectorNthM5_test.cj` | .cj | ✅ | 5 例；`An+B` 正负系数、`odd/even`、`n` 全覆盖；缺数值溢出样本（见一般项 #4 建议） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分是 `f_svg` 的 CSS 前端：词法器本身写得克制（单遍、字节级、非法字符降级而不抛），媒体查询与 `An+B` 的边界也基本打磨过；风险集中在**「解析阶段判定的合法性」与「匹配阶段的数据结构假设」不一致**，三处严重问题都是这一类：

- **必须修（严重）**：① `CssSelectorIndex` 只用分组第一条选择器建桶，`rect, circle` 的第二条永远不生效——设计文档明确承诺过分组（`doc/f_svg-M2设计.md:84`），而现有 15 个测试文件没有一条把分组规则送进级联，属「静默丢样式」；② 属性选择器的引号值按字节切片，非 ASCII 值抛 `IllegalArgumentException`，绕过只捕 `SvgException` 的 `CssStyleSheet.parse`，一句 `[data-x="中文"]` 就能让整份文档不渲染；③ 后代组合符匹配没有记忆化，256 段选择器配 512 层嵌套（两个上限都是代码自己允许的）组合数为 `C(512,256)` 量级，一条 512 字节的通配选择器即可挂死进程。前两条的修法都很局部（遍历全部选择器建桶；用 `decodeCssIdent` 或按 `utf8Length` 步进），第三条需要加一张本次调用内的备忘表并单独收紧「后代段数」。
- **应当修（一般）**：`parseCssInteger` 溢出抛异常击穿「非法返回 `None`」，与 ② 同属「非 `SvgException` 穿透公开解析入口」；十六进制转义未排除代理区（`Rune()` 抛异常）；属性值与选择器 ident 不解码转义，导致 `[data-x="a\62 c"]` 静默不匹配，且与词法层「转义是受支持输入」的口径相反；`CssParser.cj` 的空壳 + 缺版权头（M2 验证记录已提过，未闭环）。
- **可排期（轻微）**：两套选择器表示并存留下的不可达分支、`while(true)` 尾部不可达、`cssAttributeMatches` 重复的 `case Exists`（不可达）、五个兄弟遍历函数同构（`LastChild` 双扫）、空白分词两份实现、`toString` 循环内物化——都是低风险清理。
- 优化侧：候选收集（全类键扫描 + 插入排序 + 每元素两个容器）与兄弟遍历是本部分最值得先 profile 的两处，但没有基线数据，全部按「无基线方案 / 待验证假设」记录，不进 `todo.md` / `tasks.md`。
- 测试侧观察：15 个用例文件组织清晰、负向用例密度高（属性选择器非法形式、`:not()` 嵌套、`An+B` 非法表达式各有整组断言），但**恰好缺三类样本**——分组选择器的级联命中、非 ASCII / 转义输入、超长选择器与深文档的组合；三个严重问题都落在这三块空白里。

存量缺陷共 13 条（3 严重 / 4 一般 / 6 轻微），是否纳入修复待用户决定。性能类结论本部分均无基线数据，全部以「待验证假设 / 无基线优化方案」记录，不进 `todo.md` / `tasks.md`。
