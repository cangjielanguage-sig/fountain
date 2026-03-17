## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 基本特性
fountain项目的基本模块，建议开发时无脑导入本包。

## 导入
```cj
import fountain::f_base.*
```

## BaseException
BaseException是open类。增加了suppressed属性，可以向异常实例添加被遮盖的异常。

## `Comparator<T>`
```cj
public class Comparator<T>
//实例化比较器
Comparator<T>(public let comparator: (T, T) -> Ordering)

//对Comparable类型实例执行比较
public static func compare<T>(left: T, right: T): Ordering where T <: Comparable<T>

//把Comparable转换为Comparator实例
public static func create<T>(): Comparator<T> where T <: Comparable<T>

//比较两个实例
public operator func ()(left: T, right: T): Ordering

//反转比较器
public func reverse(): Comparator<T>

//使用参数创建新的Comparator，如果当前Comparator比较结果为EQ，执行本函数参数做下一步比较
public func then(comparator: (T, T) -> Ordering): Comparator<T>
public func then(comparator: Comparator<T>): Comparator<T>
//使用参数创建新的Comparator，如果当前Comparator比较结果为EQ，调用mapper把类型T转换成O，并调用comparator做下一步比较
public func then<O>(mapper: (T) -> O, comparator: (O, O) -> Ordering): Comparator<T>
public func then<O>(mapper: (T) -> O, comparator: Comparator<O>): Comparator<T>

//返回的Comparator调用本函数参数完成类型转换，并对转换结果做比较
public static func comparing<O, T>(mapper: (O) -> T): Comparator<O> where T <: Comparator<T>
//返回的Comparator调用mapper完成类型转换，并调用comparator完成比较
public static func comparing<O, T>(mapper: (O) -> T, comparator: (T, T) -> Ordering): Comparator<O>
public static func comparing<O>(mapper: (O) -> T, comparator: Comparator<T>): Comparator<O>
```
## `Equaler<T>`
```cj
public struct Equaler
Equaler(private let eq: (T, T) -> Bool)

//比较两个参数是否相等
public static func equals<T>(left: T, right: T): Bool where T <: Equal<T>
//为泛型参数创建Equaler实例
public static func create<T>(): Equaler<T> where T <: Equal<T>
//使用本类型实例比较两个参数是否相等
public operator func ()(left: T, right: T): Bool
//使用参数创建新的Euqaler，如果当前Euqaler比较结果为EQ，调用mapper把类型T转换成O，并调用equal做下一步比较
public func then(equal: (T, T) -> Bool): Equaler<T>
public func then(equal: Equaler<T>): Equaler<T>
//返回的Equaler实例调用mapper完成类型转换，并用转换结果完成比较
public static func equalling<O, T>(mapper: (O) -> T): Equaler<O> where T <: Equal<T>
//返回的Equaler实例调用mapper完成类型转换，并用转换结果执行equal完成比较
public static func equalling<O, T>(mapper: (O) -> T, equal: (T, T) -> Bool): Equaler<O>
public static func equalling<O, T>(mapper: (O) -> T, equal: Equaler<T>): Equaler<O>

//返回的Equaler实例先执行当前Equaler，如果返回true再调用mapper将当前Equaler泛型类型转换成新类型，并用新类型调用equal完成比较
public func then<O>(mapper: (T) -> O, equal: (O, O) -> Bool): Equaler<T>
public func then<O>(mapper: (T) -> O, equal: Equaler<O>): Equaler<T>
```

## Console
```cj
//将参数写到标准输出流，不换行
public static func write<T>(v: T): Unit where T <: ToString
//将参数写到标准输出流后换行
public static func writeln<T>(v: T): Unit where T <: ToString
//将参数执行结果写到标准输出流，不换行
public static func write<T>(fn: () -> T): Unit where T <: ToString
//将参数执行结果写到标准输出流后换行
public static func writeln<T>(fn: () -> T): Unit where T <: ToString
//向标准输出流写一个空行
public static func writeln(): Unit
//从标准输入流读一个字符，不阻塞
public static func read(): ?Rune
//从标准输入流读一个字符串，直到遇到参数才返回，返回不包含参数
public static func readUntil(r: Rune): ?String
//从标准输入流读到的每个字符作为参数，调用参数，直到返回true时结束，返回读到的每个字符，不包含返回true的字符
public static func readUntil(predicate: (Rune) -> Bool): ?String
//从标准输入流读一个空行
public static func readln(): ?String
```

