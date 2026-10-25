# f_jsonrpc —— 仓颉 JSON-RPC 2.0 over HTTP 模块设计

> **以实现为准**：本文档描述设计意图，任何与源码不一致的地方以 `f_jsonrpc/src` 为准。
> 关键差异见文末「文档与实现对照」，最近一次对齐：`fix-jsonrpc-mcp-review-findings`。
>
> 版本 **v0.6** ｜ 2026-10-24 ｜ 状态：待评审
>
> 定位：fountain 模块。在 `f_mvc` 之上提供 **JSON-RPC 2.0 over HTTP** 的服务端与客户端能力，
> 数据编解码交给 `f_data`。**一个 JSON-RPC 端点包装为一个 `fountain::f_mvc.RequestMeta` 实例。**
>
> 上游消费者：`f_mcp`（MCP 的消息层就是 JSON-RPC 2.0）。
>
> v0.1 → v0.2：定位收敛为「只补 f_mvc 没有的三样」——JSON-RPC 消息模型、方法表、错误码。
>
> v0.2 → v0.3：
> - **接入方式定为 `@Controller` 注解路线，f_mvc 零改动**（v0.4 起入口注解为 `@JsonRpcMapping`）
> - 撤回 v0.2 提出的「程序化构造 RequestMeta + 公开化改造」：`consumes` 是路由表的键、
>   `produces` 是内容协商依据，两者只能由注解填充，程序化会让 f_mvc 要改 3~4 处（详见 2.2）
> - 新增一条易踩的坑：`consumes` 为空 → **415**（不是 406），因为路由表压根没有这个条目
> - 明确硬约束「f_mvc 零改动」，并给出参考 WSMeta 的分工分析（2.4）：不新增 `JsonRPCMeta`、不新增 `@JsonRPC` 宏
> - 可选 `@JsonRpcMapping`：利用 `RequestMeta.generate` 按 `RequestMapping` 基类匹配的特性收敛默认值
>
> v0.3 → v0.4：**确定采用 `@JsonRpcMapping` 作为标准入口**（2.4），
> `method` / `consumes` / `produces` 三项硬编码不暴露，避免被改坏导致 415/406。
>
> v0.4 → v0.5：**`f_data.json.JsonSchema` 新增 `validate`**（4.7），参数校验从两条路变三条路；
> 明确实例 / 文档两个重载的分工、关键字支持矩阵与 fail-closed 策略；新增前置任务 P-1.5。
>
> v0.5 → v0.6：`validate` 的正则改用 **`f_regex`** 的 `String.regex(solid:)`，
> 并写清 `solid` 按"编译期常量 / 运行期动态"分流的规则（4.7.4）。

> **硬约束：`f_mvc` 零改动。**
>
> 本模块不得以任何形式修改 `f_mvc`：不新增公开 API、不修改现有行为、不依赖未公开成员。
> 若某个设计需要动 `f_mvc`，则该设计作废，改用现有能力实现。
>
> 理由不是洁癖，是依赖方向：`f_mvc` 是框架层，`f_jsonrpc` / `f_mcp` 是协议层。
> 协议层反向要求框架层开口子，会让每个上层协议都在框架里留一道缝，
> 最终框架变成一堆协议特例的集合。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 协议 | JSON-RPC 2.0，UTF-8，支持单请求 / 批量 / 通知 |
| 服务端接入点 | `@Controller` + **`@JsonRpcMapping`**（本模块自定义的 `RequestMapping` 子类），宏展开注册，**f_mvc 零改动** |
| 一个端点 = 一个 RequestMeta | JSON-RPC 的 `method` **不映射到路由**，只在请求体内分发（理由见 3.2） |
| 多租户 | `/rpc/{topic}`，`topic` 作为**方法命名空间过滤**，不做前缀补全（见 3.3） |
| 路由注册 | `MVCStarter.generateAndRegister`（`@Controller` 宏自动生成调用） |
| 客户端 | 基于 `stdx.net.http` 的同步 / 异步调用，支持批量与通知 |
| 数据层 | `f_data`：`JsonValue.fromBytes` / `toString()` / `toJson` / `fromJson` |
| 参数校验 | 三条路：弱类型手工 / 强类型 `fromJson<T>` / **`JsonSchema.validate`**（`f_data` 新增，见 4.7） |
| 依赖 | `fountain::f_mvc`、`fountain::f_data`、`stdx.net.http` |
| **硬约束** | **`f_mvc` 零改动**（见页首） |
| 首版不做 | SSE 流式、WebSocket 传输、JSON-RPC over 其他传输 |

---

## 1. 定位与依赖

### 1.1 在模块链里的位置

```
                    f_mcp
                      │ 复用消息层
                      ▼
                  f_jsonrpc          ← 本文档
                 ╱          ╲
          f_mvc              f_data
      （路由/HTTP/鉴权）    （JSON 编解码）
```

**它只补 `f_mvc` 没有的三样东西**：JSON-RPC 消息模型、方法表、错误码。
路由、鉴权、线程池、日志、异常兜底、连接管理全部由 `f_mvc` 提供——f_jsonrpc 一行都不重写。

`f_jsonrpc` **不实现 HTTP 服务器**，也不实现 JSON 解析。它只做三件事：

1. 把 JSON-RPC 的请求/响应映射成 `f_mvc` 能处理的东西
2. 维护「方法名 → 处理函数」的运行期方法表
3. 把 JSON-RPC 的错误模型落到 HTTP 状态码与错误对象上

### 1.2 依赖与版本

```toml
[dependencies]
  "fountain::f_mvc"  = {path = "../f_mvc"}
  "fountain::f_data" = {path = "../f_data"}
```

| 模块 | 用到什么 | 依据 |
|---|---|---|
| `fountain::f_mvc` | `@Controller` 宏、`RequestMapping` 基类、`MVCStarter.generateAndRegister`、`RequestMeta`、`HttpContext` | `f_mvc/src/macros/Controller.cj`、`f_mvc/src/MVCStarter.cj` |
| `fountain::f_data.json` | `JsonValue` / `JsonObject` / `JsonArray` / `toJson` / `fromJson` | `f_data/src/json/JsonConverter.cj` |
| `stdx.net.http` | 客户端 `ClientBuilder` / `Client` / `HttpRequestBuilder` | 仅客户端路径 |

`f_mvc` 与 `f_data` 的包名分别是 `fountain::f_mvc`、`fountain::f_data`（子包 `fountain::f_data.json`）。

---

## 2. 接入 f_mvc 的方式

### 2.1 没有 `@RequestMapping` 这个注解

`f_mvc/src/RequestMapping.cj` 里 `RequestMapping` 是**抽象基类**，不能标注方法。真正能用的是它的五个子类：

| 注解 | `method` | `produces` 默认 | `consumes` 默认 |
|---|---|---|---|
| `@PostMapping` | `POST` | `application/json` | `application/json` |
| `@GetMapping` | `GET` | `application/json` | `''` |
| `@PutMapping` | `PUT` | `application/json` | `application/json` |
| `@DeleteMapping` | `DELETE` | `application/json` | `''` |
| `@PatchMapping` | `PATCH` | `application/json` | `application/json` |

本文档最终采用自定义的 `@JsonRpcMapping`（2.4）——它是 `RequestMapping` 的第六个子类，
默认值与 `@PostMapping` 完全一致，只是把 `method` / `consumes` / `produces` 三项固定下来。

**路径支持两件容易忽略的事**（`f_mvc/README.md`、`RequestMeta.cj:546`）：

- `{}` 路径变量：`/rpc/{topic}`
- `|` 分隔多条路径：`path: '/rpc|/rpc/{topic}'` → **生成两个 `RequestMeta` 实例**，不是一条

### 2.2 为什么用注解，而不是程序化构造 RequestMeta

**结论：走 `@Controller` + 自定义 `@JsonRpcMapping`（2.4），f_mvc 一行都不用改。**

程序化构造不是"做不到"，而是构造出来的 `RequestMeta` 会缺两个字段，
而这两个字段是 f_mvc 分发的**索引键**。空着不是"少做一次协商"，是**请求根本打不通**。

#### ① `consumes` 是路由表的键，空着就是 415

`MultiRequestMethodHandler.register`（`MultiRequestMethodHandler.cj:41-58`）：

```cangjie
let map = metas.computeIfAbsent(meta.method){HashMap<String, RequestMeta>()}
meta.iterateConsumes {
    c => map.addIfAbsent(c, meta)
}
```

`consumes` 为空 → 这个循环一次都不执行 → 路径 compile 了，但方法表里没有这个条目。
分发时：

```cangjie
if (let Some(m) <- metas.get(c) && let h <- check(m)) { ... }
else if (let Some(m) <- metas.get('*')) { ... }
else { UNSUPPORTED_MEDIA_TYPE }
```

