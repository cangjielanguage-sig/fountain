# f_security 模块审查报告

> **模块第 1/1 部分**（本模块共 16 个文件，一次审完：`README.md`、`README_en.md` 与 `src/` 下 13 个 `.cj` + `src/exception/SecurityException.cj`。清单见 `files/f_security.txt`。）

- **审查日期**：2026-11-28
- **模块路径**：`f_security`（14 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（master 与 `sts/1.3.x` 同提交 `120fd2542`，`git diff` 为空 ⇒ 全部问题记「存量（无基线可比）」）
- **审查重点**：登录状态契约与密钥暴露面、重复逻辑、死代码、并发安全（专项）+ 存量 BUG、文档一致性
- **报告版本**：v1（第 1/1 部分，同日抽样版 `docs/review/2026-11-28/f_security.md` 的合并基线）

## 发现

### [一般][存量] #1 `HeapCacheStore` 只透传 `maxLife`，缓存既无容量上限、TTL 又是滑动续期 —— 活跃会话永不过期，条目数随用户数只增不减

- **位置**：`f_security/src/HeapCacheStore.cj:20-22`（`cache = HeapCache<P>(maxLife: maxLife)`，其余参数全取默认）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §5（无界容器 / 缓存键无界：没有容量与淘汰）、§11（语义与文档不符）、§13（`maxLife` 的真实语义）
- **证据**：静态确定 —— 两条默认值链：
  1. `HeapCache` 的 `maxSize!` 默认 `DEFAULT_HEAP_CACHE_MAX_SIZE`（`f_cache/src/HeapCache.cj:47`），常量值为 `Int64.Max`（`f_cache/src/HeapCacheBuilder.cj:19`）；超容量淘汰的入口是 `while (store.size > maxSize && ...)`（`f_cache/src/HeapCache.cj:188`、`201`），`maxSize == Int64.Max` 时该分支等价于永不执行。
  2. `HeapCache.set` 的 `once!` 默认 `false`（`f_cache/src/HeapCache.cj:302`），`Priority` 对 `once=false` 的定义是「从最后访问时间开始算超时时间」（`f_cache/src/Priority.cj:23`、`206-207`），`get` 走 `loadIfAlive()`（`f_cache/src/HeapCache.cj:238-241`）会刷新 `lastUsed`。
  `HeapCacheStore` 的构造器签名只有 `maxLife`，调用方没有任何手段设 `maxSize`（`f_security/src/HeapCacheStore.cj:20`），也拿不到内部 `cache` 去 `prolong` / `set(life:once:)`（字段 `private`，`:19`）。
- **描述**：两个后果，都不是"到 OOM 才知道"：
  - **会话不失效**：README 把 `maxLife` 写作「登录状态的保持时间」（`README.md:78-79`、`README_en.md:78-79`），实际是「空闲超时」——只要用户在 `maxLife` 内访问过一次，`lastUsed` 就被刷新，条目永不到期。`JWTSecurityContext` 路径有 JWT 自己的 `exp` 兜底（`f_jwt/src/JWT.cj:455-458` 的 `verify()` 含 `isExpired`），但 `UserTokenSecurityContext` / `HttpHeaderUserTokenSecurityContext` 两条路径**没有任何第二道过期**，令牌一旦签出就是无限期有效（直到管理员主动 `remove`，而模块未提供该入口，见 #6 附注）。
  - **无容量上限**：每个登录过的 `id` 常驻一条 `HeapCache` 条目（`String` 键 + `Priority` 节点 + `Principal`），单条量级约 150–250 B。按 `maxLife = 1h`（README 例子 `README.md:156`）估算，10 万活跃用户 ≈ 15–25 MB，100 万 ≈ 150–250 MB；且因为滑动续期，稳态是"全部活跃用户"而不是"最近一小时登录的用户"。此外每个 `HeapCacheStore` 实例还会拉起 1 个清扫线程 + 1 个 `Timer` + 1 条 `atExit` 注册（`f_cache/src/HeapCache.cj:61`、`:65`、`:99`），而本模块未调用 `close()`（`HeapCacheStore` 没有 `close`，`HeapCache` 却是 `<: Resource`）。
- **建议**：`HeapCacheStore` 构造器补 `maxSize!`（或 `capacity!`）并透传，默认给一个有限值（如 10 万）；对"绝对过期"语义的会话（token 路径）改用 `once: true`（`HeapCache.set(key:value:life:once:)` 已有该开关），并把 README 的「保持时间」改成「空闲超时 / 绝对过期」二选一写清。容量上限与过期口径必须能由调用方配置，而不是写死在模块里。

### [一般][存量] #2 `check` 闭包不做异常防护：畸形 `Authorization` 头、或在非请求线程调用，都让 `(S) -> Bool` 抛异常而不是返回 `false`

