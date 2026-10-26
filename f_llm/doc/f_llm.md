# f_llm 改造 —— 架构设计文档

> 版本 **v0.4** ｜ 2026-10-26 ｜ 状态：待评审
>
> 定位：把现在的 `f_llm`（**只认智谱 GLM、只有一次性非流式调用**）改造成
> **OpenAI 协议兼容、多供应商可切换、可工具可 MCP、可查余额**的大模型访问层，
> 并继续承载既有的上下文裁剪/压缩能力。
>
> 形态：**进程内仓颉库**（`output-type = "dynamic"`），服务于服务器侧的开发智能体。
> **不提供 HTTP 服务**——不注册路由、不提供 Controller、不做 SSE 服务端渲染；
> 对外暴露形态（REST / SSE / WebSocket）由其他模块基于本模块的仓颉 API 自行封装。
> 本模块只做两件事：**作为客户端调上游大模型**、**向进程内其他模块提供 API**。
>
> 依据：实读 `f_llm@1.3.17` 全部源码（`f_llm/src/**`、`f_llm/README.md`、`f_llm/cjpm.toml`）、
> `f_mcp/src/client|base`、`f_httpclient/src/**`、`f_orm/README.md`（`@QueryMappersGenerator` / `@ORMField`）、
> `f_concurrent/src/LoadBalance.cj`、`fdemo/boot/src/boot.cj`。
> 本文中每条关于现状的断言都能落到具体文件与行号；凡未联调确认的外部接口，一律标注 **待联调**。
>
> v0.1 → v0.2（按评审意见定稿）：
> - `LLMConf` 以评审给定字段为准：`provider / llmName / actualLlmName / url / auth / temperature / alwaysThinking / conf / enabled / weight`；
>   原 `llmType` / `threshold` / `priority` 删除，归属改为 `conf` 键与 `weight`
> - 配置**一次装载 + 周期刷新**（懒式 TTL，模块不起线程）；`conf` 用 `f_data` 转 JSON 字符串落库
> - 同一 `llmName` 多平台按 `weight` 用 `f_concurrent.LoadBalance` 调度；连续失败达阈值**临时下线**一段时长，只改内存
> - **允许破坏性变更**：删除兼容壳、删除旧 `access(llmType, ...)` 系列签名
> - 搜索改为纯 tool_call，凭据从任意启用的 `LLMConf` 取；DeepSeek 搜索/抓取端点已核实并写进契约
> - 余额只定接口，平台适配全部后置；日志默认 `info`，每次访问记 `TokenUsage`；脱敏统一「前 4 + `****` + 后 4」
>
> v0.2 → v0.3（一项职责调整）：
> - **SSE 客户端下沉到 `f_httpclient`**：新增 `HttpResponse.sseReader()` + `SseReader` 通用解析器，`f_llm` 只消费、不再自建解析器
> - 解析器只管 SSE 语法（行/字段/注释/心跳），**不认 `[DONE]`、不合并 JSON**——OpenAI 的业务语义留在 `f_llm`
>
> v0.3 → v0.4（评审第二轮）：
> - **思考能力由模型决定，不由平台决定**：新增 `ThinkingCapability`（None / Always / Toggle）+ 模型能力解析；`ProviderDialect` 只负责"用哪个字段表达"
> - `weight <= 0` 等同"停用"，装载 SQL 为 `WHERE enabled = true AND weight > 0`（不再视 1）
> - `tokenThreshold` **每个平台各算各的**，不再跨平台取最小值
> - 搜索平台改为**可注册**（`@Bean` 即可扩），搜索无可用配置时**抛异常**
> - MCP 工具名**不截断**，超限直接失败
> - 新增 `webFetch` 工具（DeepSeek `/v1/tools/fetch`），带 SSRF 防护；CodeBuddy / Qoder 余额**不做**

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 协议兼容 | 一个 `OpenAIContext` 同时支持 **Chat Completions（流式/非流式）** 与 **Responses API（流式/非流式）**，协议差异收敛在 `LLMApiKind` + 报文映射层 |
| 流式底座 | **SSE 客户端由 `f_httpclient` 提供**（`HttpResponse.sseReader()` + `SseReader`），`f_llm` 只消费增量、做归并；本模块不复制解析器 |
| 供应商差异 | 不按供应商继承子类，`ProviderDialect` **表驱动**（补丁式改写报文、自定端点、自定鉴权头）。所有平台都兼容 OpenAI 报文，只是取值不同 |
| 思考能力 | **由模型决定，不由平台决定**：`ThinkingCapability`（`None` / `Always` / `Toggle`）按 `actualLlmName` 解析；`ProviderDialect` 只负责"用哪个字段表达"（5.8） |
| 统一模型名 | `LLMConf.llmName` 是**唯一寻址键**；同一 `llmName` 的多条 `LLMConf`（多平台）由**中介者**按 `weight` 负载均衡，报文里的 `model` 填 `actualLlmName` |
| LLMConf | 字段以评审给定为准：`id / provider / llmName / actualLlmName / url / auth / temperature / alwaysThinking / conf / enabled / weight`。`temperature = -1.0` 表示用平台默认（报文不传）；`conf` 是 JSON 选项表 |
| 配置装载 | **一次装载 + 周期刷新**：懒式 TTL（默认 60s，`f_config` 配），不起线程、不起定时器；刷新整体替换不可变快照，在途请求不受影响；失败保留旧快照 |
| 负载均衡 | 每个 `llmName` 一个 `f_concurrent.LoadBalance`，按 `weight` 加权（`Int64Weight` 随机 / `RoundRobin` 轮询，算法由 `f_config` 指定） |
| 临时下线 | 单个 `LLMConf` 连续失败达阈值即熔断 T 秒，期间不参与调度；到期自动恢复。**只改内存，不动持久化配置** |
| tool_call | 保留 `FunctionCalling` + `FunctionMediator`；工具来源三类（Bean / 内置 / MCP），重名**启动即失败** |
| 内置函数 | `currentTime`（本机时间）、`webSearch`（智谱 + DeepSeek，可注册扩展）、`webFetch`（DeepSeek 抓正文，带 SSRF 防护）；均为 tool_call，**凭据从任意启用的 `LLMConf` 取** |
| MCP | 新增 `f_llm → f_mcp` 单向依赖（已确认 f_mcp 不依赖 f_llm，无环）；`McpClient.listAllTools()` 的 `inputSchema` 直接转成工具定义 |
| 上下文裁剪 | 8 个现有策略**语义不改、签名不改**；`tokenize` 换成可插拔 `TokenCounter`，饱和阈值从 `conf['tokenThreshold']` 读 |
| 日志/序列化 | `f_log` 默认 `info`，每次访问记一条含 `TokenUsage` 的汇总；`f_data` 负责报文 ↔ 对象与 `conf` 的 JSON 互转，流式增量**手工归并** |
| 余额查询 | 只定 `BalanceQuerier` 接口 + 中介者，**平台适配全部后置**（M4，可选）；**CodeBuddy / Qoder 明确不做** |
| 破坏性变更 | 允许。旧 `llm_conf` 表直接按新结构重建，旧 `access(llmType, ...)` 系列、`GLMContext`、`LLMRouter` 全部删除，不留兼容壳（见 6.5） |
| 分期 | **M0** 前置验证；**M1** 装载/刷新/权重/熔断 + 协议层（非流式）；**M2** 流式 + tool_call + MCP；**M3** `TokenCounter` + 观测；**M4** 余额（最后，可选） |
| 对外形态 | **纯进程内库**：无 Controller、无路由注册、无 SSE 服务端；HTTP/推送由应用模块包装本模块 API（见 2.2 / 2.4） |

三条关键判断：

1. **现在的 `llm_conf.conf` 列就是 API Key**。`AbstractLLMContext` 把 `conf.conf` 存为 `conf` 字段，`GLMContext` 再把它当 `auth` 传给 `http(url, auth)`（`f_llm/src/llm/AbstractLLMContext.cj:27-28`、`f_llm/src/util/http.cj:18-20`、`f_llm/src/llm/GLMContext.cj:100`）。所以 `auth` 与 `conf` 拆开不是"增加字段"，是**修一个既有的语义错位**。
2. **`f_httpclient` 现在没有 SSE，但这个缺口补在它那儿**。对外只有 `reader(): StringReader<InputStream>`（`f_httpclient/src/ExtendHttpResponse.cj:60-62`）。SSE 是 HTTP 客户端的通用能力（不止大模型用），所以由 `f_httpclient` 新增 `sseReader()` / `SseReader`，`f_llm` 只调用——不在每个业务模块里各写一份行解析。
3. **`conf` 的落库不走 ORM 自动映射**：成员是 `HashMap`，写库前用 `f_data` 的 `toJson` 转成 JSON 字符串当 SQL 参数，读回用 `fromJson<HashMap<String,String>>`。`fdemo/boot/src/boot.cj:105-113` 正是这条路径的现成示例（`map.toData()` → `JsonValue.from(...)` / `toJson(obj)` / `fromJson<T>(s)`）。这比给 ORM 写双向 converter 直接，也避免"读得出、写不回"的半截实现。

---

## 1. 现状核查（改造的起点）

### 1.1 现在的调用链

```
LLMContextMediator.access(agentId, session, llmType, params)
  └─ key = '${params.model}+${llmType}'          // 模型名与能力维度拼字符串做键
     └─ load(key)                                 // 首次调用时把 LLMFinder 的全部 conf 建一遍 context
        └─ contextCreators.get('${conf.name}+${conf.llmType}')
           └─ GLMContext(conf)                    // static init 里只注册了 glm-4.7-flash / glm-5 / glm-5.1
              └─ http(url, conf) { post(...).readJson() }   // 一次性读完，无流式
```

对应源码：`f_llm/src/llm/LLMContextMediator.cj:19-72`、`f_llm/src/llm/GLMContext.cj:75-142`。

### 1.2 六个硬约束（实证）

| # | 事实 | 证据 |
|---|---|---|
| C1 | 只有一家供应商 | `LLMContextMediator.cj:21-26` 的 `static init` 只注册 `GLMContext` |
| C2 | `LLMConf` 只有 6 列，没有供应商/开关/温度/鉴权 | `f_llm/src/model/po/LLMConf.cj:25-37`：`id / llm_name / llm_type / llm_url / conf / threshold` |
| C3 | `conf` 列被当 Bearer Token 用 | `AbstractLLMContext.cj:28` → `util/http.cj:20` `client.header("Authorization", 'Bearer ${auth}')` |
| C4 | 没有任何流式路径 | 4 处调用全是 `post(...).readJson()`：`GLMContext.cj:104`、`:138`、`search/GLMSearcher.cj:35`、`embedding/GLMEmbeddingContext.cj:33` |
| C5 | 没有 Responses API 概念 | 全仓 `openai\|responses` 只命中 `LLMParams.response_format`（`LLMParams.cj:27`） |
| C6 | 搜索"引擎"藏在模型名里 | `GLMSearcher.cj:25` `this.engine = super.name.split('\|')[1]`，即 `name='glm\|search-pro'` |
| C7 | 没有 MCP、没有余额查询 | `f_llm/cjpm.toml:21-35` 无 `f_mcp`；全仓 `balance\|余额` 在 `f_llm` 下零命中 |

### 1.3 需求与差距

| 需求 | 现状 | 差距性质 |
|---|---|---|
| ① OpenAI 兼容（流式/非流式/Responses） | 只有 GLM 的非流式 | **新增协议层**，不是改参 |
| ② `LLMConf` 承载温度/鉴权/alwaysThinking/多供应商 | 6 列，鉴权藏在 `conf` | **模型 + 表结构 + DAO 三方改动** |
| ③ tool_call + 两个内置函数 | `FunctionCalling`/`FunctionMediator` 已完整 | **新增函数 + 工具来源扩展** |
| ④ 保留上下文压缩/裁剪 | 8 个策略完整（`ContextPruner.cj`） | **不改语义**，只换 token 计数实现 |
| ⑤ MCP | 无 | **新增依赖 + 适配层** |
| ⑥ f_log / f_data | 已在用 | **规约补强**（脱敏、流式汇总） |
| ⑦ 余额查询 | 无 | **全新子域** |

---

## 2. 目标与边界

### 2.1 目标

1. 任意 OpenAI 兼容端点（智谱、DeepSeek、火山方舟、阿里百炼、硅基流动、OpenAI 官方、自建网关）改**一行配置**即可接入，不改代码。
2. 同一个统一模型名可以由多家平台提供，按 `weight` 加权调度 + 失败转移，业务侧只认 `llmName`。
3. 三种调用形态（Chat 非流式、Chat 流式、Responses 流式/非流式）都有**稳定的仓颉 API**，供 `fcoder`、`fountain` 应用或其他项目直接调用。
4. 工具调用、MCP 工具、余额查询都是**可扩展**的：加一个 `@Bean` 类即可，不改框架代码。
5. **嵌入式形态不变**：沿用 `output-type = "dynamic"`（`f_llm/cjpm.toml:8`），由 `fboot` 加载进服务器进程，不引入独立进程、不引入 RPC、不新增部署单元。调用方就是同进程内的 `fcoder` / 应用 Service。
6. **配置冷热分离**：`LLMConf` 只在启动时装载一次，之后按周期（`f_config` 可配）刷新；刷新是全量替换快照，不逐条改。
7. **流量按权重分配**：同一 `llmName` 的多平台按 `weight` 加权调度，算法可配（随机加权 / 轮询）。
8. **故障自愈**：单个平台连续失败达阈值自动临时下线，冷却到期自动上线，不需要人改配置。
9. **允许破坏性变更**：不为旧签名留兼容壳，宁可让 `fcoder` 一次性改到位，也不背两套语义。

### 2.2 非目标（本期不做）

- **不做 HTTP 服务**：不提供 Controller、不注册路由、不下发 `text/event-stream`、不监听端口。本模块的"流式"是**消费上游 SSE**，不是**生产 SSE**。
- **不做**余额平台适配：本期只落 `BalanceQuerier` 接口与中介者，平台实现全部后置（M4，可选），不承诺端点细节；**CodeBuddy / Qoder 明确不做**（无公开接口，不硬凑）。
- **不做** Anthropic Messages 协议（`/v1/messages`）——供应商差异表留了 `apiStyle` 键，但不是本期实现。
- **不做** embedding / rerank / tokenizer 的重构：`EmbeddingContextMediator` 只跟随 `LLMConf` 字段变化做最小适配。
- **不做**计费与成本核算（`TokenUsage` 只进日志，不落库、不算钱）。
- **不做**供应商侧的"配额/限速"管理（只识别 429 做退避）。

### 2.3 依赖变化

```
                 ┌───────────────────────────────────────┐
                 │                f_llm                  │
                 │  llm / tool / mcp / balance / config  │
                 └───┬──────────┬──────────┬────────┬────┘
                     │          │          │        │
        ┌────────────▼──┐ ┌─────▼────┐ ┌───▼──────┐ │
        │ f_httpclient  │ │  f_mcp   │ │f_concurrent│ │
        │ + SSE 客户端  │ │ (新依赖) │ │LoadBalance │ │
        │ (需先补能力)  │ └─────┬────┘ │ (新依赖)   │ │
        └────────┬──────┘       │      └────────────┘ │
                 │              │                     │
        ┌────────▼──────────────▼─────────────────────▼─┐
        │ f_data · f_log · f_bean · f_orm · f_config     │
        └────────────────────────────────────────────────┘
```

`f_llm/cjpm.toml` 新增：

```toml
"fountain::f_mcp"        = {path = "../f_mcp"}         # MCP 工具来源
"fountain::f_concurrent" = {path = "../f_concurrent"}  # LoadBalance 权重调度
```

