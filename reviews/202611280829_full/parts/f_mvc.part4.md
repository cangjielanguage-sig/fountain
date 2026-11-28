# f_mvc 模块审查报告（第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（59 个源文件；本部分覆盖 14 个）
- **基线**：工作区快照（`git status` 仅两处未跟踪的 review 目录，源码无 diff；本部分全部发现均为**存量**）
- **审查重点**：WSPing / 异常 / 健康监控 / `@Controller` 与 `@WSEndPoint` 宏 / 响应下载测试的正确性与边界、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：part4（供主 Agent 与 part1~3 合并为 `docs/review/f_mvc_review_20261128.md`；本文件不单独作为最终报告）

## 发现

### [严重] `/health` 在普通 GET 下返回 415：`consumes` 写了 `application/x-www-form-urlencoded`

- **位置**：`src/health/MVCHealthMonitor.cj:26`（`@GetMapping[path:"/health", produces:'application/json', consumes:'application/x-www-form-urlencoded']`）
- **来源**：存量（`git blame` → `ded2987aba` 2026-08-17 建类；`consumes` 早于 `64e1d0c6a7` 2026-11-05「produces 由 text/plain 更正为 application/json」，该提交只改了 `produces`）
- **判据**：review-checklist §11（契约与实现不符）/ §12 无关，正确性路径
- **证据**：静态确定 —— 请求链完全可枚举：
  1. `GetMapping.consumes` 默认是 `''`（`src/RequestMapping.cj:52`），这里被显式覆盖为 `application/x-www-form-urlencoded`；
  2. 注册期 `RequestMeta.generate` → `meta.addConsumes(a.consumes)`（`src/RequestMeta.cj:553`），`addMediaTypes(consumes, types, allowAny:false, allowEmpty:true)`（`:490-492`）在 `types` 非空时**只** `set.add('application/x-www-form-urlencoded')`，不会加 `''` 键；
  3. `MultiRequestMethodHandler.register` 以 consumes 串为键（`src/MultiRequestMethodHandler.cj:46-56`），故 GET 表里只有这一个键；
  4. 请求期 `handle` 取 `consumes = headers.getFirst('Content-Type') ?? ''`（`:63`），在 `check(metas)` 里 `metas.get('')` 落空、`metas.get('*')` 只可能是 WS 端点（`:83-92`），于是 `UNSUPPORTED_MEDIA_TYPE`。
- **描述**：`curl http://host/health`、k8s liveness/readiness probe、任何不带 `Content-Type` 的探活都会得到 `415 Unsupported Media Type`；只有客户端恰好声明 `Content-Type: application/x-www-form-urlencoded`（GET 无 body，属于无意义头）才能拿到指标。健康检查能力对标准探活**不可用**，且失败是"415"而非缺测，运维侧很难归因。`produces` 的修正提交说明该端点当时被"校正"过，但没人验证过不带 Content-Type 的请求。
- **建议**：删掉 `consumes`（GET 用默认 `''`，即 `metas.get('')` 命中）；若确需限定，改成 `consumes: ''` 并在 README 写明。补一条 `MVCHealthController` 的路由单测：无 Content-Type 的 GET `/health` 必须 200 且 body 含 `allocatedHeapSize`。

### [一般] `@OnWS*` 文档化的 `WebSocket`/`HttpContext` 参数会在启动期抛 `WSException`

- **位置**：`src/macros/WSEndPoint.cj:69-86`（按类型注入参数的 `paramTokens`）、`:105-116`；校验方 `src/WSMeta.cj:409-421`
- **来源**：存量（宏与 `WSMeta.generate` 均为 2025 年代码；全仓 0 个 `@OnWS*` 使用者，见下）
- **判据**：review-checklist §11（契约与实现不符）/ §14（承诺能力不可用）
- **证据**：静态确定 —— 两条事实互相矛盾：
  1. `WSMeta<T>.generate()` 对每个处理函数的**每个**参数都要求"有且仅有一个 `ControllerFuncParam` 注解"，否则 `throw WSException('parameter of controller function must be with one and only one Annotation as @RequestBody or ...')`（`:409-421`）；
  2. 宏生成的参数注入却按**类型**分支：`?HttpContext` / `?HttpRequest` / `?HttpHeaders` / `?WebSocket` / `?Array<Byte>` 直接取 `ctx`/`request`/`ws`/`payload`（`:78-82`），只有其余类型才走 `m.extract`；
  3. README `:1198` 明确写「`@OnWSOpen` … 需要主动向客户端写时应声明 WebSocket 参数」，未提任何注解要求。
  因此 `public func open(ws: WebSocket)` 这种文档化写法在模块静态初始化期（`MVCStarter.generateAndRegisterWSEndPoint` → `WSMeta.generate`）直接抛异常，应用起不来。全仓 `@OnWS*` 命中 0 次（`grep -rn "@OnWS" --include=*.cj`，仅注释与判定逻辑），该路径从未被跑过，故十个月未暴露。
