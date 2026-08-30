# f_rpc

远程过程调用（RPC）模块。

`fountain::f_rpc` 基于 `fountain::f_net`（事件驱动 TCP 网络模块）与 `fountain::f_protocol`（网络通讯协议）实现，提供：

- **声明式 RPC**：服务端用 `@RPCSkeleton` 宏一键发布服务，客户端用 `@RPCStub` 宏自动生成远程调用存根
- **服务注册与发现**：节点间通过 `REGISTER` / `SUBSCRIBE` 命令自动完成服务注册与发现，无需独立注册中心
- **DEREGISTER**: 节点退出时自动向种子节点发送 `DEREGISTER` 命令
- **服务版本号**：支持服务版本号（主版本.次版本.修订版本），支持精确版本与通配版本
- **版本路由**：按服务版本号（主版本.次版本）匹配调用目标，支持精确版本与通配版本
- **负载均衡**：内置随机（random）与轮询（roundrobin）策略，按权重选择服务节点
- **限流**：支持任意时刻、漏桶、滑动窗口、令牌桶四种限流算法
- **重试与容错**：调用失败自动切换节点重试，异常聚合上报
- **IOC 集成**：服务实现与客户端存根均注册到 `fountain::f_bean` 的 BeanFactory，可直接 `lookup` 使用

## 模块依赖

`f_app` `f_base` `f_bean` `f_codec` `f_collection` `f_concurrent` `f_config` `f_data` `f_health` `f_io` `f_log` `f_macros` `f_net` `f_process` `f_protocol` `f_store` `f_util`

## 包结构

| 包 | 说明 |
| --- | --- |
| `fountain::f_rpc` | 根包 |
| `fountain::f_rpc.base` | 基础类型：`RPCMessage`、`ServiceMeta`、`RPCException`、日志辅助 |
| `fountain::f_rpc.macros` | 宏包（macro package）：`@RPCSkeleton`、`@RPCStub` |
| `fountain::f_rpc.client` | 客户端：`RPCClient`、`ClientConfig` |
| `fountain::f_rpc.server` | 服务端：`ServiceHub`、`RPCServerInitializer`、`RPCVersionException` |
| `fountain::f_rpc.health` | 内置健康检查 RPC 接口：`HealthRPC` |
| `fountain::f_rpc.health.server` | 内置健康检查服务实现：`HealthRPCImpl` |

## 工作原理

### 服务注册与发现

1. 服务节点启动时监听 `rpcServer_port` 端口，并向 `rpcServer_baseAddresses` 配置的种子节点发送 `REGISTER` 命令（携带自身端口），将自己的地址加入种子节点维护的节点地址集合
2. 客户端首次使用 `RPCClient` 时（类静态初始化）：
   - 连接 `rpcClient_serverAddress` 配置的种子地址，发送 `SUBSCRIBE(data: true)` 获取**全部服务节点地址列表**
   - 逐个连接每个服务节点，发送 `SUBSCRIBE(data: false)` 获取该节点提供的**服务元数据列表**（`Array<ServiceMeta>`）
   - 为每个服务元数据建立一个带负载均衡的连接池（`MultiClient`）
   - 进程退出时自动关闭全部连接
3. 服务节点退出时向种子节点发送 `DEREGISTER` 命令

### RPC 调用流程

1. 客户端调用 Stub 方法 → 构造 `ServiceMeta`（版本、Bean 名、接口名、方法名、参数类型名）与 `RPCMessage`（方法参数）
2. `RPCClient.call<R>` 按服务元数据取出连接池，按负载均衡策略逐个尝试服务节点
3. 通过 `CONSUME` 命令发送 `RPCMessage`；服务端解码后由 `ServiceHub` 查找注册的执行函数，从 IOC 容器取出服务 Bean 完成本地调用
4. 服务端通过 `RESP` 命令返回结果，客户端反序列化为声明类型 `R`；服务端执行异常时通过 `ERROR` 命令返回异常堆栈文本
5. 单个节点失败自动换下一个节点重试（受 `rpcClient_retryCount` 限制），全部失败时抛出聚合了各节点异常的 `RPCException`

