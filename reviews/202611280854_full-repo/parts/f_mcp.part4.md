# f_mcp 模块审查报告（模块第 4/5 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mcp`（本部分 20 个文件：`.cj` 20 个 / `.md` 0 个）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，全部记为「存量」）
- **审查重点**：MCP 协议正确性、会话与资源生命周期、并发安全、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块第 4/5 部分，只统计本部分文件；`README` / `doc/**` 在 1-3 部分，`McpServer` / `McpSse` / `McpTool` / `McpResultStore` / `McpResource` 在 5 部分）

本部分文件：`base/McpModels.cj`、`base/McpProtocol.cj`、`client/McpClient.cj`、`exports.cj`、`macros/Mcp.cj`、`macros/imports.cj`、`server/McpAnnotations.cj`、`server/McpConfig.cj`、`server/McpController.cj`、`server/McpConvert.cj`、`server/McpPrompt.cj`、`server/McpRateLimit.cj`、`server/McpRegistry.cj` + 7 个 `*_test.cj`。

## 发现

### [一般][存量] 1. stdio 传输会把并发请求中「别人的响应」当 stale 丢弃，导致该请求空等到超时

- **位置**：`f_mcp/src/client/McpClient.cj:126`（`send` 持锁等待）、`:129`（`lines.remove(at: 0)`）、`:169-205`（`classify`）、`:187-188`（丢弃分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入 / 同步缺失）、§11（契约与实现不符）
- **证据**：静态确定 —— 两个并发访问者与同步手段都能指出来，见下
- **描述**：
  1. 访问者 A、B 分别是两个线程上的 `McpClient.callTool` → `JsonRpcClient.call`（`f_jsonrpc/src/client/JsonRpcClient.cj:82-95` 全程无锁）→ `StdioJsonRpcTransport.send`。
  2. 两者都已把请求写进 stdin（`:114-118`，受另一把 `writeMutex` 保护），A 先拿到 `mutex`（`:126`）并进入等待，B 阻塞在 `:126` 之外。
  3. MCP 服务端允许并发处理请求，回包乱序（先 B 的 id=2、后 A 的 id=1）。B 的响应行先被 `consumeStdout` 入队（`:212`）；A 取出后 `classify` 判 id 不等（`:184`）→ 打一条 `stale stdio response` 日志 → `Skip`（`:187-188`），**该行被永久丢弃**。
  4. A 取到自己的响应返回；B 进入临界区时 `lines` 已空，只能等到 `timeout`（`:139-141`，默认 30s，`McpClient.cj:31`）抛 `IOException('stdio response timeout')`。
- **后果**：并发调用 stdio transport 时出现随机的、与业务无关的 30s 超时；响应内容丢失。单线程顺序调用不触发。
- **建议**：`classify` 命中「id 不等但形态是响应」时不要丢，改为按 id 存入 `HashMap<String, String>` 待取表，`send` 先查表再等；或者干脆在 `send` 入口用一把串行锁把 stdio 请求排成单飞（stdio 本来就是单管道），并在类注释里写明「并发调用在客户端串行」。

### [一般][存量] 2. stdio 的 `lines` 只增不减：通知无人消费时无界增长，且 `remove(at: 0)` 是 O(n)

- **位置**：`f_mcp/src/client/McpClient.cj:96`（`lines` 声明）、`:129`（`remove(at: 0)`）、`:211-213`（`consumeStdout` 无条件入队）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界容器）、§6.4（`remove(at: 0)` 当队列头）
- **证据**：静态确定（增长路径与消费路径只有这一处，读代码即可定）
- **描述**：`lines` 的唯一消费者是 `send`（`:128-134`），而生产者在 `consumeStdout` 里对**每一行** stdout 无条件 `add`。服务端推送的 `notifications/*`（tools/list_changed、progress、日志）没有任何请求在途时照样入队；`classify` 的跳过逻辑只在 `send` 内部执行，所以「没有人在等响应」时队列只增不减。
  - 量化：单行通知约 100-300 B。10 条/s 的常驻通知 → 约 7 MB/小时；100 条/s → 约 70 MB/小时，直到 OOM。触发面是「长期只监听、很少发请求」的客户端（典型 MCP 订阅场景）。
  - 积压 n 行时每次 `send` 的消费成本是 O(n²)（`ArrayList.remove(at: 0)` 每次搬移剩余元素）。
- **建议**：`consumeStdout` 里对「无 `id`」的行直接丢弃（或交给通知回调），只把有 `id` 的行入表，并按 id 建 `HashMap` 而不是 FIFO；若必须保序，改用索引队列（不删除元素，只推进读指针）。

### [一般][存量] 3. `close()` 与在途 `send` 抢同一把 `mutex`：关闭最长被阻塞一个 `timeout`（默认 30s）

- **位置**：`f_mcp/src/client/McpClient.cj:148-155`（`close` 取锁 + `notifyAll`）、`:126-145`（`send` 持锁 `cond.wait`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（同步缺失 / 条件等待）、§11（资源释放不对称）
- **证据**：静态确定
- **描述**：`send` 在 `synchronized(mutex)` 内做 `cond.wait(timeout: timeout - elapsed)`，最长持有 30s。`close()` 第一件事就是 `synchronized(mutex)`（`:149`），因此无法执行 `cond.notifyAll()`（`:154`）去唤醒等待者，只能等 `send` 自己超时释放锁；`close()` 随后才 `terminate()`。结果是「取消一个卡住的 stdio 请求」在客户端侧不可行，关闭动作被在途请求拖住。
- **建议**：把「是否关闭」拆成独立的 `AtomicBool`/单独锁，`close()` 先置位并 `notifyAll()`，或先关 stdin / `terminate()` 让 `consumeStdout` 走到 EOF 分支（`:219-222`）由它 `notifyAll`，再取 `mutex` 收尾。