查不到任何东西 → **415**。

> 这条的实践含义：客户端必须带 `Content-Type: application/json`。
> JSON-RPC 客户端本来就会带，但**用裸 curl 调试时很容易漏**，然后误判成"服务没起来"。

#### ② `produces` 是 `checkProduces` 的判断依据，空着就是 406

`MultiRequestMethodHandler.handle:66` 每次分发先调：

```cangjie
if (!meta.checkProduces(ctx)) { NOT_ACCEPTABLE }
```

`checkProduces` 只在三种情况返回真：没有 `Accept` 头、`Accept` 是 `*` 或 `*/*`、
或 `produces` 里包含该值。空 `produces` + `Accept: application/json` → **406**。

#### ③ 这两个字段只能由注解填

`consumes` / `produces` 都是 `private let`，唯一的写入路径是 `RequestMeta.generate()`
读 `@XxxMapping[...]` 的参数。要程序化填，就得给 f_mvc 加 setter。

#### ④ 还要顺带解决 `setHandle` 的 bean 依赖

`setHandle<T>` 已经是 public，但第一步就查 `BeanFactory.instance.iterator<T>().next()`，
为空即 `UnreachableException`——**`T` 必须是 f_bean 里注册过的类型**，且调用时 `pattern` 已赋值。
`@Controller` 宏展开时这两件事都已就绪；程序化则要自己造 holder bean、自己保证注册顺序。

#### 成本对比

| 路线 | **注册这一步**要改什么 | 仍然绕不开的 |
|---|---|---|
| **注解（采用）** | **0** | 无（宏把 `consumes` / `produces` / `setHandle` / `registered` 全办了） |
| 程序化 | `RequestMetas.add` 公开 1 处，并在 `initialize()` 里统一 drain | `consumes` / `produces` 要 setter（`private let`）、`setHandle` 要 bean 或重载 |

也就是说：**程序化注册本身只差一个 public，但它解决不了另外两个字段的问题**——
那两个与"怎么注册"无关，只与"字段谁能写"有关。

JSON-RPC 的端点路径本来就是固定的（`/rpc`、`/mcp`），不存在"运行期动态加端点"的需求。
为一个用不上的灵活性去改框架，不划算。

> **如果将来真需要程序化注册，正确的位置不是 `add`，而是 `MVCStarter.initialize()`。**
> `RequestMetas` 只是登记簿；让 `initialize()` 在启动前统一取用它、灌进 distributor，
> 才能满足「所有 `RequestMeta` 在 `initialize` 之后才生效」这个时序。
> 在 `add` 里顺手挂载，会把「登记」和「生效」耦合成一步，也绕开了 `initialize` 这个统一入口。
>
> 按那种设计，公开面只需要 `RequestMetas.add`（外加包内一个 `all()` 供 `MVCStarter` 读取）。
> 但 `consumes`/`produces` 与 `setHandle` 两处仍然免不了——因为前者是 `private let`、
> 后者依赖 bean，与注册方式无关。

具体到这个方案，`MVCStarter.initialize()` 里只需要加一段：

```cangjie
public static func initialize(): Unit {
    if (!initial_.compareAndSwap(false, true)) { throw MVCException('mvc has been started') }
    if (!registered.load()) {
        let metas = RequestMetas.instance.all()            // 包内可见即可
        if (metas.isEmpty()) { return }
        HttpRequestDistributorImpl.instance.register(metas)  // 包内可见即可
        registered.store(true)                               // 同类内部，本来就可达
    }
    ...  // 后面照旧
}
```

注意三个"不需要"：`registered` 不用改可见性（就在 `MVCStarter` 内部写）、
`all()` 不用 public（只有 `MVCStarter` 读）、`HttpRequestDistributorImpl.register(metas)` 也不用
（同包）。**整个方案只动 `RequestMetas.add` 一个声明。**

但这条路依然解决不了 `consumes`/`produces`——它们不是注册问题，是字段写入权限问题。

### 2.3 注册时序：宏在 static init 展开

`MVCStarter.generateAndRegister` 里：

```cangjie
if (!initial_.load()) { ... } else {
    throw MVCException("The generateAndRegister can only be called before calling MVCStarter.start().")
}
```

`initial_` 在 `MVCStarter.initialize()` 里置位，而 `MVCInitializer <: Initializer` 的 `initialize()`
正是调它。所以注册的时间窗是：**动态库被加载时（`static init`）→ 早于 `InitializerCollection.initialize()`**。

`@Controller` 宏生成的代码恰好就落在这个窗口里（`Controller.cj` 里对每个 Mapping 方法生成
`MVCStarter.generateAndRegister<$klass>(...)`），这也是它在 `fboot run` 模式下能工作的原因。

> 这个限制对 JSON-RPC 几乎无感：路由只有一条（端点路径），注册一次就够；
> 之后增删**方法**只动方法表，不碰路由。

**一个容易混淆的地方：挂载 ≠ 生效。** `generateAndRegister` 只是把条目放进
`HttpRequestDistributorImpl` 的 pattern 表；真正对外可用要等 `MVCStarter.start()` 里
`server.serve()`。所以「注册发生在 static init」和「所有 RequestMeta 在 initialize 之后才生效」
这两句话并不矛盾：前者是填表，后者是开始服务。

---

### 2.4 参考 WSMeta 的分工，但不复制它的重量

WebSocket 是 f_mvc 里"另一个协议"的现成样板，值得参考的是**分工**，不是它的体量。

`WSMeta.cj` 的结构：

```cangjie
sealed abstract class WSFuncMeta<T> {
    public let name: String
    public let mediaType: String
    public let responseFrameType: ?WebSocketFrameType
    let args = RequestArgMeta()
    var `handle` = {_: T, _: HttpContext, _: HttpRequestPathPatterns, _: WebSocket, _: Array<Byte> => Array<Byte>()}
}
public class WSOpenMeta<T>    <: WSFuncMeta<T> { ... }   // 6 个子类
public class WSCloseMeta<T>   <: WSFuncMeta<T> { ... }
public class WSTextMeta<T>    <: WSFuncMeta<T> { ... }
public class WSBinaryMeta<T>  <: WSFuncMeta<T> { ... }
public class WSPingMeta<T>    <: WSFuncMeta<T> { ... }
public class WSPongMeta<T>    <: WSFuncMeta<T> { ... }
```

`WSMeta<T>` 把 6 个事件各自的 handler 打包成一个对象，再由
`RequestMeta.setHandle(meta: WSMeta<T>)` 这个重载转换成一条路由；
注册入口是 `MVCStarter.generateAndRegisterWSEndPoint<T>(path): WSMeta<T>`。

**它的重量来自"6 个事件"**：每个事件有自己的 handler、媒体类型、返回值处理、参数提取。
JSON-RPC 只有一个入口（POST 一个端点，方法在 body 里分发），所以：

| | WebSocket | JSON-RPC |
|---|---|---|
| 协议事件数 | 6（open/close/text/binary/ping/pong） | **1**（一个请求入口） |
| 需要打包的 handler | 6 个 | 1 个 |
| meta 的职责 | 事件表 + 每事件媒体类型 | **方法表**（name → handler） |
| 对应物 | `WSMeta<T>` | `JsonRpcServer` |

**结论：不需要 `JsonRPCMeta`。** `JsonRpcServer` 本身就是那个 meta——它持有方法表、
编解码、错误映射；再包一层 `JsonRPCMeta` 只是给同一个东西换个名字，没有增加信息。

**也不需要 `@JsonRPC` 宏。** 原因是 `@Controller` 不按注解名筛选：

```cangjie
// Controller.cj：对每个 public 实例方法都生成 generateAndRegister
let metas = MVCStarter.generateAndRegister<$klass>($(f.identifier.value), $argTypes)
```

真正的筛选发生在 `RequestMeta.generate` 里，而且它是**按基类匹配**的：

```cangjie
// RequestMeta.cj:540
if (let a: RequestMapping <- annotation) {
```

也就是说，**任何 `RequestMapping` 子类都会被识别**，宏这一层不需要改动。

#### `@JsonRpcMapping`（已采用）

```cangjie
package fountain::f_jsonrpc

import fountain::f_mvc.*

/// JSON-RPC 端点。method 固定 POST，consumes / produces 固定 application/json。
@Annotation[target: [MemberFunction]]
public class JsonRpcMapping <: RequestMapping {
    public const init(
        path!: String,
        params!: String = '',
        headers!: String = '',
        ignoreAuth!: Bool = false,
        ignorePrivilege!: Bool = false
    ) {
        super(path: path,
              method: RequestMethod.POST,
              produces: 'application/json',
              consumes: 'application/json',
              params: params,
              headers: headers,
              ignoreAuth: ignoreAuth,
              ignorePrivilege: ignorePrivilege)
    }
}
```

