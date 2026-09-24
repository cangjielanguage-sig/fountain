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