### 服务端注册的元数据变体

`ServiceHub.register` 会为服务实现类的每个匹配接口注册多个 `ServiceMeta` 变体，供客户端灵活匹配：

| 变体 | version | name（Bean 名） |
| --- | --- | --- |
| 1 | 项目版本（如 `1.0`） | Bean 名 |
| 2 | `*`（通配） | Bean 名 |
| 3（Bean 名非空时） | 项目版本 | 空 |
| 4（Bean 名非空时） | `*` | 空 |

注册接口元数据时会自动跳过 `std.`、`fountain::` 前缀接口及常用系统接口（`Equatable`、`Comparable`、`Iterable`、`Collection`、`Equal`、`NotEqual`、`Less`、`LessOrEqual`、`Greater`、`GreaterOrEqual`）。

## 快速开始

### 1. 定义共享接口与数据类型

建议将接口与数据类型放在独立的共享 API 包中，服务端与客户端同时依赖，保证接口完全限定名一致：

```cj
package demo.api

import fountain::f_data.macros.*
import fountain::f_rpc.client.*
import fountain::f_rpc.macros.*

// RPC 传输的数据类型需用 @DataAssist 修饰以支持序列化
@DataAssist[fields props]
public class User {
    public var id: Int64 = 0
    public var name: String = ''
    public init(){}
}

@RPCStub[version='1.0.0']
public interface UserService {
    func getUser(id: Int64): User
}
```

### 2. 服务端：实现并发布服务

```cj
package demo.service

import fountain::f_rpc.macros.*
import fountain::f_rpc.server.*
import demo.api.*

// @RPCSkeleton 将 public 实例函数注册为 RPC 服务，同时将类注册为 IOC Bean
@RPCSkeleton
public class UserServiceImpl <: UserService {
    public func getUser(id: Int64): User {
        User(id: id, name: 'tom')
    }
}
```

服务端版本号自动从工作目录 `cjpm.toml` 的 `version=` 字段提取。

### 3. 客户端：生成存根并调用

```cj
package demo.client

import fountain::f_bean.*
import fountain::f_rpc.macros.*
import demo.api.*

// version 可以是字面版本号，也可以是配置项名（从 Config 读取），也可以是'*'，默认是'*'
@RPCStub[version='1.0.0']
public interface UserService {
    func getUser(id: Int64): User
}

// 从 IOC 容器获取 Stub（实际类型为 UserService_Stub__），即可发起远程调用
let userService = lookup<UserService>()
let user = userService.getUser(1)
```

### 4. 配置

`fountain::f_config` 不依赖配置文件，所有配置来自**环境变量**和**命令行参数**（命令行参数覆盖同名环境变量）。

```bash
# 服务端（种子节点可不配置 rpcServer_baseAddresses）
export rpcServer_port=1203
# 服务端线程数
export rpcServer_executors=200
# 向已有集群注册时，配置种子节点地址（逗号分隔）
export rpcServer_baseAddresses=192.168.1.10:1203
# 服务端权重，默认值是1.0
export rpcServer_weight=1.0

# 客户端：种子节点地址，格式 weight,address（weight 为权重，| 分隔多个）
export rpcClient_serverAddress='1.0,192.168.1.10:1203|2.0,192.168.1.11:1203'
# 客户端：负载均衡策略（random、roundrobin）默认是 roundrobin
export rpcClient_loadbalance=roundrobin
# 客户端：重试次数，默认是0
export rpcClient_retryCount=1
```

命令行参数方式：

```bash
fboot --dylibPattern=<REGEX_FOR_LOADING_DYNAMIC_LIB_FILE> --rpcServer_port=1300 --rpcClient_retryCount=3
```

