# Spec Delta

## Purpose

定义 `f_mcp` 的服务端护栏：三层限流与并发闸门、限流错误语义、大结果的 `resource_link` / 截断策略与临时结果存储。

## ADDED Requirements

### Requirement: 三层限流配置

限流 MUST 支持三层：全局默认（`RateLimitPolicy`）→ 服务级（`Builder.rateLimit`）→ 每工具覆盖（`ToolRateLimit`）；每个字段 MUST 取第一个非 `None` 的值，全部缺省时回落到全局默认。

#### Scenario: 工具级覆盖

- **WHEN** 全局 `perCallerToolRpm = 120`，工具 A 设 `perCallerToolRpm = 10`
- **THEN** 调用方对 A 的限制为 10，对其他工具仍为 120

#### Scenario: 部分字段覆盖

- **WHEN** 工具只设 `maxResultBytes`
- **THEN** 其余限流字段沿用服务级 / 全局值

### Requirement: 限流维度与错误语义

服务端 MUST 依次检查：全局总并发、工具子并发、`perCallerRpm`、`perCallerToolRpm`、`perToolRpm`。超限 MUST 返回 `-32050`，`error.data` 含 `scope`（`caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`）、`limit`、`retryAfterMs`。

#### Scenario: 调用方总配额

- **WHEN** 同一调用方超过 `perCallerRpm`
- **THEN** 返回 `-32050`，`data.scope = "caller"`

#### Scenario: 工具全局配额

- **WHEN** 多个调用方合计超过某工具的 `perToolRpm`
- **THEN** 返回 `-32050`，`data.scope = "tool"`

#### Scenario: 并发子限额

- **WHEN** 调用方对工具 A 的在途数超过 `perCallerConcurrency`，但总并发未满
- **THEN** 返回 `-32050`，`data.scope = "concurrency_tool"`

### Requirement: 并发闸门生命周期

并发计数 MUST 在 `finally` 中释放；计数归零 MUST 回收 key（先读值比对引用再删除），不得让访问过的调用方永久占一个键。

#### Scenario: 异常也释放

- **WHEN** 工具 handler 抛异常
- **THEN** 该调用方的全局与工具并发计数都回到 0

#### Scenario: 键回收

- **WHEN** 某调用方的在途数降到 0
- **THEN** `ConcurrencyGate` 中对应 key 被移除

### Requirement: 大结果转 `resource_link`

`tools/call` 的 content 总字节超过 `maxResultBytes`（默认 1 MB）时 MUST 转为单个 `resource_link` 块，URI 为 `{publicBaseUrl}/mcp/tool-results/{token}`；未配置 `publicBaseUrl` 时 MUST 截断并设置 `data.truncated = true`，同时记录 warning。

#### Scenario: 配了 baseUrl

- **WHEN** 结果 2 MB 且 `publicBaseUrl` 已配置
- **THEN** `content` 只有一个 `resource_link`，可随后通过 `resources/read` 取回原文

#### Scenario: 未配 baseUrl

- **WHEN** 结果超限且 `publicBaseUrl` 缺失
- **THEN** 返回截断文本，`data.truncated = true`，不抛错

### Requirement: 临时结果存储

`ToolResultStore` MUST 同时约束条数（默认 256）、总字节（默认 256 MB）与 TTL（默认 10 分钟）；字节预算 MUST 用 CAS 预留，永不超限；`get` 发现过期时 MUST 用 `remove` 的返回值决定是否减账；MUST 只在写入压力下惰性回收，不建后台线程。

#### Scenario: 条数满

- **WHEN** 已有 256 条且都未过期
- **THEN** 新写入被拒绝，返回 false，不驱逐现有条目

#### Scenario: 过期读取

- **WHEN** 条目超过 TTL 后被读取
- **THEN** 返回 None，且字节预算与条数被正确减账

#### Scenario: 服务关闭

- **WHEN** 调用 `McpServer.close()`
- **THEN** 结果存储、限流桶与并发闸门全部释放

### Requirement: 临时链接的读取

`resources/read` MUST 优先处理 `{publicBaseUrl}/mcp/tool-results/` 前缀；命中返回原内容，未命中或过期返回 `-32002` 且 `data.reason = "expired"`；用户资源 MUST NOT 注册同前缀的 URI。

#### Scenario: 读回大结果

- **WHEN** 读取未过期的临时链接
- **THEN** 返回原始 `ResourceContent`

#### Scenario: 前缀冲突

- **WHEN** 注册以 `/mcp/tool-results/` 开头的用户资源
- **THEN** `build()` 抛异常

### Requirement: 运行期自适应调容

`ToolResultStore` MUST 每窗口统计 `puts` / `rejectedByCount` / `rejectedByBytes` / 占用率；拒绝率超过阈值（默认 1%）且未到 `ceiling` MUST 将 `maxEntries` 上调 25%；连续 `shrinkConfirmWindows`（默认 3）个窗口占用低于 25% 且无字节拒绝 MUST 下调 12.5%（不低于 `floor`）。只调 `maxEntries`，不调 `maxBytes` / TTL。每窗口一条 debug 日志，每次调整一条 info 日志。

#### Scenario: 拒绝率触发扩容

- **WHEN** 某窗口 100 次写入有 3 次因条数被拒，`maxEntries < ceiling`
- **THEN** 下一个窗口 `maxEntries` 上调 25%

#### Scenario: 连续空闲触发缩容

- **WHEN** 连续 3 个窗口占用低于 25% 且无字节拒绝
- **THEN** `maxEntries` 下调 12.5%，但不低于 `floor`

#### Scenario: 字节瓶颈不扩容

- **WHEN** 拒绝全部来自 `rejectedByBytes`
- **THEN** `maxEntries` 不变（应调 `maxBytes`，由人决定）

### Requirement: 分布式限流 SPI

限流 MUST 通过 `RateLimitBackend` 接口执行；默认实现是进程内 `LocalRateLimitBackend`；使用方 MUST 能注入共享后端，使多实例共享计数。

#### Scenario: 注入后端

- **WHEN** Builder 传入自定义 `RateLimitBackend`
- **THEN** `tools/call` 的限流判定走该后端

#### Scenario: 默认本地

- **WHEN** 未注入后端
- **THEN** 使用进程内令牌桶，行为与单实例一致
