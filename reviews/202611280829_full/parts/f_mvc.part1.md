# f_mvc 模块审查报告（第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mvc`（59 个源文件；**本部分 15 个**，第 1/4 部分）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，无 diff 可比 ⇒ 本部分所有缺陷来源统一记「存量」；`git blame` 抽样核对，涉及行均为 `4be871f2fd`（2026-10-02）等历史提交）
- **审查重点**：请求分发 / 参数绑定 / 鉴权 / 下载 / 当前上下文；并发安全与锁粒度；死代码；重复逻辑；空实现；OOM；存量 BUG
- **报告版本**：v1（部分报告，最终由主 Agent 合并为 `docs/review/f_mvc_review_20261128.md`）
- **已有性能资料**：未提供（`scope.md` 明示）⇒ 本部分无「热点瓶颈」级发现，性能类结论只出现在「优化可行性方案 / 待验证假设」

## 发现

### 1. [严重][存量] `@IgnoreAuth` 会连带跳过权限检查，权限校验被静默绕过

- **位置**：`f_mvc/src/AuthHandler.cj:121-135`（关键在 125 行的 `!param.ignoreAuth && …` 短路）
- **来源**：存量（`git blame -L 97,120` ⇒ `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §3（契约承诺但实现不成立）+ §11（与规格 / README 冲突）
- **证据**：静态确定
- **描述**：`ignoreAuth == true && ignorePrivilege == false`（即函数只标了 `@IgnoreAuth`）时：第 121 行条件不成立；`authHandler` 为 `None`（分别实现两个子接口的常规布局）时第 125 行条件因 `!param.ignoreAuth` 为 `false` 直接不成立，落到第 133 行 `AuthStatus.OK`——**权限检查一次都没执行**。而 README 把两个标记写成互不包含的两个能力：`README.md:146`「`@IgnoreAuth` 忽略登录状态检查」、`README.md:147`「`@IgnorePrivilege` 忽略权限检查」、`README.md:148`「`@IgnoreSecurity` 同时忽略登录状态和权限检查」。按文档，`@IgnoreAuth` 只该放开登录检查，权限仍应校验；实际效果等于 `@IgnoreSecurity`，凡是「匿名可访问但仅限某权限」的端点都会对任意匿名请求开放。
- **建议**：把登录检查与权限检查拆成两条独立分支，不要用 `!ignoreAuth` 作为权限分支的前置：`ignoreAuth` 只控制是否调用 `sessionHandler`（跳过时视为「已登录」），随后仍按 `!ignorePrivilege` 调用 `privilegeHandler`。若「`@IgnoreAuth` 隐含忽略权限」确为设计意图，必须在 `AuthAnnotation.cj` / `README.md:143-151` 明确写出，并考虑直接删掉 `@IgnorePrivilege` 这一独立标记。

### 2. [严重][存量] 一个实现类同时实现 `UserSessionHandler` 与 `PrivilegeHandler` 时，权限检查被丢弃

- **位置**：`f_mvc/src/AuthHandler.cj:102-108`（`if / else if` 链）+ `AuthHandler.cj:113`（只有两者都 `Some` 才 `break`）
- **来源**：存量（同上）
- **判据**：review-checklist §11（语义与实现不符 / 与规格冲突）
- **证据**：静态确定
- **描述**：`AuthHandler.cj:52-53` 的接口注释与 `README.md:158`「登录状态与权限都要检查时，最好在同一个类里一次做完（一次调用即可）」、`README.md:185`（选择规则）都把「同一个类实现两个子接口」当作**推荐做法**。但第 102 行的分支只把该实例赋给 `sessionHandler`，`privilegeHandler` 因 `else if` 不再求值而保持 `None`；第 113 行要求两者皆 `Some` 才 `break`，循环耗尽后 `privilegeHandler` 仍为 `None`，回到 `check()` 第 128 行 `let Some(h) <- privilegeHandler` 失败 ⇒ 直接返回 `OK`。后果：**按文档推荐方式接入的应用，权限检查完全失效**（登录检查照常执行，所以问题很难在测试中被发现）。
- **建议**：赋值分支改为互不排斥的独立 `if`（同一实例可同时写入两个字段），或选择阶段就用 `match` 把实例按实现的接口集合分类；并在 `break` 条件里补上「该实例已覆盖所有需要的角色」的判定。修复后需要一条回归用例：单类同时实现两接口 + `ignoreAuth=false/ignorePrivilege=false` ⇒ 两个 handler 都被调用。

### 3. [严重][存量] 下载响应体是全内存无上限缓冲且无背压，大文件 / 慢客户端直接 OOM

- **位置**：`f_mvc/src/FileDownload.cj:36`（`pipe = SyncByteBuffer()`）、`FileDownload.cj:66-68`（`write(bytes)` 直接 `pipe.write`）、`FileDownload.cj:57-60`（按 4 KiB 循环灌入）；缓冲区实现见 `f_io/src/ByteBuffer.cj:135-137`（`grow()` 每次 `reserve(size + size/2)`，无容量上限）、`f_io/src/ByteBuffer.cj:258-263`（`SyncByteBuffer.write` 无等待/无拒绝）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 无拒绝路径）、§12.1（有界性）
- **证据**：静态确定（上限不存在，非「需实测」）；具体爆点阈值需实测
- **描述**：`pipe` 是响应体的唯一承载，`ByteBuffer` 只扩容不设上限，写端（下载任务）从不检查消费端进度。两种触发路径：① `ResponseDownload.cj:19-22` 的 `download(data: File)` 在**请求线程内同步**把整文件灌进 `pipe`，1 GiB 文件即常驻 ≥1 GiB，扩容期间还有一次 `reserve` 全量复制（峰值约 2.5 倍）；② `exec` 路径（`FileDownload.cj:77`）读盘速度远高于慢客户端消费速度时，未消费字节同样在 `pipe` 累积到文件大小。README 恰恰把 `write(bytes)` / `start` 标为「文件特别大时」的用法（`README.md:1262-1266`、`1270-1276`），即文档承诺的「大文件流式下载」在实现层没有内存上限。
- **建议**：给 `SyncByteBuffer` 增加「高水位 + 等待」接口（读端消费后 `notify`，写端在 `writeOffset - readOffset > 阈值`（如 2×`downloadBufferSize`）时等待），`FileDownload.write` 走该接口；`download(data: File)` 改为在下载任务里分块读，而不是先全量入队。阈值进 `MVCConfig`（新增 `downloadPipeHighWaterMark`），超时时间可复用 `writeTimeout`。

### 4. [严重][存量] `Content-Disposition` 文件名未过滤 CR/LF，存在响应头注入

- **位置**：`f_mvc/src/FileDownload.cj:140-142`（`attachment()` 直接字符串插值）、使用点 `FileDownload.cj:101`（单文件）与 `FileDownload.cj:122`（multipart part 头）
- **来源**：存量
- **判据**：review-checklist §10（安全性：外部输入未校验）、§11（安全漏洞）
- **证据**：静态确定（代码中不存在任何对 `filename` 的过滤 / 转义 / 引号处理）
- **描述**：`attachment(filename)` 返回 `attachment, filename="${filename}"`，`filename` 原样拼进响应头。文件名在典型用法里来自请求（`@RequestParam` / 上传后的原名），攻击者用含 `\r\n` 的名称即可在响应里插入任意头甚至第二个响应（RFC 7230 §3.2.4 明确禁止字段值出现 CR/LF）。同一函数还有第二个问题（见下一条）：参数分隔符写成了逗号。
- **建议**：按 RFC 6266 生成 `attachment; filename="..."; filename*=UTF-8''<percent-encoded>`；`filename` 先剥离 `\r`、`\n`、`"`、`\\` 与控制字符，非 ASCII 走 `filename*`。过滤函数放 `f_util`（`PathUtils` 之类）以便 multipart 头复用。

