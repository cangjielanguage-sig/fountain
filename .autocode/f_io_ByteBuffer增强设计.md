# f_io.ByteBuffer 增强设计 —— 类型化读写与字符编码

> ## 状态：**已决定「保持现状」，本设计不实施**
>
> 2026-10-24 决定：`f_io.ByteBuffer` 不做这批增强——不新增类型化读写、不新增字符串方法、不改可见性。
> 需要这些能力时，各模块在自己的层里实现，或直接用 `std.io.ByteBuffer`。
>
> **保留本文档的理由**（它不是废纸）：
> - **3.11 有 `std.io.ByteBuffer` 的实测数据**（position / bytes / 写追加），
>   这些事实与是否实施无关，长期有效，任何模块选缓冲区时都用得上
> - **字符集失败策略的论述已移交 `f_xml`**：`InvalidByteMode` / `InvalidCharMode` 见 f_xml 设计 2.7
> - **3.12 的长度前缀范式仍然适用**：用 `std.io.ByteBuffer` 时没有可定位的写游标，
>   需要回填就得换 `f_io.ByteBuffer` 或自己维护缓冲区

> 版本 **v0.3（归档）** ｜ 2026-10-24 ｜ 状态：**不实施**
>
> v0.1 → v0.2（十二项决策落定 + 两处实测修正）：
> - **修正**：`std.io.ByteBuffer` 的 `position` 是**读游标**，写后停在 0；`bytes()` 也是"未读部分"。
>   原 3.11 说的两个差异都不成立，真正的差异只有"写游标能否定位"（见 3.11）
> - 明确**不改**现有 `read`；只新增 `readString` 系列
> - `readRune` 增加 `InvalidByteMode.Replace`（U+FFFD），默认仍是 `Strict`
> - `readln` 严格解码、UTF-16/32 直接报错、不支持孤立 `\r`
> - 新增 3.12：长度前缀**不提供**，给出"占位 → 回填"范式与三条陷阱
> - charset4cj 跟随最新版，不锁死；`SyncByteBuffer` 同步补齐
>
> **定位：f_zip 的前置任务。** f_zip 解析 ZIP 头需要小端定长读写，解码文件名需要多字符集支持，
> 这两项都落在 `f_io.ByteBuffer` 上。f_excel 复用同一套能力。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 类型化读写 | 为 `f_io.ByteBuffer` 补齐 `ExtendByteBuffer` 全套（12 个读 + 12 个写） |
| Endian 参数 | **必填**，不设默认值（防止忘了传导致端序错） |
| 越界语义 | 返回 `None`，且**回滚读游标**（保证原子性） |
| 字符串写 | `write(s: String, charset!)`，依赖 `charset4cj` |
| 字符串读 | `readString(count)` 按**字符**；`readStringBytes(count)` 按**字节**（ZIP/XML 必需） |
| 坏字节策略 | `InvalidByteMode`：**有量契约的（字符数/行）默认 Strict，纯解码的（字节数/剩余）默认 Replace**（3.3） |
| 按字符读 | `readRune()` → `?Rune`，UTF-8 走长度快判；坏字节可选 `Replace` 产 U+FFFD（默认 Strict） |
| 按行读 | `readln()` → `?String`，支持 `\n` 与 `\r\n`；**仅限 ASCII 兼容字符集**，UTF-16/32 直接报错；严格解码，无宽容模式 |
| 按行写 | `writeln()` 固定写 `\n`（不跟随平台），换行符按 charset 编码 |
| 双类型覆盖 | 同一套文本能力**同时扩展 `std.io.ByteBuffer`**；实测读语义一致，**唯一差异是 std 不能回填**（3.11） |
| 字节解码 | `decode`（宽容）+ `decodeStrict`（严格）；ZIP 文件名回退链用后者 |
| BOM | charset4cj 尚未支持 BOM，需自行跳过 |
| 新依赖 | `charset4cj`，**跟随最新发布版**（写作时 1.0.6），不锁死 |
| 长度前缀 | **不提供方法**，给出"占位 → 回填"范式（3.12） |

---

## 1. 现状核查

### 1.1 f_io.ByteBuffer 现有能力

实读 `f_io/src/ByteBuffer.cj`：

```cangjie
public class ByteBuffer <: IOStream {
    public let toOverwriteOnClearing!: Bool
    public prop writeOffset: Int64
    public prop readOffset: Int64
    public prop capacity: Int64

    public func bytes(): Array<Byte>
    public func clear(): Unit
    public func clone(): ByteBuffer
    public func reserve(addition: Int64): Unit

    public func seekReading(pos: SeekPosition): Unit
    public func seekWriting(pos: SeekPosition): Unit

    public func readByte(): ?Byte
    public func read(buf: Array<Byte>): Int64
    public func writeByte(b: Byte): Unit
    public func write(buf: Array<Byte>): Unit
    public func flush(): Unit
}
```

对照 ZIP/XML 的需要，缺口很清楚：

| 需要 | 现状 |
|---|---|
| 读小端 UInt16/UInt32 | ❌ 只有 `readByte` / `read(Array<Byte>)` |
| 写小端 UInt16/UInt32 | ❌ 只有 `writeByte` / `write(Array<Byte>)` |
| 读写 String（带字符集） | ❌ 完全没有 |
| 随机访问 | ✅ `seekReading` / `seekWriting` |

### 1.2 ExtendByteBuffer 的绑定问题

`f_io` 里已有 `ExtendByteBuffer` 接口，提供完整的类型化读写。但它的 `extend` 目标不是 `f_io.ByteBuffer`：

```cangjie
// f_io/src/ExtendByteBuffer.cj 第 17~18 行
import std.io.ByteBuffer
...
// 第 54 行
extend ByteBuffer <: ExtendByteBuffer {
```

由于文件顶部 `import std.io.ByteBuffer`，这个 `extend` 绑定的是**标准库**的 ByteBuffer。而 `fountain::f_io.ByteBuffer` 是本包另一个类（`<: IOStream`），**没有被覆盖**。

**同包同名类型的歧义**是这里的根源：`f_io` 包自己声明了 `ByteBuffer`，同包文件里又 `import std.io.ByteBuffer`。建议把两个 `extend` 拆到不同文件，各自只 import 需要的那个，避免解析歧义。

### 1.3 顺带发现的一个隐患

现有 `extend` 里的读取实现大致是：

```cangjie
private func read<T>(len: Int64, endian: Endian): ?T where T <: ... {
    let bytes = Array<Byte>(len, repeat: 0)
    if (len == 0) {
        None
    } else {
        match (endian) {
            case Big => T.readBigEndian(bytes[0..len])
            ...
```

**如果 `read(bytes)` 实际只读到不足 `len` 个字节，剩余部分仍是初始化的 0，会被当成有效数据解码。**

后果：解析同一段数据时，"读越界"不会报错，而是返回一个看起来合法的值（比如 0x00000000 被当成签名不匹配，或者反过来把某个字段读成 0）。这类错误在 ZIP 解析里极难定位。

**必须校验实际读到的字节数**（见 2.3）。

---

## 2. 类型化大小端读写

### 2.1 接口清单

沿用 `ExtendByteBuffer` 已定义的 24 个方法，**不要另起炉灶**：

**读（返回 `?T`）**

| 方法 | 字节数 |
|---|---|
| `readBool(): ?Bool` | 1（0=false，非 0=true） |
| `readUInt8(): ?UInt8` | 1 |
| `readUInt16(): ?UInt16` | 2 |
| `readUInt32(): ?UInt32` | 4 |
| `readUInt64(): ?UInt64` | 8 |
| `readInt8(): ?Int8` | 1 |
| `readInt16(): ?Int16` | 2 |
| `readInt32(): ?Int32` | 4 |
| `readInt64(): ?Int64` | 8 |
| `readFloat16(): ?Float16` | 2 |
| `readFloat32(): ?Float32` | 4 |
| `readFloat64(): ?Float64` | 8 |

