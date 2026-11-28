# f_http 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_http`（模块共 20 个 `.cj`；本部分 15 个，其余 5 个见第 2 部分）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce643a`，工作区干净）；快照模式无 diff，全部缺陷记「存量」
- **审查重点**：multipart 解析 / 媒体类型 / Content-Disposition 的边界与内存、按不可信长度预分配、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，后续与第 2 部分合并为 `f_http_review_20261128.md`）

## 发现

### [严重][存量] `encodeFilename` 判断取反，任何非 ASCII filename 序列化必抛异常

- **位置**：`src/ContentDisposition.cj:469-476`（调用点 `src/ContentDisposition.cj:206-215`）
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §11（语义与注释 / 错误消息不符）、§10 正确性
- **证据**：静态确定 —— 第 470 行是 `if (!charset.nameEquals(US_ASCII)) { throw IllegalArgumentException("US_ASCII does not require encoding.") }`；随后第 474 行 `if (!(isUtf8 || charset.nameEquals(ISO_8859_1)))` 又对剩余 charset 抛错。两条守卫合起来使该函数对**任何** charset 都抛异常。
- **描述**：`toString()` 只有在 `charset` 非空且非 US-ASCII 时才会走 `filename*=` 分支（第 207 行），因此 `ContentDisposition().setCharset(Charsets.UTF8).setFilename("中文.txt").toString()` 必然抛 `IllegalArgumentException`，RFC 5987 输出路径完全不可用。该分支没有任何测试覆盖，缺陷因此长期未暴露。
- **建议**：把守卫改为 `if (charset.nameEquals(US_ASCII)) throw ...`（或直接删除，由调用方保证），保留 UTF-8 / ISO-8859-1 白名单；补 `setCharset(UTF8) + 中文 filename → filename*=UTF-8''...` 的往返用例（`parse(toString())` 等价）。

### [严重][存量] `MultipartFileInputStream` 状态机把终止分隔符用在每个 part，且最后一个 part 后数组越界

- **位置**：`src/MultipartFormData.cj:117-127`（`124` 终止符、`125` 下标）；同类正确实现见 `src/MultipartFormData.cj:30-40`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §11（边界越界 / 契约与实现不符）、§2（两套序列化实现行为漂移）
- **证据**：静态确定 —— `case CRLF_Boundary` 固定产出 `'\r\n--${boundary}--\r\n'`（第 124 行，即 RFC 的**结束**分隔符），`case Next => Current(idx + 1, data.parts[idx + 1], ...)`（第 125 行）无条件取下一个 part。
- **描述**：① 多 part 时每个 part 后都输出 `--boundary--`，服务端会把它当作报文结束，后续 part 全部丢弃（静默数据丢失）；② 最后一个 part 走 `Next` 时 `data.parts[idx + 1]` 越界，`f_httpclient` 的 `MultipartFormDataBuilder.post()/put()`（`f_httpclient/src/httpclient.cj:231-244`）在发送完内容后必抛 `IndexOutOfBoundsException`；③ `parts` 为空时 `case Start` 的 `data.parts[0]`（第 96 行）同样越界；④ 本类自递归 `read(buf)`，1000 个 part 约 6k 栈帧。README（`README.md:160-166`）把它列为公开能力，实际不可用。
- **建议**：为状态机增加结束态：`CRLF_Boundary` 只输出 `\r\n--boundary`，`Next` 时若 `idx + 1 >= parts.size` 则输出 `--\r\n` 并返回 0，否则输出 `\r\n` 后进入下一 part；`parts.isEmpty()` 直接返回 0；或者删掉这套实现，用 `encode()` 的迭代器包装成 `InputStream`（`encode()` 的格式是正确的），并补 `input()` 的单 part / 多 part / 空表单用例。

### [严重][存量] 上传文件名未净化，可路径穿越写到 uploadDir 之外

