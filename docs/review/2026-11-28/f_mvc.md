# f_mvc 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（68 个文件：59 个 .cj + 9 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_mvc.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [严重] 拆分鉴权接口时权限检查被 session 分支锁死：只注册 `PrivilegeHandler`、或单 bean 兼任两个子接口时权限检查静默失效

- **位置**：`f_mvc/src/AuthHandler.cj:121-135`（`check` 的 else-if 链，权限检查只出现在 128 行这一层嵌套里）、`f_mvc/src/AuthHandler.cj:101-115`（初始化循环用 if/else-if，一个 bean 只能占一个槽）；影响面 `f_mvc/src/RequestMeta.cj:248-252`（每请求调用 `AuthHandlerProxy.instance.check`）
- **来源**：存量（快照模式无基线；`git log -S "noHandlers"` → `5f29e1c96`「修复认证处理器代理的初始化逻辑」，具体逻辑行被 `4be871f2f` 换行提交覆盖 blame）
- **判据**：review-checklist §11「契约与实现不符 / 错误处理静默」、§10 安全性（越权）；承诺源：`docs/speech/speech.md:2881-2893` 把算法写成 5 步，其中「4. `!ignorePrivilege` 且 `PrivilegeHandler` 存在 → 用它检查权限」是与第 3 步并列的一步
- **证据**：静态确定 —— 两条路径进不到 128 行：
  1. 只注册 `PrivilegeHandler`（没有 `UserSessionHandler`）：`sessionHandler` 为 `None`，125 行的 `let Some(h) <- sessionHandler` 失败 ⇒ 直接落到 133 行 `AuthStatus.OK`，128-129 行的权限检查一次也不会执行；
  2. 单个 bean 同时实现 `UserSessionHandler` 与 `PrivilegeHandler`：101-108 行的 if/else-if 链第一次迭代只会把它写进 `sessionHandler`（第一分支命中后不再走 `else if`），113 行 `sessionHandler.isSome() && privilegeHandler.isSome()` 因后者仍为 `None` 不 break，循环也没有第二个 bean ⇒ `privilegeHandler` 永远为 `None`，128 行失败 ⇒ `OK`。README:158 恰恰建议「登录状态与权限都要检查时，最好在同一个类里一次做完」，按拆分接口理解就是「一个类实现两个子接口」，正好命中
- **描述**：`docs/speech/speech.md:2881-2893` 把「登录检查」与「权限检查」列为两个独立步骤，代码却把第 4 步嵌进第 3 步的成功分支，于是「权限检查器的存在」被「登录检查器的存在」绑架：只配权限检查器（例如会话由网关负责、应用只做 RBAC）时整个鉴权退化为 `OK`；一个类同时实现两个子接口时权限部分被完全丢弃。两条路径都返回 200 级别的 `AuthStatus.OK`，没有 warn 日志，也不会在启动期报错，属于典型 fail-open。另外 `@IgnoreAuth` 在拆分接口模式下也会连带跳过权限检查（125 行首项 `!param.ignoreAuth` 为 false ⇒ 133 行 `OK`），这与 README:146「`@IgnoreAuth` 忽略登录状态检查」的字面承诺不一致——不过「无登录身份就无法判权限」也有其合理性，这一条列为**待确认**（需产品/文档明确），不计入本条缺陷的成立依据。仓内唯一实现 `fdemo/user/src/util/auth/AuthCheckerImpl.cj:26` 用的是直接接口 `AuthHandler`，上述两条路径没有任何测试或 demo 覆盖
- **建议**：把权限检查从 session 分支里提出来，写成顺序三段：`if (!ignoreAuth && let Some(h) <- sessionHandler) { let s = h.check(param); if (!s.isOK) { return s } }` → `if (!ignorePrivilege && let Some(h) <- privilegeHandler) { return h.check(param) }` → `AuthStatus.OK`；初始化循环改成「按接口独立判断、互不 else」，让同一个 bean 能同时填两个槽（`if (let sh: UserSessionHandler <- h) { sessionHandler = sh }` / `if (let ph: PrivilegeHandler <- h) { privilegeHandler = ph }`）；「只注册了 `PrivilegeHandler` 却没有 session 实现」在启动期打 warn（或按 fail-closed 直接失败），并把 README 的「最好在一个类里实现」改成明确指向 `AuthHandler` 直接接口

### [严重] `AcceptQueue` 把 `;q=` 参数与空白留在媒体类型里：带 q 值的合法 `Accept` 被判定为不匹配（406），选出的值还会被当成 `Content-Type`

- **位置**：`f_mvc/src/AcceptQueue.cj:37-50`（`let e` 是 q 值的结束位置，48 行却用它切媒体类型 `let submt = mt[0..e]`）；影响面 `f_mvc/src/RequestMeta.cj:171-190`（`checkProduces`）、`f_mvc/src/RequestMeta.cj:270` / `:343` / `:374`（`first()` 的返回值直接当 `Content-Type`）、`f_mvc/src/MultiRequestMethodHandler.cj:167-173`
- **来源**：存量（`git log -S "submt"` → `0447371e8`「改进 Accept 头部处理逻辑以支持多类型匹配」）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§2「字面量复制（同一张媒体类型表被两处按不同口径比较）」
- **证据**：静态确定 —— `mt = "application/json;q=0.9"` 时 `idx = 16`（`;q=` 起点）、`qi = 19`、`e = 23`（`mt.size`），于是 `submt = mt[0..23]` 仍是整串 `application/json;q=0.9`；注释与日志名（`addAccept`）表明这里要的是「媒体类型」，正确的切点应是 `idx`（无 q 时 `mt.size`）。下游比较全是精确匹配：`produces` 是 `HashSet<String>`（`RequestMeta.cj:68`），`checkProduces` 用 `produces.contains(accept)`，`startsWith('*/*')` 也不成立 ⇒ 该条永不命中。同一根因还有两个变体：`lastIndexOf(';q=')` 只认「小写、无空白」，`;Q=0.9` 或 `; q=0.9` 会把整个参数当媒体类型；`submt` 没有 trim，`"text/html, application/json"` 这种逗号后带空格的写法第二条也匹配不上
- **描述**：只要客户端在 `Accept` 里带权重，协商就失效：单值 `Accept: application/json;q=0.9`（`indexOf(',')` 为 None）直接让 `checkProduces` 返回 false，请求被判不匹配（406/405 路径）；多值时第一条带 q 的类型被跳过，`*/*;q=0.8` 靠 `startsWith('*/*')` 侥幸命中，其它真实类型被丢弃。更隐蔽的是「命中后」的值也被污染：`checkProduces` 把选中的 `c` 写回 `Accept`（`RequestMeta.cj:180`），`first()` 的返回值又被直接当 `Content-Type` 用（`RequestMeta.cj:270`、`:343`、`:374`），响应头会出现 `Content-Type: application/json;q=0.9`——把请求侧的权重参数带进响应侧。触发面很宽：浏览器与常见 SDK 都会发送带 q 的条目（Chrome/Firefox 的 `application/xml;q=0.9,*/*;q=0.8`、`curl -H 'Accept: application/json;q=0.9'`），浏览器首条 `text/html` 恰好无 q 所以首页不受影响，凡是 controller 声明的类型只出现在带 q 的条目里就必然失败
- **建议**：`init` 里只保留 `mt[0..idx]`（q 分支）或 `mt`（无 q 分支），并 `trimAscii()`、用 `toAsciiLower()` 后再比较 `;q=`；`submt` 只存媒体类型，q 只进排序键。补 5 条单测：`a/b;q=0.9`、`a/b, c/d`（带空格）、`a/b;Q=0.9`、`a/b;q=0.9;charset=utf-8`、多值按 q 降序