`f_httpclient` 不需要新增依赖项（SSE 解析只用 `std.io` + 已有的 `InputStream`），但**需要先补 SSE 客户端能力**，`f_llm` 的流式里程碑依赖它（见 5.3 / 13 的 M2 前置）。

`f_concurrent` 自身只依赖 `f_base / f_collection / f_exception / f_random`（`f_concurrent/cjpm.toml:1-5`），无环。

**无环已验证**：`f_mcp/cjpm.toml` 依赖 `f_bean / f_concurrent / f_config / f_data / f_jsonrpc / f_log / f_macros / f_mvc`，不含 `f_llm`。

**依赖闭包的副作用**：`f_mcp` 自己依赖 `f_mvc`（其服务端能力需要），所以 `f_llm` 的编译/链接闭包会顺带带上 `f_mvc`。本模块**不使用**其中任何 HTTP 服务端能力，只是被动继承；若将来要去掉这层重量，可评估把 MCP 客户端从 `f_mcp` 拆成独立模块（后续优化，不在本期）。

**不新增 `f_crypto` 依赖**：三种云签名的 HMAC 直接用 `stdx.crypto.digest.HMAC`（`f_jwt/src/HMACDigest.cj:18-24` 已有同款用法可抄）。

### 2.4 进程内库的三条约束

既然不承担 HTTP 服务，实现上必须守住三条，否则会被应用层"绑"成半个服务端：

1. **不持有线程、不托管执行器**。流式回调在调用方线程内**同步**触发（`chatStream` 内部就是一个 `while (let Some(e) <- reader.next())` 循环），模块不 `spawn`、不建线程池、不向队列投递。这样调用方的线程模型（`f_mvc` 的请求线程、`f_ticktock` 的任务线程）才是唯一需要关心的事。
2. **不做全局可变状态**。所有共享结构（conf 索引、context 缓存、工具表、余额缓存）都走 `ConcurrentHashMap` + `Mutex` 双检，与既有 `LLMContextMediator.load` 的写法一致；除工具表首次构建外，不做跨请求持有锁。多会话并发是**常态**，不是边界情况。
3. **资源所有权清晰**。`HttpClient` / `McpClient` / SSE 响应体一律 `resource(...)` 或显式 `close()` 收尾；`chatStream` 中途抛异常也必须关闭底层流——`f_httpclient` 每次请求都新建底层 client（`httpclient.cj:133-137`），漏关的代价比常规连接池更高。

取消语义（M2 引入）：`LLMRequest` 加 `cancelToken: ?CancelToken`，只承诺"尽快停止读流并关闭连接"，**不承诺**上游停止计费；回调里抛异常即视为取消，原始异常向上传播，不被吞成 `LLMException`。

---

## 3. 领域模型：`LLMConf`

### 3.1 最终形态

```cangjie
package fountain::f_llm.model.po

import std.collection.HashMap

import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.*
import fountain::f_orm.macros.*

@DataAssist[props fields]
@QueryMappersGenerator[table: llm_conf]
public class LLMConf {
    @ORMField[true 'id']
    private var id: Int64 = 0

    /** 提供服务的平台名称：zhipu / deepseek / ark / dashscope / siliconflow / openai / custom... */
    @ORMField['provider']
    private var provider: String = ''

    /** 统一的大模型名：框架内唯一寻址键，多个平台可共用同一个值 */
    @ORMField['llm_name']
    private var llmName: String = ''

    /** 平台实际使用的模型名；火山方舟填 ep-xxxx 端点 ID */
    @ORMField['actual_llm_name']
    private var actualLlmName: String = ''

    /** baseUrl，不含协议路径；路径由 Dialect 按 LLMApiKind 拼接 */
    @ORMField['llm_url']
    private var url: String = ''

    /** 鉴权 KEY，或引用形式 secretRef:env:NAME（见 3.6） */
    @ORMField['auth']
    private var auth: String = ''

    /** 温度：< 0 表示用平台默认值（报文不带 temperature）；>= 0 覆盖请求值 */
    @ORMField['temperature']
    private var temperature: Float64 = -1.0f64

    /** 有些模型必须开启思考 */
    @ORMField['always_thinking']
    private var alwaysThinking: Bool = false

    /** 其他配置（端点覆盖、饱和阈值、搜索、余额、签名参数等），见 3.5 */
    @ORMField['conf']
    private var conf: HashMap<String, String> = HashMap<String, String>()

    /** 当前配置是否启用：false 时不参与调度（下线配置无需删行） */
    @ORMField['enabled']
    private var enabled: Bool = true

    /** 多个平台为相同 llmName 提供服务时，分配流量的权重（>= 1） */
    @ORMField['weight']
    private var weight: Int64 = 1

    public func option(key: String): ?String {
        conf.get(key)
    }

    public func option(key: String, defaultValue: String): String {
        conf.get(key) ?? defaultValue
    }

    public func optionInt(key: String, defaultValue: Int64): Int64 {
        if(let Some(v) <- option(key)){
            Int64.tryParse(v) ?? defaultValue
        }else{
            defaultValue
        }
    }

    public func optionBool(key: String, defaultValue: Bool): Bool {
        if(let Some(v) <- option(key)){
            v == 'true' || v == '1'
        }else{
            defaultValue
        }
    }

    /** 该 conf 的饱和 token 数；0 表示不限制 */
    @DataExclude[prop field]
    public prop tokenThreshold: Int64 {
        get() {
            optionInt('tokenThreshold', 0)
        }
    }

    @DataExclude[prop field]
    public prop streamable: Bool {
        get() {
            optionBool('stream', true)
        }
    }

    @DataExclude[prop field]
    public prop isPlaceholder: Bool {
        get() {
            provider.isEmpty() || actualLlmName.isEmpty() || url.isEmpty()
        }
    }
}
```

> 与评审给定草稿的两处差异，都是编译层面绕不开的：
> 1. `conf` 声明为 `HashMap` 而非 `Map`——`Map` 是接口，`f_data` 的 `DataFields` 扩展落在 `HashMap` 上（`f_data/src/base/MapData.cj:122`），声明成 `Map` 无法被 `toData()` / `@QueryMappersGenerator` 正常展开。
> 2. 拼写 `tempreture` → `temperature`，默认值 `0.0f64` → `-1.0f64`（15.1 已确认：`-1.0` 表示用平台默认值，报文不传该参数）。

### 3.2 字段语义

| 字段 | 语义与约束 |
|---|---|
| `id` | 主键。也是 context 缓存键与熔断状态的键（**不能用 `llmName`**：同名的多平台必须各自独立） |
| `provider` | 平台标识，决定用哪个 `ProviderDialect`；也是搜索/余额能力的路由依据 |
| `llmName` | 统一模型名，业务侧唯一寻址键。同一值可对应多条记录（多平台） |
| `actualLlmName` | 写进报文的 `model`。三家典型差异：智谱 `glm-5`、DeepSeek `deepseek-chat`、火山方舟 `ep-2026xxxx` |
| `url` | baseUrl（不含 `/chat/completions`）。路径由 Dialect 拼，`conf['chatPath']` 可覆盖 |
| `auth` | Bearer KEY，或 `secretRef:env:NAME`（见 3.6） |
| `temperature` | `< 0` ⇒ 报文不带 `temperature`（用平台默认）；`>= 0` ⇒ 覆盖调用方传值。`0.0` 是合法贪心温度，所以**不能用 0 当哨兵** |
| `alwaysThinking` | `true` ⇒ 无论调用方怎么传都强制开启思考；**是否真的能开由模型能力决定**（模型 `ThinkingCapability=None` 时记 `warn` 并忽略，见 5.8） |
| `conf` | 开放配置表，见 3.5。库列是 TEXT/JSON |
| `enabled` | `false` ⇒ 装载快照时就过滤掉，不参与调度 |
| `weight` | 加权调度的**相对份额**，`> 0` 才有意义；**`<= 0` 等同停用**（与 `enabled=false` 同效，不再"视 1"）。装载 SQL 统一是 `WHERE enabled = true AND weight > 0`（见 3.3） |

**被删掉的旧字段去哪了**：

| 旧字段 | 归属 | 原因 |
|---|---|---|
| `llmType` | `conf['llmType']`（可选，默认 `text`） | 搜索改成 tool_call 后不再需要独立的 `search` 类型（15.4）；只有 embedding 等非文本模型需要显式标注 |
| `threshold` | `conf['tokenThreshold']` | 只有 `SaturationContextPruner` 用，放进开放配置表即可，不值得占一列 |
| `priority` | 删除，由 `weight` 取代 | 权重已经能表达"谁多分流量"，再留一个排序字段会出现"priority 与 weight 打架"的二义性 |

### 3.3 表结构（重建，不做数据迁移）

允许破坏性变更，所以不写数据搬运脚本——旧表直接按新结构重建，人工补几条配置：

```sql
DROP TABLE IF EXISTS llm_conf;

CREATE TABLE llm_conf (
  id               BIGINT       NOT NULL AUTO_INCREMENT,
  provider         VARCHAR(64)  NOT NULL DEFAULT ''  COMMENT '平台标识',
  llm_name         VARCHAR(128) NOT NULL DEFAULT ''  COMMENT '统一模型名',
  actual_llm_name  VARCHAR(128) NOT NULL DEFAULT ''  COMMENT '平台实际模型名',
  llm_url          VARCHAR(512) NOT NULL DEFAULT ''  COMMENT 'baseUrl',
  auth             VARCHAR(512) NOT NULL DEFAULT ''  COMMENT '鉴权KEY或secretRef:...',
  temperature      DOUBLE       NOT NULL DEFAULT -1  COMMENT '<0 用平台默认',
  always_thinking  TINYINT      NOT NULL DEFAULT 0,
  conf             TEXT         NULL                 COMMENT 'JSON 对象',
  enabled          TINYINT      NOT NULL DEFAULT 1,
  weight           BIGINT       NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  KEY idx_llm_name (llm_name, enabled)
);
```

索引说明：装载时按 `llm_name` 分组，所以 `(llm_name, enabled)` 一个索引就够；`provider` 不做索引，它只在内存里做分支。

**装载 SQL**（唯一一条，`LLMFinder` 的实现照抄）：

```sql
SELECT id, provider, llm_name, actual_llm_name, llm_url, auth,
       temperature, always_thinking, conf, enabled, weight
FROM llm_conf
WHERE enabled = true AND weight > 0
ORDER BY llm_name, id;
```

`weight <= 0` 与 `enabled = false` 等价，**在 SQL 里就过滤掉**——不把停用记录带进内存，也就不需要在装载后再判一次、更不用为它记 `warn`。

### 3.4 `conf` 的落库与读写（f_data）

`conf` 成员是 `HashMap<String,String>`，**库里存 JSON 文本**，转换只走 `f_data`，并且收敛到一个 codec 里，DAO 与测试都调它：

```cangjie
package fountain::f_llm.model

import fountain::f_data.*

/** llm_conf.conf 列 <-> HashMap 的唯一入口 */
public struct LLMConfCodec {
    private init(){}

    /** 写库前：Map -> JSON 字符串，作为 SQL 参数传入 */
    public static func toColumn(conf: HashMap<String, String>): String {
        toJson(conf)                       // toJson<T>(d) where T <: ToData，HashMap 已实现
    }

    /** 读库后：JSON 字符串 -> Map；空串/null 给空表，不让解析失败把整条配置丢掉 */
    public static func fromColumn(text: String): HashMap<String, String> {
        if(text.trimAscii().isEmpty()){
            HashMap<String, String>()
        }else{
            fromJson<HashMap<String, String>>(text) ?? HashMap<String, String>()
        }
    }
}
```

`toJson` / `fromJson` 的签名在 `f_data/src/json/JsonConverter.cj:18-24`：`toJson<T>(d) where T <: ToData`、`fromJson<T>(s): ?T where T <: FromData`。`HashMap` 通过 `MapData` 扩展两者都实现了（`f_data/src/base/MapData.cj:67,122`），不需要手写遍历。`fdemo/boot/src/boot.cj:105-113` 就是同一组 API 的用例（`map.toData()` → `JsonValue.from(...)`、`toJson(obj)`、`fromJson<T>(s)`）。

**写入路径**（评审 15.2：传 SQL 参数时先转 JSON 字符串）：

```cangjie
// conf 列永远传字符串，不传 Map 本身
executor.???.SET('conf', LLMConfCodec.toColumn(conf.conf))   // 具体 DAO 写法沿用 f_orm 既有链式 API
```

**读取路径**：`@ORMField['conf']` 配 `QueryMapperJsonConverter`（`f_orm/src/base/QueryMapperConverter.cj:42-57`，内部就是 `fromJson<T>(text)`），由它把 TEXT 还原成 `HashMap`；如果要用 codec 的"空串给空表"语义，就自写一个同名 converter 转调 `LLMConfCodec.fromColumn`。

**M0 的验收**（只验两件事，不再讨论方案）：

1. `LLMConf` 新形态能被 `@DataAssist` + `@QueryMappersGenerator` 展开并通过编译；
2. 一条记录跑完 `读 → 改 conf → 写 → 再读`，断言 `conf` 是合法 JSON 且内容一致。

### 3.5 `conf` 键约定

`conf` 是"平台方言 + 运维开关"的开放口袋，**只放字符串**，键名小驼峰。已约定的键：

| 键 | 用途 | 谁读 |
|---|---|---|
| `apiStyle` | `chat`（默认）/ `responses` | `ProviderDialect.endpoint` |
| `chatPath` / `responsesPath` | 覆盖默认路径（默认 `/chat/completions`、`/responses`） | 同上 |
| `organization` / `project` | OpenAI 组织/项目头 | `OpenAIDialect` |
| `extraHeaders` | JSON 对象串，原样并入请求头 | `authHeaders` |
| `stream` | `false` 时该 conf 禁流式（老网关不支持） | `LLMConf.streamable` |
| `llmType` | 默认 `text`；embedding 等非文本模型必须显式标注 | `EmbeddingContextMediator` |
| `thinking` | 覆盖模型思考能力：`none` / `always` / `toggle`；不写则按 5.8 的解析顺序推断 | `ModelCapabilities` |
| `tokenThreshold` | 该平台该模型的饱和 token 数，`0` 表示不限制；**每平台各存一份，不跨平台聚合** | `SaturationContextPruner` |
| `timeoutMs` | 单次调用超时，默认 120000 | `OpenAIContext` |
| `idleTimeoutMs` | 流式无数据超时，默认 120000（传给 `f_httpclient` 的 `sseReader`） | `OpenAIContext` |
| `tokenizerUrl` | 远端 token 计数端点（智谱有，多数平台没有） | `RemoteTokenCounter` |
| `maxTokens` / `maxOutputTokens` | 默认上限 | 报文映射 |
| `searchUrl` | 搜索端点覆盖（默认取 `SearchProvider` 注册的实现里的常量） | `WebSearchFunction` |
| `searchEngine` | 智谱 `search_engine`（如 `search_pro`） | `ZhipuSearchProvider` |
| `fetchUrl` | 抓取端点覆盖（默认取 `SearchProvider` 的 `fetchEndpoint`） | `WebFetchFunction` |
| `balanceUrl` / `balanceMethod` | 余额端点（见 11） | `BalanceQuerier` |
| `accessKeyId` / `secretRef` / `region` / `service` / `apiVersion` | 云厂商签名参数 | `BalanceQuerier` |

### 3.6 凭据治理

需求②要求 `LLMConf` 带"鉴权 KEY"，字段保留，但**不是唯一来源**：

```cangjie
public interface LLMSecretResolver {
    /** 解析 auth 字段；支持 auth:xxx / secretRef:env:NAME / secretRef:file:/path */
    func resolve(auth: String): String
}
```

规则：

