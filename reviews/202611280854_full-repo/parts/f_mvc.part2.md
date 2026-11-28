# f_mvc 模块审查报告（模块第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（全模块 59 个 `.cj` + 9 个 `.md`；本部分 20 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；无 diff，全部问题记「存量」）
- **审查重点**：路由 / 参数绑定正确性、鉴权与权限（`@IgnoreAuth` 语义）、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（部分报告；由主 Agent 与第 1/3/4 部分合并为 `docs/review/2026-11-28/f_mvc.md`）
- **本部分覆盖文件**：`files/f_mvc.part2.txt` 全部 20 个 `.cj`（下载、分发器、HttpStatus、配置、启动器、`MultiRequestMethodHandler`、WS 注解、计时器、Redirect、`RequestArgMeta`）

> 说明：本部分不含 `AuthHandler.cj` / `AuthAnnotation.cj`（在第 1 部分），因此「`@IgnoreAuth` 语义」在本部分只按「路由分发是否绕过鉴权」这一面交叉核对：`MultiRequestMethodHandler` 的 404 / 405 / OPTIONS / HEAD 分支都在 `RequestMeta.setHandle` 之外直接返回，不经过任何鉴权钩子（与第 1 部分结论一致，此处不重复计数）。

## 发现

### [一般] [存量] HEAD 路由丢弃已注册的 HEAD 处理器：HEAD-only 路由恒 405，HEAD+GET 路由忽略 HEAD 实现

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:121-124`
- **来源**：存量（`git blame -L 121,124` → `4be871f2fd` 2026-10-02，快照模式无基线可比）
- **判据**：review-checklist §11（语义与命名不符 / 分支漏做）、§10 正确性
- **证据**：静态确定 —— `metas.get(HEAD)` 匹配成功后，分支体只做 `metas.get(RequestMethod.GET)`：① 若该 path 同时注册了 GET，则执行 GET 处理器，已注册的 HEAD 处理器永不执行；② 若只注册了 HEAD（`RequestMethod.HEAD` 是合法注册键，见 `RequestMethod.cj:30`），`metas.get(GET)` 为 `None` ⇒ 落到 `METHOD_NOT_ALLOWED`，即 HEAD-only 路由**恒返回 405**。绑定的 `m`（`case (Some(m), HEAD)`）在分支体内未被使用。
- **描述**：HEAD 语义应为「与 GET 相同的元信息、无响应体」。当前实现既忽略显式注册的 HEAD 处理器，又把 GET 的完整响应体原样写出（stdx 侧不会替 `HEAD` 裁体，见 `http_package_classes.md` 的 `body(InputStream)` / `body(String)` 只按内容写 body），对 keep-alive 连接存在响应体错位风险（客户端按 HEAD 不读 body）。
- **建议**：`case (Some(_), HEAD)` 改走 `metas.get(HEAD)` 优先、GET 兜底；GET 兜底时显式不出 body（`ctx.responseBuilder.status(...)` 只写 `Content-Type` / `Content-Length`），并补一条 HEAD 用例（HEAD-only 与 HEAD+GET 两种注册形态）。

### [一般] [存量] 未知 HTTP 方法（TRACE / CONNECT / 自定义）抛异常 ⇒ 请求变 500

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:64`
- **来源**：存量（blame `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（错误处理缺失）、§10 正确性
- **证据**：静态确定 —— `RequestMethod.parse(request.method).getOrThrow{IllegalArgumentException}`（`RequestMethod.cj:95-97`）对 `TRACE`/`CONNECT`/任意扩展方法抛 `IllegalArgumentException`，本函数无 `try`，异常穿到 stdx 分发层 ⇒ 500。同文件已有 `tryParse`（`RequestMethod.cj:79-91`）可用。
- **描述**：不合法的**方法名**属于客户端错误，应为 405（或 501），当前一律 500；同时 500 会走内部错误日志/内部错误体，放大日志量与误导排障。
- **建议**：改 `RequestMethod.tryParse(request.method)`，`None` 时返回 `METHOD_NOT_ALLOWED`（或 `NOT_IMPLEMENTED`），并把方法名记一条 `debug` 日志。

### [一般] [存量] 下载响应体生命周期：成功路径永不 `pipe.end()`，且 `start()/build()` 在 `spawn` 之后

- **位置**：`f_mvc/src/FileDownload.cj:55-61`（`write(filename:input:length:)` 末尾只调 `end()`）、`:75-93`（`exec` 的 `finish` 只在异常分支跑）、`:134-139`（`end()` 仅 `multi` 分支 `pipe.end()`）
- **来源**：存量（`exec` 见 blame `52d1fb59e4` 2026-10-05，`end()`/`start()` 见 `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（资源不对称 / 边界）、§12.1（异步语义）、§3
- **证据**：静态确定 + 待确认 —— 静态确定的两点：① `runDownloadTask`（`:152-164`）只在 `catch` 里调 `finish`，成功路径不调；② 单文件（`multi == false`）路径上 `end()` 是空操作，`pipe.end()` 只存在于 `multi` 分支 ⇒ 单文件下载**从不**显式结束响应体。待确认的一点：读取端把「缓冲暂时为空」当作什么 —— `f_io/src/ByteBuffer.cj:236-250` 的零超时 `read(buf)` 在「无数据且未 end」时返回 `None`，外层 `read(buf)` 用 `?? 0` 折成 `0`，与「已 end」的 `0` 不可区分。
- **描述**：单文件下载的结束语义完全依赖「`SyncByteBuffer` 空缓冲返回 0 即被当成 EOF」这一巧合：声明了 `Content-Length` 时若实际写入不足会挂住；`Transfer-Encoding: chunked`（`length < 0`）时若读取端先于生产者读到空缓冲就会**提前结束、响应被截断**。第二点：`exec` 把 `start()`（内部 `responseBuilder.header/build/body(pipe)`）整个放进 `spawn`，而 handler 在 `RequestMeta.cj:418-422` 立即返回；若 stdx 在 handler 返回时按 `responseBuilder` 现状发送，则「body 设置」与「响应发送」构成竞争（该路径仓内无端到端用例，`.autocode/bugs/bug-mvc-archived-20261006.md:119` 亦记录「真端到端未跑」）。
- **建议**：① 成功路径也收尾 —— 在 `write(filename:input:length:)` 的循环后 / `exec` 的 `finally` 里统一 `pipe.end()`（幂等：`end_.store(true)` + `notify`），不要让「结束」只挂在异常分支；② `start()`/`body(pipe)` 提到请求线程（在 `exec` 的 `spawn` 之前完成），`spawn` 只跑数据搬运；③ 用「先 `build` 再 `spawn`」的顺序写一条 e2e 用例（单文件 + 多文件 + 中途失败三种）钉住时序。

