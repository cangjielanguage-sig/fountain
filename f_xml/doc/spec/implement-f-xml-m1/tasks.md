# Tasks — implement-f-xml-m1

> **唯一入库副本**：`f_xml/doc/spec/implement-f-xml-m1/`。`openspec/changes/implement-f-xml-m1/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 12.7）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/implement-f-xml-m1/ openspec/changes/implement-f-xml-m1/`
> 校验：`diff -ru f_xml/doc/spec/implement-f-xml-m1 openspec/changes/implement-f-xml-m1` 无输出。
>
> 实施遵循 TDD：**先写失败用例，再实现**。每个任务完成即独立提交（仓库约定「有单元测试后再提交」）。
> **分支**：在本 worktree 的当前分支上开发（`git branch --show-current` 确认），开工前 `git pull`；
> **不新建**分支、**不自动 merge**、**不自动 push**——全部验收通过后由用户确认再按仓库流程
> `git merge --no-ff` 合回主干，是否删除分支同样由用户确认。
> **边界**：只改 `f_xml/`；不动 `f_base` / `f_io` / `f_zip`；不新增依赖、不升级 `charset4cj`。
> **范围**：只做 M1。任何 XPath / C14N / XML 1.1 的代码都不写（包括「先留个空壳」）。

## 0. 前置

- [ ] 0.1 记录基线：`f_xml` 的 `cjpm build` / `cjpm test` 现状（预期：build 通过，0 用例）；
  `git branch --show-current` 记录当前分支。
- [ ] 0.2 建包骨架 `f_xml/src/f_xml.cj` 的导入约定：`f_base` 与 `charset4cj` 的公开再导出
  （`public import cangjie_tpc::charset4cj.charset.encoding.Charset`、
  `public import cangjie_tpc::charset4cj.charset.Charsets`），`cjpm build` 通过。
- [ ] 0.3 **R1–R3 实测**（`StringGenerator` 的三条前提，见 `design.md` §10）：
  - 10 万次 `append("x")` 的耗时曲线（线性 / 二次）；
  - `ArrayList<Byte>` 扩容倍数（连续 append 记录底层数组换新时机）；
  - `unsafeBytes()` 连续两次取是否同一数组（`===`），以及 `unsafeBytes().size == size`。
  结论回填 `design.md` §10；不达标则先调整 `XmlWriter` 的缓冲策略再继续。
- [ ] 0.4 **R4 实测**：`charset4cj` 的 `Encoder.encode` 对不可映射字符的行为（GBK 写 emoji：
  抛 / 替换 `?` / 跳过）。结论回填 `design.md` §10 与 §6.9（决定往返校验是否保留）。
- [ ] 0.5 **R6 实测**：`cjpm test` 的工作目录。结论决定 `TestDataRoot` 的候选顺序。

## 1. P-1 字符层

- [ ] 1.1 **先写测试** `src/PrefixStream_test.cj`：前缀 + 剩余连续读出；EOF 返回 `-1`；
  `close()` 关闭底层（用计数流断言）。→ 实现 `src/PrefixStream.cj`。
- [ ] 1.2 **先写测试** `src/ByteSniffer_test.cj`：UTF-8 BOM / UTF-16LE BOM / UTF-16BE BOM /
  UTF-32LE BOM 优先于 UTF-16LE / 无 BOM 的 `3C 00 3F 00` 与 `00 3C 00 3F` / 声明 `encoding`
  单双引号 / BOM 与声明冲突以 BOM 为准 / 无任何线索默认 UTF-8。
  → 实现 `src/ByteSniffer.cj`（嗅探上限 4 + 1024 字节）。
- [ ] 1.3 **先写测试** `src/RuneSource_test.cj`：`peek(0..4)` 不移动游标；`advance` 语义；
  行列号 1-based；无 `byteOffset`。→ 实现 `src/RuneSource.cj` 的接口 + `SourcePosition` +
  `Utf8RuneSource`。
- [ ] 1.4 **先写测试** `src/CharsetRuneSource_test.cj`：GBK 文档逐字符读出；`bufSize` 变化结果一致。
  → 实现 `CharsetRuneSource`。
- [ ] 1.5 **先写测试** `src/BlockRuneSource_test.cj`：UTF-16LE 含 U+0A00 不被当换行；
  `bufSize = 16` 解析 4 KB UTF-16 文档无丢字；UTF-32BE 同理。
  → 实现 `BlockRuneSource`（固定块解码 + 块尾回退 ≤3 字节）。
