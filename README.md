```
  _____                    __         .__
_/ ____\____  __ __  _____/  |______  |__| ____
\   __\/  _ \|  |  \/    \   __\__  \ |  |/    \
 |  | (  <_> )  |  /   |  \  |  / __ \|  |   |  \
 |__|  \____/|____/|___|  /__| (____  /__|___|  /
                        \/          \/        \/
```

![fountain](.assets/README/fountain.png)

# fountain

## 介绍

一个用于服务器应用开发的综合工具库。

- 零配置文件
- 环境变量和命令行参数配置
- 约定优于配置
- 深刻利用仓颉语言特性
- 只需要开发动态链接库，fboot负责加载、初始化并运行。

## 版本管理

### 分支
待功能完备后将按以下流程跟随仓颉版本，功能完备以前一直跟随最新的开发版。

- 每月仓颉开发版对应一个`canary/${CANARY_CANGJIE_VERSION}`
- 每次发仓颉sts版，将对应的开发版转为`sts/${BETA_CANGJIE_VERSION}`，删除对应的开发版
- 功能完备后的长期支持版作为master分支
  - 此后master分支跟随最新的长期支持版
  - 每次仓颉升级LTS
    - 从对应的beta版建分支`lts/${LTS_CANGJIE_VERSION}`
    - 删除对应beta版
    - lts版本完成测试合并到master，创建版本`release-${main}.${sub}.${bug}.${CANGJIE_VERSION}`
      - main：有新功能
      - sub：功能变更
      - bug：修改BUG
      - CANGJIE_VERSION：取当前仓颉长期支持版前两位，比如当前仓颉长期支持版是1.0.x，CANGJIE_VERSION就是1_0。

### 版本
- canary/ sts/ lts/开头的是分支，不是tag
- 当分支稳定了会用相应分支建tag
  - 假设有分支`canary/0.0.1.0_60`且fountain没有对应下一个canary版本仓颉SDK的canary分支，则这个分支稳定以后会建tag：`canary-0.0.1.0_60`。
  - 不一定每个仓颉canary版本都有一个对应的分支
  - 不一定每个canary分支都对应建一个canary版本
  - 仓颉的每个sts lts版本都会对应一个sts/ lts/分支
  - 每个sts/ lts/分支一定会有对应的版本

## 加载本项目的动态链接库

- 如果仅仅是开发使用，可以使用cjpm run当前依赖fountain的项目，就自动加载了。
- 如果是在Linux服务器环境运行，
  - 将fountain动态链接库所在的路径加入环境变量`export FOUNTAIN_HOME=/path/of/fountain_dynamic_libs`。
  - 将本项目编译的动态链接库都加入环境变量`export LD_LIBRARY_PATH=$FOUNTAIN_HOME:$LD_LIBRARY_PATH`。
  - 或者把子项目`fountain/fboot`的构建结果原样复制到`FOUNTAIN_HOME`，把`fountain/fboot/fboot`脚本复制到`FOUNTAIN_HOME`目录，并执行`fboot export`即可自动添加环境变量

## fboot

