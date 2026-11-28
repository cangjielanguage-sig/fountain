# f_jwt 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_jwt`（7 个源文件 + 7 个 .md，共 14 个文件）
- **基线**：工作区快照（sts/1.3.x，`git status f_jwt` 无未提交改动，无 diff 可比 → 全部记「存量」）
- **审查重点**：签名校验与安全边界（alg 混淆、过期校验）、死代码、空实现、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] 数字型声明的比较恒为 false：`verifyIssueAt` 对本模块签出的 token 永远不成立

- **位置**：`src/JWT.cj:459-465`（`verifyPayload`）、`src/JWT.cj:475-483`（`verifyIssueAt` 三个重载）、`src/JWT.cj:484-489`（`verifyId`）
- **来源**：存量（`git blame`：`verifyPayload`/`verifyIssueAt`/`verifyId` 均为 `4be871f2fd 2026-10-02`，不在任何近期改动内）
- **判据**：review-checklist §11（契约与实现不符）、§10 正确性（`Option`/类型匹配）、§14.1
- **证据**：静态确定 —— ① `f_data` 解析 JSON 时把所有数字统一成 `JsonDecimal`（`f_data/src/json/JsonValue.cj:173-174`：`case JsonNumber => JsonDecimal(reader.readValue<Decimal>())`）；② `getJsonValue<Any>` 因此把 `iat`/`jti`/任意数字声明取成 `Decimal`（`src/JWT.cj:352`）；③ `verifyPayload` 用 `if (let Some(v: Equatable<V>) <- getPayload(name))` 做**精确类型**匹配（`src/JWT.cj:460`），`V = Int64` 时 `Decimal` 不满足 `Equatable<Int64>`，直接落到 `else false`。
- **描述**：`iat` 按 RFC 7519 必然是数字，因此 `verifyIssueAt(Int64 / Duration / DateTime)` 对任何本模块签出的 token 都返回 `false`；同理 `verifyPayload("uid", 42)`、`verifyId<Int64>(cache)` 也恒 false。`getPayloadValue<T>` 因为多了一条 `case v: ToString => tryParse<T>` 兜底（`src/JWT.cj:414`）反而正常，这也是 `testPayloadFunctionality`（`src/JWT_test.cj:263`）能通过的原因；但三个验证型 API 没有这条兜底，**且测试套件完全没有 `verifyIssueAt` 用例**（全仓 grep 只命中 README 与源码），所以 20/20 全绿掩盖了该缺陷。后果是 fail-closed 的可用性事故：接入方按 README 用 `verifyIssueAt` 校验签发时间会拒绝全部合法 token。
- **建议**：`verifyPayload` 增加与 `getPayloadValue` 同构的字符串兜底（`case Some(v: ToString) => v.toString() == value.toString()`，放在 `case Some(v: V)` 之后）；`verifyId` 改为按 `jti.toString()` 查缓存（`HeapJwtIdCache` 的键本来就是 `id.toString()`，见 `src/JwtIdCache.cj:59`），或把 `T` 收紧到 `DataParsable<T>`；补 `verifyIssueAt` 与数字型 `verifyPayload` 的用例（`jwtId<Int64>` + `verifyId<Int64>` 一组）。

### [一般][存量] `JWTVerifier` 对不可信 token 不做结构校验，畸形 token 抛出非 `JWTException`

