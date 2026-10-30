# Design — optimize-f-xml-semantic-layer

> 范围：只改 `f_xml/`。本文件描述**怎么做**；契约见 `specs/f-xml-semantic-layer/spec.md`，
> 执行顺序见 `tasks.md`。设计基线是 `complete-f-xml-m1-followups/design.md`（尤其 §3、§4.4、
> §6、§13、D13）；本文件只写增量，不重复已有决策。
>
> **前置事实（实施后已补齐）**：`baseline.md` §3 的同轮实测已采集（旧代码 = `git archive HEAD`
> + 同一份新基准）。实测：旧 10 MB `min = 1026.4 ms`、`VmHWM(50 MB) = 295 136 kB`；
> 新 10 MB `min = 497.0 ms`、`VmHWM(50 MB) = 104 280 kB`。Gate T / T-对照 / M / M-对照
> 全部达成，§8 的阶梯一级都没用。明细见 `verification.md` §2。

## 1. Gate 与不变量

### 1.1 Gate

| Gate | 标准 | 判定方式 |
|---|---|---|
| **T** | 10 MB `min(5) < 1000 ms` | `F_XML_PERF=1 cjpm test --filter=PerfTen_test`（独立进程） |
| **T-对照** | `new_min ≤ 0.95 × old_min`（同轮同机） | 同一份基准跑旧 / 新代码各 5 次 |
| **M** | `VmHWM(50 MB) < 262 144 kB` | `F_XML_PERF=1 cjpm test --filter=PerfFifty_test`（独立进程） |
| **M-对照** | `new_hwm ≤ old_hwm` | 同上，只记录 + 断言不恶化 |
| **A** | `pass + known == 2038`、`fail == 0`、`unsupported == 524` | `XmlconfHarness_test.fullSuite` |
| **R** | 337 + 4 条用例全过；WARNING 不新增未说明项 | `cjpm test` / `unittest` |

- 三条前置条件缺一不可：**默认运行时**（`env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` 为空）、**空载**
  （1 分钟负载 ≤ `0.5 × nproc`）、**独立进程**（`VmHWM` 是单调峰值）。
- 一轮 5 次里 `max / min > 1.4` → 该轮标记「负载污染」，重测。**不许**在污染轮次上判正，
  也不许据此判负（本机同代码重复测量可达 1.4 倍差异）。
- 未达标按 §8 阶梯继续；阶梯用尽 → 回到用户处重裁 Gate。**不放宽阈值、不加环境变量。**

### 1.2 不变量

1. 公开类型 / 方法签名 / 参数名 / 默认值零变更；新增成员全部 `internal`。
2. 事件序列、文本内容、事件拆分边界逐字节不变；推 / 拉 / 单回调三种前端日志逐行一致。
3. 错误消息、`line` / `column`、`entityLimitKind` 不变。
4. `InvalidByteMode.Strict` / `Replace` 逐字符输出不变。
5. 驻留命中 SHALL NOT 产生错误的 `local` / `prefix`（碰撞误判是本变更最危险的失效模式）。
6. 复用容器 SHALL NOT 造成跨事件别名。
7. 驻留表与复用缓冲的内存有界，不随文档线性增长。
8. 五条 xmlconf 排除规则与 2062 / 524 / 2038 三个数字不变。

## 2. 分配预算：钱花在哪

按本仓合成流模板（每条记录 `<item id="N" a="v">text-N</item>`，10 MB = 254 951 条）：