### [一般] [存量] CORS 预检头名写错（`Access-Control-Allow-Method`，规范为复数 `Methods`），且该分支不设 status/body

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:108-120`（头名 `:111`）
- **来源**：存量（blame `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（与规格冲突）、§10 安全性/正确性
- **证据**：静态确定 —— 预检响应头规范名为 `Access-Control-Allow-Methods`；仓内 `grep 'Access-Control-Allow-Method'` 只有本行（`MultiRequestMethodHandler.cj:111`）与测试注释（`MultiRequestMethodHandler_test.cj:23`），无第二处拼写可辩护。同分支只调 `resp.header(...)`，不设 `status` 也不设 `body`（对比 `HttpStatusOnlyHandler.setStatus()` 至少设 status+body）。
- **描述**：浏览器 CORS 预检只认复数头，因此该分支对真实跨域预检等同「未声明允许方法」，预检失败、后续业务请求被浏览器拦截；同时无 body 的响应对 `build()` 之外的隐式发送路径依赖过强（stdx 文档示例均在 `.body(...)` 后隐式发送，`http_package_classes.md:809`）。
- **建议**：改为 `Access-Control-Allow-Methods`；分支显式 `status(204)`（或 200）并 `body(Array<Byte>())`；补一条断言响应头名与状态码的用例（现测试只断言 `allowsOf` 的字符串内容，见 `MultiRequestMethodHandler_test.cj:38-46`，覆盖不到真实响应头）。

### [一般] [存量] `Content-Disposition` 手写且分隔符用逗号、文件名未转义

- **位置**：`f_mvc/src/FileDownload.cj:140-142`（`attachment()`），被用于 `:101`（响应头）与 `:122`（multipart 分片头）
- **来源**：存量（blame `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（与规格冲突）、§10 安全性（响应头注入）、§2（与 `f_http.ContentDispositionBuilder` 能力重复）
- **证据**：静态确定 —— 生成的是 `attachment, filename="x"`；RFC 6266 的参数分隔符是分号（`attachment; filename="x"`）。`filename` 直接内插，不做 `"`、`\`、CR/LF 转义；`start(filename:)`/`next(filename:...)` 都是 `public`，`download(data: InputStream, filename:)` 也直接透传调用方给的字符串。
- **描述**：① 逗号分隔会让部分客户端/浏览器解析不到 `filename`，下载文件名退化为 URL 末段；② 若调用方把外部输入（上传原名、用户输入）当 filename，`"` 可截断参数、CR/LF 可注入额外响应头（`HttpHeaders` 写入侧未必拦截）。
- **建议**：改用同仓 `f_http.ContentDispositionBuilder`（`f_http/src/ContentDispositionBuilder.cj:19-76`，已有 `attachment` / `filename` / RFC 5987 相关能力）生成头值；multipart 分片头复用同一函数，避免两处手工拼串（`:101` 与 `:122`）。

### [一般] [存量] 无路由时 `initialize()` 静默返回、`start()` 静默空转：MVC 不监听且无任何日志

- **位置**：`f_mvc/src/MVCStarter.cj:28-30`、`:106-108`
- **来源**：存量（blame 2026-10-02，`MVCStarter.cj` 未在近两次下载/计时改动中触碰）
- **判据**：review-checklist §3（开关打开后走进空分支）、§14.1（接线缺失）、§11
- **证据**：静态确定 —— `initialize()` 先 `initial_.compareAndSwap(false, true)`，紧接着 `if (!registered.load()) { return }`，既不打日志也不建 `Server`；`start()` 是 `starter?.doStart()`，`starter` 为 `None` 时什么都不做。此后 `initial_` 已为 `true`，任何再次 `initialize()` 都抛 `MVCException('mvc has been started')`，状态不可恢复。
- **描述**：一个没有 `@Controller`/`@WSEndPoint` 的应用（例如只跑定时任务、只做 MQ 消费）会拿到「进程正常启动但不监听端口」的结果，且日志里没有任何痕迹；排查时最容易被误判为端口/防火墙问题。反向场景（路由注册晚于 `initialize`）又被 CAS 拦死，无法补救。
- **建议**：无路由时打一条 `warn`（明确「未注册任何路由，跳过 HTTP 服务」），或改为配置项显式开关；`start()` 在 `starter == None` 时抛 `MVCException` 而不是静默返回。

### [一般] [存量] `mvc_tlsPath` 格式非法时静默降级为明文 HTTP

