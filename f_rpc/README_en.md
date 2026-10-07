# f_rpc

Remote procedure call (RPC) module. See <https://gitcode.com/Cangjie-SIG/fountain/tree/master/frpcdemo> for usage.

`fountain::f_rpc` is built on `fountain::f_net` (the event-driven TCP network module) and `fountain::f_protocol` (the network communication
protocol) and provides:

- **Declarative RPC**: the server publishes services with the `@RPCSkeleton` macro, and the client generates remote call stubs with the `@RPCStub` macro
- **Service registration and discovery**: nodes complete service registration and discovery automatically through `REGISTER` / `SUBSCRIBE` commands, with no separate registry needed
- **DEREGISTER**: a node automatically sends a `DEREGISTER` command to the seed nodes when it exits
- **Service version numbers**: service version numbers (major.minor.patch) are supported, with both exact and wildcard versions
- **Version routing**: call targets are matched by service version number (major.minor), with both exact and wildcard versions
- **Load balancing**: built-in random and round robin strategies, choosing service nodes by weight
- **Rate limiting**: four rate limiting algorithms: any-moment, leaky bucket, sliding window and token bucket
- **Retry and fault tolerance**: a failed call automatically switches to another node to retry, and exceptions are aggregated and reported
- **IOC integration**: both service implementations and client stubs are registered with the BeanFactory of `fountain::f_bean`, so they can be used directly with `lookup`

## Module dependencies

`f_app` `f_aspect` `f_base` `f_bean` `f_codec` `f_collection` `f_concurrent` `f_config` `f_data` `f_health` `f_io` `f_log` `f_macros` `f_net` `f_process` `f_protocol` `f_store` `f_util`

## Package structure

| Package | Description |
| --- | --- |
| `fountain::f_rpc` | Root package (empty) |
| `fountain::f_rpc.base` | Basic types: `RPCMessage`, `ServiceMeta`, `RPCException`, the `rpc_codec*` pool configuration (`PoolConfig`), `ControllerTraceAspect`, logging helpers |
| `fountain::f_rpc.macros` | Macro package: `@RPCSkeleton`, `@RPCStub`, automatic type registration |
| `fountain::f_rpc.client` | Client: `RPCClient`, `ClientConfig`, `LogMessage` |
| `fountain::f_rpc.server` | Server: `RPCServer`, `ServerConfig`, `ServiceHub`, `RPCServerInitializer`, `RPCVersionException` |
| `fountain::f_rpc.health` | The built-in health check RPC interface: `HealthRPC` |
| `fountain::f_rpc.health.server` | The built-in health check service implementation: `HealthRPCImpl` |

## How it works

### Service registration and discovery

1. At startup a service node listens on the `rpcServer_port` port and sends `REGISTER` to each of `rpcServer_baseAddresses` (a comma-separated
   list of seed nodes):
   the payload is `"<port>,<weight>"` (`weight` comes from `rpcServer_weight`, and `@RPCSkeleton[weight=…]` overrides it);
   the registry uses the **IP of the TCP peer** plus this port as the address key (so a node does not need to know its own external address),
   and the weight as the value;
   a failed registration is retried at a fixed period and does not block startup.
2. The first time a client uses `RPCClient` it starts a **background discovery thread** (not a one-off action):
   - It connects to the configured nodes from `rpcClient_serverAddress` and uses `SUBSCRIBE(data: true)` to get the **full list of service nodes**
     (`Array<String>`, each item `"<ip>:<port>,<weight>"`)
   - It connects to each service node and uses `SUBSCRIBE(data: false)` to get the **list of service metadata** it provides (`Array<ServiceMeta>`)
   - It builds a connection pool with load balancing (`MultiClient`) for each service metadata, and prints one DEBUG line per service:
     `[FOUNTAIN_RPC.hosts] <interface>.<method> v=<version> -> N host(s): host(weight) …`
   - Afterwards it refreshes once every `rpcClient_refreshIntervalSeconds` (1s by default); when the set of nodes changes the corresponding
     connection pools are rebuilt; all connections are closed when the process exits
3. When a service node exits it sends `DEREGISTER` to the seed nodes (the payload is only the port)

### RPC call flow