- **位置**：`f_security/src/JWTSecurityContext.cj:35-41`（`JWT.verifier(jwt)` + `verify()`）、`f_security/src/JWTSecurityContext.cj:56-61`；`f_security/src/HttpHeaderUserTokenSecurityContext.cj:29-30`、`40-41`、`52`；`f_security/src/JWTSecurityContext.cj:25`、`46`
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（错误处理缺失 / 失败路径当异常抛出）、§10（正确性：`Option` 与异常路径）
- **证据**：静态确定 —— 契约侧：`public let check: (S) -> Bool`（`f_security/src/SecurityContext.cj:22`），返回值是 `Bool`，调用方（如 `fdemo/user/src/util/UserSessionCache.cj:49-51` 的 `verify()`）直接 `let v = context.check(())`，没有 `try`。实现侧两条触发路径：
  1. **不可信头部**：`Authorization` 头原样进 `JWT.verifier(jwt)`（`:36`、`:57`）。`JWTVerifier` 的构造器先 `indexOf(".")` 再 `data[0 .. firstDot]`，然后 `fromBase64(...)`（`f_jwt/src/JWT.cj:330-337`），而 `fromBase64` 是 `fromBase64String(src).getOrThrow {JWTException(...)}`（`f_jwt/src/encoding.cj:24`）；`verifySign()` 在 token 的 `alg` 与配置不一致时也 `throw JWTException`（`f_jwt/src/JWT.cj:443-447`）。因此 `Authorization: Bearer x`（无 `.`）或 `Bearer !!!`（非 base64）或伪造 `alg`，都会让异常直接穿出 `check`。这些是**任何未认证客户端都能发的头**。
  2. **非请求线程**：`check` 第一句就是 `CurrentHttpContext.instance`（`:25`、`:46`；HttpHeader 版 `:29`、`:40`、`:52`），该属性是 `context.get().getOrThrow()`（`f_mvc/src/CurrentHttpContext.cj:49-53`），`ThreadLocal` 为空时抛 `None.getOrThrow()`。在定时任务、`spawn` 的子线程、单测里调用 `check`/`checkAndGet` 都会抛，而不是"未登录 → false"。
- **描述**：`check` 的名字与签名承诺"判定"，实际行为是"判定或抛异常"。`f_mvc` 的 `AuthStatus` 专门有 `SessionError`/`InvalidSession` 来表达"检查出错"与"登录信息无效"（`f_mvc/src/AuthHandler.cj:18-28`），说明上层期望的是状态而不是异常；一旦应用照 README 例子直接 `context.check(())`，畸形头就会变成每个请求一次未捕获异常（500 或线程终止），构成低成本的可触发错误面。`checkAndGet()`（`:67-72`）先 `check` 再取 principal，异常同样穿出。
- **建议**：把 JWT 解析与验签整体包进 `try { ... } catch (e: JWTException) { false }`（仓颉侧 `JWT.verifier` 与 `verify()` 的抛出类型已固定为 `JWTException`，见 `f_jwt/src/JWT.cj:446`、`f_jwt/src/encoding.cj:24`），并把 `CurrentHttpContext.instance` 换成可空访问（`f_mvc` 内部 `context` 是 `private`，需在 `f_mvc` 侧补一个 `instanceOption`），无上下文时返回 `false`。修完在 README 写明"`check` 不抛异常，任何输入都返回 `Bool`"。

### [一般][存量] #3 `JWTSecurityContext.checkAndGet()` 一次请求把同一张 JWT 解析两遍，两段实现逐行同构，且构成 TOCTOU

- **位置**：`f_security/src/JWTSecurityContext.cj:25-42`（`check` 闭包：取头 → 剥 `Bearer ` → `JWT.verifier` → `getKeyId` → `store.get` → `verify`）与 `:46-63`（`getPricinpal`：取头 → 剥 `Bearer ` → `JWT.verifier` → `getKeyId` → `store.get`）；调用点在 `:68-69`
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：换控制流 / 只改最后一步）、§11（检查-然后-写入 / TOCTOU）
- **证据**：静态确定 —— 两段的 header 提取（`:26-34` vs `:47-55`）、`startsWith('Bearer ')` 判定与切片（`:27-28` vs `:48-49`）、`JWT.verifier(jwt)` + `getKeyId()` + `size > 0` 判定（`:36-38` vs `:57-58`）逐行对齐，唯一差异是收尾：一处 `keySetter(verifier, principal).verify()`（`:39`），一处 `store.get(userId)`（`:59-60`）。`checkAndGet()` 依次调用二者（`:68`、`:69`），因此单次请求里 JWT 被 base64 解码 + JSON 解析 **2 次**，`store.get` 也走 2 次。
- **描述**：除重复解析的 CPU 开销外，还有语义问题：`:38` 校验通过的是当时的 `principal`，`:69` 重新取到的可能是另一个对象（同一 `userId` 被重新登录 / 密钥轮换后 `set` 覆盖）。返回给业务层的 principal 因此不保证"刚被验签过的那一个"，其 `key` / `token` 字段可能已被替换。差异点不足以论证"必须两份"：两段没有错误文案、边界或可空性上的业务差异。
- **建议**：让单一私有函数返回解析结果（`Option<(JWTVerifier, String)>` 或直接 `JWTVerifier` + `keyId`），`check` 与 `getPricinpal` 都基于它实现，`checkAndGet` 一次解析后同时完成"验签"与"取 principal"；若担心改动公开行为，先走 propose（`check` 是 `public let` 字段，签名动不了，但内部实现可以改）。

