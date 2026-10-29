# fountain实现思想与应用第十一弹

##### ——RPC实现

项目链接：https://gitcode.com/Cangjie-TPC/fountain

RPC 框架的宣传语永远是「像调用本地方法一样调用远程服务」。但真写过生产系统的人都知道，这句话只描述了 20% 的工作量。剩下 80% 是：

- 服务节点怎么被找到？新节点上线，客户端要改配置吗？
- 接口改了字段，老客户端会不会打过来？
- 某个节点挂了，调用是报错还是自动换一个？
- 一次 HTTP 请求里调了三次 RPC，日志怎么串起来？
- 服务端模块自己也依赖接口定义，会不会调用到自己生成的存根，形成回环？

`f_rpc` 的大部分代码量花在这 80% 上，而它的 API 面积只有两个宏。

---

## 一、把 RPC 压缩成两个宏

```cj
// 共享 API 包：接口 + 数据类型
@RPCStub[version='1.0.0']
public interface UserService {
    func getUser(id: Int64): User
}

// 服务端：实现即发布
@RPCSkeleton
public class UserServiceImpl <: UserService {
    public func getUser(id: Int64): User {
        User(id: id, name: 'tom')
    }
}

// 客户端：从 IOC 拿存根
let userService = lookup<UserService>()
let user = userService.getUser(1)
```

三件事同时发生了：

- `@RPCStub` 修饰接口，展开出一个实现该接口的存根类 `UserService_Stub__`，每个方法体里构造 `ServiceMeta` + `RPCMessage`，调用 `RPCClient.call<R>(message)`；
- `@RPCSkeleton` 修饰实现类，先给它加 `@Bean`（进 IOC），再生成静态初始化块，把每个 public 实例函数注册进 `ServiceHub`；
- 客户端 `lookup<UserService>()` 拿到的其实是存根实例，业务代码看到的是普通接口调用。

宏展开后的形态大致是这样（取自内置的 `HealthRPC`）：

```cj
// @RPCStub 展开（节选）
public class HealthRPC_Stub__ <: HealthRPC {
    public func health(): HealthData {
        let meta = ServiceMeta("*", "", TypeInfo.of<HealthRPC>().qualifiedName,
                                "health", [], exactlyVersion: false)
        RPCClient.call<HealthData>(RPCMessage(meta, []))
    }
}
```

这里有个设计取向值得注意：**存根不做「智能」的事**。它不缓存连接、不做重试、不拼 URL，只负责「把一次方法调用翻译成一条消息」。所有非功能能力（发现、负载均衡、重试、限流、日志）都在 `RPCClient` 和服务端，这样它们才能被统一配置、统一观测。

---

## 二、没有注册中心的「注册中心」

`f_rpc` 不依赖 ZooKeeper、etcd、Consul。它用三个协议命令和一条「定期全量拉取」的循环，做出了服务发现：

```
        ① REGISTER(port, weight)
   ┌──────────────┐ ─────────────────────► ┌──────────────┐
   │  服务节点 A   │                        │   种子节点    │
   │  :1204       │ ◄───────────────────── │   :1203      │
   └──────────────┘   ② ACK                │  (注册表)     │
                                           └──────┬───────┘
        ③ SUBSCRIBE(data=true)                   │
   ┌──────────────┐ ─────────────────────────────►│
   │  客户端       │ ◄─────────────────────────────┘
   │              │   全量节点列表 "ip:port,weight"
   │              │
   │              │   ④ 逐个节点 SUBSCRIBE(data=false)
   │              │      取回该节点的 Array<ServiceMeta>
   └──────────────┘
        ⑤ 每 rpcClient_refreshIntervalSeconds（默认 1s）重复 ③④
```

### 为什么是「拉」而不是「推」

注册表里存的东西极少：`<ip>:<port> → weight`，加上每个节点自报的服务元数据列表。这个量级下，**每秒全量拉一次的成本远低于维护一条长连接的推送通道**，而且天然具备自愈能力：客户端不需要知道「我错过了哪次变更」，拉到的就是当前真相。

代价是收敛有延迟（最坏一个刷新周期），以及节点数很大时拉取流量线性增长。对「几十到几百个服务节点」的规模，这个取舍是划算的；再大就该上分层或推拉结合了。

### 注册表用 TCP 对端 IP 作为地址

