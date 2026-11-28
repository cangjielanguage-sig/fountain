# f_mvc 模块审查报告（模块第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（本部分 11 个 `.cj` + 9 个 `.md`，共 20 个文件；模块合计 59 `.cj` + 9 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支，无 diff 可比；`git blame` 的每一行都落在 2026-10-02 `4be871f2f`「统一换行符为 LF（CRLF→LF，1293 个文件）」这一纯格式提交上，再向上用 `git log -S` 只能追到功能提交号，无法区分引入版本）→ 全部问题记为「存量」
- **审查重点**：路由 / 参数绑定正确性、鉴权与权限（`@IgnoreAuth` 语义）、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件是分报告，模块报告 `docs/review/2026-11-28/f_mvc.md` 由主 Agent 合并 4 个部分后生成）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `AcceptQueue` 的构造 + 堆操作在路由主路径上的自耗时占比（n=5 时） | `f_mvc/src/AcceptQueue.cj:27-60` | 自耗时占比、每请求分配字节数 | `cjprof record` 跑 `Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` 的 GET 压测（10k req/s，60s） |
| 2 | 同一请求重复解析 `Accept`（`checkProduces` + `respond` + 错误路径）的比例 | `f_mvc/src/RequestMeta.cj:176,270,374` | 每请求 `AcceptQueue` 构造次数分布 | 在 `AcceptQueue.init` 加计数器埋点，跑 10 分钟稳态负载后看直方图 |
| 3 | `@RequestParamObject` 每请求的反射开销（`getStaticFunction('dataFields')` + `apply` + 逐字段 `mutableFields`） | `f_mvc/src/ControllerFuncParam.cj:96-108` | 单次 extract 耗时、在请求总耗时中的占比 | 5 字段对象的 controller，`cjprof` 压测 10k 请求 |
| 4 | `AuthHandlerProxy` 首次请求的 `lookupList` 在锁内的等待（冷启动 P99） | `f_mvc/src/AuthHandler.cj:99-119` | 首请求锁等待时长、并发首请求数 | 分段计时埋点（`synchronized` 前后 `MonoTime`），冷启动并发 50 请求 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/README.md` | .md | ✅ | 配置/宏/安全注解/AuthHandler/CurrentHttpContext/WebSocket/FileDownload 段落逐条与实现核对；问题见「一般」参数注解未文档化、「严重」拆分接口下权限检查失效（README:146 的 `@IgnoreAuth` 措辞列为待确认） |
| 2 | `f_mvc/README_en.md` | .md | ✅ | 章节结构与中文版一一对应（1353 行 vs 1338 行，差异为英文换行）；`HttpStatus`/`Series` 声明块 75 个常量与中文版逐项一致（归一化 diff 为空）；与中文版同步缺参数注解章节 |
| 3 | `f_mvc/doc/spec/fix-mvc-streaming-response/design.md` | .md | ✅ | 方案 D1「显式 `Transfer-Encoding: chunked`」与 `RequestMeta.cj:396-405` 现状一致 |
| 4 | `f_mvc/doc/spec/fix-mvc-streaming-response/proposal.md` | .md | ✅ | 问题描述与现状一致；`MVC-C3`/SSE 影响面为历史记录 |
| 5 | `f_mvc/doc/spec/fix-mvc-streaming-response/specs/mvc-response/spec.md` | .md | ✅ | 3 个 Scenario 与实现语义一致（无法在本轮复跑用例） |
| 6 | `f_mvc/doc/spec/fix-mvc-streaming-response/tasks.md` | .md | ✅ | 勾选项与代码一致（chunked 已落地）；测试计数 32/32 未复跑 |
| 7 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/design.md` | .md | ✅ | 引用的 `HttpRequestDistributorImpl.cj:18/21`、`PathPattern.cj:248-252` 与当前代码行号仍吻合 |
| 8 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/proposal.md` | .md | ✅ | 纯文档变更记录，两条阻断结论自洽 |
| 9 | `f_mvc/doc/spec/record-f-mvc-path-pattern-blocker/tasks.md` | .md | ✅ | 勾选项为当时验证记录，不与当前实现冲突 |
| 10 | `f_mvc/src/AcceptQueue.cj` | .cj | ✅ | 「严重」q 参数未剥离、「一般」畸形 q 抛异常；优化方案 2 条 |
| 11 | `f_mvc/src/AuthAnnotation.cj` | .cj | ✅ | 3 个注解均被 `RequestMeta.cj:540-542` 读取，无死代码 |
| 12 | `f_mvc/src/AuthHandler.cj` | .cj | ✅ | 「严重」权限短路 + 初始化可见性、「一般」先注册先赢、「轻微」注释/命名 |
| 13 | `f_mvc/src/BreakingCommand.cj` | .cj | ✅ | 4 个构造器为转发，`status` 公有只读；无缺陷 |
| 14 | `f_mvc/src/ControllerFuncParam.cj` | .cj | ✅ | 「一般」RequestHeader 校验口径、「轻微」concat 前导空值 + 错误消息；参数绑定主逻辑 |
| 15 | `f_mvc/src/ControllerFuncParam_test.cj` | .cj | ✅ | 4 个 `@TestCase` 只覆盖 `requestBodyMediaType`（415 三种 + JSON 回归）；`catch (_: Exception)` 为「修前形态哨兵」并有注释，非静默吞异常 |
| 16 | `f_mvc/src/CurrentHttpContext.cj` | .cj | ✅ | ThreadLocal 语义正确；`scoped` 不恢复前值（轻微） |
| 17 | `f_mvc/src/DownloadMeta.cj` | .cj | ✅ | 空文件（轻微） |
| 18 | `f_mvc/src/ErrorHttpRequestHandler.cj` | .cj | ✅ | 接口被 `MultiRequestMethodHandler.cj:147` 按 bean 名 lookup；契约与 README:62-77 一致 |
| 19 | `f_mvc/src/ExtendHttpResponsePusher.cj` | .cj | ✅ | `extend HttpResponsePusher` 增加 `RequestMethod` 重载，转发到 stdx 的 `push(String,String,HttpHeaders)`（文档 `stdx/net/http/http_package_api/http_package_classes.md:6242`），无递归风险 |
| 20 | `f_mvc/src/FailureMessageKind.cj` | .cj | ✅ | `tryParse`/`parse`/`==` 与 `MVCConfig.cj:35,242,248` 用法一致；`Equatable`+`DataParsable` 契约齐备 |

合计：`.cj` 11 个 / `.md` 9 个 / 共 20 个，全部读完（本部分不含 `src/FileDownload.cj`、`src/RequestMeta.cj` 等 48 个 `.cj`，归其余 3 个子轮）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 4 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 12 条（严重 3 + 一般 4 + 轻微 5），全部只报不修，是否纳入修复待用户决定。「待验证假设」4 条不计入统计。

## 总评

本部分是本模块的「鉴权 + 参数绑定」核心：11 个文件里有 6 个是注解/接口/枚举/空文件这类薄类型，真正承载逻辑的是 `ControllerFuncParam.cj`（三个参数提取器）、`AuthHandler.cj`（处理器选择与失败语义）和 `AcceptQueue.cj`（内容协商）。薄类型部分质量不错——注解都有 `@Annotation[target]` 且确实被 `RequestMeta.generate` 读取，`FailureMessageKind` 的 `Equatable`/`Parsable`/`DataParsable` 三件套完整，`ExtendHttpResponsePusher` 的转发不会自递归，`ControllerFuncParam_test` 对 `MVC-C3`（缺/未注册 `Content-Type` → 415）有正向与回归用例。

风险集中在两处，都是「分支条件写窄了」而不是算法错误：

1. **鉴权 fail-open（最高优先级）**。权限检查被嵌进 session 分支，导致「只注册 `PrivilegeHandler`」与「单 bean 兼任两个子接口」两种配置下权限检查静默失效（`@IgnoreAuth` 连带跳过权限另列为待确认）；再叠加 `AuthHandlerProxy` 的懒初始化用普通 `var` 跨线程发布，弱内存序平台上还可能整体读到「无 handler」而直接放行。鉴权代码的失效方向必须是 fail-closed，这两条都属于阻塞项，且改法都很小（把权限判断提出来 + 用不可变快照发布）。
2. **内容协商未归一化**。`Accept` 里的 `;q=` 被当成媒体类型的一部分，`HashSet.contains` 精确匹配必然失败，带权重的合法请求被 406；选中的值还被当作 `Content-Type` 回写。畸形 `q` 值则直接抛 `Float64.parse` 异常。建议连同 trim、大小写一起做一次归一化，并补一组 `Accept` 单测——目前 `AcceptQueue` 没有任何测试。

`RequestHeader` 与其它两个提取器的校验口径不一致，是「三份近似实现各自演进」的典型后果，属于可以顺手统一的重复逻辑。文档侧，README 把 75 个 `HttpStatus` 常量、WebSocket、FileDownload 都写得很细，却唯独漏掉了写 controller 必须用的 5 个参数注解，这一块建议优先补，否则使用者只能读源码猜 `default` 的类型。

性能与内存方面没有基线数据，报告只给了 2 条待验证方案（`AcceptQueue` 的单趟扫描 + 请求级只解析一次）和 4 条假设，未做任何「能降 X%」的结论。

**范围外提示**（不占本部分统计）：`f_mvc/src/RequestMeta.cj:144-151` 的 `populateResponseContentType` 把整条 `Accept` 原样写进 `Content-Type`（`Content-Type: text/html,application/xhtml+xml` 这类非法值），与上面 `AcceptQueue` 的 q 污染叠加；`f_mvc/src/global_func.cj:69-120` 的数组解析用 `Bool.parse`/`Int64.parse` 等非 `tryParse` 版本，非法查询值会抛异常而非 400。