1. The client calls a stub method → it builds a `ServiceMeta` (version, bean name, interface name, method name, argument type names) and an `RPCMessage` (the method arguments)
2. `RPCClient.call<R>` takes the connection pool from the service metadata and tries the service nodes one by one according to the load balancing strategy
3. The `RPCMessage` is sent with the `CONSUME` command; after decoding, the server's `ServiceHub` looks up the registered execution function and takes the service bean from the IOC container to complete the local call
4. The server returns the result with the `RESP` command and the client deserializes it into the declared type `R`; when the server execution throws, the exception stack text is returned with the `ERROR` command
5. A single node failure automatically moves on to the next node (bounded by `rpcClient_retryCount`); when all fail, an `RPCException` aggregating the exceptions of all nodes is thrown

### Metadata variants registered by the server

`ServiceHub.register` registers several `ServiceMeta` variants for each matching interface of the service implementation class, for the client to match flexibly:

| Variant | version | name (bean name) |
| --- | --- | --- |
| 1 | Project version (such as `1.0`) | Bean name |
| 2 | `*` (wildcard) | Bean name |
| 3 (when the bean name is non-empty) | Project version | Empty |
| 4 (when the bean name is non-empty) | `*` | Empty |

When registering interface metadata it automatically skips interfaces with the `std.` and `fountain::` prefixes and the common system interfaces
(`Equatable`, `Comparable`, `Iterable`, `Collection`, `Equal`, `NotEqual`, `Less`, `LessOrEqual`, `Greater`, `GreaterOrEqual`).

## Quick start

### 1. Define the shared interface and data types

Putting the interface and the data types in a separate shared API package is recommended; both the server and the client then depend on it, which
guarantees the fully qualified name of the interface is identical:

```cj
package demo.api

import fountain::f_data.macros.*
import fountain::f_rpc.client.*
import fountain::f_rpc.macros.*

// Data types transferred over RPC must be decorated with @DataAssist to support serialization
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

### 2. Server: implement and publish the service

```cj
package demo.service

import fountain::f_rpc.macros.*
import fountain::f_rpc.server.*
import demo.api.*

// @RPCSkeleton registers the public instance functions as RPC services and registers the class as an IOC Bean
@RPCSkeleton
public class UserServiceImpl <: UserService {
    public func getUser(id: Int64): User {
        User(id: id, name: 'tom')
    }
}
```

The server version number is extracted automatically from the `version=` field of the `cjpm.toml` in the working directory.

### 3. Client: generate the stub and call it

```cj
package demo.client

import fountain::f_bean.*
import fountain::f_rpc.macros.*
import demo.api.*

// version may be a literal version number, the name of a configuration item (read from Config), or '*'; the default is '*'
@RPCStub[version='1.0.0']
public interface UserService {
    func getUser(id: Int64): User
}

// Get the stub from the IOC container (its actual type is UserService_Stub__) and a remote call can be made
let userService = lookup<UserService>()
let user = userService.getUser(1)
```

### 4. Configuration

`fountain::f_config` does not depend on a configuration file; all configuration comes from **environment variables** and **command line arguments**
(a command line argument overrides an environment variable of the same name).

```bash
# Server (a seed node may omit rpcServer_baseAddresses)
export rpcServer_port=1203
# Number of server threads
export rpcServer_executors=200
# When registering with an existing cluster, configure the seed node addresses (comma separated)
export rpcServer_baseAddresses=192.168.1.10:1203
# Server weight, 1.0 by default
export rpcServer_weight=1.0

