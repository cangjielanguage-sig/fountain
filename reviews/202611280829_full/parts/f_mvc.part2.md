# f_mvc 模块审查报告（第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（59 个源文件；**本部分 15 个**，第 2/4 部分）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，无 diff 可比 ⇒ 本部分所有缺陷来源统一记「存量」；`git blame` 抽样核对，涉及行均为 `4be871f2fd`（2026-10-02）等历史提交）
- **审查重点**：HTTP 状态 / 启动器 / 媒体类型 / 多方法分发 / WebSocket 回调 / 停止计时；并发安全与生命周期；死代码；重复逻辑；空实现；OOM；存量 BUG
- **报告版本**：v1（部分报告，最终由主 Agent 合并为 `docs/review/f_mvc_review_20261128.md`；下文编号为本部分内序号）
- **已有性能资料**：未提供（`scope.md` 明示）⇒ 本部分无「热点瓶颈」级发现，性能类结论只出现在「优化可行性方案 / 待验证假设」
- **构建告警旁证**：`f_mvc/target/release/.build-logs/f_mvc@fountain/f_mvc@fountain.aarch64-unknown-linux-gnu..errlog`（既有构建产物，非本轮运行）——用于死代码 / 不可达分支的机械取证

## 发现

### 1. [一般][存量] `ErrorHttpRequestHandler` 返回 `Array<Byte>` 时响应体被当成字符串输出，违反接口契约

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:159-163`（`match(resp)` 分支序；`case x: Array<Byte>` 在 :163）
- **来源**：存量（`git blame -L 158,182` ⇒ `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §1（不可达分支）+ §11（契约与实现不符）+ §3（承诺的能力实际未接通）
- **证据**：静态确定 —— 既有构建日志明确报 `MultiRequestMethodHandler.cj:163:26 unreachable pattern: case x: Array<Byte>`：`Array<Byte>` 实现了 `ToString`，因此永远被上一行 `case x: ToString => b.body(x.toString())` 截获
- **描述**：README 与接口注释把「返回 `Array<Byte>` ⇒ 响应体就是这段字节」写成明确契约（`f_mvc/README_en.md:74`、`README_en.md:205`）。实际执行：字节数组先被 `toString()` 变成 `"[104, 101, 108, ...]"` 这样的十进制文本，再被当作 body 写出（同时 `Content-Type` 还是从 `Accept` 抄来的值，见发现 #2）。后果是二进制错误体（图片、protobuf、加密载荷）被静默损坏，客户端解析失败，且不会报任何错。
- **建议**：把 `case x: Array<Byte>` 提到 `ToString` 之前（`String` 分支之后），或用 `match` 前先判 `resp is Array<Byte>` 单独处理；修完用一条「ErrorHttpRequestHandler 返回 `@[0x00, 0xff]` ⇒ 响应体长度 2」的用例钉住。

### 2. [一般][存量] 错误响应的内容协商是第二份实现，与正常响应行为漂移（并错误地把 `Accept` 原串写进 `Content-Type`）

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:155-180`（`Content-Type` 取 `Accept` 原串在 :155-158；协商主体 :164-180；`accept.isEmpty()` 死条件在 :165）；对照实现 `f_mvc/src/RequestMeta.cj:319-357`
- **来源**：存量（同上）
- **判据**：review-checklist §2（跨层复制、行为漂移）+ §11（契约不符）+ §6.4（同一对象重复序列化）
- **证据**：静态确定 —— 两处都做「`MediaTypes.tryParse` → `fromData` → `AcceptQueue`」，但选择规则不同；`RequestMeta.respond` 用 `AcceptQueue(renderAccept).first()` 按 q 值取第一项并写单项 `Content-Type`（`RequestMeta.cj:333-357`），错误路径用 `accept.contains('*/*')` 直接短路到 JSON
- **描述**：四个可复现的偏差，全部落在错误响应（`HttpStatusOnlyHandler` 的 `Bean` 分支，即 `mvc_internalServerErrorMessageKind=BEAN` 或 `RequestMeta.cj:577` 的 500 路径）：① `Content-Type` 被写成请求的**整个** `Accept` 串，例如 `application/json, text/plain;q=0.9` —— 单值头里出现多个媒体类型，属非法头值，严格客户端会拒绝；② `Accept: application/xml, */*;q=0.1` 时因 `contains('*/*')` 先命中而返回 JSON，无视 q 值偏好（正常响应路径会选 XML）；③ 请求**没有** `Accept` 头时 `accept` 为空串，`case x: ToData where accept.size > 0` 不匹配，直接落到 `_ => b.body(status.reasonPhrase)`，`ToData` 载荷整体丢失（普通 CLI / 服务间调用不带 `Accept` 很常见）；④ 同一 `x.toData()` 在多候选分支里被反复调用（`:171` 在 `while` 内每轮一次，另有 `:166/:175/:177/:179`），最坏 N 次完整序列化；⑤ `:165` 的 `accept.isEmpty()` 位于 `where accept.size > 0` 守卫之内，恒为假，是死条件。
- **建议**：不要在错误路径重写一套协商。把 `RequestMeta.respond` 里的「`Accept` → 单个 media type + bytes」抽成包内函数（例如 `func negotiate(accept: ?String, result: ToData): (String, Array<Byte>)`），两处共用；`Content-Type` 只写选中的那一个；无 `Accept` 时按 `application/json` 兜底而不是丢 body；`toData()` 只算一次并复用。

