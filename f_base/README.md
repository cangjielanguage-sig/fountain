# f_base

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

- [Console](doc/Console.md)

## 空集合

- [空集合](doc/空集合.md)

## 扩展Iterator

- [扩展Iterator](doc/扩展Iterator.md)

## 扩展Option

- [扩展Option](doc/扩展Option.md)

## OptionCaller

- [OptionCaller](doc/OptionCaller.md)

## Result<T, E>

- [Result_T_E](doc/Result_T_E.md)

## 扩展ThreadLocal

- [扩展ThreadLocal](doc/扩展ThreadLocal.md)

## HashBuilder

- [HashBuilder](doc/HashBuilder.md)

## Help

- [Help](doc/Help.md)

## OS

- [OS](doc/OS.md)

## 顶级函数resource

- [顶级函数resource](doc/顶级函数resource.md)

## `ResourceManager<R> where R <: Resource`

- [ResourceManager_R_where_R_Resource](doc/ResourceManager_R_where_R_Resource.md)

## 单值迭代

- [单值迭代](doc/单值迭代.md)

## StringGenerator

- [StringGenerator](doc/StringGenerator.md)

## 得到字符串的原始字节数组

- [得到字符串的原始字节数组](doc/得到字符串的原始字节数组.md)

## 得到ArrayList的原始数组

- [得到ArrayList的原始数组](doc/得到ArrayList的原始数组.md)

## 得到零值

- [得到零值](doc/得到零值.md)

## 零Timer

- [零Timer](doc/零Timer.md)

## 溢出拒绝策略

- [溢出拒绝策略](doc/溢出拒绝策略.md)

## 基础运算符接口

- [基础运算符接口](doc/基础运算符接口.md)

## `FutureTask<T>`
1. 父任务结束时可以选择是否结束子任务
2. 支持InheritedTaskLocal，类似ThreadLocal，不过有继承关系，如果当然FutureTask未找到值，则从父任务中获取
- [FutureTask](doc/FutureTask.md)

## 结束进程信号处理函数
本模块确保在使用fountain的应用项目所有动态链接库完成加载后再注册SIGTERM、SIGINT两个信号处理函数，并清除之前注册的这两个信号的处理函数。
应用项目模块如果需要在进程结束前做一些清除工作应当调用以下函数：
```cj
ExitCallbacks.atExit(priority){...}
```
函数声明如下：
```cj
public struct ExitCallbacks {
    //注册信号处理函数，这个函数会重置之前注册过的SIGTERM、SIGINT信号，
    //然后为这两个信号注册新的处理函数，处理函数内调用ExitCallbacks.atExit注册的函数，然后调用exit(0)退出进程，信号处理函数最后返回false
    //需要在进程退出前做清理工作的模块务必调用ExitCallbacks.atExit或std.env.atExit
    //如果开发者在项目中使用了"fountain::f_app"="1.3.0"及以上版本则不需要调用本函数，因为f_app模块会自动调用本函数
    public static func toExitGracefully(): Unit
    //回调函数按照权重升序顺序执行，权重一样的按照注册顺序执行
    public static func atExit(priority: UInt16, atexit: () -> Unit): Unit
}
```