- **位置**：`src/MultipartFormDataParser.cj:198`（`filename` 来自 `src/MultipartFormDataParser.cj:130`，源头是 `ContentDisposition.parse`）
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §10 安全性（外部输入未校验）、§11 安全
- **证据**：静态确定 —— `filename` 原样来自报文 `Content-Disposition`（`ContentDisposition.parse` 不做 basename 处理），第 198 行直接 `File(path.join(filename), ReadWrite)`。std 文档明确 `Path.join` 只拼接字符串、**不处理 `..`**（`std/fs/fs_package_structs.md:1625` 的「注意」段），绝对路径入参会抛 `FSException`。
- **描述**：`filename="../../../../etc/cron.d/x"` 或 `filename="a/../../../x"` 可写到 `/tmp/fountain/upload/<uuid>/` 之外，覆盖进程有权限的任意文件；`filename="/etc/passwd"` 会抛未捕获的 `FSException`（500）。同一请求内重名 filename 还会互相覆盖（见「文件 part 落盘」一条）。
- **建议**：落盘名取 `Path(filename).fileName` 并剔除 `/`、`\`、`..`、NUL 与控制字符，长度截断到 255；更稳妥的是服务端用 UUID 作落盘名、原始名只存进 `ContentDisposition`；落盘后 `canonicalize` 并断言前缀仍是本请求目录。

### [严重][存量] `MediaTypes` 注册抛异常时状态永久停在 -1，所有后续解析线程永久等待

- **位置**：`src/MediaTypes.cj:41-55`
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02）
- **判据**：review-checklist §12.1（死锁 / 条件等待未重查条件）、§11 并发正确性
- **证据**：静态确定 —— `compareAndSwap(0, -1)` 成功后调用 `register(BeanFactory.instance.getList<MediaType>())`，该调用没有 `try/finally`；失败时 `mediaTypeBeansRegistered` 永远保持 `-1`，且不会 `notifyAll`。等待分支是单次 `condition.wait()`（无超时、不在 `while` 中重查）。
- **描述**：任一 `MediaType` bean 构造失败（BeanFactory 抛错）后，所有进入 `MediaTypes.tryParse` 的请求线程都会阻塞在 `condition.wait()` 上且无人唤醒，HTTP 媒体类型解析整体挂死；即使没有异常，虚假唤醒也会带着未完成的注册表继续工作。
- **建议**：`try { ... } finally { store(1 或 -2); synchronized(mutex){ condition.notifyAll() } }`；失败态缓存并让后续调用直接抛明确异常；等待改为 `while (load() == -1) { condition.wait(timeout: ...) }` 并对超时抛错。

### [严重][存量] 请求体 / multipart 字段全量物化，全模块没有任何大小上限

- **位置**：`src/MediaType.cj:64-75`（`toData(InputStream)`），`src/MultipartFormDataParser.cj:165-175`（文本字段流式分支）、`124/134`（按报文长度新建数组）、`115-219`（part 数无上限）
- **来源**：存量（`git blame` 4be871f2fd，2026-10-02；`124/134` 在 eb36d4e8e8 2026-11-22 重写但语义未变）
- **判据**：review-checklist §5（一次性物化 / 按不可信长度预分配 / 无界容器）
- **证据**：静态确定 —— `MediaType.toData(InputStream)` 用 `ArrayList<Byte>` 循环 `add(all: buf[0..len])` 直到 EOF；`MultipartFormDataParser` 文本字段分支同样累积到 `byteList`；`HttpConfig` 只有 `halfBufferSize` / `uploadDir`，全仓（`f_http`/`f_net`/`f_mvc`）grep 不到 `maxBody` / `contentLength` / 请求体上限检查。
- **描述**：`@RequestBody` 对 `text/plain` 或任何未覆写 `toData(InputStream)` 的媒体类型（`JsonMediaType` 有自己的实现，见 `TextMediaType.cj:110-116`）会把整个请求体读进内存：1 GB 请求体 ≈ 1 GB 常驻 + 扩容峰值；multipart 的一个 1 GB 文本字段同样全量进 `ArrayList<Byte>`，再 `unsafeData()` 交给 `Data`；part 数量也不设上限，每个文件 part 一个 FD + `MultipartFile`。并发 10 个此类请求即可打满容器内存。
- **建议**：新增 `http_maxBodySize`（默认几 MB）与 multipart per-part 上限，超限抛 413/`MultipartException`；`toData(InputStream)` 在 `Content-Length` 已知时一次分配、未知时边读边判上限；文本字段超过阈值改为落盘（与文件 part 同路）。

## 发现（一般）

### [一般][存量] `ContentDisposition.parse` 的 RFC 5987 / RFC 2047 处理有多处边界缺陷

- **位置**：`src/ContentDisposition.cj:301-310`（`filename*`）、`311-323`（RFC 2047）、`324-325`（size）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（边界 / 错误处理）
- **证据**：静态确定
- **描述**：
  1. 第 304 行在判断 `idx1 != -1` **之前**就执行 `value[0..idx1]`：`filename*` 里没有 `'` 时 `idx1 = -1`，切片直接抛越界，第 305 行的 `idx1 != -1` 分支实际不可达；
  2. 第 304 行 `Charsets.forName(...).getOrThrow()`：未知 charset 抛 `NoneValueException`，不是 `IllegalArgumentException`；
  3. 第 307-310 行的回退分支只在 `idx2 == -1` 时进入，此时 `value` 仍是 `charset'lang'...` 整串，却整串拿去 `decodeFilename`，结果必然错误；
  4. 第 312-320 行处理 `=?charset?B?...?=` 时 `let _ = m.matchString(1)` 丢弃 charset，固定按 UTF-8 `unsafeUtf8` 解码 → GB2312/ISO-8859-1 文件名乱码；`fromBase64String` 失败时 `?? []` 得到空 filename，文件 part 会被降级成普通文本字段；
  5. 第 325 行 `Int64.parse(value)` 对非数字 `size` 抛 `NumberFormatException`，未按可选参数忽略。
- **建议**：先校验 `idx1/idx2` 再取 charset，失败时回退 `filename` 原值；RFC 2047 用捕获到的 charset 解码；`size` 用 `tryParse` 失败即忽略；补畸形 `filename*`（无引号、未知 charset、坏 base64）用例。

### [一般][存量] `parse` 丢弃 `filename*` 的 charset，`getCharset()` 解析后恒为 `None`

- **位置**：`src/ContentDisposition.cj:349-357`（构造时未传 `charset`）、`107-113`（文档承诺）、`src/MultipartFormDataParser.cj:137/176/207`（依赖 `getCharset()`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（契约与实现不符）、§13 同类（源码注释即契约）
- **证据**：静态确定 —— 第 304 行拿到了 charset，但第 349-357 的构造调用没有 `charset:` 实参；`getCharset` 注释写「Return the charset defined in filename* parameter」。
- **描述**：解析 `filename*=UTF-8''%E4%B8%AD.txt` 后 `getCharset()` 返回 `None`，`toString()` 会退回 `filename="..."` 明文（编码信息丢失，往返不等价）；parser 的三个分支也因此永远走 `String.unsafeUtf8`，声明了 `charset=` 的 part 正文被忽略。
- **建议**：`parse` 把 `filename*` 的 charset 写入 `charset` 字段；parser 直接用该字段决定正文解码；补「非 UTF-8 正文 + filename*」用例。

