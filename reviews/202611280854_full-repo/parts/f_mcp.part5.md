# f_mcp 模块审查报告 —— 模块第 5/5 部分

- **审查日期**：2026-11-28
- **模块路径**：`f_mcp/src/server`（本部分 10 个源文件；全模块按 5 个子轮拆分，本文件只覆盖第 5 部分）
- **基线**：工作区快照（`sts/1.3.x`，master 同提交 `120fd2542`；`git status` 无源码改动，`git blame` 命中 2026-10-24 / 10-25 提交）
- **审查重点**：MCP 协议正确性、会话与资源生命周期、并发安全、死代码、重复逻辑（并扫全部通用 / 专项维度）
- **报告版本**：v1（本部分独立成文，由主 Agent 合并为 `docs/review/2026-11-28/f_mcp.md`）

> 说明：本部分的「文件覆盖」「覆盖自检」「模块统计」仅统计本部分 10 个文件，不代表整个 f_mcp 模块。

## 发现

### [严重][存量] #1 并发维度显式配 `0`（文档语义“不限制”）被当成 `limit=0` 闸门，工具 100% 被拒

- **位置**：`f_mcp/src/server/McpServer.cj:1047-1059`（`acquireConcurrency`）、`f_mcp/src/server/McpServer.cj:991-1001`（`resolveLimit`）
- **来源**：存量（`git blame` `McpServer.cj:1041-1061` → `113bc448b3`，2026-10-25；`git status` 无源码改动）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（接线缺失）；契约源 `f_mcp/README.md:131`、`f_mcp/README.md:528`（注解数值 `-1` 继承 / `0` 不限制 / `>0` 限额）、`f_mcp/doc/spec/fix-jsonrpc-mcp-review-findings/specs/mcp-guardrails/spec.md:20-26`
- **证据**：静态确定 —— `McpRegistry.cj:235-241` 的 `mapLimit(0)` 返回 `Some(0)`；`resolveLimit` 原样传给 `acquireConcurrency`；`McpRateLimit.cj:389-393` 明确 `limit <= 0` 返回 `false` 表示“未占槽”，而 `acquireConcurrency` 把 `false` 一律当成“已达上限”
- **描述**：`@McpToolMeta[maxConcurrency: 0]`（文档语义“不限制”）→ `toolConcurrency = Some(0)` → `gates.tryAcquire('conc:t:<tool>', 0)` 返回 `false` → 返回 `concurrency_tool` 拒绝，该工具每次调用都拿 `-32050`，完全不可用。`perCallerConcurrency: 0` 与 `RateLimitPolicy(maxConcurrency: Some(0))`（含 `Builder.rateLimit`）走同一路径。配置路径 `mcp_rateLimit` 已在 `McpConfig.cj:131-152` 把 `0` 归一成 `None`，所以只有“注解 / Builder”两条路径触发——两条都是公开契约。现有用例 `McpRateLimit_test`/`McpResultStore_test:210-217` 只测闸门本身（`tryAcquire(k, 0) == false` 且计数不变），没有覆盖 `McpServer` 把 `false` 解释成拒绝这一步。
- **建议**：在 `resolveLimit` 出口统一归一：`Some(v) where v <= 0 → None`（与 `McpConfig.parseValue` 同语义），或在 `acquireConcurrency` 里先判 `max <= 0` 跳过闸门；补一条 `@McpToolMeta[maxConcurrency: 0]` 的 `tools/call` 回归用例（期望成功且闸门计数不变）。

### [一般][存量] #2 `maxResultBytes <= 0` 未校验：结果被静默截成空串

- **位置**：`f_mcp/src/server/McpTool.cj:115-118`（`maxResultBytes(bytes:)`）；`f_mcp/src/server/McpServer.cj:1096-1101`、`:1123-1126`、`:1143-1146`
- **来源**：存量（`git blame` `McpTool.cj:115-118`、`McpServer.cj:1095-1101` → `f29c8cc9de`，2026-10-24）
- **判据**：review-checklist §11（缺少边界校验）、§3（静默返回空值）
- **证据**：静态确定 —— 无任何校验；`limit <= 0` 时 `truncateUtf8` 的第一条分支直接 `return ''`
- **描述**：`maxResultBytes(0)` 或负数会让 `json.size <= limit` 恒假，走 `truncated()`，`truncateUtf8(json, limit)` 对 `limit <= 0` 返回 `''`，客户端拿到“空 text + `data.truncated=true`”，服务端只留一条 WARN。按本项目其它数值配置“`0` = 不限制”的习惯（README:131、`McpConfig.parseValue`），`maxResultBytes(0)` 很可能被当成“不限”，实际是“结果全空”。
- **建议**：`McpToolBuilder.build()` 校验 `maxResultBytes > 0`（否则 `INTERNAL_ERROR`），或把 `<= 0` 视为默认值并写进 README；`truncated()` 增加 `limit <= 0` 的错误分支而不是静默空串。

