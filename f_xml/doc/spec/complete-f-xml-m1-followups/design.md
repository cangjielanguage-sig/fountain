# Design — complete-f-xml-m1-followups

> 范围：只改 `f_xml/`。本文件描述**怎么做**；契约变化见 `specs/**/spec.md`，执行顺序见 `tasks.md`。
> 设计基线是 `implement-f-xml-m1` 的 `design.md`（尤其 §2、§6、§10.1、§13）；本文件只写增量，
> 不重复已有决策。所有「SHALL」与 `specs/**` 一一对应。

## 1. 目标、Gate 与不变量

### 1.1 Gate

| Gate | 标准 | 判定方式 |
|---|---|---|
| P（本变更出口） | 事件模式 10 MB `min(3 次) < 7200 ms`（相对本机基线 9649 ms 提升 ≥25%） | `Perf_test`，`F_XML_PERF=1` |
| P-RSS | `VmHWM(50 MB) − VmHWM(10 MB) ≤ 24 MB` 且 `VmHWM(50 MB) ≤ 256 MB` | 同上，读 `/proc/self/status` |
| A（沿用） | `pass + known == 2038`、`fail == 0`、`unsupported == 524` | `XmlconfHarness_test.fullSuite` |
| R（回归） | 现有 303 条 `@TestCase` 全过；`cjpm build` 的 WARNING 不新增 | `cjpm test` |

P 未达标**不允许**自行放宽阈值；按 §13 的阶梯继续做，或回到用户处重新裁定 Gate。
**2026-10-29 用户裁定**：本机语义层 ~4–5.6 s，绝对 10 MB < 1 s 不可达；本变更改用相对 Gate
（< 7200 ms，≥25%），绝对目标移交 `optimize-f-xml-semantic-layer`。

### 1.2 不变量（改写过程中任何一条被破坏都算回退）

1. 公开类型、方法签名、参数名、默认值零变更；新增 seam 全部 `internal`。
2. 事件序列（类型、顺序、文本内容）逐字节不变；推模式与拉模式仍逐行一致。
3. 错误消息文本、`line` / `column`、`entityLimitKind` 不变。
4. `InvalidByteMode.Strict` / `Replace` 两条 UTF-8 路径的逐字符输出不变，且互不替代。
5. `\r\n`、孤立 `\r` 只归一一次；空行与 EOF 仍可区分。
6. 事件模式内存 O(嵌套深度)，不因文档变大而线性增长。
7. 五条 xmlconf 排除规则与 2062 / 524 / 2038 三个数字不变。
8. `bufSize` 的**行为**不变（只影响块大小，不影响结果）；默认值仍 8192。

## 2. 基线

见 `baseline.md`。摘要：事件模式 1 MB ≈ 1.5 s、10 MB ≈ 15.8 s；303 条用例；Gate A
`pass=2038 fail=0 unsupported=524 known=0`。M1 已做过 `peekFast` / `advanceFast` 并去掉
两层 `ArrayList`，收益约 15%，量级不变——所以本变更必须换结构，不是再挤常数。

## 3. 字符层：块解码 + 单活动缓冲

### 3.1 现状成本模型

一次 `advanceCp()` 现在的调用链：

```
Lexer.advanceCp
  → LineWindow.advanceFast          (Rune 取出 + 比较 + 行列号)
      → BufferedRuneSource.advanceFast   (Rune 取出 + 比较 + 行列号)
          → Utf8RuneSource.pull          (每字符一次)
              → ByteDecoder.next         (match codec + ensure + peek + consume)
                  → ByteReader.ensure    (至少一次 "available < count" 判断)
```

三处叠加：**每字符一次虚调用链**、**每字符一次 `ByteDecoder.next` 的 codec 分支**、
**两层 `Array<Rune>` 环形缓冲的无谓搬运**。`Rune` 与 `Option` 只是表象；即使把
`Option` 全去掉（M1 已做），上面三条仍在，所以只有 15%。

### 3.2 块解码

`BufferedRuneSource` 改为「按块产出码点」：

```cangjie
// 一次块填充的结果：count 个有效码点；error 非 None 表示「这 count 个之后就是坏字节」
internal struct BlockFill {
    let count: Int64
    let error: ?Exception
}

public abstract class BufferedRuneSource <: RuneSource {
    // 公开 / 受保护契约保持不变：pull() 与 pulledRune 仍然存在
    protected func pull(): Bool
    protected var pulledRune: Rune

    // 新增（可覆写）：把至多 capacity 个码点写进 dest[start..]
    // 默认实现循环调用 pull()，因此第三方子类无需改动即可继续工作
    internal func decodeInto(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill

    // ownBlock 只在「直接调用 RuneSource 方法」时惰性分配
    private var ownBlock: ?Array<Int32> = None
    private var ownPos: Int64 = 0
    private var ownLen: Int64 = 0

    // 解码游标（与消费游标分离）：算坏字节自身的行列号
    private var decLine: Int64 = 1
    private var decColumn: Int64 = 1
}
```

