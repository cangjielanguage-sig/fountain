# f_httpclient 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_httpclient`（5 个源文件 `.cj` + 2 个测试 `.cj` + 7 个 `.md`，共 14 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支）。`git status f_httpclient` 无改动；`httpclient.cj` 最后触达为 `4be871f2fd chore: 统一换行符为 LF`（2026-10-02），`SseReader.cj` 为 `ab457e58b perf(f_httpclient): SseReader.readLine 复用实例字节行缓冲`（2026-11-22）。故**所有问题来源均记「存量」**
- **审查重点**：连接复用与超时、错误处理、资源泄漏、并发安全、死代码、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] `send()` 每次请求都 `builder.build()` 新建 `Client` 并覆盖字段，旧实例不关闭

- **位置**：`f_httpclient/src/httpclient.cj:133-137`（`client = builder.build()` 在 `:135`）；`f_httpclient/src/httpclient.cj:129-132`（`close()` 只关最后一个）
- **来源**：存量（快照；`git blame -L 133,137 -- f_httpclient/src/httpclient.cj` → `4be871f2fd` 2026-10-02，逻辑行早于该 LF 统一提交）
- **判据**：review-checklist §11（资源不对称：打开未关）、§5（无界增长）；`README.md:40-42` 把 `poolSize`（连接池大小）写成能力
- **证据**：静态确定 —— `send()` 的每次调用都执行 `client = builder.build()`，字段被直接覆盖，前一个 `Client` 再无引用、也没有 `close()`；stdx 文档明确 `ClientBuilder.build()` 是「构造 Client 实例」（`cangjie-doc/stdx/1.3.0/libs_stdx/net/http/http_package_api/http_package_classes.html:1576-1582`），`Client.close()` 是「关闭客户端建立的所有连接」（同文件 `:654-656`），即连接池与传输资源归属该 `Client` 实例。
- **描述**：一个 `HttpClient` 实例上的第 N 次请求都会丢弃第 N-1 个 `Client` 及其连接池：连接不复用（`poolSize` / HTTP/2 `maxConcurrentStreams` 等参数形同虚设），池内 socket（以及 `Client` 自带的连接管理资源）只能等 GC 回收，长时间复用的实例（如 `FormBuilder` 持有 `client` 连发 GET + DELETE）会按请求数累积；`HttpClient` 自称「stdx.net.http.Client 的简单包装」（`README.md:9`），但包装后恰好丢掉了 `Client` 唯一的复用价值。`HttpClient` 自称「stdx.net.http.Client 的简单包装」（`README.md:9`），但包装后恰好破坏了 Client 唯一的复用价值。
- **建议**：`client` 改为惰性单例——`if(let None <- client){ client = builder.build() }` 后复用；`close()` 关闭后置 `client = None`；若确需「一次一连接」语义，应在 README 写明并去掉 `poolSize` 承诺。

### [严重][存量] `SseReader` 的 `idleTimeout` 只在阻塞读之前判定：既无法打断挂死的读，又会在慢读返回后误报

- **位置**：`f_httpclient/src/sse/SseReader.cj:221-242`（判定在 `:227-233`，`body.read` 在 `:233`）；单测 `f_httpclient/src/sse/SseReader_test.cj:115-129` 走的正是「先返回数据、下一次 `fill()` 才抛」的路径
- **来源**：存量（`git blame -L 221,242 -- f_httpclient/src/sse/SseReader.cj` → `53af388201` 2026-10-26「feat: SSE 客户端」）
- **判据**：review-checklist §11（契约与实现不符）、§3（公开契约承诺有行为，实现不生效）；承诺源 `doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md:55`、`:61-64`，`README.md:258`（第 7 条）
- **证据**：静态确定 —— 超时判定只出现在 `fill()` 里、且位于 `body.read(buffer)` 之前；`read` 是阻塞读，一旦服务端不发任何字节也不发 FIN，`read` 不返回，判定点永远到不了。反向误差同样成立：`lastActivityAt` 在 `read` 之前写入，量的是「距上一次读开始」而非「距上一次收到字节」；`SseReader_test.cj:117-128` 的 60 ms 慢读返回 `'\n'` 后事件 `a` 正常产出，紧接的下一次 `next()` 才抛 `SseTimeoutException`，即为误报路径的实测记录。
- **描述**：`idleTimeout` 在最需要它的场景（对端静默、没有 RST/FIN 的半开连接）完全无效——调用线程会无限期阻塞在 `read` 上；而在「每次读都比 `idleTimeout` 慢但一直有数据」的正常慢流上，事件会延迟一格后误抛超时。`f_llm` 的流式链路依赖该异常做挂死保护（`f_llm/src/llm/LLMStreamTransport.cj:55`、`f_llm/src/llm/LLM.cj:205` 注释），因此这里的失效会直接变成 LLM 流永久挂起。
- **建议**：超时不能只靠事后检查，得让 `read` 本身可被打断——在 `HttpClient` 侧对 SSE 请求设置 socket 级 `readTimeout`（stdx `ClientBuilder.readTimeout`），或在 `fill()` 改用带截止时间的读（若 std 提供），`SseTimeoutException` 只作为语义包装；同时把 `lastActivityAt` 改为「读到 n>0 之后」更新，避免慢读误报。若短期无法改阻塞语义，README 必须写明「本超时只能检测读与读之间的间隔，不能中断阻塞读」。

### [一般][存量] `close()` 之后仍能发请求，`isClosed()` 与真实行为不一致