### 5. 启动服务端

`RPCServerInitializer` 实现了 `fountain::f_app` 的 `Initializer` 接口，加载时自动注册到 `InitializerCollection`（名称 `fountain::f_rpc.server`，依赖 `fountain::f_bean`）。使用 `fountain::f_app` / `fboot` 启动应用时会自动调度执行，其 `start()` 为**阻塞函数**，会启动 RPC 服务器并向种子节点注册自身。

## 宏 API

宏定义于 `fountain::f_rpc.macros`（macro package），使用前需 `import fountain::f_rpc.macros.*`。

### @RPCSkeleton — 服务端骨架宏

```cj
public macro RPCSkeleton(input: Tokens): Tokens
// attr 可选，用于作为二次展开的宏 @Bean 的属性
// attr 还支持权重属性weight，默认是1.0，weight支持标识符表示的配置项或者具体权重值
// attr eg. @RPCSkeleton[weight = 1.0] //如果还有其他属性，一律作为@Bean[...]的属性
// attr 的weight属性会覆盖rpcServer_weight的配置
public macro RPCSkeleton(attr: Tokens, input: Tokens): Tokens
```

- 修饰**服务实现类**（class 声明），要求类中每个 public 非 static 实例函数即一个 RPC 服务方法
- 展开效果：
  1. 以 `@Bean[$attr]` 修饰该类，将其注册到 IOC 容器（`attr` 作为 `fountain::f_bean` 的 `@Bean` 宏属性，可省略）
  2. 生成静态初始化块，对每个 public 实例函数调用 `ServiceHub.register<类名>(方法名, 参数类型数组){beanName, args => ...}`，运行时按 Bean 名从 IOC 容器取出服务实例完成调用
- 展开示例（来自内置 `HealthRPCImpl`）：

```cj
@RPCSkeleton
public class HealthRPCImpl <: HealthRPC {
    public func health(): HealthData {
        HealthData()
    }
}
// 展开后（节选）：
// @Bean[]
// public class HealthRPCImpl <: HealthRPC { ... }
// private let _ = {=> BeanFactory.instance.register<HealthRPCImpl>{HealthRPCImpl()} }()
// private let _ = {=>
//     ServiceHub.register<HealthRPCImpl>("health", []) {beanName, args =>
//         if(beanName.isEmpty()){ lookup<HealthRPCImpl>() }
//         else{ lookup<HealthRPCImpl>(beanName) }.health()
//     }
// }()
```

### @RPCStub — 客户端存根宏

```cj
public macro RPCStub(input: Tokens): Tokens
public macro RPCStub(attr: Tokens, input: Tokens): Tokens
```

- 修饰**接口**（interface 声明），生成实现该接口的存根类 `接口名_Stub__`
- 每个方法的实现：构造 `ServiceMeta` 与 `RPCMessage`，调用 `RPCClient.call<返回类型>(message)` 发起远程调用
- 同时生成静态初始化块，将存根类注册到 IOC 容器（可通过 `lookup<接口名>()` 获取）
- 无属性形式 `@RPCStub` 时版本号为 `*`（通配任意版本）

**属性（attr）说明：**

| 属性 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `version` | 是（使用属性形式时） | 无，不指定报编译错误 | 服务版本号。若为字面版本号（如 `'1.0.0'`）直接使用；若为字母开头的标识符（如 `'appVersion'`）则视为配置项名，从 `Config` 读取对应值 |
| `name` | 否 | `''` | 目标服务的 Bean 名（对应 `@Bean` 的名称属性） |
| `exactlyVersion` | 否 | `false` | `false` 时只保留 version 前两位数字（`1.2.3` → `1.2`）；`true` 时保留全部版本数字 |

属性格式：`@RPCStub[version='1.0.0' name=beanName exactlyVersion=true]`

展开示例（来自内置 `HealthRPC`）：