- `decodeInto` 的**默认实现**：循环 `pull()` 把 `pulledRune` 写进目标数组；`pull()` 抛出的
  任何 `Exception` 都被装进 `BlockFill(…, Some(e))`，不在此刻向 `LineWindow` 抛出。
  `Utf8RuneSource` 与 `BlockRuneSource` 覆写它走批量路径；`CharsetRuneSource` **用默认实现**
  （仍然逐字符 `read()`，但只发生在填充）。`decodeInto` 是 `internal`，外部子类（只实现
  `pull()`）走默认实现，行为正确但不变快；公开/受保护契约不新增。
- `peekFast(offset)` / `advanceFast()` 只做「块内下标 + 边界判断」，不再回调解码器。
- `peek` / `advance` 保留为 `Option` 包装（公开契约不变），内部转调 fast 版本。
- 块容量 `blockCapacity = max(64, min(bufSize, 1 << 20))` 个码点（`Array<Int32>`，
  即 ≤ 4 MiB；默认 8192 → 32 KiB）。`bufSize` 仍是**字节块**大小，语义不反转：
  UTF-8 每码点至少 1 字节，所以一个字节块的码点数 ≤ `bufSize`；`max(64, …)` 只为
  满足 `peek(≤ 4)` 与 `bufSize = 4/8/16` 的既有测试。
- **零冗余块**：`ownBlock` 惰性分配。`LineWindow` 驱动的路径走 §3.3 的 seam，直接写进
  `LineWindow` 自己的数组，此时 `ownBlock` 始终是 `None`。

UTF-8 块解码（`ByteDecoder`）：

```cangjie
// 返回写入 dest 的码点数；0 = EOF。strict 分支沿用现有错误语义与字节偏移。
func decodeBlock(dest: Array<Int32>, start: Int64, capacity: Int64): Int64 {
    var i = start
    let end = start + capacity
    while (i < end) {
        if (!this.reader.ensure(1)) { break }
        // 连续 ASCII 段：一次性搬运，逐个 ensure/分支都省掉
        let n = this.reader.copyAsciiRun(dest, i, end - i)
        if (n > 0) { i += n; continue }
        let cp = this.next()          // 多字节走既有单字符路径（含块尾回退）
        if (cp < 0) { break }
        dest[i] = Int32(cp)
        i++
    }
    i - start
}
```

`ByteReader.copyAsciiRun(dest, dstStart, limit): Int64` 在 `ByteReader` 内部实现
（`pos` / `len` 是私有字段，只能在这里做）：`while (pos < len && limit > 0 &&
buf[pos] < 0x80) { dest[dstStart++] = Int32(buf[pos]); pos++; consumed++; limit-- }`。
不调用 `consume()` 的通用路径，避免每字节一次函数调用。

UTF-16 / UTF-32 的 `decodeBlock` 仍是「循环调 `next()`」，但**只发生在块填充**，
Lexer 热路径看不到；`Option` 与 `Rune` 都已消失。GBK 见 §3.8。

### 3.3 三层缓冲合并

块读入口是 `BufferedRuneSource` 上的**内部方法**（不引入公开接口，避免 `public class`
实现 `internal interface` 的可见性纠缠）：

```cangjie
// BufferedRuneSource 内部成员；LineWindow 通过类型判定调用
func readCodePointBlock(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill
```

`LineWindow` 改为**唯一的活动缓冲**：

```
Lexer ──peekCp/advanceCp──> LineWindow（Array<Int32> 块，已归一化）
                                  │  refill
                                  └── BufferedRuneSource.readCodePointBlock（internal）
                                          └── ByteDecoder.decodeBlock（ASCII 批量）
```

- `LineWindow` 持有 `Array<Int32>`（容量同上），`pos` / `len`。
- `ensure(offset + 1)`：若 `pos + offset >= len`，先把尾部最多 8 个码点搬到数组头部，
  再向源要满剩余容量；`count = 0` 且无 `error` 即 EOF。因为 `peek` 只承诺 `offset ≤ 4`，
  留 8 个余量足够。`error` 非空时记下「已产出 `count` 个码点后是错误点」（§3.5）。
- `advanceFast()`：`cp = block[pos++]`，`0x0A` 时 `line++ / column = 1`，否则 `column++`；
  与现状逐字一致（归一发生在填充时，行列号推进仍发生在消费时）。
- **回退路径**：`source` 是 `BufferedRuneSource`（`match` 类型判定）时走批量；
  否则（用户自定义 `RuneSource`，或直接实现 `RuneSource` 的第三方类型）用
  `advanceFast()` 逐字符填块。语义相同，只是慢。用例必须覆盖这条回退路径
  （`CharLayerParity_test`）。