**写（返回 `Unit`）**：`writeBool` / `writeUInt8` … `writeFloat64`，一一对应。

**全部带 `endian: Endian` 参数**，`Endian` 来自 `std.binary`，取值 `Big` / `Little`。

### 2.2 Endian 必须显式传

**不建议给 `endian` 设默认值。**

理由：ZIP 全字段小端、网络协议全大端、部分二进制格式混用。一旦有了默认值，"忘了传"就会静默用错端序，而端序错误的表现是"字段值完全不合理但依然是个合法数字"，排查成本极高。

8 位类型（`UInt8` / `Int8` / `Bool`）的端序无意义，但仍保留参数以保持签名统一——**统一比省一个参数重要**，否则调用方要记住"哪几个不用传"。

### 2.3 越界语义：返回 None 且回滚游标

这是本节最重要的约定。

```
读 N 字节时若剩余不足 N：
  1. 返回 None
  2. readOffset 保持不变（回到调用前的位置）
  3. 不抛异常
```

**为什么必须回滚**：ZIP 解析是"seek 到某处 → 连续读一串字段"。假设读到第 5 个字段时越界，如果游标停在那里，后续所有 `seekReading` 的相对偏移都会错位，错误会在很远的地方才暴露。

实现要点：

```cangjie
let start = readOffset
let buf = Array<Byte>(len, repeat: 0)
let n = this.read(buf)
if (n < len) {
    seekReading(SeekPosition.Begin(start))   // 回滚
    return None
}
// 再按 endian 解码 buf
```

**`len == 0` 的处理**：现有实现返回 `None`。建议保持——零字节的整数没有意义，返回 `None` 比返回 `0` 更安全（避免调用方误以为读成功）。

### 2.4 实现方式

在 `f_io` 内新增一个文件，为本包的 ByteBuffer 补 extend：

```cangjie
// f_io/src/ByteBufferExt.cj —— 不 import std.io.ByteBuffer
package fountain::f_io

extend ByteBuffer <: ExtendByteBuffer {
    // 24 个方法的实现
}
```

同时保持 `ExtendByteBuffer.cj` 里的 `extend std.io.ByteBuffer` 不变。

**两个文件各自只 import 自己需要的类型**，靠文件隔离消除同名歧义。这比在同一个文件里用全限定名混写更清晰。

### 2.5 是否覆盖 SyncByteBuffer

`f_io` 还有 `SyncByteBuffer`（带 `batch(fn)` 和超时读写）。

**已定：同样补齐**，类型化读写与字符串读写都覆盖。否则调用方一旦为了线程安全换成 Sync 版，
就会失去这些能力，反而逼人不用安全版本——这类"安全版功能更少"的设计是反的。

**`batch(fn)` 与文本方法的关系（已定：不要求原子）**

`batch` 的实现是：

```cangjie
public func batch(fn: (ByteBuffer) -> Unit): Unit {
    synchronized(mutex){ fn(buffer) }
}
```

三点事实：

1. **互斥是成立的**——`SyncByteBuffer` 的其它方法都锁同一把 `mutex`，`fn` 执行期间别的线程进不来。
2. **但它不提供"原子"**：`fn` 中途抛异常，已经写入 / 消费的字节**不会回滚**。
   文本方法在 `fn` 里就是普通调用，出错时游标停在哪儿就是哪儿，不需要额外语义。
3. **`fn` 拿到的是内部 `ByteBuffer` 本身。** 把它存到外部变量、在 `batch` 之外再用，
   就完全绕过了锁——这是这套 API 唯一的真实风险，必须写进文档注释。

需要"要么全成、要么全不成"的调用方，可以在 `fn` 里先记下 `readOffset` / `writeOffset`，
`catch` 里再设回去（两者都是 `mut prop`）。注意这只回滚**逻辑游标**，已扩容的内存不会缩回——
不影响正确性，只是别指望内存也退回去。

实现上可以让 `SyncByteBuffer` 委托给内部 `ByteBuffer` 的同一套实现，避免逻辑重复。

---

## 3. 字符串读写

### 3.1 依赖 charset4cj

```toml
[dependencies]
charset4cj = "1.0.6"
```

已核实的信息：

- 仓库：`Cangjie-TPC/charset4cj`，最新标签 `v1.0.6`（还有 v1.0.5 / v1.0.4 / v1.0.0）
- 包路径：`charset4cj.charset.*`
- 获取字符集：`Charsets.UTF8` 常量，或 `Charsets.forName("UTF-8")`
- 编码：`charset.newEncoder().encode(str: String): Array<Byte>`
- 解码：`charset.newDecoder().decode(src: Array<Byte>): String`
- 另提供 `decode(src, dest): (Int64, Int64)` 的带目标缓冲区版本
- 已支持 GBK / GB18030 / BIG5 / EUC-KR / Shift_JIS / EUC-JP / 各种单字节字符集
- **BOM 支持标注为"待开发"**

**版本兼容要验证**：README 里提到适配过 `cjc 1.1.3`，我们用的是 1.3.0，接入前先跑一个最小用例确认能编译。

### 3.2 原始签名的问题

需求给的签名是：

```cangjie
public func write(s: String, chatset!: Charset = Charsets.UTF8): Unit
public func read(bytes: Array<Byte>, chatset!: Charset = Charsets.UTF8): Int64
```

`write` 没问题。`read` 有两个问题：

**问题 1：入参是 `Array<Byte>`，返回 `Int64`，产不出 `String`。**

`charset` 参数在这个签名里无处生效——既然是"读进一个字节数组"，那就不涉及解码；既然返回 `Int64`，就没法把解码结果交出去。

**问题 2：`chatset` 应为 `charset`。** 公共 API 里的拼写错误一旦发布就改不掉（或要留一个永久别名），建议现在就改。

> **这条不是要改现有的 `read`。** `IOStream.read(buffer: Array<Byte>): Int64` 是流契约，
> 保持原样、一个字都不动——它本来就该只搬字节。
>
> 这里说的只是：**如果**要加一个"读字符串"的方法，它不能复用 `read` 这个名字，
> 也不能沿用 `read(bytes, charset): Int64` 这个签名——入参是 `Array<Byte>`、返回 `Int64`，
> `charset` 参数没有任何作用点，产不出 `String`。
>
> 结论是**新增** `readString` 系列，`read` 不变。

### 3.3 建议的 API

按实际使用场景拆成三个方法，覆盖三种需求：

```cangjie
public class ByteBuffer <: IOStream {
    /// 把字符串按字符集编码后写入（不写长度前缀）
    public func write(s: String, charset!: Charset = Charsets.UTF8): Unit

    /// 读取 count 个【字符】并按字符集解码（坏字节默认抛异常）
    public func readString(count: Int64, charset!: Charset = Charsets.UTF8,
                           onInvalid!: InvalidByteMode = InvalidByteMode.Strict): String

    /// 读取 count 个【字节】并按字符集解码（ZIP / XML 必需）。
    /// **消费字节数恒为 count**，onInvalid 只影响解码结果，不影响游标
    public func readStringBytes(count: Int64, charset!: Charset = Charsets.UTF8,
                                onInvalid!: InvalidByteMode = InvalidByteMode.Replace): String

    /// 读取剩余全部字节并解码
    public func readString(charset!: Charset = Charsets.UTF8,
                           onInvalid!: InvalidByteMode = InvalidByteMode.Replace): String

    /// 解码一段已有字节（宽容）
    public static func decode(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8): String

    /// 解码一段已有字节（严格，失败返回 None）
    public static func decodeStrict(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8): Option<String>

    /// 读一个 Unicode 码点
    public func readRune(charset!: Charset = Charsets.UTF8,
                         onInvalid!: InvalidByteMode = InvalidByteMode.Strict): ?Rune

    /// 读一行（不含换行符）。**没有 onInvalid：永远严格**
    public func readln(charset!: Charset = Charsets.UTF8): ?String

    /// 写一行（内容 + 换行符）
    public func writeln(s: String, charset!: Charset = Charsets.UTF8): Unit
}
```