## 空集合
```cj
//以下是各种空集合的实例化方式
EmptyArray<T>.instance()
EmptySet<T>.instance()//EmptySet<T> <: Set where T <: Equatable<T>
EmptyIterator<T>.instance()//EmptyIterator<T> <: Iterator<T>
EmptyIterable<T>.instance()//EmptyIterable<T> <:Iterable<T>
EmptyMap<K, V>.instance()//EmptyMap<K, V> <: Map<K, V> where K <: Equatable<K>
EmptyEquatableCollection<K>.instance()//EmptyEquatableCollection<K> <: EquatableCollection<K> where K <: Equatable<K>
EmptyCollection<T>.instance()//EmptyCollection<T> <: Collection<T>
EmptyList<T>.instance()//EmptyList<T> <: List<T>
```

## 扩展Iterator
```cj
//返回的Iterator每次执行next()都创建一个新线程返回一个?Future<?T>，
func async(): Iterator<Future<?T>>
//使用参数比较迭代器的每个元素，返回迭代器中的最小值
func min(cmp: (T, T) -> Ordering): ?T
//使用参数比较迭代器的每个元素，返回迭代器中的最大值
func max(cmp: (T, T) -> Ordering): ?T
//exactly： true，则迭代器的每个元素类型必须是R类型才会返回；exactly: false，则迭代器的每个元素类型必须是R的子类型才会返回；忽略其它元素
func filterType<R>(exactly!: Bool): Iterator<R>
//如果迭代器的每个元素是Iterable<R>，则将当前元素转换为Iterator<R>；如果迭代器元素不是Iterable<R>类型，toThrow是true时会抛出异常，toThrow是false时返回EmptyIterator<T>
func flatten<R>(toThrow!: Bool): Iterator<R>
//用迭代器的每个元素调用collector，把迭代器元素填充到collection
func collect<C>(collection: C, collector: (T, C) -> Unit): C where C <: Collection<T>
//把迭代器转换为Array<T>
func toArray(): Array<T>
//把迭代器转换为ArrayList<T>
func toArrayList(): ArrayList<T>
//把迭代器元素作为key的参数用key返回的K作为HashMap的KEY，将迭代器元素填充到HashMap
func collect<K>(key: (T) -> K): HashMap<K, T> where K <: Hashable & Equatable<K>
//把迭代器元素作为key的参数用key返回的K作为HashMap的KEY，将迭代器元素填充的HashMap
public func groupBy<K>(key: (T) -> K): HashMap<K, ArrayList<T>> where K <: Hashable & Equatable<K>
//返回的实例有一个函数peek，调用peek会返回当前未迭代的值，不消耗任何未迭代值，不影响next()的执行。
public func peekable(): PeekableIterator<T>
```

