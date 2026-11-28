# f_http 模块审查报告（模块第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_http`（本部分 13 个 `.cj` + 7 个 `.md`，共 20 个文件；第 2 部分为 `MultipartMedia.cj` / `MultipartMediaType.cj` / `TextMediaType.cj` / `exception/*.cj` / `rfc.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；`git blame` 指向 2026-10-02 `4be871f2f`「统一换行符为 LF（CRLF→LF，1293 个文件）」这一格式提交，无法再向上归因，故本部分全部记为「存量」）
- **审查重点**：HTTP multipart 解析与响应正确性（分块、流式、边界）、注入与路径安全、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

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

## 一般

### [一般][存量] part 头解析硬编码 `Content-Disposition: `、固定首行与固定第二行，合法报文会被拒绝或按内部异常崩溃

- **位置**：`f_http/src/MultipartFormDataParser.cj:123-129`（`partHeader[0]['Content-Disposition: '.size ..]`）；`f_http/src/MultipartFormDataParser.cj:143/182`（`partHeader[1]` 当 Content-Type）；`f_http/src/MultipartFormDataParser.cj:124`（`Array<Byte>(end - start + 4)`，`end == -1` 时为负）；`f_http/src/MultipartFormDataParser_test.cj:304-309`（把 `NegativeArraySizeException` 固化为期望）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「边界差一 / 未处理 None」「语义与注释不符」；§13「文档与实现不一致」
- **证据**：静态确定 —— ①HTTP 头字段名大小写不敏感，`content-disposition: form-data; ...`（本文件 26-64 行的类注释示例就是小写）会被切掉 21 字节后得到 `orm-data; ...`，`ContentDispositionType.parse` 抛 `IllegalArgumentException`；`Content-Disposition:form-data`（无空格）同样错位。②只认 `partHeader[0]`，若客户端先发 `Content-Type` 再发 `Content-Disposition`，切的是 CT 行。③只把 `partHeader[1]` 当 CT，若中间还有 `Content-Transfer-Encoding`，CT 被当媒体类型解析而失败。④`end = indexOf(DOUBLE_CRLF)` 只在当前 2×halfBufferSize 窗口内查找，header 超过约 4 KB 时返回 -1，`Array<Byte>(-1 - start + 4)` 抛 `NegativeArraySizeException`（测试 304-309 行明确把它当现状）
- **描述**：合法的 RFC 1867 报文（大小写变体、头顺序不同、无空格）会被 500；超长 header 由客户端可控地触发内部 `NegativeArraySizeException`，不是 `MultipartException`，错误语义与限流都收不到正确信号
- **建议**：按行遍历 `partHeader`，用 `equalsIgnoreAsciiCase` 找 `Content-Disposition` / `Content-Type`（不依赖位置）；`end < start` 或 `end < 0` 时抛 `MultipartException("header too long or malformed")`；把测试改为断言 `MultipartException`，并补小写头、CT 在 CD 之前、5 KB header 三条用例

### [一般][存量] `MultipartFormDataParser.new` 用 `indexOf("boundary=")` 截取到行尾，引号、尾随参数、大小写都会取错 boundary

- **位置**：`f_http/src/MultipartFormDataParser.cj:83-87`
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「边界 / 空值 / 错误处理」；§14「半成品」
- **证据**：静态确定 —— `contentType[contentType.indexOf('boundary=').getOrThrow() + 'boundary='.size ..]` 取的是 `boundary=` 之后到字符串末尾的全部内容：`multipart/form-data; boundary="abc"` 得到 `"abc"`（含引号），`boundary=abc; charset=utf-8` 得到 `abc; charset=utf-8`，两者都构造不出正确的 `\r\n--boundary`，`parse()` 在 `indexOf` 时返回 -1 抛 `MultipartException`；`Boundary=` 大写则 `getOrThrow()` 抛 `NoneValueException`，Header 缺失时同样抛 `NoneValueException` 而不是 `MultipartException`
- **描述**：带引号的 boundary 是 RFC 2046 允许的写法，带 `charset`/其他参数的 Content-Type 也很常见；这些请求会全部解析失败。异常类型还泄漏了内部 `Option` 细节
- **建议**：用 `MediaType`/`ContentType` 的参数解析（或正则 `(?i)boundary\s*=\s*(?:"([^"]+)"|([^;]+))`）提取并 `trimAscii()`，去掉引号；失败统一抛 `MultipartException("missing or invalid boundary")`；补 quoted boundary、尾随参数两条用例

### [一般][存量] `ContentDisposition.parse` 的 `filename*` 分支先切片后判空：缺 charset 抛越界，单引号回退解码错误，Base64 解码失败被静默成空文件名