- **位置**：`f_httpclient/src/httpclient.cj:125-137`（`closed` 只在 `:131` 置位，`send()` 全程不检查）
- **来源**：存量（快照；同上 blame）
- **判据**：review-checklist §11（契约与实现不符；`Resource` 语义）
- **证据**：静态确定 —— `send()` 里没有任何 `if(closed)` 分支，`client = builder.build()` 会重建客户端；`isClosed()` 返回 `closed == true`，但此时 `get()` 仍会发起真实网络请求并返回响应。
- **描述**：典型场景是 `resource(client){...}` 块结束后误用同一实例，或用 `isClosed()` 做健康判断后继续调用——都不会报错，而是静默恢复可用；`close()` 也只关掉了「最后一个」`Client`（见上一条），所以「已关闭」既不完整也不可逆。
- **建议**：`send()` 首行加 `if(closed){ throw IllegalStateException('HttpClient is closed') }`，`close()` 里 `client = None`，并在 README 说明 `Resource` 语义（关闭后不可复用）。

### [一般][存量] `FormBuilder` 重复拼 query：`build()` 每次把 `?query` 追加到 `client.url`

- **位置**：`f_httpclient/src/httpclient.cj:212-218`（`:213` `client.url = '${client.url}?${form.toEncodeString()}'`）
- **来源**：存量（快照）
- **判据**：review-checklist §11（语义与命名不符 / 状态累积）、§10（正确性：URL 构造）
- **证据**：静态确定 —— `build()` 直接改写 `HttpClient.url`（`public var url`，`:41`），且无条件用 `'?'` 拼接；`get()`/`delete()` 各调一次 `build()`（`:216-221`）。
- **描述**：同一个 `FormBuilder` 上先 `get()` 再 `delete()`，第二次请求的 URL 变成 `...?a=1?a=1`（参数重复、第二个 `?` 非法）；若 `HttpClient` 的 URL 本来已带 query（很常见，如 `?api-version=...`），拼出来是 `...?api-version=1?a=b`，服务端只会把 `a=b` 当成 `api-version` 值的一部分。错误是静默的：请求照发，服务端拿到错误参数。
- **建议**：`build()` 不再改写 `client.url`，改为返回 `(url, form)` 或把 query 交给 `HttpRequestBuilder.url` 的一次性拼接；分隔符按「URL 已有 `?` 则用 `&`」判定（或直接用 `stdx.encoding.url` 的 query 组件拼接），并保证幂等（多次 `get()` 结果相同）。

### [一般][存量] `FormBuilder.put()/post()` 发 form body 但不设 `Content-Type: application/x-www-form-urlencoded`

- **位置**：`f_httpclient/src/httpclient.cj:222-227`
- **来源**：存量（快照）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（只做了一半的分支：GET/DELETE 走 query、PUT/POST 走 body，但缺配套头）
- **证据**：静态确定 —— `put()/post()` 只调 `client.put(form.toEncodeString())`，全类没有任何 `header('Content-Type', 'application/x-www-form-urlencoded')`；`HttpClient.put(body: String)`（`:150-153`）也不会推断类型。对照 `MultipartFormDataBuilder` 的构造函数（`:232-234`）确实设了 `multipart/form-data; boundary=...`，说明作者知道要设，只是 form 这条漏了。
- **描述**：服务端（含 fountain 自己的 `f_mvc` 表单绑定）按 `Content-Type` 选解析器，缺省时通常按 `text/plain` 或直接忽略 body，表现为「参数全空但 HTTP 200」——最难排查的一类失败。README 把 `FormBuilder.put/post` 写成可用能力（`README.md:162-169`），与实现不符。
- **建议**：`put()/post()` 发送前设 `header('Content-Type', 'application/x-www-form-urlencoded')`（与 `put<T>(contentType, body)` 一致地先设头再发 body），并补一条断言请求头的单测。

### [一般][存量] `MultipartFormDataBuilder.put()/post()` 丢弃 `HttpResponse`，响应体与连接不释放

- **位置**：`f_httpclient/src/httpclient.cj:238-243`
- **来源**：存量（快照；`README.md:183-191` 同形）
- **判据**：review-checklist §11（资源不对称）、§3（返回值被丢弃）
- **证据**：静态确定 —— 两个方法声明为 `Unit`，函数体是 `client.put(data.input())` / `client.post(data.input())`，返回值（`HttpResponse`）未被接收、未读 body、未 `close()`；stdx 文档要求「不再需要未读完的 body 数据时调用 `close()` 释放连接」（`http_package_classes.html:4436-4441`）。
- **描述**：调用方拿不到状态码，也无法关闭响应；连接要等 GC 或服务端超时才回收，`poolSize` 一旦调小就会把池占满，后续请求排队。与 `FormBuilder.put/post`（返回 `HttpResponse`）行为不一致，是同一模块内的资源释放不对称。
- **建议**：返回 `HttpResponse`（与 `FormBuilder` 对齐），或内部 `resource(response){...}` 读完并返回状态码；README 同步签名。

### [一般][存量] `send()` 复用同一个 `HttpRequestBuilder`：上一次的 body 会带进下一次请求

- **位置**：`f_httpclient/src/httpclient.cj:133-136`、`:150-173`（`request.body(...)` 只设不清）
- **来源**：存量（快照）
- **判据**：review-checklist §11（语义与命名不符 / 状态残留）
- **证据**：静态确定 —— `send()` 只覆盖 `method` 与 `url`，从不清 `body`/headers；stdx 文档的 `HttpRequestBuilder.body(...)` 条目写明「设置请求 body。如果已经设置过，调用该函数将替换原 body」，`build()` 条目只写「根据当前 HttpRequestBuilder 实例构造出来的 HttpRequest 实例」（`cangjie-doc/stdx/1.3.0/libs_stdx/net/http/http_package_api/http_package_classes.html` 的 `HttpRequestBuilder` 段），即 builder 状态跨 `build()` 保留。
- **描述**：统一实例上先 `post('{...}')` 再 `get()`，第二个请求是「带 body 的 GET」；若第一次用的是 `put(body: InputStream)`（`:158-165`），第二次发送时流已被读空，静默变成空 body。两个表现都不会抛错。
- **建议**：每次 `send()` 之前重置请求态（用 `HttpRequestBuilder()` 新建，或把 method/url/body/header 收进一个请求级小对象），只让「连接级配置」留在 `HttpClient` 上。

