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