- **位置**：`src/JWT.cj:330-340`（构造函数）、`src/JWT.cj:341-348`（`populate`）、`src/JWT.cj:349-365`（`getJsonValue`）
- **来源**：存量（`git blame` 全部为 `4be871f2fd 2026-10-02`；`doc/spec/.../design.md:36` 明示「不处理畸形 token 的 RangeException」，属已知遗留）
- **判据**：review-checklist §11（边界/越界、错误处理）、§3（`case _ => ()` 兜底）、§10 安全性（外部输入未校验）
- **证据**：静态确定 —— `indexOf(".") ?? -1` 后直接 `data[0 .. firstDot]`（`-1` 上界）、`data[firstDot + 1 .. lastDot]`、`data[lastDot + 1 ..]` 均未判空/判序，越界切片按 std 文档抛 `IndexOutOfBoundsException`（`std.core`，`<: Exception`）；`String.unsafeUtf8` 后 `JsonValue.fromStr` 失败抛 `f_data` 的 `JsonException`（`f_data/src/json/JsonValue.cj:188`）；头字段非字符串时 `(r as T).getOrThrow()` 抛 `NoneValueException`（`src/JWT.cj:364`）。
- **描述**：`Authorization: Bearer abc`（无点）、`a.b.`（末尾点）、`{"alg":1}` 这类输入全部停在构造期抛非 `JWTException`。仓库内真实调用点 `f_security/src/JWTSecurityContext.cj:36-39` 直接 `JWT.verifier(jwt)` 且 lambda 内无 `try/catch`，只按 `catch JWTException` 兜底的调用方无法拦截 → 每个畸形 Bearer 头都会打断认证检查（而非返回 `false`/401），给日志与告警制造噪声，也让「token 无效」与「服务异常」不可区分。
- **建议**：构造期先校验 `firstDot > 0 && lastDot > firstDot + 1 && data.endsWith` 形态，任一不满足抛 `JWTException("malformed token")`；头必须是 `JsonObject`，`populate` 的 `case _ => ()` 改为抛异常；`getJsonValue` 类型不符时返回 `None` 而不是 `getOrThrow()`；对 token 总长设上限（见待验证假设 #3）。

### [一般][存量] 编码不是 RFC 7519 的 base64url，签名输入也不是紧凑序列化文本

- **位置**：`src/encoding.cj:23-41`（`fromBase64` / `toBase64`）、`src/JWT.cj:295-322`（`sign()` 编码）、`src/JWT.cj:450`（验签输入）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10 正确性（契约不符）、§14.1（`README.md:9` 承诺「本模块实现了完整的JWT特性」）
- **证据**：静态确定 —— `toBase64` 只转调 `stdx.encoding.base64.toBase64String`，该包在 stdx 1.3.0 文档里只有 `toBase64String(Array<Byte>): String` 与 `fromBase64String(String): Option<Array<Byte>>` 两个函数、无 URL-safe / 去填充选项（`cangjie-doc/stdx/1.3.0/libs_stdx/encoding/base64/base64_package_api`），即输出用 `+` `/` 与 `=` 填充；解码侧同样没有 `-`/`_` 归一化。另外验签用的是**解码后字节**重新拼接（`bytesForSign(headerBytes, payloadBytes)`），而不是 RFC 7515 定义的 `BASE64URL(header).BASE64URL(payload)` 文本。
- **描述**：① 本模块签出的 token 含 `+` `/` `=`，标准 JWT 库（jwt.io / Java jjwt / Go golang-jwt）会拒绝或解析失败；② 反之，别家签出的 base64url token（无填充、含 `-`/`_`）会在 `fromBase64` 处直接抛 `JWTException`，「完整的JWT特性」在跨语言场景不成立；③ 签名字节取自解码结果，token 字符串只要解码等价即可换一种写法，以 token 原文做去重/黑名单键的缓存（如 `UserSessionCache` 场景）可能被绕开。
- **建议**：模块内自带 `toBase64Url` / `fromBase64Url`（`+`→`-`、`/`→`_`、去 `=`，解码侧补齐 padding），编码与解码都用它；验签输入改为两段 base64url 文本的 ASCII 拼接；README 增加「与标准实现的兼容边界」段落。

### [一般][存量] HMAC 验签使用非恒定时间比较

- **位置**：`src/SignAlgo.cj:57-59`
- **来源**：存量（`git blame` 为 2026-10-02 基线；`doc/spec/.../design.md:31-33` 与 `verify.md:65` 明示为本次变更的 Out of Scope / SUGGESTION）
- **判据**：review-checklist §10 安全性、§11 契约
- **证据**：静态确定 —— `protected func verify(...) { this.sign(data) == sign }` 对 `Array<Byte>` 做逐字节短路比较，提前返回的位置泄漏「已匹配前缀长度」。
- **描述**：服务端对攻击者提交的签名可无限次测量时延，理论上可逐字节逼近正确 HMAC（需网络抖动远小于单字节比较差异，实践难度高但属已知攻击面）。对 RSA/ECDSA 无影响（stdx 内部处理）。
- **建议**：增加模块内 `constantTimeEquals(Array<Byte>, Array<Byte>)`（等长前提下全量异或累加），仅替换 `DigestSignAlgo.verify`；或对 `HMAC` 实例走 stdx 的 `HMAC.equal`，其余摘要用自实现常量时间比较。