### [一般][存量] `tryParse<T>()` 在 `bodySize` 为 `None`（chunked / 长度未知）时直接返回 `None`，静默丢弃可读的响应体

- **位置**：`f_httpclient/src/ExtendHttpResponse.cj:100-112`（分支在 `:101-107`）
- **来源**：存量（`git blame -L 100,112 -- f_httpclient/src/ExtendHttpResponse.cj` → `4be871f2fd` 2026-10-02，快照）
- **判据**：review-checklist §11（错误处理缺失 / 失败路径当成功）、§3（`return None` 吞掉可用数据）
- **证据**：静态确定 —— 私有重载只在 `bodySize` 为 `Some` 时解析，`None` 分支直接 `None<T>`；stdx 文档写明「对于接收到的响应（如 chunked 编码的响应），body 读取完毕前 bodySize 为 None」（`http_package_classes.html:4256-4259`）。同一文件的 `readToEnd()`（`:69-76`）专门为 `None` 写了流式分支，说明作者知道 `None` 是常态。
- **描述**：任何无 `Content-Length` 的响应（chunked 的 JSON、代理改写过的响应、`Transfer-Encoding: chunked` 的 API 网关）都会让 `convert<T>()` / `tryParse<T>()` 返回 `None`，调用方按「没有 body / 类型不匹配」处理，与真实原因（长度未知）无关，属于静默数据丢失。
- **建议**：`None` 分支改为走 `MediaTypes.tryParse(contentType)....toDataFields<T>(this.body)`（输入流重载已存在，见 `f_http/src/MediaType.cj:85-87`），只在 `bodySize == Some(0)` 时才返回 `None`；补一条 chunked 响应用例。

### [一般][存量] `readToEnd()` 按响应头 `Content-Length` 一次性预分配，长度不可信且无上限

- **位置**：`f_httpclient/src/ExtendHttpResponse.cj:50-68`（`Array<Byte>(size, repeat: 0)` 在 `:55`）
- **来源**：存量（快照；`f_llm/doc/spec/f-llm-openai-compat/design.md:299` 记录过该函数的另一次修复，说明此路径长期在改）
- **判据**：review-checklist §5（按不可信长度预分配）
- **证据**：静态确定 —— `size` 直接来自 `this.bodySize`，没有与任何上限比较；分配在读取第一个字节之前完成。量化：`Content-Length: 2147483647` 会先申请 2 GiB 连续字节数组（`-O2` 下 `Array<Byte>` 就是一块堆内存），随后可能只读到 0 字节并从 `:67` 返回 `buf[0..0]`——而该切片仍引用 2 GiB 后备存储。
- **描述**：客户端访问的 URL 可能来自配置、重定向或第三方（`autoRedirect` 默认行为由 stdx 决定），错误或恶意的响应头即可让进程 OOM，且失败点在「读完响应之前」，没有拒绝路径。
- **建议**：`size` 与常量上限（如 64 MiB）取 `min`，超限走流式分支并累计计数、超过上限抛明确异常；提前 EOF 的分支（`:64-68`）改为返回拷贝后的数组，避免短读时把大缓冲带出函数。

### [一般][存量] SSE 单事件内的 `data` 行数/字节数无上限，`ArrayList<String>` 可被单条事件撑爆

- **位置**：`f_httpclient/src/sse/SseReader.cj:81-103`（`data` 容器在 `:86`，累加在 `:122-124`），拼接在 `:137-151`
- **来源**：存量（`git blame -L 81,103` → `53af388201` 2026-10-26）
- **判据**：review-checklist §5（无界容器 / 无拒绝路径）
- **证据**：静态确定 —— `maxLineBytes` 只约束「一行」，`next()` 只以空行或 EOF 结束一条事件，中间对 `data` 的条数与累计字节没有任何计数或上限；`joinData` 再把全部内容拼成一个 `String`（峰值 ≈ 全部行 + 拼接结果 + `toString` 拷贝）。
- **描述**：对端持续发送 `data: xxx\n` 而不发空行时，内存按行线性增长（每行 ≤ 1 MiB，10 万行即数十 GB），最终 OOM；这不是「慢」，而是没有拒绝路径。LLM 场景下用错误的分帧（例如漏发空行）也会触发，且表现为进程内存持续上涨而非报错。
- **建议**：在 `next()` 内累计 `dataBytes` 与行数，超过阈值（如 `maxEventBytes`，默认取 `maxLineBytes * 4`）抛 `SseEventTooLargeException`；阈值做成构造参数或与 `maxLineBytes` 关联，README 第 6 条一并说明。

### [一般][存量] `HttpClient` 的可变实例状态与静态超时无同步、无「非线程安全」声明

- **位置**：`f_httpclient/src/httpclient.cj:28-48`（`static var readTimeout_` / `writeTimeout_` 在 `:29-30`，builder/request/client 字段在 `:37-39`）、`:125-137`
- **来源**：存量（快照）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性）、§10（契约声明缺失）
- **证据**：待确认 —— 代码层面可确定无锁/无原子/无线程封闭：`send()` 同时改写 `request`（`method`/`url`/`body`）与 `client` 字段，`close()` 改写 `closed`，`globalReadTimeout`/`globalWriteTimeout` 改写静态变量并被每个构造函数读取（`:42-47`）；缺的是「仓内是否真的共享实例」的证据：现有 6 个调用点（`f_llm/src/util/http.cj:19`、`f_llm/src/llm/LLMTransport.cj:41`、`fprobe/src/collect/health/HttpProbe.cj:54` 等）均为函数内新建、用完 `close()`，未发现跨线程共享。类文档也只写了「stdx Client 的简单包装」，未声明线程安全性。
- **描述**：一旦下游把它当 bean/字段复用（这是包装类最常见的用法，且 `Resource` + builder 风格看起来就像可复用对象），两个线程同时 `get()`/`post()` 会出现「A 的方法配 B 的 body」、`client` 互相覆盖并泄漏（放大第一条严重项），`closed` 的写入对其他线程也无可见性保证。`SseReader` 反而明确写了「非线程安全」（`SseReader.cj:24`），`HttpClient` 缺这句。
- **建议**：短期在类注释与 README 明确「一个实例只在一个线程内、一次请求生命周期内使用」；中期把 `client` 做成线程安全的惰性单例（`Mutex` 或 `Atomic` 引用 + 双重检查），`request` 改为 `send()` 内局部对象，静态超时改为启动期一次写入的不可变快照。