### [一般][存量] `hashCode` 缓存不随 setter 失效，可变对象当哈希键会查不到

- **位置**：`src/ContentDisposition.cj:175-190`（`private var hash`）、`75-154`（全部 setter 均返回 `this` 且不重置 `hash`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（契约与实现不符）、§12.1（可见性）
- **证据**：静态确定 —— `hash == 0` 时计算并缓存，任何 `setType/setName/...` 都不把 `hash` 复位；`hash` 是普通字段，多线程首次计算是数据竞争（结果同值、但字段非原子）。
- **描述**：`ContentDisposition` 同时是 `Hashable` 且可被 builder 就地修改。放进 `HashMap` 后再 `setFilename(...)`，`hashCode` 返回旧值 → `get` 命中不到，表现为「键丢了」。若被多线程共享并在计算 `hashCode` 时被修改，读到的是撕裂的字段组合。
- **建议**：要么去掉缓存（字段只有 8 个，`HashBuilder` 开销可控），要么在每次 setter 里 `hash = 0`；同时在类注释里明确「不要在多线程共享实例上修改」。

### [一般][存量] `toString` 的 quoted-string 转义不完整，且固定追加 `\r\n\r\n`

- **位置**：`src/ContentDisposition.cj:196-235`（`name` 未转义、末尾 `\r\n\r\n`）、`438-459`（`escapeQuotationsInFilename`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §10 安全性（注入）、§11（语义与注释不符）
- **证据**：静态确定 —— 第 201-205 行把 `name` 原样塞进双引号，不转义 `"`、`\`、CR/LF；第 235 行无条件 `append('\r\n\r\n')`；第 444-451 行只把 `"` 转成 `\"`，反斜杠原样输出，靠第 454-455 行「末尾反斜杠截掉」兜底。
- **描述**：`name` 来自请求报文又会被 `MultipartFormData.encode()` / `MultipartFileInputStream` 回写进 multipart 首部，攻击者可用 `name="x\"\r\nContent-Type: ...\r\n"` 注入额外首部或伪造 part 边界；filename 含 `\` 时生成的 quoted-string 非法（`a\b` 应为 `a\\b`），末尾 `\` 被吞掉导致文件名改变。`toString()` 的返回值同时被当「首部值」和「part 首部块」使用，语义混淆。
- **建议**：抽 `quoteHeaderValue(s)` 统一转义 `"`、`\`、CR、LF（CR/LF 直接拒绝或替换）；`name` 也走同一转义；把「part 首部块」的 `\r\n\r\n` 从 `ContentDisposition.toString()` 移到 multipart 编码处。

### [一般][存量] parser 首部解析硬编码前缀与行序，畸形输入抛原始异常而非 `MultipartException`

- **位置**：`src/MultipartFormDataParser.cj:123-129`（`Content-Disposition: ` 定长切片）、`143/182`（`partHeader[1]`）、`124`（负长度数组）
- **来源**：存量（4be871f2fd；`124` 为 eb36d4e8e8）
- **判据**：review-checklist §11（边界 / 错误处理 / 契约）
- **证据**：静态确定 —— 第 129 行 `partHeader[0]['Content-Disposition: '.size ..]` 依赖首行恰为该大小写、恰有一个空格且是第一个首部；`indexOf(DOUBLE_CRLF)` 返回 `-1` 时 `end - start + 4 < 0`，`Array<Byte>(负数)` 抛 `NegativeArraySizeException`（`MultipartFormDataParser_test.cj:305-309` 已把该行为写成期望）。
- **描述**：`content-disposition:`（RFC 首部名大小写不敏感）、`Content-Type` 在 `Content-Disposition` 之前、首部无空格等合法变体都会让切片错位，随后 `ContentDisposition.parse` 抛 `IllegalArgumentException`/`NoneValueException`，最终 HTTP 层返回 500 而非 400；缺 `\r\n\r\n` 直接以运行时内部异常（`NegativeArraySizeException`）的形式冒泡。
- **建议**：逐行解析首部（`:` 切分 + 名字 `toAsciiLower` 比较），只取 `content-disposition` 行；`DOUBLE_CRLF` 缺失抛 `MultipartException` 并更新那条测试期望；所有解析异常在 `parse()` 边界统一转 `MultipartException`。

### [一般][存量] `MultipartFileBuilder.build()` 允许未设置内容，`value(Array<Byte>)` 超过约 80 B 会越界

- **位置**：`src/MultipartFormData.cj:46-48`（`unsafeZeroValue<InputStream>()`）、`85-88`（无校验）、`53-57`（`value(Array<Byte>)`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（空值未处理 / 边界）、§3（半成品）
- **证据**：静态确定 —— `content` 初值是 `unsafeZeroValue<InputStream>()`（空引用），`build()` 不检查是否调用过 `value`/`file`；`value` 往默认容量 32 的 `ByteBuffer` 里一次 `write` 整个数组，而 `ByteBuffer.write`（范围外文件 `f_io/src/ByteBuffer.cj:145-152`）只在写入前 `grow()` 一次（容量变为 80），单次写入超过 80 B 时 `copyTo` 越界。
- **描述**：`newPart().name("n").build()` 得到一个内容为空引用的 part，`encode()`/`input()` 时崩；`newPart().value(longText)`（超过 80 字节）直接抛数组越界，公开 API 的正常用法就会失败。
- **建议**：`build()` 校验 `content` 已赋值，否则抛明确的 `IllegalStateException`；`value` 改用 `ByteBuffer(initialCapacity: content.size)` 或分块写；`ByteBuffer.write` 的扩容不足问题单独在 `f_io` 修（见「范围外提示」）。