### [一般][存量] 异常消息回显密钥与 token 原文

- **位置**：`src/encoding.cj:24`（`'${src} is not base64'`）、`src/encoding.cj:32`（`'${src} is not hex'`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10 安全性（敏感数据）；`fountain-baseline.md` §6「日志中不得出现凭据」
- **证据**：静态确定 —— `src` 的来源是 `hmac*ByHexKey(key)` / `hmac*ByBase64Key(key)` 的密钥参数（`src/JWT.cj:54,57,...`），以及 `JWTVerifier` 里的 token 三段（`src/JWT.cj:333-335`）。
- **描述**：密钥格式写错（少一位、混入空格）时，异常消息会把整段密钥写进 `JWTException.message`；这类消息通常被 `f_log` 或框架的统一异常处理落盘，且「写错的密钥」往往就是真密钥的近似体。token 段被整段回显还会放大日志体积（base64 长度 ≈ 4/3 原文）。
- **建议**：只报位置与长度，例如 `JWTException("hmac key is not valid hex (len=${src.size})")`；token 段同理只报段名。

### [一般][存量] 非对称算法入口 7 份同构实现，时间重载重复换算（§2）

- **位置**：`src/JWT.cj:104-200`（`ecdsa224/256/384/512`、`rsa256/384/512`）、`src/JWT.cj:213-246`（`expire`/`notBeforeAt`/`issuedAt` 的 9 个重载）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2（只改类型名 / 换算复制）
- **证据**：静态确定 —— 7 个函数体逐行对齐，差异只有 `SHA224/256/384/512` 类型、`useAlgo` 的名字、`RSASignAlgo` 额外的 `padType`；`expire(Duration)`/`expireAt(DateTime)`/`expireAt(Duration)` 与 `notBeforeAt`/`issuedAt` 的 `toSeconds()` 换算在三处重复。
- **描述**：新增算法或修一处边界（例如 ECDSA 也需要 `padType`、或某族要支持 `SM2`）时极易只改其中一份，形成行为漂移；当前 4 份 ECDSA 的 `throw JWTException("no key of ECDSA is been specified")` 与 3 份 RSA 的同类文案也是复制来的，文案改动需同步 7 处。
- **建议**：抽 `private func asymmetric(name: String, digest: Digest, privatePem: ?String, publicPem: ?String, padType: PadOption): This`，7 个入口各留一行调用；时间换算抽 `private func absoluteSeconds(DateTime): Int64`。

### [一般][存量] 对不可信 payload 的 JSON 递归遍历无深度上限（§4）

- **位置**：`src/JWT.cj:349-365`（`getJsonValue` 递归处理 `JsonArray` / `JsonObject`）、`src/JWT.cj:341-348`（`populate` → `getJsonValue` 互递归）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §4（无界递归：深度由输入决定）
- **证据**：需实测 —— 递归深度 = payload 的 JSON 嵌套层数，代码内无任何深度/长度上限；上界只由调用方 HTTP 头大小决定（`f_security` 从 `Authorization` 头取值，未截断）。`JsonValue.fromStr` 自身也是递归下降（`f_data/src/json/JsonValue.cj:185`），因此实际触发深度与「解析先爆栈还是遍历先爆栈」需用构造数据实测。
- **描述**：构造 `payload` 为 N 层嵌套数组/对象的 token（需能通过签名或落在签名校验之前的解析路径），`getJsonValue` 每层一帧并额外分配 `HashMap`/`Array`，深度足够时抛栈溢出（进程级错误，不可 catch）。当前 `JWTVerifier` 在构造期就完成解析，故攻击面在「任何拿到 token 字符串的调用点」。
- **建议**：`populate`/`getJsonValue` 改为显式栈迭代；或在解析前限制 `payloadBytes.size` 与嵌套深度（例如 32 层、1 MB），超限抛 `JWTException`。

### [轻微][存量] 死代码：6 个无调用者的编码/签名辅助（§1）

