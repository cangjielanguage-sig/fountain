数据库中间件
---

## 模块定义
在fountain项目下面创建两个新的文件夹`f_dbd`和`fdbm`作为本项目新的仓颉模块。
`f_dbd` 的编译目标是动态链接库，`fdbm`的编译目标是可执行文件。
`fdbm` 是一个数据库中间件。
`f_dbd`是`fdbm`的驱动，同时还提供`f_dbd`和`fdbm`的共用代码，`fdbm`要依赖`f_dbd`，比如承载sql和SQL参数的类以及驱动数据类型的实现就是共用代码，它们类可做以下声明：
```cj
import std.collection.ArrayList
import std.database.sql.*
import fountain::f_data.*

//此类的实例转换为`fountain::f_data.Data`，作为`fountain::f_protocol.default.Message`的`data`成员变量
//在f_dbd的Statement实现内部创建SqlPayload，Statement的set<T>函数和setNull()调用它的add<T>(...)和addNull()填充参数
//f_dbd编码，fdbm解码
@DataAssist[fields props]
public class SqlPayload {
    private var sql: String = ''
    private let params = ArrayList<DataAny>()

    func add<T>(param: T): Unit where T <: ToData {
         params.add(DataAny(param.toData()))
    }
    func addNull(): Unit {
        params.add(DataAny(DataNone.INSTANCE))
    }
}

@DataAssist[fields props]
public class UpdateResultPayload <: UpdateResult{
    private var rowCount: Int64
    private var lastInsertId: Int64
}

//fdbm编码，f_dbd解码
@DataAssist[fields props]
public class QueryResultServerPayload{
    private var columnInfos: Array<ColumnInfo>
    private var hasData: Bool//本次查询是否有数据，
    //如果有数据读取数据时就以QueryResultColumnPayload作为请求负载，以具体数据值作为响应负载。
    //f_dbd以ColumnInfo的索引发起列读请求，fdbm以ColumnInfo的typeName决定以什么类型从物理数据库的驱动读取并编码。
    //f_dbd收到数据以ColumnInfo决定以读取类型。
}
@DataAssist[fields props]
public class QueryResultColumnPayload {
    //从0开始
    private var index: Int64
    //仅对列类型是InputStream时有效，列类型是InputStream时返回的是最长bufSize的字节数组
    private var bufSize: Int64
}

@DataAssist[fields props]
public class ColumnInfoImpl <: ColumnInfo{
    private var name: String
    private var typeName: String
    private var length: Int64
    private var scale: Int64
    private var nullable: Bool
    private var displaySize: Int64
}
```
这两个模块依赖`f_codec`实现编解码，使用`f_protocol`作为二者之间的通讯协议，使用`f_net`完成二者之间的网络通讯，使用`f_log`记录日志，使用`f_config`进行配置管理。
对于`f_codec`、`f_protocol`、`f_net`的使用可参考`f_rpc`模块。
使用`f_fdbm`的PooledDatasource连接物理数据库。

从`f_dbd`访问`fdbm`使用`f_protocol`的*CONSUME*命令，从`fdbm`响应`f_dbd`使用`f_protocol`的*RESP*命令。

## `fdbm`

### 功能
#### 数据库节点配置
```
export fdbm_db='name0@host1:port;name2@host2:port;name3@host3:port;...' 
# 这是各个数据库节点，各个节点用分号隔开
# @前面的是中间件为节点名，不是数据库名
export fdbm_db_driver_name0=driver_name # 这个节点的数据库驱动名
export fdbm_db_database_name0=database_name_0 # 这是数据库名的配置，参与分库的物理数据库不可重名，同名的物理数据库参与负载均衡
export fdbm_db_database_name1=database_name_0 # 多个数据库节点可以拥有相同的数据库名
export fdbm_db_database_name2=database_name_0
export fdbm_db_database_name3='database_name_0,database_name_1' # 一个节点下面可以有多个数据库
export fdbm_db_username_name0=<username> # name0的用户名，其他节点用户名配置以此类推
export fdbm_db_password_name0=<password> # name0的密码，其他节点的密码配置以此类推
# 不同节点、不同数据库内部拥有相同的表定义
# 节点名不同、数据库名相同之间实现负载均衡、读写分离
# 不同的数据库名之间实现水平分库

# 同样可以配置sm4的KEY IV等，配置方法和`f_config`一致，具体参考`fdemo/boot.sh`的build函数

# 一个物理数据库可以对应多个逻辑数据库
export fdbm_db_logicalDatabase_<logical_database_name>='database_name_0,database_name_1' 
```
#### 连接池配置
```
# 在fdbm的部署路径下面创建driver子目录，将驱动的**动态链接库**文件复制到这里
# fdbm启动时自动从这里加载驱动（调用std.reflect.PackageInfo.load(dylibPath)），逐个加载。
# 调用std.database.sql.DriverManager.drivers()获得所有驱动名，用驱动名逐个调用std.database.sql.Driver.getDriver(driverName)得到驱动实例
# 使用前面配置的每一个host:port和数据库名、用户名、密码构造出数据库连接url，结合以下配置完成连接池初始化（每个host:port+database_name对应一个fountain::f_dbpool.DatabasePool实例）。
# 注：现在DatabasePool还在fountain::f_orm.wrap，后面会创建新模块f_dbpool，将DatabasePool移动到新模块中，f_orm原DatabasePool的文件内重导出这个声明。
export fdbm_databasePoolInitSize=1 # 初始连接数
export fdbm_databasePoolMinSize=1 # 最小连接数
export fdbm_databasePoolMaxSize=1 # 最大连接数
export fdbm_databasePoolCheckOnCreation=true # 创建连接时是否检查连接有效性，默认是false
export fdbm_databasePoolCheckOnBorrowing=true # 获取连接时是否检查连接有效性，默认是true
export fdbm_databasePoolCheckOnReturning=false # 归还连接时是否检查连接有效性，默认是true
export fdbm_databasePoolIdleTimeout=0 # 连接闲置时间，默认是0，表示闲置不过期
export fdbm_databasePoolConnectionLife=86400 # 连接存活时间，默认是3600，单位是秒
export fdbm_databasePoolCheckInterval=300 # 连接有效性检查周期，默认是300，单位是秒
export fdbm_databasePoolConnectTimeout=50 # 默认是50，单位是毫秒，从fountain.fdbm.DatabasePool获取连接的超时时间
export fdbm_databasePoolMaxWaiting=30000 # 默认是30000（单位毫秒，即30秒）。池耗尽且调用方用无限等待（Duration.Max）取连接时的等待上限；超过上限就记WARN并返回None，避免无日志挂死；配成0表示真无限等待
export fdbm_databasePoolCheckSql='select 1' # 检查连接有效性的SQL，默认是select 1
```