### [一般][存量] 4. `/mcp/sse` 的查询串按「字节当码点」解码，非 ASCII 的 `topics` / 参数静默变乱码

- **位置**：`f_mcp/src/server/McpController.cj:119-138`（`decodeComponent`，关键在 `:125-127`）、调用点 `:33` / `:44` / `:100-117`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约不符）、§2（重复实现，见同条「建议」）
- **证据**：静态确定；文档对照：`stdx` `URL.decodeComponent`（`cangjie_stdx/doc/libs_stdx/encoding/url/url_package_api/url_package_classes.md:988-1016`）与 `URL.queryForm`（同文件 `:685-716`，示例把 `name=张三` 正确解成 `张三`）
- **描述**：`decodeComponent` 把 `%XX` 直接还原成一个 `Rune(UInt32(hi*16+lo))`，等价于按 Latin-1 解码。标准客户端会把 `topics=%E8%B5%84%E6%BA%90`（「资源」的 UTF-8）发上来，这里得到 3 个乱码字符，`SubscriptionHub.matches` 永不命中 → 订阅建立成功但一条事件都收不到，且没有任何诊断。`+` → 空格、非法 `%` 原样保留的处理是对的，问题仅在多字节编码。
- **建议**：直接用 `http.request.url.queryForm`（`Form.get`）或 `URL.decodeComponent` 取代 `queryOf` + `decodeComponent`（顺带消掉这 38 行重复实现）；若要保留自有实现，必须先把 `%XX` 聚合成 `Array<Byte>` 再 `String.fromUtf8`。

### [一般][存量] 5. `/mcp/sse` 无任何调用方校验：可接管他人 `subscriptionId`、可无认证占满订阅池

- **位置**：`f_mcp/src/server/McpController.cj:30-52`（`sse()`，`:39` 的 `attach`、`:44` 的直连订阅）、配合 `f_mcp/src/server/McpServer.cj:194-208`（`attach` 只判 id 与 `!attached`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（越权）、§12.1（有界性）、§10 安全性
- **证据**：静态确定（整条 GET 路径无 caller 派生、无凭据校验）；利用面取决于部署（`McpController.handle` 派生 caller 的 `X-Forwarded-For` / `Authorization` 逻辑只用在 `/mcp`）
- **描述**：
  - 带 `subscriptionId` 时直接 `server.hub().attach(id)`：`attach` 只看 `id` 相等且 `!attached`，不校验调用方。订阅 id 是 `AtomicInt64` 从 1 递增（`McpServer.cj:122`、`:164`），可枚举，因此任何人可以「猜号」接管别人尚未连接的订阅并收到其通知。
  - 不带 `subscriptionId` 时按 `topics`（缺省 = 全部）建订阅，同样无认证；`maxSubscribers` 默认 1024（`McpServer.cj:127`），1024 个匿名 GET 即可把池占满，使正常 `subscriptions/listen` 收到 `-32003`。
  - 附带：`catch (e: McpException) → status(400)`（`:46-49`）把「订阅池满 / 限流」也映射成 400，语义上应是 503 / 429；`throw e` 之后框架是否仍保留 400 与 JSON 错误体，本部分无法确认（属 5 部分/框架行为）。
- **建议**：`subscriptions/listen` 建订阅时记录派生出的 caller，`attach(id)` 增加 `caller` 参数并比对不一致即 403；直连路径同样先做 caller 派生（复用 `/mcp` 的逻辑）；对 `OVERLOADED` 单独映射 503 + `Retry-After`。

### [一般][存量] 6. `@McpPromptArg[required: false]` 配非 `Option<T>` 参数时，「可选」在调用期必然失败

- **位置**：`f_mcp/src/server/McpRegistry.cj:177-190`（`:186` 用 `JsonNull.instance` 占位）、`f_mcp/src/macros/Mcp.cj:183`（生成 `McpConvert.argument<T>(__mcp_raw[$count])`）、`f_mcp/src/server/McpConvert.cj:38-43`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14（承诺与实现不符）、§11（契约不符）
- **证据**：静态确定（类型与调用链可逐行追；`String.tryFromData(DataNone) => None<String>` 见 `f_data/src/base/DataString.cj:51`，`Option<T> <: DataFields` 见 `f_data/src/base/OptionData.cj:18-31`）
- **描述**：注册期允许 `required: false`，缺参时塞 `JsonNull`；调用期 `McpConvert.argument<T>` 对 `JsonNull.toData() == DataNone` 走 `convert<T>`，普通类型（`String` / `Int64` / `@DataAssist` 类）都拿不到值 → 抛 `McpException(-32602, 'invalid argument: null')`。于是 `prompts/list` 里声明 `required: false` 的参数实际必填，客户端按声明省略就一定报参数错误。只有把参数类型写成 `Option<T>` 才能成立（README:133 是这样建议的），但注册期不校验这个约束，属于埋雷。
- **建议**：`registerPromptMeta` 在 `required == false` 且参数类型不是 `Option<...>` 时直接 `throw McpException(INTERNAL_ERROR, ...)`（构建期失败优于运行期静默失败）；或在 `argument` 层对 `DataNone` 明确返回 `None<T>`/默认值，并同步文档。