### [一般][存量] 文件 part 落盘：同名互相覆盖、含子目录名失败、写异常泄漏 FD

- **位置**：`src/MultipartFormDataParser.cj:195-208`
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（资源不对称 / 边界）、§10 正确性
- **证据**：静态确定 —— 同一请求共用 `path`（第 101 行 UUID 目录），第 198 行 `File(path.join(filename), ReadWrite)`；循环内 `file.write` 抛异常时没有 `try/finally` 关闭 `file`，`MultipartFile` 也尚未创建（其 `~init` 不会兜底）；文件名含 `/` 时父目录未创建。
- **描述**：两个 part 用同一 filename 时第二个写入会覆盖/交错第一个（且第一个 `MultipartFile` 仍指向同一路径，读到的是被改过的内容）；`filename="a/b.bin"` 因目录不存在抛 `NotFoundException`（500）；磁盘满等写入异常会漏掉一个 FD 与半截文件（请求目录留在 `/tmp`）。
- **建议**：落盘名加唯一后缀（或直接 UUID + 原名校验后保留）；`try { ... } catch { file.close(); throw }`；写入前 `Directory.create(parent, recursive: true)` 或在文件名规范化时拒绝路径分隔符。

### [一般][存量] 文件 part 的 `Content-Type` 被丢弃，`MultipartMedia` 设计好的 `mediaType` 从未接线

- **位置**：`src/MultipartFormDataParser.cj:143`（只对字段用）、`155-163`（文件 part 只传 `contentDisposition`）；`src/MultipartMedia.cj:18-60`（零构造点）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §14.1（接线缺失）、§11（信息丢失）
- **证据**：静态确定 —— 全仓 grep `MultipartMedia(` 只命中定义处；parser 解析出的 `Content-Type` 只参与字段分支的 `contentType.toData(value)`，文件分支构造 `MultipartFile(contentDisposition, ...)` 不带媒体类型，`MultipartFile` 也没有该字段。
- **描述**：上传图片/PDF 后业务侧拿不到声明的 MIME 类型，只能靠扩展名猜；为携带媒体类型而写的 `MultipartMedia` 完全没被 parser 使用（公开类、仓内零引用），属于「设计了但没接线」。
- **建议**：给 `MultipartFile` 增加 `mediaType: ?MediaType` 并在 parser 文件分支填入；或者让文件 part 产出 `MultipartMedia`；若确认不用 `MultipartMedia`，在 README 中移除或在类注释说明用途。

### [一般][存量] 媒体类型注册静默覆盖、`tryParse` 会抛异常、查找不健壮

- **位置**：`src/MediaTypes.cj:34-37`（覆盖）、`56-84`（`tryParse`→`make` 抛）、`63-80`（前缀查找）；`src/MultipartMediaType.cj:47-61`（`make`）
- **来源**：存量（4be871f2fd）
- **判据**：fountain-baseline §4（同名注册应启动失败）、review-checklist §11（契约不符：`tryParse` 不 try）
- **证据**：静态确定 —— `mediaTypes[mediaType.mediaType] = mediaType` 无重复检查；`doTryParse` 末尾 `?.make(mediaType)`，而 `MultipartMediaType.make` 对 `multipart/form-data; charset=utf-8`（无 boundary）抛 `MediaTypeException`，`TextMediaType.doMake` 对不匹配串也抛；前缀分支 `mediaType[0..idx]` 不 `trim`，`"application/json ; charset=UTF-8"` 查不到，大小写敏感。
- **描述**：两个 bean 注册同一 `mediaType` 时后者静默覆盖（违反项目「同名注册启动失败」约定，问题被推迟到运行期）；`MediaTypes.tryParse("multipart/form-data; charset=utf-8")` 抛异常，而 `f_mvc/src/ControllerFuncParam.cj:180-190` 是按「返回 None → 415」写的，异常路径会退化成 500；带空格/大写媒体类型被判为不支持。
- **建议**：`register` 遇已存在键直接抛错（并在 `static init` 与 bean 注册路径都适用）；`tryParse` 内 `try { make } catch { None }`；前缀取 `trimAscii().toAsciiLower()` 后再查，注册键同样规范化。

### [一般][存量] `MultipartMedia` 回退序列化把二进制当 UTF-8 解码，数据被破坏

- **位置**：`src/MultipartMedia.cj:26-31`（`case _ => toString().toData()`）、`44-46`（`none.toDataFields` 抛 `NoneValueException`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（数据错误 / 空值处理）
- **证据**：静态确定 —— 无 `mediaType` 时 `toData()` 走 `toString()`，后者用 `charset.newDecoder().decode(bytes)` 把原始字节解码成字符串再 `toData()`；二进制中的非法序列会被替换，往返后字节不同。
- **描述**：解析出没有 `Content-Type` 的 part（`mediaType == None`）、再调用 `toData()` 时，附件内容被按 UTF-8 转码破坏（典型：0x80-0xFF 连续字节变 `\uFFFD`）；`toDataFields<T>()` 在 `mediaType` 为空时 `getOrThrow()` 抛 `NoneValueException`，不是 `MediaTypeException`。
- **建议**：`case _ => bytes.toData()`（原始字节直接作为 `Data`）；`toDataFields` 用 `match` 返回明确异常（`MediaTypeException("no media type")`）。

### [一般][存量] `Data` / `DataFields` 接口面大量空实现，`toString()` 也直接抛异常