| 环节 | 次数 / 10 MB | 单次实测 | 小计 | 本变更后 |
|---|---|---|---|---|
| `readName` 的 `StringGenerator` 构造 | 4 × 254 951 ≈ **102 万** | 213–240 ns | 0.22–0.24 s | **0**（驻留命中，仅保留 scratch） |
| 名字结果 `String` 分配 | 102 万 | — | GC 压力 | **≈ 唯一名字数**（个位数） |
| 文本 `StringGenerator` | 25.5 万 | 213–240 ns | 0.05–0.06 s | 构造 → 0（复用），`String` 仍 1 次/记录 |
| 属性值 `StringGenerator` | 51 万 | 213–240 ns | 0.11–0.12 s | 构造 → 0，`String` 仍 1 次/值 |
| `ArrayList<RawAttribute>` + 扩容 | 25.5 万 | — | 未测 | 0（复用） |
| `ArrayList<XmlAttribute>` + `toArray()` | 25.5 万 ×2 | — | 未测 | 1 次精确 `Array` 分配 |
| `ArrayList<QName>`（去重） | 25.5 万 | — | 未测 | 0（复用） |
| `XmlEvent` + `Option` 包装 | 76.5 万 | — | 未测 | **不变**（公开类型决定，只记录） |
| 基准自身 `recordText` + `toArray` | 25.5 万（50 MB 上 125 万） | — | 计入 `VmHWM` | **0**（§3） |

三条结论：

1. `StringGenerator` 的**构造 + 内部 `ArrayList<Byte>` 扩容 + `toString`** 合计约
   0.38–0.43 s（按用户口径 230 万次则 0.49–0.55 s），是 1.1 s 里最大的一块；
2. 名字的**结果 `String`** 是唯一「可以整类消灭」的存活分配（102 万 → 个位数），
   对 GC 与 `VmHWM` 是双料收益；
3. 文本与属性值的 `String` **不能**消灭（事件的公开载荷），只能消灭「容器构造」这层。

## 3. 先决条件：基准不能自己分配

### 3.1 `SyntheticXmlStream` 改为零分配

现状（`Perf_test.cj`）：`read()` 每写满一条记录就 `recordText(n).toArray()` →
1 个 `String` + 1 个 `Array<Byte>`，10 MB 25.5 万次、50 MB 125 万次。这不是解析器成本，
却是 `VmHWM` 与费时的实打实来源。

改法：`read()` 直接往调用方的 `buffer` 写字节，十进制数字**逐位写**：

```cangjie
// 一条记录的字节布局：<item id="N" a="v">text-N</item>
// 逐段写入 buffer；数字按位（最多 20 位）写入，不建临时数组、不建 String。
private func writeRecord(buffer: Array<Byte>, offset: Int64, n: Int64): Int64
```

- `recordLength(n)` 与 `totalBytes()` 的算式**不变**，因此事件数、字节数与旧基准完全相同。
- 用例新增 `syntheticStreamGolden`：对 1 KB / 64 KB / 含 9→10、99→100 位数进位的条数，
  断言新基准产出的字节序列与 **旧实现**（用例内置一份参照实现）逐字节一致。
  这条断言是「新旧对照输入相同」的唯一证据，必须最先落地。
- 这是**测试代码**的改动，不进交付库；但它决定 Gate 是否可信，所以排在最前面。

### 3.2 拆成两个 Gate 类、两个进程

`VmHWM` 是进程生命周期内的**单调峰值**：同一进程先跑 10 MB（5 次）再跑 50 MB，
50 MB 的峰值已经被 10 MB 垫高，读数是假的。因此：

| 类 | 用例 | 进程内做什么 |
|---|---|---|
| `PerfTen_test` | `gateTenMegabytes` | 只跑 10 MB × 5 次 |
| `PerfFifty_test` | `gateFiftyMegabytes` | 只跑 50 MB × 1 次（记录 `VmHWM`） |
| `Perf_test` | 原有冒烟 / 矩阵 / 合成流自检 | 保持默认关闭语义 |

两个 Gate 类都先打印「环境三件套」：`nproc`、`/proc/loadavg`、`env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` 的结果
（后两项用 `File` 读 `/proc`、用 `std.env.getVariable` 探测已知 GC 变量名）。
环境不干净或负载超限时，用例 **打印 `gate: invalid (env/load)` 并直接返回**，
不产生假的 pass/fail——判定交给人工看输出。

### 3.3 分段计时（诊断用，非门禁）