# Client: seed node address, in the form weight,address (weight is the weight; | separates several)
export rpcClient_serverAddress='1.0,192.168.1.10:1203|2.0,192.168.1.11:1203'
# Client: load balancing strategy (random, roundrobin), random by default
export rpcClient_loadbalance=roundrobin
# Client: number of retries, 0 by default
export rpcClient_retryCount=1
```

As command line arguments:

```bash
fboot --dylibPattern=<REGEX_FOR_LOADING_DYNAMIC_LIB_FILE> --rpcServer_port=1300 --rpcClient_retryCount=3
```

### 5. Starting the server

`RPCServerInitializer` implements the `Initializer` interface of `fountain::f_app` and registers itself with `InitializerCollection` when loaded
(name `fountain::f_rpc.server`, dependency `fountain::f_bean`). When the application is started with `fountain::f_app` / `fboot` it is scheduled
and executed automatically; its `start()` is a **blocking function** that starts the RPC server and registers the node with the seed nodes.

## Macro API

The macros are defined in `fountain::f_rpc.macros` (a macro package); `import fountain::f_rpc.macros.*` is needed before use.

### @RPCSkeleton — the server skeleton macro

```cj
public macro RPCSkeleton(input: Tokens): Tokens
// attr is optional and is used as the attribute of the macro @Bean during the second expansion
// attr also supports the weight attribute, which is 1.0 by default; weight may be an identifier denoting a configuration item or a concrete weight value
// attr eg. @RPCSkeleton[weight = 1.0] //Any other attributes are all taken as attributes of @Bean[...]
// The weight attribute of attr overrides the rpcServer_weight configuration
public macro RPCSkeleton(attr: Tokens, input: Tokens): Tokens
```

- It decorates a **service implementation class** (a class declaration), requiring every public non-static instance function of the class to be one RPC service method
- Expansion effect:
  1. It decorates the class with `@Bean[$attr]`, registering it with the IOC container (`attr` is used as the attribute of the `@Bean` macro of `fountain::f_bean` and may be omitted)
  2. It generates a static initialization block that calls `ServiceHub.register<Class name>(method name, argument type array){beanName, args => ...}` for every public instance function; at runtime the service instance is taken from the IOC container by bean name and the call is completed
- Expansion example (from the built-in `HealthRPCImpl`):

```cj
@RPCSkeleton
public class HealthRPCImpl <: HealthRPC {
    public func health(): HealthData {
        HealthData()
    }
}
// After expansion (excerpt):
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

### @RPCStub — the client stub macro

```cj
public macro RPCStub(input: Tokens): Tokens
public macro RPCStub(attr: Tokens, input: Tokens): Tokens
```

- It decorates an **interface** (an interface declaration) and generates a stub class `<interface name>_Stub__` implementing that interface
- The implementation of every method builds a `ServiceMeta` and an `RPCMessage` and calls `RPCClient.call<return type>(message)` to make the remote call
- It also generates a static initialization block that registers the stub class with the IOC container (it can be obtained with `lookup<<interface name>>()`)
- With the attributeless form `@RPCStub` the version number is `*` (matching any version)

**Attribute (attr) description:**

| Attribute | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | Yes (with the attribute form) | None; a compile error is reported if it is not given | Service version number. A literal version number (such as `'1.0.0'`) is used directly; an identifier starting with a letter (such as `'appVersion'`) is treated as a configuration item name and the value is read from `Config` |
| `name` | No | `''` | Bean name of the target service (corresponding to the name attribute of `@Bean`) |
| `exactlyVersion` | No | `false` | When `false` only the first two digits of version are kept (`1.2.3` → `1.2`); when `true` all digits are kept |

Attribute format: `@RPCStub[version='1.0.0' name=beanName exactlyVersion=true]`

Expansion example (from the built-in `HealthRPC`):

```cj
@RPCStub
public interface HealthRPC {
    func health(): HealthData
}
// After expansion (excerpt):
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

**The `rpc_currentSkeleton` anti-loop mechanism**: when the configuration item/environment variable `rpc_currentSkeleton` exists (its value is a
regular expression) and the current project matches that regular expression, the stub class is **not** registered with the IOC. This is used when a
server module also depends on the interface definition, to avoid that module mistakenly using a remote stub instead of the local implementation.
The value can be read through `ClientConfig.currentSkeleton`.

## Core API

### fountain::f_rpc.base

#### RPCException — the RPC exception

```cj
public class RPCException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

Thrown when a client call fails (retries exhausted, no available node, response type mismatch, ...); when several nodes fail, the exceptions of the
nodes are aggregated with `addSuppressed`.

#### RPCMessage — the RPC request message

```cj
@DataAssist[fields props]
public class RPCMessage {
    public mut prop meta: ServiceMeta        // Service metadata
    public mut prop params: Array<DataAny>   // Method arguments
    public init()
    public init(meta: ServiceMeta, params: Array<DataAny>)

    // When the server calls another service in turn, the trace it received from the client is inherited automatically
    @DataExclude[prop]                       // Not serialized
    public mut prop trace: String
    // When trace has no value, one is generated automatically from the static ThreadLocal of this class
    public static func currentTrace(): String
    // The developer decides when to clear the ThreadLocal; f_rpc provides automatic clearing on the server and an aspect for f_mvc
    // (fountain::f_mvc.macros.WeavedController, see the "ControllerTraceAspect" section)
    public static func clearCurrentTrace(): Unit
}
```