**`onInvalid` 的默认值按"有没有量上的契约"分档**

| 方法 | 默认 | 判据 |
|---|---|---|
| `readString(count)` | **Strict** | `count` 是字符数契约；宽容会让"读 5 个字符"悄悄变成"5 个字符里含替换符" |
| `readRune` | **Strict** | 逐字符解析多发生在结构化场景，失败必须能被感知 |
| `readln` | **Strict（无参数）** | 行内容必须可信，见 3.8 |
| `readStringBytes(count)` | **Replace** | 消费字节数由调用方给定、**不受解码策略影响**，替换不改变契约 |
| `readString()`（到末尾） | **Replace** | 没有计数契约，目标是"尽量把已有内容给出来" |
| `decode` / `decodeStrict` | 宽容 / 严格 | 入参是完整字节段，无游标风险，按名字取 |

一句话记法：**有"量"的契约（字符数、行）→ 严格；只是"把已有字节变成字符串"（字节数、剩余全部）→ 宽容。**

> `InvalidByteMode` 的定义与 `Replace` 的三条硬规定见 3.7。

> `readStringBytes` 的这一条要在测试里钉死：**无论 `onInvalid` 取哪个值，消费的字节数都必须正好是 `count`**。
> 这是它与 `readString(count)` 的根本分工——前者定字节，后者定字符。

| 方法 | 计数单位 | 场景 |
|---|---|---|
| `write(s)` | — | 序列化时写文本 |
| `readString(count)` | **字符** | 按可见长度取（截断展示、按字数分块） |
| `readStringBytes(count)` | **字节** | 结构里给的是字节长度（ZIP 条目名、XML 片段） |
| `readString()` | — | 读到末尾（整段文本） |
| `decode(bytes)` | — | 已拿到字节，需按不同字符集重试（文件名回退链） |

**`decode(bytes)` 不是多余的**——f_zip 解文件名时字节已经在手上（来自中央目录），需要"先试 UTF-8，失败再试 GBK"。用 `readStringBytes` 表达不了这个语义：它从游标读，且只能试一次。

> 上面是精简签名。`readString` / `decode` 实际还带 `skipBom!: Bool = true` 参数，见 3.5。

### 3.3.1 为什么字符和字节必须分成两个方法

**两者不能合并，因为长度信息的来源不同。**

| 长度的来源 | 单位 | 用哪个 |
|---|---|---|
| ZIP 中央目录的 `file name length` 字段 | 字节 | `readStringBytes` |
| OOXML 里 `<t>` 的实际字节数 | 字节 | `readStringBytes` |
| 业务上"取前 20 个字"做摘要 | 字符 | `readString(count)` |
| 输入框限制"最多 50 字" | 字符 | `readString(count)` |

**如果 `readString(count)` 按字节算**：中文会被从中间切断。"取前 20 字节"在 UTF-8 下只有 6 个汉字，且第 7 个汉字可能被切成半个，解码出乱码或替换字符。

**如果按字符算**：ZIP 解析会全错。ZIP 的 filename length 明确是字节数，按字符读会消费过多或过少的字节，导致后续所有偏移错位。

所以两个都要有，**名字里必须体现单位差异**——`readString` 默认按字符（符合直觉），`readStringBytes` 显式标注字节。

### 3.3.2 "字符"的定义

按 **Unicode 码点** 计数，不是字素簇（grapheme cluster）。

| 输入 | 码点数 | 说明 |
|---|---|---|
| `"中"` | 1 | |
| `"😀"` | 1 | U+1F600，UTF-8 里是 4 字节但仍是 1 个码点 |
| `"👨‍👩‍👧"` | 5 | 家庭 emoji 是 3 个 emoji + 2 个 ZWJ，视觉上 1 个但码点 5 个 |
| `"é"`（组合式） | 2 | `e` + U+0301 组合重音 |

**如果要按"用户感知的字符"计数，需要字素簇分割（UAX #29），那是另一个量级的工作。** 当前设计只做码点级，文档里说明清楚，避免调用方误以为是视觉字符数。

**与 `String.runes()` 对齐**

`readString(count)` 消费的"字符数"必须与 `s.runes()` 迭代出的元素数一致（即 Unicode 码点）。
这样下面两段是等价的：

```cangjie
let s = buf.readString(5)
let n = s.runes().count()          // == 5（除非剩余不足 5）
```

**不做字素簇（视觉字符）语义。** `"👨‍👩‍👧"` 按码点是 5、按视觉是 1；
UAX #29 的分割需要一整套字素边界表与状态机，与本模块"提供基础读写"的定位不成比例。
选码点是因为它与 `runes()`、`String.size` 的既有语义一致——**同一套 API 里出现两种"字符"定义才是灾难**。
需要视觉字符计数的调用方应在上层自行处理。

### 3.3.3 readString(count) 的实现与边界

**不能逐字节解码**——必须先进到字符边界。

三条实现路，按优先级：

| 路径 | 适用 | 做法 |
|---|---|---|
| **A. UTF-8 快扫** | charset 是 UTF-8 | 扫字节，非续字节（`(b & 0xC0) != 0x80`）即一个字符起点，数够 count 个后一次性解码 |
| **B. readRune 循环** | 其他多字节字符集 | 循环调 `readRune()` 累积，最后拼接 |
| **C. 固定宽度** | 单字节字符集 | 直接读 count 字节 |

A 的关键优势：**只解码一次**。B 在 count = 1000 时要做 1000 次小解码，量级差很多。

**边界语义**：

| 情况 | 行为 |
|---|---|
| 剩余字符 ≥ count | 消费对应字节，返回 count 个字符 |
| 剩余字符 < count | **消费全部剩余，返回实际内容**（不补空、不报错） |
| 中途遇到非法字节序列 | 停在非法字节**之前**，返回已解出的部分，游标不越过非法字节 |
| 已到末尾 | 返回 `""`，游标不动 |

因为返回类型是 `String` 而非 `?String`，"读不满"和"读满"从返回值上区分不出来。需要精确控制时用：

```cangjie
/// 返回 (实际内容, 实际读到的字符数)
public func readStringEx(count: Int64, charset!: Charset = Charsets.UTF8): (String, Int64)
```

调用方靠第二个返回值判断是否读满、是否到 EOF，避免"用 `== ""` 猜 EOF"这种不可靠写法。

**BOM 不占 count**：首次读取时先跳过 BOM，再从 BOM 之后开始计字符数。

### 3.4 写 String 后怎么知道长度

`write(s)` 不写长度前缀——编码后的字节数是变化的，读的时候没有边界信息。

三种方案：

| 方案 | 做法 | 适用 |
|---|---|---|
| **A（默认）** | 调用方自己保证长度（ZIP 里长度来自 header） | ✅ 二进制容器格式 |
| B | 长度前缀（1/2/4 字节 + 数据） | 自定义序列化 |
| C | 终止符 | ❌ 二进制里不可靠（数据可能含终止符） |

**选 A**：ZIP 和 OOXML 的长度信息都在结构里自带，加前缀反而会破坏格式。

另外提供可选的长度前缀版本给自定义场景：

```cangjie
public func writeLengthPrefixed(s: String, charset!: Charset = Charsets.UTF8): Unit
public func readLengthPrefixed(charset!: Charset = Charsets.UTF8): String
```

前缀用 `UInt32` 小端（与 ZIP 风格一致），长度上限 4 GB。

### 3.5 BOM 处理

charset4cj 明确标注 BOM 支持待开发，所以 **UTF-8 BOM（`EF BB BF`）不会被自动跳过**。

不处理的后果：Windows 导出的 UTF-8 文本第一个字符会变成 `U+FEFF`（零宽不换行空格），表现为"看起来没坏但字符串比较永远不相等"。这在文件名匹配、去重、索引里都会变成隐蔽 bug。