- **位置**：`src/encoding.cj:27`（`fromBase64ToString`，且未声明返回类型、`String.unsafeUtf8(...)` 结果被丢弃）、`src/encoding.cj:39`（`toBase64(String)`）、`src/SignAlgo.cj:27`（`sign(String)`）、`src/SignAlgo.cj:34`（`signToBase64(String)`）、`src/SignAlgo.cj:38`、`src/SignAlgo.cj:42`（`verifyFromBase64` 两个重载）
- **来源**：存量（`git blame`：全部 `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（`internal` 符号在本包及子包内无调用者）
- **证据**：静态确定 —— 在 `f_jwt`（含 `f_jwt.exception` 子包）、`f_security`、`fdemo`、根 `src` 内 `grep -rn`（排除 `.worktrees`/`target`），6 个符号均只命中定义处；`JWT`/`SignAlgo` 虽因 `sealed` 隐含 `public` 而对外可见，但这 6 个成员本身是 `internal`（无修饰符），仓内零引用。
- **描述**：这批「String 版本」重载是 JWT 早期用字符串表示待签名数据的残留，现在 `sign()`/`verifySign()` 全走 `Array<Byte>` 路径（`src/JWT.cj:322`、`src/JWT.cj:450`）。其中 `fromBase64ToString` 更危险：签名 `func fromBase64ToString(src: String)` 没有返回类型，调用它只会解码后丢弃结果，等于永远无输出。
- **建议**：删除这 6 个成员；若确要保留字符串便捷入口，补返回类型 `String` 并加用例覆盖。

### [轻微][存量] `NoneJwtIdCache` 的空实现没有代码注释说明（§3）

- **位置**：`src/JwtIdCache.cj:28-37`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（有意的 Null Object 必须有注释说明为什么可以空）
- **证据**：静态确定 —— `put` 两个重载空函数体、`contains`/`remove` 直接 `false`，类上无注释；只有 `README.md:538-539` 写了「不保存任何数据」。
- **描述**：Null Object 本身合理，但代码侧无说明，读代码的人无法区分「有意 no-op」与「忘记实现」；且 `remove` 恒 `false` 会让 `verifyId` 恒 false（fail-closed），这个语义也没写。
- **建议**：类注释补一句「不持久化 jti，等价于关闭防重放；`verifyId` 恒 false」。

### [轻微][存量] 非对称签名/验签用 `?? []` / `?? false` 静默兜底（§3）

- **位置**：`src/SignAlgo.cj:91`、`:99`、`:113`、`:119`、`:133`、`:139`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（静默失败 / 兜底把错误吃掉）
- **证据**：静态确定 —— `(key as RSAPrivateKey)?.sign(...) ?? []`，类型不符时返回零长签名，`JWTEncoder.sign()` 会把它编成 `header.payload.`（空签名段）而不是报错。当前 `RSASignAlgo`/`ECDSASignAlgo`/`SM2SignAlgo` 的构造函数参数类型使该 cast 不可能失败（`toPrivateKey` 已按具体类型转换），故不可达；但这是「扩展成接受通用 `PrivateKey` 后立刻变成静默空签名」的隐患。
- **描述**：同一 `match` 的 `case _ => throw JWTException(...)`（如 `:92`、`:100`）已经覆盖了无密钥场景，`??` 兜底只会吞掉类型错误。
- **建议**：改为 `case Some(key: RSAPrivateKey) => ...; case Some(_) => throw JWTException("unexpected private key type"); case _ => throw ...`，去掉 `??`。

### [轻微][存量] 未使用的 import（§1）

- **位置**：`src/JWT.cj:19`（`std.convert.Parsable`）、`src/JWT.cj:23-24`（`stdx.encoding.hex.*` / `stdx.encoding.base64.*`，文件内的 `fromHex`/`toBase64`/`fromBase64` 全部解析到本包 `encoding.cj`）、`src/encoding.cj:20`（`fountain::f_base.*`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 三个文件中除 `DataParsable`（来自 `f_data`）外，没有 `Parsable` / hex 包 / base64 包 / `f_base` 的任何符号引用。
- **描述**：无功能影响，但会误导读者以为编码走的是 stdx 直连。
- **建议**：删除这 4 行 import。

### [轻微][存量] `HeapJwtIdCache` 把自己的 `this` 当缓存值、用 `toString()` 当键

- **位置**：`src/JwtIdCache.cj:40`、`:58-63`、`:67-69`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10 可读性 / 语言特性；§11（语义与命名不符）
- **证据**：静态确定 —— `cache.set(id.toString(), this, life: expire)` 把 `HeapJwtIdCache` 实例自身存成 value（只为满足 `HeapCache<V> where V <: Object` 的泛型约束），缓存里真正有用的只有 key；`remove` 也只按 `id.toString()` 取。
- **描述**：① 每个条目都强引用整个缓存对象，`evictionCallback` 拿到的是 `this` 而不是被淘汰的 jti，用户无法在回调里做审计；② 两个不同的 `T` 若 `toString()` 相同（例如自定义类型未实现唯一表示）会互相覆盖，防重放静默失效；③ 读代码时很难看出「值不使用」。
- **建议**：把 value 换成 `id.toString()` 本身（`HeapCache<String>`），或在类注释里写明「value 恒为 this，仅用 key 表达存在性」；`T` 的约束补一句「`toString()` 必须唯一稳定」。

### [轻微][存量] README 中文把 `verifyIssueAt` 的语义写成「iss」

- **位置**：`README.md:493-504`（三段 `verifyIssueAt` 注释均为「确定iss 与参数是否相同」），对应实现 `src/JWT.cj:475-483`
- **来源**：存量（README 与源码同属快照基线）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— `verifyIssueAt` 比较的是 `iat`（`src/JWT.cj:476`：`verifyPayload('iat', issueAt)`）；`README_en.md:494-505` 三处均正确写作「iat」，说明是中文版复制粘贴遗留。
- **描述**：读者会以为这是校验 `iss` 的第三个重载（`verifyIssuer` 已存在），误用后得到恒 false 的结果。
- **建议**：中文三处改为「确定 iat 与参数是否相同」。

### [轻微][存量] `doc/spec/**/verify.md` 的 requirement / scenario 计数与 `spec.md` 不一致

- **位置**：`doc/spec/fix-f-jwt-signature-verification/verify.md:7-9`（「spec 5 条 ADDED requirement 全覆盖」「26 个 scenario 中 25 个有用例」），对照 `spec.md:11,41,62,92,118,128`
- **来源**：存量（归档规格文档）
- **判据**：review-checklist §13（规格与实现/规格内部漂移）
- **证据**：静态确定 —— `spec.md` 实为 **6** 条 requirement（HMAC 摘要映射、入口登记算法名、验签必须配算法、算法一致、保留解析头、拒绝空密钥），scenario 逐条数为 3+3+5+4+1+3 = **19**；`verify.md:44-49` 自己的映射表也列了 6 行。
- **描述**：归档文档的「5 条 / 26 个」两个数字都与 `spec.md` 对不上，后续按该文档复核覆盖率会得出错误结论（真实缺口是「缺 alg 头」场景无直接用例，verify.md 已单列，但计数错误掩盖了它）。
- **建议**：改为「6 条 requirement」「19 个 scenario，18 个有用例」；`verify.md:8` 的「5/5」同步改 6/6。

### [轻微][存量] `HeapJwtIdCache` 的 5 个构造参数未进 README（§14.2）

- **位置**：`README.md:537-542`（仅有类名与「基于 `fountain::f_cache.HeapCache`」），实现 `src/JwtIdCache.cj:42-56`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— `public init(concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL, maxLife!: Duration = ..., maxSize!: Int64 = ..., checkDuration!: Duration = ..., evictionCallback!: (String, HeapJwtIdCache<T>) -> Unit = {_,_ => ()})` 五个命名参数与默认值在 README / `README_en.md` 中均检索不到。
- **描述**：防重放缓存的容量与寿命直接决定「关掉服务后 token 是否可重放」和内存占用，属关键配置，按 README 只能看到默认值不可调。另外 README 也没说明 `verifyId` 的 `T` 必须与 `jwtId` 的 `T` 同类型（与上文严重项相关）。
- **建议**：补一张参数表（名字、默认值、含义、调大/调小的后果），并加一句「未知容量请显式设置 `maxSize`，默认值见常量」。

### [轻微][存量] `JWT`/`SignAlgo` 的可变状态未声明线程安全（§12）

- **位置**：`src/JWT.cj:31-49`（`headers`/`payload`/`signAlgo`/`algoName` 均为实例可变字段）、`src/SignAlgo.cj:24-25`（`SignAlgo` 持有单个 `Digest` 实例）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态）、§13（契约未声明）
- **证据**：静态确定 —— `DigestSignAlgo`/`RSA*`/`ECDSA*` 都复用构造时传入的同一个 `Digest`，`doDigest` 走 `stdDigest(digest, data)`（`src/SignAlgo.cj:45-47`）会 reset/write/finish 同一个实例；`JWT` 本身是可变 builder（`header`/`addPayload` 直接写字段）。**仓内没有共享路径**：`f_security/src/JWTSecurityContext.cj:36` 与 `fdemo/user/src/util/UserSessionCache.cj:46` 都是每次新建 encoder/verifier，因此当前不存在真实竞争。
- **描述**：风险在「调用方把 verifier 缓存成单例复用」这一常见优化上——并发 `verifySign()` 会互相 reset 同一个 `Digest`，可能把 A 请求的摘要算成 B 的数据（错误验签或随机失败）。README 没有任何线程安全声明，容易被误认为无状态。
- **建议**：README 明确「`JWT`/`JWTVerifier` 实例非线程安全，请每请求新建」；若要支持共享，把 `Digest` 改为每次签名时按算法名新建（`HMACDigest(key, HashType)` 已是工厂形态，可缓存 key 而非实例）。

## 优化可行性方案

### [堆内存] 去掉 `bytesForSign` 的全量拼接缓冲

- **现状**：每次签名/验签都新建 `Array<Byte>(header.size + payload.size)` 并逐字节拷贝（`src/encoding.cj:47-55`）；HMAC 路径随后再由 `doDigest` 走一遍摘要，签名结果再被 `toBase64String` 转成字符串。1 KB payload 时每次调用多 1 个约 1.3 KB 的临时数组，生命周期仅一次调用。
- **方案**：给 `SignAlgo` 增加 `sign(header: Array<Byte>, payload: Array<Byte>)` 的默认实现（`digest.write(header)` + `digest.write(payload)` + `finish()`），`DigestSignAlgo` 走两段写入，不再经过 `bytesForSign`；RSA/ECDSA 需要连续摘要输入，继续用现有拼接。
- **预期**：HMAC 每次 sign/verify 少 1 次 O(n) 拷贝、少 1 个临时数组（分配次数可从 5 次降到 4 次/调用，字节收益与 token 长度成正比）。
- **代价**：`SignAlgo` 多一个方法；需确认 `Digest` 的 `write` 多次调用后再 `finish` 的语义与单次 `digest(digest, data)` 一致（std 文档：`digest` 内部即 reset/write/finish）。
- **验证**：同输入 1e6 次 sign + verify，比较 `getAllocatedHeapSize()` 与 RSS；`cjpm bench -O2` 对照中位数与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `JWTEncoder.sign()` 的 JSON 中间树与 base64 两次遍历

- **现状**：`sign()` 先把 `payload` 逐项搬进 `JsonObject`（底层 `HashMap<String, JsonValue>`，`f_data/src/json/JsonValue.cj:456-492`），再 `toString()` 生成字符串，再 base64 一次；header 同样两趟。即一次签名要遍历数据三遍、并同时持有「原 map + JsonValue 树 + JSON 串 + base64 串」四份表示。
- **方案**：改为直接写 `StringBuilder`（按 `payload` 顺序生成 JSON 文本），边生成边喂给 base64 编码器，省掉 `JsonObject` 中间树与一次全量字符串。
- **预期**：大 payload（数百字段）时减少 2 份全量副本与 2 次遍历；小 token 收益接近噪声。
- **代价**：需要自己保证 JSON 转义与数字格式与 `JsonValue` 一致（否则跨语言验签会变）；`payload` 的类型分派逻辑（`src/JWT.cj:299-318`）要原样保留。
- **验证**：`cjpm bench -O2`，输入 10 / 100 / 1000 字段三档，比较 sign 的 P50/P95；并用现有 `testLargePayload` 断言输出可被自身验签。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `bytesForSign` 的整段拷贝在 `verifySign` 自耗时中占比可忽略或可观 | `src/encoding.cj:47` | 自耗时占比 | `cjprof record` 跑 10k 次 `verifySign`（1 KB payload，单线程），看 `bytesForSign` / `doDigest` 的 self time |
| 2 | `JsonValue.fromStr` + base64 解码占验签链路的主要 CPU | `src/JWT.cj:336-337` | 分段耗时 | 在构造期与 `verifySign` 前后打点，10k token 取中位数；或用 `cjprof` 看解析占比 |
| 3 | 嵌套 payload 的栈溢出阈值低于 HTTP 头大小上限 | `src/JWT.cj:349-365` | 触发深度 | 构造 100/500/1000/2000 层嵌套数组的 token，逐档跑 `verifySign`，记录首次栈溢出的深度与 `ulimit -s` |
| 4 | `HeapJwtIdCache` 的 `toString()` + 字符串哈希在每请求 `verifyId` 下占比低 | `src/JwtIdCache.cj:59-69` | 单次耗时 | 对 `put`/`remove` 各跑 1e6 次，比较不同 `T`（String vs Int64）的耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jwt/README.md` | .md | ✅ | 与实现基本一致；中文 `verifyIssueAt` 注释错误（见轻微项）、`HeapJwtIdCache` 参数缺失、缺 RFC 兼容边界段落 |
| 2 | `f_jwt/README_en.md` | .md | ✅ | 与中文版章节一一对应，`iat` 描述正确；同样缺 `HeapJwtIdCache` 参数表 |
| 3 | `doc/spec/fix-f-jwt-signature-verification/design.md` | .md | ✅ | 设计与实现一致（D1~D7）；D 之外遗留的 RangeException 已在本报告作为存量项提出 |
| 4 | `doc/spec/fix-f-jwt-signature-verification/proposal.md` | .md | ✅ | 变更清单与 `src/` 现状吻合，无过期承诺 |
| 5 | `doc/spec/fix-f-jwt-signature-verification/spec.md` | .md | ✅ | 6 条 requirement、19 个 scenario；「缺 alg 头」场景实现已覆盖（`src/JWT.cj:444-446`） |
| 6 | `doc/spec/fix-f-jwt-signature-verification/tasks.md` | .md | ✅ | 21 项全部勾选，与 `verify.md` 的 21/21 一致 |
| 7 | `doc/spec/fix-f-jwt-signature-verification/verify.md` | .md | ✅ | 计数与 `spec.md` 不符（见轻微项）；「可以归档」的结论本身成立 |
| 8 | `src/HMACDigest.cj` | .cj | ✅ | 空密钥守卫集中在 `create()`，与 spec 一致 |
| 9 | `src/JWT.cj` | .cj | ✅ | 主要缺陷集中处（数字声明比较、畸形 token、编码规范） |
| 10 | `src/JWT_test.cj` | .cj | ✅ | 20 个用例；缺 `verifyIssueAt`/`verifyId`/畸形 token 三类覆盖 |
| 11 | `src/JwtIdCache.cj` | .cj | ✅ | `NoneJwtIdCache` 注释缺失、`HeapJwtIdCache` 用 `this` 作值 |
| 12 | `src/SignAlgo.cj` | .cj | ✅ | 非恒定时间比较、`?? []` 兜底、4 个死代码重载 |
| 13 | `src/encoding.cj` | .cj | ✅ | base64 非 url-safe、异常回显原文、`fromBase64ToString` 无返回值 |
| 14 | `src/exception/JWTException.cj` | .cj | ✅ | 四个构造函数与 README 描述一致 |

