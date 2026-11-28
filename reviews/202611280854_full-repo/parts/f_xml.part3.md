# f_xml 模块审查报告

> **模块第 3/7 部分**（本报告只覆盖 `files/f_xml.part3.txt` 列出的 16 个文件，全部为 `doc/spec/**` 下的 `.md`：`implement-f-xml-m1` 的 5 个 capability spec + `tasks` / `verification`，`optimize-f-xml-semantic-layer` 全部 6 个文件，`reuse-f-xml-writer-scratch` 全部 3 个文件。`README.md` / `README_en.md` / `doc/f_xml模块设计.md` / `doc/build-warnings.md` / `doc/xmlconf-unsupported.md` 与各 `.cj` 由第 1、2、4–7 部分产出；本部分编号独立，合并时以主 Agent 为准。README 与代码只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（本部分 0 个 `.cj` + 16 个 `.md`）
- **基线**：工作区快照（`120fd2542`，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：XML 解析 / 序列化的正确性与安全承诺（XXE、实体展开、转义、三层上限）在规格层的落实、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG。本部分实际内容为三份已归档变更的规格与验收记录，故重点落在 §13 文档与实现一致性、§14 承诺完备性，以及规格对安全 / 资源边界的描述是否成立
- **报告版本**：v1（第 3/7 部分）

## 发现

### [一般][存量] #1 同一份 `tasks.md` 对 xmlconf Gate A 给出相反结论：12.5 记「未达成」，10.2 / 8.10 记「已达成」

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/tasks.md:350`（12.5「xmlconf 的 Gate A 未达成」）；同文件 `:294-296`（10.2「**已达成**：实测 `pass=2038 fail=0 unsupported=524`」）、`:218`（8.10 同样记达成）
- **来源**：存量（工作区快照，无基线可比；12.5 是第三轮修订前的文字，10.2 重写后未回填）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」、§11「契约与实现不符」
- **证据**：静态确定 —— 12.5 是本文件唯一一处「未达成」，而 10.2 勾选并给出三数字，`implement-f-xml-m1/baseline.md:1-12`（「当前基线（Gate A 已达成）」）与 `implement-f-xml-m1/verification.md:12`（`pass=2038`、`fail=0`）一致指向达成。12.5 的括注还写「见 10.2 与 baseline.md」，而那两处结论都与它相反
- **描述**：读者按任务表核对验收状态会得到互斥答案。这不是措辞问题：Gate A 是整个变更的出口条件，验收记录自相矛盾会让「是否可归档」无法复核
- **建议**：把 12.5 改为「Gate A 已达成（见 10.2）」；若想保留历史，写成「首轮基线未达成（见 `baseline.md` §2），第三轮后达成（见 §1）」，不要在同一句里给单值结论

### [一般][存量] #2 `f-xml-writer` 规格要求 UTF-8 走 `StringWriter` + `StringGenerator.unsafeBytes()`，实现已整体换成 `ByteScratch`，且无任何偏离登记

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:143`（「UTF-8 SHALL 走 `std.io.StringWriter` + `StringGenerator.unsafeBytes()` 直接写字节」）
- **来源**：存量（工作区快照；后一次变更 `reuse-f-xml-writer-scratch` 改了实现但没改这条 SHALL）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全模块 `grep -rn StringWriter f_xml/src` **0 命中**；实际实现是 `f_xml/src/XmlWriter.cj:51` `private let buffer = ByteScratch()` 与 `XmlWriter.cj:311` `this.output.write(this.buffer.bytes()[0 .. this.buffer.size])`；`reuse-f-xml-writer-scratch/design.md:43-53`（D1）明确「`XmlWriter` 缓冲换成 `ByteScratch`」，但该变更的 `proposal.md:19` 只声明「公开 API 不变」，`specs/xml-writer-output/spec.md` 也未声明覆盖 / 作废 writer spec 的这条要求。同一 Requirement 内「SHALL NOT 用 `writeln()`」仍然成立（`writeln` 全模块 0 命中）
- **描述**：两条 SHALL 中一条已永久不可满足（没有 `StringWriter`），另一条成立。规格是归档契约，后续按 spec 审计会把现状判成违约；反过来若有人照 spec 恢复 `StringGenerator` 缓冲，则与 `reuse` 变更的实测结论（`design.md:5-25`：`append(Rune)` 每字符 68 B）冲突。这是本部分最硬的一处「SHALL 与实现相反」（另一处相关表述见 #12 的 `close()` 契约）
- **建议**：在 writer spec 该行补注「已于 `reuse-f-xml-writer-scratch` 改为复用 `ByteScratch`，输出字节不变（见其 spec / design）」；或按 `optimize-f-xml-semantic-layer/verification.md:119-125` 的既有做法，在 reuse 变更的 `verification.md` 里单列一张「与既有 spec 的偏离登记」表并把这条登记进去

