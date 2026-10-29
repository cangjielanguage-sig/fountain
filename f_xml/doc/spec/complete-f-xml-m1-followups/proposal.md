# Proposal: 完成 f_xml M1 遗留（字符层性能重写 + P3 验收补强）

> **唯一入库副本**：`f_xml/doc/spec/complete-f-xml-m1-followups/`。`openspec/changes/complete-f-xml-m1-followups/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 `tasks.md` 11.4）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/complete-f-xml-m1-followups/ openspec/changes/complete-f-xml-m1-followups/`
> 校验：`diff -ru f_xml/doc/spec/complete-f-xml-m1-followups openspec/changes/complete-f-xml-m1-followups` 无输出。

## Why

1. **M1 最重要的出口目标没达成**：`implement-f-xml-m1` 只把性能「记录在案」——事件模式
   1 MB ≈ 1.5 s、10 MB ≈ 15.8 s（开发机、单线程）。设计文档 §13.2 的原始要求是
   **10 MB < 1 s**，差了一个数量级。M1 已把重写整体移交给后续变更，本变更承接这笔欠账。
2. **根因已经定位，且证明调参无效**：字符层逐字符返回 `?Rune`（仓颉 `Option` 是引用类型，
   每字符一次堆分配）+ 三层缓冲（`RuneSource` 逐字符解码 → `LineWindow` 环形缓冲 →
   `Lexer` 输入栈）。M1 已经做过 `peekFast` / `advanceFast`、去掉两层 `ArrayList`，
   **合计只有约 15% 收益，量级不变**——这说明瓶颈是结构，不是常数，必须按块改写。
3. **下游等不起**：10 MB 级 POM / OOXML / RSS 是 `f_xml` 的主要目标场景；15.8 s 意味着
   服务端单请求延迟不可接受，也会把线程池长期占住。反过来，事件模式本来就是流式设计，
   RSS 不应随文档线性增长——现在这一点**没有任何自动化断言证明**。
4. **M1 验收留下了三条 P3 缺口，归档后无法追溯**（`verification.md` §3）：
   `SpillDir` 四级全失败的报错分支没有自动化用例（只覆盖成功路径）；「两个解析器实体计数
   互不影响」只有实现、没有用例；`xmlconf_gen.py` 的 SHA-256 不匹配分支只有代码、没有
   自动化验证。三条都属于「行为存在但没证据」，补齐成本低、收益是让 M1 的验收证据闭环。
5. **重写不能靠「跑得快」换取契约漂移**：公开类型与方法签名、事件序列、错误语义与
   `InvalidByteMode` 两条路径的输出必须逐字符不变；xmlconf 的五条排除规则与 2038 条断言
   必须原样沿用。性能只有在这个前提下才算达成。

## What Changes

本变更只做两件事：**字符层性能重写**与**P3 验收补强**。范围仅 `f_xml/`。

### A. 字符层性能重写（内部实现，公开签名不变）

- **块解码**：`BufferedRuneSource` 从「每字符一次 `pull()`」改为「一次填充 N 个码点到
  `Array<Int32>`」。`ByteDecoder` 增加块级入口（UTF-8 严格 / 替换、UTF-16LE/BE、UTF-32LE/BE
  共用），`ByteReader` 增加连续 ASCII 段批量搬运。码点块容量 = `max(64, bufSize)`，
  内存上界固定（64 K `bufSize` → 256 KB）。
- **三层缓冲合并**：`BufferedRuneSource` 新增内部块读入口，`LineWindow` 直接把
  `BufferedRuneSource` 的码点块填进**自己的**唯一活动缓冲（不再是两级环形缓冲），
  归一化（`\r\n` / 孤立 `\r` → `\n`）在块填充时就地完成；`\r` 落在块尾、`\n` 落在下一块
  开头时用 `pendingSkipLf` 状态跨块处理，**只归一一次**。非块源（自定义 `RuneSource`）
  自动回退到逐字符填充，语义不变。
- **Lexer 热路径码点化**：`nextContentToken` / `nextMarkupToken` / `readMarkup` /
  `readStartTag` / `readAttributeValue` / `skipWhitespace` / `trySkipWhitespace` /
  `startsWith` / `consume` / `readReference` / 注释 / CDATA / PI / 声明 / DOCTYPE 的扫描
  全部走 `peekCp` / `advanceCp`（`Int64`，`-1` 表示 EOF），热路径不再出现
  `?Rune`、`match (Some/None)` 与 `r.position()`。