1. `auth` 以 `secretRef:` 开头 ⇒ 交给 resolver，DB 里不落明文；
2. 否则 `auth` 即明文 KEY（允许，但**日志一律脱敏**，见 10.1）；
3. `auth`、`Authorization`、余额查询的 `accessKeySecret` / `secretKey`、`conf` 里所有 `*Key*` / `*Secret*` / `*Token*` 值，输出一律是 **前 4 位 + `****` + 后 4 位**（长度不足 12 位时全部 `****`），例：`sk-a1b2c3d4e5f6` → `sk-a****e5f6`；
4. `LLMConf.toString()` 也必须走同一个脱敏函数——`@DataAssist[tostring]` 一开，未脱敏的 `LLMConf` 会直接把 KEY 打进日志；
5. 余额查询的 AK/SK **不要**复用模型调用的 Bearer KEY——火山方舟的 API Key 与火山引擎计费 OpenAPI 的 AK/SK 是两套凭据，混用只会得到一个很隐蔽的 401。

---

## 4. 配置装载、刷新与多平台调度

### 4.1 装载一次，之后整体替换快照

```cangjie
public interface LLMFinder {
    /** 全量配置；由应用实现（fcoder 的 LLMDAO 或 f_config/文件），启动与每次刷新各调用一次 */
    func listConfs(): ArrayList<LLMConf>
}
```

`LLMContextMediator` 内部持有**不可变快照**，读路径完全无锁：

```cangjie
class LLMConfsSnapshot {
    let version: Int64
    let confs: HashMap<Int64, LLMConf>                  // conf.id -> conf
    let byName: HashMap<String, ArrayList<LLMConf>>     // llmName -> 可用候选（enabled && weight>0）
    let balancers: HashMap<String, LoadBalance<Int64, LLMCall, LLMResp>>  // llmName -> 权重调度器
}

// 唯一可变引用，写入时整体替换
private var snapshot: LLMConfsSnapshot
```

关键点：

- **context 缓存键是 `conf.id`**，不是 `llmName`。现在的 `'${model}+${llmType}'`（`LLMContextMediator.cj:58`）在同名多平台时会让两个平台共用一个实例，鉴权与端点全错。
- 快照是 `class` 且字段全 `let`，刷新时**新建一个再原子替换**，不做原地修改——这样在途请求拿到的旧快照始终自洽。
- `enabled = false` 与 `weight <= 0` 在 **SQL 层就已过滤**（3.3），不该出现在内存里；快照构建时只需丢掉 `provider / actualLlmName / url` 为空的残缺行（`LLMConf.isPlaceholder`）并记 `warn`——那是配置错误，值得提醒。

### 4.2 刷新：懒式 TTL，不起线程

```cangjie
private let refreshMutex = Mutex()
private var refreshing = false

private func ensureFresh(): Unit {
    let snap = snapshot
    if(MonoTime.now() - snap.loadedAt < LLMConfig.getConfRefreshInterval()){
        return                                      // 未到周期，零开销
    }
    synchronized(refreshMutex){
        if(refreshing){
            return                                  // 单飞：已有线程在刷，本次直接用旧快照
        }
        refreshing = true
    }
    try{
        let confs = lookup<LLMFinder>().listConfs()  // 一次全量查询
        snapshot = LLMConfsSnapshot(snap.version + 1, confs, MonoTime.now())
        log.info{'llm conf refreshed, version: ${snapshot.version}, count: ${confs.size}'}
    }catch(e: Exception){
        log.error(e){'llm conf refresh failed, keep version ${snap.version}'}
    }finally{
        synchronized(refreshMutex){
            refreshing = false
        }
    }
}
```

- **不引入定时器/线程**：模块是库（见 2.4），不能持有线程。所谓"定时刷新"是**周期内第一次访问触发刷新**（lazy TTL），空闲进程零开销。
- 刷新周期由 `f_config` 决定：`llm_confRefreshSeconds`（默认 60 秒）。
- **单飞**：同一个周期内只允许一个线程查库，其余线程用旧快照继续跑，不排队等。
- **刷新失败不降级**：保留旧快照，记 `error`（含异常与耗时），下一个周期再试。绝不能因为一次 DB 抖动把全部模型配置清空。
- 提供 `refreshNow(): Unit` 给运维接口/测试用；正常路径不调。
- 代价明确写在文档里：刷新周期后的第一个请求要承担一次 DB 查询（毫秒级）；对延迟极敏感的场景把 `llm_confRefreshSeconds` 调大即可。

### 4.3 权重调度：`f_concurrent.LoadBalance`

真实 API（`f_concurrent/src/LoadBalance.cj:75-125`）：

```cangjie
public class LoadBalance<W, D, R> where W <: Addable<W> & Comparable<W> {
    public LoadBalance(private let min: W, private let algo: LoadBalanceAlgo<W>)
    public func add(weight: W, fn: (D) -> R): Unit
    public func add(all!: Iterable<(W, (D) -> R)>): Unit
    public func call(data: D): R
    public func call(data: D, maxRetrying: Int64): (?R, ?LoadBalanceException)
    public func iterator(): Iterator<(D) -> R>
}
```

用法（每个 `llmName` 一个实例，随快照重建）：

```cangjie
var total = 0
for(c in candidates){
    total += c.weight
}
if(total <= 0){
    return None<LoadBalance<Int64, LLMCall, LLMResp>>     // 没有可用平台，不建调度器
}
let algo: LoadBalanceAlgo<Int64> = match(LLMConfig.getLoadBalanceAlgo()){
    case 'roundRobin' => RoundRobin<Int64>(1, 0, total - 1)
    case _ => Int64Weight(0, total)          // 默认：随机加权
}
let balancer = LoadBalance<Int64, LLMCall, LLMResp>(0, algo)
for(c in candidates){
    balancer.add(c.weight){call => doAccess(c, call)}
}
```

要点：

- `add` 内部把权重**累加成 TreeMap 键**（`max + weight`），所以 `weight` 是相对份额，不需要自己算百分比；`Int64Weight(0, total)` 的上界必须覆盖累计键空间，因此 `total` 要在 `add` 之前算好。
- 算法由 `llm_loadBalanceAlgo` 指定：`randomWeight`（默认）/ `roundRobin`。二者都只用标准实现，不写自定义算法。
- **不用 `call(data, maxRetrying)`**：它在**任何**异常上都继续试下一个节点，会把 400/401 也当故障转移。我们用 `iterator()` 自己遍历——它从权重选中的位置开始、绕回一圈，正好是"按权重选起点、失败再顺延"的语义，且能精确控制"哪些错误才转移"。
- 转移规则：连接失败/超时/429/5xx/SSE 中途断开 → 试下一个；其余 4xx → 立即抛，不再试。
- 全部候选失败 ⇒ 抛最后一个异常，消息里带 `tried=[provider:actualLlmName, ...]`。

### 4.4 连续失败与临时下线（熔断）

只改内存，不动持久化配置：

```cangjie
class BreakerState {
    var failures: Int64 = 0
    var openUntil: ?MonoTime = None<MonoTime>
}
private let breakers = ConcurrentHashMap<Int64, BreakerState>()   // key = conf.id
```

| 事件 | 处理 |
|---|---|
| 调用成功 | `failures = 0`，`openUntil = None` |
| 可重试失败 | `failures++`；达到 `llm_failureThreshold`（默认 5）⇒ `openUntil = now + llm_cooldownSeconds`（默认 60s） |
| 不可重试失败（4xx） | **不计入**。参数错不该把平台打成"下线"，否则一次错误的请求参数会让整家平台停一分钟 |
| 选择候选时 | `openUntil <= now` 视为已恢复：清零计数并参与调度；否则跳过 |
| 进程重启 | 状态清零（本来就不该持久化） |

粒度是 `conf.id` 而不是 `llmName`：坏掉的是"这家平台的这个模型"，不是整个模型名。同名的其他平台必须还能用。

熔断与权重调度的关系：熔断**不重建** `LoadBalance`（避免每次失败都重算权重树），而是在 `iterator()` 遍历时跳过已下线的节点。节点数是个位数，跳过的成本可以忽略。

### 4.5 对外签名与阈值

```cangjie
public func access(agentId: Int64, session: String, llmName: ModelName, params: LLMParams): LLMResp
public func accessStream(agentId: Int64, session: String, llmName: ModelName, params: LLMParams,
                         onDelta: (LLMDelta) -> Unit): LLMResp
public func candidates(llmName: ModelName): ArrayList<LLMConf>
public func candidates(): ArrayList<LLMConf>            // 全部可用候选（搜索借凭据时用）
public func isCircuitOpen(confId: Int64): Bool          // 熔断状态查询
public func peekNext(llmName: ModelName): ?LLMConf      // 按权重选出"下一次会用到"的 conf（不调用）
public func getTokenThreshold(conf: LLMConf): Int64     // 按 conf 取，不跨平台聚合
public func tokenize(conf: LLMConf, messages: ArrayList<ChatMessage>): Int64
public func saturated(conf: LLMConf, messages: ArrayList<ChatMessage>): Bool
public func refreshNow(): Unit
```

- 旧签名（`access(agentId, session, llmType, params)`、`getTokenThreshold(llmType, model)` 等）**删除**，不留转发（见 6.5）。
- `LLMParams.model` 语义改为**统一模型名**；报文里的 `model` 取 `conf.actualLlmName`。`AgentTask.cj:389` 传的本来就是 `agent.llmName`，这一处不用改。
- **阈值不跨平台聚合**（评审 B4）：`tokenThreshold` 是"这个平台这个模型"的属性，取最小值会把 A 平台的保守上限强加到 B 平台，白白多裁一次上下文。改成按 conf 判断，调用方先 `peekNext(llmName)` 拿到即将使用的 conf：

```cangjie
public func getTokenThreshold(conf: LLMConf): Int64 {
    conf.tokenThreshold          // 0 表示该平台不限制
}
```

调用顺序变成"**先选平台，再裁上下文**"：

```cangjie
let conf = mediator.peekNext(agent.llmName).getOrThrow{LLMException('no candidate: ${agent.llmName}')}
if(mediator.saturated(conf, messages)){
    messages = pruner.prune(agent.id, session, messages)
}
let resp = mediator.access(agent.id, session, agent.llmName, params)   // 内部重新按权重选
```

已知偏差：`peekNext` 与实际调用之间若发生熔断/刷新，实际平台可能不是 `peekNext` 返回的那个。此时按"**目标平台阈值更小就再裁一次**"处理——`access` 内部命中目标 conf 后做一次 `saturated` 检查，超限则记 `warn` 并放弃该候选（转下一个），不静默超限发送。

---

## 5. 协议层（OpenAI 兼容）

### 5.1 三种形态的分工

| 形态 | 端点 | 报文根 | 流式结束标志 | 工具结果回填 |
|---|---|---|---|---|
| Chat Completions 非流式 | `POST {base}/chat/completions` | `{model, messages, tools, ...}` | — | `role=tool` 消息 |
| Chat Completions 流式 | 同上 + `stream:true` | 同上 | `data: [DONE]` | 组装完整 `tool_calls` 后回填 |
| Responses 非流式 | `POST {base}/responses` | `{model, input, tools, ...}` | — | `function_call_output` 输入项 |
| Responses 流式 | 同上 + `stream:true` | 同上 | `response.completed` 事件 | 同上 |

`LLMApiKind`：

```cangjie
public type LLMApiKind = String
public const LLM_API_CHAT = 'chat'            // OpenAI Chat Completions
public const LLM_API_RESPONSES = 'responses'  // OpenAI Responses API
```

### 5.2 Chat Completions 非流式

复用现有 f_data 通路，只补字段：

```cangjie
@DataAssist[props fields]
public open class LLMRequest {
    public LLMRequest(
        private let llmName!: String = '',
        private var messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
    private var temperature: Float64 = -1.0f64   // <0 表示不覆盖
    private var max_tokens: Int64 = 0            // 0 表示不指定
    private let thinking: Thinking = Thinking()
    private var response_format: ResponseFormat = ResponseFormat.text
    private let functions: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
    private let responses: ResponsesOptions = ResponsesOptions()  // 仅 respond/respondStream 生效
    private let toolLoop: ToolLoopOptions = ToolLoopOptions()     // 见 7.5
    @DataExclude[prop field]
    private let extra: JsonObject = JsonObject() // 方言扩展，原样并入报文
}
```

要点：

- 字段名**必须是蛇形**（`max_tokens`、`response_format`、`tool_choice`）。既有代码已踩过："不能用驼峰命名法再用 `@FieldAlias` 修饰，因为要用这个类的实例转换为 JSON，这样命名会产生 JSON 字段冗余"（`LLMParams.cj:28` 注释）。沿用该约定。
- `temperature < 0` 时**不出现在报文里**——`@DataExclude` 不能按值排除，所以映射层用 `JsonObject` 手工拼装而不是直接 `DataObject<LLMRequest>`。这是与"纯对象直转"的唯一分歧，换取的是不把 `-1` 发给供应商。
- `alwaysThinking` / `conf.temperature` 的覆盖在这里落定（见 5.7）。

### 5.3 Chat Completions 流式

本节全部是**客户端解析**：读上游返回的 `text/event-stream`。本模块不产出 SSE（见 2.2），也**不自己实现解析器**——解析能力放在 `f_httpclient`（见 5.3.1）。

#### 5.3.1 `f_httpclient` 新增的 SSE 客户端

SSE 是 HTTP 客户端层的通用能力（`text/event-stream` 不只大模型用），所以放在 `f_httpclient`，与现有 `readJson()` / `reader()` 同一处扩展：

```cangjie
package fountain::f_httpclient

/** 一条 SSE 事件。只做语法解析，不含任何业务含义 */
public struct SseEvent {
    public SseEvent(
        public let event: String = '',   // event: 字段，缺省为空串
        public let data: String = '',    // data: 字段，多行以 '\n' 拼接
        public let id: String = '',      // id: 字段
        public let retry: Int64 = -1     // retry: 字段，缺省 -1
    ){}
}

/** 阻塞式读取器：一个实例对应一个响应体，非线程安全 */
public class SseReader <: Resource {
    public init(
        body: InputStream,
        maxLineBytes!: Int64 = 1024 * 1024,
        idleTimeout!: Duration = Duration.second * 120
    )
    /** 取下一条事件；流正常结束返回 None。超时抛 SseTimeoutException，超长抛 SseLineTooLongException */
    public func next(): ?SseEvent
    public func close(): Unit
}

/** 与 readJson()/reader() 同一层级的便利入口 */
extend HttpResponse <: ExtendHttpResponse {
    public func sseReader(
        maxLineBytes!: Int64 = 1024 * 1024,
        idleTimeout!: Duration = Duration.second * 120
    ): SseReader
}
```

`f_httpclient` 侧的实现要求（每条都要单测）：

| # | 规则 | 理由 |
|---|---|---|
| 1 | 按字节读 `response.body`（`Array<Byte>(8192)` 循环），**不先 `readToEnd()`** | 流式的前提是增量；`readToEnd` 会把整段生成等完才返回 |
| 2 | 行分隔 `\n`，容忍行尾 `\r` | 有的网关发 `\r\n` |
| 3 | `:` 开头是注释/心跳，整行丢弃（`f_mcp` 服务端就发 `: ping`） | 心跳不能当成事件 |
| 4 | 空行 = 一条事件结束；`field: value` 只认 `event`/`data`/`id`/`retry`，其余字段丢弃 | 只解析需要的最小集 |
| 5 | `data` 多行以 `\n` 拼接；字段值去掉前导一个空格 | 标准行为（`data: x` 的值是 `x`） |
| 6 | 单行超过 `maxLineBytes`（默认 1 MiB）⇒ 抛 `SseLineTooLongException` | 防恶意/异常响应把内存吃光 |
| 7 | `idleTimeout` 内没读到任何字节 ⇒ 抛 `SseTimeoutException` | 与"连接超时"区分开，便于排障 |
| 8 | **返回 `data` 原文，不解释 `[DONE]`、不解析 JSON** | `[DONE]` 是 OpenAI 的约定，不是 SSE 标准；业务语义留在 `f_llm` |
| 9 | `close()` 关闭底层流；`Resource` 实现保证 `resource(...)` 可用 | 中途异常必须关流，否则连接泄漏 |
| 10 | 不做自动重连、不消费 `Last-Event-ID` | LLM 的流是"一次性生成"，断了只能重发请求，重连语义不成立；`id` 仍然解析出来备将来用 |

