# Tasks — optimize-f-xml-semantic-layer

> **唯一入库副本**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/`。`openspec/changes/optimize-f-xml-semantic-layer/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 7.4）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/optimize-f-xml-semantic-layer/ openspec/changes/optimize-f-xml-semantic-layer/`
> 校验：`diff -ru f_xml/doc/spec/optimize-f-xml-semantic-layer openspec/changes/optimize-f-xml-semantic-layer` 无输出。
>
> 实施遵循 TDD：**先写失败用例，再实现**。每条任务单独可验收，完成即独立提交
> （仓库约定「有单元测试后再提交」）。
> **分支**：`feature/f_xml_semantic`（开工前 `git branch --show-current` 确认、`git pull`）；
> **不自动 merge、不自动 push**——全部验收通过后由用户确认再 `git merge --no-ff`。
> **边界**：只改 `f_xml/`；不动 `f_base` / `f_io`；不新增依赖；**不改任何 `public` 声明**；
> **不设置任何 GC 环境变量**。

## 0. 前置（0.3 是硬门禁，未完成不得进入第 6 节）

- [x] 0.1 记录环境：`git rev-parse HEAD`、`uname -r`、`nproc`、Cangjie SDK 版本、
  `env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'`（必须为空）、`f_xml/cjpm.toml` 的 `-O2` 在位。写入 `baseline.md` §3.1 表头。
- [x] 0.2 **公开声明快照**：`grep -rn '^public ' f_xml/src --include='*.cj' | sort > /tmp/f_xml_public_before.txt`，
  记下条数。这是 7.3 的对比基准。
- [x] 0.3 **同轮旧代码基线（临时）**：在未改动的 `HEAD` 上用现有 `Perf_test`
  （`F_XML_PERF=1 cjpm test --filter=Perf_test`，10 MB × 3）先记一版临时值，
  填入 `baseline.md` §3.1 并标注「临时，待 1.4 用新基准替换」。
  - **已执行**：临时值 10 MB `min ≈ 1068.4 ms`（3 次），与 1.4 的权威值 1026.4 ms 同量级。
  - 权威基线由 1.4 产出（新基准 + `git archive HEAD` 到临时目录 `f_xml_old/`，测完即删）；
    0.3 的临时值只用于判断量级，不用于 Gate 判定。
- [x] 0.4 **微基准：`StringGenerator.reset()` 是否保留容量**。写临时用例：
  1 亿次 `reset + append(Rune(0x41))`，每 1000 万次打印 RSS 与累计耗时。
  若 RSS 单调增长（> 50 MB）或耗时随次数上台阶 ⇒ `clear()` 释放了底层数组 ⇒ 第 3 节启用
  `ByteScratch`（`design.md` §5.3）。结论写进 `design.md` §5.1 与 `baseline.md` §3.3。
  - **实测结论：保留容量**（复用 111.6 ms vs 每次新建 115.9 ms，RSS +60 kB / 500 万次），
    文本 / 值走 `reset()` 复用；名字另用 `ByteScratch`（`unsafeBytes()` 会拷贝，见 D16）。
- [x] 0.5 **预算核对**：用一次性临时用例统计 1 MB 文档上 `readName` / 文本 / 属性值各调用
  多少次、`StringGenerator()` 构造多少次，与本仓模板算式（254 951 × 7）和用户口径（~230 万）
  对齐；差异 > 20% 时查明原因写进 `baseline.md` §4。
- [x] 0.6 确认一致性基线可用：`cjpm test` = 337 条全绿；
  `python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v` = 4 条全绿；
  xmlconf 缓存（`f_xml/.cache/xmlconf/cases.json`）存在且 Gate A 当前为 2038 / 0 / 524。

## 1. 先决条件：基准零分配（否则 Gate 不可信）

- [x] 1.1 **先写失败用例** `src/Perf_test.cj` 追加 `syntheticStreamGolden`：
  用内置的**旧实现**（`recordText(n).toArray()` 再逐字节比较）产出参照字节流，
  断言新 `read()` 的字节序列逐字节一致。覆盖 1 KB、64 KB、以及条数跨 9→10 / 99→100 的
  进位点（构造 `targetBytes` 使最后一条记录的 `N` 位宽发生变化）。
  → 预期红（新实现未写）。