### [一般][存量] README 未覆盖 `SseTimeoutException` / `SseLineTooLongException` 等公开 API

- **位置**：`f_httpclient/README.md:206-214`（「其他公开 API」只列了 `SseException`）；对应声明 `f_httpclient/src/sse/SseException.cj:26`、`:33`，`f_httpclient/src/sse/SseReader.cj:64`，`f_httpclient/src/ExtendHttpResponse.cj:36`、`:38`、`:44`
- **来源**：存量（快照）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— README 全文检索 `SseTimeoutException`、`SseLineTooLongException`、`isClosed`、`charset` 均无命中（三个 charset 重载 `reader(charset)`、`readEntire(charset)`、`readJson(charset)` 完全缺文档）；`ExtendHttpResponse` 片段（`README.md:200-202`）只写了 `convert<T>()`，接口实际有 10 个成员（`ExtendHttpResponse.cj:33-47`）。
- **描述**：这两个异常是调用方唯一能区分「超时」与「行过长」的手段（`README.md:257-258` 只在规则表里提到名字，没有类型声明、没有捕获示例），`f_llm` 已经在 `catch` 里依赖 `SseTimeoutException`（`f_llm/src/llm/LLM.cj:205`）。按 README 写代码的人不知道异常类型属于哪个包、能否单独捕获。
- **建议**：在「SSE 客户端」段落补 `SseException` 家族的声明与一段 `try/catch` 示例；把 `reader(charset)`、`readEntire(charset)`、`readJson(charset)`、`SseReader.isClosed()` 补进「其他公开 API」清单。

### [轻微][存量] `SseReader` 两处 `while(true)` 之后有不可达语句

- **位置**：`f_httpclient/src/sse/SseReader.cj:134`（`next()` 末尾的 `None<SseEvent>`）、`f_httpclient/src/sse/SseReader.cj:185`（`readLine()` 末尾的 `None<String>`）
- **来源**：存量（`git blame` → `53af388201` / `ab457e58b2`）
- **判据**：review-checklist §1（`return` / `break` 之后的同层语句；`while(true)` 无 `break` 出口）
- **证据**：静态确定 —— 两个函数体都是 `while(true){ ... }` 且循环内所有路径 `return`/`throw`，循环没有 `break`；循环后的表达式不可能执行，只用于满足返回类型检查。
- **描述**：无害但会误导读者以为存在「循环正常结束」的出口；仓颉要求函数有返回值时这类写法常见，但配合 `while(true)` 就是死代码。
- **建议**：改为 `while(true)` 内显式覆盖全部分支后删除尾随表达式（编译器接受 `while(true)` 函数无返回），或把 `while(true)` 改成 `while(!eof)` 并让尾部成为真实出口。

### [轻微][存量] `ExtendHttpResponse.cj` 冗余导入：`sse` 包重复导入、`f_data.macros.*` 未使用

- **位置**：`f_httpclient/src/ExtendHttpResponse.cj:26`（`import fountain::f_data.macros.*`）、`:30-31`（同一 `sse` 包先 `import` 再 `public import`）
- **来源**：存量（快照）
- **判据**：review-checklist §1（未使用的 `import`、冗余导入）
- **证据**：静态确定 —— 该文件全文没有任何宏调用（无 `@DataAssist` 等 `@` 标注），`DataFields` 来自 `fountain::f_http`、`unsafeData` 来自 `fountain::f_base`（`f_base/src/ExtendIterator.cj:47` 等处均有该扩展），因此 `macros` 包无引用；`:30` 的普通 `import` 与 `:31` 的 `public import` 同名同范围，前者被后者完全覆盖。
- **建议**：删除 `:26` 与 `:30`，只保留 `public import fountain::f_httpclient.sse.*`（若需要 `public` 重导出）。

### [轻微][存量] 不含冒号的 SSE 行被整行丢弃（W3C 语义应为「字段名 + 空值」）

- **位置**：`f_httpclient/src/sse/SseReader.cj:108-111`
- **来源**：存量（`git blame -L 108,111` → `53af388201` 2026-10-26）
- **判据**：review-checklist §11（与标准/契约不一致）
- **证据**：待确认 —— 代码在 `text.indexOf(':')` 为 `None` 时 `continue`；而 SSE 规范把「无冒号的行」定义为字段名为整行、值为空串。本模块自己的规格（`doc/spec/reuse-sse-line-buffer/specs/http-sse-client/spec.md:38-47`）只说「未知字段忽略」「字段值去掉一个前导空格」，未覆盖该形态，因此「是否必须兼容」需产品/协议侧确认。
- **描述**：`data`（单独一行、无冒号）按标准应追加一个空 data 行（`data\n\n` → 事件数据为空串），当前实现直接丢弃，`hasField` 保持 `false`，整条事件不产出；对端用这种写法发「空增量」时，客户端表现为「少了一条事件」而不是空事件。
- **建议**：在 `None` 分支按 `field = text`、`value = ''` 处理，走同一个 `match(field)`；补一条 `data\n\n` 的用例并写进 README 规则表。

### [轻微][存量] 「读尽到容器」的逻辑在 `readToEnd()` 与 `f_http` 的 `MediaType.toData(InputStream)` 各写一份

