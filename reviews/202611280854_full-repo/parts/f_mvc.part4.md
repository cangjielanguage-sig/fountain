# f_mvc 模块审查报告（第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（模块共 59 个 `.cj` + 9 个 `.md`；本部分 8 个 `.cj` + 0 个 `.md`，共 8 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 可比；本部分所有问题来源均为「存量」）
- **审查重点**：路由 / 参数绑定正确性、鉴权与权限（`@IgnoreAuth` 语义）、并发安全、死代码、重复逻辑、存量 BUG（本部分对 §1 死代码 / §2 重复逻辑做了机械排查，并逐个 `import` 核对了全包使用情况）
- **报告版本**：v1（模块第 4/4 部分，与 `reviews/202611280854_full-repo/parts/f_mvc.part1..3.md` 由主 Agent 合并；本文件只统计本部分文件：`global_func.cj`、`imports.cj`、`exception/imports.cj`、`macros/{imports,Controller,WSEndPoint}.cj`、`health/MVCHealthMonitor.cj`、`response_download_test.cj`）

## 发现

### 1. [严重][存量] `GET /health` 对任何不带 `Content-Type` 的请求恒返回 415，框架自带的健康探针用不了

- **位置**：`f_mvc/src/health/MVCHealthMonitor.cj:26`（`@GetMapping[path:"/health", produces:'application/json', consumes:'application/x-www-form-urlencoded']`）
- **来源**：存量 —— 快照模式无基线；`git blame -L 26,26` 显示该行属 `64e1d0c6a`（2026-11-05，只把 `produces` 从 `text/plain` 改成 `application/json`），`consumes` 自 `ded2987aba`（2026-08-17 首次入库）起未变
- **判据**：review-checklist §11（契约与实现不符 / 与规格冲突）；§14（承诺的能力不可用）
- **证据**：静态确定 —— 路径可完整推导：
  1. `GetMapping` 的 `consumes` 默认值是 `''`（`f_mvc/src/RequestMapping.cj:52`），本端点显式覆盖成 `application/x-www-form-urlencoded`；`RequestMeta.addConsumes` → `addMediaTypes(..., allowAny:false, allowEmpty:true)` 只在 `types` 为空时补 `''`（`f_mvc/src/RequestMeta.cj:463-483,490-492`），因此该路由在分发表里**只有一个键** `application/x-www-form-urlencoded`。
  2. 分发时 `let consumes = headers.getFirst('Content-Type') ?? ''`，先 `metas.get(c)`，未命中再看 `metas.get('*')`（仅 WS 端点会注册 `'*'`），两者都没有就 `UNSUPPORTED_MEDIA_TYPE`（`f_mvc/src/MultiRequestMethodHandler.cj:63,74-92`）。GET 请求没有 body，正常客户端（curl 无 `-H`、k8s/负载均衡探针、浏览器导航）都不带 `Content-Type` ⇒ `c == ''` ⇒ 415。
  3. 同一文件 `:84-88` 的注释自证这条判据：「WS 握手请求没有 Content-Type（`c == ''`）⇒ 原先在这里被判 415；端到端实测确认了这一点」——正是因为该分支会被命中，才给 WS 加了 `'*'` 兜底。
  4. 工程内的真实调用方正好踩中：`fprobe/src/collect/health/HttpProbe.cj:52-60` 的 `FHttpClientProbe.get` 只设 `Accept: application/json`，不带 `Content-Type`；`fprobe/src/collect/health/MvcHealthProbe.cj:58-61` 把非 2xx 收敛成 `error`。`fprobe/doc/spec/add-fprobe/design.md:16` 还把「`GET /health` 返回 `HealthData`」当作既有能力引用（并标注了 `MVCHealthMonitor.cj:26-29`）。
- **描述**：`/health` 只有携带 `Content-Type: application/x-www-form-urlencoded` 才能进 handler，这与「健康检查」的使用方式相反；外部探针拿到 415 后按错误上报，等于该端点在生产上恒不可用。同时该端点没有任何启用开关（`f_health` 的 `health_enabled` 只控制日志监控，见 `f_health/src/HealthConfig.cj:22-28`），不可用也不可关。
- **建议**：删掉 `consumes:'application/x-www-form-urlencoded'`（GET 用默认 `''` 即可）；若确实要限制，应写 `consumes:''` 而不是任何具体类型。补一条端到端用例：起 `HttpRequestDistributorImpl` + 无 `Content-Type` 的 `GET /health`，断言 200 且 body 可被 `HealthMetrics.tryParse` 解析（现在全仓没有任何用例真的请求过 `/health`，`grep -rn "/health" --include="*.cj"` 只命中 fprobe 的假实现与文档）。

### 2. [严重][存量] `@WSEndPoint` 函数级参数注入生成的代码类型不匹配：带非可选参数的 WS 处理器根本编译不过