- **位置**：`f_mvc/src/MVCConfig.cj:79-80`（`paths.size == 2` 才进 TLS 分支）、`:114-116`（否则 `None`）
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §11（错误处理静默 / fail-open）、§10 安全性
- **证据**：静态确定 —— 条件链是 `Config.getString(TLS_PATH)` 非空 && 长度>0 && `split('|')` 且 `paths.size == 2`；任一不满足即返回 `None`，`MVCStarter.cj:72-74` 的 `if (let Some(tls) <- ...)` 随之跳过 `builder.tlsConfig(tls)`，服务器以明文启动。同函数内其它非法配置（`tlsVerifyMode` 未知值、CustomCA 缺 pem、CustomVerify 缺 bean）都是 `throw MVCException`，唯独「tlsPath 写错」不报错。
- **描述**：运维把 `mvc_tlsPath` 写成 `cert.pem`（单段）或 `a|b|c`（三段）时，服务在明文端口上正常对外服务，配置意图（加密）与运行事实（明文）相反，属于安全侧的静默降级。
- **建议**：`TLS_PATH` 非空但无法解析成两段时 `throw MVCException`，与同函数其它分支口径一致；把「未配置 `mvc_tlsPath`」与「配置了但格式错」分开判断。

### [一般] [存量] 每次下载 `spawn` 一个新线程，无线程池与并发上限