`SemanticPerf_test` 提供一次性诊断：在同一份 1 MB 文档上分别测
「纯 `advanceFast` 扫字符」「`readName` 全流程」「文本扫描」「属性值扫描」的耗时与分配计数，
输出到 stdout。它只在 Gate 未达标时用来决定 §8 走哪一级阶梯，不参与判定。

## 4. 名字驻留

### 4.1 数据结构

```cangjie
/** 名字驻留表：开放寻址 + 逐 rune 比对。条目数有界，超出停止插入。 */
internal class NameTable {
    private var slots: Array<Int64>          // 槽位 → 条目下标；-1 空
    private var mask: Int64                  // 容量 - 1（容量是 2 的幂）
    private var hashes: ArrayList<Int64>
    private var texts: ArrayList<String>     // 完整字面名（含冒号）
    private var locals: ArrayList<String>    // 已切分的本地名
    private var prefixes: ArrayList<Option<String>>
    private let maxEntries: Int64            // 默认 65536

    var hits: Int64 = 0
    var misses: Int64 = 0
    var insertions: Int64 = 0
}
```

- **hash**：FNV-1a 64，扫描时逐码点增量计算
  `h = (h ^ cp) * 0x00000100000001B3`，初值 `0xCBF29CE484222325`。ASCII 时等价于字节 hash。
- **容量**：初始 64，负载因子 > 0.5 时翻倍重建（重建只搬运已有条目，代价由唯一名字数决定，
  与文档大小无关）。
- **条目上限**：达到 `maxEntries` 后停止插入，`hits/misses` 继续统计。退化路径仍然正确。
- **比较**：`texts[e].unsafeBytes()` 与 `nameScratch.unsafeBytes()` 逐字节比长度与内容。
  两侧都是同一编码器产出的 UTF-8，字节序列相等 ⟺ 码点序列相等，所以这就是「逐 rune 比对」，
  且比逐 rune 少一次解码。**绝不**只比 hash。

### 4.2 `readName` 的改法

```cangjie
func readName(): RawName {
    let pos = this.position()
    let gen = this.nameScratch.reset()      // 复用，不新建
    var hash: Int64 = 0xCBF29CE484222325
    var count: Int64 = 0
    var colonSeen = false
    var first = true
    while (true) {
        let cp = this.peekCp(0)
        ... // 校验 isNameStartChar / isNameChar 与冒号规则，全部照旧
        if (cp == 0x3A) {
            if (colonSeen || first) { throw this.error("名字里出现非法的冒号") }
            colonSeen = true
        }
        gen.append(Rune(cp))
        hash = (hash ^ cp) * 0x00000100000001B3
        count++
        this.advanceCp()
        first = false
    }
    if (first) { throw this.error("缺少名字") }
    // 查表：命中直接复用（含已切分的 prefix / local），零 String 分配
    if (let Some(entry) <- this.names.lookup(hash, gen, colonSeen)) {
        return RawName(entry.prefix, entry.local, pos.line, pos.column)
    }
    let text = gen.toString()               // 未命中才建 String
    ... // 冒号切分与空前缀 / 空本地名报错，全部照旧
    this.names.insert(hash, text, prefix, local)
    RawName(prefix, local, pos.line, pos.column)
}
```

要点：

1. **一次扫描**，没有「先 peek 一遍再 advance 一遍」——`peekFast` 只保证 `offset ≤ 8`，
   长名字无法二次前瞻。
2. 切分只在未命中路径做；命中路径省掉两次 `substring`（带前缀名字每记录省 2 个 `String`）。
3. 冒号合法性、空前缀 / 空本地名的**报错时机与消息**完全不变（在插入前做，和在 `readName`
   末尾做等价）。
4. `readName` 也被 `readReference`（`&name;`）与 `readPiOrDeclaration`（target）调用，
   一并受益，无需额外改动。

### 4.3 为什么不在 `ParserEngine` 驻留 `QName`