### [一般][存量] 7. `ConcurrencyGate` 的 `sweep` 与 `tryAcquire` 存在 check-then-act 竞态，清理窗口内可超额放行

- **位置**：`f_mcp/src/server/McpRateLimit.cj:396-413`（`tryAcquire` 取条目后 CAS 计数）、`:449-469`（`sweep` 删除 `count == 0 && 空闲` 的条目）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入 / 容器线程安全不等于复合操作原子）
- **证据**：静态确定（时序可逐步构造，见下）
- **描述**：`tryAcquire` 先 `counts.get(key)` 拿到 `GateEntry` 引用（`:395-399`），再做 `load` + `compareAndSwap`（`:405-413`）。在这两步之间，另一线程的 `sweep`（每 256 次操作触发一次，`:402-404`）可能因为 `count == 0 && idle` 把该 key 从 map 里删掉（`:451-453`）。此后 `tryAcquire` 的 CAS 打在**已脱离 map 的对象**上并成功返回 `true`，而 `counts` 里该 key 已不存在：新来的请求会新建一个 `count = 0` 的条目再放行一个，实际并发度可短暂超过 `limit`；`release(key)` 找不到 key（`:417-430`）也不会回补。类注释（`:371-376`）明确写了「删 key 会与并发的 tryAcquire 竞态，导致新条目从 0 开始计数」，但 `sweep` 仍然在删，只有「count 非 0 不删」这一层保护挡不住上面的窗口。
- **建议**：删除动作改成 CAS 式「只有仍然 count==0 且版本未变才删」（给 `GateEntry` 加版本号/用 `remove(key, entry)` 语义），或 `sweep` 只做标记、由下一次 `tryAcquire` 自己重建；`tryAcquire` 在 CAS 前用 `compute`/`getOrCreate` 原子拿到条目而不是先 `get` 再 CAS。`LimiterPool.acquire`（`:140-157`）同一模式，同样建议统一。

### [轻微][存量] 8. `classify` 只按 `id` 判响应：服务端发来的「请求」若 id 撞上就直接当响应

- **位置**：`f_mcp/src/client/McpClient.cj:182-188`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（协议语义）、与 README:33「未实现 sampling/roots」的能力声明比对
- **证据**：静态确定（判定条件只有 `id.toString() == expected.toString()`）
- **描述**：JSON-RPC 双向的两套 id 空间是独立的。服务端若发 `roots/list` / `sampling/createMessage`（`id` 从 1 开始也很常见），只要数值等于当前在途请求 id，就会被判为 `Response` 交回 `JsonRpcClient`；该对象没有 `result`/`error`，客户端抛 `malformed json-rpc response: missing result`（`f_jsonrpc/src/client/JsonRpcClient.cj:90-94`），而真正的响应被留在 `lines` 里当成 stale 丢掉。README:33 已声明 `sampling` / `roots` 未实现，所以这条当前是「未实现能力下的误判」，但误判路径本身是确定的。
- **建议**：`classify` 判响应时要求「有 `id` 且（有 `result` 或 `error`）且无 `method`」；对服务端请求显式回 `-32601`（而不是只打 DEBUG 日志后 `Skip`，`:189-199`）。

### [轻微][存量] 9. `ToolPage` / `ResourcePage` / `PromptPage`（及 `ReadResourceResult`）的 `fromJson` / `toJson` 是同一份代码只换了类型名

- **位置**：`f_mcp/src/base/McpModels.cj:291-317`、`:329-355`、`:367-393`、`:403-425`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（「只改类型名」形态）
- **证据**：静态确定（把四个函数体压成摘要：`obj[key]` → 过滤 `JsonObject` → 逐项 `X.fromJson` → `X(..., optionalStringOf(obj,'nextCursor'))`，逐行对齐）
- **描述**：三处 `fromJson` 只差「字段名（`tools` / `resources` / `prompts`）+ 元素类型 + `X.fromJson`」，三处 `toJson` 只差同样的字面量；`ReadResourceResult` 是同一形态的第四份（字段 `contents`，无 `nextCursor`）。差异点只有字段名与元素类型，没有语义差异（可空性、排序、错误处理都一致），属可合并的重复。
- **建议**：加一个包内私有辅助 `func pageOf<T>(obj: JsonObject, key: String, fromJson: (JsonObject) -> T): Array<T>`（`toJson` 同理），public 类型与签名保持不变；`ReadResourceResult` 复用同一个 helper。

### [轻微][存量] 10. `RateLimitBackends.of` 与 `fromConfig` 是同一段查表逻辑的两份实现

- **位置**：`f_mcp/src/server/McpRateLimit.cj:336-341`、`:344-353`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一语义、仅错误文案不同）
- **证据**：静态确定
- **描述**：两者都是 `backends.get(normalize(name))` → `factory()`，唯一差异是错误消息里写 `mcp_rateLimitBackend` 还是裸名字。`fromConfig` 完全可以 `of(name)` 后再把异常包一层带配置键的提示，行为不变。
- **建议**：`fromConfig` 里 `try { of(name) } catch (e: IllegalArgumentException) { throw IllegalArgumentException("unknown ${McpConfig.RATE_LIMIT_BACKEND} '${name}'") }`，或把「查表 + 构造」抽成 `private static func create(name: String, errorLabel: String): RateLimitBackend`。

### [轻微][存量] 11. 三个 `get*Meta` 是同一份反射逻辑，且「查不到」时静默跳过注册

