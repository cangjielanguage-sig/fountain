# f_mvc 模块审查报告

> **模块第 3/4 部分**（本报告只覆盖 `files/f_mvc.part3.txt` 列出的 20 个文件：`src/RequestCondition.cj` → `src/exception/WSException.cj`，全部为 `.cj`，0 个 `.md`。`README.md` / `README_en.md` / `doc/**` 与其余 39 个 `.cj` 由第 1、2、4 部分产出；README 只作为"承诺源"被引用，不计入本部分覆盖与统计。发现编号在本部分内独立编号，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（本部分 20 个 `.cj`，0 个 `.md`；模块共 59 `.cj` + 9 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：路由/参数绑定正确性、鉴权与权限（`@IgnoreAuth` 语义）、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 3/4 部分）

## 发现

### [严重][存量] #1 `@IgnoreAuth` 会连带静默跳过权限检查：分两个 Handler 注册的应用被越权

- **位置**：`f_mvc/src/RequestMeta.cj:249-253`（本部分调用方：仅当两个标记同时为真才短路，否则交给 Proxy）；根因在 `f_mvc/src/AuthHandler.cj:121-134`（第 4 部分文件）
- **来源**：存量（`git blame`：`RequestMeta.cj:249-253` 落在 `4be871f2fd 2026-10-02`；快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」、§10「安全性（越权）」、§14.1（文档承诺未实现）
- **证据**：静态确定 —— 两条分支叠起来即可判定：
  - `RequestMeta.checkAuth` 只在 `ignoreAuth && ignorePrivilege` 时直接放行；`ignoreAuth=true, ignorePrivilege=false` 走 `AuthHandlerProxy.instance.check(...)`（`RequestMeta.cj:249-253`）；
  - Proxy 里唯一会调用 `PrivilegeHandler` 的地方在 `else if (!param.ignoreAuth && let Some(h) <- sessionHandler ...)` 分支内部（`AuthHandler.cj:125-132`）。`param.ignoreAuth == true` 使这个条件为假，直接落到末尾 `else { AuthStatus.OK }`（`AuthHandler.cj:133-134`）⇒ **`privilegeHandler` 一次都不会被调用**；
  - 承诺源：`README.md:148`「`@IgnoreAuth` 忽略登录状态检查」（不含权限）；`README.md:185`「两个忽略标记会原样传给实现类，由实现类决定如何对待」。
- **描述**：应用按 README 推荐的"分离实现"方式注册一个 `UserSessionHandler` + 一个 `PrivilegeHandler` 时，任何带 `@IgnoreAuth`（或 `@GetMapping(..., ignoreAuth: true)`）的接口在跳过登录检查的同时把权限检查也跳过了。`RequestMapping.ignoreAuth` 与 `@IgnoreAuth` 是 OR 关系（`RequestMeta.cj:541,546`），所以这条路径就是最常见的用法。后果是**未登录/低权限用户可访问标注了 ignoreAuth 但仍要求权限的接口**，而日志上只会看到"鉴权通过"。
- **建议**：把 Proxy 的两段检查拆平，不要在"登录分支"里嵌套权限检查：
  `if (!param.ignoreAuth && let Some(h) <- sessionHandler) { let s = h.check(param); if (!s.isOK) { return s } }`，然后 `if (!param.ignorePrivilege && let Some(h) <- privilegeHandler) { return h.check(param) }`，最后 `OK`；`ignoreAuth && ignorePrivilege` 的短路只保留在 `RequestMeta.checkAuth` 一处。补一条用例：注册两个 Handler（各计数一次），`ignoreAuth=true, ignorePrivilege=false` 时断言 `PrivilegeHandler.check` 被调用且其 `NoPrivilege` 能拦住请求。
- **备注**：若第 4 部分已就 `AuthHandler.cj:121-134` 单独报同一根因，合并计一条即可（本部分是沿 `@IgnoreAuth` 语义链取证）。

### [严重][存量] #2 `WSMeta.pattern` 全仓从未赋值：12 个公开的 `extract*Arg` 必然抛 `NoneValueException`

- **位置**：`f_mvc/src/WSMeta.cj:140`（`var pattern = None<HttpRequestPathPatterns>`）、`f_mvc/src/WSMeta.cj:320-332`（`doExtractArgOption` / 两个 `doExtractArg`）、`f_mvc/src/WSMeta.cj:334-369`（12 个 `extractOpenArg` / `extractCloseArg` / `extractTextArg` / `extractBinaryArg` / `extractPingArg` / `extractPongArg`）；注册口 `f_mvc/src/HttpRequestDistributorImpl.cj:35-41`
- **来源**：存量（`git blame`：`WSMeta.cj:138-140` 落在 `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符」、§3「公开契约承诺有行为，实现不可用」、§14.1
- **证据**：静态确定 —— 三件事同时成立：
  1. `RequestArgMeta.doExtract` **无条件**执行 `pattern.getOrThrow()`（`f_mvc/src/RequestArgMeta.cj:20-23`），而 `doExtractArgOption` 传的正是这个成员 `pattern`（`WSMeta.cj:321`）；
  2. 全仓 `grep -rn "\.pattern" --include=*.cj`（排除 `.worktrees`）只有 3 处：`RequestMeta.cj:219`（读 `RequestMeta.pattern`）、`MultiRequestMethodHandler.cj:43`（写 `RequestMeta.pattern`）、`HttpRequestDistributorImpl.cj:37`（写 `requestMeta.pattern`）——**没有任何一处写 `WSMeta.pattern`**；
  3. `register<T>(path, meta: WSMeta<T>)` 只设了 `requestMeta.pattern = this`，没设 `meta.pattern = this`（`HttpRequestDistributorImpl.cj:36-39`）；`WSMeta` 也没有构造器或 setter 写它。
- **描述**：任何端点在 `@OnWSOpen` / `@OnWSText` 等处理器里调用 `meta.extractTextArg(ctx, "id")` 这类公开便捷 API 读路径变量/请求参数时，都会在 `pattern.getOrThrow()` 处抛 `NoneValueException`（不是业务异常，也没有可读信息）。宏生成的处理器参数绑定走的是 `exec(..., pattern, ...)` 的**入参** `pattern`（`WSMeta.cj:216,227,262-303`），所以只有"处理器内部再取参数"这条公开 API 是坏的。仓内 `grep` 对 12 个方法名零命中、无测试覆盖 ⇒ 缺陷长期潜伏。
- **建议**：在 `register<T>(path, meta: WSMeta<T>)` 里补 `meta.pattern = this`（一行，与 `requestMeta.pattern = this` 对齐）；更彻底的做法是把 `pattern` 作为 `handle` 闭包的入参传下去、删掉 `WSMeta.pattern` 这个可变成员。补一条用例：`WSMeta<Smoke>` 注册后调 `extractOpenArg`，断言不再抛 `NoneValueException`（没有匹配变量时返回 `None`）。

### [严重][存量] #3 未命中路由的兜底会从**进程工作目录**读文件：默认配置下任意可读文件可被未鉴权下载

- **位置**：`f_mvc/src/RequestMeta.cj:45`（`STATIC_RESOURCE_ROOT = MVCConfig.mvcStaticResourceRoot`）、`f_mvc/src/RequestMeta.cj:108-137`（`loadStaticResource`：`path[1..]` → `STATIC_RESOURCE_ROOT.join(p)` → `exists/FileInfo` → `File.readFrom`）、`f_mvc/src/RequestMeta.cj:693-721`（`StaticResourceOrNotFoundHandler`）；入口 `f_mvc/src/HttpRequestDistributorImpl.cj:57-65`（路由未命中即返回该 handler）；默认值 `f_mvc/src/MVCConfig.cj:283-290`（未配置 `mvcStaticResourceRoot` 时 `getWorkingDirectory()`）
- **来源**：存量（`git blame`：`RequestMeta.cj:45,108-137` 落在 `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「安全 / 外部输入未校验」、§10「安全性」、§5「长期持有 / 无拒绝路径」
- **证据**：静态确定（默认根 + 无路径校验）／待确认（前缀穿越能否到达，取决于 stdx 对请求目标的规范化）：
  - 默认根是**工作目录**：`MVC_STATIC_RESOURCE_ROOT` 未配置时 `canonicalize(getWorkingDirectory())`（`MVCConfig.cj:283-290`）⇒ `GET /cjpm.toml`、`GET /boot.sh`、`GET /*.db` 这类"进程目录下的任意文件"都能被 404 兜底直接返回，且这条路径**不经过 `RequestMeta.checkAuth`**（handler 只做 `loadStaticResource` → 404）；README 只在 `42-43` 给了 `export mvc_staticResourceRoot=/path/to/static` 的示例，没有写"不配置时回退到工作目录"，使用者无法从文档预期这个默认值；
  - 路径未做任何 `..`/绝对路径校验：`STATIC_RESOURCE_ROOT.join(p)` 走 std 的 `Path.join`，实现只做字符串拼接、**不归一化 `..`**（`cangjie_runtime/stdlib/libs/std/fs/path.cj:220-240`，只在 `isAbsolutePath` 时抛）；而 `URL.path` 是**解码后**的路径（`cangjie_stdx/doc/libs_stdx/encoding/url/url_package_api/url_package_classes.md:595-603` 的 `prop path`：「获取解码后的路径」）⇒ `%2e%2e%2f` 会变成真实的 `../`。是否真能穿越只剩"stdx 服务端是否拒绝含 dot-segment 的请求行"这一个未知量，因此整体记待确认，但一旦成立即为任意文件读；
  - 读取异常未捕获：`exists(p) && let fi <- FileInfo(p)` 与 `File(p, Read)` 之间是 TOCTOU；`File.readFrom` 抛的 `FSException` / 权限错误会穿过 `loadStaticResource`（`try(file = File(p, Read))` 是**资源式 try**，不是 catch），`StaticResourceOrNotFoundHandler` 只有 `finally` ⇒ 404 路径变成 500。