- **位置**：`f_httpclient/src/ExtendHttpResponse.cj:69-76`；对照 `f_http/src/MediaType.cj:64-75`
- **来源**：存量（快照）
- **判据**：review-checklist §2（跨层复制：同一输入-输出-副作用的实现两份）
- **证据**：静态确定 —— 两处都是「1024 B 缓冲 + `while(read>0)` + `ArrayList<Byte>.add(all:)` + `unsafeData()`」，差异只有缓冲大小常量写死的位置与返回值包装（`Data` vs `Array<Byte>`）。
- **描述**：同一语义两份实现，后续调缓冲大小或改成分块上限时只会改一处；`f_http` 是 `f_httpclient` 的下层依赖，抽取落点应是 `f_io`（而不是让 `f_http` 反向依赖本模块）。
- **建议**：在 `f_io` 提供 `readAll(input, chunkSize, maxBytes)`，两处都调它；顺带统一「超上限抛什么」的语义。

### [轻微][存量] media type 解析与同一条错误文案在 `httpclient.cj` / `ExtendHttpResponse.cj` 各写一份

- **位置**：`f_httpclient/src/httpclient.cj:175-177`；对照 `f_httpclient/src/ExtendHttpResponse.cj:102-104`
- **来源**：存量（快照）
- **判据**：review-checklist §2（相同错误消息 / 相同转换的复制）
- **证据**：静态确定 —— 两处都是 `MediaTypes.tryParse(contentType).getOrThrow{ MediaTypeException('${contentType} is not a valid media type') }`，字面量逐字相同，只有后续调用不同（`fromDataFields` vs `toDataFields`）；`put<T>/post<T>`（`:181-188`）还会在 `header(...)` 与 `body<T>(...)` 里各解析一次。
- **描述**：错误文案与异常类型是调用方可见契约，复制两份后一处改成更具体的提示（例如带上支持的格式列表）就会与另一处不一致；同一次请求解析两次也有多余开销（量级待测）。
- **建议**：抽 `private func mediaTypeOrThrow(contentType: String): MediaType`，`put<T>/post<T>` 只解析一次并把结果传给 `body<T>`。

### [轻微][存量] `README_en.md` 缺「行缓冲复用」实现要求第 11 条

- **位置**：`f_httpclient/README.md:261`（第 11 条）；`f_httpclient/README_en.md:248-261`（到第 10 条结束）
- **来源**：存量（快照；`README.md` 侧由 `ab457e58b` 补入，`README_en.md` 未同步）
- **判据**：review-checklist §13（`README_en.md` 与 `README.md` 不同步）
- **证据**：静态确定 —— 中文版实现要求表 11 行，英文版 10 行，缺的正是「行读取复用实例字节缓冲……（`F_HTTPCLIENT_SSE_BENCH=1` 下有分配上界基准）」。
- **描述**：英文读者拿不到「每行不新建集合、缓冲上界 `maxLineBytes`、有门控基准」这三条结构性约束，也就不知道 `F_HTTPCLIENT_SSE_BENCH` 的存在。
- **建议**：补第 11 条英文版（与 `README.md:261` 一一对应）。

### [轻微][存量] README 声称实现要求「每条都有单测」，第 4/9/10 条实际无用例

- **位置**：`f_httpclient/README.md:248`；对应测试 `f_httpclient/src/sse/SseReader_test.cj:56-138`、`f_httpclient/src/sse/SseReaderLineBuffer_test.cj:192-393`
- **来源**：存量（快照）
- **判据**：review-checklist §13（文档声明与实现不符）、§14.1（半成品/覆盖不足）
- **证据**：静态确定 —— 第 4 条「其余字段丢弃」没有任何用例（`testCommentAndFields` 只喂 `event`/`id`/`data`/`retry` 四个已知字段）；第 9 条「`close()` 关闭底层流」只在不可关的假流上验证了「再读返回 None」（`SseReader_test.cj:131-137`），没有实现 `Resource` 的记录型假流来断言 `close()` 真被调用；第 10 条「不做自动重连」无用例。
- **描述**：这句话是给后续维护者的承诺，实际覆盖是 20 条用例中有 3 条规则没有断言，容易在重构时被静默破坏（尤其第 9 条的 `Resource` 分支）。
- **建议**：补「未知字段 + 记录型 `Resource` 假流」两条用例，或把该句改成「核心规则均有单测（第 4/9/10 条除外）」。

### [轻微][存量] `reuse-sse-line-buffer` 的 design/tasks 与实现漂移：`takeLine` 签名、声称存在的「超限后再读」用例

- **位置**：`doc/spec/reuse-sse-line-buffer/design.md:181`、`:320`；`doc/spec/reuse-sse-line-buffer/tasks.md:51`；实现 `f_httpclient/src/sse/SseReader.cj:212`
- **来源**：存量（快照，`ab457e58b` 一并提交）
- **判据**：review-checklist §13（规格与实现漂移）、§14.1（承诺了但没做）
- **证据**：静态确定 —— design/tasks 写 `private func takeLine(stripCr: Bool)`，实现是命名实参 `takeLine(stripCr!: Bool)`；`design.md:320` 风险表写「抛错前与 `takeLine` 内都显式归零，并有用例覆盖「超限后再读」」，但 `design.md:247-261` 的用例清单、`tasks.md` 的 2.x 条目、`SseReaderLineBuffer_test.cj` 全都没有「超限后再读」用例（只有 `testMaxLineBytesOverLimit` 断言抛错）。
- **描述**：规格自称的风险已被用例覆盖，实际没有；这正好掩盖了下一条「抛错后 reader 仍可继续使用」的行为。
- **建议**：补「超限后再读」用例并据结果决定语义（见下一条），或改掉 design.md:320 的表述；`stripCr` 签名同步为 `stripCr!:`。

### [轻微][存量] `SseLineTooLongException` 抛出后 reader 未失效，继续 `next()` 会从被丢弃行的中部解析出错误事件