- **位置**：`f_http/src/ContentDisposition.cj:301-310`（`idx1`/`idx2` 与 `value[0..idx1]`）；`f_http/src/ContentDisposition.cj:304`（先取值再判 `idx1 != -1`）；`f_http/src/ContentDisposition.cj:311-323`（Base64 分支 `?? []`）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「空集合 / None 未处理」「错误处理缺失」；`String` 的 Range 下标越界抛 `IndexOutOfBoundsException`（`stdlib/.../core_package_structs.md:9380-9405`）
- **证据**：静态确定 —— `filename*=`（空值）或 `filename*=abc`（无单引号）时 `idx1 == -1`，304 行先执行 `value[0..-1]`（越界切片，或空串交给 `Charsets.forName(...).getOrThrow()`），无论哪种都会先抛异常，307-310 的「US ASCII 回退」永远到不了；只有一个单引号（`UTF-8'abc`）时 `idx1 != -1 && idx2 == -1` 走到 else，却把 `UTF-8'abc` 整串交给 `decodeFilename(..., WINDOWS_1252)`，文件名变成 `UTF-8'abc`；`fromBase64String(matched) ?? []` 把非法 Base64 静默成空文件名，且 316 行读出的 charset 被 `let _ =` 丢弃
- **描述**：畸形但可出现的 `filename*` 参数会让整包解析抛越界异常（不是 `MultipartException`），或静默给出错误文件名；RFC 2047 的 charset 也未被使用，非 UTF-8 的 encoded-word 会乱码
- **建议**：先算 `idx1`/`idx2` 并校验 `idx1 >= 0 && idx2 > idx1`，不满足时抛明确异常（或回退整串为普通 filename）；`filename*` 的 charset 通过 `setCharset` 写入返回的 `ContentDisposition`；Base64 失败保留原值或抛异常；`matchString(1)` 用于创建对应 `Charset` 解码器

### [一般][存量] `filename*` 的 charset 解析后被丢弃：`getCharset()` 恒为 `None`，parser 三个 charset 分支是死代码，文件 part 永远按 UTF-8 读

- **位置**：`f_http/src/ContentDisposition.cj:349-357`（构造 `ContentDisposition` 时不传 `charset`）；`f_http/src/MultipartFormDataParser.cj:137-141/176-180/207`（`contentDisposition.getCharset()`）；`f_http/src/MultipartFile.cj:22`（默认 `Charsets.UTF8`）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §1「恒假分支」、§11「数据错误」、§14「只做了一半」
- **证据**：静态确定 —— `parse()` 的局部变量只有 `name/filename/size/creationDate/modificationDate/readDate`，没有 `charset`，返回对象也就永远 `None`；因此 parser 中 `if(let Some(charset) <- contentDisposition.getCharset())` 的三处分支永不执行，`MultipartFile(... charset: contentDisposition.getCharset() ?? Charsets.UTF8)` 永远取 UTF8
- **描述**：客户端发 `filename*=GBK''...` 时字节被正确解码成 `filename`，但 charset 丢失；后续若把该 CD 重新编码，中文会以裸 UTF-8 写进 quoted filename。文件 part 的 `Content-Type: text/plain; charset=GBK` 也完全没被用于 `MultipartFile.reader`，`reader` 恒按 UTF-8 解码，中文文本文件乱码
- **建议**：`parse()` 在 `filename*` 分支把 charset 传给构造器（`charset: charset`）；文件分支从 part 的 `Content-Type` 解析 charset 传给 `MultipartFile`；三处 charset 分支要么接上，要么删除；补 GBK filename* 与 GBK 文本文件 `reader` 两条用例

### [一般][存量] Builder 允许无 content 构建，`unsafeZeroValue<InputStream>()` 被 encode/bytes 调用；`value()` 不设 size，`empty`/`size` 对内存 part 错误

- **位置**：`f_http/src/MultipartFormData.cj:47`（`private var content = unsafeZeroValue<InputStream>()`）；`f_http/src/MultipartFormData.cj:53-58`（`value()` 只写 ByteBuffer，不设 size）；`f_http/src/MultipartFormData.cj:85-88`（`build()` 无条件加入）；`f_http/src/MultipartFile.cj:57-61`（`empty` 只看 CD size）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「空值未处理」「契约与实现不符」
- **证据**：静态确定 —— `newPart().name("x").build()` 完全合法（`name` 返回 `This`，`build` 不校验），生成 `MultipartFile` 的 `content` 是零值接口；`MultipartFormData.encode` 的 `copy(input, to: output)` 与 `MultipartFile.bytes()` 会调用零值接口的方法，属于未定义行为（通常直接崩溃）。`value("")` 生成 size 未设置（-1）的 part，`empty` 返回 `false`、`size` 返回 `-1`，与实际 0 字节不符；`file(fileName, content, size: -1)` 同样跳过 size
- **描述**：公开 builder 缺少必填校验，错误用法不在 `build()` 报错而在发送/读取时崩溃；`empty` 与 `size` 的文档语义（0 字节为 empty）对内存 part 不成立
- **建议**：`content` 初始化为 `ByteBuffer()`（空流）或在 `build()` 校验非零值并抛 `IllegalStateException`；`value()` 调 `builder.size(content.size)`；`file(..., size < 0)` 时在写入后按实际长度回填；补「未设 value 直接 build」「空字符串 value」两条用例