- **描述**：一个"静态资源兜底"把攻击面从"配置了根目录的静态文件"放大到"整个工作目录（叠加穿越则是整个文件系统）"，且绕过鉴权。`RequestMeta.cj:691-692` 的注释只讨论了"不按路径缓存"的成本，没有讨论根目录与校验。
- **建议**：①`mvcStaticResourceRoot` 未配置时**不要**回退到工作目录（改为关闭静态资源、返回 404）；②`join` 之后 `canonicalize` 并断言结果仍以根目录为前缀（`p.startsWith(root)` 用规范化路径比较），拒绝 `..` 段与符号链接逃逸（现在 `SymbolicLink.readFrom(p, recursive: true)` 也直接跟随到根外）；③`File`/`readFrom` 包 `try/catch (e: Exception)`，失败降级 404 并记 debug 日志；④只允许白名单扩展名（见 `RequestMeta.cj:701-710` 已有的表，反过来当白名单用）。

### [一般][存量] #4 `params` 条件的求值逻辑写错：表单体里的参数永远匹配不到，无 query 的请求恒判 501

- **位置**：`f_mvc/src/RequestCondition.cj:22-29`（`check(form: Form, url: URL)`），调用点 `f_mvc/src/RequestMeta.cj:195`（`this.params.check(request.form, request.url)`）
- **来源**：存量（`git blame`：`RequestCondition.cj:18-29` 落在 `f55a882bb8 2026-07-25`）
- **判据**：review-checklist §11「逻辑错误 / 边界」，§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 表达式展开为 `check(form) && (if (url.rawQuery.isSome()) { !refEq(form, urlForm) && check(urlForm) } else { false })`：
  - **无 query string** 时右半恒 `false`，`check(form)` 真也白搭 ⇒ 例如 `POST /x`（body 是 `a=1`）+ `params: "a"`：`check(form)` 命中，但 `rawQuery` 为 `None` ⇒ 条件判假 ⇒ `MultiRequestMethodHandler.cj:68-70` 把它当 `NOT_IMPLEMENTED`（501）；
  - **form 与 `url.queryForm` 是同一实例**时 `!refEq` 为假 ⇒ 整体为假；但此路径上 `check(form)` 已经为真，正确结果应是 `true`（`refEq` 只是"避免重复检查"，不该反转结果）。
  - 同语义的正确写法就在隔壁：`f_mvc/src/ControllerFuncParam.cj:45-67`（`AbstractRequestParam.extractValue`）先查 `form`、命中就返回，未命中才去看 `url.queryForm`，且 `!refEq` 只用于跳过重复读取——这套逻辑与 `RequestCondition` 是同一需求的两份实现，已经漂移。
- **描述**：`RequestCondition` 只在 `params`/`headers` 注解属性非空时生效（`RequestMeta.cj:548-551`）。对以请求体表单传参的 POST/PUT，`params` 条件等于不可用；对没有 query 的 GET，`params` 条件会让请求落到 501 而不是 404/405，误导排查。注释（`MVC-C2` 等）没有提到这一语义。
- **建议**：改成"form 命中即通过，否则再看 query form"：
  `check(form) || (if (let Some(_) <- url.rawQuery) { check(url.queryForm) } else { false })`；若担心重复检查，用 `!refEq(form, url.queryForm) && check(url.queryForm)` 作为**追加**条件而不是替换。抽一条公共 `Form` 查询工具（`f_util` 或包内 util）给 `RequestCondition` 与 `AbstractRequestParam` 共用，附等价性用例（GET 带 query / POST 带 body / 两者都有 / 都没有）。

### [一般][存量] #5 GET/DELETE 的默认 `consumes=''` 让"带 Content-Type 的请求"一律 415

- **位置**：`f_mvc/src/RequestMeta.cj:487-492`（`addConsumes` → `addMediaTypes(..., allowEmpty: true)` → 写入 `''` 这个键）、`f_mvc/src/RequestMeta.cj:463-483`（`case '' where !allowEmpty => throw` 之后落到 `case x => set.add(x)`，即 `''` 被当合法 consumes）；默认值 `f_mvc/src/RequestMapping.cj:52`（`GetMapping.consumes = ''`）、`f_mvc/src/RequestMapping.cj:84`（`DeleteMapping.consumes = ''`），对照 `RequestMapping.cj:36,68,100`（POST/PUT/PATCH 默认 `application/json`）；消费者 `f_mvc/src/MultiRequestMethodHandler.cj:74-93`
- **来源**：存量（`git blame`：`RequestMapping.cj` 全部落在 `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符 / 边界」，§2「字面量复制（默认值不一致）」
- **证据**：静态确定 —— 注册时 `meta.iterateConsumes` 只把 `''` 写进 `HashMap<RequestMethod, HashMap<String, RequestMeta>>`（`MultiRequestMethodHandler.cj:45-56`）；请求侧 `c = Content-Type 去掉 ';' 之前的部分`（`74-80`），`metas.get(c)` miss、`metas.get('*')` 只对 WS 成立（`83-89`）⇒ `UNSUPPORTED_MEDIA_TYPE`。于是 `@GetMapping('/x')`（默认 consumes=''）收到 `GET /x` + `Content-Type: application/json`（部分客户端/网关会给 GET 也带）直接 415，而同一路径的 `POST` 声明 `application/json` 反而正常。
- **描述**：同一个注解族里 GET/DELETE 与 POST/PUT/PATCH 的默认 `consumes` 不一致，且 `''` 被当成"只接受没有 Content-Type 的请求"而不是"接受任意 Content-Type"。语义上 GET 声明 consumes 本就少见，默认值应表达"不限制"。
- **建议**：把 GET/DELETE 的默认值改成 `'*'` 或 `''` 表示"不限"并在 `MultiRequestMethodHandler` 里对 `''` 键做兜底（`metas.get(c)` miss 后再 `metas.get('')`），而不是直接把 `''` 当精确键；或统一 5 个注解的默认值，并在 README 用表格写清 `consumes` 的匹配规则。补用例：`GET` 带 `Content-Type: application/json` 命中默认 consumes 的映射。

### [一般][存量] #6 `RequestMeta.isMultipart(name)` 恒为 `false`，且未知参数名会抛 `NoneValueException`

- **位置**：`f_mvc/src/RequestMeta.cj:424-426`；配套 `f_mvc/src/RequestArgMeta.cj:35-37`（`operator [](name)` 返回 `args[name][0]`，类型 `ControllerFuncParam`）、`f_http/src/MultipartFormData.cj:24`（`public class MultipartFormData`，父类型只有 `Object`）
- **来源**：存量（`git blame`：`f55a882bb8 2026-07-25`）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」、§14.1（公开 API 实际不可用）
- **证据**：静态确定 —— `args[name]` 的静态类型是注解对象 `ControllerFuncParam`（`RequestArgMeta.cj:19,35-37`）；`is` 的判定是"运行时类型是目标类型的子类型"（`cangjie_docs/docs/dev-guide/source_zh_cn/class_and_interface/typecast.md`「`is` 和 `as` 操作符」），`MultipartFormData` 是 f_http 的**请求体数据类**、与 `ControllerFuncParam` 无继承关系 ⇒ 该表达式恒 `false`。全仓 `grep MultipartFormData` 只有 `RequestMeta.cj:425` 一处真实引用（另两处是异常文案），f_mvc 里也没有名为 `MultipartFormData` 的注解类。未知 `name` 走 `HashMap[]`，键不存在抛 `NoneValueException`（`cangjie_runtime/stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:6162`）。
- **描述**：这行像是旧设计（把 `@MultipartFormData` 当参数注解）的残留：现在判断对象错了，方法对任何已声明参数都返回 `false`，对未声明参数直接抛异常。公开方法挂在 public `RequestMeta` 上，使用者无法从签名看出它永远为假。
- **建议**：改名并改判据——如果语义是"该参数是否用 multipart 注解声明"，就 `args.contains(name) && args[name] is RequestBody`（或对应的新注解）并对未知 key 返回 `false`；如果语义是"当前请求是否 multipart"，就读 `Content-Type` 前缀 `multipart/`。两种都应对未知 `name` 返回 `false`，不要抛异常。

### [一般][存量] #7 `populateResponseContentType` 把客户端 `Accept` 原文写成响应 `Content-Type`

- **位置**：`f_mvc/src/RequestMeta.cj:144-151`；调用点 `f_mvc/src/RequestMeta.cj:398`（`InputStream`）、`408`（`Array<Byte>`）、`414`（`String`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「语义与命名不符」、§10「正确性」
- **证据**：静态确定 —— `header('Content-Type', accept)` 直接使用 `ctx.request.headers.getFirst('Accept')` 的整串，缺省填 `'*/*'`。`Accept` 与 `Content-Type` 不是同一个语义维度，且取值允许 `a/b, c/d;q=0.8`、`*/*`、`application/*`。同文件里对多值 `Accept` 的处理（`checkProduces:172-190`、`respond<JsonValue>:372-388`）都用 `AcceptQueue` 选首值，只有这三个分支没做。
- **描述**：控制器返回 `Array<Byte>` / `InputStream` / `String` 时（例如导出文件、纯文本），响应头可能是 `Content-Type: application/json, text/plain;q=0.8` 或 `Content-Type: */*`，前者不是合法的媒体类型，后者让客户端自行嗅探；两者都可能被严格客户端（或反向代理）拒绝/改写。f_http 层若严格校验头值还会直接 500。
- **建议**：这三个分支应显式声明内容类型（`Array<Byte>`/`InputStream` 默认 `application/octet-stream`，`String` 默认 `text/plain; charset=utf-8`），或从 `Accept` 里经 `AcceptQueue` 取一个 `MediaTypes.tryParse` 成功的类型，失败时回落到默认值；不要回写 `*/*`。同族问题见「范围外提示」。

### [一般][存量] #8 鉴权失败响应是 `ToData` 时，`Accept: */*`（curl 默认）会把结构化错误体丢成一行 reasonPhrase

- **位置**：`f_mvc/src/RequestMeta.cj:290-295`（`case x: ToData where firstAccept != '*/*'` → `case _ => respondStatusReasonPhrase()`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符 / 边界」
- **证据**：静态确定 —— `AuthHandler` 允许返回任意 `Any`（`AuthHandler.cj:18-28` 的注释明确"Any 类型实际只能处理 String/ToString/InputStream/Array<Byte>/ToData"），而 `RequestMeta.checkAuth` 对 `ToData` 加了 `firstAccept != '*/*'` 的守卫；`Accept: */*` 或缺 `Accept`（`?? '*/*'`，`RequestMeta.cj:268`）时直接落到 `_` 分支，只写状态码 reasonPhrase。
- **描述**：鉴权失败/无权限时，客户端拿到的 JSON 错误结构（业务错误码、提示文案）在最常见的 `Accept: */*` 下消失，只剩 `Forbidden` 之类的纯文本；而同一个 handler 返回 `String`/`ToString` 时又能正常输出。同一个响应构造器对返回类型不一致。
- **建议**：把守卫改成"`*/*` 时按 `produces` 里第一个 `MediaType` 渲染"（`respond<R>` 的 `genBody` 已有这段逻辑，`RequestMeta.cj:333-339`），或直接复用 `respond<R>(status, x, ctx)` 统一渲染与关闭语义。

