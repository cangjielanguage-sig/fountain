# f_http 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_http`（模块共 20 个源文件；本部分 5 个，均为 `.cj`）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce643a`，工作区干净）；快照模式无 diff，全部缺陷记「存量」
- **审查重点**：文本媒体类型 / 异常 / RFC 时间工具的正确性，死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1（部分报告，与第 1 部分合并为 `f_http_review_20261128.md`）

## 发现

### [严重][存量] `parseRfc1123` 对任何合法 RFC 1123 日期都抛异常

- **位置**：`src/rfc.cj:38-46`（时区切分与构造），失败在 `39`、`43`、`45`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§14.1（README 承诺但实现不可用）
- **证据**：静态确定 —— 三个失败点都能只靠代码 + 官方文档判定：
  1. 第 39 行 `date[zoneIdx + 1..zoneIdx + 3]` 只取 **2 个字符**：`"... GMT"` 得到 `"GM"`，`"... +0800"` 得到 `"+0"`，`"... -0500"` 得到 `"-0"`；
  2. 第 40 行 `zoneId == "GMT"` 因此永远不成立（死分支）；落到第 45 行 `Int64.parse("GM")`，按 std `parsable.cj:733-741` 的 `@throws IllegalArgumentException` 直接抛；
  3. 第 43/45 行 `TimeZone("", …)` 传空 id，std `timezone.cj:190-192` 与 `time_package_classes.md:390-395` 明确「id 为空字符串抛 `IllegalArgumentException`」，故 `"+0800"` 也必抛。
- **描述**：`parseRfc1123` 没有任何一条成功路径：带 `GMT` 的日期抛 `IllegalArgumentException`，带数字偏移的日期要么被截成 `+0`/`-0`（即使不抛也会丢 8 小时/5 小时），要么在 `TimeZone("")` 处抛。即使只把切片改成 5 字符也不够：正分支 `zoneId[1..]` 会变成 `"0800"`、`Int64.parse` 得 800 小时，负分支得 `-500` 小时，都会因 `TimeZone` 偏移超出 `(-25h, 26h)` 再抛一次；必须拆出 `HH`/`MM` 两段分别换算。该函数是 README `README.md:181` 明示的时间格式能力，仓内零调用、零测试，缺陷因此长期未暴露。
- **建议**：用 `date.lastIndexOf(" ")` 之后取**剩余整段** `date[zoneIdx + 1..]`，再 `toAsciiUpper()` 后 `match`：`"GMT"` → `TimeZone.UTC`；`[+-]HHMM` → 解析 `HH`/`MM` 并 `Duration.hour * h + Duration.minute * m`（负号整体取负）；其余抛带原文的 `IllegalArgumentException`。`id` 用 `"GMT+08:00"` 这类非空串。补 `rfc1123(t)` → `parseRfc1123` 往返用例（含 GMT、+0800、-0530）。

### [一般][存量] `rfc1123` 输出不符合 RFC 1123 / IMF-fixdate，标准解析器会拒绝

- **位置**：`src/rfc.cj:20-34`（偏移取整 `20`、零偏移分支 `21-22`、拼接 `34`）
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）、§13 同类（头值格式是协议契约）
- **证据**：静态确定 —— 第 34 行直接用 `t.dayOfMonth` / `t.hour` / `t.minute` / `t.second` 的整数值，未补前导零；第 20 行 `zoneOffset.toSeconds() / 3600` 为整数除法；第 21-22 行零偏移时用 `t.zoneId` 而不是 `"GMT"`。
- **描述**：RFC 1123/7231 的 IMF-fixdate 要求 `Sun, 06 Nov 1994 08:49:37 GMT`。当前实现对 `2022-11-06 09:05:08 +08:00` 输出 `Sun, 6 Nov 2022 9:5:8 +0800`，日期/时分秒均非法；`TimeZone.UTC` 的 `zoneId` 是 `"UTC"`，输出 `UTC` 而非 `GMT`（RFC 7231 §7.1.1.1 要求 `GMT`）；`+05:30` / `-03:30` 这类半小时时区被截成 `+0500` / `-0300`，偏移错 30 分钟。该函数被 `ContentDisposition.toString()` 用于 `creation-date` / `modification-date` / `read-date`（`src/ContentDisposition.cj:220-233`），这些头值会带上非法日期。
- **建议**：日/时/分/秒统一 `padLeft(2, '0')`（或用 `DateTime.toString` 的格式化能力），零偏移固定输出 `GMT`，偏移按 `toSeconds()` 拆成 `h = s / 3600`、`m = (s % 3600) / 60` 两段输出；返回值补显式 `: String` 返回类型。补 `2022-11-06T09:05:08+08:00`、`+05:30`、UTC 三个用例。