`QName` 是 `struct`（`prefix` / `local` / `uri` 三个字段），本身不分配；它持有的 `String`
才是成本。驻留 `local` 已经把 `QName` 的字符串开销压掉了。驻留整个 `QName` 只省一个
24 字节的栈/结构体拷贝，却要引入「`uri` 由命名空间栈决定」的失效风险（同一个 `local`
在不同作用域可能是不同 `QName`），**不做**。

## 5. 扫描缓冲复用

### 5.1 三条复用缓冲

`Lexer` 新增三个字段，生命周期 = 一次解析：

| 字段 | 服务对象 | 清空点 |
|---|---|---|
| `nameScratch` | `readName`、`readReference` 的名字部分 | `readName` 入口 |
| `valueScratch` | `readAttributeValue`、`readDeclarationValue`、`readQuoted` | 各入口 |
| `textScratch` | `nextContentToken`、`nextMarkupToken` 的裸文本、CDATA、注释、PI 数据、内部子集 | 各入口 |

- `StringGenerator.reset()` 是 `utf8.clear()`（`ArrayList<Byte>`）。**实测（`tasks.md` 0.4）：
  保留容量**——同一实例 `reset + 10000 append` × 2000 次 111.6 ms，每次新建 115.9 ms
  （比值 0.96）；500 万次 `reset + append(1 字节)` 每百万 8.3–8.6 ms、RSS 仅 +60 kB，
  无上台阶。结论：**文本 / 属性值 / 声明值一律复用 `reset()` 实例**，未启用 §5.3 的替换。
- **名字**是例外：`StringGenerator.unsafeBytes()` 返回按 `size` 截好的**新数组**
  （探针：填 10000 取 10000；reset 后 append 1 取 1），逐字节比对会每 token 分配一次。
  因此名字扫描独用 §5.3 的 `ByteScratch`（零拷贝视图 + 只增不减），文本与值仍走
  `StringGenerator`，两者输出逐字节一致（`BufferReuse_test.byteScratchMatchesStringGenerator`）。
- `toString()` 仍然每 token 一次（事件的公开载荷是 `String`），这是**必须**的分配，
  不在优化目标内；目标是消掉「容器对象 + 容器扩容」这一层。

### 5.2 允许保留新建的白名单

| 位置 | 保留理由 |
|---|---|
| `collapseSpaces` | 只在 DTD 声明了 tokenized 属性类型时走；每次调用对新 `String` 做二次归一，复用会引入递归复用风险 |
| `XmlEvent.escape`（`ToString`） | 只在事件日志 / 调试路径，不在解析热路径 |
| `DoctypeParser` / `SkipScanner` | 冷路径，且它们的 `StringGenerator` 生命周期跨越整个内部子集 |
| `EntityExpander` 的替换文本累积 | 受实体上限与溢出策略约束，本变更不碰 |

白名单 SHALL 在 `tasks.md` 3.4 用 `grep -n 'StringGenerator()' src/Lexer.cj` 复核，
只允许剩上表列出的位置。

**实测复核（2026-10-30）**：`grep -n 'StringGenerator()' src/Lexer.cj` 只剩三处——

| 行 | 位置 | 说明 |
|---|---|---|
| 72 | `collapseSpaces` | 白名单内（tokenized 属性的二次归一，冷路径） |
| 143 | `valueScratch` 字段 | 一次解析只构造一次 |
| 145 | `textScratch` 字段 | 一次解析只构造一次 |

即热路径上**没有任何**逐 token 的 `StringGenerator()` 构造。

### 5.3 自有字节累积器（**实际只用于名字扫描**，见 §5.1 与 D16）

```cangjie
/** 只增不减的 UTF-8 字节累积器：reset 只把长度置 0，容量留作下次复用。 */
internal class ByteScratch {
    private var buf = Array<Byte>(256, repeat: 0)
    private var len: Int64 = 0
    func reset(): ByteScratch
    func putAscii(b: Int64): Unit
    func putCp(cp: Int64): Unit        // 非 ASCII 走 Rune.intoUtf8Array
    func toUtf8String(): String         // String.fromUtf8Unchecked(buf[0..len])
    func bytes(): Array<Byte>
}
```