- **位置**：`src/MultipartFormDataParser.cj:245-256`（`DataMultipartTuples`）、`270-281`（`DataMultipartList`）、`src/MultipartMedia.cj:41-43,51-56`、`src/MultipartFile.cj:51-56`
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §3（接口实现为抛异常 / 空实现）
- **证据**：静态确定 —— 两个 struct 的 `tryParse/parse/tryFromData/toString` 一律 `throw IllegalAccessException()`；`MultipartMedia.tryFromData/tryParse` 与 `MultipartFile.tryParse` 一律 `throw MediaTypeException('Not Supported')`。
- **描述**：`parse()` 的返回值就是一个 `DataMultipartTuples`，任何通用代码对它做字符串化（日志、`MediaType.toDataFields` 的错误分支 `data.toString()`，`MediaType.cj:80`）都会抛 `IllegalAccessException`；`Data` 契约中的构造/字符串化能力实际不可用，属于「为满足接口而写的占位」。
- **建议**：`toString()` 至少返回类型名 + 元素个数；确实不支持的 `parse/tryFromData` 返回 `None` 或抛带说明的 `UnsupportedOperationException`，并在类注释写明「只支持 parser 产出、不可反序列化」。

### [一般][存量] `MultipartFile.copyTo` 在 `finally` 里关闭并删除 part，且可能掩盖原异常

- **位置**：`src/MultipartFile.cj:103-122`（`finally { close() }`）、`152-184`（`close` → `doClose` 删文件）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §11（资源语义 / 异常处理）、§10 设计
- **证据**：静态确定 —— `copyTo` 结束时无条件 `close()`，`File` 分支会 `removeIfExists` 文件并可能删除父目录；`close()` 默认 `toThrow = true`，若拷贝过程中已抛异常，`finally` 里的 `close` 再抛会覆盖原异常。
- **描述**：`copyTo` 名字只承诺「拷贝」，实际隐式销毁数据源：拷到目标文件后再 `read`/`bytes` 会因已关闭而失败；`bytes()` 内部依赖这个副作用，进一步固化了「读一次即毁」的语义，使用者很难预期。
- **建议**：`copyTo` 不负责关闭（由调用方或 `use` 管理），`bytes()` 自己 `try/finally` 关闭；`finally` 里 `close` 用 `try { } catch { }` 保护，避免覆盖主异常；在 README/注释中写清 part 的生命周期。

### [一般][存量] `http_uploadStoreInMemory` 配置项无任何读取方，multipart 永远落盘

- **位置**：`src/HttpConfig.cj:21,27,48-52`；`src/MultipartFormDataParser.cj:195-205`（无条件 `File`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §14.1（配置项被读取却从未使用 / 接线缺失）、§1（死配置）
- **证据**：静态确定 —— 全仓 grep `uploadStoreInMemory` / `UPLOAD_STORE_IN_MEMORY` 只命中 `HttpConfig.cj` 自身的定义，无调用方；parser 文件分支无条件创建文件。
- **描述**：使用者按配置名把 `http_uploadStoreInMemory` 设为 `true` 期望小文件留在内存，实际行为完全不变（仍写 `/tmp`），配置是空承诺；同时 `DEFAULT_UPLOAD_STORE_IN_MEMORY` 也是死常量。
- **建议**：要么在 parser 文件分支按该配置选择 `ByteBuffer`/`File`（并配 per-part 阈值），要么删除这两个公开常量与 prop，避免误导。

### [一般][存量] 三处同语义实现重复且已行为漂移

- **位置**：`src/MultipartFormData.cj:30-40` vs `src/MultipartFormData.cj:90-130`（multipart 序列化两套）；`src/MultipartFormDataParser.cj:136-154` vs `175-193`（字段注册两套）；`src/MultipartFormDataParser.cj:235-241` vs `286-299`（单值展开两套）
- **来源**：存量（4be871f2fd；parser 两分支在 eb36d4e8e8 拆分）
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 近似重复）
- **证据**：静态确定 —— ① `encode()` 输出正确的 `\r\n--b` 分隔符，`MultipartFileInputStream` 输出 `--b--` 且越界（见严重项）；② parser 整块分支（136-154）与流式分支（175-193）除取字节方式外逐行相同（解码 → 取 name → 判断 Content-Type → 四路 `parts` 分派）；③ `get()` 对单值直接返回、不展开 `DataMultipartList`，而 `iterator()` 对单值额外做 `DataMultipartList → DataIterable`，同一份数据两种遍历结果不同。
- **描述**：同一语义存在两份实现，一份修了另一份没修，导致上面的严重缺陷长期存活；第 ③ 处让 `map.get(name)` 与 `for (kv in tuples)` 的形态不一致，调用方需两套拆包逻辑。
- **建议**：序列化只保留 `encode()`，`input()` 包一层迭代器；parser 抽 `addPart(parts, cd, headerLine, bytes)`；统一单值/多值展开规则（并补「单值为 list」用例）。

## 发现（轻微）

### [轻微][存量] 死代码：`Multipart.name` / `Multipart.setName` 与 `MultipartFile` 的三个内部成员无调用者

- **位置**：`src/Multipart.cj:21-29`；`src/MultipartFile.cj:62-64,83-85,136-143`
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §1（`public` 但所属顶层声明非 public → 全项目无使用即死代码；`internal` 无调用者）
- **证据**：静态确定 —— 全仓 grep：`Multipart` 是 `abstract sealed class`（非 public），其 `name` / `setName` 无任何调用；`MultipartFile.setType` / `setFilename` 为 `internal`，仅定义处命中；`prop directory` 亦仅定义处命中。`setSize` 有 parser 调用，`contentDisposition` 被子类使用，均保留。
- **建议**：删除上述 5 个成员；若 `name` 想对外，放到 `MultipartFile` 的 `public` 面并写入 README。

