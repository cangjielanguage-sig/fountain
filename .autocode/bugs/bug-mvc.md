# f_mvc 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 25 条**：严重 4（§1.9 `MVC-4`、§1.10 `MVC-1`、§1.11 `MVC-3`、§1.12 `MVC-2`）、中 8（§2.2 `MVC-C3`、§2.3 `MVC-C5`、§2.5 `MVC-C2`、§2.6 `MVC-8`、§2.7 `MVC-6`、§2.19 `MVC-5`、§2.20 `MVC-7`、§2.21 `MVC-9`）、低危+待验证 13（§3）。
- **状态（截至 2026-10-05）**：`MVC-4` ✅已修复（§1.9，`fix/mvc-4`，已并入 `sts/1.3.x`）；`MVC-1` ❌误判（§1.10，非缺陷：静态资源常驻是设计目的、`view.value = None` 实为删除条目）；`MVC-3` ✅已修复（§1.11，`fix/mvc-3`，已并入 `sts/1.3.x`）；`MVC-2` ✅已修复（§1.12，`fix/mvc-rest`）；`MVC-C3` ✅已修复（§2.2，`fix/mvc-rest`）；`MVC-C5` ✅已修复（§2.3，`fix/mvc-rest`）；`MVC-C2` ✅已修复（§2.5，`fix/mvc-rest`，潜在问题、防御性修复）；`MVC-8` ✅已修复（§2.6，`fix/mvc-rest`）；`MVC-6` ❌误判（§2.7，用户判定非缺陷：WS 消息总长上限属端点/部署侧策略，不设硬上限是设计选择）；`MVC-5` ❌不改（§2.19，用户判定「不值得改」：全仓 `@PathVariable` 均为单变量、暴露面为零）；`MVC-7` ✅已修复（§2.20，`fix/mvc-rest`，范围：只改 `RequestMethod.hashCode()`）；`MVC-9` ❌不改（§2.21，用户判定：每请求从 IoC 取 controller 实例是设计语义 —— 允许 controller 定义为 `prototype`，缓存实例会破坏它）；`MVC-L8`/`MVC-L1`/`MVC-C6`(a)/`MVC-L5` ✅已加固（§3.1，`fix/mvc-rest`）；`MVC-L7` ❌不改（§3.1，用户判定 C：成本仅注册期毫秒级，且源头是只写不读的 `RequestMetas`）；`MVC-L12` ✅已修复（§3.2，`fix/mvc-rest`）；`MVC-C6`(b)（§3.1）与 `MVC-L11`（§3.2）✅已修复（同一提交，`fix/mvc-rest`）；**待处理** §3.1 的 `MVC-L2`/`L3`/`L4`/`L6`/`L9`/`L10`（6 条，按分诊为不改，待用户口径）（**§1 严重级、§2 中危均已清零**）。

## 1. 严重（本模块 4 条）

### 1.9 [严重｜正确性] `MVC-4` `download` 写出整个缓冲，而不是实际读到的长度（f_mvc）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-4`（worktree `.worktrees/mvc-4`，基线 `a435d58d`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-4 download 只写出实际读到的长度，缓冲改用 MVCConfig.downloadBufferSize（§1.9）`）。

- 改动：`f_mvc/src/ResponseDownload.cj` —— 两处循环（`:44-47` 多流重载、`:62-65` `Array<File>` 重载）抽出为包内 `copy(input: InputStream, write: (Array<Byte>) -> Unit)`（顺带去重复），`write(buf)` → `write(buf[0..bytes])`、缓冲分配提到循环外、大小改用 `MVCConfig.downloadBufferSize`（与同模块正确写法 `FileDownload.cj:54-58` 对齐）。
- 用例：`f_mvc/src/response_download_test.cj`（`package fountain::f_mvc`，与源文件同包以便调用包内 `copy`；沿用 `f_base/src/Comparator_test.cj` 的同包测试约定）—— `testCopyWritesOnlyReadBytes`：19997 字节（非 1024/4096/8192 整数倍）源、逐字节可预测，用内存收集器断言「写出总长 == 源长、逐字节一致」；`testCopyEmptyInput`：空流写出 0 字节。
- 测量证据：**修前**（`copy` 仍是 `write(buf)` + 1024 缓冲）`cjpm test` → `[ FAILED ] CASE: testCopyWritesOnlyReadBytes`，`Assert Failed: (written.value == size)`，**left: 20480**（= 20×1024）、**right: 19997**，`PASSED: 1, FAILED: 1`、`EXIT=1`（20480 正是「每块多写 缓冲大小−实读」在 1024 缓冲下的结果，随缓冲大小线性放大：默认 4096 时每块多写 4096−实读）。**修后** → `[ PASSED ] testCopyWritesOnlyReadBytes`、`[ PASSED ] testCopyEmptyInput`，`PASSED: 2, FAILED: 0, ERROR: 0`、`cjpm test success`；另跑 `cjpm build`（f_mvc 库）`BUILD EXIT=0`，确认 `*_test.cj` 不进正常构建。
- 未覆盖：真端到端（HTTP 响应里的多流/多文件下载）未跑 —— `FileDownload` 构造期即取 `CurrentHttpContext.instance`，且 f_mvc 无测试基建；本用例覆盖缺陷所在的复制语义，两个下载重载共用该函数。

位置：`src/ResponseDownload.cj:44-47, 62-65`

```cangjie
// ResponseDownload.cj:44-47
let buf = Array<Byte>(1024, repeat: 0)
while(let bytes <- d[0].read(buf) && bytes > 0){
    fd.write(buf)          // ← bytes 只用于判断，写的是全部 1024 字节
}
```

影响：多文件/多流下载时，除最后一块外的每一块都会多输出「脏尾部」（`read` 只填充 `bytes` 字节，其余是 0 或上一轮残留）⇒ 下载内容长度与内容都错。同文件 `src/FileDownload.cj:57-59` 是正确的 `buf[0..len]` 写法，可直接对齐。修法：`fd.write(buf[0..bytes])`，并把缓冲分配移到循环外、改用 `MVCConfig.downloadBufferSize`。

### 1.10 [误判｜非缺陷] `MVC-1` 静态资源缓存「无上限、且不存在也建条目（负缓存）」（f_mvc）✓已复核 → ❌误判（2026-10-05：前者是设计目的，后者不成立）

**❌ 误判标记（2026-10-05）**：本条目整体判定为**误判、非缺陷**，不进入修复队列：

1. **「负缓存」不成立**：`std.collection` 的 `MapEntryView.value` 文档（`collection_package_interface.md:478-480`）写明「设置为 `None` 时，则会删除当前 Entry」；首次未命中时 `entryView` 给出的是该 key 的**空视图**，对它设 `None` 是空操作 ⇒ `RequestMeta.cj:122` 的 `view.value = None` 是**删除 / 保持无条目**，404 不会在表里留下任何东西，反而顺带做到了「文件消失后清掉旧条目」。原文「任何扫 404 的流量都会以每路径一条增长」作废。
2. **「无上限」是设计目的**：静态文件就是要「读入内存后一直驻留」，不做 TTL、不做淘汰；键是「去前导 '/' 的请求路径」、且不存在/目录不落条目 ⇒ 条目集合 ⊆ 现存静态文件，规模由部署决定。经用户 2026-10-05 确认：**保持 `sts/1.3.x` 的 `loadStaticResource` 原样**，不引入 LRU 或新的类型声明。
3. **一度按审查意见写过的 `StaticResourceCache`（有界 LRU + `mvc_staticResourceCacheSize` 配置位 + `RequestMeta` 接线）已在动手阶段全部回退**（本分支不包含这些改动，`MVCConfig.cj`/`RequestMeta.cj` 与 `sts/1.3.x` 一致）。
4. 另记一笔（**独立于本条目、未单列、待验证**）：审查时注意到请求路径未做 `..`/符号链接规范化，`STATIC_RESOURCE_ROOT.join` 后直接 `exists`/读取，理论上可指向静态根之外的可读文件——这属于「路径规范化」问题而非缓存问题，用户本次未要求跟进。

**以下为审查时的原始判断（已作废，留档对照）**：

位置：`src/RequestMeta.cj:24, 96-124`

```cangjie
// RequestMeta.cj:97    staticResourceBytes.entryView(path){view => ...
// RequestMeta.cj:113-119  view.value = if(let Some((last,_)) <- view.value && last < lastModified){ (lastModified, File.readFrom(p)) } ...
// RequestMeta.cj:122  }else{ view.value = None }     // 文件不存在：照样落一个条目
```

影响：键来自**请求路径**，无容量上限、无 TTL、无淘汰；命中后整文件 `Array<Byte>` 常驻。任何扫 404 的流量（爬虫、探测）都会以「每路径一条」的速度让这张表增长，并且 404 也会建条目。修法：改成有上限的 LRU/TTL 缓存，且只在「存在且为普通文件」时写条目（不存在不要落盘）。

