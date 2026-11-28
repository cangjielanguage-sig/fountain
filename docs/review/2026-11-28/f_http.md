# f_http 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_http`（27 个文件：20 个 .cj + 7 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_http.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] 落盘文件名直接取自客户端且未净化，`Path.join` 不处理 `..`，可写到 uploadDir 之外

- **位置**：`f_http/src/MultipartFormDataParser.cj:198`（`File(path.join(filename), ReadWrite)`）；`f_http/src/MultipartFormDataParser.cj:101`（唯一的 `path`）；`f_http/src/MultipartFormDataParser.cj:130/198`（`filename` 来源）
- **来源**：存量（快照模式无基线；blame 4be871f2f）
- **判据**：review-checklist §11「安全 / 外部输入未校验」、§10「安全性」；`Path.join(String)` 文档明确「仅进行字符串拼接，不处理 `..` 等路径遍历组件」（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1681-1693`）
- **证据**：静态确定 —— `filename` 来自 `ContentDisposition.getFilename()`，即 `Content-Disposition` 头里的客户端字符串；代码只判了 `filename.isEmpty()`，未取 basename、未拒绝 `/`、`\`、`..`，也未做 `canonicalize` 后的目录归属校验；`File(ReadWrite)` 在文件不存在时会创建文件（`fs_package_enums.md:44-47`）
- **描述**：攻击者上传 `filename="../../../../tmp/pwn"` 即可在 uploadDir 之外创建/覆盖任意可写文件（配置、启动脚本、其他租户上传目录都在射程内）；`filename` 为绝对路径时 `Path.join` 抛 `FSException`，变成 500。该路径是文件上传主路径，不需要任何特殊配置
- **建议**：`let base = Path(filename).fileName`（或按 `/`、`\` 切最后一段），拒绝空名与 `.`/`..`；拼完 `path` 后 `canonicalize()` 并断言仍以 uploadDir 规范化结果为前缀，否则抛 `MultipartException`；补三条恶意 filename 用例（`../`、绝对路径、`a/b`）

### [严重][存量] `MultipartFormData.input()` 状态机：每个 part 后都写终止边界，最后一个 part 后越界，内容 EOF 直接返回 0

- **位置**：`f_http/src/MultipartFormData.cj:93-129`（`read`）；`f_http/src/MultipartFormData.cj:111-116`（内容读到 0 直接 `return 0`）；`f_http/src/MultipartFormData.cj:124`（`'\r\n--${boundary}--\r\n'` 无条件写终止符）；`f_http/src/MultipartFormData.cj:125`（`data.parts[idx + 1]` 无上界判断）；`f_http/src/MultipartFormData.cj:96`（`data.parts[0]` 无空列表判断）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「边界差一 / 越界」「契约与实现不符」；§14「承诺了但没实现」
- **证据**：静态确定 —— ①`CRLF_Boundary` 分支固定写 `\r\n--boundary--\r\n`，非最后一个 part 也应写 `\r\n--boundary\r\n`，因此多 part 报文在第一个 part 后就出现终止边界，后续 part 成为非法尾随数据；②最后一个 part 走 `Next => Current(idx + 1, data.parts[idx + 1], StartBoundary)`，`idx + 1 == parts.size` 必然 `IndexOutOfBoundsException`；③`Current(idx, input)` 在内容刚好读完时 `l == 0`，却把 0 返回给调用方，调用方按 InputStream 语义视为 EOF，后面的 `\r\n--boundary` 永远不会被写出；④`Start` 分支直接 `data.parts[0]`，空表崩溃。仓内 `f_httpclient/src/httpclient.cj:239/242` 正是 `client.put/post(data.input())` 的调用方，因此客户端 multipart 上传必坏
- **描述**：单 part：上传体在内容结束处被截断，服务端收不到终止边界；多 part：第一个 part 后插入 `--` 终止符，服务端解析失败；即使调用方强行继续读，最后一个 part 后越界抛异常。现有测试只覆盖 `parse()`，`input()`/`encode()` 零用例
- **建议**：把状态机改为「`Next` 时 `idx + 1 < parts.size` 才进入下一 part，否则 `cur = Done` 并返回 0」；`CRLF_Boundary` 写 `\r\n--boundary`，仅当 `idx == parts.size - 1` 时追加 `--\r\n`；内容 `read` 返回 0 时先推进状态并递归/继续，不把 0 返回给外层；`Start` 对 `parts.isEmpty()` 返回 0。补 `encode()`/`input()` 的单 part、双 part、空 form 三条用例（可直接用 `parse()` 回读做往返断言）

### [严重][存量] `ContentDisposition.encodeFilename` 条件写反：所有 charset 都抛异常，`filename*` 编码永远不可用

- **位置**：`f_http/src/ContentDisposition.cj:469-494`（`encodeFilename`）；`f_http/src/ContentDisposition.cj:470-472`（`if (!charset.nameEquals(US_ASCII)) throw "US_ASCII does not require encoding."`）；`f_http/src/ContentDisposition.cj:473-476`（第二道检查）；调用点 `f_http/src/ContentDisposition.cj:207-214`
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「语义与注释不符」、§3「公开契约承诺有行为」；§1「不可达语句」
- **证据**：静态确定 —— 唯一的调用条件已经排除了 `charset == None` 与 `US_ASCII`（207 行），因此进入 `encodeFilename` 的 charset 必为非 ASCII：470 行 `!nameEquals(US_ASCII)` 恒为 true，第一句就抛；若勉强传入 `US_ASCII`，473 行 `isUtf8 = (charset == UTF8)` 为 false，474 行 `!(false || nameEquals(ISO_8859_1))` 又为 true，仍抛。函数体 477-493 行（含 UTF8 分支）对任何输入都不可达
- **描述**：公开 API `ContentDisposition.setCharset(UTF8).toString()`（或任何非 ASCII charset）必抛 `IllegalArgumentException`，RFC 5987 `filename*=` 功能整体失效；`MultipartFile` 合并 `ContentDisposition.toString()` 生成 part 头时，只要上游给 CD 设了 charset（例如中文文件名）就会中断整个 multipart 编码。仓内目前只有 parser 使用 CD，尚未触发，但这是对外可调用路径
- **建议**：条件改为「若 charset 是 US-ASCII 则无需编码（直接返回/走普通 filename）」，并把 473-476 的支持列表检查放到最前、按 `isUtf8 || ISO-8859-1` 判断；删除不可达分支或补 `US_ASCII` 早返回；补 `setFilename("中文.pdf").setCharset(Charsets.UTF8).toString()` 与 `US_ASCII` 两条往返用例（`parse(toString())` 后 filename 一致）

### [严重][存量] 一次 `parse()` 的所有落盘 part 共用一个目录和一个客户端文件名，同名文件互相覆盖且不截断

- **位置**：`f_http/src/MultipartFormDataParser.cj:101`（`path` 在循环外创建一次）；`f_http/src/MultipartFormDataParser.cj:195-208`（每个文件 part 都用 `path` + `filename`）；`f_http/src/MultipartFormDataParser.cj:198`（`ReadWrite`）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「数据错误」；`OpenMode.ReadWrite` 文档明确「不会使文件被截断为零字节大小」（`fs_package_enums.md:44-47`）；同一变更的 `doc/spec/reuse-multipart-parse-buffers/design.md:110` 声称「每个 part 的 File 路径独立（各自 UUID 子目录）」
- **证据**：静态确定 —— `path` 是 `uploadDir/UUID`，循环内所有文件 part 复用；第二个同名 part `File(path.join(filename), ReadWrite)` 从偏移 0 开始写，旧文件更长时尾部保留；随后 `part.setSize(file.length)` 把旧长度当新内容长度，`bytes()` 会返回「新内容 + 旧尾部」
- **描述**：`<input type="file" multiple name="files">` 或多个目录下同名文件（`photo.jpg`）会静默损坏：后者覆盖前者前缀，长度取较长的旧文件，读取方拿到混合内容；两个 `MultipartFile` 还指向同一路径，先 `close()` 的一方会删掉另一方正在用的文件。设计文档与实现不一致，说明该场景没有被测试覆盖（`testMixedFormAndFiles` 用的是 `one.bin`/`two.bin`）
- **建议**：每个文件 part 使用独立子目录（`path.join(UUID.random().toString())`）或对 filename 做去重/哈希；打开文件改用 `Write`（截断）或写入前 `setLength(0)`；补「两个同名 part 内容不同、长度一大一小」的用例，断言两个 `MultipartFile` 内容各自正确

### [严重][存量] `MediaTypes` 注册失败路径没有 `finally` 复位与通知，等待线程永久阻塞

- **位置**：`f_http/src/MediaTypes.cj:41-55`（`registerFromBeanFactory`）；`f_http/src/MediaTypes.cj:42-47`（CAS 0→-1 后注册，再 store(1)+notifyAll）；`f_http/src/MediaTypes.cj:48-53`（`condition.wait()` 无超时、无循环重查）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §12.1「死锁 / 条件等待」、§3「静默失效」
- **证据**：静态确定（控制流）＋待确认（`BeanFactory.instance.getList<MediaType>()` 是否可能抛异常）—— `compareAndSwap(0, -1)` 成功后，`register(BeanFactory.instance.getList<MediaType>())` 与 `store(1)` 之间没有 `try/finally`；一旦 `getList` 初始化某个 MediaType bean 失败，标志永久停在 -1。后续任何 `MediaTypes.parse/tryParse`（每个 part 的 `Content-Type` 都会走）进入 `else if (load() == -1)`，在 `condition.wait()` 上无限等待，且没有第二个线程会 `notifyAll`
- **描述**：单个自定义 MediaType bean 初始化异常会把「之后所有 multipart 请求」永久挂住（线程池逐步耗尽），而不是让首请求失败、后续重试；`wait()` 返回后也不重查标志，虚假唤醒时会在 bean 尚未注册完时继续解析，导致自定义类型偶发缺失
- **建议**：`try { register(...); store(1) } catch (e) { store(0); throw e } finally { synchronized(mutex){ condition.notifyAll() } }`；等待端改为 `while (load() == -1) { condition.wait(timeout) }`（超时抛明确异常）；更稳妥的是用 `std.sync` 的 `Future`/一次性 latch 替代手写条件变量

<!-- 第 2 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [堆内存] 文本字段流式分支避免 `ArrayList<Byte>` 扩容与容量残留

- **现状**：`MultipartFormDataParser.cj:164-175` 每 1 KB `add(all:)` 一次，`ArrayList` 按约 1.5 倍扩容；`unsafeData()` 返回底层数组的 `[0..size]` 切片（`f_base/src/UnsafeData.cj:24-29`），`String.unsafeUtf8` 继续持有该数组。一个 1 MB 文本字段会同时存在扩容期旧数组、最终底层数组（容量可能 1.5 MB）和 String 视图
- **方案**：用请求 `Content-Length`/当前窗口估算 `ArrayList<Byte>(initialCapacity: expected)`；或在结束时按 `bytes.size` 精确复制一次并让旧数组尽快不可达；超阈值（如 1 MB）直接落盘，再由下游流式读取
- **预期**：减少扩容拷贝次数，降低大字段的峰值堆占用（具体百分比需测）
- **代价**：预分配可能浪费；精确复制多一次 O(n) 拷贝；落盘增加 I/O
- **验证**：1/8/64 MB 文本字段各 10 轮，`-O2`，记录 `getAllocatedHeapSize()`、峰值 RSS、解析耗时中位数与 P95；与当前实现同机对照
- **证据状态**：`无基线（待验证）`

### [CPU] `MediaTypes.doTryParse` 每 part 的 debug 调用先取时间戳/线程 id

- **现状**：`MediaTypes.cj:61-80` 每个 part 解析 `Content-Type` 都会走一次 `log.debug{...}`；虽然 lambda 消息体是惰性的，但 `AbstractLogger.append` 在级别判断前就执行 `DateTime.now()` 与 `Thread.currentThread.id`（`f_log/src/base/AbstractLogger.cj:113-115`），debug 关闭时这部分开销仍然发生；随后还有两次 `ConcurrentHashMap` 查找与 `make(mediaType)` 字符串处理
- **方案**：调用点加 `if (log.debugEnabled) { log.debug{...} }`（或新增无时间戳的重载）；把「Content-Type → MediaType 原型/实例」按请求内缓存（同一 part 头通常重复），避免同一字符串多次 `make`
- **预期**：每 part 省一次 `DateTime.now` + 线程 id 读取；100 part 的表单约省 100 次这类调用（绝对值需测）
- **代价**：请求内缓存增加少量内存与失效逻辑；不能跨请求缓存（MediaTypes 可运行时注册）
- **验证**：`cjprof record` 解析 10k part 的合成报文，比较 `MediaTypes.doTryParse` 自耗时与 `DateTime.now` 调用次数；同时用 `cjpm bench -O2`
- **证据状态**：`无基线（待验证）`

<!-- 第 2 部分 -->

> 不是缺陷，是"还能更好"。无基线的一律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] `MultipartMedia` 文本 part 的 bytes→String→Data 三份表示

- **现状**：一个 part 同时持有 `bytes: Array<Byte>`；`toData()` / `toString()` 再各解码一次整段内容为 `String`；`toData()` 返回的 `DataString` 又包一份字符串（`f_data/src/base/DataString.cj:43-46`）。单 part 10 MB 时，峰值至少 bytes + String 两份等长数据。
- **方案**：`mediaType == None` 时 `toData()` 直接返回 `ByteBuffer(bytes).toData()`（`f_data/src/base/DataInputStream.cj:81-84`），把文本解码推迟到调用方；`toString()` 按需解码，不缓存。
- **预期**：每个文本 part 少一份与内容等长的 `String`；峰值内存随单 part 大小线性下降（具体比例待测）。
- **代价**：`toData()` 的返回语义从「文本 Data」变「字节 Data」，下游若按 `DataString` 取值会受影响，需要兼容性评估。
- **验证**：构造 10 MB 文本 part + 10 MB 二进制 part 各 100 次，比较 `getAllocatedHeapSize()` 峰值与 RSS，中位数 5 轮。
- **证据状态**：`无基线（待验证）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MediaTypes.doTryParse` 的 debug 时间戳/线程 id 与 map 查找在多 part 表单中占比可观 | `f_http/src/MediaTypes.cj:61-80` | 该函数自耗时占比、每 part 调用次数 | `cjprof record` 解析 10k part，`-O2`；对照 `debugEnabled` 守卫版本 |
| 2 | 文本字段 `ArrayList<Byte>` 扩容与 `unsafeData` 容量残留抬高大字段峰值 | `f_http/src/MultipartFormDataParser.cj:164-175` | 1/8/64 MB 字段的峰值堆与分配量 | `getAllocatedHeapSize()` + RSS，10 轮中位数，改前/改后对照 |
| 3 | `parse()` 无条件 `UUID.random().toString()` + `Path.join` 在纯字段表单上是可省开销 | `f_http/src/MultipartFormDataParser.cj:101` | 每请求分配字节数与耗时 | 分配采样 + 1 万次纯字段 parse 的分段计时 |
| 4 | `ContentDisposition.tokenize` + `split('\r\n')` 的临时字符串在 100+ part 时带来明显 GC 压力 | `f_http/src/ContentDisposition.cj:360-397`、`MultipartFormDataParser.cj:128` | 每 part 分配量、GC 次数 | `cjprof heap`，100/1000 part 两档 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TextMediaType` / `MultipartMediaType` 的 `hashCode` 不含 charset/boundary，若这些实例进哈希容器会放大碰撞 | `f_http/src/TextMediaType.cj:56-61`、`f_http/src/MultipartMediaType.cj:41-46` | 实例进入哪些 Map/Set、碰撞率与查找耗时 | 埋点统计 `MediaType` 实例作为 key 的次数与桶长度，跑 10 分钟内容协商负载 |
| 2 | 每个请求都 `indexOf` + 切片构造 `MultipartMediaType`，高频上传下分配占比可观 | `f_http/src/MultipartMediaType.cj:47-61` | 单次解析耗时占比、每请求分配字节数 | `cjprof record` 跑 1k/10k 次 multipart 请求，看 `make` 自耗时与分配量 |
| 3 | `MultipartMedia.toString()` 对大 part 解码是长尾来源 | `f_http/src/MultipartMedia.cj:47-50` | P95/P99 单次解码耗时、峰值 RSS | 按 1 MB / 10 MB / 100 MB part 分段计时，记录 GC 次数 |

