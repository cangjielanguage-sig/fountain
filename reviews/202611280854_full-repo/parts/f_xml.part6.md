# f_xml 模块审查报告（模块第 6/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_xml/src`（本部分 20 个源文件，全部为 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本部分所有问题来源均为「存量」
- **审查重点**：XML 解析与安全（XXE / 实体展开 / 转义）、递归与栈溢出、OOM、死代码、重复逻辑；本部分实际覆盖字符源与解码层、事件定义、`skipElement` 标签级扫描器、性能/回归测试基础设施
- **报告版本**：v1（分部分报告，供主 Agent 合并进 `docs/review/2026-11-28/f_xml_v2.md`）

## 发现

### [一般][存量] #1 同一模块存在两套互斥的性能门禁阈值，且旧门禁在同一进程里先测 10 MB 再测 50 MB

- **位置**：`f_xml/src/Perf_test.cj:554-580`（阈值在 `:571` / `:575` / `:576`）；对照 `f_xml/src/PerfTen_test.cj:75`、`f_xml/src/PerfFifty_test.cj:64`（后两个文件属第 5 部分）
- **来源**：存量（`git blame -L 554,580` 为 `5be2470bd2`（26 行）+ `ed671ce909`（1 行）；PerfTen/PerfFifty 侧为同一轮的后继实现）
- **判据**：review-checklist §14「接线缺失 / 只做了一半的分支」+ §11「契约与实现不符」；同一开关 `F_XML_PERF=1` 下两套判定对同一被测对象给出不同结论
- **证据**：静态确定 —— 三处阈值直接读代码即可比对
- **描述**：
  1. 10 MB 事件解析：`Perf_test.cj:571` 断 `min(3) < 7200 ms`，`PerfTen_test.cj:75` 断 `min(5) < 1000 ms`。3000 ms 的机器会「旧门禁通过、新门禁失败」。
  2. 50 MB 峰值：`Perf_test.cj:576` 断 `VmHWM ≤ 320 MB`，`PerfFifty_test.cj:64` 断 `VmHWM < 262144 kB（256 MB）`。300 MB 的机器同样一过一失。
  3. `Perf_test.gateTenAndFiftyMegabytes` 在**同一进程**内先跑 10 MB×3 再跑 50 MB×1，而 `PerfTen_test.cj:22-26` 明确写了「单独一个类是为了让门禁独占进程：`VmHWM` 是进程级单调峰值，同进程内先跑的 10 MB 会垫高 50 MB 的读数」。旧门禁用 `delta = hwm50 - hwm10` 试图补偿，但同一用例里还保留了绝对值断言（`≤ 320 MB`），补偿与绝对值混用，且绝对阈值被放宽到恰好掩盖污染量。
  4. `F_XML_PERF=1` 时三个用例同时执行，仓库里没有任何一处说明以哪个为准（旧用例也没有 `@Deprecated` 或注释标注被取代）。
- **建议**：二选一并二选一落文档 —— 删除 `Perf_test.gateTenAndFiftyMegabytes`（保留 `syntheticStream*` 三个自检用例），或把它收窄成「只跑 1 MB 冒烟 + 打印」，阈值判定统一交给 `PerfTen_test` / `PerfFifty_test`。若要保留旧口径，至少在类注释里写清「阈值以 `PerfTen/PerfFifty` 为准，本用例只作历史对照」，并去掉绝对值断言。

### [一般][存量] #2 `BufferedRuneSource.ensureOwn` 在「部分解码 + 解码错误」时丢弃 `BlockFill.error`

- **位置**：`f_xml/src/RuneSource.cj:220-228`（判据行 `:222-228`）
- **来源**：存量（`git blame -L 208,231` 全部 24 行为 `4006c4c25d`）
- **判据**：review-checklist §11「错误处理缺失或静默」+ §3「`Result` 失败被丢弃是一般以上」
- **证据**：静态确定（丢弃动作）+ 待确认（被丢弃的错误是否会在下一次 `decodeInto` 重新抛出，取决于底层解码器抛异常后的状态）
- **描述**：`ensureOwn` 只在 `fill.count == 0` 时把 `fill.error` 存进 `ownError`：

  ```
  let fill = this.finishFill(this.decodeInto(block, this.ownLen, this.capacity - this.ownLen), block, this.ownLen)
  this.ownLen += fill.count
  if (fill.count == 0) { if (fill.error.isSome()) { this.ownError = fill.error } else { this.ownEof = true } }
  ```

  `fill.count > 0 && fill.error.isSome()` 时 `fill.error` 被直接丢弃，循环继续。内置两条路径（`Utf8RuneSource` / `BlockRuneSource` → `ByteDecoder`）在严格模式下是「抛错前不消费坏字节」，所以下一次 `decodeInto` 会重新抛同一错误并以 `count == 0` 落进 `ownError`，实际不丢；但 `decodeViaPull` 的路径（`CharsetRuneSource`、以及任何第三方 `BufferedRuneSource` 子类）依赖 `pull()` 抛异常后的可重入性 —— 若 `TextReader.read()` 抛异常后已跨过坏字符，则该错误永久丢失，表现为「文档被静默截断且不报错」。
  这与第 5 部分 #9（`LineWindow.fillOnce` 同样只在 `fill.count == 0` 时保留 `pendingError`）是同一根因的两处实例，合并时可归为一条。
