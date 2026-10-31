# Spec Delta

## Purpose

收敛 `f_mcp` 护栏层的资源与语义缺陷：限流器池无界、结果存储 TTL 不回收、并发闸门删除竞态、限流顺序与设计相反、限流配置静默失效、大结果按字节切 UTF-8。覆盖 R4（部分）、R5 与 R6-2 / R6-5。

## MODIFIED Requirements

### Requirement: 三层限流配置

限流 MUST 支持三层：全局默认（`McpConfig.rateLimit()`）→ 服务级（`Builder.rateLimit`）→ 每工具覆盖（`ToolRateLimit`）；每个字段 MUST 取第一个非 `None` 的值，全部缺省时回落到全局默认。

服务级 MUST 与全局**逐字段合并**：`Builder.rateLimit(...)` 只覆盖它显式给出的字段，未给出的字段 MUST 继承配置，MUST NOT 把整个配置丢弃。

数值语义 MUST 在注解 / Builder / 配置三条路径一致：

| 值 | 含义 |
| --- | --- |
| `-1` | 继承（仅 `@McpToolMeta` 默认值使用） |
| `0` | 显式不限制（覆盖掉下层的限制） |
| `> 0` | 限额 |

`maxConcurrency` 的归属 MUST 明确：

- `RateLimitPolicy.maxConcurrency` = **服务级全局总并发**，key 唯一，limit 只取服务级值；
- `ToolRateLimit.maxConcurrency` = **该工具的并发上限**，每个工具独立计数；
- 两者同时存在时工具调用 MUST 同时受两个闸门约束。

#### Scenario: 工具级覆盖

- **WHEN** 全局 `perCallerToolRpm = 120`，工具 A 设 `perCallerToolRpm = 10`
- **THEN** 调用方对 A 的限制为 10，对其他工具仍为 120

#### Scenario: 部分字段覆盖

- **WHEN** 工具只设 `maxResultBytes`
- **THEN** 其余限流字段沿用服务级 / 全局值

#### Scenario: Builder 只覆盖一个字段

- **WHEN** 配置里 `maxConcurrency = 64`、`perToolRpm = 6000`，代码调用 `.rateLimit(RateLimitPolicy(perCallerRpm: 120))`
- **THEN** 全局并发仍为 64、每工具配额仍为 6000，调用方配额为 120

#### Scenario: 显式不限制

- **WHEN** 全局 `perCallerRpm = 600`，工具注解写 `perCallerRpm: 0`
- **THEN** 该工具不检查调用方配额（`Some(0)` 覆盖，不回落到 600）

#### Scenario: 注解不写字段

- **WHEN** 工具注解只写 `description`
- **THEN** 所有限流字段为 `-1`，全部继承上层

#### Scenario: 工具并发与全局并发独立

- **WHEN** 全局 `maxConcurrency = 8`，工具 A `maxConcurrency = 2`
- **THEN** A 在途最多 2，A+B 合计最多 8；A 的限额变化不影响 B 的全局计数

### Requirement: 限流维度与错误语义

服务端 MUST 依次检查：全局总并发 → 工具并发 → 调用方×工具并发 → `perCallerRpm` → `perCallerToolRpm` → `perToolRpm`。

并发先于令牌桶：被并发拒绝的请求 MUST NOT 消耗任何令牌桶配额；任一后续检查失败时 MUST 释放已获得的并发租约（lease）。

超限 MUST 返回 `-32050`，`error.data` 含 `scope`、`limit`、`retryAfterMs`。`scope` MUST 与拒绝维度一一对应，取值只允许这 6 个：

| `scope` | 拒绝维度 |
| --- | --- |
| `concurrency` | 服务级全局并发（`RateLimitPolicy.maxConcurrency`） |
| `concurrency_tool` | 工具并发（`ToolRateLimit.maxConcurrency`） |
| `concurrency_caller` | 调用方×工具并发（`perCallerConcurrency`） |
| `caller` | `perCallerRpm` |
| `caller_tool` | `perCallerToolRpm` |
| `tool` | `perToolRpm` |

HTTP 场景 MUST 同时返回状态码 `429` 与 `Retry-After`（秒，向上取整，最小 1）；`scope` 的取值与是否 HTTP 无关。

调用方标识 MUST 按以下顺序派生并写入 README：

