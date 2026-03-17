## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## CaseFormat 转换
```cj
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerHyphen), "case-format")
```

## crc16
```cj
/**
 * 用字节数组计算UInt16
 */
public func crc16(bytes: Array<Byte>): UInt16
```

## 工厂模式
```cj
public interface Producer<A, O> {
    /**创建类型是O的实例，默认实现是抛出IllegalAccessException*/
    func produce(): O 
    /**用参数A创建类型是O的实例，默认实现是抛出IllegalAccessException*/
    func produce(arg: A): O 
}
/**
 * 对象工厂
 * assemble 函数是注册对象生产实例
 * produce 是按照注册的生产实例制造指定类型的对象
 */
public class Factory<A, O> {
    public func assemble<T>(producer: Producer<A, O>): Unit
    public func assemble<T>(producers: Iterable<Producer<A, O>>): Unit
    public func produce<T>(): T
    public func produce<T>(arg: A): T
}
```

### 中介者模式
```cj
//策略定义接口
public interface Colleague<N, A, R> where A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    prop name: N//策略名
    func execute(arg: A): R//策略函数
}
public interface ColleagueArgument<N> where N <: Hashable & Equatable<N> {
    prop name: N
}
public class Mediator<N, C, A, R> where C <: Colleague<N, A, R>, A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    /**注册策略*/
    public func register(colleague: Colleague<N, A, R>): Unit
    /**用参数查找策略并执行*/
    public func execute(arg: A): R 
}
```

### 责任链模式
```cj
/*
 * 责任链模式的接口，所有责任链策略都要实现此接口
 * S 是策略的具体实现，N与S需要一一对应
 * C 是执行策略的条件参数，满足条件的策略会得到执行
 * A 是执行策略的参数
 * R 是执行策略的结果
 */
public interface Resposibility<C, A, R> {
    /**
     * 检查指定条件是否满足执行当前策略的要求
     */
    func check(condition: C): Bool

    /**
     * 执行当前策略
     */
    func execute(arg: A): R
}
/**
 * 责任策略
 */
public interface ValidationResposibility<C, A> <: Resposibility<C, A, Unit> {
    func execute(arg: A): Unit {}
}
/**
 * 责任链
 */ 
public class ResposibilityChain<C, A, R> {
    public init() {}
    public init(resposibilities: Iterable<Resposibility<C, A, R>>)
    /**
     * 注册一个策略
     */
    public func register(resposibility: Resposibility<C, A, R>): ResposibilityChain<C, A, R>
    /**
     * 注册一批策略
     */
    public func register<S>(resposibilities: Iterable<S>): Unit where S <: Resposibility<C, A, R>
    /**  
     * 执行一个策略，遍历策略集合，直到遇到一个Resposibility.check(condition)返回true的策略，并执行这个策略。
     * 如果没有策略满足条件，就抛出IllegalAccessException
     */
    public func execute(condition: C, arg: A): R
    /**
     * 执行所有满足条件的策略
     */
    public func executeAll(condition: C, arg: A): Unit 
}
```

### 状态模式
```cj
/**
 * 状态模式
 */
public interface State<D> {
    /**
     * 是否有后续状态
     */
    prop continues: Bool{
        get(){
            true
        }
    }
    /**
     * 执行当前状态
     */
    func exec<S>(): S where S <: State<D>
    /**
     * 当前状态的数据
     */
    prop data: D
    /**
     * 执行状态
     */
    func startup<D>(): D
}
```

### 策略模式
```cj
/**
 * 策略模式的接口，所有策略都要实现此接口
 * N 是策略的标识，需要用N找到对应的策略，
 * S 是策略的具体实现，N与S需要一一对应
 * A 是执行策略的参数
 * R 是执行策略的结果
 */
public interface Strategy<N, A, R> where N <: Hashable & Equatable<N> {
    /**
     * 返回策略标识
     */
    prop name: N

    /**
     * 执行策略
     */
    func execute(arg: A): R
}

/**策略的集合*/
public class Strategies<N, A, R> where N <: Hashable & Equatable<N> {
    public init() {}

    /** 把指定策略注册进来*/
    public func register(strategy: Strategy<N, A, R>): Strategies<N, A, R> 
    public func register<S>(strategies: Iterable<S>): Unit where S <: Strategy<N, A, R> 

    /**
     * 用指定的标识和参数执行策略，如果没有找到标识是name的策略会抛出base.IllegalAccessException
     */
    public func execute(name: N, arg: A): R 
}

```