## 扩展Option
```cj
//用当前Option实例化为只有一个元素的迭代器，这个迭代在首次调用next函数时函数返回值取决于Option是Some还是None
func iterator(): Iterator<T>
//如果Option是Some则用Some包含的值调用fn，则fn的返回值就是call的返回值，否则call返回None
func call<R>(fn: (T) -> R): ?R
//如果Option是Some则用Some包含的值和right作参数调用fn，则fn的返回值就是call的返回值，否则call返回None
func call<A, R>(right: A, fn: (T, A) -> R): ?R

//fn和当前Option作为参数初始化OptionCaller
func caller<R>(fn: (T) -> R): OptionCaller<T, R>
//fn、right和当前Option作为参数初始化OptionCaller
func caller<A, R>(right: A, fn: (T, A) -> R): OptionCaller<T, R>
//当前Option如果是Some(x: U)，则转换为Result.Ok(x)；如果是Some但是类型不是U，返回None；如果是None，返回NoResult
func toResult<U, E>(): ?Result<U, E>
//当前Option如果是Some，调用fn转换为U，并用返回值实例化为Result类型，否则返回None
func toResult<U, E>(fn: (T) -> U): ?Result<U, E>
//当前Option如果是Some，调用fn转换为?U，如果返回了Some(x)，则将Some的值实例化为Result<U, E>.Ok(x)， 否则返回None；如果是None，则返回NoResult
func toResult<U, E>(fn: (T) -> ?U): ?Result<U, E>
//当前Option如果是Some(x: U)，返回Result<U, E>.Ok(x)，如果是Some，但值不是类型U，会抛出异常；否则返回Result<U, E>.NoResult
func toResult<U, E>(fn: () -> Exception): Result<U, E>
//将当前Option包装为Result.Ok(this)
func wrapResult<E>(): Result<?T, E>
``

## OptionCaller
```cj
public class OptionCaller<T, R> {
    public OptionCaller(
        private let option: ?T,
        private let someCallee: (T) -> R,
        private var noneCallee!: ?() -> R = None<() -> R>
    ) {}
    //修改noneCallee
    public func none(callee: () -> R) 
    //如果option是Some，执行someCallee，否则执行noneCallee，如果noneCallee是None，则返回None
    public func call(): ?R 
    //同call
    public operator func ()(): ?R 
}
```

## Result<T, E>
```cj
public enum Result<T, E> {
    | Ok
    | Ok(T)
    | Err
    | Err(E)
    | NoResult
    //当前Result是不是Ok
    public prop isOk: Bool 
    //当前Result是不是Err
    public prop isErr: Bool 
    //当前Result是不是NoResult
    public prop isNoResult: Bool 
    //当前Result是否包含错误值，只有是Err(E)时才返回true
    public prop withE: Bool
    //当前Result是否包含正确的值，只有是Ok(T)时才返回true
    public prop withValue: Bool 
    //是Ok(T)时返回Some(T)，其它情况返回None<T>
    public func result(): ?T 
    //是Err(E)时返回Some(E)，其它情况返回None<E>
    public func err(): ?E 
    //将当前Result转换为Result<U, E>，当前Result是Ok(T)时执行参数f，
    public func mapValue<U>(f: (T) -> Result<U, E>): Result<U, E> 
    /**
     * 将当前Result转换为Result<U, E>，当前Result是Err(E)时执行参数f，
     * 当前Result是Ok(x: U)时返回Ok(x)，其它Ok值返回Ok
     * 其它情况返回同样的枚举值
     */
    public func mapError<U>(f: (E) -> Result<U, E>): Result<U, E> 
    //忽略数据和错误信息，只返回Ok Err NoResult
    public func ignore(): Result<T, E> 
    //当前Result 是Ok(x)时执行predicate，且返回true时返回当前Result，其它情况返回NoResult
    public func filterValue(predicate: (T) -> Bool): Result<T, E> 
    //当前Result是Err(x)时执行predicate，且返回true时返回当前Result，其它情况返回NoResult
    public func filterError(predicate: (E) -> Bool): Result<T, E> 
    //当前Result的isOk返回true时返回当前Result，否则返回NoResult
    public func filterOk(): Result<T, E> 
    //当前Result的isErr返回true返回当前Result，否则返回NoResult
    public func filterErr(): Result<T, E>
    //当前Result是Err(E)时返回当前Result，否则返回NoResult
    public func filterWithE(): Result<T, E>
    //当前Result是Ok(T)时返回当前Result，否则返回NoResult
    public func filterWithValue(): Result<T, E>
    //如果当前Result是Ok(x: Result<U, E>)返回x，其它情况原样返回
    public func flatten<U>(): Result<U, E> 
    //如果当前Result是Ok(x: U)，返回Ok(x)，是Ok(x)，但是x不是类型U返回Ok，其它情况原样返回
    public func transpose<U>(): ?Result<U, E> 
    //如果当前Result是Ok(x)，返回x，其它情况返回default
    public func orDefault(default: T): T 
    //如果当前Result是Ok(x)，返回x，其它情况返回fn的返回值
    public func orElse(fn: () -> T): T 
    //如果当前Result是Ok(x)，返回x，其它情况返回fn的返回值
    public func orElse(fn: () -> ?T): ?T 
}
```

## 扩展ThreadLocal
```cj
//如果当前ThreadLocal有值就返回当前值，否则调用fn，将fn的返回值存入当前ThreadLocal，并返回刚存入的值
func getOrCompute(fn: () -> T): T
//清除当前ThreadLocal的值
func remove(): Unit
```

## HashBuilder
```cj
/* 此类一般只作为局部变量使用，不会发生逃逸
   仓颉已支持类实例的逃逸分析和栈上分配
   按照HashBuilder_test的简单性能测试。
   每个append函数参数会尽量参与哈希计算，参数实现了Hashable的会调用参数的hashCode()再用这个哈希值执行哈希公式
 */
public class HashBuilder

/**
 * 调用一次，本类的实例回到初始状态
 */
public func build(): Int64
@OverflowWrapping
public func append(arg: Int64): This
public func append<T>(arg: T): This where T <: Hashable
//遍历参数的每个元素，逐个元素调用append函数
public func append<T, I>(args: I): This where T <: Hashable, I <: Iterable<T>
//遍历区间，每个区间值调用append函数
public func append<T>(args: Range<T>): This where T <: Hashable & Countable<T> & Comparable<T> & Equatable<T>
//调用参数的toString()函数，用这个字符串调用append
public func append(arg: StringGenerator): This
/**
 * 遍历参数，如果键和值实现了Hashable，则使用它们的哈希值分别调用append函数，
 * 如果实现了ToString则先调用toString()再调用append，都没有实现的用'_'调用append函数。
 */
