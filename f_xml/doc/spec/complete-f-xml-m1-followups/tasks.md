# Tasks — complete-f-xml-m1-followups

> **唯一入库副本**：`f_xml/doc/spec/complete-f-xml-m1-followups/`。`openspec/changes/complete-f-xml-m1-followups/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 11.4）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/complete-f-xml-m1-followups/ openspec/changes/complete-f-xml-m1-followups/`
> 校验：`diff -ru f_xml/doc/spec/complete-f-xml-m1-followups openspec/changes/complete-f-xml-m1-followups` 无输出。
>
> 实施遵循 TDD：**先写失败用例，再实现**。每个任务完成即独立提交（仓库约定「有单元测试后再提交」）。
> **分支**：在 `feature/f_xml_followups` 上开发（开工前 `git branch --show-current` 确认、
> `git pull`）；**不自动 merge、不自动 push**——全部验收通过后由用户确认再按仓库流程
> `git merge --no-ff` 合回主干，是否删除分支同样由用户确认。
> **边界**：只改 `f_xml/`；不动 `f_base` / `f_io` / `f_zip`；不新增依赖、不升级 `charset4cj`；
> **不改任何 `public` 声明**（签名、默认值、可见性）。
> **范围**：字符层性能重写 + 三项 P3 补强。XPath / C14N / XML 1.1 一行都不写。

## 0. 前置

- [x] 0.1 记录基线：`git branch --show-current`、`cjpm build` 结果、`cjpm test` 条数与通过率、
  `F_XML_PERF=1` 下 1 MB / 10 MB 的现状耗时（若基准尚未存在，先手工跑一次
  `XmlParser.parse` 的 loop，记录到 `baseline.md`）。与 `baseline.md` 的预填值核对，不一致
  以实测为准并更新该文件。
- [x] 0.2 **公开声明快照**：`grep -rn '^public ' f_xml/src --include='*.cj' | sort > /tmp/f_xml_public_before.txt`；
  记下条数。这是 10.4 的对比基准。
- [x] 0.3 **微基准：`Rune` 的分配属性**（决定 §4.4 是否启用备选）。写一个临时用例：
  1 亿次 `Rune(0x41)` + `position()`，记录耗时与 RSS 增量；若 RSS 随次数线性增长，
  说明 `Rune` 是引用类型。结论回填 `design.md` §4.4 与 §13。**不改实现，只测量。**
- [x] 0.4 确认 xmlconf 缓存可用（`f_xml/.cache/xmlconf/cases.json` 存在）；缺失时先跑
  `python3 f_xml/tools/xmlconf_gen.py`，再确认 Gate A 当前是 2038 / 0 / 524。
- [x] 0.5 跑一次 Python 工具的自测基线：`python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v`
  当前应为「0 条用例」（文件还不存在），确认为空而非报错。

## 1. 字符层块解码（TDD）

- [x] 1.1 **先写失败用例** `src/RuneSource_test.cj` 追加：
  - `peekFast` / `advanceFast` 与 `peek` / `advance` 在 `bufSize ∈ {4, 8, 16, 8192}` 下逐字符一致；
  - `peekFast(0..4)` 在块边界（构造恰好 63 / 64 / 65 字符前缀）仍有效；
  - 内部计数：1 MB ASCII 文档 `blocksFilled <= codepoints / 64 + 1`。
  → 预期红（计数不存在、块填充未实现）。
- [x] 1.2 实现 `BufferedRuneSource` 块化：`decodeInto` 默认实现（循环 `pull()`）+
  `ownBlock` 惰性分配 + `peekFast` / `advanceFast` 块内寻址 + `blocksFilled` /
  `codepointsYielded` 计数。**`protected pull()` / `pulledRune` 保留**，不破坏第三方子类。
  三个内置子类中：`Utf8RuneSource`（strict / replace）与 `BlockRuneSource`（UTF-16/32）
  覆写 `decodeInto` 走批量；`CharsetRuneSource` 用默认实现（逐字符 `read()`，保留 §3.8
  例外）。→ 1.1 转绿。
- [x] 1.3 `ByteDecoder.decodeBlock(dest, start, capacity)` + `ByteReader.copyAsciiRun`；
  UTF-8 连续 ASCII 批量搬运，多字节仍走 `next()`；块尾回退不变。
  用例：`InvalidByteMode_test` 追加「`bufSize = 4/8/16` 下块解码与整块读取逐字符一致」。