## 文件覆盖

> 与 `files/f_http.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_http/README.md` | .md | ✅ | — |
| 2 | `f_http/README_en.md` | .md | ✅ | — |
| 3 | `f_http/doc/spec/reuse-multipart-parse-buffers/design.md` | .md | ✅ | — |
| 4 | `f_http/doc/spec/reuse-multipart-parse-buffers/proposal.md` | .md | ✅ | — |
| 5 | `f_http/doc/spec/reuse-multipart-parse-buffers/specs/http-multipart/spec.md` | .md | ✅ | — |
| 6 | `f_http/doc/spec/reuse-multipart-parse-buffers/specs/io-rotatable-buffer/spec.md` | .md | ✅ | — |
| 7 | `f_http/doc/spec/reuse-multipart-parse-buffers/tasks.md` | .md | ✅ | — |
| 8 | `f_http/src/ContentDisposition.cj` | .cj | ✅ | — |
| 9 | `f_http/src/ContentDispositionBuilder.cj` | .cj | ✅ | — |
| 10 | `f_http/src/ContentDispositionType.cj` | .cj | ✅ | — |
| 11 | `f_http/src/HttpConfig.cj` | .cj | ✅ | — |
| 12 | `f_http/src/MediaType.cj` | .cj | ✅ | — |
| 13 | `f_http/src/MediaTypes.cj` | .cj | ✅ | — |
| 14 | `f_http/src/Multipart.cj` | .cj | ✅ | — |
| 15 | `f_http/src/MultipartBufferReuse_test.cj` | .cj | ✅ | — |
| 16 | `f_http/src/MultipartEmptyPart_test.cj` | .cj | ✅ | — |
| 17 | `f_http/src/MultipartFile.cj` | .cj | ✅ | — |
| 18 | `f_http/src/MultipartFormData.cj` | .cj | ✅ | — |
| 19 | `f_http/src/MultipartFormDataParser.cj` | .cj | ✅ | — |
| 20 | `f_http/src/MultipartFormDataParser_test.cj` | .cj | ✅ | — |
| 21 | `f_http/src/MultipartMedia.cj` | .cj | ✅ | — |
| 22 | `f_http/src/MultipartMediaType.cj` | .cj | ✅ | — |
| 23 | `f_http/src/TextMediaType.cj` | .cj | ✅ | — |
| 24 | `f_http/src/exception/HttpRequestHeaderException.cj` | .cj | ✅ | — |
| 25 | `f_http/src/exception/MediaTypeException.cj` | .cj | ✅ | — |
| 26 | `f_http/src/exception/MultipartFormDataException.cj` | .cj | ✅ | — |
| 27 | `f_http/src/rfc.cj` | .cj | ✅ | — |