### [一般][存量] `TextMediaType.doMake` 只识别一种精确写法，合法参数被抛异常或静默降级为 UTF-8

- **位置**：`src/TextMediaType.cj:25-46`（`26` 标签字面量、`31` 类型名比较、`32` charset 取值、`41-42` 前缀回退）
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §11（边界 / 错误处理 / 静默失效）、§10 正确性
- **证据**：静态确定 —— ① 第 26 行 `tag = "; charset="` 硬编码「一个分号 + 一个空格 + 小写参数名」；② 第 29 行 `cs = mediaType[x + tag.size..]` 把标签之后**整段**当 charset；③ 第 31 行 `mt == this.mediaType` 区分大小写；④ 第 41-42 行匹配不到标签时 `startsWith` 成立就返回 `this`（UTF-8 单例）。
- **描述**：以下都是 RFC 2045/7231 允许的写法，但行为错误：
  1. `text/plain;charset=GBK`（无空格）匹配不到标签，`startsWith("text/plain")` 成立 → 返回 UTF-8 单例，GBK 正文被按 UTF-8 解码，**静默乱码**（若此路径承载非 UTF-8 请求体，后果按数据错误算）；
  2. `text/plain; charset="UTF-8"`（带引号）或 `text/plain; charset=UTF-8; format=flowed`（RFC 3676 的合法 Content-Type）→ `cs` 变成 `"UTF-8"` / `UTF-8; format=flowed`，`Charsets.forName` 返回 `None` → 抛 `MediaTypeException`，合法请求变 500；
  3. `Text/Plain; charset=UTF-8` → 第 31 行不相等 → 抛 `MediaTypeException`（类型名按 RFC 应大小写不敏感）；
  4. `PlainTextMediaType.instance.make("text/plainx")` 会被前缀判断接受为 `text/plain`（无分隔符校验）。
  另外第 32 行局部变量 `charset` 遮蔽了同名成员 `this.charset`，阅读时容易误判。
- **建议**：按 `;` 切分后逐段 `trimAscii()`，参数名 `toAsciiLower()` 比较，只取 `charset` 参数；值去掉成对双引号、只取到下一个 `;`；`mt` 与 `this.mediaType` 都用 `toAsciiLower()` 比较；参数一律无法识别时按「无参数」处理返回 `this`（不要把整段当 charset）；前缀判断补 `mediaType.size == this.mediaType.size || mediaType[this.mediaType.size] == b';'`。局部变量改名 `csOpt`。

### [轻微][存量] `TextMediaType.hashCode` 的 charset 分支不可达，哈希始终不含 charset

- **位置**：`src/TextMediaType.cj:56-61`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §1（恒假分支）、§12.1（惰性写可见性）
- **证据**：静态确定 —— 基类构造器 `src/MediaType.cj:40-42` 已执行 `hash = mediaType.hashCode()`；`TextMediaType` 没有重置 `hash`，所以 `if (hash == 0)` 对当前子类（`"text/plain"` / `"application/json"`）恒为假，`HashBuilder().append(mediaType).append(charset)` 永不执行。
- **描述**：`hashCode` 实际只等于 `mediaType.hashCode()`，与注释/写法表达的「含 charset」不符；`charset=GBK` 与 `charset=UTF-8` 的两个实例哈希相同（契约允许，但与实现意图相反，且 `==` 第 52 行还用哈希做快路径）。当前因为分支不可达才没有竞态；一旦让它可达，`hash` 就是共享单例上的无同步惰性写（`Int64` 非原子），多线程调用 `hashCode` 会出现数据竞争。
- **建议**：在构造期一次性算好 `hash = HashBuilder().append(mediaType).append(charset).build()`（或直接删掉缓存与 `if`），不要保留运行期惰性写；若坚持惰性初始化，改用 `AtomicInt64` 或双检锁并声明可见性。

### [轻微][存量] `PlainTextMediaType` 与 `JsonMediaType` 的 `toData(Array<Byte>)` 逐行相同

- **位置**：`src/TextMediaType.cj:75-77` 与 `src/TextMediaType.cj:117-119`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— 两处函数体完全一致：`toData(charset.newDecoder().decode(data))`，输入 `Array<Byte>`、输出 `Data`、副作用均为按 charset 解码后走各自 `toData(String)`。
- **描述**：这是同一语义的两份实现，差异只在所属类；`JsonMediaType.toData(String)` 解析 JSON、`PlainTextMediaType.toData(String)` 包成 `DataString`，因此把该函数上提到 `TextMediaType` 作为唯一实现不会改变行为。当前分散写法让「字节 → charset 解码」这一步有两处维护点。
- **建议**：在 `TextMediaType` 中实现一次 `public func toData(data: Array<Byte>): Data { toData(charset.newDecoder().decode(data)) }`，删除两个子类的同名覆盖；补两个子类的 `fromData → toData` 往返用例（UTF-8 与 GBK）。