- **建议**：把条件改为「有错就存」——`if (fill.error.isSome()) { this.ownError = fill.error } else if (fill.count == 0) { this.ownEof = true }`；`LineWindow.fillOnce` 同步改（`f_xml/src/LineWindow.cj:104-110`）。这样错误一定在消费到 `ownLen` 时抛出，不依赖解码器的可重入性。

### [轻微][存量] #3 三个零引用的测试辅助（`minOf` / `MemoryInputStream.consumed` / `JsonRecord.isNull`）

- **位置**：`f_xml/src/TestSupport_test.cj:141-147`（`minOf`）、`f_xml/src/TestSupport_test.cj:49-51`（`consumed()`）、`f_xml/src/TestDataRoot_test.cj:78-80`（`isNull`）
- **来源**：存量（`git blame`：`minOf` 与 `consumed()` 为 `9a74dcbe9f`，`isNull` 为 `d17d3f528e`）
- **判据**：review-checklist §1「非 public 符号在可预见范围内无引用」
- **证据**：静态确定 —— `grep -F "minOf" --include=*.cj f_xml/src` 仅命中定义处；`grep -F "consumed()"` 仅命中 `TestSupport_test.cj:49`；`grep -F "isNull"` 仅命中 `TestDataRoot_test.cj:78`
- **描述**：三者都在 `internal` 顶层声明里且模块内（含全部 `*_test.cj`）零调用。`MemoryInputStream` 的 `consumed()` 与 `TrackingInputStream.readCount` 功能重叠，但后者被 `XmlPullParser_test.cj:54` 使用，前者没有。`JsonRecord.get` 有 5 处调用（`XmlconfHarness_test.cj:74-76/183/185`），`isNull` 是它的未使用包装。
- **建议**：删除这三个成员；`consumed()` 若将来要用于「读了多少字节」的断言，届时再加（`readCount` 已覆盖同类需求）。

### [轻微][存量] #4 两处恒不可达的分支：`truncatedOrNone` 的 `truncatedReported` 与 `peekFast` 的第二个错误判断

- **位置**：`f_xml/src/RuneSource.cj:633-636`、`f_xml/src/RuneSource.cj:251-253`
- **来源**：存量（`git blame -L 626,641` 为 `9a74dcbe9f` / `d17d3f528e`；`peekFast` 段在 `:240-255` 内，为 `4006c4c25d` / `d17d3f528e`）
- **判据**：review-checklist §1「不可达语句 / 恒假分支」
- **证据**：静态确定 —— 两条都可由前置状态直接推出
- **描述**：
  1. `truncatedOrNone`：只有 `ensure(2)` / `ensure(4)` 返回 `false` 才会进入，此时 `eof == true` 且 `available < count`。第一次进入走 `truncatedReported = true` 分支并 `consume(remaining)`，`consume` 在 `pos == len` 时把 `pos/len` 双双归零 ⇒ 下次进入必然 `available() == 0`，先命中 `:630` 的 `return -1`。所以 `:633-636` 的「重复上报保护」永远走不到，`truncatedReported` 字段只被写、从不产生不同行为（注释声称的「只报一次」已由 `available() == 0` 保证）。
  2. `peekFast`：`:245` 的 `if (!this.ensureOwn(offset + 1))` 为假意味着 `ownLen - ownPos >= offset + 1`，即 `ownPos + offset <= ownLen - 1 < ownLen`，所以 `:251` 的 `ownPos + offset == ownLen` 恒假。
- **建议**：删掉 `:633-636` 与 `truncatedReported` 字段（或把 `truncatedReported` 改成对 `available()` 的显式断言，保留意图）；删掉 `:251-253`。

### [轻微][存量] #5 三组重复逻辑：性能计时循环、门禁开关读取、测试文本重复

- **位置**：`f_xml/src/Perf_test.cj:404-414` 与 `:426-436`；`f_xml/src/Perf_test.cj:378-383` 与 `:418-423`；`f_xml/src/TextScan_test.cj:31-34` 与 `f_xml/src/TestSupport_test.cj:247-255`
- **来源**：存量（`git blame`：前者 `1fd1dd35ca` / `5be2470bd2`，后者 `19e26c9c32`）
- **判据**：review-checklist §2「只改名字，函数体逐行对齐」/「纯别名包装」
- **证据**：静态确定 —— 函数体逐行比对
- **描述**：
  1. `runSyntheticPass(targetBytes, bufSize)` 与 `Perf_test.runOnce(targetBytes, bufSize)` 的函数体逐行相同（建 `SyntheticXmlStream` → 建 `XmlPullParser` → `nextEvent` 计数 → 返回 `(ms, events)`），差异只有 doc 注释；前者被 `SemanticPerf_test.cj:100` 与 `PerfTen/PerfFifty` 使用，后者只在本类内使用。
  2. `perfGateEnabled()`（顶层）与 `Perf_test.perfEnabled()`（私有方法）读同一个 `F_XML_PERF` 并做同一个 `== "1"` 比较；`Perf_test` 内部 2 处（`:555`、`:585`）走私有版本，`SemanticPerf_test` / `PerfTen` / `PerfFifty` 走顶层版本。
  3. `TextScan_test.repeatBlock(block, times)` 函数体只有 `repeatText(block, times)`，是纯别名；`repeatText` 已被 13 个测试文件直接调用。
