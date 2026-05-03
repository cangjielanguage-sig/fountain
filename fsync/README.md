# fsync — 分布式键值同步系统

去中心化的键值同步系统，各节点绝对平等，通过一致性哈希分片存储数据，通过互相同步实现数据最终一致性。

---

## 服务端 (Server)

### 配置项

通过 `fountain::f_config.Config` 读取，支持环境变量和命令行参数（`--key=value`）。

| 配置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `sync_hosts` | `String` | **必填** | 集群节点列表，逗号分隔，格式 `ip1:port1,ip2:port2` |
| `sync_dataPath` | `String` | `/tmp/fsync` | 数据存储目录 |
| `sync_localIndex` | `Int64` | `0` | 本地节点在节点列表中的索引（仅命令行参数） |

### 启动方式

```bash
# 单节点启动（默认索引 0）
fboot sync --sync_hosts=127.0.0.1:1203

# 多节点集群（分别在不同机器启动）
# 节点 0
fboot sync --sync_hosts=10.0.0.1:1203,10.0.0.2:1203 --sync_dataPath=/data/fsync --sync_localIndex=0

# 节点 1
fboot sync --sync_hosts=10.0.0.1:1203,10.0.0.2:1203 --sync_dataPath=/data/fsync --sync_localIndex=1
```

启动流程：
1. `static init()` 自动注册到 `SubCommandMediator`（子命令名 `sync`）
2. `exec()` 读取配置 → 初始化 `Store` / `NodeManager` / `WatchManager` / `SyncHandler` / `SyncServer`
3. 在后台线程启动 TCP 服务，绑定端口取自节点列表中本地节点端口
4. 主线程阻塞等待

---

## 客户端 (Client)

### 配置项

客户端无独立配置文件，通过构造函数传入节点列表和参数。

### 公共 API

```cj
// 构造客户端
// nodes:     集群所有节点
// localIndex: 本地节点索引（仅用于一致性哈希路由）
// requestTimeout: 请求超时时间（默认 10s）
public init(nodes: ArrayList<HostAndPort>, localIndex: Int64, requestTimeout!: Duration = Duration.second * 10)

// 写入键值对（仅 Owner 节点可写）
// key:   键，UNIX 风格路径（如 /app/config/db/host）
// value: 值
// 写入失败时抛出 Exception
public func add(key: String, value: Array<Byte>): Unit

// 删除键值对（仅 Owner 节点可写）
public func delete(key: String): Unit

// 读取键值对（所有节点可读）
// 返回 None 表示键不存在
// Owner 超时时自动故障转移到下一节点
public func get(key: String): ?Array<Byte>
```

### 通信协议

| API | f_protocol 命令 | 请求体 | 响应体 |
|-----|----------------|--------|--------|
| `add` | `REGISTER` | `SyncData(key, version, value)` | `KeyData(key)` |
| `delete` | `DEREGISTER` | `KeyData(key)` | `KeyData(key)` |
| `get` | `ACK` | `KeyData(key)` | `ValueData(?value)` |

### 数据体类型

定义在 `fountain::fsync.base` 包：

| 类型 | 字段 | 用途 |
|------|------|------|
| `SyncData` | key: String, version: Int64, value: Array<Byte> | REGISTER / PUBLISH 请求体 |
| `KeyData` | key: String | DEREGISTER / GET 请求体 |
| `ValueData` | value: ?Array<Byte> | GET 响应体（None 表示不存在/已删除） |
| `WatchData` | key: String, timeout: Duration | WATCH 注册 |
| `WatchNotifyData` | key: String, value: ?Array<Byte> | Watch 变更通知 |
| `PatternData` | pattern: String | PREFIX / GLOB 请求 |

---

## 架构

```
┌────────────────────────────────────┐
│         fsync Server Node          │
│  ┌──────────────────────────────┐  │
│  │  SyncCommand (fboot sync)    │  │
│  │  └─ Server Startup           │  │
│  ├──────────────────────────────┤  │
│  │  f_net.Server                │  │
│  │  └─ SyncHandler              │  │
│  │     ├─ NodeManager           │  │
│  │     │  └─ HashRing           │  │
│  │     ├─ WatchManager          │  │
│  │     └─ Store (LSM-Tree)      │  │
│  └──────────────────────────────┘  │
│                                    │
│  ┌──────────────────────────────┐  │
│  │  SyncClient (peer access)    │  │
│  │  ├─ HashRing routing         │  │
│  │  └─ f_net.Client pool        │  │
│  └──────────────────────────────┘  │
└────────────────────────────────────┘
```

### 包结构

```
fsync/
├── src/
│   ├── base/
│   │   ├── HashRing.cj         — 一致性哈希环
│   │   ├── HostAndPort.cj      — 节点地址
│   │   └── SyncDataFormat.cj   — 消息体数据类
│   ├── config/
│   │   └── SyncConfig.cj       — 配置读取
│   ├── server/
│   │   ├── NodeManager.cj      — 节点管理/仲裁
│   │   ├── SyncCommand.cj      — SubCommand 入口
│   │   ├── SyncHandler.cj      — 请求处理逻辑
│   │   ├── SyncServer.cj       — 网络服务封装
│   │   └── WatchManager.cj     — Watch 管理
│   └── client/
│       └── SyncClient.cj       — 客户端 API
└── cjpm.toml
```