### [严重] `AuthHandlerProxy` 的延迟初始化对无锁读者不建立 happens-before（普通 `var` 跨线程发布，可能 fail-open）

- **位置**：`f_mvc/src/AuthHandler.cj:92-120`（`mutex` / `noHandlers` / `authHandler` / `sessionHandler` / `privilegeHandler` 都是普通字段；98 行在锁外读 `noHandlers`，117 行在锁内写）
- **来源**：存量（`git log -S "noHandlers"` → `5f29e1c96`「修复认证处理器代理的初始化逻辑」，该提交把锁内 `authHandler.isNone()` 换成锁外可见的 `noHandlers` 标记）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 惰性初始化 / 可见性」「发布逸出」、§11「并发正确性」
- **证据**：静态确定（缺同步这一事实）；实际是否读到陈旧值取决于平台内存模型，需实测才能给出发生率 —— 写侧在 `synchronized(mutex)` 内完成 5 个字段赋值后置 `noHandlers = false`；读侧（98 行）直接读 `noHandlers`，随后（123-133 行）直接读三个 handler 字段，全程不取 `mutex`，因此读写之间没有 acquire/release 配对的 happens-before 边
- **描述**：`AuthHandlerProxy.instance` 是进程级单例，`check` 由所有请求线程并发调用（`RequestMeta.checkAuth` 每请求一次）。在弱内存序平台（ARM，含鸿蒙 PC / 服务器）上，请求线程可能看到 `noHandlers == false` 却仍读到 `authHandler/sessionHandler == None`，于是 135 行返回 `AuthStatus.OK` —— 鉴权被跳过（fail-open），且没有任何日志。反向也可能读到「只有一个 handler 已发布」的中间态，导致只做登录检查不做权限检查（与上一条叠加）。x86 TSO 下 store 顺序保证使该窗口极小，因此不把它定为「必现」，但代码层面的同步缺失是确定的
- **建议**：把「解析结果」做成不可变快照对象（`class Handlers { let auth: ?AuthHandler; let session: ...; let privilege: ... }`）用一个 `AtomicReference<Handlers>`（初值「未解析」）发布，读侧一次 `load()` + 判空即可，既不持锁也没有可见性问题；或在 `MVCInitializer.initialize()`（启动期、单线程）里解析完，运行期只读 `let`。若坚持懒加载，读侧首次也要进 `synchronized` 取本地快照后再用

### [一般] 多个 `AuthHandler` 实现并存时「先注册先赢」，无告警也不启动失败（fountain-baseline §4 违规）

- **位置**：`f_mvc/src/AuthHandler.cj:101-115`（`break` 于第一个命中的直接实现）、`f_mvc/src/AuthHandler.cj:90`（`static let instance`）
- **来源**：存量
- **判据**：fountain-baseline §4「同名注册：启动直接失败，不做隐式优先级；后者静默覆盖前者或『先注册先赢』」；review-checklist §14.1「接线缺失 / 只做一半的分支」
- **证据**：静态确定 —— 循环里 `authHandler.isSome()` 即 `break`，`lookupList<AuthHandler>()` 的返回顺序就是 bean 注册顺序；后续实现既不比较也不记录
- **描述**：README:185 只说「存在直接实现 `AuthHandler` 的实现类时只用它」，没有定义多个直接实现时选谁。实际行为退化为「bean 列表第一个」，取决于 `@Bean` 扫描顺序；如果应用里同时存在旧的会话检查器与新的统一检查器，最终生效的是哪一个不可预期，且没有 warn 日志。该行为在教程 `docs/fountain实现思想与应用/fountain实现思想与应用第06弹——MVC.md:80` 里被当作既定语义写了出来（「按照从IOC的返回顺序决定哪个生效」），但模块 README 没有写，且与 fountain-baseline §4 的「同名注册启动直接失败」相反
- **建议**：初始化时收集所有候选，直接实现 > 1 个时 `throw MVCException('multiple AuthHandler implementations: ...')`（启动即失败，符合 baseline §4）；只允许一个 `UserSessionHandler` 与一个 `PrivilegeHandler`，重复同样启动失败

### [一般] `AcceptQueue` 对畸形 q 值无兜底：`Float64.parse` 抛 `IllegalArgumentException`，请求在路由阶段变 500

- **位置**：`f_mvc/src/AcceptQueue.cj:43`（`-Float64.parse(mt[qi..e])`）
- **来源**：存量（`0447371e8`）
- **判据**：review-checklist §11「错误处理缺失 / 外部输入未校验」、§10 安全性（不可信输入）
- **证据**：静态确定（抛异常这一点有文档依据）—— `std.convert` 的 `Float64.parse(String)` 契约写明「字符串不符合浮点数语法时抛 `IllegalArgumentException`」（本地文档 `std/convert/convert_package_api/convert_package_interfaces.md:1098-1116`）；`checkProduces` 的调用方 `MultiRequestMethodHandler.handle` 没有 `try`（`MultiRequestMethodHandler.cj:66`），异常只能落到 HTTP 层兜底（最终状态码待确认，通常 500 或直接断连）
- **描述**：`Accept: application/json;q=abc`、`;q=`（空值）、`;q=0.9e` 这类客户端拼写错误会让服务端抛异常，而不是按「该条 q 无效、按 0 处理或忽略该条」的 RFC 7231 语义降级。攻击者可以低成本构造该请求反复触发 500 与错误日志
- **建议**：改用 `Float64.tryParse`，失败按 `q = 0`（或忽略该媒体范围）处理并 `log.debug` 记录原文；同时把 q 钳制到 `[0, 1]`

### [一般] `@RequestHeader` 缺失时把 `''` 交给 `Validator`，与 `@RequestParam` / `@PathVariable` 传 `None` 的口径不一致，「必填」类校验可能被绕过

- **位置**：`f_mvc/src/ControllerFuncParam.cj:150-165`（`let v = if (value.isEmpty()) { '' } else { concat(value) }`，159 行 `validate<T>(n, v, validator)`）；对照 `:83-84`（`@RequestParam` 传 `?String`）、`:125-129`（`@PathVariable` 传 `?String`）
- **来源**：存量
- **判据**：review-checklist §11「语义与实现不符」、§2「近似重复导致行为漂移」；`Validator.validate(value: ?String)` 的契约（`f_data/src/base/Validator.cj:23`）本身区分「无值」与「空串」
- **证据**：静态确定（口径不一致本身）；是否真的放过某个校验器取决于具体 `Validator` 实现 —— 待确认
- **描述**：`@RequestParam` / `@PathVariable` 缺值时给校验器 `None`，`@RequestHeader` 缺值时给 `Some("")`。任何以 `value.isNone()` 判「必填」的校验器（下游项目自定义，如 `f_util.IsUUID` 这类）对缺失的请求头会收到 `Some("")` 并放行，随后 `extract` 又返回 `None<T>`，控制器拿到的是 `None`（`getOrThrow` 处变成 500）。同一语义三个类三种口径，也解释了为什么 README 无法用一句话描述校验规则
- **建议**：先算 `let v: ?String = if (value.isEmpty() && default.isNone()) { None<String> } else { concat(value) }`，再 `validate<T>(n, v, validator)`，即「缺值就传 `None`」；或统一给 `ControllerFuncParam` 一个 `validatePresence(name, ?String, validator)` 入口，三个子类共用