### 3. [一般][存量] 未识别的 HTTP 方法直接抛异常，客户端拿到 500 而不是 405

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:64`（`RequestMethod.parse(request.method)`）；抛点 `f_mvc/src/RequestMethod.cj:95-97`
- **来源**：存量（同上）
- **判据**：review-checklist §11（边界 / 错误处理缺失：外部输入未校验）
- **证据**：静态确定 —— `parse` 对 `tryParse` 的 `None` 直接 `getOrThrow {IllegalArgumentException}`，而 `handle` 内没有任何 `try`/`catch`，异常穿到 stdx 分发层
- **描述**：`request.method` 完全由客户端控制。任意非 8 个字面量之一的方法（`TRACE`、`CONNECT`、`FOO`，或大小写/空白异常值）都会在此抛 `IllegalArgumentException`，结果是连接异常或 500，而正确语义是 405 Method Not Allowed（未知方法也可 501）。这也是一个可被外部低成本触发的异常路径（每次请求一次异常构造 + 栈展开 + 服务端错误日志）。
- **建议**：改用 `RequestMethod.tryParse(request.method)`，`None` 时直接走 `METHOD_NOT_ALLOWED`（并按发现 #5 补 `Allow`）；若担心 `CONNECT` 的隧道语义，至少在白名单外统一 405。

### 4. [一般][存量] `@RequestMapping(params/headers)` 条件不满足时返回 501 Not Implemented

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:68-69`（`!meta.check(ctx)` ⇒ `NOT_IMPLEMENTED`）；`check` 的语义见 `f_mvc/src/RequestMeta.cj:190-193` 与 `f_mvc/src/RequestCondition.cj:19-30,84-155`
- **来源**：存量（同上）
- **判据**：review-checklist §11（语义与命名 / 规范不符）+ §13（该行为无任何文档）
- **证据**：静态确定 —— `meta.check` = `headers.check(request.headers) && params.check(request.form, request.url)`，判定的是**请求是否满足路由条件**（`params`/`headers` 表达式、`@PathVariable` 正则），失败原因完全在客户端
- **描述**：控制器声明 `params = "action=create"` 而请求未带该参数时，路由条件不成立，服务端回 `501 Not Implemented`。501 的定义是「服务器不支持该功能」，会被监控/网关当作服务端缺陷告警，也会误导客户端（应重试还是改请求？）。README 未记载这一映射（`grep 501` 于 `README.md`/`README_en.md` 均无命中），属未文档化的错误契约。
- **建议**：条件不匹配应回 400（参数/头不满足）或 404（无匹配路由），按框架策略二选一并写进 README；若确实想区分「路径存在但条件不满足」与「路径不存在」，用 404 + 明确 reason phrase 比 501 更安全。

### 5. [一般][存量] 405 响应不带 `Allow`，OPTIONS 预检头名写成 `Access-Control-Allow-Method`（缺 s）

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:21,126`（405 只设状态与 reason phrase）、`:107-120`（OPTIONS 分支）、`:111`（`Access-Control-Allow-Method`）、`:231-239`（`Allow` 串把 `WS` 也拼进去）
- **来源**：存量（同上）
- **判据**：review-checklist §11（与规范冲突）+ §12.2/§6.2 无关（此处是按规范的正确性）
- **证据**：静态确定 —— RFC 7231 §6.5.5 要求 405 必须带 `Allow`；Fetch/CORS 规范定义的预检响应头是 `Access-Control-Allow-Methods`（复数）
- **描述**：三个独立偏差：① 所有 405 均由 `HttpStatusOnlyHandler(HttpStatus.METHOD_NOT_ALLOWED)` 产生（`:21`、`:126`），只写状态与文本，**从不写 `Allow`**，客户端无法得知该路径支持哪些方法；② 预检响应写的是 `Access-Control-Allow-Method`（`:111`），少一个 s，浏览器按规范不会识别，跨域预检实际会失败（`Allow` 有写，但浏览器不读它）；③ `allowsOf` 遍历 `metas` 时把 `RequestMethod.WS` 也当成 HTTP 方法拼进 `Allow`（`:231-239`），产生 `Allow: OPTIONS, GET, WS` 这种含非标准 token 的值。
- **建议**：405 分支复用 OPTIONS 分支的 `allowsCache.get()` 写 `Allow`；头名改为 `Access-Control-Allow-Methods`；`allowsOf` 跳过 `WS`（它只是内部路由键，不是 HTTP 方法）。补一条响应头断言的用例。

### 6. [一般][存量] 未注册 `HEAD` 时不会回退到 `GET`，直接 405

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:121-126`
- **来源**：存量（同上）
- **判据**：review-checklist §11（边界 / 与 HTTP 语义不符）
- **证据**：待确认 —— RFC 7231 §4.3.2 要求服务器对 HEAD 返回与 GET 相同的头（无 body）；当前只有 `metas.get(HEAD)` 命中时才进入 `case (Some(m), HEAD)`，否则落到 `case _ => METHOD_NOT_ALLOWED`。缺的信息：这是有意「只支持显式注册 HEAD」还是漏了回退
- **描述**：`case (Some(m), HEAD)` 内已经实现了「用 GET 的 handler 处理」的回退（`:121-124`），说明设计上认可 HEAD↔GET 同源；但该分支的守卫是 `metas.get(HEAD)` 为 `Some`，即**必须先显式注册一个 HEAD 路由**才会回退。绝大多数控制器只声明 `@RequestMapping(method: GET)`，于是 `HEAD /path` 得到 405，反直觉且会让健康检查/缓存探测类客户端失败。
- **建议**：把分支改为「`method == HEAD` 且 `metas.get(HEAD)` 为空而 `metas.get(GET)` 非空 ⇒ 走 GET」，或在注册期自动为每个 GET 路由生成 HEAD 别名（后者能顺带让 `Allow` 正确）。若确为有意限制，README 需写明「HEAD 必须显式声明」。

### 7. [一般][存量] 无路由注册时服务器静默不启动；初始化失败后 `start()` 也静默空转