- **位置**：`f_httpclient/src/sse/SseReader.cj:174-180`（抛错只复位 `lineLen`）
- **来源**：存量（`git blame -L 174,180` → `ab457e58b2` 2026-11-22）
- **判据**：review-checklist §11（契约与实现不符）；承诺源 `doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md:57-59`（「读取抛出『行过长』异常，**且不继续读取**」）
- **证据**：静态确定 —— 抛错时只 `lineLen = 0`，`closed`/`eof` 均未置位，`pos` 已越过触发字节；下一次 `next()` 会从超长行的剩余部分开始重新累积一行，正常返回一条 `data` 被截断的事件。
- **描述**：只在调用方「捕获异常后继续用同一 reader」时触发，但该用法没有任何阻止手段，结果是静默的错误数据（截断的 JSON 等），比直接失败更难定位；与规格「不继续读取」相反。
- **建议**：抛错时置 `closed = true`（或 `eof = true` 并让后续 `next()` 返回 `None`），规格与 README 同步写明「超限后 reader 不可继续使用」。

## 优化可行性方案

> 性能类结论均无改前/改后对照，除引用已有基线外一律标注「无基线（待验证）」，不进 `todo.md` / `tasks.md`。

### [堆内存] 复用事件组装缓冲（`ArrayList<String>` + `StringBuilder`）

- **现状**：每调一次 `next()` 都新建 `ArrayList<String>`（`SseReader.cj:86`）并在 `joinData` 里新建 `StringBuilder`（`:141`），事件结束后全部丢弃；已有基线：`design.md:370` 的 `case=event_small` 实测 `allocPerEvent = 450 B`（`-O2`、5000 条 `data: x` 事件、5 样本中位数），事件越小固定开销占比越高。
- **方案**：把 `data` 与 `StringBuilder` 提为实例字段，`next()` 开头 `clear()` 复用；只保留「事件 String」这一处必要分配；给保留容量设上限（例如超过 64 KiB 的事件后丢弃缓冲），避免长事件把常驻内存抬高。
- **预期**：每事件少 1 个 `ArrayList` + 1 个 `StringBuilder` 的对象头与扩容（450 B 中可归因比例未测，不给百分比）。
- **代价**：实例常驻缓冲（与 `lineBuf` 同类的「容量只增不减」取舍，`clear()` 不归还物理内存，`mem §3.2`）；`next()` 变为有状态复用，`close()` 后需一并释放。
- **验证**：`F_HTTPCLIENT_SSE_BENCH=1 F_HTTPCLIENT_SSE_BENCH_STRICT=1` + `-O2` 重跑 `event_small`，比较 `allocPerEvent` 中位数与离散；同时看多轮负载下 `getAllocatedHeapSize()` 是否回到稳态。
- **证据状态**：`已有基线（当前 allocPerEvent 450 B）`，但**改后无数据 → 无基线（待验证，不进 tasks）**。

### [CPU] `readLine` 改为块内批量查找 `\n`，只在跨块时逐块拼接

