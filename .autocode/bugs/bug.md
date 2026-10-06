# 代码审查报告：f_orm / f_mvc / f_bean / f_aspect（索引）

- 审查分支：`review/orm-mvc-bean-aspect`（基线 `5a5d6cf3`，即审查时的 `sts/1.3.x` 值）
- 审查范围：4 个模块、183 个 `.cj`、19706 行（f_orm 11587 / f_mvc 5044 / f_bean 1939 / f_aspect 1136），逐文件通读
- 审查依据：`cangjie-code-review`（性能优化 14 节 / 内存优化 11 节）；结论以「瓶颈证据 + 调用频率 + 功能等价」为准，未做实测的项一律标注
- 复核口径：所有「严重」级问题**已回到源码逐行复核**（行号见各条）；「中」及以下带 `文件:行号` 证据
- **编排方式**：按**严重程度降序**（严重 → 中 → 低/待验证），不按模块分节；同一级内按「静默错误/崩溃 → 语义与内容损坏 → 资源泄漏 → 热点开销 → 局部浪费」排序。模块归属只体现在每条编号上：`ORM-x`（f_orm）、`MVC-x`（f_mvc）、`BEAN-x`（f_bean）、`ASP-x`（f_aspect）、`X-x`（跨模块）
- **已按模块拆分（2026-10-05）**：条目正文拆到 `bug-orm.md` / `bug-mvc.md` / `bug-bean.md` / `bug-aspect.md` / `bug-cross.md`，**编号沿用原报告**（§x.y 不变，便于与代码注释、其他报告交叉引用）；本文件保留摘要与修复时间线、编号索引、基线与验证状态、审查方法。各模块的结构小结（原 §4.1–§4.4）随该模块条目放在对应文件末尾。
- 同目录另有归档报告（`bug-archived-20261004-2.md`、`bug-archived-on-20261004.md`）与模块专题报告（`bug-cache.md`、`bug-pool.md`、`bug-mockdb.md`）。

## 0. 摘要

| 严重度 | f_orm | f_mvc | f_bean | f_aspect | 跨模块 | 合计 |
|---|---|---|---|---|---|---|
| 严重 | 3 | 4 | 1 | 5 | 1 | **14** |
| 中 | 7 | 8 | 4 | 4 | 1 | **24** |
| 低 / 待验证 | 14 | 13 | 9 | 8 | 0 | **44** |
| 合计 | 24 | 25 | 14 | 17 | 2 | **82** |