- [ ] 1.6 **先写测试** `src/LineWindow_test.cj`：空行补 `\n` 而 EOF 不补；孤立 `\r` 归一；
  `\r\n` 只归一一次；跨行 token 拼接。
  → 实现 `src/LineWindow.cj`（8 槽环形前瞻 + 行列号）。
- [ ] 1.7 **先写测试** `src/InvalidByteMode_test.cj`，两模式输出分别钉住：
  - `Strict`：走 `std.io.StringReader`；坏字节抛 `XmlException`，消息含行号、列号、坏字节偏移；
    合法 UTF-8 的逐字符输出用 golden 字符串固定。
  - `Replace`：走自研 `Utf8ReplaceDecoder`（与 `BlockRuneSource` 共用 `ByteDecoder`）；
    `0xE0 0x80` 等最大子部分各产出**恰好 1 个** `U+FFFD`，后续字符不错位；合法输入的输出与
    `Strict` 路径逐字符一致。
  - 块边界：`bufSize = 4/8` 下截断的多字节序列（2/3/4 字节各一例）与块内截断结果相同；
    overlong、代理区、`> U+10FFFF` 各一例。
  → 实现 `ByteDecoder` + `Utf8ReplaceDecoder`，在 `Utf8RuneSource` 内按 `onInvalidByte` 选路；
  `Strict` 路径不得复用 `Replace` 解码器。
- [ ] 1.8 记录 `bufSize` 实测（R5）：1 MB / 20 万行文档扫 4K/8K/16K/64K，结论回填
  `design.md` §10；默认值保持 8192 除非实测明显更优。

## 2. P0 词法

- [ ] 2.1 **先写测试** `src/Lexer_test.cj`（最小集）：`<a/>`、`<a></a>`、`<a b="1"/>`、
  `<a b='1'/>`、`<a />`、文本、`&lt;` 系列、`&#65;`、`&#x41;`、`<![CDATA[]]>`、`<!-- -->`、
  `<?pi d?>`。→ 实现 `src/Lexer.cj` 的切分（先不做状态机）。
- [ ] 2.2 **先写测试**：非法字符引用（`&#0;`、`&#xD800;`、`&#x110000;`、`&nbsp;`、裸 `&`、
  `&foo` 无分号）全部报错；`&#x1F600;` 产出一个码点。
- [ ] 2.3 **先写测试**：CDATA 的 `]]` 不结束、只有 `]]>` 结束；空 CDATA；相邻 CDATA 各一次；
  CDATA 与文本混排顺序不乱。
- [ ] 2.4 **先写测试**：注释含 `--`、注释以 `-` 结尾、PI target 为 `xml`/`XML` 均报错；
  PI data 含 `?` 不提前结束。

## 3. P1 状态机与校验

- [ ] 3.1 **先写测试** `src/ParserState_test.cj`：PROLOG/CONTENT/EPILOG 的允许集；
  多根元素、无根元素、纯空白文档、只有注释的文档报错；前导 / 尾部注释与 PI 合法。
- [ ] 3.2 **先写测试**：结束标签与栈顶不匹配；提前 EOF；`<a b="1"c="2"/>` 缺空白；
  属性值裸 `<`；引号不配对；重复属性（**字面名**与**展开名**各一条）。
  → 名称栈按展开名比较。
- [ ] 3.3 **先写测试**：`maxElementDepth`（4096 默认）与 `maxAttributeValueLength`（1 MiB）
  的超限与边界；1 万层嵌套不栈溢出。
- [ ] 3.4 **先写测试**：`version="1.1"` 抛错且消息含 `1.1`；`version="2.0"` 报错；
  `version="1.0"` 与省略合法。

## 4. P1.5 事件与 DOM

- [ ] 4.1 **先写测试** `src/XmlEvent_test.cj`：`XmlEvent.toString()` 的稳定文本格式
  （含 `TEXT "..." <字符数>`）；`XmlAction` 的 `==` 与 `toString`；`XmlEventHandler`
  默认实现可被「只覆盖一个方法」的实现类继承。
  → `XmlAction` / `InvalidByteMode` / `InvalidCharMode` / `CdataMode` / `EntityOverflowPolicy` /
  `EntityLimitKind` 声明 `Equatable` 的**同时显式实现 `operator func ==`**（仓颉 enum 不自动派生）；
  测试覆盖每个取值的自反、互不相等、以及新增分支时 `match` 的穷尽性。
