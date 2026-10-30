# Proposal: 语义层零冗余（名字驻留 + 扫描缓冲复用 + 批量扫描）压到 10 MB < 1 s、VmHWM < 256 MB

> **唯一入库副本**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/`。`openspec/changes/optimize-f-xml-semantic-layer/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 `tasks.md` 7.4）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/optimize-f-xml-semantic-layer/ openspec/changes/optimize-f-xml-semantic-layer/`
> 校验：`diff -ru f_xml/doc/spec/optimize-f-xml-semantic-layer openspec/changes/optimize-f-xml-semantic-layer` 无输出。

## Why

1. **上一个变更把字符层做完了，出口目标还差一截**。`complete-f-xml-m1-followups` 在 `-O2`
   下把 10 MB 事件解析从 16 346 ms 压到 **1101.8 ms**（−93%），但放弃了绝对 1 s 目标，
   并在 `design.md` D13 里明确把它「移交 `optimize-f-xml-semantic-layer`」。同时那一轮的
   RSS 门禁是 `VmHWM(50 MB) ≤ 320 MB`，实测 288.1 MB——**按 256 MB 的口径是超的**。
   本变更承接这两笔账：**10 MB < 1000 ms、VmHWM(50 MB) < 256 MB**。

2. **剩下的时间不再花在字符层**。字符层已经是块解码 + 单活动缓冲，`advanceFast` 吞吐
   81 MB/s、`decodeBatch` 231 MB/s（上一轮 §7.3.1）。10 MB 仍要 1.1 s 说明单位事件成本
   约 **1.44 µs**，与「扫描字符」不再成正比。可归因的三项实测事实：
   - 每条记录约 **6–7 个 `StringGenerator`**（4 次名字扫描 + 1 文本 + 2 属性值），
     10 MB 上约 **180–230 万次**；单次 213–240 ns ⇒ **0.4–0.55 s**；
   - **GC 160–260 ms**，占 15–24%——分配是**双料成本**（CPU + 触发 GC）；
   - 默认 `VmHWM` **242–295 MB**：`cjHeapSize` 默认 256 MB，堆被短命对象长满。

3. **「便宜」的杠杆已经用尽且被证伪**。`cjGCInterval=100ms` 能把 `VmHWM` 压到 165 MB，
   但**一点也没提速**，而且该变量在 OpenHarmony 上不生效；`cjHeapSize` / `cjRegionSize`
   同理。本变更**禁止**用任何 GC 环境变量达标——否则「内存达标」只是换了一台机器的
   运行期参数，`f_xml` 作为库交付时这个保证不存在。调大 `bufSize` 只有 −9%，上一轮
   已判定不构成拐点。

4. **名字是最肥的一块，而且天然可驻留**。10 MB 文档有约 **102 万次** `readName`，
   但不同字面名只有几个。现在每次扫描都新建 `StringGenerator`、扩容内部
   `ArrayList<Byte>`、再 `toString()` 出**一个新的 `String`**——解析器手里已经有
   「一模一样」的 `String` 上千次了。驻留后这 102 万次可以变成「查表命中 + 复用同一个
   `String`」，同时把**存活期**从毫秒级短命对象变成「与解析器同生命周期、数量恒等于
   唯一名字数」的少量对象。

5. **VmHWM 的一部分是基准自己造的**。`SyntheticXmlStream.read()` 每记录调用
   `recordText(n)` 建 `String` 再 `.toArray()`：10 MB 25 万次、50 MB 125 万次。
   这些分配与解析器无关却计进 `VmHWM` 与耗时。不修基准就永远测不准语义层——
   但它必须先修、且新旧代码共用同一份修正后的基准，否则对照不成立。

6. **不能拿契约换速度**。公开类型与方法签名零变更；推 / 拉 / 单回调三种前端的事件日志
   逐行一致；Gate A 2038 / 0 / 524 与五条排除规则不变；错误消息与行列号不变。名字驻留
   一旦有碰撞误判，就会静默产生**错误的 `local`**——这是本变更最危险的失效模式，必须用
   「逐 rune 比对」和同 hash 反例用例挡住。

## What Changes

范围仅 `f_xml/`。四组改动 + 一个先决条件。

### A. 先决条件：基准自身不再分配（否则 Gate 不可信）

- `SyntheticXmlStream` 改成「按需写字节」：记录内容直接写进调用方的 `buffer`
  （十进制数字逐位写），**不再** 每条记录 `recordText(n)` + `toArray()`。
- 字节流 SHALL 与旧实现**逐字节一致**（用例用固定 golden 覆盖 1 KB / 64 KB / 带边界值
  的条数），保证新旧对照的输入完全相同。
- 10 MB 与 50 MB 拆成两个独立测试类（`PerfTen_test` / `PerfFifty_test`），
  各自 `cjpm test --filter` 单进程运行；`VmHWM` 是单调峰值，同进程内先跑 10 MB
  会污染 50 MB 的读数。
- 每轮打印 `nproc` / `loadavg` / `env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` 的结果，作为「空载 + 默认运行时」
  的证据；`max/min > 1.4` 的轮次标记不可信。

### B. 名字驻留（`NameTable`）

- 扫描 `readName` 时**增量**算 FNV-1a hash 与码点长度，同时把码点append进复用的
  `nameScratch`；扫描结束先用 `(hash, 长度)` 定位候选，再**逐 rune（实现上比较 UTF-8
  字节序列）比对**确认，命中直接复用表里的 `String`，未命中才 `toString()` 并插入。
- 表项同时保存**已切分**的 `prefix` / `local`：命中的名字连「按 `:` 切片」都省掉
  （当前 `text[0..idx]` / `text[idx+1..]` 每次调用分配两个 `String`）。
- 开放寻址、负载因子 ≤ 0.5、容量翻倍重建；条目数上限（默认 65 536）**硬停插**，
  超过只降级为「不驻留」——正确性不变，内存有界（不随文档线性增长）。
- 暴露 `internal` 计数（`hits` / `misses` / `insertions` / `distinct`），用例据此
  断言「10 MB 上 miss 次数 == 唯一名字数」，把「确实驻留」变成结构性断言而不是看耗时。

### C. 扫描缓冲复用（去掉每 token 的 `StringGenerator`）

- `Lexer` 持有 **三条**复用缓冲：`nameScratch`、`valueScratch`、`textScratch`；
  进入对应扫描时 `reset()`，不再 `StringGenerator()` 局部构造。
- 先验证 `StringGenerator.reset()` 是否保留底层容量（微基准 + RSS）；不保留则改用
  `f_xml` 内部自有 scratch（`Array<Byte>` 倍增、只增不减），**不改 `f_base`**。
- 去掉 `collapseSpaces` / `readComment` / `readCdata` 等处的**每次调用**新建；
  DTD 冷路径若难以复用可保留，但必须在 `design.md` 白名单中逐条登记。

### D. 文本与属性值批量扫描

- `LineWindow` 增加 `internal` 块视图（`runAvailable` / `cpAt` / `skipRun`），**不进公开
  API**。词法器在活动块上找下一个停止字符（文本：`<` / `&` / `]`；属性值：引号 / `&` /
  `<` / 三个空白），整段读取并 `skipRun(n)` 一次推进，不再逐字符 `peekCp` / `advanceCp`。
- 纯 ASCII 段走「码点即字节」直写；非 ASCII 或控制字符**退回**逐字符路径，保证
  `isXmlChar` 校验与报错位置逐字符不变。
- `isXmlChar` 在 ASCII 区间加 128 项查表（热路径 O(1)、无分支链）。
- 跨块边界（剩余不足或需要 refill）自动退回逐字符路径，语义不变；块视图在
  refill/压缩时会失效，因此**先取可用长度、再拷贝、最后一次性推进**。

### E. 事件侧缓冲区复用

- `Lexer.readStartTag` 的 `ArrayList<RawAttribute>` 改为复用容器（每标签 `clear()`）。
- `ParserEngine.openElement` 的 `resolved` / `seen` 改为复用容器，最终
  `Array<XmlAttribute>(n)` **按长度一次分配**并按索引填充（替代 `ArrayList` 增长 +
  `toArray()` 的二次分配）。
- **不改任何公开类型**：`XmlEvent.StartElement(QName, Array<XmlAttribute>, Bool)` 仍然
  持有独立数组；用例必须证明「上一个事件的对象在一次 `nextEvent()` 之后仍然完整」
  （复用不得造成跨事件别名）。

### F. Gate（默认运行时，绝对 + 同轮对照）

| Gate | 标准 | 判定 |
|---|---|---|
| **T**（时间） | 10 MB `min(5) < 1000 ms` | 独立进程、空载、`-O2`、默认运行时 |
| **T-对照** | `new_min(10 MB) ≤ 0.95 × old_min(10 MB)`（同轮同机） | 证明增益来自代码 |
| **M**（内存） | `VmHWM(50 MB) < 256 MB` | 独立进程、只跑 50 MB |
| **M-不回归** | `VmHWM(50 MB)` 不高于改前 | 只记录 + 断言不恶化 |
| **A**（沿用） | `pass + known == 2038`、`fail == 0`、`unsupported == 524` | `XmlconfHarness_test.fullSuite` |
| **R**（回归） | 337 条仓颉用例 + 4 条 Python 用例全过；`cjpm build` 不新增未说明的 WARNING | `cjpm test` / `unittest` |

- 任一轮 `max/min > 1.4` 视为负载污染，重测；不允许在污染轮次上判正或判负。
- 未达标**不许**放宽阈值、**不许**加环境变量；按 `design.md` §8 的阶梯继续做，
  或回到用户处重新裁定 Gate。

## Impact

- **新增代码**：`src/NameTable.cj`（名字驻留 + 计数）、`src/NameTable_test.cj`、
  `src/SemanticPerf_test.cj`（三段占比与分配计数）、`src/TextScan_test.cj`
  （批量扫描等价性）、`src/BufferReuse_test.cj`（复用无别名）。
- **修改代码（全部内部实现）**：`src/Lexer.cj`（`readName` / 文本 / 属性值 / 三条 scratch /
  `attrs` 复用 / ASCII 查表）、`src/LineWindow.cj`（`internal` 块视图）、
  `src/ParserEngine.cj`（`resolved` / `seen` 复用 + 精确数组）、`src/XmlChars.cj`
  （ASCII 查表）、`src/Perf_test.cj`（无分配合成流 + 拆两个 Gate 类）、
  `src/Perf_test` 的 RSS/负载输出。
- **公开 API**：**0 处变更**。`LineWindow` 新增成员全部 `internal`；`NameTable` 是
  `internal class`；`XmlEvent` / `QName` / `XmlAttribute` / 各种 `Options` 一字不动。
- **依赖**：不改。不动 `f_base` / `f_io`；不升级 `charset4cj`。
- **性能目标**（同轮同机对照，见 `baseline.md` §3）：

  | 场景 | 改前（上一轮 `-O2`） | 本变更 Gate |
  |---|---|---|
  | 事件模式 10 MB | 1101.8 ms（用户本轮 242–295 MB 口径下同量级） | **< 1000 ms（min of 5）** |
  | 事件模式 1 MB | 80.1 ms | 记录，不设上限 |
  | 事件模式 50 MB | 5422.6 ms | 记录，不设上限 |
  | `VmHWM(50 MB)` | 288.1 MB（默认运行时 242–295 MB） | **< 256 MB** |

- **测试规模**：现有 **337** 条 `@TestCase` 全部保持通过（一条不删、期望不改）；
  新增约 22–28 条仓颉用例；Python 4 条不变。
- **磁盘 / CI**：50 MB 仍由流合成，不新增入库测试数据；10 MB / 50 MB Gate 用例
  仍由 `F_XML_PERF=1` 开关，默认 `cjpm test` 不跑。
- **风险**：`VmHWM` 由运行时堆策略主导，256 MB 与默认 `cjHeapSize` 恰好同量级，
  余量很小；能否达标取决于「分配量下降是否足以让堆不去长满」。这一点只在实测里
  回答，因此 `design.md` §8 给了四级阶梯（全部在代码侧，不含环境变量），
  并明确「阶梯用尽仍不达标 → 回到用户处重裁 Gate」。

## Out of Scope

- **不用任何 GC 环境变量**：`cjHeapSize` / `cjGCInterval` / `cjRegionSize` 一个都不设；
  Gate 只在「默认运行时」下成立。OpenHarmony 上这些变量不生效，靠它们达标等于造假。
- **不改公开 API**：不新增 / 删除 / 重命名任何 `public` 类型、方法、参数或默认值；
  不新增配置项；`XmlEvent` 的 10 个分支一个不动。
- **不改默认 `bufSize`**：仍是 8192（上一轮 D5 的结论仍然有效）。
- **不做 DOM 门禁**：DOM 的耗时与内存只记录。DOM 另有节点对象成本，混进来会把
  「语义层零冗余」变成「DOM 重写」。
- **不改 `f_base`**：`StringGenerator` 的行为与 API 不动；若 `reset()` 不保留容量，
  在 `f_xml` 内自建 scratch，而不是去改 `StringGenerator`。
- **不消除 `XmlEvent` / `Option<XmlEvent>` 的每事件分配**：公开枚举的载荷语义决定
  必须产出新事件对象。只记录它占多少，不算作缺陷。
- **不改 xmlconf 判定逻辑**：五条排除规则与 2062 / 524 / 2038 三个数字原样沿用。
- **不做 M2 / M3**：XPath、C14N、XML 1.1 一行都不写。