### [一般][存量] #9 静态资源缓存：整文件常驻无上限，且 `File.readFrom` 在 `entryView` 的原子区内做磁盘 I/O

- **位置**：`f_mvc/src/RequestMeta.cj:46`（`ConcurrentHashMap<String, (DateTime, Array<Byte>)>`）、`f_mvc/src/RequestMeta.cj:108-136`（`entryView` 内 `File.readFrom(p)`，键来自请求路径）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §5「无界缓存 / 缓存键无界 / 长期持有」、§12.2「临界区内做 I/O」、§6.2「锁内 I/O」（性能面见「待验证假设」）
- **证据**：静态确定（结构）+ 文档核对：`entryView` 的回调"具有原子性"，且文档明确"回调中不能并发调用 `entryView`/`remove`/`replace`"（`cangjie_runtime/stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1219-1247`）⇒ 回调体（含 `File.readFrom` 与整文件 `Array<Byte>` 分配）在容器的原子区内执行。缓存没有容量、单条大小、条目数、TTL 或淘汰；删除文件后条目也不会失效（只按 `lastModificationTime` 变新才替换）。
- **描述**：两条后果独立存在：①内存——某个 200 MB 的静态文件被请求一次后，200 MB 字节常驻到进程结束（`clear()`/删文件都不会归还，`mem §3.2`）；静态目录里放视频/离线包时峰值随"被访问过的文件总大小"增长，属无界增长面；②并发——首次请求（或文件更新后）在原子区内读整文件，同时访问同一映射的请求线程会被这个 I/O 挡在容器锁上，属于"锁内做 I/O"；缓存键是外部可控的路径字符串（见 #3），同一文件用 `/a.css` 与 `a.css` 会各存一份字节，条目上限由"静态根下存在的文件数 × 路径写法变体"决定。
- **建议**：①按 `Content-Length`/文件大小设上限（超限走 `InputStream` 流式写，不进缓存）；②给缓存加条目数 + 总字节上限（LRU 或直接"只缓存 < N KB 的小文件"）；③把读取挪到 `entryView` 之外：先 `get`（得到 `?值`），miss 时读文件，再 `addIfAbsent` 发布，读失败删条目；④文件不存在/被删时删除条目。

### [一般][存量] #10 `WSCloseFrame(payload)` 不做长度校验：合法的空 Close 帧会抛 `IndexOutOfBoundsException`

- **位置**：`f_mvc/src/WSCloseFrame.cj:105-111`（`status = UInt16(payload[0]) << 8 | UInt16(payload[1])`、`reason = String.fromUtf8(payload[2..payload.size])`）；上游构造点 `f_mvc/src/macros/WSEndPoint.cj:83`（`WSCloseFrame(payload)`）、`f_mvc/src/WSMeta.cj:293-294`（把 `frame.payload` 交给 close 处理器）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「空集合未处理 / 边界差一」
- **证据**：静态确定 —— RFC 6455 §5.5.1 允许 Close 帧不带 body（此时无状态码），`payload.size == 0`；`payload[0]`/`payload[1]` 越界抛 `IndexOutOfBoundsException`（`<: Exception`，`cangjie_runtime/stdlib/libs/std/core/index_out_of_bounds_exception.cj:11`），被 `WSMeta.cj:301-303` 的 `catch (e: Exception)` 接住后记一条 ERROR 日志，用户的 `@OnWSClose` 处理器根本不会执行，服务端也不会回一个 Close 状态码。`payload.size == 1` 同样越界。
- **描述**：任何客户端（含正常浏览器）在无状态码关闭连接时都会走到这条路径；日志里表现为"error on handling close ''"，排查时容易误判为业务处理器异常。`String.fromUtf8` 对非法 UTF-8 的 reason 也会抛（RFC 要求 1007 关闭，但这里是异常）。
- **建议**：`init` 里做长度与编码兜底：`status = if (payload.size >= 2) { ... } else { WS_RESERVED_DISEXISTENCE }`，`reason = if (payload.size > 2) { try String.fromUtf8(...) catch { '' } } else { '' }`；并在 `WSMeta.exec` 的 close 分支对"无 body"单独走一次 `ws.writeCloseFrame()`。

### [一般][存量] #11 `WS_FRAME_TYPE_UNMATCH = 1008`：与自己的注释（1007）和 RFC 6455 都不符，且与 `WS_ANTI_STRATEGY` 撞值

- **位置**：`f_mvc/src/WSCloseFrame.cj:59-73`（`WS_FRAME_TYPE_UNMATCH = 1008` 紧跟 1007 的说明；`WS_ANTI_STRATEGY = 1008` 紧跟 1008 的说明）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」
- **证据**：静态确定 —— 注释写「1007 indicates ... data within a message that was not consistent with the type of the message」（RFC 6455 的 1007 = invalid frame payload data），常量值却是 `1008`（policy violation，下一个常量的语义）。全仓 `grep WS_FRAME_TYPE_UNMATCH` 只有定义处（公开常量，无仓内使用）。
- **描述**：使用者按名字/注释发 `WS_FRAME_TYPE_UNMATCH` 关闭帧时，对端收到的是 1008（策略违规）而不是 1007（数据不一致），排障方向被带偏；两个不同语义的常量值相同，无法区分。
- **建议**：改为 `public const WS_FRAME_TYPE_UNMATCH = 1007`；顺手把常量的注释压成一行语义 + RFC 编号，避免"注释讲 1007、值写 1008"这类复制粘贴。

### [一般][存量] #12 WebSocket 端点参数不收集 `Validator`：`@NotEmpty` 一类校验在 WS 上静默失效

- **位置**：`f_mvc/src/WSMeta.cj:409-421`（`generate` 只把第一个 `ControllerFuncParam` 写进 `args`，其余注解全部丢弃）、`f_mvc/src/WSMeta.cj:36-41`（`extract` 固定传 `DummyValidator.instance`）、`f_mvc/src/RequestArgMeta.cj:38-44`（`operator [](name, value!)` 新建条目时 validator 固定 `DummyValidator.instance`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符」、§3「静默吞掉」
- **证据**：静态确定 —— 对照 HTTP 侧 `RequestMeta.generate`：那里显式识别 `Validator` 与 `AbstractDateTimeConverter` 注解并写进三元组（`RequestMeta.cj:519-530`）；WS 侧 `for (annotation in param.annotations where annotation is ControllerFuncParam) { ... break }` 只看参数注解，`Validator` 注解既不进 `args` 也没日志，提取时 `DummyValidator`（`Validator.validate` 恒真，`ControllerFuncParam.cj:32-40`）。
- **描述**：同一个 DTO/参数在 HTTP 控制器上会触发 `@NotEmpty` 等校验（失败抛 `ValidationException`），搬到 `@OnWSText` 处理器后完全不校验，坏数据直接进业务函数；由于没有日志，只有把 handler 打到脏数据才会发现。转换器（`AbstractDateTimeConverter`）同样被忽略，日期类参数按默认格式解析。
- **建议**：WS 的参数收集复用 HTTP 侧那段三元组收集逻辑（抽 `collectArgMeta(function.parameters)` 给两处用），`WSFuncMeta.extract` 传 `args` 里的真实 validator/converter；若 WS 校验确实不打算支持，就要在 `generate` 里对"带 Validator 注解"的参数报 `WSException`，不要静默丢弃。

### [一般][存量] #13 `RequestMetas` 是一个只写不读的路由注册表：`TreeSet` 永不读取，等值路由被静默丢弃

