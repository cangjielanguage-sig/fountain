# f_mvc 模块审查报告（第 3/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（59 个源文件；**本部分 15 个**，第 3/4 部分）
- **基线**：工作区快照（检出 `sts/1.3.x`，HEAD `8c0ce643a`，无 diff 可比 ⇒ 本部分所有缺陷来源统一记「存量」；`git blame` 抽样：`RequestCondition.cj:22-29`、`WSCloseFrame.cj:105-111` 均为 `4be871f2fd`（2026-10-02））
- **审查重点**：请求元数据 / 类型化条件 / 请求方法 / 响应下载 / WebSocket 帧与端点元数据的正确性与边界；死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（部分报告，最终由主 Agent 合并为 `docs/review/f_mvc_review_20261128.md`；编号为本部分内序号）
- **已有性能资料**：未提供（`scope.md` 明示）⇒ 本部分无「热点瓶颈」级发现；性能类结论只出现在「优化可行性方案 / 待验证假设」
- **构建告警旁证**：`f_mvc/target/release/.build-logs/f_mvc@fountain/f_mvc@fountain.aarch64-unknown-linux-gnu..errlog`（既有构建产物，非本轮运行）—— 用于死代码 / 不可达分支的机械取证

## 发现

### 1. [严重][存量] 静态资源路径未做范围校验：`..` 与软链接可读到静态根之外的任意文件（默认根还是进程 CWD）