- [ ] 4.2 **先写测试** `src/DomBuilder_test.cj`：相邻 `Text` 合并为一个节点；
  `Text` + `CData` 不合并；`trimWhitespaceOnly`；`xml:space="preserve"` / `"default"`；
  深度超限报错。→ 实现 `src/DomBuilder.cj`。
- [ ] 4.3 **先写测试** `src/XmlElement_test.cj` / `src/QName_test.cj`：`attr`/`child`/
  `childrenOf` 按 local name 命中（`<x:item>` 与 `<item>` 都命中）；`attr(ns, local)`；
  `setAttr` 覆盖；`text()` 跳过注释与 PI；`QName.toString()`。
- [ ] 4.4 **先写测试** `src/XmlPullParser_test.cj`：事件顺序（前导 / 尾部注释、声明最多一次）；
  自闭合产 Start + End；`Stop` 后不再读流；`SkipSubtree` 后 `EndElement` 仍到。
  → 实现 `src/XmlPullParser.cj`。
- [ ] 4.5 **先写测试** `src/XmlParser_test.cj`：`parse(input/bytes/text/path)` 四种重载；
  单回调重载不产 DOM；多回调与单回调路径等价。→ 实现 `src/XmlParser.cj`。
- [ ] 4.6 **先写测试** `src/SkipScanner_test.cj`：按深度配对（同名嵌套）；`<!-- a > b -->`；
  属性值里的 `>`；CDATA 里的 `>`；自闭合时 `skipElement()` 为空操作；非法位置调用报错。
  → 实现 `src/SkipScanner.cj`。

## 5. P2 推拉一致性

- [ ] 5.1 **先写测试** `src/PushPullParity_test.cj`：同一批输入（自闭合、CDATA、注释、PI、
  命名空间、实体、跨行属性）分别走 `nextEvent()` 与 `parse(input, handler)`，
  两份事件日志文本**逐行相同**。
- [ ] 5.2 单回调路径并入同一份日志对比（三份日志两两相等）。
- [ ] 5.3 覆盖 `Stop` / `SkipSubtree` 在两条路径上的等价性（`break` vs `Stop`）。

## 6. P2.5 xmlconf harness

> 套件与派生 JSON **一律不入库**。仓库只保留 `f_xml/tools/xmlconf_gen.py`、
> `f_xml/tools/known-issues.json`、`f_xml/doc/xmlconf-unsupported.md`；其余落 `f_xml/.cache/xmlconf/`。

- [ ] 6.1 写 `f_xml/tools/xmlconf_gen.py`（唯一入口，不再单列 `verify_suite.py`）：
  下载 `xmlts20130923.tar.gz` 到 `f_xml/.cache/xmlconf/download/`、校验 SHA-256
  `9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f`（不匹配即非 0 退出并打印
  期望 / 实际值）、解压到 `f_xml/.cache/xmlconf/suite/`；支持 `--offline`（只用缓存）与
  `--force`（重新下载）。缓存缺失且离线时以非 0 退出，提示先联网运行本脚本。
- [ ] 6.2 同一脚本解析 31 个 catalog → 缓存内 `cases.json`；按两条规则产出 `unsupported.json`
  （`edition` / `external-entity`）；判定口径写进脚本注释。跑出 2586 / 408 / 2178 / 2154 与
  1155 / 763 / 236 / 24 的分布，与 `design.md` §9.1 对齐。JSON 键序固定、无时间戳，重复运行
  逐字节一致。
- [ ] 6.3 写 `src/XmlconfHarness_test.cj` + `src/TestDataRoot.cj`：缓存解析顺序
  `F_XML_XMLCONF_CACHE` → `<module>/.cache/xmlconf/`；缺失时用例 **fail**（禁止 skip），
  消息含 `python3 f_xml/tools/xmlconf_gen.py`。按 `TYPE` 映射判定（`invalid` 期望成功、
  `error` 不判定）；输出 `pass / fail / unsupported` 三数字；从缓存内 `unsupported.json`
  生成并更新 `f_xml/doc/xmlconf-unsupported.md`（md 入库，json 不入库）。
  验证 `git check-ignore -v f_xml/.cache/xmlconf/suite` 命中，且 `git ls-files` 不出现套件路径。
- [ ] 6.4 跑一次基线（先 `python3 f_xml/tools/xmlconf_gen.py`），把 `fail` 清单入档
  （P2.5 允许失败），并在 `f_xml/doc/spec/implement-f-xml-m1/` 下新增 `baseline.md` 记录首个
  基线数字与失败分类。离线无缓存的失败路径由 6.3 的 fail 用例覆盖。