### [轻微][存量] 死存储与「读了不用」

- **位置**：`src/MultipartFormDataParser.cj:109-114`（`start` 赋值后第 122 行被覆盖）、`119`（`let (l, _, _)` 的 `l` 未读）、`286-289`（`v.isEmpty()` 恒假分支）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §1（读了不用 / 恒假分支）
- **证据**：静态确定 —— `start` 只在第 123 行被读取，而第 122 行已重新赋值；`l` 未出现在后续任何表达式；`add()` 只向 map 写入非空 `ArrayList`，`v.isEmpty()` 不可能成立。
- **建议**：删除第 114 行的 `start += ...`（保留第 110-112 行的缺失首边界检查）、用 `stream.read(crlf)` 直接丢弃返回值、删除 `v.isEmpty()` 分支。

### [轻微][存量] `MultipartFileInputStream.read` 自递归，深度随 part 数线性增长

- **位置**：`src/MultipartFormData.cj:93-129`（7 处 `read(buf)` 自调用）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §4（间接递归 / 深度由输入决定）
- **证据**：静态确定 —— 每个状态迁移都递归调用自身，一个 part 约 6 层；深度 ≈ 6 × part 数，且每帧持有 `Array<Byte>` 局部。1000 个 part 约 6k 帧。
- **描述**：客户端构造的 part 数由业务决定、通常很小，故定轻微；若未来开放「按外部清单批量上传」，深度会随条数线性上涨。
- **建议**：改成 `while (true)` 状态循环（`read` 返回 0 即结束），顺带修掉上面的越界问题。

### [轻微][存量] `ContentDispositionBuilder` 是 public 类但没有公开构造入口

- **位置**：`src/ContentDispositionBuilder.cj:18-19`（构造器无修饰符，按语言规范默认 `internal`）
- **来源**：存量（4be871f2fd）
- **判据**：review-checklist §1 硬原则一（不算死代码）→ 记为可用性问题；§14（README 将其列为公开类型，`README.md:180,269`）
- **证据**：静态确定（默认可见性依据官方文档 `docs/dev-guide/source_zh_cn/class_and_interface/class.md:370`「缺省的含义是 internal」）；全仓唯一构造点是 `src/MultipartFormData.cj:46`。
- **描述**：外部使用者无法 `new` 一个 `ContentDispositionBuilder`，只能经 `MultipartFormData.newPart()` 间接使用，README 却把它当独立公开 API 列出；链式 `attachment/inline/formData` 对库外不可达。
- **建议**：给 `ContentDisposition` 加 `public func builder(): ContentDispositionBuilder`（或 `public init(cd: ContentDisposition)`），或从 README 的公开 API 列表中移除。

### [轻微][存量] 测试覆盖缺口，且把「负长度崩溃」固化为期望

- **位置**：`src/MultipartFormDataParser_test.cj:305-309`；`src/MultipartBufferReuse_test.cj`、`src/MultipartEmptyPart_test.cj`（整体覆盖范围）
- **来源**：存量（测试文件 2026 提交，`MultipartFormDataParser_test.cj` 头注写明「f_http 首批测试」）
- **判据**：review-checklist §11（测试锁定错误行为）、§14.1（半成品）
- **证据**：静态确定 —— `testHeaderWithoutDoubleCrlf` 注释与断言都要求 `NegativeArraySizeException`；三个测试文件均未覆盖 `MultipartFormData.input()`、`MultipartFormData.encode()`、`MultipartFormDataParser.new(ctx)`、`ContentDisposition.parse/toString`（含 RFC 5987）。
- **描述**：parser 的缓冲复用覆盖做得不错，但公开的序列化路径与 Content-Disposition 完全无测试，导致 `encodeFilename` 取反、`input()` 越界两个严重缺陷长期未被发现；同时把畸形输入的内部异常固化成期望，阻碍后续改成 400 契约。
- **建议**：补 `input()`（单/多/空 part）、`encode()` 往返、`new(ctx)` 的 boundary 处理、`ContentDisposition` 的 ASCII/RFC 5987/RFC 2047 往返用例；把 `testHeaderWithoutDoubleCrlf` 的期望改为 `MultipartException`。

**范围外提示**：`f_io/src/ByteBuffer.cj:145-152` 的 `write` 只做一次 `grow()`，单次写入大于当前容量 2.5 倍时 `copyTo` 越界（本文件 `value(Array<Byte>)` 会踩到）；`f_io/src/RotatableBuffer.cj:43-69` 的 `indexOf` 不按 `bufferEnd` 截断，窗口尾部残留字节可能被误判为 boundary。两条均属 `f_io` 模块，不计入本部分统计。

## 优化可行性方案

### [堆内存] `MultipartFile.bytes()` 去掉二次拷贝，峰值从约 2N 降到 N