建议：

```cangjie
public func readString(count: Int64, charset!: Charset = Charsets.UTF8, skipBom!: Bool = true): String
public static func decode(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8, skipBom!: Bool = true): String
```

- 仅当 charset 是 UTF-8 / UTF-16LE / UTF-16BE 时检测对应 BOM
- `skipBom` 默认 `true`
- **`readString(count)` 按字符计数，BOM 不占名额**：先跳过 BOM，再从 BOM 之后开始数字符
- **`readStringBytes(count)` 按字节计数，不提供 `skipBom`**：它的 `count` 来自结构里的字节长度（ZIP 的 `file name length`、XML 片段长度），这个数字是权威的，跳过 BOM 会让消费量与声明不一致。需要跳 BOM 时先用 `read(buf)` 取原始字节，再交给 `decode(bytes, skipBom: true)`

### 3.6 解码失败的处理

非法字节序列（比如 UTF-8 里的孤立尾字节）有两种处理：

| 策略 | 行为 | 适用 |
|---|---|---|
| 抛异常 | `DecoderException` 向上冒泡 | 严格场景 |
| 替换 | 非法部分变成 `U+FFFD` | 宽容场景 |

**建议默认宽容**，与 f_excel 的"读取要宽容"原则一致——知识库场景下，个别非法字符不该让整份文档进不去。

但要注意：**宽容会掩盖问题**。所以提供严格版本：

```cangjie
public static func decodeStrict(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8): Option<String>
```

`decode` 宽容、`decodeStrict` 返回 `None`。

**已定：两者都提供**，命名就是 `decode` / `decodeStrict`。

f_zip 的文件名回退链正好用 `decodeStrict`——"UTF-8 严格解码失败就换 GBK"，
这里必须严格，否则宽容解码永远第一次就成功，回退链形同虚设。

> 例外提醒：`readln` **不用**这两个的宽容语义，它走严格解码并在失败时抛异常（见 3.8）。
> 「宽容」只适用于"整段解码出一个字符串"的场景，不适用于"必须先确定行边界"的场景。

### 3.7 readRune：按码点读取

```cangjie
public func readRune(charset!: Charset = Charsets.UTF8): ?Rune
```

`Rune` 是 `std.core` 的 Unicode 标量类型，可用 `toString()` 转字符串、`UInt32(rune)` 取码点。

**难点一：编码是变长的。**

| 字符集 | 单码点字节数 |
|---|---|
| UTF-8 | 1 ~ 4 |
| GBK | 1 ~ 2 |
| GB18030 | 1 ~ 4 |
| UTF-16 | 2 或 4（代理对） |
| 单字节字符集（ISO-8859 等） | 固定 1 |

所以"读一个字节"根本不成立。

**难点二：charset4cj 没有流式 Rune 解码器，只有"整段字节 → String"。**

于是只有两条实现路：

**路径 A：UTF-8 按首字节算长度（快，覆盖 95% 场景）**

| 首字节 | 序列长度 | 说明 |
|---|---|---|
| `0x00`–`0x7F` | 1 | ASCII |
| `0xC2`–`0xDF` | 2 | |
| `0xE0`–`0xEF` | 3 | |
| `0xF0`–`0xF4` | 4 | |
| `0x80`–`0xBF` | 非法 | 孤立续字节 |
| `0xC0`–`0xC1` | 非法 | overlong 编码 |
| `0xF5`–`0xFF` | 非法 | 超出 U+10FFFF |

**路径 B：通用试解码（慢，但字符集无关）**

```
for len in 1..4:
    若剩余字节 < len: 跳出
    用 charset 严格解码 buf[pos..pos+len]
    若成功且结果恰好是 1 个码点: 消费 len 字节, 返回该 Rune
返回 None
```

判"恰好 1 个码点"：把解码结果转成码点序列，长度必须为 1。长度 > 1 说明只切了半个字符，继续试更长的。

**建议实现**：先判断 charset 是否为 UTF-8，是则走 A，否则走 B。B 最坏 4 次解码，对逐字符读取有性能影响，但非 UTF-8 场景本身就少。

**失败与游标语义**

| 情况 | 返回 | 游标 |
|---|---|---|
| 成功解出 1 个码点 | `Some(rune)` | 前进该码点字节数 |
| 首字节非法 | `None` | **不动** |
| 序列不完整（EOF 处半截） | `None` | **不动** |
| 已到末尾 | `None` | 不动 |

与端序读写一致：**失败不推进游标**。但这样有个副作用——遇到坏字节会永远卡住。所以必须配一个逃生口：

```cangjie
public func peekRune(charset!: Charset = Charsets.UTF8): ?Rune  // 不移动游标
public func skipByte(): Unit                                     // 跳过 1 字节
```

调用方遇到 `None` 时自行决定：是 `skipByte()` 继续，还是停止解析。库不替它做决定——因为"数据坏了要不要继续"是业务语义。

**关于"坏字节要不要替换成 U+FFFD"**

上面这套语义（严格、失败不动游标）适合**结构化解析**：数据坏了就该停下，把半个字符猜成别的比失败更糟。

但对"尽量读出能读的内容"的场景（日志采集、网页正文、用户上传的脏文本），
`while (let Some(r) <- buf.readRune())` 碰到第一个坏字节就结束，后面全丢——这不可接受。

所以提供一个显式模式：

```cangjie
public enum InvalidByteMode {
    | Strict      // 默认：返回 None，游标不动
    | Replace     // 用 U+FFFD 占位，游标前进
}

public func readRune(
    charset!: Charset = Charsets.UTF8,
    onInvalid!: InvalidByteMode = InvalidByteMode.Strict
): ?Rune
```

`Replace` 模式的三条硬规定：

1. **按"最大非法子序列"消费，不是按 1 字节。** UTF-8 里一个 3 字节序列坏了两个字节，
   应消费这 3 个字节并产出**一个** U+FFFD；按 1 字节消费会产出 3 个 U+FFFD，
   长度信息全错，还会让"原文第 N 个字符"这种定位彻底失效。这就是 RFC 3629 的 maximal subpart 规则。
2. **`None` 只表示 EOF。** Replace 模式下不再用 `None` 表示"解码失败"，
   否则调用方的 `while (Some(r))` 还是会在坏字节处停下。
3. **不提供"静默跳过"（Skip）模式。** 跳过会让后续字节错位对齐——GBK 双字节的首字节被丢后，
   那个尾字节恰好落在合法范围，就解出一个**看起来正常但内容错误**的字符。
   这种错误比 U+FFFD 难查得多：U+FFFD 至少是可见的"这里坏了"。

4. **U+FFFD 计入 `readStringEx` 的字符数。** 它确实是一个产出字符，也确实消费了字节。
   不计入的话 `n != s.runes().count()`，元组自身就不自洽——3.3.2 的不变式会被破坏。
   需要"实际消费了多少**字节**"时，取 `readOffset` 的前后差值：那是精确的字节量，且与解码策略无关。

> 默认必须是 `Strict`。设成 `Replace` 等于把所有解码错误变成一个个替换字符静默写进下游，
> 而多数调用方根本不会检查返回值里有没有 U+FFFD。

### 3.8 readln：按行读取

```cangjie
public func readln(charset!: Charset = Charsets.UTF8): ?String
```

**返回值语义**

| 情况 | 返回 | 游标 |
|---|---|---|
| 正常一行（后有 `\n`） | `Some("内容")`，不含换行符 | 前进到换行符之后 |
| 空行（只有 `\n`） | `Some("")` | 前进 1 字节 |
| 末行无换行 | `Some("内容")` | 前进到末尾 |
| 已到末尾 | `None` | 不动 |

`?String` 而不是 `String`，正是为了区分"文件结束"和"最后是一个空行"——这两者返回空串时的含义完全不同。