- **位置**：`f_mvc/src/macros/WSEndPoint.cj:77-85`（`paramTokens` 的 `match` 全部分支以 `getOrThrow()` 收尾）；`:87-98`（`factParams` 四个分支）；`:105-116`（`metaHandles[...] = {=> ... }()`）
- **来源**：存量 —— 快照模式无基线；该函数最近一次改动是 `123eef0c3`（2026-10-08「@WSEndPoint 端点级 handle 去掉冗余 converter」），只动了端点级，函数级生成路径未变
- **判据**：review-checklist §11（契约与实现不符）；§14（承诺的能力不可用）；§3（功能未接完）
- **证据**：静态确定 ——
  1. `let <p> = match (None<paramType>) { ... }` 的**每个**分支都是 `(expr as <paramType>).getOrThrow()`（`:78-84`）。按 std 文档 `as` 返回 `Option`（`class_and_interface/typecast.md:54`），`getOrThrow()` 返回 `T`（`core/core_package_api/core_package_enums.md:392`），所以参数类型非 Option 时该变量是**非 Option 的裸值**（如 `String`）。
  2. `factParams` 的四条分支（`:90-98`）：
     - `!named && default.size == 0`（最常见写法 `func onText(msg: String)`）→ `msg.getOrThrow()`，而 `msg` 已是 `String`，`getOrThrow` 只定义在 `Option` 上 ⇒ 编译错误；
     - `named && default.size > 0` → `msg: msg ?? default`，`??` 要求左侧是 `?T`（`basic_data_type/basic_operators.md:185-187`）⇒ 编译错误；
     - `!named && default.size > 0` → 同上；
     - 只有 `named && default.size == 0` 生成 `msg: msg`，类型恰好相符。
  3. 即便把参数声明成 `?T` 让类型通过，`case _` 分支仍错：`m.extract<?T>(...)` 返回 `??T`，`as ?T` 作用在 `??T` 值上按文档恒得 `None`（同 `typecast.md:54`），`getOrThrow()` 必抛 `NoneValueException`。
  4. 该路径从未被编译过：全仓 `@WSEndPoint` 使用者只有 `fdemo/user/src/controller/SmokeWSEndPoint.cj:29` 与 `f_mvc/src/WSEndPointMacro_test.cj:35`，两者都是空类；后者 `:32-33` 明确写「未覆盖：带 `@OnWS*` 处理器的端点（宏的函数级生成路径）」。`fdemo/user/src/controller/SmokeWSEndPoint.cj.macrocall:57-75` 的展开结果里 `metaHandles` 是空表，也印证参数生成段没进入过任何构建。
- **描述**：`@WSEndPoint` 的文档承诺「`@OnWSOpen/@OnWSText/...` 修饰的公共实例函数」可带参数并注入帧数据 / 请求参数（`f_mvc/README.md:1194-1206`、宏注释 `:21-29`），但宏生成的调用代码对**非可选参数**（也就是用户最自然的写法）是非法表达式。用户一按文档写处理器就得到指向生成代码的编译错误（`msg.getOrThrow()`），且堆栈在宏展开产物里，定位成本高。这是「文档承诺但整条路径不可用」，不是可选优化。
- **建议**：把 `paramTokens` 的取值统一成「可选值」再交给 `factParams` 解包——即 `let <p> = <match>` 的各分支去掉 `getOrThrow()`（`case _` 分支的 `m.extract<T>(...) as ?T` 直接给 `?T`），随后：
  - 非命名无默认 → `<p>.getOrThrow()`；
  - 命名无默认 → `<p>: <p>.getOrThrow()`；
  - 有默认 → `<p> ?? <default>`（命名时 `<p>: <p> ?? <default>`）。
  同时把 `as <paramType>` 改成 `as ?<paramType>`（`extract` 的返回已是 `?P`，再 `as P` 是错的）。必须补一条**带 `@OnWSText` 处理函数**的编译级用例（现有 `WSEndPointMacro_test.cj` 只钉住空端点），否则这条路径仍会再漂移。

### 3. [一般][存量] 控制器内抛出的所有异常统一变成 500，`HttpRequestException` / `ValidationException` 的 4xx 语义被吞掉

- **位置**：`f_mvc/src/macros/Controller.cj:94-98`（`catch (e: Exception) { ex = e }` + `finally { meta.accessLog(...) }`）；下游 `f_mvc/src/RequestMeta.cj:575-589`（`e` 非空时一律 `MultiRequestMethodHandler.INTERNAL_SERVER_ERROR`）
- **来源**：存量 —— 快照模式无基线（`git blame -L 94,98 -- f_mvc/src/macros/Controller.cj` 落在 `4be871f2f`，2026-10-02 换行符统一前的既有实现）
- **判据**：review-checklist §11（错误处理缺失 / 失败路径当成功）；§10 正确性
- **证据**：静态确定 ——
  1. 宏把整个参数绑定 + 业务调用包在 `try` 里，`catch` 只记 `ex`，**不重抛也不分类**。
  2. `accessLog` 见 `e` 非空就调 `MultiRequestMethodHandler.INTERNAL_SERVER_ERROR.handle(ctx, ex)`（`RequestMeta.cj:575-589`），而该 handler 的默认 `kind` 是 `Text`，不读 `ex`，直接写 500 + 固定文案（`MultiRequestMethodHandler.cj:24-27,186-190`）。
  3. 框架自己抛的两种「客户端错误」就走这条链：缺必填参数 → `HttpRequestException('NO param for controller func, ...')`（`RequestMeta.cj:451-453`）；`@Validator` 不通过 → `ValidationException`（`ControllerFuncParam.cj:32-40`）。全仓没有任何位置把它们映射成 400（`grep -rn 'ValidationException\|HttpRequestException' f_mvc/src` 只有抛出点；`ErrorHttpRequestHandler` 的唯一实现是 `fdemo/boot/src/error/ErrorHandler.cj:27` 的 `Http500Handler`）。
- **描述**：客户端漏传参数或参数不合法，得到的是 `500 Internal Server Error` 和「服务器内部错误」文案：客户端不会修正请求、监控告警被 4xx 污染、按状态码重试的策略全部失效。对 `@RequestBody` 的反序列化失败同理。
- **建议**：在生成代码的 `catch` 里先做异常分类（`HttpRequestException` / `ValidationException` → 400，`MediaTypeException` → 415），或把分类逻辑收进 `accessLog` 之前的统一接缝（例如新增 `mvcStatusOf(e: Exception): HttpStatus`），仍由 `HttpStatusOnlyHandler` 统一渲染。补两条用例：漏参数 → 400、`@Validator` 失败 → 400。

### 4. [一般][存量] `parseValue` 对不支持的参数类型在**请求期**抛 `MVCException`，与 `@Controller` 文档承诺的「编译错误」不符

