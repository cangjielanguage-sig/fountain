# Proposal: 实现 f_xml M1（通用 XML 1.0 解析 / DOM / 生成）

> **唯一入库副本**：`f_xml/doc/spec/implement-f-xml-m1/`。`openspec/changes/implement-f-xml-m1/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 `tasks.md` 12.7）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/implement-f-xml-m1/ openspec/changes/implement-f-xml-m1/`
> 校验：`diff -ru f_xml/doc/spec/implement-f-xml-m1 openspec/changes/implement-f-xml-m1` 无输出。

## Why

1. **`f_xml` 目前只有骨架**：`f_xml/src/f_xml.cj` 仅有一个包注释，`cjpm.toml` 与中英 README 已就位，
   但没有任何实现。设计文档 `f_xml/doc/f_xml模块设计.md`（v1.1）已把 26 项决策全部落定
   （§14.1），§14.2 明确「暂无阻塞项，可以进入实施」。
2. **下游在等一个不绑定业务格式的 XML 能力**：RSS/Atom、SVG/SOAP、POM、OOXML、任意配置文件都
   需要同一套「词法 → 事件 → DOM → 序列化」原语。按业务格式各写一套解析器，会把 XML 的
   兼容性补丁分散到多个模块里。
3. **XML 的三类经典攻击必须在第一版就封死**：Billion Laughs（实体膨胀）、XXE（外部实体）、
   SSRF via DTD（外部子集）。设计已经给出「支持内部实体 + 三层上限 + 软阈值溢出到临时文件 +
   外部实体引用即报错」的方案，这套方案不能事后补——它决定了词法器与实体展开器的结构。
4. **通用性需要可复核的验收基准**：不能用「五个格式跑通」当验收，必须用 W3C xmlconf
   20130923 的断言集（可跑 2062 条 / 断言 2038 条；`unsupported` 524 条按五条规则排除：
   `edition` / 外部实体 / XML 1.1 / 外部子集 / 命名空间名）。生成脚本与
   `unsupported` 人读清单要入库，
   套件本体与派生 JSON 走缓存，否则通过率无法复核、仓库又会被 20 MB 测试数据撑大。

## What Changes

本次只做 **M1**。M2（XPath 1.0 子集）与 M3（XML 1.1 + C14N）另开变更；字符层性能重写另开
`optimize-f-xml-char-layer`。本变更不为它们预留半成品 API。

- **字符层（全部 f_xml 自实现）**：字节嗅探（BOM → `<?xml encoding?>` → UTF-8，含附录 F 的
  UTF-16/32 魔数）、`PrefixStream`（把嗅探吃掉的前缀接回流头）、`RuneSource` 三个实现
  （`Utf8RuneSource` / `CharsetRuneSource` / **`BlockRuneSource`**，后者专供 UTF-16/32 绕开
  `readln()` 的按字节断行缺陷）、`LineWindow`（行拼接 + `\r`→`\n` 归一 + ≤4 字符前瞻 + 行列号）、
  `InvalidByteMode`（读）/ `InvalidCharMode`（写）。`InvalidByteMode.Strict` 的 UTF-8 路径仍用
  `std.io.StringReader`；`Replace` 路径改用自研 UTF-8 字节解码（与 `BlockRuneSource` 共用固定块
  字节层），两种模式的输出各由独立测试钉住。
- **词法与事件**：`Lexer` + 状态机（PROLOG / CONTENT / EPILOG）+ 名称栈配对校验；
  `XmlEvent` 单一事件定义、`XmlAction` 控制流、`XmlEventHandler`（**全部默认实现**）。
  需要比较的枚举（`XmlAction` / `InvalidByteMode` / `InvalidCharMode` / `CdataMode` /
  `EntityOverflowPolicy` / `EntityLimitKind`）**显式实现 `operator func ==`**——仓颉 enum 不自动派生 `==`。
- **三个前端，一套内核**：`XmlPullParser.nextEvent()`（唯一内核）、单回调
  `parse(input, onEvent)`、多回调 `parse(input, handler)`；推模式是拉模式之上的一层 `match` 转译。
- **`skipElement()`**：推模式返回 `XmlAction.SkipSubtree`，拉模式直接调；按**深度**配对，
  匹配的 `EndElement` 仍发出；跳过期间只做标签级扫描（正确处理引号内 `>`、注释、CDATA、PI）。
- **DOM**：`QName` / `XmlAttribute` / `XmlNode`（enum，含 `EntityRefNode`）/ `XmlElement` /
  `XmlDocument` / `DomBuilder`；`child()` / `childrenOf()` 按 **local name** 匹配；相邻文本合并；
  `trimWhitespaceOnly` 与 `xml:space` 生效。