> 计数修正（2026-10-04）：§1.3 `ASP-1` 判定为**误判**（设计目的，非缺陷）⇒ 待修严重级 **13** 条（f_aspect 严重 4 条）；上表保留审查当时的原始计数。
> 二次修正（2026-10-04）：§1.4 `ASP-2` 已修复 ⇒ 待修严重级 **12** 条（f_aspect 严重 3 条）。
> 三次修正（2026-10-04）：§1.6 `ASP-4` 已修复 ⇒ 待修严重级 **11** 条（f_aspect 严重 2 条）。
> 四次修正（2026-10-05）：§1.7 `ASP-5` 已修复 ⇒ 待修严重级 **10** 条（f_aspect 严重 1 条）。
> 五次修正（2026-10-05）：§1.8 `BEAN-1` 已修复 ⇒ 待修严重级 **9** 条（f_bean 严重 0 条）。
> 六次修正（2026-10-05）：§1.9 `MVC-4` 已修复 ⇒ 待修严重级 **8** 条（f_mvc 严重 2 条：§1.10 `MVC-1`、§1.11 `MVC-3`）。
> 七次修正（2026-10-05）：§1.5 `ORM-C1` 已修复（迭代器持有结果集/语句所有权、事务感知关闭），§2.1 `ORM-C2` 一并修复 ⇒ 严重级待修再减 1（**f_orm 严重级清零**）。**核对**：把此前已修复的 `X-1`、`ORM-1`、§1.9 `MVC-4` 一并计入后，实际剩余严重级 **5** 条 —— §1.10 `MVC-1`、§1.11 `MVC-3`、§1.12 `MVC-2`、§1.13 `ORM-2`、§1.14 `ASP-3`（前述逐次递减的「8/9 条」未扣减 `X-1`、`ORM-1` 与 `MVC-4`）。
> 八次修正（2026-10-05）：§1.10 `MVC-1` 判定为 ❌**误判**（「无上限」是设计目的、静态文件本就要求常驻内存；「负缓存」不成立）；§1.11 `MVC-3` 已修复 ⇒ 剩余严重级 **3** 条 —— §1.12 `MVC-2`、§1.13 `ORM-2`、§1.14 `ASP-3`。
> 九次修正（2026-10-05）：§1.13 `ORM-2` 已修复（列信息构造期缓存 + 取值判定收敛为按列构造的取值器；mock 口径前后计时无差异，真实驱动的收益待 `ORM-L3` 验证）⇒ 剩余严重级 **2** 条 —— §1.12 `MVC-2`、§1.14 `ASP-3`。
> 十次修正（2026-10-05）：§2.8 `ORM-C5` 判定为 ❌**误判**（`argInSql` 是显式打开的「值内联进 SQL」开关，设计目的；已补 README §11.5 说明 + 口径用例）⇒ f_orm 中危待修 **5** 条（§2.10–§2.14）。
> 十一次修正（2026-10-05）：§2.10 `ORM-3` 判定为 ⏸**决定不修**（保留现状：否决「加静态集合只清标记过的类型」与「`beforeDirty` 挪到引用型 holder 就地复位」两个方案，报告原文的成本仍作已知开销登记在案）⇒ f_orm 中危待修 **4** 条（§2.11–§2.14）。
> 十二次修正（2026-10-05）：§2.11 `ORM-4` 判定为 ⏸**决定不修**（借连接校验 `checkOnBorrowing` 与默认值均不改；语句复用读了四家驱动源码——ZhaoJun postgres 驱动自带 32 条 LRU 语句缓存、aibrary pgsql 无缓存、mysql/mariadb CRUD 走 server 模式——判定在 f_orm 层重做不值得，依据见 §2.11）⇒ f_orm 中危待修 **3** 条（§2.12–§2.14）。
> 十三次修正（2026-10-05）：§2.12 `ORM-5` 已修复（`emptyLogicalExpr` / `Condition.trim` / `TableClause.appendPartial` 三处改为预编译正则常量；前后各 118 行输出逐字符一致，`trim` 计时 ≈1.7×、`emptyLogicalExpr` ≈14.8×）⇒ f_orm 中危待修 **2** 条（§2.13–§2.14）。
> 九次修正（2026-10-05）：§1.12 `MVC-2` 已修复（`accessLog` 惰性化：日志级别关闭时不序列化参数与返回值）⇒ 剩余严重级 **2** 条 —— §1.13 `ORM-2`、§1.14 `ASP-3`。
> 十次修正（2026-10-05）：§2.2 `MVC-C3` 已修复（缺 / 未注册 Content-Type 的 `@RequestBody` 请求改回 415，不再 500）⇒ f_mvc 中危待修 7 条（§2.3、§2.5、§2.6、§2.7、§2.19–§2.21）。
> 十一次修正（2026-10-05）：§2.3 `MVC-C5` 已修复（下载任务失败自收尾：记录 + 结束响应体；传输耗时搬进下载任务）⇒ f_mvc 中危待修 6 条（§2.5、§2.6、§2.7、§2.19–§2.21）。
> 十二次修正（2026-10-05）：§2.5 `MVC-C2` 已修复（`respond<R>` 的 `Resource` 关闭覆盖所有分支；缺 `Accept` 的非空结果不再 406 而按星号通配渲染；该条经核实为**潜在**问题——本仓库唯一 `ToData & Resource` 类型 `MultipartFile` 会被 `InputStream` 分支先拦走）⇒ f_mvc 中危待修 5 条（§2.6、§2.7、§2.19–§2.21）。
> 十三次修正（2026-10-05）：§2.6 `MVC-8` 已修复（两处请求出口统一清请求级 ThreadLocal：`currentResponseStatus` 与 `OverallStopwatch.start`；access log 的 status 改在请求线程读，不再由异步 appender 在消费线程上读成默认值）⇒ f_mvc 中危待修 4 条（§2.7、§2.19–§2.21）。
> 十四次修正（2026-10-05）：§2.7 `MVC-6` 判定为 ❌**误判**（用户判定：WS 消息总长上限属端点/部署侧策略，框架不设硬上限是设计选择；帧上限已由 `mvc_maxFrameSize` 可配）⇒ f_mvc 中危待修 3 条（§2.19–§2.21）。
> 十五次修正（2026-10-05）：§2.19 `MVC-5` 判定为 ❌**不值得改**（用户判定；全仓 `@PathVariable` 均为单变量、暴露面为零；触发条件「出现 ≥2 个 `@PathVariable` 的端点」时再评估）⇒ f_mvc 中危待修 2 条（§2.20、§2.21）。
> 十六次修正（2026-10-05）：§2.3 `MVC-C5` 的异常形态按用户指定改为 `throw ex`（收尾也失败时抛包装后的 `MVCException`：cause = 收尾失败、suppressed = 原任务异常；实测 std `Exception(caused)` 不复制 message ⇒ `ex.message` 为空），用例同步钉该形态。
> 十七次修正（2026-10-05）：§2.20 `MVC-7` 已修复（范围：`RequestMethod.hashCode()` 由 `toString().hashCode()` 改为声明序常量表；`compare` 经核对只在注册期、`tryParse` 分配净收益不确定，按用户决定不动。唯一可观察变化是 OPTIONS 的 `Allow`/`Access-Control-Allow-Method` 头方法顺序可能不同）⇒ f_mvc 中危待修 1 条（§2.21）。
> 十八次修正（2026-10-05）：§2.21 `MVC-9` 判定为 ❌**不改**（用户判定：每次 HTTP 访问都从 IoC 取一次 controller 实例是**设计语义** —— 允许把 controller 定义为 `prototype`，缓存实例会把它静默变成单例；`@Controller` 即 `@Bean` 包装，fdemo 有 prototype 控制器实例 `CurrentUserController`。报告原建议「注册期解析」另有时序问题：注册在模块静态初始化期，早于 `BeanFactory.afterRegistered()` 的 `check()`/`initBeansIfNeed()`）⇒ **§1 严重级、§2 中危全部清零**，f_mvc 仅剩 §3 的 13 条低危/待验证。
> 十九次修正（2026-10-05）：§3.1 三条微项加固（`fix/mvc-rest`，同一提交）：`MVC-L8` 404 日志改惰性插值；`MVC-L1` OPTIONS 的 `Allow` 串改为「构建一次缓存」（新增包内接缝 `AllowsCache` / `allowsOf`，删死变量）——RED/GREEN 实测 `testAllowsIsBuiltOnce` 由失败转通过，`TOTAL 24 / PASSED 24`；`MVC-C6`(a) WS 帧错误日志改惰性（`log.error(e){…}`），ERROR 关闭时不再为每条消息 base64 整个 payload（控制流未动；(b) 待用户拍板）⇒ f_mvc 剩 §3.1 低危 8 条 + §3.2 待验证 2 条。
> 二十次修正（2026-10-05）：§3.1 `MVC-L5` 已修复（`fix/mvc-rest`）：未命中路由（静态资源 / 404，**每条静态资源请求都命中**）不再每请求构造 `RequestMeta`（原先连带 2×`HashSet` + `RequestArgMeta`（内含 `HashMap`）+ 闭包 ≈6 次分配），改返回只持 `path` 的轻量 handler `StaticResourceOrNotFoundHandler`；`RequestMeta` 构造器默认处理器改为委托它（单一事实来源），并为复用放宽 `log` / `NOT_FOUND` / `loadStaticResource` 为包内可见（公开 API 不变，日志 name 与文本不变）。RED/GREEN 实测 `testUnmatchedPathReturnsLightweightHandler`（结构契约）由 `handler is StaticResourceOrNotFoundHandler = false` 转通过，`TOTAL 25 / PASSED 25`。⇒ f_mvc 剩 §3.1 低危 7 条 + §3.2 待验证 2 条。
> 二十一次修正（2026-10-06）：§3.1 `MVC-L7` 判定为 ❌**不改**（用户判定 C）。核对修正了报告的表述：`RequestMeta.compare` 里「建两个 `TreeSet`」那段只在**前两步都为 EQ（`path` 与 `method` 都相同）**时才执行 ⇒ 一次 `TreeSet.add` 的 O(log N) 次比较里绝大多数只做两次字符串比较，「同 path + 同 method」组常态只有 1 个成员 ⇒ 真实成本是注册期毫秒级以下的短字符串比较。顺带发现（未立项）：`RequestMetas`（`RequestMetas.cj:18-28`）是**只写不读**的容器（全仓只有 `RequestMeta.cj:527` 的 `instance.add`，`metas` private 无访问器）⇒ `compare` 目前在为一个无消费者的有序表服务。⇒ f_mvc 剩 §3.1 的 `MVC-C6`(b) 与 `MVC-L2`/`L3`/`L4`/`L6`/`L9`/`L10`（共 7 条）+ §3.2 的 `MVC-L11`/`L12` 两条待验证。
> 二十二次修正（2026-10-06）：§3.2 `MVC-L12` 已修复（`fix/mvc-rest`）：`RequestMethod.operator ==` 补 `(WS, WS)` 分支（`!=` 由 `==` 派生自动修好），修掉 `Equatable` 不满足自反性的硬缺陷。**「HashMap 是否引用短路」的待验证问题定论**：本机 std 源码 `hash_map.cj:485` 的匹配是 `hash == 记录.hash && key == 记录.key`（无短路），`HashSet` 委托 `HashMap`、fountain 的 `computeIfAbsent` 走 `entryView` 同族 ⇒ 拿 `WS` 当键必查不到；RED 实测 `map.get(RequestMethod.WS)` 为 `None`、`WS == WS` 为 false，GREEN 后 `TOTAL 27 / PASSED 27`。修后唯一新增可观察行为 = WS 键的 `get/contains/add/computeIfAbsent` 生效 + debug 日志 `methodRegistered` 不再误报 false（请求期从不查 `WS`）。**新发现（未立项）**：WS 端点路由可达性存疑 —— WS meta 只注册在 `WS` 键下（`HttpRequestDistributorImpl.cj:36`）而握手请求是 `GET`（`MultiRequestMethodHandler.cj:64/91`）⇒ 代码路径上匹配不到、落到 `:111` 的 405，全仓无 `@WSEndPoint` 示例/文档/集成测试。⇒ f_mvc 剩 §3.1 的 7 条（`MVC-C6`(b)、`MVC-L2`/`L3`/`L4`/`L6`/`L9`/`L10`）+ §3.2 的 `MVC-L11` 1 条待验证。
> 二十九次修正（2026-10-06）：`MVC-14` 已修复（`fix/mvc-rest`，用户选方案①）：抽出包内接缝 `finishRequest()`（`CurrentHttpContext.clear()` + `RequestMeta.clearResponseStatus()` + `OverallStopwatch.clearStart()`），**三条请求出口共用** —— HTTP 闭包、404/静态资源轻量 handler、以及此前裸调用不收尾的 **WS 闭包**（改为 `try { CurrentHttpContext.set(ctx); wsmeta.handle(...) } finally { finishRequest() }`）⇒ 握手被拒留下的 406 不再串给同线程下一个请求的 `accessLog`。验证：新增 `RequestMeta_test.testFinishRequestClearsRequestState`；整轮 `TOTAL 31 / PASSED 31 / FAILED 0`、`cjpm build` exit 0（`MVC-13` 端到端用例仍全绿）。**无 RED**（WS 出口未接缝不可观测，同 `MVC-L8`/`MVC-C6(a)` 类型）；首次 build 的 `undeclared identifier 'clearResponseStatus'`（顶层函数漏 `RequestMeta.` 限定）已修正。⇒ **f_mvc 条目全部结清**（§1 严重 0、§2 中危 0、§3.1 与 §3.2 全部 ✅/判定不改）。
> 二十八次修正（2026-10-06）：`MVC-13` 的 **fdemo 冒烟资产就位**（`fix/mvc-rest`）：新增 `fdemo/user/src/controller/SmokeWSEndPoint.cj`（`@WSEndPoint['/ws/smoke']`，无任何 `@OnWS*` 处理器 ⇒ 只有握手）与 `fdemo/ws_smoke.sh`（build → launch → 等 8080 → `/dev/tcp` 原始握手断言 `101`、普通 GET 断言 `405`）。PostgreSQL 经用户提示后核对**可用**（5432 在监听；`~/.bashrc` 里 `POSTGRES_USERNAME=fountain`/`POSTGRES_PASSWORD=…`/`POSTGRES=postgres://172.27.34.60:5432/fountain`，`psql` 实测可连 ✔），但本轮运行**卡在 fdemo 自身的构建/启动封装**（① build：`fboot: error while loading shared libraries: libf_app@fountain.so: cannot open shared object file`；② launch：`./boot.sh: line 161: launch: command not found`，Linux `boot.sh` 的 `launch)` 分支调用的 `launch` 未定义）⇒ 与 WS 路由无关；**路由验证以 f_mvc 内端到端为准**（`WebSocketRouting_test`：101 ✔ / 405 ✔），fdemo 脚本保留给能正常 `boot.sh build/launch` 的环境。
> 二十七次修正（2026-10-06）：`MVC-13` **端到端验证完成并纠正判断**（`fix/mvc-rest`）。新增 `f_mvc/src/WebSocketRouting_test.cj`：测试内起**真实 stdx 服务**（`ServerBuilder` + `HttpRequestDistributorImpl.instance`，端口 18099）+ `std.net.TcpSocket` 发**真实握手**，断言握手 `HTTP/1.1 101 Switching Protocols`、同路径无 `Upgrade` 头的普通 GET 仍 `HTTP/1.1 405 Method Not Allowed` —— **两条全绿**（`TOTAL 30 / PASSED 30`，`cjpm build` exit 0）。实测纠正两点：①**stdx 对 WS 握手上报 `request.method == "WS"`（不是 `GET`）** ⇒ `metas.get(WS)` 本就是请求期真实查表（`MVC-L12` 修前返回 None ⇒ 405，修后才命中并暴露下一步）；②**真正的拦路虎是 consumes 查表** —— 握手无 `Content-Type`（`c == ''`）而 WS meta 的 consumes 键是 `'*'` ⇒ `check(metas)` 落空 ⇒ **415**（诊断输出实测到该行）；修复 = `check(metas)` 增加 `'*'` 通配兜底（控制器 consumes 不允许 `'*'` ⇒ 该键只可能来自 WS 端点），修后握手拿到 101 ✔。`handle` 里新增的 `GET + isWebSocketUpgrade` 分支在本栈不可达（stdx 上报 `WS`），保留为对其它 server 实现的防御（有单测）。fdemo 冒烟路线因依赖 PostgreSQL（`postgres_driver` + `orm_drivers=postgres`）在本环境不可行，已在用例注释中写明。
> 二十六次修正（2026-10-06）：新立条目 **`MVC-14`**（§3.2 待验证）：**WS 路径缺请求级 ThreadLocal 收尾** —— `RequestMeta.setHandle(wsmeta:)` 的闭包（`RequestMeta.cj`）没有 HTTP 路径那样的 `CurrentHttpContext.set/clear` 与 `clearResponseStatus()`/`OverallStopwatch.clearStart()`（对比 `setHandle<T>(fn:)` 的 `try/finally`，`:202`/`:222-224`）。影响：①`CurrentHttpContext.instance` 是 `context.get().getOrThrow()`（`CurrentHttpContext.cj:30-34`）⇒ WS 链路里若用 `download(...)`/`FileDownload`（后者构造期即读 `CurrentHttpContext.instance`，`FileDownload.cj:38`）会抛 `NoneValueException`；②`check(wsMeta)` 命中 `NOT_ACCEPTABLE`/`NOT_IMPLEMENTED` 时 `HttpStatusOnlyHandler` 会 `setResponseStatus`（`MultiRequestMethodHandler.cj:133`/`:145`，如握手带非通配 `Accept`），WS 路径不清 ⇒ 该线程后续 HTTP 请求的 `accessLog`（`RequestMeta.cj:538`）可能取到陈旧状态；③`OverallStopwatch` 起点残留（下次 `doStart` 覆盖，仅短暂持有 path 引用）。相关性：`MVC-13` 刚让 WS 路径可达，此前影响面为 0。建议修法（小）：把 WS 闭包与 HTTP 闭包对齐（`try { CurrentHttpContext.set(ctx); … } finally { CurrentHttpContext.clear(); clearResponseStatus(); OverallStopwatch.clearStart() }`）。验证：ThreadLocal 为线程内状态、外部不可断言，需随 `MVC-13` 的端到端或专门接缝观察（当前无单测方案）。
> 二十五次修正（2026-10-06）：新条目 `MVC-13` 已修复（`fix/mvc-rest`，用户选「③ 打通」）：`MultiRequestMethodHandler.handle` 在方法/Content-Type 查表前先判 `GET + isWebSocketUpgrade(headers)`（新接缝：`Upgrade` 头含 `websocket`，忽略大小写），命中则取 `metas.get(RequestMethod.WS)` 并用**单参** `check(wsMeta).handle(ctx)` 处理 —— 握手请求没有 Content-Type，而 WS meta 的 `consumes`/`produces` 是 `'*'`，走双参 `check(metas)` 会因 `map.get('')` 落空误判 **415**。该分流依赖已修的 `MVC-L12`（`(WS, WS)` 的 `==`，否则 `metas.get(WS)` 必落空）。行为变化仅限「GET + `Upgrade: websocket` 且该路径注册了 WS 端点」（修前 405 → 现进入 WS meta：`WSMeta.upgrade` → `exec`）；无 Upgrade 头或路径无 WS 端点的请求完全不变。RED/GREEN：`MultiRequestMethodHandler_test.testIsWebSocketUpgrade`（`websocket`/`WebSocket` ⇒ true，`h2c`/缺失 ⇒ false）修前失败（`right: false`）→ 实现接缝后 **`TOTAL 29 / PASSED 29`**，同轮 `cjpm build` exit 0。**未覆盖**：①端到端（WS 客户端应收到 101 而非 405）需真实服务 + WS 客户端，f_mvc 单测造不出 `HttpContext`；②只做路由分流，握手合法性仍由 stdx 校验；③顺带观察（未处理）：WS 路径的 `handle_`（`RequestMeta.setHandle(wsmeta:)`）没有 HTTP 路径那样的 `CurrentHttpContext.set/clear` 与 `clearResponseStatus`/`OverallStopwatch.clearStart` 收尾。
> 二十四次修正（2026-10-06）：§3.1 剩余 6 条（`MVC-L9`/`L2`/`L3`/`L4`/`L6`/`L10`）按分诊判定为 ❌**不改**（用户 2026-10-06 采纳），逐条理由见 §3.1 判定标记（C 桶）；同时把此前顺带发现的 **WS 端点路由可达性**问题立为新条目 **`MVC-13`**（§3.2 待验证）：WS meta 只注册在 `WS` 键下（`HttpRequestDistributorImpl.cj:36`）而握手请求是 `GET`（`MultiRequestMethodHandler.cj:64/91`）⇒ 代码路径上匹配不到、落到 `:111` 的 405；全仓无 `@WSEndPoint` 示例/文档/端到端用例 ⇒ f_mvc 唯一待验证项为 `MVC-13`。
> 二十三次修正（2026-10-06）：`MVC-C6`(b) 与 `MVC-L11` 已修复（`fix/mvc-rest`，同一提交）。`MVC-L11`：空结果（`DataUnit`/`DataNone`）不再因「具体 Accept（不含 `*/*`）」判 406 —— 改为「原状态码 + 按 Accept 声明 Content-Type + 空体」（仅 `Accept: ''` 异常值仍 406）；修前会把 `MVCBreakingCommand(status)`（默认 `DataUnit.UNIT`，如 `ControllerFuncParam` 的 415）的状态码吞成 406（调用链：`ControllerFuncParam.cj:192` → `BreakingCommand.cj:23` → `RequestMeta.cj:220` → `respond<Data>`），`MVC-C3` 的用例只断言到 `MVCBreakingCommand` 层，故此前未暴露。`MVC-C6`(b)：数据帧无对应 meta / 上一条载荷未消费完，从「每条消息抛异常 → catch → 会话继续」改为**首帧即关**（新增接缝 `dataFrameCloseReason` + `log.error` + `ws.closeConn()` + `return true`，并删除被取代的 `throw`）。RED/GREEN：`testEmptyResultBranches` 与 `testDataFrameCloseReason` 各失败 1 条（`TOTAL 28 / PASSED 26 / FAILED 2`）→ 全绿 **28/28**。⇒ f_mvc 剩 §3.1 的 `MVC-L2`/`L3`/`L4`/`L6`/`L9`/`L10`（6 条，按分诊为不改，待用户口径）。
> —— 以下为并行会话（f_bean，分支 `fix/bean-anno` 等）的时间线：其编号与上方 f_mvc 侧各自独立，仅表示各自会话内的第 N 次修正 ——
> 九次修正（2026-10-05）：§2.15 `BEAN-2` 已修复（`getFirst` 热路径去掉两处恒真复检；调用形状即 `f_mvc` 每请求一次，基准 ns/op **3951.68 → 2253.18**）⇒ f_bean 中危待修 4 → 3 条，详见 `bug-bean.md` §2.15。
> 十次修正（2026-10-05）：§2.17 `BEAN-4` 已修复（`StringCond` 的 `Wildcard`/`Regexp` 按模式串 memo 编译结果；基准 ns/op `Wildcard` **4342.47 → 1508.23**、`Regexp` **3886.54 → 1747.54**，对照组不变）⇒ f_bean 中危待修 3 → 2 条（§2.16 `BEAN-3`、§2.18 `BEAN-5` 待验证），详见 `bug-bean.md` §2.17。
> 十一次修正（2026-10-05）：§2.16 `BEAN-3` 已修复（`iterator<T>()` 的 IgnoreCond 快路径不建闭包 + 单参重载去掉恒真校验；按用户指示一并修 `getFirstTuple` 的逐元素重算；基准 `iterator<Animal>()` ns/op **3262 → 2349 / 3174 → 2586**，见 `bug-bean.md` §2.16）⇒ f_bean 中危待修仅剩 §2.18 `BEAN-5`（待验证）。
> 十二次修正（2026-10-05）：§2.18 `BEAN-5` 已修复（`BeanManager` 构造期预存 `_singleton`，不再每次取 bean 都算 `scope.isSingleton`；`bean` ns/op **72.50 → 57.09（-21%）**、自定义 scope 实例 **329.33 → 60.62（-82%）**，见 `bug-bean.md` §2.18）⇒ **f_bean 中危清零**，剩 §3 的 9 条低危/待验证。
> 十三次修正（2026-10-05）：§3.1 `BEAN-L9` 判为 ❌**不成立**（`beanTypeMap.get(TypeInfo.of<T>())` 的桶只含 `T` 的子类型 ⇒ 「缺前置校验」无对象），见 `bug-bean.md` §3.1 ⇒ f_bean 待修 9 → 8 条。
> 十四次修正（2026-10-05）：§3.1 `BEAN-L2` 判为 ❌**不成立（设计）**（只有 singleton 由 BeanFactory 管全生命周期并调 destroy；永不清理 BeanFactory 的集合）、`BEAN-L3` ⏸保持现状（同族设计）；`BEAN-L6` 修法确定为「整条注解分支删除」（`annotationMap` 无任何读方 + 不开放注解 bean 功能），顺带覆盖 `BEAN-L7` ⇒ f_bean 待修 8 → 6 条，见 `bug-bean.md` §3.1。
> 十五次修正（2026-10-05，**更正十四次修正里的 L6 结论**）：`annotationMap` 是**面向应用项目**的特性（`f_bean/README.md:5`：「使用修饰bean的类型的注解，以及父类型的注解获取bean」），**不删** —— 本仓无调用方不等于死代码；L6 改判 ⏸保持现状（成本仅在注册期一次）。**同时记录一条待作者确认的新发现**：`annotationMap` 只写不读，README:5 描述的能力目前没有可用查询入口（所有查询只查 `beanTypeMap`）。⇒ f_bean 待修 5 条（`L1`/`L4`/`L5`/`L7` + 待验证的 `L8`）。
> 十六次修正（2026-10-05）：§3.1 `BEAN-L7` 已修复（注册循环体里的局部闭包换成无捕获静态函数 `wrapType`；探针 ns/节点 **51.97 → 37.12（-28.6%）**，每 bean 省 ~45~90 ns 的注册期开销；注解能力不受影响），见 `bug-bean.md` §3.1 ⇒ f_bean 待修 4 条（`L1`/`L4`/`L5` + 待验证的 `L8`）。
> 十七次修正（2026-10-05）：§3.1 `BEAN-L4` 按作者决定 ⏸**保持现状**（惰性化会减少 prototype bean 的实例化次数，属可见行为差异 ⇒ 行为不变优先；权衡与附带留档已写入条目），见 `bug-bean.md` §3.1 ⇒ f_bean 待修 3 条（`L1`/`L5` + 待验证的 `L8`）。
> 十八次修正（2026-10-05）：§3.1 `BEAN-L5` 已修复（`lookupHashSet`/`lookupTreeSet` 改为直接向目标集合填充，去掉中间 `ArrayList`；同进程对照归一后 **hashSet -18.3%、treeSet -27.2%**，实例化次数与语义不变、仅 debug 日志少 N 行），见 `bug-bean.md` §3.1 ⇒ f_bean 待修 2 条（`L1` + 待验证的 `L8`）。
> 十九次修正（2026-10-05）：f_bean **API 卫生**按用户决定「只文档化、不改签名」落地 —— `f_bean/README.md` 新增「形参风格（两层约定）」小节（低层 `BeanFactory` 的 `cond` 命名 + `beanType` 位置、上层 `lookup*` 全位置 + 0 参重载；约定新增 API 走上层风格），公开函数名拼写（`lookupOptionLable`）与 4 处 README 文档错误留档不改，见 `bug-bean.md` §3.1 节末「API 卫生」（代码零改动）。
> 二十次修正（2026-10-05）：§3.1 `BEAN-L10` 已修复（`getList`/`getMap`/`getAllTuples` 去掉私有收集器 `getAll(cond, put)` 的 per-element 闭包，改为循环内直接收集；**同结构对照 9495.48 → 9261.68 ns/op，省 233.80 ns/次（-2.46%）**；口径更正：本次只消掉「闭包分配 + 间接调用」两笔，`ArrayList` 扩容、逐元素 `beanLog`、结果容器均保留），并顺带修 `f_bean/README.md` 4 处文档错误（`lookupTreeSet` 签名写成 `HashSet`、`lookupLables` 拼写、`ComparableW>`、`lookupOption<T>(cond)` 的描述）⇒ f_bean 待修仍 2 条（`L1` + 待验证的 `L8`）。**另记一条新发现（未立条、待作者定）**：逐元素 `beanLog` ≈ **325~349 ns/元素**（本环境 debug 关闭、日志 0 行）⇒ `lookupList` +42%、`lookupHashMap` +32%，比本条大 ~15 倍；候选修法见 `bug-bean.md` §3.1 `BEAN-L10` 条目末。
> 二十一次修正（2026-10-05）：§3.1 新增 **`BEAN-L11`**（逐元素 `beanLog` ≈ 325~349 ns/元素，debug 关闭时仍付；`lookupList` +42%、`lookupHashMap` +32%）—— 按作者决定 ⏸**保持现状**（候选修法已留档：去掉逐元素日志 / 用 `log.debugEnabled` 前置判定），见 `bug-bean.md` §3.1 ⇒ f_bean 待修仍 2 条（`L1` + 待验证的 `L8`）。
> 二十二次修正（2026-10-05）：§3.2 `BEAN-L8` 判为 ❌**不成立**（部署方约定：请求晚于 initializer ⇒ 启动初始化与首次请求不并发，`initIfNeed` 的无条件 `store` 与 `bean` getter 的双检不构成竞态），见 `bug-bean.md` §3.2 ⇒ f_bean 待修 1 条（`BEAN-L1`）。顺带修 `f_bean/README.md:264` 小节标题拼写（`BeanBef` → `BeanDef`）。
> 二十三次修正（2026-10-05）：§3.1 `BEAN-L1` 收口 —— **(a) 判为不可达并已回滚**（`case (IgnoreType, IgnoreName)` 的 `IgnoreName` 是模式变量绑定 ⇒ catch-all ⇒ `IgnoreType` 组合一律 `return true`，快路径落不到；实测去掉恒真判定收益 -38.6 ns ≈ 0），**(b) 已实施**（清理阶段只在移除成功时记账；定向运行：`afterRegistered()` 前 1 → 后 0，两张表清理且不留空键）；**同时新发现缺陷 `BEAN-L12`**（`IgnoreType` 组合的名条件/count/scope 被静默忽略 ⇒ 属行为变更、待作者拍板），见 `bug-bean.md` §3.1 ⇒ f_bean 待修 1 条（`BEAN-L12`）。
> 二十四次修正（2026-10-06）：§3.1 `BEAN-L12` 已修复（**方案 F1**：`case (IgnoreType, IgnoreName)` → `case (IgnoreType, IgnoreCond)`；`IgnoreName` 曾是模式变量绑定 ⇒ catch-all 吃掉名条件/count/scope。本意经作者确认：**类型与名字都是 Ignore 时其余条件一并忽略** ⇒ 无条件真；其余组合走真实筛选）。RED→GREEN：谓词 **true → false**；端到端（真 `BeanDef` 条件 + 显式 `afterRegistered()`）`BeanDefDiscarded` **1 → 0**、样本未被误删；全套 **TOTAL 25 / PASSED 25 / ERROR 0 / FAILED 0**、`cjpm build` exit 0。`BEAN-L1(a)` 快路径已可达但收益 ≈ 0 ⇒ 不复活；同类模式绑定嗅探仅此一处（其余为外部枚举 case 误报）。见 `bug-bean.md` §3.1 ⇒ **f_bean 待修 0 条**。
> 二十五次修正（2026-10-06）：§3.1 `BEAN-L6` 的待确认项**已了结** —— 按作者指示补齐「按注解取 bean」入口（分支 `fix/bean-anno`）：`BeanFactory.getFirstByAnnotation`／`getListByAnnotation`／`getMapByAnnotation<T, A> where T <: Object, A <: Annotation` + `lookup.cj` 的 `lookupByAnnotation`／`lookupListByAnnotation`／`lookupMapByAnnotation`；候选 = `annotationMap[TypeInfo.of<A>()]` 桶（自身/父类/接口/元注解链），逐元素真实类型判定 + `cond`，顺序同注解桶、map 以 bean 名为 KEY、未命中类型的 prototype 不实例化。新增用例 6 条；全套 **TOTAL 31 / PASSED 31 / ERROR 0 / FAILED 0**、`cjpm build` exit 0；README 新增「按注解获取bean」小节（能力声明不再超前）。
> 二十六次修正（2026-10-06）：§3.1 `BEAN-L6` 其二 —— ① 加 `lookupOptionByAnnotation`（`?T` 变体）；② **更正二十五次修正里的不实描述并真正实现元注解链**：`doRegister` 的类型队列原先只让**类节点**展开 `annotations`（注解节点被 `if (isClass && …)` 挡住）⇒ 元注解**没**进 `annotationMap`；本次改为 `!isClass || !白名单` 并加节点去重（防「A 注解 B、B 注解 A」在注册期死循环）⇒ 元注解链成立。新增用例 1 条（`bean_annotation_meta_test.cj`）⇒ 全套 **TOTAL 32 / PASSED 32 / ERROR 0 / FAILED 0**、`cjpm build` exit 0。
> 二十七次修正（2026-10-06）：§3.1 `BEAN-L6` 其三 —— 补「**只限制注解、不限制 bean 类型**」的 API。仓颉不允许「同名 + 仅泛型参数个数不同」的重载（实测 15 处 `overload conflicts`）⇒ 另起名 **`*ByAnnotationOnly`**：`BeanFactory.getFirstByAnnotationOnly`/`getListByAnnotationOnly`/`getMapByAnnotationOnly<A> where A <: Annotation` + `lookupByAnnotationOnly`/`lookupOptionByAnnotationOnly`/`lookupListByAnnotationOnly`/`lookupMapByAnnotationOnly`（各 0 参 + `cond` 重载）；内部复用私有实现并传 `T = Object` ⇒ 零新增遍历代码、语义与 `…<Object, A>` 一致（用例断言相等）。新增用例 1 条 ⇒ 全套 **TOTAL 33 / PASSED 33 / ERROR 0 / FAILED 0**、`cjpm build` exit 0；README 新增「只限制注解、不限制bean类型」小节。**已并入 `sts/1.3.x`**：分支 `fix/bean-anno`（worktree `.worktrees/bean-anno`）经 **fast-forward** 合入（`0dc0518b..03b537d5`，7 文件 +634/−4，**无合并提交**）；同族的其二/其三（`lookupOptionByAnnotation`、元注解链、`*ByAnnotationOnly`）一并合入，worktree 与分支已删除。