### [一般][存量] #3 DOM 侧两个公开递归入口（`text()` / `XmlWriter.write*`）没有深度契约，程序化构造的 DOM 可栈溢出

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md:69`（`text(): String`（拼接所有后代文本））、`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:11-12`（`write(doc)` / `write(element)`）
- **来源**：存量（工作区快照；规格与实现同批落地，缺的是「限制」这一段）
- **判据**：review-checklist §4「无界递归 / 深度由输入决定」、§11「边界差一 / 越界」；§14.2「缺关键段落：限制与注意事项」
- **证据**：静态确定 —— 实现按层递归：`f_xml/src/XmlNode.cj:234-240` `text()` 调 `collectText`，`:240-249` 对每个 `ElementNode` 递归自身；`f_xml/src/XmlWriter.cj:465-497` `writeElement` → `:502-508` `writeNodeWithName` → `writeElement`。上游没有任何深度护栏：`XmlElement.appendChild`（`XmlNode.cj:172`）、`XmlDocument.root`（`XmlNode.cj:277`，`public var`）都可程序化设置任意深度；解析侧唯一的深度限制 `XmlOptions.cj:146` `maxElementDepth = 4096` 是**用户可配**且无上限校验（`:153` 直接赋值）
- **描述**：解析产物默认受 4096 层约束，按 4096 层估算递归深度通常安全；但规格把 `text()` / `write()` 定义为可接受任意 `XmlElement` / `XmlDocument`，而 DOM 是公开可变的，调用方（或把 `maxElementDepth` 调高的解析结果）构造出深链后调用 `text()` / `write(element)` 就是无界递归——没有拒绝路径、没有告警，后果是进程崩溃而不是异常。规格对这一层完全沉默，使用者无法从文档得知「必须自己保证深度」
- **建议**：规格补一条显式约定，二选一：(a) 要求实现改成显式栈迭代，文档写明「任意深度安全」；(b) 声明「递归实现，调用方 SHALL 保证深度 ≤ N（N 与 `maxElementDepth` 默认值一致），超限行为未定义」并在 `text()` / `write()` 的注释里重复。倾向 (a)：这两处都只是树的先序遍历，改迭代成本低且能同时消掉 `maxElementDepth` 被调高后的隐患

### [一般][存量] #4 Gate C 承诺「每次运行把 unsupported 的 ID 清单存档」，harness 只写 fail 清单

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-conformance/spec.md:171`（Gate C 行：「每次运行输出 `pass / fail / unsupported` 三个数字，并把 `unsupported` 的 ID 清单存档」）、`:193-196`（Scenario「Gate C 三数字」重复同一要求）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3「公开契约承诺有行为，实现缺失」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `f_xml/src/XmlconfHarness_test.cj:110` 只 `println` 三数字；`:114-119` 只写 `cache/failures.txt`（fail 清单），全文件没有任何写 unsupported 清单的语句；`unsupported` 的 ID 集合只存在于生成脚本一次性产出的 `cache/unsupported.json`（`tools/xmlconf_gen.py` 另生成入库的 `doc/xmlconf-unsupported.md`）。同目录 `tasks.md:147-148` 反而写明「harness 只读缓存并计数」，与 spec 的 Gate C 直接冲突
- **描述**：数据本身没有丢——`unsupported.json` / `xmlconf-unsupported.md` 可复核（本部分已核对：524 行，`edition 313 / external-entity 95 / xml-1.1 59 / external-subset 47 / namespace-name 10` 与 spec 完全一致）。缺的是「每次运行留档」这个动作，因此 Gate C 的「可追溯」实际只覆盖 fail 一侧；换一套缓存重建后，运行记录里查不到当次被判 unsupported 的具体 ID。按后果（无运行时影响、数据可另取）记一般，不判严重
- **建议**：harness 增写 `cache/unsupported.txt`（一行一个 ID，与 `failures.txt` 同处），或在 spec 侧把口径改成「`unsupported` 清单由 `xmlconf_gen.py` 存档，harness 只断言计数」并同步该 Scenario——两者选一，不要保持「承诺了但没人做」