### [轻微][存量] 异常文件名与类名不符，`MultipartException` 的父类归属待确认

- **位置**：`src/exception/MultipartFormDataException.cj:18`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §10 可读性 / 设计合理性；§11（契约待确认）
- **证据**：静态确定 —— 文件名为 `MultipartFormDataException.cj`，内部定义的是 `public class MultipartException`；README `README.md:267` 与 `README_en.md:269` 记录的是 `MultipartException`，说明类名才是对外契约，文件名是残留。`MultipartException <: MediaTypeException`，而它的抛出点都是 multipart 报文结构错误（`MultipartFormDataParser.cj:107/111/217`），不是媒体类型错误。
- **描述**：文件名会误导维护者按 `MultipartFormDataException` 去搜/引用；继承 `MediaTypeException` 后，只想处理 `Content-Type` 解析失败的调用方会连 multipart 分帧错误一起捕获，「媒体类型异常」这一层语义被放大。是否为有意设计（统一归到媒体类型异常族）缺规格说明。
- **建议**：把文件重命名为 `MultipartException.cj`（或在文件头注明类名为何与文件名不同）；在类注释里写明它继承 `MediaTypeException` 的理由，若只是复用基类构造器，改为直接继承 `BaseException` 更贴合语义。

### [轻微][存量] `TextMediaType.cj` 与两个异常文件零 `import`，隐式依赖同包其它文件的 `internal import`

- **位置**：`src/TextMediaType.cj:16-18`、`src/exception/HttpRequestHeaderException.cj:16-18`、`src/exception/MultipartFormDataException.cj:16-18`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §10 可读性 / 可维护性
- **证据**：静态确定 —— 这 3 个文件在 `package` 之后直接进入声明，没有任何 `import`；它们用到的 `Charset`/`Charsets`/`Data`/`JsonValue`/`InputStream`/`OutputStream` 来自 `src/MediaType.cj:18-36` 的 `internal import`（按官方文档 `package/import.md:293-296`，`internal import` 在当前包及子包可见），`BaseException` 来自 `src/exception/MediaTypeException.cj:18` 的 `internal import`。
- **描述**：能编译，但文件不自包含：`MediaType.cj` 或 `MediaTypeException.cj` 一旦清理某个「看起来只在本文件用」的 import，这些文件会突然编译失败，且报错位置与改动位置相隔一个文件，定位成本高。
- **建议**：每个文件按自身实际使用补 `internal import`（`internal` 修饰以维持包内可见），不要依赖邻文件的 import 传递。

## 优化可行性方案

> 本部分没有带基线数据的优化项，以下两条均为结构上可证的对象数/中转次数改进，收益幅度未测，标 `无基线（待验证）`，不进 `tasks`。

### [堆内存] O1：`make()` 在 charset 与当前实例相同时复用 `this`

- **现状**：`MediaTypes.doTryParse` 对带参数的 Content-Type 走 `?.make(mediaType)`（`src/MediaTypes.cj:80`）。`doMake`（`src/TextMediaType.cj:25-46`）即使 charset 就是默认 UTF-8，也会切出 `cs`、`mt` 两个 `String` 并 `creator(c)` 新建一个媒体类型实例；`application/json; charset=UTF-8`、`text/plain; charset=UTF-8` 是常见请求头，等于每请求 2 个短字符串 + 1 个对象。
- **方案**：在 `doMake` 的 `Some(c)` 分支加 `if (c == this.charset) { return this }`（`Charset.==` 按名字比较，见 charset4cj `encoding/charset.cj:36-38`，`forName` 返回单例，UTF-8 一定命中），再 `creator(c)`。
- **预期**：常见 `; charset=UTF-8` 请求少 2 个短字符串 + 1 个实例分配；对象数可数，耗时收益需实测。
- **代价**：无（`TextMediaType` 实例不可变，返回单例安全；`make` 的返回值只用于读取媒体类型，调用方不依赖「每次拿到新实例」）
- **验证**：10k 次 `MediaTypes.parse("application/json; charset=UTF-8")`，改前/改后 `cjprof heap` 分配量与 `getAllocatedHeapSize()` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] O2：`JsonMediaType.fromData` 的 UTF-8 路径避免「JsonValue → String → bytes」中转，并复用 encoder/decoder