- **位置**：`f_mcp/src/server/McpRegistry.cj:47-54`、`:57-64`、`:67-74`；静默跳过的消费点 `f_mcp/src/macros/Mcp.cj:203-209`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名）、§11（静默失效）
- **证据**：静态确定（`catch (_: InfoNotFoundException) { return None }` → 宏里 `if (meta.isSome())` 才注册，否则既无日志也无构建错误）
- **描述**：三份函数体除注解类型外完全相同。更值得注意的是失败路径：`TypeInfo.of<T>().getInstanceFunction(name, args)` 一旦因为参数类型 `TypeInfo` 与声明不完全一致（例如参数类型是别名、或跨模块的 `@DataAssist` 类型）抛 `InfoNotFoundException`，工具/资源/提示词会**无声消失**，`tools/list` 里看不到、启动也不报错，只能靠人肉比对注册代码。
- **建议**：抽成 `private func annotationOf<T, A>(name: String, args: Array<TypeInfo>): ?A`（若反射 API 的泛型约束允许），并在 `None` 分支至少记一条 WARN 并带上 `name` 与 `args` 的类型名；`@Mcp` 展开侧对「有注解但拿不到元数据」直接 `diagReport(ERROR)`。

### [轻微][存量] 12. `rpcCall` 的 `McpException` 与 `JsonRpcException` 两个 catch 分支逐行同构

- **位置**：`f_mcp/src/client/McpClient.cj:416-427`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复）
- **证据**：静态确定（两分支的 `if (code == UNSUPPORTED_VERSION && tried.isNone()) { negotiate; retry }` 完全一致）
- **描述**：`McpException <: JsonRpcException`（`base/McpException.cj:22`），所以后一个 `catch` 已经覆盖前者；两个分支的唯一差异是「`McpException` 原样抛出 vs 包装成 `McpException`」。这是可合并的近似重复，且当前写法容易在改一处时漏改另一处（例如以后要按 code 分类处理）。
- **建议**：只留 `catch (e: JsonRpcException)`，内部 `if (e is McpException) { throw e }`，否则 `throw McpException(e.code, e.message, data: e.data)`。

### [轻微][存量] 13. `listAllTools` 的两个硬上限与错误文案对不上，且不可配置

- **位置**：`f_mcp/src/client/McpClient.cj:300-319`（`:304` 的 `rounds < 100 && all.size < 1000`、`:315-317` 的报错）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与文案不符）、§10（可配置性）
- **证据**：静态确定
- **描述**：实际触发抛错的条件有两个：`rounds` 到 100 **或** 累计 1000 条仍有 `nextCursor`；但消息固定写 `exceeded 100 pages`。服务端每页 50 条时会在第 20 页就因为 1000 条上限报「100 页」，排查时会被误导。两个上限也无法从 `McpClientOptions` 调整。
- **建议**：把两处上限放进 `McpClientOptions`（`maxListPages` / `maxListItems`），错误消息按实际触发的那条拼（`exceeded ${limit} pages` / `exceeded ${limit} items`）。

### [轻微][存量] 14. 后端同名注册静默覆盖，与项目基线「同名注册启动直接失败」相反

- **位置**：`f_mcp/src/server/McpRateLimit.cj:331-333`（`backends.add(normalize(T.name), T.new)`）
- **来源**：存量（快照模式无基线）
- **判据**：`references/fountain-baseline.md` §4（同名注册：启动直接失败，不做隐式优先级）；review-checklist §11（契约）
- **证据**：静态确定（`ConcurrentHashMap.add` 覆盖同键，代码注释也写明「同名重复注册会覆盖」）
- **描述**：两个模块各自 `register<MyBackend>()` 且 `name` 相同（或与内置 `token-bucket` 撞名）时，后注册者静默生效，配置里写同一个名字会随加载顺序改变行为。基线的约定是启动期直接失败。
- **建议**：`if (backends.contains(normalized)) { throw IllegalArgumentException(...) }`；确有「覆盖内置」需求时单开 `replace<T>()` 并在 README 写明。

### [轻微][存量] 15. 关闭 / 吞异常路径不对称：`consumeStderr` 无 try、`close` 吞掉全部异常、`UnlimitedRateLimitBackend.close` 空实现无说明

- **位置**：`f_mcp/src/client/McpClient.cj:156-166`（两处 `catch (_: Exception) {}` 与 `let _ = process.wait(...)`）、`:225-230`（`consumeStderr` 无异常保护）、`:216-217`（`consumeStdout` 吞异常）；`f_mcp/src/server/McpRateLimit.cj:310`（`close() {}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞异常 / 无注释的空 no-op）、§11（资源释放不对称）
- **证据**：静态确定
- **描述**：（1）`close()` 把 `stdInPipe.close()` 与 `terminate()` 的异常全部吞掉，且 `process.wait(timeout: 2s)` 的返回值被丢弃——子进程 2s 内没退出时既不重试也不记录，等于留下一个可能仍存活的子进程。（2）`consumeStdout` 有 `try/catch`，孪生的 `consumeStderr` 没有，管道异常会以未捕获异常的形式打死该 `spawn` 线程（不会崩进程，但日志是栈而不是一行 WARN），两处行为不一致。（3）`UnlimitedRateLimitBackend.close()` 是空 no-op，属可接受的 Null Object，但没有一句注释说明「无需释放」，按 §3 需要注释。
- **建议**：`close()` 里对 `wait` 结果判 `false` 时记 WARN 并再 `kill()`；两个 `consume*` 统一 `try/catch` + WARN；给空 `close()` 补 `// 无内部资源`。

### [轻微][存量] 16. `McpController` 构造期缓存 `McpRegistry.server()`，`configure` 的「立即生效」对 HTTP 路径不成立