### [一般] README 未文档化 5 个参数绑定注解（`@RequestParam` / `@PathVariable` / `@RequestHeader` / `@RequestBody` / `@RequestParamObject`）的用法与默认值语义

- **位置**：`f_mvc/README.md`（全文只在 `:1325` 的「其他公开 API」清单里出现这 5 个类名）；对照实现 `f_mvc/src/ControllerFuncParam.cj:70-177`
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化 / 缺关键段落」；承诺源：README:112-113 只说参数类型限制与「按参数名从请求里提取参数」，`:1323-1325` 声明「完整语义见 `src/`」
- **证据**：静态确定 —— `grep -n "@RequestParam\|@PathVariable\|@RequestHeader\|@RequestBody\|RequestParamObject" f_mvc/README.md` 只命中 1325 行那一行；README_en.md:1340 同
- **描述**：这 5 个注解是写 controller 的必备 API（`RequestMeta.generate` 强制「每个参数必须有且只有一个」此类注解，`RequestMeta.cj:534-539`），但 README 没有一节说明：`name` 属性可覆盖参数名、`default` 只对 `@RequestParam`/`@PathVariable`/`@RequestHeader` 生效且是「字符串」而非类型值、`@RequestHeader` 的默认值会按 `,` 拆开、`@RequestBody` 依赖 `Content-Type` 且缺失/未注册直接 415（`ControllerFuncParam.cj:179-195` 的 `MVC-C3` 行为完全没进 README）、`@RequestParamObject` 会用反射按字段名逐个从 form/query 取值。使用者只能读源码
- **建议**：在「controller函数注解」后新增「参数绑定注解」小节：一张表（注解 / 取值来源 / `name` / `default` / 校验与转换 / 缺失时的返回值），并补 `@RequestBody` 的 415 约定与 `@RequestParamObject` 的字段来源；`README_en.md` 同步

### [轻微] `DownloadMeta.cj` 是空文件（只有版权头 + `package`），无任何声明

- **位置**：`f_mvc/src/DownloadMeta.cj:1-17`
- **来源**：存量（`git log -- f_mvc/src/DownloadMeta.cj` → `4592ae049`「添加FileDownloadMeta支持多文件下载」，类型已迁走，文件留下）
- **判据**：review-checklist §1「兼容残留」
- **证据**：静态确定 —— 文件 17 行，`package` 之后没有任何声明；全仓 `grep -rn "DownloadMeta"` 只命中 `FileDownloadMeta` 与 bug 记录，没有 `DownloadMeta` 这个类型
- **描述**：空编译单元会被打进包但不产生符号，属历史残留；`cjpm` 每次都白解析一遍，也给读者「这里应该有个类型」的误导
- **建议**：删除该文件（`FileDownloadMeta` 已在 `FileDownload.cj` 中）

### [轻微] `CurrentHttpContext.scoped` 结束时只清空、不恢复上一个值，同线程嵌套调用会抹掉外层上下文

- **位置**：`f_mvc/src/CurrentHttpContext.cj:37-47`（`finally { context.set(None<HttpContext>) }`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符（文档只承诺给子线程用）」
- **证据**：静态确定 —— 进入时 `match (ctx) { case Some(h) => context.set(h) ... }` 覆盖旧值，退出时无条件 `set(None)`；没有保存/回填旧值
- **描述**：当前唯一调用点在 `f_jsonrpc/src/server/JsonRpcServer.cj:287` 的 `spawn { ... }` 子线程里，该线程用完即弃，所以现在没有实际影响。但它是 `public` API（README:1338 列出），使用者若在请求线程里嵌套 `scoped(Some(ctx)) { ... }`，`body` 返回后本请求后续代码再取 `CurrentHttpContext.instance` 会抛 `NoneValueException`；`scoped(None, body)` 与「只清理」的注释一致，但同样会清掉别人的上下文
- **建议**：进入前 `let prev = context.get()`，`finally` 回填 `match (prev) { case Some(h) => context.set(h); case _ => context.set(None) }`；README 补一句「按作用域栈语义恢复」

### [轻微] `ControllerFuncParam.concat` 用「累计长度 > 0」判断分隔符，前导空值会被丢掉

- **位置**：`f_mvc/src/ControllerFuncParam.cj:22-31`（`if (b.size > 0) { b.append(',') }`）
- **来源**：存量
- **判据**：review-checklist §11「边界差一」、§2（同一个「拼多值」逻辑被当作解析前置步骤，隐含假设第一个元素非空）
- **证据**：静态确定 —— `StringGenerator.size` 是已写入的字节数（`f_base/src/StringGenerator.cj:34-38`）；`["", "b"]` 时第一个元素不增加长度，第二个元素前不加 `,`，结果是 `"b"`；下游 `parseValue` 对 `?Array<String>` 按 `,` 切（`f_mvc/src/global_func.cj:69`）得到 1 个元素而不是 2 个
- **描述**：`?a=&a=b` 这类「首项为空」的表单/查询串会把数组参数少给一个元素，且无法从结果看出是被吞掉的。中间与尾部的空值不受影响（`"a,,b"`、`"a,"` 都能切出空串）
- **建议**：用显式 `var first = true` 控制分隔符（`if (!first) { b.append(',') }; b.append(v); first = false`），不要用「输出是否为空」推断「是不是第一个元素」

### [轻微] `validate` 的默认错误消息把原始参数值按 `Option` 文本拼进去（`Some(x)`），既外泄输入也不易读

- **位置**：`f_mvc/src/ControllerFuncParam.cj:34-39`（`'Invalid request data ${name}:${value} and its type is ${TypeInfo.of<T>()}'`）
- **来源**：存量
- **判据**：review-checklist §10 安全性（敏感数据进响应/日志）、§10 可读性
- **证据**：静态确定 —— `value: ?String` 直接插值，`Option` 的 `toString` 会打印 `Some(明文)`/`None`
- **描述**：校验失败的消息会带上参数原名与原值（密码、token、身份证号等参数同样会进来），并以 `Some(...)` 形式呈现；异常最终进响应体或日志时既不专业也可能构成信息泄露
- **建议**：消息里只留参数名与类型（`'Invalid request parameter: ${name}, type ${TypeInfo.of<T>()}'`），需要定位时把值以 `debug` 级别单独记录并按参数配置脱敏

### [轻微] 注释与命名漂移：`AuthStatus` 上方挂的是「响应体类型」说明，`noHandlers` 的语义是「尚未初始化」