服务节点向种子发送 `REGISTER` 时，载荷只有 `"<port>,<weight>"`。种子节点**用 TCP 连接的对端 IP 补上 host**，拼成地址键。

这个细节解决了一个实际痛点：**节点不需要知道自己的对外地址**。容器、NAT、多网卡环境下，「我自己的 IP 是什么」经常是个难题；而「我看到你的 IP 是什么」在服务端是免费的。把这件事交给接收方判断，比让发送方自报要可靠得多。

### 四个元数据变体，为了「怎么都能匹配上」

`ServiceHub.register` 会为每个服务实现类的每个匹配接口注册**四个变体**：

| 变体 | version | name（Bean 名） |
| --- | --- | --- |
| 1 | 项目版本（如 `1.0`） | Bean 名 |
| 2 | `*`（通配） | Bean 名 |
| 3（Bean 名非空时） | 项目版本 | 空 |
| 4（Bean 名非空时） | `*` | 空 |

为什么？因为客户端的 `@RPCStub` 可能写 `version='1.0.0'`，也可能不写属性（版本为 `*`）；可能指定 `name=beanName`，也可能不指定。**服务端把「所有合法的匹配组合」都注册一遍，把匹配复杂度从运行期的字符串比较，前移成了注册期的四倍写入。** 注册是一次性的，匹配是每次调用都要做的——这笔买卖很划算。

顺带一提，注册时会自动跳过 `std.`、`fountain::` 前缀的接口和 `Equatable` / `Comparable` / `Iterable` 等系统接口，否则每个服务都会莫名其妙多出几百个「方法」。

### 退出也要打招呼

节点退出时向种子节点发 `DEREGISTER`（载荷只有 port），种子回复 `ACK`。如果不发，注册表可能在一段时间内仍然认为这个地址可用——这段时间里客户端会往一个死节点上打，只能靠重试兜底。

**能优雅退出的时候，就不要让对端用超时来发现你走了。**

---

## 三、一次调用的完整链路

```
 ① Stub: ServiceMeta(version, name, typeName, methodName, argTypeNames) + RPCMessage(params)
 ② RPCClient.call<R>: 按元数据取连接池 → 按负载均衡取节点
 ③ CONSUME(once=true, qos=AtMostOnce) 发送 RPCMessage
 ④ 服务端 decode → ServiceHub 查执行函数 → 从 IOC 取服务 Bean → 本地调用
 ⑤ RESP(id, result) 或 ERROR(id, 堆栈文本)
 ⑥ 客户端反序列化为 R，失败换下一个节点
```

几个设计点：

**`ServiceMeta` 的五元组就是「方法身份」**：版本、Bean 名、接口完全限定名、方法名、形参类型完全限定名。客户端和服务端不需要共享一个「方法 ID 分配表」，也不需要 IDL 编译——**接口的完全限定名本身就是契约**。这也解释了为什么官方建议把接口放在独立的共享 API 包里：只要两边的包名和类型名一致，就能对上。

**服务端异常不抛给客户端，而是转成 `ERROR` + 堆栈文本。** 因为异常类型跨进程没有意义：客户端没有服务端的异常类，反序列化出来也只能是 `Exception`。与其假装能还原，不如把堆栈原样带回去，客户端统一表现为 `RPCException`，排查时看日志。

**多节点失败会聚合。** 每个节点的异常通过 `addSuppressed` 挂到最终的 `RPCException` 上，而不是只留最后一个。排障时你能看到「A 节点超时、B 节点拒绝」，而不是「B 节点拒绝」。

### 重试的正确语义

```bash
export rpcClient_retryCount=1   # 首次尝试之外的重试次数
```

判定条件是 `tried > retryCount`，所以：

- `0`（默认）：只发第一次，失败就抛；
- `1`：最多两次尝试。

这个语义很容易被误解成「总尝试次数」，配置时多写一个 1 就多打一轮。更要注意的是：**重试只对「换节点可能成功」的失败有意义**。如果服务端已经执行了业务逻辑、只是回包丢了，重试会造成重复执行——RPC 在协议层不做去重，重复执行的风险要业务侧自己兜住（幂等键、唯一约束、状态机都行）。

---

## 四、版本：前两位是契约，第三位是实现

版本匹配规则简单但值得展开：

