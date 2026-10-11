MQ
---

## 前置任务
加载技能using-git-worktrees，创建新的worktree

## 模块定义
在fountain项目下面创建两个新的文件夹`f_mq`和`fmq`，作为本项目新的仓颉模块。
`f_mq`是MQ的客户端，且包含与`fmq`共用的API，编译目标是动态链接库。
`fmq`是MQ的服务端，编译目标是可执行文件。

## 两个模块的cjpm.toml共同配置
两个模块初始化后都要在各自的cjpm.toml添加相同的category节点如下：
```toml
[package]
category = ["Infrastructure", "Message Queue", "MQ"] # 客户端服务端都使用这些分类
```

## 编解码、通讯与核心功能
`fmq`和`f_mq`之间都使用`f_codec`编解码，采用`f_protocol`作为通讯协议，使用`f_net`作为网络库，这三个模块的具体用法可以参考`f_rpc`。
- f_protocol 的各个命令如下：
  - register
    - 注册主题，注册时指定主题名和主题的队列数，**队列是宝贵的资源不可无节制地创建**。
      fmq服务进程自动地在各个服务节点间复制所有主题的元数据。
      每个主题元数据从发起注册的进程以`f_codec`编码，调用`f_net`的API向`fmq`服务节点传输
      `fmq`解码为MQTopicMeta对象，并初始化主题队列，每个主题的队列均匀地分布在所有节点上，如果队列数超过服务节点数则有些节点会多占用一些队列。
      每个队列从0开始编号，注册主题时要每个`fmq`节点都要保存这个主题的最大队列编号分配到了哪个节点，下次从这个节点的下一个节点开始分配新主题的队列。
      比如，有三个`fmq`节点分别是A B C，创建主题/topic1，队列数是4，编号是0 1 2 3，节点A拥有队列0 3，B C分别拥有队列1 2；创建主题/topic2，队列数是2，编号是0 1，节点A没有/topic2的队列，B C分别拥有队列0 1；依此类推。
      可以向任意`fmq`服务节点注册主题，所有主题元数据都会保存在所有`fmq`服务节点上。
      客户端不可使用此命令，只有`fmq manager`才可以可以使用此命令，下文会对`fmq manager`做详细说明。
    - 注册订阅组，注册时指定订阅组名，**订阅组是宝贵的资源不可无节制地创建**。
      每个订阅组元数据从发起注册的进程以`f_codec`编码，调用`f_net`的API向`fmq`服务节点传输
      `fmq`解码为MQSubscribeGroupMeta对象，并初始化订阅组。
      可以向任意`fmq`服务节点注册订阅组，所有订阅组元数据都会保存在所有`fmq`服务节点上。
      客户端不可使用此命令，只有`fmq manager`才可以可以使用此命令，下文会对`fmq manager`做详细说明。
    ```
    @DataAssist[props fields]
    public class MQTopicMeta {
        private var topic: String = ''  // 主题名
        private var queueNum: Int64 = 0 // 队列数
    }
    ```
  - deregister 
    - 删除主题，删除所有`fmq`服务节点上指定的主题相关的所有元数据、队列、消息
      - 删除消息是危险操作，客户端不可以删除主题，只能由`fmq manager`删除。
    - 删除订阅组，删除所有`fmq`服务节点上指定的订阅组相关的所有元数据、订阅者
      - 删除订阅组是危险操作，客户端不可以删除订阅组，只能由`fmq manager`删除。
  - publish - 发布消息。每条消息严格按照以下格式发布：
    - 消息主题字符串（TOPIC）、后面跟着消息标识字符串数组（TAGS）、消息ID（`fountain::f_protocol.MessageID`的字符串表示）、后面跟着消息内容（BODY）。
      - 每一部分都要单独编码，在网络流中连续地传输
    - TOPIC、TAGS、BODY都以`f_codec`编码
    - BODY可以是任意基本类型、字符串、Decimal、DateTime、Duration、被`@DataAssist[props fields]`修饰的类，以及它们的数组、ArrayList、HashSet、TreeSet、HashMap、TreeMap。
    - `fmq`服务节点使用`fountain::f_io.SegmentedLog`按照接收顺序保存消息。忠实地把从网络流接收到的字节序列写到SegmentedLog中。
    - 如果消息主题不存在，则使用error命令向客户端报错。
  - subscribe - 订阅主题
    - 客户端声明函数：`public func subscribe(topic: String, subscribeGroup!: String = '', tags!: Array<String> = [], filter!: String = '', autoAck!: Bool = false): String`
      - topic 不可以是空串
      - subscribeGroup是订阅组，空串是默认组。**订阅组是宝贵的资源不可无节制地创建**，每个订阅组必须事先由`fmq manager`创建，然后客户端才可以使用，否则必须报错。
        - `fmq`接收到不存在的订阅组订阅时使用error命令向客户端报错
        - 使用同一个订阅组的多个订阅者不会重复消费消息，消息可以在不同的订阅组之间重复消费。
      - tags是主题的tags，filter是`fountain::f_data.path`定义的路径作为消息过滤器；必须topic完全相等、包含subscribe包含的所有tags（不关心顺序），且filter结果为true的消息才能被订阅者接收。
      - tags为空数组时，表示此订阅不关注tags，任意tags都可以匹配
      - filter为空串时，表示此订阅不关注filter，订阅者消费任意BODY
      - autoAck为true时，服务端向订阅者发送消息时自动确认，客户端不需要调用ack命令
      - 返回用UUID表示的订阅唯一标识。
  - unsubscribe - 取消订阅
    - 客户端声明函数：`public func unsubscribe(subscribedId: String): Unit`
      - 参数是subscribe返回的订阅唯一标识符
  - consume - 消费消息
    - 客户端声明函数`public func consume(subscribedId: String): MQMessage`
      ```cj
      @DataAssist[props fields]
      public class MQMessage {
          private var topic: String = ''  // 订阅的topic
          private var tags: Array<String> = [] 
          private var body: ?DataAny = None
          private var segmentedIndex: Int64 = 0 // 当前消息在segmented log的索引
          private var segmentedOffset: Int64 = 0 // 当前消息在segmentedIndex所对应的segmented log的偏移

          public func get<T>(): ?T {
              match(body){
                case Some(x) => DataObject<T>.populate(body.data)
                case _ => None
              }
          }
      }
      ```
  - ack - 确认完成消息。客户端完成消费了要发送ACK消息
    - 客户端声明函数`public func ack(subscribedId: String, segmentedIndex: Int64, segmentedOffset: Int64): Unit`
      - 服务端要记录下最后完成消费的消息的segmentedIndex和segmentedOffset，以便于下次消费时从这个位置开始消费。要注意订阅组与segmentedIndex和segmentedOffset的关联关系。每个组的消费进度很可能不同。
      - 可能同一订阅组的订阅者在不同的线程处理消息的速度不一样，可能导致后面某个消息先于前面的消息ACK。
    - 始终没有ack的消息进入死信队列。
      - 超过一定时间没有ACK的消息会向订阅者重复投递，超过指定投递次数会进入死信队列。
      - 死信队列使用新的SegmentedLog存储
      - 有专门的消费者消费死信消息。
  - error - 报错，比如试图向不存在的主题发布消息，试图使用不存在的订阅组订阅主题等。