- **位置**：`f_mcp/src/server/McpController.cj:28`（`private let server = McpRegistry.server()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§14（接线缺失）
- **证据**：待确认 —— 需确认 `@Controller`（= `@Bean`，默认 `BeanScope.singleton`，`f_bean/src/BeanMeta.cj:26`）实例的创建时机；`McpRegistry.configure` 的契约是「已经 `build()` 过时立即重建，新注册马上生效」（`McpRegistry.cj:30-34`、README:547-549）
- **描述**：控制器把 `McpServer` 在字段初始化时取一次并永久持有；`McpRegistry.configure` 之后 `built` 被换成新实例，但 HTTP 路由仍打到旧实例上，新注册的 tool / resource / prompt 对 `/mcp` 不可见（对直接 `McpRegistry.server()` 的调用方可见）。文档虽写着「只应在启动阶段调用」，同一段又承诺「立即重建、马上生效」，两者对使用者是矛盾的。若在控制器创建之后再 `build()`，还会把结果缓存与订阅状态按文档所说丢掉，却没有任何提示。
- **建议**：`McpController` 改成每次请求 `McpRegistry.server()`（或持有 `() -> McpServer` 的取值函数）；若坚持缓存，就在 `configure`/`build` 时把「已存在控制器持有的旧实例」显式作废（例如 `built` 加版本号，控制器比对版本后重取），并把文档统一成「仅启动期有效」。

## 优化可行性方案

> 不是缺陷。两条都**没有改前/改后对照数据**，只作为下一轮补数据的候选。

### [堆内存] `withMeta` 每请求复制一次 `params` 并新建两个 `JsonObject`

- **现状**：`McpClient.withMeta`（`f_mcp/src/client/McpClient.cj:439-456`）对每次调用新建 3 个 `JsonObject`（`obj` / `meta` / `info`），并把 `params` 的全部字段逐个 `add` 复制一遍；`clientInfo` 的 `name` / `version` 与 `capabilities` 是不变的。
- **方案**：把 `info` 与 `meta` 的固定部分在 `McpClient` 构造期建成模板（`capabilities` 按引用共享，序列化时只读），每请求只 `obj.add(META, metaTemplate)`；`params` 若调用方保证不复用，可直接在入参对象上补 `_meta`（需文档说明会修改入参）。
- **预期**：每请求少 2 个短生命周期对象 + 一次字段拷贝；大 `params`（如 `arguments` 里带大对象）时省掉一次浅拷贝的哈希表扩容。
- **代价**：模板共享要求 `capabilities` 不被调用方并发修改（当前 `McpClientOptions.capabilities` 是公开可变 `var`，模板共享会把这层风险放大）；直接改入参会改变 API 语义。
- **验证**：`cjpm bench -O2`，同一 8 线程、10k 次 `callTool`（参数含 100 字段对象），对照 `getAllocatedHeapSize()` 与单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LimiterPool.sweep` / `ConcurrencyGate.sweep` 超容量时用「全表扫描找最旧」淘汰，最坏 O(n²)