### [一般][存量] #3 大结果链接的 token 用每次新建的 `Random()` 生成，且同 token 静默覆盖、读取不绑定调用方

- **位置**：`f_mcp/src/server/McpResultStore.cj:241-244`（`newToken`）、`:113-141`（`put(token, content)` 覆盖）、`f_mcp/src/server/McpServer.cj:1105-1108`（生成并入库）、`:665-670`（按 token 读）
- **来源**：存量（`git blame` `McpResultStore.cj:241-244` → `f29c8cc9de`，2026-10-24）
- **判据**：review-checklist §12.1（跨线程资源标识）、§11（语义与安全）；`std.random.Random` 默认构造种子来源见 `cangjie_runtime/stdlib/libs/std/random/random.cj:16-30`（`getSeed()` = `CJ_RANDOM_NanoNow()`）
- **证据**：静态确定（token 是唯一凭据、`put` 遇到同 token 直接换内容、`resources/read` 不校验 callerId）+ 待确认（同一纳秒内并发 `Random()` 是否会取到同一种子，取决于目标平台时钟分辨率）
- **描述**：`${base}/mcp/tool-results/{token}` 是访问大结果的**唯一**凭据，而 token 由“每次调用现场 `new Random()`（纳秒种子）+ 两个 `nextUInt64()` 十进制拼接”得到：同 tick 并发会得到相同序列；可变长十进制拼接本身不唯一（`"1"+"23"` 与 `"12"+"3"` 同形），有效熵低于 128 bit。`put` 命中已有 token 时只替换内容、不报错，于是后写入者会“接管”前一个链接；任何拿到链接的调用方都能读，没有 caller 绑定。另：`Random()` 每次构造要初始化 312×8B 的 MT 状态，只为取两个数（见优化方案）。
- **建议**：进程级 CSPRNG 单例 + 单调计数器 / 线程 id 混入，十六进制定宽编码；`put` 发现 token 已存在时重试新 token 而不是覆盖；如坚持 bearer link 语义，在 README 明确“链接即凭据、10 分钟有效”，否则在 `ResourceContent` 上记录 callerId 并在 `resources/read` 校验。

### [一般][存量] #4 订阅者回收只在下一次 `subscribe`/`attach` 时发生，没有定时 prune

- **位置**：`f_mcp/src/server/McpServer.cj:230-235`（`prune`）、`:251-253`（`pruneLocked`）、`:141-145`（`subscribe` 调 `pruneLocked`）、`:194-208`（`attach` 调 `pruneLocked`）
- **来源**：存量（`git blame` 同上，2026-10-24/25）
- **判据**：review-checklist §11（资源生命周期不对称）、§5（长期持有）
- **证据**：静态确定 —— 全仓 `grep "\.prune("` 只命中 `McpServer_test.cj`（5 处）；生产路径只有 `subscribeLocked`/`attach` 内部调用 `pruneLocked`
- **描述**：SSE 断流（`detach`，grace 60s）或 `subscriptions/listen` 后从不连接的订阅者，只能等下一次 `subscribe`/`attach` 才被清理。若服务转入空闲，这些订阅者连同各自最多 `queueCapacity=256` 条通知一起常驻（上限 1024 订阅者 × 256 条）；有界但不会自愈，`size`/内存要等下一次入站请求才回落。`McpServer.close()` 在生产代码里也没有调用方（只有 `testServerCloseClearsHub`），所以“进程内不再有流量”这一状态没有任何回收路径。
- **建议**：用 `f_ticktock` 按 `detachedTtl/2` 周期调 `hub().prune()`（注册在 `McpRegistry` 启动钩子），或在 `publish` 里按窗口限频顺带 prune。