### 5. [一般][存量] `Content-Disposition` 参数分隔符写成逗号，浏览器按规范会丢弃文件名

- **位置**：`f_mvc/src/FileDownload.cj:141`
- **来源**：存量
- **判据**：review-checklist §11（契约 / 规范不符）
- **证据**：静态确定（RFC 6266 §4.2：`disposition-type *( ";" disposition-parm )`，分隔符只能是 `;`）
- **描述**：`"attachment, filename=\"${filename}\""` 中的 `,` 使 `filename` 不是 `attachment` 的参数而是一个独立的、非法值；`download(File)`、`write(filename, …)`、multipart 的 `next()` 三条路径全部受影响。宽松的客户端（部分浏览器）能容错，严格的解析器会退回 URL 末段作为文件名，中文文件名尤其容易丢失。
- **建议**：改为 `attachment; filename="..."`，与上一条的转义一并处理。

### 6. [一般][存量] `noContent()` 在 204 响应里写响应体，违反 HTTP 规范

- **位置**：`f_mvc/src/FileDownload.cj:43-46`
- **来源**：存量
- **判据**：review-checklist §11（契约 / 规范不符）
- **证据**：静态确定（代码显式 `body(status.reasonPhrase)`）；HTTP 层是否抑制该 body 待确认
- **描述**：204 的语义是「无响应体」（RFC 7230 §3.3.2、RFC 7231 §6.3.5），代码却把 `"No Content"` 塞进 body 且未声明 `Content-Length: 0`。部分客户端 / 代理会因此报协议错误，或在 keep-alive 连接上把这段字节当成下一个响应的开头。
- **建议**：`noContent()` 只设状态码并 `build()`（必要时显式 `Content-Length: 0`），不调用 `body(...)`。