- **位置**：`f_mvc/src/global_func.cj:148`（`case _ => throw MVCException('${value} cannot be parsed to ${TypeInfo.of<T>()}')`）；文档承诺 `f_mvc/src/macros/Controller.cj:19-24`
- **来源**：存量 —— 快照模式无基线（`global_func.cj` 最近提交 `4be871f2f`，2026-10-02，仅换行符）
- **判据**：review-checklist §11（契约与实现不符 / 语义与注释不符）；§14（承诺的错误行为没实现）
- **证据**：静态确定 —— 宏注释写「请求处理函数只接收实现了 `DataFields<T>` 的类型……试图使用其它类型作为请求处理函数的参数将会在本宏展开时发生编译错误」。实际 `generateArgs`（`Controller.cj:107-155`）只把参数类型塞进 `TypeInfo.of<...>()` 和 `meta.extract<ptype, pt>(...)`，不做白名单校验；`parseValue` 的兜底分支是运行期 `throw`，该异常经上一条的 `catch` 变成 500。可复现的输入：任意声明为 `@RequestParam x: SomeCustomType`（未在 `parseValue` 分支表内、但 `DataFields` 由用户实现）的处理器，编译通过、请求时 500。
- **描述**：把「配置/声明错误」推迟到线上请求，且错误信息里的 `${value}` 打印的是 `?String`（形如 `Some("abc")`），也没说明是哪个参数、哪个注解。
- **建议**：二选一——① 在宏展开期用类型白名单校验参数类型，非法即 `diagReport(ERROR, ptype, 'unsupported parameter type ...', '')`，让文档成真；② 保持运行期失败但把文档改成「运行期抛 `MVCException`」，并把参数名与注解名带进消息（`parseValue` 增加 `name: String` 形参）。

### 5. [一般][存量] `parseValue` 缺 `Array<DateTime>`（以及所有 `??Array<*>`）分支：DateTime 标量支持、数组不支持

- **位置**：`f_mvc/src/global_func.cj:120-147`（数组分支表；`?DateTime` 在 `:41-45`、`??DateTime` 在 `:63-67` 有分支，数组里没有）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §11（只处理部分输入 / 分支不完整）；§3（`match` 少一个 case 落到兜底）
- **证据**：静态确定 —— `f_data/src/base/CollectionData.cj:75` 有 `extend<T> Array<T> <: CollectionData<Array<T>, T> where T <: DataFields<T>`，`f_data/src/base/DataDateTime.cj:55` 有 `extend DateTime <: DataFields<DateTime>`，所以 `Array<DateTime>` 满足 `RequestParam.extract<T>` 的 `T <: DataFields<T>` 约束、能编译；但分支表里被 `Array<String|Bool|Byte|Int8|Int16|Int32|Int64|UInt8|UInt16|UInt32|UInt64|Float64|Float32|Float16|BigInt|Decimal|Duration>` 覆盖，`Array<DateTime>` 落到 `:148` 抛 `MVCException`（⇒ 500）。同理 `??Array<...>` 全部缺失（只有标量有 `??` 分支，`:47-67`）。`DateTime` 还带 `AbstractDateTimeConverter`，数组路径连转换器都没机会用。
- **描述**：`@RequestParam dates: Array<DateTime>`（以及 `Array<Date>` 之类的同族写法）是合理需求，声明能编译、请求必 500，而标量 `DateTime` 工作正常——用户无法从文档或编译错误看出边界在哪。
- **建议**：补 `case _: ?Array<DateTime>`（并按转换器语义透传 `converter`）；`??Array<*>` 若确实要支持，抽成与 `??T` 一致的分派；两者都补用例（`parseValue_test` 类）。若决定不支持，在 README 的 `@RequestParam` 支持类型表里写明「数组仅支持 ……，不含 `DateTime`」。

### 6. [一般][存量] 标量解析失败被静默吞成「没有这个参数」，数组解析失败却抛异常：同一语义两套处理

- **位置**：`f_mvc/src/global_func.cj:26-45`（`Bool/Int*/UInt*/Float*/BigInt/Decimal/Duration` 全用 `tryParse`，失败返回 `None`）对照 `:70-144`（数组元素一律用 `parse`，失败抛 `IllegalArgumentException`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §11（错误处理缺失或静默）；§2（近似重复但边界不同 ⇒ 行为漂移）
- **证据**：静态确定 ——
  1. `tryParse` 解析失败返回 `None`（std `convert/convert_package_api/convert_package_interfaces.md:765-767`），`parseValue` 末尾 `match (any) { case x: ?T => x }` 原样把这个 `None` 交回（`:150-154`）。
  2. 调用方 `RequestMeta.extract` 拿到 `None` 后走 `case _ => throw HttpRequestException('NO param for controller func, which request param name is ${name}')`（`RequestMeta.cj:446-453`）——把「值非法」报成「参数缺失」。
  3. 数组分支用 `Bool.parse / Int8.parse / ...`（`:73,78,83,...`），非法元素直接抛（`parse` 失败抛异常，同文档 `:767`），跳过上面的「缺参」文案，直接 500。
- **描述**：`?age=abc`（非可选 `Int64` 参数）得到「NO param」——排查方向完全错；同样输入换成 `?ids=1,abc` 得到 500。两种都不告诉调用方「哪个参数、什么值、期望什么类型」。
- **建议**：`parseValue` 内部统一改成「解析失败即抛 `ValidationException`（带参数名与原始值）」，或返回一个显式的 `ParseFailed` 供调用方区分「缺失 / 非法」；两侧同时改，别只改标量。

### 7. [一般][存量] 健康端点没有 `@IgnoreAuth` / `@IgnorePrivilege`：应用一旦注册 `AuthHandler`，`/health` 就是 401