1. 配置 `mcp_trustForwardedFor = true` 且存在 `X-Forwarded-For` → 取第一个逗号分隔项并 trim；
2. 存在 `Authorization` → `SHA-256` 摘要的**前 16 字节**（32 个十六进制字符）；
3. 否则取 `remoteAddr` 并去掉端口；
4. 仍为空 → `anonymous`；非 HTTP（本地直调）→ `local`。

#### Scenario: 调用方总配额

- **WHEN** 同一调用方超过 `perCallerRpm`
- **THEN** 返回 `-32050`，`data.scope = "caller"`，HTTP 状态 429 且带 `Retry-After`

#### Scenario: 工具全局配额

- **WHEN** 多个调用方合计超过某工具的 `perToolRpm`
- **THEN** 返回 `-32050`，`data.scope = "tool"`

#### Scenario: 并发子限额

- **WHEN** 调用方对工具 A 的在途数超过 `perCallerConcurrency`，但总并发与工具并发都未满
- **THEN** 返回 `-32050`，`data.scope = "concurrency_caller"`

#### Scenario: 工具并发子限额

- **WHEN** 工具 A 的在途数超过其 `maxConcurrency`，但全局并发未满
- **THEN** 返回 `-32050`，`data.scope = "concurrency_tool"`

#### Scenario: 被并发拒绝不烧令牌

- **WHEN** 全局并发已满，且 `perCallerRpm = 2`
- **THEN** 连续 5 次被并发拒绝的请求不消耗令牌；并发释放后同一调用方仍能用满 2 次/分钟的配额

#### Scenario: 反向代理

- **WHEN** `mcp_trustForwardedFor = true`，请求带头 `X-Forwarded-For: 1.2.3.4, 10.0.0.1`
- **THEN** caller 为 `1.2.3.4`；同一来源的不同 TCP 连接共享一个桶

#### Scenario: 无 Authorization 时不留端口

- **WHEN** `remoteAddr = "10.0.0.9:53211"` 且未开 `trustForwardedFor`
- **THEN** caller 为 `10.0.0.9`

### Requirement: 并发闸门生命周期

并发计数 MUST 在 `finally` 中按「实际获得的租约」释放，MUST NOT 依据「配置是否非空」推断是否释放。

闸门条目 MUST 为「计数 + 上限 + 最近使用时间」；`release` MUST 只减计数，MUST NOT 在减到 0 时立即删除 key（避免与 `tryAcquire` 交错导致计数丢失或扣到新计数器上）。空闲条目 MUST 由 TTL / 容量上限回收；MUST NOT 让访问过的调用方永久占一个键。

`limit <= 0` MUST 视为不限制且 MUST NOT 计数；对应 `release` MUST 为空操作。

#### Scenario: 异常也释放

- **WHEN** 工具 handler 抛异常
- **THEN** 该调用方的全局与工具并发计数都回到 0

#### Scenario: 键回收

- **WHEN** 某调用方的在途数降到 0 并空闲超过 TTL
- **THEN** `ConcurrencyGate` 中对应 key 被移除

#### Scenario: 0 不误减

- **WHEN** 工具配置 `maxConcurrency = 0`（不限制）
- **THEN** 调用前后全局并发计数不变，不会把其他工具的在途数减 1

#### Scenario: 释放与获取交错

- **WHEN** 线程 A 释放到 0 的同时线程 B 从同一 key 获取成功
- **THEN** B 的在途计数保留，最终计数与真实在途数一致

### Requirement: 大结果转 `resource_link`

`tools/call` 的 content 总字节超过 `maxResultBytes`（默认 1 MB，可由 `McpTool.maxResultBytes` 覆盖）时 MUST 转为单个 `resource_link` 块，URI 为 `{publicBaseUrl}/mcp/tool-results/{token}`；未配置 `publicBaseUrl` 时 MUST 截断并设置 `data.truncated = true`，同时记录 warning。

截断 MUST：

1. 按 UTF-8 **字符边界**切分，MUST NOT 产生非法 UTF-8，MUST NOT 抛异常；
2. 保留 `isError` / `resultType` / `inputRequired` / `requestState`；
3. 丢弃 `structuredContent`（文本前缀已含其序列化形态），并在 `data` 中保留 `truncated` / `limit`；
4. 复用已经计算好的序列化文本，MUST NOT 为截断再序列化一次。