public func append<K, V>(value: ConcurrentHashMap<K, V>): This where K <: Hashable & Equatable<K>
/**
 * 如果value实现了Hashable，使用参数的哈希值调用append函数，
 * 如果value实现了ToString，用参数的toString()结果调用append
 */
public func append(value: Any): This
/**
 * 如果参数扩展了Hashable，则用参数的哈希值调用append。
 * 否则遍历参数，每个键和值如果实现了Hashable，则分别用哈希值调用append，
 * 如果实现了ToString则用toString()的结果调用append
 */
private func append<K, V>(value: Map<K, V>): This where K <: Equatable<K>
```

## Help
```cj
//convert返回第一个非None且非空的值
//Help.convert<T>(a, b, c)
//Help.convert<T>(list)
public static func convert<T>(options: Array<?T>): ?T
public static func convert<T>(options: Array<?String>): String
public static func convert<T, C>(collections: Array<C>): ?C where C <: Collection<T>
public static func convert(strings: Array<String>): String
```

## OS
```cj
//操作系统
public enum OS <: Equatable<OS> & ToString & Hashable {
    | Linux
    | Windows
    | macOS
    | HarmonyOS
    public operator func ==(other: OS): Bool
    public prop isWindows: Bool
    public prop isLinux: Bool
    public prop isMacOS: Bool
    public prop isHarmonyOS: Bool
    public func toString(): String
    public static func valueOf(value: String): OS
    public func hashCode(): Int64
    //返回当前操作系统的实例
    public static prop current: OS
    //返回当前操作系统的换行符
    public prop nextLine: String
}
```

## 顶级函数resource
```cj
//代替try-with-resource，fn的参数是res，区别是本函数会返回fn的返回。
public func resource<R, T>(res: R, fn: (R) -> T): T where R <: Resource
```

## 单值迭代
```cj
//用一个值初始化的迭代对象
public class SingleIterable<T> <: Iterable<T>
public class SingleIterator<T> <: Iterator<T>
```

## StringGenerator
```cj
//功能比标准库的StringBuilder更丰富
public class StringGenerator <: ToString

