# f_http 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_http`（本部分 7 个源文件：媒体类型实现 / 异常定义 / RFC 1123 时间格式）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；全部结论按「存量」记）
- **审查重点**：HTTP 解析与响应正确性（媒体类型参数解析、分块/流式入口）、边界与注入、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分报告；模块报告 = `parts/f_http.part1.md` + 本文件，本文件不写 `docs/review/`）
- **说明**：本部分文件清单全部为 `.cj`，无 `.md`；README / `doc/**` 由第 1/2 部分覆盖。

## 发现

> 下文按出现顺序编号 #1–#14，文件覆盖表与覆盖自检表引用同一编号。

### [严重][存量] `parseRfc1123` 时区只切 2 个字符，任何合法 RFC 1123 日期都抛异常

- **位置**：`f_http/src/rfc.cj:37-46`（`parseRfc1123`）；`f_http/src/rfc.cj:39`（`date[zoneIdx + 1..zoneIdx + 3]`）；`f_http/src/rfc.cj:40-46`（三条时区分支）；消费方 `f_http/src/ContentDisposition.cj:326-343`
- **来源**：存量（工作区快照；`git blame` 4be871f2f）
- **判据**：review-checklist §11（边界 / 错误处理 / 契约与实现不符）
- **证据**：静态确定
  - `zoneIdx` 是最后一个空格的下标，时区串从 `zoneIdx + 1` 开始；`[zoneIdx + 1..zoneIdx + 3]` 固定截 2 个字符。
  - `"... GMT"` → `zoneId == "GM"`，`:40` 的比较不成立，落到 `:45` `Int64.parse("GM")` → IllegalArgumentException。
  - `"... +0800"` → `zoneId == "+0"`，`:43` `zoneId[1..]` 为 `"0"` → `TimeZone("", Duration.Zero)`；`TimeZone.init(String, Duration)` 文档写明「`id` 为空字符串抛 IllegalArgumentException」（`std/time/time_package_api/time_package_classes.md:377-395`）。
  - `"... -0800"` → `zoneId == "-0"` → 同一空 id 路径，同样抛异常。
  - 三条分支全覆盖，**没有一个合法输入能正常返回**；即使不抛异常，`+0800` 也只剩 "0"，时区偏移恒为 0。
- **描述**：`ContentDisposition.parse` 对 `creation-date` / `modification-date` / `read-date` 全部 `catch (_) { // ignore }`（`ContentDisposition.cj:326-343`），异常被吞掉后这三个参数**永远读不出来**（静默数据丢失，且无日志）。同时公开 API `setCreationDate(String)` / `setModificationDate(String)` / `setReadDate(String)`（`ContentDisposition.cj:133-141`）对合法输入直接抛异常。
- **建议**：`let zoneId = date[zoneIdx + 1..]` 取到串尾，再按 `GMT` / `UTC` / `Z` / `±HHMM` 分支；`±HHMM` 用 `hh * 60 + mm` 换算分钟偏移，`TimeZone` 的 id 传非空串（如 `"GMT+08:00"`）；`GMT` 分支保留但必须真的可达。`catch { ignore }` 至少改成 warn 日志，或把三个日期参数的失败分开处理。

### [严重][存量] `rfc1123` 生成的日期串不符合 RFC 1123：时间不补零、0 偏移输出 `zoneId`、分钟级偏移被截断

- **位置**：`f_http/src/rfc.cj:18-35`（`rfc1123`）；`:20`（`t.zoneOffset.toSeconds() / 3600`）；`:21-33`（zoneId 分支）；`:34`（输出模板）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（语义与注释 / 规格不符）、§13（`README.md:181` 把 `rfc1123` 列为对外「时间格式」能力）
- **证据**：静态确定
  - `:34` 直接拼 `t.hour` / `t.minute` / `t.second` / `t.dayOfMonth`，个位数不补零（`9:5:3`）；RFC 1123 的 `date1` / `time-of-day` 要求 `2DIGIT`。
  - `offset == 0` 时用 `t.zoneId`；`TimeZone.UTC.id` 为 `"UTC"`（`std/time` 文档示例 `timeZoneID: UTC`），HTTP-date 规定的是 `"GMT"`。
  - `toSeconds() / 3600` 整除截断：`+05:30`（印度）→ 5 → `+0500`，`+05:45`（尼泊尔）→ `+0500`，`-03:30`（纽芬兰）→ `-0300`，时间整体偏移 30~45 分钟。