- **位置**：`f_mvc/src/MVCStarter.cj:24-30`（先 CAS 再判 `registered`，未注册直接 `return`）、`:106-108`（`starter?.doStart()`）
- **来源**：存量（`git blame -L 24,30` / `-L 106,108` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（错误处理缺失 / 静默失效）+ §12.1（生命周期状态机）
- **证据**：静态确定 —— `initial_.compareAndSwap(false, true)` 在判断 `registered` 之前执行；`starter` 是 `?MVCStarter` 且 `start()` 用 `?.` 吞掉 `None`
- **描述**：三条失败路径都没有任何日志或异常：① 应用只配了 `mvc_staticResourceRoot`（`StaticResourceOrNotFoundHandler` 本来就负责静态资源，`f_mvc/src/HttpRequestDistributorImpl.cj:60-64`）而没有任何 `@Controller` ⇒ `registered == false` ⇒ `initialize()` 直接返回 ⇒ `start()` 无事可做 ⇒ 进程正常退出，用户以为服务启动了；② `initialize()` 中途抛错（TLS PEM 非法、`servicePoolConfig` 非法、`builder.build()` 失败）时 `initial_` 已是 `true`，之后 `start()` 因 `starter == None` 静默返回，错误只在首次初始化时出现一次，重启后同样静默；③ 第二次调用 `initialize()` 抛 `mvc has been started`，但此时可能根本没启动，错误信息误导。此外 `generateAndRegister` 的守卫是 `initial_`（`:84-90`），错误文案却说 "before calling MVCStarter.start()"，契约与实现不一致。
- **建议**：`start()` 在 `starter == None` 时抛明确异常（或记录 error 并返回失败码）；`initialize()` 把 `initial_` 的置位放到 `builder.build()` 成功之后（失败时回滚 `compareAndSwap(true, false)`），无路由时至少 `log.info` 说明「未注册任何路由，HTTP 服务不启动」；错误文案与守卫统一（要么都按 `initialize`，要么改成 `started` 标记）。

### 8. [一般][存量] 配置解析失败静默降级为「未配置」，非法值不会报错

- **位置**：`f_mvc/src/MVCConfig.cj:165-170`（`duration`）、`:202-207`（`uint32`）、`:125-153`（`servicePoolConfig`）、`:240-245`（`getMessageKind` 之外的容错风格对照）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失：失败路径当成功）+ §5 无关
- **证据**：静态确定 —— 四个 helper 都是「`tryParse`/转换失败 ⇒ `None` ⇒ 调用方用默认值」，全程无日志、无异常
- **描述**：`mvc_readTimeout=5`（漏单位）、`mvc_keepAliveTimeout=5x`、`mvc_maxConcurrentSteams=-1`（`UInt32(-1)` 溢出为 `None`）、`mvc_servicePoolCapacity=abc`、`mvc_headerTableSize=99999999999` 全部被当成「没配」，服务以 stdx 默认值启动。运维只能通过行为差异发现配置没生效，而这些参数（超时、请求体上限、HTTP/2 窗口）恰恰是排障时最先怀疑的对象。
- **建议**：helper 改为 `tryParse` 失败时 `log.warn` 并带上键名与原值（或直接抛 `MVCException`，与 `tlsVerifyMode` 的严格风格一致）；`UInt32` 溢出单独报「超范围」；`servicePoolConfig` 的三键部分配置要么全有要么报错（见发现 #17 的文档冲突）。

### 9. [一般][存量] 配置的静态资源目录不存在时，`mvcStaticResourceRoot` 抛 `FSException`（且发生在类初始化期）

- **位置**：`f_mvc/src/MVCConfig.cj:283-291`；触发点 `f_mvc/src/RequestMeta.cj:45`（`private static let STATIC_RESOURCE_ROOT = MVCConfig.mvcStaticResourceRoot`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理不完善 / 启动期故障不明确）
- **证据**：静态确定 —— std 的 `canonicalize(String)` 在路径不存在或无权限时直接 `throw FSException`（`cangjie_runtime/stdlib/libs/std/fs/path.cj:16-23`），本函数无 `exists` 检查、无 try
- **描述**：`canonicalize` 的语义是「解析真实路径」，要求路径**已存在**。把目录名写错（或容器里挂载点未就绪）时，异常不是在启动校验阶段抛出，而是在 `RequestMeta` 类首次初始化时抛出（`STATIC_RESOURCE_ROOT` 是 `static let`），错误栈指向静态初始化，排查成本高；若该类初始化被 GC/Bean 流程包住，还可能表现为「首个请求 500」而非启动失败。另外该 prop 每次访问都会做一次 `getcwd`/`canonicalize` 系统调用，作为 public prop 反复调用是纯浪费。
- **建议**：配置值在启动阶段校验一次（`exists && isDirectory`），不存在时给明确的 `MVCException("mvc_staticResourceRoot does not exist: ...")`；`Path` 结果缓存到 `static let`，prop 直接返回缓存。

### 10. [一般][存量] `HttpStatus` 的废弃别名覆盖注册表：`valueOf(413/414/421)` 返回旧名/非标准名，注释与 README 却写相反