**行终止符处理**

| 序列 | 处理 |
|---|---|
| `\n`（LF） | 终止符，消费 1 字节 |
| `\r\n`（CRLF） | 终止符，消费 2 字节 |
| 孤立 `\r`（CR） | **默认不作为终止符**，保留在内容里 |

孤立 CR 是经典 Mac（OS 9 及更早）的换行。现在极少见，**已定：不提供 `crAsNewline` 参数**，
孤立 `\r` 一律保留在内容里。

> 连带影响：XML 规范要求孤立 `\r` 归一成 `\n`。既然 `readln` 不做这件事，
> 归一化就落在字符层之上（f_xml 的 2.4 已相应说明）。**"谁负责归一化"必须只有一个答案**，
> 两边都做会变成 `\r\r\n` 之类的二次处理问题。

**关键约束：只在 ASCII 兼容字符集上做字节扫描**

`readln` 的实现是"扫字节找 `0x0A`，再解码整段"。这在 UTF-8 / GBK 上安全，但不是所有字符集都安全：

| 字符集 | 多字节序列里会出现 `0x0A` 吗 | 字节扫描安全性 |
|---|---|---|
| UTF-8 | 不会。续字节恒为 `0x80`–`0xBF`，首字节 ≥ `0xC2` | ✅ 安全 |
| GBK / GB18030 | 不会。第二字节范围 `0x40`–`0xFE`（排除 `0x7F`） | ✅ 安全 |
| EUC-KR / Shift_JIS 等 | 尾字节范围同样避开 `0x0A` | ✅ 安全 |
| **UTF-16 / UTF-32** | **会**。如 U+0A00 的低字节就是 `0x0A` | ❌ **不安全** |

所以：

- UTF-16 / UTF-32 走 `readln` 会**在字符中间误断行**
- **已定：传入 UTF-16/32 时直接抛异常**，不给"可能读错"的结果
- **不提供 `readlnDecoded()` 兜底**：按行读的前提是"行边界可信"，一个要先全量解码才能确定行边界的实现，
  与"流式读行"这个定位自相矛盾。真需要按行处理 UTF-16，应先整体转成 UTF-8 再读
- **解码本身严格**：指定 charset 后，遇到不符合该字符集的字节序列就抛异常，**不做 U+FFFD 替换**。
  理由同上——替换会让"这一行有多长"不可信，而 `readln` 返回的是整行内容，长度错了下游全错

**BOM 处理**

首次 `readln` 应先检测并跳过 BOM（复用 3.5 的逻辑），否则第一行会带一个不可见的 `U+FEFF`。

**与 charset4cj 语义对齐**

charset4cj 导出了 `TextReader.readln(): Option<String>`，语义应与之一致，避免同一个项目里两套"读行"行为不同。

### 3.9 writeln：按行写入

```cangjie
public func writeln(s: String, charset!: Charset = Charsets.UTF8): Unit
```

语义：写入 `s`，再写入一个换行符。三个必须定清楚的点：

**① 换行符固定 LF（`\n`），不跟随平台**

不要学 C# 的 `WriteLine` 或 Java 的 `System.lineSeparator()` 那种"Windows 下自动用 CRLF"的行为：

- ZIP / OOXML / XML 里 CRLF 会被规范化成 LF，自动插入 CRLF 只制造不一致
- 平台相关的输出让文件**不可复现**——同一份数据在不同机器上生成不同字节，破坏哈希、差分、缓存
- 二进制容器要的是确定性，不是"记事本里看着舒服"

需要 CRLF 时由调用方显式表达（拼 `"\r\n"`），不给隐式行为。

**② 换行符必须按 charset 编码，不能直接写 `0x0A`**

这是最容易写错的地方。朴素实现：

```cangjie
this.write(s, charset)
this.writeByte(0x0A)      // ❌ 错
```

在 UTF-8 / GBK 下碰巧能工作（换行就是单字节 `0x0A`），但 **UTF-16LE 里换行是 `0A 00`、UTF-16BE 是 `00 0A`**。直接写一个 `0x0A` 会产出非法序列，后面所有解码都错位。

正确写法：

```cangjie
this.write(s, charset)
this.write("\n", charset)   // ✅ 换行也走同一套编码
```

**③ 空字符串也要写换行**

`writeln("")` 应产出一个空行，而不是什么都不写——与 `readln()` 返回 `Some("")` 对称。

**往返一致性**

`writeln` 与 `readln` 必须能往返，这是最重要的验收用例：

```
writeln("a"); writeln(""); writeln("中")
  → readln() == Some("a")
  → readln() == Some("")
  → readln() == Some("中")
  → readln() == None
```

写入与读取的换行约定不一致，是"自己写自己读不出来"最典型的成因。

### 3.10 四个新增方法的共同点

`readString` / `readRune` / `readln` / `writeln` 四者共享同一套约定，实现时应统一：

| 约定 | 说明 |
|---|---|
| 失败不推进游标 | 保持"要么成功，要么完全没动" |
| EOF 返回 `None` | 不返回空串冒充结束 |
| 解码默认宽容，另给严格版 | 业务解析宽容，回退链严格 |
| BOM 默认跳过 | 可通过参数关闭 |
| 不替调用方决定坏数据怎么办 | 提供 `skipByte()` 逃生，不做隐式跳过 |



`f_io/cjpm.toml`：

```toml
[dependencies]
"cangjie_tpc::charset4cj" = "1.0.6"   # 写接入时的最新发布版；升级只改这一行
```

**已定：用中心仓的最新发布版，不锁死在 `1.0.6`。**

cjpm 的依赖必须写具体版本号（没有 `^` 语义），所以"用最新版"落到流程上是：

1. 首次接入取当时最新（写作时为 `1.0.6`）
2. 之后定期 `cjpm update`，每次都跑一遍 P-1 的冒烟用例（encode / decode / readln / BOM / GBK）
3. 升级失败就记录并回退——**但不靠"锁死版本"回避升级**：charset4cj 的编码表本身在修 bug，
   长期停在旧版是把问题留给自己

接入后要验证两件事：

1. 中心仓能解析到目标版本（离线环境需提前 vendor）
2. 与当前 `cjc 1.3.0` 编译器兼容（charset4cj 的 README 提到适配过 1.1.3）

**风险**：如果 `charset4cj` 与 cjc 1.3.0 不兼容，会阻塞整个 f_zip 计划。建议第一步就先做这个兼容性验证，而不是先写代码。

---

### 3.11 同步扩展到 std.io.ByteBuffer

**结论：可以做，语义基本一致。** 但本节最初按签名推断出的两个差异，**实测证明都不成立**——
下面以实测为准。

#### 实测（cjc 1.3.0-alpha.20261023，aarch64）

```cangjie
let b = ByteBuffer()
b.write("abc" 的字节)
// pos=0  len=3  remain=3  cap=32     ← 写完 position 是 0，不是末尾
let n = b.read(buf)                    // n=3：不 seek 就能读到
b.seek(SeekPosition.Begin(0)); b.read(buf)      // 仍 n=3
b.bytes().size                         // 全读完后 = 0
b.write("abc")                         // pos=3  len=6
b.bytes().size                         // = 3（未读部分）
b.seek(SeekPosition.Begin(0)); b.bytes().size   // = 6
b.write("abc")                         // 在 Begin(0) 之后写
b.bytes().size                         // = 9  ← 追加，不是覆盖
```

三条与直觉不同的结论：

| # | 原本以为 | 实测 |
|---|---|---|
| 1 | 写后 position 停在末尾，读之前必须 seek 回 0 | **position 是读游标，写不动它**；写完可直接读 |
| 2 | `bytes()` 返回整个底层数组 | **返回未读部分**（`position..length`） |
| 3 | 写可以覆盖（像 memcpy） | **写永远追加**，seek 之后也一样 |

#### 能力对照（修正版）

