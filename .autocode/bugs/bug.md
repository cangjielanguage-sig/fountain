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
> 二十五次修正（2026-10-06）：新条目 `MVC-13` 已修复（`fix/mvc-rest`，用户选「③ 打通」）：`MultiRequestMethodHandler.handle` 在方法/Content-Type 查表前先判 `GET + isWebSocketUpgrade(headers)`（新接缝：`Upgrade` 头含 `websocket`，忽略大小写），命中则取 `metas.get(RequestMethod.WS)` 并用**单参** `check(wsMeta).handle(ctx)` 处理 —— 握手请求没有 Content-Type，而 WS meta 的 `consumes`/`produces` 是 `'*'`，走双参 `check(metas)` 会因 `map.get('')` 落空误判 **415**。该分流依赖已修的 `MVC-L12`（`(WS, WS)` 的 `==`，否则 `metas.get(WS)` 必落空）。行为变化仅限「GET + `Upgrade: websocket` 且该路径注册了 WS 端点」（修前 405 → 现进入 WS meta：`WSMeta.upgrade` → `exec`）；无 Upgrade 头或路径无 WS 端点的请求完全不变。RED/GREEN：`MultiRequestMethodHandler_test.testIsWebSocketUpgrade`（`websocket`/`WebSocket` ⇒ true，`h2c`/缺失 ⇒ false）修前失败（`right: false`）→ 实现接缝后 **`TOTAL 29 / PASSED 29`**，同轮 `cjpm build` exit 0。**未覆盖**：①端到端（WS 客户端应收到 101 而非 405）需真实服务 + WS 客户端，f_mvc 单测造不出 `HttpContext`；②只做路由分流，握手合法性仍由 stdx 校验；③顺带观察（未处理）：WS 路径的 `handle_`（`RequestMeta.setHandle(wsmeta:)`）没有 HTTP 路径那样的 `CurrentHttpContext.set/clear` 与 `clearResponseStatus`/`OverallStopwatch.clearStart` 收尾。
> 二十四次修正（2026-10-06）：§3.1 剩余 6 条（`MVC-L9`/`L2`/`L3`/`L4`/`L6`/`L10`）按分诊判定为 ❌**不改**（用户 2026-10-06 采纳），逐条理由见 §3.1 判定标记（C 桶）；同时把此前顺带发现的 **WS 端点路由可达性**问题立为新条目 **`MVC-13`**（§3.2 待验证）：WS meta 只注册在 `WS` 键下（`HttpRequestDistributorImpl.cj:36`）而握手请求是 `GET`（`MultiRequestMethodHandler.cj:64/91`）⇒ 代码路径上匹配不到、落到 `:111` 的 405；全仓无 `@WSEndPoint` 示例/文档/端到端用例 ⇒ f_mvc 唯一待验证项为 `MVC-13`。
> 二十三次修正（2026-10-06）：`MVC-C6`(b) 与 `MVC-L11` 已修复（`fix/mvc-rest`，同一提交）。`MVC-L11`：空结果（`DataUnit`/`DataNone`）不再因「具体 Accept（不含 `*/*`）」判 406 —— 改为「原状态码 + 按 Accept 声明 Content-Type + 空体」（仅 `Accept: ''` 异常值仍 406）；修前会把 `MVCBreakingCommand(status)`（默认 `DataUnit.UNIT`，如 `ControllerFuncParam` 的 415）的状态码吞成 406（调用链：`ControllerFuncParam.cj:192` → `BreakingCommand.cj:23` → `RequestMeta.cj:220` → `respond<Data>`），`MVC-C3` 的用例只断言到 `MVCBreakingCommand` 层，故此前未暴露。`MVC-C6`(b)：数据帧无对应 meta / 上一条载荷未消费完，从「每条消息抛异常 → catch → 会话继续」改为**首帧即关**（新增接缝 `dataFrameCloseReason` + `log.error` + `ws.closeConn()` + `return true`，并删除被取代的 `throw`）。RED/GREEN：`testEmptyResultBranches` 与 `testDataFrameCloseReason` 各失败 1 条（`TOTAL 28 / PASSED 26 / FAILED 2`）→ 全绿 **28/28**。⇒ f_mvc 剩 §3.1 的 `MVC-L2`/`L3`/`L4`/`L6`/`L9`/`L10`（6 条，按分诊为不改，待用户口径）。

**建议修复顺序**（即严重级内部的落地顺序）：

