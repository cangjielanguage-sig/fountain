# 前置任务
mkdir fsync && cd fsync && cjpm init --type=dynamic && mkdir doc

## 任务
按照以下要求创建一个技术方案文档，保存在fsync/doc/sync.md。
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

5. 在fsync/src/实现raft协议。
5.1 fsync/src/server实现raft服务端
5.2 fsync/src/client实现raft客户端
5.3 严格实现raft协议
5.4 以极致性能为第一目标
5.5 活跃节点数超过一半可以继续提供服务
5.6 使用f_net 和f_protocol实现通讯协议，使用f_codec实现编解码
5.7 f_codec f_protocol已经测试过了，f_net可能有BUG，正式开始之前先为f_net添加测试用例，确认f_net没有问题
5.8 使用f_store 实现数据持久化
5.9 使用f_protocol/doc/定义的协议实现选举和同步数据
    - f_protocol的ELECT表示本次通讯为选举，VOTE表示本次通讯为发起投票，APPROVE表示本次通讯为同意位。
      - 0xd8 - 发起投票
      - 0xdd - 赞成发起方
      - pxd9 - 拒绝发起方
    - f_protocol的PUBLISH表示向另一主机同步数据
    - f_protocol的REGISTER表示向sync进程发送数据，sync进程需要存储发送过来的数据
      - 数据包含键和值，键必须是字符串，值必须是字节数组
      - fsync客户端以fountain::f_util.murmurHash(String) 决定向哪个fsync服务端进程发送数据
    - 以上都是消息头的解释，具体的发起选举、投票、同步数据、发送/接收数据都是消息体。
      - f_protocol详细定义了消息头、消息ID、消息体
      - 消息按照f_codec编码，按以下顺序发送：
        - 消息头
        - 消息ID - f_protocol已定义
        - 数据KEY
        - 数据版本
        - 数据字节数组
5.10 添加f_app依赖，实现fountain::f_app.SubCommand
     - 本项目不必实现main函数，
     - SubCommand实现以子命令“sync”将本项目注册到fountain::f_app。
     - 具体实现与注册方法参考fountain::f_app.PublishCommand
     - 本项目可以使用命令fboot sync --hosts=ip1:port,ip2:port,ip3:port启动
5.11 为本项目添加测试用例