- **位置**：`f_mvc/src/health/MVCHealthMonitor.cj:26-29`（`@GetMapping` 未带 `ignoreAuth`，类上也无 `@IgnoreSecurity`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §12.1（安全 / 鉴权语义）；§14（能力未接线，端点不可用）
- **证据**：静态确定 —— `RequestMeta.generate` 的 `ignoreAuth` 只来自 `a.ignoreAuth` 或函数上的 `@IgnoreAuth`（`RequestMeta.cj:540-547`），本端点两者都没有；`AuthHandlerProxy.check` 在没有 handler 时返回 `OK`（`AuthHandler.cj:133-135`），一旦应用注册了 `UserSessionHandler`/`PrivilegeHandler`/`AuthHandler` 就走真实校验（`:121-132`）。fprobe 期望 2xx（`MvcHealthProbe.cj:58-61`），实际会拿到 401。
- **描述**：健康检查天生是给未认证的探针用的。当前实现让每个接入鉴权的应用都要自己再写一个不带鉴权的 `/health`，而框架自带的这个则是「要么 415（见第 1 条）、要么 401」。另外 `HealthData` 会把堆/线程/GC 计数直接暴露给未认证请求方（`f_health/src/HealthData.cj:24-90`），跳过鉴权前应确认这是有意的。
- **建议**：给 `health()` 加 `@IgnoreSecurity`（登录与权限都不查），或在 `@GetMapping` 里写 `ignoreAuth: true, ignorePrivilege: true`；若担心指标外泄，改为「默认只返回 `{"status":"ok"}`，详细指标受 `HealthConfig.enabled` 控制」。

### 8. [一般][存量] `@IgnoreAuth` 在「`UserSessionHandler` + `PrivilegeHandler` 分装」时连带跳过权限检查（跨部分：`AuthHandler.cj`）

- **位置**：`f_mvc/src/AuthHandler.cj:121-135`（`else if (!param.ignoreAuth && let Some(h) <- sessionHandler && ...)` 之后才是权限检查）
- **来源**：存量 —— 快照模式无基线（`f_mvc/src/AuthHandler.cj` 最近提交 `4be871f2f`）
- **判据**：review-checklist §12.1（安全 / 越权）；f_mvc 自身的 `@IgnoreAuth` / `@IgnorePrivilege` 是两个独立开关（`AuthAnnotation.cj:18-29`）
- **证据**：静态确定 —— 未注册「合并式」`AuthHandler`、而是分别注册 `UserSessionHandler` 与 `PrivilegeHandler` 时（接口注释 `:51-54` 承认这种装法存在，只是"最好在一个类中实现"），`ignoreAuth == true` 会让第二个分支的条件 `!param.ignoreAuth` 直接为假，落到末尾 `else { AuthStatus.OK }`——`privilegeHandler.check` 从未被调用，`ignorePrivilege` 取什么值都不影响结果。同一处的 `noHandlers` 是普通 `Bool` 且在 `synchronized` 之外先读（`:98-100`，双检读），发布语义不安全。
- **描述**：`@IgnoreAuth`（只想放过登录）实际放过了越权；而 `@IgnorePrivilege`（只想放过权限）仍要求登录——两个开关的语义不对称，且方向是「更宽松」，属静默放开。该文件属本模块其它部分，因本轮重点指定「`@IgnoreAuth` 语义」在此提一次，不重复计入本部分其它条目。
- **建议**：拆成两段独立判定：`if (!ignoreAuth && sessionHandler.isSome()) { 检查会话 }`，再 `if (!ignorePrivilege && privilegeHandler.isSome()) { 检查权限 }`；`noHandlers` 改为 `AtomicBool` 或整体放进同一把锁内读（`AllowsCache` 在 `MultiRequestMethodHandler.cj:209-224` 已经给了「全程持锁、不搞双检」的正确写法，可对齐）。补三条用例：`ignoreAuth` 单独为真时权限仍被调用、`ignorePrivilege` 单独为真时会话仍被调用、两者皆真直接 `OK`。

### 9. [一般][存量] `@WSEndPoint` 的注册代码手写了一份 `private let _ = {=> ... }()`，没复用 `topMacroAnonymousClosure`，注册期异常丢失上下文

- **位置**：`f_mvc/src/macros/WSEndPoint.cj:119-150`（自建 `quote(private let _ = {=> ... }())`）；对照 `f_macros/src/topMacroAnonymousClosure.cj:20-31`（`@Controller` 走的那条带 `try/catch` + `printStackTrace` 的包装）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §2（换控制流的重复实现）；§3（错误处理缺失）；§11（错误处理缺失）
- **证据**：静态确定 —— 展开产物 `fdemo/user/src/controller/SmokeWSEndPoint.cj.macrocall:49-78` 显示：`@Bean` 那一段被自动包了 `try/catch`，而 WS 注册这一段（`let meta = MVCStarter.generateAndRegisterWSEndPoint...` / `metaHandles[m.name](...)`）**没有任何 try**。`@Controller` 的同一位置（`Controller.cj:78`）用的是 `topMacroAnonymousClosure`，`HellowordController.cj.macrocall:75-84` 可见异常会打印出整段生成代码。
- **描述**：WS 注册期一旦抛异常（重复路径、反射取不到函数、`metaHandles` 键缺失等），用户只看到一条指向宏展开产物的 `NoneValueException`，看不到是哪个控制器/哪一行触发的。两处宏对同一件事写了两种实现，后续演进必然漂移。
- **建议**：把 `:119-150` 的 `quote(private let _ = {=> ... }())` 换成 `topMacroAnonymousClosure(quote(...))`（`f_macros` 已在 `macros/imports.cj:19` 导入），删掉本地手写包装。

### 10. [一般][存量] `@WSEndPoint` 用 `metaHandles[m.name]` 下标取值，且未校验文档要求的「处理器必须是 public、函数名唯一」：违规时是启动期崩溃或静默覆盖