#### 5.3.2 `f_llm` 侧怎么用

```cangjie
// util/http.cj 新增流式版本：与非流式（util/http.cj:18-26）只差 Accept 头
public func httpStream<T>(url: String, auth: String, callback: (HttpClient) -> T): T {
    let client = HttpClient(url)
    client.header('Authorization', 'Bearer ${auth}')
    client.header('Content-Type', 'application/json')
    client.header('Accept', 'text/event-stream')          // ← 唯一差别
    // TLS 配置与 util/http.cj 现有实现一致：CertificateVerifyMode.TrustAll
    resource(client, callback)
}

// OpenAIContext.accessStream
httpStream(url, auth){http =>
    let resp = http.post('application/json', body)        // body 里 stream = true
    resource(resp.sseReader(
        maxLineBytes: LLMConfig.getStreamMaxLineBytes(),
        idleTimeout: LLMConfig.getStreamIdleTimeout()
    )){reader =>
        while(let Some(ev) <- reader.next()){
            if(ev.data == '[DONE]'){ break }               // ← 业务语义在这里判断
            accumulators.feed(ev)                          // ← 增量归并在 f_llm
        }
    }
}
```

职责边界一句话：**`f_httpclient` 负责"把字节流转成一条条 SSE 事件"，`f_llm` 负责"事件里的 JSON 怎么拼成消息"**。前者可以给任何 SSE 服务用，后者只认 OpenAI 报文。

**增量归并（Chat）**：

| 增量位置 | 归并规则 |
|---|---|
| `choices[0].delta.content` | 追加到 assistant 文本 |
| `choices[0].delta.reasoning_content` / `delta.reasoning` | 追加到 `AssistantMessage.reasoningContent`（两家字段名不同，都认） |
| `choices[0].delta.tool_calls[i]` | 按 `index` 归并；`id`、`function.name` 仅首块出现；`function.arguments` **分片字符串拼接**后再 `JsonValue.fromStr` |
| `choices[0].finish_reason` | 记录；`tool_calls` ⇒ 需要执行工具；`length` ⇒ 记 warn |
| `usage` | 只在末块（需 `stream_options.include_usage=true`，智谱默认带）；缺失时按 10.2 的启发式估算并标 `estimated` |

`tool_calls` 的增量是**最容易错的地方**：`arguments` 会跨块截断在 JSON 的任意位置（甚至 `{"pa` + `th":"x"}`），必须**先拼完再解析**，任何"边收边 parse"的实现都会在长参数上偶发失败。

### 5.4 Responses API

请求侧映射（`ChatMessage` → `input` items）：

| 内部类型 | Responses `input` 项 |
|---|---|
| `SystemMessage` | 提到顶层 `instructions`（官方语义），其余 system 保留为 `{role:'system', content:[{type:'input_text', text}]}` |
| `UserMessage` | `{role:'user', content:[{type:'input_text', text}]}` |
| `AssistantMessage` | `{role:'assistant', content:[{type:'output_text', text}]}` |
| `ToolCallMessage` | `{type:'function_call', call_id, name, arguments}` |
| `ToolMessage` | `{type:'function_call_output', call_id, output}` |

响应侧：`output` 是**异构数组**，按 `type` 分派——`message`（内含 `content[].type='output_text'`）、`function_call`（`call_id` / `name` / `arguments`）、`reasoning`（摘要）。**不能**用 `DataObject<LLMResp>.populate` 一把转，必须手写 `type` 分派。

流式事件（`ResponsesEvent`）：

| 事件 | 处理 |
|---|---|
| `response.created` | 记 `response.id`、`model` |
| `response.output_item.added` | 按 `item.type` 建占位（message / function_call） |
| `response.output_text.delta` | 追加文本，回调 `LLMDeltaKind.Text` |
| `response.function_call_arguments.delta` | 按 `item_id` 追加参数分片 |
| `response.function_call_arguments.done` | 该工具参数完整，产出 `ToolCall` |
| `response.completed` | **以事件里的完整 `response` 对象为准**重建最终响应（含 usage / status），delta 只用于增量展示 |
| `response.incomplete` / `response.failed` / `error` | 抛 `LLMException`（带 `response.error.code`） |

**关键设计决定**：最终响应**以 `response.completed` 为准**，不是以累积的 delta 为准。理由是 delta 可能丢事件（网络抖动）而 `completed` 携带权威快照；这样"流式"与"非流式"的结果在字段上严格一致，业务侧可以只写一套解析。

Responses 专属选项：

```cangjie
@DataAssist[props fields]
public class ResponsesOptions {
    private var previous_response_id: String = ''
    private var instructions: String = ''
    private var store: Bool = false
    private var max_output_tokens: Int64 = 0
    private let reasoning: ReasoningOptions = ReasoningOptions()  // effort / summary
}
```

### 5.5 报文字段映射总表

| 内部概念 | Chat | Responses |
|---|---|---|
| 模型 | `model` | `model` |
| 消息 | `messages[]` | `input[]` + `instructions` |
| 温度 | `temperature` | `temperature` |
| token 上限 | `max_tokens`（新模型用 `max_completion_tokens`，由 `conf` 的 `maxTokensField` 选） | `max_output_tokens` |
| JSON 输出 | `response_format:{type}` | `text.format` |
| 工具 | `tools:[{type:'function',function:{...}}]` | `tools:[{type:'function',name,description,parameters}]`（**扁平，不套 function**） |
| 工具选择 | `tool_choice` | `tool_choice` |
| 思考 | `thinking:{type}`（智谱/火山） / `enable_thinking`（百炼） / `reasoning:{effort}`（官方） | `reasoning:{effort}` |
| 流式 | `stream` + `stream_options.include_usage` | `stream` |
| 用量 | `usage.prompt_tokens / completion_tokens` | `usage.input_tokens / output_tokens` |

### 5.6 错误与重试

```cangjie
public class LLMException <: Exception {
    public LLMException(
        message: String,
        public let status: Int64 = 0,
        public let code: String = '',
        public let requestId: String = '',
        public let retryable: Bool = false,
        public let raw: String = ''
    ){}
}
```

| 情形 | `retryable` | 处置 |
|---|---|---|
| 连接失败 / DNS / TLS | true | 指数退避重试 + 候选转移 |
| `idleTimeout` / 读超时 | true | 同上（流式中断时**从头发起新请求**，不做断点续传） |
| 429 | true | 优先读 `Retry-After`，没有就 1s×2^n，上限 30s |
| 5xx | true | 退避重试 |
| 400/401/403/404/422 | false | 立刻抛；401/403 额外记一条"凭据可能失效" |
| 流中 `error` 事件 | 视 `code` | 已知可重试码才重试 |

重试次数/时长沿用既有配置 `llm_accessTryingCount` / `llm_accessTryingElapsed`（`LLMConfig.cj:55-60`，默认 `Int64.Max`），`AgentTask` 与新的 `LLM.chat` 共用同一套退避实现，不再各写一份。

### 5.7 供应商方言：`ProviderDialect`

不写继承树，用表驱动。每家的差异只有三件事：**端点、鉴权头、报文补丁**。

```cangjie
public interface ProviderDialect {
    prop provider: String
    /** baseUrl + 协议路径；conf 里 chatPath/responsesPath 可覆盖 */
    func endpoint(conf: LLMConf, api: LLMApiKind): String
    /** 鉴权头；默认 Bearer + conf.auth */
    func authHeaders(conf: LLMConf): HashMap<String, String>
    /** 在标准报文上打补丁：thinking / enable_thinking / reasoning / do_sample */
    func decorate(conf: LLMConf, params: LLMParams, body: JsonObject): Unit
    /** 非标准 usage 字段补齐（cached_tokens / reasoning_tokens） */
    func parseUsage(json: JsonObject, usage: TokenUsage): Unit
}

public class DialectRegistry {
    public static func register(dialect: ProviderDialect): Unit   // 同名重复注册 ⇒ 抛异常
    public static func get(provider: String): ProviderDialect     // 未知 provider ⇒ StandardOpenAIDialect
}
```

内置方言只描述**报文语法**（字段长什么样、放哪里），**不描述"模型支不支持思考"**——那是模型的能力，见 5.8。

| provider | 端点路径 | 思考字段形态（语法） | 备注 |
|---|---|---|---|
| `zhipu` | `/chat/completions` | `thinking:{ type: 'enabled'\|'disabled', clear_thinking }` | 还带 `do_sample` / `request_id` |
| `deepseek` | `/chat/completions` | 无该字段（模型自带时也不能开关） | `capability=Always` 时什么也不写 |
| `ark`（火山方舟） | `/chat/completions` | `thinking:{ type }` | |
| `dashscope`（百炼） | `/compatible-mode/v1/chat/completions` | `enable_thinking: Bool` | 形态与上面两家完全不同 |
| `siliconflow` | `/v1/chat/completions` | 透传 `thinking` | |
| `openai` | `/chat/completions`、`/responses` | `reasoning:{ effort, summary }` | `capability=Toggle` 时用 `effort` 表达"关/开" |
| 未注册 provider | `/chat/completions`、`/responses` | 透传原样 | |

`decorate` 的判定顺序：

```cangjie
func decorate(conf: LLMConf, params: LLMParams, body: JsonObject): Unit {
    let cap = ModelCapabilities.thinking(conf)          // 模型能力，不是平台能力
    match(cap){
        case ThinkingCapability.None => ()              // 模型不支持，一个字段都不写
        case ThinkingCapability.Always =>
            writeThinking(body, enabled: true)          // 恒思考：写不写都行，写了更明确
            body.remove('temperature')                  // 推理模型不收 temperature
        case ThinkingCapability.Toggle =>
            writeThinking(body, enabled: params.thinking.`type` == THINGKING_ENABLED || conf.alwaysThinking)
    }
}
```

`writeThinking` 是 dialect 的实现（智谱写 `thinking:{type}`、百炼写 `enable_thinking`……）。这样"要不要思考"由模型定，"怎么写"由平台定，两件事不会互相污染。

`temperature` 与思考的冲突：`capability=Always` 的模型普遍不接受 `temperature != 1`，规则是**丢弃 `temperature` 并记 `warn`**，不把请求打回去——业务侧不该为了温度去改一遍全部调用点。

### 5.8 模型能力：`ThinkingCapability`

评审明确：**思考是模型属性，不是平台属性**。同一个智谱账号下，`glm-5` 可开关思考，某些纯生成模型压根没有思考通道；同一家的 `deepseek-reasoner` 恒思考、`deepseek-chat` 不思考。所以按平台建表一定会错。

```cangjie
public enum ThinkingCapability {
    | None      // 模型没有思考通道：不写任何相关字段
    | Always    // 模型恒思考：无法关闭，且通常不接受 temperature
    | Toggle    // 可开可关：由 alwaysThinking / 请求参数决定
}

public interface ModelCapabilities {
    func thinking(actualLlmName: String): ThinkingCapability
    /** 恒思考模型通常不接受 temperature != 1 */
    func supportsTemperature(actualLlmName: String): Bool
}
```

解析顺序（**逐级覆盖，先命中先返回**）：

1. `LLMConf.conf['thinking']` 显式配置：`none` / `always` / `toggle` —— 这是运维兜底，任何模型都能手工纠正；
2. 内置能力表（按 `actualLlmName` 前缀匹配，只登记"确定如此"的模型）：

   | 模型名（前缀） | capability | 依据 |
   |---|---|---|
   | `deepseek-reasoner` | `Always` | 推理模型，无开关 |
   | `deepseek-chat` | `None` | 普通对话模型 |
   | `glm-5` / `glm-4.5` 及以上 | `Toggle` | 智谱支持 `thinking:{type}` 开关 |
   | `qwen3` 系列 | `Toggle` | 百炼支持 `enable_thinking` |
   | `o1` / `o3` / `gpt-5` 系列 | `Always` | 官方推理模型 |
   | 未登记 | `Toggle` | 保守默认：可开关，由调用方决定 |

3. 未命中任一规则 ⇒ `Toggle`。

三条落地约束：

- **`alwaysThinking=true` 遇到 `None`**：记 `warn`（"配置要求强制思考，但模型不支持"）并继续发请求，不抛异常——配置错误不该让整条业务链断掉。
- **`Always` 时忽略调用方的"关闭思考"**：模型没这个开关，传了也没用，只在 `debug` 记一句。
- 内置表只是"确定值的集合"，不是全集；未登记的模型走 `Toggle` + `conf['thinking']` 兜底。新增模型时优先改配置，**不急着改代码**。

`GLMContext` 的归宿：**删除**。`provider='zhipu'` 的 `OpenAIContext` + `ZhipuDialect` 已完全覆盖它的行为（`thinking`、`do_sample`、`request_id` 都在 dialect 的 `decorate` 里），留着它等于让"平台实现"有两套入口。全仓引用只有 `LLMContextMediator` 的 `static init`，删掉不影响外部项目（`fcoder` 用的是 `LLMContextMediator`，不是 `GLMContext`）。

---

## 6. 对外仓颉 API

### 6.1 分层

```
应用进程（fboot 起的服务器）
   │  HTTP / SSE / WebSocket —— 由其他模块负责（如 f_mvc），本模块完全不参与
   ▼
业务/其他模块（fcoder、应用 Service）
   │  只依赖这一层
   ▼
LLM（门面，静态方法）        ← 本文档新增，稳定契约
   │
   ▼
LLMContextMediator          ← 快照 / 刷新 / 权重调度 / 熔断
   │
   ▼
AbstractLLMContext          ← 平台适配（OpenAIContext 唯一实现 + Dialect）
   │
   ▼
f_httpclient（HttpClient + sseReader）/ f_data / f_log
```

分层规则：

- **业务侧不直接接触 `AbstractLLMContext`**；`Mediator` 留给需要"拿到候选、算阈值"的编排代码（`ContextPruner` 就是）。
- **本模块不出现在任何 URL 路径上**。若应用要把流式结果推给浏览器，由应用模块在 `chatStream` 的回调里写自己的输出通道（`f_mvc` 的 SSE 响应、消息队列、日志），本模块只负责"产出增量"。

### 6.2 门面 `LLM`

```cangjie
package fountain::f_llm.llm

public class LLM {
    private init(){}

    /** Chat Completions 非流式 */
    public static func chat(req: LLMRequest): LLMResponse

    /** Chat Completions 流式：每个增量回调一次；返回聚合后的完整响应 */
    public static func chatStream(req: LLMRequest, onDelta: (LLMDelta) -> Unit): LLMResponse

    /** Responses API 非流式 */
    public static func respond(req: LLMRequest): LLMResponse

    /** Responses API 流式：每个 SSE 事件回调一次；返回聚合后的完整响应 */
    public static func respondStream(req: LLMRequest, onEvent: (ResponsesEvent) -> Unit): LLMResponse
}
```