- 把fboot加入PATH环境变量
  1. fboot run [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME>
  2. fboot shutdown <PID>
  3. fboot rerun <PID> [PATH] --dylibPattern=<DYNAMIC_LIB_NAME_REGEX_WITHOUT_EXTNAME>

## 构建
  为stdx指定环境变量，比如下面这样
  ```
  export CANGJIE_STDX_PATH=/path/of/stdx/linux_x86_64_llvm
  export CANGJIE_STDX_DYNAMIC_PATH=$CANGJIE_STDX_PATH/dynamic/stdx
  ```

## 功能

### 空集合
### 比较器Comparator Equaler

### UUID
### 常用设计模式
  - 工厂模式
  - 策略模式
  - 发布订阅模式
  - 观察者模式
  - 状态模式
### 路径匹配PathPattern
### TreeTransformer
### crc16
### murmur_hash
### DiffieHellman密钥交换协议
### CaseFormat 命名风格的字符串转换
### 文本模板，插值串在编译期就确定了，有时候需要运行期才能确定的文本模板
### 各种常用异常
### 标准库的扩展
  
  - 针对Iterator的扩展
### 对象池
### 堆缓存
#### 强引用，指定最大缓存数、过期时间的缓存
  ```cj
  let cache = HeapCache<V> where V <: Object (
    private let concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL,
    private let maxLife!: Duration = DEFAULT_HEAP_CACHE_MAX_LIFE,
    private let maxSize!: Int64 = DEFAULT_HEAP_CACHE_MAX_SIZE,
    private let checkDuration!: Duration = DEFAULT_HEAP_CHECK_CHECK_DURATION,
    private let evictionCallback!: (String, V) -> Unit = {k, v => ()}
  )
  cache.set('key', object)
  let opt: ?V = cache.get('key')
  ```
#### 延迟弱引用堆缓存

### 正则表达式DSL
### 简化属性复制的工具
### 优先级队列
### 标准库未提供的集合
### 支持大端序小端序的字节数组扩展（可以把各种数值类型按指定端序从字节数组读写）
### 功能更丰富的JSON
### CRON定时器
### ORM
### IOC
### AOP
### MVC
  - 特性
    - 各种请求方法
    - 参数
      - 路径参数
      - 请求头参数
      - application/x-www-urlencode参数
      - 各种格式的请求体
        - 可以注册满足业务需求的请求体解析逻辑
        - 默认支持json
    - 可以注册满足业务需求的响应体序列化逻辑
    - 可以上传多个文件
    - 自动生成文档
      - 自带文档请求接口
### 网络流水线
### 权限控制
### 负载均衡策略
  - 随机
  - 优先级
  - 轮转法
### id生成器
  
  - 雪花算法改
### 配置类型
### jwt

  ```cj
  let jwt = JWT().hmacSHA1(keyOfBytes)//支持标准库提供的除国密之外的全部签名算法，国密不支持HMAC故无法支持
  //JWT().hmacSHA1ByBase64Key(base64String)
  //JWT().hmacSHA1ByHexKey(hexString)
  let sign = jwt.keyId('keyId').expire(Duration.minute).addPayload('name', 'Bob').encoder().sign()
  println(sign)
  @Expect(jwt.verifier(sign).verify(), true)
  ```

- 日志

  ```cj
  import fountain.log.LoggerFactory
  let topLog = LoggerFactory.getLogger('top')
  public class Foo {
    private static let LOGGER = LoggerFactory.getLogger<Foo>()
    public func foo(){
      LOGGER.info('hello')
      LOGGER.error('hello', Exception('test'))
      LOGGER.info('hello {}', 'world')
    }
  }
  ```

  ```bash
    # 现在支持console, file, tcp, udp, unixDatagram, unix这六个日志记录器，可以随意编排不必全部出现，还可以继承f_log.AsyncLogger实现新的日志记录器
    export fountain_logger_appender_console=ConsoleLoggerName # =右边是开发者定义的日志记录器名字，用来标识配置项，控制台日志只支持一个配置，即使配置了多个也是只有第一个名字的配置生效
    export fountain_logger_appender_ConsoleLoggerName_level=ERROR
    export fountain_logger_appender_ConsoleLoggerName_pattern=..... # 控制台日志格式

    export fountain_logger_appender_file=FileLoggerName1,FileLoggerName2
    export fountain_logger_appender_FileLoggerName1_level=INFO
    export fountain_logger_appender_FileLoggerName1_path=/path/of/file/logger.log
    export fountain_logger_appender_FileLoggerName1_pattern=..... # 文件日志格式
    export fountain_logger_appender_FileLoggerName1_rotateDuration=DAY # 新建日志文件的时间周期，现在支持各种时间单位从NANOSECOND到YEAR
    export fountain_logger_appender_FileLoggerName1_rotateSize=1G # 新建日志文件的日志文件大小上限，现在支持字节数从xB和K M G T P E，大小写不限，x是任意正整数，Z Y 超过Int64上限了，B表示字节，K M G T P E后面可以带字母B也可以不带
    export fountain_logger_appender_FileLoggerName1_compressFormat=Deflate(BestSpeed) # GZip(BestSpeed) 支持标准库的Deflate和GZip以及压缩比。还有不压缩的None
    # 还支持用url的形式，path必须出现在url，其它配置项可选，可以继续以每项一个环境变量的形式指定
    export fountain_logger_appender_FileLoggerName2=file:///path/of/file/logger.log?level=INFO
    # 下面是文件日志记录器的默认选项
    # public var path = "${getWorkingDirectory()}/logs/${getCommand()}.log"
    # public var fileSize = Int64.Max
    # public var timeunit = TimeUnit.DAY
    # public var compress = LogFileCompressFormat.NonCompression
    # 默认日志格式[%level-%name] %d{yyyy/MM/dd,HH:mm:ss.SSS}|%m
    # %level 日志级别
    # %name  日志记录器的名字，这个是初始化日志记录器是从LoggerFactory.getLogger传入的名字
    # %d     日志产生时间，按照yyyy-MM-dd,HH:mm:ss.SSS格式输出
    # %d{...}日志产生时间，花括号内是时间格式
    # %m     日志内容
    # %app   当前应用名称，即当前进程名
    export fountain_logger_appender_tcp=TcpLoggerName # 也是支持英文逗号分隔的多个TcpLoggerName
    export fountain_logger_appender_TcpLoggerName_host=127.0.0.1:65535 # 这个host也是默认参数
    export fountain_logger_appender_TcpLoggerName_pattern=..... # tcp日志格式
    
    export fountain_logger_appender_udp=UdpLoggerName
    export fountain_logger_appender_UdpLoggerName_host=127.0.0.1:65534
    export fountain_logger_appender_UdpLoggerName_pattern=..... # udp日志格式

    export fountain_logger_appender_unixDatagram=UnixDatagramLoggerName
    export fountain_logger_appender_UnixDatagramLoggerName_path=/path/of/udpDatagram/file.log # 默认是/tmp/log/unixDatagram.log
    export fountain_logger_appender_UnixDatagramLoggerName_pattern=..... # unix datagram日志格式

    export fountain_logger_appender_unix=UnixLoggerName
    export fountain_logger_appender_UnixLoggerName_path=/path/of/unix/file.log # 默认是/tmp/log/unix.log
    export fountain_logger_appender_UnixLoggerName_pattern=..... # unix日志格式
  ```


### 零复制
  - MMapFile
### 响应式编程
#### 最简单用法
```cj
let observable = Observable<Int64>
.iterable([1,2,3])
.subscribe('test', FuncObserver<Int64>().setNextFunc{v => println(v)})
.withCurrent()
.defer()

observable.pause()//暂停产生新数据
// 每次获取下次数据前都会检查内部变量disposed_，disposed_是false的立即结束。dispose()修改disposed_为true。
//disposed_类型是AtomicBool
```
#### 初始化方式
1. iterable
    1. 接收一个`Iterable<T>`实例
    2. 接收一个`()->Iterable<T>`实例
    3. 接收一个`()->Future<Iterable<T>>`实例
    4. 接收一个`Future<Iterable<T>>`实例
    5. 接收一个`()->Future<Iterable<T>>`实例
2. emitter
    接收一个`(Emitter<T>) -> Unit`实例
    - `Emitter<T>`
      - onNext(T)
        发送一条数据
      - onComplete()
        发送完成事件
      - onError(Exception)
        发送异常
3. single
    1. 接收一个`T`实例
    2. 接收一个`()->T`实例
    3. 接收一个`Future<T>`实例
    4. 接收一个`()->Future<T>`实例
4. maybe
    1. 接收一个`?T`实例
    2. 接收一个`()->?T`实例
    3. 接收一个`Future<?T>`实例
    4. 接收一个`()->Future<?T>`实例
5. empty
    创建一个空的被观察者
6. concat
    1. 接收一个`Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    2. 接收一个`()->Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    3. 接收一个`Future<Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    4. 接收一个`()->Future<Iterable<Iterable<T>>>`实例，并把它展开成`Iterator<T>`

#### 注册观察者
  - subscribe(Observer<T>)
    - 可多次调用注册多个观察者
    - 由初始化时的asyncCombined参数决定是否并行执行各个观察者
    - 使用观察者类型全限定名作为名称
  - 有多个重载，还可以为观察者指定名称
#### 注销观察者
  - dispose(completion)
    强制结束，不再产生新数据。参数决定是否发送完成消息
  - dispose(name)
    注销指定名称的观察者
  - dispose<O>() 
    注销指定类型的全部观察者
  - dispose<O>(name, O) where O <: Object & Observer<T>
    注销指定名称和观察者实例，如果注册的观察者与参数不是同一实例会抛异常
  - dispose<O>(observer: O): Unit where O <: Object & Observer<T> 
    注销指定实例的观察者，如果注册的观察者与参数不是同一实例会抛异常
  - disposeAll()
    注销全部观察者
  - pause(completion!: Bool = false)
    暂停产生新数据，completion决定是否发送完成事件
  - 如果当前已经没有观察者了将暂停产生新数据，直到注册新的观察者并重新调用启动函数
##### 多个观察者
    以上每个初始化函数都可以接收命名参数`asyncCombined!: Bool`，用来决定多个观察者是否单独开启线程还是所有观察者都使用一个线程

#### 每条数据的处理策略
 1. withAlwaysNew()
    总是使用新线程处理每条数据
 2. withCurrent()
    总是使用当前线程处理每条数据
 3. withSingle(...)
    使用指定背压策略和数据队列长度初始化数据处理策略，一直使用同一个线程处理所有数据
 4. withFixed(...)
    使用指定背压策略、数据队列长度和线程数初始化数据处理策略，一直使用这几个线程处理所有数据
#### 启动
  1. delay(Duration)
     延迟Duration后启动
  2. defer()
     0延迟新线程启动
  3. immediately()
     当前线程立即启动
#### 停止
  - dispose(completion!: Bool = false)
    停止当前被观察者，如果参数是true就发送onComplete()事件
#### 背压策略
    只有单线程和固定线程数的处理策略才支持背压策略，如果产生新数据时，数据队列已满，则触发背压策略
##### BackPressure
 1.  `Discarding`
     丢弃新数据
 2.  `DropOldest`
     丢弃队列头的数据
 3.  `AlwaysBlocking`
     一直阻塞
 4.  `BlockingOrDiscarding(Duration)`
     阻塞指定时长后如果队列还是满的则丢弃最新数据
 5.  `BlockingOrThrowing(Duration)`
     阻塞指定时长后如果队列还是满的就抛出异常
 6.  `BlockingOrDroppingOldest(Duration)`
     阻塞指定时长后如果队列还是满的就丢弃队列头部的数据
 7.  `Throwing`
     如果队列是满的立即抛出异常
 8.  `Current`
     如果队列是满的就立即使用当前线程处理当前数据
 9.  `NewThread`
     如果队列是满的就立即使用新线程处理当前数据
 10. `Action((()->Unit) -> Unit)`
     如果队列是满的就使用指定函数处理当前数据
 11. `BlockingOrCurrent(Duration)`
     阻塞指定时长后如果队列还是满的就使用当前线程执行观察者
 12. `BlockingOrNewThread(Duration)`
     阻塞指定时长后如果队列还是满的就使用新线程执行观察者
 13. `BlockingOrAction(Duration, (() -> Unit) -> Unit)`
     阻塞指定时长后如果队列还是满的就使用指定函数执行观察者

#### `Observer<T>`
  - onNext(T)
    接收一条数据
  - onComplete()
    接收完成事件
  - onError(Exception)
    接收一个异常
##### `FuncObserver<T> <: Observer<T>`
   - `setNext((T) -> Unit)`
     指定接收数据的函数
   - `setNext((Single<T>) -> Unit)`
      `Single<T>`是`SingleIterator<T>`的别名，可以在这个闭包内使用`Iterator<T>`的各种函数。
   - `setError((Exception) -> Unit)`
     指定接收异常的函数
   - `setComplete(() -> Unit)`
     指定接收完成事件的函数
##### `EmptyObserver<T>`
   空的观察者

#### 错误恢复器
  - `public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?T) : This`
  - `public func setErrorResumer(resumer: (Exception) -> Unit): This`
  - `public func setErrorResumer(resumeIfFalse: Bool, resumer: (Exception) -> Bool): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?(Emitter<T>) -> Unit): This`

#### 重放
Observable.replaySize(capacity)
启动后如果继续注册观察者会异步重放缓存的数据，缓存数据的数量最大是capacity

- 流程引擎
- 实例复制

  - ```cj
    // 下面的T <: DataFields<T>
    convert<T>(data: Data, flag: DataConversionFlag = SILENCE): ?T
    // 下面的T <: ObjectData<T>
    T.populate(src: Data, flag): ?T
    T.populate(src: Data, target: T, flag): ?T
    T.populate<S>(src: S, flag): ?T where S <: DataFields<T>
    T.populate<S>(src: S, target: T, flag): ?T where S <: DataFields<T>
    T.populate<M, V>(src: M, flag): ?T where M <: StringKeyMap<V>, V <: DataFields<V>
    T.populate<M, V>(src: M, target: T, flag): ?T where M <: StringKeyMap<V>, V <: DataFields<V>
    T.
    ```

  - `let iterator: Iterator<Data> = DataPath.cache(pathString).get(data)`
    - 还支持`DataPath.solid(pathString)`，两种模式的使用方式都一样。
    - solid会一直保存path的编译结果，直到进程结束
    - cache最多保存一万个path，最长保存一天的时间。
- 功能更丰富的json
- 并发
  - 限流策略
    - 滑动时间窗口
    - 令牌桶
    - 漏桶
    - 任意时刻最大并发数
    - 无限制策略
  - 布隆过滤器
  - ConcurrentHashSet
  - SyncPriorityQueue
  - 原子类型扩展
- 集合
  - LinkedHashMap
  - 判定值是否存在的Map扩展
  - PriorityQueue
- TextTemplate
- 随机数
  - 随机字符串
  - 范围随机数
  - 蓄水池算法
- 文档
  - f_doc.* 的宏用来声明文档，可以对各种声明生成markdown文档。
  - 生成文档的路径从环境变量获得