#### 负载均衡、读写分离
`fountain::f_net.client.MultiClient`已提供了负载均衡实现。`fdbm`只需要提供相应的配置：
```
# 使用fountain::f_config.Config读取以下环境变量表示的配置项
export fdbm_loadbalance=random # 随机负载均衡
export fdbm_loadbalance=roundrobin # 轮询负载均衡
export fdbm_loadbalance_weight_name0='w,1;r;2' # 这是节点name0的权重，w,1表示写权重为1，r;2表示读权重为2
export fdbm_loadbalance_weight_name1='w,2;r;1' # 这是节点name1的权重，w,2表示写权重为2，r;1表示读权重为1依，此类推
export fdbm_loadbalance_weight_name3__database_0='w;r' # 这是节点name3的权重，w表示写权重为1，r表示读权重为1
export fdbm_loadbalance_weight_name3__database_1='w;r' # 这是节点name3的权重，w表示写权重为1，r表示读权重为1
#export fdbm_loadbalance_weight_name3='w;r' # 这是节点name3的权重，w表示写权重为1，r表示读权重为1
export fdbm_loadbalance_weight_name4=w # 这是节点name4的权重，w表示写权重为1，且name4没有配置读权重，那么这个节点就是只写的
export fdbm_loadbalance_weight_name5=r # 这是节点name5的权重，r表示读权重为1，且name5没有配置写权重，那么这个节点就是只读的
# 如果节点名后面跟着两个下划线和物理数据库名，表示这个节点下面的这个数据库的读写权重配置
# 如果节点名后面没有下划线和物理数据库名，表示这个节点下面的所有数据库使用一样的读写权重配置
# 如果节点名后面只有下划线，这是错误配置，启动时应当**报错**并**结束进程**。
```

按照以上配置，可以构造出以下对象：
```cj
import std.collection.HashMap
import std.database.sql.*
import fountain::f_concurrent.LoadBalance
import fountain::f_config.Config
protected struct DatabaseResources {
    //LoadBalance的第一个泛型实参是权重，第二个泛型实参是数据库连接池，第三个泛型实参是数据库连接。
    //HashMap的KEY是物理数据库名称，不同节点、相同物理数据库名的DatabasePool实例对应一个LoadBalance实例
    //如果一个物理数据库同时配置了读权重和写权重，那么它会同时出现在readNodes和writeNodes中
    //如果一个物理数据库只配置了读权重，那么它只会出现在readNodes中，对于只配置写权重的情况则只会出现在writeNodes中
    private let readNodes = HashMap<String, LoadBalance<Int64, DatabasePool, Connection>>() 
    private let writeNodes = HashMap<String, LoadBalance<Int64, DatabasePool, Connection>>()
    public init(){
        let allConfs/*: HashMap<String, String>*/ = Config.getAll()
        //allConfs包含前面提到的所有配置项，利用这些配置项填充readNodes和writeNodes
    }
    public func selectReadNode(database: String): Connection {
        // 从readNodes中选择一个节点并返回连接
    }

    //database是物理数据库名称，返回一个数据库连接
    public func selectWriteNode(database: String): Connection {
        // 从writeNodes中选择一个节点并返回连接
    }
}
```