- **建议**：二选一——(a) `WSMeta.generate` 放行 `HttpContext`/`HttpRequest`/`HttpHeaders`/`WebSocket`/`Array<Byte>` 五类参数不做注解校验；(b) 在宏里对这几类参数生成时补一个内部注解。同时补一个带 `@OnWS*` 处理器的端到端用例（`WSEndPointMacro_test.cj:32-33` 已自认这是未覆盖项）。

### [一般] `metaHandles[m.name]` 无校验索引：非 public / 静态 / 重载处理器在启动期崩溃

- **位置**：`src/macros/WSEndPoint.cj:124-144`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失、崩溃）/ §1（注册了但永不触发的反向：注册表缺键）
- **证据**：静态确定 —— `metaHandles` 只收集「`decl.body.decls where isPublic(d) && !isStatic(d)`」的函数（`:64`），而 `WSMeta.generate()` 用反射遍历 `endpointClass.instanceFunctions` 的**全部**实例函数并按注解登记 `openMeta/closeMeta/textMeta/binaryMeta/pingMeta/pongMeta/pingFunc`（`WSMeta.cj:374-408`）。只要有人把 `@OnWSText` 写在 `private`/`protected` 函数上（编译期合法、注解目标只约束 `MemberFunction`），或写两个同名重载，`metaHandles` 里就没有对应键（或被后者覆盖），`:125/128/.../143` 的下标取值在模块初始化期抛异常，异常再被 `topMacroAnonymousClosure` 的 `catch` 打印后重抛（`f_macros/src/topMacroAnonymousClosure.cj:22-29`），表现为"启动失败 + 一大段宏展开栈"。
- **描述**：前置条件（"有且只有被 `@OnWS*` 修饰的公共实例成员函数"）只写在注释里（`WSEndPoint.cj:28`、README `:1192`），宏既不在展开期报 `diagReport`，也不在运行期给出可读错误，违反前置条件的代价是应用起不来且报错不可读。
- **建议**：宏展开期对"被 `@OnWS*`/`@WSPing` 修饰但不是 public 实例函数"直接 `diagReport(ERROR, ...)`；运行期把 `metaHandles[m.name]` 换成 `metaHandles.get(m.name) ?? diag` 式兜底并抛带 `m.name` 的 `WSException`。顺带把同处 7 段重复块合并（见 §2 条目）。

### [一般] `parseValue` 把解析失败折成 `None`：非法值被当成"缺参"，最终 500 且报错误导

- **位置**：`src/global_func.cj:24-45`（标量分支）、`:148-154`（收口匹配）；调用点 `src/ControllerFuncParam.cj:85-89`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（错误处理缺失 / 语义与命名不符）
- **证据**：静态确定 —— `Int32.tryParse("abc")` 返回 `None`，`match (any)` 的 `case x: ?T => x`（`:152`）把它原样返回；`RequestMeta.extract<T,P>` 拿到 `None` 后走 `case _ => throw HttpRequestException('NO param for controller func, which request param name is ${name}')`（`src/RequestMeta.cj:447-453`），再由 `accessLog` 交给 `INTERNAL_SERVER_ERROR`（`src/RequestMeta.cj:575-589`）。
- **描述**：`GET /x?page=abc`（`page: Int64` 必填）得到 **500 + "NO param for controller func"**：状态码错（应为 400）、文案错（参数在，是值非法）、日志里也没有原始值。若参数是 `?Int64`，则更糟——非法值被静默当成 `null` 交给业务，服务端无法区分"没传"和"传错"。
- **建议**：`parseValue` 区分三态（缺参 / 解析失败 / 成功）：解析失败抛 `HttpRequestException('invalid value ${val} for ${name}')`（或专门的 `ValidationException`），让上层映射 400；至少把 `case x: ?T => x` 之前加一层"`val` 非空但解析返回 `None` ⇒ 报错"。

