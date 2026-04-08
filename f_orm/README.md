
# ORM
## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 配置
```bash
# export opengauss_orm_useThirdPartyPool=flase # 可以为指定的数据库驱动配置是否使用第三方池
# 此时使用ORM.register(datasource, default: false) # 开发者自己用代码初始化Driver和连接池、调用这个函数注册连接池
# export orm_useStdPool=false # 默认是true，表示使用标准库连接池，false是使用fountain连接池
export orm_drivers=mockdb,opengauss # 逗号分隔的驱动名称，最后一个驱动是默认驱动，
#以下每个配置项都可以在使用<driverName>_前缀单独为特定驱动指定配置项
# 如果不使用fountain连接池，也不使用标准库连接池，就不要配置以下orm_*Pool*变量，只配置orm_noPool，只能用代码初始化第三方连接池
export orm_useThirdPartyPool=false # 使用第三方连接池，不使用fountain.orm的连接池，也不使用标准库的连接池。默认是false
export orm_noPool=false # 默认是false，true表示不用连接池
# orm_databasePool开头的是fountain.orm.DatabasePool的配置项
export orm_databasePoolInitSize=1 # 初始连接数
export orm_databasePoolMinSize=1 # 最小连接数
export orm_databasePoolMaxSize=1 # 最大连接数
export orm_databasePoolCheckOnCreation=true # 创建连接时是否检查连接有效性，默认是false
export orm_databasePoolCheckOnBorrowing=true # 获取连接时是否检查连接有效性，默认是true
export orm_databasePoolCheckOnReturning=false # 归还连接时是否检查连接有效性，默认是true
export orm_databasePoolIdleTimeout=0 # 连接闲置时间，默认是0，表示闲置不过期
export orm_databasePoolConnectionLife=86400 # 连接存活时间，默认是3600，单位是秒
export orm_databasePoolCheckInterval=300 # 连接有效性检查周期，默认是300，单位是秒
export orm_databasePoolConnectTimeout=50 # 默认是50，单位是毫秒，从fountain.orm.DatabasePool获取连接的超时时间
export orm_databasePoolCheckSql='select 1' # 检查连接有效性的SQL，默认是select 1
# orm_stdPool开头的是std.datasource.sql.PooledDatasource的配置项
export orm_stdPoolMaxSize=10 # 连接池最大连接数
export orm_stdPoolMaxIdleSize=10 # 连接池最大空闲连接数
export orm_stdPoolIdleTimeout=86400 # 连接闲置时间，默认是10分钟
export orm_stdPoolMaxLifeTime=86400 # 连接存活时间，默认30分钟
export orm_stdPoolConnectionTimeout=86400 # 连接获取超时时间，默认30分钟
export orm_stdPoolKeepaliveTime=86400 # 连接保活检查周期，默认1分钟
# orm_transactionalFuncExecution 和@Transactional注解只要有一个生效就会将事务切面织入到函数
export orm_transactionalFuncExecution='*..*ServiceImpl.delete*(**): *'
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.remove*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.save*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.add*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.new*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.create*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.update*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.change*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*ServiceImpl.register*(**): *"
export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*..*.userSession(**): *"
export opengauss_orm_connectionUrl=$POSTGRES # postgres URL
# export mysql_orm_indexStartsWithZero=false # orm_indexStartsWithZero的默认值是true
```

## 导入
```cj
import fountain::f_orm.*
import fountain::f_orm.macros.*
```