### [轻微][存量] #5 8.11 的残差条数（12）与 §13 / `baseline.md` 的分解（13）不符，归因也错位

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/tasks.md:234-236`（「`not-wf` 被接受从 385 条降到 60 条…余下 12 条由 8.9 / 8.12 / 8.13 收敛」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「近似重复导致的口径漂移」（同一条收口链在两处给出不同结论）
- **证据**：静态确定 —— 同文件 `:366-369` 写「余下 13 条里 11 条由实现修正收掉（B1 2 + B2 1 + B4 7 + B5 1）、2 条（`rmt-ns10-043` / `-044`）由 `namespace-name` 排除」；`implement-f-xml-m1/baseline.md:78-84` 的算式是 `385 − 325 = 60`、`60 − 47 = 13`、`13 − 2 − 11 = 0`。三条都指向 13，只有 8.11 写 12。归因同样不符：B1（BOM 与 `encoding` 冲突）、B2（内部子集条件段）不在 8.9 / 8.12 / 8.13 名下，8.9（standalone 三档）在这 13 条里贡献为 0
- **描述**：8.11 是「声明语法校验」这项工作的收口记录，读者据此判断剩余不良构去向会数错 1 条，并把 2 条排除规则的功劳记到实现任务上。最终 `fail = 0` 已被 `baseline.md` / `verification.md` 复核，故只记轻微
- **建议**：改为「余下 13 条：11 条由 B1 / B2 / B4 / B5 实现修正收掉，2 条由 `namespace-name` 规则移出」，与 `baseline.md` §3 的算式逐项对齐

### [轻微][存量] #6 `optimize-f-xml-semantic-layer/baseline.md` 50 MB 行的事件数与记录数不满足它自己声明的不变式

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:34`（50 MB 行：事件数 `3 726 208`、记录数 `1 247 399`）、同文件 `:39-40`（不变式「`events = 3 × records + 4`」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档数值不一致」、§11「与规格 / 文档记载冲突」
- **证据**：静态确定 —— `3 × 1 247 399 + 4 = 3 742 201`，与表内 `3 726 208` 差 `15 993`（恰好 `5 331 × 3`，即 5 331 条记录）；同一张表的 1 MB（`80 311 = 3 × 26 769 + 4`）与 10 MB（`764 857 = 3 × 254 951 + 4`）两行都严格成立
- **描述**：这张表是 Gate T / Gate M 的改前对照引用源，其中一列抄错会让「事件数校验」这个自检形同虚设；也说明当时没有真的按不变式复算 50 MB 一行。由于 Gate 只引用时间与 `VmHWM`，不影响门禁结论，记轻微
- **建议**：复跑 50 MB 或用例输出（`PerfFifty_test` 打印项）核对后订正事件数或记录数，并在表下注明「两列以用例输出为准」

### [轻微][存量] #7 `baseline.md` 三处未随实测回填：协议「每档 5 次」、标题「待补」、「只有 2 个不同字面名」

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:51-53`（协议第 4 条「每档 5 次、每次独立进程、取 `min`」）、`:42`（小节标题仍写「同轮实测（**待补** …）」）、`:112`（「`readName` … **只有 2 个不同字面名**」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档与自身协议不一致 / 文档过期」、§6.1「测量口径必须可复核」
- **证据**：静态确定 ——
  - 协议要求每档 5 次，但 `:65-67`、`:77-81` 的 1 MB 与 50 MB 只有 `run1`（其余 `—`，`:67` 括注「50 MB 单次」），`:69` 仍称「均无负载污染（阈值 1.4）」——单次测量算不出 `max/min`。`design.md:96` 只对 50 MB 声明单次（`PerfFifty_test` 1 次），1 MB 的单次没有任何依据。
  - `:42` 标题写「待补」，而 `:56-81` 已填两组实测值、文件头 `:6-8` 也声明「§3 已补齐」。
  - `:112` 写「2 个不同字面名」；同变更 `tasks.md:77` 与 `f_xml/src/Lexer_test.cj:157,170` 都按 **3** 个（`item` / `id` / `a`）断言。
- **描述**：三处都是「实测出来后没回头改估算 / 协议 / 标题」。第 3 条把名字驻留的收益面写小了一个（4 次 `readName` 只对应 2 个不同名字，实际 3 个），会让读者误判驻留覆盖度；第 1 条把「单次」说成「无污染」，读者第一反应会是「作者算过波动」。均不影响 Gate 结论（10 MB 的 5 次值齐全），但误导证据强度
- **建议**：`:51-53` 限定为「10 MB 5 次；1 MB / 50 MB 各 1 次，不参与 `max/min`」并删掉 `:69` 的「均」；`:42` 去掉「待补」；`:112` 改为「3 个不同字面名（`item` / `id` / `a`）」

### [轻微][存量] #8 `StringGenerator.unsafeBytes()` 的语义在两份归档 spec 里被描述成互斥的两件事，而其中一侧正是 `ByteScratch` 的立论依据

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:94`（「`StringGenerator.unsafeBytes()` 返回**按 size 截好的新数组**…每次驻留比对都会分配」）与同目录 `design.md:425`（D16 同义）；对照 `f_xml/doc/spec/reuse-f-xml-writer-scratch/design.md:12`（「`unsafeBytes()` 返回的是按 size 截好的**数组视图**」＋「**没有** 16 KB 的整块复制」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「同一事实两种表述导致决策漂移」
- **证据**：文档互斥（静态确定）；实现侧 `f_base/src/StringGenerator.cj:265-267` 是 `utf8.unsafeData()`（`ArrayList` 底层存储直取，方法体内无复制语句），`reuse` 侧实测（`reuse design.md:5-12`：64 次 × 16 KB 刷写总分配 20 080 B）只能用「共享存储、不复制字节」解释。**待确认**：`ArrayList.unsafeData()` 每次是否仍产生一个小的视图对象（本机 `~/.autocode/cj/doc` 不可用，无法查标准库语义），这一点决定「每 token 分配一次」是否成立
- **描述**：一侧说「新数组（会分配）」、一侧说「视图（无整块复制）」。两种描述若都按字面理解，D16「因此名字扫描必须改用 `ByteScratch`」与 D1「因此 `XmlWriter` 不必改 flush」就至少有一条立据错误；后续按文档继续复用（例如给文本缓冲也换 `ByteScratch`）会得出相反结论。代码本身行为不受影响（`BufferReuse_test` 有逐字节对拍），故记轻微
- **建议**：统一为「返回共享底层存储的视图；是否每次新建视图对象需实测」，两处互相引用同一句结论，并注明探针（填 10000 取 10000、reset 后 append 1 取 1）说明的是「长度跟随 size」而不是「发生拷贝」