### [一般] `parseValue` 的 21 个 `??X` 分支不可达（死代码），且真被启用时会吞掉已解析的值

- **位置**：`src/global_func.cj:47-67`
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §1（恒不成立的分支）
- **证据**：静态确定 —— `parseValue<T>` 只在 `ControllerFuncParam.cj:86/133/163` 三处被调用，三者都在 `extract<T> ... where T <: DataFields<T>` 内；`f_data` 里没有任何 `Option<T> <: DataFields<...>` 的实现（`grep "DataFields<" f_data/src` 只列出 Bool/DateTime/Duration/数值/集合/Map/DataAny），所以实例化时 `T` 永远不是 `Option` 类型 ⇒ `none = None<T>`（`:19`）的运行时类型不可能是 `Option<Option<...>>` ⇒ `case _: ??String` … `case _: ??DateTime` 永远不匹配。
- **描述**：21 行永假分支。附带一个隐藏缺陷：若将来真有 `T = ?String` 的调用（例如 WS 处理器参数），`case _: ??String => val` 会返回裸 `String`，收口 `match (any)` 的 `case x: T`（T 为 `?String`，裸 `String` 不匹配）与 `case x: ?T`（`??String`，也不匹配）全部落空，走 `case _ => None<T>`，**把用户传上来的值丢掉**。
- **建议**：整段删除；若确要支持"可空的可空"三态，改成 `match (any) { case x: T => Some(x); case x: ?T => x; case _ => None }` 之前先把 `any` 归一为 `?T`（例如 `Some(val) as ?T`），并补一条 `T = ?Int64` 的单测。

### [一般] `response_download_test` 只覆盖内部 `copy`，4 个公开 `download` 入口零覆盖

- **位置**：`src/response_download_test.cj:29-62`（`testCopyWritesOnlyReadBytes`）、`:64-69`（`testCopyEmptyInput`）
- **来源**：存量
- **判据**：review-checklist §14（测试覆盖与契约）/ §13 无关
- **证据**：静态确定 —— 用例只把 `ByteBuffer` 喂给包内 `copy(input, write)`（`src/ResponseDownload.cj:71-76`）并断言写出长度；`download(File)` / `download(InputStream, filename)` / `download(Array<Byte>, filename)` / `download(Array<File>)`（`src/ResponseDownload.cj:18-65`）与 `FileDownload` 的多段拼装（`start/next/end`）一行未测。第 3 部分已用同一份代码证出 multipart 分段头缺失的真实缺陷，而本文件全绿——正是"测试绿、功能坏"的典型。
- **描述**：`copy` 的作用是把 `read` 的返回长度截断后交给 `write`，这是修复点（MVC-4）本身，值得测；但它不覆盖 `download` 的接线（谁调 `copy`、多段边界、`length` 未知时的 `Transfer-Encoding`）。文件名/分段头/空输入这些真正出过错的地方仍是盲区。
- **建议**：补 `download(Array<File>)` 与 `download<C>(Iterable<(InputStream,String)>)` 的字节级断言（用可控的 `InputStream` + 收集器，断言 `--boundary`、段头空行、结束边界三段齐全），以及 `download(InputStream, length: -1)` 的 chunked 头断言；本条与第 3 部分 multipart 缺陷同源，合并报告时保留一条即可。

### [轻微] `imports.cj` 存在 9 处无引用的 `internal import`