## `RootDAO`
```cj
/**
 * 所有的DAO接口都要继承本接口
 */
public interface RootDAO {
    /**
     * 本接口函数不必实现，所有DAO都是SqlExecutor的扩展，SqlExecutor已经提供了相同声明的属性，
     * 且SqlExecutor已经实现本接口，故任意DAO接口可以直接调用本属性
     */
    prop executor: SqlExecutor
    /**
     * 所有的arg函数都会返回'?'作为SQL参数占位符
     * 对于Option类型的arg函数形参，会从Some(x)提取参数值，如果arg函数实参是None会添加null参数值
     */
    func arg(value: Bool): String
    func arg(value: ?Bool): String
    func arg(value: Int8): String
    func arg(value: ?Int8): String
    func arg(value: UInt8): String
    func arg(value: ?UInt8): String
    func arg(value: Int16): String
    func arg(value: ?Int16): String
    func arg(value: UInt16): String
    func arg(value: ?UInt16): String
    func arg(value: Int32): String
    func arg(value: ?Int32): String
    func arg(value: UInt32): String
    func arg(value: ?UInt32): String
    func arg(value: Int64): String
    func arg(value: ?Int64): String
    func arg(value: UInt64): String
    func arg(value: ?UInt64): String
    func arg(value: Float16): String
    func arg(value: ?Float16): String
    func arg(value: Float32): String
    func arg(value: ?Float32): String
    func arg(value: Float64): String
    func arg(value: ?Float64): String
    func arg(value: BigInt): String
    func arg(value: ?BigInt): String
    func arg(value: Decimal): String
    func arg(value: ?Decimal): String
    func arg(value: Rune): String
    func arg(value: ?Rune): String
    func arg(value: String): String
    func arg(value: ?String): String
    func arg(value: InputStream): String
    func arg(value: ?InputStream): String
    func arg(value: Duration): String
    func arg(value: ?Duration): String
    func arg(value: DateTime): String
    func arg(value: ?DateTime): String
    func arg(value: Array<Byte>): String
    func arg(value: ?Array<Byte>): String
    /**
     * 参数类型是fountain::f_data.Data，可以从Data的各个实现类型得到具体的SQL参数值
     */
    func arg(value: Data): String
    func arg(value: Any): String
    /**
     * 用于SQL表达式IN
     */
    func arg<I, T>(value: I): String where I <: Iterable<T>
    /** 
     * 添加SQL实参null 
     */
    func argNull(): String 
    /**
     * 动态SQL条件
     * @param condition 为true时把partial 添加到SQL，value添加到SQL参数列表
     */
    func meet(condition: Bool, partial: String, value: Any): String
    /**
     * 动态SQL条件
     * @param condition 为true时把partial 添加到SQL，value()的返回值添加到SQL参数列表
     */
    func meet(condition: Bool, partial: String, value: () -> Any): String
    /**
     * ChooseCondition实例会将第一个返回true的条件闭包所对应的SQL和参数闭包添加到构造的SQL末尾和SQL参数列表，忽略其它闭包
     */
    prop choose: ChooseCondition
    /**
     * LoopCondition用来遍历values并执行添加到LoopCondition的闭包，用values内的元素构造SQL片段
     */
    func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T>
    /**
     * 遍历value，构造IN (?, ?, ...)
     */
    func IN<I, T>(value: I): String where I <: Iterable<T>
    /**
     * 遍历value，构造NOT IN (?, ?, ...)
     */
    func NOT_IN<I, T>(value: I): String where I <: Iterable<T>
    /**
     * 返回一条SELECT SQL，并用返回的SQL构造EXISTS (SELECT ...)
     */
    func EXISTS(exists: () -> String): String
    /**
     * 返回一条SELECT SQL，并用返回的SQL构造NOT EXISTS (SELECT ...)
     */
    func NOT_EXISTS(exists: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的','，并用这个SQL构造SET子句
     */
    func SET(partial: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的and和or（and和or不分大小写），并用这个SQL构造WHERE子句。
     */
    func WHERE(partial: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的and和or（and和or不分大小写），并用这个SQL构造WHERE子句。
     * 闭包内调用的每两个meet choose返回的SQL片段中间都会用delimiter分割
     */
    func WHERE(delimiter: String, partial: () -> String): String
    /**
     * 裁剪partial开头的prefix，结尾的suffix，将裁剪后的字符串追加到当前构造的SQL后面
     */
    func trim(prefix!: String, suffix!: String, partial!: () -> String): String
}
```
## `LoopCondition`
```cj
public class LoopCondition<I, T> where I <: Iterable<T> {
    LoopCondition(private let values: I, private let executor: SqlExecutor)
    /**
     * LoopCondition构造的SQL片段左边插入left，右面插入right
     */
    public func wrap(left: String, right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段左边插入left
     */
    public func wrapLeft(left: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段右面插入right
     */
    public func wrapRight(right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，左边裁剪left，右边裁剪right
     */
    public func trim(left: String, right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，左边裁剪left
     */
    public func trimLeft(left: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，右边裁剪right
     */
    public func trimRight(right: String): LoopCondition<I, T> 
    /**
     * 遍历每个迭代器元素所得到的SQL片段后面都追加本函数实参
     */
    public func delimiter(d: String): LoopCondition<I, T> 
    /**
     * SQL参数是否添加到SQL中
     */
    public prop argInSql: LoopCondition<I, T> 
    /**
     * 遍历迭代器元素和当前的元素索引作为闭包参数，如果闭包返回true就执行partial闭包，忽略返回false的那些元素
     */
    public func condition(cond: (T, Int64) -> Bool): LoopCondition<I, T> 
    /**
     * 如果condition闭包返回true，就用迭代器元素和元素索引作为闭包参数，返回的元组第一个元素是SQL片段，第二个元素是SQL参数
     */
    public func partial(partial: (T, Int64) -> (String, Any)): LoopCondition<I, T> 
    /**
     * 如果condition闭包返回true，就用迭代器元素和元素索引作为闭包参数，返回的是SQL参数
     */
    public func partial(partial: (T, Int64) -> Any): LoopCondition<I, T> 
    /**
     * 遍历迭代器并执行以上闭包
     */
    public func done(): String
}
```

## `ChooseCondition`
```cj
/**
 * 只向SQL添加注册进来的第一个条件闭包是true的SQL片段
 */
public class ChooseCondition {
    public ChooseCondition(private let executor: SqlExecutor) {}
    /**
     * 调用一次确认将SQL参数添加到SQL中，不调用则是将SQL参数添加到SQL参数列表并向SQL添加?作为参数占位符
     */
    public prop argInSql: ChooseCondition 
    /**
     * SQL条件闭包，可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func condition(condition: () -> Bool): ChooseCondition 
    /**
     * 返回的元组第一个元素是添加到SQL的片段，第二个元素是SQL参数。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> (String, Any)): ChooseCondition 
    /**
     * 返回的是SQL参数。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> Any): ChooseCondition 
    /**
     * 返回的是SQL片段。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> String): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的元组第一个元素是添加到SQL的片段，第二个元素是SQL参数。
     */
    public func otherwise(partial: () -> (String, Any)): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的是SQL片段。
     */
    public func otherwise(partial: () -> String): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的是SQL参数。
     */
    public func otherwise(partial: () -> Any): ChooseCondition 
    /**
     * 执行添加进来的闭包，将第一个返回true的condition对应的partial添加到SQL。
     * 如果没有condition返回true，执行othersize，如果没有指定otherwise则不添加新的SQL片段也没有参数
     */
    public func done(): String 
}
```