- **位置**：`f_mvc/src/AuthHandler.cj:18-28`（注释讲的是 `Any` 响应体如何被 `RequestMeta` 处理）、`f_mvc/src/AuthHandler.cj:93` + `:98-117`（`noHandlers`）；对照实现 `f_mvc/src/RequestMeta.cj:285-296`（`match (resp)` 的五个类型分支）
- **来源**：存量
- **判据**：review-checklist §10 可读性 / §11「语义与命名不符」
- **证据**：静态确定 —— 注释所述「String/ToString/InputStream/Array<Byte>/ToData 转换」实现在 `RequestMeta.checkAuth`（`RequestMeta.cj:285-296`），与 `AuthStatus` 定义无关；`noHandlers` 为 `true` 表示「还没解析过 bean」，为 `false` 表示「已解析」
- **描述**：新人读 `AuthStatus` 会以为枚举自己负责序列化；`if (noHandlers)` 字面像「没有任何 handler」，实际是「未初始化」，容易在读 `check` 时把 98 行理解反
- **建议**：把 18-28 行注释搬到 `RequestMeta.checkAuth` 的响应体分支上，`AuthStatus` 只留枚举语义；`noHandlers` 改名 `handlersResolved`（或 `initialized`，语义取反）

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 不是缺陷，是「还能更好」。两条都无改前基线，只作下一轮补数据的候选，不进修复清单。

### [CPU] `AcceptQueue` 用优先队列只为取一个最大值；同一请求还会重复构造 2-3 次

- **现状**：`first()`（`f_mvc/src/AcceptQueue.cj:64-66`）只取优先级最高的一个媒体类型，但 `init` 会为 n 个媒体范围各分配 1 个 `(Float64, Int64, String)` 元组并把子串插入 `PriorityQueue`（O(n log n) + n 次堆调整）；同一请求里 `AcceptQueue` 最多被构造 3 次（`RequestMeta.cj:176` 的 `checkProduces`、`:270` 的 `checkAuth` 失败响应、`:374` 的 `respond(JsonValue)`，外加 `MultiRequestMethodHandler.cj:168` 的错误响应路径）；n = `Accept` 中的媒体范围个数，浏览器与常见 SDK 为 1-8
- **方案**：①`first()` 改成单趟扫描 `var bestQ / bestIdx / bestType`；②把「解析结果」提升到请求级（`checkProduces` 已经把选中的类型写回 `ctx.request.headers.set('Accept', c)`，可顺手存进一个请求级 `ThreadLocal`，与 `RequestMeta.currentResponseStatus` 共用 `finishRequest()` 这一清理点），后续 `respond` 直接读，不再重建
- **预期**：每次构造省 1 个 `PriorityQueue` + n 个元组 + n 个子串，O(n log n) → O(n)；n 很小时绝对收益有限，主要收益在分配量与 GC 压力
- **代价**：需要保留「q 相同按出现顺序」的 tie-break 语义；请求级缓存要跟着 `finishRequest()` 清理，否则会串到同线程的下一个请求（`RequestMeta.cj:667`）
- **验证**：`cjpm bench -O2` 写一个 `Accept` 解析微基准（n = 1/3/8，1e6 次），另加端到端压测看 P99 与分配量；`getAllocatedHeapSize()` 前后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 请求级媒体类型选择结果的短生命周期副本

- **现状**：每次 `AcceptQueue(accept)` 都为每个媒体范围生成一个新 `String` 子串（`mt[0..e]`）并保存在元组里，随 `PriorityQueue` 一起在 `first()` 返回后变成垃圾；一个请求 3 次构造即 3n 个短命 `String` + 3 个 `ArrayList`/`Array` 底层（`PriorityQueue.queue` 初值 16 个 `Option<T>`）
- **方案**：单趟扫描时只保留「当前最优」的一个下标（`Int64`），返回时再切一次 `String`；或让 `first()` 直接返回选中范围的下标，由调用方按需切
- **预期**：每请求少 n-1 个子串与 1 个 `PriorityQueue`（16 槽数组）；绝对量级在 KB 以下，收益需按 QPS 累计评估
- **代价**：`first()` 的返回类型若改成下标，调用点（4 处）都要改；语义不变
- **验证**：`-O2` 下 10 分钟稳态负载，`getAllocatedHeapSize()` 增量与 Young GC 次数对照
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

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

<!-- 第 1 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `AcceptQueue` 的构造 + 堆操作在路由主路径上的自耗时占比（n=5 时） | `f_mvc/src/AcceptQueue.cj:27-60` | 自耗时占比、每请求分配字节数 | `cjprof record` 跑 `Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` 的 GET 压测（10k req/s，60s） |
| 2 | 同一请求重复解析 `Accept`（`checkProduces` + `respond` + 错误路径）的比例 | `f_mvc/src/RequestMeta.cj:176,270,374` | 每请求 `AcceptQueue` 构造次数分布 | 在 `AcceptQueue.init` 加计数器埋点，跑 10 分钟稳态负载后看直方图 |
| 3 | `@RequestParamObject` 每请求的反射开销（`getStaticFunction('dataFields')` + `apply` + 逐字段 `mutableFields`） | `f_mvc/src/ControllerFuncParam.cj:96-108` | 单次 extract 耗时、在请求总耗时中的占比 | 5 字段对象的 controller，`cjprof` 压测 10k 请求 |
| 4 | `AuthHandlerProxy` 首次请求的 `lookupList` 在锁内的等待（冷启动 P99） | `f_mvc/src/AuthHandler.cj:99-119` | 首请求锁等待时长、并发首请求数 | 分段计时埋点（`synchronized` 前后 `MonoTime`），冷启动并发 50 请求 |

<!-- 第 2 部分 -->

> 无测试数据，仅作下一轮取数清单；不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 下载 `spawn` 的线程数随并发下载线性增长，慢客户端下线程/RSS 双涨 | `f_mvc/src/FileDownload.cj:77` | 并发下载数 → 线程数与 RSS 的曲线 | 压测：50/200/1000 个并发下载 + 客户端限速，采 `Thread` 计数、RSS、`getAllocatedHeapSize()` |
| 2 | 单文件下载在 chunked（`length < 0`）下会被提前截断 | `f_mvc/src/FileDownload.cj:55-61` + `f_io/src/ByteBuffer.cj:230-250` | stdx 响应写出侧对 `read()==0` 的解释 | 起真服务 + 慢生产者（每块 sleep），比对下载字节数与源长度；同时抓 stdx 写出循环的读次数 |
| 3 | `exec` 里 `start()/build()` 晚于 handler 返回，存在「响应已发送、body 未设置」窗口 | `f_mvc/src/FileDownload.cj:75-93` | stdx 发送时机（handler 返回即发 or 显式 build 才发） | 在 `start()` 前后与 handler 返回处打时间戳，跑 1k 次单文件下载，统计「空响应 / 缺 body」次数 |
| 4 | 路由热路径的 `toAsciiUpper` + 切片在整请求耗时中占比 < 5% | `f_mvc/src/MultiRequestMethodHandler.cj:64-80` | 自耗时占比（需工具） | `cjprof record` 跑静态资源/JSON 混合负载 10 分钟，看 `RequestMethod.parse` 与 `HashMap.get` 的自耗时 |
| 5 | `MVCConfig` 每次 `tlsConfig`/`downloadBufferSize` 访问都读配置 + 读文件，若被请求期调用会成为 I/O 热点 | `f_mvc/src/MVCConfig.cj:77-118,257-261` | 调用频次与单次耗时 | 在 getter 内埋计数与分段计时，跑稳态负载看每秒调用次数（`tlsConfig` 预期仅启动期 1 次） |