「三层合并」的准确含义：**活动路径上只有一个码点块**（`LineWindow` 的），
`BufferedRuneSource` 不再为它维护第二份环形缓冲；Lexer 也不再持有 `Array<Rune>` 缓冲，
只做 `Int64` 码点的游标运算。不是把 `LineWindow` 删掉——`LineWindow` 仍是公开类型，
也仍是归一的唯一场所。

### 3.4 `\r` / `\r\n` 跨块归一

归一在填充时原地做：

```cangjie
private var pendingSkipLf = false

// 填充循环内，对每个新码点 cp：
if (this.pendingSkipLf && cp == 0x0A) { this.pendingSkipLf = false; continue }  // 吃掉
this.pendingSkipLf = false
if (cp == 0x0D) { dest[i++] = 0x0A; this.pendingSkipLf = true } else { dest[i++] = cp }
```

- `\r` 在块尾：先产出 `\n`，置 `pendingSkipLf`；下一块首字符是 `\n` 就吞掉，否则正常产出。
- `\r` 在流尾：产出 `\n`，`pendingSkipLf` 留到下轮 EOF，无副作用。
- 连续 `\r\r\n`：第一个 `\r` → `\n` 并置位；第二个 `\r` 清位并再产出 `\n`；`\n` 不被吞。
  结果 `\n\n`，与现状一致（`LineWindow_test` 已有断言）。

**边界用例必须覆盖**：`bufSize = 4/8/16` 时把 `\r` 卡在块尾（构造 63 / 64 / 65 字符前缀）。

### 3.5 解码错误：延迟抛出，位置取坏字符自身

按块解码会**超前**读出解析器还没消费的字符，所以错误不能在填充时直接抛给调用方——
否则「坏字节之前的事件」会被提前吞掉，流式拉取的语义就变了。

规则：

1. 填充遇到坏字节时停止，返回 `BlockFill(count, Some(e))`。若 `e` 是 `XmlException`，
   其 `line` / `column` **由解码游标 `decLine` / `decColumn` 给出**（即坏字符自身的位置），
   `message` 仍带原有字节偏移；其他异常类型（如 charset4cj 自己的异常）原样保留并在消费点抛出，不包装、不改消息；
2. `LineWindow` / `BufferedRuneSource` 记住「已产出 `count` 个码点后是错误点」；
3. `peekFast` / `advanceFast` 请求到该位置时**才**抛 `e`；
   在此之前的事件照常送达；
4. `peekFast` 命中错误点也抛（与今天 `peek` 触发解码错误的行为一致），
   不返回 `-1` 伪装 EOF。

`decLine` / `decColumn` 与消费用的 `line` / `column` 是两个游标：前者在**填充**时按
已解码码点推进，后者在**消费**时推进。这样即使超前 8 K 个字符，错误位置也不会漂。

既有 `InvalidByteMode_test` / `ParserError_test` 的断言是硬约束。若某条断言实际依赖的是
旧实现「超前填充时的消费位置」，以规范语义（坏字节自身位置）为准，并在
`verification.md` 登记为**修正**，由用户确认后才改断言。

### 3.6 位置语义

- `LineWindow.position()` 仍返回「下一个待读字符」的 1-based 位置。
- 位置只在 `advanceFast()` 里推进；填充不推进。
- 错误定位仍由 `Lexer.error()` 取 `position()`；`XmlException` 的 `line` / `column`
  与 M1 完全一致（`ParserError_test` 的既有断言是硬约束）。
- 不新增「字节偏移」概念（`RuneSource` 仍不暴露）。
- `RuneSource.position()` 的权威语义只在其被**直接驱动**时成立（`peek` / `advance`）。
  被 `LineWindow` 经块 seam 驱动时，源侧没有「消费」动作，其 `position()` 不保证前进；
  解析器对外报告的位置一律取 `LineWindow.position()`。这是内部协作细节，公开方法签名不变。

### 3.7 可测性：块填充计数

`BufferedRuneSource` 增加两个内部只读计数（`internal`，不进公开 API）：

```cangjie
var blocksFilled: Int64 = 0      // BlockFill.count > 0 的次数
var codepointsYielded: Int64 = 0 // 累计码点数
```

用例断言 `blocksFilled <= codepointsYielded / 64 + 1`（1 MB 文档大约 1 万次块填充，
而不是 100 万次），把「确实按块解码」变成结构性断言。计数只在 `LineWindow` 走 seam
或直接调用 fast 方法时累加，不参与任何业务判断。

### 3.8 允许保留的 `Option`：`CharsetRuneSource`

`charset4cj.TextReader` 只提供 `read(): ?Rune`，没有批量码点 API。`CharsetRuneSource`
**不覆写** `decodeInto`，直接用 `BufferedRuneSource` 的默认实现（循环 `pull()`）：
在**块填充循环**里仍每字符一次 `Option`，但：

- 它不在 Lexer 热路径上（Lexer 只读 `LineWindow` 的 `Array<Int32>`）；
- 它只影响 GBK 等非 UTF-8 文档的填充吞吐，不影响正确性；
- 不用 `readln()` 绕过——那是 M1 已经否掉的方案（会吃掉行尾、破坏换行语义）。