- 与 `StringGenerator` 的差异只在「不释放容量」，输出逐字节相同（用例对拍）；
- 实际启用的范围**只有名字缓冲**：`Lexer.nameScratch`。文本 / 属性值 / 声明值 / CDATA /
  注释 / PI 仍用 `StringGenerator`，因此 `f-xml-char-layer` 的「文本累积 SHALL 使用
  `StringGenerator`」**未偏离**（`verification.md` §7 已登记）。

## 6. 文本与属性值批量扫描

### 6.1 `LineWindow` 的 internal 块视图

公开签名一个不动，只加三个 `internal` 成员 + 一张边界掩码：

```cangjie
// 触发一次 ensure(1) 后返回「当前块内可直接消费的码点数」；EOF 时返回 0。
// 语义与 peekFast(0) 对齐：不足且存在 pendingError 时抛错（不返回 0 伪装 EOF）。
internal func runAvailable(): Int64

// 相对 pos 的码点，调用方保证 i < runAvailable()。不 ensure、不改状态。
internal func cpAt(i: Int64): Int64

// 等价于连续调用 n 次 advanceFast（行列号推进规则逐字一致）。
internal func skipRun(n: Int64): Unit

// 从 pos 起、连续满足「码点 < 0x80 且 mask[cp] == false」的码点数。
// 不 ensure：调用方先 runAvailable() 取快照，保证期间不触发压缩/重填。
internal func asciiRunLength(mask: Array<Bool>): Int64
```

**失效规则（必须写进实现注释）**：`ensure` 会把未消费的尾部搬到数组头部并把 `pos` 归零，
所以 `cpAt` / `asciiRunLength` 的下标只在「上一次 `ensure`（即 `runAvailable`）之后、
下一次 `runAvailable` 之前」有效。因此批量路径的顺序固定为
**`runAvailable` → `asciiRunLength`/`cpAt` 拷贝 → `skipRun`**，绝不跨 `runAvailable` 持有下标。

`skipRun` 的行列号推进等价于逐字符：

```cangjie
internal func skipRun(n: Int64): Unit {
    var i = 0
    while (i < n) {
        if (Int64(this.block[this.pos + i]) == 0x0A) { this.line++; this.column = 1 }
        else { this.column++ }
        i++
    }
    this.pos += n
}
```

（块内不含 `\n` 时可以走「`column += n`」的快分支；两种写法结果一致，由用例对拍。）

### 6.2 文本扫描

```cangjie
// Lexer 里的静态边界掩码（128 项）：文本的停止字符 + 非法控制字符
private static let kTextMask = asciiMaskFor([0x3C, 0x26, 0x5D], invalid: true)
```

流程（`nextContentToken` 的主体）：

```
loop:
  avail = window.runAvailable()            // 0 = EOF 或已在错误点抛错
  if avail == 0: break
  n = window.asciiRunLength(kTextMask)     // 纯 ASCII、无停止字符、无非法字符
  if n > 0:
      for j in 0..n: textScratch.append(Rune(window.cpAt(j)))
      window.skipRun(n)
      continue
  // 落到逐字符路径：停止字符 / 非 ASCII / 控制字符 / 块边界
  cp = peekCp(0)
  ... 与现状逐行相同（`]]>` 检查、`&` 引用、isXmlChar 报错、append、advance）
```

- 停止字符里含 `]`：`]]>` 需要 2 字符前瞻，交给逐字符路径，代价只是「含 `]` 的文本变慢」。
- `avail == 0` 且并非 EOF 的情况不会出现：`runAvailable()` 在拿到 0 时要么是 EOF，
  要么已经抛了 `pendingError`。