### [一般][存量] #4 `HeapCacheStore` 用 `id.toString()` 当键，把 `Equatable`/`Hashable` 的相等性换成字符串表示

- **位置**：`f_security/src/HeapCacheStore.cj:24`（`cache.set(principal.id.toString(), principal)`）、`:27`（`cache.get(id.toString())`）、`:30`（`cache.remove(id.toString())`）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）、§10（`ID <: Hashable & Equatable<ID>` 的语义）
- **证据**：静态确定（机制）/ 待确认（真实 ID 类型）—— `PrincipalStore<ID, P>` 的约束声明 `ID <: Hashable & Equatable<ID>`（`f_security/src/PrincipalStore.cj:18`），承诺"按 `ID` 的相等性存取"；实现却先 `toString()` 再当 `String` 键（`HeapCache<V>` 的键类型固定为 `String`，`f_cache/src/HeapCache.cj:235`、`302`）。于是两个 `toString()` 结果相同的不同 `ID` 命中同一条会话：自定义 ID 的 `toString` 截断 / 丢弃字段，或包装类型把 `Int64` 与 `String` 都映射成同一串，都会串号；`remove(id)` 也会删掉别人的会话。`UserTokenHeapCacheStore`（`:40-48`）再包一层，语义不变。
- **描述**：仓内现有 ID 类型只有 `String` 与 `Int64`（`f_security/src/UserIdData.cj:18`、`25`），`toString` 是单射，当前不会触发；但这是**库的对外契约**，下游自定义 ID 就会踩。约束里写了 `Equatable` 却不用，读代码的人会以为按 `ID` 判等。
- **建议**：`HeapCache` 的键是 `String`，若不想改 `f_cache`，就在约束与 README 里显式写「键 = `id.toString()`，调用方需保证 `ToString` 单射」，并把 `Equatable` 从约束里去掉（不给假承诺）；或给 `HeapCache` 增加泛型键变体后改用 `ID` 本身。

### [一般][存量] #5 签名密钥 `JWTPrincipal.key` 是 `public let`，随 principal 交给所有调用方，并由堆缓存长期持有

- **位置**：`f_security/src/JWTPrincipal.cj:22`（`public let key: String`）；扩散路径 `f_security/src/SecurityContext.cj:24-31`（`login` 把整个 principal 交给 `store.store` 后原样返回）、`:33-35`（`get`）、`JWTSecurityContext.cj:64-72`（`checkAndGet`）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §10（安全性：敏感数据暴露面）、§11（契约与实现）
- **证据**：静态确定 —— `key` 与「可对外传递的登录态」是同一个对象：`login(U) -> ?P` / `get(ID) -> ?P` / `checkAndGet(S) -> ?P` 三个公开入口都返回它，`README.md:91` 自己写明是「签名密钥」，`README.md:148-149` 又强调 `UserTokenPrincipal.token` / `UserNamePasswordUserData.password` 是 `public let` 直接公开。持有者拿到 principal 即可读密钥，业务层透传、日志打印结构体、序列化返回都会带出去（`JWT` 的 `keySetter` 是唯一真正需要它的地方，`:22` 的 `keySetter: (JWTVerifier, JWTPrincipal<String>) -> JWTVerifier`）。
- **描述**：密钥应当只活在校验路径里，现在它是"用户可见的数据字段"。两个放大因素：一是它能被业务层任意读取（同进程，非远程泄露，因此不判严重）；二是按 #1 的口径，它随缓存条目驻留到会话过期，滑动续期下可能是整个进程生命周期。`UserTokenPrincipal.token` 同理，但 token 本来就是调用方交进来的凭据，暴露面小一层。
- **建议**：`key` 从 `JWTPrincipal` 移出，改为 `JWTSecurityContext` 内部的 `PrincipalStore<String, String>`（userId → key）或让 `JWTPrincipal` 只保存 `id`/`username`，`keySetter` 从 store 取密钥；若必须保留字段，把它降为 `private let` 并补一个包内可见的读取方法，同时从 README 的"直接公开"清单里去掉。这是契约变更（`key` 当前对外可达），需用户确认。