- **位置**：`f_mvc/src/HttpStatus.cj:794-799`（`statuses` 由 `values` 顺序写入，同码后者覆盖前者）、`:845-847`（413/414 两个别名都在 `values` 里）、`:854`（421 位置只有 `DESTINATION_LOCKED`）；受影响的常量定义 `:440-457`、`:464-480`、`:548-562`；相反的说法见 `:450-451`、`:474` 与 `f_mvc/README.md` 的同段复制
- **来源**：存量
- **判据**：review-checklist §11（契约与注释不符）+ §13（文档与实现不一致）
- **证据**：静态确定 —— `static init` 用 `for (status in values) { statuses[status.value] = status }`，`values` 中 `PAYLOAD_TOO_LARGE` 在前、`REQUEST_ENTITY_TOO_LARGE` 在后（同为 413），`URI_TOO_LONG` 在前、`REQUEST_URI_TOO_LONG` 在后（同为 414），两处注释却写「deprecated in favor of … which **will be returned** from `HttpStatus.valueOf`」；`MISDIRECTED_REQUEST` 根本不在 `values` 里，421 只能解析成 `DESTINATION_LOCKED`
- **描述**：实际行为：`HttpStatus.valueOf(413).reasonPhrase == "Request Entity Too Large"`（RFC 2616 旧名）、`valueOf(414).reasonPhrase == "Request-URI Too Long"`、`valueOf(421).reasonPhrase == "Destination Locked"`（非标准，标准是 "Misdirected Request"）。`==` 只比 `value`，所以等值判断不会暴露问题，只有 `toString()`/`reasonPhrase` 落进响应体或日志时才显形（例如 `MVCConfig.getInternalServerErrorMessage` 的兜底文本）。`values` 也因此不是「全部常量」：`MOVED_TEMPORARILY`、`MISDIRECTED_REQUEST` 缺失（302 恰好因 `FOUND` 在后而正确，属侥幸）。
- **建议**：注册表按「标准名优先」显式构造：把废弃别名移出 `values`（或改成 `statuses.putIfAbsent`），让 413→`PAYLOAD_TOO_LARGE`、414→`URI_TOO_LONG`、421→`MISDIRECTED_REQUEST`；`values` 要么补全要么在注释里声明「不含废弃别名」；同步修正 `:450-451`、`:474` 的注释与 README 同段。

### 11. [轻微][存量] `MVCConfig.getStatus` 是无调用者的死代码

- **位置**：`f_mvc/src/MVCConfig.cj:233-239`
- **来源**：存量
- **判据**：review-checklist §1（`private` 符号全仓搜无引用）
- **证据**：静态确定 —— 全仓 `grep getStatus` 仅命中定义处；既有构建日志 `warning: unused function:'getStatus'`（errlog :179-182）
- **描述**：私有 `static func getStatus(key:default:)` 无任何调用者，属于旧配置读取方式的残留；它还藏着「配置值非法时 `valueOf` 抛异常」的语义，若将来被误用会把配置错误变成运行期崩溃。
- **建议**：删除；若确实需要「配置驱动状态码」，按发现 #8 的严格策略重写并加调用点与用例。