**只暴露 5 个参数，三个协议相关项硬编码。** 这不是保守，是因为那三项不是"风格选项"：

| 参数 | 若允许覆盖 | 后果 |
|---|---|---|
| `method` | 改成 GET | JSON-RPC 的 body 可能被 HTTP 层直接丢弃 |
| `consumes` | 写成非 JSON 或留空 | **415**——路由表的键为空，匹配不上（2.2 ①） |
| `produces` | 写成非 JSON | 带 `Accept: application/json` 的客户端 **406**（2.2 ②） |

放出去只会制造误配，收进来就永远不会错。

保留的 5 个都是路由层面的：

| 参数 | 用途 |
|---|---|
| `path` | 端点路径；支持 `{}` 路径变量和 `|` 多路径（沿用 `generate` 的拆分逻辑） |
| `params` / `headers` | 路由条件，可用于按 header 分流版本 |
| `ignoreAuth` / `ignorePrivilege` | 鉴权开关。JSON-RPC 端点常常要关掉 MVC 的会话校验，改由方法内部按 `method` 处理权限 |

用法与 `@PostMapping` 完全一样，只是少写三项：

```cangjie
@Controller
public class JsonRpcController {
    /// 方法表由 JsonRpcRegistry 在 static init 阶段填充
    private let server = JsonRpcRegistry.server()

    /// 默认端点：不做命名空间过滤
    @JsonRpcMapping[path: '/rpc']
    public func handleRoot(@RequestBody raw: Array<Byte>): Any {
        dispatch(raw, '')
    }

    /// 租户端点：topic 作为方法命名空间（3.3）
    @JsonRpcMapping[path: '/rpc/{topic}']
    public func handleTopic(@PathVariable topic: String, @RequestBody raw: Array<Byte>): Any {
        dispatch(raw, topic)
    }

    /// 两条路由共用的分发逻辑；private 方法不会被 @Controller 注册
    private func dispatch(raw: Array<Byte>, topic: String): Any {
        let ctx = CurrentHttpContext.instance
        let rpcCtx = JsonRpcContext(
            http: Some(ctx),
            endpoint: if (topic.isEmpty()) { '/rpc' } else { '/rpc/${topic}' },
            topic: topic,
            meta: forwardableHeaders(ctx)
        )
        match (server.handle(raw, ctx: rpcCtx)) {
            case Some(bytes) => bytes    // 正常响应
            case None => ()              // 通知：不写响应体（4.8）
        }
    }
}
```

**成立的两条前提，都已核实：**

1. `RequestMeta.generate` 按**基类**匹配注解——`RequestMeta.cj:540` 是
   `if (let a: RequestMapping <- annotation)`，不是枚举五个具体子类。
2. 跨包继承允许——官方文档（`ClassTypeInfo.isOpen` 契约）写明
   「`abstract class` 无论是否被 `open` 修饰符修饰都会拥有 `open` 语义」，
   而 `RequestMapping` 正是 `public abstract class`。

> 兜底：若将来 `generate` 改成枚举具体类型，退回
> `@PostMapping[path:'/rpc', consumes:'application/json', produces:'application/json']`。
> 行为完全等价，**仍是 f_mvc 零改动**，只是三项要手写。

---

## 3. 一个 JSON-RPC 端点如何变成 RequestMeta

### 3.1 映射表

| JSON-RPC 概念 | `RequestMeta` | 说明 |
|---|---|---|
| 端点路径 `/rpc` | `path` | 一个端点一条路由 |
| `POST` | `method` | JSON-RPC 只用 POST |
| `application/json` | `consumes` / `produces` | 必须显式指定，见 4.3 |
| 请求体的 `method` 字段 | — | **不映射到路由**，在端点内分发 |
| `id` | — | 与 HTTP 层无关，仅在响应体里回填 |
| 批量数组 | — | 一次 `handle` 调用内循环，仍是一条路由 |
| 通知（无 `id`） | — | 返回 `Unit`，不写响应体 |

### 3.2 为什么 `method` 不映射成路由

「一个 JSON-RPC 方法 = 一个 RequestMeta」既做起来贵，也不该做。

**做起来贵**：一条路由需要一个带 Mapping 注解的方法，而注解是编译期固定的。
方法表是运行期的（可以随时增删方法），想让它和路由一一对应，就得为每个方法写一个包装方法，
且增删方法要重启。

**更不该做**：

| 损失 | 说明 |
|---|---|
| 批量请求失效 | 批量要求多条调用进同一个 HTTP 请求；拆路由后每条都要单独发，JSON-RPC 的 batch 直接没了 |
| 错误模型分裂 | `-32601`（方法不存在）本该是 JSON-RPC 错误对象，拆路由后变成 HTTP 404，客户端拿到的不是合法 JSON-RPC 响应 |
| 参数校验前移 | 路由层只能校验路径/头，校验不了 `params`；最终还是要进方法表分发 |
| 鉴权语义混乱 | `ignoreAuth` 是路由级；方法级的权限差异无法表达 |

所以定死：**一个 JSON-RPC 端点 = 一个 `RequestMeta`**，`method` 在请求体内分发。
需要按方法分权限时，用**多端点**——一个端点一个 `RequestMeta`，各自带自己的 `ignoreAuth`，
方法表按端点隔离。

> 反过来说，这个决定让运行期扩缩容变得非常轻：**加一个方法 = 往 `HashMap` 里加一条**，
> 不涉及任何路由变更，也不需要重新 `initialize()`。

### 3.3 端点形态与多租户

| 形态 | 怎么写 | RequestMeta 数 | 场景 |
|---|---|---|---|
| 单端点（默认） | 一个方法，`@JsonRpcMapping[path: '/rpc']` | 1 | 标准 JSON-RPC |
| 带租户 | **两个方法**，`/rpc` 与 `/rpc/{topic}` 各一个 | 2 | 按 `topic` 分组 |
| 多服务 | 多个 `@Controller`，各自路径 | N | 隔离方法表与鉴权 |

> **为什么租户场景用两个方法，而不是 `path: '/rpc|/rpc/{topic}'`。**
> `|` 确实能生成两条路由，但两条路由共用同一个方法的同一套参数——
> 而 `/rpc` 上没有 `{topic}` 这个路径变量，`@PathVariable topic` 取不到值会抛
> `HttpRequestException`（`extract` 的 `default` 为空时的行为）。
> 两个方法各自声明参数，语义清楚且不依赖默认值。

#### `{topic}` 的语义：命名空间过滤，不是前缀补全

**定义：`topic` 是方法名的命名空间，请求体里的 `method` 仍是完整名。**

```
POST /rpc/kb   {"method":"kb.search"}   → 命中
POST /rpc/kb   {"method":"search"}      → 不命中
POST /rpc/kb   {"method":"crm.list"}    → 不命中（跨命名空间）
POST /rpc      {"method":"kb.search"}   → 命中（默认端点不过滤）
```

不做「前缀补全」的三个理由：

| 问题 | 说明 |
|---|---|
| 同一份 body 语义随路径变 | JSON-RPC 请求体本该自包含；换个 URL 换个解释，缓存、重放、审计日志都会失真 |
| 与 MCP 不兼容 | MCP 的工具名是全局的，客户端按名字缓存；前缀补全让它无法复用同一份 `tools/list` |
| 排障困难 | 报错里的 `method` 与实际注册名不一致，日志对不上 |

**过滤规则**：

| 请求 | 行为 |
|---|---|
| `topic` 为空（`/rpc`） | 不过滤，全表可调 |
| `topic="kb"` 且 `method="kb.search"` | 命中 |
| `topic="kb"` 但 `method` 不以 `kb.` 开头 | `-32601`（该命名空间下不存在） |
| `topic` 没有任何方法属于它 | `-32004 UnknownTopic` |
| `method` 本身未注册 | `-32601` |

命名空间从方法名反推：第一个 `.` 之前的部分即命名空间；不含 `.` 的方法属默认命名空间，
只能从 `/rpc` 调用。

```
kb.search      → 命名空间 kb
crm.user.list  → 命名空间 crm
ping           → 默认命名空间
```

---

## 4. 服务端设计

### 4.1 分层

```
JsonRpcServer（方法表 + 编解码 + 错误映射）
      │
JsonRpcController（唯一 HTTP 入口，@Controller）
      │
f_mvc（RequestMeta / 鉴权 / 日志 / 异常）
      │
stdx.net.http（真正的 HTTP 服务器）
```

`JsonRpcServer` 不依赖 HTTP，可以被 stdio、本地直调复用——这一点对 `f_mcp` 很关键（见 f_mcp 设计 4.3）。