为什么是四个方法而不是一个带 `api` 字段的方法：`chat` 与 `respond` 的**请求语义不同**（`messages` vs `input`+`instructions`+`previous_response_id`），合成一个入口会让调用方一半字段永远用不上，且无法在编译期区分"流式/非流式"的误用。四个方法各自只有一个参数组合要记。

为什么流式用**回调**而不是 `Iterator`：仓颉里把阻塞读包装成迭代器，要么用 `Channel`（生产者线程 + 消费线程，超时/取消路径要自己管），要么退化成"先读完再迭代"（那就不是流式）。回调把生命周期压在调用栈上，实现 30 行，语义最清楚。需要收集时用 `LLMDeltaCollector`：

```cangjie
public class LLMDeltaCollector {
    public func on(delta: LLMDelta): Unit
    public func text(): String
    public func reasoning(): String
    public func toolCalls(): ArrayList<ToolCall>
    public func firstChunkElapsed(): Duration   // TTFT
}
```

### 6.3 响应与增量类型

```cangjie
@DataAssist[props fields]
public class LLMResponse {
    private let id: String = ''
    private let provider: String = ''
    private let actualLlmName: String = ''
    private let api: LLMApiKind = LLM_API_CHAT
    private let messages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    private let usage: TokenUsage = TokenUsage()
    private let finishReason: String = ''
    private let elapsed: Duration = Duration.Zero
    private let raw: JsonValue = JsonObject()    // 原始报文，排障用；默认不进日志
}

public enum LLMDeltaKind {
    | Start        // 首块，带 id / model
    | Text         // content 增量
    | Reasoning    // 思考增量
    | ToolCall     // 工具参数已完整
    | Usage        // 用量（末块）
    | Done         // 结束
}

@DataAssist[props fields]
public class LLMDelta {
    private let kind: LLMDeltaKind = LLMDeltaKind.Text
    private let content: String = ''
    private let toolCall: ?ToolCall = None<ToolCall>
    private let usage: ?TokenUsage = None<TokenUsage>
}
```

### 6.4 三个使用示例

**非流式 + 工具（最常用）**：

```cangjie
let req = LLMRequest(llmName: 'qwen-plus', messages: messages)
req.temperature = 0.3f64
for(def in FunctionMediator.getDefinitions(['currentTime', 'webSearch'])){
    req.functions.add(def)
}
let resp = LLM.chat(req)
for(msg in resp.messages){
    if(let t: ToolCallMessage <- msg){
        for(call in t.tool_calls){
            let result = FunctionMediator.call(call.function.name, JsonValue.fromStr(call.function.arguments).asObject())
            // 把 result 包成 ToolMessage 后再次 LLM.chat
        }
    }
}
```

**流式（控制台增量输出）**：

```cangjie
let req = LLMRequest(llmName: 'glm-5', messages: messages)
req.messages.add(UserMessage('用三句话说明 SSE 与 WebSocket 的区别'))
let resp = LLM.chatStream(req){delta =>
    match(delta.kind){
        case LLMDeltaKind.Text => print(delta.content)
        case LLMDeltaKind.Reasoning => ()
        case _ => ()
    }
}
println()
println('tokens: ${resp.usage.total}, 耗时: ${resp.elapsed}')
```

**Responses API（多轮 + 服务端状态）**：

```cangjie
let req = LLMRequest(llmName: 'gpt-5', messages: ArrayList<ChatMessage>([UserMessage('继续上一轮')]))
req.responses.previous_response_id = lastResponseId
req.responses.store = true
let resp = LLM.respondStream(req){event => /* 按 event.type 展示 */ ()}
```

### 6.5 破坏性变更清单

不做兼容期，旧 API 直接删。改动范围可枚举（全仓 grep 后只有这些）：

| 旧 API / 字段 | 处理 | 影响面 |
|---|---|---|
| `LLMContextMediator.access(agentId, session, llmType, params)` | **删除**，改为 `access(..., llmName, ...)` | `AgentTask.cj:425`、`ContextPruner.cj:67`、`Memory.cj:70` |
| `getTokenThreshold(llmType, model)` / `tokenize(llmType, model, msgs)` / `saturated(llmType, model, msgs)` | **删除**，改为按 `conf: LLMConf` 传入（`getTokenThreshold(conf)` / `tokenize(conf, msgs)` / `saturated(conf, msgs)`） | `ContextPruner.cj:153`、`AgentTask` 相关路径 |
| `AbstractLLMContext` 的 6 个散装构造参数 | 改为持有 `LLMConf` 一个对象 | `GLMContext`、`EmbeddingContextMediator` |
| `GLMContext` | **删除**（`provider='zhipu'` 的 `OpenAIContext` 完全等价） | 无外部引用，仅模块内注册表 |
| `LLMRouter` / `PriorityFailoverRouter`（v0.1 设计） | 不实现，改由 `LoadBalance` + 熔断 | —— |
| `LLMConf.name` | 改名 `llmName` | `AbstractLLMContext.cj:28`、`AbstractSearcher.cj:55`、`LLMContextMediator.cj:49`、`SearchMediartor.cj:55` |
| `LLMConf.llmType` | 删除，改 `conf['llmType']` | `EmbeddingContextMediator.cj:47`、`LLMContextMediator.cj:48`、`SearchMediartor.cj:54` |
| `LLMConf.threshold` | 删除，改 `conf['tokenThreshold']` | `AbstractLLMContext.cj:28`、`ContextPruner.cj:153` |
| `LLMConf.conf: String` | 改为 `HashMap<String,String>` | 4 处读取点改为 `option(...)` |
| `LLMFinder.listConfs(llmTypes)` | 改为无参 `listConfs(): ArrayList<LLMConf>` | `fcoder/src/service/LLMService.cj:18-20`、`LLMServiceImpl.cj:22-24`、`LLMDAO.cj:22-26` |
| `llm_conf` 表结构 | 按 3.3 **重建**，不迁数据 | 运维需人工录入新配置 |
| `AbstractSearcher` / `SearchMediator` 的 `register(engine, ...)` | **删除**，搜索改为 `WebSearchFunction` 内部按 `provider` 直接调（见 7.4） | `GLMSearcher.cj`、`SearchMediartor.cj`、`fcoder/KnowledgeServiceImpl.cj:34` |

一次性改完，不留 `@Deprecated` 壳：留壳等于让"两套模型名语义"长期共存，后面每加一个平台都要维护两遍。

---

## 7. tool_call

### 7.1 保留什么

`FunctionCalling<T>`（`tool/FunctionCalling.cj:42-77`）、`CommonFunctionCalling`、`FunctionResult`、`@ToolCall` 宏、`FunctionMediator` 的 Bean 扫描**全部保留**。理由：这套已经能用，且 `@ToolCall` 宏会把类的公共函数注册成工具（`macros/ToolCall.cj:43-72`），换掉等于把 `fcoder` 的技能/命令/文件函数全部重写。

### 7.2 工具的三个来源

```
                 ┌────────────────────────┐
                 │     FunctionMediator   │
                 └───────┬────────────────┘
        ┌────────────────┼──────────────────┐
        ▼                ▼                  ▼
   Bean 扫描         内置函数             MCP 工具
(@Bean/@ToolCall)  (currentTime,       (McpToolSource,
                     webSearch,         名字带 mcp__ 前缀)
                     webFetch)
```

```cangjie
public struct FunctionMediator {
    public static func register(calling: CommonFunctionCalling): Unit       // 新增：手工注册
    public static func registerMcp(alias: String, client: McpClient): Unit  // 新增：整台 server 的工具批量注册
    public static func getDefinitions<I>(funcNames: I): Iterator<FunctionCall> where I <: Iterable<String>
    public static func call(function: String, args: JsonObject): FunctionResult
}
```

懒加载顺序：先 Bean 扫描，再内置，最后 MCP。任何两个来源产出同名工具 ⇒ **立刻抛 `FunctionCallingException`**，消息里带两个来源，不做隐式覆盖。仓库既有决策一致：命名冲突优先报错，不做隐式优先级。

### 7.3 内置函数 `currentTime`

```cangjie
@DataAssist[props fields]
public class CurrentTimeParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'IANA 时区名，如 Asia/Shanghai；空串表示本机时区']
    private var timezone: String = ''
    @JsonStringSchema[description:'输出格式：iso8601（默认）或 human']
    private var format: String = 'iso8601'
}

@Bean
public class CurrentTimeFunction <: FunctionCalling<CurrentTimeParams> {
    public prop name: String { get(){ 'currentTime' } }
    public prop description: String { get(){ '返回本机当前时间，用于需要"现在"的场景（日期换算、时效判断）' } }
    public func call(params: CurrentTimeParams): FunctionResult
}
```

实现要点：

- 基准是**本机时间**（`DateTime.now()`），带 `zoneOffset`；
- `timezone` 非空时用 `Asia/Shanghai` 这类 IANA 名做偏移换算；不支持的名字返回错误文本（不抛），让模型自己改参数；
- `format='human'` 输出 `2026-10-26 14:03:21 +08:00 (Monday)`；
- 返回值里**同时给 ISO 与 epoch 毫秒**，模型算差值时更稳。

### 7.4 内置函数 `webSearch`

```cangjie
@DataAssist[props fields]
public class WebSearchParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'查询关键词，支持 site: / -site: / 引号等语法']
    private var query: String = ''
    @JsonStringSchema[description:'返回条数，1~50，默认 10']
    private var count: Int64 = 10
    @JsonStringSchema[description:'强制指定平台：zhipu / deepseek；空串表示自动选择']
    private var provider: String = ''
    @JsonStringSchema[description:'是否返回网页正文（体积大），默认 false']
    private var needContent: Bool = false
}

@Bean
public class WebSearchFunction <: FunctionCalling<WebSearchParams> {
    public prop name: String { get(){ 'webSearch' } }
    public prop description: String { get(){ '联网搜索，返回标题、摘要与链接；需要正文时把 needContent 设为 true' } }
    public func call(params: WebSearchParams): FunctionResult
}
```

**搜索能力是可注册的，不是硬编码集合**（评审 B10：以后可能接入更多平台）：

```cangjie
/** 一个平台能提供哪些工具能力，由它自己声明 */
public interface SearchProvider {
    prop provider: String
    prop searchEndpoint: String            // 可被 conf['searchUrl'] 覆盖
    prop fetchEndpoint: String             // 空串 = 不支持抓取
    func search(conf: LLMConf, query: String, count: Int64, needContent: Bool): ArrayList<SearchResultItem>
    func fetch(conf: LLMConf, url: String): FetchedPage
}

public class SearchProviderRegistry {
    public static func register(provider: SearchProvider): Unit   // 同名重复注册 ⇒ 抛异常
    public static prop instance: SearchProviderRegistry
    public func get(provider: String): ?SearchProvider
    public func providers(): Iterator<SearchProvider>
}
```

注册来源与 `BalanceQuerier` 一致：`@Bean` 自动发现 + 显式 `register` 两条路。内置 `ZhipuSearchProvider`、`DeepSeekSearchProvider` 两个 `@Bean`，新增平台**加一个类即可，不改框架代码**。

**凭据来源（评审 15.4）**：搜索不需要单独的配置记录，直接从**已启用的 `LLMConf`** 里挑一个支持该能力的平台，借它的 `auth`：

```cangjie
private func pickConf(provider: String, needFetch: Bool): LLMConf {
    let registry = SearchProviderRegistry.instance
    var cands = LLMContextMediator.instance.candidates()          // 已过滤 enabled && weight>0
        .filter{c => let p = registry.get(c.provider); p.isSome() && (!needFetch || !p.getOrThrow().fetchEndpoint.isEmpty())}
    if(!provider.isEmpty()){
        cands = cands.filter{c => c.provider == provider}
    }
    let avail = cands.filter{c => !LLMContextMediator.instance.isCircuitOpen(c.id)}
    if(avail.isEmpty()){
        throw SearchUnavailableException(provider: provider, needFetch: needFetch)
    }
    avail[0]          // 真实实现按权重起点取，与 4.3 同一套顺序
}
```

- **一个都没有 ⇒ 抛 `SearchUnavailableException`**（评审 B9），消息里带 `provider` / 是否需要 fetch / 当前已注册的 provider 列表。理由：工具静默"返回一段错误文本"会被模型当成搜索结果继续编，抛异常才能让编排层知道"这次工具没跑起来"。
- 顺手解决旧实现的毛病：`name='glm|search-pro'` 里塞引擎、`llmType='search'` 占一条模型配置（`GLMSearcher.cj:25`、`LLMContextMediator.cj:48`），搜个网页还要先"配一个假模型"。
- `provider` 显式指定时只在该平台选；没有就抛，**不跨平台静默回退**（否则搜索结果来源不可追溯）。

**平台契约（已核实）**：

| 项 | 智谱 | DeepSeek |
|---|---|---|
| 端点 | `POST {base}/web_search`（base 取 `LLMConf.url`，如 `https://open.bigmodel.cn/api/paas/v4`） | `POST https://api.deepseek.com/v1/tools/search` |
| 鉴权 | `Authorization: Bearer {conf.auth}` | 同左 |
| 请求字段 | `search_query` / `search_engine`（`conf['searchEngine']`，如 `search_pro`）/ `count` / `content_size` | `query`（必填，≤128 字符）/ `count`（1~50，默认 10）/ `ori_question` / `localization` / `need_content`（默认 false） |
| 响应字段 | `search_result[].{ title, content, link, media, icon, refer, publish_date }` | `results[].{ rerank_score, title, url, snippet, summary, content, site_name, site_icon, date, authority }` |
| 参考 | 现有 `search/GLMSearcher.cj:27-50` 已跑通 | 官方文档 `api-docs.deepseek.com/zh-cn/api/search` |

DeepSeek 的结果里 `snippet`（约 100~200 字）适合展示，`summary`（约 600~800 字）适合喂模型；默认返回 `summary`，`needContent=true` 时才取 `content`。`rerank_score >= 1.5`、`authority >= 3` 可作为"优质结果"的过滤线，实现里按 `rerank_score` 降序，不额外过滤（别替模型做取舍）。

**返回给模型的统一结构**（两个平台归一，便于模型复用）：

```json
[{"title":"...","url":"...","summary":"...","date":"2026-06-01","score":2.4}]
```

整体序列化后按 `llm_toolResultMaxBytes`（默认 64 KiB）截断，并在尾部标注 `[已截断]`。

**计费提醒**：DeepSeek 搜索按次计费（5 元 / 1000 次成功请求，HTTP 200 且 `results` 非空才计），所以不要把它放在"猜一下"的循环里；工具描述里要明确"只在确实需要外部事实时调用"。

#### 7.4.1 `webFetch`（评审 A7：实现）

`needContent=true` 能覆盖"搜到就读"，但**模型拿着一个具体 URL 要读全文**时，搜索引擎的 `content` 字段并不可靠（可能为空、可能只有摘要）。所以单独给一个抓取工具：

```cangjie
@DataAssist[props fields]
public class WebFetchParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var event: String = ''
    @JsonStringSchema[description:'要抓取的网页地址，必须是 http/https']
    private var url: String = ''
}

@Bean
public class WebFetchFunction <: FunctionCalling<WebFetchParams> {
    public prop name: String { get(){ 'webFetch' } }
    public prop description: String { get(){ '抓取单个网页并返回 Markdown 正文，用于已知 URL 需要读全文的场景' } }
    public func call(params: WebFetchParams): FunctionResult
}
```

契约（DeepSeek，已核实）：`POST https://api.deepseek.com/v1/tools/fetch`，`Authorization: Bearer {conf.auth}`，请求 `{ "url": "..." }`（≤8192 字符，必须带 host，不能含用户名密码），响应 `{ "title": "...", "content": "<markdown>" }`。错误语义：`403` 被安全策略拒绝、`404` 拿不到可用正文、`429` 限流、`5xx` 服务端错。

