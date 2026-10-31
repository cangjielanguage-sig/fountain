# f_mcp —— 仓颉 MCP 客户端 / 服务端 SDK 设计

> **以实现为准**：本文档描述设计意图，任何与源码不一致的地方以 `f_mcp/src` 为准。
> 关键差异见文末「文档与实现对照」，最近一次对齐：`fix-jsonrpc-mcp-review-findings`。
>
> 版本 **v1.0** ｜ 2026-10-24 ｜ 状态：待评审
>
> 定位：fountain 模块。**MCP 客户端实现**为主，同时提供**构建 MCP 服务**的 API。
> 消息层完全复用 `f_jsonrpc`；本模块只负责 MCP 的语义（能力、方法、内容块、版本协商）。
>
> **硬约束：`f_mvc` 零改动。** f_mcp 与 f_jsonrpc 一样，只使用 `f_mvc` 的现有能力
> （`@Controller`、`@RequestBody`、`CurrentHttpContext`，以及 f_jsonrpc 提供的 `@JsonRpcMapping`），
> 不新增或修改 `f_mvc` 的任何 API，也不依赖其未公开成员。
>
> 部署形态：用 f_mcp 写的 MCP **服务**编译为动态链接库，由 `fboot run --dylibPattern=<regex>` 加载启动。
>
> v0.9 → v1.0（配置与可观测性）：
> - **12 个自适应配置项全部集中列表**（5.6.6.5.1），并补 `Builder.resultStore(options)`
> - 新增 **DEBUG 评估日志**（5.6.6.5.6）：**每个窗口一条**，含统计、阈值与决策依据，
>   供开发者观察后决定下次启动的配置值
> - 明确**两级日志分工**：`debug` 记"每次评估"（调参期开），`info` 记"实际调整"（始终开）
>
> v0.8 → v0.9（自适应改为默认开启）：
> - **自适应调容默认开启**：`maxEntries` 是"起点"不是"配置值"；`adaptive: false` 可关掉
> - 可调区间叫 **`floor`/`ceiling`**（避免与外层 `maxEntries` 撞名）
> - 新增**非对称策略**：调大 25% / 调小 12.5%，调小需连续 3 个窗口确认
> - 调小的附加条件：`rejectedByBytes == 0`（字节没压力才缩）
>
> v0.7 → v0.8（一项新增）：
> - **新增 5.6.6.5 运行期自适应调容**：只调 `maxEntries`，不调 `maxBytes` / TTL；
>   **两种拒绝分开统计**（`rejectedByCount` / `rejectedByBytes`）是前提
>   —— 当时定为**默认关闭**，**v0.9 已改为默认开启**
>
> v0.6 → v0.7（五项确认）：
> - `AtomicInt64.fetchAdd` **返回旧值**，`let v = counter.fetchAdd(1) + 1` 的写法成立
> - `ConcurrentHashMap` 是 **`addIfAbsent`**（不是 `putIfAbsent`），且**没有** `remove(key, value)`，
>   防误删只能靠 `===` 引用比对（7.2.2）
> - `ConcurrencyGate` 加 `close()`
> - `data.scope` **拆成五个**：`concurrency`（全局总并发）与 `concurrency_tool`（工具子并发）分离
>
> v0.5 → v0.6（五项决策落定）：
> - **条数成为主约束**：`maxEntries = 256`、`maxBytes = 256 MB`（256 × 1 MB 正好对齐）
> - **不做后台清理**：空闲时保留热数据，忙起来直接命中——这是正面价值，不是妥协
> - `ToolRateLimit` **新增 `perCallerConcurrency`**，但语义是**子限额**而非"覆盖全局"
> - 确认 `ConcurrentHashMap.remove(key)` 返回被删值（并发减账成立）
> - 确认 `String.size` 是 **UTF-8 字节数**（`estimateBytes` 成立）
>
> v0.4 → v0.5（五项决策落定）：
> - **纠正 `HeapCache.maxLife` 语义**：默认 `once=false` 时是"最后一次访问后"，
>   `get()` 自动续期，**不需要 prolong**（v0.4 的说法错了，依据见 7.2.4.1）
> - `perToolRpm` 改用 **`std.collection.concurrent.ConcurrentHashMap`**（工具数固定，不需要淘汰）
> - **临时结果不用 `HeapCache`**：`ConcurrentHashMap` + CAS 字节预算池，自管条数/字节/TTL（5.6.6.2）
> - `maxResultBytes` 默认 **256 KB → 1 MB**（可配），减少无谓的多一跳
> - `resource_link` **不加 HMAC 签名**
>
> v0.3 → v0.4（四项决策落定）：
>
> - **限流改三层**：全局默认值 → 服务级配置 → **每个工具可声明覆盖**（7.2.1）
> - **大结果一律转 `resource_link`**（文本也转，不再"文本截断、二进制转 link"）；
>   新增 `publicBaseUrl` 与临时结果资源（5.6.6）
> - **URI 规则**：完整 URI 只接受 `http` / `https` / `ftp`；`/path` 由 `publicBaseUrl` 补全，`file://` 等一律 `-32602`（5.6.1）
> - **限流器用 `f_concurrent` 的 4 种实现**：`token-bucket`（默认）/ `leaking-bucket` / `sliding-window` / `unlimited`，由 `mcp_rateLimitBackend` 选择（7.2.6 / 7.2.7）；后端的完整清单见 7.2.6
>
> v0.2 → v0.3（七项决策落定，补上 v0.2 遗留的待确认）：
>
> - **legacy 对端给友好提示**（不是裸错误），错误文案带双方版本（1.2 / 3.3）
> - **`resources/list` + `resources/read` 一起做**（5.6），不再是"首版只做 list"
> - **不做 server-side stdio 夹具**：stdio 只保留客户端侧，用于连外部 server 自测（3.2）
> - **单轮优先**：`tools/call` 单轮做扎实，`input_required` 多轮**可配**、默认关（4.4）
> - **schema 统一走 `f_data.json.JsonSchema`**：生成用 `toJsonSchema<T>()`，校验用 `validate`（5.3）
> - **限流双层**：调用方（IP / token）+ 工具配额，另加并发与结果大小上限（7.2）
> - **能力声明原则：不声明空壳**。prompts 首版**不声明**，resources 声明了就完整实现（5.4）
>
> v0.1 → v0.2：
>
> - **只实现最新规范**（当前 `2026-07-28`），不做 legacy `initialize` 握手；后续跟随规范版本升级
> - stdio 收敛为**模块内置的简化实现，仅供测试**，不作为生产传输
> - 明确「只补 f_mvc 没有的 MCP 特性」，消息层与路由全部复用 `f_jsonrpc` / `f_mvc`
> - 部署命令统一为 `fboot run --dylibPattern=<regex>`（PATH 省略即当前目录）

---

## 0. 结论摘要


| 项           | 结论                                                                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| 对齐规范     | MCP**2026-07-28**（modern：无握手、每请求携带版本与能力）                                                                              |
| 版本策略     | **只实现最新规范**（当前 `2026-07-28`），不实现 legacy 握手；后续跟随规范升级                                                          |
| legacy 对端  | **给友好提示**（说明本 SDK 只支持无握手协议 + 双方版本），不返回裸 `-32601`（1.2.1）                                                   |
| 消息层       | JSON-RPC 2.0，**全部复用 `f_jsonrpc`**                                                                                                 |
| 传输         | 服务端：Streamable HTTP；客户端：Streamable HTTP + stdio（**stdio 仅内置简化版，供自测**）                                             |
| 能力范围     | `tools` + **`resources`（list + read 成对实现）**；**`prompts` 首版不声明**（5.4）                                                     |
| 能力声明原则 | **不声明空壳**：要么不声明，声明了就必须完整实现（含分页、错误、确定性排序）                                                           |
| schema       | **统一走 `f_data.json.JsonSchema`**：`toJsonSchema<T>()` 生成、`JsonSchema.validate` 校验（5.3）                                       |
| 首版不做 SSE | 响应一律返回单个 JSON 对象（规范允许）；声明`listChanged: false`                                                                       |
| 多轮重试     | **单轮优先**；`input_required` 多轮默认 `Manual`，可配 `Auto(handler, maxRounds)`（4.4）                                               |
| 限流         | **三层**：全局默认 → 服务级配置 → **每工具覆盖**；内置 5 种 `f_concurrent` 限流器，`mcp_rateLimitBackend` 选择，跨进程走 `RateLimitBackend` SPI |
| 大结果       | 超过 **1 MB**（可配）**一律转 `resource_link`**；临时结果自管理（256 条 / 256 MB / TTL 10 分钟）（5.6.6） |
| 容量自适应   | **默认开启**。只调 `maxEntries`（不调 `maxBytes` / TTL）；按 `rejectedByCount` 触发，调大敏捷调小迟钝（5.6.6.5） |
| 可观测性     | **每个窗口一条 `debug`**（含未调整原因）+ **每次调整一条 `info`**；13 项参数全部可配（5.6.6.5.3 / 5.6.6.5.6） |
| 资源 URI     | **完整 URI 只接受 `http` / `https` / `ftp`**；也允许 `/path`，由 `publicBaseUrl` 补全（5.6.1）                                                                |
| 部署         | `output-type = "dynamic"` + `--dy-std`，`fboot run --dylibPattern=<模块名>`                                                            |
| 依赖         | `fountain::f_jsonrpc`、`fountain::f_mvc`、`fountain::f_data`、`fountain::f_concurrent`（限流）、`fountain::f_config`（配置）、`fountain::f_process`（stdio） |

---

## 1. 规范形态：先纠正一个过时的印象

多数关于 MCP 的材料描述的还是「`initialize` 握手 + 会话」那一套。**2026-07-28 版已经取消了握手。**

### 1.0 版本策略：只跟最新


| 决定       | 内容                                                                               |
| ---------- | ---------------------------------------------------------------------------------- |
| 实现范围   | **只实现当前最新版**（本文档写作时为 `2026-07-28`）                                |
| legacy     | **不实现**。没有 `initialize` 握手、没有 `notifications/initialized`、没有会话状态 |
| 对端更旧时 | 服务端不认识`_meta` 里的版本就返回 `-32022`；客户端拿到后按 `supported` 重试或报错 |
| 升级方式   | 规范发新版时，按第 11 节的「跟随清单」逐项过一遍，不做运行时多版本共存             |

这样做的代价是**连不上只实现旧版的客户端**。这是刻意的取舍：多版本共存会让每个方法都要写两条路径，
而 MCP 的演进速度很快（2024-11 到 2026-07 已经三次结构性调整），背着旧版跑会很快变成负担。

规范原文：

> **There is no negotiation handshake.** Every request carries its protocol version, and the server accepts or rejects each request independently.


| 维度           | legacy（≤ 2025-11-25）                         | **modern（2026-07-28）**                                         |
| -------------- | ----------------------------------------------- | ---------------------------------------------------------------- |
| 建连           | `initialize` 请求 + `notifications/initialized` | **没有**                                                         |
| 状态           | 连接级会话                                      | **无状态，每请求自包含**                                         |
| 版本           | 握手时协商一次                                  | **每个请求的 `_meta` 里带**                                      |
| 能力           | 握手时交换一次                                  | **每个请求的 `_meta` 里带**                                      |
| 服务端发起请求 | 允许                                            | **不允许**（server 不发 JSON-RPC request，client 不发 response） |
| 发现           | `initialize` 返回                               | `server/discover`（**服务端 MUST 实现**）                        |

最后一行影响很大：**modern 协议是单向请求模型**。需要"向客户端要东西"的场景（如 elicitation）
不再是服务端主动发请求，而是通过 `tools/call` 的 `resultType: "input_required"` 让客户端重试。

### 1.1 每请求的 `_meta`

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "tools/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": { "name": "f_mcp", "version": "1.0.0" },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

服务端在响应的 `_meta` 里回 `io.modelcontextprotocol/serverInfo`。

### 1.2 版本不匹配

服务端不支持请求里的版本时，**必须**返回：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32022,
    "message": "Unsupported protocol version",
    "data": { "supported": ["2026-07-28", "2025-11-25"], "requested": "1900-01-01" }
  }
}
```

客户端拿到 `-32022` 后，从 `supported` 里挑一个共同版本重试；一个都没有才报错。

### 1.2.1 legacy 对端：给升级提示，不给裸错误

**决定：不静默失败、不假装成功、也不抛一个看不懂的错误——明确告诉调用方"你该升级哪一端"。**

三种 legacy 场景，三种提示：


| 场景                   | 触发条件                                                                            | 处置                                                                       |
| ---------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **旧客户端连新服务端** | 收到`initialize` / `notifications/initialized` 这类 legacy 方法                     | 返回`-32601`，`message` 带升级提示，`data.legacyMethod` 标出收到的方法名   |
| **新客户端连旧服务端** | `server/discover` 或 `tools/list` 收到 `-32601` / `-32602`，或响应里缺 `resultType` | 抛`McpException`，提示"对端可能是 MCP 2025-11-25 及更早版本，请升级服务端" |
| **版本无交集**         | `-32022` 的 `data.supported` 与本端支持集合无交集                                   | 抛`McpException`，带双方版本列表                                           |

服务端返回的 `message` 固定格式（便于日志检索与用户识别）：

```
Unsupported legacy method 'initialize'. This server implements MCP 2026-07-28
(handshake-free). Please upgrade your client to a version that supports
server/discover, or use an older server.
```

`data` 里补充机器可读字段：

```json
{
  "code": -32601,
  "message": "Unsupported legacy method 'initialize'. ...",
  "data": {
    "legacyMethod": "initialize",
    "supportedVersions": ["2026-07-28"],
    "docUrl": "https://modelcontextprotocol.io/specification/2026-07-28"
  }
}
```

**为什么用 `-32601` 而不是新造一个码**：`initialize` 在这个协议版本里确实"不存在"，
`-32601 Method not found` 语义正确。额外信息放 `data`，不污染错误码体系。

**为什么不做协议降级**：实现 legacy 握手意味着同时维护两套状态机（有会话 / 无会话），
每个方法都要分支。这是协议演进的成本，不该由一个 SDK 承担——
**要么用新版服务端，要么用旧版 SDK**。

客户端探测逻辑（只探测一次，不做重试风暴）：

```
首次请求前（可配 skipProbe）：
  发 server/discover
    ├─ 成功     → 记下 capabilities 与 supportedVersions
    ├─ -32601   → 判定为 legacy 服务端，抛 McpException（提示升级服务端）
    └─ -32022   → 走 3.3 的单次重试