### 4.2 核心类型

```cangjie
package fountain::f_jsonrpc

/// 方法处理函数：入参是 params（可能为 None），返回 result
public type JsonRpcHandler = (JsonRpcContext, ?JsonValue) -> JsonValue

public class JsonRpcContext {
    /// HTTP 侧信息；stdio / 本地直调时为 None
    public let http: ?HttpContext
    /// 请求 id（通知时为 None）
    public let id: ?JsonValue
    /// 端点路径或逻辑端点名
    public let endpoint: String
    /// 路径里的 {topic}；默认端点为 ""
    public let topic: String
    /// 调用方从 HTTP 头透传的元数据（MCP 的 _meta 走这里）
    public let meta: HashMap<String, String>

    /// 设置响应头。仅在 handler 执行期间有效。
    public func setResponseHeader(name: String, value: String): Unit
}

public class JsonRpcMethodMeta {
    public let name: String
    public let handler: JsonRpcHandler
    public let description: String
    public let inputSchema: ?JsonValue
    public let outputSchema: ?JsonValue
    public let timeout: ?Duration
}
```

`description` / `inputSchema` / `outputSchema` 在纯 JSON-RPC 场景用不上，但 `f_mcp` 需要它们来生成
`tools/list` 的响应——提前放进方法元数据，避免 `f_mcp` 再维护第二张表。

**`setResponseHeader` 的实现与边界**：

```cangjie
public func setResponseHeader(name: String, value: String): Unit {
    match (http) {
        case Some(ctx) => ctx.responseBuilder.header(name, value)
        case _ => ()          // stdio / 本地直调：无响应头概念，静默忽略
    }
}
```

三条约定：

1. **只在 handler 执行期间调用有效**——handler 返回后响应就由 `respond` 组装了，
   之后再改 `responseBuilder` 不会生效。
2. **不要覆盖 `Content-Type`**。JSON-RPC 的响应体是 JSON，覆盖会让客户端解析失败。
   要表达"这是 JSON-RPC"，加自定义头（如 `X-JsonRpc-Version`），别动标准头。
3. **stdio 场景是 no-op**，不是报错。同一份 handler 代码要能同时跑在两种传输上。

### 4.3 服务端 API

```cangjie
public class JsonRpcServer {
    public static func builder(): Builder

    public class Builder {
        /// 逻辑端点名，用于日志与多端点区分
        public func endpoint(name: String): Builder
        /// 单次请求方法数上限（批量保护），默认 100
        public func maxBatchSize(n: Int64): Builder
        /// 请求体字节上限，默认取 f_mvc 的 mvc_maxRequestBodySize
        public func maxBodyBytes(n: Int64): Builder
        public func addMethod(meta: JsonRpcMethodMeta): Builder
        public func build(): JsonRpcServer
    }

    /// 处理一段原始请求体，返回响应体（None 表示 204 无内容）
    public func handle(body: Array<Byte>, ctx!: JsonRpcContext): ?Array<Byte>

    /// 本地直调，不经 HTTP（stdio 传输与单元测试复用）
    public func invoke(method: String, params!: ?JsonValue = None): JsonValue

    public func methods(): ArrayList<JsonRpcMethodMeta>
}
```

### 4.4 HTTP 入口：一个 `@Controller`

```cangjie
package fountain::f_jsonrpc

import fountain::f_mvc.*
import fountain::f_mvc.macros.*

@Controller
public class JsonRpcController {
    /// 方法表由 JsonRpcRegistry 在 static init 阶段填充
    private let server = JsonRpcRegistry.server()

    /// 默认端点：不做命名空间过滤
    @JsonRpcMapping[path: '/rpc']
    public func handleRoot(@RequestBody raw: Array<Byte>): Any {
        dispatch(raw, '')
    }

    /// 租户端点：topic 作为方法命名空间（3.3）
    @JsonRpcMapping[path: '/rpc/{topic}']
    public func handleTopic(@PathVariable topic: String, @RequestBody raw: Array<Byte>): Any {
        dispatch(raw, topic)
    }

    /// 两条路由共用的分发逻辑。private 方法不会被 @Controller 注册（宏只看 public 实例方法）
    private func dispatch(raw: Array<Byte>, topic: String): Any {
        let ctx = CurrentHttpContext.instance
        let rpcCtx = JsonRpcContext(
            http: Some(ctx),
            endpoint: if (topic.isEmpty()) { '/rpc' } else { '/rpc/${topic}' },
            topic: topic,
            meta: forwardableHeaders(ctx)
        )
        match (server.handle(raw, ctx: rpcCtx)) {
            case Some(bytes) => bytes    // 正常响应
            case None => ()              // 通知：不写响应体（4.8）
        }
    }
}
```

四个要点：

1. **body 用 `Array<Byte>`，不要用 `JsonValue`。**
   `RequestMeta.extract` 对 `?Array<Byte>` 有专门分支，直接走 `extractBytes(ctx)` 全量拷贝
   `ctx.request.body`（`RequestMeta.cj:454`）。解析权留在自己手里，`-32700`（Parse error）
   才能正确产生——如果让框架先解析，失败时抛的是框架异常，不是 JSON-RPC 错误对象。

2. **`consumes` / `produces` 不用写，`@JsonRpcMapping` 已把它们固定为 `application/json`。**
   这项之所以要固定而不是让调用方填：`consumes` 就是**路由表的键**（2.2 ①），
   填错或留空会让所有请求变成 415，而它在代码里看起来只是个普通的注解参数。

3. **返回类型写 `Any`：正常路径返回 `Array<Byte>`，通知返回 `()`。**
   `setHandle` 的结果分派分别对应 `case x: Array<Byte> => respond(x, ctx)` 与 `case _: Unit => ()`，
   前者直接写字节、不二次序列化，后者完全不碰响应构建器。
   若声明成 `Array<Byte>`，通知就只能返回空数组，反而要赌"空数组会被序列化成什么"。

4. **要拿 `HttpContext` 用 `CurrentHttpContext.instance`，不要加 `ctx: HttpContext` 参数。**
   `extract` 要求每个 controller 参数都有且仅有一个 Mapping/Param 注解，给 `HttpContext`
   挂一个 `@RequestParam` 语义上是错的。而 `CurrentHttpContext` 是 f_mvc 公开的 ThreadLocal 包装
   （`CurrentHttpContext.cj`），`setHandle` 在调用 handler 前已经 `set(ctx)`，直接用即可。

> 多端点：一个 controller 里写多个 `@JsonRpcMapping` 方法，或用 `path: '/rpc|/rpc/{topic}'`
> 生成两个 `RequestMeta`。两者都符合「一个端点 = 一个 RequestMeta」。
>
> 注解本身在 f_jsonrpc 里定义（2.4），继承 `f_mvc` 的 `RequestMapping`，**不需要改 f_mvc**。
>
> 两个入口方法而不是一个方法挂两条路径，是因为 `/rpc` 上取不到 `{topic}`（3.3）。
> `private func dispatch` 不会被 `@Controller` 注册——宏只遍历 **public** 实例方法。

### 4.5 处理流水线

```
raw bytes
   │
   ├─① 大小检查（maxBodyBytes）→ 超限：-32600 + HTTP 413
   ├─② JsonValue.fromBytes → 失败：-32700 + HTTP 200（见 4.6）
   ├─③ 形态判定
   │     ├ 数组  → 批量（长度 ≤ maxBatchSize，空数组 → -32600）
   │     ├ 对象  → 单条
   │     └ 其他  → -32600
   ├─④ 逐条校验：jsonrpc=="2.0"、method 存在且是 String、id 类型合法
   │     └ 不合法 → 该条返回 -32600（批量里只错这一条）
   ├─⑤ 查方法表 → 不存在：-32601
   ├─⑥ 参数类型检查（可选，见 4.7）→ 不匹配：-32602
   ├─⑦ 调 handler，捕获异常
   │     ├ JsonRpcException → 用它的 code/message/data
   │     └ 其他异常 → -32603，message 泛化，细节进日志
   └─⑧ 有 id → 组响应；无 id → 通知，不产出
```

### 4.6 错误模型

JSON-RPC 2.0 的五个标准错误码，加四个项目自定义：

| code | 名称 | 产生位置 | HTTP 状态 |
|---|---|---|---|
| -32700 | Parse error | ② 解析失败 | **200**（见下） |
| -32600 | Invalid Request | ④ 结构不合法 | **200** |
| -32601 | Method not found | ⑤ | **200** |
| -32602 | Invalid params | ⑥ | **200** |
| -32603 | Internal error | ⑦ 未捕获异常 | **200** |
| -32001 | Server error | **保留，当前实现不产生** | — |
| -32002 | Timeout | 显式配置的 `timeout` 到点 | **200** |
| -32003 | Overloaded | **仅批量条数超限**（`data = {limit, size}`） | **200** |
| -32004 | Unknown topic | `{topic}` 下没有任何方法 | **200** |