- **现状**：`f_mcp/src/server/McpRateLimit.cj:186-204` 与 `:455-468` 在 `size > maxSize` 时每淘汰一个 key 就整表扫一遍找最小 `lastUsed`；`maxSize` 默认 10_000，`sweep` 每 256 次 `acquire` 触发一次（`:153-155`、`:402-404`）。
- **方案**：改成采样淘汰（随机/固定取 16 个候选取最旧，Redis 风格），或维护一个按 `lastUsed` 排序的近似 LRU 索引；只要保证「最终有界」，不要求精确最旧。
- **预期**：超容量窗口内从 O(n²) 降到 O(n·k)（k = 采样数）；稳态下 `sweep` 由全表 O(n) 降到只清 TTL 条目。
- **代价**：淘汰不再严格 LRU，可能提前淘汰刚用过的 key（对限流只是配额重置，可接受）；需要并发压力测试断言 `size <= maxSize`。
- **验证**：`cjprof record` 跑「10 万不同 caller、`perCallerRpm=60`」的压测，对照 `sweep` 自耗时占比与 P99 延迟；同时断言最终 `gate.size()`/`pool.size` 不超上限。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，只用于下一轮补数据；不计入模块统计，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sweep` 的全表扫描在「大量不同 caller」场景下成为限流路径热点 | `f_mcp/src/server/McpRateLimit.cj:178-205`、`:449-469` | 自耗时占比、`sweep` 调用频次、`limiters`/`counts` 平均 size | `cjprof record` 跑 10 万 caller / 30 分钟、`maxSize=10000`，看 `sweep` self time 与 size 分布 |
| 2 | stdio `send` 的「持锁串行」把并发吞吐压成 1，客户端并发调用收益为零 | `f_mcp/src/client/McpClient.cj:126-145` | 单请求 RTT、并发 1/2/4/8 下的 QPS 与 P99 | 本地起假 stdio 服务端（`McpStdio_test.cj` 的脚本可直接复用），`cjpm bench -O2` 跑 4 组并发度 |
| 3 | `McpModels` 的 `fromJson` 在 `tools/list` 大页（500 条）下分配量偏高（每条 1 个描述对象 + 1 个 `ArrayList` 拷贝） | `f_mcp/src/base/McpModels.cj:291-317` | 单次解析分配量与耗时、页大小分布 | 分段计时 + `getAllocatedHeapSize()`，100/500/2000 条三档、每档 1000 轮取中位数 |

## 文件覆盖

> 与 `{workdir}/files/f_mcp.part4.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mcp/src/base/McpModels.cj` | .cj | ✅ | 见发现 #9（三类 Page 同构）；`stringOf`/`optionalStringOf`/`boolOf`/`intOf`/`objectOf`/`nestedBool` 全仓搜过，仅在本包内被 `McpContent.cj` 与本文件使用，无死代码 |
| 2 | `f_mcp/src/base/McpModels_test.cj` | .cj | ✅ | 8 个用例覆盖 `ContentBlock` / `CallToolResult` / `McpCapabilities` / `DiscoverResult` / `PromptArgument` / `ResourceContent` / `PromptMessage` 往返，与实现一致；未见缺陷 |
| 3 | `f_mcp/src/base/McpProtocol.cj` | .cj | ✅ | 常量全部有引用（`METHOD_NOT_FOUND` 仅测试引用，属对外 `public`，按硬原则一不判死代码）；`isToolName` 字符集与 README:606 一致；`decodeCursor` 空串 → `Some(0)`、非法 → `None`、上限 1e7 与调用点 `McpServer.cj:844` 的「必须回 -32602」约定一致 |
| 4 | `f_mcp/src/client/McpClient.cj` | .cj | ✅ | 见发现 #1、#2、#3、#8、#12、#13、#15 |
| 5 | `f_mcp/src/client/McpClient_test.cj` | .cj | ✅ | 19 个用例；`RawMcpServer`/`FakeMcpRpc` 为测试替身，空 `close()` 不计 §3；并发协商用例断言 8 线程 × 2 次调用，与 `rpcCall` 的一次重试逻辑吻合；未见缺陷 |
| 6 | `f_mcp/src/client/McpStdio_test.cj` | .cj | ✅ | 4 个用例覆盖分帧、噪声/通知跳过、id 单调与 stale 忽略、读超时；`writeStdioScript` 用 `@`→`$` 全量替换（`:33`）只影响测试脚本，`/tmp` 路径限定 Linux，属测试环境假设，不单列 |
| 7 | `f_mcp/src/exports.cj` | .cj | ✅ | 5 条 `public import` 都是重导出（`@Mcp` 展开所需的 `lookup`/`BeanFactory`/`JsonValue`/`convert`/`ArrayList`/`TypeInfo`）；三包重导出由 `src/Mcp.cj` 完成（3 部分已核），与 README:18-22 一致，无缺项 |
| 8 | `f_mcp/src/macros/Mcp.cj` | .cj | ✅ | 见发现 #6 的生成点与 #11 的静默跳过点；`serverNameOf`/`annotationKinds`/`declaredName`/`generateFunction` 均有调用；tool 重名在展开期 `diagReport(ERROR)`，符合「同名注册启动失败」；同名重载函数只注册第一个（`processed` 去重，`:85`）且无诊断，属可接受约定，未单列 |
| 9 | `f_mcp/src/macros/imports.cj` | .cj | ✅ | `internal import std.collection.{ArrayList, HashSet}` 是 `Mcp.cj` 里 `HashSet`/`ArrayList` 的实际来源（`Mcp.cj` 自身未 import 集合），非死代码；`std.ast.*` 与 `f_macros.*` 两条与 `Mcp.cj:18-19` 重复（重导出语义，不影响正确性，仅冗余） |
| 10 | `f_mcp/src/server/McpAnnotations.cj` | .cj | ✅ | 4 个注解与 README:531 的字段表一一对应；`-1`/`0`/`>0` 语义在 `McpRegistry.mapLimit` 与 `LimiterPool`/`ConcurrencyGate` 两侧一致 |
| 11 | `f_mcp/src/server/McpConfig.cj` | .cj | ✅ | CSV/JSON 双解析、空段校验、上限 1e6 与 11 个用例吻合；`publicBaseUrl` 的 `while` 会把退化输入 `http://` 截成 `http:`（`:59-61`），属配置退化输入，未单列；`trustForwardedFor` 非法值抛错、非法 JSON 数字拒绝小数，均正确 |
| 12 | `f_mcp/src/server/McpConfig_test.cj` | .cj | ✅ | 17 个用例覆盖 CSV/JSON 等价、空段、负数/小数/超限、`publicBaseUrl` 三斜杠、`version` 缺省；与实现一致 |
| 13 | `f_mcp/src/server/McpController.cj` | .cj | ✅ | 见发现 #4（解码）、#5（无鉴权）、#16（缓存 server）；`parseSubscriptionId` 拒绝负数、`parseTopics` 显式空串 400 与注释一致 |
| 14 | `f_mcp/src/server/McpConvert.cj` | .cj | ✅ | 四组重载（tool/resource/prompt × 原样/`String`/`Unit`/`ToData`）语义清晰、无相互覆盖歧义；见发现 #6 的 `argument` 失败路径 |
| 15 | `f_mcp/src/server/McpHttp_test.cj` | .cj | ✅ | 8 个用例覆盖 429/Retry-After、`X-Forwarded-For` 信任开关、`Authorization` 哈希 caller、头/体版本校验顺序；`McpAnyPathDistributor.register` 空实现是接口替身，不计 §3；`mcpFreePort`（`:78-88`）先 bind→close→再 bind 有端口抢占窗口，属测试抖动风险，未单列 |
| 16 | `f_mcp/src/server/McpMacro_test.cj` | .cj | ✅ | 13 个用例覆盖 `@Mcp` 全链路（tool/resource/prompt、多 `@Mcp` 类累计、`structuredContent`、注解限流）；`helper(ctx: McpToolContext)` 无注解故不入注册，验证了「只注册带注解的 public 实例函数」 |
| 17 | `f_mcp/src/server/McpPrompt.cj` | .cj | ✅ | `listJson` 缓存字段被 `McpServer.cj:899-910` 使用（非死代码）；`build()` 校验名称字符集与 handler 必填，失败抛 `INTERNAL_ERROR`，合理 |
| 18 | `f_mcp/src/server/McpRateLimit.cj` | .cj | ✅ | 见发现 #7（sweep 竞态）、#10（`of`/`fromConfig` 重复）、#14（静默覆盖）、#15（关闭路径）；四个后端与 `RateLimitBackends.normalize` 的大小写/`-`/`_` 不敏感与 README:257 一致 |
| 19 | `f_mcp/src/server/McpRateLimit_test.cj` | .cj | ✅ | 11 个用例覆盖池有界/空闲回收（断言 `close()` 真被调用）、名字归一化、自定义后端注册与配置选中、四种算法、rpm=0 放行 |
| 20 | `f_mcp/src/server/McpRegistry.cj` | .cj | ✅ | 见发现 #6、#11、#16；`configure` 在锁内 `build()`、`server()` 懒建、`withContext` 补 uri/mimeType 均正确；`toolRateLimitOf`/`mapLimit` 的 `-1`→`None`、`0`→`Some(0)` 与 `RateLimitPolicy` 语义对齐 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1（并发丢响应）、#3（关闭阻塞）、#4（解码错）、#8（协议误判）；安全性：#5（`/sse` 无鉴权）。语言特性：`synchronized` 尾随 lambda 里的 `return` 只返回 lambda 值，`send`（`McpClient.cj:126-145`）与 `close`（`:149-155`）的写法都靠「lambda 值即函数值」成立，已核实（`cangjie_docs/docs/dev-guide/source_zh_cn/function/lambda.md:92`），非缺陷；`Option<T> <: DataFields` 已按 `f_data/src/base/OptionData.cj:18` 核实 |
| §1 死代码 | 0 | 机械过了一遍：`private`/`internal` 符号逐名全仓搜过（`stringOf` 等 6 个 JSON 辅助、`parseSubscriptionId`、`parseTopics`、`queryOf`、`decodeComponent`、`hexValue`、`LimiterPool`/`LimiterEntry`/`GateEntry`/`ResolvedRateLimit`/`RateVerdict`/`ConcurrencyLease`、`serverNameOf`/`expand`/`asFunc`/`shortName`/`annotationKinds`/`declaredName`/`generateFunction`）均有调用者；`ConcurrencyGate.tryAcquire:414` 的尾 `false` 在 `while (true)` 之后不可达，但是仓颉返回检查所需（不是兼容残留），不算兼容残留；`LimiterPool.size`/`sweepNow`、`ConcurrencyGate.size`/`sweepNow` 只被测试引用——`LimiterPool` 是 `internal` 类，按硬原则二本应判死代码，但仓内确有测试使用（§1「仅测试使用」只算可见性建议），故记为可见性建议不计数；`McpClient.versionRewrites`、`McpPrompt.listJson` 均有生产代码读取 |
| §2 重复逻辑 | 4 | #9（三类 Page + `ReadResourceResult`）、#10（`of`/`fromConfig`）、#11（三个 `get*Meta`）、#12（`rpcCall` 两个 catch）。另外已比对并排除：`McpConvert` 的 4 组重载（语义分支不同，非重复）、`LimiterPool`/`ConcurrencyGate` 的「TTL + 容量淘汰」（结构相似但 `close()` 语义与并发不变量不同，硬合并会破坏 `count` 不变量，只把「超限全表扫描」写进优化方案）、`McpModels` 的 `toJson` 与 `fromJson` 镜像（读写不同向）；`queryOf`/`decodeComponent` 对标 `stdx.URL` 的重复并入 #4 一并给建议，不重复计数 |
| §3 空实现 | 1 | #15（`close()` 吞异常、`UnlimitedRateLimitBackend.close()` 空 no-op 无注释）。测试替身（`FakeMcpRpc.close`、`AlwaysUnsupportedRpc.close`、`McpAnyPathDistributor.register`、`ObservableLimiter.exec`）属接口实现，不计；本部分无 `TODO`/`FIXME`/`UnsupportedException` 占位 |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构：`decodeComponent`/`hexValue`/`queryOf`/`isToolName`/`fromJson` 全是单层循环或线性扫描；宏展开侧 `asFunc`/`annotationKinds`/`declaredName` 的递归只沿 `MacroExpandDecl.macroInputDecl` 下降，深度由注解嵌套层数（作者可控、常量级）决定 |
| §5 OOM | 1 | #2（`lines` 无界 + O(n) 头删）。其余容器均有界：`LimiterPool`/`ConcurrencyGate` `maxSize` 默认 10_000、TTL 10 min；`ToolPage` 等按服务端页大小（`pageSize`）物化，上限在服务端 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 `cjprof` / `cjpm bench` 数据，热点不成立；三个疑点写入「待验证假设」#1-#3（均给了工具、输入规模、采法） |
| §6.2 大粒度锁 | 0 | `McpRegistry` 的 `Mutex` 只保护启动期注册与 `built` 快照，临界区内 `builder.build()` 不在请求主路径（`configure` 文档限定启动阶段）；stdio `send` 的临界区含 `cond.wait` 但那是协议要求的单管道读，不是「锁里做 I/O」——I/O 已移到 `writeMutex` 与独立读线程 |
| §6.3 并发串行 | 0 | 本部分只有 `spawn` 两个读线程（`McpClient.cj:104-109`），无「spawn 后立刻 get」；stdio 请求串行是单管道语义（已作为 #1 的替代修法提及） |
| §6.4 低效算法 | 1 | #2 的 `remove(at: 0)`。`sweep` 的超限全表扫描只在优化方案与假设 #1 里，不重复计入发现（无测量数据） |
| §7 降堆内存方案 | 1 | 「优化可行性方案」的 `withMeta` 模板化，证据状态 `无基线（待验证，不进 tasks）` |
| §8 降 CPU 方案 | 1 | 「优化可行性方案」的采样淘汰，证据状态 `无基线（待验证，不进 tasks）` |
| §9 local mode 可行性 | 0 | 候选只有 `decodeComponent`/`withMeta` 的短命对象，但前者在请求路径上量级极小（查询串 < 100 B），后者返回的 `JsonObject` 会逃逸到 `JsonRpcClient.requestBody` 并序列化成字节（跨函数返回，逃逸检查不通过）；无峰值内存对照数据，不成立 |
| §11 现有代码的 BUG（存量） | 16 | 本部分 16 条发现全部为存量（快照模式无基线）。已核对的边界/空值/错误处理：`decodeCursor`（空串/非法/超上限）、`parseSubscriptionId`（负数/非数）、`parseTopics`（空串/全空段）、`rateLimit`（空段/负数/小数/超限/未知键）、`publicBaseUrl`（全空/三斜杠）、`listAllTools`（页上限/空页/重复游标）、`callToolAuto`（`maxRounds=0` 立即抛错，按 `maxRounds>0` 的判定属预期）、`getOrThrow` 竞态（`LimiterPool:151` 有窗口但需 `sweep` 恰好淘汰刚插入项，概率极低，并入 #7 的同一类不再单列） |
| §12 并发安全与锁粒度 | 3 | #1（stdio 响应被别的线程消费）、#3（`close` 与 `send` 抢锁）、#7（gate 清理竞态）。共享路径已列清：`McpClient` 的 `versionMutex`/`protocolVersion`/`versionRewrites` 均在锁内写、`options` 只读（`McpClientOptions` 可外部改写属使用约束，已在「优化可行性方案 · 堆内存」的代价里点出，不单列）；`McpRegistry.built` 读写都在同一 `Mutex` 内 |
| §14 功能完备性与 README 覆盖 | 2 | #6（`required:false` 未真正实现，承诺源 README:531 + `McpAnnotations.cj:23`，缺失证据 = 调用期必然 -32602）、#16（`configure`「立即生效」在 HTTP 路径不成立，承诺源 README:547-549）。README 逐符号对照属 1 部分文件，本部分只核对了与本部分符号相关的段落（`exports.cj`↔README:18-22、`RateLimitBackends`↔README:257、`isToolName`↔README:606），无其它遗漏 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_mcp.part4.txt` 逐行一致，无缺读；本部分不含 `.md`，§13 文档一致性由 1-3 部分承担 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分覆盖 `f_mcp` 的协议常量与模型、客户端（HTTP/stdio 共用消息层）、宏展开入口、注解、配置、HTTP 入口、参数/返回值转换、prompt 与限流注册表，共 4777 行。整体分层是清楚的：`base` 只放协议模型与常量，`client` 把消息层完全委托给 `f_jsonrpc`（`McpRpc` 接缝只有 20 行），`server` 的注册/构建/限流三段职责没有互相穿透；`exports.cj` + `src/Mcp.cj` 的重导出与 README 的门面包说明一致；限流的多维合并（`RateLimitPolicy.overlay` → `ToolRateLimit` → `ResolvedRateLimit`）与「并发拒绝不消耗令牌」的语义在代码里是自洽的。