### [一般][存量] #5 大结果限额在完整序列化之后才判定：序列化本身无法被拒绝

- **位置**：`f_mcp/src/server/McpServer.cj:1095-1101`（`applyLargeResult`）
- **来源**：存量（`git blame` `McpServer.cj:1095-1101` → `f29c8cc9de` / `39fcc879f8`，2026-10-24/25）
- **判据**：review-checklist §5（一次性物化）、§6.4（同一输入重复处理）
- **证据**：静态确定 —— 顺序固定为 `toJson()` → `toString()` → 比 `limit`
- **描述**：一个返回 200 MB 文本的工具，即使 `maxResultBytes = 1 MiB`，也会先生成完整 JSON 树与完整 JSON 字符串（峰值 ≈ 结果 + 字符串，约 2×），之后才截断到 1 MiB —— “限额”挡不住这次分配，只有 GC 能兜底。`maxResultBytes` 配得越大，`truncateUtf8` 里的 `StringBuilder(limit)` 还会按上限一次性预分配（`core_package_classes.md:2622-2629` 确认 `init(capacity)` 是预分配），进一步抬高峰值。
- **建议**：先用内容块估算字节（`text.size` + `blob.size` + 固定结构开销）做一道前置闸门，明显超限直接走 `truncated()`；仅在“估算接近 limit”时才做精确序列化。同时对 `maxResultBytes` 设上限校验。

### [轻微][存量] #6 `ToolResultStore` 的条数上限是 check-then-act，`close()` 与并发 `put` 还有竞态

- **位置**：`f_mcp/src/server/McpResultStore.cj:113-123`（count 判断与 `entries.add` 非原子）、`:183-189`（`close`）
- **来源**：存量（`git blame` `McpResultStore.cj` → `f29c8cc9de`，2026-10-24）
- **判据**：review-checklist §12.1（检查-然后-写入）、§11（资源释放不对称）
- **证据**：静态确定 —— `count.load()` 与 `entries.add` 之间没有保留动作；`close()` 先逐条删除再 `budget.release(budget.value())`
- **描述**：(a) 两个线程同时看到 `count == maxEntries-1` 都会通过检查，条数可短暂超过 `maxEntries`（字节预算由 CAS 保护，内存仍有界，故按轻微）。(b) `close()` 与并发 `put` 交错时，`budget.release(budget.value())` 会把别人刚 `reserve` 的字节一起减掉，`usedBytes` 可为负、后续预算变宽松；close 之后写入的条目也不会被清掉。
- **建议**：条数改成与 `ByteBudget` 同样的“CAS 预留 + 失败回退”；`close()` 先置 `closed` 标志，`put` 见到即拒绝，再清表并 `budget.release(used)` 用残留值一次性归零。

### [轻微][存量] #7 `withoutPort` 对无方括号 IPv6 返回 `::`，把不同调用方合并成同一个限流 key

- **位置**：`f_mcp/src/server/McpServer.cj:944-956`
- **来源**：存量（`git blame` `McpServer.cj` → `113bc448b3`，2026-10-25）
- **判据**：review-checklist §11（边界）
- **证据**：待确认 —— 需要确认 `http.request.remoteAddr` 对 IPv6 是否总是带方括号（填充点在 f_jsonrpc / f_http，不在本部分）
- **描述**：带括号走 `indexOf(']')` 分支是对的；无括号的 `::1` 落到 `lastIndexOf(':')` → 返回 `::`。所有无括号 IPv6 调用方共用 `c:::...` 这个 key，per-caller 限流变成“全体共享一份 rpm”，也会让 `callerId` 暴露给工具方失真。
- **建议**：先判 `]`，再判 `text.indexOf(':') != text.lastIndexOf(':')` 时视为“无端口的 IPv6”原样返回；并给 `testCallerAddressDropsPort` 补 `::1` / `2001:db8::1` 用例。

### [轻微][存量] #8 `listJson` 惰性缓存无同步，且把可变 `JsonObject` 跨请求共享

