# f_config


## 配置工具

```cj
package fountain::f_config

/**
 * 不依赖配置文件，所有配置都来自环境变量和命令行参数，命令行参数会覆盖同名环境变量。
 * 本工具不会修改环境变量和命令行参数命名风格，仓颉运行时环境变量都是驼峰命名法，建议用于应用配置的环境变量和命令行参数也采用此风格。
 * 命令行参数需要遵守以下规则
 *   1. --argName=argValue
 *   2. --argName
 *      * 相当于--argName=true
 *   3. -argName argVal
 *   4. -argName
 *      * 相当于-argName true
 */
public class Config {
    /**
     * ifAbsent是true，只有当前配置项不存在时才添加，否则用新的配置覆盖旧的
     */
    public static func set<T>(tuples: Array<(String, T)>, ifAbsent!: Bool = false): Unit where T <: ToString
    /**
     * 得到相同前缀的配置项
     */
    public static func getAll(prefix: String): Map<String, String>
    /**
     * 得到名是key的配置项
     */
    public static func getString(key: String): ?String
    /**
     * 得到名是key的配置项，调用parser把配置值转为指定类型
     */
    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T
    /**
     * 得到名是key的配置项，把配置值转成指定类型
     */
    public static func getValue<T>(key: String): ?T where T <: Parsable<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组
     */
    public static func getStringArray(key: String, delim!: String = ','): Array<String>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并用数组的每个元素调用parser转换成指定类型的数组
     */
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并把每个元素转换成指定类型
     */
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T>
    /**
     * 得到名是key的配置项，把配置值按照指定格式转换成DateTime
     */
    public static func getDateTime(key: String, format!: String = ''): ?DateTime
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，并按照指定格式转换成DateTime数组
     */
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime>
    /**
     * 得到名是key的配置项，把配置值转换成指定类型
     */
    public static func getData<T>(key: String): ?T where T <: DataParsable<T>
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，把数组元素转换成指定类型
     */
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T>
    /**
     * 得到名是key的配置项，并转成Duration
     */
    public static func getDuration(key: String): ?Duration
    /**
     * 得到名是key的配置项，把配置值用delim切割成字符串数组，把数组元素转成Duration
     */
    public static func getDurations(key: String, delim!: String = ','): Array<Duration>
    /**
     * 得到名是bufferKey的配置项，并转换成Int64，如果没有相应配置项或者值是负数就返回default
     */
    public static func bufferSize(bufferKey: String, default: Int64, debugging: Bool): Int64
}
```

## 可配置时间转换器

```cj
package fountain::f_config

import fountain::f_data.*

@Annotation[target: [MemberProperty, MemberVariable, Parameter]]
public class DateTimeConfConverter <: DateTimeConverter {
    public const DateTimeConfConverter(private let conf: String, private let default!: String = 'yyyy-MM-dd HH:mm:ss'){}
    public func convert(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?DateTime
}
```