### [一般][存量] 文本字段流式分支与 `MediaType.toData(InputStream)` 无上限物化，没有 part/请求大小拒绝路径

- **位置**：`f_http/src/MultipartFormDataParser.cj:164-175`（`byteList.add(all: buf[0..len])` 累积到 `unsafeData()`）；`f_http/src/MultipartFormDataParser.cj:99-221`（全函数无大小/part 数上限）；`f_http/src/MediaType.cj:64-75`（`toData(InputStream)` 读到底进 ArrayList）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §5「一次性物化 / 无界容器 / 无拒绝路径」
- **证据**：静态确定（无上限）＋需实测（峰值与是否被上游 body 限制抵消）—— 单个文本字段可占满请求体全部大小：`ArrayList<Byte>` 按 1.5 倍扩容，`unsafeData()` 返回底层数组的 `[0..size]` 切片（`f_base/src/UnsafeData.cj:24-29`），`String.unsafeUtf8` 又保持该数组存活，1 MB 字段峰值约 2.5 MB；part 数量也没有上限，`parts` 列表随 part 数增长。上游 `ctx.request.body` 是否已有 `maxRequestBodySize` 未在 `f_http` 内体现，`HttpConfig` 也没有对应配置
- **描述**：恶意/误用的超大 text field 或海量小 part 可在解析阶段直接把进程推到 OOM，且错误是 OOM 而不是 4xx；文件分支有落盘，文本分支没有
- **建议**：在 `parse()` 增加可配置的 `maxPartBytes`、`maxParts`（默认值写进 `HttpConfig`，README 列出），超限抛 `MultipartException`/413；文本字段超过阈值时落盘或流式交给下游；`ArrayList` 用 `Content-Length`/剩余窗口预分配；补「1 MB 字段」「1000 个 part」两条边界用例

### [一般][存量] `DataMultipartTuples` / `DataMultipartList` 的 `tryParse/parse/tryFromData/toString` 全部抛 `IllegalAccessException`，`try*` 契约与 `toString` 契约都不成立

- **位置**：`f_http/src/MultipartFormDataParser.cj:245-256`（Tuples）；`f_http/src/MultipartFormDataParser.cj:270-281`（List）；`f_http/src/MultipartFile.cj:51-56`（`parse` 只是 `tryParse` 的 `getOrThrow`，两者都抛）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §3「接口默认空实现 / 静默吞异常」、§11「契约与实现不符」
- **证据**：静态确定 —— `tryParse` 的返回类型是 `?Data`，却无条件 `throw`；`tryFromData` 返回 `Any` 也直接抛；`toString()` 抛异常意味着这些 `Data` 一旦进入日志、异常消息或字符串插值就会二次崩溃（例如 `data.toString()`）。`MultipartFile.parse` 调用同样抛异常的 `tryParse`，是纯冗余包装
- **描述**：这些类型实现了 `Data` 接口但只支持 `add/get/iterator`，任何通用 `Data` 消费者（序列化、日志、`f_data` 转换）都会被打断；`tryParse` 名字承诺「失败返回 None」却被实现成抛异常
- **建议**：`tryParse` 返回 `None<Data>`；`parse` 抛 `DataException("multipart data cannot be parsed from string")`；`tryFromData` 返回 `None`；`toString` 至少输出 `DataMultipartTuples(size=...)` 之类的摘要，不能抛；若确实不支持 `Data` 通用能力，考虑不实现 `Data`（仅实现 `DataMultiparts`），避免误导

### [一般][存量] 嵌套 `multipart/mixed` 未实现：parser 把字段内容转成 String 后调用 `toData(String)`，而 `MultipartMediaType` 只实现了 `toData(InputStream)`

- **位置**：`f_http/src/MultipartFormDataParser.cj:143-149/182-188`（`contentType.toData(value)`，`value: String`）；`f_http/src/MultipartFormDataParser.cj:41-64`（类注释的 nested multipart 示例）；`f_http/src/MultipartMediaType.cj:66-71`（范围外佐证：`toData(Array<Byte>)` 抛 `MediaTypeException`，只有 `toData(InputStream)` 解析）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §14「承诺了但没实现 / 半成品」、§3「开关走进空分支」
- **证据**：静态确定 —— `MediaType.toData(data: String)`（`MediaType.cj:76-78`）转调 `toData(data.toArray())`；`MultipartMediaType` 的 Array 重载直接 `throw MediaTypeException("... does not support current access")`。注释 41-64 行明确展示嵌套 `multipart/mixed` 的报文，但解析该字段时必抛
- **描述**：`MediaTypes` 注册了 `multipart/mixed`，parser 也接受顶层 `multipart/mixed`，但嵌套（form-data 的某个 part 里再套 multipart/mixed）完全不可用，使用者按注释示例会得到 `MediaTypeException`
- **建议**：在字段分支判断 `contentType is MultipartMediaType` 时用 `MultipartFormDataParser(ByteBuffer(value.unsafeBytes()), mediaType, boundary).parse()` 递归解析（注意深度上限），或给 `MultipartMediaType` 补 `toData(Array<Byte>)`；补一条嵌套 mixed 用例；若短期不打算支持，删除注释中的嵌套示例并在 README 标注不支持