### [轻微][存量] #9 `optimize-f-xml-semantic-layer/verification.md` 章节编号重复且乱序（两个 `## 6.`，且第二个排在 `## 8.` 之后）

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md:96`（`## 6. Scenario → 用例对照`）、`:127`（`## 8. 遗留项`）、`:133`（`## 6. verify 收口（2026-10-30）`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「结构 / 引用失效」、可维护性
- **证据**：静态确定 —— 文档出现 `1,2,3,4,5,6,7,8,6` 的编号序列；末尾的收口表（W1 / S1–S5）是最后追加的一节，未重编号
- **描述**：验收记录被其他部分引用（`design.md:10` 指向「`verification.md` §2」），编号错乱会让「§6 指哪一节」产生歧义；不影响结论
- **建议**：收口节改为 `## 9. verify 收口`，或整体重排为 1–9

### [轻微][存量] #10 `design.md` §11 承诺「实施后回填实际值」，用例数仍停在估算区间 22–28（实测 39）

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md:435`（「上一轮 `README.md`「337 条」→ 本变更在此基础上新增约 22–28 条 → **实施后回填实际值**」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档过期」、§14.2「版本与命令过期」同类
- **证据**：静态确定 —— `verification.md:76`「改动前 337，新增 39」、`:83-94` 的分布表（7+8+13+4+1+1+2+3 = 39）与本文件 `:435` 的 22–28 相差 11–17 条
- **描述**：这是 design 自己写明的回填义务，未执行。读者若按 design 估算新增规模会低估 40%；`proposal.md:143` 的同区间属提案期估算，可保留，但 design 的「回填」承诺应兑现
- **建议**：回填「实测 +39（`cjpm test` 337 → 376）」，保留原估算区间并标注为估算

### [轻微][存量] #11 三份文档的「文件清单 / 路径」陈述与仓库现状不符（4 处）

- **位置**：`implement-f-xml-m1/tasks.md:144`、`:185`；`implement-f-xml-m1/specs/f-xml-conformance/spec.md:22-24`；`optimize-f-xml-semantic-layer/tasks.md:95-96`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「链接 / 路径失效」、§14.1「文档过期」
- **证据**：静态确定 ——
  - `tasks.md:144` 写「写 `src/XmlconfHarness_test.cj` + `src/TestDataRoot.cj`」，`f_xml/src/TestDataRoot.cj` 不存在；`TestDataRoot` 定义在 `f_xml/src/TestDataRoot_test.cj:32`（`internal class`）。
  - `tasks.md:185` 写「→ 实现 `src/SpillDir.cj`」，该文件不存在；`SpillDir` 定义在 `f_xml/src/ExpandSink.cj:30`（四级目录顺序 `:27-47` 与 spec 一致）。
  - `spec.md:22-24` 写「版本库 SHALL 只保留三样：`xmlconf_gen.py`、`known-issues.json`、`xmlconf-unsupported.md`」，`git ls-files f_xml/tools` 实际命中四份（多 `test_xmlconf_gen.py`，且 `baseline.md:18` 明确引用它的 4 条用例）。
  - `tasks.md:95-96` 写 grep「只剩 … 白名单里的位置（`collapseSpaces` 等 **4 处**）」，`design.md:227-235` 的实测复核是 **3 处**（`Lexer.cj:72,143,145` 实测一致），白名单表本身 4 行但跨 4 个不同文件。
- **描述**：四处都是「任务写完后实现换了落点 / 后续变更增了文件，文档不回填」。第 1、2 条会让按文档找实现的读者直接扑空；第 3 条规定了一条现在被违反的入库规则（照它执行会误删 Python 用例）；第 4 条把「白名单 4 条（跨文件）」与「`Lexer.cj` 内 3 处命中」混为一谈。均为文档问题，无功能影响
- **建议**：`tasks.md:144` 改 `TestDataRoot_test.cj`；`:185` 改「实现于 `src/ExpandSink.cj` 的 `internal class SpillDir`」；`spec.md:22-24` 改为「生成脚本 + 人工裁定文件 + Python 用例 `tools/test_xmlconf_gen.py` 一并入库」；`tasks.md:95-96` 改为「`Lexer.cj` 内剩 3 处（白名单跨 4 个文件）」

### [轻微][存量] #12 `f-xml-writer` spec 的公开 API 清单与 `close()` 契约落后于实现

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:9-13`（成员清单）、`:15-16`（`close()` 后为「未定义行为」）、`:20-23`（`close` Scenario）
- **来源**：存量（快照；spec 随 `622f0c2c6` 入库，增量接口随 `9066e1cd7` 加入，spec 未回填）
- **判据**：review-checklist §13「契约与实现不符」、§14.2「公开 API 未文档化」
- **证据**：静态确定 ——
  - spec 成员清单只有 `init` / `write(doc)` / `write(element)` / `flush` / `close`；实现另有 5 个 `public` 方法：`writeDeclaration`（`f_xml/src/XmlWriter.cj:168`）、`startElement`（:184）、`endElement`（:207）、`text`（:234）、`emptyElement`（:245），`README.md:124` 已文档化，但 `doc/spec/**` 无任何 spec 覆盖这批接口。
  - spec:15-16 称 close 后调用「未定义行为」；实现是确定性行为——`close()` 之后任何入口走 `ensureOpen()` 抛 `XmlException("XmlWriter 已关闭，不得再调用")`（`XmlWriter.cj:295-299`），`close()` 自身幂等（`XmlWriter.cj:277-279`）。`README.md:417` 同样写「未定义行为」，两份文档一起偏离实现。
  - spec:20-23 只写「写入后 `close()` → 底层收到全部字节并被 flush」；实现里仍有未闭合元素时 `close()` **先抛** `XmlException("有 N 个元素未闭合，不能关闭 XmlWriter")`（`XmlWriter.cj:278-282`），底层既不 flush 也不 close。该行为只写在 `README.md:100,300`。