`tools/call` MUST 只为「量字节」序列化一次；小结果路径 MUST NOT 重复序列化。

#### Scenario: 配了 baseUrl

- **WHEN** 结果 2 MB 且 `publicBaseUrl` 已配置
- **THEN** `content` 只有一个 `resource_link`，可随后通过 `resources/read` 取回原文

#### Scenario: 未配 baseUrl

- **WHEN** 结果超限且 `publicBaseUrl` 缺失
- **THEN** 返回截断文本，`data.truncated = true`，不抛错

#### Scenario: 中文边界

- **WHEN** 结果含中文，序列化后第 `limit` 个字节落在某个 3 字节字符中间
- **THEN** 截断在字符边界结束，响应为合法 UTF-8，`tools/call` 不返回 `-32603`

#### Scenario: 保留 inputRequired

- **WHEN** 超限结果同时带 `inputRequired`
- **THEN** 截断结果仍包含 `inputRequired`

#### Scenario: 只序列化一次

- **WHEN** 一个 200 字节的小结果
- **THEN** `tools/call` 过程中对结果的完整序列化次数为 1（量字节与返回共用）

### Requirement: 临时结果存储

`ToolResultStore` MUST 同时约束条数（默认 256）、总字节（默认 256 MB）与 TTL（默认 10 分钟）；字节预算 MUST 用 CAS 预留，永不超限；`get` 发现过期时 MUST 用 `remove` 的返回值决定是否减账；MUST 只在写入压力下惰性回收，不建后台线程。

`put` MUST 在压力路径先回收再判定：

- 条数已满 → 先 `sweep()`，仍满才拒绝并计入 `rejectedByCount`；
- 字节不足 → 先 `sweep()`，再重试一次 `tryReserve`，仍失败才拒绝并计入 `rejectedByBytes`；
- `sweep` MUST 限频（同一进程内至少间隔 1 秒），避免每次写入都全表扫描。

`put(token, content)` 对**已存在 token** MUST：释放旧条目字节、MUST NOT 重复递增条数、MUST NOT 让旧字节永久占用预算。

#### Scenario: 条数满

- **WHEN** 已有 256 条且都未过期
- **THEN** 新写入被拒绝，返回 false，不驱逐现有条目

#### Scenario: 过期读取

- **WHEN** 条目超过 TTL 后被读取
- **THEN** 返回 None，且字节预算与条数被正确减账

#### Scenario: 过期后压力回收

- **WHEN** 256 条全部过期，再写入第 257 条
- **THEN** `put` 先 `sweep` 清空过期条目，写入成功，返回 true

#### Scenario: 重复 token

- **WHEN** 用同一 token 写入两次，内容大小分别为 100 / 200 字节
- **THEN** `size == 1`，`usedBytes == 200`，预算不泄漏

#### Scenario: 服务关闭

- **WHEN** 调用 `McpServer.close()`
- **THEN** 结果存储、限流桶、并发闸门与订阅中心全部释放

### Requirement: 运行期自适应调容

`ToolResultStore` MUST 每窗口统计 `puts` / `rejectedByCount` / `rejectedByBytes` / 占用率；拒绝率超过阈值（默认 1%）且未到 `ceiling` MUST 将 `maxEntries` 上调 25%；连续 `shrinkConfirmWindows`（默认 3）个窗口占用低于 25% 且无字节拒绝 MUST 下调 12.5%（不低于 `floor`）。只调 `maxEntries`，不调 `maxBytes` / TTL。每窗口一条 debug 日志，每次调整一条 info 日志。

窗口未到期时 MUST 走无锁快路径；窗口到期时 MUST 只在锁内计算快照与决策，字符串格式化、日志与 `log.append` MUST 在锁外执行。

#### Scenario: 拒绝率触发扩容

- **WHEN** 某窗口 100 次写入有 3 次因条数被拒，`maxEntries < ceiling`
- **THEN** 下一个窗口 `maxEntries` 上调 25%

#### Scenario: 连续空闲触发缩容

- **WHEN** 连续 3 个窗口占用低于 25% 且无字节拒绝
- **THEN** `maxEntries` 下调 12.5%，但不低于 `floor`

#### Scenario: 字节瓶颈不扩容

- **WHEN** 拒绝全部来自 `rejectedByBytes`
- **THEN** `maxEntries` 不变

#### Scenario: 未到期不加锁