### [一般][存量] `MultipartFile.bytes()` / `copyTo()` 是破坏性的一次性读取：落盘 part 取字节会删文件，先 `read()` 再 `bytes()` 返回空/部分

- **位置**：`f_http/src/MultipartFile.cj:103-122`（`copyTo` 的 `finally close()`）；`f_http/src/MultipartFile.cj:123-135`（`bytes` 对 File 调 `copyTo`）；`f_http/src/MultipartFile.cj:100-102`（`read` 推进底层流）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「资源不对称 / 语义与命名不符」、§7「缩短生命周期」的反面
- **证据**：静态确定 —— 对 `File` 分支，`bytes()` → `copyTo()` → `finally close()` → `doClose` 关闭并 `removeIfExists` 文件与空目录，因此 `bytes()` 一旦成功，`MultipartFile` 后续 `read()`、`reader`、`directory`、再次 `bytes()` 全部失败；对 `ByteBuffer` 分支，`bytes()` 返回 `buffer[roffset..woffset]`，`read()` 到 EOF 时 `ByteBuffer.read` 会 `clear()` 复位，导致 `bytes()` 返回空数组（`f_io/src/ByteBuffer.cj:119-131`）
- **描述**：`bytes()` 看起来是无副作用访问器（README 只写「返回字节」），实际会消费/删除上传内容；先做一次 `read()` 再取 `bytes()` 得到空，长度也会与 `size` 不一致。错误只在运行时暴露，且临时文件被提前删除后无法重试
- **建议**：把「读取」与「释放」分开：`bytes()` 不调 `close()`，用 `file.seek(Begin(0))` + 读到底 + 恢复位置（或对 File 走独立只读句柄）；`close()` 保持显式删除；`copyTo` 的 `finally close` 改为由调用方决定（或新增 `copyToAndClose`）；补「file part 先 read 一半再 bytes」「bytes 两次」两条用例

### [一般][存量] `HttpConfig.uploadStoreInMemory` 是死配置：全仓无消费方，parser 永远落盘

- **位置**：`f_http/src/HttpConfig.cj:27`（键名）、`f_http/src/HttpConfig.cj:48-52`（`uploadStoreInMemory` prop）；`f_http/src/MultipartFormDataParser.cj:194-214`（文件分支只落盘）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §1「死配置字段」、§14「接线缺失」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`/`target`）搜索 `uploadStoreInMemory|UPLOAD_STORE_IN_MEMORY` 只命中 `HttpConfig.cj` 自身；parser 没有任何分支读取该 prop，README 也未列出该配置
- **描述**：用户配置 `http_uploadStoreInMemory=true` 后行为完全不变（仍按窗口大小落盘），属于承诺但未接线的能力；反过来，如果这是废弃设计，保留公开配置会误导使用者
- **建议**：二选一——在 parser 文件分支按该配置决定 `ByteBuffer`/`File`（并处理大文件 OOM 上限），或删除常量与 prop 及文档残留；若保留，README 配置段补上并注明默认值与内存上限

### [一般][存量] README（中英）三处与模块不符：把 `f_mvc` 的 `AuthStatus/AuthHandler/AuthParam` 写进 `f_http`、漏 `parse()`/两个配置项、空标题

- **位置**：`f_http/README.md:184-257`（安全段）；`f_http/README.md:138`（标题只剩 `### ` 的空章节）；`f_http/README.md:8-14`（配置段）；`f_http/README.md:263-279`（其他 API）；`f_http/README_en.md:141/187-260/265-281`；对照 `f_mvc/src/AuthHandler.cj:29/55/71`（`AuthStatus`/`AuthHandler`/`AuthParam` 的真实归属），`f_http/src/MultipartFormDataParser.cj:99`（`parse()`）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §13「API / 配置与源码不符」、§14「README 覆盖」
- **证据**：静态确定 —— `f_http/src` 全目录搜不到 `AuthStatus|AuthHandler|AuthParam`，三者定义在 `f_mvc`；`MultipartFormDataParser` 只列了 `static func new(ctx)`，主入口 `parse()` 与公开构造器都没有；`HttpConfig` 的 `http_uploadStoreInMemory`、`http_debugging` 在配置段缺失；`### ` 后面的标题为空
- **描述**：使用者按 README 找不到 `parse()` 的用法，也不知道两个配置项；安全段让人误以为 `f_http` 提供鉴权枚举，实际要引 `f_mvc`。中英两版同步复制了同一批问题
- **建议**：把安全段移到 `f_mvc` 文档或删除；`MultipartFormDataParser` 补 `parse()`、构造器与异常说明；配置段补 `http_uploadStoreInMemory`（含默认 false 与内存上限）和 `http_debugging`；补空标题；中英同步