- **描述**：这份 spec 是 `XmlWriter` 的对外契约，读者按它无法得知：(a) 存在增量写入接口；(b) close 会因未闭合元素失败且失败后底层流未 flush；(c) close 后的调用是可捕获异常而不是 UB（UB 的说法会让人不去 catch）。三者都是使用者会踩的路径
- **建议**：补 5 个增量方法各 1 条 Scenario（增量与整树不可混用）；`close()` 段改为「冲刷 → flush → 关闭底层；若仍有未闭合元素则抛 `XmlException` 且**不**关闭底层」；把「未定义行为」改为「抛 `XmlException`」，与实现对齐并同步 README

### [轻微][存量] #13 `f-xml-dom` spec 用 `prop` 描述实际为 `let` / `var` 的字段，其中三个字段可写

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md:62-64`、`:85-89`
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档与实现不符」、语言特性（`prop` 与字段的区别）
- **证据**：静态确定 —— spec 写 `prop name` / `prop attributes` / `prop children`、`prop root` / `prop declaration` / `prop doctype` / `prop prolog` / `prop epilog`；实现是 `public let name`、`public let attributes`、`public let children`（`f_xml/src/XmlNode.cj:149-151`）与 `public var root` / `declaration` / `doctype`（`XmlNode.cj:277-279`）、`public let prolog` / `epilog`（:281,283）
- **描述**：仓颉里 `prop` 是计算属性，字段声明是 `let` / `var`。更实质的是 `root` / `declaration` / `doctype` 是 `var`——使用者可整体替换根元素或声明，spec 的 `prop` 写法会让人以为只能读；`prolog` / `epilog` 是 `let` 容器（可 add 不可换），也不是 `prop`
- **建议**：8 处改为字段写法；对 `root` / `declaration` / `doctype` 明确「可写（`var`）」，对 `prolog` / `epilog` 注明「容器只读、内容可变」

### [轻微][存量] #14 `reuse-f-xml-writer-scratch` 缺 tasks.md 与 verification.md，验收无书面记录

- **位置**：`f_xml/doc/spec/reuse-f-xml-writer-scratch/`（仅 `design.md`、`proposal.md`、`specs/xml-writer-output/spec.md`）
- **来源**：存量（`639046e37` 已入库）
- **判据**：review-checklist §14（可追溯 / 产物完备），对照同目录另两个变更的六件套结构
- **证据**：静态确定 —— `implement-f-xml-m1/` 与 `optimize-f-xml-semantic-layer/` 均含 `tasks.md` + `verification.md`；本变更两者都缺。`design.md:84-92` 承诺的验收项（多段刷写逐字节一致、`≤ 8 B/rune`、基线高 8 倍）只在 `f_xml/src/XmlWriterScratch_test.cj:164-227` 的断言里，无实测数值与运行环境记录
- **描述**：代码与用例都在（`ByteScratch.cj:30-107` 已有 `append(text)` / `putCp` / `reset` / `bytes` / `toUtf8String`），行为契约也有 spec，唯独缺「这条变更怎么验收的」这一层。后续若质疑 8 B/rune 的来源，只能重跑用例
- **建议**：补一份极简 `verification.md`（实测 `allocPerRune`、基线比值、`cjpm test` 条数、`-O2` 档位）；`tasks.md` 可只列已完成项，重点是让三个变更的产物结构一致

> 存量缺陷共 **14 条**（一般 4 / 轻微 10），是否纳入修复待用户决定。本部分全部结论基于工作区快照，无「本次改动」项。

**范围外提示**（不占本部分统计）：

- `f_xml/src/NameTable.cj:82` 的注释「表内不同名字数即 `insertions`，不另设计数」与 `:66` 的 `prop distinct` 矛盾（属实现文件，留给对应部分）。
- `f_xml/src/Lexer_test.cj:171-172` 连续两次断言 `insertions`（第二条消息写「distinct 应为 3」），`NameTable.distinct` 在该用例里实际未被断言——核对 `verification.md` S3 收口声明时撞见，属 part5 覆盖。

## 优化可行性方案

> 本部分没有新增可执行方案。文档已自带 `-O2` 同轮对照数据（10 MB `1026.4 → 497.0 ms`、`VmHWM(50 MB) 295 136 → 104 280 kB`），且 `design.md` §8 的 B1–B4 / M0–M4 阶梯在 `verification.md:53-58` 已记录「一级未用」。在没有新的 profile 数据前再提方案，只会变成无基线的猜测，按铁律只进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 名字驻留表达到 `maxEntries = 65536` 后硬停插，若文档的唯一名字数超过上限（如每行名字都不同），驻留命中率崩溃、10 MB 耗时会回到 1 s 量级 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md:70-71`（上限与降级口径）、`f_xml/src/NameTable.cj:117` | 唯一名字数 ∈ {1k, 10k, 65k, 200k} 时的 `hits/misses` 与 10 MB 耗时曲线 | `cjpm bench -O2` 跑合成流（把 `<item>` 换成唯一名字），同时打印 `NameTable.distinct` |
| 2 | 长名字（> 256 B，触发 `ByteScratch` 扩容）下，名字驻留的收益被逐字节比对与扩容拷贝吃掉 | `design.md:133`（容量翻倍）、`:237-255`（`ByteScratch` 只增不减） | 名字长度 8 / 64 / 512 B 三档的分配量与耗时 | `F_XML_BENCH=1` 或 `cjprof record`，对比 `StringGenerator` 路径 |
| 3 | 文档记录的 497.0 ms / 104 280 kB 在当前 HEAD 仍成立（采集于 2026-10-30，之后 `f_xml` 又有 reuse-writer 与增量写入两次提交） | `f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md:11-14` | 当前 HEAD 的同轮值 | 空载机、默认运行时（`env | grep -iE '^cj(...)'` 为空），`F_XML_PERF=1 cjpm test --filter=PerfTen_test` / `--filter=PerfFifty_test`，各取 `min(5)` 与 `VmHWM` |