```cj
@RPCStub
public interface HealthRPC {
    func health(): HealthData
}
// 展开后（节选）：
// public interface HealthRPC { func health(): HealthData }
// public class HealthRPC_Stub__ <: HealthRPC {
//     public func health(): HealthData {
//         let version = "*"
//         let name = ""
//         let typeName = TypeInfo.of<HealthRPC>().qualifiedName
//         let methodName = "health"
//         let argTypeNames: Array<String> = []
//         let meta = ServiceMeta(version, name, typeName, methodName, argTypeNames, exactlyVersion: false)
//         let args: Array<DataAny> = []
//         let message = RPCMessage(meta, args)
//         RPCClient.call<HealthData>(message)
//     }
// }
```

**`rpc_currentSkeleton` 防回环机制**：当存在配置项/环境变量 `rpc_currentSkeleton`，且其值与当前项目名称一致、或与被 `@RPCStub` 修饰的接口具有相同包名时，存根类**不会**注册到 IOC。用于服务端模块同时依赖接口定义时，避免本模块误用远程存根替代本地实现。可通过 `ClientConfig.currentSkeleton` 读取该值。

## 核心 API

### fountain::f_rpc.base

#### RPCException — RPC 异常

```cj
public class RPCException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

客户端调用失败（重试耗尽、无可用节点、响应类型不符等）时抛出，多节点失败时各节点异常通过 `addSuppressed` 聚合。

#### RPCMessage — RPC 请求消息

```cj
@DataAssist[fields props]
public class RPCMessage {
    public mut prop meta: ServiceMeta        // 服务元数据
    public mut prop params: Array<DataAny>   // 方法实参
    public init()
    public init(meta: ServiceMeta, params: Array<DataAny>)
}
```

#### ServiceMeta — 服务元数据

```cj
@DataAssist[fields props hash equal]
public class ServiceMeta {
    public mut prop version: String              // 服务版本号
    public mut prop name: String                 // Bean 名
    public mut prop typeName: String             // 接口完全限定名
    public mut prop methodName: String           // 方法名
    public mut prop argTypeNames: Array<String>  // 形参类型完全限定名
    public init()
    public init(version: String, name: String, typeName: String,
        methodName: String, argTypeNames: Array<String>, exactlyVersion!: Bool = false)
    public init(version: String, name: String, typeName: TypeInfo,
        methodName: String, argTypeNames: Array<TypeInfo>, exactlyVersion!: Bool = false)
    