- **位置**：`f_mvc/src/RequestMetas.cj:19-27`（`mutex` + `TreeSet<RequestMeta>` + `add`）、写入点 `f_mvc/src/RequestMeta.cj:557`、比较函数 `f_mvc/src/RequestMeta.cj:87-103`
- **来源**：存量（`git blame`：`RequestMetas.cj` 落在 `f55a882bb8 2026-07-25`）
- **判据**：review-checklist §1「读了不用（写入后无读者）」、§5「长期持有」、§11「错误处理静默」
- **证据**：静态确定 —— 全仓 `grep RequestMetas` 只有三处：类定义、`public static let instance`、`RequestMetas.instance.add(meta)`；类里没有迭代器/getter/查询方法，`metas` 是 `private let`，外部拿不到。`TreeSet.add` 的返回值被丢弃（`RequestMetas.cj:25`），而 `Set.add` 在元素已存在时返回 `false` 且不添加（`cangjie_runtime/stdlib/doc/libs/std/collection/collection_package_api/collection_package_interface.md:1009-1020`）；`RequestMeta.compare` 只比较 `path + method + consumes`（`RequestMeta.cj:87-103`），`produces` / `params` / `headers` / 实际处理函数都不参与。
- **描述**：①每个注册的 `RequestMeta`（含 `HashSet` ×2、`RequestArgMeta`、闭包）都被这个集合永久持有，而集合内容对运行期没有任何作用——纯内存与启动期 CPU 开销；②如果将来有人把它当作"路由清单/冲突检测"来读，会得到**缺条目**的结果：同 path 同 method 同 consumes、只靠 `params`/`headers` 区分的两个路由（Spring 允许）会被判等，第二个静默丢失，且没有任何日志。真正的冲突检测在 `MultiRequestMethodHandler.register`（`45-56`，`addIfAbsent` + 抛 `MVCException`），两套机制语义还不一致。
- **建议**：二选一——删掉 `RequestMetas`（以及 `RequestMeta.cj:557` 的写入），把"路由清单"职责交给 `MultiRequestMethodHandler`；或补齐用途：提供只读快照查询、`add` 检查返回值并在等值时打 warn/抛异常，同时把 `compare` 的比较键扩到 `produces + params + headers`（或改用 `toString` 的稳定指纹）。

### [一般][存量] #14 多文件下载的后续分片没有 boundary 分隔：客户端只能正确解出第一个文件

- **位置**：`f_mvc/src/ResponseDownload.cj:34-49`（`download<C>(data: C)`：首片 `fd.start`，后续 `fd.next(d[1], '')`）、`f_mvc/src/ResponseDownload.cj:51-65`（`download(data: Array<File>)` 同形）；根因 `f_mvc/src/FileDownload.cj:120-132`（`next` 只写 `Content-Disposition`/`Content-Length`/`Content-Type`，**不写** `--boundary`）、`FileDownload.cj:94-119`（`start` 先写 `--boundary\r\n`）
- **来源**：存量（`git blame`：`ResponseDownload.cj` 落在 `f55a882bb8 2026-07-25`）
- **判据**：review-checklist §11「契约与实现不符」、§2「重复逻辑」的下游后果
- **证据**：静态确定 —— 输出字节序列可逐段写出：`start(f0)` → `"--b\r\n"` + `Content-Disposition: ...\r\n` + f0 字节；`next(f1)` → 直接 `"Content-Disposition: ...\r\n"`（前面既没有 `\r\n--b\r\n`，也没有空行分隔），于是 f1 的头部成了 f0 的 body 内容；`end()` 只补一个 `"\r\n--b\r\n"`（且不是结束边界 `--b--`）。`Content-Type` 声明的是 `multipart/x-mixed-replace; boundary=...`（`FileDownload.cj:97`），解析器会一直找不到第二个边界。
- **描述**：`download([f1, f2])` / `download(iterable)` 只有在传入 1 个文件时正确；多个文件时第二个起全部粘在第一个 body 里（客户端保存出来的文件被污染）。单文件路径不受影响（`start` 内部会调用一次 `next`，见 `FileDownload.cj:114-116`）。根因文件属第 1/2 部分，本部分记录调用形态。
- **建议**：`next` 开头补 `write("\r\n--${boundary}\r\n")`，`end` 改成 `write("\r\n--${boundary}--\r\n")`；`Content-Disposition` 值改成标准形式 `attachment; filename="..."`（当前 `attachment, filename=` 用的是逗号，`FileDownload.cj:140-142`）。补一条用例：两个小文件，按 boundary 切分后断言恰好 2 段且各自字节一致。

### [一般][存量] #15 WebSocket 端点完全不经过 `AuthHandler`，也没有 `@IgnoreAuth` 一类的开关

- **位置**：`f_mvc/src/RequestMeta.cj:298-311`（`setHandle<T>(wsmeta:)` 只 `CurrentHttpContext.set` → `wsmeta.handle(...)` → `finishRequest`，无 `checkAuth`）；注册 `f_mvc/src/HttpRequestDistributorImpl.cj:35-41`；`checkAuth` 唯一调用点在 `f_mvc/src/macros/Controller.cj:89`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10「安全性（鉴权覆盖）」、§14.1「能力未接线」
- **证据**：静态确定 —— `grep checkAuth` 全仓只有 `RequestMeta.cj:248`（定义）与 `macros/Controller.cj:89`（HTTP 控制器宏）。WS 处理链是 `RequestMeta.setHandle(wsmeta:)` → `WSMeta.exec` → `@OnWS*` 处理器，中间没有任何 `AuthHandlerProxy` 调用；`WSMeta`/`@WSEndPoint` 也没有 `ignoreAuth`/`ignorePrivilege` 参数（`WSMeta.cj:191-199` 只有 `subProtocols`/`origins`/`userFunc`）。
- **描述**：HTTP 控制器有统一的"参数提取 → 登录/权限检查 → 业务"价值链（README:113），WS 端点没有：同一个应用里 `GET /api/x` 要登录，`WS /api/x` 不要。握手阶段确实可以用 `userFunc`（`WSMeta.cj:194`）自己校验 Cookie/Token，但那是用户自建逻辑，框架层没有任何钩子/文档提示。安全影响取决于端点暴露的数据，属于"鉴权模型覆盖不全"。
- **建议**：在 `setHandle(wsmeta:)` 的握手阶段（`wsmeta.upgrade` 之前）复用 `AuthHandlerProxy`，把 `RequestMeta.path` 与空 `args` 传给 `AuthParam`，并补 `@WSEndPoint(ignoreAuth: ..., ignorePrivilege: ...)`；若短期不打算做，至少在 README 的 WebSocket 段落写明"WS 端点不参与 `AuthHandler` 检查，需在 `userFunc` 里自行校验"（当前 `README.md:1174-1181` 未提）。

### [一般][存量] #16 访问日志记录表单原文与全部控制器实参，无脱敏/截断开关

- **位置**：`f_mvc/src/RequestMeta.cj:564-593`（`logContent`：`request.form.toEncodeString()` 与 `params`）、`f_mvc/src/RequestMeta.cj:601-634`（`lazyAccessLogFields`/`anyToString` 把 `Form`、`String`、`ToData` 全量 `toString`/`toData`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10「安全性（敏感数据进日志）」
- **证据**：静态确定 —— 日志文本固定包含 `request.form.toEncodeString()`（`572` 行）与按参数顺序拼接的 `${params}`；`anyToString` 对 `String` 直接返回原文、对 `ToData` 转 JSON、对 `Array<Byte>` 做 base64（`604-616`）。宏在 `finally` 里无条件调用 `accessLog`（`macros/Controller.cj:96-98`），INFO 级即输出，没有任何字段名过滤、长度上限或"关闭参数记录"的配置。
- **描述**：登录/改密/支付类接口的表单字段（`password`、`token`、`idCard`）会以明文进访问日志，日志再被采集到 ELK/磁盘；大 body（文件上传走 `MultipartFormData` 不会进这里，但 `@RequestBody` 的 `ToData` 会）还会把整条 JSON 写进一行日志，放大日志量。`MVCConfig` 里没有对应的开关（`MVCConfig.cj` 只有 debugging/accessControl/downloadBufferSize/staticResourceRoot 等）。
- **建议**：增加 `mvc_accessLogParams`（默认 false）与 `mvc_accessLogParamMaxLength`；默认只记参数个数/类型，或对 `password|token|secret|cookie` 一类字段名做 `***` 替换；`ToData` 的序列化改成"记录类型名 + 字节数"，需要排查时再按请求 id 开 debug。

### [轻微][存量] #17 死代码：`RequestMeta.checkHeader` 全仓零调用

- **位置**：`f_mvc/src/RequestMeta.cj:167-170`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1「private 符号全仓无调用者」
- **证据**：静态确定 —— `grep -rn checkHeader --include=*.cj .`（排除 `.worktrees`）只命中定义行；`RequestMeta.check` 用的是 `this.headers.check(request.headers)`（`195`），没有走这个函数。它是 `private`，不影响外部契约。
- **描述**：看起来是早期"按 header 名称单独校验"的残留，逻辑还与 `RequestCondition` 的 `ContainsRequestCondition.check(headers)` 重复。
- **建议**：删除，或若确有"只校验单个 header"的需求就把它接到 `check` 上并补用例。

### [轻微][存量] #18 死代码：`RequestMeta.generate` 建了 `functionParamMap` 却从未使用

- **位置**：`f_mvc/src/RequestMeta.cj:497-500`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1「局部变量赋值后未被读取」
- **证据**：静态确定 —— `functionParamMap` 只在 `498-500` 被填充，`493-563` 内再没有读取；`grep functionParamMap` 全仓只此一处。
- **描述**：每个控制器方法注册时多分配一个 `HashMap` 并做 N 次插入（N = 参数个数），启动期浪费；也让读者误以为后面会按名字查参数。
- **建议**：删除这 4 行（或改为真正需要的"按名索引"，但当前 `args` 已经承担该职责）。

### [轻微][存量] #19 静态资源 MIME 表里 `'ico'` 重复，`text/xml` / `application/xml` 口径也不一致