- **现状**：`src/TextMediaType.cj:93-99` 的 UTF-8 分支是 `data2json(data).toString().unsafeBytes()`：先把 `Data` 转成完整 `JsonValue` 树，再整体序列化成 `String` 取字节；同一份数据在 `fromData(data, output)`（`100-106`）里却是 `write(output)` 流式输出，两条实现内存形态不同。`fromData`/`toData` 每次还调用 `charset.newEncoder()` / `newDecoder()`，charset4cj 的实现每次都 `new`（如 `unicode/utf8.cj:35-37`）。
- **方案**：`fromData(Data): Array<Byte>` 改为用 `ByteBuffer` + `JsonValue.write(writer)`/`toJson(writer)` 直接写字节，与 `fromData(Data, OutputStream)` 共用同一条流式实现；`Encoder`/`Decoder` 若能复用则在实例上缓存（需先确认 charset4cj 的 Encoder 是否无状态）。
- **预期**：UTF-8 序列化少一份与 JSON 等长的中间 `String`（峰值从约 Data + Json 树 + String 降到 Data + Json 树 + 字节缓冲），每次序列化少 1 个 Encoder 分配；具体降幅需实测。
- **代价**：需要引入 `ByteBuffer`/`JsonWriter` 依赖，代码路径合并后要补 `fromData` 与 `fromData(output)` 输出一致的用例。
- **验证**：10k 次 100 KB `DataObject` 的 `fromData`，`cjprof record` 的 self time 与分配量、峰值 RSS 对照；`-O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 带 charset 参数的 Content-Type 走 `make()` 的切分与实例分配，在媒体类型解析自耗时中占比明显 | `src/TextMediaType.cj:25-46`、`src/MediaTypes.cj:61-84` | `doMake` self time 占比、每请求分配字节数 | 10k 次 `MediaTypes.parse("application/json; charset=UTF-8")`，`cjprof record` + `cjprof heap`，`-O2` |
| 2 | `JsonMediaType.fromData` 的 `toString()` 中转在响应体较大时是 CPU/内存热点 | `src/TextMediaType.cj:93-99` | 序列化耗时占比、峰值内存放大倍数 | 100 KB / 1 MB / 10 MB `DataObject` 各 1k 次 `fromData`，分段计时 + `getAllocatedHeapSize()` 峰值 |
| 3 | 每次调用 `newEncoder()/newDecoder()` 的分配在 multipart/文本响应路径上可忽略 | `src/TextMediaType.cj:73,76,108,118` | 每请求 Encoder 分配次数与占比 | `cjprof heap` 采样一次含 100 个文本 part 的请求 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/TextMediaType.cj` | .cj | ✅ | 见「一般：doMake」「轻微：hashCode / toData 重复 / 零 import」，以及两条优化方案 |
| 2 | `src/exception/HttpRequestHeaderException.cj` | .cj | ✅ | 4 个构造器与 `BaseException` 一致；仓内无抛出点（公开类型，不判死代码），见「轻微：零 import」 |
| 3 | `src/exception/MediaTypeException.cj` | .cj | ✅ | 4 个构造器；`internal import` 被同包其它文件隐式复用（见「轻微：零 import」） |
| 4 | `src/exception/MultipartFormDataException.cj` | .cj | ✅ | 文件名/类名不符，见「轻微：异常命名」 |
| 5 | `src/rfc.cj` | .cj | ✅ | `parseRfc1123` 必抛（严重）、`rfc1123` 格式非法（一般） |

