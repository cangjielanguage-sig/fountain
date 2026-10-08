数据库中间件
---

## 模块定义
在fountain项目下面创建两个新的文件夹`f_dbd`和`fdbm`作为本项目新的仓颉模块。
`f_dbd` 的编译目标是动态链接库，`fdbm`的编译目标是可执行文件。
`fdbm` 是一个数据库中间件。
`f_dbd`是`fdbm`的驱动，同时还提供`f_dbd`和`fdbm`的共用代码，`fdbm`要依赖`f_dbd`，比如承载sql和SQL参数的类就是共用代码，此类可做以下声明：
```cj
//此类的实例转换为`fountain::f_data.Data`，作为`fountain::f_protocol.default.Message`的`data`成员变量
@DataAssist[fields props]
public class SqlPayload {
    private var sql: String = ''
    private var params: Array<DataAny> = []
}
```
这两个模块依赖`f_codec`实现编解码，使用`f_protocol`作为二者之间的通讯协议，使用`f_net`完成二者之间的网络通讯，使用`f_log`记录日志，使用`f_config`进行配置管理。
对于`f_codec`、`f_protocol`、`f_net`的使用可参考`f_rpc`模块。

从`f_dbd`访问`fdbm`使用`f_protocol`的*CONSUME*命令，从`fdbm`响应`f_dbd`使用`f_protocol`的*RESP*命令。

## `fdbm`

### 初始化配置

```
fdbm_dbs=dbName1,dbName2,dbName3
fdbm_dbName1_driver=postgres
fdbm_dbName1_url='url_for_postgres' # url可包含用户名和密码
fdbm_dbName1_username=username
fdbm_dbName1_password=password
# dbName2 dbName3 ... 依此类推

# 这些配置项都可以SM4加密并嵌入fdbd的编译产物
# 加密参数的配置继承自`f_config`。
# 具体嵌入方式，可参考`f_orm`的宏`ORMEmbedSensitive`
```

### 功能

#### 负载均衡
`fountain::f_net.client.MultiClient`已提供了负载均衡实现。`fdbm`只需要提供相应的配置：
```
fdbm_loadbalance=random # 随机负载均衡
fdbm_loadbalance=roundrobin # 轮询负载均衡
fdbm_dbWeight='host1:port,w1|host2:port,w2|...' # w1 w2是相应数据库节点的权重，fdbm通过fdbm_loadbalance和fdbm_dbWeight指定的权重实现负载均衡
# fdbm要做的就是用这三个参数初始化 fountain::f_net.client.MultiClient
# 对于多个读节点的情况可以启用这个功能
```

#### 读写分离

#### 水平分库


## `f_dbd`
### 初始化配置
同样支持连接url：`fdbm://[username:password@]<host1>:<port>;<host2>:<port>;<host3>:<port>`。
`username`和`password`可省略，支持%编码转义。

连接URL和用户名密码通过配置项传递给`fdbm`，使用`fountain::f_config.Config`读取，具体配置项如下：
```
fdbd_url='fdbm://username:password@host:port' # username password嵌入url时可%转义
fdbd_username=username
fdbd_password=password 
# 这些配置项都可以SM4加密并嵌入fdbd的编译产物
# 加密参数的配置继承自`f_config`。
# 具体嵌入方式，可参考`f_orm`的宏`ORMEmbedSensitive`
```

### 负载均衡