- 事件边界不变：批量路径只是把同一段文本更快地喂给同一个 `gen`，
  `if (gen.size == 0) return TEof` 与 `Token.TText` 的产出点不动。

### 6.3 属性值扫描

掩码 = 当前引号（`0x22` 或 `0x27`）、`0x26`、`0x3C`、`0x0A`、`0x09`、`0x0D` + 非法控制字符。
因为引号有两种，运行时按 `quoteCp` 选两张预置掩码之一（`kAttrMaskDouble` / `kAttrMaskSingle`）。

- 命中停止字符时仍走**原逐字符分支**——`&#10;` 保持换行、字面换行变空格的差异
  完全由原分支保证，批量路径**只处理「原样拷贝」的字符**。
- 非 ASCII 直接退回逐字符（当前实现也是 `gen.append(Rune(cp))`，行为相同）。

### 6.4 ASCII 合法性查表

`XmlChars` 新增 `internal func isAsciiXmlChar(cp: Int64): Bool` 与
`internal func asciiMaskFor(stops: Array<Int64>, invalid!: Bool): Array<Bool>`；
`Char` 范围按 XML 1.0 §2.2：`0x09` / `0x0A` / `0x0D` / `0x20..0x7F` 合法。
`Rune` 版本与 `Int64` 版本都保留，非 ASCII 仍走原 `isXmlChar`。

## 7. 事件侧临时容器复用

| 位置 | 现状 | 改法 | 安全性依据 |
|---|---|---|---|
| `Lexer.readStartTag` | 每标签 `ArrayList<RawAttribute>()` | 复用 `attrsScratch`，入口 `clear()` | `TStartTag` 在同一 `step()` 内被 `openElement` 消费完毕，之后才可能取下一个 token |
| `ParserEngine.openElement` 的 `resolved` | 每元素 `ArrayList<XmlAttribute>()` + `toArray()` | 先数非 `xmlns` 属性个数，`Array<XmlAttribute>(n)` 一次分配按索引填 | 数组是事件独占，交付后不再触达 |
| `ParserEngine.openElement` 的 `seen` | 每元素 `ArrayList<QName>()` | 复用 `seenScratch`，入口 `clear()` | 只在本次重复检测内使用 |
| `ParserEngine.pending` | 已是字段 | 不动（最多 2 个元素） | — |

`openElement` 改成两遍后，**校验顺序必须与现状一致**（命名空间声明登记 → 元素名解析 →
逐属性「重复 → 长度上限」），否则同一份坏文档可能换一条错误消息。用例覆盖：
`<a x="1" x="2">`（重复）、`<a x="超长值">`（长度）两条断言消息与行列号不变。

## 8. 未达标时的阶梯（全部在代码侧）

### 8.1 时间（Gate T）

按 `SemanticPerf_test` 的分段占比从大到小下手，**不跳级**：

| 级 | 动作 | 预期 | 风险 |
|---|---|---|---|
| B0 | §3 基准修正 + §4 驻留 + §5 复用 + §6 批量 + §7 容器复用（本变更主体） | 0.38–0.55 s 的构造开销 + 0.16–0.26 s GC 大部分消失 | 低 |
| B1 | `skipRun` 的行列号走「无 `\n` 则 `column += n`」快分支；`asciiRunLength` 用 `Int32` 视图减少转换 | −3–8% | 低 |
| B2 | 文本 / 属性值的 `toString()` 改 `String.fromUtf8Unchecked(scratch 的字节区间)`，省一次 `ArrayList` 拷贝 | −5–10% | 需偏离 `f-xml-char-layer` 的「用 `StringGenerator`」要求 → **需用户批准**并登记 |
| B3 | 去 `Token` 间接层（`Lexer` 直接回调 `ParserEngine`） | 未测，可能 −5% | 内部重构面大，需重跑全部等价性用例 |
| B4 | 驻留属性值（如 `v`、`id` 这类高频值） | 未测 | **改变 `String` 实例身份**，语义风险，默认不做 |

### 8.2 内存（Gate M）