1. `ORM-1`（§1.1）结果缓存键退化 —— 事务内可能返回**别的参数**的查询结果（静默错数据）　**✅已修复（2026-10-04，见 §1.1 修复标记）**
2. `X-1`（§1.2）`TypeInfos.get(String)` 无限递归 —— 波及 14 处调用（f_bean 条件装配、f_aspect 三条规则、f_orm 一处）　**✅已修复（2026-10-04，见 §1.2 修复标记）**
3. `ASP-2`（§1.4）切面链共享参数槽 —— 并发下参数互串（原先并列的 `ASP-1`/§1.3 已于 2026-10-04 判定为**误判**：链按类型缓存、链尾固化首次 `callee` 是设计目的，非缺陷）　**✅已修复（2026-10-04，见 §1.4 修复标记）**
4. `ORM-C1`（§1.5）`iterator` 返回前结果集已被关闭 —— 真实驱动下不可用　**✅已修复（2026-10-04，见 §1.5 修复标记）**
5. `ASP-4`/`ASP-5`（§1.6/§1.7）参数注解规则越界崩溃 / 恒不织入　**ASP-4 ✅已修复（2026-10-04，见 §1.6 修复标记）；ASP-5 ✅已修复（2026-10-05，见 §1.7 修复标记）**
6. `BEAN-1`（§1.8）宏生成不存在的 `lookupSet` —— `HashSet`/`Set` 形参直接编译失败　**✅已修复（2026-10-05，见 §1.8 修复标记）**
7. `MVC-4`（§1.9）`download` 输出整块缓冲 —— 下载内容损坏　**✅已修复（2026-10-05，见 §1.9 修复标记）**
8. `MVC-1`/`MVC-3`（§1.10/§1.11）静态资源缓存无界（含 404 负缓存）/ WS ping Timer 每断链泄漏一个周期任务　**MVC-1 ❌误判（2026-10-05：无上限是设计目的、负缓存不成立，见 §1.10）；MVC-3 ✅已修复（2026-10-05，见 §1.11 修复标记）**
9. `MVC-2`（§1.12）`accessLog` 每请求无条件序列化全部参数与返回值　**✅已修复（2026-10-05，见 §1.12 修复标记）**

### 编号索引（原 §x.y → 所在文件）

| 原编号 | 模块（编号前缀） | 严重 | 中 | 低危 + 待验证 | 文件 |
|---|---|---|---|---|---|
| §1.1、§1.5、§1.13；§2.1、§2.8、§2.10–§2.14；§3（`ORM-*`）；§4.1 | f_orm（`ORM-x`） | 3 | 7 | 14 | `bug-orm.md` |
| §1.9–§1.12；§2.2、§2.3、§2.5–§2.7、§2.19–§2.21；§3（`MVC-*`）；§4.2 | f_mvc（`MVC-x`） | 4 | 8 | 13 | `bug-mvc.md` |
| §1.8；§2.15–§2.18；§3（`BEAN-*`）；§4.3 | f_bean（`BEAN-x`） | 1 | 4 | 9 | `bug-bean.md` |
| §1.3、§1.4、§1.6、§1.7、§1.14；§2.4、§2.9、§2.22、§2.23；§3（`ASP-*`）；§4.4 | f_aspect（`ASP-x`） | 5 | 4 | 8 | `bug-aspect.md` |
| §1.2、§2.24 | 跨模块（`X-x`；f_base / f_data+f_config） | 1 | 1 | 0 | `bug-cross.md` |

> 代码注释里引用的 `bug.md §1.1`（`ORM-1`）、`§1.5`（`ORM-C1`）、`§1.11`（`MVC-3`）、`§1.4`（`ASP-2`）等，按上表到对应模块文件中查同号条目；旧编号段内的其它编号同理。

## 5. 基线与验证状态

- 基线脚本：`cjpm build` + `cjpm test --no-capture-output`，模块顺序 `f_bean → f_aspect → f_mvc → f_orm`（日志 `/tmp/review_baseline.log`、`/tmp/bl_<模块>_{build,test}.log`）。
- 已完成：`f_bean` 的 `cjpm build` **exit 0**（0 条 error）。`f_bean` 的 `cjpm test` 长时间停留在**测试编译阶段**（编译 f_util 等测试依赖，非卡死），`f_aspect/f_mvc/f_orm` 尚未开始 ⇒ 本次审查未拿到 `cjpm test` 结果；本报告结论均来自代码阅读，不依赖该基线。
- 修复期验证（2026-10-04，本分支上的修复提交）：`f_orm` 的 `cjpm build` **exit 0**；`cjpm test` **TOTAL 33 / PASSED 32 / ERROR 1 / FAILED 0**。唯一 ERROR 是既有环境相关用例 `f_orm.wrap / ORMConfigTest.testPoolMaxWaiting`（用例先 `Config.set(key, '45s')` 再断言读出 45s，本机 `left: 4s` ⇒ 环境里该配置项已存在并压过内存设置；该用例不执行 SQL，与修复路径无交集）。本次修复新增的 5 条用例 **5/5 PASSED**（同一套用例在修复前对照跑为 **5/5 FAILED**），逐条记录见 §1.5 / §2.1。
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