**建议修复顺序**（即严重级内部的落地顺序）：

1. `ORM-1`（§1.1）结果缓存键退化 —— 事务内可能返回**别的参数**的查询结果（静默错数据）　**✅已修复（2026-10-04，见 §1.1 修复标记）**
2. `X-1`（§1.2）`TypeInfos.get(String)` 无限递归 —— 波及 14 处调用（f_bean 条件装配、f_aspect 三条规则、f_orm 一处）　**✅已修复（2026-10-04，见 §1.2 修复标记）**
3. `ASP-2`（§1.4）切面链共享参数槽 —— 并发下参数互串（原先并列的 `ASP-1`/§1.3 已于 2026-10-04 判定为**误判**：链按类型缓存、链尾固化首次 `callee` 是设计目的，非缺陷）　**✅已修复（2026-10-04，见 §1.4 修复标记）**
4. `ORM-C1`（§1.5）`iterator` 返回前结果集已被关闭 —— 真实驱动下不可用　**✅已修复（2026-10-04，见 §1.5 修复标记）**
5. `ASP-4`/`ASP-5`（§1.6/§1.7）参数注解规则越界崩溃 / 恒不织入　**ASP-4 ✅已修复（2026-10-04，见 §1.6 修复标记）；ASP-5 ✅已修复（2026-10-05，见 §1.7 修复标记）**
6. `BEAN-1`（§1.8）宏生成不存在的 `lookupSet` —— `HashSet`/`Set` 形参直接编译失败　**✅已修复（2026-10-05，见 §1.8 修复标记）**
7. `MVC-4`（§1.9）`download` 输出整块缓冲 —— 下载内容损坏　**✅已修复（2026-10-05，见 §1.9 修复标记）**
8. `MVC-1`/`MVC-3`（§1.10/§1.11）静态资源缓存无界（含 404 负缓存）/ WS ping Timer 每断链泄漏一个周期任务　**MVC-1 ❌误判（2026-10-05：无上限是设计目的、负缓存不成立，见 §1.10）；MVC-3 ✅已修复（2026-10-05，见 §1.11 修复标记）**
9. `ORM-2`（§1.13）逐单元格运行时类型分派 —— 行×列频率的热路径开销　**✅已修复（2026-10-05，见 §1.13 修复标记）**
9. `MVC-2`（§1.12）`accessLog` 每请求无条件序列化全部参数与返回值　**✅已修复（2026-10-05，见 §1.12 修复标记）**