| 端 | 版本来源 | 截断规则 |
| --- | --- | --- |
| 服务端 | 工作目录 `cjpm.toml` 的 `version=` | `rpcServer_exactlyVersion=false` 保留前两位；`true` 保留全部 |
| 客户端（属性形式） | `@RPCStub` 的 `version` 属性（字面值或配置项名） | `exactlyVersion=false` 保留前两位 |
| 客户端（无属性形式） | 固定 `*`（通配） | — |

也就是说，客户端写 `@RPCStub[version='1.0.0']`，实际查找的是 `1.0`，能命中所有 `1.0.x` 的服务端。

**为什么第三位不算契约？** 因为它表示「实现有变化，但没有破坏性变更」。这给了灰度发布一个抓手：

1. 新版本服务端先以 `rpcServer_exactlyVersion=true` 注册 `1.2.3`，只有显式要求 `1.2.3` 的客户端会打过来——金丝雀；
2. 验证没问题后，把它改成 `false`，服务端就变成 `1.2`，所有 `1.2.x` 的客户端都能用；
3. 客户端如果希望锁定精确版本，把 `@RPCStub` 的 `exactlyVersion` 指向一个配置项，改配置即可，不用重新编译。

反过来，**前两位变化意味着不兼容**。这时候不要指望「客户端自动适配」——正确做法是新旧版本并行部署，客户端按需切换。

还有一个容易忽略的限制：`rpcServer_exactlyVersion=true` 时，注册为 `a.b.c` 的服务端**不能**服务指定版本为 `a.b` 的客户端。精确就是精确，不做前缀回退。

---

## 五、负载均衡、限流、健康检查

### 负载均衡复用了 `MultiClient`

`f_rpc` 的客户端没有自己实现选节点，而是直接用了 `f_net` 的 `MultiClient<W, T>`——那个「迭代即负载均衡」的抽象：

```cj
for (client in multiClient) {
    // 首元素 = 本次选中节点，后续 = 重试节点
}
```

支持 `random` 和 `roundrobin`，按权重选择。权重来自两处：`ServiceMeta.weight`（`@RPCSkeleton[weight=…]` 覆盖 `rpcServer_weight`）优先，为 1.0 时退回注册表里该节点的权重。

官方 demo 里有一组实测数据（每场景 100 次调用，两个节点）：

| 场景 | 配置 | 实测分布 |
| --- | --- | --- |
| 等权轮询 | 两节点各 `1.0`，`roundrobin` | 50 : 50 |
| 权重 2:1 | 1203 `2.0`、1204 `1.0` | 67 : 33 |
| 种子 + 纯服务节点 | 客户端只认识种子 1203，1204 向它注册 | 67 : 33 |

第三行最能说明设计：**客户端配置里只有种子节点，但它最终按 2:1 把流量分给了两个节点**。链路是「客户端订阅种子 → 拿到全部节点 → 逐个订阅元数据 → 权重取自注册表」。扩容时客户端零改动，这是服务发现应该有的样子。

排障时先看这一行日志，它直接告诉你「池子里有谁、权重多少」：

```
[FOUNTAIN_RPC.hosts] <接口>.<方法> v=<版本> -> N host(s): host(weight) …
```

### 限流在服务端，四种算法

```bash
export rpcServer_rateLimiterName=tokenBucketRateLimiter
export rpcServer_tokens=1024
export rpcServer_timeout=100
```

可选 `anyMomentRateLimiter` / `leakingBucketRateLimiter` / `slidingWindowRateLimiter` / `tokenBucketRateLimiter`。触发时服务端返回 `ERROR`，data 为 `ServerExceeding`。

一个诚实的提醒：**配了无法识别的限流器名称不会报错，会静默退化成不限流**。这是少数「配置错了但启动成功」的地方，上线前建议用压测确认限流真的生效。

### 健康检查是内置服务

```cj
@RPCStub
public interface HealthRPC {
    func health(): HealthData
}

@RPCSkeleton
public class HealthRPCImpl <: HealthRPC {
    public func health(): HealthData { HealthData() }
}
```

每个节点默认提供 `health()`，客户端可以直接远程调用探测。它同时也是 `@RPCStub` / `@RPCSkeleton` 的最小用法示例——想验证环境是否正常，跑这个比读文档快。

---

## 六、三个容易被低估的工程细节

### 1. `trace`：跨进程的调用链怎么串