### 1.11 [严重｜内存] `MVC-3` WS 的 ping `Timer` 只在收到 Close 帧时取消（f_mvc）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-3`（worktree `.worktrees/mvc-3`，基线 `sts/1.3.x` 的 `41c2df49`），代码与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-3 ping 定时器在 WS 读循环的 finally 里取消（§1.11）；并记录 §1.10 MVC-1 误判`）。

- 改动（两个提交，同属本条目）：①`WSMeta.exec` 的读帧循环改为调用新抽出的包内接缝 `pumpFrames`（见下），退出路径统一在 `finally` 里 `timer?.cancel()`，删掉原来只写在 `case CloseWebFrame` 的那一句；②**加固**（用户提出）：ping 回调里的 `ws.writePingFrame(h(...))` 包 `try/catch(_:Exception)`——stdx 契约明确「`closeConn` 关闭连接后调用写，抛出异常」，包一层可避免异常抛进定时器线程。
- **stdx 契约更正**：`WebSocket.read(): WebSocketFrame`（**非 Option**），连接结束时不是「返回 None」，而是**抛异常**（`ConnectionException`（对端已关闭连接）/ `SocketException` / `WebSocketException`，见 stdx.net.http 的 `WebSocket.read` 文档）。真实退出路径是：① 收到 Close 帧（`onFrame` 返回 true ⇒ 正常 `return`）；② 对端断开/连接被关（`read` 抛异常 ⇒ 穿出循环，经 `finally` 取消后继续向外传播）；③ 处理帧时抛出的异常（每帧的 `try/catch` 只吞「处理帧」的异常，`read` 的异常不吞）。原文「read 返回 None，落到循环之外」作废。
- **用例（B 方案：可测接缝）**：`f_mvc/src/WSMeta_test.cj`（新增，f_mvc 首个测试文件）。把「建定时器 + 读帧循环 + 退出取消」抽成 `WSMeta.cj` 的包内函数 `pumpFrames(readFrame, onFrame, ping, interval)`——形参不含 `HttpContext`/`WebSocket`（两者都是 stdx 的**类**，测试里造不出来：全仓 0 处构造、0 处实现，`CurrentHttpContext` 也只是读取点），于是用「假帧源 + 计数 ping 动作」即可测：`testPingStopsAfterConnectionDrops`（首读即抛异常 ⇒ 退出后 3 个周期内 ping 必须为 0）、`testPingRunsWhileAliveAndStopsAfterReturn`（read 阻塞 3 个周期 ⇒ 存活期间 ping ≥1 防空转；退出后先等 1 个周期让在途 tick 落地取基线，再等 3 个周期断言不再增长）。
- **RED/GREEN 实测**：把 `pumpFrames` 里 `finally` 的 `timer?.cancel()` 临时注释掉复跑 ⇒ **PASSED: 0 / FAILED: 2**，断言分别为 `Assert Failed: (0 == pings.value)`（实际 2 ⇒ 退出后定时器仍在 ping，泄漏复现 ✓）与 `(baseline == pings.value)`（3 → 6 持续增长）；恢复后复跑 ⇒ **PASSED: 2 / FAILED: 0**，`cjpm build` exit 0。
- **C（端到端）现状**：本仓库目前**没有任何 WS 端点或示例**（`frpcdemo` 里 0 处 `WebSocket`/`@WS`/`WSMeta`，`f_mvc/README.md` 也无 WS 章节）⇒ 端到端验证需要先新增一个最小 WS 服务（位置待用户指定），本条暂记**待办**。
- 顺带：本次同一分支曾按审查意见尝试 §1.10 `MVC-1` 的有界 LRU 缓存，经用户判定为误判后**已回退**（见 §1.10 误判标记第 3 点），本分支只保留 §1.11。

位置：`src/WSMeta.cj:158-168, 196-242`

```cangjie
// WSMeta.cj:163-165  Timer.repeat(duration, duration, {=> ws.writePingFrame(h(endpoint, ctx, pattern, ws, []))})
// WSMeta.cj:196      while(let frame <- ws.read()){
// WSMeta.cj:231      pingTimer?.cancel()        // 只有 case CloseWebFrame 这一条路
// WSMeta.cj:234-237  case _ => log.error(...); ws.closeConn()      // 不取消
// WSMeta.cj:242      }                          // read 返回 None 时直接返回，不取消
```

影响：客户端断网/直接断 socket（不发 Close 帧）时循环退出，定时器永久存活并持续向已关闭连接写帧；闭包捕获 `endpoint/ctx/pattern/ws` ⇒ 每断一条连接泄漏一个周期任务 + 一整条请求上下文。修法：把 `pingTimer?.cancel()` 放进该函数的 `finally`（或 `while` 外层的 `try/finally`）。

### 1.12 [严重｜性能] `MVC-2` `accessLog` 每请求无条件序列化全部参数与返回值（f_mvc）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-2 accessLog 惰性化——日志级别关闭时不序列化参数与返回值（§1.12）`）。

- 改动：`f_mvc/src/RequestMeta.cj` —— 把「参数文本 + 返回值文本」的构造（原 `:537-549` 的 `argGen` 循环与 `result`，加上局部函数 `anyToString`）整体搬出 `accessLog` 函数体，抽成包内接缝 `lazyAccessLogFields(args, returned): () -> (String, String)`：**构造这个闭包不序列化任何东西**，调用它才遍历参数、做 `toString()`/`toData()`+JSON/base64；`accessLog` 的 `logContent` 里才调用它。签名、日志文本格式、调用点 `src/macros/Controller.cj:97` 均未变。**`if (let Some(ex) <- e)` 里的 500 响应处理（`INTERNAL_SERVER_ERROR.handle(ctx, ex)`、`setResponseStatus`）没进闭包** —— 它属于响应、与日志级别无关，必须无条件执行。
- 惰性成立的依据：f_log 的 `Logger.info(message: () -> String)` 经 `AbstractLogger.append`（`f_log/src/base/AbstractLogger.cj:131-137`）先判 `logLevelEnabled(level)`、为假时不调 `message()`；`LoggerWrapper`（`:39-41`）→ `LoggerAppenderFacade`（`:49-55`）→ 各 appender 同样先判级别 ⇒ 级别关闭时 `logContent` 整个不执行。`request.form.toEncodeString()`、`getResponseStatus()`、`MonoTime.now()` 的求值位置与修前一致（仍在 `logContent` 内），未把 §2.6 `MVC-8` 的 ThreadLocal 问题牵扯进来。
- 用例：`f_mvc/src/RequestMeta_test.cj`（新增）—— 用「只实现 `ToString`、`toString()` 每次 +1」的计数 spy 直接驱动接缝：`testFieldsAreLazy`（构造闭包后计数必须 0；调用闭包后参数 + 返回值各 1 次 = 2；文本 `[counted]` / `counted`）、`testNoneResult`（返回 `None` ⇒ `'None'`、只序列化参数）。
- RED/GREEN 实测：先把 `anyToString` 与两段构造搬进接缝但**保持急切**（行为与修前一致）复跑 ⇒ `[ FAILED ] testFieldsAreLazy`，`Assert Failed: (0 == counter.value)`、**left: 0、right: 2**（构造闭包时参数与返回值就都已序列化，缺陷复现 ✓），`TOTAL 6 / PASSED 5 / FAILED 1`、`TEST EXIT=1`；改成在闭包内构造后复跑 ⇒ **PASSED 6 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**（`*_test.cj` 不进正常构建）。
- 未覆盖 / 保留项：①真端到端（HTTP 请求经 `@Controller` 走到 `accessLog`）未跑 —— `accessLog` 需要 `HttpContext`，测试里造不出来（stdx 类、全仓 0 处构造/实现），本条缺陷所在的重活已由接缝用例覆盖；②`LoggerFactory.getLogger<T>()` 的每请求查表按用户 2026-10-05 决定**保留（方案 B0）**，未改用 `RequestMeta.cj:21` 的静态 `log`；③日志**开启**且配了多个 appender 时，f_log 是「每个启用的 appender 各调一次 `message()`」（`LoggerAppenderFacade.cj:49-55`）⇒ 文本拼接与序列化各 ×N（修前拼接本就 ×N、序列化 ×1），N=1 时无差异。

位置：`src/RequestMeta.cj:519-553`（调用点 `macros/Controller.cj:97` 的 `finally`）

```cangjie
// RequestMeta.cj:530   case x: ToData => return f_data.convert<JsonValue>(x.toData()).getOrThrow().toString()
// RequestMeta.cj:537-545  let argGen = StringGenerator().append('['); for (arg in args) { ... anyToString(arg) ... }
// RequestMeta.cj:546-549  let result = match (returned) { case Some(x) => anyToString(x) ... }   // 返回值再来一遍 JSON
// RequestMeta.cj:550   let log = LoggerFactory.getLogger<T>()
```

影响：`argGen`/`result` 在 `logContent` 闭包**之前**就算好了（闭包只推迟最后一次拼接）⇒ 即使日志关闭，每请求也要付出：全量参数序列化 + 返回值二次 JSON 序列化（`ToData` 分支）+ 一次 `LoggerFactory.getLogger<T>()`。修法：把两段构造移进 `logContent`，或先判 `log.isInfoEnabled`；logger 用类静态字段（`RequestMeta.cj:21` 已有 `log`）。