- **位置**：`f_mvc/src/macros/WSEndPoint.cj:106`（`metaHandles[$(f.identifier.value)] = ...`，同名覆盖）、`:124-144`（`metaHandles[m.name](m, false)`）；文档 `:28`（"确保……函数名在当前类中唯一"）、`:64`（只收 `isPublic(d) && !isStatic(d)`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §11（契约未校验 / 崩溃）；§1（静默覆盖）
- **证据**：静态确定 + 待确认（反射可见性那一步）——
  1. `HashMap` 的 `[]` 取不到键时抛 `NoneValueException`（std `collection/collection_package_api/collection_package_class.md:6147-6166`）；`metaHandles` 只登记**public 且非 static** 的函数（`:64`），而 `WSMeta.generate()` 是按 `instanceFunctions` 反射取注解（`f_mvc/src/WSMeta.cj:374-408`）。两边的可见性判据不同源，一侧多一侧少就可能出现 `meta.openMeta` 为 `Some` 但 `metaHandles` 无此键 ⇒ 模块初始化期直接抛 `NoneValueException`。
  2. 同名重载（`@OnWSText func onText(msg: String)` 与 `@OnWSText func onText(msg: Array<Byte>)`）会让 `:106` 的赋值**后者覆盖前者**，且 `:107` 的 `paramTypes` 随之变成后一个重载的签名——前一个重载永远不执行，无任何告警。
  3. 待确认：`ClassTypeInfo.instanceFunctions` 是否包含非 public 实例函数（决定第 1 条的实际触发面）。查 `std/reflect` 文档的 `instanceFunctions` 未写明可见性过滤，仓库内也没有反例。
- **描述**：文档给了三条硬约束（必须是 class / 必须是 public 实例函数 / 函数名唯一），宏一条都不校验：不合规时要么启动崩溃（错误信息与用户的错因无关），要么静默丢弃一个处理器。
- **建议**：`generate` 里先做三项校验并用 `diagReport(ERROR, ...)` 报错（非 public / static / 同名重载各自一条消息）；读取处改成 `if (let Some(h) <- metaHandles.get(m.name)) { h(m, false) } else { diagReport(...) }`；`metaHandles` 的值改成数组以保留重载，或显式禁止重载。

### 11. [一般][存量] `@Controller` 文档承诺「其它公共函数会编译错误」，实现是静默跳过：漏写 `@GetMapping` 的公共函数不会产生任何路由也不报错

- **位置**：`f_mvc/src/macros/Controller.cj:19-24`（文档）；`:75-76`（`if (let m: MacroExpandDecl <- d && let f: FuncDecl <- extract(m) && !isStatic(f) && isPublic(f))`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §11（契约与实现不符）；§14.1（承诺了没实现 / 静默失效）
- **证据**：静态确定 —— 只有「被宏注解包成 `MacroExpandDecl`、且是 public 非 static 函数」的成员才生成处理器（`:76`）；一个没写 `@GetMapping` 的 `public func foo()` 是普通 `FuncDecl`，被条件直接滤掉，`MVCStarter.generateAndRegister` 也就不会被调用（`RequestMeta.generate` 只在 `function.annotations` 里找 `RequestMapping`，`RequestMeta.cj:543-546`）。`@Bean` 那部分照常注册，所以应用能起来、路由表里没有该路径，只在下一次请求时表现为 404。
- **描述**：拼错或漏写 `@GetMapping` 是控制器开发最常见的笔误，当前实现只给 404，不给任何编译期/启动期提示。文档还写了「其它公共函数……编译错误」，与实现相反（同一句里 `HttpResponseBuilderw` 也是笔误）。
- **建议**：在 `generate` 里对「public、非 static、有函数体、又不是处理器」的成员 `diagReport(ERROR, ...)`（若要允许辅助函数，就把文档改成「非处理器的 public 函数会被忽略，请改为 private」）；同步修掉 `:21` 的 `HttpResponseBuilderw`。

### 12. [轻微][存量] `parseValue` 的分支表是 17×2 的逐类型复制，其中 `?Array<Byte>` 与 `?Array<UInt8>` 是同一个类型，后者恒不命中

- **位置**：`f_mvc/src/global_func.cj:24-149`（标量 17 支 `?T` + 17 支 `??T` + 17 支 `?Array<*>`，只有类型名不同）；`:75-79` 与 `:100-104`（`Byte` / `UInt8`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §2（只改类型名的重复逻辑）；§1（恒假分支）
- **证据**：静态确定 —— `public type Byte = UInt8`（std `core/core_package_api/core_package_types.md:3-6`），因此 `case _: ?Array<Byte>`（`:75`）先匹配，`case _: ?Array<UInt8>`（`:100`）永远不可达；同理 `??UInt8`（`:56`）也是 `??Byte` 的别名分支。17 个数组分支体逐字相同（`let array = val.split(','); Array<T>(array.size){i => T.parse(array[i])}`），只有 `T` 不同。
- **建议**：抽 `func parseArray<T>(val: String, parse: (String) -> T): Array<T>`，各分支压成 `case _: ?Array<Int64> => parseArray(val, Int64.parse)`；删掉 `:100-104` 的 `UInt8` 分支并在注释里写明 `Byte == UInt8`。注意保留「数组用 `parse`（失败抛）而标量用 `tryParse`（失败 `None`）」这条现有差异，或按上一条统一。

### 13. [轻微][存量] `imports.cj` 里有 8 处导入在全包范围内没有任何使用