合计：`.cj` 7 个 / `.md` 7 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 1（数字声明比较恒 false）、安全性 3（非恒定时间比较、密钥回显、畸形 token 未校验）、设计 1（重复逻辑）、可读性 1（`this` 作缓存值、`toString()` 作键） |
| §1 死代码 | 1 条（覆盖 6 个符号） | 已逐个核对 `private`/`internal`/`protected`：`SignAlgo` 与 `JWT` 因 `sealed` 隐含 `public`，其 `public` 成员不判；`NoneDigest`/`AsymmetricSignAlgo` 的 `protected` 成员均被本包子类使用；6 个无修饰符（internal）重载在 `f_jwt`+子包、`f_security`、`fdemo`、根 `src` 内零引用 |
| §2 重复逻辑 | 1 | 两两比对同文件函数体：7 个非对称入口同构、9 个时间重载换算重复；`hmac*` 的 6 个入口已是 3 行薄封装，未再计 |
| §3 空实现 | 2 | `NoneJwtIdCache` 无注释的 Null Object；非对称签名 `?? []` 静默兜底。无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 1 | `getJsonValue`/`populate` 对不可信 JSON 递归无上限（需实测触发深度，故定一般） |
| §5 OOM | 0 | 无全局容器增长；token 全长受调用方 HTTP 头限制，解码/解析为 3~4 份线性副本，未发现按不可信长度预分配或无界缓存（`HeapJwtIdCache` 有 `maxSize`） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点不成立，已列入待验证假设 #1 #2 #4 |
| §6.2 大粒度锁 | 0 | 模块内无 `synchronized`/锁；`HeapCache` 的分段锁在范围外 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/批处理 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`；`bytesForSign` 的 O(n) 拷贝属常数因子，已归入优化方案 |
| §7 降堆内存方案 | 1 | `bytesForSign` 全量拼接（无基线，待验证） |
| §8 降 CPU 方案 | 1 | `sign()` 的 JSON 中间树 + base64 两趟（无基线，待验证） |
| §9 local mode 可行性 | 0 | 单次 sign/verify 的临时对象与 token 同阶（KB 级），无函数内大对象峰值，收益无法用峰值内存证明；且 `String`/`Array` 的 std API 无 mode 重载，改造不成立 |
| §11 现有代码的 BUG（存量） | 5 | 数字声明比较（严重）、畸形 token 异常、base64url 偏离、密钥回显、递归无上限；另核对 `isExpired`/`isNotBefore`/`getExpireAt`/`expireAt` 的边界（exp 缺失按有效、`exp == now` 判过期）均与 README 一致 |
| §12 并发安全与锁粒度 | 1 | 已列出共享点（`JWT` 实例字段、`SignAlgo` 内单个 `Digest`）与现状（`f_security`/`fdemo` 均每请求新建，无线程共享路径），结论为「需在 README 声明非线程安全」；锁粒度无命中（模块内无锁） |
| §14 功能完备性与 README 覆盖 | 3 | 13 个算法入口与 README 表逐一对应 ✓；`SM2SignAlgo` 无 `sm2()` 入口已在 README:562 声明 ✓；缺口：`HeapJwtIdCache` 5 个构造参数未文档化、`verifyId` 同类型要求未写、「完整的JWT特性」与 base64url/SM2 现状不符 |
| 文件覆盖（§13 等） | 14/14 | §13 命中 2（README 中文 `verifyIssueAt` 注释、`verify.md` 计数）；7 个 .md 全部逐节与 `src/` 对照 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

签名/验签主链路本身是可靠的：13 个入口统一走 `useAlgo`，`alg` 与 `headers` 解耦，`verifySign()` 先比算法再验签，未配算法落到 `NoneSignAlgo` 抛异常——常见的 alg 混淆与「无签名通过」路径都已堵住，空 HMAC 密钥也收敛到 `HMACDigest.create` 一处。`doc/spec` 四件套与实现基本自洽。

阻塞项只有一条：`verifyIssueAt` / 数字型 `verifyPayload` / `verifyId` 因 JSON 数字统一解析成 `Decimal` 而恒返回 false（`JWT` 公共契约失效，且测试完全没覆盖这条路径），修复成本低，建议优先处理并补用例。其次是三条安全/规范面：畸形 token 在构造期抛出非 `JWTException`（`f_security` 认证 lambda 会直接被打断）、编码不是 base64url 导致跨语言不可用、HMAC 比较非常量时间。

死代码与重复逻辑属可维护性问题：6 个 internal 便利重载零引用（其中 `fromBase64ToString` 连返回类型都没有），7 个非对称入口同构复制，可排期合并。性能侧没有 profile/bench 数据，两条优化方案与 4 条假设只作为下一轮补数据的输入，不进修复清单。

存量缺陷共 16 条（严重 1 / 一般 6 / 轻微 9），本轮均为工作区快照存量，是否纳入修复待用户决定。