- **位置**：`src/imports.cj:23`（`std.io.IOStream`）、`:26`（`std.regex.*`）、`:31`（`stdx.encoding.hex.*`）、`:34-37`（`stdx.crypto.{common,keys,kit,x509}.*`）、`:42`（`fountain::f_collection.*`）、`:43`（`f_concurrent.ConcurrentHashSet`）、`:46`（`f_exception.IllegalArgException`）；`:21` 的 `std.env.atExit` 亦无本包使用（`MVCStarter.cj:21` 用的是 `ExitCallbacks.atExit`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 在 `f_mvc/src`（排除 `imports.cj` 与 `*_test.cj`）逐符号搜索：`Regex` 0 次、`hex|Hex` 0 次、`Sign|Verify|Certificate|X509|Pem|digest` 0 次、`Collection` 0 次、`ConcurrentHashSet` 仅导入行自身 1 次、`IllegalArgException` 0 次（命中的都是 std 的 `IllegalArgumentException`）。`public import` 行是对外契约，不在此列。
- **描述**：Cangjie 的 import 是包级可见（同包其它文件不重复 import 即可用，见 `Controller.cj` 依赖 `macros/imports.cj`），所以这些行会为整个包引入编译依赖（`stdx.crypto.*` 尤其重）与名字冲突面，且误导读者以为本模块做加解密/正则匹配。
- **建议**：删除上述条目；保留 `std.sync.*`、`std.collection.concurrent.ConcurrentHashMap`（`RequestMeta.cj:46` 用到）、`f_random.RandomString`、`std.math.numeric`、`charset4cj`。

### [轻微] `HttpRequestException.cj` 的 `BaseException` 导入与包内约定重复且不一致

- **位置**：`src/exception/HttpRequestException.cj:18`（`internal import fountain::f_exception.BaseException`）
- **来源**：存量
- **判据**：review-checklist §1（冗余导入）
- **证据**：静态确定 —— `BaseException` 的真实定义在 `f_base/src/BaseException.cj:44`；本包 `src/imports.cj:56` 已 `public import fountain::f_base.*` 把它引入包作用域，`f_exception` 只是 `public import fountain::f_base.BaseException`（`f_exception/src/imports.cj:18`）的同一声明转发；同一目录下 `HttpResponseException.cj` / `MVCException.cj` / `WSException.cj` 三份同构文件都没有这行。
- **描述**：四个异常类逐行同构，只有这一个文件多一行导入，读者会误以为四个异常的基类来源不同。
- **建议**：删除该行，四个文件保持同构。

### [轻微] `WSEndPoint` 宏里 7 段重复的"取 meta → 填 handle"注册块

- **位置**：`src/macros/WSEndPoint.cj:124-144`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：同一套动作按字段名复制 7 遍）
- **证据**：静态确定 —— `openMeta/closeMeta/textMeta/binaryMeta/pingMeta/pongMeta/pingFunc` 七段形状完全一致，唯一差异是 `closeMeta` 传 `true`、其余传 `false`。
- **描述**：加一种帧类型就要再加一段，且"`true` 表示 close"这一语义没有名字，容易传错（例如给 `pingMeta` 传 `true` 不会报错，只会让关闭帧语义错位）。
- **建议**：改成 `for ((meta, isClose) in [(openMeta, false), (closeMeta, true), ...])` 式遍历，或在宏里生成一个 `let pairs = [...]` 后循环；`isClose` 用枚举/具名布尔替换裸 `true/false`。

### [轻微] `parseValue` 的 20 段数组分支只换类型名

- **位置**：`src/global_func.cj:69-147`
- **来源**：存量
- **判据**：review-checklist §2（"只改类型名"形态）
- **证据**：静态确定 —— 每段都是 `let array = val.split(','); Array<X>(array.size){i => X.parse(array[i])}`，仅 `X` 不同；`Float16`/`Decimal`/`Duration` 三段连格式差异都没有。
- **描述**：20 段各 4 行，共约 80 行同构代码；后续加类型（如 `Date`、`Path`）继续复制，且各处错误策略已出现漂移（见下一条）。
- **建议**：抽 `func parseArray<T>(text: String, parse: (String) -> T): Array<T>`，各分支压成一行 `parseArray(val) {s => Int32.parse(s)}`；同时统一"元素非法"的处理策略（现在标量用 `tryParse` 得 `None`，数组用 `parse` 直接抛）。

### [轻微] 标量与数组的非法值处理不一致（`tryParse` vs `parse`）

- **位置**：`src/global_func.cj:26-45`（标量：`tryParse` → `None`）对比 `:70-147`（数组元素：`parse` → 抛 `NumberFormatException`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理不一致）
- **证据**：静态确定 —— 同一请求里 `?ids=1,x,3` 会抛异常（→ 500，`accessLog` 未识别该类型），而 `?id=x` 静默变 `None`（→ 上一节的 500 "NO param"）；两条路径的最终状态码相同但原因与日志完全不同。
- **描述**：同一个参数解析器对"坏值"给出两种语义，调用方无法据此统一成 400。
- **建议**：统一为"坏值 ⇒ `HttpRequestException`（400）"，与上一条的修法一起做。