- **位置**：`f_mvc/src/imports.cj:18`（`std.ast.*`）、`:23`（`std.io.IOStream`，同行的 `ByteBuffer` 有用）、`:26`（`std.regex.*`）、`:31`（`stdx.encoding.hex.*`）、`:39`（`TextReader`、`TextWriter`，同行 `Charsets` 有用）、`:43`（`f_concurrent.ConcurrentHashSet`）、`:46`（`IllegalArgException`，同行 `UnreachableException` 有用）、`:48`（`fountain::f_regex.*`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 这些是 `internal import`，作用域是「本包及子包」（`package/import.md:293-296`），所以在 `f_mvc/src` 全目录（含 `health/`，不含独立包 `macros/`）按名字检索即可判定：AST 类型（`Tokens`/`Decl`/`FunDecl`/`ClassDecl`/`TypeNode`）与 `diagReport`/`parseDecl`、`Regex`/`=~`/`findAll`、`Hex`/`hex`、`TextReader`/`TextWriter`、`ConcurrentHashSet`、`IllegalArgException` 均为 0 命中（`imports.cj` 自身除外）。其余导入已逐项核对到使用点（如 `TlsServerConfig` 在 `MVCConfig.cj:85`、`Charsets` 在 `WSDataFrame.cj:33`、`RandomString` 在 `FileDownload.cj:32`）。
- **描述**：多余的 `internal import` 让「这个包依赖哪些外部能力」失真，也会给下游带来无谓的编译依赖（`f_regex`、`stdx.encoding.hex` 都在 `cjpm.toml` 依赖里）。
- **建议**：删除上述 8 处；若某处是「为下游 re-export」而故意保留，改成 `public import` 并在注释里写明用途。

### 14. [轻微][存量] `@WSEndPoint` 对 `attr[0]` 不做任何校验：空属性宏内部越界，非字符串首项被当成路径静默注册

- **位置**：`f_mvc/src/macros/WSEndPoint.cj:39-40`（`let path = attr[0]` / `let upgradeAttrs = attr[1 .. attr.size]`）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §11（边界未处理）；文档 `:23`（"必须指定且必须是 attr 开头第一个，必须是字符串类型"）
- **证据**：静态确定 —— 属性为空（`@WSEndPoint[]`）时 `attr[0]` 直接越界，宏以数组越界异常结束，用户拿不到「缺 path」的提示；写成 `@WSEndPoint[subProtocols: ['a']]`（漏路径）时 `attr[0]` 是标识符 token，`$path` 被拼进 `generateAndRegisterWSEndPoint<$klass>($path)` 后变成把该标识符当字符串字面量位置使用，要么编译错误要么注册出一个以标识符命名的路径。文档要求的三条约束（存在、首位、字符串）一个都没校验。
- **建议**：`if (attr.isEmpty()) { diagReport(ERROR, attr, 'WSEndPoint requires a path as the first attribute', '') }`，并校验 `attr[0].kind == TokenKind.STRING_LITERAL`；非字符串同样 `diagReport`。

### 15. [轻微][存量] 可读性小结：`match (None<T>)` 类型分派无注释、`anyArgs`/`anyargs` 命名不一致、文件头缩进、文件名与类名不符

- **位置**：`f_mvc/src/global_func.cj:24`（`match (none)`——靠 reified generics 用「`None<T>` 的运行时类型」做类型分派，没有任何注释）；`:15`（块注释结束符 ` */` 多一个前导空格，与同目录其它文件不一致）；`f_mvc/src/macros/Controller.cj:77`（`anyargs` 小写）与 `:85,97`（`anyArgs`）；`f_mvc/src/health/MVCHealthMonitor.cj:23`（文件名 `MVCHealthMonitor`，类名 `MVCHealthController`，fprobe 文档按文件名引用）
- **来源**：存量 —— 快照模式无基线
- **判据**：review-checklist §10（可读性 / 可维护性）
- **证据**：静态确定 —— 逐行比对即可；`match (None<T>)` 的语义依赖「`None<T>` 的运行时类型是 `Option<T>`，与 `case _: ?X` 按具体类型实参匹配」，这正是 `class_and_interface/typecast.md:83-87` 描述的类型模式子类型匹配，但换一个 SDK/编译器优化就可能让人误读，属于必须写「为什么」的位置。文件名与类名不一致会让按 fprobe 文档（`fprobe/doc/spec/add-fprobe/design.md:16`）反查的人多绕一步。
- **建议**：在 `:24` 上方加一行注释说明这是类型分派技巧及依赖（reified generics）；统一 `anyArgs`；修 `:15`；把文件改名为 `MVCHealthController.cj` 或类名改回 `MVCHealthMonitor`（改名需同步 fprobe 文档引用）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。以下三条均无改前基线，只能作为下一轮补数据的候选，不进修复清单。

### [堆内存] 每请求预构造的 `anyArgs` 可以按需生成

- **现状**：`@Controller` 生成的闭包每个请求都 `let anyArgs = ArrayList<Any>()` 并 `anyArgs.add(<每个参数>)`（`Controller.cj:85,145`、展开样例 `fdemo/user/src/controller/HellowordController.cj.macrocall:84`）。一次请求至少 1 个 `ArrayList`（默认容量）+ 每个参数 1 次装箱；参数为 `@RequestBody` 大对象时只是引用，但装箱与容器本身与业务无关。日志已做惰性化（`RequestMeta.cj:601-634`），只有 `anyArgs` 仍是急切的。
- **方案**：把 `anyArgs` 改成 `{=> ...}` 惰性构造器，只在 `checkAuth` 真的需要（`!ignoreAuth || !ignorePrivilege` 且注册了 handler）或 `accessLog` 真要拼文本时调用一次并缓存。
- **预期**：每请求少 1 个 `ArrayList` + N 次装箱；量级由 `getAllocatedHeapSize()` 前后对照确定，当前无数据。
- **代价**：`checkAuth` 的 `args` 形参从 `ArrayList` 改成 `() -> ArrayList`（或新增重载），`AuthParam.args` 是 public 字段，属签名变更；闭包捕获参数变量会延长其生命周期到请求结束（本来也是）。
- **验证**：同压测下 `getAllocatedHeapSize()` 与 GC 次数中位数对照（`-O2`、同并发、同输入），并确认 `checkAuth` 拿到的参数内容不变（现有 `RequestMeta_test` 的 accessLog 用例可扩展）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `parseValue` 的 50 余个 `match` 分支可改为按 `TypeInfo` 预建表的单次查表