```

探测结果缓存在 `McpClient` 实例上，不重复探测。

### 1.3 `server/discover`

服务端 **MUST** 实现。请求除 `_meta` 外无参数；响应：

```json
{
  "result": {
    "resultType": "complete",
    "supportedVersions": ["2026-07-28"],
    "capabilities": { "tools": {}, "resources": {} },
    "_meta": {
      "io.modelcontextprotocol/serverInfo": { "name": "kb-server", "version": "1.0.0" }
    },
    "instructions": "可选的自然语言说明",
    "ttlMs": 3600000,
    "cacheScope": "public"
  }
}
```

客户端**不必**先调用它，但两种场景值得调：一次性拿到服务端能力（省掉分别探测 `tools/list`、
`prompts/list`、`resources/list`）；以及在**没有 HTTP 状态码可用**的传输上判断对端能力。

---

## 2. 与 f_jsonrpc 的分工

这是本设计最需要划清的一条线。**f_mcp 不重复实现任何 JSON-RPC 逻辑。**


| 能力                          | f_jsonrpc                     | f_mcp               |
| ----------------------------- | ----------------------------- | ------------------- |
| JSON 编解码                   | ✅                            | —                  |
| 请求/响应/通知/批量           | ✅                            | —                  |
| 标准错误码 -32700~-32603      | ✅                            | —                  |
| HTTP 端点（MVC 集成）         | ✅                            | —                  |
| 方法表与分发                  | ✅                            | 只往里注册 MCP 方法 |
| `_meta` 校验与回填            | 透传（`JsonRpcContext`）      | ✅ 定义键名与语义   |
| `resultType` 字段             | 不关心                        | ✅ 生成与校验       |
| 协议版本协商 /`-32022`        | —                            | ✅                  |
| 能力声明与判断                | —                            | ✅                  |
| 工具 / 资源 / 提示语义        | —                            | ✅                  |
| 内容块（text/image/resource） | —                            | ✅                  |
| 版本校验与`-32022`            | —                            | ✅                  |
| stdio 分帧                    | —                            | ✅                  |
| 子进程管理                    | —                            | ✅（客户端侧）      |

一句话：**f_jsonrpc 管"消息怎么走"，f_mcp 管"消息是什么意思"。**

---

## 3. 传输层

### 3.1 Streamable HTTP（服务端、客户端都支持）

规范定义：**所有消息都是对单个 MCP 端点的 HTTP POST**；回复可以是单个 JSON 对象，
也可以是该请求作用域的 SSE 流。

```
POST /mcp
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28

{ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": { "_meta": { ... } } }
```


| 要求                      | 说明                                                                    |
| ------------------------- | ----------------------------------------------------------------------- |
| 端点                      | 单一路径，f_mcp 默认`/mcp`                                              |
| `MCP-Protocol-Version` 头 | 与 body 的`_meta` 版本必须一致；不一致按服务端校验规则拒绝              |
| 请求头镜像                | 绑定层把 body 里的元数据镜像到 HTTP 头，便于中间层路由；**body 是权威** |
| 响应形态                  | 单个 JSON 对象**或** 请求作用域 SSE                                     |
| 取消                      | HTTP 侧通过**关闭响应流**表达取消                                       |
| 通知                      | 返回`202 Accepted`，**空 body**                                         |

**已实现「单个 JSON 对象」+ `/mcp/sse` 长连接响应。** `subscriptions/listen` 返回 `subscriptionId`
和可直接连接的 `sseUrl`；`GET /mcp/sse?subscriptionId=N` 会绑定到同一个订阅者。
`tools/list` 等列表仍是静态快照，能力声明里的 `listChanged` 保持 `false`；订阅用于自定义通知。

### 3.2 stdio：内置简化实现，仅用于测试

规范里的 stdio 是「客户端把服务端作为子进程启动，换行分隔的 JSON-RPC」。

**f_mcp 内置一个最简实现，定位是"自测工具"，不是生产传输。** 支持范围：


| 项                  | 支持 | 说明                     |
| ------------------- | ---- | ------------------------ |
| 启动子进程          | ✅   | 仅 Linux / OHOS          |
| 换行分帧            | ✅   | 一行一条消息             |
| 写请求 / 读响应     | ✅   | 按 `id` 匹配；跳过通知与噪声行；读超时抛 `IOException` |
| stderr 转发         | ✅   | 原样打到日志             |
| 进程退出            | ✅   | 关闭 stdin，等待退出     |
| 重连 / 进程崩溃恢复 | ❌   | 进程没了就报错           |
| 并发请求            | ⚠️ | 串行发送，不保证乱序响应 |
| 大消息（>1 MB）     | ⚠️ | 单行缓冲上限 8 MB        |

**为什么只做测试用：**

1. `fboot run` 启动的是常驻 HTTP 服务，天生不适合作为 stdio 子进程；
2. 生产级 stdio 传输需要处理进程池、健康检查、优雅退出、日志分流，
   这些与 MCP 协议本身无关，属于进程管理范畴，不该压在协议模块里；
3. 它真正要解决的问题只有一个：**在没有外部 MCP 客户端的情况下，验证自己的服务端实现对不对**。

> 需要生产级 stdio 时，正确的做法是把子进程管理放到 `f_process` 之上单独做一层，
> 由 f_mcp 提供 `McpMessageCodec`（编解码）供其复用。

#### 3.2.1 不做 server-side stdio 夹具

**决定：不提供"把本地 `McpServer` 包成 stdio 子进程"的测试夹具。**

之前的待确认里问过"要不要做一个夹具，把 `McpServer` 暴露成 stdio 方便测试"。答案是不做。

理由三条：

1. **测试路径已经够了。** `McpServer` 提供 `jsonRpcServer()`，直接在进程内调用就能测全部方法逻辑；
   跨进程的行为（路由、Content-Type、空 body、鉴权）用 HTTP 客户端打自己更真实。
   stdio 夹具测的是"进程管理"，不是"MCP 实现"。
2. **它会掩盖真正的部署形态。** 生产是 `fboot run` 加载动态库、监听 HTTP 端口。
   用 stdio 夹具测得很顺，反而会漏掉 6.6 那类"通知的空 body"问题——那只有在真 HTTP 栈上才暴露。
3. **维护成本不对称。** 夹具需要：子进程启动、stdin/stdout 双向管道、行分帧、进程退出清理、
   异常时不留僵尸进程。这四项都是容易在 CI 上偶发失败的，收益却只是"少写一个 HTTP 客户端"。

**替代方案（推荐做法）**：


| 要测什么                                 | 怎么测                                                             |
| ---------------------------------------- | ------------------------------------------------------------------ |
| 方法逻辑（参数解析、结果构造、错误映射） | 进程内直调`jsonRpcServer().handle(request)`                        |
| 传输层（头、状态码、空 body）            | 起一个真 HTTP 服务，用`McpClient(HTTP)` 打自己                     |
| 与外部 MCP 实现的互操作                  | 用内置 stdio**客户端**去连别人的 server（这才是 stdio 存在的意义） |

### 3.3 版本处理：单一版本 + `-32022` 重试

因为没有握手，版本协商变成了**逐请求的接受/拒绝**：

```
客户端发请求（_meta 里带它想用的版本）
   ├─ 服务端支持 → 正常返回
   └─ 不支持     → -32022，data.supported 列出服务端支持的版本
        ├─ 有交集 → 换成交集里的版本重试一次
        └─ 无交集 → 报错，不做降级
```

两条实现约定：

1. **只重试一次。** 拿到 `-32022` 后换成 `supported` 里的第一个版本重试；再失败就报错，
   不做循环试探。
2. **版本是客户端配置项，不是自动探测结果。** 默认取 f_mcp 内置常量
   `MCP_PROTOCOL_VERSION`，允许显式覆盖（用于测试服务端对新版本的处理）。

服务端侧：每个请求都要校验 `_meta` 里的版本，不支持就返回 `-32022`，
**并且 `data.supported` 必须非空**——否则客户端无法选择。

## 4. 客户端 API

### 4.1 结构

```
McpClient
 ├── McpTransport（接口）
 │    ├── HttpTransport       → 复用 JsonRpcClient
 │    └── StdioTransport      → 子进程 + 行分帧
 └── McpSession（能力缓存、版本、serverInfo）
```

```cangjie
public class McpClient {
    /// HTTP：直连已有服务
    /// 抛 McpException 表示连接或发现失败
    public static func http(url: String, opts!: McpClientOptions = McpClientOptions()): McpClient

    /// stdio：启动子进程
    public static func stdio(command: String, args!: Array<String> = [], opts!: McpClientOptions = McpClientOptions()): McpClient

    // ---- 发现 ----
    public func discover(): DiscoverResult

    // ---- 工具 ----
    public func listTools(cursor!: ?String = None): ToolPage
    public func listAllTools(): Array<McpToolDescriptor>   // 自动翻页（100 页 / 1000 条上限）
    public func callTool(name: String, arguments!: JsonValue = JsonObject()): CallToolResult

    // ---- 资源 / 提示（按需）----
    public func listResources(cursor!: ?String = None): ResourcePage
    public func readResource(uri: String): ReadResourceResult
    public func listPrompts(cursor!: ?String = None): PromptPage
    public func getPrompt(name: String, arguments!: JsonObject = JsonObject()): GetPromptResult

    public func close(): Unit
}
```

### 4.2 每请求 `_meta` 的自动注入

调用方**不需要**手写 `_meta`。`McpClient` 在每次请求前统一注入：

```cangjie
func decorate(params: JsonObject): JsonObject {
    let meta = JsonObject()
    meta['io.modelcontextprotocol/protocolVersion'] = JsonString(session.version)
    meta['io.modelcontextprotocol/clientInfo'] = clientInfoJson
    meta['io.modelcontextprotocol/clientCapabilities'] = clientCapabilitiesJson
    params['_meta'] = meta
    params
}
```

同理，服务端在校验时**统一剥离** `_meta`，交给 handler 的 `params` 里不再包含它——
否则每个工具都要自己处理这个键。

### 4.3 分页

`tools/list` / `resources/list` / `prompts/list` 都支持 `cursor` 分页：

- `listTools()` 返回单页，调用方自己处理 `nextCursor`
- `listAllTools()` 自动翻页，带**总条数与轮次上限**（默认 1000 条 / 100 轮），防止对端无限返回游标

游标是不透明字符串，**不要解析它的内容**，也不要跨服务端复用。

### 4.4 `input_required` 多轮

`tools/call` 可能返回 `resultType: "input_required"`，要求客户端补充输入：

```json
{
  "resultType": "input_required",
  "inputRequests": {
    "github_login": { "method": "elicitation/create", "params": { ... } }
  },
  "requestState": "eyJ..."
}
```

重试时带上 `inputResponses` 与 `requestState`，并且**必须换一个新的 JSON-RPC `id`**（规范明确要求）。
`requestState` 是不透明字符串，客户端不得修改。

`McpClient` 提供两种处理方式：


| 模式                                        | 行为                                                     |
| ------------------------------------------- | -------------------------------------------------------- |
| `onInputRequired: Manual`（**默认**）       | 把`InputRequiredResult` 原样返回给调用方，由它决定怎么补 |
| `onInputRequired: Auto(handler, maxRounds)` | 调 handler 收集输入后自动重试，最多`maxRounds` 轮        |

```cangjie
public enum InputRequiredMode {
    | Manual
    | Auto(handler: (Array<InputRequest>) -> Array<InputResponse>, maxRounds: Int64)
}

public class McpClientOptions {
    public var onInputRequired: InputRequiredMode = InputRequiredMode.Manual
    /// 单次 tools/call 的总超时（含全部重试轮次）
    public var callTimeoutMs: Int64 = 60_000
    /// 单轮重试的超时（不含上一轮的耗时）
    public var roundTimeoutMs: Int64 = 30_000
}
```

**默认 `Manual`**——自动重试会吞掉"需要人介入"的信号，不适合默认打开。

#### 4.4.1 首版只做单轮，多轮可配

**落地策略**：单轮是**必做且必须做扎实**的部分，多轮是**可选开启**的增量能力。


| 阶段 | 内容                                                     | 验收                                                  |
| ---- | -------------------------------------------------------- | ----------------------------------------------------- |
| P1   | `tools/call` 单轮：参数校验、`isError`、三种内容块、超时 | 单轮调用全通；不含任何`input_required` 逻辑           |
| P4   | `input_required`：`Manual` 原样透传 + `Auto` 自动重试    | 两轮/三轮的模拟服务端能跑通；超过`maxRounds` 正确报错 |

**为什么单轮优先**：绝大多数 MCP 工具是无状态的（查数据库、读文件、调 API），
`input_required` 是给"需要用户确认"的场景准备的，出现频率低。把单轮做扎实
（尤其是错误语义与超时），收益远大于提前实现多轮状态机。

#### 4.4.2 多轮状态机的四条硬规则

```
round = 0
loop:
    resp = call(method, params, newId())
    if (resp.resultType != "input_required"):  return resp
    if (round >= maxRounds):                    throw McpException("超过最大重试轮次 ${maxRounds}")
    requests = resp.inputRequests
    responses = handler(requests)               // 可能抛异常 → 直接上抛，不包装
    params.inputResponses = responses
    params.requestState = resp.requestState     // 原样带回，不解析、不修改
    params.id = newId()                         // 规范明确要求换新 id
    round += 1
```

四条规则：

1. **每轮必须换新的 JSON-RPC `id`。** 复用 id 会让服务端把它当作重复请求，或被某些实现去重掉。
2. **`requestState` 原样透传**，不解析、不修改、不比较。它是不透明的服务端状态。
3. **总超时覆盖全部轮次**（`callTimeoutMs`），不是每轮各自计时——否则 3 轮 × 30 秒 = 90 秒，
   调用方以为自己设了 60 秒却等了 90 秒。
4. **handler 抛异常直接上抛**，不转成 `isError`。这是客户端侧的收集逻辑失败，
   不是工具执行失败，语义不同。

**服务端重复索要同一个 `inputRequest` 怎么办**：`Auto` 模式下不做去重检测（判断"同一个"需要比较
`requestState`，而它是不透明的）。超过 `maxRounds` 自然终止。`Manual` 模式下由调用方判断。

---

## 5. 服务端 API

### 5.1 结构

```
McpServer
 ├── McpToolRegistry（工具表）
 ├── McpResourceRegistry（资源表）
 ├── McpCapabilities（能力声明）
 ├── RateLimiter（调用方 × 工具 双层限流）
 └── 绑定到 f_jsonrpc 的 JsonRpcServer（方法：server/discover、tools/list、tools/call、resources/*…）
```

```cangjie
public class McpServer {
    public static func builder(): Builder

    public class Builder {
        public func name(n: String): Builder
        public func version(v: String): Builder
        public func instructions(s: String): Builder
        /// 端点路径，默认 /mcp
        public func path(p: String): Builder

        public func addTool(tool: McpTool, handler: McpToolHandler): Builder
        /// 声明一个资源。**声明了就必须能 read**，build() 时校验（5.6）
        public func addResource(res: McpResource, handler: McpResourceHandler): Builder
        /// list 的默认分页大小，默认 100
        public func pageSize(n: Int64): Builder
        /// 限流策略，见 7.2
        public func rateLimit(policy: RateLimitPolicy): Builder
        /// 对外的 base URL（如 https://kb.example.com）。
        /// 大结果转 resource_link 时用它拼临时资源地址；不配则退化为截断（5.6.6）
        public func publicBaseUrl(url: String): Builder
        /// 临时结果存储与自适应调参。**这是配置 maxEntries / 自适应参数的入口**
        public func resultStore(options: ResultStoreOptions): Builder

        public func build(): McpServer
    }

    /// 交给 f_jsonrpc 的方法表
    public func jsonRpcServer(): JsonRpcServer
    public func capabilities(): McpCapabilities
    /// 释放内部资源（限流桶、临时结果存储的淘汰线程）。**必须调用**
    public func close(): Unit
}
```

**`prompts` 没有对应的 `addPrompt()`**——首版不声明、不实现，理由见 5.4.1。

### 5.2 工具定义

```cangjie
public class McpTool {
    public let name: String                  // 1~128 字符，[A-Za-z0-9_.-]
    public let description: String
    public let inputSchema: JsonObject       // 必须是合法 JSON Schema 对象，不能是 null
    public let handler: McpToolHandler
    /// 该工具的限流覆盖。None = 完全沿用全局策略（7.2.1）
    public let rateLimit: ?ToolRateLimit
    /// 单个工具的结果字节上限，None = 1 MiB
    public let maxResultBytes: ?Int64
}

public type McpToolHandler = (McpToolContext, JsonValue) -> CallToolResult
```

**工具名的硬约束**（规范 SHOULD，但建议直接按 MUST 执行）：


| 规则     | 值                       |
| -------- | ------------------------ |
| 长度     | 1~128                    |
| 允许字符 | `A-Za-z0-9_-.`           |
| 大小写   | 敏感                     |
| 唯一性   | 服务端内唯一             |
| 禁止     | 空格、逗号、其他特殊字符 |

违反这些约束不会立刻报错，但会让客户端的 LLM 无法稳定引用工具。**在 `build()` 时校验并拒绝**，
比上线后被客户端拒绝好。

### 5.3 schema：统一走 `f_data.json.JsonSchema`

**决定：不再"混用手写 schema"。所有 `inputSchema` 都必须是 `JsonSchema` 能表达的对象。**

```cangjie
public class McpToolBuilder {
    /// 方式一：从参数类型自动生成（推荐）
    public static func of<T>(): McpToolBuilder

    /// 方式二：显式给一份 schema 文档（仍需通过 build() 时的 JsonSchema 校验）
    public func inputSchema(schema: JsonObject): McpToolBuilder

    /// 方式三：从外部 JSON 文件加载
    public func inputSchemaFromFile(path: Path): McpToolBuilder

    public func build(): McpTool
}
```

三条路最终都归一成 `JsonObject`，`build()` 时用 `JsonSchema` 校验一遍。

#### 5.3.1 生成与校验用的是同一个 `JsonSchema`

```cangjie
// 生成
let schema = JsonObject.toJsonSchema<SearchParams>()

// 校验入参（f_data 新增，见 f_jsonrpc 4.7）
let result = JsonSchema.validate(schema, params)
if (let Some(err) <- result.error) {
    return JsonRpcError(-32602, "Invalid params", err)
}
```

`JsonSchema` 的两个重载在这里都用得上：


| 重载                                    | 用于                                             |
| --------------------------------------- | ------------------------------------------------ |
| `someSchema.validate(value)`            | 单标量 / 数组等有`properties` 以外约束的场合     |
| `JsonSchema.validate(schemaDoc, value)` | **对象型参数**（`toJsonSchema<T>()` 产出的文档） |

**为什么对象型必须用文档版**：`JsonObjectSchema` **没有 `properties` 字段**——
字段的 schema 是在 `toJsonSchema<T>()` 里从 `mutableFields` 现查出来拼进文档的
（见 `f_jsonrpc模块设计.md` 4.7.1）。所以"从注解对象校验一个带成员的对象"这条路走不通，
必须拿生成的文档来校验。

#### 5.3.2 自动生成的边界

`toJsonSchema<T>()` 反映的是 `f_data` 的字段模型，能表达的约束有限：


| 能表达                                                 | 表达不了（需要手写`JsonObject` 补）          |
| ------------------------------------------------------ | -------------------------------------------- |
| `type` / `properties` / `required`                     | 数值区间（`minimum` / `maximum`）            |
| 基本类型（string / number / boolean / array / object） | 字符串正则（`pattern`）                      |
| 数组`items`                                            | 互斥字段（`oneOf` / `anyOf` / `not`）        |
| 可空（`Option<T>`）                                    | 默认值语义（`default` 只是提示，不影响校验） |
| 嵌套对象（递归）                                       | `enum` 的完整取值集合（部分类型能推出来）    |

表达不了的部分**手写补**，但补完的仍是一份 `JsonObject`，走上表同一套校验。

#### 5.3.3 `$ref` 明确拒绝

`JsonSchema.validate` 不解析 `$ref`（`f_jsonrpc` 4.7 已定）。所以：

- `build()` 时扫描 `inputSchema`，发现任何 `$ref` → **抛异常并指出位置**
- 不接受"运行时才发现不支持"——那是把问题推到生产

```cangjie
throw McpException("inputSchema 含 $ref（/properties/query/$ref），本版本不支持 $ref，请展开定义")
```

#### 5.3.4 无参数的工具

按规范推荐的写法：

```json
{ "type": "object", "additionalProperties": false }
```

不要写 `{ "type": "object" }`——后者接受任意对象，会让客户端误以为可以传参数。

`McpToolBuilder.of<Unit>()` 产生的就是这个。

### 5.4 方法实现清单


| 方法                               | 必须                        | 说明                                                           |
| ---------------------------------- | --------------------------- | -------------------------------------------------------------- |
| `server/discover`                  | ✅ MUST                     | 返回版本、能力、serverInfo；`prompts` 不在 capabilities 里出现 |
| `tools/list`                       | 声明了 tools 就必须         | 支持`cursor`，顺序必须**确定**（同一工具集多次请求顺序一致）   |
| `tools/call`                       | 同上                        | 参数校验（`JsonSchema.validate`）、超时、错误包装              |
| `resources/list`                   | **声明了 resources 就必须** | 支持`cursor`，顺序确定                                         |
| `resources/read`                   | **同上（与 list 成对）**    | 返回`contents[]`；不存在的 URI → `-32040`，不是空数组         |
| `prompts/list` / `prompts/get`     | ✅ 已实现                   | 能力声明含 `prompts`；未知 prompt / 缺必填参数返回 `-32602`    |
| `subscriptions/listen`             | ✅ 已实现                   | 返回 `subscriptionId` + `sseUrl`；SSE 按 `subscriptionId` 绑定 |
| `notifications/tools/list_changed` | ✅ 可发                     | `SubscriptionHub.publish` 发布；demo 的 `notify` 工具触发        |

`tools/list` 的**确定性排序**容易被忽略：规范要求"同一工具集在多次请求间顺序一致"，
理由是客户端会缓存工具列表、LLM 的 prompt cache 也依赖稳定前缀。用 `HashMap` 遍历顺序会漂，
必须显式排序（按 name 字典序）。`resources/list` 同理，按 `uri` 字典序。

#### 5.4.1 能力声明原则：不声明空壳

**规则：capabilities 里出现的每一项，都必须有完整的实现（列表 + 读取 + 分页 + 错误语义）。**

理由很直接：客户端看到 `resources: {}` 就会去调 `resources/list`。
如果返回空列表，客户端无法区分"这个服务端没有资源"和"这个服务端实现了但没数据"；
如果返回 `-32601`，那是**协议不一致**，比不声明恶劣得多。

**首版的三项取舍**：


| 能力        | 决定                                 | 理由                                                           |
| ----------- | ------------------------------------ | -------------------------------------------------------------- |
| `tools`     | ✅ 声明并完整实现                    | 核心能力                                                       |
| `resources` | ✅**声明并完整实现 `list` + `read`** | 知识库场景的核心诉求就是"把文档暴露给 LLM"，只做 list 没有意义 |
| `prompts`   | ❌**完全不声明**                     | 首版不实现。不声明就是"我没有这个能力"，客户端不会来探         |

`capabilities` 的实际形态：

```json
{
  "tools": { "listChanged": false },
  "resources": { "subscribe": false, "listChanged": false }
}
```

**没有 `prompts` 键**。这比 `"prompts": {}` 更明确——后者容易被误读成"有 prompts，只是暂时为空"。

### 5.5 结果构造

```cangjie
public class CallToolResult {
    public let content: ArrayList<ContentBlock>
    public let structuredContent: ?JsonValue
    public let isError: Bool
}
```

`ContentBlock` 的五种形态：


| type            | 字段                                          |
| --------------- | --------------------------------------------- |
| `text`          | `text`                                        |
| `image`         | `data`（base64）、`mimeType`                  |
| `audio`         | `data`（base64）、`mimeType`                  |
| `resource`      | `resource: { uri, mimeType?, text? / blob? }` |
| `resource_link` | `uri`、`name`、`description?`、`mimeType?`    |

两个规范细节：

1. **业务失败用 `isError: true`，不要抛 JSON-RPC 错误。** 工具执行失败（比如"文件不存在"）
   是**工具结果**，不是协议错误。抛 `-32603` 会让客户端以为服务端坏了。
   JSON-RPC 错误只用于"请求本身不合法"（未知方法、参数结构错）。
2. **返回 `structuredContent` 时，同时把它的序列化文本放进一个 `text` 块。**
   规范这么建议是为了向后兼容——老客户端只认 `content`。

---

### 5.6 resources：list 与 read 成对实现

**决定：`resources/list` 和 `resources/read` 一起做，不做"只有 list 没有 read"的半截实现。**

理由：只有 list 的话，客户端能看见资源却读不到内容，等于给了一个永远打不开的目录。
这比完全不声明 resources 更糟——用户会以为是权限问题或服务端故障。

#### 5.6.1 数据模型

```cangjie
public class McpResource {
    /// 资源标识。必须是合法 URI（RFC 3986），**不得含 fragment**。
    /// **scheme 只接受 http / https / ftp**（见 5.6.1）
    public let uri: String
    /// 人类可读名，用于 UI 展示
    public let name: String
    public let description: String
    /// MIME 类型，如 "text/markdown"、"application/pdf"
    public let mimeType: ?String
    public let handler: McpResourceHandler
}

public class ResourceContent {
    public let uri: String
    public let mimeType: ?String
    /// 文本内容。与 blob **二选一**
    public let text: ?String
    /// 二进制内容。协议层自动 base64
    public let blob: ?Array<Byte>
}

public type McpResourceHandler = (String) -> ResourceContent
```

#### 5.6.1.1 URI scheme 白名单：只接受 http / https / ftp

**规则：完整 `uri` 的 scheme 必须是 `http`、`https`、`ftp` 三者之一，其余一律 `-32602`。**

也允许以 `/` 开头的绝对路径（如 `/doc`）：构建 `McpServer` 时用 `publicBaseUrl`（`Builder.publicBaseUrl()` 或 `mcp_publicBaseUrl`）补全成完整 URL；未配置 `publicBaseUrl` 时构建失败。`//host/path` 这类协议相对地址仍然拒绝。


| scheme                            | 接受 | 理由                                                                                      |
| --------------------------------- | ---- | ----------------------------------------------------------------------------------------- |
| `http` / `https`                  | ✅   | 通用；服务端自己托管的资源、以及 handler 主动抓取的远程文档都用它                         |
| `ftp`                             | ✅   | 老系统遗留的文件服务器仍常见                                                              |
| `file`                            | ❌   | **等于把服务端文件系统暴露给客户端**。`file:///etc/passwd` 一旦被 `read` 就是任意文件读取 |
| `data`                            | ❌   | 不需要——内容可以直接放`text` / `blob`                                                   |
| `javascript` / `vbscript`         | ❌   | 客户端渲染层的 XSS 载体                                                                   |
| 自定义 scheme（`kb://`、`s3://`） | ❌   | 客户端不认识，`resource_link` 点不开；见下方说明                                          |

**为什么连 `kb://` 也拒绝**：MCP 的 `resource_link` 会被客户端的 UI 直接渲染成可点击链接。
自定义 scheme 在没有注册协议处理器时点了没反应，用户体验是"坏链接"。
要用自定义标识，走 `https://your-host/kb/{id}`——既能点开，也能被 `resources/read` 处理。

**校验点**（三处都要校验，不能只在 read 里查）：

```cangjie
func validateUri(uri: String): Unit {
    let parsed = Uri.parse(uri) ?? throw McpException("-32602", "非法 URI: ${uri}")
    if (parsed.fragment != None) {
        throw McpException("-32602", "URI 不得含 fragment: ${uri}")
    }
    match (parsed.scheme.toLowerCase()) {
        case "http" | "https" | "ftp" => ()
        case other => throw McpException("-32602", "不支持的 URI scheme '${other}'，只允许 http/https/ftp")
    }
}
```


| 位置                        | 校验什么                                      |
| --------------------------- | --------------------------------------------- |
| `addResource()` / `build()` | 注册时就拒绝，不留到运行期                    |
| `resources/read` 入参       | 客户端传来的 URI 可能不来自`list`，必须再校验 |
| `resource_link` 产出        | 保证自己生成的东西符合同一套规则              |

**`build()` 时校验而不是运行期校验**，理由与工具名一致（5.2）：上线后才发现比构建时发现贵得多。

#### 5.6.2 两个方法的形态

**`resources/list`**

```json
// 请求
{ "jsonrpc": "2.0", "id": 1, "method": "resources/list",
  "params": { "cursor": "eyJvZmZzZXQiOjEwMH0=", "_meta": { } } }

// 响应
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "resultType": "complete",
    "resources": [
      { "uri": "https://kb.example.com/docs/001", "name": "产品手册", "mimeType": "text/markdown", "size": 20480 }
    ],
    "nextCursor": "eyJvZmZzZXQiOjIwMH0="
  }
}
```

**`resources/read`**

```json
// 请求
{ "jsonrpc": "2.0", "id": 2, "method": "resources/read",
  "params": { "uri": "https://kb.example.com/docs/001", "_meta": { } } }

// 响应（文本）
{
  "jsonrpc": "2.0", "id": 2,
  "result": {
    "resultType": "complete",
    "contents": [
      { "uri": "https://kb.example.com/docs/001", "mimeType": "text/markdown", "text": "# 产品手册\n..." }
    ]
  }
}

// 响应（二进制，协议层 base64）
{
  "result": {
    "resultType": "complete",
    "contents": [
      { "uri": "https://kb.example.com/docs/002", "mimeType": "application/pdf", "blob": "JVBERi0xLjQK..." }
    ]
  }
}
```

**`contents` 是数组，不是单个对象。** 一个逻辑资源可以拆成多段返回
（分页的扫描件、一本书的多个章节）。客户端必须能处理多段。

#### 5.6.3 错误语义


| 情况                                   | 返回                                                     |
| -------------------------------------- | -------------------------------------------------------- |
| URI 不在资源表里                       | **`-32040`**（Resource not found），`data.uri` 带原值、`data.reason = "unknown"` |
| URI 格式非法（不是 URI、含 fragment）  | `-32602`（Invalid params）                               |
| handler 内部抛异常                     | `-32603`（Internal error），消息脱敏（不回显堆栈）       |
| 结果超过`maxResultBytes`               | 截断 +`data.truncated = true`，并记 warning（见 7.2.4）  |

**不存在就是错误，不是空数组。** 返回 `contents: []` 会让客户端以为"这个资源是空的"，
而实际是"没有这个资源"。

#### 5.6.4 明确不做


| 特性                                   | 决定                                                | 理由                                                                               |
| -------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `resources/subscribe`                  | ❌ 不做，`capabilities.resources.subscribe = false` | SSE 已实现；未实现的是逐资源 `resources/subscribe` / `unsubscribe`                 |
| `resources/templates/list`             | ❌ 不做                                             | URI 模板（`https://kb.example.com/docs/{id}`）需要额外一套匹配引擎，首版用扁平列表 |
| `notifications/resources/list_changed` | ❌ 不发                                             | `listChanged: false`；资源表在 `build()` 后冻结                                    |
| 资源内容缓存                           | ❌ 不做                                             | 由 handler 自己决定（它可以查`f_store` 的缓存）                                    |

#### 5.6.5 `build()` 时的校验

```cangjie
// 每个资源都要过这三条，否则 build() 抛异常
1. uri 非空、能解析为 URI、不含 '#' 片段
2. uri 全局唯一（重复注册直接报错，不"后者覆盖"）
3. handler 不为 null
```

第 2 条尤其重要：重复 URI 会让 `read` 的行为取决于哈希顺序，是不可复现的 bug。

#### 5.6.6 大结果一律转 `resource_link`

**决定：`tools/call` 的结果超过 `maxResultBytes` 时，一律转成 `resource_link`——文本也一样，不再截断。**

上一版是"文本截断、二进制转 link"。这个分裂有问题：

- 截断后的文本**丢了数据**，而且调用方看不出丢了哪部分（只看到一个 `[truncated]` 标记）
- 同一个工具可能因为参数不同而走两条路径，LLM 看到的形态不稳定
- `resource_link` 本来就是为了"结果太大，按需取"设计的，文本没有理由不用

#### 5.6.6.1 临时结果资源

```
1. 工具返回的 content 总大小 > maxResultBytes
2. 服务端生成 token = 随机 16 字节（base64url）
3. 把结果整体序列化后存进 ToolResultStore（自管理，TTL 10 分钟，见 5.6.6.2）
4. 返回单个 resource_link：
     {
       "type": "resource_link",
       "uri": "{publicBaseUrl}/mcp/tool-results/{token}",
       "name": "{toolName} 的完整结果",
       "description": "结果共 {n} 字节，超过 {maxResultBytes} 字节上限",
       "mimeType": "application/json"   // 或 text/plain
     }
5. 客户端随后调 resources/read 取回
```

`publicBaseUrl` 是服务端构造时必须给的（5.1 的 Builder）。它是服务端**对外可见**的地址，
不是监听地址——反向代理后面的服务端，监听 `0.0.0.0:8080` 但对外是 `https://kb.example.com`。

**没配 `publicBaseUrl` 时怎么办**：降级为截断 + `data.truncated = true` + 一条 warning。

```
McpWarning("未配置 publicBaseUrl，大结果只能截断。生产环境请配置，以便转 resource_link")
```

**不报错。** 配置缺失不该让工具执行失败——调用方至少能拿到截断版。

#### 5.6.6.2 临时结果存储：不用 `HeapCache`，自己管三个维度

**问题**：能不能用 `f_cache.HeapCache` 存临时结果，外部维护一个 `totalBytes` 总和？

**不能。外部记的总和一定会失准。** 三个源码依据：

1. **主动 `remove()` 不触发 `evictionCallback`。** `HeapCache.remove` 的实现是
   `store.remove(key)?.load()`，退出队列只在 `checkOverSize` 淘汰时投递。
2. **`clear()` 也不触发。** 整表清空时外部完全不知道。
3. **回调是异步的。** `evictionQueue` 由独立的消费线程处理，外部总和在回调到达前是偏大的。

也就是说，只要有一次主动删除或清空，`totalBytes` 就永久偏大——之后所有 put 都会被误判成"预算不足"。

**所以三个维度（条数 / 总字节 / TTL）必须由同一个组件持有，才能保持一致。**

```cangjie
class ToolResultStore <: Resource {
    private class Entry {
        let content: ResourceContent
        let bytes: Int64              // 估算占用
        let expireAtNanos: Int64
    }

    private let map = ConcurrentHashMap<String, Entry>()
    private let maxEntries: Int64                 // 500
    private let maxBytes: Int64                   // 256 MB
    private let ttlNanos: Int64                   // 10 分钟
    private let budget: ByteBudget                // 剩余字节的预算池
    private let count = AtomicInt64(0)
    private let closedFlag = AtomicBool(false)

    // —— 统计（供自适应调容使用，见 5.6.6.5）——
    private let statPutOk = AtomicInt64(0)
    private let statRejectedByCount = AtomicInt64(0)     // 条数满
    private let statRejectedByBytes = AtomicInt64(0)     // 字节满
    private let statHit = AtomicInt64(0)
    private let statMiss = AtomicInt64(0)
}
```

##### 字节预算用 CAS 预留，不用"先加后回滚"

```cangjie
class ByteBudget {
    /// 剩余可用字节。初始值 = maxBytes
    private let remaining: AtomicInt64

    /// 预留 n 字节。失败说明预算不够
    func tryReserve(n: Int64): Bool {
        var cur = remaining.load()
        while (true) {
            if (cur < n) { return false }
            let prev = remaining.compareAndSwap(cur, cur - n)
            if (prev == cur) { return true }      // CAS 成功
            cur = prev                             // 被别人改了，重读重试
        }
    }
    func release(n: Int64): Unit { remaining.fetchAdd(n) }
    func available(): Int64 { remaining.load() }
}
```

**为什么用 CAS 预留而不是"先 fetchAdd 再检查再 fetchSub"**：后者在超限时要回滚，
回滚期间其他线程可能已经看到超限并失败——相当于一次假的拒绝对。CAS 预留**永不超过上限**，
且不需要回滚路径。

##### `put`：三重检查，全部满足才写入

```
put(key, content):
  bytes = estimateBytes(content)
  if (bytes > maxBytes):
      statRejectedByBytes.fetchAdd(1)                     // 单条就超过总预算
      return false

  // ① 条数
  if (count.load() >= maxEntries):
      sweep()                                             // 先回收过期的
      if (count.load() >= maxEntries):
          statRejectedByCount.fetchAdd(1)                 // ← 只有这里算"条数不够"
          return false

  // ② 字节
  if (!budget.tryReserve(bytes)):
      sweep()                                             // 预算不够，回收过期的再试
      if (!budget.tryReserve(bytes)):
          statRejectedByBytes.fetchAdd(1)
          return false

  // ③ 写入
  map.put(key, Entry(content, bytes, nowNanos() + ttlNanos))
  count.fetchAdd(1)
  statPutOk.fetchAdd(1)
  maybeEvaluateCapacity()                                 // 惰性评估，见 5.6.6.5
  return true
```

**两个拒绝计数器必须分开**，否则自适应会误判（详见 5.6.6.5）。这是本节唯一的"看起来多余但必须有"的实现约束。

**`put` 返回 `false` 时**，调用方（5.6.6.1 的流程）退化为"截断 + warning"，
而不是让工具失败。原因：结果是工具的真实产出，存不下也不该丢掉整个调用。

##### `get`：惰性过期，按 `remove` 的返回值决定是否记账

```
get(key):
  match (map.get(key)) {
    case Some(e) where nowNanos() < e.expireAtNanos:
        return Some(e.content)
    case Some(e):
        // 过期。只有 remove 真的删掉了才减账
        if (let Some(removed) <- map.remove(key)):
            budget.release(removed.bytes)
            count.fetchSub(1)
        return None
    case None:
        return None
  }
```

**必须用 `remove` 的返回值判断**，不能让"发现过期"和"减账"分开：

```cangjie
// 错误：两个线程同时发现过期，会重复 release，预算被放大
if (now >= e.expireAt) { budget.release(e.bytes); map.remove(key) }

// 正确：只有真正删掉的那个线程减账
if (let Some(removed) <- map.remove(key)) { budget.release(removed.bytes) }
```

##### `sweep`：只在压力时触发，不加后台线程

```cangjie
/// 遍历回收过期条目，返回回收条数
func sweep(): Int64 {
    var n = 0
    let now = nowNanos()
    for ((k, e) in map) {
        if (now >= e.expireAtNanos && let Some(removed) <- map.remove(k)) {
            budget.release(removed.bytes)
            count.fetchSub(1)
            n++
        }
    }
    n
}
```

**调用时机只有两个**：`put` 时条数满、`put` 时预算不足。没有定时器，没有后台线程。

##### 为什么"不做后台清理"反而是好事

常见的直觉是"空闲时就该把过期的清掉，省内存"。但对这个场景，**留着更好**：

```
白天：LLM 反复读同一批文档 → 结果对象被反复取用
夜间：没有请求 → 条目过期，但没人来取
次日：LLM 又问同样的问题 → 如果条目还在，直接命中；如果夜里清了，要重跑工具
```

**"过期"只应该决定"还能不能取"，不应该决定"要不要现在就扔"。**
如果服务是空闲的，那点内存本来也没别人用；等它忙起来，这些还是热数据。
反过来，忙的时候内存紧张，`put` 时的 `sweep()` 会按需回收——**清理压力和内存压力同步**，
这才是对的时机。

代价是"最多占着 `maxBytes`"：256 MB 在服务器上可接受，在手机上要调小
（通过构造参数，不是硬编码）。

**如果确实需要主动清理**，`McpServer` 暴露 `purgeExpiredResults(): Int64`，
由外部定时任务按需调用（比如内存告警时）。**不进默认路径。**

##### `estimateBytes`：按字段累加，不用 sizeof

```cangjie
func estimateBytes(c: ResourceContent): Int64 {
    var n = 64                                        // 对象头 + 4 个字段槽
    n += c.uri.size                                   // String.size 是 UTF-8 字节数
    n += c.mimeType?.size ?? 0
    n += c.text?.size ?? 0
    n += c.blob?.size ?? 0
    n
}
```

误差约 ±10%（`ConcurrentHashMap` 的节点开销、`Entry` 对象的额外字段），
对"内存预算"这个用途足够——真正要防的是"存了 2 GB 结果"，不是精确到字节。

##### 参数与生命周期

| 项 | 值 | 理由 |
|---|---|---|
| `maxEntries` | **256** | **主约束**。256 × 1 MB = 256 MB，正好对上字节上限 |
| `maxBytes` | 256 MB | 兜底。`maxResultBytes` 被调大时它会先触发，这是正确保护 |
| TTL | 10 分钟 | LLM 拿到 link 后通常几秒内就取 |
| 取出后是否删除 | **不删** | 客户端可能重试；靠 TTL 自然过期 |
| 服务重启 | 全丢 | 内存存储。`resource_link` 本来就是短生命周期 |
| 后台清理线程 | **无** | 惰性 + 压力触发（见下） |

**为什么 256 而不是 500**：目标是让**条数**成为主约束，这样"最多能存多少条"是可预期的上限。
`maxResultBytes = 1 MB` 时单条最多 1 MB，256 × 1 MB = 256 MB 正好等于字节上限——
两个闸门在同一位置，谁先触发都一样。若调用方把 `maxResultBytes` 调到 4 MB，
字节上限会先触发（256 × 4 MB = 1 GB > 256 MB），这正是我们想要的保护。

**两个上限都要有**：只限条数会让"每条都接近 1 MB"吃掉 500 MB；只限字节会让
"每条都几十字节"产生几十万个 map 节点（节点本身的开销被 `estimateBytes` 低估）。

**为什么不做持久化**：临时结果的价值窗口只有分钟级。落盘要处理清理、并发、损坏，
收益只是"服务重启后还能取到 10 分钟前的结果"，几乎没人需要。

#### 5.6.6.3 `resources/read` 如何处理自己生成的临时链接

`resources/read` 收到 `{publicBaseUrl}/mcp/tool-results/{token}` 时：

```cangjie
1. 前缀匹配 publicBaseUrl + "/mcp/tool-results/"
2. 提取 token，查 resultStore
3. 命中 → 返回 ResourceContent（原 MIME 类型）
4. 未命中/已过期 → -32040 + data.reason = "expired"
```

这一步由 f_mcp **内置的 handler 处理，优先于用户注册的资源**。用户不能注册同前缀的 URI
（`build()` 时校验并拒绝）。

**`data.reason = "expired"`** 让客户端能区分"这个链接过期了"和"这个 URI 根本不存在"。

#### 5.6.6.4 与 `maxResultBytes` 的关系

```cangjie
public class RateLimitPolicy {
    /// 单次结果大小阈值。超过则转 resource_link（不再截断）。默认 1 MB
    public var maxResultBytes: Int64 = 1024 * 1024
    ...
}
```

`maxResultBytes` 是**阈值**，不是**硬限制**：

| 结果大小 | 行为 |
|---|---|
| ≤ 1 MB | 内联在 `content` 里 |
| > 1 MB，配了 `publicBaseUrl` | 转 `resource_link`（单块） |
| > 1 MB，没配 `publicBaseUrl` | 截断 + `data.truncated = true` + warning |

**默认 1 MB 的理由**：转 link 意味着客户端要多一次往返。256 KB 太小——很多
"结构化查询结果 + 一段说明文本"就在 300~800 KB，这类结果客户端**一定会读**，
让它们多一跳是纯浪费。1 MB 能覆盖绝大多数正常结果，只在真正"大"时才走 link。

**按工具覆盖**：`ToolRateLimit.maxResultBytes` 可以单独设。例如"导出全表"类工具设 64 KB
（反正一定要走 link，早点转），"查详情"类设 4 MB（一次读完更省往返）。

**单块的结果超限时只产生一个 link**，不是"每个 content block 一个 link"——
工具结果是一个整体，拆开会让语义断裂。

#### 5.6.6.5 运行期自适应调容（**默认开启**）

**问题**：`maxEntries = 256` 是拍的。既然拍不准，就别把它当固定值——**让它自己找。**

**结论：默认开启。** `maxEntries` 是**起点**而不是"配置值"，运行期会按实际负载调。

##### 5.6.6.5.1 只能调 `maxEntries`，不能调 `maxBytes` 和 TTL

| 参数 | 能否自动调 | 理由 |
|---|---|---|
| `maxEntries` | ✅ **能** | "使用体验"参数：调大只是多留几条结果 |
| `maxBytes` | ❌ **不能** | **内存安全参数**。因为"结果被拒多了"就悄悄多占 100 MB，是拿稳定性换体验，运维再也说不清进程会吃多少内存 |
| `TTL` | ❌ **不能** | **业务语义**（"LLM 几秒内会来取"）。过期规则变了，`-32040 expired` 的含义也变了 |

**这条边界很重要**：自动调"条数"是优化体验，自动调"字节"是偷偷扩大内存占用。

##### 5.6.6.5.2 两种拒绝必须分开统计

整个自适应逻辑能不能成立，取决于这一条：

```
put 失败时：
  if (count >= maxEntries)        → rejectedByCount++
  else if (!budget.tryReserve())  → rejectedByBytes++
```

**混在一起会变成死循环**：

```
条数先满（256 条）→ 自适应调大到 320
→ 但 320 × 1 MB = 320 MB > 256 MB，字节先满
→ 还是拒，继续调到 400、500……直到撞 ceiling
→ 全程无效，还白折腾
```

只看 `rejectedByCount` 就不会：一旦主因变成字节，这个计数器归零，自适应自然停。

##### 5.6.6.5.3 完整配置项（9 项，全部可配）

**没有写死的魔数。** 下面每一项都是 `ResultStoreOptions` 的具名参数，通过
`Builder.resultStore()` 传入；自适应参数平铺在同一个结构里，没有单独的策略类型。

```cangjie
public struct ResultStoreOptions {
    public const ResultStoreOptions(
        public let maxEntries!: Int64 = 256,               // 起始容量，运行期可被自适应调整
        public let maxBytes!: Int64 = 256 * 1024 * 1024,   // 字节硬上限，不自动调
        public let ttlMillis!: Int64 = 10 * 60 * 1000,     // 过期时间，不自动调
        public let adaptive!: Bool = true,                 // false 退回固定容量
        public let windowMillis!: Int64 = 5 * 60 * 1000,   // 评估窗口
        public let rejectRateThreshold!: Float64 = 0.01,   // 拒绝率阈值
        public let floor!: Int64 = 128,                    // 可调下界
        public let ceiling!: Int64 = 1024,                 // 可调上界
        public let shrinkConfirmWindows!: Int64 = 3) {}    // 连续多少个空闲窗口才缩容
}
```

**配置项速查表**（含"什么时候该改"）：

| # | 配置项 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|---|
| 1 | `maxEntries` | 256 | 当前生效容量（自适应会改它） | 已知量级时直接给准值（自适应就没多少活干） |
| 2 | `maxBytes` | 256 MB | 字节硬上限 | 单条结果大 / 需要并存更多条 |
| 3 | `ttlMillis` | 10 min | 过期时间 | 客户端取结果慢（如移动网络） |
| 4 | `adaptive` | `true` | 传 `false` 关闭自适应 | 压测、容量规划、需要绝对可预测 |
| 5 | `floor` | 128 | 调容下界 | 不愿缩太小 / 日周期业务 |
| 6 | `ceiling` | 1024 | 调容上界 | 峰值很高 |
| 7 | `windowMillis` | 5 min | 评估窗口 | 想更快/更慢响应 |
| 8 | `rejectRateThreshold` | 0.01 | 触发调大的拒绝率 | 对结果完整性敏感就调低（0.001） |
| 9 | `shrinkConfirmWindows` | 3 | 调小需连续窗口数 | 业务有周期性就调大（5~6） |

调大步长固定 25%、调小步长固定 12.5%、两次调整之间至少间隔一个评估窗口——这三项是
实现内常量，不作为配置项暴露。

**传入方式**：

```cangjie
McpServer.builder()
    .resultStore(ResultStoreOptions(
        maxEntries: 512,                                  // 起点给准一点
        maxBytes: 512 * 1024 * 1024,
        floor: 256,
        ceiling: 2048,
        rejectRateThreshold: 0.001,                       // 对截断更敏感
        shrinkConfirmWindows: 6                           // 夜间不轻易缩
    ))
    .build()
```

**为什么把可调区间叫 `floor` / `ceiling`**：如果也叫 `minEntries` / `maxEntries`，
就会和外层的 `maxEntries`（当前生效值）撞名——三个 `maxEntries` 在同一上下文里，
读代码的人根本分不清哪个是"现在用的"、哪个是"能调到多高"。

| 名字 | 含义 |
|---|---|
| `ResultStoreOptions.maxEntries` | **当前生效值**，运行期会变 |
| `ResultStoreOptions.floor` | 可调区间的**下界**，不会低于它 |
| `ResultStoreOptions.ceiling` | 可调区间的**上界**，不会高于它 |

##### 5.6.6.5.4 非对称策略：调大敏捷，调小迟钝

这是防止震荡的核心，不能用同一套规则双向调。

| | 调大 | 调小 |
|---|---|---|
| 触发条件 | 窗口内 `rejectRate > 1%` | **连续 3 个**窗口占用 < 25% |
| 步长 | 25% | **12.5%** |
| 冷却 | 5 分钟 | 5 分钟 |
| 原因 | 结果被截断是**功能损失** | 多占内存只是**资源浪费** |

**为什么不对称**：

- **调大慢的代价大**：每一次"拒绝"都意味着一个工具结果被迫截断，客户端只能拿到
  `data.truncated = true` 的残版。这是功能可用性问题。
- **调小快的代价大**：调小后马上遇到峰值，会连续拒绝。而且"日周期"场景
  （白天忙、夜里闲）下，如果调小反应太快，每天都要经历一次"低谷缩容 → 高峰不够 → 涨回来"，
  永远在震荡。

**`shrinkConfirmWindows = 3` 是专门为日周期设的**：一个窗口 5 分钟，连续 3 个 = 15 分钟。
如果业务是"午休 1 小时没人用"，那 1 小时足够触发 12 次确认——还是会缩。

**所以再加一条**：调小只在"当前值明显高于实际需要"时才做——

```
if (occupancy < 0.25               // 占用率阈值是常量
    && w.rejectedByCount == 0
    && w.rejectedByBytes == 0          // ← 字节也没压力
    && consecutiveIdleWindows >= shrinkConfirmWindows
    && maxEntries > floor):
    shrink
```

加上 `rejectedByBytes == 0` 这一条的作用：如果字节闸门一直在挡（说明实际需求很旺），
即使条数占用低，也不该缩——因为缩了之后字节问题还在，条数更不够。

##### 5.6.6.5.5 决策流程

```
put 成功后调 maybeEvaluateCapacity()：

  if (now - lastEval < evaluationWindow):  return
  lastEval = now

  // 用"两次快照差值"算窗口统计，**不清零**计数器（清零会丢数）
  w = currentStats - lastStatsSnapshot
  lastStatsSnapshot = currentStats

  totalPuts = w.putOk + w.rejectedByCount + w.rejectedByBytes
  if (totalPuts < 20):  return                    // 样本太少，不动

  rejectRate = Float64(w.rejectedByCount) / Float64(totalPuts)
  occupancy  = Float64(count.load()) / Float64(maxEntries)

  if (w.rejectedByBytes > 0):                     // 字节闸门在挡：说明需求很旺，不缩
      shrinkStreak = 0
      return hold

  if (rejectRate > options.rejectRateThreshold && maxEntries < options.ceiling):
      target = min(options.ceiling, maxEntries + max(1, maxEntries / 4))   // +25%
      return grow

  if (occupancy < 0.25 && maxEntries > options.floor):
      shrinkStreak += 1
      if (shrinkStreak >= options.shrinkConfirmWindows):
          target = max(options.floor, maxEntries - max(1, maxEntries / 8)) // -12.5%
          return shrink
      return hold(idle_pending)

  shrinkStreak = 0
  return hold
```

评估本身按 `windowMillis` 限频：窗口未到期时只有一次原子读，不抢锁、不计算。

##### 5.6.6.5.6 日志：两个级别，各管一件事

**核心诉求**：让开发者能"看日志 → 决定下次启动的配置值"。所以**不能只记调整**，
必须把"每个窗口的评估详情"也记下来。

| 级别 | 时机 | 内容 | 建议 |
|---|---|---|---|
| **`debug`** | **每个评估窗口一条**，哪怕什么也没做 | 全量统计 + 阈值 + 决策 + **未调整的原因** | 调参期打开，稳定后关闭 |
| **`info`** | **实际发生调整时** | 调整前后值 + 触发依据 | 始终开启（行为变了，必须留痕） |

**为什么 `debug` 要记"没调整"的窗口**：开发者要判断"阈值是不是太松"，
必须看到"实际拒绝率 0.8%，阈值 1.00%"这种细节。只记调整的话，
一个从不调整的系统看起来像"没在工作"，实际可能是"阈值定得太宽"。

##### 格式：单行 `key=value`

固定前缀 `mcp.resultstore.eval`，字段顺序固定，便于 `grep` / `awk` / 导入日志分析。

```
mcp.resultstore.eval window_s=300 puts=120 put_ok=117 rej_count=3 rej_bytes=0 \
  reject_rate=0.0250 reject_threshold=0.0100 occupancy=0.941 count=241 \
  max_entries=256 budget_used_mb=157.8 budget_total_mb=256.0 idle_windows=0 \
  shrink_confirm=3 total_puts=8420 total_rej_count=31 \
  decision=grow new_max_entries=320 reason="reject_rate 2.50% > 1.00%"
```

**写日志时不要真的换行**（上面用 `\` 是为了文档排版）。实际是一行，
因为多行日志在 grep 与日志聚合系统里难以关联。

##### 字段说明

| 字段 | 含义 |
|---|---|
| `window_s` | 本次评估覆盖的秒数（通常等于 `evaluationWindow`） |
| `puts` | 窗口内 `put` 总次数（= `put_ok + rej_count + rej_bytes`） |
| `put_ok` | 成功写入数 |
| `rej_count` | **因条数满被拒**（触发调大的唯一信号） |
| `rej_bytes` | 因字节满被拒（**不触发调大**，说明该调 `maxBytes`） |
| `reject_rate` | `rej_count / puts` |
| `reject_threshold` | 当前 `rejectRateThreshold`（打印出来才好对比） |
| `occupancy` | `count / max_entries` |
| `count` / `max_entries` | 当前条数与当前生效上限 |
| `budget_used_mb` / `budget_total_mb` | 字节预算的已用 / 总量 |
| `idle_windows` | 连续空闲窗口计数（当前值 / 阈值见 `shrink_confirm`） |
| `shrink_confirm` | 当前 `shrinkConfirmWindows` |
| `total_puts` / `total_rej_count` | **进程启动至今**的累计值 |
| `decision` | `grow` / `shrink` / `hold` |
| `new_max_entries` | 仅 `grow` / `shrink` 时有 |
| `reason` | 决策依据（人类可读） |

##### `hold` 的 reason 分类

`decision=hold` 时，`reason` 只能是下面几种之一（便于统计分布）：

| reason | 含义 | 说明 |
|---|---|---|
| `sample_too_small` | 窗口内 `puts < 20` | 样本不足，不动 |
| `cooldown` | 距上次调整不足 `cooldown` | 防抖 |
| `below_threshold` | `reject_rate` 未达阈值 | **这是最需要关注的**——可能阈值太松 |
| `idle_pending` | 空闲窗口数不足（如 `1/3`） | 正常，继续观察 |
| `at_floor` | 已在 `floor` | 不再缩 |
| `at_ceiling` | 已在 `ceiling` | 不再涨 |
| `bytes_bound` | `rej_bytes > 0`，字节是瓶颈 | **该调 `maxBytes`，不是 `maxEntries`** |

##### 怎么用日志定参数：四个典型场景

**场景 A：`reason="below_threshold"` 长期出现，`reject_rate` 稳定在 0.3%~0.8%**

```
decision=hold reason="below_threshold"   reject_rate=0.0060 reject_threshold=0.0100
```

阈值定得太宽，自适应从不介入。两条路：
- 降到 `rejectRateThreshold: 0.001`，让它更早涨
- 或者承认"256 够用"，把 `floor` 提到 256（永不缩，也就不会缺）

**场景 B：`reason="at_ceiling"` 频繁出现，且 `rej_bytes > 0`**

```
decision=hold reason="bytes_bound" rej_count=0 rej_bytes=15 occupancy=1.000
```

**这不是条数问题。** `maxEntries` 已经涨到 `ceiling`，但字节闸门先满了。
该调的是 `maxBytes`（人工决定，见 5.6.6.5.1 的边界）。

**场景 C：`idle_windows` 反复在 `0 → 1 → 2 → 0` 之间跳**

业务有周期性（比如每小时有一条空闲带）。`shrinkConfirmWindows` 提到 5 或 6，
让调小更难触发。

**场景 D：`occupancy` 长期 0.1，`rej_count=0`，`decision=shrink`**

正常，它在省内存。如果希望"永远留够余量"，把 `floor` 提到 256 或更高。

##### `info` 日志：只记实际调整

```
mcp.resultstore.adjust max_entries 256 -> 320 reason="reject_rate 2.50% > 1.00%" window_puts=120
mcp.resultstore.adjust max_entries 320 -> 280 reason="occupancy 0.18 < 0.25 for 3 windows"
```

**每次调整都必须是 `info`**，理由：调整改变了系统行为，运维复盘时必须能看到。
如果只在 `debug` 级别，生产环境关掉 debug 后就完全查不到"什么时候变的、为什么变的"。

##### 字段的稳定性承诺

`mcp.resultstore.eval` 的**字段名一旦发布不轻易改**。理由：日志会被采集、
建索引、做面板。改字段名等于让历史数据与新数据无法对比。

要加字段可以（追加在末尾），要改名必须同时提供新旧两个字段一段时间。

##### 与 `f_log` 的配合

```cangjie
Log.debug("mcp.resultstore.eval ...", tag: "mcp.resultstore")
Log.info("mcp.resultstore.adjust ...", tag: "mcp.resultstore")
```

用统一的 `tag`，这样调参期只需要打一个 tag 的 debug 就能看到全部评估记录。

---

##### 5.6.6.5.7 调小不驱逐

```
adjustTo(newValue, reason):
    let old = maxEntries
    maxEntries = newValue
    lastAdjust = now
    consecutiveIdleWindows = 0
    Log.info("tool-result store: maxEntries ${old} -> ${newValue} (${reason})")
```

**调小时绝不主动删现有条目**：

- 现有条目可能正被客户端读取（`resource_link` 已发出）
- 突然删掉会让那些 link 变 404，比"以后少存几条"糟得多
- 调小的影响自然体现在"后续 put 更容易被拒"，直到占用降到新上限以下

**`maxEntries` 是"写入闸门"，不是"存储上限"**。改它只影响未来，不追溯过去。

##### 5.6.6.5.8 为什么默认开启

| 原来的担忧 | 现在的判断 |
|---|---|
| "256 已够用" | **256 没有依据**。既然是拍的，那"固定用它"和"从它出发自适应"相比，后者至少会朝正确方向走 |
| "自适应是 bug 来源" | 参数保守（±25% / 12.5%、5 分钟冷却、128~1024 区间、调小需 3 次确认），且**每次调整打 info 日志**，可复盘 |
| "行为不可复现" | 固定值也不是"可复现的正确"——它只是确定地偏离实际需求。日志能还原每次调整的依据 |
| "收益不确定" | 反向看：固定值确定地错，自适应至少接近对 |

**最根本的一条**：上线初期没有历史数据，固定值只能靠猜。与其猜一个数然后等几个月再改，
不如让它在运行中自己找。

##### 5.6.6.5.9 怎么关掉

```cangjie
ResultStoreOptions(
    maxEntries: 256,
    adaptive: None                    // 固定容量，永不调整
)
```

关掉后就是纯固定值，行为与 5.6.6.2 完全一致。**需要"绝对可预测"的场景（如压测、容量规划）应该关掉它**。

##### 5.6.6.5.10 一个必须承认的局限

自适应只看"内部统计"，看不到"客户端体验"。真正该优化的指标是
**"客户端拿到 link 后取到 404 的比例"**，但它需要客户端配合上报。

在拿到那个数据之前，`rejectedByCount` 是代理指标——不过它比 404 **更早**出现
（截断发生在写入时，404 发生在读取时），从这个角度看反而是更好的预警信号。

---

## 6. 动态库 + `fboot run` 落地

这一节是部署的全部关键，每一条都有源码依据。

### 6.1 模块形态

```toml
[package]
  cjc-version = "1.2.0"
  name = "mcp_kb"            # 模块名
  organization = "fountain"
  version = "1.0.0"
  src-dir = ""
  target-dir = ""
  output-type = "dynamic"
  compile-option = "--dy-std"
  override-compile-option = "--dy-std"
  link-option = ""
```

三条硬要求：


| 要求                          | 违反后果                                                    |
| ----------------------------- | ----------------------------------------------------------- |
| `output-type = "dynamic"`     | 产出可执行文件，`fboot run` 不会加载                        |
| `compile-option = "--dy-std"` | 与宿主各自持有一份 std，运行时行为不一致                    |
| **不能有 `main` 函数**        | 有`main` 也不影响加载，但会误导后来者；动态库模块不需要入口 |

### 6.2 加载机制（源码事实）

`f_app/src/funcs.cj`：

```cangjie
load(path, Regex('^lib.*(${extractPattern()}|.+${APP_STATIC_RESOURCE_SUFFIX}).*$'))
  → Directory.walk 递归扫描
  → 文件名（**去掉扩展名**）匹配上述正则
  → PackageInfo.load(路径去掉扩展名)
```

推论：

1. **库文件名必须以 `lib` 开头**，否则正则不匹配，静默不加载。
2. `--dylibPattern` 匹配的是**去掉 `.so` 的文件名**，不是完整路径。
3. 加载依赖 `PackageInfo.load`，**没有任何导出 C 符号的约定**。所谓"入口"是包级
   `static init()` / 顶层初始化器。

### 6.3 启动顺序

```
fboot run
  → 扫描目录、PackageInfo.load 每个匹配的 .so
      → 包级 static init 执行
          → @Controller 展开的 MVCStarter.generateAndRegister
          → McpInitializer 的 InitializerCollection.register
  → InitializerCollection.initialize()
      → f_bean → f_mvc(MVCStarter.initialize) → …
  → 各 Initializer.start() 在新线程 spawn
      → MVCStarter.start() → server.serve()   ← 真正开始监听
  → while(true) { sleep(Duration.Max) }        ← 永不返回
```

**关键约束**：MCP 的路由注册必须发生在 `static init` 阶段，不能放到 `initialize()` 里。
`MVCStarter.generateAndRegister` 在 `MVCStarter.initialize()` 之后调用会抛异常
（详见 f_jsonrpc 设计 2.3）。

### 6.4 Initializer

```cangjie
package fountain::mcp_kb

import fountain::f_app.*
import fountain::f_mcp.*

public struct KbMcpInitializer <: Initializer {
    static init() {
        InitializerCollection.register(KbMcpInitializer())
    }
    public prop name: String { get() { 'fountain::mcp_kb' } }
    public prop dependencies: Array<String> { get() { ['fountain::f_mvc'] } }
    public func initialize(): Unit { }
    public func start(): Unit { }
}
```

`initialize()` 是空的——因为工具注册和路由生成都已经在 `static init` 完成，
MVC 的启动由 `f_mvc` 自己的 Initializer 负责。

f_mcp 声明自己的 controller（端点 `/mcp`），用 f_jsonrpc 提供的 `@JsonRpcMapping`：

```cangjie
package fountain::f_mcp

import fountain::f_mvc.*
import fountain::f_mvc.macros.*
import fountain::f_jsonrpc.*

@Controller
public class McpController {
    @JsonRpcMapping[path: '/mcp']
    public func handle(@RequestBody raw: Array<Byte>): Array<Byte> {
        let ctx = CurrentHttpContext.instance
        McpRegistry.server().handle(raw, ctx)
    }
}
```

`@JsonRpcMapping` **不是 f_mvc 的注解**，而是 f_jsonrpc 定义的 `RequestMapping` 子类。
`method` / `consumes` / `produces` 已在注解里固定为 `POST` + `application/json`，
所以不存在"忘了写 `consumes` 导致 415"这类误配（背景见 f_jsonrpc 设计 2.2）。

`@Controller` 宏在 `static init` 阶段调用 `MVCStarter.generateAndRegister` 完成注册。
**f_mcp 不碰 `RequestMeta` / `RequestMetas`**，也不重复实现路由逻辑——
它只往 `McpRegistry` 的方法表里注册 `server/discover`、`tools/list`、`tools/call`。

### 6.5 启动命令

```bash
export mvc_port=8080            # 可选，默认 8080
export mvc_maxRequestBodySize=8388608   # MCP 请求可能比普通 API 大

fboot run --dylibPattern='mcp_kb'
```

`--dylibPattern` 用模块名即可。产物若是 `libmcp_kb.so`，去扩展名后是 `libmcp_kb`，
正则 `^lib.*(mcp_kb|.+_stAtIc__).*$` 命中。

### 6.6 一个必须验证的点

**`f_mvc` 能否返回「空 body + 202/204」。**

MCP 的通知要求空 body 响应。而 `f_jsonrpc` 的入口返回 `Array<Byte>`，
空的 `Array<Byte>()` 在 `f_mvc` 里会被当成"空结果"，进而按 `produces` 产出什么，
需要实测确认（可能得到 `null`、`[]`，或真的空体）。

如果拿不到空 body，两条退路：

1. 通知路径改走一个独立的、返回 `String` 且 `produces: 'text/plain'` 的方法（返回空串）
2. 接受返回 `{}` 并在此处偏离规范，同时记录为已知偏差

这一条列为 **P-1 验证项**，它决定通知能否合规实现。

---

## 7. 安全

### 7.1 规范硬性要求

规范把安全责任压到实现方。以下是 f_mcp 必须满足的要求：


| 项             | 要求                                                  | 规范依据         |
| -------------- | ----------------------------------------------------- | ---------------- |
| 工具输入校验   | 服务端**MUST** 按 `inputSchema` 校验所有入参          | Tools / Security |
| 访问控制       | 服务端**MUST** 实现（复用 `f_mvc` 的鉴权）            | 同上             |
| 限流           | 服务端**MUST** 对工具调用限流                         | 同上             |
| 输出清洗       | 服务端**MUST** 清洗输出（防注入到 LLM 上下文）        | 同上             |
| Origin 校验    | HTTP 服务端**SHOULD** 校验 `Origin`，防 DNS rebinding | 传输层安全       |
| 绑定地址       | 默认绑`127.0.0.1`，需要外部访问时显式配置             | 同上             |
| 工具描述不可信 | 客户端**MUST NOT** 把 `annotations` 当安全依据        | Tools            |
| 调用超时       | 客户端**SHOULD** 对每次调用设超时                     | Tools / Security |
| 用户确认       | 敏感操作由**Host** 负责征得同意，不是 SDK             | 规范总则         |

其中「清洗输出」在 Cangjie 侧的具体含义：工具返回的文本会进入 LLM 上下文，
必须防止它包含伪造的指令或未转义的控制字符。至少要做的是：剥离 ANSI 转义、
限制单块长度、不允许输出未标记的 HTML。

**`serverInfo` 不能用于安全判断**。规范原文：它是服务端自报的、协议不校验，
客户端不应据此改变行为或做安全决策。

---

### 7.2 限流：三层配置 + `f_cache` 存储

**决定：三个维度同时限（调用方 / 调用方×工具 / 工具全局），配置分三层（全局默认 → 服务级 → 每工具覆盖），
桶状态存 `f_cache.HeapCache`。**

#### 7.2.1 三层配置

```cangjie
/// 第一层：全局默认值。McpServer 没配 rateLimit 时用它
public class RateLimitPolicy {
    /// 单个调用方（IP 或 token）每分钟请求数，跨所有工具
    public var perCallerRpm: Int64 = 600
    /// 单个调用方对**单个工具**的每分钟请求数
    public var perCallerToolRpm: Int64 = 120
    /// 单个工具的全局每分钟请求数（保护重工具）
    public var perToolRpm: Int64 = 6000
    /// 单个调用方的并发上限（在途请求数）
    public var perCallerConcurrency: Int64 = 8
    // 注意：`maxResultBytes` 不在这里，它属于 `McpTool`（单工具覆盖），
    // `RateLimitPolicy` 只表达限流维度。
}

/// 第二层：服务级配置（Builder.rateLimit）
/// 第三层：单工具覆盖。None 的字段沿用上一层
public class ToolRateLimit {
    public var perCallerRpm: ?Int64 = None
    public var perCallerToolRpm: ?Int64 = None
    public var perToolRpm: ?Int64 = None
    /// **不是覆盖**，是"该调用方对该工具的并发子限额"，与全局总并发同时生效（见 7.2.2）
    public var perCallerConcurrency: ?Int64 = None
    public var maxResultBytes: ?Int64 = None
}
```

生效值 = 全局 → 服务级 → 工具，逐字段取第一个非 `None`：

```cangjie
func effective(global: RateLimitPolicy, server: ?RateLimitPolicy, tool: ?ToolRateLimit): RateLimitPolicy
```

**为什么要每工具声明**：全局值必然是折中的，而折中的结果是对每一类都不合适。


| 工具类型 | 建议 `perCallerToolRpm` | 建议 `perCallerConcurrency` | 理由 |
|---|---|---|---|
| 纯读（查库、读缓存、查元数据） | 300 | 不设（沿用全局 8） | 便宜，可以放开 |
| 计算密集型（向量检索、聚合） | 60 | 2 | 一次调用吃满 CPU 几秒，并发只会互相拖慢 |
| 导出（生成大文件） | 20 | 1 | 单个导出就吃满内存，并发没意义 |
| 写操作（入库、改配置、删数据） | 10 | 2 | 需要审计，且失败代价高 |
| 外部 API 代理 | 由上游配额决定 | 4 | 超了会把上游打挂 |
| 大结果返回（>1 MB） | 20 | 不设 | 主要吃带宽，与并发无关 |

```cangjie
// 用法
let tool = McpTool(
    name: "kb_search",
    rateLimit: ToolRateLimit(perCallerToolRpm: 60, perToolRpm: 3000)
)
```

#### 7.2.2 检查顺序与并发子限额

```
1. 全局总并发   perCallerConcurrency          ← 最便宜（计数器），先挡
2. 工具子并发   tool.perCallerConcurrency     ← 计数器，仅当工具声明了才查
3. perCallerRpm                               ← 一次 cache 读
4. perCallerToolRpm                           ← 一次 cache 读
5. perToolRpm                                 ← 一次 cache 读
```

**先查并发再加令牌**，理由：并发检查是纯计数器比较，成本最低；如果并发已满，
后面三次 cache 读都白做。反过来如果先查令牌再查并发，被并发挡住的那部分请求
会白白消耗令牌——而令牌是按时间补充的，消耗掉就没了，这会让正常请求被误伤。

**顺序也影响错误码**：被并发挡住时 `data.scope = "concurrency"`，
客户端应该等待而不是降低频率——两者的重试策略不同。

##### 工具级 `perCallerConcurrency` 是"子限额"，不是"覆盖"

**这两者的区别很关键**，搞错了会漏掉一层保护：

```
错误理解（覆盖）：工具 A 设 2 → 调用方对 A 的上限变成 2，总并发不再受限
                 结果：2 个 A + 8 个 B = 10 个并发，突破全局闸门

正确理解（子限额）：总并发 <= 8 且 对 A 的并发 <= 2
                   结果：2 个 A + 6 个 B = 8 个并发，两层都满足
```

所以工具级的 `perCallerConcurrency` 是**额外加一道子闸门**，全局那道依然生效。

##### 两个计数器的 key 与生命周期

```cangjie
// 全局总并发
"conc:c:" + callerId

// 工具子并发
"conc:ct:" + callerId + "\u0000" + toolName
```

```cangjie
class ConcurrencyGate {
    private let map = ConcurrentHashMap<String, AtomicInt64>()

    func tryAcquire(key: String, limit: Int64): Bool {
        var c = map.get(key)
        if (c.isNone()) {
            map.addIfAbsent(key, AtomicInt64(0))     // 仓颉叫 addIfAbsent，不是 putIfAbsent
            c = map.get(key)
        }
        let counter = c.getOrThrow()
        let v = counter.fetchAdd(1) + 1
        if (v > limit) {
            counter.fetchSub(1)                     // 回滚
            recycle(key, counter)
            return false
        }
        return true
    }

    func release(key: String): Unit {
        if (let Some(counter) <- map.get(key)) {
            let v = counter.fetchSub(1) - 1
            if (v <= 0) { recycle(key, counter) }
        }
    }

    /// 计数归零就从 map 移除，避免"每个访问过的调用方"永久占一个键
    private func recycle(key: String, counter: AtomicInt64): Unit {
        if (counter.load() <= 0 && (map.get(key) ?? counter) === counter) {
            map.remove(key)
        }
    }

    /// 清空所有计数。由 McpServer.close() 调用
    func close(): Unit {
        map.clear()
    }
}
```

`ConcurrencyGate` **没有线程和定时器**，理论上不 close 也不泄漏。
加 `close()` 是为了让 `McpServer.close()` 有一个统一语义："释放全部内部状态"——
调用方不需要知道哪个组件需要清理、哪个不需要。

**三条必须遵守的实现约定**：

**① `tryAcquire` 成功后必须配 `release`，且在 `finally` 里。**

```cangjie
if (!gate.tryAcquire(globalKey, 8)) { return tooMany("concurrency") }
var acquiredTool = false
try {
    if (let Some(l) <- toolLimit) {
        if (!gate.tryAcquire(toolKey, l)) { return tooMany("concurrency") }
        acquiredTool = true
    }
    // ... 调工具
} finally {
    gate.release(globalKey)
    if (acquiredTool) { gate.release(toolKey) }
}
```

**漏了 `finally` 就是灾难**：一次异常会让该调用方的计数器永久 +1，几次之后他再也发不出请求。
这是限流实现里最常见的生产事故，代码评审时要专门盯这一处。

**② 计数归零必须把 key 从 map 移除。**
否则"每个访问过的 IP"都会在 map 里留一个 `AtomicInt64`，长期运行后 map 无限增长——
和限流本来要防的事正好相反。

**③ `recycle` 的"是不是同一个对象"判断不能省。**
线程 A 减到 0 准备删，线程 B 同时 `fetchAdd` 到 1——如果 A 无条件 `remove(key)`，
就把 B 正在用的计数器删了，B 后续 `release` 找不到 key，计数永久丢失。
**仓颉的 `ConcurrentHashMap` 没有 `remove(key, value)` 重载**（已确认），
所以不能用"值相等才删"的原子语义，只能先读出来比对引用：

```cangjie
private func recycle(key: String, counter: AtomicInt64): Unit {
    if (counter.load() <= 0 && (map.get(key) ?? counter) === counter) {
        map.remove(key)
    }
}
```

**这里有一个无法消除的窗口**：比对和 `remove` 之间，B 可能刚好 `addIfAbsent` + `fetchAdd`。
但 B 走的是"先 `get`，拿到 None 才 `addIfAbsent`"——如果 A 在这个窗口里删掉了 key，
B 的 `get` 会拿到 None，然后 `addIfAbsent` 成功，创建一个**新**计数器并从 0 开始。
代价是 B 这一次的并发计数从头算，比实际少 1。这是可接受的偏差（并发限制是"软上限"，
少算一个不会造成资源耗尽），而"计数永久丢失"不可接受。

**要彻底消除这个窗口**，只能把"计数器值"和"key 的生命周期"绑在一个不可变对象里
（类似 Java 的 `ConcurrentHashMap.compute`）。仓颉没有 `compute`，所以接受上述偏差。

#### 7.2.3 令牌桶


|      | 令牌桶                         | 固定窗口                       |
| ---- | ------------------------------ | ------------------------------ |
| 突发 | 允许（桶容量内）               | 窗口边界可打 2 倍              |
| 实现 | 每 key 存 (tokens, lastRefill) | 每 key 存 (count, windowStart) |

固定窗口的"窗口边界"问题很实际：59 秒打 600 次 + 01 秒再打 600 次 = 2 秒内 1200 次，
但每个窗口都没超限。令牌桶没有这个洞。

桶容量 = 每分钟配额，补充速率 = 配额/60 每秒。这样"允许一次性用完一分钟的配额"，
但用完后必须等补充——符合直觉。

```cangjie
/// 必须是 class：f_cache.HeapCache<V> 要求 V <: Object
class RateBucket {
    var tokens: Float64
    var lastRefillNanos: Int64
}

func tryAcquire(bucket: RateBucket, rpm: Int64, nowNanos: Int64): Bool {
    let capacity = Float64(rpm)
    let refillPerNano = capacity / 60.0 / 1_000_000_000.0
    let elapsed = nowNanos - bucket.lastRefillNanos
    bucket.tokens = min(capacity, bucket.tokens + Float64(elapsed) * refillPerNano)
    bucket.lastRefillNanos = nowNanos
    if (bucket.tokens >= 1.0) {
        bucket.tokens -= 1.0
        return true
    }
    return false
}
```

#### 7.2.4 桶存在 `f_cache.HeapCache`

**决定：调用方级与调用方×工具级用 `fountain::f_cache.HeapCache`；工具全局级用
`std.collection.concurrent.ConcurrentHashMap`（工具数是固定的，不需要淘汰）。**

```cangjie
// 调用方级
let callerBuckets = HeapCache<RateBucket>(
    maxSize: 100_000,
    maxLife: Duration.minute * 10,
    checkDuration: Duration.minute * 1,
    concurrencyLevel: 0              // 0 = 按 maxSize 自动分段
)

// 调用方 × 工具级
let callerToolBuckets = HeapCache<RateBucket>(
    maxSize: 100_000,
    maxLife: Duration.minute * 10,
    checkDuration: Duration.minute * 1,
    concurrencyLevel: 0
)

// 工具全局级：工具数固定（几十个），用 ConcurrentHashMap 更轻（无淘汰线程）
let toolBuckets = ConcurrentHashMap<String, RateBucket>()
```

#### 7.2.4.1 `maxLife` 的语义：是"最后一次访问后"，不需要手动 prolong

**这里更正上一版的一个错误说法。** 上一版写"`maxLife` 从 put/prolong 起算，命中时必须 prolong"，
那是把 `once = true` 的语义当成了默认值。实际读 `f_cache` 源码：

`Priority.cj` 头部注释（原文）：

```
maxLife: 超时时间
once: true 从 birth 开始计算超时时间，false 从最后访问时间开始算超时时间
lastUsed: 最后使用时间
```

`deathNanosLocked()`：

```cangjie
addLife(if (once_) { birth } else { lastUsed }, maxLife_)
```

`once_` 默认 `false`，所以**死亡时间 = `lastUsed + maxLife` = 最后一次访问后 maxLife**。

更关键的是 `loadIfAlive()`（`HeapCache.get()` 走的路径）：

```cangjie
protected func loadIfAlive(): Option<V> {
    synchronized(lock) {
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        if (now >= deathNanosLocked()) { return None<V> }
        ref++
        lastUsed = now          // ← 命中就更新 lastUsed
        return Some(value)
    }
}
```

**`get()` 命中就刷新 `lastUsed`，等于自动续期。** 所以：

| 场景 | 是否需要 `prolong` |
|---|---|
| `once = false`（默认），每次请求都 `get` 桶 | **不需要**。`get` 已经续期 |
| `once = true`（从创建起算固定寿命） | 需要，或者干脆别用 `once = true` |
| 想临时改某个条目的 `maxLife` | 需要（`prolong(key, life)` 会同时改 `maxLife` 和续期） |
| 条目已过期后想"复活" | **做不到**。`prolong` 对已过期条目返回 `false`，必须重新 `put` |

`prolong` 的源码注释也确认了这一点：

```cangjie
//已过期条目不允许通过续期"复活"，调用方应改用 set 重建
case Some(p) where !expired(p) => prolongLocked(key, p, life, once)
case _ => false
```

**一个必须知道的副作用**：`get()` 会 `ref++`，而 `ref` 参与淘汰排序
（`orderOf` 的第 ①④ 条规则）。所以"频繁被访问的桶"在内存压力下会更晚被淘汰——
对限流场景这正是想要的（活跃调用方的桶不该被挤掉）。

**另一个副作用**：`get()` 不是纯读，它有写锁。高并发下同一个 key 的 `get` 会串行化。
对限流来说 OK（单 key 串行正是我们需要的原子性），但**不要把它当普通缓存读用在只读热路径上**。

#### 7.2.4.2 key 的构成

```
caller 级：      "c:" + callerId
caller×tool 级： "ct:" + callerId + "\u0000" + toolName
tool 全局级：    "t:" + toolName        （ConcurrentHashMap，键只有 toolName）
```

用 `\u0000` 分隔而不是 `:`，因为 tool name 允许 `_.-` 但不允许 `\u0000`，
可以保证不产生歧义（`a:b` + `c` 和 `a` + `b:c` 用 `:` 拼会撞）。

#### 7.2.4.3 `HeapCache` 是 `Resource`，必须 `close()`

```cangjie
public class McpServer {
    public func close(): Unit {
        callerBuckets.close()
        callerToolBuckets.close()
        resultStore.close()          // 大结果的临时存储，5.6.6.2
    }
}
```

它内部有淘汰线程与 Timer。**不要为每个请求新建 `HeapCache`**——那会创建线程和定时器，
几千个请求就能把进程拖垮。一个 `McpServer` 实例持有一份。

**内存**：10 万 × 2 个 cache × ~50 B/桶 ≈ **10 MB**，可接受。

#### 7.2.5 调用方的识别

```
1. 有 Authorization: Bearer <token> → 用 token 的 SHA-256 前 16 字节（hex），不存明文
2. 有 X-Forwarded-For（且配置了可信代理）→ 取最右侧非代理 IP
3. 否则用 TCP 对端地址
```

**`X-Forwarded-For` 必须配合可信代理列表**，否则任何人都能伪造 header 绕过限流。
未配置可信代理时**忽略该 header**，直接用 TCP 地址。

#### 7.2.6 超限的返回

**HTTP 传输**：返回 `429 Too Many Requests` + `Retry-After: <秒>`，body 是 JSON-RPC 错误对象：

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32050,
    "message": "Rate limit exceeded: per-caller-tool (120/min)",
    "data": { "scope": "caller_tool", "limit": 120, "retryAfterMs": 1500 }
  }
}
```

**stdio 传输**（没有 HTTP 状态码）：只返回 JSON-RPC 错误对象，同上的 `-32050`。

`-32050` 落在 **MCP 业务可用段 `-32020`~`-32099`**（见 `f_jsonrpc模块设计.md` 的错误码划分），
不与协议保留码冲突。


| `data.scope` | 含义 | 客户端应该怎么做 |
|---|---|---|
| `caller` | 调用方总配额超限 | 降低整体频率 |
| `caller_tool` | 调用方对该工具的令牌配额超限 | 换工具或放慢该工具 |
| `tool` | 该工具的全局配额超限（别人也在打） | 稍后重试，不是自己的问题 |
| `concurrency` | **全局总并发**超限 | **等当前请求返回再发**，不要降低频率 |
| `concurrency_tool` | **该工具的子并发**超限 | 换一个轻一点的工具，或等 |

**为什么 `concurrency` 与 `concurrency_tool` 必须分开**：

- `concurrency`：调用方的**总**在途数满了 → 他已经发得太多，只能等
- `concurrency_tool`：他对**这个工具**的在途数满了，但别的工具还有余量 → 可以换工具

如果合成一个码，客户端只能保守地"全部等"，等于废掉一半的并发余量。

前三个（`caller` / `caller_tool` / `tool`）是"你太快了"，后两个是"你同时发太多了"——
**令牌类限流看频率，并发类限流看在途数**，两者的重试策略根本不同。

#### 7.2.7 分布式限流：单实例默认 + 跨进程 SPI


| 部署形态 | 存储 |
| -------- | ---- |
| 单实例 | 5 种内置 `RateLimitBackend`，每个 key 一个 `f_concurrent` 限流器；`mcp_rateLimitBackend` 选择算法 |
| 多实例 | 注入 `RateLimitBackend`，由使用方实现共享存储 |

内置算法与配置值：

| 配置值 | 限流器 | 说明 |
| --- | --- | --- |
| `token-bucket`（默认） | `TokenBucketRateLimiter` | 每分钟 `rpm`，允许突发 |
| `leaking-bucket` | `LeakingBucketRateLimiter` | 每分钟漏出 `rpm` |
| `sliding-window` | `SlidingWindowRateLimiter` | 1 分钟滑动窗口 |
| `unlimited` | `UnlimitedRateLimiter` | 不限制 |

名字大小写与 `-` / `_` 不敏感；未知值在构建时抛 `IllegalArgumentException`。

自定义算法：实现 `RateLimitBackend` 的静态 `name` / `new()`，再调用 `RateLimitBackends.register<T>()`；配置项按 `name` 选择，同名注册会覆盖内置实现。

`RateLimitBackend.tryAcquire(key, rpm, nowNanos)` 的 `key` 已带 `c:` / `ct:` / `t:` 作用域前缀，直接作为共享存储的键：

- Redis：`INCR key` + `EXPIRE 60`（固定窗口），或 Lua 脚本实现令牌桶
- 数据库：单行 `UPDATE ... RETURNING` / 行锁
- 网关：把全局限流放在 nginx / API 网关，f_mcp 只做单实例自保

`f_concurrent` 的限流器是进程内的，不能跨进程。f_mcp 不内置 Redis 客户端，避免绑定具体存储。
全局默认值由 `mcp_rateLimit` / `mcp_rateLimitBackend` 配置；`Builder.rateLimit()` / `Builder.rateLimitBackend()` 优先于配置。并发闸门仍是进程内的。

---

## 8. 性能


| 环节         | 成本               | 优化                                    |
| ------------ | ------------------ | --------------------------------------- |
| `tools/list` | 与工具数线性       | 缓存 +`ttlMs`；工具集不变时结果必须稳定 |
| `tools/call` | 取决于工具本身     | 超时兜底                                |
| HTTP 往返    | 局域网 1~3 ms      | 客户端复用连接                          |
| `_meta` 注入 | 每请求一次对象构造 | 可预构造模板，仅替换版本号              |
| schema 生成  | 启动时一次         | 不要在每次`tools/list` 时重新生成       |

几条实践建议：

1. **工具列表在启动时冻结**，`tools/list` 直接返回缓存好的 `JsonValue`，不要每次重新拼。
2. **schema 在 `build()` 时校验一次**（是不是合法 JSON Schema 对象、工具名是否合规），
   而不是每次请求都查。
3. **大结果分页**：单个工具返回超过 `maxResultBytes`（默认 1 MB）的内容时自动转 `resource_link`，
   让客户端按需读取。

---

## 9. 测试要点


| 类别        | 用例                                                                                                             |
| ----------- | ---------------------------------------------------------------------------------------------------------------- |
| 协议发现    | `server/discover` 返回 `supportedVersions` / `capabilities` / `serverInfo`；**capabilities 里没有 `prompts` 键** |
| 版本协商    | 请求不支持的版本 →`-32022`，`data.supported` 正确；客户端据此**只重试一次**                                     |
| legacy 提示 | 发`initialize` → `-32601` 且 `data.legacyMethod = "initialize"`；`message` 含 "upgrade"                         |
| `_meta`     | 缺失`_meta` → 拒绝；`MCP-Protocol-Version` 与 body 不一致 → 拒绝                                               |
| 工具        | `tools/list` 分页、顺序稳定；`tools/call` 参数校验、`isError` 语义                                               |
| schema      | `$ref` → `build()` 就抛；`pattern` / `minimum` 约束生效；无参工具用 `additionalProperties: false`               |
| 资源        | `resources/list` 分页 + 顺序稳定；`resources/read` 文本 / 二进制两种；不存在的 URI → `-32040`                   |
| 资源边界    | URI 含`#` → `-32602`；重复 URI → `build()` 抛；`contents` 多段返回                                             |
| 能力声明    | 声明了`resources` 后 `read` 必须可用；未声明 `prompts` 时 `prompts/list` 返回 `-32601`                           |
| 内容块      | text / image / resource 三种各一条；`structuredContent` + text 双写                                              |
| 空结果      | 无参数工具、空`content` 数组                                                                                     |
| 通知        | 返回 202 且**body 为空**（依赖 6.6 的验证结论）                                                                  |
| 多轮        | `Manual` 原样透传；`Auto` 两轮成功；超过 `maxRounds` 抛错；每轮 `id` 不同                                        |
| 限流        | 调用方超限 → 429 +`Retry-After`；`data.scope` 四种取值各一条；并发超限                                          |
| 限流分层    | 全局默认生效；服务级覆盖全局；**工具级覆盖服务级**；只给部分字段时其余沿用上层                                   |
| 限流存储    | 桶数超过 10 万后旧桶被淘汰；桶空闲 10 分钟后过期；`prolong` 续期生效                                             |
| URI 白名单  | `http`/`https`/`ftp` 通过；`file://`/`data:`/`javascript:`/`kb://` 全部 `-32602`；含 `#` 的 `-32602`             |
| 大结果      | 文本超 1 MB → 单个`resource_link`；二进制同样；取回内容逐字节一致；过期后 `-32040` + `reason=expired`         |
| 大结果降级  | 未配`publicBaseUrl` 时截断 + `data.truncated = true` + warning                                                   |
| 大小上限    | 结果超 1 MB 被截断且`data.truncated = true`；二进制超限转 `resource_link`                                      |
| 互操作      | 用真实 MCP 客户端（桌面端/CLI）连一遍，跑`tools/list` + `tools/call` + `resources/read`                          |
| stdio       | 子进程启动、行分帧、stderr 不污染 stdout、关闭 stdin 后退出（**仅客户端侧**）                                    |

**互操作测试不可省。** MCP 的坑集中在"规范允许但各家实现选择不同"的地方，
只跑自己写的客户端测不出来。

**能力声明的一致性测试要单独写一条**：遍历 `capabilities` 的每个键，
断言对应的方法族全部可用。这条能防止"声明了 resources 但忘了实现 read"这类回归。

---

## 10. 实施顺序


| 阶段     | 内容                                                                                                           | 验收                                                                                                 |
| -------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **P-1**  | 两个验证：①`f_mvc` 的空 body 能力（6.6）；② `@JsonRpcMapping` 端点能取到原始 body 并返回字节（f_jsonrpc P0） | 通知能返回真空白 body；`/mcp` 能被路由到且 `Content-Type` 缺失时确认是 415                           |
| **P0**   | `McpServer` 骨架 + `server/discover` + `tools/list` + legacy 提示                                              | curl 拿到合法响应；`initialize` 返回带升级提示的 `-32601`                                            |
| **P1**   | `tools/call` **单轮** + `JsonSchema.validate` 参数校验 + `CallToolResult`                                      | 三种内容块都能产出；`isError` 语义正确；`$ref` 在 build 时被拒                                       |
| **P1.5** | **`resources/list` + `resources/read`**                                                                        | 文本与二进制两种资源可读；不存在的 URI 返回`-32040`；分页正确                                        |
| **P2**   | `McpClient`（HTTP）+ 版本探测                                                                                  | 与 P1/P1.5 的服务端互通；`-32022` 重试一次；legacy 服务端给出升级提示                                |
| **P3**   | 动态库打包 +`fboot run --dylibPattern` 启动                                                                    | `libmcp_kb.so` 被加载，端口可访问                                                                    |
| **P4**   | 内置 stdio**客户端** + `input_required` 多轮（`Manual` + `Auto`）                                              | 能连一个外部 MCP server 跑`tools/list`；两轮 `input_required` 能自动完成                             |
| **P5**   | 安全加固（三层限流 + f_cache 桶、URI 白名单、Origin、输出清洗）+ 大结果转 link +`publicBaseUrl`                | 超限样本拿到 429；四种`scope` 都覆盖；10 万 key 后旧桶被淘汰；`file://` 被拒；大结果转 link 后可读回 |
| **P6**   | 规范跟随机制（版本常量、schema 存档、跟随清单）                                                                | 换版本时只改常量 + 过清单                                                                            |

**P3 是部署形态的验证点**：在它之前所有测试都可以用"带 main 的可执行文件"跑，
通过后再切到动态库。**不要一开始就上动态库调试**——加载失败时错误信息很少
（正则不匹配是静默的），会浪费大量时间。

**P1.5 紧跟在 P1 之后**：resources 与 tools 共用同一套 f_jsonrpc 路由与错误映射，
趁热做最省事；拖到后面要重新捡起上下文。**不做 P1.5 就不该声明 `resources`**——
宁可 capabilities 里没有这一项。

**P4 的多轮是可选增量**：如果时间紧，先只做 `Manual`（原样透传），
`Auto` 留到之后。单轮的 `tools/call` 已经在 P1 完成了。

---

## 11. 风险与规范跟随

### 11.1 风险


| 项                           | 风险                                                 | 处置                                                                                                                       |
| ---------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **规范演进快**               | 只实现最新版，每次规范升级都要改代码                 | 见 11.2 跟随清单；版本号收敛成一个常量                                                                                     |
| **对端为 legacy**            | 旧客户端没有`_meta`，握手会失败，直接连不上          | **友好提示升级**（1.2.1）：`-32601` + `data.legacyMethod` + 文档链接；客户端探测到 `-32601` 抛"请升级服务端"。不做协议降级 |
| **SSE 未实现**               | 无法推送进度、无法`subscriptions/listen`             | 声明`listChanged: false`，文档明示                                                                                         |
| **空 body 未验证**           | MCP 通知可能不合规                                   | P-1 先验证，见 6.6                                                                                                         |
| **stdio 仅测试**             | 不能拿去接生产客户端                                 | 代码注释与本文件双标注；生产走 HTTP                                                                                        |
| **工具 schema 的 `$ref`**    | 规范要求解析`$ref` 后校验                            | 首版不支持，schema 校验时明确拒绝并报错                                                                                    |
| **`@Controller` 注册时序**   | 宏必须在`MVCStarter.initialize()` 之前展开           | 由 fboot 加载时机天然保证；若改成手工`main` 启动需自行确认顺序                                                             |
| **依赖 `f_cache`**           | 新增一个底层依赖；`HeapCache` 内部有淘汰线程 + Timer | 每个`McpServer` 只持有一份，`close()` 释放；不要按请求新建（7.2.4）                                                        |
| **`publicBaseUrl` 配置错误** | 大结果转出的 link 客户端打不开                       | 启动时校验 URL 合法且无尾斜杠；运行期 link 生成后打一条 debug 日志                                                         |

### 11.2 规范跟随清单

规范发新版时按这张单子逐项过，不要凭印象改：


| # | 检查项                       | 落点                          |
| - | ---------------------------- | ----------------------------- |
| 1 | 协议版本字符串               | `MCP_PROTOCOL_VERSION` 常量   |
| 2 | `_meta` 键名与必填字段       | 4.2 的`decorate` + 服务端校验 |
| 3 | `resultType` 的取值集合      | 结果构造与校验                |
| 4 | 方法增删改名                 | `McpServer` 方法表            |
| 5 | 错误码（尤其 MCP 专用段）    | 错误映射表                    |
| 6 | 传输要求（头、分帧、状态码） | 3.1 / 3.2                     |
| 7 | 内容块类型                   | `ContentBlock`                |
| 8 | 工具名与字段约束             | `McpTool` 的 `build()` 校验   |
| 9 | 能力字段结构                 | `McpCapabilities`             |

**把规范自带的 JSON Schema 存进仓库**（`spec/schema-<version>.json`），用它校验自己的响应。这比读文档可靠：升级时能直接 diff 出差异，也能在测试里当断言用。

> 一个具体建议：把「响应必须能通过官方 schema 校验」写进 CI。规范里新增字段是常事，
> 少写一个必填字段的 bug，靠人眼审文档很难发现，靠 schema 一秒就能发现。

---

## 12. 已定事项与剩余问题

### 12.1 已定（不再讨论）

| # | 事项 | 结论 | 落点 |
|---|---|---|---|
| 1 | legacy 对端 | **友好提示升级**：`-32601` + `data.legacyMethod` + 文档链接；**不做协议降级** | 1.2.1 |
| 2 | resources | **`list` + `read` 一起做**；`contents` 是数组；不存在的 URI → `-32040` | 5.6 |
| 3 | stdio 范围 | **只做客户端侧**，不做 server-side 测试夹具 | 3.2.1 |
| 4 | `input_required` | **单轮优先**；多轮 `Manual` 默认、`Auto(handler, maxRounds)` 可配 | 4.4 |
| 5 | schema | **统一走 `f_data.json.JsonSchema`**；`$ref` 在 `build()` 拒绝 | 5.3 |
| 6 | 能力声明 | **不声明空壳**；`prompts` 完全不声明 | 5.4.1 |
| 7 | 限流配置 | **三层**：全局默认 → 服务级 → 每工具覆盖（`None` 沿用上层） | 7.2.1 |
| 8 | 限流维度 | 调用方总配额 / 调用方×工具 / 工具全局 + **全局总并发 + 工具子并发** | 7.2.2 |
| 9 | 限流存储 | 令牌桶用 **`f_concurrent.TokenBucketRateLimiter`**，每 key 一个；跨进程用 `RateLimitBackend` SPI | 7.2.4 |
| 10 | `maxLife` 语义 | **最后一次访问后**，`get()` 自动续期，**不需要 prolong** | 7.2.4.1 |
| 11 | 并发计数器 | **独立 `ConcurrencyGate`**（`ConcurrentHashMap` + `AtomicInt64`），归零即回收 key | 7.2.2 |
| 12 | 工具级并发 | **是"子限额"不是"覆盖"**：全局闸门与工具闸门同时生效 | 7.2.2 |
| 13 | 大结果 | 超过 **`maxResultBytes`（默认 1 MB，可配）** 一律转 `resource_link` | 5.6.6 / 5.6.6.4 |
| 14 | 临时结果存储 | **不用 `HeapCache`**：`ConcurrentHashMap` + CAS 字节预算池，自管三个维度 | 5.6.6.2 |
| 15 | 临时结果参数 | **条数为主约束**：`maxEntries = 256`、`maxBytes = 256 MB`（正好对齐） | 5.6.6.2 |
| 16 | 后台清理 | **不做**。空闲时保留热数据，忙起来能直接命中；清理压力与内存压力同步 | 5.6.6.2 |
| 17 | `remove` 语义 | **`ConcurrentHashMap.remove(key)` 返回被删的值**（并发减账成立） | 5.6.6.2 |
| 18 | `String.size` | **UTF-8 字节数**（`estimateBytes` 的估算成立） | 5.6.6.2 |
| 19 | link 签名 | **不加 HMAC**。安全边界在 MCP 连接的鉴权上 | 5.6.6.1 |
| 20 | URI scheme | **只接受 `http` / `https` / `ftp`**；其他一律 `-32602` | 5.6.1.1 |
| 21 | `fetchAdd` 返回值 | **返回旧值**，`fetchAdd(1) + 1` 的写法成立 | 7.2.2 |
| 22 | map 的 API | 是 **`addIfAbsent`**（不是 `putIfAbsent`）；**没有 `remove(key, value)`**，防误删只能用 `===` | 7.2.2 |
| 23 | `ConcurrencyGate.close()` | **加**，语义是"释放全部内部状态"，与 `McpServer.close()` 统一 | 7.2.2 |
| 24 | `data.scope` | **五个值**：`caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool` | 7.2.6 |
| 25 | 运行期调容 | **默认开启**。只调 `maxEntries`；不调 `maxBytes`（内存安全）/ TTL（业务语义）；`adaptive: None` 可关 | 5.6.6.5 |
| 25b | 区间参数命名 | **`floor` / `ceiling`**，不叫 `minEntries` / `maxEntries`（会与外层当前值撞名） | 5.6.6.5 |
| 25c | 非对称策略 | **调大 25% / 调小 12.5%**；调小需连续 3 个窗口确认 + `rejectedByBytes == 0` | 5.6.6.5 |
| 26 | 拒绝统计 | **必须分开**：`rejectedByCount`（触发调大）与 `rejectedByBytes`（不触发，需人工调 maxBytes） | 5.6.6.5 |
| 27 | 调小语义 | **不驱逐现有条目**。`maxEntries` 是"写入闸门"不是"存储上限"，改它只影响未来 | 5.6.6.5.7 |
| 28 | 自适应配置 | **13 项全部可配**，通过 `Builder.resultStore()` 传入，**无写死魔数** | 5.6.6.5.3 |
| 29 | 评估日志 | **每个窗口一条 `debug`**（含 `decision=hold` 的原因）；**每次调整一条 `info`** | 5.6.6.5.6 |
| 30 | 日志字段稳定性 | `mcp.resultstore.eval` 字段名发布后不轻改；加字段只追加末尾 | 5.6.6.5.6 |

### 12.2 仍需确认

**暂无阻塞项。** 三十项决策已全部落地，可以进入实施。

自适应**默认开启**，所以"256 够不够"不再需要等长期观察——它会自己收敛。
参数微调靠**日志**，不需要改代码试错：

##### 调参循环：上线 → 看 debug → 改配置 → 重启

```
第 1 次上线：
  配置：全部默认
  日志：打开 tag=mcp.resultstore 的 debug

第 1~2 天：
  看 mcp.resultstore.eval 的 reason 分布
  · below_threshold 占绝大多数 → 阈值太宽，或容量本来就够
  · bytes_bound 出现        → maxBytes 才是瓶颈
  · at_ceiling 频繁         → ceiling 太低，或需求真的很大
  · idle_pending 反复 0→1→2→0 → 业务有周期性，shrinkConfirmWindows 调大

第 3 天：
  按 12.2 开头三条问题定新参数，改配置，重启
  之后可以把 debug 关掉（info 保持开启）
```

##### 三条待定的参数（只影响默认值，不影响编码）

1. **`rejectRateThreshold = 1%` 是否合适？**
   1% 意味着"每 100 次写入允许 1 次被截断"。对"结果完整性"极敏感的业务
   （导出类工具）可以降到 0.1%，代价是更容易调大、内存占用上升。
   **判据**：看日志里 `reject_rate` 的分布，如果长期在 0.3%~0.8% 徘徊（永远够不到 1%），
   说明阈值偏宽。

2. **`shrinkConfirmWindows = 3` 对日周期业务是否够？**
   3 个窗口 = 15 分钟。夜里 8 小时无人使用时，早上第一次高峰会经历
   "缩到 floor 128 → 拒绝 → 调回"一轮。这轮是**可接受的**（最多损失几次结果），
   但想避免就把 `floor` 提到 256（等于"永不缩到 256 以下"）。
   **判据**：看 `idle_windows` 是否反复在 `0→1→2→0` 跳。

3. **`ceiling = 1024` 与 `maxBytes = 256 MB` 的关系。**
   单条平均 1 MB 时，`maxEntries` 涨到 256 就会被字节闸门挡住，`ceiling` 形同虚设。
   这不是 bug——它说明**真正该调的是 `maxBytes`**（见 5.6.6.5.1 的边界表）。
   **判据**：日志里 `decision=hold reason="bytes_bound"` 且 `rej_bytes > 0`。

##### 想完全保守的首周

如果不想让它在首周就动，用区间退化（只统计不动作），**日志照常输出**：

```cangjie
ResultStoreOptions(
    maxEntries: 256,
    floor: 256,
    ceiling: 256                                         // floor == ceiling ⇒ 调不动
)
```

日志里会一直是 `decision=hold`，reason 是 `at_floor` 或 `at_ceiling`，
但 `puts` / `reject_rate` / `occupancy` 这些统计照常可用。看完一周再放开区间。

##### 实现时的四个注意点

| 项 | 注意 |
|---|---|
| `maybeEvaluateCapacity()` 的调用位置 | 只在 `put` **成功**后调。放失败路径里会变成"越拒绝越评估"，反而掩盖问题 |
| 统计快照的差值算法 | 用"当前累计 − 上次快照"，**不清零**。清零会在多线程并发时丢数 |
| `maxEntries` 的读 | 被多个线程读（`put` 的判断、`get` 的占用率计算）。用 `AtomicInt64` 或接受短暂不一致——**不要加锁**，否则热路径变临界区 |
| debug 日志的开销 | 每 5 分钟一条、单行拼接，成本可忽略。但**不要在 `get` 热路径上打**——只在评估时打 |


---

## 文档与实现对照（fix-jsonrpc-mcp-review-findings）

| 主题 | 实现（以此为准） |
|---|---|
| 能力声明 | `resources.subscribe = false`（未实现 `resources/subscribe`）；`prompts` 保留 |
| 错误码 | `RESOURCE_NOT_FOUND = -32040`（`-32002` 留给 f_jsonrpc 超时）；订阅者超限用 `-32003` |
| 多轮 | `inputResponses` / `requestState` 贯通 `McpToolContext` → `CallToolResult` → `callToolAuto` |
| 截断 | 按 UTF-8 rune 边界；保留 `isError` / `resultType` / `inputRequired` / `requestState` + `data.truncated` |
| 限流 | 三层逐字段 merge；顺序 = 并发优先；拒绝 429 + `Retry-After`；`-1/0/>0` 语义 |
| 后端 | 4 种（`token-bucket` / `leaking-bucket` / `sliding-window` / `unlimited`）；`LimiterPool` 有界 + TTL，淘汰时 `close()` |
| 并发闸门 | 条目化，`release` 只减计数，空闲 TTL 回收 |
| 订阅 | 上限 1024 / 队列 256 / detached 60s；断线与 30 分钟都只 detach，可重连 |
| SSE | 空闲阻塞等待（Condition），15 秒心跳，字符串用 `StringBuilder` |
| 客户端 | `McpClientOptions` 含 `headers` / `maxResponseBytes` / `keepAlive` / `retryOnConnectFailure`；版本协商加锁 |
| 配置 | `mcp_rateLimit` 拒绝负数/小数/未知键/超上限；`mcp_trustForwardedFor` 只接受 true/false |
| 注册时机 | `@Mcp` 在加载期注册后调用 `McpRegistry.build()`；`build()` 可重复调用，每次按累计注册重建，新注册项立即生效 |