- **命名空间**：作用域栈、`xml` 保留前缀固定绑定、`xmlns` 不可作元素前缀、`xmlns=""` 重置、
  **属性不受默认命名空间影响**、未声明前缀报错、重复展开名报错。
- **DTD 内部子集**：普通实体 + 参数实体、首个声明生效；
  `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` / `<!ENTITY>` 做**声明语法良构校验**——这是良构性，
  不是 DTD 有效性校验：非法声明必须报错，但不做内容模型与文档匹配、不做 ID/IDREF 一致性、
  不做默认属性注入。条件段 `<![INCLUDE[` / `<![IGNORE[` **只允许出现在外部子集**，内部子集里
  出现即报错（外部子集不加载，故 M1 永远不认条件段）。实体值里的引用**延迟到真正使用时展开**，
  使用时仍未声明才报错；未声明实体只在「存在外部子集或参数实体引用且 `standalone` 不是 `yes`」
  时按跳过处理并告警，否则一律报错（含无 `DOCTYPE` 的情形）。
  **单实体替换文本必须自身良构**（标签在实体内部配平，不得让实体跨越元素边界）。
  `<!ATTLIST>` 的属性类型**要建「元素 + 属性 → 类型」映射**，只用于属性值规范化（非 CDATA 类型
  去首尾空白并把内部空白折叠成单个空格），不用于有效性校验。
  外部实体与外部子集**一律不加载**，引用即报错。
- **三层膨胀上限 + 溢出策略**：`maxExpandedPerEntity` / `maxExpandedTotal`（软，`Spill` 时转
  临时文件续跑）、`maxDepth` / `maxDeclarations` / `maxExpandedHardLimit`（硬，直接抛）；
  `XmlException.entityLimitKind` 六值分类；**属性值不支持溢出**（`AttributeValue`）。
- **生成器**：`XmlWriter`（紧凑默认 / 缩进）、转义表（`\r` → `&#13;`）、非法字符拒绝、
  `CdataMode` 三值（含 `]]>` 拆分）、`XmlEntityRef` + `Doctype` + `strictEntities`、
  输出编码 + 输出缓冲 + UTF-16/32 写 BOM + `InvalidCharMode` 往返校验。
- **错误处理**：`XmlException <: f_base.BaseException`，全部带行列号；实体类错误带
  `entityLimitKind`、实体名与已展开量。
- **验收**：xmlconf 20130923 由 `f_xml/tools/xmlconf_gen.py` 按需下载、校验 SHA-256 并生成
  `cases.json` / `unsupported.json` 到 **`f_xml/.cache/xmlconf/`（gitignore，不入库）**；可跑集按
  **五条**规则排除（`edition` 313 + `external-entity` 95 + `xml-1.1` 59 + `external-subset` 48 +
  `namespace-name` 9 = 524），可跑 2062 条、断言 2038 条；`TYPE` 分布由生成脚本实测回填；
  harness 输出 `pass / fail / unsupported`；Gate A 2038 条断言全过，`known-issues`
  **默认清空（0 条）**、只允许登记真正的套件争议且 ≤ 5 条；仓库只保留生成脚本、
  `f_xml/tools/known-issues.json` 与 `f_xml/doc/xmlconf-unsupported.md`。离线且无缓存时测试
  **fail**（不是 skip）并提示先运行生成脚本。
- **单测**：按仓颉 `cjpm test` 的 `@Test` / `@TestCase` 组织，覆盖语法矩阵、组合矩阵、恶意样本、
  往返、推拉事件日志一致、安全上限边界。

## Impact

- **新增代码**：`f_xml/src/*.cj`（约 20 个文件，单包 `fountain::f_xml`）。
- **新增测试**：`f_xml/src/*_test.cj`。
- **入库的工具与清单**：`f_xml/tools/xmlconf_gen.py`（下载 + SHA-256 校验 + 解压 + 生成
  `cases.json` / `unsupported.json`）、`f_xml/tools/known-issues.json`（真正的套件争议，≤ 5 条，
  默认 0 条）、
  `f_xml/doc/xmlconf-unsupported.md`（524 条排除清单）。**原始套件与派生 JSON SHALL NOT 入库**，
  运行时落在 `f_xml/.cache/xmlconf/`。
- **依赖**：**不改**。`f_xml/cjpm.toml` 已有 `fountain::f_base` 与 `cangjie_tpc::charset4cj = "1.0.5"`，
  本次不新增依赖、不升级版本、不改 `f_io` / `f_base` / `f_zip`。
- **对外 API**：`f_xml` 从「零公开声明」变为「约 20 个公开类型 + 6 个静态 `parse` 重载」；
  无既有调用方，不存在破坏性变更。