- **现状**：每个带 `@RequestParam/@PathVariable/@RequestHeader` 的参数都要走一次最长 50+ 分支的顺序类型匹配（`global_func.cj:24-149`），匹配是「具体类型实参逐支比较」，命中越靠后比较次数越多（`Array<Duration>` 在最后）。
- **方案**：用 `HashMap<String, (String, ?AbstractDateTimeConverter) -> Any>` 以 `TypeInfo.of<T>().qualifiedName` 为键建一次表（模块初始化期），请求期一次查表 + 一次函数调用；数组分支共用 `parseArray`。
- **预期**：单参数绑定从「最多 50 次类型比较」降到 1 次哈希 + 1 次调用；端到端收益取决于参数个数与 QPS，无数据不下结论。
- **代价**：新增一张静态表（占内存、需保持与宏支持的类型集合同步）；`TypeInfo.qualifiedName` 在泛型实参上要拼装，需先验证拼装规则与 `case _: ?X` 的匹配语义完全等价（否则会静默改变行为）。
- **验证**：`cjpm bench -O2` 对 `parseValue` 做微基准（10 万次 × 各类型），再回到真实接口做端到端对照；必须先有用例钉住「每个类型的分支结果与修改前逐字节一致」。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 数组参数解析可以省掉 `split` 的中间数组