合计：`.cj` 20 个 / `.md` 7 个 / 共 27 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 2（`input()` 状态机、同名文件覆盖）、设计 1（parser 同时承担落盘/媒体类型/目录管理）、安全性 2（路径穿越、头解析宽度）；语言特性层面 `Option`/`struct`/`unsafeZeroValue` 用法本身无语法问题，但 `unsafeZeroValue` 被当作合法空值使用是设计缺陷；可读性 0（命名总体清楚，仅 `seperator` 拼写等不影响判断） |
| §1 死代码 | 2 | 已逐个检查本部分全部 `private`/包内符号：`ContentDisposition` 的 `US_ASCII/ISO_8859_1/UTF8/BASE64_ENCODED_PATTERN/charsetEq/tokenize/decodeFilename/isRFC5987AttrChar/escapeQuotationsInFilename/encodeFilename/hash` 均有引用；`MediaTypes` 的 8 个私有成员均有引用；`HttpConfig.isHttpDebugging/bufferSize` 有引用；`MultipartFormDataParser` 的 `stream/crlf/chunkBuf/chunkBuffer/seperatorBoundaryBytes` 有引用。命中：①`Multipart.name`（`public` 成员但顶层 `abstract sealed class Multipart` 非 public，按硬原则二全仓零引用）、`Multipart.setName`、`MultipartFile.setType/setFilename/directory` 均无引用；②parser `start += boundaryBytes.size`（114 行，循环开头必被覆盖）、`let (l, _, _)` 的 `l` 未用、`ContentDisposition` 316 行 `let _ = m.matchString(1)` 读了不用。对外可达 public（`isClosed`、`reader`、`getType`、`MediaType` 各方法等）仓内零引用按硬原则一不判，仅记录 |
| §2 重复逻辑 | 1 | 已把本部分全部函数体压成「输入-输出-副作用」摘要两两比对。命中：parser 的两处「字段落库」块（143-154 与 182-193）除 `value` 构造外逐行同义；`DataMultipartTuples` 与 `DataMultipartList` 的四个 stub（245-256 / 270-281）逐字同构；`ContentDisposition` 的三个日期 setter 结构相同但类型不同，属必要重载不计；`MultipartFileBuilder.file(File)` 与 `file(String, InputStream, ...)` 仅有元数据来源差异，保留 |
| §3 空实现 | 1 | `DataMultipart*` 的 `tryParse/parse/tryFromData/toString` 与 `MultipartFile.tryParse` 全部抛 `IllegalAccessException`/`MediaTypeException`（见「一般」#7）；`parse` 是 `tryParse` 的纯包装也必抛；`ContentDisposition.parse` 的日期 `catch (_) {}` 属可选字段的容错，但与 `size` 的严格 `Int64.parse` 不一致，见轻微 |
| §4 栈溢出 | 0 | 已检查：`parse()` 是 `while(true)` + 边界跳转，无递归；`MultipartFileInputStream.read` 的递归每次只推进有限状态（Start→tmp→Content→CRLF→Next），单次调用深度 ≤5，不随 part 数增长；`ContentDisposition.tokenize/decodeFilename` 均为循环；`MediaTypes` 无递归。`MultipartFormData.input()` 的越界是数组下标而非栈问题 |
| §5 OOM | 1 | 文本字段/part 数无上限（一般 #6）；另外 `MediaType.toData(InputStream)` 全量读入，但属对外 API、调用方自控，未单独计缺陷。文件分支有落盘，不构成无限堆增长 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据；`MediaTypes` debug 调用、文本字段扩容、UUID/Path 分配三处只能进「待验证假设」，未作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `MediaTypes.mutex`，只保护 `condition` 的等待/通知，注册动作在锁外，无锁内 I/O/解析/日志；不存在大粒度锁热点 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；parser 每请求单线程单次使用（类注释与实现一致） |
| §6.4 低效算法 | 0 | `tokenize` 为线性扫描；`DataMultipartTuples` 用 `HashMap` 按 name 索引；无嵌套循环、无热点 `contains`/`remove(at: 0)`；`RotatableBuffer.indexOf` 的线性扫描属 `f_io`，不重复计 |
| §7 降堆内存方案 | 1 | 文本字段流式分支的 `ArrayList` 扩容/容量残留（见优化方案，`无基线`）；`MultipartFormData.parts` 与 `DataMultipartTuples.map` 的生命周期随返回值，属必要持有，未列 |
| §8 降 CPU 方案 | 1 | `MediaTypes.doTryParse` 的 debug 时间戳/线程 id 与重复解析（见优化方案，`无基线`） |
| §9 local mode 可行性 | 0 | 逐个检查：`headerBuf` 通过 `String.unsafeUtf8` 逃逸进返回的 `Data`/`ContentDisposition`，`buf` 进入 `MultipartFile`/`Data`，`chunkBuf`/`crlf` 是实例字段（跨调用存活），均不满足「函数内创建、函数内释放」；没有峰值内存数据，收益无法证明，故不列方案 |
| §11 现有代码的 BUG（存量） | 24 | 上述「严重 5 + 一般 12 + 轻微 7」共 24 条全部为存量（快照模式无基线，blame 均指向 4be871f2f 格式提交）；边界/空值/错误处理/资源/并发/契约六类已逐函数核对 |
| §12 并发安全与锁粒度 | 2 | `MediaTypes.registerFromBeanFactory` 的失败死锁（严重 #5）；`MediaTypes.register` 对同名键静默覆盖（轻微 #6）。`mediaTypes` 是 `ConcurrentHashMap`，注册由单线程 CAS 获胜者执行；`MultipartFormData`/`MultipartFile`/`ContentDisposition` 均为请求内实例，未声明线程安全，按误报边界不判 |
| §13 文档一致性 | 1 | README 的三处不符（安全段类型归属、缺 `parse()`/配置项、空标题）合并为「一般」#11；`README_en.md` 同步复制同一批问题；`doc/spec/**` 为归档变更，按 checklist 误报边界只核对当时自洽性，不要求与当前实现一致 |
| §14 功能完备性与 README 覆盖 | 3 | 嵌套 `multipart/mixed` 未实现（一般 #8）；`uploadStoreInMemory` 未接线（一般 #10）；README 遗漏 `MultipartFormDataParser.parse()`、`HttpConfig.uploadStoreInMemory/http_debugging`（一般 #11）。`ContentDisposition`/`MultipartFile` 的其余 public 成员与 README 基本对齐 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_http.part1.txt` 一一对应，无缺项；本轮未运行构建/测试（只读审查），测试结论均引自现有测试代码与设计文档记录 |