- **位置**：`f_mvc/src/RequestMeta.cj:701-710`（`706` 行 `case 'jpg' | ... | 'avif' | 'ico' =>`，`'ico'` 在同一模式里出现两次）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1「恒真/不可达模式」、§2「字面量复制」
- **证据**：静态确定 —— 同一个 `case` 的可选模式列表里 `'ico'` 出现两次，后一个分支不可达（若编译器不去重则是编译期告警源）；`'xml'` 被映射到 `text/xml`，`'svg'` 单独映射到 `image/svg+xml`，与常见的 `application/xml` 口径不一致。
- **描述**：无功能后果（`ico` 仍得到 `image/ico`，虽规范写法是 `image/x-icon`），但属于复制粘贴残留；`text/xml` 已废弃。
- **建议**：去重 `'ico'` 并改成 `image/x-icon`；`xml` 用 `application/xml`；把这张表提成 `static let` 的 `HashMap`（现在每次静态资源请求都要过一遍 10 分支的 `match`）。

### [轻微][存量] #20 WS 帧状态机两处不完整：未知帧类型不 `return true`，孤儿 `Continuation` 被静默忽略

- **位置**：`f_mvc/src/WSMeta.cj:306-309`（`case _ => log.error; ws.closeConn()`，没有 `return true`）、`f_mvc/src/WSMeta.cj:278-279`（`ContinuationWebFrame` 直接用当前 `frameType.value`；为 `None` 时 `doExec` 里 `if (let Some(ft) <- frameType)` 整段跳过、原样返回 `bytes`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「控制流 / 协议语义」
- **证据**：静态确定 —— 未知帧分支关连接后循环继续 `readFrame()`（`WSMeta.cj:101-106`），必然在已关闭连接上再读一次并抛异常（多一条链式错误日志）；`Continuation` 在首帧丢失时既不当协议错误也不 `closeConn`，直接静默丢弃整条消息。
- **描述**：两处都让"已经决定结束会话"的路径多跑一轮或静默吞消息，排障时会看到"close 之后又一条 exception"与"客户端发的分片消息消失"。
- **建议**：未知帧分支改为 `ws.closeConn(); return true`（与 `291-305` 的 Close 分支对齐）；`Continuation` 且 `frameType.value.isNone()` 时按 `WS_PROTOCOL_ERROR` 关闭并返回 `true`。

### [轻微][存量] #21 同一套"按参数类型分派"在 `RequestMeta.extract` 与 `@WSEndPoint` 宏里各写一遍

- **位置**：`f_mvc/src/RequestMeta.cj:428-456`（`case _: ?HttpContext` / `?HttpRequest` / `?HttpHeaders` / `?HttpResponseBuilder` / `?Array<Byte>` / `?Form`）、`f_mvc/src/macros/WSEndPoint.cj:77-85`（同一串 `case _: ?HttpContext` … 外加 `?WebSocket` / `WSCloseFrame`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「跨层复制 / 只改类型名」
- **证据**：静态确定 —— 两处输入（参数声明类型 + 上下文对象）、输出（实参值）、副作用（缺参抛异常）相同，差异只有 WS 多两个类型、`HttpResponseBuilder` 只在 HTTP 侧。宏版把 `(x as T).getOrThrow()` 展开到用户类里，`RequestMeta` 版用 `match`，本质是一个分派表。
- **描述**：两份分派表已经漂移（`Form` 分支只有 HTTP 侧有；WS 侧多 `WebSocket`/`WSCloseFrame`）。新增一种"可注入类型"（例如 `HttpSession`）时要改两处宏/运行期代码，漏一处就是"某个类型在 WS 上永远注入不进来"。
- **建议**：抽成包内 `func extractByParamType<T>(ctx, ws: ?WebSocket, payload: ?Array<Byte>, ...): ?T`，宏只负责生成 `let x = extractByParamType<T>(...)`；或至少把类型清单提成一处常量文档并加交叉引用注释。

### [轻微][存量] #22 `Accept` 首值/多值解析在 4 处各写一遍，默认值还不一致（`application/json` vs `*/*`）

- **位置**：`f_mvc/src/RequestMeta.cj:268-273`（`checkAuth`：`AcceptQueue(accept).first() ?? 'application/json'`）、`f_mvc/src/RequestMeta.cj:342-346`（`respond<R>`：`?? '*/*'`）、`f_mvc/src/RequestMeta.cj:372-377`（`respond(JsonValue)`：`?? 'application/json'`）；同族 `f_mvc/src/MultiRequestMethodHandler.cj:164-180`（`HttpStatusOnlyHandler`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「字面量复制 + 近似重复」
- **证据**：静态确定 —— 四段的判定骨架完全相同（`Accept` 含 `','` → `AcceptQueue` 取首 → 缺省某个值），差异只在缺省值与后续渲染分支；`checkAuth` 与 `respond(JsonValue)` 缺省 `application/json`，`respond<R>` 缺省 `*/*`，`HttpStatusOnlyHandler` 又自己判 `*/*` 与逗号。
- **描述**：不同响应路径对"没有可用 Accept"的解释不一致，同一个客户端在 200 / 401 / 406 上拿到不同 Content-Type；改一处默认值无法整体生效，是 #8 这类不一致的温床。
- **建议**：抽 `func firstAccept(headers: HttpHeaders, fallback: String = 'application/json'): String` + `func acceptMatches(accept: String, produces: HashSet<String>): ?String`，四处统一调用；缺省值只在一处定义。

### [轻微][存量] #23 `RequestMethod.tryParse("WS")` 让 HTTP 请求行里的 `WS` 方法直达 WS 路由，绕过 Upgrade 判定

- **位置**：`f_mvc/src/RequestMethod.cj:79-91`（`case "WS" => WS`）；路由侧 `f_mvc/src/MultiRequestMethodHandler.cj:100-106`（只有 `GET + Upgrade` 被特判到 `WS` 键）、`106-127`（`metas.get(method)` 对所有方法生效）
- **来源**：存量（`git blame`：`RequestMethod.cj` 落在 `f55a882bb8 2026-07-25`）
- **判据**：review-checklist §11「契约与实现不符」、§10「外部输入未校验」
- **证据**：静态确定 —— `RequestMethod.WS` 是 `Hashable/Parsable` 的正式枚举值（`RequestMethod.cj:23-31,88`），`MultiRequestMethodHandler.handle` 用 `RequestMethod.parse(request.method)`（`64`），所以 `WS /ws/echo HTTP/1.1` 会命中 `metas.get(WS)` 并调用 `setHandle(wsmeta:)` → `wsmeta.handle` → `meta.upgrade(ctx)`（`macros/WSEndPoint.cj:145-148`），在非握手请求上走 `WebSocket.upgradeFromServer`。
- **描述**：`WebSocketRouting_test` 只断言了"普通 GET 是 405"，没有覆盖 `WS` 方法；这条路径不会造成越权，但会把非法请求送进握手代码（stdx 抛异常 → 500/连接断开），也让"WS 键只由 Upgrade 触发"的注释（`MultiRequestMethodHandler.cj:98-99`）不成立。
- **建议**：`tryParse` 不暴露 `WS`（或单独 `parseWs` 给注册侧用），路由侧只从 `GET + Upgrade` 进入 WS 分支；若必须保留，就在 `metas.get(WS)` 分支前再判一次 `isWebSocketUpgrade(headers)`。

### [轻微][存量] #24 `WSDataFrame` 的 HTTP 提取路径抛**无消息**的 `MVCException`

- **位置**：`f_mvc/src/WSDataFrame.cj:18-24`（`protected func extract<T>(_: String, ...): ?T { throw MVCException() }`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3「占位实现 / 错误信息缺失」
- **证据**：静态确定 —— 该重载是 `ControllerFuncParam` 抽象成员的实现（`ControllerFuncParam.cj:20-21`），参数名用 `_` 丢弃，函数体只抛空消息异常；`MVCException()` 的 `message` 为空（`exception/MVCException.cj:19`）。
- **描述**：把 `@WSTextFrame`/`@WSBinaryFrame` 误用到 HTTP 控制器参数时，日志里只有 `MVCException` 类型、没有"该注解只能用于 WebSocket 处理器"的提示，排查成本高。
- **建议**：`throw MVCException('@WSTextFrame/@WSBinaryFrame can only be used on @WSEndPoint handler parameters')`；同时把参数名保留下来用于消息。

### [轻微][存量] #25 `download(data: Array<File>)` 传空数组时既不 `start` 也不设 `Content-Type`

- **位置**：`f_mvc/src/ResponseDownload.cj:51-65`（`for (i in 0..data.size)` 为空时只执行 `fd.end()`）
- **来源**：存量（`git blame`：`f55a882bb8 2026-07-25`）
- **判据**：review-checklist §11「空集合未处理」
- **证据**：静态确定 —— `FileDownload.start` 是唯一 `responseBuilder.header(...)+build()+body(pipe)` 的地方（`FileDownload.cj:94-113`），空数组时不会调用；`end()` 只往 `pipe` 写字节（`134-139`）。响应因此没有 body、没有 `Content-Type`，客户端拿到一个空 200。
- **描述**：调用方按"下载一批文件"的语义传空列表（例如查询结果为空）时，得不到 204/404 或明确错误，也看不出"没有文件"。
- **建议**：空数组时 `throw HttpResponseException('no file to download')` 或 `fd.noContent()`（`FileDownload.cj:43-46` 已有 204 实现）。

### [轻微][存量] #26 两个端到端测试用固定端口 + 就绪探测失败后静默返回 + 依赖进程级全局注册表