**除了「请求体超限（413）」和「框架级异常（5xx）」，一律 HTTP 200。**

这一条经常被写错：JSON-RPC 2.0 的错误是**协议层**的错误，放在 JSON 响应体里；HTTP 状态码只表达
传输层是否成功。如果 `-32601` 返回 404，客户端拿到的就不是一个合法的 JSON-RPC 响应，
批量请求也没法表达「3 条成功 1 条方法不存在」。

> 通知不返回响应体（实现见 4.8），具体状态码是 200 还是 204 由 `f_mvc` 对 `Unit` 分支的处理决定，
> 列为 P0 验收项。

#### 码段划分：业务必须避开项目段

JSON-RPC 2.0 把 `-32000 ~ -32099` 留给「实现定义的服务端错误」。本项目这样切：

| 区间 | 归属 | 用途 |
|---|---|---|
| `-32768 ~ -32005`（其余） | 规范保留 | **不得占用** |
| **`-32001 ~ -32004`** | **f_jsonrpc 保留** | 框架级：超时、过载、未知 topic |
| **`-32020 ~ -32099`** | **业务可用** | 业务自定义错误 |
| `1000 ~ 9999`（正数，可选） | 业务可用 | 需要与客户端约定时，正数更易读、日志里更醒目 |

**`-32001 ~ -32004` 是框架占用的，业务不要往里加码。** 后续版本可能继续在该段内新增
（比如 `-32005` 用于限流），业务码一旦落进去，将来会撞。

业务侧统一这样抛：

```cangjie
throw JsonRpcException(-32020, 'Knowledge base not found', data: JsonString(id))
```

`code` 落在 `-32020 ~ -32099`，`message` 给人类看，`data` 放结构化细节。

### 4.7 参数校验：三条路，与 `JsonSchema.validate`

| 路线 | 做法 | 适用 | 依赖 |
|---|---|---|---|
| **弱类型** | handler 拿 `?JsonValue` 自己取字段 | 结构随业务变化、要透传给下游 | 无 |
| **强类型** | `@DataAssist[fields]` 类 + `fromJson<T>(params.toString())` | 参数固定、复用 `f_data` 转换 | `f_data`（已有） |
| **schema 校验** | `JsonSchema.validate(schema, params)` | 要对客户端声明 `inputSchema`，且不想手写校验 | **`f_data` 新增 `validate`** |

强类型路线有个坑：**`fromJson<T>` 接受 JSON 文本，不是 `JsonValue`**：

```cangjie
public func fromJson<T>(s: String, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?T
where T <: FromData
```

所以要先 `params.toString()`（紧凑序列化）再解析。多做一次序列化 + 反序列化，换来类型安全与现成校验——只有参数结构稳定时才值得。

#### 4.7.1 `f_data` 要新增的 API

**现状**：`JsonSchema` 只是 **schema 构造器**。`f_data/src/json/JsonSchema.cj` 全文没有 `validate`，
六个子类（`JsonBoolSchema` / `JsonIntSchema` / `JsonFloatSchema` / `JsonStringSchema` /
`JsonArraySchema` / `JsonObjectSchema`）只携带约束字段，没有任何校验行为。

要加的东西：

```cangjie
package fountain::f_data.json

public struct ValidationError {
    /// JSON Pointer：'' 是根，'/limit' 是成员，'/tags/0' 是数组元素
    public let path: String
    /// 触发失败的关键字：'type' / 'required' / 'minLength' / 'pattern' / '$schema'
    public let keyword: String
    /// 给人看的一句话，不保证可解析
    public let message: String
}

public struct ValidationResult {
    public let errors: Array<ValidationError>
    /// lenient 模式下被跳过的关键字（带路径），用于事后审计
    public let skipped: Array<String>
    public prop isValid: Bool {
        get() { errors.size == 0 }
    }
    /// 直接塞进 JSON-RPC 的 error.data，客户端可按 path 定位字段
    public func toJson(): JsonArray
}

public enum UnknownKeyword {
    | Reject    // 默认：遇到不认识的约束就报错（fail-closed）
    | Skip      // 跳过并记进 skipped
}

public struct ValidationOptions {
    public let maxErrors!: Int64 = 32
    public let maxDepth!: Int64 = 64
    public let unknownKeyword!: UnknownKeyword = UnknownKeyword.Reject
}

public sealed abstract class JsonSchema {
    public const init() {}

    /// ① 实例校验：按注解自带的约束校验一个值
    public func validate(value: JsonValue, options!: ValidationOptions = ValidationOptions()): ValidationResult

    /// ② 文档校验：按 toJsonSchema<T>() 生成的 schema 文档校验
    public static func validate(schema: JsonObject, value: JsonValue,
                                options!: ValidationOptions = ValidationOptions()): ValidationResult
}
```

实现方式：**在基类里写一个 `validate`，用 `match (this)` 分派到六个子类**，不搞六个 `override`。
理由是 `JsonSchema` 是 `sealed`，所有子类都在同一文件里，`match` 的穷尽性由编译器检查——
以后新增一个 Schema 子类，编译期就会报"未覆盖分支"，不会像 `override` 那样漏掉也照样编译通过。

> 两个 `validate` 是"实例方法 + 静态方法"的重载，参数个数不同（1 / 2）。若实际编译时
> 重载解析有歧义，退化为 `JsonSchemaValidator.validate(schema, value)`——语义不变。

#### 4.7.2 为什么必须有两个重载

因为 `JsonObjectSchema` **不携带 `properties`**。它的全部字段只有四个：

```cangjie
public class JsonObjectSchema <: JsonSchema {
    public const JsonObjectSchema(
        public let required!: ?String = None,
        public let additionalProperties!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
```

而 `properties` 是在 `toJsonSchema(typeInfo)` 里从 `mutableFields` **现查**出来拼进文档的
（`JsonSchema.cj:206-213`）。也就是说：**对象成员的 schema 只存在于生成的文档里，不在注解对象上。**

| 要校验的东西 | 用哪个 |
|---|---|
| 单个标量 | 实例版：`JsonStringSchema(minLength: 1).validate(v)` |
| 数组及其元素 | 实例版：`JsonArraySchema(items: JsonStringSchema(...), minItems: 1).validate(v)`，`items` 会递归 |
| **带成员的对象** | **文档版**：`JsonSchema.validate(JsonObject.toJsonSchema<T>(), v)` |

实例版的 `JsonObjectSchema` 只做两件事：检查 `required` 列出的键都存在；其余检查不了。
`additionalProperties` 在实例模式下**必须跳过**——没有 `properties` 就无从判断哪些是"额外"的，
硬判会让任何非空对象都失败。

#### 4.7.3 关键字支持矩阵

"模式"一列：**两者** = 实例与文档都支持；**文档** = 只有文档版支持。

| 关键字 | 模式 | 支持 | 说明 |
|---|---|---|---|
| `type` | 两者 | ✅ | `integer` 只接受 `JsonInt`；`number` 接受 `JsonInt` 与 `JsonDecimal` |
| `nullable` | 两者 | ✅ | `Option<T>` 生成的字段，`JsonNull.instance` 合法 |
| `enum` | 两者 | ✅ | 用 `JsonValue` 的 `==`（已实现），不要转字符串比 |
| `minLength` / `maxLength` | 两者 | ✅ | **数码点**，不数字节、不数字素簇 |
| `pattern` | 两者 | ✅ | `p.regex(solid: false).matches(s)`（`f_regex`）；`matches` 是"存在匹配"，正合 JSON Schema 的非锚定语义 |
| `format` | 两者 | ⚠️ | 只认 `date` / `date-time` / `email` / `uuid`；`uri` 及其余按未知关键字处理（fail-closed） |
| `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` | 两者 | ✅ | |
| `multipleOf` | 两者 | ✅ 整数 / ⚠️ 浮点 | 浮点用 `Decimal` 取余；若实测不可靠则跳过并记入 `skipped` |
| `minItems` / `maxItems` / `items` | 两者 | ✅ | `items` 递归；深度受 `maxDepth` 约束 |
| `uniqueItems` | 两者 | ✅ | 用 `==` 比较；元素数 > 1000 时跳过并记录（O(n²)） |
| `required` | 两者 | ✅ | |
| `additionalProperties` | **文档** | ✅ | 实例模式跳过（见 4.7.2） |
| `properties` | **文档** | ✅ | 实例模式不存在这个字段 |
| `title` / `description` / `default` | 两者 | — | 纯注解，不参与校验 |
| `$ref` / `$defs` / `allOf` / `anyOf` / `oneOf` / `not` | — | ❌ | **fail-closed：直接判失败** |