- **位置**：`f_mcp/src/server/McpServer.cj:865-877`（`toolJson`）、`:879-896`（`resourceJson`）、`:898-913`（`promptJson`）；字段 `McpTool.cj:51`、`McpResource.cj:38`
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §12.1（惰性初始化 / 发布逸出）、§14（设计合理性）
- **证据**：静态确定 —— 字段是无同步的普通 `var`，读写都在请求线程；`McpServer_test.cj:508-528` 把“外部修改会留在缓存里”固化成断言
- **描述**：并发 `tools/list` 会各自判定 `None` 并重复构建（浪费可接受，引用发布本身无原子/锁）；更实际的是返回的是**同一个可变 `JsonObject`**：任何下游往条目里加字段（中间件补 `_meta`、测试、未来的序列化钩子）都会永久污染后续所有响应，且这类污染跨调用方可见。
- **建议**：注册期一次性构建（`McpServer` 构造时填充），请求期只读；或缓存“不可变表示”（预序列化片段 / 冻结标记），对外返回 `clone()`。

### [轻微][存量] #9 三份插入排序、三份分页循环、`isResultLink`/`tokenOf` 重复拼前缀（§2 重复逻辑）

- **位置**：`f_mcp/src/server/McpServer.cj:482-516`（`sortTools`/`sortResources`/`sortPrompts`）、`:582-600` / `:641-659` / `:686-704`（三个列表分页）、`:1173-1190`（`isResultLink` + `tokenOf`）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §2（只改字段名 / 只改类型名的同构复制）
- **证据**：静态确定 —— 逐行比对：排序三份只有比较字段（`name`/`uri`）不同；分页三份只有结果键（`tools`/`resources`/`prompts`）与取数数组不同；`tokenOf` 重复了 `isResultLink` 的前缀拼接
- **描述**：语义相同、语法近似。游标语义、`nextCursor` 判定、排序稳定性任何一处调整都要改 3 份，已经具备“改一处漏两处”的漂移条件（例如给某类列表加 `_meta` 时）。
- **建议**：抽 `paginate<T>(items, pageSize, offset, toJson)` + `(a, b) -> Bool` 比较器（`sortBy`）；`isResultLink` 改为 `resultToken(uri): ?String` 单次判定，`readResource` 只调它。

### [轻微][存量] #10 `McpSubscriber.queued` 是包内 prop，全仓零引用

- **位置**：`f_mcp/src/server/McpServer.cj:104-110`
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §1（`internal` 符号在本包及子包内无引用即死代码）
- **证据**：静态确定 —— `grep -rn "queued" f_mcp/src` 仅命中定义处；`grep -rn "\.queued"` 全仓 0 命中
- **描述**：属于“诊断字段写了不用”。`droppedCount` 是 public、有测试；`queued` 既非 public 也无调用方。
- **建议**：删除，或并入诊断 API（public + 用例）后再保留。

### [轻微][存量] #11 `discover` 未使用局部变量、`callTool` 不可达初值、测试未使用 import

- **位置**：`f_mcp/src/server/McpServer.cj:550`（`let request = requireMeta(...)` 之后再未引用）、`:628`（`var callResult = CallToolResult.text('')` 初值在两个出口都不可达）、`f_mcp/src/server/McpServer_test.cj:25`（`import fountain::f_jsonrpc.base.*`）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §1（读了不用 / 未使用 import / 死赋值）
- **证据**：静态确定 —— `discover` 只用到 `requireMeta` 的副作用（校验 + 剥 `_meta`）；`callResult` 成功路径被 handler 覆盖、异常路径在 `finally` 后直接抛出
- **描述**：三处都是“看起来像用了”的残留，读代码时需要额外确认它们没有语义。
- **建议**：`let _ = requireMeta(ctx, params)`；把 `callResult` 的赋值移进 `try` 内改成 `let`；删除未使用的 import。

### [轻微][存量] #12 `prompts/get` 与 `subscriptions/listen` 对错误类型的入参静默降级

- **位置**：`f_mcp/src/server/McpServer.cj:711-714`（`arguments` 非 object 当空对象）、`:736-744`（`topics` 非数组 / 元素非字符串静默跳过）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §11（契约与实现不符）、§3（兜底吞掉错误）
- **证据**：静态确定 —— 两个 `match` 的 `_` 分支都直接产出空集合，没有 `INVALID_PARAMS`
- **描述**：`prompts/get` 传 `"arguments": "x"` 不报 `-32602`，按“无参数”继续（无可选参数时直接成功，需要必填参数时报 `missing prompt argument`，错误码对但原因误导）。`subscriptions/listen` 传 `"topics": "tools/list_changed"` 会静默变成“订阅全部”，与 README:344“缺省 = 订阅全部”的语义反转风险叠加。同文件 `callTool` 对 `arguments` 的处理是正确的（非 object 直接 `INVALID_PARAMS`），两处不一致。
- **建议**：非 object / 非数组一律 `INVALID_PARAMS`，与 `callTool` 保持一致；`topics` 元素非字符串也报错而不是丢弃。