## 声明DAO接口
使用本ORM的全部代码都在DAO接口函数，不必声明DAO接口的实现
```cj
import fountain::f_orm.*
import fountain::f_orm.macros.*

//下面这样就声明了一个名为UserDAO的DAO接口
@DAO//这个宏不可省略，这个宏会把它修饰的接口扩展到SqlExecutor，
    //同一个包可以导入多个DAO接口，这些接口的函数最好不要构成重载，否则可能导致函数重定义或者导致令人费解的状况
public interface UserDAO <: RootDAO {//必须是RootDAO的子接口
    /**
     * arg 函数是RootDAO的成员，这个函数会把它的实参填充到SQL参数列表，并返回字符串'?'作为SQL参数占位符
     * executor是RootDAO的属性，它的类型是SqlExecutor，SqlExecutor是ORM的核心，主要功能都在这个类
     */
    func register(username: String, password: String): Int64 {
        executor.setSql('''
            insert into user_info(
                        username,
                        password)
                 values(${arg(username)}, 
                        ${arg(password)}) 
            returning id'''//这是postgres 语法
        ).insert//执行insert，返回的是刚插入记录的主键
    }
    func changePassword(username: String, password: String): Int64 {
        executor.setSql('''
            update user_info
               set "password" = ${arg(password)}
             where username = ${arg(username)}'''
        ).update//执行update sql，返回的是修改的行数
    }
    func findUser(id: Int64): UserPO {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).first<UserPO>().getOrThrow()//返回查询结果的第一行记录
    }
    func findUserToMap(id: Int64): Map<String, Any> {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).firstToMap()//把第一行查询结果映射为一个HashMap，KEY是列名或列别名
    }
    func listUsers(): Pagination<UserPO> {
        //从FROM的泛型实参是得到表名，page的泛型实参是将查询结果映射到的类型
        executor.FROM<UserPO>()
        .WHERE{//WHERE函数会把尾闭包内的每一次meet函数调用结果拼到SQL内，并且会裁剪掉开头和结尾的and 和or
            //meet是RootDAO的成员函数，第二个参数会成为SQL的一部分，尾闭包返回的字符串会添加到SQL参数列表，
            //meet函数会把'?'拼到SQL参数相应的位置作为SQL参数占位符
            meet(username.size > 0, ' username like '){'%${username}%'}
            meet(password.size > 0, 'and "password" like '){'%${password}%'}
        }
        .page<UserPO>(10, page: 1)//返回映射类型UserPO对应的表的分页查询结果，本次查询一页10行，返回第一页
    }
    func deleteUser(id: Int64): Int64 {
        executor.setSql('''
            delete 
              from user_info
             where id = ${arg(id)} 
        '''
        ).delete//执行delete，返回的是删除的行数
    }

}
```

## 数据映射
现在支持表和类实例的映射，一对一和一对多的级联映射，映射类的成员类型是另一个映射类时会实现一对一的级联映射，当映射类的成员类型是另一个映射类的集合时会实现一对多的级联映射。

### `@QueryMappersGenerator`和`@QueryMappersGenerator[attr]`
`@QueryMappersGenerator`宏修饰的类即为映射类，宏会自动为它修饰的类添加`QueryMappersInit<T>`接口实现，`T`是宏修饰的类型。这个宏必须跟@ORMField配合使用。
`@QueryMappersGenerator`宏的属性格式：
  dirty 指定这个属性的表示被此宏修饰的类的属性发生变化时会向ORM标记修改历史，可以调用`executor.update<T>(dirty:true)`更新修改过的属性，
        本属性没有值只有属性名。
        只有被@ORMField修饰的成员变量才对dirty生效。
  table: 是一个字符串或标识符，表示列名转换的格式，
         可以是LowerUnderScore、UpperUnderScore、Pascal，会把Pascal风格的类名转换成指定风格的名称，并把转换结果作为表名，也可以是表名本身。
  classPrefix: 是一个字符串或标识符，把类名开头匹配的子串裁掉，映射的表名不包含这部分
  classSuffix: 是一个字符串或标识符，把类名结尾匹配的子串裁掉，映射的表名不包含这部分
  tablePrefix: 是一个字符串或标识符，在转换后的表名前面加上这个前缀
  tableSuffix: 是一个字符串或标识符，在转换后的表名后面加上这个后缀
  上面的冒号也是宏属性的一部分。
  如果宏属性只有一个，且不是dirty，就把它当作tableName处理。
  如果没有宏属性或只有一个dirty属性，则把类名按照Pascal风格转成LowerUnderScore。