- **描述**：`ContentDisposition.toString()`（`ContentDisposition.cj:222-232`）把该串写进 `creation-date` / `modification-date` / `read-date` 头部；对端按 RFC 解析会失败或得到错误时刻。`setCreationDate(DateTime)` 等 setter 把错误值原样带到线上。
- **建议**：按分钟计算 `totalMinutes = t.zoneOffset.toMinutes()`，输出 `±HHMM`；`hh` / `mm` / `ss` / `day` 用两位补零（`padStart` 或格式化 API）；0 偏移统一输出 `GMT`。

### [一般][存量] `TextMediaType.doMake` 只认 `"; charset="` 字面量：合法参数被拒，前缀匹配又过宽

- **位置**：`f_http/src/TextMediaType.cj:25-46`（`:27` `indexOf('; charset=')`、`:29` 取到串尾、`:41-42` 前缀命中即返回 `this`）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（边界 / 契约）、§14（`MediaTypes.parse` 是公开能力）
- **证据**：静态确定
  - 合法的 `text/plain;charset=utf-8`（无空格）、`text/plain; charset="utf-8"`（带引号）、`text/plain; charset=utf-8; format=flowed`（尾随参数）、`Text/Plain`（大小写）都进不了「正常解析」路径：
    - 带引号 / 尾随参数命中 `:27`，但 `:29` 把 `"utf-8"` / `utf-8; format=flowed` 整段当字符集名；`Charsets.forName` 只是 label 查表（charset4cj `src/charset/charsets.cj:161-163`，注册时只放 name/label 的原样 + 全大写 + 全小写），不剥引号、不切 `;` → 返回 None → `:36` 抛 `MediaTypeException`。
    - 无空格时 `:27` 未命中 → `:41` `startsWith` 成立 → 返回 `this`，**charset 被静默丢弃**，后续按 UTF-8 解码。
  - 反向误接受：`make("text/plainfoo")` 也因 `startsWith` 返回 `this`，即通过公开 `MediaType.make` 能拿到「非法类型」的实例。
- **描述**：`f_mvc` 的 `@RequestBody` 走 `MediaTypes.tryParse`（`f_mvc/src/ControllerFuncParam.cj:174,188-196`），带参数的合法头会抛异常而不是返回 `None`，最终变成 500；无空格写法则悄悄按 UTF-8 处理非 UTF-8 报文。
- **建议**：抽一个 `parseParameters(mediaType)`：按 `;` 切分、`trimAscii`、`split('=')`、去成对引号、参数名 `toAsciiLower`；类型只做 `==` 比较（不 `startsWith`）；解析失败返回 `None` 而不是 throw，让 `tryParse` 语义成立。

### [一般][存量] `MultipartMediaType.make` 的 boundary 解析只认 `"; boundary="`，引号 / 无空格 / 尾随参数 / 大小写全部失败

- **位置**：`f_http/src/MultipartMediaType.cj:47-61`（`:49` `startsWith`、`:50` `indexOf`、`:52` 取到串尾、`:56`/`:59` 抛错）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（边界）、§14（分块/流式解析入口）
- **证据**：静态确定
  - RFC 2046 允许 `boundary="abc"`、`;boundary=abc`、`Boundary=abc`、`; boundary=abc; charset=x`。
  - 前三种 `indexOf("; boundary=")` 返回 None → 走到 `:53` 判断不等 → `:56` 抛 `MediaTypeException("... is illegal")`。
  - 第四种命中，但 `:52` 把值取到串尾，`boundary == "abc; charset=x"`；`MultipartFormDataParser` 的分隔符（`MultipartFormDataParser.cj:80`）变成 `\r\n--abc; charset=x`，与报文里的 `--abc` 不匹配。
  - `boundary="abc"` 命中后 boundary 带引号，分隔符变成 `\r\n--"abc"`，同样匹配不到，解析抛异常。