## 文件覆盖

> 与 `{workdir}/files/f_xml.part3.txt` 一一对应（16 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-conformance/spec.md` | .md | ✅ | 五条规则 313/95/59/47/10、2062/2038/524 与 `doc/xmlconf-unsupported.md`（524 行，按原因求和一致）核对通过；Gate C 见 #4，「三样入库」见 #11 |
| 2 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md` | .md | ✅ | `QName` / `XmlElement` / `XmlDocument` 公开面与 `XmlNode.cj` 逐项一致；`text()` 深度契约见 #3；`prop` 写法见 #13 |
| 3 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dtd-entities/spec.md` | .md | ✅ | 三层上限默认值（64 KB / 8 MB / 16 / 1024 / 2 GB）与 `XmlOptions.cj:103-108` 完全一致；XXE（`EntityExpander.cj:73,293`）、条件段拒绝、`AttributeValue`（`ExpandSink.cj:160`）、四级 spill 目录（`ExpandSink.cj:27-47`）均已在实现中取证 |
| 4 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-stream-parser/spec.md` | .md | ✅ | `maxElementDepth = 4096` / `maxAttributeValueLength = 1 MiB` 与 `XmlOptions.cj:146-147` 一致；`XmlEvent` 只实现 `ToString`（`XmlEvent.cj:27`）符合「SHALL NOT Equatable」；拉模式三方法在 `XmlPullParser.cj:42,52,56` |
| 5 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md` | .md | ✅ | 转义表与 `Escaper.cj:25-63` 逐格一致；16 KB 刷写门限（`XmlWriter.cj:64`）在 8–64 KB 区间内；`StringWriter` 见 #2，API 清单 / close 契约见 #12，写方向深度见 #3 |
| 6 | `f_xml/doc/spec/implement-f-xml-m1/tasks.md` | .md | ✅ | 12.5 与 10.2 冲突见 #1；8.11 残差见 #5；`TestDataRoot.cj` / `SpillDir.cj` 路径见 #11 |
| 7 | `f_xml/doc/spec/implement-f-xml-m1/verification.md` | .md | ✅ | 303 用例 / 20 WARNING 与 `complete-f-xml-m1-followups/verification.md:16-21` 的「303 → 337、20 → 21」衔接一致，无问题 |
| 8 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md` | .md | ✅ | 50 MB 事件数见 #6；协议 / 标题 / 名字数见 #7；`unsafeBytes` 措辞见 #8 |
| 9 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md` | .md | ✅ | §5.2 声称 `grep -n 'StringGenerator()' src/Lexer.cj` 只剩 72 / 143 / 145 三处 —— 实测**完全一致**；D16 见 #8；§11 回填见 #10 |
| 10 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/proposal.md` | .md | ✅ | 估算区间（22–28 条）属提案期数字；「改前」列混用 §2（旧基准）与 §3.1（零分配基准）两套口径（1 MB 80.1 vs 118.6 ms、50 MB 5422.6 vs 5322.9 ms）仅 10 MB 行标注了差异，并入 #7 的建议 |
| 11 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/specs/f-xml-semantic-layer/spec.md` | .md | ✅ | `NameTable` 计数（`hits/misses/insertions/distinct`）与 `NameTable.cj:61-66` 一致；上限降级口径一致 |
| 12 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/tasks.md` | .md | ✅ | 0.3 / 0.4 的实测结论与 `baseline.md` §3.1–3.3 互相印证；3.4 的白名单「4 处」见 #11 |
| 13 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md` | .md | ✅ | 数字自洽（337+39=376、497.0/1026.4=0.484、−64.7%）；章节编号见 #9 |
| 14 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/design.md` | .md | ✅ | `ByteScratch` 的 `enc`（4 B）、`putCp` / `reset` / `bytes` / `toUtf8String` 与 `ByteScratch.cj:30-107` 一一对应；`append(text)` 已存在（`:72`）；`unsafeBytes` 措辞见 #8 |
| 15 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/proposal.md` | .md | ✅ | 与 design / spec 口径一致；未登记对 writer spec 的覆盖（见 #2） |
| 16 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/specs/xml-writer-output/spec.md` | .md | ✅ | 三条 Requirement 的实现均已在 `Escaper.cj:25-63` / `XmlWriter.cj:306-319` 取证；基准断言见 `XmlWriterScratch_test.cj:220-227`；缺 verification 见 #14 |