| 能力 | `f_io.ByteBuffer` | `std.io.ByteBuffer` | 差异 |
|---|---|---|---|
| 读游标 | `readOffset`（`mut prop`） | `position`（`Seekable`） | 等价 |
| 读定位 | `seekReading` | `seek(sp)` | 等价 |
| **写游标** | `writeOffset`；`seekWriting` 可在 `[readOffset, capacity)` 内定位 | **无公开接口，写永远追加** | ⚠️ **唯一实质差异** |
| 未读数据 | `bytes()` = `buffer[roffset..woffset]` | `bytes()` = 未读部分 | **一致** |
| 总长 / 剩余 | `writeOffset` / `writeOffset - readOffset` | `length` / `remainLength` | 等价的两种写法 |
| 截断 | 无 | `setLength` | std 多一个 |
| 清空 / 克隆 | `clear` / `clone` | `clear` / `clone` | 一致 |

#### 唯一要记住的差异：std 不能回填

`f_io` 的 `seekWriting` 允许把写游标移回 `[readOffset, capacity)`，于是可以"先占位、再回填"：

```cangjie
let at = buf.writeOffset
buf.writeUInt32(0, endian: Endian.Little)                     // 占位
... 写正文 ...
let end = buf.writeOffset
buf.seekWriting(SeekPosition.Begin(at))
buf.writeUInt32(UInt32(end - at - 4), endian: Endian.Little)  // 回填
buf.seekWriting(SeekPosition.End(0))
```

`std.io.ByteBuffer` **做不到**：实测 `seek(Begin(0))` 之后再写仍然是追加（size 9）。
ZIP 的 local header 回填、长度前缀回填、分块重组都依赖这个能力。

> **凡是需要"回填"的逻辑，只能用 `f_io.ByteBuffer`，不能换成 `std.io.ByteBuffer`。**

反过来说，纯文本读写（`readString` / `readln` / `readRune` / `write` / `writeln`）不需要写游标定位，
两套都能实现，`ExtendByteBufferText` 可以共用同一份算法——
这也是把文本扩展做成**接口**而不是塞进 `ExtendByteBuffer` 的原因之一。

#### 第三个差异：与 `std.io` 顶层函数重名

`std.io` 已有顶层函数：

```cangjie
public func readString<T>(from: T): String where T <: InputStream & Seekable
```

它读的是**整个流**。我们的成员方法也叫 `readString`，`buf.readString()` 会正确解析到成员，
但同一份代码里同时出现 `readString(buf)` 和 `buf.readString()` 会让人困惑。
保留 `readString`（成员语义更自然），但在 API 文档里显式标注两者区别。

### 3.12 长度前缀：不提供方法，但给出范式

**问题**：从缓冲区里连续读多条变长记录时，需要"这段多长"来定界。要不要提供
`writeLengthPrefixed(s)` / `readLengthPrefixed(): String`？

**结论：不提供。** 理由不是"用不上"，而是**固化任何一种前缀格式都会和使用方的协议打架**：

| 变体 | 例子 | 库若固定成一种 |
|---|---|---|
| 宽度 | 1 / 2 / 4 / 8 字节、varint（LEB128） | 别人的协议是 varint，用不了 |
| 字节序 | 大端 / 小端 | 只对一半 |
| 计数单位 | 字节 / 字符 / 码点 / 元素个数 | 文本场景差别很大 |
| 是否含自身 | 有的协议把前缀自身也算进长度 | 差 4 字节就全错 |
| 载体 | 只有**可定位写**的 buffer 能做；纯 `OutputStream` 不行 | 一半场景直接不支持 |

最后一条尤其致命：长度前缀在流上无法"边写边定"，必须**先占位、写完回填**——
这要求写游标可回退，而 `std.io.ByteBuffer` 根本做不到（见 3.11）。

**该做的不是加方法，而是给出范式**（约 10 行，调用方按自己的协议改宽度和端序）：

```cangjie
// 写：占位 → 写正文 → 回填（依赖 f_io.ByteBuffer 的 writeOffset 可定位）
func writeRecord(buf: ByteBuffer, body: Array<Byte>): Unit {
    let at = buf.writeOffset
    buf.writeUInt32(0, endian: Endian.Little)          // 占位
    let bodyAt = buf.writeOffset
    buf.write(body)
    let end = buf.writeOffset
    buf.seekWriting(SeekPosition.Begin(at))
    buf.writeUInt32(UInt32(end - bodyAt), endian: Endian.Little)
    buf.seekWriting(SeekPosition.End(0))
}

// 读：先读宽度，再按长度取
func readRecord(buf: ByteBuffer): ?Array<Byte> {
    let n = buf.readUInt32(endian: Endian.Little) ?? return None
    if (Int64(n) > buf.writeOffset - buf.readOffset) { return None }   // 长度不可信
    let out = Array<Byte>(Int64(n), repeat: 0)
    if (buf.read(out) != Int64(n)) { return None }
    out
}
```

三条必须提醒的：

1. **宽度装不下就是错误，不能截断。** `UInt32` 前缀写 5 GB 会静默回绕——
   这类 bug 在数据量小时永远发现不了。
2. **读到的长度必须校验**，先比对剩余字节再分配内存。否则一个伪造的 `0xFFFFFFFF`
   会让 `Array<Byte>(4G)` 直接把进程打死（和 ZIP 炸弹同一类问题）。
3. **varint 不能回填**——变长前缀无法"先占位后补"，只能先算好长度或改结构。

如果将来 fountain 里出现**多处**需要，正确的做法是抽一个 `f_io` 之上的协议 helper
（例如 `f_record` / `f_frame`），而不是往 `ByteBuffer` 上加一对名字含糊的方法。

---

## 4. 构建配置

`f_io/cjpm.toml`：

```toml
[dependencies]
"cangjie_tpc::charset4cj" = "1.0.6"   # 写接入时的最新发布版；升级只改这一行
```

**已定：用中心仓的最新发布版，不锁死在 `1.0.6`。**

cjpm 的依赖必须写具体版本号（没有 `^` 语义），所以"用最新版"落到流程上是：

1. 首次接入取当时最新（写作时为 `1.0.6`）
2. 之后定期 `cjpm update`，每次都跑一遍 P-1 的冒烟用例（encode / decode / readln / BOM / GBK）
3. 升级失败就记录并回退——**但不靠"锁死版本"回避升级**：charset4cj 的编码表本身在修 bug，
   长期停在旧版是把问题留给自己

接入后要验证两件事：

1. 中心仓能解析到目标版本（离线环境需提前 vendor）
2. 与当前 `cjc 1.3.0` 编译器兼容（charset4cj 的 README 提到适配过 1.1.3）

**风险**：如果 `charset4cj` 与 cjc 1.3.0 不兼容，会阻塞整个 f_zip 计划。建议第一步就先做这个兼容性验证，而不是先写代码。

## 5. 实现要点汇总