- **现状**：`File` 分支先 `ByteBuffer(initialCapacity: file.length)` 分配 N 字节（`MultipartFile.cj:127`），`copyTo` 写满后再 `buffer.bytes()` 返回 `buffer[roffset..woffset]` 的**切片副本**（`f_io/src/ByteBuffer.cj:56-58`），峰值 ≈ 2N；非 `File` 分支初始 64 KB、按 1.5 倍增长，峰值约 2.5N。一次调用即长期持有整份上传内容。
- **方案**：`File` 分支直接 `let out = Array<Byte>(file.length, repeat: 0)` 后循环 `read` 填满（一次分配、零额外副本）；或提供 `writeTo(OutputStream)` 让调用方流式消费，`bytes()` 只作显式便捷方法。
- **预期**：单次 `bytes()` 峰值内存减半（N 而非 2N）；对 200 MB 上传，峰值从约 400 MB 降到 200 MB。
- **代价**：`bytes()` 语义不变；`copyTo` 不再隐式 `close`（与本报告「copyTo 副作用」一条一起改）。
- **验证**：同输入（200 MB 文件）`getAllocatedHeapSize()` 峰值 + RSS，改前/改后各 10 轮取中位数；`cjpm bench -O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MediaType.toData(InputStream)` 预分配并避免「分块累积 + 整体转换」

- **现状**：`MediaType.cj:64-75` 用 `ArrayList<Byte>` 按 1 KB 分块追加，容量按倍增扩容，最后 `list.unsafeData()`；无 `Content-Length` 感知，未知长度时无上限（与严重项「无大小上限」同源）。
- **方案**：已知长度时一次性 `Array<Byte>(len)` 读满；未知长度时按 `http_maxBodySize` 上限预分配并截断；对 `text/plain` 直接在 `ByteBuffer` 上解码，避免 `ArrayList<Byte>` 中间表示。
- **预期**：单请求临时对象数从「每 1 KB 一次 `add` + 扩容副本」降为 1 次分配；峰值从约 2N 降到 N（不含上限收益）。
- **代价**：需要新增配置项；未知长度路径需要明确的超限异常。
- **验证**：1 KB / 1 MB / 10 MB 三档 body，改前改后 `getAllocatedHeapSize()` 与 `cjprof heap` 分配采样。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ContentDisposition.parse` 每个 part 的字符串切分可降为单趟扫描

- **现状**：`ContentDisposition.cj:280-397` 每个 part 先 `tokenize` 建 `ArrayList<String>`（每段一次 `trimAscii` + `toString`），再对每个属性 `indexOf("=")`、`indexOf("\"")`、多次 `trimAscii`；`filename`/`name` 再各复制一次。一次 multipart 请求每个 part 都走一遍。
- **方案**：在原始 header 串上单趟扫描，遇 `;` 且不在引号内时切属性，属性名/值用 `(start, end)` 偏移传给解析，只在需要时物化 `String`；`name`/`filename` 直接切片，不再经过中间 `ArrayList`。
- **预期**：每 part 的临时 `String` 数量从 O(属性数 × 3) 降到 O(属性数)（仅最终值），GC 压力同步下降；具体降幅需实测。
- **代价**：解析逻辑复杂度上升，需补等价性用例（引号、转义、空值、重复属性）。
- **验证**：`cjpm bench -O2` 解析 10 万 part 的吞吐与 `cjprof record` self time；对比改前/改后中位数与离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | multipart 解析的 CPU 主要花在 `ContentDisposition.parse` 的字符串切分与 `RotatableBuffer` 逐字节 `indexOf` | `src/MultipartFormDataParser.cj:128-131`、`src/ContentDisposition.cj:280-397` | 两个函数的 self time 占比、每 part 调用次数 | `cjprof record` 跑 10k part 的 multipart 报文，`-O2`，统计 self time |
| 2 | `MediaTypes.tryParse` 每请求两次 `ConcurrentHashMap.get` + `log.debug` 闭包分配占比可忽略 | `src/MediaTypes.cj:61-84` | 请求级自耗时、分配量 | 10k 次 `MediaTypes.parse("application/json; charset=UTF-8")` 微基准 + `cjprof heap` |
| 3 | 写盘分支的 `File.write` 1 KB 分块导致系统调用次数偏多 | `src/MultipartFormDataParser.cj:199-205` | 每 MB 系统调用次数、写盘耗时占比 | `strace -c` 或分段计时，200 MB 上传对比 1 KB / 64 KB 块 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/ContentDisposition.cj` | .cj | ✅ | 见 #1、#6、#7、#8、#9 |
| 2 | `src/ContentDispositionBuilder.cj` | .cj | ✅ | 见 #23 |
| 3 | `src/ContentDispositionType.cj` | .cj | ✅ | 无缺陷（`tryParse` 大小写不敏感问题并入 #14） |
| 4 | `src/HttpConfig.cj` | .cj | ✅ | 见 #18 |
| 5 | `src/MediaType.cj` | .cj | ✅ | 见 #5、#16、优化 O2 |
| 6 | `src/MediaTypes.cj` | .cj | ✅ | 见 #4、#14 |
| 7 | `src/Multipart.cj` | .cj | ✅ | 见 #20 |
| 8 | `src/MultipartBufferReuse_test.cj` | .cj | ✅ | 复用不变量覆盖良好；见 #24 覆盖缺口 |
| 9 | `src/MultipartEmptyPart_test.cj` | .cj | ✅ | 空 part 覆盖良好；无缺陷 |
| 10 | `src/MultipartFile.cj` | .cj | ✅ | 见 #17、#20、优化 O1 |
| 11 | `src/MultipartFormData.cj` | .cj | ✅ | 见 #2、#11、#19、#22 |
| 12 | `src/MultipartFormDataParser.cj` | .cj | ✅ | 见 #3、#5、#10、#12、#13、#19、#21 |
| 13 | `src/MultipartFormDataParser_test.cj` | .cj | ✅ | 见 #24 |
| 14 | `src/MultipartMedia.cj` | .cj | ✅ | 见 #15、#16 |
| 15 | `src/MultipartMediaType.cj` | .cj | ✅ | 见 #14 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分范围不含 README 与 `doc/**`，第 2 部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 #1/#6/#7/#10/#11/#12/#15/#17；设计 #13/#23；安全性 #3/#9；语言特性（`internal` 默认可见性、struct 装箱别名）已按官方文档核对，未另立条目 |
| §1 死代码 | 2 | 已逐个 `private`/`internal`/`protected` 符号全仓搜引用：`Multipart.name/setName`、`MultipartFile.setType/setFilename/directory` 无调用（#20）；parser 死存储与恒假分支（#21）。对外可达的 `public`（`MultipartMedia`、`MultipartFormData.encode`、`ContentDisposition.empty`、`MediaType.fromDataFields` 等）仓内零引用但按硬原则一不判，仅记信息 |
| §2 重复逻辑 | 1 | 已两两比对 15 个文件的函数体并跨文件搜错误文案/字面量：命中 3 组同语义实现（#19）；`MediaType.toDataFields` 重载、builder 的 getter/setter 属刻意展开，不判 |
| §3 空实现 | 1 | `Data`/`DataFields` 接口面 8 个恒抛方法（#16）；`chunkBuffer()` 惰性创建有真实实现，`MultipartMediaType.fromData/toData` 的「不支持」异常有明确语义，不判 |
| §4 栈溢出 | 1 | `MultipartFileInputStream.read` 自递归（#22）；parser、ContentDisposition、MediaType 均无递归；`DataMultipart*Iterator.next` 用循环 |
| §5 OOM | 1 | 请求体/字段全量物化且无上限（#5）；`MultipartFile.bytes()` 的预分配计入优化 O1（未证明会 OOM）；`Array<Byte>(end-start+4)` 最坏受 4096 窗口约束，并入 #5/#10 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据；所有疑似热点（ContentDisposition.parse、RotatableBuffer.indexOf、MediaTypes 查找）已列入「待验证假设」，未当缺陷 |
| §6.2 大粒度锁 | 0 | 本部分唯一锁是 `MediaTypes` 的 `Mutex`，临界区内只有 `condition.wait/notifyAll`，无 I/O、解析、回调；其正确性问题见 #4 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用 |
| §6.4 低效算法 | 0 | 逐函数核对复杂度：切分/扫描均 O(n)，`ByteBuffer.write` 为均摊 O(n)（f_io 侧扩容不足问题是正确性，不是复杂度）；`MultipartFile.bytes()` 的二次拷贝计入 O1，无数据不进缺陷 |
| §7 降堆内存方案 | 2 | O1 `bytes()` 双拷贝、O2 `toData(InputStream)` 累积；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | O3 ContentDisposition 单趟解析；无基线，仅作方案 |
| §9 local mode 可行性 | 0 | 本部分已按 `docs/LocalMode.md` 改造：`crlf`/`chunkBuf` 复用、header 块因 `String` 逃逸进 `Data` 不能复用（代码注释与 spec 一致）；剩余候选收益无法用峰值内存证明，不立项 |
| §11 现有代码的 BUG（存量） | 14 | 本轮读到的 15 个文件所有边界/空值/错误路径均已核对：#1/#2/#3/#6/#7/#8/#9/#10/#11/#12/#13/#15/#16/#17 记存量，均给 `git blame` 依据 |
| §12 并发安全与锁粒度 | 2 | #4（注册失败永久等待、`wait` 未重查）；#8（`hashCode` 缓存字段的可见性/竞争）。其余类型（parser、FormData、builder）为每请求单线程实例，无共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | #18（`uploadStoreInMemory` 未接线）、#13（`MultipartMedia` 未接线）；`MultipartFormData.input()`/`ContentDispositionBuilder` 的契约问题分别记 #2/#23 |
| 文件覆盖（§13 等） | 15/15 | 本部分不含 `.md`（README/README_en/doc 归第 2 部分），故 §13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 14 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