风险主要有两处，都集中在「会话/连接生命周期」上：**一是 stdio 客户端把「一次只有一个等待者」当成前提，但 `JsonRpcClient.call` 无锁、`McpClient` 又用 `Mutex` 保护版本号暗示了多线程可用**，于是出现 #1（别人的响应被当 stale 丢掉，随机 30s 超时）与 #3（`close()` 无法取消在途请求），这两条一起构成「客户端在并发下不可靠」的阻塞项，建议优先修——修法不复杂（按 id 建待取表 + 关闭走独立标志位）。**二是 `/mcp/sse` 这条旁路完全没有调用方校验**（#5），订阅 id 可枚举、订阅池可被匿名占满，属需要按部署模型定级的安全面；它与 #4 的乱码解码同处 `McpController`，一并改成复用 `caller` 派生与 `stdx.URL` 解析即可收敛。

#2（`lines` 无界）与 #7（并发闸门清理竞态）是典型的「长期运行才暴露」问题，量级已经按通知速率算过，可排期处理。其余 9 条轻微项（Page 模型/后端查表/反射查注解/两个 catch 分支的重复、`listAllTools` 文案、同名注册静默覆盖、关闭路径吞异常、控制器缓存 server）都不影响功能正确性，可随下一次收口一起做。

本部分无严重项、无栈溢出、无死锁；`§1 死代码` 与 `§2 重复逻辑` 均已机械过一遍并给出结论（0 / 4）。存量缺陷 16 条（本部分全部为存量），是否纳入修复待用户决定。

**范围外提示**：`f_jsonrpc/src/client/JsonRpcClient.cj:82-95` 的 `call` 对 `transport.send` 无任何串行化，这是 #1 能够发生的前提；该文件属 `f_jsonrpc` 模块，仅记录一句，不计入本轮统计。