如果要把fountain.data.macros.DataAssist跟@QueryMappersGenerator一起使用，需要满足以下条件：
1. 不要对被修饰类使用DataAssist宏的props属性，@QueryMappersGenerator会为被修饰类添加属性
2. 如果要复制实例成员或者把类的实例转换为JsonValue，@QueryMappersGenerator要先于@DataAssist展开，
   即@DataAssist要在@QueryMappersGenerator前面。
3. 如果没有2. 这种需求，则二者顺序没有要求，但是1. 还需要满足。

### `@ORMField`和`@ORMField[attr]`
使用宏@ORMField 修饰public mut prop或public var指定当前属性或成员变量是不是主键以及映射的列名，所有的仓颉mut prop必须是驼峰命名法。
@ORMField[true LowerUnderScore] 表示当前属性映射主键，属性名转为LowerUnderScore就是列名，列的类型是dataType。
@ORMField[true "column_name"] 表示当前属性映射主键，不论属性名是什么列名一定是"column_name"。
第一部分可以是true或false，true表示当前属性映射主键，false表示映射的不是主键。
@ORMFIeld[id column: LowerUnderScore converter: 'org::pkg.ConverterQualifiedTypeName']
@ORMField[id column: "column_name" converter: 'beanNameOfConverter'] 
id 是一个单属性，表示当前ORMField修饰的成员映射主键
column: 列名转换的格式，可以是LowerUnderScore、UpperUnderScore、Pascal、Camel，会把Camel风格的类名转换成指定风格的名称，并把转换结果作为列名，
        column对应的值是是标识符，又不是LowerUnderScore、UpperUnderScore、Pascal、Camel之一的，把标识符作为列名
        如果column对应的值是字符串，这个字符串就是映射的列名，
        如果没有指定column，会把ORMField修饰的成员名称转换成LowerUnderScore风格，并把转换结果作为列名
converter: 对应的值是数据转换器的名称，可以是`fountain::f_bean`管理的bean名称，也可以是`fountain::f_orm.QueryMapperConverter`的子类全限定名。指定了converter的被映射成员类型必须是`fountain::f_data.DataFields<T>`的子类型。
每一部分都是可选的，且两种属性风格可以混用。
没有使用@ORMField注解的成员认为映射的不是主键，且按照列名是LowerUnderScore处理。

### 例子
```cj
@DataAssist[fields tostring]//同时使用@DataAssist 和 @QueryMappersGenerator，@DataAssist必须在上面
@QueryMappersGenerator[table: user_info dirty]//映射的表名是user_info，且可以使用executor.update<UserPO>(dirty: true)更新脏数据
public class UserPO {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['username']
    private var username: String = ''
    @ORMField['password']
    private var password: String = ''
    @ORMField['save_time']
    private var saveTime: ?DateTime = None<DateTime>
}

@QueryMappersGenerator[classSuffix: 'PO' table: LowerUnderScore tablePrefix: 't_']//映射的表名是t_user_info
public class UserInfoPO {//不要使用这个类，仅用于展示@QueryMappersGenerator的用法
    @ORMField[true 'id']
    private var id: Int64 = 0
    @ORMField['username']
    private var username: String = ''
    @ORMField['password']
    private var password: String = ''
    @ORMField['save_time']
    private var saveTime: ?DateTime = None<DateTime>
    @ORMField[column: 'user_props' converter: 'fountain::f_orm.QueryMapperJsonConverter']
    private var userProps: UserProps = UserProps()
}

@DataAssist[props fields]//所有基本类型、DateTime、Duration、Jsonvalue、String和被@DataAssist修饰的类，以及Option<T>泛型实参是这些类型的，都是fountain::f_data.DataFields<T>的子类型
public class UserProps {
    private var registerTime: ?DataTime = None<DateTime>
    private var lastLoginTime: ?DataTime = None<DateTime>
    private var lastLoginIp: String = ''
    private var lastLoginDevice: String = ''
}
```

## `RootService`
业务层的类型必须实现以下接口
```cj
public interface RootService {
    /**
     * 用参数name指定的驱动名创建一个SqlExecutor实例，每个线程每个驱动名对应一个SqlExecutor实例
     */
    func executor(name: String): SqlExecutor
    /**
     * 使用默认的驱动名得到一个SqlExecutor实例，每个线程每个驱动名对应一个SqlExecutor实例
     */
    func executor(): SqlExecutor
}
```