## 2. 中（本模块 8 条）

### 2.2 [中｜正确性] `MVC-C3` 无 `Content-Type` 的请求直接 500（f_mvc）✓已复核 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-C3 缺/未注册 Content-Type 的 @RequestBody 请求改回 415（§2.2）`）。

- 改动：`f_mvc/src/ControllerFuncParam.cj` —— `RequestBody.extract`（原 `:171-178`）不再 `getFirst("Content-Type").getOrThrow()`，改调包内接缝 `requestBodyMediaType(contentType: ?String): MediaType`（顺带删掉同函数里未使用的 `let size`，编译器原就在报 `unused variable:'size'`）。接缝用 `MediaTypes.tryParse`（未知串返回 `None`，不抛，`f_http/src/MediaTypes.cj:82`）：缺失 / 空串 / **未注册类型**（如 `application/xml`，今天同样 500）统一 `perform MVCBreakingCommand(HttpStatus.UNSUPPORTED_MEDIA_TYPE)`，由 `RequestMeta.setHandle` 里既有的 `handle (cmd: MVCBreakingCommand)`（`RequestMeta.cj:205-208`；`f_mvc/cjpm.toml` 已开 `--enable-eh --experimental`）直接回 415。未被 handler 接住时 `stdx.effect.Command.defaultImpl()` 抛 `UnhandledCommandException` ⇒ 退化成原先的 500，不会静默放行。
- 为什么不是「缺失时按 `application/x-www-form-urlencoded` 处理」：`MediaTypes` 只注册了 `application/json`、`multipart/form-data`、`multipart/mixed`、`text/plain`（`f_http/src/MediaTypes.cj:28-33`，另有 bean 注册），**没有 form 类型** ⇒ `parse` 抛 `MediaTypeException`，仍是 500。为什么是 415 而不是 400：路由层对「Content-Type 不匹配任何 consumes」已回 415（`MultiRequestMethodHandler.cj:22,80`），同一语义保持同一个码。
- 用例：`f_mvc/src/ControllerFuncParam_test.cj`（新增）—— 直接驱动接缝、用 `try { ... } handle (cmd: MVCBreakingCommand) { ... }` 接住 415（`HttpContext` 造不出来，绕开它）：`testMissingContentTypeIs415`、`testEmptyContentTypeIs415`、`testUnregisteredContentTypeIs415`（三者在修前都落「没有 415」的哨兵 OK=200）、`testJsonContentTypeParsed`（已注册类型回归保护）。注：`handle` 分支不能捕获 `var`，用例里用 `Box<Option<HttpStatus>>` 兜。
- RED/GREEN 实测：接缝先按修前行为实现（`MediaTypes.parse(contentType.getOrThrow())`）复跑 ⇒ 3 条失败，`Assert Failed: (HttpStatus.UNSUPPORTED_MEDIA_TYPE.value == breakStatus(None).value)`、**left: 415、right: 200**（空串与 `application/xml` 同型），`TOTAL 10 / PASSED 7 / FAILED 3`、`TEST EXIT=1`；改成 `perform` 415 后复跑 ⇒ **PASSED 10 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。
- 未覆盖 / 已知边界：①**真端到端未跑**（`@RequestBody` 端点的 HTTP 往返）—— 建议在 fdemo 上验一次：`curl -i -X POST http://127.0.0.1:8080/api/user/echo3`（不带 Content-Type / body）应回 415，带 `-H 'Content-Type: application/json' -d '{...}'` 仍正常；②`perform` 最终走 `respond(status, data, ctx)`，而它对「空结果 + `Accept` 不含 `*/*`」会回 406（`RequestMeta.cj:313-319`）—— 这是 §3.2 `MVC-L11` 的既有语义，本条未动；③同样未动（待端到端观察）：`perform` 是否绕过宏生成闭包里的 `finally { accessLog }`，即这类被 415 快速失败的请求是否进访问日志。

`src/ControllerFuncParam.cj:175`：`ctx.request.headers.getFirst("Content-Type").getOrThrow()` —— 空 body 的 POST/PUT、只带查询参数的调用会抛 `NoneValueException` ⇒ 500，而应 415/400。修法：缺失时按 `application/x-www-form-urlencoded` 或明确报错处理。

### 2.3 [中｜正确性] `MVC-C5` `FileDownload` 在 `spawn` 内执行后立即返回（f_mvc）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-C5 下载任务失败自收尾 + 计时搬进任务（§2.3）`）。

- 改动（两处，异常出口形态按用户 2026-10-05 指定）：
  ①**异常出口 + 收尾**：`f_mvc/src/FileDownload.cj` —— `exec`（原 `:71-75`）的 `spawn{ fn(this) }` 改为 `spawn{ runDownloadTask(...) }`；新增包内接缝 `runDownloadTask(task, onFailure, finish)`：任务抛异常时先 `onFailure`（`log.error(e){'FileDownload.exec: download task failed; …'}`）再 `finish`（`built.load()` 时补 multi 的收尾 boundary `end()`，两种下载都 `pipe.end()` 结束响应体 ⇒ 客户端不再悬挂）；收尾自身失败时把 `finish` 的异常包成 `MVCException(ee)` 并把原任务异常挂为其 suppressed，然后**抛出原任务异常**（交给 spawn 的线程级兜底记录），不再是「无人接收」。
  ②**计时搬进任务**：`f_mvc/src/OverallStopwatch.cj` 新增 `takeStart()`（请求线程取走起点 `(MonoTime, path)` 并清空 ThreadLocal）与 `elapsedFrom(started, method)`（任意线程打印、不读 ThreadLocal）；`FileDownload.exec` 在任务 `finally` 里用它记真实传输耗时；`RequestMeta.respond(meta: FileDownloadMeta, ctx)`（`:372-375`）不再走 `respond(method, fn)`，去掉原来恒为 ~0 的「派发」计时。
- 用例：`f_mvc/src/FileDownload_test.cj`（新增）—— 驱动接缝（`FileDownload` 构造要读 `CurrentHttpContext.instance`，测试里造不出来）：`testFailedTaskIsReportedAndFinished`（任务失败 ⇒ `onFailure` 1 次 + `finish` 1 次）、`testSuccessfulTaskIsNotFinishedTwice`（成功路径不重复收尾）、`testFinishFailureRethrowsTaskException`（收尾也失败 ⇒ 抛出的是原任务异常 `task boom`，而非收尾的 `close boom`）。
- RED/GREEN 实测：接缝先按修前形态实现（`{ task() }`，行为与修前一致）复跑 ⇒ `testFailedTaskIsReportedAndFinished` 与 `testFinishFailureRethrowsTaskException` 失败（`Assert Failed: (1 == failures.value)`、**left: 1、right: 0**），`testSuccessfulTaskIsNotFinishedTwice` 通过，`TOTAL 13 / PASSED 11 / FAILED 2`、`TEST EXIT=1`；改成 `runDownloadTask` 正式形态后复跑 ⇒ **PASSED 13 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。
- 未覆盖 / 已知边界：①**真端到端未跑** —— fdemo 里没有任何下载路由（grep 0 处 `download(`），要 e2e 需先加一个最小下载端点，判据是「下载中途失败时客户端拿到被截断/结束的响应而不是一直挂住」；②计时（改动 ②）**无法单测**：`OverallStopwatch.switch`/`log` 在 static init 时按 `mvc_overallElapsedSwitch`（默认 false）绑定，测试里改配置拿不到可用 logger ⇒ 只有代码级论证，若要端到端观察需开 `mvc_overallElapsedSwitch=true` 后看 `MVC.overall` 的 debug 行是否出现真实传输耗时；③`finish` 失败时的异常形态：本条目首个提交（`52d1fb59`）按当时指令抛**原任务异常**；2026-10-05 已按用户指定改为 `throw ex`（见下方「补充」）。
- **补充（2026-10-05，用户指定「这里应该抛出 ex」）**：`runDownloadTask` 的 `finish` 失败分支由 `throw e` 改为 **`throw ex`**（`f_mvc/src/FileDownload.cj:150-163`，文档注释同步）—— 抛出的是包装收尾失败的 `MVCException`：`causedBy` = 收尾失败、`suppressed` = 原任务异常。实测（临时探针，跑完即删）：std 的 `Exception(caused)` **不复制** cause 的 message ⇒ `ex.message` 为空、信息全在 cause/suppressed 链上（`BaseException.printStackTrace` 会依次打出 `Caused by:` 与 `Suppressed:`，两个异常都不丢）。用例 `testFinishFailureRethrowsWrappedException` 钉死该形态：命中 `catch (e: MVCException)`、`message == ''`、`causedBy == 'close boom'`、suppressed 含 `task boom`。RED：修前形态命不中 `MVCException` 分支 ⇒ `Assert Failed: (true == caughtMvc.value)`、**left: true、right: false**，`TOTAL 20 / PASSED 19 / FAILED 1`、`TEST EXIT=1`；改成 `throw ex` 后复跑 ⇒ **PASSED 20 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。