这条例外写进 `f-xml-char-layer` 的 spec，不假装消除。

## 4. Lexer 热路径

### 4.1 输入帧接口扩展

`RuneFeed` 增加码点入口，实现三个帧：

| 帧 | 存储 | `peekCpFast` / `advanceCpFast` |
|---|---|---|
| `WindowFeed` | 无（转调 `LineWindow`） | 直接转调 `window.peekFast` / `advanceFast` |
| `StringFeed` | `Array<Int32>`（原 `Array<Rune>`） | 下标读写，`-1` = EOF |
| `SinkFeed` | `Array<Int32>`（原 `ArrayList<Rune>`） | 块内下标；不足时从 `ExpandReader.nextCp()` 补 |

`Lexer.peekCp` / `advanceCp` 在 `feeds.size == 1` 时仍直连 `LineWindow`；多帧时
从栈顶往下按码点找，`exhausted()` 为真则弹栈——与现状逻辑一一对应，只是不再经过
`?Rune`。

### 4.2 需要改写的调用点

以下位置现在用 `peek(0)` / `advance()` / `match (Some/None)`，全部改 `peekCp` / `advanceCp`：

- `nextMarkupToken`（含 `peek(0).isNone()` → `peekCp(0) < 0`）
- `readMarkup`、`readStartTag`、`readAttributeValue`、`readDeclarationValue`
- `skipWhitespace`、`trySkipWhitespace`
- `readReference`（`&#x` 数字循环、`&name;`）
- `readComment`、`readBang` 的 CDATA 分支、`readPiOrDeclaration`、`readDeclaration`、
  `readDoctype`、`readQuoted`、`readInternalSubset`
- `startsWith`、`consume`、`expect`

`XmlChars` 补 `Int64` 重载：`isWhitespace(cp: Int64)`、`isDigit(cp: Int64)`、
`isHexDigit(cp: Int64)`、`hexValue(cp: Int64)`。原 `Rune` 重载保留（写方向与 DTD 仍用）。

### 4.3 固定串匹配不再每次分配

`startsWith(text)` 现在每次 `runesOf(text)` 都新建 `ArrayList`，而 `startsWith("?>")`
在 PI / 声明 / 注释循环里是**每字符一次**。改为：

- 在 `Lexer` 里定义一组 `static let` 常量（`Array<Int64>`）：
  `kCommentOpen`("<!--")、`kCommentClose`("-->")、`kCdataOpen`("<![CDATA[")、
  `kCdataClose`("]]>")、`kPiClose`("?>")、`kDoctype`("DOCTYPE")、`kPublic`("PUBLIC")、
  `kSystem`("SYSTEM")、`kDoubleHyphen`("--")、`kConditionalOpen`("<![")、`kAmp`("&")。
- `startsWithCp(pattern: Array<Int64>): Bool`、`consumeCp(pattern)`、`expectCp(pattern)`。
- 全部调用点换成常量版本；`startsWith(String)` / `consume(String)` / `expect(String)`
  只保留给错误消息与极少数动态串（若最终无用可删，`internal` 不受 API 约束）。

这是纯内部改动，不影响任何输出。

### 4.4 文本与名字累积

`readName` / 文本 / 属性值仍用 `StringGenerator`，但热路径不构造 `String`：

- 继续 `gen.append(Rune(cp))`；`StringGenerator.append(Rune)` 已对 ASCII 走单字节
  `add`（`f_base` 的 `ORM-N1` 修复），不分配 `String`。
- `task 0.3` 先做一次微基准：断言 `Rune` 是值类型（`Rune(cp)` 不产生堆分配）。
  **若实测发现 `Rune` 是引用类型**，按 §13 阶梯 B 处理（在 `f_xml` 内维护
  `Array<Byte>` 的 UTF-8 累积器，结束时一次性 `String.fromUtf8Unchecked`）；
  该备选不改变任何公开签名。

  **实测结论（2026-10-29，task 0.3）**：`Rune` 构造成本与堆占用无关——
  1 亿次 `Rune(0x41).position()` 的 RSS 在 40 M 次后稳定在 37.8 MB，40 M → 100 M
  无增长；同规模纯 `Int64` 加法循环 918 ms、`Rune` 循环 1073 ms（+17%），
  差值来自函数调用而非分配。判定 `Rune` 为值类型，**§4.4 备选不启用**。
- `runesOf(value)` 在 DTD / 实体路径仍使用；本变更不动它（不在 Lexer 热路径）。

## 5. 实体帧与溢出读回

- `ExpandReader` 增加 `func nextCp(): Int64`（`-1` = EOF），`next(): ?Rune` 保留为包装。
- `MemoryExpandReader` 持有 `Array<Int32>`（内部 `cpsOf(text): Array<Int32>`，
  按 `text.runes()` 一次转换；转换只发生在实体替换文本进入帧时，不在逐字符路径）。