### 编号索引（原 §x.y → 所在文件）

| 原编号 | 模块（编号前缀） | 严重 | 中 | 低危 + 待验证 | 文件 |
|---|---|---|---|---|---|
| §1.1、§1.5、§1.13；§2.1、§2.8、§2.10–§2.14；§3（`ORM-*`）；§4.1 | f_orm（`ORM-x`） | 3 | 7 | 14 | `bug-orm.md` |
| §1.9–§1.12；§2.2、§2.3、§2.5–§2.7、§2.19–§2.21；§3（`MVC-*`）；§4.2 | f_mvc（`MVC-x`） | 4 | 8 | 13 | `bug-mvc.md` |
| §1.8；§2.15–§2.18；§3（`BEAN-*`，含新增 `BEAN-L10`/`BEAN-L11`/`BEAN-L12`）；§4.3 | f_bean（`BEAN-x`） | 1 | 4 | 12 | `bug-bean.md` |
| §1.3、§1.4、§1.6、§1.7、§1.14；§2.4、§2.9、§2.22、§2.23；§3（`ASP-*`）；§4.4 | f_aspect（`ASP-x`） | 5 | 4 | 8 | `bug-aspect.md` |
| §1.2、§2.24 | 跨模块（`X-x`；f_base / f_data+f_config） | 1 | 1 | 0 | `bug-cross.md` |