<!-- 第 3 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求多次解析 `Accept`（`checkProduces` + `respond` 各 1–2 次 `AcceptQueue`，`AcceptQueue.remove()` 每次重排）占请求处理 CPU 的可观比例 | `f_mvc/src/RequestMeta.cj:171-191,268-273,342-346,372-377` | `AcceptQueue` 构造/`remove` 的自耗时占比、每请求调用次数 | `cjprof record` 跑 10k 个带 `Accept: a/b, c/d;q=0.8` 的请求，看 `AcceptQueue.*` 自耗时是否 >5%；同时加计数确认每请求次数 |
| 2 | 静态资源整文件常驻让 RSS 不随请求结束回落（#9 的内存面） | `f_mvc/src/RequestMeta.cj:46,108-136` | 请求前后 `getUsedHeapSize()` / RSS 差值、缓存条目数与总字节 | 分别对 1 MB / 100 MB 文件各请求 1 次，记录 `getAllocatedHeapSize()`、RSS、`staticResourceBytes.size`；再跑 1000 次小文件请求看是否线性增长 |
| 3 | WS 单条大消息的 `ArrayList` 扩容 + `unsafeData()` 物化是消息处理的主要分配来源 | `f_mvc/src/WSMeta.cj:219-245,277-279` | 每帧分配字节数、`unsafeData()` 是否复制、GC 次数 | 用 1 MB 文本帧压测 1e4 条，`cjprof heap` 看 `ArrayList`/`Array<Byte>` 分配量与 GC 次数；对照预分配版本 |
| 4 | `FileDownload` 写入管道时还会二次复制，导致 `copy` 的切片复制在端到端上不可见 | `f_mvc/src/ResponseDownload.cj:71-76` + `f_mvc/src/FileDownload.cj:142-146`（`pipe.write`） | `SyncByteBuffer.write` 的单次拷贝字节数与自耗时 | 对 1 GB 下载做 `cjprof`，比较 `copy` / `Array.slice` / `SyncByteBuffer.write` 三者自耗时占比 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `accessLog` 的 `anyArgs` 每请求分配在小包体接口上占比可观（尤其日志级别关闭时） | `f_mvc/src/macros/Controller.cj:85,145` | 分配量与自耗时占比 | `cjprof record` 跑 2 参数接口 10k 请求，对比注释掉 `anyArgs.add` 前后的 `getAllocatedHeapSize()` 与 GC 次数 |
| 2 | `parseValue` 的类型分派在「10 个以上参数」的接口上成为绑定阶段热点 | `f_mvc/src/global_func.cj:24-149` | 自耗时占比、参数规模阈值 | `cjprof record` 跑 12 参数控制器，输入 10k 请求，看 `parseValue` self time |
| 3 | `HealthData` 的 11 个属性每次请求都调 `std.runtime`（`getAllocatedHeapSize` 等）可能引入停顿，健康探针高频（1s）时放大 | `f_mvc/src/health/MVCHealthMonitor.cj:28` + `f_health/src/HealthData.cj:24-90` | 单次属性读取耗时、是否 STW | 对 `/health` 做 100 QPS × 10 分钟压测，量 P99 与 GC 停顿；或直接对 `getAllocatedHeapSize()` 做微基准 |

## 文件覆盖