### 第 2 部分

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
| 严重 | 7 |
| 一般 | 4 |
| 轻微 | 8 |
| 其中存量 | 19 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：`f_http` 的 multipart 解析主路径（浏览器常见的 `Content-Disposition: form-data; name=...` + 小字段 + 单文件）能跑通，`chunkBuf`/`crlf` 复用、header 精确分配、落盘分支的写法是清醒的，注释也解释了「为什么 header 不能复用」。但**离生产可用还差一层安全与边界硬化**：

- **阻塞项**：①客户端 filename 直接拼进落盘路径，`Path.join` 官方文档已说明不处理 `..`，这是任意文件写入；②`MultipartFormData.input()` 的公开 API 是坏的（终止符、最后 part 越界、内容 EOF 返回 0），而 `f_httpclient` 正在调用；③`ContentDisposition.encodeFilename` 条件写反，`filename*` 永远抛异常；④所有落盘 part 共用一个目录和客户端文件名，同名上传会静默串内容；⑤`MediaTypes` 注册失败会让后续所有 multipart 请求永久等待。这五条都只看代码即可确定，且没有一条被现有测试覆盖。
- **应排期**：part 头大小写/顺序/超长、boundary 引号、`filename*` 越界、charset 丢失、无大小上限、`DataMultipart*` 的 `try*`/`toString` 契约、嵌套 mixed、`bytes()` 的破坏性语义、`uploadStoreInMemory` 未接线、README 错把 `f_mvc` 的安全类型写进来。
- **工程判断**：这个模块的测试是「事后补的回归网」，只覆盖 `parse()` 的 happy path，`encode()`/`input()`/`ContentDisposition`（解析与序列化）完全没有用例，所以输出侧的两个严重缺陷能长期存在。建议先补 `encode ↔ parse` 往返测试、恶意 filename/超长 header/多同名文件三组负向用例，再按上面的阻塞项修复；修完后 `input()` 与 `encode()` 应能互为验证。