### [一般][存量] #6 README 把 `UserTokenPrincipal<ID>` 写成 `BaseUserData` 的实现，实际是 `Principal` 的实现

- **位置**：`f_security/README.md:126`（"`UserNamePasswordUserData` 与 `UserTokenPrincipal<ID>` 是两个实现"）、`f_security/README_en.md:126`（同一句）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §13（文档与代码不一致：类型清单写错）
- **证据**：静态确定 —— 上一节 `README.md:121-124` 定义的是 `BaseUserData<U> { prop username: String }`，而 `UserTokenPrincipal<ID>` 的声明是 `<: Principal<ID, UserTokenPrincipal<ID>>`（`f_security/src/UserTokenPrincipal.cj:18`），根本不实现 `BaseUserData`。真正的 `BaseUserData` 实现是 `UserNamePasswordUserData`（`f_security/src/UserNamePasswordUserData.cj:18`）与 `String` / `Int64` 的扩展（`f_security/src/UserIdData.cj:18`、`25`）。
- **描述**：`BaseUserData<U>` 是 `SecurityContext` / `JWTSecurityContext` 的类型参数约束（`f_security/src/SecurityContext.cj:18`、`JWTSecurityContext.cj:18`），使用者要选 `U` 时会照这一句去找实现，然后发现 `UserTokenPrincipal` 不能用（它是输出类型 `P`，不是输入类型 `U`）。`UserIdData.cj` 里那两个扩展（`String` / `Int64`）在 README 中完全没有出现，而 `fdemo` 正是靠 `JWTSecurityContext<String>`（`fdemo/user/src/util/UserSessionCache.cj:27`）隐式用到 `extend String <: BaseUserData<String>` —— 读者无法从 README 得知这个能力存在。
- **建议**：把 `:126` 改成「`BaseUserData` 的实现有 `UserNamePasswordUserData`、`String`（`UserIdData.cj:18`）、`Int64`（`UserIdData.cj:25`）」，并把 `UserTokenPrincipal` 移到「登录状态（`Principal`）的实现」一节；README_en 同步。

### [轻微][存量] #7 `type StringUserTokenHeapCacheStore` 全仓零引用（死代码）

- **位置**：`f_security/src/HeapCacheStore.cj:50`
- **来源**：存量（`git blame`：`58ecd73e7f` 2025-12-31）
- **判据**：review-checklist §1（死代码：非公共顶级声明）
- **证据**：静态确定 —— 顶层 `type` 未加 `public`（默认 `internal`，仅本包及子包可见）。全仓搜索 `StringUserTokenHeapCacheStore`（排除 `.worktrees` 与 `docs/`）只命中定义本身 `f_security/src/HeapCacheStore.cj:50`；`f_security` 无子包（`src/exception` 是另一包，且不引用它），模块内无任何使用。README 也只登记了 `JWTHeapCacheStore` 与 `UserTokenHeapCacheStore`。
- **描述**：与上面 `:33` 的 `public type JWTHeapCacheStore` 成对出现，看起来是"对称补齐"时留下的；`String` 版没有任何调用者，也没有对外暴露，属纯残留。
- **建议**：删除；若确实要提供 `String` 快捷别名，加 `public` 并在 README 登记（对外契约变更需用户确认）。

### [轻微][存量] #8 `imports.cj` 的 `internal import std.convert.Parsable` 未使用

- **位置**：`f_security/src/imports.cj:18`
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02 该行原样存在）
- **判据**：review-checklist §1（死代码：未使用的 `import`）
- **证据**：静态确定 —— 模块内搜索 `Parsable`、`parse(` 只命中这一行 import 本身（`f_security/src` 全目录）。而模块用到的 `ToString` / `Hashable` / `Equatable`（`HeapCacheStore.cj:18`、`SecurityContext.cj:18`）都来自 `std.core` 隐式导入，不需要任何 import；`toString()` 是 `ToString` 的成员，与 `Parsable` 无关。同文件另外三个 import 都有实际使用（`HeapCache` → `HeapCacheStore.cj:19`；`f_jwt.*` → `JWTSecurityContext.cj:22`、`36`；`CurrentHttpContext` → `JWTSecurityContext.cj:25` 等）。
- **描述**：`cjpm.toml` 对 Linux 目标加了 `-Woff unused`（`f_security/cjpm.toml:33-34`），所以编译器不会提示，这条会一直留着。
- **建议**：删除该行。

### [轻微][存量] #9 `UserTokenHeapCacheStore` 三个方法逐行转发 `HeapCacheStore`，无任何附加语义