### [轻微][存量] #13 `checkSchema` 递归无深度上限（构建期栈溢出）

- **位置**：`f_mcp/src/server/McpTool.cj:141-162`（调用点 `:125`）
- **来源**：存量（`git blame` `McpTool.cj` → `f29c8cc9de`，2026-10-24）
- **判据**：review-checklist §4（无界递归：深度由输入结构决定）
- **证据**：静态确定 —— 只按 JSON 结构下降，无深度计数、无访问集合
- **描述**：`inputSchemaFromFile` 读入的 schema 嵌套多深，`checkSchema` 就递归多深；同时每层都拼 `path` 字符串，深度 d 时总分配 O(d²)。触发在构建期（服务启动），表现为栈溢出而不是“schema 太深”的明确错误。
- **建议**：改显式栈迭代 + 深度上限（如 64），超限抛 `INTERNAL_ERROR` 并带上路径；`path` 只在报错时拼。

### [轻微][存量] #14 `McpSseStream.closed` 跨线程无同步，`close()` 不能唤醒阻塞中的 `take`；`McpServer.close()` 不阻止后续请求

- **位置**：`f_mcp/src/server/McpSse.cj:33-37`、`:55-72`、`:81-86`、`:101-105`；`f_mcp/src/server/McpServer.cj:439-444`
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §12.1（可见性 / 异步语义）、§11（契约）
- **证据**：待确认 —— 需要确认 f_http 关闭响应时是否在另一个线程调用 `InputStream.close()`（`read` 此刻阻塞在 `Condition.wait(15s)`）
- **描述**：`closed` 是普通 `Bool`，`close()` 只置位 + `detach`，不会 `notifyAll`；跨线程关闭时读端最长 15s 后才看到 EOF，期间可见性也没有保证（可能再发一条事件）。`McpServer.close()` 只是清空 `resultStore`/`gates`/`backend`/`hub`，没有 closed 标志，之后仍可正常服务（会重新往已清空的池与表里写，`gates` 计数也从 0 重新开始）。
- **建议**：`closed` 改为 `AtomicBool`（或放进 subscriber 的 `mutex`），`close()` 里 `signal.notifyAll()`；`McpServer` 增加 `closed` 标志，close 之后的方法直接返回 `OVERLOADED`/`INTERNAL_ERROR`，并把 `close()` 接进 `McpRegistry` 的关停钩子。

### [轻微][存量] #15 测试侧：同一语义三份实现（其中一份 O(n²)）、服务实例不 close、全局注册表互相影响

- **位置**：`f_mcp/src/server/McpServer_test.cj:71-85`（`repeatText` 用 `StringBuilder`，`bigText` 用 `text += 'x'` 累加）、`f_mcp/src/server/TruncateUtf8_test.cj:26-32`（第三份 `repeatText`）、`f_mcp/src/server/McpServer_test.cj:109-126`（`server()` 无 close）、`f_mcp/src/server/McpRegistry_test.cj:49-66`（直接改全局 `McpRegistry`）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §2（近似重复 + 实现漂移）、§11（测试资源不对称）
- **证据**：静态确定 —— `bigText(1_048_576)` 做 100 万次字符串拼接；`grep "srv.close()"` 在 `McpServer_test.cj` 只有 1 处
- **描述**：`bigText` 与 `repeatText` 语义相同（重复 n 次）而复杂度不同（O(n²) vs O(n)），大用例里白白制造 GC 压力；每个 `toolServer()`/`server()` 用例都不 close，`RateLimitBackend` 的 limiter 池条目（`leaking-bucket`/`sliding-window` 后端每条目还带一个 `Timer`，见 `f_concurrent/src/LeakingBucketRateLimiter.cj:42-61`）与 result store 在测试进程内累积；`McpRegistry_test` 依赖“先 build 再断言不存在”的执行顺序，用例并行或换序会互相干扰。
- **建议**：测试辅助收敛成一处 `repeat(text, n)`（StringBuilder）；用例统一 `try { ... } finally { srv.close() }`；registry 用例前后显式 reset，或用独立 builder 断言而不动全局。

