# fleet — 分布式键值同步系统

去中心化的键值同步系统，各节点绝对平等，通过一致性哈希分片存储数据，通过互相同步实现数据最终一致性。

---

## 服务端 (Server)

### 配置项

通过 `fountain::f_config.Config` 读取，支持环境变量和命令行参数（`--key=value`）。

| 配置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `fleet_hosts` | `String` | **必填** | 集群节点列表，逗号分隔，格式 `host1:port1,host2:port2` |
| `fleet_dataPath` | `String` | `/tmp/fleet` | 数据存储目录 |

> **重要**：所有节点的 `fleet_hosts` 配置必须完全一致（host、端口、顺序、数量都必须相同），否则启动后自动检测到不一致会退出进程。

### 启动方式

```bash
# 单节点启动
fboot fleet --fleet_hosts=127.0.0.1:1203

# 多节点集群（各节点使用完全相同的 fleet_hosts）
# 节点 0（自动匹配到 fleet_hosts 第一个位置，绑定 1203 端口）
fboot fleet --fleet_hosts=10.0.0.1:1203,10.0.0.2:1204 --fleet_dataPath=/data/fleet

# 节点 1（主机名匹配到 fleet_hosts 第二个位置，绑定 1204 端口）
fboot fleet --fleet_hosts=10.0.0.1:1203,10.0.0.2:1204 --fleet_dataPath=/data/fleet
```

本地节点索引由 `fleet_hosts` 列表中 host 与本地主机名或回环地址（`127.0.0.1`、`localhost`）的匹配位置决定。

### 启动流程

1. `static init()` 自动注册到 `SubCommandMediator`（子命令名 `fleet`）
2. `exec()` 读取配置 → 初始化 `Store` / `NodeManager` / `WatchManager` / `SyncHandler` / `SyncServer`
3. 后台线程启动 TCP 服务，绑定端口取自节点列表中本地节点端口
4. 后台线程启动后，连接各对端节点进行**配置一致性校验**：
   - 读取对端 `__config__` 元键获取其 `fleet_hosts` 配置
   - 与本地的 `fleet_hosts` 比较（必须完全一致）
   - 不一致则输出错误信息、退出进程
5. 主线程阻塞等待

### 元键

| 键 | 用途 |
|----|------|
| `__config__` | GET 该键返回本节点的 `host1:port1,host2:port2,...` 配置字符串 |

---

## 客户端 (Client)

### 使用方式

客户端通过单例模式获取全局唯一实例，自动连接 `fleet_hosts` 配置的第一个节点：

```cj
let client = SyncClient.getInstance(requestTimeout: Duration.second * 5)
```

> `getInstance()` 第一次调用时连接 `fleet_hosts` 第一个节点并缓存实例，后续调用返回同一实例。

### 公共 API

```cj
// 获取全局唯一的 SyncClient 实例
// requestTimeout: 请求超时时间（默认 10s）
public static func getInstance(requestTimeout!: Duration = Duration.second * 10): SyncClient

// 写入键值对（发送到 Owner 节点）
// key: 必须为绝对路径形式（以 / 开头），如 /app/config/db/host
// value: 任意 DataFields 类型
// 写入失败时抛出 WriteFailedException(key)
public func add<T>(key: String, value: T): Unit where T <: DataFields<T>

// 读取键值对并解码为指定类型
// key 不存在时返回 None
public func get<T>(key: String): ?T where T <: DataFields<T>

// 读取键值对的原始字节（不经过 DataFields 解码）
public func getBytes(key: String): ?Array<Byte>

// 删除键值对
// key 不存在时不报错，静默返回
public func delete(key: String): Unit

// 前缀扫描：返回所有 key 以 pattern 开头的条目
// 服务端使用 store.prefix() 高效范围迭代
public func prefix(pattern: String): ScanResult

// 通配符扫描：支持 *（任意字符）**（跨级）?（单字符）通配符
// 服务端使用 PathPattern 做 Trie 匹配过滤
public func glob(pattern: String): ScanResult

// 监听指定 KEY 的变更，阻塞直到值变化或超时
// timeout=Duration.Zero 永不超时，阻塞等待变化返回 Some(newValue)
// timeout>0 超时返回 None
public func watch<T>(key: String, timeout!: Duration = Duration.Zero): ?T where T <: DataFields<T>

// 取消 Watch，当前阻塞的 watch 调用返回 None
public func unwatch(key: String): Unit
```