合计：`.cj` 0 个 / `.md` 16 个 / 共 16 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #1 #5 #6 #7；设计 #2 #4 #11；语言特性 #13；可读性 #9 #12；安全性 #3。安全性另做专项取证：XXE 不读文件（`EntityExpander.cj:73,293`）、外部子集不发请求（全模块无网络 API，`File` 只用于 spill）、转义表逐格对齐（`Escaper.cj:25-63`）、非法字符拒绝带元素 / 属性名，均无新缺陷 |
| §1 死代码 | 0 | 本部分无 `.cj`，改做「文档引用的符号是否仍存在」：`QName`、`attr(ns,local)`、`child`、`childrenOf`、`setAttr`、`withText`、`text`、`prolog` / `epilog` / `declaration` / `doctype` / `root` 全在 `XmlNode.cj:162-234, 276-284` 命中；`StringWriter` 反向 0 命中即为 #2 的证据；未命中的 2 条路径已并入 #11 |
| §2 重复逻辑 | 1 | #8（同一 `unsafeBytes` 事实在两份 spec 里给出相反描述）。另逐条比对：五条排除规则在 spec / tasks / baseline / `xmlconf-unsupported.md` 头部 / `xmlconf_gen.py` 注释 5 处陈述，阈值与措辞一致（313/95/59/47/10、2586/2062/2038/524）；Gate 阈值在 baseline §2/§7、design §1.1、proposal F、semantic spec 4 处重复，`1000 ms` / `262144 kB` / `0.95` 一致（`256 MB` 与 `262 144 kB` 为等值换算，不判重复） |
| §3 空实现 | 1 | #4（Gate C 的清单存档动作缺失） |
| §4 栈溢出 | 1 | #3（`text()` / `writeElement` 递归无深度契约）；解析侧 `ParserEngine.cj:278` 按 `maxElementDepth` 检查、`DomBuilder.cj:27` 用迭代建树，已排除 |
| §5 OOM | 0 | 三层上限（64 KB / 8 MB 软，16 / 1024 / 2 GB 硬）与 `Spill` 溢出策略均为有界设计，默认值与 `XmlOptions.cj:103-108` 一致；`Spill` 下内存恒定、2 GB 上限落磁盘不落堆；未见「按不可信长度预分配」的规格承诺 |
| §6.1 热点瓶颈 | 0 | 本部分文档自带 `-O2` 同轮实测，本轮无新的 profile / bench，故不新增热点结论；未验证项进「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 文档未承诺任何锁语义，`f_xml` 解析器为单实例单线程使用（计数器已实例化，`EntityCounterIsolation_test` 覆盖） |
| §6.3 并发串行 | 0 | 无 `spawn` / 任务提交相关承诺 |
| §6.4 低效算法 | 0 | 文档记录的批量扫描（`asciiRunLength` / `skipRun` / 掩码）与 `LineWindow` internal 块视图已在实现中落地（`design.md:259-343` 对照 `LineWindow.cj` 成员），规格与实现同向 |
| §7 降堆内存方案 | 0 | 现有方案（名字驻留 + 三缓冲复用 + 基准零分配）已有改前 / 改后数据（295 → 104 MB），无基线的新方案不写入本节 |
| §8 降 CPU 方案 | 0 | 同上（1026.4 → 497.0 ms 已达成）；B1–B4 阶梯未启用，缺数据前不列为方案 |
| §9 local mode 可行性 | 0 | `reuse-f-xml-writer-scratch/design.md:5-12` 已用实测否掉 `XmlWriter.flush` 的 local / 复用收益（313 B/次，无 16 KB 复制）；无新增可评估函数 |
| §11 现有代码的 BUG（存量） | 14 | 本部分全部 14 条均为存量文档缺陷（无 `.cj`）；每条均已给位置 / 判据 / 证据等级 |
| §12 并发安全与锁粒度 | 0 | 文档只承诺「计数器实例级、非全局」（dtd-entities spec §计数器实例级），与 `ParserEngine` 实例字段一致；无共享可变状态承诺 |
| §14 功能完备性与 README 覆盖 | 3 | #4（承诺的存档动作未实现）、#11（文件清单 / 入库规则过期）、#14（变更缺验收记录）；`README.md:417` 与 `XmlWriter.cj:42` 的「close 后不得再调用」与 spec 一致（但其「未定义行为」表述见 #12） |
| 文件覆盖（§13 等） | 16/16 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 16 份文档的质量明显高于仓库平均水平：每个变更都有「proposal / design / spec / tasks / baseline / verification」六件套（`reuse` 缺后两件，见 #14），性能结论带 `-O2` 同轮新旧对照与 `max/min` 离散度，spec 的每个 Scenario 都能在 `verification.md` 里映射到用例名。本轮抽查的默认值（64 KB / 8 MB / 16 / 1024 / 2 GB、4096、1 MiB）、公开 API 面（`QName` / `XmlElement` / `XmlDocument`）、xmlconf 口径（524 条，313/95/59/47/10）、`Lexer` 的 `StringGenerator()` 三处残留，**全部与代码一致**——说明文档不是事后补写的。

风险不在「写错」，而在「改完没回填」：#1 / #5 / #6 / #7 / #10 / #11 都是同一类问题——第三轮修订或后续变更落地后，任务状态、残差条数、测量协议、事件数、估算区间、文件路径没有回填。建议在合并报告里作为一条流程建议提出（每次变更收口时对 `tasks.md` / `baseline.md` 做一次数值复算与路径核对），而不是按六处独立缺陷排期。

真正需要动作的是三条：#2（writer spec 的 `StringWriter` SHALL 已永久不可满足，必须补偏离登记，否则后续审计会把现状判成违约）、#3（`text()` / `write()` 对程序化构造的 DOM 无深度契约，属可崩溃面，建议改迭代并在 spec 写明）、#4（Gate C 少了 unsupported 清单留档，补一个写文件或改口径即可）。#12 与 #2 同属 writer spec，建议一并处理。四条都不阻塞本次归档，也不需要回滚任何已发布行为。

无严重项，无数据丢失 / 安全漏洞 / 并发缺陷。存量 14 条，是否纳入修复待用户决定。
