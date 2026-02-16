正则表达式辅助工具

## 正则表达式扩展
```cj
public interface ExtendRegex {
    /**判定整数的正则表达式*/
    static prop INTEGER: Regex
    /**判定小数的正则表达式*/
    static prop DECIMAL: Regex
    /**判定实数的正则表达式*/
    static prop REAL_NUMBER: Regex
    /**判定电邮的正则表达式*/
    static prop EMAIL: Regex
    /**判定Duration字符串的正则表达式*/
    static prop DURATION: Regex
    /**判定标识符的正则表达式*/
    static prop IDENTIFIER: Regex
    /**判定BASE64的正则表达式*/
    static prop BASE64: Regex
    /**把带通配符的字符串转换为正则表达式*/
    static func wildcard(wildcard: String): Regex
    /**从index开始查找input替换第一个找到的子串*/
    func doReplace(input: String, replacement!: String, index!: Int64): String
    /**替换index后面所有的子串*/
    func doReplaceAll(input: String, replacement!: String, index!: Int64): String
    /**替换index后面所有的子串，替换的子串是replacement的返回值，如果返回了None就不替换*/
    func doReplaceAll(input: String, replacement!: (MatchData) -> ?String, index!: Int64): String
}
```

## 字符串扩展
```cj
/**
 * 字符串扩展此接口，将当前字符串初始化为正则表达式
 * solid如果是true，则正则表达式会在整个进程生命周期内存在，否则会使用fountain::f_cache.HeapCache缓存，最多缓存10000个正则表达式，缓存寿命是一天
 */
public interface RegexFromString {
    func regex(flags!: Array<RegexFlag>, solid!: Bool): Regex
}
```