> **key 校验**：所有公有方法内调用 `requireAbsolutePath(key)`，非 `/` 开头的 key 抛出 `InvalidKeyException`。

### ScanResult

```cj
public prop size: Int64                       // 条目数
public func getKey(index: Int64): ?String     // 第 index 个 key
public func getValue(index: Int64): ?Array<Byte>  // 第 index 个值的原始字节
public func decode<T>(index: Int64): ?(String, T) where T <: DataFields<T>  // 解码第 index 个值
```

### 异常类

| 异常 | 继承 | 触发条件 |
|------|------|----------|
| `InvalidKeyException` | `BaseException` | key 不是绝对路径（不以 `/` 开头） |
| `WriteFailedException` | `BaseException` | add/delete 网络请求失败或超时 |

### 通信协议

| API | 命令 | 请求体 | 响应体 |
|-----|------|--------|--------|
| `add<T>` | `REGISTER` | `SyncData(key, 0, encode(value))` | `RESP`（异步由 MessageID 匹配） |
| `delete` | `DEREGISTER` | `KeyData(key)` | `RESP` |
| `getBytes` / `get<T>` | `ACK` + `KeyData` | `KeyData(key)` | `RESP` + `ValueData(?Array<Byte>)` |
| `prefix` | `ACK` + `PatternData` | `PatternData(pattern)` | `RESP` + `ValueData(blob)` → `ScanResult.decodeFromBytes` |
| `glob` | `ACK` + `PatternData` | `PatternData(pattern)` | `RESP` + `ValueData(blob)` → `ScanResult.decodeFromBytes` |
| `watch<T>` | `SUBSCRIBE` | `WatchData(key, timeout)` | `RESP` + `ValueData(?Array<Byte>)`（阻塞等待变化） |
| `unwatch` | `UNSUBSCRIBE` | `KeyData(key)` | `RESP` |

> prefix/glob 的响应体经过 `ScanResult.encodeToBytes()` 编码为 `Array<Byte>` blob，通过 `ValueData` 传输，客户端用 `ScanResult.decodeFromBytes()` 重构。此方式绕过了 `@DataAssist` 对 `ArrayList<Array<Byte>>` 的 roundtrip 限制。

### 数据体类型

定义在 `fountain::fleet.base` 包：

| 类型 | 字段 | 用途 |
|------|------|------|
| `SyncData` | key, version, value: Array<Byte> | REGISTER / PUBLISH 请求体 |
| `KeyData` | key: String | DEREGISTER / GET / UNSUBSCRIBE 请求体 |
| `ValueData` | value: ?Array<Byte> | GET 响应体（None 表示不存在/已删除） |
| `WatchData` | key, timeout: Duration | SUBSCRIBE 请求体 |
| `PatternData` | pattern: String | PREFIX / GLOB 请求体 |
| `ScanResult` | keys: ArrayList\<String\>, values: ArrayList\<Array\<Byte\>\> | 扫描/glob 匹配结果（含 keys+values） |
| `ScanEntry` | key, value: Array<Byte> | 扫描结果单条条目 |
| `WatchedValue` | `Value(Array<Byte>)` / `Deleted` | Watch 通知值枚举 |

---

## Glob 匹配

### 支持的通配符

| 通配符 | 含义 | 示例 |
|--------|------|------|
| `*` | 单级路径内任意字符（≥0） | `/app/*/host` → `/app/db/host` |
| `**` | 跨级路径匹配（≥0 级） | `/app/**/*.yaml` → `/app/a/b/c/host.yaml` |
| `?` | 单级路径内单个字符（=1） | `/app/?onfig` → `/app/config` |

### 实现原理

服务端收到 `ACK(PatternData)` 后根据 pattern 是否含 glob 字符分流：

- **含 `*` `?` `{`**：`store.prefix([])` 全量扫描 → `PathPattern.matches()` 逐 key 过滤
- **纯前缀**：`store.prefix(prefix)` LSM-Tree 范围迭代

`PathPattern` 使用 Trie 树编译 glob 模式，`matches(path)` 将具体路径按段走 Trie 匹配。
`**` 支持零段匹配（先检查子节点，再消耗段）。`*.yaml` 中的 `.` 自动转义为 `\.`。
`matches()` 默认保留文件扩展名。