## 事务
- 使用配置项`orm_transactionalFuncExecution`指定事务切面织入规则，这个规则就是`fountain::f_aspect模块的织入规则`
- 或者为需要织入事务的函数使用`@Transactional`注解
- 完成以上任意一步以后为需要织入事务的类用`@TransactionalService`修饰，这个宏同时完成了IOC`@Bean`和AOP`@Pointcut`的工作。
### `@Transactional`
```cj
@Annotation[target: [MemberFunction]]
public class Transactional {
    public const Transactional(
        public let driverName!: String = '',//驱动名
        public let propagation!: ?Propagation = None, //事务传播策略
        public let isoLevel!: ?TransactionIsoLevel = None,//事务隔离级别
        public let accessMode!: ?TransactionAccessMode = None,//事务访问模式
        public let deferrableMode!: ?TransactionDeferrableMode = None,//事务延迟械
        public let rollbackFor!: String = '',//业务发生异常时需要回滚的异常名
        public let noRollbackFor!: String = ""//业务发生异常时不回滚的异常名
        //如果同时指定了noRollbackFor 和rollbackFor，先执行noRollbackFor，
        //没有异常的noRollbackFor异常再执行rollbackFor，
        //还没有匹配的rollbackFor异常执行整个事务的回滚
    ) {}

    public func getPropagation(): Propagation 
    public func getIsoLevel(): ?TransactionIsoLevel 
    public func getAccessMode(): ?TransactionAccessMode 
    public func getDeferrableMode(): ?TransactionDeferrableMode 
}
```
### 事务传播策略
```cj
package fountain::f_orm.wrap

/*
 * RequiresNew 和 NotSupported 会创建新连接，在这两个特性的作用范围内如果有其它传播特性判定还是以原连接是否创建了事务为依据。
 * 多个指定事务的函数嵌套调用的时候由事务传播枚举决定是创建新的事务还是复用外层函数的事务。
 */
public enum Propagation {
    | Required //外层函数开启了事务就使用这个事务，如果没有事务就创建一个新事务。
    | Supports //外层函数开启了事务就使用这个事务，如果没有事务就不用事务。
    | Mandatory //外层函数开启了事务就使用这个事务，没有事务就抛异常
    | RequiresNew //如果外层函数没有开启事务，当前函数重用外层函数的数据库连接并开启事务，如果外层函数开启了事务，就获得一个新的数据库连接，创建新事务。
    | Never //不使用事务，如果外层函数开启了事务就抛出异常。
    | NotSupported //不使用事务，如果外层函数开启了事务就获得一个新的数据库连接执行当前函数的业务。
    | Nested //如果外层函数开启了事务就开启一个新事务，否则当前函数也不使用事务。
}
```

### 事务钩子
实现以下接口的类并且这个类用`fountain::f_bean.macros`的`@Bean`宏修饰即实现了一个事务钩子，可以注册零或多个事务钩子。
```cj
public interface TransactionHook {
    /**
     * 在事务开启前执行
     */
    func beforeTx(): Unit {}
    /**
     * 在事务提交前执行
     */
    func beforeCommit(readOnly: Bool): Unit {}
    /**
     * 在事务提交后执行
     */
    func afterCommit(): Unit {}
    /**
     * 在事务中抛出异常时执行
     */
    func afterThrowing(e: Exception): Unit {}
    /**
     * 事务回滚前执行
     */
    func beforeRollback(e: Exception): Unit {}
    /**
     * 事务回滚后执行
     */
    func afterRollback(e: Exception): Unit {}
    /**
     * 事务结束后执行
     */
    func afterComplete(status: TransactionStatus): Unit {}
    /**
     * 用于决定钩子的执行顺序
     */
    prop order: Int64 {
        get() {
            Int64.Max
        }
    }
}
```