public init() {}
public init(s: String)
//当前StringGenerator的大小
public prop size: Int64
//重置当前StringGenerator
public func reset(): This
public func clear(): This
//把参数添加到StringGenerator
public func append<T>(content: T): This where T <: ToString
//把参数添加到StringGenerator，然后追加指定的换行符
public func appendln<T>(content: T, nextLine!: String = OS.current.nextLine): This where T <: ToString
//把参数添加到StringGenerator，并追加类UNIX系统的换行符
public func appendUnixNewLine<T>(content: T): This where T <: ToString
//把指定换行符添加到StringGenerator
public func append(nextLine!: String = OS.current.nextLine): This
//把类UNIX换行符添加到StringGenerator
public func appendUnixNewLine(): This
//把UTF8字节数组添加到StringGenerator
public func appendFromUtf8(utf8: Array<Byte>): This
//把字节数组用指定字符集转换为字符串并添加到StringGenerator
public func appendFromBytes(bytes: Array<Byte>, charset!: Charset = Charsets.UTF8): This
//将content转为字符串并从StringGenerator的fromIndex开始查找子串，返回找到的第一个子串的索引，找不到就返回None
public func indexOf<T>(content: T, fromIndex!: Int64 = 0): ?Int64 where T <: ToString
//将content转为字符串并从StringGenerator的fromIndex开始查找子串，返回找到的最后一个子串的索引，找不到就返回None
public func lastIndexOf<T>(content: T, fromIndex!: Int64 = 0): ?Int64 where T <: ToString
//将content转为字符串并判断当前StringGenerator是否包含这个字符串
public func contains<T>(content: T): Bool where T <: ToString
//判断当前StringGenerator是否以参数开头
public func startsWith(content: String): Bool
//判断当前StringGenerator是否以参数结尾
public func endsWith(content: String): Bool
//从StringGenerator截取从start到end的子串，包含start不包含end
public func substring(start: Int64, end: Int64): String
//把content转为字符串，删除从fromIndex开始找到的第一个子串
public func removeFirst<T>(content: T, fromIndex!: Int64 = 0): This where T <: ToString
//把content转为字符串，删除从fromIndex开始找到的最后一个子串
public func removeLast<T>(content: T, fromIndex!: Int64 = 0): This where T <: ToString
//把content转为字符串，删除从fromIndex到toIndex的所有子串
public func remove<T>(content: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString
//将sub转为字符串并插入到索引at处
public func insert<T>(sub: T, at!: Int64): This where T <: ToString
//将old和new转为字符串，将fromIndex到toIndex的所有old换为new
public func replace<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//将new转为字符串，从fromIndex到toIndex的内容替换为这个字符串
public func replace<T>(new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where T <: ToString
//将old和new转为字符串，将fromIndex到toIndex找到的第一个old替换为new
public func replaceFirst<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//将old和new转为字符串，将fromIndex到toIndex找到的最后一个old替换为new
public func replaceLast<O, T>(old: O, new: T, fromIndex!: Int64 = 0, toIndex!: Int64 = size): This where O <: ToString, T <: ToString
//按字符反转StringGenerator
public func reverse(): This
//返回构造的字符串
public func toString(): String
//返回StringGenerator的原始字节数组
public func unsafeBytes(): Array<Byte>
```

## 得到字符串的原始字节数组
```cj
public interface UnsafeBytes {
    func unsafeBytes(): Array<Byte>
}
extend String <: UnsafeBytes{...}
```

## 得到ArrayList的原始数组
```cj
import std.collection.ArrayList

public interface UnsafeData<T> {
    func unsafeData(): Array<T>
}

extend<T> ArrayList<T> <: UnsafeData<T>{...}
```

## 得到零值
```cj
//不必使用unsafe关键词
public func unsafeZeroValue<T>(): T
```

## 零Timer
```cj
public import std.sync.Timer

public let ZERO_TIMER: Timer = unsafe { zeroValue<Timer>() }
```

## 溢出拒绝策略
```cj
public interface OverSizePolicy<T> {
    /**
       o 是待添加的新值，
       fn是执行策略以后要执行的函数，比如执行策略以后又可以添加新值了就可以在fn内包含添加新值的逻辑
     */
    func reject(o: T, fn: () -> Unit): Unit
}
/**抛出异常*/
public class AbortOverSizePolicy<T> <: OverSizePolicy<T>
/**丢弃当前值*/
public class DiscardOverSizePolicy<T> <: OverSizePolicy<T>
/**丢弃某个值*/
public class RemoveSomeOnePolicy<T> <: OverSizePolicy<T>
/**调用线程执行*/
public class CallerRunsOverSizePolicy<T> <: OverSizePolicy<T>
/**阻塞直到超时，超时前唤醒且recovered返回true执行policy*/
public class BlockingOverSizePolicy<T> <: OverSizePolicy<T> {
    public BlockingOverSizePolicy(
        private let recovered: (T) -> Bool,
        private let timeout!: Duration = Duration.Max,
        private let policy!: OverSizePolicy<T> = DiscardOverSizePolicy<T>()
    ) {}
    /**阻塞直到超时，超时前唤醒且recovered返回true执行policy*/
    public func reject(o: T, fn: () -> Unit): Unit
    public func notifyAll(): Unit
    public func notify(): Unit
}
```

## 基础运算符接口
```cj
public interface Negativable<T> where T <: Negativable<T> {
    operator func -(): T
}

public interface Addable<T> where T <: Addable<T> {
    operator func +(right: T): T
}

public interface Subable<T> where T <: Subable<T> {
    operator func -(right: T): T
}

public interface Mulable<T> where T <: Mulable<T> {
    operator func *(right: T): T
}

public interface Divable<T> where T <: Divable<T> {
    operator func /(right: T): T
}

public interface Modable<T> where T <: Modable<T> {
    operator func %(right: T): T
}

public interface Expable<T> where T <: Expable<T> {
    operator func **(right: T): T
}

public interface Cmpable<T> where T <: Cmpable<T> {
    operator func >(right: T): Bool
    operator func <(right: T): Bool
    operator func >=(right: T): Bool
    operator func <=(right: T): Bool
}

public interface Eqable<T> where T <: Eqable<T> {
    operator func ==(right: T): Bool
    operator func !=(right: T): Bool
}

public interface BitAndable<T> where T <: BitAndable<T> {
    operator func &(right: T): T
}

public interface BitOrable<T> where T <: BitOrable<T> {
    operator func |(right: T): T
}

public interface BitXorable<T> where T <: BitXorable<T> {
    operator func ^(right: T): T
}

public interface BitNotable<T> where T <: BitNotable<T> {
    operator func !(): T
}

public interface LeftShiftable<T> where T <: LeftShiftable<T> {
    operator func <<(right: T): T
}

public interface RightShiftable<T> where T <: RightShiftable<T> {
    operator func >>(right: T): T
}
```