- **位置**：`f_security/src/HeapCacheStore.cj:35-49`（`store` `:40-42`、`get` `:43-45`、`remove` `:46-48`）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §2（重复逻辑：只改类型名的包装）
- **证据**：静态确定 —— 唯一字段 `store_: HeapCacheStore<ID, UserTokenPrincipal<ID>>`（`:36`），三个方法体分别只有一行 `store_.<同名方法>(...)`，无校验、无转换、无 TTL / 容量差异；`init` 也只是把 `maxLife` 透传（`:37-39`）。唯一"差异"是 `UserTokenHeapCacheStore<String>(d)` 比 `HeapCacheStore<String, UserTokenPrincipal<String>>(d)` 少写一个类型参数。
- **描述**：这是纯委托层，且与 #4 同源——把 `toString` 键语义又包了一层。仓内零使用（全仓 grep 仅 `README.md:108` 与定义处），对外是对可达 `public struct`，删除属契约变更。
- **建议**：若要保留类型推断便利，用 `public type UserTokenHeapCacheStore2 = ...` 式别名（`type StringUserTokenHeapCacheStore = UserTokenHeapCacheStore<String>` 已经是这个思路，只是没公开）；否则按"对外 public 需用户拍板"处理，先记入可见性/契约建议，不默认删除。

### [轻微][存量] #10 令牌用 `String ==` 比较，不是常量时间比较

- **位置**：`f_security/src/UserTokenSecurityContext.cj:24`（`p.token == tpl[1]`）、`f_security/src/HttpHeaderUserTokenSecurityContext.cj:30`（`p.token == token`）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §10（安全性：凭据比较）
- **证据**：静态确定 —— 两处都用 `==` 直接比字符串，仓颉的 `String` 相等性比较在长度 / 首个不同字节处即返回，不等价于恒定时间比较。
- **描述**：HTTP 头路径（`HttpHeaderUserTokenSecurityContext`）直接暴露在公网请求上，理论上是可测的计时侧信道；实际可利用性取决于令牌熵（README 例子用 `UUID.random().toHexString()`，熵足够）与网络抖动，因此定轻微。`JWTSecurityContext` 路径不用这种比较（走 HMAC 验签），不受影响。
- **建议**：若 token 由外部系统签发 / 长度较短，改为逐字节异或累加后比较（`f_jwt/src/SignAlgo.cj:37-43` 的验签路径已是这种思路，可复用其比较工具）；README 注明"token 需高熵"。性能类改动需实测，见待验证假设。

### [轻微][存量] #11 `HttpHeaderUserTokenSecurityContext` 单次校验读 3 次请求头，且 `getPricinpal` 里绑定的 `token` 从未使用

- **位置**：`f_security/src/HttpHeaderUserTokenSecurityContext.cj:29`（`check` 闭包第一次取 headers）、`:40-41`（`getPricinpal` 第二次取 headers，`:41` 的 `let Some(token) <- ...` 绑定后无引用）、`:52`（`checkAndGet` 第三次取 headers）
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §1（读了不用：局部绑定未被读取）、§2（同一段取值逻辑重复三次）
- **证据**：静态确定 —— `getPricinpal` 的形参含 `tokenHeader`，`:41` 把 `token` 取出来只为满足 `&&` 的 `let-else` 存在性判断，函数体（`:42-44`）只用 `uid`；`check` 在 `:29-30` 已经取过 `token` 并用于 `:30` 的比较。`checkAndGet` 在 `:51` 已判定通过，`:52-55` 又重新取 `userIdHeader`。
- **描述**：功能正确（三次读的是同一份不可变请求头，无 TOCTOU），但每次校验多两次 header 查找，且"取 token 却不用"会让人误以为函数内做了令牌比对。`JWTSecurityContext` 的同名私有函数（`:45-63`）是"取头 + 解析"一整段，两处形态不一致也算实现漂移。
- **建议**：`getPricinpal` 只接收 `userIdHeader` 与 `store`（去掉 `tokenHeader` 参数与那次 `getFirst`），`token` 的存在性判断留在 `check` 里；`checkAndGet` 复用 `check` 已取到的 `uid`（把 `check` 改成内部实现返回 `(uid, principal)`）。

### [轻微][存量] #12 README 缺少三个上下文类的构造器与过期语义，且 `JWTHeapCacheStore` 的类型别名示例不能编译