- **位置**：`f_mvc/src/WebSocketRouting_test.cj:40-70`（`PORT: UInt16 = 18099`、`for (_ in 0..50) { try ... return server } catch { sleep }` 之后 `server`）、`f_mvc/src/WSEndPointMacro_test.cj:48-71`（`PORT = 18100`，同形）；全局副作用 `WebSocketRouting_test.cj:45,51`（`MVCStarter.generateAndRegisterWSEndPoint` + `BeanFactory.instance.register`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「错误处理静默」、§12.1「有界性/全局状态」
- **证据**：静态确定 —— 端口是编译期常量，端口被占或 5 秒内未就绪时函数**仍然返回** `server`，后续 `connect` 抛的异常与"端口占用"无关；`generateAndRegisterWSEndPoint` 向单例 `HttpRequestDistributorImpl` 注册路由、`BeanFactory.register` 向全局注册表加 bean，测试重复执行（重试/同进程多次）时会二次注册。
- **描述**：CI 并行、本机已有服务占用 18099/18100 时，用例失败信息指向"握手不是 101"，而不是"端口没起来"；`spawn { server.serve() }` 的异常也没被观察（Future 丢弃），服务起不来时只有探测循环在空转。
- **建议**：端口用 0 让系统分配（`ServerBuilder.port(0)` 后读实际端口，若 API 不支持则用随机高位端口 + 占用重试）；就绪循环失败时 `throw` 明确异常；注册/bean 用 try/finally 清理或在用例里做一次性幂等（`addIfAbsent`）。

### [轻微][存量] #27 `ignoreAuth && ignorePrivilege` 的"双标记直接放行"判定在两处重复

- **位置**：`f_mvc/src/RequestMeta.cj:249-251`（`if (ignoreAuth && ignorePrivilege) { return true }`）、`f_mvc/src/AuthHandler.cj:121-122`（同一个判定，第 4 部分文件）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「同语义实现两处」
- **证据**：静态确定 —— 两处条件字面量与结果（`true`/`OK`）一致；`RequestMeta` 的短路让 Proxy 的那段在正常调用链上不可达（只有直接调用 `AuthHandlerProxy.instance.check` 的代码才会用到），属"同一策略两个事实来源"。
- **描述**：单独看无害，但它与 #1 是同一个决策点的两个副本：将来调整"哪些标记可以组合放行"时必须同时改两处，漏一处就是"HTTP 路径放行、其它调用方不放行"。
- **建议**：只保留 `RequestMeta.checkAuth` 的短路（它拥有 `ignoreAuth_`/`ignorePrivilege_` 的唯一来源），Proxy 只按单标记执行；或在 `AuthParam` 上提供 `prop bothIgnored` 让两处共用同一判据。

## 优化可行性方案

> 本部分没有 `cjprof` / `cjpm bench` 基线，以下三条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [堆内存] 静态资源缓存改为"小文件缓存 + 大文件流式"

- **现状**：`RequestMeta.cj:46` 的 `ConcurrentHashMap<String, (DateTime, Array<Byte>)>` 对每个被访问过的文件持有完整字节数组（`108-136`），生命周期 = 进程生命周期；条目数 = 被访问过的**存在文件**数，字节数 = 这些文件大小之和，没有任何上限/淘汰（见 #9）。
- **方案**：按文件大小分流——`< threshold`（例如 256 KB，可配置）走现有缓存，`>= threshold` 每次构造 `File` 流式写入 `responseBuilder.body(InputStream)`；缓存侧加"总字节上限 + LRU"或"条目数上限 + 定期清理"；文件删除/替换时删条目。
- **预期**：常驻堆内存从"Σ 被访问文件大小"降到"Σ 小文件大小（≤ 上限）"；对含大静态资源的部署，峰值 RSS 下降幅度等于大文件大小（**未测**）。
- **代价**：大文件每次请求都要读盘（无缓存），吞吐取决于磁盘；需要新增配置项与淘汰逻辑；`Content-Length` 对缓存命中可以直接给出，流式分支仍需 `chunked`。
- **验证**：准备 1 KB / 1 MB / 100 MB 三个文件，各请求 10 次，记录 `getAllocatedHeapSize()`、RSS 与 `loadStaticResource` 命中计数；确认大文件请求后 RSS 回落、小文件走缓存。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] WebSocket 消息聚合用可复用缓冲，避免每帧 `ArrayList` 扩容与 `unsafeData` 二次物化

- **现状**：`WSMeta.cj:219`（`Box<ArrayList<Byte>>`）、`221-245`（`bytes.add(all: payload)` 逐帧追加、`bytes.unsafeData()` 交给处理器）、`277-279`（每帧都 `bytes.value = doExec(...)`）。单条消息的字节峰值 ≈ `ArrayList` 容量（容量按倍增，通常 1.5–2× 实际长度）+ `unsafeData()` 若返回副本则再一份（是否复制取决于 SDK 的 `unsafeData` 语义，本部分无法从源码确认）。
- **方案**：按首帧的 `frame.payload.size` 预估并 `ArrayList<Byte>(capacity:)` 预分配；`fin` 到达后直接用该缓冲构造一次 `Array<Byte>`（或给处理器传 `ArraySlice`/`ByteBuffer`），避免 `unsafeData` 的第二次物化；消息处理完把缓冲清空复用（`clear()` + 保留容量）。
- **预期**：单条消息的分配次数从"每帧一次扩容 + 一次物化"降到"一次预分配 + 一次输出"；大消息（MB 级）的峰值内存下降接近一半（**未测**）。
- **代价**：需要确认 `unsafeData()` 的确切语义（若已返回内部数组则第二条收益消失）；缓冲复用要保证不跨消息泄漏内容（`clear()` 只清元素不还容量，正是想要的）。
- **验证**：`cjpm bench` / 压测发 1 MB 文本帧 × 1e4，采 `getAllocatedHeapSize()` 增量与 GC 次数；同时断言消息内容逐字节一致（含分片场景）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `copy(input, write)` 每个缓冲块做一次切片复制