- `FileExpandReader.nextCp()` 直接返回 `ByteDecoder.next()`，不再包 `Option`。
- `SinkFeed` 的 `ArrayList<Rune>` 改为 `Array<Int32>` + 块填充（与 `LineWindow` 同款
  的 `pos` / `len` 模型），`fillTo(offset + 1)` 时按块补。
- 溢出文件**读回**仍是 UTF-8 固定块解码（`ByteCodec.Utf8Replace`），语义不变；
  只是多了一个不进 `Option` 的入口。

注意：`ExpandSink.write(segment)` 的计数语义（`runesOf(segment).size`）不动；
本变更不碰实体上限与溢出策略。若发现 `runesOf` 在 50 MB 纯文本（无实体）路径被调用，
说明走错了分支——纯文本不经过实体展开。

## 6. 性能基准与 Gate

### 6.1 合成输入（不写 50 MB 文件）

`src/Perf_test.cj` 内实现 `SyntheticXmlStream <: InputStream`：

- 模板固定：`<root>` + 重复的 `<item id="N" a="v">text-N</item>` + `</root>`；
  每条记录预先编码成 `Array<Byte>`（约 40 B），`read(buffer)` 按需复制并跨记录拼边界。
- 构造参数 `targetBytes: Int64`，精确产出 1 / 10 / 50 MB：先按「整条记录」凑到不超过目标值
  的最大条数，再补 `</root>`；实际字节数与目标值之差 < 单条记录长度（约 40 B），
  用例把实际值打印出来。截断**不落在**记录内部，保证文档始终良构。
- 好处：RSS 断言只反映解析器，不被 50 MB 输入数组污染；也顺带验证「流式读，不整份缓存」。

### 6.2 计时口径

- 预热：先解析一次 1 MB，丢弃结果。
- 计时：只包住 `XmlPullParser` 的 `while (nextEvent() != Eof)` 循环，事件回调为空操作
  （只累加计数），不含文档构造与断言。
- 重复 3 次（每次新建流与 parser），取 `min`，同时把 3 个值都打印出来。
- 输出统一格式（便于回填）：
  `perf: bytes=10485760 events=… ms=[…] min=… rss_kb=… hwm_kb=… buf=8192`。

### 6.3 RSS

- 读 `/proc/self/status`，解析 `VmRSS` / `VmHWM`（kB）。文件不存在时**记录
  `unavailable` 并跳过 RSS 断言**（非 Linux 平台可跑，但本机必须可用）。
- 顺序：1 MB（预热）→ 10 MB → 50 MB；每步记录 `VmHWM`。
- 断言（`F_XML_PERF=1` 时）：
  - `hwm50 - hwm10 <= 24 * 1024`
  - `hwm50 <= 256 * 1024`
- 若 `hwm50 - hwm10` 因 GC 抖动超限：先在同一进程内间隔 3 次重测取最小增量；
  仍超限则说明确实有线性保留，按缺陷处理，**不得**直接放宽阈值。阈值校准结果
  写回 §7.3。

### 6.4 默认关闭

- 10 MB / 50 MB / RSS 用例：仅当环境变量 `F_XML_PERF=1` 时执行；否则打印
  `perf: disabled (set F_XML_PERF=1)` 并直接返回。
- 1 MB 冒烟用例默认执行（目标 < 100 ms，即使慢机器也不会拖住 `cjpm test`）。
- CI / 本地验收命令：`F_XML_PERF=1 cjpm test --filter=Perf`。

## 7. 实测与回填

### 7.1 回填位置

| 数据 | 回填到 |
|---|---|
| 1 / 10 / 50 MB 耗时、事件数、`VmHWM` | 本文件 §7.3 |
| `bufSize` 4K/8K/16K/64K 曲线 | 本文件 §8.2 |
| 对外一句话结论（达成 / 未达成 + 数字） | `f_xml/README.md`「状态」段 |
| 设计文档现状表 | `f_xml/doc/f_xml模块设计.md` §15.1 |
| M1 的 R5 条目 | `implement-f-xml-m1/design.md` §10.1（把「未做」改成「已实测，见 complete-f-xml-m1-followups §8.2」） |
| 验收记录 | 本变更 `verification.md`（实施完成后新增） |

### 7.2 记录格式

```text
| 文档 | 事件数 | run1 | run2 | run3 | min | 吞吐 | 峰值 RSS |
```

### 7.3 实测记录（待实施回填）

| 文档 | 事件数 | run1 | run2 | run3 | min | 吞吐 | VmHWM |
|---|---|---|---|---|---|---|---|
| 1 MB | — | — | — | — | — | — | — |
| 10 MB | — | — | — | — | — | — | — |
| 50 MB | — | — | — | — | — | — | — |

改前基线（M1）：1 MB ≈ 1.5 s、10 MB ≈ 15.8 s（`verification.md` §4）。