- **位置**：`f_mvc/src/RequestMeta.cj:108-137`（`loadStaticResource`：拼接 `:114`、软链接解析 `:117`、整文件读 `:123-132`）；调用链入口 `f_mvc/src/HttpRequestDistributorImpl.cj:64-69` → `f_mvc/src/RequestMeta.cj:693-722`（`StaticResourceOrNotFoundHandler`）；默认根 `f_mvc/src/MVCConfig.cj:283-290`
- **来源**：存量（`git blame -L 108,137` ⇒ `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §11（外部输入未校验）+ §10（安全性）+ §5（整文件物化）
- **证据**：静态确定 —— 三点闭合：① `STATIC_RESOURCE_ROOT.join(p)` 只做字符串拼接，std 文档原文「本方法仅进行字符串拼接，不处理 `..` 等路径遍历组件。如需安全验证，请先调用 `canonicalize` 并检查路径范围」（`std/fs/fs_package_api/fs_package_structs.md:1686-1688`），代码两件事都没做；② 请求路径是**已解码**的 `URL.path`（stdx 文档 `encoding/url/url_package_api/url_package_classes.md:601`：「获取解码后的路径」）⇒ `%2e%2e` 会还原成 `..`，客户端不需要发原始 `..`；③ 未命中路由的任意路径都会进本函数（`distribute` 的 `case _`）
- **描述**：`GET /%2e%2e/%2e%2e/etc/passwd` → `CWD/../../etc/passwd` → `exists` 成立 → 整文件读出并 200 返回。即使不让 `..` 通过，`SymbolicLink.readFrom(p, recursive: true)` 会把静态目录内的软链接解析到任意目标后照样读，没有任何「解析后仍在根内」的复查。更严重的是**默认配置下静态根 = 进程工作目录**（`MVCConfig.cj:288` 未配置时返回 `getWorkingDirectory()`），因此不带 `..` 的 `GET /cjpm.toml`、`GET /src/xxx.cj` 也能直接读到；静态资源这一路径没有任何鉴权。
- **建议**：`let p = canonicalize(root.join(path))`，随后断言 `p.toString().startsWith(canonicalRoot.toString() + "/")`，不满足直接 404；拒绝任何含 `..` 段的请求路径；未配置 `mvc_staticResourceRoot` 时**关闭**静态资源（而不是回落到 CWD）；软链接解析后再做一次范围断言（或直接 `refuse symlink`）。修复后用 `curl --path-as-is 'http://host/%2e%2e/cjpm.toml'` 与一条软链接用例钉住。

### 2. [一般][存量] `params` 条件在请求没有查询串时恒为 false ⇒ 带 `params` 规则的路由对 POST 表单请求不可达（回 501）

- **位置**：`f_mvc/src/RequestCondition.cj:22-29`（`:26-28` 的 `else { false }`）；消费方 `f_mvc/src/RequestMeta.cj:193-196` → `f_mvc/src/MultiRequestMethodHandler.cj:68-69`
- **来源**：存量（`git blame -L 22,29` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（边界 / 语义错误）；后果归 §11「契约与实现不符」
- **证据**：静态确定 —— `url.rawQuery` 的类型是 `?String`，「没有查询串时为 None」（stdx `url_package_classes.md:779-787`；仓内同样结论见 `f_jsonrpc/src/server/SseController.cj:38-39` 注释）。`rawQuery` 为 `None` 时整个表达式短路到 `false`，`check(form)` 的真实结果被丢弃
- **描述**：`@PostMapping(path: "/x", params: "action=create")` 收到 `application/x-www-form-urlencoded` 的 POST（URL 无 `?`）时：表单里明明有 `action=create`，条件仍判 false → 路由不匹配 → 走 `NOT_IMPLEMENTED`（501，见第 2 部分发现 #4）。`DummyRequestCondition` 自己覆盖了 `check(form, url)`（`RequestCondition.cj:73-75`）所以「无规则」的路由不受影响，正好把缺陷掩住；只有真正带规则的控制器会中招。
- **建议**：`else` 分支改为返回 `check(form)`（查询串缺失只说明「没有额外来源」，不说明「条件不成立」）；同时补一条 `params` + POST 表单的用例。

### 3. [一般][存量] 静态资源读取把磁盘 I/O 放在 `ConcurrentHashMap.entryView` 的原子回调里（锁内 I/O，请求线程互相阻塞）

- **位置**：`f_mvc/src/RequestMeta.cj:109-136`（`entryView` 起于 `:109`，`FileInfo` 在 `:115`，`File.readFrom` 在 `:126`/`:128`）
- **来源**：存量（`git blame -L 109,136` ⇒ `4be871f2fd`）
- **判据**：review-checklist §12.2 / §6.2（临界区内含 I/O）；`perf §8.3`
- **证据**：静态确定 —— `ConcurrentHashMap.entryView` 文档明确「该操作具有原子性…回调 fn 调用过程中对 key-value 键值对的修改不会即时更新，等 entryView 调用结束再整体更新」（`std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1219-1247`）；这里的回调体包含 1 次 stat + 1 次 O(文件大小) 的整读
- **描述**：临界区内容 = `exists` + `FileInfo` + `File.readFrom(整个文件)` + 元组构造。并发访问者 = 所有 HTTP 线程；同 key 首次访问的请求串行等待一次完整磁盘读，落在请求主路径上（未命中路由的请求才走这里，但扫描器/正常静态资源访问都会命中）。持有时长量级 = 磁盘读延迟（冷缓存下毫秒级、大文件更高）。
- **建议**：锁外先 `stat` + 读，再 `putIfAbsent`/条件替换（允许并发首读的重复工作，代价远小于锁内 I/O）；或对同一 path 做单飞（每 key 一把锁 / future）。另见优化 O1（整文件永久驻留）。

### 4. [一般][存量] `checkProduces` 用整条 `Accept` 串与 `produces` 精确比较：合法的单值带参数 `Accept` 一律被判 406

- **位置**：`f_mvc/src/RequestMeta.cj:171-191`（`:173` 的 `produces.contains(accept)`，`:185-187` 的 `else false`）；`produces` 的构成 `:463-492`；辅助类型 `f_mvc/src/AcceptQueue.cj:37-48`
- **来源**：存量（`git blame -L 171,191` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（与 HTTP 规范 / 契约不符）+ §6.4（同一输入重复解析）
- **证据**：静态确定 —— `produces` 里存的是 `addMediaTypes` 切分后的裸媒体类型（`application/json` 等），`accept` 是整条头值；带参数（`;charset=utf-8`、`;q=0.9`）且**不含逗号**时既进不了 `contains`，也进不了 `indexOf(',')` 分支，直接返回 false
- **描述**：`Accept: application/json;charset=UTF-8`（部分 Java/Go 客户端默认形态）→ 406 Not Acceptable，控制器根本不会被调用。多值头略好但仍不完整：`AcceptQueue` 只剥离 `;q=`（`AcceptQueue.cj:37-46`），`application/json;charset=utf-8, */*` 里的第一项仍带 `;charset=`，`produces.contains(c)` 同样失配。
- **建议**：比较前把候选值归一化为 `type/subtype`（按 `;` 第一次出现截断并 `trimAscii`），或统一用 `AcceptQueue` 输出的裸类型；`produces` 侧入库时也做同样归一化。补一条 `Accept: application/json;charset=UTF-8` 的用例。

### 5. [一般][存量] 二进制/流式响应把 `Accept` 原串或字面量 `*/*` 写进 `Content-Type`

- **位置**：`f_mvc/src/RequestMeta.cj:144-151`（`populateResponseContentType`，缺失时硬编码 `*/*`）；调用点 `:396-404`（`InputStream`）、`:406-411`（`Array<Byte>`）、`:412-417`（`String`，本身是死代码，见 #12）
- **来源**：存量（`git blame -L 144,151` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符）+ §13（`produces` 声明被无视）
- **证据**：静态确定 —— 响应头值 = 请求头 `Accept` 的完整字符串，缺省写 `*/*`
- **描述**：`curl` 默认 `Accept: */*`、无 `Accept` 的 SDK 调用、浏览器预取的 `Accept: image/avif,image/webp,*/*` 都会产出 `Content-Type: */*` 或含逗号的多值头——两者都不是合法的实体头值，严格客户端/网关会拒绝或按未知类型处理（图片、PDF 下载因此可能被当成二进制乱码）。正常 `ToData` 路径靠 `checkProduces` 把 `Accept` 改写成单项掩盖了问题，而 `*/*`/缺省不进改写分支，所以这条路径稳定复现。
- **建议**：`Content-Type` 只取「协商结果」：`produces` 中与 `Accept` 匹配的那一项；无 `Accept` 时取 `produces` 的**有序**第一项（见 #7）；绝不再写 `*/*`；补一条 `Array<Byte>` + `Accept: */*` 的头断言用例。

### 6. [一般][存量] 多文件下载的响应体不是合法 multipart：段间缺 boundary、后续段头缺终止空行、空输入不 build 响应

- **位置**：`f_mvc/src/ResponseDownload.cj:34-49`（`download<C>`，`:40` 调 `next(d[1], '')`）、`:51-65`（`download(Array<File>)`，`:59` 调 `next(..., '')`）；写头实现 `f_mvc/src/FileDownload.cj:118-136`（`next` / `end`）
- **来源**：存量（`git blame -L 34,65 -- ResponseDownload.cj` / `-L 118,136 -- FileDownload.cj` ⇒ `4be871f2fd`；注释里的 `MVC-4` 修复只保证写完实读长度）
- **判据**：review-checklist §11（契约与实现不符）+ §3（空输入走进空分支）+ §2（两处同语义循环的重复实现）
- **证据**：静态确定 —— ① `next()` 只写 `Content-Disposition`（可选 `Content-Length`）、且**仅在 `contentType.size > 0` 时**才补 `\r\n\r\n`，从不写段分隔 `\r\n--${boundary}\r\n`；② 两个多段入口在第二段起都传 `contentType = ''` ⇒ 头连终止空行都没有；③ 空集合/空 Iterable 时 `start` 从未被调用，`responseBuilder` 没有 `build()/body()`，`end()` 只往 `pipe` 写一个 boundary
- **描述**：README 承诺 `multi` 下载的响应头是 `multipart/x-mixed-replace; boundary=…`（`f_mvc/README.md:1295-1300`，函数清单 `:1308-1316`）。实际输出为 `--boundary\r\n` + 段 1 头 + 段 1 体 + `Content-Disposition:…`（无分隔、无空行）+ 段 2 体 + `\r\n--boundary\r\n`，客户端会把第二段的头当正文、把段 2 当段 1 的延续；段 2 起的 `Content-Type` 声明也整体丢失。空输入时响应体永远等不到 `body(pipe)` 的提交（挂起或空 200，取决于 stdx 收尾）。全仓 `download(` 无任何调用点，`response_download_test.cj` 只覆盖 `copy`，因此长期未暴露。
- **建议**：`next()` 首行补 `write("\r\n--${boundary}\r\n")`（首段由 `start` 负责，不重复），并**无条件**写 `\r\n\r\n` 结束头；两个多段入口在空输入时直接 `204`（或写一个只有首尾 boundary 的合法空体）并 `build()`；把两个 `for` 循环收敛成一个 `(InputStream, String, ?Int64)` 迭代器上的实现（顺带消除 `started` Box 与 `i == 0` 两种写法）；补 e2e 断言：`--boundary` 出现次数 = 段数 + 1、每段头后存在空行、段 2 的 `Content-Disposition` 在分隔符之后。

### 7. [一般][存量] 访问日志的 `Array<Byte>` / `MultipartFile` / `Data` 分支不可达：二进制请求/响应体以十进制列表整段进日志

- **位置**：`f_mvc/src/RequestMeta.cj:601-634`（`lazyAccessLogFields.anyToString`）：`:611` `case x: ToString`、`:612` `Array<Byte>`、`:613` `MultipartFile`、`:615` `Data`
- **来源**：存量（`git blame -L 601,634` ⇒ `4be871f2fd`；不可达由 2026-11-28 前的既有构建日志证实）
- **判据**：review-checklist §1（不可达分支）+ §8（日志放大）+ §10（敏感数据进日志）
- **证据**：静态确定（编译器告警）—— 构建日志报 `RequestMeta.cj:612:22`、`613:22`、`615:22` 三处 `unreachable pattern`：`Array<Byte>`、`MultipartFile` 都实现了 `ToString`，被 `:611` 先截获；`Data <: ToString`（`f_data/src/base/Data.cj:18`）同样被截获
- **描述**：原本想对字节数组走 `toBase64String`、对 Multipart 走 JSON，实际全部走 `Array.toString()`。后果：控制器返回 `Array<Byte>`（图片、PDF、protobuf）或接收 `@RequestBody Array<Byte>` 时，访问日志会把**整个**载荷写成 `"[137, 80, 78, 71, …]"`——体积约 4× 字节数，且文件内容/上传内容明文落盘（`log.info` 默认开启，闭包只在启用时求值，但 info 档默认就是启用的）。
- **建议**：把 `Array<Byte>` / `MultipartFile` 判到 `ToString` 之前；即便前移，也应按长度截断（如「前 64 字节 base64 + 总长」），避免大 body 放大；`Data` 分支按需前移或删除。

### 8. [一般][存量] `WSMeta.generate` 对同类 `@OnWS*` 注解静默覆盖：后注册者生效，先注册者永不执行

- **位置**：`f_mvc/src/WSMeta.cj:374-408`（`:379`、`:383`、`:387`、`:391`、`:395`、`:399`、`:404` 的 `meta.xxx_ = m`）
- **来源**：存量（`git blame -L 374,408` ⇒ `4be871f2fd`）
- **判据**：review-checklist §3（静默覆盖 / 无提示失效）+ `fountain-baseline.md §4`（同名注册应启动直接失败，不做隐式优先级）
- **证据**：静态确定 —— `typeInfo.instanceFunctions` 的迭代顺序未定义，赋值前没有 `isNone()` 检查；同一端点写两个 `@OnWSText` 时，`textMeta_` 被后者覆盖，前者永远拿不到帧，无日志无异常
- **描述**：这是「控制器写错」最容易被误判成「框架不回调」的形态；同一模块里 `RequestMeta.generate` 对重复注解是**抛异常**（`RequestMeta.cj:517/523/529`：`Mapping annotation … is duplicated`），两条注册路径的行为相反，属行为漂移。
- **建议**：每个 `meta.xxx_` 赋值前检查 `isSome()`，命中即抛 `WSException('duplicated @OnWSText on ${funcName}')`；与 HTTP 侧对齐。补一条「两个 `@OnWSText` ⇒ 启动失败」的用例。

### 9. [一般][存量] `WSCloseFrame(payload:)` 对空/1 字节载荷直接越界；RFC 允许无状态码的 Close 帧

- **位置**：`f_mvc/src/WSCloseFrame.cj:108-111`（`:109` `payload[0]`/`payload[1]`，`:110` `payload[2..size]`）
- **来源**：存量（`git blame -L 105,111` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（边界差一 / 空集合未处理）+ §10
- **证据**：静态确定 —— 无任何长度判断；README 把该类型定义为关闭帧的表示（`f_mvc/README.md:1216`「帧类型 `WSCloseFrame` 表示关闭帧」），而 RFC 6455 §5.5.1 明确 Close 帧载荷可以为空（此时状态码视为 1005）
- **描述**：外部按 `WSCloseFrame(frame.payload)` 解析一个「无状态码关闭」帧 → `IndexOutOfBoundsException`；1 字节载荷（非法但可到达）同样崩。异常会穿到调用方（框架自身不构造该类型，因此只在库使用者侧触发）。
- **建议**：`size == 0` ⇒ `status = 1005`、`reason = ''`；`size == 1` ⇒ 抛明确的协议异常（或 1002）；只有 `size > 2` 才解码 reason，`String.fromUtf8` 失败按 1007 处理。构造器改成可失败的 `tryCreate` 或文档写明只接受 ≥2 字节。

### 10. [一般][存量] 单例 controller 的惰性缓存 `Box<?T>` 被多请求线程无同步读写（非同步发布）

- **位置**：`f_mvc/src/RequestMeta.cj:202-215`（`:206` `Box<?T>(None<T>)`，`:208-213` 读 `cached.value` / 写 `cached.value`）
- **来源**：存量（`git blame -L 197,247` ⇒ `4be871f2fd`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出 / 可见性）
- **证据**：静态确定（存在无同步的共享读写）；具体失效概率需实测 —— 该闭包由 `handle_` 持有并被所有 HTTP 线程调用，`cached` 无锁、无 `Atomic`、无 `once`
- **描述**：两个并发首访请求都会 miss 并各自 `getBean`（单例场景为一次多余构造 + 一次多余锁竞争），并发写同一字段本身即数据竞争；更关键的是非同步发布：另一线程可能看到 `Some(ref)` 而看不到该 bean 构造期写入的字段（内存模型不保证 happens-before）。注释解释了「必须惰性」的原因（注册期其它库 bean 未就绪），但惰性不等于可以不加同步。
- **建议**：`Mutex` 保护的 double-check，或 `f_concurrent` 的 once/`Atomic`；或让 `BeanFactory` 提供 `getBeanLazily` 语义（内部同步）。修复后跑一次「32 线程同时首访」的压力用例，断言只构造一次且字段可见。

### 11. [一般][存量] `params` / `headers` 规则：参数值取 token 原文（含引号）可能永不匹配；`=` 分支语义自相矛盾；该能力零用例

- **位置**：`f_mvc/src/RequestCondition.cj:37-49`（`:41-43` `e.arguments[i].expr.toTokens().toString()`）、`:50-57`（`EQUAL`/`NOTEQ`/`SUB`）、`:112-120`（`EqualRequestCondition`）；承诺源 `f_mvc/README.md:124-131`
- **来源**：存量（`git blame -L 32,68` ⇒ `4be871f2fd`）
- **判据**：review-checklist §13（文档与实现一致性）+ §11（语义与命名不符）+ §14（文档化能力无覆盖）
- **证据**：待确认 —— 需一条运行期用例；间接证据两条：`f_data/src/path/DataPath.cj:264-268` 必须手工剥掉首尾引号（说明 token 原文带引号），`f_data/src/path/ObjectEqFilter.cj:69-70` 也专门注明「`STRING_LITERAL.value` 不含引号」
- **描述**：三个可疑点。① README 的示例全部用带引号的字面量（`contains('1','2')`、`subset('s','d')`、`| 'orderTime'`），而这里直接把 `Expr.toTokens().toString()` 当值——若它保留引号，`values` 就是 `{"'1'"}`，与表单值 `1` 永不相等，`contains/subset` 恒 false；带引号的裸规则（`'orderTime'`）更会落到 `:58` 的 `illegal expression` 直接启动失败。② `EQUAL` 分支把右侧标识符的**名字**当值比较：`a==b` 意为「a 的某个值等于字符串 "b"」，而 `a=1`（右值是数字字面量）会让 `compile` 抛 `MVCException`；`SUB` 分支则把 `a-b` 拼成一个参数名，语义无出处。③ README 内部自相矛盾：`:129` 说 `contains` 是「参数/头**名称**需要包含括号内的名称」，`:131` 的例子说「参数 a 的**值**需要同时包含 '1' 和 '2'」（实现按后者）。全模块 0 个 `RequestCondition` 测试（`grep RequestCondition f_mvc/src/*_test.cj` 无命中），所以上述任一条都不曾被验证。
- **建议**：取参数值时剥一层引号（复用 `DataPath` 的既有写法），并支持数字字面量（`EQUAL` 右侧允许 `LitConstExpr`）；删除或明确 `SUB` 分支的语义；README 的 `:129` 与 `:131` 统一；补 6 条规则级用例（`&`、`|`、`!`、`contains`、`subset`、带引号字面量）。

### 12. [轻微][存量] 死代码与死存储 7 处（编译器 `unused` 告警 + 全仓搜索双证）

- **位置**：
  - `f_mvc/src/RequestMeta.cj:167-170` `private func checkHeader` —— 全仓唯一命中是定义处，构建日志 `unused function:'checkHeader'`
  - `f_mvc/src/RequestMeta.cj:412-417` `private func respond(response: String, ctx:)` —— `setHandle` 的 match（`:225-237`）没有 `String` 分支（`String` 走 `ToData`），构建日志 `unused function:'respond'`
  - `f_mvc/src/RequestArgMeta.cj:31-33` `func contains` —— 内部类成员，全仓无调用
  - `f_mvc/src/RequestCondition.cj:113` `EqualRequestCondition(name: String, value: String)` —— `compile` 只用 `(RequestCondition, RequestCondition)` 那个 init（`:53-54`），String 版无调用
  - `f_mvc/src/RequestMeta.cj:322` `result is Unit` —— `R <: ToData`，`Unit` 不实现 `ToData` ⇒ 恒假
  - `f_mvc/src/RequestMetas.cj:21` `metas` 只写不读 —— 唯一写入 `RequestMeta.cj:557`，`private` 且无访问器（历史记录 `.autocode/bugs/bug-mvc-archived-20261006.md:257`，用户已判「不改」，此处仅登记）
  - 未使用形参：`RequestCondition.cj:19` `form`、`WSMeta.cj:36` `ws`、`RequestMeta.cj:418` `ctx`（三者均有 `unused variable` 告警）
- **来源**：存量（均为 `4be871f2fd` 及更早）
- **判据**：review-checklist §1（不可达 / 无调用者 / 读了不用）
- **证据**：静态确定 —— 每个符号都给了「全仓搜索唯一命中定义处」或编译器告警，两点互证
- **描述**：`checkHeader` 与 `respond(String)` 是「曾经有调用者、后来接线被删」的残留，容易被误读为现行策略（尤其 `respond(String)` 里还写着 `Accept` 当 `Content-Type` 的旧逻辑）；`RequestMetas` 为一张无人读取的有序表在注册期付出 TreeSet 维护 + `RequestMeta.compare`（每次比较新建 2 个 `TreeSet`）的成本。
- **建议**：删除 5 处死符号与 3 个未使用形参（或改 `_`）；`RequestMetas` 按历史结论保持不动，若要动内部结构（`TreeSet` → `ArrayList`）需单独立项。

### 13. [轻微][存量] `RequestMeta.compare` 不比较 `produces`/`params`/`headers`：两条不同路由会被 `TreeSet` 判为重复

- **位置**：`f_mvc/src/RequestMeta.cj:87-103`
- **来源**：存量（`git blame -L 87,103` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符：`Comparable` 应区分不同对象）
- **证据**：静态确定 —— 比较键只有 `path` → `method` → 排序后的 `consumes` → `consumes.size`；两条只有 `produces` 不同的 meta 返回 `EQ`
- **描述**：`TreeSet` 以 `compare == EQ` 去重，因此第二条被静默丢弃。当前唯一消费者是只写不读的 `RequestMetas`（#12），所以暂无功能影响；一旦有人接上读取（历史设计文档里 f_jsonrpc 曾设想 `all()`），就会静默丢路由。
- **建议**：补全比较键（`produces`、`params`/`headers` 的规则文本或指针），或把容器改为 `ArrayList` 并在注释里写明「允许同键多条」。

### 14. [轻微][存量] WebSocket 关闭码常量重复/错值，且常量类型与 `WSCloseFrame.status` 不一致

- **位置**：`f_mvc/src/WSCloseFrame.cj:65`（`WS_FRAME_TYPE_UNMATCH = 1008`）与 `:73`（`WS_ANTI_STRATEGY = 1008`）；`:106` `status: UInt16`；其余 `public const`（`:22-103`）均为 `Int64`
- **来源**：存量（`git blame -L 59,103` ⇒ `4be871f2fd`）
- **判据**：review-checklist §11（语义与命名不符 / 复制粘贴错值）
- **证据**：静态确定 —— 两常量同值 1008；`:59-65` 的注释描述的是「帧类型不一致」，对应 RFC 6455 的 1007（invalid frame payload data），1008 已被 `WS_ANTI_STRATEGY` 占用
- **描述**：使用者按常量发 1007 会实际发出 1008（策略违规），排障时语义错位；`status` 是 `UInt16` 而常量是 `Int64`，`frame.status == WS_NORMAL_CLOSE` 编译不过，需要手写转换——公开 API 的自洽性缺口。
- **建议**：`WS_FRAME_TYPE_UNMATCH` 改 1007；所有关闭码常量显式标注 `: UInt16`（并顺带修正 `WS_RESERVED_DISEXISTENCE` 之类拼写）。

### 15. [轻微][存量] WS 帧处理三处控制流/静默丢弃不一致

- **位置**：`f_mvc/src/WSMeta.cj:306-308`（未知帧类型 `closeConn()` 后没有 `return true`）；`:217`（`openMeta_?.handle(...)` 返回值被丢弃）；`:24-34`（`setHandle` 在 `mediaType` 为空且返回值非 `Array<Byte>` 时静默返回空帧）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §3（静默丢弃 / 空实现）+ §11（控制流不一致）
- **证据**：静态确定 —— 同一 `match` 里其余三个「关闭」分支（`:273-274`、`:304-305`）都 `return true`，只有 `case _` 缺；`setHandle` 的整段包装只为处理返回值，`exec` 却对 open 的返回值不做任何事；`case _ => []` 把非字节返回值吞成空载荷且无日志
- **描述**：未知帧类型关闭连接后循环继续 `read()`，下一次读抛异常并穿出 `pumpFrames`（绕过「正常 return」路径），日志上是 `ConnectionException` 而不是「不支持该帧」；`@OnWSOpen` 处理函数返回字节时客户端收不到任何帧（README 只说「需要主动写时声明 WebSocket 参数」，未说明返回值会被丢弃）；`mediaType` 为空却返回 `String`/`Data` 时得到空 ping/text 帧。
- **建议**：`case _` 补 `return true`；open 分支要么 `ws.write` 返回值、要么在文档里明确忽略并在 `setHandle` 里拒绝非字节返回（启动期报错）；`mediaType` 为空时对非 `Array<Byte>` 返回值抛 `WSException`（明确契约），不要静默空帧。

### 16. [轻微][存量] WS 错误日志把整帧 payload 做 base64

- **位置**：`f_mvc/src/WSMeta.cj:302`（close 处理失败）、`:311`（任意帧处理失败）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §8（日志放大）+ §10（敏感数据进日志）+ `fountain-baseline.md §6`
- **证据**：静态确定 —— `toBase64String(frame.payload)` 在 `log.error` 的消息闭包里，按帧大小分配 1.33× 临时串
- **描述**：一个 1 MB 的二进制帧出错 → 每次错误额外分配 ~1.4 MB 字符串并落盘，业务载荷（可能是图片、加密报文、个人信息）整体进入日志；错误帧若是攻击者构造，可低成本放大日志。
- **建议**：只记 `frame.frameType` + `payload.size` + 前 32 字节的 hex；完整载荷改为 debug 级且带开关。

### 17. [轻微][存量] 缺键路径抛 `NoneValueException`（而非框架异常），`isMultipart` 等公开方法的错误契约是「崩」

- **位置**：`f_mvc/src/RequestArgMeta.cj:35-37`（`args[name][0]`）；受影响 `f_mvc/src/RequestMeta.cj:424-426`（`isMultipart`）、`f_mvc/src/WSMeta.cj:36-41`（`extract`）、`WSMeta.cj:320-332`（`extract*Arg`）；同类问题 `f_mvc/src/RequestCondition.cj:38`（`(e.callFunc as MemberAccess).getOrThrow()`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11（错误处理缺失）+ §10（`Option` 被 `getOrThrow` 静默转成 std 异常）
- **证据**：静态确定 —— std 文档 `collection_package_class.md:6147-6165`：`HashMap[key]` 缺键抛 `NoneValueException`；`as` 强转失败同样抛 std 异常
- **描述**：这些方法本身是对外 API，参数名来自使用者（例如 `extractTextArg(ctx, "typo")`），错误表现为 `NoneValueException`（无上下文），而不是「该端点没有注册名为 X 的参数」；`RequestMeta.extract` 里精心写的 `HttpRequestException('NO param for controller func…')`（`:451-452`）对「名字未注册」这一情形其实到不了。
- **建议**：统一 `args.get(name)` + 抛 `MVCException`/`HttpRequestException` 并带上端点/参数名；`compile` 的 `as` 改 `match`。

### 18. [轻微][存量] 测试：两处偶发/静默失败风险，下载与条件规则零覆盖

- **位置**：`f_mvc/src/WSMeta_test.cj:48-49`（`@Assert(0, pings.value)`）；`f_mvc/src/WSEndPointMacro_test.cj:48,52-70`（固定端口 `18100`，50 次探测失败后仍 `return server`）；`f_mvc/src/response_download_test.cj:16-83`（只测 `copy`）
- **来源**：存量（2026 年新增测试文件）
- **判据**：review-checklist §11（测试自身缺陷）+ §14（能力无覆盖）
- **证据**：静态确定 —— 断言 `pings == 0` 依赖「`Timer.repeat(10ms)` 的首次 tick 一定晚于 `readFrame` 抛异常」，两者无同步；`startServer` 的失败分支不抛错，后续断言表现为「握手失败」，排查成本高；5 个 `download` 只有 `copy` 有用例，`RequestCondition`/`Series`/`WSCloseFrame` 完全没有
- **描述**：这不是产品缺陷，但直接解释了 #6、#11、#9 长期未被发现：最容易出错的边界（多段下载、规则表达式、空 Close 帧）恰好没有用例。
- **建议**：`pings` 断言放宽为 `<= 1`（并保留「退出后 3 个周期不再增长」这条真正的判据）；端口改从环境/随机可用端口取，探测失败时 `throw`；补 #6/#11/#9 的最小用例（可直接复用现有 `copy`/`pumpFrames` 风格的内存假对象）。

## 优化可行性方案

> 本部分未提供任何 bench / profile 数据，以下均为**待验证**方案，不进 `todo.md` / `tasks.md`。

### [堆内存] 静态资源缓存无上限：整文件常驻 + 一次性整读

- **现状**：`RequestMeta.staticResourceBytes`（`RequestMeta.cj:46`）是 `ConcurrentHashMap<String,(DateTime,Array<Byte>)>`，无容量、无大小上限、无淘汰；每个被请求过的静态文件整份 `Array<Byte>` 常驻直到进程结束（`loadStaticResource:123-132` 一次性 `File.readFrom`）
- **方案**：读前 `stat` 拿 size，单文件超过阈值（如 8 MiB）走流式（`File` → `InputStream` 直写响应，不缓存）；缓存改为「总字节上限 + LRU」或按 mtime 短 TTL
- **预期**：RSS 与「被请求过的静态文件总量」解耦；单个超大文件不再一次性进堆（当前 1 GB 文件 = 1 GB 常驻 + 1 GB 瞬时）
- **代价**：超阈值文件每次请求多一次 open/read；LRU 需要一把锁或分段结构（注意别再引入 #3 的锁内 I/O）
- **验证**：依次请求 10k 个不同大小的文件，多轮后 `getUsedHeapSize()` / RSS 是否收敛到上限；对照当前实现
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `download(Array<Byte>)` 双份全长拷贝

- **现状**：`ResponseDownload.cj:28-32`：`Array<Byte>` → `ByteBuffer.write(data)`（第一份全长副本）→ 按 `downloadBufferSize` 分块再拷进 pipe（第二份分块副本）；峰值 ≈ 2× body
- **方案**：长度已知时直接 `FileDownload.write(filename, ByteBuffer(data), length: data.size)`（`SyncByteBuffer` 已实现 `InputStream`），省掉中间副本；或把 `Array<Byte>` 包成只读 `InputStream` 视图
- **预期**：峰值内存从 2×body 降到 1×body（10 MB 下载省 10 MB）
- **代价**：需确认 `ByteBuffer` 的 `read` 语义（不额外复制）；无行为变化
- **验证**：`download(10 MB Array<Byte>)` 的 peak `getAllocatedHeapSize()` 前后对照（同 SDK、`-O2`、5 轮取中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `RequestMethod.parse` 每请求一次 `toAsciiUpper()` 分配

- **现状**：`RequestMethod.cj:79-91` `tryParse` 先 `value.toAsciiUpper()`（每请求 1 个短串分配）再做 8 路字符串比较；`parse` 再叠一层 `getOrThrow` 闭包（`:95-97`）。调用点 `MultiRequestMethodHandler.cj:64`，每请求 1 次
- **方案**：先与 8 个大小写正确的字面量精确比较（命中即返回），未命中再走 `toAsciiUpper` 兜底；`parse` 的 `getOrThrow` 改成显式 `match` + 预构造异常
- **预期**：常见请求（方法名本就是大写）省 1 次短串分配与 1 次比较链；收益量级需 profile 确认
- **代价**：多 8 行比较；非规范大小写请求多一次比较
- **验证**：`cjprof record` 跑 10k 请求，看 `RequestMethod.tryParse` 自耗时占比与分配计数
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能/行为数据支撑的推断，只用于下一轮补证据，不计入统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ArrayList.unsafeData()` 返回的数组长度可能大于逻辑长度（尾部分未初始化），WS 帧 payload 直接传给 handler 会带尾部垃圾 | `f_mvc/src/WSMeta.cj:227` | `unsafeData().size == size()` 的直接证据（std 文档未收录该 API；`f_base` 的 `toArray()`（`ExtendIterator.cj:46-48`）与 `StringGenerator.append`（`:45-47`）按「等于逻辑长度」使用，只能间接支持） | 加一条单测：`let l = ArrayList<Byte>(); l.add(all: [1,2,3]); @Assert(3, l.unsafeData().size)`；若 >3，则 WS 文本/二进制帧解析全部受污染，需改成 `bytes.toArray()` 或 `[0..size]` 切片 |
| 2 | 带引号的规则参数值保留引号 ⇒ README 示例规则恒 false | `f_mvc/src/RequestCondition.cj:41-43` | `Expr.toTokens().toString()` 对字符串字面量是否带引号的运行期事实 | 单测 `RequestCondition.compile("a.contains('x')")`，用 `Form` 造 `a=[x]` 断言 `check` |
| 3 | `RequestMethod.tryParse` 的 `toAsciiUpper` 分配在端到端 CPU 中占比 <1% | `f_mvc/src/RequestMethod.cj:79-91` | `cjprof` self time 占比 + 分配计数 | 网关空转场景 10k 请求（GET/POST 混合），`cjprof record/report` |
| 4 | `url.queryForm` 每请求被解析多次（`check` 1 次 + 每个 `@RequestParam` 1 次），是可选优化点 | `f_mvc/src/RequestCondition.cj:24`、`f_mvc/src/ControllerFuncParam.cj:54` | 单次解析耗时 × 每请求次数 | 分段计时或 `cjprof`，控制器带 5 个 `@RequestParam` 的场景 |
| 5 | `@WSPing(duration: '0s')` 会让 `Timer.repeat(0, 0, …)` 空转 | `f_mvc/src/WSMeta.cj:96,259` | `Timer.repeat` 对 0 间隔的行为 | 单测或最小服务，观察 1s 内 ping 次数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/RequestArgMeta.cj` | .cj | ✅ | 见 #12（死方法 `contains`）、#17 |
| 2 | `f_mvc/src/RequestCondition.cj` | .cj | ✅ | 见 #2、#11、#12、#17 |
| 3 | `f_mvc/src/RequestMapping.cj` | .cj | ✅ | 五个注解仅 method/consumes 默认值不同，无缺陷（见 #13 的 §2 说明） |
| 4 | `f_mvc/src/RequestMeta.cj` | .cj | ✅ | 见 #1、#3、#4、#5、#7、#10、#12、#13 |
| 5 | `f_mvc/src/RequestMeta_test.cj` | .cj | ✅ | 只覆盖包内接缝（`lazyAccessLogFields` / `respondKind` / `closeResultIfResource` / `finishRequest`），无端到端；见 #18 |
| 6 | `f_mvc/src/RequestMetas.cj` | .cj | ✅ | 见 #12（只写不读） |
| 7 | `f_mvc/src/RequestMethod.cj` | .cj | ✅ | 8 个方法 / 常量 hashCode / `==` 含 `WS` 分支均正确；`parse` 抛异常与 `Allow` 问题已在第 2 部分报告，不重复 |
| 8 | `f_mvc/src/RequestMethod_test.cj` | .cj | ✅ | 4 条用例覆盖 hashCode 唯一性、声明序、`WS` 自反与容器键，与实现一致 |
| 9 | `f_mvc/src/ResponseDownload.cj` | .cj | ✅ | 见 #6；`copy` 的 `bytes > 0` 循环与 `MVC-4` 修复一致 |
| 10 | `f_mvc/src/Series.cj` | .cj | ✅ | 1–5 系列映射、`valueOf`/`resolve` 语义正确；无缺陷（`values` 每次新建数组属公开 API 的既有形态） |
| 11 | `f_mvc/src/WSCloseFrame.cj` | .cj | ✅ | 见 #9、#14 |
| 12 | `f_mvc/src/WSDataFrame.cj` | .cj | ✅ | 两个帧参数类型行为一致；HTTP 重载抛无消息 `MVCException` 属防御性占位（不可达路径），未计为缺陷 |
| 13 | `f_mvc/src/WSEndPointMacro_test.cj` | .cj | ✅ | 见 #18（固定端口 + 就绪失败不报错） |
| 14 | `f_mvc/src/WSMeta.cj` | .cj | ✅ | 见 #8、#15、#16、#17 |
| 15 | `f_mvc/src/WSMeta_test.cj` | .cj | ✅ | 见 #18（`pings == 0` 竞态断言） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。本部分清单不含 `.md`；README 仅作承诺源取证（`:124-131`、`:1295-1300`、`:1308-1316`、`:1216`），文档正文由其它部分负责。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #2/#4/#5/#6/#9/#11；安全性 #1/#7/#16；设计 #3/#8/#10；语言特性（`Option` 被 `getOrThrow` 吞掉）#17 |
| §1 死代码 | 7 | `checkHeader`、`respond(String)`、`RequestArgMeta.contains`、`EqualRequestCondition(String,String)`、`result is Unit`、`RequestMetas.metas` 只写不读、3 个未使用形参 —— 每个都做了全仓搜索或引用构建告警；其余 `private`/`internal`/`protected` 符号逐个搜过均有调用者；对外可达 `public`（`RequestMethod`、`Series`、`WSCloseFrame`、`WSMeta` 及其 props、`download` 系列）按硬原则一不判 |
| §2 重复逻辑 | 1（#13 内记录，不合并） | 两两比对 15 个文件的函数体：五个 Mapping 注解、`WSTextMeta`/`WSBinaryMeta`、6×2 `extract*Arg` 属「只改类型名」，但都是公开注解/API 契约，合并会破坏对外面，结论是保留；`FileDownload.next` 与两个多段 download 循环已并入 #6；Accept 解析的 4 份实现并入 #4/#5 |
| §3 空实现 | 3 | #6（空输入走不到 `start`）、#8（静默覆盖）、#15（返回值丢弃 / 静默空帧）；无 `TODO`/`FIXME`/空函数体 |
| §4 栈溢出 | 0 | 本部分无递归：`compile` 递归深度由规则表达式长度决定（配置期、非外部输入），`pumpFrames` 是迭代读帧；未见自引用结构 |
| §5 OOM | 2 | #1（整文件读 + 无界缓存）、#3（锁内整读）；`extractBytes` 受 `maxRequestBodySize` 约束，不单列 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench；`RequestMethod.parse`、`queryForm` 重复解析已列入待验证假设，未写成缺陷 |
| §6.2 大粒度锁 | 1 | #3（`entryView` 原子回调内含 stat + 整读） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`+`get()`；`FileDownload` 的异步派发属其它部分 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配 / `remove(at:0)` / 循环拼串；`compare` 里建 TreeSet 只在注册期（已并入 #13 的描述，不单独计） |
| §7 降堆内存方案 | 2 | O1（静态资源缓存上限）、O2（下载双拷贝） |
| §8 降 CPU 方案 | 1 | O3（`RequestMethod.parse`）；另有 #7 的日志放大 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内销毁的大临时对象」主导的分配点；`loadStaticResource`/`download` 的对象都要逃逸到缓存/响应体，local mode 不成立 |
| §11 现有代码的 BUG（存量） | 10 | #2、#4、#5、#6、#9、#11、#13、#17、#18 及 #1（安全边界）；其余函数（`Series`、`RequestMapping`、`RequestMethod`、`WSDataFrame`、`RequestMeta.extract` 边界）已逐条核对，未发现问题 |
| §12 并发安全与锁粒度 | 2 | #10（`Box` 无同步发布，共享路径 = `handle_` 闭包被所有 HTTP 线程调用）；#3（锁粒度 + 锁内 I/O）。`RequestMetas.add` 有 `Mutex`，`staticResourceBytes` 用并发容器（复合操作粒度问题见 #3） |
| §14 功能完备性与 README 覆盖 | 1 | #11（README 文档化的 `params`/`headers` 规则零用例、两处 README 自相矛盾）；其余 public 声明（`Series`、`download` 5 个重载、`WSMeta` 及其 props、`WSCloseFrame`、`@WSEndPoint` 系列）在 README 中均能检索到签名或章节 |
| 文件覆盖（§13 等） | 15/15 | 清单内 15 个 `.cj` 全部读完；本部分无 `.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 10 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量 18 条（含 1 条严重），是否纳入修复待用户决定；本部分无本次改动引入的问题（快照模式，无 diff 可比）。

## 总评

本部分的主要风险集中在两处：**安全边界**与**协商/条件判定的正确性**。

- **阻塞项**：#1 静态资源任意文件读取（`..` 未归一化 + 软链接跟随 + 默认根为 CWD），属可被未认证请求直接利用的信息泄露，建议在合并前修掉；修法很小（`canonicalize` + 前缀断言 + 关闭默认 CWD 回落）。
- **应排期**：#2（`params` 规则对 POST 表单恒 false）、#4/#5（Accept 单值带参数被 406、`Content-Type: */*`）、#6（多段下载响应不可解析）、#9（`WSCloseFrame` 空载荷越界）。这四条都属于「文档承诺了、实现路径上却走不通」，且都缺最小用例——#18 把测试缺口一并列出。
- **可排期**：#3（锁内 I/O）、#7（二进制体进日志）、#8（WS 注解静默覆盖）、#10（惰性缓存无同步）、#11（规则表达式语义未验证，需先补用例定性）。
- **代码质量**：`RequestMethod`（常量 hashCode、`WS` 自反修复）、`Series`、`WSDataFrame`、`RequestMeta` 的响应分支决策（`respondKind` / `closeResultIfResource` / `finishRequest`）都写得克制且有单测钉住；注释保留了大量「为什么这样写」的历史上下文，可维护性在同类模块里属偏好。真正的问题不是风格，而是**没有用例覆盖的那几条路径恰好是错的那几条**。