| # | 要点 | 原因 |
|---|---|---|
| 1 | endian 不设默认值 | 静默用错端序的排查成本极高 |
| 2 | 读越界返回 None 并回滚游标 | 保证"要么整体成功，要么完全没动" |
| 3 | 校验实际读到的字节数 | 否则补零后解码出伪合法值 |
| 4 | 两个 extend 分文件放 | 规避同包同名类型歧义 |
| 5 | SyncByteBuffer 一并补齐 | 否则线程安全版反而是残缺版 |
| 6 | `decode` 与 `decodeStrict` 并存 | 回退链需要严格版，业务解析需要宽容版 |
| 7 | BOM 默认跳过 | 否则 U+FEFF 引发隐蔽的比较失败 |
| 8 | `charset` 不要写成 `chatset` | 公共 API 拼写错误不可逆 |
| 9 | `readRune` 失败不推进游标，另给 `skipByte()` 逃生 | 否则一个坏字节会让后续读取永久卡死 |
| 10 | `readln` 只支持 ASCII 兼容字符集，UTF-16/32 明确报错 | UTF-16 的字符字节里可能出现 `0x0A`，会误断行 |
| 11 | `readRune` 对 UTF-8 走首字节长度快判 | 通用试解码最坏要试 4 次，逐字符读会慢 |
| 12 | `writeln` 的换行符必须走 charset 编码 | 直接写 `0x0A` 在 UTF-16 下会产生非法序列 |
| 13 | `writeln` 固定 LF，不做平台判断 | 平台相关输出破坏可复现性与哈希一致性 |
| 14 | `readString(count)` 按字符、`readStringBytes(count)` 按字节，两者都要有 | 按字节取会切断汉字；按字符取会错位 ZIP 偏移 |
| 15 | 字符计数用 UTF-8 字节快扫，不要逐字符解码 | 逐字符解码在 count 大时慢一个量级 |
| 16 | 读不满不报错，靠 `readStringEx` 的返回值区分 | 返回 `String` 无法表达"读满了还是到 EOF 了" |
| 17 | 文本方法抽成独立接口 `ExtendByteBufferText` | 不塞进 `ExtendByteBuffer`（否则 34 个方法，二进制与文本混杂） |
| 18 | 两个 extend 分文件，逻辑共用私有实现 | 规避同包同名歧义，且避免两份实现漂移 |
| 19 | **只有"回填"逻辑依赖 `f_io` 的写游标**；std 版写永远追加 | 实测（3.11）：两者读游标语义一致，`bytes()` 都是未读部分；差异只在能否定位写游标 |

---

## 6. 测试要点

### 6.1 端序

```cangjie
// 同一组字节，两种端序读出不同值
// bytes = [0x01, 0x02, 0x03, 0x04]
readUInt32(endian: Big)    == 0x01020304
readUInt32(endian: Little) == 0x04030201
```

覆盖全部宽度：UInt16 / UInt32 / UInt64 / Int16 / Int32 / Int64。

### 6.2 浮点

**必须用位模式比较，不能用 `==`**：NaN != NaN，-0.0 == 0.0，都会让断言失真。

```cangjie
let a: Float32 = ...        // 包含 NaN / Inf / -0.0
buf.writeFloat32(a, endian: Endian.Little)
let b = buf.readFloat32(endian: Endian.Little)
assert(a.toBits() == b.toBits())
```

### 6.3 越界原子性

```
准备 3 字节，readOffset = 0
readUInt32() → None
assert(readOffset == 0)      // 关键：游标没动
```

再测"恰好读完"和"len == 0"两种边界。

### 6.4 字符集往返

| 用例 | 验证点 |
|---|---|
| 纯 ASCII | 基础 |
| 中文（UTF-8 / GBK / GB18030） | 编码一致 |
| emoji（4 字节 UTF-8） | 代理对 / 非 BMP |
| 带 BOM 的 UTF-8 | U+FEFF 被跳过 |
| 非法 UTF-8 字节序列 | `decode` 替换、`decodeStrict` 返回 None |
| 空字符串 | 写入 0 字节，读回空串 |
| 极长字符串（1 MB） | 无性能异常 |

### 6.5 交叉验证

同一段字节，分别用 `f_io.ByteBuffer` 和 `std.io.ByteBuffer` 读取，结果必须一致。这条能一次性验证两个 extend 的实现是否等价。

### 6.6 readRune

| 用例 | 验证点 |
|---|---|
| `"A"` | 1 字节，返回 `r'A'` |
| `"中"`（UTF-8 3 字节） | 正确解出 U+4E2D |
| emoji `"😀"`（4 字节） | 正确解出 U+1F600，不是代理对拆成两个 |
| 中文（GBK 2 字节） | 走通用路径也能正确解出 |
| 孤立续字节 `0x80` | 返回 `None`，游标不动 |
| overlong `0xC0 0xAF` | 返回 `None`（必须拒绝） |
| EOF 处半截序列 | 返回 `None`，游标不动 |
| 已到末尾 | 返回 `None` |
| 连续读完整段文本 | 逐个 Rune 拼回去与原串相等 |

### 6.7 readln

| 用例 | 验证点 |
|---|---|
| `"a\nb\n"` | 两次 `Some("a")` / `Some("b")`，第三次 `None` |
| `"a\r\nb"` | `Some("a")`，`\r` 被剥掉 |
| 空行 `"\n\n"` | 两次 `Some("")` |
| 末行无换行 `"a"` | `Some("a")`，再读 `None` |
| 空缓冲 | 第一次就 `None` |
| 带 BOM 的文件 | 首行不含 `U+FEFF` |
| 超长行（1 MB 无换行） | 正常返回，不 OOM |
| UTF-16 输入 | 抛明确异常，而不是给出错乱结果 |

### 6.8 writeln

| 用例 | 验证点 |
|---|---|
| `writeln("a")` | 末尾是单个 `0x0A`，没有 `0x0D` |
| `writeln("")` | 只写 1 字节 `0x0A`（空行） |
| UTF-16LE 下 `writeln("a")` | 末尾是 `0A 00` 两字节，不是裸 `0x0A` |
| UTF-16BE 下 `writeln("a")` | 末尾是 `00 0A` |
| `writeln` ×3 → `readln` ×3 | 内容与空行全部还原，第 4 次返回 `None` |
| 与 `readln` 混合往返 | 含中文、emoji、空行的多行文本完整往返 |

### 6.9 readString 的字符 vs 字节

**字符计数（`readString(count)`）**

| 用例 | 验证点 |
|---|---|
| 纯 ASCII，读 5 字符 | 消费 5 字节 |
| `"中文测试"`，读 2 字符 | 返回 `"中文"`，消费 6 字节（UTF-8） |
| `"a😀b"`，读 2 字符 | 返回 `"a😀"`，消费 5 字节（emoji 占 4） |
| `"家庭" + 👨‍👩‍👧`，读 2 字符 | 返回 `"家"` + 整个家庭 emoji？ —— **按码点计为 5，会切在 ZWJ 中间**，记录为已知限制 |
| 只剩 3 字符但读 10 | 返回 3 字符，游标到末尾 |
| 空缓冲 | 返回 `""`，游标不动 |
| GBK 中文，读 2 字符 | 消费 4 字节 |
| 中途遇非法字节 | 返回已解出部分，游标停在非法字节前 |

**字节计数（`readStringBytes(count)`）**

| 用例 | 验证点 |
|---|---|
| 读 6 字节的 `"中文"` | 正常解出 |
| 读 4 字节（切断一个汉字） | 返回前半部分 + 替换字符（或按严格模式报错），**游标仍前进 4 字节** |
| 与 `readString` 同一数据对比 | 字节语义与字符语义的消费量必须不同（除纯 ASCII 外） |

**最后一条是关键交叉验证**：如果两个方法对同一段中文消费了相同字节数，说明其中一个的单位搞错了。

---

### 6.10 坏字节与严格解码

| 用例 | 期望 |
|---|---|
| `Strict` 遇到孤立续字节 `0x80` | 返回 `None`，游标不动（连调两次结果相同） |
| `Replace` 遇到 `0xE4 0xB8`（3 字节序列缺一截） | 返回 `Some(U+FFFD)`，**一次消费 2 字节**，不是 2 个 U+FFFD |
| `Replace` 读完全文 | 中途坏字节不产生 `None`；只有结尾一个是 `None` |
| `Replace` + 空输入 | 第一次就返回 `None` |
| `readString(3)` 跨坏字节 | 抛异常，不返回半截字符串 |
| `readString(5).runes().count()` | 等于 5（与码点计数一致） |
| `readln` 传 UTF-16LE | 抛异常，消息指明"readln 不支持 UTF-16/32" |
| `readln` 遇非法 UTF-8 | 抛异常（不做 U+FFFD 替换） |
| 内容里含孤立 `\r` | 不作为换行，原样保留在返回的 String 里 |
| `readStringBytes(5, onInvalid: Replace)` 且 5 字节含坏字节 | 返回的字符串里有 U+FFFD，**消费的字节数仍为 5** |
| 同上但 `onInvalid: Strict` | 抛异常，**消费的字节数仍为 5**（不能因为失败就少读） |
| `readString(5)` 默认（Strict）遇坏字节 | 抛异常 |
| `readString()` 默认（Replace）遇坏字节 | 不抛，坏处变 U+FFFD，一直读到末尾 |