### [轻微] `WebSocketRouting_test` 固定端口 + 就绪失败仍继续 + `@Assert` 实参顺序颠倒

- **位置**：`src/WebSocketRouting_test.cj:40`（`PORT = 18099`）、`:59-69`（50 次探测失败后仍 `return server`）、`:105-106`（`@Assert(true, upLine.startsWith(...))`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理）/ 可读性
- **证据**：静态确定 —— 探测循环无论成功与否都返回 `server`，端口被占或 5 秒内未起来时后续 `connect()` 抛出的异常与断言失败混在一起；`@Assert(actual, expected)` 是两参相等断言（std 文档示例 `@Assert(1 + 2, 3)`），实参顺序写成 `(true, 条件)`，失败信息会显示 "expected: false, actual: true"，与真实原因相反。
- **描述**：端口 `18099` 与 `WSEndPointMacro_test` 的 `18100`（第 3 部分已记）是同一模式的两处实例；并行 CI 或本机残留进程会让用例偶发失败，且失败信息指向错误方向。
- **建议**：端口改为 `0`（由 `ServerBuilder` 分配后从 server 读取）或从环境变量取；探测失败 `throw` 带端口号的异常而不是返回未就绪 server；断言改 `@Assert(upLine.startsWith('HTTP/1.1 101'), true)` 或直接用单参 `@Assert(...)`。

### [轻微] 宏生成代码的标识符卫生与作用域依赖

- **位置**：`src/macros/Controller.cj:81-98`（生成 `meta`/`ctx`/`patterns`/`start_`/`any`/`ex`/`anyArgs`）、`:132-134`（生成 `let <param> = ...`）；`src/macros/WSEndPoint.cj:76-85`（生成 `m`/`cf`/`ctx`/`ws`/`payload`/`converter`/`pattern`）
- **来源**：存量
- **判据**：review-checklist §10（可维护性）/ 宏卫生
- **证据**：静态确定 —— 生成语句 `let $(p.identifier) = meta.extract<$ptype, $pt>(ctx, $pname, $default)`（`Controller.cj:132-134`）直接以用户参数名做局部变量名；控制器函数若有名为 `ctx`、`meta`、`anyArgs`、`ex` 的参数，展开后即与宏自己的局部变量重名（`ctx` 更是"先用后声明"）。`WSEndPoint` 侧同理（`m`、`cf`、`ws`）。另外生成物使用未限定名 `HashMap`/`ArrayList`/`MonoTime`/`TypeInfo`/`@Bean`，只有使用方 `import fountain::f_mvc.*` 才解析得到（README 示例确实这么写，但宏注释没写这个前提）。
- **描述**：当前 fdemo 没有触发，属于"用户一撞就报编译错误且错误指向宏展开"的可用性问题。
- **建议**：生成名统一加前缀（`__mvc_ctx`、`__mvc_meta`）或用 `quote` 之外的作用域隔离；宏文档（`Controller.cj:18-25`、`WSEndPoint.cj:21-29`）补一句"使用方必须 `import fountain::f_mvc.*`"。

### [轻微] `@Controller` 宏注释与实现不符（"额外公共函数会编译报错"）

- **位置**：`src/macros/Controller.cj:19-25`
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— `generate(Decl)` 只处理满足 `let m: MacroExpandDecl <- d && ...` 的声明（`:76`），即带 `@GetMapping` 一类映射注解的函数；一个**没有**映射注解的公共函数被静默跳过，不产生任何诊断，更不会"在宏展开时发生编译错误"。
- **描述**：注释把"不支持"说得比实现严格，维护者会误以为存在校验，从而不写显式检查。
- **建议**：要么在 `:76` 的 `else` 分支对"public 实例函数但无映射注解"报 `diagReport(ERROR)`（与注释一致），要么把注释改成实际行为（"无映射注解的公共函数会被忽略"）。

### [轻微] `@WSEndPoint` 对 `attr` 不做任何校验