### 7. [一般][存量] `Accept` 的 `q` 解析过于字面：合法写法不识别，非法写法直接抛异常

- **位置**：`f_mvc/src/AcceptQueue.cj:37-46`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 错误处理缺失）+ §10（外部输入未校验）
- **证据**：静态确定（`lastIndexOf(';q=')` 精确匹配、`Float64.parse` 无 `tryParse` 兜底）
- **描述**：① `Accept: application/json; q=0.9`（`;` 后有 OWS，RFC 7231 §5.3.1 允许）匹配不到 `';q='`，q 退化为默认键、且 `submt` 保留 `; q=0.9`（第 48 行），下游 `RequestMeta.checkProduces` 用 `produces.contains(c)` 精确比对 ⇒ 返回 406；`q` 参数名大小写（`Q=`）同理。② `Accept: text/html;q=abc` 或 `;q=` 空值让 `Float64.parse` 抛异常，一路穿到请求处理 ⇒ 一个畸形请求头就能把正常请求打成 500。
- **建议**：按 `;` 切分参数后 `trimAsciiBlanks()`，参数名 `toAsciiLower()` 比较；q 值用 `Float64.tryParse` 且越界（<0 或 >1）时按 1.0/0.0 收敛或忽略该条目，始终不抛异常。建议补 3 条用例：`; q=0.9`、`;Q=0.9`、`;q=abc`。

### 8. [一般][存量] `AuthHandlerProxy` 的 handler 缓存没有安全发布，且否定结果被永久缓存

- **位置**：`f_mvc/src/AuthHandler.cj:98-120`（`noHandlers` 在锁外读、锁内置位；`authHandler` / `sessionHandler` / `privilegeHandler` 在锁内写、锁外读）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 可见性 / 惰性初始化）
- **证据**：静态确定（无 `AtomicBool`、无 `volatile` 语义、读端不在 `synchronized` 内）；实际触发概率需实测
- **描述**：两个并发请求同时进入 `check()`：线程 A 在锁内写完三个字段并置 `noHandlers = false`，线程 B 在锁外读到 `false` 后可立即读三个 handler 字段，二者之间**没有 happens-before**，B 有可能看到 `None` ⇒ 落到 `AuthStatus.OK`（与 S1 相同的「放行」形态）。另外第 117 行把「已查找过」而不是「找到了」记进 `noHandlers`：若首次请求早于 `@Bean` 注册完成（`lookupList` 返回空），此后**永远不会再查找**，鉴权对所有请求失效，且没有任何日志。
- **建议**：三个字段收进一个不可变值类型（如 `AuthHandlers`），用 `AtomicReference` 一次性发布（读端一次 `load` 拿到完整快照），`noHandlers` 随之删除；改为「查到非空才置位」，空结果时记 `log.warn` 并允许下次重查。

### 9. [一般][存量] `register(String, HttpRequestHandler)` 两个重载是 `throw` 空实现

- **位置**：`f_mvc/src/HttpRequestDistributorImpl.cj:50-55`
- **来源**：存量
- **判据**：review-checklist §3（接口实现抛异常占位）
- **证据**：静态确定
- **描述**：两个 `public func register(...)` 直接 `throw MVCException("... is not implemented")`。它们是 `HttpRequestDistributor`（stdx）契约的成员，`HttpRequestDistributorImpl.instance` 又被 `MVCStarter.cj:75` 交给 `ServerBuilder.distributor(...)`；任何按 stdx 接口编程、直接调用这两个重载的代码都会在运行时炸。当前仓内无调用者（已全仓搜索），所以不是主路径，但公共类型上挂着「未实现」的方法属于半成品。
- **建议**：要么实现（转成内部 `register(RequestMeta)`），要么从接口实现里去掉并让 `HttpRequestDistributorImpl` 不再声称支持该能力（若接口不允许，则在异常信息里写明替代 API 与原因，并在类注释里声明限制）。