- [x] 1.2 改 `SyntheticXmlStream.read()`：记录逐段写入调用方 `buffer`，十进制数字**逐位写**
  （`writeRecord(buffer, offset, n)`），全程不建 `String`、不建临时 `Array<Byte>`；
  `recordLength` / `totalBytes` / `records` 算式不动。→ 1.1 转绿。
- [x] 1.3 新增 `src/PerfTen_test.cj`（`gateTenMegabytes`：10 MB × 5，输出 5 个值 + `min` +
  `nproc` / `loadavg` / `env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'`；`min >= 1000` 时 `assertTrue(false)`）与
  `src/PerfFifty_test.cj`（`gateFiftyMegabytes`：只跑 50 MB 一次，输出 `VmHWM`，
  另跑一份极小文档记录「进程地板」；`VmHWM >= 262144` 时 `assertTrue(false)`）。
  环境不干净或 `loadavg(1) > 0.5 * nproc` ⇒ 打印 `gate: invalid (env/load)` 并 return。
- [x] 1.4 **同轮旧代码重测**：`git stash` 到 `HEAD`，用 1.2 / 1.3 的新基准跑一遍，
  回填 `baseline.md` §3.1；恢复后跑新代码，回填 §3.2。两次之间不得编译其他改动。
  5 个值里 `max/min > 1.4` ⇒ 该轮作废重测。

## 2. 名字驻留（TDD）

- [x] 2.1 **先写失败用例** `src/NameTable_test.cj`：
  - 命中：同名插入两次，第二次返回同一 `String` 实例（`unsafeBytes` 相同且 `misses == 1`）；
  - 未命中：不同名各自插入，`insertions` 递增；
  - **同 hash 反例**：构造两个 hash 相同但内容不同的名字（用例直接向表注入 hash），
    断言二者不相等、各自返回自己的 `local`；
  - 前缀：`p:x` 与 `x` 不互相命中；`p:x` 的 `prefix == "p"`、`local == "x"`；
  - 非 ASCII 与组合字符：`名字`、`a\u0300`、`日本:語`；
  - 上限：把 `maxEntries` 调到 4，插入 8 个不同名，`insertions == 4`，后续查找仍然正确。
  → 预期红（`NameTable` 不存在）。
- [x] 2.2 实现 `src/NameTable.cj`：开放寻址、FNV-1a（`0xCBF29CE484222325` /
  `0x00000100000001B3`）、负载因子 0.5 翻倍重建、`maxEntries` 硬停插、
  逐字节比对（`String.unsafeBytes()` vs scratch）、`hits` / `misses` / `insertions` 计数。→ 2.1 转绿。
- [x] 2.3 `Lexer` 持有 `names: NameTable`；`readName` 改「一次扫描 + 增量 hash + 复用 scratch +
  查表」：命中直接返回表里已切分的 `prefix` / `local`，未命中才 `toString()` + 切分 + 插入
  （`design.md` §4.2）。冒号规则与空前缀 / 空本地名的报错**时机与消息不变**。
- [x] 2.4 **结构性断言** `src/Lexer_test.cj` 追加：解析 10 万条 `<item id="1" a="v">x</item>`，
  断言 `names.misses == 3`（`item` / `id` / `a`，结束标签的 `item` 命中）、`names.insertions == 3`、
  `hits >= 39.9 万`。→ 证明「确实驻留」，不靠耗时。
- [x] 2.5 回归：`Lexer_test` / `NamespaceScope_test` / `DomBuilder_test` / `EntitySecurity_test` /
  `XmlconfHarness_test` 全绿；`ParserError_test` 的消息与行列号逐条不变。

## 3. 扫描缓冲复用

- [x] 3.1 **先写失败用例** `src/BufferReuse_test.cj`：
  - 连续解析 `<a x="1">t1</a><b y="2">t2</b>`，断言事件文本 / 值逐字符正确、无上一 token 残留；
  - 名字与值交替 1000 次，断言每次结果与单次解析一致；
  - 结构断言：解析 1 KB 与 1 MB 文档，`Lexer` 的复用缓冲实例数恒为 3（用 `internal` 计数或
    实例身份断言）。