#### ServiceMeta — service metadata

```cj
@DataAssist[fields props hash equal]
public class ServiceMeta {
    public mut prop version: String              // Service version number
    public mut prop name: String                 // Bean name
    public mut prop typeName: String             // Fully qualified interface name
    public mut prop methodName: String           // Method name
    public mut prop argTypeNames: Array<String>  // Fully qualified parameter type names
    public mut prop weight: Float64              // Service weight (from @RPCSkeleton[weight=…], 1.0 by default)
    public init()
    public init(version: String, name: String, typeName: String,
        methodName: String, argTypeNames: Array<String>, weight!: Float64 = 1.0,
        exactlyVersion!: Bool = false)
    public init(version: String, name: String, typeName: TypeInfo,
        methodName: String, argTypeNames: Array<TypeInfo>, weight!: Float64 = 1.0,
        exactlyVersion!: Bool = false)
}
```

- When `exactlyVersion` is `false` (the default) only the first two digits of `version` are kept (`1.2.3` → `1.2`); when `true` all digits are kept;
- It implements `Hashable` / `Equatable`: **`weight` is excluded by `@DataExclude[equal hash]`**, so the fields taking part in equality/hashing are
  still the five fields version / name / typeName / methodName / argTypeNames;
- The weight the client uses to pick a node prefers `weight` (when it differs from 1.0 it was overridden by the skeleton weight); when it is 1.0
  (the default) the weight of that node in the registry is used instead.

#### Constants

```cj
public const UNSUPPORTED_COMMAND = 'UnsupportedCommand'  // Unsupported command (ERROR response data)
public const EXCEEDING = 'ServerExceeding'               // Server overloaded (ERROR response data)
```

### fountain::f_rpc.client

#### RPCClient — the RPC client

```cj
public class RPCClient {
    /**
     * Make one RPC call (usually called by the stub generated by @RPCStub, but it can also be used directly)
     * @param message RPC request message (service metadata + arguments)
     * @return The deserialized call result
     * @throws RPCException Retries exhausted / no available client / response data does not match type R
     */
    public static func call<R>(message: RPCMessage): R where R <: DataFields<R>
}
```

- The first access triggers static initialization, which completes service discovery and builds the connection pool of each service; when the
  process exits (`atExit`) all connections are closed automatically
- During a call the service nodes are traversed according to the load balancing strategy and a single node failure automatically moves on to the
  next one; all failure exceptions are aggregated into `RPCException.suppressed`
- The return type `R` must satisfy `DataFields<R>` (decorating it with `@DataAssist` is enough)

#### ClientConfig — the client configuration entry point

```cj
public class ClientConfig {
    /** The name of the current service module, from the configuration item rpc_currentSkeleton; returns an empty string when unset */
    public static prop currentSkeleton: String { get() }
}
```

All other configuration is read through the `Config` of `fountain::f_config` (see "Configuration reference").

#### LogMessage — the carrier of client call logs

```cj
@DataAssist[fields props]
public class LogMessage {
    public let message: RPCMessage      // Request message
    public var result: ?DataAny         // Call result
    public var consumed: Duration = Duration.Zero  // Call duration
    public init()
    public init(message: RPCMessage)
}
```

### fountain::f_rpc.server

#### ServiceHub — the service registry

```cj
public struct ServiceHub {
    /**
     * Register a service method (usually called by the code generated by @RPCSkeleton)
     * @param funcName Method name
     * @param argTypes List of parameter types
     * @param weight Weight, used for load balancing
     * @param fn The execution function: it takes the bean name and the argument array, takes the service instance from the IOC container,
     *        completes the call and returns the result
     */
    public static func register<T>(funcName: String, argTypes: Array<TypeInfo>, weight: Float64,
        fn: (String, Array<DataAny>) -> ToData): Unit where T <: Object
}
```

- The version number is extracted from the `version=` field of the `cjpm.toml` in the working directory; when missing, `RPCVersionException` is thrown
- Whether an exact version is used is controlled by the configuration item `rpcServer_exactlyVersion` (`false` by default, keeping only the first two digits)
- The bean name comes from the `name` attribute of the `@BeanMeta[name='nameOfBean']` annotation (an empty string when unnamed; the IOC has an
  internal default name but does not expose it, so by default it is not specified)