## 优化可行性方案

### [CPU] 小结果路径免掉“为量字节而全量序列化”

- **现状**：每次 `tools/call` 都在 `applyLargeResult`（`McpServer.cj:1097-1101`）里 `result.toJson()` + `encoded.toString()` 求出字节数；小结果（绝大多数）只用到 `json.size`，这份字符串随即丢弃，随后传输层再对同一个 `JsonValue` 序列化一次（`f_jsonrpc` 的 HTTP 处理器写 `value.toString()`）。即每次调用 2 次 O(size) 序列化、1 份 size 字节临时串。
- **方案**：先按 content 块估算（`text.size` + `blob.size` + 结构开销），明显低于 `limit` 直接返回 `encoded`；只在“估算接近上限”时才精确 `toString()`。
- **预期**：省一次 O(size) 序列化与一份临时串；小结果路径的序列化次数 2 → 1（收益随结果大小线性增长，占比需实测）。
- **代价**：估算与精确值有偏差，必须保留精确回退路径，逻辑复杂度上升；估算函数要跟着 `ContentBlock` 演进维护。
- **验证**：`cjprof record` 跑 1 MiB 结果 10k 次 `tools/call`，对比序列化 self time 与分配量；同 SDK、同机器、`-O2`，取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 结果存储的过期条目没有后台回收

- **现状**：`ToolResultStore` 上限 256 条 / 256 MiB / TTL 10 分钟（`McpResultStore.cj:27-31`），过期只在 `get`、`sweepIfDue`（put 满额时，限频 1 次/秒）触发。空闲期过期条目连同其 `text` 一直驻留，最坏 256 MiB。
- **方案**：用 `f_ticktock` 每 `ttlMillis/2` 调 `store.sweep()`（或由 `McpRegistry` 注册周期任务），`close()` 时注销。
- **预期**：空闲期 `usedBytes` 在 TTL 后回落到 0，常驻内存从“最多 256 MiB 过期数据”变为“<= 半个 TTL 内写入的数据”。
- **代价**：周期全表扫描 O(n)，n <= 1024（`maxEntries` 的自适应上限），可忽略；多一个定时器生命周期要管。
- **验证**：写入 256 条各 1 MiB 后停止流量，每 1 分钟采 `usedBytes` / `getAllocatedHeapSize()` / RSS，看 20 分钟内是否回落并稳定。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个 token 都新建 `Random()`（312×8B MT 状态 + 初始化循环）