- [x] 1.4 `ByteCodec` 的 UTF-16/32 块入口：`decodeBlock` 循环调 `next()`；用例复用
  `BlockRuneSource_test`（含 `bufSize = 16` 的 4 KB 文档、U+0A00、代理对跨块）。
- [ ] 1.5 性能冒烟（不设门禁）：1 MB 文档 `advanceFast` 吞吐 ≥ 20 MB/s；低于此值先查
  `decodeBlock` 是否真的走了 ASCII 批量。记录到 `design.md` §7.3 备注。
- [x] 1.6 **先写失败用例**（解码错误延迟抛出，`design.md` §3.5）：
  - `bufSize = 8192`，文档在 3 个合法元素后出现非法 UTF-8 字节；
  - 断言前 3 个元素的事件**先送达**，错误在消费坏字符时抛出；
  - `line` / `column` 指向坏字符自身，消息仍含字节偏移；
  - `peekFast` 命中错误点也抛，不返回 `-1`。
  → 实现 `BlockFill` 的错误传递与 `LineWindow` 的错误点记录。

## 2. 三层缓冲合并

- [x] 2.1 **先写失败用例** `src/LineWindow_test.cj` 追加：
  - `\r` 在块尾、`\n` 在下一块（前缀长度 62..66，`bufSize = 4/8/16/64`）只归一一次；
  - `\r\r\n` 仍产出 `\n\n`；
  - 位置只在 advance 时推进（填充前后 `position()` 不变）；
  - 自定义 `RuneSource`（不继承 `BufferedRuneSource`）走回退路径，结果与块路径一致。
- [x] 2.2 在 `BufferedRuneSource` 上实现内部块读入口 `readCodePointBlock`（转调
  `decodeInto`）；`LineWindow` 改为单活动 `Array<Int32>` + `ensure(offset + 1)` 压缩重填 +
  `pendingSkipLf` 跨块归一 + 类型判定失败时的回退路径。→ 2.1 转绿。
- [x] 2.3 断言「主路径不分配第二份块」：解析任意文档后 `ownBlock` 仍为 `None`
  （内部可见断言，放在 `RuneSource_test`）。若实现需要 `LineWindow` 暴露容量，用
  `internal` 只读属性，不进公开 API。
- [x] 2.4 跑 `LineWindow_test` / `RuneSource_test` / `InvalidByteMode_test` /
  `BlockRuneSource_test` 全绿，再进入下一节。

## 3. Lexer 热路径

- [x] 3.1 `RuneFeed` 增加 `peekCpFast` / `advanceCpFast`；`WindowFeed` / `StringFeed` /
  `SinkFeed` 实现；`StringFeed` 改 `Array<Int32>`，`SinkFeed` 改 `Array<Int32>` 块。
- [x] 3.2 **先写失败用例** `src/Lexer_test.cj` 追加：一份覆盖「标签 / 属性 / 文本 / CDATA /
  注释 / PI / 声明 / DOCTYPE / 内部子集」的文档，断言事件序列与错误位置与改动前一致
  （golden 文本写在用例里）；再加一个含 10 万个 `?>` 的 PI 文档线性耗时冒烟。
- [x] 3.3 改写扫描循环：`nextMarkupToken` / `readMarkup` / `readStartTag` /
  `readAttributeValue` / `readDeclarationValue` / `skipWhitespace` / `trySkipWhitespace` /
  `readReference` / `readComment` / `readBang` 的 CDATA 分支 / `readPiOrDeclaration` /
  `readDeclaration` / `readDoctype` / `readQuoted` / `readInternalSubset` 全部改
  `peekCp` / `advanceCp`。→ 3.2 转绿。
- [x] 3.4 固定串常量：在 `Lexer` 内定义 `static let` 的 `Array<Int64>`（`<!--`、`-->`、
  `<![CDATA[`、`]]>`、`?>`、`DOCTYPE`、`PUBLIC`、`SYSTEM`、`--`、`<![`、`&`），
  `startsWithCp` / `consumeCp` / `expectCp`；替换全部调用点。用例：PI / 注释 / CDATA
  的既有用例全过，且 1 MB 文档不再出现 `runesOf` 的每次调用分配（用计数或耗时断言）。
- [x] 3.5 `XmlChars` 补 `Int64` 重载（`isWhitespace` / `isDigit` / `isHexDigit` /
  `hexValue`），原 `Rune` 重载保留；跑 `XmlChars` 相关既有用例。