- [x] 3.2 `Lexer` 增加 `nameScratch` / `valueScratch` / `textScratch` 三个字段，
  各扫描入口 `reset()` 复用；删除对应的 `let gen = StringGenerator()` 局部构造。
  → 3.1 转绿。
- [x] 3.3 按 `tasks.md` 0.4 的结论决定是否启用 `ByteScratch`（`design.md` §5.3）：
  启用则先写「与 `StringGenerator` 逐字节对拍」的用例，再替换；不启用则在
  `design.md` §5.1 记下实测依据。
- [x] 3.4 **静态检查**：`grep -n 'StringGenerator()' src/Lexer.cj` 只剩 `design.md` §5.2 白名单
  里的位置（`collapseSpaces` 等 4 处）；白名单写进 `design.md` §5.2 注脚。

## 4. 文本与属性值批量扫描（TDD）

- [x] 4.1 **先写失败用例** `src/LineWindow_test.cj` 追加：
  - `runAvailable` / `cpAt` / `skipRun` 与 `peekFast` / `advanceFast` 在
    `bufSize ∈ {4, 8, 16, 8192}` 下逐字符一致（含 `\n` 的行列号）；
  - `asciiRunLength` 在块边界（剩余 0 / 1 / n）返回正确；跨 `runAvailable` 后旧下标不再可用
    （用例故意在 refill 后断言 `cpAt` 的结果变化，把「失效规则」钉死）；
  - `runAvailable` 在错误点之前不抛、到错误点抛（复用 `InvalidByteMode_test` 的构造方式）。
- [x] 4.2 `LineWindow` 实现 4 个 `internal` 成员（`design.md` §6.1）；`skipRun` 走
  「无 `\n` 则 `column += n`」的快分支 + 含 `\n` 的慢分支，两者用 4.1 对拍。→ 4.1 转绿。
- [x] 4.3 `XmlChars` 加 `isAsciiXmlChar` / `asciiMaskFor`；用例覆盖 `0x00..0x7F` 全 128 个码点
  与 `isXmlChar(Int64)` 结果一致。
- [x] 4.4 `nextContentToken` 接入文本批量路径（`design.md` §6.2）。用例（`src/TextScan_test.cj`）：
  - 1 MB 纯 ASCII 文本：1 个 `Text` 事件、内容逐字符一致、`peekCp` 调用次数 < 字符数 / 16
    （内部计数）；
  - 文本跨 `bufSize = 4/8/16/8192` 的块边界仍然 1 个事件；
  - `]]>` 仍报「文本里不能出现「]]>」」，位置不变；
  - `&amp;` / `&#x41;` / 自定义实体在 `&` 处正确切分（`Text` + `TEntityRef` 的行为不变）；
  - `0x01` 报错消息与行列号不变。
- [x] 4.5 `readAttributeValue` 接入属性值批量路径（`design.md` §6.3）。用例：
  - 长属性值（64 KB）内容一致、`peekCp` 调用次数下降；
  - 跨行属性值：字面换行 / Tab / CR → 空格；`&#10;` 保持换行；
  - 值里裸 `<` 报错、未闭合报错、实体展开后含 `<` 报错 —— 三条消息与位置不变。
- [x] 4.6 跑 `Lexer_test` / `CharLayerParity_test` / `ParserError_test` / `XmlParser_test` 全绿，
  再进入下一节。

## 5. 事件侧容器复用（TDD）

- [x] 5.1 **先写失败用例** `src/BufferReuse_test.cj` 追加：
  - 拉模式取到 `<a x="1" y="2"/>` 的 `StartElement` 后保存引用，再取两个事件，断言保存的
    事件属性数仍为 2、值不变（跨事件无别名）；
  - `<a x="1" x="2">` 的重复属性消息与位置不变；`<a x="超长值">` 的长度上限消息与位置不变；
  - 0 / 1 / 5 个属性的元素，交付数组长度分别为 0 / 1 / 5。