> 与 `files/f_mvc.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/README.md` | .md | ✅ | — |
| 2 | `f_mvc/README_en.md` | .md | ✅ | — |
| 3 | `f_mvc/doc/spec/fix-mvc-streaming-response/design.md` | .md | ✅ | — |
| 4 | `f_mvc/doc/spec/fix-mvc-streaming-response/proposal.md` | .md | ✅ | — |
| 5 | `f_mvc/doc/spec/fix-mvc-streaming-response/specs/mvc-response/spec.md` | .md | ✅ | — |
| 6 | `f_mvc/doc/spec/fix-mvc-streaming-response/tasks.md` | .md | ✅ | — |
| 7 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/design.md` | .md | ✅ | — |
| 8 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/proposal.md` | .md | ✅ | — |
| 9 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/tasks.md` | .md | ✅ | — |
| 10 | `f_mvc/src/AcceptQueue.cj` | .cj | ✅ | — |
| 11 | `f_mvc/src/AuthAnnotation.cj` | .cj | ✅ | — |
| 12 | `f_mvc/src/AuthHandler.cj` | .cj | ✅ | — |
| 13 | `f_mvc/src/BreakingCommand.cj` | .cj | ✅ | — |
| 14 | `f_mvc/src/ControllerFuncParam.cj` | .cj | ✅ | — |
| 15 | `f_mvc/src/ControllerFuncParam_test.cj` | .cj | ✅ | — |
| 16 | `f_mvc/src/CurrentHttpContext.cj` | .cj | ✅ | — |
| 17 | `f_mvc/src/DownloadMeta.cj` | .cj | ✅ | — |
| 18 | `f_mvc/src/ErrorHttpRequestHandler.cj` | .cj | ✅ | — |
| 19 | `f_mvc/src/ExtendHttpResponsePusher.cj` | .cj | ✅ | — |
| 20 | `f_mvc/src/FailureMessageKind.cj` | .cj | ✅ | — |
| 21 | `f_mvc/src/FileDownload.cj` | .cj | ✅ | — |
| 22 | `f_mvc/src/FileDownload_test.cj` | .cj | ✅ | — |
| 23 | `f_mvc/src/HttpRequestDistributorImpl.cj` | .cj | ✅ | — |
| 24 | `f_mvc/src/HttpRequestDistributorImpl_test.cj` | .cj | ✅ | — |
| 25 | `f_mvc/src/HttpStatus.cj` | .cj | ✅ | — |
| 26 | `f_mvc/src/MVCConfig.cj` | .cj | ✅ | — |
| 27 | `f_mvc/src/MVCInitializer.cj` | .cj | ✅ | — |
| 28 | `f_mvc/src/MVCStarter.cj` | .cj | ✅ | — |
| 29 | `f_mvc/src/MediaType.cj` | .cj | ✅ | — |
| 30 | `f_mvc/src/MultiRequestMethodHandler.cj` | .cj | ✅ | — |
| 31 | `f_mvc/src/MultiRequestMethodHandler_test.cj` | .cj | ✅ | — |
| 32 | `f_mvc/src/OnWSBinary.cj` | .cj | ✅ | — |
| 33 | `f_mvc/src/OnWSClose.cj` | .cj | ✅ | — |
| 34 | `f_mvc/src/OnWSOpen.cj` | .cj | ✅ | — |
| 35 | `f_mvc/src/OnWSPing.cj` | .cj | ✅ | — |
| 36 | `f_mvc/src/OnWSPong.cj` | .cj | ✅ | — |
| 37 | `f_mvc/src/OnWSText.cj` | .cj | ✅ | — |
| 38 | `f_mvc/src/OverallStopwatch.cj` | .cj | ✅ | — |
| 39 | `f_mvc/src/Redirect.cj` | .cj | ✅ | — |
| 40 | `f_mvc/src/RequestArgMeta.cj` | .cj | ✅ | — |
| 41 | `f_mvc/src/RequestCondition.cj` | .cj | ✅ | — |
| 42 | `f_mvc/src/RequestMapping.cj` | .cj | ✅ | — |
| 43 | `f_mvc/src/RequestMeta.cj` | .cj | ✅ | — |
| 44 | `f_mvc/src/RequestMeta_test.cj` | .cj | ✅ | — |
| 45 | `f_mvc/src/RequestMetas.cj` | .cj | ✅ | — |
| 46 | `f_mvc/src/RequestMethod.cj` | .cj | ✅ | — |
| 47 | `f_mvc/src/RequestMethod_test.cj` | .cj | ✅ | — |
| 48 | `f_mvc/src/ResponseDownload.cj` | .cj | ✅ | — |
| 49 | `f_mvc/src/Series.cj` | .cj | ✅ | — |
| 50 | `f_mvc/src/WSCloseFrame.cj` | .cj | ✅ | — |
| 51 | `f_mvc/src/WSDataFrame.cj` | .cj | ✅ | — |
| 52 | `f_mvc/src/WSEndPointMacro_test.cj` | .cj | ✅ | — |
| 53 | `f_mvc/src/WSMeta.cj` | .cj | ✅ | — |
| 54 | `f_mvc/src/WSMeta_test.cj` | .cj | ✅ | — |
| 55 | `f_mvc/src/WSPing.cj` | .cj | ✅ | — |
| 56 | `f_mvc/src/WebSocketRouting_test.cj` | .cj | ✅ | — |
| 57 | `f_mvc/src/exception/HttpRequestException.cj` | .cj | ✅ | — |
| 58 | `f_mvc/src/exception/HttpResponseException.cj` | .cj | ✅ | — |
| 59 | `f_mvc/src/exception/MVCException.cj` | .cj | ✅ | — |
| 60 | `f_mvc/src/exception/WSException.cj` | .cj | ✅ | — |
| 61 | `f_mvc/src/exception/imports.cj` | .cj | ✅ | — |
| 62 | `f_mvc/src/global_func.cj` | .cj | ✅ | — |
| 63 | `f_mvc/src/health/MVCHealthMonitor.cj` | .cj | ✅ | — |
| 64 | `f_mvc/src/imports.cj` | .cj | ✅ | — |
| 65 | `f_mvc/src/macros/Controller.cj` | .cj | ✅ | — |
| 66 | `f_mvc/src/macros/WSEndPoint.cj` | .cj | ✅ | — |
| 67 | `f_mvc/src/macros/imports.cj` | .cj | ✅ | — |
| 68 | `f_mvc/src/response_download_test.cj` | .cj | ✅ | — |

合计：`.cj` 59 个 / `.md` 9 个 / 共 68 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 3（权限短路、Accept 归一化、RequestHeader 校验口径）、安全性 2（fail-open 竞态、错误消息含原值）、设计 1（多实现先注册先赢）、可读性 2（注释错位/命名、`Option` 文本进消息）；语言特性上 `Option` 注入（`?T` 位置可直接给 `T`，见 `enum_and_pattern_match/option_type.md:31-39`）与「函数体末表达式即返回值、返回类型可推导」（`function/define_functions.md:84-107,181-189`）均已核对，`concat` / `first()` 看似缺 `return` 实为合法写法，未误报 |
| §1 死代码 | 1 | 逐个搜过：`AcceptQueue`（internal struct）5 处外部引用、其 `remove/first/priority/log` 全有调用；`AuthHandlerProxy`（internal）1 处引用、5 个字段全读；`ControllerFuncParam.concat` 2 处、`validate<T>` 3 处、`extractValue` 3 处、`requestBodyMediaType` 2 处；`CurrentHttpContext.set` 2 处、`clear` 1 处；`AbstractRequestParam` 2 个子类；`protected` 声明中 `extract`/`validate`/`init` 均有实现或调用（且 `extract` 经 `RequestArgMeta.cj:22` 动态分派），不判死代码；`RequestParam`/`PathVariable`/`RequestHeader`/`RequestBody`/`RequestParamObject`/`AuthStatus`/`MVCBreakingCommand` 等均为对外可达 `public` 或注解，按硬原则一不判。唯一命中：`DownloadMeta.cj` 空文件（兼容残留） |
| §2 重复逻辑 | 1 | 同文件内把 `RequestParam.extract` / `PathVariable.extract` / `RequestHeader.extract` 压成「解析 name → 取值 → validate → parseValue」摘要比对：三步骨架相同（差异只在取值来源与 default 处理），且已发生漂移（`RequestHeader` 传 `''`）——合并为 1 条「一般」+1 条「轻微」；`MVCBreakingCommand` 4 个构造器是转发而非重复；`FailureMessageKind.parse/tryParse` 与 `RequestMethod.parse/tryParse` 是项目统一惯例，不计；跨文件搜过相同错误文案（`'Invalid request data'`、`'unsupported FailureMessageKind'`）各只 1 处 |
| §3 空实现 | 0 | `DownloadMeta.cj` 是「空文件」而不是「承诺了行为却空实现」，已计入 §1，不重复计分；`ControllerFuncParam_test.cj:38-40` 的 `catch (_: Exception) {}` 是「修前形态哨兵」且有注释说明，不算静默吞异常；`DummyValidator`、各 `init(){}`、`ErrorHttpRequestHandler` 都是接口/注解契约或有意 no-op，无「主路径上的空分支」 |
| §4 栈溢出 | 0 | 本部分无递归：`AcceptQueue.init` 是一层 `while`，`first`/`remove` 单层调用，`AuthHandlerProxy.check` 无自调用，`CurrentHttpContext.scoped` 只调一次 `body()`（由调用方决定是否递归，非本文件职责）；无深度遍历用户结构 |
| §5 OOM | 0 | `AcceptQueue.priority` 条目数受 `Accept` 头长度约束（`mvc_maxRequestHeaderSize`，`MVCConfig` 配置项），无「按报文字段预分配」；`StringGenerator` 按实际字节增长；`AuthHandlerProxy` 只在启动后解析一次 bean 列表，不随请求增长 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，4 处疑似热点（Accept 解析、反射式 `@RequestParamObject`、`lookupList` 冷启动、重复解析）全部只能进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分唯一锁是 `AuthHandlerProxy.mutex`，临界区只在首次请求执行一次 `lookupList` + 赋值，不在稳态主路径；无锁内 I/O/序列化 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池调用；路由与参数绑定均为请求线程内同步执行 |
| §6.4 低效算法 | 1 | `AcceptQueue` 用 `PriorityQueue` 取单个最大值（O(n log n) 换 O(n)），n 为媒体类型个数且通常 ≤ 8，未达「热点」证据门槛，只作优化方案与假设 |
| §7 降堆内存方案 | 1 | 「请求级媒体类型选择结果的短生命周期副本」（`无基线（待验证）`）；其余（`StringGenerator`、`AuthParam.args`）为请求内短命对象，无量化依据，不列 |
| §8 降 CPU 方案 | 1 | `AcceptQueue` 单趟扫描 + 请求级只解析一次（`无基线（待验证）`） |
| §9 local mode 可行性 | 0 | 本部分函数内创建的临时对象只有 `AcceptQueue` 的元组/子串与 `AuthParam`，量级 KB 以下且 `AcceptQueue` 的子串可能随返回值逃逸（`first()` 返回 `String`），不满足「函数内创建、函数内释放」；模块级阻断已由 `doc/spec/record-f-mvc-path-pattern-blocker`（`PathPattern` 的 `HashMap<Int64, Any>`）记录，无前后峰值数据，不列方案 |
| §11 现有代码的 BUG（存量） | 12 | 上述「严重 3 + 一般 4 + 轻微 5」共 12 条全部为存量；逐函数核对了边界（空 `Accept`、尾逗号、缺 `Content-Type`、空 header）、空值（`Option` 未 `getOrThrow` 前的判空）、错误处理（`Float64.parse`、`MediaType` 415 路径）、资源（无文件/流持有）、并发（单例懒初始化）、契约（README/注解文档）六类 |
| §12 并发安全与锁粒度 | 2 | 共享路径已列出：`AuthHandlerProxy.instance`（进程级单例，请求线程并发 `check`）+ `CurrentHttpContext.context`（`ThreadLocal`，请求线程封闭，出口由 `RequestMeta.finishRequest` 清理）。前者命中「惰性初始化可见性」（严重）与「多实现选择无同步约束」（一般）；`AcceptQueue`/`AuthParam` 均为请求内局部对象，线程封闭。锁粒度：`mutex` 临界区只有一次 bean 列表解析，无需再拆 |
| §13 文档一致性 | 3 | `@IgnoreAuth` 的 README 措辞与拆分接口实现不一致（待确认，并入「严重」第 1 条）、参数注解语义未写（并入「一般」）、`docs/speech/speech.md:2881-2893` 的 5 步算法与实现的嵌套结构不符（并入「严重」第 1 条作为承诺源）；本部分其余逐条核对通过：`AuthStatus` 6 类取值与 README:189-201 一致、`CurrentHttpContext` 线程口径与 README:212-214 一致、`MVCBreakingCommand` 签名与 README:1161-1169 一致、`mvc_internalServerErrorMessageKind` 的 BEAN/TEXT/BASE64BINARY 与 `FailureMessageKind` 一致、两个 `doc/spec` 引用的 `HttpRequestDistributorImpl.cj:18/21` 与 `PathPattern.cj:248-252` 行号仍准确；配置项键名（`MVCConfig.cj`）不在本部分文件范围内，未展开核对 |
| §14 功能完备性与 README 覆盖 | 1 | 参数绑定注解无文档（一般）；`FailureMessageKind` 三种取值、`ExtendHttpResponsePusher`、`ErrorHttpRequestHandler` 均已在 README 有对应段落，无「承诺但缺失」；本部分代码未发现接线缺失（3 个安全注解均被 `RequestMeta` 读取，`requestBodyMediaType` 的 415 分支有 `MVCBreakingCommand` 接住） |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_mvc.part1.txt` 一一对应，无缺项、无跳过 |