- **描述**：`@RequestBody` 对 multipart 头（`ControllerFuncParam.cj:174`）以及任何 `MediaTypes.parse` 调用都受影响：合法报文要么被拒（500，而不是 415），要么 boundary 取错导致 `MultipartException`，传输编码/分块解析入口不可用。
- **建议**：与 charset 共用参数解析（切 `;`、去引号、`trimAscii`、参数名大小写不敏感）；取 boundary 值到下一个 `;` 为止；boundary 为空或含 `\r\n`/非 token 字符时抛带具体原因的异常。

### [一般][存量] 空 boundary 不被拒绝：`MultipartMediaType.formData.toData(input)` 拿 `"\r\n--"` 当分隔符

- **位置**：`f_http/src/MultipartMediaType.cj:63-71`（`toData(input: InputStream)`）；`f_http/src/MultipartMediaType.cj:53-54`（无 boundary 时返回 `this`）；`f_http/src/MultipartFormDataParser.cj:80`（`'\r\n--${boundary}'`）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（空值 / 边界）、§14（公开入口未校验）
- **证据**：静态确定 —— `MediaTypes.parse("multipart/form-data")` 返回的是 `formData` 单例（boundary 为 `""`），直接 `toData(input)` 会用 `\r\n--` 作为 section 分隔符；报文正文里任何 `--`（JSON、base64、Markdown 分隔线）都可能被当作边界，随后 `read(crlf)` 只可能读到 `\r\n` 之外的两字节，落进 `MultipartFormDataParser.cj:217` 的 `case _ => throw MultipartException()`，或切出内容错误的 part。
- **描述**：错误以无消息的 `MultipartException()` 呈现，排查困难；这也是「分块解析器对空 boundary 无前置校验」在公开 API 上的入口（parser 本体的问题已在第 1/2 部分记录）。
- **建议**：`boundary.isEmpty()` 时在 `toData(input)` 入口抛 `MediaTypeException('multipart media type requires boundary')`；`toString()` 同时不要输出空的 `boundary=`（见后文轻微条目）。

### [一般][存量] `MultipartMedia` 的 `FromData` / `DataFields` 实现全是 `throw 'Not Supported'`，`try*` 与 `parse` 契约不成立

- **位置**：`f_http/src/MultipartMedia.cj:32-56`（四个转换入口）；`:44-46`（`toDataFields` 对 `?MediaType` 直接 `getOrThrow`）；`:26-31`（`toData` 的 None 分支）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §3（公开契约的空实现 / 占位）、§14（`README.md:267` 列为公开类型，但能力未接线）
- **证据**：静态确定
  - `tryFromData`（`:41-43`）与 `tryParse`（`:54-56`）直接抛 `MediaTypeException`；`parse`（`:51-53`）= `tryParse(...).getOrThrow()`，因此 `getOrThrow` 永远执行不到。
  - 同项目其它 `tryFromData` 失败返回 `None<T>`（如 `f_data/src/base/DataBool.cj:60-70`），这里的 throw 破坏「try 不抛」的约定。
  - `toDataFields<T>()`（`:44-46`）在 `mediaType == None` 时 `?.` 得到 `None` 再 `getOrThrow`，抛的是空 `Option` 异常，不是 `MediaTypeException`。
  - 全仓（排除 `.worktrees`）`MultipartMedia(` 只有定义处，没有任何构造/解析路径；`README.md:267` 却把它列为公开类型。嵌套 `multipart/mixed` 的落地类因此不可用（与第 1/2 部分「嵌套 multipart 未实现」同源）。