## 8. R5：`bufSize` 实测

### 8.1 矩阵与口径

- 文档：1 MB、10 MB（合成流，同一模板）。
- `bufSize`：4096 / 8192 / 16384 / 65536。
- 每个组合 3 次取 `min`；只测事件模式；只改 `XmlParserOptions(bufSize: …)`。
- 目标是**曲线形状**（是否随块变大而收敛、拐点在哪），不是选一个「最快值」；
  默认值保持 8192，避免默认行为变化。

### 8.2 结果（待实施回填）

| bufSize | 1 MB min | 10 MB min | 备注 |
|---|---|---|---|
| 4096 | — | — | |
| 8192 | — | — | 默认 |
| 16384 | — | — | |
| 65536 | — | — | |

结论（待填）：若 64K 与 8K 差距 < 5%，说明瓶颈已不在块大小，默认维持 8192；
若存在稳定拐点（如 16K 快 15% 以上），只在文档里给建议值，不改默认。

## 9. P3-a：`SpillDir` 四级全失败

现状：`SpillDir.createFile(limits)` 内部算候选、内部 `try/catch continue`，四级失败分支
无法在不制造真实文件系统故障的情况下触发。

改法：把「尝试一个候选」与「遍历候选」拆开，保持公开行为不变：

```cangjie
internal class SpillDir {
    static func candidates(limits: EntityLimits): ArrayList<Path>          // 不变
    static func fallbackDirectory(): Path                                  // 不变

    // 新增：可注入候选与回落点；逻辑与原 createFile 循环逐行等价
    static func createFileFrom(candidates: ArrayList<Path>, fallback: Path): File

    static func createFile(limits: EntityLimits): File {                   // 变成薄包装
        createFileFrom(candidates(limits), fallbackDirectory())
    }
}
```

`createFileFrom` 的规则：

1. 依次尝试候选；
2. 候选不存在时：只有 `candidate == fallback` 才 `Directory.create(recursive: true)`，
   其余直接跳过（与原实现一致）；
3. `File.createTemp(candidate)` 抛任何异常都 `continue`；
4. 全部失败 → `throw XmlException("无法创建实体溢出文件，请显式指定 spillDir")`；
5. **不降级回内存**（调用方 `ExpandSink.spill()` 收到异常后原样上抛）。

用例（`src/SpillDirFallback_test.cj`）：

| 用例 | 构造 | 断言 |
|---|---|---|
| 四级全失败 | 4 个「已存在的普通文件」路径（含 fallback） | 抛 `XmlException`；消息含 `spillDir`；`ExpandSink.isSpilled() == false` |
| 非回落候选缺失被跳过 | `[缺失目录, 有效临时目录]` | 成功，文件落在第二个 |
| 回落目录缺失被创建 | `[缺失目录(非回落), 缺失 fallback]` | fallback 被创建，文件可用，用后清理 |
| 成功路径回归 | `[有效目录]` | 与原 `Spill_test` 行为一致 |

「已存在的普通文件」用 `File.createTemp(dir)` + `close()` 得到，四个互不相同；
这样第四个（fallback）也必然失败，且不依赖 `chmod` / 环境变量，能稳定复现。

## 10. P3-b：两个解析器的实体计数独立

计数器是 `EntityCounter` 实例字段，由 `ParserEngine` 持有；本变更不加锁、不改结构，
只补证据。两条用例：

1. **交错驱动（确定性，主用例）**：两个 `XmlPullParser`（各自 `<!ENTITY e "…">`）交替
   `nextEvent()`。在任意一步断言 `p1.totalExpanded()` 只随 p1 的推进变化、p2 推进不改变
   p1 的值，反之亦然。
2. **双线程（`spawn`，复用仓库既有用法）**：两个线程各解析一份展开量 = 0.8 ×
   `maxExpandedTotal` 的文档；**若计数器是全局的，第二个必超限**。断言两份都成功，
   且各自 `totalExpanded()` 落在自己的预期区间。

`XmlPullParser` 实例不共享可变状态；用例在 `src/EntityCounterIsolation_test.cj`，
同包可见 `totalExpanded()`（`internal`）。

## 11. P3-c：`xmlconf_gen.py` 的 SHA-256 分支

现状：`download()` 与 `main()` 各写一遍校验（`sys.exit(2)` / `return 2`），无法在
不联网的情况下验证。

改法：

```python
def ensure_sha256(path: str, expected: str = SUITE_SHA256) -> int:
    """返回 0 = 通过，2 = 不匹配（并打印期望 / 实际值）。不退出进程。"""
```

- `download()` / `main()` 都改为 `if ensure_sha256(archive): sys.exit(2) / return 2`。
- 行为不变：不匹配时**不**解压、**不**生成 `cases.json` / `unsupported.json`。
- 新增 `f_xml/tools/test_xmlconf_gen.py`（`unittest`，不依赖 pytest）：