#### RPCServerInitializer — application startup integration

```cj
public struct RPCServerInitializer <: Initializer {
    public prop name: String { get() }            // 'fountain::f_rpc.server'
    public prop dependencies: Array<String> { get() }  // ['fountain::f_bean']
    public func initialize(): Unit               // Empty implementation
    /// Blocking start function: starts the RPC server and registers with the seed nodes; blocks forever after being called
    public func start(): Unit
}
```

#### RPCVersionException — the missing version exception

```cj
public class RPCVersionException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

Thrown when the `cjpm.toml` of the server has no `version=` field.

#### LogMessage / ErrorMessage — server log and error carriers

```cj
@DataAssist[props fields]
public class LogMessage {
    public let param: DataAny       // Request parameters
    public let result: DataAny      // Call result
    public let consumed: Duration   // Call duration
}

@DataAssist[props fields]
public class ErrorMessage {
    public let param: DataAny       // The request parameters that failed
    public let error: String        // Error information (server exception stack text, etc.)
    public init()
    public init(error: String)
}
```

### fountain::f_rpc.health / fountain::f_rpc.health.server — built-in health check

```cj
// fountain::f_rpc.health
@RPCStub
public interface HealthRPC {
    func health(): HealthData   // HealthData comes from fountain::f_health
}