- **位置**：`src/macros/WSEndPoint.cj:38-40`（`let path = attr[0]; let upgradeAttrs = attr[1 .. attr.size]`）
- **来源**：存量
- **判据**：review-checklist §11（边界，宏展开期崩溃）
- **证据**：静态确定 —— `@WSEndPoint[]` 会在 `attr[0]` 处越界（宏展开异常，报错指向编译器而非用户代码）；`@WSEndPoint[path: '/ws']` 会把 `path` 当路径拼进 `generateAndRegisterWSEndPoint$(path)`，生成非法代码。README `:1180` 只写"必须是字符串类型"，没有编译期诊断支撑。
- **描述**：宏对输入形态零校验，用户笔误的代价是编译器栈而不是可读诊断。
- **建议**：`if (attr.isEmpty() || attr[0].kind != STRING_LITERAL) { diagReport(ERROR, attr, "@WSEndPoint 第一个属性必须是路径字符串", ""); return input }`。

### [轻微] `WSPing` 注解无注释、`duration` 无校验

- **位置**：`src/WSPing.cj:18-21`
- **来源**：存量（2025 年建文件；`WSPing.cj` 全文件 4 行有效代码）
- **判据**：review-checklist §10（可读性）/ §11（缺少边界校验）
- **证据**：静态确定 —— 同类注解 `OnWSOpen.cj:18-21` 有行为说明，`WSPing` 没有；`duration` 在 `WSMeta.cj:403` 直接 `Duration.parse(annotation.duration)`，非法字符串（如 `'30'`、`'30 s'`）在模块静态初始化期抛异常，错误信息里没有注解所在函数名。
- **描述**：`@WSPing` 是唯一带参数的服务端主动行为，注释/文档（README `:1203` 只有一行表格）都没写 `duration` 的格式与"非法值启动失败"，`mediaType = ''`（表示直接返回 `Array<Byte>`）也没解释。
- **建议**：补类注释说明 `duration` 格式（`Duration.parse` 的形式，如 `30s`）与 `mediaType` 为空时的语义；解析失败包装成 `WSException('invalid @WSPing duration ${...} on ${name}')`。

### [轻微] 健康端点常开、路径固定、无鉴权开关，暴露运行时指标

- **位置**：`src/health/MVCHealthMonitor.cj:22-29`
- **来源**：存量
- **判据**：review-checklist §10（安全性：信息暴露）/ §14（缺少关闭能力）
- **证据**：静态确定 —— `@Controller` 直接展开为 `@Bean`，类里没有 `@IgnoreAuth`/`@IgnoreSecurity`，`MVCConfig` 中也没有任何 health 相关开关（`grep -i health MVCConfig.cj` 0 命中），路径写死 `"/health"`。
- **描述**：只要依赖 `f_mvc`，任何应用的 `/health` 就被占用（用户无法再定义自己的 `/health`，两条 meta 的 consumes 键不同时还会并存，行为取决于请求头），且返回的是堆大小、线程数、GC 次数等运行时指纹，默认对未认证客户端开放（是否 401 取决于应用是否注册了 `AuthHandler`）。
- **建议**：加 `MVCConfig.healthEnabled`（默认 `false`）或 `healthPath`；README 写明默认行为与鉴权建议；至少把路径改为可配置，避免与业务路由冲突。

### [轻微] README 未写 `/health` 的路径与响应结构

- **位置**：`README.md:1329`（`MVCHealthController`：`func health(): HealthData`）、`README_en.md:1344`（同一句）
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化关键信息）
- **证据**：静态确定 —— README 全文 `grep "/health"` 0 命中（`MVCHealthController` 只出现在"其他公开 API"清单里），而路径只存在于 `src/health/MVCHealthMonitor.cj:26`；`HealthData` 的 11 个字段（`f_health/src/HealthData.cj:24-78`）也没有说明。
- **描述**：读者知道有这么一个控制器，但不知道访问哪个 URL、返回什么、是否需要鉴权、能否关闭。
- **建议**：在 README 的公开 API 段补一小节：`GET /health`、返回字段表、`Accept` 影响、鉴权与关闭方式（与上一条一起改）。

## 优化可行性方案