    //服务端再次调用其它服务时会自动继承当前服务从客户端接收到的trace
    public mut prop trace: String
    //属性trace如果没有trace值会调用currentTrace()获得一个
    //本类维持一个静态ThreadLocal成员变量，currentTrace()会从这个静态变量获得追踪标志，如果静态变量无值会自动创建一个
    public static func currentTrace(): String
    //由开发者决定何时清除ThreadLocal，f_rpc提供了针对f_mvc的切面，
    //只要使用fountain::f_mvc.macros.WeavedController修饰controller类这个切面即可生效
    //f_rpc的服务端会在服务结束前自动调用clearCurrentTrace()
    public static func clearCurrentTrace(): Unit
}
```

- `exactlyVersion` 为 `false`（默认）时只保留 `version` 前两位数字（`1.2.3` → `1.2`），`true` 时保留全部
- 实现 `Hashable` / `Equatable`，五个字段全部相等才视为同一服务

#### 常量

```cj
public const UNSUPPORTED_COMMAND = 'UnsupportedCommand'  // 不支持的命令（ERROR 响应 data）
public const EXCEEDING = 'ServerExceeding'               // 服务器超载（ERROR 响应 data）
```

### fountain::f_rpc.client

#### RPCClient — RPC 客户端

```cj
public class RPCClient {
    /**
     * 发起一次 RPC 调用（通常由 @RPCStub 生成的存根调用，也可直接使用）
     * @param message RPC 请求消息（服务元数据 + 实参）
     * @return 反序列化后的调用结果
     * @throws RPCException 重试次数耗尽 / 无可用客户端 / 响应数据与 R 类型不符
     */
    public static func call<R>(message: RPCMessage): R where R <: DataFields<R>
}
```

- 首次访问触发静态初始化，完成服务发现并建立各服务的连接池；进程退出时（`atExit`）自动关闭全部连接
- 调用时按负载均衡策略遍历服务节点，单个节点失败自动尝试下一个；所有失败异常聚合进 `RPCException.suppressed`
- 返回类型 `R` 需满足 `DataFields<R>`（用 `@DataAssist` 修饰即可）

#### ClientConfig — 客户端配置入口

```cj
public class ClientConfig {
    /** 当前服务模块名，来自配置项 rpc_currentSkeleton，未配置返回空串 */
    public static prop currentSkeleton: String { get() }
}
```

其余配置均通过 `fountain::f_config` 的 `Config` 读取（见「配置项参考」）。

#### LogMessage — 客户端调用日志载体

```cj
@DataAssist[fields props]
public class LogMessage {
    public let message: RPCMessage      // 请求消息
    public var result: ?DataAny         // 调用结果
    public var consumed: Duration = Duration.Zero  // 调用耗时
    public init()
    public init(message: RPCMessage)
}
```

### fountain::f_rpc.server

#### ServiceHub — 服务注册中心

```cj
public struct ServiceHub {
    /**
     * 注册服务方法（通常由 @RPCSkeleton 生成的代码调用）
     * @param funcName 方法名
     * @param argTypes 形参类型列表
     * @param weight 权重，用于负载均衡
     * @param fn 执行函数：入参为 Bean 名与实参数组，从 IOC 容器取出服务实例后完成调用并返回结果
     */
    public static func register<T>(funcName: String, argTypes: Array<TypeInfo>, weight: Float64,
        fn: (String, Array<DataAny>) -> ToData): Unit where T <: Object
}
```

- 版本号从工作目录 `cjpm.toml` 的 `version=` 字段提取，缺失时抛 `RPCVersionException`
- 是否使用精确版本由配置项 `rpcServer_exactlyVersion` 控制（默认 `false`，只保留前两位）
- Bean 名取自 `@BeanMeta[name='nameOfBean']` 注解的 `name` (属性，未命名则为空串，IOC有内部默认名但是不会对外公开，默认不指定)

#### RPCServerInitializer — 应用启动集成

```cj
public struct RPCServerInitializer <: Initializer {
    public prop name: String { get() }            // 'fountain::f_rpc.server'
    public prop dependencies: Array<String> { get() }  // ['fountain::f_bean']
    public func initialize(): Unit               // 空实现
    /// 阻塞启动函数：启动 RPC 服务器并向种子节点注册，调用后一直阻塞
    public func start(): Unit
}
```

#### RPCVersionException — 版本缺失异常

```cj
public class RPCVersionException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

服务端 `cjpm.toml` 中无 `version=` 字段时抛出。

#### LogMessage / ErrorMessage — 服务端日志与错误载体

```cj
@DataAssist[props fields]
public class LogMessage {
    public let param: DataAny       // 请求参数
    public let result: DataAny      // 调用结果
    public let consumed: Duration   // 调用耗时
}

@DataAssist[props fields]
public class ErrorMessage {
    public let param: DataAny       // 出错的请求参数
    public let error: String        // 错误信息（服务端异常堆栈文本等）
    public init()
    public init(error: String)
}
```

### fountain::f_rpc.health / fountain::f_rpc.health.server — 内置健康检查

```cj
// fountain::f_rpc.health
@RPCStub
public interface HealthRPC {
    func health(): HealthData   // HealthData 来自 fountain::f_health
}

// fountain::f_rpc.health.server
@RPCSkeleton
public class HealthRPCImpl <: HealthRPC {
    public func health(): HealthData { HealthData() }
}
```