### [一般][存量] 以「单次短读」作为 EOF 判定：底层流合法的分段读取会被当成报文结束（待确认）

- **位置**：`f_http/src/MultipartFormDataParser.cj:167-174/200-205`（`len < buf.size` 即 `break`）；配合 `f_io/src/RotatableBuffer.cj:26-29/99-105`（`bufferEnd < bufferSize` 被视为数据末尾，短读后不再向底层补读）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「边界 / 流式正确性」、§12.1（跨层契约）
- **证据**：待确认 —— `InputStream.read(buffer)` 只承诺返回「读取的字节数」，不保证填满 `buffer`；`RotatableBuffer` 把任意 `read` 返回值 `< halfBufferSize` 当作流结束（构造函数只读两次），parser 又把 `len < buf.size` 当 part 结束。若 `ctx.request.body` 是 socket 上的非缓冲流，一次 1 KB 请求返回 300 B 就会让后续 700 B 被当作不存在，最终在 `crlf` 读到 `(0,0)` 抛 `MultipartException`。缺的信息：std HTTP server 的 `request.body` 是否保证「要么填满 buffer，要么 EOF」
- **描述**：对真实网络 body，合法的大 multipart 请求可能随机解析失败（短读位置取决于 TCP 分片）；现有测试全部用 `ByteBuffer`（总是填满），无法暴露
- **建议**：`RotatableBuffer` 区分「暂时没有更多数据」与「EOF」，循环 `read` 直到填满窗口或返回 0；parser 只在 `partEnd` 或明确 EOF（底层返回 0 且窗口耗尽）时退出流式循环；补一个「每次只返回 1 B 的 InputStream」用例

## 轻微

### [轻微][存量] `ContentDisposition.hashCode` 缓存不随 setter 失效

- **位置**：`f_http/src/ContentDisposition.cj:175-190`（`private var hash` + 首次计算缓存）；`f_http/src/ContentDisposition.cj:75-154`（全部 setter）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「契约与实现不符」；`Hashable` 要求相等对象 hash 相同
- **证据**：静态确定 —— `hashCode()` 只计算一次，之后 `setName/setFilename/setSize/setCharset/setCreationDate` 等直接改字段，不把 `hash` 复位；先 `hashCode()` 再 `setFilename()` 后，对象已与另一个同内容对象 `==`，但 hash 仍是旧值
- **描述**：`ContentDisposition` 是可变的且实现了 `Hashable`；一旦作为 `HashMap` 的 key 后修改，或用旧 hash 与新对象比较，查找会失败。仓内目前没有把它当 key 的代码，属潜伏契约问题
- **建议**：setter 里把 `hash = 0`（与 `MultipartMediaType` 的缓存写法一致），或去掉缓存；补「hashCode → setFilename → hashCode 改变且与新建等值对象一致」用例

### [轻微][存量] 死代码：包内成员与局部变量无引用、不可达分支

