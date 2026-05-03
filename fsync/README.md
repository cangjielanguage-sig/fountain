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

本地节点索引由 `sync_hosts` 列表中 IP 与本地主机名或回环地址（`127.0.0.1`、`localhost`）的匹配位置决定。

### 启动方式

所有节点的 `sync_hosts` 配置必须完全一致（IP、端口、顺序、数量都必须相同），否则启动后会自动检测并报错退出。

```bash
# 单节点启动
fboot sync --sync_hosts=127.0.0.1:1203

# 多节点集群（各节点使用完全相同的 sync_hosts）
# 节点 0（绑定 1203 端口）
fboot sync --sync_hosts=10.0.0.1:1203,10.0.0.2:1203 --sync_dataPath=/data/fsync

# 节点 1（绑定 1204 端口，主机名匹配到列表中第二个位置）
fboot sync --sync_hosts=10.0.0.1:1203,10.0.0.2:1204 --sync_dataPath=/data/fsync
```

### 启动流程

1. `static init()` 自动注册到 `SubCommandMediator`（子命令名 `sync`）
2. `exec()` 读取配置 → 初始化 `Store` / `NodeManager` / `WatchManager` / `SyncHandler` / `SyncServer`
3. 在后台线程启动 TCP 服务，绑定端口取自节点列表中本地节点端口
4. 后台线程启动后，连接各对端节点进行**配置一致性校验**：
   - 读取对端 `__config__` 元键获取其 `sync_hosts` 配置
   - 与本地的 `sync_hosts` 比较（必须完全一致）
   - 不一致则输出错误信息、退出进程
5. 主线程阻塞等待

### 元键

| 键 | 用途 |
|----|------|
| `__config__` | GET 该键返回本节点的 `host1:port1,host2:port2,...` 配置字符串 |

---

## 客户端 (Client)

### 配置项

客户端构造时自动从 `sync_hosts` 配置项读取集群节点列表，无需额外参数。

### 公共 API

```cj
// 构造客户端
// requestTimeout: 请求超时时间（默认 10s）
// 节点列表自动从 Config.getString('sync_hosts') 读取
public init(requestTimeout!: Duration = Duration.second * 10)

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

// 前缀扫描（所有节点可读）
// 返回匹配前缀的所有键值对条目
public func prefix(pattern: String): ArrayList<ScanEntry>

// 通配符扫描（委托前缀扫描实现）
public func glob(pattern: String): ArrayList<ScanEntry>

// 注册 Watch（监听指定 KEY 的变更）
// timeout: Duration.Zero 表示永不超时
public func watch(key: String, timeout!: Duration = Duration.Zero): Unit

// 取消 Watch
public func unwatch(key: String): Unit
```

### 通信协议

| API | f_protocol 命令 | 请求体 | 响应体 |
|-----|----------------|--------|--------|
| `add` | `REGISTER` | `SyncData(key, version, value)` | `KeyData(key)` |
| `delete` | `DEREGISTER` | `KeyData(key)` | `KeyData(key)` |
| `get` | `ACK` + `KeyData` | `KeyData(key)` | `ValueData(?value)` |
| `prefix` | `ACK` + `PatternData` | `PatternData(pattern)` | `ArrayList<ScanEntry>` |
| `glob` | `ACK` + `PatternData` | `PatternData(pattern)` | `ArrayList<ScanEntry>` |
| `watch` | `SUBSCRIBE` | `WatchData(key, timeout)` | `KeyData(key)` |
| `unwatch` | `UNSUBSCRIBE` | `KeyData(key)` | `KeyData(key)` |

### 数据体类型

定义在 `fountain::fsync.base` 包：

| 类型 | 字段 | 用途 |
|------|------|------|
| `SyncData` | key: String, version: Int64, value: Array<Byte> | REGISTER / PUBLISH 请求体 |
| `KeyData` | key: String | DEREGISTER / GET / UNSUBSCRIBE 请求体 |
| `ValueData` | value: ?Array<Byte> | GET 响应体（None 表示不存在/已删除） |
| `WatchData` | key: String, timeout: Duration | SUBSCRIBE 请求体 |
| `WatchNotifyData` | key: String, value: ?Array<Byte> | Watch 变更通知 |
| `PatternData` | pattern: String | PREFIX / GLOB 请求体 |
| `ScanEntry` | key: String, value: Array<Byte> | 扫描结果条目（PREFIX/GLOB 响应） |
| `WatchedValue` | `Value(Array<Byte>)` / `Deleted` | Watch 通知值枚举 |

---

## 架构

```
┌────────────────────────────────────┐
│         fsync Server Node          │
│  ┌──────────────────────────────┐  │
│  │  SyncCommand (fboot sync)    │  │
│  │  ├─ Server Startup           │  │
│  │  └─ Config Validation        │  │
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
├── README.md
└── cjpm.toml
```