| 用例 | 做法 | 断言 |
|---|---|---|
| 函数级不匹配 | 临时文件写入 `b"not the suite"`，`expected="0"*64` | 返回 2；stderr 含两个 64 位串 |
| 函数级匹配 | 临时文件写入已知字节，`expected=sha256_of(path)` | 返回 0 |
| 端到端 | `F_XML_XMLCONF_CACHE=<tmp>` + 伪造 `download/xmlts20130923.tar.gz`，跑 `python3 xmlconf_gen.py --offline` | 退出码 2；stderr 含 `SHA-256 不匹配`；`cases.json` / `unsupported.json` 均不存在；未调用解压（`suite/` 不存在） |

运行方式：`python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v`；
在 `tasks.md` 9.3 里固定为验收命令。

## 12. 回归护栏

1. **公开声明清单**：改动前用 `grep -rn '^public ' f_xml/src` 存一份到 `/tmp`，
   改动后 diff 为空（新增的 `internal` 不计）。这一步写进 `tasks.md` 10.4。
2. **块大小等价性**：`CharLayerParity_test` 对同一组文档（UTF-8 strict / replace、
   GBK、UTF-16LE、UTF-16BE、UTF-32LE）在 `bufSize ∈ {4, 8, 16, 64, 8192, 65536}` 下
   比较：事件日志、文本、`position()` 序列、错误消息与行列号全部一致。
3. **CRLF 边界**：构造前缀长度 62..66 的 `\r\n` 文档，`bufSize = 4/8/16/64`，
   断言换行只归一一次、行列号正确。
4. **Gate A**：完整跑 xmlconf（缓存需存在），断言 2038 / 524 / 0。
5. **既有 303 条**：一条不删、一条不改期望；新增用例只加不改。
6. **构建告警**：`cjpm build` 不新增 WARNING（现有 20 条记录在 `doc/build-warnings.md`）。

## 13. 风险与备选阶梯

| 风险 | 触发信号 | 处置 |
|---|---|---|
| 块解码后 10 MB 仍 ≥ 1 s | Gate 实测 | 阶梯 B：先量「块解码 / Lexer 扫描 / 文本累积」三段占比，按占比最大者继续：①文本累积改 UTF-8 字节累积器（`Array<Byte>` + 结束时 `String.fromUtf8Unchecked`，不碰 `f_base`）；②`startsWith` 常量版本；③`readName` 的 colon 判定前置。**不放宽 Gate** |
| `Rune` 是引用类型，`append(Rune(cp))` 每字符分配 | 微基准（task 0.3） | 已排除：0.3 实测 RSS 不随迭代增长，判定为值类型；备选①不启用 |
| `VmHWM` 抖动导致 RSS 误判 | 3 次最小增量仍超限或波动 > 50% | 先查是否有线性保留（`blocksFilled` 与文档大小无关）；确认无保留后校准阈值并把校准方法写进 §6.3 |
| `\r` 跨块处理错位 | `CharLayerParity_test` 的 62..66 前缀用例失败 | 回归 `pendingSkipLf` 状态机；禁止把归一挪回 `advanceFast`（会造成两次归一） |
| 块填充改变错误定位 | `ParserError_test` 失败 | 位置只由 `advanceFast` 推进；填充阶段不得触碰 `line` / `column` |
| 自定义 `RuneSource` 回退路径变慢 | 第三方实现 | 回退路径只保证语义；文档注明「想要快就继承 `BufferedRuneSource` 并覆写 `decodeInto`」（受保护方法，不在公开文档里承诺） |
| 50 MB 合成流本身有 bug | 计数与字节数不符 | 用例先断言 `SyntheticXmlStream` 的产出字节数 == 目标 ±64，再解析 |

## 14. 文件级改动清单

| 文件 | 改动 |
|---|---|
| `src/RuneSource.cj` | `BufferedRuneSource` 块化（`decodeInto` / `ownBlock` / 计数）；`ByteDecoder.decodeBlock`；`ByteReader.copyAsciiRun`；`Utf8` / `Block` 子类适配；`CharsetRuneSource` 块填充 |
| `src/LineWindow.cj` | 单活动 `Array<Int32>` 块 + 内部块读入口 + `pendingSkipLf` + 回退路径 |
| `src/Lexer.cj` | 热路径全部 `peekCp/advanceCp`；固定串常量；`RuneFeed` 码点入口；`StringFeed` 改 `Array<Int32>` |
| `src/XmlChars.cj` | `Int64` 判定重载 |
| `src/ExpandSink.cj` | `SpillDir.createFileFrom` seam；`ExpandReader.nextCp`；`SinkFeed` 块化 |
| `src/EntityExpander.cj` | 适配 `nextCp` / `Array<Int32>`；不动上限逻辑 |
| `src/ParserEngine.cj` | 仅在 `pushFeed` / 事件源构造处适配（预期改动很小） |
| `src/Perf_test.cj` | 新增：`SyntheticXmlStream` + 1/10/50 MB + RSS + 输出格式 |
| `src/CharLayerParity_test.cj` | 新增：块大小 / 编码 / CRLF 边界等价性 |
| `src/SpillDirFallback_test.cj` | 新增：四级失败与回落创建 |
| `src/EntityCounterIsolation_test.cj` | 新增：交错 + 双线程 |
| `tools/xmlconf_gen.py` | 抽 `ensure_sha256` |
| `tools/test_xmlconf_gen.py` | 新增：3 条 Python 用例 |
| `doc/spec/complete-f-xml-m1-followups/**` | 本组产物 + 实施后 `verification.md` |
| `doc/f_xml模块设计.md` | §15.1 性能现状改写为达成值 |
| `README.md` | 状态段：性能数字、用例数校正、指向本变更 |
| `doc/spec/implement-f-xml-m1/design.md` | §10.1 R5 改为「已实测」并指向本变更 §8.2（只改这一行） |