- **位置**：`f_http/src/Multipart.cj:21-25`（`name`）、`f_http/src/Multipart.cj:27-29`（`setName`）；`f_http/src/MultipartFile.cj:62-64`（`setType`）、`83-85`（`setFilename`）、`136-143`（`directory`）；`f_http/src/MultipartFormDataParser.cj:114`（`start += boundaryBytes.size`）、`119`（`l` 未用）；`f_http/src/ContentDisposition.cj:316`（`matchString(1)` 丢弃）；`f_http/src/ContentDisposition.cj:477-493`（`encodeFilename` 第二检查后的编码主体，因 470/474 行必抛而不可达）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §1「无调用者 / 不可达语句 / 读了不用」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`/`target`）搜索 `\.name\b`、`setName(`、`setFilename(`、`setType(`、`\.directory`：`Multipart.name/setName`、`MultipartFile.setType/setFilename/directory` 只有定义处命中（`MultipartFile.setSize` 被 parser 使用，不在列）。`start` 在 114 行自增后，循环第一轮 122 行 `start = stream.offset` 必定覆盖，之前无读取；`l` 解构后未参与任何判断；`m.matchString(1)` 赋给 `_` 后再无使用
- **描述**：这些成员会让读者误以为有外部调用面，也增加维护成本；`Multipart` 是 `abstract sealed` 非 public 类型，其 `public` 成员按硬原则二不构成对外契约
- **建议**：删除 `Multipart.name/setName`、`MultipartFile.setType/setFilename/directory`；`start +=` 与 `l` 改为 `_` 或删除；`matchString(1)` 接入 charset 解析（见「一般」#3/#4）；`encodeFilename` 修复后其后续分支即变为可达，需一并处理

### [轻微][存量] 重复逻辑：字段落库块与 `DataMultipart*` stub 各复制两份

- **位置**：`f_http/src/MultipartFormDataParser.cj:143-154` 与 `182-193`（同一段「按 Content-Type/分支 add」的代码）；`f_http/src/MultipartFormDataParser.cj:245-256` 与 `270-281`（四个 stub 逐字同构）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §2「换控制流 / 字面量复制」
- **证据**：静态确定 —— 两处字段分支仅 `value` 的来源不同（一块来自 `buf`，一块来自 `byteList`），后续 12 行完全相同；`DataMultipartTuples`/`DataMultipartList` 的 `tryParse/parse/tryFromData/toString` 除类型名外逐字相同
- **描述**：两处落库逻辑已经在「filename 是否为空」「Content-Type 是否存在」上复制了同一套分支，后续任何一处修 bug（例如 charset 传递）都容易漏改另一处；stub 复制不带来收益
- **建议**：抽取 `addField(parts, contentDisposition, partHeader, value)` 与 `addFile(parts, part, name)` 两个私有函数；`DataMultipart*` 的 stub 抽到公共基类/工具函数，或按「一般」#7 统一返回 `None`

### [轻微][存量] `ContentDisposition` 的 API 一致性：setter 返回类型不统一、`toString` 无条件追加 CRLFCRLF、`name` 未转义、`size` 与日期错误处理不一致

- **位置**：`f_http/src/ContentDisposition.cj:130-154`（Date 系列 setter 返回 `Unit`，其余返回 `ContentDisposition`）；`196-236`（末尾 `builder.append('\r\n\r\n')`，`name` 直接拼接）；`324-325`（`Int64.parse` 直接抛）vs `326-344`（日期 `try/catch` 忽略）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §10「可读性 / API 设计」、§11「错误处理不一致」
- **证据**：静态确定 —— `setCreationDate(DateTime)` 等 4 个重载无返回值，`setName/setFilename/setSize/setType` 返回 `this`；`toString()` 作为 header 值却总带空行，若被写进响应头会拆行；`name` 含 `"` 或 CRLF 时不转义；`size` 非数字直接抛 `NumberFormatException` 使整包失败，日期非 RFC1123 则静默 `None`
- **描述**：链式调用在日期 setter 处断裂；`toString()` 只能用于 multipart body 场景但类型名/文档没有约束；开发者手工设置带引号的 name 会生成非法头；同一个 CD 头里两种参数的错误策略不一致。仓内没有响应头写入路径，故列为轻微
- **建议**：日期 setter 统一返回 `ContentDisposition`；`toString()` 去掉尾部空行，另增 `toStringWithCrlf()` 供 multipart 使用（或文档明确）；`name` 复用 `escapeQuotationsInFilename`；`size` 解析失败时忽略并保留 -1，与日期策略一致

### [轻微][存量] 测试把内部异常固化为契约，且 `encode()`/`input()`/`ContentDisposition` 零覆盖

- **位置**：`f_http/src/MultipartFormDataParser_test.cj:304-309`（`@ExpectThrows[NegativeArraySizeException]`）；`f_http/src/MultipartFormDataParser_test.cj:143-351`（仅 `parse()`）；`f_http/src/MultipartBufferReuse_test.cj`、`MultipartEmptyPart_test.cj`（同样只测 `parse()`）
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §14「示例/测试覆盖不足」、§11「契约与实现不符」
- **证据**：静态确定 —— 304 行注释明确写「现状：headerLen = -1 ... 由 Array<Byte>(负数) 抛出」，测试因此把 `NegativeArraySizeException` 当作对外行为；而畸形 multipart 的契约应是 `MultipartException`。全部分 `.cj` 搜索 `encode(`、`input()` 在 `*_test.cj` 中零命中，`ContentDisposition` 无任何测试文件
- **描述**：这层测试锁住了「内部实现细节」而非协议契约，导致「一般」#1 的 NegativeArraySize 无法被修；输出侧（`input()` 的严重缺陷）与 CD 的编码/解析（`encodeFilename` 必抛）长期无覆盖
- **建议**：把 304-309 改为断言 `MultipartException`；新增 `MultipartFormData_encode_test`（encode → parse 往返、单/多 part、中文 filename、空 part）与 `ContentDisposition_test`（parse/toString 往返、filename*、引号/转义、非法输入）；补恶意 filename 用例（见严重 #1）

### [轻微][存量] `MediaTypes.register` 同名静默覆盖，与 fountain 基线「同名注册启动失败」不一致

- **位置**：`f_http/src/MediaTypes.cj:34-37`
- **来源**：存量（blame 4be871f2f）
- **判据**：`fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）启动直接失败，不做隐式优先级」；review-checklist §14「接线 / 注册」
- **证据**：静态确定 —— `mediaTypes[mediaType.mediaType] = mediaType` 对已存在的键直接覆盖，无返回值、无日志（只有 debug 行），后注册者静默获胜；`static init()` 先注册内置类型，bean 工厂后注册，顺序决定结果
- **描述**：用户自定义 `application/json` 实现会无声替换内置实现，排查时只能靠 debug 日志；两个自定义 bean 同名时也没有冲突提示。注意：若「允许覆盖内置类型」是有意设计，则应显式文档化，而不是与基线约定相反
- **建议**：`register` 检查键是否存在，已存在时抛 `IllegalArgumentException`（或至少 `log.warn` 并在文档写明覆盖语义）；内置注册与 bean 注册分两个入口，后者允许覆盖需显式开关

### [轻微][存量] `parse()` 异常退出时不关闭已打开的落盘 `File`

- **位置**：`f_http/src/MultipartFormDataParser.cj:195-214`（`File` 打开后无 `try/finally`）；后续 part 的头解析/`read` 抛异常时直接跳出 `while`
- **来源**：存量（blame 4be871f2f）
- **判据**：review-checklist §11「资源不对称」
- **证据**：静态确定（持有路径：局部变量 `file` → `MultipartFile.content` → `parts` 返回；异常时 `parts` 丢弃，只能等 `MultipartFile.~init` 的 GC 终结器关闭/删除）—— 解析中途失败时，已创建的 `File` 句柄和临时文件在 GC 前不会释放；高并发畸形请求可能耗尽 fd
- **描述**：正常路径由调用方 `close()`，异常路径没有确定性清理；终结器只保证「最终」删除，不保证及时，且终结器里的 `doClose` 对 `Resource` 分支不吞异常
- **建议**：`parse()` 用 `try { ... } catch (e) { 关闭并删除本次已创建的 files; throw e }`；或维护 `openedFiles` 列表并在 `parse` 的 `finally` 中按成功/失败决定是否清理；补一条「第二个 part 头畸形，第一个文件已落盘」的用例断言目录为空

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `MediaTypes.doTryParse` 的 debug 时间戳/线程 id 与 map 查找在多 part 表单中占比可观 | `f_http/src/MediaTypes.cj:61-80` | 该函数自耗时占比、每 part 调用次数 | `cjprof record` 解析 10k part，`-O2`；对照 `debugEnabled` 守卫版本 |
| 2 | 文本字段 `ArrayList<Byte>` 扩容与 `unsafeData` 容量残留抬高大字段峰值 | `f_http/src/MultipartFormDataParser.cj:164-175` | 1/8/64 MB 字段的峰值堆与分配量 | `getAllocatedHeapSize()` + RSS，10 轮中位数，改前/改后对照 |
| 3 | `parse()` 无条件 `UUID.random().toString()` + `Path.join` 在纯字段表单上是可省开销 | `f_http/src/MultipartFormDataParser.cj:101` | 每请求分配字节数与耗时 | 分配采样 + 1 万次纯字段 parse 的分段计时 |
| 4 | `ContentDisposition.tokenize` + `split('\r\n')` 的临时字符串在 100+ part 时带来明显 GC 压力 | `f_http/src/ContentDisposition.cj:360-397`、`MultipartFormDataParser.cj:128` | 每 part 分配量、GC 次数 | `cjprof heap`，100/1000 part 两档 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_http/README.md` | .md | ✅ | 见「一般」README 三处不符、空标题；安全段属 `f_mvc` |
| 2 | `f_http/README_en.md` | .md | ✅ | 与中文版同步复制同一批问题 |
| 3 | `f_http/doc/spec/reuse-multipart-parse-buffers/design.md` | .md | ✅ | 归档变更记录；D3「各自 UUID 子目录」与实现不符（见严重 #4），空 part 结论已被后续测试覆盖，按归档不单独判 |
| 4 | `f_http/doc/spec/reuse-multipart-parse-buffers/proposal.md` | .md | ✅ | 归档变更记录，动机与代码现状一致（header 不复用、chunk 复用） |
| 5 | `f_http/doc/spec/reuse-multipart-parse-buffers/specs/http-multipart/spec.md` | .md | ✅ | 归档验收口径；截断报文抛 `MultipartException` 已被 `testMissingClosingBoundary` 覆盖，header 截断场景例外见「一般」#1 |
| 6 | `f_http/doc/spec/reuse-multipart-parse-buffers/specs/io-rotatable-buffer/spec.md` | .md | ✅ | 描述 `f_io` EOF 截断；实现与 spec 一致（范围外文件，仅核对语义） |
| 7 | `f_http/doc/spec/reuse-multipart-parse-buffers/tasks.md` | .md | ✅ | 历史任务清单（26 条用例）；后续新增 `MultipartEmptyPart_test` 未回写，按归档不判 |
| 8 | `f_http/src/ContentDisposition.cj` | .cj | ✅ | 严重 encodeFilename；一般 filename*/charset；轻微 hashCode/API 一致性 |
| 9 | `f_http/src/ContentDispositionBuilder.cj` | .cj | ✅ | 纯转发，未发现独立缺陷；CD setter 的返回类型不一致见轻微 |
| 10 | `f_http/src/ContentDispositionType.cj` | .cj | ✅ | `parse` 大小写敏感（RFC token 大小写不敏感），归入「一般」#1 的头解析问题；其余正确 |
| 11 | `f_http/src/HttpConfig.cj` | .cj | ✅ | `uploadStoreInMemory` 无消费方（一般）；`halfBufferSize` 有消费方 |
| 12 | `f_http/src/MediaType.cj` | .cj | ✅ | `toData(InputStream)` 全量物化（一般 #6 的次要位置）；无独立严重问题 |
| 13 | `f_http/src/MediaTypes.cj` | .cj | ✅ | 注册失败死锁（严重）、同名静默覆盖（轻微）、debug 开销（优化/假设） |
| 14 | `f_http/src/Multipart.cj` | .cj | ✅ | `name`/`setName` 仓内无引用，死代码（轻微） |
| 15 | `f_http/src/MultipartBufferReuse_test.cj` | .cj | ✅ | 5 条用例；只覆盖 `parse()`，未覆盖 `encode/input`；测试本身无缺陷 |
| 16 | `f_http/src/MultipartEmptyPart_test.cj` | .cj | ✅ | 9 条空 part 用例；说明空 part 已可用，旧 design 结论过期（归档不判） |
| 17 | `f_http/src/MultipartFile.cj` | .cj | ✅ | `bytes/copyTo` 破坏性（一般）、`empty` 对内存 part 错误（一般）、`directory/setType/setFilename` 死代码（轻微） |
| 18 | `f_http/src/MultipartFormData.cj` | .cj | ✅ | `input()` 状态机（严重）、builder 零值 content（一般） |
| 19 | `f_http/src/MultipartFormDataParser.cj` | .cj | ✅ | 路径穿越（严重）、同目录覆盖（严重）、头/boundary 解析、OOM、嵌套 mixed、短读假设 |
| 20 | `f_http/src/MultipartFormDataParser_test.cj` | .cj | ✅ | 21 条回归；`testHeaderWithoutDoubleCrlf` 把内部异常固化为期望（轻微）；未覆盖恶意 filename/超长 header |

合计：`.cj` 13 个 / `.md` 7 个 / 共 20 个，全部读完（本部分不含 `MultipartMedia.cj`、`MultipartMediaType.cj`、`TextMediaType.cj`、`exception/*.cj`、`rfc.cj`，归第 2 部分）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 12 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 24 条（严重 5 + 一般 12 + 轻微 7），全部只报不修，是否纳入修复待用户决定。

**范围外提示（不计入统计）**：`rfc.cj`（第 2 部分）`parseRfc1123` 只取时区字符串前两个字符（`+0800` → `+0`、`GMT` → `GM`），`ContentDisposition` 的 creation/modification/read-date 解析出的时区会错甚至抛异常；`f_io.RotatableBuffer` 的单次短读即视为 EOF 是「一般 #12」的上游成因，需与 `f_io` 报告合并处理。

## 总评

`f_http` 的 multipart 解析主路径（浏览器常见的 `Content-Disposition: form-data; name=...` + 小字段 + 单文件）能跑通，`chunkBuf`/`crlf` 复用、header 精确分配、落盘分支的写法是清醒的，注释也解释了「为什么 header 不能复用」。但**离生产可用还差一层安全与边界硬化**：

- **阻塞项**：①客户端 filename 直接拼进落盘路径，`Path.join` 官方文档已说明不处理 `..`，这是任意文件写入；②`MultipartFormData.input()` 的公开 API 是坏的（终止符、最后 part 越界、内容 EOF 返回 0），而 `f_httpclient` 正在调用；③`ContentDisposition.encodeFilename` 条件写反，`filename*` 永远抛异常；④所有落盘 part 共用一个目录和客户端文件名，同名上传会静默串内容；⑤`MediaTypes` 注册失败会让后续所有 multipart 请求永久等待。这五条都只看代码即可确定，且没有一条被现有测试覆盖。
- **应排期**：part 头大小写/顺序/超长、boundary 引号、`filename*` 越界、charset 丢失、无大小上限、`DataMultipart*` 的 `try*`/`toString` 契约、嵌套 mixed、`bytes()` 的破坏性语义、`uploadStoreInMemory` 未接线、README 错把 `f_mvc` 的安全类型写进来。
- **工程判断**：这个模块的测试是「事后补的回归网」，只覆盖 `parse()` 的 happy path，`encode()`/`input()`/`ContentDisposition`（解析与序列化）完全没有用例，所以输出侧的两个严重缺陷能长期存在。建议先补 `encode ↔ parse` 往返测试、恶意 filename/超长 header/多同名文件三组负向用例，再按上面的阻塞项修复；修完后 `input()` 与 `encode()` 应能互为验证。

性能与内存方面没有可用的基线数据，报告只给了 2 条待验证方案与 4 条假设，未做任何「能降 X%」的结论。