- **实体输入帧同步块化**：`StringFeed` / `SinkFeed` 的缓冲从 `Array<Rune>` /
  `ArrayList<Rune>` 改为 `Array<Int32>`；`ExpandReader` 增加 `nextCp()` 码点入口，
  溢出文件读回不再每字符分配 `Option`。
- **可测性**：`BufferedRuneSource` 暴露内部计数（块填充次数 / 已产出码点数），用例据此
  **结构性断言「确实在按块解码」**（块填充次数 ≤ 码点数 / 64），而不是只看耗时。

### B. 性能验收（本变更的 Gate）

- 新增 `src/Perf_test.cj`：用**合成 `InputStream`**（不落地 50 MB 测试文件）生成精确字节数的
  1 / 10 / 50 MB 文档，事件模式解析并计时。
- Gate：**10 MB `min(3 次) < 7200 ms`（相对本机基线 9649 ms 提升 ≥25%）**；RSS 用 `/proc/self/status` 的 `VmHWM`，
  **`VmHWM(50 MB) − VmHWM(10 MB) ≤ 24 MB`** 且 `VmHWM(50 MB) ≤ 256 MB`。
  1 MB 与 50 MB 的耗时只记录、不设上限。
- 基准用例默认不跑（`F_XML_PERF=1` 才启用）；默认 `cjpm test` 保持原有耗时。
- **R5 `bufSize` 实测**：1 MB / 10 MB 文档 × `4K / 8K / 16K / 64K`，各取 3 次最小值，
  记录吞吐曲线；结论回填 `design.md` §7.3、`f_xml/doc/f_xml模块设计.md` §15.1 与
  `f_xml/README.md`。**默认值仍为 8192**，本变更不改默认（避免无谓的行为面变化）。

### C. P3 验收补强

- **`SpillDir` 四级全失败路径**：把「候选解析」与「逐个尝试创建」拆成可注入的内部函数
  （`createFileFrom(candidates, fallback)`），用例用四个「已存在但不是目录」的路径稳定
  触发四级全失败，断言抛 `XmlException`、消息含 `spillDir`、**不降级回内存**。
- **两个解析器实体计数独立**：新增交错驱动用例（逐事件交替推进两个 `XmlPullParser`，
  断言各自 `totalExpanded()` 互不影响）+ 双线程用例（`spawn`，两份接近上限的文档都成功）。
- **`xmlconf_gen.py` SHA-256 不匹配分支**：抽出 `ensure_sha256(path, expected) -> int`，
  新增 `f_xml/tools/test_xmlconf_gen.py`（`unittest`）：既做函数级断言，也用
  `--offline` + 伪造损坏包做端到端断言（退出码 2、stderr 含期望 / 实际值、不产出
  `cases.json`）。

### D. 回归护栏与文档

- 公开类型 / 方法签名**零变更**：以「改动前后公开声明清单 diff 为空」为验收项。
- 事件日志、错误消息与行列号、`InvalidByteMode` 两条路径的逐字符输出、推拉一致性、
  xmlconf Gate A（2038 / 524 / fail=0）全部复用既有用例，不允许下调断言。
- 文档回填：`design.md` §7.3（性能实测）、`f_xml/doc/f_xml模块设计.md` §15.1（性能现状
  改写为达成值）、`f_xml/README.md`（性能段落与用例数校正）、
  `implement-f-xml-m1/design.md` §10.1 的 R5 条目（由「未做」改为「已实测」并指向本变更）。

## Impact

- **新增代码**：`f_xml/src/Perf_test.cj`（基准）、`f_xml/src/CharLayerParity_test.cj`
  （块大小 / 编码等价性）、`f_xml/src/SpillDirFallback_test.cj`（四级失败）、
  `f_xml/src/EntityCounterIsolation_test.cj`（计数独立）、`f_xml/tools/test_xmlconf_gen.py`。