- **建议**：`Perf_test` 内部改调 `runSyntheticPass` 与 `perfGateEnabled`，删掉两个私有副本；`repeatBlock` 删除并让 `TextScan_test` 直接调 `repeatText`。这三处合并只减代码、不改语义（`runs` 默认值、打印口径均不受影响）。

### [轻微][存量] #6 `Utf8RuneSource` 头注释仍称 Strict 档「走 `std.io.StringReader`」，实现两档都走 `ByteDecoder`

- **位置**：`f_xml/src/RuneSource.cj:300-303`（注释）对照 `f_xml/src/RuneSource.cj:309-317`（构造 `ByteDecoder(input, ByteCodec.Utf8Strict / Utf8Replace, bufSize)`）
- **来源**：存量（`git blame -L 298,306` 为 `9a74dcbe9f`，而构造器在 `d17d3f528e` 已改成 `ByteDecoder`）
- **判据**：review-checklist §11「语义与注释不符」/ §13「文档与实现漂移」
- **证据**：静态确定 —— 类注释列出的两条实现路径与构造函数实际使用的两条 codec 分支不是同一件事；模块内 `grep "StringReader"` 只命中 `Perf_test.cj:21/245/292`（读 `/proc`），`RuneSource.cj` 除该注释外无任何 `StringReader` 引用
- **描述**：注释说「`Strict` 走 `std.io.StringReader`，`Replace` 走自研 `ByteDecoder`」「两条路径互不替代」，实际 `strict` 只决定同一 `ByteDecoder` 里的 `ByteCodec.Utf8Strict` / `Utf8Replace` 分支。读注释的人会以为严格档不受自研解码器缺陷影响，从而在排查解码差异时找错方向。与第 2 部分 #1（spec 里「Strict 走 StringReader」的旧口径）同源，此处是源码侧未同步的实例，合并时可并入一条。
- **建议**：注释改成「两档共用 `ByteDecoder`，`strict` 只切换 `ByteCodec.Utf8Strict`（非法序列抛 `XmlException`）/ `Utf8Replace`（按 RFC 3629 maximal subpart 产 `U+FFFD`）」。

### [轻微][存量] #7 `RuneSource` 的前瞻偏移契约三处不一致：文档写 ≤4、实现接受 ≤8、越界静默当 EOF

- **位置**：`f_xml/src/RuneSource.cj:24-27`（类/接口文档「只保证 `offset ≤ 4`」）、`f_xml/src/RuneSource.cj:242-244`（`offset > 8` 直接 `-1`）、`f_xml/src/RuneSource.cj:274-281`（`peek` 把 `-1` 转成 `None`）
- **来源**：存量（`git blame -L 240,255` 以 `4006c4c25d` 为主，另含 `d17d3f528e` / `9a74dcbe9f` 各 1–4 行）
- **判据**：review-checklist §11「契约与实现不符」；与第 5 部分 #5（`LineWindow.peek` 对 `offset > 8` 静默 `None`）同一模式
- **证据**：静态确定 —— `LineWindow.peekFast` 自己的慢路径允许到 8（`LineWindow.cj:157/167`），说明真实上界是 8；文档写的 4 是 `<!--` / `<![CDATA[` 这类前缀长度，不是实现上界
- **描述**：三处口径互斥：（1）公开接口文档承诺 4；（2）实现支持 8，超过 8 返回 `-1`；（3）`peek(9)` 得到 `None`，与「流结束」不可区分，调用方无法把「看太远」和「到 EOF」分开。当前模块内 `RuneSource.peek/peekFast` 只被测试直接调用（生产路径统一走 `LineWindow`），因此影响面是「直接使用公开 `RuneSource` 的下游」，属于潜在而不是已发生的错判。
- **建议**：把接口文档改成「`offset ∈ [0, 8]`，超出范围返回 `None` / `-1`（与 EOF 同值，调用方不得用越界偏移探边界）」；若希望区分，另加 `Option` 版本或断言。至少让三处写成同一个数。

### [轻微][存量] #8 行列号只把 `LF` 当换行：CR-only 文档的解码错误行号恒为 1