每个服务节点默认提供 `health()` 健康检查 RPC 服务，客户端可远程调用它探测节点状态。这也是 `@RPCStub` / `@RPCSkeleton` 最小用法示例。

## 配置项参考

所有配置项通过 `fountain::f_config` 读取，来源为环境变量或命令行参数（`--key=value`）。

### 服务端配置（前缀 rpcServer）

| 配置项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `rpcServer_port` | UInt16 | `1203` | 服务监听端口 |
| `rpcServer_bufferQueueSize` | `Int64` | `1000000` | 数据传输任务队列大小 |
| `rpcServer_connectionCheckDuration` | `Int64`（毫秒） | `1000` | TCP 连接有效性检查周期 |
| `rpcServer_baseAddresses` | `Array<String>`（逗号分隔） | 空 | 种子节点地址列表（如 `192.168.1.10:1203,192.168.1.11:1203`），启动后向这些节点注册自身 |
| `rpcServer_unavailableChecked` | `Int64` | `3` | 不可用检查次数 |
| `rpcServer_executors` | `Int64` | `200` | 服务端线程池大小 |
| `rpcServer_weight` | `Float64` | `1.0` | 服务权重 |
| `rpcServer_exactlyVersion` | `Bool` | `false` | 是否以完整版本号注册服务（`false` 只保留前两位） |
| `rpcServer_rateLimiterName` | `String` | 无（不限流） | 限流器名称，见下表 |

### 客户端配置（前缀 rpcClient）

| 配置项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `rpcClient_serverAddress` | `String` | 无 | 种子节点地址，格式 `weight,address`，多个地址用 `\|` 分隔，如 `'1.0,192.168.1.10:1203\|2.0,192.168.1.11:1203'`（weight 为 `Float64` 权重） |
| `rpcClient_loadbalance` | `String` | `random` | 负载均衡算法：`random`（随机）/ `roundrobin`（轮询），其它值抛 `LoadBalanceException` |
| `rpcClient_queueSize` | `Int64` | `1024` | 写数据任务队列大小 |
| `rpcClient_socketCount` | `Int64` | `1` | 每个服务节点的连接数 |
| `rpcClient_checkDuration` | `Duration` | `1s` | 连接有效性检查周期（如 `1s`、`500ms`） |
| `rpcClient_bindToDevice` | `String` | 无 | 绑定网卡名 |
| `rpcClient_socketKeepaliveConfig_count` | `UInt32` | 无 | keepalive 探测计数 |
| `rpcClient_socketKeepaliveConfig_idle` | `Duration` | 无 | keepalive 空闲时间 |
| `rpcClient_socketKeepaliveConfig_interval` | `Duration` | 无 | keepalive 探测间隔 |
| `rpcClient_linger` | `Duration` | 无 | SO_LINGER |
| `rpcClient_noDelay` | `Bool` | 无 | TCP_NODELAY |
| `rpcClient_acknowledge` | `Bool` | 无 | TCP_QUICKACK |
| `rpcClient_readTimeout` | `Duration` | 无 | 读超时 |
| `rpcClient_writeTimeout` | `Duration` | 无 | 写超时 |
| `rpcClient_receiveBufferSize` | `Int64` | 无 | SO_RCVBUF |
| `rpcClient_sendBufferSize` | `Int64` | 无 | SO_SNDBUF |
| `rpcClient_socketOptionBool` | `level,option,value` | 无 | 布尔型套接字选项，如 `6,1,true` |
| `rpcClient_socketOptionInt` | `level,option,value` | 无 | 整型套接字选项，如 `6,2,128` |
| `rpcClient_pingTimeout` | `Duration` | 无 | ping 超时 |
| `rpcClient_retryCount` | `Int64` | `0` | 单次调用最大尝试次数（每次尝试前检查已尝试次数是否达到上限，**需配置为不小于 1 才能发起调用**） |
| `_refreshIntervalSeconds` | `Duration` | `1` | 刷新服务端连接的周期，单位是秒，定时从种子节点获取服务端节点，并获得每个节点提供的RPC服务元数据 |
| `rpc_currentSkeleton` | `String` | 无 | 当前服务模块名，用于阻止存根在服务端模块注册到 IOC（见 `@RPCStub`） |