---

## Watch 机制

### 实现原理

服务端 `handleSubscribe` 阻塞等待 `WatchFuture`（基于 `Mutex` + `Condition` 自实现 Promise）：

```
SUBSCRIBE(key, timeout=0)  → registerExact(key) → future.get()      → 永久阻塞
SUBSCRIBE(key, timeout>0)  → registerExact(key) → future.tryGet(t)  → 超时返回 None
```

当 REGISTER/PUBLISH/DEREGISTER 操作发生时，handler 调用 `watchManager.notify(key, value)`
→ 遍历精确/前缀/通配符三张注册表 → `future.set(data)` 唤醒等待线程 → 返回 `RESP(ValueData)`。

支持三种注册方式：`registerExact(key)`、`registerPrefix(prefix*?)`、`registerGlob(glob)`。
过期 Watcher 由后台线程每秒清理一次。

---

## 架构

```
┌────────────────────────────────────┐
│         fleet Server Node          │
│  ┌──────────────────────────────┐  │
│  │  SyncCommand (fboot fleet)    │  │
│  │  ├─ Server Startup           │  │
│  │  └─ Config Validation        │  │
│  ├──────────────────────────────┤  │
│  │  f_net.Server                │  │
│  │  └─ SyncHandler              │  │
│  │     ├─ NodeManager           │  │
│  │     │  └─ HashRing           │  │
│  │     ├─ WatchManager          │  │
│  │     │  └─ WatchFuture        │  │
│  │     └─ Store (LSM-Tree)      │  │
│  └──────────────────────────────┘  │
│                                    │
│  ┌──────────────────────────────┐  │
│  │  SyncClient (单例+单连接)     │  │
│  │  ├─ getInstance()            │  │
│  │  └─ f_net.Client             │  │
│  │     └─ MessageID→Future      │  │
│  └──────────────────────────────┘  │
│                                    │
│  ├─ exception/                     │
│  │  ├─ InvalidKeyException         │
│  │  └─ WriteFailedException        │
└────────────────────────────────────┘
```

### 包结构

```
fleet/
├── src/
│   ├── base/
│   │   ├── HashRing.cj              — 一致性哈希环
│   │   ├── HostAndPort.cj           — 节点地址
│   │   ├── SyncDataFormat.cj        — 消息体数据类（SyncData/ValueData/ScanResult 等）
│   │   └── SyncDataFormat_test.cj
│   ├── config/
│   │   └── SyncConfig.cj            — 配置读取
│   ├── exception/
│   │   └── exception.cj             — InvalidKeyException / WriteFailedException
│   ├── server/
│   │   ├── NodeManager.cj           — 节点管理/仲裁
│   │   ├── NodeManager_test.cj
│   │   ├── SyncCommand.cj           — SubCommand 入口
│   │   ├── SyncCommand_test.cj
│   │   ├── SyncHandler.cj           — 请求处理逻辑
│   │   ├── SyncHandlerStore_test.cj — 含 glob/prefix 集成测试
│   │   ├── SyncServer.cj            — 网络服务封装
│   │   ├── SyncServer_test.cj
│   │   ├── WatchManager.cj          — Watch 管理
│   │   ├── WatchManager_test.cj
│   │   ├── VersionCodec_test.cj     — 版本号编解码测试
│   │   ├── ClientOperations_test.cj — 客户端功能 handler 链路测试
│   │   └── GlobIntegration_test.cj  — glob 端到端集成测试
│   └── client/
│       └── SyncClient.cj            — 客户端 API
├── doc/
│   └── 架构设计文档.md               — 详细架构设计文档
├── README.md
└── cjpm.toml
```

### 测试覆盖

| 测试文件 | 覆盖范围 | 测试数 |
|---------|---------|--------|
| `SyncHandlerStore_test` | 各命令 handler 处理 + 前缀/glob 匹配 | 21 |
| `ClientOperations_test` | 客户端 API 完整 handler 链路 | 10 |
| `GlobIntegration_test` | glob 端到端 | 1 |
| 其他（base/config/server） | HashRing / NodeManager / WatchManager 等 | 33+ |
| **总计** | | **75** |