- **位置**：`f_xml/src/RuneSource.cj:265-270`（`advanceFast` 只在 `cp == 0x0A` 时 `line++`）、`f_xml/src/RuneSource.cj:163-171`（`finishFill` 的 `decLine` 同样只认 `0x0A`）
- **来源**：存量（`git blame -L 163,171` 以 `4006c4c25d` 为主，另含 `9a74dcbe9f`）
- **判据**：review-checklist §11「语义与注释/规格不符」—— XML 1.0 §2.11 要求把 `CR` 与 `CRLF` 都归一成 `LF`，孤立 `CR` 是合法换行
- **证据**：静态确定（判定事实）+ 待确认（影响面：需要构造 CR-only 文档 + 坏字节才能看到）
- **描述**：`LineWindow.fillOnce`（`LineWindow.cj:96-105`）在填充时已把 `0x0D` 归一成 `0x0A` 并吞掉后继 `0x0A`，所以**词法器侧**报错行列号是对的；但字符源侧的两套游标（`line/column` 与 `decLine/decColumn`）看的是**归一前**的原始码点，只认 `0x0A`。后果：CR-only 文档（旧 Mac 换行）里，第 3 行的非法 UTF-8 字节会被 `positionedError`（`RuneSource.cj:186-196`）报成「第 1 行第 N 列」；直接使用 `RuneSource.position()` 的下游同样拿不到 CR 换行。CRLF 文档不受影响（`LF` 仍会重置列）。
- **建议**：`advanceFast` 与 `finishFill` 统一按 XML 1.0 §2.11 处理 `0x0D`（`CR` 记一次换行，`CRLF` 只记一次，用一个 `pendingSkipLf` 标志，与 `LineWindow` 的实现保持一致）；或直接把行列号职责上收，让字符源只报「已消费码点数」，行列号只由 `LineWindow` 计算。

### [轻微][存量] #9 `SkipScanner` 的结束标签只比较 `local`：前缀不同也判匹配，`depth > 0` 时完全不校验名字

- **位置**：`f_xml/src/SkipScanner.cj:47-52`（判据行 `:48` `if (name.local != startName.local)`）
- **来源**：存量（`git blame -L 47,49` 全部为 `7cd8b9d291`）
- **判据**：review-checklist §11「边界遗漏」；`skipElement` 是公开 API（`XmlPullParser.skipElement`），跳过期间的配对错误会被静默接受
- **证据**：静态确定 —— `<p:a> … </q:a>` 在 `depth == 0` 处 `local` 相同即 `return`，前缀不参与比较
- **描述**：`skipSubtree` 的 doc 已声明「只按深度配对」，`depth > 0` 不校验名字是有意取舍；但在 `depth == 0`（即将结束本次跳过）处既然已经调了 `readName()`，只比 `local` 会让前缀不匹配的结束标签也算配对，跳过早结束，随后主解析器在残留的 `</p:a>` 上再报错——错误位置指向「跳过结束后」而不是真正的失配处。触发需要构造前缀不一致的畸形输入，正常文档不受影响。
- **建议**：`depth == 0` 处比较 `(name.prefix, name.local)` 与 `startName` 的对应字段（`RawName` 已在手，比较成本可忽略）；或按注释的口径彻底不比名字、把 `readName()` 换成 `skipName()`，让行为与文档一致。

### [轻微][存量] #10 门禁的环境探测只在 Linux 生效，无 `/proc` 时 `gateEnvironmentOk()` 恒为真

- **位置**：`f_xml/src/Perf_test.cj:241-266`（`readProcMem`）、`:288-300`（`readProcText`）、`:303-319`（`cpuCount` 读不到返回 1）、`:322-328`（`loadAverage1` 读不到返回 0）、`:399-401`（`gateEnvironmentOk`）
- **来源**：存量（`git blame -L 398,401` 为 `1fd1dd35ca`）
- **判据**：review-checklist §11「错误处理静默」+ §14「接线缺失」（本文件的 10/50 MB 用例 `:554-580` 没有调用 `gateEnvironmentOk()`）
- **证据**：静态确定 —— 三个探测函数都以 `catch (_: Exception) → None` 收口，`gateEnvironmentOk` 在 `cpuCount() == 1`、`loadAverage1() == 0.0` 时判定为「环境合格」
- **描述**：非 Linux（或容器内 `/proc` 不可读）时：`nproc=1`、`loadavg1=0.0`、`load_bound=0.5`，`gateEnvironmentOk()` 返回 `true`，打印的 `load_bound` 也是假值；`PerfFifty_test` 至少还会因为 `hwm <= 0` 打印 `invalid` 并 `return`，而 `Perf_test.gateTenAndFiftyMegabytes` 只打印 `rss unavailable` 就继续做时间断言。第 5 部分 #20 已就「开关关闭即 return」记过一条，本条是环境探测侧的另一个入口，合并成一条「门禁在不可测环境下静默降级」也成立。
- **建议**：探测函数增加「不可用」与「值为 0」的区分（返回 `?Int64` / `?Float64`），`gateEnvironmentOk()` 在任一探测不可用时返回 `false`（判 invalid 而不是 ok）；`Perf_test.gateTenAndFiftyMegabytes` 在跑之前也调一次 `environmentLine()` + `gateEnvironmentOk()`（与 `PerfTen/PerfFifty` 对齐），或在注释里写明「本用例不设环境门禁，仅作历史对照」。