- **现状**：`newToken()`（`McpResultStore.cj:241-244`）每次 `Random()` 都 `Array<UInt64>(312)` + `initialMtArray`（`cangjie_runtime/stdlib/libs/std/random/random.cj:64-76`），只为取两个 `UInt64`；每个超限结果 ≈ 2.5 KiB 额外分配与 312 轮初始化。
- **方案**：进程级随机源（单个 `Random` + `Mutex`，或每线程一份）叠加 `AtomicInt64` 计数器 / 线程 id 混入；输出改十六进制定宽，顺带解决十进制拼接不唯一的问题。
- **预期**：每 token 少 ~2.5 KiB 分配与一次 312 轮初始化；超限结果 10k 次 ≈ 25 MiB 分配量下降（按 1 token/次估算）。
- **代价**：单例引入锁（可用每线程实例规避）；token 生成逻辑要加并发用例。
- **验证**：分配计数（同 `TruncateUtf8_test` 的 `measureCall` 手法）+ 10k 次超限 `tools/call` 的 `getAllocatedHeapSize()` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sha256Hex` 每请求用 64 次 `hex +=` 拼串 + `toArray()`，在带 `Authorization` 的高 QPS 下占可观 CPU | `f_mcp/src/server/McpServer.cj:958-968` | 该函数 self time 占比 | `cjprof record` 跑 10k 次带 `Authorization` 的 `tools/call`，看 `sha256Hex`/`toString` 占比 |
| 2 | 队列满时 `queue.remove(at: 0)` 的 O(n) 搬移在持续过载下成为发布方热点 | `f_mcp/src/server/McpServer.cj:54-63` | 丢包率、单次 `offer` 耗时 | 压测 `queueCapacity=256` 持续 `publish`，埋点统计 `offer` P99 与 `droppedCount` |
| 3 | 结果双重序列化（量字节 + 传输）占 `tools/call` 端到端的时间比例 | `f_mcp/src/server/McpServer.cj:1097-1101` | 序列化 self time 占比 | `cjprof` 跑 1 MiB 结果 10k 次，对比“直接返回”与“先量字节”两版 |
| 4 | `McpSseStream.read` 的 `pending[off..off+n]` 切片赋值每次 read 多一次拷贝，在多订阅者下放大分配 | `f_mcp/src/server/McpSse.cj:55-72` | 每次 read 的分配字节数 | 分配计数 + 50 条 SSE 连接、1k 条通知/分钟压测 |
| 5 | `ToolResultStore.evaluate` 的窗口锁在大量并发写入时会有排队，但窗口 5 分钟一次，影响可忽略 | `f_mcp/src/server/McpResultStore.cj:262-329` | 锁等待时长 | 线程状态采样（BLOCKED/WAITING）+ `windowLockCount` 对照 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_mcp.part5.txt` 一行对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mcp/src/server/McpRegistry_test.cj` | .cj | ✅ | 全局注册表用例，见 §2/§11 测试隔离问题 |
| 2 | `f_mcp/src/server/McpResource.cj` | .cj | ✅ | URI 校验与 `listJson` 缓存，见发现 #8 |
| 3 | `f_mcp/src/server/McpResultStore.cj` | .cj | ✅ | 配额 / TTL / 自适应调容，见发现 #3、#6 |
| 4 | `f_mcp/src/server/McpResultStore_test.cj` | .cj | ✅ | 覆盖条数/字节/TTL/自适应/闸门；未覆盖 `McpServer` 的 `0` 语义 |
| 5 | `f_mcp/src/server/McpServer.cj` | .cj | ✅ | 方法表、分页、限流、订阅、大结果，见发现 #1、#4、#5、#9、#10、#11、#12、#14 |
| 6 | `f_mcp/src/server/McpServer_test.cj` | .cj | ✅ | 协议主路径用例齐全；测试辅助重复，见发现 #15 |
| 7 | `f_mcp/src/server/McpSse.cj` | .cj | ✅ | SSE 流；心跳/30 分钟上限与 README 一致，见发现 #14 |
| 8 | `f_mcp/src/server/McpSse_test.cj` | .cj | ✅ | 只覆盖 `poll()` 路径，`read`/心跳/到点未测（测试覆盖缺口，不计问题） |
| 9 | `f_mcp/src/server/McpTool.cj` | .cj | ✅ | 工具构建与 schema 校验，见发现 #2、#13 |
| 10 | `f_mcp/src/server/TruncateUtf8_test.cj` | .cj | ✅ | 等价性 + 分配基准（`F_MCP_BENCH` 门控），见发现 #15 |

合计：`.cj` 10 个 / `.md` 0 个 / 共 10 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1/#2/#7；设计 #8/#9；可读性 #11；安全 #3/#12 |
| §1 死代码 | 2 | 已逐个 `private`/`internal` 符号在本包及子包内搜引用（`resolved`、`sweepIfDue`、`drainLocked`、`sha256Hex`、`maxOf` 等均有调用者）；命中 `queued`（#10）与未使用局部量/import（#11）。对外可达的 `public`（`unsubscribe`、`resultStoreRef`、`put(content)`、`sweep()`）仓内无引用或仅测试引用，按硬原则一只记信息、不判死代码 |
| §2 重复逻辑 | 2 | 已按「输入→输出→副作用」摘要比对本部分全部函数体（同文件逐对、跨文件按相同前缀/键名/字面量搜索）：命中排序/分页/前缀三组同构复制（#9）与测试侧 `repeatText`/`bigText`（#15）；`resolveLimit`/`checkLimits`/`acquireConcurrency` 语义不同，不算重复 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`；`case _ => ()` 仅出现在 `mimeType` 可选分支（#12 另计静默降级）；`catch (_: Exception)` 只在本部分之外的 `McpProtocol.decodeCursor` |
| §4 栈溢出 | 1 | `checkSchema` 按 schema 嵌套递归、无深度上限（#13）；其余递归仅 `JsonValue` 内部（标准库） |
| §5 OOM | 1 | 结果限额后置于完整序列化之后（#5）；`checkSchema` 深层 `path` 拼接的 O(d²) 分配同源于 #13 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，序列化、`sha256Hex`、SSE 拷贝均只进「待验证假设」，不作结论 |
| §6.2 大粒度锁 | 0 | `SubscriptionHub.mutex` 内只做数组遍历与快照（`publish` 入队移到锁外）；`ToolResultStore.windowMutex` 内只做统计与一次 `store`，格式化与日志已在锁外，5 分钟一次，未构成热点 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`、无批大小 1 的循环；限流闸门是 CAS 不是串行队列 |
| §6.4 低效算法 | 0 | 疑似项（`queue.remove(at: 0)`、每秒一次全表 `sweep`、启动期插入排序）均有界或仅在启动/秒级执行，已列入待验证假设 #2 |
| §7 降堆内存方案 | 2 | 结果过期条目不回收、每 token 新建 `Random`（见优化方案） |
| §8 降 CPU 方案 | 1 | 小结果路径的重复序列化（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`truncateUtf8` 的 `StringBuilder`、`applyLargeResult` 的 JSON 串、`readResource` 的数组）全部逃逸为返回值或被 store 长期持有，`@ local!` 无法覆盖；改造成本与收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 15 | 本部分全部发现均为存量缺陷（快照模式无 diff），其中 #1/#2 影响功能可用性、#3 影响结果链接的正确性与隔离，#4/#5 影响生命周期与峰值内存 |
| §12 并发安全与锁粒度 | 3 | 已列出共享路径与同步手段：`ToolResultStore` 的 count/budget（#6）、`listJson` 惰性发布（#8）、`McpSseStream.closed` 可见性（#14）；`SubscriptionHub`/`McpSubscriber` 的锁顺序固定为 hub → subscriber，未发现反向路径 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分公开符号（`McpSseStream`、`SubscriptionHub`、`ToolResultStore`、`ResultStoreOptions`、`McpTool`、`McpResource`）已在 `f_mcp/README.md:30-34`、`:640-710` 列出；本部分无 `.md`，§13 文档一致性归其它子轮 |
| 文件覆盖（§13 等） | 10/10 | 无缺失文件；本部分不含 `.md`，README 一致性只用于交叉核对（发现 #1、#5 引用 README 作为契约源） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

> 存量 15 条，是否纳入修复待用户决定；本部分未改动任何源码，也未跑构建。
>
> 范围外提示（不计入统计）：`ConcurrencyGate.sweep` 的 `count == 0` 判断与 `counts.remove` 之间同样存在 TOCTOU（`McpRateLimit.cj:449-453`），属其它子轮文件，此处只记一句。

## 总评

协议主路径（`_meta` 版本协商与 `-32022`/`-32602` 分支、游标分页、限流检查顺序与槽位释放、大结果外链、SSE 阻塞等待与保活）整体自洽，且实现里能看到刻意的“锁外格式化”“限频 sweep”“单次序列化复用”等取舍，说明作者已经做过一轮性能与并发审视。

阻塞项是两条“数值语义”问题：`maxConcurrency: 0` 这类“0 = 不限制”的文档承诺在并发维度上被实现成“全部拒绝”（#1，工具直接不可用），以及 `maxResultBytes <= 0` 把结果静默截成空串（#2）。两者都不在配置路径上表现出来，只在注解 / Builder 路径触发，现有用例恰好只测了闸门本身与配置路径，容易漏。

其次是生命周期：订阅者（#4）与结果存储（优化方案「结果存储的过期条目没有后台回收」）都只靠“下一次流量”自愈，空闲期内存不回落；大结果限额后置（#5）让“限额”挡不住一次大分配。这些在单机默认配置下都可接受，但多租户或大结果场景需要先补闸门。

死代码与重复逻辑集中在三组同构模板与测试辅助上，属可排期清理项，不影响正确性。存量 15 条中建议先处理 #1、#2（功能性阻塞）与 #4、#5（生命周期 / 峰值内存），#3 需要先确认随机源在该平台的实际行为，#6-#15 随下次重构一并处理。