> 代码注释里引用的 `bug.md §1.1`（`ORM-1`）、`§1.5`（`ORM-C1`）、`§1.11`（`MVC-3`）、`§1.4`（`ASP-2`）等，按上表到对应模块文件中查同号条目；旧编号段内的其它编号同理。

## 5. 基线与验证状态

- 基线脚本：`cjpm build` + `cjpm test --no-capture-output`，模块顺序 `f_bean → f_aspect → f_mvc → f_orm`（日志 `/tmp/review_baseline.log`、`/tmp/bl_<模块>_{build,test}.log`）。
- 已完成：`f_bean` 的 `cjpm build` **exit 0**（0 条 error）。`f_bean` 的 `cjpm test` 长时间停留在**测试编译阶段**（编译 f_util 等测试依赖，非卡死），`f_aspect/f_mvc/f_orm` 尚未开始 ⇒ 本次审查未拿到 `cjpm test` 结果；本报告结论均来自代码阅读，不依赖该基线。
- 修复期验证（2026-10-04，本分支上的修复提交）：`f_orm` 的 `cjpm build` **exit 0**；`cjpm test` **TOTAL 33 / PASSED 32 / ERROR 1 / FAILED 0**。唯一 ERROR 是既有环境相关用例 `f_orm.wrap / ORMConfigTest.testPoolMaxWaiting`（用例先 `Config.set(key, '45s')` 再断言读出 45s，本机 `left: 4s` ⇒ 环境里该配置项已存在并压过内存设置；该用例不执行 SQL，与修复路径无交集）。本次修复新增的 5 条用例 **5/5 PASSED**（同一套用例在修复前对照跑为 **5/5 FAILED**），逐条记录见 §1.5 / §2.1。
- 修复期验证（2026-10-05，`fix/orm` 分支，§1.13 `ORM-2`）：`f_orm` 的 `cjpm build` **exit 0**；`cjpm test` **TOTAL 38 / PASSED 37 / ERROR 1 / FAILED 0**（新增 `QueryResultWrap_test.cj` 5 条 **5/5 PASSED**；把 `QueryResultWrap.cj` 临时还原为 HEAD 后同一套用例仍 **5/5 PASSED** —— 本条是性能整改，语义必须不变）。唯一 ERROR 仍是既有环境相关 `ORMConfigTest.testPoolMaxWaiting`。该条的计时前后对照与「mock 口径无差异、真实驱动收益待 `ORM-L3` 验证」的结论记在 §1.13 修复记录里（探针 `.autocode/tmp/orm2_mapList_bench.cj`，拷回 `f_orm/src/base/` 可复跑）。
- 修复期验证（2026-10-05，`fix/orm` 分支，§2.12 `ORM-5`）：`cjpm build` **exit 0**；`cjpm test` **TOTAL 52 / PASSED 51 / ERROR 1 / FAILED 0**（新增 `ConditionTrim_test.cj` 7 条 **7/7 PASSED**；唯一 ERROR 仍是既有环境相关 `ORMConfigTest.testPoolMaxWaiting`）。前后对照（同一 118 行输出矩阵逐字符一致）与计时（trim ≈1.7×、`emptyLogicalExpr` ≈14.8×）记在 §2.12 修复记录里，探针 `.autocode/tmp/orm5_probe_test.cj` 可复跑。
- 误判/文档期验证（2026-10-05，`fix/orm` 分支，§2.8 `ORM-C5`）：`cjpm test` **TOTAL 45 / PASSED 44 / ERROR 1 / FAILED 0**（新增 `ArgInSql_test.cj` 7 条 **7/7 PASSED**；唯一 ERROR 仍是既有环境相关 `ORMConfigTest.testPoolMaxWaiting`）。README 新增 §11.5 并按真实绑定口径写明 `argInSql` 的三种结果与边界。
- 本报告未做**运行时实测**（无 benchmark、无 heap profile）。凡标「**待验证**」的条目都给出了验证方法（见 §3.2），另补几条高危项的复现方式：
  - `ORM-1`：同一 executor 上「同 SQL、不同参数」两次查询，断言结果不同（✅ 已由 `SqlResultCache_test.cj` 落地，见 §1.1）；
  - `ORM-C1`：真实驱动（postgres/mysql）下取回 `iterator` 后逐行读，观察 `close()` 后行为（✅ 所有权/关闭语义已由 `QueryResultIterator_test.cj` 在 mock 上钉死，见 §1.5；真实驱动的 `next()` 仍未实测）；
  - `BEAN-1`：写一个含 `HashSet<T>` 形参的 `@Bean`+`@Constructor` 类，编译即见未定义符号；
  - `ASP-4`/`ASP-5`：按 `AspectRoute.cj:311-317` 的文档示例写规则，观察崩溃/不织入；
  - `X-1`：`TypeInfos.get("a.b.C")` 单测。

## 6. 审查方法与备注

- 方法：4 个模块并行全文通读（含 `macros` 子包），按「性能（复杂度/集合/分配/字符串/闭包/同步/IO/CFFI/数据表示/背压）+ 内存（堆与 RSS/临时对象/集合容量/缓存/大对象/对象图/闭包/线程/Resource/CFFI）」两套清单取证；每条结论要求 `文件:行号` + 证据片段 + 调用频率判断 + 修法，再对全部「严重」级条目回到源码逐行复核。
- 编排：按严重程度降序，模块归属用编号前缀表示；同一处问题若同时涉及性能与正确性，只在最高危那一处详述，其它位置用编号交叉引用（如 `MVC-4` 即原 `MVC-C1`），不重复计数。
- 本次审查**只读**，未改动这 4 个模块的任何代码（后续修复与误判判定见 §0 的修复时间线）；报告按模块拆分后落在 `.autocode/bugs/bug-{orm,mvc,bean,aspect,cross}.md`，本文件为索引。