```cj
@DataAssist[fields props]
public class RPCMessage {
    public mut prop meta: ServiceMeta
    public mut prop params: Array<DataAny>

    @DataExclude[prop]              // 不参与序列化
    public mut prop trace: String

    public static func currentTrace(): String
    public static func clearCurrentTrace(): Unit
}
```

`trace` 用 `ThreadLocal` 保存：客户端发起调用时生成，服务端收到后继承；**服务端再调用其它服务时自动带上同一个 trace**。于是跨进程的调用链有了一个共同的标识。

坑在清理。`ThreadLocal` 在同一线程处理下一个请求时会残留，所以：

- 服务端在请求结束时自动清理；
- 同时用 `f_mvc` 和 `f_rpc` 的项目，要用 `@WeavedController` 修饰 Controller 类，`ControllerTraceAspect` 才会生效：进入方法时取当前 trace，返回前清理并记一行 INFO。

**没有这个切面，第二个 HTTP 请求会继承第一个请求的 trace**——日志看起来「串了」，其实是线程复用的正常后果。

### 2. `rpc_currentSkeleton`：防止「调用自己」

服务端模块通常也依赖共享 API 包，而 API 包里的接口带着 `@RPCStub`。如果不做处理，服务端进程里也会注册一个存根 Bean；某个业务不小心 `lookup<UserService>()`，就调到了自己（或自己的邻居），本地实现被绕过。

解决办法是一行配置：

```bash
export rpc_currentSkeleton='^mycompany::order'   # 正则，匹配当前模块
```

匹配时，存根**不注册到 IOC**。这是一个非常轻的机制，但它避免了一类很难查的 bug：**行为看起来正常，只是偶尔走了网络**。

### 3. `BreakingCommand`：业务里的快速失败

服务端执行到一半发现条件不满足，不想抛异常（异常会被包装成堆栈文本），希望直接把一个值返回给客户端：

```cj
import fountain::f_data.BreakingCommand

perform BreakingCommand(toDataValue)
```

它会立即结束当前业务，`data` 原样返回给客户端。**`data` 必须能转换成 RPC 函数的返回类型**，否则客户端侧转换失败。

这相当于给业务开了一个「提前 return」的语法出口，比抛异常轻，也比构造完整的错误响应简单。

---

## 七、上线清单

**必须配的**

```bash
# 服务端
export rpcServer_port=1203
export rpcServer_baseAddresses=192.168.1.10:1203     # 种子节点，逗号分隔
export rpcServer_weight=1.0

# 客户端：格式 weight,address，多个用 | 分隔
export rpcClient_serverAddress='1.0,192.168.1.10:1203|2.0,192.168.1.11:1203'
export rpcClient_loadbalance=roundrobin
export rpcClient_retryCount=1
```

**容易踩的**

1. `rpcServer_port` **只接受端口号**（`UInt16`）。写成 `127.0.0.1:1204` 会解析失败并**静默回落到 1203**，两个节点就撞端口了。
2. 服务端工作目录的 `cjpm.toml` 必须有 `version=`，否则启动抛 `RPCVersionException`。
3. `@RPCStub` 只能实现接口**直接声明**的实例方法：不支持属性、不支持父接口方法、接口不能带泛型参数。
4. 参数类型要支持 `ToData`，返回类型要满足 `DataFields<R>`（加 `@DataAssist` 即可）。
5. `rpcClient_discoveryTimeout` 默认 5s，首次调用要等服务发现完成；超时报
   `no available client for <接口>.<方法>(version …) after …`——先确认服务端起没起、地址对不对、版本匹不匹配。
6. 调用全落在同一个节点：先看 `[FOUNTAIN_RPC.hosts]` 那行，确认注册表里两个节点都报了权重。

---

## 一句话收尾

`f_rpc` 的接口只有两个宏，但它把 80% 的力气花在了「调用之外」：**发现靠拉、匹配靠四份元数据、容错靠迭代语义、灰度靠版本第三位、排障靠 trace**。

**RPC 框架的成熟度，不看它调用有多快，看它出问题时你能不能一眼看出是哪个节点、哪个版本、哪条链路。**

---

**同系列**

- [编解码器与应用通讯协议](fountain实现思想与应用第10弹——编解码器与应用通讯协议.md)
- [数据库中间件](fountain实现思想与应用第12弹——数据库中间件.md)
- [消息队列](fountain实现思想与应用第13弹——消息队列.md)
- [JSONRPC & MCP](fountain实现思想与应用第14弹——JSONRPC&MCP.md)