## 动态SQL的高级API
```cj
//SqlExecutor扩展了这个接口
public interface SqlPartial <: RootDAO {
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造insert into values前的部分。
     * @param ignoreColumns 忽略的列名，遍历映射类型所有的公共成员，得到它们对应的列名，忽略本参数指定的那些
     */
    func INTO<T>(ignoreColumns!: Array<String>): IntoClause<T> where T <: QueryMappersInit<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造insert into。
     * @param values，遍历泛型类型的实例所有公共成员，得到它们的值作为insert into values的值
     * @param ignoreColumns 忽略的列名，遍历映射类型的所有公共成员，得到它们对应的列名，忽略本参数指定的那些
     * @return 返回的是刚插入的ID
     */
    func INTO<T>(values: T, ignoreColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update
     */
    func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，values必须包含主键键值对
     */
    func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，id是要修改的表的主键值
     */
    func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update。
     * @param values 要更新的数据
     * @param ignoredColumns 忽略的列
     * @param includingColumns 要更新的列
     * @param dirty 只更新values内修改过的那些列。被@QueryMappersGenerator修饰的类，修改它们的公共实例属性时内部会记录修改过的属性。本函数会把这些属性名对应的列名作为includingColumns递归调用自身。
     * @return 更新的行数。这个函数会使用主键更新数据，返回的值要么是0，要么是1.
     * ignoredColumns includingColumns dirty，每次调用最多只能传其中一个，或者都不传，都不传时会更新T所有公共实例属性对应的列
     */
    func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 将泛型类型T作为映射类型，用映射的表名构造update。
     * @param values 要更新的数据
     * @param ignoredColumns 忽略的列
     * @param includingColumns 要更新的列
     * @return 更新的行数。这个函数会使用主键更新数据，返回的值要么是0，要么是1.
     * ignoredColumns includingColumns，每次调用最多只能传其中一个，或者都不传，都不传时会更新T所有公共实例属性对应的列
     */
    func UPDATE<T>(values: T, ignoredColumns!: Array<String>, includingColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * 用泛型类型T构造delete from 或select ... from 
     */
    func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T>
    /**
     * 分页查询
     * @param sql 基于此sql添加分页子句
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func page<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R>
    /**
     * 分页查询，返回列索引是0的数据
     * @param sql 基于此sql添加分页子句
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func singlePage<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R>
    /**
     * 分页查询，返回列索引是0的数据
     * @param sql 基于此sql添加分页子句
     * @param column 返回列索引是column的数据
     * @param size 每页返回的行数
     * @param page 返回第page页，page从1开始
     * @return 分页数据
     */
    func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R>
    /**
     * 返回sql中列索引是0的第一行数据
     */
    func singleFirst<T>(sql: String): ?T
    /**
     * 返回sql中列索引是column的第一行数据
     */
    func singleFirst<T>(sql: String, column: Int64): ?T
    /**
     * 返回sql中列索名是column的第一行数据
     */
    func singleFirst<T>(sql: String, column: String): ?T
    /**
     * 返回sql查询结果，并使用mappers映射为泛型类型T，如果没查到数据返回None<T>
     */
    func first<T>(sql: String, mappers: QueryMappers<T>): Option<T> 
    /**
     * 返回sql查询结果，泛型类型T是数据映射类型，如果没有查到数据返回None<T>
     */
    func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T> 
    /**
     * 将刚构造的SQL添加到当前的SqlExecutor
     */
    public func setSql(sql: String, clearArgsAfterExec!: Bool = true): SqlExecutor
    /**
     * 将刚构造的SQL添加到当前的SqlExecutor
     */
    public operator func ()(sql: String): SqlExecutor
}
```
```cj
abstract sealed class TableClause<T> <: ToString where T <: QueryMappersInit<T>{...}

public abstract class ExceptInsertClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    /**
     * 内联接
     */
    public func INNER_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 左外联接
     */
    public func LEFT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 右外联接
     */
    public func RIGHT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 全联接
     */
    public func FULL_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> 
    /**
     * 闭包用来构造SQL逻辑表达式
     */
    public func WHERE(condition: () -> Unit): This 
    /**
     * condition是WHERE后面的逻辑表达式
     */
    public func WHERE(condition: String): This 
    public func AND(condition: () -> Unit): This 
    public func AND(condition: String): This 
    public func OR(condition: () -> Unit): This 
    public func OR(condition: String): This 
    public func NOT(condition: () -> Unit): This 
    public func NOT(condition: String): This 
    /**
     * 用()包含构造的逻辑SQL片段
     */
    public func PAREN(condition: () -> Unit): This 
    /**
     * 用()包含condition
     */
    public func PAREN(condition: String): This 
    /**
     * 用()包含condition构造的SQL片段，在(前面添加op
     */
    public func PAREN(op: CondRelOp, condition: () -> Unit): This 
    /**
     * 用()包含condition，在(前面添加op
     */
    public func PAREN(op: CondRelOp, condition: String): This 
    /**
     * 添加order by 子句
     */
    public func ORDER_BY(orderBy: () -> String): This 
    /**
     * 添加分页子句，会按照SqlExecutor包含的驱动名找到对应的数据库SQL方言
     */
    public func LIMIT(size: Int64, offset!: Int64 = 0): This 
}
```
```cj
public class FromClause<T> <: ExceptInsertClause<T> where T <: QueryMappersInit<T> {
    /**
     * 基于此对象的数据构造DELETE SQL
     */
    public func DELETE(): Int64 
    public func DELETE(sql: String): Int64 

    public func GROUP_BY(groupBy: () -> String): This 
    public func HAVING(condition: () -> Unit): This 
    public func HAVING(condition: String): This 
    public func HAVING(arg: Map<String, Any>, condition: () -> String): This 
    public func HAVING<T>(arg: T, condition: () -> String): This where T <: ObjectData<T> 
    /**
     * 按主键查询
     */
    public func findById(id: Int64): ?T 
    /**
     * 按主键查询
     */
    public func findById(id: UInt64): ?T 
    /**
     * 按主键查询
     */
    public func findById(id: String): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: Int64): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: UInt64): ?T 
    /**
     * 按主键删除
     */
    public func deleteById(id: String): ?T 
    
    public func first<T>(): ?T where T <: QueryMappersInit<T> 
    public func first<T>(columns: String): ?T where T <: QueryMappersInit<T> 
    public func singleFirst<T>(column: String): ?T 
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T> 
    public func list<T>(columns: String): ArrayList<T> where T <: QueryMappersInit<T> 
    public func singleList<T>(): ArrayList<T> 
    public func singleList<T>(column: String): ArrayList<T> 

    public func count(): Int64 
    public func singlePage<R>(size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> 

    public func singlePage<R>(column: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> 
    
    public func page<R>(size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> 
    public func page<R>(columns: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> 
}
```
```cj
public class UpdateClause<T> <: ExceptInsertClause<T> where T <: QueryMappersInit<T> {
    public func SET(set: () -> String): This 
    public func SET(arg: Map<String, Any>, condition: () -> String): This 
    public func SET<T>(arg: T, condition: () -> String): This where T <: ObjectData<T> 
    public func execute(): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: Int64): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: UInt64): Int64 
    /**
     * 按主键更新
     */
    public func byId(id: String): Int64 
}
```
```cj
public class IntoClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    /**
     * 构造INSERT INTO的VALUES子句，value的每个公共实例属性和公共实例变量是VALUES子句的实参，每个实例成员对应一个?作为SQL参数占位符
     */
    public func VALUES<D>(value: D): This where D <: ObjectData<D> 
    /**
     * 构造INSERT SQL的SELECT ${selectColumns}
     */
    public func SELECT<T>(selectColumns: String): This where T <: QueryMappersInit<T> 
    /**
     * 构造INSERT SQL的SELECT 子句
     * @param selectColumns SELECT子句的查询列
     * @param fromClause SELECT 的from where group by order by 和分页子句的闭包
     */
    public func SELECT<T>(selectColumns: String, fromClause: (FromClause<T>) -> Unit): This where T <: QueryMappersInit<T> 
    /**
     * 构造ON DUPLICATE KEY UPDATE ...
     */
    public func ON_DUPLICATE_KEY_UPDATE(columns: ()-> String): This 
    /**
     * 构造ON CONFLICT columns DO UPDATE SET ...
     */
    public func ON_CONFLICT(columns: Array<String>, DO_UPDATE_SET!: () -> String): This 
    /**
     * 执行insert into，返回刚插入的主键
     */
    public func execute(): Int64
}
```
### 分页类型`Pagination<T>`
```cj
/**
 * 分页对象
 *
 * @param <T> 泛型，数据映射类型
 * @param page 当前页码
 * @param size 每页大小
 * @param pages 总页数
 * @param rows 总记录数
 * @param list 数据列表
 */
public class Pagination<T> <: ObjectData<Pagination<T>> where T <: DataFields<T> {
    public let pages: Int64
    public Pagination(
        public let page!: Int64,
        public let size!: Int64,
        public let rows!: Int64,
        public let list!: ArrayList<T>
    ) 
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: () -> ArrayList<T>)
    public init(page!: Int64, size!: Int64, rows!: Int64, list!: (Int64, Int64) -> ArrayList<T>)
    public func toData(): Data 
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any 
    public static func dataFields(): ObjectFields 
}
```

