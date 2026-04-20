# 前置任务
mkdir fsync && cd fsync && cjpm init --type=dynamic && mkdir doc

## 任务
按照以下要求创建一个架构设计文档，保存在fsync/doc/sync.md。
按照sync.md拆分开发任务，制定开发计划，详细描述开发计划的每一步需要做什么，以及需要注意的要点、难点和需要注意的问题。
以下提到的依赖项如果不足以实现需求务必要提出不足之处，经用户确认之后再生成文档。

1. mkdir -p fsync/src/config
2. touch fsync/src/config/SyncConfig.cj
3. 在fsync/cjpm.toml添加fountain::f_config fountain::f_base fountain::f_codec fountain::f_net fountain::f_protocol的依赖
4. 在SyncConfig.cj 添加以下代码
```cj
package fountain::fsync.config

import fountain::f_config.*

public class SyncConfig {
    public static const sync = 'sync'
    public static const hosts = sync + '_hosts'
    public static const dataPath = sync + '_dataPath'
    /**
     * 集群内的节点列表，使用英文逗号分隔，同时包含ip1:port1,ip2:port2,ip3:port3...
     */
    public static func getHosts(): Array<HostAndPort>{
        let hosts = Config.getString(hosts).split(',')
        Array<HostAndPort>(hosts.size){i => HostAndPort(hosts[i])}
    }
    /**
     * 数据保存路径，默认为/tmp/fsync
     */
    public static func getDataPath(): String {
        Config.getString(dataPath) ?? '/tmp/fsync'
    }
    //需要其它配置就往后添加
}
public struct HostAndPort {
    public HostAndPort(
        public let host: String,
        public let port: UInt16
    ){}
    public init(host: String){
        let idx = host.indexOf(':') ?? -1
        this.host = host[0..idx]
        this.port = idx == -1 ? 1203 : UInt16.parse(host[idx+1..])
    }
}
```

5. 在fsync/src/严格实现raft协议。
5.1 fsync/src/server实现raft服务端
    - 添加f_app依赖，实现fountain::f_app.SubCommand
      - 本项目服务端不必实现main函数，
      - SubCommand实现以子命令“sync”将本项目注册到fountain::f_app。
      - 具体实现与注册方法参考fountain::f_app.PublishCommand
      - 本项目可以使用命令fboot sync --hosts=ip1:port,ip2:port,ip3:port启动
    - 活跃节点数超过一半可以继续提供服务
    - 使用f_store 实现数据持久化
    - 使用f_protocol/doc/定义的协议实现选举和同步数据
      - f_protocol的ELECT请求头表示本次通讯为sync服务节点发起选举，VOTE表示本次通讯为选举投票，APPROVE表示本次通讯为选举同意位。
        - 0xd8 - 发起选举
        - 0xdd - 赞成发起方
        - pxd9 - 拒绝发起方
        - f_protocol的PUBLISH请求头表示sync服务进程向另一主机同步数据
        - f_protocol的REGISTER请求头表示向sync进程发送数据，sync进程需要存储发送过来的数据
        - 数据包含键和值，键必须是字符串，值必须是字节数组
          - 使用UNIX风格的路径作为KEY
        - fsync客户端以fountain::f_util.murmurHash(String) 决定向哪个fsync服务端进程发送数据
        - 以上都是消息头的解释，具体的发起选举、投票、同步数据、发送/接收数据都是消息体。
        - f_protocol详细定义了消息头、消息ID、消息体
        - 消息按照f_codec编码，按以下顺序发送：
          - 消息头
          - 消息ID - f_protocol已定义
          - 数据KEY
          - 数据版本
          - 数据字节数组
    - 对外开放网络服务：
      - 添加键值对
      - 删除键值对
      - 修改键对应的值
      - KEY前缀遍历
      - KEY通配符遍历
      - 监听键对应的值的变化，包括添加、删除、修改
        - 可以指定监听超时时间
        - 可以取消监听
        - 值没有变化就阻塞直到超时，如果没有指定超时时间就一直阻塞
        - 值发生了变化，给客户端返回变化以后的值，如果是删除操作就返回f_codec定义的None
5.2 fsync/src/client实现raft客户端
    - 客户端作为其它项目的依赖
    - 提供一个开放以下公共实例成员函数的类，依赖客户端的项目调用这些函数访问服务端的服务
      - `get(key: String): ?Array<Byte>`
      - `add(key: String, value: Array<Byte>): Unit`
      - `delete(key: String): Unit`
      - `prefix(prefix: String): Iterator<(String, Array<Byte>)>` # 遍历所有符合prefix模式的KEY和对应的值
      - `glob(glob: String): Iterator<(String, Array<Byte>)>` # 遍历所有符合glob模式的KEY和对应的值
      - `watch(key: String, timeout!: Duration = Duration.Zero): ?Array<Byte>` # timeout: Duration.Zero表示不超时
      - `unwatch(key: String): Unit` # 取消监听
      - `watchPrefix(key: String, timeout!: Duration = Duration.Zero): Iterator<(String, WatchedValue)>` # 监听所有具有相同前缀的KEY，任意一个KEY发生变化就立即返回，可能同时有多个发生变化，所以返回一个迭代器，timeout: Duration.Zero表示不超时，监听所有符合前缀的KEY
      - `unwatchPrefix(key: String): Unit` # 取消监听
      - `watchGlob(key: String, timeout!: Duration = Duration.Zero): Iterator<(String, WatchedValue)>` # 监听所有满足相同glob模式的KEY，任意一个KEY发生变化就立即返回，可能同时有多个发生变化，所以返回一个迭代器，timeout: Duration.Zero表示不超时，监听所有符合通配符的KEY
      - `unwatchGlob(key: String): Unit` # 取消监听
```cj
public enum WatchedValue{
    Value(Array<Byte>)
    Deleted
}
```
5.4 以极致性能为第一目标
5.5 使用f_net 和f_protocol实现通讯协议，使用f_codec实现编解码
5.6 f_codec f_protocol f_net已经测试过了
5.7 网络通讯使用std.net.TcpSocket，文件存储使用本项目的f_store
5.8 为本项目添加测试用例