- **位置**：`f_mvc/src/FileDownload.cj:77`
- **来源**：存量（blame `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §12.1（有界性）、§5（无界增长）
- **证据**：静态确定 —— `exec` 每次调用一条 `spawn{...}`，无池、无信号量、无并发计数；`HttpRequestDistributorImpl`/`MVCStarter` 侧也没有对下载并发的准入。下载线程不占用 `mvc_servicePoolCapacity` 的配额（它由请求线程派生、生命周期远长于请求）。
- **描述**：慢客户端场景下线程数 ≈ 并发下载数，与 `ServerBuilder` 的 service pool 上限解耦，等于绕过了池化保护；每个线程另持有 `Array<Byte>(downloadBufferSize)` 与文件句柄。规模上限只有「客户端数量」，一旦被拖住就是线程 + 堆同时增长。
- **建议**：接入 `f_pool` / `mvc_servicePool*` 的同一套池化，或在 `exec` 入口加并发闸门（信号量 + 排队上限 + 超时释放）；至少在文档里写明「一次下载一个线程」的容量模型。

### [一般] [存量] `noContent()` 给 204 写 body

- **位置**：`f_mvc/src/FileDownload.cj:43-46`
- **来源**：存量（blame 2026-10-02；仓内 `grep noContent` 仅此定义，无调用者）
- **判据**：review-checklist §11（与规格冲突）、§10 正确性
- **证据**：静态确定 —— `responseBuilder.status(NO_CONTENT).body(status.reasonPhrase).build()`，204 按 RFC 9110 不得携带响应体；`body(String)` 会让 builder 生成带长度的 body（`http_package_classes.md:5650` 起 `body(String)`）。该方法在 `public class FileDownload` 上，属对外 API（仓内零引用，按硬原则一不判死代码）。
- **描述**：客户端按规范忽略 204 的 body 时，残留字节会污染 keep-alive 上的下一个响应；按 body 长度读取时又会等到超时。该方法目前无仓内调用者，风险面取决于下游是否使用。
- **建议**：删除 `.body(...)`，只 `status(NO_CONTENT).build()`；或改成 `status(204)` + `header('Content-Length','0')`，并在 README 写明用法。

### [一般] [存量] `@OnWSPong` 的 `mediaType` 参数被丢弃（接线缺失）

- **位置**：`f_mvc/src/OnWSPong.cj:20`（注解声明 `mediaType`）→ `f_mvc/src/WSMeta.cj:398`（`WSPongMeta<T>(funcName, '')` 传空串）
- **来源**：存量（blame 2026-10-02；`WSMeta.cj` 不在本部分清单内，仅作被调用方取证）
- **判据**：review-checklist §14.1（承诺了但没接线）、§13（注解契约与实现不一致）
- **证据**：静态确定 —— 同批其它注解都把参数透传：`OnWSBinary`→`WSBinaryMeta(..., annotation.mediaType, annotation.responseFrameType)`（`WSMeta.cj:386`）、`OnWSText`→`:390`、`OnWSPing`→`WSPingMeta(funcName, annotation.mediaType)`（`:394`）；唯独 `OnWSPong` 写死 `''`。
- **描述**：用户在 `@OnWSPong[mediaType: 'application/json']` 上配置的类型永远不生效，pong 帧按空 mediaType 处理，表现形式是「配了和没配一样」，且没有任何告警。
- **建议**：改为 `WSPongMeta<T>(funcName, annotation.mediaType)`；若 pong 确实不需要 mediaType，则把注解参数删掉，别留一个沉默的配置面。

### [轻微] [存量] 死代码：`MVCConfig.getStatus` 无任何调用者

- **位置**：`f_mvc/src/MVCConfig.cj:233-239`
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §1（`private` 符号本项目内无调用者）
- **证据**：静态确定 —— 在 `f_mvc/src` 全包（含 `macros/`、`*_test.cj`）搜 `getStatus` 只有本定义一处；`private static func` 连测试都够不到。函数体还依赖 `HttpStatus.valueOf`（未知码抛 `IllegalArgumentException`），是一条未接线的旧路径。
- **描述**：无行为影响，但会让人误以为「内部错误状态码可配置」：同文件的 `getInternalServerErrorMessageKind` 才是实际在用的那一个（`MultiRequestMethodHandler.cj:27`）。
- **建议**：删除；若将来要支持「可配置的响应状态码」，再连配置键与 README 一起加。

### [轻微] [存量] 死代码：`RequestArgMeta.contains` 无任何调用者

- **位置**：`f_mvc/src/RequestArgMeta.cj:31-33`
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §1（`internal` 符号本包及子包内无引用）
- **证据**：静态确定 —— 包内搜 `contains(name)` / `args.contains` 只命中本函数自身；宏（`macros/Controller.cj`）不生成该调用，`RequestMeta.isMultipart` 走的是 `args[name]` 下标（`RequestMeta.cj:425`），`WSMeta` 走 `args[name]`（`WSMeta.cj:37`）。
- **描述**：纯冗余成员；`RequestArgMeta` 是包内类，该成员对外不可达。
- **建议**：删除；若保留，可让 `RequestMeta.isMultipart` 复用它以避免「下标 + 类型判断」重复（需连同 `RequestMeta.cj:425` 一起改）。

### [轻微] [存量] `HttpStatus.values` 的成员与顺序让 `valueOf` 解析到 deprecated 常量；421 缺标准常量

- **位置**：`f_mvc/src/HttpStatus.cj:806-878`（`values`），相关常量定义 `:440-457`（413）、`:464-480`（414）、`:60-69`（103）、`:553-562`（421）
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §11（语义与注释不符）、§10 正确性
- **证据**：静态确定 —— `static init`（`:795-799`）按 `values` 顺序写入 `statuses[value]`，后者覆盖前者：① `413` 先 `PAYLOAD_TOO_LARGE` 后 `REQUEST_ENTITY_TOO_LARGE` ⇒ `valueOf(413)` 得到已 deprecated 的后者，与 `REQUEST_ENTITY_TOO_LARGE` 注释「deprecated in favor of PAYLOAD_TOO_LARGE which will be returned from HttpStatus.valueOf(413)」相反；② `414` 同理（`URI_TOO_LONG` 被 `REQUEST_URI_TOO_LONG` 覆盖）；③ `103` 只列 `CHECKPOINT`、未列 `EARLY_HINTS` ⇒ `valueOf(103).reasonPhrase == "Checkpoint"`；④ `MISDIRECTED_REQUEST`（421）不在 `values` 里，`resolve(421)` 得到 `DESTINATION_LOCKED`（reasonPhrase `"Destination Locked"`），与 302 处「deprecated 常量让位给标准常量」的约定相反。逐个比对声明（70 个）与 `values`（67 项）确认缺失项恰为 `EARLY_HINTS` / `MISDIRECTED_REQUEST` / `MOVED_TEMPORARILY`（后者有意为之，注释已说明）。
- **描述**：只影响 reasonPhrase 文案与被 `resolve/valueOf` 命中的常量身份，不影响 `value` 数值；但 `MISDIRECTED_REQUEST` 这个 public 常量永远无法通过 `resolve` 取回，属契约层面的小坑。
- **建议**：`values` 按「deprecated 在前、标准项在后」排序或只保留标准项，补 `MISDIRECTED_REQUEST`；加一条测试遍历 `values` 断言 `valueOf(c.value) == c` 且文案属标准值。

### [轻微] [存量] 重复逻辑：下载读取循环两处逐行相同

- **位置**：`f_mvc/src/FileDownload.cj:57-60` 与 `f_mvc/src/ResponseDownload.cj:71-76`（`copy`）
- **来源**：存量（`FileDownload` 侧 blame 2026-10-02；`copy` 由 `MVC-4` 修复引入，2026-10-05）
- **判据**：review-checklist §2（语义相同的两处实现）
- **证据**：静态确定 —— 两处都是「`Array<Byte>(MVCConfig.downloadBufferSize)` → `while (let n <- input.read(buf) && n > 0) write(buf[0..n])`」，缓冲大小来源、截断写法、循环条件完全一致，只有 `write` 的接收者不同（`this.pipe` vs 回调参数）。
- **描述**：`MVC-4` 修的是「只写出读到的长度」，而 `FileDownload` 侧当时已是正确写法却各写一遍；后续任一侧再改（加读超时、加校验）都会漏掉另一侧。
- **建议**：让 `FileDownload.write(filename:input:length:)` 复用包内 `copy(input, write)`（同包可达），或把 `copy` 提成 `FileDownload` 的私有方法并让 `ResponseDownload` 调它；差异点只有「写目标」，用一个 `(Array<Byte>) -> Unit` 参数即可覆盖。

### [轻微] [存量] 重复逻辑：`HttpStatusOnlyHandler` 内「status + Accept→Content-Type」写了两遍

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:138-145`（`setStatus()`）与 `:152-158`（Bean 分支重设）
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §2（同函数内近似重复）
- **证据**：静态确定 —— `setStatus()` 做 `status(...)` + `RequestMeta.setResponseStatus(...)` + `headers.getFirst("Accept")` → `header("Content-Type", accept)`；Bean 分支因为要换成自定义 handler 给的 status，把同样三步再抄一遍（还把 `accept` 另存一个局部变量）。两处唯一差异是 status 取值来源。
- **描述**：`setStatus()` 的返回值被两处分别接续（`.body(...)` / `.body(x)`），一旦给 `setStatus` 加逻辑（例如补 `Content-Length`），Bean 分支就会漏。
- **建议**：改成 `func applyStatus(b: HttpResponseBuilder, status: HttpStatus): String`（返回最终 accept），两处都调它。