### 第 2 部分

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

### 第 3 部分

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

### 第 4 部分

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
| 严重 | 6 |
| 一般 | 27 |
| 轻微 | 27 |
| 其中存量 | 27 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分是本模块的「鉴权 + 参数绑定」核心：11 个文件里有 6 个是注解/接口/枚举/空文件这类薄类型，真正承载逻辑的是 `ControllerFuncParam.cj`（三个参数提取器）、`AuthHandler.cj`（处理器选择与失败语义）和 `AcceptQueue.cj`（内容协商）。薄类型部分质量不错——注解都有 `@Annotation[target]` 且确实被 `RequestMeta.generate` 读取，`FailureMessageKind` 的 `Equatable`/`Parsable`/`DataParsable` 三件套完整，`ExtendHttpResponsePusher` 的转发不会自递归，`ControllerFuncParam_test` 对 `MVC-C3`（缺/未注册 `Content-Type` → 415）有正向与回归用例。

风险集中在两处，都是「分支条件写窄了」而不是算法错误：

1. **鉴权 fail-open（最高优先级）**。权限检查被嵌进 session 分支，导致「只注册 `PrivilegeHandler`」与「单 bean 兼任两个子接口」两种配置下权限检查静默失效（`@IgnoreAuth` 连带跳过权限另列为待确认）；再叠加 `AuthHandlerProxy` 的懒初始化用普通 `var` 跨线程发布，弱内存序平台上还可能整体读到「无 handler」而直接放行。鉴权代码的失效方向必须是 fail-closed，这两条都属于阻塞项，且改法都很小（把权限判断提出来 + 用不可变快照发布）。
2. **内容协商未归一化**。`Accept` 里的 `;q=` 被当成媒体类型的一部分，`HashSet.contains` 精确匹配必然失败，带权重的合法请求被 406；选中的值还被当作 `Content-Type` 回写。畸形 `q` 值则直接抛 `Float64.parse` 异常。建议连同 trim、大小写一起做一次归一化，并补一组 `Accept` 单测——目前 `AcceptQueue` 没有任何测试。

`RequestHeader` 与其它两个提取器的校验口径不一致，是「三份近似实现各自演进」的典型后果，属于可以顺手统一的重复逻辑。文档侧，README 把 75 个 `HttpStatus` 常量、WebSocket、FileDownload 都写得很细，却唯独漏掉了写 controller 必须用的 5 个参数注解，这一块建议优先补，否则使用者只能读源码猜 `default` 的类型。

性能与内存方面没有基线数据，报告只给了 2 条待验证方案（`AcceptQueue` 的单趟扫描 + 请求级只解析一次）和 4 条假设，未做任何「能降 X%」的结论。

**范围外提示**（不占本部分统计）：`f_mvc/src/RequestMeta.cj:144-151` 的 `populateResponseContentType` 把整条 `Accept` 原样写进 `Content-Type`（`Content-Type: text/html,application/xhtml+xml` 这类非法值），与上面 `AcceptQueue` 的 q 污染叠加；`f_mvc/src/global_func.cj:69-120` 的数组解析用 `Bool.parse`/`Int64.parse` 等非 `tryParse` 版本，非法查询值会抛异常而非 400。

**第 2 部分**：本部分代码整体处于「功能齐、边界松」的状态：结构分层清楚（分发器 → `MultiRequestMethodHandler` → `RequestMeta`/`WSMeta`，下载走独立 `FileDownload` 门面），前几轮加固留下的注释把设计意图写得很透（`AllowsCache` 的「构建一次」、`isWebSocketUpgrade` 的握手路由、`runDownloadTask` 的失败自收尾），可读性明显高于同仓平均水平；`HttpStatus`、`Redirect`、WS 注解这几个文件是纯数据/契约，没有缺陷。

真正的风险集中三处：

