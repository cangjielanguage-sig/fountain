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
### 部署
```bash
cjpm install fountain::fboot-<a.b.c> # 使用跟fleet一样的版本
cjpm install fountain::fleet-<a.b.c> # 去安装路径找到下载的包，复制到指定路径然后执行以下路径
cp /path/of/fleet/installed /path/of/fleet/copied
cd /path/of/fleet/copied
cjpm build 
```
也可以从git下载源码
```bash
git clone https://gitcode.com/Cangjie-SIG/fountain.git
git checkout -b release-<a.b.c> # <a.b.c> 改成最新版本
cd /path/of/fountain/cloned
cd fboot
cjpm intall --root /path/of/fboot/installed
cd ../fleet
cjpm build
```

### 启动
```bash
cd /path/of/fleet/compiled-or-installed
fboot fleet --dylibPattern='fountain|f_.*|fleet'
```


## 客户端
客户的配置只有`fleet_hosts`（同名常量在`FleetConfig.FLEET_SERVER_HOSTS`）。

```cj
public struct FleetConfig {
    public static const FLEET_SERVER_HOSTS = 'fleet_hosts'
    /**客户端要连接的fleet服务端地址列表，按逗号分隔*/
    public static prop hosts: Array<String>
}
```

客户端按`path`做分片路由（`clients[path.hashCode() % clients.size]`），不是负载均衡：同一个`path`总是落到同一个服务端。因此`fleet_hosts`的**顺序改变会改变 path 到服务端的映射**，扩缩容时需要评估存量数据的归属。

`FleetClientException <: BaseException`是客户端失败信号；`fleet.base`还提供两个常量：`ERROR_HOST_FOR_PATH = 'ErrorHost'`、`UNSUPPORTED_COMMAND = 'UnsupportedCommand'`。

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

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`public class FleetDataMessage`、`bufferQueueSize`（prop）、`command`（prop）、`connectionCheckDuration`（prop）、`public func exec(args: Array<String>): Int64`、`port`（prop）、`storePath`（prop）
- `FleetDataMessage`：`new`（func）