**SSRF 防护（必须实现，不是可选项）**——这个工具让模型能指定任意 URL，等于把一个"内网探针"交给模型：

| 规则 | 说明 |
|---|---|
| 只允许 `http` / `https` | `file:` / `ftp:` / `gopher:` 一律拒绝 |
| 解析后的 IP 必须在公网 | 拒绝 `127.0.0.0/8`、`10/8`、`172.16/12`、`192.168/16`、`169.254/16`（含云元数据 `169.254.169.254`）、`::1`、`fc00::/7`、`fe80::/10` |
| 先解析再校验，校验后再连接 | 防 DNS rebinding：不能"校验域名 → 再让 HTTP 客户端自己解析" |
| 禁止跳转跟随到内网 | 最多跟 3 跳，每跳都重新做 IP 校验；跳到内网直接拒绝 |
| 响应体上限 | 默认 256 KiB（`llm_fetchMaxBytes`），超了截断并标注 `[已截断]` |
| 只取正文，不落盘 | 不缓存、不写文件，避免变成"任意文件写"的跳板 |

失败处理：**抛 `FetchRejectedException`**（带拒绝原因），与搜索一致——不返回"抓取失败"的假文本让模型继续编。

计费：与搜索同价（5 元 / 1000 次成功请求，HTTP 200 且返回正文才计），工具描述里写清"只在需要读全文时调用，不要拿它做探测"。

### 7.5 工具循环

`AgentTask` 现有的单轮模式（`AgentTask.cj:459-507`：调一次模型 → 执行全部 tool_calls → 产出事件）保留不动，因为 `fcoder` 的编排语义是"每次调用都必须产生一个事件"。

给普通调用方新增**自动循环**（在 `LLM.chat` 内部，可选开启）：

```cangjie
@DataAssist[props fields]
public class ToolLoopOptions {
    private var enabled: Bool = false
    private var maxRounds: Int64 = 8
    private var eventName: String = 'toolResult'      // 注入到工具参数 JSON 的 event
    private var session: String = ''
}
```

循环语义：

1. 请求 → 若 `finish_reason == 'tool_calls'`，逐个 `FunctionMediator.call`；
2. 工具结果包成 `ToolMessage` 追加到 `messages`，再请求一次；
3. 轮数达 `maxRounds` 仍未收尾 ⇒ 停，返回最后一次响应并在 `finishReason` 标 `tool_rounds_exceeded`；
4. 单个工具抛异常 ⇒ 把异常文本作为 `ToolMessage` 内容回给模型（现有 `AgentTask.cj:499-502` 的做法），不中断整轮。

`eventName` 是必需的：`FunctionResult` 在 `event` 为空时直接抛异常（`tool/FunctionResult.cj:39-41`）。所以自动循环必须注入一个事件名，参数里已有 `event` 键时**不覆盖**。

### 7.6 命名与冲突

| 来源 | 工具名 | 规则 |
|---|---|---|
| Bean / `@ToolCall` | 原样 | 必须匹配 `^[A-Za-z0-9_-]{1,64}$`，否则启动失败 |
| 内置 | `currentTime` / `webSearch` / `webFetch` | 固定 |
| MCP | `mcp__{alias}__{tool}` | 非法字符替换为 `_`；**不做任何截断**（评审 B8）——总长或字符集不合法直接失败 |

**不截断的理由**：截断 + hash 会让日志、模型看到的工具名与 MCP server 里的真实工具名对不上，排障时要反推 hash；长度是配置问题（改短 alias 即可），不该由框架悄悄改名。所以：

- `mcp__{alias}__{tool}` 超过 64 字符 ⇒ 启动失败，消息里给出实际长度与"请缩短 alias"；
- 含非法字符 ⇒ 先做 `_` 替换再判长度，替换后仍不合法（如首字符是数字以外的问题）⇒ 失败；
- 长度校验统一在**首次构建工具表**时做，不带病运行。

冲突处理三档：同名同来源（同一 server 里两个同名工具）⇒ 失败；跨来源同名 ⇒ 失败；MCP 别名重复 ⇒ 失败。同样在**首次构建工具表时**抛出。

---

## 8. MCP 集成（`f_mcp`）

### 8.1 配置

MCP 是"工具来源"，与具体模型无关，因此**不塞进 `LLMConf.conf`**，单独一张表。

本模块只用 `f_mcp` 的**客户端**（`McpClient`）：往外连 MCP server 取工具、调工具。把智能体自身暴露成 MCP server 是应用层的事（`f_mcp` 的服务端能力 + 应用模块的路由），不在本模块职责内——本模块不注册任何 MCP 端点。

```cangjie
@DataAssist[props fields]
@QueryMappersGenerator[table: mcp_server]
public class McpServerConf {
    @ORMField[true 'id']
    private var id: Int64 = 0
    @ORMField['alias']                 // 工具名前缀，全局唯一
    private var alias: String = ''
    @ORMField['transport']             // http | stdio
    private var transport: String = 'http'
    @ORMField['url']                   // transport=http
    private var url: String = ''
    @ORMField['command']               // transport=stdio
    private var command: String = ''
    @ORMField['args']                  // JSON 数组串
    private var args: String = ''
    @ORMField['headers']               // JSON 对象串，鉴权头在这里（同样支持 secretRef）
    private var headers: String = ''
    @ORMField['timeout_ms']
    private var timeout: Int64 = 30000
    @ORMField['enabled']
    private var enabled: Bool = true
}
```

### 8.2 适配层

```cangjie
package fountain::f_llm.mcp

public class McpToolSource {
    public init(conf: McpServerConf)
    /** 连接并列举全部工具（分页已由 listAllTools 内部处理） */
    public func load(): Unit
    public func tools(): ArrayList<McpTool>
    public func call(name: String, arguments: JsonObject): FunctionResult
    public func close(): Unit
}

public struct McpTool {
    public McpTool(
        public let name: String,            // mcp__{alias}__{tool}
        public let description: String,
        public let definition: JsonObject,   // 已是 OpenAI function 定义
        public let descriptor: McpToolDescriptor
    ){}
}
```

底层 API（已核实签名）：

- `McpClient.http(url, options!)` / `McpClient.stdio(command, args, options!)`（`f_mcp/src/client/McpClient.cj:276-284`）
- `listAllTools(): Array<McpToolDescriptor>`（`:300`）
- `callTool(name, arguments!): CallToolResult`（`:321`）
- `McpToolDescriptor` 有 `name` / `description` / `inputSchema: JsonObject` / `raw`（`f_mcp/src/base/McpModels.cj:182-201`）

### 8.3 工具定义转换

`inputSchema` 本身就是 JSON Schema，但**不能原样塞给模型**：

| 风险 | 处置 |
|---|---|
| 带 `$schema` / `$id` / `definitions` / `$ref` | 只保留 `type/properties/required/additionalProperties` 白名单；`$ref` 无法解析时降级为 `{type:'object'}` |
| `additionalProperties: true` | 部分模型直接 400，改为 `false` |
| `required` 缺失 | 补 `[]` |
| 属性 `description` 过长（> 1024） | 截断 |
| 属性类型是 MCP 扩展（如 `type: ['string','null']` 联合） | 取第一个非 `null` |

转换结果与 `FunctionCalling.definition` 的形态对齐，这样 `FunctionMediator.getDefinitions` 与 MCP 工具对调用方**完全同构**。

### 8.4 调用结果转换

`CallToolResult`（`f_mcp/src/base/McpContent.cj:110-146`）→ `FunctionResult`：

1. `isError == true` ⇒ 返回文本 `[MCP 错误] ...`，**不抛异常**（让模型自愈，与 7.5 一致）。注意这与 7.4 的"搜索无配置抛异常"不矛盾：MCP 的 `isError` 是**工具跑起来了、业务失败**，属于可以回给模型的信息；搜索无可用配置是**框架没能力跑这个工具**，必须在调用方暴露。
2. 有 `structuredContent` ⇒ 用 `JsonValue` 序列化成字符串作结果（保留结构）；
3. 否则取 `content` 中 `type == 'text'` 的块，按顺序拼接；非文本块（image/audio/resource）只留占位描述 `<image 1024B>`，不塞 base64 进上下文；
4. 拼接结果超过 `conf.maxToolResultBytes`（默认 64 KiB）⇒ 截断并在尾部标注，避免一次工具调用把上下文打爆。

### 8.5 生命周期

| 项 | 处置 |
|---|---|
| 连接时机 | 懒加载：首次需要工具表时连接；构建失败不阻塞进程启动，但记 `error` 并把该 alias 标记为不可用 |
| 复用 | 一台 server 一个 `McpClient`，进程内共享；`http` 用 `keepAlive=true`（`McpClientOptions.keepAlive`） |
| 关闭 | `f_llm` 提供 `McpToolSources.closeAll()`，由应用在停机钩子里调用；stdio 子进程随进程退出兜底 |
| 超时 | 工具调用超时取 `min(McpServerConf.timeout, 请求剩余时间)`，超时按 7.5 回给模型 |
| 并发 | `McpClient` 不保证并发安全 ⇒ `McpToolSource` 内部串行化（`Mutex`），必要时按 alias 建连接池（M2 先串行，压测后再说） |

---

## 9. 上下文压缩 / 裁剪（保持）

### 9.1 现状

`ContextPruner` 及 6 个实现全部保留，语义、名字、`name` 拼装规则**一行不改**：

| 策略 | 名字形态 | 是否依赖大模型 |
|---|---|---|
| `RetainContextPruner` | `Retain` | 否 |
| `LastNContextPruner` | `LastN_{n}` | 否 |
| `ContextSummaryPruner` | `Summary_BY_{llmType}_{model}` | 是 |
| `ContextKeywordsPruner` | `Keywords_BY_{llmType}_{model}` | 是 |
| `DRCContextPruner` | `DRC_{system}_{others}` | 否（内部组合） |
| `SaturationContextPruner` | `Saturation_{pruner}` | 否（只查阈值） |
| `RetainLastUserPruner` | `RetainLastUser_{pruner}` | 否 |
| `RetainLastNRoundPruner` | `RetainLastNRound_{pruner}` | 否 |

源码：`f_llm/src/llm/ContextPruner.cj:20-213`、`ContextPrunerMediator.cj:18-42`。

**唯一需要动内部逻辑的是 `SaturationContextPruner`**：它现在从 `agent.llmType + agent.llmName` 反查阈值（`ContextPruner.cj:152-153`），而 `llmType` 列已删除。改为"先取平台、再判饱和"：

```cangjie
public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage> {
    let agent = lookup<AgentsFinder>().queryAgent(agentId)
    let conf = LLMContextMediator.instance.peekNext(agent.llmName)
                   .getOrThrow{LLMException('no candidate: ${agent.llmName}')}
    if(LLMContextMediator.instance.saturated(conf, messages)){
        pruner.prune(agentId, session, messages)
    }else{
        messages
    }
}
```

其余 7 个策略（`Retain` / `LastN` / `Summary` / `Keywords` / `DRC` / `RetainLastUser` / `RetainLastNRound`）**一行不改**。

### 9.2 唯一需要改的地方：`tokenize`

现在 `tokenize` 直连智谱的 `/api/paas/v4/tokenizer`（`GLMContext.cj:135-142`）。换供应商后这个端点不存在，`SaturationContextPruner` 会直接抛异常。改为策略化：

```cangjie
public interface TokenCounter {
    prop provider: String
    /** 按具体 conf 计数（tokenizer 端点与模型名都是平台/模型相关的）；返回 -1 表示无法精确计数 */
    func count(conf: LLMConf, messages: ArrayList<ChatMessage>): Int64
}

public class RemoteTokenCounter <: TokenCounter    // 智谱，走 conf['tokenizerUrl']
public class HeuristicTokenCounter <: TokenCounter // 兜底：CJK 1 字 ≈ 1 token，其余 4 字符 ≈ 1 token
```

`saturated` 的降级：拿不到精确值（-1）时用启发式估算，并把阈值按 0.9 折算，避免估算偏小导致超限。阈值来源改为 `LLMConf.tokenThreshold`（即 `conf['tokenThreshold']`），**按传入的 conf 判断、不跨平台聚合**（4.5）；该值为 `0` 表示这个平台不限制（`saturated` 返回 `false`）。

### 9.3 边界：裁剪不属于单次调用

`LLM.chat/chatStream` **不做自动裁剪**——裁剪需要 `agentId`、`session`、`pruner` 三样上下文，属于会话编排（`AgentTask` 已在这些位置调用 `ContextPrunerMediator.prune`，`AgentTask.cj:411`）。把这个职责塞进 `LLM` 会让"单次调用"变得不可预测，也会让 `ContextSummaryPruner` 递归调用自己。

---

## 10. 日志与序列化

### 10.1 `f_log`

沿用既有用法（`LoggerFactory.getLogger<T>()` + `log.info{...}` / `log.error(e){...}`，见 `GLMContext.cj:76,127-131`），补充规约：

**默认级别就是 `info`**（评审 R8）——正常路径不依赖调高级别才能看到东西；`debug` 只放"请求体、逐块细节"这类排障才需要的内容。

**每次调用一个 `requestId`**（`f_util.UUID.random().toString()`，与 `GLMParams.request_id` 现行为一致），贯穿：请求 → 每个 SSE 块（不记内容）→ 工具调用 → 响应。

| 场景 | 级别 | 内容 |
|---|---|---|
| 配置装载/刷新 | `info` | `version / 条数 / 耗时`；刷新失败 `error`（带异常，保留旧版本号） |
| 请求发出 | `debug` | `requestId / provider / actualLlmName / api / stream / 消息条数 / 工具数` |
| 请求体 | `debug` | 截断到 `llm_logBodyLimit`（默认 4096 字节），**脱敏后** |
| **调用完成** | **`info`** | `requestId / provider / actualLlmName / 耗时 / TTFT（流式）/ TokenUsage(prompt/completion/cached/reasoning/total) / finish_reason` |
| 流式增量 | —— | **不逐块打日志**（一条 8K 输出会产生上千行）；只在结束时打 chunk 数 |
| 可重试失败 | `warn` | `requestId / status / code / 第 n 次重试 / 下次候选 / 该 conf 累计失败数` |
| 触发熔断 | `warn` | `confId / provider / actualLlmName / 失败次数 / 下线时长` |
| 最终失败 | `error` | 带异常对象 + 响应体（截断） |
| 余额查询 | `info` | `provider / 可用余额 / 币种`；低于阈值时 `warn` |

**`TokenUsage` 只进日志，不落库**（评审 R10）：每次调用结束打一行结构化用量就够做趋势统计；需要持久化的应用自己实现 `TokenUsageSaver`（接口保留，本模块不主动调用）。

**脱敏**（统一走 `Redactor`，规则是评审 R9：前 4 + `****` + 后 4）：

```cangjie
public struct Redactor {
    /** 前 4 + '****' + 后 4；长度 < 12 时全部 '****'。例：'sk-a1b2c3d4e5f6' -> 'sk-a****e5f6' */
    public static func mask(secret: String): String
    /** 对 JSON 递归处理：命中 auth/authorization/api_key/accessKeySecret/*Secret*/*Key*/*Token* 的字符串值掩码 */
    public static func json(obj: JsonObject): JsonObject
    /** 对 conf 选项表处理（余额查询的 secretRef / accessKeyId 等也在内） */
    public static func options(conf: HashMap<String, String>): HashMap<String, String>
}
```

`LLMConf.toString()` 必须走 `Redactor`——否则 `@DataAssist[... tostring]` 一开，KEY 就进了日志。

### 10.2 `f_data`