- **现状**：17 个数组分支都先 `val.split(',')` 得到 `Array<String>`，再按索引逐元素 `parse`（`global_func.cj:70-147`）——中间数组与每个子串都是一次分配。
- **方案**：单趟扫描 `val`，用下标区间直接对子串做 `parse`，不构造中间 `Array<String>`。
- **预期**：每个多值参数少 1 个数组 + N 个子串对象；对短参数（常见 `?ids=1,2,3`）收益很小，需数据。
- **代价**：手写扫描要复刻 `split` 的空串、结尾分隔符语义，容易引入行为差异；建议先补等价性用例（`,,`、`1,`、空串）。
- **验证**：`cjpm bench` 对 1k/10k 元素的参数做对照，同时断言结果与 `split` 版本一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `accessLog` 的 `anyArgs` 每请求分配在小包体接口上占比可观（尤其日志级别关闭时） | `f_mvc/src/macros/Controller.cj:85,145` | 分配量与自耗时占比 | `cjprof record` 跑 2 参数接口 10k 请求，对比注释掉 `anyArgs.add` 前后的 `getAllocatedHeapSize()` 与 GC 次数 |
| 2 | `parseValue` 的类型分派在「10 个以上参数」的接口上成为绑定阶段热点 | `f_mvc/src/global_func.cj:24-149` | 自耗时占比、参数规模阈值 | `cjprof record` 跑 12 参数控制器，输入 10k 请求，看 `parseValue` self time |
| 3 | `HealthData` 的 11 个属性每次请求都调 `std.runtime`（`getAllocatedHeapSize` 等）可能引入停顿，健康探针高频（1s）时放大 | `f_mvc/src/health/MVCHealthMonitor.cj:28` + `f_health/src/HealthData.cj:24-90` | 单次属性读取耗时、是否 STW | 对 `/health` 做 100 QPS × 10 分钟压测，量 P99 与 GC 停顿；或直接对 `getAllocatedHeapSize()` 做微基准 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/exception/imports.cj` | .cj | ✅ | 仅 `public import fountain::f_http.exception.*`；与 `f_mvc` 自有异常类（`MVCException`/`WSException`/`HttpRequestException`/`HttpResponseException`）无同名项，无冲突 |
| 2 | `f_mvc/src/global_func.cj` | .cj | ✅ | `parseValue` 是参数绑定唯一入口；见 #4/#5/#6/#12 |
| 3 | `f_mvc/src/health/MVCHealthMonitor.cj` | .cj | ✅ | 见 #1（consumes ⇒ 415）与 #7（未跳过鉴权） |
| 4 | `f_mvc/src/imports.cj` | .cj | ✅ | 逐项核对全包使用；8 处未使用，见 #13 |
| 5 | `f_mvc/src/macros/Controller.cj` | .cj | ✅ | 宏展开链已对照 `fdemo/**/*.macrocall` 实物；见 #3、#11、#15 |
| 6 | `f_mvc/src/macros/WSEndPoint.cj` | .cj | ✅ | 见 #2、#9、#10、#14 |
| 7 | `f_mvc/src/macros/imports.cj` | .cj | ✅ | `internal import std.ast.*` / `fountain::f_macros.*` 均被同包 `Controller.cj`、`WSEndPoint.cj` 使用；两个 `public import` 是为下游 re-export 的 `@Bean` / `@Pointcut` |
| 8 | `f_mvc/src/response_download_test.cj` | .cj | ✅ | 回归用例钉住包内 `copy`（`ResponseDownload.cj:71-76`）只写实读长度；断言完整、可有效防回归；`public class` + `@Test` 与仓内其它 `src/*_test.cj` 约定一致 |

合计：`.cj` 8 个 / `.md` 0 个 / 共 8 个，全部读完。

> 说明：本部分清单不含 `.md`；`f_mvc/README*.md` 与 `doc/**` 属本模块其它部分，本文只把它们当作「承诺源」引用（`README.md:1194-1206`、`fprobe/doc/...`），不参与本部分统计。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 4（#1 #2 #3 #4）、设计 2（#9 #11）、语言特性 1（#6 的 `tryParse`/`parse` 混用）、可读性 1（末条）。语言特性方面另核对了 reified generics 分派（`global_func.cj:24`）与 `as` 返回 `Option` 的语义（`class_and_interface/typecast.md:54`），均按文档判定 |
| §1 死代码 | 1 | 逐个 `private` / `internal` 符号搜引用：`parseValue`（3 处调用）、`generate`（4 个宏入口）、两处 `generate` 重载、`generateArgs` 均有调用者；`WeavedController` 等 4 个 `public macro` 对外可达不判（`fdemo/user/src/controller/CurrentUserController.cj:30` 有真实使用）。`import` 逐个核对（8 处未使用，见轻微条）。`return` 后无同层语句。`match` 恒假分支 1 处：`?Array<UInt8>`（`Byte == UInt8`） |
| §2 重复逻辑 | 2 | ①`parseValue` 17×2 逐类型复制（轻微条）；②`WSEndPoint.cj:119-150` 重复实现 `topMacroAnonymousClosure`（#9）。另比对了 `Controller.cj` 与 `WSEndPoint.cj` 的参数提取生成逻辑：语义不同（前者走 `RequestMeta.extract`，后者走 `WSFuncMeta.extract` + 帧注入），不算重复 |
| §3 空实现 | 1 | `MVCHealthController.health()` 不是空实现（`HealthData` 的 11 个 prop 均实时读 `std.runtime`）。命中 1 条：`parseValue` 对不支持的参数类型「能编译、请求期才失败」，属功能未接完（#4）。无 `TODO`/`FIXME`/空 `catch` |
| §4 栈溢出 | 0 | `global_func.cj` 无递归；`Controller.cj:64-68` 的 `generate(Decl)` 自递归只在 `MacroExpandDecl` 嵌套时发生，深度由源码嵌套层数（编译期常量）决定，不随输入增长 |
| §5 OOM | 0 | `parseValue` 的 `split` 结果与参数串长度成正比，受请求行/头大小限制（`MVCConfig.maxRequestHeaderSize`）；`anyArgs` 大小等于函数形参个数（编译期常量）。无全量物化、无全局只增容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点不成立；三条候选已列入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分文件无锁；`synchronized` 出现在 `RequestMeta`/`MultiRequestMethodHandler`（其它部分），本部分生成的闭包不持锁 |
| §6.3 并发串行 | 0 | 生成代码无 `spawn`、无 `Future.get`；WS 的 `pumpFrames` 是单连接单线程读帧（`WSMeta.cj:89-118`，其它部分） |
| §6.4 低效算法 | 0 | `parseValue` 的分支数是「类型个数」而非输入规模，线性扫描且无嵌套；未发现 `remove(at:0)`、循环拼串、重复正则编译 |
| §7 降堆内存方案 | 1 | 列出「`anyArgs` 惰性化」，无基线 ⇒ 只作待验证方案 |
| §8 降 CPU 方案 | 2 | 列出「类型分派表化」「数组省掉 split 中间数组」，均无基线 ⇒ 待验证方案 |
| §9 local mode 可行性 | 0 | `parseValue` 的临时对象（`split` 结果、`Array<T>`）确实不逃逸，是理论候选；但收益只能靠峰值内存对照证明，本部分无该数据，按 `review-checklist §9` 只能记「待验证」。另受约束卡住：`Array<T>` 等 std 类型需有 `@ local!` 构造重载，未逐个核对签名，暂不宣称可行 |
| §11 现有代码的 BUG（存量） | 9 | 逐个函数核对了边界 / 空值 / 错误处理 / 资源 / 契约：#1 #2 #3 #4 #5 #6 #8 #10 #11。资源方面：`response_download_test.cj` 用内存 `ByteBuffer` 无句柄；`parseValue` 无资源 |
| §12 并发安全与锁粒度 | 1 | 生成闭包只在请求线程执行、无共享可变状态（`anyArgs`/`any`/`ex` 均为局部）；唯一跨线程共享点是鉴权代理的 `noHandlers` 双检读（#8，跨部分文件）。未发现死锁、锁顺序、发布逸出 |
| §14 功能完备性与 README 覆盖 | 3 | ①`GET /health` 文档承诺但恒 415（#1）；②`@WSEndPoint` 处理器路径承诺但编译不过（#2）；③`@Controller` 文档承诺的编译期校验不存在（#11）。`.md` 覆盖核对以 `README.md:1194-1206`（WS 注解表）、`fprobe/doc/...:16`（/health）为承诺源 |
| 文件覆盖（§13 等） | 8/8 | 本部分 8 个文件全部读完；清单内无 `.md`，故 §13 文档一致性本部分记 0 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 9 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分是两个宏的「代码生成层」+ 参数绑定内核，问题集中在「文档与生成物不一致、且生成物从未被真正编译/请求过」：

- **阻塞项 2 条**：`GET /health` 恒 415（一条 `consumes` 让框架自带的健康端点完全不可用，fprobe 的探针会一直报错），以及 `@WSEndPoint` 函数级参数注入的生成代码类型错误（全仓没有任何带 `@OnWS*` 处理函数的端点，这条路径十个月没有进过构建，一按文档写就编译失败）。两条都是「承诺的能力实际不可用」，建议优先处理。
- **可排期**：控制器异常一律 500（4xx 语义丢失）、`parseValue` 的缺失分支与解析失败语义不统一、`@IgnoreAuth` 在双 handler 装配下连权限一起放过。前两条影响面广但改动局部；第三条涉及公开语义，建议与 `AuthHandler` 其它部分一起改并补用例。
- **清理项**：8 处无用导入、`Byte`/`UInt8` 同型死分支、`WSEndPoint` 手写注册包装（应复用 `topMacroAnonymousClosure`）以及若干校验缺失，风险低、可顺手做。
- 代码质量本身不差：`response_download_test.cj` 是一条写得比较到位的回归用例（钉住「只写实读长度」这条不变量），宏展开也普遍做了 `try/catch` 与生成物回显，主要短板是「生成路径缺少编译级用例」与「文档比实现走得快」。

本部分存量缺陷共 15 条（严重 2 / 一般 9 / 轻微 4），是否纳入修复待用户决定；优化方案 3 条（全部无基线）与待验证假设 3 条不进修复清单。