### [轻微] [存量] 把原始 `Accept` 整串写回 `Content-Type`

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:141-143`、`:155-157`
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §11（语义与命名不符）、§10 安全性（响应头反射用户输入）
- **证据**：静态确定 —— `headers.getFirst("Accept")` 的原值（可能是 `text/html,application/xhtml+xml;q=0.9,*/*;q=0.8`）被直接当 `Content-Type` 写入响应，而 `Content-Type` 只允许单个媒体类型 + 参数。仓内已有正确的「按 q 选一个类型」实现（`AcceptQueue` + `MediaTypes.tryParse`，`:167-180`；`RequestMeta.populateResponseContentType`）。
- **描述**：405/404/500 这类响应会带上非法 `Content-Type`，客户端可能按错误类型解析错误体或直接拒绝；同时把请求头原样反射进响应头属不必要的输入外泄面（CR/LF 是否被 `HttpHeaders` 拦下取决于 stdx 实现，未核实）。
- **建议**：只取 Accept 的首个媒体类型（或固定 `text/plain; charset=utf-8`），与 `populateResponseContentType` 共用同一套解析。

### [轻微] [存量] `OverallStopwatch` 用 `unsafeZeroValue` 占位，安全性只靠 5 处 `if(switch)` 兜底

- **位置**：`f_mvc/src/OverallStopwatch.cj:19-28`（static init），使用点 `:30`、`:35`、`:44`、`:56`、`:65`
- **来源**：存量（blame 2026-10-02，`takeStart/elapsedFrom` 2026-10-05）
- **判据**：review-checklist §12.1（惰性初始化）、§10 类型使用
- **证据**：静态确定 —— `switch == false` 时 `log` / `start` 被赋为 `unsafeZeroValue<AbstractLogger>()` 与 `unsafeZeroValue<ThreadLocal<...>>()`（非法引用），每个使用点都必须先 `if(switch)`；一旦新增使用点忘记前置判断就是进程级崩溃（不是可捕获异常）。
- **描述**：把「是否计时」编码进「字段是否为零值」，省了两次分配，代价是类型系统完全帮不上忙（`AbstractLogger` 非 `?`，编译器不会强制判空）。
- **建议**：改为 `?AbstractLogger` / `?ThreadLocal<...>`，使用点用 `if (let Some(l) <- log)`；若担心空判断开销，可在开关关闭时替换为真正的 no-op logger。

### [轻微] [存量] `MVCStarter.register(mediaType)` 不受 `initial_` 守卫，与同文件其它注册 API 口径不一致

- **位置**：`f_mvc/src/MVCStarter.cj:78-80`（对比 `:83-100` 的 `generateAndRegister*`）
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §12.1（运行期改共享集合）、§10 一致性、fountain-baseline §5（启动后不假设配置/注册变化）
- **证据**：静态确定 —— `generateAndRegister` / `generateAndRegisterWSEndPoint` 都在 `initial_.load()` 为真时 `throw`，而 `register(mediaType)` 直接 `MediaTypes.register(...)`；`MediaTypes` 是 `f_http` 的全局注册表、请求期会被解析逻辑读取。该方法仓内零调用者（`grep 'MVCStarter.register'` 无命中），属对外 API。
- **描述**：启动后注册媒体类型会并发修改全局表，与同模块「注册只允许在 start 之前」的约定冲突；stdx 对同类注册表的立场也是「启动后 register 结果未定义」（`http_package_interfaces.md:196-200`）。
- **建议**：加与 `generateAndRegister` 相同的 `initial_` 守卫 + `MVCException`；并在 README 的注册时序说明里补一行。

### [轻微] [存量] `HttpRequestDistributorImpl.register` 两个重载是占位实现，直接抛「not implemented」

- **位置**：`f_mvc/src/HttpRequestDistributorImpl.cj:50-55`
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §3（占位实现）、§14.1（半成品）
- **证据**：静态确定 —— 两个 `register` 只 `throw MVCException('... is not implemented')`；它们是 stdx `HttpRequestDistributor` 接口的必需成员（`http_package_interfaces.md:184-191`），而 `HttpRequestDistributorImpl` 是内部类、`instance` 也不对外暴露，因此这两个方法仓内不可达（按接口实现豁免，不判死代码）。
- **描述**：「MVC 只允许通过宏注册路由」是合理设计，但文案「未实现」会让人以为是半成品；`MVCException` 也无法区分「设计不支持」与「忘了写」。
- **建议**：文案改为「f_mvc 只支持通过 `@Controller`/`@WSEndPoint` 注册，请勿直接 register」，并把这条约束写进 README 的扩展点章节。

### [轻微] [存量] `consumes` 首段解析不 trim；条件不匹配映射为 501

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:75-80`（切片）、`:68-69`（501）
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §11（边界）、§10 语义
- **证据**：静态确定 —— ① `Content-Type: application/json ; charset=utf-8`（分号前有空格）得到 `"application/json "`，与注册键 `"application/json"` 不等 ⇒ 落到 415；② `meta.check(ctx)` 为假（`@RequestMapping` 的 `headers`/`params` 条件不满足）时返回 `HttpStatus.NOT_IMPLEMENTED`（501），而 501 语义是「服务器不支持该功能」，条件不满足更接近 404（handler 不适用于此请求）或 412。
- **描述**：① 属解析宽容度问题（规范不鼓励空格，但真实客户端/网关会带）；② 会让客户端把「参数不匹配」理解成服务端能力缺失。
- **建议**：切片后 `.trimAscii()`；条件不匹配改用 `NOT_FOUND`（保留 `Allow` 头）或 `PRECONDITION_FAILED`，并同步补用例。

### [轻微] [存量] `MVCConfig` 静态初始化里丢弃 `lookupOption<GlobalCryptoKit>()` 结果，无注释

- **位置**：`f_mvc/src/MVCConfig.cj:68-70`
- **来源**：存量（blame 2026-10-02）
- **判据**：review-checklist §1（读了不用的表达式语句）、§10 可读性
- **证据**：静态确定 —— `static init(){ lookupOption<GlobalCryptoKit>() }` 返回值被丢弃，唯一可能作用是「触发 bean 初始化/注册」；同文件 `cryptoKit`（`:71-75`）用的是 `lookupOption<CryptoKit>() ?? getGlobalCryptoKit()`，看不出与这行的因果关系。
- **描述**：读代码的人无法判断这行是「有意的启动期预热」还是「漏了赋值」；`MVCConfig` 的静态初始化由第一次配置访问触发，把它与 bean 容器初始化绑在一起还引入了隐式启动顺序依赖。
- **建议**：若确有预热意图，加注释说明「为什么必须在 static init 里 lookup 一次」；否则删除，把依赖显式放到 `MVCInitializer.initialize()`（它已声明 `dependencies = ['fountain::f_bean']`，是更合适的落点）。

## 优化可行性方案

> 本部分无 bench / profile 数据，以下两条均为「能更好」，不进修复清单。

### [CPU] 路由热路径每请求一次 `toAsciiUpper` 分配 + 两次字符串切片

- **现状**：`MultiRequestMethodHandler.handle` 每请求调用 `RequestMethod.parse(request.method)`（`MultiRequestMethodHandler.cj:64`），内部 `value.toAsciiUpper()` 新建字符串；随后 `check(metas)` 里 `consumes.indexOf(';')` + `consumes[0..idx]` 再各产一次临时串（`:75-80`）。输入规模 = 每请求 1 次，`RequestMethod.hashCode` 已改为常量（`RequestMethod.cj:38-49`），这几次分配是剩下的固定开销。
- **方案**：在 `HttpRequestDistributorImpl.distribute` 入口用 `match` 直接比较原始方法串（或长度+首字符）得到枚举；`consumes` 首段解析改为索引扫描、只在需要查表时构造子串（或直接用 `HttpHeaders` 的 content-type 归一化结果）。
- **预期**：每请求省 1 个 String + 0–2 个切片（数十字节级），收益量级与「一次 HTTPS 请求的固定开销」相比很小。
- **代价**：多一处手写方法名映射，需与 `RequestMethod` 枚举保持同步（可加编译期穷尽检查的 `match`）。
- **验证**：`cjpm bench -O2`，同机同输入（10k 次 `distribute`，方法名分布真实），对照中位数与离散程度；或 `cjprof record` 确认 `toAsciiUpper` 自耗时占比 > 5% 再动手。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `HttpStatus.values` 每次访问重建 66 元素数组

- **现状**：`public static prop values`（`HttpStatus.cj:806-878`）每次 getter 调用都新建一个 66 元素 `Array<HttpStatus>`（引用数组，约 0.5KB + 头部）。仓内只有 `static init`（`:796`）用一次，但它是公开 API，下游若循环调用就是按次分配。
- **方案**：改为 `private static let all: Array<HttpStatus>` 在静态初始化时建一次，`values` 返回该数组（或在文档里写明「返回快照，请勿修改」）。
- **预期**：静态初始化后零分配；对仓内无收益（只 1 次），对下游高频调用者省下每次数组分配。
- **代价**：语义变化——调用方若修改返回数组将影响全局（需在 README 注明只读）；`values` 的「每次新数组」当前也无人依赖。
- **验证**：加一条 `getAllocatedHeapSize()` 对照（连续 10k 次 `HttpStatus.values`），确认分配归零且业务断言不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无测试数据，仅作下一轮取数清单；不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 下载 `spawn` 的线程数随并发下载线性增长，慢客户端下线程/RSS 双涨 | `f_mvc/src/FileDownload.cj:77` | 并发下载数 → 线程数与 RSS 的曲线 | 压测：50/200/1000 个并发下载 + 客户端限速，采 `Thread` 计数、RSS、`getAllocatedHeapSize()` |
| 2 | 单文件下载在 chunked（`length < 0`）下会被提前截断 | `f_mvc/src/FileDownload.cj:55-61` + `f_io/src/ByteBuffer.cj:230-250` | stdx 响应写出侧对 `read()==0` 的解释 | 起真服务 + 慢生产者（每块 sleep），比对下载字节数与源长度；同时抓 stdx 写出循环的读次数 |
| 3 | `exec` 里 `start()/build()` 晚于 handler 返回，存在「响应已发送、body 未设置」窗口 | `f_mvc/src/FileDownload.cj:75-93` | stdx 发送时机（handler 返回即发 or 显式 build 才发） | 在 `start()` 前后与 handler 返回处打时间戳，跑 1k 次单文件下载，统计「空响应 / 缺 body」次数 |
| 4 | 路由热路径的 `toAsciiUpper` + 切片在整请求耗时中占比 < 5% | `f_mvc/src/MultiRequestMethodHandler.cj:64-80` | 自耗时占比（需工具） | `cjprof record` 跑静态资源/JSON 混合负载 10 分钟，看 `RequestMethod.parse` 与 `HashMap.get` 的自耗时 |
| 5 | `MVCConfig` 每次 `tlsConfig`/`downloadBufferSize` 访问都读配置 + 读文件，若被请求期调用会成为 I/O 热点 | `f_mvc/src/MVCConfig.cj:77-118,257-261` | 调用频次与单次耗时 | 在 getter 内埋计数与分段计时，跑稳态负载看每秒调用次数（`tlsConfig` 预期仅启动期 1 次） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/FileDownload.cj` | .cj | ✅ | 见 #3 #5 #8 #9 |
| 2 | `f_mvc/src/FileDownload_test.cj` | .cj | ✅ | 只覆盖 `runDownloadTask` 接缝；成功路径不测 `pipe.end()`（正是 #3 的盲区） |
| 3 | `f_mvc/src/HttpRequestDistributorImpl.cj` | .cj | ✅ | 见 #19（`register` 占位抛异常）；`getHandler` 为隐式返回类型推断（`cj_syntax.md:11`） |
| 4 | `f_mvc/src/HttpRequestDistributorImpl_test.cj` | .cj | ✅ | 只断言未命中路径的类型，未覆盖 `distribute` 的计时/注册路径 |
| 5 | `f_mvc/src/HttpStatus.cj` | .cj | ✅ | 见 #13（`values` 成员/顺序） |
| 6 | `f_mvc/src/MVCConfig.cj` | .cj | ✅ | 见 #7 #11 #21 |
| 7 | `f_mvc/src/MVCInitializer.cj` | .cj | ✅ | `dependencies` 仅声明 `fountain::f_bean`；委托 `MVCStarter`，实现与文档一致 |
| 8 | `f_mvc/src/MVCStarter.cj` | .cj | ✅ | 见 #6 #18 |
| 9 | `f_mvc/src/MediaType.cj` | .cj | ✅ | 仅 `public import fountain::f_http.*`（再导出），无逻辑 |
| 10 | `f_mvc/src/MultiRequestMethodHandler.cj` | .cj | ✅ | 见 #1 #2 #4 #15 #16 #19 #20 |
| 11 | `f_mvc/src/MultiRequestMethodHandler_test.cj` | .cj | ✅ | 覆盖 `allowsOf`/`AllowsCache`/`isWebSocketUpgrade`；未覆盖 HEAD/OPTIONS 响应头 |
| 12 | `f_mvc/src/OnWSBinary.cj` | .cj | ✅ | 注解声明，参数在 `WSMeta.cj:386` 全部透传 |
| 13 | `f_mvc/src/OnWSClose.cj` | .cj | ✅ | 注解声明，`WSMeta.cj:381-384` 消费 |
| 14 | `f_mvc/src/OnWSOpen.cj` | .cj | ✅ | 注解声明，`WSMeta.cj:377-380` 消费 |
| 15 | `f_mvc/src/OnWSPing.cj` | .cj | ✅ | 注解声明，`mediaType` 在 `WSMeta.cj:394` 透传 |
| 16 | `f_mvc/src/OnWSPong.cj` | .cj | ✅ | 见 #10（`mediaType` 未接线） |
| 17 | `f_mvc/src/OnWSText.cj` | .cj | ✅ | 注解声明，参数在 `WSMeta.cj:390` 全部透传 |
| 18 | `f_mvc/src/OverallStopwatch.cj` | .cj | ✅ | 见 #17（`unsafeZeroValue` 占位） |
| 19 | `f_mvc/src/Redirect.cj` | .cj | ✅ | 301/308、302/307 语义与注释一致；无问题 |
| 20 | `f_mvc/src/RequestArgMeta.cj` | .cj | ✅ | 见 #12（`contains` 无调用者） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_mvc.part2.txt` 的 20 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 见 #1–#10；语言特性面核对了「省略返回类型的推断」（`cj_syntax.md:11`，`getHandler`/`duration`/`register(metas)` 依赖它）、`HashMap` 下标取值语义、`unsafeZeroValue` 约束，未发现类型使用错误 |
| §1 死代码 | 2 | 逐个 `private`/`internal` 符号全包搜引用：`MVCConfig.getStatus`、`RequestArgMeta.contains` 零引用（#11/#12）；其余（`OverallStopwatch.clearStart/takeStart/elapsedFrom`、`AllowsCache.get`、`allowsOf`、`isWebSocketUpgrade`、`getHandler`、`bufferSize/uint32/duration/getMessageKind`、`runDownloadTask`、`HttpStatusOnlyHandler.*`、`RequestArgMeta.add/extract/[]`）均有调用者。`public` 侧：`FileDownload.noContent`、`MVCStarter.register(mediaType)`、`HttpStatus.*`、注解类均对外可达 ⇒ 按硬原则一只记「仓内零引用」不判死代码；`HttpRequestDistributorImpl` 的 `register` 两个重载是 stdx 接口实现（`http_package_interfaces.md:184-191`），按接口实现豁免，但实现是占位抛异常，另记 #19 |
| §2 重复逻辑 | 2 | 同文件两两比对 + 跨文件搜相同字面量：下载读取循环两处（#14）、`HttpStatusOnlyHandler` 内 status+Accept 逻辑两遍（#15）。另记「手写 Content-Disposition」与 `f_http.ContentDispositionBuilder` 能力重复，并入 #5；`MVCStarter` 的 12 段 builder 接线是同类但参数各异的样板，不算重复 |
| §3 空实现 | 1 | `HttpRequestDistributorImpl.register(String, HttpRequestHandler)` / `register(String, (HttpContext)->Unit)` 直接抛 `MVCException('... not implemented')`（#19）；`FileDownload.end()` 在 `multi == false` 时是空实现（并入 #3）；`OverallStopwatch` 的 `unsafeZeroValue` 占位属有意空值（有 `if(switch)` 守卫，记 #17） |
| §4 栈溢出 | 0 | 本部分无递归：`HttpStatus`/`MVCConfig`/`RequestArgMeta` 全是平铺查询；`FileDownload.exec` 的 `spawn` 是单层；`runDownloadTask` 无自调用 |
| §5 OOM | 0 | 未发现全量物化/按不可信长度预分配；`Array<Byte>(downloadBufferSize)` 由配置且每次下载一份，不算无界。唯一增长面是线程（归 §12.1，见 #8） |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据，`MultiRequestMethodHandler` 与 `MVCConfig` getter 的疑似热点只进「待验证假设」#4/#5 |
| §6.2 大粒度锁 | 0 | 本部分仅 `MultiRequestMethodHandler.mutex`（注册期）、`AllowsCache.mutex`（只在首次 OPTIONS 建串，临界区内只有字符串拼接）；无锁内 I/O/日志/回调 |
| §6.3 并发串行 | 0 | 无 `spawn...get()`、无单消费者串行段；`FileDownload` 的 `spawn` 是「提交后不等」，不算串行 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`/`remove(at:0)`；`allowsOf` 只遍历一次 `metas`，且已缓存（`AllowsCache`） |
| §7 降堆内存方案 | 1 | `HttpStatus.values` 数组缓存（优化方案 2） |
| §8 降 CPU 方案 | 1 | 路由热路径方法串解析（优化方案 1） |
| §9 local mode 可行性 | 0 | 本部分热点函数无「函数内创建、函数内释放的大对象」：`handle` 的临时对象是个位数小对象，`FileDownload` 的缓冲跨线程使用（逃逸），收益无法用峰值内存证明 ⇒ 不立项 |
| §11 现有代码的 BUG（存量） | 21 | 本部分全部 21 条均为存量（快照模式无基线）；已核对每条的边界/空值/错误处理/资源/并发/契约，逐条见「发现」 |
| §12 并发安全与锁粒度 | 1 | 安全面：`metas` 无锁读 + 注册期 `static mutex` 写（可行，注册只发生在模块静态初始化，`MVCStarter.generateAndRegister*` 在 `initial_` 之后调用会抛；stdx 侧也约定「启动后 register 结果未定义」，`http_package_interfaces.md:196-200`）；`HttpStatus.statuses`/`RequestMeta.staticResourceBytes` 读多写少且写只在初始化。锁粒度面：无大粒度锁。唯一并发风险是 #8 的无界线程 |
| §13 文档一致性 | 0 | 本部分无 `.md`（模块 README 与 `doc/spec/**` 属第 1/3/4 部分）。仅作交叉核对时用到 README `:37`：`mvc_maxConcurrentSteams` 的拼写 README 已显式说明「键名里的 Steams 是源码拼写」，不构成文档漂移 |
| §14 功能完备性与 README 覆盖 | 1 | #10（`@OnWSPong` 的 `mediaType` 承诺未接线）；`MVCStarter.register(mediaType)`、`FileDownload.noContent` 等 public API 是否进 README 由第 1/3/4 部分对照，本部分不重复计 |
| 文件覆盖 | 20/20 | `files/f_mvc.part2.txt` 的 20 行全部读完，无缺 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 10 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

> 本部分 21 条缺陷全部为「存量」（工作区快照，无基线可比）。是否纳入修复待用户决定，本报告不代为取舍。

## 总评

本部分代码整体处于「功能齐、边界松」的状态：结构分层清楚（分发器 → `MultiRequestMethodHandler` → `RequestMeta`/`WSMeta`，下载走独立 `FileDownload` 门面），前几轮加固留下的注释把设计意图写得很透（`AllowsCache` 的「构建一次」、`isWebSocketUpgrade` 的握手路由、`runDownloadTask` 的失败自收尾），可读性明显高于同仓平均水平；`HttpStatus`、`Redirect`、WS 注解这几个文件是纯数据/契约，没有缺陷。

真正的风险集中三处：

1. **HTTP 方法语义**（#1、#2）：HEAD 被当成「GET 的别名」，HEAD-only 路由恒 405、未知方法（TRACE/CONNECT）变 500。这两条都在请求主路径上，属可用性缺陷，建议优先排期——改动小（一个 `match` 分支 + `tryParse`），收益是行为可预期。
2. **下载的响应体生命周期**（#3、#8、#9）：成功路径不 `pipe.end()`、`start()/build()` 在 `spawn` 之后、每次下载一条线程、204 带 body。这些点单独看都「能跑」，但依赖 `SyncByteBuffer` 把空缓冲当 EOF 的巧合，且仓内没有一条下载端到端用例（成对的历史记录也确认未跑 e2e）。建议先补 e2e（单文件 / 多文件 / 中途失败），再按 #3 的建议把「开始」提到请求线程、「结束」放进统一收尾。
3. **静默降级**（#6、#7、#10、#4）：无路由不监听、`tlsPath` 写错走明文、`@OnWSPong` 的 mediaType 丢弃、CORS 预检头名拼错——四个场景的共同点是「不报错、行为与配置意图相反」，排障成本最高，建议统一改成「配置/契约不成立就启动失败或 `warn`」。

死代码与重复逻辑面很干净：只有 `MVCConfig.getStatus`、`RequestArgMeta.contains` 两处零引用符号，重复逻辑两处（下载读取循环、`HttpStatusOnlyHandler` 内的 Accept 处理），都不涉及行为漂移。性能方面本轮没有任何测试数据，因此未把「路由串解析」「`HttpStatus.values` 重建」写成结论，只进「待验证假设 / 优化可行性方案（无基线）」。

测试覆盖的短板需要点名：现有 4 个测试文件全部只钉「包内接缝」（`runDownloadTask`、`allowsOf`、`AllowsCache`、`isWebSocketUpgrade`、未命中 handler 的类型），`distribute` 的真实分发、HEAD/OPTIONS 的响应头与状态码、`HttpStatus.resolve/valueOf` 的解析结果、`MVCConfig` 的配置解析与非法值路径全部无用例。这也是 #1/#2/#7/#13 能长期存活的直接原因。