### 限流器配置

通过 `rpcServer_rateLimiterName` 选择限流算法，参数均为独立配置项：
```bash
# eg.
export rpcServer_rateLimiterName=anyMomentRateLimiter
export rpcServer_maxTokens=1024
export rpcServer_timeout=100
```
| 限流器 | 配置项（均带 `rpcServer_` 前缀） | 默认值 |
| --- | --- | --- |
| `anyMomentRateLimiter` | `maxTokens`、`timeout` | `1024`、`100`(单位毫秒) |
| `leakingBucketRateLimiter` | `timeout`、`maxWaitings`、`leakingPerDuration`、`leakingDuration` | `1000ms`、`1024`、`1`、`50`（单位毫秒） |
| `slidingWindowRateLimiter` | `window`、`limit`、`timeout` | `150ms`、`1024`、`100`（单位毫秒） |
| `tokenBucketRateLimiter` | `tokens`、`timeout`、`populationPeriod` | `1024`、`100`（单位毫秒）、`150`（单位毫秒） |

未配置 `rpcServer_rateLimiterName` 时使用 `UnlimitedRateLimiter`（不限流）。限流触发时服务端返回 `ERROR` 命令，data 为 `ServerExceeding`。

## 协议命令

RPC 基于 `fountain::f_protocol` 的 `Command` 枚举：

| 命令 | 方向 | 说明 |
| --- | --- | --- |
| `REGISTER` | Client → Server | 服务节点向种子节点注册自身地址与端口，服务端回复 `ACK` |
| `DEREGISTER` | Server → BaseServer | 服务节点向种子节点注销自身地址与端口，服务端回复 `ACK` |
| `SUBSCRIBE` | Client → Server | `data=true` 返回全部服务节点地址列表（`Array<String>`）；`data=false` 返回本节点提供的服务元数据列表（`Array<ServiceMeta>`） |
| `CONSUME` | Client → Server | 发起 RPC 调用，data 为 `RPCMessage`（`once: true`，QoS 为 `AtMostOnce`） |
| `RESP` | Server → Client | 返回调用结果或订阅数据 |
| `ACK` | 双向 | 注册确认，无响应体 |
| `PING` | Client → Server | 连接有效性检查 |
| `ERROR` | 双向 | 错误响应：不支持的命令（`UnsupportedCommand`）、服务器超载（`ServerExceeding`）、服务调用异常（携带异常堆栈文本） |

## 日志

日志器名称为 `rpc`（`LoggerFactory.getLogger('rpc')`），可通过 `fountain::f_log` 的日志配置调整级别。日志内容：

```text
[FOUNTAIN_RPC.{label}.{command}] {messageId}; {JSON}
```

- `label`：`Stub`（客户端）或 `Skeleton`（服务端）
- 正常调用以 INFO 级别记录（含请求消息、结果、耗时 `consumed`），注册/订阅以 DEBUG 级别记录，异常以 ERROR 级别记录（附异常堆栈）

## 版本匹配规则

| 端 | 版本来源 | 截断规则 |
| --- | --- | --- |
| 服务端 | 工作目录 `cjpm.toml` 的 `version=` 字段 | `rpcServer_exactlyVersion=false`（默认）保留前两位；`true` 保留全部 |
| 客户端（属性形式） | `@RPCStub` 的 `version` 属性（字面值或客户端开发者自定义配置项） | `exactlyVersion=false`（默认）保留前两位；`true` 保留全部，默认是`false`，也可以是客户端开发者自定义配置项|
| 客户端（无属性形式） | 版本固定为 `*`（通配） | — |