- 主题以`/`分隔的绝对路径表示。
- 消息元数据和订阅组元数据以`f_codec`编码保存在`fmq`所在目录的`metas`子目录中。

## `fmq`
### 服务进程
进程启动命令`fmq server`，进程启动时使用以下配置项完成初始化、监听端口号、初始化SegmentedLog和死信队列路径。
定义`protected struct MQConfig`，使用`fountain::f_config.Config`读取以下配置项，以静态属性返回各配置项的值。 
```
export mqServer_port=2350 # 默认端口2350
export mqServer_ackTimeout=10s # 默认ACK超时时间10秒，超过这个时间不ACK会向同一订阅组的订阅者重复投递消息
export mqServer_deadMsgThreshold=3 # 默认死信消息阈值3，重复投递超过阈值的消息进入死信队列
export mqServer_deadMsgTTL=72h # 默认死信消息TTL 72小时，死信队列内的消息超过这个时间会会自动删除
export mqServer_segmentedLogDir=/var/log/fmq/segmentedLogs # 默认SegmentedLog存储目录
export mqServer_deadMsgDir=/var/log/fmq/deadMsgs # 默认死信消息存储目录
export mqServer_segmentedLogMaxSize=1G # 默认SegmentedLog最大大小1G
export mqServer_segmentedLogTTL=72h # 默认SegmentedLog TTL 72小时，当SegmentedLog最后修改时间超过这个时间会自动删除

# 默认备份数0，即每条消息只有最初的节点存储一条。如果备份数大于0，则接收消息的节点会向下一个节点发送自身的SegmentedLog字节序列以及每条消息的状态，接收的`fmq`也要存储这些消息。
# 比如有A B C三个节点，备份数是2，A接收到消息分别向B C发送数据做备份，B接收到消息向C A发送数据做备份，C接收到消息向A B发送数据做备份。
# 万一某个节点挂了，可以从相信节点恢复服务。
# `fmq`的各个节点之间要互相发送PING命令确认存活，不论备份数是多少。
# 如果备份数指定为负数，`fmq`进程启动时要报错并结束进程。
export mqServer_backup=0 
```
#### 帮助
`fmq server --help` 显示所有的配置项和每个配置项的意义与默认值。

### 管理进程
启动命令`fmq manager`，进程启动时使用以下子命令完成主题注册、应该是删除、定义订阅组、删除订阅组、查看主题元数组、查看订阅组元数据。
当不指定`--server=<host>:<port>`，默认会读取当前服务器的配置项`mqServer_port`，并尝试连接当前服务器的`fmq server`进程。如果读不到这个配置项或无法建立有效连接，报错“无法连接消息队列服务”然后退出进程。
`--server`指定任意一个服务节点就可以，服务节点之间会自动同步元数据。
```
# 注册主题
fmq manager [--server=<host>:<port>] registerTopic </path/of/topic> <TopicQueueNumbers>
# 删除主题
fmq manager [--server=<host>:<port>] deleteTopic </path/of/topic>
# 定义订阅组
fmq manager [--server=<host>:<port>] registerSubscriber </path/of/topic> <SubscriberName>
# 删除订阅组
fmq manager [--server=<host>:<port>] deleteSubscribeGroup </path/of/topic> <SubscriberName>
# 查看主题元数据
fmq manager [--server=<host>:<port>] listTopics
# 查看订阅组元数据
fmq manager [--server=<host>:<port>] listSubscribeGroups </path/of/topic> 
```
#### 帮助
`fmq manager --help` 显示每个参数及所有的子命令和每个子命令的参数意义。

## `f_mq`
```
export mqClient_hosts=host1:port1,host2:port2
```