#### 4.7.4 五个实现要点

1. **`enumeration` 和 `required` 是「JSON 文本字符串」，不是 `|` 分隔。**
   证据是生成侧就按 JSON 解析：`property.add("enum", JsonValue.fromStr(enumeration).asArray())`。
   所以 `JsonStringSchema(enumeration: '["a","b"]')` 才是合法写法。
   解析失败必须当 **schema 错误**（`keyword: "$schema"`）处理，不能当空数组——空数组会让 `enum` 变成"拒绝一切"。

2. **`minLength` / `maxLength` 数码点。** 与 `f_io` 的 `readString(count)` 保持同一约定：
   `"😀"` 长度是 1，不是 4；`"👨‍👩‍👧"` 是 5（三个 emoji + 两个 ZWJ）。要按视觉字符得有 UAX #29 分割，
   不在本模块范围，文档里写明这个限制。

3. **`pattern` 的正则必须编译一次。** 编译结果挂在 `CompiledSchema` 上；非法 pattern 要捕获
   引擎抛出的异常并转成 schema 错误（`keyword: "$schema"`）——`String.regex` 内部没有 try/catch，
   `RegexException` 会直接冒到调用方。用 `f_regex`，`solid` 怎么选取见本节末。

4. **`format` 只判能判的四个。** `email` / `date` / `date-time` / `uuid`；
   `uri` 及其余一律按未知关键字处理。JSON Schema 里 `format` 默认是注解而非断言，
   语义明确的就判，判不了的不许假装支持。

5. **`maxErrors` 必须真的生效。** 校验器要能提前返回：凑够 32 条就停，不再继续遍历。
   否则一个 10 万元素的数组能返回 10 万条错误，响应体积直接失控。

**正则用 `f_regex`，`solid` 必须按来源区分。**

`f_data` 的 `cjpm.toml` 里已经有 `"fountain::f_regex" = {path = "../f_regex"}`，
直接 `import fountain::f_regex.*` 即可——它 `public import std.regex.*`，`Regex` / `RegexFlag`
一并带出来。**不需要给 `f_data` 新增依赖。**

```cangjie
// f_regex/src/RegexFromString.cj
public interface RegexFromString {
    func regex(flags!: Array<RegexFlag> = [], solid!: Bool = false): Regex
}
extend String <: RegexFromString
```

`solid` 不是"快不快"的开关，是**缓存策略**——两个分支背后是两张不同的表：

| | `solid: true` | `solid: false`（默认） |
|---|---|---|
| 存放 | 进程级 `ConcurrentHashMap` | `HeapCache` |
| 上限 | **无** | 10000 条 |
| 失效 | 永不 | 1 天 |
| 适用 | **编译期常量** | **运行期动态串** |

所以按正则的来源选：

| 来源 | `solid` | 理由 |
|---|---|---|
| `format` 的固定模式（`email` / `date` / …） | **`true`** | 只有 4 个，与 `ExtendRegex.EMAIL` 这类静态 prop 的写法一致；无上限表不会增长 |
| schema 文档里的 `pattern`（任意多、可能由外部提供） | **`false`** | 走 `solid: true` 会写进无上限的进程级表，等于给外部输入开一条只增不减的内存路径 |

三条附带说明：

1. **两个分支互查对方的表**（`solid: true` 先查 `HeapCache`，`solid: false` 先查进程表），
   所以同一个 pattern 用不同取值调用也不会重复编译。但**不要依赖这个**——按来源固定取值，
   读代码时才看得出意图。
2. **缓存过期不影响已持有的实例。** `CompiledSchema` 自己持有 `Regex` 引用，
   1 天过期只影响"下次查表要不要重编"，不影响手上这个。
3. **`flags` 一律传 `[]`。** JSON Schema 的 `pattern` 没有 flags 概念；加 `IgnoreCase`
   会悄悄改变语义，与"照 schema 校验"直接冲突。

`format` 的四个模式，一个复用、三个自己写：

```cangjie
// 编译期常量，全部 solid: true
let EMAIL_RE    = Regex.EMAIL                                   // ExtendRegex 静态 prop，自带 ^...$
let DATE_RE     = #"^\d{4}-\d{2}-\d{2}$"#.regex(solid: true)
let DATETIME_RE = #"^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?$"#.regex(solid: true)
let UUID_RE     = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#.regex(solid: true)
```

| `format` | 复用/自写 | 备注 |
|---|---|---|
| `email` | 复用 `Regex.EMAIL` | 自带 `^...$` |
| `date` | 自写 | **只做词法**，`2026-02-31` 也会通过；要判真实日期得另做日历校验 |
| `date-time` | 自写 | RFC 3339 的词法近似，不校验闰秒、不校验时区偏移范围 |
| `uuid` | 自写 | 不校验版本位与变体位 |

> 更复杂的模式可以用 `RegexBuilder` 拼（`f_regex` 的可读构造式），但上面四个用字面量更短。

> **`pattern` 与 `format` 的锚定方向相反，别混。** `pattern` 用 `Regex.matches`，语义是"存在匹配"
> （非锚定），正合 JSON Schema；`format` 的模式自带 `^...$`，于是 `matches` 等价于整串匹配。
> 给 `pattern` 自动补 `^...$` 会让 `"abc"` 匹配不上 `b`，语义正好反了。

> **方言差异要认。** JSON Schema 的 `pattern` 按 ECMA-262 定义，而引擎是 Cangjie 的 `std.regex`。
> 绝大多数常用语法一致；遇到引擎不支持的写法会在 `.regex()` 处抛异常，按 schema 错误处理——
> **不能吞掉异常当作"约束不成立"或"约束通过"**，前者会误拒合法请求，后者等于没校验。

#### 4.7.5 fail-closed：三种情况都必须拒

| 情况 | 必须的行为 | 为什么 |
|---|---|---|
| **schema 本身坏了**（`type` 拼错、`required` 不是 JSON 数组） | 判失败，`keyword` 记 `$schema` | 坏 schema 静默通过等于没有校验，而调用方以为校验过了 |
| **有未支持的关键字**（`$ref`、`allOf`…） | 默认 `Reject`：判失败 | 见下 |
| **值不合规** | 判失败，逐条报 `path` + `keyword` | 这是正常路径 |

`$ref` 单独说：MCP 规范要求"解析 `$ref` 后再校验"。首版不实现解析，那就**必须拒绝任何带
`$ref` 的 schema**，不能"跳过这个关键字继续校验其余部分"——跳过之后剩下的约束可能恰恰是次要的，
真正的类型约束全在 `$ref` 里，结果是一份看起来通过、实际什么都没校验的报告。

需要"先跑起来、后补能力"时，用 `unknownKeyword: Skip` 显式降级，并把 `skipped` 写进日志或响应——
**让"没校验"这件事可见**，而不是让它伪装成"校验通过"。

#### 4.7.6 与 JSON-RPC 的接线

```cangjie
// 注册时编译一次，不在请求路径上做
let compiled = JsonRpcSchema.compile(JsonObject.toJsonSchema<SearchParams>())

// 调用时
let r = compiled.validate(params)
if (!r.isValid) {
    throw JsonRpcException(-32602, 'Invalid params', data: r.toJson())
}
```

三条约定：

1. **错误码固定 `-32602`，不要用 `-32001`。** 前者是"参数不合法"（客户端不该重试），
   后者是"服务端内部错误"（客户端可以重试）。用错会让客户端反复重试一个永远不会成功的请求。
2. **`data` 放 `r.toJson()`**，客户端能按 `path` 直接定位到出错字段，不必自己猜。
3. **正常路径零字符串拼接**：`path` 只在出错时构造，`maxErrors` 封顶 32 条。

方法元数据里同时保留两份东西，用途不同：

| 字段 | 类型 | 用途 |
|---|---|---|
| `paramsSchema` | `?JsonObject` | 对外声明（MCP 的 `inputSchema` 直接取它） |
| `compiled` | `?CompiledSchema` | 内部校验，注册时由 `paramsSchema` 编译而来 |

只存文档、每次请求现编译是不行的（正则编译 + 字符串解析都在热路径上）；
只存编译结果、不存文档也不行（要原样发给客户端）。

#### 4.7.7 前置任务与边界

在 `f_data` 里加 `validate` 是 f_jsonrpc 的前置任务（实施顺序里的 **P-1.5**）。

**边界：`validate` 是通用能力，不许把 JSON-RPC 概念塞进 `f_data`。**
错误码、`-32602`、`error.data` 的形状都属于 f_jsonrpc；`f_data` 只回答"这个值满足这个 schema 吗"，
返回结构化的 `ValidationError`。这条同样适用于 f_mcp——它要的 MCP 错误码也留在自己那层。

