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