本轮无带基线的优化方案（0 条堆内存 / 0 条 CPU）。`parseValue` 的 match 分派与 `Any` 装箱是唯一值得测的形状，但没有任何 profile / 基准数据，按规则只能进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `parseValue` 的 ~60 分支 `match` + `Any` 装箱在每请求每参数上执行，可能是参数绑定路径的主要自耗时 | `src/global_func.cj:24-154` | 自耗时占比、每请求分配量 | 造 10 参数控制器（标量+数组各半），`cjpm bench -O2` 打 10k 请求取中位数；`cjprof record` 看 `parseValue`/`TypeInfo.of` 的 self time 与分配 |
| 2 | `WebSocketRouting_test` 固定端口 `18099` 在并行 CI / 本机残留进程下失败率显著 | `src/WebSocketRouting_test.cj:40,59-69` | 失败率 | `cjpm test` 连跑 50 次统计失败次数，同时开一个占坑脚本占住 18099 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/WSPing.cj` | .cj | ✅ | 注解定义与 `WSMeta.cj:401-404` 对读；见「WSPing 注解无注释」 |
| 2 | `src/WebSocketRouting_test.cj` | .cj | ✅ | 端到端握手用例；见固定端口与 `@Assert` 顺序 |
| 3 | `src/exception/HttpRequestException.cj` | .cj | ✅ | 见冗余导入 |
| 4 | `src/exception/HttpResponseException.cj` | .cj | ✅ | 仓内 0 引用，但为对外 `public` 契约，不判死代码 |
| 5 | `src/exception/MVCException.cj` | .cj | ✅ | `global_func.cj:148`、`MVCStarter` 等在用 |
| 6 | `src/exception/WSException.cj` | .cj | ✅ | `WSMeta.cj` 在用 |
| 7 | `src/exception/imports.cj` | .cj | ✅ | `public import` 转发 f_http 异常，属对外契约 |
| 8 | `src/global_func.cj` | .cj | ✅ | `parseValue` 全 155 行逐分支核对，见 3 条发现 |
| 9 | `src/health/MVCHealthMonitor.cj` | .cj | ✅ | 见 415 与常开端点 |
| 10 | `src/imports.cj` | .cj | ✅ | 逐符号核对，见 9 处无用导入 |
| 11 | `src/macros/Controller.cj` | .cj | ✅ | `generate/generateArgs` 与 `RequestMeta.setHandle`、`extract` 对读 |
| 12 | `src/macros/WSEndPoint.cj` | .cj | ✅ | 与 `WSMeta.cj`、`fdemo/SmokeWSEndPoint.cj` 对读 |
| 13 | `src/macros/imports.cj` | .cj | ✅ | 承载宏包 `std.ast`/`f_macros` 依赖与 `@Bean`/`@Pointcut` 再导出，均有用 |
| 14 | `src/response_download_test.cj` | .cj | ✅ | 见覆盖缺口的发现 |

合计：`.cj` 14 个 / `.md` 0 个 / 共 14 个，全部读完（本部分无分配到的 `.md`；`README.md` / `README_en.md` 仅按 §13/§14 定向核查了与本部分符号相关的段落）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：`/health` 415、`parseValue` 静默 `None`；设计：健康端点常开、宏前置条件无校验；语言特性：`Any` 装箱与 `Option` 匹配语义（`??X` 分支）；可读性：注解无注释、注释与实现不符；安全性：`/health` 无鉴权暴露运行时指标 |
| §1 死代码 | 2 | `parseValue` 的 21 个 `??X` 分支（`T` 恒非 Option，`Option` 无 `DataFields` 实现）；`imports.cj` 9 处未使用 import。其余逐个核对：`private generate/generateArgs/startServer/request` 均有调用；`Controller`/`WeavedController`/`WSEndPoint`/`WSPing`/四个异常类/`MVCHealthController` 均对外可达（不判）；`HttpResponseException` 仓内 0 引用仅作信息记录；`macros/imports.cj` 的两条 `public import` 是展开后 `@Bean`/`@Pointcut` 的可解析前提 |
| §2 重复逻辑 | 2 | `WSEndPoint.cj:124-144` 七段同构注册块；`global_func.cj:69-147` 二十段"只换类型名"的数组分支。另比对：四个异常类是同一模板但类型身份即语义（`catch (WSException)` 依赖），不算重复；`WebSocketRouting_test:47-50` 手写的 handle 与宏生成物同形，属"测试钉住宏输出"的有意重复，已在覆盖缺口条目中说明 |
| §3 空实现 | 0 | 逐函数检查：无空函数体、无 TODO/FIXME、无 `catch {}` 吞异常（`WSMeta` 的 `catch` 都带日志，宏的 `catch` 是为了补栈后重抛）；`SmokeWsEndpoint`/`MacroSmokeWsEndpoint` 是空类，但那是"空 meta 端点"的设计用例，非功能空实现 |
| §4 栈溢出 | 0 | `parseValue` 无递归；`Controller.generate` 的递归仅沿 `MacroExpandDecl` 单链推进（`Controller.cj:67-68`、`WSEndPoint.cj:46-48`），深度=用户嵌套宏层数，不可由运行期输入放大 |
| §5 OOM | 0 | 本部分唯一按长度分配的是 `parseValue` 的 `split(',')`/`Array(n)`，规模受请求头与 body 上限（`MVCConfig.maxRequestHeaderSize/maxRequestBodySize`，`MVCStarter.cj:48-53`）约束；无全局容器、无按报文头预分配的循环 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据，`parseValue` 只写成「待验证假设 #1」，未作为发现 |
| §6.2 大粒度锁 | 0 | 本部分文件不含锁；宏在编译期执行；`WebSocketRouting_test` 的 server 起停是单线程 |
| §6.3 并发串行热点 | 0 | `spawn { server.serve() }` 后不 `get()`（服务端常驻，本就不是并行任务）；无循环内逐项 `get()` |
| §6.4 低效算法 | 0 | `parseValue` 的 match 为常数级分支（≤60，编译后为类型比较链）；`imports`/注解扫描不在请求路径 |
| §7 降堆内存方案 | 0 | 无分配量基线，见「优化可行性方案」说明 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 临时对象只有 `split` 出来的 `Array<String>` 与 `Any` 装箱，均从函数返回（经 `Option`/`Any` 逃逸），不满足 local region 的逃逸约束；无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 4 | `/health` 415、`@OnWS*` 参数校验矛盾、`metaHandles` 无校验索引、`parseValue` 静默 `None`；均给了行号与调用链，来源全部为存量（快照模式，`git status` 无源码 diff） |
| §12 并发安全与锁粒度 | 0 | `MVCHealthController` 无状态；宏为编译期；`WebSocketRouting_test` 的全局注册走 `MultiRequestMethodHandler` 的 `Mutex`（`MultiRequestMethodHandler.cj:38-57`），且单测试线程执行。未发现共享可变状态的新路径 |
| §14 功能完备性与 README 覆盖 | 2 | `@OnWS*` 处理器按文档写法不可用（功能不可用）；README 缺 `/health` 路径与响应结构。`@WeavedController` 已文档化（`README.md:114`），`WSPing` 在注解表内（`:1203`） |
| 文件覆盖（§13 等） | 14/14 | 本部分 14 个文件全部读完；模块其余 45 个文件由 part1~3 覆盖，未在本部分展开 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 18 条（本部分全部为存量，快照模式无基线可比），是否纳入修复待用户决定。

## 总评

本部分代码量不大（912 行），但两个"看起来能用、实际不能用"的问题都集中在这里：

1. **健康检查端点是坏的**（严重）。`consumes: 'application/x-www-form-urlencoded'` 让普通 `GET /health` 返回 415，而这条路由从 2026-08 起就存在、2026-11 还专门改过 `produces`，说明该端点从未被"不带 Content-Type"地验证过。这一条建议作为 f_mvc 的阻塞项优先修，并补一条路由级单测。
2. **WebSocket 处理器路径整条未被使用过**。全仓 `@OnWS*` 命中 0 次；宏按类型注入 `WebSocket`/`HttpContext` 参数，而 `WSMeta.generate` 要求每个参数都带映射注解，两者直接矛盾——照 README 写就会在启动期抛 `WSException`。再加上 `metaHandles[m.name]` 的无校验索引，这条路径目前只能算"编译得过、跑不起来、没人跑过"。

宏实现本身（`Controller` 的注册/鉴权/访问日志接线）与 `RequestMeta` 的契约是对得上的，`WSPing` 的 `duration` 也确实被 `WSMeta` 读到并用于 `Timer.repeat`，不存在"注解空转"。`parseValue` 是老代码里问题最集中的一处：解析失败一律折成 `None`，导致非法值被报成"缺参"并返回 500，同时 21 行 `??X` 分支永远不可能命中。

其余为可维护性问题：`imports.cj` 的 9 处死导入、宏的标识符卫生、7 段/20 段复制粘贴、README 与注释的表述漂移。都不影响现有功能，可以排期处理。