| 场景 | 做法 |
|---|---|
| 非流式请求 | 手拼 `JsonObject`（因为要按值排除 `temperature=-1`）；值本身用 `JsonValue.fromData` / `toData` |
| 非流式响应 | `DataObject<LLMResponse>.populate(json.toData())`；异构部分（`choices[]`）按 `finish_reason` / `message` 字段分派 |
| 流式增量 | **手工 `JsonObject.get`**。`DataObject.populate` 是整对象覆盖语义，不能表达"拼接" |
| 工具定义 | `FunctionCalling.definition`（已有 `JsonObject.toJsonSchema<T>()`，`tool/FunctionCalling.cj:48-59`） |
| 配置/PO | `@DataAssist[props fields]` + `@QueryMappersGenerator`，与既有 PO 一致 |
| JSON Schema 注解 | `@JsonStringSchema` / `@JsonArraySchema` 继续用于工具参数描述（`tool/FunctionCalling.cj`、`tool/*Function.cj` 已大量使用） |

补充：`TokenUsage` 增补两个映射（`model/po/TokenUsage.cj`）：

| 内部字段 | OpenAI 字段 | 说明 |
|---|---|---|
| `cached` | `prompt_tokens_details.cached_tokens` / `input_tokens_details.cached_tokens` | 已有；智谱在 `usage.prompt_tokens_details` |
| `reasoning` | `completion_tokens_details.reasoning_tokens` / `output_tokens_details.reasoning_tokens` | 新增，思考模型的成本大头在这 |

估算（供应商不给 usage 时）：`prompt ≈ Σ(消息字符数)/3.2`、`completion ≈ 输出字符数/3.2`，结果标注 `estimated` 并只进日志——本模块不做持久化，也就不存在污染成本表的可能。

---

## 11. 余额查询

### 11.1 统一接口

```cangjie
package fountain::f_llm.balance

@DataAssist[props fields]
public class BalanceSnapshot {
    private var provider: String = ''
    private var account: String = ''            // 账号标识（脱敏后的 AK/子账号/邮箱）
    private var currency: String = 'CNY'
    private var available: Float64 = 0.0f64     // 可用余额（能花的部分）
    private var cash: Float64 = 0.0f64          // 现金
    private var credit: Float64 = 0.0f64        // 信用额度 / 赠送
    private var frozen: Float64 = 0.0f64        // 冻结
    private var total: Float64 = 0.0f64         // 总额（口径各平台不同，见 11.2）
    private var low: Bool = false               // 低于阈值
    private var queriedAt: DateTime = DateTime.now()
    private var raw: JsonValue = JsonObject()   // 原始响应，便于排查
}

public interface BalanceQuerier {
    prop provider: String
    /** 一个 provider 对应一条 LLMConf（凭据放在 conf 里） */
    func query(conf: LLMConf): BalanceSnapshot
}

public class BalanceMediator {
    public static func register(provider: String, creator: (LLMConf) -> BalanceQuerier): Unit
    public static prop instance: BalanceMediator
    public func query(provider: String, conf: LLMConf): BalanceSnapshot
    /** 按当前所有启用的 conf 去重后逐个查询；单个失败不影响其它 */
    public func queryAll(): ArrayList<BalanceSnapshot>
}
```

失败语义（刻意设计）：

- 平台不支持 ⇒ `BalanceUnsupportedException`；
- 凭据缺失 ⇒ `BalanceCredentialException`（消息说明缺哪个键）；
- 接口异常 ⇒ `BalanceException`（带 status / 原始响应截断）；
- **绝不返回 0 余额**。0 会被下游当成"该充值了"，误告警比不告警更糟。

### 11.2 平台与分期（本期一律不实现）

本期只落接口。按"鉴权族"分，谁先做、要做什么，一目了然：

| 鉴权族 | 平台 | 实现要点 |
|---|---|---|
| Bearer | 智谱、硅基流动 | `Authorization` 头 + 一个 GET/简单 POST；端点在实现时按当时官方文档确定，写进 `conf['balanceUrl']` |
| AK/SK 签名 | 火山云、腾讯云、阿里云 | 各自的签名算法（HMAC-SHA256 V4 / TC3 / RPC HMAC-SHA1），HMAC 直接取 `stdx.crypto.digest` |

**CodeBuddy / Qoder 明确不做**（评审 A6）：没有公开接口，拿不到稳定凭据，与其写一个随时会坏的抓取实现，不如在接口层明确"不支持"——`BalanceMediator.query('codebuddy', ...)` 直接抛 `BalanceUnsupportedException`，调用方一眼知道原因。

**不预先在文档里固化端点与字段版本**，理由有两条：

1. 三家云厂商的计费 API 版本会变，写死的版本号过半年就是错的，读者会以为已经支持；
2. 余额接口不属于"契约稳定"的公开能力，文档写得越具体，越像是在承诺。

实现顺序（M4，可选、可砍）：

1. Bearer 族（智谱 / 硅基流动）先跑通，验证接口形状与 `BalanceSnapshot` 字段是否够用；
2. 腾讯云 TC3——结构最规整，适合做签名基线的第一个实现；
3. 火山云 V4、阿里云 RPC。

签名实现说明：`stdx.crypto.digest.HMAC` 可直接用（`f_jwt/src/HMACDigest.cj:18-24` 是现成封装），阿里云的 SHA1 用 `HashType.SHA1`。**不引入 `f_crypto` 依赖**。

`total` 的口径差异必须在实现时写进注释，不能装成统一：阿里云 `AvailableAmount` 已含信用额度，腾讯云 `Balance` 与 `RealBalance` 不同，火山云 `AvailableBalance` 已扣冻结。拿不准的字段宁可留 `0` 并在 `raw` 里保留原始响应，也不要"猜一个数"。

### 11.3 扩展方式

两条路，任选：

```cangjie
// 路 1：注册表（显式，适合不带 f_bean 的项目）
BalanceMediator.instance.register('mycloud'){conf => MyCloudBalanceQuerier(conf)}

// 路 2：@Bean（自动发现，适合 fountain 应用）
@Bean
public class MyCloudBalanceQuerier <: BalanceQuerier {
    public prop provider: String { get(){ 'mycloud' } }
    public func query(conf: LLMConf): BalanceSnapshot
}
```

同名 `provider` 注册两次 ⇒ 启动失败（与 7.6 一致）。

### 11.4 缓存与告警

| 项 | 默认 | 配置键 |
|---|---|---|
| 结果缓存 | 300s（同一 conf.id） | `llm_balanceCacheSeconds` |
| 低余额阈值 | 100（CNY） | `llm_balanceLowThreshold` |
| 查询超时 | 10s | `llm_balanceTimeoutMs` |

低余额只打一条 `warn` 日志并置 `BalanceSnapshot.low=true`，**不主动发消息**——通知属于应用层（避免框架偷偷接 SMTP，也避开凭据治理问题）。

---

## 12. 模块结构

### 12.1 包与文件

```
f_llm/src/
├── llm/
│   ├── (保留) ChatMessage.cj LLMParams.cj LLMResp.cj TokenizerParams.cj advanced_params.cj
│   ├── (保留) ContextPruner.cj ContextPrunerMediator.cj ContextPrunerName.cj
│   ├── (改造) AbstractLLMContext.cj       改持 LLMConf；新增 accessStream
│   ├── (改造) LLMContextMediator.cj       中介者：快照 / 刷新 / LoadBalance / 熔断
│   ├── (删除) GLMContext.cj               由 provider='zhipu' 的 OpenAIContext 取代
│   ├── LLMConfsSnapshot.cj                不可变快照（含 byName 与 balancers）   [新]
│   ├── CircuitBreaker.cj                  失败计数与临时下线（仅内存）           [新]
│   ├── LLM.cj                             门面（4 个入口）                       [新]
│   ├── LLMRequest.cj / LLMResponse.cj / LLMDelta.cj                            [新]
│   ├── protocol/
│   │   ├── ChatCompletionsMapper.cj       内部模型 ↔ chat 报文                 [新]
│   │   └── ResponsesMapper.cj             内部模型 ↔ responses 报文            [新]
│   ├── openai/
│   │   ├── OpenAIContext.cj               唯一的平台实现                       [新]
│   │   └── ProviderDialect.cj / DialectRegistry.cj                             [新]
│   ├── ModelCapabilities.cj               ThinkingCapability 解析（模型属性）  [新]
│   └── stream/
│       └── StreamAccumulator.cj           chat / responses 两套归并            [新]
│                                          （SSE 解析在 f_httpclient，不在这里）
├── tool/
│   ├── (保留) 全部现有文件
│   ├── (改造) FunctionMediator.cj         + register / registerMcp
│   ├── CurrentTimeFunction.cj                                                  [新]
│   ├── WebSearchFunction.cj               内置搜索（借任一启用 conf 的凭据）   [新]
│   └── WebFetchFunction.cj                内置抓取（含 SSRF 校验）             [新]
├── search/
│   ├── (删除) AbstractSearcher.cj / SearchMediartor.cj / GLMSearcher.cj
│   ├── SearchProvider.cj                  能力接口 + 注册表（可扩展）          [新]
│   ├── SearchResultItem.cj                统一结果结构                         [新]
│   ├── ZhipuSearchProvider.cj                                                 [新]
│   └── DeepSeekSearchProvider.cj          search + fetch                       [新]
├── mcp/
│   └── McpServerConf.cj / McpToolSource.cj / McpToolSchema.cj                  [新]
├── balance/
│   ├── BalanceSnapshot.cj / BalanceQuerier.cj / BalanceMediator.cj             [新]
│   └── (平台实现) M4 才落，本期只有接口
├── config/  (改造) LLMConfig.cj           新增 14 个配置键（见 12.3）
├── model/
│   ├── po/ (改造) LLMConf.cj / TokenUsage.cj
│   └── LLMConfCodec.cj                    conf 列 ↔ HashMap（f_data）          [新]
└── util/
    ├── (改造) http.cj                     保留旧函数；新增流式构造
    ├── Redactor.cj                        前 4 + **** + 后 4                     [新]
    └── TokenCounter.cj                                                           [新]
```

`conf` 列的读方向用 f_orm 现成的 `QueryMapperJsonConverter`（3.4），不需要自写 converter；写入由 `LLMConfCodec.toColumn` 显式转字符串。

**配套改动：`f_httpclient`（本期的前置依赖）**

```
f_httpclient/src/
├── (改造) ExtendHttpResponse.cj   + extend HttpResponse { func sseReader(...): SseReader }
├── (新增) sse/SseEvent.cj         SseEvent（event / data / id / retry）
├── (新增) sse/SseReader.cj        SseReader <: Resource（next() / close()）
└── (新增) sse/SseException.cj     SseTimeoutException / SseLineTooLongException
```

不新增第三方依赖：只用 `std.io` 的 `InputStream` 与现有 `readToEnd` 同款的字节缓冲循环。`f_httpclient` 的 README 需要补一节"SSE 客户端"，写清 5.3.1 那 10 条实现要求。

### 12.2 `cjpm.toml`

```toml
[dependencies]
  "fountain::f_mcp"        = {path = "../f_mcp"}         # MCP 工具来源
  "fountain::f_concurrent" = {path = "../f_concurrent"}  # LoadBalance 权重调度
```

不做其他依赖调整：`f_log` / `f_data` / `f_orm` / `f_httpclient` / `f_config` 均已在列。

### 12.3 新增配置项

沿用 `LLMConfig` 的"环境变量 + `Config.getValue<T>`"风格（`f_llm/src/config/LLMConfig.cj:23-73`）：

| 常量 | 键 | 默认 | 说明 |
|---|---|---|---|
| `LLM_CONF_REFRESH_SECONDS` | `llm_confRefreshSeconds` | `60` | 配置刷新周期（懒式 TTL） |
| `LLM_LOAD_BALANCE_ALGO` | `llm_loadBalanceAlgo` | `randomWeight` | `randomWeight` / `roundRobin` |
| `LLM_FAILURE_THRESHOLD` | `llm_failureThreshold` | `5` | 连续可重试失败多少次触发临时下线 |
| `LLM_COOLDOWN_SECONDS` | `llm_cooldownSeconds` | `60` | 临时下线时长 |
| `LLM_STREAM_IDLE_TIMEOUT` | `llm_streamIdleTimeout` | `120`（秒） | 流式无数据超时 |
| `LLM_STREAM_MAX_LINE` | `llm_streamMaxLineBytes` | `1048576` | SSE 单行上限 |
| `LLM_LOG_BODY_LIMIT` | `llm_logBodyLimit` | `4096` | 请求/响应体日志截断字节数 |
| `LLM_MCP_ENABLED` | `llm_mcpEnabled` | `false` | MCP 工具总开关 |
| `LLM_TOOL_RESULT_LIMIT` | `llm_toolResultMaxBytes` | `65536` | 单次工具结果进上下文的上限 |
| `LLM_FETCH_MAX_BYTES` | `llm_fetchMaxBytes` | `262144` | `webFetch` 单页正文上限（256 KiB） |
| `LLM_SEARCH_TIMEOUT` | `llm_searchTimeoutMs` | `15000` | 搜索 / 抓取超时 |
| `LLM_BALANCE_CACHE_SECONDS` | `llm_balanceCacheSeconds` | `300` | 余额缓存（M4） |
| `LLM_BALANCE_LOW_THRESHOLD` | `llm_balanceLowThreshold` | `100` | 低余额告警阈值（M4） |
| `LLM_BALANCE_TIMEOUT` | `llm_balanceTimeoutMs` | `10000` | 余额查询超时（M4） |

已有 `llm_accessTryingCount` / `llm_accessTryingElapsed`（`LLMConfig.cj:28-29`）继续用于单次调用的重试上限；`llm_failureThreshold` 管的是**跨请求**的连续失败，两者别混：前者是"这一请求再试几次"，后者是"这个平台暂时别用了"。

---

## 13. 里程碑

| 阶段 | 交付 | 验收 |
|---|---|---|
| **M0** 前置验证（1~2 天） | ①`LLMConf` 新形态可编译 ②`toJson(HashMap)` / `fromJson<HashMap>` 双向往返 ③一条记录 `读 → 改 conf → 写 → 再读` | 三个最小用例跑通，`conf` 落库是合法 JSON 且内容一致 |
| **M1** 装载/调度 + 协议层（非流式） | `LLMConfsSnapshot` + 懒式刷新 + `LoadBalance` 权重 + 熔断 + `OpenAIContext` + `ProviderDialect`（zhipu/deepseek/ark/dashscope/openai）+ `LLM.chat/respond` | ①新增一家平台只改配置 ②停掉一家平台后请求自动切另一家 ③连续失败达阈值后该 conf 被跳过、冷却到期自动恢复 ④刷新周期内只查一次库（用计数桩断言） |
| **M2** 流式 + 工具 + MCP | **前置：`f_httpclient` 的 `sseReader()` 已发布**；`StreamAccumulator` + `chatStream/respondStream` + 三个内置函数（`currentTime` / `webSearch` / `webFetch`）+ `McpToolSource` + `ModelCapabilities` | ①流式与非流式结果字段一致（同输入比对）②工具多轮（≥3 轮）③`webSearch` 在两个 provider 各跑通一次 ④`webFetch` 对公网 URL 成功、对内网 URL 拒绝 ⑤MCP stdio/http 各接一台真实 server ⑥`f_llm` 内不出现 `text/event-stream` 的行解析代码 |
| **M3** 观测 + TokenCounter | `TokenCounter`（远端/启发式）+ `Redactor` + 每次调用记 `TokenUsage` | ①日志默认 `info` 就有完整用量 ②日志中无明文 KEY（正则扫日志断言）③启发式计数与真实 usage 偏差 < 30% |
| **M4** 余额（可选） | `BalanceQuerier` 接口已定，按 11.2 顺序落平台实现；CodeBuddy / Qoder 不实现 | ①不支持的平台抛明确异常 ②至少 Bearer 族一家联调通过 |

