## 服务端
服务端的顶级声明都是internal，不对外开放API。
### 配置
```bash
export fleet_port=2350 # fleet服务端监听的端口号，2350是默认端口号。也可以使用--fleet_port=2350 通过命令行参数指定
export fleet_storePath=/tmp/fleet # fleet服务端存储目录，默认目录是fleet所在目录的fleet/store
export fleet_bufferQueueSize=1024 # 数据缓冲队列大小，默认1024
export fleet_connectionCheckDuration=1000 # 连接健康检查周期，默认1000ms
export fleet_hosts=ip1:port1,ip2:port2..... # fleet服务端连接的ip和端口，多个ip用逗号隔开
```

### 启动
`fboot fleet`

## 客户端
客户的配置只有fleet_hosts

### API
```cj
public struct Fleet {
    public static func get<T>(path: String): ?T where T <: DataFields<T>
    public static func set<T>(path: String, data: T, expireAt: ?DateTime): Unit where T <: DataFields<T>
    public static func set<T>(path: String, data: T): Unit where T <: DataFields<T>
    public static func set<T>(path: String, data: T, expire!: Duration = Duration.Zero): Unit where T <: DataFields<T>
    /**
     * 删除指定path的数据
     */
    public static func remove(path: String): Unit
    /**
     * 调用此函数，path在服务端对应的数据发生变化时，服务端会把变化后的数据发回监听的客户端
     */
    public static func listen(path: String, executor: (Message) -> Unit): ListeningFleet
}
// 仅开放isClosed() close()两个函数，关闭时会取消监听
public struct ListeningFleet <: Resource
```