- [x] 3.6 **静态检查**：`grep -n 'peek(\|advance(\|Rune.position(' f_xml/src/Lexer.cj`，
  逐条确认只剩：`public peek/advance` 的包装定义、`readName` 等极少数明确白名单位置；
  白名单写进 `design.md` §4.2 的注脚。

## 4. 实体帧与溢出读回

- [x] 4.1 `ExpandReader` 增加 `nextCp(): Int64`；`MemoryExpandReader` 改 `Array<Int32>`
  （新增内部 `cpsOf(text)`）；`FileExpandReader.nextCp` 直接转 `ByteDecoder.next()`。
- [x] 4.2 `SinkFeed` 改 `Array<Int32>` 块填充；`EntityExpander.feed` / `ExpandSink.openReader`
  适配。用例：`Spill_test` / `EntitySecurity_test` / `EntityReplacementWf_test` 全绿。
- [x] 4.3 溢出读回性能冒烟：20 MB 展开量 `Spill` 路径的 `readAll` 不出现逐字符 `Option`
  （结构断言：`SinkFeed` 的填充只调用 `nextCp()`，不再调用 `next()`）；耗时只记录。

## 5. 性能基准与 Gate

- [x] 5.1 新增 `src/Perf_test.cj`：`SyntheticXmlStream`（按整条记录凑数、精确到 < 单条
  记录长度的误差、跨记录边界、良构）+ 字节数自检用例。
- [x] 5.2 1 MB 冒烟用例（默认执行，目标 < 100 ms）+ 10 MB / 50 MB 用例（`F_XML_PERF=1`）。
  计时口径按 `design.md` §6.2：预热、3 次、只计 `nextEvent` 循环、`min`。
- [x] 5.3 RSS 采集：`/proc/self/status` 的 `VmRSS` / `VmHWM`；不可用时打印 `unavailable`
  并跳过断言。断言按 `design.md` §6.3。
- [ ] 5.4 **Gate 判定**：`F_XML_PERF=1 cjpm test --filter=Perf`，10 MB `min < 7200 ms`、
  `hwm50 - hwm10 <= 24 MB`、`hwm50 <= 256 MB`。三项全过才勾这一条；不过按
  `design.md` §13 阶梯继续，**不放宽阈值**。
- [ ] 5.5 把 1 / 10 / 50 MB 的 `bytes / events / ms / min / hwm` 回填 `design.md` §7.3
  （同时保留改前基线那一行）。

## 6. R5 `bufSize` 实测

- [x] 6.1 在 `Perf_test` 增加矩阵用例（`F_XML_PERF=1`）：1 MB / 10 MB × 4096 / 8192 /
  16384 / 65536，各 3 次取最小，输出统一格式。
- [ ] 6.2 跑完把 8 个值回填 `design.md` §8.2，并写一句结论（是否收敛、拐点在哪）。
- [ ] 6.3 回填 `f_xml/doc/f_xml模块设计.md` §15.1 与 `f_xml/README.md` 状态段；
  把 `implement-f-xml-m1/design.md` §10.1 的 R5 行从「未做」改为「已实测，见
  `complete-f-xml-m1-followups/design.md` §8.2」。**默认值仍是 8192。**

## 7. P3-a：`SpillDir` 四级全失败

- [x] 7.1 **先写失败用例** `src/SpillDirFallback_test.cj`：
  - 四个「已存在的普通文件」路径（含回落点）→ 抛 `XmlException`，消息含 `spillDir`；
  - `ExpandSink.isSpilled() == false`，且没有产生 `.fountain_tmp` 目录；
  - 非回落缺失候选被跳过；回落目录缺失被创建；单候选成功路径回归。
- [x] 7.2 抽出 `SpillDir.createFileFrom(candidates, fallback): File`，`createFile(limits)`
  变薄包装；保持原循环语义（仅回落点可创建、异常 `continue`、最终抛出）。→ 7.1 转绿。
- [x] 7.3 跑 `SpillDir_test` + `Spill_test`，确认成功路径无回归。

## 8. P3-b：两个解析器计数独立

- [x] 8.1 **先写失败用例** `src/EntityCounterIsolation_test.cj`：
  - 交错：两个 `XmlPullParser` 交替 `nextEvent()`，断言 `totalExpanded()` 只随自身变化；
  - 双线程：`spawn` 两个线程，各解析展开量 0.8 × `maxExpandedTotal` 的文档，两份都成功。