- **现状**：`readLine` 每字节一次 `buffer[pos]` 下标读 + 分支判定（`SseReader.cj:160-184`），8 KiB 长行实测 `nsPerLine = 82882`、`allocPerLine = 9502`（`design.md:369` 的 `case=line_long`，`-O2`、200 行、5 样本中位数）；短行 `nsPerLine = 430`（`:367`）。这些是端到端观测，不是扫描段自耗时。
- **方案**：在 `buffer[pos..len]` 上用 `indexOf(0x0A)`（或手写分段比较）一次定位换行，命中后 `lineBuf.add(all: buffer[pos..nl])`；只有一行跨多个 `read` 块时才退回逐块追加；`maxLineBytes` 判定与 `\r` 剥除保持在同一个出口。
- **预期**：长行扫描的每字节常数下降（未测，不给比例）。
- **代价**：跨块、`maxLineBytes` 恰好/超限、EOF 半行三条边界都要重新对齐（现有 20 条用例可作等价性网），`indexOf` 的可用签名需按 std 文档确认。
- **验证**：`cjpm bench`（`-O2`）对照 `line_long` / `line_reuse` 的中位数与离散；`cjprof record` 看 `readLine` 自耗时占比是否仍是长行场景的主项。
- **证据状态**：`无基线（待验证，不进 tasks）` —— 现有 82.9 µs/line 含分配与调用开销，不能当作扫描段收益。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 逐字节扫描是 8 KiB 长行的主要耗时（而非分配/`fromUtf8`） | `f_httpclient/src/sse/SseReader.cj:157-186` | `readLine` 自耗时占比 | `cjprof record` 跑 `F_HTTPCLIENT_SSE_BENCH=1` 的 `line_long`（200 行 × 8 KiB），取 `readLine` / `String.fromUtf8` 的 self time |
| 2 | 事件组装的缓冲复用能显著降低短事件流的分配 | `f_httpclient/src/sse/SseReader.cj:85-103`、`:137-151` | 改后 `allocPerEvent` | 按「优化可行性方案 · 堆内存」实现后，`-O2 + STRICT` 重跑 `event_small`，与 450 B 对照 |
| 3 | 每请求新建 `Client` 的建连/TLS 握手是端到端延迟主项 | `f_httpclient/src/httpclient.cj:135` | 建连 / 首字节 / 读体的分段耗时 | 对同一 URL 连发 100 次 POST，记录 P50/P95 分段耗时，修复（单 Client 复用）后同条件对照 |
| 4 | 已知长度路径上 1024 B 的小读块放大了系统调用次数 | `f_httpclient/src/ExtendHttpResponse.cj:56-63` | 每响应 `read` 调用次数 | 在读取循环加计数埋点，跑 1 MiB 响应，比较调用次数与总耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_httpclient/README.md` | .md | ✅ | 声明清单与 `src/` 基本一致；缺 `SseTimeoutException`/`SseLineTooLongException`/charset 重载（一般条目）；第 248 行「每条都有单测」不成立（轻微条目） |
| 2 | `f_httpclient/README_en.md` | .md | ✅ | 与中文版逐段对照，缺实现要求第 11 条（轻微条目）；其余章节一致 |
| 3 | `f_httpclient/doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md` | .md | ✅ | 归档变更的验收口径，作为「空闲超时」「不继续读取」的承诺源；空闲超时与实际实现不符（严重条目），超长行语义不符（轻微条目） |
| 4 | `f_httpclient/doc/spec/reuse-sse-line-buffer/design.md` | .md | ✅ | 行缓冲设计、等价性论证与 §10 实测数据；`takeLine` 签名与「超限后再读」用例声称与实现/测试不符（轻微条目） |
| 5 | `f_httpclient/doc/spec/reuse-sse-line-buffer/proposal.md` | .md | ✅ | 动机与改动范围，与实现一致（行缓冲 + 两个辅助函数 + 构造参数不变），未发现偏差 |
| 6 | `f_httpclient/doc/spec/reuse-sse-line-buffer/specs/http-sse-client/spec.md` | .md | ✅ | 行缓冲 MUST 条款逐条核对：初始容量 `min(256,max)`、增长收敛、`[0,lineLen)` 只读、单线程契约均成立；未覆盖「无冒号行」（轻微条目） |
| 7 | `f_httpclient/doc/spec/reuse-sse-line-buffer/tasks.md` | .md | ✅ | T1–T6 全部勾选；`takeLine(stripCr: Bool)` 与实现不一致（轻微条目），2.11 编号重复（未计入问题） |
| 8 | `f_httpclient/src/ExtendHttpResponse.cj` | .cj | ✅ | 10 个接口成员 + `HttpResponse` 扩展；`tryParse` 的 `bodySize=None` 分支、`readToEnd` 预分配（两条一般条目），冗余导入、读尽逻辑重复、错误文案重复（三条轻微条目） |
| 9 | `f_httpclient/src/httpclient.cj` | .cj | ✅ | 244 行全文；`Client` 生命周期（严重）、`close` 语义、`FormBuilder` 三处、`request` 残留、并发契约（一般条目） |
| 10 | `f_httpclient/src/sse/SseEvent.cj` | .cj | ✅ | 纯数据 `struct`，字段与 README/`SseReader` 一致，无问题 |
| 11 | `f_httpclient/src/sse/SseException.cj` | .cj | ✅ | 三个异常类层次清晰；`SseTimeoutException`/`SseLineTooLongException` 未进 README（一般条目） |
| 12 | `f_httpclient/src/sse/SseReader.cj` | .cj | ✅ | 243 行全文；`fill()` 超时语义（严重）、事件 `data` 无上限（一般）、不可达语句/无冒号行/超限后未失效（轻微） |
| 13 | `f_httpclient/src/sse/SseReaderLineBuffer_test.cj` | .cj | ✅ | 12 条用例（含 `-O2` 门控基准）；覆盖短/长行、跨块、CRLF、EOF、边界、复用独立性；缺「超限后再读」与「未知字段」用例 |
| 14 | `f_httpclient/src/sse/SseReader_test.cj` | .cj | ✅ | 8 条既有用例；`testIdleTimeout` 恰好记录了超时「晚一拍」的路径（严重条目证据）；`close()` 只用不可关假流验证 |

合计：`.cj` 7 个 / `.md` 7 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 5（`close` 后仍可请求、`request` body 残留、`tryParse` 丢弃 chunked 体、`readToEnd` 预分配、事件 `data` 无上限）；设计 1（`HttpClient` 可变状态无契约，另 1 条设计类「`Client` 生命周期」计入严重项）；可读性 1（不可达语句，计入 §1）；语言特性 0（`Option` 用法、`match`、`struct` 值语义均符合 std 文档）；安全性 0（无凭据硬编码、无注入面；TLS 配置由调用方传入，本模块不落默认弱配置） |
| §1 死代码 | 2 | 逐个 `private` 符号全仓搜过：`readTimeout_`/`writeTimeout_`、`builder`/`request`/`client`/`closed`、`send`、`body<T>`、`FormBuilder.build`、`SseReader` 的 `joinData`/`readLine`/`ensureLineCapacity`/`takeLine`/`fill` 与全部私有字段均有引用；`internal`/`protected` 0 个；`public` 均为顶层 public 类型成员（对外可达），按硬原则一不判；`public import` 的 `ByteBuffer`/`copy`/`Charsets` 是重导出契约，不作死代码。命中的是两处 `while(true)` 之后的不可达表达式与冗余/未使用 import |
| §2 重复逻辑 | 2 | 同文件两两比对：`HttpClient` 的 8 组 `put/post` 重载只差方法名与 body 类型（参数化 API，非重复）；`FormBuilder.get/delete` 同为 `build().x()`（有意对称）；`MultipartFormDataBuilder.put/post` 同形（有意）。跨文件按相同错误文案/相同转换搜到两处：读尽逻辑（`readToEnd` vs `MediaType.toData`）、media type 解析 + `'${contentType} is not a valid media type'` 文案 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`/`UnsupportedException`；`SseReader.close()` 的 `catch(_: Exception){}` 有注释说明「流不一定可关」，属有意的 best-effort（不判）；`match` 的 `case _ => ()` 是文档化的「未知字段丢弃」；`MultipartFormDataBuilder` 丢弃返回值是资源问题，已按 §11 报 |
| §4 栈溢出 | 0 | 无递归（`ensureLineCapacity` 是迭代增长，`readLine` 是状态机循环）；无自引用结构、无深拷贝；`SseEvent` 是扁平 `struct` |
| §5 OOM | 2 | 按不可信长度预分配（`Content-Length` → `Array<Byte>(size)`，可放大到 GiB 级）；SSE 单事件内 `data` 行/字节无上限（无拒绝路径）。`SseReader` 的行缓冲上界 `maxLineBytes`（默认 1 MiB）由 `ensureLineCapacity` 收敛，不构成无界增长 |
| §6.1 热点瓶颈 | 0 | 无可复核的 profile 数据；`design.md` §10 的分配/耗时只覆盖行缓冲路径，且是改造后的单点观测。相关线索已降级为「待验证假设」1/3/4，未作为发现 |
| §6.2 大粒度锁 | 0 | 本模块无锁、无 `synchronized`、无临界区；`SseReader.close()` 与 `fill()` 均无线程同步 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无任务队列、无连接池的并发提交（`poolSize` 因每请求重建而实际未生效，已在严重条目中说明） |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`/`indexOf` 当查找、无 `remove(at:0)`、无循环内字符串 `+`（`joinData` 用 `StringBuilder`）；逐字节扫描是 O(n) 线性，复杂度不构成缺陷（优化空间见 CPU 方案） |
| §7 降堆内存方案 | 1 | 事件组装缓冲复用（引用已有基线 450 B/event；改后收益无基线，标注待验证） |
| §8 降 CPU 方案 | 1 | 块内批量查找 `\n`（无基线，标注待验证） |
| §9 local mode 可行性 | 0 | 行缓冲已消除每行分配（`design.md:71-73` 明确结论「不需要 local」）；剩余临时对象是事件 String 与 `StringBuilder`，`String` 需要返回给调用方（逃逸），加 `@ local!` 不成立；无 `docs/LocalMode` 峰值数据，不写结论 |
| §11 现有代码的 BUG（存量） | 12 | 本轮读到的 5 个实现文件全部逐函数核对边界/空值/错误处理/资源/契约：2 条严重（Client 生命周期、idleTimeout 语义）+ 8 条一般（`close` 语义、`FormBuilder` 三处、`request` 残留、`tryParse`、`readToEnd`、事件 `data` 上限）+ 2 条轻微（无冒号行、超限后未失效） |
| §12 并发安全与锁粒度 | 1 | 共享路径已列出：`HttpClient` 实例字段（`request`/`client`/`closed`）与 `static readTimeout_`/`writeTimeout_` 无同步、无可见性手段，且未声明非线程安全（证据等级「待确认」：仓内 6 个调用点均为函数内新建，缺下游共享证据）；`SseReader` 显式声明非线程安全且按单消费者使用，判为线程封闭；锁粒度无对象（无锁） |
| §14 功能完备性与 README 覆盖 | 1 | 以 `src/` 公开声明为基准逐项检索 README：`SseTimeoutException`、`SseLineTooLongException`、`SseReader.isClosed()`、`reader/readEntire/readJson(charset)` 三个重载未文档化（README 全文无 `charset` 字样）；`HttpClient` 的 `poolSize` 有声明但实现无效（计入严重条目），`form()` 的 PUT/POST 缺 Content-Type（计入一般条目）；模块已在根 `README.md` / `cjpm.toml` 登记，无索引缺失 |
| 文件覆盖（§13 等） | 14/14 | 无缺读文件；`doc/spec/**` 4 个按「归档变更自洽性 + 与当前实现的关键差异」核对 |
| §13 文档一致性 | 3 | `README_en.md` 缺第 11 条；`README.md:248` 的「每条都有单测」不成立；`design.md`/`tasks.md` 的 `takeLine` 签名与「超限后再读」用例声称与实现/测试不符 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

SSE 解析这条线质量不错：`SseReader` 把行读取做成实例字节缓冲（上界 `maxLineBytes`）、CRLF/EOF 半行/超限边界都有明确口径，20 条用例覆盖了跨块、长短行交替、缓冲复用独立性与分配门控基准，`design.md` 还给了 `-O2` 下的前后分配对照（104 → 24 B/行）。这部分只留下三处形态问题（不可达语句、无冒号行、超限后未失效）和一处文档漂移。

真正的阻塞项在客户端包装层，两条都与本轮「连接复用与超时」直接相关：

1. `send()` 每次 `builder.build()` 新建 `Client` 并覆盖字段，旧实例从不 `close()` —— 连接池与传输资源随请求数累积，`poolSize` 这个对外承诺完全失效，`HttpClient` 反而把 stdx `Client` 唯一的复用价值丢掉了。这是全模块最该先修的（改惰性单例 + `close` 置空即可）。
2. `SseReader` 的 `idleTimeout` 只在阻塞读**之前**检查，且以「上次读起点」计时：真正静默的连接会永久挂住（`f_llm` 的流式链路正依赖它做挂死保护），而慢但正常的流反而会在下一次 `fill()` 误抛。这条不修，README 第 7 条与规格里的「空闲超时后失败」都只是纸面承诺。

一般问题集中在 `FormBuilder`/`MultipartFormDataBuilder`（URL 重复拼 query、缺 form `Content-Type`、丢弃响应）和 `ExtendHttpResponse`（chunked 响应 `tryParse` 返回 `None`、按不可信 `Content-Length` 预分配、`request` body 残留跨请求）。它们大多不是「看起来不好」，而是静默的错误行为（参数全空、URL 非法、内存暴涨），建议与上面两条一起排期。

并发方面，`SseReader` 的线程封闭是明确的；`HttpClient` 则是「可变 builder + `Resource`」的混合形态，既没锁也没声明非线程安全。仓内调用点都是函数内新建实例，所以现在没炸，但这是文档与契约缺口，应在上面的单例改造中一并定死语义。

其余 9 条轻微项是死代码、重复逻辑与文档同步（`README_en` 缺第 11 条、README「每条都有单测」、design/tasks 签名与用例声称），随手可改，不阻塞。

**存量缺陷共 21 条（2 严重 + 10 一般 + 9 轻微），是否纳入修复待用户决定。** 本报告不改源码、未跑构建；性能类结论除引用 `design.md` 已有基线外均为「待验证假设」，不进 `todo.md` / `tasks.md`。

范围外提示：`f_llm/src/llm/LLMStreamTransport.cj:55` 与 `f_jsonrpc/src/client/SocketSseConnection.cj:58` 是 `SseReader` 的两个生产消费点，前者依赖 `SseTimeoutException` 做挂死保护（见第 2 条严重项），后者用默认 `maxLineBytes`/`idleTimeout`；`f_llm/doc/spec/f-llm-openai-compat/design.md:299` 记录过 `readToEnd` 的历史短读 bug（当前实现已改为循环读满，本轮未复现）。