- **描述**：`convert<MultipartMedia>(data)`、`MultipartMedia.parse(...)`、`toDataFields<T>()` 全部异常，`DataFields<MultipartMedia>` 这个对外契约没有任何可用行为。
- **建议**：实现 `tryFromData`（不支持时返回 `None`）与 `tryParse`，或把该类从 `Data` + `DataFields` 契约摘出并标注废弃、同步 README；`toDataFields` 的 None 分支改成显式 `MediaTypeException('no media type for multipart part')`。

### [轻微][存量] `MultipartMedia.toString()` / `toData()` 把任意 part 字节按文本解码，二进制 part 不可逆损坏

- **位置**：`f_http/src/MultipartMedia.cj:47-50`（`toString`）；`:26-31`（`toData` 的 `case _` 分支）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（数据错误 / 语义与命名不符）、§7（多一份字符串表示）
- **证据**：静态确定 —— `charset.newDecoder().decode(bytes)` 对 image/png、zip 等字节产生替换字符；`toData()` 再走 `String.toData()`（f_data `DataString`，`f_data/src/base/DataString.cj:43-46`，只包字符串、没有字节表示），原始字节永久丢失。
- **描述**：类名为 `MultipartMedia`（对应任意 media type），但只有文本语义；`mediaType` 为 `None`（未注册类型，例如 `application/octet-stream`）或二进制类型时结果不可用。
- **建议**：`mediaType` 为 None 时 `toData()` 返回字节表示（`ByteBuffer(bytes).toData()`，见 `f_data/src/base/DataInputStream.cj:81-84`），或直接抛「未知媒体类型」；`toString()` 限定文本类型，其余返回长度/类型摘要。

### [轻微][存量] 恒假分支与不可达调用：`zoneId == "GMT"`、`MultipartMedia.parse` 的 `getOrThrow`

- **位置**：`f_http/src/rfc.cj:40-41`；`f_http/src/MultipartMedia.cj:51-53`
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `zoneId` 被切成 2 个字符，永远不等于 `"GMT"`（分支体 `TimeZone(zoneId, Duration.Zero)` 不可达）；`MultipartMedia.tryParse` 恒 throw，`parse` 里的 `getOrThrow` 永不执行。
- **描述**：死分支掩盖了真正的时区 bug（见第一条），读代码时容易误以为 `GMT` 可用。
- **建议**：随上述两条修复一并消除；`parse` 改成 `tryParse(...) ?? throw MediaTypeException(...)` 这类形态，避免永远到不了的调用。

### [轻微][存量] 三个异常类逐字复制同一组 4 个构造器（12 个空壳构造器）

- **位置**：`f_http/src/exception/HttpRequestHeaderException.cj:19-29`；`f_http/src/exception/MediaTypeException.cj:21-31`；`f_http/src/exception/MultipartFormDataException.cj:19-29`
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 三份 `init()` / `init(String)` / `init(caused)` / `init(String, caused)` 完全相同，仅类名不同。
- **描述**：`MultipartException` 实际只用 `init()` 与 `init(String)`（`MultipartFormDataParser.cj:107/111/217`）；`MediaTypeException` 是 `public open`、另两个是 `public class`，开放度也不一致。
- **建议**：只保留被使用的构造器；或抽一个 `HttpException` 基类统一转发，子类不再重复。可见性统一（要么都 `open`，要么都不）。

### [轻微][存量] `==` / `hashCode` 模板复制三份，且子类的 hash 缓存分支实际不生效

- **位置**：`f_http/src/TextMediaType.cj:50-61`；`f_http/src/MultipartMediaType.cj:35-46`；对照 `f_http/src/MediaType.cj:38-52`
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §2（结构相同、只多一个字段）、§1（基本不命中的分支）
- **证据**：静态确定 —— 三段 `==` / `hashCode` 逐行同构，只在比较字段上多了 `charset` / `boundary`。`MediaType` 构造器已把 `mediaType.hashCode()` 写进 `hash`（`MediaType.cj:40-42`），子类 `if (hash == 0)` 只有在哈希恰好为 0 时才重算，因此 `charset` / `boundary` **实际不参与哈希**。`==` 仍比较字段，`equals/hashCode` 契约不破，只是不同 charset/boundary 的实例全部碰撞。
- **建议**：基类改成 `private var hash: ?Int64`（或构造器置 0），子类只提供 `fieldHash()` / `fieldEquals()` 钩子，由基类统一缓存与比较。