| 级 | 动作 | 说明 |
|---|---|---|
| M0 | §3.1 基准零分配 | 50 MB 上 125 万次 `recordText` + `Array` 消失，这是最大单一来源 |
| M1 | §3.2 分进程测量 | 10 MB 的峰值不再垫高 50 MB 的读数 |
| M2 | §4 名字驻留 | 102 万存活 `String` → 个位数；GC 不必为它们扩容/搬运 |
| M3 | §5 / §7 容器复用 | 减少 `ArrayList` 的增长峰值（每个 `ArrayList<Byte>` 扩容到 8 KB 量级 × 数十万次） |
| M4 | 若仍 ≥ 256 MB | **停下**：记录 50 MB 的 `VmHWM` 曲线（每 5 MB 采一次，用现有 `readProcMem`），把「是否有线性保留」写进 `verification.md`，回到用户处重裁 Gate（候选：改为「不高于改前」的相对门禁）。**不加环境变量、不改默认堆参数** |

M4 的判定材料必须包含「进程地板」：解析 `<?xml version="1.0"?><a/>` 的一份极小文档后的
`VmHWM`，用来区分「运行时底座」与「本题分配」。

## 9. 文件级改动清单

| 文件 | 改动 |
|---|---|
| `src/NameTable.cj` | 新增：开放寻址驻留表、FNV-1a、逐字节比对、上限、计数 |
| `src/Lexer.cj` | `readName` 增量 hash + 驻留；三条复用 scratch；`attrsScratch`；文本 / 属性值批量路径；边界掩码 |
| `src/LineWindow.cj` | 新增 4 个 `internal` 成员（`runAvailable` / `cpAt` / `skipRun` / `asciiRunLength`） |
| `src/XmlChars.cj` | `isAsciiXmlChar`、`asciiMaskFor`、`Int32` 视图重载 |
| `src/ParserEngine.cj` | `resolved` 精确数组 + `seenScratch` 复用；校验顺序不变 |
| `src/Perf_test.cj` | 合成流零分配 + golden 断言；Gate 拆到两个新类 |
| `src/PerfTen_test.cj` | 新增：10 MB × 5，环境三件套，`min < 1000 ms` |
| `src/PerfFifty_test.cj` | 新增：50 MB × 1，`VmHWM < 262 144 kB`，进程地板 |
| `src/NameTable_test.cj` | 新增：命中 / 未命中 / 同 hash 反例 / 非 ASCII / 上限 / 计数 |
| `src/TextScan_test.cj` | 新增：批量与逐字符等价性、跨块、报错位置、属性值归一 |
| `src/BufferReuse_test.cj` | 新增：复用不串内容、跨事件无别名 |
| `src/SemanticPerf_test.cj` | 新增：分段计时与分配计数（诊断用） |
| `doc/spec/optimize-f-xml-semantic-layer/**` | 本组产物 + 实施后 `verification.md` |
| `f_xml/README.md` / `README_en.md` | 状态段：达成值、用例数、指向本变更 |
| `doc/f_xml模块设计.md` | §15.1 性能现状改为达成值；补「语义层」小节指向本变更 |

## 10. 决策记录