`src/FileDownload.cj:71-75` + `src/RequestMeta.cj:372-376`：`respond` 的 `finally` 立刻调 `OverallStopwatch.elapsed` ⇒ 下载耗时统计恒为 ~0；且 `spawn` 内异常无人接收（`Future` 被丢弃），`pipe.end()` 可能永不执行 ⇒ 客户端悬挂。修法：把耗时统计移进下载任务，或明确分离响应与传输阶段；`spawn` 的异常要有出口。

### 2.5 [中｜内存｜待验证] `MVC-C2` `Resource` 在无 `Accept` 的路径上不关闭（f_mvc）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-C2 Resource 全分支关闭 + 缺 Accept 按通配渲染（§2.5）`）。

- **「待验证」的答案**：本仓库唯一同时实现 `ToData & Resource` 的类型是 `MultipartFile`（`f_http/src/MultipartFile.cj:18`：`Multipart & InputStream & Resource & DataFields<MultipartFile> & Data`，而 `Data <: FromToData <: ToData`，见 `f_data/src/base/Data.cj:18` + `DataFields.cj:31`）；但它作为控制器返回值会被 `setHandle` 里更靠前的 `case x: InputStream => respond(x, ctx)`（`RequestMeta.cj:194`）拦走，根本走不到 `respond<R>` 的 close；fdemo 里 `MultipartFile` 也只作入参（`UploadRequest.file`）。⇒ 本条是**潜在**问题（只对用户自定义的「`ToData + Resource` 且非 `InputStream`」返回类型生效），本仓库暂无触达路径，修复按防御性处理。
- 改动（两处，用户 2026-10-05 决定 ①close 全覆盖 + ②缺 Accept 不再 406）：
  ①**close 覆盖所有分支**：`f_mvc/src/RequestMeta.cj` 的 `respond<R>(status, result, ctx)` 把原先只写在「非空结果 + 有 Accept」分支里的关闭逻辑（原 `:303-309`）抽成包内接缝 `closeResultIfResource(result): ?Exception`（关闭失败不抛、回传异常由调用方 `log.warn` 记录），并挪进 `try/finally` ⇒ 渲染分支、两个空结果分支、`NotAcceptable` 分支都会关闭。
  ②**分支决策抽出 + 缺 Accept 按星号通配渲染**：新增包内接缝 `respondKind(emptyResult, accept): RespondKind`（枚举 `Render` / `EmptyWithContentType` / `EmptyWithoutContentType` / `NotAcceptable`），`respond<R>` 改为按它 `match`；修后「非空结果 + 缺 `Accept`」走 `Render`（用该 meta 的 `produces` 首选类型渲染），与 `JsonValue` 响应（`:328-347`）和 `populateResponseContentType`（`:132-139`）缺 Accept 时的默认一致；**空结果三分支行为不变**（无 Accept ⇒ 不带 Content-Type 的空体；含星号通配 ⇒ 带 Content-Type 的空体；其余 406）。
- 用例：`f_mvc/src/RequestMeta_test.cj`（追加 `RequestMeta_respond_test` + `CountingResource`）：`testNoAcceptRendersBody`、`testAcceptRendersBody`、`testEmptyResultBranches`、`testResourceIsClosed`（关闭恰好一次）、`testCloseFailureIsReturnedNotThrown`（关闭失败回传异常、不抛）、`testNonResourceIsUntouched`。
- RED/GREEN 实测：`respondKind` 先按修前逻辑落地（缺 Accept ⇒ `NotAcceptable`）复跑 ⇒ `[ FAILED ] testNoAcceptRendersBody`，`Assert Failed: 'Render' != respondKind(false, None).toString()`，`TOTAL 19 / PASSED 18 / FAILED 1`、`TEST EXIT=1`；改成修后逻辑后复跑 ⇒ **PASSED 19 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。
- 未覆盖 / 已知边界：①close 的**路径覆盖**无法单测（`respond<R>` 需要 `HttpContext`），只有「接缝调用点唯一且在 `finally` 内」的代码事实 + 上文对 `setHandle` 分发链的核对；②改动 ② 是**行为变更**（无 `Accept` 的 `ToData` 请求由 406 改为正常渲染），已按用户决定执行；③顺带发现、本条未动：当控制器声明 `produces: '*'` 一类通配时，渲染分支里 `produces.iterator().next()` 可能取到星号通配串再 `MediaTypes.parse` 抛异常（`RequestMeta.cj:310-314` 既有隐患，待确认后另行登记）。

`src/RequestMeta.cj:303-309`：`Resource` 只在「非空结果 + 有 Accept + `genBody`」这条路上 `close()`；`accept` 缺失时直接落到 `313-318`，`InputStream`/`Resource` 结果不会被关闭 ⇒ 句柄泄漏。**待验证**：哪些返回类型同时实现 `ToData & Resource`。

### 2.6 [中｜内存+正确性] `MVC-8` 请求级 ThreadLocal 不清理（f_mvc）→ ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-8 请求出口清理请求级 ThreadLocal + status 改在请求线程读（§2.6）`）。

- 改动（①清理 + ②读取位置，用户 2026-10-05 决定两件都做）：
  ①**请求出口统一清理**：`f_mvc/src/RequestMeta.cj` 新增 `clearResponseStatus()`（`currentResponseStatus.set(None)`）；`f_mvc/src/OverallStopwatch.cj` 新增 `clearStart()`（`switch` 开时清 `start` 的 ThreadLocal）。两处请求出口都调用：`setHandle<T>` 闭包的 finally（原先只有 `CurrentHttpContext.clear()`）与 404/静态资源路径（构造器里的 `handle_` 闭包，改为 `try/finally`）。
  ②**status 改在请求线程读**：`accessLog` 在闭包之外先读一次 `getResponseStatus()`，日志文本改用该值 —— f_log 的 message 闭包由异步 appender 在**消费线程**执行（`LoggerAppenderFacade`/`AsyncLogger`），原来在闭包里读会恒取默认值。日志关闭时这里只是一次 ThreadLocal 读，成本可忽略（MVC-2 的惰性化不受影响）。
- 顺带：`getResponseStatus()` 由 `private static` 放宽为包内 `static`（供用例断言）。
- 用例：`f_mvc/src/RequestMeta_test.cj`（追加 `RequestMeta_locals_test`）：`testResponseStatusIsCleared`（set 401 → 读得到 401 → clear 之后回落到默认 200）。
- RED/GREEN 实测：`clearResponseStatus` 先按修前形态实现（空实现）复跑 ⇒ `[ FAILED ] testResponseStatusIsCleared`，`Assert Failed: (HttpStatus.OK.value == RequestMeta.getResponseStatus())`、**left: 200、right: 401**（泄漏复现），`TOTAL 20 / PASSED 19 / FAILED 1`、`TEST EXIT=1`；改为真实清理后复跑 ⇒ **PASSED 20 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。
- 未覆盖 / 已知边界：①`OverallStopwatch.clearStart()` **无法单测**（`switch = MVCConfig.mvcOverallElapsedSwitch` 在 static init 时绑定、默认 false），只有「两处请求出口都调用它」的代码事实；②改动 ②（读取位置）**无法单测**（需要 `HttpContext`），需端到端观察（开日志后看 `MVC.accessLog` 的 status 是否为 401 等真实状态）；③WS 连接（`setHandle(wsmeta:)`）是长连接、不按请求清理，未纳入；④既有缺口、本条未动：`respond<R>(status, ...)` 没有把 `status` 喂给 `setResponseStatus`（只有 auth 失败 / 500 / `HttpStatusOnlyHandler` 路径会 set）⇒ 命令式 4xx（如 §2.2 的 415）的 access log status 字段仍是默认值，待确认后另行登记。

`src/RequestMeta.cj:25-35, 552`：`currentResponseStatus` 只 set 不清 ⇒ `accessLog` 的 status 会沿用上一个请求（如前一个 401，本请求 200 也记 401）；`src/OverallStopwatch.cj:29-39`：`start` 在 404/405/OPTIONS 路径不调用 `elapsed` ⇒ 线程继续持有上个请求的 path 字符串。修法：请求 `finally` 统一清理。

### 2.7 [中｜内存] `MVC-6` WS continuation 帧累积无上限（f_mvc）→ ❌误判（2026-10-05：用户判定「这不是错」，消息总长上限属端点/部署侧策略）

**❌ 误判标记（2026-10-05）**：用户 2026-10-05 判定本条**不是缺陷**，不进入修复队列（「MVC-6 也不改。我认为这不是错」）。支撑这一判定、已核对的事实：

1. **帧与消息是两层粒度**：框架已把「按帧」上限做成可配置项 —— `MVCConfig.MAX_FRAME_SIZE` / `maxFrameSize`（`MVCConfig.cj:48, 223-225`）→ `MVCStarter.cj:64` 的 `ServerBuilder.maxFrameSize`；`WSMeta.cj` 里 0 处长度校验是因为「消息总长」不是框架的职责层。
2. **端点拿到的就是完整消息**：`WSMeta.cj:209` 把 `bytes.unsafeData()` 整块交给 meta 的 `handle` ⇒ 消息总长的校验/拒绝属端点（业务）策略。
3. **硬上限会切断合法用法**：超大消息（大图片、大 JSON）本来就是靠 continuation 分片传输的，框架设死上限会让这类合法流量断连。