## 总评

这一部分覆盖 f_http 的 multipart 编解码与媒体类型基础设施，**不能按「质量良好」放行**：

- **阻塞项（严重）**：① 上传文件名直接 `Path.join` 落盘，存在路径穿越任意写（安全）；② `MultipartFileInputStream` 的终止符/下标错误让 `f_httpclient` 的 multipart 上传路径实际不可用，且多 part 报文会被服务端截断；③ `ContentDisposition.encodeFilename` 条件取反，RFC 5987 输出永远抛异常；④ `MediaTypes` 注册失败后所有解析线程永久等待；⑤ 请求体与 multipart 字段全量物化且无任何大小上限，存在 OOM 面。
- **排期项（一般）**：`ContentDisposition` 的解析/序列化一组边界缺陷（charset 丢失、base64 charset 丢弃、`name` 未转义、hashCode 缓存失效）、parser 首部硬编码与 500 化、落盘同名覆盖与 FD 泄漏、文件 Content-Type 丢失、媒体类型注册静默覆盖与 `tryParse` 抛异常、`Data` 接口面空实现、两套序列化与两段字段注册逻辑重复。
- **可维护性**：parser 的缓冲复用改造（`crlf`/`chunkBuf`、header 精确分配）方向正确、注释清楚，测试也锁住了空 part、跨 part 残留等不变量；问题集中在「边界输入 + 公开序列化路径 + 跨模块契约」这三块，缺少对应测试是共同根因。

存量缺陷共 24 条（严重 5 / 一般 14 / 轻微 5），是否纳入修复待用户决定；建议优先级：路径穿越 → `input()` 状态机 → 大小上限 → `encodeFilename` → `MediaTypes` 死锁。
