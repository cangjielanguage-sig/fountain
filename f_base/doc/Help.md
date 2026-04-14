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