> 注意这与"`f_mvc` 零改动"不冲突：约束的对象是 `f_mvc`（框架层），不是 `f_data`（数据层）。
> `validate` 本身也不是为协议服务的——任何用 `JsonSchema` 描述结构的场景都需要它。

### 4.8 批量与通知

| 情况 | 行为 |
|---|---|
| 单个请求 | 返回单个响应对象 |
| 批量 · 全部是通知 | 返回 `Unit`，不写响应体 |
| 批量 · 混合 | 只回有 `id` 的响应，顺序不保证 |
| 批量 · 空数组 | 返回单个 `-32600` 错误对象（**不是**数组，规范明确要求） |
| 批量 · 超 `maxBatchSize` | 返回单个 `-32003`，整批拒绝（不做部分执行） |
| 单个通知 | 执行 handler，返回 **`Unit`** |

通知执行失败时**不返回任何东西**——这是 JSON-RPC 的设计：通知的语义是"发了不管结果"。
但日志必须记录，否则出问题无从排查。

**空 body 用返回 `Unit` 实现（已定）。** 依据是 `setHandle` 的结果分派：

```cangjie
case x: Array<Byte> => respond(x, ctx)
case _: Unit => ()                    // ← 什么都不做
```

`Unit` 分支**完全不触碰响应构建器**，是三个候选里唯一不依赖"空数组会被怎么序列化"的。
因此 controller 方法的返回类型写成 `Any`：正常返回 `Array<Byte>`，通知返回 `()`。

```cangjie
match (server.handle(raw, ctx: rpcCtx)) {
    case Some(bytes) => bytes    // 有响应
    case None => ()              // 通知：不写响应体
}
```

> 仍需实测的一点：`Unit` 分支下 `f_mvc` 最终发出的状态码是 200 还是 204。
> 两者对 JSON-RPC 客户端都可接受（通知本就不该有响应体），但要记进 P0 验收，
> 避免将来客户端严格校验状态码时才发现。f_mcp 设计 6.6 是同一个验证项。

### 4.9 并发与超时

`f_mvc` 有业务线程池配置（`mvc_servicePoolCapacity` / `mvc_servicePoolQueueCapacity` / `mvc_servicePoolPreheat`，
三个键必须同时指定才生效）。`f_jsonrpc` 不另建线程池，直接跑在 MVC 的池里。

单方法超时用 `JsonRpcMethodMeta.timeout`：**默认不设超时**，handler 在请求线程内联执行（请求级
ThreadLocal 可用）；只有显式配置了 `timeout` 才在独立 `spawn` 里跑，并用 `CurrentHttpContext.scoped`
恢复上下文，超时返回 `-32002`。

**语义已确认：只提前返回错误，不终止 handler。** 仓颉没有抢占式取消，超时后那个 `spawn`
仍在跑完。这条必须在使用文档里写明，否则会有人把"超时=已停止"当成事实，
在 `timeout` 后面做资源回收，结果和还在跑的 handler 抢同一份状态。

配套的三条缓解措施：

| 措施 | 说明 |
|---|---|
| 超时值按"最慢的正常调用"设，不按"我能忍多久"设 | 把无害的慢调用判成超时，比等久一点更糟 |
| handler 内部自查 deadline | 长循环里每轮检查一次 `ctx.deadline`，超时就抛 `-32002` 自行退出 |
| 有副作用的操作要幂等 | 超时后客户端可能重试，重复执行不能造成二次写入 |

---

## 5. 客户端设计

### 5.1 API

```cangjie
public class JsonRpcClient {
    public init(url: String, opts!: ClientOptions = ClientOptions())

    /// 同步调用
    public func call(method: String, params!: ?JsonValue = None): JsonValue

    /// 异步调用
    public func callAsync(method: String, params!: ?JsonValue = None): Future<JsonValue>

    /// 通知：不等结果
    public func notify(method: String, params!: ?JsonValue = None): Unit

    /// 批量：返回与输入同序的响应（含每条的错误）
    public func batch(calls: Array<JsonRpcCall>): Array<JsonRpcResponse>

    public func close(): Unit
}

public struct ClientOptions {
    public let timeout: Duration = 30s
    public let headers: HashMap<String, String> = HashMap()
    public let maxResponseBytes: Int64 = 8 * 1024 * 1024
    public let keepAlive: Bool = true
}
```

`JsonRpcException` 在客户端侧同样抛出，携带 `code` / `message` / `data`，这样调用方不需要区分
"HTTP 错误"和"业务错误"——只有传输失败才抛 `IOException`。

### 5.2 传输细节

| 项 | 取值 | 理由 |
|---|---|---|
| 方法 | `POST` | JSON-RPC 一律 POST |
| `Content-Type` | `application/json; charset=utf-8` | 带 charset，避免服务端按 ISO-8859-1 猜 |
| `Accept` | `application/json` | |
| 连接复用 | 默认开 | 客户端持有 `Client` 实例，不要每次 new |
| 响应体读取 | 先查 `Content-Length` 预判，再流式累计；超 `maxResponseBytes` 立即抛错并关闭响应（不截断、不返回部分内容） | 防超大响应打爆内存 |

**`Client` 实例必须复用。** `stdx.net.http` 的 `Client` 内部维护连接池，每次调用新建 `Client`
会让 keep-alive 完全失效，在批量场景下延迟翻几倍。

### 5.3 重试策略

**默认不重试。** 理由：JSON-RPC 的方法不保证幂等，自动重试可能造成重复写入。

需要重试时由调用方显式开启，且只对**连接建立失败**重试（不是超时后重试——超时可能已经执行了）：

```cangjie
ClientOptions(retryOnConnectFailure: 2)
```

---

## 6. 与 f_data 的集成

### 6.0 编码：只支持 UTF-8

**已定：f_jsonrpc 只处理 UTF-8，不提供 charset 参数、不做编码探测。**

- JSON-RPC 2.0 规范要求 UTF-8；`f_mvc` 的 `@RequestBody raw: Array<Byte>` 拿到的也是原始字节
- 请求体不是合法 UTF-8 → 直接返回 **`-32700 Parse error`**，**不猜 GBK / 不试探其他字符集**
- 响应一律 UTF-8，`Content-Type: application/json`（JSON 的默认编码就是 UTF-8）

**为什么不猜编码**：同一个字节流在不同请求里可能解出不同结果（取决于"这次猜哪个"），
而 JSON-RPC 是自描述协议——**请求体本身必须无歧义**。需要非 UTF-8 的对端，
应在网关层转码，而不是让协议层去猜。

> 这与 f_xml 的策略不同是有意的：XML 的 `<?xml encoding="..."?>` **自带编码声明**，所以能确定地选解码器；
> JSON 没有等价机制（RFC 8259 直接规定 UTF-8），猜就是错。

### 6.1 编解码的两套字符串

`JsonValue` 有两个序列化方法，差别很大：

| 方法 | 形态 | 用途 |
|---|---|---|
| `toString()` | **紧凑**（无空白） | **协议传输必须用这个** |
| `toJsonString()` | 美化（带缩进换行） | 日志、调试、给人看 |

`toJsonString()` 默认 `pretty = true`。把它用在 HTTP 响应上，会让每个响应多出大量空白，
而且在批量场景下体积翻倍。**f_jsonrpc 内部一律用 `toString()`。**

### 6.2 关键 API 速查

```cangjie
// 解析
JsonValue.fromBytes(bytes)      // Array<Byte> → JsonValue
JsonValue.fromStr(s)            // String → JsonValue
JsonValue.fromInput(input)      // InputStream → JsonValue

// 序列化
json.toString()                 // 紧凑

// 取值
let obj = json.asObject()       // 非对象则抛 JsonException
obj.get('name')                 // ?JsonValue
obj['name']                     // JsonValue，缺失则抛
obj.contains('name')
for ((k, v) in obj) { ... }

let arr = json.asArray()
arr.size
arr[0]
for (v in arr) { ... }

// 强类型
toJson<T>(instance)             // T <: ToData
fromJson<T>(text)               // ?T，T <: FromData

// 校验（本轮新增，见 4.7）
JsonSchema.validate(schema, value)      // schema 文档 → ValidationResult
someSchemaAnnotation.validate(value)    // 注解实例 → ValidationResult
JsonObject.toJsonSchema<T>()            // 从类型生成 schema 文档
```

### 6.3 数字精度

`JsonValue` 的数字有 `JsonInt`（`BigInt`）和 `JsonDecimal`（`Decimal`）两种。
JSON-RPC 的 `id` 允许是数字或字符串，**回填时必须原样返回**：