- **文档**：`f_xml/README.md` / `README_en.md` 由「骨架」改写为能力与示例；新增
  `f_xml/doc/xmlconf-unsupported.md`（524 条 `unsupported` 清单）。套件下载与缓存重建方式写进该文档
  与 `xmlconf_gen.py` 的 `--help`。
- **性能**：事件模式 O(嵌套深度) 内存；DOM 模式约 XML 体积的 5~10 倍。当前实测
  1 MB ≈ 1.5 s / 10 MB ≈ 15.8 s，根因是字符层逐字符 `Option` 分配与三层缓冲
  （`RuneSource` → `LineWindow` → `Lexer`）。**性能在本变更只记录现状、不作门禁**；
  字符层重写另开 `optimize-f-xml-char-layer`，不属于本变更的出口条件。
- **磁盘**：溢出的临时文件峰值 = 该次展开总量（用完即删）；无 `spillDir` 时落到
  `TMPDIR` → 系统临时目录 → `./.fountain_tmp`。

## 与设计文档的差异登记

设计文档内部有几处无法按字面实现，或与仓库现状不一致，本变更按下列方式落地（逐条见
`design.md` §8）：

| # | 设计原文 | 问题 | 本变更的处理 |
|---|---|---|---|
| 1 | §9 `public class XmlException <: Exception` | 仓库所有模块的异常都继承 `f_base.BaseException`（如 `GraphException`） | 继承 `BaseException`，保留 `init(message)` 便捷构造（`line = column = 0`） |
| 2 | §7.6 `public class XmlEntityRef <: XmlNode`，而 §4 把 `XmlNode` 定义成 `enum` | 仓颉不允许类继承 enum，两者互斥 | `XmlNode` 保持 enum，新增 `EntityRefNode(String)` 分支 + 工厂 `XmlEntityRef(name)` |
| 3 | §1.3 依赖 `charset4cj = "1.0.6"` | 仓库 9 个模块（含 `f_base`）全部锁 `1.0.5`，且 1.0.5 的导入路径已是 `charset4cj.charset.*` | 保持 `1.0.5`，不升级；把「1.0.6 才改布局」这条记为设计文档待修正项 |
| 4 | §4 `XmlDocument.builder: DomBuilder` 为 `public let` | 建成后 builder 栈已空，外露只会诱导继续追加 | 改为 `internal`，公开 API 不含 `builder` |
| 5 | §12.8 要求「超深嵌套 1 万层应报错」「超长属性 100 MB 应有上限」 | 设计未给对应配置项 | 新增 `maxElementDepth`（默认 4096）与 `maxAttributeValueLength`（默认 1 MB） |
| 6 | §2.5 要求 UTF-16/32 不走 `readln()`，§2.6 只给两个 `RuneSource` 实现 | 缺一个实现；`InvalidByteMode.Replace` 也需要字节级解码 | 新增 `BlockRuneSource` 与共享 `ByteDecoder`（固定块解码 + 跨块字符边界回退） |
| 7 | §5.4 `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>`「识别并跳过，不校验」 | xmlconf 385 条 `not-wf` 用例的不良构出在声明语法本身；只跳过不校验，良构性缺口永远收不拢 | 升级为**声明语法良构校验**：只验声明产生式，仍不做有效性校验（内容模型与文档匹配、`ID`/`IDREF` 一致性、默认属性注入都不做）；`<!ATTLIST>` 额外建「元素 + 属性 → 类型」映射，**仅**用于属性值规范化 |

## Out of Scope

- **M2（XPath）**：不实现 `selectNodes` / `evaluate` / `XPathContext`；决策 2/14/17 本次不落地。
- **M3（XML 1.1 + C14N）**：不实现 `canonicalize` / `C14nOptions` / `C14nMode`；决策 3/9/15/18/21
  本次不落地；决策 25（保留前缀四处跳过）在 M1 只承担解析侧的两处（元素名 / 属性名）。
- **不做**：DTD **有效性**校验（内容模型与文档匹配、`ID`/`IDREF` 唯一与引用一致性、NOTATION 语义、
  枚举取值是否落在声明列表内、默认属性注入）、外部子集加载、
  NOTATION 语义处理（声明语法良构校验已纳入）、XInclude、xml:base。
- **不做**：性能门槛与字符层重写——现状记录在案，另开 `optimize-f-xml-char-layer`。
- **不比对** xmlconf 的 432 条 `OUTPUT`（需要 C14N，M3）。
- **不改** `f_io` / `f_base` / `f_zip`；临时目录探测按设计 §5.4.2 各模块私有实现，不抽公用工具。