1. **HTTP 方法语义**（#1、#2）：HEAD 被当成「GET 的别名」，HEAD-only 路由恒 405、未知方法（TRACE/CONNECT）变 500。这两条都在请求主路径上，属可用性缺陷，建议优先排期——改动小（一个 `match` 分支 + `tryParse`），收益是行为可预期。
2. **下载的响应体生命周期**（#3、#8、#9）：成功路径不 `pipe.end()`、`start()/build()` 在 `spawn` 之后、每次下载一条线程、204 带 body。这些点单独看都「能跑」，但依赖 `SyncByteBuffer` 把空缓冲当 EOF 的巧合，且仓内没有一条下载端到端用例（成对的历史记录也确认未跑 e2e）。建议先补 e2e（单文件 / 多文件 / 中途失败），再按 #3 的建议把「开始」提到请求线程、「结束」放进统一收尾。
3. **静默降级**（#6、#7、#10、#4）：无路由不监听、`tlsPath` 写错走明文、`@OnWSPong` 的 mediaType 丢弃、CORS 预检头名拼错——四个场景的共同点是「不报错、行为与配置意图相反」，排障成本最高，建议统一改成「配置/契约不成立就启动失败或 `warn`」。

死代码与重复逻辑面很干净：只有 `MVCConfig.getStatus`、`RequestArgMeta.contains` 两处零引用符号，重复逻辑两处（下载读取循环、`HttpStatusOnlyHandler` 内的 Accept 处理），都不涉及行为漂移。性能方面本轮没有任何测试数据，因此未把「路由串解析」「`HttpStatus.values` 重建」写成结论，只进「待验证假设 / 优化可行性方案（无基线）」。

测试覆盖的短板需要点名：现有 4 个测试文件全部只钉「包内接缝」（`runDownloadTask`、`allowsOf`、`AllowsCache`、`isWebSocketUpgrade`、未命中 handler 的类型），`distribute` 的真实分发、HEAD/OPTIONS 的响应头与状态码、`HttpStatus.resolve/valueOf` 的解析结果、`MVCConfig` 的配置解析与非法值路径全部无用例。这也是 #1/#2/#7/#13 能长期存活的直接原因。

**第 3 部分**：本部分是 f_mvc 的"路由条件 + 请求元数据 + WebSocket 元数据 + 下载 + 异常"层，20 个文件里真正有逻辑的只有 4 个（`RequestMeta.cj` 722 行、`WSMeta.cj` 424 行、`RequestCondition.cj` 196 行、`ResponseDownload.cj` 76 行），其余是注解、枚举、异常与测试。整体工程质量偏上：近期一轮 `MVC-*` 修复留下的注释（`MVC-2/3/4/8/13/L5/L11/L12`）都能在代码里找到对应改动与用例，`RequestMethod` 的哈希/相等、`finishRequest` 的三条出口清理、`pumpFrames` 的定时器取消、`respondKind` 的空结果分支都有单测钉住。

但**鉴权与"公开 API 是否真能用"这两条线明显比其它部分薄弱**：

- 阻塞项一：#1 `@IgnoreAuth` 在"分离 Handler"部署下连带跳过权限检查，是可直接利用的越权；它恰好落在 README 两段承诺的夹缝里（`148` 说只忽略登录、`185` 说标记原样传给实现类），所以既不是文档写错也不是实现写错，而是**两条承诺交叉处的分支没人走过**。修法是把 Proxy 的两段检查拆平（十行左右），并补一条"两个 Handler + 单标记"的用例。
- 阻塞项二：#3 静态资源兜底默认以**进程工作目录**为根，且不校验 `..`/符号链接、读文件异常不降级——未配置 `mvcStaticResourceRoot` 的部署等于把工作目录（以及潜在的整个文件系统）开给未鉴权的 GET。这一条要么改默认值（未配置即关闭），要么把根目录规范化 + 前缀校验 + 白名单扩展名一起补上。
- 契约面：#2 `WSMeta.extract*Arg` 因为 `WSMeta.pattern` 从未赋值而必然抛 `NoneValueException`，12 个公开方法与 `README` 的 WebSocket 章节对不上；同族的 #6 `isMultipart` 判断了一个永远不成立的类型。#2/#6 都是"仓内零调用 + 零测试"的对外 API——与 `RequestMetas`（#13，只写不读）一起说明：**本模块有几处 API 是"写出来就没人再碰"，缺的是使用侧回归而不是文档**。
- 语义陷阱：#4 `params` 条件在无 query 时恒假（POST 表单体永远匹配不到，错误表现为 501）、#5 默认 `consumes=''` 让 GET/DELETE 对带 Content-Type 的请求一律 415、#7/#8 把 `Accept` 当 `Content-Type`/在 `*/*` 下丢错误体、#10 空 Close 帧越界、#11 关闭码常量写错——这些单条影响有限，但都发生在"请求进来/响应出去"的必经路径上，且都不报错、只表现为"路由不命中/客户端解析异常"，排查成本高。
- 可维护性：#14（多文件下载缺 boundary）、#20（帧状态机两处不完整）、#21/#22/#27（三组重复逻辑）属于"改一处不够、要同时改两三处"的债务；#17/#18/#19 是纯残留，删除即可。
- 性能与内存：本部分没有任何改前/改后数据，2 条内存方案 + 1 条 CPU 方案与 4 条假设都不进修复清单。下一轮最值得补的是"静态资源常驻对 RSS 的影响"（假设 2，与 #3/#9 同源）与"WS 大消息的分配量"（假设 3）——它们决定 #9 与 WS 缓冲要不要动结构。
- 已确认**没有**的问题：`RequestMethod` 的 `hashCode`/`==`/`compare` 三者自洽且有测试；`RequestCondition.compile` 的递归只受开发者注解表达式约束（非请求输入）；`WSMeta.exec` 的读循环与 ping 定时器生命周期正确（`finally` 取消）；`dataFrameCloseReason` 的两条"该关就关"判定与 `WSCloseFrame` 常量表除 1008 外均与 RFC 6455 一致；`download` 的 `copy` 只写实读长度（`MVC-4` 修复已生效）；`Series`/`WSPing`/4 个异常类无逻辑缺陷。

**第 4 部分**：本部分是两个宏的「代码生成层」+ 参数绑定内核，问题集中在「文档与生成物不一致、且生成物从未被真正编译/请求过」：

- **阻塞项 2 条**：`GET /health` 恒 415（一条 `consumes` 让框架自带的健康端点完全不可用，fprobe 的探针会一直报错），以及 `@WSEndPoint` 函数级参数注入的生成代码类型错误（全仓没有任何带 `@OnWS*` 处理函数的端点，这条路径十个月没有进过构建，一按文档写就编译失败）。两条都是「承诺的能力实际不可用」，建议优先处理。
- **可排期**：控制器异常一律 500（4xx 语义丢失）、`parseValue` 的缺失分支与解析失败语义不统一、`@IgnoreAuth` 在双 handler 装配下连权限一起放过。前两条影响面广但改动局部；第三条涉及公开语义，建议与 `AuthHandler` 其它部分一起改并补用例。
- **清理项**：8 处无用导入、`Byte`/`UInt8` 同型死分支、`WSEndPoint` 手写注册包装（应复用 `topMacroAnonymousClosure`）以及若干校验缺失，风险低、可顺手做。
- 代码质量本身不差：`response_download_test.cj` 是一条写得比较到位的回归用例（钉住「只写实读长度」这条不变量），宏展开也普遍做了 `try/catch` 与生成物回显，主要短板是「生成路径缺少编译级用例」与「文档比实现走得快」。

本部分存量缺陷共 15 条（严重 2 / 一般 9 / 轻微 4），是否纳入修复待用户决定；优化方案 3 条（全部无基线）与待验证假设 3 条不进修复清单。