- 请求 `id` 是 `1`（`JsonInt`）→ 响应 `id` 必须是 `1`，不能变成 `"1"`
- 不要走「解析成 Int64 再拼回去」的路径，大整数会溢出

实现上直接把请求里的 `id` 节点**原样搬到**响应里，不做任何类型转换。

---

## 7. 安全

| 项 | 措施 | 依据 |
|---|---|---|
| 请求体上限 | 默认取 `mvc_maxRequestBodySize`（2 MB） | `f_mvc` 配置项 |
| 批量放大 | `maxBatchSize` 默认 100，超限整批拒绝 | 防一条请求触发上百次 handler |
| 方法枚举 | `-32601` 的 message 不暴露内部方法名清单 | 避免探测 |
| 异常细节 | `-32603` 的 message 泛化，堆栈只进日志 | 避免泄露路径/结构 |
| 鉴权 | 复用 `f_mvc` 的 `ignoreAuth` / `ignorePrivilege` | 路由级；JSON-RPC 内不再做第二套 |
| 客户端 SSRF | `JsonRpcClient` 只接受 `http`/`https`，不跟 `file://` | 由 `f_mcp` 的上层约束 |

**一个容易被忽略的点**：JSON-RPC 的错误 message 会原样返回给调用方。如果 handler 的异常信息里
带 SQL、文件路径、内部 IP，就等于把它们泄露出去。所以 `-32603` 必须是固定文案，真实异常写日志。

---

## 8. 性能

| 环节 | 成本 | 备注 |
|---|---|---|
| `JsonValue.fromBytes` | 与请求体大小线性 | 单次几 KB 的请求可忽略 |
| 方法表查找 | `HashMap` O(1) | |
| `toString()` 序列化 | 与响应体线性 | 比 `toJsonString()` 少 30~50% 字节 |
| HTTP 往返 | 局域网 1~3 ms | 客户端侧主要成本 |
| 批量 | 摊薄 HTTP 往返 | 10 条批量比 10 次单发快 5~8 倍 |

优化点按收益排序：

1. **用批量**——最大的收益，几乎没有代价
2. **复用 `Client` 实例**——保住连接池
3. **响应体用紧凑序列化**——直接减字节
4. 方法表用 `HashMap` 而不是线性扫描

---

## 9. 测试要点

| 类别 | 用例 |
|---|---|
| 协议合规 | 单请求 / 批量 / 通知 / 空批量 / 批量混合通知 |
| 错误码 | 五个标准错误各一条；批量里部分失败仍返回 200 |
| `id` 保真 | 数字 id、字符串 id、大整数 id、`null` id |
| 编解码 | 中文、emoji（4 字节 UTF-8）、转义字符、深层嵌套 |
| 框架集成 | `f_mvc` 的 `consumes` 不匹配时返回 415；body 超限返回 413 |
| 并发 | 100 并发调用同一方法，无串包、无 id 错配 |

**互操作测试**：至少用两个现成的 JSON-RPC 客户端库对着跑一遍。协议实现最容易在
「空批量」「`id: null`」「批量里全是通知」这些边角上出分歧。

---

## 10. 实施顺序

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P-1.5** | **`f_data` 加 `JsonSchema.validate`**（4.7.1，与 P0 并行即可） | `minLength` / `pattern` / `required` / `enum` 四类约束各有正反用例；坏 schema 与 `$ref` 均被判失败 |
| **P0** | 定义 `@JsonRpcMapping` + `@Controller` 最小闭环（不接 JSON-RPC 逻辑，先返回固定字节） | `curl -H 'Content-Type: application/json' -d '{}'` 能拿到响应；漏掉 `Content-Type` 时确认是 415 而不是 404 |
| **P1** | `JsonValue` 编解码封装 + 错误类型 + 方法表 | 单测：五种错误码各产出一条合法错误对象 |
| **P2** | `JsonRpcServer.handle` 单请求路径 | 请求 → 响应字节流正确 |
| **P3** | 批量 + 通知 + 空批量 | 六种批量组合符合规范；确认通知走 `Unit` 分支后的状态码与真空体（4.8） |
| **P4** | `JsonRpcClient` | 与 P2 的服务端互通 |
| **P5** | 超时 + 并发 + 限流 | 超时返回 -32002；100 并发无错配 |
| **P6** | 互操作测试 | 与两个外部客户端库互通 |

**P0 提前到最前面**，是因为上面那两条 415 / 406 的坑只有在真跑起来才会暴露，
而它们与 JSON-RPC 逻辑无关。先用十几行验证「注解路由 + 原始字节 + 返回字节」这条路通，
再往里塞协议实现。

**P2 之前所有测试都可以脱离 HTTP 跑**（`invoke` 直调），能省掉大量调试成本。

**P-1.5 与 P0 无依赖，可并行**：它只碰 `f_data`，不碰 `f_mvc`、不碰 HTTP。
放在最前面是因为"弱类型 + schema 校验"是**降低接入成本的关键**——
没有它，每个方法都得写一个 `@DataAssist` 类，或者手写一遍字段检查。

---

## 11. 已定事项与剩余验证

### 11.1 已定（不再讨论）

| # | 事项 | 结论 | 落点 |
|---|---|---|---|
| 1 | 多租户 | 支持 `/rpc/{topic}`；`topic` 作为**命名空间过滤**，不做前缀补全 | 3.3 |
| 2 | 错误码段 | 项目保留 `-32001 ~ -32004`；业务用 `-32020 ~ -32099` | 4.6 |
| 3 | 响应头 | `JsonRpcContext.setResponseHeader(name, value)` | 4.2 |
| 4 | 超时 | 只提前返回错误，不终止 handler | 4.9 |
| 5 | 空 body | 返回 `Unit` | 4.8 |
| 6 | 注解名 | `@JsonRpcMapping` | 2.4 |
| 7 | 参数校验 | `f_data.JsonSchema` 新增 `validate`（实例版 + 文档版两个重载），f_jsonrpc 用它做 `-32602` | 4.7 |
| 8 | 正则 | 走 `f_regex` 的 `String.regex(solid:)`；`format` 用 `solid: true`，动态 `pattern` 用 `solid: false` | 4.7.4 |
| 9 | 编码 | **只支持 UTF-8**；非法 UTF-8 → `-32700`，不猜其他字符集 | 6.0 |

### 11.2 仍需实测（都在 P0 ~ P3 覆盖）

| # | 待测 | 影响 | 阶段 |
|---|---|---|---|
| 1 | `Unit` 分支的状态码（200 / 204）与是否真空白体 | 通知合规性；f_mcp 同一验证项 | P0 |
| 2 | `@JsonRpcMapping` 在真实 `cjpm` 构建下被 `@Controller` 识别 | 整个接入方式的前提 | P0 |
| 3 | `@PathVariable` 与 `@RequestBody` 共存时的提取行为 | 双方法方案依赖它 | P0 |
| 4 | `setResponseHeader` 设置的头部是否被 `respond(Array<Byte>)` 覆盖 | MCP 回写 `MCP-Protocol-Version` 依赖它 | P1 |
| 5 | 批量里混有通知时，响应顺序与 `id` 保真 | 协议合规 | P3 |

> 这五项都不需要改 `f_mvc`，全部是对现有行为的确认。任何一项不符合预期，
> 优先调整 f_jsonrpc 自己的实现，而不是回头去改框架。


---

## 文档与实现对照（fix-jsonrpc-mcp-review-findings）

| 主题 | 实现（以此为准） |
|---|---|
| 默认超时 | 无。`JsonRpcRegistry.getMeta` 无注解时返回 `JsonRpcMeta('', '')`；`''` = 不设超时 |
| 超时线程模型 | 显式超时才 `spawn`，子线程内 `CurrentHttpContext.scoped(ctx.http)` 建立/清理上下文 |
| `-32001` | 保留常量，当前不产生 |
| `-32003` | 只有批量条数超限会产生 |
| `JsonRpcServer.handle` | 返回 `?JsonValue`；`Content-Type` 由 f_mvc 按 `application/json` 输出 |
| `maxBodyBytes` | 每次请求解析 `MVCConfig.maxRequestBodySize`，显式配置优先，不在 `build()` 快照 |
| `ClientOptions` | `timeout` / `headers` / `maxResponseBytes` / `keepAlive` / `retryOnConnectFailure` |
| 重试边界 | 只有 `JsonRpcConnectException`（建连/发送）可重试；读响应失败永不重试 |
| 参数 schema | 注册期 `CompiledSchema.compile`（结构校验 + 正则预编译） |
| `JsonRpcContext` | 不再有 `meta` 字段；`JsonRpcMethodMeta` 不再有 `inputSchema` / `outputSchema` |