合计：`.cj` 5 个 / `.md` 0 个 / 共 5 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：`parseRfc1123`、`rfc1123`、`doMake`；语言特性：`hashCode` 惰性缓存（`Int64` 非原子）、`as` 返回 `Option`（已核对 `typecast.md:54`，`data2json` 用法成立）；设计：异常层级；可读性：文件名与零 import。本部分无外部输入拼接、无凭据、无 SQL，安全性无独立条目 |
| §1 死代码 | 1 | 逐个核对：`doMake`（`public abstract` 非 sealed 类的 `protected` 成员，豁免且被两个子类调用）；`data2json`（`95/97/102` 三处调用）；`instance` 被 `src/MediaTypes.cj:29/32` 引用，`make`/`fromData`/`toData` 是接口实现或父类覆盖且对外可达，均不判；`rfc1123` 被 `ContentDisposition.cj:222/227/232` 调用，`parseRfc1123` 对外可达但仓内零引用（只记信息）；`HttpRequestHeaderException` 仓内无抛出点但对外可达（只记信息）。命中 1 条：`TextMediaType.hashCode` 的 `if (hash == 0)` 恒假 |
| §2 重复逻辑 | 1 | 已把 5 个文件的函数体两两比对，并搜了相同错误文案与字面量：命中 `toData(Array<Byte>)` 两处逐行相同；3 个异常类的 4 构造器属语言惯例（只差类名与父类，无行为漂移），不判；`fromData(Data)` 与 `fromData(JsonValue)` 输入类型不同，不判 |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/空函数体/静默 `catch`；异常类的 `init() {}` 是构造器形态而非契约方法；`data2json` 的尾表达式有实际返回值 |
| §4 栈溢出 | 0 | 5 个文件无递归、无间接递归、无自引用结构遍历；`rfc.cj` 是直线解析 |
| §5 OOM | 0 | 本部分无「按不可信长度预分配 / 无界容器 / 全量读流」；`JsonMediaType.fromData` 额外物化 JsonValue 树与等长 String 的放大计入优化方案，请求体本身无上限属模块级问题（见第 1 部分 #5） |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据；`doMake`、`fromData` 两个疑似热点已进「待验证假设」，未当缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 0 | `indexOf`/`startsWith`/切片均 O(n)，输入是几十字节的 Content-Type；`parseRfc1123` 的多次 `indexOf` 也是 O(n) 单趟；无嵌套循环 |
| §7 降堆内存方案 | 1 | O1 `make()` 复用实例；标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | O2 `JsonMediaType` UTF-8 序列化去中转 + encoder 复用；标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `doMake` 只产出 1-2 个短字符串与 1 个小对象，量级不足以用峰值内存证明收益；且返回值会逃逸出函数，不满足 local 约束 |
| §11 现有代码的 BUG（存量） | 3 | `parseRfc1123`（时区切分/空 TimeZone）、`rfc1123`（未补零/零偏移/GMT）、`doMake`（参数解析与静默降级）；`hashCode` 计入 §1/§12，其余为可维护性 |
| §12 并发安全与锁粒度 | 1 | `PlainTextMediaType.instance`/`JsonMediaType.instance` 是跨线程共享单例；`hash` 是可变字段，当前唯一写入点在构造期（发布前），`if (hash == 0)` 分支不可达故无实际竞态；若修正该分支使其可达，则成为无同步惰性写（见「轻微：hashCode」的建议）。`Charsets.forName` 的静态缓存只读，安全 |
| §14 功能完备性与 README 覆盖 | 1 | `parseRfc1123` 被 `README.md:181` 列为时间格式能力但不可用（与严重项合并）；本部分其余公开符号（`PlainTextMediaType`/`JsonMediaType`/`TextMediaType.charset`/`HttpRequestHeaderException`/`MultipartException`）均在 README `README.md:178,267,273,278,279` 登记，无遗漏 |
| 文件覆盖（§13 等） | 5/5 | 5 个文件全部读完，无跳过。**§13 不适用**：本部分文件清单只含 5 个 `.cj`，README/README_en/doc 未在范围；第 1 部分注明 `.md` 由第 2 部分覆盖，本轮第 2 部分未获得 `.md` 文件，存在覆盖缺口，建议主 Agent 补一轮 `.md` 审查（已抽查 `README.md:178-181,263-280`，未发现与本部分符号冲突的表述） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分是 f_http 的文本媒体类型与 RFC 时间工具，问题集中在「对外 API 实际不可用」而非性能：

- **阻塞项（严重）**：`parseRfc1123` 三条路径全部抛异常，任何标准 HTTP 日期都解析不了；它与 `rfc1123` 是一对无测试、无仓内调用的公开工具，缺陷长期无人发现。
- **排期项（一般）**：`rfc1123` 缺前导零、零偏移输出 `UTC`、半小时时区截断，生成的 `Content-Disposition` 日期头不合规；`TextMediaType.doMake` 只认 `"; charset="` 一种写法，合法 Content-Type 会抛 500，无空格写法会静默按 UTF-8 解码。
- **可维护性**：`hashCode` 的 charset 分支恒假（哈希不含 charset）、两个子类的 `toData(Array<Byte>)` 重复、异常文件名与类名不符、三个文件依赖邻文件的 `internal import`。异常类本身实现完整、构造器与 `BaseException` 对齐，没有空实现。
- **建议优先级**：`parseRfc1123` 时区解析 → `rfc1123` 补零与 GMT → `doMake` 参数解析 → 消重与命名。

存量缺陷共 7 条（严重 1 / 一般 2 / 轻微 4），是否纳入修复待用户决定。