### [轻微][存量] `HttpRequestHeaderException` 全仓无抛出点，且依赖同包另一文件的 `internal import` 才看得见 `BaseException`

- **位置**：`f_http/src/exception/HttpRequestHeaderException.cj:18`；隐式依赖 `f_http/src/exception/MediaTypeException.cj:18`
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §1（读到的声明无使用者；public 顶层不判死代码，仅记为信息）、§11（隐式耦合）
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）`HttpRequestHeaderException` 只命中定义处与 `README.md:267`；本文件没有任何 `import`，`BaseException` 能解析是因为 `MediaTypeException.cj` 用了 `internal import`（`import.md:291-294`：不写修饰符等于 `private import`，仅当前文件；`internal import` 覆盖当前包及子包）。单独移动 / 改名 `MediaTypeException.cj` 即编译失败。
- **描述**：异常类型定义后从未抛出，README 却把它列为对外类型；同时它是包内「靠兄弟文件 import 存活」的最脆弱一例（`MultipartMedia.cj`、`TextMediaType.cj`、`rfc.cj` 同样无 import，只是依赖面更大）。
- **建议**：补 `internal import fountain::f_base.BaseException`；确认是否要真正接入（`README.md:267` 已列出），不接入就随契约变更删除并同步 README。

### [轻微][存量] 文件名与类名不一致：`MultipartFormDataException.cj` 里定义的是 `MultipartException`

- **位置**：`f_http/src/exception/MultipartFormDataException.cj:18`
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（语义与命名不符）、§13（`README.md:267` 只提 `MultipartException`）
- **证据**：静态确定 —— 文件名、README、类名三者对不上；按文件名检索 `MultipartFormDataException` 找不到任何类型。
- **描述**：使用者按文件名 `import fountain::f_http.exception.MultipartFormDataException` 会编译失败。
- **建议**：文件改名为 `MultipartException.cj`，或类改名为 `MultipartFormDataException` 并同步 `MultipartFormDataParser.cj:107/111/217` 与 README。

### [轻微][存量] `MultipartMediaType.toString()` 无条件输出 `; boundary=`；`make` 的错误文案对 `mixed` 恒说 form-data

- **位置**：`f_http/src/MultipartMediaType.cj:32-34`（`toString`）；`:59`（错误消息）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §11（契约 / 文案与实例不符）、§13
- **证据**：静态确定 —— `formData` / `mixed` 单例 boundary 为 `""`，`toString()` 得到 `"multipart/form-data; boundary="`（非法 Content-Type）；`mixed.make("x")` 抛 `"x is not multipart/form-data"`。
- **描述**：任何用 `"${mediaType}"` 拼请求头的地方都会带上空的 boundary 参数；错误消息会把 multipart/mixed 的误用引向 form-data 排查。
- **建议**：boundary 为空 / `""` 时不拼 `; boundary=`；错误消息用 `this.mediaType`。

### [轻微][存量] README 的数据格式清单漏 `multipart/mixed`

- **位置**：`f_http/src/MultipartMediaType.cj:25`（`mixed` 公开并注册于 `MediaTypes.cj:31`）；`f_http/README.md:170-174`（只列 text/plain、application/json、multipart/form-data）
- **来源**：存量（`git blame` 4be871f2f）
- **判据**：review-checklist §14（README 覆盖公开能力）
- **证据**：静态确定 —— `multipart/mixed` 已注册且 `MultipartFormDataParser.cj:104` 有专门分支（产出 `DataMultipartList`），README 数据格式清单未列。
- **描述**：使用者不知道 `multipart/mixed` 可用；同时它只能经 `toData(input)` / parser 解析，不能经 `toData(Array<Byte>)`（`MultipartMediaType.cj:66-68` 抛异常），这条限制也没写。
- **建议**：README 数据格式清单补 `multipart/mixed`，并注明仅支持输入流解析、需要 boundary。