- **现状**：`ResponseDownload.cj:71-76` 每次 `read` 后 `write(buf[0..bytes])`；Cangjie 的 `Array` 切片返回新数组（复制），所以每个 `downloadBufferSize`（默认 4096 B）块都多一次分配 + 一次 memcpy。调用方是 `download<C>` / `download(Array<File>)` 两条下载循环（`34-65`）。
- **方案**：把 `copy` 的回调签名改成 `(Array<Byte>, Int64) -> Unit`（传原始缓冲 + 有效长度），由 `FileDownload.write(bytes, offset, length)` 直接写有效区间；若 `OutputStream` 没有偏移写重载，就用 `ByteBuffer` 承接并在最后 `writeTo`。
- **预期**：每块少一次 4 KB 分配与复制；对 1 GB 下载约少 25 万次分配（**未测**，收益取决于 `FileDownload.pipe.write` 是否也复制）。
- **代价**：回调签名变更（包内 `func copy` 非 public，影响面仅本文件两处调用与一处测试）；`Pipe` 侧若本来就复制，端到端收益会明显低于分配计数。
- **验证**：`cjpm bench -O2` 对比 1 GB 虚拟流下载的墙钟时间与 `getAllocatedHeapSize()`；`cjprof` 看 `copy` 与 `Array.slice` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求多次解析 `Accept`（`checkProduces` + `respond` 各 1–2 次 `AcceptQueue`，`AcceptQueue.remove()` 每次重排）占请求处理 CPU 的可观比例 | `f_mvc/src/RequestMeta.cj:171-191,268-273,342-346,372-377` | `AcceptQueue` 构造/`remove` 的自耗时占比、每请求调用次数 | `cjprof record` 跑 10k 个带 `Accept: a/b, c/d;q=0.8` 的请求，看 `AcceptQueue.*` 自耗时是否 >5%；同时加计数确认每请求次数 |
| 2 | 静态资源整文件常驻让 RSS 不随请求结束回落（#9 的内存面） | `f_mvc/src/RequestMeta.cj:46,108-136` | 请求前后 `getUsedHeapSize()` / RSS 差值、缓存条目数与总字节 | 分别对 1 MB / 100 MB 文件各请求 1 次，记录 `getAllocatedHeapSize()`、RSS、`staticResourceBytes.size`；再跑 1000 次小文件请求看是否线性增长 |
| 3 | WS 单条大消息的 `ArrayList` 扩容 + `unsafeData()` 物化是消息处理的主要分配来源 | `f_mvc/src/WSMeta.cj:219-245,277-279` | 每帧分配字节数、`unsafeData()` 是否复制、GC 次数 | 用 1 MB 文本帧压测 1e4 条，`cjprof heap` 看 `ArrayList`/`Array<Byte>` 分配量与 GC 次数；对照预分配版本 |
| 4 | `FileDownload` 写入管道时还会二次复制，导致 `copy` 的切片复制在端到端上不可见 | `f_mvc/src/ResponseDownload.cj:71-76` + `f_mvc/src/FileDownload.cj:142-146`（`pipe.write`） | `SyncByteBuffer.write` 的单次拷贝字节数与自耗时 | 对 1 GB 下载做 `cjprof`，比较 `copy` / `Array.slice` / `SyncByteBuffer.write` 三者自耗时占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/RequestCondition.cj` | .cj | ✅ | 见 #4（`check(form,url)` 恒假分支）、#17（`checkHeader` 是另一文件的死代码，此处仅对照）；`compile(Expr)` 的递归深度由注解字符串决定（开发者可控，见 §4 自检）；`EqualRequestCondition` 用 `y.name` 作字面量、`SubsetOf`/`ValueContains` 的集合语义正确 |
| 2 | `f_mvc/src/RequestMapping.cj` | .cj | ✅ | 见 #5（GET/DELETE 默认 `consumes=''` 与 POST/PUT/PATCH 不一致）、#1（`ignoreAuth`/`ignorePrivilege` 是注解属性且与方法级注解 OR）；5 个注解子类只是转发构造参数，无重复逻辑问题 |
| 3 | `f_mvc/src/RequestMeta.cj` | .cj | ✅ | 见 #1、#3、#4、#5、#6、#7、#8、#9、#13、#16、#17、#18、#19；另核对了 `extract` 的 `as T` + `getOrThrow`（语言文档：`as` 返回 `Option`，`T` 是 `Option<T>` 的子类型，模式成立）、`respond<R>` 的 4 个分支、`setHandle` 的 `Box` 惰性缓存（无同步但只影响重复 `getBean`，未单列） |
| 4 | `f_mvc/src/RequestMeta_test.cj` | .cj | ✅ | 6+3 条用例只覆盖包内接缝（`respondKind`/`closeResultIfResource`/`lazyAccessLogFields`/`finishRequest`），未覆盖 `checkAuth`、`isMultipart`、`generate`、静态资源；`CountingResource.isClosed()` 恒 `false` 与 `close()` 不一致（测试替身精度问题，不计缺陷） |
| 5 | `f_mvc/src/RequestMetas.cj` | .cj | ✅ | 见 #13（只写不读 + `add` 返回值丢弃 + 比较键过窄） |
| 6 | `f_mvc/src/RequestMethod.cj` | .cj | ✅ | 见 #23（`tryParse("WS")`）；`hashCode` 常量表与 `==` 的 `(WS,WS)` 分支已由测试钉住，`compare` 走 `hashCode` 与 `==` 自洽 |
| 7 | `f_mvc/src/RequestMethod_test.cj` | .cj | ✅ | 4 条用例（哈希互异/声明序/WS 自反/哈希容器键）与实现一致；无边界问题 |
| 8 | `f_mvc/src/ResponseDownload.cj` | .cj | ✅ | 见 #14（多文件缺 boundary）、#25（空数组）；`copy` 只写实读长度（`MVC-4` 修复已生效），优化方案 3 |
| 9 | `f_mvc/src/Series.cj` | .cj | ✅ | 5 个常量 + `static init` 填表，`resolve`/`valueOf` 逻辑正确；`values`/`valueOf`/`resolve` 仓内零引用但都是 `public struct` 的对外 API，按硬原则一不判死代码 |
| 10 | `f_mvc/src/WSCloseFrame.cj` | .cj | ✅ | 见 #10（空 payload 越界）、#11（`WS_FRAME_TYPE_UNMATCH=1008`）；其余常量值与 RFC 6455 一致（1000–1006/1009/1010/1011/1015） |
| 11 | `f_mvc/src/WSDataFrame.cj` | .cj | ✅ | 见 #24（无消息异常）；`WSTextFrame`/`WSBinaryFrame` 的 `mediaType==''` 分支把字节直接 `as T`（`Array<Byte>` 参数）正确，`Charsets.forName` 失败有明确消息 |
| 12 | `f_mvc/src/WSEndPointMacro_test.cj` | .cj | ✅ | 见 #26（固定端口 18100 + 就绪失败静默）；用例本身只断言 101/405 两个首行，宏与 `WSMeta` 的漂移能被这条用例钉住（注释已说明未覆盖带 `@OnWS*` 的端点） |
| 13 | `f_mvc/src/WSMeta.cj` | .cj | ✅ | 见 #2、#12、#15、#20；`pumpFrames` 的 `finally` 取消定时器正确；ping 动作 `catch (_: Exception) {}` 有注释说明"不能抛进定时器线程"，按 §3 误报边界不判；`dataFrameCloseReason` 两条判定有单测 |
| 14 | `f_mvc/src/WSMeta_test.cj` | .cj | ✅ | 3 条用例（断链后 ping 停止、存活时 ping 在跑、数据帧关闭原因）依赖 `sleep(10ms×n)` 的真实时间，抖动环境下可能误报（并入 #26 的测试稳定性说明）；不涉及生产缺陷 |
| 15 | `f_mvc/src/WSPing.cj` | .cj | ✅ | 注解默认值 `duration='30s'`、`mediaType=''`；`WSMeta.generate` 用 `Duration.parse(annotation.duration)`（`WSMeta.cj:403`），默认值合法，空串/非法值会在模块初始化期抛（fail-fast，可接受） |
| 16 | `f_mvc/src/WebSocketRouting_test.cj` | .cj | ✅ | 见 #26（固定端口 18099、全局注册、`spawn` 异常未观察）；对"普通 GET 仍 405"的断言有效，但未覆盖 `WS` 方法（见 #23） |
| 17 | `f_mvc/src/exception/HttpRequestException.cj` | .cj | ✅ | 4 个构造器转发 `BaseException`，`internal import` 正确；无逻辑 |
| 18 | `f_mvc/src/exception/HttpResponseException.cj` | .cj | ✅ | 与 `HttpRequestException` 逐行同形（§2 的"只改类型名"，但这是异常类型的必要样板，不判重复）；**本文件自身没有 `import` `BaseException`**，靠同包 `HttpRequestException.cj:18` 的 `internal import fountain::f_exception.BaseException`（Cangjie 的 `import` 是包级可见）才能编译——脆弱但当前可编译，记「范围外提示」 |
| 19 | `f_mvc/src/exception/MVCException.cj` | .cj | ✅ | 同上；`MVCException()` 无消息构造器被 `WSDataFrame`（#24）与 `HttpRequestDistributorImpl.cj:51,54` 使用 |
| 20 | `f_mvc/src/exception/WSException.cj` | .cj | ✅ | 同上；`WSException` 在 `WSMeta` 中用于 meta 缺失/帧类型不符，消息完整 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。（`exception/imports.cj`、`AuthHandler.cj`、`MultiRequestMethodHandler.cj`、`FileDownload.cj`、`macros/*.cj`、`README.md` 等只作为调用链/承诺源取证，不计入本部分覆盖。）

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 #4/#5/#6/#7/#8/#10/#13/#14/#20；设计 #13（注册表职责重叠）、#2（可变 `pattern` 成员）；语言特性：`as T` 返回 `Option<T>`（已核 `typecast.md`，`RequestMeta.extract` 模式成立）、`RequestCondition` 的 `Bool` 表达式函数体、`struct Series` 的 `static init` 均正确；可读性 #19/#21/#24；安全性 #1/#3/#15/#16 |
| §1 死代码 | 3 | 逐项机械过：`private` 全仓搜 → `checkHeader`（#17）、`functionParamMap`（#18）、`RequestMeta.populateResponseContentType`/`addMediaTypes`/`respond` 系列均有调用者；`internal` 在本包+子包搜 → `iterateConsumes`（`MultiRequestMethodHandler.cj:46`）、`loadStaticResource`、`get/setResponseStatus`、`pumpFrames`、`dataFrameCloseReason`、`lazyAccessLogFields`、`respondKind`、`finishRequest`、`closeResultIfResource` 全部有引用；`protected` 检查（`RequestCondition.check*` 在非 public 类里，但都被子类覆写/基类调用）均非死代码；`RequestMetas.metas` 属"只写不读"，按后果归 #13（一般）。对外可达的 `public`（`RequestMeta` 全部公开成员、`RequestMapping` 家族、`WSMeta`/`WS*Meta`/`WSCloseFrame`/`WS_*` 常量、`Series`、`download` 重载、4 个异常类）一律不判，仓内零引用者（`Series.valueOf`/`resolve`/`values`、`WS_RESERVED_*`、`RequestMeta.isMultipart`、12 个 `extract*Arg`）已作为"对外 API"记录，其中 `isMultipart`/`extract*Arg` 因实现不可用另报 #6/#2 |
| §2 重复逻辑 | 3 | #21（参数类型分派两份）、#22（`Accept` 解析四处）、#27（双标记放行两处）；另核对了 `RequestMeta.compare` 每次构造两个 `TreeSet` 与 `equals`/`toString` 无重复、`ResponseDownload` 两条下载循环的差异（单文件 vs 多文件、`length` 参数）是业务要求不是重复、4 个异常类逐行同形属必要样板、`ValueContains`/`SubsetOfValues` 两个 `check` 方向相反（不是重复） |
| §3 空实现 | 1 | #24（抛空消息异常）；`WSDataFrame.extract(String...)` 是接口成员的"拒绝实现"（用 HTTP 控制器误用 WS 注解时触发），`WSMeta.handle`/`WSFuncMeta.handle` 的空默认实现总会被宏 `setHandle` 覆盖（`macros/WSEndPoint.cj:145`），`WSFuncMeta.setHandle` 在 `mediaType==''` 且返回值非 `Array<Byte>` 时返回空帧（静默失败，并入 #12 的建议"要么报错要么不要静默"）；`ping` 动作的 `catch (_: Exception) {}` 有明确注释，按误报边界不判 |
| §4 栈溢出 | 0 | 唯一递归是 `RequestCondition.compile(Expr)`（`32-60`）对 AST 的遍历，深度由开发者写在 `params`/`headers` 注解里的表达式嵌套决定（不是请求输入），且有 `ParenExpr`/`UnaryExpr`/`BinaryExpr` 的有限分支；`RequestCondition.check` 的 `And`/`Or` 组合递归同理；`Series`/`RequestMapping`/`WSMeta` 无递归、无自引用结构 |
| §5 OOM | 1 | #9（`staticResourceBytes` 整文件常驻 + 无上限，量化：单文件大小 × 被访问文件数）；其余：`WSMeta` 的帧缓冲受对端消息大小约束（stdx 是否限制单帧大小未确认，不在本部分下结论）、`RequestMetas`/`RequestMeta.args`/`RequestMapping` 只在启动期增长、`copy` 是流式分块 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench`/分段计时数据，任何"热点"结论都不成立；4 条疑似开销（`AcceptQueue`、静态资源缓存、WS 帧聚合、`copy` 切片）全部进「待验证假设」与优化方案，标 `无基线` |
| §6.2 大粒度锁 | 1 | #9（`File.readFrom` + 整文件分配发生在 `ConcurrentHashMap.entryView` 的原子区内，文档明确回调具有原子性且不能并发再调 `entryView/remove/replace`）；另一处 `RequestMetas` 的 `synchronized(mutex)` 只包一次 `TreeSet.add`，临界区极小，不判 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future.get`/线程池；`RequestMeta.setHandle` 的 `Box` 惰性缓存不复用线程，`AuthHandlerProxy` 的初始化在第 4 部分 |
| §6.4 低效算法 | 0 | `RequestMeta.compare`（`87-103`）每次比较构造两个 `TreeSet` 是 O(n log n)，但只发生在启动期 `TreeSet.add`（且该集合无读者，见 #13），不构成请求路径瓶颈；`checkProduces` 对多值 Accept 的 `AcceptQueue.remove()` 是 O(n) 但 n = Accept 条目数（≤ 个位数）；无嵌套循环匹配、无 `remove(at: 0)` 队列 |
| §7 降堆内存方案 | 1 | 优化方案「静态资源缓存改为小文件缓存 + 大文件流式」，标 `无基线（待验证）`；WS 帧缓冲复用列为第二条堆内存方案 |
| §8 降 CPU 方案 | 1 | 优化方案「`copy` 每块切片复制」，标 `无基线（待验证）`；`AcceptQueue` 复用与 `Series`/MIME 表改 `HashMap` 的收益无数据，只进假设 |
| §9 local mode 可行性 | 0 | 无合格候选：`loadStaticResource` 的字节数组必须逃逸到静态缓存（逃逸检查不过）；`respond` 的临时 `String`/`AcceptQueue` 是单次小对象（收益无法用峰值内存证明）；`WSMeta.exec` 的负载对象在 `spawn`/闭包/处理器之间跨调用存活（跨线程 + 逃逸，`LocalMode.md:986` 已列这条约束）；`LocalMode.md:334,468` 也已就 `f_mvc` 给出"`PathPattern.extract` 不改、`Any` 中转阻断 local 化"的既有结论，本部分不推翻 |
| §11 现有代码的 BUG（存量） | 27 | 全部 27 条均为存量（快照无 diff，`git blame` 落在 `4be871f2fd 2026-10-02` / `f55a882bb8 2026-07-25`）。另逐项核对了本轮读到的边界与空值：`WSCloseFrame` 空/1 字节 payload（#10）、`download(Array<File>)` 空数组（#25）、`RequestCondition` 的 `form.getAll` 空集合（`ContainsRequestCondition`/`Equal` 对空集合返回 false，正确）、`RequestMeta.extract` 的 `Option` 分支（`as T` 语义已核）、`RequestMethod.tryParse` 大小写（`toAsciiUpper` 已核）、`Series.valueOf(Int64)` 对非法状态的 `IllegalArgumentException`（正确）、`RequestArgMeta.operator []` 对未知 key 抛异常（#6 的一个触发点） |
| §12 并发安全与锁粒度 | 2 | 并发安全 #9（锁内 I/O + 非线程安全读取路径上的整文件分配）；锁粒度 #13（`RequestMetas` 用 `Mutex` 保护一个无读者的容器，属"锁了不该锁的东西"）。已核对的同步手段：`RequestMeta.currentResponseStatus`/`OverallStopwatch.start` 是 `ThreadLocal` 且三条出口都 `finishRequest` 清理（`RequestMeta.cj:244,306,719`）；`staticResourceBytes` 是 `ConcurrentHashMap`（单次操作原子，问题在回调体）；`RequestMeta` 的 `handle_`/`ignoreAuth_`/`pattern` 都是"注册期写、服务期只读"，注册发生在服务启动前（`MultiRequestMethodHandler.cj:200-207` 的注释有同样假设）；`setHandle` 的 `Box<?T>` 惰性缓存无同步，但只可能导致重复 `getBean`（singleton 返回同一实例），未列为缺陷 |
| §14 功能完备性与 README 覆盖 | 2 | #2（`WSMeta.extract*Arg` 公开 API 不可用）、#6（`isMultipart` 公开 API 恒 false）；承诺源交叉核对：`README.md:113`（HTTP 处理管线）与实现一致、`README.md:148/185`（`@IgnoreAuth` 与 Handler 选择规则）与 `AuthHandler.cj` 不一致（#1）、`README.md:1174-1181`（WebSocket）未提鉴权（#15）。本部分无 `.md` 文件，README 正文审查属第 1/4 部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件、无需延后；本部分 0 个 `.md`，§13 仅以 README 作承诺源抽查（`113/148/185/1174-1181`） |

**范围外提示**（不计入统计，均属本模块其它部分文件，已在本部分调用链上取证）：

1. `f_mvc/src/FileDownload.cj:120-132` 的 `next` 不写 part boundary、`140-142` 的 `Content-Disposition` 用逗号而非分号，与 `ResponseDownload.cj` 的两个多文件入口叠加成 #14；修 #14 时应对齐修这里。
2. `f_mvc/src/MultiRequestMethodHandler.cj:137-145` 的 `setStatus` 同样把 `Accept` 原文写成 `Content-Type`（与本部分 #7 同根因）；`164-180` 的 `ToData` 渲染又单独实现了一遍 Accept 解析（与 #22 同族）。
3. `f_mvc/src/AuthHandler.cj:97-120` 的 `noHandlers` 是"首次检查即定稿"：应用一个 `AuthHandler` 都没注册（或注册晚于首个请求）时所有请求直接 `AuthStatus.OK`，属"默认放行"设计；是否可接受取决于部署约定，第 4 部分审查时建议单独确认。
4. `f_mvc/src/exception/HttpResponseException.cj:18` 使用 `BaseException` 却不写 `import`，靠同包 `HttpRequestException.cj:18` 的 `internal import fountain::f_exception.BaseException` 生效（Cangjie 的 `import` 按包共享）；单独把该文件挪到别的包、或删掉 `HttpRequestException.cj` 的那行，都会直接编译失败。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 13 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

> 存量缺陷 27 条，是否纳入修复由用户决定；本报告不替用户拍板。另：本部分与第 4 部分在 `AuthHandler.cj:121-134` 上有唯一一处潜在重叠（#1 的根因），合并时按一条计。

## 总评

本部分是 f_mvc 的"路由条件 + 请求元数据 + WebSocket 元数据 + 下载 + 异常"层，20 个文件里真正有逻辑的只有 4 个（`RequestMeta.cj` 722 行、`WSMeta.cj` 424 行、`RequestCondition.cj` 196 行、`ResponseDownload.cj` 76 行），其余是注解、枚举、异常与测试。整体工程质量偏上：近期一轮 `MVC-*` 修复留下的注释（`MVC-2/3/4/8/13/L5/L11/L12`）都能在代码里找到对应改动与用例，`RequestMethod` 的哈希/相等、`finishRequest` 的三条出口清理、`pumpFrames` 的定时器取消、`respondKind` 的空结果分支都有单测钉住。

但**鉴权与"公开 API 是否真能用"这两条线明显比其它部分薄弱**：

- 阻塞项一：#1 `@IgnoreAuth` 在"分离 Handler"部署下连带跳过权限检查，是可直接利用的越权；它恰好落在 README 两段承诺的夹缝里（`148` 说只忽略登录、`185` 说标记原样传给实现类），所以既不是文档写错也不是实现写错，而是**两条承诺交叉处的分支没人走过**。修法是把 Proxy 的两段检查拆平（十行左右），并补一条"两个 Handler + 单标记"的用例。
- 阻塞项二：#3 静态资源兜底默认以**进程工作目录**为根，且不校验 `..`/符号链接、读文件异常不降级——未配置 `mvcStaticResourceRoot` 的部署等于把工作目录（以及潜在的整个文件系统）开给未鉴权的 GET。这一条要么改默认值（未配置即关闭），要么把根目录规范化 + 前缀校验 + 白名单扩展名一起补上。
- 契约面：#2 `WSMeta.extract*Arg` 因为 `WSMeta.pattern` 从未赋值而必然抛 `NoneValueException`，12 个公开方法与 `README` 的 WebSocket 章节对不上；同族的 #6 `isMultipart` 判断了一个永远不成立的类型。#2/#6 都是"仓内零调用 + 零测试"的对外 API——与 `RequestMetas`（#13，只写不读）一起说明：**本模块有几处 API 是"写出来就没人再碰"，缺的是使用侧回归而不是文档**。
- 语义陷阱：#4 `params` 条件在无 query 时恒假（POST 表单体永远匹配不到，错误表现为 501）、#5 默认 `consumes=''` 让 GET/DELETE 对带 Content-Type 的请求一律 415、#7/#8 把 `Accept` 当 `Content-Type`/在 `*/*` 下丢错误体、#10 空 Close 帧越界、#11 关闭码常量写错——这些单条影响有限，但都发生在"请求进来/响应出去"的必经路径上，且都不报错、只表现为"路由不命中/客户端解析异常"，排查成本高。
- 可维护性：#14（多文件下载缺 boundary）、#20（帧状态机两处不完整）、#21/#22/#27（三组重复逻辑）属于"改一处不够、要同时改两三处"的债务；#17/#18/#19 是纯残留，删除即可。
- 性能与内存：本部分没有任何改前/改后数据，2 条内存方案 + 1 条 CPU 方案与 4 条假设都不进修复清单。下一轮最值得补的是"静态资源常驻对 RSS 的影响"（假设 2，与 #3/#9 同源）与"WS 大消息的分配量"（假设 3）——它们决定 #9 与 WS 缓冲要不要动结构。
- 已确认**没有**的问题：`RequestMethod` 的 `hashCode`/`==`/`compare` 三者自洽且有测试；`RequestCondition.compile` 的递归只受开发者注解表达式约束（非请求输入）；`WSMeta.exec` 的读循环与 ping 定时器生命周期正确（`finally` 取消）；`dataFrameCloseReason` 的两条"该关就关"判定与 `WSCloseFrame` 常量表除 1008 外均与 RFC 6455 一致；`download` 的 `copy` 只写实读长度（`MVC-4` 修复已生效）；`Series`/`WSPing`/4 个异常类无逻辑缺陷。