- [x] 8.2 若用例暴露共享状态（预期不会），修 `ParserEngine` / `EntityCounter` 的持有关系；
  否则只提交用例。**不加锁、不改计数语义。**
- [x] 8.3 用例连跑 5 次（线程调度抖动），全绿才算完成。

## 9. P3-c：`xmlconf_gen.py` SHA-256 分支

- [x] 9.1 **先写失败用例** `tools/test_xmlconf_gen.py`（`unittest`）：
  函数级匹配 / 不匹配 + 端到端 `--offline` 损坏包（退出码、stderr、无 `cases.json`、
  无 `suite/`）。
- [x] 9.2 抽 `ensure_sha256(path, expected=SUITE_SHA256) -> int`；`download()` 与 `main()`
  改为调用它，保持「不匹配不继续」的原行为。→ 9.1 转绿。
- [x] 9.3 跑 `python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v` 全绿；
  再跑一次真实 `--offline`（缓存完好）确认脚本行为未变：仍输出 `total / unsupported /
  runnable / assertions` 且 `assertions == 2038`。

## 10. 全量回归

- [x] 10.1 `cjpm clean && cjpm build`：不新增 WARNING（现有 20 条在
  `doc/build-warnings.md`）。
- [x] 10.2 `cjpm test`：现有 303 条 + 新增用例全部通过；记录总数。
- [ ] 10.3 **Gate A**：xmlconf 全量 `pass=2038 fail=0 unsupported=524 known=0`；
  五条排除规则的条数仍是 313 / 95 / 59 / 47 / 10（`unsupported.json` 复核）。
- [x] 10.4 **公开声明零变更**：`grep -rn '^public ' f_xml/src --include='*.cj' | sort >
  /tmp/f_xml_public_after.txt && diff /tmp/f_xml_public_before.txt /tmp/f_xml_public_after.txt`
  无输出。
- [x] 10.5 推拉一致性：`PushPullParity_test` 全绿；`FormatSamples_test` 全绿；
  `WriterEncoding_test` 全绿（写方向不该被本次改动影响，跑它是为了证明边界干净）。
- [x] 10.6 新增 `CharLayerParity_test`：`bufSize ∈ {4, 8, 16, 64, 8192, 65536}` ×
  6 份文档（UTF-8 strict / replace、GBK、UTF-16LE、UTF-16BE、UTF-32LE）的事件日志 /
  文本 / `position()` / 错误消息全一致。

## 11. 文档与副本

- [ ] 11.1 更新 `f_xml/README.md`：状态段的性能数字改成实测值、用例数校正为实际值、
  指向本变更；`README_en.md` 同步同一口径。
- [ ] 11.2 更新 `f_xml/doc/f_xml模块设计.md` §15.1：把「1 MB ≈ 1.5 s / 10 MB ≈ 15.8 s、
  已移出 M1 出口」改成本变更的达成值与 Gate 口径；§13.2 的 P6 注明「已由
  complete-f-xml-m1-followups 达成」。
- [ ] 11.3 新增本变更 `verification.md`：结果总览（Gate P / A / R）、verify 轮次、
  性能与 R5 表、遗留项（必须为空或经用户裁定）。
- [ ] 11.4 同步工作副本：
  `rsync -a --delete f_xml/doc/spec/complete-f-xml-m1-followups/ openspec/changes/complete-f-xml-m1-followups/`
  然后 `diff -ru …` 无输出。
- [ ] 11.5 在 `implement-f-xml-m1/verification.md` §3 末尾补一行：三项 P3 已由
  `complete-f-xml-m1-followups` 承接（只加指向，不改历史结论）。

## 12. 收尾

- [ ] 12.1 逐条核对 `specs/**/spec.md` 的每个 Scenario 都有对应用例（新建或既有），
  缺一补一；把「Scenario → 用例名」对照表写进 `verification.md`。
- [ ] 12.2 确认没有把 50 MB 测试数据、`/tmp` 产物、`openspec/` 提交进版本库
  （`git status --porcelain` 人工过一遍）。
- [ ] 12.3 分支内提交（按任务独立提交，不合并、不推送），提交信息写明 Gate 实测值。
- [ ] 12.4 交付给用户：Gate P / A / R 的数字、R5 曲线、新增用例数、以及
  「哪些优化做了、哪些按设计留作例外（GBK 的逐字符 Option）」。