- **位置**：`f_security/README.md:50-53`（只给了 `JWTSecurityContext<U>` 的类型声明）、`:76-84`（`public type JWTHeapCacheStore = HeapCacheStore<...> { public init ... }`）、`:108-116`（`UserTokenHeapCacheStore` 同样式）；对照实现 `JWTSecurityContext.cj:19-23`、`HttpHeaderUserTokenSecurityContext.cj:22-38`、`UserTokenSecurityContext.cj:19-30`、`HeapCacheStore.cj:33`
- **来源**：存量（`git blame`：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §13（示例不能用 / 关键段落缺失）、§14.2（公开 API 与关键配置未文档化）
- **证据**：静态确定 ——
  1. 三个 context 类在 README 里只有类型头，**没有任何构造器**。`JWTSecurityContext` 的安全关键参数 `keySetter: (JWTVerifier, JWTPrincipal<String>) -> JWTVerifier`（`:22`）全文只出现在末尾例子的尾随闭包里（`README.md:158-160`），没有参数名与语义说明；`HttpHeaderUserTokenSecurityContext` 的两个头名参数（`:23-24`）同样缺失。
  2. `:76-84` 写成 `public type X = Y { public init(...) ... }` —— 仓颉的 `type` 别名不能带成员块（实现里 `HeapCacheStore.cj:33` 只有一行无 body 的别名），这段示例照抄会编译失败，读者也无法据此判断该调哪个构造器。
  3. 逾期语义完全缺失：`maxLife` 的滑动续期（见 #1）、未带 `exp` 的 JWT 会被接受（`f_jwt/src/JWT.cj:453-458` 的 `isExpired` 对缺失 `exp` 返回 `false`）、`check` 依赖 `CurrentHttpContext`（见 #2），README 一句都没写。
- **描述**：这是模块唯一的对外文档，`README_en.md` 是逐句翻译（两个文件行号一一对应），因此两份同时缺。按文档用不起来的部分集中在"怎么构造"和"登录态多久失效"这两件最容易被误判的事上。
- **建议**：为三个 context 补构造器签名与参数说明（`keySetter` 必须写清"用 principal 里的密钥构造 verifier"）；把 `:76-84` / `:108-116` 改成 `public type JWTHeapCacheStore = HeapCacheStore<String, JWTPrincipal<String>>` 加一行"构造：`JWTHeapCacheStore(maxLife)`"；新增"过期语义"小节，写清 `maxLife` 是空闲超时、JWT 以 `exp` 为准、无 `exp` 视为不过期。README_en 同步。

## 优化可行性方案

### [CPU] `JWTSecurityContext` 单请求只解析一次 JWT

- **现状**：`checkAndGet()` 依次调用 `check(())`（解析 + 验签一次）与 `getPricinpal(store)`（再解析一次），单次请求 2 次 base64 解码 + 2 次 JSON 解析 + 2 次 `store.get`（`JWTSecurityContext.cj:25-42`、`46-63`、`68-69`）。输入规模：每次鉴权请求 1 张 JWT（典型 < 1 KB）。
- **方案**：抽出 `private func parse(): Option<(JWTVerifier, String)>`（取头 + 剥前缀 + `JWT.verifier` + `getKeyId`），`check` 与 `getPricinpal` 都调它；`checkAndGet` 改为"解析一次 → 验签 → 用同一个 `userId` 取 principal"。同时把 #3 的 TOCTOU 一并消除。
- **预期**：本模块内 JWT 解析调用次数减半（2 → 1/请求）；端到端收益取决于解析在请求耗时中的占比，**未测**。
- **代价**：`check` 仍是 `public let (S) -> Bool`，对外签名不变；改动限于类内部，但需要保证"验签通过"与"取 principal"用的是同一次解析结果（行为更严格，属修正而非兼容风险）。
- **验证**：`cjpm bench -O2` 或 `cjprof record` 跑 fdemo 的鉴权路径，同输入（同一 JWT、`n = 10k` 次），对照 `JWT.verifier` / `JsonValue.fromStr` 的自耗时占比中位数与离散度；只看模块内占比，不外推到端到端。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | JWT 双解析占单次鉴权耗时的可测比例（是否为 >5% 的端到端项） | `f_security/src/JWTSecurityContext.cj:25-42`、`46-63` | `JWT.verifier` + `getKeyId` 的自耗时占比；单请求总耗时 | `cjprof record` 跑 fdemo `/user/verify` 稳态负载（同 JWT，10k 次，`-O2`），取中位数 |
| 2 | 业务侧是否存在 `toString()` 非单射的 `ID` 类型（会真的触发 #4 串号） | `f_security/src/HeapCacheStore.cj:24` | 下游 `UserTokenSecurityContext<ID, …>` 的 `ID` 实参清单与自定义类型的 `toString` 实现 | 采集使用方清单（仓内只有 `String` / `Int64`，需问下游仓库）；对候选类型做"两个不同实例同 `toString`"的单测 |
| 3 | 登录态缓存的稳态条目数与 RSS 贡献（#1 的量化上界） | `f_security/src/HeapCacheStore.cj:20-22` | 真实业务的 distinct 登录 ID 数 / `maxLife` 配置 / 单条目的实测字节数 | 在 fdemo 上灌 `n` 个不同 userId 登录后 `getUsedHeapSize()` + RSS，`n = 10k / 100k` 两档，配合 `HeapCache` 的段数（`segmentCount()`）估算 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_security/README.md` | .md | ✅ | 183 行全读；见 #6、#12，与实现逐条对照 |
| 2 | `f_security/README_en.md` | .md | ✅ | 183 行全读；与中文版逐节对齐，同一处错误（`:126`）同步存在 |
| 3 | `f_security/src/BaseUserData.cj` | .cj | ✅ | 单接口声明，无问题 |
| 4 | `f_security/src/HeapCacheStore.cj` | .cj | ✅ | 见 #1、#4、#7、#9 |
| 5 | `f_security/src/HttpHeaderUserTokenSecurityContext.cj` | .cj | ✅ | 见 #2、#10、#11 |
| 6 | `f_security/src/JWTPrincipal.cj` | .cj | ✅ | 见 #5 |
| 7 | `f_security/src/JWTSecurityContext.cj` | .cj | ✅ | 见 #2、#3、#12 |
| 8 | `f_security/src/Principal.cj` | .cj | ✅ | 两属性接口，`id`/`username` 均被子类与调用方使用 |
| 9 | `f_security/src/PrincipalStore.cj` | .cj | ✅ | `remove` 仓内零调用，属对外接口契约（见 #9 附注） |
| 10 | `f_security/src/SecurityContext.cj` | .cj | ✅ | 见 #2、#5；`store` 为 `protected let`，`public abstract class` 非 `sealed` ⇒ 扩展点，不判死代码 |
| 11 | `f_security/src/UserIdData.cj` | .cj | ✅ | `String` / `Int64` 扩展，被 `JWTSecurityContext<String>` 隐式使用；README 未登记（#6） |
| 12 | `f_security/src/UserNamePasswordUserData.cj` | .cj | ✅ | 单实现，`password` 公开已在 README 声明 |
| 13 | `f_security/src/UserTokenPrincipal.cj` | .cj | ✅ | 见 #6（被 README 错写成 `BaseUserData` 实现） |
| 14 | `f_security/src/UserTokenSecurityContext.cj` | .cj | ✅ | 见 #10 |
| 15 | `f_security/src/exception/SecurityException.cj` | .cj | ✅ | 4 个构造器转发 `BaseException`，`public class` 对外契约，无问题 |
| 16 | `f_security/src/imports.cj` | .cj | ✅ | 见 #8 |