| # | 决策 | 理由 |
|---|---|---|
| D1 | 名字驻留按「hash + 长度 + 逐字节（等价逐 rune）比对」判定 | 只比 hash 会产生**静默错误的名字**，是本变更唯一不可接受失效模式；逐字节比对是最便宜的全量比对 |
| D2 | 驻留表同时存已切分的 `prefix` / `local` | 命中路径连 `substring` 都省掉；带前缀名字每记录省 2 个 `String` |
| D3 | 驻留表开放寻址 + 负载因子 0.5 + 条目上限硬停插 | 查找 O(1) 无对象分配；上限保证内存不随文档增长，超限只降级为「不驻留」 |
| D4 | 用 FNV-1a 而不是 `HashBuilder` | `HashBuilder` 是可变对象（每次要 new）+ 每次 `append` 走泛型；热路径要的是「两个 `Int64` 运算」 |
| D5 | 一次扫描 + 复用 scratch，不做「二次前瞻」 | `peekFast` 只保证 `offset ≤ 8`，长名字无法先探后取；一次扫描是唯一可行解 |
| D6 | 复用 `StringGenerator` 而不是换 `StringBuilder` | 字符层 spec 已定「用 `StringGenerator`」；复用实例不改 API、不改契约 |
| D7 | 批量扫描只处理「原样拷贝」的 ASCII 段，其余退回逐字符 | 归一、引用、`]]>`、非法字符四条规则都已正确实现，重复实现一份是 bug 源；批量路径只做「快的那部分」 |
| D8 | `LineWindow` 的块视图用 `internal` 而非新公开接口 | 公开声明 diff 必须为空；`public class` 实现 `internal interface` 会有可见性纠缠 |
| D9 | 边界掩码由 `Lexer` 构造、`LineWindow` 只按掩码消费 | `LineWindow` 保持「与 XML 无关」的分层；掩码是纯数据 |
| D10 | 基准先改、新旧代码共用同一份 | 旧基准每记录分配 `String`，会把「基准成本」误记成「解析器成本」；不改基准，对照没有意义 |
| D11 | 10 MB / 50 MB 拆两个进程 | `VmHWM` 单调；同进程 10 MB 会垫高 50 MB 读数，等于自欺 |
| D12 | `max/min > 1.4` 判为污染轮次，重测 | 本机实测波动可达 1.4 倍；污染轮次上判正会误报达标，判负会误杀 |
| D13 | 禁用一切 GC 环境变量 | `cjGCInterval=100ms` 能把 `VmHWM` 压到 165 MB 但**不提速**，且 OpenHarmony 不生效；靠它达标等于把库的保证换成机器的参数 |
| D14 | 驻留 `QName` 不做 | `QName` 是 `struct` 不分配；`uri` 由作用域决定，驻留会引入作用域失效风险，收益只有一个结构体拷贝 |
| D15 | 属性值 / 文本的 `String` 不驻留 | 事件载荷语义上是「这一处的文本」；驻留会让不同事件共享实例（身份变化），收益与风险不成比例（列入 B4 / 不做） |
| D16 | 名字缓冲用自建 `ByteScratch`，文本 / 值仍用复用的 `StringGenerator` | `reset()` 实测保留容量（0.4），但 `StringGenerator.unsafeBytes()` 是按 `size` 截好的**新数组**，逐字节比对会每 token 分配；名字驻留需要零拷贝视图。`ByteScratch` 只用于名字，输出与 `StringGenerator` 逐字节一致，`f_base` 未改 |

## 11. 与上一轮产物的差异登记

| # | 原文 | 差异 | 处理 |
|---|---|---|---|
| 1 | `complete-f-xml-m1-followups/design.md` D13「绝对 10 MB < 1 s 移交 `optimize-f-xml-semantic-layer`」 | 本变更就是承接项 | 本文件 §1 明确 Gate T |
| 2 | 同上 Gate P-RSS「`VmHWM(50) ≤ 320 MB`」 | 本变更收紧到 256 MB | 上一轮阈值是 `-O2` 档位的校准值；256 MB 与默认 `cjHeapSize` 同量级，是本变更的真实目标 |
| 3 | 同一轮 `Perf_test` 的 `SyntheticXmlStream` 每记录 `recordText` | 本变更改为零分配 | 属于**测量方法**修正，不掩盖缺陷：§3.1 用 golden 断言证明字节流不变 |
| 4 | `char-layer` spec「文本累积 SHALL 使用 `StringGenerator`」 | 默认仍遵守；仅 §8 的 B2 级可能偏离 | B2 需用户批准；未启用则在 `verification.md` 登记「未启用」 |
| 5 | 上一轮 `README.md`「337 条」 | 本变更在此基础上新增约 22–28 条 | 实施后回填实际值 |