---

## 7. 实施顺序

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0** | `charset4cj` 在 cjc 1.3.0 下编译通过 | 一个最小 encode/decode 用例跑通 |
| **P1** | 类型化读写 24 个方法 + 端序单测 | 大端/小端读写全部正确 |
| **P2** | 越界原子性（回滚游标） | 越界后 `readOffset` 不变 |
| **P3** | `write(String)` + `readString`(字符) + `readStringBytes`(字节) + `decode` | 字符/字节两种语义的消费量符合预期 |
| **P4** | BOM 跳过 + 严格/宽容双版本 | 带 BOM 文本首字符正确 |
| **P5** | `SyncByteBuffer` 对齐 | 交叉验证通过 |
| **P6** | `readRune` + `peekRune` + `skipByte` | UTF-8 与 GBK 都能逐字符正确解出 |
| **P7** | `readln` + `writeln` + 行终止符 | `\n` / `\r\n` / 空行 / 末行无换行都正确；writeln→readln 往返一致 |
| **P8** | `std.io.ByteBuffer` 等价扩展 | 两个 ByteBuffer 对同一输入的结果与消费字节数逐一相等 |

**P0 是硬门槛**：charset4cj 若与 cjc 1.3.0 不兼容，整个方案要换（备选是自己写 UTF-8/GBK 转换，工作量大幅上升）。建议第一天就验证这一条。

---

## 8. 对下游的影响

**f_zip 依赖本设计的以下能力**：

| f_zip 的用法 | 依赖项 |
|---|---|
| 解析 local header / 中央目录 / EOCD | `readUInt16(Endian.Little)` / `readUInt32(Endian.Little)` |
| 写出 ZIP 结构 | `writeUInt16` / `writeUInt32`（Little） |
| **读条目名（长度来自 header，单位是字节）** | **`readStringBytes(fileNameLength)`** |
| 文件名编码判定（UTF-8 / GBK 回退） | `decodeStrict(bytes, charset)` |

**注意第三行**：ZIP 的 `file name length` 明确是**字节数**。如果这里误用 `readString(count)` 按字符读，中文文件名会多消费字节，后面所有偏移全错。这是"字符/字节必须分开"最直接的例证。

**f_excel 依赖**：主要用 `f_io.ByteBuffer` 作序列化后端（`seekWriting` 回填长度、`bytes()` 直接交付）。读 XML 文本时是"扫字节到闭合标签 → 用 `decode(bytes)` 解码切片"，不依赖 count 版本；`readString` / `readRune` / `readln` 在其场景里用得不多，但作为通用能力仍应提供。

---

## 9. 同批交付：`PrefixStream`

这个类型不属于 ByteBuffer，但和它同批进 `f_io`——因为 f_xml 的字符层前置任务依赖它，
而它本身与 XML 无关（见 `f_xml模块设计.md` 的 1.4）。

```cangjie
package fountain::f_io

public class PrefixStream <: InputStream {
    /// prefix 先出，随后接 rest；close() 关闭 rest
    public init(prefix: Array<Byte>, rest: InputStream)

    /// 从当前流位置再探一次（可选，用于"两段探测"场景）
    public func peekPrefix(n: Int64): Array<Byte>
}
```

设计要点：

| 项 | 决定 |
|---|---|
| 数据形态 | `prefix` 是 `Array<Byte>`（就是刚从 rest 读出来的那几个字节），不是 `InputStream` |
| 读取顺序 | prefix 优先；耗尽后透传 rest |
| 结束 | rest 读到 EOF 即结束，不额外补字节 |
| `close()` | 关闭 rest；prefix 是内存数组，无需关闭 |
| 编码 | **完全不碰**，纯字节搬运 |
| 线程安全 | 不做（与 f_io 其它流一致，单线程使用） |

**为什么值得单独抽出来**：任何"先探头部再解析"的格式都要这个能力（图片魔数、压缩格式、协议握手）。
每个解析器各写一份的话，衔接处的短读边界会各错各的——而这个 bug 只在"prefix 刚好用尽、
rest 还没读"的那一两个字节上出现，极难复现。

> f_zip **不需要**它：f_zip 的两条路径是"全量入 buffer"和 `File.seek`，都不存在"读了再放回去"。

---

## 10. 已定事项与剩余问题

### 10.1 已定（不再讨论）

| # | 问题 | 结论 | 落点 |
|---|---|---|---|
| 1 | `read` 是否改成返回 String | **不改**。`read(Array<Byte>): Int64` 是流契约；字符串能力走新增的 `readString` 系列 | 3.2 |
| 2 | `chatset` 是否笔误 | **是笔误**，全部改为 `charset` | 3.3 |
| 3 | 是否要长度前缀方法 | **不提供**；给出"占位 → 回填"范式与三条陷阱 | 3.12 |
| 4 | 解码失败宽容还是严格 | **两者都提供**：`decode` 宽容、`decodeStrict` 严格 | 3.6 |
| 5 | `SyncByteBuffer` 是否补齐 | **补齐**，与 `ByteBuffer` 同能力 | 2.5 |
| 6 | charset4cj 是否锁版本 | **用最新发布版**，不锁死；升级跑冒烟用例 | 4 |
| 7 | 孤立 `\r` 是否算换行 | **不算**，不提供 `crAsNewline`；归一化交给上层 | 3.8 |
| 8 | `readRune` 要不要 U+FFFD 模式 | **要**，`InvalidByteMode.Replace`；默认仍 `Strict` | 3.7 |
| 9 | `readln` 对 UTF-16/32 | **严格按指定字符集解码，不合法就抛异常**；不提供 `readlnDecoded` | 3.8 |
| 10 | `writeln` 是否支持 CRLF | **固定 LF**，不提供 `lineEnd` | 3.9 |
| 11 | `readString(count)` 计数单位 | **码点**，与 `String.runes()` 一致；不做字素簇 | 3.3.2 |
| 12 | `std.io.ByteBuffer` 的 position | **实测：写后停在 0（读游标）**；`bytes()` 是未读部分；写永远追加 | 3.11 |

### 10.2 已定（本轮补充）

| # | 问题 | 结论 | 落点 |
|---|---|---|---|
| 13 | `Replace` 的 U+FFFD 是否计入 `readStringEx` 字符数 | **计入**；字节量另取 `readOffset` 差值 | 3.7 |
| 14 | `readString` / `readStringBytes` 是否也给 `onInvalid` | **给**；默认值按"有无量的契约"分档 | 3.3 |
| 15 | `batch` 内是否要求原子 | **不要求**：只保证互斥，不回滚 | 2.5 |

### 10.3 仍需确认

1. **编码方向（`String` → 字节）的解码策略还没定。** `readRune` 有 `onInvalid`，但 `write(s)` 遇到
   目标字符集表示不了的字符（例如 GBK 写 emoji）怎么办？当前默认是抛异常，但要不要也提供
   `InvalidCharMode { | Throw | Replace }`（替换成 `?` 或 U+FFFD 的编码）？这是与读方向对称的问题，
   建议在 P3 之前定。
2. **`readStringEx` 的第二个返回值是否改成"消费字节数"。** 当前定为字符数（与 `count` 参数同单位）。
   若将来出现"按字节偏移对齐"的需求（XML 的 byte offset、ZIP 的 local header 偏移），
   字符数不够用，得再取 `readOffset` 差值——是否需要直接返回三元组 `(String, 字符数, 字节数)`？