## `SqlExcutor`
```cj
public class SqlExecutor <: Resource & RootDAO {
    /**
     * 如果是select开头就返回true
     */
    public prop isReadOnly: Bool
    /**
     * DAO接口必须声明相同的属性，不必真的提供实现。所有的DAO都是SqlExecutor的扩展
     * SqlExecutor提供的实现是返回自身
     */
    public prop executor: SqlExecutor
    public func isClosed(): Bool
    public func close(): Unit
    /**
     * 启动新事务
     */
    public func newTxAndBegin(
        propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
        isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
        accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
        deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName)
    ): SqlExecutor
    /**
     * 提交
     */
    public func commit(): Unit
    /**
     * 回滚
     */
    public func rollback(): Unit
    /**
     * 回滚到指定的savepoint
     */
    public func rollback(savepoint: String): Unit
    /**
     * 异常类型是e的实际类型时不回滚而是执行提交，除非提交时又发生异常
     */
    public func noRollbackFor(e: Exception): Exception
    /**
     * 异常类型是e的实际类型时才执行回滚
     */
    public func rollbackFor(e: Exception): Exception
    /**
     * 执行本函数前必须先启动一个事务，然后执行callee，最后commit。
     * 本函数不执行回滚。
     */
    public func callAndCommit<T>(callee: () -> T): T
    /**
     * 为当前事务指定savepoint
     */
    public func save(savepoint: String): Unit
    /**
     * 释放指定的savepoint
     */
    public func release(savepoint: String): Unit
    /**
     * 执行udpate，当前SqlExecutor维持的SQL必须是UDPATE，返回更新的行数
     */
    public prop update: Int64
    /**
     * 执行delete，当前SqlExecutor维持的SQL必须是delete，返回删除的行数
     */
    public prop delete: Int64
    /**
     * 执行insert，当前SqlExecutor维持的SQL必须是insert，否则会出错，返回刚插入的主键
     */
    public prop insert: Int64
    /**
     * 返回第一行列索引是0的那一列
     */
    public func singleFirst<T>(): Option<T>
    /**
     * 返回第一行列索引是index的那一列
     */
    public func singleFirst<T>(index: Int64): Option<T>
    /**
     * 返回第一行列名或别名是column的那一列
     */
    public func singleFirst<T>(column: String): Option<T>
    /**
     * 返回索引是0的那一列的全部查询结果
     */
    public func singleList<T>(): ArrayList<T>
    /**
     * 返回列索引是index的那一列的全部查询结果
     */
    public func singleList<T>(index: Int64): ArrayList<T>
    /**
     * 返回列名或列别名是column的那一列的全部查询结果
     */
    public func singleList<T>(column: String): ArrayList<T>
    /**
     * 返回的迭代器可以遍历列索引是0的那一列的全部查询结果
     */
    public func singleIterator<T>(): Iterator<T>
    /**
     * 返回的迭代器可以遍历列索引是index的那一列的全部查询结果
     */
    public func singleIterator<T>(index: Int64): Iterator<T>
    /**
     * 返回的迭代器可以遍历列名或列别名是column的那一列的全部查询结果
     */
    public func singleIterator<T>(column: String): Iterator<T>
    /**
     * 按照指定的映射类型将第一行查询结果映射为泛型类型并返回，如果没有查到数据返回None<T>
     */
    public func first<T>(mappers: QueryMappers<T>): Option<T>
    /**
     * 将第一行查询结果映射为泛型类型并返回，如果没有查到数据返回None<T>
     */
    public func first<T>(): Option<T> where T <: QueryMappersInit<T>
    /**
     * 将查到的第一行数据映射为HashMap，KEY是select 列名
     */
    public func firstToMap(): Map<String, Any>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回查询结果的ArrayList<T>
     */
    public func list<T>(mappers: QueryMappers<T>): ArrayList<T>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回查询结果的ArrayList<T>
     */
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T>
    /**
     * 将查到的所有数据映射为HashMap，Map的KEY是select列名，并返回查询结果的ArrayList<T>
     */
    public func mapList(): ArrayList<HashMap<String, Any>>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回一个迭代器
     */
    public func iterator<T>(mappers: QueryMappers<T>): QueryResultIterator<T>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回一个迭代器
     */
    public func iterator<T>(): Iterator<T> where T <: QueryMappersInit<T>
    /**
     * 
     */
    public func one<T>(mappers: QueryMappers<T>): Option<T>
}
```