// fountain::f_rpc.health.server
@RPCSkeleton
public class HealthRPCImpl <: HealthRPC {
    public func health(): HealthData { HealthData() }
}
```

Every service node provides the `health()` health check RPC service by default, and a client can call it remotely to probe the state of the node.
This is also the minimal usage example of `@RPCStub` / `@RPCSkeleton`.

## Configuration reference

All configuration is read through `fountain::f_config`, from environment variables or command line arguments (`--key=value`).

### Server configuration (prefix rpcServer)

| Configuration | Type | Default | Description |
| --- | --- | --- | --- |
| `rpcServer_port` | UInt16 | `1203` | Service listening port |
| `rpcServer_bufferQueueSize` | `Int64` | `1024` | Size of the data transfer task queue |
| `rpcServer_connectionCheckDuration` | `Int64` (milliseconds) | `1000` | TCP connection validity check period |
| `rpcServer_baseAddresses` | `Array<String>` (comma separated) | Empty | List of seed node addresses (such as `192.168.1.10:1203,192.168.1.11:1203`); the node registers itself with them after startup |
| `rpcServer_unavailableChecked` | `Int64` | `3` | Number of unavailability checks |
| `rpcServer_executors` | `Int64` | `200` | Server thread pool size |
| `rpcServer_weight` | `Float64` | `1.0` | Service weight |
| `rpcServer_exactlyVersion` | `Bool` | `false` | Whether to register the service with the full version number (`false` keeps only the first two digits) |
| `rpcServer_rateLimiterName` | `String` | None (no rate limiting) | Name of the rate limiter, see the table below |

### Client configuration (prefix rpcClient)

| Configuration | Type | Default | Description |
| --- | --- | --- | --- |
| `rpcClient_serverAddress` | `String` | None | Seed node address, in the form `weight,address`, with several addresses separated by `\|`, such as `'1.0,192.168.1.10:1203\|2.0,192.168.1.11:1203'` (weight is a `Float64`) |
| `rpcClient_loadbalance` | `String` | `random` | Load balancing algorithm: `random` / `roundrobin`; any other value throws `LoadBalanceException` |
| `rpcClient_queueSize` | `Int64` | `1024` | Size of the write data task queue (not passed to the builder when unset; the default comes from `f_net`) |
| `rpcClient_socketCount` | `Int64` | `1` | Number of connections per service node (as above) |
| `rpcClient_checkDuration` | `Duration` | `1s` | Connection validity check period (such as `1s`, `500ms`) |
| `rpcClient_bindToDevice` | `String` | None | Network card name to bind to |
| `rpcClient_socketKeepaliveConfig_count` | `UInt32` | None | keepalive probe count |
| `rpcClient_socketKeepaliveConfig_idle` | `Duration` | None | keepalive idle time |
| `rpcClient_socketKeepaliveConfig_interval` | `Duration` | None | keepalive probe interval |
| `rpcClient_linger` | `Duration` | None | SO_LINGER |
| `rpcClient_noDelay` | `Bool` | None | TCP_NODELAY |
| `rpcClient_acknowledge` | `Bool` | None | TCP_QUICKACK |
| `rpcClient_readTimeout` | `Duration` | None | Read timeout |
| `rpcClient_writeTimeout` | `Duration` | None | Write timeout |
| `rpcClient_receiveBufferSize` | `Int64` | None | SO_RCVBUF |
| `rpcClient_sendBufferSize` | `Int64` | None | SO_SNDBUF |
| `rpcClient_socketOptionBool` | `level,option,value` | None | Boolean socket option, such as `6,1,true` |
| `rpcClient_socketOptionInt` | `level,option,value` | None | Integer socket option, such as `6,2,128` |
| `rpcClient_pingTimeout` | `Duration` | None | ping timeout |
| `rpcClient_retryCount` | `Int64` | `0` | **Number of retries beyond the first attempt**: the total number of attempts is ≤ `retryCount + 1` (the first call is made even with the default 0); the test is `tried > retryCount` |
| `rpcClient_refreshIntervalSeconds` | `Int64` (seconds) | `1` | Refresh period of the background service discovery thread: it periodically SUBSCRIBEs again for the nodes and service metadata and rebuilds the connection pools when the set of nodes changes |
| `rpcClient_discoveryTimeout` | `Duration` | `5s` | Time limit for the first call to wait for service discovery to complete; on timeout it throws `RPCException("no available client for <interface>.<method>(version …) after …")` |
| `rpc_currentSkeleton` | `String` | None | Name of the current service module, used to prevent the stub from being registered with the IOC in a server module (see `@RPCStub`) |

### Rate limiter configuration

The rate limiting algorithm is chosen with `rpcServer_rateLimiterName`; its parameters are separate configuration items:
```bash
# eg.
export rpcServer_rateLimiterName=anyMomentRateLimiter
export rpcServer_maxTokens=1024
export rpcServer_timeout=100
```
| Rate limiter | Configuration (all with the `rpcServer_` prefix) | Default |
| --- | --- | --- |
| `anyMomentRateLimiter` | `maxTokens`, `timeout` | `1024`, `100` (milliseconds) |
| `leakingBucketRateLimiter` | `timeout`, `maxWaitings`, `leakingPerDuration`, `leakingDuration` | `1000ms`, `1024`, `1`, `50` (milliseconds) |
| `slidingWindowRateLimiter` | `window`, `limit`, `timeout` | `150ms`, `1024`, `100` (milliseconds) |
| `tokenBucketRateLimiter` | `tokens`, `timeout`, `populationPeriod` | `1024`, `100` (milliseconds), `150` (milliseconds) |

When `rpcServer_rateLimiterName` is unset, `UnlimitedRateLimiter` is used (no rate limiting); **an unrecognized name also silently degrades to it**
(no error is reported).
When rate limiting is triggered the server returns the `ERROR` command with the data `ServerExceeding`.

## Protocol commands

RPC is based on the `Command` enum of `fountain::f_protocol`:

| Command | Direction | Description |
| --- | --- | --- |
| `REGISTER` | Client → Server | A service node registers its address and port with the seed nodes; the server replies with `ACK` |
| `DEREGISTER` | Server → BaseServer | A service node deregisters its address and port from the seed nodes; the server replies with `ACK` |
| `SUBSCRIBE` | Client → Server | `data=true` returns all service nodes in the registry (`Array<String>`, each item `"<ip>:<port>,<weight>"`); `data=false` returns the list of service metadata provided by this node (`Array<ServiceMeta>`) |
| `CONSUME` | Client → Server | Initiates an RPC call; the data is an `RPCMessage` (`once: true`, QoS `AtMostOnce`) |
| `RESP` | Server → Client | Returns the call result or the subscription data |
| `ACK` | Both ways | Registration confirmation with no response body |
| `PING` | Client → Server | Connection validity check |
| `ERROR` | Both ways | Error response: unsupported command (`UnsupportedCommand`), server overloaded (`ServerExceeding`), or a service call exception (carrying the exception stack text) |

## Logging

The logger name is `rpc` (`LoggerFactory.getLogger('rpc')`), and its level can be adjusted with the logging configuration of `fountain::f_log`. Log content:

```text
[FOUNTAIN_RPC.{label}.{command}] {messageId}; {JSON}
```

- `label`: `Stub` (client call) or `Skeleton` (server execution); besides these there are the labels `subscribe.services`,
  `subscribe.hosts`, `hosts`, `register`, `register.newClient`, `deregister`, `pool` and so on, which carry **no messageId**
- A normal call is logged at INFO level (including the request message, the result and the `consumed` duration), registration/subscription is
  logged at DEBUG level, and exceptions are logged at ERROR level (with the exception stack)
- In every service discovery round the composition of the call pool is printed for each service; **this is the line to look at first when
  troubleshooting load balancing**:
  `[FOUNTAIN_RPC.hosts] <interface>.<method> v=<version> -> N host(s): host(weight) …`

## Version matching rules

| Side | Source of the version | Truncation rule |
| --- | --- | --- |
| Server | The `version=` field of the `cjpm.toml` in the working directory | `rpcServer_exactlyVersion=false` (the default) keeps the first two digits; `true` keeps all |
| Client (attribute form) | The `version` attribute of `@RPCStub` (a literal value or a configuration item defined by the client developer) | `exactlyVersion=false` (the default) keeps the first two digits; `true` keeps all; the default is `false`, and it may also be a configuration item defined by the client developer |
| Client (attributeless form) | The version is fixed to `*` (wildcard) | — |

Example: the client `@RPCStub[version='1.0.0']` actually looks up version `1.0` and can hit a server whose version is `1.0.x` (and which has not enabled exact versions).

## Failing fast
`import fountain::f_data.BreakingCommand`
During the execution of server business logic, executing perform BreakingCommand(toDataValue) ends the current business immediately, failing fast
data is the data returned to the client

## ControllerTraceAspect

For projects using both f_mvc and f_rpc: if an f_rpc service is called during one HTTP request, the thread-local trace must be cleared in time,
otherwise it is inherited by later requests on the same thread. The approach is to decorate the Controller class with
`fountain::f_mvc.macros.WeavedController`, which makes the `ControllerTraceAspect` of this module take effect: on entering a decorated method the
current trace is taken (`RPCMessage.currentTrace()`), and before the method returns `RPCMessage.clearCurrentTrace()` is called and
`ControllerTrace.proceed start: <trace> <class>.<method>(args)` is logged at INFO level. Other calling scenarios can follow that implementation.

The implementation is in `f_rpc/src/base/ControllerTraceAspect.cj` (the source code is authoritative; no code copies are embedded in this document).

## Notes and limitations

1. `@RPCStub` can only implement **instance member functions declared directly by the decorated interface**; it can neither implement properties nor implement functions of parent interfaces
2. An interface decorated with `@RPCStub` must not take generic parameters, otherwise compilation fails
3. RPC method argument types must support `ToData` serialization, and the return type must satisfy `DataFields<R>` (decorating it with `@DataAssist` is enough)
4. The `cjpm.toml` of the server working directory must contain a `version=` field, otherwise `RPCVersionException` is thrown at startup
5. `rpcClient_retryCount` is the "number of retries beyond the first attempt": the first call is made even with the default `0`, the test is
   `tried > retryCount`, and once exceeded an `RPCException("retry count exceeded")` is thrown (multiple node failures are aggregated with `addSuppressed`)
6. The interface definitions of the client and the server must match (the fully qualified interface name, the method name and the fully qualified
   argument type names all take part in matching); sharing an API package is recommended
7. A server call exception is not thrown to the client; instead the exception stack text is returned with the `ERROR` command (which the client
   sees as an `RPCException`)
8. When the skeleton uses `rpcServer_exactlyVersion=true`, a `a.b.c` version cannot serve a client that specifies version `a.b`.
   - A change in the third version digit indicates a non-breaking, compatible change where the implementation changed somewhat.
     - Registering with `rpcServer_exactlyVersion=true` can be used for grey or canary releases; after confirming there is no problem, if you do not
       want to upgrade the client version you can change `rpcServer_exactlyVersion` to `false` and change the client version to the form `a.b`. Or
       specify the `exactlyVersion` of `@RPCStub` as a configuration item and change the value of that configuration item to `false`.
   - A change in the first two version digits indicates a breaking, incompatible change.
9. A client may depend on RPC servers of different versions for different businesses, so the `exactlyVersion` and `version` attributes of
   `@RPCStub` need to be defined as configuration items by the client developer.
10. The client configuration item `rpc_currentSkeleton` is used to prevent the stub of the same module from being registered with the IOC.