### 12. [轻微][存量] HEAD 分支的模式变量 `m` 绑定后未使用

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:121`
- **来源**：存量
- **判据**：review-checklist §1（读了不用）
- **证据**：静态确定 —— `case (Some(m), HEAD) =>` 之后的分支只使用内层 `metas.get(GET)` 的 `ms`，`m` 从未被读取
- **描述**：读代码时会误以为 HEAD 的 handler 列表参与了处理，实际完全没用；与发现 #6 同处一段，属残留写法。
- **建议**：改为 `case (_, HEAD) =>`，或在实现 #6 的回退时真正用上 `m`。

### 13. [轻微][存量] `DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND` 仓内零引用，也未进 README

- **位置**：`f_mvc/src/MVCConfig.cj:35`
- **来源**：存量
- **判据**：review-checklist §1 硬原则一（对外可达的 public 不判死代码，仅记信息）+ §14（公开常量未文档化）
- **证据**：静态确定 —— 全仓 `grep DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND` 仅命中定义；`README.md` 的「其他公开 API · MVCConfig」清单未列该符号（`:1328`）
- **描述**：名字里的 "PRIVILEGE" 在 `FailureMessageKind`/`AuthHandler` 体系里已无对应使用者（错误消息 kind 走 `getInternalServerErrorMessageKind`），疑似旧权限失败消息机制的遗留。它是对外可达的 public 常量，按硬原则一不算死代码，但「无引用 + 无文档」意味着没人会正确使用它。
- **建议**：确认无下游依赖后删除；若保留，在 README 写清用途，并给出唯一读取点。

### 14. [轻微][存量] `OverallStopwatch` 用 `unsafeZeroValue` 占位关态字段，开关在 static init 就固定

- **位置**：`f_mvc/src/OverallStopwatch.cj:19-28`（`switch`/`log`/`start` 的静态初始化）、`:30-38`、`:43-51`、`:64-68`
- **来源**：存量
- **判据**：review-checklist §10（可维护性 / 可测试性）+ §11（不安全 API 使用）
- **证据**：静态确定 —— 关态时把 `AbstractLogger` 与 `ThreadLocal<(MonoTime,String)>` 都设为 `unsafeZeroValue`，之后仅靠 `if (switch)` 保证不解引用
- **描述**：代码正确性依赖「三处 `if (switch)` 一个都不能漏」这一隐含契约：任何新增的计时读取点若忘了判断，就会对零值对象发消息（NPE/未定义行为）。同时 `switch` 是 `static let`，在类首次使用时绑定配置，运行期改配置无效果、单测也无法开启真实计时（`bug-mvc-archived-20261006.md:119` 已自认「测试里改配置拿不到可用 logger」）。风险目前为零（现有路径都有守卫），但属易碎结构。
- **建议**：把三件东西收进一个 `?Stopwatch`（`None` 即关闭）或用 `Option<AbstractLogger>`/`Option<ThreadLocal<...>>`，让「关闭」由类型表达；`switch` 若需要可测，改成可注入的 `var`/构造参数，默认值仍取自配置。

### 15. [轻微][存量] 可见性建议：`MultiRequestMethodHandler` 可降为 `internal`，`MVCStarter.closeGracefully` 应为 `private`

- **位置**：`f_mvc/src/MultiRequestMethodHandler.cj:18`（`public class`，但构造器 `:33` 无修饰符 ⇒ 包内）；`f_mvc/src/MVCStarter.cj:113`（`public func closeGracefully`）
- **来源**：存量
- **判据**：review-checklist §1「可见性建议」（不是死代码）+ 硬原则一
- **证据**：静态确定 —— `MultiRequestMethodHandler` 的唯一构造点在包内（`HttpRequestDistributorImpl.cj:25-27`），外部即使拿到类型也无法构造；`closeGracefully` 全仓唯一调用点是 `MVCStarter.cj:21` 的 `ExitCallbacks.atExit(0, closeGracefully)`，`MVCStarter` 实例从未对外暴露（`starter` 为 `private static var`，构造器 `private`）
- **描述**：两者都在扩大公共面：`MultiRequestMethodHandler` 出现在 README 的公开 API 清单里（`:1323`）却没有可用入口；`closeGracefully` 出现在 README（`:1328`）却永远拿不到实例。对外承诺了做不到的事，也让「哪些是扩展点」变得模糊。
- **建议**：`MultiRequestMethodHandler` 降为 `internal` 并从 README 公开清单移除；`closeGracefully` 改 `private`，若确实需要外部优雅停机，另加 `public static func shutdown()`（内部判 `starter`）。收窄前确认无下游依赖（本项目允许破坏性变更，但仍需用户拍板）。

### 16. [轻微][存量] `MediaType.cj` 用 `public import fountain::f_http.*` 整包再导出

- **位置**：`f_mvc/src/MediaType.cj:18`
- **来源**：存量
- **判据**：review-checklist §10（设计 / 可读性：命名与内容不符、公共面过宽）
- **证据**：静态确定 —— 该文件只有一行再导出；`f_http` 侧导出的符号不止媒体类型（`MediaType`/`MediaTypes` 之外还有 `Multipart*`、`ContentDisposition*`、`HttpConfig` 等，见 `f_http/src/*.cj`）
- **描述**：文件名承诺「MediaType」，实际把整个 `f_http` 公共面挂到 `f_mvc` 上；`import fountain::f_mvc.*` 的使用者会意外看到 Multipart / ContentDisposition 等与 MVC 无关的类型，且未来 `f_http` 新增顶层名时会直接扩大 `f_mvc` 的公共契约（潜在命名冲突）。
- **建议**：改成显式符号再导出（`public import fountain::f_http.{MediaType, MediaTypeException, ...}`），文件名与实际内容对齐；其余类型由使用者自行 `import fountain::f_http.*`。

### 17. [轻微][存量] README 说业务线程池「三个键必须同时指定」，实现支持任意子集

- **位置**：文档 `f_mvc/README.md:45`（对照 `README_en.md` 同段）；实现 `f_mvc/src/MVCConfig.cj:125-153`（八个 `match` 分支覆盖全部 `Some`/`None` 组合，任意子集都会构造出 `ServicePoolConfig`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致）
- **证据**：静态确定 —— 代码对 `(Some, None, None)`、`(None, Some, None)`、`(None, None, Some)` 都返回了配置对象，只有全 `None` 才返回 `None`
- **描述**：按 README 只配 `mvc_servicePoolCapacity=64` 的用户会以为「不生效」，实际生效（队列用 stdx 默认）；反过来，以为「配一个就够」的用户在部分版本里可能拿到与预期不同的池行为。文档与实现二者必有一错。
- **建议**：二选一并对齐——推荐保留「任意子集生效」，把 README 改成「未指定的键沿用 stdx 默认值」；若要求全配，则代码在子集时 `log.warn`。README 行号属第 4 部分文件，此处只做跨部分记录，合并时去重。

### 18. [轻微][存量] 核心分发逻辑没有单测，测试只覆盖两个包内接缝

- **位置**：`f_mvc/src/MultiRequestMethodHandler_test.cj:26-77`（仅 `allowsOf` / `AllowsCache` / `isWebSocketUpgrade` 三个用例）
- **来源**：存量
- **判据**：review-checklist §10（可测试性）+ §14（能力覆盖）
- **证据**：静态确定 —— 全模块测试文件里没有构造 `MultiRequestMethodHandler` 或 `HttpStatusOnlyHandler` 的用例；`handle` 的 405/415/501/HEAD/OPTIONS/WS 六条分支、错误响应的内容协商均无断言
- **描述**：发现 #1-#6 全部落在未覆盖区域，且都是「编译器/规范可判」的类型——只要有一条 `handle` 级用例（构造 `HttpContext` 或抽出「方法+头 → handler」的纯函数）就能提前拦住 #3/#6，`HttpStatusOnlyHandler` 的 body 类型用例能拦住 #1/#2。
- **建议**：把「方法 × Content-Type × Accept → 选中的 handler / 响应体类型」抽成纯函数并加表驱动用例；WS 握手识别已有用例，可复用同一套构造工具。

## 优化可行性方案

> 无基线数据，以下均为「待验证」，不进 `tasks.md`。

### [CPU] 错误响应的 `ToData` 只序列化一次

- **现状**：`MultiRequestMethodHandler.cj:164-180` 在一条响应里最多调用 `x.toData()` N+1 次（N = `Accept` 候选数，`:171` 在 `while` 内）；错误路径通常出现在 500/415 场景，QPS 不高
- **方案**：进入 `match` 前 `let bytes = x.toData()` 一次，后续分支只做 `mt.fromData(bytes)`；若与发现 #2 的「抽取共享协商函数」一起做，则该函数天然只算一次
- **预期**：单次错误响应省 N 次完整序列化（N 通常 1-3）；因错误路径占比低，端到端收益预计 < 1%
- **代价**：无（语义不变，必须保证 `toData()` 无副作用——当前 `ToData` 契约如此）
- **验证**：`cjpm bench -O2` 构造「返回大 `ToData` 的错误 handler + 3 个候选 `Accept`」，对比修复前后单请求耗时与分配量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `HttpStatus.values` 改为静态数组

- **现状**：`public static prop values` 每次 get 都新建一个约 70 元素的 `Array<HttpStatus>`（`HttpStatus.cj:806-878`）；类初始化时已调用一次，外部（含 README 使用者）也可能在循环里调用
- **方案**：`private static let all = [...]`，`values` 直接返回它（注意与 `static init` 的初始化顺序：`statuses` 的构建改为显式引用 `all`）
- **预期**：每次访问少一次 ~70 引用（约 560 B + 数组头）的分配与复制；仓内唯一调用点是 `static init`，实际收益接近 0
- **代价**：返回共享数组后，调用方若原地排序/修改会污染全局（现在是每次新副本）；需在注释里声明「只读」
- **验证**：仅在确认有外部高频调用后再做；`cjprof heap` 观察该数组分配次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存 / CPU] `MVCConfig.tlsConfig` 缓存解析结果

- **现状**：`MVCConfig.cj:77-118` 每次访问都 `File.readFrom` 两个 PEM 文件 + `X509Certificate.decodeFromPem` + `GeneralPrivateKey.decodeFromPem`；当前调用点在 `MVCStarter.initialize`（一次），但它是 public prop，外部可反复调用
- **方案**：首次解析后缓存到 `private static var`（配置按基线「启动只读一次」，无需失效），或在文档里标注「仅供启动期调用」
- **预期**：重复调用时省两次文件读 + 两次 PEM 解码（毫秒级/次）；无重复调用时收益 0
- **代价**：缓存后无法在进程内换证书（与基线一致）；`tlsConfig` 抛异常时不要把半成品写进缓存
- **验证**：单测里连续调用 1000 次计时对比；生产只调用一次则无需改
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求的 `RequestMethod.parse`（`toAsciiUpper` + 匹配）与 `metas.get` 哈希在路由总耗时中占可观比例 | `f_mvc/src/MultiRequestMethodHandler.cj:63-64,106` | 自耗时占比、调用频次 | `cjprof record` 跑 10 分钟稳态流量（GET/POST 各半，500 rps），看 `handle` 子树 self time |
| 2 | `Content-Type` 每请求做 `indexOf(';')` + 切片，可用注册期预编译的前缀匹配替代 | `f_mvc/src/MultiRequestMethodHandler.cj:74-80` | 该段占 `handle` 的比例 | 同上 profile，按函数粒度看 `String.indexOf`/切片调用次数 |
| 3 | 每个路径一个 `Mutex`（`AllowsCache`）在 OPTIONS 密集场景有可观测锁开销 | `f_mvc/src/MultiRequestMethodHandler.cj:209-224` | 锁等待时间、OPTIONS 占比 | 线程状态采样 + 全 OPTIONS 压测；若占比 <1% 则忽略 |
| 4 | `SIGTERM` 时 `closeGracefully` 在信号处理线程内阻塞（长 WS 连接）导致进程迟迟不退出 | `f_mvc/src/MVCStarter.cj:20-21` + `f_base/src/signal.cj:39-47` | 关闭耗时分布、是否有超时上限 | 保持 N 条 WS 长连接后发 SIGTERM，测 `closeGracefully` 到进程退出耗时；确认 stdx 是否有超时参数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/HttpStatus.cj` | .cj | ✅ | 见发现 #10；`values`/`statuses` 注册顺序逐条核对，series 与码段无错配 |
| 2 | `f_mvc/src/MVCConfig.cj` | .cj | ✅ | 见发现 #8、#9、#11、#13；配置键与 README 逐项对照 |
| 3 | `f_mvc/src/MVCInitializer.cj` | .cj | ✅ | 纯接口实现（`name`/`dependencies`/`initialize`/`start`），依赖只声明 `f_bean`；`f_config` 无 Initializer（按需读环境变量），不构成顺序风险 |
| 4 | `f_mvc/src/MVCStarter.cj` | .cj | ✅ | 见发现 #7、#15；`initial_`/`registered` 的 CAS 顺序与 `start()` 的空转均在 #7 |
| 5 | `f_mvc/src/MediaType.cj` | .cj | ✅ | 见发现 #16 |
| 6 | `f_mvc/src/MultiRequestMethodHandler.cj` | .cj | ✅ | 见发现 #1、#2、#3、#4、#5、#6、#12、#18 |
| 7 | `f_mvc/src/MultiRequestMethodHandler_test.cj` | .cj | ✅ | 3 条用例与接缝语义一致；覆盖缺口见 #18 |
| 8 | `f_mvc/src/OnWSBinary.cj` | .cj | ✅ | 注解类，参数被 `WSMeta.cj:385-388` 反射读取；`public const init` 是注解必需构造 |
| 9 | `f_mvc/src/OnWSClose.cj` | .cj | ✅ | 同上（标记注解，`WSMeta.cj:381-384`） |
| 10 | `f_mvc/src/OnWSOpen.cj` | .cj | ✅ | 同上（`WSMeta.cj:377-380`） |
| 11 | `f_mvc/src/OnWSPing.cj` | .cj | ✅ | 同上（`WSMeta.cj:393-396`） |
| 12 | `f_mvc/src/OnWSPong.cj` | .cj | ✅ | 同上（`WSMeta.cj:397-400`；该消费点忽略 `mediaType`，属范围外，见总评） |
| 13 | `f_mvc/src/OnWSText.cj` | .cj | ✅ | 同上（`WSMeta.cj:389-392`） |
| 14 | `f_mvc/src/OverallStopwatch.cj` | .cj | ✅ | 见发现 #14；`doStart`/`elapsed`/`takeStart`/`elapsedFrom`/`clearStart` 均有调用者 |
| 15 | `f_mvc/src/Redirect.cj` | .cj | ✅ | 三个工厂语义与注释一致（301/308、302/307）；`location` 原样写 `Location` 头（`RequestMeta.cj:391-395`），未做 CR/LF 过滤——调用方须保证输入可信，建议并入第 1 部分 #4 的同一条加固 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分按主 Agent 指定文件清单执行；模块 README 由其他部分覆盖，本报告只在与上述文件直接冲突时引用行号）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 6（#1/#2/#3/#4/#5/#10）、设计 3（#15/#16/#18）、可读性 1（#12）；语言特性核对：`ThreadLocal.set(?T)` 语义（`std/core/thread_local.cj:43-59`，`set(None)` 合法）、`Option` 传播（`checkProduces` 的隐式返回、`?HttpStatus`）、`struct` 值语义（`Redirect`/`MVCInitializer` 不可变字段）；安全性：未发现注入面（`Redirect.location` 由调用方控制，已在文件覆盖表标注） |
| §1 死代码 | 4 | 逐个 `private`/`internal`/`protected` 符号全仓搜：`MVCConfig.confPrefix/cryptoKit/isMVCDebugging/duration/uint32/getMessageKind/bufferSize` 均有调用者，`getStatus` 无（#11，编译器 warning 佐证）；`MVCStarter.log/starter/initial_/registered/listening/doStart` 均有调用者；`MultiRequestMethodHandler.log/METHOD_NOT_ALLOWED/UNSUPPORTED_MEDIA_TYPE/NOT_IMPLEMENTED/metas/mutex/allowsCache`、`AllowsCache.mutex/cached`、`OverallStopwatch.switch/log/start`、`HttpStatus.statuses` 均有使用。触发命中：`getStatus`（#11）、`Array<Byte>` 不可达分支（#1）、`accept.isEmpty()` 恒假（#2）、HEAD 的 `m` 未读（#12）。对外可达 public 的仓内零引用仅作信息：`MVCStarter.register`、`HttpStatus.is1xx/is2xx/is3xx`、`HttpStatus.resolve/values`、`DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND`（后者另见 #13，按硬原则一不判死代码） |
| §2 重复逻辑 | 1 | 已把本部分 15 个文件的函数体压成「输入→输出→副作用」摘要两两比对：命中 #2（错误响应协商 vs `RequestMeta.respond`，且 q 值/兜底/`Content-Type` 三处行为漂移，属「近似重复 + 缺陷」）；`MVCStarter.register` 与 `MediaTypes.register` 是一行转发（语义完全一致、无差异点，仅记冗余不单列）；`HttpStatus` 的 `is1xx…is5xx/isError` 是常量判断的展开，`Redirect` 两个工厂仅状态码不同（业务要求），均不算重复 |
| §3 空实现 | 1 | `OnWSOpen`/`OnWSClose` 的空类是有意的标记注解（`@Annotation[target:[MemberFunction]]`，由 `WSMeta.generate` 反射读取），不是空实现；`HttpStatusOnlyHandler` 无空分支。唯一命中：#1（契约承诺 `Array<Byte>` 原样输出，实际分支不可达 ⇒ 能力未接通） |
| §4 栈溢出 | 0 | 本部分无递归：`HttpStatus` 只有 `static init` 一次遍历；`MVCStarter` 无自调用；`MultiRequestMethodHandler.handle` 的局部函数 `check`/`handle` 互不递归；`HttpStatusOnlyHandler` 只单向调用 `ErrorHttpRequestHandler`；`OverallStopwatch` 全部是直线代码 |
| §5 OOM | 0 | 本部分无按不可信长度分配、无全量物化：`HttpStatus.statuses`/`values` 大小由常量表决定（~70）；`HttpStatusOnlyHandler` 的 `AcceptQueue` 规模受 `maxRequestHeaderSize` 约束；`BeanFactory.getFirst` 返回单例。`MultiRequestMethodHandler.metas` 只在注册期增长（路由数是编译期常量） |
| §6.1 热点瓶颈 | 0 | `scope.md` 明示无 profile / bench 数据，本部分不产生热点结论；候选点已进「待验证假设」#1-#3 |
| §6.2 大粒度锁 | 0 | 两处临界区均只保护不变量：`MultiRequestMethodHandler.register` 的静态 `Mutex` 内仅做 map 写入 + `log.debug`（注册期一次性，非主路径）；`AllowsCache.get` 内只做一次 `allowsOf` 拼接（首次 OPTIONS 一次，之后命中缓存，OPTIONS 本身稀少）。无 I/O、无外部回调、无嵌套取锁 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get()`、无单消费者队列；`server.serve()` 是唯一阻塞点且只在 `start()` |
| §6.4 低效算法 | 1 | #2 的「同一 `toData()` 在 `while` 内重复序列化」属可静态判定的重复工作（无性能数据 ⇒ 只列轻微并进优化方案）；`allowsOf` 单次 O(方法数) 拼接且已缓存；`metas` 全为哈希查找 |
| §7 降堆内存方案 | 2 | 「`HttpStatus.values` 静态数组」「`tlsConfig` 缓存解析结果」，均 `无基线（待验证）`；未写成结论 |
| §8 降 CPU 方案 | 1 | 「错误响应只序列化一次」，`无基线（待验证）`；路由热路径的优化只有线索，全部降级为待验证假设 |
| §9 local mode 可行性 | 0 | 本部分无可收益的函数内大对象：`HttpStatus.values` 返回的数组会逃逸（public 返回值），`HttpStatusOnlyHandler` 的临时 `AcceptQueue`/`Array<Byte>` 生命周期在单个错误响应内且只有几十字节~KB 级，峰值收益无法证明；`--experimental` 与工具链约束下不建议为这些函数引入 local mode |
| §11 现有代码的 BUG（存量） | 9 | #1/#2/#3/#4/#5/#6/#7/#8/#9 以 §11 为主判据（#10 计入 §13 行）；另核对了 `MVCStarter` 构造器内注册 `atExit` 的发布时序（`private let` 在主构造器体内已绑定，回调捕获的 `server` 状态完整，未发现不安全发布）、`HttpStatusOnlyHandler` 的 `resp is Unit` 判定、`OverallStopwatch` 的 `ThreadLocal` 清理对称性（`elapsed`/`clearStart` 都置 `None`），均无缺陷 |
| §12 并发安全与锁粒度 | 1 | 共享点与同步手段：`metas`（注册期写、启动后只读，写侧持 `MultiRequestMethodHandler.mutex`，读侧无锁——启动前完成的发布由 stdx 线程池的任务提交建立 HB）、`AllowsCache.cached`（自身 `Mutex`）、`HttpStatusOnlyHandler` 实例（全字段 `private let`，不可变，可安全共享）、`HttpStatus.statuses`（static init 一次写入后只读）、`MVCStarter.starter`（仅初始化线程写、`start()` 同线程读）。命中 #7（生命周期状态静默失效）；另记录一条轻微竞争面：`MVCStarter.generateAndRegister` 的 `initial_.load()` 是检查-然后-写入，与 `initialize()` 的 CAS 之间存在窗口，并发调用会让 `metas`/`PathPattern` 在服务期被写（与第 1 部分对同一闸门的评估一致，按「调用方违反启动前注册约定」记轻微，不单列编号） |
| §13 文档一致性（.md） | 2 | 本部分无 `.md` 文件；跨部分核对命中 #10（`HttpStatus` 注释与 README 同段声称 `valueOf` 返回新名，实际返回旧名）与 #17（README `:45` 与 `servicePoolConfig` 实现不符），README 行号归第 4 部分统计，合并时去重 |
| §14 功能完备性与 README 覆盖 | 1 | #13（`DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND` 与一批 `DEFAULT_*` 常量未进 README 的 `MVCConfig` 清单）。其余对照：`HttpStatus`（`README.md:243-1091`）、`Redirect`（`:216-240`）、`MVCStarter`/`MVCConfig`/`MultiRequestMethodHandler`/`MVCInitializer`（`:1321-1329`）、WS 注解（`:1194-1205`）均有对应段落；`MVCConfig` 的 `tls*`、`servicePool*`、`staticResourceRoot` 等配置键都在 `:9-57` 有示例，无「承诺但未实现」 |
| 文件覆盖（§13 等） | 15/15 | 本部分指定的 15 个 `.cj` 全部读完，无遗漏、无超时 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 10 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量共 18 条（10 一般 + 8 轻微），本部分无「本次改动」引入项；是否纳入修复待用户决定。另有 2 条跨部分文档一致性项（#10 的 README 同段、#17）只记不重复计数。

## 总评

本部分没有崩溃级缺陷，但「对外承诺」与「实际行为」之间有一圈系统性偏差，且集中在最容易被忽略的错误路径上：`ErrorHttpRequestHandler` 的 `Array<Byte>` 契约实际不可达（#1）、错误响应的内容协商是第二份实现且有四处行为漂移（#2）、405 不带 `Allow` 且预检头名拼错（#5）、路由条件不满足回 501（#4）、未知方法直接抛异常（#3）。这些都是静态可判、可用一条 `handle` 级用例钉住的类型，建议作为一组一起修，并补上 #18 提到的表驱动测试——否则每次改动路由层都只能靠端到端碰运气。

生命周期面的风险在 `MVCStarter`：无路由时静默不启动、初始化失败后 `start()` 静默空转（#7），叠加 `mvc_staticResourceRoot` 在类初始化期抛 `FSException`（#9），会让「服务到底为什么没起来」极难定位。这一块改动小、收益直接，建议优先于性能项。

`HttpStatus` 的别名覆盖（#10）属数据正确性小坑：等值比较不受影响，只有 reason phrase 会错，容易在响应/日志里长期存在却没人发现；`MVCConfig` 的静默降级（#8）同理，属于「配置写了但没生效」的运维陷阱。

正面结论也要写清：并发模型是干净的——注册期一次性写 + 启动后只读的发布方式成立，`AllowsCache` 只保护一个字符串缓存，`HttpStatusOnlyHandler` 全不可变字段，`OverallStopwatch` 用 `ThreadLocal` 把计时状态线程封闭；没有锁内 I/O、没有 `spawn().get()`、没有死锁路径，也没有栈溢出或 OOM 面（#5 OOM 维度全清）。`OverallStopwatch` 与 `Redirect` 的实现简洁、边界清楚；WS 六个注解是纯标记 + 两参构造，消费点齐全，没有空实现。性能与内存的候选改进因缺少基线数据，一律只以「优化可行性方案（无基线）/ 待验证假设」形式给出，不进修复清单。

范围外提示（只记不计数，供合并时参考）：`f_mvc/src/WSMeta.cj:398` 构造 `WSPongMeta` 时把 `mediaType` 写死为 `''`，忽略了 `@OnWSPong(mediaType:)`；`WSMeta.generate` 对同一类中重复的同类注解（多个 `@OnWSText` 等）只保留最后一个，前面的被静默覆盖。