## geohash
```cj
public struct GeoHash <: Hashable & Equatable<GeoHash> & ToString & Parsable<GeoHash> & DataParsable<GeoHash> {
    /**初始化geohash*/
    public static func encode(latitude: Float64, longitude: Float64): GeoHash
    /**
     * GeoHash.encode(coordinate[0], coordinate[1])
     */
    public static func encode(coordinate: (Float64, Float64)): GeoHash
    /**从geohash反向计算经伟度，返回的元组是(longitude, latitude)*/
    public func decode(): (Float64, Float64)
    public operator func ==(other: GeoHash): Bool
    public func hashCode(): Int64
    /**把geohash转成4进制*/
    public func toString(): String 
    /**把四进制字符串转成GeoHash*/
    public static func tryParse(hash: String): Option<GeoHash>
    /**把四进制字符串转成GeoHash*/
    public static func parse(hash: String): GeoHash
}
```

## IdMaker
```cj
public class IdMaker {
    /**
     * hostSerial 主机序列号
     */
    public IdMaker(private let hostSerial!: Int64)
    /**
     * 从配置项idMakerHostSerial获取主机序列化
     */
    public init()
    /**
     * 获取下一个ID
     */
    public func nextInt64(): Int64
}
```

## @IsUUID
IsUUID注解是`fountain::f_data.validation`的子类。
受验证数据必须是UUID

## murmur hash
```cj
/**
 * 计算给定字节数组的MurmurHash64哈希值
 * 
 * @param data 要计算哈希的字节数组
 * @param seed 哈希种子值，默认为0x1234567890ABCDEF
 * @return 计算得到的64位MurmurHash值
 * 
 * @note 此实现使用MurmurHash64算法，适用于非加密用途的哈希计算
 * @see 参考MurmurHash算法规范
 */
public func murmurHash64(data: Array<Byte>, seed!: Int64 = 0x1234567890ABCDEF): Int64 
/**
 * 计算给定字符串的MurmurHash64哈希值
 * 
 * @param data 要计算哈希的字节数组
 * @param seed 哈希种子值，默认为0x1234567890ABCDEF
 * @return 计算得到的64位MurmurHash值
 * 
 * @note 此实现使用MurmurHash64算法，适用于非加密用途的哈希计算
 * @see 参考MurmurHash算法规范
 */
public func murmurHash64(data: String, seed!: Int64 = 0x1234567890ABCDEF): Int64
/**
 * 128比特murmur hash
 */
public struct MurmurHash128X64 <: Hashable & Comparable<MurmurHash128X64> & ToString {
    /**
     * 得到表示murmur hash的字节数组
     */
    public func toBytes(): Array<Byte>
    /**
     * 得到表示murmur hash的BigInt
     */
    public func toBigInt(): BigInt
    public func hashCode(): Int64 
    public func compare(other: MurmurHash128X64): Ordering
    /**
     * 把字节数组转成16进制字符串
     */
    public func toString(): String
    /**
     * 把字符串转成murmur hash实例
     */
    public static func parse(s: String): MurmurHash128X64 
    /**
     * 把字节数组转成murmur hash实例
     */
    public static func parse(bytes: Array<Byte>): MurmurHash128X64
}
/**
 * 计算给定字节数组的128位MurmurHash3哈希值(x64变体)
 * 
 * @param data 要计算哈希的字节数组
 * @param seed 可选的种子值，默认为0x1234567890ABCDEF
 * @return 包含两个64位哈希值的MurmurHash128X64结构体
 * 
 * 算法特点：
 * - 使用MurmurHash3算法的128位x64变体
 * - 处理输入数据为16字节的块
 * - 对剩余字节进行特殊处理
 * - 使用多个混合常量(C1, C2)和旋转操作(R1, R2, R3)
 * - 包含最终的混合步骤(fmix64)
 * 
 * 注意：
 * - 结果由两个64位整数组成，表示128位哈希值
 * - 默认种子为0x1234567890ABCDEF
 */
@OverflowWrapping
public func murmurHash128X64(data: Array<Byte>, seed!: Int64 = 0x1234567890ABCDEF): MurmurHash128X64
public func murmurHash128X64(data: String, seed!: Int64 = 0x1234567890ABCDEF): MurmurHash128X64
```