## 数据库表变更
现在为mysql mariadb postgres opengauss提供了自动生成变更sql的支持
### 基础接口
```cj
/**
 * 此接口的实现类要用fountain::f_bean.macros.Bean宏修饰
 */
public interface SchemaFinder {
    /**
     * 驱动名
     */
    prop driverName: String
    /**
     * 查询表结构数据
     * @param database 数据库名
     * @param tableName 表名
     * @return 列元数据的迭代器
     */
    func findTableSchema(database: String, tableName: String): Iterator<ColumnMeta>
    /**
     * 返回索引元数据的迭代器
     * @param database 数据库名
     * @param tableName 表名
     */
    func findIndexes(database: String, tableName: String): Iterator<IndexMeta>
    /**
     * 使用指定的表名和列元数据构造create table sql
     */
    func generateCreateSql(tableName: String, columns: Iterator<ColumnMeta>): Iterator<String>
    /**
     * 使用指定的表名、新的列元数据，当前数据库的元数据构造alter table sql，包括修改列名、列类型、是否not null、列默认值、添加新列、删除列等
     */
    func generateAlterSql(tableName: String, new: Array<ColumnMeta>, current: Iterator<ColumnMeta>): Iterator<String>
    /**
     * 使用指定的表名和新旧索引元数据生成索引sql，包括添加、删除索引
     */
    func generateIndexSql(tableName: String, new: Array<IndexMeta>, current: Iterator<IndexMeta>): Iterator<String>
}
```

### 表元数据
```sql
public class TableMeta{
    private TableMeta(
        public let driver: String,
        public let database: String,
        public let tableName: String,
        public let columns: Array<ColumnMeta>,
        public let indexes: Array<IndexMeta>
    ){}
}
@DataAssist[fields]
public class ColumnMeta <: Hashable & Equatable<ColumnMeta> {
    public var columnName: String = ''
    public var oldColumnName: String = ''
    public var typeName: String = ''
    public var nullable: Bool = false
    public var default: ?String = None
    public var extra: String = ''
    public var comment: String = ''
    public init(){}
    public init(schema: ColumnSchema, columnName: String)
}
@DataAssist[fields]
public class IndexMeta <: Hashable & Equatable<IndexMeta> {
    public var name: String = ''
    public var columns: String = ''
    public var unique: Bool = false
    public var def: String = ''
    public init(){}
    public init(name: String, columns: String, unique: Bool)
    public init(schema: IndexSchema)
}
```

### 表schema
表元数据变量功能生效的前提是**必须**使用这些注解修饰映射类
```cj
@Annotation[target: [Type]]
public class DatabaseSchema{
    public const DatabaseSchema(
        private let driver!: String = '',
        public let database!: String
    ){}
    public prop driverName: String {
        get(){
            if(driver.isEmpty()){
                ORM.defaultDriver
            }else{
                driver
            }
        }
    }
}

@Annotation[target: [Type]]
public class IndexSchema{
    public const IndexSchema(
        public let name!: String,
        public let columns!: String,
        public let unique!: Bool
    ){}
}

@Annotation[target: [MemberProperty, MemberVariable]]
public class ColumnSchema{
    public const ColumnSchema(
        /**
         * 如果列名发生了变化，需要注明旧的列名，宏@ORMField['new_column_name']标注新的列名。
         */
        public let oldColumnName!: String = '',
        public let typeName!: String,
        public let nullable!: Bool = false,
        public let default!: ?String = None,
        public let extra!: String = '',
        public let comment!: String = ''
    ){}
}
```

### 操作表数据变更
执行命令`fboot dbmigro --dylibPattern='需要加载的动态链接库文件名的正则表达式' [--mode|-m file|auto|dry|interactive]`
命令会向控制台输出生成的DDL
- file 会在工作路径生成.migro.sql文件保存生成的DDL。
- auto 会自动执行生成的DDL
- dry 仅向控制台输出生成的DDL
- interactive 会在向控制台输出生成的全部DDL后询问用户是否执行
- `--mode`参数没有默认值，如果不是以上四个值会抛出异常