全阶段硬性验收（每个里程碑都查）：**源码里不得出现 `@GetMapping` / `@PostMapping` / `@Controller` 等路由注解，也不得 `import fountain::f_mvc.*`**；`cjpm.toml` 不新增 `f_mvc` / `f_http` 依赖（`f_mvc` 只会作为 `f_mcp` 的传递依赖出现）。这条比"功能跑通"更重要——一旦本模块开始注册路由，"库"就变成了"服务"，其他项目就没法只取它的调用能力。

---

## 14. 测试策略

| 层 | 手段 |
|---|---|
| 报文映射 | 表驱动单测：内部模型 → 期望 JSON（`m1/*.json` fixture），逐字段断言 |
| `conf` 编解码 | `toColumn` / `fromColumn` 往返：空表、含中文、含引号、超长值、非法 JSON（应回退空表） |
| 装载与刷新 | 假 `LLMFinder` 计数桩：周期内多次 `access` 只查一次库；刷新后新配置生效；刷新抛异常时旧快照仍可用 |
| 权重调度 | 固定种子/固定序列下断言分配比例（`weight 3:1` 大致 3:1）；`roundRobin` 严格交替；`weight<=0` 被丢弃 |
| 熔断 | 连续 5 次可重试失败后该 conf 被跳过；冷却到期恢复；4xx 不计入失败；进程内不改持久化配置 |
| SSE 解析 | **在 `f_httpclient` 测**：fixture 文本回放——正常流、`\r\n`、心跳注释、超长行、半行断开、无尾空行、`close()` 关流 |
| SSE 消费 | `f_llm` 侧用假 `SseReader`（喂事件序列）测：`[DONE]` 终止、`usage` 只在末块、空 `data` 跳过、`idleTimeout` 冒泡成 `LLMException` |
| 增量归并 | 用真实抓的 chunk 序列（脱敏）断言：文本拼接、`tool_calls` 分片、`usage` 只在末块、`reasoning` 两家字段名 |
| 工具 | 内置函数用固定时钟/假搜索客户端；`FunctionMediator` 冲突用重复注册断言抛异常；`webSearch` 无可用 conf 时**断言抛 `SearchUnavailableException`** |
| `webFetch` 安全 | 用假 DNS/假 HTTP：内网地址（`127.0.0.1` / `10.x` / `169.254.169.254` / `::1`）必须拒绝；`file://` 拒绝；跳转到内网拒绝；超 256 KiB 截断 |
| 搜索扩展性 | 注册一个假 `SearchProvider`（第三个平台），断言 `webSearch` 自动可用、同名重复注册抛异常 |
| 模型能力 | `ThinkingCapability` 解析：`conf['thinking']` 覆盖 > 内置表 > 默认 `Toggle`；`Always` 模型丢弃 `temperature`；`None` + `alwaysThinking=true` 记 `warn` 且不写字段 |
| MCP | 用 `fmcpdemo` 的真实 server 做集成；schema 清洗用 6 个畸形 `inputSchema` 样本；工具名超 64 字符断言启动失败 |
| 余额（M4） | 签名用官方示例向量做纯函数断言；接口层用录制响应回放 |
| 回归 | 现有 `ContextPruner` 全部单测不改一行，必须全绿 |
| 端到端 | `fdemo` 加一个"两家平台轮流挂掉"的场景，验证业务无感且熔断不误伤 |

不打真实网络：所有网络层测试走"回放"（fixture + 假 `HttpClient` 行为），真实联调单独放在 `m3/live/` 手工执行并记录。

---

## 15. 风险与待确认

| # | 风险 | 影响 | 处置 |
|---|---|---|---|
| R1 | `conf` 的 JSON 文本受数据库/驱动影响（`\u` 转义、空串 vs `NULL`、字符集） | 读回解析失败或值被改写 | codec 统一 `trim` + 空判断；M0 用真实库跑一条往返；失败只丢该条的非关键配置，不阻断启动 |
| R2 | `f_httpclient` 的 SSE 客户端与 `f_llm` 的 M2 **串行依赖**：它不发布，流式就开不了工 | M2 被阻塞 | M2 明确列为前置；`f_httpclient` 侧先按 5.3.1 的 10 条要求交付并自带单测，`f_llm` 只做消费 |
| R2b | `SseReader` 边界行为（超长行、半行断开、`close()` 时机）由两个模块共同决定 | 排障时互相甩锅 | 错误类型定义在 `f_httpclient`（`SseTimeoutException` / `SseLineTooLongException`），`f_llm` 只做包装与 `requestId` 标注 |
| R3 | 各平台 `thinking` / `usage` / `tools` 取值不一致，**且包括智谱在内都还没系统联调**（智谱只有搜索端点由现有代码跑通过） | 400 或 usage 缺失 | `ProviderDialect` 表驱动 + 每家 fixture；按"一家一张联调清单"逐家过（M1/M2 验收），附录 B 在联调前一律视为**未确认** |
| R4 | DeepSeek 搜索按次计费（5 元/1000 次成功请求） | 费用随调用量上升 | 工具描述明确"仅在需要外部事实时调用"；日志记每次搜索的平台与条数 |
| R5 | 懒式刷新的第一个请求承担一次 DB 查询 | 长尾延迟 | 周期调大可摊薄；应用启动后主动调一次 `refreshNow()` |
| R6 | 刷新与熔断的竞态：快照已被替换，熔断表里残留已删除的 `conf.id` | 内存缓慢增长、误判 | 每次刷新后按新快照清理熔断表；单测断言"删掉的 conf 不再出现在表里" |
| R7 | `LoadBalance` 的权重空间必须覆盖累计键（`Int64Weight(0, total)`） | 权重比例失真 | 先算 `total` 再建 algo；用 3:1 分布单测固定住 |
| R8 | 破坏性变更同时改 `fcoder`（`LLMService` / `LLMDAO` / `KnowledgeServiceImpl`） | 编译面失败 | 6.5 已列全改动点；一次性提交，不留兼容壳 |
| R9 | 明文 KEY 进日志/异常 | 凭据泄露 | `Redactor` 前 4 + `****` + 后 4；单测用正则扫日志 |
| R10 | `f_mcp` 传递带入 `f_mvc` | 职责漂移：有人顺手加 Controller | 13 章硬性验收 + 不建 `controller/` / `router/` 目录 |
| R11 | 库被宿主线程模型绑架（回调里做阻塞 IO、或要求模块自己起线程） | 流式实现变形 | 2.4 三条约束写进 README；回调里只允许"转发/落盘/推送" |
| R12 | DeepSeek `/v1/tools/*` 非 OpenAI 标准端点，网关可能拦截 | 搜索 / 抓取不可用 | 端点可由 `conf['searchUrl']` / `conf['fetchUrl']` 覆盖；失败按 7.4 抛 `SearchUnavailableException` |
| R13 | `webFetch` 让模型指定 URL，等于把内网探测能力交给模型 | SSRF / 读云元数据 | 7.4.1 的 6 条防护（协议白名单、解析后 IP 校验、禁跳转到内网、字节上限）；单测覆盖内网地址族 |
| R14 | 搜索能力注册表是开放的，第三方实现可能不守"不静默回退"约定 | 搜索结果来源不可追溯 | `SearchProvider` 接口注释写死约定；`provider` 显式指定时框架层不再兜底 |

**评审已确认的决策（不再讨论）**：

| 编号 | 决策 |
|---|---|
| R1 | `conf` 用 `f_data` 的 API 把 Map 转 JSON 字符串保存；传 SQL 参数前先转（3.4） |
| R2 | SSE 客户端由 `f_httpclient` 提供（`sseReader()` + `SseReader`），`f_llm` 只消费（5.3） |
| R3 | 所有平台按 OpenAI 兼容处理，取值差异用 `ProviderDialect` 驱动（5.7） |
| R4 | DeepSeek 搜索 `POST /v1/tools/search`、抓取 `POST /v1/tools/fetch` 已核实并写进契约（7.4） |
| R5 | 智谱 / 硅基流动的余额**先不实现**（11.2） |
| R6 | 所有平台的余额查询留到最后（M4，可选） |
| R7 | **不必考虑兼容期**，允许破坏性变更（6.5） |
| R8 | 日志默认开 `info`（10.1） |
| R9 | 鉴权 KEY、余额签名 KEY 一律脱敏：前 4 + `****` + 后 4（3.6 / 10.1） |
| R10 | `info` 记每次访问的 `TokenUsage`，不持久化（10.1） |
| 15.1 | `temperature` 默认 `-1.0`，表示用平台默认值，报文不传该参数（3.2） |
| 15.2 | 传 SQL 参数时先把 Map 转成 JSON 字符串（3.4） |
| 15.3 | 自动工具循环默认关闭，显式开启（7.5） |
| 15.4 | 搜索实现为 tool_call，凭据从任意启用的 `LLMConf` 取（7.4） |
| v0.3 | SSE 客户端由 `f_httpclient` 提供（`HttpResponse.sseReader()` + `SseReader`），`f_llm` 只消费增量（5.3） |
| A6 | CodeBuddy / Qoder 的余额**不做**（11.2） |
| A7 | `webFetch` **要实现**，带 SSRF 防护（7.4.1） |
| A 系列 | 各平台方言（**含智谱**）先联调再说，联调前附录 B 一律按"未确认"处理 |
| 模型能力 | 思考由**模型**决定而非平台：`ThinkingCapability` + 三级解析（5.8） |
| B3 | `weight <= 0` 等同停用，装载 SQL 为 `WHERE enabled = true AND weight > 0`（3.3） |
| B4 | `tokenThreshold` **每平台各算各的**，不跨平台取最小（4.5） |
| B8 | MCP 工具名**不截断**，超限直接失败（7.6） |
| B9 | 搜索 / 抓取无可用配置时**抛异常**，不返回假文本（7.4） |
| B10 | 搜索平台**可注册扩展**（`@Bean` 即接入），不写死集合（7.4） |
| B1/B2/B5/B6/B7 | 采用文档默认：熔断只计可重试错误、5 次 / 60s、`response.completed` 为准、刷新后清理熔断表、`LLM` 不做自动裁剪 |

---

## 附录 A `conf` 键速查

见 3.5。新增键必须同时更新该表与 `LLMConf` 的类注释，否则下一个接入的人只能读代码猜。

## 附录 B 方言矩阵（**全部未联调**，以实测为准）

评审确认：**包括智谱在内，A 系列方言问题都要先联调**。下表的"取值"是**待验证的假设**，不是结论；联调前不得据此写死代码，只能作为 fixture 的初始草稿。

| provider | chat 路径 | responses 路径 | 思考字段形态 | tools 形态 | usage 差异 | 联调状态 |
|---|---|---|---|---|---|---|
| zhipu | `/chat/completions` | 无 | `thinking:{type,clear_thinking}`（是否支持取决于模型，见 5.8） | 标准 | `prompt_tokens_details.cached_tokens` | 未联调 |
| deepseek | `/chat/completions` | 无 | 无该字段（模型自带时不能开关） | 标准 | `prompt_cache_hit_tokens`（假设值） | 未联调 |
| ark | `/chat/completions` | 未知（可能无） | `thinking:{type}` | 标准 | 标准 | 未联调 |
| dashscope | `/compatible-mode/v1/chat/completions` | 无 | `enable_thinking` | 标准 | 标准 | 未联调 |
| siliconflow | `/v1/chat/completions` | 无 | 依模型 | 标准 | 标准 | 未联调 |
| openai | `/chat/completions` | `/responses` | `reasoning:{effort,summary}` | 标准 | `*_tokens_details` | 未联调 |

**联调清单**（每平台一条，逐项打勾才能把该行状态改成"已确认"）：

1. 非流式：普通对话 + `tool_calls` 各一次，`usage` 字段名与层级；
2. 流式：`[DONE]` 是否出现、`usage` 落在哪一块、`reasoning` 字段叫什么；
3. 思考：`capability=Toggle` 时"开/关"各一次，确认关掉后确实不返回推理内容；
4. `temperature`：设 `0.3` 与 `-1`（不传）各一次，确认被接受/被忽略；
5. 错误：一个 4xx（错误模型名）与一个 429/5xx（如果有办法构造），确认错误体结构。

工具类端点（与 chat 无关，独立于上表）：

| 平台 | 搜索 | 抓取 | 联调状态 |
|---|---|---|---|
| zhipu | `POST {base}/web_search`（`search_query` / `search_engine` / `count`）——现有代码跑通过 | 无 | 搜索：现有实现可用；字段仍需按上方清单复核 |
| deepseek | `POST https://api.deepseek.com/v1/tools/search`（`query` / `count` / `need_content`） | `POST https://api.deepseek.com/v1/tools/fetch`（`{url}`） | 未联调（契约来自官方文档） |

## 附录 C 对外 API 一览

```cangjie
// 门面
LLM.chat(req: LLMRequest): LLMResponse
LLM.chatStream(req: LLMRequest, onDelta: (LLMDelta) -> Unit): LLMResponse
LLM.respond(req: LLMRequest): LLMResponse
LLM.respondStream(req: LLMRequest, onEvent: (ResponsesEvent) -> Unit): LLMResponse

// 中介者（编排层用）
LLMContextMediator.instance.access(agentId, session, llmName, params): LLMResp
LLMContextMediator.instance.accessStream(agentId, session, llmName, params, onDelta): LLMResp
LLMContextMediator.instance.candidates(): ArrayList<LLMConf>
LLMContextMediator.instance.candidates(llmName): ArrayList<LLMConf>
LLMContextMediator.instance.isCircuitOpen(confId): Bool
LLMContextMediator.instance.peekNext(llmName): ?LLMConf
LLMContextMediator.instance.getTokenThreshold(conf): Int64
LLMContextMediator.instance.tokenize(conf, messages): Int64
LLMContextMediator.instance.saturated(conf, messages): Bool
LLMContextMediator.instance.refreshNow(): Unit

// 上下文
ContextPrunerMediator.instance.prune(name, agentId:, session:, messages:): ArrayList<ChatMessage>

// 模型能力
ModelCapabilities.thinking(conf: LLMConf): ThinkingCapability
ModelCapabilities.supportsTemperature(actualLlmName: String): Bool

// 工具
FunctionMediator.register(calling: CommonFunctionCalling): Unit
FunctionMediator.registerMcp(alias: String, client: McpClient): Unit
FunctionMediator.getDefinitions(names): Iterator<FunctionCall>
FunctionMediator.call(name, args: JsonObject): FunctionResult
// 内置工具：currentTime、webSearch、webFetch（无需注册，随工具表自动加载）

// 搜索 / 抓取：能力由 provider 声明，可注册扩展
SearchProviderRegistry.instance.register(provider: SearchProvider)
SearchProviderRegistry.instance.get(provider): ?SearchProvider
SearchProvider.search(conf, query, count, needContent): ArrayList<SearchResultItem>
SearchProvider.fetch(conf, url): FetchedPage

// MCP
McpToolSource(conf).load() / tools() / call(name, args) / close()

// 配置编码
LLMConfCodec.toColumn(conf: HashMap<String, String>): String
LLMConfCodec.fromColumn(text: String): HashMap<String, String>

// 依赖的 f_httpclient 能力（不在本模块）
HttpResponse.sseReader(maxLineBytes!, idleTimeout!): SseReader
SseReader.next(): ?SseEvent
SseReader.close(): Unit

// 余额（M4，接口先定）
BalanceMediator.instance.register(provider, creator)
BalanceMediator.instance.query(provider, conf): BalanceSnapshot
BalanceMediator.instance.queryAll(): ArrayList<BalanceSnapshot>
```