> 审查建议的「可配置上限 + 超限关连接」保留为**可选加固**：日后若要防滥用（恶意客户端持续发 continuation 不发 fin），再单独登记条目。

**以下为审查时的原始判断（留档对照）**：`src/WSMeta.cj:169-173`：`bytes.add(all: payload)`，只有 fin 才清空 ⇒ 客户端持续发 continuation 不发 fin 即可打爆单连接内存。修法：累积时校验总长上限（可配置），超限直接关连接。

### 2.19 [中｜性能] `MVC-5` 每个 `@PathVariable` 参数都做一次全路径解析 + 全量 `HashMap` 构造（f_mvc）→ ❌不改（2026-10-05：用户判定「不值得改」）

**❌ 不改标记（2026-10-05）**：用户 2026-10-05 判定本条**不值得改**，不进入修复队列。核对过的事实与账目：

1. **暴露面为零**：全仓只有 2 个控制器函数用 `@PathVariable`，且都是**单个**变量（`fdemo/user/src/controller/UserController.cj:33, 69` 的 `queryUser`/`deleteUser`）⇒ 「N 次重复解析」的实际浪费 = 0（单变量本来也必须解析一次）；解析入口也只有 `ControllerFuncParam.cj:125` 与 `HttpRequestDistributorImpl.cj:22` 两处。
2. **每次调用的成本构成**（留档，供日后评估）：`PathPattern.parts`（`trimExt` + `split("/")`，`f_util/src/PathPattern.cj:52-64`）→ `get(parts, EXTRACTION)`（模式树下行 + `HashMap<Int64, Any>`，`:241-249`）→ `extractVariablesInPath` 再建 `HashMap<String, String>` 并取**全部**变量值（`:179-196`），而调用方只取一个 key。
3. **备选方案与代价**：A「`f_util` 加轻量单变量查找」只省一张表与全量取值，解决不了 N 次切分/树查找，且给不出 RED；B「按请求缓存变量表」收益最大，但要引入新的请求级缓存状态（与 §2.6 的请求出口清理耦合），改动面大于收益。

> 触发条件：出现「一个控制器函数声明 ≥2 个 `@PathVariable`」的端点时再回头评估（届时 B 值得做）。

`ControllerFuncParam.cj:125` → `f_util/src/PathPattern.cj:173-195`：N 个 path 变量就重复 N 次切分（`f_util` 属跨模块，可加单变量轻量查找）。

### 2.20 [中｜性能] `MVC-7` 路由热路径每请求多次字符串分配（f_mvc）→ ✅已修复（2026-10-05，范围：只改 `RequestMethod.hashCode()`）

**✅ 修复标记（2026-10-05）**：分支 `fix/mvc-rest`（worktree `.worktrees/mvc-rest`，基线 `sts/1.3.x` 的 `7be7225d`），代码、用例与本标记在**同一提交**（提交信息 `fix(f_mvc): MVC-7 RequestMethod.hashCode 改常量表（§2.20）`）。

- **核对结论（修正审查表述）**：请求路径上的实际开销是 —— ①`RequestMethod.parse(request.method)` 每请求 1 次（`MultiRequestMethodHandler.cj:60`）：`toAsciiUpper()` 1 个 String 分配 + `getOrThrow{}` 1 个闭包分配；②`metas.get(method)` 每请求 1 次（`:87`，HEAD 请求再 1 次查 GET，`:109`）→ `hashCode()` = `toString().hashCode()`，`toString()` 返回字面量**不分配**，但每次都要**重算短串哈希**；③`RequestMethod.compare`（`RequestMethod.cj:67-69`）**不在请求路径上** —— 只经 `RequestMeta.compare`（`RequestMeta.cj:110-123`）在**注册期**被 `RequestMetas` 的 `TreeSet<RequestMeta>`（`RequestMetas.cj:21`，仓库内只写不读）插入时调用。
- 改动（**按用户 2026-10-05 决定：只改 `hashCode()`**）：`f_mvc/src/RequestMethod.cj` —— `hashCode()` 由 `toString().hashCode()` 改为**声明序常量表**（`GET→1` … `WS→8`），零分配、零字符串哈希。`tryParse` 的 `toAsciiUpper()` 分配（改用 `equalsIgnoreAsciiCase` 要最多 8 次逐字符忽略大小写比较，对 3–6 字符短串**净收益不确定**）、`parse` 的 `getOrThrow` 闭包、`compare`（注册期；改成声明序会改变排序语义）三项按用户决定**不动**。
- 用例：`f_mvc/src/RequestMethod_test.cj`（新增）：`testHashCodeIsDistinct`（8 个方法哈希两两不同，用 `HashSet.add` 的 `Bool` 返回判定）、`testHashCodeFollowsDeclarationOrder`（哈希随声明序递增，把「不再依赖字符串哈希」钉住）。
- RED/GREEN 实测：先落用例、`hashCode` 保持原实现复跑 ⇒ `[ FAILED ] testHashCodeFollowsDeclarationOrder`，`Assert Failed: (true == RequestMethod.OPTIONS.hashCode() < RequestMethod.HEAD.hashCode())`、**left: true、right: false**（字符串哈希与声明序无关），`TOTAL 22 / PASSED 21 / FAILED 1`、`TEST EXIT=1`；改成常量表后复跑 ⇒ **PASSED 22 / FAILED 0 / ERROR 0**、`TEST EXIT=0`；同轮 `cjpm build` **exit 0**。
- 未覆盖 / 已知边界：①**唯一可观察的行为变化**：哈希值变了 ⇒ `MultiRequestMethodHandler.metas`（`HashMap<RequestMethod, …>`）的**遍历顺序**可能变化，而 OPTIONS 分支用它拼 `Allow` / `Access-Control-Allow-Method`（`:89-99`）⇒ 这两个头里的**方法顺序**可能不同（HTTP 对该头顺序无要求；全仓无用例/脚本断言该头内容，已核对）;②`tryParse`/`parse`/`compare`/`operator ==`（后者缺 `WS` 分支，属 §3.2 `MVC-L12`）均未动。

`MultiRequestMethodHandler.cj:60` + `RequestMethod.cj:28-30, 55, 67-69`（`hashCode = toString().hashCode()`、`compare` 也走 `toString`）。修法：用 enum ordinal/常量名做哈希与比较。

### 2.21 [中｜性能] `MVC-9` 每请求一次反射式 bean 查找（f_mvc）→ ❌不改（2026-10-05，用户判定：这是设计语义，不是缺陷）

**❌ 不改标记（2026-10-05）**：用户判定 —— **每次 HTTP 访问都从 IoC 取一次 controller 实例，目的就是允许把 controller 定义为 `prototype`**，因此不做「注册期解析一次并缓存实例」。

- 设计语义核对（支撑该判定）：`@Controller` 本身就是 `@Bean` 的包装（`f_mvc/src/macros/Controller.cj:29-37`：`macro Controller(attr:)` → `@Bean[$attr]`），scope 由 `@BeanMeta[scope: …]` 决定；`RequestMeta.cj:224`（审查基线为 `:191`）每请求 `BeanFactory.instance.getFirst<T>().getOrThrow()` → `BeanManager.bean`（`f_bean/src/BeanManager.cj:88-108`）在 **`singleton`** 下走原子读、在 **`prototype`** 下每次 `new()`。fdemo 里就有活生生的 prototype 控制器：`fdemo/user/src/controller/CurrentUserController.cj:30-36`（`@BeanMeta[scope: BeanScope.prototype]`，其 `init()` 里 println 注明「多次访问本类的 controller 映射这一行每次都会输出」）。缓存实例会把它静默变成单例 ⇒ 语义破坏。
- 报告建议「注册期解析一次并缓存实例」另有一处时序问题（即便不考虑 prototype 也不成立）：`@Controller` 的注册代码经 `topMacroAnonymousClosure`（`f_macros/src/topMacroAnonymousClosure.cj:20-30`）展开为**模块级静态初始化** `private let _ = {=> … }()`，早于 `InitializerCollection.initialize()` → `BeanInitializer.initialize()` → `BeanFactory.afterRegistered()`（`f_bean/src/BeanInitializer.cj:28-30`）；后者才执行 `check()`（按 `@Conditional` 丢弃 bean）与 `initBeansIfNeed()`（创建单例、调 `@PostConstruct`）。注册期解析会提前造出实例 ⇒ 绕过条件过滤、打乱 `@PostConstruct` 顺序。
- 与 `BEAN-2`/`BEAN-3`（`bug-bean.md` §2.15/§2.16）的关系：那两条针对 `getFirst<T>()` **内部**的重复 `TypeInfo.of`/`isSubtypeOf`（影响所有 `lookup<T>()`/`getFirst` 调用方），属 f_bean 侧的独立条目；本条按设计**保留每请求调用**。若将来修 `BEAN-2`，本模块**无需再动**（收益自动落到这条路径上）。
- 附带核对（不改也留档）：该查找的三条路径为 `RequestMeta.cj:224`（HTTP，每请求）、`RequestMeta.cj:302`（WS，每**连接**一次，`WSMeta.exec` 内跑会话循环 `WSMeta.cj:198-227`）、`MultiRequestMethodHandler.cj:135`（异常响应冷路径，`cond: Exactly(message)` 直查 `beans`）。另注：`prototype` 控制器每请求 `new()` 会重跑字段初始化，其中的 `lookup<T>()`（`f_bean/src/lookup.cj:18-30`）也随之为每请求成本 —— 这是 prototype 的固有代价，非本条缺陷。