## 路径匹配
```cj
let patterns = PathPattern<Object>()
patterns.compileIfAbsent(path){Object()}//将path注册到PathPattern，并且添加路径对应的对象
patterns.extractVariableInPath(path, name)//从path找到名为name的路径变量，并返回path中对应的路径变量值
patterns.data<Object>(path)//从PathPattern找到路径对应的对象
```

## isPrime
```cj
/**
 * 判定素数
 * @param p
 * @return
 */
public func isPrime(p: UInt64): Bool
```

## 文档模板
```cj
/**
 * 简单文本模板
 * 本类依赖ThreadLocalStringBuilder，如果使用本类的方法也使用了ThreadLocalStringBuilder请不要在那个方法内构造字符串时调用本类方法。
 * 如果本类对象的返回值是构造的一个字符串的一部分，请先调用本类，然后在使用本类的方法内使用ThreadLocalStringBuilder获取StringBuilder对象。
 * 占位符方式的文本模板，prefix和suffix之间的文本是提供数据的对象属性或map的key，
 * 占位符用“regex:”开头的表示这是一个正则表达式，包含正则表达式的模板只接收map作为数据来源，用map中找到的第一个匹配这个正则表达式的key所对应的值替换这个正则表达式占位符；正则表达式用`包含
 * 占位符内包含“time:`FORMAT`”表示，FORMAT在实际使用时换成日期格式化模板；占位符名在time:前面用空格分隔，或者在`FORMAT`后面后空格分隔
 * <p>
 * 占位符内包含“number:`##.##,HALF_UP`”表示，`##.##,HALF_UP`
 * 在实际使用时换成数字格式化模板；占位符名在number:前面用空格分隔，
 * 或者在`##.##,HALF_UP`后面用空格分隔，格式模板的#数量表示数字位数，.表示小数点位置；HALF_UP是默认舍入规则，可选
 * 数字格式可以o O x X e E + (等任意一个符号开头，这几个标记不能同时出现
 * o O表示转化成8进制，x X 表示转化成16进制，转化前会自动把小数精度改为0
 * e E 表示转化为科学计数法
 * + 表示对于正数需要前置+，(表示对于负数需要去掉-，并用()包含数字串
 * <p>
 * 占位符可以是用.分割的字符串，.分割的占位符接收数组、list、po、map作参数；
 * a.0.b.c，表示参数的a属性是一个数组或list，它的索引0有一个属性b（如果是map就是key）,属性b有一个属性c，属性c的值是用来格式化的内容
 * 由于在number: regex: time:等模式中`有特殊意义
 */
public class TextTemplate {
    /**
     * 将template编译为TextTemplate，模板内由一对#包含的字符串为模板变量
     */
    public static func compile(template: String, placeholder!: String = "#"): TextTemplate 
    /**
     * 将template编译为TextTemplate，模板由prefix和suffix包含的字符串为模板变量
     */
    public static func compile(template: String, prefix!: String = #"${"#, suffix!: String = "}"): TextTemplate
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<T>(data: Array<T>, noneConverter!: ?String = None<String>): String where T <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<T>(data: ArrayList<T>, noneConverter!: ?String = None<String>): String where T <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<V>(data: ConcurrentHashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<V>(data: HashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<V>(data: TreeMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<V>(data: LinkedHashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format函数把data里的元素代替字符串模板的模板变量，如果不存在相应的模板变量则使用noneConverter
     */
    public func format<T>(data: T, noneConverter!: ?String = None<String>): String where T <: Object & ObjectData<T> 
}
```

## UUID
```cj
/**
 * reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html
 * 实现各个版本的UUID
 */
public struct UUID <: Hashable & Comparable<UUID> & ToString & Parsable<UUID> & DataParsable<UUID> & DataFields<UUID> {
    /**
     * UUID转Data实例
     */
    public func toData(): Data 
    /**
     * Data转UUID
     */
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public func hashCode(): Int64
    public operator func ==(other: UUID): Bool 
    public operator func !=(other: UUID): Bool 
    public func compare(other: UUID): Ordering
    /**
     * 空UUID
     */
    public static let Nil = UUID()
    /**
     * 最大的UUID
     */
    public static let Max = UUID(values: Array<Byte>(16, repeat: 0xff))
    public func toString(): String
    /**
     * UUID转成指定进制的字符串
     */
    public func toString(radix: Int64)
    /**
     * UUID转成指定16进制的字符串
     */
    public func toHexString(): String
    /**
     * UUID版本
     */
    public prop version: Int64
    /**
     * UUID时间戳
     */
    public prop timestampNanos: Int64
    /**
     * UUID时间戳
     */
    public prop timestamp: DateTime
    public prop variant: Int64
    public static func parse(uuid: String): UUID
    public static func tryParse(uuid: String): ?UUID
    /**
     * 基于时间戳的UUID，兼容UUID version 1 2 6
     */
    public static func timeBased(timeLowFirst!: Bool = false): TimeBasedUUIDBuilder
    /**
     * version 3
     */
    public static func md5(value: String): UUID
    /**
     * 用随机字节数组创建基于md5的UUID 
     */
    public static func randomMd5(bytes!: Int64 = 16): UUID
    /**
     * 用指定字节数组创建基于md5的UUID 
     */
    public static func md5(value: Array<Byte>): UUID
    /**
     * version 4
     */
    public static func random(): UUID
    /**
     * version 5
     */
    public static func sha1(value: String): UUID
    /**
     * 用随机字节数组创建基于sha1的UUID 
     */
    public static func randomSha1(bytes!: Int64 = 20): UUID
    /**
     * 用指定字节数组创建基于sha1的UUID 
     */
    public static func sha1(value: Array<Byte>): UUID
    /**
     * version 7 基于UNIX时间戳的UUID 
     */
    public static func unixTimeBased(): UUID
    /**
     * version 8
     */
    public static func custom(values: Array<Byte>): UUID
}

public class TimeBasedUUIDBuilder <: Resource {
    public func isClosed(): Bool 
    public func close(): Unit 
    /**注册序列号生成器*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**注册文件序列号生成器*/
    public func registerFileSequenceGenerator(): This
    /**使用原子整型注册一个序列号生成器*/
    public func registerSequenceGenerator(): This
    /**随机序列号生成器*/
    public prop randomSeq: TimeBasedUUIDBuilder 
    /**顺序序列号生成器*/
    public prop serialSeq: TimeBasedUUIDBuilder 
    /**Linux uid */
    public func UID(uid: UInt32): TimeBasedUUIDBuilder 
    /**Linux gid*/
    public func GID(gid: UInt32): TimeBasedUUIDBuilder 
    /**使用eth0*/ 
    @When[os == 'Linux']
    public func eth0()
    /**使用指定名称的网卡地址*/
    @When[os == 'Linux']
    public func etherName(name: String): UUID 
    /**使用指定的网卡地址*/
    public func ether(ether: String): UUID 
    public func node(node: Int64): UUID 
    public func node(node: UInt64): UUID 
    public func randomNode(): UUID 
    public func node(node: Array<Byte>): UUID 
    /**使用高位时间戳*/
    public func timeHighFirst(timestamp: Int64): (Int64) -> Byte 
}

public class TimestampSequenceBuilder <: Resource {
    public func isClosed(): Bool 
    public func close(): Unit 
    /**注册序列号生成器*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**注册文件序列号生成器*/
    public func registerFileSequenceGenerator(): This
    /**使用原子整型注册一个序列号生成器*/
    public func registerSequenceGenerator(): This
}

```