合计：`.cj` 14 个 / `.md` 2 个 / 共 16 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #2（异常路径破 `Bool` 契约）、#3（TOCTOU）、#4（契约与实现）、#5（密钥暴露）、#10（非常量时间比较） |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` 符号全仓搜过：`private` 的 `getPricinpal`（两处）均有调用；`internal` 顶层别名 `StringUserTokenHeapCacheStore` 零引用（#7）；`internal import Parsable` 未使用（#8）。`public` 且对外可达的（`SecurityContext` 及其 `protected store`、`PrincipalStore.remove`、`checkAndGet()` 无参重载）按硬原则一不判，只记"仓内无引用"；无 `sealed` 类。逐条检查了 4 处 `return` 之前的同层语句与每个局部 `let` 的读取（`:41` 的 `token` 是 #11） |
| §2 重复逻辑 | 2 | 把模块内 30 余个函数体（含 3 个 `check` lambda 闭包、4 个 `SecurityException` 构造器、8 个 store 转发方法）压成「输入-输出-副作用」摘要后两两比对：`JWTSecurityContext.check` 闭包 vs `getPricinpal` 逐行同构（#3）；`UserTokenHeapCacheStore` 三方法纯转发（#9）。另逐行比对 `JWTPrincipal` vs `UserTokenPrincipal`（仅字段名 `key`/`token` 不同），判定**不是**重复——凭据语义、生存期与 README 契约不同，属领域类型各自保留；`HttpHeader…` vs `JWTSecurityContext` 的 `checkAndGet(_: Unit)` 属接口实现的标准重载转发，不计；跨文件搜了相同字面量（`'Bearer '`、`'Authorization'`），只在本模块 `JWTSecurityContext` 内部重复出现，已并入 #3 |
| §3 空实现 | 0 | 14 个 `.cj` 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`SecurityException` 的 4 个构造器都有 `super(...)` 转发；`HeapCache` 内部吞异常（`f_cache/src/HeapCache.cj` 的 `notifyEviction`）不在本模块 |
| §4 栈溢出 | 0 | 无递归、无自引用结构遍历；`check` 与 `checkAndGet` 的调用是"重载 → 另一重载"，只一跳、无环 |
| §5 OOM | 1 | #1（缓存无容量上限 + 滑动续期）。无按不可信长度预分配、无一次性物化、无全量 `spawn` |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，JWT 双解析只作待验证假设 1，未当缺陷 |
| §6.2 大粒度锁 | 0 | 模块内无显式锁；`CurrentHttpContext` 用 `ThreadLocal`（`f_mvc/src/CurrentHttpContext.cj:22`），无临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无批处理循环 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `contains` 热点、无 `remove(at: 0)`；重复解析归 #3 与待验证假设 1 |
| §7 降堆内存方案 | 0 | 唯一可降的是缓存条目常驻（#1，已按缺陷报）与 principal 上的密钥（#5）；无大对象副本、无流式化空间。`HeapCache` 每实例 1 线程 + 1 定时器的固定开销属 `f_cache` 范围 |
| §8 降 CPU 方案 | 1 | 优化方案"单请求只解析一次 JWT"（无基线，不进 tasks） |
| §9 local mode 可行性 | 0 | 模块内无函数内创建的大临时对象（最长路径是 `JWT` 解析，对象在 `f_jwt` 内）；收益无法用峰值内存证明，不列 |
| §11 现有代码的 BUG（存量） | 5 | #1（语义与文档不符 + 无界）、#2（错误处理缺失）、#3（TOCTOU）、#4（契约与实现）、#5（敏感数据）；#11 的未使用绑定另计 1 |
| §12 并发安全与锁粒度 | 0 | 逐个查共享点：`SecurityContext` 的 `store` / `principalMaker` / `check` 全是 `let`；两个 context 实现类的字段全是 `let`；唯一跨线程状态是 `ThreadLocal<HttpContext>`（线程封闭）与 `HeapCache`（`ConcHashMap` 分段 + `Priority.lock`，`f_cache/src/HeapCache.cj:29`、`256`）。本模块无共享可变状态，故无数据竞争；"`check` 在无上下文线程抛异常"按正确性记 #2，不记为并发缺陷 |
| §13 文档与代码一致性 | 2 | #6（类型清单写错）、#12（示例不可编译 + 关键段落缺失） |
| §14 功能完备性与 README 覆盖 | 1 | #12：`JWTSecurityContext.init(store:principalMaker:keySetter:)`、`HttpHeaderUserTokenSecurityContext.init(userIdHeader:tokenHeader:store:principalMaker:)`、`UserTokenSecurityContext.init(store:principalMaker:)` 三个构造器与 `keySetter` 语义未进 README；`StringUserTokenHeapCacheStore` 未登记（#7）。附注：`PrincipalStore.remove` 存在但 `SecurityContext` 无 `logout`，`store` 又是 `protected`，登出只能靠调用方自己保留 store 引用——这是 API 设计不对称，README 也未说明，未单列（无承诺源） |
| 文件覆盖（§13 等） | 16/16 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6（#1–#6） |
| 轻微 | 6（#7–#12） |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