### 10. [一般][存量] 每次下载 `spawn` 一个线程，无池化与并发上限

- **位置**：`f_mvc/src/FileDownload.cj:75-93`（第 77 行 `spawn{ … }`）
- **来源**：存量
- **判据**：review-checklist §12.1（有界性：无界任务 / 线程堆积）、§6.3
- **证据**：静态确定（每个下载请求必经此路径，无池化 / 无信号量）；实际线程数与影响需实测
- **描述**：`exec` 是下载的唯一异步入口，`RequestMeta.respond(FileDownloadMeta)` 因此对每个下载请求新建一个线程，且任务生命周期覆盖整个文件传输（可能几十秒）。并发下载数 = 线程数，没有上限；`download(Array<File>)` 等快捷函数还叠加了「一个请求一个线程」的乘法。
- **建议**：改走有界执行器（`f_*` 里已有线程池设施，如 `MVCConfig.servicePoolConfig` 同源的池），或至少加一个下载并发信号量（`Semaphore`，容量可配置），超限时直接回 503 而不是继续 `spawn`。

### 11. [一般][存量] `@RequestParamObject` 忽略参数级 `validator`，校验注解静默失效

- **位置**：`f_mvc/src/ControllerFuncParam.cj:96-97`（`_: Validator` 形参被丢弃）
- **来源**：存量
- **判据**：review-checklist §3（静默 no-op）+ §11（契约不符）
- **证据**：静态确定
- **描述**：`RequestParam` / `PathVariable` / `RequestHeader` 都会调 `validate<T>(...)`，唯独 `RequestParamObject` 把 `validator` 形参命名为 `_` 且从不调用。参数上写 `@IsNotEmpty` / `@StringSize` 等注解对对象参数**不报错也不生效**（字段级注解经 `MutableField.set` 仍会校验），使用者很容易以为已经校验过。`RequestBody.extract`（第 171-176 行）同样忽略，属同一形态。
- **建议**：要么在 `RequestParamObject` 里对「对象字段拼出的原始值」执行 `validate`（语义需定义），要么在宏展开阶段对「对象 / body 参数 + 参数级校验注解」的组合直接编译报错，避免静默忽略。

### 12. [一般][存量] `FileDownloadMeta` 是公开返回类型，但构造参数与 `execute()` 不是 `public`

- **位置**：`f_mvc/src/FileDownload.cj:20-29`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 与 README 不一致）+ §10（可测试性 / 可用性）
- **证据**：待确认 —— 仓颉中主构造参数 `let x!` 省略修饰符时的默认可见性（同仓 `AuthParam` 显式写了 `public let`，此处 3 个字段都没写）
- **描述**：README 把 `FileDownloadMeta` 列为 controller 函数可返回的公开类型（`README.md:113`、`1288-1306`），但 `multi` / `contentType` / `exec` 三个字段和 `execute()` 都未加 `public`。若默认可见性为 `internal`，外部项目就无法构造它（必须传 `exec`），只能退回使用 `download()` 快捷函数，README 那一节等于不可用；`exec` 是「包内接缝」的注释也说明作者把它当内部实现，与公开类型的定位冲突。
- **建议**：确认语义后二选一——把 `exec` 设为 `public`（并加输入说明），或把 `FileDownloadMeta` 降为 `internal` 并从 README 删除、只保留 `download()` 系列；不要保留「公开类型 + 不可构造」的组合。

### 13. [轻微][存量] `DownloadMeta.cj` 是空文件

- **位置**：`f_mvc/src/DownloadMeta.cj:1-18`（仅版权头 + `package`）
- **来源**：存量
- **判据**：review-checklist §1（无符号的空壳文件 / 命名残留）
- **证据**：静态确定（全仓搜索 `DownloadMeta` 只命中 `FileDownloadMeta`）
- **描述**：下载元数据实际定义在 `FileDownload.cj:20`（`FileDownloadMeta`），本文件没有任何声明，属重构残留。编译期无害，但会误导查找「下载元数据在哪」。
- **建议**：删除该文件（若担心历史引用，先在 `docs/review` 记录）。

### 14. [轻微][存量] 参数名兜底逻辑在三个注解类里各写一遍