## 优化可行性方案

> 不是缺陷，是"还能更好"。无基线的一律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] `MultipartMedia` 文本 part 的 bytes→String→Data 三份表示

- **现状**：一个 part 同时持有 `bytes: Array<Byte>`；`toData()` / `toString()` 再各解码一次整段内容为 `String`；`toData()` 返回的 `DataString` 又包一份字符串（`f_data/src/base/DataString.cj:43-46`）。单 part 10 MB 时，峰值至少 bytes + String 两份等长数据。
- **方案**：`mediaType == None` 时 `toData()` 直接返回 `ByteBuffer(bytes).toData()`（`f_data/src/base/DataInputStream.cj:81-84`），把文本解码推迟到调用方；`toString()` 按需解码，不缓存。
- **预期**：每个文本 part 少一份与内容等长的 `String`；峰值内存随单 part 大小线性下降（具体比例待测）。
- **代价**：`toData()` 的返回语义从「文本 Data」变「字节 Data」，下游若按 `DataString` 取值会受影响，需要兼容性评估。
- **验证**：构造 10 MB 文本 part + 10 MB 二进制 part 各 100 次，比较 `getAllocatedHeapSize()` 峰值与 RSS，中位数 5 轮。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TextMediaType` / `MultipartMediaType` 的 `hashCode` 不含 charset/boundary，若这些实例进哈希容器会放大碰撞 | `f_http/src/TextMediaType.cj:56-61`、`f_http/src/MultipartMediaType.cj:41-46` | 实例进入哪些 Map/Set、碰撞率与查找耗时 | 埋点统计 `MediaType` 实例作为 key 的次数与桶长度，跑 10 分钟内容协商负载 |
| 2 | 每个请求都 `indexOf` + 切片构造 `MultipartMediaType`，高频上传下分配占比可观 | `f_http/src/MultipartMediaType.cj:47-61` | 单次解析耗时占比、每请求分配字节数 | `cjprof record` 跑 1k/10k 次 multipart 请求，看 `make` 自耗时与分配量 |
| 3 | `MultipartMedia.toString()` 对大 part 解码是长尾来源 | `f_http/src/MultipartMedia.cj:47-50` | P95/P99 单次解码耗时、峰值 RSS | 按 1 MB / 10 MB / 100 MB part 分段计时，记录 GC 次数 |

## 文件覆盖

> 与 `{workdir}/files/f_http.part2.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_http/src/MultipartMedia.cj` | .cj | ✅ | 见发现 #6、#7、#9 |
| 2 | `f_http/src/MultipartMediaType.cj` | .cj | ✅ | 见发现 #4、#5、#11、#14 |
| 3 | `f_http/src/TextMediaType.cj` | .cj | ✅ | 见发现 #3、#11 |
| 4 | `f_http/src/exception/HttpRequestHeaderException.cj` | .cj | ✅ | 见发现 #10、#12 |
| 5 | `f_http/src/exception/MediaTypeException.cj` | .cj | ✅ | 见发现 #10、#12 |
| 6 | `f_http/src/exception/MultipartFormDataException.cj` | .cj | ✅ | 见发现 #10、#13 |
| 7 | `f_http/src/rfc.cj` | .cj | ✅ | 见发现 #1、#2、#9 |

合计：`.cj` 7 个 / `.md` 0 个 / 共 7 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 #1-#7；语言特性：单引号多行串、`as` 返回 `Option`、函数返回类型推导均已查文档确认，未误报；安全性 0 条——boundary/charset 只作为字面量字节与查表键使用，未进正则 / SQL / 路径，无注入面 |
| §1 死代码 | 2 | 逐个检查本部分 `private` / 包内符号：`FORM_DATA`/`MIXED`/`data2json`/私有构造器均有引用；`protected` 仅 `TextMediaType` 的 ctor/`doMake`，属 `public abstract` 非 sealed 类，按豁免不判；命中 #9（恒假分支 + 不可达 `getOrThrow`）、#10（public 异常类型全仓无抛出点，按要求只记信息不判死代码） |
| §2 重复逻辑 | 2 | 同文件两两比对 15 个函数体 + 跨文件搜相同文案/模板：命中 #10（3 个异常类 12 个构造器）、#11（3 份 `==`/`hashCode` 模板）。`PlainTextMediaType.make`/`JsonMediaType.make` 已复用 `doMake`，不算重复 |
| §3 空实现 | 1 | #6：`MultipartMedia` 的四个转换入口全是 throw，`try*` 契约不成立；`TextMediaType`/`MultipartMediaType` 的「不支持访问」throw 属显式设计并有语义，不判 |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构、无深拷贝；`MultipartMediaType`/`doMake` 都是单层解析 |
| §5 OOM | 0 | 本部分没有新的全量物化点；`MultipartMediaType.toData(input)`、`MultipartMedia.toString()` 的无上限读取/解码已由第 1/2 部分的 `MediaType.toData(InputStream)` 与 parser 条目覆盖，不重复计数 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点不成立；候选写入「待验证假设」#2、#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列 |
| §6.4 低效算法 | 0 | 解析均为单趟 `indexOf`/切片，无嵌套循环、无 `contains` 热点；字符串重复拼接（`rfc1123`）调用频率低，不构成算法级问题 |
| §7 降堆内存方案 | 1 | 「MultipartMedia 文本 part 三份表示」，`无基线（待验证）` |
| §8 降 CPU 方案 | 0 | 无基线，唯一候选（`make` 每次切片分配）已进「待验证假设」#2 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内销毁的大临时对象」；`MultipartMediaType.make` 的切片只活到返回，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 12 | #1-#9、#12-#14 均为存量缺陷，逐条给出行号与触发条件；日期解析/格式化、媒体类型参数解析是主要风险面 |
| §12 并发安全与锁粒度 | 0 | 已核对共享点：`PlainTextMediaType.instance`、`JsonMediaType.instance`、`MultipartMediaType.formData/mixed` 是全局单例，但字段全 `let`；`hash` 的惰性写分支在子类不命中（见 #11），无实际写共享；无锁可谈 |
| §14 功能完备性与 README 覆盖 | 1 | #14（README 漏 `multipart/mixed`）；#6 另给出 `MultipartMedia`「README 列为公开类型但无任何实现路径」的双证 |
| 文件覆盖（§13 等） | 7/7 | 本部分无 `.md`，§13 文档一致性由第 1/2 部分覆盖；7 个 `.cj` 全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

存量 14 条（严重 2、一般 4、轻微 8），是否纳入修复待用户决定。

## 总评

本部分代码的最大问题是 `rfc.cj`：解析端两字符切片让**所有**合法 RFC 1123 日期都抛异常，而调用方用空 `catch` 吞掉，表现为「Content-Disposition 的日期永远读不出来」；格式化端又因不补零、0 偏移输出 `UTC`、分钟偏移截断而生成非法 HTTP-date。这两条是阻塞项，且都是纯字符串处理，修复成本低、收益直接。

媒体类型实现的问题集中在参数解析：`TextMediaType.doMake` 和 `MultipartMediaType.make` 都用「单一字面量 + 取到串尾」的方式解析 `charset` / `boundary`，对带引号、无空格、带尾随参数、大小写不同的合法头要么抛异常（`@RequestBody` 变 500），要么静默丢参数；空 boundary 还能一路传到分块解析器。建议抽一个共享参数解析器，并把校验前置到 `toData(input)` 入口。

结构性问题是 `MultipartMedia`：`Data`/`DataFields` 的四个转换入口全是 `Not Supported`，README 却把它列为公开类型，嵌套 multipart 因此没有落地实现；同一根因也导致二进制 part 走文本解码而丢字节。异常包的三处小问题（构造器复制、文件名与类名不符、靠兄弟文件 `import` 存活）属于可排期的整理项。