性能与内存方面没有可用的基线数据，报告只给了 2 条待验证方案与 4 条假设，未做任何「能降 X%」的结论。

**第 2 部分**：本部分代码的最大问题是 `rfc.cj`：解析端两字符切片让**所有**合法 RFC 1123 日期都抛异常，而调用方用空 `catch` 吞掉，表现为「Content-Disposition 的日期永远读不出来」；格式化端又因不补零、0 偏移输出 `UTC`、分钟偏移截断而生成非法 HTTP-date。这两条是阻塞项，且都是纯字符串处理，修复成本低、收益直接。

媒体类型实现的问题集中在参数解析：`TextMediaType.doMake` 和 `MultipartMediaType.make` 都用「单一字面量 + 取到串尾」的方式解析 `charset` / `boundary`，对带引号、无空格、带尾随参数、大小写不同的合法头要么抛异常（`@RequestBody` 变 500），要么静默丢参数；空 boundary 还能一路传到分块解析器。建议抽一个共享参数解析器，并把校验前置到 `toData(input)` 入口。

结构性问题是 `MultipartMedia`：`Data`/`DataFields` 的四个转换入口全是 `Not Supported`，README 却把它列为公开类型，嵌套 multipart 因此没有落地实现；同一根因也导致二进制 part 走文本解码而丢字节。异常包的三处小问题（构造器复制、文件名与类名不符、靠兄弟文件 `import` 存活）属于可排期的整理项。