这是一层很薄的封装：4 个接口 + 3 个 `SecurityContext` 实现 + 堆缓存适配 + 1 个异常类型，没有并发、没有资源生命周期、没有解析器，代码量小到可以逐行读。真正的风险不在"实现写错"，而在**凭据与生命周期的契约**：

1. **会话不过期**（#1）是最该排期的一条。`maxLife` 被文档写成"保持时间"，实现却是滑动空闲超时，`maxSize` 又是 `Int64.Max`；JWT 路径靠 `exp` 兜底，token 路径完全没有第二道闸，且容量不可配。改法很小（透传 `maxSize`、token 路径用 `once: true`），但会改默认行为，需要用户拍板。
2. **`check` 会抛异常**（#2）是唯一的"任何客户端可触发"问题：畸形 `Authorization` 头就能让 `(S) -> Bool` 抛 `JWTException`，非请求线程则抛 `None.getOrThrow()`。它不会崩进程，但会让每个坏请求多一条未捕获异常，且与 `f_mvc` 的 `AuthStatus` 模型（有 `SessionError`）冲突。修法是一个 `try`，建议与本轮一起改。
3. **密钥模型**（#5）与 **`toString` 当键**（#4）是同一类"把不该外露的东西放进数据对象"的问题：前者让签名密钥随 principal 扩散并驻留，后者让不同 `ID` 可能命中同一会话。两者都需要契约层决策（是否保留 `key` 字段、是否改用 `ID` 作键），不适合直接改代码。
4. **文档**（#6、#12）的问题比代码更"贵"：README 是唯一入口，却把 `UserTokenPrincipal` 写成 `BaseUserData` 实现、给了不能编译的 `type` 别名示例、缺构造器与过期语义。按文档接入的人会在选 `U` 类型和判断"多久掉线"这两件事上直接走错。

`#7`–`#11` 是清理项（死别名、死 import、纯委托层、非常量时间比较、重复取头），可以批量处理。存量共 12 条，是否纳入修复、以及 #5/#9 这类对外 public 的契约变更，待用户决定。