- **WHEN** 同一窗口内连续 `put` 1000 次
- **THEN** 除第一次进入窗口外，其余调用不获取窗口锁

### Requirement: 分布式限流 SPI

限流 MUST 通过 `RateLimitBackend` 接口执行；默认实现是进程内令牌桶；使用方 MUST 能注入共享后端，使多实例共享计数。

内置后端 MUST 只有实现 `tryAcquire` 语义的四种：`token-bucket`（默认）/ `leaking-bucket` / `sliding-window` / `unlimited`。`any-moment` MUST 移除：其语义是「同时进入 `exec` 的线程数」，与「每分钟配额」无关，选择它等于静默关闭限流。

配置引用已移除的后端名 MUST 在启动期抛出 `IllegalArgumentException`，消息列出可用名字；MUST NOT 静默回退。

#### Scenario: 注入后端

- **WHEN** Builder 传入自定义 `RateLimitBackend`
- **THEN** `tools/call` 的限流判定走该后端

#### Scenario: 默认本地

- **WHEN** 未注入后端
- **THEN** 使用进程内令牌桶，行为与单实例一致

#### Scenario: 已移除的后端

- **WHEN** `mcp_rateLimitBackend = any-moment`
- **THEN** 启动期报错，提示可用后端名

## ADDED Requirements

### Requirement: 限流器池有界与回收

`LimiterPool` MUST 有界：

- 容量上限（默认 10 000 个 limiter）；
- 空闲 TTL（默认 10 分钟）；
- 获取时更新最近使用时间；周期性（按操作计数触发，无后台线程）回收「空闲超过 TTL」与「超出容量时最久未使用」的条目；
- 回收与 `close()` MUST 调用限流器的 `close()`，真正取消其 `Timer` 与内部队列。

`RateLimiter` MUST 提供可覆盖的 `close()`（默认空实现）；定时器型限流器（token / leaking / sliding）MUST 在其中取消 Timer。

`LimiterPool` 的 key MUST 不含调用方可控的完整原文（保持现有 `SHA-256` / 去端口派生），防止攻击者用超长 `Authorization` 放大 key 内存。

#### Scenario: 调用方基数爆炸

- **WHEN** 连续用 50 000 个不同 `Authorization` 调用启用 `perCallerRpm` 的工具
- **THEN** `LimiterPool` 条目数不超过容量上限 + 一个回收批次，进程 RSS 不随调用方数量单调增长

#### Scenario: 淘汰取消定时器

- **WHEN** 某 limiter 因空闲被淘汰
- **THEN** 其 `Timer` 被取消，不再周期回调

#### Scenario: 关闭

- **WHEN** `McpServer.close()`
- **THEN** 池内全部 limiter 被 `close()`，Timer 全部取消

### Requirement: 限流配置校验

`mcp_rateLimit` 的两种写法（CSV / JSON）MUST 做语义校验：

- 负数 MUST 报 `IllegalArgumentException`；
- `0` MUST 表示「不限制」（转成 `None`）；
- `rpm` 类字段上限 MUST 为 1 000 000，超过 MUST 报错；
- JSON 只接受整数；`JsonDecimal`（如 `1.9`）MUST 报错，MUST NOT 截断；
- JSON 未知键 MUST 报错；
- CSV 段数 MUST ≤ 5；中间空段 MUST 报错；尾部多余段 MUST 报错；
- JSON 语法错误 MUST 包装成 `IllegalArgumentException`（带原始错误信息），MUST NOT 直接抛 `JsonException`。

配置项 `mcp_trustForwardedFor` MUST 为布尔字符串（`true` / `false`），其他值 MUST 报错。

#### Scenario: 负数

- **WHEN** `mcp_rateLimit = "-1,120"` 或 `{"perCallerRpm":-1}`
- **THEN** 启动期抛 `IllegalArgumentException`，消息含字段名

#### Scenario: 小数

- **WHEN** `mcp_rateLimit = {"perCallerRpm":1.9}`
- **THEN** 启动期报错，不按 1 处理

#### Scenario: 未知键

- **WHEN** `mcp_rateLimit = {"perCallerRpm":120,"foo":1}`
- **THEN** 启动期报错，消息含 `foo`

#### Scenario: 过大配额

- **WHEN** `perCallerRpm = 100000000`
- **THEN** 启动期报错，提示上限