`RequestMeta.cj:191`（`BeanFactory.instance.getFirst<T>().getOrThrow()`）——与 `BEAN-2`/`BEAN-3` 是同一成本的两端，建议注册期解析一次并缓存实例。

## 3. 低危 / 待验证（本模块 13 条）

### 3.1 低危（11 条）

**健壮性 / 正确性**

- `MVC-C6` `WSMeta.cj:176, 238-240`：文本/二进制帧到达但未配置对应 meta 时每条消息抛一次 `WSException`，并在 catch 里 `toBase64String(frame.payload)`（O(payload)）⇒ 异常驱动控制流 + 编码放大。→ ✅**(a) 已加固（2026-10-05，见 §3.1 加固标记）**；✅**(b) 已修复（2026-10-06，见下）**
  - **(b) 修复（2026-10-06，`fix/mvc-rest`，与 `MVC-L11` 同一提交）**：把「数据帧到达但该类型没配 meta / 上一条载荷未消费完」从「抛 `WSException` → catch → 记日志 → 会话继续」改为**首帧即关**：新增包内接缝 `dataFrameCloseReason(metaType, pendingPayload, hasMeta): ?String`（`WSMeta.cj`，紧接 `pumpFrames`），`exec` 的 `onFrame` 在 Text/Binary 分支先问接缝，拿到原因就 `log.error{'${reason}'}` + `ws.closeConn()` + `return true`（与同文件「未知帧类型」的既有处置一致）⇒ 每条这样的消息不再付一次异常构造 + 栈展开 + 一条 ERROR 日志（`(a)` 去掉的是 base64 成本）。原 `throw WSException('current payload is not empty')` 已被接缝取代而删除；`doExec<M>` 内的 `meta.getOrThrow{…not specified…}` 保留为防御性断言（泛型助手，另有可能的调用方）。用例 `WSMeta_test.testDataFrameCloseReason` 钉住两条「该关」判定与两条「不该关」判定；RED 实测（接缝先落「一律 `None`」的修前形态）`Assert Failed: Some('current payload is not empty') != dataFrameCloseReason('text', true, true)`、left 原因 / **right None** ⇒ 同一轮 `TOTAL 28 / PASSED 26 / FAILED 2`、`TEST EXIT=1`；GREEN 后 28/28、`cjpm build` exit 0。

**内存 / 清理**

- `MVC-L9` `HttpStatus.cj:806-878` / `Series.cj:38-42`：`values` 属性每次访问重建数组（模块内只用于 `static init`，影响为 0，但属公开 API 易误用）。

**性能微项**

- `MVC-L1` `MultiRequestMethodHandler.cj:90-97`：OPTIONS 每次重建 Allow 字符串（`metas` 注册后不变，可预生成）；另有死变量 `let last = metas.size`。→ ✅**已修复（2026-10-05，见 §3.1 加固标记）**
- `MVC-L2` `FileDownload.cj:56` / `ResponseDownload.cj:44, 62`：每次下载重新分配缓冲并每次读配置（`MVCConfig.cj:257-261`）。
- `MVC-L3` `RequestMeta.cj:161-175, 298-302`：多值 `Accept` 每请求构造 `AcceptQueue`（内含 `PriorityQueue` + 比较闭包），浏览器默认多值 Accept 命中率极高。
- `MVC-L4` `RequestCondition.cj:154-170`：每次条件检查新建 `HashSet<String>(currentValues)`。
- `MVC-L5` `HttpRequestDistributorImpl.cj:57-63`：未命中路径每请求新建 `RequestMeta`（含闭包）⇒ 建议复用单例 404 handler。→ ✅**已修复（2026-10-05，见 §3.1 加固标记（二））**
- `MVC-L6` `global_func.cj:69-147`：数组参数解析用 `split`（无逗号也会切出 1 元素数组），可先判 `indexOf(',')` 或 `lazySplit`。
- `MVC-L7` `RequestMeta.cj:76-92`：比较器内构造两个 `TreeSet`（注册期 O(N log N) 次，可预算排序键）。→ ❌**不改（2026-10-06，用户判定 C，见 §3.1 判定标记（L7））**
- `MVC-L8` `RequestMeta.cj:71`：404 日志用非惰性插值（`'...${path}'`），改 `log.warn{...}`。→ ✅**已修复（2026-10-05，见 §3.1 加固标记）**
- `MVC-L10` `RequestArgMeta.cj:21, 39`：同一次写入用 `[]` + `get` 双查表，可合并为一次 `get`。

**✅ 加固标记（2026-10-05，`fix/mvc-rest`，代码/用例/本标记同一提交）**

提交信息 `perf(f_mvc): MVC-L8 / MVC-L1 / MVC-C6(a) 微项加固——日志惰性化 + OPTIONS Allow 串缓存（§3.1）`。

- **`MVC-L8`（404 日志惰性化）**：`RequestMeta.cj:99`（原基线记录为 `:71`）—— `log.warn('RequestMeta.handle.Not Found:${path} ${ctx.request.headers.getFirst('Accept')}')` → `log.warn{'…'}`。⇒ WARN 关闭时不再拼字符串、也不再做一次 `headers.getFirst('Accept')`（未命中/静态资源未命中的每条请求都付）。惰性依据：`Logger.warn(message: () -> String)`（`f_log/src/base/Logger.cj:523`）→ `AbstractLogger.append`（`f_log/src/base/AbstractLogger.cj:131-137`）**先判 `logLevelEnabled` 再调 `message()`**（同一契约已在 §1.12 `MVC-2` 标记中验证）。WARN 开启时输出逐字不变。
- **`MVC-L1`（OPTIONS 的 `Allow` 串构建一次缓存）**：`MultiRequestMethodHandler.cj` —— OPTIONS 分支（`:93-96`）改为取 `allowsCache.get()`；新增包内接缝 `AllowsCache`（`:194-209`：Mutex 保护的「构建一次」缓存）与 `allowsOf(metas)`（`:216-224`：原拼串逻辑原样搬入，首项固定 `RequestMethod.OPTIONS`）；**删除死变量 `let last = metas.size`**。缓存安全性：路由注册只发生在模块静态初始化期（`MVCStarter.generateAndRegister*` 在 `MVCStarter.initialize()` 之后调用会抛异常；`HttpRequestDistributorImpl` 的两个公开 `register` 直接抛「not implemented」）⇒ 首次 OPTIONS 请求时 `metas` 已是最终集合、此后不变。`Allow` / `Access-Control-Allow-Method` 的方法顺序取自 `HashMap` 遍历（本就不保证顺序，§2.20 已记录），缓存后同进程内稳定。
- **`MVC-C6`(a)（WS 帧错误日志惰性化，未改控制流）**：`WSMeta.cj:277`（close 帧 catch）、`:286`（帧处理 catch）—— `log.error('…${toBase64String(frame.payload)}', e)` → `log.error(e){'…'}`（惰性重载 `Logger.cj:444`/`:447`，调用形式同 `RequestMeta.cj:354` 的 `log.warn(e){…}`）；`:282` 的 `log.error('unsupport frame …')` 一并改惰性。⇒ **ERROR 关闭时不再为每条消息 base64 整个 payload**（该路径正是「帧到了但没配 meta ⇒ 每条消息抛一次」最贵的地方）。异常仍在 catch 内消化、会话继续，与修前一致；**(b)**「未配置 meta 的帧是否改为首帧即 `closeConn()`」属行为变更，**待用户拍板**。
- **RED/GREEN 实测**（同一套用例两次运行，`f_mvc`）：
  - **RED**：先落接缝的**急切形态**（`AllowsCache.get()` 每次重建，行为与改造前一致）+ 新增用例文件 `f_mvc/src/MultiRequestMethodHandler_test.cj` ⇒ `[ FAILED ] testAllowsIsBuiltOnce`，`Assert Failed: first != cache.get()`（第二次调用前向 `metas` 加了一个 PUT，重建即产生不同串）⇒ **`TOTAL 24 / PASSED 23 / FAILED 1`、`TEST EXIT=1`**；同轮 `testAllowsContent` PASSED（内容不变量成立）。
  - **GREEN**：给 `AllowsCache` 加上 Mutex + 一次性缓存后复跑 ⇒ **`PASSED 24 / FAILED 0 / ERROR 0`、`TEST EXIT=0`**；同轮 `cjpm build` **exit 0**。