### [轻微][存量] #11 两处格式塌行：函数签名与函数体、注释与声明挤在同一行

- **位置**：`f_xml/src/XmlChars.cj:101`（`static func isDigit(r: Rune): Bool {        r >= r'0' && r <= r'9'`）、`f_xml/src/TestSupport_test.cj:229`（`/** … */internal func utf32beBytes(…`）
- **来源**：存量（`git blame`：`XmlChars.cj:101` 为 `19e26c9c32`；`TestSupport_test.cj:229` 为 `f3024e0e61`）
- **判据**：review-checklist §10「可读性 / 维护性」；`cjfmt` 会把这些行展开，说明它与工程格式化口径不一致
- **证据**：静态确定 —— 同一文件其余重载（`:104-106`、`:113-115`）都是标准缩进，只有这两处塌行
- **描述**：不影响编译与行为，但 `cjfmt` / diff / 代码检索时这两行与周围不一致；`XmlChars.cj:101` 还是 `XmlChars` 唯一一处「身体紧贴 `{`」的写法。
- **建议**：按 `cjfmt` 口径展开为多行（把 `r >= r'0' && r <= r'9'` 放回缩进体，`utf32beBytes` 的 doc 注释换行）。

## 优化可行性方案

> 以下均无改前基线 + 改后对照，**不进 `todo.md` / `tasks.md`**，只作下一轮补数据的候选。

### [堆内存] `parse(text)` 入口把整份文本复制成字节数组，峰值多一份输入

- **现状**：`TextInputStream(text)` 在构造时执行 `text.toArray()`（`f_xml/src/PrefixStream.cj:25-27`），此后整个解析期间同时持有原 `String` 与等价 `Array<Byte>`；`XmlPullParser.init(text:)`（`XmlPullParser.cj:37`）把它挂到 `private let stream` 上，生命周期 = parser 生命周期。1 MB 文档 = 多驻留约 1 MB；10 MB = 约 10 MB。
- **方案**：给 `parse(text)` 路径换成「按码点游标的 `InputStream` 适配」或直接让 `ParserEngine` 接受 `String` 源（`text.runes()` 迭代器 + 少量环形缓冲），不再 `toArray()`；`XmlParser.parse(bytes)` 路径保持不变。
- **预期**：`parse(text)` 峰值下降约 1 份输入大小（1 MB 输入约 −1 MB，10 MB 输入约 −10 MB）；解析吞吐不变。
- **代价**：需要一个 `String` → 码点块的新适配器（或复用 `LineWindow` 的填充接口）；`TextInputStream` 的 `init(data:)` 分支仍被 `XmlParser.cj:34` 使用，不能整体删除。
- **验证**：同一 10 MB 文本分别走 `parse(text)` 与 `parse(bytes)`，多轮取 `getAllocatedHeapSize()` 峰值 + RSS 稳态；断言字节结果与事件日志逐行一致（`PushPullParity_test` 的样本集可直接复用）。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `finishFill` 对每个已解码码点再做一次换行扫描，只服务罕见的错误定位