- [x] 5.2 `Lexer.readStartTag` 的 `ArrayList<RawAttribute>` 改为复用 `attrsScratch`（入口 `clear()`）；
  `ParserEngine.openElement` 的 `resolved` / `seen` 改为「精确 `Array<XmlAttribute>(n)` +
  复用 `seenScratch`」；**校验顺序保持不变**（`design.md` §7）。→ 5.1 转绿。
- [x] 5.3 推 / 拉 / 单回调三份事件日志逐行 `diff` 为空：跑 `PushPullParity_test` 与
  `FormatSamples_test`；再手工用 `XmlParser.parse(handler)` 对 3 份文档做一次日志对拍
  （用例形式落在 `PushPullParity_test`）。

## 6. Gate 判定（缺 0.3 不得开工）

- [x] 6.1 `cjpm clean && cjpm build`：不新增 WARNING（现有 21 条在 `doc/build-warnings.md`）。
- [x] 6.2 `cjpm test`：337 条 + 新增用例全部通过，记录总数。
- [x] 6.3 空载检查不可跳过：
  `uptime`（1 分钟负载 ≤ `0.5 × nproc`）、`env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` 为空，**截图/原文写进
  `verification.md`**。
- [x] 6.4 **Gate T**：`F_XML_PERF=1 cjpm test --filter=PerfTen_test` 一次进程跑 5 次，
  5 个单次值都要记；`min < 1000`。
- [x] 6.5 **Gate T-对照**：同一轮里旧 / 新代码各 5 次；`new_min <= 0.95 * old_min`。
  两份值都进 `baseline.md` §3 与 `verification.md`。
- [x] 6.6 **Gate M**：`F_XML_PERF=1 cjpm test --filter=PerfFifty_test`，`VmHWM < 262144 kB`；
  同时记录进程地板值。`VmHWM` 不低于改前（M-对照）。
- [x] 6.7 波动检查：任何一轮 `max/min > 1.4` ⇒ 作废重测（记录作废原因，不改阈值）。
  三项（6.4 / 6.5 / 6.6）全过才勾本节；不过按 `design.md` §8 阶梯继续，**不放宽阈值**。

## 7. 全量回归与文档

- [x] 7.1 **Gate A**：xmlconf 全量 `pass = 2038`、`fail = 0`、`unsupported = 524`、`known = 0`；
  五条排除规则仍为 `313 / 95 / 59 / 47 / 10`（`unsupported.json` 复核）。
- [x] 7.2 **Python 用例**：`python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v` = 4 条全绿。
- [x] 7.3 **公开声明零变更**：`grep -rn '^public ' f_xml/src --include='*.cj' | sort >
  /tmp/f_xml_public_after.txt && diff /tmp/f_xml_public_before.txt /tmp/f_xml_public_after.txt`
  无输出（`public class *_test` 按文件名过滤）。
- [x] 7.4 同步工作副本：`rsync -a --delete f_xml/doc/spec/optimize-f-xml-semantic-layer/
  openspec/changes/optimize-f-xml-semantic-layer/`，再 `diff -ru …` 无输出。
- [x] 7.5 新增本变更 `verification.md`：结果总览（T / T-对照 / M / M-对照 / A / R）、
  同轮对照表、`max/min` 与负载原文、阶梯用了哪几级、遗留项（必须为空或经用户裁定）。
- [x] 7.6 回填 `f_xml/README.md` / `README_en.md` 状态段（达成值、用例数、指向本变更）；
  回填 `doc/f_xml模块设计.md` §15.1（性能现状 + 语义层小节）。
- [x] 7.7 逐条核对 `specs/f-xml-semantic-layer/spec.md` 的每个 Scenario 都有对应用例
  （新建或既有），缺一补一；「Scenario → 用例名」对照表写进 `verification.md`。
- [x] 7.8 `git status --porcelain` 人工过一遍：不提交 `.cache/`、`/tmp` 产物、`openspec/`、
  50 MB 测试数据。
- [x] 7.9 分支内提交（按任务独立提交，不合并、不推送），提交信息写明 Gate 实测值；
  交付给用户：T / M 的数字、同轮对照、新增用例数、启用了哪一级阶梯（或未启用）。