## 7. P3 命名空间

- [ ] 7.1 **先写测试** `src/NamespaceScope_test.cj`：默认命名空间继承；前缀声明与使用；
  `xmlns=""` 重置；嵌套重定义后恢复；多前缀同 URI；`xml` 前缀免声明；
  **属性不受默认命名空间影响**；未声明前缀报错；`xmlns` 作元素前缀报错。
  → 实现 `src/NamespaceScope.cj` 并接进 `Lexer`。
- [ ] 7.2 **先写测试**：`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>` 报重复属性（展开名）。
- [ ] 7.3 更新 P2.5 基线，确认命名空间类用例的 fail 数下降；把残余 fail 分类到 6.4 的档里。

## 8. P3.5 DTD 内部实体

- [ ] 8.1 **先写测试** `src/DoctypeParser_test.cj`：`<!ENTITY>` 单双引号；`%` 参数实体；
  `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` 跳过（内含 `>` 与引号）；条件段
  `INCLUDE`/`IGNORE`；首个声明生效；`SYSTEM`/`PUBLIC` 声明可识别。
  → 实现 `src/DoctypeParser.cj` + `src/EntityTable.cj`。
- [ ] 8.2 **先写测试**：实体展开位置（内容 / 属性值 / CDATA 不展开 / 注释不展开 / 实体值内递归）；
  前向引用报错；属性值顺序（先展开再归一，且不 trim）。
- [ ] 8.3 **先写测试** `src/EntityLimits_test.cj`：`maxDepth` 16 通过 / 17 报错、
  `maxDeclarations` 1025 报错、`maxExpandedHardLimit` 超限、原文不计入 `maxExpandedTotal`、
  边展开边计数（抛错时 `totalExpanded < 2 MB`）。
  → 实现 `src/EntityExpander.cj` 的计数。
- [ ] 8.4 **先写测试** `src/ExpandSink_test.cj`：`Spill` 下 20 MB 展开成功、
  `retainedBytes` 不随展开量增长、溢出文件 UTF-8 分块读回与内存路径逐字节一致、
  文件用完即删；`Strict` 下软阈值直接抛。
  → 实现 `src/ExpandSink.cj`。
- [ ] 8.5 **先写测试** `src/SpillDir_test.cj`：四级顺序（显式 → `TMPDIR` → 系统临时 →
  `./.fountain_tmp`）；四级全失败报错含 `spillDir`。→ 实现 `src/SpillDir.cj`。
- [ ] 8.6 **先写测试**：属性值实体的 `AttributeValue` 分类 + 消息含 `属性 'r'`、`64 KB`、行列号；
  `Spill` 下同样抛。
- [ ] 8.7 **先写测试** `src/XmlException_test.cj`：三个构造器；六种 `EntityLimitKind`；
  非实体错误为 `None`；`Strict` 捕获 `Some(Total)` 后改 `Spill` 重试成功；`Some(Depth)` 重试仍同分类。
- [ ] 8.8 **先写测试** `src/EntitySecurity_test.cj`（全部 `Strict`）：Billion Laughs、
  参数实体版、单实体超长、深度边界两条、XXE（不读文件）、外部子集（不发请求）。
- [ ] 8.9 `standalone` 语义：`yes` 报错、`no`/缺省跳过并告警。
- [ ] 8.10 跑全量 xmlconf，确认 228 条内部实体用例进入可跑集且有断言；更新基线。

## 9. P4 XmlWriter

- [ ] 9.1 **先写测试** `src/Escaper_test.cj`：转义表逐格（`\r` → `&#13;`）；
  非法控制字符拒绝并带元素名 / 属性名。→ 实现 `src/Escaper.cj`。
- [ ] 9.2 **先写测试** `src/XmlWriter_test.cj`：紧凑逐字节相等；缩进只在元素间换行；
  写文档（声明 / doctype / prolog / root / epilog 顺序）；写元素不带声明；
  `flush()` 冲刷底层；`close()` 冲刷并关闭。
- [ ] 9.3 **先写测试**：`CdataMode.Auto/Always/Never`；`]]>` 拆分后往返语义不变；
  `Always` 不影响属性值。
- [ ] 9.4 **先写测试**：`EntityRefNode` 输出 `&name;`；`Doctype` 内部子集输出；
  `strictEntities = true` 未声明即报错；`false` 只告警。