## 15. 决策记录

| # | 决策 | 理由 |
|---|---|---|
| D1 | 码点块用 `Array<Int32>`，`-1` 表 EOF | 4 字节/码点，缓存友好；`Int64` 数组容量翻倍；公开 API 仍用 `Int64` |
| D2 | 块容量 = `max(64, min(bufSize, 1<<20))` 码点 | `bufSize` 是字节块，码点数不会超过它；下限 64 保证 `offset ≤ 4` 与 `bufSize = 4` 的测试；上限 1M 防极端配置 |
| D3 | `BufferedRuneSource.ownBlock` 惰性分配 | `LineWindow` 驱动时用调用方的数组，避免第二份块 |
| D4 | 归一只在填充时做，位置只在消费时推进 | 保持 `\r\n` 只归一一次，且错误行列号不变 |
| D5 | 默认 `bufSize` 保持 8192 | R5 只给建议；改默认是行为面变化，收益未证明 |
| D6 | 基准默认关闭，`F_XML_PERF=1` 开启 | 50 MB 用例不适合每次 `cjpm test`；Gate 仍可复现 |
| D7 | RSS 用 `VmHWM` 差值，不用绝对值为主 | 绝对值依赖运行时与分配器；差值能直接识别线性保留 |
| D8 | `SpillDir` 用内部 `createFileFrom` seam，不加公开配置 | 公开 API 冻结；seam 只服务测试 |
| D9 | 计数独立性用「交错 + 双线程」两条 | 交错能确定性地证明实例隔离；双线程复现 M1 spec 的原始场景 |
| D10 | `CharsetRuneSource` 的逐字符 `Option` 作为书面例外 | 不改第三方库的前提下无法消除；不在 Lexer 热路径上，不影响 Gate |
| D13 | Gate P 由绝对 1 s 改为相对 7.2 s（≥25%） | 2026-10-29 用户裁定：本机 10 MB 基线 9649 ms，语义层仍占 4–5.6 s，绝对 1 s 需另开语义层零分配变更；本变更不以放宽阈值收尾，而是明确分层 |
| D11 | `decodeInto` 用 `internal`，不用 `protected` | 公开声明 diff 必须为空；内部子类覆写即可，外部子类走 `pull()` 慢路径 |
| D12 | 块解码延迟**所有** `Exception`，不只 `XmlException` | 超前读下若提前抛 charset4cj 异常，会改变事件送达顺序；延迟到消费点才能保持流式语义 |

## 16. 与设计文档 / M1 产物的差异登记

| # | 原文 | 差异 | 处理 |
|---|---|---|---|
| 1 | M1 `design.md` §13「词法器改为按块扫描 + 只在出错时回退定位」 | 本变更不需要「回退定位」：位置仍按消费推进，填充阶段不消费 | 采用更简单的方案；记在此处，不改 M1 原文 |
| 2 | M1 `design.md` §13「必要时合并 `LineWindow` 与 `Lexer` 的前瞻层」 | 实际合并的是 `BufferedRuneSource` 与 `LineWindow` 的缓冲；`Lexer` 保留自己的输入栈（实体需要） | 同上 |
| 3 | M1 `specs/f-xml-char-layer`「实现可用固定 8 槽环形缓冲」 | 改为码点块（≥ 64），`peek ≤ 4` 的承诺不变 | 在 spec delta 的 MODIFIED 里写明 |
| 4 | M1 `specs/f-xml-conformance`「性能只记录、不作门禁」 | 本变更把性能变成 Gate P | 用 REMOVED（原 Requirement）+ ADDED（「性能门禁」）替换，M1 副本保持历史原文 |
| 5 | M1 `verification.md` §3 把三项 P3 归入「后续 `optimize-f-xml-char-layer` 或按需补测」 | 本变更改名为 `complete-f-xml-m1-followups` 并全部承接 | `tasks.md` 11.5 补指向说明 |
| 6 | M1 `README.md` 写「298 条单元测试」 | `verification.md` 是 303 条 | 本变更把 README 校正为实际数字 |