- 用例内容：`testAllowsContent`（`"OPTIONS, GET, POST, WS"` 按**集合**断言：首项 `OPTIONS`、集合 == 已注册方法集合，不绑顺序）、`testAllowsIsBuiltOnce`（可变 `metas` 钉住「构建一次后不再重建」）。
- 未覆盖 / 保留项：①`MVC-L8` 与 `MVC-C6(a)` 的「惰性」依赖 f_log 契约，无 f_mvc 侧单测（`HttpContext`/日志级别在 f_mvc 测试里造不出、注入不了），证据为契约核对 + 既有 24 条用例全绿；②`MVC-C6`(b) 未做；③本次未动 `MVC-L2`/`L3`/`L4`/`L6`/`L7`/`L9`/`L10` 与 §3.2 两条（`MVC-L5` 见下一个标记）。

**✅ 加固标记（二）（2026-10-05，`fix/mvc-rest`，代码/用例/本标记同一提交）**

提交信息 `perf(f_mvc): MVC-L5 未命中路径改轻量 handler——静态资源/404 不再每请求构造 RequestMeta（§3.1）`。

- **改动**：新增包内类 `StaticResourceOrNotFoundHandler <: HttpRequestHandler`（`RequestMeta.cj` 文件末尾）——只持一个 `path`，逻辑与原 `RequestMeta` 默认处理器**逐字一致**（读静态资源 → 按扩展名设 `Content-Type` → body；否则记 `Not Found` + 404；`finally` 里 `RequestMeta.clearResponseStatus()` + `OverallStopwatch.clearStart()`）；`HttpRequestDistributorImpl.distribute` 的未命中分支（`:60-63`）由 `RequestMeta(path, RequestMethod.GET)` 改为返回该 handler；`RequestMeta` 构造器里的默认 `handle_` 改为**委托**给它（单一事实来源，避免两份静态资源逻辑）。
- **为复用而放宽的可见性**（均只到包内，公开 API 不变）：`RequestMeta.log`（`private static let` → `static`；**复用同一日志类别 ⇒ 日志 name 与文本都不变**）、`RequestMeta.NOT_FOUND`（→ `static`；仍复用 stdx 的 `NotFoundHandler`——`stdx.net.http` 的 `HttpRequestDistributor.distribute` 文档明确「未找到对应请求处理器时返回 `NotFoundHandler` 以返回 404」，即未命中返回轻量 handler 是该接口既定用法）、`RequestMeta.loadStaticResource`（`private static func` → `static`）。`STATIC_RESOURCE_ROOT` / `staticResourceBytes` 保持 `private`。
- **收益**：未命中/静态资源请求的分配从 ≈6 次（`RequestMeta` 本体 + 闭包 + `produces`/`consumes` 两个 `HashSet` + `RequestArgMeta` 及其内部 `HashMap`）降到 **1 次**（handler 本体）。**不做按路径缓存**：路径集合无界（扫描器可制造任意路径），按请求构造只多一个对象。
- **触发面**（说明这不是冷路径）：任何未注册为路由的路径都走它——404（爬虫/扫描器/旧链接）**以及静态资源**（`/index.html`、`/app.js`…；命中静态资源时旧实现同样先付整套分配）。
- **RED/GREEN 实测**：
  - **RED**：接缝先落、`distribute` 未切（仍返回 `RequestMeta`）⇒ `[ FAILED ] testUnmatchedPathReturnsLightweightHandler`，`Assert Failed: (true == handler is StaticResourceOrNotFoundHandler)`、**left: true、right: false** ⇒ `TOTAL 25 / PASSED 24 / FAILED 1`、`TEST EXIT=1`；同轮 `cjpm build` **exit 0**。
  - **GREEN**：`distribute` 切到轻量 handler 后复跑 ⇒ **`PASSED 25 / FAILED 0 / ERROR 0`、`TEST EXIT=0`**；同轮 `cjpm build` **exit 0**。
- 用例：`f_mvc/src/HttpRequestDistributorImpl_test.cj`（新增）`testUnmatchedPathReturnsLightweightHandler` —— `HttpRequestDistributorImpl.instance.distribute('/__mvc_l5_unregistered_path__')` 的结果必须 `is StaticResourceOrNotFoundHandler`。**它钉的是结构契约（分发结果的类型），不是用户可见行为**（`handle(ctx)` 需要 `HttpContext`，f_mvc 测试造不出）——行为侧证据为「逻辑逐字搬运核对 + 既有 25 条用例全绿」。
- 未覆盖 / 已知边界：①`handle(ctx)` 的静态资源/404 行为无单测（同 `MVC-L8`/`MVC-C6(a)` 的限制）；②`RequestMeta` 构造器的默认处理器如今只被「手工 `RequestMeta(path, method)` 且不调 `setHandle`」这类用法走到（生产路径已无），保留委托以不改变该语义；③本次未动 `MVC-L2`/`L3`/`L4`/`L6`/`L7`/`L9`/`L10` 与 §3.2 两条。

**❌ 判定标记（L7）（2026-10-06，用户判定 C：不改）**

报告原文：`MVC-L7` `RequestMeta.cj:76-92`：「比较器内构造两个 `TreeSet`（注册期 O(N log N) 次，可预算排序键）」。

- **现状**：`RequestMeta.compare`（当前 `:87-103`）—— `path` → `method` → 两侧 `consumes` 各建一个 `TreeSet<String>` 升序逐元素比较 → `consumes.size` 兜底。唯一调用方是 `RequestMetas` 的全局 `TreeSet<RequestMeta>`（`RequestMetas.cj:21`），插入点仅 `RequestMeta.cj:527`（`RequestMeta.generate` 内），全部发生在**注册期**且串行（`RequestMetas.add` 持锁，`RequestMetas.cj:23-27`）。
- **对报告表述的修正（成本远小于原文）**：建 `TreeSet` 那段只在**前两步都为 EQ（`path` 与 `method` 都相同）**时才执行 ⇒ 一次 `TreeSet.add` 的 O(log N) 次比较里，绝大多数只做两次字符串比较；只有与「同 path + 同 method」的 meta 比较（该组常态只有 1 个成员，约 1–2 次）才进该分支。⇒ 真实成本 ≈ 注册期 N·log N 次短字符串比较 + 极少数小 `TreeSet` 构造，量级在毫秒以下（N=200 路由约上千次比较）。
- **顺带发现（未立项）**：`RequestMetas` 是**只写不读**的容器 —— 全仓（排除 `.git`/`target`）只有定义（`RequestMetas.cj:18-28`）与 `RequestMeta.cj:527` 的 `instance.add(meta)`，`metas` 为 `private` 且无访问器 ⇒ 连外部 App 也读不出。即 `compare`（本条的全部成本）目前在为一个无消费者的有序表服务；该表持有的 meta 引用在 `MultiRequestMethodHandler.metas` 与 `PathPattern` 树中已持有 ⇒ 功能上是纯负担。将来若要做，可选「`TreeSet<RequestMeta>` → `ArrayList<RequestMeta>`」（成本归零、可观察行为不变，因其无读者），但那是动 `public class RequestMetas` 的内部结构，需单独立项与拍板。
- **未采纳的方案（一并记录）**：**A** 缓存排序键（`private var consumesOrder_ = None<Array<String>>`，首次比较时把 `consumes` 排好序存下，`compare` 改为两次 `Array<String>` 逐元素 + size 兜底）——收益与 B 同级，但要处理缓存失效（写入点仅 `addConsumes`（`:460`，private）与 `setHandle(wsmeta:)`（`:283-284`）两处）；**B** 换掉有序容器。用户在 2026-10-06 选择 **C（不改）**。
- **可验证性（若将来改）**：本条属「同一语义的缓存化」，**无真 RED**；证据应为「等价性守卫用例（`compare` 为 `public`，测试内可用 `@GetMapping` 注解类 + `RequestMeta.generate<T>` 造出带不同 `consumes` 的同 path+method meta，覆盖相等 / 前缀（`{'a'}` vs `{'a','b'}`，靠 size 兜底）/ 非前缀（`{'ab'}` vs `{'a','b'}`）/ `'*'`、`'*/*'` 特例）+ 代码核对」，必要时补基准。

### 3.2 待验证（2 条）

- `MVC-L11` `RequestMeta.cj:303-318`：空结果的控制器函数在 `Accept` 不含 `*/*` 时被判为 406 而非 200 空体。**验证**：设计意图。→ ✅**已修复（2026-10-06，见修复标记（L11））** —— 判定为**不是设计意图**：会把 `MVCBreakingCommand(status)`（默认 `DataUnit.UNIT`，如 `ControllerFuncParam` 的 415）的状态码吞成 406
- `MVC-L12` `RequestMethod.cj:32-38`：`operator ==` 的分支里没有 `WS`，`(WS, WS)` 落到 `case _ => false`，而 `hashCode` 由 `toString` 生成。**验证**：若 `HashMap` 不做引用短路，WS 路由查不到（`RequestMethod.WS` 正是 WS 端点的注册键，见 `HttpRequestDistributorImpl.cj:36`）。→ ✅**已修复（2026-10-06，见 §3.2 修复标记）**（注：`hashCode` 自 `MVC-7` 起已是声明序常量表，不再是 `toString` 哈希）