- **现状**：`f_xml/src/RuneSource.cj:163-171` 在**每次块填充**后遍历 `fill.count` 个码点，只为推进 `decLine/decColumn`；这两个游标唯一的消费点是 `positionedError`（`:186-196`），即只有解码异常时才需要。等于在热路径上给每个字符再加一次「比较 + 分支 + 计数」，输入越大浪费越多。
- **方案**：把「块内换行数」与「最后一个换行后的偏移」交给 `ByteDecoder.decodeBlock` 顺手统计（它本来就在逐字节走），或在块内只记 `fill.count` 与首码点位置，等真正出错时再对当前块做一次局部回扫（错误路径慢一点无妨）。
- **预期**：省掉一次全量遍历（每字符 1 次比较 + 1 次分支 + 2 次字段写），量级待侧。
- **代价**：`decLine/decColumn` 的推进点从「填充时」挪到「报错时」，需要保证并发/重入语义不变（当前是单解析器单线程，风险低）；错误位置必须逐点对齐（`InvalidByteMode_test` 已有 `1:5` 这类精确断言可作回归）。
- **验证**：`cjpm bench -O2` 同输入（10 MB / 50 MB 合成流）改前改后各 5 轮取中位数；同时跑 `InvalidByteMode_test` / `TextScan_test` 的错误位置断言。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ByteReader` 的双缓冲让每次 `fill` 多一次整块 `memcpy`

- **现状**：`f_xml/src/RuneSource.cj:752-782` 每次 `fill()`：先把未消费尾部搬到 `buf[0..]`（拷贝 A），再 `input.read(scratch)`（读入第二块缓冲），再把 `scratch` 的前 `n` 字节拷进 `buf`（拷贝 B）。`buf` 与 `scratch` 各占 `bufSize`（默认 8 KB × 2）。1 MB 输入约 128 次填充 ⇒ 约 1 MB 尾部搬运 + 1 MB scratch→buf 拷贝。
- **方案**：`read` 直接读进 `buf[len..]`（`Array` 支持带偏移视图或按长度切片），只在 `len == buf.size` 且 `pos > 0` 时才压缩；压缩仍按原逻辑。这样去掉拷贝 B，拷贝 A 也只在必要时发生。
- **预期**：每 MB 输入少一次全量 `memcpy`，另省 `scratch` 的 `bufSize` 常驻（每解析器 8 KB，默认值下占比很小）。
- **代价**：`InputStream.read(Array<Byte>)` 只能整数组传入，若要读进 `buf[len..]` 需要一份 `bufSize - len` 的临时视图或改成分段读取；`bufSize < 单个字符宽度` 时的扩容分支要重新验证（`bufSize = 4/8` 的用例在 `RuneSource_test` / `TextScan_test`）。
- **验证**：`cjpm bench -O2` 10 MB 合成流改前改后 5 轮中位数；`RuneSource_test.assertFastParity` + `TextScan_test` 四档 `bufSize` 全绿。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `finishFill` 的逐码点换行扫描占解码侧自耗时的比例（猜测 5% 量级，未测） | `f_xml/src/RuneSource.cj:163-171` | 该函数自耗时占比 + 调用次数 | `cjprof record` 跑 `runSyntheticPass(50 MB)`；对照把循环注释掉的一版 |
| 2 | `ByteReader.fill` 的两段拷贝占 I/O 侧耗时比例 | `f_xml/src/RuneSource.cj:752-782` | 分段计时（`fill` 累计耗时 / 解析总耗时） | 在 `fill()` 首尾加 `MonoTime` 累计（仅测量构建），跑 50 MB × 3 |
| 3 | 非 UTF-8（GBK）路径每字符一次 `TextReader.read()` 的 `?Rune` 分配是 GBK 文档的主要成本 | `f_xml/src/RuneSource.cj:350-357`、`:140-155` | 分配次数 / GC 占比 / 吞吐对比 | `cjprof heap` + 用 `CharsetRuneSource` 跑 1 MB GBK 文档；与 UTF-8 同规模对比 |

## 已排除的候选（误报边界，不计入统计）

- `TextInputStream.read`（`PrefixStream.cj:33-46`）与测试夹具 `MemoryInputStream.read`（`TestSupport_test.cj:34-47`）逐行相同：前者是生产入口（被 `XmlParser.cj:34`、`XmlPullParser.cj:37` 使用），后者是测试夹具，按 §2 误报边界（测试准备代码）不判重复。
- `BufferedRuneSource.no-arg init`（`RuneSource.cj:98-100`）无子类调用：`public abstract class` 的 `protected` 成员属扩展点，按硬原则不计死代码。
- `Utf8RuneSource.pull`（`:324-338`）/ `BlockRuneSource.pull`（`:389-397`）在 `decodeInto` 的类型分派（`:133-137`）下运行期不可达：它们是抽象成员 `pull` 的覆盖实现，按「父类覆盖」豁免不计死代码，仅记录信息。
- `blocksFilled` / `codepointsYielded` / `hasOwnBlock()` 只被 `RuneSource_test.cj` 读取：属「仅测试使用」，是可见性建议而非死代码。
- `WriterEncoding_test.semanticDump`（`:221-247`）是递归函数，但只在测试里、输入是固定小样本，栈深度受用例控制，按 §4 误报边界不计。
- `SpillDir_test` 临时改写进程级 `TMPDIR`：`try/finally` 有恢复（`:36-42`、`:56-63`），无残留；是否与并行执行的测试冲突取决于 unittest 的并发策略，本部分未取得该数据，暂不计。
- `QName` 的 `==` 不比较 `prefix`、`XmlAttribute.toString` 不转义属性值：前者是 doc 声明的「展开名比较」语义（`QName.cj:37-61`），后者仅用于调试输出，均属有意设计。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/src/Perf_test.cj` | .cj | ✅ | 见 #1、#5、#10；合成流与 golden 自检用例本身正确 |
| 2 | `f_xml/src/PrefixStream.cj` | .cj | ✅ | `TextInputStream` 全量副本见「优化方案 [堆内存]」；`PrefixStream.close` 为公开 API，生产路径由 `XmlPullParser.close` 关原流 |
| 3 | `f_xml/src/PrefixStream_test.cj` | .cj | ✅ | 3 个用例覆盖前缀拼接 / 空前缀 / close 委托，与实现一致 |
| 4 | `f_xml/src/PushPullParity_test.cj` | .cj | ✅ | 推拉日志逐行对比，样本与实现契约一致 |
| 5 | `f_xml/src/QName.cj` | .cj | ✅ | 展开名比较与 doc 一致；无问题 |
| 6 | `f_xml/src/RuneSource.cj` | .cj | ✅ | 见 #2、#4、#6、#7、#8 与 3 条优化方案 |
| 7 | `f_xml/src/RuneSource_test.cj` | .cj | ✅ | 逐字符对照 / 块边界 / 1 MB 冒烟，断言口径合理（`0..5` 偏移未越 `≤4` 的文档口径） |
| 8 | `f_xml/src/SemanticPerf_test.cj` | .cj | ✅ | 只打印不断言；吞吐列口径与 part2 #8 相关，未重复计入 |
| 9 | `f_xml/src/SkipScanner.cj` | .cj | ✅ | 见 #9；引号 / 注释 / CDATA / PI 四类「假 `>`」均已处理 |
| 10 | `f_xml/src/SkipScanner_test.cj` | .cj | ✅ | 6 个用例正好覆盖四类假 `>` + 实体不解析 + 提前 EOF |
| 11 | `f_xml/src/SpillDirFallback_test.cj` | .cj | ✅ | 四级候选失败 / 缺失跳过 / 回落创建 / 成功路径，与 `SpillDir` 契约一致 |
| 12 | `f_xml/src/SpillDir_test.cj` | .cj | ✅ | TMPDIR 优先级两例，恢复在 `finally` |
| 13 | `f_xml/src/Spill_test.cj` | .cj | ✅ | 溢出 20 MB 展开 / 读回一致 / Strict 阈值 / 显式目录；断言与实现一致 |
| 14 | `f_xml/src/TestDataRoot_test.cj` | .cj | ✅ | 见 #3（`isNull`）；`FlatJson` 是限定格式的极简解析，doc 已声明范围 |
| 15 | `f_xml/src/TestSupport_test.cj` | .cj | ✅ | 见 #3、#5、#11；其余夹具均被使用 |
| 16 | `f_xml/src/TextScan_test.cj` | .cj | ✅ | 见 #5；批量/逐字符等价与错误位置断言完整 |
| 17 | `f_xml/src/WriterEncoding_test.cj` | .cj | ✅ | 写侧编码与往返语义用例；`semanticDump` 递归见「已排除的候选」 |
| 18 | `f_xml/src/XmlChars.cj` | .cj | ✅ | 见 #11；`Char` / `NameStartChar` / `NameChar` 产生式与 XML 1.0 第 5 版逐段一致 |
| 19 | `f_xml/src/XmlElement_test.cj` | .cj | ✅ | DOM 取值 / 链式构造 / DOCTYPE 实体顺序；与实现一致 |
| 20 | `f_xml/src/XmlEvent.cj` | .cj | ✅ | 10 个分支与 doc 的「分支固定 10 个」一致；`toString` 转义覆盖 `"` `\` `LF` `CR` `TAB` |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #6（注释与实现不符）、#7（偏移契约三口径）、#8（CR 换行口径）、#9（跳过配对只比 `local`）、#11（格式塌行）；语言特性方面核对了 `Option` 热路径替身（`peekFast`/`advanceFast`）、`match` 类型分派、`protected` 扩展点语义，未发现误用；并发与安全见 §12 行 |
| §1 死代码 | 2 | #3（3 个零引用测试辅助）、#4（2 处恒假分支）。机械动作：对 `RuneSource.cj` / `XmlChars.cj` / `SkipScanner.cj` / `PrefixStream.cj` / `XmlEvent.cj` / `QName.cj` 全部 `private`·`internal` 符号逐个全模块 `grep`（`blockCapacityOf` / `runesOf` / `cpsOf` / `cps32Of` / `isAsciiXmlChar` / `asciiMaskFor` / `hex` / `hexValue` / `isDigit` / `isHexDigit` / `isWhitespace` / `readCodePointBlock` / `decodeInto` / `decodeBatch` / `finishFill` / `pull` 等均有引用），测试辅助对 `minOf` / `consumed` / `isNull` / `get` / `tokenText` / `drainStream` 等逐个查；`public` 顶层声明（`QName` / `SourcePosition` / `XmlAttribute` / `XmlEvent` / `XmlAction` / `XmlEventHandler` / `RuneSource` / `BufferedRuneSource` / 三个字符源 / `PrefixStream` / `LineWindow`）对外可达，按硬原则一不判 |
| §2 重复逻辑 | 1 | #5（3 组：计时循环、门禁开关、文本重复别名）。同文件内把 20 个文件的函数体压成「输入→输出→副作用」两两比对；跨文件搜了错误文案（「跳过子树时」「提前 EOF」）、`F_XML_PERF`、`/proc/` 路径、`repeatText` / `runSyntheticPass` 等字面量 |
| §3 空实现 | 0 | 无 `TODO` / `FIXME` / `UnsupportedException`；`MemoryInputStream.close() {}`、`SyntheticXmlStream.close() {}`、`RecordingOutputStream` 只有计数的 `flush`、`raiseOwnError` 的 `case None => ()` 都是带语义的 no-op（测试夹具 / 可选关闭），不是契约空实现 |
| §4 栈溢出 | 0 | 本部分唯一递归是测试侧 `semanticDump`（`WriterEncoding_test.cj:221-247`），输入是固定小样本，深度由用例控制；`SkipScanner.skipSubtree` 用 `while (true)` + `depth` 显式深度，不递归；`BufferedRuneSource` / `ByteDecoder` / `ByteReader` 全为迭代 |
| §5 OOM | 0 | 本部分无「按不可信长度预分配」：`Array<Int32>(capacity)` 的 `capacity` 由 `blockCapacityOf` 钳到 `[64, 1 MiB]`；`ByteReader` 扩容按 `len + n` 精确值，不放大；`TextInputStream` 的全量副本是「省内存」候选（进优化方案），不是无界增长 |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` / 分段计时数据，`Perf_test` 只有端到端总耗时；任何热点结论都不成立，线索全部进「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享容器 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；`SyntheticXmlStream` 的跨块读取是单线程状态机 |
| §6.4 低效算法 | 0 | 未发现平方级路径：`ByteReader.copyAsciiRun` / `LineWindow.asciiRunLength` 是单趟扫描，`SkipScanner.skipUntil` 线性；`encode`/`decode` 无嵌套循环；`Perf_test.measure` 的 `SyntheticXmlStream(targetBytes)` 重算记录数只有 O(log n) 次除法，不在解析主路径 |
| §7 降堆内存方案 | 1 | 「`parse(text)` 全量副本」（无基线，不进 tasks） |
| §8 降 CPU 方案 | 2 | 「`finishFill` 二次遍历」「`ByteReader` 双缓冲多一次 memcpy」（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象只有定长小数组（`hex` 的数字串、`toString` 的 `StringGenerator`），逃逸面大（返回值 / 事件载荷）；且收益只能靠峰值内存证明，当前无改前基线，按 §9 结论写法只能是「待验证假设」，故不列方案 |
| §11 现有代码的 BUG（存量） | 2 | #2（`ensureOwn` 丢 `error`）、#8（CR 换行口径）；另核对了 `ByteReader.fill` 扩容 / `copyAsciiRun` 的 `pos==len` 复位、`consumeBroken` 的 `available` 边界、`nextUtf16` 代理对与 `ensure(4)` 失败路径、`decodeCompleteUtf8` 的 `E0/ED/F0/F4` 上下界，未发现其它越界或丢字节 |
| §12 并发安全与锁粒度 | 0 | 本部分所有类型（`BufferedRuneSource` 及其子类、`ByteDecoder`、`ByteReader`、`SkipScanner`、`PrefixStream`）都是**每解析器一份**的可变对象，无静态可变状态、无注册表、无回调；`SyntheticXmlStream` 仅测试内单线程使用 ⇒ 线程封闭，不构成共享路径。唯一可被多线程共享的是 `public` 常量（`XmlEvent` 分支、`QName` 值类型）与 `kGcEnvNames`，均不可变 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`（README / doc 在第 1–3 部分已审，`#5`/`#7`/`#12` 已登记公开 API 与限制面）；`XmlAction.SkipSubtree`→`SkipScanner`、`skipElement`→`ParserEngine.skipElement` 的接线完整（`ParserEngine.cj:499`）；`Perf_test` 的 10/50 MB 门禁与 `PerfTen/PerfFifty` 的重复见 #1，属「两次实现」而非「接线缺失」 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无 `.md`；与 `files/f_xml.part6.txt` 逐行对应 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分（字符源与解码层、事件定义、`skipElement` 标签级扫描器、性能与回归测试基础设施）代码质量良好：`RecordSource` 的 `Option` 热路径替身有明确动机与对照用例，块解码在 `bufSize = 4/8` 的极端边界上有逐字符等价测试，错误定位用「消费游标 + 解码游标」两套位置分离处理，`SkipScanner` 把四类「假 `>`」都考虑到了，注释密度与「为什么这样写」的说明明显高于一般模块。

**没有阻塞项**（无崩溃、无越界、无数据竞争、本部分无 XXE/实体展开路径）。两条「一般」都属口径/健壮性问题而不是功能失效：门禁阈值有两套互斥定义且旧用例违反「独占进程测 VmHWM」的自定约束；`ensureOwn` 在部分解码失败时会丢掉错误对象，当前只影响第三方/`CharsetRuneSource` 直连 `peek/advance` 的路径。九条「轻微」里，#7/#8/#9 是三条独立的「契约口径漂移」（偏移上界、换行定义、名字比较），#3/#4/#5 是机械检查到的死代码与重复，#6/#10/#11 是注释与格式层面。

存量缺陷共 11 条，是否纳入修复待用户决定；三条优化方案均无基线，只能进下一轮补数据清单，不进 `tasks.md`。
