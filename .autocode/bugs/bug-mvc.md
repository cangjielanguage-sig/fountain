# f_mvc 模块审查条目（拆分自 bug.md）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 25 条**：严重 4（§1.9 `MVC-4`、§1.10 `MVC-1`、§1.11 `MVC-3`、§1.12 `MVC-2`）、中 8（§2.2 `MVC-C3`、§2.3 `MVC-C5`、§2.5 `MVC-C2`、§2.6 `MVC-8`、§2.7 `MVC-6`、§2.19 `MVC-5`、§2.20 `MVC-7`、§2.21 `MVC-9`）、低危+待验证 13（§3）。
- **状态（截至 2026-10-05）**：`MVC-4` ✅已修复（§1.9，`fix/mvc-4`，已并入 `sts/1.3.x`）；`MVC-1` ❌误判（§1.10，非缺陷：静态资源常驻是设计目的、`view.value = None` 实为删除条目）；`MVC-3` ✅已修复（§1.11，`fix/mvc-3`，已并入 `sts/1.3.x`）；`MVC-2` ✅已修复（§1.12，`fix/mvc-rest`）；`MVC-C3` ✅已修复（§2.2，`fix/mvc-rest`）；`MVC-C5` ✅已修复（§2.3，`fix/mvc-rest`）；**待修** §2 的 6 条中危（§2.5、§2.6、§2.7、§2.19–§2.21）、§3 的 13 条低危/待验证（**本模块严重级已清零**）。

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
- 未覆盖 / 已知边界：①**真端到端未跑** —— fdemo 里没有任何下载路由（grep 0 处 `download(`），要 e2e 需先加一个最小下载端点，判据是「下载中途失败时客户端拿到被截断/结束的响应而不是一直挂住」；②计时（改动 ②）**无法单测**：`OverallStopwatch.switch`/`log` 在 static init 时按 `mvc_overallElapsedSwitch`（默认 false）绑定，测试里改配置拿不到可用 logger ⇒ 只有代码级论证，若要端到端观察需开 `mvc_overallElapsedSwitch=true` 后看 `MVC.overall` 的 debug 行是否出现真实传输耗时；③保留项：`finish` 失败时抛出的仍是**原任务异常**（用户指定形态），`finish` 自身异常只挂在未被抛出的 `ex` 的 suppressed 上、不随异常抛出。

`src/FileDownload.cj:71-75` + `src/RequestMeta.cj:372-376`：`respond` 的 `finally` 立刻调 `OverallStopwatch.elapsed` ⇒ 下载耗时统计恒为 ~0；且 `spawn` 内异常无人接收（`Future` 被丢弃），`pipe.end()` 可能永不执行 ⇒ 客户端悬挂。修法：把耗时统计移进下载任务，或明确分离响应与传输阶段；`spawn` 的异常要有出口。

### 2.5 [中｜内存｜待验证] `MVC-C2` `Resource` 在无 `Accept` 的路径上不关闭（f_mvc）

`src/RequestMeta.cj:303-309`：`Resource` 只在「非空结果 + 有 Accept + `genBody`」这条路上 `close()`；`accept` 缺失时直接落到 `313-318`，`InputStream`/`Resource` 结果不会被关闭 ⇒ 句柄泄漏。**待验证**：哪些返回类型同时实现 `ToData & Resource`。

### 2.6 [中｜内存+正确性] `MVC-8` 请求级 ThreadLocal 不清理（f_mvc）

`src/RequestMeta.cj:25-35, 552`：`currentResponseStatus` 只 set 不清 ⇒ `accessLog` 的 status 会沿用上一个请求（如前一个 401，本请求 200 也记 401）；`src/OverallStopwatch.cj:29-39`：`start` 在 404/405/OPTIONS 路径不调用 `elapsed` ⇒ 线程继续持有上个请求的 path 字符串。修法：请求 `finally` 统一清理。

### 2.7 [中｜内存] `MVC-6` WS continuation 帧累积无上限（f_mvc）

`src/WSMeta.cj:169-173`：`bytes.add(all: payload)`，只有 fin 才清空 ⇒ 客户端持续发 continuation 不发 fin 即可打爆单连接内存。修法：累积时校验总长上限（可配置），超限直接关连接。

### 2.19 [中｜性能] `MVC-5` 每个 `@PathVariable` 参数都做一次全路径解析 + 全量 `HashMap` 构造（f_mvc）

`ControllerFuncParam.cj:125` → `f_util/src/PathPattern.cj:173-195`：N 个 path 变量就重复 N 次切分（`f_util` 属跨模块，可加单变量轻量查找）。

### 2.20 [中｜性能] `MVC-7` 路由热路径每请求多次字符串分配（f_mvc）