#### 水平分库
```
# ID步长分库，step是分库算法，默认是1000_0000，即ID在1-1000万的分到database_name_0，1000_0001-2000万分到database_name_1，2000_0001-3000万分到database_name_2，以此类推
export fdbm_partition_step=1000_0000 

# 哈希分库算法可选值有std crc16 crc32 crc64 murmur，默认是hash。选择hash的时候计算的是ID的hashCode()。
# 每个哈希分片算法都对应一个类。crc和murmur依赖fountain::f_util，CRC算法采用它们的顶级函数，murmur采用MurmurHash3X128
# 由于算法是固定的，不需要有配置项

# 每个表都如此配置，fdbm_partition__后面跟表名是配置项，配置值是'<逻辑数据库名称>,<分库算法>,<参与分库计算的列名>'
# 如果fdbm_partition后面没有下划线或者没有表名，则**报错**并**结束进程**。
export fdbm_partition__table_name='localcal_database_name,partition_algorithm,partition_column_name'
```
每一种分库算法都实现同一个接口，每个分库算法实现内部都维持着所有参与分库的物理数据库名称，并以算法需要的方式组织数据结构：
```cj
//开发者可以自定义分库算法，如果算法需要额外的配置，由开发者自己定义，并调用fountain::f_config.Config读取、解析
public interface PartitionAlgorithm {
    //算法名称
    prop name: String
    //key是分库的键，返回一个物理数据库名
    func partition<K>(key: K): String
}
```
#### 全局表
全局表的数据在逻辑数据库包含的每个物理数据库中各有一副相同的副本
```
export fdbm_global__table_name='localcal_database_name'
```

#### ID生成器
每个ID生成器都要实现同一个接口：
```cj
public interface IdGenerator{
    //算法名称
    prop name: String
    //返回一个ID，由于可能是整数或字符串，所以声明两个函数。默认实现抛出异常
    func nextStringId(): String{
        throw IdGeneratorException()
    }
    func nextIntId(): Int64{
        throw IdGeneratorException()
    }
}
```
1. UUID
```
# uuid采用fountain::f_util.UUID，后面的数字表示UUID版本
export fdbm_idmaker=uuid,1
```
2. Snowflake
```
# snoflake采用fountain::f_util.IdMaker
#export fdbm_idmaker=snowflake
```
3. Sequence
```
# sequence需要在数据库里建一个表fountain_sequence，表结构在下面定义
#export fdbm_idmaker=sequence
```
```sql
create table fountain_sequence(
    table_name varchar(64) not null comment '值是<logical_database_name>.<table_name>',
    current_value bigint not null comment '从1开始',
    increment bigint not null comment '每次递增的步长值',
    primary key(table_name)
)
-- 这个表需要配合存储过程或函数使用，可以参考dble的文档。这个表结构是参考mysql的，需要同时兼容mysql/postgres
```

### 数据库兼容性
可以提供mysql和postgres的支持，但是`/path/to/fdbm/driver`下面只能有一个驱动。如果有两个驱动要**错误**并**结束进程**。
fdbm不负责SQL方言的转换，`f_dbd`的SQL方言要与`/path/to/fdbm/driver`保持一致。

### SQL兼容性
尽量使用简单SQL，复杂SQL会影响性能。
fdbm负责解析INSERT UPDATE DELETE SELECT，及JOIN等各种语法。
INSERT INTO ... SELECT，拆成INSERT INTO ... VALUES ...和SELECT。如果SELECT 出多行，逐行INSERT。
INSERT INTO <table_name> SET <column_name>=<value>, <column_name>=<value> ... 也要支持
UPDATE 也要支持JOIN。
不支持存储过程和函数。

### 缓存
采用f_store缓存分库列值和物理库的关系，默认开启，且永久保存。
缓存KEY是`'<logical_database_name>.<table_name>.<column_name>:<value_string>'.unsafeBytes()`，值是`<physical_database_name>.unsafeBytes()`
unsafeBytes 是fountain::f_base对字符串的扩展。
执行DELETE时，要先把受影响的数据行的分库键都查出来，然后删除记录，再删除缓存。
UPDATE/SELECT时，如果缓存中存在，但是数据库不存在，则从缓存中删除。**注意**，可能只有一部分缓存在数据库中存在，有一部分不存在。
```
export fdbm_cache=true # 是否开启缓存
export fdbm_cache_expire=1d # 缓存过期时间，不填则永久保存，采用Duration.toString()的字符串格式
export fdbm_cache_size=10000000 # 缓存KEY的数量，默认不限制
```

### 与f_dbd交互
通讯协议和编解码格式前面已经介绍过。
允许定义多个逻辑数据库，并且f_dbd要能够用`show databases`查看，能够用`show tables [logical_database_name] [like '...']`查看指定逻辑数据库的表，如果没有指定逻辑数据库，就是查看当前数据库。
可以通过f_dbd执行`create table` `alter table`。
可以通过f_dbd执行`export <config_item>=<value>` 修改配置项，并把配置项落到启动脚本中。

### 启动脚本
在fdbm定义boot.sh，里面要包含各种配置项和启动与停止命令。
### 优雅停止
响应kill -15，停止接收新的访问，等待执行完成并响应已接收到的访问，自动关闭所有连接，然后结束进程

## `f_dbd`
完整实现`std.database.sql`的全部API。采用仓颉侧的数据类型，不是`std.database.sql`的数据类型。