- [ ] 9.5 **先写测试**：输出编码（UTF-8 无 BOM / UTF-16LE 带 `FF FE` / GBK 可解回）；
  `onInvalidChar` 两模式；UTF-8 不做往返校验（计次断言）；写次数远小于 token 数（缓冲生效）。
  → 实现 `src/XmlWriter.cj` + `src/XmlWriterOptions.cj`。
- [ ] 9.6 **先写测试**：命名空间声明最小化（不重复 / 改绑定重声明 / `xmlns=""` 重置）。
- [ ] 9.7 **先写测试** `src/RoundTrip_test.cj`：DOM → 写 → 读 → DOM 逐节点语义相等；
  含 `\r` 的文本往返后仍含 `\r`。

## 10. P5 安全收尾与 Gate A

- [ ] 10.1 恶意样本全量回归（`Strict`），确认全部在硬限制内中断、无 OOM、无栈溢出。
- [ ] 10.2 全量 xmlconf（缓存已由 `xmlconf_gen.py` 生成）：`fail == 0`、`pass == 2154`、
  `unsupported == 408`。
- [ ] 10.3 `f_xml/tools/known-issues.json`：仅在确属套件争议用例时添加，每条写理由 + 规范章节；
  ≤ 5 条。该文件入库。
- [ ] 10.4 `f_xml/doc/xmlconf-unsupported.md` 落盘，ID 集合与缓存内 `unsupported.json` 一致；
  **只提交 md**，`unsupported.json` 与套件本体留在 `f_xml/.cache/xmlconf/`。
- [ ] 10.5 语法矩阵自查（`design.md` §9.1）：逐条对照 §12.2 的 ❌ 行，确认每条至少一个用例；
  补缺口。
- [ ] 10.6 组合矩阵与五格式样本用例补齐。

## 11. P6 性能

- [ ] 11.1 事件模式解析 1 / 10 / 50 MB 同构文档，记录耗时与 RSS 峰值；
  10 MB < 1 s（开发机），RSS 峰值不随规模增长。
- [ ] 11.2 DOM 模式记录峰值内存与「XML 体积 → 内存」倍数，回填 `design.md`。
- [ ] 11.3 若 `readln()` 占比 > 总耗时 30%，再评估 `bufSize` 与固定块解码；
  只调参数，不改结构。

## 12. 文档与验收

- [ ] 12.1 改写 `f_xml/README.md` 与 `README_en.md`：能力表、三种用法示例、安全边界
  （外部实体不加载 / 三层上限 / 溢出策略）、`close()` 后不得调用、`indent` 只用于人看。
- [ ] 12.2 更新 `f_xml/src/f_xml.cj` 的包注释：模块定位与「不绑定业务格式」。
- [ ] 12.3 `f_xml/doc/f_xml模块设计.md` 回填差异：§1.3 依赖版本（1.0.5）、§7.6 `XmlEntityRef`、
  §4 `builder`、§12.8 新增的两个上限选项、§2.6 第三个 `RuneSource`。
  这些是本变更 `design.md` §8 已登记的六项。
- [ ] 12.4 `cjpm build`：无错误；WARNING 逐条记录原因（不允许「新增未说明的 WARNING」）。
- [ ] 12.5 `cjpm test`：全绿；连续运行两次结果一致。
- [ ] 12.6 覆盖率自查：每个 `public` 声明至少一个正向用例；每个会抛异常的分支至少一个负向用例。
- [ ] 12.7 产物一致性（两份副本逐文件字节一致）：
  - **入库副本**：`f_xml/doc/spec/implement-f-xml-m1/`（唯一可提交的一份）。
  - **本地工作副本**：`openspec/changes/implement-f-xml-m1/`（`openspec/` 已被 `.gitignore` 忽略）。
  - 同步：`rsync -a --delete f_xml/doc/spec/implement-f-xml-m1/ openspec/changes/implement-f-xml-m1/`。
  - 校验：`diff -ru f_xml/doc/spec/implement-f-xml-m1 openspec/changes/implement-f-xml-m1`
    必须无输出；文件清单含 `proposal.md`、`design.md`、`tasks.md`、`specs/**`、`.openspec.yaml`。
  - 只改一侧视为未完成；`openspec validate --strict implement-f-xml-m1` 必须 0 WARNING。
- [ ] 12.8 **合并需用户确认**：向用户汇报验收结果，得到确认后再执行
  `git merge --no-ff`；是否删除分支由用户决定。本变更执行过程**不得**自动 merge / push。

## 13. 遗留（实施中产生的问题登记在此，不在本变更强补）

- （空）