`MultiRequestMethodHandler.cj:60` + `RequestMethod.cj:28-30, 55, 67-69`（`hashCode = toString().hashCode()`、`compare` 也走 `toString`）。修法：用 enum ordinal/常量名做哈希与比较。

### 2.21 [中｜性能] `MVC-9` 每请求一次反射式 bean 查找（f_mvc）

`RequestMeta.cj:191`（`BeanFactory.instance.getFirst<T>().getOrThrow()`）——与 `BEAN-2`/`BEAN-3` 是同一成本的两端，建议注册期解析一次并缓存实例。

## 3. 低危 / 待验证（本模块 13 条）

### 3.1 低危（11 条）

**健壮性 / 正确性**

- `MVC-C6` `WSMeta.cj:176, 238-240`：文本/二进制帧到达但未配置对应 meta 时每条消息抛一次 `WSException`，并在 catch 里 `toBase64String(frame.payload)`（O(payload)）⇒ 异常驱动控制流 + 编码放大。

**内存 / 清理**

- `MVC-L9` `HttpStatus.cj:806-878` / `Series.cj:38-42`：`values` 属性每次访问重建数组（模块内只用于 `static init`，影响为 0，但属公开 API 易误用）。

**性能微项**

- `MVC-L1` `MultiRequestMethodHandler.cj:90-97`：OPTIONS 每次重建 Allow 字符串（`metas` 注册后不变，可预生成）；另有死变量 `let last = metas.size`。
- `MVC-L2` `FileDownload.cj:56` / `ResponseDownload.cj:44, 62`：每次下载重新分配缓冲并每次读配置（`MVCConfig.cj:257-261`）。
- `MVC-L3` `RequestMeta.cj:161-175, 298-302`：多值 `Accept` 每请求构造 `AcceptQueue`（内含 `PriorityQueue` + 比较闭包），浏览器默认多值 Accept 命中率极高。
- `MVC-L4` `RequestCondition.cj:154-170`：每次条件检查新建 `HashSet<String>(currentValues)`。
- `MVC-L5` `HttpRequestDistributorImpl.cj:57-63`：未命中路径每请求新建 `RequestMeta`（含闭包）⇒ 建议复用单例 404 handler。
- `MVC-L6` `global_func.cj:69-147`：数组参数解析用 `split`（无逗号也会切出 1 元素数组），可先判 `indexOf(',')` 或 `lazySplit`。
- `MVC-L7` `RequestMeta.cj:76-92`：比较器内构造两个 `TreeSet`（注册期 O(N log N) 次，可预算排序键）。
- `MVC-L8` `RequestMeta.cj:71`：404 日志用非惰性插值（`'...${path}'`），改 `log.warn{...}`。
- `MVC-L10` `RequestArgMeta.cj:21, 39`：同一次写入用 `[]` + `get` 双查表，可合并为一次 `get`。

### 3.2 待验证（2 条）

- `MVC-L11` `RequestMeta.cj:303-318`：空结果的控制器函数在 `Accept` 不含 `*/*` 时被判为 406 而非 200 空体。**验证**：设计意图。
- `MVC-L12` `RequestMethod.cj:32-38`：`operator ==` 的分支里没有 `WS`，`(WS, WS)` 落到 `case _ => false`，而 `hashCode` 由 `toString` 生成。**验证**：若 `HashMap` 不做引用短路，WS 路由查不到（`RequestMethod.WS` 正是 WS 端点的注册键，见 `HttpRequestDistributorImpl.cj:36`）。

## 4. 逐模块覆盖面（原 §4.2）

### 4.2 f_mvc

**结构**：请求链路 `HttpRequestDistributorImpl.distribute`（`57`）→ `PathPattern` 查表 → `MultiRequestMethodHandler.handle`（method/Content-Type 两级 `HashMap`）→ 宏生成闭包（`macros/Controller.cj:78-101`）→ `RequestMeta.checkAuth/extract/respond`。**路由表在注册期构建、请求期只查表**（`f_util/src/PathPattern.cj:153` + `MultiRequestMethodHandler.cj:37-54`），这部分设计是对的。

**无实例的维度**：路由匹配表**不是**每请求重建；热点循环里无 `Array/ArrayList.contains` 存在性判断（`consumes/produces` 用 `HashSet`、`checkHeader` 用 `HashSet.contains`、`HttpStatus/Series` 用 `HashMap`）；无循环字符串 `+`/插值（统一 `StringGenerator`）；无 String↔Rune/Byte 循环转换；锁只在注册期（`RequestMetas.add`、`register`、`AuthHandlerProxy` 首次初始化）；无「spawn 后立即 get」；无循环内同步 IO；无健康检查历史/中间件链增长；无 `catch NoneValueException` 式控制流（`tryParse` 系列均正确使用）；除 WS ping Timer 外无「注册无注销」；已知上界未预分配的分配点都在注册期。