**✅ 修复标记（L12）（2026-10-06，`fix/mvc-rest`，代码/用例/本标记同一提交）**

提交信息 `fix(f_mvc): MVC-L12 RequestMethod.== 补 WS 分支——修 Equatable 自反性，WS 可作哈希容器键（§3.2）`。

- **「待验证」问题的定论（读本机 std 源码 + 实测）**：`HashMap.get` 的桶内匹配是 `hash == entries[i].hash && key == entries[i].key`（`cangjie_runtime/std/libs/std/collection/hash_map.cj:480-492`，匹配行 `:485`）⇒ **没有「同一引用即命中」的短路**；`HashSet.contains/add` 委托 `HashMap`（`hash_set.cj:107-110`、`:151-156`），fountain 自有的 `computeIfAbsent` 走 `entryView`（`f_collection/src/ExtendCollection.cj:61-69`）同族。⇒ 报告的假设前半句成立：只要真拿 `WS` 当键去查就会查不到（RED 实测 `map.get(RequestMethod.WS)` = `None`）。
- **改动**：`RequestMethod.cj` 的 `operator ==` 补一个分支 `| (WS, WS)`（`!=` 由 `==` 派生，自动修好）。`hashCode`（`MVC-7` 后为声明序常量表，`WS→8`）、`toString`、`compare`、`parse`/`tryParse` 均未动。
- **RED/GREEN 实测**（同一套用例两次运行，`f_mvc`）：
  - **RED**：两条用例先落、`==` 未改 ⇒ `[ FAILED ] testWsIsEqualToItself`（`Assert Failed: (true == RequestMethod.WS == RequestMethod.WS)`、left: true / right: false）与 `[ FAILED ] testWsIsUsableAsHashContainerKey`（`Assert Failed: Some(1) != map.get(RequestMethod.WS)`、left: 1 / **right: None**）⇒ `TOTAL 27 / PASSED 25 / FAILED 2`、`TEST EXIT=1`。
  - **GREEN**：补 `| (WS, WS)` 后复跑 ⇒ **`PASSED 27 / FAILED 0 / ERROR 0`、`TEST EXIT=0`**；同轮 `cjpm build` **exit 0**。
- 用例：`f_mvc/src/RequestMethod_test.cj` 新增 `testWsIsEqualToItself`（自反性 + `!=` + 路由侧形态 `parse('WS') == WS`）、`testWsIsUsableAsHashContainerKey`（`HashMap<RequestMethod, Int64>` 写 `WS` 后 `get(WS)` 命中、`HashSet.add(WS)` 后 `contains(WS)`）。
- **修后影响面**：①拿 `WS` 当键的 `get`/`contains`/`add`/`computeIfAbsent` 开始正常工作；②debug 日志里 WS 的 `methodRegistered`（`MultiRequestMethodHandler.cj:44`/`:48`）由误报 `false` 变为 `true`。请求期无其它变化 —— `handle` 只用 `RequestMethod.parse(request.method)`（`:64`）与 HEAD 分支的 `metas.get(RequestMethod.GET)`（`:106`）查键，**从不查 `WS`**（全仓 `RequestMethod.WS` 仅出现在 `HttpRequestDistributorImpl.cj:36` 的注册点与本测试）。
- **关联（新发现，建议单独立项，本次未做）**：WS 端点路由可达性存疑 —— WS meta 只注册在 `WS` 键下（`HttpRequestDistributorImpl.cj:36`），而握手请求是 `GET` ⇒ `metas.get(GET)` 落空 ⇒ 落到 `MultiRequestMethodHandler.cj:111` 的 405；全仓亦无 `@WSEndPoint` 使用/文档/端到端用例。修 `==` 是 WS 可用的**必要不充分**条件。

**✅ 修复标记（L11）（2026-10-06，`fix/mvc-rest`，与 `MVC-C6(b)` 同一提交）**

提交信息 `fix(f_mvc): MVC-L11 空结果不再判 406（具体 Accept 走空体）+ MVC-C6(b) 无 meta 的数据帧首帧即关（§3.1/§3.2）`。

- **判定：不是设计意图，而是会吞掉状态码的缺陷**（用户 2026-10-06 采纳建议）：`respondKind(emptyResult, accept)` 在「空结果 + 具体 Accept（不含 `*/*`）」时返回 `NotAcceptable` ⇒ `respond<R>` 调 `MultiRequestMethodHandler.NOT_ACCEPTABLE`（406）。
- **真实触发链（关键证据）**：`ControllerFuncParam.cj:192` 的 `perform MVCBreakingCommand(HttpStatus.UNSUPPORTED_MEDIA_TYPE)`（`MVC-C3` 修的 415）→ `BreakingCommand.cj:23` 的 data 默认 `DataUnit.UNIT` → `RequestMeta.cj:220` `respond(MVCBreakingCommand(cmd.data), ctx)` → `respond<Data>(status, DataUnit, ctx)` ⇒ `emptyResult = true` ⇒ 客户端带 `Accept: application/json` 时 **415 被 406 顶掉** ✗；同类场景：任何 `MVCBreakingCommand(status)`、且客户端只接受具体媒体类型时，原状态码都会被吞。`MVC-C3` 的用例只断言到 `MVCBreakingCommand` 的状态/类型、没走到 HTTP 响应层，所以此前没暴露。
- **改动**（`RequestMeta.cj` 的 `respondKind`）：缺 Accept ⇒ `EmptyWithoutContentType`；**非空 Accept（含 `*/*` 与具体类型）⇒ `EmptyWithContentType`**（原状态码 + 按 Accept 声明 Content-Type + 空体）；仅 `Accept: ''` 这类异常值仍 `NotAcceptable`（保持 406 可达，避免写出空 `Content-Type`）。`RespondKind` 与 `respond<R>` 的其它分支未动；**非空结果**的 406 路径（`Render` + `genBody` 失败 ⇒ `:322`）不受影响。
- **RED/GREEN 实测**（同一套用例两次运行，`f_mvc`）：
  - **RED**：断言先改（`testEmptyResultBranches` 把 `Some('application/json')` 的期望由 `NotAcceptable` 改为 `EmptyWithContentType`，另加 `Some('text/html')`、`Some('')`）⇒ `[ FAILED ] testEmptyResultBranches`，`Assert Failed: 'EmptyWithContentType' != respondKind(true, Some('application/json')).toString()` ⇒ 同一轮 `TOTAL 28 / PASSED 26 / FAILED 2`（另一条属 `MVC-C6(b)`）、`TEST EXIT=1`。
  - **GREEN**：改实现后复跑 ⇒ **`PASSED 28 / FAILED 0 / ERROR 0`、`TEST EXIT=0`**；同轮 `cjpm build` **exit 0**。
- 用例：`RequestMeta_test.cj` 的 `testEmptyResultBranches` —— `None` ⇒ `EmptyWithoutContentType`；`Some('*/*')` / `Some('application/json')` / `Some('text/html')` ⇒ `EmptyWithContentType`；`Some('')` ⇒ `NotAcceptable`。
- 未覆盖 / 已知边界：①`respond<R>` 需要 `HttpContext`，端到端（415 链路在 `Accept: application/json` 下不再变 406）无法单测 —— 证据为上面的调用链 + `respondKind` 用例；②空体 + `Content-Type: <Accept>` 对「严格解析 JSON 的客户端」可能仍需容忍空体，但 `*/*` 分支修前一直如此，本次只是把行为统一。

## 4. 逐模块覆盖面（原 §4.2）

### 4.2 f_mvc

**结构**：请求链路 `HttpRequestDistributorImpl.distribute`（`57`）→ `PathPattern` 查表 → `MultiRequestMethodHandler.handle`（method/Content-Type 两级 `HashMap`）→ 宏生成闭包（`macros/Controller.cj:78-101`）→ `RequestMeta.checkAuth/extract/respond`。**路由表在注册期构建、请求期只查表**（`f_util/src/PathPattern.cj:153` + `MultiRequestMethodHandler.cj:37-54`），这部分设计是对的。

**无实例的维度**：路由匹配表**不是**每请求重建；热点循环里无 `Array/ArrayList.contains` 存在性判断（`consumes/produces` 用 `HashSet`、`checkHeader` 用 `HashSet.contains`、`HttpStatus/Series` 用 `HashMap`）；无循环字符串 `+`/插值（统一 `StringGenerator`）；无 String↔Rune/Byte 循环转换；锁只在注册期（`RequestMetas.add`、`register`、`AuthHandlerProxy` 首次初始化）；无「spawn 后立即 get」；无循环内同步 IO；无健康检查历史/中间件链增长；无 `catch NoneValueException` 式控制流（`tryParse` 系列均正确使用）；除 WS ping Timer 外无「注册无注销」；已知上界未预分配的分配点都在注册期。