- **修改代码（内部实现）**：`src/RuneSource.cj`、`src/LineWindow.cj`、`src/Lexer.cj`、
  `src/ExpandSink.cj`（`SpillDir` seam、`ExpandReader.nextCp`）、`src/EntityExpander.cj`、
  `src/XmlChars.cj`（`Int64` 判定重载）、`src/ParserEngine.cj`（仅在需要时接码点帧）；
  `tools/xmlconf_gen.py`（抽 `ensure_sha256`）。
- **公开 API**：**0 处变更**。`RuneSource` / `LineWindow` / `XmlParser` /
  `XmlPullParser` / `XmlParserOptions` / `EntityLimits` 的方法签名与默认值全部不动；
  新增的块 seam 与计数全部 `internal`。
- **依赖**：不改。`cjpm.toml` 不动，不升级 `charset4cj`。
- **性能**（开发机、单线程、release）：

  | 场景 | 改动前（M1） | 本变更 Gate |
  |---|---|---|
  | 事件模式 1 MB | ≈ 1.5 s | 记录（预期 < 100 ms） |
  | 事件模式 10 MB | ≈ 15.8 s | **< 7.2 s（min of 3，相对基线 ≥25%）** |
  | 事件模式 50 MB | 未测（按线性外推 ≈ 79 s） | 记录 + RSS 断言 |
  | `VmHWM(50 MB) − VmHWM(10 MB)` | 无断言 | **≤ 24 MB** |

- **测试规模**：现有 303 条 `@TestCase`（`verification.md` 口径；README 的 298 是旧数字，
  本变更顺带校正）全部保持通过；新增约 20 条仓颉用例 + 3 条 Python 用例。
- **CI / 磁盘**：50 MB 文档由流合成，**不新增入库测试数据**；基准默认关闭，不拖慢日常
  `cjpm test`。
- **风险**：`VmHWM` 受 GC 与分配器保留策略影响，阈值需在目标机校准一次并写回
  `design.md`；若 10 MB < 7.2 s 在块解码后仍差一点，按 `design.md` §13 的备选阶梯继续
  （先量文本累积，再考虑 ASCII 快车道），**不通过放宽 Gate 来收尾**。

## 与 `implement-f-xml-m1` 的关系

| M1 移交项 | M1 原文 | 本变更落点 |
|---|---|---|
| 字符层重写 | `design.md` §13、`proposal.md` Out of Scope「性能门槛与字符层重写」 | 本变更 A 部分；Gate 见 B 部分 |
| R5 `bufSize` 实测 | `design.md` §10.1「未做，留待重写后一并实测」 | 本变更 B 部分第 4 条 |
| `SpillDir` 四级失败 | `verification.md` §3 第 1 条 | 本变更 C 部分第 1 条 |
| 双解析器计数独立 | `verification.md` §3 第 2 条 | 本变更 C 部分第 2 条 |
| SHA-256 不匹配分支 | `verification.md` §3 第 3 条 | 本变更 C 部分第 3 条 |

变更名不再使用 M1 预留的 `optimize-f-xml-char-layer`：本次还包含三项验收补强，
`complete-f-xml-m1-followups` 才是准确的名字。M1 文档里的旧名字保留为历史记录，
在 `tasks.md` 11.5 里补一行指向说明。

## Out of Scope

- **不改公开 API**：不新增/删除/重命名任何 `public` 类型、方法、参数或默认值；不新增配置项。
- **不做 DOM 模式性能门禁**：DOM 的内存与耗时只记录。事件模式达标不代表 DOM 达标，
  把 DOM 拉进门禁会让「字符层重写」变成「DOM 重写」。
- **不改默认 `bufSize`**：R5 只产出建议值，默认仍是 8192。
- **不消除 `CharsetRuneSource` 的逐字符 `Option`**：`charset4cj.TextReader` 只提供
  `read(): ?Rune`，在不动第三方库的前提下无法批量取码点。本变更只保证它不在 Lexer 热路径上
  （填充进块后，热路径看码点）；该例外写进 `design.md` §3.8 与 spec。
- **不做 M2 / M3**：XPath、C14N、XML 1.1 一律不碰。
- **不改 `f_base` / `f_io` / `f_zip`**：`StringGenerator` 的行为与 API 不动。
- **不改 xmlconf 可跑集口径**：五条排除规则、2062 / 524 / 2038 三个数字原样沿用；
  本变更只补脚本自身的测试，不动判定逻辑。
