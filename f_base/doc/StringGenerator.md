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