示例：客户端 `@RPCStub[version='1.0.0']` 实际查找版本 `1.0`，可命中版本为 `1.0.x`（且未开启精确版本）的服务端。

## 快速失败
`import fountain::f_data.BreakingCommand`
服务端业执行过程中执行perform BreakingCommand(toDataValue)立即结束当前业务，快速失败
data是返回给客户端的数据

## ControllerTraceAspect
对于同时使用f_mvc和f_rpc的项目，一次http访问需要依赖f_rpc服务，为了及时清除trace，应当使用`fountain::f_mvc.macros.WeavedController`宏修饰Controller类。
如此本模块的ControllerTraceAspect就会生效。Controller函数返回前会清除ServiceMeta的trace。
其他客户端场景可参考此类
```cj
import fountain::f_aspect.*
import fountain::f_bean.{BeanFactory, BeanMeta}
import fountain::f_log.LoggerFactory

@AspectRoute[FuncAnnotationRouteRule("fountain::f_mvc.PostMapping") | FuncAnnotationRouteRule("fountain::f_mvc.PutMapping") | FuncAnnotationRouteRule("fountain::f_mvc.GetMapping") | FuncAnnotationRouteRule("fountain::f_mvc.DeleteMapping") | FuncAnnotationRouteRule("fountain::f_mvc.PatchMapping")]
@BeanMeta
public class ControllerTraceAspect <: Aspect {
    private static let log = LoggerFactory.getLogger<ControllerTraceAspect>()
    static init(){
        BeanFactory.instance.register<ControllerTraceAspect>({=> ControllerTraceAspect()})
    }

    private init(){}

    public func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        log.debug('ControllerTraceAspect.proceed start')
        try{
            point(funcInfo.args)
        }finally{
            ServiceMeta.clearCurrentTrace()
            log.debug('ControllerTraceAspect.proceed end')
        }
    }
}
```

## 注意事项与限制

1. `@RPCStub` 只能实现**被修饰接口直接声明的实例成员函数**，不能实现属性，也不能实现父接口的函数
2. 被 `@RPCStub` 修饰的接口不能带泛型参数，否则编译报错
3. RPC 方法参数类型需支持 `ToData` 序列化、返回类型需满足 `DataFields<R>`（用 `@DataAssist` 修饰即可）
4. 服务端工作目录的 `cjpm.toml` 必须包含 `version=` 字段，否则启动时抛 `RPCVersionException`
5. `rpcClient_retryCount` 默认为 `0`，且每次尝试前检查已达上限即抛出 `RPCException("retry count exceeded")`，使用时需配置为不小于 `1`
6. 客户端与服务端的接口定义需保持一致（接口完全限定名、方法名、参数类型完全限定名均参与匹配），推荐共享 API 包
7. 服务端调用异常不会抛给客户端，而是通过 `ERROR` 命令返回异常堆栈文本（客户端表现为 `RPCException`）
8. skeleton `rpcServer_exactlyVersion=true`时，`a.b.c`版本不能服务指定版本是`a.b`的客户端访问。
   - 第三位版本号变化表示没有破坏性的不兼容的变更，但是实现有所变化。
     - 注册为`rpcServer_exactlyVersion=true`，可以用于灰度发布或金丝雀发布，确认没有问题以后如果不希望升级客户端版本，可以把`rpcServer_exactlyVersion`改为`false`，同时客户端版本改为`a.b`的形式。或者把`@RPCStub`的exactlyVersion指定为一个配置项，并把配置项的值改为`false`。
   - 前两位版本号变化表示发生了破坏性、不兼容变更。
9. 客户端可能依赖不同业务不同版本的RPC服务端，所以`@RPCStub`的`exactlyVersion`和`version`的属性需要客户端开发者自己定义配置项。
10. 客户端配置项`rpc_currentSkeleton`用于阻止同模块的Stub注册到IOC。