- **位置**：`f_mvc/src/ControllerFuncParam.cj:78-82`（`RequestParam`）、`120-124`（`PathVariable`）、`145-149`（`RequestHeader`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定（三处逐行同构：`let n = if (this.name.isEmpty()) { name } else { this.name }`）
- **描述**：三份完全同义的实现，差异只有后续调用的取值来源。第四处 `RequestBody`（171-176）不做兜底，语义漂移已经开始。另外 `concat(list)`（22-31）同样承担「逗号拼接」职责但没有返回类型标注，读起来像 `Unit`。
- **建议**：把 `n` 的计算上提到 `ControllerFuncParam`（如 `protected func resolveName(name: String): String`），三处调用改为一行；`concat` 补 `: String` 返回类型。

### 15. [轻微][存量] 下载读循环与 `ResponseDownload.copy` 是同一段实现

- **位置**：`f_mvc/src/FileDownload.cj:57-60` 与 `f_mvc/src/ResponseDownload.cj:70-75`
- **来源**：存量
- **判据**：review-checklist §2（同文件族内的近似重复）
- **证据**：静态确定（缓冲大小来源、循环条件、切片写出三要素完全相同，只有局部变量名不同）
- **描述**：「按 `downloadBufferSize` 分块读、只写实际读到的长度」在两处各写一遍。`ResponseDownload.cj:69` 的注释记录了这条规则来自 `MVC-4` 的修复——同一规则存在两份实现，后续任一处修 bug 都会漂移。
- **建议**：`FileDownload.write(filename, input, length)` 内部直接复用 `copy(input, {bytes => pipe.write(bytes)})`（同包内 `copy` 已是包内可见），只保留一份。

### 16. [轻微][存量] `getHandler` 的签名隐藏了它返回 `Option`

- **位置**：`f_mvc/src/HttpRequestDistributorImpl.cj:42-44`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 契约清晰）
- **证据**：静态确定（首行无返回类型，末表达式 `patterns.data<HttpRequestHandler>(path)` 的 `Option` 靠推导成为返回值；调用方第 59-64 行正是按 `Option` 解构）
- **描述**：函数名 + 无返回类型的写法看起来像 `Unit` 的副作用方法，实际返回 `?HttpRequestHandler`；跨文件阅读时容易误判「返回值被丢弃」。
- **建议**：显式写 `func getHandler(path: String): ?HttpRequestHandler`（`register(metas)` 第 29-34 行末尾单独一句 `metas` 属同类问题，建议改为显式 `return metas` 或删掉返回值）。

## 优化可行性方案

> 无基线数据，以下均为「待验证」，不进 `tasks.md`。

### [堆内存] 下载管道加高水位背压（发现 #3 的结构性修法）

- **现状**：`FileDownload.pipe` 承载整个未消费响应体，容量只增不减；`download(File)` 路径下峰值 ≈ 文件大小（含一次 1.5× 扩容复制）
- **方案**：`SyncByteBuffer` 增加 `awaitSpace(highWater)`（读端 `notifyAll`），`FileDownload.write` 在写入前等待；高水位默认 `8 × downloadBufferSize`（32 KiB）
- **预期**：单下载常驻内存从 O(文件大小) 降到 O(高水位)，1 GiB 下载峰值下降约 4 个数量级；代价是慢客户端下生产端阻塞（需要超时）
- **代价**：`SyncByteBuffer` 是 `f_io` 公共类型，新增方法属 API 增量；等待需配合 `writeTimeout`，否则慢客户端会长期占住下载线程
- **验证**：`curl --limit-rate 1m` 下载 1 GiB 文件，多轮取 `getUsedHeapSize()` / RSS 峰值与中位数；同时断言吞吐不下降（`-O2`，同机同文件）
- **证据状态**：`无基线（待验证）`

### [CPU] 去掉每块 4 KiB 的切片拷贝

- **现状**：`FileDownload.cj:57-60` 每块先 `buf[0..len]` 生成一个 `Array<Byte>`，再被 `SyncByteBuffer.write` 复制进内部缓冲；1 GiB 下载 = 约 26 万次 4 KiB 分配 + 拷贝
- **方案**：`SyncByteBuffer` 增加 `write(bytes: Array<Byte>, offset: Int64, length: Int64)`（内部 `copyTo` 带区间），`FileDownload.write` 直接传 `buf` 与 `len`
- **预期**：分配次数 ≈ 归零，GC 压力与 memcpy 各少一半；收益大小取决于 `-O2` 下 `Array` 切片的实际成本
- **代价**：`f_io` 新增重载；`copy()`（`ResponseDownload.cj:70-75`）同步改造
- **验证**：`cjpm bench -O2`，1 GiB 本地回环下载，取 5 轮中位数与 P95；`cjprof heap` 对比分配量
- **证据状态**：`无基线（待验证）`

### [CPU] `AcceptQueue` 结果在单请求内复用

- **现状**：`RequestMeta` 在一个请求里最多构造 3 次 `AcceptQueue`（`RequestMeta.cj:270/343/374`），每次都新建 `PriorityQueue`、做字符串切片与 `log.debug` 插值
- **方案**：把解析结果放进请求级缓存（`HttpContext` 上挂一个 `?AcceptQueue` 惰性字段），或直接在第一次解析后把排序结果写回请求头
- **预期**：省掉 2 次解析；仅在 `Accept` 含逗号时生效（单值请求不受影响）
- **代价**：请求对象多一个字段；`Accept` 被下游改写（`RequestMeta.cj:186` 会 `headers.set('Accept', c)`）时缓存必须失效
- **验证**：先用 `cjprof record` 确认 `AcceptQueue.init` 在采样中可观测（自耗时占比 > 1%），再决定是否实施
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `AcceptQueue` 构造（含 `log.debug` 字符串插值）在多值 `Accept` 请求上是可观开销 | `f_mvc/src/AcceptQueue.cj:27-60` | 自耗时占比、调用频次 | `cjprof record` 跑 10 分钟稳态流量，请求头带 3~5 个候选媒体类型；看 `AcceptQueue.init` self time |
| 2 | 下载路径的 4 KiB 切片分配是 GC 抖动来源之一 | `f_mvc/src/FileDownload.cj:57-60` | 分配速率、GC 次数、端到端耗时 | `cjprof heap` + 1 GiB 下载，对照 `getAllocatedHeapSize()` 增长率 |
| 3 | `FileDownload` 的管道峰值内存随「客户端速率 / 磁盘速率」比值线性上升 | `f_mvc/src/FileDownload.cj:36,66-68` | RSS 峰值与客户端限速的关系曲线 | `curl --limit-rate` 取 1m/10m/不限 三档，各下载 512 MiB，记录 RSS 峰值 |
| 4 | 下载线程数在高并发下成为资源瓶颈 | `f_mvc/src/FileDownload.cj:77` | 并发下载数 vs 线程数 / 上下文切换 | 50/200/500 并发下载压测，采 `/proc/<pid>/status` 的 Threads 与 CPU 利用率 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mvc/src/AcceptQueue.cj` | .cj | ✅ | 见发现 #7（q 解析） |
| 2 | `f_mvc/src/AuthAnnotation.cj` | .cj | ✅ | 三个注解均被 `RequestMeta.cj:540-542` / `findAnnotation` 消费，无死代码 |
| 3 | `f_mvc/src/AuthHandler.cj` | .cj | ✅ | 见发现 #1、#2、#8 |
| 4 | `f_mvc/src/BreakingCommand.cj` | .cj | ✅ | 对外 API；`new<T>` 仓内无引用（对外可达，不判死代码） |
| 5 | `f_mvc/src/ControllerFuncParam.cj` | .cj | ✅ | 见发现 #11、#14 |
| 6 | `f_mvc/src/ControllerFuncParam_test.cj` | .cj | ✅ | 4 条用例对应 `MVC-C3`；`catch (_) {}` 有注释说明，可接受 |
| 7 | `f_mvc/src/CurrentHttpContext.cj` | .cj | ✅ | `scoped` 为 f_jsonrpc 子线程用法；见「文档一致性」说明 |
| 8 | `f_mvc/src/DownloadMeta.cj` | .cj | ✅ | 空文件，见发现 #13 |
| 9 | `f_mvc/src/ErrorHttpRequestHandler.cj` | .cj | ✅ | 纯接口，外部扩展点 |
| 10 | `f_mvc/src/ExtendHttpResponsePusher.cj` | .cj | ✅ | `extend` 转发到 3 参 `push`，无逻辑缺陷 |
| 11 | `f_mvc/src/FailureMessageKind.cj` | .cj | ✅ | `parse`/`tryParse` 被 `MVCConfig.cj:242` 使用；`==` 手写匹配完整 |
| 12 | `f_mvc/src/FileDownload.cj` | .cj | ✅ | 见发现 #3、#4、#5、#6、#12、#15 |
| 13 | `f_mvc/src/FileDownload_test.cj` | .cj | ✅ | 3 条用例钉 `MVC-C5` 收尾语义，与实现一致 |
| 14 | `f_mvc/src/HttpRequestDistributorImpl.cj` | .cj | ✅ | 见发现 #9、#16 |
| 15 | `f_mvc/src/HttpRequestDistributorImpl_test.cj` | .cj | ✅ | 1 条结构契约用例，与实现一致 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分按主 Agent 指定文件清单执行；模块 README / doc 由其他部分覆盖，本报告只在与上述文件直接冲突时引用行号）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 6（#1/#2/#5/#6/#7/#11）、安全性 1（#4）、设计 2（#9/#12）、可读性 3（#14/#15/#16）；语言特性方面核对了 `Option` 传播（`AcceptQueue.first` 的 `?[2]`、`getHandler` 的隐式返回）与 `struct` 值语义（`AcceptQueue` 持有引用型 `PriorityQueue`，仅 init 内写，无共享） |
| §1 死代码 | 1 | 逐个 private / internal / protected 符号全仓搜：`AcceptQueue.log/priority/remove`、`FileDownload.random/log/responseBuilder/built/pipe/boundary/ctx/attachment/write(header)`、`AuthHandlerProxy.mutex/noHandlers/authHandler/...`、`HttpRequestPathPatterns.patterns/register/extract/getHandler` 均有调用者；`CurrentHttpContext.set/clear/scoped` 分别被 `RequestMeta.cj:223,302,668` 与 `f_jsonrpc/JsonRpcServer.cj:287` 使用；`ControllerFuncParam.concat/validate/extractValue` 均被本文件使用。`public` 成员均为对外可达（顶层 public 类型 + 嵌套链全 public），按硬原则一不判；`noContent`、`MVCBreakingCommand.new<T>`、`HttpResponsePusher.extend` 仓内无引用但对外可达，仅记信息。唯一命中是空文件 `DownloadMeta.cj` |
| §2 重复逻辑 | 2 | 已把本部分 15 个文件的函数体压成「输入→输出→副作用」摘要两两比对：命中 #14（三处名称兜底 + `concat`）、#15（读循环与 `ResponseDownload.copy`）；另按相同字面量跨文件搜过错误文案 / 逗号拼接 / `downloadBufferSize`，`ControllerFuncParam.cj:22-31` 与 `RequestMeta.cj:621-626` 虽同为逗号拼接但语义不同（前者是参数值合并，后者是日志打印），不算重复 |
| §3 空实现 | 3 | #9（两个 `register` 重载 `throw` 未实现）、#11（`validator` 被静默丢弃）、#13（空文件）；`ExtendHttpResponsePusher` / `ErrorHttpRequestHandler` 是纯接口，无默认空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`AcceptQueue.init/remove/first` 均为循环或单次 `PriorityQueue` 操作；`ControllerFuncParam` 各 `extract` 无自调用；`FileDownload` 无递归；`runDownloadTask` 只做一层 try/catch。`CurrentHttpContext.scoped` 接受闭包但不自调用 |
| §5 OOM | 1 | #3（下载管道无界、无背压）；`AcceptQueue` 的容器大小受 `maxRequestHeaderSize` 约束，不构成无界增长；`Array<Byte>(downloadBufferSize=4096)` 由配置给定且有默认值，非不可信长度 |
| §6.1 热点瓶颈 | 0 | `scope.md` 明示无 profile / bench 数据，本部分不产生热点结论；候选点已进「待验证假设」#1-#4 |
| §6.2 大粒度锁 | 0 | 唯一临界区是 `AuthHandlerProxy.check` 的首次查找（`synchronized(mutex)` 内只做 `lookupList` 遍历与字段赋值，无 I/O、无解析、无日志、无回调），且只发生一次；未构成热点，但可见性问题已单列 #8 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无单消费者队列串行段；`exec` 是「提交后立即返回」，不等待子任务。下载线程无上限的问题按资源有界性归入 #10 |
| §6.4 低效算法 | 0 | `AcceptQueue` 用 `PriorityQueue`（O(log n)）而非排序全量；`concat` 用 `StringGenerator` 而非循环 `+`；`HttpRequestDistributorImpl` 单次哈希查找。无热点数据支撑进一步判断 |
| §7 降堆内存方案 | 1 | 「下载管道背压」方案（见优化方案第 1 条，`无基线`）；无实测基线，未写成结论 |
| §8 降 CPU 方案 | 2 | 「去切片拷贝」「`AcceptQueue` 结果复用」两条，均为 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选只有 `FileDownload.write` 的 `buf[0..len]` 与 `AcceptQueue` 的元组容器：前者切片是 `Array` 视图/拷贝，std 无对应 local 构造重载，且该对象会进入 `SyncByteBuffer` 内部缓冲（逃逸），不满足逃逸检查；后者峰值只有几十字节。收益无法用峰值内存证明，判定不可行 |
| §10 通用维度 | 3 | 已单列 #11（校验静默失效）、#12（公开类型不可构造）、#16（签名可读性）；`Option`/`Result` 丢弃点逐一核对：`getHandler` 返回值被 `distribute` 使用、`patterns.data` 失败走 `StaticResourceOrNotFoundHandler`、`AcceptQueue.remove()` 的 `None` 被 `while (let Some(...))` 正常终止 |
| §11 现有代码的 BUG（存量） | 5 | #1、#2、#5、#6、#7 以 §11 为主判据（#11、#12 已在 §10 行统计）；另核对了 `FileDownload.write` 的 `length>=0` 与 `Transfer-Encoding` 分支、`runDownloadTask` 的收尾幂等（`SyncByteBuffer.end()` 可重复调用，`f_io/src/ByteBuffer.cj:265-270`）、`CurrentHttpContext.scoped` 的 try/finally 清理，均无缺陷 |
| §12 并发安全与锁粒度 | 2 | #8（handler 缓存的发布 / 否定缓存）、#10（下载线程无界）。其余核对：`FileDownload.built` 为 `AtomicBool`（`start` 的 check-then-set 只在单写者任务线程调用，暂不构成竞争）、`FileDownload.random`（`RandomString` 默认 `ThreadLocalRandom`，无跨线程状态）、`HttpRequestDistributorImpl.instance` 的注册受 `MVCStarter.initial_` 闸门约束（启动后 `generateAndRegister` 直接抛错），注册期写入 `PathPattern` 全程持锁 ⇒ 分发期只读，未发现共享可变路径 |
| §13 文档一致性（.md） | 1 | 本部分无 `.md` 文件；跨部分核对时发现 `f_mvc/README.md:203-214` 只文档化 `CurrentHttpContext.instance`，且「自己 spawn 出来的线程里取不到（会抛异常）」与 `CurrentHttpContext.cj:37-47` 新增的 `public static func scoped` 矛盾（f_jsonrpc 已用它跨线程恢复上下文）⇒ 「一般·文档与实现不符 / 公开 API 未进 README」，位置 `README.md:203-214` + `CurrentHttpContext.cj:37`（README 归第 4 部分统计，此处只记不重复计数） |
| §14 功能完备性与 README 覆盖 | 1 | #12（`FileDownloadMeta` 公开但不可构造）；`CurrentHttpContext.scoped` 未进 README 属跨部分项，已记在 §13 行不重复计数。其余对照：`MVCBreakingCommand`（`README.md:1155-1165`）、`ExtendHttpResponsePusher` / `FailureMessageKind`（`README.md:1325-1326`）、`ErrorHttpRequestHandler`（`README.md:62`）、`FileDownload` 全 API（`README.md:1240-1286`）均在文档中有对应段落 |
| 文件覆盖（§13 等） | 15/15 | 本部分指定的 15 个 `.cj` 全部读完，无遗漏、无超时 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 8 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量共 17 条（4 严重 + 8 一般 + 5 轻微），本部分无「本次改动」引入项；是否纳入修复待用户决定。另有 1 条跨部分的文档一致性项（`CurrentHttpContext.scoped` 未进 README）只记在 §13 行，不计入本部分统计。

## 总评

鉴权链路是本部分最大的风险面：`AuthHandlerProxy` 的两个分支缺陷（`@IgnoreAuth` 连带跳过权限、单类双接口时权限丢弃）都属于**静态可判、后果为越权放行**，且都恰好违背 README 明文承诺；再加上缓存无安全发布与否定结果永久缓存，四者叠加使得「鉴权是否真的生效」高度依赖接入方式与启动时序，建议列为阻塞项优先修复并补并发 + 组合场景用例。

下载链路的结构性问题是「用无上限内存缓冲冒充流式」（#3）与「头值直接拼外部文件名」（#4），前者在文件较大时必然爆内存，后者是注入面；`Content-Disposition` 的逗号与 204 带 body 属规范级小错，但都落在同一函数里，可一并修掉。

其余文件（注解、`FailureMessageKind`、`ExtendHttpResponsePusher`、`ErrorHttpRequestHandler`、分发器的查找路径）实现简洁、边界清楚、无死代码（仅一个空文件 `DownloadMeta.cj` 可删）；`HttpRequestDistributorImpl` 的两个 `throw` 重载属半成品但不在主路径上，可排期。本部分未发现栈溢出、`spawn().get()` 串行、锁内 I/O 等问题，锁粒度整体合理；性能与内存改进项因缺少基线数据，只以「待验证假设」形式给出。
